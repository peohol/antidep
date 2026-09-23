import { readFileSync } from 'node:fs'
import { describe, expect, it, vi } from 'vitest'

import {
  describeDiscoveryReport,
  runMonographDiscovery,
  type DiscoveryApi,
  type DiscoveryPlan,
  type SearchRequest,
} from './monograph-discovery.ts'
import type { Fetcher, MachineSearch } from './monograph-search.ts'
import { findMethod, type SearchMethod } from './search-methods.ts'

function method(platform: string, name: string): SearchMethod {
  const found = findMethod(platform, name)
  if (found === undefined) throw new Error(`${platform} (${name}) finnes ikke`)
  return found
}

const keyword = (platform: string): SearchMethod => method(platform, 'keyword')

function request(overrides: Partial<SearchRequest> = {}): SearchRequest {
  return {
    requestReference: 'd'.repeat(32),
    searchRound: 1,
    origin: 'plan_opened',
    strategy: 'broad',
    rationale: 'Den nye søkeplanens første maskinelle søkerunde.',
    platform: null,
    method: null,
    methods: [],
    seedIdentifiers: [],
    drugAliases: [],
    queryTerms: [],
    filtersNote: null,
    trackCodes: ['bibliographic_database', 'trial_registry'],
    attempts: 0,
    state: 'pending',
    ...overrides,
  }
}

const PLAN: DiscoveryPlan = {
  planReference: 'a'.repeat(32),
  drug: 'sertralin',
  editionReference: 'b'.repeat(32),
  profileCode: 'AE',
  scope: { drug: 'sertralin', outcome: 'vektendring' },
  searchRound: 1,
  requests: [request()],
}

function recorded(file: string): Fetcher {
  return async (url) => ({
    status: 'ok',
    httpStatus: 200,
    contentType: 'application/json',
    bytes: new TextEncoder().encode(readFileSync(`src/ops/fixtures/${file}`, 'utf8')),
    finalUrl: url,
  })
}

function api(overrides: Partial<DiscoveryApi> = {}): {
  readonly api: DiscoveryApi
  readonly searches: MachineSearch[]
  readonly closed: string[]
} {
  const searches: MachineSearch[] = []
  const closed: string[] = []
  return {
    searches,
    closed,
    api: {
      work: async () => [PLAN],
      beginRun: async () => 'c'.repeat(8),
      recordSearch: async (_run, _plan, _request, search) => {
        searches.push(search)
      },
      closeRequest: async (_run, reference) => {
        closed.push(reference)
        return { state: 'fulfilled', enqueuedJob: true }
      },
      completeRun: async () => undefined,
      ...overrides,
    },
  }
}

