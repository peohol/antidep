// ============================================================================
// MCP-lagets eneste vei til databasen
//
// Ti kall, og ingen flere. MCP-serveren har ingen databasehemmelighet av egen
// kraft: den videresender det tokenet kalleren la ved, og databasen avgjør hva
// tokenet får gjøre. Serveren kan derfor ikke gi seg selv mer enn tilkoblingen
// har, og en kompromittert server er ikke en kompromittert database
// (ANTIDEP_CONSTITUTION.md regel 7).
//
// Det er også grunnen til at nøkkelen serveren bruker mot Data API-et, er den
// publishable: de ti funksjonene er gitt til `anon` av samme grunn som
// `api.claim_pipeline_job` er det — en kjører har ingen brukerkonto, så
// legitimasjonen og ikke Data API-rollen er kontrollen (migrasjon 005e).
//
// ----------------------------------------------------------------------------
// Hvorfor dette er en grenseflate og ikke en klient
//
// Som `agent-work-gateway.ts` og `agent-api.ts`: hele protokollaget skal kunne
// prøves uten en Supabase-stack, og en prøve skal kunne beskrive nøyaktig hva
// databasen svarte — også når den svarte noe galt.
// ============================================================================

import { createClient, type SupabaseClient } from '@supabase/supabase-js'

import { parseAgentTask, type AgentTask } from '../agents/agent-task.ts'
import type { Database } from '../types/database.ts'
import { GatewayError, type RunnerOutcome } from './errors.ts'

/**
 * Kontraktslaget slik MCP-appen ser det: appens flate, pluss de ti kjørerveiene.
 *
 * Utvider `Database` framfor å være en ny kopi, av samme grunn som
 * `AgentDatabase` i `agent-api.ts` gjør det: de ti hører ikke hjemme i
 * nettleserens beskrivelse — appen skal aldri kalle dem — mens to uavhengige
 * beskrivelser av det samme schemaet ville kunnet drive fra hverandre.
 */
type RunnerRpc<TArgs> = { Args: TArgs; Returns: unknown }

export type RunnerDatabase = {
  api: Omit<Database['api'], 'Functions'> & {
    Functions: Database['api']['Functions'] & {
      register_agent_runner_client: RunnerRpc<{
        p_client_name: string
        p_redirect_uris: string[]
      }>
      authorize_agent_runner: RunnerRpc<{
        p_pairing_code: string
        p_client_id: string
        p_redirect_uri: string
        p_code_challenge: string
        p_code_challenge_method: string
        p_resource: string
      }>
      exchange_agent_runner_code: RunnerRpc<{
        p_code: string
        p_code_verifier: string
        p_client_id: string
        p_redirect_uri: string
        p_resource: string
      }>
      refresh_agent_runner_token: RunnerRpc<{
        p_refresh_token: string
        p_client_id: string
        p_resource: string
      }>
      list_pending_agent_tasks: RunnerRpc<{ p_access_token: string; p_resource: string }>
      claim_agent_task: RunnerRpc<{
        p_access_token: string
        p_resource: string
        p_task_ref: string | null
        p_lease_seconds: number
      }>
      agent_task_for_runner: RunnerRpc<{
        p_access_token: string
        p_resource: string
        p_task_handle: string
        p_tool_name: TaskReadCaller
      }>
      submit_agent_answer: RunnerRpc<{
        p_access_token: string
        p_resource: string
        p_task_handle: string
        p_answer: Record<string, unknown>
      }>
      release_agent_task: RunnerRpc<{
        p_access_token: string
        p_resource: string
        p_task_handle: string
        p_reason_code: string | null
      }>
      agent_runner_identity: RunnerRpc<{ p_access_token: string; p_resource: string }>
      record_agent_runner_outcome: RunnerRpc<{
        p_access_token: string
        p_resource: string
        p_tool_name: string
        p_outcome: string
        p_task_handle: string | null
      }>
    }
  }
}

type RunnerFunctions = RunnerDatabase['api']['Functions']

