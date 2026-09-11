// ============================================================================
// Én delkontroll: den ordrette teksten til venstre, Antideps tolkning til høyre
//
// Skuffen inneholder det som trengs for å svare på ett spørsmål, og ingenting
// mer. Ingen lenke, ingen adresse, ingen provenans, ingen forklaring av
// publiseringsgaten — de hører til kildetilgangssteget og til «Tekniske
// detaljer» (ANTIDEP_CONSTITUTION.md §2).
//
// ----------------------------------------------------------------------------
// Et utsagn om kilden og en mangel ved kilden er to forskjellige spørsmål
//
// `interpretation.kind` sier hvilket av de to steget viser
// (`extraction-statements.ts`), og skuffen stiller spørsmålet utsagnet faktisk
// inviterer til. «Stemmer Antideps tolkning med teksten?» er meningsløst om
// utsagnet er at kilden ikke oppgir noe — da er spørsmålet om det stemmer at
// den ikke gjør det.
//
// ----------------------------------------------------------------------------
// Venstresiden er bevist av maskinen, høyresiden vurderes av mennesket
//
// Utdraget er ordrett tekst fra den representasjonen som faktisk ble hentet, og
// den deterministiske verifikatoren har prøvd at det står der (`extraction-checks.ts`).
// Tolkningen bygges av evidensfunnets egne kolonner (`extraction-statements.ts`),
// aldri av en lagret kopi som kunne kommet i utakt med dem.
//
// Kontrollørens oppgave er derfor den ene sammenligningen som er igjen: sier
// venstresiden det høyresiden påstår?
//
// ----------------------------------------------------------------------------
// Et felt uten forankring får ikke et spørsmål
//
// Da har økten ingen venstreside å vise, og å be kontrolløren finne den i
// artikkelen selv er nøyaktig arbeidsformen forankringen finnes for å fjerne.
// Slike funn stoppes før økten begynner (`extraction-control-steps.tsx`), og
// komponenten her tar derfor alltid imot en forankring.
// ============================================================================

import { ControlChoice } from './ControlWizard'
import { CONTROL_ANSWER_OPTIONS, type ControlAnswer } from '../lib/control-session'
import type { FieldInterpretation, FieldStatementKind } from '../lib/extraction-statements'
import type { EvidenceFieldGrounding } from '../agents/verification-input'

/**
 * Hva høyresiden heter, og hva kontrolløren blir spurt om.
 *
 * Spørsmålet følger utsagnets art, og det er ikke kosmetikk: et svar på feil
 * spørsmål blir registrert som om det var et svar på riktig. «Stemmer det at
 * kilden ikke oppgir dette?» ville for en verdi ført som `not_extractable` —
 * «står i kilden, men lar seg ikke lese entydig ut» — bedt kontrolløren
 * bekrefte det motsatte av det som faktisk er ført
 * (`extraction-statements.ts`, ANTIDEP_CONSTITUTION.md §6, §11).
 */
const PANE: Record<FieldStatementKind, { readonly heading: string; readonly question: string }> = {
  interpretation: {
    heading: 'Antideps tolkning',
    question: 'Stemmer Antideps tolkning med teksten?',
  },
  // Grunnen er registrert, og det er grunnen som skal bedømmes — ikke et
  // fravær flaten har formulert på egen hånd.
  absence: {
    heading: 'Hvorfor verdien mangler',
    question: 'Stemmer denne begrunnelsen?',
  },
  // Ingen fraværskolonne finnes for feltet. Da er «ingenting er ført» hele
  // påstanden, og den handler om registreringen — ikke om hva kilden oppgir.
  unrecorded: {
    heading: 'Ingenting er ført',
    question: 'Stemmer det at det ikke er noe å føre her?',
  },
}

export function ExtractionFieldStep({
  interpretation,
  grounding,
  answer,
  note,
  onAnswer,
  onNote,
}: {
  readonly interpretation: FieldInterpretation
  readonly grounding: EvidenceFieldGrounding
  readonly answer: ControlAnswer | null
  readonly note: string
  readonly onAnswer: (answer: ControlAnswer) => void
  readonly onNote: (note: string) => void
}) {
  const pane = PANE[interpretation.kind]
  return (
    <div className="field-check">
      <div className="field-check__panes">
        <div className="field-check__pane">
          <h4 className="field-check__pane-heading">Ordrett tekst</h4>
          <blockquote className="field-check__excerpt">{grounding.sourceExcerpt}</blockquote>
          <p className="field-check__locator">{grounding.sourceLocator}</p>
        </div>

        <div className="field-check__pane">
          <h4 className="field-check__pane-heading">{pane.heading}</h4>
          <p className="field-check__statement">{interpretation.statement}</p>
          {interpretation.detail === null ? null : (
            <p className="field-check__detail">{interpretation.detail}</p>
          )}
          {/* Et fravær i kilden som helhet kan ikke avgjøres av ett lokalt
              utdrag. Forbeholdet står der kontrolløren svarer, ikke i en
              fotnote lenger nede. */}
          {interpretation.caveat === null ? null : (
            <p className="field-check__caveat">{interpretation.caveat}</p>
          )}
          <details className="field-check__why">
            <summary>Hvorfor mener Antidep dette?</summary>
            <p>{grounding.justification}</p>
          </details>
        </div>
      </div>

      <ControlChoice
        legend={pane.question}
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
