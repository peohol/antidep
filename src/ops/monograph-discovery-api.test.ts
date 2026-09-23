import { describe, expect, it } from 'vitest'

import type { AgentClient } from '../agents/agent-api.ts'
import { createDiscoveryApi, planFrom } from './monograph-discovery-api.ts'
import type { MachineSearch } from './monograph-search.ts'

// ============================================================================
// Databasegrensen driftskjøringen og ende-til-ende-prøven deler
// ============================================================================

const IDENTITY = { p_identity_key: 'agent-identity:source-discovery-01', p_secret: 'hemmelig' }
const PLAN = '0123456789abcdef0123456789abcdef'

function fake(answers: Record<string, unknown>): {
  readonly client: AgentClient
  readonly calls: { fn: string; args: Record<string, unknown> }[]
} {
  const calls: { fn: string; args: Record<string, unknown> }[] = []
  const client = {
    rpc: (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args })
      return Promise.resolve({ data: answers[fn] ?? null, error: null })
    },
  }
  return { client: client as unknown as AgentClient, calls }
}

const SEARCH: MachineSearch = {
  platform: 'PubMed',
  method: 'systematic_review_filter',
  queryString: '("sertraline") AND systematic[sb]',
  filters: 'systematic[sb]; retmax=25',
  endpoint: 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed',
  responseDigest: `sha256:${'a'.repeat(64)}`,
  outcome: 'executed',
  resultCount: 3,
  screenedCount: 3,
  truncated: false,
  truncationNote: null,
  limitationNote: null,
  trackCodes: ['systematic_review_search'],
  candidates: [],
}

describe('databasegrensen for søkekjøringen', () => {
  it('ber om alle åpne planer uten en planreferanse, og bare den ene med', async () => {
    const alle = fake({ monograph_discovery_work: { plans: [] } })
    await createDiscoveryApi(alle.client, IDENTITY, 'discovery').work()
    expect(alle.calls[0]?.args).toEqual({ ...IDENTITY, p_plan_reference: null })

    const en = fake({ monograph_discovery_work: { plans: [] } })
    await createDiscoveryApi(en.client, IDENTITY, 'discovery', PLAN).work()
    expect(en.calls[0]?.args['p_plan_reference']).toBe(PLAN)
  })

  it('registrerer søket med metoden det brukte, og ikke bare plattformen', async () => {
    const { client, calls } = fake({})
    await createDiscoveryApi(client, IDENTITY, 'discovery').recordSearch(
      'kjoring',
      PLAN,
      'runde',
      SEARCH,
    )
    expect(calls[0]?.fn).toBe('record_monograph_machine_search')
    expect(calls[0]?.args).toMatchObject({
      p_platform: 'PubMed',
      p_search_method: 'systematic_review_filter',
      p_track_codes: ['systematic_review_search'],
    })
  })

  // Leddet tar igjen sine egne overganger med sin egen identitet, og ingenting
  // annet: databasen avgjør selv hva tilstanden tilsier (migrasjon 014h).
  it('tar igjen leddets overganger med identiteten alene, og teller oppgavene', async () => {
    const { client, calls } = fake({
      resume_search_round_tasks: { agent_role: 'source_discovery', tasks_enqueued: 2 },
    })
    const opened = await createDiscoveryApi(client, IDENTITY, 'discovery', PLAN).catchUp()
    expect(calls).toEqual([{ fn: 'resume_search_round_tasks', args: IDENTITY }])
    expect(opened).toBe(2)
  })

  it('åpner kjøringen under leddets egen rolle', async () => {
    const { client, calls } = fake({ begin_agent_run: 'kjoring' })
    await createDiscoveryApi(client, IDENTITY, 'coverage').beginRun(PLAN)
    expect(calls[0]?.args['p_agent_role']).toBe('source_quality_assessment')
  })

  it('leser metodene, kildene og avgrensningen slik databasen gir dem', () => {
    const plan = planFrom({
      plan_reference: PLAN,
      drug: 'sertralin',
      profile: { code: 'EFF' },
      scope: { drug: 'sertralin', drug_aliases: ['sertraline'], atc_codes: ['N06AB06'] },
      requests: [
        {
          request_reference: 'runde',
          strategy: 'broad',
          platform: 'Europe PMC',
          method: 'references',
          methods: [{ platform: 'Europe PMC', method: 'references' }, { platform: '' }],
          seed_identifiers: ['doi:10.1000/x', ''],
          track_codes: ['reference_lists'],
        },
      ],
    })
    expect(plan.scope.atcCodes).toEqual(['N06AB06'])
    expect(plan.requests[0]).toMatchObject({
      platform: 'Europe PMC',
      method: 'references',
      methods: [{ platform: 'Europe PMC', method: 'references' }],
      seedIdentifiers: ['doi:10.1000/x'],
      trackCodes: ['reference_lists'],
    })
  })
})
