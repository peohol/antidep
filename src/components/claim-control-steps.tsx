// ============================================================================
// Stegene i kontrollen av selve påstanden, og i beslutningene etter den
//
// Fortsettelsen av den samme økten: når evidensgrunnlaget er kontrollert mot
// kilden, kontrolleres påstanden mot grunnlaget — de sju kontrollpunktene i
// DATABASE_ARCHITECTURE.md §30, ett om gangen, og én rad per evidenslenke.
//
// ----------------------------------------------------------------------------
// De sju punktene er uendret, og det er meningen
//
// Vokabularet, kravet om at alle sju er `ok` for en bekreftelse, og kravet om at
// hver evidenslenke er kontrollert, er de samme. Det som er nytt, er at
// kontrolløren møter dem ett spørsmål om gangen, med bare det grunnlaget punktet
// handler om synlig (`claim-checkpoint-context.ts`), og at det samlede utfallet
// utledes framfor å velges.
//
// ----------------------------------------------------------------------------
// Tre beslutninger, tre objekter
//
// Kontrollen av påstanden (§11), publiseringsbeslutningen (§12) og selve
// publiseringen er tre forskjellige utsagn, lagret som tre objekter i tre
// tabeller, og publiseringsgaten krever dem hver for seg (G9, G11 og gaten selv
// inne i publiseringstransaksjonen). Økten samler dem i én sammenhengende flyt,
// men de blir aldri én handling: hvert steg har sin egen knapp og sin egen rad.
//
// Begrunnelse etterspørres bare der den bærer informasjon. Etter en fullført
// kontroll uten åpne avvik er «hvorfor godkjenner du?» besvart av kontrollen
// selv, og teksten som lagres, skrives deterministisk av de samme svarene. Ved
// «Be om endringer» og «Avvis» sier begrunnelsen noe ingen annen rad sier, og
// da kreves den.
// ============================================================================

import { ControlChoice, type WizardStep } from './ControlWizard'
import { CheckpointPanes } from './CheckpointPanes'
import {
  CLAIM_CHECKPOINTS,
  REVIEW_OUTCOME_LABELS,
  VERIFICATION_OUTCOME_LABELS,
} from './vocabulary-labels'
import {
  CONTROL_ANSWER_OPTIONS,
  claimTally,
  deriveClaimVerification,
  type AnsweredCheck,
  type AnsweredLink,
  type ControlAnswer,
  type ControlTally,
  type DerivedVerification,
} from '../lib/control-session'
import { checkpointContext } from '../lib/claim-checkpoint-context'
import {
  checkpointStepId,
  claimCommitStepId,
  claimIntroStepId,
  linkStepId,
  publicationDecisionStepId,
  publicationStepId,
} from '../lib/control-steps'
import type { ClaimReviewRevision } from '../lib/review-workspace'
import type { ReviewOutcome, VerificationOutcome } from '../types/api'

/** Kontrollørens svar og beslutninger for én påstandsrevisjon. */
export interface ClaimSessionState {
  readonly started: boolean
  readonly checkpoints: Readonly<Record<string, AnsweredCheck>>
  readonly links: Readonly<Record<string, AnsweredCheck>>
  readonly savedClaimVerificationId: string | null
  readonly savingClaim: boolean
  readonly claimProblem: string | null
  /** `approved`, `changes_requested` eller `rejected`. `null` = ikke valgt. */
  readonly decision: string | null
  readonly decisionRationale: string
  readonly savedDecisionId: string | null
  readonly savingDecision: boolean
  readonly decisionProblem: string | null
  readonly publishedEventId: string | null
  readonly publishing: boolean
  readonly publishProblem: string | null
}

export function emptyClaimSessionState(): ClaimSessionState {
  return {
    started: false,
    checkpoints: {},
    links: {},
    savedClaimVerificationId: null,
    savingClaim: false,
    claimProblem: null,
    decision: null,
    decisionRationale: '',
    savedDecisionId: null,
    savingDecision: false,
    decisionProblem: null,
    publishedEventId: null,
    publishing: false,
    publishProblem: null,
  }
}

