import { describe, expect, it } from 'vitest'

import { parseClaimVerificationInput } from './claim-verification-input'

/** Ett minimalt, gyldig svar på formen migrasjon 005k dokumenterer. */
function payload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    agent_run_id: '11111111-1111-4111-8111-111111111111',
    verifier_actor_id: '22222222-2222-4222-8222-222222222222',
    revisions: [revision()],
    ...overrides,
  }
}

function revision(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    claim_revision_id: '33333333-3333-4333-8333-333333333333',
    claim_id: '33333333-3333-4333-8333-333333333334',
    revision_number: 1,
    knowledge_type: 'evidence_synthesis',
    created_at: '2026-09-01T00:00:00+00:00',
    created_by_actor_id: '44444444-4444-4444-8444-444444444444',
    created_by_actor_key: 'agent:claim-synthesis',
    created_by_actor_type: 'agent',
    content_hash: `sha256-v2:${'c'.repeat(64)}`,
    claim_retired_at: null,
    topic_concept_id: '55555555-5555-4555-8555-555555555555',
    topic_label: 'vektendring',
    subject_drug_id: '66666666-6666-4666-8666-666666666666',
    subject_drug_name: 'sertralin',
    evidence_set_digest: `sha256-v1:${'d'.repeat(64)}`,
    claim: {
      statement: 'Testpåstand.',
      scope: 'Testomfang.',
      population_id: null,
      population_label: null,
      timeframe_min: '182 days',
      timeframe_max: '224 days',
      comparator_kind: 'none',
      comparator_drug_id: null,
      comparator_drug_name: null,
      direction: 'increase',
      magnitude_measure: null,
      magnitude_value: null,
      magnitude_unit: null,
      qualifiers: null,
      uncertainty_summary: 'Testusikkerhet.',
    },
    links: [link()],
    unlinked_related_evidence: [],
    verifications_by_this_actor: 0,
    verifications_total: 0,
    ...overrides,
  }
}

function link(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    claim_evidence_link_id: '77777777-7777-4777-8777-777777777777',
    relationship_type: 'supports',
    directness: 'direct',
    relevance_note: 'Testbegrunnelse.',
    evidence_item: {
      evidence_item_id: '88888888-8888-4888-8888-888888888888',
      created_at: '2026-09-01T00:00:00+00:00',
      created_by_actor_id: '99999999-9999-4999-8999-999999999999',
      created_by_actor_key: 'agent:evidence-extraction',
      created_by_actor_type: 'agent',
      extraction_method: 'ai_assisted',
      content_hash: `sha256-v2:${'e'.repeat(64)}`,
      source: { source_id: '10000000-0000-4000-8000-000000000001', title: 'Testkilde' },
      source_version: {
        source_version_id: '10000000-0000-4000-8000-000000000002',
        retrieved_at: '2026-09-01T00:00:00+00:00',
        retrieved_from: 'https://eksempel.invalid/kilde',
        external_version: null,
        content_hash: `sha256:${'a'.repeat(64)}`,
        has_storage_reference: false,
      },
      extraction: {
        design_code: 'randomized_controlled_trial',
        population_label: null,
        population_availability: 'not_reported',
        population_detail: 'Testpopulasjon.',
        sample_size: null,
        sample_size_availability: 'not_reported',
        intervention_drug_name: 'sertralin',
        intervention_detail: null,
        comparator_kind: 'none',
        comparator_drug_name: null,
        comparator_detail: null,
        outcome_label: 'vektendring',
        outcome_detail: 'Testutfall.',
        timepoint_min: '182 days',
        timepoint_max: '224 days',
        timepoint_availability: 'reported_value',
        reported_direction: 'increase',
        effect_measure: 'mean_change',
        estimate: '1.50',
        estimate_unit: 'kg',
        estimate_availability: 'reported_value',
        ci_lower: null,
        ci_upper: null,
        ci_level_percent: null,
        confidence_interval_availability: 'not_reported',
        limitations_text: null,
        source_locator: 'Avsnitt 1',
        raw_extraction: { sitat: 'Et tilstrekkelig langt ordrett utdrag fra kilden.' },
      },
    },
    current_extraction_verification: {
      evidence_verification_id: '10000000-0000-4000-8000-000000000003',
      outcome: 'uncertain',
      source_access: 'verifiable_representation',
      checked_fields: ['raw_extraction', 'source_locator'],
      verified_at: '2026-09-02T00:00:00+00:00',
    },
    ...overrides,
  }
}

