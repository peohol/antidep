// ============================================================================
// Den eksterne agentoppgaven: én felles, versjonert kontrakt for de semantiske
// leddene
//
// Antidep har hele tiden hatt én arbeidsform for det semantiske arbeidet: en
// aktør utenfor Antidep leser en bunden forespørsel, og Antidep kontrollerer
// svaret og registrerer resultatet. Kjøremappa (`drafting-job.ts`) og
// fraværsgjennomlesningen (`absence-review-job.ts`) er to filbaserte utgaver av
// nettopp det.
//
// Denne modulen er den formen destillert til én kontrakt som gjelder for flere
// agentroller, og som kan betjenes fra Antidep-flaten av et menneske som verken
// har repoet, en terminal eller en modellnøkkel.
//
//   oppgaven   bygges av databasen av rader som allerede finnes
//              (`api.agent_task_payload`), med et avtrykk over nøyaktig det som
//              binder svaret
//   filen      `agent-task-file.ts` gjør oppgaven til én selvforklarende fil
//              som kan lastes opp i vanlig ChatGPT
//   svaret     `agent-answer.ts` leser det, og `handoff-result.ts` kontrollerer
//              innholdet før det i det hele tatt sendes til databasen
//
// ----------------------------------------------------------------------------
// Hvorfor avtrykket ikke regnes ut her
//
// Fordi klienten ikke kan eie bindingen. `request_digest` dekker rollen,
// oppgavenøkkelen, promptmalversjonen, svarformversjonen, inndataens versjon og
// de tidligere agentkjøringene rollen hviler på — og alle de opplysningene er
// databasens. Regnet den ut her, ville en klient kunnet bygge en oppgave
// databasen aldri hadde sett, og et svar på den ville vært bundet til
// ingenting.
//
// Klienten kopierer derfor avtrykket uendret, både inn i oppgavefilen og ut av
// svaret. Databasen regner det ut på nytt ved import, av de samme radene
// (migrasjon 010c).
//
// ----------------------------------------------------------------------------
// Hvorfor rollene står her og ikke bare i databasen
//
// Promptmalversjonen og svarformversjonen inngår i avtrykket, og databasen er
// fasiten. Verdiene står likevel her, fordi det er denne siden som *skriver*
// oppgavefilen: uten dem måtte filen enten utelate malen eller gjette den. Det
// er den samme kontrakten sett fra hver sin side av databasegrensen — samme form
// som modelltildelingene (`model-roles.ts`) og tekstuttrekksoppskriften
// (`document-binding.ts`) allerede har — og `agent-task.test.ts` pinner de to
// mot hverandre.
//
// ----------------------------------------------------------------------------
// Utrygg inndata
//
// Oppgaven er data. Den bygges av kildetekst og registrerte rader Antidep ikke
// kontrollerer innholdet i, og verken teksten, dossieret eller etikettene i den
// får styre en eneste beslutning i kjeden (AGENTS.md).
// ============================================================================

import {
  asOptionalText,
  asText,
  fieldsOf,
  nestedFields,
  problem,
  raw,
  rejectUnknown,
  type Fields,
} from './strict-fields.ts'
import {
  parseModelIdentity,
  type ModelIdentity,
  type ModelVersionDisclosure,
} from './model-identity.ts'

const TASK_SUBJECT = 'Agentoppgaven'

/** Versjonen av oppgaveformen. Den samme for alle roller. */
export const AGENT_TASK_VERSION = 'antidep/agent-task@1'

/** Versjonen av svarformen oppgaven ber om. */
export const AGENT_ANSWER_VERSION = 'antidep/agent-answer@1'

/**
 * Rollene som kan settes ut til en ekstern KI-agent.
 *
 * De uavhengige kontrolleddene står ikke her. De er Antideps egen
 * deterministiske kode, og en ekstern modell som fikk utføre dem, ville gjort
 * kontrollen til nok en modellvurdering (ANTIDEP_CONSTITUTION.md regel 3).
 */
export const HANDOFF_ROLES = [
  'evidence_extraction',
  'claim_synthesis',
  'evidence_assessment',
] as const

export type HandoffRole = (typeof HANDOFF_ROLES)[number]

export function isHandoffRole(role: string): role is HandoffRole {
  return (HANDOFF_ROLES as readonly string[]).includes(role)
}

