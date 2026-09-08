// ============================================================================
// Den kontrollerte skriveveien for en menneskelig ekstraksjonskontroll
//
// Ett kall til `api.register_human_extraction_verification(...)` (migrasjon
// 005s). Ingen validering her utover formen skjemaet samler inn: constraintene
// og triggerne på `workflow.evidence_verifications` er fasiten
// (DATABASE_ARCHITECTURE.md §29, §43, §57), ikke en kopi av dem i klienten.
//
// ----------------------------------------------------------------------------
// Ingen «du har lov»-boolean
//
// Samme doktrine som `register-human-claim-verification.ts`: modulen avgjør ikke
// om kalleren FÅR registrere en kontroll. Den sender forsøket og returnerer det
// databasen svarer — inkludert en avvisning fra
// `workflow.assert_reviewer_authorized(uuid)` eller fra radens egen
// mandatkontroll.
//
// ----------------------------------------------------------------------------
// Avtrykket sendes tilbake uendret
//
// `seenExtractionDigest` er verdien flaten fikk fra
// `api.extraction_review_workspace(uuid)`, sendt tilbake ordrett. Den er ikke en
// garanti klienten stiller — databasen sammenligner den med grunnlaget slik det
// er nå, under radlåsen, og avviser hvis kildeversjonen, kildens status eller
// kontrollhistorikken er endret mens vurderingen pågikk. Klienten skal derfor
// verken beregne den, normalisere den eller finne på en.
// ============================================================================

import type { AntidepClient } from './supabase'
import type { Uuid } from '../types/api'

export interface HumanExtractionVerificationInput {
  readonly evidenceItemId: Uuid
  readonly seenExtractionDigest: string
  readonly outcome: string
  readonly sourceAccess: string
  /** Feltene revieweren faktisk gikk gjennom. Databasen avviser en tom liste. */
  readonly checkedFields: readonly string[]
  readonly rationale: string
  /** Påkrevd av databasen når utfallet ikke er `verified`. */
  readonly findings: string | null
}

export type HumanExtractionVerificationResult =
  | { readonly status: 'ok'; readonly evidenceVerificationId: Uuid }
  | { readonly status: 'error'; readonly message: string }

/**
 * Kaller `api.register_human_extraction_verification(...)`.
 *
 * Returnerer aldri en avvisning som et kastet unntak: flaten skal kunne vise
 * enhver avvisning — manglende rolle, endret grunnlag, en bekreftelse uten
 * kontrollert kildepeker — med databasens egen tekst, uten å måtte skille
 * feiltyper fra hverandre her.
 */
export async function registerHumanExtractionVerification(
  client: AntidepClient,
  input: HumanExtractionVerificationInput,
): Promise<HumanExtractionVerificationResult> {
  const { data, error } = await client.rpc('register_human_extraction_verification', {
    p_evidence_item_id: input.evidenceItemId,
    p_seen_extraction_digest: input.seenExtractionDigest,
    p_outcome: input.outcome,
    p_source_access: input.sourceAccess,
    p_checked_fields: [...input.checkedFields],
    p_rationale: input.rationale,
    p_findings: input.findings,
  })
  if (error !== null) {
    return { status: 'error', message: error.message }
  }
  return { status: 'ok', evidenceVerificationId: data }
}
