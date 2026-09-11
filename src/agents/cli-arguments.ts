// ============================================================================
// Argumentlistene kjørerne leser
//
// Parsingen ligger her framfor i hver CLI-fil av to grunner. Den ene er
// gjenbruk: to nesten like parsere er to steder å glemme en grense. Den andre er
// at CLI-filene selv kjører `main()` på toppnivå og derfor ikke kan importeres
// av en test — logikken som fortjener en test, må ligge et sted som kan
// importeres uten å starte en kjøring.
//
// Filen har bare typeimporter, og skal ikke få flere: den leses av kjørere på
// begge sider av grensen mellom modell-leddet og de leddene som har
// legitimasjon, og en verdiimport her ville vært en kant i begge grafene på én
// gang (`drafting-no-write-path.test.ts`).
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

import type { RegistrationMode } from './extraction-proposal.ts'

export interface VerifierCliOptions {
  /** Objektet kjøringen avgrenses til, eller `null` for hele arbeidskøen. */
  readonly targetId: string | null
  readonly dryRun: boolean
  readonly limit: number | null
  /**
   * Katalogene kjøreren ba om, slått opp på flaggnavnet uten `--`.
   *
   * Tom for en kjører som ikke oppgir `pathFlags`. Formen er en oppslagsbok og
   * ikke et felt per flagg fordi de to verifikatorene deler denne parseren, og
   * et felt her ville gitt claim-verifikatoren et valg den ikke kan gjøre noe
   * med — men som den da ville tatt imot uten å avvise.
   */
  readonly paths: Readonly<Record<string, string | null>>
}

export interface VerifierCliSpec {
  /** Flagget som avgrenser kjøringen, uten `--`, for eksempel `claim-revision`. */
  readonly targetFlag: string
  readonly usage: string
  /** Valg som tar en katalogsti, uten `--`. Alt annet avvises som ukjent. */
  readonly pathFlags?: readonly string[]
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
  const pathFlags = spec.pathFlags ?? []
  let targetId: string | null = null
  let dryRun = false
  let limit: number | null = null
  const paths: Record<string, string | null> = Object.fromEntries(
    pathFlags.map((flag) => [flag, null]),
  )

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const pathFlag = pathFlags.find((flag) => argument === `--${flag}`)
    if (pathFlag !== undefined) {
      const value = argv[index + 1]
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`--${pathFlag} krever en katalogsti.`)
      }
      paths[pathFlag] = value
      index += 1
    } else if (argument === '--dry-run') {
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

  return { targetId, dryRun, limit, paths }
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
  /** Oppdraget forslaget kontrolleres mot, eller `null` når modusen ikke har et. */
  readonly assignmentPath: string | null
  /** Arbeidsformen kalleren registrerer under. */
  readonly mode: RegistrationMode
  readonly dryRun: boolean
}

/** De tre valgene, og modusen hvert av dem betyr. */
const REGISTRATION_FLAGS: Readonly<Record<string, RegistrationMode>> = {
  '--assignment': 'with_assignment',
  '--model-proposal': 'unchecked_model',
  '--human-proposal': 'without_assignment',
}

function tooManyModes(chosen: readonly string[]): never {
  throw new Error(
    `Oppgi nøyaktig ett av ${Object.keys(REGISTRATION_FLAGS).join(', ')}. Du oppga ` +
      `${chosen.join(' og ')}.`,
  )
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
  const chosen: string[] = []
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
    if (flag === '--model-proposal' || flag === '--human-proposal') {
      chosen.push(flag)
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
        chosen.push(flag)
      }
      index += 1
      continue
    }
    throw new Error(`Ukjent valg: ${String(flag)}`)
  }

  if (proposalPath === null) {
    throw new Error('--proposal er påkrevd.')
  }
  if (chosen.length > 1) {
    tooManyModes(chosen)
  }
  const mode = chosen.length === 0 ? undefined : REGISTRATION_FLAGS[chosen[0] as string]
  if (mode === undefined) {
    throw new Error(
      'Oppgi hva slags forslag dette er:\n\n' +
        '  --assignment <fil>   et maskinutkast, med oppdraget det ble laget under\n' +
        '  --model-proposal     et maskinutkast uten oppdrag\n' +
        '  --human-proposal     en redaktørs eget arbeid\n\n' +
        'Valget er påkrevd for hver registrering, og det er kallerens. Det avgjør om ' +
        'avgrensningen mot katalogen kontrolleres, og om raden føres som KI-assistert eller ' +
        'manuell — og forslaget er utrygg inndata som ikke får avgjøre noen av delene.',
    )
  }
  return { proposalPath, assignmentPath, mode, dryRun }
}

// ----------------------------------------------------------------------------
// Re-ekstraksjonen
//
// Samme spørsmål, uten oppdraget: en kø av forslagsfiler har ingenting å
// kontrolleres mot, men hva slags arbeid de er, må fortsatt sies av kalleren.
// ----------------------------------------------------------------------------

export interface ReextractionCliOptions {
  readonly directory: string | null
  readonly proposalPaths: readonly string[]
  readonly mode: RegistrationMode
  readonly dryRun: boolean
}

export function parseReextractionArguments(
  argv: readonly string[],
): ReextractionCliOptions | 'help' {
  let directory: string | null = null
  const proposalPaths: string[] = []
  const chosen: string[] = []
  let dryRun = false

  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    if (flag === '--help' || flag === '-h') {
      return 'help'
    }
    if (flag === '--dry-run') {
      dryRun = true
      continue
    }
    if (flag === '--model-proposal' || flag === '--human-proposal') {
      chosen.push(flag)
      continue
    }
    if (flag === '--directory' || flag === '--proposal') {
      const value = argv[index + 1]
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`${flag} krever en sti.`)
      }
      if (flag === '--directory') {
        if (directory !== null) {
          throw new Error('--directory kan bare oppgis én gang.')
        }
        directory = value
      } else {
        proposalPaths.push(value)
      }
      index += 1
      continue
    }
    throw new Error(`Ukjent valg: ${String(flag)}`)
  }

  if (directory === null && proposalPaths.length === 0) {
    throw new Error('Oppgi enten --directory eller minst én --proposal.')
  }
  // De to sammen ville gjort rekkefølgen uklar, og rekkefølgen er en del av
  // sporet: hver kjøring i provenance.agent_runs skal kunne leses tilbake mot
  // filen den kom fra.
  if (directory !== null && proposalPaths.length > 0) {
    throw new Error('Oppgi enten --directory eller --proposal, ikke begge.')
  }
  if (chosen.length > 1) {
    tooManyModes(chosen)
  }
  const mode = chosen.length === 0 ? undefined : REGISTRATION_FLAGS[chosen[0] as string]
  // `with_assignment` kan ikke nås her: `--assignment` er ikke et valg denne
  // kjøreren tar imot, og en kø har ingen oppdrag å kontrolleres mot.
  if (mode === undefined) {
    throw new Error(
      'Oppgi hva slags forslag køen består av:\n\n' +
        '  --model-proposal   maskinutkast uten oppdrag\n' +
        '  --human-proposal   en redaktørs eget arbeid\n\n' +
        'Valget er påkrevd, og det gjelder hele køen. Re-ekstraksjonen har ingen oppdrag å ' +
        'kontrollere mot, men hva slags arbeid dette er, skal sies av kalleren — ikke av filen.',
    )
  }
  return { directory, proposalPaths, mode, dryRun }
}
