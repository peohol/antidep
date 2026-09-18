// ============================================================================
// Kontrollen av hvordan monografien sies på norsk
//
// To ting prøves her, og de er forskjellige.
//
// Det første er at flaten kjenner hele vokabularet. Tilstandene finnes i
// databasen som enum-typer, og en ny verdi der uten en tekst her ville blitt
// vist som «ukjent tilstand» til en kliniker. Prøven leser derfor
// migrasjonsfilene på nytt og krever at hver eneste verdi har fått et tegn og
// en tekst — den samme formen for avviksvern som `standard.test.ts` har mot
// `docs/MONOGRAPH_STANDARD.md`.
//
// Det andre er at de seks dimensjonene holdes fra hverandre i ordene også.
// «Venter på tilgang» og «teknisk stopp» er ikke faglige konklusjoner, og
// teksten deres må si det. Det er ikke en stilsak: en flate som lot en
// betalingsmur se ut som «ingen relevante studier», ville løyet om
// kunnskapsgrunnlaget (ANTIDEP_CONSTITUTION.md regel 4).
// ============================================================================

import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

import {
  blockedSummary,
  certaintyLabel,
  completionLabel,
  knowledgeTypeLabel,
  outcomePresentation,
  parseMonographCoverage,
  parseMonographDraft,
  parseMonographOrders,
  parseMonographProposals,
  parseMonographRequests,
  proposalLabel,
  relevancePresentation,
  workStatePresentation,
  type MonographCoverage,
} from './monograph.ts'

const ORDER_MIGRATION = 'supabase/migrations/20261003092000_monograph_order_and_coverage.sql'
const EDITORIAL_MIGRATION = 'supabase/migrations/20261008090000_monograph_editorial_control.sql'
const ANSWER_MIGRATION = 'supabase/migrations/20261006090000_monograph_answers.sql'

/**
 * Leser verdiene i én enum-type ut av en migrasjon.
 *
 * Egen, enkel avlesning framfor en delt hjelpefunksjon med kildekoden: to
 * uavhengige avlesninger kan vise at de er enige, mens én felles ville vist at
 * den er enig med seg selv.
 */
function enumValues(file: string, name: string): readonly string[] {
  const sql = readFileSync(file, 'utf8')
  const match = new RegExp(`create type ${name} as enum \\(([^)]*)\\)`, 'i').exec(sql)
  if (match === null) {
    throw new Error(`Fant ikke typen ${name} i ${file}.`)
  }
  return [...(match[1] ?? '').matchAll(/'([a-z_]+)'/g)].map((row) => row[1] ?? '')
}

