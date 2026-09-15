// ============================================================================
// Ett kandidatsvar, i den formen `api.candidate_for_control` faktisk svarer i
//
// Både lesingen og flaten prøves mot det samme svaret, og det er med vilje: to
// håndholdte kopier ville drevet fra hverandre, og da ville den ene prøven
// bekreftet en form den andre ikke lenger leste. Formen her følger
// `knowledge.candidate_content` (migrasjon 009d) felt for felt, inkludert de
// feltene `jsonb_strip_nulls` fjerner når de er tomme.
//
// Innholdet er syntetisk og sier ingenting klinisk. Det er en form, ikke en
// påstand om et legemiddel.
// ============================================================================

export const FIXTURE_CANDIDATE_ID = '11111111-1111-4111-8111-111111111111'
export const FIXTURE_CANDIDATE_DIGEST = `sha256:${'a'.repeat(64)}`
export const FIXTURE_EVIDENCE_SET_DIGEST = `sha256-v1:${'b'.repeat(64)}`
export const FIXTURE_STATEMENT = 'Sertralin er forbundet med en liten vektøkning ved langtidsbruk.'

/** Det forseglede innholdet. `overrides` erstatter felter på øverste nivå. */
export function candidateContent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    claim_revision: {
      claim_revision_id: '22222222-2222-4222-8222-222222222222',
      revision_number: 1,
      knowledge_type: 'evidence_synthesis',
      statement: FIXTURE_STATEMENT,
      scope: 'Voksne i allmennpraksis.',
      subject_drug: 'sertralin',
      topic: 'vektendring',
      population: 'voksne med depressiv lidelse',
      direction: 'increase',
      uncertainty_summary: 'Grunnlaget er begrenset til én studie.',
      qualifiers: null,
    },
    evidence_assessment: {
      framework: 'grade',
      certainty_level: 'low',
      risk_of_bias: 'serious',
      inconsistency: 'not_assessable',
      indirectness: 'not_serious',
      imprecision: 'very_serious',
      publication_bias: 'not_assessable',
      other_considerations: 'Ingen dose-respons-sammenheng kunne vurderes.',
      rationale: 'Én studie, alvorlig upresishet.',
      evidence_gap: 'Ingen langtidsdata utover 32 uker.',
    },
    citation_support_check: {
      outcome: 'needs_correction',
      source_access: 'verifiable_representation',
      source_support: 'ok',
      population_match: 'ok',
      comparator_match: 'not_assessable',
      timeframe_match: 'ok',
      direction_and_magnitude: 'ok',
      qualifiers_complete: 'deviation',
      contradictory_evidence_represented: 'not_assessable',
      rationale: 'Komparatoren lot seg ikke bedømme mot den ene kilden.',
      findings: 'Forbeholdet om langtidsbruk mangler i formuleringen.',
      verified_evidence_set_digest: FIXTURE_EVIDENCE_SET_DIGEST,
    },
    evidence: [
      {
        evidence_item_id: '33333333-3333-4333-8333-333333333333',
        relationship_type: 'supports',
        directness: 'direct',
        design_code: 'randomized_controlled_trial',
        outcome: 'vektendring',
        outcome_detail: 'Gjennomsnittlig prosentvis vektendring ved endepunkt.',
        reported_direction: 'increase',
        sample_size: 220,
        sample_size_availability: 'reported_value',
        estimate: '1.0',
        estimate_unit: 'percent',
        estimate_availability: 'reported_value',
        effect_measure: 'mean_change',
        ci_lower: '0.4',
        ci_upper: '1.6',
        ci_level_percent: '95',
        confidence_interval_availability: 'reported_value',
        limitations_text: 'Åpen oppfølging etter uke 24.',
        source_locator: 'RESULTS, Table 1',
        source: { title: 'Syntetisk artikkel om vektendring' },
        coverage: {
          required_check_fields: ['outcome', 'estimate', 'timepoint'],
          covered_check_fields: ['outcome', 'estimate'],
          grounded_check_fields: ['outcome', 'estimate'],
          grounding_machine_proved: false,
        },
        field_groundings: [
          {
            check_field: 'estimate',
            source_excerpt: 'Mean percent weight change was 1.0% at endpoint.',
            source_locator: 'RESULTS',
          },
        ],
        extraction_check: { outcome: 'verified' },
      },
    ],
    source_coverage: [
      {
        source_id: '44444444-4444-4444-8444-444444444444',
        title: 'Syntetisk artikkel om vektendring',
        evidence_item_count: 1,
        full_text_in_library: true,
        readability_checked: true,
        grounding_machine_proved: false,
      },
    ],
    evidence_set_digest: FIXTURE_EVIDENCE_SET_DIGEST,
    ...overrides,
  }
}

/** Hele svaret. `overrides` erstatter felter på øverste nivå. */
export function candidateResponse(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    candidate_id: FIXTURE_CANDIDATE_ID,
    claim_revision_id: '22222222-2222-4222-8222-222222222222',
    candidate_digest: FIXTURE_CANDIDATE_DIGEST,
    evidence_set_digest: FIXTURE_EVIDENCE_SET_DIGEST,
    built_at: '2026-09-26T09:00:00+00:00',
    is_current: true,
    current_digest: FIXTURE_CANDIDATE_DIGEST,
    experimental: true,
    published: false,
    content: candidateContent(),
    final_controls: [],
    ...overrides,
  }
}
