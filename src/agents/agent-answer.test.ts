import { describe, expect, it } from 'vitest'

import { parseAgentTask } from './agent-task.ts'
import { answerBindingProblem, parseAgentAnswer, parseAnswerJson } from './agent-answer.ts'
import { answerFor, taskPayload } from './handoff-test-support.ts'

const CHATGPT = { provider: 'openai', model: 'GPT-5 Thinking' }
const CLAUDE = { provider: 'anthropic', model: 'Claude Opus' }

function task(role: 'evidence_extraction' | 'claim_synthesis' | 'evidence_assessment') {
  return parseAgentTask(taskPayload(role))
}

describe('parseAgentAnswer', () => {
  it('leser et gyldig svar', () => {
    const answer = parseAgentAnswer(answerFor('evidence_extraction', CHATGPT))
    expect(answer.role).toBe('evidence_extraction')
    expect(answer.identity).toEqual({
      provider: 'openai',
      model: 'GPT-5 Thinking',
      modelVersion: 'ikke-eksponert',
      modelVersionDisclosure: 'not_exposed',
    })
    expect(answer.answeredAt).toBe('2026-09-15T10:12:00Z')
  })

  it('avviser et ukjent felt framfor å ignorere det', () => {
    expect(() =>
      parseAgentAnswer(answerFor('evidence_extraction', CHATGPT, { notat: 'ekstra' })),
    ).toThrow(/ukjente felter/)
  })

  it('avviser en svarform denne utgaven ikke leser', () => {
    expect(() =>
      parseAgentAnswer(
        answerFor('evidence_extraction', CHATGPT, { answer_version: 'antidep/agent-answer@0' }),
      ),
    ).toThrow(/answer_version/)
  })

  it('avviser et avtrykk som ikke har formen', () => {
    expect(() =>
      parseAgentAnswer(answerFor('evidence_extraction', CHATGPT, { request_digest: 'nope' })),
    ).toThrow(/request_digest/)
  })

  it('avviser et svar uten result som objekt', () => {
    expect(() =>
      parseAgentAnswer(answerFor('evidence_extraction', CHATGPT, { result: 'et utkast' })),
    ).toThrow(/result/)
  })

  // Ingen versjon er en opplysning, ikke et tomt felt. En modell som ikke får
  // vite sin egen build, skal si nettopp det — og en oppdiktet versjon ville sett
  // like troverdig ut som en sann (ANTIDEP_CONSTITUTION.md regel 4).
  it('krever en versjon når svaret sier at tjenesten oppgir en', () => {
    expect(() =>
      parseAgentAnswer(
        answerFor('evidence_extraction', CHATGPT, {
          identity: { provider: 'openai', model: 'GPT-5', model_version_disclosure: 'exact' },
        }),
      ),
    ).toThrow(/model_version/)
  })

  it('avviser den kanoniske ukjent-verdien sammen med «exact»', () => {
    expect(() =>
      parseAgentAnswer(
        answerFor('evidence_extraction', CHATGPT, {
          identity: {
            provider: 'openai',
            model: 'GPT-5',
            model_version: 'ikke-eksponert',
            model_version_disclosure: 'exact',
          },
        }),
      ),
    ).toThrow(/ikke-eksponert/)
  })

  it('kanoniserer en ikke-eksponert versjon, slik at to ukjente er den samme modellen', () => {
    const a = parseAgentAnswer(answerFor('evidence_extraction', CHATGPT))
    const b = parseAgentAnswer(
      answerFor('evidence_extraction', CHATGPT, {
        identity: {
          provider: 'openai',
          model: 'GPT-5 Thinking',
          model_version: null,
          model_version_disclosure: 'not_exposed',
        },
      }),
    )
    expect(a.identity).toEqual(b.identity)
  })

  it('avviser et svartidspunkt som ikke er en dato', () => {
    expect(() =>
      parseAgentAnswer(
        answerFor('evidence_extraction', CHATGPT, { answered_at: '2026-09-31T00:00:00Z' }),
      ),
    ).toThrow(/answered_at/)
  })
})

describe('answerBindingProblem', () => {
  it('godtar et svar som hører til oppgaven', () => {
    expect(
      answerBindingProblem(
        task('evidence_extraction'),
        parseAgentAnswer(answerFor('evidence_extraction', CHATGPT)),
      ),
    ).toBeNull()
  })

  it('avviser et svar avgitt i en annen rolle', () => {
    const answer = parseAgentAnswer(answerFor('claim_synthesis', CLAUDE))
    expect(answerBindingProblem(task('evidence_extraction'), answer)).toMatch(/rollen/)
  })

  // Et svar avgitt på ett grunnlag, importert mot et annet, er nøyaktig det
  // avtrykket finnes for å utelukke (ANTIDEP_CONSTITUTION.md regel 2).
  it('avviser et svar avgitt på et annet grunnlag', () => {
    const answer = parseAgentAnswer(
      answerFor('evidence_extraction', CHATGPT, { request_digest: `sha256:${'e'.repeat(64)}` }),
    )
    expect(answerBindingProblem(task('evidence_extraction'), answer)).toMatch(/endret/)
  })

  it('avviser en annen svarform enn oppgaven krever', () => {
    const answer = parseAgentAnswer(
      answerFor('evidence_extraction', CHATGPT, {
        output_schema_version: 'antidep/extraction-draft@0',
      }),
    )
    expect(answerBindingProblem(task('evidence_extraction'), answer)).toMatch(/svarformen/)
  })

  it('avviser en annen modell enn den rollen er registrert med', () => {
    const registered = parseAgentTask(
      taskPayload('evidence_extraction', {
        registered_model: {
          provider: 'openai',
          model: 'GPT-5 Thinking',
          model_version: 'ikke-eksponert',
          model_version_disclosure: 'not_exposed',
        },
      }),
    )
    const answer = parseAgentAnswer(answerFor('evidence_extraction', CLAUDE))
    expect(answerBindingProblem(registered, answer)).toMatch(/GPT-5 Thinking/)
  })
})

describe('parseAnswerJson', () => {
  it('leser ren JSON', () => {
    expect(parseAnswerJson('{"a": 1}')).toEqual({ a: 1 })
  })

  // Ett gjerde rundt hele svaret er den ene avviksformen som er entydig, og som
  // ikke endrer et eneste tegn i innholdet. Et menneske som limer inn fra et
  // chatvindu, får nettopp den.
  it('tåler ett kodegjerde rundt hele svaret', () => {
    expect(parseAnswerJson('```json\n{"a": 1}\n```')).toEqual({ a: 1 })
  })

  it('sier hva som er galt når filen ikke er JSON', () => {
    expect(() => parseAnswerJson('her er svaret ditt')).toThrow(/ikke gyldig JSON/)
  })
})
