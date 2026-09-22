// ============================================================================
// Loggen MCP-serveren skriver
//
// Nok til å forstå hvorfor autonomien stoppet, og ikke ett tegn mer. Én linje
// per kall, som JSON, med verktøynavnet, ruten, utfallsklassen og varigheten.
//
// Aldri: artikkelens fulltekst, hele modellsvaret, access- eller refresh-tokens,
// tilkoblingskoder, autorisasjonskoder, cookies eller en videreformidlet
// feiltekst fra databasen. En avvisning kan navngi en påstand eller et
// kildeutdrag, og teksten hører hjemme i svaret til den agenten som nettopp leste
// oppgaven — ikke i en driftslogg (ANTIDEP_CONSTITUTION.md regel 2, 7).
//
// Det er derfor utfallsklassen er et eget vokabular og ikke en setning: klassen
// er nok til å skille «ingen arbeid» fra «faglig blokkert», «foreldet oppgave»,
// «feil rolle», «auth-feil», «plattformen krevde godkjenning» og «teknisk feil»,
// og ingen av dem trenger et sitat for å bety noe.
// ============================================================================

import type { RunnerOutcome } from './errors.ts'

export interface RunnerLogRecord {
  readonly route: string
  /**
   * Opprinnelsen forespørselen oppga, og bare der den ble avvist.
   *
   * En 403 uten navnet på det som ble avvist, er ikke til å feilsøke: det er
   * nettopp adressen som skiller en klient ingen har listet opp fra et forsøk
   * utenfra. Verdien er kanonisk og bundet i lengde, og kommer fra
   * `loggableOrigin` — ikke fra headeren slik den sto. En logg som står foran
   * autentiseringen, skal ikke kunne fylles med kallerens egne tegn.
   */
  readonly origin?: string | undefined
  readonly tool?: string | undefined
  readonly outcome: RunnerOutcome | 'auth_failed' | 'bad_request'
  readonly status: number
  readonly durationMs: number
}

export type RunnerLogger = (record: RunnerLogRecord) => void

/** Standardloggeren: én JSON-linje, uten et eneste felt som kan bære innhold. */
export const consoleRunnerLogger: RunnerLogger = (record) => {
  console.log(
    JSON.stringify({
      at: new Date().toISOString(),
      component: 'antidep-mcp',
      route: record.route,
      origin: record.origin ?? null,
      tool: record.tool ?? null,
      outcome: record.outcome,
      status: record.status,
      duration_ms: record.durationMs,
    }),
  )
}

/** En logger som ikke skriver noe. Brukes av prøvene. */
export const silentRunnerLogger: RunnerLogger = () => undefined
