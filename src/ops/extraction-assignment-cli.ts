// ============================================================================
// Kjøreren som lager et ekstraksjonsoppdrag
//
//   npm run editor:assignment -- --source "Fava" --drug sertralin \
//     --outcome vektendring --population "voksne med depressiv lidelse" \
//     --pdf ~/artikler/fava-2000.pdf \
//     --retrieved-from "https://doi.org/10.4088/jcp.v61n1109"
//
// Med `--pdf` registreres fullteksten av originaldokumentet først: databasen
// beregner fingeravtrykket av PDF-en og av teksten, og lagrer oppskriften
// teksten ble hentet ut med (migrasjon 003e). Uten `--pdf` velges den nyeste
// registrerte kildeversjonen, eventuelt av den representasjonstypen `--representation`
// ber om.
//
// Ingen uuid, ingen hash og ingen JSON skrives for hånd. Oppdraget bygges av
// `api.build_extraction_assignment(...)` (migrasjon 007i), leses med den samme
// strengheten som en fil, og skrives til `assignments/`.
//
// ----------------------------------------------------------------------------
// Legitimasjonen er redaktørens egen
//
// Kommandoen skriver en kildeversjon og leser den redaksjonelle lesemodellen.
// Begge krever `editor`-rollen, som er en **menneskelig** rolle: det er en
// kvalifisert redaktør som avgjør hvilken artikkel og hvilken avgrensning et
// oppdrag gjelder (EVIDENCE_PIPELINE.md §63, CONTENT_GOVERNANCE.md). Den bruker
// derfor redaktørens egen innlogging — den samme som i nettappen — og ingen
// agentlegitimasjon og ingen service_role-nøkkel.
//
// Dette er ikke et ledd i modell-leddet, og skal aldri bli nåbar derfra.
// ============================================================================

import { writeFile } from 'node:fs/promises'
import { join } from 'node:path'

import { createClient } from '@supabase/supabase-js'

import type { Database } from '../types/database.ts'
import type { EditorSourceRow, EditorSourceVersionRow, Uuid } from '../types/api.ts'
import { toSlug } from '../lib/slug.ts'
import {
  buildAssignmentFromCatalog,
  type BuildAssignmentInput,
  type DocumentVersionInput,
  type EditorCatalogApi,
} from './extraction-assignment.ts'

const USAGE = `Bruk:
  npm run editor:assignment -- --source <søk> --drug <navn> --outcome <navn> [valg]

Valg:
  --source <søk>          Del av tittelen eller en forfatter. Må treffe én kilde.
  --drug <navn>           Virkestoff funnet kan gjelde. Kan gjentas. Minst ett.
  --outcome <navn>        Endepunkt funnet kan gjelde. Kan gjentas. Minst ett.
  --population <navn>     Populasjon funnet kan peke på. Kan gjentas, kan utelates.
  --pdf <fil>             Originaldokumentet. Registrerer fullteksten av det.
  --retrieved-from <url>  Hvor dokumentet ble hentet fra. Påkrevd med --pdf.
  --representation <type> Med --pdf: hva versjonen registreres som (standard full_text).
                          Uten: hvilken registrert versjon oppdraget skal gjelde.
  --external-version <t>  Versjonsmerket kilden selv oppgir, om den gjør det.
  --documents <katalog>   Dokumentlageret (standard: documents, eller ANTIDEP_DOCUMENT_DIR).
  --out <fil>             Hvor oppdraget skrives (standard: assignments/<kilde>.json).
  --help                  Vis denne teksten.

Miljø:
  ANTIDEP_SUPABASE_URL, ANTIDEP_SUPABASE_PUBLISHABLE_KEY
  ANTIDEP_EDITOR_EMAIL og ANTIDEP_EDITOR_PASSWORD — redaktørens egen innlogging,
  eller ANTIDEP_EDITOR_ACCESS_TOKEN når en gyldig token allerede finnes.`

interface CliOptions {
  readonly sourceQuery: string
  readonly drugs: readonly string[]
  readonly outcomes: readonly string[]
  readonly populations: readonly string[]
  readonly documentPath: string | null
  readonly retrievedFrom: string | null
  readonly representation: string | null
  readonly externalVersion: string | null
  readonly documentStore: string | null
  readonly out: string | null
}

