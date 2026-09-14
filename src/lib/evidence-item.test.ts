import { describe, expect, it } from 'vitest'
import type { PublishedClaimEvidenceRow } from '../types/api'
import {
  AVAILABILITY_PARTITION,
  describeEvidenceConfidenceInterval,
  describeEvidenceEstimate,
  describeEvidenceFinding,
  describeEvidencePopulation,
  describeEvidenceSampleSize,
  describeEvidenceStance,
  describeEvidenceTimepoint,
  describePublicationDate,
  readReportedDirection,
  readSourceStatus,
  readSourceType,
  readStudyDesign,
} from './evidence-item'
import type { ClaimComparatorState } from './claim-effect'
import { CLAIM_DIRECTIONS, REPORTED_DIRECTIONS, VALUE_AVAILABILITIES } from '../types/api'

function evidenceRow(
  overrides: Partial<PublishedClaimEvidenceRow> = {},
): PublishedClaimEvidenceRow {
  return {
    claim_id: '11111111-1111-4111-8111-111111111111',
    claim_revision_id: '22222222-2222-4222-8222-222222222222',
    claim_evidence_link_id: '55555555-5555-4555-8555-111111111111',

    relationship_type: 'supports',
    directness: 'direct',
    relevance_note: 'Testnotat: funnet måler samme endepunkt i samme populasjon.',

    evidence_item_id: '66666666-6666-4666-8666-111111111111',
    study_design: 'randomized_controlled_trial',

    population_id: '77777777-7777-4777-8777-111111111111',
    population_label: 'voksne med depresjon',
    population_detail: 'Voksne 18–65 år i poliklinisk behandling.',
    population_availability: 'reported_value',
    sample_size: 240,
    sample_size_availability: 'reported_value',

    intervention_drug_id: '33333333-3333-4333-8333-333333333333',
    intervention_drug_name: 'virkestoff a',
    intervention_detail: null,
    comparator_kind: 'placebo',
    comparator_drug_id: null,
    comparator_drug_name: null,
    comparator_detail: null,

    outcome_concept_id: '44444444-4444-4444-8444-444444444444',
    outcome_label: 'vektendring',
    outcome_detail: 'Endring i kroppsvekt fra baseline.',
    timepoint_min: '56 days',
    timepoint_max: '56 days',
    timepoint_availability: 'reported_value',

    reported_direction: 'increase',
    effect_measure: 'mean_difference',
    estimate: 1.7,
    estimate_unit: 'kg',
    estimate_availability: 'reported_value',
    ci_lower: 0.9,
    ci_upper: 2.5,
    ci_level_percent: 95,
    confidence_interval_availability: 'reported_value',

    limitations_text: null,
    source_locator: 'Tabell 2, side 114',

    extraction_withdrawn: false,
    extraction_withdrawn_at: null,
    extraction_withdrawal_rationale: null,

    source_version_id: null,
    source_version_retrieved_at: null,
    source_version_retrieved_from: null,
    source_version_external_version: null,
    source_version_content_hash: null,

    source_id: '55555555-5555-4555-8555-555555555555',
    source_type: 'journal_article',
    source_title: 'Testkilde A: vektendring ved åtte uker',
    source_authors_or_issuer: 'Testforfatter m.fl.',
    source_publisher_or_journal: 'Testtidsskrift',
    source_publication_date: '2019-03-01',
    source_publication_date_precision: 'month',
    source_status: 'active',
    source_status_note: null,
    source_dois: ['10.0000/test.a'],
    source_pmids: null,
    ...overrides,
  }
}

// ============================================================================
// Avledningen av ett evidensfunn.
//
// Alle testene handler om det samme skillet: et fravær skal aldri kunne leses
// som en nullverdi, og en verdi utenfor et vokabular skal aldri kunne falle i
// en godartet gren.
// ============================================================================

const PLACEBO: ClaimComparatorState = { kind: 'placebo' }
const NO_COMPARATOR: ClaimComparatorState = { kind: 'none' }

