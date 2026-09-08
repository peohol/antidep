// ============================================================================
// Kjøreren for claim-verifikatoren
//
//   npm run agent:verify-claims -- --dry-run
//   npm run agent:verify-claims -- --claim-revision <uuid>
//   npm run agent:verify-claims -- --limit 5
//
// Miljøet leses av `agent-environment.ts`. Legitimasjonen er claim-verifikatorens
// egen — `ANTIDEP_CLAIM_AGENT_IDENTITY_KEY` og `ANTIDEP_CLAIM_AGENT_SECRET` — og
// ikke ekstraksjonsverifikatorens: rollen er rettighetsgrensen, og de to leddene
// deler verken aktør, identitet eller hemmelighet (MVP_IMPLEMENTATION_PLAN.md
// §49). Se `supabase/README.md`, avsnittet «Legitimasjon til agentidentiteten».
//
// Standard er å registrere. `--dry-run` kontrollerer og rapporterer uten å skrive
// en eneste rad — kjøringen registreres likevel, og lukkes som `aborted`, slik at
// også en tørrkjøring er sporbar (§74.31).
//
// Filen importeres aldri av appen og havner derfor ikke i klientbunten.
// ============================================================================

import { createAgentClient, createClaimVerificationApi } from './agent-api.ts'
import { CLAIM_VERIFIER_CREDENTIAL, readAgentConfig } from './agent-environment.ts'
import { redact } from './agent-credential.ts'
import { parseVerifierArguments } from './cli-arguments.ts'
import { runClaimVerification } from './claim-verification-run.ts'
import { CLAIM_VERIFICATION_PREMISES } from './pipeline-version.ts'

const USAGE = `Bruk:
  npm run agent:verify-claims -- [valg]

Valg:
  --claim-revision <uuid>  Kontroller nøyaktig denne påstandsrevisjonen. Uten
                           valget tas hele arbeidskøen.
  --limit <n>              Ta høyst n revisjoner i denne kjøringen.
  --dry-run                Kontroller og rapporter, men registrer ingenting.
  --help                   Vis denne teksten.`

async function main(): Promise<number> {
  const options = parseVerifierArguments(process.argv.slice(2), {
    targetFlag: 'claim-revision',
    usage: USAGE,
  })
  const config = readAgentConfig(process.env, CLAIM_VERIFIER_CREDENTIAL)
  const api = createClaimVerificationApi(
    createAgentClient({ url: config.url, publishableKey: config.publishableKey }),
    config.credential,
  )

  try {
    const report = await runClaimVerification({
      api,
      premises: CLAIM_VERIFICATION_PREMISES,
      claimRevisionId: options.targetId,
      dryRun: options.dryRun,
      limit: options.limit,
      log: (line) => {
        console.log(line)
      },
    })

    const count = (decision: string) =>
      String(report.revisions.filter((revision) => revision.decision === decision).length)
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
