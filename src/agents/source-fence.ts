// ============================================================================
// Gjerdet rundt kildeteksten i en modellforespørsel
//
// Kildetekst er utrygg ekstern data. Den kan inneholde tekst som ser ut som en
// instruksjon, og malene sier eksplisitt at slik tekst skal leses som en del av
// dokumentet og aldri følges (ANTIDEP_CONSTITUTION.md §19). Setningen alene er
// ikke nok: teksten må også være entydig avgrenset, slik at ingenting i den kan
// se ut som om gjerdet var slutt.
//
// Markøren utledes derfor av representasjonens eget fingeravtrykk, og ikke av en
// fast streng: en artikkel kan ikke inneholde en markør den ikke kjenner, og en
// fast markør ville stått i enhver kilde som noen gang hadde lest denne koden.
// Inneholder teksten likevel markøren, bygges ingen forespørsel i det hele tatt.
//
// ----------------------------------------------------------------------------
// Hvorfor dette er en egen modul
//
// To modell-ledd gjerder inn den samme slags tekst — ekstraksjonsutkastet
// (`extraction-prompt.ts`) og den kildeomfattende fraværsgjennomlesningen
// (`absence-review.ts`) — og regelen skal være den samme for begge. To kopier
// ville kunnet komme i utakt om hvor lang markøren er, eller om hva som skjer
// når teksten inneholder den.
//
// Modulen importerer ingenting. Det er ikke tilfeldig: den ligger under både
// promptmalene og den deterministiske kontrollen, og en import herfra ville
// laget en syklus mellom dem (`source-excerpt.ts` leser fra
// `extraction-checks.ts`, som leser fraværskontrakten).
// ============================================================================

/** Hvor mange tegn av fingeravtrykket markøren bærer. */
const FENCE_LENGTH = 16

/** Markøren kildeteksten står mellom, utledet av representasjonens eget avtrykk. */
export function sourceFence(contentHash: string): string {
  return contentHash.replace(/^sha256:/, '').slice(0, FENCE_LENGTH)
}

/**
 * Kildeteksten mellom markørene, eller et kast dersom gjerdet ikke kan holde.
 *
 * Rent uttrykk: den samme inndataen gir den samme teksten, hver gang. Det er
 * forutsetningen for at `modelRequestDigest` binder et svar til nøyaktig den
 * teksten forespørselen ble bygget av.
 */
export function fencedSourceText(contentHash: string, representation: string): string {
  const fence = sourceFence(contentHash)
  const open = `<kildetekst nonce="${fence}">`
  const close = `</kildetekst nonce="${fence}">`

  if (representation.includes(open) || representation.includes(close)) {
    throw new Error(
      `Representasjonen inneholder selv markøren «${fence}», som gjerdet rundt kildeteksten ` +
        'bruker. Da kan gjerdet ikke holde, og ingen forespørsel bygges.',
    )
  }

  return `${open}\n${representation}\n${close}`
}
