// ============================================================================
// Svarkonvolutten aktøren som utfører modell-leddet, skriver
//
// Det som prøves, er at filen ikke kan si noe usant om seg selv uten å bli
// avvist: hvilken forespørsel den svarer på, hvem som svarte, når, og hvilket
// av de to svarfeltene som gjelder. Innholdet i selve utkastet prøves et annet
// sted — det er `parseExtractionDraft` sin jobb, og den kjøres på nøyaktig det
// samme viset uansett hvilken av formene filen brukte.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { MODEL_ANSWER_VERSION, parseModelAnswer } from './model-answer'

const DIGEST = `sha256:${'a'.repeat(64)}`

function svar(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    answer_version: MODEL_ANSWER_VERSION,
    request_digest: DIGEST,
    identity: { provider: 'anthropic', model: 'claude-code', model_version: 'opus-5' },
    answered_at: '2026-09-10T09:12:00Z',
    draft: { extraction: {} },
    ...overrides,
  }
}

describe('parseModelAnswer — den lykkede stien', () => {
  it('leser et svar der utkastet er et objekt, og gjør det til teksten kontrollen leser', () => {
    const answer = parseModelAnswer(svar())
    expect(answer.form).toBe('draft')
    expect(answer.requestDigest).toBe(DIGEST)
    expect(answer.identity).toEqual({
      provider: 'anthropic',
      model: 'claude-code',
      modelVersion: 'opus-5',
    })
    expect(answer.answeredAt).toBe('2026-09-10T09:12:00Z')
    expect(JSON.parse(answer.completion)).toEqual({ extraction: {} })
  })

  it('leser et svar der utkastet er ordrett tekst, og bevarer teksten uendret', () => {
    const text = '```json\n{ "extraction": {} }\n```'
    const answer = parseModelAnswer(svar({ draft: undefined, completion: text }))
    expect(answer.form).toBe('completion')
    expect(answer.completion).toBe(text)
  })

  it('godtar et svar uten tidspunkt, og sier at det mangler framfor å finne på et', () => {
    expect(parseModelAnswer(svar({ answered_at: undefined })).answeredAt).toBeNull()
  })
})

describe('parseModelAnswer — svar som ikke kan brukes', () => {
  it('avviser en fil skrevet mot en annen versjon av formen', () => {
    expect(() => parseModelAnswer(svar({ answer_version: 'antidep/model-answer@0' }))).toThrow(
      /answer_version/,
    )
  })

  it('avviser et avtrykk som ikke har formen kjøringen fører', () => {
    expect(() => parseModelAnswer(svar({ request_digest: 'sha256:kortere' }))).toThrow(
      /request_digest/,
    )
  })

  it('avviser et svar uten både draft og completion', () => {
    expect(() => parseModelAnswer(svar({ draft: undefined }))).toThrow(
      /verken draft eller completion/,
    )
  })

  it('avviser et svar som oppgir begge, framfor å velge en av dem', () => {
    expect(() => parseModelAnswer(svar({ completion: '{}' }))).toThrow(/både draft og completion/)
  })

  it('avviser et draft som ikke er et objekt', () => {
    expect(() => parseModelAnswer(svar({ draft: [1, 2] }))).toThrow(/draft/)
  })

  it('avviser en tom completion, fordi en tom plass ikke er et svar', () => {
    expect(() => parseModelAnswer(svar({ draft: undefined, completion: '   ' }))).toThrow(
      /completion/,
    )
  })

  it('avviser et ukjent felt framfor å ignorere det', () => {
    expect(() => parseModelAnswer(svar({ temperature: 0.2 }))).toThrow(/ukjente felter/)
  })
})

describe('parseModelAnswer — proveniens som ville vært usann', () => {
  it('avviser en identitet som fortsatt står med plassholderen fra malen', () => {
    expect(() =>
      parseModelAnswer(
        svar({
          identity: {
            provider: 'anthropic',
            model: 'SETT-INN-MODELL',
            model_version: 'opus-5',
          },
        }),
      ),
    ).toThrow(/plassholderen/)
  })

  it('avviser en delvis rettet plassholder, som er like usann som en urørt', () => {
    expect(() =>
      parseModelAnswer(
        svar({
          identity: {
            provider: 'anthropic',
            model: 'SETT-INN-MODELL-2026',
            model_version: 'opus-5',
          },
        }),
      ),
    ).toThrow(/plassholderen/)
  })

  it('avviser en identitet med et felt som mangler', () => {
    expect(() =>
      parseModelAnswer(svar({ identity: { provider: 'anthropic', model: 'claude-code' } })),
    ).toThrow(/model_version/)
  })

  it('avviser tidspunktet når plassholderen fra malen står igjen', () => {
    expect(() => parseModelAnswer(svar({ answered_at: 'SETT-INN-TIDSPUNKT' }))).toThrow(
      /plassholderen/,
    )
  })

  it('avviser et tidspunkt som ikke er et tidspunkt', () => {
    expect(() => parseModelAnswer(svar({ answered_at: '10. september' }))).toThrow(/answered_at/)
  })
})
