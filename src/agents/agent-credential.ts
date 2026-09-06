// ============================================================================
// Agentlegitimasjonen, og hvorfor den er pakket inn
//
// Hemmeligheten til `agent-identity:extraction-verification-01` finnes bare ett
// sted: i miljøet kjøreren leser den fra. Den skal aldri i repoet, aldri i en
// logg, aldri i et auditspor og aldri i et feilobjekt som skrives ut
// (CLAUDE.md, DATABASE_ARCHITECTURE.md §49).
//
// «Aldri» holder ikke som en regel man husker. Verdien ligger derfor bak
// `reveal()`, og både `toString()` og `toJSON()` gir en maskert tekst — så
// `console.log(credential)`, en interpolert feilmelding og
// `JSON.stringify({ credential })` alle er ufarlige. Den eneste måten å få tak
// i verdien på, er å be om den eksplisitt, og det gjør bare selve RPC-kallet.
// ============================================================================

const MASK = '[hemmelighet skjult]'

/** En hemmelighet som ikke lekker ved et uhell. */
export interface AgentSecret {
  /** Henter klartekstverdien. Skal bare kalles der den faktisk sendes. */
  reveal(): string
  toString(): string
  toJSON(): string
}

export function agentSecret(value: string): AgentSecret {
  return {
    reveal: () => value,
    toString: () => MASK,
    toJSON: () => MASK,
  }
}

/** Identiteten en agentkjøring handler med. Nøkkelen er ikke hemmelig. */
export interface AgentCredential {
  readonly identityKey: string
  readonly secret: AgentSecret
}

/**
 * Fjerner hemmeligheten fra en tekst før den logges.
 *
 * Andre linje i forsvaret: en feilmelding fra PostgREST eller fra `fetch` kan i
 * prinsippet gjengi det som ble sendt. Alt som skrives ut av runneren, går
 * gjennom denne.
 */
export function redact(text: string, secret: AgentSecret): string {
  const value = secret.reveal()
  return value.length === 0 ? text : text.replaceAll(value, MASK)
}
