// ============================================================================
// Kjøremappa: modell-leddet som to kommandoer med en tilstand imellom
//
// Modell-leddet kan ikke være én kommando. Selve modellarbeidet gjøres av en
// aktør Antidep ikke kaller — i dag en Claude Code Routine, i går ChatGPT i et
// nettleservindu — og en kommando som ventet på den, ville vært en kommando som
// aldri returnerte. Arbeidet er derfor delt i to kjøringer med en fil imellom:
//
//   open    henter kildeversjonen, bygger den versjonerte forespørselen, og
//           legger igjen prompt.txt, en tom svar.json og kjoring.json
//   (aktøren leser prompt.txt og skriver svaret sitt i svar.json)
//   close   leser svaret, kjører det gjennom nøyaktig de samme kontrollene som
//           før, og skriver forslag.json — eller ingenting
//
// Tilstanden ligger i `kjoring.json`, og det er hele poenget med at den ligger
// på disk framfor i hodet på den som kjører: en Routine som blir avbrutt mellom
// de to kjøringene, kan gjenoppta uten å vite hva som skjedde forrige gang, og
// uten å kunne komme i skade for å lukke et svar inn i feil kjøring.
//
// ----------------------------------------------------------------------------
// Hva mappa *ikke* er
//
// Den er ikke en arbeidsflytmotor, og den skal ikke bli det. Orkestreringen —
// hvilket oppdrag som kjøres når, hva som skjer etterpå, hvem som varsles — er
// Claude Code Routines sitt ansvar, ikke Antideps (`docs/ROUTINE_EXTRACTION.md`).
// Det som ligger her, er de tilstandene *Antidep* må kunne skille fra hverandre
// for at et svar skal kunne kontrolleres: venter på svar, fikk et gyldig svar,
// fikk et svar som ikke holdt mål.
//
// ----------------------------------------------------------------------------
// Hvorfor avtrykket er nøkkelen mellom de to kjøringene
//
// `request_digest` dekker representasjonen, katalogen i oppdraget og
// promptmalversjonen. Står det samme avtrykket i kjøringen og i svaret, er
// svaret et svar på nettopp den forespørselen. Endres én av delene mellom open
// og close — kilden er oppdatert, oppdraget er redigert, malen er ny — får
// forespørselen et annet avtrykk, og det gamle svaret gjelder ikke lenger.
//
// Det er ikke et hinder. Alternativet er et svar lest ut av én tekst, lukket inn
// i en kjøring som peker på en annen (ANTIDEP_CONSTITUTION.md §14).
//
// ----------------------------------------------------------------------------
// Ingen legitimasjon her heller
//
// Mappa er filer. Modulen henter en kilde over nett og leser og skriver på
// disk; den har ingen databasetilgang, ingen agentidentitet og ingen skrivevei
// inn i Antidep (EVIDENCE_PIPELINE.md §63). Forslaget den skriver, er en fil som
// må registreres etterpå, av en annen kjøring med sin egen identitet, under de
// samme deterministiske kontrollene som før.
// ============================================================================

import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { basename, dirname, join } from 'node:path'

import {
  prepareDraftingRequest,
  runExtractionDrafting,
  type DraftingReport,
} from './drafting-run.ts'
import { parseAssignmentJson } from './extraction-assignment.ts'
import { serializeExtractionProposal, type ExtractionProposal } from './extraction-proposal.ts'
import { MODEL_ANSWER_VERSION, parseModelAnswer } from './model-answer.ts'
import { PLACEHOLDER_PREFIX, PLACEHOLDER_IDENTITY } from './model-identity.ts'
import {
  createRecordedModelClient,
  MODEL_RECORDING_VERSION,
  parseModelRecording,
  type ModelRecording,
} from './recorded-model.ts'
import type { RetrieveLike, RetrieveOptions } from './source-retrieval.ts'
import { asText, fieldsOf, problem, raw, rejectUnknown, type Fields } from './strict-fields.ts'

