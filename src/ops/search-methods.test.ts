import { readFileSync } from 'node:fs'
import { crc32, deflateRawSync } from 'node:zlib'
import { describe, expect, it } from 'vitest'

import { FEST_URL, readFestSubstance, readZip } from './fest.ts'
import {
  EUROPE_PMC,
  PUBMED,
  CROSSREF,
  type Fetcher,
  type MachineSearch,
} from './monograph-search.ts'
import { createPoliteFetcher } from './search-http.ts'
import { catalogEntry, executableTracks, SEARCH_METHOD_CATALOG } from './search-method-catalog.ts'
import {
  CLINICAL_TRIALS_ENDPOINT,
  declaredTracks,
  EXECUTOR_KEYS,
  findMethod,
  resolveRequestMethods,
  SEARCH_METHODS,
  type MethodInput,
  type SearchMethod,
} from './search-methods.ts'

// ----------------------------------------------------------------------------
// Opptak
//
// Ordinær CI søker ikke på nettet. Opptakene har de ekte tjenestenes svarform,
// med syntetiske treff, og at de *er* et opptak, står her framfor å bli omtalt
// som en utført søkerunde (SOURCE_POLICY.md §4.3).
// ----------------------------------------------------------------------------

type Reply = { readonly status: number; readonly body: unknown } | { readonly error: string }

function served(routes: (url: string) => Reply): Fetcher {
  return async (url) => {
    const reply = routes(url)
    if ('error' in reply) {
      return { status: 'error', message: reply.error }
    }
    const bytes =
      reply.body instanceof Uint8Array
        ? reply.body
        : new TextEncoder().encode(
            typeof reply.body === 'string' ? reply.body : JSON.stringify(reply.body),
          )
    return {
      status: 'ok',
      httpStatus: reply.status,
      contentType: 'application/json',
      bytes,
      finalUrl: url,
    }
  }
}

function method(platform: string, name: string): SearchMethod {
  const found = findMethod(platform, name)
  if (found === undefined) throw new Error(`${platform} (${name}) finnes ikke`)
  return found
}

function input(overrides: Partial<MethodInput> & { fetcher: Fetcher }): MethodInput {
  return {
    scope: { drug: 'sertralin', drugAliases: ['sertraline'], atcCodes: ['N06AB06'] },
    profileCode: 'EFF',
    strategy: 'broad',
    queryTerms: [],
    drugAliases: ['sertraline'],
    seeds: [],
    allowedTracks: [],
    memo: new Map(),
    now: new Date('2026-09-23T00:00:00Z'),
    ...overrides,
  }
}

async function one(searches: Promise<readonly MachineSearch[]>): Promise<MachineSearch> {
  const all = await searches
  expect(all).toHaveLength(1)
  return all[0] as MachineSearch
}

// ============================================================================
// Speilet: katalogen i koden og registeret i databasen er det samme
// ============================================================================

