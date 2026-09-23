// ============================================================================
// Kjøreren for de maskinelt utførte søkene
//
//   npm run ops:discovery                    # kildeoppdagelsens egne søk
//   npm run ops:discovery -- --leg coverage  # dekningskontrollens motsøk
//
// Teknisk drift, ikke en produktflate. Kommandoen henter de søkerundene som
// står åpne for det leddet legitimasjonen gjelder, kjører søkene mot de
// navngitte offentlige plattformene, og registrerer dem gjennom den
// kontrollerte skriveveien.
//
// Ingen modellnøkkel finnes her, og ingen trengs: å kalle et søke-API og lese
// svaret er deterministisk kode. Den *faglige* kildeoppdagelsen — å vurdere
// treffene og velge kildene — er en ekstern KI-agent med sin egen identitet, og
// den går gjennom agentarbeidsflaten. De to veiene holdes fra hverandre i
// databasen, og det er hele poenget.
//
// ----------------------------------------------------------------------------
// Hvorfor kommandoen har to ledd
//
// Fordi dekningskontrollen skal ha sine EGNE motsøk (SOURCE_POLICY.md §6), og
// et motsøk registrert under generatorens identitet ville ikke vært et motsøk.
// De to leddene har hver sin legitimasjon, hver sin registreringstildeling og
// hver sin søkestrategi — og databasen utleder kontrollens uavhengighet av
// hvilken rolle kjøringen faktisk gikk under. Det er derfor `--leg` finnes, og
// derfor den planlagte kjøringen kjører begge.
// ============================================================================

import { createAgentClient } from '../agents/agent-api.ts'
import { readAgentConfig, type AgentCredentialVariables } from '../agents/agent-environment.ts'
import { guardedGet } from '../agents/guarded-http.ts'
import {
  describeDiscoveryReport,
  LEGS,
  runMonographDiscovery,
  type DiscoveryLeg,
} from './monograph-discovery.ts'
import { createDiscoveryApi } from './monograph-discovery-api.ts'

const USAGE = `Bruk:
  npm run ops:discovery [-- valg]

Valg:
  --leg <discovery|coverage>  Hvilket kildeledd søkene utføres for (standard discovery)
  --max-plans <n>             Hvor mange søkeplaner kjøringen tar (standard 5, høyst 25)
  --plan <referanse>          Bare de åpne rundene for én bestemt søkeplan
  --dry-run                   Vis hvilke runder som ville blitt søkt for, uten å søke
  --help                      Vis denne teksten

Miljø:
  ANTIDEP_SUPABASE_URL
  ANTIDEP_SUPABASE_PUBLISHABLE_KEY
  ANTIDEP_DISCOVERY_AGENT_IDENTITY_KEY / ANTIDEP_DISCOVERY_AGENT_SECRET   (--leg discovery)
  ANTIDEP_COVERAGE_AGENT_IDENTITY_KEY  / ANTIDEP_COVERAGE_AGENT_SECRET    (--leg coverage)`

/** Legitimasjonen kildeoppdagelsen kjører med. Eget par, som hvert annet ledd. */
export const DISCOVERY_CREDENTIAL: AgentCredentialVariables = {
  identityKey: 'ANTIDEP_DISCOVERY_AGENT_IDENTITY_KEY',
  secret: 'ANTIDEP_DISCOVERY_AGENT_SECRET',
}

/**
 * Og legitimasjonen dekningskontrollens motsøk kjører med.
 *
 * Eget par, og det er ikke ryddighet: identiteten autentiseres for *rollen*
 * sin, og et motsøk registrert under kildeoppdagelsens nøkkel ville blitt ført
 * som generatorens eget søk. Da ville kontrollens uavhengighet vært en
 * formulering framfor en rad (SOURCE_POLICY.md §6).
 */
export const COVERAGE_CREDENTIAL: AgentCredentialVariables = {
  identityKey: 'ANTIDEP_COVERAGE_AGENT_IDENTITY_KEY',
  secret: 'ANTIDEP_COVERAGE_AGENT_SECRET',
}

export const LEG_CREDENTIALS: Readonly<Record<DiscoveryLeg, AgentCredentialVariables>> = {
  discovery: DISCOVERY_CREDENTIAL,
  coverage: COVERAGE_CREDENTIAL,
}

interface Arguments {
  readonly leg: DiscoveryLeg
  readonly maxPlans: number
  readonly plan: string | null
  readonly dryRun: boolean
  readonly help: boolean
}

export function parseArguments(argv: readonly string[]): Arguments {
  let leg: DiscoveryLeg = 'discovery'
  let maxPlans = 5
  let plan: string | null = null
  let dryRun = false
  let help = false

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') {
      help = true
    } else if (argument === '--dry-run') {
      dryRun = true
    } else if (argument === '--leg') {
      const value = argv[index + 1] ?? ''
      if (value !== 'discovery' && value !== 'coverage') {
        throw new Error('--leg må være discovery eller coverage.')
      }
      leg = value
      index += 1
    } else if (argument === '--max-plans') {
      const value = Number.parseInt(argv[index + 1] ?? '', 10)
      if (!Number.isInteger(value) || value < 1 || value > 25) {
        throw new Error('--max-plans må være et tall mellom 1 og 25.')
      }
      maxPlans = value
      index += 1
    } else if (argument === '--plan') {
      const value = argv[index + 1] ?? ''
      if (!/^[0-9a-f]{32}$/.test(value)) {
        throw new Error('--plan må være en søkeplans referanse (32 heksadesimale tegn).')
      }
      plan = value
      index += 1
    } else {
      throw new Error(`Ukjent valg: ${argument}`)
    }
  }

  return { leg, maxPlans, plan, dryRun, help }
}

async function main(): Promise<void> {
  let args: Arguments
  try {
    args = parseArguments(process.argv.slice(2))
  } catch (error) {
    console.error(error instanceof Error ? error.message : 'Ugyldige argumenter.')
    console.error(USAGE)
    process.exitCode = 2
    return
  }

  if (args.help) {
    console.log(USAGE)
    return
  }

  const leg = LEGS[args.leg]
  const config = readAgentConfig(process.env, LEG_CREDENTIALS[args.leg])
  const client = createAgentClient(config)
  const identity = {
    p_identity_key: config.credential.identityKey,
    p_secret: config.credential.secret.reveal(),
  }

  const api = createDiscoveryApi(client, identity, args.leg, args.plan)

  if (args.dryRun) {
    const plans = await api.work()
    console.log(`Åpne søkeplaner for ${leg.label}: ${plans.length}`)
    for (const plan of plans.slice(0, args.maxPlans)) {
      console.log(
        `  ${plan.profileCode}  ${plan.planReference}  runder: ${String(plan.requests.length)}`,
      )
    }
    return
  }

  const report = await runMonographDiscovery(api, {
    maxPlans: args.maxPlans,
    fetcher: guardedGet,
  })
  console.log(`Ledd: ${leg.label}`)
  console.log(describeDiscoveryReport(report))
  if (report.problems.length > 0) {
    process.exitCode = 1
  }
}

await main()
