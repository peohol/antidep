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
import { parseRegistrationArguments, type RegistrationCliOptions } from './cli-arguments.ts'
import { parseAssignmentJson } from './extraction-assignment.ts'
import { registrationModeProblem, type RegistrationMode } from './extraction-proposal.ts'
import { buildExtractionProposalSchema } from './extraction-proposal-schema.ts'
import { runEvidenceExtraction } from './extraction-run.ts'
import { readProposalFile } from './proposal-files.ts'

const USAGE = `Bruk:
  npm run agent:extract-evidence -- --proposal <fil> --assignment <fil> [valg]
  npm run agent:extract-evidence -- --proposal <fil> --no-assignment-check [valg]

Valg:
  --proposal <fil>       JSON-filen med ekstraksjonsforslaget. Påkrevd.
  --assignment <fil>     Oppdraget forslaget kontrolleres mot: kildebindingen og
                         hver katalogverdi.
  --no-assignment-check  Registrer uten den kontrollen. For et forslag som ikke
                         har noe oppdrag — et en redaktør har skrevet selv.
  --dry-run              Hent og kontroller, men registrer ingenting.
  --schema               Skriv ut JSON Schema-formen av forslaget, og avslutt.
  --help                 Vis denne teksten.

Nøyaktig ett av --assignment og --no-assignment-check er påkrevd. Valget er
kallerens, og føres i kjøringens manifest: forslaget er utrygg inndata og får
ikke avgjøre om det blir kontrollert.`

async function main(): Promise<number> {
  let options: RegistrationCliOptions
  try {
    const parsed = parseRegistrationArguments(process.argv.slice(2))
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
  let mode: RegistrationMode
  try {
    proposal = (await readProposalFile(options.proposalPath)).proposal
    // Hvorvidt oppdraget kontrolleres, er avgjort av argumentlisten — ikke av
    // noe felt i forslaget. Se `parseRegistrationArguments`.
    assignment =
      options.assignmentPath === null
        ? undefined
        : parseAssignmentJson(
            options.assignmentPath,
            await readFile(options.assignmentPath, 'utf8'),
          )

    // Modusen kontrolleres her, før legitimasjonen leses: den trenger ingenting
    // annet enn de to filene, og kalleren skal få vite at valget og forslaget
    // ikke stemmer, uten først å måtte ha legitimasjon på plass. Kjøringen
    // håndhever den samme regelen om igjen — der er den invarianten, her er den
    // en beskjed.
    mode = assignment === undefined ? 'without_assignment' : 'with_assignment'
    const problem = registrationModeProblem(mode, proposal.generatedBy.producer)
    if (problem !== null) {
      console.error(`Ingenting ble registrert: ${problem}.`)
      return 1
    }
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
      // Modusen er kallerens valg, og den er den tiltrodde halvdelen av «hvem
      // laget dette»: den avgjør hvilken `extraction_method` raden får, og
      // forslagets egen erklæring må stemme med den.
      mode,
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
