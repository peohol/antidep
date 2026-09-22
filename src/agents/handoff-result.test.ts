import { describe, expect, it } from 'vitest'

import { parseAgentTask, type HandoffRole } from './agent-task.ts'
import { handoffResultProblem } from './handoff-result.ts'
import {
  resultFor,
  taskPayload,
  TEST_EVIDENCE_ID,
  TEST_OTHER_EVIDENCE_ID,
  TEST_OUTCOME_ID,
} from './handoff-test-support.ts'

type Role = HandoffRole

function task(role: Role) {
  return parseAgentTask(taskPayload(role))
}

/** Utkastet med én verdi endret, uten å røre fiksturet. */
function withExtraction(change: Record<string, unknown>): Record<string, unknown> {
  const result = resultFor('evidence_extraction')
  const extraction = result['extraction'] as Record<string, unknown>
  return { ...result, extraction: { ...extraction, ...change } }
}

describe('ekstraksjonsutkastet', () => {
  it('godtar et utkast som holder seg innenfor oppgaven og står ordrett i teksten', () => {
    expect(
      handoffResultProblem(task('evidence_extraction'), resultFor('evidence_extraction')),
    ).toBeNull()
  })

  // Avgrensningen er den ene tingen den ordrette kontrollen ikke kan fange: et
  // utdrag kan stå ordrett i kilden og likevel være ført på feil endepunkt.
  it('avviser et endepunkt utenfor oppgaven', () => {
    const problem = handoffResultProblem(
      task('evidence_extraction'),
      withExtraction({ outcome_concept_id: '78000000-0000-4000-8000-0000000000ff' }),
    )
    expect(problem).toMatch(/endepunkt/)
  })

  it('avviser et virkestoff utenfor oppgaven', () => {
    const problem = handoffResultProblem(
      task('evidence_extraction'),
      withExtraction({ intervention_drug_id: '78000000-0000-4000-8000-0000000000ff' }),
    )
    expect(problem).toMatch(/virkestoff/)
  })

  it('avviser et kildeutdrag som ikke står i teksten', () => {
    const result = resultFor('evidence_extraction')
    const groundings = (result['field_groundings'] as Record<string, unknown>[]).map(
      (grounding, index) =>
        index === 0
          ? {
              ...grounding,
              source_excerpt: 'Denne setningen står ikke i artikkelen i det hele tatt.',
            }
          : grounding,
    )
    const problem = handoffResultProblem(task('evidence_extraction'), {
      ...result,
      field_groundings: groundings,
    })
    expect(problem).toMatch(/ordrett/)
  })

  // Et utsnitt som begynner inne i et ord, er ordrett til stede og likevel
  // ubrukelig som kontrollgrunnlag (`source-excerpt.ts`).
  it('avviser et utdrag som begynner midt i et ord', () => {
    const result = resultFor('evidence_extraction')
    const groundings = (result['field_groundings'] as Record<string, unknown>[]).map(
      (grounding, index) =>
        index === 0
          ? {
              ...grounding,
              source_excerpt: 'ean weight change from baseline was 0.8 kg in the testmiddel arm',
            }
          : grounding,
    )
    const problem = handoffResultProblem(task('evidence_extraction'), {
      ...result,
      field_groundings: groundings,
    })
    expect(problem).not.toBeNull()
  })

  it('avviser et utkast med et ukjent felt', () => {
    expect(
      handoffResultProblem(task('evidence_extraction'), {
        ...resultFor('evidence_extraction'),
        notat: 'ekstra',
      }),
    ).toMatch(/ukjente felter/)
  })

  it('sier fra når oppgaven ikke bar noen kildetekst', () => {
    const payload = taskPayload('evidence_extraction')
    const input = payload['input'] as Record<string, unknown>
    const without = parseAgentTask({
      ...payload,
      input: { ...input, representation_text: '' },
    })
    expect(handoffResultProblem(without, resultFor('evidence_extraction'))).toMatch(/kildetekst/)
  })
})

