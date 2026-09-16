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
// Hvorfor avvisningene ikke lenger når fram ordrett
//
// Denne filen sa tidligere det motsatte: at databasens feilmeldinger burde nå
// fram uendret, fordi de sier hva som må gjøres. Den vurderingen er omgjort
// (issue #99, punkt 8). Grunnen er ikke at setningene var dårlige, men at
// avsenderen ikke lot seg kontrollere: den samme veien bar også «JWT expired»,
// «permission denied for function …» og PostgREST-koder til en kliniker.
//
// Handlingen står fortsatt i setningen — bygg kandidaten på nytt, be om mandat,
// hent siden på nytt — men den er nå Antideps egen formulering, valgt av hva
// slags avvisning det var. Den rå årsaken går til observability (`gateway.ts`).
// ============================================================================

import { antidepClient, callRpc, type FailureWording, type TechnicalArea } from './gateway'
import {
  parsePublicationOutcome,
  parsePublishedClaim,
  parsePublishedClaimIndex,
  type PublicationOutcome,
  type PublishedClaimEntry,
  type PublishedClaimView,
} from '../lib/published-claim'

const AREA: TechnicalArea = 'clinical_content'

/** Setningene som gjelder en handling bundet til det avtrykket flaten viste. */
const SEALED_CONTENT_WORDING: FailureWording = {
  not_authorized: 'Du har ikke mandat til denne handlingen i Antidep.',
  not_found: 'Innholdet finnes ikke lenger slik du så det. Hent siden på nytt.',
  invalid_input: 'Antidep kunne ikke ta imot dette. Hent siden på nytt og prøv igjen.',
  rejected:
    'Grunnlaget er endret siden du åpnet siden, eller innholdet er ikke klart for dette ' +
    'steget. Hent siden på nytt; er innholdet endret, må det bygges og sluttkontrolleres på nytt.',
}

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

export function createPublicationGateway(): PublicationGateway {
  const client = antidepClient()

  return {
    async listPublished() {
      return callRpc(client, {
        fn: 'published_claim_index',
        area: AREA,
        parse: parsePublishedClaimIndex,
        wording: {
          not_authorized:
            'Publisert klinikerinnhold krever innlogging i Antidep. Logg inn og prøv igjen.',
          unavailable:
            'Antidep får ikke hentet det publiserte innholdet akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async readPublished(claimId) {
      return callRpc(client, {
        fn: 'published_claim',
        args: { p_claim_id: claimId },
        area: AREA,
        parse: parsePublishedClaim,
        wording: {
          not_authorized:
            'Publisert klinikerinnhold krever innlogging i Antidep. Logg inn og prøv igjen.',
          not_found: 'Antidep publiserer ikke dette innholdet nå.',
          unavailable: 'Antidep får ikke hentet innholdet akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async publish(input) {
      return callRpc(client, {
        fn: 'publish_candidate',
        args: {
          p_candidate_id: input.candidateId,
          // Uendret fra det flaten viste. Databasen avviser et annet avtrykk, og
          // avviser også en kandidat som ikke lenger er den gjeldende.
          p_seen_candidate_digest: input.seenCandidateDigest,
          p_reason: input.reason,
        },
        area: AREA,
        parse: parsePublicationOutcome,
        wording: {
          ...SEALED_CONTENT_WORDING,
          not_authorized: 'Publisering krever publisher-mandat, og du har det ikke i Antidep.',
          unavailable:
            'Publiseringen ble ikke registrert. Antidep svarte ikke. Prøv igjen om litt.',
        },
      })
    },

    async withdraw(input) {
      return callRpc(client, {
        fn: 'withdraw_claim_publication',
        args: { p_claim_id: input.claimId, p_reason: input.reason },
        area: AREA,
        parse: parsePublicationOutcome,
        wording: {
          ...SEALED_CONTENT_WORDING,
          not_authorized: 'Tilbaketrekking krever publisher-mandat, og du har det ikke i Antidep.',
          unavailable:
            'Tilbaketrekkingen ble ikke registrert. Antidep svarte ikke. Prøv igjen om litt.',
        },
      })
    },

    async rollback(input) {
      return callRpc(client, {
        fn: 'rollback_claim_publication',
        args: {
          p_claim_id: input.claimId,
          p_target_candidate_id: input.targetCandidateId,
          p_seen_candidate_digest: input.seenCandidateDigest,
          p_reason: input.reason,
        },
        area: AREA,
        parse: parsePublicationOutcome,
        wording: {
          ...SEALED_CONTENT_WORDING,
          not_authorized: 'Rollback krever publisher-mandat, og du har det ikke i Antidep.',
          unavailable: 'Rollbacken ble ikke registrert. Antidep svarte ikke. Prøv igjen om litt.',
        },
      })
    },
  }
}