describe('vokabularene deler seg i to halvdeler, og ingen verdi faller utenfor', () => {
  it('hver availability-verdi er enten «verdi finnes» eller «verdi mangler»', () => {
    // Vaktposten mot at en ny enum-verdi stilltiende havner i én av halvdelene.
    // `api-vocabularies.test.ts` binder VALUE_AVAILABILITIES til migrasjonen;
    // denne binder de to listene her til VALUE_AVAILABILITIES.
    const partitioned = [...AVAILABILITY_PARTITION.present, ...AVAILABILITY_PARTITION.absent]
    expect(new Set(partitioned)).toEqual(new Set(AVAILABILITY_PARTITION.all))
    expect(partitioned).toHaveLength(AVAILABILITY_PARTITION.all.length)
    expect(new Set(AVAILABILITY_PARTITION.all)).toEqual(new Set(VALUE_AVAILABILITIES))
  })

  it.each(VALUE_AVAILABILITIES)('%s klassifiseres, framfor å bli et kontraktsbrudd', (value) => {
    // Forutsetningsassertion: uten den ville testene under kunne passere fordi
    // *alt* ble `unrecognised_availability`.
    expect(
      describeEvidencePopulation({ population_availability: value, population_label: 'x' }),
    ).not.toMatchObject({ reason: 'unrecognised_availability' })
  })

  it('rapportert retning er ikke påstandens retning', () => {
    // Fella hand-offen navngir: vokabularene ser like ut og har hver sin fjerde
    // verdi. Slått sammen ville «kilden oppgir ingen retning» og «Antidep
    // konkluderer med ingen klar forskjell» kunne bytte plass.
    expect(REPORTED_DIRECTIONS).toContain('not_stated')
    expect(CLAIM_DIRECTIONS).not.toContain('not_stated')
    expect(readReportedDirection('not_stated')).toEqual({ kind: 'known', value: 'not_stated' })
  })
})

describe('relasjonen mellom funnet og påstanden', () => {
  it('leser en gyldig relasjon med sin direkthet', () => {
    expect(
      describeEvidenceStance({ relationship_type: 'contradicts', directness: 'direct' }),
    ).toEqual({ kind: 'known', relationship: 'contradicts', directness: 'direct' })
  })

  it('en ukjent relasjonstype blir ukjent, ikke støtte', () => {
    // Den farligste enkeltfeilen på siden: et funn Antidep ikke kan si
    // relasjonen til, må ikke kunne leses som støtte for påstanden (§9).
    expect(describeEvidenceStance({ relationship_type: 'refutes', directness: 'direct' })).toEqual({
      kind: 'unknown',
      reason: 'unrecognised_relationship',
      rawRelationship: 'refutes',
      rawDirectness: 'direct',
    })
  })

  it('en ukjent direkthet blir ukjent', () => {
    expect(
      describeEvidenceStance({ relationship_type: 'supports', directness: 'nesten' }),
    ).toMatchObject({ reason: 'unrecognised_directness' })
  })

  it('en indirekte relasjon som hevder direkthet er et brudd', () => {
    // Migrasjon 004 forbyr paret. De to sier forskjellige ting om samme lenke.
    expect(
      describeEvidenceStance({ relationship_type: 'indirect', directness: 'direct' }),
    ).toMatchObject({ reason: 'indirect_relationship_claiming_directness' })
  })

  it('en indirekte relasjon med indirekte direkthet er gyldig', () => {
    expect(
      describeEvidenceStance({ relationship_type: 'indirect', directness: 'indirect' }),
    ).toMatchObject({ kind: 'known' })
  })

  it('et nøytralt funn kan treffe påstanden direkte', () => {
    // Nøytraliteten ligger på stance-aksen, ikke på indirekthetsaksen.
    expect(
      describeEvidenceStance({ relationship_type: 'neutral_contextual', directness: 'direct' }),
    ).toMatchObject({ kind: 'known', relationship: 'neutral_contextual' })
  })
})

