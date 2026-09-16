// ============================================================================
// Kandidatflatens eneste vei til databasen
//
// Flaten skal kunne prøves uten en Supabase-stack, og en komponent som kalte
// `getAntidepClient()` direkte, kunne ikke det. De fire kallene ligger derfor
// bak én grenseflate, og komponenten kjenner bare den.
//
// ----------------------------------------------------------------------------
// Hvorfor avtrykket sendes tilbake uendret
//
// Sluttkontrollen er bundet til nøyaktig den kandidaten som ble lest
// (ANTIDEP_CONSTITUTION.md regel 5). Avtrykket flaten faktisk viste, sendes
// derfor med beslutningen, og databasen krever at det er kandidatens eget *og*
// at innholdet fortsatt bygger til det. Flaten regner ikke ut noe avtrykk selv:
// en verdi klienten kunne beregne, ville vært en påstand om seg selv.
//
// ----------------------------------------------------------------------------
// Hvorfor avvisningene ikke lenger når fram ordrett
//
// Tidligere gikk databasens melding rett til siden. Den var ofte god — «bygg
// kandidaten på nytt», «be om publisher-mandat» — men den var like ofte
// PostgreSQL, PostgREST eller Supabase som formulerte den, og de to lar seg
// ikke skille pålitelig fra utsiden (issue #99, punkt 8). Flaten skriver derfor
// setningen selv, valgt av *hva slags* avvisning det var, og den rå årsaken går
// til observability (`gateway.ts`). Handlingen den som står her skal gjøre, står
// fortsatt i setningen — den kommer bare fra Antidep og ikke fra databasen.
// ============================================================================

import { antidepClient, callRpc, type FailureWording, type TechnicalArea } from './gateway'
import { parseCandidateView, type CandidateView } from '../lib/candidate-view'
import { parsePublicationOutcome, type PublicationOutcome } from '../lib/published-claim'

const AREA: TechnicalArea = 'clinical_content'

/**
 * Setningene som gjelder en avgjørelse bundet til det avtrykket flaten viste.
 *
 * En avvisning her betyr nesten alltid det samme: grunnlaget er endret siden
 * siden ble åpnet, og kandidaten må bygges og godkjennes på nytt.
 */
const SEALED_CONTENT_WORDING: FailureWording = {
  not_authorized: 'Du har ikke mandat til denne handlingen i Antidep.',
  not_found: 'Innholdet finnes ikke lenger slik du så det. Hent siden på nytt.',
  invalid_input: 'Antidep kunne ikke ta imot dette. Hent siden på nytt og prøv igjen.',
  rejected:
    'Grunnlaget er endret siden du åpnet siden, eller innholdet er ikke klart for dette ' +
    'steget. Hent siden på nytt; er innholdet endret, må det bygges og sluttkontrolleres på nytt.',
}

/** Én rad i køen: nok til å velge én kandidat, ikke nok til å vurdere den. */
export interface CandidateQueueEntry {
  readonly candidateId: string
  readonly statement: string
  readonly subjectDrug: string
  readonly topic: string
  readonly certaintyLevel: string | null
  readonly sourceCount: number
  readonly finalControlCount: number
  readonly builtAt: string
}

export interface CandidateGateway {
  listQueue(): Promise<readonly CandidateQueueEntry[]>
  read(candidateId: string): Promise<CandidateView>
  recordFinalControl(input: {
    readonly candidateId: string
    readonly seenCandidateDigest: string
    readonly decision: string
    readonly rationale: string
  }): Promise<void>
  /**
   * Publiseringen av nøyaktig denne kandidaten.
   *
   * En egen, eksplisitt handling etter sluttkontrollen, med et annet mandat. Den
   * ligger på den samme grenseflaten fordi den utføres fra den samme siden —
   * ikke fordi den er den samme handlingen.
   */
  publish(input: {
    readonly candidateId: string
    readonly seenCandidateDigest: string
    readonly reason: string
  }): Promise<PublicationOutcome>
}

function queueEntry(value: unknown, index: number): CandidateQueueEntry {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`Køen er ugyldig: rad ${String(index)} er ikke et objekt.`)
  }
  const record = value as Record<string, unknown>
  const required = (key: string): string => {
    const entry = record[key]
    if (typeof entry !== 'string' || entry.length === 0) {
      throw new Error(`Køen er ugyldig: rad ${String(index)}.${key} mangler.`)
    }
    return entry
  }
  const certainty = record['certainty_level']
  return {
    candidateId: required('candidate_id'),
    statement: required('statement'),
    subjectDrug: required('subject_drug'),
    topic: required('topic'),
    certaintyLevel: typeof certainty === 'string' ? certainty : null,
    sourceCount: typeof record['source_count'] === 'number' ? record['source_count'] : 0,
    finalControlCount:
      typeof record['final_control_count'] === 'number' ? record['final_control_count'] : 0,
    builtAt: required('built_at'),
  }
}

function parseQueue(data: unknown): readonly CandidateQueueEntry[] {
  if (!Array.isArray(data)) {
    throw new Error('Kandidatkøen er ugyldig: svaret er ikke en liste.')
  }
  return data.map(queueEntry)
}

export function createCandidateGateway(): CandidateGateway {
  const client = antidepClient()

  return {
    async listQueue() {
      return callRpc(client, {
        fn: 'candidate_control_queue',
        area: AREA,
        parse: parseQueue,
        wording: {
          not_authorized:
            'Sluttkontrollen krever mandat. Ta kontakt med en administrator hvis du skulle ' +
            'hatt det.',
          unavailable: 'Antidep får ikke hentet kandidatkøen akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async read(candidateId) {
      return callRpc(client, {
        fn: 'candidate_for_control',
        args: { p_candidate_id: candidateId },
        area: AREA,
        parse: parseCandidateView,
        wording: {
          ...SEALED_CONTENT_WORDING,
          unavailable: 'Antidep får ikke hentet kandidaten akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async recordFinalControl(input) {
      await callRpc(client, {
        fn: 'record_candidate_final_control',
        args: {
          p_candidate_id: input.candidateId,
          // Uendret fra det flaten viste. Databasen avviser et annet avtrykk, og
          // avviser også en kandidat hvis grunnlag er endret siden forseglingen.
          p_seen_candidate_digest: input.seenCandidateDigest,
          p_decision: input.decision,
          p_rationale: input.rationale,
        },
        area: AREA,
        parse: () => undefined,
        wording: {
          ...SEALED_CONTENT_WORDING,
          unavailable:
            'Sluttkontrollen ble ikke registrert. Antidep svarte ikke. Prøv igjen om litt.',
        },
      })
    },

    async publish(input) {
      return callRpc(client, {
        fn: 'publish_candidate',
        args: {
          p_candidate_id: input.candidateId,
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
  }
}