/** Det denne siden må vite om en rolle for å kunne skrive oppgavefilen. */
export interface HandoffRoleContract {
  readonly role: HandoffRole
  /** Versjonen av promptmalen. Inngår i avtrykket, og eies av databasen. */
  readonly promptTemplateVersion: string
  /** Versjonen av svarformen rollen krever. Inngår i avtrykket. */
  readonly outputSchemaVersion: string
  /** Rollens navn på norsk, slik et menneske ser den. */
  readonly label: string
  /** Én setning om hva oppgaven gjelder, til køen og til oppgavefilen. */
  readonly summary: string
}

export const HANDOFF_CONTRACTS: Readonly<Record<HandoffRole, HandoffRoleContract>> = {
  evidence_extraction: {
    role: 'evidence_extraction',
    promptTemplateVersion: 'evidence-extraction/handoff-drafting/1',
    outputSchemaVersion: 'antidep/extraction-draft@1',
    label: 'Ekstraksjonsutkast',
    summary:
      'Les artikkelen og foreslå de strukturerte verdiene for ett evidensfunn, med ett ordrett kildeutdrag per felt.',
  },
  claim_synthesis: {
    role: 'claim_synthesis',
    promptTemplateVersion: 'claim-synthesis/handoff-drafting/1',
    outputSchemaVersion: 'antidep/claim-synthesis-draft@1',
    label: 'Synteseutkast',
    summary:
      'Formuler én påstand av de registrerte evidensfunnene, og si hvordan hvert funn forholder seg til den.',
  },
  evidence_assessment: {
    role: 'evidence_assessment',
    promptTemplateVersion: 'evidence-assessment/handoff-drafting/1',
    outputSchemaVersion: 'antidep/evidence-assessment-draft@1',
    label: 'Evidensvurdering',
    summary:
      'Vurder sikkerheten i kunnskapsgrunnlaget bak én påstand, med hvert GRADE-domene eksplisitt bedømt.',
  },
}

/** Rollens kontrakt, eller et kast som navngir de rollene som finnes. */
export function handoffContract(role: string): HandoffRoleContract {
  if (!isHandoffRole(role)) {
    throw new Error(
      `Agentrollen «${role}» kan ikke settes ut til en ekstern KI-agent. ` +
        `Rollene som kan det, er ${HANDOFF_ROLES.join(', ')}. ` +
        'De uavhengige kontrolleddene er Antideps egen deterministiske kode ' +
        '(ANTIDEP_CONSTITUTION.md regel 3).',
    )
  }
  return HANDOFF_CONTRACTS[role]
}

/** Hva oppgaven gjelder, i klartekst. */
export interface AgentTaskSubject {
  readonly kind: string
  readonly label: string
}

/** Én oppgave, lest og kontrollert slik databasen bygget den. */
export interface AgentTask {
  readonly taskVersion: typeof AGENT_TASK_VERSION
  readonly answerVersion: typeof AGENT_ANSWER_VERSION
  readonly pipelineJobId: string
  readonly jobKey: string
  readonly role: HandoffRole
  readonly promptTemplateVersion: string
  readonly outputSchemaVersion: string
  readonly requestDigest: string
  /** Bindingen avtrykket er regnet av. Kopieres aldri fra, bare vist. */
  readonly binding: Record<string, unknown>
  readonly subject: AgentTaskSubject
  /**
   * Modellen rollen allerede er registrert med, eller `null`.
   *
   * `null` betyr at ingen ekstern agent har svart i rollen ennå, og at det
   * første svaret registrerer seg selv (migrasjon 010c). Flaten viser verdien,
   * slik at den som skal utføre oppgaven, vet hvilken modell den skal velge.
   */
  readonly registeredModel: ModelIdentity | null
  /** Innholdet agenten skal lese. Formen avhenger av rollen. */
  readonly input: Record<string, unknown>
}

const DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/

function asRecord(fields: Fields, key: string): Record<string, unknown> {
  const value = raw(fields, key)
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    problem(TASK_SUBJECT, `oppgaven.${key}`, 'er ikke et JSON-objekt')
  }
  return value as Record<string, unknown>
}

/**
 * Leser oppgaven databasen bygget, eller sier hvilket felt som er galt.
 *
 * Strengt, som alt annet som kommer inn utenfra: et felt med skrivefeil skal
 * stoppe flaten, ikke bli en manglende opplysning i en oppgavefil noen laster
 * opp i ChatGPT.
 */
