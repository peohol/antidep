import { describe, expect, it } from 'vitest'

import {
  checkExtraction,
  numberOccursIn,
  searchProjections,
  trimNumericText,
} from './extraction-checks'
import { FIXTURE_SOURCE_TEXT, verificationItemFixture } from './test-support'
import type { VerificationExtraction } from './verification-input'

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
        rawExtraction: { metode: 'Sertraline patients (N = 284) with major depressive' },
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
    const report = check({ extraction: { rawExtraction } })

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
    const report = check({ extraction: { rawExtraction } })

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
      'Sertraline patients had a mean weight change of 1.5 kg (95% CI 0.4 to 2.6) ' +
      'over the study period.'
    const report = check(
      {
        extraction: {
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
        { extraction: { sampleSize: størrelse, rawExtraction: { resultat: FLERARMS } } },
        `Forord. ${FLERARMS}`,
      )

      expect(report.outcome).not.toBe('verified')
      expect(report.checkedFields).not.toContain('sample_size')
    },
  )

  it('bekrefter utvalgsstørrelsen som står inntil radens egen arm', () => {
    const report = check(
      { extraction: { sampleSize: 48, rawExtraction: { resultat: FLERARMS } } },
      `Forord. ${FLERARMS}`,
    )

    expect(report.checkedFields).toContain('sample_size')
  })

  it('bekrefter ikke et estimat fra et utdrag som oppgir to armer i samme setning', () => {
    const utdrag =
      'The mean difference was 0.8 kg for sertraline and the mean difference was 0.4 kg ' +
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
      'Sertraline: weight change was 1.5 kg (95% CI 0.4 to 2.6) and quality of life ' +
      'improved (95% CI 1.1 to 3.2) over the study period.'
    const report = check(
      { extraction: { rawExtraction: { resultat: utdrag } } },
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
      { extraction: { sampleSize: 48, rawExtraction: { arm, resultat: tall } } },
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
      { extraction: { sampleSize: 48, rawExtraction: { resultat: tall } } },
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
          sampleSize: 48,
          confidenceIntervalAvailability: 'not_reported',
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
          estimate: '5.0',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
          outcomeLabel: 'body weight change',
          sampleSizeAvailability: 'not_reported',
          sampleSize: null,
          confidenceIntervalAvailability: 'not_reported',
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
          estimate: '5.0',
          outcomeLabel: 'body weight change',
          sampleSizeAvailability: 'not_reported',
          sampleSize: null,
          confidenceIntervalAvailability: 'not_reported',
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
      { extraction: { sampleSize: 48, rawExtraction: { sitat: utdrag } } },
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
          estimate: '5.0',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_reported',
          confidenceIntervalAvailability: 'not_reported',
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
          estimateAvailability: 'not_reported',
          estimate: null,
          estimateUnit: null,
          effectMeasure: null,
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_reported',
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
          estimate: '5.0',
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_reported',
          confidenceIntervalAvailability: 'not_reported',
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
          estimate: '5.0',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_reported',
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
      { extraction: { sampleSize: 48, rawExtraction: { sitat: utdrag } } },
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
          estimateAvailability: 'not_reported',
          estimate: null,
          estimateUnit: null,
          effectMeasure: null,
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_reported',
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
      { extraction: { sampleSize: 48, rawExtraction: { dose, annen } } },
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
          estimate: '5.0',
          estimateUnit: null,
          effectMeasure: 'risk_ratio',
          outcomeLabel: 'body weight change',
          sampleSize: null,
          sampleSizeAvailability: 'not_reported',
          confidenceIntervalAvailability: 'not_reported',
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
      { extraction: { sampleSize: 48, rawExtraction: { sitat: utdrag } } },
      `Forord. ${utdrag}`,
    )

    expect(report.outcome).not.toBe('verified')
    expect(report.checkedFields).not.toContain('sample_size')
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
    const report = check({ extraction: { rawExtraction: { sitat: utdrag } } }, `Forord. ${utdrag}`)

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
    ['N = 48', 'Patients (sertraline, N = 48) completed the trial', 48],
    ['sample size was 48', 'the sertraline sample size was 48', 48],
    ['284 adults', 'sertraline: 284 adults were randomised', 284],
    ['48 patients', 'the sertraline arm had 48 patients', 48],
    ['norsk form', 'sertraline-gruppen: 48 pasienter', 48],
  ])('kjenner igjen utvalgsstørrelsen skrevet som «%s»', (_navn, kilde, størrelse) => {
    const report = check(
      {
        extraction: {
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
    // Ikke et avvik. Intervallet står uavklart fordi radens eget estimat er
    // det som binder det til endepunktet, og her finnes det ikke.
    expect(report.outcome).not.toBe('needs_correction')
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

// ----------------------------------------------------------------------------
// Bindingen mellom et tall og den raden det er registrert på
//
// Tre veier til en falsk bekreftelse, alle av samme slag: tallet står i et
// utdrag som er ordrett riktig, men verdien tilhører noe annet enn raden.
// ----------------------------------------------------------------------------
describe('checkExtraction — tallet må tilhøre denne raden', () => {
  function withQuote(quote: string, extraction: Partial<VerificationExtraction>) {
    return check(
      { extraction: { ...extraction, rawExtraction: { utdrag: quote } } },
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
        confidenceIntervalAvailability: 'not_reported',
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
      sampleSizeAvailability: 'not_reported',
      sampleSize: null,
      estimate: '1.5',
      estimateUnit: 'kg',
      confidenceIntervalAvailability: 'not_reported',
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
        sampleSizeAvailability: 'not_reported',
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
        confidenceIntervalAvailability: 'not_reported',
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
    const report = check({ extraction: { outcomeLabel: 'vektendring' } })
    expect(report.checkedFields).not.toContain('outcome')
  })

  it('behandler et manglende begrepstreff som en merknad, ikke som et avvik', () => {
    const report = check({ extraction: { outcomeLabel: 'vektendring' } })
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
      extraction: { comparatorKind: 'drug', comparatorDrugName: 'fluoxetine' },
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
    sampleSizeAvailability: 'not_reported',
    estimate: null,
    estimateUnit: null,
    estimateAvailability: 'not_reported',
    ciLower: null,
    ciUpper: null,
    ciLevelPercent: null,
    confidenceIntervalAvailability: 'not_reported',
  } as const satisfies Partial<VerificationExtraction>

  function utenTallMedUtdrag(quote: string, extraction: Partial<VerificationExtraction> = {}) {
    return check(
      { extraction: { ...utenTall, ...extraction, rawExtraction: { utdrag: quote } } },
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
      { populationAvailability: 'not_reported' },
      'intervention_arm',
    ],
    [
      'endepunktet',
      'Sertraline-treated patients were followed over the trial',
      { populationAvailability: 'not_reported' },
      'outcome',
    ],
    [
      'komparatoren',
      BEGGE,
      {
        comparatorKind: 'drug',
        comparatorDrugName: 'fluoxetine',
        populationAvailability: 'not_reported',
      },
      'comparator_arm',
    ],
    ['populasjonen', BEGGE, { populationLabel: 'voksne med depressiv lidelse' }, 'population'],
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
      populationAvailability: 'not_reported',
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
        extraction: { ...utenTall, populationAvailability: 'not_reported', rawExtraction },
      },
      `${FIXTURE_SOURCE_TEXT}\n${quotes.map((quote) => `<p>${quote}</p>`).join('\n')}`,
    )

    expect(report.outcome).toBe('uncertain')
    expect(report.findings).toContain('Kontrollen konkluderte ikke')
  })

  // Den positive kontrollen: står begrepene faktisk i utdraget, er raden
  // bekreftet som før. Uten denne kunne rettelsen over gjort alt uavklart.
  it('bekrefter en rad uten tallfelt når begrepene faktisk står i utdraget', () => {
    const report = utenTallMedUtdrag(BEGGE, { populationAvailability: 'not_reported' })

    expect(report.outcome).toBe('verified')
    expect(report.checkedFields).toEqual(
      expect.arrayContaining(['raw_extraction', 'source_locator', 'intervention_arm', 'outcome']),
    )
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
