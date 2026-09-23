// ============================================================================
// Søkemetodene: hva Antideps kode gjør mot hver tjeneste, og hvilke spor det
// faktisk dekker
//
// Dette er TypeScript-siden av registeret i `knowledge.monograph_search_methods`
// og `knowledge.monograph_search_platforms` (migrasjon 014c). De to holdes like
// av en prøve som leser migrasjonen: en metode databasen tror finnes, men som
// koden ikke har, ville vært en evne ingen har — og en metode koden har, men som
// databasen ikke kjenner, ville blitt avvist ved registreringen.
//
// ----------------------------------------------------------------------------
// Hvorfor metoder og ikke plattformer
//
// Et PubMed-søk med NLMs oversiktsfilter er et annet søk enn et PubMed-søk uten.
// Bare det første dekker oversiktssporet, og det er metoden — ikke plattformen —
// som avgjør det. Å kalle hvert filter en egen «plattform» ville vært et
// register som lyver om hvor mange tjenester Antidep kaller; å la «PubMed»
// dekke oversiktssporet ville latt hvert PubMed-søk erklære det.
//
// ----------------------------------------------------------------------------
// Hva metodene ikke gjør
//
// De velger ikke kilder, de vurderer ikke relevans, og de bestemmer ikke hvilke
// kilder som er sentrale. Referanselistene og de siterende arbeidene følges bare
// for kilder kildeoppdagelsen selv har valgt ut (`seeds`). Hver metode leser et
// svar og gir et registrerbart søk — med endepunkt, søkestreng, treffantall og
// avtrykk — og ingenting annet.
//
// ----------------------------------------------------------------------------
// Språket i søket
//
// Avgrensningsaksene (indikasjon, utfall, populasjon) er norske katalog-
// etiketter. Mot et engelskspråklig register ville «depressiv lidelse» gitt null
// treff, og null treff for et søk i feil språk er ikke et kontrollert nullsøk —
// det ville sett ut som dekning. De nye metodene søker derfor på virkestoffet
// med katalogens synonymer og på termene kildeoppdagelsen selv ber om; de
// bibliografiske fritekstsøkene bruker aksene som før.
// ============================================================================

import { FEST_MAX_BYTES, FEST_URL, readFestSubstance, readZip } from './fest.ts'
import {
  catalogEntry,
  SEARCH_METHOD_CATALOG,
  type SearchMethodEntry,
} from './search-method-catalog.ts'
import {
  buildQueries,
  CROSSREF,
  digest,
  EUROPE_PMC,
  PAGE_SIZE,
  PUBMED,
  runQuery,
  runSearch,
  text,
  trimmed,
  unreachable,
  unreadable,
  year,
  type CandidateSource,
  type Fetcher,
  type MachineSearch,
  type SearchPlatform,
  type SearchScope,
} from './monograph-search.ts'

/** Det én metode trenger for å utføre en runde. */
export interface MethodInput {
  readonly scope: SearchScope
  readonly profileCode: string
  readonly strategy: 'broad' | 'targeted'
  readonly queryTerms: readonly string[]
  /** Katalogens og forespørselens synonymer, samlet. */
  readonly drugAliases: readonly string[]
  /** Kildene som skal følges, som «doi:…», «pmid:…» eller «pmcid:…». */
  readonly seeds: readonly string[]
  /** Sporene runden kan erklære. */
  readonly allowedTracks: readonly string[]
  readonly fetcher: Fetcher
  /** Kjøringens eget minne, for datasett som leses av mange planer. */
  readonly memo: Map<string, unknown>
  readonly now: Date
}

/** En katalogoppføring med koden som utfører den. */
export interface SearchMethod extends SearchMethodEntry {
  readonly execute: (input: MethodInput) => Promise<readonly MachineSearch[]>
}

/**
 * Sporene et søk med denne metoden kan erklære: skjæringen mellom det runden
 * fikk lov til, og det metoden dekker for profilen. Databasen håndhever den
 * samme skjæringen på raden; her faller feilen til den trygge siden.
 */
export function declaredTracks(
  method: Pick<SearchMethod, 'coverage'>,
  allowedTracks: readonly string[],
  profileCode: string,
): readonly string[] {
  return method.coverage
    .filter((entry) => entry.profiles === null || entry.profiles.includes(profileCode))
    .map((entry) => entry.track)
    .filter((track) => allowedTracks.includes(track))
}

function drugOnly(input: MethodInput): SearchScope {
  return { drug: input.scope.drug }
}

function drugNames(input: MethodInput): readonly string[] {
  return [
    ...new Set(
      [input.scope.drug, ...input.drugAliases]
        .map((name) => name.trim())
        .filter((name) => name.length > 0),
    ),
  ]
}

const TIMEOUT_MS = 30_000

// ----------------------------------------------------------------------------
// 1. De bibliografiske fritekstsøkene — som før
// ----------------------------------------------------------------------------

function keyword(platform: SearchPlatform): SearchMethod {
  return {
    ...catalogEntry(platform.name, 'keyword'),
    execute: async (input) => {
      const queries = buildQueries(input.scope, input.strategy, input.queryTerms, input.drugAliases)
      const searches: MachineSearch[] = []
      for (const query of queries) {
        searches.push(await runSearch(platform, query, input.fetcher, input.allowedTracks))
      }
      return searches
    },
  }
}

// ----------------------------------------------------------------------------
// 2. De filtrerte litteratursøkene: samme endepunkt, et annet søk
// ----------------------------------------------------------------------------

const PUBMED_ENDPOINT = catalogEntry('PubMed', 'keyword').endpointBase
const EUROPE_PMC_SEARCH = catalogEntry('Europe PMC', 'keyword').endpointBase

interface FilterDefinition {
  readonly method: string
  /** Leddet som legges til søkestrengen, ordrett slik tjenesten leser det. */
  readonly filter: string | null
  /** Ekstra parametere til endepunktet, beregnet av tidspunktet. */
  readonly parameters?: (now: Date) => Readonly<Record<string, string>>
  readonly filterNote: (now: Date) => string
  readonly discoveryPath: string
}

