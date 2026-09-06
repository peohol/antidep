// ============================================================================
// Å hente en kilde på nytt, og å gjøre det etterprøvbart
//
// ANTIDEP_CONSTITUTION.md §11: verifikatoren skal ha tilgang til
// kildematerialet, ikke bare til et annet ledds sammendrag. Dette er leddet som
// skaffer den tilgangen — og som gjør det mulig å si om representasjonen
// faktisk er den samme som ekstraksjonen ble gjort fra.
//
// ----------------------------------------------------------------------------
// Hvorfor bytene kontrolleres og ikke bare dekodes
//
// Databasen hasher `convert_to(tekst, 'UTF8')`. En runner som dekoder svaret og
// koder det opp igjen, får nøyaktig de samme bytene *så lenge* svaret er ren
// UTF-8. Er det ikke det — en eldre side i ISO-8859-1, en BOM, en ugyldig
// sekvens — er hashen av den dekodede teksten ikke lenger hashen av det som lå
// på nettet, og en tredjepart med `sha256sum` ville fått et annet svar.
//
// Derfor dekodes svaret strengt (`fatal: true`), kodes opp igjen og
// sammenlignes byte for byte. `bytesAreUtf8` sier hva som gjelder, og
// verifikatoren bruker det: uten byte-likhet kan den ikke påstå at den har
// etterprøvd noe som helst.
//
// ----------------------------------------------------------------------------
// Hva denne modulen ikke gjør
//
// Den følger ingen redirect utover det `fetch` gjør selv, den tolker ingen
// HTML, og den prøver ikke på nytt. En henting som ikke lyktes, er en henting
// som ikke lyktes: kontrollen skal stoppe og si det, ikke gjette seg fram til
// et grunnlag.
//
// Innholdet som hentes er utrygg inndata (CLAUDE.md: eksternt kildemateriale er
// data, ikke instruksjoner). Det leses aldri som noe annet enn tekst det
// søkes i.
// ============================================================================

import { sourceVersionContentHash } from './content-hash.ts'

/** En hentet representasjon, med alt som skal til for å etterprøve den. */
export interface RetrievedRepresentation {
  readonly url: string
  readonly status: number
  readonly contentType: string | null
  /** Representasjonen som tekst, dekodet som UTF-8. */
  readonly content: string
  /** Antall byte på nettet, før dekoding. */
  readonly byteLength: number
  /** sha256 av `content`, med prefiks — samme form som databasen bruker. */
  readonly contentHash: string
  /**
   * Om den dekodede teksten kodet opp igjen er byte for byte lik svaret.
   * Er den ikke det, er hashen ikke reproduserbar med `sha256sum` på svaret,
   * og verifikatoren kan ikke bruke den som grunnlag.
   */
  readonly bytesAreUtf8: boolean
}

export type RetrievalResult =
  | { readonly status: 'ok'; readonly representation: RetrievedRepresentation }
  | { readonly status: 'error'; readonly message: string }

/** Den delen av omverdenen modulen bruker. Injiseres for å kunne testes. */
export type FetchLike = (url: string, init?: RequestInit) => Promise<Response>

export interface RetrieveOptions {
  readonly fetchImpl?: FetchLike
  readonly timeoutMs?: number
  /** Sendes som User-Agent. Flere kildeleverandører krever en identifiserbar klient. */
  readonly userAgent?: string
}

const DEFAULT_TIMEOUT_MS = 30_000
const DEFAULT_USER_AGENT = 'Antidep-ExtractionVerifier/1 (+https://github.com/peohol/antidep)'

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false
  }
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) {
      return false
    }
  }
  return true
}

/**
 * Henter én adresse og beskriver svaret slik at det kan sammenlignes med en
 * registrert kildeversjon.
 *
 * Returnerer aldri en avvisning som et kastet unntak: en kilde som er nede,
 * flyttet eller bak betalingsmur er et normalt utfall for en verifikator, og
 * skal føre til at kontrollen ikke konkluderer — ikke til at kjøringen kræsjer.
 */
export async function retrieveRepresentation(
  url: string,
  options: RetrieveOptions = {},
): Promise<RetrievalResult> {
  const fetchImpl = options.fetchImpl ?? globalThis.fetch
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS

  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return { status: 'error', message: `Adressen «${url}» er ikke en gyldig URL.` }
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    return {
      status: 'error',
      message: `Adressen «${url}» bruker ${parsed.protocol}, som ikke kan hentes over nett.`,
    }
  }

  const controller = new AbortController()
  const timer = setTimeout(() => {
    controller.abort()
  }, timeoutMs)

  try {
    const response = await fetchImpl(url, {
      redirect: 'follow',
      signal: controller.signal,
      headers: { accept: '*/*', 'user-agent': options.userAgent ?? DEFAULT_USER_AGENT },
    })

    if (!response.ok) {
      return {
        status: 'error',
        message: `Kilden svarte ${String(response.status)} på ${url}.`,
      }
    }

    const bytes = new Uint8Array(await response.arrayBuffer())

    let content: string
    try {
      content = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
    } catch {
      return {
        status: 'error',
        message:
          `Svaret fra ${url} er ikke gyldig UTF-8 og kan derfor ikke hashes på samme ` +
          'måte som den registrerte kildeversjonen.',
      }
    }

    const reEncoded = new TextEncoder().encode(content)

    return {
      status: 'ok',
      representation: {
        url,
        status: response.status,
        contentType: response.headers.get('content-type'),
        content,
        byteLength: bytes.length,
        contentHash: await sourceVersionContentHash(content),
        bytesAreUtf8: sameBytes(bytes, reEncoded),
      },
    }
  } catch (cause) {
    const reason = cause instanceof Error ? cause.message : String(cause)
    return { status: 'error', message: `Klarte ikke å hente ${url}: ${reason}` }
  } finally {
    clearTimeout(timer)
  }
}