describe('registeret over søkemetoder', () => {
  const MIGRASJON =
    'supabase/migrations/20261020091000_the_registry_says_what_each_search_path_covers.sql'
  const FORRIGE = 'supabase/migrations/20261019092000_the_runner_declares_what_it_can_execute.sql'

  function block(sql: string, statement: string): string {
    const start = sql.indexOf(statement)
    expect(start).toBeGreaterThan(-1)
    // Slutten er semikolonet etter siste radparentes, ikke et semikolon i en
    // beskrivelse.
    const end = sql.indexOf(');\n', start)
    return sql.slice(start, end + 2)
  }

  /** Metodene migrasjonen seeder: plattform|metode|adresse|følger kilder|standard. */
  function seededMethods(): ReadonlySet<string> {
    const sql = readFileSync(MIGRASJON, 'utf8')
    const rows = block(sql, 'insert into knowledge.monograph_search_methods')
    const found = new Set<string>()
    for (const match of rows.matchAll(
      /\('([^']+)', '([a-z_]+)',\s*'(https:[^']+)', (true|false), (array\[[^\]]*\]::text\[\]|array\[[^\]]*\]), (true|false),/g,
    )) {
      const kinds = [...(match[5] ?? '').matchAll(/'([a-z]+)'/g)].map((kind) => kind[1]).join(',')
      found.add(`${match[1]}|${match[2]}|${match[3]}|${match[4]}|${kinds}|${match[6]}`)
    }
    return found
  }

  /** Dekningen: plattform|metode|spor|profiler — fra 013x og fra 014c. */
  function seededCoverage(): ReadonlySet<string> {
    const found = new Set<string>()
    const old = block(
      readFileSync(FORRIGE, 'utf8'),
      'insert into knowledge.monograph_search_platforms',
    )
    for (const match of old.matchAll(/\('([^']+)', '([a-z_]+)'\)/g)) {
      found.add(`${match[1]}|keyword|${match[2]}|*`)
    }
    const fresh = block(
      readFileSync(MIGRASJON, 'utf8'),
      'insert into knowledge.monograph_search_platforms (platform, method, track_code, profile_codes)',
    )
    for (const match of fresh.matchAll(
      /\('([^']+)', '([a-z_]+)', '([a-z_]+)',\s*(null|array\[[^\]]+\])\)/g,
    )) {
      const profiles =
        match[4] === 'null'
          ? '*'
          : [...(match[4] ?? '').matchAll(/'([A-Z]+)'/g)].map((code) => code[1]).join(',')
      found.add(`${match[1]}|${match[2]}|${match[3]}|${profiles}`)
    }
    return found
  }

  it('speiler nøyaktig metodene migrasjonen registrerer, med adresse og kildefølging', () => {
    const fraKoden = new Set(
      SEARCH_METHOD_CATALOG.map(
        (entry) =>
          `${entry.platform}|${entry.method}|${entry.endpointBase}|${String(entry.requiresSeeds)}|${entry.seedIdentifierKinds.join(',')}|${String(entry.defaultForRequests)}`,
      ),
    )
    expect(seededMethods()).toEqual(fraKoden)
  })

  it('speiler nøyaktig hvilke spor hver metode dekker, og for hvilke profiler', () => {
    const fraKoden = new Set(
      SEARCH_METHOD_CATALOG.flatMap((entry) =>
        entry.coverage.map(
          (coverage) =>
            `${entry.platform}|${entry.method}|${coverage.track}|${coverage.profiles === null ? '*' : coverage.profiles.join(',')}`,
        ),
      ),
    )
    expect(seededCoverage()).toEqual(fraKoden)
  })

  it('har kode for hver metode i katalogen, og ingen kode uten en katalogoppføring', () => {
    const katalog = SEARCH_METHOD_CATALOG.map((entry) => `${entry.platform}|${entry.method}`).sort()
    expect([...EXECUTOR_KEYS].sort()).toEqual(katalog)
    expect(SEARCH_METHODS).toHaveLength(SEARCH_METHOD_CATALOG.length)
  })

  it('kaller adressene katalogen oppgir', () => {
    expect(catalogEntry('DMP FEST', 'product_register').endpointBase).toBe(FEST_URL)
    expect(catalogEntry('ClinicalTrials.gov', 'registry_search').endpointBase).toBe(
      CLINICAL_TRIALS_ENDPOINT,
    )
    for (const platform of [EUROPE_PMC, PUBMED, CROSSREF]) {
      expect(
        platform.endpoint('x').startsWith(catalogEntry(platform.name, 'keyword').endpointBase),
      ).toBe(true)
    }
  })

  it('dekker hvert obligatorisk spor i standarden for hver profil, utenom gjenbrukskontrollen', () => {
    // Samme tabell som SOURCE_POLICY.md §4.2 og migrasjon 20261003090000.
    const standard: Readonly<Record<string, readonly string[]>> = {
      REG: ['norwegian_authority_source', 'all_identified_products', 'change_and_shortage_check'],
      PROD: ['norwegian_authority_source', 'all_identified_products', 'change_and_shortage_check'],
      EFF: [
        'bibliographic_database',
        'systematic_review_search',
        'independent_second_database',
        'reference_lists',
        'citing_works',
        'trial_registries',
      ],
      AE: [
        'bibliographic_database',
        'systematic_review_search',
        'independent_second_database',
        'reference_lists',
        'citing_works',
        'trial_registries',
      ],
      SAFE: [
        'bibliographic_database',
        'systematic_review_search',
        'regulatory_or_specialist_guidance',
        'observational_safety_search',
      ],
      POP: [
        'bibliographic_database',
        'systematic_review_search',
        'regulatory_or_specialist_guidance',
        'observational_safety_search',
      ],
      PK: [
        'bibliographic_database',
        'reference_lists',
        'product_information',
        'human_primary_studies',
      ],
      INT: [
        'bibliographic_database',
        'reference_lists',
        'product_information',
        'human_primary_studies',
      ],
      PGX: ['bibliographic_database', 'regulatory_or_specialist_guidance', 'update_search'],
      TDM: ['bibliographic_database', 'regulatory_or_specialist_guidance', 'update_search'],
      STOP: [
        'bibliographic_database',
        'systematic_review_search',
        'regulatory_or_specialist_guidance',
        'dependent_profile_controls',
      ],
      TOX: [
        'bibliographic_database',
        'systematic_review_search',
        'regulatory_or_specialist_guidance',
      ],
    }
    const uten: string[] = []
    for (const [profile, tracks] of Object.entries(standard)) {
      for (const track of tracks) {
        if (!executableTracks(profile).includes(track)) uten.push(`${profile}:${track}`)
      }
    }
    expect(uten).toEqual([])
  })
})

// ============================================================================
// Et søk kan ikke erklære et spor metoden ikke dekker
// ============================================================================

