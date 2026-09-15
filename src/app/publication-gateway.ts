// ============================================================================
// Klinikerflatens og publiseringshandlingenes eneste vei til databasen
//
// Samme form som `candidate-gateway.ts`, og av samme grunn: flaten skal kunne
// prøves uten en Supabase-stack, og en komponent som kalte `getAntidepClient()`
// direkte, kunne ikke det.
//
// ----------------------------------------------------------------------------
// Hvorfor avtrykket sendes tilbake uendret
//
// Publiseringen og rollbacken gjelder nøyaktig det innholdet flaten viste
// (ANTIDEP_CONSTITUTION.md regel 5, 6). Avtrykket sendes derfor med, og
// databasen krever at det er kandidatens eget *og* at kandidaten fortsatt er den
// gjeldende. Flaten regner ikke ut noe avtrykk selv: en verdi klienten kunne
// beregne, ville vært en påstand om seg selv.
//
// ----------------------------------------------------------------------------
// Hvorfor avvisningene når fram ordrett
//
// Databasens feilmeldinger sier hva som må gjøres — bygg kandidaten på nytt, få
// den sluttkontrollert, be om publisher-mandat. En flate som erstattet dem med
// «noe gikk galt», ville tatt bort nettopp det som gjør en avvisning nyttig.
// ============================================================================

import { getAntidepClient } from '../lib/supabase'
import {
  parsePublicationOutcome,
  parsePublishedClaim,
  parsePublishedClaimIndex,
  type PublicationOutcome,
  type PublishedClaimEntry,
  type PublishedClaimView,
} from '../lib/published-claim'

export interface PublicationGateway {
  listPublished(): Promise<readonly PublishedClaimEntry[]>
  readPublished(claimId: string): Promise<PublishedClaimView>
  publish(input: {
    readonly candidateId: string
    readonly seenCandidateDigest: string
    readonly reason: string
  }): Promise<PublicationOutcome>
  withdraw(input: {
    readonly claimId: string
    readonly reason: string
  }): Promise<PublicationOutcome>
  rollback(input: {
    readonly claimId: string
    readonly targetCandidateId: string
    readonly seenCandidateDigest: string
    readonly reason: string
  }): Promise<PublicationOutcome>
}

/** Avvisninger fra databasen når fram uendret: de sier hva som må gjøres. */
function rejected(operation: string, message: string): Error {
  return new Error(`${operation}: ${message}`)
}

export function createPublicationGateway(): PublicationGateway {
  const client = getAntidepClient()

  return {
    async listPublished() {
      const { data, error } = await client.rpc('published_claim_index', {})
      if (error !== null) {
        throw rejected('Den publiserte katalogen kunne ikke leses', error.message)
      }
      return parsePublishedClaimIndex(data)
    },

    async readPublished(claimId) {
      const { data, error } = await client.rpc('published_claim', { p_claim_id: claimId })
      if (error !== null) {
        throw rejected('Det publiserte innholdet kunne ikke leses', error.message)
      }
      return parsePublishedClaim(data)
    },

    async publish(input) {
      const { data, error } = await client.rpc('publish_candidate', {
        p_candidate_id: input.candidateId,
        // Uendret fra det flaten viste. Databasen avviser et annet avtrykk, og
        // avviser også en kandidat som ikke lenger er den gjeldende.
        p_seen_candidate_digest: input.seenCandidateDigest,
        p_reason: input.reason,
      })
      if (error !== null) {
        throw rejected('Publiseringen ble ikke registrert', error.message)
      }
      return parsePublicationOutcome(data)
    },

    async withdraw(input) {
      const { data, error } = await client.rpc('withdraw_claim_publication', {
        p_claim_id: input.claimId,
        p_reason: input.reason,
      })
      if (error !== null) {
        throw rejected('Tilbaketrekkingen ble ikke registrert', error.message)
      }
      return parsePublicationOutcome(data)
    },

    async rollback(input) {
      const { data, error } = await client.rpc('rollback_claim_publication', {
        p_claim_id: input.claimId,
        p_target_candidate_id: input.targetCandidateId,
        p_seen_candidate_digest: input.seenCandidateDigest,
        p_reason: input.reason,
      })
      if (error !== null) {
        throw rejected('Rollbacken ble ikke registrert', error.message)
      }
      return parsePublicationOutcome(data)
    },
  }
}
