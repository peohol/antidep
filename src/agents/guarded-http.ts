// ============================================================================
// HTTP-henting med adressekontroll, redirect-kontroll og størrelsesgrense
//
// Kjøreren henter adresser en redaktør har registrert, fra en betrodd maskin.
// Uten kontrollene her ville `retrieved_from` vært en fjernstyring av hva den
// maskinen kobler seg til — en SSRF-vei fra en runner som ellers har tilgang til
// interne tjenester og til skyens metadatatjeneste.
//
// ----------------------------------------------------------------------------
// Hvorfor `node:https` og ikke `fetch`
//
// `fetch` slår opp DNS selv, inne i socketen, og gir ingen mulighet til å se
// eller godkjenne adressen den faktisk kobler til. Å slå opp navnet først og så
// kalle `fetch` er ikke det samme: mellom kontrollen og tilkoblingen kan svaret
// fra DNS ha endret seg (DNS-rebinding), og da er det den ukontrollerte adressen
// socketen bruker.
//
// `node:http` og `node:https` tar derimot imot en `lookup`-funksjon som
// socketen bruker *som sitt eget* navneoppslag. Adressen vi godkjenner er
// dermed nøyaktig den adressen det kobles til, og TOCTOU-vinduet forsvinner —
// ikke fordi vi rekker å sjekke i tide, men fordi det ikke finnes to oppslag å
// komme imellom.
//
// Prisen er at redirect, tidsavbrudd og lesing av kroppen må skrives for hånd.
// Det er ingen ulempe her: alle tre skal uansett kontrolleres.
//
// ----------------------------------------------------------------------------
// Hva som kontrolleres
//
//   Protokoll        bare http og https. `file:`, `ftp:` og resten avvises.
//   Adresse          to veier, fordi det er to tilfeller. Er verten et navn,
//                    kontrolleres hver adresse navnet slår opp til, gjennom
//                    `lookup` — den samme funksjonen socketen bruker. Er verten
//                    allerede en IP-adresse, slår Node aldri opp noe, og
//                    `lookup` blir aldri kalt; adressen kontrolleres derfor
//                    direkte før forespørselen sendes. Begge veier gjelder for
//                    hvert redirect-hopp, ikke bare for den første adressen.
//   Redirect         høyst `maxRedirects` hopp, hvert med ny protokollkontroll
//                    og ny adressekontroll. En Location uten verdi, eller en
//                    som ikke lar seg lese som URL, avslutter hentingen.
//   Størrelse        lesingen avbrytes idet grensen passeres, og forbindelsen
//                    rives. Kroppen samles aldri opp ubegrenset.
//   Tid              ett samlet tidsavbrudd for hele hentingen, redirect
//                    inkludert. Tidsavbruddet river forbindelsen; et
//                    tidsavbrudd som bare sluttet å vente, ville latt kilden
//                    fortsette å strømme i bakgrunnen, og en kø med mange
//                    kilder ville samlet opp åpne socketer.
//
// ----------------------------------------------------------------------------
// Miljøer med utgående proxy
//
// Kontrollen gjelder adressen socketen kobler til. Kjører Antidep en dag bak en
// utgående HTTP-proxy, er det proxyens adresse som kontrolleres — og en proxy
// på et privat nett vil derfor bli avvist. Det er riktig oppførsel for den
// vakten som finnes nå, men det er også grunnen til at en slik oppsettsendring
// må gjøres bevisst og ikke ved at kontrollen mykes opp.
// ============================================================================

import { lookup as systemLookup, type LookupAddress } from 'node:dns'
import { request as httpRequest, type ClientRequest, type IncomingMessage } from 'node:http'
import { request as httpsRequest } from 'node:https'

import { judgeAddress, parseIpAddress } from './address-guard.ts'

/** Predikatet som avgjør om én oppslått adresse kan nås. */
export type AddressPolicy = (address: string) => { allowed: boolean; reason?: string | undefined }