describe('sporene et søk erklærer', () => {
  it('er skjæringen mellom rundens lov og metodens dekning for profilen', () => {
    const clinpgx = catalogEntry('ClinPGx', 'guideline_annotations')
    expect(declaredTracks(clinpgx, ['regulatory_or_specialist_guidance'], 'PGX')).toEqual([
      'regulatory_or_specialist_guidance',
    ])
    // Et farmakogenetisk oppslag er ikke sikkerhetsveiledning.
    expect(declaredTracks(clinpgx, ['regulatory_or_specialist_guidance'], 'SAFE')).toEqual([])
    const ema = catalogEntry('EMA', 'regulatory_data')
    expect(declaredTracks(ema, ['regulatory_or_specialist_guidance'], 'PGX')).toEqual([])
    expect(declaredTracks(ema, ['regulatory_or_specialist_guidance'], 'SAFE')).toEqual([
      'regulatory_or_specialist_guidance',
    ])
  })

  it('erklærer aldri et spor runden ikke fikk — heller ikke når metoden dekker det', () => {
    const fest = catalogEntry('DMP FEST', 'product_register')
    expect(declaredTracks(fest, [], 'REG')).toEqual([])
    expect(
      declaredTracks(fest, ['norwegian_authority_source', 'bibliographic_database'], 'REG'),
    ).toEqual(['norwegian_authority_source'])
  })
})

describe('hva en forespørsel betyr', () => {
  it('er de bibliografiske fritekstsøkene når ingen metode er navngitt — som før metoden fantes', () => {
    expect(resolveRequestMethods(SEARCH_METHODS, null, null)).toEqual([
      { platform: 'Crossref', method: 'keyword' },
      { platform: 'Europe PMC', method: 'keyword' },
      { platform: 'PubMed', method: 'keyword' },
    ])
    expect(resolveRequestMethods(SEARCH_METHODS, 'PubMed', null)).toEqual([
      { platform: 'PubMed', method: 'keyword' },
    ])
  })

  it('er plattformens egne søk når den ikke har et fritekstsøk', () => {
    expect(resolveRequestMethods(SEARCH_METHODS, 'ClinicalTrials.gov', null)).toEqual([
      { platform: 'ClinicalTrials.gov', method: 'registry_search' },
    ])
  })

  it('er den navngitte metoden på hver plattform som har den', () => {
    expect(resolveRequestMethods(SEARCH_METHODS, null, 'references')).toEqual([
      { platform: 'Crossref', method: 'references' },
      { platform: 'Europe PMC', method: 'references' },
    ])
    expect(resolveRequestMethods(SEARCH_METHODS, 'Europe PMC', 'citations')).toEqual([
      { platform: 'Europe PMC', method: 'citations' },
    ])
  })
})

// ============================================================================
// De filtrerte litteratursøkene
// ============================================================================

describe('de filtrerte litteratursøkene', () => {
  const pubmed = readFileSync('src/ops/fixtures/pubmed-sertraline.json', 'utf8')

  it('legger NLMs oversiktsfilter i strengen og erklærer bare oversiktssporet', async () => {
    const urls: string[] = []
    const search = await one(
      method('PubMed', 'systematic_review_filter').execute(
        input({
          fetcher: served((url) => {
            urls.push(url)
            return { status: 200, body: pubmed }
          }),
          allowedTracks: ['bibliographic_database', 'systematic_review_search'],
        }),
      ),
    )
    expect(search.queryString).toBe('(("sertralin" OR "sertraline")) AND systematic[sb]')
    expect(search.trackCodes).toEqual(['systematic_review_search'])
    expect(search.filters).toContain('systematic[sb]')
    expect(urls[0]).toContain(encodeURIComponent('systematic[sb]'))
  })

  it('bruker ikke de norske avgrensningsaksene mot et engelskspråklig register', async () => {
    const search = await one(
      method('PubMed', 'observational_filter').execute(
        input({
          scope: {
            drug: 'sertralin',
            indication: 'depressiv lidelse',
            drugAliases: ['sertraline'],
          },
          fetcher: served(() => ({ status: 200, body: pubmed })),
        }),
      ),
    )
    expect(search.queryString).not.toContain('depressiv lidelse')
  })

  it('setter oppdateringsvinduet i adressen og i filteret', async () => {
    const urls: string[] = []
    const search = await one(
      method('PubMed', 'update_window').execute(
        input({
          fetcher: served((url) => {
            urls.push(url)
            return { status: 200, body: pubmed }
          }),
          allowedTracks: ['update_search'],
          profileCode: 'PGX',
        }),
      ),
    )
    expect(urls[0]).toContain('mindate=2023')
    expect(urls[0]).toContain('maxdate=2026')
    expect(search.filters).toContain('2023–2026')
    expect(search.trackCodes).toEqual(['update_search'])
  })
})

// ============================================================================
// ClinicalTrials.gov: paginering og avkorting
// ============================================================================

function trialsPage(ids: readonly number[], total: number, next: string | null): unknown {
  return {
    totalCount: total,
    studies: ids.map((id) => ({
      protocolSection: {
        identificationModule: {
          nctId: `NCT${String(id).padStart(8, '0')}`,
          briefTitle: `Syntetisk studie ${id}`,
        },
        statusModule: { overallStatus: 'COMPLETED', startDateStruct: { date: '2015-03' } },
        sponsorCollaboratorsModule: { leadSponsor: { name: 'Syntetisk sponsor' } },
      },
      hasResults: id % 2 === 0,
    })),
    ...(next === null ? {} : { nextPageToken: next }),
  }
}