/** Vinduet oppdateringssøket gjelder: de tre siste hele årene og inneværende år. */
export function updateWindow(now: Date): { readonly from: number; readonly to: number } {
  const to = now.getUTCFullYear()
  return { from: to - 3, to }
}

export const PUBMED_FILTERS: readonly FilterDefinition[] = [
  {
    method: 'systematic_review_filter',
    filter: 'systematic[sb]',
    filterNote: () => 'NLMs filter for systematiske oversikter: systematic[sb]',
    discoveryPath: 'PubMed, søk med NLMs filter for systematiske oversikter',
  },
  {
    method: 'observational_filter',
    filter:
      '("observational study"[pt] OR "cohort studies"[mh] OR "case-control studies"[mh] OR "registries"[mh] OR "pharmacovigilance"[mh] OR "adverse drug reaction reporting systems"[mh] OR "drug-related side effects and adverse reactions"[mh])',
    filterNote: () =>
      'Observasjonelle design og legemiddelovervåking: observasjonsstudie, kohort, kasus-kontroll, register, legemiddelovervåking, meldesystem, bivirkninger',
    discoveryPath: 'PubMed, målrettet søk etter observasjons- og sikkerhetsdata',
  },
  {
    method: 'human_primary_filter',
    filter: '(humans[mh] NOT (review[pt] OR systematic[sb] OR "meta-analysis"[pt]))',
    filterNote: () => 'Humane studier, uten oversikter, systematiske oversikter og metaanalyser',
    discoveryPath: 'PubMed, målrettet søk etter humane originalstudier',
  },
  {
    method: 'guideline_filter',
    filter:
      '(guideline[pt] OR "practice guideline"[pt] OR "consensus development conference"[pt] OR consensus[ti])',
    filterNote: () =>
      'Retningslinjer og konsensusdokumenter: guideline, practice guideline, consensus',
    discoveryPath: 'PubMed, søk etter publiserte retningslinjer og konsensusdokumenter',
  },
  {
    method: 'update_window',
    filter: null,
    parameters: (now) => {
      const window = updateWindow(now)
      return { datetype: 'pdat', mindate: String(window.from), maxdate: String(window.to) }
    },
    filterNote: (now) => {
      const window = updateWindow(now)
      return `Oppdateringsvindu: publisert ${window.from}–${window.to} (datetype=pdat)`
    },
    discoveryPath: 'PubMed, oppdateringssøk etter nye eller motstridende studier',
  },
]

function pubmedFilter(definition: FilterDefinition): SearchMethod {
  const entry = catalogEntry('PubMed', definition.method)
  return {
    ...entry,
    execute: async (input) => {
      const tracks = declaredTracks(entry, input.allowedTracks, input.profileCode)
      const queries = buildQueries(
        drugOnly(input),
        input.strategy,
        input.queryTerms,
        input.drugAliases,
      )
      const extra = definition.parameters?.(input.now) ?? {}
      const searches: MachineSearch[] = []
      for (const query of queries) {
        const term = definition.filter === null ? query : `(${query}) AND ${definition.filter}`
        const parameters = new URLSearchParams({
          db: 'pubmed',
          term,
          retmode: 'json',
          retmax: String(PAGE_SIZE),
          ...extra,
        })
        searches.push(
          await runQuery(
            {
              platform: 'PubMed',
              method: definition.method,
              queryString: term,
              filters: `${definition.filterNote(input.now)}; retmax=${PAGE_SIZE}`,
              endpoint: `${PUBMED_ENDPOINT}?${parameters.toString()}`,
              parse: PUBMED.parse,
              trackCodes: tracks,
              discoveryPath: definition.discoveryPath,
            },
            input.fetcher,
          ),
        )
      }
      return searches
    },
  }
}

const EUROPE_PMC_SYSTEMATIC_REVIEWS: SearchMethod = {
  ...catalogEntry('Europe PMC', 'systematic_review_filter'),
  execute: async (input) => {
    const tracks = declaredTracks(
      EUROPE_PMC_SYSTEMATIC_REVIEWS,
      input.allowedTracks,
      input.profileCode,
    )
    const queries = buildQueries(
      drugOnly(input),
      input.strategy,
      input.queryTerms,
      input.drugAliases,
    )
    const searches: MachineSearch[] = []
    for (const query of queries) {
      const term = `(${query}) AND PUB_TYPE:"systematic-review"`
      searches.push(
        await runQuery(
          {
            platform: 'Europe PMC',
            method: 'systematic_review_filter',
            queryString: term,
            filters: `Publikasjonstype: systematisk oversikt (PUB_TYPE:"systematic-review"); pageSize=${PAGE_SIZE}`,
            endpoint: EUROPE_PMC.endpoint(term),
            parse: EUROPE_PMC.parse,
            trackCodes: tracks,
            discoveryPath: 'Europe PMC, søk avgrenset til systematiske oversikter',
          },
          input.fetcher,
        ),
      )
    }
    return searches
  },
}

// ----------------------------------------------------------------------------
// 3. ClinicalTrials.gov
// ----------------------------------------------------------------------------

export const CLINICAL_TRIALS_ENDPOINT = catalogEntry(
  'ClinicalTrials.gov',
  'registry_search',
).endpointBase
export const CLINICAL_TRIALS_PAGE_SIZE = 100
export const CLINICAL_TRIALS_MAX_PAGES = 3

function trialCandidates(payload: Record<string, unknown>): {
  readonly rows: number
  readonly candidates: CandidateSource[]
} {
  const studies = Array.isArray(payload['studies']) ? (payload['studies'] as unknown[]) : []
  const candidates: CandidateSource[] = []
  for (const entry of studies) {
    const protocol = ((entry as Record<string, unknown>)['protocolSection'] ?? {}) as Record<
      string,
      Record<string, unknown>
    >
    const identification = protocol['identificationModule'] ?? {}
    const nct = trimmed(identification['nctId'])
    const title = trimmed(identification['briefTitle']) ?? trimmed(identification['officialTitle'])
    if (nct === undefined || title === undefined || !/^NCT[0-9]{8}$/.test(nct)) continue
    const status = protocol['statusModule'] ?? {}
    const sponsor = (protocol['sponsorCollaboratorsModule'] ?? {})['leadSponsor'] as
      Record<string, unknown> | undefined
    const start = (status['startDateStruct'] as Record<string, unknown> | undefined)?.['date']
    const hasResults = (entry as Record<string, unknown>)['hasResults'] === true
    candidates.push({
      identifier_kind: 'registry_id',
      identifier_value: nct,
      title,
      authors_or_issuer: trimmed(sponsor?.['name']),
      publisher_or_journal: 'ClinicalTrials.gov',
      publication_year: year(start),
      discovery_path: `ClinicalTrials.gov, søk gjennom API v2 (status: ${String(status['overallStatus'] ?? 'ukjent')}${hasResults ? ', resultater registrert' : ''})`,
      access_limited: false,
    })
  }
  return { rows: studies.length, candidates }
}

