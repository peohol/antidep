// @vitest-environment node
import { describe, expect, it } from 'vitest'

import { parseVerificationInput } from './verification-input.ts'

// Svaret slik det faktisk kommer: api-funksjonen returnerer jsonb, PostgREST
// sender det som JSON-tekst, og `JSON.parse` er det første som rører det. Å
// bygge et objekt for hånd ville hoppet over nettopp det leddet der presisjonen
// går tapt, og testen ville prøvd fikstursen framfor kjeden.
function fromApi(json: string): unknown {
  return JSON.parse(json)
}

function svarMed(felter: Record<string, string>): string {
  const ekstraksjon = {
    design_code: 'randomized_controlled_trial',
    population_label: null,
    population_availability: 'not_reported',
    population_detail: 'Voksne med depressiv lidelse.',
    sample_size: null,
    sample_size_availability: 'not_reported',
    intervention_drug_name: 'sertraline',
    intervention_detail: null,
    comparator_kind: 'none',
    comparator_drug_name: null,
    comparator_detail: null,
    outcome_label: 'weight change',
    outcome_detail: 'Gjennomsnittlig vektendring.',
    timepoint_availability: 'not_reported',
    reported_direction: 'increase',
    effect_measure: 'mean_change',
    estimate_unit: 'kg',
    estimate_availability: 'reported_value',
    confidence_interval_availability: 'not_reported',
    limitations_text: null,
    source_locator: 'Sammendrag',
    raw_extraction: null,
  }
  const felterJson = Object.entries(felter)
    .map(([navn, verdi]) => `"${navn}": ${verdi}`)
    .join(', ')
  return `{
    "agent_run_id": "d3e0f6a0-0000-4000-8000-000000000001",
    "verifier_actor_id": "d3e0f6a0-0000-4000-8000-000000000002",
    "items": [
      {
        "evidence_item_id": "d3e0f6a0-0000-4000-8000-000000000003",
        "created_by_actor_key": "agent:evidence-extraction",
        "source": {
          "source_id": "d3e0f6a0-0000-4000-8000-000000000004",
          "source_type": "journal_article",
          "title": "Testkilde",
          "authors_or_issuer": null,
          "publisher_or_journal": null,
          "publication_date": null,
          "publication_date_precision": "unknown",
          "source_status": "active",
          "status_note": null
        },
        "source_version": null,
        "verifications_by_this_actor": 0,
        "extraction": { ${JSON.stringify(ekstraksjon).slice(1, -1)}, ${felterJson} }
      }
    ]
  }`
}

describe('parseVerificationInput — kliniske tallverdier', () => {
  // Hele poenget: `numeric` er vilkårlig presis, en IEEE-754 double er det
  // ikke, og avrundingen skjer i `JSON.parse` — før noen linje i parseren
  // kjører. Sifferrekken må derfor komme som tekst hele veien.
  it.each([
    ['9007199254740993', 'utenfor Number.MAX_SAFE_INTEGER'],
    ['0.1234567890123456789', 'flere signifikante siffer enn en double rommer'],
    ['1.0000000000000000001', 'skiller seg fra 1 først i det 19. sifferet'],
  ])('bevarer %s ordrett (%s)', (verdi) => {
    const input = parseVerificationInput(fromApi(svarMed({ estimate: `"${verdi}"` })))

    expect(input.items[0]?.extraction.estimate).toBe(verdi)
  })

  it('avviser et estimat som kom som JSON-tall, framfor å bruke den avrundede verdien', () => {
    // Uten kastet ville denne blitt til «9007199254740992» og kontrollen ville
    // lett etter et tall som ikke er det registrerte.
    expect(() =>
      parseVerificationInput(fromApi(svarMed({ estimate: '9007199254740993' }))),
    ).toThrow(/extraction\.estimate kom som number/)
  })

  it.each(['ci_lower', 'ci_upper', 'ci_level_percent'])('avviser også %s som JSON-tall', (felt) => {
    const svar = svarMed({
      estimate: '"1.5"',
      confidence_interval_availability: '"reported_value"',
      ci_lower: felt === 'ci_lower' ? '0.4' : '"0.4"',
      ci_upper: felt === 'ci_upper' ? '2.6' : '"2.6"',
      ci_level_percent: felt === 'ci_level_percent' ? '95' : '"95"',
    })

    expect(() => parseVerificationInput(fromApi(svar))).toThrow(
      new RegExp(`extraction\\.${felt} kom som number`),
    )
  })

  it('leser fravær som fravær, ikke som et kontraktsbrudd', () => {
    const input = parseVerificationInput(
      fromApi(svarMed({ estimate: 'null', estimate_availability: '"not_reported"' })),
    )

    expect(input.items[0]?.extraction.estimate).toBeNull()
  })
})
