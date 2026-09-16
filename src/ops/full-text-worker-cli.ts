// ============================================================================
// Kjøreren som henter tekst ut av fulltekstene redaktøren har lastet opp
//
//   npm run ops:full-text
//
// Teknisk drift, ikke en produktflate. Kommandoen kjøres planlagt av
// `.github/workflows/full-text-extraction.yml` hvert kvarter, på en maskin som
// har `pdftotext` installert. Ingen kliniker skal noen gang kjøre den, ingen
// trenger å starte den, og ingenting i den krever en faglig avgjørelse
// (issue #99). Den kan også kjøres for hånd av Claude Code eller ChatGPT når
// noe skal feilsøkes.
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
  apiFailure,
  describeUnexpectedFailure,
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
  --diagnostics      Ta med den rå årsaken fra verktøyet i loggen. Av som
                     standard: den planlagte kjøringen logger offentlig, og en
                     rå feiltekst kan bære deler av dokumentet.
  --help             Vis denne teksten.

Miljø:
  ANTIDEP_SUPABASE_URL, ANTIDEP_SUPABASE_PUBLISHABLE_KEY
  ANTIDEP_EDITOR_EMAIL og ANTIDEP_EDITOR_PASSWORD — redaktørens egen innlogging,
  eller ANTIDEP_EDITOR_ACCESS_TOKEN når en gyldig token allerede finnes.

Kommandoen er teknisk drift. Den hører til deployen og aldri til en brukerflate.`

interface CliOptions {
  readonly maxTasks: number
  readonly leaseSeconds: number
  readonly diagnostics: boolean
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
  let diagnostics = false

  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    if (flag === '--help' || flag === '-h') {
      return 'help'
    }
    if (flag === '--diagnostics') {
      diagnostics = true
      continue
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

  return { maxTasks, leaseSeconds, diagnostics }
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
async function editorClient(
  diagnostics: boolean,
): Promise<ReturnType<typeof createClient<Database, 'api'>>> {
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
    throw apiFailure('Innloggingen som redaktør mislyktes.', error, diagnostics)
  }
  return client
}

type Client = Awaited<ReturnType<typeof editorClient>>

/**
 * Hvilket ledd som sviktet og med hvilken kode — og den rå årsaken bare når
 * noen har bedt om den.
 *
 * Dette var en ren terminalkommando da den ble skrevet, og da nådde
 * avvisningene fra databasen fram ordrett: den som kjørte den, var Claude Code,
 * ChatGPT eller repo-eieren, og for dem er den rå årsaken nettopp det som
 * trengs. Nå kjører den også planlagt i GitHub Actions, i et offentlig repo,
 * der loggen er offentlig — og da holder ikke den begrunnelsen lenger. Den rå
 * årsaken er derfor bak `--diagnostics`, og koden, som ikke kan bære innhold,
 * står alltid.
 */
function intakeApi(client: Client, diagnostics: boolean): FullTextIntakeApi {
  return {
    claim: async (leaseSeconds: number): Promise<unknown> => {
      const { data, error } = await client.rpc('claim_full_text_extraction', {
        p_lease_seconds: leaseSeconds,
      })
      if (error !== null) {
        throw apiFailure('Uttrekksoppdraget ble ikke hentet.', error, diagnostics)
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
        throw apiFailure('Teksten ble ikke levert.', error, diagnostics)
      }
      return data
    },
    fail: async (handle: string, stage: FailureStage): Promise<unknown> => {
      const { data, error } = await client.rpc('fail_full_text_extraction', {
        p_handle: handle,
        p_stage: stage,
      })
      if (error !== null) {
        throw apiFailure('Stopppunktet ble ikke meldt.', error, diagnostics)
      }
      return data
    },
    resume: async (): Promise<unknown> => {
      const { data, error } = await client.rpc('resume_blocked_full_text_extractions', {})
      if (error !== null) {
        throw apiFailure('Blokkert arbeid ble ikke satt i gang igjen.', error, diagnostics)
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
    // Valgene kommer fra kommandolinjen og ikke fra databasen, så feilen her er
    // kommandoens egen setning om et ugyldig valg.
    console.error(cause instanceof Error ? cause.message : String(cause))
    console.error(`\n${USAGE}`)
    return 1
  }

  try {
    const report = await runFullTextWorker({
      api: intakeApi(await editorClient(options.diagnostics), options.diagnostics),
      maxTasks: options.maxTasks,
      leaseSeconds: options.leaseSeconds,
      diagnostics: options.diagnostics,
      log: (line) => {
        console.log(line)
      },
    })
    console.log(describeWorkerReport(report))
    return 0
  } catch (cause) {
    console.error(describeUnexpectedFailure(cause, options.diagnostics))
    return 1
  }
}

process.exitCode = await main()