describe('et felt med sin availability', () => {
  it('en rapportert verdi står, uten forbehold', () => {
    expect(
      describeEvidencePopulation({
        population_availability: 'reported_value',
        population_label: 'voksne',
      }),
    ).toEqual({ kind: 'reported', value: 'voksne', uncertainExtraction: false })
  })

  it('en usikker ekstraksjon står, med forbehold', () => {
    // Verdien finnes, men ekstraksjonen er registrert som usikker. Å behandle
    // den som en vanlig rapportert verdi ville skjult forbeholdet.
    expect(
      describeEvidencePopulation({
        population_availability: 'uncertain_extraction',
        population_label: 'voksne',
      }),
    ).toEqual({ kind: 'reported', value: 'voksne', uncertainExtraction: true })
  })

  it.each(AVAILABILITY_PARTITION.absent)('%s er et fravær med sin egen grunn', (reason) => {
    // De fire grunnene er egenskaper ved forskjellige ting — studien,
    // publikasjonen, funnet, ekstraksjonen — og må ikke slås sammen.
    expect(
      describeEvidencePopulation({ population_availability: reason, population_label: null }),
    ).toEqual({ kind: 'absent', reason })
  })

  it('en ukjent availability blir et brudd, ikke et registrert fravær', () => {
    expect(
      describeEvidencePopulation({ population_availability: 'kanskje', population_label: null }),
    ).toEqual({ kind: 'unknown', reason: 'unrecognised_availability', rawAvailability: 'kanskje' })
  })

  it('en verdi som mangler der statusen lover en, er et brudd', () => {
    expect(
      describeEvidencePopulation({
        population_availability: 'reported_value',
        population_label: null,
      }),
    ).toMatchObject({ reason: 'missing_value' })
  })

  it('en verdi som står der statusen sier at den ikke gjør det, er et brudd', () => {
    // Verdien vises ikke: den er merket som noe kilden ikke oppgir.
    expect(
      describeEvidencePopulation({
        population_availability: 'not_reported',
        population_label: 'voksne',
      }),
    ).toMatchObject({ reason: 'unexpected_value' })
  })
})

describe('utvalgsstørrelsen', () => {
  it('leser et positivt heltall', () => {
    expect(
      describeEvidenceSampleSize({ sample_size_availability: 'reported_value', sample_size: 240 }),
    ).toMatchObject({ kind: 'reported', value: 240 })
  })

  it.each([0, -3, 12.5, Number.NaN])('%s er ikke en utvalgsstørrelse', (size) => {
    // Et utvalg på 0 ser ut som et tall og leses som «ingen deltakere». Det er
    // nettopp den lesningen §17 forbyr.
    expect(
      describeEvidenceSampleSize({ sample_size_availability: 'reported_value', sample_size: size }),
    ).toMatchObject({ reason: 'implausible_value' })
  })
})

describe('måletidspunktet', () => {
  it('leser paret', () => {
    expect(
      describeEvidenceTimepoint({
        timepoint_availability: 'reported_value',
        timepoint_min: '56 days',
        timepoint_max: '56 days',
      }),
    ).toMatchObject({ kind: 'reported', value: { min: '56 days', max: '56 days' } })
  })

  it('et enslig ledd er halve verdien, og ikke en verdi', () => {
    expect(
      describeEvidenceTimepoint({
        timepoint_availability: 'reported_value',
        timepoint_min: '56 days',
        timepoint_max: null,
      }),
    ).toMatchObject({ reason: 'incomplete_value' })
  })

  it('ikke målt er ikke tidspunkt null', () => {
    expect(
      describeEvidenceTimepoint({
        timepoint_availability: 'not_measured',
        timepoint_min: null,
        timepoint_max: null,
      }),
    ).toEqual({ kind: 'absent', reason: 'not_measured' })
  })
})

