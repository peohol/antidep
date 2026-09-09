import { describe, expect, it } from 'vitest'
import { createEvidenceItem } from './create-evidence-item'
import type { AntidepClient } from './supabase'
import type { CreateEvidenceItemInput } from './create-evidence-item'

interface RecordedCall {
  name: string
  args: unknown
}

function fakeClient(outcome: { data: unknown; error: { message: string } | null }) {
  const calls: RecordedCall[] = []
  const client = {
    rpc(name: string, args: unknown) {
      calls.push({ name, args })
      return Promise.resolve(outcome)
    },
  }
  return { client: client as unknown as AntidepClient, calls }
}

const SOURCE = '88888888-8888-4888-8888-111111111111'
const DRUG = '11111111-1111-4111-8111-111111111111'
const OUTCOME = '44444444-4444-4444-8444-111111111111'

/** Det minste gyldige funnet: alt klinisk innhold er registrert som fraværende. */
const MINIMAL_INPUT: CreateEvidenceItemInput = {
  sourceId: SOURCE,
  sourceVersionId: null,
  designCode: 'randomized_controlled_trial',
  populationId: null,
  populationAvailability: 'not_reported',
  populationDetail: 'Populasjonen er ikke beskrevet i kilden.',
  sampleSize: null,
  sampleSizeAvailability: 'not_reported',
  interventionDrugId: DRUG,
  interventionDetail: null,
  comparatorKind: 'none',
  comparatorDrugId: null,
  comparatorDetail: null,
  outcomeConceptId: OUTCOME,
  outcomeDetail: 'Vektendring, ikke tallfestet.',
  timepointMin: null,
  timepointMax: null,
  timepointAvailability: 'not_reported',
  reportedDirection: 'not_stated',
  effectMeasure: null,
  estimate: null,
  estimateUnit: null,
  estimateAvailability: 'not_reported',
  ciLower: null,
  ciUpper: null,
  ciLevelPercent: null,
  confidenceIntervalAvailability: 'not_reported',
  limitationsText: null,
  sourceLocator: 'Avsnitt 1',
  sourceQuote: null,
}