describe('forsøksregisteret', () => {
  const trials = method('ClinicalTrials.gov', 'registry_search')

  it('leser alle sidene når trefflisten er kort nok, og står da ikke som avkortet', async () => {
    const search = await one(
      trials.execute(
        input({
          allowedTracks: ['trial_registries'],
          fetcher: served((url) =>
            url.includes('pageToken=t2')
              ? { status: 200, body: trialsPage([3, 4], 4, null) }
              : { status: 200, body: trialsPage([1, 2], 4, 't2') },
          ),
        }),
      ),
    )
    expect(search.outcome).toBe('executed')
    expect(search.resultCount).toBe(4)
    expect(search.screenedCount).toBe(4)
    expect(search.truncated).toBe(false)
    expect(search.candidates.map((candidate) => candidate.identifier_value)).toEqual([
      'NCT00000001',
      'NCT00000002',
      'NCT00000003',
      'NCT00000004',
    ])
    expect(search.candidates[0]?.identifier_kind).toBe('registry_id')
    expect(search.trackCodes).toEqual(['trial_registries'])
  })

  it('står som avkortet når en side underveis ikke kom — aldri som en fullstendig liste', async () => {
    const search = await one(
      trials.execute(
        input({
          allowedTracks: ['trial_registries'],
          fetcher: served((url) =>
            url.includes('pageToken=t2')
              ? { status: 503, body: 'nede' }
              : { status: 200, body: trialsPage([1, 2], 4, 't2') },
          ),
        }),
      ),
    )
    expect(search.outcome).toBe('executed')
    expect(search.truncated).toBe(true)
    expect(search.truncationNote).toContain('side 2 svarte ikke')
    expect(search.screenedCount).toBe(2)
  })

  it('står som avkortet når sidegrensen nås før hele trefflisten er lest', async () => {
    let page = 0
    const search = await one(
      trials.execute(
        input({
          fetcher: served(() => {
            page += 1
            return { status: 200, body: trialsPage([page], 999, `t${page + 1}`) }
          }),
        }),
      ),
    )
    expect(search.truncated).toBe(true)
    expect(search.resultCount).toBe(999)
    expect(search.screenedCount).toBe(3)
  })

  it('skiller en tjeneste som er nede fra null treff', async () => {
    const down = await one(
      trials.execute(input({ fetcher: served(() => ({ error: 'ECONNRESET' })) })),
    )
    expect(down.outcome).toBe('unavailable')
    expect(down.resultCount).toBeNull()
    const zero = await one(
      trials.execute(
        input({ fetcher: served(() => ({ status: 200, body: trialsPage([], 0, null) })) }),
      ),
    )
    expect(zero.outcome).toBe('zero_results')
    expect(zero.resultCount).toBe(0)
  })
})

// ============================================================================
// Å følge de sentrale kildene
// ============================================================================

