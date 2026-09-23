// ============================================================================
// De maskinelt utførte søkene
//
// Kildeoppdagelsen har to utførelsesveier, og de er ikke det samme. En ekstern
// KI-agent kan *rapportere* et søk den sier den gjorde; Antidep registrerer det
// som agentens egen beretning. Dette er den andre veien: Antideps egen kode
// kaller et navngitt offentlig søke-API, leser svaret, og registrerer søket med
// endepunktet og et fingeravtrykk av svaret. Databasen holder de to fra
// hverandre (`workflow.monograph_execution_evidence`), og det er hele poenget —
// en agents erklæring om et verktøykall skal ikke omtales som maskinelt
// bekreftet utførelse (SOURCE_POLICY.md §4.3).
//
// ----------------------------------------------------------------------------
// Hvorfor hentingen går gjennom `guardedGet`
//
// Fordi adressene kommer fra data. En søkestreng bygget av en avgrensning i
// databasen, og en treffliste med lenker i, er begge utrygg inndata: uten
// adressekontroll ville en kjører med tilgang til interne tjenester kunnet
// styres dit av en rad. `guardedGet` kontrollerer adressen socketen faktisk
// kobler til, hvert redirect-hopp, størrelsen og tiden.
//
// ----------------------------------------------------------------------------
// Hvorfor plattformene er tre og ikke én
//
// Kildepolitikken krever flere uavhengige søkespor, og metningsregelen i
// `workflow.monograph_search_closure_problem(uuid)` teller distinkte
// plattformer. Én plattform kjørt tre ganger er ett spor. De tre her er valgt
// fordi de er åpne, dokumenterte og ikke krever en nøkkel:
//
//   Europe PMC   biomedisinsk litteratur, med åpen fulltekstlenke når den finnes
//   PubMed       MEDLINE gjennom E-utilities
//   Crossref     registeret over DOI-er, som fanger det som ikke er indeksert
//                biomedisinsk
//
// ----------------------------------------------------------------------------
// Hva et mislykket søk er
//
// Tre forskjellige ting, og de skal ikke se like ut: et utført søk uten treff
// (`zero_results`), en søkevei Antidep ikke kom til (`unavailable`), og et svar
// som ikke lot seg lese (`failed`). Ingen av dem er en konklusjon om evidensen
// (SOURCE_POLICY.md §8.2).
// ============================================================================

import { createHash } from 'node:crypto'

import { guardedGet, type GuardedGetOptions } from '../agents/guarded-http.ts'
import { SEARCH_OUTCOMES } from '../agents/search-outcomes.ts'
import { catalogEntry } from './search-method-catalog.ts'

/** Sporene et bibliografisk fritekstsøk dekker, lest av katalogen. */
function keywordTracks(platform: string): readonly string[] {
  return catalogEntry(platform, 'keyword').coverage.map((entry) => entry.track)
}

/** Hentefunksjonen. Injiserbar, slik at prøver kan spille av et opptak. */
export type Fetcher = (
  url: string,
  overrides?: Partial<GuardedGetOptions>,
) => Promise<
  | {
      status: 'ok'
      httpStatus: number
      contentType: string | null
      bytes: Uint8Array
      finalUrl: string
    }
  | { status: 'error'; message: string }
>

/** Avgrensningen søket gjelder, slik `api.monograph_discovery_work` gir den. */
export interface SearchScope {
  readonly drug: string
  readonly indication?: string | undefined
  readonly outcome?: string | undefined
  readonly population?: string | undefined
  readonly comparator?: string | undefined
  /**
   * Katalogens egne synonymer for virkestoffet — typisk det engelske
   * INN-navnet. Søkes som ALTERNATIVER til det kanoniske navnet, aldri som et
   * krav i tillegg (migrasjon 014d).
   */
  readonly drugAliases?: readonly string[] | undefined
  /** ATC-kodene katalogen har for virkestoffet. FEST slås opp på dem. */
  readonly atcCodes?: readonly string[] | undefined
}

/** Én kandidatkilde, slik `api.record_monograph_machine_search` tar imot den. */
export interface CandidateSource {
  readonly identifier_kind: 'doi' | 'pmid' | 'pmcid' | 'url' | 'registry_id' | 'title'
  readonly identifier_value: string
  readonly title: string
  readonly authors_or_issuer?: string | undefined
  readonly publisher_or_journal?: string | undefined
  readonly publication_year?: number | undefined
  readonly discovery_path: string
  readonly access_limited?: boolean | undefined
  readonly access_limitation_note?: string | undefined
}

