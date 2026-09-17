// ============================================================================
// Kjøreren som henter materialet Antidep selv kan hente
//
//   npm run ops:acquire
//
// Teknisk drift, ikke en produktflate. Kommandoen går gjennom de åpne
// forespørslene om originalmateriale og leter der materialet faktisk ligger —
// hos utgiveren, i et åpent arkiv — før noen spør en kliniker. Det den ikke
// finner, blir stående som en åpen forespørsel med en tilgangsbegrensning, og
// det er ikke en konklusjon om evidensen.
//
// Redaktørlegitimasjon, som `npm run ops:full-text`: registreringen av et
// dokument er en redaksjonell skrivevei, og den har ingen agentrolle.
// ============================================================================

import { createClient } from '@supabase/supabase-js'

import { guardedGet } from '../agents/guarded-http.ts'
import type { Database } from '../types/database.ts'
import {
  describeAcquisitionReport,
  runMonographAcquisition,
  type AcquisitionApi,
  type SourceRequest,
} from './monograph-acquisition.ts'

const USAGE = `Bruk:
  npm run ops:acquire [-- valg]

Valg:
  --max-requests <n>  Hvor mange forespørsler kjøringen forsøker (standard 10)
  --help              Vis denne teksten

Miljø:
  ANTIDEP_SUPABASE_URL
  ANTIDEP_SUPABASE_PUBLISHABLE_KEY
  ANTIDEP_EDITOR_EMAIL og ANTIDEP_EDITOR_PASSWORD (eller ANTIDEP_EDITOR_ACCESS_TOKEN)`

function required(name: string): string {
  const value = process.env[name]?.trim()
  if (value === undefined || value.length === 0) {
    throw new Error(`Miljøvariabelen ${name} mangler. Se .env.example.`)
  }
  return value
}

function requestFrom(row: Record<string, unknown>): SourceRequest {
  const identifiers = Array.isArray(row['identifiers']) ? (row['identifiers'] as unknown[]) : []
  return {
    reference: String(row['reference'] ?? ''),
    kind: row['kind'] === 'authority_document' ? 'authority_document' : 'research_full_text',
    title: String(row['title'] ?? ''),
    retrievedFrom: typeof row['retrieved_from'] === 'string' ? row['retrieved_from'] : null,
    requiredRepresentation:
      typeof row['required_representation'] === 'string' ? row['required_representation'] : null,
    identifiers: identifiers.map((entry) => {
      const identifier = entry as Record<string, unknown>
      return {
        system: String(identifier['system'] ?? ''),
        value: String(identifier['value'] ?? ''),
      }
    }),
  }
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2)
  if (argv.includes('--help') || argv.includes('-h')) {
    console.log(USAGE)
    return
  }
  let maxRequests = 10
  const limitIndex = argv.indexOf('--max-requests')
  if (limitIndex >= 0) {
    const value = Number.parseInt(argv[limitIndex + 1] ?? '', 10)
    if (!Number.isInteger(value) || value < 1 || value > 100) {
      console.error('--max-requests må være et tall mellom 1 og 100.')
      process.exitCode = 2
      return
    }
    maxRequests = value
  }

  const url = required('ANTIDEP_SUPABASE_URL')
  const key = required('ANTIDEP_SUPABASE_PUBLISHABLE_KEY')
  const token = process.env['ANTIDEP_EDITOR_ACCESS_TOKEN']?.trim()

  const client =
    token !== undefined && token.length > 0
      ? createClient<Database, 'api'>(url, key, {
          db: { schema: 'api' },
          auth: { persistSession: false, autoRefreshToken: false },
          global: { headers: { Authorization: `Bearer ${token}` } },
        })
      : createClient<Database, 'api'>(url, key, {
          db: { schema: 'api' },
          auth: { persistSession: false, autoRefreshToken: false },
        })

  if (token === undefined || token.length === 0) {
    const { error } = await client.auth.signInWithPassword({
      email: required('ANTIDEP_EDITOR_EMAIL'),
      password: required('ANTIDEP_EDITOR_PASSWORD'),
    })
    if (error !== null) {
      console.error('Innloggingen som redaktør mislyktes.')
      process.exitCode = 1
      return
    }
  }

  const api: AcquisitionApi = {
    async orders() {
      const { data, error } = await client.rpc('monograph_orders')
      if (error !== null) {
        throw new Error('Bestillingene kunne ikke hentes.')
      }
      const rows = Array.isArray(data) ? data : []
      return rows
        .map((row) => String((row as Record<string, unknown>)['reference'] ?? ''))
        .filter((reference) => reference.length > 0)
    },

    async requests(editionReference) {
      const { data, error } = await client.rpc('monograph_source_requests', {
        p_edition_reference: editionReference,
      })
      if (error !== null) {
        throw new Error('Forespørslene kunne ikke hentes.')
      }
      const payload = (data ?? {}) as Record<string, unknown>
      const research = Array.isArray(payload['research_full_text'])
        ? (payload['research_full_text'] as unknown[])
        : []
      const documents = Array.isArray(payload['authority_documents'])
        ? (payload['authority_documents'] as unknown[])
        : []
      return [...research, ...documents].map((row) => requestFrom(row as Record<string, unknown>))
    },

    async submitDocument(args) {
      const { error } = await client.rpc('submit_monograph_document', {
        p_reference: args.reference,
        p_document_base64: args.documentBase64,
        p_media_type: args.mediaType,
        p_extracted_text: args.extractedText,
        p_text_extraction_recipe: args.recipe,
        p_retrieved_from: args.retrievedFrom,
      })
      if (error !== null) {
        throw new Error('Dokumentet ble avvist av registreringen.')
      }
    },

    async submitFullText(args) {
      const { error } = await client.rpc('submit_full_text', {
        p_reference: args.reference,
        p_document_base64: args.documentBase64,
      })
      if (error !== null) {
        throw new Error('Fullteksten ble avvist av innboksen.')
      }
    },
  }

  const report = await runMonographAcquisition(api, { maxRequests, fetcher: guardedGet })
  console.log(describeAcquisitionReport(report))
}

await main()
