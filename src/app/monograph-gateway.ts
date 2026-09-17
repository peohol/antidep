// ============================================================================
// Monografiflatens eneste vei til databasen
//
// Bestillingen, dekningen, hele utkastet, det som venter på et menneske, og de
// redaksjonelle handlingene. Ingenting her regner ut noe selv: tilstanden er
// databasens, og flaten viser den.
//
// Avvisningene har sine egne setninger, som resten av flatene. «Du mangler
// mandat» og «Antidep svarer ikke» er to forskjellige beskjeder, og den som
// står her, trenger å vite hva vedkommende skal gjøre i stedet. Den rå årsaken
// går til observability (`gateway.ts`) og vises aldri.
// ============================================================================

import { antidepClient, callRpc, type FailureWording, type TechnicalArea } from './gateway'
import {
  parseMonographDraft,
  parseMonographOrders,
  parseMonographProposals,
  parseMonographRequests,
  type MonographCoverage,
  type MonographDraft,
  type MonographProposal,
  type MonographRequest,
} from '../lib/monograph'

const AREA: TechnicalArea = 'clinical_content'

const MANDATE_WORDING: FailureWording = {
  not_authorized:
    'Å bestille og lese en monografi under arbeid er redaksjonelt arbeid, og krever ' +
    'redaktørmandat. Ta kontakt med en administrator hvis du skulle hatt det.',
}

export interface MonographGateway {
  listOrders(): Promise<readonly MonographCoverage[]>
  order(drug: string, note: string): Promise<MonographCoverage | null>
  options(): Promise<{ readonly drugs: readonly string[]; readonly questionTemplates: number }>
  draft(reference: string): Promise<MonographDraft>
  requests(reference: string): Promise<readonly MonographRequest[]>
  proposals(reference: string): Promise<readonly MonographProposal[]>
  decideProposal(reference: string, accept: boolean, note: string): Promise<void>
  editAnswer(input: {
    readonly needReference: string
    readonly statement: string
    readonly changeReason: string
  }): Promise<void>
  lockAnswer(needReference: string, reason: string): Promise<void>
  unlockAnswer(needReference: string, reason: string): Promise<void>
  buildCandidate(
    reference: string,
  ): Promise<{ readonly reference: string; readonly digest: string }>
}

