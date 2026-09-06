// ============================================================================
// Data API-flaten en agentkjører bruker
//
// Fire funksjoner, alle i `api`, alle kalt uten brukersesjon: en agent har ingen
// brukerkonto, så kalleren er `anon` i Data API-et og legitimasjonen — ikke
// Data API-rollen — er kontrollen (migrasjon 005e sin hodekommentar).
//
//   api.begin_agent_run                  åpner kjøringen og registrerer premissene
//   api.extraction_verification_input    grunnlaget kontrollen gjøres mot (005h)
//   api.register_extraction_verification registrerer resultatet (005g)
//   api.complete_agent_run               lukker kjøringen med et utfall
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

/** De fire kallene runneren gjør, som én grenseflate. */
export interface ExtractionVerificationApi {
  beginRun(premises: AgentRunPremises, inputManifest: Record<string, unknown>): Promise<Uuid>
  readInput(agentRunId: Uuid, evidenceItemId: Uuid | null): Promise<unknown>
  registerVerification(args: RegisterVerificationArgs): Promise<Uuid>
  completeRun(
    agentRunId: Uuid,
    status: 'succeeded' | 'failed' | 'aborted',
    outputManifest: Record<string, unknown> | null,
    failureReason: string | null,
  ): Promise<void>
}

/** Agentrollen alle fire kallene handler i (provenance.agent_role). */
export const EXTRACTION_VERIFICATION_ROLE = 'extraction_verification'

function fail(operation: string, message: string): never {
  throw new Error(`${operation} ble avvist: ${message}`)
}

/**
 * Porten implementert mot en faktisk Supabase-klient.
 *
 * Legitimasjonen hentes ut på det ene stedet den faktisk sendes, og
 * `AgentSecret` sørger for at den ikke kan havne i en logg på veien
 * (se `agent-credential.ts`).
 */
export function createExtractionVerificationApi(
  client: AgentClient,
  credential: AgentCredential,
): ExtractionVerificationApi {
  const identity = {
    p_identity_key: credential.identityKey,
    p_secret: credential.secret.reveal(),
  }

  return {
    async beginRun(premises, inputManifest) {
      const { data, error } = await client.rpc('begin_agent_run', {
        ...identity,
        p_agent_role: EXTRACTION_VERIFICATION_ROLE,
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
