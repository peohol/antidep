import { describe, expect, it } from 'vitest'

import {
  CHECKABLE_FIELDS,
  checkExtraction,
  numberOccursIn,
  searchProjections,
  sourceWideAbsenceSearch,
  trimNumericText,
} from './extraction-checks'
import {
  absenceReviewFixture,
  FIXTURE_SOURCE_TEXT,
  sourceVersionFixture,
  verificationItemFixture,
} from './test-support'
import type { AbsenceReviewOutcome } from './absence-review'
import type { VerificationExtraction } from './verification-input'

/**
 * Kontrollen av fiksturen, med den kildeomfattende gjennomlesningen på plass.
 *
 * Standardverdien er en gjennomlesning som konkluderte «absent» på hvert felt
 * raden fører som globalt fraværende. Uten den kan `source_wide_absence` aldri
 * dekkes, og enhver prøve om noe annet ville blitt uavklart av en grunn den
 * ikke prøver (`absence-review.ts`). Prøvene som handler om selve halvdelen,
 * oppgir den selv — også som `null`, som er «ingen gjennomlesning foreligger».
 */
function check(
  overrides: Parameters<typeof verificationItemFixture>[0] = {},
  sourceText: string = FIXTURE_SOURCE_TEXT,
  representationReproduced = true,
  absenceReview?: AbsenceReviewOutcome | null,
) {
  const item = verificationItemFixture(overrides)
  return checkExtraction({
    item,
    sourceText,
    representationReproduced,
    absenceReview: absenceReview === undefined ? absenceReviewFixture(item) : absenceReview,
  })
}

// Fiksturen oppgir en populasjon, og utdragene dens navngir den. En test som
// bytter ut utdraget, forteller en annen historie: da er populasjonen støy og
// slås av, slik at testen måler det den sier den måler.
//
// `not_applicable` og ikke `not_reported`: det siste er en påstand om at kilden
// ikke oppgir populasjonen, og den utløser et kildeomfattende krav ingen kan
// innfri for en etikett (migrasjon 005ae). Det ville gjort hver av disse
// prøvene uavklart av en grunn de ikke handler om. Fiksturen mener «ikke
// aktuelt her», og skal si det.
const UTEN_POPULASJON = { populationAvailability: 'not_applicable' } as const

// ----------------------------------------------------------------------------
// Kontrakten mot publiseringsgaten
//
// Denne kontrollen bedømmer en delmengde av feltene. Gaten (G5b, migrasjon
// 20260907093000) krever at kontrollene til sammen dekker det raden påstår noe
// om, og leser det fra `checked_fields`. Da må denne siden aldri føre opp et
// felt den ikke faktisk gikk gjennom.
// ----------------------------------------------------------------------------
describe('checkExtraction — fører aldri opp et felt den ikke kan bedømme', () => {
  const UTENFOR: readonly string[] = [
    'timepoint',
    'reported_direction',
    'effect_measure',
    'availability_semantics',
    'limitations',
  ]

  it.each([
    ['den lykkede stien', {}],
    ['et avvik', { extraction: { rawExtraction: { sitat: 'står ikke i kilden' } } }],
    ['en uavklart kontroll', { extraction: { estimate: '2.7' } }],
    [
      'et rapportert tidspunkt kilden motsier',
      { extraction: { timepointAvailability: 'reported_value' } },
    ],
    [
      'en utvalgsstørrelse uten verdi',
      { extraction: { sampleSize: null, sampleSizeAvailability: 'not_applicable' } },
    ],
    [
      'en utvalgsstørrelse ført som ikke rapportert i kilden',
      { extraction: { sampleSize: null, sampleSizeAvailability: 'not_reported' } },
    ],
  ] as const)('holder seg innenfor de kontrollerbare feltene (%s)', (_navn, overrides) => {
    const report = check(overrides)

    expect(report.checkedFields.filter((field) => UTENFOR.includes(field))).toEqual([])
    for (const field of report.checkedFields) {
      expect(CHECKABLE_FIELDS).toContain(field)
    }
  })

  // Det er nettopp derfor gaten ikke kan nøye seg med `outcome`: selv den
  // lykkede stien lar felter stå ukontrollert.
  it('lar felter stå ukontrollert også når utfallet er verified', () => {
    const report = check()

    expect(report.outcome).toBe('verified')
    expect(report.checkedFields).not.toContain('availability_semantics')
    expect(report.checkedFields).not.toContain('reported_direction')
  })
})

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

// ----------------------------------------------------------------------------
// Kildeforankringen
//
// Arbeidsdelingen mellom maskin og menneske: maskinen beviser at venstresiden —
// det ordrette utdraget kontrolløren får se — faktisk står i den
// kildeversjonen raden peker på. Mennesket vurderer om den strukturerte verdien
// følger av utdraget.
//
// Et utdrag som ikke står der, er et avvik. Et *manglende* utdrag er noe annet:
// da finnes det ingen venstreside, og raden kan ikke kontrolleres felt for felt
// av noen.
// ----------------------------------------------------------------------------
describe('checkExtraction — kildeforankringen', () => {
  it('kontrollerer hvert forankret utdrag ordrett mot kildeversjonen', () => {
    const report = check()
    expect(report.outcome).toBe('verified')
    expect(report.rationale).toContain('forankrede utdrag ble gjenfunnet ordrett')
  })

  it('avviser et forankret utdrag som ikke står i representasjonen', () => {
    const report = check({
      fieldGroundings: [
        {
          fieldGroundingId: '61000000-0000-4000-8000-000000000099',
          checkField: 'outcome',
          sourceExcerpt: 'Quality of life was the primary outcome.',
          sourceLocator: 'Metode, avsnitt 2',
          justification: 'Endepunktet står i metodeavsnittet.',
          createdAt: '2026-09-01T00:00:00+00:00',
          createdByActorId: '99999999-9999-4999-8999-999999999999',
        },
      ],
      groundedCheckFields: ['outcome'],
    })
    expect(report.outcome).toBe('needs_correction')
    expect(report.findings).toContain('Quality of life was the primary outcome.')
  })

  // Et felt hvis eget grunnlag er falsifisert, kan aldri stå som kontrollert:
  // det ville sagt at kontrolløren har sammenlignet verdien mot noe som finnes.
  it('fører ikke opp et felt hvis eget utdrag ikke ble gjenfunnet', () => {
    const report = check({
      fieldGroundings: [
        {
          fieldGroundingId: '61000000-0000-4000-8000-000000000098',
          checkField: 'intervention_arm',
          sourceExcerpt: 'Patients received paroxetine only.',
          sourceLocator: 'Metode, avsnitt 1',
          justification: 'Behandlingsarmen står i metodeavsnittet.',
          createdAt: '2026-09-01T00:00:00+00:00',
          createdByActorId: '99999999-9999-4999-8999-999999999999',
        },
      ],
      groundedCheckFields: ['intervention_arm'],
    })
    expect(report.checkedFields).not.toContain('intervention_arm')
  })

  // Gamle funn er i nøyaktig denne tilstanden, og de skal ikke kunne se
  // kontrollerbare ut (ANTIDEP_CONSTITUTION.md §6, §11).
  it('kan ikke bekrefte et funn med hull i forankringen', () => {
    const report = check({ fieldGroundings: [], groundedCheckFields: [] })
    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toContain('mangler kildeforankring')
    expect(report.findings).toContain('må ekstraheres på nytt')
  })

  it('sier hvilke felter som mangler forankring', () => {
    const report = check({
      groundedCheckFields: [
        'intervention_arm',
        'outcome',
        'reported_direction',
        'availability_semantics',
        'effect_measure',
        'population',
        'sample_size',
        'confidence_interval',
      ],
    })
    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toContain('estimate')
  })
})

