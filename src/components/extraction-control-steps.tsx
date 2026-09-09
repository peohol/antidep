// ============================================================================
// Stegene i kontrollen av én ekstraksjon mot kilden
//
// Bygger den delen av kontrolløkten som gjelder ett evidensfunn: først hvilken
// tilgang kontrolløren faktisk har til kilden, så ett steg per felt funnet
// påstår noe om, og til slutt registreringen av kontrollen.
//
// Rekkefølgen er ikke kosmetisk. Kildetilgangen kommer først fordi den avgjør
// hva som i det hele tatt kan bekreftes: en kontroll som bare har et sammendrag
// fra et annet ledd, kan ikke ende i en bekreftelse
// (ANTIDEP_CONSTITUTION.md §11), og da skal kontrolløren vite det før hen
// begynner — ikke få det som en avvisning til slutt.
//
// ----------------------------------------------------------------------------
// Feltene kommer fra publiseringsgaten, ikke fra denne filen
//
// `requiredCheckFields` er `workflow.required_check_fields(uuid)`, den samme
// funksjonen gatens G5b leser. Ett steg per felt betyr derfor «ett steg per
// påstand funnet faktisk gjør», og når alle er besvart, er nøyaktig det gaten
// krever, dekket. En liste her ville vært en andre formulering av regelen.
//
// ----------------------------------------------------------------------------
// Ingen samlet «hvordan gjennomførte du kontrollen?» og ingen utfallsmeny
//
// Kontrollalgoritmen *er* metoden, og utfallet følger av delsvarene
// (`control-session.ts`). Registreringssteget viser hva som blir registrert og
// hvorfor, og har én knapp.
// ============================================================================

import { ExtractionFieldStep } from './ExtractionFieldStep'
import { SourceAddressLink } from './SourceAddressLink'
import { ControlChoice, type WizardStep } from './ControlWizard'
import { VERIFICATION_OUTCOME_LABELS } from './vocabulary-labels'
import {
  deriveExtractionVerification,
  extractionTally,
  type AnsweredCheck,
  type ControlAnswer,
  type DerivedVerification,
  type ExtractionSessionState,
} from '../lib/control-session'
import { uncoveredCheckFields } from '../lib/extraction-review'
import { designStatement, interpretField } from '../lib/extraction-statements'
import { extractionCommitStepId, fieldStepId, sourceAccessStepId } from '../lib/control-steps'
import type { ExtractionReviewItem } from '../lib/extraction-review'
import type { VerificationOutcome } from '../types/api'

export interface ExtractionSessionHandlers {
  readonly onFullText: (evidenceItemId: string, answer: ControlAnswer) => void
  readonly onSourceAccess: (evidenceItemId: string, access: string) => void
  readonly onFieldAnswer: (evidenceItemId: string, field: string, answer: ControlAnswer) => void
  readonly onFieldNote: (evidenceItemId: string, field: string, note: string) => void
  readonly onSave: (evidenceItemId: string) => void
}

const ACCESS_WITHOUT_FULL_TEXT = [
  {
    value: 'verifiable_representation',
    label: 'Den lagrede kopien Antidep kan etterprøve',
  },
  { value: 'derived_summary', label: 'Bare et sammendrag fra et annet ledd' },
] as const

function outcomeLabel(outcome: string): string {
  return outcome in VERIFICATION_OUTCOME_LABELS
    ? VERIFICATION_OUTCOME_LABELS[outcome as VerificationOutcome]
    : outcome
}

/** Kildetilgangen, formulert slik kontrolløren svarte på den. */
function accessSummary(state: ExtractionSessionState): string | null {
  if (state.sourceAccess === 'original_source') {
    return 'Har fullteksten'
  }
  if (state.sourceAccess === 'verifiable_representation') {
    return 'Har den lagrede kopien'
  }
  if (state.sourceAccess === 'derived_summary') {
    return 'Har bare et sammendrag'
  }
  return null
}

/**
 * Om delkontrollen er ferdig.
 *
 * Et «Nei» er ikke ferdig før avviket er beskrevet. Beskrivelsen hører til
 * nettopp dette steget, mens kontrolløren har kilden foran seg — og et avvik
 * uten tekst ville måttet forklares på nytt lenger ned, eller aldri.
 */
