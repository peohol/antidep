// ============================================================================
// Fingeravtrykket av en modellforespørsel
//
// Avtrykket er det som binder et opptak til nøyaktig den forespørselen det
// svarte på. Er det ikke entydig, kan et svar spilles av for en annen artikkel
// — og en deterministisk prøve av kjeden ville egentlig ikke prøvd noe.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { modelRequestDigest, type ModelRequest } from './model-client'

function request(overrides: Partial<ModelRequest> = {}): ModelRequest {
  return {
    promptTemplateVersion: 'evidence-extraction/proposal-drafting/1',
    system: 'Du er ekstraksjonsleddet.',
    user: 'Kildeteksten står under.',
    ...overrides,
  }
}

describe('modelRequestDigest', () => {
  it('gir den samme verdien for den samme forespørselen', async () => {
    expect(await modelRequestDigest(request())).toBe(await modelRequestDigest(request()))
  })

  it('har formen databasen bruker for fingeravtrykk', async () => {
    expect(await modelRequestDigest(request())).toMatch(/^sha256:[0-9a-f]{64}$/)
  })

  it('endrer seg når promptmalen endrer seg', async () => {
    expect(await modelRequestDigest(request())).not.toBe(
      await modelRequestDigest(request({ promptTemplateVersion: 'evidence-extraction/x/2' })),
    )
  })

  it('endrer seg når kildeteksten i brukerdelen endrer seg', async () => {
    expect(await modelRequestDigest(request())).not.toBe(
      await modelRequestDigest(request({ user: 'En annen kildetekst.' })),
    )
  })

  // Uten lengdeprefiks ville «ab» + «c» og «a» + «bc» gitt den samme strengen,
  // og dermed det samme avtrykket for to forskjellige forespørsler.
  it('skiller to oppdelinger som ville gitt samme sammenslåing', async () => {
    expect(await modelRequestDigest(request({ system: 'ab', user: 'c' }))).not.toBe(
      await modelRequestDigest(request({ system: 'a', user: 'bc' })),
    )
  })
})