/** Leser argumentlisten, eller kaster med en setning som sier hva som er galt. */
export function parseAssignmentArguments(argv: readonly string[]): CliOptions | 'help' {
  const drugs: string[] = []
  const outcomes: string[] = []
  const populations: string[] = []
  const single = new Map<string, string>()

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
      case '--drug':
        drugs.push(value)
        continue
      case '--outcome':
        outcomes.push(value)
        continue
      case '--population':
        populations.push(value)
        continue
      case '--source':
      case '--pdf':
      case '--retrieved-from':
      case '--representation':
      case '--external-version':
      case '--documents':
      case '--out':
        if (single.has(flag)) {
          throw new Error(`${flag} kan bare oppgis én gang.`)
        }
        single.set(flag, value)
        continue
      default:
        throw new Error(`Ukjent valg: ${String(flag)}`)
    }
  }

  const sourceQuery = single.get('--source')
  if (sourceQuery === undefined) {
    throw new Error('--source er påkrevd.')
  }
  if (drugs.length === 0) {
    throw new Error('--drug er påkrevd, og kan gjentas.')
  }
  if (outcomes.length === 0) {
    throw new Error('--outcome er påkrevd, og kan gjentas.')
  }

  return {
    sourceQuery,
    drugs,
    outcomes,
    populations,
    documentPath: single.get('--pdf') ?? null,
    retrievedFrom: single.get('--retrieved-from') ?? null,
    representation: single.get('--representation') ?? null,
    externalVersion: single.get('--external-version') ?? null,
    documentStore: single.get('--documents') ?? null,
    out: single.get('--out') ?? null,
  }
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

/** En avvisning fra lesemodellen sier alltid det samme: mangler du rollen? */
function readRows<Row>(
  table: string,
  result: { data: Row[] | null; error: { message: string } | null },
): readonly Row[] {
  if (result.error !== null) {
    throw new Error(
      `Oppslaget mot ${table} ble avvist: ${result.error.message}. Har kontoen editor-rollen?`,
    )
  }
  return result.data ?? []
}

function catalogApi(client: Client): EditorCatalogApi {
  return {
    listSources: async (): Promise<readonly EditorSourceRow[]> =>
      readRows('editor_sources', await client.from('editor_sources').select('*')),
    listSourceVersions: async (sourceId): Promise<readonly EditorSourceVersionRow[]> =>
      readRows(
        'editor_source_versions',
        await client.from('editor_source_versions').select('*').eq('source_id', sourceId),
      ),
    createSourceVersionFromDocument: async (input: DocumentVersionInput): Promise<Uuid> => {
      const { data, error } = await client.rpc('create_source_version_from_document', {
        p_source_id: input.sourceId,
        p_retrieved_at: input.retrievedAt,
        p_retrieved_from: input.retrievedFrom,
        p_document_base64: input.documentBase64,
        p_extracted_text: input.extractedText,
        p_representation: input.representation,
        p_text_extraction_tool: input.recipe.tool,
        p_text_extraction_tool_version: input.recipe.toolVersion,
        p_text_extraction_arguments: input.recipe.arguments,
        p_external_version: input.externalVersion,
      })
      if (error !== null) {
        throw new Error(`Kildeversjonen ble ikke registrert: ${error.message}`)
      }
      return data
    },
    buildAssignment: async (input: BuildAssignmentInput): Promise<unknown> => {
      const { data, error } = await client.rpc('build_extraction_assignment', {
        p_source_version_id: input.sourceVersionId,
        p_drug_names: input.drugs,
        p_outcome_labels: input.outcomes,
        p_population_labels: input.populations,
      })
      if (error !== null) {
        throw new Error(`Oppdraget ble ikke bygget: ${error.message}`)
      }
      return data
    },
  }
}

async function main(): Promise<number> {
  let options: CliOptions
  try {
    const parsed = parseAssignmentArguments(process.argv.slice(2))
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
    const client = await editorClient()
    const documentStore =
      options.documentStore ?? process.env['ANTIDEP_DOCUMENT_DIR']?.trim() ?? 'documents'

    const report = await buildAssignmentFromCatalog({
      catalog: catalogApi(client),
      sourceQuery: options.sourceQuery,
      drugs: options.drugs,
      outcomes: options.outcomes,
      populations: options.populations,
      documentStore,
      ...(options.documentPath === null ? {} : { documentPath: options.documentPath }),
      ...(options.retrievedFrom === null ? {} : { retrievedFrom: options.retrievedFrom }),
      ...(options.representation === null ? {} : { representation: options.representation }),
      externalVersion: options.externalVersion,
      log: (line) => {
        console.log(line)
      },
    })

    const out =
      options.out ??
      join(
        'assignments',
        `${toSlug(report.source.title).slice(0, 60)}-${report.representation}.json`,
      )
    await writeFile(out, `${JSON.stringify(report.json, null, 2)}\n`, 'utf8')

    console.log(
      `\nOppdrag skrevet: ${out}\n` +
        `  kilde              ${report.source.title}\n` +
        `  kildeversjon       ${report.sourceVersionId} (${report.representation}, ${report.versionOutcome})\n` +
        `  originaldokument   ${report.document?.digest ?? 'ingen — representasjonen er teksten på adressen'}\n` +
        `  virkestoff         ${report.assignment.drugs.map((choice) => choice.label).join(', ')}\n` +
        `  endepunkt          ${report.assignment.outcomes.map((choice) => choice.label).join(', ')}\n` +
        `  populasjon         ${
          report.assignment.populations.length === 0
            ? 'ingen — forslaget må si hvorfor i population_availability'
            : report.assignment.populations.map((choice) => choice.label).join(', ')
        }`,
    )
    return 0
  } catch (cause) {
    console.error(cause instanceof Error ? cause.message : String(cause))
    return 1
  }
}

process.exitCode = await main()
