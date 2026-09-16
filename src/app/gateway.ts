// ============================================================================
// Den ene veien fra en flate til databasen — og den ene veien en feil kan ta
//
// Hver flate i Antidep leser gjennom en gateway, og hver gateway går gjennom
// `callRpc` her. Samlingen er ikke ryddighet for ryddighetens skyld: den er
// stedet regelen om feilhåndtering faktisk kan håndheves.
//
// ----------------------------------------------------------------------------
// Ingen rå feiltekst når fram til et menneske
//
// Tidligere sendte gatewayene `error.message` rett videre til siden. Det ga
// setninger som «JWT expired», «permission denied for function …» og
// PostgREST-koder til en kliniker som verken kan eller skal gjøre noe med dem.
// En avvisning Antidep selv har formulert, kan være god; en avvisning
// PostgreSQL, PostgREST eller Supabase formulerte, er det aldri. Og de to lar
// seg ikke skille pålitelig fra utsiden: den samme SQLSTATE 42501 kommer både
// fra Antideps egen mandatkontroll og fra en manglende grant.
//
// Flaten formulerer derfor setningen selv, valgt av *hva slags* svikt det var
// og ikke av hva svaret sa. Den rå årsaken går til observability, der en
// teknisk agent kan lese den.
//
// ----------------------------------------------------------------------------
// Hvorfor bare to av sviktformene meldes videre til databasen
//
// «Du har ikke mandat» og «Antidep avviste dette» er ikke tekniske problemer —
// de er systemet som gjør jobben sin. Bare et svar som ikke kom, og et svar som
// ikke stemte med kontrakten, er noe en drift skal se.
//
// ----------------------------------------------------------------------------
// Hvor den rå årsaken faktisk blir liggende
//
// En `console.error` i en nettleser er ingen observability: fanen lukkes, og da
// er årsaken borte. Meldingen til databasen bærer derfor fire
// maskinidentifikatorer — område, svikttype, hvilken api-funksjon kallet gjaldt,
// og hvilken kode svaret bar. Databasen kontrollerer alle fire mot noe den
// selv vet (funksjonen må finnes; koden må være en SQLSTATE eller en
// PostgREST-kode) og skriver setningen selv.
//
// Det er med vilje ikke feilteksten. En videreformidlet feilmelding kan bære et
// filnavn, en adresse eller en del av et svar, og den tekniske loggen skal ikke
// bli et sted slikt samler seg. Operasjonen og koden er nok: de peker på
// nøyaktig ett kall og én feilklasse, og resten står i kildekoden.
//
// Flaten lukker også sin egen melding når det samme kallet går gjennom igjen.
// Uten det ville ett nettverksglipp fått merket i navigasjonen til å lyse for
// alltid, og en lampe som alltid lyser, er en lampe ingen ser på.
// ============================================================================

import { getAntidepClient, type AntidepClient } from '../lib/supabase'

/** Områdene Antidep melder tekniske problemer under. Lukket, som i databasen. */
export type TechnicalArea =
  'work_queue' | 'automatic_task' | 'agent_service' | 'full_text_intake' | 'clinical_content'

/**
 * Hva slags svikt det var — aldri hva svaret sa.
 *
 * `rejected` er Antidep som avviser noe med hensikt; `unavailable` er et svar
 * som ikke kom. De to krever forskjellige ting av den som står ved flaten, og
 * bare den ene er et teknisk problem.
 */
export type GatewayFailureKind =
  | 'unavailable'
  | 'not_authorized'
  | 'not_found'
  | 'invalid_input'
  | 'rejected'
  | 'unreadable_answer'

/** Setningene en flate kan overstyre for sin egen handling. */
export type FailureWording = Partial<Record<GatewayFailureKind, string>>

export class GatewayFailure extends Error {
  readonly kind: GatewayFailureKind
  readonly area: TechnicalArea

  constructor(message: string, kind: GatewayFailureKind, area: TechnicalArea) {
    super(message)
    this.name = 'GatewayFailure'
    this.kind = kind
    this.area = area
  }
}

/**
 * SQLSTATE-ene Antideps egne kontrollerte skriveveier bruker når de avviser
 * noe med hensikt. Listen er lukket, og den avgjør bare *formen* på setningen
 * flaten skriver — aldri innholdet i den.
 */
const DELIBERATE: Readonly<Record<string, GatewayFailureKind>> = {
  '42501': 'not_authorized',
  '02000': 'not_found',
  P0002: 'not_found',
  '22023': 'invalid_input',
  '23001': 'rejected',
  '23505': 'rejected',
  '23514': 'rejected',
}

function errorCode(cause: unknown): string | null {
  if (typeof cause !== 'object' || cause === null) {
    return null
  }
  const code = (cause as { code?: unknown }).code
  return typeof code === 'string' && code.length > 0 ? code : null
}

