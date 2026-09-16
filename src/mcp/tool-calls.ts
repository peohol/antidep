// ============================================================================
// Hva de fem verktøyene faktisk gjør
//
// Argumentene leses strengt, kallet går til grenseflaten, og svaret settes sammen
// slik en modell kan handle på det. Ingenting her tar en faglig beslutning: alle
// kontrollene ligger i databasen, og dette laget kan ikke omgå en eneste av dem
// (ANTIDEP_CONSTITUTION.md regel 7).
//
// ----------------------------------------------------------------------------
// Hvorfor en avvisning blir et verktøyresultat og ikke en protokollfeil
//
// Fordi den er noe agenten skal kunne rapportere. En avvist levering er et utfall
// oppgaven hadde — ikke et sammenbrudd i transporten — og en agent som fikk en
// protokollfeil, ville avsluttet uten å kunne si hva som var galt. Teksten går
// derfor til agenten, og utfallsklassen til sporet.
// ============================================================================

import { answerBindingProblem, parseAgentAnswer } from '../agents/agent-answer.ts'
import type { AgentTask } from '../agents/agent-task.ts'
import { renderAgentTaskFile, answerTemplate } from '../agents/agent-task-file.ts'
import { handoffResultProblem } from '../agents/handoff-result.ts'
import {
  GatewayError,
  isAuthenticationFailure,
  outcomeForError,
  type RunnerOutcome,
} from './errors.ts'
import {
  RUNNER_RELEASE_REASONS,
  type RunnerCredentials,
  type RunnerGateway,
  type RunnerReleaseReason,
} from './gateway.ts'

/** Én verktøykjøring, slik MCP beskriver resultatet. */
export interface ToolCallResult {
  readonly content: readonly { readonly type: 'text'; readonly text: string }[]
  readonly structuredContent?: Record<string, unknown>
  readonly isError?: boolean
}

/** Det sporet skal vite om kallet, uten en eneste setning fra en kilde. */
export interface ToolCallTrace {
  readonly tool: string
  readonly outcome: RunnerOutcome
}

export interface ToolCallOutput {
  readonly result: ToolCallResult
  readonly trace: ToolCallTrace
}

const DEFAULT_LEASE_SECONDS = 900

class ToolArgumentError extends Error {}

/**
 * Den samme forklarende kontrollen agentarbeidsflaten kjører før den sender.
 *
 * Returnerer én setning om hva som er galt, eller `null`. Den er ikke *den*
 * kontrollen — den uavhengige ekstraksjonskontrollen er en egen rolle senere i
 * kjeden — men den er generatorens egen aktsomhet, og den skal være den samme
 * uansett om svaret kommer fra en fil eller fra en planlagt kjøring.
 */
function deterministicProblem(task: AgentTask, answer: Record<string, unknown>): string | null {
  let parsed
  try {
    parsed = parseAgentAnswer(answer)
  } catch (error) {
    return error instanceof Error ? error.message : 'Svaret har ikke den formen kontrakten krever.'
  }
  return answerBindingProblem(task, parsed) ?? handoffResultProblem(task, parsed.result)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Ukjente felter avvises, som overalt ellers.
 *
 * Et felt med skrivefeil ville sett ut som en utelatt opplysning, og et felt
 * ingen leser, ville vært en påstand uten virkning.
 */
function rejectUnknown(args: Record<string, unknown>, allowed: readonly string[]): void {
  const unknown = Object.keys(args).filter((key) => !allowed.includes(key))
  if (unknown.length > 0) {
    throw new ToolArgumentError(
      `Kallet har felter dette verktøyet ikke kjenner: ${unknown.map((key) => `«${key}»`).join(', ')}.`,
    )
  }
}

function requiredText(args: Record<string, unknown>, key: string): string {
  const value = args[key]
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new ToolArgumentError(`Kallet mangler «${key}».`)
  }
  return value.trim()
}

function optionalText(args: Record<string, unknown>, key: string): string | null {
  const value = args[key]
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'string') {
    throw new ToolArgumentError(`Feltet «${key}» er ikke en tekst.`)
  }
  const trimmed = value.trim()
  return trimmed.length === 0 ? null : trimmed
}

