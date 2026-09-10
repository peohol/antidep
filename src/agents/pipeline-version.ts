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
import type { GeneratedBy } from './extraction-proposal.ts'

/**
 * Versjonen av Antideps egen evidenspipeline.
 *
 * Ett sted, brukt av hvert ledd: den sier hvilken kjede kjøringen var en del
 * av, og den er vår uansett hvem som produserte inndataen. Ville den vært
 * skrevet av på tre steder, kunne to ledd i den samme kjøringen oppgitt hver
 * sin pipeline.
 */
export const ANTIDEP_EVIDENCE_PIPELINE_VERSION = 'antidep-evidence/1'

export const EXTRACTION_VERIFICATION_PREMISES: AgentRunPremises = {
  provider: 'antidep',
  model: 'deterministic-extraction-check',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'extraction-verification/deterministic/1',
  pipelineVersion: ANTIDEP_EVIDENCE_PIPELINE_VERSION,
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
  pipelineVersion: ANTIDEP_EVIDENCE_PIPELINE_VERSION,
}

/**
 * Ekstraksjonsagentens premisser, utledet av forslaget selv (migrasjon 005v, 005w).
 *
 * Ikke en konstant, og det er hele endringen fra da forslagene bare kom
 * utenfra. Leddet som *leser* artikkelen og foreslår verdier, er ikke det
 * samme som kjøringen som registrerer forslaget: den første er et menneske
 * eller en modell, den andre er Antideps deterministiske vei inn i basen. En
 * fast verdi her ville derfor registrert hvert eneste forslag som om det samme
 * hadde laget det — et menneskes ekstraksjon som en modells, og omvendt
 * (ANTIDEP_CONSTITUTION.md §14, §20, EVIDENCE_PIPELINE.md §65).
 *
 * Leverandør, modell, modellversjon og promptmalversjon kommer derfor fra
 * `generated_by` i forslaget. Pipelineversjonen gjør det ikke: den er Antideps
 * egen, og et forslag utenfra skal ikke kunne påstå noe om hvilken pipeline som
 * registrerte det. Skillet er hele grunnen til at feltene er fri tekst — to
 * kjøringer med hver sin leverandør står ved siden av hverandre framfor å bli
 * forvekslet.
 */
export function extractionPremisesFor(generatedBy: GeneratedBy): AgentRunPremises {
  return {
    provider: generatedBy.provider,
    model: generatedBy.model,
    modelVersion: generatedBy.modelVersion,
    promptTemplateVersion: generatedBy.promptTemplateVersion,
    pipelineVersion: ANTIDEP_EVIDENCE_PIPELINE_VERSION,
  }
}