const CLINICAL_TRIALS: SearchMethod = {
  ...catalogEntry('ClinicalTrials.gov', 'registry_search'),
  execute: async (input) => {
    const tracks = declaredTracks(CLINICAL_TRIALS, input.allowedTracks, input.profileCode)
    const intervention = drugNames(input).join(' OR ')
    // Én passering for virkestoffet alene i den brede strategien, og én per
    // term leddet ba om i den målrettede.
    const terms =
      input.strategy === 'broad'
        ? [
            input.queryTerms
              .map((term) => term.trim())
              .filter((term) => term.length > 0)
              .join(' OR '),
          ]
        : input.queryTerms.map((term) => term.trim()).filter((term) => term.length > 0)
    const passes = terms.length === 0 ? [''] : terms
    const searches: MachineSearch[] = []

    for (const term of passes) {
      const parameters = new URLSearchParams({
        'query.intr': intervention,
        pageSize: String(CLINICAL_TRIALS_PAGE_SIZE),
        countTotal: 'true',
        fields: 'NCTId,BriefTitle,OfficialTitle,OverallStatus,StartDate,LeadSponsorName,HasResults',
      })
      if (term.length > 0) parameters.set('query.term', term)
      const endpoint = `${CLINICAL_TRIALS_ENDPOINT}?${parameters.toString()}`
      const queryString = `intervensjon: ${intervention}${term.length > 0 ? `; term: ${term}` : ''}`
      const base = {
        platform: 'ClinicalTrials.gov',
        method: 'registry_search',
        queryString,
        filters: `pageSize=${CLINICAL_TRIALS_PAGE_SIZE}; høyst ${CLINICAL_TRIALS_MAX_PAGES} sider`,
        endpoint,
        screenedCount: 0,
        truncated: false,
        truncationNote: null,
        trackCodes: tracks,
        candidates: [] as readonly CandidateSource[],
      }

      const pages: Uint8Array[] = []
      const candidates: CandidateSource[] = []
      let rowsRead = 0
      let total: number | null = null
      let token: string | null = null
      let stoppedEarly: string | null = null

      for (let page = 0; page < CLINICAL_TRIALS_MAX_PAGES; page += 1) {
        const url = token === null ? endpoint : `${endpoint}&pageToken=${encodeURIComponent(token)}`
        const response = await input.fetcher(url, {
          timeoutMs: TIMEOUT_MS,
          maxBytes: 8 * 1024 * 1024,
        })
        if (
          response.status === 'error' ||
          response.httpStatus < 200 ||
          response.httpStatus >= 300
        ) {
          if (page === 0) {
            searches.push(
              response.status === 'error'
                ? unreachable(base, `Søkeveien svarte ikke: ${response.message}`)
                : unreachable(
                    { ...base, responseDigest: digest(response.bytes) },
                    `Søkeveien svarte med HTTP ${response.httpStatus}.`,
                  ),
            )
          } else {
            // En side som ikke kom, etter en som gjorde det, er en avkortet
            // treffliste og ikke en fullstendig: resten er ikke lest.
            stoppedEarly = `side ${page + 1} svarte ikke`
          }
          break
        }
        pages.push(response.bytes)
        let payload: Record<string, unknown>
        try {
          payload = JSON.parse(text(response.bytes)) as Record<string, unknown>
        } catch (error) {
          if (page === 0) {
            searches.push(
              unreadable(
                { ...base, responseDigest: digest(response.bytes) },
                `Svaret lot seg ikke lese: ${error instanceof Error ? error.message : 'ukjent form'}.`,
              ),
            )
          } else {
            stoppedEarly = `side ${page + 1} lot seg ikke lese`
          }
          break
        }
        if (page === 0) {
          const counted = Number(payload['totalCount'])
          total = Number.isInteger(counted) && counted >= 0 ? counted : null
        }
        const read = trialCandidates(payload)
        rowsRead += read.rows
        candidates.push(...read.candidates)
        token = trimmed(payload['nextPageToken']) ?? null
        if (token === null) break
      }

      if (pages.length === 0) continue
      const resultCount = total ?? rowsRead
      // Avkortet når ikke hele trefflisten er lest — fordi grensen for sider
      // ble nådd, eller fordi en side underveis ikke kom. En side som ikke kom,
      // gjør aldri en delvis liste til en fullstendig.
      const truncated = rowsRead < resultCount || stoppedEarly !== null
      searches.push({
        ...base,
        responseDigest: digest(pages),
        outcome: resultCount === 0 ? 'zero_results' : 'executed',
        resultCount,
        screenedCount: rowsRead,
        truncated,
        truncationNote: truncated
          ? `Trefflisten er avkortet: ${resultCount} studier totalt, ${rowsRead} lest${stoppedEarly === null ? ` på ${pages.length} side(r)` : ` før ${stoppedEarly}`}.`
          : null,
        limitationNote: null,
        candidates,
      })
    }
    return searches
  },
}

// ----------------------------------------------------------------------------
// 4. Å følge de sentrale kildene: referanser og siterende arbeider
// ----------------------------------------------------------------------------

const EUROPE_PMC_REST = catalogEntry('Europe PMC', 'references').endpointBase
export const CHASE_PAGE_SIZE = 1_000
export const CHASE_MAX_PAGES = 2