export function parseAgentTask(value: unknown): AgentTask {
  const fields = fieldsOf(value, TASK_SUBJECT, 'oppgaven')

  const taskVersion = asText(fields, 'task_version')
  if (taskVersion !== AGENT_TASK_VERSION) {
    problem(
      TASK_SUBJECT,
      'oppgaven.task_version',
      `er ${JSON.stringify(taskVersion)}, men denne flaten leser ${JSON.stringify(AGENT_TASK_VERSION)}`,
    )
  }
  const answerVersion = asText(fields, 'answer_version')
  if (answerVersion !== AGENT_ANSWER_VERSION) {
    problem(
      TASK_SUBJECT,
      'oppgaven.answer_version',
      `er ${JSON.stringify(answerVersion)}, men denne flaten skriver ${JSON.stringify(AGENT_ANSWER_VERSION)}`,
    )
  }

  const role = asText(fields, 'role')
  if (!isHandoffRole(role)) {
    problem(
      TASK_SUBJECT,
      'oppgaven.role',
      `er ${JSON.stringify(role)}, som ikke er en rolle denne flaten kan sette ut`,
    )
  }
  const contract = HANDOFF_CONTRACTS[role as HandoffRole]

  const requestDigest = asText(fields, 'request_digest')
  if (!DIGEST_PATTERN.test(requestDigest)) {
    problem(
      TASK_SUBJECT,
      'oppgaven.request_digest',
      'har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn',
    )
  }

  const promptTemplateVersion = asText(fields, 'prompt_template_version')
  const outputSchemaVersion = asText(fields, 'output_schema_version')
  // Fasiten er databasens, og avviket sies med begge verdiene. En flate som
  // hadde skrevet sin egen versjon inn i filen, ville laget et svar databasen
  // avviste — med en melding som pekte på svaret framfor på utakten.
  if (promptTemplateVersion !== contract.promptTemplateVersion) {
    problem(
      TASK_SUBJECT,
      'oppgaven.prompt_template_version',
      `er ${JSON.stringify(promptTemplateVersion)}, mens denne utgaven av Antidep skriver ` +
        `${JSON.stringify(contract.promptTemplateVersion)}. Flaten og databasen er i utakt`,
    )
  }
  if (outputSchemaVersion !== contract.outputSchemaVersion) {
    problem(
      TASK_SUBJECT,
      'oppgaven.output_schema_version',
      `er ${JSON.stringify(outputSchemaVersion)}, mens denne utgaven av Antidep skriver ` +
        `${JSON.stringify(contract.outputSchemaVersion)}. Flaten og databasen er i utakt`,
    )
  }

  const subjectFields = nestedFields(fields, raw(fields, 'subject'), 'subject')
  const subject: AgentTaskSubject = {
    kind: asText(subjectFields, 'kind'),
    label: asText(subjectFields, 'label'),
  }
  rejectUnknown(subjectFields)

  const registered = raw(fields, 'registered_model')
  const registeredModel =
    registered === null || registered === undefined
      ? null
      : parseModelIdentity(fields, registered, 'registered_model')

  const task: AgentTask = {
    taskVersion: AGENT_TASK_VERSION,
    answerVersion: AGENT_ANSWER_VERSION,
    pipelineJobId: asText(fields, 'pipeline_job_id'),
    jobKey: asText(fields, 'job_key'),
    role: role as HandoffRole,
    promptTemplateVersion,
    outputSchemaVersion,
    requestDigest,
    binding: asRecord(fields, 'binding'),
    subject,
    registeredModel,
    input: asRecord(fields, 'input'),
  }
  rejectUnknown(fields)
  return task
}

// ----------------------------------------------------------------------------
// Køen
//
// Én rad per agentoppgave, slik en operativ flate trenger den. Inneholder ikke
// kildeteksten: den hentes først når oppgaven faktisk skal utføres, av den som
// skal utføre den.
// ----------------------------------------------------------------------------

/** Én rad i køen over agentoppgaver. */
export interface AgentWorkItem {
  readonly pipelineJobId: string
  readonly role: HandoffRole
  readonly jobKey: string
  readonly state: string
  readonly attempts: number
  readonly maxAttempts: number
  readonly enqueuedAt: string
  readonly subjectLabel: string
  /** Hvorfor oppgaven ikke kan kjøres ennå, eller `null`. */
  readonly blockedReason: string | null
  /** Begrunnelsen fra forrige mislykkede forsøk, eller `null`. */
  readonly failureReason: string | null
  /** Om oppgaven allerede har tatt imot et svar. */
  readonly answered: boolean
  readonly answeredAt: string | null
  readonly registeredModel: ModelIdentity | null
}