/** Utfallet ett søk kan ha. Det samme vokabularet databasen og svarformen bruker. */
export type SearchOutcome = (typeof SEARCH_OUTCOMES)[number]

/** Resultatet av ett utført søk, klart til registrering. */
export interface MachineSearch {
  readonly platform: string
  /**
   * Søkemetoden, slik den står i `knowledge.monograph_search_methods`. Et
   * PubMed-søk med oversiktsfilter og et uten er to forskjellige søk, og bare
   * det første dekker oversiktssporet (migrasjon 014c).
   */
  readonly method: string
  readonly queryString: string
  readonly filters: string | null
  readonly endpoint: string
  readonly responseDigest: string | null
  readonly outcome: SearchOutcome
  readonly resultCount: number | null
  readonly screenedCount: number
  readonly truncated: boolean
  readonly truncationNote: string | null
  readonly limitationNote: string | null
  readonly trackCodes: readonly string[]
  readonly candidates: readonly CandidateSource[]
}

/** Hvor mange treff hvert søk leser. Bevisst lavt: dette er en driftskjøring. */
export const PAGE_SIZE = 25

/** De aksene som er noe annet enn virkestoffet, i en fast rekkefølge. */
function scopeTerms(scope: SearchScope): readonly string[] {
  return [scope.indication, scope.outcome, scope.population, scope.comparator]
    .map((value) => value?.trim())
    .filter((value): value is string => value !== undefined && value.length > 0)
}

/**
 * Virkestoffleddet: det kanoniske navnet, og synonymene som ALTERNATIVER.
 *
 * Skillet mellom et synonym og en term er ikke kosmetisk. Et virkestoffnavn på
 * et annet språk lagt til som en ekstra term gir «"sertralin" AND "sertraline"»
 * — og da kan en artikkel som bare bruker det engelske navnet, ikke treffe i
 * det hele tatt. Nettopp den artikkelen var søket ment å finne.
 */
function drugClause(scope: SearchScope, aliases: readonly string[]): string {
  const names = [scope.drug, ...aliases.map((alias) => alias.trim())].filter(
    (name) => name.length > 0,
  )
  const unique = [...new Set(names)]
  return unique.length === 1
    ? `"${unique[0] ?? ''}"`
    : `(${unique.map((name) => `"${name}"`).join(' OR ')})`
}

/**
 * Søkestrengen, bygget av avgrensningen.
 *
 * Bredere enn den senere analyseavgrensningen med vilje: et søk som krever at
 * alle utfall står i tittel eller abstract, er ikke et dekkende søk
 * (SOURCE_POLICY.md §4.1). Virkestoffet er alltid med; de øvrige aksene legges
 * til som ELLER-ledd, slik at en artikkel som bare nevner den ene, fortsatt
 * kommer med.
 */
export function buildQuery(
  scope: SearchScope,
  extraTerms: readonly string[] = [],
  drugAliases: readonly string[] = [],
): string {
  const drug = drugClause(scope, drugAliases)
  const extra = [...scopeTerms(scope), ...extraTerms.map((term) => term.trim())].filter(
    (value) => value.length > 0,
  )

  if (extra.length === 0) {
    return drug
  }
  return `${drug} AND (${extra.map((value) => `"${value}"`).join(' OR ')})`
}

/** Hvor mange strenger én runde kan gi. En driftskjøring er ikke en støvsuger. */
export const MAX_QUERIES_PER_REQUEST = 6

/**
 * Strengene én søkerunde skal kjøre.
 *
 * `broad` er den brede orienteringen: alle aksene som ELLER-ledd, som før.
 * `targeted` er noe annet, og det er hele poenget med at de to finnes: én
 * passering per akse og per bedt om term, hver av dem et smalere søk som kan
 * løfte fram noe det brede søket lot drukne. Dekningskontrollens motsøk kjører
 * alltid `targeted` — et motsøk som gjentok generatorens egen streng, ville
 * ikke lett etter det generatoren overså (SOURCE_POLICY.md §6).
 */
