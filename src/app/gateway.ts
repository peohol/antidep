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
// Klassifiseringen er likevel ikke diagnosen. Den rå årsaken — stacken, den
// faktiske meldingen — havner i `workflow.client_diagnostics`: en egen, privat
// tabell uten grants, uten policy og uten noen api-lesevei. Skillet er med
// vilje. Tilstandsraden er Antideps ord om hva som er galt, og den skal aldri
// bære en videreformidlet feiltekst; råmaterialet er klientens ord om hva den
// så, og det er bundet av attribusjon, en kvote per bruker og time, en
// lengdegrense og vasking av tokenformede strenger.
//
// ----------------------------------------------------------------------------
// To meldinger, to veier — og det er ikke ryddighet
//
// Meldingen om at et område ikke svarer, går over Data API-et. Den rå årsaken
// gjør det ikke, og kan ikke gjøre det: det er nettopp den veien som kanskje er
// nede. Den går derfor til `/diagnostics`, en rute på Antideps egen
// opprinnelse, med `sendBeacon` — som nettleseren leverer selv mens fanen
// lukkes, og som ikke har noen preflight å feile på.
//
// De to har også forskjellige krav til å komme fram. En tilstandsrad kan
// gjentas ved neste svikt; den rå årsaken finnes bare denne ene gangen. Den
// legges derfor i en utboks *før* den sendes, og blir liggende til leveringen
// er bekreftet — så en utilgjengelig lagring utsetter den framfor å miste den
// (`diagnostics-outbox.ts`). Nummeret på observasjonen gjør at et nytt forsøk
// blir den samme raden og ikke en til.
//
// En `console.error` er ingen erstatning: fanen lukkes, og da er årsaken borte.
// Konsollen skrives til uansett, fordi den er det den som feilsøker lokalt
// leser — men det varige er raden.
//
// En kode alene er ikke nok, for koden mangler nettopp når svaret aldri kom.
// Meldingen bærer derfor også HTTP-statusen og en *transportform* fra et lukket
// vokabular — uten nett, nådde ikke fram, avbrutt, tidsavbrudd, feilkode fra
// tjenesten, brøt kontrakten. Til sammen sier de ikke bare at `api.foo` sviktet,
// men hvordan.
//
// Det er med vilje ikke feilteksten. En videreformidlet feilmelding kan bære et
// filnavn, en adresse eller en del av et svar, og den tekniske loggen skal ikke
// bli et sted slikt samler seg.
//
// Flaten lukker ingenting. En selvmeldt rad gjelder så lenge den fornyes, og
// det er databasen som avgjør når den er over
// (`workflow.self_report_heartbeat()`). Å la flaten lukke sin egen melding
// ville lagt oppryddingen av varig servertilstand i et minne som forsvinner
// ved en sideoppfriskning eller en ny fane — og da ville ett nettverksglipp
// kunnet bli stående som et uløst problem for alltid.
// ============================================================================

import { getAntidepClient, type AntidepClient } from '../lib/supabase'
import { forget, pending, remember, type PendingDiagnostic } from './diagnostics-outbox'

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

/**
 * Formen på en svikt, som et lukket vokabular databasen deler.
 *
 * Finnes fordi koden mangler nettopp når svaret aldri kom. Den utledes av
 * *formen* på det som gikk galt og aldri av teksten i det, slik at den kan
 * være en maskinidentifikator og ikke en videreformidlet feilmelding.
 */
export type TransportShape =
  'offline' | 'network' | 'aborted' | 'timeout' | 'http' | 'contract' | 'unknown'

/** Én rå observasjon, slik den går til observability og aldri til en side. */
export interface TechnicalDetail {
  readonly area: TechnicalArea
  readonly operation: string
  readonly kind: GatewayFailureKind
  readonly code: string | null
  readonly httpStatus: number | null
  readonly transport: TransportShape
  readonly detail: string
}

export type TechnicalSink = (entry: TechnicalDetail) => void

