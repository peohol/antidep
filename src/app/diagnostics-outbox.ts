// ============================================================================
// Utboksen den rå årsaken venter i
//
// Sendingen til `/diagnostics` kan mislykkes, og den mislykkes helst når den
// betyr mest: er Antideps eget Data API nede, er også lagringen bak ruten
// utilgjengelig. En observasjon som bare overlever når det den beskriver ikke
// skjedde, er ingen observasjon.
//
// Observasjonen legges derfor her *før* den sendes, og blir liggende til
// leveringen er bekreftet. Neste gang flaten sender noe — eller bare blir
// åpnet igjen — går restansen med. Er utfallet av en Data API-svikt at årsakene
// kommer fram ti minutter senere framfor aldri, er det hele forskjellen.
//
// ----------------------------------------------------------------------------
// Hvorfor nettleserens eget lager, og hva det koster
//
// Det er det ene stedet en nettleser kan skrive uten å spørre noen. Teksten som
// ligger her, er den samme som allerede står i konsollen, den ligger i
// brukerens egen nettleser, og den slettes i det leveringen er bekreftet.
//
// Grensen er ærlig: lukker noen fanen og kommer aldri tilbake, er restansen
// borte. Men da er ingenting fra den økten gjenopprettelig uansett.
//
// ----------------------------------------------------------------------------
// Alt kan feile, og ingenting av det skal merkes
//
// `localStorage` kaster i privat modus, når kvoten er full, og når en flate er
// innrammet med blokkerte informasjonskapsler. Hver eneste lesing og skriving
// er derfor pakket inn: en utboks som ikke virker, skal ikke bli en ny feil på
// toppen av den som allerede er vist.
// ============================================================================

const KEY = 'antidep:diagnostikk-utboks'

/**
 * Hvor mange observasjoner utboksen holder på.
 *
 * Nok til å bære en kort utilgjengelighet, og lavt nok til at en flate som
 * svikter i en løkke ikke fyller lageret. Den eldste faller ut først: en ny
 * årsak sier mer om hva som skjer nå enn en gammel.
 */
export const MAX_PENDING = 20

/** Én observasjon slik den venter. Formen er konvoluttens, uten tokenen. */
export interface PendingDiagnostic {
  readonly eventId: string
  /**
   * Hvem observasjonen tilhørte da den oppsto.
   *
   * Uten den ville en restanse blitt sendt med den brukeren som tilfeldigvis er
   * innlogget når den endelig går — og på en delt maskin på et kontor ville en
   * annens observasjon blitt tilskrevet feil person. Restansen leveres derfor
   * bare når den samme brukeren er innlogget igjen.
   */
  readonly userId: string
  readonly area: string
  readonly kind: string
  readonly operation: string | null
  readonly code: string | null
  readonly httpStatus: number | null
  readonly transport: string
  readonly detail: string
}

function read(): PendingDiagnostic[] {
  try {
    const raw = globalThis.localStorage?.getItem(KEY)
    if (raw === null || raw === undefined) {
      return []
    }
    const parsed: unknown = JSON.parse(raw)
    return Array.isArray(parsed) ? (parsed as PendingDiagnostic[]) : []
  } catch {
    return []
  }
}

function write(entries: readonly PendingDiagnostic[]): void {
  try {
    globalThis.localStorage?.setItem(KEY, JSON.stringify(entries))
  } catch {
    // Ingen plass, eller ingen tilgang. Da er utboksen tom, og sendingen under
    // er det eneste forsøket. Det er fortsatt bedre enn å kaste her.
  }
}

/** Legger observasjonen til side før den sendes. */
export function remember(entry: PendingDiagnostic): void {
  const entries = read().filter((pending) => pending.eventId !== entry.eventId)
  entries.push(entry)
  write(entries.slice(-MAX_PENDING))
}

/**
 * Det som venter for én bruker, eldste først.
 *
 * Ingen andres. En restanse hører til den som så den, og skal aldri følge med
 * neste innlogging på den samme maskinen.
 */
export function pendingFor(userId: string): readonly PendingDiagnostic[] {
  return read().filter((entry) => entry.userId === userId)
}

/** Alt som venter, uansett hvem. Bare for prøver og for taket. */
export function pending(): readonly PendingDiagnostic[] {
  return read()
}

/** Tar observasjonen ut av utboksen. Kalles først når leveringen er bekreftet. */
export function forget(eventId: string): void {
  write(read().filter((entry) => entry.eventId !== eventId))
}

/** Bare for prøver: tøm utboksen. */
export function clearOutbox(): void {
  try {
    globalThis.localStorage?.removeItem(KEY)
  } catch {
    // Som over: en utboks som ikke virker, er ikke en feil å melde.
  }
}
