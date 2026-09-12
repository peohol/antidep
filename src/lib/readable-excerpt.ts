// ============================================================================
// Det ordrette utdraget, gjort lesbart — uten å endre et ord
//
// Kildeutdraget kontrolløren leser, kommer fra en tekst hentet ut av en PDF.
// Linjeskiftene i den er der spaltens linje tok slutt på papiret, ikke der
// setningen tok slutt: «Patients (N = 284) with major depressive disorder\nwere
// randomly assigned …» er én setning brutt av sidebredden.
//
// Gjengis den teksten preformatert, arver kontrollflaten papirets geometri: på
// en mobilskjerm må kontrolløren rulle vannrett gjennom en setning, og et
// utdrag fra en tospaltet artikkel blir en vegg av mellomrom. Det er ikke den
// teksten hen skal lese (PRODUCT_INFORMATION_ARCHITECTURE.md §63.1).
//
// ----------------------------------------------------------------------------
// Hva som er et avsnitt, og hva som bare er en linje
//
// Den kanoniske representasjonen skiller **uavhengige tekstblokker** med en
// blank linje og sider med et sideskift, og **linjer innenfor samme blokk** med
// ett linjeskift (`src/agents/reading-order.ts`). Skillet er ikke kosmetisk: det
// er den samme grensen den ordrette kontrollen ikke tillater et sitat å krysse
// (`src/agents/extraction-checks.ts`).
//
// Denne modulen leser nøyaktig det skillet:
//
//   blank linje eller sideskift  →  et nytt avsnitt, som beholdes
//   ett linjeskift               →  et mellomrom, som en linjeombrekking er
//
// ----------------------------------------------------------------------------
// Hvorfor ordene aldri endres
//
// Ingen orddeling settes sammen, ingen tegnsetting legges til, ingen ord
// fjernes. Det eneste som skjer, er at blanktegn slås sammen — den samme
// operasjonen den ordrette kontrollen selv gjør før den søker. Et utdrag som er
// lesbart her, er derfor det samme utdraget som er kontrollert, ord for ord.
//
// ----------------------------------------------------------------------------
// Den ene teksten som ikke skal flyte
//
// Alt over hviler på at leserekkefølgen i teksten *er* logisk. For en
// kildeversjon som bærer verktøyets utdata ordrett — `-layout`, uten
// etterbehandling, som er oppskriften hver dokumentutledet rad fra før
// migrasjon 003g har — er den ikke det: der ligger venstre og høyre spalte på
// den samme tekstlinjen, atskilt av en vegg mellomrom. Slås den veggen sammen
// til ett mellomrom, leser to uavhengige spalter som én flytende setning, og
// kontrolløren ser en setning som ikke står i artikkelen. Den veggen er det
// eneste synlige varselet om at teksten er vevd sammen, og den skal derfor bli
// stående.
//
// Grensen leses av det raden selv sier om hvordan teksten ble laget, ikke av en
// gjetning om hva som står i den: en dokumentutledet versjon uten
// etterbehandling viser plasseringen som den er, alt annet flyter.
// ============================================================================

/** Et opphold som skiller to uavhengige blokker: en blank linje eller et sideskift. */
const BLOCK_BREAK = /\n[^\S\n]*\n|\f/

/**
 * Utdraget som avsnitt, slik en kontrollør skal lese det.
 *
 * Returnerer alltid minst ett avsnitt for et utdrag som har innhold, og en tom
 * liste for et utdrag uten. Kalleren viser hvert avsnitt for seg.
 */
export function readableExcerptParagraphs(excerpt: string): readonly string[] {
  return excerpt
    .split(BLOCK_BREAK)
    .map((paragraph) => paragraph.replaceAll(/\s+/g, ' ').trim())
    .filter((paragraph) => paragraph.length > 0)
}

/**
 * Skal utdraget vises med plasseringen fra papiret i behold?
 *
 * Svaret leses av oppskriften i raden, som er der nettopp fordi den sier hvordan
 * teksten ble laget. Bare én tilstand skal ikke flyte: en tekst som er
 * verktøyets utdata ordrett, uten Antideps egen rekonstruksjon av
 * leserekkefølgen. Da er den fysiske plasseringen fortsatt i teksten, og å slå
 * den sammen ville gjort to spalter til én setning.
 *
 * En representasjon som ikke er utledet av et dokument — teksten som lå på
 * adressen, for eksempel et sammendrag — har ingen spalter å veve sammen, og
 * flyter som resten.
 *
 * Formen er tatt strukturelt framfor som en importert type, slik at
 * kontrollflaten ikke trekker agentleddene inn i importgrafen sin.
 */
export function excerptKeepsLayout(
  document: { readonly textExtraction: { readonly transform: string | null } } | null,
): boolean {
  return document !== null && document.textExtraction.transform === null
}