describe('tilstandene', () => {
  it('har et tegn og en tekst for hver arbeidstilstand databasen kjenner', () => {
    const states = enumValues(ORDER_MIGRATION, 'knowledge\\.monograph_work_state')
    expect(states.length).toBe(8)
    for (const state of states) {
      const shown = workStatePresentation(state)
      expect(shown.label).not.toBe('Ukjent tilstand')
      expect(shown.symbol.length).toBeGreaterThan(0)
      expect(shown.note.length).toBeGreaterThan(0)
    }
  })

  it('har et tegn og en tekst for hvert faglig utfall databasen kjenner', () => {
    const outcomes = enumValues(ORDER_MIGRATION, 'knowledge\\.monograph_outcome')
    expect(outcomes.length).toBe(5)
    for (const outcome of outcomes) {
      expect(outcomePresentation(outcome).label).not.toBe('Ukjent tilstand')
    }
  })

  it('har et tegn og en tekst for hver relevansverdi databasen kjenner', () => {
    const values = enumValues(ORDER_MIGRATION, 'knowledge\\.monograph_relevance')
    expect(values.length).toBe(3)
    for (const value of values) {
      expect(relevancePresentation(value).label).not.toBe('Ukjent tilstand')
    }
  })

  it('har en tekst for hvert avvik databasen kan lage', () => {
    for (const kind of enumValues(EDITORIAL_MIGRATION, 'workflow\\.monograph_proposal_kind')) {
      expect(proposalLabel(kind)).not.toBe(kind)
    }
  })

  it('har en tekst for hver kunnskapstype et svar kan ha', () => {
    const types = enumValues(ANSWER_MIGRATION, 'knowledge\\.monograph_knowledge_type')
    expect(types.length).toBeGreaterThan(0)
    for (const type of types) {
      expect(knowledgeTypeLabel(type)).not.toBe(type)
    }
  })

  // En verdi ingen har skrevet en tekst for, skal vises som ukjent — ikke
  // gjettes på, og ikke skjules. Et skjult felt er en usann visning.
  it('viser en ukjent verdi som ukjent framfor å gjette', () => {
    expect(workStatePresentation('noe_helt_nytt').label).toBe('Ukjent tilstand')
    expect(outcomePresentation('noe_helt_nytt').label).toBe('Ukjent tilstand')
    expect(relevancePresentation('noe_helt_nytt').label).toBe('Ukjent tilstand')
    expect(knowledgeTypeLabel('noe_helt_nytt')).toBe('noe_helt_nytt')
  })

  // Tegnene er forskjellige *former*, ikke bare forskjellige farger: de må
  // skille seg også i svart-hvitt (WCAG 1.4.1).
  it('skiller tilstandene på tegn og tekst, ikke på farge alene', () => {
    const states = enumValues(ORDER_MIGRATION, 'knowledge\\.monograph_work_state')
    const labels = states.map((state) => workStatePresentation(state).label)
    expect(new Set(labels).size).toBe(labels.length)

    // De fire tonene deles av flere tilstander. Det er greit så lenge tegnet
    // eller teksten skiller dem — fargen alene gjør det ikke.
    const blocked = states
      .map((state) => workStatePresentation(state))
      .filter((shown) => shown.tone === 'blocked')
    expect(blocked.length).toBeGreaterThan(1)
    expect(new Set(blocked.map((shown) => shown.symbol)).size).toBe(blocked.length)
  })

  // Dette er hele poenget med at de seks dimensjonene er atskilt: en
  // tilgangsbegrensning, en avklaring og en teknisk feil sier ingenting om
  // kunnskapen, og teksten må si nettopp det.
  it('sier uttrykkelig at en blokkering ikke er en konklusjon om kunnskapen', () => {
    for (const state of ['awaiting_access', 'awaiting_clarification', 'technical_stop']) {
      expect(workStatePresentation(state).note).toContain('ikke en konklusjon om kunnskapen')
    }
  })

  it('holder «ingen kvalifiserende studier» som et resultat og ikke som et hull', () => {
    const shown = outcomePresentation('no_qualifying_evidence')
    expect(shown.tone).toBe('done')
    expect(shown.note).toContain('ikke et hull i arbeidet')
  })

  it('sier at uavklart relevans ikke er det samme som ikke relevant', () => {
    const shown = relevancePresentation('undetermined')
    expect(shown.label).toBe('Uavklart relevans')
    expect(shown.note).toContain('ikke det samme som')
    expect(shown.tone).not.toBe('done')
  })

  it('oversetter evidenssikkerhet, og lar et manglende nivå være manglende', () => {
    expect(certaintyLabel('very_low')).toBe('Svært lav sikkerhet')
    expect(certaintyLabel(null)).toBeNull()
    expect(certaintyLabel('noe_annet')).toBe('noe_annet')
  })
})

// ----------------------------------------------------------------------------
// Dekningen
// ----------------------------------------------------------------------------

const COVERAGE = {
  edition: {
    reference: '3c7a1f5e9b2d4a6c8e0f1a3b',
    drug: 'sertralin',
    standard_version: '2026.1',
    edition_no: 1,
    ordered_at: '2026-09-01T10:00:00+00:00',
  },
  needs: {
    total: 92,
    relevant: 70,
    justified_not_applicable: 12,
    undetermined_relevance: 10,
    answered: 31,
    reviewed_gaps: 7,
    open: 32,
  },
  blocked: { awaiting_access: 4, awaiting_clarification: 1, technical_stop: 2 },
  work_coverage: { handled: 50, denominator: 92, percent: 54 },
  completion: { level: 'coverage_map', partial: true },
} as const