describe('parseClaimVerificationInput', () => {
  it('leser et fullstendig svar', () => {
    const input = parseClaimVerificationInput(payload())

    expect(input.revisions).toHaveLength(1)
    const [first] = input.revisions
    expect(first?.claim.statement).toBe('Testpåstand.')
    expect(first?.claim.timeframeMin).toBe('182 days')
    expect(first?.evidenceSetDigest).toContain('sha256-v1:')
    expect(first?.links[0]?.evidenceItem.extraction.interventionDrugName).toBe('sertralin')
    expect(first?.links[0]?.currentExtractionVerification?.outcome).toBe('uncertain')
  })

  it('leser tidspunktet på evidensfunnet, slik tidsromkontrollen trenger det', () => {
    const input = parseClaimVerificationInput(payload())

    expect(input.revisions[0]?.links[0]?.evidenceItem.extraction.timepointMin).toBe('182 days')
    expect(input.revisions[0]?.links[0]?.evidenceItem.extraction.timepointMax).toBe('224 days')
  })

  it('skiller «ingen kontroll registrert» fra «kontrollen var negativ»', () => {
    const input = parseClaimVerificationInput(
      payload({
        revisions: [revision({ links: [link({ current_extraction_verification: null })] })],
      }),
    )

    expect(input.revisions[0]?.links[0]?.currentExtractionVerification).toBeNull()
  })

  it('avviser et svar uten revisjonsliste framfor å gjette', () => {
    expect(() =>
      parseClaimVerificationInput({ agent_run_id: 'a', verifier_actor_id: 'b' }),
    ).toThrow(/revisions/)
  })

  it('avviser en revisjon som mangler avtrykket av evidenssettet', () => {
    const broken = revision()
    delete broken['evidence_set_digest']
    expect(() => parseClaimVerificationInput(payload({ revisions: [broken] }))).toThrow(
      /evidence_set_digest/,
    )
  })

  it('avviser en påstandsstørrelse som kom som tall og ikke som tekst', () => {
    // Et JSON-tall er allerede avrundet av `JSON.parse` før noen linje her
    // kjører. Kastet er det som gjør at en senere endring i api-funksjonen ikke
    // kan gjeninnføre avrundingen stille.
    expect(() =>
      parseClaimVerificationInput(
        payload({
          revisions: [
            revision({
              claim: { ...(revision()['claim'] as Record<string, unknown>), magnitude_value: 1.5 },
            }),
          ],
        }),
      ),
    ).toThrow(/serialiseres med ::text/)
  })

  it('avviser et evidensfunn som mangler ekstraksjonen', () => {
    const brokenLink = link()
    const item = brokenLink['evidence_item'] as Record<string, unknown>
    delete item['extraction']
    expect(() =>
      parseClaimVerificationInput(payload({ revisions: [revision({ links: [brokenLink] })] })),
    ).toThrow(/extraction/)
  })

  it('leser en kandidat for urepresentert evidens', () => {
    const input = parseClaimVerificationInput(
      payload({
        revisions: [
          revision({
            unlinked_related_evidence: [
              {
                evidence_item_id: '10000000-0000-4000-8000-000000000004',
                source_title: 'Ulenket studie',
                source_status: 'active',
                intervention_drug_name: 'sertralin',
                outcome_label: 'vektendring',
                reported_direction: 'decrease',
                effect_measure: null,
                estimate: null,
                estimate_unit: null,
                created_by_actor_key: 'agent:evidence-extraction',
              },
            ],
          }),
        ],
      }),
    )

    expect(input.revisions[0]?.unlinkedRelatedEvidence).toHaveLength(1)
    expect(input.revisions[0]?.unlinkedRelatedEvidence[0]?.sourceTitle).toBe('Ulenket studie')
  })
})
