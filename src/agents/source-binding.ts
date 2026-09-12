// ============================================================================
// Kildebindingen: hvordan kjeden får tak i nøyaktig den teksten som ble lest
//
// Hvert ledd i kjeden — modell-leddet, registreringen og den maskinelle
// kontrollen — begynner med det samme spørsmålet: *hvilken tekst er dette
// egentlig?* Fram til nå fantes ett svar: hent `retrieved_from` over nett, og
// krev at sha256 av svaret er kildeversjonens `content_hash`.
//
// Det svaret finnes fortsatt, og det er riktig for en MEDLINE-post. Det er
// ubrukelig for en fulltekstartikkel: PDF-en ligger bak en innlogging, og selv
// om den ikke gjorde det, er den ikke tekst.
//
// Denne modulen er det ene stedet som avgjør hvilken vei som gjelder, og
// avgjørelsen leses av **den registrerte raden**, ikke av kalleren:
//
//   ingen dokumentbinding  →  hent adressen, krev fingeravtrykket  (som før)
//   dokumentbinding        →  finn originaldokumentet på fingeravtrykket,
//                             kjør den registrerte oppskriften, krev at
//                             teksten hasher til `content_hash`
//
// ----------------------------------------------------------------------------
// Hvorfor de to veiene ikke kan bytte plass
//
// En kildeversjon med dokumentbinding hentes **aldri** over nett, og en uten
// hentes **aldri** fra et dokument. Det er ikke ryddighet, men selve
// invarianten: kunne en fulltekstversjon tilfredsstilles av det som lå på
// `retrieved_from`, ville et abstrakt hentet fra PubMed kunnet bli
// kontrollgrunnlaget for en ekstraksjon registrert som fulltekst. Og kunne en
// abstraktversjon tilfredsstilles av en PDF, ville det motsatte skjedd.
//
// Begge veier ender med den samme kontrollen — sha256 av teksten må være den
// registrerte — så en tekst som ikke er den registrerte, blir aldri grunnlag,
// uansett hvor den kom fra.
//
// Utrygg inndata: både svaret fra nettet og teksten ut av dokumentet er data,
// aldri instruksjoner (CLAUDE.md). De brukes bare som høystakk for ordrette søk.
// ============================================================================

import {
  looksLikePdf,
  type DocumentBinding,
  type RepresentationBinding,
  type TextExtractionRecipe,
} from './document-binding.ts'
import { reproduceDocumentText, type RunTool } from './document-text.ts'
import type { DocumentLookup, LoadedDocument } from './source-document.ts'
import {
  retrieveRepresentation,
  type RetrieveLike,
  type RetrieveOptions,
} from './source-retrieval.ts'

export interface ResolvePorts {
  readonly retrieve?: RetrieveLike
  readonly retrieveOptions?: RetrieveOptions
  /** Oppslaget av originaldokumentet, på fingeravtrykk. */
  readonly documents?: DocumentLookup
  readonly runTool?: RunTool
}

export type ResolvedRepresentation =
  | {
      readonly status: 'ok'
      readonly text: string
      /** Hvor teksten kom fra, i klartekst, til logging og til kontrollgrunnlag. */
      readonly origin: 'retrieved_text' | 'extracted_from_document'
      /** Dokumentet, når teksten kom fra ett. */
      readonly document?: LoadedDocument
      /**
       * Oppskriften som gjenskapte teksten, når det **ikke** var den raden selv
       * bærer.
       *
       * Utelatt i det normale tilfellet. Er den satt, er den registrerte
       * oppskriften avløst og ikke lenger kjørbar, og dagens oppskrift kom fram
       * til nøyaktig det registrerte fingeravtrykket (`document-text.ts`).
       * Kalleren skal føre den i proveniensen sin: «gjenskapt med X, stemmer med
       * fingeravtrykket registrert under Y» er en annen påstand enn «kjørt med
       * den registrerte oppskriften», og de to skal ikke se like ut i ettertid.
       */
      readonly reproducedWith?: TextExtractionRecipe
    }
  | { readonly status: 'error'; readonly message: string }