describe('konfidensintervallet', () => {
  it('leser intervallet med nivået sitt', () => {
    expect(
      describeEvidenceConfidenceInterval({
        confidence_interval_availability: 'reported_value',
        ci_lower: 0.9,
        ci_upper: 2.5,
        ci_level_percent: 95,
      }),
    ).toMatchObject({ kind: 'reported', value: { lower: 0.9, upper: 2.5, levelPercent: 95 } })
  })

  it('et intervall uten nivå er ikke tolkbart', () => {
    // 0,9 til 2,5 betyr forskjellige ting på 90 % og på 99 %.
    expect(
      describeEvidenceConfidenceInterval({
        confidence_interval_availability: 'reported_value',
        ci_lower: 0.9,
        ci_upper: 2.5,
        ci_level_percent: null,
      }),
    ).toMatchObject({ reason: 'incomplete_value' })
  })

  it('et intervall uten øvre grense er ikke tolkbart', () => {
    expect(
      describeEvidenceConfidenceInterval({
        confidence_interval_availability: 'reported_value',
        ci_lower: 0.9,
        ci_upper: null,
        ci_level_percent: 95,
      }),
    ).toMatchObject({ reason: 'incomplete_value' })
  })

  it('et intervall med grensene i feil rekkefølge er ikke tolkbart', () => {
    // Et brudd på verdien, ikke på paret: begge ledd står, men de kan ikke være
    // et intervall. Skilt fra `incomplete_value` fordi rettingen er en annen.
    expect(
      describeEvidenceConfidenceInterval({
        confidence_interval_availability: 'reported_value',
        ci_lower: 2.5,
        ci_upper: 0.9,
        ci_level_percent: 95,
      }),
    ).toMatchObject({ reason: 'implausible_value' })
  })

  it('et manglende intervall betyr upresist grunnlag, ikke et presist estimat', () => {
    expect(
      describeEvidenceConfidenceInterval({
        confidence_interval_availability: 'not_reported',
        ci_lower: null,
        ci_upper: null,
        ci_level_percent: null,
      }),
    ).toEqual({ kind: 'absent', reason: 'not_reported' })
  })
})

