// @vitest-environment node
import { describe, expect, it } from 'vitest'

import { parseClaimReviewWorkspace, parseReviewQueue } from './review-workspace'

// Svaret slik det faktisk kommer: api-funksjonen returnerer jsonb, PostgREST
// sender det som JSON-tekst, og `JSON.parse` er det første som rører det. Samme
// begrunnelse som i `agents/verification-input.test.ts`: å bygge objektet for
// hånd ville hoppet over leddet der en `numeric` mister presisjon.
function fromApi(payload: unknown): unknown {
  return JSON.parse(JSON.stringify(payload))
}

const DIGEST = `sha256-v1:${'d'.repeat(64)}`

function link(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    claim_evidence_link_id: '55555555-5555-4555-8555-111111111111',
    relationship_type: 'supports',
    directness: 'direct',
    relevance_note: 'Testnotat.',
    evidence_item: {
      evidence_item_id: '66666666-6666-4666-8666-111111111111',
      created_by_actor_key: 'agent:evidence-extraction',
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
      source_version: null,
      extraction: {
        design_code: 'randomized_controlled_trial',
        population_label: null,
        population_availability: 'not_reported',
        population_detail: 'Testpopulasjon.',
        sample_size: null,
        sample_size_availability: 'not_reported',
        intervention_drug_name: 'virkestoff a',
        intervention_detail: null,
        comparator_kind: 'none',
        comparator_drug_name: null,
        comparator_detail: null,
        outcome_label: 'vektendring',
        outcome_detail: 'Testendepunkt.',
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
        raw_extraction: null,
      },
    },
    current_extraction_verification: null,
    ...overrides,
  }
}

function revision(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    claim_revision_id: '33333333-3333-4333-8333-111111111111',
    claim_id: '22222222-2222-4222-8222-111111111111',
    revision_number: 1,
    knowledge_type: 'evidence_synthesis',
    created_by_actor_id: '00000000-0000-4000-8000-111111111111',
    created_by_actor_key: 'agent:claim-synthesis',
    content_hash: `sha256-v2:${'c'.repeat(64)}`,
    claim_retired_at: null,
    topic_concept_id: '44444444-4444-4444-8444-111111111111',
    topic_label: 'vektendring',
    subject_drug_id: '11111111-1111-4111-8111-111111111111',
    subject_drug_name: 'virkestoff a',
    evidence_set_digest: DIGEST,
    claim: {
      statement: 'Testpåstand.',
      scope: 'Testomfang.',
      population_id: null,
      population_label: null,
      timeframe_min: null,
      timeframe_max: null,
      comparator_kind: 'none',
      comparator_drug_id: null,
      comparator_drug_name: null,
      direction: 'increase',
      magnitude_measure: null,
      magnitude_value: null,
      magnitude_unit: null,
      qualifiers: null,
      uncertainty_summary: null,
    },
    links: [link()],
    unlinked_related_evidence: [],
    current_claim_verification_id: null,
    claim_verifications: [],
    current_review_decision_id: null,
    review_decisions: [],
    evidence_assessment: null,
    is_published_revision: false,
    publication_gate: { status: 'passes' },
    ...overrides,
  }
}

function payload(overrides: Record<string, unknown> = {}): unknown {
  return fromApi({
    reviewer_actor_id: '00000000-0000-4000-8000-222222222222',
    revision: revision(overrides),
  })
}

describe('parseReviewQueue', () => {
  it('leser en kørad med tellingen og publiseringstilstanden', () => {
    const parsed = parseReviewQueue(
      fromApi({
        reviewer_actor_id: '00000000-0000-4000-8000-222222222222',
        queue: [
          {
            claim_revision_id: '33333333-3333-4333-8333-111111111111',
            claim_id: '22222222-2222-4222-8222-111111111111',
            revision_number: 2,
            knowledge_type: 'evidence_synthesis',
            created_by_actor_key: 'agent:claim-synthesis',
            statement: 'Testpåstand.',
            subject_drug_name: 'virkestoff a',
            topic_label: 'vektendring',
            evidence_link_count: 3,
            is_published_revision: false,
            current_claim_verification_outcome: null,
            current_publication_decision: null,
          },
        ],
      }),
    )
    expect(parsed.items).toHaveLength(1)
    expect(parsed.items[0]?.evidenceLinkCount).toBe(3)
    expect(parsed.items[0]?.isPublishedRevision).toBe(false)
    expect(parsed.items[0]?.currentClaimVerificationOutcome).toBeNull()
  })

  it('avviser et svar uten køen framfor å lese det som en tom kø', () => {
    expect(() =>
      parseReviewQueue(fromApi({ reviewer_actor_id: '00000000-0000-4000-8000-222222222222' })),
    ).toThrow(/queue/)
  })
})

