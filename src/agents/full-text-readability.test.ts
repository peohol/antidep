import { readFile } from 'node:fs/promises'
import { describe, expect, it } from 'vitest'

import {
  READABILITY_THRESHOLDS,
  readabilityMetrics,
  readabilityProblem,
} from './full-text-readability.ts'

const MIGRATION = 'supabase/migrations/20260926091000_full_text_library.sql'

/**
 * En tekst som ser ut som en artikkel: brødtekst nok, og en tabell som kom med.
 *
 * Mellomrommene mellom cellene er *enkle*, slik Antideps leserekkefølge faktisk
 * setter dem. En fikstur med kolonner justert av flere mellomrom ville vært en
 * fikstur av `pdftotext -layout` — en oppskrift Antidep ikke registrerer nye
 * kildeversjoner med — og prøven ville da bekreftet en regel kjeden aldri møter.
 */
function readableFullText(): string {
  const body = Array.from(
    { length: 80 },
    (_unused, index) =>
      `Patients with major depressive disorder were randomised to treatment (line ${String(index)}).`,
  ).join('\n')
  return [
    body,
    'Table 1 Baseline characteristics',
    'Age (years) 42.1 41.8',
    'Weight (kg) 74.2 73.9',
    'BMI (kg/m2) 25.1 24.8',
  ].join('\n')
}

describe('readabilityMetrics', () => {
  it('teller datarader og tabellerklæringer hver for seg', () => {
    const metrics = readabilityMetrics(readableFullText())
    expect(metrics.tableRowCount).toBe(3)
    expect(metrics.tableDeclarationCount).toBe(1)
  })

  it('leser en resultatsetning som brødtekst, ikke som en datarad', () => {
    // Fire tall blant sytten ord. Tallene er der, men de dominerer ikke linjen,
    // og en setning er ikke en tabellrad.
    const sentence =
      'Mean percent weight change was 1.0% at endpoint with a 95% confidence interval from 0.5% to 1.5%.'
    expect(readabilityMetrics(sentence).tableRowCount).toBe(0)
  })

  it('teller bokstaver etter Unicode og ikke etter det engelske alfabetet', () => {
    // En artikkel med norske tegn er ikke mindre lesbar av den grunn.
    expect(readabilityMetrics('Vektøkning').letterCount).toBe(10)
  })
})

describe('readabilityProblem', () => {
  it('godtar en fulltekst med brødtekst og en overlevd tabell', () => {
    expect(readabilityProblem(readableFullText())).toBeNull()
  })

  it('avviser et sammendrag på mengde tekst', () => {
    expect(readabilityProblem('Kort sammendrag.')).toContain('3000')
  })

  it('avviser en artikkel der tabellene ble droppet som bilder', () => {
    // Brødteksten er uendret. Det er nettopp derfor denne formen er farlig:
    // teksten ser hel ut, og de kliniske tallene mangler.
    const withoutTables = readableFullText()
      .split('\n')
      .filter((line) => !/^(Age|Weight|BMI)/.test(line))
      .join('\n')
    expect(readabilityProblem(withoutTables)).toContain('datarad')
  })

  it('avviser en tekst som er mest tegnstøy', () => {
    const noise = Array.from({ length: 120 }, () => '### ~~~ ### ~~~ ### ~~~ ### ~~~ 1  2  3').join(
      '\n',
    )
    expect(readabilityProblem(noise)).toContain('bokstaver')
  })

  it('avviser et dokument som erklærer flere tabeller enn det har datarader til', () => {
    const lines = readableFullText().split('\n')
    // Fire erklæringer og fortsatt tre datarader: mengden datarader er over
    // grensen, så det er *forholdet* mellom erklæringer og innhold som slår ut.
    lines.splice(
      1,
      0,
      'Table 2  Efficacy outcomes',
      'Table 3  Adverse events',
      'Table 4  Laboratory values',
    )
    expect(readabilityProblem(lines.join('\n'))).toContain('erklærer')
  })
})

// ----------------------------------------------------------------------------
// Speilet mot fasiten
//
// Databasen avgjør. Blir de to uenige om en terskel, er det denne modulen som
// er feil — og da skal prøven si det, framfor at en redaktør får en avvisning
// fra serveren som motsier den hen nettopp fikk lokalt.
// ----------------------------------------------------------------------------
describe('tersklene er de samme som databasens', () => {
  it('finner hver terskel igjen i migrasjon 009a', async () => {
    const sql = await readFile(MIGRATION, 'utf8')
    expect(sql).toContain(`v_characters < ${String(READABILITY_THRESHOLDS.minCharacters)}`)
    expect(sql).toContain(`v_lines < ${String(READABILITY_THRESHOLDS.minLines)}`)
    expect(sql).toContain(`v_table_rows < ${String(READABILITY_THRESHOLDS.minTableRows)}`)
    // Bokstavandelen er skrevet som en multiplikasjon begge steder, fordi en
    // halvpart uttrykt som 0.5 ville vært flyttall i den ene og ikke i den andre.
    expect(sql).toContain('v_letters * 2 < v_characters')
    expect(READABILITY_THRESHOLDS.minLetterRatio).toBe(0.5)
  })

  // Regelen for en datarad er den ene som ikke kan leses av en terskel: den er
  // et mønster. Den prøves derfor mot **den teksten kjeden faktisk lager** —
  // en ekte PDF gjennom det ekte verktøyet og Antideps egen leserekkefølge.
  //
  // Den første utgaven av denne regelen lette etter kolonner skilt av flere
  // mellomrom, slik `pdftotext -layout` setter dem. Leserekkefølgen setter ett,
  // så regelen fant ingen tabellrader i det hele tatt, og lesbarhetskontrollen
  // ville avvist hver eneste ekte artikkel. En prøve mot en håndskrevet streng
  // ville vært grønn hele veien.
  it('finner dataradene i teksten kjeden faktisk lager av en PDF', async () => {
    const { currentPdfRecipe, extractDocumentText } = await import('./document-text.ts')
    const { syntheticArticlePdf } = await import('./test-support.ts')

    const recipe = await currentPdfRecipe()
    expect(recipe.status).toBe('ok')
    if (recipe.status !== 'ok') return

    const extracted = await extractDocumentText({
      bytes: syntheticArticlePdf(['Mean percent weight change was 1.0% at endpoint.']),
      recipe: recipe.recipe,
    })
    expect(extracted.status).toBe('ok')
    if (extracted.status !== 'ok') return

    expect(readabilityMetrics(extracted.extracted.text).tableRowCount).toBe(3)
    expect(readabilityProblem(extracted.extracted.text)).toBeNull()
  })
})
