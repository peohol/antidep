// ============================================================================
// Premissene ekstraksjonsverifikatoren kjører under
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