export interface ClaimSessionHandlers {
  readonly onStart: () => void
  readonly onCheckpoint: (key: string, answer: ControlAnswer) => void
  readonly onCheckpointNote: (key: string, note: string) => void
  readonly onLink: (linkId: string, answer: ControlAnswer) => void
  readonly onLinkNote: (linkId: string, note: string) => void
  readonly onSaveClaim: () => void
  readonly onDecision: (decision: string) => void
  readonly onDecisionRationale: (rationale: string) => void
  readonly onSaveDecision: () => void
  readonly onPublish: () => void
}

function outcomeLabel(outcome: string): string {
  return outcome in VERIFICATION_OUTCOME_LABELS
    ? VERIFICATION_OUTCOME_LABELS[outcome as VerificationOutcome]
    : outcome
}

function decisionLabel(decision: string): string {
  return decision in REVIEW_OUTCOME_LABELS
    ? REVIEW_OUTCOME_LABELS[decision as ReviewOutcome]
    : decision
}

/** Et «Nei» er ikke ferdig før avviket er beskrevet. Se `extraction-control-steps.tsx`. */
function isAnswerComplete(entry: AnsweredCheck | undefined): boolean {
  if (entry === undefined) {
    return false
  }
  return entry.answer !== 'no' || entry.note.trim().length > 0
}

function answerSummary(entry: AnsweredCheck | undefined): string | null {
  switch (entry?.answer) {
    case 'yes':
      return 'Holder'
    case 'no':
      return 'Avvik'
    case 'cannot_determine':
      return 'Kunne ikke avgjøres'
    default:
      return null
  }
}

/** Lenkene, slik utledningen tar imot dem. */
export function answeredLinksFor(
  revision: ClaimReviewRevision,
  state: ClaimSessionState,
  sourceAccessFor: (evidenceItemId: string) => string | null,
): readonly AnsweredLink[] {
  return revision.dossier.links.map((link) => {
    const entry = state.links[link.claimEvidenceLinkId]
    return {
      claimEvidenceLinkId: link.claimEvidenceLinkId,
      sourceTitle: link.evidenceItem.sourceTitle,
      // Kildetilgangen er den kontrolløren allerede oppga for nettopp den
      // kilden, i ekstraksjonssteget. Å spørre en gang til ville vært å spørre
      // om det samme to ganger — og åpnet for to forskjellige svar.
      sourceAccess: sourceAccessFor(link.evidenceItem.evidenceItemId) ?? 'derived_summary',
      answer: entry?.answer ?? 'cannot_determine',
      note: entry?.note ?? '',
    }
  })
}

/** Utfallet claim-kontrollen vil få, slik svarene står nå. */
export function derivedClaimFor(
  revision: ClaimReviewRevision,
  state: ClaimSessionState,
  sourceAccessFor: (evidenceItemId: string) => string | null,
): DerivedVerification {
  return deriveClaimVerification({
    checkpoints: state.checkpoints,
    links: answeredLinksFor(revision, state, sourceAccessFor),
  })
}

/**
 * Begrunnelsen for en godkjenning, skrevet av kontrollen selv.
 *
 * Etter en fullført kontroll uten åpne avvik sier «hvorfor godkjenner du?»
 * ingenting kontrollen ikke allerede har sagt. Teksten er derfor deterministisk
 * — men den er ikke tom, og den er ikke en formalitet: den navngir nøyaktig
 * hvilken kontroll godkjenningen hviler på (CONTENT_GOVERNANCE.md §39).
 */
export function approvalRationale(tally: ControlTally): string {
  return (
    'Godkjent for publisering etter en fullført kontrolløkt. ' +
    `${String(tally.confirmed)} av ${String(tally.total)} delkontroller bekreftet, ` +
    `${String(tally.deviations)} avvik og ${String(tally.unresolved)} uavklarte punkter.`
  )
}

