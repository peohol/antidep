// ============================================================================
// Kjøreren for re-ekstraksjonen
//
//   npm run agent:reextract-evidence -- --directory proposals --dry-run
//   npm run agent:reextract-evidence -- --directory proposals
//   npm run agent:reextract-evidence -- --proposal proposals/fava-2000.json
//
// Ett eller flere eksternt produserte forslag går gjennom hele den
// deterministiske kjeden: kilden hentes på nytt, fingeravtrykket må stemme,
// hvert utdrag må stå ordrett i representasjonen, funnet registreres gjennom
// `api.register_agent_extraction`, og den deterministiske ekstraksjonskontrollen
// kjøres på nettopp det funnet.
//
// ----------------------------------------------------------------------------
// De gamle radene røres ikke
//
// Et forankret funn kommer *ved siden av* det gamle, ikke i stedet for det.
// Ingen legacy-rad muteres, og ingen forankring legges til retroaktivt: ingen vet
// hvilke utdrag den gamle ekstraksjonen faktisk ble laget av, og en påstand om
// det ville vært oppdiktet proveniens (ANTIDEP_CONSTITUTION.md §8, §14).
//
// ----------------------------------------------------------------------------
// Idempotent
//
// Kjør den om igjen med de samme filene, og ingenting skrives:
// `evidence_items_content_hash_key` dekker hele radens faglige innhold, og fra
// migrasjon 003d også kildeforankringen. Databasen avviser dubletten, og
// kjøringen rapporterer det som `already_registered` og går videre.
//
// Et forslag der bare et utdrag, en kildepeker eller en begrunnelse er rettet,
// er derimot et *annet* evidensfunn: det registreres ved siden av det gamle og
// kontrolleres på nytt, mens det gamle står urørt uten å arve noe fra det nye.
//
// ----------------------------------------------------------------------------
// Hvor den stopper
//
// Den lenker ikke det nye funnet til en påstandsrevisjon. Om et funn støtter,
// motsier eller er indirekte relevant for en formulering, er en faglig
// vurdering — ikke en teknisk operasjon — og gjøres av en kvalifisert redaktør
// i adminflyten (ANTIDEP_CONSTITUTION.md §12, §15).
//
// Miljøet leses av `agent-environment.ts`. Kjøreren trenger legitimasjon for
// *begge* agentidentitetene, fordi ekstraksjon og kontroll er to roller og to
// operasjoner: `ANTIDEP_EXTRACTION_AGENT_*` for ekstraksjonen og
// `ANTIDEP_AGENT_*` for kontrollen. Se `supabase/README.md`, «Legitimasjon til
// agentidentiteten».
//
// Filen importeres aldri av appen og havner derfor ikke i klientbunten.
// ============================================================================

import {
  createAgentClient,
  createEvidenceExtractionApi,
  createExtractionVerificationApi,
} from './agent-api.ts'
import {
  EVIDENCE_EXTRACTION_CREDENTIAL,
  EXTRACTION_VERIFIER_CREDENTIAL,
  readAgentConfig,
} from './agent-environment.ts'
import { redact } from './agent-credential.ts'
import { parseReextractionArguments, type ReextractionCliOptions } from './cli-arguments.ts'
import { EXTRACTION_VERIFICATION_PREMISES } from './pipeline-version.ts'
import { readProposalDirectory, readProposalFile } from './proposal-files.ts'
import type { LabelledProposal } from './reextraction-run.ts'
import { runReextraction } from './reextraction-run.ts'
import { documentsFromEnv } from './source-document.ts'

const USAGE = `Bruk:
  npm run agent:reextract-evidence -- (--directory <katalog> | --proposal <fil>...) \
    (--model-proposal | --human-proposal) [valg]

Valg:
  --directory <katalog>  Alle .json-forslagene i katalogen, i navnerekkefølge.
  --proposal <fil>       Ett forslag. Kan gjentas.
  --model-proposal       Køen består av maskinutkast uten oppdrag.
  --human-proposal       Køen består av en redaktørs eget arbeid.
  --dry-run              Hent og kontroller, men skriv ingenting.
  --help                 Vis denne teksten.

Nøyaktig ett av --model-proposal og --human-proposal er påkrevd, og det gjelder
hele køen. Re-ekstraksjonen har ingen oppdrag å kontrollere mot, men hva slags
arbeid forslagene er, skal sies av kalleren — ikke av filene.

Kjøringen er idempotent: et forslag som allerede er registrert med nøyaktig det
samme innholdet, skriver ingenting.`

