// ============================================================================
// Den redaksjonelle handlingen som publiserer én påstandsrevisjon
//
// Ett kall til `api.publish_claim_revision(...)` (migrasjon 006h).
//
// ----------------------------------------------------------------------------
// Klienten avgjør ikke om revisjonen kan publiseres
//
// Publiseringsgaten kjøres av databasen, inne i den transaksjonen som skriver
// hendelsen, etter at låsene er tatt. Denne modulen regner ingenting ut på
// forhånd: en kontroll her ville vært en andre formulering av gaten, og den
// ville uansett ikke vært en garanti — grunnlaget kan endre seg mellom en
// forhåndskontroll og selve publiseringen.
//
// Flaten leser gatens svar gjennom `api.claim_review_workspace(uuid)`, som
// kaller gaten på ekte. Det er en visning av tilstanden, ikke en beslutning om
// den, og det er derfor ufarlig at den kan være foreldet når knappen trykkes:
// databasen avgjør på nytt.
//
// ----------------------------------------------------------------------------
// Publisher-aktøren er ikke en parameter
//
// Den utledes av databasen fra den innloggede brukerens egen aktørrad. En
// kallerstyrt aktør ville gjort attribusjonen til en påstand fra den som
// skriver framfor en observasjon (ANTIDEP_CONSTITUTION.md §14).
// ============================================================================

import type { AntidepClient } from './supabase'
import type { Uuid } from '../types/api'

export interface PublishClaimRevisionInput {
  readonly claimRevisionId: Uuid
  /** Påkrevd av databasen: en publisering uten begrunnelse er ikke etterprøvbar. */
  readonly reason: string
}

export type PublishClaimRevisionResult =
  | { readonly status: 'ok'; readonly publicationEventId: Uuid }
  | { readonly status: 'error'; readonly message: string }

/** Kaller `api.publish_claim_revision(...)` og gir databasens svar uendret. */
export async function publishClaimRevision(
  client: AntidepClient,
  input: PublishClaimRevisionInput,
): Promise<PublishClaimRevisionResult> {
  const { data, error } = await client.rpc('publish_claim_revision', {
    p_claim_revision_id: input.claimRevisionId,
    p_reason: input.reason,
  })
  if (error !== null) {
    return { status: 'error', message: error.message }
  }
  return { status: 'ok', publicationEventId: data }
}
