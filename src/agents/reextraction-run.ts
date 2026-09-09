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
// `evidence_items_content_hash_key` dekker de strukturerte verdiene på raden.
// Kjøres det samme forslaget om igjen, avviser databasen registreringen som en
// dublett, og kjøringen rapporterer `already_registered` framfor å skrive noe.
// Ingen lokal bokføring, ingen «har jeg gjort dette før?»-fil: fasiten er basen.
//
// Avtrykket dekker *ikke* forankringen, som ligger i sin egen tabell. Et forslag
// som bare retter et utdrag, en peker eller en begrunnelse, er derfor den samme
// ekstraksjonen for databasen, og avvises som en dublett. Det er en reell
// begrensning i datamodellen og ikke noe denne kjøreren kan rette; den sier det
// i klartekst framfor å la det se ut som «allerede gjort».
//
// ----------------------------------------------------------------------------
// En avbrutt kjøring skal kunne fullføres
//
// Registreringen og kontrollen er to skrivinger, i to transaksjoner. Dør
// prosessen mellom dem, finnes raden uten maskinbevis — og en ny kjøring med det
// samme forslaget får bare «dublett» tilbake, uten en id å kontrollere.
//
// Kjøringen gjenfinner da funnet i verifikatorens egen arbeidskø, på det den
// faktisk har: kildeversjonen og forankringen. Utvalget er strengere enn
// databasens dublettregel — en legacy-rad uten forankring treffer aldri — så
// gjenopptakelsen rører nøyaktig det forslaget beskriver, og lar resten av køen
// stå.
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
import type { RunReport } from './extraction-verification-run.ts'
import { runExtractionVerification } from './extraction-verification-run.ts'
import type { RetrieveOptions } from './source-retrieval.ts'
import type { VerificationItem } from './verification-input.ts'

/** Ett forslag, med navnet det ble lest under, slik rapporten kan navngi det. */
export interface LabelledProposal {
  readonly label: string
  readonly proposal: ExtractionProposal
}

export interface ReextractionOptions {
  readonly extractionApi: EvidenceExtractionApi
  readonly verificationApi: ExtractionVerificationApi
  readonly extractionPremises: AgentRunPremises
  readonly verificationPremises: AgentRunPremises
  readonly proposals: readonly LabelledProposal[]
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
 * Om et funn i verifikatorens kø er nøyaktig det forslaget beskriver.
 *
 * Strengere enn databasens dublettregel, med hensikt: den dekker de strukturerte
 * verdiene, mens denne krever *også* at forankringen er den samme, felt for felt.
 * En legacy-rad uten forankring treffer derfor aldri, og et annet forslag på den
 * samme kildeversjonen treffer bare hvis det forankrer nøyaktig det samme — og
 * da er det den samme ekstraksjonen.
 */
export function matchesProposal(item: VerificationItem, proposal: ExtractionProposal): boolean {
  if (item.sourceVersion?.sourceVersionId !== proposal.sourceVersionId) {
    return false
  }
  return groundingKey(item.fieldGroundings) === groundingKey(proposal.fieldGroundings)
}

/**
 * Forankringen som én sammenlignbar nøkkel.
 *
 * Lengdeprefikset per del, av samme grunn som databasens egne avtrykk er det: to
 * ulike forankringer skal ikke kunne skrives om til den samme strengen ved at et
 * skilletegn står inni en verdi.
 */
function groundingKey(
  groundings: readonly {
    readonly checkField: string
    readonly sourceExcerpt: string
    readonly sourceLocator: string
    readonly justification: string
  }[],
): string {
  return groundings
    .map((grounding) =>
      [
        grounding.checkField,
        grounding.sourceExcerpt,
        grounding.sourceLocator,
        grounding.justification,
      ]
        .map((part) => `${String(part.length)}:${part}`)
        .join('|'),
    )
    .sort()
    .join('||')
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
    extractionPremises,
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
      premises: extractionPremises,
      proposal,
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
    // kjøring (ANTIDEP_CONSTITUTION.md §10, §11). Den kjøres på nøyaktig det
    // funnet forslaget gjelder, aldri på hele køen: en re-ekstraksjon skal ikke
    // stille dra andre funn med seg.
    //
    // Ble raden nettopp skrevet, kjenner vi id-en. Var den skrevet fra før —
    // fordi en tidligere kjøring døde mellom de to skrivingene — gjør vi det
    // ikke, og funnet gjenfinnes i køen på kildeversjonen og forankringen.
    const target =
      extraction.evidenceItemId === undefined
        ? { select: (item: VerificationItem) => matchesProposal(item, proposal) }
        : { evidenceItemId: extraction.evidenceItemId }

    const verification = await runExtractionVerification({
      api: verificationApi,
      premises: verificationPremises,
      ...target,
      ...(retrieve === undefined ? {} : { retrieve }),
      ...(retrieveOptions === undefined ? {} : { retrieveOptions }),
      log,
    })

    // En kontroll som ikke lot seg gjennomføre, er ikke en kontroll. Sto funnet
    // allerede med et bevis, er køen tom for det — og da er det ingenting som
    // ble hoppet over.
    const verified = !verification.items.some((item) => item.decision === 'skipped')
    if (!verified) {
      log(`Funnet fra ${label} står uten registrert maskinbevis etter denne kjøringen.`)
    }

    results.push({
      label,
      sourceVersionId: proposal.sourceVersionId,
      extraction,
      verification,
      verified,
    })
  }

  return {
    results,
    registered: results.filter((result) => result.extraction.decision === 'registered').length,
    alreadyRegistered: results.filter(
      (result) => result.extraction.decision === 'already_registered',
    ).length,
    skipped: results.filter((result) => result.extraction.decision === 'skipped').length,
    unverified: results.filter((result) => result.verification !== undefined && !result.verified)
      .length,
  }
}
