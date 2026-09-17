// ============================================================================
// Revisjonsflatens eneste vei til databasen
//
// Tre kall, og ikke et fjerde: se hvilke påstander som har fått ny forskning,
// åpne én av dem, og avgjøre hva som skal skje. Selve revisjonen bygger Antidep
// selv — synteseoppgaven, kildestøttekontrollen, evidensvurderingen og
// kandidaten er de samme leddene som før, og ingen av dem er synlige her
// (docs/ROADMAP.md, AGENTS.md).
//
// ----------------------------------------------------------------------------
// Hvorfor evidensgrunnlaget sendes tilbake uendret
//
// Avgjørelsen er bundet til nøyaktig det grunnlaget redaktøren tok stilling til
// (ANTIDEP_CONSTITUTION.md regel 5). Avtrykket flaten faktisk viste, følger
// derfor med, og databasen avviser en avgjørelse som gjelder noe annet enn det
// som ligger der nå. Flaten regner ikke ut noe avtrykk selv: en verdi klienten
// kunne beregne, ville vært en påstand om seg selv.
//
// ----------------------------------------------------------------------------
// Hvorfor avvisningene har sine egne setninger
//
// «Grunnlaget er endret» og «noen andre har alt avgjort denne» er ikke feil —
// de er systemet som gjør jobben sin, og den som står ved flaten trenger å vite
// hva vedkommende skal gjøre i stedet. Setningen er flatens egen, valgt av hva
// slags avvisning det var; den rå årsaken går til observability (`gateway.ts`).
// ============================================================================

import { antidepClient, callRpc, type FailureWording, type TechnicalArea } from './gateway'
import {
  parseClaimRevisionOutcome,
  parseClaimRevisionQueue,
  parseClaimRevisionTask,
  type ClaimRevisionDecision,
  type ClaimRevisionOutcome,
  type ClaimRevisionTask,
} from '../lib/claim-revision'

const AREA: TechnicalArea = 'clinical_content'

const MANDATE_WORDING: FailureWording = {
  not_authorized:
    'Å avgjøre om en påstand skal skrives om, er en redaksjonell avgjørelse, og krever ' +
    'redaktørmandat for fagområdet. Ta kontakt med en administrator hvis du skulle hatt det.',
}

export interface ClaimRevisionGateway {
  listQueue(): Promise<readonly ClaimRevisionTask[]>
  read(reference: string): Promise<ClaimRevisionTask>
  decide(input: {
    readonly reference: string
    readonly decision: ClaimRevisionDecision
    readonly seenEvidenceBasis: string
    readonly note: string
  }): Promise<ClaimRevisionOutcome>
}

export function createClaimRevisionGateway(): ClaimRevisionGateway {
  const client = antidepClient()

  return {
    async listQueue() {
      return callRpc(client, {
        fn: 'claim_revision_queue',
        area: AREA,
        parse: parseClaimRevisionQueue,
        wording: {
          ...MANDATE_WORDING,
          unavailable: 'Antidep får ikke hentet listen akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async read(reference) {
      return callRpc(client, {
        fn: 'claim_revision_for_decision',
        args: { p_reference: reference },
        area: AREA,
        parse: parseClaimRevisionTask,
        wording: {
          ...MANDATE_WORDING,
          not_found:
            'Denne oppgaven venter ikke lenger på en avgjørelse. Den kan være avgjort av ' +
            'noen andre, eller den nye forskningen kan ha blitt trukket tilbake. Hent listen ' +
            'på nytt.',
          unavailable: 'Antidep får ikke hentet oppgaven akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async decide(input) {
      return callRpc(client, {
        fn: 'record_claim_revision_decision',
        args: {
          p_reference: input.reference,
          p_decision: input.decision,
          // Uendret fra det flaten viste. Databasen avviser en avgjørelse som
          // gjelder et annet evidensgrunnlag enn det som ligger der nå.
          p_seen_evidence_basis: input.seenEvidenceBasis,
          p_note: input.note.trim().length === 0 ? null : input.note.trim(),
        },
        area: AREA,
        parse: parseClaimRevisionOutcome,
        wording: {
          ...MANDATE_WORDING,
          not_found: 'Oppgaven finnes ikke lenger slik du så den. Hent listen på nytt.',
          invalid_input:
            'Antidep kunne ikke ta imot avgjørelsen. Kontroller at begrunnelsen er fylt ut, ' +
            'og prøv igjen.',
          rejected:
            'Grunnlaget er endret siden du åpnet oppgaven, eller noen andre har allerede ' +
            'avgjort den. Hent oppgaven på nytt, og ta stilling til det som faktisk finnes nå.',
          unavailable: 'Avgjørelsen ble ikke registrert. Antidep svarte ikke. Prøv igjen om litt.',
        },
      })
    },
  }
}
