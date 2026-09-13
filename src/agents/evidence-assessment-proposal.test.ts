import { describe, expect, it } from 'vitest'

import {
  EVIDENCE_ASSESSMENT_PROPOSAL_VERSION,
  parseEvidenceAssessmentProposal,
} from './evidence-assessment-proposal'

const REVISION = '66666666-6666-4666-8666-666666666666'
const ACTOR = '77777777-7777-4777-8777-777777777777'
const DIGEST = 'sha256:0f3a1c9e2b4d5678901234567890abcdef1234567890abcdef1234567890abcd'

function proposal(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    proposal_version: EVIDENCE_ASSESSMENT_PROPOSAL_VERSION,
    generated_by: {
      producer: 'model',
      provider: 'testleverandør',
      model: 'testmodell',
      model_version: '2026-09-13',
      prompt_template_version: 'evidence-assessment/1',
      drafted_at: '2026-09-13T09:00:00Z',
      request_digest: null,
    },
    claim_revision_id: REVISION,
    evidence_set_digest: DIGEST,
    assessment: {
      framework: 'grade',
      certainty_level: 'very_low',
      risk_of_bias: 'serious',
      inconsistency: 'not_assessable',
      indirectness: 'serious',
      imprecision: 'serious',
      publication_bias: 'not_assessable',
      other_considerations: null,
      rationale: 'Ett evidensfunn fra én randomisert studie ligger til grunn.',
      evidence_gap: 'Størrelsen er ikke tallfestet i grunnlaget.',
    },
    ...overrides,
  }
}

function assessmentWith(overrides: Record<string, unknown>): Record<string, unknown> {
  const base = proposal()
  return {
    ...base,
    assessment: { ...(base['assessment'] as Record<string, unknown>), ...overrides },
  }
}

describe('parseEvidenceAssessmentProposal', () => {
  it('leser et fullstendig forslag', () => {
    const parsed = parseEvidenceAssessmentProposal(proposal())
    expect(parsed.claimRevisionId).toBe(REVISION)
    expect(parsed.evidenceSetDigest).toBe(DIGEST)
    expect(parsed.assessment.certaintyLevel).toBe('very_low')
    expect(parsed.generatedBy.producer).toBe('model')
  })

  it('avviser en annen kontraktsversjon framfor å lese filen som om den var ny', () => {
    expect(() =>
      parseEvidenceAssessmentProposal(
        proposal({ proposal_version: 'antidep/evidence-assessment-proposal@0' }),
      ),
    ).toThrow(/proposal_version/)
  })

  it('krever revisjonen vurderingen gjelder', () => {
    expect(() => parseEvidenceAssessmentProposal(proposal({ claim_revision_id: null }))).toThrow(
      /claim_revision_id/,
    )
  })

  it('krever avtrykket av evidenssettet utkastet ble laget mot', () => {
    expect(() => parseEvidenceAssessmentProposal(proposal({ evidence_set_digest: '  ' }))).toThrow(
      /evidence_set_digest/,
    )
  })

  it('avviser et ukjent felt framfor å ignorere det', () => {
    expect(() => parseEvidenceAssessmentProposal(proposal({ notat: 'hei' }))).toThrow(
      /ukjente felter/,
    )
    expect(() =>
      parseEvidenceAssessmentProposal(assessmentWith({ rasjonale: 'skrivefeil' })),
    ).toThrow(/ukjente felter/)
  })

  it('krever alle fem GRADE-domenene når en sikkerhetsgrad er satt', () => {
    expect(() => parseEvidenceAssessmentProposal(assessmentWith({ imprecision: null }))).toThrow(
      /minst ett GRADE-domene/,
    )
  })

  it('avviser GRADE-domener sammen med «ingen vurderbar evidens»', () => {
    expect(() =>
      parseEvidenceAssessmentProposal(
        assessmentWith({ certainty_level: 'no_assessable_evidence' }),
      ),
    ).toThrow(/no_assessable_evidence/)
  })

  it('krever at «ingen vurderbar evidens» sier hva som mangler', () => {
    expect(() =>
      parseEvidenceAssessmentProposal(
        assessmentWith({
          certainty_level: 'no_assessable_evidence',
          risk_of_bias: null,
          inconsistency: null,
          indirectness: null,
          imprecision: null,
          publication_bias: null,
          evidence_gap: null,
        }),
      ),
    ).toThrow(/evidence_gap/)
  })

  it('godtar «ingen vurderbar evidens» når den sier hva som mangler', () => {
    const parsed = parseEvidenceAssessmentProposal(
      assessmentWith({
        certainty_level: 'no_assessable_evidence',
        risk_of_bias: null,
        inconsistency: null,
        indirectness: null,
        imprecision: null,
        publication_bias: null,
        evidence_gap: 'Det finnes ingen registrert evidens for dette endepunktet.',
      }),
    )
    expect(parsed.assessment.certaintyLevel).toBe('no_assessable_evidence')
    expect(parsed.assessment.riskOfBias).toBeNull()
  })

  it('avviser et vurderingstidspunkt i filen: databasen eier det', () => {
    expect(() =>
      parseEvidenceAssessmentProposal(assessmentWith({ assessed_at: '2026-09-13T09:00:00Z' })),
    ).toThrow(/eies av databasen/)
  })

  it('avviser en aktør i filen: attribusjonen er kjøringens egen', () => {
    expect(() =>
      parseEvidenceAssessmentProposal(assessmentWith({ created_by_actor_id: ACTOR })),
    ).toThrow(/legitimasjonen/)
  })

  it('avviser en kunnskapstype i filen: den leses av revisjonen', () => {
    expect(() =>
      parseEvidenceAssessmentProposal(
        assessmentWith({ assessed_knowledge_type: 'evidence_synthesis' }),
      ),
    ).toThrow(/leses av revisjonen/)
  })

  it('avviser et tidspunkt som ikke finnes i kalenderen', () => {
    const base = proposal()
    expect(() =>
      parseEvidenceAssessmentProposal({
        ...base,
        generated_by: {
          ...(base['generated_by'] as Record<string, unknown>),
          drafted_at: '2026-09-31T09:00:00Z',
        },
      }),
    ).toThrow(/drafted_at/)
  })
})
