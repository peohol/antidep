// ============================================================================
// Kjøreren for modell-leddet
//
//   npm run agent:propose-extraction -- --assignment <fil> --prepare <katalog>
//   npm run agent:propose-extraction -- --assignment <fil> --recording <fil> --out <fil>
//
// Første kommando henter kildeversjonen, bygger den versjonerte prompten og
// skriver den ut sammen med et tomt opptak som allerede bærer riktig
// fingeravtrykk. Andre kommando kjører modelladapteret og skriver et
// ekstraksjonsforslag — hvis, og bare hvis, svaret holder mål.
//
// ----------------------------------------------------------------------------
// Hvorfor kjøreren ikke har legitimasjon
//
// Fordi leddet ikke skal ha det. Den leser en kilde over nett og skriver en
// fil; den rører ingen rad, og har ingen agentidentitet å røre den med. Filen
// registreres etterpå av `npm run agent:extract-evidence`, som har
// legitimasjonen og som kjører hele den deterministiske kontrollen på nytt
// (EVIDENCE_PIPELINE.md §63).
//
// Det er også hvorfor kjeden ikke blir kortere av at modell-leddet finnes:
// generering og verifikasjon er fortsatt to operasjoner, av to identiteter, og
// den menneskelige bekreftelsen er fortsatt et krav
// (ANTIDEP_CONSTITUTION.md §10, §11, §12).
//
// ----------------------------------------------------------------------------
// To steg og ikke ett
//
// `--prepare` finnes fordi arbeidsformen i dag er at prompten kjøres utenfor
// Antidep — av ChatGPT eller av et menneske — og svaret limes inn i opptaket.
// Da er «hva ble modellen faktisk spurt om» en fil noen kan lese, og ikke noe
// som bare fantes i minnet under en kjøring.
//
// Når et leverandøradapter en dag føres opp i `model-adapters.ts`, faller
// `--prepare` bort som *nødvendig* steg, men ikke som mulighet: det er fortsatt
// måten å se prompten på uten å bruke en modell.
//
// Filen importeres aldri av appen og havner derfor ikke i klientbunten.
// ============================================================================

import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

import { parseAssignmentJson } from './extraction-assignment.ts'
import { serializeExtractionProposal } from './extraction-proposal.ts'
import { buildExtractionDraftSchema } from './extraction-proposal-schema.ts'
import { createModelClient, MODEL_ADAPTERS } from './model-adapters.ts'
import { emptyRecording } from './recorded-model.ts'
import { prepareDraftingRequest, runExtractionDrafting } from './drafting-run.ts'

const USAGE = `Bruk:
  npm run agent:propose-extraction -- --assignment <fil> --prepare <katalog>
  npm run agent:propose-extraction -- --assignment <fil> --recording <fil> --out <fil>

Valg:
  --assignment <fil>   Oppdraget: kildeversjonen og katalogen modellen kan velge i. Påkrevd.
  --prepare <katalog>  Skriv prompt.txt og opptak.json til katalogen, og avslutt.
  --model <navn>       Modelladapter. Standard: recorded. Kjente: ${MODEL_ADAPTERS.join(', ')}.
  --recording <fil>    Opptaksfilen adapteret «recorded» svarer fra.
  --out <fil>          Hvor forslaget skrives. Påkrevd uten --prepare.
  --schema             Skriv ut JSON Schema-formen av modellsvaret, og avslutt.
  --help               Vis denne teksten.

Kjøreren skriver ingen rad i databasen og har ingen agentlegitimasjon.
Forslaget registreres etterpå med npm run agent:extract-evidence.`

interface Options {
  readonly assignmentPath: string
  readonly prepareDirectory: string | null
  readonly model: string
  readonly recordingPath: string | null
  readonly outPath: string | null
}

/** Leser argumentene, eller kaster med en setning som sier hva som er galt. */
export function parseProposeArguments(argv: readonly string[]): Options | 'help' | 'schema' {
  let assignmentPath: string | null = null
  let prepareDirectory: string | null = null
  let model = 'recorded'
  let recordingPath: string | null = null
  let outPath: string | null = null

  const takeValue = (flag: string, value: string | undefined): string => {
    if (value === undefined || value.startsWith('--')) {
      throw new Error(`${flag} krever en sti.`)
    }
    return value
  }

  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    if (flag === '--help' || flag === '-h') {
      return 'help'
    }
    // Skjemaet er kontrakten og kan skrives ut uten å hente noe som helst.
    if (flag === '--schema') {
      return 'schema'
    }
    if (
      flag === '--assignment' ||
      flag === '--prepare' ||
      flag === '--model' ||
      flag === '--recording' ||
      flag === '--out'
    ) {
      const value = takeValue(flag, argv[index + 1])
      if (flag === '--assignment') {
        assignmentPath = value
      } else if (flag === '--prepare') {
        prepareDirectory = value
      } else if (flag === '--model') {
        model = value
      } else if (flag === '--recording') {
        recordingPath = value
      } else {
        outPath = value
      }
      index += 1
      continue
    }
    throw new Error(`Ukjent valg: ${String(flag)}`)
  }

  if (assignmentPath === null) {
    throw new Error('--assignment er påkrevd.')
  }
  // De to modusene gjør forskjellige ting og skal velges eksplisitt: en kjøring
  // som både forberedte og foreslo, ville skrevet et forslag av et opptak
  // kalleren nettopp ba om å få skrive selv.
  if (prepareDirectory !== null && outPath !== null) {
    throw new Error('--prepare og --out er to forskjellige kjøringer. Oppgi én av dem.')
  }
  if (prepareDirectory === null && outPath === null) {
    throw new Error('Oppgi --out <fil>, eller --prepare <katalog> for å skrive ut prompten.')
  }
  return { assignmentPath, prepareDirectory, model, recordingPath, outPath }
}