export interface GuardedGetOptions {
  readonly maxBytes: number
  readonly timeoutMs: number
  readonly maxRedirects: number
  readonly userAgent: string
  /**
   * Bare for tester. Standardverdien er den faktiske vakten, og en test som
   * skal nå en lokal server, må si eksplisitt fra at den gjør det — den kan
   * ikke skje ved et uhell.
   */
  readonly addressPolicy?: AddressPolicy
}

export const GUARDED_GET_DEFAULTS = {
  /** 16 MiB. Nok til en fulltekstside, langt under det som tømmer en runner. */
  maxBytes: 16 * 1024 * 1024,
  timeoutMs: 30_000,
  maxRedirects: 5,
  userAgent: 'Antidep-ExtractionVerifier/1 (+https://github.com/peohol/antidep)',
} as const

export type GuardedGetResult =
  | {
      readonly status: 'ok'
      readonly httpStatus: number
      readonly contentType: string | null
      readonly bytes: Uint8Array
      /** Adressen som faktisk ble lest, etter eventuelle redirect. */
      readonly finalUrl: string
    }
  | { readonly status: 'error'; readonly message: string }

function policyFor(options: GuardedGetOptions): AddressPolicy {
  return options.addressPolicy ?? ((address) => judgeAddress(address))
}

/**
 * Kontrollen for en vert som allerede *er* en adresse.
 *
 * Node slår ikke opp noe når verten er en IP-adresse, så `lookup` blir aldri
 * kalt og vakten der ville aldri sett den. Uten denne kontrollen ville
 * `http://127.0.0.1:8080/` gått rett gjennom — og det er den enkleste formen en
 * SSRF-adresse har.
 *
 * `null` betyr at verten er et navn, og at `lookup` er den som kontrollerer den.
 */
function judgeLiteralHost(hostname: string, policy: AddressPolicy): string | null {
  // URL-en skriver IPv6-verter i klammer; adressen selv har ingen.
  const literal =
    hostname.startsWith('[') && hostname.endsWith(']') ? hostname.slice(1, -1) : hostname
  if (parseIpAddress(literal) === null) {
    return null
  }
  const verdict = policy(literal)
  if (verdict.allowed) {
    return null
  }
  return (
    `${literal} er ikke en offentlig internettadresse (${verdict.reason ?? 'avvist'}). ` +
    'Kjøreren henter bare kilder fra det offentlige internettet.'
  )
}

/**
 * Dommen over alle adressene ett navn slo opp til.
 *
 * Alle kontrolleres — ikke bare den første. Et navn som peker både på en
 * offentlig og en privat adresse, avvises i sin helhet: å plukke den offentlige
 * ville gjort utfallet avhengig av rekkefølgen resolveren tilfeldigvis svarer i,
 * og det er nøyaktig den rekkefølgen en angriper kan styre.
 *
 * `null` betyr at alle adressene kan nås.
 */
export function judgeResolvedAddresses(
  hostname: string,
  addresses: readonly string[],
  policy: AddressPolicy,
): string | null {
  if (addresses.length === 0) {
    return `${hostname} slo ikke opp til noen adresse.`
  }
  for (const address of addresses) {
    const verdict = policy(address)
    if (!verdict.allowed) {
      return (
        `${hostname} slo opp til ${address}, som ikke er en offentlig ` +
        `internettadresse (${verdict.reason ?? 'avvist'}). Kjøreren henter bare ` +
        'kilder fra det offentlige internettet.'
      )
    }
  }
  return null
}

/**
 * Navneoppslaget socketen bruker.
 *
 * Se `judgeResolvedAddresses` for regelen; her er poenget at den kjøres inne i
 * socketens eget oppslag, slik at adressen vi godkjenner er adressen det kobles
 * til.
 */
