import { describe, expect, it } from 'vitest'

import {
  CLAIM_SYNTHESIS_PROPOSAL_VERSION,
  parseClaimSynthesisProposal,
} from './claim-synthesis-proposal'

const TOPIC = '11111111-1111-4111-8111-111111111111'
const DRUG = '22222222-2222-4222-8222-222222222222'
const POPULATION = '33333333-3333-4333-8333-333333333333'
const ITEM = '44444444-4444-4444-8444-444444444444'
const OTHER_ITEM = '55555555-5555-4555-8555-555555555555'

function proposal(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    proposal_version: CLAIM_SYNTHESIS_PROPOSAL_VERSION,
    generated_by: {
      producer: 'model',
      provider: 'testleverandør',
      model: 'testmodell',
      model_version: '2026-09-13',
      prompt_template_version: 'claim-synthesis/1',
      drafted_at: '2026-09-13T09:00:00Z',
      request_digest: null,
    },
    claim: {
      claim_id: null,
      topic_concept_id: TOPIC,
      subject_drug_id: DRUG,
      statement: 'Hos voksne er behandling forbundet med en gjennomsnittlig vektøkning.',
      scope: 'Gjelder gjennomsnittlig vektendring fra behandlingsstart i åtte uker.',
      population_id: POPULATION,
      timeframe_min: '8 weeks',
      timeframe_max: '8 weeks',
      comparator_kind: 'none',
      comparator_drug_id: null,
      direction: 'increase',
      magnitude_measure: null,
      magnitude_value: null,
      magnitude_unit: null,
      qualifiers: 'Grunnlaget er armspesifikt.',
      uncertainty_summary: 'Ett evidensfunn fra én studie ligger til grunn.',
    },
    evidence_links: [
      {
        evidence_item_id: ITEM,
        relationship_type: 'supports',
        directness: 'indirect',
        relevance_note: 'Funnet rapporterer vektendring for behandlingsarmen påstanden gjelder.',
      },
    ],
    ...overrides,
  }
}

function claimWith(overrides: Record<string, unknown>): Record<string, unknown> {
  const base = proposal()
  return { ...base, claim: { ...(base['claim'] as Record<string, unknown>), ...overrides } }
}

