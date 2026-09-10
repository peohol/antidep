// ============================================================================
// Registeret over modelleverandøradaptere
//
// ANTIDEP_CONSTITUTION.md §20 krever at modelleverandører ligger bak
// utskiftbare adaptere, og at et leverandørbytte er en endring i
// pipelinekonfigurasjon framfor i datamodellen (EVIDENCE_PIPELINE.md §66).
// Denne filen er stedet byttet skjer: ett navn, én konstruktør, og ingenting
// annet i kjeden vet hvilken leverandør som svarte.
//
// ----------------------------------------------------------------------------
// Hvorfor registeret finnes med bare ett adapter i dag
//
// Fordi grensen er poenget, ikke antallet. Så lenge `recorded` er det eneste
// oppførte, kjører kjeden uten leverandørkonto og uten kostnad — og et
// leverandøradapter legges til som én oppføring her, uten at kontrakten,
// kjøringen, kontrollene eller databasen røres. Et adapter valgt med en if-test
// inne i kjøreren ville hatt den samme oppførselen i dag og en helt annen
// endringskostnad i morgen.
//
// Et ukjent navn er en feil som navngir de kjente, framfor et stille fall
// tilbake til standardvalget: en skrivefeil i `--model` skal ikke føre til at
// en kjøring gjøres med en annen modell enn den kalleren ba om — og premissene
// den registreres med, ville da sagt noe annet enn det som skjedde.
// ============================================================================

import { createRecordedModelClient, parseModelRecording } from './recorded-model.ts'
import type { ModelClient } from './model-client.ts'

/** Adapterne som finnes. Et nytt leverandøradapter legges til her. */
export const MODEL_ADAPTERS = ['recorded'] as const
export type ModelAdapterName = (typeof MODEL_ADAPTERS)[number]

export interface ModelAdapterInput {
  /** Innholdet i opptaksfilen, allerede lest og JSON-parset. `null` når ingen er oppgitt. */
  readonly recording: unknown | null
}

/**
 * Lager modellklienten kjøringen skal bruke.
 *
 * Synkron og uten fil-I/O med vilje: kalleren leser filene, og registeret
 * avgjør bare hvilket adapter navnet betyr. Da kan valget prøves uten disk.
 */
export function createModelClient(name: string, input: ModelAdapterInput): ModelClient {
  if (name !== 'recorded') {
    throw new Error(
      `Ukjent modelladapter «${name}». Tilgjengelige adaptere: ${MODEL_ADAPTERS.join(', ')}. ` +
        'Et leverandøradapter legges til som én oppføring i src/agents/model-adapters.ts; ' +
        'ingenting annet i kjeden endres.',
    )
  }
  if (input.recording === null) {
    throw new Error(
      'Adapteret «recorded» krever en opptaksfil. Oppgi --recording <fil>, eller kjør med ' +
        '--prepare <katalog> for å skrive ut prompten og et tomt opptak.',
    )
  }
  return createRecordedModelClient(parseModelRecording(input.recording))
}