describe('dekningen', () => {
  it('leser tellingene hver for seg, uten å slå dem sammen', () => {
    const coverage = parseMonographCoverage(COVERAGE)
    expect(coverage.drug).toBe('sertralin')
    expect(coverage.counts.total).toBe(92)
    expect(coverage.counts.answered).toBe(31)
    expect(coverage.counts.reviewedGaps).toBe(7)
    expect(coverage.counts.justifiedNotApplicable).toBe(12)
    expect(coverage.counts.undeterminedRelevance).toBe(10)
    expect(coverage.counts.open).toBe(32)
    expect(coverage.blocked.awaitingAccess).toBe(4)
    expect(coverage.partial).toBe(true)
  })

  // Malene er ikke behovene, og nevneren er behovslisten for denne utgaven.
  //
  // De to inndelingene er forskjellige spørsmål, og hver av dem går opp for seg
  // selv. Relevans deler *hele* listen i tre; det faglige utfallet deler bare de
  // relevante. En prøve som la dem sammen i én sum, ville krevd at flaten blandet
  // to dimensjoner den nettopp holder fra hverandre.
  it('regner dekningen ut av behovslisten og ikke av antallet maler', () => {
    const coverage = parseMonographCoverage(COVERAGE)
    expect(
      coverage.counts.relevant +
        coverage.counts.justifiedNotApplicable +
        coverage.counts.undeterminedRelevance,
    ).toBe(coverage.counts.total)
    expect(coverage.counts.answered + coverage.counts.reviewedGaps + coverage.counts.open).toBe(
      coverage.counts.relevant,
    )
    expect(coverage.denominator).toBe(coverage.counts.total)
  })

  // Uavklart relevans forsvinner ikke inn i en annen telling. Den har sin egen,
  // og den er verken «ikke relevant» eller «åpen».
  it('lar uavklart relevans stå som sin egen telling', () => {
    const coverage = parseMonographCoverage(COVERAGE)
    expect(coverage.counts.undeterminedRelevance).toBe(10)
    expect(coverage.counts.undeterminedRelevance).not.toBe(0)
    expect(coverage.counts.open).not.toBe(
      coverage.counts.open + coverage.counts.undeterminedRelevance,
    )
  })

  it('skiller standardens fullføringsnivåer fra hverandre', () => {
    const at = (level: string): MonographCoverage =>
      parseMonographCoverage({
        ...COVERAGE,
        completion: { level, partial: level !== 'agent_complete' },
      })
    expect(completionLabel(at('no_coverage_map'))).toBe('Ingen kunnskapsbehov opprettet ennå')
    expect(completionLabel(at('coverage_map'))).toBe('Dekningskart under arbeid')
    expect(completionLabel(at('agent_complete'))).toBe('Alle spørsmål er behandlet av Antidep')
  })

  // Et agentferdig dekningskart er ikke et publisert innhold, og teksten lover
  // ikke at det er det.
  it('lover ikke publisering i teksten om et agentferdig kart', () => {
    const label = completionLabel(
      parseMonographCoverage({
        ...COVERAGE,
        completion: { level: 'agent_complete', partial: false },
      }),
    )
    expect(label).not.toContain('ublisert')
    expect(label).not.toContain('odkjent')
  })

  it('sier hva som står i veien, uten å kalle det et faglig utfall', () => {
    const lines = blockedSummary(parseMonographCoverage(COVERAGE))
    expect(lines.length).toBe(3)
    expect(lines[0]).toContain('tilgang')
    expect(lines[1]).toContain('avklaring')
    expect(lines[2]).toContain('teknisk feil')
    for (const line of lines) {
      expect(line).not.toContain('evidens')
      expect(line).not.toContain('ingen relevante studier')
    }
  })

  it('sier ingenting om blokkeringer når ingen finnes', () => {
    const coverage = parseMonographCoverage({
      ...COVERAGE,
      blocked: { awaiting_access: 0, awaiting_clarification: 0, technical_stop: 0 },
    })
    expect(blockedSummary(coverage)).toEqual([])
  })

  it('avviser et svar som ikke er en liste over bestillinger', () => {
    expect(() => parseMonographOrders({ noe: 'annet' })).toThrow(/liste over bestillinger/)
    expect(parseMonographOrders([COVERAGE]).length).toBe(1)
  })

  // Et manglende felt er ikke null: da ville en tom visning sett ut som et
  // gjennomført arbeid uten funn.
  it('avviser en dekning uten utgave', () => {
    expect(() => parseMonographCoverage({ ...COVERAGE, edition: undefined })).toThrow()
  })
})

