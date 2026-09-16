// ============================================================================
// Sammensetningen: miljøet inn, én forespørselsbehandler ut
//
// Adapterne i `api/` er tynne med vilje. De vet hvilken rute de er, og
// ingenting annet — hele appen ligger her, i vanlig TypeScript uten en eneste
// plattformavhengighet, og kan prøves som det den er.
//
// Databasegrenseflaten opprettes verken ved import eller ved første
// forespørsel, men ved første bruk: en modulimport skal ikke kaste i et
// byggesteg uten miljøvariabler, og oppdagelsesdokumentene under
// `/.well-known/` skal svare selv om databaseoppsettet mangler — det er der en
// klient leser hvor den skal autentisere seg.
// ============================================================================

import { assertPublishableKey } from '../lib/publishable-key.ts'
import { handleMcpRequest, type McpAppDependencies, type McpRoute } from './app.ts'
import { createSupabaseRunnerGateway, type RunnerGateway } from './gateway.ts'
import { parseAllowedOrigins } from './origin.ts'

export { MCP_ROUTES, RUNNER_SCOPE, handleMcpRequest } from './app.ts'
export type { McpRoute, McpAppDependencies } from './app.ts'
export type { RunnerGateway } from './gateway.ts'

/** Den delen av miljøet MCP-appen leser. */
export interface McpEnvironment {
  readonly ANTIDEP_SUPABASE_URL?: string | undefined
  readonly ANTIDEP_SUPABASE_PUBLISHABLE_KEY?: string | undefined
  readonly VITE_SUPABASE_URL?: string | undefined
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string | undefined
  readonly ANTIDEP_MCP_BASE_URL?: string | undefined
  readonly ANTIDEP_MCP_ALLOWED_ORIGINS?: string | undefined
}

/**
 * Navnene hver verdi kan stå under, i den rekkefølgen de leses.
 *
 * Antidep har ÉN Data API-adresse og ÉN publishable key. At de i dag er
 * oppgitt under to navnesett, er en konsekvens av hvem som leser dem: CLI-ene
 * på en utviklermaskin leser `ANTIDEP_`-navnene fra en miljøfil, og
 * nettklienten leser `VITE_`-navnene fordi Vite krever prefikset for å legge
 * dem inn i nettleserbygget. Verdiene er de samme
 * (`.env.example`, `supabase/README.md`).
 *
 * MCP-appen kjører i den samme utrullingen som nettklienten, og skal ikke
 * kreve at den samme verdien føres opp en tredje gang for å komme i gang. Det
 * eksplisitte `ANTIDEP_`-navnet vinner alltid, slik at en utrulling som skal
 * peke et annet sted, kan si det.
 *
 * Fallbacken utvider ingen fullmakt: `VITE_`-verdiene sendes per definisjon
 * til enhver nettleser som åpner Antidep, og `assertPublishableKey` avviser en
 * nøkkel som gir mer — uansett hvilket navn den kom under.
 */
const SUPABASE_URL_NAMES = ['ANTIDEP_SUPABASE_URL', 'VITE_SUPABASE_URL'] as const
const PUBLISHABLE_KEY_NAMES = [
  'ANTIDEP_SUPABASE_PUBLISHABLE_KEY',
  'VITE_SUPABASE_PUBLISHABLE_KEY',
] as const

export interface McpConfig extends McpTransportConfig, McpGatewayConfig {}

/** Den delen appen trenger for å svare på en forespørsel i det hele tatt. */
export interface McpTransportConfig {
  readonly baseUrl: string | undefined
  readonly allowedOrigins: readonly string[]
}

/** Den delen appen bare trenger når den faktisk skal snakke med databasen. */
export interface McpGatewayConfig {
  readonly supabaseUrl: string
  readonly publishableKey: string
}

