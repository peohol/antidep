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
// Svaret sier to ting, og ikke én til
//
// 204 betyr *ferdig behandlet*: lagret, eller avvist av databasen — en
// avvisning er et endelig svar, og et nytt forsøk ville gitt det samme. 503
// betyr *ikke lagret, prøv igjen*: transporten videre sviktet uten at databasen
// svarte.
//
// Skillet er ikke kosmetikk. Nettleseren beholder observasjonen i utboksen til
// leveringen er bekreftet, og en rute som svarte 204 på en mislykket lagring,
// ville fått den til å slette årsaken den nettopp skulle berge — den samme
// tapsmåten utboksen finnes for å fjerne.
//
// Utover de to sier svaret ingenting. Om tokenen var gyldig, om kvoten var
// brukt opp, om raden allerede fantes: alt er 204. En rute som skilte dem, ville
// vært et sted å prøve seg fram fra utsiden. Grunnen står i kjøreloggen, som er
// privat.
// ============================================================================

import { createClient } from '@supabase/supabase-js'

import type { Database } from '../types/database.ts'
import { parseDiagnosticEnvelope, scrubDetail, MAX_DETAIL_CHARS } from './envelope.ts'

/** Den delen av miljøet ruten leser. Samme verdier som resten av utrullingen. */
export interface DiagnosticsEnvironment {
  readonly ANTIDEP_SUPABASE_URL?: string | undefined
  readonly ANTIDEP_SUPABASE_PUBLISHABLE_KEY?: string | undefined
  readonly VITE_SUPABASE_URL?: string | undefined
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string | undefined
}

/** Hvem kallet gjøres som, og mot hva. */
export interface ForwardTarget {
  readonly url: string
  readonly publishableKey: string
  /** Brukerens egen token, videresendt. Ruten har ingen av sine egne. */
  readonly accessToken: string
}

/**
 * Å sende det videre til databasen. Injiserbar, slik at en prøve slipper nettet.
 *
 * `retry` sier om det er verdt et forsøk til: en svikt uten kode er transporten
 * selv, mens en kode er databasens svar, og et svar skal ikke gjentas.
 */
export type ForwardDiagnostic = (
  target: ForwardTarget,
  args: Record<string, unknown>,
) => Promise<{ readonly delivered: boolean; readonly retry: boolean }>

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

/**
 * Den ekte veien videre, gjennom den samme klienten resten av Antidep bruker.
 *
 * Ikke et håndskrevet REST-kall: skjemavalget, nøkkelen og hodene er konvensjon
 * denne klienten allerede eier, og en egen kopi av dem ville vært en kopi å ta
 * feil i. Klienten er bare konfigurasjon og lages per kall — den holder ingen
 * tilstand å gjenbruke.
 */
const supabaseForward: ForwardDiagnostic = async (target, args) => {
  const client = createClient<Database, 'api'>(target.url, target.publishableKey, {
    db: { schema: 'api' },
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${target.accessToken}` } },
  })
  const { error } = await client.rpc('record_client_diagnostic', args as never)
  if (error === null) {
    return { delivered: true, retry: false }
  }
  // En kode betyr at databasen svarte — en avvisning er dens avgjørelse, og
  // ikke noe å prøve om igjen. Uten kode er det transporten som sviktet.
  const answered = typeof error.code === 'string' && error.code.length > 0
  return { delivered: false, retry: !answered }
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
  forward: ForwardDiagnostic = supabaseForward,
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

  let target: ForwardTarget
  try {
    target = {
      url: pick(env, ['ANTIDEP_SUPABASE_URL', 'VITE_SUPABASE_URL']),
      publishableKey: pick(env, [
        'ANTIDEP_SUPABASE_PUBLISHABLE_KEY',
        'VITE_SUPABASE_PUBLISHABLE_KEY',
      ]),
      accessToken: envelope.accessToken,
    }
  } catch {
    return new Response(null, { status: 503 })
  }

  const args = {
    p_event_id: envelope.eventId,
    p_area: envelope.area,
    p_kind: envelope.kind,
    p_operation: envelope.operation,
    p_code: envelope.code,
    p_http_status: envelope.httpStatus,
    p_transport: envelope.transport,
    // Vaskes også her, uavhengig av hva nettleseren gjorde. Databasen vasker
    // uansett; dette er den samme grensen ett ledd tidligere, for en kaller vi
    // ikke kontrollerer.
    p_detail: scrubDetail(envelope.detail).slice(0, MAX_DETAIL_CHARS),
  }

  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const outcome = await forward(target, args)
      if (outcome.delivered || !outcome.retry) {
        // Levert, eller avvist av databasen. En avvisning er dens avgjørelse,
        // og et nytt forsøk ville gitt det samme svaret.
        return nothing()
      }
    } catch {
      // Et brudd i nettet mellom ruten og databasen. Verdt ett forsøk til.
    }
  }

  // Ikke lagret. Nettleseren må beholde observasjonen — den er det eneste
  // stedet den finnes nå.
  return new Response(null, { status: 503 })
}
