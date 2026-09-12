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
import { readableExcerptParagraphs } from '../lib/readable-excerpt.ts'

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
interface Pane {
  readonly heading: string
  readonly question: string
  /** Hva utdraget til venstre er, når det ikke er åpenbart. */
  readonly basis?: string
}

const PANE: Record<FieldStatementKind, Pane> = {
  interpretation: {
    heading: 'Antideps tolkning',
    question: 'Stemmer Antideps tolkning med teksten?',
  },
  // Grunnen er registrert og gjelder funnet eller lesningen, og det er grunnen
  // som skal bedømmes — ikke et fravær flaten har formulert på egen hånd.
  absence: {
    heading: 'Hvorfor verdien mangler',
    question: 'Stemmer denne begrunnelsen?',
  },
  // Grunnen er en påstand om kilden som helhet, og den kan ingen avgjøre av ett
  // lokalt utdrag. Spørsmålet er derfor snevret inn til det utdraget faktisk
  // bærer, og kontrollgrunnlaget er valgt deretter: ekstraksjonen skal forankre
  // et slikt fravær i passasjen der verdien ville stått
  // (EVIDENCE_PIPELINE.md §19.1). Et forbehold ved siden av et globalt
  // ja/nei-spørsmål ville ikke endret sannhetsbetingelsen, og ville latt
  // kontrolløren stå igjen med «Kan ikke avgjøres» hver gang.
  //
  // Den andre halvdelen — om opplysningen står noe annet sted i kilden — er
  // ikke kontrollørens arbeid og blir aldri spurt om her. Den er et eget
  // kontrollobjekt: en maskinell gjennomgang av hele den registrerte
  // kildeversjonen (migrasjon 005ae, `absence-review.ts`). Setningen under sier
  // det, slik at kontrolløren vet at hen ikke skal lete — og at ingen andre
  // venter på at hen gjør det.
  absence_in_source: {
    heading: 'Hvorfor verdien mangler',
    question: 'Mangler opplysningen der utdraget viser at den ville stått?',
    basis:
      'Utdraget til venstre er stedet der opplysningen ville stått. Du skal bare avgjøre om ' +
      'den mangler der. Om den står noe annet sted i kilden, avgjøres maskinelt ved en egen ' +
      'gjennomgang av hele den registrerte kildeversjonen — det er ikke din oppgave.',
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
          {/* Utdraget som lesbar tekst: ett avsnitt per uavhengig tekstblokk,
              med linjeombrekkingen fra PDF-en slått sammen til mellomrom. Ingen
              ord er endret — bare blanktegn (`readable-excerpt.ts`). */}
          <blockquote className="field-check__excerpt">
            {readableExcerptParagraphs(grounding.sourceExcerpt).map((paragraph, index) => (
              <p key={index} className="field-check__excerpt-paragraph">
                {paragraph}
              </p>
            ))}
          </blockquote>
          <p className="field-check__locator">{grounding.sourceLocator}</p>
        </div>

        <div className="field-check__pane">
          <h4 className="field-check__pane-heading">{pane.heading}</h4>
          <p className="field-check__statement">{interpretation.statement}</p>
          {interpretation.detail === null ? null : (
            <p className="field-check__detail">{interpretation.detail}</p>
          )}
          {/* Hva utdraget er, når spørsmålet er snevret inn til det. Står der
              kontrolløren svarer, ikke i en fotnote lenger nede. */}
          {pane.basis === undefined ? null : <p className="field-check__caveat">{pane.basis}</p>}
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