describe('parseClaimReviewWorkspace', () => {
  it('leser grunnlaget med den samme leseren agenten bruker', () => {
    const parsed = parseClaimReviewWorkspace(payload())
    expect(parsed.revision.dossier.evidenceSetDigest).toBe(DIGEST)
    expect(parsed.revision.dossier.links).toHaveLength(1)
    expect(parsed.revision.dossier.links[0]?.evidenceItem.sourceStatus).toBe('active')
  })

  it('leser publiseringsgaten som bestått bare når gaten selv sier det', () => {
    expect(parseClaimReviewWorkspace(payload()).revision.publicationGate).toEqual({
      status: 'passes',
    })
  })

  it('leser en blokkering med gatens egen setning, hint og SQLSTATE', () => {
    const parsed = parseClaimReviewWorkspace(
      payload({
        publication_gate: {
          status: 'blocked',
          sqlstate: '23001',
          message: 'Revisjonen har ingen registrert claim-verifikasjon.',
          hint: 'Registrer kontrollen først.',
        },
      }),
    )
    expect(parsed.revision.publicationGate).toEqual({
      status: 'blocked',
      sqlstate: '23001',
      message: 'Revisjonen har ingen registrert claim-verifikasjon.',
      hint: 'Registrer kontrollen først.',
    })
  })

  it('avviser en ukjent gatetilstand framfor å lese den som klar til publisering', () => {
    // Den farligste retningen å ta feil i: en tilstand klienten ikke kjenner,
    // må aldri kunne falle sammen med «gaten passerer».
    expect(() =>
      parseClaimReviewWorkspace(payload({ publication_gate: { status: 'kanskje' } })),
    ).toThrow(/ukjent tilstand for publiseringsgaten/)
  })

  it('leser «ingen registrert kontroll» som fravær, ikke som et negativt utfall', () => {
    const parsed = parseClaimReviewWorkspace(payload())
    expect(parsed.revision.currentClaimVerificationId).toBeNull()
    expect(parsed.revision.claimVerifications).toEqual([])
    expect(parsed.revision.evidenceAssessment).toBeNull()
  })

  it('leser en registrert kontroll med alle sju punktene og kontrollradene', () => {
    const parsed = parseClaimReviewWorkspace(
      payload({
        current_claim_verification_id: '99999999-9999-4999-8999-111111111111',
        claim_verifications: [
          {
            claim_verification_id: '99999999-9999-4999-8999-111111111111',
            outcome: 'uncertain',
            source_access: 'verifiable_representation',
            verified_at: '2026-09-03T10:00:00+00:00',
            verifier_actor_id: '00000000-0000-4000-8000-333333333333',
            verifier_actor_key: 'agent:citation-support-verification',
            verifier_actor_type: 'agent',
            verifier_display_name: 'Claim-verifikator',
            agent_run_id: '77777777-7777-4777-8777-111111111111',
            verified_evidence_set_digest: DIGEST,
            checks: {
              source_support: 'not_assessable',
              population_match: 'ok',
              comparator_match: 'ok',
              timeframe_match: 'ok',
              direction_and_magnitude: 'ok',
              qualifiers_complete: 'not_assessable',
              contradictory_evidence_represented: 'not_assessable',
            },
            findings: 'Ordlyden krever språkforståelse.',
            rationale: 'Deterministisk kontroll uten avvik.',
            citations: [
              {
                claim_evidence_link_id: '55555555-5555-4555-8555-111111111111',
                evidence_item_id: '66666666-6666-4666-8666-111111111111',
                source_access: 'verifiable_representation',
                source_version_id: '88888888-8888-4888-8888-222222222222',
                checked_content_hash: `sha256:${'a'.repeat(64)}`,
                relationship_supported: 'not_assessable',
                finding: 'Lot seg ikke bedømme.',
              },
            ],
          },
        ],
      }),
    )
    const record = parsed.revision.claimVerifications[0]
    expect(record?.checks.contradictoryEvidenceRepresented).toBe('not_assessable')
    expect(record?.citations).toHaveLength(1)
    expect(record?.agentRunId).toBe('77777777-7777-4777-8777-111111111111')
  })

  it('leser en menneskelig kontroll som en uten agentkjøring', () => {
    const parsed = parseClaimReviewWorkspace(
      payload({
        claim_verifications: [
          {
            claim_verification_id: '99999999-9999-4999-8999-222222222222',
            outcome: 'verified',
            source_access: 'original_source',
            verified_at: '2026-09-05T10:00:00+00:00',
            verifier_actor_id: '00000000-0000-4000-8000-444444444444',
            verifier_actor_key: 'human:testreviewer',
            verifier_actor_type: 'human',
            verifier_display_name: 'Test Reviewer',
            agent_run_id: null,
            verified_evidence_set_digest: DIGEST,
            checks: {
              source_support: 'ok',
              population_match: 'ok',
              comparator_match: 'ok',
              timeframe_match: 'ok',
              direction_and_magnitude: 'ok',
              qualifiers_complete: 'ok',
              contradictory_evidence_represented: 'ok',
            },
            findings: null,
            rationale: 'Gikk gjennom ordlyd og forbehold.',
            citations: [],
          },
        ],
      }),
    )
    expect(parsed.revision.claimVerifications[0]?.agentRunId).toBeNull()
    expect(parsed.revision.claimVerifications[0]?.verifierActorType).toBe('human')
  })

  it('avviser et svar der revisjonen mangler', () => {
    expect(() =>
      parseClaimReviewWorkspace(
        fromApi({ reviewer_actor_id: '00000000-0000-4000-8000-222222222222' }),
      ),
    ).toThrow(/revision/)
  })

  it('avviser et svar der publiseringstilstanden mangler', () => {
    const broken = payload() as { revision: Record<string, unknown> }
    delete broken.revision['is_published_revision']
    expect(() => parseClaimReviewWorkspace(broken)).toThrow(/is_published_revision/)
  })
})
