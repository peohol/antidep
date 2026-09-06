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
    // Paret er det som mangler, ikke ett tall: kilden har et intervall, men
    // ikke dette. Begrunnelsen navngir derfor grensene som ett uttrykk.
    expect(report.rationale).toContain('konfidensgrensene (0.4 til 9.9)')
  })

  // Nivået hører til intervallet: «0,4 til 2,6» er en annen påstand med 90 %
  // enn med 95 %. Grensene alene er derfor ikke nok til å føre feltet som
  // kontrollert — ellers ville auditsporet sagt at intervallet var etterprøvd
  // mot en kilde som oppgir noe annet.
  it('fører ikke konfidensintervallet som kontrollert når nivået ikke stemmer', () => {
    const report = check({ extraction: { ciLevelPercent: '90' } })

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
    expect(report.rationale).toContain('konfidensnivå (90)')
  })

  it('fører konfidensintervallet som kontrollert når grensene og nivået alle står der', () => {
    const report = check()

    expect(report.checkedFields).toContain('confidence_interval')
  })

  // Nøyaktig eksempelet fra gjennomgangen. Alle tre tallene finnes i teksten —
  // `90` som utvalgsstørrelse, `0.4` og `2.6` fra et intervall som er oppgitt
  // med *et annet* nivå. Tre uavhengige tallsøk fant dem og sa `verified`.
  // Intervallet er én påstand, og et tall et annet sted kan ikke tre inn i den.
  it('lar ikke et tilfeldig 90 et annet sted bekrefte et 90 %-intervall mot en 95 %-kilde', () => {
    const kilde =
      'Among 284 adults with depression, 90 participants were enrolled at site B. ' +
      'Mean weight change was 1.5 kg (95% CI 0.4 to 2.6) over the study period.'
    const report = check(
      {
        extraction: {
          ciLevelPercent: '90',
          rawExtraction: { sitat: 'Mean weight change was 1.5 kg (95% CI 0.4 to 2.6)' },
        },
      },
      kilde,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
    // Grensene ble funnet i intervalluttrykket; det er nivået som ikke hører til.
    expect(report.rationale).toContain('konfidensnivå (90)')
  })

  // Samme feilklasse den andre veien: grensene finnes, men fra to forskjellige
  // intervaller. Ingen av dem er det registrerte.
  it('bekrefter ikke et intervall satt sammen av grenser fra to forskjellige uttrykk', () => {
    const kilde =
      'Weight change was 1.5 kg (95% CI 0.4 to 1.9). ' +
      'Quality of life improved (95% CI 1.1 to 2.6).'
    const report = check(
      {
        extraction: {
          rawExtraction: { sitat: 'Weight change was 1.5 kg (95% CI 0.4 to 1.9)' },
        },
      },
      kilde,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  it.each([
    ['95% CI 0.4 to 2.6', 'Mean weight change was 1.5 kg (95% CI 0.4 to 2.6).'],
    ['CI etter nivået med kolon', 'Mean weight change was 1.5 kg (CI 95%: 0.4 to 2.6).'],
    ['nivået skrevet ut', 'Mean weight change was 1.5 kg, 95% confidence interval 0.4 to 2.6.'],
    ['grensene før ankeret', 'Mean weight change was 1.5 kg, 0.4 to 2.6 (95% CI).'],
    ['norsk kilde', 'Vektendringen var 1,5 kg (95 % konfidensintervall 0,4 til 2,6).'],
    // Den vanligste skrivemåten i MEDLINE-sammendrag. Utenfor et navngitt
    // intervall leses en bindestrek fortsatt ikke som intervallstrek.
    ['bindestrek som intervallstrek', 'Mean weight change was 1.5 kg (95% CI 0.4-2.6).'],
  ])('kjenner igjen intervallet skrevet som «%s»', (_navn, kilde) => {
    const report = check(
      { extraction: { rawExtraction: { sitat: 'Mean weight change' } } },
      `Mean weight change. ${kilde}`,
    )

    expect(report.checkedFields).toContain('confidence_interval')
  })

  // Navngir ikke kilden intervallet, er utfallet uavklart og ikke et avvik:
  // grensene kan stå i en tabell som ikke er med i representasjonen.
  it('melder ikke avvik når kilden ikke navngir noe konfidensintervall', () => {
    const report = check(
      { extraction: { rawExtraction: { sitat: 'Mean weight change was 1.5 kg' } } },
      'Mean weight change was 1.5 kg, from 0.4 to 2.6, among 284 adults.',
    )

    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toBeNull()
    expect(report.checkedFields).not.toContain('confidence_interval')
    expect(report.rationale).toContain('navngir ikke noe konfidensintervall')
  })

  // Presisjonsfellen, sett fra kontrollen: den avrundede verdien står i
  // kilden, den registrerte gjør ikke. Ville tallet kommet inn som et
  // JSON-tall, hadde de to vært samme verdi her — og kontrollen ville
  // bekreftet et estimat som ikke står i kilden.
  it('bekrefter ikke et estimat der bare den avrundede verdien står i kilden', () => {
    const report = check(
      {
        extraction: {
          estimate: '9007199254740993',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
        },
      },
      `${FIXTURE_SOURCE_TEXT} Estimatet var 9007199254740992.`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.rationale).toContain('estimat (9007199254740993)')
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

  // Den klinisk viktigste av talltestene: et fortegn som er snudd, skal aldri
  // ende i `verified`.
  it('bekrefter ikke et estimat der fortegnet er snudd', () => {
    const report = check(
      { extraction: { estimate: '-1.5' } },
      'Mean weight change was 1.5 kg (95% CI 0.4 to 2.6)',
    )
    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.rationale).toContain('estimat (-1.5)')
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

  it('finner ikke et tall som bare er heltallsdelen av et desimaltall', () => {
    expect(numberOccursIn(searchProjections('verdien var 12.5 kg'), '12')).toBe(false)
  })
})

// Fortegnet er en del av tallet. En vektendring på −1,5 kg og en på 1,5 kg
// peker motsatt vei, så en kontroll som blandet dem ville kunnet bekrefte et
// funn som snur effektretningen.
describe('numberOccursIn — fortegn', () => {
  const positive = searchProjections('gjennomsnittlig endring var 1.5 kg')
  const negative = searchProjections('gjennomsnittlig endring var -1.5 kg')

  it('finner ikke et negativt tall i en kilde som oppgir det positive', () => {
    expect(numberOccursIn(positive, '-1.5')).toBe(false)
  })

  it('finner ikke et positivt tall i en kilde som oppgir det negative', () => {
    expect(numberOccursIn(negative, '1.5')).toBe(false)
  })

  it('finner et negativt tall når kilden faktisk oppgir det', () => {
    expect(numberOccursIn(negative, '-1.5')).toBe(true)
  })

  it('finner et negativt tall skrevet med typografisk minustegn', () => {
    expect(numberOccursIn(searchProjections('endringen var −1,5 kg'), '-1.5')).toBe(true)
  })

  it('leser ikke en bindestrek i et intervall som et minustegn', () => {
    expect(numberOccursIn(searchProjections('mirtazapin 15-60 mg/døgn'), '-60')).toBe(false)
  })

  // Følgen av regelen over, og den er bevisst: et tvilstilfelle skal bli
  // uavklart, ikke en bekreftelse.
  it('finner heller ikke det positive tallet i et bindestrek-intervall', () => {
    expect(numberOccursIn(searchProjections('mirtazapin 15-60 mg/døgn'), '60')).toBe(false)
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

// Kildeinnhold er utrygg ekstern data. Én ugyldig entitet i én kilde skal ikke
// kunne stoppe kontrollen av resten av køen — og før denne rettelsen kastet
// `String.fromCodePoint` en RangeError som gjorde nettopp det.
describe('searchProjections — ugyldige entiteter i kildeinnhold', () => {
  it.each([
    ['&#x110000;', 'kodepunkt over U+10FFFF, heksadesimalt'],
    ['&#1114112;', 'kodepunkt over U+10FFFF, desimalt'],
    ['&#99999999999999999999;', 'et tall som er større enn noe kodepunkt'],
    ['&#xFFFFFFFFFFFF;', 'et heksadesimalt tall uten øvre grense'],
  ])('kaster ikke på %s (%s)', (entity) => {
    expect(() => searchProjections(`<p>${entity}</p>`)).not.toThrow()
  })

  it('beholder en ugyldig entitet ordrett framfor å gjette på hva den var', () => {
    expect(searchProjections('&#x110000;')[0]).toContain('&#x110000;')
  })

  it('avkoder fortsatt en gyldig entitet', () => {
    expect(searchProjections('&#xe6; &#229; &amp;')[0]).toBe('æ å &')
  })

  it('stopper ikke kontrollen av et funn når kilden har en ugyldig entitet', () => {
    const report = checkExtraction({
      item: verificationItemFixture(),
      sourceText: `${FIXTURE_SOURCE_TEXT}\n<p>&#x110000;</p>`,
      representationReproduced: true,
    })
    expect(report.outcome).toBe('verified')
  })
})

describe('searchProjections', () => {
  it('gir én projeksjon for ren tekst og to når det finnes markup', () => {
    expect(searchProjections('ren tekst')).toHaveLength(1)
    expect(searchProjections('<p>med markup</p>')).toHaveLength(2)
  })
})
