// ============================================================================
// Innhentingen som faktisk henter
//
// Antidep har valgt kildene. Denne kjøringen gjør det neste: den leter etter
// materialet der det faktisk ligger — hos utgiveren, i et åpent arkiv — før
// noen spør en kliniker. En betalingsmur er en tilgangsbegrensning, ikke en
// faglig eksklusjonsgrunn, og en artikkel Antidep selv kunne hentet, skal ikke
// bli en menneskeoppgave (SOURCE_POLICY.md §5).
//
// ----------------------------------------------------------------------------
// To veier, fordi kontraktene er forskjellige
//
//   Myndighetsdokument   en side eller et strukturert datasett. Hentes, teksten
//                        trekkes ut med en navngitt oppskrift, og begge deler
//                        registreres gjennom api.submit_monograph_document(...).
//   Forskningsfulltekst  krever PDF med etterprøvbar dokumentbinding. Kjøringen
//                        leter etter en åpen PDF gjennom Europe PMC, og
//                        registrerer den gjennom fulltekstinnboksen —
//                        nøyaktig den veien et menneske ville brukt. Finnes
//                        ingen åpen PDF, blir forespørselen stående åpen, og
//                        det er en tilgangsbegrensning og ikke en konklusjon.
//
// ----------------------------------------------------------------------------
// Tekstuttrekket fra HTML
//
// Oppskriften er navngitt (`antidep-html-text@1`) og står på originalfilen, slik
// at et ordrett utdrag senere kan kontrolleres mot nøyaktig den teksten. Den er
// bevisst enkel: skript og stil fjernes, tagger blir til mellomrom, og
// HTML-entiteter oversettes. Ingen tolkning, ingen sammendrag — et uttrekk som
// «ryddet opp» i teksten, ville gjort et ordrett sitat til noe annet enn det som
// sto der.
//
// ----------------------------------------------------------------------------
// Utrygg inndata
//
// En hentet side er DATA. Innholdet blir aldri et argument, aldri en adresse å
// følge videre utenom `guardedGet`, og aldri en instruksjon. Adressene kommer
// fra registrerte kilder og fra Europe PMC-svaret, og alle går gjennom
// adressekontrollen.
// ============================================================================

import { createHash } from 'node:crypto'

import { guardedGet } from '../agents/guarded-http.ts'
import type { Fetcher } from './monograph-search.ts'

/** Oppskriften teksten trekkes ut av en HTML-side med. */
export const HTML_TEXT_RECIPE = 'antidep-html-text@1'

/** Den korteste teksten databasen godtar som et dokument. */
export const MINIMUM_TEXT_LENGTH = 200

const ENTITIES: Readonly<Record<string, string>> = {
  amp: '&',
  lt: '<',
  gt: '>',
  quot: '"',
  apos: "'",
  nbsp: ' ',
  aring: 'å',
  Aring: 'Å',
  oslash: 'ø',
  Oslash: 'Ø',
  aelig: 'æ',
  AElig: 'Æ',
}

/**
 * Teksten i en HTML- eller XML-side, etter den navngitte oppskriften.
 *
 * Bevisst enkel og bevisst uten tolkning: et uttrekk som ryddet opp i teksten,
 * ville gjort et ordrett sitat til noe annet enn det som sto i dokumentet.
 */
