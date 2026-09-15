// ============================================================================
// Agentarbeidsflatens eneste vei til databasen
//
// Fire kall, og ingen flere: hva som venter, hvilken KI-tjeneste et agentledd
// skal utføres av, hva én oppgave inneholder, og hva som skjer når et svar
// kommer tilbake. De ligger bak én grenseflate av samme
// grunn som kandidatflatens gjør det (`candidate-gateway.ts`): flaten skal kunne
// prøves uten en Supabase-stack, og en prøve skal kunne beskrive nøyaktig hva
// databasen svarte — også når den svarte noe galt.
//
// ----------------------------------------------------------------------------
// Hvorfor svaret sendes ordrett
//
// Fordi bindingen er verdiene i svaret, og databasen kontrollerer dem mot
// oppgaven slik den bygger den *da*. Sendte flaten en bearbeidet utgave, ville
// den kontrollen vært en kontroll av flatens arbeid framfor av agentens. De
// deterministiske kontrollene flaten gjør først (`handoff-result.ts`), er et
// forklarende ledd for mennesket — ikke en erstatning for databasens egne.
// ============================================================================

import { getAntidepClient } from '../lib/supabase'
import {
  parseAgentRunnerConnections,
  parseAgentRunnerPairingCode,
  parseAgentTask,
  parseAgentWorkQueue,
  parseImportOutcome,
  parseRoleModelAssignment,
  type AgentRunnerConnection,
  type AgentRunnerPairingCode,
  type AgentTask,
  type AgentWorkItem,
  type ImportOutcome,
  type RoleModelAssignment,
} from '../agents/agent-task'

/**
 * Valget av KI-tjeneste for ett agentledd, slik flaten samler det inn.
 *
 * `modelVersion` er tom med mindre tjenesten faktisk viser en eksakt versjon.
 * Eksponeringsgraden utledes derfor her framfor å være et valg brukeren tar: en
 * oppdiktet versjon ville sett like troverdig ut som en sann, og «vet ikke» er
 * en sann opplysning som skal registreres som nettopp det
 * (ANTIDEP_CONSTITUTION.md regel 4).
 */
export interface RoleModelChoice {
  readonly role: string
  readonly provider: string
  readonly model: string
  readonly modelVersion: string | null
  readonly reason: string | null
  /** Begrunnelsen for et bytte. Kreves når leddet allerede har en tjeneste. */
  readonly replacesReason: string | null
}

/**
 * Registreringen av én autonom kjører, slik flaten samler den inn.
 *
 * `platformModelDisclosure` er en opplysning om plattformen og ikke om modellen:
 * pinner Workspace Agent-en en bestemt modell plattformen viser, er den
 * `platform_pinned`; gjør den ikke det, er den `not_exposed`. Det siste er en
 * sann opplysning framfor en mangel som skal skjules — separasjonen hviler da på
 * modelltildelingen, som i den manuelle handoffen
 * (ANTIDEP_CONSTITUTION.md regel 3, 4).
 */
export interface RunnerRegistration {
  readonly connectionKey: string
  readonly displayName: string
  readonly role: string
  readonly platformAgentReference: string
  readonly platformModelDisclosure: 'platform_pinned' | 'not_exposed'
  readonly reason: string | null
}

export interface AgentWorkGateway {
  listQueue(): Promise<{
    readonly items: readonly AgentWorkItem[]
    readonly unknownRoles: number
  }>
  assignRoleModel(choice: RoleModelChoice): Promise<RoleModelAssignment>
  readTask(pipelineJobId: string): Promise<AgentTask>
  importAnswer(pipelineJobId: string, answer: Record<string, unknown>): Promise<ImportOutcome>
  listRunners(): Promise<readonly AgentRunnerConnection[]>
  registerRunner(registration: RunnerRegistration): Promise<void>
  issuePairingCode(connectionKey: string): Promise<AgentRunnerPairingCode>
  revokeRunner(connectionKey: string, reason: string): Promise<void>
}

/** Avvisninger fra databasen når fram uendret: de sier hva som må gjøres. */
function rejected(operation: string, message: string): Error {
  return new Error(`${operation}: ${message}`)
}

export function createAgentWorkGateway(): AgentWorkGateway {
  const client = getAntidepClient()

  return {
    async listQueue() {
      const { data, error } = await client.rpc('agent_work_queue', {})
      if (error !== null) {
        throw rejected('Agentkøen kunne ikke leses', error.message)
      }
      return parseAgentWorkQueue(data)
    },

    async assignRoleModel(choice) {
      const version = choice.modelVersion === null ? null : choice.modelVersion.trim()
      const exact = version !== null && version !== ''
      const { data, error } = await client.rpc('assign_agent_role_model', {
        p_agent_role: choice.role,
        p_provider: choice.provider,
        p_model: choice.model,
        p_model_version: exact ? version : null,
        p_model_version_disclosure: exact ? 'exact' : 'not_exposed',
        p_reason: choice.reason,
        p_replaces_reason: choice.replacesReason,
      })
      if (error !== null) {
        throw rejected('KI-tjenesten ble ikke valgt', error.message)
      }
      return parseRoleModelAssignment(data)
    },

    async readTask(pipelineJobId) {
      const { data, error } = await client.rpc('agent_task_payload', {
        p_pipeline_job_id: pipelineJobId,
      })
      if (error !== null) {
        throw rejected('Oppgaven kunne ikke hentes', error.message)
      }
      return parseAgentTask(data)
    },

    async importAnswer(pipelineJobId, answer) {
      const { data, error } = await client.rpc('import_agent_answer', {
        p_pipeline_job_id: pipelineJobId,
        // Ordrett. Databasen regner fingeravtrykket av nøyaktig denne filen og
        // bruker det til å kjenne igjen det samme svaret sendt inn på nytt.
        p_answer: answer,
      })
      if (error !== null) {
        throw rejected('Svaret ble ikke registrert', error.message)
      }
      return parseImportOutcome(data)
    },

    async listRunners() {
      const { data, error } = await client.rpc('agent_runner_connections', {})
      if (error !== null) {
        throw rejected('Kjørerne kunne ikke leses', error.message)
      }
      return parseAgentRunnerConnections(data)
    },

    async registerRunner(registration) {
      const { error } = await client.rpc('register_agent_runner', {
        p_connection_key: registration.connectionKey,
        p_display_name: registration.displayName,
        p_agent_role: registration.role,
        p_platform_agent_reference: registration.platformAgentReference,
        p_platform_model_disclosure: registration.platformModelDisclosure,
        p_reason: registration.reason,
      })
      if (error !== null) {
        throw rejected('Kjøreren ble ikke registrert', error.message)
      }
    },

    async issuePairingCode(connectionKey) {
      const { data, error } = await client.rpc('issue_agent_runner_pairing_code', {
        p_connection_key: connectionKey,
      })
      if (error !== null) {
        throw rejected('Tilkoblingskoden ble ikke utstedt', error.message)
      }
      return parseAgentRunnerPairingCode(data)
    },

    async revokeRunner(connectionKey, reason) {
      const { error } = await client.rpc('revoke_agent_runner', {
        p_connection_key: connectionKey,
        p_reason: reason,
      })
      if (error !== null) {
        throw rejected('Kjøreren ble ikke trukket tilbake', error.message)
      }
    },
  }
}