describe('referanser og siterende arbeider', () => {
  const references = readFileSync('src/ops/fixtures/europe-pmc-references.json', 'utf8')

  it('henter referanselisten til hver kilde og gir kandidater med identitet', async () => {
    const search = await one(
      method('Europe PMC', 'references').execute(
        input({
          seeds: ['pmid:37032427'],
          allowedTracks: ['reference_lists'],
          fetcher: served(() => ({ status: 200, body: references })),
        }),
      ),
    )
    expect(search.outcome).toBe('executed')
    expect(search.resultCount).toBe(3)
    // Referansen uten en identifikator er lest, men ikke en kandidat.
    expect(search.candidates.map((candidate) => candidate.identifier_value)).toEqual([
      '10000001',
      '10000002',
    ])
    expect(search.endpoint).toContain('/MED/37032427/references')
    expect(search.trackCodes).toEqual(['reference_lists'])
  })

  it('regner en kilde uten registrert referanseliste som en begrensning og ikke som null referanser', async () => {
    const search = await one(
      method('Europe PMC', 'references').execute(
        input({
          seeds: ['pmid:1'],
          allowedTracks: ['reference_lists'],
          fetcher: served(() => ({
            status: 200,
            body: { hitCount: 0, referenceList: { reference: [] } },
          })),
        }),
      ),
    )
    expect(search.outcome).toBe('unavailable')
    expect(search.resultCount).toBeNull()
    expect(search.limitationNote).toContain('ikke null referanser')
  })

  it('regner null siterende arbeider som et resultat', async () => {
    const search = await one(
      method('Europe PMC', 'citations').execute(
        input({
          seeds: ['pmid:1'],
          allowedTracks: ['citing_works'],
          fetcher: served(() => ({
            status: 200,
            body: { hitCount: 0, citationList: { citation: [] } },
          })),
        }),
      ),
    )
    expect(search.outcome).toBe('zero_results')
    expect(search.resultCount).toBe(0)
    expect(search.trackCodes).toEqual(['citing_works'])
  })

  it('sier fra når kilden ikke finnes i Europe PMC, framfor å rapportere null treff', async () => {
    const search = await one(
      method('Europe PMC', 'citations').execute(
        input({
          seeds: ['doi:10.5555/finnes.ikke'],
          fetcher: served(() => ({
            status: 200,
            body: { hitCount: 0, resultList: { result: [] } },
          })),
        }),
      ),
    )
    expect(search.outcome).toBe('unavailable')
    expect(search.limitationNote).toContain('finnes ikke i Europe PMC')
  })

  it('følger bare DOI-er i Crossref, og skiller en manglende referanseliste fra en tom', async () => {
    const searches = await method('Crossref', 'references').execute(
      input({
        seeds: ['pmid:1', 'doi:10.5555/a', 'doi:10.5555/b', 'doi:10.5555/c'],
        allowedTracks: ['reference_lists'],
        fetcher: served((url) => {
          if (url.endsWith(encodeURIComponent('10.5555/a'))) {
            return {
              status: 200,
              body: {
                message: {
                  reference: [
                    { DOI: '10.5555/ref.1', 'article-title': 'Syntetisk referanse', year: '2010' },
                    { unstructured: 'En referanse uten DOI.' },
                  ],
                },
              },
            }
          }
          if (url.endsWith(encodeURIComponent('10.5555/b'))) {
            return { status: 200, body: { message: {} } }
          }
          return { status: 404, body: 'Resource not found.' }
        }),
      }),
    )
    expect(searches.map((search) => [search.queryString, search.outcome])).toEqual([
      ['Referanselisten til doi:10.5555/a', 'executed'],
      ['Referanselisten til doi:10.5555/b', 'unavailable'],
      ['Referanselisten til doi:10.5555/c', 'unavailable'],
    ])
    expect(searches[0]?.candidates.map((candidate) => candidate.identifier_value)).toEqual([
      '10.5555/ref.1',
    ])
  })
})

// ============================================================================
// EMA og ClinPGx
// ============================================================================

describe('de regulatoriske datasettene', () => {
  const ema = method('EMA', 'regulatory_data')
  const psusa = {
    data: [
      {
        active_substance: 'sertraline',
        active_substances_in_scope_of_procedure: 'Sertraline',
        procedure_number: 'PSUSA/00002696/202203',
        regulatory_outcome: 'Maintenance',
        first_published_date: '05/12/2023',
        psusa_url: 'https://www.ema.europa.eu/en/medicines/psusa/psusa-00002696-202203',
      },
      {
        active_substance: 'sertralinum-lignende stoff',
        procedure_number: 'PSUSA/1',
        psusa_url: 'https://www.ema.europa.eu/en/medicines/psusa/1',
      },
    ],
  }

  it('leser hvert datasett som sitt eget søk, med sitt eget avtrykk', async () => {
    const searches = await ema.execute(
      input({
        profileCode: 'SAFE',
        allowedTracks: ['regulatory_or_specialist_guidance'],
        fetcher: served((url) =>
          url.includes('periodic_safety_update')
            ? { status: 200, body: psusa }
            : { status: 200, body: { data: [] } },
        ),
      }),
    )
    expect(searches).toHaveLength(4)
    expect(searches[0]?.outcome).toBe('executed')
    // «sertraline» som eget ord, og ikke et stoff som bare begynner likt.
    expect(searches[0]?.resultCount).toBe(1)
    expect(searches[0]?.candidates[0]?.identifier_value).toBe(
      'https://www.ema.europa.eu/en/medicines/psusa/psusa-00002696-202203',
    )
    expect(searches.slice(1).map((search) => search.outcome)).toEqual([
      'zero_results',
      'zero_results',
      'zero_results',
    ])
    expect(new Set(searches.map((search) => search.endpoint)).size).toBe(4)
  })

  it('erklærer ikke veiledningssporet for en profil EMA ikke er registrert for', async () => {
    const searches = await ema.execute(
      input({
        profileCode: 'PGX',
        allowedTracks: ['regulatory_or_specialist_guidance'],
        fetcher: served(() => ({ status: 200, body: { data: [] } })),
      }),
    )
    expect(searches.every((search) => search.trackCodes.length === 0)).toBe(true)
  })

  it('skiller et uleselig datasett fra et datasett uten treff', async () => {
    const searches = await ema.execute(
      input({ fetcher: served(() => ({ status: 200, body: '<html>vedlikehold</html>' })) }),
    )
    expect(searches.every((search) => search.outcome === 'failed')).toBe(true)
  })
})

