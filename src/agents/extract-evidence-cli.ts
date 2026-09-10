// ============================================================================
// Kjøreren for ekstraksjonsagenten
//
//   npm run agent:extract-evidence -- --proposal forslag.json --dry-run
//   npm run agent:extract-evidence -- --proposal forslag.json
//   npm run agent:extract-evidence -- --schema
//
// Forslaget er en JSON-fil med de strukturerte verdiene og én kildeforankring
// per semantisk felt (`extraction-proposal.ts`). Kjøringen henter
// representasjonen, krever at fingeravtrykket er den registrerte
// kildeversjonens, prøver hvert utdrag ordrett mot den, og registrerer
// ekstraksjonen gjennom `api.register_agent_extraction`.
//
// Miljøet leses av `agent-environment.ts`; hemmeligheten skal ligge i
// `.env.agent.local` (gitignorert) eller i miljøet der kjøreren faktisk kjører.
// Se `supabase/README.md`, avsnittet «Legitimasjon til agentidentiteten».
//
// `--dry-run` henter og kontrollerer uten å skrive en eneste rad — kjøringen
// registreres likevel, og lukkes som `aborted`, slik at også en tørrkjøring er
// sporbar (§74.31: en KI-operasjon uten proveniens er ikke en KI-operasjon
// Antidep kjenner).
//
// Filen importeres aldri av appen og havner derfor ikke i klientbunten.
// ============================================================================

import { readFile } from 'node:fs/promises'

import { createAgentClient, createEvidenceExtractionApi } from './agent-api.ts'
import { EVIDENCE_EXTRACTION_CREDENTIAL, readAgentConfig } from './agent-environment.ts'
import { redact } from './agent-credential.ts'
import { parseAssignmentJson } from './extraction-assignment.ts'
import { buildExtractionProposalSchema } from './extraction-proposal-schema.ts'
import { runEvidenceExtraction } from './extraction-run.ts'
import { readProposalFile } from './proposal-files.ts'

const USAGE = `Bruk:
  npm run agent:extract-evidence -- --proposal <fil> --assignment <fil> [valg]

Valg:
  --proposal <fil>       JSON-filen med ekstraksjonsforslaget. Påkrevd.
  --assignment <fil>     Oppdraget forslaget ble laget under. Påkrevd for et
                         forslag laget av en modell.
  --no-assignment-check  Registrer uten oppdraget. Bare for et forslag en
                         redaktør har skrevet selv, uten et oppdrag.
  --dry-run              Hent og kontroller, men registrer ingenting.
  --schema               Skriv ut JSON Schema-formen av forslaget, og avslutt.
  --help                 Vis denne teksten.`

interface Options {
  readonly proposalPath: string
  readonly assignmentPath: string | null
  readonly skipAssignmentCheck: boolean
  readonly dryRun: boolean
}

/**
 * Leser argumentene.
 *
 * Egen parser og ikke `cli-arguments.ts`: de to verifikatorene tar en kø og en
 * grense, mens dette leddet tar én fil. En felles parser for to ulike former
 * ville vært en parser med to moduser.
 */
export function parseExtractionArguments(argv: readonly string[]): Options | 'help' | 'schema' {
  let proposalPath: string | null = null
  let assignmentPath: string | null = null
  let skipAssignmentCheck = false
  let dryRun = false

  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    if (flag === '--help' || flag === '-h') {
      return 'help'
    }
    // Skjemaet kan skrives ut uten legitimasjon og uten database: det er
    // kontrakten, ikke en operasjon mot basen.
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
  return { proposalPath, assignmentPath, skipAssignmentCheck, dryRun }
}

/**
 * Hvorfor et modellskrevet forslag ikke registreres uten oppdraget sitt.
 *
 * Avgrensningen mot katalogen er den ene kontrollen den ordrette ikke kan
 * gjøre, og den ble gjort i modell-leddet — *før* forslaget ble overlevert fra
 * en økt som leste utrygt eksternt innhold. En registrering som stolte på filen
 * alene, ville tatt modellens ord for avgrensningen (EVIDENCE_PIPELINE.md §63).
 *
 * Et menneskeskrevet forslag har ikke noe oppdrag, og der er `--no-assignment-check`
 * det riktige svaret. Valget er kallerens, ikke modellens, og det føres i
 * kjøringens manifest.
 */
const ASSIGNMENT_REQUIRED =
  'Forslaget er erklært laget av en modell, og registreres derfor ikke uten oppdraget det ble ' +
  'laget under. Oppgi --assignment <fil> med den oppdragsfilen redaktøren eier.\n\n' +
  'Avgrensningen mot katalogen ble kontrollert i modell-leddet, før forslaget ble overlevert. ' +
  'Uten oppdraget her ville registreringen tatt modellens ord for hvilket virkestoff og hvilket ' +
  'endepunkt funnet gjelder.\n\n' +
  'Er forslaget skrevet av en redaktør uten et oppdrag, si det uttrykkelig med ' +
  '--no-assignment-check. Valget føres i kjøringens manifest.'

async function main(): Promise<number> {
  let options: Options
  try {
    const parsed = parseExtractionArguments(process.argv.slice(2))
    if (parsed === 'help') {
      console.log(USAGE)
      return 0
    }
    if (parsed === 'schema') {
      console.log(JSON.stringify(buildExtractionProposalSchema(), null, 2))
      return 0
    }
    options = parsed
  } catch (cause) {
    console.error(cause instanceof Error ? cause.message : String(cause))
    console.error(`\n${USAGE}`)
    return 1
  }

  // Filene leses før legitimasjonen. Et forslag som mangler oppdraget sitt, er en
  // feil kalleren kan rette der og da, og den skal ikke skjule seg bak en
  // melding om en manglende miljøvariabel — eller kreve legitimasjon for å bli
  // sagt i det hele tatt.
  let proposal
  let assignment
  try {
    proposal = (await readProposalFile(options.proposalPath)).proposal

    if (
      proposal.generatedBy.producer === 'model' &&
      options.assignmentPath === null &&
      !options.skipAssignmentCheck
    ) {
      console.error(ASSIGNMENT_REQUIRED)
      return 1
    }
    assignment =
      options.assignmentPath === null
        ? undefined
        : parseAssignmentJson(
            options.assignmentPath,
            await readFile(options.assignmentPath, 'utf8'),
          )
  } catch (cause) {
    console.error(cause instanceof Error ? cause.message : String(cause))
    return 1
  }

  const config = readAgentConfig(process.env, EVIDENCE_EXTRACTION_CREDENTIAL)
  const api = createEvidenceExtractionApi(
    createAgentClient({ url: config.url, publishableKey: config.publishableKey }),
    config.credential,
  )

  try {
    const report = await runEvidenceExtraction({
      api,
      proposal,
      ...(assignment === undefined ? {} : { assignment }),
      dryRun: options.dryRun,
      log: (line) => {
        console.log(line)
      },
    })

    console.log(
      `\nKjøring ${report.agentRunId} lukket som ${report.runStatus} ` +
        `(${report.decision})${report.reason === undefined ? '' : `: ${report.reason}`}`,
    )
    return report.decision === 'skipped' ? 1 : 0
  } catch (cause) {
    // Alt som skrives ut, går gjennom redact: en feilmelding fra PostgREST kan
    // i prinsippet gjengi det som ble sendt, og det som ble sendt inneholder
    // hemmeligheten.
    const message = cause instanceof Error ? cause.message : String(cause)
    console.error(redact(message, config.credential.secret))
    return 1
  }
}

process.exitCode = await main()
