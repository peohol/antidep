// ============================================================================
// Re-ekstraksjonen: en trygg vei fra en gammel rad til et forankret funn
//
//   forslag (fil)                  eksternt produsert, kontrollert på form
//   runEvidenceExtraction          henter kilden, prøver utdragene, registrerer
//   runExtractionVerification      den deterministiske kontrollen, på det nye funnet
//
// ----------------------------------------------------------------------------
// Hva den finnes for
//
// Evidensfunnene fra golden slicen ble registrert før forankringen fantes som
// data. De er ukontrollerbare felt for felt, og kontrolløkten stopper på dem —
// som er riktig oppførsel, ikke en feil.
//
// Løsningen er *ikke* å legge forankring på de gamle radene i etterkant. En
// forankring lagt til retroaktivt ville påstått at den gamle ekstraksjonen ble
// laget av nettopp de utdragene, og det vet ingen. `knowledge.evidence_items` er
// dessuten append-only, og en normal redaksjonell arbeidsflyt skal aldri slette
// klinisk relevant historikk (CLAUDE.md, ANTIDEP_CONSTITUTION.md §14).
//
// Veien er derfor å ekstrahere på nytt: et forslag laget av den *samme*
// kildeversjonen blir et nytt, forankret evidensfunn ved siden av det gamle. Det
// gamle består som historisk objekt, urørt.
//
// ----------------------------------------------------------------------------
// Hvorfor den er idempotent, og hva som gjør den det
//
// `evidence_items_content_hash_key` dekker de strukturerte verdiene på raden
// *og* avtrykket av kildeforankringen (migrasjon 003d). Kjøres det samme
// forslaget om igjen, avviser databasen registreringen som en dublett, og
// kjøringen rapporterer `already_registered` framfor å skrive noe. Ingen lokal
// bokføring, ingen «har jeg gjort dette før?»-fil: fasiten er basen.
//
// En dublett betyr derfor noe strengere enn før: den samme ekstraksjonen med den
// samme forankringen. Et forslag som bare retter et utdrag, en peker eller en
// begrunnelse, er et *annet* evidensfunn og registreres ved siden av det gamle.
// Det gamle består urørt, og det nye arver ingenting — verken maskinbeviset,
// den menneskelige kontrollen, claim-lenkene eller en publiseringsgodkjenning.
// Det går derfor gjennom den ordinære deterministiske kontrollen her, som
// ethvert annet nytt funn.
//
// ----------------------------------------------------------------------------
// En avbrutt kjøring skal kunne fullføres
//
// Registreringen og kontrollen er to skrivinger, i to transaksjoner. Dør
// prosessen mellom dem, finnes raden uten maskinbevis — og en ny kjøring med det
// samme forslaget får bare «dublett» tilbake, uten en id å kontrollere.
//
// Databasen navngir da raden som kolliderte, og kjøringen fullfører kontrollen
// av nøyaktig den. Den rører ingen annen rad, og skriver ingen ny.
//
// ----------------------------------------------------------------------------
// Hvilken rad dubletten gjaldt, og hva den sier
//
// Databasen navngir raden som kolliderte (migrasjon 007h), slått opp med den
// samme kanoniske identiteten UNIQUE-regelen bruker. Kjøringen leser derfor
// nøyaktig den raden — ikke en rad som ligner — og avgjør på den:
//
//   * Raden har allerede et gjeldende maskinbevis → kjeden er komplett.
//     Ingenting skrives.
//   * Raden mangler beviset → en avbrutt kjøring. Kontrollen fullføres, og
//     ingen ny rad skrives.
//
// Kjøringen sammenligner ikke forankringen selv. Den er en del av identiteten
// databasen slo opp på (migrasjon 003d), så den navngitte raden *er* forslagets
// forankring; en sammenligning her ville bare kunnet ta feil. Identiteten kommer
// fra databasen og ikke fra en likhet kjøreren finner på: to funn fra den samme
// kildeversjonen kan legitimt dele forankring — det samme utvalgsutdraget, den
// samme populasjonssetningen — og likevel gjelde ulike utfall.
//
// ----------------------------------------------------------------------------
// Hvor den stopper, og hvorfor den stopper der
//
// Den registrerer funnet og kontrollerer det deterministisk. Den lenker det
// *ikke* til en påstandsrevisjon. Å avgjøre at et funn støtter, motsier eller er
// indirekte relevant for en formulering er en faglig vurdering, ikke en teknisk
// operasjon (ANTIDEP_CONSTITUTION.md §12, §15) — og agenten har verken
// editor-rolle eller skrivevei til `knowledge.claim_evidence_links`. Den delen
// gjør en kvalifisert redaktør i adminflyten, på det nye funnet.
// ============================================================================