describe('de farmakogenetiske retningslinjene', () => {
  const clinpgx = method('ClinPGx', 'guideline_annotations')

  it('regner «ingen treff» fra ClinPGx som null treff, og en feilkode som en begrensning', async () => {
    const searches = await clinpgx.execute(
      input({
        profileCode: 'PGX',
        allowedTracks: ['regulatory_or_specialist_guidance'],
        fetcher: served((url) =>
          url.includes('sertraline')
            ? {
                status: 503,
                body: { status: 'fail', data: { errors: [{ message: 'Overloaded' }] } },
              }
            : {
                status: 404,
                body: {
                  status: 'fail',
                  data: { errors: [{ message: 'No results matching criteria.' }] },
                },
              },
        ),
      }),
    )
    expect(searches.map((search) => [search.queryString, search.outcome])).toEqual([
      ['relatedChemicals.name = sertralin', 'zero_results'],
      ['relatedChemicals.name = sertraline', 'unavailable'],
    ])
  })

  it('gir hver retningslinjeannotasjon som en kandidat med retningslinjeeieren', async () => {
    const searches = await clinpgx.execute(
      input({
        profileCode: 'PGX',
        drugAliases: [],
        scope: { drug: 'sertraline' },
        allowedTracks: ['regulatory_or_specialist_guidance'],
        fetcher: served(() => ({
          status: 200,
          body: {
            status: 'success',
            data: [
              {
                id: 'PA166104980',
                name: 'Annotation of DPWG Guideline for sertraline',
                source: 'DPWG',
              },
            ],
          },
        })),
      }),
    )
    expect(searches[0]?.candidates[0]).toMatchObject({
      identifier_kind: 'url',
      identifier_value: 'https://www.clinpgx.org/guidelineAnnotation/PA166104980',
      authors_or_issuer: 'DPWG',
    })
    expect(searches[0]?.trackCodes).toEqual(['regulatory_or_specialist_guidance'])
  })
})

// ============================================================================
// FEST: den norske myndighetskilden
// ============================================================================

/** Et lite, syntetisk FEST-dokument i M30-formen. */
function festXml(): string {
  return `<?xml version="1.0" encoding="utf-8"?>
<FEST xmlns="http://www.kith.no/xmlstds/eresept/m30/2014-12-01">
  <HentetDato>2026-09-08T03:09:06</HentetDato>
  <KatLegemiddelMerkevare>
    <OppfLegemiddelMerkevare>
      <Id>ID_OPPF-1</Id>
      <Tidspunkt>2026-01-23T03:13:53</Tidspunkt>
      <Status V="A" DN="Aktiv oppføring" />
      <LegemiddelMerkevare xmlns="http://www.kith.no/xmlstds/eresept/forskrivning/2014-12-01">
        <Atc V="N06AB06" DN="Sertralin" />
        <NavnFormStyrke>Syntetisk sertralin tab 50 mg</NavnFormStyrke>
        <Reseptgruppe V="C" DN="Reseptgruppe C" />
        <Preparattype V="7" DN="Legemiddel" />
        <AdministreringLegemiddel><Administrasjonsvei V="53" DN="Oral bruk" /></AdministreringLegemiddel>
        <Id>ID_PRODUKT-1</Id>
        <Varenavn>Syntetisk sertralin</Varenavn>
        <LegemiddelformLang>Tablett</LegemiddelformLang>
        <ProduktInfo><Produsent>Syntetisk AS</Produsent></ProduktInfo>
        <Preparatomtaleavsnitt><Lenke><Www V="https://produktinformasjon.legemiddelsok.no/preparatomtaler/00-00001.pdf" /></Lenke></Preparatomtaleavsnitt>
      </LegemiddelMerkevare>
    </OppfLegemiddelMerkevare>
    <OppfLegemiddelMerkevare>
      <Id>ID_OPPF-2</Id>
      <Status V="A" DN="Aktiv oppføring" />
      <LegemiddelMerkevare xmlns="http://www.kith.no/xmlstds/eresept/forskrivning/2014-12-01">
        <Atc V="N06AB06" DN="Sertralin" />
        <NavnFormStyrke>Uregistrert sertralin kaps 25 mg</NavnFormStyrke>
        <Preparattype V="11" DN="Krever godkj. Fritak" />
        <Id>ID_PRODUKT-2</Id>
        <Varenavn>Uregistrert sertralin</Varenavn>
      </LegemiddelMerkevare>
    </OppfLegemiddelMerkevare>
    <OppfLegemiddelMerkevare>
      <Id>ID_OPPF-3</Id>
      <Status V="A" DN="Aktiv oppføring" />
      <LegemiddelMerkevare xmlns="http://www.kith.no/xmlstds/eresept/forskrivning/2014-12-01">
        <Atc V="C10AB05" DN="Fenofibrat" />
        <NavnFormStyrke>Et annet virkestoff kaps 200 mg</NavnFormStyrke>
        <Preparattype V="7" DN="Legemiddel" />
        <Id>ID_PRODUKT-3</Id>
      </LegemiddelMerkevare>
    </OppfLegemiddelMerkevare>
  </KatLegemiddelMerkevare>
  <KatLegemiddelpakning>
    <OppfLegemiddelpakning>
      <Id>ID_OPPF-P1</Id>
      <Legemiddelpakning xmlns="http://www.kith.no/xmlstds/eresept/forskrivning/2014-12-01">
        <Atc V="N06AB06" DN="Sertralin" />
        <NavnFormStyrke>Syntetisk sertralin tab 50 mg</NavnFormStyrke>
        <Id>ID_PAKNING-1</Id>
        <Varenr>123456</Varenr>
        <Pakningsinfo><RefLegemiddelMerkevare>ID_PRODUKT-1</RefLegemiddelMerkevare></Pakningsinfo>
        <Markedsforingsinfo><Markedsforingsdato>2005-02-01</Markedsforingsdato><MidlUtgattDato>2026-07-29</MidlUtgattDato></Markedsforingsinfo>
      </Legemiddelpakning>
    </OppfLegemiddelpakning>
  </KatLegemiddelpakning>
  <KatVarselSlv>
    <OppfVarselSlv>
      <Id>ID_VARSEL-1</Id>
      <VarselSlv>
        <Type V="2" DN="Leveringssvikt" />
        <Overskrift>Mangel på syntetisk sertralin</Overskrift>
        <Varseltekst>Syntetisk varsel.</Varseltekst>
        <FraDato>2026-08-01</FraDato>
        <Lenke><Www V="https://www.dmp.no/syntetisk-varsel" /></Lenke>
        <Referanseelement><RefElement>ID_PRODUKT-1</RefElement></Referanseelement>
      </VarselSlv>
    </OppfVarselSlv>
    <OppfVarselSlv>
      <Id>ID_VARSEL-2</Id>
      <VarselSlv>
        <Type V="1" DN="Sikkerhetsinformasjon" />
        <Overskrift>Et varsel om et annet virkestoff</Overskrift>
        <Referanseelement><RefElement>ID_PRODUKT-3</RefElement></Referanseelement>
      </VarselSlv>
    </OppfVarselSlv>
  </KatVarselSlv>
</FEST>`
}

