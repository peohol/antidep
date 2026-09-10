// ============================================================================
// Argumentlistene kjørerne leser
//
// Parsingen ligger her framfor i hver CLI-fil av to grunner. Den ene er
// gjenbruk: to nesten like parsere er to steder å glemme en grense. Den andre er
// at CLI-filene selv kjører `main()` på toppnivå og derfor ikke kan importeres
// av en test — logikken som fortjener en test, må ligge et sted som kan
// importeres uten å starte en kjøring.
//
// Filen har ingen importer, og skal ikke få noen: den leses av kjørere på begge
// sider av grensen mellom modell-leddet og de leddene som har legitimasjon, og
// en import her ville vært en kant i begge grafene på én gang
// (`drafting-no-write-path.test.ts`).
//
// ----------------------------------------------------------------------------
// Verifikatorene
//
// Begge kjørerne tar de samme tre valgene, og bare målets navn skiller dem:
//
//   --<mål> <uuid>   kontroller nøyaktig dette objektet
//   --limit <n>      ta høyst n objekter i denne kjøringen
//   --dry-run        kontroller og rapporter, men registrer ingenting
// ============================================================================

export interface VerifierCliOptions {
  /** Objektet kjøringen avgrenses til, eller `null` for hele arbeidskøen. */
  readonly targetId: string | null
  readonly dryRun: boolean
  readonly limit: number | null
}

export interface VerifierCliSpec {
  /** Flagget som avgrenser kjøringen, uten `--`, for eksempel `claim-revision`. */
  readonly targetFlag: string
  readonly usage: string
}

/**
 * Leser argumentlisten, eller kaster med en setning som sier hva som er galt.
 *
 * Et ukjent valg avvises framfor å ignoreres: en skrivefeil i `--dry-run` ville
 * ellers blitt til en kjøring som registrerte rader kalleren ikke ba om.
 */
export function parseVerifierArguments(
  argv: readonly string[],
  spec: VerifierCliSpec,
): VerifierCliOptions {
  const target = `--${spec.targetFlag}`
  let targetId: string | null = null
  let dryRun = false
  let limit: number | null = null

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--dry-run') {
      dryRun = true
    } else if (argument === target) {
      const value = argv[index + 1]
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`${target} krever en uuid.`)
      }
      targetId = value
      index += 1
    } else if (argument === '--limit') {
      const value = Number(argv[index + 1])
      if (!Number.isInteger(value) || value < 1) {
        throw new Error('--limit krever et heltall større enn null.')
      }
      limit = value
      index += 1
    } else if (argument === '--help' || argument === '-h') {
      throw new Error(spec.usage)
    } else {
      throw new Error(`Ukjent valg: ${String(argument)}\n\n${spec.usage}`)
    }
  }

  return { targetId, dryRun, limit }
}

// ----------------------------------------------------------------------------
// Modell-leddet
//
// Ett oppdrag og ett steg. Kjøremappa er `null` når kalleren ikke oppga en, og
// utledes av kjøreren (`defaultRunDirectory`): utledningen hører til
// kjøremappa, ikke til argumentlisten, og en import derfra ville lagt hele
// modell-leddet inn i grafen til de to verifikatorene.
// ----------------------------------------------------------------------------

/** De tre stegene modell-leddet kjøres i. */
export type DraftStep = 'open' | 'close' | 'status'

export interface DraftCliOptions {
  readonly assignmentPath: string
  /** Kjøremappa kalleren oppga, eller `null` for den utledede. */
  readonly runDirectory: string | null
  readonly step: DraftStep
}

/**
 * Leser argumentlisten til modell-leddet, eller kaster med en setning som sier
 * hva som er galt.
 *
 * Nøyaktig ett steg: en kommando som både åpnet og lukket, ville lukket en
 * kjøring på et svar som ikke fantes ennå, og en som gjettet steget ut av
 * tilstanden i mappa, ville gjort utfallet avhengig av noe kalleren ikke oppga.
 */
