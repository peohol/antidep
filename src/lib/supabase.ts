// ============================================================================
// Supabase-klienten for nettleseren
//
// Klienten er bundet til kontraktslaget `api`. Det er ikke en sikkerhetsgrense
// — den ligger i RLS, i grants og i at de kanoniske schemaene ikke er
// eksponert (migrasjon 007, punkt «Trusselvurdering») — men det holder
// klientkoden på den ene leseveien som faktisk er sanksjonert, og gjør et
// forsøk på å lese et kanonisk schema til en typefeil framfor et 404 i
// produksjon.
//
// Nøkkelvakten under er av samme grunn et supplement, ikke en lås:
// service_role omgår RLS og hører ikke hjemme i en nettleser
// (DATABASE_ARCHITECTURE.md §49, CLAUDE.md). Den virkelige beskyttelsen er at
// nøkkelen aldri legges i repoet; vakten fanger den dagen noen likevel
// kopierer feil verdi inn i `.env.local`.
// ============================================================================

import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '../types/database'
import { assertPublishableKey } from './publishable-key'

// Vakten mot en for privilegert nøkkel ligger i sin egen modul, fordi
// MCP-appen leser den samme regelen på serversiden — og en import av noe
// Vite-spesifikt derfra ville dratt `import.meta.env` inn i et Node-bygg.
export { assertPublishableKey }

/** Supabase-klienten slik resten av appen ser den: bundet til `api`. */
export type AntidepClient = SupabaseClient<Database, 'api'>

export interface SupabaseConfig {
  readonly url: string
  readonly publishableKey: string
}

/** Den delen av miljøet klienten leser. Injiseres for å kunne testes. */
export interface SupabaseEnv {
  readonly VITE_SUPABASE_URL?: string | undefined
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string | undefined
}

function required(env: SupabaseEnv, name: keyof SupabaseEnv): string {
  const value = env[name]?.trim()
  if (value === undefined || value.length === 0) {
    throw new Error(
      `Miljøvariabelen ${name} mangler. Kopier .env.example til .env.local og fyll inn ` +
        'verdiene fra `npm run db:status` (lokal stack) eller Supabase-prosjektet.',
    )
  }
  return value
}

/**
 * Leser og validerer konfigurasjonen. Feiler høyt og tidlig: en app som
 * starter med halv konfigurasjon ender i et tomt resultat som ikke lar seg
 * skille fra en tom projeksjon, og de to skal aldri se like ut.
 */
export function readSupabaseConfig(env: SupabaseEnv): SupabaseConfig {
  const url = required(env, 'VITE_SUPABASE_URL')
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    throw new Error(`VITE_SUPABASE_URL er ikke en gyldig URL: «${url}».`)
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    throw new Error(`VITE_SUPABASE_URL må bruke http eller https, ikke «${parsed.protocol}».`)
  }

  const publishableKey = required(env, 'VITE_SUPABASE_PUBLISHABLE_KEY')
  assertPublishableKey(publishableKey)

  return { url, publishableKey }
}

export function createAntidepClient(config: SupabaseConfig): AntidepClient {
  return createClient<Database, 'api'>(config.url, config.publishableKey, {
    db: { schema: 'api' },
  })
}

let client: AntidepClient | undefined

/**
 * Klienten appen deler. Opprettes ved første kall slik at en modulimport ikke
 * kaster i tester og verktøy som ikke har miljøvariablene satt.
 */
export function getAntidepClient(env: SupabaseEnv = import.meta.env): AntidepClient {
  client ??= createAntidepClient(readSupabaseConfig(env))
  return client
}

/** Bare for tester: glem den delte klienten. */
export function resetAntidepClientForTests(): void {
  client = undefined
}