import type { Uuid } from '../types/api.ts'
import type {
  AgentRunPremises,
  EvidenceExtractionApi,
  ExtractionVerificationApi,
} from './agent-api.ts'
import type { ExtractionProposal } from './extraction-proposal.ts'
import type { ExtractionRunReport, RetrieveLike } from './extraction-run.ts'
import { runEvidenceExtraction } from './extraction-run.ts'
import type { RegistrationMode } from './extraction-proposal.ts'
import type { RunReport } from './extraction-verification-run.ts'
import { runExtractionVerification } from './extraction-verification-run.ts'
import type { RetrieveOptions } from './source-retrieval.ts'

/** Ett forslag, med navnet det ble lest under, slik rapporten kan navngi det. */
export interface LabelledProposal {
  readonly label: string
  readonly proposal: ExtractionProposal
}

export interface ReextractionOptions {
  readonly extractionApi: EvidenceExtractionApi
  readonly verificationApi: ExtractionVerificationApi
  /**
   * Kontrollens premisser. Ekstraksjonens står ikke her: de er forslagets egne,
   * og hvert forslag i køen kan ha sin egen produsent (`pipeline-version.ts`).
   */
  readonly verificationPremises: AgentRunPremises
  readonly proposals: readonly LabelledProposal[]
  /**
   * Arbeidsformen hele køen registreres under. **Påkrevd.**
   *
   * Én modus for hele køen, og ikke én per forslag: modusen er kallerens
   * tiltrodde påstand om hva slags arbeid dette er, og en kø der hvert forslag
   * bestemte sin egen, ville vært den samme feilen om igjen — filen ville
   * avgjort hva den ble registrert som (`extraction-proposal.ts`).
   *
   * Re-ekstraksjonen har ingen oppdrag å kontrollere mot, så modusen her er
   * enten `unchecked_model` eller `without_assignment`. Den første fører raden
   * som KI-assistert og lar kjøringen si at avgrensningen ikke ble
   * kontrollert; den andre er en redaktørs eget arbeid.
   */
  readonly mode: RegistrationMode
  /** Hent og kontroller, men registrer ingenting og kontroller ingenting. */
  readonly dryRun?: boolean
  readonly retrieve?: RetrieveLike
  readonly retrieveOptions?: RetrieveOptions
  readonly log?: (line: string) => void
}

export interface ReextractionResult {
  readonly label: string
  readonly sourceVersionId: Uuid
  readonly extraction: ExtractionRunReport
  /**
   * Den deterministiske kontrollen av nettopp det funnet forslaget gjelder.
   *
   * Mangler bare når det ikke finnes noen rad å kontrollere: en tørrkjøring
   * eller et forslag som ikke holdt mål. En dublett har en rad, og den
   * kontrolleres — se hodekommentaren om avbrutte kjøringer.
   */
  readonly verification?: RunReport
  /**
   * Om funnet står med et registrert maskinbevis etter denne kjøringen.
   *
   * `false` når kontrollen ikke lot seg gjennomføre — kilden svarte ikke,
   * fingeravtrykket stemte ikke, registreringen ble avvist. Da finnes raden uten
   * bevis, og kjøringen skal ikke rapportere at kjeden er komplett
   * (ANTIDEP_CONSTITUTION.md §11).
   */
  readonly verified: boolean
  /**
   * Hvorfor funnet står uten registrert maskinbevis etter kjøringen.
   *
   * Bare satt når det finnes en rad som skulle vært kontrollert, og kontrollen
   * ikke lot seg gjennomføre. En tørrkjøring og et forslag som ikke holdt mål
   * har ingen rad, og har derfor ingen grunn å oppgi her — de rapporteres som
   * `previewed` og `skipped` med `extraction.reason`.
   */
  readonly unverifiedReason?: string
}

export interface ReextractionReport {
  readonly results: readonly ReextractionResult[]
  /** Antall nye forankrede evidensfunn denne kjøringen faktisk skrev. */
  readonly registered: number
  /** Forslag som allerede var registrert, med de samme strukturerte verdiene. */
  readonly alreadyRegistered: number
  /** Forslag som ikke ble registrert fordi noe ikke holdt mål. */
  readonly skipped: number
  /** Funn som finnes, men står uten registrert maskinbevis etter kjøringen. */
  readonly unverified: number
}

/**
 * Kjører re-ekstraksjonen for ett eller flere forslag, i den rekkefølgen de kom.
 *
 * Hvert forslag er sin egen kjøring med sin egen proveniens, og et forslag som
 * ikke holder mål stopper ikke de andre: rapporten sier hva som skjedde med
 * hvert enkelt. Det er bevisst — en levering på to artikler skal ikke være
 * alt-eller-ingenting når den ene kilden har endret seg.
 */