// ----------------------------------------------------------------------------
// Utkastet
// ----------------------------------------------------------------------------

const DRAFT = {
  edition: { reference: 'abc', drug: 'sertralin', standard_version: '2026.1' },
  sections: [
    {
      section: 'Effekt',
      entries: [
        {
          need_reference: 'n1',
          template_code: 'MN29',
          question: 'Hvor godt virker midlet ved depresjon hos voksne?',
          requirement: 'mandatory',
          scope: 'voksne · depresjon',
          relevance: 'relevant',
          relevance_reason: null,
          work_state: 'agent_complete',
          work_state_note: null,
          outcome: 'answered',
          answer: {
            revision_reference: 'r1',
            revision_number: 2,
            knowledge_type: 'research_finding',
            origin: 'agent',
            statement: 'Effekten er liten til moderat.',
            uncertainty_summary: 'Konfidensintervallet er bredt.',
            limitation_note: null,
            as_of: null,
            recommending_body: null,
            certainty: 'low',
            sources: [],
            evidence_sources: [
              {
                title: 'En studie',
                authors_or_issuer: 'Forfatter mfl.',
                publisher_or_journal: 'Et tidsskrift',
                locator: '10.1000/x',
                as_of: null,
                retrieved_from: null,
              },
            ],
            controlled_fields: ['statement', 'certainty'],
          },
        },
        {
          need_reference: 'n2',
          template_code: 'MN30',
          question: 'Hvor godt virker midlet hos barn?',
          requirement: 'conditional',
          scope: null,
          relevance: 'undetermined',
          relevance_reason: null,
          work_state: 'awaiting_access',
          work_state_note: 'Artikkelen ligger bak en betalingsmur.',
          outcome: null,
          answer: null,
        },
      ],
    },
  ],
  coverage: COVERAGE,
  latest_candidate: null,
  published: null,
} as const

describe('utkastet', () => {
  it('leser seksjonene, spørsmålene og svarene', () => {
    const draft = parseMonographDraft(DRAFT)
    expect(draft.drug).toBe('sertralin')
    expect(draft.sections.length).toBe(1)
    const entries = draft.sections[0]?.entries ?? []
    expect(entries.length).toBe(2)
    expect(entries[0]?.answer?.statement).toBe('Effekten er liten til moderat.')
    expect(entries[0]?.answer?.sources.length).toBe(1)
    expect(entries[0]?.answer?.certainty).toBe('low')
  })

  // Et spørsmål som venter på tilgang, har ikke noe faglig utfall — og skal
  // ikke få et av flaten heller.
  it('lar et blokkert spørsmål stå uten faglig utfall', () => {
    const entry = parseMonographDraft(DRAFT).sections[0]?.entries[1]
    expect(entry?.outcome).toBeNull()
    expect(entry?.answer).toBeNull()
    expect(entry?.workState).toBe('awaiting_access')
    expect(workStatePresentation(entry?.workState ?? '').tone).toBe('blocked')
  })

  it('leser en kandidat og sluttkontrollen hennes når de finnes', () => {
    const draft = parseMonographDraft({
      ...DRAFT,
      latest_candidate: {
        reference: 'k1',
        candidate_no: 3,
        stale_reason: 'Et svar er endret etter at kandidaten ble laget.',
        final_control: {
          decision: 'approved',
          reviewer: 'Navn Navnesen',
          rationale: 'Gjennomgått.',
        },
      },
      published: { candidate_reference: 'k0' },
    })
    expect(draft.latestCandidate?.candidateNo).toBe(3)
    expect(draft.latestCandidate?.staleReason).toContain('endret')
    expect(draft.latestCandidate?.finalControl?.reviewer).toBe('Navn Navnesen')
    expect(draft.publishedCandidate).toBe('k0')
  })

  it('leser et utkast uten kandidat uten å lage en', () => {
    const draft = parseMonographDraft(DRAFT)
    expect(draft.latestCandidate).toBeNull()
    expect(draft.publishedCandidate).toBeNull()
  })
})

