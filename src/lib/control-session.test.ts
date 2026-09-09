// ============================================================================
// Utledningen av utfallene, prøvd mot databasens egne regler
//
// Kontrollpåstandene her er de samme som constraintene på
// `workflow.evidence_verifications` og `workflow.claim_verifications` håndhever.
// Går utledningen fra hverandre fra dem, sender flaten noe databasen avviser —
// eller, verre, noe den godtar og som betyr noe annet enn kontrolløren mente.
// ============================================================================

import { describe, expect, it } from 'vitest'
import {
  CONTROL_ANSWER_OPTIONS,
  checkResultFor,
  claimTally,
  deriveClaimVerification,
  deriveExtractionVerification,
  emptyExtractionSessionState,
  extractionTally,
  pruneExtractionSession,
  retainAnswers,
  sourceAccessCanConfirm,
  weakestSourceAccess,
  type AnsweredCheck,
  type AnsweredLink,
} from './control-session'

// Feltene gaten krever dekket (`workflow.required_check_fields`) og de
// feltene kontrolløren faktisk får spørsmål om
// (`workflow.semantic_check_fields`). De to provenansfeltene stilles ikke som
// egne spørsmål; de føres opp som kontrollert når kontrollen ble bekreftet.
const REQUIRED = ['raw_extraction', 'source_locator', 'intervention_arm', 'outcome', 'population']
const SEMANTIC = ['intervention_arm', 'outcome', 'population']

function answers(entries: Record<string, AnsweredCheck['answer']>): Record<string, AnsweredCheck> {
  return Object.fromEntries(
    Object.entries(entries).map(([field, answer]) => [field, { answer, note: '' }]),
  )
}

function allYes(): Record<string, AnsweredCheck> {
  return answers(Object.fromEntries(SEMANTIC.map((field) => [field, 'yes' as const])))
}

describe('svaralternativene', () => {
  it('har alltid «kan ikke avgjøre» med, og har den sist', () => {
    expect(CONTROL_ANSWER_OPTIONS.map((option) => option.value)).toEqual([
      'yes',
      'no',
      'cannot_determine',
    ])
  })
})

describe('deriveExtractionVerification', () => {
  it('bekrefter når alle påkrevde felter stemmer og kilden var tilgjengelig', () => {
    const derived = deriveExtractionVerification({
      requiredFields: REQUIRED,
      semanticFields: SEMANTIC,
      sourceAccess: 'original_source',
      answers: allYes(),
    })
    expect(derived.outcome).toBe('verified')
    // Nøyaktig de feltene gaten krever, og ingen flere: dekningen skal si det
    // den gir inntrykk av å si.
    expect([...derived.checkedFields].sort()).toEqual([...REQUIRED].sort())
    expect(derived.findings).toBeNull()
    expect(derived.rationale).toContain('3 av 3 delkontroller besvart')
  })

  // Begrunnelsen er audittekst. Den skal si hvem som kontrollerte hva, slik at
  // ingen leser dekningen som at mennesket selv prøvde utdragene mot kilden.
  it('sier i begrunnelsen at maskinen beviste utdragene og mennesket semantikken', () => {
    const derived = deriveExtractionVerification({
      requiredFields: REQUIRED,
      semanticFields: SEMANTIC,
      sourceAccess: 'original_source',
      answers: allYes(),
    })
    expect(derived.rationale).toContain('bedømte de semantiske feltene')
    expect(derived.rationale).toContain('deterministiske ekstraksjonskontrollen')
  })

  it('lover ingenting om maskinbeviset når kontrollen ikke er en bekreftelse', () => {
    const derived = deriveExtractionVerification({
      requiredFields: REQUIRED,
      semanticFields: SEMANTIC,
      sourceAccess: 'original_source',
      answers: { ...allYes(), outcome: { answer: 'cannot_determine', note: '' } },
    })
    expect(derived.outcome).not.toBe('verified')
    expect(derived.rationale).not.toContain('deterministiske ekstraksjonskontrollen')
  })

  // evidence_verifications_source_access_check: en bekreftelse kan ikke hvile på
  // et avledet sammendrag alene.
  it('kan ikke bekrefte på et sammendrag fra et annet ledd', () => {
    const derived = deriveExtractionVerification({
      requiredFields: REQUIRED,
      semanticFields: SEMANTIC,
      sourceAccess: 'derived_summary',
      answers: allYes(),
    })
    expect(derived.outcome).toBe('uncertain')
    expect(derived.findings).toContain('bare et sammendrag fra et annet ledd')
  })

  it('blir «må rettes» av ett konkret avvik, og bærer avviksteksten', () => {
    const derived = deriveExtractionVerification({
      requiredFields: REQUIRED,
      semanticFields: SEMANTIC,
      sourceAccess: 'original_source',
      answers: {
        ...allYes(),
        outcome: { answer: 'no', note: 'Kilden måler livskvalitet, ikke vektendring.' },
      },
    })
    expect(derived.outcome).toBe('needs_correction')
    expect(derived.findings).toContain('Kilden måler livskvalitet, ikke vektendring.')
    expect(derived.findings).toContain('Endepunktet')
  })

  it('blir uavklart når noe ikke lot seg avgjøre', () => {
    const derived = deriveExtractionVerification({
      requiredFields: REQUIRED,
      semanticFields: SEMANTIC,
      sourceAccess: 'original_source',
      answers: { ...allYes(), population: { answer: 'cannot_determine', note: '' } },
    })
    expect(derived.outcome).toBe('uncertain')
    expect(derived.findings).toContain('lot seg ikke avgjøre mot kilden')
  })

  it('er uavklart så lenge noe står ubesvart', () => {
    const derived = deriveExtractionVerification({
      requiredFields: REQUIRED,
      semanticFields: SEMANTIC,
      sourceAccess: 'original_source',
      answers: answers({ intervention_arm: 'yes' }),
    })
    expect(derived.outcome).toBe('uncertain')
    expect(derived.findings).toContain('ikke besvart')
  })

  // evidence_verifications_findings_required_check: et annet utfall enn
  // verified krever et funn.
  it('har alltid et funn når utfallet ikke er bekreftet', () => {
    for (const sourceAccess of ['original_source', 'derived_summary']) {
      for (const answer of ['no', 'cannot_determine'] as const) {
        const derived = deriveExtractionVerification({
          requiredFields: REQUIRED,
          semanticFields: SEMANTIC,
          sourceAccess,
          answers: { ...allYes(), outcome: { answer, note: '' } },
        })
        expect(derived.outcome).not.toBe('verified')
        expect(derived.findings).not.toBeNull()
        expect((derived.findings ?? '').trim().length).toBeGreaterThan(0)
      }
    }
  })

  // Et avvik veier tyngre enn noe uavklart: en kontroll som fant en feil, er
  // ikke «uavklart».
  it('lar et avvik veie tyngre enn noe uavklart', () => {
    const derived = deriveExtractionVerification({
      requiredFields: REQUIRED,
      semanticFields: SEMANTIC,
      sourceAccess: 'original_source',
      answers: {
        ...allYes(),
        outcome: { answer: 'no', note: 'Feil endepunkt.' },
        population: { answer: 'cannot_determine', note: '' },
      },
    })
    expect(derived.outcome).toBe('needs_correction')
  })

  it('teller delsvarene', () => {
    expect(
      extractionTally(SEMANTIC, {
        ...allYes(),
        outcome: { answer: 'no', note: '' },
        population: { answer: 'cannot_determine', note: '' },
      }),
    ).toEqual({ total: 3, answered: 3, confirmed: 1, deviations: 1, unresolved: 1 })
  })
})

