// ============================================================================
// Formen på et ekstraksjonsforslag
//
// Kontrollen gjelder formen, aldri innholdet: at et felt finnes og har riktig
// type. Om verdien følger av kilden, avgjøres av den ordrette kontrollen og av
// mennesket etterpå.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { parseExtractionProposal } from './extraction-proposal'

function gyldig(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    source_id: '50000000-0000-4000-8000-000000000001',
    source_version_id: '51000000-0000-4000-8000-000000000001',
    retrieved_from: 'https://eksempel.invalid/kilde',
    content_hash: `sha256:${'a'.repeat(64)}`,
    extraction: {
      design_code: 'randomized_controlled_trial',
      population_availability: 'not_reported',
      population_detail: 'Voksne.',
      sample_size_availability: 'not_reported',
      intervention_drug_id: '40000000-0000-4000-8000-000000000001',
      comparator_kind: 'none',
      outcome_concept_id: '41000000-0000-4000-8000-000000000001',
      outcome_detail: 'Vektendring.',
      timepoint_availability: 'not_reported',
      reported_direction: 'increase',
      estimate_availability: 'not_reported',
      confidence_interval_availability: 'not_reported',
      source_locator: 'Sammendrag',
    },
    field_groundings: [
      {
        check_field: 'intervention_arm',
        source_excerpt: 'Patients received sertraline.',
        source_locator: 'Metode',
        justification: 'Armen står i metodeavsnittet.',
      },
    ],
    ...overrides,
  }
}

describe('parseExtractionProposal', () => {
  it('leser et gyldig forslag', () => {
    const parsed = parseExtractionProposal(gyldig())
    expect(parsed.sourceVersionId).toBe('51000000-0000-4000-8000-000000000001')
    expect(parsed.fieldGroundings).toHaveLength(1)
    expect(parsed.extraction.designCode).toBe('randomized_controlled_trial')
  })

  it('krever minst én forankring', () => {
    expect(() => parseExtractionProposal(gyldig({ field_groundings: [] }))).toThrow(
      /field_groundings/,
    )
  })

  // Ett felt har én forankring: to ville vært to påstander om hvilket utdrag
  // verdien hviler på.
  it('avviser to forankringer av samme felt', () => {
    const duplikat = gyldig({
      field_groundings: [
        {
          check_field: 'outcome',
          source_excerpt: 'A',
          source_locator: 'B',
          justification: 'C',
        },
        {
          check_field: 'outcome',
          source_excerpt: 'D',
          source_locator: 'E',
          justification: 'F',
        },
      ],
    })
    expect(() => parseExtractionProposal(duplikat)).toThrow(/mer enn én gang/)
  })

  it('avviser en forankring uten kildepeker', () => {
    const uten = gyldig({
      field_groundings: [{ check_field: 'outcome', source_excerpt: 'A', justification: 'C' }],
    })
    expect(() => parseExtractionProposal(uten)).toThrow(/source_locator/)
  })

  // `1.50` og `1.5` er samme tall, men ikke samme oppgitte verdi. En tur innom
  // `Number` ville stille endret det som skal kontrolleres mot kilden.
  it('krever at tallverdier står som tekst', () => {
    const somTall = gyldig({
      extraction: { ...(gyldig()['extraction'] as Record<string, unknown>), estimate: 1.5 },
    })
    expect(() => parseExtractionProposal(somTall)).toThrow(/skrivemåten bevares ordrett/)
  })

  it('bevarer tallverdien ordrett', () => {
    const medHale = gyldig({
      extraction: { ...(gyldig()['extraction'] as Record<string, unknown>), estimate: '1.50' },
    })
    expect(parseExtractionProposal(medHale).extraction.estimate).toBe('1.50')
  })

  // Et forslag uten en verdi er et forslag uten den verdien. Ingenting fylles
  // inn (ANTIDEP_CONSTITUTION.md §6).
  it('lar en utelatt valgfri verdi stå som fravær', () => {
    const parsed = parseExtractionProposal(gyldig())
    expect(parsed.extraction.estimate).toBeNull()
    expect(parsed.extraction.limitationsText).toBeNull()
    expect(parsed.extraction.sampleSize).toBeNull()
  })

  it('sier hvilket felt som er galt', () => {
    const uten = gyldig({ source_version_id: '' })
    expect(() => parseExtractionProposal(uten)).toThrow(/source_version_id/)
  })
})
