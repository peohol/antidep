import { describe, expect, it } from 'vitest'

import { isContentHash, sourceVersionContentHash } from './content-hash'

describe('sourceVersionContentHash', () => {
  // Referanseverdien er `printf 'antidep' | sha256sum`, og den samme verdien er
  // festet i 450_source_version_registration_test.sql mot
  // knowledge.source_version_content_hash(text). At begge sider av kjeden måles
  // mot den samme uavhengige verdien, er det som gjør at de ikke kan drive fra
  // hverandre uten at noe feiler.
  it('gir samme verdi som sha256sum og som databasen', async () => {
    await expect(sourceVersionContentHash('antidep')).resolves.toBe(
      'sha256:4f031f35e9e54f26eaed0a8e2333d6d51dd0be1d72d67a74ee8b72ca46b0dfba',
    )
  })

  it('hasher UTF-8-bytene, ikke kodepunktene', async () => {
    // «æ» er to byte i UTF-8. Verdien er `printf 'æ' | sha256sum`.
    await expect(sourceVersionContentHash('æ')).resolves.toBe(
      'sha256:889be819e24eaa58cd98ff071bc5aa9d9d6b3fea8d62c6cd43778c7370d2bf60',
    )
  })

  it('normaliserer ingenting: et etterfølgende mellomrom gir en annen hash', async () => {
    await expect(sourceVersionContentHash('antidep ')).resolves.toBe(
      'sha256:4d0a6e06b6a93e8a2ad52a4ceec22547ba8d26c3c32616e7e09a0fefb67235d1',
    )
  })

  it('gir formatet knowledge.source_versions krever', async () => {
    expect(isContentHash(await sourceVersionContentHash(''))).toBe(true)
  })
})

describe('isContentHash', () => {
  it('avviser en verdi uten algoritmeprefiks', () => {
    expect(isContentHash('a'.repeat(64))).toBe(false)
  })

  it('avviser en verdi med feil lengde', () => {
    expect(isContentHash('sha256:abc')).toBe(false)
  })

  it('avviser store bokstaver: databasens CHECK krever små', () => {
    expect(isContentHash(`sha256:${'A'.repeat(64)}`)).toBe(false)
  })
})
