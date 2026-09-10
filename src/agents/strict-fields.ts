// ============================================================================
// Å lese en fil utenfra strengt, med regnskap over hva som faktisk ble lest
//
// Modulen eier én disiplin, og den brukes av hver fil Antidep tar imot fra noen
// utenfor: ekstraksjonsforslaget (`extraction-proposal.ts`), oppdraget
// (`extraction-assignment.ts`) og modellopptaket (`recorded-model.ts`).
//
//   1. **Et ukjent felt er en feil, ikke noe som ignoreres.** Regnskapet i
//      `seen` er hele mekanismen: et felt med skrivefeil ville ellers vært
//      usynlig, og filen ville blitt lest uten verdien den trodde den leverte.
//      `extimate` i stedet for `estimate` skal stoppe kjøringen, ikke bli til
//      et manglende estimat i kilden.
//   2. **Ingenting fylles inn.** En manglende verdi er en manglende verdi, og
//      leseren gjetter aldri fra andre felter (ANTIDEP_CONSTITUTION.md §6).
//   3. **Vokabularene er lukket.** En verdi utenfor vokabularet avvises med
//      feltnavnet og de gyldige verdiene.
//
// Feilmeldingene navngir *feltet i filen* framfor kolonnen eller typen. En
// avvisning som pekte på en fremmednøkkel, ville sendt den som skrev filen på
// leting etter noe annet enn det som er galt.
//
// ----------------------------------------------------------------------------
// Hvorfor disiplinen er én modul og ikke én per filtype
//
// De tre filtypene har ulike former, men nøyaktig den samme kontrakten om hva
// lesingen skal gjøre. Tre kopier av `rejectUnknown` ville vært tre steder å
// glemme regnskapet — og en filtype der regelen stille sluttet å gjelde, ville
// vært umulig å se på lesesiden.
//
// `subject` er hva filen heter i en feilmelding, og følger med gjennom de
// nøstede objektene: feilen skal si «Oppdraget er ugyldig: …» for et oppdrag og
// «Ekstraksjonsforslaget er ugyldig: …» for et forslag, uten at hver leser må
// skrive den setningen selv.
//
// Utrygg inndata: filene er data, aldri instruksjoner (CLAUDE.md). Ingenting
// her tolker en verdi som noe annet enn en verdi.
// ============================================================================

import type { Uuid } from '../types/api.ts'

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** Én oppslagsbok, med regnskap over hvilke nøkler som faktisk er lest. */
export interface Fields {
  /** Hva filen heter i en feilmelding, for eksempel «Oppdraget». */
  readonly subject: string
  /** Hvor i filen vi er, for eksempel `field_groundings[0]`. */
  readonly where: string
  readonly record: Record<string, unknown>
  readonly seen: Set<string>
}

/** Avviser med en setning som sier hvor i filen feilen er, og hva som er galt. */
export function problem(subject: string, where: string, what: string): never {
  throw new Error(`${subject} er ugyldig: ${where} ${what}.`)
}

function fail(fields: Fields, key: string | null, what: string): never {
  return problem(fields.subject, key === null ? fields.where : `${fields.where}.${key}`, what)
}

/** Leser et objekt på øverste nivå. */
export function fieldsOf(value: unknown, subject: string, where: string): Fields {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    problem(subject, where, 'er ikke et objekt')
  }
  return { subject, where, record: value as Record<string, unknown>, seen: new Set() }
}

/** Leser et nøstet objekt, med samme filnavn i feilmeldingene. */
export function nestedFields(parent: Fields, value: unknown, where: string): Fields {
  return fieldsOf(value, parent.subject, where)
}

/** Henter en rå verdi og fører nøkkelen i regnskapet. */
export function raw(fields: Fields, key: string): unknown {
  fields.seen.add(key)
  return fields.record[key]
}

/**
 * Ingen ukjente felter slipper gjennom.
 *
 * `explanations` lar en leser gi en egen setning for en nøkkel den vet hvorfor
 * ikke hører hjemme. En generell «ukjente felter»-melding ville vært riktig,
 * men ikke sagt hvorfor akkurat den nøkkelen er en dårlig idé.
 */
export function rejectUnknown(
  fields: Fields,
  explanations: Readonly<Record<string, string>> = {},
): void {
  const unknown = Object.keys(fields.record)
    .filter((key) => !fields.seen.has(key))
    .sort()
  if (unknown.length === 0) {
    return
  }
  for (const key of unknown) {
    const explanation = explanations[key]
    if (explanation !== undefined) {
      fail(fields, key, explanation)
    }
  }
  fail(fields, null, `har ukjente felter: ${unknown.join(', ')}`)
}

export function asText(fields: Fields, key: string): string {
  const value = raw(fields, key)
  if (typeof value !== 'string' || value.trim().length === 0) {
    fail(fields, key, 'mangler eller er tom')
  }
  return value
}

export function asOptionalText(fields: Fields, key: string): string | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'string') {
    fail(fields, key, 'er ikke tekst')
  }
  return value.trim().length === 0 ? null : value
}

