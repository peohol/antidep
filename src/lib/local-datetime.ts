// ============================================================================
// Et lokalt klokkeslett inn og ut av `<input type="datetime-local">`
//
// Feltet gir og tar «2026-09-07T09:15» uten tidssone. Databasen lagrer
// `timestamptz`, så en verdi uten sone ville blitt tolket i databasens sone og
// ikke i redaktørens — samme klokkeslett, en annen hendelse. De to
// oversettelsene ligger derfor her, ett sted, framfor i hver komponent som
// bruker et slikt felt.
//
// Nettleserens egen sone er den som gjelder: redaktøren skriver klokkeslettet
// hen faktisk hentet kilden på, der hen står.
// ============================================================================

/** «Nå», i den formen `datetime-local` forventer, i nettleserens egen sone. */
export function nowAsLocalInputValue(now: Date = new Date()): string {
  const pad = (value: number) => String(value).padStart(2, '0')
  return (
    `${String(now.getFullYear())}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}` +
    `T${pad(now.getHours())}:${pad(now.getMinutes())}`
  )
}

/**
 * Verdien fra et `datetime-local`-felt som et tidspunkt med sone.
 *
 * `null` betyr at feltet er tomt eller ikke lar seg lese som et tidspunkt —
 * ikke at tidspunktet er ukjent. Kalleren avgjør hva det skal bety.
 */
export function localInputValueToIso(localValue: string): string | null {
  if (localValue.trim().length === 0) {
    return null
  }
  const parsed = new Date(localValue)
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString()
}
