// ============================================================================
// Kjøreren for ekstraksjonsverifikatoren
//
//   npm run agent:verify-extraction -- --dry-run
//   npm run agent:verify-extraction -- --evidence-item <uuid>
//   npm run agent:verify-extraction -- --limit 5
//   npm run agent:verify-extraction -- --absence-prompts <katalog>
//   npm run agent:verify-extraction -- --absence-reviews <katalog>
//
// De to siste er den kildeomfattende fraværskontrollen, som går i to trinn:
// første kjøring legger igjen ett spørsmål per funn som fører et globalt
// fravær, en aktør uten legitimasjon svarer i filene, og andre kjøring leser
// svarene og lar dem avgjøre om `source_wide_absence` kan føres opp
// (`absence-review-job.ts`). Uten et svar står halvdelen åpen, og funnet kommer
// ut som `uncertain` — et søk som ikke fant noe, er ikke et bevis for et fravær.
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
import { parseVerifierArguments } from './cli-arguments.ts'
import { runExtractionVerification } from './extraction-verification-run.ts'
import { documentsFromEnv } from './source-document.ts'
import { EXTRACTION_VERIFICATION_PREMISES } from './pipeline-version.ts'

const USAGE = `Bruk:
  npm run agent:verify-extraction -- [valg]

Valg:
  --evidence-item <uuid>  Kontroller nøyaktig dette evidensfunnet. Uten valget
                          tas hele arbeidskøen.
  --limit <n>             Ta høyst n funn i denne kjøringen.
  --dry-run               Kontroller og rapporter, men registrer ingenting.
  --absence-prompts <kat> Legg igjen ett spørsmål per funn som fører et globalt
                          fravær, og registrer ingenting. Aktøren som svarer,
                          leser prompt.txt og skriver i svar.json.
  --absence-reviews <kat> Les svarene fra den katalogen. Uten dette kan ingen
                          kildeomfattende fraværspåstand bli kontrollert.
  --help                  Vis denne teksten.`

async function main(): Promise<number> {
  const options = parseVerifierArguments(process.argv.slice(2), {
    targetFlag: 'evidence-item',
    usage: USAGE,
    pathFlags: ['absence-prompts', 'absence-reviews'],
  })
  const config = readAgentConfig(process.env)
  const api = createExtractionVerificationApi(
    createAgentClient({ url: config.url, publishableKey: config.publishableKey }),
    config.credential,
  )

  try {
    const report = await runExtractionVerification({
      api,
      // Dokumentlageret: en kildeversjon utledet av en PDF kontrolleres mot
      // originaldokumentet, aldri mot adressen (`source-binding.ts`).
      documents: documentsFromEnv(process.env),
      premises: EXTRACTION_VERIFICATION_PREMISES,
      evidenceItemId: options.targetId,
      dryRun: options.dryRun,
      limit: options.limit,
      absencePrompts: options.paths['absence-prompts'] ?? null,
      absenceReviews: options.paths['absence-reviews'] ?? null,
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
