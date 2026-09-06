// ============================================================================
// Hvilke IP-adresser en kildehenting har lov til å nå
//
// `knowledge.source_versions.retrieved_from` er redaktørstyrt data, og
// verifikatoren henter den adressen fra en betrodd kjører — lokalt, eller fra en
// GitHub Actions-runner med tilgang til nettet. Uten en grense her ville en
// registrert kilde kunne peke kjøreren mot `localhost`, mot et privat nett eller
// mot 169.254.169.254, altså skymiljøenes metadatatjeneste. Det er en
// SSRF-vei, og den er reell selv om redaktøren er en betrodd rolle: en adresse
// registrert i god tro kan peke feil, og en kilde kan redirecte hvor som helst.
//
// Modulen er ren og kjenner verken nett eller DNS: den svarer bare på om én
// oppslått adresse er en offentlig internettadresse. Hvem som spør, og når i
// tilkoblingen de spør, avgjøres i `guarded-http.ts`.
//
// ----------------------------------------------------------------------------
// Hvorfor parsingen er streng
//
// Adresser kan skrives på former forskjellige parsere leser forskjellig —
// `127.000.000.1` som oktal, `::ffff:127.0.0.1` som en IPv6-innpakket IPv4,
// `0x7f.1` som heksadesimal. En vakt som leser en adresse annerledes enn
// socketen som kobler til, er ingen vakt. Derfor: bare kanoniske former godtas,
// alt annet avvises som ukjent, og en ukjent adresse er aldri offentlig.
//
// De to innkapslede formene som *er* kanoniske — IPv4-mapped (`::ffff:a.b.c.d`)
// og NAT64 (`64:ff9b::/96`) — pakkes ut og kontrolleres som IPv4. Tunnelformene
// 6to4 (`2002::/16`) og Teredo (`2001::/32`) avvises i sin helhet: de bærer en
// vilkårlig destinasjon inne i adressen, og å slippe dem gjennom ville flyttet
// kontrollen til et lag vi ikke ser.
// ============================================================================

/** En adresse lest som bytes, slik prefiksene kan kontrolleres uniformt. */
export interface IpAddress {
  readonly kind: 'ipv4' | 'ipv6'
  readonly bytes: Uint8Array
}

function parseIpv4(value: string): Uint8Array | null {
  const parts = value.split('.')
  if (parts.length !== 4) {
    return null
  }
  const bytes = new Uint8Array(4)
  for (let index = 0; index < 4; index += 1) {
    const part = parts[index] ?? ''
    // Bare desimale siffer, ingen ledende null (den leses som oktal av noen
    // parsere), og høyst tre siffer.
    if (!/^\d{1,3}$/.test(part) || (part.length > 1 && part.startsWith('0'))) {
      return null
    }
    const octet = Number(part)
    if (octet > 255) {
      return null
    }
    bytes[index] = octet
  }
  return bytes
}

function parseIpv6(value: string): Uint8Array | null {
  // En sone-id (`%eth0`) gjelder bare link-local, som avvises uansett. Den
  // fjernes her slik at resten av parsingen slipper å kjenne formen.
  const withoutZone = value.split('%')[0] ?? ''

  const halves = withoutZone.split('::')
  if (halves.length > 2) {
    return null
  }

  const readGroups = (text: string): number[] | null => {
    if (text.length === 0) {
      return []
    }
    const groups: number[] = []
    const parts = text.split(':')
    for (let index = 0; index < parts.length; index += 1) {
      const part = parts[index] ?? ''
      const isLast = index === parts.length - 1
      // Den siste gruppen kan være en punktnotert IPv4 (`::ffff:127.0.0.1`).
      if (isLast && part.includes('.')) {
        const embedded = parseIpv4(part)
        if (embedded === null) {
          return null
        }
        groups.push(((embedded[0] ?? 0) << 8) | (embedded[1] ?? 0))
        groups.push(((embedded[2] ?? 0) << 8) | (embedded[3] ?? 0))
        continue
      }
      if (!/^[0-9a-fA-F]{1,4}$/.test(part)) {
        return null
      }
      groups.push(Number.parseInt(part, 16))
    }
    return groups
  }

  const head = readGroups(halves[0] ?? '')
  const tail = halves.length === 2 ? readGroups(halves[1] ?? '') : []
  if (head === null || tail === null) {
    return null
  }

  const total = head.length + tail.length
  if (halves.length === 2) {
    if (total > 7) {
      return null
    }
  } else if (total !== 8) {
    return null
  }

  const groups = [...head, ...new Array<number>(8 - total).fill(0), ...tail]
  const bytes = new Uint8Array(16)
  for (let index = 0; index < 8; index += 1) {
    const group = groups[index] ?? 0
    bytes[index * 2] = (group >> 8) & 0xff
    bytes[index * 2 + 1] = group & 0xff
  }
  return bytes
}

/** Leser en adresse på kanonisk form. `null` betyr «ukjent», aldri «offentlig». */
export function parseIpAddress(value: string): IpAddress | null {
  const trimmed = value.trim()
  if (trimmed.length === 0) {
    return null
  }
  if (trimmed.includes(':')) {
    const bytes = parseIpv6(trimmed)
    return bytes === null ? null : { kind: 'ipv6', bytes }
  }
  const bytes = parseIpv4(trimmed)
  return bytes === null ? null : { kind: 'ipv4', bytes }
}

