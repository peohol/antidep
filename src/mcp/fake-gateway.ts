// ============================================================================
// En grenseflate i minnet, for prøvene av protokollaget
//
// Den etterligner databasens *oppførsel* og ikke databasens implementasjon:
// tokenet må være det utstedte, uttaket må være det gjeldende, det samme svaret
// registreres én gang, og et annet svar på en besvart oppgave avvises. Nettopp
// de reglene er det protokollaget hviler på, og de skal prøves uten en stack —
// mens `supabase/tests/790_autonomous_agent_runner_test.sql` prøver at databasen
// faktisk har dem.
//
// Alt innhold er syntetisk (`handoff-test-support.ts`). Ingen linje her er en
// klinisk påstand.
// ============================================================================

import type { HandoffRole } from '../agents/agent-task.ts'
import { parseAgentTask } from '../agents/agent-task.ts'
import { taskPayload } from '../agents/handoff-test-support.ts'
import { GatewayError } from './errors.ts'
import type { ClaimResult, RunnerGateway, SubmitResult, TaskResult } from './gateway.ts'

export const FAKE_PAIRING_CODE = 'f'.repeat(64)
export const FAKE_ACCESS_TOKEN = 'a'.repeat(64)
export const FAKE_REFRESH_TOKEN = 'r'.repeat(64)
export const FAKE_AUTHORIZATION_CODE = 'c'.repeat(64)
export const FAKE_CLIENT_ID = '0123456789abcdef0123456789abcdef'
export const FAKE_REDIRECT_URI = 'https://chatgpt.example/callback'
export const FAKE_TASK_REF = 'task_0123456789abcdef01234567'
export const FAKE_TASK_HANDLE = '11111111-2222-4333-8444-555555555555'

export interface FakeGatewayOptions {
  readonly role?: HandoffRole
  /** `true` gjør køen tom, slik at kjøreren skal avslutte stille. */
  readonly empty?: boolean
  /** Antall oppgaver som venter på et menneske. */
  readonly blockedCount?: number
}

export interface FakeGateway extends RunnerGateway {
  /** Svaret som faktisk nådde registreringen, ordrett. */
  readonly submitted: Record<string, unknown>[]
  /** Utfallsklassene som ble skrevet til sporet. */
  readonly recorded: string[]
  /** Hvor mange ganger en oppgave er tatt ut. */
  claims: number
  expireLease(): void
}