/** Kilden i Europe PMCs egne koordinater, eller null når Europe PMC ikke har den. */
export async function resolveEuropePmc(
  seed: string,
  fetcher: Fetcher,
): Promise<
  | { readonly status: 'found'; readonly source: string; readonly id: string }
  | { readonly status: 'missing' }
  | { readonly status: 'unavailable'; readonly note: string }
> {
  const [kind, ...rest] = seed.split(':')
  const value = rest.join(':')
  if (kind === 'pmid') return { status: 'found', source: 'MED', id: value }
  if (kind === 'pmcid') return { status: 'found', source: 'PMC', id: value }
  const endpoint = `${EUROPE_PMC_SEARCH}?query=${encodeURIComponent(`DOI:"${value}"`)}&format=json&resultType=lite&pageSize=1`
  const response = await fetcher(endpoint, { timeoutMs: TIMEOUT_MS, maxBytes: 1024 * 1024 })
  if (response.status === 'error') {
    return {
      status: 'unavailable',
      note: `Europe PMC svarte ikke på oppslaget av kilden: ${response.message}`,
    }
  }
  if (response.httpStatus < 200 || response.httpStatus >= 300) {
    return {
      status: 'unavailable',
      note: `Europe PMC svarte med HTTP ${response.httpStatus} på oppslaget av kilden.`,
    }
  }
  try {
    const payload = JSON.parse(text(response.bytes)) as Record<string, unknown>
    const list = (payload['resultList'] as Record<string, unknown> | undefined)?.['result']
    const first = Array.isArray(list) ? (list[0] as Record<string, unknown> | undefined) : undefined
    const source = trimmed(first?.['source'])
    const id = trimmed(first?.['id'])
    return source === undefined || id === undefined
      ? { status: 'missing' }
      : { status: 'found', source, id }
  } catch {
    return { status: 'unavailable', note: 'Oppslaget av kilden i Europe PMC lot seg ikke lese.' }
  }
}

function europePmcEntryCandidate(
  row: Record<string, unknown>,
  path: string,
): CandidateSource | null {
  const title = trimmed(row['title'])
  const source = trimmed(row['source'])
  const id = trimmed(row['id'])
  const doi = trimmed(row['doi'])
  if (title === undefined) return null
  const identifier: Pick<CandidateSource, 'identifier_kind' | 'identifier_value'> | null =
    doi !== undefined
      ? { identifier_kind: 'doi', identifier_value: doi }
      : source === 'MED' && id !== undefined && /^[0-9]{1,9}$/.test(id)
        ? { identifier_kind: 'pmid', identifier_value: id }
        : source === 'PMC' && id !== undefined && /^PMC[0-9]{1,9}$/.test(id)
          ? { identifier_kind: 'pmcid', identifier_value: id }
          : null
  if (identifier === null) return null
  return {
    ...identifier,
    title,
    authors_or_issuer: trimmed(row['authorString']),
    publisher_or_journal: trimmed(row['journalAbbreviation']) ?? trimmed(row['journalTitle']),
    publication_year: year(row['pubYear']),
    discovery_path: path,
    access_limited: true,
    access_limitation_note: 'Funnet ved å følge en sentral kilde. Tilgangen er ikke avklart.',
  }
}

function europePmcChase(direction: 'references' | 'citations'): SearchMethod {
  const method: SearchMethod = {
    ...catalogEntry('Europe PMC', direction),
    execute: async (input) => {
      const tracks = declaredTracks(method, input.allowedTracks, input.profileCode)
      const listKey = direction === 'references' ? 'referenceList' : 'citationList'
      const itemKey = direction === 'references' ? 'reference' : 'citation'
      const searches: MachineSearch[] = []

      for (const seed of input.seeds) {
        const queryString =
          direction === 'references'
            ? `Referanselisten til ${seed}`
            : `Arbeider som siterer ${seed}`
        const resolved = await resolveEuropePmc(seed, input.fetcher)
        const base = {
          platform: 'Europe PMC',
          method: direction,
          queryString,
          filters: `pageSize=${CHASE_PAGE_SIZE}; høyst ${CHASE_MAX_PAGES} sider`,
          endpoint: `${EUROPE_PMC_REST}/search?query=${encodeURIComponent(seed)}`,
          screenedCount: 0,
          truncated: false,
          truncationNote: null,
          trackCodes: tracks,
          candidates: [] as readonly CandidateSource[],
        }
        if (resolved.status === 'unavailable') {
          searches.push(unreachable(base, resolved.note))
          continue
        }
        if (resolved.status === 'missing') {
          searches.push(
            unreachable(
              base,
              `Kilden ${seed} finnes ikke i Europe PMC, og ${direction === 'references' ? 'referanselisten' : 'de siterende arbeidene'} kan ikke hentes der.`,
            ),
          )
          continue
        }

        const endpoint = `${EUROPE_PMC_REST}/${resolved.source}/${encodeURIComponent(resolved.id)}/${direction}?format=json&pageSize=${CHASE_PAGE_SIZE}`
        const pages: Uint8Array[] = []
        const candidates: CandidateSource[] = []
        let rowsRead = 0
        let total: number | null = null
        let stoppedEarly: string | null = null
        let failure: MachineSearch | null = null
        const path = `Europe PMC, ${direction === 'references' ? 'referanselisten til' : 'arbeider som siterer'} ${seed}`

        for (let page = 1; page <= CHASE_MAX_PAGES; page += 1) {
          const response = await input.fetcher(`${endpoint}&page=${page}`, {
            timeoutMs: TIMEOUT_MS,
            maxBytes: 8 * 1024 * 1024,
          })
          if (
            response.status === 'error' ||
            response.httpStatus < 200 ||
            response.httpStatus >= 300
          ) {
            if (page === 1) {
              failure =
                response.status === 'error'
                  ? unreachable({ ...base, endpoint }, `Søkeveien svarte ikke: ${response.message}`)
                  : unreachable(
                      { ...base, endpoint, responseDigest: digest(response.bytes) },
                      `Søkeveien svarte med HTTP ${response.httpStatus}.`,
                    )
            } else {
              stoppedEarly = `side ${page} svarte ikke`
            }
            break
          }
          pages.push(response.bytes)
          let payload: Record<string, unknown>
          try {
            payload = JSON.parse(text(response.bytes)) as Record<string, unknown>
          } catch (error) {
            if (page === 1) {
              failure = unreadable(
                { ...base, endpoint, responseDigest: digest(response.bytes) },
                `Svaret lot seg ikke lese: ${error instanceof Error ? error.message : 'ukjent form'}.`,
              )
            } else {
              stoppedEarly = `side ${page} lot seg ikke lese`
            }
            break
          }
          if (page === 1) {
            const counted = Number(payload['hitCount'])
            total = Number.isInteger(counted) && counted >= 0 ? counted : null
          }
          const items = (payload[listKey] as Record<string, unknown> | undefined)?.[itemKey]
          const rows = Array.isArray(items) ? (items as Record<string, unknown>[]) : []
          rowsRead += rows.length
          for (const row of rows) {
            const candidate = europePmcEntryCandidate(row, path)
            if (candidate !== null) candidates.push(candidate)
          }
          if (total === null || page * CHASE_PAGE_SIZE >= total || rows.length === 0) break
        }

        if (failure !== null) {
          searches.push(failure)
          continue
        }
        const resultCount = total ?? rowsRead
        // En kilde uten registrert referanseliste er ikke en kilde uten
        // referanser. Null referanser er en begrensning i Europe PMC og ikke et
        // kontrollert nullsøk. Null siterende arbeider er derimot et resultat:
        // ingen i Europe PMC siterer kilden på søketidspunktet.
        if (direction === 'references' && resultCount === 0) {
          searches.push(
            unreachable(
              { ...base, endpoint, responseDigest: digest(pages) },
              `Europe PMC har ingen referanseliste registrert for ${seed}. Det er en begrensning i kilden, ikke null referanser.`,
            ),
          )
          continue
        }
        const truncated = rowsRead < resultCount || stoppedEarly !== null
        searches.push({
          ...base,
          endpoint,
          responseDigest: digest(pages),
          outcome: resultCount === 0 ? 'zero_results' : 'executed',
          resultCount,
          screenedCount: rowsRead,
          truncated,
          truncationNote: truncated
            ? `Listen er avkortet: ${resultCount} totalt, ${rowsRead} lest${stoppedEarly === null ? '' : ` før ${stoppedEarly}`}.`
            : null,
          limitationNote: null,
          candidates,
        })
      }
      return searches
    },
  }
  return method
}