export function buildQueries(
  scope: SearchScope,
  strategy: 'broad' | 'targeted',
  extraTerms: readonly string[] = [],
  drugAliases: readonly string[] = [],
): readonly string[] {
  if (strategy === 'broad') {
    return [buildQuery(scope, extraTerms, drugAliases)]
  }

  const drug = drugClause(scope, drugAliases)
  const axes = [...scopeTerms(scope), ...extraTerms.map((term) => term.trim())].filter(
    (value) => value.length > 0,
  )
  if (axes.length === 0) {
    return [drug]
  }
  // Duplikater fjernes: den samme strengen kjørt to ganger er ett spor og ikke
  // to passeringer, og metningsregelen teller passeringer.
  const unique = [...new Set(axes)]
  return unique.slice(0, MAX_QUERIES_PER_REQUEST).map((axis) => `${drug} AND "${axis}"`)
}

/** Fingeravtrykket av et svar: SHA-256 over bytene som faktisk kom. */
export function digest(bytes: Uint8Array | readonly Uint8Array[]): string {
  const hash = createHash('sha256')
  // Flere sider tas i rekkefølge, slik at avtrykket er av hele svaret som ble
  // lest, og ikke bare av den første siden.
  // `ArrayBuffer.isView` og ikke `instanceof`: en Uint8Array fra et annet
  // realm (en testmiljøs TextEncoder) er fortsatt ett svar og ikke en liste.
  for (const part of ArrayBuffer.isView(bytes)
    ? [bytes as Uint8Array]
    : (bytes as readonly Uint8Array[])) {
    hash.update(part)
  }
  return `sha256:${hash.digest('hex')}`
}

export function text(bytes: Uint8Array): string {
  return new TextDecoder('utf-8').decode(bytes)
}

export function year(value: unknown): number | undefined {
  const parsed =
    typeof value === 'number' ? value : Number.parseInt(String(value ?? '').slice(0, 4), 10)
  return Number.isInteger(parsed) && parsed >= 1800 && parsed <= 2200 ? parsed : undefined
}

export function trimmed(value: unknown): string | undefined {
  const asString = typeof value === 'string' ? value.trim() : ''
  return asString.length > 0 ? asString : undefined
}

/** Et svar som ikke lot seg lese, er `failed` — ikke null treff. */
export function unreadable(
  base: Omit<MachineSearch, 'outcome' | 'resultCount' | 'limitationNote'>,
  why: string,
): MachineSearch {
  return {
    ...base,
    outcome: 'failed',
    resultCount: null,
    limitationNote: why,
  }
}

/** En søkevei Antidep ikke kom til, er `unavailable` — heller ikke null treff. */
export function unreachable(
  base: Omit<MachineSearch, 'outcome' | 'resultCount' | 'limitationNote' | 'responseDigest'> & {
    readonly responseDigest?: string | null
  },
  why: string,
): MachineSearch {
  return {
    ...base,
    // Et svar Antidep faktisk fikk, beholder avtrykket sitt også når det var en
    // HTTP-feil: avtrykket er utførelsesbeviset, og det finnes uansett hva
    // tjenesten svarte. Kom det ikke noe svar i det hele tatt, finnes det ikke.
    responseDigest: base.responseDigest ?? null,
    outcome: 'unavailable',
    resultCount: null,
    limitationNote: why,
  }
}

/** Én søkeplattform: hvordan adressen bygges, og hvordan svaret leses. */
export interface SearchPlatform {
  readonly name: string
  readonly trackCodes: readonly string[]
  readonly endpoint: (query: string) => string
  readonly parse: (body: string) => {
    readonly total: number
    readonly candidates: readonly CandidateSource[]
  }
}

export const EUROPE_PMC: SearchPlatform = {
  name: 'Europe PMC',
  trackCodes: keywordTracks('Europe PMC'),
  endpoint: (query) =>
    'https://www.ebi.ac.uk/europepmc/webservices/rest/search' +
    `?query=${encodeURIComponent(query)}&format=json&pageSize=${PAGE_SIZE}&resultType=core`,
  parse: (body) => {
    const payload = JSON.parse(body) as Record<string, unknown>
    const list = (payload['resultList'] as Record<string, unknown> | undefined)?.['result']
    const rows = Array.isArray(list) ? list : []
    const total = Number(payload['hitCount'] ?? rows.length)
    const candidates: CandidateSource[] = []
    for (const entry of rows) {
      const row = entry as Record<string, unknown>
      const title = trimmed(row['title'])
      if (title === undefined) continue
      const doi = trimmed(row['doi'])
      const pmid = trimmed(row['pmid'])
      const pmcid = trimmed(row['pmcid'])
      const identifier: CandidateSource['identifier_kind'] | null =
        doi !== undefined
          ? 'doi'
          : pmid !== undefined
            ? 'pmid'
            : pmcid !== undefined
              ? 'pmcid'
              : null
      if (identifier === null) continue
      const isOpen = trimmed(row['isOpenAccess']) === 'Y'
      candidates.push({
        identifier_kind: identifier,
        identifier_value: (doi ?? pmid ?? pmcid) as string,
        title,
        authors_or_issuer: trimmed(row['authorString']),
        publisher_or_journal: trimmed(row['journalTitle']),
        publication_year: year(row['pubYear']),
        discovery_path: 'Europe PMC, søk gjennom det åpne REST-endepunktet',
        access_limited: !isOpen,
        access_limitation_note: isOpen
          ? undefined
          : 'Treffet er ikke merket som åpen tilgang i Europe PMC. Tilgangen er ikke avklart.',
      })
    }
    return { total: Number.isFinite(total) ? total : candidates.length, candidates }
  },
}

