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

describe('kilde- og monografisvar', () => {
  for (const role of [
    'source_discovery',
    'source_quality_assessment',
    'monograph_answer',
  ] as const) {
    it(`godtar et gyldig ${role}-resultat uten å lese det som en evidensvurdering`, () => {
      expect(handoffResultProblem(task(role), resultFor(role))).toBeNull()
    })
  }

  // ------------------------------------------------------------------------
  // Migrasjon 013v: kildeleddene utfører ikke søk, og kan ikke hevde at de
  // gjorde det. Dette er den ene regelen hele omleggingen hviler på.
  // ------------------------------------------------------------------------
  for (const role of ['source_discovery', 'source_quality_assessment'] as const) {
    it(`lar ikke et ${role}-svar fremstille et modellrapportert søk som utført`, () => {
      const problem = handoffResultProblem(task(role), {
        ...resultFor(role),
        searches: [
          {
            platform: 'PubMed',
            query_string: 'testmiddel[tiab]',
            outcome: 'executed',
            result_count: 12,
          },
        ],
      })

      expect(problem).toMatch(/rapporterer utførte søk/)
      expect(problem).toMatch(/maskinelt bekreftet/)
    })

    it(`lar ikke et ${role}-svar legge til en kandidatkilde uten oppdagelsesvei`, () => {
      expect(
        handoffResultProblem(task(role), {
          ...resultFor(role),
          candidates: [
            {
              identifier_kind: 'doi',
              identifier_value: '10.1000/husket-fra-hukommelsen',
              title: 'En kilde ingen søk fant',
              discovery_path: 'Hukommelsen',
            },
          ],
        }),
      ).toMatch(/legger til kandidatkilder/)
    })
  }

  it('avviser en vesentlig kilde uten begrunnelse før databaseskriving', () => {
    const result = resultFor('source_discovery')
    const appraisals = [...(result['candidate_appraisals'] as Record<string, unknown>[])]
    appraisals[0] = { ...appraisals[0], could_change_conclusion: true, materiality_reason: null }

    expect(
      handoffResultProblem(task('source_discovery'), {
        ...result,
        candidate_appraisals: appraisals,
      }),
    ).toMatch(/materiality_reason/)
  })

  it('avviser en søkeforespørsel mot en tjeneste Antidep ikke kaller', () => {
    expect(
      handoffResultProblem(task('source_discovery'), {
        ...resultFor('source_discovery'),
        search_requests: [{ rationale: 'Trenger et bredere søk.', platform: 'Et internt arkiv' }],
      }),
    ).toMatch(/platform/)
  })

  it('avviser en søketerm som ikke har formen en søkestreng kan bære', () => {
    expect(
      handoffResultProblem(task('source_discovery'), {
        ...resultFor('source_discovery'),
        search_requests: [{ rationale: 'Synonymsøk.', query_terms: ['sertralin" OR alt annet'] }],
      }),
    ).toMatch(/query_terms/)
  })

  it('avviser et virkestoffsynonym som ikke har formen en søkestreng kan bære', () => {
    expect(
      handoffResultProblem(task('source_discovery'), {
        ...resultFor('source_discovery'),
        search_requests: [{ rationale: 'Engelsk navn.', drug_aliases: ['sertraline" OR alt'] }],
      }),
    ).toMatch(/drug_aliases/)
  })

  it('godtar en søkeforespørsel med virkestoffsynonymer', () => {
    expect(
      handoffResultProblem(task('source_discovery'), {
        ...resultFor('source_discovery'),
        search_requests: [
          {
            rationale: 'Det engelske navnet er ikke søkt ennå.',
            strategy: 'targeted',
            drug_aliases: ['sertraline'],
          },
        ],
      }),
    ).toBeNull()
  })

  it('godtar et smalere søk som oppgir runden det erstatter, og avviser noe som ikke er en referanse', () => {
    const narrower = {
      rationale: 'Det brede fritekstsøket er avkortet; dette er den delen som gjelder spørsmålet.',
      method: 'keyword',
      platform: 'PubMed',
      query_terms: ['weight gain'],
      narrows_request: '0123456789abcdef0123456789abcdef',
    }
    expect(
      handoffResultProblem(task('source_discovery'), {
        ...resultFor('source_discovery'),
        search_requests: [narrower],
      }),
    ).toBeNull()
    expect(
      handoffResultProblem(task('source_discovery'), {
        ...resultFor('source_discovery'),
        search_requests: [{ ...narrower, narrows_request: 'det brede søket' }],
      }),
    ).toMatch(/narrows_request/)
  })

  it('lar ikke kontrollen erklære sin egen uavhengighet', () => {
    const result = resultFor('source_quality_assessment')
    const control = result['control'] as Record<string, unknown>

    expect(
      handoffResultProblem(task('source_quality_assessment'), {
        ...result,
        control: { ...control, searched_independently: true },
      }),
    ).toMatch(/erklærer selv at den søkte uavhengig/)
  })

  it('avviser feil type i kontrollens boolske felt før databaseskriving', () => {
    const result = resultFor('source_quality_assessment')
    const control = result['control'] as Record<string, unknown>

    expect(
      handoffResultProblem(task('source_quality_assessment'), {
        ...result,
        control: { ...control, materiality_assessed: 'ja' },
      }),
    ).toMatch(/materiality_assessed.*sann\/usann/)
  })

  it('lar ikke kontrollen be om flere motsøk og avgjøre i det samme svaret', () => {
    const result = resultFor('source_quality_assessment')

    expect(
      handoffResultProblem(task('source_quality_assessment'), {
        ...result,
        search_requests: [{ rationale: 'Trenger et motsøk i et forsøksregister.' }],
      }),
    ).toMatch(/ber om flere søk og avgjør/)
  })

  it('krever at en kontrollrunde enten avgjør eller ber om flere motsøk', () => {
    const result = { ...resultFor('source_quality_assessment') }
    delete result['control']

    expect(handoffResultProblem(task('source_quality_assessment'), result)).toMatch(
      /verken avgjør dekningen eller ber om flere motsøk/,
    )
  })

  it('godtar en kontrollrunde som bare ber om flere motsøk', () => {
    const result = { ...resultFor('source_quality_assessment') }
    delete result['control']

    expect(
      handoffResultProblem(task('source_quality_assessment'), {
        ...result,
        search_requests: [
          {
            rationale: 'Et målrettet motsøk mot forsøksregistre mangler.',
            strategy: 'targeted',
            query_terms: ['trial registry'],
          },
        ],
      }),
    ).toBeNull()
  })

  it('avviser structured_value som ikke er et objekt', () => {
    const result = resultFor('monograph_answer')
    const answer = result['answer'] as Record<string, unknown>

    expect(
      handoffResultProblem(task('monograph_answer'), {
        ...result,
        answer: { ...answer, structured_value: '50 mg' },
      }),
    ).toMatch(/structured_value.*objekt/)
  })

  it('avviser ugyldige monografidatoer før databaseskriving', () => {
    const result = resultFor('monograph_answer')
    const answer = result['answer'] as Record<string, unknown>

    expect(
      handoffResultProblem(task('monograph_answer'), {
        ...result,
        answer: { ...answer, as_of: '2026-02-30' },
      }),
    ).toMatch(/as_of.*gyldig dato/)
  })

  it('avviser ugyldig kilde-id i en tilleggskilde før databaseskriving', () => {
    const result = resultFor('monograph_answer')
    const answer = result['answer'] as Record<string, unknown>

    expect(
      handoffResultProblem(task('monograph_answer'), {
        ...result,
        answer: {
          ...answer,
          additional_sources: [
            {
              source_version_id: 'ikke-en-uuid',
              source_quote: 'Ordrett sitat.',
              source_locator: 'Avsnitt 1',
              as_of: '2026-09-22',
            },
          ],
        },
      }),
    ).toMatch(/source_version_id.*uuid/)
  })
})
