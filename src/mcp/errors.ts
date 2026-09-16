// ============================================================================
// Feilformene MCP-laget kjenner
//
// Tre, og de betyr forskjellige ting for den som skal finne ut hvorfor en
// planlagt kjøring stoppet:
//
//   McpHttpError       protokollen eller adressen var gal — svares med en
//                      HTTP-status, ikke med et JSON-RPC-svar
//   UnauthorizedError  tokenet mangler, er utløpt eller er trukket tilbake.
//                      Svares med 401 og den henvisningen MCP-klienten trenger
//                      for å begynne en ny autorisasjon (RFC 9728)
//   GatewayError       databasen avviste noe. Bærer SQLSTATE-en, slik at
//                      utfallsklassen kan utledes uten å lese feilteksten
//
// ----------------------------------------------------------------------------
// Hvorfor feilteksten aldri logges
//
// En avvisning fra den autoritative kontrollen kan navngi en påstand, et
// kildeutdrag eller en formulering fra artikkelen. Teksten hører hjemme i svaret
// til den agenten som nettopp leste oppgaven, og ingen andre steder: sporet
// bærer utfallsklassen, og aldri setningen (ANTIDEP_CONSTITUTION.md regel 2, 4).
// ============================================================================

/** Utfallsklassene sporet kjenner. Samme vokabular som `workflow.agent_runner_outcome`. */
export const RUNNER_OUTCOMES = [
  'ok',
  'no_work',
  'blocked',
  'stale_task',
  'wrong_role',
  'lease_lost',
  'rejected',
  'approval_blocked',
  'server_error',
] as const

export type RunnerOutcome = (typeof RUNNER_OUTCOMES)[number]

/** En feil som skal bli en HTTP-status framfor et JSON-RPC-svar. */
export class McpHttpError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.name = 'McpHttpError'
    this.status = status
  }
}

/** Tokenet mangler eller holder ikke. Svares med 401 og en henvisning. */
export class UnauthorizedError extends Error {
  constructor(message = 'Tilkoblingen er ikke autentisert.') {
    super(message)
    this.name = 'UnauthorizedError'
  }
}

/** Databasen avviste noe. SQLSTATE-en bærer klassen; teksten bærer forklaringen. */
export class GatewayError extends Error {
  /** SQLSTATE fra PostgreSQL, når PostgREST oppga en. */
  readonly code: string | null

  constructor(message: string, code: string | null) {
    super(message)
    this.name = 'GatewayError'
    this.code = code
  }
}

/**
 * Om en feil betyr at legitimasjonen ikke holder lenger.
 *
 * Ett sted, fordi den er avgjørende to steder som ellers ville kunnet bli
 * uenige: verktøylaget må la den passere, og transporten må gjøre den om til
 * 401 med henvisningen klienten trenger for å fornye (RFC 9728). Ble den
 * fanget som en vanlig verktøyfeil, ville svaret vært 200 — og en klient som
 * ikke får 401, vet ikke at den skal fornye i det hele tatt.
 *
 * `42501` er `insufficient_privilege`: databasen kontrollerer tokenet på nytt
 * i hvert kall, så det er dette den svarer når tokenet løp ut eller
 * tilkoblingen ble trukket tilbake MELLOM autentiseringen og verktøykallet.
 */
export function isAuthenticationFailure(error: unknown): error is UnauthorizedError | GatewayError {
  return (
    error instanceof UnauthorizedError || (error instanceof GatewayError && error.code === '42501')
  )
}

/**
 * Utfallsklassen en avvisning hører til.
 *
 * Utledet av SQLSTATE og aldri av teksten. En klassifisering som leste
 * meldingen, ville endret seg neste gang noen omformulerte en setning — og den
 * samme meldingen ville måttet stå i loggen for at klassen skulle gi mening.
 */
export function outcomeForError(error: unknown): RunnerOutcome {
  if (error instanceof UnauthorizedError) {
    return 'server_error'
  }
  if (error instanceof GatewayError) {
    switch (error.code) {
      // insufficient_privilege: tokenet holder ikke.
      case '42501':
        return 'server_error'
      // restrict_violation og invalid_parameter_value: den autoritative
      // kontrollen sa nei til nettopp dette svaret.
      case '23001':
      case '22023':
      case '23505':
        return 'rejected'
      default:
        return 'server_error'
    }
  }
  return 'server_error'
}