describe('checkExtraction — feilsitering', () => {
  it('avviser et sitat som ikke står ordrett i kilden', () => {
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        rawExtraction: { sitat: 'Mean weight change was 4.9 kg' },
      },
    })
    expect(report.outcome).toBe('needs_correction')
    expect(report.findings).toContain('finnes ikke ordrett')
  })

  it('fører sitatfeltet opp som kontrollert også når kontrollen felte det', () => {
    // Et avvik er et resultat av en kontroll, ikke et fravær av en: uten dette
    // ville en avvist rad sett ut som om sitatet aldri var sett på.
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        rawExtraction: { sitat: 'noe som ikke står der, i det hele tatt' },
      },
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
        ...UTEN_POPULASJON,
        rawExtraction: { metode: 'Sertraline patients (N = 284) with major depressive' },
      },
    })
    expect(report.checkedFields).toContain('raw_extraction')
    expect(report.findings).not.toContain('finnes ikke ordrett')
  })

  it('finner et sitat med en avkodet entitet', () => {
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        rawExtraction: { sitat: '(95% CI 0.4 to 2.6) & the difference was significant' },
      },
    })
    expect(report.checkedFields).toContain('raw_extraction')
    expect(report.findings).not.toContain('finnes ikke ordrett')
  })

  it('finner et sitat med typografiske anførselstegn i den ene enden', () => {
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          rawExtraction: { sitat: '"Mean weight change over the trial"' },
        },
      },
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
    [
      'tall som ikke ble gjenfunnet',
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimate: '2.7',
        },
      },
    ],
    [
      'sitat som ikke står i kilden',
      {
        extraction: {
          ...UTEN_POPULASJON,
          rawExtraction: { sitat: 'står ikke der i det hele tatt' },
        },
      },
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

  // `raw_extraction` er jsonb uten størrelsesgrense, mens begge tekstfeltene er
  // begrenset til 4000 tegn i basen. Mange eller lange utdrag skal ikke kunne
  // felle registreringen av en kontroll som faktisk ble gjennomført.
  it.each([
    ['mange utdrag med lange nøkler', 30, 300],
    ['få utdrag, svært lange nøkler', 4, 3000],
  ])('holder findings og rationale innenfor 4000 tegn (%s)', (_navn, antall, nøkkellengde) => {
    const rawExtraction: Record<string, string> = {}
    for (let i = 0; i < antall; i += 1) {
      rawExtraction[`utdrag_${String(i)}_${'x'.repeat(nøkkellengde)}`] =
        'Sertraline-treated patients had a mean weight change of 1.5 kg (95% CI 0.4 to 2.6)'
    }
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        rawExtraction,
      },
    })

    expect(report.rationale.length).toBeLessThanOrEqual(4000)
    expect((report.findings ?? '').length).toBeLessThanOrEqual(4000)
    expect(report.rationale).toBe(report.rationale.trim())
    expect(report.findings ?? 'x').toBe((report.findings ?? 'x').trim())
  })

  it('holder også et avvik innenfor 4000 tegn', () => {
    const rawExtraction: Record<string, string> = {}
    for (let i = 0; i < 40; i += 1) {
      rawExtraction[`utdrag_${String(i)}_${'x'.repeat(300)}`] =
        `noe som ikke står i kilden ${String(i)}`
    }
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        rawExtraction,
      },
    })

    expect(report.outcome).toBe('needs_correction')
    expect((report.findings ?? '').length).toBeLessThanOrEqual(4000)
    expect(report.rationale.length).toBeLessThanOrEqual(4000)
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
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        estimate: '2.7',
      },
    })
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
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        estimate: '2.7',
      },
    })
    expect(report.rationale).toContain('skrevet med bokstaver')
  })

  it('behandler en konfidensgrense som ikke ble gjenfunnet på samme måte', () => {
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        ciUpper: '9.9',
      },
    })
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
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        ciLevelPercent: '90',
      },
    })

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
      'Sertraline patients had a mean weight change of 1.5 kg (95% CI 0.4 to 2.6) ' +
      'over the study period.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          ciLevelPercent: '90',
          rawExtraction: {
            sitat: 'Sertraline patients had a mean weight change of 1.5 kg (95% CI 0.4 to 2.6)',
          },
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
          ...UTEN_POPULASJON,
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
          ...UTEN_POPULASJON,
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
          ...UTEN_POPULASJON,
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
        extraction: {
          ...UTEN_POPULASJON,
          rawExtraction: { sitat: 'et sitat som ikke står i kilden i det hele tatt' },
        },
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
  // Setningsdelingen og nærheten til armen løser dette riktig: «sertraline,
  // N = 48» sier hva sertralinarmen var, og de to andre tallene står inntil
  // andre legemidler.
  const FLERARMS =
    'Patients (fluoxetine, N = 44; sertraline, N = 48; paroxetine, N = 47) who ' +
    'completed the trial were included in these analyses.'

  it.each([44, 47, 284])(
    'bekrefter ikke utvalgsstørrelse %s fra et flerarmsutdrag der tallet tilhører en annen arm',
    (størrelse) => {
      const report = check(
        {
          extraction: {
            ...UTEN_POPULASJON,
            sampleSize: størrelse,
            rawExtraction: { resultat: FLERARMS },
          },
        },
        `Forord. ${FLERARMS}`,
      )

      expect(report.outcome).not.toBe('verified')
      expect(report.checkedFields).not.toContain('sample_size')
    },
  )

  it('bekrefter utvalgsstørrelsen som står inntil radens egen arm', () => {
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          sampleSize: 48,
          rawExtraction: { resultat: FLERARMS },
        },
      },
      `Forord. ${FLERARMS}`,
    )

    expect(report.checkedFields).toContain('sample_size')
  })

  it('bekrefter ikke et estimat fra et utdrag som oppgir to armer i samme setning', () => {
    const utdrag =
      'The mean difference was 0.8 kg for sertraline and the mean difference was 0.4 kg ' +
      'for fluoxetine.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimate: '0.8',
          rawExtraction: { resultat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
  })

  it('bekrefter ikke et konfidensintervall fra et utdrag som oppgir to intervaller', () => {
    const utdrag =
      'Sertraline: weight change was 1.5 kg (95% CI 0.4 to 2.6) and quality of life ' +
      'improved (95% CI 1.1 to 3.2) over the study period.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          rawExtraction: { resultat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
    expect(report.rationale).toContain('flere verdier for de samme feltene')
  })

  // En samling verifiserte utdrag er ikke i seg selv en binding: her navngir
  // det ene utdraget armen, mens alle tallene står i det andre — og tilhører
  // paroksetin. Slått sammen så det ut som en bekreftet sertralinrad.
  it('bekrefter ikke tall som står i et utdrag om en annen arm enn radens', () => {
    const arm = 'Sertraline-treated patients were included in the trial.'
    const tall = 'Paroxetine patients (N = 48) had mean weight change 1.5 kg (95% CI 0.4 to 2.6).'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          sampleSize: 48,
          rawExtraction: { arm, resultat: tall },
        },
      },
      `Forord. ${arm} ${tall}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('sample_size')
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.checkedFields).not.toContain('confidence_interval')
    // Armutdraget er bundet, men har ingen tall; tallutdraget navngir en annen
    // arm og leses ikke. Begrunnelsen sier at tallene ikke ble gjenfunnet i
    // funnets egne utdrag.
    expect(report.rationale).toContain('funnets egne utdrag')
  })

  it('sier fra når ingen av utdragene navngir armen i det hele tatt', () => {
    const tall = 'Paroxetine patients (N = 48) had mean weight change 1.5 kg (95% CI 0.4 to 2.6).'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          sampleSize: 48,
          rawExtraction: { resultat: tall },
        },
      },
      `Forord. ${tall}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('sample_size')
    expect(report.rationale).toContain('navngir intervensjonen')
  })

  it('leser tallene fra det utdraget som navngir armen, når det finnes', () => {
    const arm = 'Sertraline-treated patients (N = 48) had a mean weight change of 1.5 kg.'
    const annen = 'Paroxetine patients had a mean weight change of 9.9 kg.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          sampleSize: 48,
          confidenceIntervalAvailability: 'not_applicable',
          ciLower: null,
          ciUpper: null,
          ciLevelPercent: null,
          rawExtraction: { arm, annen },
        },
      },
      `Forord. ${arm} ${annen}`,
    )

    expect(report.checkedFields).toContain('sample_size')
    expect(report.checkedFields).toContain('estimate')
  })

  // «citalopram» står inne i «escitalopram». En delstrengsjekk gjorde et utdrag
  // om det ene til et utdrag om det andre — i et antidepressivregister er det
  // en forveksling som ikke kan stå.
  it.each([
    ['citalopram', 'Escitalopram-treated patients (N = 48) had a weight change of 1.5 kg.'],
    ['venlafaxine', 'Desvenlafaxine-treated patients (N = 48) had a weight change of 1.5 kg.'],
    ['milnacipran', 'Levomilnacipran-treated patients (N = 48) had a weight change of 1.5 kg.'],
  ])('binder ikke en %s-rad til et utdrag om et annet virkestoff', (virkestoff, utdrag) => {
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          interventionDrugName: virkestoff,
          sampleSize: 48,
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('intervention_arm')
    expect(report.checkedFields).not.toContain('sample_size')
  })

  it('binder fortsatt en norsk legemiddeletikett til den engelske formen', () => {
    const utdrag = 'Sertraline-treated patients (N = 48) had a weight change of 1.5 kg.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          interventionDrugName: 'sertralin',
          sampleSize: 48,
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.checkedFields).toContain('intervention_arm')
    expect(report.checkedFields).toContain('sample_size')
  })

  // Begge utdragene er sanne, og begge står ordrett i kilden. Sammen «bekreftet»
  // de et estimat som tilhører et helt annet endepunkt.
  it('bekrefter ikke et estimat satt sammen av riktig arm og riktig endepunkt fra hvert sitt utdrag', () => {
    const a = 'Sertraline-treated patients had a mean change of 5.0 points on the HAM-D scale.'
    const b = 'Body weight change was the prespecified primary outcome.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimate: '5.0',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
          outcomeLabel: 'body weight change',
          sampleSizeAvailability: 'not_applicable',
          sampleSize: null,
          confidenceIntervalAvailability: 'not_applicable',
          ciLower: null,
          ciUpper: null,
          ciLevelPercent: null,
          rawExtraction: { arm: a, endepunkt: b },
        },
      },
      `Forord. ${a} ${b}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
  })

  it('bekrefter et estimat når ett og samme utdrag navngir både armen og endepunktet', () => {
    const utdrag =
      'Sertraline-treated patients had a mean body weight change of 5.0 kg over the trial.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimate: '5.0',
          outcomeLabel: 'body weight change',
          sampleSizeAvailability: 'not_applicable',
          sampleSize: null,
          confidenceIntervalAvailability: 'not_applicable',
          ciLower: null,
          ciUpper: null,
          ciLevelPercent: null,
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.checkedFields).toContain('estimate')
  })

  // Forvekslingen skjer *inne i* ett verifisert utdrag: utdraget navngir riktig
  // arm, men tallet står i en setning om en annen.
  it('bekrefter ikke en utvalgsstørrelse som står i en setning om en annen arm', () => {
    const utdrag =
      'Weight change was assessed. Sertraline and paroxetine were compared; ' +
      'paroxetine patients (N = 48) completed the trial.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          sampleSize: 48,
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('sample_size')
  })

  // Samme, for endepunktet: utdraget navngir både armen og målendepunktet, men
  // det eneste estimatet står i setningen om HAM-D.
  it('bekrefter ikke et estimat som står i en setning om et annet endepunkt', () => {
    const utdrag =
      'Sertraline-treated patients had a mean change of 5.0 points on HAM-D; ' +
      'body weight change was also recorded.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimate: '5.0',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          confidenceIntervalAvailability: 'not_applicable',
          ciLower: null,
          ciUpper: null,
          ciLevelPercent: null,
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
  })

  it('bekrefter ikke et konfidensintervall som står i setningen om et annet endepunkt', () => {
    const utdrag =
      'Sertraline-treated patients had a mean change of 5.0 points (95% CI 0.4 to 2.6) ' +
      'on HAM-D; body weight change was also recorded.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimateAvailability: 'not_applicable',
          estimate: null,
          estimateUnit: null,
          effectMeasure: null,
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  it('bekrefter når arm, endepunkt og verdi står i samme setning', () => {
    const utdrag =
      'Sertraline-treated patients had a mean body weight change of 5.0 kg; ' +
      'HAM-D was also recorded.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimate: '5.0',
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          confidenceIntervalAvailability: 'not_applicable',
          ciLower: null,
          ciUpper: null,
          ciLevelPercent: null,
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.checkedFields).toContain('estimate')
  })

  // To endepunkter i én grammatisk setning: utdraget navngir både armen og
  // radens endepunkt, mens estimatet og intervallet tilhører HAM-D.
  it('bekrefter ikke et estimat som tilhører et annet endepunkt i samme setning', () => {
    const utdrag =
      'Sertraline-treated patients had a mean HAM-D change of 5.0 points ' +
      '(95% CI 4.0 to 6.0), while body weight change was also recorded.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimate: '5.0',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          ciLower: '4.0',
          ciUpper: '6.0',
          ciLevelPercent: '95',
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  // Et punktum rett etter et tall avslutter også en setning. Uten det ble
  // paroksetinsetningen og sertralinsetningen ett fragment.
  it('bekrefter ikke en utvalgsstørrelse fra setningen foran, når den slutter på et tall', () => {
    const utdrag = 'Paroxetine patients had N = 48. Sertraline was also studied.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          sampleSize: 48,
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('sample_size')
  })

  // Etterfølgende nuller er samme tall. Uten den valgfrie halen i mønsteret
  // kunne et registrert «4,0» aldri gjenfinnes i en kilde som skriver «4.0».
  it.each([
    ['4.0', 'the sertraline weight change sample size was 4.0'],
    ['5.00', 'the sertraline weight change sample size was 5'],
  ])('gjenfinner det registrerte tallet %s uansett etterfølgende nuller', (verdi, kilde) => {
    expect(numberOccursIn(searchProjections(kilde), verdi)).toBe(true)
  })

  it('lar ikke den valgfrie nullhalen gjøre 4 til 4.5', () => {
    expect(numberOccursIn(searchProjections('the value was 4.5'), '4')).toBe(false)
  })

  // Intervallet må stå inntil endepunktet. Her tilhører det HAM-D, mens raden
  // gjelder vektendring — begge navngis i samme setning.
  it('bekrefter ikke et konfidensintervall som tilhører et annet endepunkt i samme setning', () => {
    const utdrag =
      'Sertraline-treated patients had a mean HAM-D change of 5.0 points ' +
      '(95% CI 4.0 to 6.0), while body weight change was also recorded.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimateAvailability: 'not_applicable',
          estimate: null,
          estimateUnit: null,
          effectMeasure: null,
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          ciLower: '4.0',
          ciUpper: '6.0',
          ciLevelPercent: '95',
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  // (a) Setningen navngir ekte «Citalopram», så den slipper gjennom det ytre
  // filteret — og nærhetsmønsteret må da ikke kunne bruke delstrengen inne i
  // «escitalopram».
  it('binder ikke et tall til delstrengen inne i et lengre virkestoffnavn', () => {
    const utdrag = 'Citalopram was compared with escitalopram-treated patients (N = 48).'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          interventionDrugName: 'citalopram',
          sampleSize: 48,
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('sample_size')
  })

  // (b) Samme tall i to roller, i hvert sitt utdrag. Et snitt av tallverdier
  // ville sagt «48 finnes begge steder»; ett sammenhengende treff sier det ikke.
  it('bekrefter ikke et tall satt sammen av en dose i ett utdrag og en annen arms N i et annet', () => {
    const dose = 'Sertraline 48 mg daily was used.'
    const annen = 'Sertraline was compared with paroxetine patients (N = 48).'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          sampleSize: 48,
          rawExtraction: { dose, annen },
        },
      },
      `Forord. ${dose} ${annen}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('sample_size')
  })

  // (c) Enheten bak tallet gir rollen: 5,0 uker er et tidspunkt, ikke en effekt.
  it('bekrefter ikke et estimat der tallet er et tidspunkt', () => {
    const utdrag = 'Sertraline-treated patients had body weight change at 5.0 weeks.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimate: '5.0',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          confidenceIntervalAvailability: 'not_applicable',
          ciLower: null,
          ciUpper: null,
          ciLevelPercent: null,
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
  })

  it('bekrefter ikke en utvalgsstørrelse der tallet er en dose', () => {
    const utdrag = 'Sertraline 48 mg daily was given to the group.'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          sampleSize: 48,
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('sample_size')
  })

  // Et nakent tall ved ankeret er ikke et nivå. Her er `90` en utvalgsstørrelse,
  // og kilden sier aldri prosent — den sier ikke hvilket nivå intervallet har.
  it('bekrefter ikke et nivå kilden aldri oppgir som prosent', () => {
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          ciLevelPercent: '90',
          rawExtraction: { sitat: 'Mean weight change' },
        },
      },
      'Mean weight change. n=90; CI 0.4 to 2.6',
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  // Kilden sier uttrykkelig at intervallet ikke er rapportert. Nivået står ved
  // ankeret og grenseparet finnes i teksten, men de er ikke det samme uttrykket.
  it('bekrefter ikke et intervall kilden sier den ikke har rapportert', () => {
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          rawExtraction: { sitat: 'Mean weight change' },
        },
      },
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
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          rawExtraction: { sitat: 'Mean weight change' },
        },
      },
      kilde,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  it.each([
    ['95% CI 0.4 to 2.6', 'mean weight change was 1.5 kg (95% CI 0.4 to 2.6)'],
    // Den positive formen benektelsene over er en variant av. Uten denne ville
    // rettelsen kunne bestå ved å avvise alt.
    ['nøytralt «was» som lim', 'mean weight change, 95% CI was 0.4 to 2.6'],
    ['CI etter nivået med kolon', 'mean weight change was 1.5 kg (CI 95%: 0.4 to 2.6)'],
    ['nivået skrevet ut', 'mean weight change was 1.5 kg, 95% confidence interval 0.4 to 2.6'],
    ['grensene før ankeret', 'mean weight change was 1.5 kg, 0.4 to 2.6 (95% CI)'],
    ['norsk kilde', 'weight change var 1,5 kg (95 % konfidensintervall 0,4 til 2,6)'],
    // Den vanligste skrivemåten i MEDLINE-sammendrag. Utenfor et navngitt
    // intervall leses en bindestrek fortsatt ikke som intervallstrek.
    ['bindestrek som intervallstrek', 'mean weight change was 1.5 kg (95% CI 0.4-2.6)'],
    ['nivået skrevet «percent»', 'weight change 1.5 kg, 95 percent CI 0.4 to 2.6'],
    [
      'ankeret i parentes mellom nivå og grenser',
      'Weight change, 95% confidence interval (CI) 0.4 to 2.6.',
    ],
    ['grensene før ankeret og nivået', 'weight change 0.4 to 2.6 (CI 95%)'],
  ])('kjenner igjen intervallet skrevet som «%s»', (_navn, kilde) => {
    // Teksten er funnets eget utdrag: tallene kontrolleres mot den, ikke mot
    // resten av artikkelen.
    // Utdraget må navngi både armen og endepunktet: et intervall hører til
    // ett endepunkt hos én arm.
    // Arm, endepunkt og verdi i samme setning: bindingen er på setningen.
    const utdrag = `Sertraline, ${kilde}`
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          rawExtraction: { sitat: utdrag },
        },
      },
      `Forord. ${utdrag}`,
    )

    expect(report.checkedFields).toContain('confidence_interval')
  })

  // Navngir ikke kilden intervallet, er utfallet uavklart og ikke et avvik:
  // grensene kan stå i en tabell som ikke er med i representasjonen.
  it('melder ikke avvik når kilden ikke navngir noe konfidensintervall', () => {
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          rawExtraction: { sitat: 'Mean weight change was 1.5 kg' },
        },
      },
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
    // Utdraget oppgir nøyaktig ett tall for feltet, så kontrollen kan svare på
    // det testen spør om: er den registrerte verdien den som står i kilden?
    const kilde = 'Sertraline weight change: the estimate was 9007199254740992'
    const report = check(
      {
        extraction: {
          estimate: '9007199254740993',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          ciLower: null,
          ciUpper: null,
          ciLevelPercent: null,
          confidenceIntervalAvailability: 'not_applicable',
          populationAvailability: 'not_applicable',
          rawExtraction: { sitat: kilde },
        },
      },
      `Forord. ${kilde}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.rationale).toContain('estimat (9007199254740993)')
  })

  // Samme lærdom som for konfidensintervallet, på skalarene: sifferrekken finnes,
  // men kilden oppgir aldri verdien for *dette* feltet.
  it('fører ikke utvalgsstørrelsen som kontrollert når 90 bare er en prosentandel', () => {
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          sampleSize: 90,
          rawExtraction: { sitat: 'Mean weight change' },
        },
      },
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
          ...UTEN_POPULASJON,
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
      {
        extraction: {
          ...UTEN_POPULASJON,
          sampleSize: 12,
          rawExtraction: { sitat: 'Vekt' },
        },
      },
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
          ...UTEN_POPULASJON,
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
    ['N = 48', 'Patients (sertraline, N = 48) completed the trial', 48],
    ['sample size was 48', 'the sertraline sample size was 48', 48],
    ['284 adults', 'sertraline: 284 adults were randomised', 284],
    ['48 patients', 'the sertraline arm had 48 patients', 48],
    ['norsk form', 'sertraline-gruppen: 48 pasienter', 48],
  ])('kjenner igjen utvalgsstørrelsen skrevet som «%s»', (_navn, kilde, størrelse) => {
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          sampleSize: størrelse,
          rawExtraction: { sitat: kilde },
        },
      },
      `Forord. ${kilde}`,
    )

    expect(report.checkedFields).toContain('sample_size')
  })

  it.each([
    ['mean weight gain of', 'sertraline patients had a weight change, a mean gain of 0.8 kg'],
    ['mean difference', 'for sertraline the weight change mean difference was 0.8 kg'],
    ['norsk form', 'sertraline weight change, gjennomsnittlig endring var 0,8 kg'],
  ])('kjenner igjen estimatet skrevet som «%s»', (_navn, kilde) => {
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimate: '0.8',
          rawExtraction: { sitat: `Sertraline, weight change. ${kilde}` },
        },
      },
      `Forord. Sertraline, weight change. ${kilde}`,
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
      {
        extraction: {
          ...UTEN_POPULASJON,
          rawExtraction: { sitat: 'Mean weight change' },
        },
      },
      'Mean weight change. Result (95% CI 0.4 to 2.6e-3).',
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  it('behandler en utvalgsstørrelse som ikke ble gjenfunnet på samme måte', () => {
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        sampleSize: 285,
      },
    })
    expect(report.outcome).toBe('uncertain')
    expect(report.checkedFields).not.toContain('sample_size')
    expect(report.rationale).toContain('utvalgsstørrelse (285)')
  })

  // Rekkefølgen mellom de to: et sitat som ikke finnes, er falsifiserbart og
  // veier tyngre enn en kontroll som ikke konkluderte.
  it('lar et manglende sitat veie tyngre enn et manglende talltreff', () => {
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        estimate: '2.7',
        rawExtraction: { sitat: 'står ikke i kilden i det hele tatt' },
      },
    })
    expect(report.outcome).toBe('needs_correction')
  })

  it('kontrollerer ikke et tall som ikke er oppgitt som rapportert', () => {
    // §19.1: en verdi finnes hvis og bare hvis statusen sier det. Et estimat
    // uten en rapportert verdi har ingenting å lete etter, og feltet skal da
    // ikke stå som kontrollert. Grunnen er `not_applicable` og ikke
    // `not_reported`, slik at prøven måler nettopp dette og ikke det
    // kildeomfattende kravet en påstand om kilden utløser (migrasjon 005ae).
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        estimate: null,
        estimateAvailability: 'not_applicable',
      },
    })
    expect(report.checkedFields).not.toContain('estimate')
    // Ikke et avvik. Intervallet står uavklart fordi radens eget estimat er
    // det som binder det til endepunktet, og her finnes det ikke.
    expect(report.outcome).not.toBe('needs_correction')
  })

  // Den klinisk viktigste av talltestene: et fortegn som er snudd, skal aldri
  // ende i `verified`.
  it('bekrefter ikke et estimat der fortegnet er snudd', () => {
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          estimate: '-1.5',
        },
      },
      'Mean weight change was 1.5 kg (95% CI 0.4 to 2.6)',
    )
    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.rationale).toContain('estimat (-1.5)')
  })
})

// ----------------------------------------------------------------------------
// Bindingen mellom et tall og den raden det er registrert på
//
// Tre veier til en falsk bekreftelse, alle av samme slag: tallet står i et
// utdrag som er ordrett riktig, men verdien tilhører noe annet enn raden.
// ----------------------------------------------------------------------------
describe('checkExtraction — tallet må tilhøre denne raden', () => {
  function withQuote(quote: string, extraction: Partial<VerificationExtraction>) {
    return check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          ...extraction,
          rawExtraction: { utdrag: quote },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${quote}</p>`,
    )
  }

  // Legemiddelnavnet navngir armen, ikke feltet. Uten et uttrykk som sier at
  // tallet er et antall personer, er «Sertraline: 48 …» ikke en
  // utvalgsstørrelse — uansett hvilken enhet som følger.
  it('bekrefter ikke en utvalgsstørrelse som bare står inntil legemiddelnavnet', () => {
    const report = withQuote(
      'Sertraline: 48 tablets were dispensed; body weight change was assessed',
      { sampleSize: 48, sampleSizeAvailability: 'reported_value' },
    )
    expect(report.checkedFields).not.toContain('sample_size')
    expect(report.outcome).not.toBe('verified')
  })

  it('bekrefter fortsatt en utvalgsstørrelse som er navngitt som et antall personer', () => {
    const report = withQuote('Sertraline patients (N = 48) were randomised', {
      sampleSize: 48,
      sampleSizeAvailability: 'reported_value',
    })
    expect(report.checkedFields).toContain('sample_size')
  })

  // Setningen navngir sertralin, men verdiene er uttrykkelig paroksetinets.
  it('bekrefter ikke et estimat som setningen tilskriver en annen arm', () => {
    const report = withQuote(
      'Sertraline and paroxetine were compared, and body weight change was 5.0 kg ' +
        '(95% CI 4.0 to 6.0) in paroxetine patients',
      {
        estimate: '5.0',
        estimateUnit: 'kg',
        ciLower: '4.0',
        ciUpper: '6.0',
        ciLevelPercent: '95',
      },
    )
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.outcome).not.toBe('verified')
  })

  it('bekrefter ikke et konfidensintervall som setningen tilskriver en annen arm', () => {
    const report = withQuote(
      'Sertraline and paroxetine were compared, and body weight change was 5.0 kg ' +
        '(95% CI 4.0 to 6.0) in paroxetine patients',
      {
        estimate: '5.0',
        estimateUnit: 'kg',
        ciLower: '4.0',
        ciUpper: '6.0',
        ciLevelPercent: '95',
      },
    )
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  // Den skarpe formen av den forrige: her er radens **eget estimat bekreftet**,
  // og det er nettopp estimatet som ellers limer intervallet til endepunktet.
  // Uten armen i samme treff ble et intervall som uttrykkelig tilhører den
  // andre armen, ført opp som kontrollert.
  it('bekrefter ikke et annet arms intervall selv når radens eget estimat er bekreftet', () => {
    const report = withQuote(
      'Sertraline-treated patients had a mean weight change of 1.5 kg, and paroxetine ' +
        'patients had a weight change of 1.5 kg (95% CI 4.0 to 6.0)',
      {
        estimate: '1.5',
        estimateUnit: 'kg',
        ciLower: '4.0',
        ciUpper: '6.0',
        ciLevelPercent: '95',
      },
    )
    expect(report.checkedFields).toContain('estimate')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  // Samme tall i kilogram og i prosent er to forskjellige kliniske påstander.
  it('bekrefter ikke et estimat i kg mot en prosentverdi i kilden', () => {
    const report = withQuote(
      'Sertraline-treated patients had a mean weight change of 1.5% over the trial',
      {
        estimate: '1.5',
        estimateUnit: 'kg',
        confidenceIntervalAvailability: 'not_applicable',
        ciLower: null,
        ciUpper: null,
        ciLevelPercent: null,
      },
    )
    expect(report.checkedFields).not.toContain('estimate')
    expect(report.outcome).not.toBe('verified')
  })

  // Det er tillatelseslisten som stopper en gal binding, ikke avstanden: et
  // annet legemiddelnavn er alltid et ord limet ikke kjenner, og bryter kjeden.
  it.each([
    [
      'en annen arm mellom armen og verdien',
      'Sertraline patients, paroxetine patients had a mean weight change of 1.5 kg',
    ],
    [
      'en annen arm bak verdien',
      'Sertraline was studied, a mean weight change of 1.5 kg in paroxetine patients',
    ],
    [
      'en limkjede som er lengre enn bindingen rekker',
      'Sertraline patients patients patients patients patients patients patients ' +
        'patients patients patients patients patients patients had a mean weight ' +
        'change of 1.5 kg',
    ],
  ])('bekrefter ikke et estimat når bindingen til armen er brutt (%s)', (_navn, quote) => {
    const report = withQuote(quote, {
      sampleSizeAvailability: 'not_applicable',
      sampleSize: null,
      estimate: '1.5',
      estimateUnit: 'kg',
      confidenceIntervalAvailability: 'not_applicable',
      ciLower: null,
      ciUpper: null,
      ciLevelPercent: null,
    })
    expect(report.checkedFields).not.toContain('estimate')
  })

  // Radens eget estimat er limet som binder intervallet til endepunktet. Uten
  // enheten kunne en *annen* forekomst av samme sifferrekke gjøre den jobben —
  // og da er det ikke lenger radens egen påstand som limer.
  it('limer ikke et intervall med en enhetsløs forekomst av estimatets tall', () => {
    const report = withQuote(
      'Sertraline patients had a mean weight change of 1.5 kg, the change of 1.5 ' +
        '(95% CI 4.0 to 6.0)',
      {
        sampleSizeAvailability: 'not_applicable',
        sampleSize: null,
        estimate: '1.5',
        estimateUnit: 'kg',
        ciLower: '4.0',
        ciUpper: '6.0',
        ciLevelPercent: '95',
      },
    )
    expect(report.checkedFields).toContain('estimate')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  it('bekrefter et estimat i prosent når kilden oppgir prosent', () => {
    const report = withQuote(
      'Sertraline-treated patients had a mean weight change of 1.5% over the trial',
      {
        estimate: '1.5',
        estimateUnit: '%',
        confidenceIntervalAvailability: 'not_applicable',
        ciLower: null,
        ciUpper: null,
        ciLevelPercent: null,
      },
    )
    expect(report.checkedFields).toContain('estimate')
  })
})

describe('checkExtraction — begreper som ikke lar seg kontrollere', () => {
  it('fører ikke opp et begrep som ikke ble gjenfunnet', () => {
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        outcomeLabel: 'vektendring',
      },
    })
    expect(report.checkedFields).not.toContain('outcome')
  })

  it('behandler et manglende begrepstreff som en merknad, ikke som et avvik', () => {
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        outcomeLabel: 'vektendring',
      },
    })
    // Ikke et avvik: utfallet er uavklart, ikke `needs_correction`, og
    // begrunnelsen sier at feltet ikke ble kontrollert. Et endepunkt på norsk
    // som ikke står i en engelsk kilde, binder heller ikke effektmålene — se
    // hodekommentaren om arm og endepunkt.
    expect(report.outcome).toBe('uncertain')
    expect(report.findings).not.toContain('finnes ikke ordrett')
    expect(report.rationale).toContain('ikke ført opp som kontrollert')
  })

  it('fører opp komparatoren når den er et virkestoff som finnes i kilden', () => {
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        comparatorKind: 'drug',
        comparatorDrugName: 'fluoxetine',
      },
    })
    expect(report.checkedFields).toContain('comparator_arm')
  })
})