describe('kildetilgang', () => {
  it('sier at bare et sammendrag ikke kan bære en bekreftelse', () => {
    expect(sourceAccessCanConfirm('original_source')).toBe(true)
    expect(sourceAccessCanConfirm('verifiable_representation')).toBe(true)
    expect(sourceAccessCanConfirm('derived_summary')).toBe(false)
  })

  it('velger den svakeste, og regner en ukjent verdi som svakest', () => {
    expect(weakestSourceAccess(['original_source', 'verifiable_representation'])).toBe(
      'verifiable_representation',
    )
    expect(weakestSourceAccess(['original_source', 'derived_summary'])).toBe('derived_summary')
    expect(weakestSourceAccess(['original_source', 'noe_helt_annet'])).toBe('noe_helt_annet')
    expect(weakestSourceAccess([])).toBeNull()
  })
})

describe('claim-kontrollen', () => {
  const CHECKPOINTS = [
    'sourceSupport',
    'populationMatch',
    'comparatorMatch',
    'timeframeMatch',
    'directionAndMagnitude',
    'qualifiersComplete',
    'contradictoryEvidenceRepresented',
  ]

  function allCheckpointsOk(): Record<string, AnsweredCheck> {
    return answers(Object.fromEntries(CHECKPOINTS.map((key) => [key, 'yes' as const])))
  }

  function link(overrides: Partial<AnsweredLink> = {}): AnsweredLink {
    return {
      claimEvidenceLinkId: 'lenke-1',
      sourceTitle: 'Testkilde A',
      sourceAccess: 'original_source',
      answer: 'yes',
      note: '',
      ...overrides,
    }
  }

  it('oversetter de tre svarene til kontrollresultatene databasen kjenner', () => {
    expect(checkResultFor('yes')).toBe('ok')
    expect(checkResultFor('no')).toBe('deviation')
    expect(checkResultFor('cannot_determine')).toBe('not_assessable')
    // Ubesvart er ikke bestått.
    expect(checkResultFor(undefined)).toBe('not_assessable')
  })

  it('bekrefter når alle sju punktene og alle lenkene holder', () => {
    const derived = deriveClaimVerification({
      checkpoints: allCheckpointsOk(),
      links: [link()],
    })
    expect(derived.outcome).toBe('verified')
    expect(derived.findings).toBeNull()
  })

  // claim_verifications_verified_requires_all_ok_check.
  it('kan ikke bekrefte med ett ubedømt punkt', () => {
    const derived = deriveClaimVerification({
      checkpoints: {
        ...allCheckpointsOk(),
        qualifiersComplete: { answer: 'cannot_determine', note: '' },
      },
      links: [link()],
    })
    expect(derived.outcome).toBe('uncertain')
    expect(derived.findings).toContain('Forbehold')
  })

  it('kan ikke bekrefte når en lenke bare hvilte på et sammendrag', () => {
    const derived = deriveClaimVerification({
      checkpoints: allCheckpointsOk(),
      links: [link(), link({ claimEvidenceLinkId: 'lenke-2', sourceAccess: 'derived_summary' })],
    })
    expect(derived.outcome).toBe('uncertain')
  })

  it('navngir lenken i funnteksten når relasjonen ikke holder', () => {
    const derived = deriveClaimVerification({
      checkpoints: allCheckpointsOk(),
      links: [link({ answer: 'no', note: 'Funnet støtter ikke ordlyden.' })],
    })
    expect(derived.outcome).toBe('needs_correction')
    expect(derived.findings).toContain('Testkilde A')
    expect(derived.findings).toContain('Funnet støtter ikke ordlyden.')
  })

  it('sier fra når det ikke finnes noe grunnlag i det hele tatt', () => {
    const derived = deriveClaimVerification({ checkpoints: allCheckpointsOk(), links: [] })
    expect(derived.outcome).toBe('uncertain')
    expect(derived.findings).toContain('ingen evidenslenker')
  })

  it('teller de sju punktene og lenkene under ett', () => {
    expect(
      claimTally(allCheckpointsOk(), [link(), link({ claimEvidenceLinkId: 'lenke-2' })]),
    ).toEqual({
      total: 9,
      answered: 9,
      confirmed: 9,
      deviations: 0,
      unresolved: 0,
    })
  })
})

