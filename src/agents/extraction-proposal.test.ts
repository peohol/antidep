// ============================================================================
// Formen på et ekstraksjonsforslag
//
// Kontrollen gjelder formen, aldri innholdet: at et felt finnes, har riktig
// type og en verdi innenfor sitt vokabular. Om verdien følger av kilden,
// avgjøres av den ordrette kontrollen og av mennesket etterpå.
//
// Forslaget er den permanente grensen mot et framtidig modell-ledd, og testene
// her er den grensens kontrakt: et ukjent felt er en feil, ingenting fylles
// inn, og ingen verdi utenfor vokabularet slipper gjennom.
// ============================================================================

import { describe, expect, it } from 'vitest'

import {
  EXTRACTION_PROPOSAL_VERSION,
  MIN_SOURCE_EXCERPT_LENGTH,
  parseExtractionProposal,
} from './extraction-proposal'

const EXCERPT = 'Patients received sertraline 50 mg daily for eight weeks.'

function gyldigExtraction(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
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
    ...overrides,
  }
}

function gyldig(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    proposal_version: EXTRACTION_PROPOSAL_VERSION,
    source_id: '50000000-0000-4000-8000-000000000001',
    source_version_id: '51000000-0000-4000-8000-000000000001',
    retrieved_from: 'https://eksempel.invalid/kilde',
    content_hash: `sha256:${'a'.repeat(64)}`,
    extraction: gyldigExtraction(),
    field_groundings: [
      {
        check_field: 'intervention_arm',
        source_excerpt: EXCERPT,
        source_locator: 'Metode',
        justification: 'Armen står i metodeavsnittet.',
      },
    ],
    ...overrides,
  }
}

describe('parseExtractionProposal — den gyldige formen', () => {
  it('leser et gyldig forslag', () => {
    const parsed = parseExtractionProposal(gyldig())
    expect(parsed.proposalVersion).toBe(EXTRACTION_PROPOSAL_VERSION)
    expect(parsed.sourceVersionId).toBe('51000000-0000-4000-8000-000000000001')
    expect(parsed.fieldGroundings).toHaveLength(1)
    expect(parsed.extraction.designCode).toBe('randomized_controlled_trial')
  })

  // Et forslag uten en verdi er et forslag uten den verdien. Ingenting fylles
  // inn (ANTIDEP_CONSTITUTION.md §6).
  it('lar en utelatt valgfri verdi stå som fravær', () => {
    const parsed = parseExtractionProposal(gyldig())
    expect(parsed.extraction.estimate).toBeNull()
    expect(parsed.extraction.limitationsText).toBeNull()
    expect(parsed.extraction.sampleSize).toBeNull()
    expect(parsed.extraction.populationId).toBeNull()
  })

  it('bevarer tallverdien ordrett', () => {
    const medHale = gyldig({
      extraction: gyldigExtraction({ estimate: '1.50', estimate_availability: 'reported_value' }),
    })
    expect(parseExtractionProposal(medHale).extraction.estimate).toBe('1.50')
  })
})

describe('parseExtractionProposal — kontraktsversjonen', () => {
  it('krever at versjonen er oppgitt', () => {
    const uten = gyldig()
    delete uten['proposal_version']
    expect(() => parseExtractionProposal(uten)).toThrow(/proposal_version/)
  })

  // Uten versjonskravet ville et forslag skrevet mot en eldre form sett ut som
  // et forslag med et manglende felt, og bare det ene er en feil.
  it('avviser en annen versjon enn den kjøreren leser', () => {
    const feil = gyldig({ proposal_version: 'antidep/extraction-proposal@0' })
    expect(() => parseExtractionProposal(feil)).toThrow(/proposal_version/)
  })
})

describe('parseExtractionProposal — et ukjent felt er en feil', () => {
  // Uten dette ville `extimate` blitt registrert som et manglende estimat, og
  // feilen ville sett ut som en mangel i kilden.
  it('avviser et ukjent felt i forslaget', () => {
    expect(() => parseExtractionProposal(gyldig({ kilde: 'noe' }))).toThrow(/ukjente felter/)
  })

  it('avviser et ukjent felt i extraction', () => {
    const skrivefeil = gyldig({ extraction: gyldigExtraction({ extimate: '1.5' }) })
    expect(() => parseExtractionProposal(skrivefeil)).toThrow(/ukjente felter: extimate/)
  })

  it('avviser et ukjent felt i en forankring', () => {
    const ekstra = gyldig({
      field_groundings: [
        {
          check_field: 'outcome',
          source_excerpt: EXCERPT,
          source_locator: 'Metode',
          justification: 'Begrunnelse.',
          confidence: 0.9,
        },
      ],
    })
    expect(() => parseExtractionProposal(ekstra)).toThrow(/ukjente felter: confidence/)
  })

  // De strukturerte verdiene er kolonnene. En samlet tolkning ved siden av
  // ville vært noe å lese verdier ut av (EVIDENCE_PIPELINE.md §21).
  it('navngir raw_extraction særskilt', () => {
    const medSkuff = gyldig({ raw_extraction: { note: 'hele tolkningen' } })
    expect(() => parseExtractionProposal(medSkuff)).toThrow(/hører ikke hjemme i et forslag/)
  })
})