const consoleSink: TechnicalSink = (entry) => {
  // Én linje, strukturert, med et prefiks som kan søkes etter. Dette er for den
  // som feilsøker lokalt; det varige er raden i workflow.client_diagnostics.
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
 * Grensen databasen håndhever, gjentatt her med vilje.
 *
 * Ikke som en andre sannhet — databasen klipper uansett — men fordi en stack
 * på flere hundre kilobyte ikke skal sendes over nettet for å bli kastet i
 * andre enden.
 */
const MAX_DETAIL_CHARS = 4000

/**
 * Hvilken form svikten hadde.
 *
 * Leses av hva slags feil dette *er* — er nettet borte, ble forespørselen
 * avbrutt, svarte tjenesten med en kode — og aldri av hva feilen sa. Det er
 * nettopp derfor verdien kan sendes videre: den kan ikke bære innhold.
 */
export function transportShape(cause: unknown, kind: GatewayFailureKind): TransportShape {
  if (kind === 'unreadable_answer') {
    return 'contract'
  }
  if (httpStatusOf(cause) !== null) {
    return 'http'
  }
  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    return 'offline'
  }
  const name =
    typeof cause === 'object' && cause !== null ? (cause as { name?: unknown }).name : null
  if (name === 'AbortError') {
    return 'aborted'
  }
  if (name === 'TimeoutError') {
    return 'timeout'
  }
  // `fetch` melder et brudd i nettet som en TypeError, og det er den eneste
  // formen den har. Alt annet er noe flaten ikke kjenner igjen, og skal si det.
  if (cause instanceof TypeError) {
    return 'network'
  }
  return 'unknown'
}

function httpStatusOf(cause: unknown): number | null {
  if (typeof cause !== 'object' || cause === null) {
    return null
  }
  const status = (cause as { status?: unknown }).status
  return typeof status === 'number' && status >= 100 && status <= 599 ? status : null
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
  httpStatus: number | null = null,
): TechnicalDetail | null {
  const entry: TechnicalDetail = {
    area,
    operation,
    kind,
    code: errorCode(cause),
    httpStatus: httpStatus ?? httpStatusOf(cause),
    transport: transportShape(cause, kind),
    // Klippes allerede her. Databasen klipper uansett, men en stack på flere
    // hundre kilobyte skal ikke sendes over nettet for å bli kastet i andre
    // enden — og `sendBeacon` har sin egen, mindre kø å ta hensyn til.
    detail: rawDetail(cause).slice(0, MAX_DETAIL_CHARS),
  }
  sink(entry)
  return kind === 'unavailable' || kind === 'unreadable_answer' ? entry : null
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
  // Statusen følger med svaret og ikke med feilen: PostgREST-feilen selv bærer
  // en kode, mens *hvilken* HTTP-status tjenesten svarte med, står i
  // konvolutten rundt. Begge deler er maskinidentifikatorer, og begge trengs —
  // en 503 og en 401 er to helt forskjellige driftsproblemer.
  // Tilordnes alltid før den leses: catch-grenen kaster, så veien videre går
  // bare gjennom en fullført try.
  let httpStatus: number | null
  try {
    const outcome = await client.rpc(spec.fn as never, (spec.args ?? {}) as never)
    httpStatus = typeof outcome.status === 'number' ? outcome.status : null
    if (outcome.error !== null) {
      throw fail(client, spec, outcome.error, undefined, httpStatus)
    }
    data = outcome.data
  } catch (cause) {
    if (cause instanceof GatewayFailure) {
      throw cause
    }
    // En feil fra transporten selv — nettverket, en avbrutt forespørsel — har
    // ingen kode og ingen status. Da er transportformen det eneste som sier
    // noe om hva som skjedde, og det er nettopp derfor den finnes.
    throw fail(client, spec, cause)
  }

  try {
    return spec.parse(data)
  } catch (cause) {
    throw fail(client, spec, cause, 'unreadable_answer', httpStatus)
  }
}

function fail<T>(
  client: AntidepClient,
  spec: RpcSpec<T>,
  cause: unknown,
  forced?: GatewayFailureKind,
  httpStatus: number | null = null,
): GatewayFailure {
  const kind = forced ?? classifyGatewayFailure(cause)
  const entry = recordTechnicalDetail(spec.area, spec.fn, kind, cause, httpStatus)
  if (entry !== null) {
    reportTechnicalProblem(client, entry)
    recordRawCause(client, entry)
  }
  return new GatewayFailure(describeGatewayFailure(kind, spec.wording), kind, spec.area)
}

/**
 * Melder fra til Antidep at ett kall ikke gikk gjennom.
 *
 * Seks maskinidentifikatorer og ingen tekst: databasen skriver setningen selv,
 * og kontrollerer hver av dem. En uinnlogget kaller blir avvist der, og det er
 * riktig — en melding som ikke kan tilskrives noen, skal ikke kunne få merket i
 * navigasjonen til å lyse.
 *
 * Feiler meldingen, er det ingenting mer å gjøre: da er det nettopp databasen
 * som ikke svarer. Den svelges derfor med vilje, framfor å bli en ny feil på
 * toppen av den som allerede er vist. Den rå årsaken går sin egen vei og er
 * ikke avhengig av at denne kom fram.
 */