function leaseSeconds(args: Record<string, unknown>): number {
  const value = args['lease_seconds']
  if (value === undefined || value === null) {
    return DEFAULT_LEASE_SECONDS
  }
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 30 || value > 86400) {
    throw new ToolArgumentError('Feltet «lease_seconds» må være et helt tall mellom 30 og 86400.')
  }
  return value
}

function text(body: string, structured?: Record<string, unknown>): ToolCallResult {
  return structured === undefined
    ? { content: [{ type: 'text', text: body }] }
    : { content: [{ type: 'text', text: body }], structuredContent: structured }
}

function failure(body: string, structured?: Record<string, unknown>): ToolCallResult {
  return { ...text(body, structured), isError: true }
}

export interface ToolCallInput {
  readonly gateway: RunnerGateway
  readonly credentials: RunnerCredentials
  readonly name: string
  readonly args: Record<string, unknown>
}

async function runTool(input: ToolCallInput): Promise<ToolCallOutput> {
  const { gateway, credentials, name, args } = input

  switch (name) {
    case 'list_pending_agent_tasks': {
      rejectUnknown(args, [])
      const pending = await gateway.listPendingTasks(credentials)
      const body =
        pending.tasks.length === 0
          ? pending.blockedCount === 0
            ? `Ingen Antidep-oppgaver venter i agentleddet ${pending.agentRole}. Avslutt stille.`
            : `Ingen Antidep-oppgaver kan utføres nå. ${String(pending.blockedCount)} venter på ` +
              'et menneske, og de er ikke dine å gjøre noe med. Avslutt stille.'
          : `${String(pending.tasks.length)} oppgave(r) venter i agentleddet ${pending.agentRole}.` +
            (pending.blockedCount > 0
              ? ` I tillegg venter ${String(pending.blockedCount)} på et menneske; de er ikke dine.`
              : '') +
            '\n\n' +
            pending.tasks
              .map(
                (task) =>
                  `- ${task.taskRef} — ${task.subjectKind}: ${task.subjectLabel} ` +
                  `(lagt inn ${task.enqueuedAt})`,
              )
              .join('\n')
      return {
        result: text(body, {
          agent_role: pending.agentRole,
          blocked_count: pending.blockedCount,
          tasks: pending.tasks.map((task) => ({
            task_ref: task.taskRef,
            subject_kind: task.subjectKind,
            subject_label: task.subjectLabel,
            enqueued_at: task.enqueuedAt,
          })),
        }),
        trace: {
          tool: name,
          outcome:
            pending.tasks.length > 0 ? 'ok' : pending.blockedCount > 0 ? 'blocked' : 'no_work',
        },
      }
    }

    case 'claim_agent_task': {
      rejectUnknown(args, ['task_ref', 'lease_seconds'])
      const claim = await gateway.claimTask({
        credentials,
        taskRef: optionalText(args, 'task_ref'),
        leaseSeconds: leaseSeconds(args),
      })
      if (!claim.claimed) {
        const body =
          claim.reason === 'no_work'
            ? `Ingen oppgave å ta i agentleddet ${claim.agentRole} nå. Avslutt stille.`
            : claim.reason === 'stale_task'
              ? 'Den henvisningen gjelder ingen oppgave som kan tas nå. Hent listen på nytt.'
              : 'Oppgaven ble utilgjengelig før uttaket. Hent listen på nytt.'
        return {
          result: text(body, { claimed: false, reason: claim.reason }),
          trace: {
            tool: name,
            outcome:
              claim.reason === 'no_work'
                ? 'no_work'
                : claim.reason === 'stale_task'
                  ? 'stale_task'
                  : 'blocked',
          },
        }
      }
      return {
        result: text(
          `Oppgaven er tatt: ${claim.subjectKind} — ${claim.subjectLabel}. ` +
            `Håndtak: ${claim.taskHandle}. Uttaket holder til ${claim.leaseExpiresAt} ` +
            `(forsøk ${String(claim.attempt)} av ${String(claim.maxAttempts)}). ` +
            'Hent oppgaven med get_agent_task.',
          {
            claimed: true,
            task_handle: claim.taskHandle,
            agent_role: claim.agentRole,
            subject_kind: claim.subjectKind,
            subject_label: claim.subjectLabel,
            lease_expires_at: claim.leaseExpiresAt,
          },
        ),
        trace: { tool: name, outcome: 'ok' },
      }
    }

    case 'get_agent_task': {
      rejectUnknown(args, ['task_handle'])
      const handle = requiredText(args, 'task_handle')
      const task = await gateway.readTask({
        credentials,
        taskHandle: handle,
        calledBy: 'get_agent_task',
      })
      if (!task.available) {
        return {
          result: failure(
            'Håndtaket gjelder ingen oppgave du holder nå. Uttaket er løpt ut eller overtatt. ' +
              'Ta en ny oppgave framfor å arbeide videre på denne.',
            { available: false, reason: task.reason },
          ),
          trace: { tool: name, outcome: 'stale_task' },
        }
      }
      return {
        result: text(
          // Nøyaktig den samme oppgaveteksten nedlast/opplast-veien bruker, med
          // det ene avsnittet om hvordan svaret leveres byttet ut. To tekster
          // ville kunnet komme i utakt om hva som er tillatt.
          renderAgentTaskFile(task.task, 'mcp'),
          {
            task_handle: task.taskHandle,
            agent_role: task.task.role,
            subject: task.task.subject.label,
            lease_expires_at: task.leaseExpiresAt,
            answer_template: answerTemplate(task.task),
          },
        ),
        trace: { tool: name, outcome: 'ok' },
      }
    }

    case 'submit_agent_answer': {
      rejectUnknown(args, ['task_handle', 'answer'])
      const handle = requiredText(args, 'task_handle')
      const answer = args['answer']
      if (!isRecord(answer)) {
        throw new ToolArgumentError('Feltet «answer» er ikke et JSON-objekt.')
      }
      // De samme deterministiske kontrollene agentarbeidsflaten kjører før den
      // sender et opplastet svar (`AgentWorkPage`): bindingen, formen på
      // utkastet, avgrensningen, og — for ekstraksjonsleddet — at hvert
      // kildeutdrag faktisk står ordrett i kildeteksten oppgaven inneholdt.
      //
      // De ligger her fordi MCP-veien ellers ville vært den mildere av de to.
      // Databasen kontrollerer ikke utdragene ordrett; det gjør Antideps egen
      // kode før registreringen, og deretter den uavhengige
      // ekstraksjonskontrollen. En autonom kjører som slapp forbi dem, ville
      // fått registrert et oppdiktet utdrag som en rad, og en kontrollør ville
      // måttet avvise det etterpå (ANTIDEP_CONSTITUTION.md regel 4).
      // Kan oppgaven ikke leses, gjøres kontrollen ikke — den skal ikke være
      // grunnen til at et svar avvises. Det vanligste tilfellet er en
      // gjentakelse: et svar som ALLEREDE er registrert, har gjort oppgaven
      // ferdig, og et forsøk på å lese den svarer stale_task. Databasen kjenner
      // igjen det samme svaret og registrerer ingenting nytt, mens et virkelig
      // foreldet uttak avvises der uansett. Kontrollen her er et forklarende
      // ledd, ikke grensen (ANTIDEP_CONSTITUTION.md regel 4).
      const claimed = await gateway.readTask({
        credentials,
        taskHandle: handle,
        // Egen databasevei, med sitt eget navn i sporet. Lesningen er ikke et
        // verktøykall, og sporet skal verken kalle den `get_agent_task` — som
        // ingen klient gjorde — eller `submit_agent_answer`, som ville vært en
        // andre rad for det ene kallet, og på en avvisning en `ok` foran en
        // `rejected` for den samme leveringen.
        calledBy: 'precheck',
      })
      const deterministic = claimed.available ? deterministicProblem(claimed.task, answer) : null
      if (deterministic !== null) {
        await gateway
          .recordOutcome({ credentials, toolName: name, outcome: 'rejected', taskHandle: handle })
          .catch(() => undefined)
        return {
          result: failure(
            `Antidep avviste svaret før registreringen: ${deterministic}\n\n` +
              'Rett svaret og lever det på nytt med det samme oppgavehåndtaket. ' +
              'Kontrollen skal ikke omgås.',
            { accepted: false, reason: 'rejected' },
          ),
          trace: { tool: name, outcome: 'rejected' },
        }
      }

      const submitted = await gateway.submitAnswer({
        credentials,
        taskHandle: handle,
        answer,
      })
      if (!submitted.accepted) {
        return {
          result: failure(
            'Håndtaket gjelder ingen oppgave i dette agentleddet. Svaret ble ikke registrert.',
            { accepted: false, reason: submitted.reason },
          ),
          trace: { tool: name, outcome: 'stale_task' },
        }
      }
      return {
        result: text(
          submitted.alreadyImported
            ? 'Dette svaret var allerede registrert. Ingenting nytt ble skrevet.'
            : 'Svaret er registrert av Antidep.',
          {
            accepted: true,
            imported: submitted.imported,
            already_imported: submitted.alreadyImported,
            agent_role: submitted.agentRole,
            outcome: submitted.outcome,
          },
        ),
        trace: { tool: name, outcome: 'ok' },
      }
    }

    case 'release_agent_task': {
      rejectUnknown(args, ['task_handle', 'reason_code'])
      const handle = requiredText(args, 'task_handle')
      const reasonCode = optionalText(args, 'reason_code')
      if (
        reasonCode !== null &&
        !(RUNNER_RELEASE_REASONS as readonly string[]).includes(reasonCode)
      ) {
        throw new ToolArgumentError(
          `Feltet «reason_code» må være en av ${RUNNER_RELEASE_REASONS.join(', ')}.`,
        )
      }
      const released = await gateway.releaseTask({
        credentials,
        taskHandle: handle,
        reasonCode: reasonCode as RunnerReleaseReason | null,
      })
      return {
        result: text(
          released.released
            ? 'Oppgaven er gitt fra deg og er ledig igjen.'
            : 'Håndtaket gjelder ingen løpende leie du holder.',
          { released: released.released },
        ),
        trace: { tool: name, outcome: released.released ? 'ok' : 'stale_task' },
      }
    }

    default:
      throw new ToolArgumentError(`Verktøyet «${name}» finnes ikke.`)
  }
}