const CROSSREF_WORKS = catalogEntry('Crossref', 'references').endpointBase

const CROSSREF_REFERENCES: SearchMethod = {
  ...catalogEntry('Crossref', 'references'),
  execute: async (input) => {
    const tracks = declaredTracks(CROSSREF_REFERENCES, input.allowedTracks, input.profileCode)
    const searches: MachineSearch[] = []
    for (const seed of input.seeds.filter((value) => value.startsWith('doi:'))) {
      const doi = seed.slice('doi:'.length)
      const endpoint = `${CROSSREF_WORKS}/${encodeURIComponent(doi)}`
      const base = {
        platform: 'Crossref',
        method: 'references',
        queryString: `Referanselisten til ${seed}`,
        filters: 'Referansene utgiveren har deponert',
        endpoint,
        screenedCount: 0,
        truncated: false,
        truncationNote: null,
        trackCodes: tracks,
        candidates: [] as readonly CandidateSource[],
      }
      const response = await input.fetcher(endpoint, {
        timeoutMs: TIMEOUT_MS,
        maxBytes: 8 * 1024 * 1024,
      })
      if (response.status === 'error') {
        searches.push(unreachable(base, `Søkeveien svarte ikke: ${response.message}`))
        continue
      }
      if (response.httpStatus === 404) {
        searches.push(
          unreachable(
            { ...base, responseDigest: digest(response.bytes) },
            `DOI-en ${doi} finnes ikke i Crossref, og referanselisten kan ikke hentes der.`,
          ),
        )
        continue
      }
      if (response.httpStatus < 200 || response.httpStatus >= 300) {
        searches.push(
          unreachable(
            { ...base, responseDigest: digest(response.bytes) },
            `Søkeveien svarte med HTTP ${response.httpStatus}.`,
          ),
        )
        continue
      }
      let references: Record<string, unknown>[]
      try {
        const payload = JSON.parse(text(response.bytes)) as Record<string, unknown>
        const message = payload['message'] as Record<string, unknown> | undefined
        references = Array.isArray(message?.['reference'])
          ? (message['reference'] as Record<string, unknown>[])
          : []
      } catch (error) {
        searches.push(
          unreadable(
            { ...base, responseDigest: digest(response.bytes) },
            `Svaret lot seg ikke lese: ${error instanceof Error ? error.message : 'ukjent form'}.`,
          ),
        )
        continue
      }
      if (references.length === 0) {
        searches.push(
          unreachable(
            { ...base, responseDigest: digest(response.bytes) },
            `Utgiveren har ikke deponert en referanseliste for ${seed} i Crossref. Det er en begrensning i kilden, ikke null referanser.`,
          ),
        )
        continue
      }
      const candidates: CandidateSource[] = []
      for (const reference of references) {
        const referenceDoi = trimmed(reference['DOI'])
        if (referenceDoi === undefined) continue
        const title =
          trimmed(reference['article-title']) ??
          trimmed(reference['unstructured'])?.slice(0, 1_000) ??
          `Referanse ${referenceDoi}`
        candidates.push({
          identifier_kind: 'doi',
          identifier_value: referenceDoi,
          title,
          authors_or_issuer: trimmed(reference['author']),
          publisher_or_journal: trimmed(reference['journal-title']),
          publication_year: year(reference['year']),
          discovery_path: `Crossref, referanselisten utgiveren har deponert for ${seed}`,
          access_limited: true,
          access_limitation_note: 'Funnet ved å følge en sentral kilde. Tilgangen er ikke avklart.',
        })
      }
      searches.push({
        ...base,
        responseDigest: digest(response.bytes),
        outcome: 'executed',
        resultCount: references.length,
        screenedCount: references.length,
        truncated: false,
        truncationNote: null,
        // Referanser uten DOI er lest, men har ingen identitet Antidep kan slå
        // opp; det står her framfor å forsvinne.
        limitationNote: null,
        candidates,
      })
    }
    return searches
  },
}