const JOB_SUBJECT = 'Kjøringen'

/** Versjonen av kjøringsformen, oppgitt i hver `kjoring.json`. */
export const DRAFTING_JOB_VERSION = 'antidep/drafting-job@1'

/**
 * Filnavnene i en kjøremappe.
 *
 * Faste navn og ikke valg: en aktør som måtte oppgi hvor svaret skulle ligge,
 * ville hatt ett parameter til å ta feil av, og en dokumentasjon som måtte
 * holdes i synk med det. Navnene er ren ASCII, slik at de overlever et
 * filsystem eller et verktøy som ikke normaliserer norske tegn likt.
 */
export const JOB_FILES = {
  job: 'kjoring.json',
  prompt: 'prompt.txt',
  answer: 'svar.json',
  proposal: 'forslag.json',
  recording: 'opptak.json',
} as const

/** Hvor kjøringen står. */
export type DraftingJobState = 'awaiting_answer' | 'drafted' | 'rejected'

const JOB_STATES: readonly string[] = ['awaiting_answer', 'drafted', 'rejected']

/** Innholdet i `kjoring.json`. */
export interface DraftingJob {
  readonly jobVersion: typeof DRAFTING_JOB_VERSION
  /** Oppdragsfilen kjøringen ble åpnet for, slik kalleren oppga den. */
  readonly assignmentPath: string
  readonly sourceVersionId: string
  readonly retrievedFrom: string
  readonly contentHash: string
  readonly requestDigest: string
  readonly promptTemplateVersion: string
  readonly state: DraftingJobState
  readonly openedAt: string
  readonly closedAt: string | null
  /** Hvorfor svaret ikke holdt mål. Bare satt for `rejected`. */
  readonly reason: string | null
}

const DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/

/**
 * Hvor mye klokkene får sprike før et svartidspunkt regnes som usant.
 *
 * Kontrollen finnes for å fange et tidspunkt som ikke kan stemme — et svar
 * avgitt før forespørselen fantes, eller langt inn i framtiden. Den finnes ikke
 * for å kreve sekundpresisjon: aktøren som svarer, kjører gjerne på en annen
 * maskin med en annen klokke, og et tidspunkt avrundet til nærmeste minutt er
 * ikke en usann påstand. Uten slakk ville en riktig kjøring blitt stoppet av
 * tre sekunder, og da ville kontrollen blitt skrudd av framfor fulgt.
 */
const ANSWER_CLOCK_SLACK_MS = 5 * 60 * 1000

/** Kjøremappa et oppdrag får når kalleren ikke oppgir en. */
export function defaultRunDirectory(assignmentPath: string): string {
  return join(dirname(assignmentPath), basename(assignmentPath).replace(/\.json$/i, ''))
}

function optionalText(fields: Fields, key: string): string | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'string') {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke tekst')
  }
  return value
}

/** Leser og kontrollerer `kjoring.json`, eller sier hvilket felt som er galt. */
export function parseDraftingJob(value: unknown): DraftingJob {
  const fields = fieldsOf(value, JOB_SUBJECT, 'kjøringen')

  const version = asText(fields, 'job_version')
  if (version !== DRAFTING_JOB_VERSION) {
    problem(
      JOB_SUBJECT,
      'kjøringen.job_version',
      `er ${JSON.stringify(version)}, men denne kjøreren leser ` +
        `${JSON.stringify(DRAFTING_JOB_VERSION)}. Åpne kjøringen på nytt i en tom katalog`,
    )
  }

  const requestDigest = asText(fields, 'request_digest')
  if (!DIGEST_PATTERN.test(requestDigest)) {
    problem(
      JOB_SUBJECT,
      'kjøringen.request_digest',
      'har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn',
    )
  }

  const state = asText(fields, 'state')
  if (!JOB_STATES.includes(state)) {
    problem(
      JOB_SUBJECT,
      'kjøringen.state',
      `er ${JSON.stringify(state)}, som ikke er en tilstand denne kjøreren kjenner`,
    )
  }

  const job: DraftingJob = {
    jobVersion: DRAFTING_JOB_VERSION,
    assignmentPath: asText(fields, 'assignment_path'),
    sourceVersionId: asText(fields, 'source_version_id'),
    retrievedFrom: asText(fields, 'retrieved_from'),
    contentHash: asText(fields, 'content_hash'),
    requestDigest,
    promptTemplateVersion: asText(fields, 'prompt_template_version'),
    state: state as DraftingJobState,
    openedAt: asText(fields, 'opened_at'),
    closedAt: optionalText(fields, 'closed_at'),
    reason: optionalText(fields, 'reason'),
  }
  rejectUnknown(fields)
  return job
}