export function extractHtmlText(html: string): string {
  return html
    .replace(/<script\b[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[\s\S]*?<\/style>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#(\d+);/g, (_all, code: string) => String.fromCodePoint(Number.parseInt(code, 10)))
    .replace(/&#x([0-9a-f]+);/gi, (_all, code: string) =>
      String.fromCodePoint(Number.parseInt(code, 16)),
    )
    .replace(/&([a-zA-Z]+);/g, (all, name: string) => ENTITIES[name] ?? all)
    .replace(/[ \t\r\f\v]+/g, ' ')
    .replace(/\s*\n\s*/g, '\n')
    .trim()
}

/** Formen `api.monograph_source_requests(text)` gir. */
export interface SourceRequest {
  readonly reference: string
  readonly kind: 'research_full_text' | 'authority_document'
  readonly title: string
  readonly retrievedFrom: string | null
  readonly requiredRepresentation: string | null
  readonly identifiers: readonly { readonly system: string; readonly value: string }[]
}

export type AcquisitionOutcome =
  | { readonly status: 'registered'; readonly reference: string; readonly note: string }
  | { readonly status: 'left_open'; readonly reference: string; readonly note: string }

/** Databasegrensen kjøringen bruker. */
export interface AcquisitionApi {
  readonly orders: () => Promise<readonly string[]>
  readonly requests: (editionReference: string) => Promise<readonly SourceRequest[]>
  readonly submitDocument: (args: {
    readonly reference: string
    readonly documentBase64: string
    readonly mediaType: string
    readonly extractedText: string
    readonly recipe: string
    readonly retrievedFrom: string
  }) => Promise<void>
  readonly submitFullText: (args: {
    readonly reference: string
    readonly documentBase64: string
  }) => Promise<void>
}

export interface AcquisitionReport {
  readonly editions: number
  readonly requests: number
  readonly registered: number
  readonly leftOpen: number
  readonly notes: readonly string[]
}

/** Europe PMC-oppslaget som finner en åpen PDF, når det finnes en. */
export async function openAccessPdfUrl(doi: string, fetcher: Fetcher): Promise<string | null> {
  const endpoint =
    'https://www.ebi.ac.uk/europepmc/webservices/rest/search' +
    `?query=${encodeURIComponent(`DOI:"${doi}"`)}&format=json&pageSize=1&resultType=core`
  const response = await fetcher(endpoint, { timeoutMs: 20_000, maxBytes: 4 * 1024 * 1024 })
  if (response.status !== 'ok' || response.httpStatus !== 200) {
    return null
  }

  let payload: Record<string, unknown>
  try {
    payload = JSON.parse(new TextDecoder('utf-8').decode(response.bytes)) as Record<string, unknown>
  } catch {
    return null
  }

  const list = (payload['resultList'] as Record<string, unknown> | undefined)?.['result']
  const first = Array.isArray(list) ? (list[0] as Record<string, unknown> | undefined) : undefined
  const urls = (first?.['fullTextUrlList'] as Record<string, unknown> | undefined)?.['fullTextUrl']
  if (!Array.isArray(urls)) {
    return null
  }

  for (const entry of urls) {
    const row = entry as Record<string, unknown>
    if (String(row['documentStyle'] ?? '').toLowerCase() !== 'pdf') continue
    if (
      String(row['availability'] ?? '')
        .toLowerCase()
        .includes('subscription')
    )
      continue
    const url = String(row['url'] ?? '')
    // Bare https. En adresse uten kryptering ville gjort dokumentets identitet
    // avhengig av et ledd underveis.
    if (url.startsWith('https://')) {
      return url
    }
  }
  return null
}

function isPdf(bytes: Uint8Array): boolean {
  return (
    bytes.length > 5 &&
    bytes[0] === 0x25 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x44 &&
    bytes[3] === 0x46 &&
    bytes[4] === 0x2d
  )
}

function base64(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString('base64')
}

/** Henter og registrerer materialet for én forespørsel. Kaster aldri. */
export async function acquireOne(
  api: AcquisitionApi,
  request: SourceRequest,
  fetcher: Fetcher,
): Promise<AcquisitionOutcome> {
  if (request.kind === 'authority_document') {
    if (request.retrievedFrom === null || !request.retrievedFrom.startsWith('https://')) {
      return {
        status: 'left_open',
        reference: request.reference,
        note: 'Dokumentet har ingen https-adresse Antidep kan hente det fra.',
      }
    }

    const response = await fetcher(request.retrievedFrom, {
      timeoutMs: 30_000,
      maxBytes: 8 * 1024 * 1024,
    })
    if (response.status !== 'ok' || response.httpStatus !== 200) {
      return {
        status: 'left_open',
        reference: request.reference,
        note: 'Adressen svarte ikke, og dokumentet er fortsatt etterspurt.',
      }
    }
    if (isPdf(response.bytes)) {
      return {
        status: 'left_open',
        reference: request.reference,
        note: 'Adressen ga en PDF. PDF-veien har sin egen kontroll, og dokumentet må registreres gjennom fulltekstinnboksen.',
      }
    }

    const html = new TextDecoder('utf-8').decode(response.bytes)
    const text = extractHtmlText(html)
    if (text.length < MINIMUM_TEXT_LENGTH) {
      return {
        status: 'left_open',
        reference: request.reference,
        note: 'Siden ga for lite tekst til å være dokumentet.',
      }
    }

    const mediaType = (response.contentType ?? '').toLowerCase().includes('xml')
      ? 'application/xml'
      : 'text/html'

    try {
      await api.submitDocument({
        reference: request.reference,
        documentBase64: base64(response.bytes),
        mediaType,
        extractedText: text,
        recipe: mediaType === 'application/xml' ? 'antidep-xml-text@1' : HTML_TEXT_RECIPE,
        retrievedFrom: response.finalUrl,
      })
    } catch {
      return {
        status: 'left_open',
        reference: request.reference,
        note: 'Dokumentet ble hentet, men avvist av registreringen.',
      }
    }

    return {
      status: 'registered',
      reference: request.reference,
      note: 'Myndighetsdokumentet er hentet og registrert.',
    }
  }

  const doi = request.identifiers.find((row) => row.system === 'doi')?.value
  if (doi === undefined) {
    return {
      status: 'left_open',
      reference: request.reference,
      note: 'Artikkelen har ingen DOI, og det finnes ingen åpen vei å lete etter fullteksten på.',
    }
  }

  const pdfUrl = await openAccessPdfUrl(doi, fetcher)
  if (pdfUrl === null) {
    return {
      status: 'left_open',
      reference: request.reference,
      note: 'Ingen åpen fulltekst-PDF ble funnet. Tilgangen er begrenset, og det er ikke en faglig konklusjon.',
    }
  }

  const response = await fetcher(pdfUrl, { timeoutMs: 60_000, maxBytes: 16 * 1024 * 1024 })
  if (response.status !== 'ok' || response.httpStatus !== 200 || !isPdf(response.bytes)) {
    return {
      status: 'left_open',
      reference: request.reference,
      note: 'Den åpne lenken ga ikke en PDF, og forespørselen står fortsatt åpen.',
    }
  }

  try {
    await api.submitFullText({
      reference: request.reference,
      documentBase64: base64(response.bytes),
    })
  } catch {
    return {
      status: 'left_open',
      reference: request.reference,
      note: 'Fullteksten ble hentet, men avvist av fulltekstinnboksen.',
    }
  }

  return {
    status: 'registered',
    reference: request.reference,
    note: 'Åpen fulltekst hentet fra arkivet og lagt i fulltekstinnboksen.',
  }
}

/** Kjører innhentingen for alle åpne bestillinger. */
export async function runMonographAcquisition(
  api: AcquisitionApi,
  options: { readonly maxRequests?: number; readonly fetcher?: Fetcher } = {},
): Promise<AcquisitionReport> {
  const fetcher = options.fetcher ?? guardedGet
  const limit = options.maxRequests ?? 10
  const editions = await api.orders()

  let requests = 0
  let registered = 0
  let leftOpen = 0
  const notes: string[] = []

  for (const edition of editions) {
    if (requests >= limit) break
    let open: readonly SourceRequest[]
    try {
      open = await api.requests(edition)
    } catch {
      notes.push('Forespørselslisten for én utgave kunne ikke hentes.')
      continue
    }

    for (const request of open) {
      if (requests >= limit) break
      requests += 1
      const outcome = await acquireOne(api, request, fetcher)
      if (outcome.status === 'registered') {
        registered += 1
      } else {
        leftOpen += 1
      }
      notes.push(outcome.note)
    }
  }

  return { editions: editions.length, requests, registered, leftOpen, notes }
}

/** Rapporten, i klartekst. Ingen artikkeltitler: loggen kan være offentlig. */
export function describeAcquisitionReport(report: AcquisitionReport): string {
  const counted = new Map<string, number>()
  for (const note of report.notes) {
    counted.set(note, (counted.get(note) ?? 0) + 1)
  }
  const lines = [
    `Bestillinger sett: ${report.editions}`,
    `Forespørsler forsøkt: ${report.requests}`,
    `Hentet og registrert: ${report.registered}`,
    `Fortsatt åpne: ${report.leftOpen}`,
  ]
  for (const [note, count] of [...counted].sort((a, b) => b[1] - a[1])) {
    lines.push(`  ${count}x ${note}`)
  }
  return lines.join('\n')
}

/** Fingeravtrykket av en fil, slik driftsloggen kan si hva som ble hentet. */
export function fingerprint(bytes: Uint8Array): string {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`
}
