// ============================================================================
// Kjøreren for de maskinelt utførte søkene
//
//   npm run ops:discovery                    # kildeoppdagelsens egne søk
//   npm run ops:discovery -- --leg coverage  # dekningskontrollens motsøk
//
// Teknisk drift, ikke en produktflate. Kommandoen henter de søkerundene som
// står åpne for det leddet legitimasjonen gjelder, kjører søkene mot de
// navngitte offentlige plattformene, og registrerer dem gjennom den
// kontrollerte skriveveien.
//
// Ingen modellnøkkel finnes her, og ingen trengs: å kalle et søke-API og lese
// svaret er deterministisk kode. Den *faglige* kildeoppdagelsen — å vurdere
// treffene og velge kildene — er en ekstern KI-agent med sin egen identitet, og
// den går gjennom agentarbeidsflaten. De to veiene holdes fra hverandre i
// databasen, og det er hele poenget.
//
// ----------------------------------------------------------------------------
// Hvorfor kommandoen har to ledd
//
// Fordi dekningskontrollen skal ha sine EGNE motsøk (SOURCE_POLICY.md §6), og
// et motsøk registrert under generatorens identitet ville ikke vært et motsøk.
// De to leddene har hver sin legitimasjon, hver sin registreringstildeling og
// hver sin søkestrategi — og databasen utleder kontrollens uavhengighet av
// hvilken rolle kjøringen faktisk gikk under. Det er derfor `--leg` finnes, og
// derfor den planlagte kjøringen kjører begge.
// ============================================================================

import { createAgentClient } from '../agents/agent-api.ts'
import { readAgentConfig, type AgentCredentialVariables } from '../agents/agent-environment.ts'
import { guardedGet } from '../agents/guarded-http.ts'
import {
  describeDiscoveryReport,
  LEGS,
  runMonographDiscovery,
  type DiscoveryApi,
  type DiscoveryLeg,
  type DiscoveryPlan,
  type SearchRequest,
} from './monograph-discovery.ts'
import type { MachineSearch } from './monograph-search.ts'

const USAGE = `Bruk:
  npm run ops:discovery [-- valg]

Valg:
  --leg <discovery|coverage>  Hvilket kildeledd søkene utføres for (standard discovery)
  --max-plans <n>             Hvor mange søkeplaner kjøringen tar (standard 5)
  --dry-run                   Vis hvilke runder som ville blitt søkt for, uten å søke
  --help                      Vis denne teksten

Miljø:
  ANTIDEP_SUPABASE_URL
  ANTIDEP_SUPABASE_PUBLISHABLE_KEY
  ANTIDEP_DISCOVERY_AGENT_IDENTITY_KEY / ANTIDEP_DISCOVERY_AGENT_SECRET   (--leg discovery)
  ANTIDEP_COVERAGE_AGENT_IDENTITY_KEY  / ANTIDEP_COVERAGE_AGENT_SECRET    (--leg coverage)`

/** Legitimasjonen kildeoppdagelsen kjører med. Eget par, som hvert annet ledd. */
export const DISCOVERY_CREDENTIAL: AgentCredentialVariables = {
  identityKey: 'ANTIDEP_DISCOVERY_AGENT_IDENTITY_KEY',
  secret: 'ANTIDEP_DISCOVERY_AGENT_SECRET',
}

/**
 * Og legitimasjonen dekningskontrollens motsøk kjører med.
 *
 * Eget par, og det er ikke ryddighet: identiteten autentiseres for *rollen*
 * sin, og et motsøk registrert under kildeoppdagelsens nøkkel ville blitt ført
 * som generatorens eget søk. Da ville kontrollens uavhengighet vært en
 * formulering framfor en rad (SOURCE_POLICY.md §6).
 */
export const COVERAGE_CREDENTIAL: AgentCredentialVariables = {
  identityKey: 'ANTIDEP_COVERAGE_AGENT_IDENTITY_KEY',
  secret: 'ANTIDEP_COVERAGE_AGENT_SECRET',
}