describe('runMonographDiscovery', () => {
  it('registrerer ett søk per plattform, med endepunkt og fingeravtrykk', async () => {
    const { api: port, searches, closed } = api()
    const report = await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })

    expect(report.plans).toBe(1)
    expect(report.requests).toBe(1)
    expect(report.searches).toBe(1)
    expect(report.executed).toBe(1)
    expect(report.candidates).toBe(2)
    expect(searches[0]?.endpoint).toContain('ebi.ac.uk')
    expect(searches[0]?.responseDigest).toMatch(/^sha256:/)
    expect(closed).toHaveLength(1)
  })

  // Runden er det som slipper den semantiske oppgaven fram. Lukkes den ikke,
  // står planen for alltid, og ingenting sier hvorfor.
  it('lukker hver runde, og teller oppgavene lukkingen åpnet', async () => {
    const { api: port } = api()
    const report = await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(report.fulfilled).toBe(1)
    expect(report.tasksOpened).toBe(1)
  })

  it('lukker runden også når ingen søkevei svarte', async () => {
    const closeRequest = vi.fn().mockResolvedValue({ state: 'unavailable', enqueuedJob: true })
    const { api: port, searches } = api({ closeRequest })
    const report = await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: async () => ({ status: 'error', message: 'tidsavbrudd' }),
    })

    expect(searches[0]?.outcome).toBe('unavailable')
    expect(searches[0]?.responseDigest).toBeNull()
    expect(closeRequest).toHaveBeenCalledTimes(1)
    expect(report.stillUnavailable).toBe(1)
    // Og oppgaven slippes likevel fram: en tjeneste som er nede, skal ikke
    // kunne stanse arbeidet for alltid (SOURCE_POLICY.md §8.2).
    expect(report.tasksOpened).toBe(1)
  })

  // En kjører som mangler en metode databasen kjenner, er en utrullingsfeil.
  // Lukket runden seg likevel, ville den blitt «utilgjengelig» uten at en eneste
  // tjeneste var spurt — og sporet ville blitt gitt opp på en feil i koden.
  it('lar runden stå åpen, uten ett søk, når kjøreren mangler en metode den ber om', async () => {
    const closeRequest = vi.fn()
    const completeRun = vi.fn().mockResolvedValue(undefined)
    const { api: port, searches } = api({
      closeRequest,
      completeRun,
      work: async () => [
        {
          ...PLAN,
          requests: [
            request({
              methods: [
                { platform: 'Europe PMC', method: 'keyword' },
                { platform: 'Europe PMC', method: 'finnes_ikke' },
              ],
            }),
          ],
        },
      ],
    })
    const fetcher = vi.fn(recorded('europe-pmc-sertraline.json'))
    const report = await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher,
    })

    expect(fetcher).not.toHaveBeenCalled()
    expect(searches).toHaveLength(0)
    expect(closeRequest).not.toHaveBeenCalled()
    expect(report.problems.join(' ')).toContain('finnes_ikke')
    expect(report.problems.join(' ')).toContain('runden står åpen')
    expect(completeRun).toHaveBeenCalledWith(
      'c'.repeat(8),
      'failed',
      expect.anything(),
      expect.stringContaining('finnes_ikke'),
    )
  })

  // Et søk som ble utført, men ikke registrert, er en teknisk svikt. Lukket
  // runden seg, ville den stått som utført eller utilgjengelig på et grunnlag
  // søkeloggen ikke har, og den semantiske oppgaven ville blitt sluppet fram.
  it('lar runden stå åpen og merker kjøringen mislykket når et søk ikke lar seg registrere', async () => {
    const closeRequest = vi.fn()
    const completeRun = vi.fn().mockResolvedValue(undefined)
    const { api: port } = api({
      closeRequest,
      completeRun,
      recordSearch: async () => {
        throw new Error('nede')
      },
    })
    const report = await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })

    expect(closeRequest).not.toHaveBeenCalled()
    expect(report.problems.join(' ')).toContain('runden står åpen')
    expect(completeRun).toHaveBeenCalledWith(
      'c'.repeat(8),
      'failed',
      expect.objectContaining({ searches_recorded: 0, requests_closed: 0 }),
      expect.stringContaining('lot seg ikke registrere'),
    )
  })

  it('merker kjøringen vellykket når alt ble registrert og lukket', async () => {
    const completeRun = vi.fn().mockResolvedValue(undefined)
    const { api: port } = api({ completeRun })
    await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(completeRun).toHaveBeenCalledWith(
      'c'.repeat(8),
      'succeeded',
      expect.objectContaining({ requests_closed: 1 }),
    )
  })

  it('tar høyst så mange planer som kjøringen er bedt om', async () => {
    const many = Array.from({ length: 8 }, () => PLAN)
    const { api: port } = api({ work: async () => many })
    const report = await runMonographDiscovery(port, {
      maxPlans: 3,
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(report.plans).toBe(3)
  })

  // En plan som ikke lot seg registrere, er et problem — ikke en grunn til at
  // resten av monografien skal stå.
  it('fortsetter når ett søk ikke lot seg registrere', async () => {
    const { api: port } = api({
      recordSearch: async () => {
        throw new Error('avvist')
      },
    })
    const report = await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(report.searches).toBe(1)
    expect(report.problems).toHaveLength(1)
    expect(report.problems[0]).toContain('Europe PMC')
  })

  it('fortsetter til neste plan når en kjøring ikke lot seg åpne', async () => {
    const beginRun = vi.fn().mockRejectedValue(new Error('avvist'))
    const { api: port, searches } = api({ work: async () => [PLAN, PLAN], beginRun })
    const report = await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(beginRun).toHaveBeenCalledTimes(2)
    expect(searches).toHaveLength(0)
    expect(report.problems).toHaveLength(2)
  })

  it('åpner ingen kjøring for en plan uten en åpen runde', async () => {
    const beginRun = vi.fn()
    const { api: port } = api({
      work: async () => [{ ...PLAN, requests: [] }],
      beginRun,
    })
    const report = await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
    })
    expect(beginRun).not.toHaveBeenCalled()
    expect(report.searches).toBe(0)
  })

  // Rapporten er en driftssetning. Den navngir ingen kilde og ingen
  // avgrensning: loggen kan være offentlig.
  it('rapporterer uten å navngi en kilde eller en avgrensning', async () => {
    const { api: port } = api()
    const report = await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    const text = describeDiscoveryReport(report)
    expect(text).toContain('Søkeplaner tatt: 1')
    expect(text).not.toContain('sertralin')
    expect(text).not.toContain('vektendring')
  })
})

