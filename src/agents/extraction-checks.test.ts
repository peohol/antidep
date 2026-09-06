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

  // De tre neste prøver sitatmatchingen alene. De erstatter fiksturens utdrag
  // med ett smalt sitat, og da har ikke de øvrige tallfeltene lenger et utdrag
  // som dekker dem — utfallet for raden sier derfor noe annet enn det disse
  // testene handler om. Asserten er at sitatet ble gjenfunnet.
  it('finner et sitat som krysser markup i råsvaret', () => {
    // Sitatet spenner over to linjer og et element i fiksturen.
    const report = check({
      extraction: {
        rawExtraction: { metode: 'A total of 284 adults with major depressive disorder' },
      },
    })
    expect(report.checkedFields).toContain('raw_extraction')
    expect(report.findings).not.toContain('finnes ikke ordrett')
  })

  it('finner et sitat med en avkodet entitet', () => {
    const report = check({
      extraction: {
        rawExtraction: { sitat: '(95% CI 0.4 to 2.6) & the difference was significant' },
      },
    })
    expect(report.checkedFields).toContain('raw_extraction')
    expect(report.findings).not.toContain('finnes ikke ordrett')
  })

  it('finner et sitat med typografiske anførselstegn i den ene enden', () => {
    const report = check(
      { extraction: { rawExtraction: { sitat: '"Mean weight change over the trial"' } } },
      `${FIXTURE_SOURCE_TEXT}\n“Mean weight change over the trial”`,
    )
    expect(report.checkedFields).toContain('raw_extraction')
    expect(report.findings).not.toContain('finnes ikke ordrett')
  })
})

