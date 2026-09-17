import { describe, expect, it } from 'vitest'

import {
  decisionOutcomeSentence,
  decisionProblem,
  newEvidenceSentence,
  parseClaimRevisionOutcome,
  parseClaimRevisionQueue,
  parseClaimRevisionTask,
} from './claim-revision'

function finding(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
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

function article(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    article_title: 'Sertraline and sleep in adults',
    article_authors: 'Testforfatter m.fl.',
    published_year: 2026,
    findings: [finding()],
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
    newer_unpublished_revision: false,
    certainty_level: 'low',
    existing_evidence_count: 1,
    new_article_count: 1,
    new_finding_count: 2,
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
    expect(entry?.newArticleCount).toBe(1)
    expect(entry?.newFindingCount).toBe(2)
    expect(entry?.published).toBe(true)
    expect(entry?.newerUnpublishedRevision).toBe(false)
    // Køen bærer ikke forskningen: den avgjørelsen tas på oppgavens egen side.
    expect(entry?.newEvidence).toEqual([])
  })

  it('leser hele oppgaven med hver ny artikkel, og funnene under den', () => {
    // To funn fra den samme artikkelen er én artikkel, ikke to: en liste som
    // viste funn som om de var artikler, ville vist den samme studien to ganger
    // og latt den telle to ganger i vurderingen.
    const read = parseClaimRevisionTask(
      task({
        new_evidence: [article({ findings: [finding(), finding({ finding: 'Et funn til.' })] })],
      }),
    )
    expect(read.newEvidence).toHaveLength(1)
    expect(read.newEvidence[0]?.articleTitle).toBe('Sertraline and sleep in adults')
    expect(read.newEvidence[0]?.findings).toHaveLength(2)
    expect(read.newEvidence[0]?.findings[0]?.participants).toBe(120)
    expect(read.newEvidence[0]?.findings[0]?.estimate).toBe(-0.4)
  })

  it('leser en verdi kilden ikke oppgir, som fravær og aldri som null', () => {
    const read = parseClaimRevisionTask(
      task({
        uncertainty_summary: null,
        certainty_level: null,
        new_evidence: [
          article({
            published_year: null,
            findings: [
              finding({
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
        ],
      }),
    )
    expect(read.uncertaintySummary).toBeNull()
    expect(read.certaintyLevel).toBeNull()
    expect(read.newEvidence[0]?.publishedYear).toBeNull()
    expect(read.newEvidence[0]?.findings[0]?.estimate).toBeNull()
    expect(read.newEvidence[0]?.findings[0]?.population).toBeNull()
  })

  // Et svar som ikke stemmer med kontrakten, skal stoppe her — ikke bli til en
  // oppgave som mangler noe uten at noen merket det.
  it.each([
    ['ikke en liste', {}],
    ['en manglende referanse', [task({ reference: '' })]],
    ['et manglende evidensgrunnlag', [task({ evidence_basis: '' })]],
    ['et antall som ikke er et tall', [task({ new_finding_count: 'to' })]],
    ['en publiseringstilstand som ikke er boolsk', [task({ published: 'ja' })]],
    ['en ukjent nyere formulering', [task({ newer_unpublished_revision: null })]],
    ['en ny forskning som ikke er en liste', [task({ new_evidence: 'noe' })]],
    ['en artikkel uten funn', [task({ new_evidence: [article({ findings: [] })] })]],
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
  // Artikler og funn er to tall, og setningen sier begge når de er forskjellige:
  // én studie kan bære flere funn, og «to nye studier» og «to nye funn» er ikke
  // det samme for den som skal vurdere hvor mye ny kunnskap som finnes.
  it('sier hvor mye ny forskning som venter, i tall en kan lese', () => {
    expect(
      newEvidenceSentence(
        parseClaimRevisionTask(task({ new_article_count: 1, new_finding_count: 1 })),
      ),
    ).toBe('Én ny forskningsartikkel er kommet til siden påstanden sist ble formulert.')
    expect(
      newEvidenceSentence(
        parseClaimRevisionTask(task({ new_article_count: 1, new_finding_count: 2 })),
      ),
    ).toBe('Én ny forskningsartikkel med 2 funn er kommet til siden påstanden sist ble formulert.')
    expect(
      newEvidenceSentence(
        parseClaimRevisionTask(task({ new_article_count: 3, new_finding_count: 3 })),
      ),
    ).toContain('3 nye forskningsartikler er kommet til')
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