/** Ett utstedt token-par, slik OAuth-svaret trenger det. */
export interface RunnerTokenSet {
  readonly accessToken: string
  readonly refreshToken: string
  readonly expiresIn: number
  readonly scope: string
}

/** Én ventende oppgave, slik køen viser den. Uten kildetekst og uten database-id. */
export interface PendingTask {
  readonly taskRef: string
  readonly agentRole: string
  readonly subjectKind: string
  readonly subjectLabel: string
  readonly enqueuedAt: string
}

export interface PendingTasks {
  readonly agentRole: string
  readonly tasks: readonly PendingTask[]
  /** Oppgaver som venter på et menneske. «Ingen arbeid» er noe annet. */
  readonly blockedCount: number
}

export type ClaimResult =
  | {
      readonly claimed: true
      readonly taskHandle: string
      readonly agentRole: string
      readonly subjectKind: string
      readonly subjectLabel: string
      readonly attempt: number
      readonly maxAttempts: number
      readonly leaseExpiresAt: string
    }
  | { readonly claimed: false; readonly reason: string; readonly agentRole: string }

export type TaskResult =
  | {
      readonly available: true
      readonly taskHandle: string
      readonly leaseExpiresAt: string
      readonly task: AgentTask
    }
  | { readonly available: false; readonly reason: string }

export type SubmitResult =
  | {
      readonly accepted: true
      readonly imported: boolean
      readonly alreadyImported: boolean
      readonly agentRole: string
      readonly agentRunId: string
      readonly outcome: Record<string, unknown>
    }
  | { readonly accepted: false; readonly reason: string }

export interface AuthorizationGrant {
  readonly authorizationCode: string
  readonly connectionKey: string
  readonly displayName: string
  readonly agentRole: string
}

/**
 * Grunnene en kjører kan oppgi for å gi en oppgave fra seg.
 *
 * En lukket klasse, og de samme verdiene `workflow.agent_release_note(text)`
 * kjenner. Antidep skriver selv setningen klassen står for.
 */
export const RUNNER_RELEASE_REASONS = [
  'blocked_by_task',
  'could_not_complete',
  'out_of_time',
] as const

export type RunnerReleaseReason = (typeof RUNNER_RELEASE_REASONS)[number]

/**
 * Verktøyene som leser en oppgave, som en lukket klasse.
 *
 * De samme to `api.agent_task_for_runner` godtar. Klassen finnes fordi sporet
 * skal si hva som faktisk skjedde: `submit_agent_answer` leser oppgaven på nytt
 * for de deterministiske kontrollene, og den lesningen hører til kallet som ba
 * om den — ikke til et `get_agent_task` ingen klient gjorde.
 */
export const TASK_READ_CALLERS = ['get_agent_task', 'submit_agent_answer'] as const

export type TaskReadCaller = (typeof TASK_READ_CALLERS)[number]

/**
 * Tokenet og den adressen det gjelder for, som én verdi.
 *
 * De to hører sammen og reiser sammen. Et token uten publikum kunne ellers ha
 * blitt sendt videre alene, og publikumskontrollen ville vært en kontroll bare
 * de kallerne som husket den, faktisk kjørte (RFC 8707).
 */
export interface RunnerCredentials {
  readonly accessToken: string
  /** Den kanoniske adressen til MCP-serveren tokenet brukes mot. */
  readonly resource: string
}

/** Hvem et token tilhører. Bærer ingen hemmelighet. */
export interface RunnerIdentity {
  readonly connectionKey: string
  readonly displayName: string
  readonly agentRole: string
  readonly platformModelDisclosure: string
}

/** Grenseflaten protokollaget kjenner. */
export interface RunnerGateway {
  /**
   * Hvem tokenet tilhører, eller et avslag.
   *
   * Transportlaget kaller den på hver forespørsel. Uten den ville et utløpt
   * eller tilbaketrukket token sett ut som en levende tilkobling helt til det
   * første verktøykallet — og en MCP-klient trenger nettopp avslaget for å vite
   * at den skal fornye.
   */
  identify(credentials: RunnerCredentials): Promise<RunnerIdentity>

