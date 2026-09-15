// ============================================================================
// Kandidatflatens eneste vei til databasen
//
// Flaten skal kunne prøves uten en Supabase-stack, og en komponent som kalte
// `getAntidepClient()` direkte, kunne ikke det. De tre kallene ligger derfor bak
// én grenseflate, og komponenten kjenner bare den.
//
// ----------------------------------------------------------------------------
// Hvorfor avtrykket sendes tilbake uendret
//
// Sluttkontrollen er bundet til nøyaktig den kandidaten som ble lest
// (ANTIDEP_CONSTITUTION.md regel 5). Avtrykket flaten faktisk viste, sendes
// derfor med beslutningen, og databasen krever at det er kandidatens eget *og*
// at innholdet fortsatt bygger til det. Flaten regner ikke ut noe avtrykk selv:
// en verdi klienten kunne beregne, ville vært en påstand om seg selv.
// ============================================================================

import { getAntidepClient } from '../lib/supabase'
import { parseCandidateView, type CandidateView } from '../lib/candidate-view'

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

/** Avvisninger fra databasen når fram uendret: de sier hva som må gjøres. */
function rejected(operation: string, message: string): Error {
  return new Error(`${operation}: ${message}`)
}

export function createCandidateGateway(): CandidateGateway {
  const client = getAntidepClient()

  return {
    async listQueue() {
      const { data, error } = await client.rpc('candidate_control_queue', {})
      if (error !== null) {
        throw rejected('Kandidatkøen kunne ikke leses', error.message)
      }
      if (!Array.isArray(data)) {
        throw new Error('Kandidatkøen er ugyldig: svaret er ikke en liste.')
      }
      return data.map(queueEntry)
    },

    async read(candidateId) {
      const { data, error } = await client.rpc('candidate_for_control', {
        p_candidate_id: candidateId,
      })
      if (error !== null) {
        throw rejected('Kandidaten kunne ikke leses', error.message)
      }
      return parseCandidateView(data)
    },

    async recordFinalControl(input) {
      const { error } = await client.rpc('record_candidate_final_control', {
        p_candidate_id: input.candidateId,
        // Uendret fra det flaten viste. Databasen avviser et annet avtrykk, og
        // avviser også en kandidat hvis grunnlag er endret siden forseglingen.
        p_seen_candidate_digest: input.seenCandidateDigest,
        p_decision: input.decision,
        p_rationale: input.rationale,
      })
      if (error !== null) {
        throw rejected('Sluttkontrollen ble ikke registrert', error.message)
      }
    },
  }
}
