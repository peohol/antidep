// ============================================================================
// Kjøreren som henter tekst ut av fulltekstene redaktøren har lastet opp
//
//   npm run ops:full-text
//
// Teknisk drift, ikke en produktflate. Kommandoen er ment å kjøres planlagt —
// av Claude Code, av ChatGPT, eller av en tidsplan på en maskin som har
// `pdftotext` installert. Ingen kliniker skal noen gang kjøre den, og ingenting
// i den krever en faglig avgjørelse (issue #99).
//
// ----------------------------------------------------------------------------
// Legitimasjonen er redaktørens egen
//
// Kallet gir ut originaldokumentet, og det skal bare forlate databasen til den
// som allerede kan laste det opp. Kommandoen bruker derfor den samme
// innloggingen `npm run editor:assignment` bruker — ingen agentlegitimasjon,
// ingen service_role-nøkkel.
//
// ----------------------------------------------------------------------------
// Ingen faglig avgjørelse tas her
//
// Om filen er artikkelen, om teksten lar seg lese, og om kildeversjonen kan
// registreres, avgjøres av `api.complete_full_text_extraction(...)`. Denne
// kommandoen leverer teksten oppskriften ga, og rapporterer hva databasen
// svarte.
// ============================================================================

import { createClient } from '@supabase/supabase-js'

import type { Database } from '../types/database.ts'
import {
  describeWorkerReport,
  runFullTextWorker,
  type FailureStage,
  type FullTextIntakeApi,
} from './full-text-worker.ts'

const USAGE = `Bruk:
  npm run ops:full-text [-- valg]

Valg:
  --max <antall>     Hvor mange filer én kjøring tar (standard 10).
  --lease <sekunder> Hvor lenge oppdraget holdes (standard 600).
  --help             Vis denne teksten.

Miljø:
  ANTIDEP_SUPABASE_URL, ANTIDEP_SUPABASE_PUBLISHABLE_KEY
  ANTIDEP_EDITOR_EMAIL og ANTIDEP_EDITOR_PASSWORD — redaktørens egen innlogging,
  eller ANTIDEP_EDITOR_ACCESS_TOKEN når en gyldig token allerede finnes.

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

export function parseWorkerArguments(argv: readonly string[]): CliOptions | 'help' {
  let maxTasks = 10
  let leaseSeconds = 600

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

/** Redaktørens klient: enten en ferdig token, eller en innlogging. */
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
 * Claude Code, ChatGPT eller repo-eieren, og for dem er den rå årsaken
 * nettopp det som trengs. Regelen om stabile menneskelige formuleringer gjelder
 * produkt-UI (`src/app/gateway.ts`), ikke teknisk drift.
 */
function intakeApi(client: Client): FullTextIntakeApi {
  return {
    claim: async (leaseSeconds: number): Promise<unknown> => {
      const { data, error } = await client.rpc('claim_full_text_extraction', {
        p_lease_seconds: leaseSeconds,
      })
      if (error !== null) {
        throw new Error(`Uttrekksoppdraget ble ikke hentet: ${error.message}`)
      }
      return data
    },
    complete: async (
      handle: string,
      extractedText: string,
      toolVersion: string,
    ): Promise<unknown> => {
      const { data, error } = await client.rpc('complete_full_text_extraction', {
        p_handle: handle,
        p_extracted_text: extractedText,
        p_text_extraction_tool_version: toolVersion,
      })
      if (error !== null) {
        throw new Error(`Teksten ble ikke levert: ${error.message}`)
      }
      return data
    },
    fail: async (handle: string, stage: FailureStage): Promise<unknown> => {
      const { data, error } = await client.rpc('fail_full_text_extraction', {
        p_handle: handle,
        p_stage: stage,
      })
      if (error !== null) {
        throw new Error(`Stopppunktet ble ikke meldt: ${error.message}`)
      }
      return data
    },
  }
}

async function main(): Promise<number> {
  let options: CliOptions
  try {
    const parsed = parseWorkerArguments(process.argv.slice(2))
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

  try {
    const report = await runFullTextWorker({
      api: intakeApi(await editorClient()),
      maxTasks: options.maxTasks,
      leaseSeconds: options.leaseSeconds,
      log: (line) => {
        console.log(line)
      },
    })
    console.log(describeWorkerReport(report))
    return 0
  } catch (cause) {
    console.error(cause instanceof Error ? cause.message : String(cause))
    return 1
  }
}

process.exitCode = await main()
