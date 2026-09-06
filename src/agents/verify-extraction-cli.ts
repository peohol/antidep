// ============================================================================
// Kjøreren for ekstraksjonsverifikatoren
//
//   npm run agent:verify-extraction -- --dry-run
//   npm run agent:verify-extraction -- --evidence-item <uuid>
//   npm run agent:verify-extraction -- --limit 5
//
// Miljøet leses av `agent-environment.ts`; hemmeligheten skal ligge i
// `.env.agent.local` (gitignorert) eller i miljøet der kjøreren faktisk kjører.
// Se `supabase/README.md`, avsnittet «Legitimasjon til agentidentiteten».
//
// Standard er å registrere. `--dry-run` kontrollerer og rapporterer uten å
// skrive en eneste verifikasjonsrad — kjøringen registreres likevel, og lukkes
// som `aborted`, slik at også en tørrkjøring er sporbar (§74.31: en KI-operasjon
// uten proveniens er ikke en KI-operasjon Antidep kjenner).
//
// Filen importeres aldri av appen og havner derfor ikke i klientbunten.
// ============================================================================

import { createAgentClient, createExtractionVerificationApi } from './agent-api.ts'
import { readAgentConfig } from './agent-environment.ts'
import { redact } from './agent-credential.ts'
import { runExtractionVerification } from './extraction-verification-run.ts'
import { EXTRACTION_VERIFICATION_PREMISES } from './pipeline-version.ts'

interface CliOptions {
  readonly evidenceItemId: string | null
  readonly dryRun: boolean
  readonly limit: number | null
}

const USAGE = `Bruk:
  npm run agent:verify-extraction -- [valg]

Valg:
  --evidence-item <uuid>  Kontroller nøyaktig dette evidensfunnet. Uten valget
                          tas hele arbeidskøen.
  --limit <n>             Ta høyst n funn i denne kjøringen.
  --dry-run               Kontroller og rapporter, men registrer ingenting.
  --help                  Vis denne teksten.`

export function parseCliArguments(argv: readonly string[]): CliOptions {
  let evidenceItemId: string | null = null
  let dryRun = false
  let limit: number | null = null

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--dry-run') {
      dryRun = true
    } else if (argument === '--evidence-item') {
      const value = argv[index + 1]
      if (value === undefined || value.startsWith('--')) {
        throw new Error('--evidence-item krever en uuid.')
      }
      evidenceItemId = value
      index += 1
    } else if (argument === '--limit') {
      const value = Number(argv[index + 1])
      if (!Number.isInteger(value) || value < 1) {
        throw new Error('--limit krever et heltall større enn null.')
      }
      limit = value
      index += 1
    } else if (argument === '--help' || argument === '-h') {
      throw new Error(USAGE)
    } else {
      throw new Error(`Ukjent valg: ${String(argument)}\n\n${USAGE}`)
    }
  }

  return { evidenceItemId, dryRun, limit }
}

async function main(): Promise<number> {
  const options = parseCliArguments(process.argv.slice(2))
  const config = readAgentConfig(process.env)
  const api = createExtractionVerificationApi(
    createAgentClient({ url: config.url, publishableKey: config.publishableKey }),
    config.credential,
  )

  try {
    const report = await runExtractionVerification({
      api,
      premises: EXTRACTION_VERIFICATION_PREMISES,
      evidenceItemId: options.evidenceItemId,
      dryRun: options.dryRun,
      limit: options.limit,
      log: (line) => {
        console.log(line)
      },
    })

    const count = (decision: string) =>
      String(report.items.filter((item) => item.decision === decision).length)
    console.log(
      `\nKjøring ${report.agentRunId} lukket som ${report.runStatus}. ` +
        `${count('registered')} registrert, ${count('previewed')} kontrollert uten å ` +
        `registreres, ${count('skipped')} uten grunnlag å kontrollere mot.`,
    )
    return 0
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
