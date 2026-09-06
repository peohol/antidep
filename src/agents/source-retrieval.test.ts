import { describe, expect, it } from 'vitest'

import { retrieveRepresentation, type HttpGet } from './source-retrieval'

const utf8 = (text: string) => new TextEncoder().encode(text)

function responds(bytes: Uint8Array, overrides: { contentType?: string; url?: string } = {}) {
  const httpGet: HttpGet = (url) =>
    Promise.resolve({
      status: 'ok',
      httpStatus: 200,
      contentType: overrides.contentType ?? 'text/plain; charset=utf-8',
      bytes,
      finalUrl: overrides.url ?? url,
    })
  return httpGet
}

describe('retrieveRepresentation', () => {
  it('hasher svaret slik databasen ville gjort det', async () => {
    const result = await retrieveRepresentation('https://eksempel.invalid/kilde', {
      httpGet: responds(utf8('antidep')),
    })
    expect(result).toMatchObject({
      status: 'ok',
      representation: {
        contentHash: 'sha256:4f031f35e9e54f26eaed0a8e2333d6d51dd0be1d72d67a74ee8b72ca46b0dfba',
        bytesAreUtf8: true,
        byteLength: 7,
      },
    })
  })

  it('sier fra når svaret ikke er ren UTF-8', async () => {
    // 0xff finnes ikke i noen gyldig UTF-8-sekvens. Da kan hashen av den
    // dekodede teksten ikke reproduseres med sha256sum på svaret, og
    // verifikatoren skal ikke late som noe annet.
    const result = await retrieveRepresentation('https://eksempel.invalid/latin', {
      httpGet: responds(new Uint8Array([0x61, 0xff, 0x62])),
    })
    expect(result).toEqual({
      status: 'error',
      message: expect.stringContaining('ikke gyldig UTF-8') as unknown as string,
    })
  })

  it('oppgir adressen som faktisk ble lest, etter redirect', async () => {
    const result = await retrieveRepresentation('https://eksempel.invalid/start', {
      httpGet: responds(utf8('innhold'), { url: 'https://eksempel.invalid/mal' }),
    })
    expect(result).toMatchObject({
      status: 'ok',
      representation: { url: 'https://eksempel.invalid/mal' },
    })
  })

  it('gir hentingens egen avvisning videre uendret', async () => {
    const result = await retrieveRepresentation('https://eksempel.invalid/nede', {
      httpGet: () => Promise.resolve({ status: 'error', message: 'Kilden svarte 503.' }),
    })
    expect(result).toEqual({ status: 'error', message: 'Kilden svarte 503.' })
  })

  // Grensene ligger i `guarded-http.ts`, men de skal kunne styres herfra: en
  // kjøring skal kunne senke dem, og en test skal kunne se at de sendes videre.
  it('sender grensene videre til hentingen', async () => {
    let seen: Record<string, unknown> = {}
    await retrieveRepresentation('https://eksempel.invalid/kilde', {
      httpGet: (url, options) => {
        seen = options
        return responds(utf8('antidep'))(url, options)
      },
      timeoutMs: 1234,
      maxBytes: 2048,
      userAgent: 'Testklient/1',
    })
    expect(seen).toEqual({ timeoutMs: 1234, maxBytes: 2048, userAgent: 'Testklient/1' })
  })

  it('overstyrer ingen grense den ikke har fått oppgitt', async () => {
    let seen: Record<string, unknown> = { urørt: true }
    await retrieveRepresentation('https://eksempel.invalid/kilde', {
      httpGet: (url, options) => {
        seen = options
        return responds(utf8('antidep'))(url, options)
      },
    })
    expect(seen).toEqual({})
  })
})

describe('retrieveRepresentation — vakten er på uten en injisert henting', () => {
  // Den ene testen her som ikke bruker en dobbel: uten `httpGet` går kallet til
  // `guardedGet`, og adressevakten skal da gjelde. En regresjon som byttet
  // tilbake til `fetch`, ville sluppet dette kallet gjennom.
  it('avviser en adresse på loopback', async () => {
    const result = await retrieveRepresentation('http://127.0.0.1:9/')
    expect(result).toMatchObject({
      status: 'error',
      message: expect.stringContaining('offentlig internettadresse') as unknown as string,
    })
  })

  it('avviser skyens metadataadresse', async () => {
    const result = await retrieveRepresentation('http://169.254.169.254/latest/meta-data/')
    expect(result).toMatchObject({
      status: 'error',
      message: expect.stringContaining('metadatatjeneste') as unknown as string,
    })
  })
})
