// ============================================================================
// Svaret fra den eksterne KI-agenten: den ene filen som kommer tilbake
//
// Oppgaven går ut av Antidep som én fil (`agent-task-file.ts`). Svaret kommer
// tilbake som én fil, og dette er formen på nettopp den:
//
//   answer_version         hvilken svarform filen er skrevet mot
//   task_version           hvilken oppgaveform den svarer på
//   role                   hvilket agentledd svaret er avgitt i
//   job_key                hvilken oppgave det gjelder
//   request_digest         hvilket grunnlag oppgaven ble bygget av
//   output_schema_version  hvilken svarstruktur result følger
//   identity               hvem som faktisk svarte
//   answered_at            når det ble svart (valgfritt)
//   result                 selve svaret
//
// De seks første er verdier agenten kopierer uendret fra oppgaven. De binder
// svaret til nøyaktig én oppgave, ett grunnlag og én rolle — og de kontrolleres
// på nytt av databasen ved import, mot en oppgave den bygger av radene slik de
// er *da* (migrasjon 010c). Er grunnlaget endret i mellomtiden, gjelder ikke
// svaret lenger, og det er riktig utfall.
//
// ----------------------------------------------------------------------------
// Hvorfor filnavnet ikke betyr noe
//
// Fordi det ikke kan bety noe. En fil kan hete hva som helst og ligge hvor som
// helst; bindingen er verdiene i den, og bare dem. Flaten leser filen brukeren
// velger, og alt annet avgjøres av innholdet (ANTIDEP_CONSTITUTION.md regel 2).
//
// ----------------------------------------------------------------------------
// Utrygg inndata
//
// Svaret er data, aldri instruksjoner. Det er skrevet av en modell som nettopp
// har lest en artikkel Antidep ikke kontrollerer, og verken verdiene,
// begrunnelsene eller identiteten i det får styre en eneste beslutning i kjeden.
// De blir kontrollert, eller de blir avvist (AGENTS.md).
//
// Kontrollen her er den *første*, ikke den eneste: databasen gjør den samme
// bindingskontrollen om igjen på sin side, av sine egne rader. Kontrollen her
// finnes for at et menneske skal få en setning på norsk om hva som er galt,
// framfor en SQLSTATE — ikke for at databasen skal kunne stole på klienten.
// ============================================================================

import {
  asOptionalText,
  asText,
  fieldsOf,
  isCalendarTimestamp,
  problem,
  raw,
  rejectUnknown,
} from './strict-fields.ts'
import {
  parseModelIdentity,
  PLACEHOLDER_PREFIX,
  serializeModelIdentity,
  type ModelIdentity,
} from './model-identity.ts'
import { AGENT_ANSWER_VERSION, AGENT_TASK_VERSION, type AgentTask } from './agent-task.ts'

const ANSWER_SUBJECT = 'Agentsvaret'

/** Ett svar fra en ekstern KI-agent, lest og kontrollert. */
export interface AgentAnswer {
  readonly answerVersion: typeof AGENT_ANSWER_VERSION
  readonly taskVersion: typeof AGENT_TASK_VERSION
  readonly role: string
  readonly jobKey: string
  readonly requestDigest: string
  readonly outputSchemaVersion: string
  readonly identity: ModelIdentity
  readonly answeredAt: string | null
  readonly result: Record<string, unknown>
}

const DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/

/** Leser og kontrollerer ett agentsvar, eller sier hvilket felt som er galt. */
export function parseAgentAnswer(value: unknown): AgentAnswer {
  const fields = fieldsOf(value, ANSWER_SUBJECT, 'svaret')

  const answerVersion = asText(fields, 'answer_version')
  if (answerVersion !== AGENT_ANSWER_VERSION) {
    problem(
      ANSWER_SUBJECT,
      'svaret.answer_version',
      `er ${JSON.stringify(answerVersion)}, men Antidep leser ${JSON.stringify(AGENT_ANSWER_VERSION)}`,
    )
  }
  const taskVersion = asText(fields, 'task_version')
  if (taskVersion !== AGENT_TASK_VERSION) {
    problem(
      ANSWER_SUBJECT,
      'svaret.task_version',
      `er ${JSON.stringify(taskVersion)}, men Antidep bygger oppgaver som ${JSON.stringify(AGENT_TASK_VERSION)}`,
    )
  }

  const requestDigest = asText(fields, 'request_digest')
  if (!DIGEST_PATTERN.test(requestDigest)) {
    problem(
      ANSWER_SUBJECT,
      'svaret.request_digest',
      'har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn. Verdien står i ' +
        'oppgavefilen, og skal kopieres derfra uendret',
    )
  }

  const role = asText(fields, 'role')
  const jobKey = asText(fields, 'job_key')
  const outputSchemaVersion = asText(fields, 'output_schema_version')
  const identity = parseModelIdentity(fields, raw(fields, 'identity'))

  const answeredAt = asOptionalText(fields, 'answered_at')
  if (answeredAt !== null && answeredAt.trimStart().startsWith(PLACEHOLDER_PREFIX)) {
    problem(
      ANSWER_SUBJECT,
      'svaret.answered_at',
      'står fortsatt med plassholderen fra malen. Skriv tidspunktet du svarte, på formen ' +
        '2026-09-10T09:12:00Z, eller la feltet stå tomt',
    )
  }
  // Kalenderkontroll og ikke bare et mønster, av samme grunn som i
  // `model-answer.ts`: «2026-09-31T00:00:00Z» har formen og er ikke en dato.
  if (answeredAt !== null && !isCalendarTimestamp(answeredAt)) {
    problem(
      ANSWER_SUBJECT,
      'svaret.answered_at',
      'er ikke et tidspunkt på formen 2026-09-10T09:12:00Z',
    )
  }

  const result = raw(fields, 'result')
  rejectUnknown(fields)

  if (typeof result !== 'object' || result === null || Array.isArray(result)) {
    problem(
      ANSWER_SUBJECT,
      'svaret.result',
      'er ikke et JSON-objekt. Selve svaret skal ligge der, i den formen oppgaven beskriver',
    )
  }

  return {
    answerVersion: AGENT_ANSWER_VERSION,
    taskVersion: AGENT_TASK_VERSION,
    role,
    jobKey,
    requestDigest,
    outputSchemaVersion,
    identity,
    answeredAt,
    result: result as Record<string, unknown>,
  }
}