  registerClient(input: {
    readonly clientName: string
    readonly redirectUris: readonly string[]
  }): Promise<{ readonly clientId: string; readonly redirectUris: readonly string[] }>

  authorize(input: {
    readonly pairingCode: string
    readonly clientId: string
    readonly redirectUri: string
    readonly codeChallenge: string
    readonly codeChallengeMethod: string
    /** Den kanoniske adressen tokenet skal gjelde for (RFC 8707). */
    readonly resource: string
  }): Promise<AuthorizationGrant>

  exchangeCode(input: {
    readonly code: string
    readonly codeVerifier: string
    readonly clientId: string
    readonly redirectUri: string
    readonly resource: string
  }): Promise<RunnerTokenSet>

  refresh(input: {
    readonly refreshToken: string
    readonly clientId: string
    readonly resource: string
  }): Promise<RunnerTokenSet>

  listPendingTasks(credentials: RunnerCredentials): Promise<PendingTasks>

  claimTask(input: {
    readonly credentials: RunnerCredentials
    readonly taskRef: string | null
    readonly leaseSeconds: number
  }): Promise<ClaimResult>

  readTask(input: {
    readonly credentials: RunnerCredentials
    readonly taskHandle: string
    /**
     * Verktøyet som forårsaket lesningen.
     *
     * `submit_agent_answer` leser oppgaven én gang til for de deterministiske
     * kontrollene, fordi protokollen er tilstandsløs og det ikke finnes en
     * lesning å huske. Sporet skal navngi det kallet som faktisk ble gjort, og
     * ikke et `get_agent_task` ingen klient ba om.
     */
    readonly calledBy: TaskReadCaller
  }): Promise<TaskResult>

  submitAnswer(input: {
    readonly credentials: RunnerCredentials
    readonly taskHandle: string
    readonly answer: Record<string, unknown>
  }): Promise<SubmitResult>

  releaseTask(input: {
    readonly credentials: RunnerCredentials
    readonly taskHandle: string
    /**
     * Hvorfor oppgaven gis fra seg, som en lukket klasse.
     *
     * Ikke fri tekst: en setning fra modellen ville vært modellinnhold i det
     * operative sporet, og sporet skal ikke bli et sted en promptavledet
     * setning eller et kildeutdrag kan samle seg.
     */
    readonly reasonCode: RunnerReleaseReason | null
  }): Promise<{ readonly released: boolean; readonly reason?: string }>

  recordOutcome(input: {
    readonly credentials: RunnerCredentials
    readonly toolName: string
    readonly outcome: RunnerOutcome
    readonly taskHandle: string | null
  }): Promise<void>
}

export interface RunnerGatewayConfig {
  readonly supabaseUrl: string
  readonly publishableKey: string
}

function record(value: unknown, where: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new GatewayError(`Svaret fra ${where} er ikke et JSON-objekt.`, null)
  }
  return value as Record<string, unknown>
}

function text(row: Record<string, unknown>, key: string, where: string): string {
  const value = row[key]
  if (typeof value !== 'string' || value.length === 0) {
    throw new GatewayError(`Svaret fra ${where} mangler feltet «${key}».`, null)
  }
  return value
}

function count(row: Record<string, unknown>, key: string, where: string): number {
  const value = row[key]
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    throw new GatewayError(`Svaret fra ${where} mangler et helt tall i «${key}».`, null)
  }
  return value
}

function flag(row: Record<string, unknown>, key: string, where: string): boolean {
  const value = row[key]
  if (typeof value !== 'boolean') {
    throw new GatewayError(`Svaret fra ${where} mangler en boolsk verdi i «${key}».`, null)
  }
  return value
}

/**
 * Den ekte grenseflaten.
 *
 * Feil fra databasen bæres videre med SQLSTATE-en, slik at utfallsklassen kan
 * utledes uten å lese feilteksten. Teksten går til den agenten som nettopp leste
 * oppgaven, og aldri til en logg.
 */
