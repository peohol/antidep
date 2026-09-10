// ============================================================================
// Dokumentbindingen: hvilket originaldokument en representasjon kom fra
//
// En kildeversjon er enten teksten som lå på en adresse, eller tekst hentet ut
// av et originaldokument — i praksis PDF-en av en fulltekstartikkel. Er den det
// siste, bærer raden to opplysninger til (migrasjon 003e):
//
//   * **fingeravtrykket av dokumentet**, beregnet av databasen av bytene, og
//   * **oppskriften teksten ble hentet ut med**: verktøy, versjon, argumenter.
//
// Til sammen er de kontrakten utad: *kjør denne kommandoen på dokumentet med
// dette fingeravtrykket, og sha256 av resultatet skal være `content_hash`.*
//
// ----------------------------------------------------------------------------
// Hvorfor dette er sin egen modul
//
// Formen bæres av tre filer — oppdraget, forslaget og kontrollgrunnlaget — og
// leses av fire ledd, hvorav ett er nettleseren: kontrolløkten viser hvilket
// dokument utdragene står i. Modulen har derfor **ingen** Node-avhengighet, og
// skal ikke få noen. Selve oppslaget av dokumentet (`source-document.ts`),
// tekstuttrekkingen (`document-text.ts`) og hentingen (`source-binding.ts`)
// ligger hver for seg, over denne.
//
// Utrygg inndata: bindingen er data, aldri instruksjoner (CLAUDE.md).
// ============================================================================

import { CONTENT_HASH_PREFIX } from './content-hash.ts'
import {
  asText,
  fieldsOf,
  nestedFields,
  problem,
  raw,
  rejectUnknown,
  type Fields,
} from './strict-fields.ts'

/** Verktøyet, versjonen av det, og argumentene — ordrett. */
export interface TextExtractionRecipe {
  readonly tool: string
  readonly toolVersion: string
  /** Argumentene, som én streng, slik de står i basen og i en kommandolinje. */
  readonly arguments: string
}

/** Originaldokumentet en kildeversjon er utledet av. */
export interface DocumentBinding {
  /** sha256 av originaldokumentets byte, slik databasen beregnet det. */
  readonly sha256: string
  readonly byteSize: number
  readonly mediaType: string
  /** Oppskriften teksten ble hentet ut med, og som gjentas ved etterprøving. */
  readonly textExtraction: TextExtractionRecipe
}

/**
 * Alt som skal til for å skaffe representasjonen på nytt.
 *
 * Den samme formen i oppdraget, i forslaget og i kontrollgrunnlaget, fordi det
 * er den samme opplysningen: tre ledd som beskrev den hver for seg, ville vært
 * tre steder å beskrive den litt forskjellig.
 */
export interface RepresentationBinding {
  readonly retrievedFrom: string
  readonly contentHash: string
  /** `null` når representasjonen er teksten på adressen, ikke et dokument. */
  readonly document: DocumentBinding | null
}

const DOCUMENT_DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/

/** Om en verdi har formen `knowledge.source_versions.document_sha256` krever. */
export function isDocumentDigest(value: string): boolean {
  return DOCUMENT_DIGEST_PATTERN.test(value)
}

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
}

/**
 * sha256 av bytene slik de er, med algoritmen som prefiks.
 *
 * Samme form og samme algoritme som `sourceVersionContentHash`, men over
 * *bytes* og ikke over tekst. Skillet er hele poenget: en PDF er ikke tekst, og
 * en hash av «PDF-en dekodet som UTF-8» ville verken vært reproduserbar eller
 * meningsfull (`source-retrieval.ts`).
 */
export async function documentDigest(bytes: Uint8Array): Promise<string> {
  // Kopieres inn i en egen ArrayBuffer: en Uint8Array kan være et utsnitt av en
  // større buffer, og `crypto.subtle.digest` ville da hashet hele bufferen.
  const copy = new Uint8Array(bytes.byteLength)
  copy.set(bytes)
  return CONTENT_HASH_PREFIX + toHex(await crypto.subtle.digest('SHA-256', copy.buffer))
}

// ----------------------------------------------------------------------------
// Hva slags fil dette er, lest av bytene og ikke av navnet
//
// Endelsen `.pdf` er en påstand den som lagret filen gjorde. De første bytene
// er dokumentet selv. Kontrollen er bevisst smal: den avgjør bare om noe *er*
// en PDF, som er den ene formen kjeden i dag kan hente tekst ut av med
// etterprøvbar proveniens.
// ----------------------------------------------------------------------------

/** Mediatypen en PDF registreres med. */
export const PDF_MEDIA_TYPE = 'application/pdf'

/** PDF-signaturen, ordrett. */
export const PDF_MAGIC = '%PDF-'

/** Om bytene begynner med PDF-signaturen. */
export function looksLikePdf(bytes: Uint8Array): boolean {
  if (bytes.length < PDF_MAGIC.length) {
    return false
  }
  for (let index = 0; index < PDF_MAGIC.length; index += 1) {
    if (bytes[index] !== PDF_MAGIC.charCodeAt(index)) {
      return false
    }
  }
  return true
}