describe('estimatet', () => {
  const reported = {
    estimate_availability: 'reported_value',
    effect_measure: 'mean_difference',
    estimate: 1.7,
    estimate_unit: 'kg',
  }

  it('leser et tolkbart estimat', () => {
    expect(describeEvidenceEstimate(reported, PLACEBO)).toEqual({
      kind: 'quantified',
      measure: 'mean_difference',
      value: 1.7,
      unit: 'kg',
      uncertainExtraction: false,
    })
  })

  it('bærer forbeholdet fra en usikker ekstraksjon', () => {
    expect(
      describeEvidenceEstimate(
        { ...reported, estimate_availability: 'uncertain_extraction' },
        PLACEBO,
      ),
    ).toMatchObject({ kind: 'quantified', uncertainExtraction: true })
  })

  it('et kontrastivt mål uten komparator er ikke tolkbart', () => {
    // Samme regel som på påstandskortet, og den har bare én utgave.
    expect(describeEvidenceEstimate(reported, NO_COMPARATOR)).toMatchObject({
      reason: 'contrastive_measure_without_comparator',
    })
  })

  it('en endring innenfor én arm med komparator er ikke tolkbart', () => {
    expect(
      describeEvidenceEstimate(
        { ...reported, effect_measure: 'mean_change', estimate_unit: 'kg' },
        PLACEBO,
      ),
    ).toMatchObject({ reason: 'within_arm_measure_with_comparator' })
  })

  it('et dimensjonalt mål uten enhet er ikke tolkbart', () => {
    expect(describeEvidenceEstimate({ ...reported, estimate_unit: null }, PLACEBO)).toMatchObject({
      reason: 'missing_unit',
    })
  })

  it('et tall uten mål er ikke en størrelse', () => {
    expect(
      describeEvidenceEstimate({ ...reported, effect_measure: null, estimate_unit: null }, PLACEBO),
    ).toMatchObject({ reason: 'value_without_measure' })
  })

  it('statusen lover en verdi, og ingen av feltene er utfylt', () => {
    expect(
      describeEvidenceEstimate(
        {
          estimate_availability: 'reported_value',
          effect_measure: null,
          estimate: null,
          estimate_unit: null,
        },
        PLACEBO,
      ),
    ).toMatchObject({ reason: 'missing_value' })
  })

  it('statusen lover en verdi, og bare målet står', () => {
    expect(describeEvidenceEstimate({ ...reported, estimate: null }, PLACEBO)).toMatchObject({
      reason: 'measure_without_value',
    })
  })

  it('et fravær beholder målet kilden brukte', () => {
    // «Kilden målte gjennomsnittsforskjell, men oppgir ikke tallet» er et annet
    // utsagn enn «kilden målte ingenting».
    expect(
      describeEvidenceEstimate(
        { ...reported, estimate_availability: 'not_reported', estimate: null },
        PLACEBO,
      ),
    ).toEqual({ kind: 'absent', reason: 'not_reported', measure: 'mean_difference' })
  })

  it('et fravær uten mål sier at ingen effektstørrelse er registrert', () => {
    expect(
      describeEvidenceEstimate(
        {
          estimate_availability: 'not_measured',
          effect_measure: null,
          estimate: null,
          estimate_unit: null,
        },
        PLACEBO,
      ),
    ).toEqual({ kind: 'absent', reason: 'not_measured', measure: null })
  })

  it('enhetsregelen gjelder også når tallet mangler', () => {
    // Migrasjon 003 knytter enheten til målet, ikke til estimatet.
    expect(
      describeEvidenceEstimate(
        {
          estimate_availability: 'not_reported',
          effect_measure: 'odds_ratio',
          estimate: null,
          estimate_unit: 'kg',
        },
        PLACEBO,
      ),
    ).toMatchObject({ reason: 'unit_on_dimensionless_measure' })
  })

  it('en enhet uten mål står ikke alene, heller ikke uten tall', () => {
    expect(
      describeEvidenceEstimate(
        {
          estimate_availability: 'not_reported',
          effect_measure: null,
          estimate: null,
          estimate_unit: 'kg',
        },
        PLACEBO,
      ),
    ).toMatchObject({ reason: 'unit_on_dimensionless_measure' })
  })

  it('et tall som står der statusen sier at det ikke gjør det, vises ikke', () => {
    expect(
      describeEvidenceEstimate({ ...reported, estimate_availability: 'not_reported' }, PLACEBO),
    ).toMatchObject({ reason: 'unexpected_value' })
  })

  it('en ukjent status blir et brudd', () => {
    expect(
      describeEvidenceEstimate({ ...reported, estimate_availability: 'kanskje' }, PLACEBO),
    ).toMatchObject({ reason: 'unrecognised_availability' })
  })

  it('et ukjent mål blir et brudd, også uten tall', () => {
    expect(
      describeEvidenceEstimate(
        {
          estimate_availability: 'not_reported',
          effect_measure: 'hazard_ratio',
          estimate: null,
          estimate_unit: null,
        },
        PLACEBO,
      ),
    ).toMatchObject({ reason: 'unrecognised_measure' })
  })
})