// ----------------------------------------------------------------------------
// 5. EMA: de regulatoriske datasettene
// ----------------------------------------------------------------------------

export const EMA_REPORTS = catalogEntry('EMA', 'regulatory_data').endpointBase

interface EmaDataset {
  readonly file: string
  readonly label: string
  readonly substanceFields: readonly string[]
  readonly urlField: string
  readonly title: (row: Record<string, unknown>) => string
}

export const EMA_DATASETS: readonly EmaDataset[] = [
  {
    file: 'medicines-output-periodic_safety_update_report_single_assessments-output-json-report_en.json',
    label: 'periodiske sikkerhetsvurderinger (PSUSA)',
    substanceFields: ['active_substance', 'active_substances_in_scope_of_procedure'],
    urlField: 'psusa_url',
    title: (row) =>
      `EMA PSUSA ${String(row['procedure_number'] ?? '')}: ${String(row['active_substances_in_scope_of_procedure'] ?? row['active_substance'] ?? '')} — ${String(row['regulatory_outcome'] ?? 'utfall ikke oppgitt')}`,
  },
  {
    file: 'referrals-output-json-report_en.json',
    label: 'referrals',
    substanceFields: ['international_non_proprietary_name_inn_common_name', 'referral_name'],
    urlField: 'referral_url',
    title: (row) =>
      `EMA referral: ${String(row['referral_name'] ?? '')} (${String(row['referral_type'] ?? '')}, ${String(row['current_status'] ?? '')})`,
  },
  {
    file: 'dhpc-output-json-report_en.json',
    label: 'direkte helsepersonellbrev (DHPC)',
    substanceFields: ['active_substances', 'name_of_medicine'],
    urlField: 'dhpc_url',
    title: (row) =>
      `EMA DHPC: ${String(row['name_of_medicine'] ?? '')} — ${String(row['dhpc_type'] ?? '')}`,
  },
  {
    file: 'shortages-output-json-report_en.json',
    label: 'legemiddelmangel',
    substanceFields: ['international_non_proprietary_name_inn_or_common_name', 'medicine_affected'],
    urlField: 'shortage_url',
    title: (row) =>
      `EMA mangel: ${String(row['medicine_affected'] ?? '')} (${String(row['supply_shortage_status'] ?? '')})`,
  },
]

/** Om et felt nevner virkestoffet som et eget ord, uavhengig av store og små bokstaver. */
export function mentionsSubstance(value: unknown, names: readonly string[]): boolean {
  const haystack = String(value ?? '').toLowerCase()
  return names.some((name) => {
    const needle = name.toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    return new RegExp(`(^|[^a-z0-9æøå])${needle}($|[^a-z0-9æøå])`).test(haystack)
  })
}

function emaDate(value: unknown): number | undefined {
  const match = /(\d{2})\/(\d{2})\/(\d{4})/.exec(String(value ?? ''))
  return match === null ? undefined : year(match[3])
}

const EMA_REGULATORY_DATA: SearchMethod = {
  ...catalogEntry('EMA', 'regulatory_data'),
  execute: async (input) => {
    const tracks = declaredTracks(EMA_REGULATORY_DATA, input.allowedTracks, input.profileCode)
    const names = drugNames(input)
    const searches: MachineSearch[] = []
    for (const dataset of EMA_DATASETS) {
      const endpoint = `${EMA_REPORTS}/${dataset.file}`
      const queryString = `EMA ${dataset.label}: virkestoff ${names.join(' | ')}`
      const base = {
        platform: 'EMA',
        method: 'regulatory_data',
        queryString,
        filters: `Felter: ${dataset.substanceFields.join(', ')}; hele datasettet leses`,
        endpoint,
        screenedCount: 0,
        truncated: false,
        truncationNote: null,
        trackCodes: tracks,
        candidates: [] as readonly CandidateSource[],
      }
      const response = await input.fetcher(endpoint, {
        timeoutMs: 60_000,
        maxBytes: 32 * 1024 * 1024,
      })
      if (response.status === 'error') {
        searches.push(unreachable(base, `Søkeveien svarte ikke: ${response.message}`))
        continue
      }
      if (response.httpStatus < 200 || response.httpStatus >= 300) {
        searches.push(
          unreachable(
            { ...base, responseDigest: digest(response.bytes) },
            `Søkeveien svarte med HTTP ${response.httpStatus}.`,
          ),
        )
        continue
      }
      let rows: Record<string, unknown>[]
      try {
        const payload = JSON.parse(text(response.bytes)) as Record<string, unknown>
        if (!Array.isArray(payload['data'])) throw new Error('datasettet har ingen «data»-liste')
        rows = payload['data'] as Record<string, unknown>[]
      } catch (error) {
        searches.push(
          unreadable(
            { ...base, responseDigest: digest(response.bytes) },
            `Svaret lot seg ikke lese: ${error instanceof Error ? error.message : 'ukjent form'}.`,
          ),
        )
        continue
      }
      const matched = rows.filter((row) =>
        dataset.substanceFields.some((field) => mentionsSubstance(row[field], names)),
      )
      const candidates: CandidateSource[] = []
      for (const row of matched) {
        const url = trimmed(row[dataset.urlField])
        if (url === undefined || !url.startsWith('https://')) continue
        candidates.push({
          identifier_kind: 'url',
          identifier_value: url,
          title: dataset.title(row).slice(0, 1_000),
          authors_or_issuer: 'European Medicines Agency',
          publisher_or_journal: 'EMA',
          publication_year: emaDate(row['first_published_date']),
          discovery_path: `EMA, datasettet for ${dataset.label}`,
          access_limited: false,
        })
      }
      searches.push({
        ...base,
        responseDigest: digest(response.bytes),
        outcome: matched.length === 0 ? 'zero_results' : 'executed',
        resultCount: matched.length,
        screenedCount: matched.length,
        truncated: false,
        truncationNote: null,
        limitationNote: null,
        candidates,
      })
    }
    return searches
  },
}