/**
 * Skaffer representasjonen for én kildeversjon, og krever at den er den
 * registrerte.
 *
 * Returnerer aldri en avvisning som et kastet unntak: en kilde som er nede,
 * flyttet eller endret, og et dokument som ikke ligger der, er normale utfall
 * for et ledd i kjeden — de skal føre til at leddet ikke konkluderer, ikke til
 * at kjøringen kræsjer.
 */
export async function resolveRepresentation(
  binding: RepresentationBinding,
  ports: ResolvePorts = {},
): Promise<ResolvedRepresentation> {
  if (binding.document === null) {
    return resolveFromAddress(binding, ports)
  }
  return resolveFromDocument(binding, binding.document, ports)
}

async function resolveFromAddress(
  binding: RepresentationBinding,
  ports: ResolvePorts,
): Promise<ResolvedRepresentation> {
  const retrieve =
    ports.retrieve ?? ((url: string) => retrieveRepresentation(url, ports.retrieveOptions))
  const retrieved = await retrieve(binding.retrievedFrom)
  if (retrieved.status === 'error') {
    return retrieved
  }
  const representation = retrieved.representation
  if (!representation.bytesAreUtf8) {
    return {
      status: 'error',
      message:
        `Svaret fra ${binding.retrievedFrom} er ikke ren UTF-8, så fingeravtrykket kan ikke ` +
        'sammenlignes byte for byte med den registrerte kildeversjonen.',
    }
  }
  if (representation.contentHash !== binding.contentHash) {
    return {
      status: 'error',
      message:
        `Kilden har endret seg: ${binding.retrievedFrom} gir nå ` +
        `${representation.contentHash}, mens kildeversjonen er registrert med ` +
        `${binding.contentHash}. En tekst lest ut av den ville pekt på en annen utgave enn ` +
        'den som faktisk ble registrert.',
    }
  }
  return { status: 'ok', text: representation.content, origin: 'retrieved_text' }
}

async function resolveFromDocument(
  binding: RepresentationBinding,
  document: DocumentBinding,
  ports: ResolvePorts,
): Promise<ResolvedRepresentation> {
  if (ports.documents === undefined) {
    return {
      status: 'error',
      message:
        `Kildeversjonen er utledet av originaldokumentet ${document.sha256}, og dette leddet ` +
        'har ingen dokumentkatalog å slå det opp i. Oppgi --documents <katalog> (eller sett ' +
        'ANTIDEP_DOCUMENT_DIR). Kildeteksten kan ikke hentes fra adressen i stedet: da ville ' +
        'kontrollen hvilt på noe annet enn det ekstraksjonen ble lest av.',
    }
  }

  const found = await ports.documents(document.sha256)
  if (found.status === 'error') {
    return found
  }
  const original = found.document

  if (original.byteSize !== document.byteSize) {
    // Kan i praksis ikke skje når fingeravtrykket stemmer, men en påstand som
    // ikke kontrolleres, er ikke en påstand noen kan stole på.
    return {
      status: 'error',
      message:
        `${original.path} er ${String(original.byteSize)} byte, mens kildeversjonen er ` +
        `registrert med ${String(document.byteSize)} byte.`,
    }
  }
  if (!looksLikePdf(original.bytes)) {
    return {
      status: 'error',
      message: `${original.path} er ikke en PDF, og kildeversjonen er registrert som ${document.mediaType}.`,
    }
  }

  // Den registrerte oppskriften først. Er den avløst og ikke lenger kjørbar,
  // prøves dagens som stedfortreder — og bare et eksakt fingeravtrykk godtas
  // (`document-text.ts`). Avvisningen sier hvilket av de to som sviktet.
  const reproduced = await reproduceDocumentText({
    bytes: original.bytes,
    registered: document.textExtraction,
    contentHash: binding.contentHash,
    ...(ports.runTool === undefined ? {} : { run: ports.runTool }),
  })
  if (reproduced.status === 'error') {
    return { status: 'error', message: `${original.path}: ${reproduced.message}` }
  }

  return {
    status: 'ok',
    text: reproduced.reproduced.text,
    origin: 'extracted_from_document',
    document: original,
    ...(reproduced.reproduced.viaRegisteredRecipe
      ? {}
      : { reproducedWith: reproduced.reproduced.recipe }),
  }
}
