// ============================================================================
// Katalogen over søkemetodene — bare data
//
// Én liste over hva Antideps kode kan søke i: plattformen, metoden, adressen
// den kaller, om den følger sentrale kilder, og hvilke obligatoriske søkespor
// den dekker for hvilke profiler. Speiler `knowledge.monograph_search_methods`
// og `knowledge.monograph_search_platforms` (migrasjon 014c), og en prøve holder
// de to like.
//
// Den står for seg, uten import, fordi to forskjellige lag leser den: svarformen
// agenten fyller ut (hvilke plattformer og metoder en søkeforespørsel kan
// navngi), og kjøreren som utfører dem (`search-methods.ts`). Navnene skal ha
// ett sted å bo; hvordan hver metode faktisk henter, hører til kjøreren.
// ============================================================================

/** Ett spor en metode dekker, og for hvilke profiler når ikke for alle. */
export interface TrackCoverage {
  readonly track: string
  readonly profiles: readonly string[] | null
}

export interface SearchMethodEntry {
  readonly platform: string
  readonly method: string
  readonly endpointBase: string
  readonly requiresSeeds: boolean
  readonly seedIdentifierKinds: readonly ('doi' | 'pmid' | 'pmcid')[]
  readonly defaultForRequests: boolean
  readonly coverage: readonly TrackCoverage[]
}

function everyProfile(...tracks: readonly string[]): readonly TrackCoverage[] {
  return tracks.map((track) => ({ track, profiles: null }))
}

const PUBMED = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi'
const EUROPE_PMC_SEARCH = 'https://www.ebi.ac.uk/europepmc/webservices/rest/search'
const EUROPE_PMC_REST = 'https://www.ebi.ac.uk/europepmc/webservices/rest'
const CROSSREF_WORKS = 'https://api.crossref.org/works'

function plain(
  platform: string,
  method: string,
  endpointBase: string,
  coverage: readonly TrackCoverage[],
  defaultForRequests = false,
): SearchMethodEntry {
  return {
    platform,
    method,
    endpointBase,
    requiresSeeds: false,
    seedIdentifierKinds: [],
    defaultForRequests,
    coverage,
  }
}

function seeded(
  platform: string,
  method: string,
  endpointBase: string,
  seedIdentifierKinds: readonly ('doi' | 'pmid' | 'pmcid')[],
  coverage: readonly TrackCoverage[],
): SearchMethodEntry {
  return {
    platform,
    method,
    endpointBase,
    requiresSeeds: true,
    seedIdentifierKinds,
    defaultForRequests: false,
    coverage,
  }
}

export const SEARCH_METHOD_CATALOG: readonly SearchMethodEntry[] = [
  plain('Europe PMC', 'keyword', EUROPE_PMC_SEARCH, everyProfile('bibliographic_database'), true),
  plain('PubMed', 'keyword', PUBMED, everyProfile('bibliographic_database'), true),
  // Crossref er også det uavhengige søkesporet: registeret bygger på det
  // utgiverne selv har deponert, og ikke på MEDLINE-indekseringen PubMed og
  // Europe PMC deler.
  plain(
    'Crossref',
    'keyword',
    CROSSREF_WORKS,
    everyProfile('bibliographic_database', 'independent_second_database'),
    true,
  ),
  plain('PubMed', 'systematic_review_filter', PUBMED, everyProfile('systematic_review_search')),
  plain(
    'Europe PMC',
    'systematic_review_filter',
    EUROPE_PMC_SEARCH,
    everyProfile('systematic_review_search'),
  ),
  plain('PubMed', 'observational_filter', PUBMED, everyProfile('observational_safety_search')),
  plain('PubMed', 'human_primary_filter', PUBMED, everyProfile('human_primary_studies')),
  plain('PubMed', 'guideline_filter', PUBMED, everyProfile('regulatory_or_specialist_guidance')),
  plain('PubMed', 'update_window', PUBMED, everyProfile('update_search')),
  seeded(
    'Europe PMC',
    'references',
    EUROPE_PMC_REST,
    ['doi', 'pmid', 'pmcid'],
    everyProfile('reference_lists'),
  ),
  seeded(
    'Europe PMC',
    'citations',
    EUROPE_PMC_REST,
    ['doi', 'pmid', 'pmcid'],
    everyProfile('citing_works'),
  ),
  seeded('Crossref', 'references', CROSSREF_WORKS, ['doi'], everyProfile('reference_lists')),
  plain(
    'ClinicalTrials.gov',
    'registry_search',
    'https://clinicaltrials.gov/api/v2/studies',
    everyProfile('trial_registries'),
  ),
  plain(
    'DMP FEST',
    'product_register',
    'https://www.dmp.no/globalassets/documents/om-oss/distribusjon-av-legemiddeldata/fest/festfiler/fest251.zip',
    everyProfile(
      'norwegian_authority_source',
      'all_identified_products',
      'change_and_shortage_check',
      'product_information',
      'dependent_profile_controls',
    ),
  ),
  plain('EMA', 'regulatory_data', 'https://www.ema.europa.eu/en/documents/report', [
    { track: 'regulatory_or_specialist_guidance', profiles: ['SAFE', 'POP', 'STOP', 'TOX'] },
  ]),
  plain('ClinPGx', 'guideline_annotations', 'https://api.clinpgx.org/v1/data/guidelineAnnotation', [
    { track: 'regulatory_or_specialist_guidance', profiles: ['PGX'] },
  ]),
]

/** Plattformene en søkeforespørsel kan navngi. Utledet, aldri skrevet av. */
export const SEARCH_REQUEST_PLATFORMS: readonly string[] = [
  ...new Set(SEARCH_METHOD_CATALOG.map((entry) => entry.platform)),
].sort()

/** Metodene en søkeforespørsel kan navngi. Utledet, aldri skrevet av. */
export const SEARCH_REQUEST_METHODS: readonly string[] = [
  ...new Set(SEARCH_METHOD_CATALOG.map((entry) => entry.method)),
].sort()

/** Katalogoppføringen for (plattform, metode), eller en feil: den finnes alltid. */
export function catalogEntry(platform: string, method: string): SearchMethodEntry {
  const entry = SEARCH_METHOD_CATALOG.find(
    (candidate) => candidate.platform === platform && candidate.method === method,
  )
  if (entry === undefined) {
    throw new Error(`Søkemetoden ${platform} (${method}) står ikke i katalogen.`)
  }
  return entry
}

/** Søkesporene Antideps kode kan utføre for én profil. */
export function executableTracks(profileCode: string): readonly string[] {
  return [
    ...new Set(
      SEARCH_METHOD_CATALOG.flatMap((entry) =>
        entry.coverage
          .filter(
            (coverage) => coverage.profiles === null || coverage.profiles.includes(profileCode),
          )
          .map((coverage) => coverage.track),
      ),
    ),
  ].sort()
}

/** Alle sporene minst én metode dekker for minst én profil. */
export const EXECUTABLE_TRACK_CODES: readonly string[] = [
  ...new Set(
    SEARCH_METHOD_CATALOG.flatMap((entry) => entry.coverage.map((coverage) => coverage.track)),
  ),
].sort()
