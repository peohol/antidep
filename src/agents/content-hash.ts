// ============================================================================
// Fingeravtrykket av en hentet representasjon
//
// Motstykket til `knowledge.source_version_content_hash(text)` (migrasjon
// 20260907091000): sha256 av representasjonen, UTF-8-kodet, med algoritmen som
// prefiks. De to skal alltid gi samme svar for samme tekst, og at de gjør det
// er festet som en assertion i `src/agents/content-hash.test.ts` mot en kjent
// referanseverdi — den samme `printf 'antidep' | sha256sum` gir.
//
// Hvorfor funksjonen finnes her og ikke bare i databasen: verifikatoren henter
// kilden på nytt og må kunne regne ut hashen selv for å sammenligne. Kunne den
// bare spurt databasen, ville kontrollen vært «databasen sier at databasens
// egen verdi stemmer», altså ingen kontroll.
//
// Web Crypto og ikke `node:crypto`: den samme koden skal kunne kjøre i en
// nettleser, i Node og i en runner uten at algoritmen bytter implementasjon.
// ============================================================================

/** Prefikset `knowledge.source_versions.content_hash` krever (migrasjon 003). */
export const CONTENT_HASH_PREFIX = 'sha256:'

const encoder = new TextEncoder()

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
}

/**
 * sha256 av teksten slik den er, UTF-8-kodet.
 *
 * Ingen normalisering: ingen trimming, ingen linjeskiftkonvertering, ingen
 * reserialisering. Verdien skal kunne reproduseres med `sha256sum` på svaret
 * fra `retrieved_from` av hvem som helst, uten å kjenne til noen kanonisk form
 * — det er hele grunnen til at hashen er etterprøvbar.
 */
export async function sourceVersionContentHash(content: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(content))
  return CONTENT_HASH_PREFIX + toHex(digest)
}

/** Om en verdi har formen `knowledge.source_versions.content_hash` krever. */
export function isContentHash(value: string): boolean {
  return /^sha256:[0-9a-f]{64}$/.test(value)
}