/**
 * Kjører ett verktøy og setter sporet.
 *
 * En avvisning fra den autoritative kontrollen ruller hele leveringen tilbake,
 * sporet inkludert. Utfallsklassen skrives derfor i et eget kall etterpå — ellers
 * ville nettopp de kjøringene som gikk galt, vært de eneste som ikke etterlot
 * seg noe (ANTIDEP_CONSTITUTION.md regel 4).
 */
export async function callTool(input: ToolCallInput): Promise<ToolCallOutput> {
  try {
    return await runTool(input)
  } catch (error) {
    if (error instanceof ToolArgumentError) {
      return {
        result: failure(error.message),
        trace: { tool: input.name, outcome: 'rejected' },
      }
    }
    // Legitimasjonen holder ikke lenger. Den skal forbi verktøylaget urørt:
    // transporten gjør den om til 401 med henvisningen klienten trenger for å
    // fornye. Et verktøyresultat på 200 ville sagt til modellen at kallet
    // mislyktes, og til klienten at alt var i orden — og da ville ingen fornyet
    // noe. Sporet skrives heller ikke her: det ville krevd nettopp det tokenet
    // som nettopp sluttet å gjelde.
    if (isAuthenticationFailure(error)) {
      throw error
    }
    if (error instanceof GatewayError) {
      const outcome = outcomeForError(error)
      await input.gateway
        .recordOutcome({
          credentials: input.credentials,
          toolName: input.name,
          outcome,
          taskHandle:
            typeof input.args['task_handle'] === 'string' ? input.args['task_handle'] : null,
        })
        // Sporet er verdifullt, men det er ikke svaret. Kan det ikke skrives,
        // skal agenten fortsatt få vite hva som gikk galt.
        .catch(() => undefined)
      return {
        result: failure(
          `Antidep avviste kallet: ${error.message}\n\n` +
            'Dette er den autoritative kontrollen, og den skal ikke omgås. Rapporter feilen ' +
            'framfor å forsøke en annen vei.',
        ),
        trace: { tool: input.name, outcome },
      }
    }
    throw error
  }
}
