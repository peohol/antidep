import { describe, expect, it } from 'vitest'

import { readUtf8File, type ByteSource } from './read-utf8-file'

function fileOf(bytes: Uint8Array, name = 'kilde.xml'): ByteSource {
  return {
    name,
    arrayBuffer: () => Promise.resolve(bytes.buffer.slice(0) as ArrayBuffer),
  }
}

describe('readUtf8File', () => {
  // Kjernen: CRLF skal overleve. Et `<textarea>` normaliserer linjeskift i sin
  // API-verdi, så den veien ville gitt «a\nb» her — og et fingeravtrykk som
  // ikke lenger stemmer med bytene på nettet.
  it('bevarer CRLF', async () => {
    const result = await readUtf8File(fileOf(new TextEncoder().encode('a\r\nb')))
    expect(result).toEqual({ status: 'ok', text: 'a\r\nb', byteLength: 4 })
  })

  // Samme feilklasse som CRLF, og like stille: uten `ignoreBOM: true` fjerner
  // `TextDecoder` et innledende U+FEFF, og de tre bytene EF BB BF forsvinner
  // ut av teksten databasen hasher. Kilden ville da aldri kunne reprodusere
  // sitt eget fingeravtrykk.
  it('bevarer en UTF-8 BOM, slik at bytene kan kodes tilbake uendret', async () => {
    const bytes = new Uint8Array([0xef, 0xbb, 0xbf, ...new TextEncoder().encode('<xml/>')])
    const result = await readUtf8File(fileOf(bytes))

    expect(result).toMatchObject({ status: 'ok', text: '\ufeff<xml/>', byteLength: 9 })
    if (result.status !== 'ok') {
      throw new Error('forventet ok')
    }
    expect([...new TextEncoder().encode(result.text)]).toEqual([...bytes])
  })

  it('bevarer ledende og etterfølgende blanktegn', async () => {
    const result = await readUtf8File(fileOf(new TextEncoder().encode('  innhold\n\n')))
    expect(result).toMatchObject({ status: 'ok', text: '  innhold\n\n' })
  })

  it('leser flerbytetegn riktig', async () => {
    const result = await readUtf8File(fileOf(new TextEncoder().encode('vektøkning æøå')))
    expect(result).toMatchObject({ status: 'ok', text: 'vektøkning æøå', byteLength: 18 })
  })

  it('avviser en fil som ikke er gyldig UTF-8', async () => {
    const result = await readUtf8File(fileOf(new Uint8Array([0x61, 0xff, 0x62])))
    expect(result).toEqual({
      status: 'error',
      message: expect.stringContaining('ikke gyldig UTF-8') as unknown as string,
    })
  })

  it('avviser en tom fil', async () => {
    expect(await readUtf8File(fileOf(new Uint8Array([])))).toEqual({
      status: 'error',
      message: expect.stringContaining('er tom') as unknown as string,
    })
  })

  it('gjør en lesefeil til et resultat, ikke til et kastet unntak', async () => {
    const broken: ByteSource = {
      name: 'kilde.xml',
      arrayBuffer: () => Promise.reject(new Error('diskfeil')),
    }
    expect(await readUtf8File(broken)).toEqual({
      status: 'error',
      message: expect.stringContaining('Klarte ikke å lese') as unknown as string,
    })
  })
})