interface Prefix {
  readonly bytes: readonly number[]
  readonly length: number
  readonly why: string
}

// Byte som ikke er oppgitt i prefikset, er null. Uten det ville et prefiks som
// `100::/64` bare kunne skrives ut i full lengde, og en kortform ville stille
// sluttet å matche — altså en avvisningsregel som så ut til å gjelde uten å
// gjøre det.
function matchesPrefix(bytes: Uint8Array, prefix: Prefix): boolean {
  let remaining = prefix.length
  let index = 0
  while (remaining >= 8) {
    if ((bytes[index] ?? 0) !== (prefix.bytes[index] ?? 0)) {
      return false
    }
    index += 1
    remaining -= 8
  }
  if (remaining === 0) {
    return true
  }
  const mask = 0xff << (8 - remaining)
  return ((bytes[index] ?? 0) & mask) === ((prefix.bytes[index] ?? 0) & mask)
}

// Alt som ikke er offentlig unicast på internett. Listen er en avvisningsliste
// og ikke en tillatelsesliste, fordi det offentlige adresserommet ikke lar seg
// liste opp — men den er uttømmende over IANAs spesialregistre, ikke over «de
// vanlige».
const BLOCKED_IPV4: readonly Prefix[] = [
  { bytes: [0, 0, 0, 0], length: 8, why: 'dette nettet' },
  { bytes: [10, 0, 0, 0], length: 8, why: 'privat nett' },
  { bytes: [100, 64, 0, 0], length: 10, why: 'operatørnett (CGNAT)' },
  { bytes: [127, 0, 0, 0], length: 8, why: 'loopback' },
  { bytes: [169, 254, 0, 0], length: 16, why: 'link-local, blant annet skyens metadatatjeneste' },
  { bytes: [172, 16, 0, 0], length: 12, why: 'privat nett' },
  { bytes: [192, 0, 0, 0], length: 24, why: 'IETF-protokolltildeling' },
  { bytes: [192, 0, 2, 0], length: 24, why: 'dokumentasjonsnett' },
  { bytes: [192, 88, 99, 0], length: 24, why: '6to4-relé' },
  { bytes: [192, 168, 0, 0], length: 16, why: 'privat nett' },
  { bytes: [198, 18, 0, 0], length: 15, why: 'ytelsestesting' },
  { bytes: [198, 51, 100, 0], length: 24, why: 'dokumentasjonsnett' },
  { bytes: [203, 0, 113, 0], length: 24, why: 'dokumentasjonsnett' },
  { bytes: [224, 0, 0, 0], length: 4, why: 'multicast' },
  { bytes: [240, 0, 0, 0], length: 4, why: 'reservert' },
]

const IPV4_MAPPED: Prefix = {
  bytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff],
  length: 96,
  why: 'IPv4-innpakket',
}
const NAT64: Prefix = {
  bytes: [0x00, 0x64, 0xff, 0x9b],
  length: 32,
  why: 'NAT64',
}

const BLOCKED_IPV6: readonly Prefix[] = [
  { bytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], length: 128, why: 'uspesifisert' },
  { bytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], length: 128, why: 'loopback' },
  { bytes: [0x01, 0x00], length: 64, why: 'discard-prefiks' },
  { bytes: [0x20, 0x01, 0x00, 0x00], length: 32, why: 'Teredo-tunnel' },
  { bytes: [0x20, 0x01, 0x0d, 0xb8], length: 32, why: 'dokumentasjonsnett' },
  { bytes: [0x20, 0x02], length: 16, why: '6to4-tunnel' },
  { bytes: [0xfc, 0x00], length: 7, why: 'unique local' },
  { bytes: [0xfe, 0x80], length: 10, why: 'link-local' },
  { bytes: [0xff, 0x00], length: 8, why: 'multicast' },
]

export type AddressVerdict =
  { readonly allowed: true } | { readonly allowed: false; readonly reason: string }

function judgeIpv4(bytes: Uint8Array): AddressVerdict {
  for (const prefix of BLOCKED_IPV4) {
    if (matchesPrefix(bytes, prefix)) {
      return { allowed: false, reason: prefix.why }
    }
  }
  return { allowed: true }
}

/**
 * Om adressen er en offentlig internettadresse kjøreren har lov til å nå.
 *
 * En adresse som ikke lar seg lese, er aldri tillatt: vakten skal ikke gjette
 * på en form den ikke kjenner.
 */
export function judgeAddress(value: string): AddressVerdict {
  const address = parseIpAddress(value)
  if (address === null) {
    return { allowed: false, reason: 'ikke en gjenkjennelig IP-adresse' }
  }

  if (address.kind === 'ipv4') {
    return judgeIpv4(address.bytes)
  }

  // De innkapslede formene kontrolleres som den IPv4-adressen de faktisk bærer.
  if (matchesPrefix(address.bytes, IPV4_MAPPED) || matchesPrefix(address.bytes, NAT64)) {
    return judgeIpv4(address.bytes.slice(12))
  }

  for (const prefix of BLOCKED_IPV6) {
    if (matchesPrefix(address.bytes, prefix)) {
      return { allowed: false, reason: prefix.why }
    }
  }
  return { allowed: true }
}

/** Kortform for kallere som bare trenger ja eller nei. */
export function isPublicAddress(value: string): boolean {
  return judgeAddress(value).allowed
}
