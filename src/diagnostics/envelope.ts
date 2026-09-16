// ============================================================================
// Konvolutten den rå årsaken reiser i
//
// Delt mellom nettleseren, som pakker den, og serverruten, som pakker den opp.
// Egen modul fordi de to sidene ellers ville hatt hver sin forståelse av det
// samme skjemaet — og et skjema som er beskrevet to steder, er to skjemaer.
//
// Lesingen er like streng som for alt annet Antidep tar imot: en konvolutt som
// ikke stemmer med kontrakten, avvises framfor å bli tolket velvillig. Det er
// ikke en formalitet her — ruten tar imot fra en nettleser, og det eneste som
// står mellom den og en vilkårlig POST, er denne lesingen og databasens egne
// grenser.
// ============================================================================

/** Områdene Antidep melder tekniske problemer under. Lukket, som i databasen. */
export const TECHNICAL_AREAS = [
  'work_queue',
  'automatic_task',
  'agent_service',
  'full_text_intake',
  'clinical_content',
] as const

/**
 * Områdene en uinnlogget besøkende faktisk kan se svikte.
 *
 * Arbeidsoversikten og det publiserte innholdet er åpne for alle. De tre andre
 * finnes bare bak innlogging, så en observasjon uten token som melder om dem,
 * beskriver noe avsenderen ikke kan ha sett. Den avvises framfor å bli skrevet
 * ned — ikke fordi den er farlig i seg selv, men fordi en anonym vei inn skal
 * være så smal som den kan være og fortsatt gjøre nytte.
 */
export const PUBLIC_TECHNICAL_AREAS = ['work_queue', 'clinical_content'] as const

export const FAILURE_KINDS = ['unavailable', 'unreadable_answer'] as const

export const TRANSPORT_SHAPES = [
  'offline',
  'network',
  'aborted',
  'timeout',
  'http',
  'contract',
  'unknown',
] as const

/**
 * Grensen databasen håndhever, gjentatt her.
 *
 * Ikke som en andre sannhet — databasen klipper uansett — men fordi en stack på
 * flere hundre kilobyte ikke skal sendes over nettet for å bli kastet i andre
 * enden, og fordi ruten skal kunne avvise en absurd stor kropp uten å lese den
 * inn i databasen først.
 */
export const MAX_DETAIL_CHARS = 4000

/**
 * Fjerner det som ser ut som en hemmelighet, før teksten lagres noe sted.
 *
 * Den samme vaskingen finnes i databasen, og den er den autoritative. Denne
 * kjøres likevel først, fordi årsaken legges i nettleserens eget lager før den
 * sendes: en bearer-token som havnet i en feilmelding, skal ikke bli liggende
 * lesbar i `localStorage` i påvente av en levering.
 *
 * Bevisst smal, som databasens: målet er ikke å gjøre teksten trygg i seg selv,
 * men å hindre at en token overlever lenger enn den lever.
 */
export function scrubDetail(detail: string): string {
  return detail
    .replace(/eyJ[A-Za-z0-9_.-]{20,}/g, '[token utelatt]')
    .replace(/(bearer|apikey|api_key|authorization|password)([=: ]+)[^\s,;"']+/gi, '$1$2[utelatt]')
    .slice(0, MAX_DETAIL_CHARS)
}

/** Én observasjon på vei fra en nettleser til den private lagringen. */
export interface DiagnosticEnvelope {
  /**
   * Flatens eget nummer på observasjonen.
   *
   * Gjør leveringen idempotent: en fane som lukkes midt i sendingen, vet ikke om
   * raden kom fram, og beholder observasjonen til den vet det. Uten nummeret
   * ville den samme årsaken blitt liggende i to eksemplarer hver gang.
   */
  readonly eventId: string
  /**
   * Brukerens egen Supabase-token, videresendt. Ingen klienthemmelighet: den
   * ligger allerede i fanen.
   *
   * `null` når ingen er innlogget. Da er observasjonen anonym, og den kan ikke
   * tilskrives noen — den blir derfor aldri en rad i databasen, bare en linje i
   * Antideps egen serverlogg.
   */
  readonly accessToken: string | null
  readonly area: string
  readonly kind: string
  readonly operation: string | null
  readonly code: string | null
  readonly httpStatus: number | null
  readonly transport: string
  /**
   * Stacken og meldingen slik flaten så dem.
   *
   * Alltid tom når `accessToken` er `null`: en anonym vei inn for fritekst
   * ville vært en logg hvem som helst kunne fylle med sine egne ord.
   */
  readonly detail: string
}

function text(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`Diagnostikkonvolutten er ugyldig: ${field} er ikke en tekst.`)
  }
  return value
}

function optionalText(value: unknown, field: string): string | null {
  if (value === null || value === undefined) {
    return null
  }
  return text(value, field)
}

function oneOf(value: unknown, allowed: readonly string[], field: string): string {
  const found = text(value, field)
  if (!allowed.includes(found)) {
    throw new Error(`Diagnostikkonvolutten er ugyldig: ${field} er ukjent.`)
  }
  return found
}

/**
 * Leser en konvolutt slik den kom inn.
 *
 * Kaster på alt som ikke stemmer. Ruten svarer da med en avvisning og skriver
 * ingenting: en observasjon vi ikke forstår, er ikke en observasjon.
 */
export function parseDiagnosticEnvelope(value: unknown): DiagnosticEnvelope {
  if (typeof value !== 'object' || value === null) {
    throw new Error('Diagnostikkonvolutten er ugyldig: svaret er ikke et objekt.')
  }
  const raw = value as Record<string, unknown>
  const status = raw.httpStatus
  if (
    status !== null &&
    status !== undefined &&
    (typeof status !== 'number' || !Number.isInteger(status) || status < 100 || status > 599)
  ) {
    throw new Error('Diagnostikkonvolutten er ugyldig: httpStatus er ikke en HTTP-status.')
  }
  const eventId = text(raw.eventId, 'eventId')
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(eventId)) {
    throw new Error('Diagnostikkonvolutten er ugyldig: eventId er ikke en uuid.')
  }
  const accessToken = optionalText(raw.accessToken, 'accessToken')
  return {
    eventId,
    accessToken,
    area: oneOf(raw.area, TECHNICAL_AREAS, 'area'),
    kind: oneOf(raw.kind, FAILURE_KINDS, 'kind'),
    operation: optionalText(raw.operation, 'operation'),
    code: optionalText(raw.code, 'code'),
    httpStatus: typeof status === 'number' ? status : null,
    transport: oneOf(raw.transport, TRANSPORT_SHAPES, 'transport'),
    // Uten en token finnes det ingen å tilskrive teksten, og da leses den ikke
    // i det hele tatt — den kastes her, før noe annet ser konvolutten. Den
    // sterkeste formen: ikke «teksten filtreres», men «teksten finnes ikke på
    // denne veien», uansett hva kalleren la ved.
    detail: accessToken === null ? '' : text(raw.detail, 'detail').slice(0, MAX_DETAIL_CHARS),
  }
}