/** `kjoring.json` slik den skrives. */
export function serializeDraftingJob(job: DraftingJob): unknown {
  return {
    job_version: job.jobVersion,
    assignment_path: job.assignmentPath,
    source_version_id: job.sourceVersionId,
    retrieved_from: job.retrievedFrom,
    content_hash: job.contentHash,
    request_digest: job.requestDigest,
    prompt_template_version: job.promptTemplateVersion,
    state: job.state,
    opened_at: job.openedAt,
    closed_at: job.closedAt,
    reason: job.reason,
  }
}

/**
 * Malen `open` legger igjen, med avtrykket allerede fylt ut.
 *
 * Avtrykket står der fordi det er den ene verdien aktøren ikke kan finne på
 * selv, og plassholderne står der fordi de tre andre er ting bare aktøren vet.
 * En mal med tomme strenger ville sett ferdig ut; en med plassholdere avvises
 * med en setning som sier hva som mangler (`model-identity.ts`).
 */
export function answerTemplate(requestDigest: string): unknown {
  return {
    answer_version: MODEL_ANSWER_VERSION,
    request_digest: requestDigest,
    identity: PLACEHOLDER_IDENTITY,
    answered_at: `${PLACEHOLDER_PREFIX}TIDSPUNKT`,
    draft: {},
  }
}

type JsonFile = { readonly present: false } | { readonly present: true; readonly value: unknown }

const ABSENT: JsonFile = { present: false }

async function readJsonFile(path: string): Promise<JsonFile> {
  let text: string
  try {
    text = await readFile(path, 'utf8')
  } catch {
    return ABSENT
  }
  try {
    return { present: true, value: JSON.parse(text) as unknown }
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`${path} er ikke gyldig JSON: ${message}`, { cause })
  }
}

async function writeJsonFile(path: string, value: unknown): Promise<void> {
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}

/**
 * Om svarfilen bærer et svar, eller bare er malen `open` la igjen.
 *
 * Skillet avgjør om `open` får skrive over den. Et svar kan være eneste kopi av
 * en modellkjøring som allerede er gjort, og en gjenopptatt kjøring skal ikke
 * kunne slette den i stillhet. En mal skal derimot kunne skrives over.
 */
export function answerHoldsAnAnswer(value: unknown): boolean {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false
  }
  const record = value as Record<string, unknown>
  const draft = record.draft
  if (
    typeof draft === 'object' &&
    draft !== null &&
    !Array.isArray(draft) &&
    Object.keys(draft).length > 0
  ) {
    return true
  }
  const completion = record.completion
  return typeof completion === 'string' && completion.trim().length > 0
}

async function answerFileHoldsAnAnswer(path: string): Promise<boolean> {
  let file: JsonFile
  try {
    file = await readJsonFile(path)
  } catch {
    // Ugyldig JSON: filen kan bære et svar noen har klusset til, og skal ikke
    // skrives over av en gjenopptakelse.
    return true
  }
  return file.present && answerHoldsAnAnswer(file.value)
}