export const LEG_CREDENTIALS: Readonly<Record<DiscoveryLeg, AgentCredentialVariables>> = {
  discovery: DISCOVERY_CREDENTIAL,
  coverage: COVERAGE_CREDENTIAL,
}

interface Arguments {
  readonly leg: DiscoveryLeg
  readonly maxPlans: number
  readonly dryRun: boolean
  readonly help: boolean
}

export function parseArguments(argv: readonly string[]): Arguments {
  let leg: DiscoveryLeg = 'discovery'
  let maxPlans = 5
  let dryRun = false
  let help = false

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') {
      help = true
    } else if (argument === '--dry-run') {
      dryRun = true
    } else if (argument === '--leg') {
      const value = argv[index + 1] ?? ''
      if (value !== 'discovery' && value !== 'coverage') {
        throw new Error('--leg må være discovery eller coverage.')
      }
      leg = value
      index += 1
    } else if (argument === '--max-plans') {
      const value = Number.parseInt(argv[index + 1] ?? '', 10)
      if (!Number.isInteger(value) || value < 1 || value > 50) {
        throw new Error('--max-plans må være et tall mellom 1 og 50.')
      }
      maxPlans = value
      index += 1
    } else {
      throw new Error(`Ukjent valg: ${argument}`)
    }
  }

  return { leg, maxPlans, dryRun, help }
}

function asText(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined
}

function requestFrom(row: Record<string, unknown>): SearchRequest {
  const terms = Array.isArray(row['query_terms']) ? (row['query_terms'] as unknown[]) : []
  const tracks = Array.isArray(row['track_codes']) ? (row['track_codes'] as unknown[]) : []
  return {
    requestReference: String(row['request_reference'] ?? ''),
    searchRound: Number(row['search_round'] ?? 1),
    origin: String(row['origin'] ?? ''),
    strategy: row['strategy'] === 'broad' ? 'broad' : 'targeted',
    rationale: String(row['rationale'] ?? ''),
    platform: asText(row['platform']) ?? null,
    queryTerms: terms.map((term) => String(term)).filter((term) => term.length > 0),
    filtersNote: asText(row['filters_note']) ?? null,
    trackCodes: tracks.map((track) => String(track)).filter((track) => track.length > 0),
    attempts: Number(row['attempts'] ?? 0),
    state: String(row['state'] ?? 'pending'),
  }
}

function planFrom(row: Record<string, unknown>): DiscoveryPlan {
  const scope = (row['scope'] ?? {}) as Record<string, unknown>
  const profile = (row['profile'] ?? {}) as Record<string, unknown>
  const requests = Array.isArray(row['requests']) ? (row['requests'] as unknown[]) : []

  return {
    planReference: String(row['plan_reference'] ?? ''),
    drug: String(row['drug'] ?? ''),
    editionReference: String(row['edition_reference'] ?? ''),
    profileCode: String(profile['code'] ?? '?'),
    searchRound: Number(row['search_round'] ?? 1),
    requests: requests.map((entry) => requestFrom(entry as Record<string, unknown>)),
    scope: {
      drug: asText(scope['drug']) ?? String(row['drug'] ?? ''),
      indication: asText(scope['indication']),
      outcome: asText(scope['outcome']),
      population: asText(scope['population']),
      comparator: asText(scope['comparator']),
    },
  }
}