// ----------------------------------------------------------------------------
// 6. ClinPGx: de farmakogenetiske retningslinjene
// ----------------------------------------------------------------------------

export const CLINPGX_ENDPOINT = catalogEntry('ClinPGx', 'guideline_annotations').endpointBase

const CLINPGX: SearchMethod = {
  ...catalogEntry('ClinPGx', 'guideline_annotations'),
  execute: async (input) => {
    const tracks = declaredTracks(CLINPGX, input.allowedTracks, input.profileCode)
    const searches: MachineSearch[] = []
    for (const name of drugNames(input)) {
      const endpoint = `${CLINPGX_ENDPOINT}?${new URLSearchParams({ 'relatedChemicals.name': name, view: 'base' }).toString()}`
      const base = {
        platform: 'ClinPGx',
        method: 'guideline_annotations',
        queryString: `relatedChemicals.name = ${name}`,
        filters: 'Alle retningslinjeeiere ClinPGx annoterer (blant dem CPIC og DPWG)',
        endpoint,
        screenedCount: 0,
        truncated: false,
        truncationNote: null,
        trackCodes: tracks,
        candidates: [] as readonly CandidateSource[],
      }
      const response = await input.fetcher(endpoint, {
        timeoutMs: TIMEOUT_MS,
        maxBytes: 16 * 1024 * 1024,
      })
      if (response.status === 'error') {
        searches.push(unreachable(base, `Søkeveien svarte ikke: ${response.message}`))
        continue
      }
      let payload: Record<string, unknown>
      try {
        payload = JSON.parse(text(response.bytes)) as Record<string, unknown>
      } catch (error) {
        searches.push(
          response.httpStatus >= 200 && response.httpStatus < 300
            ? unreadable(
                { ...base, responseDigest: digest(response.bytes) },
                `Svaret lot seg ikke lese: ${error instanceof Error ? error.message : 'ukjent form'}.`,
              )
            : unreachable(
                { ...base, responseDigest: digest(response.bytes) },
                `Søkeveien svarte med HTTP ${response.httpStatus}.`,
              ),
        )
        continue
      }
      // ClinPGx svarer 404 med «No results matching criteria» når ingen
      // retningslinje nevner navnet. Det er et svar om saken — null treff — og
      // ikke en tjeneste som er nede. Enhver annen feilkode er en begrensning.
      const noMatch =
        response.httpStatus === 404 &&
        payload['status'] === 'fail' &&
        JSON.stringify(payload['data'] ?? '').includes('No results matching criteria')
      if (noMatch) {
        searches.push({
          ...base,
          responseDigest: digest(response.bytes),
          outcome: 'zero_results',
          resultCount: 0,
          limitationNote: null,
        })
        continue
      }
      if (
        response.httpStatus < 200 ||
        response.httpStatus >= 300 ||
        !Array.isArray(payload['data'])
      ) {
        searches.push(
          unreachable(
            { ...base, responseDigest: digest(response.bytes) },
            `Søkeveien svarte med HTTP ${response.httpStatus}.`,
          ),
        )
        continue
      }
      const rows = payload['data'] as Record<string, unknown>[]
      const candidates: CandidateSource[] = []
      for (const row of rows) {
        const id = trimmed(row['id'])
        const title = trimmed(row['name'])
        if (id === undefined || title === undefined || !/^PA[0-9]+$/.test(id)) continue
        candidates.push({
          identifier_kind: 'url',
          identifier_value: `https://www.clinpgx.org/guidelineAnnotation/${id}`,
          title,
          authors_or_issuer: trimmed(row['source']),
          publisher_or_journal: 'ClinPGx',
          discovery_path: 'ClinPGx, annoterte farmakogenetiske retningslinjer (API)',
          access_limited: false,
        })
      }
      searches.push({
        ...base,
        responseDigest: digest(response.bytes),
        outcome: rows.length === 0 ? 'zero_results' : 'executed',
        resultCount: rows.length,
        screenedCount: rows.length,
        truncated: false,
        truncationNote: null,
        limitationNote: null,
        candidates,
      })
    }
    return searches
  },
}

// ----------------------------------------------------------------------------
// 7. FEST: den norske myndighetskilden
// ----------------------------------------------------------------------------

