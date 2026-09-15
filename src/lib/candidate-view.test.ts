import { describe, expect, it } from 'vitest'

import {
  canBeFinalControlled,
  coverageRatio,
  parseCandidateView,
  uncoveredCheckFields,
  CITATION_SUPPORT_CHECK_FIELDS,
  GRADE_DOMAIN_FIELDS,
} from './candidate-view.ts'
import {
  candidateContent,
  candidateResponse,
  FIXTURE_CANDIDATE_DIGEST,
  FIXTURE_EVIDENCE_SET_DIGEST,
} from './candidate-test-support.ts'

describe('parseCandidateView', () => {
  it('leser kandidaten med påstand, vurdering, evidens og kildedekning', () => {
    const view = parseCandidateView(candidateResponse())
    expect(view.claim.subjectDrug).toBe('sertralin')
    expect(view.assessment?.certaintyLevel).toBe('low')
    expect(view.evidence).toHaveLength(1)
    expect(view.sourceCoverage[0]?.fullTextInLibrary).toBe(true)
    expect(view.published).toBe(false)
    expect(view.experimental).toBe(true)
  })

  // Avtrykket dekker vurderingen i sin helhet. En lesing som slo domenene
  // sammen til én sikkerhetsgrad, ville latt en fagperson attestere en
  // nedgradering hen aldri så begrunnelsen for.
  it('leser hvert GRADE-domene for seg', () => {
    const view = parseCandidateView(candidateResponse())
    expect(GRADE_DOMAIN_FIELDS.map((field) => view.assessment?.[field])).toEqual([
      'serious',
      'not_assessable',
      'not_serious',
      'very_serious',
      'not_assessable',
    ])
    expect(view.assessment?.otherConsiderations).toBe(
      'Ingen dose-respons-sammenheng kunne vurderes.',
    )
  })

  // Domenene er null nøyaktig når det ikke finnes noe å gradere ned fra
  // (evidence_assessments_*_pairing_check). Det er ikke «ingen nedgradering».
  it('skiller et domene som ikke lot seg vurdere fra et domene uten problem', () => {
    const view = parseCandidateView(
      candidateResponse({
        content: candidateContent({
          evidence_assessment: {
            framework: 'grade',
            certainty_level: 'no_assessable_evidence',
            rationale: 'Det finnes ikke vurderbar evidens.',
          },
        }),
      }),
    )
    expect(GRADE_DOMAIN_FIELDS.every((field) => view.assessment?.[field] === null)).toBe(true)
    expect(view.assessment?.certaintyLevel).toBe('no_assessable_evidence')
  })

  it('leser alle de sju kontrollpunktene i kildestøttekontrollen', () => {
    const view = parseCandidateView(candidateResponse())
    expect(CITATION_SUPPORT_CHECK_FIELDS.map((f) => view.citationSupportCheck?.[f])).toEqual([
      'ok',
      'ok',
      'not_assessable',
      'ok',
      'ok',
      'deviation',
      'not_assessable',
    ])
    expect(view.citationSupportCheck?.outcome).toBe('needs_correction')
    expect(view.citationSupportCheck?.verifiedEvidenceSetDigest).toBe(FIXTURE_EVIDENCE_SET_DIGEST)
  })

  // ANTIDEP_CONSTITUTION.md regel 4: fravær og tomhet er ikke det samme.
  it('leser en manglende evidensvurdering som fravær, ikke som en tom vurdering', () => {
    const view = parseCandidateView(
      candidateResponse({ content: candidateContent({ evidence_assessment: null }) }),
    )
    expect(view.assessment).toBeNull()
  })

  it('leser en manglende kildestøttekontroll som fravær, ikke som en bestått kontroll', () => {
    const view = parseCandidateView(
      candidateResponse({ content: candidateContent({ citation_support_check: null }) }),
    )
    expect(view.citationSupportCheck).toBeNull()
  })

  // Avtrykket er av hele innholdet. Bæres bare et utvalg videre, kan ikke
  // flaten vise det som faktisk attesteres.
  it('bærer det forseglede innholdet videre uendret', () => {
    const svar = candidateResponse()
    const view = parseCandidateView(svar)
    expect(view.sealedContent).toEqual(svar['content'])
  })

  it('avviser et svar uten kontraktens form framfor å tegne en tom rute', () => {
    expect(() => parseCandidateView(candidateResponse({ is_current: 'ja' }))).toThrow(/is_current/)
    expect(() => parseCandidateView({})).toThrow(/content/)
  })
})

describe('kildedekningen', () => {
  it('sier hvor mange av kontrollfeltene som faktisk er dekket', () => {
    const view = parseCandidateView(candidateResponse())
    const evidence = view.evidence[0]
    expect(evidence).toBeDefined()
    if (evidence === undefined) return
    expect(coverageRatio(evidence)).toEqual({ covered: 2, required: 3 })
  })

  // Et ukontrollert felt er ikke det samme som et kontrollert felt uten avvik.
  // Vises bare det andre, ser det første ut som det.
  it('navngir feltene som ingen kontroll dekker', () => {
    const view = parseCandidateView(candidateResponse())
    const evidence = view.evidence[0]
    expect(evidence).toBeDefined()
    if (evidence === undefined) return
    expect(uncoveredCheckFields(evidence)).toEqual(['timepoint'])
  })
})

describe('canBeFinalControlled', () => {
  it('lar en gjeldende kandidat sluttkontrolleres', () => {
    expect(canBeFinalControlled(parseCandidateView(candidateResponse()))).toBe(true)
  })

  it('stopper en kandidat hvis grunnlag er endret siden forseglingen', () => {
    const view = parseCandidateView(
      candidateResponse({ is_current: false, current_digest: `sha256:${'c'.repeat(64)}` }),
    )
    expect(canBeFinalControlled(view)).toBe(false)
    expect(view.candidateDigest).toBe(FIXTURE_CANDIDATE_DIGEST)
  })
})