/** Et ZIP-arkiv med én deflatert fil, bygget byte for byte som FEST-filen er. */
function zip(name: string, content: Uint8Array, corruptCrc = false): Uint8Array {
  const compressed = deflateRawSync(content)
  const nameBytes = new TextEncoder().encode(name)
  const crc = (crc32(content) ^ (corruptCrc ? 1 : 0)) >>> 0
  const local = Buffer.alloc(30)
  local.writeUInt32LE(0x04034b50, 0)
  local.writeUInt16LE(20, 4)
  local.writeUInt16LE(8, 8)
  local.writeUInt32LE(crc, 14)
  local.writeUInt32LE(compressed.length, 18)
  local.writeUInt32LE(content.length, 22)
  local.writeUInt16LE(nameBytes.length, 26)
  const central = Buffer.alloc(46)
  central.writeUInt32LE(0x02014b50, 0)
  central.writeUInt16LE(20, 4)
  central.writeUInt16LE(20, 6)
  central.writeUInt16LE(8, 10)
  central.writeUInt32LE(crc, 16)
  central.writeUInt32LE(compressed.length, 20)
  central.writeUInt32LE(content.length, 24)
  central.writeUInt16LE(nameBytes.length, 28)
  central.writeUInt32LE(0, 42)
  const localSize = local.length + nameBytes.length + compressed.length
  const end = Buffer.alloc(22)
  end.writeUInt32LE(0x06054b50, 0)
  end.writeUInt16LE(1, 8)
  end.writeUInt16LE(1, 10)
  end.writeUInt32LE(central.length + nameBytes.length, 12)
  end.writeUInt32LE(localSize, 16)
  return new Uint8Array(Buffer.concat([local, nameBytes, compressed, central, nameBytes, end]))
}