export function createMonographGateway(): MonographGateway {
  const client = antidepClient()

  return {
    async listOrders() {
      return callRpc(client, {
        fn: 'monograph_orders',
        area: AREA,
        parse: parseMonographOrders,
        wording: {
          ...MANDATE_WORDING,
          unavailable: 'Antidep får ikke hentet monografiene akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async options() {
      return callRpc(client, {
        fn: 'monograph_order_options',
        area: AREA,
        parse: (value) => {
          const payload = (value ?? {}) as Record<string, unknown>
          const drugs = Array.isArray(payload['drugs'])
            ? (payload['drugs'] as unknown[]).filter(
                (name): name is string => typeof name === 'string',
              )
            : []
          const templates = payload['question_templates']
          return {
            drugs,
            questionTemplates: typeof templates === 'number' ? templates : 0,
          }
        },
        wording: {
          ...MANDATE_WORDING,
          unavailable: 'Antidep får ikke hentet virkestoffene akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async order(drug, note) {
      const trimmed = note.trim()
      const outcome = await callRpc(client, {
        fn: 'order_monograph',
        args: { p_drug_name: drug, p_note: trimmed.length === 0 ? null : trimmed },
        area: AREA,
        parse: (value) => (value ?? {}) as Record<string, unknown>,
        wording: {
          ...MANDATE_WORDING,
          not_found: 'Antidep kjenner ikke dette virkestoffet. Velg et av dem som står i listen.',
          invalid_input:
            'Bestillingen kunne ikke tas imot. Kontroller virkestoffet, og prøv igjen.',
          unavailable: 'Bestillingen ble ikke registrert. Antidep svarte ikke. Prøv igjen om litt.',
        },
      })
      const reference = outcome['reference']
      if (typeof reference !== 'string') {
        return null
      }
      return this.draft(reference).then((draft) => draft.coverage)
    },

    async draft(reference) {
      return callRpc(client, {
        fn: 'monograph_draft',
        args: { p_edition_reference: reference },
        area: AREA,
        parse: parseMonographDraft,
        wording: {
          ...MANDATE_WORDING,
          not_found: 'Denne monografien finnes ikke. Hent listen på nytt.',
          unavailable: 'Antidep får ikke hentet monografien akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async requests(reference) {
      return callRpc(client, {
        fn: 'monograph_source_requests',
        args: { p_edition_reference: reference },
        area: AREA,
        parse: parseMonographRequests,
        wording: {
          ...MANDATE_WORDING,
          not_found: 'Denne monografien finnes ikke. Hent listen på nytt.',
          unavailable: 'Antidep får ikke hentet forespørslene akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async proposals(reference) {
      return callRpc(client, {
        fn: 'monograph_revision_proposals',
        args: { p_edition_reference: reference },
        area: AREA,
        parse: parseMonographProposals,
        wording: {
          ...MANDATE_WORDING,
          not_found: 'Denne monografien finnes ikke. Hent listen på nytt.',
          unavailable: 'Antidep får ikke hentet avvikene akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async decideProposal(reference, accept, note) {
      const trimmed = note.trim()
      await callRpc(client, {
        fn: 'decide_monograph_revision_proposal',
        args: {
          p_reference: reference,
          p_accept: accept,
          p_note: trimmed.length === 0 ? null : trimmed,
        },
        area: AREA,
        parse: () => undefined,
        wording: {
          ...MANDATE_WORDING,
          not_found: 'Dette avviket finnes ikke lenger. Hent listen på nytt.',
          invalid_input:
            'Antidep kunne ikke ta imot avgjørelsen. En avvisning krever en begrunnelse.',
          unavailable: 'Avgjørelsen ble ikke registrert. Antidep svarte ikke. Prøv igjen om litt.',
        },
      })
    },

    async editAnswer(input) {
      await callRpc(client, {
        fn: 'edit_monograph_answer',
        args: {
          p_need_reference: input.needReference,
          p_statement: input.statement,
          p_change_reason: input.changeReason,
        },
        area: AREA,
        parse: () => undefined,
        wording: {
          ...MANDATE_WORDING,
          not_found: 'Dette spørsmålet finnes ikke lenger slik du så det. Hent siden på nytt.',
          invalid_input:
            'Antidep kunne ikke ta imot rettelsen. En redaksjonell endring krever en begrunnelse.',
          rejected:
            'Spørsmålet har ikke noe kontrollert svar å rette ennå. En rettelse endrer et svar ' +
            'som allerede har kildestøtte.',
          unavailable: 'Rettelsen ble ikke registrert. Antidep svarte ikke. Prøv igjen om litt.',
        },
      })
    },

    async lockAnswer(needReference, reason) {
      await callRpc(client, {
        fn: 'lock_monograph_answer',
        args: { p_need_reference: needReference, p_reason: reason },
        area: AREA,
        parse: () => undefined,
        wording: {
          ...MANDATE_WORDING,
          invalid_input: 'En låsing krever en begrunnelse.',
          unavailable: 'Låsingen ble ikke registrert. Prøv igjen om litt.',
        },
      })
    },

    async unlockAnswer(needReference, reason) {
      await callRpc(client, {
        fn: 'unlock_monograph_answer',
        args: { p_need_reference: needReference, p_reason: reason },
        area: AREA,
        parse: () => undefined,
        wording: {
          ...MANDATE_WORDING,
          invalid_input: 'En opphevelse av en lås krever en begrunnelse.',
          unavailable: 'Opphevelsen ble ikke registrert. Prøv igjen om litt.',
        },
      })
    },

    async buildCandidate(reference) {
      return callRpc(client, {
        fn: 'build_monograph_candidate',
        args: { p_edition_reference: reference },
        area: AREA,
        parse: (value) => {
          const payload = (value ?? {}) as Record<string, unknown>
          return {
            reference: String(payload['reference'] ?? ''),
            digest: String(payload['content_digest'] ?? ''),
          }
        },
        wording: {
          ...MANDATE_WORDING,
          rejected:
            'Monografien har ingen kontrollerte svar å bygge en utgave av ennå. Et dekningskart ' +
            'er ikke en monografiutgave.',
          unavailable: 'Utgaven ble ikke bygget. Antidep svarte ikke. Prøv igjen om litt.',
        },
      })
    },
  }
}
