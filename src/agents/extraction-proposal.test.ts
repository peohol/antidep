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
  extractionMethodFor,
  parseExtractionDraft,
  parseExtractionProposal,
  serializeExtractionProposal,
} from './extraction-proposal'
import { MIN_SOURCE_EXCERPT_LENGTH } from './source-excerpt'

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

function gyldigGeneratedBy(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    producer: 'model',
    provider: 'antidep',
    model: 'opptaksmodell',
    model_version: '1',
    prompt_template_version: 'evidence-extraction/proposal-drafting/1',
    drafted_at: '2026-09-15T09:00:00Z',
    ...overrides,
  }
}

function gyldig(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    proposal_version: EXTRACTION_PROPOSAL_VERSION,
    generated_by: gyldigGeneratedBy(),
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

  // Regresjon fra den første reelle kildekontrollen (Fava 2000). Utdraget er
  // langt nok, står ordrett i artikkelen, og er likevel ubrukelig: det er et
  // fragment uten en eneste setningsgrense, og en kontrollør kan ikke se hva
  // tallene gjelder.
  it('avviser et løsrevet fragment, selv når det er langt nok', () => {
    const fragment = gyldig({
      field_groundings: [
        {
          check_field: 'intervention_arm',
          source_excerpt: 'tine (N = 92), sertraline, (N = 96), or paroxetine',
          source_locator: 'Methods',
          justification: 'Armene er navngitt.',
        },
      ],
    })
    expect(() => parseExtractionProposal(fragment)).toThrow(/inneholder ingen setningsgrense/)
  })

  // Et desimaltegn er ingen setningsgrense. «1.0» avslutter ingen setning, og et
  // fragment som bare inneholder tallet, skal ikke slippe gjennom fordi det står
  // et punktum inni det.
  it('regner ikke desimaltegnet i et tall som en setningsgrense', () => {
    const fragment = gyldig({
      field_groundings: [
        {
          check_field: 'estimate',
          source_excerpt: 'showed a small mean increase in weight of 1.0 percent',
          source_locator: 'Results',
          justification: 'Estimatet står i resultatavsnittet.',
        },
      ],
    })
    expect(() => parseExtractionProposal(fragment)).toThrow(/inneholder ingen setningsgrense/)
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

// ---------------------------------------------------------------------------
// Hvem som laget forslaget
// ---------------------------------------------------------------------------

describe('parseExtractionProposal — generated_by', () => {
  it('leser erklæringen om hvem som laget forslaget', () => {
    const parsed = parseExtractionProposal(gyldig())
    expect(parsed.generatedBy).toEqual({
      producer: 'model',
      provider: 'antidep',
      model: 'opptaksmodell',
      modelVersion: '1',
      promptTemplateVersion: 'evidence-extraction/proposal-drafting/1',
      draftedAt: '2026-09-15T09:00:00Z',
      requestDigest: null,
    })
  })

  // Uten feltet ville kjøringen måttet oppgi en fast verdi for hvert forslag,
  // altså registrert et menneskes ekstraksjon som en modells og omvendt
  // (ANTIDEP_CONSTITUTION.md §14, §20).
  it('krever at forslaget sier hvem som laget det', () => {
    const uten = gyldig()
    delete uten['generated_by']
    expect(() => parseExtractionProposal(uten)).toThrow(/generated_by/)
  })

  it('avviser en produsent utenfor vokabularet', () => {
    expect(() =>
      parseExtractionProposal(gyldig({ generated_by: gyldigGeneratedBy({ producer: 'agent' }) })),
    ).toThrow(/producer er "agent"/)
  })

  it('krever hver av premissene', () => {
    for (const felt of [
      'provider',
      'model',
      'model_version',
      'prompt_template_version',
      'drafted_at',
    ]) {
      const uten = gyldigGeneratedBy()
      delete uten[felt]
      expect(() => parseExtractionProposal(gyldig({ generated_by: uten }))).toThrow(
        new RegExp(`generated_by\\.${felt}`),
      )
    }
  })

  // Pipelineversjonen er Antideps egen. Et forslag utenfra skal ikke kunne
  // påstå noe om hvilken pipeline som registrerte det.
  it('navngir pipeline_version særskilt som noe forslaget ikke skal oppgi', () => {
    expect(() =>
      parseExtractionProposal(
        gyldig({ generated_by: gyldigGeneratedBy({ pipeline_version: 'antidep-evidence/1' }) }),
      ),
    ).toThrow(/Pipelineversjonen er Antideps egen/)
  })

  it('oversetter produsenten til ekstraksjonsmetoden raden registreres med', () => {
    expect(extractionMethodFor('model')).toBe('ai_assisted')
    expect(extractionMethodFor('human')).toBe('manual')
  })

  // Tidspunktet er utkastets, og registreringen skjer senere. Uten det ville
  // det eneste tidspunktet i proveniensen vært registreringskjøringens
  // (EVIDENCE_PIPELINE.md §65).
  it('krever at tidspunktet er et tidspunkt med tidssone', () => {
    expect(() =>
      parseExtractionProposal(
        gyldig({ generated_by: gyldigGeneratedBy({ drafted_at: '15.09.2026' }) }),
      ),
    ).toThrow(/drafted_at/)
    expect(() =>
      parseExtractionProposal(
        gyldig({ generated_by: gyldigGeneratedBy({ drafted_at: '2026-09-15T09:00:00' }) }),
      ),
    ).toThrow(/drafted_at/)
  })

  // Formen alene er ikke nok. Node normaliserer en dag utenfor måneden framfor
  // å gi NaN, så «31. september» ville blitt 1. oktober og stått i proveniensen
  // som et tidspunkt ingen kan peke på i en kalender. Kontrollen er den samme
  // som modellsvarets `answered_at` bruker, fra `strict-fields.ts`.
  it('krever at datoen finnes i kalenderen', () => {
    for (const drafted of [
      '2026-09-31T00:00:00Z',
      '2026-02-29T00:00:00Z',
      '2026-13-01T00:00:00Z',
    ]) {
      expect(() =>
        parseExtractionProposal(
          gyldig({ generated_by: gyldigGeneratedBy({ drafted_at: drafted }) }),
        ),
      ).toThrow(/drafted_at/)
    }
  })

  it('godtar 29. februar i et skuddår', () => {
    expect(
      parseExtractionProposal(
        gyldig({ generated_by: gyldigGeneratedBy({ drafted_at: '2028-02-29T00:00:00Z' }) }),
      ).generatedBy.draftedAt,
    ).toBe('2028-02-29T00:00:00Z')
  })

  // Avtrykket er den ene verdien som gjør en modellkjøring identifiserbar i
  // ettertid. Et menneskeskrevet forslag har ingen forespørsel, og utelater det.
  it('godtar at fingeravtrykket av forespørselen mangler, men ikke at det er noe annet', () => {
    expect(parseExtractionProposal(gyldig()).generatedBy.requestDigest).toBeNull()
    expect(
      parseExtractionProposal(
        gyldig({
          generated_by: gyldigGeneratedBy({ request_digest: `sha256:${'a'.repeat(64)}` }),
        }),
      ).generatedBy.requestDigest,
    ).toBe(`sha256:${'a'.repeat(64)}`)
    expect(() =>
      parseExtractionProposal(gyldig({ generated_by: gyldigGeneratedBy({ request_digest: 'x' }) })),
    ).toThrow(/request_digest/)
  })

  it('avviser et forslag skrevet mot den forrige versjonen av kontrakten', () => {
    expect(() =>
      parseExtractionProposal(gyldig({ proposal_version: 'antidep/extraction-proposal@1' })),
    ).toThrow(/proposal_version/)
  })
})

// ---------------------------------------------------------------------------
// Modellens utkast, og veien tilbake til en fil
// ---------------------------------------------------------------------------

describe('parseExtractionDraft', () => {
  it('leser de to delene et modell-ledd produserer', () => {
    const draft = parseExtractionDraft(
      { extraction: gyldigExtraction(), field_groundings: gyldig()['field_groundings'] },
      'Modellsvaret',
    )
    expect(draft.extraction.designCode).toBe('randomized_controlled_trial')
    expect(draft.fieldGroundings).toHaveLength(1)
  })

  // Kildebindingen er oppdragets og settes av kjøringen. En modell som kunne
  // oppgitt den, kunne oppgitt feil utgave uten at noe merket det.
  it('avviser en kildebinding i modellens utkast', () => {
    expect(() =>
      parseExtractionDraft(
        {
          extraction: gyldigExtraction(),
          field_groundings: gyldig()['field_groundings'],
          source_version_id: '51000000-0000-4000-8000-000000000001',
        },
        'Modellsvaret',
      ),
    ).toThrow(/Modellsvaret er ugyldig.*source_version_id/s)
  })

  it('navngir svaret i avvisningen framfor å kalle det en fil', () => {
    expect(() => parseExtractionDraft({ extraction: {} }, 'Modellsvaret')).toThrow(
      /^Modellsvaret er ugyldig/,
    )
  })
})

describe('serializeExtractionProposal', () => {
  // Filen modell-leddet skriver, skal være nøyaktig den formen kjøringen
  // etterpå leser. To oversettelser ville vært to steder å stave et feltnavn
  // feil, og feilen ville først vist seg som en manglende verdi i en rad.
  it('gir en form leseren tar imot uendret', () => {
    const original = parseExtractionProposal(gyldig())
    const tilbake = parseExtractionProposal(
      JSON.parse(JSON.stringify(serializeExtractionProposal(original))) as unknown,
    )
    expect(tilbake).toEqual(original)
  })
})
