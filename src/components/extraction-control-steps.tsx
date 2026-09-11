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
import { SourceLink } from './SourceLink'
import { ControlChoice, type WizardStep } from './ControlWizard'
import {
  EVIDENCE_CHECK_FIELD_LABELS,
  VERIFICATION_OUTCOME_LABELS,
  termText,
} from './vocabulary-labels'
import { readEvidenceCheckField } from '../lib/evidence-item'
import {
  deriveExtractionVerification,
  extractionTally,
  type AnsweredCheck,
  type ControlAnswer,
  type DerivedVerification,
  type ExtractionSessionState,
} from '../lib/control-session'
import { groundingGap, uncoveredCheckFields } from '../lib/extraction-review'
import {
  designStatement,
  interpretField,
  sourceWideAbsenceFields,
} from '../lib/extraction-statements'
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

function checkFieldLabel(field: string): string {
  return termText(readEvidenceCheckField(field), EVIDENCE_CHECK_FIELD_LABELS, 'kontrollfelt')
}

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
    semanticFields: item.dossier.semanticCheckFields,
    sourceAccess: state.sourceAccess ?? 'derived_summary',
    answers: state.fields,
    // Feltene der raden bærer en påstand om kilden som helhet. Kontrolløren har
    // bare bekreftet et lokalt fravær, og registreringen skal ikke føre opp mer
    // dekning enn det (DATABASE_ARCHITECTURE.md §29).
    sourceWideAbsenceFields: sourceWideAbsenceFields(
      item.dossier.semanticCheckFields,
      item.dossier.extraction,
    ),
  })
}