describe('parseExtractionProposal — lukkede vokabularer', () => {
  it('avviser en ukjent availability-verdi', () => {
    const feil = gyldig({ extraction: gyldigExtraction({ population_availability: 'maybe' }) })
    expect(() => parseExtractionProposal(feil)).toThrow(/population_availability/)
  })

  it('avviser en ukjent retning', () => {
    const feil = gyldig({ extraction: gyldigExtraction({ reported_direction: 'up' }) })
    expect(() => parseExtractionProposal(feil)).toThrow(/reported_direction/)
  })

  it('avviser et ukjent effektmål', () => {
    const feil = gyldig({ extraction: gyldigExtraction({ effect_measure: 'hedges_g' }) })
    expect(() => parseExtractionProposal(feil)).toThrow(/effect_measure/)
  })

  it('avviser et ukjent kontrollfelt i forankringen', () => {
    const feil = gyldig({
      field_groundings: [
        {
          check_field: 'konklusjon',
          source_excerpt: EXCERPT,
          source_locator: 'Metode',
          justification: 'Begrunnelse.',
        },
      ],
    })
    expect(() => parseExtractionProposal(feil)).toThrow(/check_field/)
  })
})

describe('parseExtractionProposal — bindingen til kildeversjonen', () => {
  it('krever at kildeversjonen er en uuid', () => {
    expect(() => parseExtractionProposal(gyldig({ source_version_id: 'fava-2000' }))).toThrow(
      /source_version_id/,
    )
  })

  it('krever at fingeravtrykket har formen kildeversjonene registreres med', () => {
    expect(() => parseExtractionProposal(gyldig({ content_hash: 'abc123' }))).toThrow(
      /content_hash/,
    )
  })

  it('sier hvilket felt som er galt', () => {
    expect(() => parseExtractionProposal(gyldig({ source_version_id: '' }))).toThrow(
      /source_version_id/,
    )
  })
})

describe('parseExtractionProposal — forankringen', () => {
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
          source_excerpt: EXCERPT,
          source_locator: 'Metode',
          justification: 'Første.',
        },
        {
          check_field: 'outcome',
          source_excerpt: EXCERPT,
          source_locator: 'Resultat',
          justification: 'Andre.',
        },
      ],
    })
    expect(() => parseExtractionProposal(duplikat)).toThrow(/mer enn én gang/)
  })

  it('avviser en forankring uten kildepeker', () => {
    const uten = gyldig({
      field_groundings: [
        { check_field: 'outcome', source_excerpt: EXCERPT, justification: 'Begrunnelse.' },
      ],
    })
    expect(() => parseExtractionProposal(uten)).toThrow(/source_locator/)
  })

  // Et tall uten kontekst er ikke kontrollgrunnlag: det står kanskje fem steder
  // i artikkelen, og utdraget sier ikke hvilket.
  it('avviser et utdrag uten nok kontekst', () => {
    const kort = gyldig({
      field_groundings: [
        {
          check_field: 'sample_size',
          source_excerpt: 'N = 284',
          source_locator: 'Resultat',
          justification: 'Utvalget.',
        },
      ],
    })
    expect(() => parseExtractionProposal(kort)).toThrow(
      new RegExp(`kortere enn ${String(MIN_SOURCE_EXCERPT_LENGTH)} tegn`),
    )
  })
})

describe('parseExtractionProposal — tallverdier', () => {
  // `1.50` og `1.5` er samme tall, men ikke samme oppgitte verdi. En tur innom
  // `Number` ville stille endret det som skal kontrolleres mot kilden.
  it('krever at tallverdier står som tekst', () => {
    const somTall = gyldig({
      extraction: gyldigExtraction({ estimate: 1.5, estimate_availability: 'reported_value' }),
    })
    expect(() => parseExtractionProposal(somTall)).toThrow(/skrivemåten bevares ordrett/)
  })

  it('krever at utvalgsstørrelsen er et heltall', () => {
    const somTekst = gyldig({ extraction: gyldigExtraction({ sample_size: '284' }) })
    expect(() => parseExtractionProposal(somTekst)).toThrow(/sample_size/)
  })
})
