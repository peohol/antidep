// ============================================================================
// Fulltekstflatenes eneste vei til databasen
//
// To handlinger, og ikke en tredje: å be om en artikkel Antidep mangler, og å
// velge riktig PDF for en som allerede er bestilt. Begge er redaksjonelle.
// Bindingen, identitetskontrollen, lesbarhetskontrollen, tekstuttrekket,
// registreringen og kølegging av neste ledd er Antideps eget arbeid
// (issue #99 punkt 3, issue #101 punkt 3).
//
// De to kallene som ikke er handlinger — listene bestillingen velger fra, og
// hva den innloggede kan gjøre — er lesinger, og de finnes for at flaten skal
// slippe å be om noe teknisk eller vise et skjema kallet uansett måtte avvise.
//
// ----------------------------------------------------------------------------
// Hvorfor avvisningene har sine egne setninger
//
// Databasen avviser en opplasting med SQLSTATE og en melding. Meldingen er ikke
// noe flaten viser (`gateway.ts`), men *formen* på avvisningen sier likevel noe
// nyttig, og den er flatens å formulere: en fil som ikke er en PDF, og en
// artikkel Antidep ikke lenger venter på, krever forskjellige ting av den som
// står der.
// ============================================================================

import { antidepClient, callRpc, type TechnicalArea } from './gateway'
import { toBase64 } from '../lib/base64'
import {
  parseFullTextInbox,
  parseFullTextSubmission,
  type FullTextInboxItem,
  type FullTextSubmission,
} from '../lib/full-text-inbox'
import {
  normaliseDoi,
  parseCapabilities,
  parseRequestOptions,
  parseRequestResult,
  type FullTextCapabilities,
  type FullTextRequestDraft,
  type FullTextRequestOptions,
  type FullTextRequestResult,
} from '../lib/full-text-request'

const AREA: TechnicalArea = 'full_text_intake'

export interface FullTextGateway {
  listInbox(): Promise<readonly FullTextInboxItem[]>
  submit(reference: string, document: Uint8Array): Promise<FullTextSubmission>
  /** Hva den innloggede kan gjøre her. Svarer stille nei framfor å avvise. */
  capabilities(): Promise<FullTextCapabilities>
  /** De faglige valgene en bestilling kan avgrenses med, som navn. */
  requestOptions(): Promise<FullTextRequestOptions>
  request(draft: FullTextRequestDraft): Promise<FullTextRequestResult>
}

export function createFullTextGateway(): FullTextGateway {
  const client = antidepClient()

  return {
    async listInbox() {
      return callRpc(client, {
        fn: 'full_text_inbox',
        area: AREA,
        parse: parseFullTextInbox,
        wording: {
          not_authorized:
            'Fulltekstinnboksen er for redaktører og administratorer. Ta kontakt med en ' +
            'administrator hvis du skulle hatt tilgang.',
          unavailable: 'Antidep får ikke hentet innboksen akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async submit(reference, document) {
      return callRpc(client, {
        fn: 'submit_full_text',
        // Filen sendes uendret, byte for byte: databasen beregner
        // fingeravtrykket selv, og enhver omforming underveis ville gitt et
        // fingeravtrykk som ikke er filens.
        args: { p_reference: reference, p_document_base64: toBase64(document) },
        area: AREA,
        parse: parseFullTextSubmission,
        wording: {
          not_authorized: 'Du har ikke tilgang til å laste opp fulltekst i Antidep.',
          not_found:
            'Antidep venter ikke lenger på fulltekst for denne artikkelen. Hent listen på nytt.',
          invalid_input:
            'Filen kunne ikke brukes. Antidep tar bare imot PDF-filer på inntil 64 MB.',
          rejected:
            'Antidep arbeider allerede med en fil for denne artikkelen. Vent til den er ' +
            'ferdig behandlet.',
          unavailable: 'Filen ble ikke lastet opp. Antidep svarte ikke. Prøv igjen om litt.',
        },
      })
    },

    async capabilities() {
      return callRpc(client, {
        fn: 'full_text_capabilities',
        area: AREA,
        parse: parseCapabilities,
        wording: {
          unavailable: 'Antidep svarte ikke akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async requestOptions() {
      return callRpc(client, {
        fn: 'full_text_request_options',
        area: AREA,
        parse: parseRequestOptions,
        wording: {
          not_authorized:
            'Å be om en artikkel er en redaksjonell avgjørelse, og krever redaktørmandat. ' +
            'Ta kontakt med en administrator hvis du skulle hatt det.',
          unavailable: 'Antidep får ikke hentet valgene akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async request(draft) {
      return callRpc(client, {
        fn: 'request_missing_full_text',
        args: {
          // Normaliseres på den samme måten databasen gjør, slik at det som
          // vises i feltet, er det som faktisk blir lagret.
          p_doi: normaliseDoi(draft.doi),
          p_title: draft.title.trim(),
          p_authors: draft.authors.trim(),
          p_drug_names: draft.drugs,
          p_outcome_labels: draft.outcomes,
          p_population_labels: draft.populations,
          p_journal: draft.journal.trim().length === 0 ? null : draft.journal.trim(),
          p_year: draft.year.trim().length === 0 ? null : Number(draft.year.trim()),
        },
        area: AREA,
        parse: parseRequestResult,
        wording: {
          not_authorized: 'Du har ikke tilgang til å be om artikler i Antidep.',
          not_found: 'Antidep fant ikke det bestillingen viste til. Hent siden på nytt.',
          invalid_input:
            'Bestillingen kunne ikke brukes. Kontroller DOI-en, tittelen og forfatterne, og ' +
            'at virkestoffene og endepunktene er valgt fra listene.',
          rejected:
            'Antidep venter allerede på denne artikkelen med en annen avgrensning. Vent til ' +
            'fullteksten er registrert, og be om den nye avgrensningen da.',
          unavailable: 'Bestillingen ble ikke sendt. Antidep svarte ikke. Prøv igjen om litt.',
        },
      })
    },
  }
}