export interface DraftingJobPorts {
  readonly retrieve?: RetrieveLike
  readonly retrieveOptions?: RetrieveOptions
  /** Klokka, injisert, slik at tidspunktene i kjøringen kan festes i en prøve. */
  readonly now?: () => string
  readonly log?: (line: string) => void
}

function retrievalPorts(ports: DraftingJobPorts): {
  retrieve?: RetrieveLike
  retrieveOptions?: RetrieveOptions
} {
  return {
    ...(ports.retrieve === undefined ? {} : { retrieve: ports.retrieve }),
    ...(ports.retrieveOptions === undefined ? {} : { retrieveOptions: ports.retrieveOptions }),
  }
}

export interface OpenJobOptions extends DraftingJobPorts {
  readonly assignmentPath: string
  /** Kjøremappa. Utledes av oppdragsfilen når den ikke oppgis. */
  readonly runDirectory?: string
}

export interface OpenJobReport {
  readonly outcome: 'opened' | 'resumed' | 'already_drafted'
  readonly runDirectory: string
  readonly job: DraftingJob
  readonly promptPath: string
  readonly answerPath: string
  /** Forslaget, når kjøringen allerede var lukket med et. */
  readonly proposalPath?: string
  /** Hvorfor forrige forsøk ble avvist, når mappa bar en avvist kjøring. */
  readonly previousReason?: string
}

/**
 * Åpner — eller gjenopptar — kjøringen for ett oppdrag.
 *
 * Henter kildeversjonen og krever at fingeravtrykket er den registrerte, før
 * noe skrives: en prompt bygget av en annen utgave enn den ekstraksjonen skal
 * peke på, er ikke en prompt noen skal kjøre.
 *
 * Kjøringen er idempotent. Den samme kommandoen kjørt om igjen på en mappe som
 * allerede venter på svar, skriver den samme prompten og lar svarfilen stå.
 */
