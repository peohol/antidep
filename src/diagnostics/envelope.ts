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

/** Én observasjon på vei fra en nettleser til den private lagringen. */
export interface DiagnosticEnvelope {
  /** Brukerens egen Supabase-token. Ingen klienthemmelighet: den er allerede i fanen. */
  readonly accessToken: string
  readonly area: string
  readonly kind: string
  readonly operation: string | null
  readonly code: string | null
  readonly httpStatus: number | null
  readonly transport: string
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
  return {
    accessToken: text(raw.accessToken, 'accessToken'),
    area: oneOf(raw.area, TECHNICAL_AREAS, 'area'),
    kind: oneOf(raw.kind, FAILURE_KINDS, 'kind'),
    operation: optionalText(raw.operation, 'operation'),
    code: optionalText(raw.code, 'code'),
    httpStatus: typeof status === 'number' ? status : null,
    transport: oneOf(raw.transport, TRANSPORT_SHAPES, 'transport'),
    detail: text(raw.detail, 'detail').slice(0, MAX_DETAIL_CHARS),
  }
}
