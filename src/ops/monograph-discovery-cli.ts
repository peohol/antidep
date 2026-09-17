// ============================================================================
// Kjøreren for de maskinelt utførte søkene
//
//   npm run ops:discovery
//
// Teknisk drift, ikke en produktflate. Kommandoen henter det arbeidet
// kildeoppdagelsen har åpent, kjører søkene mot de tre offentlige plattformene,
// og registrerer dem gjennom den kontrollerte skriveveien.
//
// Ingen modellnøkkel finnes her, og ingen trengs: å kalle et søke-API og lese
// svaret er deterministisk kode. Den *faglige* kildeoppdagelsen — å planlegge
// søket og velge kildene — er en ekstern KI-agent med sin egen identitet, og
// den går gjennom agentarbeidsflaten. De to veiene holdes fra hverandre i
// databasen, og det er hele poenget.
// ============================================================================

import { createAgentClient } from '../agents/agent-api.ts'
import { readAgentConfig } from '../agents/agent-environment.ts'
import { guardedGet } from '../agents/guarded-http.ts'
import {
  DISCOVERY_REGISTRATION_PREMISES,
  describeDiscoveryReport,
  runMonographDiscovery,
  type DiscoveryApi,
  type DiscoveryPlan,
} from './monograph-discovery.ts'
import type { MachineSearch } from './monograph-search.ts'

const USAGE = `Bruk:
  npm run ops:discovery [-- valg]

Valg:
  --max-plans <n>   Hvor mange søkeplaner kjøringen tar (standard 5)
  --dry-run         Vis hvilke planer som ville blitt søkt for, uten å søke
  --help            Vis denne teksten

Miljø:
  ANTIDEP_SUPABASE_URL
  ANTIDEP_SUPABASE_PUBLISHABLE_KEY
  ANTIDEP_DISCOVERY_AGENT_IDENTITY_KEY
  ANTIDEP_DISCOVERY_AGENT_SECRET`

/** Legitimasjonen kildeoppdagelsen kjører med. Eget par, som hvert annet ledd. */
export const DISCOVERY_CREDENTIAL = {
  identityKey: 'ANTIDEP_DISCOVERY_AGENT_IDENTITY_KEY',
  secret: 'ANTIDEP_DISCOVERY_AGENT_SECRET',
} as const

interface Arguments {
  readonly maxPlans: number
  readonly dryRun: boolean
  readonly help: boolean
}

export function parseArguments(argv: readonly string[]): Arguments {
  let maxPlans = 5
  let dryRun = false
  let help = false

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') {
      help = true
    } else if (argument === '--dry-run') {
      dryRun = true
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

  return { maxPlans, dryRun, help }
}

function planFrom(row: Record<string, unknown>): DiscoveryPlan {
  const scope = (row['scope'] ?? {}) as Record<string, unknown>
  const profile = (row['profile'] ?? {}) as Record<string, unknown>
  const asText = (value: unknown): string | undefined =>
    typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined

  const tracks = Array.isArray(row['tracks']) ? (row['tracks'] as unknown[]) : []

  return {
    planReference: String(row['plan_reference'] ?? ''),
    drug: String(row['drug'] ?? ''),
    editionReference: String(row['edition_reference'] ?? ''),
    profileCode: String(profile['code'] ?? '?'),
    requiredTracks: tracks
      .map((track) => String((track as Record<string, unknown>)['code'] ?? ''))
      .filter((code) => code.length > 0),
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

  const config = readAgentConfig(process.env, DISCOVERY_CREDENTIAL)
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
        p_agent_role: 'source_discovery',
        p_provider: DISCOVERY_REGISTRATION_PREMISES.provider,
        p_model: DISCOVERY_REGISTRATION_PREMISES.model,
        p_model_version: DISCOVERY_REGISTRATION_PREMISES.modelVersion,
        p_prompt_template_version: DISCOVERY_REGISTRATION_PREMISES.promptTemplateVersion,
        p_pipeline_version: DISCOVERY_REGISTRATION_PREMISES.pipelineVersion,
        p_input_manifest: { search_plan_reference: planReference, mode: 'machine_executed' },
      })
      if (error !== null || typeof data !== 'string') {
        throw new Error('Kjøringen kunne ikke åpnes.')
      }
      return data
    },

    async recordSearch(agentRunId, planReference, search: MachineSearch) {
      const { error } = await client.rpc('record_monograph_machine_search', {
        ...identity,
        p_agent_run_id: agentRunId,
        p_plan_reference: planReference,
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
    console.log(`Åpne søkeplaner: ${plans.length}`)
    for (const plan of plans.slice(0, args.maxPlans)) {
      console.log(`  ${plan.profileCode}  ${plan.planReference}`)
    }
    return
  }

  const report = await runMonographDiscovery(api, {
    maxPlans: args.maxPlans,
    fetcher: guardedGet,
  })
  console.log(describeDiscoveryReport(report))
  if (report.problems.length > 0) {
    process.exitCode = 1
  }
}

await main()
