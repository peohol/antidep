// ============================================================================
// Kontrakten som fil, og eksempelet som prøve på den
//
// `proposals/extraction-proposal.schema.json` er den formen noen utenfor
// Antidep får utlevert for å *lage* et forslag. Driver den fra parseren, blir
// den en beskrivelse av noe annet enn det som faktisk godtas — og den som
// følger den, får avvisninger uten å forstå hvorfor.
//
// Testene her holder de tre delene sammen: koden, den gjengitte filen og det
// commitede eksempelet.
// ============================================================================

import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

import { buildExtractionProposalSchema } from './extraction-proposal-schema'
import { EXTRACTION_PROPOSAL_VERSION, parseExtractionProposal } from './extraction-proposal'
import { EVIDENCE_CHECK_FIELDS, VALUE_AVAILABILITIES } from '../types/api'

const SCHEMA_FILE = 'proposals/extraction-proposal.schema.json'
const EXAMPLE_FILE = 'proposals/eksempel-syntetisk-forslag.json'

function readJson(path: string): Record<string, unknown> {
  return JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>
}

function objectAt(root: Record<string, unknown>, ...path: string[]): Record<string, unknown> {
  let current: Record<string, unknown> = root
  for (const key of path) {
    current = current[key] as Record<string, unknown>
  }
  return current
}

describe('extraction-proposal.schema.json', () => {
  // Regenereres med:
  //   npm run agent:extract-evidence -- --schema > proposals/extraction-proposal.schema.json
  it('er nøyaktig det koden bygger', () => {
    expect(readJson(SCHEMA_FILE)).toEqual(buildExtractionProposalSchema())
  })

  it('lukker formen på alle tre nivåene', () => {
    const schema = buildExtractionProposalSchema()
    expect(schema['additionalProperties']).toBe(false)
    expect(objectAt(schema, 'properties', 'extraction')['additionalProperties']).toBe(false)
    expect(
      objectAt(schema, 'properties', 'field_groundings', 'items')['additionalProperties'],
    ).toBe(false)
  })

  // Vokabularene leses fra src/types/api.ts, som tests/api-vocabularies.test.ts
  // holder identisk med enum-ene i migrasjonene. Skjemaet kan derfor ikke drive
  // fra databasen uten at den testen slår ut først.
  it('gjengir vokabularene fra kontraktslaget', () => {
    const schema = buildExtractionProposalSchema()
    expect(
      objectAt(schema, 'properties', 'field_groundings', 'items', 'properties', 'check_field')[
        'enum'
      ],
    ).toEqual([...EVIDENCE_CHECK_FIELDS])
    expect(
      objectAt(schema, 'properties', 'extraction', 'properties', 'population_availability')['enum'],
    ).toEqual([...VALUE_AVAILABILITIES])
  })

  it('binder forslaget til kontraktsversjonen', () => {
    expect(
      objectAt(buildExtractionProposalSchema(), 'properties', 'proposal_version')['const'],
    ).toBe(EXTRACTION_PROPOSAL_VERSION)
  })
})

describe('eksempel-syntetisk-forslag.json', () => {
  // Eksempelet er malen den som lager et forslag får utlevert. Er den ikke
  // gyldig, er malen feil.
  it('går gjennom den samme kontrollen som et ekte forslag', () => {
    const parsed = parseExtractionProposal(readJson(EXAMPLE_FILE))
    expect(parsed.proposalVersion).toBe(EXTRACTION_PROPOSAL_VERSION)
    expect(parsed.fieldGroundings.length).toBeGreaterThan(0)
  })

  it('har hvert felt skjemaet krever', () => {
    const example = readJson(EXAMPLE_FILE)
    const schema = buildExtractionProposalSchema()
    for (const key of schema['required'] as string[]) {
      expect(Object.keys(example)).toContain(key)
    }
    const extraction = example['extraction'] as Record<string, unknown>
    for (const key of objectAt(schema, 'properties', 'extraction')['required'] as string[]) {
      expect(Object.keys(extraction)).toContain(key)
    }
  })

  // Eksempelet skal vise hvordan forankringen faktisk dekker det raden påstår,
  // ikke bare være formelt gyldig med én forankring.
  it('forankrer hvert semantiske felt raden påstår noe om', () => {
    const parsed = parseExtractionProposal(readJson(EXAMPLE_FILE))
    const grounded = new Set(parsed.fieldGroundings.map((grounding) => grounding.checkField))
    const expected = [
      'intervention_arm',
      'comparator_arm',
      'outcome',
      'reported_direction',
      'availability_semantics',
      'effect_measure',
      'sample_size',
      'timepoint',
      'estimate',
      'confidence_interval',
      'limitations',
    ]
    for (const field of expected) {
      expect(grounded).toContain(field)
    }
  })

  // Eksempelet er syntetisk med vilje: det skal ikke kunne forveksles med en
  // reell kilde, og de nullede id-ene sier det tydelig.
  it('er tydelig syntetisk', () => {
    const example = readJson(EXAMPLE_FILE)
    expect(example['source_id']).toMatch(/^0{8}-/)
    expect(example['content_hash']).toBe(`sha256:${'0'.repeat(64)}`)
  })
})
