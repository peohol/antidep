import { describe, expect, it } from 'vitest'
import {
  parseExtractionQueue,
  parseExtractionReviewWorkspace,
  uncoveredCheckFields,
} from './extraction-review'

/**
 * Svaret slik `api.extraction_review_workspace(uuid)` faktisk gir det, med
 * snake_case-nøklene fra migrasjon 005t. Fiksturen bygges her og ikke i
 * `app/test-support.tsx`, fordi denne filen prøver leseren og ikke visningen: en
 * nøkkel som fjernes, skal bli en feil her først.
 */
function itemPayload(): Record<string, unknown> {
  return {
    evidence_item_id: '66666666-6666-4666-8666-111111111111',
    created_at: '2026-08-30T08:00:00Z',
    created_by_actor_id: '99999999-9999-4999-8999-111111111111',
    created_by_actor_key: 'agent:evidence-extraction',
    created_by_actor_type: 'agent',
    extraction_method: 'ai_assisted',
    content_hash: `sha256-v2:${'e'.repeat(64)}`,
    source: {
      source_id: '88888888-8888-4888-8888-111111111111',
      source_type: 'journal_article',
      title: 'Testkilde',
      authors_or_issuer: 'Testforfatter',
      publisher_or_journal: null,
      publication_date: null,
      publication_date_precision: null,
      source_status: 'active',
      status_note: null,
    },
    source_version: {
      source_version_id: '88888888-8888-4888-8888-222222222222',
      retrieved_at: '2026-09-01T09:00:00Z',
      retrieved_from: 'https://eksempel.invalid/kilde',
      external_version: null,
      content_hash: `sha256:${'a'.repeat(64)}`,
      has_storage_reference: false,
    },
    extraction: {
      design_code: 'randomized_controlled_trial',
      population_id: null,
      population_label: null,
      population_availability: 'not_reported',
      population_detail: 'Ikke oppgitt.',
      sample_size: null,
      sample_size_availability: 'not_reported',
      intervention_drug_id: '11111111-1111-4111-8111-111111111111',
      intervention_drug_name: 'virkestoff a',
      intervention_detail: null,
      comparator_kind: 'none',
      comparator_drug_id: null,
      comparator_drug_name: null,
      comparator_detail: null,
      outcome_concept_id: '22222222-2222-4222-8222-222222222222',
      outcome_label: 'vektendring',
      outcome_detail: 'Endring i kroppsvekt.',
      timepoint_min: null,
      timepoint_max: null,
      timepoint_availability: 'not_reported',
      reported_direction: 'increase',
      effect_measure: null,
      estimate: null,
      estimate_unit: null,
      estimate_availability: 'not_reported',
      ci_lower: null,
      ci_upper: null,
      ci_level_percent: null,
      confidence_interval_availability: 'not_reported',
      limitations_text: null,
      source_locator: 'Avsnitt 1',
      raw_extraction: { sitat: 'Ordrett utdrag.' },
    },
    extraction_digest: `sha256-v1:${'b'.repeat(64)}`,
    required_check_fields: ['source_locator', 'raw_extraction', 'outcome'],
    covered_check_fields: ['source_locator'],
    current_extraction_verification_id: '77777777-7777-4777-8777-111111111111',
    extraction_verifications: [
      {
        evidence_verification_id: '77777777-7777-4777-8777-111111111111',
        outcome: 'uncertain',
        source_access: 'verifiable_representation',
        checked_fields: ['source_locator'],
        findings: 'Fant ikke utdraget for endepunktet.',
        rationale: 'Deterministisk kontroll.',
        verified_at: '2026-09-02T10:00:00Z',
        created_at: '2026-09-02T10:00:00Z',
        verifier_actor_id: '00000000-0000-4000-8000-111111111111',
        verifier_actor_key: 'agent:extraction-verification',
        verifier_actor_type: 'agent',
        verifier_display_name: 'Ekstraksjonsverifikator',
        agent_run_id: '11111111-1111-4111-8111-111111111111',
      },
    ],
    linked_claim_revisions: [
      {
        claim_revision_id: '33333333-3333-4333-8333-111111111111',
        claim_id: '22222222-2222-4222-8222-111111111111',
        revision_number: 2,
        statement: 'Testpåstand.',
        subject_drug_name: 'virkestoff a',
        topic_label: 'vektendring',
        relationship_type: 'supports',
        is_published_revision: false,
      },
    ],
  }
}

function payload(): Record<string, unknown> {
  return { reviewer_actor_id: '00000000-0000-4000-8000-999999999999', item: itemPayload() }
}

