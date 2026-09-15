// ============================================================================
// Sammensetningen: miljøet inn, én forespørselsbehandler ut
//
// Adapterne i `api/` er tynne med vilje. De vet hvilken rute de er, og
// ingenting annet — hele appen ligger her, i vanlig TypeScript uten en eneste
// plattformavhengighet, og kan prøves som det den er.
//
// Klienten opprettes ved første kall og ikke ved import: en modulimport skal
// ikke kaste i et byggesteg som ikke har miljøvariablene satt.
// ============================================================================

import { assertPublishableKey } from '../lib/publishable-key.ts'
import { handleMcpRequest, type McpAppDependencies, type McpRoute } from './app.ts'
import { createSupabaseRunnerGateway, type RunnerGateway } from './gateway.ts'

export { MCP_ROUTES, RUNNER_SCOPE, handleMcpRequest } from './app.ts'
export type { McpRoute, McpAppDependencies } from './app.ts'
export type { RunnerGateway } from './gateway.ts'

/** Den delen av miljøet MCP-appen leser. */
export interface McpEnvironment {
  readonly ANTIDEP_SUPABASE_URL?: string | undefined
  readonly ANTIDEP_SUPABASE_PUBLISHABLE_KEY?: string | undefined
  readonly ANTIDEP_MCP_BASE_URL?: string | undefined
}

export interface McpConfig {
  readonly supabaseUrl: string
  readonly publishableKey: string
  readonly baseUrl: string | undefined
}

function required(env: McpEnvironment, name: keyof McpEnvironment): string {
  const value = env[name]?.trim()
  if (value === undefined || value.length === 0) {
    throw new Error(
      `Miljøvariabelen ${name} mangler. MCP-appen trenger adressen til Data API-et og ` +
        'den publishable nøkkelen — og ingen andre hemmeligheter.',
    )
  }
  return value
}

/**
 * Leser miljøet, og avviser en nøkkel som gir mer enn appen skal ha.
 *
 * Den samme vakten nettleserklienten bruker: service_role omgår RLS, og en
 * MCP-app som hadde den, ville kunnet gjøre alt en modell ba den om — stikk i
 * strid med at hele autorisasjonen ligger i databasen
 * (ANTIDEP_CONSTITUTION.md regel 7).
 */
export function readMcpConfig(env: McpEnvironment): McpConfig {
  const supabaseUrl = required(env, 'ANTIDEP_SUPABASE_URL')
  const publishableKey = required(env, 'ANTIDEP_SUPABASE_PUBLISHABLE_KEY')
  assertPublishableKey(publishableKey, 'ANTIDEP_SUPABASE_PUBLISHABLE_KEY')
  const baseUrl = env.ANTIDEP_MCP_BASE_URL?.trim()
  return {
    supabaseUrl,
    publishableKey,
    baseUrl: baseUrl === undefined || baseUrl.length === 0 ? undefined : baseUrl,
  }
}

let cached: McpAppDependencies | undefined

function dependencies(env: McpEnvironment): McpAppDependencies {
  if (cached === undefined) {
    const config = readMcpConfig(env)
    const gateway: RunnerGateway = createSupabaseRunnerGateway({
      supabaseUrl: config.supabaseUrl,
      publishableKey: config.publishableKey,
    })
    cached = { gateway, baseUrl: config.baseUrl }
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
