// ============================================================================
// Opptaksadapteret
//
// Adapteret er leddet som lar hele kjeden kjøres deterministisk uten en
// leverandørkonto. Det som prøves her, er at det ikke svarer på noe annet enn
// nøyaktig den forespørselen svaret ble gitt til.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { modelRequestDigest, type ModelRequest } from './model-client'
import {
  createRecordedModelClient,
  emptyRecording,
  MODEL_RECORDING_VERSION,
  parseModelRecording,
} from './recorded-model'

const REQUEST: ModelRequest = {
  promptTemplateVersion: 'evidence-extraction/proposal-drafting/1',
  system: 'Du er ekstraksjonsleddet.',
  user: 'Kildeteksten står under.',
}

function opptak(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    recording_version: MODEL_RECORDING_VERSION,
    identity: { provider: 'antidep', model: 'opptaksmodell', model_version: '1' },
    entries: [
      {
        request_digest: `sha256:${'a'.repeat(64)}`,
        prompt_template_version: REQUEST.promptTemplateVersion,
        completion: '{"ok": true}',
      },
    ],
    ...overrides,
  }
}

async function opptakFor(completion: string): Promise<Record<string, unknown>> {
  return opptak({
    entries: [
      {
        request_digest: await modelRequestDigest(REQUEST),
        prompt_template_version: REQUEST.promptTemplateVersion,
        completion,
      },
    ],
  })
}

describe('parseModelRecording', () => {
  it('leser et gyldig opptak', () => {
    const parsed = parseModelRecording(opptak())
    expect(parsed.identity).toEqual({
      provider: 'antidep',
      model: 'opptaksmodell',
      modelVersion: '1',
    })
    expect(parsed.entries).toHaveLength(1)
  })

  it('avviser et ukjent felt', () => {
    expect(() => parseModelRecording(opptak({ temperatur: 0 }))).toThrow(
      /ukjente felter: temperatur/,
    )
  })

  it('avviser en annen versjon av opptaksformen', () => {
    expect(() => parseModelRecording(opptak({ recording_version: 'x' }))).toThrow(
      /recording_version/,
    )
  })

  it('avviser to svar på den samme forespørselen', () => {
    const entry = {
      request_digest: `sha256:${'a'.repeat(64)}`,
      prompt_template_version: REQUEST.promptTemplateVersion,
      completion: 'a',
    }
    expect(() =>
      parseModelRecording(opptak({ entries: [entry, { ...entry, completion: 'b' }] })),
    ).toThrow(/to svar på den samme forespørselen/)
  })

  // Et opptak skrevet av --prepare har en tom plass. Den skal ikke avvises for
  // å være tom: avvisningen hører hjemme der noen faktisk ber om svaret.
  it('leser en tom plass som en tom plass', () => {
    const parsed = parseModelRecording(
      opptak({
        entries: [
          {
            request_digest: `sha256:${'b'.repeat(64)}`,
            prompt_template_version: REQUEST.promptTemplateVersion,
            completion: '',
          },
        ],
      }),
    )
    expect(parsed.entries[0]?.completion).toBe('')
  })

  // Verdiene ender i proveniensen som premissene utkastet ble laget under. En
  // plassholder som ble stående, ville vært en rad som påstår at
  // «SETT-INN-MODELL» leste artikkelen (ANTIDEP_CONSTITUTION.md §14, §20).
  it('avviser malen fra --prepare så lenge identiteten står urørt', () => {
    expect(() =>
      parseModelRecording(
        emptyRecording(`sha256:${'b'.repeat(64)}`, REQUEST.promptTemplateVersion),
      ),
    ).toThrow(/plassholderen fra --prepare/)
  })

  it('avviser en plassholder som bare er delvis rettet', () => {
    expect(() =>
      parseModelRecording(
        opptak({
          identity: {
            provider: 'openai',
            model: 'SETT-INN-MODELL-2026',
            model_version: '2026-09-15',
          },
        }),
      ),
    ).toThrow(/identity\.model står fortsatt med plassholderen/)
  })

  it('godtar en identitet der alle tre er fylt ut', () => {
    expect(
      parseModelRecording(
        opptak({
          identity: { provider: 'openai', model: 'en-modell', model_version: '2026-09-15' },
        }),
      ).identity.model,
    ).toBe('en-modell')
  })
})

describe('createRecordedModelClient', () => {
  it('svarer med det som ble spilt inn for nettopp denne forespørselen', async () => {
    const client = createRecordedModelClient(parseModelRecording(await opptakFor('{"svar": 1}')))
    expect((await client.complete(REQUEST)).text).toBe('{"svar": 1}')
    expect(client.identity.model).toBe('opptaksmodell')
  })

  // Et opptak nøklet på noe annet enn forespørselen kunne blitt spilt av for en
  // annen artikkel. Det er hele grunnen til at oppslaget er på avtrykket.
  it('svarer ikke på en forespørsel den ikke har et opptak av', async () => {
    const client = createRecordedModelClient(parseModelRecording(await opptakFor('{"svar": 1}')))
    await expect(client.complete({ ...REQUEST, user: 'En annen kildetekst.' })).rejects.toThrow(
      /har ikke noe svar på denne forespørselen/,
    )
  })

  it('sier fra når promptmalen er en annen enn opptakets', async () => {
    const client = createRecordedModelClient(parseModelRecording(await opptakFor('{"svar": 1}')))
    await expect(
      client.complete({ ...REQUEST, promptTemplateVersion: 'evidence-extraction/x/2' }),
    ).rejects.toThrow(/Opptaket er laget for promptmalen/)
  })

  it('sier fra når plassen i opptaket ennå er tom', async () => {
    const client = createRecordedModelClient(parseModelRecording(await opptakFor('   ')))
    await expect(client.complete(REQUEST)).rejects.toThrow(/tom plass/)
  })
})