function required(env: McpEnvironment, names: readonly (keyof McpEnvironment)[]): string {
  for (const name of names) {
    const value = env[name]?.trim()
    if (value !== undefined && value.length > 0) {
      return value
    }
  }
  throw new Error(
    `Ingen av miljøvariablene ${names.join(' eller ')} er satt. MCP-appen trenger ` +
      'adressen til Data API-et og den publishable nøkkelen — og ingen andre hemmeligheter.',
  )
}

/**
 * Transporten sin del av miljøet.
 *
 * Begge verdiene er valgfrie, men en oppgitt `ANTIDEP_MCP_ALLOWED_ORIGINS` som
 * ikke lar seg lese, kastes her framfor å bli en opprinnelse ingen slipper inn
 * og ingen skjønner hvorfor: uten en opprinnelsespolicy kan transporten ikke
 * avgjøre grensen, og da skal den ikke svare på noe som helst.
 */
export function readTransportConfig(env: McpEnvironment): McpTransportConfig {
  const baseUrl = env.ANTIDEP_MCP_BASE_URL?.trim()
  return {
    baseUrl: baseUrl === undefined || baseUrl.length === 0 ? undefined : baseUrl,
    allowedOrigins: parseAllowedOrigins(
      env.ANTIDEP_MCP_ALLOWED_ORIGINS,
      'ANTIDEP_MCP_ALLOWED_ORIGINS',
    ),
  }
}

/**
 * Databasedelen av miljøet, og avvisningen av en nøkkel som gir mer enn appen
 * skal ha.
 *
 * Den samme vakten nettleserklienten bruker: service_role omgår RLS, og en
 * MCP-app som hadde den, ville kunnet gjøre alt en modell ba den om — stikk i
 * strid med at hele autorisasjonen ligger i databasen
 * (ANTIDEP_CONSTITUTION.md regel 7).
 */
export function readGatewayConfig(env: McpEnvironment): McpGatewayConfig {
  const supabaseUrl = required(env, SUPABASE_URL_NAMES)
  const publishableKey = required(env, PUBLISHABLE_KEY_NAMES)
  assertPublishableKey(publishableKey, PUBLISHABLE_KEY_NAMES[0])
  return { supabaseUrl, publishableKey }
}

/** Hele miljøet på én gang, for den som vil kontrollere oppsettet i ett kall. */
export function readMcpConfig(env: McpEnvironment): McpConfig {
  return { ...readTransportConfig(env), ...readGatewayConfig(env) }
}

let cached: McpAppDependencies | undefined

/**
 * Sammensetningen, med databasen som et ledd appen først krever når den skal
 * bruke det.
 *
 * Oppdagelsesdokumentene under `/.well-known/` beskriver ressursen og
 * autorisasjonstjeneren, og de er rene funksjoner av adressen appen står på.
 * De skal svare selv om databaseoppsettet mangler — nettopp da trenger en
 * klient dem, for det er der den leser hvor den skal autentisere seg. Bygde vi
 * grenseflaten ved første forespørsel uansett rute, ville en manglende
 * miljøvariabel gjort hele appen taus på én gang, og den som feilsøkte, ville
 * ikke fått vite mer enn «500» av noen rute.
 *
 * Grunnen står i kjøreloggen og aldri i svaret: en rute som faktisk trenger
 * databasen, svarer med sin vanlige feilform.
 */
function dependencies(env: McpEnvironment): McpAppDependencies {
  if (cached === undefined) {
    const transport = readTransportConfig(env)
    let gateway: RunnerGateway | undefined
    cached = {
      get gateway(): RunnerGateway {
        gateway ??= createSupabaseRunnerGateway(readGatewayConfig(env))
        return gateway
      },
      baseUrl: transport.baseUrl,
      allowedOrigins: transport.allowedOrigins,
    }
  }
  return cached
}

/** Bare for prøver: glem den delte sammensetningen. */
export function resetMcpAppForTests(): void {
  cached = undefined
}

/** Behandleren en adapter i `api/` kaller. */
export function serveMcpRoute(
  route: McpRoute,
  request: Request,
  env: McpEnvironment,
): Promise<Response> {
  return handleMcpRequest(route, request, dependencies(env))
}
