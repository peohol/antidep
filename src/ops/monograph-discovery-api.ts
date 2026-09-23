// ============================================================================
// Databasegrensen søkekjøreren går gjennom
//
// De fem kallene `runMonographDiscovery` kjenner (`DiscoveryApi`), mot de
// autoriserte api-funksjonene, med ett ledds egen identitet og legitimasjon.
// Står for seg framfor inne i kommandoen, slik at driftskjøringen og
// ende-til-ende-prøven (`scripts/monograph-e2e.ts`) går gjennom nøyaktig den
// samme grensen: en prøve med sin egen avlesning av søkearbeidet ville bestått
// på en avlesning driften ikke bruker.
// ============================================================================

import type { AgentClient } from '../agents/agent-api.ts'
import {
  LEGS,
  type DiscoveryApi,
  type DiscoveryLeg,
  type DiscoveryPlan,
  type SearchRequest,
} from './monograph-discovery.ts'
import type { MachineSearch } from './monograph-search.ts'

/** Identiteten og legitimasjonen ett kildeledd kjører med, i klartekst for kallet. */
export interface DiscoveryIdentity {
  readonly p_identity_key: string
  readonly p_secret: string
}

function asText(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined
}

function textList(value: unknown): readonly string[] {
  return Array.isArray(value)
    ? value.map((entry) => asText(entry)).filter((entry): entry is string => entry !== undefined)
    : []
}

export function requestFrom(row: Record<string, unknown>): SearchRequest {
  const terms = Array.isArray(row['query_terms']) ? (row['query_terms'] as unknown[]) : []
  const aliases = Array.isArray(row['drug_aliases']) ? (row['drug_aliases'] as unknown[]) : []
  const tracks = Array.isArray(row['track_codes']) ? (row['track_codes'] as unknown[]) : []
  const methods = Array.isArray(row['methods']) ? (row['methods'] as unknown[]) : []
  const seeds = Array.isArray(row['seed_identifiers']) ? (row['seed_identifiers'] as unknown[]) : []
  return {
    requestReference: String(row['request_reference'] ?? ''),
    searchRound: Number(row['search_round'] ?? 1),
    origin: String(row['origin'] ?? ''),
    strategy: row['strategy'] === 'broad' ? 'broad' : 'targeted',
    rationale: String(row['rationale'] ?? ''),
    platform: asText(row['platform']) ?? null,
    method: asText(row['method']) ?? null,
    methods: methods
      .map((entry) => entry as Record<string, unknown>)
      .map((entry) => ({
        platform: String(entry['platform'] ?? ''),
        method: String(entry['method'] ?? ''),
      }))
      .filter((entry) => entry.platform.length > 0 && entry.method.length > 0),
    seedIdentifiers: seeds.map((seed) => String(seed)).filter((seed) => seed.length > 0),
    drugAliases: aliases.map((alias) => String(alias)).filter((alias) => alias.length > 0),
    queryTerms: terms.map((term) => String(term)).filter((term) => term.length > 0),
    filtersNote: asText(row['filters_note']) ?? null,
    trackCodes: tracks.map((track) => String(track)).filter((track) => track.length > 0),
    attempts: Number(row['attempts'] ?? 0),
    state: String(row['state'] ?? 'pending'),
  }
}

export function planFrom(row: Record<string, unknown>): DiscoveryPlan {
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
      drugAliases: textList(scope['drug_aliases']),
      atcCodes: textList(scope['atc_codes']),
    },
  }
}

/**
 * `DiscoveryApi` for ett ledd, mot de autoriserte api-funksjonene. Med en
 * planreferanse henter den bare den planens åpne runder.
 */
export function createDiscoveryApi(
  client: AgentClient,
  identity: DiscoveryIdentity,
  legName: DiscoveryLeg,
  planReference: string | null = null,
): DiscoveryApi {
  const leg = LEGS[legName]
  return {
    async work() {
      const { data, error } = await client.rpc('monograph_discovery_work', {
        ...identity,
        p_plan_reference: planReference,
      })
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
        p_search_method: search.method,
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
}
