// ============================================================================
// Modellgrensesnittet: alt en modelleverandør får lov til å være
//
//   identity            hvem svarte — leverandør, modell, modellversjon
//   complete(request)   én forespørsel inn, én tekst ut
//
// To ting, og ikke en tredje. Grensesnittet har ingen verktøy, ingen
// funksjonskall, ingen strømming, ingen retries og ingen tilgang til Antidep.
// Det er ikke en forenkling som venter på å bli utvidet: ANTIDEP_CONSTITUTION.md
// §20 krever at leverandører ligger bak utskiftbare adaptere, og et grensesnitt
// som lot leverandøren gjøre mer, ville gjort byttet til en migrering.
//
// ----------------------------------------------------------------------------
// Hvorfor svaret bare er tekst
//
// Enhver leverandør kan levere tekst. Strukturerte utdata heter forskjellige
// ting hos hver av dem — «JSON mode», «structured outputs», «tool use» — og et
// grensesnitt som forutsatte én av formene, ville vært bundet til den ene
// leverandøren i praksis, uansett hva navnet på typen sa.
//
// Kontrollen av formen ligger derfor der den uansett måtte ligge: i
// `parseExtractionDraft`, som avviser alt som ikke er kontrakten. Et svar fra en
// leverandør med garantert skjema går gjennom nøyaktig den samme kontrollen som
// et svar fra en leverandør uten. Det er hele poenget — garantien er vår, ikke
// leverandørens (EVIDENCE_PIPELINE.md §62).
//
// ----------------------------------------------------------------------------
// Hvorfor premissene henger på klienten og ikke på kallet
//
// `provenance.agent_runs` krever leverandør, modell og modellversjon per
// kjøring, og de tre er egenskaper ved adapteret — ikke ved forespørselen.
// Ligger de på klienten, kan en kjører ikke registrere en kjøring med andre
// premisser enn den faktisk kjørte under: verdien kommer fra det samme objektet
// som svarte (ANTIDEP_CONSTITUTION.md §20, EVIDENCE_PIPELINE.md §65).
//
// Promptmalversjonen hører derimot til forespørselen, fordi den er vår og ikke
// leverandørens.
//
// ----------------------------------------------------------------------------
// Ingen legitimasjon her
//
// Grensesnittet tar ingen nøkler og ingen konfigurasjon. Et adapter som trenger
// en API-nøkkel, leser den selv i sin egen konstruktør, av det samme miljøet
// som resten av kjørerne bruker (`agent-environment.ts`). Modell-leddet har
// uansett ingen databaselegitimasjon: det leser en kilde og skriver en fil, og
// har ingen skrivevei inn i Antidep (EVIDENCE_PIPELINE.md §63).
// ============================================================================

import { sourceVersionContentHash } from './content-hash.ts'

/** Hvem som svarte, i de tre feltene proveniensen krever. */
export interface ModelIdentity {
  readonly provider: string
  readonly model: string
  readonly modelVersion: string
}

/** Én forespørsel: den versjonerte malen, systemdelen og brukerdelen. */
export interface ModelRequest {
  /**
   * Versjonen av promptmalen forespørselen er bygget av.
   *
   * Registreres på kjøringen sammen med leverandør og modell, slik at det som
   * ble kjørt kan rekonstrueres i ettertid selv om malen senere endres
   * (ANTIDEP_CONSTITUTION.md §20).
   */
  readonly promptTemplateVersion: string
  readonly system: string
  readonly user: string
}

/** Svaret, ordrett slik leverandøren ga det. */
export interface ModelCompletion {
  readonly text: string
}

/**
 * Ett modelleverandøradapter.
 *
 * Implementasjonen kan være et HTTP-kall til en leverandør, en lokal modell
 * eller et opptak. Kjøreren ser ingen forskjell, og det er kravet: kjeden skal
 * kunne prøves uten en leverandørkonto, og et leverandørbytte skal være en
 * konfigurasjonsendring (EVIDENCE_PIPELINE.md §66).
 */
export interface ModelClient {
  readonly identity: ModelIdentity
  complete(request: ModelRequest): Promise<ModelCompletion>
}

/**
 * Fingeravtrykket av én forespørsel.
 *
 * Brukes to steder, og begge er kontroller framfor bekvemmeligheter:
 *
 *   * Opptaksadapteret slår opp svaret på nettopp dette avtrykket, slik at et
 *     opptak ikke kan spilles av for en *annen* artikkel eller en annen
 *     promptmal. Uten det ville et opptak vært et svar som passet på hva som
 *     helst — og en deterministisk prøve som egentlig ikke prøvde noe.
 *   * Kjøringen fører avtrykket i proveniensen, slik at «hva ble kjørt med
 *     hvilke premisser» også dekker selve forespørselen (EVIDENCE_PIPELINE.md
 *     §65).
 *
 * Serialiseringen er entydig: lengden på hver del står foran delen, så to
 * forskjellige oppdelinger ikke kan gi den samme strengen. `JSON.stringify` av
 * et objekt ville vært avhengig av nøkkelrekkefølgen, som ikke er en del av
 * forespørselen.
 */
export function modelRequestDigest(request: ModelRequest): Promise<string> {
  const parts = [request.promptTemplateVersion, request.system, request.user]
  return sourceVersionContentHash(parts.map((part) => `${String(part.length)}:${part}`).join('\n'))
}