describe('FEST', () => {
  const fest = method('DMP FEST', 'product_register')
  const archive = zip('fest251.xml', new TextEncoder().encode(festXml()))

  it('leser virkestoffets preparater, pakninger og DMPs varsler på ATC-koden', () => {
    const [entry] = readZip(archive)
    const record = readFestSubstance(
      new TextDecoder().decode(entry?.bytes),
      ['N06AB06'],
      ['sertralin'],
    )
    expect(record.retrievedAt).toBe('2026-09-08T03:09:06')
    expect(record.products.map((product) => product.nameFormStrength)).toEqual([
      'Syntetisk sertralin tab 50 mg',
      'Uregistrert sertralin kaps 25 mg',
    ])
    expect(record.products[0]?.productId).toBe('ID_PRODUKT-1')
    expect(record.packages[0]?.temporarilyUnavailableFrom).toBe('2026-07-29')
    expect(record.notices.map((notice) => notice.heading)).toEqual([
      'Mangel på syntetisk sertralin',
    ])
  })

  it('er den norske myndighetskilden for REG: alle tre regulatoriske spor, med preparatomtale og varsel', async () => {
    const search = await one(
      fest.execute(
        input({
          profileCode: 'REG',
          allowedTracks: [
            'norwegian_authority_source',
            'all_identified_products',
            'change_and_shortage_check',
          ],
          fetcher: served(() => ({ status: 200, body: archive })),
        }),
      ),
    )
    expect(search.outcome).toBe('executed')
    expect(search.resultCount).toBe(2)
    expect(search.truncated).toBe(false)
    expect(search.trackCodes).toEqual([
      'norwegian_authority_source',
      'all_identified_products',
      'change_and_shortage_check',
    ])
    expect(search.filters).toContain('1 midlertidig utgått')
    expect(search.filters).toContain('1 uregistrerte med godkjenningsfritak')
    expect(search.candidates.map((candidate) => candidate.identifier_value)).toEqual([
      'https://produktinformasjon.legemiddelsok.no/preparatomtaler/00-00001.pdf',
      'https://www.dmp.no/syntetisk-varsel',
    ])
    expect(search.responseDigest).toMatch(/^sha256:[0-9a-f]{64}$/)
  })

  it('pakker ut og leser filen én gang per kjøring, uansett hvor mange planer som leser den', async () => {
    const memo = new Map<string, unknown>()
    const fetcher = served(() => ({ status: 200, body: archive }))
    await fest.execute(input({ profileCode: 'REG', memo, fetcher }))
    await fest.execute(input({ profileCode: 'PROD', memo, fetcher }))
    expect(memo.size).toBe(1)
  })

  it('gir null treff for et virkestoff FEST ikke fører — et resultat, ikke en feil', async () => {
    const search = await one(
      fest.execute(
        input({
          scope: { drug: 'ukjent', atcCodes: ['N06AX99'] },
          fetcher: served(() => ({ status: 200, body: archive })),
        }),
      ),
    )
    expect(search.outcome).toBe('zero_results')
    expect(search.resultCount).toBe(0)
  })

  it('regner en fil som ikke stemmer med sin egen kontrollsum som uleselig, aldri som null treff', async () => {
    const broken = zip('fest251.xml', new TextEncoder().encode(festXml()), true)
    const search = await one(
      fest.execute(input({ fetcher: served(() => ({ status: 200, body: broken })) })),
    )
    expect(search.outcome).toBe('failed')
    expect(search.resultCount).toBeNull()
    expect(search.limitationNote).toContain('kontrollsum')
  })

  it('regner en DMP som ikke svarer som en begrensning', async () => {
    const search = await one(
      fest.execute(input({ fetcher: served(() => ({ status: 502, body: 'x' })) })),
    )
    expect(search.outcome).toBe('unavailable')
    expect(search.responseDigest).toMatch(/^sha256:/)
  })
})

// ============================================================================
// Hentingen: takt, nye forsøk og deling
// ============================================================================

describe('den høflige henteren', () => {
  function recorder(): {
    sleeps: number[]
    sleep: (ms: number) => Promise<void>
    now: () => number
  } {
    let clock = 0
    const sleeps: number[] = []
    return {
      sleeps,
      sleep: async (ms) => {
        sleeps.push(ms)
        clock += ms
      },
      now: () => clock,
    }
  }

  it('prøver et 429-svar på nytt, og leverer svaret som kom etterpå', async () => {
    let calls = 0
    const clock = recorder()
    const fetcher = createPoliteFetcher(
      served(() => {
        calls += 1
        return calls === 1 ? { status: 429, body: 'for mange' } : { status: 200, body: '{}' }
      }),
      clock,
    )
    const response = await fetcher('https://eutils.ncbi.nlm.nih.gov/x')
    expect(response.status === 'ok' && response.httpStatus).toBe(200)
    expect(calls).toBe(2)
  })

  it('prøver ikke et svar om saken på nytt', async () => {
    let calls = 0
    const fetcher = createPoliteFetcher(
      served(() => {
        calls += 1
        return { status: 404, body: 'finnes ikke' }
      }),
      recorder(),
    )
    await fetcher('https://api.crossref.org/works/x')
    expect(calls).toBe(1)
  })

  it('gir opp etter de tillatte forsøkene, og leverer begrensningen videre', async () => {
    let calls = 0
    const fetcher = createPoliteFetcher(
      served(() => {
        calls += 1
        return { error: 'ECONNRESET' }
      }),
      recorder(),
    )
    const response = await fetcher('https://clinicaltrials.gov/api/v2/studies')
    expect(response.status).toBe('error')
    expect(calls).toBe(3)
  })

  it('holder avstand mellom kall mot den samme verten', async () => {
    const clock = recorder()
    const fetcher = createPoliteFetcher(
      served(() => ({ status: 200, body: '{}' })),
      clock,
    )
    await fetcher('https://eutils.ncbi.nlm.nih.gov/a')
    await fetcher('https://eutils.ncbi.nlm.nih.gov/b')
    expect(clock.sleeps).toEqual([400])
  })

  it('henter det samme kallet én gang per kjøring', async () => {
    let calls = 0
    const fetcher = createPoliteFetcher(
      served(() => {
        calls += 1
        return { status: 200, body: '{}' }
      }),
      recorder(),
    )
    await fetcher(FEST_URL)
    await fetcher(FEST_URL)
    expect(calls).toBe(1)
  })
})
