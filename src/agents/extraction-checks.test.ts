import { describe, expect, it } from 'vitest'

import {
  checkExtraction,
  numberOccursIn,
  searchProjections,
  trimNumericText,
} from './extraction-checks'
import { FIXTURE_SOURCE_TEXT, verificationItemFixture } from './test-support'

function check(
  overrides: Parameters<typeof verificationItemFixture>[0] = {},
  sourceText: string = FIXTURE_SOURCE_TEXT,
  representationReproduced = true,
) {
  return checkExtraction({
    item: verificationItemFixture(overrides),
    sourceText,
    representationReproduced,
  })
}

describe('checkExtraction — den lykkede stien', () => {
  it('bekrefter et funn der sitatet og alle tallene står i kilden', () => {
    const report = check()
    expect(report.outcome).toBe('verified')
    expect(report.findings).toBeNull()
  })

  it('fører opp sitatet og kildepekeren som kontrollert', () => {
    expect(check().checkedFields).toEqual(
      expect.arrayContaining(['raw_extraction', 'source_locator']),
    )
  })

  it('fører opp tallene som kontrollert', () => {
    expect(check().checkedFields).toEqual(
      expect.arrayContaining(['sample_size', 'estimate', 'confidence_interval']),
    )
  })

  it('sier i begrunnelsen at ingen språkmodell er brukt', () => {
    expect(check().rationale).toContain('Ingen språkmodell er brukt')
  })
})

describe('checkExtraction — feilsitering', () => {
  it('avviser et sitat som ikke står ordrett i kilden', () => {
    const report = check({
      extraction: { rawExtraction: { sitat: 'Mean weight change was 4.9 kg' } },
    })
    expect(report.outcome).toBe('needs_correction')
    expect(report.findings).toContain('finnes ikke ordrett')
  })

  it('fører sitatfeltet opp som kontrollert også når kontrollen felte det', () => {
    // Et avvik er et resultat av en kontroll, ikke et fravær av en: uten dette
    // ville en avvist rad sett ut som om sitatet aldri var sett på.
    const report = check({
      extraction: { rawExtraction: { sitat: 'noe som ikke står der, i det hele tatt' } },
    })
    expect(report.checkedFields).toContain('raw_extraction')
  })

  it('finner et sitat som krysser markup i råsvaret', () => {
    // Sitatet spenner over to linjer og et element i fiksturen.
    const report = check({
      extraction: {
        rawExtraction: { metode: 'A total of 284 adults with major depressive disorder' },
      },
    })
    expect(report.outcome).toBe('verified')
  })

  it('finner et sitat med en avkodet entitet', () => {
    const report = check({
      extraction: {
        rawExtraction: { sitat: '(95% CI 0.4 to 2.6) & the difference was significant' },
      },
    })
    expect(report.outcome).toBe('verified')
  })

  it('finner et sitat med typografiske anførselstegn i den ene enden', () => {
    const report = check(
      { extraction: { rawExtraction: { sitat: '"Mean weight change over the trial"' } } },
      `${FIXTURE_SOURCE_TEXT}\n“Mean weight change over the trial”`,
    )
    expect(report.outcome).toBe('verified')
  })
})

describe('checkExtraction — tallene', () => {
  it('fører opp et tall som ble gjenfunnet som kontrollert', () => {
    expect(check().checkedFields).toContain('estimate')
  })

  // Et tall kan stå skrevet med bokstaver («Thirty-one HV») eller i en tabell
  // som ikke er med i representasjonen. Å kalle det et avvik ville produsert
  // falske anklager mot riktige ekstraksjoner.
  it('gjør et tall som ikke ble gjenfunnet til en uavklart kontroll, ikke til et avvik', () => {
    const report = check({ extraction: { estimate: '2.7' } })
    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toBeNull()
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.rationale).toContain('estimat (2.7)')
  })

  it('sier i begrunnelsen hvorfor et manglende talltreff ikke er et avvik', () => {
    const report = check({ extraction: { estimate: '2.7' } })
    expect(report.rationale).toContain('skrevet med bokstaver')
  })

  it('behandler en konfidensgrense som ikke ble gjenfunnet på samme måte', () => {
    const report = check({ extraction: { ciUpper: '9.9' } })
    expect(report.outcome).toBe('uncertain')
    expect(report.checkedFields).not.toContain('confidence_interval')
    expect(report.rationale).toContain('øvre konfidensgrense (9.9)')
  })

  it('behandler en utvalgsstørrelse som ikke ble gjenfunnet på samme måte', () => {
    const report = check({ extraction: { sampleSize: 285 } })
    expect(report.outcome).toBe('uncertain')
    expect(report.checkedFields).not.toContain('sample_size')
    expect(report.rationale).toContain('utvalgsstørrelse (285)')
  })

  // Rekkefølgen mellom de to: et sitat som ikke finnes, er falsifiserbart og
  // veier tyngre enn en kontroll som ikke konkluderte.
  it('lar et manglende sitat veie tyngre enn et manglende talltreff', () => {
    const report = check({
      extraction: {
        estimate: '2.7',
        rawExtraction: { sitat: 'står ikke i kilden i det hele tatt' },
      },
    })
    expect(report.outcome).toBe('needs_correction')
  })

  it('kontrollerer ikke et tall som ikke er oppgitt som rapportert', () => {
    // §19.1: en verdi finnes hvis og bare hvis statusen sier det. Et estimat
    // med statusen not_reported har ingen verdi å lete etter, og feltet skal
    // da ikke stå som kontrollert.
    const report = check({
      extraction: { estimate: null, estimateAvailability: 'not_reported' },
    })
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.outcome).toBe('verified')
  })

  it('godtar et tall skrevet med komma i kilden', () => {
    // Norske og engelske kilder skriver desimalskilletegnet ulikt, og tallet er
    // det samme. Bare estimatet er i spill her; den øvrige teksten er byttet
    // ut, så de andre kontrollene slår ut som de skal.
    const report = check({ extraction: { estimate: '1.5' } }, 'Vektendringen var 1,5 kg.')
    expect(report.findings).not.toContain('estimat')
  })
})

