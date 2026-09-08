// ============================================================================
// Data API-flaten en agentkjører bruker
//
// Seks funksjoner, alle i `api`, alle kalt uten brukersesjon: en agent har ingen
// brukerkonto, så kalleren er `anon` i Data API-et og legitimasjonen — ikke
// Data API-rollen — er kontrollen (migrasjon 005e sin hodekommentar).
//
//   api.begin_agent_run                  åpner kjøringen og registrerer premissene
//   api.complete_agent_run               lukker kjøringen med et utfall
//   api.extraction_verification_input    grunnlaget ekstraksjonskontrollen gjøres mot (005h)
//   api.register_extraction_verification registrerer resultatet av den (005g)
//   api.claim_verification_input         grunnlaget claim-kontrollen gjøres mot (005k)
//   api.register_claim_verification      registrerer resultatet av den (005k)
//
// De to første er felles for alle agentledd; de fire andre kommer i par, ett par
// per rolle. Paret er grenseflaten det enkelte leddet kjenner, og kjøringen som
// omslutter det er den samme mekanismen i begge tilfeller — derfor er den
// skrevet én gang, i `createAgentRunApi`.
//
// ----------------------------------------------------------------------------
// Hvorfor typene utvider `Database` framfor å være en ny kopi
//
// `src/types/database.ts` beskriver kontraktslaget slik nettleseren ser det, og
// disse fire hører ikke hjemme der: appen skal aldri kalle dem, og en type som
// sa at den kunne, ville vært en invitasjon. Samtidig er viewene og de
// editorfunksjonene de samme objektene, og to uavhengige beskrivelser av samme
// schema ville kunnet drive fra hverandre. `AgentDatabase` utvider derfor den
// eksisterende typen med nøyaktig de fire.
//
// ----------------------------------------------------------------------------
// Hvorfor runneren snakker med en port og ikke med supabase-js direkte
//
// `ExtractionVerificationApi` er de fire kallene som en grenseflate. Runneren
// kjenner bare den, så hele orkestreringen — rekkefølgen, hva som skjer når
// kilden ikke lar seg hente, hva som skrives når kontrollen ikke konkluderer —
// kan prøves uten database og uten nett. Det er den samme grunnen til at
// `checkExtraction` er en ren funksjon.
// ============================================================================

import { createClient, type SupabaseClient } from '@supabase/supabase-js'

import type { Database } from '../types/database.ts'
import type { Uuid } from '../types/api.ts'
import type { AgentCredential } from './agent-credential.ts'

/** Kontraktslaget slik en agentkjører ser det: appens flate, pluss de fire. */
export type AgentDatabase = {
  api: Omit<Database['api'], 'Functions'> & {
    Functions: Database['api']['Functions'] & {
      begin_agent_run: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_role: string
          p_provider: string
          p_model: string
          p_model_version: string
          p_prompt_template_version: string
          p_pipeline_version: string
          p_input_manifest: Record<string, unknown>
        }
        Returns: Uuid
      }
      complete_agent_run: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_run_id: Uuid
          p_status: string
          p_output_manifest?: Record<string, unknown> | null
          p_failure_reason?: string | null
        }
        Returns: Uuid
      }
      claim_verification_input: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_run_id: Uuid
          p_claim_revision_id?: Uuid | null
        }
        // jsonb. Formen er dokumentert i migrasjon 005k og leses av
        // `parseClaimVerificationInput`, som avviser et svar som ikke har den.
        Returns: unknown
      }
      register_claim_verification: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_run_id: Uuid
          p_claim_revision_id: Uuid
          p_outcome: string
          p_source_support: string
          p_population_match: string
          p_comparator_match: string
          p_timeframe_match: string
          p_direction_and_magnitude: string
          p_qualifiers_complete: string
          p_contradictory_evidence_represented: string
          p_citations: readonly Record<string, unknown>[]
          p_rationale: string
          p_findings?: string | null
        }
        Returns: Uuid
      }
      extraction_verification_input: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_run_id: Uuid
          p_evidence_item_id?: Uuid | null
        }
        // jsonb. Formen er dokumentert i migrasjon 005h og leses av
        // `parseVerificationInput`, som avviser et svar som ikke har den.
        Returns: unknown
      }
      register_extraction_verification: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_run_id: Uuid
          p_evidence_item_id: Uuid
          p_outcome: string
          p_source_access: string
          p_checked_fields: readonly string[]
          p_rationale: string
          p_findings?: string | null
        }
        Returns: Uuid
      }
    }
  }
}