async function main(): Promise<number> {
  let options: ReextractionCliOptions
  try {
    const parsed = parseReextractionArguments(process.argv.slice(2))
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

  const extractionConfig = readAgentConfig(process.env, EVIDENCE_EXTRACTION_CREDENTIAL)
  const verificationConfig = readAgentConfig(process.env, EXTRACTION_VERIFIER_CREDENTIAL)
  const client = createAgentClient({
    url: extractionConfig.url,
    publishableKey: extractionConfig.publishableKey,
  })

  try {
    const proposals: readonly LabelledProposal[] =
      options.directory === null
        ? await Promise.all(options.proposalPaths.map((path) => readProposalFile(path)))
        : await readProposalDirectory(options.directory)

    const report = await runReextraction({
      documents: documentsFromEnv(process.env),
      extractionApi: createEvidenceExtractionApi(client, extractionConfig.credential),
      verificationApi: createExtractionVerificationApi(client, verificationConfig.credential),
      verificationPremises: EXTRACTION_VERIFICATION_PREMISES,
      proposals,
      // Kallerens tiltrodde påstand om hva slags arbeid køen er. Uten den
      // ville forslagsfilene selv avgjort om de ble ført som KI-assistert
      // eller manuell (`extraction-proposal.ts`).
      mode: options.mode,
      dryRun: options.dryRun,
      log: (line) => {
        console.log(line)
      },
    })

    console.log(
      `\n${String(report.registered)} nye forankrede evidensfunn, ` +
        `${String(report.alreadyRegistered)} allerede registrert, ` +
        `${String(report.skipped)} ikke registrert, ` +
        `${String(report.unverified)} uten maskinbevis.`,
    )

    // Setningen under er en påstand om at kjeden er komplett, og skal bare stå
    // når den er sann. Et funn uten registrert maskinbevis er ikke
    // deterministisk kontrollert, uansett hvor mange som er det
    // (ANTIDEP_CONSTITUTION.md §11).
    if (report.unverified > 0) {
      console.error(
        `\n${String(report.unverified)} funn står uten registrert maskinbevis. Kontrollen ` +
          'lot seg ikke gjennomføre — kilden svarte ikke, fingeravtrykket stemte ikke, eller ' +
          'registreringen ble avvist. Rett årsaken og kjør kommandoen om igjen; den skriver ' +
          'ingen ny rad, men fullfører kontrollen.',
      )
    } else if (report.registered > 0 || report.alreadyRegistered > 0) {
      console.log(
        'Funnene er registrert og deterministisk kontrollert. Å lenke dem til en ' +
          'påstandsrevisjon er en faglig vurdering og gjøres av en kvalifisert redaktør.',
      )
    }

    // Hver rad som står uten maskinbevis, sier hvorfor. En samletelling alene
    // ville sagt at noe mangler uten å si hva som må rettes.
    for (const result of report.results) {
      if (result.unverifiedReason !== undefined) {
        console.error(`\n${result.label}: ${result.unverifiedReason}`)
      }
    }

    return report.skipped > 0 || report.unverified > 0 ? 1 : 0
  } catch (cause) {
    // Alt som skrives ut, går gjennom redact: en feilmelding fra PostgREST kan
    // i prinsippet gjengi det som ble sendt, og det som ble sendt inneholder
    // hemmelighetene.
    const message = cause instanceof Error ? cause.message : String(cause)
    console.error(
      redact(
        redact(message, extractionConfig.credential.secret),
        verificationConfig.credential.secret,
      ),
    )
    return 1
  }
}

process.exitCode = await main()
