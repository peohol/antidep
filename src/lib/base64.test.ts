import { describe, expect, it } from 'vitest'

import { toBase64 } from './base64'

describe('omformingen til base64', () => {
  it('gir nøyaktig de bytene den fikk', () => {
    const bytes = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34])
    expect(toBase64(bytes)).toBe('JVBERi0xLjQ=')
  })

  it('tåler alle 256 byteverdiene, også de som ikke er tekst', () => {
    const bytes = new Uint8Array(256)
    for (let index = 0; index < 256; index += 1) {
      bytes[index] = index
    }
    const roundtrip = Uint8Array.from(atob(toBase64(bytes)), (char) => char.charCodeAt(0))
    expect([...roundtrip]).toEqual([...bytes])
  })

  // Grensen i databasen er 64 MB. En omforming som bygget én kjempestreng av
  // argumenter, ville sprengt kallstakken lenge før det — og en fulltekst som
  // ikke lot seg laste opp fordi filen var stor, ville vært en teknisk oppgave
  // tilbake på klinikeren.
  it('tåler en fil som er langt større enn kallstakken', () => {
    const bytes = new Uint8Array(1_000_000).fill(0x41)
    const encoded = toBase64(bytes)
    expect(encoded.length).toBe(Math.ceil(1_000_000 / 3) * 4)
    expect(encoded.startsWith('QUFB')).toBe(true)
  })
})