/**
 * Hva slags svikt dette var.
 *
 * Alt som ikke er en av Antideps egne, bevisste avvisninger, er `unavailable`.
 * Det er med vilje det bredeste alternativet: en ukjent svikt skal behandles
 * som «Antidep svarte ikke», ikke som noe flaten later som om den forstår.
 */
export function classifyGatewayFailure(cause: unknown): GatewayFailureKind {
  const code = errorCode(cause)
  if (code === null) {
    return 'unavailable'
  }
  return DELIBERATE[code] ?? 'unavailable'
}

const DEFAULT_WORDING: Readonly<Record<GatewayFailureKind, string>> = {
  unavailable: 'Antidep svarte ikke akkurat nå. Prøv igjen om litt.',
  not_authorized: 'Du har ikke tilgang til dette i Antidep.',
  not_found: 'Det du ba om, finnes ikke lenger. Hent siden på nytt.',
  invalid_input: 'Det du sendte, kunne ikke brukes.',
  rejected: 'Antidep kunne ikke ta imot dette nå. Hent siden på nytt og prøv igjen.',
  unreadable_answer: 'Antidep svarte noe denne siden ikke kunne lese.',
}

/** Setningen et menneske faktisk får se. Alltid flatens egen, aldri databasens. */
export function describeGatewayFailure(
  kind: GatewayFailureKind,
  wording: FailureWording = {},
): string {
  return wording[kind] ?? DEFAULT_WORDING[kind]
}

/**
 * Setningen en side faktisk viser.
 *
 * Gatewayene formulerer allerede sine egne setninger (`callRpc`), men en side
 * som skrev `cause.message` ordrett, ville vist en rå tekst i det øyeblikket en
 * annen feil enn en GatewayFailure kom denne veien — en programmeringsfeil, en
 * avbrutt forespørsel, en dobbel i en prøve. Regelen om at ingen rå feiltekst
 * når fram til et menneske (issue #99, punkt 8), skal ikke hvile på at hvert
 * kastested husker den.
 */
export function pageMessage(cause: unknown): string {
  if (cause instanceof GatewayFailure) {
    return cause.message
  }
  return DEFAULT_WORDING.unavailable
}

/** Én rå observasjon, slik den går til observability og aldri til en side. */
export interface TechnicalDetail {
  readonly area: TechnicalArea
  readonly operation: string
  readonly kind: GatewayFailureKind
  readonly code: string | null
  readonly detail: string
}

type TechnicalSink = (entry: TechnicalDetail) => void

const consoleSink: TechnicalSink = (entry) => {
  // Én linje, strukturert, med et prefiks som kan søkes etter. Dette er
  // diagnostikk for Claude Code og ChatGPT, ikke noe et menneske leser i UI.
  console.error('[antidep:teknisk]', entry)
}

let sink: TechnicalSink = consoleSink

/**
 * Formen databasen godtar en kode i: en SQLSTATE på fem tegn, eller en
 * PostgREST-kode. Gjentatt her fordi flaten skal la være å sende noe som ville
 * blitt avvist — ikke som en andre sannhet. Databasens kontroll er den som
 * gjelder.
 */
const MACHINE_CODE = /^([0-9A-Z]{5}|PGRST[0-9]{3})$/

/**
 * Hvilke kall flaten har meldt fra om, og ennå ikke lukket.
 *
 * Lever i modulen og ikke i en komponent, fordi den skal overleve at en side
 * byttes ut: det er det samme kallet som sviktet og det samme som går gjennom
 * igjen, uansett hvilken side som gjør det.
 */
const reported = new Set<string>()

/** Bare for prøver: glem hva som er meldt fra om. */
export function forgetReportedProblems(): void {
  reported.clear()
}

/** Bare for prøver: bytt ut observability-sluket og få det tilbake etterpå. */
export function setTechnicalSink(next: TechnicalSink | null): void {
  sink = next ?? consoleSink
}

function rawDetail(cause: unknown): string {
  if (cause instanceof Error) {
    return cause.stack ?? cause.message
  }
  if (typeof cause === 'object' && cause !== null) {
    try {
      return JSON.stringify(cause)
    } catch {
      return String(cause)
    }
  }
  return String(cause)
}

/**
 * Sender den rå årsaken dit den hører hjemme, og ingen andre steder.
 *
 * Returnerer om sviktet er av en form en drift skal se. Bare `unavailable` og
 * `unreadable_answer` er det: en manglende rettighet og en bevisst avvisning er
 * systemet som gjør jobben sin (ANTIDEP_CONSTITUTION.md regel 4).
 */