describe('parseExtractionReviewWorkspace', () => {
  it('leser grunnlaget med den samme leseren agenten bruker', () => {
    const workspace = parseExtractionReviewWorkspace(payload())
    expect(workspace.item.dossier.sourceTitle).toBe('Testkilde')
    expect(workspace.item.dossier.extraction.sourceLocator).toBe('Avsnitt 1')
    expect(workspace.item.dossier.extraction.rawExtraction).toEqual({ sitat: 'Ordrett utdrag.' })
    expect(workspace.item.dossier.extractionMethod).toBe('ai_assisted')
  })

  it('leser avtrykket, feltdekningen, historikken og påstandene funnet bærer', () => {
    const workspace = parseExtractionReviewWorkspace(payload())
    expect(workspace.item.extractionDigest).toBe(`sha256-v1:${'b'.repeat(64)}`)
    expect(workspace.item.requiredCheckFields).toEqual([
      'source_locator',
      'raw_extraction',
      'outcome',
    ])
    expect(workspace.item.coveredCheckFields).toEqual(['source_locator'])
    expect(workspace.item.extractionVerifications).toHaveLength(1)
    expect(workspace.item.extractionVerifications[0]?.checkedFields).toEqual(['source_locator'])
    expect(workspace.item.linkedClaimRevisions[0]?.relationshipType).toBe('supports')
  })

  // Fravær er ikke et negativt svar: `null` betyr at ingen kontroll er
  // registrert, og leseren skal bevare forskjellen.
  it('leser en manglende gjeldende kontroll som fravær, ikke som en verdi', () => {
    const broken = payload() as { item: Record<string, unknown> }
    broken.item['current_extraction_verification_id'] = null
    const workspace = parseExtractionReviewWorkspace(broken)
    expect(workspace.item.currentExtractionVerificationId).toBeNull()
  })

  it('avviser et svar uten avtrykk framfor å sende en tom streng videre', () => {
    const broken = payload() as { item: Record<string, unknown> }
    delete broken.item['extraction_digest']
    expect(() => parseExtractionReviewWorkspace(broken)).toThrow(/extraction_digest/)
  })

  it('avviser et svar der feltdekningen mangler', () => {
    const broken = payload() as { item: Record<string, unknown> }
    delete broken.item['covered_check_fields']
    expect(() => parseExtractionReviewWorkspace(broken)).toThrow(/covered_check_fields/)
  })

  it('avviser et svar der kontrollhistorikken mangler', () => {
    const broken = payload() as { item: Record<string, unknown> }
    delete broken.item['extraction_verifications']
    expect(() => parseExtractionReviewWorkspace(broken)).toThrow(/extraction_verifications/)
  })
})

describe('parseExtractionQueue', () => {
  function queueItem(): Record<string, unknown> {
    return {
      evidence_item_id: '66666666-6666-4666-8666-111111111111',
      created_at: '2026-08-30T08:00:00Z',
      created_by_actor_id: '99999999-9999-4999-8999-111111111111',
      created_by_actor_key: 'agent:evidence-extraction',
      source_id: '88888888-8888-4888-8888-111111111111',
      source_title: 'Testkilde',
      source_status: 'active',
      intervention_drug_name: 'virkestoff a',
      outcome_label: 'vektendring',
      outcome_concept_id: '22222222-2222-4222-8222-222222222222',
      current_extraction_verification_outcome: null,
      verification_count: 0,
      required_check_fields: ['source_locator', 'outcome'],
      covered_check_fields: [],
      linked_claim_revision_count: 2,
    }
  }

  it('leser en kørad med status og feltdekning', () => {
    const queue = parseExtractionQueue({
      reviewer_actor_id: '00000000-0000-4000-8000-999999999999',
      queue: [queueItem()],
    })
    expect(queue.items).toHaveLength(1)
    expect(queue.items[0]?.currentExtractionVerificationOutcome).toBeNull()
    expect(queue.items[0]?.requiredCheckFields).toEqual(['source_locator', 'outcome'])
    expect(queue.items[0]?.linkedClaimRevisionCount).toBe(2)
  })

  it('avviser et svar der køen mangler', () => {
    expect(() =>
      parseExtractionQueue({ reviewer_actor_id: '00000000-0000-4000-8000-999999999999' }),
    ).toThrow(/queue/)
  })
})

describe('uncoveredCheckFields', () => {
  it('gir feltene som står igjen, i den rekkefølgen kravet lister dem', () => {
    expect(
      uncoveredCheckFields({
        requiredCheckFields: ['source_locator', 'outcome', 'estimate'],
        coveredCheckFields: ['outcome'],
      }),
    ).toEqual(['source_locator', 'estimate'])
  })

  it('gir en tom liste når dekningen er komplett', () => {
    expect(
      uncoveredCheckFields({
        requiredCheckFields: ['source_locator'],
        coveredCheckFields: ['source_locator', 'estimate'],
      }),
    ).toEqual([])
  })

  // En dekning som er tom, er ikke det samme som at ingenting kreves: alle
  // kravene står da igjen.
  it('lar alt stå igjen når ingenting er dekket', () => {
    expect(
      uncoveredCheckFields({
        requiredCheckFields: ['source_locator', 'outcome'],
        coveredCheckFields: [],
      }),
    ).toEqual(['source_locator', 'outcome'])
  })
})