export function parseDraftArguments(argv: readonly string[]): DraftCliOptions | 'help' {
  let assignmentPath: string | null = null
  let runDirectory: string | null = null
  const steps: DraftStep[] = []

  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    if (flag === '--help' || flag === '-h') {
      return 'help'
    }
    if (flag === '--open' || flag === '--close' || flag === '--status') {
      steps.push(flag.slice(2) as DraftStep)
      continue
    }
    if (flag === '--assignment' || flag === '--run') {
      const value = argv[index + 1]
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`${flag} krever en sti.`)
      }
      if (flag === '--assignment') {
        assignmentPath = value
      } else {
        runDirectory = value
      }
      index += 1
      continue
    }
    throw new Error(`Ukjent valg: ${String(flag)}`)
  }

  if (assignmentPath === null) {
    throw new Error('--assignment er påkrevd.')
  }
  if (steps.length === 0) {
    throw new Error('Oppgi ett av --open, --close eller --status.')
  }
  if (steps.length > 1) {
    throw new Error(
      `Oppgi ett steg om gangen. Du oppga ${steps.map((step) => `--${step}`).join(' og ')}.`,
    )
  }
  return { assignmentPath, runDirectory, step: steps[0] as DraftStep }
}

// ----------------------------------------------------------------------------
// Registreringen
//
// Ett forslag, og ett uttrykkelig valg om hvorvidt det kontrolleres mot
// oppdraget sitt.
//
// ----------------------------------------------------------------------------
// Hvorfor valget er påkrevd, og ikke utledet av forslaget
//
// Forslaget er utrygg inndata. Det har vært innom en økt som leste en artikkel
// Antidep ikke kontrollerer, og som har skall — filen kan være endret etter at
// kontrollen i modell-leddet kjørte.
//
// En sperre som leste `generated_by.producer` for å avgjøre om oppdraget var
// påkrevd, ville derfor latt *filen* bestemme om den skulle kontrolleres: en
// endret `producer` fra `model` til `human`, og katalogkontrollen var hoppet
// over. Det er den eneste feilen en slik sperre kan gjøre som gjør den verdiløs.
//
// Valget er derfor kallerens, alltid, og det er lukket: nøyaktig ett av de to.
// Fravær av kontroll er da en handling noen gjorde, ikke en tilstand som oppsto.
// ----------------------------------------------------------------------------

export interface RegistrationCliOptions {
  readonly proposalPath: string
  /** Oppdraget forslaget kontrolleres mot, eller `null` når kalleren valgte bort kontrollen. */
  readonly assignmentPath: string | null
  readonly dryRun: boolean
}

/**
 * Leser argumentlisten til registreringen, eller kaster med en setning som sier
 * hva som er galt.
 *
 * `'schema'` og `'help'` er egne utfall: begge kan besvares uten legitimasjon,
 * uten database og uten et forslag.
 */
export function parseRegistrationArguments(
  argv: readonly string[],
): RegistrationCliOptions | 'help' | 'schema' {
  let proposalPath: string | null = null
  let assignmentPath: string | null = null
  let skipAssignmentCheck = false
  let dryRun = false

  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    if (flag === '--help' || flag === '-h') {
      return 'help'
    }
    // Skjemaet er kontrakten og kan skrives ut uten en operasjon mot basen.
    if (flag === '--schema') {
      return 'schema'
    }
    if (flag === '--dry-run') {
      dryRun = true
      continue
    }
    if (flag === '--no-assignment-check') {
      skipAssignmentCheck = true
      continue
    }
    if (flag === '--proposal' || flag === '--assignment') {
      const value = argv[index + 1]
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`${flag} krever en filsti.`)
      }
      if (flag === '--proposal') {
        proposalPath = value
      } else {
        assignmentPath = value
      }
      index += 1
      continue
    }
    throw new Error(`Ukjent valg: ${String(flag)}`)
  }

  if (proposalPath === null) {
    throw new Error('--proposal er påkrevd.')
  }
  if (assignmentPath !== null && skipAssignmentCheck) {
    throw new Error(
      '--assignment og --no-assignment-check er to forskjellige valg. Oppgi ett av dem.',
    )
  }
  if (assignmentPath === null && !skipAssignmentCheck) {
    throw new Error(
      'Oppgi --assignment <fil> med oppdraget forslaget ble laget under, eller ' +
        '--no-assignment-check dersom forslaget ikke har noe oppdrag.\n\n' +
        'Valget er påkrevd for hver registrering, og det er kallerens. Avgrensningen mot ' +
        'katalogen — hvilket virkestoff og hvilket endepunkt funnet gjelder — er den ene ' +
        'kontrollen den ordrette ikke kan gjøre, og forslaget er utrygg inndata som ikke får ' +
        'avgjøre om den kjøres.',
    )
  }
  return { proposalPath, assignmentPath, dryRun }
}
