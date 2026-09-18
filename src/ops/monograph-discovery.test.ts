import { readFileSync } from 'node:fs'
import { describe, expect, it, vi } from 'vitest'

import {
  describeDiscoveryReport,
  runMonographDiscovery,
  type DiscoveryApi,
  type DiscoveryPlan,
} from './monograph-discovery.ts'
import { EUROPE_PMC, type Fetcher, type MachineSearch } from './monograph-search.ts'

const PLAN: DiscoveryPlan = {
  planReference: 'a'.repeat(32),
  drug: 'sertralin',
  editionReference: 'b'.repeat(32),
  profileCode: 'AE',
  scope: { drug: 'sertralin', outcome: 'vektendring' },
  requiredTracks: ['bibliographic_database', 'trial_registry'],
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
} {
  const searches: MachineSearch[] = []
  return {
    searches,
    api: {
      work: async () => [PLAN],
      beginRun: async () => 'c'.repeat(8),
      recordSearch: async (_run, _plan, search) => {
        searches.push(search)
      },
      completeRun: async () => undefined,
      ...overrides,
    },
  }
}

describe('runMonographDiscovery', () => {
  it('registrerer ett søk per plattform, med endepunkt og fingeravtrykk', async () => {
    const { api: port, searches } = api()
    const report = await runMonographDiscovery(port, {
      platforms: [EUROPE_PMC],
      fetcher: recorded('europe-pmc-sertraline.json'),
    })

    expect(report.plans).toBe(1)
    expect(report.searches).toBe(1)
    expect(report.executed).toBe(1)
    expect(report.candidates).toBe(2)
    expect(searches[0]?.endpoint).toContain('ebi.ac.uk')
    expect(searches[0]?.responseDigest).toMatch(/^sha256:/)
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
// Sporene et søk kan erklære
// ----------------------------------------------------------------------------

describe('søkesporene', () => {
  it('erklærer bare de sporene kildeprofilen faktisk krever', async () => {
    const { api: port, searches } = api({
      work: async () => [{ ...PLAN, requiredTracks: ['trial_registry'] }],
    })
    await runMonographDiscovery(port, {
      platforms: [EUROPE_PMC],
      fetcher: recorded('europe-pmc-sertraline.json'),
    })

    // Europe PMC kan dekke `bibliographic_database`, men profilen her krever
    // det ikke. Et søk som erklærte det likevel, ville fått porten til å se
    // dekket ut for et spor ingen ba om — og databasen avviser det, med rette.
    expect(searches.length).toBe(1)
    expect(searches[0]?.trackCodes).toEqual([])
    expect(searches[0]?.outcome).toBe('executed')
  })

  it('erklærer sporet når profilen krever det', async () => {
    const { api: port, searches } = api({
      work: async () => [{ ...PLAN, requiredTracks: ['bibliographic_database'] }],
    })
    await runMonographDiscovery(port, {
      platforms: [EUROPE_PMC],
      fetcher: recorded('europe-pmc-sertraline.json'),
    })
    expect(searches[0]?.trackCodes).toEqual(['bibliographic_database'])
  })
})