/** Begrunnelsen for publiseringen. Handlingen er teknisk; sporet skal likevel si hvorfor. */
export function publicationReason(revision: ClaimReviewRevision): string {
  return (
    `Publisert etter fullført kontroll av kildegrunnlag og påstand, og etter registrert ` +
    `publiseringsgodkjenning av revisjon ${String(revision.dossier.revisionNumber)}.`
  )
}

export function buildClaimSteps({
  revision,
  isOwnRevision,
  state,
  handlers,
  sourceAccessFor,
  sessionTally,
}: {
  readonly revision: ClaimReviewRevision
  readonly isOwnRevision: boolean
  readonly state: ClaimSessionState
  readonly handlers: ClaimSessionHandlers
  readonly sourceAccessFor: (evidenceItemId: string) => string | null
  /** Hele øktens delkontroller, ekstraksjon og påstand under ett. */
  readonly sessionTally: ControlTally
}): readonly WizardStep[] {
  const { dossier } = revision

  const steps: WizardStep[] = [
    {
      id: claimIntroStepId(),
      title: 'Du skal kontrollere følgende påstand',
      answerSummary: state.started ? 'Lest' : null,
      isComplete: state.started,
      countsTowardProgress: false,
      content: (
        <div className="control-step__form">
          <blockquote className="control-claim-statement">{dossier.claim.statement}</blockquote>
          <button onClick={handlers.onStart} type="button">
            Start kontroll
          </button>
        </div>
      ),
    },
  ]

  if (isOwnRevision) {
    steps.push({
      id: claimCommitStepId(),
      title: 'Du kan ikke kontrollere din egen påstand',
      answerSummary: 'Kontrolleres av en annen',
      isComplete: true,
      countsTowardProgress: false,
      content: (
        <div className="knowledge-notice knowledge-notice--absence" role="note">
          <p className="knowledge-notice__lead">
            Du formulerte denne revisjonen selv, og kan derfor verken kontrollere eller godkjenne
            den.
          </p>
          <p className="knowledge-notice__caveat">
            Generering og kontroll skal være atskilte operasjoner. En annen kvalifisert person må
            gjøre begge stegene.
          </p>
        </div>
      ),
    })
    return steps
  }

  for (const link of dossier.links) {
    const entry = state.links[link.claimEvidenceLinkId]
    const relationshipSentence = relationshipQuestion(link.relationshipType)
    steps.push({
      id: linkStepId(link.claimEvidenceLinkId),
      title: `Grunnlagets rolle: ${link.evidenceItem.sourceTitle}`,
      answerSummary: answerSummary(entry),
      isComplete: isAnswerComplete(entry),
      countsTowardProgress: true,
      content: (
        <div className="control-step__form">
          <p className="field-check__statement">{relationshipSentence}</p>
          {link.relevanceNote.trim().length === 0 ? null : (
            <p className="field-check__detail">{link.relevanceNote}</p>
          )}
          <ControlChoice
            legend="Stemmer det?"
            onChoose={(value) => handlers.onLink(link.claimEvidenceLinkId, value as ControlAnswer)}
            options={CONTROL_ANSWER_OPTIONS}
            value={entry?.answer ?? null}
          />
          {entry?.answer === 'no' ? (
            <label className="field-check__note">
              Hva er feil, eller hvordan bør denne lenken forstås?
              <textarea
                onChange={(event) =>
                  handlers.onLinkNote(link.claimEvidenceLinkId, event.target.value)
                }
                rows={3}
                value={entry.note}
              />
            </label>
          ) : null}
        </div>
      ),
    })
  }

  for (const checkpoint of CLAIM_CHECKPOINTS) {
    const entry = state.checkpoints[checkpoint.key]
    const context = checkpointContext(checkpoint.key, dossier)
    steps.push({
      id: checkpointStepId(checkpoint.key),
      title: checkpoint.label,
      answerSummary: answerSummary(entry),
      isComplete: isAnswerComplete(entry),
      countsTowardProgress: true,
      content: (
        <div className="control-step__form">
          <CheckpointPanes claimSide={context.claimSide} evidenceSide={context.evidenceSide} />
          <ControlChoice
            legend={checkpoint.question}
            onChoose={(value) => handlers.onCheckpoint(checkpoint.key, value as ControlAnswer)}
            options={CONTROL_ANSWER_OPTIONS}
            value={entry?.answer ?? null}
          />
          {entry?.answer === 'no' ? (
            <label className="field-check__note">
              Hva er feil, eller hvordan bør dette forstås?
              <textarea
                onChange={(event) => handlers.onCheckpointNote(checkpoint.key, event.target.value)}
                rows={3}
                value={entry.note}
              />
            </label>
          ) : null}
        </div>
      ),
    })
  }

  const claimCounts = claimTally(
    state.checkpoints,
    answeredLinksFor(revision, state, sourceAccessFor),
  )
  const derivedClaim = derivedClaimFor(revision, state, sourceAccessFor)
  const claimReady =
    CLAIM_CHECKPOINTS.every((checkpoint) => isAnswerComplete(state.checkpoints[checkpoint.key])) &&
    dossier.links.every((link) => isAnswerComplete(state.links[link.claimEvidenceLinkId]))

  steps.push({
    id: claimCommitStepId(),
    title: 'Lagre kontrollen av påstanden',
    answerSummary:
      state.savedClaimVerificationId === null
        ? null
        : `Registrert: ${outcomeLabel(derivedClaim.outcome)}`,
    isComplete: state.savedClaimVerificationId !== null,
    countsTowardProgress: false,
    content: (
      <div className="control-step__form">
        <p className="control-summary">
          {`${String(claimCounts.confirmed)} av ${String(claimCounts.total)} kontrollpunkter holder. `}
          {claimCounts.deviations === 0
            ? 'Ingen avvik. '
            : `${String(claimCounts.deviations)} avvik. `}
          {claimCounts.unresolved === 0
            ? 'Ingenting sto uavklart.'
            : `${String(claimCounts.unresolved)} kunne ikke avgjøres.`}
        </p>
        <p className="control-summary__outcome">
          {`Dette blir registrert som: ${outcomeLabel(derivedClaim.outcome)}.`}
        </p>
        {state.claimProblem === null ? null : (
          <p className="admin-form__problem" role="alert">
            Kontrollen ble ikke registrert. {state.claimProblem}
          </p>
        )}
        <button
          disabled={!claimReady || state.savingClaim}
          onClick={handlers.onSaveClaim}
          type="button"
        >
          {state.savingClaim ? 'Lagrer …' : 'Lagre og fortsett'}
        </button>
        {claimReady ? null : (
          <p className="control-summary__note">
            Svar på alle kontrollpunktene over før kontrollen kan registreres.
          </p>
        )}
      </div>
    ),
  })

  const canApprove = revision.approvalReadiness.status === 'passes'
  const needsWrittenRationale =
    state.decision === 'changes_requested' || state.decision === 'rejected'
  const decisionReady =
    state.decision !== null && (!needsWrittenRationale || state.decisionRationale.trim().length > 0)

  steps.push({
    id: publicationDecisionStepId(),
    title: 'Kan denne påstanden publiseres slik den står?',
    answerSummary: state.savedDecisionId === null ? null : decisionLabel(state.decision ?? ''),
    isComplete: state.savedDecisionId !== null,
    countsTowardProgress: false,
    content: (
      <div className="control-step__form">
        <p className="control-summary">
          Kontrollen er ferdig.{' '}
          {`${String(sessionTally.confirmed)} av ${String(sessionTally.total)} nødvendige delkontroller er bekreftet. `}
          {sessionTally.deviations === 0
            ? 'Ingen åpne avvik.'
            : `${String(sessionTally.deviations)} åpne avvik.`}
        </p>
        {canApprove ? null : (
          <div className="knowledge-notice knowledge-notice--absence" role="note">
            <p className="knowledge-notice__lead">
              Du kan ikke gå god for publisering ennå: grunnlaget er ikke ferdig kontrollert.
            </p>
            <p className="knowledge-notice__detail">{revision.approvalReadiness.message}</p>
            <p className="knowledge-notice__caveat">
              «Be om endringer» og «Avvis» kan du registrere som vanlig.
            </p>
          </div>
        )}
        <ControlChoice
          legend="Din beslutning"
          onChoose={handlers.onDecision}
          options={[
            ...(canApprove ? [{ value: 'approved', label: 'Godkjenn for publisering' }] : []),
            { value: 'changes_requested', label: 'Be om endringer' },
            { value: 'rejected', label: 'Avvis' },
          ]}
          value={state.decision}
        />
        {needsWrittenRationale ? (
          <label className="field-check__note">
            Hva må endres, eller hvorfor holder ikke påstanden?
            <textarea
              onChange={(event) => handlers.onDecisionRationale(event.target.value)}
              rows={4}
              value={state.decisionRationale}
            />
          </label>
        ) : null}
        {state.decisionProblem === null ? null : (
          <p className="admin-form__problem" role="alert">
            Beslutningen ble ikke registrert. {state.decisionProblem}
          </p>
        )}
        <button
          disabled={!decisionReady || state.savingDecision}
          onClick={handlers.onSaveDecision}
          type="button"
        >
          {state.savingDecision ? 'Lagrer …' : 'Lagre beslutningen'}
        </button>
      </div>
    ),
  })

  const gate = revision.publicationGate
  steps.push({
    id: publicationStepId(),
    title: 'Publiser påstanden',
    answerSummary: state.publishedEventId === null ? null : 'Publisert',
    isComplete: state.publishedEventId !== null,
    countsTowardProgress: false,
    content: (
      <div className="control-step__form">
        {gate.status === 'passes' ? (
          <>
            <p className="control-summary">
              Alle vilkårene for publisering er oppfylt. Antidep kjører dem én gang til i det
              publiseringen skjer.
            </p>
            {state.publishProblem === null ? null : (
              <p className="admin-form__problem" role="alert">
                Påstanden ble ikke publisert. {state.publishProblem}
              </p>
            )}
            <button disabled={state.publishing} onClick={handlers.onPublish} type="button">
              {state.publishing ? 'Publiserer …' : 'Publiser påstanden'}
            </button>
          </>
        ) : (
          <div className="knowledge-notice knowledge-notice--absence" role="note">
            <p className="knowledge-notice__lead">Påstanden kan ikke publiseres ennå.</p>
            <p className="knowledge-notice__detail">{gate.message}</p>
            {gate.hint === null ? null : <p className="knowledge-notice__caveat">{gate.hint}</p>}
          </div>
        )}
      </div>
    ),
  })

  return steps
}

/**
 * Relasjonstypen som et utsagn kontrolløren kan svare ja eller nei på.
 *
 * Ikke etiketten alene: «Motsier påstanden» er en påstand om funnet, og den skal
 * kontrolleres som en påstand. Ordlyden er den samme som `stanceText()` bruker,
 * satt inn i en setning (ANTIDEP_CONSTITUTION.md §9).
 */
function relationshipQuestion(relationshipType: string): string {
  switch (relationshipType) {
    case 'supports':
      return 'Antidep har registrert at dette funnet støtter påstanden.'
    case 'partially_supports':
      return 'Antidep har registrert at dette funnet støtter deler av påstanden.'
    case 'contradicts':
      return 'Antidep har registrert at dette funnet motsier påstanden.'
    case 'neutral_contextual':
      return 'Antidep har registrert at dette funnet verken taler for eller mot påstanden.'
    case 'indirect':
      return 'Antidep har registrert at dette funnet bare er indirekte bedømbart mot påstanden.'
    default:
      return `Antidep har registrert en relasjon dette systemet ikke kjenner («${relationshipType}»).`
  }
}