// ----------------------------------------------------------------------------
// Runden bestemmer hva som søkes
// ----------------------------------------------------------------------------

describe('søkerunden', () => {
  it('erklærer bare de sporene runden faktisk fikk', async () => {
    const { api: port, searches } = api({
      work: async () => [{ ...PLAN, requests: [request({ trackCodes: [] })] }],
    })
    await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })

    // Dekningskontrollens motsøk får ingen spor. Et søk som erklærte et
    // likevel, ville produsert den dekningen kontrollen skal kontrollere.
    expect(searches).toHaveLength(1)
    expect(searches[0]?.trackCodes).toEqual([])
  })

  // Regresjonen Codex fanget: runden får ALLE kildeprofilens obligatoriske
  // spor, men Europe PMC dekker bare det bibliografiske. Uten skjæringen ville
  // ett vellykket søk merket forsøksregistre og referanselister som dekket, og
  // porten ville sett dekket ut for spor ingen hadde søkt i.
  it('erklærer aldri et spor plattformen ikke dekker', async () => {
    const { api: port, searches } = api({
      work: async () => [
        {
          ...PLAN,
          requests: [
            request({
              trackCodes: [
                'bibliographic_database',
                'trial_registry',
                'reference_lists',
                'norwegian_authority_source',
              ],
            }),
          ],
        },
      ],
    })
    await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(searches[0]?.trackCodes).toEqual(['bibliographic_database'])
  })

  it('erklærer sporene runden fikk av databasen', async () => {
    const { api: port, searches } = api({
      work: async () => [
        { ...PLAN, requests: [request({ trackCodes: ['bibliographic_database'] })] },
      ],
    })
    await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(searches[0]?.trackCodes).toEqual(['bibliographic_database'])
  })

  it('søker bare i den plattformen runden navnga', async () => {
    const { api: port, searches } = api({
      work: async () => [{ ...PLAN, requests: [request({ platform: 'Crossref' })] }],
    })
    await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC'), keyword('Crossref')],
      politeness: false,
      fetcher: recorded('crossref-sertraline.json'),
    })
    expect(searches.map((search) => search.platform)).toEqual(['Crossref'])
  })

  it('kjører én målrettet passering per akse når runden ba om det', async () => {
    const { api: port, searches } = api({
      work: async () => [
        {
          ...PLAN,
          scope: { drug: 'sertralin', indication: 'depressiv lidelse', outcome: 'vektendring' },
          requests: [request({ strategy: 'targeted' })],
        },
      ],
    })
    await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(searches.map((search) => search.queryString)).toEqual([
      '"sertralin" AND "depressiv lidelse"',
      '"sertralin" AND "vektendring"',
    ])
  })

  it('søker virkestoffsynonymer som alternativer, ikke som et krav i tillegg', async () => {
    const { api: port, searches } = api({
      work: async () => [
        {
          ...PLAN,
          scope: { drug: 'sertralin' },
          requests: [request({ strategy: 'targeted', drugAliases: ['sertraline'] })],
        },
      ],
    })
    await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    // «"sertralin" AND "sertraline"» ville utelukket nettopp de artiklene som
    // bare bruker det engelske navnet — de søket var ment å finne.
    expect(searches[0]?.queryString).toBe('("sertralin" OR "sertraline")')
  })

  it('tar med de termene forespørselen ba om', async () => {
    const { api: port, searches } = api({
      work: async () => [
        {
          ...PLAN,
          scope: { drug: 'sertralin' },
          requests: [request({ strategy: 'targeted', queryTerms: ['weight gain'] })],
        },
      ],
    })
    await runMonographDiscovery(port, {
      methods: [keyword('Europe PMC')],
      politeness: false,
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(searches[0]?.queryString).toBe('"sertralin" AND "weight gain"')
  })
})