export type AgentClient = SupabaseClient<AgentDatabase, 'api'>

export interface AgentClientConfig {
  readonly url: string
  readonly publishableKey: string
}

export function createAgentClient(config: AgentClientConfig): AgentClient {
  return createClient<AgentDatabase, 'api'>(config.url, config.publishableKey, {
    db: { schema: 'api' },
    // Ingen sesjon å lagre eller fornye: kjøreren har ingen brukerkonto, og en
    // klient som prøvde å oppdatere en token i bakgrunnen, ville holdt
    // prosessen i live etter at kjøringen er lukket.
    auth: { persistSession: false, autoRefreshToken: false },
  })
}

/** Premissene en kjøring registreres med (provenance.agent_runs). */
export interface AgentRunPremises {
  readonly provider: string
  readonly model: string
  readonly modelVersion: string
  readonly promptTemplateVersion: string
  readonly pipelineVersion: string
}

export interface RegisterVerificationArgs {
  readonly agentRunId: Uuid
  readonly evidenceItemId: Uuid
  readonly outcome: string
  readonly sourceAccess: string
  readonly checkedFields: readonly string[]
  readonly rationale: string
  readonly findings: string | null
}

/** Én kontrollert evidenslenke, slik `api.register_claim_verification` tar imot den. */
export interface ClaimCitationArgs {
  readonly claimEvidenceLinkId: Uuid
  readonly sourceAccess: string
  readonly sourceVersionId: Uuid | null
  readonly checkedContentHash: string | null
  readonly relationshipSupported: string
  readonly finding: string | null
}

/** De sju kontrollpunktene DATABASE_ARCHITECTURE.md §30 krever. */
export interface ClaimCheckResults {
  readonly sourceSupport: string
  readonly populationMatch: string
  readonly comparatorMatch: string
  readonly timeframeMatch: string
  readonly directionAndMagnitude: string
  readonly qualifiersComplete: string
  readonly contradictoryEvidenceRepresented: string
}

export interface RegisterClaimVerificationArgs {
  readonly agentRunId: Uuid
  readonly claimRevisionId: Uuid
  readonly outcome: string
  readonly checks: ClaimCheckResults
  readonly citations: readonly ClaimCitationArgs[]
  readonly rationale: string
  readonly findings: string | null
}

/** Kjøringen, som er den samme mekanismen for hvert agentledd. */
export interface AgentRunApi {
  beginRun(premises: AgentRunPremises, inputManifest: Record<string, unknown>): Promise<Uuid>
  completeRun(
    agentRunId: Uuid,
    status: 'succeeded' | 'failed' | 'aborted',
    outputManifest: Record<string, unknown> | null,
    failureReason: string | null,
  ): Promise<void>
}

/** Kallene ekstraksjonsverifikatoren gjør, som én grenseflate. */
export interface ExtractionVerificationApi extends AgentRunApi {
  readInput(agentRunId: Uuid, evidenceItemId: Uuid | null): Promise<unknown>
  registerVerification(args: RegisterVerificationArgs): Promise<Uuid>
}

/** Kallene claim-verifikatoren gjør, som én grenseflate. */
export interface ClaimVerificationApi extends AgentRunApi {
  readInput(agentRunId: Uuid, claimRevisionId: Uuid | null): Promise<unknown>
  registerVerification(args: RegisterClaimVerificationArgs): Promise<Uuid>
}

/** Agentrollene kjøringene handler i (provenance.agent_role). */
export const EXTRACTION_VERIFICATION_ROLE = 'extraction_verification'
export const CITATION_SUPPORT_VERIFICATION_ROLE = 'citation_support_verification'

function fail(operation: string, message: string): never {
  throw new Error(`${operation} ble avvist: ${message}`)
}

type Identity = { readonly p_identity_key: string; readonly p_secret: string }

function identityOf(credential: AgentCredential): Identity {
  return { p_identity_key: credential.identityKey, p_secret: credential.secret.reveal() }
}

/**
 * Kjøringen, implementert én gang.
 *
 * `api.begin_agent_run` og `api.complete_agent_run` er de samme to kallene for
 * hvert agentledd; det eneste som skiller dem, er rollen kjøringen åpnes i. Å
 * skrive dem om igjen per ledd ville vært to steder å glemme et felt.
 */