/**
 * Om svaret hører til oppgaven, eller hvorfor det ikke gjør det.
 *
 * Én setning på norsk, skrevet til den som skal gjøre noe med den. De samme
 * sammenligningene gjør databasen om igjen ved import; forskjellen er at den
 * ikke kan si «hent oppgaven på nytt» før noen har prøvd.
 */
export function answerBindingProblem(task: AgentTask, answer: AgentAnswer): string | null {
  if (answer.role !== task.role) {
    return (
      `Svaret er avgitt i rollen «${answer.role}», mens oppgaven gjelder rollen ` +
      `«${task.role}». Last opp svaret på den oppgaven det ble laget for.`
    )
  }
  if (answer.jobKey !== task.jobKey) {
    return 'Svaret gjelder en annen agentoppgave enn den det lastes opp på.'
  }
  if (answer.outputSchemaVersion !== task.outputSchemaVersion) {
    return (
      `Svaret følger svarformen «${answer.outputSchemaVersion}», mens oppgaven krever ` +
      `«${task.outputSchemaVersion}». Hent oppgaven på nytt og be om et nytt svar.`
    )
  }
  if (answer.requestDigest !== task.requestDigest) {
    return (
      'Svaret ble laget på et annet grunnlag enn oppgaven har nå. Noe av det oppgaven ble ' +
      'bygget av, er endret siden den ble hentet ut. Hent oppgaven på nytt og be om et nytt svar.'
    )
  }
  if (
    task.registeredModel !== null &&
    (task.registeredModel.provider !== answer.identity.provider ||
      task.registeredModel.model !== answer.identity.model ||
      task.registeredModel.modelVersion !== answer.identity.modelVersion)
  ) {
    return (
      `Dette agentleddet er tildelt ${task.registeredModel.model} ` +
      `(${task.registeredModel.provider}), men svaret kom fra ${answer.identity.model} ` +
      `(${answer.identity.provider}). Bruk den tildelte tjenesten, eller bytt tildelingen først.`
    )
  }
  return null
}

/** Svaret slik det skrives som JSON. Motstykket til parseren. */
export function serializeAgentAnswer(answer: AgentAnswer): Record<string, unknown> {
  return {
    answer_version: answer.answerVersion,
    task_version: answer.taskVersion,
    role: answer.role,
    job_key: answer.jobKey,
    request_digest: answer.requestDigest,
    output_schema_version: answer.outputSchemaVersion,
    identity: serializeModelIdentity(answer.identity),
    ...(answer.answeredAt === null ? {} : { answered_at: answer.answeredAt }),
    result: answer.result,
  }
}

/**
 * Svaret som JSON, med ett innpakningsmønster tålt.
 *
 * Oppgaven ber uttrykkelig om en JSON-fil uten kodegjerder, og et svar med
 * gjerder er derfor et svar som ikke fulgte oppgaven. Ett enkelt gjerde rundt
 * hele svaret pakkes likevel ut, fordi det er den ene avviksformen som er
 * entydig og som ikke endrer et eneste tegn i innholdet — og fordi et menneske
 * som limer inn fra et chatvindu, får nettopp den. Alt annet avvises, fordi det
 * ikke finnes én riktig måte å tolke det på.
 */
export function parseAnswerJson(text: string): unknown {
  const trimmed = text.trim()
  const fenced = /^```(?:json)?\s*\n([\s\S]*)\n```$/.exec(trimmed)
  const body = fenced?.[1] ?? trimmed
  try {
    return JSON.parse(body) as unknown
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(
      `Filen er ikke gyldig JSON: ${message}. Be agenten om å levere svaret som én JSON-fil ` +
        'uten tekst rundt.',
      { cause },
    )
  }
}