export async function runReextraction(options: ReextractionOptions): Promise<ReextractionReport> {
  const {
    extractionApi,
    verificationApi,
    verificationPremises,
    proposals,
    dryRun = false,
    retrieve,
    retrieveOptions,
    log = () => {},
  } = options

  const results: ReextractionResult[] = []

  for (const { label, proposal } of proposals) {
    log(`\n${label}`)
    const extraction = await runEvidenceExtraction({
      api: extractionApi,
      proposal,
      mode: options.mode,
      dryRun,
      ...(retrieve === undefined ? {} : { retrieve }),
      ...(retrieveOptions === undefined ? {} : { retrieveOptions }),
      log,
    })

    // Ingen rad å kontrollere: en tørrkjøring, eller et forslag som ikke holdt
    // mål. `verified` er da ikke en påstand om noe som finnes.
    if (extraction.decision === 'previewed' || extraction.decision === 'skipped') {
      results.push({
        label,
        sourceVersionId: proposal.sourceVersionId,
        extraction,
        verified: false,
      })
      continue
    }

    // Kontrollen er en *separat* operasjon, av en annen aktør og med sin egen
    // kjøring (ANTIDEP_CONSTITUTION.md §10, §11). Den kjøres på nøyaktig den
    // raden forslaget gjelder, aldri på en rad som ligner og aldri på hele køen.
    //
    // Ble raden nettopp skrevet, kjenner vi id-en derfra. Var den skrevet fra
    // før, navngir dublettavvisningen den (migrasjon 007h).
    const evidenceItemId = extraction.evidenceItemId ?? extraction.existingEvidenceItemId
    if (evidenceItemId === undefined) {
      // Databasen kunne ikke slå opp den kolliderende raden. Da er det ingen rad
      // å kontrollere herfra, og kjøringen skal ikke påstå at kjeden er komplett.
      const reason =
        'Den samme ekstraksjonen er allerede registrert, men databasen kunne ikke navngi ' +
        'raden det gjaldt. Kontrollen av den kan ikke fullføres herfra; kjør ' +
        'npm run agent:verify-extraction for arbeidskøen.'
      log(reason)
      results.push({
        label,
        sourceVersionId: proposal.sourceVersionId,
        extraction,
        verified: false,
        unverifiedReason: reason,
      })
      continue
    }

    // Raden leses på id, så svaret gjelder den og ingen annen — også når den
    // allerede er kontrollert. `select` avgjør bare hva som faktisk skal
    // kontrolleres av det kalleren allerede har pekt på.
    const verification = await runExtractionVerification({
      api: verificationApi,
      premises: verificationPremises,
      evidenceItemId,
      // Et gjeldende maskinbevis betyr at kjeden allerede er komplett. En ny
      // kontroll ville vært en ny rad uten et nytt svar, og ville brutt at den
      // samme filen kjørt om igjen ikke skriver noe.
      select: (items) => items.filter((item) => !item.groundingMachineProved),
      ...(retrieve === undefined ? {} : { retrieve }),
      ...(retrieveOptions === undefined ? {} : { retrieveOptions }),
      log,
    })

    // En kontroll som ikke lot seg gjennomføre, er ikke en kontroll. Sto raden
    // allerede med et bevis, ble ingenting valgt — og da er det heller ingenting
    // som ble hoppet over.
    const skipped = verification.items.find((item) => item.decision === 'skipped')
    const verified = skipped === undefined
    if (!verified) {
      log(`Funnet fra ${label} står uten registrert maskinbevis etter denne kjøringen.`)
    }

    results.push({
      label,
      sourceVersionId: proposal.sourceVersionId,
      extraction,
      verification,
      verified,
      ...(skipped?.reason === undefined ? {} : { unverifiedReason: skipped.reason }),
    })
  }

  return {
    results,
    registered: results.filter((result) => result.extraction.decision === 'registered').length,
    alreadyRegistered: results.filter(
      (result) => result.extraction.decision === 'already_registered',
    ).length,
    skipped: results.filter((result) => result.extraction.decision === 'skipped').length,
    // Bare de forslagene som faktisk har en rad i basen. En tørrkjøring og et
    // forslag som ikke holdt mål, står ikke uten maskinbevis — de står uten rad.
    unverified: results.filter(
      (result) =>
        !result.verified &&
        (result.extraction.decision === 'registered' ||
          result.extraction.decision === 'already_registered'),
    ).length,
  }
}