async function main(): Promise<void> {
  let args: Arguments
  try {
    args = parseArguments(process.argv.slice(2))
  } catch (error) {
    console.error(error instanceof Error ? error.message : 'Ugyldige argumenter.')
    console.error(USAGE)
    process.exitCode = 2
    return
  }

  if (args.help) {
    console.log(USAGE)
    return
  }

  const leg = LEGS[args.leg]
  const config = readAgentConfig(process.env, LEG_CREDENTIALS[args.leg])
  const client = createAgentClient(config)
  const identity = {
    p_identity_key: config.credential.identityKey,
    p_secret: config.credential.secret.reveal(),
  }

  const api: DiscoveryApi = {
    async work() {
      const { data, error } = await client.rpc('monograph_discovery_work', identity)
      if (error !== null) {
        throw new Error('Søkearbeidet kunne ikke hentes.')
      }
      // Svaret er ett dokument med `plans` i seg, og ikke en liste: funksjonen
      // bærer også hvilken identitet og hvilket ledd arbeidet ble hentet for.
      // En avlesning som forventet en liste, fikk aldri én eneste plan — og
      // ingenting sa fra, fordi «ingen åpne planer» er et gyldig svar.
      const payload = (data ?? {}) as Record<string, unknown>
      const rows = payload['plans']
      if (!Array.isArray(rows)) {
        throw new Error('Søkearbeidet kom uten en liste over søkeplaner.')
      }
      return rows.map((row) => planFrom(row as Record<string, unknown>))
    },

    async beginRun(planReference) {
      const { data, error } = await client.rpc('begin_agent_run', {
        ...identity,
        p_agent_role: leg.agentRole,
        p_provider: leg.premises.provider,
        p_model: leg.premises.model,
        p_model_version: leg.premises.modelVersion,
        p_prompt_template_version: leg.premises.promptTemplateVersion,
        p_pipeline_version: leg.premises.pipelineVersion,
        p_input_manifest: { search_plan_reference: planReference, mode: 'machine_executed' },
      })
      if (error !== null || typeof data !== 'string') {
        throw new Error('Kjøringen kunne ikke åpnes.')
      }
      return data
    },

    async recordSearch(agentRunId, planReference, requestReference, search: MachineSearch) {
      const { error } = await client.rpc('record_monograph_machine_search', {
        ...identity,
        p_agent_run_id: agentRunId,
        p_plan_reference: planReference,
        p_request_reference: requestReference,
        p_platform: search.platform,
        p_query_string: search.queryString,
        p_filters: search.filters,
        p_endpoint: search.endpoint,
        p_response_digest: search.responseDigest,
        p_outcome: search.outcome,
        p_result_count: search.resultCount,
        p_screened_count: search.screenedCount,
        p_truncated: search.truncated,
        p_truncation_note: search.truncationNote,
        p_limitation_note: search.limitationNote,
        p_track_codes: search.trackCodes,
        p_candidates: search.candidates,
      })
      if (error !== null) {
        throw new Error('Søket kunne ikke registreres.')
      }
    },

    async closeRequest(agentRunId, requestReference) {
      const { data, error } = await client.rpc('close_monograph_search_request', {
        ...identity,
        p_agent_run_id: agentRunId,
        p_request_reference: requestReference,
      })
      if (error !== null) {
        throw new Error('Søkerunden kunne ikke lukkes.')
      }
      const payload = (data ?? {}) as Record<string, unknown>
      return {
        state: String(payload['state'] ?? 'pending'),
        enqueuedJob: payload['enqueued_job'] === true,
      }
    },

    async completeRun(agentRunId, status, outcome) {
      const { error } = await client.rpc('complete_agent_run', {
        ...identity,
        p_agent_run_id: agentRunId,
        p_status: status,
        p_output_manifest: outcome,
        p_failure_reason: null,
      })
      if (error !== null) {
        throw new Error('Kjøringen kunne ikke lukkes.')
      }
    },
  }

  if (args.dryRun) {
    const plans = await api.work()
    console.log(`Åpne søkeplaner for ${leg.label}: ${plans.length}`)
    for (const plan of plans.slice(0, args.maxPlans)) {
      console.log(
        `  ${plan.profileCode}  ${plan.planReference}  runder: ${String(plan.requests.length)}`,
      )
    }
    return
  }

  const report = await runMonographDiscovery(api, {
    maxPlans: args.maxPlans,
    fetcher: guardedGet,
  })
  console.log(`Ledd: ${leg.label}`)
  console.log(describeDiscoveryReport(report))
  if (report.problems.length > 0) {
    process.exitCode = 1
  }
}

await main()