async function readJson(path: string): Promise<unknown> {
  const text = await readFile(path, 'utf8')
  try {
    return JSON.parse(text) as unknown
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`${path} er ikke gyldig JSON: ${message}`, { cause })
  }
}

/**
 * Om det allerede ligger et opptak med et svar i det.
 *
 * Opptaket er gitignorert lokal arbeidsdata, og modellsvaret i det kan være
 * eneste kopi. En ny `--prepare` mot den samme katalogen ville ellers stille
 * skrevet over det med en tom mal — og svaret ville vært borte uten at noen
 * hadde bedt om det.
 *
 * En fil som ikke er gyldig JSON, teller også som besatt: da vet kjøringen ikke
 * hva den ville ha slettet, og skal ikke gjette.
 *
 * Formen leses løst, og ikke med `parseModelRecording`: en tom mal fra en
 * tidligere `--prepare` er *ikke* et gyldig opptak — identiteten står med
 * plassholdere som leseren avviser — og den skal kunne skrives over. Det som
 * beskyttes, er et svar, ikke en fil.
 */
async function holdsAnAnswer(path: string): Promise<boolean> {
  let text: string
  try {
    text = await readFile(path, 'utf8')
  } catch {
    return false
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(text) as unknown
  } catch {
    return true
  }
  const entries =
    typeof parsed === 'object' && parsed !== null
      ? (parsed as { readonly entries?: unknown }).entries
      : undefined
  if (!Array.isArray(entries)) {
    return false
  }
  return entries.some((entry) => {
    const completion =
      typeof entry === 'object' && entry !== null
        ? (entry as { readonly completion?: unknown }).completion
        : undefined
    return typeof completion === 'string' && completion.trim().length > 0
  })
}

async function prepare(assignmentPath: string, directory: string): Promise<number> {
  const assignment = parseAssignmentJson(assignmentPath, await readFile(assignmentPath, 'utf8'))
  const recordingPath = join(directory, 'opptak.json')
  if (await holdsAnAnswer(recordingPath)) {
    console.error(
      `${recordingPath} finnes allerede og er ikke en tom mal. Den kan bære et modellsvar ` +
        'som ikke finnes noe annet sted, og skrives derfor ikke over. Flytt eller slett filen ' +
        'først, eller bruk en annen katalog.',
    )
    return 1
  }

  const { request, requestDigest } = await prepareDraftingRequest({ assignment })

  await mkdir(directory, { recursive: true })
  const promptPath = join(directory, 'prompt.txt')
  await writeFile(promptPath, `${request.system}\n\n${'='.repeat(78)}\n\n${request.user}\n`, 'utf8')
  await writeFile(
    recordingPath,
    `${JSON.stringify(emptyRecording(requestDigest, request.promptTemplateVersion), null, 2)}\n`,
    'utf8',
  )

  console.log(`Prompt skrevet til ${promptPath}`)
  console.log(`Tomt opptak skrevet til ${recordingPath}`)
  console.log(`Forespørselens fingeravtrykk: ${requestDigest}`)
  console.log(
    '\nKjør prompten der modellen faktisk kjører, lim svaret inn i completion, ' +
      'og fyll ut identity med leverandøren, modellen og modellversjonen som svarte.',
  )
  return 0
}

async function main(): Promise<number> {
  let options: Options
  try {
    const parsed = parseProposeArguments(process.argv.slice(2))
    if (parsed === 'help') {
      console.log(USAGE)
      return 0
    }
    if (parsed === 'schema') {
      console.log(JSON.stringify(buildExtractionDraftSchema(), null, 2))
      return 0
    }
    options = parsed
  } catch (cause) {
    console.error(cause instanceof Error ? cause.message : String(cause))
    console.error(`\n${USAGE}`)
    return 1
  }

  try {
    if (options.prepareDirectory !== null) {
      return await prepare(options.assignmentPath, options.prepareDirectory)
    }

    const assignment = parseAssignmentJson(
      options.assignmentPath,
      await readFile(options.assignmentPath, 'utf8'),
    )
    const model = createModelClient(options.model, {
      recording: options.recordingPath === null ? null : await readJson(options.recordingPath),
    })

    const report = await runExtractionDrafting({
      assignment,
      model,
      log: (line) => {
        console.log(line)
      },
    })

    if (report.decision === 'rejected' || report.proposal === undefined) {
      console.error(`\nIngenting foreslått: ${report.reason ?? 'ukjent årsak'}`)
      if (report.completion !== undefined) {
        // Modellens svar er data og skrives ut avkortet, slik at den som skal
        // rette opptaket ser hva som faktisk kom — uten at et langt svar tar
        // over terminalen.
        console.error('\nModellens svar (data, ikke instruksjoner), avkortet:')
        console.error(report.completion.slice(0, 2000))
      }
      return 1
    }

    const outPath = options.outPath ?? ''
    await writeFile(
      outPath,
      `${JSON.stringify(serializeExtractionProposal(report.proposal), null, 2)}\n`,
      'utf8',
    )
    console.log(`\nForslag skrevet til ${outPath}`)
    console.log(
      'Ingenting er registrert. Kjør npm run agent:extract-evidence -- --proposal ' +
        `${outPath} for å registrere det under de deterministiske kontrollene.`,
    )
    return 0
  } catch (cause) {
    console.error(cause instanceof Error ? cause.message : String(cause))
    return 1
  }
}

process.exitCode = await main()