function isFieldComplete(entry: AnsweredCheck | undefined): boolean {
  if (entry === undefined) {
    return false
  }
  return entry.answer !== 'no' || entry.note.trim().length > 0
}

function answerSummary(entry: AnsweredCheck | undefined): string | null {
  switch (entry?.answer) {
    case 'yes':
      return 'Stemmer'
    case 'no':
      return 'Avvik'
    case 'cannot_determine':
      return 'Kunne ikke avgjøres'
    default:
      return null
  }
}

/**
 * Utfallet økten vil registrere for dette funnet, slik det står nå.
 *
 * Eksportert fordi registreringen trenger nøyaktig den samme utledningen som
 * oppsummeringssteget viser. To kall til den samme rene funksjonen kan ikke
 * komme i utakt; to formuleringer av regelen kunne det.
 */
export function derivedExtractionFor(
  item: ExtractionReviewItem,
  state: ExtractionSessionState,
): DerivedVerification {
  return deriveExtractionVerification({
    requiredFields: item.requiredCheckFields,
    sourceAccess: state.sourceAccess ?? 'derived_summary',
    answers: state.fields,
  })
}

export function buildExtractionSteps({
  item,
  reviewerActorId,
  state,
  handlers,
  includeFieldSteps,
  titlePrefix,
}: {
  readonly item: ExtractionReviewItem
  readonly reviewerActorId: string
  readonly state: ExtractionSessionState
  readonly handlers: ExtractionSessionHandlers
  /**
   * Om selve feltkontrollen hører til økten.
   *
   * Er ekstraksjonen allerede fullt dekket av registrerte kontroller, er det
   * ingenting igjen å kontrollere, og en økt som spurte likevel ville bedt om
   * arbeid uten hensikt. Kildetilgangen spørres uansett: claim-kontrollen skal
   * registrere hva kontrolløren hadde tilgang til for hver evidenslenke.
   */
  readonly includeFieldSteps: boolean
  /** Prefiks som skiller flere evidensfunn fra hverandre i en lang økt. */
  readonly titlePrefix: string | null
}): readonly WizardStep[] {
  const { dossier } = item
  const evidenceItemId = dossier.evidenceItemId
  const isOwnExtraction = dossier.createdByActorId === reviewerActorId
  const uncovered = uncoveredCheckFields(item)
  const retrievedFrom = dossier.sourceVersion?.retrievedFrom ?? null
  const hasVerifiableCopy =
    dossier.sourceVersion !== null && dossier.sourceVersion.contentHash !== null
  const prefix = titlePrefix === null ? '' : `${titlePrefix} `

  const steps: WizardStep[] = [
    {
      id: sourceAccessStepId(evidenceItemId),
      title: `${prefix}Hvilken tilgang har du til kilden?`,
      answerSummary: accessSummary(state),
      isComplete: state.sourceAccess !== null,
      // Ikke en delkontroll: kildetilgangen er forutsetningen for kontrollen,
      // ikke en av de tingene som kan bekreftes. Talt med ville progresjonen
      // oppgitt et annet tall enn oppsummeringen til slutt.
      countsTowardProgress: false,
      content: (
        <div className="control-step__form">
          <p className="control-step__lead">{dossier.sourceTitle}</p>
          <SourceAddressLink label="Åpne kilden" retrievedFrom={retrievedFrom} />
          <ControlChoice
            legend="Har du tilgang til fullteksten?"
            onChoose={(value) => handlers.onFullText(evidenceItemId, value as ControlAnswer)}
            options={[
              { value: 'yes', label: 'Ja' },
              { value: 'no', label: 'Nei' },
            ]}
            value={state.fullText}
          />
          {state.fullText === 'no' ? (
            <ControlChoice
              legend="Hva har du da tilgang til?"
              onChoose={(value) => handlers.onSourceAccess(evidenceItemId, value)}
              options={ACCESS_WITHOUT_FULL_TEXT.filter(
                (option) => option.value !== 'verifiable_representation' || hasVerifiableCopy,
              )}
              value={state.sourceAccess}
            />
          ) : null}
        </div>
      ),
    },
  ]

  if (isOwnExtraction) {
    steps.unshift({
      id: extractionCommitStepId(evidenceItemId),
      title: `${prefix}Du kan ikke kontrollere din egen ekstraksjon`,
      answerSummary: 'Kontrolleres av en annen',
      isComplete: true,
      countsTowardProgress: false,
      content: (
        <div className="knowledge-notice knowledge-notice--absence" role="note">
          <p className="knowledge-notice__lead">
            Du registrerte denne ekstraksjonen selv, og kan derfor ikke kontrollere den.
          </p>
          <p className="knowledge-notice__caveat">
            En annen kvalifisert person eller en ekstraksjonsverifikator må gjøre kontrollen. Du kan
            fortsette med kontrollen av påstanden.
          </p>
        </div>
      ),
    })
    return steps
  }

  if (!includeFieldSteps) {
    steps.push({
      id: extractionCommitStepId(evidenceItemId),
      title: `${prefix}Ekstraksjonen er allerede kontrollert`,
      answerSummary: 'Ferdig fra før',
      isComplete: true,
      countsTowardProgress: false,
      content: (
        <div className="knowledge-notice knowledge-notice--ok" role="note">
          <p className="knowledge-notice__lead">
            Alle feltene dette funnet påstår noe om, er kontrollert mot kilden fra før.
          </p>
          <p className="knowledge-notice__caveat">
            Du trenger ikke gjøre den kontrollen på nytt for å vurdere påstanden.
          </p>
        </div>
      ),
    })
    return steps
  }

  const groundings = new Map(
    dossier.fieldGroundings.map((grounding) => [grounding.checkField, grounding]),
  )

  for (const field of item.requiredCheckFields) {
    const interpretation = interpretField(field, dossier.extraction)
    const entry = state.fields[field]
    steps.push({
      id: fieldStepId(evidenceItemId, field),
      title: `${prefix}${interpretation.heading}`,
      answerSummary: answerSummary(entry),
      isComplete: isFieldComplete(entry),
      countsTowardProgress: true,
      content: (
        <ExtractionFieldStep
          answer={entry?.answer ?? null}
          grounding={groundings.get(field) ?? null}
          interpretation={interpretation}
          note={entry?.note ?? ''}
          onAnswer={(answer) => handlers.onFieldAnswer(evidenceItemId, field, answer)}
          onNote={(note) => handlers.onFieldNote(evidenceItemId, field, note)}
          retrievedFrom={retrievedFrom}
        />
      ),
    })
  }

  const counts = extractionTally(item.requiredCheckFields, state.fields)
  const derived = derivedExtractionFor(item, state)
  const ready =
    state.sourceAccess !== null &&
    item.requiredCheckFields.every((field) => isFieldComplete(state.fields[field]))

  steps.push({
    id: extractionCommitStepId(evidenceItemId),
    title: `${prefix}Lagre kontrollen av kildegrunnlaget`,
    answerSummary:
      state.savedVerificationId === null ? null : `Registrert: ${outcomeLabel(derived.outcome)}`,
    isComplete: state.savedVerificationId !== null,
    countsTowardProgress: false,
    content: (
      <div className="control-step__form">
        <p className="control-step__lead">{designStatement(dossier.extraction)}</p>
        <p className="control-summary">
          {`${String(counts.confirmed)} av ${String(counts.total)} delkontroller bekreftet. `}
          {counts.deviations === 0 ? 'Ingen avvik. ' : `${String(counts.deviations)} avvik. `}
          {counts.unresolved === 0
            ? 'Ingenting sto uavklart.'
            : `${String(counts.unresolved)} kunne ikke avgjøres.`}
        </p>
        <p className="control-summary__outcome">
          {`Dette blir registrert som: ${outcomeLabel(derived.outcome)}.`}
        </p>
        {uncovered.length > 0 && derived.outcome !== 'verified' ? (
          <p className="control-summary__note">
            Publiseringsgaten krever at hvert felt funnet påstår noe om, er bekreftet. Med dette
            utfallet står den kontrollen fortsatt åpen.
          </p>
        ) : null}
        {state.problem === null ? null : (
          <p className="admin-form__problem" role="alert">
            Kontrollen ble ikke registrert. {state.problem}
          </p>
        )}
        <button
          disabled={!ready || state.saving}
          onClick={() => handlers.onSave(evidenceItemId)}
          type="button"
        >
          {state.saving ? 'Lagrer …' : 'Lagre og fortsett'}
        </button>
        {ready ? null : (
          <p className="control-summary__note">
            Svar på alle delkontrollene over før kontrollen kan registreres.
          </p>
        )}
      </div>
    ),
  })

  return steps
}
