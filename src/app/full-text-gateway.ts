// ============================================================================
// Fulltekstinnboksens eneste vei til databasen
//
// To kall: hva Antidep mangler, og én fil. Ingen tredje, fordi det ikke finnes
// noe tredje et menneske skal gjøre her — bindingen, identitetskontrollen,
// lesbarhetskontrollen, tekstuttrekket, registreringen og kølegging av neste
// ledd er Antideps eget arbeid (issue #99, punkt 3).
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

const AREA: TechnicalArea = 'full_text_intake'

export interface FullTextGateway {
  listInbox(): Promise<readonly FullTextInboxItem[]>
  submit(reference: string, document: Uint8Array): Promise<FullTextSubmission>
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
  }
}
