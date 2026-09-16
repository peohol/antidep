// ============================================================================
// Den private kanalen den rå årsaken går til
//
// `src/app/gateway.ts` sender to helt forskjellige ting to helt forskjellige
// veier. Til databasen går maskinidentifikatorer — område, svikttype,
// api-funksjon, kode, HTTP-status, transportform — og aldri en feiltekst: den
// tekniske loggen i produktdatabasen skal ikke bli et sted en videreformidlet
// feilmelding kan bære et filnavn, en adresse eller en del av et svar.
//
// Men klassifiseringen er ikke diagnosen. En teknisk agent som skal finne ut
// *hvorfor* et kall sviktet, trenger stacken og den rå meldingen, og en
// `console.error` i en nettleser er ingen varig kanal: fanen lukkes, og da er
// årsaken borte (issue #99, punkt 8).
//
// ----------------------------------------------------------------------------
// Hvorfor dette er et endepunkt og ikke en tabell
//
// Den rå årsaken hører ikke hjemme i Antideps egen database. Den er ikke
// klinisk innhold, den har ingen proveniens, og et fritekstfelt en nettleser
// kan skrive til, ville vært nettopp den samlingsplassen regelen over finnes
// for å unngå. Den hører heller ikke hjemme på den samme RPC-veien som nettopp
// kan være nede — en diagnostikk som forsvinner sammen med det den skal
// forklare, er ingen diagnostikk.
//
// Kanalen er derfor et eget endepunkt, valgt i deployen. Det er et driftsvalg
// og ingen produktflate: hvilken observability-tjeneste Antidep bruker, er
// nøyaktig den typen teknisk beslutning issue #99 sier hører hjemme utenfor
// klinikerens grensesnitt.
//
// ----------------------------------------------------------------------------
// Av som standard, og trygt når det er av
//
// Uten `VITE_ANTIDEP_DIAGNOSTICS_URL` går ingenting ut av nettleseren. Da er
// oppførselen nøyaktig som før: én linje i konsollen, til den som feilsøker
// lokalt. Konsollen skrives til uansett, fordi den er det eneste som virker når
// endepunktet selv er nede.
// ============================================================================

import type { TechnicalDetail } from './gateway'

/** Den delen av miljøet kanalen leser. Injiseres for å kunne testes. */
export interface DiagnosticsEnv {
  readonly VITE_ANTIDEP_DIAGNOSTICS_URL?: string | undefined
}

/**
 * Adressen den rå årsaken sendes til, eller `null` når ingen er valgt.
 *
 * Krever https, fordi innholdet er nettopp det som ikke skal leses av andre
 * underveis. Unntaket er localhost, der det ikke finnes noe «underveis» — og
 * der en utvikler skal kunne se hva som faktisk sendes.
 *
 * Feiler høyt på en verdi som er satt men ugyldig. En diagnostikk-kanal som
 * stille lot være å virke, ville vært verre enn ingen: den som satte
 * variabelen, ville trodd årsakene ble bevart.
 */
export function readDiagnosticsEndpoint(env: DiagnosticsEnv): string | null {
  const value = env.VITE_ANTIDEP_DIAGNOSTICS_URL?.trim()
  if (value === undefined || value.length === 0) {
    return null
  }

  let parsed: URL
  try {
    parsed = new URL(value)
  } catch {
    throw new Error(`VITE_ANTIDEP_DIAGNOSTICS_URL er ikke en gyldig URL: «${value}».`)
  }

  const local = parsed.hostname === 'localhost' || parsed.hostname === '127.0.0.1'
  if (parsed.protocol !== 'https:' && !(parsed.protocol === 'http:' && local)) {
    throw new Error(
      'VITE_ANTIDEP_DIAGNOSTICS_URL må bruke https. Den rå årsaken er nettopp det som ikke ' +
        'skal kunne leses av andre underveis.',
    )
  }
  return parsed.toString()
}

/** Én observasjon slik den ser ut på vei ut av nettleseren. */
export interface DiagnosticsEnvelope extends TechnicalDetail {
  readonly occurredAt: string
}

/** Å sende én konvolutt. Egen type slik at en prøve kan sende inn sin egen. */
export type SendDiagnostics = (endpoint: string, body: string) => void

const sendWithFetch: SendDiagnostics = (endpoint, body) => {
  // `keepalive` slik at en observasjon rett før en navigasjon ikke går tapt —
  // og det er ofte nettopp da den kommer.
  void fetch(endpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body,
    keepalive: true,
    mode: 'cors',
  }).then(
    () => undefined,
    // Feiler kanalen, er det ingenting mer å gjøre. Den skal aldri bli en ny
    // feil på toppen av den som allerede er vist.
    () => undefined,
  )
}

/**
 * Sluket flaten faktisk bruker.
 *
 * Konsollen skrives til uansett: den virker når endepunktet ikke gjør det, og
 * den er det den som feilsøker lokalt leser. Endepunktet er det varige.
 */
export function createDiagnosticsSink(
  endpoint: string | null,
  send: SendDiagnostics = sendWithFetch,
): (entry: TechnicalDetail) => void {
  return (entry) => {
    // Én linje, strukturert, med et prefiks som kan søkes etter. Dette er
    // diagnostikk for Claude Code og ChatGPT, ikke noe et menneske leser i UI.
    console.error('[antidep:teknisk]', entry)

    if (endpoint === null) {
      return
    }
    const envelope: DiagnosticsEnvelope = { ...entry, occurredAt: new Date().toISOString() }
    try {
      send(endpoint, JSON.stringify(envelope))
    } catch {
      // En konvolutt som ikke lot seg pakke, skal ikke stoppe flaten.
    }
  }
}
