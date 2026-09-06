import { describe, expect, it } from 'vitest'

import { retrieveRepresentation, type FetchLike } from './source-retrieval'

function respondWith(bytes: Uint8Array, init: ResponseInit = {}): FetchLike {
  return () =>
    Promise.resolve(
      new Response(bytes as unknown as BodyInit, {
        status: 200,
        headers: { 'content-type': 'text/plain; charset=utf-8' },
        ...init,
      }),
    )
}

const utf8 = (text: string) => new TextEncoder().encode(text)

describe('retrieveRepresentation', () => {
  it('hasher svaret slik databasen ville gjort det', async () => {
    const result = await retrieveRepresentation('https://eksempel.invalid/kilde', {
      fetchImpl: respondWith(utf8('antidep')),
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
      fetchImpl: respondWith(new Uint8Array([0x61, 0xff, 0x62])),
    })
    expect(result).toEqual({
      status: 'error',
      message: expect.stringContaining('ikke gyldig UTF-8') as unknown as string,
    })
  })

  it('avviser et svar som ikke er 2xx', async () => {
    const result = await retrieveRepresentation('https://eksempel.invalid/borte', {
      fetchImpl: respondWith(utf8(''), { status: 404 }),
    })
    expect(result).toEqual({ status: 'error', message: expect.stringContaining('404') })
  })

  it('avviser en adresse som ikke er en URL', async () => {
    const result = await retrieveRepresentation('ikke en url', {
      fetchImpl: respondWith(utf8('')),
    })
    expect(result).toEqual({ status: 'error', message: expect.stringContaining('gyldig URL') })
  })

  it('avviser en adresse som ikke kan hentes over nett', async () => {
    const result = await retrieveRepresentation('file:///etc/passwd', {
      fetchImpl: respondWith(utf8('')),
    })
    expect(result).toEqual({ status: 'error', message: expect.stringContaining('file:') })
  })

  it('gjør et nettverksbrudd til et resultat, ikke til et kastet unntak', async () => {
    const result = await retrieveRepresentation('https://eksempel.invalid/nede', {
      fetchImpl: () => Promise.reject(new Error('ECONNRESET')),
    })
    expect(result).toEqual({ status: 'error', message: expect.stringContaining('ECONNRESET') })
  })
})
