// ============================================================================
// Kjøreren for påstandsdannelsen
//
//   npm run agent:synthesise-claims -- --directory syntheses --dry-run
//   npm run agent:synthesise-claims -- --directory syntheses
//   npm run agent:synthesise-claims -- --proposal syntheses/mirtazapin-vektendring.json
//
// Ett eller flere eksternt produserte syntesforslag kontrolleres på form og
// registreres gjennom `api.register_claim_synthesis`: påstandsidentiteten (eller
// en ny revisjon av en som finnes), revisjonen, evidenslenkene og
// evidensvurderingen, i én transaksjon per forslag.
//
// ----------------------------------------------------------------------------
// Hvor den stopper, og hvorfor den stopper der
//
// Den kontrollerer ikke påstanden sin egen. Å prøve å falsifisere en formulering
// mot grunnlaget er et eget mandat med sin egen identitet og sin egen rolle —
// `npm run agent:verify-claims` — og en kjøring som gjorde begge deler, ville
// vært ett ledd der ANTIDEP_CONSTITUTION.md §10 og §11 krever to.
//
// Den godkjenner og publiserer ingenting. Revisjonen legger seg i /review, der
// en kvalifisert redaktør tar stilling til den (§12, §15).
//
// Miljøet leses av `agent-environment.ts`. Legitimasjonen er synteseagentens
// egen — `ANTIDEP_SYNTHESIS_AGENT_IDENTITY_KEY` og
// `ANTIDEP_SYNTHESIS_AGENT_SECRET` — og ingen annens: rollen er
// rettighetsgrensen (MVP_IMPLEMENTATION_PLAN.md §49). Se `supabase/README.md`,
// avsnittet «Legitimasjon til agentidentiteten».
//
// Filen importeres aldri av appen og havner derfor ikke i klientbunten.
// ============================================================================

import { createAgentClient, createClaimSynthesisApi } from './agent-api.ts'
import { CLAIM_SYNTHESIS_CREDENTIAL, readAgentConfig } from './agent-environment.ts'
import { redact } from './agent-credential.ts'
import { parseSynthesisArguments, type SynthesisCliOptions } from './cli-arguments.ts'
import { CLAIM_SYNTHESIS_PREMISES } from './pipeline-version.ts'
import { runClaimSynthesis, type LabelledSynthesisProposal } from './claim-synthesis-run.ts'
import { readSynthesisDirectory, readSynthesisFile } from './synthesis-files.ts'

const USAGE = `Bruk:
  npm run agent:synthesise-claims -- (--directory <katalog> | --proposal <fil>...) [valg]

Valg:
  --directory <katalog>  Alle .json-forslagene i katalogen, i navnerekkefølge.
  --proposal <fil>       Ett forslag. Kan gjentas.
  --dry-run              Kontroller formen, men registrer ingenting.
  --help                 Vis denne teksten.

Kjøringen registrerer forslag. Den kontrollerer dem ikke: claim-verifikasjonen
er et eget ledd med sin egen identitet (npm run agent:verify-claims), og den
faglige godkjenningen er et menneskes (/review).`

async function main(): Promise<number> {
  let options: SynthesisCliOptions
  try {
    const parsed = parseSynthesisArguments(process.argv.slice(2))
    if (parsed === 'help') {
      console.log(USAGE)
      return 0
    }
    options = parsed
  } catch (cause) {
    console.error(cause instanceof Error ? cause.message : String(cause))
    console.error(`\n${USAGE}`)
    return 1
  }

  const config = readAgentConfig(process.env, CLAIM_SYNTHESIS_CREDENTIAL)
  const api = createClaimSynthesisApi(
    createAgentClient({ url: config.url, publishableKey: config.publishableKey }),
    config.credential,
  )

  try {
    const proposals: readonly LabelledSynthesisProposal[] =
      options.directory === null
        ? await Promise.all(options.proposalPaths.map((path) => readSynthesisFile(path)))
        : await readSynthesisDirectory(options.directory)

    const report = await runClaimSynthesis({
      api,
      premises: CLAIM_SYNTHESIS_PREMISES,
      proposals,
      dryRun: options.dryRun,
      log: (line) => {
        console.log(line)
      },
    })

    console.log(
      `\nKjøring ${report.agentRunId} lukket som ${report.runStatus}. ` +
        `${String(report.registered)} påstandsrevisjoner registrert, ` +
        `${String(report.skipped)} avvist.`,
    )

    // Setningen under er en påstand om hva som gjenstår, og skal bare stå når
    // den er sann: en registrert revisjon er et forslag, ikke noe kontrollert.
    if (report.registered > 0) {
      console.log(
        'Revisjonene er forslag. Neste ledd er claim-verifikasjonen ' +
          '(npm run agent:verify-claims), som er en separat kontroll av en annen aktør, og ' +
          'deretter den faglige vurderingen i /review.',
      )
    }
    return report.skipped > 0 ? 1 : 0
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
