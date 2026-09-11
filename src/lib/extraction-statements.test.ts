// ============================================================================
// Utsagnene kontrolløren faktisk svarer på
//
// To ting prøves: at setningen sier det raden sier, og at fravær står som
// fravær. Den andre er den viktigste — en setning som utelot et felt uten verdi,
// ville latt kontrolløren tro at det ikke var noe å ta stilling til.
// ============================================================================

import { describe, expect, it } from 'vitest'
import { controlSubjectStatement, designStatement, interpretField } from './extraction-statements'
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

  // `sample_size` er antallet observasjoner ESTIMATET bygger på, ikke studiens
  // totale inklusjon. Fava 2000 randomiserte 284, og 96 til sertralin, mens
  // langtidsresultatet hviler på de 48 som fullførte — «studien inkluderte 48
  // deltakere» er ganske enkelt feil om den studien.
  it('sier hva estimatet bygger på, ikke hva studien inkluderte', () => {
    const interpretation = interpretField('sample_size', extraction())
    expect(interpretation.statement).toBe('Dette estimatet bygger på 48 deltakere.')
    expect(interpretation.statement).not.toContain('Studien inkluderte')
    expect(interpretation.kind).toBe('interpretation')
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

  // Kilden sier uker. Kontrolløren skal slippe å kontrollregne, og den
  // kanoniske varigheten i databasen skal likevel stå.
  it('viser uker som hovedform, med dagene som eksplisitt omregning', () => {
    expect(interpretField('timepoint', extraction()).statement).toBe(
      'Målingen gjelder 8 uker (registrert som 56 dager) etter oppstart.',
    )
  })

  it('viser et spenn i uker med dagene ved siden av, som Fava 2000 oppgir det', () => {
    expect(
      interpretField(
        'timepoint',
        extraction({ timepointMin: '182 days', timepointMax: '224 days' }),
      ).statement,
    ).toBe('Målingen gjelder 26 til 32 uker (registrert som 182 til 224 dager) etter oppstart.')
  })

  it('gjengir varigheten i dager når den ikke er hele uker', () => {
    expect(
      interpretField('timepoint', extraction({ timepointMin: '10 days', timepointMax: '10 days' }))
        .statement,
    ).toBe('Målingen gjelder 10 dager etter oppstart.')
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

  // Et felt uten verdi er en MANGEL, ikke en tolkning. Setningen sier hva som
  // ikke er ført og hvorfor, og flaten spør om noe annet enn den gjør om en
  // tolkning (`ExtractionFieldStep.tsx`).
  it('presenterer et felt uten verdi som en mangel, med grunnen', () => {
    const interpretation = interpretField(
      'sample_size',
      extraction({ sampleSize: null, sampleSizeAvailability: 'not_reported' }),
    )
    expect(interpretation.kind).toBe('absence')
    expect(interpretation.statement).toBe(
      'Antidep har ikke ført hvor mange observasjoner dette estimatet bygger på. Ikke rapportert i kilden.',
    )
  })

  // Eksempelet fra den første reelle kildekontrollen: et manglende
  // konfidensintervall skal si nettopp det — ikke bli til en klinisk påstand om
  // at effekten ikke var signifikant (ANTIDEP_CONSTITUTION.md §6).
  it('sier at konfidensintervallet mangler, uten å tolke fraværet', () => {
    const interpretation = interpretField(
      'confidence_interval',
      extraction({
        ciLower: null,
        ciUpper: null,
        ciLevelPercent: null,
        confidenceIntervalAvailability: 'not_reported',
      }),
    )
    expect(interpretation.kind).toBe('absence')
    expect(interpretation.statement).toBe(
      'Antidep har ikke ført et konfidensintervall for dette estimatet. Ikke rapportert i kilden.',
    )
    expect(interpretation.statement).not.toContain('signifikant')
  })

  // Ikke «Antidep har ført 1 felt uten verdi, med en begrunnelse for hvert».
  // Et antall er bokføring, og en kontrollør kan ikke holde det opp mot en
  // artikkel.
  it('navngir hva som mangler, framfor å telle felter', () => {
    const interpretation = interpretField(
      'availability_semantics',
      extraction({
        ciLower: null,
        ciUpper: null,
        ciLevelPercent: null,
        confidenceIntervalAvailability: 'not_reported',
      }),
    )
    expect(interpretation.kind).toBe('absence')
    expect(interpretation.statement).toBe(
      'Antidep har ikke ført et konfidensintervall for estimatet. Ikke rapportert i kilden.',
    )
    expect(interpretation.statement).not.toMatch(/\d+ felt/)
  })

  it('lister hvert felt uten verdi når det er flere av dem', () => {
    const interpretation = interpretField(
      'availability_semantics',
      extraction({
        sampleSize: null,
        sampleSizeAvailability: 'not_reported',
        estimate: null,
        estimateAvailability: 'not_measured',
      }),
    )
    expect(interpretation.kind).toBe('absence')
    expect(interpretation.detail).toContain('Antall deltakere: Ikke rapportert i kilden.')
    expect(interpretation.detail).toContain('Estimatet: Ikke målt i studien.')
  })

  it('sier at alle verdifeltene er ført, når ingenting mangler', () => {
    const interpretation = interpretField('availability_semantics', extraction())
    expect(interpretation.kind).toBe('interpretation')
    expect(interpretation.statement).toBe('Alle de fem verdifeltene er ført som oppgitt av kilden.')
  })

  it('sier at ingen forbehold er registrert, framfor å utelate spørsmålet', () => {
    const interpretation = interpretField('limitations', extraction())
    expect(interpretation.kind).toBe('absence')
    expect(interpretation.statement).toBe('Antidep har ikke ført noen forbehold ved dette funnet.')
  })

  it('gjengir den rå ekstraksjonen ordrett når den finnes', () => {
    expect(interpretField('raw_extraction', extraction()).detail).toBe(
      'Mean weight change was 1.7 kg.',
    )
    expect(
      interpretField('raw_extraction', extraction({ rawExtraction: null })).statement,
    ).toContain('ordrett gjengivelse')
  })

  it('sier hvor i kilden funnet står', () => {
    expect(interpretField('source_locator', extraction()).statement).toBe(
      'Funnet er hentet fra «Tabell 2, side 114» i kilden.',
    )
  })

  // «Endepunktet» og «Effektmålet» leste som duplikater i den første reelle
  // kildekontrollen. Forskjellen er nettopp den en kontrollør må se: hva som ble
  // målt, og hvordan resultatet er uttrykt.
  it('skiller endepunktet fra hvordan resultatet er uttrykt', () => {
    const outcome = interpretField('outcome', extraction())
    const measure = interpretField('effect_measure', extraction())
    expect(outcome.statement).toBe('Det målte endepunktet er vektendring.')
    expect(measure.heading).toBe('Hvordan resultatet er uttrykt')
    expect(measure.statement).toBe(
      'Resultatet er uttrykt som gjennomsnittlig endring, oppgitt i kg.',
    )
  })

  it('sier at et effektmål ikke er ført, uten å låne en begrunnelse fra et annet felt', () => {
    const interpretation = interpretField('effect_measure', extraction({ effectMeasure: null }))
    expect(interpretation.kind).toBe('absence')
    expect(interpretation.statement).toBe('Antidep har ikke ført et effektmål for dette funnet.')
  })

  // En feltverdi Antidep ikke kjenner skal ikke forsvinne: et felt uten spørsmål
  // ville sett ut som et felt uten påstand.
  it('gir et ukjent felt sin egen setning framfor å utelate det', () => {
    const interpretation = interpretField('noe_helt_nytt', extraction())
    expect(interpretation.statement).toContain('kjenner ikke feltet')
    expect(interpretation.heading).toContain('noe_helt_nytt')
  })
})

// ----------------------------------------------------------------------------
// Innledningen til kontrolløkten
// ----------------------------------------------------------------------------

describe('controlSubjectStatement', () => {
  it('sier hva som skal kontrolleres: endepunkt, virkestoff og populasjon', () => {
    expect(controlSubjectStatement(extraction())).toBe(
      'Du skal nå kontrollere Antideps vurdering av hva kilden sier om vektendring ved bruk av ' +
        'sertralin hos voksne med depresjon.',
    )
  })

  // Ingen populasjon er koblet. Setningen skal da ikke finne på en.
  it('utelater populasjonen når ingen er koblet', () => {
    expect(controlSubjectStatement(extraction({ populationLabel: null }))).toBe(
      'Du skal nå kontrollere Antideps vurdering av hva kilden sier om vektendring ved bruk av ' +
        'sertralin.',
    )
  })
})
