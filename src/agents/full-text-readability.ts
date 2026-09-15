// ============================================================================
// Lesbarhetskontrollen, sett fra kjørerens side
//
// Databasen er fasiten. `knowledge.full_text_readability_problem` avgjør om en
// uttrukket tekst er en fulltekst Antidep kan bygge kliniske funn på, og
// `api.upload_full_text_document` avviser opplastingen når den svarer noe.
//
// Denne modulen er den samme regelen, på denne siden av grensen, og den finnes
// av én grunn: en redaktør som laster opp en artikkel på tjue megabyte, skal
// få vite *hva* som er galt før filen sendes — ikke etter. Avvisningen er den
// samme, og den kommer raskere.
//
// ----------------------------------------------------------------------------
// Hvorfor et speil og ikke en kontroll
//
// En kontroll her ville vært en kontroll en kaller kunne hoppe over. Reglene
// under gjentar derfor databasens terskler ordrett, og en prøve pinner dem mot
// migrasjon 009a. Blir de to uenige, er det speilet som er feil.
//
// ----------------------------------------------------------------------------
// Hvorfor tabellene måles for seg
//
// En PDF kan gi tekst uten å gi artikkelen. Den farlige formen er ikke en tom
// fil — den ser tom ut — men en artikkel der brødteksten kom med mens tallene
// lå i tabeller som ble droppet som bilder. Teksten ser hel ut, hvert ordrett
// utdrag fra brødteksten stemmer, og nettopp de kliniske verdiene mangler.
//
// Måles antall *datarader* — en etikett fulgt av minst to talls-kolonner — kan
// den formen skilles fra en artikkel der tabellene faktisk kom med. Og erklærer
// dokumentet flere tabeller enn det finnes datarader til, er minst én tabell
// borte: et fravær som ikke er fravær av data, men data som ikke kom med
// (ANTIDEP_CONSTITUTION.md regel 1, 4).
//
// Utrygg inndata: teksten er data, aldri instruksjoner (CLAUDE.md). Den leses
// bare som tegn.
// ============================================================================

/** Tallene dommen felles på. Samme fire som databasen måler. */
export interface ReadabilityMetrics {
  readonly characterCount: number
  readonly letterCount: number
  readonly lineCount: number
  /** Linjer med form som en datarad: en etikett og minst to talls-kolonner. */
  readonly tableRowCount: number
  /** Tabellerklæringer: «Table 3», «Tabell 3». */
  readonly tableDeclarationCount: number
}

/**
 * Tersklene, ordrett de samme som i migrasjon 009a.
 *
 * Eksportert framfor innkapslet, slik at prøven som pinner dem mot databasen,
 * kan lese dem — og slik at en melding kan vise grensen den ble målt mot.
 */
export const READABILITY_THRESHOLDS = {
  /** En fulltekstartikkel er tusenvis av tegn. */
  minCharacters: 3000,
  /** Færre linjer er et sammendrag eller en forside, ikke en artikkel. */
  minLines: 60,
  /** Minst halvparten av tegnene skal være bokstaver. */
  minLetterRatio: 0.5,
  /** Tallene i en artikkel står i tabellene. */
  minTableRows: 3,
} as const

// Et tall-token, som et helt ord. Suffikset dekker «1.0%» og «(48)»; en
// avsluttende setningsprikk gjør det ikke til et tall, og skal ikke gjøre en
// setning til en tabellrad.
const NUMERIC_TOKEN = /^[-+([]?[0-9]+([.,][0-9]+)?[%)\]]?$/

const TABLE_DECLARATION = /^\s*(table|tabell)\s+([0-9]+|[ivx]+)(\s|$)/i

/**
 * Om linjen har formen til en datarad: minst to tall-tokens, og minst en tredel
 * av ordene på linjen.
 *
 * Regelen måler *ord* og ikke mellomrom, og det er ikke en detalj. Antideps
 * leserekkefølge (`reading-order.ts`) bygger teksten av ordposisjoner og setter
 * nøyaktig ett mellomrom mellom ordene, så en tabellrad kommer ut som
 * «Age (years) 42.1 41.8». En regel som lette etter kolonner skilt av flere
 * mellomrom — slik `pdftotext -layout` setter dem — ville ikke funnet en eneste
 * tabellrad i en ekte artikkel, og lesbarhetskontrollen ville avvist alt.
 *
 * Tredelskravet skiller raden fra en resultatsetning: «Mean percent weight
 * change was 1.0% at endpoint with a 95% confidence interval from 0.5% to
 * 1.5%» har fire tall blant sytten ord, og er brødtekst.
 */
