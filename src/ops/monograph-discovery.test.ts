import { readFileSync } from 'node:fs'
import { describe, expect, it, vi } from 'vitest'

import {
  describeDiscoveryReport,
  runMonographDiscovery,
  type DiscoveryApi,
  type DiscoveryPlan,
  type SearchRequest,
} from './monograph-discovery.ts'
import { CROSSREF, EUROPE_PMC, type Fetcher, type MachineSearch } from './monograph-search.ts'

function request(overrides: Partial<SearchRequest> = {}): SearchRequest {
  return {
    requestReference: 'd'.repeat(32),
    searchRound: 1,
    origin: 'plan_opened',
    strategy: 'broad',
    rationale: 'Den nye søkeplanens første maskinelle søkerunde.',
    platform: null,
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
      platforms: [EUROPE_PMC],
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
      platforms: [EUROPE_PMC],
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(report.fulfilled).toBe(1)
    expect(report.tasksOpened).toBe(1)
  })

  it('lukker runden også når ingen søkevei svarte', async () => {
    const closeRequest = vi.fn().mockResolvedValue({ state: 'unavailable', enqueuedJob: true })
    const { api: port, searches } = api({ closeRequest })
    const report = await runMonographDiscovery(port, {
      platforms: [EUROPE_PMC],
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

  it('tar høyst så mange planer som kjøringen er bedt om', async () => {
    const many = Array.from({ length: 8 }, () => PLAN)
    const { api: port } = api({ work: async () => many })
    const report = await runMonographDiscovery(port, {
      maxPlans: 3,
      platforms: [EUROPE_PMC],
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
      platforms: [EUROPE_PMC],
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
      platforms: [EUROPE_PMC],
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
    const report = await runMonographDiscovery(port, { platforms: [EUROPE_PMC] })
    expect(beginRun).not.toHaveBeenCalled()
    expect(report.searches).toBe(0)
  })

  // Rapporten er en driftssetning. Den navngir ingen kilde og ingen
  // avgrensning: loggen kan være offentlig.
  it('rapporterer uten å navngi en kilde eller en avgrensning', async () => {
    const { api: port } = api()
    const report = await runMonographDiscovery(port, {
      platforms: [EUROPE_PMC],
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
      platforms: [EUROPE_PMC],
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
      platforms: [EUROPE_PMC],
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
      platforms: [EUROPE_PMC],
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(searches[0]?.trackCodes).toEqual(['bibliographic_database'])
  })

  it('søker bare i den plattformen runden navnga', async () => {
    const { api: port, searches } = api({
      work: async () => [{ ...PLAN, requests: [request({ platform: 'Crossref' })] }],
    })
    await runMonographDiscovery(port, {
      platforms: [EUROPE_PMC, CROSSREF],
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
      platforms: [EUROPE_PMC],
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
      platforms: [EUROPE_PMC],
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
      platforms: [EUROPE_PMC],
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(searches[0]?.queryString).toBe('"sertralin" AND "weight gain"')
  })
})