function guardedLookup(policy: AddressPolicy): typeof systemLookup {
  const lookup = (hostname: string, options: unknown, callback: unknown): void => {
    // Node kaller `lookup` med (hostname, options, callback) eller
    // (hostname, callback). Begge formene må støttes.
    const done = (typeof options === 'function' ? options : callback) as (
      error: NodeJS.ErrnoException | null,
      address?: string | LookupAddress[],
      family?: number,
    ) => void
    const wantsAll =
      typeof options === 'object' && options !== null && (options as { all?: boolean }).all === true

    systemLookup(hostname, { all: true, verbatim: true }, (error, addresses) => {
      if (error !== null) {
        done(error)
        return
      }
      const problem = judgeResolvedAddresses(
        hostname,
        addresses.map((candidate) => candidate.address),
        policy,
      )
      if (problem !== null) {
        done(Object.assign(new Error(problem), { code: 'EACCES' }))
        return
      }
      if (wantsAll) {
        done(null, addresses)
        return
      }
      const first = addresses[0]
      done(null, first?.address, first?.family)
    })
  }
  return lookup as unknown as typeof systemLookup
}

function readBody(
  response: IncomingMessage,
  maxBytes: number,
): Promise<{ bytes: Uint8Array } | { tooLarge: true }> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    response.on('data', (chunk: Buffer) => {
      size += chunk.length
      if (size > maxBytes) {
        // Riv forbindelsen framfor å lese ferdig: grensen finnes for at en
        // kilde ikke skal kunne bruke opp minnet til kjøreren.
        response.destroy()
        resolve({ tooLarge: true })
        return
      }
      chunks.push(chunk)
    })
    response.on('end', () => {
      resolve({ bytes: new Uint8Array(Buffer.concat(chunks)) })
    })
    response.on('error', reject)
  })
}

interface Hop {
  readonly status: number
  readonly headers: Record<string, string | string[] | undefined>
  readonly response: IncomingMessage
}

/**
 * Sender forespørselen, og gir kalleren både svaret og selve forespørselen.
 *
 * `ClientRequest` returneres synkront og ikke gjennom promisen, fordi den
 * trengs nettopp når promisen *ikke* løser seg: et tidsavbrudd må kunne rive
 * forbindelsen, og det kan den bare gjøre hvis den har noe å rive.
 */
function sendRequest(
  url: URL,
  options: GuardedGetOptions,
  policy: AddressPolicy,
): { readonly request: ClientRequest; readonly hop: Promise<Hop> } {
  const send = url.protocol === 'https:' ? httpsRequest : httpRequest
  let settle: (hop: Hop) => void = () => {}
  let fail: (error: unknown) => void = () => {}
  const hop = new Promise<Hop>((resolve, reject) => {
    settle = resolve
    fail = reject
  })

  const request = send(
    url,
    {
      method: 'GET',
      headers: { accept: '*/*', 'user-agent': options.userAgent },
      lookup: guardedLookup(policy),
    },
    (response) => {
      settle({ status: response.statusCode ?? 0, headers: response.headers, response })
    },
  )
  // Alltid en lytter: en `destroy()` etter at promisen er avgjort, gir et
  // error-event som ellers ville blitt en uhåndtert feil i prosessen.
  request.on('error', (error) => {
    fail(error)
  })
  request.end()

  return { request, hop }
}

/**
 * Henter én adresse, med alle kontrollene i hodekommentaren.
 *
 * Returnerer aldri en avvisning som et kastet unntak: en kilde som er nede,
 * flyttet, for stor eller peker et sted kjøreren ikke får gå, er et normalt
 * utfall for en verifikator — kontrollen skal da ikke konkludere, ikke kræsje.
 */