describe('checkExtraction — begreper som ikke lar seg kontrollere', () => {
  it('fører ikke opp et begrep som ikke ble gjenfunnet', () => {
    const report = check({ extraction: { outcomeLabel: 'vektendring' } })
    expect(report.checkedFields).not.toContain('outcome')
  })

  it('behandler et manglende begrepstreff som en merknad, ikke som et avvik', () => {
    const report = check({ extraction: { outcomeLabel: 'vektendring' } })
    expect(report.outcome).toBe('verified')
    expect(report.findings).toBeNull()
    expect(report.rationale).toContain('ikke ført opp som kontrollert')
  })

  it('fører opp komparatoren når den er et virkestoff som finnes i kilden', () => {
    const report = check({
      extraction: { comparatorKind: 'drug', comparatorDrugName: 'fluoxetine' },
    })
    expect(report.checkedFields).toContain('comparator_arm')
  })
})

describe('checkExtraction — når kontrollen ikke kan konkludere', () => {
  it('gir uncertain når funnet ikke har noe sitat å kontrollere', () => {
    const report = check({ extraction: { rawExtraction: null } })
    expect(report.outcome).toBe('uncertain')
  })

  it('fører ikke kildepekeren opp som kontrollert uten et sitat', () => {
    // evidence_verifications_locator_checked_check gjør da `verified` umulig i
    // basen også. De to reglene peker samme vei uten å stole på hverandre.
    const report = check({ extraction: { rawExtraction: null } })
    expect(report.checkedFields).not.toContain('source_locator')
  })

  it('gir uncertain når representasjonen ikke lot seg reprodusere', () => {
    const report = check({}, FIXTURE_SOURCE_TEXT, false)
    expect(report.outcome).toBe('uncertain')
    expect(report.rationale).toContain('ikke samme fingeravtrykk')
  })

  it('lar et avvik veie tyngre enn en manglende reproduksjon', () => {
    const report = check(
      { extraction: { rawExtraction: { sitat: 'står ikke her, og har aldri gjort det' } } },
      FIXTURE_SOURCE_TEXT,
      false,
    )
    expect(report.outcome).toBe('needs_correction')
  })
})

describe('numberOccursIn', () => {
  const projections = searchProjections('n = 284, estimat 1.5 (0.4 til 2.6), og 17 til.')

  it('finner et heltall', () => {
    expect(numberOccursIn(projections, '284')).toBe(true)
  })

  it('finner et desimaltall', () => {
    expect(numberOccursIn(projections, '1.5')).toBe(true)
  })

  it('finner ikke et tall som bare er en del av et annet', () => {
    expect(numberOccursIn(projections, '7')).toBe(false)
    expect(numberOccursIn(projections, '28')).toBe(false)
  })

  it('godtar etterfølgende nuller fra numeric', () => {
    expect(numberOccursIn(projections, '1.50')).toBe(true)
  })

  it('avviser en verdi som ikke er et tall', () => {
    expect(numberOccursIn(projections, 'ikke et tall')).toBe(false)
  })
})

describe('trimNumericText', () => {
  it('fjerner etterfølgende nuller uten å avrunde', () => {
    expect(trimNumericText('1.50')).toBe('1.5')
    expect(trimNumericText('12.000')).toBe('12')
    expect(trimNumericText('0.870')).toBe('0.87')
  })

  it('lar et heltall og et tall uten etterfølgende nuller stå', () => {
    expect(trimNumericText('120')).toBe('120')
    expect(trimNumericText('1.05')).toBe('1.05')
  })

  it('bevarer alle signifikante siffer i et langt desimaltall', () => {
    expect(trimNumericText('0.1234567890123456789')).toBe('0.1234567890123456789')
  })
})

describe('searchProjections', () => {
  it('gir én projeksjon for ren tekst og to når det finnes markup', () => {
    expect(searchProjections('ren tekst')).toHaveLength(1)
    expect(searchProjections('<p>med markup</p>')).toHaveLength(2)
  })
})