export function recordTechnicalDetail(
  area: TechnicalArea,
  operation: string,
  kind: GatewayFailureKind,
  cause: unknown,
): boolean {
  sink({ area, operation, kind, code: errorCode(cause), detail: rawDetail(cause) })
  return kind === 'unavailable' || kind === 'unreadable_answer'
}

export interface RpcSpec<T> {
  /** Navnet på api-funksjonen. Går til observability, aldri til en side. */
  readonly fn: string
  readonly args?: Record<string, unknown>
  readonly area: TechnicalArea
  /** Flatens egne setninger for denne handlingen. */
  readonly wording?: FailureWording
  /** Leser svaret med den samme strengheten som en fil. */
  readonly parse: (data: unknown) => T
}

/**
 * Ett kall, med hele feilhåndteringen på ett sted.
 *
 * Et svar som ikke lar seg lese, er like alvorlig som et svar som ikke kom:
 * begge betyr at flaten ikke vet hva den viser. Parsingen ligger derfor her og
 * ikke etter kallet, slik at ingen flate kan hoppe over den.
 */
export async function callRpc<T>(client: AntidepClient, spec: RpcSpec<T>): Promise<T> {
  let data: unknown
  try {
    const outcome = await client.rpc(spec.fn as never, (spec.args ?? {}) as never)
    if (outcome.error !== null) {
      throw fail(client, spec, outcome.error)
    }
    data = outcome.data
  } catch (cause) {
    if (cause instanceof GatewayFailure) {
      throw cause
    }
    // En feil fra transporten selv — nettverket, en avbrutt forespørsel — har
    // ingen kode, og blir dermed `unavailable`, som er riktig.
    throw fail(client, spec, cause)
  }

  let parsed: T
  try {
    parsed = spec.parse(data)
  } catch (cause) {
    throw fail(client, spec, cause, 'unreadable_answer')
  }

  clearTechnicalProblem(client, spec.area, spec.fn)
  return parsed
}

function fail<T>(
  client: AntidepClient,
  spec: RpcSpec<T>,
  cause: unknown,
  forced?: GatewayFailureKind,
): GatewayFailure {
  const kind = forced ?? classifyGatewayFailure(cause)
  if (recordTechnicalDetail(spec.area, spec.fn, kind, cause)) {
    reportTechnicalProblem(client, spec.area, kind, spec.fn, errorCode(cause))
  }
  return new GatewayFailure(describeGatewayFailure(kind, spec.wording), kind, spec.area)
}

/**
 * Melder fra til Antidep at ett kall ikke gikk gjennom.
 *
 * Fire maskinidentifikatorer og ingen tekst: databasen skriver setningen selv,
 * og kontrollerer både at operasjonen finnes og at koden har en kodes form. En
 * uinnlogget kaller blir avvist der, og det er riktig — en melding som ikke kan
 * tilskrives noen, skal ikke kunne få merket i navigasjonen til å lyse.
 */
function reportTechnicalProblem(
  client: AntidepClient,
  area: TechnicalArea,
  kind: GatewayFailureKind,
  operation: string,
  code: string | null,
): void {
  reported.add(`${area}|${operation}`)
  forget(
    client.rpc('report_technical_problem', {
      p_area: area,
      p_kind: kind,
      p_operation: operation,
      // Koden sendes bare når den har den formen databasen godtar. En kode
      // flaten ikke kjenner igjen, er ikke en opplysning verdt å presse
      // gjennom en kontroll — den ville bare fått hele meldingen avvist.
      p_code: MACHINE_CODE.test(code ?? '') ? code : null,
    }),
  )
}

/**
 * Lukker flatens egen melding når det samme kallet går gjennom igjen.
 *
 * Kalles bare når det faktisk finnes noe å lukke. Et kall per vellykket
 * lesing ville vært en dobling av trafikken for å rydde i noe som nesten
 * alltid ikke er der.
 */
function clearTechnicalProblem(
  client: AntidepClient,
  area: TechnicalArea,
  operation: string,
): void {
  const key = `${area}|${operation}`
  if (!reported.delete(key)) {
    return
  }
  forget(client.rpc('clear_technical_problem', { p_area: area, p_operation: operation }))
}

/**
 * Sender kallet uten å vente på det, og uten å la det bli en feil.
 *
 * Feiler meldingen, er det ingenting mer å gjøre: da er det nettopp databasen
 * som ikke svarer. Den svelges derfor med vilje, framfor å bli en ny feil på
 * toppen av den som allerede er vist.
 */
function forget(call: PromiseLike<unknown>): void {
  void Promise.resolve(call).then(
    () => undefined,
    () => undefined,
  )
}

/** Klienten flatene deler. Egen funksjon slik at en prøve kan sende inn sin egen. */
export function antidepClient(): AntidepClient {
  return getAntidepClient()
}