export async function guardedGet(
  url: string,
  overrides: Partial<GuardedGetOptions> = {},
): Promise<GuardedGetResult> {
  const options: GuardedGetOptions = { ...GUARDED_GET_DEFAULTS, ...overrides }
  const policy = policyFor(options)

  let current: URL
  try {
    current = new URL(url)
  } catch {
    return { status: 'error', message: `Adressen «${url}» er ikke en gyldig URL.` }
  }

  // Ett samlet tidsavbrudd for hele hentingen. En grense per hopp ville latt en
  // kjede av trege redirect bruke vilkårlig lang tid til sammen.
  const expiry = Date.now() + options.timeoutMs

  // Forespørselen som er i luften akkurat nå. Den rives i `finally`, uansett
  // hvilken vei funksjonen forlates: tidsavbrudd, avvist redirect, for stort
  // svar eller et vellykket svar. Uten det ville en avbrutt henting etterlatt
  // en åpen socket, og en kø med mange kilder ville samlet dem opp.
  let active: ClientRequest | null = null

  try {
    for (let hop = 0; hop <= options.maxRedirects; hop += 1) {
      if (current.protocol !== 'https:' && current.protocol !== 'http:') {
        return {
          status: 'error',
          message: `Adressen «${current.href}» bruker ${current.protocol}, som ikke kan hentes over nett.`,
        }
      }
      const literalProblem = judgeLiteralHost(current.hostname, policy)
      if (literalProblem !== null) {
        return { status: 'error', message: `Klarte ikke å hente ${url}: ${literalProblem}` }
      }
      if (Date.now() > expiry) {
        return { status: 'error', message: `Hentingen av ${url} brukte for lang tid.` }
      }

      const attempt = sendRequest(current, options, policy)
      active = attempt.request
      const hopResult = await withTimeout(attempt.hop, Math.max(1, expiry - Date.now()))
      if (hopResult.status === 'timeout') {
        return { status: 'error', message: `Hentingen av ${url} brukte for lang tid.` }
      }
      const { status, headers, response } = hopResult.value

      if (status >= 300 && status < 400) {
        // `destroy()` og ikke `resume()`: en redirect-kropp skal ikke leses, og
        // en server som strømmer i det uendelige skal ikke få lov til å gjøre
        // det i bakgrunnen mens vi henter neste hopp.
        response.destroy()
        const location = headers['location']
        const target = Array.isArray(location) ? location[0] : location
        if (target === undefined || target.trim().length === 0) {
          return {
            status: 'error',
            message: `Kilden svarte ${String(status)} på ${current.href} uten å si hvor den er flyttet.`,
          }
        }
        let next: URL
        try {
          next = new URL(target, current)
        } catch {
          return {
            status: 'error',
            message: `Kilden svarte ${String(status)} på ${current.href} med en Location som ikke er en gyldig URL.`,
          }
        }
        current = next
        continue
      }

      if (status < 200 || status >= 300) {
        // Samme grunn som over: kroppen til et feilsvar skal ikke leses ferdig.
        response.destroy()
        return { status: 'error', message: `Kilden svarte ${String(status)} på ${current.href}.` }
      }

      const body = await withTimeout(
        readBody(response, options.maxBytes),
        Math.max(1, expiry - Date.now()),
      )
      if (body.status === 'timeout') {
        return { status: 'error', message: `Hentingen av ${url} brukte for lang tid.` }
      }
      if ('tooLarge' in body.value) {
        return {
          status: 'error',
          message:
            `Svaret fra ${current.href} er større enn grensen på ` +
            `${String(options.maxBytes)} byte, og ble ikke lest ferdig.`,
        }
      }

      const contentType = headers['content-type']
      return {
        status: 'ok',
        httpStatus: status,
        contentType: Array.isArray(contentType) ? (contentType[0] ?? null) : (contentType ?? null),
        bytes: body.value.bytes,
        finalUrl: current.href,
      }
    }

    return {
      status: 'error',
      message: `Hentingen av ${url} ble videresendt mer enn ${String(options.maxRedirects)} ganger.`,
    }
  } catch (cause) {
    const reason = cause instanceof Error ? cause.message : String(cause)
    return { status: 'error', message: `Klarte ikke å hente ${url}: ${reason}` }
  } finally {
    active?.destroy()
  }
}

type Timed<T> = { readonly status: 'ok'; readonly value: T } | { readonly status: 'timeout' }

function withTimeout<T>(work: Promise<T>, ms: number): Promise<Timed<T>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      resolve({ status: 'timeout' })
    }, ms)
    work.then(
      (value) => {
        clearTimeout(timer)
        resolve({ status: 'ok', value })
      },
      (error: unknown) => {
        clearTimeout(timer)
        reject(error instanceof Error ? error : new Error(String(error)))
      },
    )
  })
}
