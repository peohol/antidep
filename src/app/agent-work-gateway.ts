// ============================================================================
// Agentarbeidsflatens eneste vei til databasen
//
// Tre kall, og ingen flere: hva som venter, hva én oppgave inneholder, og hva
// som skjer når et svar kommer tilbake. De ligger bak én grenseflate av samme
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
  parseAgentTask,
  parseAgentWorkQueue,
  parseImportOutcome,
  type AgentTask,
  type AgentWorkItem,
  type ImportOutcome,
} from '../agents/agent-task'

export interface AgentWorkGateway {
  listQueue(): Promise<{
    readonly items: readonly AgentWorkItem[]
    readonly unknownRoles: number
  }>
  readTask(pipelineJobId: string): Promise<AgentTask>
  importAnswer(pipelineJobId: string, answer: Record<string, unknown>): Promise<ImportOutcome>
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
  }
}