describe('foreldet grunnlag', () => {
  it('oversetter svarnøkkelen til stegets id før den sammenligner', () => {
    // Svarene er nøklet på kontrollpunktet, avtrykket på steget. Uten
    // oversettelsen ville hvert oppslag bomme, og alle svar blitt kastet.
    const kept = retainAnswers(
      { sourceSupport: 'ok' },
      { 'checkpoint:sourceSupport': 'avtrykk-1' },
      { 'checkpoint:sourceSupport': 'avtrykk-1' },
      (key) => `checkpoint:${key}`,
    )
    expect(kept.kept).toEqual({ sourceSupport: 'ok' })
    expect(kept.dropped).toEqual([])
  })

  it('beholder svarene på stegene som viser det samme', () => {
    const kept = retainAnswers(
      { a: 'svar-a', b: 'svar-b' },
      { a: 'avtrykk-1', b: 'avtrykk-2' },
      { a: 'avtrykk-1', b: 'avtrykk-2-endret' },
    )
    expect(kept.kept).toEqual({ a: 'svar-a' })
    expect(kept.dropped).toEqual(['b'])
  })

  it('nullstiller bare de feltene forankringen er endret på', () => {
    const state = {
      ...emptyExtractionSessionState(),
      fullText: 'yes' as const,
      sourceAccess: 'original_source',
      fields: {
        outcome: { answer: 'yes' as const, note: '' },
        estimate: { answer: 'yes' as const, note: '' },
      },
    }
    const pruned = pruneExtractionSession({
      state,
      semanticFields: ['outcome', 'estimate'],
      sourceAccessStepId: 'tilgang',
      fieldStepIdFor: (field) => `felt:${field}`,
      previousBasis: { tilgang: 'k1', 'felt:outcome': 'f1', 'felt:estimate': 'f2' },
      nextBasis: { tilgang: 'k1', 'felt:outcome': 'f1', 'felt:estimate': 'f2-endret' },
    })
    expect(pruned.sourceAccess).toBe('original_source')
    expect(Object.keys(pruned.fields)).toEqual(['outcome'])
  })

  it('nullstiller kildetilgangen når kildeversjonen er byttet', () => {
    const state = {
      ...emptyExtractionSessionState(),
      fullText: 'no' as const,
      sourceAccess: 'verifiable_representation',
      fields: { outcome: { answer: 'yes' as const, note: '' } },
    }
    const pruned = pruneExtractionSession({
      state,
      semanticFields: ['outcome'],
      sourceAccessStepId: 'tilgang',
      fieldStepIdFor: (field) => `felt:${field}`,
      previousBasis: { tilgang: 'k1', 'felt:outcome': 'f1' },
      nextBasis: { tilgang: 'k2', 'felt:outcome': 'f1' },
    })
    expect(pruned.sourceAccess).toBeNull()
    expect(pruned.fullText).toBeNull()
    // Og feltet som ikke er endret, står.
    expect(Object.keys(pruned.fields)).toEqual(['outcome'])
  })
})
