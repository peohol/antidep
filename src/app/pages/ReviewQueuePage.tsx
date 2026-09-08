// ============================================================================
// Reviewkøen — `/review`
//
// Steg 4 av «manuell adminflyt» (MVP_IMPLEMENTATION_PLAN.md §15, §29): hvilke
// påstandsrevisjoner som venter på faglig vurdering. Første halvdel av det
// ANTIDEP_CONSTITUTION.md §15 krever — at en kvalifisert redaktør kan gjøre
// arbeidet sitt uten Claude, ChatGPT eller direkte databaseinngrep.
//
// ----------------------------------------------------------------------------
// Ingen rollegate, bare en innloggingsgate
//
// Samme doktrine som de tre registreringssidene: `api.claim_review_workspace()`
// avviser en kaller uten reviewer-rolle på sitt eget tidspunkt, og siden viser
// den avvisningen med databasens egen setning. En klient som skjulte køen ville
// lovet noe den ikke kan stå for (DATABASE_ARCHITECTURE.md §43, §48).
//
// ----------------------------------------------------------------------------
// Hva raden sier, og hva den ikke sier
//
// Utfallet av den gjeldende kontrollen og den gjeldende beslutningen står som
// status, men fravær står som fravær: «ingen kontroll registrert» er ikke det
// samme som en kontroll som konkluderte negativt, og en tom kø er ikke et svar
// om at kunnskapsbasen er ferdig vurdert (ANTIDEP_CONSTITUTION.md §17).
//
// Rekkefølgen er databasens: eldste først. Den er en arbeidskø og ingen
// prioritering — ingenting her sier hvilken påstand som haster mest.
// ============================================================================

import { Link } from 'react-router'
import { fetchReviewQueue } from '../../lib/review-workspace'
import {
  REVIEW_OUTCOME_LABELS,
  VERIFICATION_OUTCOME_LABELS,
  termText,
} from '../../components/vocabulary-labels'
import { readReviewOutcome, readVerificationOutcome } from '../../lib/evidence-item'
import { useAuthSession, type AuthSessionState } from '../use-auth-session'
import { usePageTitle } from '../use-page-title'
import { useReadModel } from '../use-read-model'
import { accessPath, claimReviewPath } from '../routes'
import type { ReviewQueueItem } from '../../lib/review-workspace'

function SignedOutNotice() {
  return (
    <div className="knowledge-notice knowledge-notice--absence" role="note">
      <p className="knowledge-notice__lead">Du må logge inn for å se reviewkøen.</p>
      <p className="knowledge-notice__caveat">
        <Link to={accessPath()}>Logg inn under «Min tilgang»</Link>, og kom tilbake hit.
      </p>
    </div>
  )
}

function QueueRow({ item }: { readonly item: ReviewQueueItem }) {
  return (
    <li className="review-queue__item">
      <h3>
        <Link to={claimReviewPath(item.claimRevisionId)}>{item.statement}</Link>
      </h3>
      <p className="review-queue__meta">
        {`${item.subjectDrugName} · ${item.topicLabel} · revisjon ${String(
          item.revisionNumber,
        )} · ${String(item.evidenceLinkCount)} evidenslenke${
          item.evidenceLinkCount === 1 ? '' : 'r'
        } · formulert av ${item.createdByActorKey}`}
      </p>
      <p className="review-queue__status">
        {'Kontroll mot grunnlaget: '}
        {item.currentClaimVerificationOutcome === null ? (
          <span className="review-absent">ingen registrert</span>
        ) : (
          termText(
            readVerificationOutcome(item.currentClaimVerificationOutcome),
            VERIFICATION_OUTCOME_LABELS,
            'utfall',
          )
        )}
        {' · Publiseringsbeslutning: '}
        {item.currentPublicationDecision === null ? (
          <span className="review-absent">ingen registrert</span>
        ) : (
          termText(
            readReviewOutcome(item.currentPublicationDecision),
            REVIEW_OUTCOME_LABELS,
            'reviewbeslutning',
          )
        )}
        {item.isPublishedRevision ? ' · Publisert' : ''}
      </p>
    </li>
  )
}

function QueueBody() {
  const queue = useReadModel(fetchReviewQueue)

  switch (queue.status) {
    case 'loading':
      return (
        <p
          className="knowledge-notice knowledge-notice--loading"
          aria-busy="true"
          aria-live="polite"
        >
          Henter reviewkøen …
        </p>
      )
    case 'error':
      return (
        <div className="knowledge-notice knowledge-notice--error" role="alert">
          <p className="knowledge-notice__lead">Antidep fikk ikke hentet reviewkøen.</p>
          <p className="knowledge-notice__detail">Teknisk årsak: {queue.message}</p>
          <p className="knowledge-notice__caveat">
            Mangler kontoen din reviewer-rollen, står grunnen i teksten over.{' '}
            <Link to={accessPath()}>Se «Min tilgang»</Link> for hva kontoen din har.
          </p>
        </div>
      )
    case 'empty':
      return (
        <div className="knowledge-notice knowledge-notice--absence" role="note">
          <p className="knowledge-notice__lead">Ingen påstandsrevisjoner venter på vurdering nå.</p>
          <p className="knowledge-notice__caveat">
            Køen viser revisjoner du ikke selv har formulert, som har minst én evidenslenke, og som
            hører til et innholdsområde reviewer-tildelingen din dekker. At den er tom, betyr ikke
            at kunnskapsbasen er ferdig vurdert.
          </p>
        </div>
      )
    case 'ok':
      return (
        <ul className="review-queue">
          {queue.items.map((item) => (
            <QueueRow key={item.claimRevisionId} item={item} />
          ))}
        </ul>
      )
  }
}

function ReviewQueueBody({ authState }: { readonly authState: AuthSessionState }) {
  switch (authState.status) {
    case 'loading':
      return (
        <p
          className="knowledge-notice knowledge-notice--loading"
          aria-busy="true"
          aria-live="polite"
        >
          Sjekker innloggingen …
        </p>
      )
    case 'unavailable':
      return (
        <div className="knowledge-notice knowledge-notice--error" role="alert">
          <p className="knowledge-notice__lead">Antidep fikk ikke sjekket innloggingen din.</p>
          <p className="knowledge-notice__detail">Teknisk årsak: {authState.message}</p>
        </div>
      )
    case 'signed_out':
      return <SignedOutNotice />
    case 'signed_in':
      return <QueueBody key={authState.userId} />
  }
}

export function ReviewQueuePage() {
  usePageTitle('Faglig vurdering')
  const authState = useAuthSession()

  return (
    <>
      <p className="page-kicker">Review</p>
      <h2>Faglig vurdering</h2>
      <p className="admin-form__intro">
        Her ligger påstandsrevisjonene som venter på menneskelig faglig vurdering. Hver revisjon
        vurderes i to atskilte steg: først kontrollen av at påstanden holder mot det registrerte
        evidensgrunnlaget, deretter beslutningen om at den kan publiseres.
      </p>
      <ReviewQueueBody authState={authState} />
    </>
  )
}
