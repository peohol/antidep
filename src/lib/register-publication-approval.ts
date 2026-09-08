// ============================================================================
// Den kontrollerte skriveveien for en publiseringsgodkjenning
//
// Ett kall til `api.register_publication_approval(...)` (migrasjon 006d).
//
// ----------------------------------------------------------------------------
// Hvorfor dette er en egen modul og ikke et felt i den forrige
//
// Den faglige kontrollen mot grunnlaget (ANTIDEP_CONSTITUTION.md §11) og
// beslutningen om at påstanden kan publiseres (§12) er to forskjellige faglige
// utsagn, lagret som to beslutningsobjekter i to tabeller, og publiseringsgaten
// krever dem hver for seg (G9 og G11). To skriveveier, to moduler, to knapper i
// flaten — en samlet «godkjenn alt» ville slått sammen to vurderinger til én.
//
// `seenEvidenceSetDigest` sendes tilbake uendret, av samme grunn som i
// `register-human-claim-verification.ts`.
// ============================================================================

import type { AntidepClient } from './supabase'
import type { Uuid } from '../types/api'

export interface PublicationApprovalInput {
  readonly claimRevisionId: Uuid
  readonly seenEvidenceSetDigest: string
  /** `approved`, `rejected` eller `changes_requested`. Alle tre bevares. */
  readonly decision: string
  readonly rationale: string
}

export type PublicationApprovalResult =
  | { readonly status: 'ok'; readonly reviewDecisionId: Uuid }
  | { readonly status: 'error'; readonly message: string }

/** Kaller `api.register_publication_approval(...)` og gir databasens svar uendret. */
export async function registerPublicationApproval(
  client: AntidepClient,
  input: PublicationApprovalInput,
): Promise<PublicationApprovalResult> {
  const { data, error } = await client.rpc('register_publication_approval', {
    p_claim_revision_id: input.claimRevisionId,
    p_seen_evidence_set_digest: input.seenEvidenceSetDigest,
    p_decision: input.decision,
    p_rationale: input.rationale,
  })
  if (error !== null) {
    return { status: 'error', message: error.message }
  }
  return { status: 'ok', reviewDecisionId: data }
}