describe('publiseringsdatoen', () => {
  it('leser datoen med presisjonen sin', () => {
    expect(describePublicationDate('2019-01-01', 'year')).toEqual({
      kind: 'dated',
      date: '2019-01-01',
      precision: 'year',
    })
  })

  it('ingen dato er ingen dato, ikke en udatert kilde med ukjent presisjon', () => {
    expect(describePublicationDate(null, null)).toEqual({ kind: 'undated' })
  })

  it('en dato uten presisjon er ikke tolkbar', () => {
    // Uten nivået vet vi ikke hvor mye av datoen som er ekte, og hele datoen
    // ville vært falsk presisjon (§6).
    expect(describePublicationDate('2019-01-01', null)).toMatchObject({
      reason: 'date_without_precision',
    })
  })

  it('en presisjon uten dato er ikke tolkbar', () => {
    expect(describePublicationDate(null, 'year')).toMatchObject({
      reason: 'precision_without_date',
    })
  })

  it('en ukjent presisjon er ikke tolkbar', () => {
    expect(describePublicationDate('2019-01-01', 'quarter')).toMatchObject({
      reason: 'unrecognised_precision',
    })
  })
})

describe('de enkle vokabularene', () => {
  it('kjenner igjen sine egne verdier', () => {
    expect(readStudyDesign('randomized_controlled_trial')).toMatchObject({ kind: 'known' })
    expect(readSourceType('clinical_guideline')).toMatchObject({ kind: 'known' })
    expect(readSourceStatus('retracted')).toMatchObject({ kind: 'known' })
  })

  it('en ukjent kildestatus faller ikke sammen med «i bruk»', () => {
    // En kilde kan trekkes tilbake etter publisering, og det skal vises (§14).
    expect(readSourceStatus('embargoed')).toEqual({ kind: 'unknown', raw: 'embargoed' })
  })

  it('et ukjent studiedesign blir ikke en randomisert studie', () => {
    expect(readStudyDesign('cohort_study')).toEqual({ kind: 'unknown', raw: 'cohort_study' })
  })

  it('en ukjent dokumenttype blir ikke en fagfellevurdert artikkel', () => {
    expect(readSourceType('preprint')).toEqual({ kind: 'unknown', raw: 'preprint' })
  })
})

describe('hele funnet', () => {
  it('avleder komparatoren mot intervensjonen, ikke mot påstandens virkestoff', () => {
    // Funnets subjekt er intervensjonen. En komparator lik intervensjonen er
    // ingen sammenligning, og migrasjon 003 forbyr paret.
    const finding = describeEvidenceFinding(
      evidenceRow({
        comparator_kind: 'drug',
        comparator_drug_id: evidenceRow().intervention_drug_id,
        comparator_drug_name: 'virkestoff a',
      }),
    )
    expect(finding.comparator).toMatchObject({ reason: 'comparator_is_subject_drug' })
  })

  it('lar estimatet arve at komparatoren ikke er tolkbar', () => {
    const finding = describeEvidenceFinding(
      evidenceRow({ comparator_kind: 'placebo', comparator_drug_name: 'virkestoff b' }),
    )
    expect(finding.comparator).toMatchObject({ reason: 'named_drug_without_drug_kind' })
    expect(finding.estimate).toMatchObject({ reason: 'comparator_not_interpretable' })
  })

  it('avleder alle aksene på en velformet rad', () => {
    const finding = describeEvidenceFinding(evidenceRow())
    expect(finding.stance).toMatchObject({ kind: 'known', relationship: 'supports' })
    expect(finding.studyDesign).toMatchObject({ kind: 'known' })
    expect(finding.population).toMatchObject({ kind: 'reported' })
    expect(finding.sampleSize).toMatchObject({ kind: 'reported', value: 240 })
    expect(finding.timepoint).toMatchObject({ kind: 'reported' })
    expect(finding.reportedDirection).toMatchObject({ kind: 'known', value: 'increase' })
    expect(finding.comparator).toEqual({ kind: 'placebo' })
    expect(finding.estimate).toMatchObject({ kind: 'quantified', value: 1.7 })
    expect(finding.confidenceInterval).toMatchObject({ kind: 'reported' })
    expect(finding.sourceType).toMatchObject({ kind: 'known' })
    expect(finding.sourceStatus).toMatchObject({ kind: 'known', value: 'active' })
    expect(finding.publicationDate).toMatchObject({ kind: 'dated', precision: 'month' })
  })
})