function createAgentRunApi(client: AgentClient, identity: Identity, role: string): AgentRunApi {
  return {
    async beginRun(premises, inputManifest) {
      const { data, error } = await client.rpc('begin_agent_run', {
        ...identity,
        p_agent_role: role,
        p_provider: premises.provider,
        p_model: premises.model,
        p_model_version: premises.modelVersion,
        p_prompt_template_version: premises.promptTemplateVersion,
        p_pipeline_version: premises.pipelineVersion,
        p_input_manifest: inputManifest,
      })
      if (error !== null) {
        fail('api.begin_agent_run', error.message)
      }
      return data
    },

    async completeRun(agentRunId, status, outputManifest, failureReason) {
      const { error } = await client.rpc('complete_agent_run', {
        ...identity,
        p_agent_run_id: agentRunId,
        p_status: status,
        p_output_manifest: outputManifest,
        p_failure_reason: failureReason,
      })
      if (error !== null) {
        fail('api.complete_agent_run', error.message)
      }
    },
  }
}

/**
 * Ekstraksjonsverifikatorens port mot en faktisk Supabase-klient.
 *
 * Legitimasjonen hentes ut på det ene stedet den faktisk sendes, og
 * `AgentSecret` sørger for at den ikke kan havne i en logg på veien
 * (se `agent-credential.ts`).
 */
export function createExtractionVerificationApi(
  client: AgentClient,
  credential: AgentCredential,
): ExtractionVerificationApi {
  const identity = identityOf(credential)

  return {
    ...createAgentRunApi(client, identity, EXTRACTION_VERIFICATION_ROLE),

    async readInput(agentRunId, evidenceItemId) {
      const { data, error } = await client.rpc('extraction_verification_input', {
        ...identity,
        p_agent_run_id: agentRunId,
        p_evidence_item_id: evidenceItemId,
      })
      if (error !== null) {
        fail('api.extraction_verification_input', error.message)
      }
      return data
    },

    async registerVerification(args) {
      const { data, error } = await client.rpc('register_extraction_verification', {
        ...identity,
        p_agent_run_id: args.agentRunId,
        p_evidence_item_id: args.evidenceItemId,
        p_outcome: args.outcome,
        p_source_access: args.sourceAccess,
        p_checked_fields: args.checkedFields,
        p_rationale: args.rationale,
        p_findings: args.findings,
      })
      if (error !== null) {
        fail('api.register_extraction_verification', error.message)
      }
      return data
    },
  }
}

/**
 * Claim-verifikatorens port. Samme form, egen rolle og egen legitimasjon: en
 * identitet i det ene leddet kan ikke utføre operasjonene i det andre
 * (MVP_IMPLEMENTATION_PLAN.md §49).
 */
export function createClaimVerificationApi(
  client: AgentClient,
  credential: AgentCredential,
): ClaimVerificationApi {
  const identity = identityOf(credential)

  return {
    ...createAgentRunApi(client, identity, CITATION_SUPPORT_VERIFICATION_ROLE),

    async readInput(agentRunId, claimRevisionId) {
      const { data, error } = await client.rpc('claim_verification_input', {
        ...identity,
        p_agent_run_id: agentRunId,
        p_claim_revision_id: claimRevisionId,
      })
      if (error !== null) {
        fail('api.claim_verification_input', error.message)
      }
      return data
    },

    async registerVerification(args) {
      const { data, error } = await client.rpc('register_claim_verification', {
        ...identity,
        p_agent_run_id: args.agentRunId,
        p_claim_revision_id: args.claimRevisionId,
        p_outcome: args.outcome,
        p_source_support: args.checks.sourceSupport,
        p_population_match: args.checks.populationMatch,
        p_comparator_match: args.checks.comparatorMatch,
        p_timeframe_match: args.checks.timeframeMatch,
        p_direction_and_magnitude: args.checks.directionAndMagnitude,
        p_qualifiers_complete: args.checks.qualifiersComplete,
        p_contradictory_evidence_represented: args.checks.contradictoryEvidenceRepresented,
        // Nøklene er databasens, ikke kjøreren sine: formen er kontrakten
        // migrasjon 005k dokumenterer, og oversettelsen skjer her framfor å
        // lekke snake_case inn i resten av kjøreren.
        p_citations: args.citations.map((citation) => ({
          claim_evidence_link_id: citation.claimEvidenceLinkId,
          source_access: citation.sourceAccess,
          source_version_id: citation.sourceVersionId,
          checked_content_hash: citation.checkedContentHash,
          relationship_supported: citation.relationshipSupported,
          finding: citation.finding,
        })),
        p_rationale: args.rationale,
        p_findings: args.findings,
      })
      if (error !== null) {
        fail('api.register_claim_verification', error.message)
      }
      return data
    },
  }
}