const FEST_PRODUCT_REGISTER: SearchMethod = {
  ...catalogEntry('DMP FEST', 'product_register'),
  execute: async (input) => {
    const tracks = declaredTracks(FEST_PRODUCT_REGISTER, input.allowedTracks, input.profileCode)
    const atc = input.scope.atcCodes ?? []
    const queryString =
      atc.length > 0
        ? `ATC ${atc.join(', ')} (${input.scope.drug})`
        : `Virkestoff ${drugNames(input).join(' | ')} (ingen ATC-kode i katalogen)`
    const base = {
      platform: 'DMP FEST',
      method: 'product_register',
      queryString,
      filters:
        'FEST 2.5.1, rekvirentuttrekket; leser legemiddelmerkevarer, pakninger (markedsføring, midlertidig utgått, utgående varenummer) og DMPs varsler',
      endpoint: FEST_URL,
      screenedCount: 0,
      truncated: false,
      truncationNote: null,
      trackCodes: tracks,
      candidates: [] as readonly CandidateSource[],
    }

    const response = await input.fetcher(FEST_URL, { timeoutMs: 180_000, maxBytes: FEST_MAX_BYTES })
    if (response.status === 'error') {
      return [unreachable(base, `Søkeveien svarte ikke: ${response.message}`)]
    }
    if (response.httpStatus < 200 || response.httpStatus >= 300) {
      return [
        unreachable(
          { ...base, responseDigest: digest(response.bytes) },
          `Søkeveien svarte med HTTP ${response.httpStatus}.`,
        ),
      ]
    }
    const responseDigest = digest(response.bytes)

    // Filen er den samme for hver plan i kjøringen; den pakkes ut og leses én
    // gang. Nøkkelen er avtrykket, så en annen fil aldri kan leses som denne.
    const memoKey = `fest:${responseDigest}:${atc.join(',')}:${drugNames(input).join(',')}`
    let record: ReturnType<typeof readFestSubstance>
    try {
      const cached = input.memo.get(memoKey) as ReturnType<typeof readFestSubstance> | undefined
      if (cached !== undefined) {
        record = cached
      } else {
        const entry = readZip(response.bytes).find((file) =>
          file.name.toLowerCase().endsWith('.xml'),
        )
        if (entry === undefined) throw new Error('arkivet har ingen XML-fil')
        record = readFestSubstance(text(entry.bytes), atc, drugNames(input))
        input.memo.set(memoKey, record)
      }
    } catch (error) {
      return [
        unreadable(
          { ...base, responseDigest },
          `FEST-filen lot seg ikke lese: ${error instanceof Error ? error.message : 'ukjent form'}.`,
        ),
      ]
    }

    const candidates: CandidateSource[] = []
    const bySmpc = new Map<string, { names: Set<string>; manufacturers: Set<string> }>()
    for (const product of record.products) {
      for (const url of product.smpcUrls) {
        const entry = bySmpc.get(url) ?? {
          names: new Set<string>(),
          manufacturers: new Set<string>(),
        }
        entry.names.add(product.nameFormStrength)
        if (product.manufacturer !== null) entry.manufacturers.add(product.manufacturer)
        bySmpc.set(url, entry)
      }
    }
    for (const [url, entry] of bySmpc) {
      candidates.push({
        identifier_kind: 'url',
        identifier_value: url,
        title: `Preparatomtale (SPC): ${[...entry.names].sort().join('; ')}`.slice(0, 1_000),
        authors_or_issuer: [...entry.manufacturers].sort().join(', ') || undefined,
        publisher_or_journal: 'Direktoratet for medisinske produkter',
        publication_year: year(record.retrievedAt),
        discovery_path: `DMP FEST (hentet ${record.retrievedAt}), lenken til gjeldende preparatomtale`,
        access_limited: false,
      })
    }
    for (const notice of record.notices) {
      candidates.push({
        identifier_kind: notice.url !== null && notice.url.startsWith('https://') ? 'url' : 'title',
        identifier_value:
          notice.url !== null && notice.url.startsWith('https://')
            ? notice.url
            : `DMP-varsel: ${notice.heading}`.slice(0, 500),
        title: `DMP-varsel (${notice.kind}): ${notice.heading}`.slice(0, 1_000),
        authors_or_issuer: 'Direktoratet for medisinske produkter',
        publisher_or_journal: 'FEST',
        publication_year: year(notice.from),
        discovery_path: `DMP FEST (hentet ${record.retrievedAt}), varsel om ${notice.kind.toLowerCase()} for preparatene`,
        access_limited: false,
      })
    }

    const unavailable = record.packages.filter((pack) => pack.temporarilyUnavailableFrom !== null)
    const exempted = record.products.filter((product) => /fritak/i.test(product.productType))
    return [
      {
        ...base,
        filters: `${base.filters}; FEST hentet ${record.retrievedAt}; ${record.packages.length} pakninger, ${unavailable.length} midlertidig utgått, ${exempted.length} uregistrerte med godkjenningsfritak, ${record.notices.length} varsler`,
        responseDigest,
        outcome: record.products.length === 0 ? 'zero_results' : 'executed',
        resultCount: record.products.length,
        screenedCount: record.products.length,
        truncated: false,
        truncationNote: null,
        limitationNote: null,
        candidates,
      },
    ]
  },
}

// ----------------------------------------------------------------------------
// Registeret
// ----------------------------------------------------------------------------

const EXECUTORS: readonly SearchMethod[] = [
  keyword(EUROPE_PMC),
  keyword(PUBMED),
  keyword(CROSSREF),
  ...PUBMED_FILTERS.map(pubmedFilter),
  EUROPE_PMC_SYSTEMATIC_REVIEWS,
  europePmcChase('references'),
  europePmcChase('citations'),
  CROSSREF_REFERENCES,
  CLINICAL_TRIALS,
  FEST_PRODUCT_REGISTER,
  EMA_REGULATORY_DATA,
  CLINPGX,
]

/**
 * Hver søkemetode i katalogen, med koden som utfører den — i katalogens egen
 * rekkefølge. En katalogoppføring uten kode ville vært en evne ingen har; en
 * prøve holder de to listene like.
 */
export const SEARCH_METHODS: readonly SearchMethod[] = SEARCH_METHOD_CATALOG.flatMap((entry) =>
  EXECUTORS.filter(
    (executor) => executor.platform === entry.platform && executor.method === entry.method,
  ),
)

/** Metoden med dette navnet på denne plattformen, eller undefined. */
export function findMethod(platform: string, method: string): SearchMethod | undefined {
  return SEARCH_METHODS.find((entry) => entry.platform === platform && entry.method === method)
}

/** Kodene som finnes, uavhengig av katalogen. Bare for prøven som holder dem like. */
export const EXECUTOR_KEYS: readonly string[] = EXECUTORS.map(
  (executor) => `${executor.platform}|${executor.method}`,
)

/**
 * Hva én forespørsel betyr, med den samme regelen som
 * `workflow.monograph_request_methods` i databasen: en navngitt metode er den
 * metoden (på den navngitte plattformen, eller på alle som har den); uten metode
 * er det de bibliografiske fritekstsøkene; og en plattform uten et slikt søk
 * betyr sine egne metoder som ikke følger kilder.
 */
export function resolveRequestMethods(
  methods: readonly SearchMethod[],
  platform: string | null,
  method: string | null,
): readonly { readonly platform: string; readonly method: string }[] {
  const onPlatform = methods.filter((entry) => platform === null || entry.platform === platform)
  const chosen =
    method !== null
      ? onPlatform.filter((entry) => entry.method === method)
      : onPlatform.some((entry) => entry.defaultForRequests)
        ? onPlatform.filter((entry) => entry.defaultForRequests)
        : onPlatform.filter((entry) => !entry.requiresSeeds)
  return chosen
    .map((entry) => ({ platform: entry.platform, method: entry.method }))
    .sort((a, b) =>
      a.platform === b.platform
        ? a.method.localeCompare(b.method)
        : a.platform.localeCompare(b.platform),
    )
}
