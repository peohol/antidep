// ============================================================================
// Agentplattformen som et driftssteg, ikke som en redaksjonell beslutning
//
// Fram til issue #99 lå dette i produkt-UI: en redaktør skulle velge leverandør,
// modell og modellversjon for hvert agentledd, registrere en «kjører», hente en
// tilkoblingskode og trekke den tilbake. Ingen av delene er klinisk eller
// redaksjonelt arbeid, og ingen av dem er noe en kliniker kan vurdere.
//
// Handlingene er ikke borte — de er flyttet dit de hører hjemme. Modulen her er
// den operasjonelle delen, og `agent-platform-cli.ts` er kommandoen. Den kjøres
// av Claude Code, av ChatGPT eller av repo-eieren som en del av oppsettet, og
// aldri fra en brukerflate.
//
// ----------------------------------------------------------------------------
// Sikkerhetsgrensene er uendret
//
// Tildelingen er fortsatt en attestert avgjørelse tatt FØR oppgaven hentes ut,
// den inngår fortsatt i oppgavens avtrykk, og et svar kan fortsatt bekrefte sin
// identitet uten å bestemme den (ANTIDEP_CONSTITUTION.md regel 3). Ingen modell
// attesterer seg selv, og ingen av databasens kontroller er svekket: dette er
// de samme `api`-funksjonene flaten kalte, kalt fra et annet sted.
//
// ----------------------------------------------------------------------------
// Den manuelle handoffen er en recovery-mekanisme
//
// Nedlast/opplast-veien består, fordi den er nyttig når en planlagt kjøring er
// nede og under feilsøking. Den er bare ikke en klinikeroppgave lenger. Filen
// bærer hele den kontrollerte kildeteksten og skal aldri commites, legges i en
// issue eller havne i en logg (`scripts/verify-repo.sh` fanger et forsøk).
// ============================================================================

import {
  handoffContract,
  isHandoffRole,
  parseAgentRunnerConnections,
  parseAgentRunnerPairingCode,
  parseAgentRunnerRevocation,
  parseAgentTask,
  parseAgentWorkQueue,
  parseImportOutcome,
  parseRoleModelAssignment,
  type AgentRunnerConnection,
  type AgentRunnerPairingCode,
  type AgentRunnerRevocation,
  type AgentTask,
  type AgentWorkItem,
  type ImportOutcome,
  type RoleModelAssignment,
} from '../agents/agent-task.ts'

/** Valget av KI-tjeneste for ett agentledd, slik kommandoen samler det inn. */
export interface RoleModelChoice {
  readonly role: string
  readonly provider: string
  readonly model: string
  /**
   * Tom med mindre tjenesten faktisk viser en eksakt versjon.
   *
   * Eksponeringsgraden utledes av dette framfor å være et valg: en oppdiktet
   * versjon ville sett like troverdig ut som en sann, og «vet ikke» er en sann
   * opplysning som skal registreres som nettopp det (ANTIDEP_CONSTITUTION.md
   * regel 4).
   */
  readonly modelVersion: string | null
  readonly reason: string | null
  /** Begrunnelsen for et bytte. Kreves når leddet allerede har en tjeneste. */
  readonly replacesReason: string | null
}

/**
 * Registreringen av én autonom kjører.
 *
 * `platformModelDisclosure` er en opplysning om plattformen og ikke om
 * modellen: pinner Workspace Agent-en en bestemt modell plattformen viser, er
 * den `platform_pinned`; gjør den ikke det, er den `not_exposed`. Det siste er
 * en sann opplysning framfor en mangel som skal skjules — separasjonen hviler
 * da på modelltildelingen, som i den manuelle handoffen.
 */
export interface RunnerRegistration {
  readonly connectionKey: string
  readonly displayName: string
  readonly role: string
  readonly platformAgentReference: string
  readonly platformModelDisclosure: 'platform_pinned' | 'not_exposed'
  readonly reason: string | null
}

/** Hva kommandoen trenger av databasen, som en injiserbar grenseflate. */
export interface AgentPlatformApi {
  listQueue(): Promise<unknown>
  assignRoleModel(choice: RoleModelChoice): Promise<unknown>
  readTask(pipelineJobId: string): Promise<unknown>
  importAnswer(pipelineJobId: string, answer: Record<string, unknown>): Promise<unknown>
  listRunners(): Promise<unknown>
  registerRunner(registration: RunnerRegistration): Promise<unknown>
  issuePairingCode(connectionKey: string): Promise<unknown>
  revokeRunner(connectionKey: string, reason: string): Promise<unknown>
}

export async function listWork(api: AgentPlatformApi): Promise<{
  readonly items: readonly AgentWorkItem[]
  readonly unknownRoles: number
}> {
  return parseAgentWorkQueue(await api.listQueue())
}

export async function assignRoleModel(
  api: AgentPlatformApi,
  choice: RoleModelChoice,
): Promise<RoleModelAssignment> {
  if (!isHandoffRole(choice.role)) {
    throw new Error(
      `«${choice.role}» er ikke et agentledd som settes ut til en ekstern KI-agent. ` +
        'De uavhengige kontrolleddene er Antideps egen deterministiske kode.',
    )
  }
  return parseRoleModelAssignment(await api.assignRoleModel(choice))
}

export async function readTask(api: AgentPlatformApi, pipelineJobId: string): Promise<AgentTask> {
  return parseAgentTask(await api.readTask(pipelineJobId))
}

export async function importAnswer(
  api: AgentPlatformApi,
  pipelineJobId: string,
  answer: Record<string, unknown>,
): Promise<ImportOutcome> {
  return parseImportOutcome(await api.importAnswer(pipelineJobId, answer))
}

export async function listRunners(
  api: AgentPlatformApi,
): Promise<readonly AgentRunnerConnection[]> {
  return parseAgentRunnerConnections(await api.listRunners())
}

export async function issuePairingCode(
  api: AgentPlatformApi,
  connectionKey: string,
): Promise<AgentRunnerPairingCode> {
  return parseAgentRunnerPairingCode(await api.issuePairingCode(connectionKey))
}

export async function revokeRunner(
  api: AgentPlatformApi,
  connectionKey: string,
  reason: string,
): Promise<AgentRunnerRevocation> {
  return parseAgentRunnerRevocation(await api.revokeRunner(connectionKey, reason))
}

/** Køen, som linjer i en terminal. Rå verdier: dette er drift, ikke produkt. */
export function describeWorkItem(item: AgentWorkItem): string {
  const contract = handoffContract(item.role)
  const model =
    item.registeredModel === null
      ? 'ingen KI-tjeneste tildelt'
      : `${item.registeredModel.provider}/${item.registeredModel.model}`
  const held = item.heldByRunner === null ? '' : ` — hentes nå av «${item.heldByRunner}»`
  const blocked = item.blockedReason === null ? '' : `\n    blokkert: ${item.blockedReason}`
  return (
    `  ${item.pipelineJobId}\n` +
    `    ${contract.label}: ${item.subjectLabel}\n` +
    `    ${item.state}, forsøk ${String(item.attempts)}/${String(item.maxAttempts)}, ${model}${held}${blocked}`
  )
}
