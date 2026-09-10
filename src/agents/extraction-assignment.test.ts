// ============================================================================
// Formen på et oppdrag
//
// Oppdraget er det modell-leddet får vite som ikke står i artikkelen:
// kildeversjonen, og katalogen den kan velge innenfor. Testene her er den
// grensens kontrakt — et ukjent felt er en feil, ingenting fylles inn, og en
// liste med to like id-er er en feil framfor et vilkårlig valg.
// ============================================================================

import { describe, expect, it } from 'vitest'

import {
  EXTRACTION_ASSIGNMENT_VERSION,
  parseAssignmentJson,
  parseExtractionAssignment,
} from './extraction-assignment'

function gyldig(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    assignment_version: EXTRACTION_ASSIGNMENT_VERSION,
    source_id: '50000000-0000-4000-8000-000000000001',
    source_version_id: '51000000-0000-4000-8000-000000000001',
    retrieved_from: 'https://eksempel.invalid/kilde',
    content_hash: `sha256:${'a'.repeat(64)}`,
    drugs: [{ drug_id: '40000000-0000-4000-8000-000000000001', label: 'sertralin' }],
    outcomes: [
      { outcome_concept_id: '41000000-0000-4000-8000-000000000001', label: 'vektendring' },
    ],
    populations: [],
    ...overrides,
  }
}

describe('parseExtractionAssignment — den gyldige formen', () => {
  it('leser et gyldig oppdrag', () => {
    const parsed = parseExtractionAssignment(gyldig())
    expect(parsed.sourceVersionId).toBe('51000000-0000-4000-8000-000000000001')
    expect(parsed.drugs).toEqual([
      { id: '40000000-0000-4000-8000-000000000001', label: 'sertralin' },
    ])
    expect(parsed.outcomes).toHaveLength(1)
  })

  // En tom populasjonsliste er en reell tilstand: passer ingen registrert
  // populasjon, skal availability si hvorfor (ANTIDEP_CONSTITUTION.md §6).
  it('godtar at ingen populasjon passer, og at listen mangler helt', () => {
    expect(parseExtractionAssignment(gyldig()).populations).toEqual([])
    const utenNøkkel = gyldig()
    delete utenNøkkel['populations']
    expect(parseExtractionAssignment(utenNøkkel).populations).toEqual([])
  })
})

describe('parseExtractionAssignment — det som avvises', () => {
  it('avviser et ukjent felt', () => {
    expect(() => parseExtractionAssignment(gyldig({ kilde: 'noe' }))).toThrow(
      /ukjente felter: kilde/,
    )
  })

  it('avviser et ukjent felt i et katalogvalg', () => {
    expect(() =>
      parseExtractionAssignment(
        gyldig({
          drugs: [
            { drug_id: '40000000-0000-4000-8000-000000000001', label: 'sertralin', atc: 'N06AB06' },
          ],
        }),
      ),
    ).toThrow(/drugs\[0\] har ukjente felter: atc/)
  })

  // Et oppdrag uten virkestoff er ikke et oppdrag: modellen ville ikke hatt
  // noen gyldig id å registrere funnet på.
  it('krever minst ett virkestoff og minst ett endepunkt', () => {
    expect(() => parseExtractionAssignment(gyldig({ drugs: [] }))).toThrow(/drugs mangler/)
    expect(() => parseExtractionAssignment(gyldig({ outcomes: [] }))).toThrow(/outcomes mangler/)
  })

  it('avviser den samme id-en to ganger', () => {
    expect(() =>
      parseExtractionAssignment(
        gyldig({
          drugs: [
            { drug_id: '40000000-0000-4000-8000-000000000001', label: 'sertralin' },
            { drug_id: '40000000-0000-4000-8000-000000000001', label: 'Sertralin' },
          ],
        }),
      ),
    ).toThrow(/fører 40000000-0000-4000-8000-000000000001 mer enn én gang/)
  })

  it('krever fingeravtrykket kildeversjonene registreres med', () => {
    expect(() => parseExtractionAssignment(gyldig({ content_hash: 'sha256:kort' }))).toThrow(
      /content_hash/,
    )
  })

  it('avviser en annen versjon av oppdragsformen', () => {
    expect(() =>
      parseExtractionAssignment(gyldig({ assignment_version: 'antidep/extraction-assignment@0' })),
    ).toThrow(/assignment_version/)
  })

  it('navngir filen når JSON-en ikke lar seg lese', () => {
    expect(() => parseAssignmentJson('assignments/x.json', '{')).toThrow(
      /assignments\/x\.json er ikke gyldig JSON/,
    )
  })

  it('navngir filen når formen er gal', () => {
    expect(() =>
      parseAssignmentJson('assignments/x.json', '{"assignment_version": "feil"}'),
    ).toThrow(/assignments\/x\.json: Oppdraget er ugyldig/)
  })
})
