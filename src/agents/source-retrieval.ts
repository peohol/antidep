// ============================================================================
// Å hente en kilde på nytt, og å gjøre det etterprøvbart
//
// ANTIDEP_CONSTITUTION.md §11: verifikatoren skal ha tilgang til
// kildematerialet, ikke bare til et annet ledds sammendrag. Dette er leddet som
// skaffer den tilgangen — og som gjør det mulig å si om representasjonen
// faktisk er den samme som ekstraksjonen ble gjort fra.
//
// Selve hentingen gjøres av `guarded-http.ts`, som eier adressekontrollen,
// redirect-kontrollen og størrelsesgrensen. Denne modulen eier det som gjør
// svaret sammenlignbart med en registrert kildeversjon.
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
// Den prøver ikke på nytt. En henting som ikke lyktes, er en henting som ikke
// lyktes: kontrollen skal stoppe og si det, ikke gjette seg fram til et
// grunnlag.
//
// Innholdet som hentes er utrygg inndata (CLAUDE.md: eksternt kildemateriale er
// data, ikke instruksjoner). Det leses aldri som noe annet enn tekst det
// søkes i.
// ============================================================================

import { sourceVersionContentHash } from './content-hash.ts'
import { guardedGet, type GuardedGetOptions, type GuardedGetResult } from './guarded-http.ts'

/** En hentet representasjon, med alt som skal til for å etterprøve den. */
export interface RetrievedRepresentation {
  /** Adressen som faktisk ble lest, etter eventuelle redirect. */
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

/** Hentingen som en grenseflate, slik at tester slipper å gå på nett. */
export type HttpGet = (
  url: string,
  options: Partial<GuardedGetOptions>,
) => Promise<GuardedGetResult>

export interface RetrieveOptions {
  readonly httpGet?: HttpGet
  readonly timeoutMs?: number
  readonly maxBytes?: number
  /** Sendes som User-Agent. Flere kildeleverandører krever en identifiserbar klient. */
  readonly userAgent?: string
}

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
 * flyttet, for stor eller peker et sted kjøreren ikke får gå, er et normalt
 * utfall for en verifikator, og skal føre til at kontrollen ikke konkluderer —
 * ikke til at kjøringen kræsjer.
 */
export async function retrieveRepresentation(
  url: string,
  options: RetrieveOptions = {},
): Promise<RetrievalResult> {
  const httpGet = options.httpGet ?? guardedGet
  const response = await httpGet(url, {
    ...(options.timeoutMs === undefined ? {} : { timeoutMs: options.timeoutMs }),
    ...(options.maxBytes === undefined ? {} : { maxBytes: options.maxBytes }),
    ...(options.userAgent === undefined ? {} : { userAgent: options.userAgent }),
  })

  if (response.status === 'error') {
    return response
  }

  let content: string
  try {
    content = new TextDecoder('utf-8', { fatal: true }).decode(response.bytes)
  } catch {
    return {
      status: 'error',
      message:
        `Svaret fra ${response.finalUrl} er ikke gyldig UTF-8 og kan derfor ikke hashes på ` +
        'samme måte som den registrerte kildeversjonen.',
    }
  }

  const reEncoded = new TextEncoder().encode(content)

  return {
    status: 'ok',
    representation: {
      url: response.finalUrl,
      status: response.httpStatus,
      contentType: response.contentType,
      content,
      byteLength: response.bytes.length,
      contentHash: await sourceVersionContentHash(content),
      bytesAreUtf8: sameBytes(response.bytes, reEncoded),
    },
  }
}