export async function openDraftingJob(options: OpenJobOptions): Promise<OpenJobReport> {
  const { assignmentPath, now = () => new Date().toISOString(), log = () => {} } = options
  const runDirectory = options.runDirectory ?? defaultRunDirectory(assignmentPath)

  const assignment = parseAssignmentJson(assignmentPath, await readFile(assignmentPath, 'utf8'))
  const jobPath = join(runDirectory, JOB_FILES.job)
  const promptPath = join(runDirectory, JOB_FILES.prompt)
  const answerPath = join(runDirectory, JOB_FILES.answer)
  const proposalPath = join(runDirectory, JOB_FILES.proposal)

  const existingFile = await readJsonFile(jobPath)
  const existing = existingFile.present ? parseDraftingJob(existingFile.value) : null
  if (existing !== null && existing.assignmentPath !== assignmentPath) {
    throw new Error(
      `${runDirectory} er kjøremappa til ${existing.assignmentPath}, ikke til ${assignmentPath}. ` +
        'To oppdrag skal ikke dele mappe: svaret på det ene ville da ligget der kjøringen for det ' +
        'andre leter. Oppgi en annen katalog.',
    )
  }

  // En ferdig kjøring svares ut før hentingen, ikke etter.
  //
  // Filen neste ledd venter på, ligger der allerede, og det er hele svaret. Ble
  // kilden utilgjengelig eller endret etterpå, ville en henting her gjort den
  // idempotente kommandoen til en som feiler — nettopp i den situasjonen en
  // avbrutt Routine kjører den om igjen. `--close` gjør det samme.
  if (
    existing !== null &&
    existing.state === 'drafted' &&
    (await readJsonFile(proposalPath)).present
  ) {
    log(`Kjøringen er allerede lukket med et forslag: ${proposalPath}`)
    return {
      outcome: 'already_drafted',
      runDirectory,
      job: existing,
      promptPath,
      answerPath,
      proposalPath,
    }
  }

  const { request, requestDigest } = await prepareDraftingRequest({
    assignment,
    ...retrievalPorts(options),
  })

  if (
    existing !== null &&
    existing.requestDigest !== requestDigest &&
    (await answerFileHoldsAnAnswer(answerPath))
  ) {
    // Avtrykket er et annet, og svarfilen bærer et svar. Svaret ble lest ut av
    // en annen tekst enn den kjøringen nå ville bygget, og et svar som ble
    // stående, ville blitt kontrollert mot feil forespørsel.
    throw new Error(
      'Forespørselen har fått et annet fingeravtrykk siden kjøringen ble åpnet ' +
        `(${existing.requestDigest} → ${requestDigest}), og ${answerPath} bærer allerede et svar. ` +
        'Avtrykket dekker kildeteksten, katalogen i oppdraget og promptmalen; endres én av dem, ' +
        'gjelder ikke det gamle svaret. Flytt eller slett svarfilen for å be om et nytt svar, ' +
        'eller bruk en annen katalog.',
    )
  }

  const job: DraftingJob = {
    jobVersion: DRAFTING_JOB_VERSION,
    assignmentPath,
    sourceVersionId: assignment.sourceVersionId,
    retrievedFrom: assignment.retrievedFrom,
    contentHash: assignment.contentHash,
    requestDigest,
    promptTemplateVersion: request.promptTemplateVersion,
    state: 'awaiting_answer',
    openedAt: existing?.openedAt ?? now(),
    closedAt: null,
    reason: null,
  }

  await mkdir(runDirectory, { recursive: true })
  await writeFile(promptPath, `${request.system}\n\n${'='.repeat(78)}\n\n${request.user}\n`, 'utf8')
  if (!(await answerFileHoldsAnAnswer(answerPath))) {
    await writeJsonFile(answerPath, answerTemplate(requestDigest))
  }
  await writeJsonFile(jobPath, serializeDraftingJob(job))

  log(
    `${existing === null ? 'Åpnet' : 'Gjenopptok'} kjøringen i ${runDirectory} for kildeversjon ` +
      `${assignment.sourceVersionId}, forespørsel ${requestDigest}.`,
  )
  return {
    outcome: existing === null ? 'opened' : 'resumed',
    runDirectory,
    job,
    promptPath,
    answerPath,
    ...(existing?.reason == null ? {} : { previousReason: existing.reason }),
  }
}

export interface CloseJobOptions extends DraftingJobPorts {
  readonly runDirectory: string
  /**
   * Oppdragsfilen, når kalleren oppgir den.
   *
   * Er den oppgitt, kontrolleres den mot den kjøringen ble åpnet for. En
   * Routine som kjører de to kommandoene med det samme argumentet, får da
   * beskjed dersom den har pekt på feil mappe — framfor å lukke et svar inn i
   * en kjøring for et annet oppdrag.
   */
  readonly assignmentPath?: string
}

export interface CloseJobReport {
  readonly outcome: 'drafted' | 'rejected' | 'already_drafted'
  readonly runDirectory: string
  readonly job: DraftingJob
  readonly proposalPath: string
  readonly proposal?: ExtractionProposal
  /** Modellens svar, ordrett. Bare satt når et svar ble lest og kontrollert. */
  readonly completion?: string
  readonly reason?: string
}

function serializeRecording(recording: ModelRecording): unknown {
  return {
    recording_version: recording.recordingVersion,
    identity: {
      provider: recording.identity.provider,
      model: recording.identity.model,
      model_version: recording.identity.modelVersion,
    },
    entries: recording.entries.map((entry) => ({
      request_digest: entry.requestDigest,
      prompt_template_version: entry.promptTemplateVersion,
      completion: entry.completion,
    })),
  }
}

/**
 * Lukker kjøringen: leser svaret, kontrollerer det, og skriver forslaget.
 *
 * Skriver forslaget bare når svaret holder mål på alle tre punktene
 * `drafting-run.ts` kontrollerer — formen, katalogen og de ordrette utdragene.
 * Ellers skrives ingen fil, og kjøringen står som avvist med en begrunnelse.
 */
