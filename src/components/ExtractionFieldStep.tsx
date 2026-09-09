// ============================================================================
// Én delkontroll av ekstraksjonen: kilden til venstre, Antideps tolkning til høyre
//
// Kontrolløren skal se det minste som trengs for å svare på ett spørsmål: står
// dette i kilden, slik Antidep har lest det? Derfor to felt side om side —
// utdraget kilden faktisk har, og setningen Antidep har laget av det — og
// ingenting annet.
//
// ----------------------------------------------------------------------------
// Tolkningen er den kanoniske raden, ikke en lagret gjengivelse av den
//
// Setningen bygges av `interpretField(...)` fra evidensfunnets egne kolonner
// (`extraction-statements.ts`). Forankringen leverer utdraget, pekeren og
// begrunnelsen; den leverer aldri tolkningen. Da kan kontrolløren ikke bekrefte
// en setning som er noe annet enn det databasen holder
// (ANTIDEP_CONSTITUTION.md §4, §8).
//
// ----------------------------------------------------------------------------
// Et felt uten forankring ser ut som et felt uten forankring
//
// Funn registrert før migrasjon 005u har ingen forankring, og flaten viser
// fraværet med ord. Den henter *ikke* et utdrag ut av `raw_extraction`: et
// utdrag gjettet på den måten ville vært å konstruere nettopp det grunnlaget
// kontrollen skal prøve, og kontrolløren ville ikke kunnet se forskjell på et
// utdrag ekstraktøren faktisk brukte og et flaten fant på.
//
// Feltet kan fortsatt kontrolleres — mot kilden selv, som kontrolløren har åpen
// — men det er da kontrollørens egen lesning som bærer bekreftelsen, og det skal
// stå tydelig.
// ============================================================================

import { ControlChoice } from './ControlWizard'
import { SourceAddressLink } from './SourceAddressLink'
import { CONTROL_ANSWER_OPTIONS, type ControlAnswer } from '../lib/control-session'
import type { FieldInterpretation } from '../lib/extraction-statements'
import type { EvidenceFieldGrounding } from '../agents/verification-input'

export function ExtractionFieldStep({
  interpretation,
  grounding,
  retrievedFrom,
  answer,
  note,
  onAnswer,
  onNote,
}: {
  readonly interpretation: FieldInterpretation
  /** `null` betyr at ekstraksjonen ikke har forankret dette feltet. */
  readonly grounding: EvidenceFieldGrounding | null
  readonly retrievedFrom: string | null
  readonly answer: ControlAnswer | null
  readonly note: string
  readonly onAnswer: (answer: ControlAnswer) => void
  readonly onNote: (note: string) => void
}) {
  return (
    <div className="field-check">
      <div className="field-check__panes">
        <div className="field-check__pane">
          <h4 className="field-check__pane-heading">Kilden</h4>
          {grounding === null ? (
            <div className="knowledge-notice knowledge-notice--absence" role="note">
              <p className="knowledge-notice__lead">
                Ekstraksjonen har ikke registrert hvilket kildeutdrag denne tolkningen bygger på.
              </p>
              <p className="knowledge-notice__caveat">
                Antidep gjetter ikke på et utdrag. Skal du bekrefte feltet, må du finne det i kilden
                selv — og bekreftelsen hviler da på din egen lesning.
              </p>
            </div>
          ) : (
            <>
              <blockquote className="field-check__excerpt">{grounding.sourceExcerpt}</blockquote>
              <p className="field-check__locator">{grounding.sourceLocator}</p>
            </>
          )}
          <SourceAddressLink label="Åpne kilden" retrievedFrom={retrievedFrom} />
        </div>

        <div className="field-check__pane">
          <h4 className="field-check__pane-heading">Antideps tolkning</h4>
          <p className="field-check__statement">{interpretation.statement}</p>
          {interpretation.detail === null ? null : (
            <p className="field-check__detail">{interpretation.detail}</p>
          )}
          {grounding === null ? null : (
            <details className="field-check__why">
              <summary>Hvorfor mener Antidep dette?</summary>
              <p>{grounding.justification}</p>
            </details>
          )}
        </div>
      </div>

      <ControlChoice
        legend="Stemmer Antideps tolkning med kilden?"
        onChoose={(value) => onAnswer(value as ControlAnswer)}
        options={CONTROL_ANSWER_OPTIONS}
        value={answer}
      />

      {/* Avviket beskrives der det oppdages, mens det er ferskt — og spørres
          aldri om igjen senere. */}
      {answer === 'no' ? (
        <label className="field-check__note">
          Hva er feil, eller hvordan bør dette tolkes?
          <textarea onChange={(event) => onNote(event.target.value)} rows={3} value={note} />
        </label>
      ) : null}
    </div>
  )
}
