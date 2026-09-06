import { describe, expect, it } from 'vitest'

import { isPublicAddress, judgeAddress, parseIpAddress } from './address-guard'

describe('judgeAddress — IPv4 som skal avvises', () => {
  it.each([
    ['127.0.0.1', 'loopback'],
    ['127.255.255.254', 'hele loopback-blokken'],
    ['0.0.0.0', 'dette nettet'],
    ['10.0.0.1', 'privat nett'],
    ['10.255.255.255', 'hele 10/8'],
    ['172.16.0.1', 'privat nett'],
    ['172.31.255.255', 'øvre ende av 172.16/12'],
    ['192.168.1.1', 'privat nett'],
    ['169.254.169.254', 'skyens metadatatjeneste'],
    ['169.254.0.1', 'link-local'],
    ['100.64.0.1', 'operatørnett'],
    ['192.0.0.1', 'IETF-protokolltildeling'],
    ['198.18.0.1', 'ytelsestesting'],
    ['224.0.0.1', 'multicast'],
    ['255.255.255.255', 'kringkasting'],
  ])('avviser %s (%s)', (address) => {
    expect(isPublicAddress(address)).toBe(false)
  })

  it('sier hvorfor adressen ble avvist', () => {
    expect(judgeAddress('169.254.169.254')).toEqual({
      allowed: false,
      reason: expect.stringContaining('metadatatjeneste') as unknown as string,
    })
  })

  // Grensene er der de skal være, ikke én byte for langt.
  it.each(['172.15.255.255', '172.32.0.0', '11.0.0.1', '100.128.0.1', '9.255.255.255'])(
    'godtar %s, som ligger utenfor blokken over',
    (address) => {
      expect(isPublicAddress(address)).toBe(true)
    },
  )
})

describe('judgeAddress — IPv4 som skal godtas', () => {
  it.each(['8.8.8.8', '1.1.1.1', '130.14.29.110', '93.184.216.34'])('godtar %s', (address) => {
    expect(isPublicAddress(address)).toBe(true)
  })
})

