// ============================================================================
// Agentplattformen som et driftssteg
//
//   npm run ops:agents -- work
//   npm run ops:agents -- assign-model --role evidence_extraction \
//     --provider openai --model gpt-5 --reason "Tildelt ved oppsett."
//   npm run ops:agents -- runners
//   npm run ops:agents -- register-runner --key ekstraksjon-01 \
//     --name "Ekstraksjonsagent" --role evidence_extraction \
//     --platform-ref "workspace-agent/ekstraksjon" --disclosure not_exposed
//   npm run ops:agents -- pair --key ekstraksjon-01
//   npm run ops:agents -- revoke --key ekstraksjon-01 --reason "Byttet konfigurasjon."
//   npm run ops:agents -- export-task --job <id> --out oppgave.md
//   npm run ops:agents -- import-answer --job <id> --answer svar.json
//
// Teknisk drift, og aldri en produktflate. Dette er handlingene som til og med
// PR #96 lå i kliniker-UI på `/agentarbeid`: å velge KI-tjeneste for et
// agentledd, registrere en kjører, hente en engangskode, laste ned en oppgave
// og laste opp et svar. Ingen av dem er klinisk eller redaksjonelt arbeid
// (issue #99).
//
// ----------------------------------------------------------------------------
// Sikkerhetsgrensene er de samme
//
// Dette er de samme `api`-funksjonene flaten kalte. Tildelingen er fortsatt en
// attestert avgjørelse tatt før oppgaven hentes ut, den inngår fortsatt i
// oppgavens avtrykk, og ingen modell attesterer sin egen identitet
// (ANTIDEP_CONSTITUTION.md regel 3).
//
// ----------------------------------------------------------------------------
// Oppgavefilen er privat
//
// `export-task` skriver hele den kontrollerte kildeteksten til en fil. Den skal
// aldri commites, legges i en issue eller havne i en logg; `verify-repo.sh`
// fanger et forsøk. Filen går rett fra terminalen og inn i KI-tjenesten.
// ============================================================================

import { readFile, writeFile } from 'node:fs/promises'

import { createClient } from '@supabase/supabase-js'

import type { Database } from '../types/database.ts'
import { agentTaskFileName, renderAgentTaskFile } from '../agents/agent-task-file.ts'
import {
  assignRoleModel,
  describeWorkItem,
  importAnswer,
  issuePairingCode,
  listRunners,
  listWork,
  readTask,
  revokeRunner,
  type AgentPlatformApi,
  type RoleModelChoice,
  type RunnerRegistration,
} from './agent-platform.ts'

const USAGE = `Bruk:
  npm run ops:agents -- <kommando> [valg]

Kommandoer:
  work                         Vis agentoppgavene som venter.
  assign-model                 Tildel KI-tjeneste til ett agentledd.
    --role <ledd>              evidence_extraction, claim_synthesis, evidence_assessment
    --provider <navn>          Leverandøren, for eksempel openai eller anthropic.
    --model <navn>             Modellen slik tjenesten navngir den.
    --model-version <v>        Bare når tjenesten faktisk viser en eksakt versjon.
    --reason <tekst>           Hvorfor leddet tildeles denne tjenesten.
    --replaces-reason <tekst>  Påkrevd når leddet allerede har en tjeneste.
  runners                      Vis de registrerte autonome kjørerne.
  register-runner              Registrer én autonom kjører.
    --key <nøkkel>             Kort, stabil nøkkel for tilkoblingen.
    --name <navn>              Navnet mennesker ser.
    --role <ledd>              Agentleddet kjøreren utfører.
    --platform-ref <tekst>     Plattformens egen referanse til agenten.
    --disclosure <verdi>       platform_pinned eller not_exposed.
    --reason <tekst>           Hvorfor kjøreren registreres.
  pair --key <nøkkel>          Hent engangskoden tilkoblingen settes opp med.
  revoke --key <nøkkel> --reason <tekst>
  export-task --job <id> [--out <fil>]
  import-answer --job <id> --answer <fil>

Miljø:
  ANTIDEP_SUPABASE_URL, ANTIDEP_SUPABASE_PUBLISHABLE_KEY
  ANTIDEP_EDITOR_EMAIL og ANTIDEP_EDITOR_PASSWORD, eller ANTIDEP_EDITOR_ACCESS_TOKEN.

Kommandoen er teknisk drift. Den hører til deployen og aldri til en brukerflate.`

export interface ParsedCommand {
  readonly command: string
  readonly options: ReadonlyMap<string, string>
}

export function parseAgentArguments(argv: readonly string[]): ParsedCommand | 'help' {
  const [command, ...rest] = argv
  if (command === undefined || command === '--help' || command === '-h') {
    return 'help'
  }
  const options = new Map<string, string>()
  for (let index = 0; index < rest.length; index += 1) {
    const flag = rest[index]
    if (flag === '--help' || flag === '-h') {
      return 'help'
    }
    if (flag === undefined || !flag.startsWith('--')) {
      throw new Error(`Ukjent argument: ${String(flag)}`)
    }
    const value = rest[index + 1]
    if (value === undefined || value.startsWith('--')) {
      throw new Error(`${flag} krever en verdi.`)
    }
    options.set(flag, value)
    index += 1
  }
  return { command, options }
}

