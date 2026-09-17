// ============================================================================
// Kjøreren for Antideps egne deterministiske kontroller
//
//   npm run ops:controls
//
// Teknisk drift, ikke en produktflate. Kommandoen kjøres planlagt av
// `.github/workflows/deterministic-controls.yml`, og ingen trenger å starte
// den. Den kan kjøres for hånd av Claude Code eller ChatGPT når noe skal
// feilsøkes — som `npm run ops:full-text`, og av samme grunn.
//
// ----------------------------------------------------------------------------
// To legitimasjoner, og de blir aldri én
//
// Ekstraksjonskontrollen og kildestøttekontrollen er to agentledd med hver sin
// aktør, identitet og hemmelighet. Kommandoen kjører begge, men hvert ledd
// autentiseres for seg og kan bare gjøre operasjonene i sin egen rolle
// (ANTIDEP_CONSTITUTION.md regel 3). Mangler legitimasjonen til det ene,
// kjøres det andre — et ledd uten legitimasjon er ikke en grunn til at det
// andre skal stå.
//
// Ingen modellnøkkel finnes her, og ingen trengs: kontrollene er deterministisk
// kode, ikke modellvurderinger.
//
// ----------------------------------------------------------------------------
// Kildeteksten hentes fra databasen, ikke fra en katalog
//
// Kontrollen leser artikkelen ordrett. På en planlagt kjøring finnes ingen
// dokumentkatalog, og det skal ikke finnes en: originalfilen ligger varig og
// privat i databasen. Kjøringen slår derfor opp den *registrerte
// representasjonen* — teksten kildeversjonens fingeravtrykk ble beregnet av — og
// regner fingeravtrykket ut på nytt selv før den bruker den
// (`src/agents/source-binding.ts`).
//
// Er `ANTIDEP_DOCUMENT_DIR` satt og filen ligger der, brukes originaldokumentet
// som før. Det er den sterkeste formen, fordi den i tillegg viser at teksten lar
// seg gjenskape av den registrerte oppskriften.
//
// ----------------------------------------------------------------------------
// Loggen er offentlig
//
// Den planlagte kjøringen logger i et offentlig repo. Kommandoen skriver derfor
// bare stabile driftssetninger og aldri en videreformidlet feiltekst: en
// avvisning fra databasen kan navngi en påstand eller et kildeutdrag, og en
// offentlig logg skal ikke bli et sted slikt samler seg (AGENTS.md).
// ============================================================================

import {
  createAgentClient,
  createClaimVerificationApi,
  createExtractionVerificationApi,
  CITATION_SUPPORT_VERIFICATION_ROLE,
  EXTRACTION_VERIFICATION_ROLE,
  type AgentClient,
} from '../agents/agent-api.ts'
import { redact, type AgentCredential } from '../agents/agent-credential.ts'
import {
  CLAIM_VERIFIER_CREDENTIAL,
  EXTRACTION_VERIFIER_CREDENTIAL,
  readAgentConfig,
  type AgentConfig,
  type AgentCredentialVariables,
} from '../agents/agent-environment.ts'
import { runClaimVerification } from '../agents/claim-verification-run.ts'
import { runExtractionVerification } from '../agents/extraction-verification-run.ts'
import { createPipelineJobApi, type ClaimedJob } from '../agents/pipeline-job.ts'
import {
  CLAIM_VERIFICATION_PREMISES,
  EXTRACTION_VERIFICATION_PREMISES,
} from '../agents/pipeline-version.ts'
import { documentsFromEnv } from '../agents/source-document.ts'
import type { Uuid } from '../types/api.ts'
import {
  describeControlReport,
  runControlWorker,
  type ControlOutcome,
  type ControlStep,
} from './control-worker.ts'

