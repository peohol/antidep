// ============================================================================
// Opprinnelseskontrollen: transportens egen grense
//
// Streamable HTTP krever at serveren kontrollerer `Origin` på hver innkommende
// forbindelse, og svarer 403 dersom den finnes og ikke er tillatt. Grunnen er
// DNS rebinding: en fremmed nettside kan få nettleseren til å sende
// forespørsler til en server den ellers ikke ville nådd, og forespørselen bærer
// da nettleserens egen legitimasjon. Kontrollen hører derfor hjemme FØR
// autentiseringen og dispatchen — den skal ikke være noe et modellkall kan nå
// forbi.
//
// Mengden av tillatte opprinnelser utledes av konfigurasjonen, og aldri av
// forespørselen alene. Nettopp det er poenget: leste vi «vår egen adresse» av
// `Host`, ville en angriper som styrer navnet, også ha styrt svaret, og hele
// kontrollen ville vært en formalitet.
//
// Tre ting slipper gjennom, og ingenting annet:
//
//   1. Adressene konfigurasjonen navngir — appens egen publiserte adresse, og
//      eventuelle klientopprinnelser miljøet lister opp.
//   2. Loopback. En side på maskinen selv er utviklingsoppsettet og
//      inspektøren; en fremmed nettside kan ikke ha en loopback-opprinnelse.
//   3. Appens egen adresse når forespørselen kom over https. Tilkoblingssiden
//      poster sitt eget skjema til seg selv, og skal virke uten at noen har
//      satt en variabel. Over https er den trygg av seg selv: en DNS
//      rebinding-angriper må presentere et gyldig sertifikat for sitt eget
//      navn fra vår vert, og det kan hen ikke. Over rent http gjelder unntaket
//      ikke, for der er det nettopp angrepet lever.
// ============================================================================

/** Verter bare maskinen selv kan nå. */
const LOOPBACK_HOSTNAMES = new Set(['localhost', '127.0.0.1', '[::1]'])

export type OriginVerdict =
  | { readonly kind: 'absent' }
  | { readonly kind: 'allowed'; readonly origin: string }
  | { readonly kind: 'forbidden'; readonly origin: string }

export interface OriginPolicy {
  /** Opprinnelsene konfigurasjonen navngir, normalisert. */
  readonly allowed: ReadonlySet<string>
  /** Appens egen adresse, slik forespørselen nådde den. */
  readonly selfOrigin: string | null
  /** Om forespørselen kom over https, og selvunntaket derfor gjelder. */
  readonly selfIsSecure: boolean
}

/**
 * En opprinnelse på kanonisk form, eller `null` om verdien ikke er en.
 *
 * `URL.origin` er selve normaliseringen: den stryker standardporten, senker
 * skjema og vert, og fjerner alt en opprinnelse ikke har.
 */
export function normalizeOrigin(value: string): string | null {
  const trimmed = value.trim()
  if (trimmed.length === 0) {
    return null
  }
  let url: URL
  try {
    url = new URL(trimmed)
  } catch {
    return null
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    return null
  }
  return url.origin
}

export function isLoopbackOrigin(origin: string): boolean {
  try {
    return LOOPBACK_HOSTNAMES.has(new URL(origin).hostname)
  } catch {
    return false
  }
}

/**
 * Leser en liste med opprinnelser fra miljøet.
 *
 * Skilletegnet er komma eller mellomrom, slik at den samme verdien kan skrives
 * på den formen plattformen gjør det lettest. En ugyldig verdi kaster her, ved
 * oppstart, framfor å bli et hull ingen oppdager.
 */
export function parseAllowedOrigins(raw: string | undefined, name: string): readonly string[] {
  if (raw === undefined) {
    return []
  }
  const origins: string[] = []
  for (const part of raw.split(/[\s,]+/)) {
    if (part.length === 0) {
      continue
    }
    const origin = normalizeOrigin(part)
    if (origin === null) {
      throw new Error(
        `Miljøvariabelen ${name} inneholder «${part}», som ikke er en opprinnelse. ` +
          'Skriv skjema og vert, for eksempel https://chatgpt.com.',
      )
    }
    origins.push(origin)
  }
  return origins
}

/** Mengden forespørselen skal måles mot, utledet av konfigurasjonen. */
export function originPolicy(input: {
  readonly baseUrl: string
  readonly allowedOrigins?: readonly string[] | undefined
}): OriginPolicy {
  const allowed = new Set<string>()
  for (const value of input.allowedOrigins ?? []) {
    const origin = normalizeOrigin(value)
    if (origin !== null) {
      allowed.add(origin)
    }
  }
  const selfOrigin = normalizeOrigin(input.baseUrl)
  return {
    allowed,
    selfOrigin,
    selfIsSecure: selfOrigin !== null && selfOrigin.startsWith('https://'),
  }
}

/** Dommen over én forespørsel. Ingen Origin er ingen dom å felle. */
export function judgeOrigin(raw: string | null, policy: OriginPolicy): OriginVerdict {
  if (raw === null) {
    // Spesifikasjonen krever avslag bare når headeren FINNES og ikke er
    // tillatt. Et kall fra en tjener har ingen opprinnelse å oppgi, og det er
    // nettopp slik en planlagt kjøring når fram.
    return { kind: 'absent' }
  }
  const origin = normalizeOrigin(raw)
  if (origin === null) {
    // Blant annet den lovlige verdien «null», som en sandkasset kontekst
    // sender. Den er ingen adresse, og skal ikke kunne bli til en.
    return { kind: 'forbidden', origin: raw }
  }
  if (policy.allowed.has(origin)) {
    return { kind: 'allowed', origin }
  }
  if (isLoopbackOrigin(origin)) {
    return { kind: 'allowed', origin }
  }
  if (policy.selfIsSecure && origin === policy.selfOrigin) {
    return { kind: 'allowed', origin }
  }
  return { kind: 'forbidden', origin }
}

/**
 * Den avviste opprinnelsen, på en form driftsloggen trygt kan bære.
 *
 * En avvisning uten navnet på det som ble avvist, er ikke til å feilsøke: den
 * eneste måten å skille «klienten står på en adresse ingen har listet opp» fra
 * «noen prøver seg» på, er å se adressen. Verdien går derfor gjennom den samme
 * normaliseringen som dommen, slik at loggen bærer en kanonisk opprinnelse og
 * aldri en fritekst kalleren valgte. Det som ikke er en opprinnelse, blir det
 * ene ordet `ugyldig`.
 */
export function loggableOrigin(verdict: OriginVerdict): string | undefined {
  if (verdict.kind === 'absent') {
    return undefined
  }
  return normalizeOrigin(verdict.origin) ?? 'ugyldig'
}
