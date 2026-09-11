// ============================================================================
// Hva som gjør ett kildeutdrag kontrollerbart
//
// Et `source_excerpt` er venstresiden i kontrolløkten: den ordrette teksten et
// menneske skal holde Antideps tolkning opp mot. Kravet til det er derfor ikke
// «finnes i kilden». Det er:
//
//   **Kontrolløren skal kunne avgjøre delpunktet ut fra det Antidep viser,
//   uten å måtte lete i fullteksten selv.**
//
// Det er et produktkrav (PRODUCT_INFORMATION_ARCHITECTURE.md §63.1), ikke en
// preferanse i en promptmal, og det er grunnen til at reglene har et hjem i
// koden og ikke bare i prosa.
//
// ----------------------------------------------------------------------------
// Hvorfor modulen finnes, og hva den lærte av Fava 2000
//
// Både promptmalen og ekstraksjonsferdigheten sa allerede at utdraget skulle
// inneholde «hele setningen verdien står i». Likevel ble dette registrert i
// produksjon som forankringen for behandlingsarmene:
//
//   «tine (N = 92), sertraline, (N = 96), or paroxetine»
//
// Utdraget står ordrett i artikkelen, og hver deterministisk kontroll i kjeden
// sa ja. Det begynner likevel midt inne i «fluoxetine», og en kontrollør som
// leser det, kan ikke se hvilket virkestoff de 92 gjelder, hvilken studie det
// er, eller hva som ble randomisert.
//
// Lærdommen er at en regel som bare står i en modellprompt, er en regel uten
// håndhevelse. Det som kan håndheves deterministisk, skal håndheves her — og
// bare det. Resten står svært eksplisitt i den versjonerte malen
// (`extraction-prompt.ts`).
//
// ----------------------------------------------------------------------------
// Skillet mellom de to kontrollene, og hvorfor det går der det går
//
//   `excerptShapeProblem`   ser bare på teksten i utdraget, og kan derfor kjøres
//                           av parseren — før noen kilde er hentet.
//   `excerptSourceProblem`  trenger representasjonen, fordi spørsmålet «begynner
//                           dette midt i et ord?» ikke kan besvares av utdraget
//                           alene. Det kjøres av leddene som har teksten:
//                           modell-leddets egen aktsomhet og registreringen.
//
// ----------------------------------------------------------------------------
// Hva som med vilje IKKE håndheves her
//
// Ingen setningsparser. Kildene er PDF-er som er kjørt gjennom `pdftotext`, og
// der er linjeskift, orddeling, kolonner, fotnotemerker og forkortelser
// («vs.», «e.g.», «Fig. 2») helt vanlige. En parser som skulle avgjøre om et
// utdrag er «én hel setning», ville avvist legitime utdrag på formfeil i
// tekstuttrekket — og et ledd som avviser riktige ekstraksjoner, blir slått av.
//
// De to reglene under er valgt fordi de ikke kan ta feil på den måten:
//
//   1. **Ordgrense.** Kontrollen leser tegnet rett foran og rett bak treffet i
//      selve representasjonen. Den tolker ikke språk i det hele tatt.
//   2. **Minst én setningsgrense.** Et utdrag uten et eneste punktum,
//      semikolon, spørsmåls- eller utropstegn har ikke fanget opp slutten på
//      en eneste setning, og er per definisjon et utsnitt. Punktum mellom to
//      sifre er et desimalskilletegn og teller ikke — «1.0» avslutter ingen
//      setning.
//
// Den andre regelen har én kjent kostnad, og den er en bevisst avveining: en
// verdi som bare står i en tabellrad uten tegnsetting, kan ikke forankres av
// raden alene. Den skal da forankres av teksten eller tabellteksten som sier
// hva raden er — som er nøyaktig det kontrolløren trenger uansett. Prisen er et
// avvist utkast med en lesbar beskjed, aldri en registrert rad med for tynt
// grunnlag.
// ============================================================================

import { verbatimOccursIn, verbatimOccursWholeWordsIn } from './extraction-checks.ts'

/**
 * Hvor kort et ordrett kildeutdrag kan være og fortsatt bære kontekst.
 *
 * «284» eller «8 weeks» alene er ikke et kontrollgrunnlag: tallet står kanskje
 * fem steder i artikkelen, og utdraget sier ikke hvilket. Grensen er den samme
 * som `MIN_QUOTE_LENGTH` i `extraction-checks.ts` bruker for at et sitat skal
 * være verdt å kontrollere ordrett, og av samme grunn.
 *
 * Den er et **gulv**, ikke målet. Et utdrag som er langt nok til å passere
 * denne grensen, er ikke dermed langt nok til å være kontrollgrunnlag; det
 * avgjøres av de to reglene under og av malen.
 */
export const MIN_SOURCE_EXCERPT_LENGTH = 24

/**
 * En setningsgrense, med desimaltall unntatt.
 *
 * Samme regel som `sentences()` i `extraction-checks.ts` deler på: semikolon,
 * utropstegn og spørsmålstegn deler alltid, og et punktum deler med mindre det
 * står mellom to sifre. Kolon deler ikke — «CI 95%: 0,4 til 2,6» er én påstand.
 */
const SENTENCE_BOUNDARY = /[;!?]|(?<!\d)\.|\.(?!\d)/u

/** Om utdraget har fanget opp minst én setningsslutt. */
export function spansSentenceBoundary(excerpt: string): boolean {
  return SENTENCE_BOUNDARY.test(excerpt)
}

/**
 * Det som kan avgjøres av utdraget alene, eller `null` når ingenting er galt.
 *
 * Formulert som et ledd i en avvisning: «…source_excerpt <problem>». Teksten
 * sier hva som må gjøres i stedet, fordi mottakeren er et ledd som skal rette
 * utkastet sitt.
 */
export function excerptShapeProblem(excerpt: string): string | null {
  const trimmed = excerpt.trim()
  if (trimmed.length < MIN_SOURCE_EXCERPT_LENGTH) {
    return (
      `er kortere enn ${String(MIN_SOURCE_EXCERPT_LENGTH)} tegn og bærer derfor ikke nok ` +
      'kontekst til å være kontrollgrunnlag. Ta med hele setningen verdien står i, ordrett'
    )
  }
  if (!spansSentenceBoundary(trimmed)) {
    return (
      'inneholder ingen setningsgrense, og er derfor et løsrevet fragment. Et fragment sier ' +
      'ikke hva opplysningen gjelder. Ta med hele setningen verdien står i, og den nærmeste ' +
      'tilstøtende setningen når én setning ikke gjør betydningen entydig'
    )
  }
  return null
}

/**
 * Det som bare kan avgjøres mot teksten utdraget påstår å komme fra.
 *
 * To spørsmål, i rekkefølge, fordi det andre ikke er meningsfullt uten det
 * første: står utdraget der i det hele tatt, og står det da mellom ordgrenser?
 *
 * `projections` er `searchProjections(representasjonen)`, slik at kalleren kan
 * kontrollere mange utdrag mot den samme normaliserte teksten.
 */
export function excerptSourceProblem(
  projections: readonly string[],
  excerpt: string,
): string | null {
  if (!verbatimOccursIn(projections, excerpt)) {
    return 'ikke står ordrett i representasjonen'
  }
  if (!verbatimOccursWholeWordsIn(projections, excerpt)) {
    return (
      'begynner eller slutter midt i et ord i representasjonen, og er derfor et utsnitt av en ' +
      'tegnstrøm og ikke et utdrag av en setning'
    )
  }
  return null
}