function reportTechnicalProblem(client: AntidepClient, entry: TechnicalDetail): void {
  void Promise.resolve(
    client.rpc('report_technical_problem', {
      p_area: entry.area,
      p_kind: entry.kind,
      p_operation: entry.operation,
      // Koden sendes bare når den har den formen databasen godtar. En kode
      // flaten ikke kjenner igjen, er ikke en opplysning verdt å presse
      // gjennom en kontroll — den ville bare fått hele meldingen avvist.
      p_code: MACHINE_CODE.test(entry.code ?? '') ? entry.code : null,
      p_http_status: entry.httpStatus,
      p_transport: entry.transport,
    }),
  ).then(
    () => undefined,
    () => undefined,
  )
}

/**
 * Legger den rå årsaken i utboksen, og tømmer den.
 *
 * Rekkefølgen er hele poenget: observasjonen er lagret lokalt før noe sendes,
 * så en levering som ikke går gjennom, utsetter den framfor å miste den.
 */
function recordRawCause(client: AntidepClient, entry: TechnicalDetail): void {
  remember({
    eventId: newEventId(),
    area: entry.area,
    kind: entry.kind,
    operation: entry.operation,
    code: MACHINE_CODE.test(entry.code ?? '') ? entry.code : null,
    httpStatus: entry.httpStatus,
    transport: entry.transport,
    detail: entry.detail,
  })
  flushPendingDiagnostics(client)
}

/**
 * Sender alt som venter, og glemmer bare det som faktisk kom fram.
 *
 * Tokenen er brukerens egen og allerede i fanen — ingen klienthemmelighet. Er
 * det ingen token, sendes ingenting: en rad som ikke kan tilskrives noen, ville
 * vært en åpen skrivevei, og da kunne hvem som helst fylle den private
 * lagringen. Dette gjelder også den åpne arbeidsoversikten, som kan leses uten
 * innlogging, og grensen er bevisst.
 *
 * Det er ikke det samme som at årsaken går tapt: observasjonen blir liggende i
 * utboksen, og den første innloggingen i den nettleseren tar restansen med. En
 * uinnlogget besvergelse som aldri logger inn, er det eneste tilfellet som bare
 * når konsollen — og da finnes det ingen å tilskrive den uansett.
 *
 * Eksportert fordi flaten også kaller den når appen åpnes: da er restansen fra
 * en tidligere økt det eneste som finnes igjen av den.
 */
export function flushPendingDiagnostics(client: AntidepClient): void {
  const waiting = pending()
  if (waiting.length === 0) {
    return
  }
  void Promise.resolve(client.auth.getSession())
    .then(async ({ data }) => {
      const accessToken = data.session?.access_token
      if (accessToken === undefined || accessToken.length === 0) {
        return
      }
      for (const entry of waiting) {
        if (await deliver(accessToken, entry)) {
          forget(entry.eventId)
        }
      }
    })
    .catch(() => undefined)
}

/** Ruten på Antideps egen opprinnelse. Ingenting å konfigurere. */
const DIAGNOSTICS_PATH = '/diagnostics'

function newEventId(): string {
  try {
    return crypto.randomUUID()
  } catch {
    // Eldre nettlesere uten `randomUUID`. Nummeret trenger bare å være unikt
    // nok til at to leveringer av den samme observasjonen møtes.
    const hex = (n: number): string =>
      Math.floor(Math.random() * 16 ** n)
        .toString(16)
        .padStart(n, '0')
    return `${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}`
  }
}

/**
 * Én levering, og et svar på om den kom fram.
 *
 * `keepalive` slik at en forespørsel rett før en navigasjon fullføres — og det
 * er ofte nettopp da den sendes. Til forskjell fra `sendBeacon` gir den et
 * svar, og det svaret er det som avgjør om observasjonen kan glemmes.
 * `sendBeacon` er reserven der `fetch` ikke finnes; da er leveringen ubekreftet,
 * og observasjonen blir liggende til en senere kjøring bekrefter den.
 */
async function deliver(accessToken: string, entry: PendingDiagnostic): Promise<boolean> {
  const body = JSON.stringify({ accessToken, ...entry })
  try {
    const response = await fetch(DIAGNOSTICS_PATH, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
      keepalive: true,
    })
    return response.ok
  } catch {
    try {
      if (typeof navigator !== 'undefined' && typeof navigator.sendBeacon === 'function') {
        navigator.sendBeacon(DIAGNOSTICS_PATH, new Blob([body], { type: 'application/json' }))
      }
    } catch {
      // Kø full, eller ingen Blob. Observasjonen blir liggende.
    }
    return false
  }
}

/** Klienten flatene deler. Egen funksjon slik at en prøve kan sende inn sin egen. */
export function antidepClient(): AntidepClient {
  return getAntidepClient()
}