describe('parseClaimSynthesisProposal', () => {
  it('leser et fullstendig forslag', () => {
    const parsed = parseClaimSynthesisProposal(proposal())
    expect(parsed.claim.statement).toMatch(/vektøkning/)
    expect(parsed.claim.claimId).toBeNull()
    expect(parsed.evidenceLinks).toHaveLength(1)
    expect(parsed.generatedBy.producer).toBe('model')
  })

  it('avviser en annen kontraktsversjon framfor å lese filen som om den var ny', () => {
    expect(() =>
      parseClaimSynthesisProposal(
        proposal({ proposal_version: 'antidep/claim-synthesis-proposal@0' }),
      ),
    ).toThrow(/proposal_version/)
  })

  it('avviser et ukjent felt framfor å ignorere det', () => {
    expect(() => parseClaimSynthesisProposal(proposal({ notat: 'hei' }))).toThrow(/ukjente felter/)
    expect(() => parseClaimSynthesisProposal(claimWith({ statemnt: 'skrivefeil' }))).toThrow(
      /ukjente felter/,
    )
  })

  it('avviser en kunnskapstype i filen: skriveveien registrerer bare evidenssyntese', () => {
    expect(() =>
      parseClaimSynthesisProposal(claimWith({ knowledge_type: 'clinical_recommendation' })),
    ).toThrow(/evidence_synthesis/)
  })

  it('avviser revisjonsnummer og videreføring: databasen teller selv', () => {
    expect(() => parseClaimSynthesisProposal(claimWith({ revision_number: 2 }))).toThrow(
      /Databasen teller selv/,
    )
    expect(() =>
      parseClaimSynthesisProposal(claimWith({ supersedes_revision_id: OTHER_ITEM })),
    ).toThrow(/følger av claim_id/)
  })

  it('avviser en aktør i filen: attribusjonen er kjøringens egen', () => {
    expect(() => parseClaimSynthesisProposal(claimWith({ created_by_actor_id: DRUG }))).toThrow(
      /legitimasjonen/,
    )
  })

  it('krever en usikkerhetstekst: en evidenssyntese uten den mangler halve påstanden', () => {
    expect(() => parseClaimSynthesisProposal(claimWith({ uncertainty_summary: '   ' }))).toThrow(
      /uncertainty_summary/,
    )
  })

  it('krever begge endene av tidsrommet, eller ingen av dem', () => {
    expect(() => parseClaimSynthesisProposal(claimWith({ timeframe_max: null }))).toThrow(
      /bare den ene enden/,
    )
    expect(() =>
      parseClaimSynthesisProposal(claimWith({ timeframe_min: null, timeframe_max: null })),
    ).not.toThrow()
  })

  it('bevarer en tallfestet størrelse ordrett, som tekst', () => {
    const parsed = parseClaimSynthesisProposal(
      claimWith({
        magnitude_measure: 'mean_change',
        magnitude_value: '0.80',
        magnitude_unit: 'kg',
      }),
    )
    expect(parsed.claim.magnitudeValue).toBe('0.80')
  })

  it('avviser et tall oppgitt som JSON-tall', () => {
    expect(() =>
      parseClaimSynthesisProposal(
        claimWith({ magnitude_measure: 'mean_change', magnitude_value: 0.8, magnitude_unit: 'kg' }),
      ),
    ).toThrow(/skrivemåten bevares/)
  })

  it('krever en begrunnelse på hver evidenslenke', () => {
    expect(() =>
      parseClaimSynthesisProposal(
        proposal({
          evidence_links: [
            { evidence_item_id: ITEM, relationship_type: 'supports', directness: 'direct' },
          ],
        }),
      ),
    ).toThrow(/relevance_note/)
  })

  it('avviser en lenke som er indirekte og direkte på én gang', () => {
    expect(() =>
      parseClaimSynthesisProposal(
        proposal({
          evidence_links: [
            {
              evidence_item_id: ITEM,
              relationship_type: 'indirect',
              directness: 'direct',
              relevance_note: 'Prøve.',
            },
          ],
        }),
      ),
    ).toThrow(/neutral_contextual/)
  })

  it('avviser det samme funnet to ganger', () => {
    const base = proposal()
    const link = (base['evidence_links'] as Record<string, unknown>[])[0] as Record<string, unknown>
    expect(() =>
      parseClaimSynthesisProposal(proposal({ evidence_links: [link, { ...link }] })),
    ).toThrow(/flere ganger/)
  })

  it('avviser en revisjon uten evidenslenker', () => {
    expect(() => parseClaimSynthesisProposal(proposal({ evidence_links: [] }))).toThrow(
      /evidence_links/,
    )
  })

  it('avviser en evidensvurdering i syntesforslaget: den er et eget ledd', () => {
    expect(() =>
      parseClaimSynthesisProposal(
        proposal({
          assessment: {
            framework: 'grade',
            certainty_level: 'very_low',
            risk_of_bias: 'serious',
            inconsistency: 'not_assessable',
            indirectness: 'serious',
            imprecision: 'serious',
            publication_bias: 'not_assessable',
            other_considerations: null,
            rationale: 'Ett evidensfunn ligger til grunn.',
            evidence_gap: null,
          },
        }),
      ),
    ).toThrow(/agent:assess-evidence/)
  })

  it('avviser et tidspunkt som ikke finnes i kalenderen', () => {
    const base = proposal()
    expect(() =>
      parseClaimSynthesisProposal({
        ...base,
        generated_by: {
          ...(base['generated_by'] as Record<string, unknown>),
          drafted_at: '2026-09-31T09:00:00Z',
        },
      }),
    ).toThrow(/drafted_at/)
  })
})
