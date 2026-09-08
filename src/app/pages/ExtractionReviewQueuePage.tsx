// ============================================================================
// Køen for ekstraksjonskontroll — `/extraction-review`
//
// Leddet før den faglige vurderingen av en påstand (MVP_IMPLEMENTATION_PLAN.md
// §15): hvilke evidensfunn som venter på at et menneske kontrollerer dem mot
// kilden. Publiseringsgatens G4 og G5 krever nettopp denne kontrollen, og den
// deterministiske verifikatoren kan per konstruksjon ikke dekke alle feltene et
// funn påstår noe om (§74.34).
//
// ----------------------------------------------------------------------------
// Ingen rollegate, bare en innloggingsgate
//
// Samme doktrine som reviewkøen: `api.extraction_review_workspace()` avviser en
// kaller uten reviewer-rolle på sitt eget tidspunkt, og siden viser den
// avvisningen med databasens egen setning. En klient som skjulte køen ville lovet
// noe den ikke kan stå for (DATABASE_ARCHITECTURE.md §43, §48).
//
// ----------------------------------------------------------------------------
// Hva raden sier, og hva den ikke sier
//
// Utfallet av den gjeldende kontrollen står som status, men fravær står som
// fravær: «ingen kontroll registrert» er ikke det samme som en kontroll som
// konkluderte negativt, og en tom kø er ikke et svar om at kunnskapsbasen er
// ferdig kontrollert (ANTIDEP_CONSTITUTION.md §17).
//
// Feltdekningen står som et tall av et tall, og tallene kommer fra
// publiseringsgatens egne funksjoner. Raden regner ingenting ut på nytt.
// ============================================================================

import { Link } from 'react-router'
import {
  fetchExtractionQueue,
  uncoveredCheckFields,
  type ExtractionQueueItem,
} from '../../lib/extraction-review'
import {
  SOURCE_STATUS_LABELS,
  VERIFICATION_OUTCOME_LABELS,
  termText,
} from '../../components/vocabulary-labels'
import { readSourceStatus, readVerificationOutcome } from '../../lib/evidence-item'
import { useAuthSession, type AuthSessionState } from '../use-auth-session'
import { usePageTitle } from '../use-page-title'
import { useReadModel } from '../use-read-model'
import { accessPath, extractionReviewPath } from '../routes'

function SignedOutNotice() {
  return (
    <div className="knowledge-notice knowledge-notice--absence" role="note">
      <p className="knowledge-notice__lead">Du må logge inn for å se køen for kildekontroll.</p>
      <p className="knowledge-notice__caveat">
        <Link to={accessPath()}>Logg inn under «Min tilgang»</Link>, og kom tilbake hit.
      </p>
    </div>
  )
}

function QueueRow({ item }: { readonly item: ExtractionQueueItem }) {
  const outstanding = uncoveredCheckFields(item)
  return (
    <li className="review-queue__item">
      <h3>
        <Link to={extractionReviewPath(item.evidenceItemId)}>{item.sourceTitle}</Link>
      </h3>
      <p className="review-queue__meta">
        {`${item.interventionDrugName} · ${item.outcomeLabel} · registrert av ${
          item.createdByActorKey
        } · ${String(item.linkedClaimRevisionCount)} påstandsrevisjon${
          item.linkedClaimRevisionCount === 1 ? '' : 'er'
        }`}
      </p>
      <p className="review-queue__status">
        {'Gjeldende kontroll: '}
        {item.currentExtractionVerificationOutcome === null ? (
          <span className="review-absent">ingen registrert</span>
        ) : (
          termText(
            readVerificationOutcome(item.currentExtractionVerificationOutcome),
            VERIFICATION_OUTCOME_LABELS,
            'utfall',
          )
        )}
        {' · Felter som står igjen: '}
        {outstanding.length === 0 ? (
          `ingen av ${String(item.requiredCheckFields.length)}`
        ) : (
          <>{`${String(outstanding.length)} av ${String(item.requiredCheckFields.length)}`}</>
        )}
        {' · Kildestatus: '}
        {termText(readSourceStatus(item.sourceStatus), SOURCE_STATUS_LABELS, 'kildestatus')}
      </p>
    </li>
  )
}

function QueueBody() {
  const queue = useReadModel(fetchExtractionQueue)

  switch (queue.status) {
    case 'loading':
      return (
        <p
          className="knowledge-notice knowledge-notice--loading"
          aria-busy="true"
          aria-live="polite"
        >
          Henter køen for kildekontroll …
        </p>
      )
    case 'error':
      return (
        <div className="knowledge-notice knowledge-notice--error" role="alert">
          <p className="knowledge-notice__lead">Antidep fikk ikke hentet køen.</p>
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
          <p className="knowledge-notice__lead">
            Ingen evidensfunn venter på kildekontroll fra deg nå.
          </p>
          <p className="knowledge-notice__caveat">
            Køen viser funn du ikke selv har registrert, som du ikke selv har kontrollert, og som
            hører til et endepunkt reviewer-tildelingen din dekker. At den er tom, betyr ikke at
            alle ekstraksjoner er kontrollert.
          </p>
        </div>
      )
    case 'ok':
      return (
        <ul className="review-queue">
          {queue.items.map((item) => (
            <QueueRow key={item.evidenceItemId} item={item} />
          ))}
        </ul>
      )
  }
}

function ExtractionQueueBody({ authState }: { readonly authState: AuthSessionState }) {
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

export function ExtractionReviewQueuePage() {
  usePageTitle('Kildekontroll av evidensfunn')
  const authState = useAuthSession()

  return (
    <>
      <p className="page-kicker">Kildekontroll</p>
      <h2>Kildekontroll av evidensfunn</h2>
      <p className="admin-form__intro">
        Her ligger evidensfunnene som venter på at et menneske kontrollerer ekstraksjonen mot
        kilden. Dette er et annet ledd enn den faglige vurderingen av en påstand: her spør vi om
        raden gjengir det kilden faktisk rapporterer, ikke om grunnlaget støtter en påstand.
      </p>
      <ExtractionQueueBody authState={authState} />
    </>
  )
}