/**
 * Om en tekst begynner med PDF-signaturen.
 *
 * Motstykket til `looksLikePdf` for veien der en fil allerede er blitt til
 * tekst — et innlimt felt, en fil lest som UTF-8, en `retrieved_content`. En
 * PDF som har vært innom den veien, er ikke lenger dokumentet: bytene er
 * omkodet, og fingeravtrykket ville beskrevet omkodingen framfor filen.
 */
export function textLooksLikePdf(text: string): boolean {
  return text.startsWith(PDF_MAGIC)
}

// ----------------------------------------------------------------------------
// Formen dokumentbindingen har i en fil
//
// Oppdraget og forslaget bærer den samme blokka, lest av den samme koden. To
// lesere ville vært to steder å stave et feltnavn feil — og feilen ville først
// vist seg som en kildeversjon som ble hentet på feil måte.
// ----------------------------------------------------------------------------

const DIGEST_HINT = 'har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn'

/** Leser `document`-blokka, eller `null` når den ikke står der. */
export function parseDocumentBinding(parent: Fields, key = 'document'): DocumentBinding | null {
  const value = raw(parent, key)
  if (value === undefined || value === null) {
    return null
  }
  const fields = nestedFields(parent, value, key)

  const sha256 = asText(fields, 'sha256')
  if (!isDocumentDigest(sha256)) {
    problem(fields.subject, `${key}.sha256`, DIGEST_HINT)
  }

  const byteSize = raw(fields, 'byte_size')
  if (typeof byteSize !== 'number' || !Number.isInteger(byteSize) || byteSize <= 0) {
    problem(fields.subject, `${key}.byte_size`, 'er ikke et helt tall større enn null')
  }

  const mediaType = asText(fields, 'media_type')
  const extraction = nestedFields(fields, raw(fields, 'text_extraction'), `${key}.text_extraction`)
  const recipe: TextExtractionRecipe = {
    tool: asText(extraction, 'tool'),
    toolVersion: asText(extraction, 'tool_version'),
    arguments: asText(extraction, 'arguments'),
  }
  rejectUnknown(extraction)
  rejectUnknown(fields)

  return { sha256, byteSize, mediaType, textExtraction: recipe }
}

/**
 * Den samme blokka lest ut av en verdi som ikke ligger i et felt.
 *
 * Kontrollgrunnlaget fra databasen er ett jsonb-objekt og ikke en fil, og
 * `document` ligger inne i `source_version`. Formen skal likevel leses av
 * nøyaktig den samme koden: to lesere ville vært to steder å godta litt
 * forskjellige former, og forskjellen ville vist seg som en kontroll som hentet
 * teksten på feil måte.
 */
export function parseDocumentBindingValue(
  value: unknown,
  subject: string,
  where: string,
): DocumentBinding | null {
  if (value === undefined || value === null) {
    return null
  }
  return parseDocumentBinding(fieldsOf({ document: value }, subject, where), 'document')
}

/** Skriver `document`-blokka slik `parseDocumentBinding` leser den. */
export function serializeDocumentBinding(document: DocumentBinding | null): unknown {
  if (document === null) {
    return null
  }
  return {
    sha256: document.sha256,
    byte_size: document.byteSize,
    media_type: document.mediaType,
    text_extraction: {
      tool: document.textExtraction.tool,
      tool_version: document.textExtraction.toolVersion,
      arguments: document.textExtraction.arguments,
    },
  }
}

/**
 * Om to dokumentbindinger beskriver det samme dokumentet og den samme
 * oppskriften.
 *
 * Returnerer `null` når de gjør det, ellers én setning som sier hva som
 * skiller dem. Fraværet av en binding er også en verdi: en fulltekstversjon som
 * plutselig ikke har noe dokument, er ikke den samme kildeversjonen.
 */
export function documentBindingMismatch(
  expected: DocumentBinding | null,
  actual: DocumentBinding | null,
): string | null {
  if (expected === null && actual === null) {
    return null
  }
  if (expected === null || actual === null) {
    return actual === null
      ? 'forslaget oppgir ingen dokumentbinding, mens oppdraget er utledet av et originaldokument'
      : 'forslaget oppgir en dokumentbinding, mens oppdraget ikke er utledet av et originaldokument'
  }
  const pairs: readonly (readonly [string, string, string])[] = [
    ['document.sha256', actual.sha256, expected.sha256],
    ['document.byte_size', String(actual.byteSize), String(expected.byteSize)],
    ['document.media_type', actual.mediaType, expected.mediaType],
    ['document.text_extraction.tool', actual.textExtraction.tool, expected.textExtraction.tool],
    [
      'document.text_extraction.tool_version',
      actual.textExtraction.toolVersion,
      expected.textExtraction.toolVersion,
    ],
    [
      'document.text_extraction.arguments',
      actual.textExtraction.arguments,
      expected.textExtraction.arguments,
    ],
  ]
  for (const [key, proposed, wanted] of pairs) {
    if (proposed !== wanted) {
      return `${key} er ${JSON.stringify(proposed)} i forslaget, men ${JSON.stringify(wanted)} i oppdraget`
    }
  }
  return null
}