function need(options: ReadonlyMap<string, string>, flag: string): string {
  const value = options.get(flag)?.trim()
  if (value === undefined || value.length === 0) {
    throw new Error(`${flag} er påkrevd for denne kommandoen.`)
  }
  return value
}

function required(name: string): string {
  const value = process.env[name]?.trim()
  if (value === undefined || value.length === 0) {
    throw new Error(
      `Miljøvariabelen ${name} mangler. Se .env.example og supabase/README.md for hvordan ` +
        'redaktørens legitimasjon settes uten at den havner i repoet.',
    )
  }
  return value
}

async function editorClient(): Promise<ReturnType<typeof createClient<Database, 'api'>>> {
  const url = required('ANTIDEP_SUPABASE_URL')
  const key = required('ANTIDEP_SUPABASE_PUBLISHABLE_KEY')
  const token = process.env['ANTIDEP_EDITOR_ACCESS_TOKEN']?.trim()

  if (token !== undefined && token.length > 0) {
    return createClient<Database, 'api'>(url, key, {
      db: { schema: 'api' },
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    })
  }

  const client = createClient<Database, 'api'>(url, key, {
    db: { schema: 'api' },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { error } = await client.auth.signInWithPassword({
    email: required('ANTIDEP_EDITOR_EMAIL'),
    password: required('ANTIDEP_EDITOR_PASSWORD'),
  })
  if (error !== null) {
    throw new Error(`Innloggingen som redaktør mislyktes: ${error.message}`)
  }
  return client
}

type Client = Awaited<ReturnType<typeof editorClient>>

/**
 * Avvisninger fra databasen når fram ordrett her.
 *
 * Dette er en terminal og ikke en brukerflate: den som kjører kommandoen, er
 * Claude Code, ChatGPT eller repo-eieren, og den rå årsaken er nettopp det som
 * trengs. Regelen om stabile menneskelige formuleringer gjelder produkt-UI
 * (`src/app/gateway.ts`), ikke teknisk drift.
 */
function platformApi(client: Client): AgentPlatformApi {
  const call = async (fn: string, args: Record<string, unknown>, what: string) => {
    const { data, error } = await client.rpc(fn as never, args as never)
    if (error !== null) {
      throw new Error(`${what}: ${error.message}`)
    }
    return data
  }

  return {
    listQueue: () => call('agent_work_queue', {}, 'Agentkøen kunne ikke leses'),
    assignRoleModel: (choice: RoleModelChoice) => {
      const version = choice.modelVersion === null ? null : choice.modelVersion.trim()
      const exact = version !== null && version !== ''
      return call(
        'assign_agent_role_model',
        {
          p_agent_role: choice.role,
          p_provider: choice.provider,
          p_model: choice.model,
          p_model_version: exact ? version : null,
          p_model_version_disclosure: exact ? 'exact' : 'not_exposed',
          p_reason: choice.reason,
          p_replaces_reason: choice.replacesReason,
        },
        'KI-tjenesten ble ikke tildelt',
      )
    },
    readTask: (pipelineJobId: string) =>
      call(
        'agent_task_payload',
        { p_pipeline_job_id: pipelineJobId },
        'Oppgaven kunne ikke hentes',
      ),
    importAnswer: (pipelineJobId: string, answer: Record<string, unknown>) =>
      call(
        'import_agent_answer',
        // Ordrett. Databasen regner fingeravtrykket av nøyaktig denne filen.
        { p_pipeline_job_id: pipelineJobId, p_answer: answer },
        'Svaret ble ikke registrert',
      ),
    listRunners: () => call('agent_runner_connections', {}, 'Kjørerne kunne ikke leses'),
    registerRunner: (registration: RunnerRegistration) =>
      call(
        'register_agent_runner',
        {
          p_connection_key: registration.connectionKey,
          p_display_name: registration.displayName,
          p_agent_role: registration.role,
          p_platform_agent_reference: registration.platformAgentReference,
          p_platform_model_disclosure: registration.platformModelDisclosure,
          p_reason: registration.reason,
        },
        'Kjøreren ble ikke registrert',
      ),
    issuePairingCode: (connectionKey: string) =>
      call(
        'issue_agent_runner_pairing_code',
        { p_connection_key: connectionKey },
        'Tilkoblingskoden ble ikke utstedt',
      ),
    revokeRunner: (connectionKey: string, reason: string) =>
      call(
        'revoke_agent_runner',
        { p_connection_key: connectionKey, p_reason: reason },
        'Kjøreren ble ikke trukket tilbake',
      ),
  }
}

function disclosure(value: string): 'platform_pinned' | 'not_exposed' {
  if (value !== 'platform_pinned' && value !== 'not_exposed') {
    throw new Error('--disclosure må være platform_pinned eller not_exposed.')
  }
  return value
}

async function run(parsed: ParsedCommand, api: AgentPlatformApi): Promise<number> {
  const { command, options } = parsed

  if (command === 'work') {
    const queue = await listWork(api)
    if (queue.items.length === 0) {
      console.log('Ingen agentoppgaver venter.')
    } else {
      console.log(`${String(queue.items.length)} agentoppgave(r) venter:`)
      for (const item of queue.items) {
        console.log(describeWorkItem(item))
      }
    }
    if (queue.unknownRoles > 0) {
      console.log(
        `${String(queue.unknownRoles)} rad(er) i køen har et agentledd denne kommandoen ikke kjenner.`,
      )
    }
    return 0
  }

  if (command === 'assign-model') {
    const outcome = await assignRoleModel(api, {
      role: need(options, '--role'),
      provider: need(options, '--provider'),
      model: need(options, '--model'),
      modelVersion: options.get('--model-version') ?? null,
      reason: options.get('--reason') ?? null,
      replacesReason: options.get('--replaces-reason') ?? null,
    })
    console.log(
      outcome.alreadyAssigned
        ? `Leddet var allerede tildelt ${outcome.model.provider}/${outcome.model.model}.`
        : `${outcome.role} utføres nå av ${outcome.model.provider}/${outcome.model.model}` +
            `${outcome.replaced ? ' (erstattet en tidligere tildeling)' : ''}.`,
    )
    return 0
  }

  if (command === 'runners') {
    const runners = await listRunners(api)
    if (runners.length === 0) {
      console.log('Ingen autonome kjørere er registrert.')
      return 0
    }
    for (const runner of runners) {
      console.log(
        `  ${runner.connectionKey} — ${runner.displayName} (${runner.role}), ` +
          `${runner.connected ? 'tilkoblet' : 'ikke tilkoblet'}, ` +
          `${String(runner.deliveredAnswers)} leverte svar, ` +
          `modell: ${runner.platformModelDisclosure}`,
      )
    }
    return 0
  }

  if (command === 'register-runner') {
    await api.registerRunner({
      connectionKey: need(options, '--key'),
      displayName: need(options, '--name'),
      role: need(options, '--role'),
      platformAgentReference: need(options, '--platform-ref'),
      platformModelDisclosure: disclosure(need(options, '--disclosure')),
      reason: options.get('--reason') ?? null,
    })
    console.log('Kjøreren er registrert. Hent engangskoden med `pair` når oppsettet skal gjøres.')
    return 0
  }

  if (command === 'pair') {
    const code = await issuePairingCode(api, need(options, '--key'))
    console.log(
      `Engangskode for ${code.displayName} (${code.role}): ${code.pairingCode}\n` +
        `Gyldig til ${code.expiresAt}. Koden vises bare denne ene gangen.`,
    )
    return 0
  }

  if (command === 'revoke') {
    const outcome = await revokeRunner(api, need(options, '--key'), need(options, '--reason'))
    console.log(
      outcome.revoked
        ? 'Kjøreren er trukket tilbake, og tilgangen stoppet i det samme øyeblikket. ' +
            `${String(outcome.revokedSecrets)} hemmelighet(er) trukket, ` +
            `${String(outcome.releasedTasks)} uttak gjort ledige.`
        : 'Kjøreren var allerede trukket tilbake.',
    )
    return 0
  }

  if (command === 'export-task') {
    const task = await readTask(api, need(options, '--job'))
    const path = options.get('--out') ?? agentTaskFileName(task)
    await writeFile(path, renderAgentTaskFile(task), 'utf8')
    console.log(
      `Oppgaven er skrevet til ${path}.\n` +
        'Filen inneholder hele den kontrollerte kildeteksten. Den skal aldri commites, ' +
        'legges i en issue eller havne i en logg.',
    )
    return 0
  }

  if (command === 'import-answer') {
    const raw: unknown = JSON.parse(await readFile(need(options, '--answer'), 'utf8'))
    if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
      throw new Error('Svarfilen er ikke et JSON-objekt.')
    }
    const outcome = await importAnswer(api, need(options, '--job'), raw as Record<string, unknown>)
    console.log(
      outcome.alreadyImported
        ? 'Svaret var allerede registrert. Ingenting nytt ble skrevet.'
        : `Svaret er registrert som kjøring ${outcome.agentRunId}.`,
    )
    return 0
  }

  throw new Error(`Ukjent kommando: ${command}`)
}

async function main(): Promise<number> {
  let parsed: ParsedCommand
  try {
    const result = parseAgentArguments(process.argv.slice(2))
    if (result === 'help') {
      console.log(USAGE)
      return 0
    }
    parsed = result
  } catch (cause) {
    console.error(cause instanceof Error ? cause.message : String(cause))
    console.error(`\n${USAGE}`)
    return 1
  }

  try {
    return await run(parsed, platformApi(await editorClient()))
  } catch (cause) {
    console.error(cause instanceof Error ? cause.message : String(cause))
    return 1
  }
}

process.exitCode = await main()
