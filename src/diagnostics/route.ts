// ============================================================================
// Ruten den rå årsaken kommer inn på
//
// En egen transport, og det er hele poenget. Meldingen om at et område ikke
// svarer, går over Data API-et — men den rå årsaken kan ikke gå den samme veien,
// for det er nettopp den veien som kanskje er nede. En observasjon som bare
// overlever når det den beskriver ikke skjedde, er ingen observasjon.
//
// ----------------------------------------------------------------------------
// Hvorfor same-origin, og hvorfor det ikke er en fullmakt
//
// Ruten ligger på Antideps egen opprinnelse. Det gir tre ting nettleseren ikke
// får til på tvers av opprinnelser: `sendBeacon` kan levere mens fanen lukkes,
// det finnes ingen preflight å feile på, og serveren kan prøve igjen når
// databasen svarer tregt.
//
// Den gir ingen ny fullmakt. Ruten holder ingen hemmelighet og har ikke mer
// tilgang enn nettleseren — den videresender brukerens egen token, og hele
// autorisasjonen ligger i databasen (ANTIDEP_CONSTITUTION.md regel 7). Det er
// den samme grensen MCP-appen bærer, og av samme grunn.
//
// ----------------------------------------------------------------------------
// Svaret sier ingenting
//
// 204 uansett utfall, så lenge kroppen lot seg lese. En rute som fortalte om
// tokenen var gyldig, eller om kvoten var brukt opp, ville vært et sted å prøve
// seg fram fra utsiden. Grunnen står i kjøreloggen, som er privat.
// ============================================================================

import { parseDiagnosticEnvelope, MAX_DETAIL_CHARS } from './envelope.ts'

/** Den delen av miljøet ruten leser. Samme verdier som resten av utrullingen. */
export interface DiagnosticsEnvironment {
  readonly ANTIDEP_SUPABASE_URL?: string | undefined
  readonly ANTIDEP_SUPABASE_PUBLISHABLE_KEY?: string | undefined
  readonly VITE_SUPABASE_URL?: string | undefined
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string | undefined
}

/** Å sende det videre til databasen. Injiserbar, slik at en prøve slipper nettet. */
export type ForwardDiagnostic = (
  url: string,
  init: { readonly headers: Record<string, string>; readonly body: string },
) => Promise<{ readonly ok: boolean; readonly status: number }>

/**
 * Kroppen leses med et tak.
 *
 * En konvolutt er noen kilobyte. Alt over er enten en feil eller et forsøk, og
 * ingen av delene skal få lov til å bli lest inn i minnet.
 */
const MAX_BODY_BYTES = 16 * 1024

function pick(
  env: DiagnosticsEnvironment,
  names: readonly (keyof DiagnosticsEnvironment)[],
): string {
  for (const name of names) {
    const value = env[name]?.trim()
    if (value !== undefined && value.length > 0) {
      return value
    }
  }
  throw new Error(`Ingen av miljøvariablene ${names.join(' eller ')} er satt.`)
}

const nothing = (): Response => new Response(null, { status: 204 })

const fetchForward: ForwardDiagnostic = async (url, init) => {
  const response = await fetch(url, { method: 'POST', headers: init.headers, body: init.body })
  return { ok: response.ok, status: response.status }
}

/**
 * Tar imot én observasjon og legger den i den private lagringen.
 *
 * Prøver igjen én gang på et svar som kan være forbigående. Det er den ene
 * tingen en server kan gjøre som en nettleser midt i en navigasjon ikke kan, og
 * den er grunnen til at ruten finnes.
 */
export async function serveDiagnostics(
  request: Request,
  env: DiagnosticsEnvironment,
  forward: ForwardDiagnostic = fetchForward,
): Promise<Response> {
  if (request.method !== 'POST') {
    return new Response(null, { status: 405, headers: { allow: 'POST' } })
  }

  let envelope
  try {
    const body = await request.text()
    if (body.length > MAX_BODY_BYTES) {
      return new Response(null, { status: 413 })
    }
    envelope = parseDiagnosticEnvelope(JSON.parse(body))
  } catch {
    // Grunnen står i kjøreloggen og aldri i svaret.
    return new Response(null, { status: 400 })
  }

  let supabaseUrl: string
  let publishableKey: string
  try {
    supabaseUrl = pick(env, ['ANTIDEP_SUPABASE_URL', 'VITE_SUPABASE_URL'])
    publishableKey = pick(env, [
      'ANTIDEP_SUPABASE_PUBLISHABLE_KEY',
      'VITE_SUPABASE_PUBLISHABLE_KEY',
    ])
  } catch {
    return new Response(null, { status: 503 })
  }

  const url = `${supabaseUrl.replace(/\/+$/, '')}/rest/v1/rpc/record_client_diagnostic`
  const body = JSON.stringify({
    p_area: envelope.area,
    p_kind: envelope.kind,
    p_operation: envelope.operation,
    p_code: envelope.code,
    p_http_status: envelope.httpStatus,
    p_transport: envelope.transport,
    p_detail: envelope.detail.slice(0, MAX_DETAIL_CHARS),
  })
  const headers = {
    // Brukerens egen token, videresendt. Ruten har ingen av sine egne.
    authorization: `Bearer ${envelope.accessToken}`,
    apikey: publishableKey,
    'content-type': 'application/json',
    'content-profile': 'api',
  }

  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const outcome = await forward(url, { headers, body })
      if (outcome.ok || outcome.status < 500) {
        // En avvisning er databasens avgjørelse og ikke noe å prøve om igjen.
        return nothing()
      }
    } catch {
      // Et brudd i nettet mellom ruten og databasen. Verdt ett forsøk til.
    }
  }
  return nothing()
}