describe('synteseutkastet', () => {
  it('godtar et utkast som bygger på evidensfunnene i oppgaven', () => {
    expect(handoffResultProblem(task('claim_synthesis'), resultFor('claim_synthesis'))).toBeNull()
  })

  it('avviser en lenke til et evidensfunn utenfor oppgaven', () => {
    const result = resultFor('claim_synthesis')
    const links = [
      {
        ...(result['evidence_links'] as Record<string, unknown>[])[0],
        evidence_item_id: TEST_OTHER_EVIDENCE_ID,
      },
    ]
    expect(
      handoffResultProblem(task('claim_synthesis'), { ...result, evidence_links: links }),
    ).toMatch(/ikke står i oppgaven/)
  })

  it('avviser det samme funnet ført to ganger', () => {
    const result = resultFor('claim_synthesis')
    const first = (result['evidence_links'] as Record<string, unknown>[])[0]
    expect(
      handoffResultProblem(task('claim_synthesis'), {
        ...result,
        evidence_links: [first, { ...first, evidence_item_id: TEST_EVIDENCE_ID }],
      }),
    ).toMatch(/mer enn én gang/)
  })

  // Avgrensningen er redaktørens, ikke modellens: et svar som oppga sitt eget
  // tema, kunne flyttet påstanden uten at noe i kjeden merket det.
  it('avviser et utkast som oppgir avgrensningen selv', () => {
    const result = resultFor('claim_synthesis')
    const claim = result['claim'] as Record<string, unknown>
    expect(
      handoffResultProblem(task('claim_synthesis'), {
        ...result,
        claim: { ...claim, topic_concept_id: TEST_OUTCOME_ID },
      }),
    ).toMatch(/oppgaven/)
  })

  // Evidenssettet er redaktørens avgrensning. Et utkast som utelot et funn —
  // typisk det som MOTSIER påstanden — ville gitt en syntese som hvilte på et
  // annet grunnlag enn det som finnes, uten at noe sa fra.
  it('krever at hvert evidensfunn i oppgaven har en relasjon til påstanden', () => {
    const payload = taskPayload('claim_synthesis')
    const binding = payload['binding'] as Record<string, unknown>
    const bindingInput = binding['input'] as Record<string, unknown>
    const twoItems = parseAgentTask({
      ...payload,
      binding: {
        ...binding,
        input: {
          ...bindingInput,
          evidence: [
            { evidence_item_id: TEST_EVIDENCE_ID, content_hash: `sha256:${'9'.repeat(64)}` },
            { evidence_item_id: TEST_OTHER_EVIDENCE_ID, content_hash: `sha256:${'8'.repeat(64)}` },
          ],
        },
      },
    })

    // Utkastet lenker bare til det ene.
    expect(handoffResultProblem(twoItems, resultFor('claim_synthesis'))).toMatch(/mangler 1 av/)

    const result = resultFor('claim_synthesis')
    const first = (result['evidence_links'] as Record<string, unknown>[])[0]
    expect(
      handoffResultProblem(twoItems, {
        ...result,
        evidence_links: [
          first,
          { ...first, evidence_item_id: TEST_OTHER_EVIDENCE_ID, relationship_type: 'contradicts' },
        ],
      }),
    ).toBeNull()
  })

  it('avviser en populasjon utenfor oppgavens avgrensning', () => {
    const result = resultFor('claim_synthesis')
    const claim = result['claim'] as Record<string, unknown>
    expect(
      handoffResultProblem(task('claim_synthesis'), {
        ...result,
        claim: { ...claim, population_id: '78000000-0000-4000-8000-0000000000ff' },
      }),
    ).toMatch(/populasjon/)
  })

  it('avviser en påstand uten usikkerhetstekst', () => {
    const result = resultFor('claim_synthesis')
    const claim = { ...(result['claim'] as Record<string, unknown>) }
    delete claim['uncertainty_summary']
    expect(handoffResultProblem(task('claim_synthesis'), { ...result, claim })).toMatch(
      /uncertainty_summary/,
    )
  })
})

describe('vurderingsutkastet', () => {
  it('godtar en vurdering med alle domener bedømt', () => {
    expect(
      handoffResultProblem(task('evidence_assessment'), resultFor('evidence_assessment')),
    ).toBeNull()
  })

  it('avviser en sikkerhetsgrad uten alle fem GRADE-domener', () => {
    const result = resultFor('evidence_assessment')
    const assessment = { ...(result['assessment'] as Record<string, unknown>) }
    delete assessment['imprecision']
    expect(handoffResultProblem(task('evidence_assessment'), { ...result, assessment })).toMatch(
      /GRADE-domene/,
    )
  })

  // «Ingen vurderbar evidens» er en vurdert tilstand og ikke en femte grad:
  // finnes det ingenting å gradere ned fra, skal domenene stå tomme og
  // evidence_gap si hva som mangler (ANTIDEP_CONSTITUTION.md regel 4).
  it('avviser «ingen vurderbar evidens» uten evidence_gap', () => {
    expect(
      handoffResultProblem(task('evidence_assessment'), {
        assessment: {
          framework: 'grade',
          certainty_level: 'no_assessable_evidence',
          risk_of_bias: null,
          inconsistency: null,
          indirectness: null,
          imprecision: null,
          publication_bias: null,
          other_considerations: null,
          rationale: 'Grunnlaget lar seg ikke gradere.',
          evidence_gap: null,
        },
      }),
    ).toMatch(/evidence_gap/)
  })
})

describe('roller med autoritativ databasevalidering', () => {
  for (const role of [
    'source_discovery',
    'source_quality_assessment',
    'monograph_answer',
  ] as const) {
    it(`sender et gyldig ${role}-resultat videre uten å lese det som en evidensvurdering`, () => {
      expect(handoffResultProblem(task(role), resultFor(role))).toBeNull()
    })
  }
})
