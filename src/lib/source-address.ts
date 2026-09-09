// ============================================================================
// Adressen kilden ble hentet fra, gjort trykkbar — eller sagt at den ikke er det
//
// `knowledge.source_versions.retrieved_from` er tekst, ikke en URL-type: en
// kildeversjon kan være hentet fra et sted som ikke har en adresse en nettleser
// kan åpne, for eksempel et arkivsignatur eller en papirutgave. Kolonnen er
// derfor fri tekst, og hva den er, avgjøres her.
//
// ----------------------------------------------------------------------------
// Hvorfor bare http og https
//
// En lenke bygget av data er en angrepsflate: `javascript:` og `data:` i en
// href kjører i sidens egen opprinnelse. Kildeadresser er registrert av
// mennesker og agenter og skal behandles som utrygg inndata (CLAUDE.md), så
// bare de to skjemaene som faktisk peker på et dokument, blir til en lenke.
// Alt annet vises som det står — aldri skjult, aldri trykkbart.
// ============================================================================

/** En adresse som kan åpnes, eller en tekst som bare kan leses. */
export type SourceAddress =
  | { readonly kind: 'link'; readonly href: string; readonly text: string }
  | { readonly kind: 'text'; readonly text: string }

const OPENABLE_PROTOCOLS = new Set(['http:', 'https:'])

/**
 * Hva adressen er.
 *
 * `null` og tom tekst er fravær, og fravær er ikke en tom lenke: en flate som
 * viste en trykkbar lenke uten mål, ville lovet kontrolløren en vei til kilden
 * som ikke finnes.
 */
export function describeSourceAddress(raw: string | null): SourceAddress | null {
  if (raw === null) {
    return null
  }
  const trimmed = raw.trim()
  if (trimmed.length === 0) {
    return null
  }
  let parsed: URL
  try {
    parsed = new URL(trimmed)
  } catch {
    return { kind: 'text', text: trimmed }
  }
  return OPENABLE_PROTOCOLS.has(parsed.protocol)
    ? { kind: 'link', href: parsed.href, text: trimmed }
    : { kind: 'text', text: trimmed }
}
