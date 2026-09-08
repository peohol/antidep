// ============================================================================
// Den kontrollerte skriveveien for en menneskelig claim-verifikasjon
//
// Ett kall til `api.register_human_claim_verification(...)` (migrasjon 005n).
// Ingen validering her utover formen skjemaet samler inn: constraintene og
// triggerne på `workflow.claim_verifications` er fasiten
// (DATABASE_ARCHITECTURE.md §43, §48, §57), ikke en kopi av dem i klienten.
//
// ----------------------------------------------------------------------------
// Ingen «du har lov»-boolean
//
// Samme doktrine som `create-evidence-item.ts`: modulen avgjør ikke om kalleren
// FÅR registrere en kontroll. Den sender forsøket og returnerer det databasen
// svarer — inkludert en avvisning fra `workflow.assert_reviewer_authorized(uuid)`
// eller fra radens egen mandatkontroll.
//
// ----------------------------------------------------------------------------
// Avtrykket sendes tilbake uendret
//
// `seenEvidenceSetDigest` er verdien flaten fikk fra
// `api.claim_review_workspace(uuid)`, sendt tilbake ordrett. Den er ikke en
// garanti klienten stiller — databasen sammenligner den med settet slik det er
// nå, og avviser hvis en evidenslenke er kommet til mens vurderingen pågikk.
// Klienten skal derfor verken beregne den, normalisere den eller finne på en.
// ============================================================================

import type { AntidepClient } from './supabase'
import type { Uuid } from '../types/api'

/** Én kontrollert evidenslenke, slik skriveveien tar imot den. */
export interface ClaimVerificationCitationInput {
  readonly claimEvidenceLinkId: Uuid
  readonly sourceAccess: string
  /** `null` når verifikatoren ikke hadde en registrert representasjon for lenken. */
  readonly sourceVersionId: Uuid | null
  readonly checkedContentHash: string | null
  readonly relationshipSupported: string
  /** Påkrevd av databasen når `relationshipSupported` ikke er `ok`. */
  readonly finding: string | null
}

export interface HumanClaimVerificationInput {
  readonly claimRevisionId: Uuid
  readonly seenEvidenceSetDigest: string
  readonly outcome: string
  readonly sourceSupport: string
  readonly populationMatch: string
  readonly comparatorMatch: string
  readonly timeframeMatch: string
  readonly directionAndMagnitude: string
  readonly qualifiersComplete: string
  readonly contradictoryEvidenceRepresented: string
  readonly citations: readonly ClaimVerificationCitationInput[]
  readonly rationale: string
  /** Påkrevd av databasen når utfallet ikke er `verified`. */
  readonly findings: string | null
}

export type HumanClaimVerificationResult =
  | { readonly status: 'ok'; readonly claimVerificationId: Uuid }
  | { readonly status: 'error'; readonly message: string }

/**
 * Kaller `api.register_human_claim_verification(...)`.
 *
 * Returnerer aldri en avvisning som et kastet unntak: flaten skal kunne vise
 * enhver avvisning — manglende rolle, endret evidenssett, en bekreftelse med et
 * ubedømt punkt — med databasens egen tekst, uten å måtte skille feiltyper fra
 * hverandre her.
 */
export async function registerHumanClaimVerification(
  client: AntidepClient,
  input: HumanClaimVerificationInput,
): Promise<HumanClaimVerificationResult> {
  const { data, error } = await client.rpc('register_human_claim_verification', {
    p_claim_revision_id: input.claimRevisionId,
    p_seen_evidence_set_digest: input.seenEvidenceSetDigest,
    p_outcome: input.outcome,
    p_source_support: input.sourceSupport,
    p_population_match: input.populationMatch,
    p_comparator_match: input.comparatorMatch,
    p_timeframe_match: input.timeframeMatch,
    p_direction_and_magnitude: input.directionAndMagnitude,
    p_qualifiers_complete: input.qualifiersComplete,
    p_contradictory_evidence_represented: input.contradictoryEvidenceRepresented,
    p_citations: input.citations.map((citation) => ({
      claim_evidence_link_id: citation.claimEvidenceLinkId,
      source_access: citation.sourceAccess,
      source_version_id: citation.sourceVersionId,
      checked_content_hash: citation.checkedContentHash,
      relationship_supported: citation.relationshipSupported,
      finding: citation.finding,
    })),
    p_rationale: input.rationale,
    p_findings: input.findings,
  })
  if (error !== null) {
    return { status: 'error', message: error.message }
  }
  return { status: 'ok', claimVerificationId: data }
}
