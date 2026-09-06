// ============================================================================
// Å lese en fil som tekst, uten å endre en eneste byte
//
// Kildeversjonens fingeravtrykk er sha256 av representasjonen slik den ble
// hentet, og det skal kunne reproduseres med `sha256sum` på svaret fra
// adressen (migrasjon 007f). Da må veien inn i databasen bevare bytene.
//
// ----------------------------------------------------------------------------
// Hvorfor en fil og ikke et tekstfelt
//
// `<textarea>` kan ikke brukes til dette. HTML-standarden normaliserer
// linjeskift i feltets API-verdi: en representasjon med CRLF kommer ut som LF,
// og hashen ville blitt beregnet av noe annet enn det som faktisk lå på nettet.
// Verifikatoren, som hasher de faktiske bytene, ville da rapportert at kilden
// hadde endret seg — for en kilde som var uendret. Feilen er stille, den ser ut
// som et funn, og den ville rammet nettopp de kildene som leveres med CRLF.
//
// En fil har ingen slik normalisering: `arrayBuffer()` gir bytene slik de ble
// lagret. Det er derfor registreringen ber om en fil, ikke om innlimt tekst.
//
// ----------------------------------------------------------------------------
// Hvorfor UTF-8 kreves
//
// Databasen hasher `convert_to(tekst, 'UTF8')`, og verifikatoren gjør det
// samme. For en representasjon som er ren UTF-8, er det byte for byte det som
// lå på nettet. Er den ikke det, er hashen ikke lenger reproduserbar med
// `sha256sum` på svaret — og da skal registreringen avvises framfor å lagre et
// fingeravtrykk ingen kan etterprøve.
//
// ----------------------------------------------------------------------------
// Hvorfor `ignoreBOM: true`
//
// Navnet er invertert i forhold til hva det gjør. Uten flagget *fjerner*
// `TextDecoder` et innledende U+FEFF, og de tre bytene EF BB BF forsvinner ut
// av teksten som hashes. Det er nøyaktig den samme stille feilen som CRLF:
// fingeravtrykket ville beskrevet noe annet enn filen, og en kilde som
// leveres med BOM ville aldri kunne reprodusere sitt eget fingeravtrykk.
// Med flagget beholdes tegnet, og `convert_to(..., 'UTF8')` gir bytene
// tilbake uendret. Verifikatoren leser svaret sitt med samme flagg.
// ============================================================================

export type Utf8FileResult =
  | { readonly status: 'ok'; readonly text: string; readonly byteLength: number }
  | { readonly status: 'error'; readonly message: string }

/** Den delen av `File` denne modulen bruker. Injiserbar for tester. */
export interface ByteSource {
  readonly name: string
  arrayBuffer(): Promise<ArrayBuffer>
}

/**
 * Leser filen som UTF-8, uten trimming, uten normalisering av linjeskift og
 * uten omkoding.
 *
 * Returnerer aldri en avvisning som et kastet unntak: en fil i feil koding er
 * et normalt brukerfeil, og skjemaet skal kunne vise den som en setning.
 */
export async function readUtf8File(file: ByteSource): Promise<Utf8FileResult> {
  let bytes: Uint8Array
  try {
    bytes = new Uint8Array(await file.arrayBuffer())
  } catch {
    return { status: 'error', message: `Klarte ikke å lese filen «${file.name}».` }
  }

  if (bytes.length === 0) {
    return { status: 'error', message: `Filen «${file.name}» er tom.` }
  }

  try {
    return {
      status: 'ok',
      text: new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes),
      byteLength: bytes.length,
    }
  } catch {
    return {
      status: 'error',
      message:
        `Filen «${file.name}» er ikke gyldig UTF-8. Fingeravtrykket ville da ikke kunne ` +
        'etterprøves mot svaret fra adressen, og kildeversjonen registreres ikke.',
    }
  }
}
