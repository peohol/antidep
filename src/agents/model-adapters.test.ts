// ============================================================================
// Registeret over modelleverandøradaptere
//
// Grensen er poenget, ikke antallet: et leverandøradapter skal kunne føres opp
// her uten at kontrakten, kjøringen, kontrollene eller databasen røres. Det som
// prøves, er at et navn som ikke står i registeret, er en feil — og ikke et
// stille fall tilbake til standardvalget.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { createModelClient, MODEL_ADAPTERS } from './model-adapters'
import { MODEL_RECORDING_VERSION } from './recorded-model'

const OPPTAK = {
  recording_version: MODEL_RECORDING_VERSION,
  identity: { provider: 'antidep', model: 'opptaksmodell', model_version: '1' },
  entries: [
    {
      request_digest: `sha256:${'a'.repeat(64)}`,
      prompt_template_version: 'evidence-extraction/proposal-drafting/1',
      completion: '{}',
    },
  ],
}

describe('createModelClient', () => {
  it('lager opptaksadapteret av en opptaksfil', () => {
    const client = createModelClient('recorded', { recording: OPPTAK })
    expect(client.identity).toEqual({
      provider: 'antidep',
      model: 'opptaksmodell',
      modelVersion: '1',
    })
  })

  // En skrivefeil i --model skal ikke bli til en kjøring gjort med en annen
  // modell enn den kalleren ba om: premissene ville da sagt noe annet enn det
  // som skjedde (ANTIDEP_CONSTITUTION.md §20).
  it('avviser et ukjent navn og navngir de kjente', () => {
    expect(() => createModelClient('gpt', { recording: OPPTAK })).toThrow(
      new RegExp(`Ukjent modelladapter «gpt».*${MODEL_ADAPTERS.join(', ')}`, 's'),
    )
  })

  it('sier hva som mangler når opptaksadapteret kalles uten opptak', () => {
    expect(() => createModelClient('recorded', { recording: null })).toThrow(/--prepare/)
  })

  it('propagerer avvisningen av et ugyldig opptak uendret', () => {
    expect(() =>
      createModelClient('recorded', { recording: { ...OPPTAK, recording_version: 'x' } }),
    ).toThrow(/recording_version/)
  })
})
