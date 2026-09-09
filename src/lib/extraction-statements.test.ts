// ============================================================================
// Utsagnene kontrolløren faktisk svarer på
//
// To ting prøves: at setningen sier det raden sier, og at fravær står som
// fravær. Den andre er den viktigste — en setning som utelot et felt uten verdi,
// ville latt kontrolløren tro at det ikke var noe å ta stilling til.
// ============================================================================

import { describe, expect, it } from 'vitest'
import { designStatement, interpretField } from './extraction-statements'
import type { VerificationExtraction } from '../agents/verification-input'

function extraction(overrides: Partial<VerificationExtraction> = {}): VerificationExtraction {
  return {
    designCode: 'randomized_controlled_trial',
    populationLabel: 'voksne med depresjon',
    populationAvailability: 'reported_value',
    populationDetail: 'Voksne 18–65 år i poliklinisk behandling.',
    sampleSize: 48,
    sampleSizeAvailability: 'reported_value',
    interventionDrugName: 'sertralin',
    interventionDetail: '50 mg daglig',
    comparatorKind: 'none',
    comparatorDrugName: null,
    comparatorDetail: null,
    outcomeLabel: 'vektendring',
    outcomeDetail: 'Endring i kroppsvekt fra baseline.',
    timepointMin: '56 days',
    timepointMax: '56 days',
    timepointAvailability: 'reported_value',
    reportedDirection: 'increase',
    effectMeasure: 'mean_change',
    estimate: '1.7',
    estimateUnit: 'kg',
    estimateAvailability: 'reported_value',
    ciLower: '0.9',
    ciUpper: '2.5',
    ciLevelPercent: '95',
    confidenceIntervalAvailability: 'reported_value',
    limitationsText: null,
    sourceLocator: 'Tabell 2, side 114',
    rawExtraction: { sitat: 'Mean weight change was 1.7 kg.' },
    ...overrides,
  }
}

describe('interpretField', () => {
  it('formulerer studiedesignet som en setning', () => {
    expect(designStatement(extraction())).toBe(
      'Dette er registrert som en randomisert kontrollert studie.',
    )
  })

  it('sier hvor mange deltakere studien inkluderte', () => {
    expect(interpretField('sample_size', extraction()).statement).toBe(
      'Studien inkluderte 48 deltakere.',
    )
  })

  it('sier hvilken populasjon funnet gjelder, med utdypningen under', () => {
    const interpretation = interpretField('population', extraction())
    expect(interpretation.statement).toBe('Populasjonen er voksne med depresjon.')
    expect(interpretation.detail).toBe('Voksne 18–65 år i poliklinisk behandling.')
  })

  it('sier at et funn uten komparator gjelder én arm', () => {
    expect(interpretField('comparator_arm', extraction()).statement).toBe(
      'Dette funnet gjelder sertralin uten en separat sammenligningsarm.',
    )
  })

  it('navngir komparatorvirkestoffet når det finnes', () => {
    expect(
      interpretField(
        'comparator_arm',
        extraction({ comparatorKind: 'drug', comparatorDrugName: 'fluoksetin' }),
      ).statement,
    ).toBe('Sammenligningen er mot fluoksetin.')
  })

  it('gjengir tidsrommet som en varighet', () => {
    expect(interpretField('timepoint', extraction()).statement).toBe(
      'Målingen gjelder 56 dager etter oppstart.',
    )
  })

  // Tallet gjengis ordrett slik det er lagret. En lokalisering ville krevd en
  // tolkning av strengen, og det er nettopp i dette steget kontrolløren
  // sammenligner tegn for tegn med kilden.
  it('gjengir estimatet ordrett, med enheten', () => {
    expect(interpretField('estimate', extraction()).statement).toBe('Den målte effekten er 1.7 kg.')
    expect(interpretField('confidence_interval', extraction()).statement).toBe(
      'Konfidensintervallet er 0.9 til 2.5 (95 %).',
    )
  })

  it('sier hvorfor et felt uten verdi ikke har en', () => {
    const interpretation = interpretField(
      'sample_size',
      extraction({ sampleSize: null, sampleSizeAvailability: 'not_reported' }),
    )
    expect(interpretation.statement).toContain('ikke ført med en verdi')
    expect(interpretation.statement).toContain('ikke rapportert i kilden')
  })

  it('lister feltene uten verdi under begrunnelseskontrollen', () => {
    const interpretation = interpretField(
      'availability_semantics',
      extraction({
        sampleSize: null,
        sampleSizeAvailability: 'not_reported',
        estimate: null,
        estimateAvailability: 'not_measured',
      }),
    )
    expect(interpretation.statement).toContain('2 felt uten verdi')
    expect(interpretation.detail).toContain('Antall deltakere: Ikke rapportert i kilden.')
    expect(interpretation.detail).toContain('Estimatet: Ikke målt i studien.')
  })

  it('sier at ingen forbehold er registrert, framfor å utelate spørsmålet', () => {
    expect(interpretField('limitations', extraction()).statement).toBe(
      'Ingen forbehold er registrert på dette funnet.',
    )
  })

  it('gjengir den rå ekstraksjonen ordrett når den finnes', () => {
    expect(interpretField('raw_extraction', extraction()).detail).toBe(
      'Mean weight change was 1.7 kg.',
    )
    expect(
      interpretField('raw_extraction', extraction({ rawExtraction: null })).statement,
    ).toContain('Ingen ordrett gjengivelse')
  })

  it('sier hvor i kilden funnet står', () => {
    expect(interpretField('source_locator', extraction()).statement).toBe(
      'Funnet er hentet fra «Tabell 2, side 114» i kilden.',
    )
  })

  // En feltverdi Antidep ikke kjenner skal ikke forsvinne: et felt uten spørsmål
  // ville sett ut som et felt uten påstand.
  it('gir et ukjent felt sin egen setning framfor å utelate det', () => {
    const interpretation = interpretField('noe_helt_nytt', extraction())
    expect(interpretation.statement).toContain('kjenner ikke feltet')
    expect(interpretation.heading).toContain('noe_helt_nytt')
  })
})