export function createSupabaseRunnerGateway(config: RunnerGatewayConfig): RunnerGateway {
  // Bundet til kontraktslaget `api`, som nettleserklienten: et forsøk på å lese
  // et kanonisk schema skal være en typefeil framfor et 404 i produksjon.
  const client: SupabaseClient<RunnerDatabase, 'api'> = createClient<RunnerDatabase, 'api'>(
    config.supabaseUrl,
    config.publishableKey,
    {
      db: { schema: 'api' },
      // Ingen sesjon å lagre eller fornye: MCP-appen har ingen brukerkonto, og
      // tokenet den videresender, er kallerens — aldri sitt eget.
      auth: { persistSession: false, autoRefreshToken: false },
    },
  )

  async function call<TName extends keyof RunnerFunctions & string>(
    fn: TName,
    args: RunnerFunctions[TName]['Args'],
  ): Promise<unknown> {
    const { data, error } = await client.rpc(fn, args)
    if (error !== null) {
      throw new GatewayError(error.message, error.code ?? null)
    }
    return data
  }

  function tokenSet(value: unknown, where: string): RunnerTokenSet {
    const row = record(value, where)
    return {
      accessToken: text(row, 'access_token', where),
      refreshToken: text(row, 'refresh_token', where),
      expiresIn: count(row, 'expires_in', where),
      scope: text(row, 'scope', where),
    }
  }

  return {
    async identify(credentials) {
      const where = 'api.agent_runner_identity'
      const row = record(
        await call('agent_runner_identity', {
          p_access_token: credentials.accessToken,
          p_resource: credentials.resource,
        }),
        where,
      )
      return {
        connectionKey: text(row, 'connection_key', where),
        displayName: text(row, 'display_name', where),
        agentRole: text(row, 'agent_role', where),
        platformModelDisclosure: text(row, 'platform_model_disclosure', where),
      }
    },

    async registerClient(input) {
      const where = 'api.register_agent_runner_client'
      const row = record(
        await call('register_agent_runner_client', {
          p_client_name: input.clientName,
          p_redirect_uris: [...input.redirectUris],
        }),
        where,
      )
      const uris = row['redirect_uris']
      return {
        clientId: text(row, 'client_id', where),
        redirectUris: Array.isArray(uris) ? uris.map(String) : [...input.redirectUris],
      }
    },

    async authorize(input) {
      const where = 'api.authorize_agent_runner'
      const row = record(
        await call('authorize_agent_runner', {
          p_pairing_code: input.pairingCode,
          p_client_id: input.clientId,
          p_redirect_uri: input.redirectUri,
          p_code_challenge: input.codeChallenge,
          p_code_challenge_method: input.codeChallengeMethod,
          p_resource: input.resource,
        }),
        where,
      )
      return {
        authorizationCode: text(row, 'authorization_code', where),
        connectionKey: text(row, 'connection_key', where),
        displayName: text(row, 'display_name', where),
        agentRole: text(row, 'agent_role', where),
      }
    },

    async exchangeCode(input) {
      return tokenSet(
        await call('exchange_agent_runner_code', {
          p_code: input.code,
          p_code_verifier: input.codeVerifier,
          p_client_id: input.clientId,
          p_redirect_uri: input.redirectUri,
          p_resource: input.resource,
        }),
        'api.exchange_agent_runner_code',
      )
    },

    async refresh(input) {
      return tokenSet(
        await call('refresh_agent_runner_token', {
          p_refresh_token: input.refreshToken,
          p_client_id: input.clientId,
          p_resource: input.resource,
        }),
        'api.refresh_agent_runner_token',
      )
    },

    async listPendingTasks(credentials) {
      const where = 'api.list_pending_agent_tasks'
      const row = record(
        await call('list_pending_agent_tasks', {
          p_access_token: credentials.accessToken,
          p_resource: credentials.resource,
        }),
        where,
      )
      const rows = row['tasks']
      if (!Array.isArray(rows)) {
        throw new GatewayError(`Svaret fra ${where} har ingen liste med oppgaver.`, null)
      }
      return {
        agentRole: text(row, 'agent_role', where),
        blockedCount: count(row, 'blocked_count', where),
        tasks: rows.map((entry) => {
          const task = record(entry, where)
          return {
            taskRef: text(task, 'task_ref', where),
            agentRole: text(task, 'agent_role', where),
            subjectKind: text(task, 'subject_kind', where),
            subjectLabel: text(task, 'subject_label', where),
            enqueuedAt: text(task, 'enqueued_at', where),
          }
        }),
      }
    },

    async claimTask(input) {
      const where = 'api.claim_agent_task'
      const row = record(
        await call('claim_agent_task', {
          p_access_token: input.credentials.accessToken,
          p_resource: input.credentials.resource,
          p_task_ref: input.taskRef,
          p_lease_seconds: input.leaseSeconds,
        }),
        where,
      )
      if (!flag(row, 'claimed', where)) {
        return {
          claimed: false,
          reason: text(row, 'reason', where),
          agentRole: text(row, 'agent_role', where),
        }
      }
      return {
        claimed: true,
        taskHandle: text(row, 'task_handle', where),
        agentRole: text(row, 'agent_role', where),
        subjectKind: text(row, 'subject_kind', where),
        subjectLabel: text(row, 'subject_label', where),
        attempt: count(row, 'attempt', where),
        maxAttempts: count(row, 'max_attempts', where),
        leaseExpiresAt: text(row, 'lease_expires_at', where),
      }
    },

    async readTask(input) {
      const where = 'api.agent_task_for_runner'
      const row = record(
        await call('agent_task_for_runner', {
          p_access_token: input.credentials.accessToken,
          p_resource: input.credentials.resource,
          p_task_handle: input.taskHandle,
          p_tool_name: input.calledBy,
        }),
        where,
      )
      if (!flag(row, 'available', where)) {
        return { available: false, reason: text(row, 'reason', where) }
      }
      return {
        available: true,
        taskHandle: text(row, 'task_handle', where),
        leaseExpiresAt: text(row, 'lease_expires_at', where),
        // Den samme strenge lesningen agentarbeidsflaten bruker. En oppgave
        // flaten ville avvist, skal ikke bli en oppgave en modell utfører.
        task: parseAgentTask(row['task']),
      }
    },

    async submitAnswer(input) {
      const where = 'api.submit_agent_answer'
      const row = record(
        await call('submit_agent_answer', {
          p_access_token: input.credentials.accessToken,
          p_resource: input.credentials.resource,
          p_task_handle: input.taskHandle,
          // Ordrett. Databasen regner fingeravtrykket av nøyaktig dette svaret
          // og bruker det til å kjenne igjen det samme svaret sendt inn på nytt.
          p_answer: input.answer,
        }),
        where,
      )
      if (!flag(row, 'accepted', where)) {
        return { accepted: false, reason: text(row, 'reason', where) }
      }
      const outcome = row['outcome']
      return {
        accepted: true,
        imported: flag(row, 'imported', where),
        alreadyImported: flag(row, 'already_imported', where),
        agentRole: text(row, 'agent_role', where),
        agentRunId: text(row, 'agent_run_id', where),
        outcome: record(outcome, where),
      }
    },

    async releaseTask(input) {
      const where = 'api.release_agent_task'
      const row = record(
        await call('release_agent_task', {
          p_access_token: input.credentials.accessToken,
          p_resource: input.credentials.resource,
          p_task_handle: input.taskHandle,
          p_reason_code: input.reasonCode,
        }),
        where,
      )
      const released = flag(row, 'released', where)
      return released ? { released } : { released, reason: text(row, 'reason', where) }
    },

    async recordOutcome(input) {
      await call('record_agent_runner_outcome', {
        p_access_token: input.credentials.accessToken,
        p_resource: input.credentials.resource,
        p_tool_name: input.toolName,
        p_outcome: input.outcome,
        p_task_handle: input.taskHandle,
      })
    },
  }
}
