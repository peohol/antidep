// ============================================================================
// Premissene verifikatorene kjører under
//
// `provenance.agent_runs` krever fem versjonsfelter, alle NOT NULL: leverandør,
// modell, modellversjon, promptmalversjon og pipelineversjon. ANTIDEP_CONSTITUTION.md
// §20 er grunnen — en uversjonert KI-operasjon kan ikke rekonstrueres i
// ettertid, og feltet ville stått tomt akkurat i de kjøringene det betyr mest å
// kunne lese.
//
// ----------------------------------------------------------------------------
// Hvorfor «leverandør» og «modell» beskriver en deterministisk kontroll
//
// Feltene er fri tekst med hensikt (migrasjon 005e): leverandør og modell er
// utskiftbare, og et kontrollert vokabular ville bundet kunnskapsmodellen til
// én leverandørs identifikatorer. At dette leddet i dag er en deterministisk
// kontroll og ikke et språkmodellkall, er derfor noe premissene *sier* framfor
// noe modellen ikke kan uttrykke: leverandøren er Antidep selv, og «modellen»
// er kontrollrutinen med sin egen versjon.
//
// Det er samtidig det som gjør et senere språkmodellsteg til et adapterbytte og
// ikke en datamodellendring: en kjøring med en annen leverandør og modell står
// ved siden av disse, og hver rad sier hvilken kontroll den faktisk var
// (ANTIDEP_CONSTITUTION.md §20, EVIDENCE_PIPELINE.md §65).
//
// Versjonene økes når kontrollen endrer oppførsel. En rettelse som ikke endrer
// hva som godtas eller avvises, er ikke en ny versjon; alt annet er det.
// ============================================================================

import type { AgentRunPremises } from './agent-api.ts'

export const EXTRACTION_VERIFICATION_PREMISES: AgentRunPremises = {
  provider: 'antidep',
  model: 'deterministic-extraction-check',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'extraction-verification/deterministic/1',
  pipelineVersion: 'antidep-evidence/1',
}

/**
 * Claim-verifikatoren (migrasjon 005i, 005k).
 *
 * Egne premisser og ikke en variant av de andre: leddet har sitt eget mandat,
 * sin egen aktør og sin egen kontrollrutine, og en kjøring skal kunne leses
 * tilbake til nøyaktig den kontrollen som faktisk ble gjort. Modellnavnet sier
 * at kontrollen er deterministisk; et senere språkmodellsteg registrerer sin
 * egen leverandør og modell, og de to står da ved siden av hverandre framfor å
 * bli forvekslet (ANTIDEP_CONSTITUTION.md §20, EVIDENCE_PIPELINE.md §65).
 */
export const CLAIM_VERIFICATION_PREMISES: AgentRunPremises = {
  provider: 'antidep',
  model: 'deterministic-claim-check',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'claim-verification/deterministic/1',
  pipelineVersion: 'antidep-evidence/1',
}

/**
 * Ekstraksjonsagenten (migrasjon 005v, 005w).
 *
 * Leddet som *leser* en artikkel og foreslår strukturerte verdier, krever en
 * språkmodell — og dermed en leverandør og en konto (issue #63). Kjøringen som
 * finnes i dag, tar forslaget som inndata og gjør resten deterministisk:
 * henter representasjonen, prøver hvert utdrag ordrett mot den, og registrerer.
 *
 * Premissene sier nøyaktig det. Når modell-leddet kobles på, registrerer det
 * sin egen leverandør, modell og modellversjon, og de to kjøringene står ved
 * siden av hverandre framfor å bli forvekslet — som er hele grunnen til at
 * feltene er fri tekst (ANTIDEP_CONSTITUTION.md §20, EVIDENCE_PIPELINE.md §65).
 */
export const EVIDENCE_EXTRACTION_PREMISES: AgentRunPremises = {
  provider: 'antidep',
  model: 'proposal-grounded-extraction',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'evidence-extraction/proposal/1',
  pipelineVersion: 'antidep-evidence/1',
}