// ----------------------------------------------------------------------------
// Det som venter på et menneske
// ----------------------------------------------------------------------------

describe('det som venter på et menneske', () => {
  it('samler begge slags originalmateriale i én liste', () => {
    const requests = parseMonographRequests({
      research_full_text: [
        {
          reference: 'a',
          kind: 'research_full_text',
          title: 'En studie',
          authors_or_issuer: 'Forfatter mfl.',
          publisher_or_journal: 'Et tidsskrift',
          professional_reason: 'Trengs for spørsmålet om effekt hos voksne.',
          access_limitation: 'Betalingsmur hos utgiveren.',
        },
      ],
      authority_documents: [
        {
          reference: 'b',
          kind: 'authority_document',
          title: 'Et preparatomtale',
          authors_or_issuer: 'Legemiddelverket',
          publisher_or_journal: null,
          professional_reason: 'Trengs for styrkene som markedsføres i Norge.',
          access_limitation: null,
        },
      ],
    })
    expect(requests.length).toBe(2)
    expect(requests[0]?.kind).toBe('research_full_text')
    expect(requests[1]?.kind).toBe('authority_document')
    // Den faglige grunnen står i bestillingen, slik at et menneske slipper å
    // gjette hvorfor artikkelen trengs.
    expect(requests[0]?.professionalReason).toContain('effekt')
    expect(requests[0]?.accessLimitation).toContain('Betalingsmur')
  })

  it('tåler et svar uten noen bestillinger', () => {
    expect(parseMonographRequests({ research_full_text: [], authority_documents: [] })).toEqual([])
  })

  it('leser avvikene og sier hva de er på norsk', () => {
    const proposals = parseMonographProposals({
      proposals: [
        {
          reference: 'p1',
          kind: 'locked_answer_challenged',
          template_code: 'MN29',
          question: 'Hvor godt virker midlet ved depresjon hos voksne?',
          scope: 'voksne · depresjon',
          rationale: 'Ny kontrollert evidens motsier det låste svaret.',
          source_title: 'En nyere studie',
        },
        {
          reference: 'p2',
          kind: 'restricted_source_offered',
          template_code: 'MN30',
          question: 'Hvor godt virker midlet hos barn?',
          scope: null,
          rationale: 'Kilden er relevant, men står utenfor de forhåndsgodkjente.',
          source_title: 'En annen studie',
        },
      ],
    })
    expect(proposals.length).toBe(2)
    expect(proposalLabel(proposals[0]?.kind ?? '')).toBe(
      'Nytt kontrollert grunnlag for et låst svar',
    )
    expect(proposalLabel(proposals[1]?.kind ?? '')).toBe(
      'Relevant kilde utenfor de forhåndsgodkjente',
    )
    // Avviket bærer sin egen begrunnelse: det låste innholdet skjermes ikke mot
    // synlig kritikk, og den restriktive kilden skjules ikke.
    expect(proposals[0]?.rationale).toContain('motsier')
    expect(proposals[1]?.sourceTitle).toBe('En annen studie')
  })

  it('tåler et svar uten avvik', () => {
    expect(parseMonographProposals({ proposals: [] })).toEqual([])
  })
})