describe('createEvidenceItem', () => {
  it('kaller api.create_evidence_item med feltene oversatt til p_-parametrene', async () => {
    const evidenceItemId = '66666666-6666-4666-8666-999999999999'
    const { client, calls } = fakeClient({ data: evidenceItemId, error: null })

    const result = await createEvidenceItem(client, {
      ...MINIMAL_INPUT,
      sourceVersionId: '88888888-8888-4888-8888-222222222222',
      populationId: '77777777-7777-4777-8777-111111111111',
      populationAvailability: 'reported_value',
      sampleSize: '240',
      sampleSizeAvailability: 'reported_value',
      interventionDetail: '50 mg daglig',
      comparatorKind: 'drug',
      comparatorDrugId: '11111111-1111-4111-8111-222222222222',
      comparatorDetail: '30 mg daglig',
      timepointMin: '8 weeks',
      timepointMax: '12 weeks',
      timepointAvailability: 'reported_value',
      reportedDirection: 'increase',
      effectMeasure: 'mean_difference',
      estimate: '1.7',
      estimateUnit: 'kg',
      estimateAvailability: 'reported_value',
      ciLower: '0.9',
      ciUpper: '2.5',
      ciLevelPercent: '95',
      confidenceIntervalAvailability: 'reported_value',
      limitationsText: 'Åpen etikett i den ene armen.',
      sourceQuote: 'Mean difference 1.7 kg.',
    })

    expect(result).toEqual({ status: 'ok', evidenceItemId })
    expect(calls).toEqual([
      {
        name: 'create_evidence_item',
        args: {
          p_source_id: SOURCE,
          p_source_version_id: '88888888-8888-4888-8888-222222222222',
          p_design_code: 'randomized_controlled_trial',
          p_population_id: '77777777-7777-4777-8777-111111111111',
          p_population_availability: 'reported_value',
          p_population_detail: 'Populasjonen er ikke beskrevet i kilden.',
          p_sample_size: '240',
          p_sample_size_availability: 'reported_value',
          p_intervention_drug_id: DRUG,
          p_intervention_detail: '50 mg daglig',
          p_comparator_kind: 'drug',
          p_comparator_drug_id: '11111111-1111-4111-8111-222222222222',
          p_comparator_detail: '30 mg daglig',
          p_outcome_concept_id: OUTCOME,
          p_outcome_detail: 'Vektendring, ikke tallfestet.',
          p_timepoint_min: '8 weeks',
          p_timepoint_max: '12 weeks',
          p_timepoint_availability: 'reported_value',
          p_reported_direction: 'increase',
          p_effect_measure: 'mean_difference',
          p_estimate: '1.7',
          p_estimate_unit: 'kg',
          p_estimate_availability: 'reported_value',
          p_ci_lower: '0.9',
          p_ci_upper: '2.5',
          p_ci_level_percent: '95',
          p_confidence_interval_availability: 'reported_value',
          p_limitations_text: 'Åpen etikett i den ene armen.',
          p_source_locator: 'Avsnitt 1',
          p_source_quote: 'Mean difference 1.7 kg.',
        },
      },
    ])
  })

  it('sender tallene som tekst, slik at et eksakt desimaltall når fram uendret', async () => {
    // Et JS-tall er en IEEE-754 double: Number('0.12345678901234567') er
    // 0.12345678901234566, og en avrundet verdi ville blitt lagret og hashet som
    // noe annet enn det kilden oppgir. PostgreSQL sin numeric er vilkårlig
    // presis, og PostgREST caster en JSON-streng til den.
    const exact = '0.12345678901234567'
    const { client, calls } = fakeClient({ data: 'id', error: null })

    await createEvidenceItem(client, {
      ...MINIMAL_INPUT,
      estimateAvailability: 'reported_value',
      effectMeasure: 'mean_difference',
      estimateUnit: 'kg',
      estimate: exact,
    })

    const args = calls[0]?.args as Record<string, unknown>
    expect(args['p_estimate']).toBe(exact)
    expect(typeof args['p_estimate']).toBe('string')
    expect(Number(exact).toString()).not.toBe(exact)
  })

  it('sender ingen ekstraksjonsmetode, ingen hash og ingen aktør', async () => {
    // De tre eies av databasen, ikke av kalleren (migrasjon 007e). Et kall som
    // begynte å sende dem ville flyttet en påstand om radens opphav ut i
    // klienten.
    const { client, calls } = fakeClient({ data: 'id', error: null })

    await createEvidenceItem(client, MINIMAL_INPUT)

    const args = calls[0]?.args as Record<string, unknown>
    expect(Object.keys(args)).not.toContain('p_extraction_method')
    expect(Object.keys(args)).not.toContain('p_content_hash')
    expect(Object.keys(args)).not.toContain('p_created_by_actor_id')
  })

  it('sender null for valgfrie felter som ikke er utfylt, ikke tomstreng', async () => {
    const { client, calls } = fakeClient({ data: 'id', error: null })

    await createEvidenceItem(client, MINIMAL_INPUT)

    const args = calls[0]?.args as Record<string, unknown>
    for (const key of [
      'p_source_version_id',
      'p_population_id',
      'p_sample_size',
      'p_intervention_detail',
      'p_comparator_drug_id',
      'p_comparator_detail',
      'p_timepoint_min',
      'p_timepoint_max',
      'p_effect_measure',
      'p_estimate',
      'p_estimate_unit',
      'p_ci_lower',
      'p_ci_upper',
      'p_ci_level_percent',
      'p_limitations_text',
      'p_source_quote',
    ]) {
      expect(args[key], key).toBeNull()
    }
  })

  it('sender fortsatt hver *_availability, også når verdien er null', async () => {
    // Det er hele poenget med kolonnene: et fravær sier hvorfor
    // (ANTIDEP_CONSTITUTION.md §6).
    const { client, calls } = fakeClient({ data: 'id', error: null })

    await createEvidenceItem(client, MINIMAL_INPUT)

    const args = calls[0]?.args as Record<string, unknown>
    expect(args['p_population_availability']).toBe('not_reported')
    expect(args['p_sample_size_availability']).toBe('not_reported')
    expect(args['p_timepoint_availability']).toBe('not_reported')
    expect(args['p_estimate_availability']).toBe('not_reported')
    expect(args['p_confidence_interval_availability']).toBe('not_reported')
  })

  it('en avvisning fra databasen kommer tilbake som error, ikke som et kastet unntak', async () => {
    const { client } = fakeClient({
      data: null,
      error: { message: 'Brukeren har ikke gyldig editor-rolle for dette innholdsområdet.' },
    })

    const result = await createEvidenceItem(client, MINIMAL_INPUT)

    expect(result).toEqual({
      status: 'error',
      message: 'Brukeren har ikke gyldig editor-rolle for dette innholdsområdet.',
    })
  })

  it('dubletten kommer tilbake med databasens egen setning', async () => {
    const { client } = fakeClient({
      data: null,
      error: { message: 'Nøyaktig det samme evidensfunnet er allerede registrert.' },
    })

    const result = await createEvidenceItem(client, MINIMAL_INPUT)

    expect(result).toEqual({
      status: 'error',
      message: 'Nøyaktig det samme evidensfunnet er allerede registrert.',
    })
  })
})
