// ============================================================================
// Bestillingen: hva flaten kan sende, og hva den aldri lar noen sende
//
// Kontrollene her er ikke sikkerhetsgrenser — databasen avviser uansett, og den
// avvisningen er den som gjelder. De finnes for at den som skriver feil, skal få
// vite det mens feltet står foran dem, og for at ingen skal måtte kjenne til en
// uuid for å be om en artikkel.
// ============================================================================

import { describe, expect, it } from 'vitest'

import {
  EMPTY_REQUEST,
  normaliseDoi,
  parseCapabilities,
  parseRequestOptions,
  parseRequestResult,
  requestOutcomeSentence,
  requestProblem,
} from './full-text-request.ts'

const FULLSTENDIG = {
  ...EMPTY_REQUEST,
  doi: '10.1016/j.jad.2019.01.001',
  title: 'Sertralin og vektendring',
  authors: 'Testforfatter m.fl.',
  drugs: ['sertralin'],
  outcomes: ['vektendring'],
}

describe('valgene bestillingen avgrenses med', () => {
  it('leses som navn, og bare navn', () => {
    const options = parseRequestOptions({
      drugs: ['sertralin', 'mirtazapin'],
      outcomes: ['vektendring'],
      populations: [],
    })
    expect(options.drugs).toEqual(['sertralin', 'mirtazapin'])
    expect(options.populations).toEqual([])
  })

  it('avviser et svar som ikke har formen framfor å gjette', () => {
    expect(() => parseRequestOptions({ drugs: 'sertralin' })).toThrow(/drugs/)
    expect(() => parseRequestOptions({ drugs: [1], outcomes: [], populations: [] })).toThrow(
      /drugs\[0\]/,
    )
  })
})

describe('hva den innloggede kan gjøre', () => {
  it('leses som to lukkede svar', () => {
    expect(parseCapabilities({ may_request: true, may_upload: false })).toEqual({
      mayRequest: true,
      mayUpload: false,
    })
  })

  it('avviser et svar som ikke er boolsk', () => {
    expect(() => parseCapabilities({ may_request: 'ja', may_upload: false })).toThrow(/may_request/)
  })
})

describe('DOI-en', () => {
  it('normaliseres til den formen databasen lagrer', () => {
    expect(normaliseDoi('  https://doi.org/10.1234/ABC  ')).toBe('10.1234/abc')
    expect(normaliseDoi('http://dx.doi.org/10.1234/ABC')).toBe('10.1234/abc')
    expect(normaliseDoi('10.1234/abc')).toBe('10.1234/abc')
  })

  it('må ha formen en DOI har', () => {
    expect(requestProblem({ ...FULLSTENDIG, doi: 'pmid 12345678' })).toMatch(/DOI/)
    expect(requestProblem({ ...FULLSTENDIG, doi: '' })).toMatch(/DOI/)
  })

  it('godtas som en doi.org-lenke, fordi det er den samme DOI-en', () => {
    expect(requestProblem({ ...FULLSTENDIG, doi: 'https://doi.org/10.1234/abc' })).toBeNull()
  })
})

describe('hva bestillingen må si', () => {
  it('sier fra om tittelen mangler', () => {
    expect(requestProblem({ ...FULLSTENDIG, title: '   ' })).toMatch(/tittel/i)
  })

  it('sier fra om forfatterne mangler', () => {
    // Innboksen viser tittel og forfattere til den som senere skal kjenne igjen
    // riktig PDF. Uten dem er bestillingen ikke til å handle på.
    expect(requestProblem({ ...FULLSTENDIG, authors: '' })).toMatch(/forfatter/i)
  })

  it('krever minst ett virkestoff og ett endepunkt', () => {
    expect(requestProblem({ ...FULLSTENDIG, drugs: [] })).toMatch(/virkestoff/i)
    expect(requestProblem({ ...FULLSTENDIG, outcomes: [] })).toMatch(/endepunkt/i)
  })

  it('lar populasjonen stå tom, fordi ikke alle funn er avgrenset til én', () => {
    expect(requestProblem({ ...FULLSTENDIG, populations: [] })).toBeNull()
  })

  it('godtar et årstall, og avviser et som ikke hører til en publisert artikkel', () => {
    expect(requestProblem({ ...FULLSTENDIG, year: '2019' })).toBeNull()
    expect(requestProblem({ ...FULLSTENDIG, year: '' })).toBeNull()
    expect(requestProblem({ ...FULLSTENDIG, year: '1200' })).toMatch(/Årstallet/)
    expect(requestProblem({ ...FULLSTENDIG, year: 'i fjor' })).toMatch(/Årstallet/)
  })

  it('sier én ting om gangen, og alltid om feltet som står nærmest', () => {
    // En liste over alt som mangler, ville vært en feilmelding og ikke en hjelp.
    expect(requestProblem(EMPTY_REQUEST)).toMatch(/tittel/i)
  })
})

describe('svaret etter en bestilling', () => {
  it('sier at Antidep nå venter på artikkelen', () => {
    const sentence = requestOutcomeSentence(
      parseRequestResult({ requested: true, state: 'open', title: 'En artikkel' }),
    )
    expect(sentence).toMatch(/venter nå på «En artikkel»/)
  })

  it('behandler en gjentatt bestilling som noe riktig, ikke som en feil', () => {
    // To redaktører som ber om den samme artikkelen, har begge gjort riktig.
    const sentence = requestOutcomeSentence(
      parseRequestResult({ requested: false, state: 'open', title: 'En artikkel' }),
    )
    expect(sentence).toMatch(/venter allerede/)
    expect(sentence).not.toMatch(/feil/i)
  })

  it('sier fra når artikkelen alt er behandlet', () => {
    const sentence = requestOutcomeSentence(
      parseRequestResult({ requested: false, state: 'fulfilled', title: 'En artikkel' }),
    )
    expect(sentence).toMatch(/allerede behandlet/)
  })

  it('avviser et svar som ikke har formen', () => {
    expect(() => parseRequestResult({ requested: 'ja', state: 'open', title: 'x' })).toThrow(
      /requested/,
    )
  })
})
