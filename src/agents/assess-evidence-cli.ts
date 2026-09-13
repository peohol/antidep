// ============================================================================
// Kjøreren for evidensvurderingen
//
//   npm run agent:assess-evidence -- --directory assessments --dry-run
//   npm run agent:assess-evidence -- --directory assessments
//   npm run agent:assess-evidence -- --proposal assessments/mirtazapin-vektendring.json
//
// Ett eller flere eksternt produserte vurderingsforslag kontrolleres på form og
// registreres gjennom `api.register_evidence_assessment`: én GRADE-vurdering per
// påstandsrevisjon, i én transaksjon per forslag.
//
// ----------------------------------------------------------------------------
// Hvor den står i kjeden
//
// Etter claim-verifikasjonen, ikke før. Databasen håndhever det: en revisjon
// uten en gjeldende, bekreftet kildestøtteverifikasjon som dekker nøyaktig det
// evidenssettet som ligger der nå, avvises med en setning som sier hva som
// mangler (migrasjon 005am, MVP_IMPLEMENTATION_PLAN.md §15).
//
// Den formulerer ingen påstand — det er `npm run agent:synthesise-claims`, med
// sin egen rolle og sin egen legitimasjon — og den kontrollerer ingen påstand.
// Den godkjenner og publiserer ingenting: vurderingen legger seg på revisjonen i
// /review, der en kvalifisert redaktør tar stilling til helheten (§12, §15).
//
// Miljøet leses av `agent-environment.ts`. Legitimasjonen er
// evidensvurderingsagentens egen — `ANTIDEP_ASSESSMENT_AGENT_IDENTITY_KEY` og
// `ANTIDEP_ASSESSMENT_AGENT_SECRET` — og ingen annens: rollen er
// rettighetsgrensen (MVP_IMPLEMENTATION_PLAN.md §49). Se `supabase/README.md`,
// avsnittet «Legitimasjon til agentidentiteten».
//
// Filen importeres aldri av appen og havner derfor ikke i klientbunten.
// ============================================================================

import { createAgentClient, createEvidenceAssessmentApi } from './agent-api.ts'
import { EVIDENCE_ASSESSMENT_CREDENTIAL, readAgentConfig } from './agent-environment.ts'
import { redact } from './agent-credential.ts'
import { parseDraftedProposalArguments, type DraftedProposalCliOptions } from './cli-arguments.ts'
import { EVIDENCE_ASSESSMENT_PREMISES } from './pipeline-version.ts'
import {
  runEvidenceAssessment,
  type LabelledAssessmentProposal,
} from './evidence-assessment-run.ts'
import { parseEvidenceAssessmentProposal } from './evidence-assessment-proposal.ts'
import { readDraftedProposalDirectory, readDraftedProposalFile } from './drafted-proposal-files.ts'

const USAGE = `Bruk:
  npm run agent:assess-evidence -- (--directory <katalog> | --proposal <fil>...) [valg]

Valg:
  --directory <katalog>  Alle .json-forslagene i katalogen, i navnerekkefølge.
  --proposal <fil>       Ett forslag. Kan gjentas.
  --dry-run              Kontroller formen, men registrer ingenting.
  --help                 Vis denne teksten.

Kjøringen registrerer forslag til evidensvurdering, og bare for revisjoner som
allerede er kontrollert av claim-verifikasjonen. Den faglige godkjenningen er et
menneskes (/review).`

async function main(): Promise<number> {
  let options: DraftedProposalCliOptions
  try {
    const parsed = parseDraftedProposalArguments(process.argv.slice(2))
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

  const config = readAgentConfig(process.env, EVIDENCE_ASSESSMENT_CREDENTIAL)
  const api = createEvidenceAssessmentApi(
    createAgentClient({ url: config.url, publishableKey: config.publishableKey }),
    config.credential,
  )

  try {
    const proposals: readonly LabelledAssessmentProposal[] =
      options.directory === null
        ? await Promise.all(
            options.proposalPaths.map((path) =>
              readDraftedProposalFile(path, parseEvidenceAssessmentProposal),
            ),
          )
        : await readDraftedProposalDirectory(
            options.directory,
            parseEvidenceAssessmentProposal,
            (directory) =>
              `Fant ingen vurderingsforslag i ${directory}. Et vurderingsforslag er en .json-fil med formen beskrevet i assessments/README.md.`,
          )

    const report = await runEvidenceAssessment({
      api,
      premises: EVIDENCE_ASSESSMENT_PREMISES,
      proposals,
      dryRun: options.dryRun,
      log: (line) => {
        console.log(line)
      },
    })

    console.log(
      `\nKjøring ${report.agentRunId} lukket som ${report.runStatus}. ` +
        `${String(report.registered)} evidensvurderinger registrert, ` +
        `${String(report.skipped)} avvist.`,
    )

    // Setningen under er en påstand om hva som gjenstår, og skal bare stå når
    // den er sann: en registrert vurdering er et forslag, ikke en godkjenning.
    if (report.registered > 0) {
      console.log(
        'Vurderingene er forslag. Den faglige vurderingen av hele revisjonen — påstanden, ' +
          'grunnlaget, kontrollen og graderingen — gjøres av en kvalifisert redaktør i /review.',
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