// ----------------------------------------------------------------------------
// Et begrep som ikke ble gjenfunnet, er en kontroll som ikke konkluderte
//
// Uten dette kunne et ordrett, men irrelevant utdrag bære hele raden: sitatet
// finnes i riktig kildeversjon, ingen tallfelt er oppgitt, og verken
// legemiddelet eller endepunktet står i utdraget — men utfallet ble `verified`.
// ----------------------------------------------------------------------------
describe('checkExtraction — begrepene må være gjenfunnet for at raden er bekreftet', () => {
  // Ingen tallfelt oppgitt: da er begrepene det eneste som kan gjøre raden til
  // noe annet enn bekreftet, og testene måler nettopp det de sier.
  const utenTall = {
    sampleSize: null,
    sampleSizeAvailability: 'not_applicable',
    estimate: null,
    estimateUnit: null,
    estimateAvailability: 'not_applicable',
    ciLower: null,
    ciUpper: null,
    ciLevelPercent: null,
    confidenceIntervalAvailability: 'not_applicable',
  } as const satisfies Partial<VerificationExtraction>

  function utenTallMedUtdrag(quote: string, extraction: Partial<VerificationExtraction> = {}) {
    return check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          ...utenTall,
          ...extraction,
          rawExtraction: { utdrag: quote },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${quote}</p>`,
    )
  }

  const BEGGE = 'Sertraline-treated patients had a mean weight change over the trial'

  // Ett begrep om gangen: utdraget navngir alt raden trenger *unntatt* det ene
  // testen handler om.
  it.each([
    [
      'intervensjonen',
      'Patients had a mean weight change over the trial',
      { populationAvailability: 'not_applicable' },
      'intervention_arm',
    ],
    [
      'endepunktet',
      'Sertraline-treated patients were followed over the trial',
      { populationAvailability: 'not_applicable' },
      'outcome',
    ],
    [
      'komparatoren',
      BEGGE,
      {
        comparatorKind: 'drug',
        comparatorDrugName: 'fluoxetine',
        populationAvailability: 'not_applicable',
      },
      'comparator_arm',
    ],
    [
      'populasjonen',
      BEGGE,
      { populationLabel: 'voksne med depressiv lidelse', populationAvailability: 'reported_value' },
      'population',
    ],
  ] as const)(
    'bekrefter ikke en rad der %s ikke ble gjenfunnet i funnets utdrag',
    (_navn, quote, extraction, felt) => {
      const report = utenTallMedUtdrag(quote, extraction)

      expect(report.outcome).toBe('uncertain')
      expect(report.checkedFields).not.toContain(felt)
      // Fortsatt ikke et avvik: en norsk etikett mot en engelsk kilde er den
      // vanligste grunnen, og den er ikke en feilekstraksjon.
      expect(report.findings).toContain('Kontrollen konkluderte ikke')
    },
  )

  // Reviewerens egen sak, i sin helhet: et ordrett og korrekt utdrag som ikke
  // handler om raden i det hele tatt.
  it('bekrefter ikke en rad der et ordrett, men irrelevant utdrag er alt som finnes', () => {
    const report = utenTallMedUtdrag('The trial was randomized and double blind', {
      populationAvailability: 'not_applicable',
    })

    expect(report.outcome).toBe('uncertain')
    expect(report.checkedFields).toEqual(
      expect.arrayContaining(['raw_extraction', 'source_locator']),
    )
    expect(report.checkedFields).not.toContain('intervention_arm')
    expect(report.checkedFields).not.toContain('outcome')
  })

  // ..og begrepene må være bundet til hverandre, ikke bare finnes hver for seg.
  // Ellers kan to sanne utdrag om hver sin arm sys sammen til én gal rad.
  it.each([
    [
      'to utdrag som hver for seg navngir sitt begrep',
      {
        a: 'Sertraline-treated patients discontinued treatment because of nausea',
        b: 'Paroxetine-treated patients had a mean body weight change over the trial',
      },
    ],
    [
      'ett utdrag der endepunktet uttrykkelig gjelder en annen arm',
      {
        a:
          'No participants received sertraline; paroxetine-treated patients had a mean ' +
          'body weight change over the trial',
      },
    ],
    [
      'ett utdrag der bindingen er benektet',
      { a: 'Sertraline was not associated with a mean weight change over the trial' },
    ],
    // Semikolonet er lim inne i et uttrykk («CI 95%: 0,4 til 2,6»), men det
    // skiller to påstander. Uten setningsdelingen bandt det disse to.
    [
      'ett utdrag der de to står i hver sin semikolonskilte påstand',
      { a: 'Sertraline patients; a mean weight change was the primary endpoint' },
    ],
  ])('bekrefter ikke en rad der %s', (_navn, rawExtraction) => {
    const quotes = Object.values(rawExtraction)
    const report = check(
      {
        extraction: { ...utenTall, populationAvailability: 'not_applicable', rawExtraction },
      },
      `${FIXTURE_SOURCE_TEXT}\n${quotes.map((quote) => `<p>${quote}</p>`).join('\n')}`,
    )

    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toContain('Kontrollen konkluderte ikke')
  })

  // Komparator og populasjon er del av den samme kliniske raden, og har samme
  // krav: et ordtreff i en benektelse eller i en helt annen påstand er ikke
  // støtte for at *denne* raden stemmer.
  it.each([
    [
      'komparatoren bare forekommer i en benektelse',
      'Paroxetine was not used as a comparator in this analysis',
      { comparatorKind: 'drug', comparatorDrugName: 'paroxetine' },
    ],
    [
      'komparatoren bare forekommer i en annen påstand',
      'Paroxetine-treated patients discontinued treatment because of nausea',
      { comparatorKind: 'drug', comparatorDrugName: 'paroxetine' },
    ],
    [
      'placebo ikke er navngitt som komparator',
      'Placebo tablets were prepared by the hospital pharmacy',
      { comparatorKind: 'placebo', comparatorDrugName: null },
    ],
  ] as const)('bekrefter ikke en rad der %s', (_navn, komparatorutdrag, extraction) => {
    const report = check(
      {
        extraction: {
          ...utenTall,
          ...extraction,
          populationAvailability: 'not_applicable',
          rawExtraction: { arm: BEGGE, komparator: komparatorutdrag },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${BEGGE}</p>\n<p>${komparatorutdrag}</p>`,
    )

    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toContain('Kontrollen konkluderte ikke')
  })

  it('bekrefter ikke en rad der populasjonen bare forekommer i en eksklusjonspåstand', () => {
    const eksklusjon = 'Patients with major depressive disorder were excluded from this analysis'
    const report = check(
      {
        extraction: {
          ...utenTall,
          populationLabel: 'major depressive disorder',
          populationAvailability: 'reported_value',
          rawExtraction: { arm: BEGGE, populasjon: eksklusjon },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${BEGGE}</p>\n<p>${eksklusjon}</p>`,
    )

    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toContain('Kontrollen konkluderte ikke')
  })

  // Positive kontroller for de samme to: står støtten i den *samme* påstanden
  // som armen og endepunktet, er raden bekreftet. Et eget «Fluoxetine was the
  // comparator»-utdrag ved siden av holder ikke — det er nettopp åpningen.
  it.each([
    [
      'komparatoren er navngitt som komparator i samme påstand',
      { comparatorKind: 'drug', comparatorDrugName: 'fluoxetine' },
      'Sertraline-treated patients had a mean weight change compared with fluoxetine',
    ],
    [
      'placebo er navngitt som komparator i samme påstand',
      { comparatorKind: 'placebo', comparatorDrugName: null },
      'Sertraline-treated patients had a mean weight change compared with placebo',
    ],
  ] as const)('bekrefter en rad der %s', (_navn, extraction, støtte) => {
    const report = check(
      {
        extraction: {
          ...utenTall,
          ...extraction,
          populationAvailability: 'not_applicable',
          rawExtraction: { støtte },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${støtte}</p>`,
    )

    expect(report.outcome).toBe('verified')
    expect(report.checkedFields).toContain('comparator_arm')
  })

  // Forskjellen på en presisering og en kontrast: populasjonsetiketten er lim
  // mellom armen og verdien, komparatornavnet er det ikke. Et kontrastord der
  // er nettopp signalet om at verdien kan tilhøre den andre armen.
  it('bekrefter ikke en rad der komparatornavnet står mellom armen og endepunktet', () => {
    const arm = 'Sertraline patients, paroxetine patients had a mean weight change over the trial'
    const komparator = 'Paroxetine was the comparator'
    const report = check(
      {
        extraction: {
          ...utenTall,
          populationAvailability: 'not_applicable',
          comparatorKind: 'drug',
          comparatorDrugName: 'paroxetine',
          rawExtraction: { arm, komparator },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${arm}</p>\n<p>${komparator}</p>`,
    )

    // Komparatorbindingen holder — det er arm-til-endepunkt som ikke gjør det.
    expect(report.checkedFields).toContain('comparator_arm')
    expect(report.outcome).toBe('uncertain')
  })

  it('bekrefter en rad der populasjonen står i samme påstand som armen', () => {
    const støtte =
      'Sertraline-treated patients with major depressive disorder had a mean weight change'
    const report = check(
      {
        extraction: {
          ...utenTall,
          populationLabel: 'major depressive disorder',
          populationAvailability: 'reported_value',
          rawExtraction: { arm: støtte },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${støtte}</p>`,
    )

    expect(report.outcome).toBe('verified')
    expect(report.checkedFields).toContain('population')
  })

  // ..og bindingene er én binding, ikke flere som holder hver for seg. Ellers
  // kan én rad sys sammen av påstander om forskjellige funn.
  it('bekrefter ikke en rad der komparatoren hører til et annet utfall', () => {
    const annet = 'Fluoxetine was compared with paroxetine for remission'
    const report = check(
      {
        extraction: {
          ...utenTall,
          populationAvailability: 'not_applicable',
          comparatorKind: 'drug',
          comparatorDrugName: 'paroxetine',
          rawExtraction: { arm: BEGGE, annet },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${BEGGE}</p>\n<p>${annet}</p>`,
    )

    expect(report.outcome).toBe('uncertain')
  })

  it('bekrefter ikke en rad der populasjonen hører til et annet utfall', () => {
    const populasjon =
      'Sertraline-treated adults with major depressive disorder discontinued treatment ' +
      'because of nausea'
    const utfall = 'Sertraline-treated patients had a mean weight change over the trial'
    const report = check(
      {
        extraction: {
          ...utenTall,
          populationLabel: 'major depressive disorder',
          populationAvailability: 'reported_value',
          rawExtraction: { populasjon, utfall },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${populasjon}</p>\n<p>${utfall}</p>`,
    )

    expect(report.outcome).toBe('uncertain')
  })

  it('bekrefter ikke tall som hører til en annen kontrast enn radens komparator', () => {
    const tall =
      'For sertraline, the mean difference in weight change was 1.5 kg ' +
      '(95% CI 0.4 to 2.6), with placebo as comparator'
    const komparator = 'Sertraline was compared with paroxetine for remission'
    const report = check(
      {
        extraction: {
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          populationAvailability: 'not_applicable',
          comparatorKind: 'drug',
          comparatorDrugName: 'paroxetine',
          effectMeasure: 'mean_difference',
          rawExtraction: { tall, komparator },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${tall}</p>\n<p>${komparator}</p>`,
    )

    expect(report.checkedFields).not.toContain('estimate')
    expect(report.checkedFields).not.toContain('confidence_interval')
    expect(report.outcome).toBe('uncertain')
  })

  // Intervallet hører til samme kontrast som estimatet. Her er estimatet
  // bekreftet mot riktig kontrast, mens intervallet står i en påstand som ikke
  // sier hvilken kontrast det gjelder.
  it('bekrefter ikke et intervall som ikke sier hvilken kontrast det gjelder', () => {
    const medKomparator =
      'Sertraline-treated patients had a mean weight change of 1.5 kg compared with paroxetine'
    const utenKomparator =
      'Sertraline-treated patients had a mean weight change of 1.5 kg (95% CI 0.4 to 2.6)'
    const report = check(
      {
        extraction: {
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          populationAvailability: 'not_applicable',
          comparatorKind: 'drug',
          comparatorDrugName: 'paroxetine',
          effectMeasure: 'mean_difference',
          rawExtraction: { medKomparator, utenKomparator },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${medKomparator}</p>\n<p>${utenKomparator}</p>`,
    )

    expect(report.checkedFields).toContain('estimate')
    expect(report.checkedFields).not.toContain('confidence_interval')
  })

  // Populasjonen er en del av tallets påstand, ikke bare av radens. Ellers kan
  // radbindingen og tallbindingen komme fra hver sin populasjon.
  const MED_POPULASJON =
    'Sertraline-treated patients with major depressive disorder had weight change ' +
    'compared with paroxetine'

  const medPopulasjon = {
    populationLabel: 'major depressive disorder',
    populationAvailability: 'reported_value',
    comparatorKind: 'drug',
    comparatorDrugName: 'paroxetine',
    effectMeasure: 'mean_difference',
  } as const satisfies Partial<VerificationExtraction>

  it('bekrefter ikke et estimat som gjelder en annen populasjon', () => {
    const annenPopulasjon =
      'Sertraline-treated patients had weight change of 5.0 kg compared with paroxetine ' +
      'in adolescents'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          ...medPopulasjon,
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          estimate: '5.0',
          estimateUnit: 'kg',
          confidenceIntervalAvailability: 'not_applicable',
          ciLower: null,
          ciUpper: null,
          ciLevelPercent: null,
          rawExtraction: { rad: MED_POPULASJON, tall: annenPopulasjon },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${MED_POPULASJON}</p>\n<p>${annenPopulasjon}</p>`,
    )

    expect(report.checkedFields).not.toContain('estimate')
    expect(report.outcome).toBe('uncertain')
  })

  // Intervallet for seg: her er komparatoren `none`, så populasjonen er det
  // eneste som skiller radens påstand fra tallets.
  it('bekrefter ikke et intervall som gjelder en annen populasjon', () => {
    const rad = 'Sertraline-treated patients with major depressive disorder had weight change'
    const annenPopulasjon =
      'Sertraline-treated patients had weight change of 5.0 kg (95% CI 4.0 to 6.0) in adolescents'
    const report = check(
      {
        extraction: {
          populationLabel: 'major depressive disorder',
          populationAvailability: 'reported_value',
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          estimate: '5.0',
          estimateUnit: 'kg',
          ciLower: '4.0',
          ciUpper: '6.0',
          ciLevelPercent: '95',
          rawExtraction: { rad, tall: annenPopulasjon },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${rad}</p>\n<p>${annenPopulasjon}</p>`,
    )

    expect(report.checkedFields).not.toContain('estimate')
    expect(report.checkedFields).not.toContain('confidence_interval')
    expect(report.outcome).toBe('uncertain')
  })

  it('bekrefter ikke en utvalgsstørrelse som gjelder en annen populasjon', () => {
    const annenPopulasjon = 'Sertraline patients (N = 48) in the adolescent subgroup'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          ...medPopulasjon,
          ...utenTall,
          sampleSize: 48,
          sampleSizeAvailability: 'reported_value',
          rawExtraction: { rad: MED_POPULASJON, tall: annenPopulasjon },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${MED_POPULASJON}</p>\n<p>${annenPopulasjon}</p>`,
    )

    expect(report.checkedFields).not.toContain('sample_size')
    expect(report.outcome).toBe('uncertain')
  })

  it('bekrefter et tall som står i samme påstand som riktig populasjon', () => {
    const støtte =
      'Sertraline-treated patients with major depressive disorder (N = 48) had weight ' +
      'change compared with paroxetine'
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          ...medPopulasjon,
          ...utenTall,
          sampleSize: 48,
          sampleSizeAvailability: 'reported_value',
          rawExtraction: { støtte },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${støtte}</p>`,
    )

    expect(report.checkedFields).toContain('sample_size')
    expect(report.outcome).toBe('verified')
  })

  // Positive kontroller: alt raden oppgir står i samme påstand.
  it('bekrefter en rad der arm, endepunkt og komparator står i samme påstand', () => {
    const støtte = 'Sertraline-treated patients had a mean weight change compared with paroxetine'
    const report = check(
      {
        extraction: {
          ...utenTall,
          populationAvailability: 'not_applicable',
          comparatorKind: 'drug',
          comparatorDrugName: 'paroxetine',
          rawExtraction: { støtte },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${støtte}</p>`,
    )

    expect(report.outcome).toBe('verified')
    expect(report.checkedFields).toContain('comparator_arm')
  })

  it('bekrefter et tall som står i samme påstand som arm, endepunkt og komparator', () => {
    const støtte =
      'Sertraline-treated patients had a mean weight change of 1.5 kg compared with paroxetine'
    const report = check(
      {
        extraction: {
          sampleSize: null,
          sampleSizeAvailability: 'not_applicable',
          confidenceIntervalAvailability: 'not_applicable',
          ciLower: null,
          ciUpper: null,
          ciLevelPercent: null,
          populationAvailability: 'not_applicable',
          comparatorKind: 'drug',
          comparatorDrugName: 'paroxetine',
          effectMeasure: 'mean_difference',
          rawExtraction: { støtte },
        },
      },
      `${FIXTURE_SOURCE_TEXT}\n<p>${støtte}</p>`,
    )

    expect(report.checkedFields).toContain('estimate')
    expect(report.outcome).toBe('verified')
  })

  // Den positive kontrollen: står begrepene faktisk i utdraget, er raden
  // bekreftet som før. Uten denne kunne rettelsen over gjort alt uavklart.
  it('bekrefter en rad uten tallfelt når begrepene faktisk står i utdraget', () => {
    const report = utenTallMedUtdrag(BEGGE, { populationAvailability: 'not_applicable' })

    expect(report.outcome).toBe('verified')
    expect(report.checkedFields).toEqual(
      expect.arrayContaining(['raw_extraction', 'source_locator', 'intervention_arm', 'outcome']),
    )
  })
})

describe('checkExtraction — når kontrollen ikke kan konkludere', () => {
  it('gir uncertain når funnet ikke har noe sitat å kontrollere', () => {
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        rawExtraction: null,
      },
    })
    expect(report.outcome).toBe('uncertain')
  })

  it('fører ikke kildepekeren opp som kontrollert uten et sitat', () => {
    // evidence_verifications_locator_checked_check gjør da `verified` umulig i
    // basen også. De to reglene peker samme vei uten å stole på hverandre.
    const report = check({
      extraction: {
        ...UTEN_POPULASJON,
        rawExtraction: null,
      },
    })
    expect(report.checkedFields).not.toContain('source_locator')
  })

  it('gir uncertain når representasjonen ikke lot seg reprodusere', () => {
    const report = check({}, FIXTURE_SOURCE_TEXT, false)
    expect(report.outcome).toBe('uncertain')
    expect(report.rationale).toContain('ikke samme fingeravtrykk')
  })

  it('lar et avvik veie tyngre enn en manglende reproduksjon', () => {
    const report = check(
      {
        extraction: {
          ...UTEN_POPULASJON,
          rawExtraction: { sitat: 'står ikke her, og har aldri gjort det' },
        },
      },
      FIXTURE_SOURCE_TEXT,
      false,
    )
    expect(report.outcome).toBe('needs_correction')
  })
})

// ----------------------------------------------------------------------------
// Den kildeomfattende fraværskontrollen
//
// `not_reported` og `not_measured` er påstander om kilden SOM HELHET, og de har
// to ledd: et deterministisk søk som kan FALSIFISERE, og en uavhengig
// gjennomlesning av hele representasjonen som kan KONKLUDERE (issue #74,
// migrasjon 005ae, `absence-review.ts`).
//
// Prøvene under holder fem ting fast:
//
//   1. Et negativt søkeresultat dekker ALDRI feltet alene. Det er funnet fra
//      teknisk review av denne leveransen, og det viktigste her.
//   2. Et treff — fra søket eller fra gjennomlesningen — stopper dekningen uten
//      å bli et avvik.
//   3. Begge leddene må gjelde den reproduserte representasjonen.
//   4. Alle feltene raden fører som globalt fraværende må være avklart.
//   5. Teksten påstår aldri mer enn den dekker, og navngir både
//      representasjonen og hvem som leste den.
// ----------------------------------------------------------------------------
describe('checkExtraction — den kildeomfattende fraværskontrollen', () => {
  // En tekst som ikke oppgir noe konfidensintervall noe sted.
  const UTEN_INTERVALL = [
    '<PubmedArticle>',
    '  <AbstractText Label="RESULTS">Sertraline-treated patients with major depressive',
    '  disorder had a mean weight change of 1.5 kg and the difference was significant.',
    '  </AbstractText>',
    '</PubmedArticle>',
  ].join('\n')

  const UTEN_KI = {
    ciLower: null,
    ciUpper: null,
    ciLevelPercent: null,
    confidenceIntervalAvailability: 'not_reported',
    rawExtraction: {
      resultat:
        'Sertraline-treated patients with major depressive disorder had a mean weight ' +
        'change of 1.5 kg',
    },
  } as const

  /** Fiksturens gjennomlesning for en rad, med et valgfritt svar per felt. */
  const lest = (
    overrides: Parameters<typeof verificationItemFixture>[0],
    verdicts: Record<string, 'absent' | 'present' | 'uncertain'> = {},
  ) => absenceReviewFixture(verificationItemFixture(overrides), verdicts)

  // ------------------------------------------------------------------------
  // Funnet fra teknisk review: søket alene dekker ingenting
  //
  // Den første utgaven førte feltet opp så snart mønsterlisten ikke fant noe.
  // Mønstrene kjente `CI`, `C.I.` og `confidence interval(s)`, men ikke `CIs`
  // og ikke `confidence limits`, og et fravær kan ikke bevises av et søk.
  // ------------------------------------------------------------------------

  it('dekker aldri feltet på et negativt søk alene', () => {
    const report = check({ extraction: UTEN_KI }, UTEN_INTERVALL, true, null)
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toMatch(/ingen gjennomlesning av hele representasjonen/)
    expect(report.findings).toMatch(/ikke at ingen form gjør det/)
  })

  // Den konkrete falske negativen review konstruerte. Teksten oppgir et
  // intervall i en form den første mønsterlisten ikke kjente. Prøven holder to
  // ting fast på én gang: at en gyldig, ukjent formulering aldri blir til
  // `checked` av seg selv, og at listen nå kjenner nettopp denne.
  const MED_CIs = [
    '<PubmedArticle>',
    '  <AbstractText Label="RESULTS">Sertraline-treated patients with major depressive',
    '  disorder had a mean weight change of 1.5 kg. The 95% CIs were 0.4 to 2.6.',
    '  </AbstractText>',
    '</PubmedArticle>',
  ].join('\n')

  const MED_CONFIDENCE_LIMITS = [
    '<PubmedArticle>',
    '  <AbstractText Label="RESULTS">Sertraline-treated patients with major depressive',
    '  disorder had a mean weight change of 1.5 kg (confidence limits 0.4 and 2.6).',
    '  </AbstractText>',
    '</PubmedArticle>',
  ].join('\n')

  it.each([
    ['CIs', MED_CIs],
    ['confidence limits', MED_CONFIDENCE_LIMITS],
  ])('dekker ikke et intervall skrevet som «%s», uansett hvem som leser', (_form, tekst) => {
    // Uten gjennomlesning: ingen dekning, fordi søket aldri dekker alene.
    expect(check({ extraction: UTEN_KI }, tekst, true, null).checkedFields).not.toContain(
      'source_wide_absence',
    )
    // Med en gjennomlesning som ser intervallet: fortsatt ingen dekning.
    expect(
      check(
        { extraction: UTEN_KI },
        tekst,
        true,
        lest(
          { extraction: UTEN_KI },
          {
            confidence_interval: 'present',
          },
        ),
      ).checkedFields,
    ).not.toContain('source_wide_absence')
    // Og søket selv skal nå kjenne formen, slik at det falsifiserer den uten
    // hjelp. Det gjør ikke listen uttømmende — det er derfor ledd to finnes.
    const bareSøket = check({ extraction: UTEN_KI }, tekst, true, lest({ extraction: UTEN_KI }))
    expect(bareSøket.checkedFields).not.toContain('source_wide_absence')
    expect(bareSøket.findings).toMatch(/Søket gjennom hele representasjonen fant noe som ligner/)
  })

  // Et søketreff kan ikke overstyres av en gjennomlesning som mener noe annet:
  // to ledd som er uenige om hvorvidt verdien står der, er ikke et grunnlag for
  // å påstå at den ikke gjør det.
  it('lar et søketreff veie tyngre enn en gjennomlesning som sier «absent»', () => {
    const report = check(
      { extraction: UTEN_KI },
      FIXTURE_SOURCE_TEXT,
      true,
      lest({
        extraction: UTEN_KI,
      }),
    )
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.findings).toMatch(/Søket gjennom hele representasjonen fant noe som ligner/)
  })

  // ------------------------------------------------------------------------
  // Når begge leddene konkluderer
  // ------------------------------------------------------------------------

  it('fører opp feltet når begge leddene konkluderte', () => {
    const report = check({ extraction: UTEN_KI }, UTEN_INTERVALL)
    expect(report.checkedFields).toContain('source_wide_absence')
    expect(report.rationale).toMatch(/kontrollert i to ledd/)
    expect(report.rationale).toMatch(/«confidence_interval»/)
    // Begrunnelsen navngir hvem som leste, og hvilken forespørsel svaret gjaldt.
    expect(report.rationale).toMatch(/test\/gjennomlesning/)
    expect(report.rationale).toMatch(/promptmal evidence-extraction\/source-wide-absence\/1/)
  })

  // Ordlyden er den sannheten kontrollen faktisk bærer, og det er ikke pynt:
  // `not_reported` gjelder kildeversjonen, ikke publikasjonen. Sier raden noe
  // annet, påstår auditsporet mer enn kontrollen bærer (DATABASE_ARCHITECTURE.md §29).
  it('påstår ikke at opplysningen mangler i publikasjonen, bare i kildeversjonen', () => {
    const report = check({ extraction: UTEN_KI }, UTEN_INTERVALL)
    expect(report.rationale).toMatch(/ikke står i den kildeversjonen raden viser til/)
    expect(report.rationale).toMatch(/ikke at den ikke står i publikasjonen/)
  })

  // …og den navngir hva som faktisk ble gjennomgått. Et abstrakt sier mindre om
  // publikasjonen enn en fulltekst, og dekningen skal aldri leses som mer enn
  // den er (EVIDENCE_PIPELINE.md §13).
  it('navngir representasjonen som ble gjennomgått', () => {
    expect(check({ extraction: UTEN_KI }, UTEN_INTERVALL).rationale).toMatch(/«full_text»/)
    const abstrakt = check(
      {
        extraction: UTEN_KI,
        sourceVersion: sourceVersionFixture({ representation: 'abstract' }),
      },
      UTEN_INTERVALL,
    )
    expect(abstrakt.checkedFields).toContain('source_wide_absence')
    expect(abstrakt.rationale).toMatch(/«abstract»/)
  })

  it('sier fra når kildeversjonen ikke har en registrert representasjonstype', () => {
    const report = check(
      {
        extraction: UTEN_KI,
        sourceVersion: sourceVersionFixture({ representation: null }),
      },
      UTEN_INTERVALL,
    )
    expect(report.rationale).toMatch(/ikke har en registrert representasjonstype/)
  })

  // ------------------------------------------------------------------------
  // Når ett av leddene stopper
  // ------------------------------------------------------------------------

  // Fiksturteksten oppgir «95% CI 0.4 to 2.6». Et funn som fører intervallet som
  // ikke rapportert, kan da ikke få fraværet kontrollert.
  it('fører ikke opp feltet når kildeversjonen oppgir en slik verdi', () => {
    const report = check({ extraction: UTEN_KI })
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.findings).toMatch(/Søket gjennom hele representasjonen fant noe som ligner/)
  })

  // Et treff er ikke en anklage: det kan gjelde et annet endepunkt eller et
  // annet tidspunkt. Samme asymmetri som ellers i modulen.
  it('gjør ikke et treff til et avvik', () => {
    const report = check({ extraction: UTEN_KI })
    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toMatch(/ikke i seg selv et avvik/)
  })

  it('dekker ikke feltet når gjennomlesningen fant verdien', () => {
    const report = check(
      { extraction: UTEN_KI },
      UTEN_INTERVALL,
      true,
      lest({ extraction: UTEN_KI }, { confidence_interval: 'present' }),
    )
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toMatch(/Gjennomlesningen av hele representasjonen fant en verdi/)
  })

  // Et sitat gjennomlesningen skrev om — eller fant på — skal ikke legges til
  // grunn som et funn. Fraværet dekkes uansett ikke, men teksten skal si hvilken
  // av de to tingene som skjedde.
  it('sier fra når gjennomlesningens sitat ikke står i teksten', () => {
    const review = lest({ extraction: UTEN_KI }, { confidence_interval: 'present' })
    const report = check({ extraction: UTEN_KI }, UTEN_INTERVALL, true, review)
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.findings).toMatch(/lot seg IKKE gjenfinne ordrett/)
  })

  it('dekker ikke feltet når gjennomlesningen ikke kunne avgjøre det', () => {
    const report = check(
      { extraction: UTEN_KI },
      UTEN_INTERVALL,
      true,
      lest({ extraction: UTEN_KI }, { confidence_interval: 'uncertain' }),
    )
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.findings).toMatch(/kunne ikke avgjøre fraværet/)
  })

  // En gjennomlesning som gjelder et annet funn, dekker ingenting her. Filen kan
  // være lagt i feil mappe, og mappenavnet alene skal ikke avgjøre det.
  it('ser bort fra en gjennomlesning som gjelder et annet evidensfunn', () => {
    const review = lest({ extraction: UTEN_KI })
    const report = check({ extraction: UTEN_KI }, UTEN_INTERVALL, true, {
      ...review,
      evidenceItemId: '00000000-0000-4000-8000-000000000000',
    })
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.findings).toMatch(/gjelder evidensfunnet 00000000/)
  })

  // Grunnen til at halvdelen står åpen, skal stå i teksten. «Ingen fil» og «et
  // svar på en annen tekst» er ikke det samme for den som skal gjøre noe.
  it('gjengir grunnen til at ingen gjennomlesning kunne brukes', () => {
    const report = check({ extraction: UTEN_KI }, UTEN_INTERVALL, true, {
      kind: 'missing',
      reason: 'svaret gjaldt en annen forespørsel',
    })
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.findings).toMatch(/svaret gjaldt en annen forespørsel/)
  })

  // Funn i teknisk review: et udekket kildeomfattende fravær er en uavklart
  // kontroll, ikke bare en merknad. Raden kunne før komme ut som `verified`
  // med `findings` null, mens begrunnelsen sa at fraværet ikke lot seg
  // bekrefte — en bekreftelse som motsa sin egen tekst.
  it('lar et udekket fravær avgjøre utfallet, ikke bare merknadene', () => {
    // Alt annet stemmer: utdraget er radens eget, står ordrett i kilden, og
    // binder arm, endepunkt, populasjon og verdi sammen. Uten fraværskontrollen
    // ville denne raden vært `verified`.
    const støtte =
      'Sertraline-treated patients with major depressive disorder had a mean weight ' +
      'change of 1.5 kg'
    const overrides = {
      extraction: {
        sampleSize: null,
        // Kilden oppgir «N = 284», så søket finner en utvalgsstørrelse og
        // fraværet kan ikke regnes som kontrollert.
        sampleSizeAvailability: 'not_reported',
        ciLower: null,
        ciUpper: null,
        ciLevelPercent: null,
        confidenceIntervalAvailability: 'not_applicable',
        rawExtraction: { støtte },
      },
    } as const
    const report = check(overrides, `${FIXTURE_SOURCE_TEXT}\n<p>${støtte}</p>`)
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.outcome).toBe('uncertain')
    // …og et uavklart utfall må ha et funn: databasen krever det.
    expect(report.findings).not.toBeNull()
    expect(report.findings).toMatch(/«sample_size»/)
  })

  // Stemmer ikke fingeravtrykket, gjelder begge leddene en annen tekst enn den
  // ekstraksjonen ble laget av.
  it('kontrollerer ikke en representasjon som ikke lot seg reprodusere', () => {
    const report = check({ extraction: UTEN_KI }, UTEN_INTERVALL, false)
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.findings).toMatch(/ikke samme fingeravtrykk/)
  })

  // Raden gjør ingen kildeomfattende påstand: da er det ingenting å
  // kontrollere, og et felt ført opp likevel ville vært en kontroll av
  // ingenting.
  it('fører aldri opp feltet for en rad uten en global fraværsstatus', () => {
    // Standardfiksturen fører tidspunktet som ikke rapportert, så «ingen global
    // fraværsstatus» må settes eksplisitt.
    const ingenFravaer = {
      timepointAvailability: 'not_applicable',
      ...UTEN_KI,
      confidenceIntervalAvailability: 'not_applicable',
    } as const
    expect(check({ extraction: ingenFravaer }).checkedFields).not.toContain('source_wide_absence')
    expect(
      check({
        extraction: { ...ingenFravaer, confidenceIntervalAvailability: 'not_extractable' },
      }).checkedFields,
    ).not.toContain('source_wide_absence')
  })

  // En utvalgsstørrelse ført som ikke rapportert, mens teksten oppgir «N = 284».
  it('finner en utvalgsstørrelse som står i kildeversjonen', () => {
    const report = check({
      extraction: {
        sampleSize: null,
        sampleSizeAvailability: 'not_reported',
        rawExtraction: {
          resultat:
            'Sertraline-treated patients with major depressive disorder had a mean weight ' +
            'change of 1.5 kg',
        },
      },
    })
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.findings).toMatch(/«sample_size»/)
  })

  // …og motsatt, når teksten ikke oppgir noe antall og gjennomlesningen bekrefter det.
  it('fører opp feltet når verken søket eller gjennomlesningen fant et antall', () => {
    const report = check(
      {
        extraction: {
          sampleSize: null,
          sampleSizeAvailability: 'not_reported',
          ciLower: null,
          ciUpper: null,
          ciLevelPercent: null,
          confidenceIntervalAvailability: 'not_applicable',
          rawExtraction: {
            resultat:
              'Sertraline-treated patients with major depressive disorder had a mean weight ' +
              'change of 1.5 kg',
          },
        },
      },
      UTEN_INTERVALL,
    )
    expect(report.checkedFields).toContain('source_wide_absence')
  })

  // Populasjonen er en etikett og ikke et tall, og radens egen er norsk mens
  // kilden er engelsk. Søket har da ingen form å prøve — men gjennomlesningen
  // leser teksten og kan svare. Dekningen sier eksplisitt at den hviler på ett
  // ledd (issue #79).
  const UTEN_POPULASJONSVERDI = {
    populationLabel: null,
    populationAvailability: 'not_reported',
    timepointAvailability: 'not_applicable',
    ciLower: null,
    ciUpper: null,
    ciLevelPercent: null,
    confidenceIntervalAvailability: 'not_applicable',
    rawExtraction: {
      resultat:
        'Sertraline-treated patients with major depressive disorder had a mean weight ' +
        'change of 1.5 kg',
    },
  } as const

  it('sier fra når søket ikke har en form å prøve, men lar gjennomlesningen avgjøre', () => {
    const report = check({ extraction: UTEN_POPULASJONSVERDI }, UTEN_INTERVALL)
    expect(report.checkedFields).toContain('source_wide_absence')
    expect(report.rationale).toMatch(/har søket ingen form å prøve/)
    expect(report.rationale).toMatch(/hviler konklusjonen på gjennomlesningen alene/)
  })

  it('dekker ikke et felt uten søkbar form når ingen gjennomlesning foreligger', () => {
    const report = check({ extraction: UTEN_POPULASJONSVERDI }, UTEN_INTERVALL, true, null)
    expect(report.checkedFields).not.toContain('source_wide_absence')
    expect(report.findings).toMatch(/«population»/)
  })

  // Alle de globalt fraværende feltene må være avklart. Ett udekket felt er en
  // udekket påstand, og hele feltet holdes tilbake.
  it('holder feltet tilbake når bare ett av flere fravær er avklart', () => {
    const overrides = {
      extraction: {
        ...UTEN_KI,
        populationLabel: null,
        populationAvailability: 'not_reported',
      },
    } as const
    const report = check(
      overrides,
      UTEN_INTERVALL,
      true,
      lest(overrides, {
        population: 'uncertain',
      }),
    )
    expect(report.checkedFields).not.toContain('source_wide_absence')
  })
})

describe('sourceWideAbsenceSearch', () => {
  const TEKST = [
    'Sertraline-treated patients (N = 48) had a mean weight change of 1.5 kg ' +
      '(95% CI 0.4 to 2.6) at 8 weeks.',
  ]

  it('finner et intervall som står i teksten', () => {
    expect(sourceWideAbsenceSearch(TEKST, 'confidence_interval').kind).toBe('found')
  })

  it('finner ingenting når teksten ikke oppgir en slik verdi', () => {
    expect(
      sourceWideAbsenceSearch(
        ['Sertraline-treated patients had a mean weight change of 1.5 kg.'],
        'confidence_interval',
      ).kind,
    ).toBe('not_found')
  })

  it('skiller feltene fra hverandre', () => {
    expect(sourceWideAbsenceSearch(TEKST, 'sample_size').kind).toBe('found')
    expect(sourceWideAbsenceSearch(TEKST, 'timepoint').kind).toBe('found')
    expect(sourceWideAbsenceSearch(TEKST, 'estimate').kind).toBe('found')
  })

  it('sier fra om feltene som ikke har en søkbar form', () => {
    expect(sourceWideAbsenceSearch(TEKST, 'population').kind).toBe('not_searchable')
    expect(sourceWideAbsenceSearch(TEKST, 'outcome').kind).toBe('not_searchable')
  })

  // Et nakent tall er ikke en verdi av noe felt: uten et anker som navngir
  // hva tallet er, teller det ikke som et treff.
  it('teller ikke et nakent tall som en verdi', () => {
    expect(
      sourceWideAbsenceSearch(['Sertraline was given to the group in room two.'], 'estimate').kind,
    ).toBe('not_found')
  })

  // Funn i teknisk review, og den farligste av dem: kilder skriver anaforisk.
  // Et søk som krevde at verdien sto i en passasje som selv navngir armen,
  // kastet andre setning før den ble søkt — og bekreftet et fravær av et
  // intervall som sto der, svart på hvitt.
  it('finner en verdi som står i setningen etter den som navngir armen', () => {
    expect(
      sourceWideAbsenceSearch(
        ['Sertraline patients improved.', 'The 95% CI was 0.4 to 2.6.'],
        'confidence_interval',
      ).kind,
    ).toBe('found')
  })

  // …og finner den også når armen ikke er nevnt i det hele tatt. Søket har
  // ingen binding til raden, med vilje: en maskin kan ikke se hvilket intervall
  // som er radens, og skal derfor ikke påstå at ingen av dem er det.
  it('finner en verdi i en tekst som ikke nevner armen', () => {
    expect(
      sourceWideAbsenceSearch(['The 95% CI was 0.4 to 2.6.'], 'confidence_interval').kind,
    ).toBe('found')
  })

  // Det andre reviewfunnet: tall skrevet med bokstaver er helt vanlige, og
  // står i denne kodebasens egen PDF-fikstur. Et sifferbasert søk ga «ingen
  // utvalgsstørrelse i kilden» på nettopp den setningen.
  it('teller tall skrevet med bokstaver', () => {
    expect(
      sourceWideAbsenceSearch(
        ['Forty-eight sertraline-treated patients completed the trial.'],
        'sample_size',
      ).kind,
    ).toBe('found')
    expect(
      sourceWideAbsenceSearch(['Treatment continued for eight weeks.'], 'timepoint').kind,
    ).toBe('found')
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

  // Norske og engelske kilder skriver desimalskilletegnet ulikt, og tallet er
  // det samme. Uten dette ville en norsk kilde aldri kunne bekrefte et
  // registrert desimaltall.
  it('godtar et desimaltall skrevet med komma i kilden', () => {
    expect(numberOccursIn(searchProjections('Vektendringen var 1,5 kg.'), '1.5')).toBe(true)
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
    const item = verificationItemFixture()
    const report = checkExtraction({
      item,
      sourceText: `${FIXTURE_SOURCE_TEXT}\n<p>&#x110000;</p>`,
      representationReproduced: true,
      absenceReview: absenceReviewFixture(item),
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
