// ============================================================================
// Svarhåndteringen for ekstraksjonsdelen av en kontrolløkt
//
// Ett sted, fordi to flater kjører den samme delen av økten: kontrollen av ett
// evidensfunn for seg (`/extraction-review/:evidenceItemId`) og den samme
// kontrollen inne i kontrollen av en påstand (`/review/:claimRevisionId`).
// Skrevet to ganger ville de to kunnet svare forskjellig på det samme
// spørsmålet — for eksempel om «Ja» på fullteksten betyr originalkilden.
//
// Modulen holder ingen tilstand. Den oversetter et svar til en endring, og lar
// siden eie både tilstanden og selve lagringen.
// ============================================================================

import type { ExtractionSessionHandlers } from '../components/extraction-control-steps'
import type { AnsweredCheck, ControlAnswer, ExtractionSessionState } from '../lib/control-session'

/** Endrer tilstanden for ett evidensfunn i økten. */
export type ExtractionSessionUpdate = (
  evidenceItemId: string,
  change: (state: ExtractionSessionState) => ExtractionSessionState,
) => void

export function extractionSessionHandlers(
  update: ExtractionSessionUpdate,
  save: (evidenceItemId: string) => void,
): ExtractionSessionHandlers {
  return {
    onFullText: (evidenceItemId, answer) =>
      update(evidenceItemId, (state) => ({
        ...state,
        fullText: answer,
        // «Ja» er originalkilden. «Nei» åpner spørsmålet om hva kontrolløren da
        // har, og lar tilgangen stå ubesvart til det er svart på — den svakeste
        // verdien er ikke et svar noen har gitt.
        sourceAccess: answer === 'yes' ? 'original_source' : null,
      })),
    onSourceAccess: (evidenceItemId, access) =>
      update(evidenceItemId, (state) => ({ ...state, sourceAccess: access })),
    onFieldAnswer: (evidenceItemId, field, answer) =>
      update(evidenceItemId, (state) => ({
        ...state,
        fields: {
          ...state.fields,
          [field]: { answer, note: state.fields[field]?.note ?? '' } satisfies AnsweredCheck,
        },
      })),
    onFieldNote: (evidenceItemId, field, note) =>
      update(evidenceItemId, (state) => ({
        ...state,
        fields: {
          ...state.fields,
          // Skrives det i avviksfeltet uten at et svar er gitt, er svaret
          // fortsatt ikke gitt: teksten festes til den tilstanden som faktisk
          // gjelder, ikke til en bekreftelse ingen har avgitt.
          [field]: {
            answer: state.fields[field]?.answer ?? ('cannot_determine' as ControlAnswer),
            note,
          },
        },
      })),
    onSave: save,
  }
}