const QUEUE_SUBJECT = 'Agentkøen'

function asCount(fields: Fields, key: string): number {
  const value = raw(fields, key)
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke et helt tall som ikke er negativt')
  }
  return value as number
}

function asFlag(fields: Fields, key: string): boolean {
  const value = raw(fields, key)
  if (typeof value !== 'boolean') {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke en boolsk verdi')
  }
  return value as boolean
}

/**
 * Leser køen.
 *
 * Rader i en rolle denne utgaven ikke kjenner, utelates framfor å kaste: en
 * database som har fått en ny handoff-rolle før flaten er oppdatert, skal ikke
 * gjøre hele siden ubrukelig. Raden er borte til flaten kan vise den, og det er
 * en synlig forskjell fra at den ikke finnes — køen sier hvor mange rader den
 * ikke kunne vise.
 */
export function parseAgentWorkQueue(value: unknown): {
  readonly items: readonly AgentWorkItem[]
  readonly unknownRoles: number
} {
  if (!Array.isArray(value)) {
    throw new Error('Agentkøen er ugyldig: svaret er ikke en liste.')
  }
  const items: AgentWorkItem[] = []
  let unknownRoles = 0

  value.forEach((row, index) => {
    const fields = fieldsOf(row, QUEUE_SUBJECT, `raden[${String(index)}]`)
    const role = asText(fields, 'agent_role')
    if (!isHandoffRole(role)) {
      unknownRoles += 1
      return
    }
    const registered = raw(fields, 'registered_model')
    items.push({
      pipelineJobId: asText(fields, 'pipeline_job_id'),
      role,
      jobKey: asText(fields, 'job_key'),
      state: asText(fields, 'state'),
      attempts: asCount(fields, 'attempts'),
      maxAttempts: asCount(fields, 'max_attempts'),
      enqueuedAt: asText(fields, 'enqueued_at'),
      subjectLabel: asText(fields, 'subject_label'),
      blockedReason: asOptionalText(fields, 'blocked_reason'),
      failureReason: asOptionalText(fields, 'failure_reason'),
      answered: asFlag(fields, 'answered'),
      answeredAt: asOptionalText(fields, 'answered_at'),
      registeredModel:
        registered === null || registered === undefined
          ? null
          : parseModelIdentity(fields, registered, 'registered_model'),
    })
  })

  return { items, unknownRoles }
}

// ----------------------------------------------------------------------------
// Utfallet av en import, lest med den samme strengheten
// ----------------------------------------------------------------------------

/** Hva importen faktisk gjorde. */
export interface ImportOutcome {
  /** `false` betyr at svaret allerede var importert, og at ingenting nytt ble skrevet. */
  readonly imported: boolean
  readonly alreadyImported: boolean
  readonly pipelineJobId: string
  readonly role: string
  readonly agentRunId: string
  /** Modellen som utførte arbeidet, slik den ble registrert. */
  readonly model: ModelIdentity | null
  /** Det registrerte objektet, slik databasen navngir det. */
  readonly outcome: Record<string, unknown>
}

export function parseImportOutcome(value: unknown): ImportOutcome {
  const fields = fieldsOf(value, 'Importsvaret', 'svaret')
  const model = raw(fields, 'model')
  const outcome = raw(fields, 'outcome')
  if (typeof outcome !== 'object' || outcome === null || Array.isArray(outcome)) {
    problem('Importsvaret', 'svaret.outcome', 'er ikke et JSON-objekt')
  }
  return {
    imported: asFlag(fields, 'imported'),
    alreadyImported: asFlag(fields, 'already_imported'),
    pipelineJobId: asText(fields, 'pipeline_job_id'),
    role: asText(fields, 'agent_role'),
    agentRunId: asText(fields, 'agent_run_id'),
    model:
      model === null || model === undefined ? null : parseModelIdentity(fields, model, 'model'),
    outcome: outcome as Record<string, unknown>,
  }
}

export type { ModelIdentity, ModelVersionDisclosure }