export const PUBMED: SearchPlatform = {
  name: 'PubMed',
  trackCodes: keywordTracks('PubMed'),
  endpoint: (query) =>
    'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi' +
    `?db=pubmed&term=${encodeURIComponent(query)}&retmode=json&retmax=${PAGE_SIZE}`,
  parse: (body) => {
    const payload = JSON.parse(body) as Record<string, unknown>
    const result = payload['esearchresult'] as Record<string, unknown> | undefined
    const ids = Array.isArray(result?.['idlist']) ? (result['idlist'] as unknown[]) : []
    const total = Number(result?.['count'] ?? ids.length)
    // E-utilities gir bare identifikatorene. Tittelen hentes ikke her: en
    // tittel Antidep fant på, ville sett ut som en opplysning fra kilden.
    const candidates = ids
      .map((value) => trimmed(value))
      .filter((value): value is string => value !== undefined)
      .map<CandidateSource>((pmid) => ({
        identifier_kind: 'pmid',
        identifier_value: pmid,
        title: `PubMed-oppføring ${pmid}`,
        discovery_path: 'PubMed, søk gjennom E-utilities esearch',
        access_limited: true,
        access_limitation_note:
          'Treffet er en identifikator fra et søkeregister. Verken tittel eller tilgang er avklart ennå.',
      }))
    return { total: Number.isFinite(total) ? total : candidates.length, candidates }
  },
}

export const CROSSREF: SearchPlatform = {
  name: 'Crossref',
  trackCodes: keywordTracks('Crossref'),
  endpoint: (query) =>
    `https://api.crossref.org/works?query=${encodeURIComponent(query)}&rows=${PAGE_SIZE}`,
  parse: (body) => {
    const payload = JSON.parse(body) as Record<string, unknown>
    const message = payload['message'] as Record<string, unknown> | undefined
    const rows = Array.isArray(message?.['items']) ? (message['items'] as unknown[]) : []
    const total = Number(message?.['total-results'] ?? rows.length)
    const candidates: CandidateSource[] = []
    for (const entry of rows) {
      const row = entry as Record<string, unknown>
      const doi = trimmed(row['DOI'])
      const titles = Array.isArray(row['title']) ? (row['title'] as unknown[]) : []
      const title = trimmed(titles[0])
      if (doi === undefined || title === undefined) continue
      const authors = Array.isArray(row['author'])
        ? (row['author'] as Record<string, unknown>[])
        : []
      const container = Array.isArray(row['container-title'])
        ? trimmed((row['container-title'] as unknown[])[0])
        : undefined
      const issued = row['issued'] as Record<string, unknown> | undefined
      const parts = Array.isArray(issued?.['date-parts'])
        ? ((issued['date-parts'] as unknown[])[0] as unknown[] | undefined)
        : undefined
      candidates.push({
        identifier_kind: 'doi',
        identifier_value: doi,
        title,
        authors_or_issuer:
          authors.length > 0
            ? authors
                .map((author) =>
                  [trimmed(author['given']), trimmed(author['family'])]
                    .filter((part) => part !== undefined)
                    .join(' '),
                )
                .filter((name) => name.length > 0)
                .join(', ')
            : undefined,
        publisher_or_journal: container,
        publication_year: year(parts?.[0]),
        discovery_path: 'Crossref, søk gjennom det åpne works-endepunktet',
        access_limited: true,
        access_limitation_note:
          'Crossref sier ingenting om tilgang. Om fullteksten er tilgjengelig, er ikke avklart.',
      })
    }
    return { total: Number.isFinite(total) ? total : candidates.length, candidates }
  },
}

