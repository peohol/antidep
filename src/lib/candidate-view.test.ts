import { describe, expect, it } from 'vitest'

import {
  canBeFinalControlled,
  coverageRatio,
  parseCandidateView,
  uncoveredCheckFields,
} from './candidate-view.ts'

const DIGEST = `sha256:${'a'.repeat(64)}`

function svar(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    candidate_id: '11111111-1111-4111-8111-111111111111',
    claim_revision_id: '22222222-2222-4222-8222-222222222222',
    candidate_digest: DIGEST,
    evidence_set_digest: `sha256-v1:${'b'.repeat(64)}`,
    built_at: '2026-09-26T09:00:00+00:00',
    is_current: true,
    current_digest: DIGEST,
    experimental: true,
    published: false,
    content: {
      claim_revision: {
        statement: 'Sertralin er forbundet med en liten vektøkning ved langtidsbruk.',
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
        rationale: 'Én studie, alvorlig upresishet.',
        evidence_gap: 'Ingen langtidsdata utover 32 uker.',
      },
      evidence: [
        {
          evidence_item_id: '33333333-3333-4333-8333-333333333333',
          relationship_type: 'supports',
          directness: 'direct',
          outcome: 'vektendring',
          outcome_detail: 'Gjennomsnittlig prosentvis vektendring ved endepunkt.',
          reported_direction: 'increase',
          estimate: '1.0',
          estimate_unit: 'percent',
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
    },
    final_controls: [],
    ...overrides,
  }
}

describe('parseCandidateView', () => {
  it('leser kandidaten med påstand, vurdering, evidens og kildedekning', () => {
    const view = parseCandidateView(svar())
    expect(view.claim.subjectDrug).toBe('sertralin')
    expect(view.assessment?.certaintyLevel).toBe('low')
    expect(view.evidence).toHaveLength(1)
    expect(view.sourceCoverage[0]?.fullTextInLibrary).toBe(true)
    expect(view.published).toBe(false)
    expect(view.experimental).toBe(true)
  })

  // ANTIDEP_CONSTITUTION.md regel 4: fravær og tomhet er ikke det samme.
  it('leser en manglende evidensvurdering som fravær, ikke som en tom vurdering', () => {
    const view = parseCandidateView(
      svar({ content: { ...(svar()['content'] as object), evidence_assessment: null } }),
    )
    expect(view.assessment).toBeNull()
  })

  it('avviser et svar uten kontraktens form framfor å tegne en tom rute', () => {
    expect(() => parseCandidateView(svar({ is_current: 'ja' }))).toThrow(/is_current/)
    expect(() => parseCandidateView({})).toThrow(/content/)
  })
})

describe('kildedekningen', () => {
  it('sier hvor mange av kontrollfeltene som faktisk er dekket', () => {
    const view = parseCandidateView(svar())
    const evidence = view.evidence[0]
    expect(evidence).toBeDefined()
    if (evidence === undefined) return
    expect(coverageRatio(evidence)).toEqual({ covered: 2, required: 3 })
  })

  // Et ukontrollert felt er ikke det samme som et kontrollert felt uten avvik.
  // Vises bare det andre, ser det første ut som det.
  it('navngir feltene som ingen kontroll dekker', () => {
    const view = parseCandidateView(svar())
    const evidence = view.evidence[0]
    expect(evidence).toBeDefined()
    if (evidence === undefined) return
    expect(uncoveredCheckFields(evidence)).toEqual(['timepoint'])
  })
})

describe('canBeFinalControlled', () => {
  it('lar en gjeldende kandidat sluttkontrolleres', () => {
    expect(canBeFinalControlled(parseCandidateView(svar()))).toBe(true)
  })

  it('stopper en kandidat hvis grunnlag er endret siden forseglingen', () => {
    const view = parseCandidateView(
      svar({ is_current: false, current_digest: `sha256:${'c'.repeat(64)}` }),
    )
    expect(canBeFinalControlled(view)).toBe(false)
  })
})