// `workflow.evidence_verifications` krever en ikke-tom `findings` for alt som
// ikke er `verified` (evidence_verifications_findings_required_check). Uten
// dette ble en helt normal uavklart kontroll avvist av basen, og hele
// agentkjøringen falt — prøvd ende-til-ende mot databasen.
describe('checkExtraction — kontrakten mot databasen', () => {
  it.each([
    ['tall som ikke ble gjenfunnet', { extraction: { estimate: '2.7' } }],
    [
      'sitat som ikke står i kilden',
      { extraction: { rawExtraction: { sitat: 'står ikke der i det hele tatt' } } },
    ],
    ['representasjonen er en annen utgave', {}],
  ])('gir en ikke-tom findings for et uavklart utfall (%s)', (navn, overrides) => {
    const report =
      navn === 'representasjonen er en annen utgave'
        ? check({}, FIXTURE_SOURCE_TEXT, false)
        : check(overrides)

    expect(report.outcome).not.toBe('verified')
    expect(report.findings).not.toBeNull()
    expect(report.findings?.trim()).not.toBe('')
    expect((report.findings ?? '').length).toBeLessThanOrEqual(4000)
  })

  it('lar findings være tom bare når kontrollen faktisk bekreftet raden', () => {
    const report = check()

    expect(report.outcome).toBe('verified')
    expect(report.findings).toBeNull()
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
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.rationale).toContain('estimat (2.7)')
    // Basen krever en begrunnelse for alt som ikke er `verified`
    // (evidence_verifications_findings_required_check). Den skal si at
    // kontrollen ikke konkluderte, ikke at noe er galt.
    expect(report.findings).toContain('Kontrollen konkluderte ikke')
    expect(report.findings).toContain('estimat (2.7)')
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

  // En artikkel beskriver flere armer. Tallet finnes — men for en annen arm enn
  // den raden gjelder, og da er det ikke denne raden som er kontrollert.
  it('bekrefter ikke en utvalgsstørrelse som tilhører en annen arm i samme artikkel', () => {
    const kilde =
      'Patients (fluoxetine, N = 44; paroxetine, N = 48) completed the trial. ' +
      'Sertraline-treated patients had a modest weight increase.'
    const report = check(
      {
        extraction: {
          sampleSize: 48,
          rawExtraction: { sitat: 'Sertraline-treated patients had a modest weight increase.' },
        },
      },
      kilde,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('sample_size')
    expect(report.rationale).toContain('utvalgsstørrelse (48)')
  })

  it('bekrefter ikke et estimat som tilhører et annet utfall i samme artikkel', () => {
    const kilde =
      'Quality of life improved by a mean difference of 0.8 points. ' +
      'Weight did not change appreciably in either group.'
    const report = check(
      {
        extraction: {
          estimate: '0.8',
          rawExtraction: { sitat: 'Weight did not change appreciably in either group.' },
        },
      },
      kilde,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
  })

  it('sier i begrunnelsen hvorfor tallene ikke kunne kontrolleres uten et gjenfunnet utdrag', () => {
    const report = check(
      {
        extraction: { rawExtraction: { sitat: 'et sitat som ikke står i kilden i det hele tatt' } },
      },
      'A total of 284 adults. Mean weight change was 1.5 kg (95% CI 0.4 to 2.6).',
    )

    expect(report.checkedFields).not.toContain('sample_size')
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.rationale).toContain('ingen tekst som tilhører nettopp dette funnet')
  })

  // Et helt vanlig utdrag beskriver flere armer i én setning. Da står den
  // registrerte verdien der — men det gjør de andre armenes verdier også, og
  // ingenting binder maskinelt en av dem til nettopp denne raden.
  it.each([48, 44, 47])(
    'bekrefter ikke utvalgsstørrelse %s fra et utdrag som oppgir flere armer',
    (størrelse) => {
      const utdrag =
        'Patients (fluoxetine, N = 44; sertraline, N = 48; paroxetine, N = 47) who ' +
        'completed the trial were included in these analyses.'
      const report = check(
        { extraction: { sampleSize: størrelse, rawExtraction: { resultat: utdrag } } },
        `Forord. ${utdrag}`,
      )

      expect(report.outcome).not.toBe('verified')
      expect(report.checkedFields).not.toContain('sample_size')
      expect(report.rationale).toContain('flere verdier for de samme feltene')
    },
  )

  it('bekrefter ikke et estimat fra et utdrag som oppgir to armer i samme setning', () => {
    const utdrag =
      'The mean difference was 0.8 kg for mirtazapine and the mean difference was 0.4 kg ' +
      'for fluoxetine.'
    const report = check(
      { extraction: { estimate: '0.8', rawExtraction: { resultat: utdrag } } },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
  })

  it('bekrefter ikke et konfidensintervall fra et utdrag som oppgir to intervaller', () => {
    const utdrag =
      'Weight change was 1.5 kg (95% CI 0.4 to 2.6) and quality of life improved ' +
      '(95% CI 1.1 to 3.2) over the study period.'
    const report = check(
      { extraction: { rawExtraction: { resultat: utdrag } } },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
    expect(report.rationale).toContain('flere verdier for de samme feltene')
  })

  // Et nakent tall ved ankeret er ikke et nivå. Her er `90` en utvalgsstørrelse,
  // og kilden sier aldri prosent — den sier ikke hvilket nivå intervallet har.
  it('bekrefter ikke et nivå kilden aldri oppgir som prosent', () => {
    const report = check(
      { extraction: { ciLevelPercent: '90', rawExtraction: { sitat: 'Mean weight change' } } },
      'Mean weight change. n=90; CI 0.4 to 2.6',
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  // Kilden sier uttrykkelig at intervallet ikke er rapportert. Nivået står ved
  // ankeret og grenseparet finnes i teksten, men de er ikke det samme uttrykket.
  it('bekrefter ikke et intervall kilden sier den ikke har rapportert', () => {
    const report = check(
      { extraction: { rawExtraction: { sitat: 'Mean weight change' } } },
      'Mean weight change. 95% CI was not reported; observed values ranged from 0.4 to 2.6.',
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  // «Kort og sifferfritt» er ikke det samme som «nøytralt». Begge disse er
  // korte og uten siffer, og begge snur betydningen av tallene som følger.
  it.each([
    ['was not', 'Mean weight change. 95% CI was not 0.4 to 2.6'],
    ['komma + not', 'Mean weight change. 95% CI, not 0.4 to 2.6'],
    ['except', 'Mean weight change. 95% CI except 0.4 to 2.6'],
    ['ikke', 'Vektendring. 95 % konfidensintervall ikke 0,4 til 2,6'],
  ])('bekrefter ikke et intervall en benektelse står foran (%s)', (_navn, kilde) => {
    const report = check({ extraction: { rawExtraction: { sitat: 'Mean weight change' } } }, kilde)

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  it.each([
    ['95% CI 0.4 to 2.6', 'Mean weight change was 1.5 kg (95% CI 0.4 to 2.6).'],
    // Den positive formen benektelsene over er en variant av. Uten denne ville
    // rettelsen kunne bestå ved å avvise alt.
    ['nøytralt «was» som lim', 'Mean weight change. 95% CI was 0.4 to 2.6'],
    ['CI etter nivået med kolon', 'Mean weight change was 1.5 kg (CI 95%: 0.4 to 2.6).'],
    ['nivået skrevet ut', 'Mean weight change was 1.5 kg, 95% confidence interval 0.4 to 2.6.'],
    ['grensene før ankeret', 'Mean weight change was 1.5 kg, 0.4 to 2.6 (95% CI).'],
    ['norsk kilde', 'Vektendringen var 1,5 kg (95 % konfidensintervall 0,4 til 2,6).'],
    // Den vanligste skrivemåten i MEDLINE-sammendrag. Utenfor et navngitt
    // intervall leses en bindestrek fortsatt ikke som intervallstrek.
    ['bindestrek som intervallstrek', 'Mean weight change was 1.5 kg (95% CI 0.4-2.6).'],
    ['nivået skrevet «percent»', 'Weight change 1.5 kg, 95 percent CI 0.4 to 2.6.'],
    [
      'ankeret i parentes mellom nivå og grenser',
      'Weight change, 95% confidence interval (CI) 0.4 to 2.6.',
    ],
    ['grensene før ankeret og nivået', 'Weight change 0.4 to 2.6 (CI 95%).'],
  ])('kjenner igjen intervallet skrevet som «%s»', (_navn, kilde) => {
    // Teksten er funnets eget utdrag: tallene kontrolleres mot den, ikke mot
    // resten av artikkelen.
    const report = check({ extraction: { rawExtraction: { sitat: kilde } } }, `Forord. ${kilde}`)

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
    expect(report.checkedFields).not.toContain('confidence_interval')
    expect(report.rationale).toContain('navngir ikke noe konfidensintervall')
    expect(report.findings).toContain('Kontrollen konkluderte ikke')
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

  // Samme lærdom som for konfidensintervallet, på skalarene: sifferrekken finnes,
  // men kilden oppgir aldri verdien for *dette* feltet.
  it('fører ikke utvalgsstørrelsen som kontrollert når 90 bare er en prosentandel', () => {
    const report = check(
      { extraction: { sampleSize: 90, rawExtraction: { sitat: 'Mean weight change' } } },
      'Mean weight change. In this trial 90% improved during follow-up.',
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('sample_size')
    expect(report.rationale).toContain('utvalgsstørrelse (90)')
  })

  it('fører ikke estimatet som kontrollert når tallet bare er en dose', () => {
    const report = check(
      {
        extraction: {
          estimate: '15',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
          rawExtraction: { sitat: 'Mean weight change' },
        },
      },
      'Mean weight change. Participants received 15 mg once daily.',
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.rationale).toContain('estimat (15)')
  })

  // Et verb sier hva som ble gjort, ikke hva som telles. «12» er her en
  // varighet, og kilden oppgir ingen utvalgsstørrelse i det hele tatt.
  it.each([
    ['completed 12 weeks', 'Vekt. Participants completed 12 weeks of treatment.'],
    ['included 12 weeks', 'Vekt. The study included 12 weeks of follow-up.'],
    ['enrolled over 12 months', 'Vekt. Patients were enrolled at 12 sites.'],
  ])('fører ikke utvalgsstørrelsen som kontrollert på «%s»', (_navn, kilde) => {
    const report = check(
      { extraction: { sampleSize: 12, rawExtraction: { sitat: 'Vekt' } } },
      kilde,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('sample_size')
    expect(report.rationale).toContain('utvalgsstørrelse (12)')
  })

  // Samme klasse på estimatet: «mean», «median» og «average» er statistikk over
  // hva som helst, ikke navnet på et effektmål.
  it.each([
    ['median var en varighet', 'Vekt. The median was 12 months.'],
    ['mean var en alder', 'Vekt. The mean was 12 years.'],
    ['average var en varighet', 'Vekt. An average of 12 weeks of treatment.'],
  ])('fører ikke estimatet som kontrollert på «%s»', (_navn, kilde) => {
    const report = check(
      {
        extraction: {
          estimate: '12',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
          rawExtraction: { sitat: 'Vekt' },
        },
      },
      kilde,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.rationale).toContain('estimat (12)')
  })

  it.each([
    ['N = 48', 'Patients (sertraline, N = 48) completed the trial.', 48],
    ['sample size was 48', 'The sample size was 48 in the sertraline arm.', 48],
    ['284 adults', 'A total of 284 adults were randomised.', 284],
    ['48 patients', 'We enrolled 48 patients at two sites.', 48],
    ['norsk form', 'Studien inkluderte 48 pasienter.', 48],
  ])('kjenner igjen utvalgsstørrelsen skrevet som «%s»', (_navn, kilde, størrelse) => {
    const report = check(
      { extraction: { sampleSize: størrelse, rawExtraction: { sitat: kilde } } },
      `Forord. ${kilde}`,
    )

    expect(report.checkedFields).toContain('sample_size')
  })

  it.each([
    ['mean weight gain of', 'Vekt. Patients had a mean weight gain of 0.8 kg.'],
    ['mean difference', 'Vekt. The mean difference was 0.8 kg.'],
    ['norsk form', 'Vekt. Gjennomsnittlig endring var 0,8 kg.'],
  ])('kjenner igjen estimatet skrevet som «%s»', (_navn, kilde) => {
    const report = check(
      { extraction: { estimate: '0.8', rawExtraction: { sitat: kilde } } },
      `Forord. ${kilde}`,
    )

    expect(report.checkedFields).toContain('estimate')
  })

  // En eksponent hører til tallet. «1.5e-3» er 0,0015, ikke 1,5.
  it.each(['p = 1.5e-3', 'x = 1.5E+3', 'y = 1.5e3'])(
    'leser ikke koeffisienten i «%s» som et selvstendig 1.5',
    (kilde) => {
      expect(numberOccursIn(searchProjections(kilde), '1.5')).toBe(false)
    },
  )

  it('bekrefter ikke en øvre konfidensgrense som står i eksponentnotasjon', () => {
    const report = check(
      { extraction: { rawExtraction: { sitat: 'Mean weight change' } } },
      'Mean weight change. Result (95% CI 0.4 to 2.6e-3).',
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
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