export async function closeDraftingJob(options: CloseJobOptions): Promise<CloseJobReport> {
  const { runDirectory, now = () => new Date().toISOString(), log = () => {} } = options

  const jobPath = join(runDirectory, JOB_FILES.job)
  const answerPath = join(runDirectory, JOB_FILES.answer)
  const promptPath = join(runDirectory, JOB_FILES.prompt)
  const proposalPath = join(runDirectory, JOB_FILES.proposal)
  const recordingPath = join(runDirectory, JOB_FILES.recording)

  const jobFile = await readJsonFile(jobPath)
  if (!jobFile.present) {
    throw new Error(
      `${jobPath} finnes ikke, så det er ingen kjøring å lukke her. Åpne kjøringen først med ` +
        '--open, som henter kildeversjonen og skriver ut prompten.',
    )
  }
  const job = parseDraftingJob(jobFile.value)

  if (options.assignmentPath !== undefined && options.assignmentPath !== job.assignmentPath) {
    throw new Error(
      `${runDirectory} er kjøremappa til ${job.assignmentPath}, ikke til ${options.assignmentPath}.`,
    )
  }

  // En avbrutt kjøring som rakk å skrive forslaget, skal ikke lage det på nytt:
  // filen er allerede resultatet, og neste ledd venter på den.
  if (job.state === 'drafted' && (await readJsonFile(proposalPath)).present) {
    log(`Kjøringen var allerede lukket med et forslag: ${proposalPath}`)
    return { outcome: 'already_drafted', runDirectory, job, proposalPath }
  }

  const assignment = parseAssignmentJson(
    job.assignmentPath,
    await readFile(job.assignmentPath, 'utf8'),
  )

  const answerFile = await readJsonFile(answerPath)
  if (!answerFile.present) {
    throw new Error(
      `${answerPath} finnes ikke. Modellen skal lese ${promptPath} og legge svaret sitt der.`,
    )
  }
  if (!answerHoldsAnAnswer(answerFile.value)) {
    throw new Error(
      `${answerPath} står fortsatt uten et svar. Legg modellens svar i draft som et JSON-objekt, ` +
        'eller i completion som ordrett tekst, og fyll ut identity med leverandøren, modellen og ' +
        'modellversjonen som faktisk svarte.',
    )
  }
  const answer = parseModelAnswer(answerFile.value)

  if (answer.requestDigest !== job.requestDigest) {
    throw new Error(
      `${answerPath} svarer på forespørselen ${answer.requestDigest}, mens denne kjøringen ble ` +
        `åpnet for ${job.requestDigest}. Et svar lest ut av én forespørsel skal ikke lukkes inn i ` +
        'en annen. Avtrykket står i kjoring.json og skal kopieres derfra uendret.',
    )
  }

  const closedAt = now()
  // Et tidspunkt utenfor vinduet mellom åpningen og nå, beskriver ikke denne
  // kjøringen. Det ville blitt registrert som da utkastet ble laget, og en
  // proveniens som sier at modellen svarte før den fikk spørsmålet, er ikke en
  // unøyaktighet — den er usann (ANTIDEP_CONSTITUTION.md §14).
  //
  // Tidspunktene sammenlignes som klokkeslett og ikke som tekst: to gyldige
  // ISO-tidspunkter med hver sin tidssone kan ikke sammenlignes tegn for tegn.
  if (answer.answeredAt !== null) {
    const answered = Date.parse(answer.answeredAt)
    if (
      answered < Date.parse(job.openedAt) - ANSWER_CLOCK_SLACK_MS ||
      answered > Date.parse(closedAt) + ANSWER_CLOCK_SLACK_MS
    ) {
      throw new Error(
        `${answerPath} oppgir answered_at ${answer.answeredAt}, som ligger utenfor kjøringen: den ` +
          `ble åpnet ${job.openedAt} og lukkes ${closedAt}. Tidspunktet registreres som da ` +
          'utkastet ble laget, og skal derfor være det.',
      )
    }
  }

  const recording = parseModelRecording({
    recording_version: MODEL_RECORDING_VERSION,
    identity: {
      provider: answer.identity.provider,
      model: answer.identity.model,
      model_version: answer.identity.modelVersion,
    },
    entries: [
      {
        request_digest: job.requestDigest,
        prompt_template_version: job.promptTemplateVersion,
        completion: answer.completion,
      },
    ],
  })

  const draftedAt = answer.answeredAt ?? closedAt
  let report: DraftingReport
  try {
    report = await runExtractionDrafting({
      assignment,
      model: createRecordedModelClient(recording),
      now: () => draftedAt,
      log,
      ...retrievalPorts(options),
    })
  } catch (cause) {
    // Den ene forventede kilden til et kast er at forespørselen ikke lenger er
    // den kjøringen ble åpnet for — oppdraget er redigert, eller malen er ny —
    // slik at opptaket ikke har noe svar på den. Det er en avvist kjøring og
    // ikke en krasj, og begrunnelsen er meldingen fra adapteret.
    report = {
      decision: 'rejected',
      requestDigest: job.requestDigest,
      promptTemplateVersion: job.promptTemplateVersion,
      reason: cause instanceof Error ? cause.message : String(cause),
    }
  }

  if (report.decision === 'rejected' || report.proposal === undefined) {
    const reason = report.reason ?? 'ukjent årsak'
    const rejectedJob: DraftingJob = { ...job, state: 'rejected', closedAt, reason }
    await writeJsonFile(jobPath, serializeDraftingJob(rejectedJob))
    return {
      outcome: 'rejected',
      runDirectory,
      job: rejectedJob,
      proposalPath,
      reason,
      ...(report.completion === undefined ? {} : { completion: report.completion }),
    }
  }

  await writeJsonFile(proposalPath, serializeExtractionProposal(report.proposal))
  // Opptaket skrives ved siden av forslaget, ikke fordi kjeden trenger det, men
  // fordi en kjøring som skal undersøkes senere, da kan spilles av gjennom
  // nøyaktig de samme kontrollene uten en modell (`recorded-model.ts`).
  await writeJsonFile(recordingPath, serializeRecording(recording))
  const draftedJob: DraftingJob = { ...job, state: 'drafted', closedAt, reason: null }
  await writeJsonFile(jobPath, serializeDraftingJob(draftedJob))

  return {
    outcome: 'drafted',
    runDirectory,
    job: draftedJob,
    proposalPath,
    proposal: report.proposal,
    ...(report.completion === undefined ? {} : { completion: report.completion }),
  }
}

export interface JobStatusReport {
  readonly runDirectory: string
  readonly job: DraftingJob
  /** Om svarfilen bærer noe annet enn malen. */
  readonly answerPresent: boolean
  /** Om forslaget ligger der. */
  readonly proposalPresent: boolean
}

/** Leser tilstanden i en kjøremappe, uten å hente noe og uten å skrive noe. */
export async function readDraftingJobStatus(runDirectory: string): Promise<JobStatusReport> {
  const jobFile = await readJsonFile(join(runDirectory, JOB_FILES.job))
  if (!jobFile.present) {
    throw new Error(
      `${join(runDirectory, JOB_FILES.job)} finnes ikke, så det er ingen kjøring her.`,
    )
  }
  return {
    runDirectory,
    job: parseDraftingJob(jobFile.value),
    answerPresent: await answerFileHoldsAnAnswer(join(runDirectory, JOB_FILES.answer)),
    proposalPresent: (await readJsonFile(join(runDirectory, JOB_FILES.proposal))).present,
  }
}
