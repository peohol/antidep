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
//
// Den ugjennomsiktige opprinnelsen «null» er sin egen sak, og den avgjøres av
// ruten framfor av mengden. En sandkasset nettleserkontekst har ingen adresse å
// oppgi, og sender det ene ordet `null`. Den kan ikke listes opp — den er ikke
// en adresse, og ville dessuten vært den samme for enhver sandkasse på ethvert
// nettsted. Se `opaqueIsAllowed` for hvor den slipper inn, og hvorfor det ikke
// åpner noe.
// ============================================================================

/** Verter bare maskinen selv kan nå. */
const LOOPBACK_HOSTNAMES = new Set(['localhost', '127.0.0.1', '[::1]'])

export type OriginVerdict =
  | { readonly kind: 'absent' }
  | { readonly kind: 'allowed'; readonly origin: string }
  /** Den lovlige verdien «null»: en kontekst uten adresse, ikke en adresse. */
  | { readonly kind: 'opaque' }
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
  if (raw.trim() === 'null') {
    // Den lovlige verdien en sandkasset kontekst sender. Den er ingen adresse,
    // og skal ikke kunne bli til en — dommen sier bare hva den er, og ruten
    // avgjør resten.
    return { kind: 'opaque' }
  }
  const origin = normalizeOrigin(raw)
  if (origin === null) {
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
 * Om en ugjennomsiktig opprinnelse slipper inn på denne ruten.
 *
 * Bare tilkoblingssiden, og grunnen er at det ikke er noe der å beskytte med en
 * opprinnelse. Kontrollen finnes fordi en nettleserforespørsel kan bære
 * legitimasjon avsenderen ikke selv har: cookies, en pålogget økt, en lokal
 * tjener som stoler på maskinen sin. Denne appen har ingen av delene — den
 * holder ingen cookie, ingen økt og ingen påloggingstilstand, og alt
 * `/oauth/authorize` kan gjøre, krever engangskoden et menneske med
 * redaktørmandat nettopp har hentet. Uten den koden svarer ruten det samme til
 * alle.
 *
 * Avgjørende er hva unntaket faktisk legger til: ingenting. En forespørsel HELT
 * uten `Origin` slipper allerede inn overalt — det er slik den planlagte
 * kjøringen når fram — så enhver angriper kan allerede sende nøyaktig denne
 * forespørselen fra en tjener. En sandkasse har heller ingen legitimasjon å
 * bære: en ugjennomsiktig opprinnelse har verken cookies eller lager hos oss.
 *
 * Verktøyflaten er en annen sak, og der gjelder unntaket ikke. `/mcp` bærer et
 * token, og i utviklingsoppsettet står appen på maskinen selv — det er nettopp
 * der DNS rebinding lever, og der skal en kontekst uten adresse ikke nå fram.
 */
export function opaqueIsAllowed(route: string): boolean {
  return route === 'authorize'
}

/**
 * Lengste opprinnelse loggen skriver av.
 *
 * Grensen er strukturell og ikke en smaksdom: en vert kan være tusenvis av tegn
 * lang, og feltet står FØR autentiseringen. Uten et tak kunne hvem som helst
 * fylt driftsloggen med sine egne tegn, og det er ikke observability
 * (AGENTS.md). Hundre tegn er romslig for en adresse noen faktisk kunne listet
 * opp — `https://chatgpt.com` er nitten.
 */
const MAX_LOGGED_ORIGIN = 100

/**
 * Den avviste opprinnelsen, på en form driftsloggen trygt kan bære.
 *
 * En avvisning uten navnet på det som ble avvist, er ikke til å feilsøke: den
 * eneste måten å skille «klienten står på en adresse ingen har listet opp» fra
 * «noen prøver seg» på, er å se adressen. Verdien går derfor gjennom den samme
 * normaliseringen som dommen, slik at loggen bærer en kanonisk opprinnelse og
 * aldri en fritekst kalleren valgte.
 *
 * Tre utfall er faste ord framfor kallerens tegn, og til sammen gjør de feltet
 * bundet: en sandkasset kontekst uten adresse blir `ugjennomsiktig`, det som
 * ikke er en opprinnelse blir `ugyldig`, og det som er lengre enn en adresse
 * noen kunne listet opp, blir `for-lang`. Ingen av delene taper noe å feilsøke
 * etter: en adresse på over hundre tegn er uansett ikke den klienten står på.
 *
 * En tillatt opprinnelse navngis ikke. Den er ikke noe å feilsøke.
 */
export function loggableOrigin(verdict: OriginVerdict): string | undefined {
  if (verdict.kind === 'absent' || verdict.kind === 'allowed') {
    return undefined
  }
  if (verdict.kind === 'opaque') {
    return 'ugjennomsiktig'
  }
  const origin = normalizeOrigin(verdict.origin)
  if (origin === null) {
    return 'ugyldig'
  }
  return origin.length > MAX_LOGGED_ORIGIN ? 'for-lang' : origin
}
