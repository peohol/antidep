import { describe, expect, it } from 'vitest'

import {
  decisionOutcomeSentence,
  decisionProblem,
  newEvidenceSentence,
  parseClaimRevisionOutcome,
  parseClaimRevisionQueue,
  parseClaimRevisionTask,
} from './claim-revision'

function evidence(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    article_title: 'Sertraline and sleep in adults',
    article_authors: 'Testforfatter m.fl.',
    published_year: 2026,
    study_design: 'randomized_controlled_trial',
    population: 'voksne med depressiv lidelse',
    population_detail: 'Voksne med moderat depresjon.',
    participants: 120,
    finding: 'Kortere søvn ved 12 uker.',
    direction: 'decrease',
    effect_measure: 'mean_change',
    estimate: -0.4,
    estimate_unit: 'kg',
    ci_lower: -0.9,
    ci_upper: 0.1,
    ci_level_percent: 95,
    limitations: 'Åpen oppfølging.',
    ...overrides,
  }
}

function task(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    reference: '9f2c1a4b8e6d0c3a5b7f9e1d',
    subject_drug: 'sertralin',
    topic: 'søvnlengde',
    statement: 'Sertralin er forbundet med noe lengre søvn.',
    scope: 'Gjelder voksne.',
    uncertainty_summary: 'Lite materiale.',
    revision_number: 1,
    published: true,
    certainty_level: 'low',
    existing_evidence_count: 1,
    new_evidence_count: 2,
    noticed_at: '2026-09-30T09:00:00+00:00',
    evidence_basis: `sha256-v1:${'a'.repeat(64)}`,
    ...overrides,
  }
}

describe('lesingen av en revisjonsoppgave', () => {
  it('leser køen uten den nye forskningen, som databasen svarer den', () => {
    const [entry] = parseClaimRevisionQueue([task()])
    expect(entry?.reference).toBe('9f2c1a4b8e6d0c3a5b7f9e1d')
    expect(entry?.subjectDrug).toBe('sertralin')
    expect(entry?.newEvidenceCount).toBe(2)
    expect(entry?.published).toBe(true)
    // Køen bærer ikke forskningen: den avgjørelsen tas på oppgavens egen side.
    expect(entry?.newEvidence).toEqual([])
  })

  it('leser hele oppgaven med hver ny artikkel', () => {
    const read = parseClaimRevisionTask(task({ new_evidence: [evidence()] }))
    expect(read.newEvidence).toHaveLength(1)
    expect(read.newEvidence[0]?.articleTitle).toBe('Sertraline and sleep in adults')
    expect(read.newEvidence[0]?.participants).toBe(120)
    expect(read.newEvidence[0]?.estimate).toBe(-0.4)
  })

  it('leser en verdi kilden ikke oppgir, som fravær og aldri som null', () => {
    const read = parseClaimRevisionTask(
      task({
        uncertainty_summary: null,
        certainty_level: null,
        new_evidence: [
          evidence({
            published_year: null,
            estimate: null,
            estimate_unit: null,
            effect_measure: null,
            ci_lower: null,
            ci_upper: null,
            ci_level_percent: null,
            limitations: null,
            population: null,
          }),
        ],
      }),
    )
    expect(read.uncertaintySummary).toBeNull()
    expect(read.certaintyLevel).toBeNull()
    expect(read.newEvidence[0]?.estimate).toBeNull()
    expect(read.newEvidence[0]?.population).toBeNull()
  })

  // Et svar som ikke stemmer med kontrakten, skal stoppe her — ikke bli til en
  // oppgave som mangler noe uten at noen merket det.
  it.each([
    ['ikke en liste', {}],
    ['en manglende referanse', [task({ reference: '' })]],
    ['et manglende evidensgrunnlag', [task({ evidence_basis: '' })]],
    ['et antall som ikke er et tall', [task({ new_evidence_count: 'to' })]],
    ['en publiseringstilstand som ikke er boolsk', [task({ published: 'ja' })]],
    ['en ny forskning som ikke er en liste', [task({ new_evidence: 'noe' })]],
  ])('avviser %s', (_what, value) => {
    expect(() => parseClaimRevisionQueue(value)).toThrow(/Revisjonsoppgaven er ugyldig/)
  })

  it('leser utfallet av en avgjørelse', () => {
    const outcome = parseClaimRevisionOutcome({
      reference: 'abc',
      decision: 'revise',
      recorded: true,
    })
    expect(outcome).toEqual({ reference: 'abc', decision: 'revise', recorded: true })
  })
})

describe('det redaktøren får se og gjøre', () => {
  it('sier hvor mye ny forskning som venter, i tall en kan lese', () => {
    expect(newEvidenceSentence(parseClaimRevisionTask(task({ new_evidence_count: 1 })))).toContain(
      'Én ny forskningsartikkel',
    )
    expect(newEvidenceSentence(parseClaimRevisionTask(task({ new_evidence_count: 3 })))).toContain(
      '3 nye forskningsartikler',
    )
  })

  // Begrunnelsen er det som gjør «endrer ikke påstanden» til en faglig
  // konklusjon framfor til en utsettelse. Å beslutte revisjon trenger den ikke:
  // der er avgjørelsen selv innholdet.
  it('krever en begrunnelse bare for konklusjonen om at ingenting endres', () => {
    expect(decisionProblem('set_aside', '   ')).toContain('hvorfor')
    expect(decisionProblem('set_aside', 'Peker samme vei.')).toBeNull()
    expect(decisionProblem('revise', '')).toBeNull()
  })

  it('sier hva som skjedde, uten en eneste teknisk verdi', () => {
    const revised = decisionOutcomeSentence({
      reference: 'abc',
      decision: 'revise',
      recorded: true,
    })
    expect(revised).toContain('sluttkontroll')
    expect(revised.toLowerCase()).not.toContain('jobb')
    expect(revised.toLowerCase()).not.toContain('agent')
    expect(revised.toLowerCase()).not.toContain('sha256')

    // En gjentatt avgjørelse er ikke en feil: to redaktører som trykket
    // samtidig, har begge gjort riktig.
    const repeated = decisionOutcomeSentence({
      reference: 'abc',
      decision: 'revise',
      recorded: false,
    })
    expect(repeated).toContain('allerede')
    expect(repeated.toLowerCase()).not.toContain('feil')

    expect(
      decisionOutcomeSentence({ reference: 'abc', decision: 'set_aside', recorded: true }),
    ).toContain('står som den står')
  })
})