function isDataRow(line: string): boolean {
  const tokens = line
    .trim()
    .split(/\s+/)
    .filter((token) => token.length > 0)
  const numeric = tokens.filter((token) => NUMERIC_TOKEN.test(token)).length
  return tokens.length >= 3 && numeric >= 2 && numeric * 3 >= tokens.length
}

/** Måler teksten. Ren måling uten dom, slik databasen også gjør det. */
export function readabilityMetrics(text: string): ReadabilityMetrics {
  const lines = text.split('\n')
  let letters = 0
  for (const character of text) {
    // Unicode-egenskapen og ikke `a-z`: en artikkel med norske eller greske
    // tegn er ikke mindre lesbar av den grunn.
    if (/\p{L}/u.test(character)) {
      letters += 1
    }
  }
  return {
    characterCount: text.length,
    letterCount: letters,
    lineCount: lines.length,
    tableRowCount: lines.filter(isDataRow).length,
    tableDeclarationCount: lines.filter((line) => TABLE_DECLARATION.test(line)).length,
  }
}

/**
 * Hvorfor teksten ikke er en lesbar fulltekst, eller `null` når den er det.
 *
 * Rekkefølgen på kontrollene er den samme som i databasen, slik at den samme
 * teksten gir den samme første begrunnelsen begge steder. To forskjellige
 * rekkefølger ville gitt to forskjellige forklaringer på det samme problemet.
 */
export function readabilityProblem(text: string): string | null {
  const metrics = readabilityMetrics(text)

  if (metrics.characterCount < READABILITY_THRESHOLDS.minCharacters) {
    return (
      `Fullteksten er ${String(metrics.characterCount)} tegn, og grensen er ` +
      `${String(READABILITY_THRESHOLDS.minCharacters)}. En fulltekstartikkel er tusenvis av ` +
      'tegn; et tynt eller ødelagt tekstlag er ikke en fulltekst noen kan kontrollere et ' +
      'ordrett utdrag mot.'
    )
  }
  if (metrics.lineCount < READABILITY_THRESHOLDS.minLines) {
    return (
      `Fullteksten har ${String(metrics.lineCount)} linjer, og grensen er ` +
      `${String(READABILITY_THRESHOLDS.minLines)}. Så få linjer er et sammendrag eller en ` +
      'forside, ikke en artikkel.'
    )
  }
  if (metrics.letterCount * 2 < metrics.characterCount) {
    return (
      `Bare ${String(metrics.letterCount)} av ${String(metrics.characterCount)} tegn er ` +
      'bokstaver, og grensen er halvparten. Et tekstlag som er mest tegnstøy, gir utdrag ' +
      'ingen kan lese tilbake til artikkelen.'
    )
  }
  if (metrics.tableRowCount < READABILITY_THRESHOLDS.minTableRows) {
    return (
      `Fullteksten har ${String(metrics.tableRowCount)} linjer med form som en datarad, og ` +
      `grensen er ${String(READABILITY_THRESHOLDS.minTableRows)}. Tallene i en artikkel står ` +
      'i tabellene; kom de ikke med i tekstuttrekkingen, ser teksten hel ut samtidig som ' +
      'nettopp de kliniske verdiene mangler.'
    )
  }
  if (metrics.tableDeclarationCount > 0 && metrics.tableRowCount < metrics.tableDeclarationCount) {
    return (
      `Fullteksten erklærer ${String(metrics.tableDeclarationCount)} tabeller, men har bare ` +
      `${String(metrics.tableRowCount)} linjer med form som en datarad. Minst én erklært ` +
      'tabell står dermed uten innhold, og en tabell som er borte, er ikke et fravær av ' +
      'data — den er data som ikke kom med.'
    )
  }
  return null
}
