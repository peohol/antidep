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
// `evidence_items_content_hash_key` dekker hele radens faglige innhold. Kjøres
// det samme forslaget om igjen, avviser databasen registreringen som en dublett,
// og kjøringen rapporterer `already_registered` framfor å skrive noe. Ingen
// lokal bokføring, ingen «har jeg gjort dette før?»-fil: fasiten er basen.
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
   * Den deterministiske kontrollen av nettopp det funnet som ble registrert.
   *
   * Mangler når ingenting ble registrert — en tørrkjøring, en dublett eller et
   * forslag som ikke holdt mål. Da finnes det ingen ny rad å kontrollere, og en
   * kontroll ville vært en kontroll av noe annet.
   */
  readonly verification?: RunReport
}

export interface ReextractionReport {
  readonly results: readonly ReextractionResult[]
  /** Antall nye forankrede evidensfunn denne kjøringen faktisk skrev. */
  readonly registered: number
  /** Forslag som allerede var registrert, med nøyaktig det samme innholdet. */
  readonly alreadyRegistered: number
  /** Forslag som ikke ble registrert fordi noe ikke holdt mål. */
  readonly skipped: number
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

    if (extraction.decision !== 'registered' || extraction.evidenceItemId === undefined) {
      results.push({ label, sourceVersionId: proposal.sourceVersionId, extraction })
      continue
    }

    // Kontrollen er en *separat* operasjon, av en annen aktør og med sin egen
    // kjøring (ANTIDEP_CONSTITUTION.md §10, §11). Den kjøres på nøyaktig det
    // funnet som nettopp ble registrert, aldri på hele køen: en re-ekstraksjon
    // skal ikke stille dra andre funn med seg.
    const verification = await runExtractionVerification({
      api: verificationApi,
      premises: verificationPremises,
      evidenceItemId: extraction.evidenceItemId,
      ...(retrieve === undefined ? {} : { retrieve }),
      ...(retrieveOptions === undefined ? {} : { retrieveOptions }),
      log,
    })

    results.push({ label, sourceVersionId: proposal.sourceVersionId, extraction, verification })
  }

  return {
    results,
    registered: results.filter((result) => result.extraction.decision === 'registered').length,
    alreadyRegistered: results.filter(
      (result) => result.extraction.decision === 'already_registered',
    ).length,
    skipped: results.filter((result) => result.extraction.decision === 'skipped').length,
  }
}