describe('judgeAddress — IPv6', () => {
  it.each([
    ['::1', 'loopback'],
    ['::', 'uspesifisert'],
    ['fe80::1', 'link-local'],
    ['fd00::1', 'unique local'],
    ['fc00::1', 'unique local'],
    ['ff02::1', 'multicast'],
    ['2001:db8::1', 'dokumentasjonsnett'],
    ['2002:7f00:1::', '6to4-tunnel'],
    ['2001:0:1::', 'Teredo-tunnel'],
    ['100::1', 'discard-prefiks'],
    ['100:0:0:1::1', 'dummy-prefiks'],
    ['2001:2::1', 'benchmarking, inne i IETF-blokken'],
    ['2001:20::1', 'ORCHIDv2, inne i IETF-blokken'],
    ['2001:30::1', 'drone remote id, inne i IETF-blokken'],
    ['2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff', 'siste adresse i IETF-blokken'],
    ['3fff::1', 'dokumentasjonsnett'],
    ['3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff', 'siste adresse i dokumentasjonsnettet'],
    ['5f00::1', 'SRv6 SID-blokk'],
  ])('avviser %s (%s)', (address) => {
    expect(isPublicAddress(address)).toBe(false)
  })

  // Grensene rundt de nye blokkene: en for vid regel ville stengt ute
  // publikumsadresser, og det er en feil den andre veien.
  it.each([
    ['2606:4700:4700::1111', 'Cloudflare'],
    ['2a00:1450:4001:80f::200e', 'Google'],
    ['2001:4860:4860::8888', 'like utenfor IETF-blokken'],
    ['2001:200::1', 'første adresse etter IETF-blokken'],
    ['2000::1', 'første adressen i global unicast'],
    ['3fff:ffff::1', 'siste adressen i global unicast'],
  ])('godtar %s (%s)', (address) => {
    expect(isPublicAddress(address)).toBe(true)
  })

  // IANA deler ut global unicast fra 2000::/3. Resten av IPv6-rommet er
  // reservert for framtidig bruk, står ikke i special-purpose-registeret, og
  // kan likevel ha en intern rute. En avvisningsliste alene er derfor ikke en
  // SSRF-grense for IPv6.
  it.each([
    ['1000::1', 'før global unicast'],
    ['4000::1', 'etter global unicast'],
    ['6000::1', 'reservert'],
    ['8000::1', 'reservert'],
    ['e000::1', 'reservert'],
  ])('avviser %s (%s), som er utenfor 2000::/3', (address) => {
    expect(isPublicAddress(address)).toBe(false)
  })

  // Den innpakkede formen er den farligste: en vakt som bare leste den som
  // «en IPv6-adresse som ikke er fe80/fc00», ville sluppet loopback rett
  // gjennom.
  it.each([
    '::ffff:127.0.0.1',
    '::ffff:169.254.169.254',
    '::ffff:10.0.0.1',
    '::ffff:7f00:1',
    '64:ff9b::127.0.0.1',
  ])('avviser den innpakkede formen %s', (address) => {
    expect(isPublicAddress(address)).toBe(false)
  })

  it.each(['::ffff:8.8.8.8', '64:ff9b::8.8.8.8'])(
    'godtar den innpakkede offentlige adressen %s',
    (address) => {
      expect(isPublicAddress(address)).toBe(true)
    },
  )

  // Bare `64:ff9b::/96` legger IPv4-adressen i de siste 32 bitene. RFC 6052
  // tillater også kortere prefikser, og da ligger destinasjonen et annet sted.
  // Her er destinasjonen 10.0.0.1 — privat — mens de siste 32 bitene er
  // 8.8.8.8 og ser offentlige ut. En vakt som leste dem, ville sluppet den
  // gjennom til et privat nett.
  it('avviser en NAT64-adresse der destinasjonen ikke ligger i de siste 32 bitene', () => {
    expect(isPublicAddress('64:ff9b:1:a00:0:100:808:808')).toBe(false)
  })

  it.each(['64:ff9b:1::8.8.8.8', '64:ff9b:0:1::808:808', '64:ff9b:ffff::1'])(
    'avviser %s, som er NAT64 med en innpakking vakten ikke kan lese',
    (address) => {
      expect(isPublicAddress(address)).toBe(false)
    },
  )

  it('leser en sone-id uten å la den omgå kontrollen', () => {
    expect(isPublicAddress('fe80::1%eth0')).toBe(false)
  })
})

describe('parseIpAddress — former som ikke skal leses', () => {
  // En vakt som leser en adresse annerledes enn socketen, er ingen vakt. Alle
  // disse avvises som ukjente, og en ukjent adresse er aldri offentlig.
  it.each([
    '127.000.000.1',
    '0x7f.0.0.1',
    '2130706433',
    '127.1',
    '256.1.1.1',
    '1.2.3.4.5',
    '::ffff:999.1.1.1',
    'ikke en adresse',
    '',
    '   ',
    ':::1',
    '12345::1',
  ])('leser ikke %s', (value) => {
    expect(parseIpAddress(value)).toBeNull()
    expect(isPublicAddress(value)).toBe(false)
  })

  it('sier at en uleselig adresse ikke er gjenkjennelig', () => {
    expect(judgeAddress('127.000.000.1')).toEqual({
      allowed: false,
      reason: 'ikke en gjenkjennelig IP-adresse',
    })
  })
})

describe('parseIpAddress — kanoniske former', () => {
  it('leser en IPv4-adresse som fire byte', () => {
    expect(parseIpAddress('1.2.3.4')).toEqual({
      kind: 'ipv4',
      bytes: new Uint8Array([1, 2, 3, 4]),
    })
  })

  it('leser en komprimert IPv6-adresse som seksten byte', () => {
    const parsed = parseIpAddress('2001:db8::1')
    expect(parsed?.kind).toBe('ipv6')
    expect(parsed?.bytes).toHaveLength(16)
    expect(parsed?.bytes[15]).toBe(1)
  })
})
