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

import { createAgentClient, createEvidenceExtractionApi } from './agent-api.ts'
import { EVIDENCE_EXTRACTION_CREDENTIAL, readAgentConfig } from './agent-environment.ts'
import { redact } from './agent-credential.ts'
import { buildExtractionProposalSchema } from './extraction-proposal-schema.ts'
import { runEvidenceExtraction } from './extraction-run.ts'
import { readProposalFile } from './proposal-files.ts'

const USAGE = `Bruk:
  npm run agent:extract-evidence -- --proposal <fil> [valg]

Valg:
  --proposal <fil>  JSON-filen med ekstraksjonsforslaget. Påkrevd.
  --dry-run         Hent og kontroller, men registrer ingenting.
  --schema          Skriv ut JSON Schema-formen av forslaget, og avslutt.
  --help            Vis denne teksten.`

interface Options {
  readonly proposalPath: string
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
    if (flag === '--proposal') {
      const value = argv[index + 1]
      if (value === undefined || value.startsWith('--')) {
        throw new Error('--proposal krever en filsti.')
      }
      proposalPath = value
      index += 1
      continue
    }
    throw new Error(`Ukjent valg: ${String(flag)}`)
  }

  if (proposalPath === null) {
    throw new Error('--proposal er påkrevd.')
  }
  return { proposalPath, dryRun }
}

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

  const config = readAgentConfig(process.env, EVIDENCE_EXTRACTION_CREDENTIAL)
  const api = createEvidenceExtractionApi(
    createAgentClient({ url: config.url, publishableKey: config.publishableKey }),
    config.credential,
  )

  try {
    const { proposal } = await readProposalFile(options.proposalPath)
    const report = await runEvidenceExtraction({
      api,
      proposal,
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