/** En grenseflate som oppfører seg som databasen gjør, i minnet. */
export function createFakeGateway(options: FakeGatewayOptions = {}): FakeGateway {
  const role: HandoffRole = options.role ?? 'evidence_extraction'
  const task = parseAgentTask(taskPayload(role))
  const submitted: Record<string, unknown>[] = []
  const recorded: string[] = []
  let leaseValid = false
  let answered: string | null = null
  let claims = 0

  function authenticated(token: string): void {
    if (token !== FAKE_ACCESS_TOKEN) {
      throw new GatewayError('Tilkoblingen er ikke autentisert.', '42501')
    }
  }

  const gateway: FakeGateway = {
    submitted,
    recorded,
    get claims() {
      return claims
    },
    set claims(value: number) {
      claims = value
    },

    expireLease() {
      leaseValid = false
    },

    identify(accessToken) {
      authenticated(accessToken)
      return Promise.resolve({
        connectionKey: `agent-runner:${role.replaceAll('_', '-')}`,
        displayName: 'Prøvekjøreren',
        agentRole: role,
        platformModelDisclosure: 'not_exposed',
      })
    },

    registerClient(input) {
      return Promise.resolve({ clientId: FAKE_CLIENT_ID, redirectUris: input.redirectUris })
    },

    authorize(input) {
      if (input.pairingCode !== FAKE_PAIRING_CODE) {
        return Promise.reject(new GatewayError('Tilkoblingen er ikke autentisert.', '42501'))
      }
      return Promise.resolve({
        authorizationCode: FAKE_AUTHORIZATION_CODE,
        connectionKey: `agent-runner:${role.replaceAll('_', '-')}`,
        displayName: 'Prøvekjøreren',
        agentRole: role,
      })
    },

    exchangeCode(input) {
      if (input.code !== FAKE_AUTHORIZATION_CODE) {
        return Promise.reject(new GatewayError('Tilkoblingen er ikke autentisert.', '42501'))
      }
      return Promise.resolve({
        accessToken: FAKE_ACCESS_TOKEN,
        refreshToken: FAKE_REFRESH_TOKEN,
        expiresIn: 3600,
        scope: 'antidep.agent-runner',
      })
    },

    refresh(input) {
      if (input.refreshToken !== FAKE_REFRESH_TOKEN) {
        return Promise.reject(new GatewayError('Tilkoblingen er ikke autentisert.', '42501'))
      }
      return Promise.resolve({
        accessToken: FAKE_ACCESS_TOKEN,
        refreshToken: FAKE_REFRESH_TOKEN,
        expiresIn: 3600,
        scope: 'antidep.agent-runner',
      })
    },

    listPendingTasks(accessToken) {
      authenticated(accessToken)
      const available = options.empty === true || answered !== null
      return Promise.resolve({
        agentRole: role,
        blockedCount: options.blockedCount ?? 0,
        tasks: available
          ? []
          : [
              {
                taskRef: FAKE_TASK_REF,
                agentRole: role,
                subjectKind: task.subject.kind,
                subjectLabel: task.subject.label,
                enqueuedAt: '2026-09-15T09:00:00Z',
              },
            ],
      })
    },

    claimTask(input) {
      authenticated(input.accessToken)
      if (options.empty === true || answered !== null) {
        return Promise.resolve({ claimed: false, reason: 'no_work', agentRole: role })
      }
      if (input.taskRef !== null && input.taskRef !== FAKE_TASK_REF) {
        return Promise.resolve({ claimed: false, reason: 'stale_task', agentRole: role })
      }
      claims += 1
      leaseValid = true
      const result: ClaimResult = {
        claimed: true,
        taskHandle: FAKE_TASK_HANDLE,
        agentRole: role,
        subjectKind: task.subject.kind,
        subjectLabel: task.subject.label,
        attempt: claims,
        maxAttempts: 3,
        leaseExpiresAt: '2026-09-15T09:15:00Z',
      }
      return Promise.resolve(result)
    },

    readTask(input) {
      authenticated(input.accessToken)
      if (!leaseValid || input.taskHandle !== FAKE_TASK_HANDLE) {
        return Promise.resolve({ available: false, reason: 'stale_task' } satisfies TaskResult)
      }
      return Promise.resolve({
        available: true,
        taskHandle: FAKE_TASK_HANDLE,
        leaseExpiresAt: '2026-09-15T09:15:00Z',
        task,
      } satisfies TaskResult)
    },

    submitAnswer(input) {
      authenticated(input.accessToken)
      if (!leaseValid || input.taskHandle !== FAKE_TASK_HANDLE) {
        return Promise.resolve({ accepted: false, reason: 'stale_task' } satisfies SubmitResult)
      }
      const digest = JSON.stringify(input.answer)
      if (answered !== null) {
        if (answered === digest) {
          return Promise.resolve({
            accepted: true,
            imported: false,
            alreadyImported: true,
            agentRole: role,
            agentRunId: '99999999-9999-4999-8999-999999999999',
            outcome: { evidence_item_id: '88888888-8888-4888-8888-888888888888' },
          } satisfies SubmitResult)
        }
        return Promise.reject(
          new GatewayError('Denne agentoppgaven har allerede tatt imot et annet svar.', '23505'),
        )
      }
      answered = digest
      submitted.push(input.answer)
      return Promise.resolve({
        accepted: true,
        imported: true,
        alreadyImported: false,
        agentRole: role,
        agentRunId: '99999999-9999-4999-8999-999999999999',
        outcome: { evidence_item_id: '88888888-8888-4888-8888-888888888888' },
      } satisfies SubmitResult)
    },

    releaseTask(input) {
      authenticated(input.accessToken)
      if (!leaseValid || input.taskHandle !== FAKE_TASK_HANDLE) {
        return Promise.resolve({ released: false, reason: 'stale_task' })
      }
      leaseValid = false
      return Promise.resolve({ released: true })
    },

    recordOutcome(input) {
      authenticated(input.accessToken)
      recorded.push(input.outcome)
      return Promise.resolve()
    },
  }

  return gateway
}