const USAGE = `Bruk:
  npm run ops:controls [-- valg]

Valg:
  --max <antall>     Hvor mange kontroller hvert ledd tar i én kjøring (standard 10).
  --lease <sekunder> Hvor lenge et uttak holdes (standard 900).
  --help             Vis denne teksten.

Miljø:
  ANTIDEP_SUPABASE_URL, ANTIDEP_SUPABASE_PUBLISHABLE_KEY
  ANTIDEP_AGENT_IDENTITY_KEY og ANTIDEP_AGENT_SECRET — ekstraksjonskontrollen.
  ANTIDEP_CLAIM_AGENT_IDENTITY_KEY og ANTIDEP_CLAIM_AGENT_SECRET — kildestøttekontrollen.
  ANTIDEP_DOCUMENT_DIR — valgfri. Er originaldokumentet der, brukes det; ellers
  slås den registrerte representasjonen opp i databasen.

Kommandoen er teknisk drift. Den hører til deployen og aldri til en brukerflate.`

interface CliOptions {
  readonly maxTasks: number
  readonly leaseSeconds: number
}

function positive(name: string, value: string): number {
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} må være et helt tall større enn null.`)
  }
  return parsed
}

export function parseControlArguments(argv: readonly string[]): CliOptions | 'help' {
  let maxTasks = 10
  let leaseSeconds = 900

  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    if (flag === '--help' || flag === '-h') {
      return 'help'
    }
    const value = argv[index + 1]
    if (value === undefined || value.startsWith('--')) {
      throw new Error(`${String(flag)} krever en verdi.`)
    }
    index += 1
    switch (flag) {
      case '--max':
        maxTasks = positive('--max', value)
        continue
      case '--lease':
        leaseSeconds = positive('--lease', value)
        continue
      default:
        throw new Error(`Ukjent valg: ${String(flag)}`)
    }
  }

  return { maxTasks, leaseSeconds }
}

/**
 * Leser legitimasjonen for ett ledd, eller svarer `null` når den ikke er satt.
 *
 * Et ledd uten legitimasjon skal ikke stoppe det andre: en halvt konfigurert
 * utrulling skal kjøre den halvdelen som faktisk er konfigurert, og si fra om
 * resten.
 */
function optionalConfig(variables: AgentCredentialVariables): AgentConfig | null {
  try {
    return readAgentConfig(process.env, variables)
  } catch {
    return null
  }
}

/** Uttaket fra køen, oversatt til det kontrollen trenger å vite. */
function subjectOf(job: ClaimedJob, key: string): Uuid {
  const value = job.inputManifest[key]
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`Uttaket sier ikke hvilken rad kontrollen gjelder (${key} mangler).`)
  }
  return value as Uuid
}

function extractionStep(client: AgentClient, credential: AgentCredential): ControlStep {
  const api = createExtractionVerificationApi(client, credential)
  return {
    agentRole: EXTRACTION_VERIFICATION_ROLE,
    label: 'Ekstraksjonskontrollen',
    jobs: createPipelineJobApi(client, credential),
    async execute(job): Promise<ControlOutcome> {
      const evidenceItemId = subjectOf(job, 'evidence_item_id')
      const report = await runExtractionVerification({
        api,
        premises: EXTRACTION_VERIFICATION_PREMISES,
        evidenceItemId,
        // Kjøringen bindes til nettopp dette uttaket, slik at utfallet ikke kan
        // meldes med en kjøring som tjente en annen jobb.
        job: { pipelineJobId: job.pipelineJobId, leaseToken: job.leaseToken },
        documents: documentsFromEnv(process.env),
        useRegisteredText: true,
      })
      const item = report.items.find((entry) => entry.evidenceItemId === evidenceItemId)
      return {
        agentRunId: report.agentRunId,
        registered: item?.decision === 'registered',
        reason:
          item?.reason ?? (item === undefined ? 'Funnet sto ikke i kontrollens grunnlag.' : null),
        outcome: item?.outcome ?? null,
      }
    },
  }
}

function claimStep(client: AgentClient, credential: AgentCredential): ControlStep {
  const api = createClaimVerificationApi(client, credential)
  return {
    agentRole: CITATION_SUPPORT_VERIFICATION_ROLE,
    label: 'Kildestøttekontrollen',
    jobs: createPipelineJobApi(client, credential),
    async execute(job): Promise<ControlOutcome> {
      const claimRevisionId = subjectOf(job, 'claim_revision_id')
      const report = await runClaimVerification({
        api,
        premises: CLAIM_VERIFICATION_PREMISES,
        claimRevisionId,
        job: { pipelineJobId: job.pipelineJobId, leaseToken: job.leaseToken },
        documents: documentsFromEnv(process.env),
        useRegisteredText: true,
      })
      const revision = report.revisions.find((entry) => entry.claimRevisionId === claimRevisionId)
      return {
        agentRunId: report.agentRunId,
        registered: revision?.decision === 'registered',
        reason:
          revision?.reason ??
          (revision === undefined ? 'Revisjonen sto ikke i kontrollens grunnlag.' : null),
        outcome: revision?.outcome ?? null,
      }
    },
  }
}

/**
 * Opprydningen etter en teknisk svikt, kjørt med kontrolleddets egen
 * legitimasjon.
 *
 * Veien tar ikke imot ett eneste felt fra kalleren: den leser hva databasens
 * egen tilstand tilsier og legger inn nøyaktig det triggerne ville lagt inn.
 */
function resumeWith(client: AgentClient, credential: AgentCredential) {
  return async (): Promise<{
    queued: number
    candidatesBuilt: number
    revisionReviews: number
  }> => {
    const { data, error } = await client.rpc('resume_chain_transitions', {
      p_identity_key: credential.identityKey,
      p_secret: credential.secret.reveal(),
    })
    if (error !== null) {
      throw new Error(`Kjedeovergangene kunne ikke tas opp igjen. Kode: ${error.code ?? 'ingen'}.`)
    }
    if (typeof data !== 'object' || data === null || Array.isArray(data)) {
      throw new Error('Svaret fra opprydningen har ikke den formen kommandoen kan lese.')
    }
    const queued = (data as { queued?: unknown }).queued
    const built = (data as { candidates_built?: unknown }).candidates_built
    const reviews = (data as { revision_reviews?: unknown }).revision_reviews
    return {
      queued: typeof queued === 'number' ? queued : 0,
      candidatesBuilt: typeof built === 'number' ? built : 0,
      revisionReviews: typeof reviews === 'number' ? reviews : 0,
    }
  }
}

async function main(): Promise<number> {
  let options: CliOptions
  try {
    const parsed = parseControlArguments(process.argv.slice(2))
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

  const extraction = optionalConfig(EXTRACTION_VERIFIER_CREDENTIAL)
  const claim = optionalConfig(CLAIM_VERIFIER_CREDENTIAL)
  const configured = extraction ?? claim
  if (configured === null) {
    console.error(
      'Ingen av kontrolleddene har legitimasjon i miljøet. Se .env.example og ' +
        'supabase/README.md for hvordan de settes uten at de havner i repoet.',
    )
    return 1
  }

  const client = createAgentClient({
    url: configured.url,
    publishableKey: configured.publishableKey,
  })

  const steps: ControlStep[] = []
  if (extraction !== null) {
    steps.push(extractionStep(client, extraction.credential))
  } else {
    console.log('Ekstraksjonskontrollen har ingen legitimasjon i dette miljøet, og står over.')
  }
  if (claim !== null) {
    steps.push(claimStep(client, claim.credential))
  } else {
    console.log('Kildestøttekontrollen har ingen legitimasjon i dette miljøet, og står over.')
  }

  try {
    const report = await runControlWorker({
      steps,
      resume: resumeWith(client, configured.credential),
      maxTasksPerStep: options.maxTasks,
      leaseSeconds: options.leaseSeconds,
      log: (line) => {
        console.log(line)
      },
    })
    console.log(describeControlReport(report))
    return 0
  } catch (cause) {
    // Alt som skrives ut, går gjennom redact: en feilmelding fra PostgREST kan
    // i prinsippet gjengi det som ble sendt, og det som ble sendt inneholder
    // hemmeligheten.
    const message = cause instanceof Error ? cause.message : String(cause)
    console.error(redact(message, configured.credential.secret))
    return 1
  }
}

process.exitCode = await main()