export function buildExtractionSteps({
  item,
  reviewerActorId,
  state,
  handlers,
  includeFieldSteps,
  sourceIntroduced,
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
  /**
   * Om kilden allerede er presentert over økten.
   *
   * Kontrollflaten for ett evidensfunn innleder med hva som skal kontrolleres og
   * hvilken kilde det gjelder (`ExtractionControlIntro.tsx`), og da er tittelen
   * gjentatt i kildetilgangssteget bare støy. En påstandsøkt kontrollerer flere
   * kilder etter hverandre uten en slik innledning, og der må steget selv si
   * hvilken kilde spørsmålet gjelder.
   */
  readonly sourceIntroduced: boolean
  /** Prefiks som skiller flere evidensfunn fra hverandre i en lang økt. */
  readonly titlePrefix: string | null
}): readonly WizardStep[] {
  const { dossier } = item
  const evidenceItemId = dossier.evidenceItemId
  const isOwnExtraction = dossier.createdByActorId === reviewerActorId
  const uncovered = uncoveredCheckFields(item)
  const missingGrounding = groundingGap(dossier)
  const groundings = new Map(
    dossier.fieldGroundings.map((grounding) => [grounding.checkField, grounding]),
  )
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
      // Lenken og spørsmålet, og ikke mer. Hva slags representasjon
      // ekstraksjonen bygger på, og hvilken identifikator kilden har, er
      // proveniens som hører til «Tekniske detaljer»; i dette steget er begge
      // deler støy (ANTIDEP_CONSTITUTION.md §2).
      content: (
        <div className="control-step__form">
          {sourceIntroduced ? null : <p className="control-step__lead">{dossier.sourceTitle}</p>}
          <SourceLink identifiers={dossier.sourceIdentifiers} />
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

  // Et funn uten komplett forankring kan ikke kontrolleres felt for felt: det
  // finnes ingen venstreside å sammenligne mot. Å be kontrolløren finne den i
  // artikkelen selv er nøyaktig arbeidsformen forankringen finnes for å fjerne,
  // så økten stopper her og sier hva som må skje i stedet.
  if (missingGrounding.length > 0) {
    steps.push({
      id: extractionCommitStepId(evidenceItemId),
      title: `${prefix}Dette evidensfunnet må ekstraheres på nytt`,
      answerSummary: null,
      // Ikke ferdig, for ingenting her er gjort: steget er en stopp, og skal
      // stå åpent som den aktive tilstanden økten faktisk er i.
      isComplete: false,
      countsTowardProgress: false,
      content: (
        <div className="knowledge-notice knowledge-notice--absence" role="note">
          <p className="knowledge-notice__lead">
            Ekstraksjonen mangler kildeforankring for{' '}
            {`${String(missingGrounding.length)} av feltene den påstår noe om, og kan derfor ikke kontrolleres felt for felt.`}
          </p>
          <p className="knowledge-notice__detail">
            {`Uten forankring: ${missingGrounding.map(checkFieldLabel).join(', ')}.`}
          </p>
          <p className="knowledge-notice__caveat">
            Antidep gjetter ikke hvilket kildeutdrag en verdi hviler på, og du skal ikke måtte lete
            i artikkelen selv. Funnet må ekstraheres på nytt etter gjeldende protokoll, slik at
            hvert felt får sitt ordrette utdrag, sin peker og sin begrunnelse.
          </p>
        </div>
      ),
    })
    return steps
  }

  // Rekkefølgen er maskinbevis → menneskelig semantikk, ikke omvendt. Uten
  // beviset har ingen prøvd at utdragene i det hele tatt står i kilden, og en
  // kontrollør som gikk gjennom alle feltene, ville fått avvisningen først ved
  // lagring (migrasjon 005x). Økten stopper derfor her.
  if (!dossier.groundingMachineProved) {
    steps.push({
      id: extractionCommitStepId(evidenceItemId),
      title: `${prefix}Kildeutdragene er ikke kontrollert mot kilden ennå`,
      answerSummary: null,
      isComplete: false,
      countsTowardProgress: false,
      content: (
        <div className="knowledge-notice knowledge-notice--absence" role="note">
          <p className="knowledge-notice__lead">
            Ingen maskinell kontroll har ennå prøvd at kildeutdragene står ordrett i denne utgaven
            av kilden.
          </p>
          <p className="knowledge-notice__caveat">
            Du skal bare vurdere om Antideps tolkning følger av utdraget — ikke om utdraget finnes.
            Den kontrollen gjøres av ekstraksjonsverifikatoren, og må være kjørt før du kan bekrefte
            noe. Er grunnlaget endret etter at den kjørte, må den kjøres på nytt.
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

  for (const field of dossier.semanticCheckFields) {
    const grounding = groundings.get(field)
    if (grounding === undefined) {
      // Kan ikke skje: et funn med hull i forankringen er stoppet over. Vakten
      // står likevel, slik at en senere endring ikke stille kan gi et feltsteg
      // uten venstreside.
      continue
    }
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
          grounding={grounding}
          interpretation={interpretation}
          note={entry?.note ?? ''}
          onAnswer={(answer) => handlers.onFieldAnswer(evidenceItemId, field, answer)}
          onNote={(note) => handlers.onFieldNote(evidenceItemId, field, note)}
        />
      ),
    })
  }

  const counts = extractionTally(dossier.semanticCheckFields, state.fields)
  const derived = derivedExtractionFor(item, state)
  // Feltene der svaret gjelder den lokale halvdelen av en påstand om kilden som
  // helhet. Den kildeomfattende halvdelen er et eget kontrollobjekt, og
  // kontrolløren skal vite hvor den står — ikke oppdage det som en blokkert
  // publisering senere (PRODUCT_INFORMATION_ARCHITECTURE.md §63.1).
  const localOnly = sourceWideAbsenceFields(dossier.semanticCheckFields, dossier.extraction).filter(
    (field) => state.fields[field]?.answer === 'yes',
  )
  const sourceWideOutstanding = uncovered.includes('source_wide_absence')
  const ready =
    state.sourceAccess !== null &&
    dossier.semanticCheckFields.every((field) => isFieldComplete(state.fields[field]))

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
        {/* Svaret dekker den lokale halvdelen. Den kildeomfattende halvdelen
            er maskinens, og kontrolløren skal se hvor den står — men aldri bli
            bedt om å gjøre den (DATABASE_ARCHITECTURE.md §29). */}
        {localOnly.length > 0 ? (
          <p className="control-summary__note">
            {`Svaret ditt på ${localOnly.map(checkFieldLabel).join(', ')} gjelder stedet
              opplysningen ville stått, og det er nøyaktig det som blir registrert. Om
              opplysningen står noe annet sted i den registrerte kildeversjonen, avgjøres av et
              maskinelt søk gjennom hele den. ${
                sourceWideOutstanding
                  ? 'Det søket har ennå ikke gått god for dette funnet, så publiseringsgaten er fortsatt åpen på det. Det er ikke noe du skal gjøre.'
                  : 'Det søket er allerede gjort for dette funnet.'
              }`.replace(/\s+/g, ' ')}
          </p>
        ) : null}
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