function inVocabulary(
  fields: Fields,
  key: string,
  vocabulary: readonly string[],
  value: string,
): string {
  if (!vocabulary.includes(value)) {
    fail(
      fields,
      key,
      `er ${JSON.stringify(value)}, som ikke er en kjent verdi. Gyldige verdier: ${vocabulary.join(', ')}`,
    )
  }
  return value
}

export function asVocabulary(fields: Fields, key: string, vocabulary: readonly string[]): string {
  return inVocabulary(fields, key, vocabulary, asText(fields, key))
}

export function asOptionalVocabulary(
  fields: Fields,
  key: string,
  vocabulary: readonly string[],
): string | null {
  const value = asOptionalText(fields, key)
  return value === null ? null : inVocabulary(fields, key, vocabulary, value)
}

export function asUuid(fields: Fields, key: string): Uuid {
  const value = asText(fields, key)
  if (!UUID_PATTERN.test(value)) {
    fail(fields, key, 'er ikke en uuid')
  }
  return value as Uuid
}

export function asOptionalUuid(fields: Fields, key: string): Uuid | null {
  const value = asOptionalText(fields, key)
  if (value === null) {
    return null
  }
  if (!UUID_PATTERN.test(value)) {
    fail(fields, key, 'er ikke en uuid')
  }
  return value as Uuid
}

export function asOptionalInteger(fields: Fields, key: string): number | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    fail(fields, key, 'er ikke et heltall')
  }
  return value
}

/**
 * Et tall bevares som tekst, ordrett slik filen skrev det.
 *
 * `1.50` og `1.5` er samme tall, men ikke samme oppgitte verdi, og en tur innom
 * `Number` ville stille endret det som skal kontrolleres mot kilden.
 */
export function asOptionalNumericText(fields: Fields, key: string): string | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value === 'number') {
    fail(
      fields,
      key,
      'er oppgitt som et tall. Tallverdier skal stå som tekst, slik at skrivemåten bevares ordrett',
    )
  }
  if (typeof value !== 'string' || value.trim().length === 0) {
    fail(fields, key, 'er ikke et tall som tekst')
  }
  return value
}

/** En liste med minst ett element, lest som objekter. */
export function asObjectList(fields: Fields, key: string): readonly unknown[] {
  const value = raw(fields, key)
  if (!Array.isArray(value) || value.length === 0) {
    fail(fields, key, 'mangler eller er tom')
  }
  return value
}

/** En liste som godt kan være tom, men som må være en liste. */
export function asOptionalObjectList(fields: Fields, key: string): readonly unknown[] {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return []
  }
  if (!Array.isArray(value)) {
    fail(fields, key, 'er ikke en liste')
  }
  return value
}

// ----------------------------------------------------------------------------
// Tidspunkter
//
// Både forslagets `drafted_at` og modellsvarets `answered_at` er påstander om
// når en modell leste en artikkel, og begge ender i proveniensen. De må derfor
// leses av den samme kontrollen — og den må være en *kalenderkontroll*, ikke
// bare et mønster.
//
// `Date.parse` er ikke nok alene. Node normaliserer et ISO-tidspunkt med en dag
// utenfor måneden: «2026-09-31T00:00:00Z» blir 1. oktober framfor å bli `NaN`.
// En dato som ikke finnes, ville da passert vinduskontrollen og blitt lagret
// ordrett som et tidspunkt ingen kan peke på i en kalender
// (ANTIDEP_CONSTITUTION.md §14).
// ----------------------------------------------------------------------------

const RFC3339 =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-](\d{2}):(\d{2}))$/

function isLeapYear(year: number): boolean {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0
}

const MONTH_LENGTHS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] as const

function daysInMonth(year: number, month: number): number {
  if (month === 2 && isLeapYear(year)) {
    return 29
  }
  return MONTH_LENGTHS[month - 1] ?? 0
}

/**
 * Ett tidspunkt på RFC 3339-form, med tidssone, og med en dato som finnes.
 *
 * Skuddsekunder (`:60`) godtas ikke. De er tillatt i RFC 3339, men ingen
 * modell oppgir et, og PostgreSQL ville uansett normalisert det bort — så et
 * avslag her er tydeligere enn en verdi som skifter mening senere.
 */
export function isCalendarTimestamp(value: string): boolean {
  const match = RFC3339.exec(value)
  if (match === null) {
    return false
  }
  const [, year, month, day, hour, minute, second, offsetHour, offsetMinute] = match
  const y = Number(year)
  const m = Number(month)
  if (m < 1 || m > 12 || Number(day) < 1 || Number(day) > daysInMonth(y, m)) {
    return false
  }
  if (Number(hour) > 23 || Number(minute) > 59 || Number(second) > 59) {
    return false
  }
  if (offsetHour !== undefined && (Number(offsetHour) > 23 || Number(offsetMinute) > 59)) {
    return false
  }
  // Siste ord til plattformen: en verdi kontrollene over slipper gjennom, men
  // som ikke lar seg lese som et øyeblikk, skal ikke bli en proveniensverdi.
  return !Number.isNaN(Date.parse(value))
}
