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
// borte. Men ruten skriver observasjonen i sin egen serverlogg i det den kommer
// fram, så utboksen er en utsettelse og ikke det eneste eksemplaret.
//
// ----------------------------------------------------------------------------
// Taket gjelder per avsender, ikke for lageret under ett
//
// Flere mennesker deler ofte den samme maskinen på et kontor, og de deler da
// også dette lageret. Et felles tak ville gjort at den som sist møtte en feil,
// skjøv ut observasjonene til den som møtte en før — uten at noen av dem kunne
// se det skje. Den ene ville kommet tilbake til en tom utboks.
//
// Hver avsender har derfor sitt eget tak. I tillegg finnes et samlet tak på
// lageret, fordi `localStorage` er en delt og liten ressurs: blir det for mye
// totalt, faller den eldste hos den som har flest, slik at ingen kan sulte ut
// noen annen ved å ha mange.
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
 * Hvor mange observasjoner utboksen holder for **én** avsender.
 *
 * Nok til å bære en kort utilgjengelighet, og lavt nok til at en flate som
 * svikter i en løkke ikke fyller lageret. Den eldste av avsenderens egne faller
 * ut først: en ny årsak sier mer om hva som skjer nå enn en gammel.
 */
export const MAX_PENDING = 20

/**
 * Hvor mange observasjoner lageret holder til sammen.
 *
 * `localStorage` deles med alt annet Antidep måtte legge der, og en maskin med
 * mange brukere skal ikke kunne fylle den med restanser alene.
 */
export const MAX_PENDING_TOTAL = 100

/** Én observasjon slik den venter. Formen er konvoluttens, uten tokenen. */
export interface PendingDiagnostic {
  readonly eventId: string
  /**
   * Hvem observasjonen tilhørte da den oppsto, og `null` når ingen var
   * innlogget.
   *
   * Uten den ville en restanse blitt sendt med den brukeren som tilfeldigvis er
   * innlogget når den endelig går — og på en delt maskin på et kontor ville en
   * annens observasjon blitt tilskrevet feil person. Restansen leveres derfor
   * bare når den samme brukeren er innlogget igjen.
   *
   * En anonym observasjon tilhører ingen og sendes som nettopp det: ruten
   * skriver den i serverloggen og aldri som en rad, så den kan ikke bli
   * tilskrevet noen senere heller.
   */
  readonly userId: string | null
  readonly area: string
  readonly kind: string
  readonly operation: string | null
  readonly code: string | null
  readonly httpStatus: number | null
  readonly transport: string
  readonly detail: string
}

/** Nøkkelen en avsender telles under. Den anonyme er én avsender, ikke ingen. */
function owner(entry: PendingDiagnostic): string {
  return entry.userId ?? ''
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

/**
 * Klipper til begge takene, uten at én avsender kan gå ut over en annen.
 *
 * Først holder hver avsender sitt eget tak. Deretter, dersom lageret under ett
 * er for stort, faller den eldste hos den som har flest — gjentatt til det er
 * plass. Rekkefølgen ellers er den observasjonene kom i.
 */
function withinLimits(entries: readonly PendingDiagnostic[]): PendingDiagnostic[] {
  const perOwner = new Map<string, PendingDiagnostic[]>()
  for (const entry of entries) {
    const key = owner(entry)
    const mine = perOwner.get(key) ?? []
    mine.push(entry)
    perOwner.set(key, mine)
  }
  for (const [key, mine] of perOwner) {
    perOwner.set(key, mine.slice(-MAX_PENDING))
  }

  let total = [...perOwner.values()].reduce((sum, mine) => sum + mine.length, 0)
  while (total > MAX_PENDING_TOTAL) {
    let largest: PendingDiagnostic[] | undefined
    for (const mine of perOwner.values()) {
      if (largest === undefined || mine.length > largest.length) {
        largest = mine
      }
    }
    if (largest === undefined || largest.length === 0) {
      break
    }
    largest.shift()
    total -= 1
  }

  const kept = new Set<string>()
  for (const mine of perOwner.values()) {
    for (const entry of mine) {
      kept.add(entry.eventId)
    }
  }
  return entries.filter((entry) => kept.has(entry.eventId))
}

/** Legger observasjonen til side før den sendes. */
export function remember(entry: PendingDiagnostic): void {
  const entries = read().filter((pending) => pending.eventId !== entry.eventId)
  entries.push(entry)
  write(withinLimits(entries))
}

/**
 * Det som venter for én avsender, eldste først. `null` gir de anonyme.
 *
 * Ingen andres. En restanse hører til den som så den, og skal aldri følge med
 * neste innlogging på den samme maskinen.
 */
export function pendingFor(userId: string | null): readonly PendingDiagnostic[] {
  return read().filter((entry) => (entry.userId ?? null) === userId)
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
