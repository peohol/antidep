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
// `evidence_items_content_hash_key` dekker hele radens faglige innhold, og
// databasen avviser dubletten. Kjøringen rapporterer det som
// `already_registered` og går videre.
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
import {
  EVIDENCE_EXTRACTION_PREMISES,
  EXTRACTION_VERIFICATION_PREMISES,
} from './pipeline-version.ts'
import { readProposalDirectory, readProposalFile } from './proposal-files.ts'
import type { LabelledProposal } from './reextraction-run.ts'
import { runReextraction } from './reextraction-run.ts'

const USAGE = `Bruk:
  npm run agent:reextract-evidence -- (--directory <katalog> | --proposal <fil>...) [valg]

Valg:
  --directory <katalog>  Alle .json-forslagene i katalogen, i navnerekkefølge.
  --proposal <fil>       Ett forslag. Kan gjentas.
  --dry-run              Hent og kontroller, men skriv ingenting.
  --help                 Vis denne teksten.

Kjøringen er idempotent: et forslag som allerede er registrert med nøyaktig det
samme innholdet, skriver ingenting.`

interface Options {
  readonly directory: string | null
  readonly proposalPaths: readonly string[]
  readonly dryRun: boolean
}

export function parseReextractionArguments(argv: readonly string[]): Options | 'help' {
  let directory: string | null = null
  const proposalPaths: string[] = []
  let dryRun = false

  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    if (flag === '--help' || flag === '-h') {
      return 'help'
    }
    if (flag === '--dry-run') {
      dryRun = true
      continue
    }
    if (flag === '--directory' || flag === '--proposal') {
      const value = argv[index + 1]
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`${flag} krever en sti.`)
      }
      if (flag === '--directory') {
        if (directory !== null) {
          throw new Error('--directory kan bare oppgis én gang.')
        }
        directory = value
      } else {
        proposalPaths.push(value)
      }
      index += 1
      continue
    }
    throw new Error(`Ukjent valg: ${String(flag)}`)
  }

  if (directory === null && proposalPaths.length === 0) {
    throw new Error('Oppgi enten --directory eller minst én --proposal.')
  }
  // De to sammen ville gjort rekkefølgen uklar, og rekkefølgen er en del av
  // sporet: hver kjøring i provenance.agent_runs skal kunne leses tilbake mot
  // filen den kom fra.
  if (directory !== null && proposalPaths.length > 0) {
    throw new Error('Oppgi enten --directory eller --proposal, ikke begge.')
  }
  return { directory, proposalPaths, dryRun }
}

async function main(): Promise<number> {
  let options: Options
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
      extractionApi: createEvidenceExtractionApi(client, extractionConfig.credential),
      verificationApi: createExtractionVerificationApi(client, verificationConfig.credential),
      extractionPremises: EVIDENCE_EXTRACTION_PREMISES,
      verificationPremises: EXTRACTION_VERIFICATION_PREMISES,
      proposals,
      dryRun: options.dryRun,
      log: (line) => {
        console.log(line)
      },
    })

    console.log(
      `\n${String(report.registered)} nye forankrede evidensfunn, ` +
        `${String(report.alreadyRegistered)} allerede registrert, ` +
        `${String(report.skipped)} ikke registrert.`,
    )
    if (report.registered > 0) {
      console.log(
        'De nye funnene er registrert og deterministisk kontrollert. Å lenke dem til en ' +
          'påstandsrevisjon er en faglig vurdering og gjøres av en kvalifisert redaktør.',
      )
    }
    return report.skipped > 0 ? 1 : 0
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