// ----------------------------------------------------------------------------
// Metodene: kjøreren utfører det databasen sier runden betyr (migrasjon 014d)
// ----------------------------------------------------------------------------

describe('søkemetodene runden bestilte', () => {
  it('utfører nøyaktig den metoden runden ber om, og bærer metoden videre til registreringen', async () => {
    const { api: port, searches } = api({
      work: async () => [
        {
          ...PLAN,
          profileCode: 'EFF',
          requests: [
            request({
              platform: 'PubMed',
              method: 'systematic_review_filter',
              methods: [{ platform: 'PubMed', method: 'systematic_review_filter' }],
              trackCodes: ['systematic_review_search', 'bibliographic_database'],
            }),
          ],
        },
      ],
    })
    await runMonographDiscovery(port, {
      fetcher: recorded('pubmed-sertraline.json'),
      politeness: false,
    })
    expect(searches).toHaveLength(1)
    expect(searches[0]?.platform).toBe('PubMed')
    expect(searches[0]?.method).toBe('systematic_review_filter')
    expect(searches[0]?.queryString).toContain('systematic[sb]')
    // Oversiktsfilteret dekker oversiktssporet og ikke det bibliografiske: det
    // er et annet søk enn fritekstsøket, selv mot den samme tjenesten.
    expect(searches[0]?.trackCodes).toEqual(['systematic_review_search'])
  })

  it('følger bare de sentrale kildene runden navnga', async () => {
    const seen: string[] = []
    const fetcher: Fetcher = async (url) => {
      seen.push(url)
      return {
        status: 'ok',
        httpStatus: 200,
        contentType: 'application/json',
        bytes: new TextEncoder().encode(
          readFileSync('src/ops/fixtures/europe-pmc-references.json', 'utf8'),
        ),
        finalUrl: url,
      }
    }
    const { api: port, searches } = api({
      work: async () => [
        {
          ...PLAN,
          profileCode: 'EFF',
          requests: [
            request({
              method: 'references',
              seedIdentifiers: ['pmid:37032427'],
              methods: [{ platform: 'Europe PMC', method: 'references' }],
              trackCodes: ['reference_lists'],
            }),
          ],
        },
      ],
    })
    await runMonographDiscovery(port, { fetcher, politeness: false })
    expect(seen.every((url) => url.includes('/MED/37032427/references'))).toBe(true)
    expect(searches[0]?.queryString).toBe('Referanselisten til pmid:37032427')
    expect(searches[0]?.trackCodes).toEqual(['reference_lists'])
    expect(searches[0]?.candidates.length).toBeGreaterThan(0)
  })

  it('bruker katalogens synonymer for virkestoffet i hver metode', async () => {
    const { api: port, searches } = api({
      work: async () => [
        {
          ...PLAN,
          scope: { drug: 'sertralin', drugAliases: ['sertraline'] },
          requests: [request({ methods: [{ platform: 'Europe PMC', method: 'keyword' }] })],
        },
      ],
    })
    await runMonographDiscovery(port, {
      fetcher: recorded('europe-pmc-sertraline.json'),
      politeness: false,
    })
    expect(searches[0]?.queryString).toBe('("sertralin" OR "sertraline")')
  })
})