export const SEARCH_PLATFORMS: readonly SearchPlatform[] = [EUROPE_PMC, PUBMED, CROSSREF]

/** Ett søk slik én søkemetode ber om det: adressen, strengen og hvordan svaret leses. */
export interface QuerySpec {
  readonly platform: string
  readonly method: string
  readonly queryString: string
  readonly filters: string | null
  readonly endpoint: string
  readonly parse: SearchPlatform['parse']
  /** Sporene søket erklærer: allerede skåret mot runden og metodens dekning. */
  readonly trackCodes: readonly string[]
  /** Oppdagelsesveien kandidatene får, når metoden er noe annet enn fritekstsøket. */
  readonly discoveryPath?: string | undefined
  readonly maxBytes?: number | undefined
}

/**
 * Utfører ett søk og leser svaret til et registrerbart resultat.
 *
 * Kaster aldri: en plattform som er nede, et svar som ikke lar seg lese, og et
 * søk uten treff er tre forskjellige registrerte utfall, og ingen av dem er en
 * grunn til at resten av kjøringen skal stoppe.
 */
export async function runQuery(
  spec: QuerySpec,
  fetcher: Fetcher = guardedGet,
): Promise<MachineSearch> {
  const base = {
    platform: spec.platform,
    method: spec.method,
    queryString: spec.queryString,
    filters: spec.filters,
    endpoint: spec.endpoint,
    screenedCount: 0,
    truncated: false,
    truncationNote: null,
    trackCodes: spec.trackCodes,
    candidates: [] as readonly CandidateSource[],
  }

  const response = await fetcher(spec.endpoint, {
    timeoutMs: 20_000,
    maxBytes: spec.maxBytes ?? 4 * 1024 * 1024,
  })
  if (response.status === 'error') {
    return unreachable(base, `Søkeveien svarte ikke: ${response.message}`)
  }
  if (response.httpStatus < 200 || response.httpStatus >= 300) {
    return unreachable(
      { ...base, responseDigest: digest(response.bytes) },
      `Søkeveien svarte med HTTP ${response.httpStatus}.`,
    )
  }

  const responseDigest = digest(response.bytes)
  let parsed: { total: number; candidates: readonly CandidateSource[] }
  try {
    parsed = spec.parse(text(response.bytes))
  } catch (error) {
    return unreadable(
      { ...base, responseDigest },
      `Svaret lot seg ikke lese: ${error instanceof Error ? error.message : 'ukjent form'}.`,
    )
  }

  const candidates =
    spec.discoveryPath === undefined
      ? parsed.candidates
      : parsed.candidates.map((candidate) => ({
          ...candidate,
          discovery_path: spec.discoveryPath ?? '',
        }))
  const truncated = parsed.total > candidates.length
  return {
    ...base,
    responseDigest,
    outcome: parsed.total === 0 ? 'zero_results' : 'executed',
    resultCount: parsed.total,
    screenedCount: candidates.length,
    truncated,
    truncationNote: truncated
      ? `Trefflisten er avkortet: ${parsed.total} treff totalt, ${candidates.length} gjennomgått på første side.`
      : null,
    limitationNote: null,
    candidates,
  }
}

/**
 * Utfører ett bibliografisk fritekstsøk mot én plattform, med den strengen
 * runden ba om.
 *
 * Sporene søket kan erklære, er skjæringen mellom det runden fikk lov til og
 * det plattformen faktisk dekker. Uten skjæringen ville ett vellykket Europe
 * PMC-søk merket forsøksregistre og regulatorisk veiledning som dekket — og
 * porten ville sett dekket ut for spor ingen hadde søkt i (SOURCE_POLICY.md
 * §4.2).
 */
export async function runSearch(
  platform: SearchPlatform,
  query: string,
  fetcher: Fetcher = guardedGet,
  allowedTracks: readonly string[] = [],
): Promise<MachineSearch> {
  return runQuery(
    {
      platform: platform.name,
      method: 'keyword',
      queryString: query,
      filters: `pageSize=${PAGE_SIZE}`,
      endpoint: platform.endpoint(query),
      parse: platform.parse,
      trackCodes: platform.trackCodes.filter((code) => allowedTracks.includes(code)),
    },
    fetcher,
  )
}
