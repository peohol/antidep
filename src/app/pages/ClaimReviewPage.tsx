// ============================================================================
// Reviewarbeidsflaten for én påstandsrevisjon — `/review/:claimRevisionId`
//
// Her gjøres den menneskelige faglige vurderingen ANTIDEP_CONSTITUTION.md §12
// krever før klinisk innhold kan publiseres. Flaten viser hele grunnlaget —
// påstanden, hver evidenslenke med funnet og kilden, den gjeldende
// ekstraksjonskontrollen, registrert evidens som ikke er lenket,
// evidensvurderingen, kontrollene og beslutningene som allerede finnes — og
// hva publiseringsgaten svarer.
//
// ----------------------------------------------------------------------------
// To skjemaer, og det er ikke en layoutdetalj
//
// Kontrollen mot grunnlaget (§11) og beslutningen om å publisere (§12) er to
// forskjellige faglige utsagn, lagret som to beslutningsobjekter i to tabeller,
// og publiseringsgaten krever dem hver for seg (G9 og G11). Flaten har derfor to
// atskilte handlinger og ingen «godkjenn alt»-knapp. En samlet knapp ville latt
// én museklikk stå for to vurderinger som skal kunne skilles i ettertid — og
// gjort det umulig å se hvilken av dem revieweren faktisk gjorde.
//
// ----------------------------------------------------------------------------
// Ingen validering som gjentar databasens
//
// Skjemaene samler inn og sender. At en bekreftelse krever at alle sju punktene
// er `ok`, at alle evidenslenkene må være kontrollert, at et utfall som ikke er
// `verified` krever et funn, og at en reviewer ikke kan vurdere sin egen påstand
// — alt håndheves av constraintene og triggerne på tabellene, og deres
// avvisninger vises ordrett (DATABASE_ARCHITECTURE.md §43, §57). Det flaten gjør,
// er å si det på forhånd, slik at regelen ikke er en overraskelse.
//
// Det gjelder også godkjenningen: at den ikke kan gis før grunnlaget er
// kontrollert, avgjøres av databasen (migrasjon 006e), og flaten leser svaret
// fra den samme funksjonen skriveveien bruker. Den regner ikke ut på nytt om
// godkjenning er mulig — da kunne de to kommet i utakt, og flaten tilbudt noe
// databasen avviser, eller stengt noe den ville godtatt.
//
// ----------------------------------------------------------------------------
// Avtrykket sendes tilbake uendret
//
// Begge skriveveiene får avtrykket av evidenssettet slik flaten faktisk viste
// det. Kommer det en evidenslenke til mens vurderingen pågår, avvises
// registreringen — og det er riktig: den nye lenken kan være nettopp den
// motstridende evidensen kontrollen skulle lete etter (§9).
// ============================================================================

import { useCallback, useId, useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router'
import {
  ClaimStatementPanel,
  DecisionHistoryPanel,
  EvidenceAssessmentPanel,
  EvidenceLinkPanel,
  PublicationGatePanel,
  UnlinkedEvidencePanel,
  VerificationHistoryPanel,
} from '../../components/ReviewDossier'
import {
  CLAIM_CHECKPOINTS,
  REVIEW_OUTCOME_LABELS,
  VERIFICATION_CHECK_RESULT_LABELS,
  VERIFICATION_OUTCOME_LABELS,
  VERIFICATION_SOURCE_ACCESS_LABELS,
} from '../../components/vocabulary-labels'
import { registerHumanClaimVerification } from '../../lib/register-human-claim-verification'
import { registerPublicationApproval } from '../../lib/register-publication-approval'
import { fetchClaimReview } from '../../lib/review-workspace'
import {
  VERIFICATION_CHECK_RESULTS,
  VERIFICATION_OUTCOMES,
  VERIFICATION_SOURCE_ACCESSES,
} from '../../types/api'
import { useAntidepClient } from '../antidep-client'
import { useAuthSession, type AuthSessionState } from '../use-auth-session'
import { usePageTitle } from '../use-page-title'
import { useReadModel } from '../use-read-model'
import { accessPath, reviewQueuePath } from '../routes'
import type { ClaimCheckpointKey } from '../../components/vocabulary-labels'
import type { ClaimVerificationCitationInput } from '../../lib/register-human-claim-verification'
import type { ClaimReviewWorkspace } from '../../lib/review-workspace'
import type { Uuid } from '../../types/api'

/** De tre beslutningene en publiseringsgodkjenning kan ende i. */
const APPROVAL_DECISIONS = ['approved', 'changes_requested', 'rejected'] as const

function SignedOutNotice() {
  return (
    <div className="knowledge-notice knowledge-notice--absence" role="note">
      <p className="knowledge-notice__lead">Du må logge inn for å vurdere en påstand.</p>
      <p className="knowledge-notice__caveat">
        <Link to={accessPath()}>Logg inn under «Min tilgang»</Link>, og kom tilbake hit.
      </p>
    </div>
  )
}

/** Tom streng fra et valgfritt tekstfelt betyr «ikke oppgitt», ikke en verdi å lagre. */
function blankToNull(value: string): string | null {
  return value.trim().length === 0 ? null : value
}

// ----------------------------------------------------------------------------
// Skjema 1 — den faglige kontrollen mot grunnlaget
// ----------------------------------------------------------------------------

interface LinkAssessment {
  readonly sourceAccess: string
  readonly relationshipSupported: string
  readonly finding: string
}

function emptyLinkAssessment(): LinkAssessment {
  return {
    // Ingen forhåndsutfylling som ser ut som en vurdering: den svakeste
    // kildetilgangen og det mest forbeholdne resultatet er utgangspunktet, slik
    // at en reviewer som ikke rører feltet, ikke har hevdet mer enn hen så.
    sourceAccess: 'derived_summary',
    relationshipSupported: 'not_assessable',
    finding: '',
  }
}

function ClaimVerificationForm({
  workspace,
  onRegistered,
}: {
  readonly workspace: ClaimReviewWorkspace
  readonly onRegistered: () => void
}) {
  const availability = useAntidepClient()
  const { dossier } = workspace.revision
  const [checks, setChecks] = useState<Record<ClaimCheckpointKey, string>>(
    () =>
      Object.fromEntries(
        CLAIM_CHECKPOINTS.map((checkpoint) => [checkpoint.key, 'not_assessable']),
      ) as Record<ClaimCheckpointKey, string>,
  )
  const [links, setLinks] = useState<Record<string, LinkAssessment>>(() =>
    Object.fromEntries(
      dossier.links.map((link) => [link.claimEvidenceLinkId, emptyLinkAssessment()]),
    ),
  )
  const [outcome, setOutcome] = useState('uncertain')
  const [rationale, setRationale] = useState('')
  const [findings, setFindings] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)

  const outcomeId = useId()
  const rationaleId = useId()
  const findingsId = useId()
  const problemId = useId()

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (availability.status !== 'ready') {
      return
    }
    setSubmitting(true)
    setProblem(null)

    const citations: ClaimVerificationCitationInput[] = dossier.links.map((link) => {
      const assessment = links[link.claimEvidenceLinkId] ?? emptyLinkAssessment()
      // Kildeversjonen og fingeravtrykket er kildeversjonens egne, lest av
      // grunnlaget — aldri skrevet inn av revieweren. En verdi hen kunne oppgi,
      // ville sett ut som en garanti uten å være det, og databasen ville uansett
      // avvist et fingeravtrykk som ikke er kildeversjonens registrerte.
      const version =
        assessment.sourceAccess === 'derived_summary' ? null : link.evidenceItem.sourceVersion
      return {
        claimEvidenceLinkId: link.claimEvidenceLinkId,
        sourceAccess: assessment.sourceAccess,
        sourceVersionId: version === null ? null : version.sourceVersionId,
        checkedContentHash: version === null ? null : version.contentHash,
        relationshipSupported: assessment.relationshipSupported,
        finding: blankToNull(assessment.finding),
      }
    })

    const result = await registerHumanClaimVerification(availability.client, {
      claimRevisionId: dossier.claimRevisionId,
      seenEvidenceSetDigest: dossier.evidenceSetDigest,
      outcome,
      sourceSupport: checks.sourceSupport,
      populationMatch: checks.populationMatch,
      comparatorMatch: checks.comparatorMatch,
      timeframeMatch: checks.timeframeMatch,
      directionAndMagnitude: checks.directionAndMagnitude,
      qualifiersComplete: checks.qualifiersComplete,
      contradictoryEvidenceRepresented: checks.contradictoryEvidenceRepresented,
      citations,
      rationale,
      findings: blankToNull(findings),
    })
    setSubmitting(false)
    if (result.status === 'error') {
      setProblem(result.message)
      return
    }
    onRegistered()
  }

  return (
    <form className="admin-form admin-form--review" onSubmit={(event) => void handleSubmit(event)}>
      <h3>1. Registrer din kontroll mot grunnlaget</h3>
      <p className="admin-form__intro">
        Dette er den faglige kontrollen: holder påstanden mot det som faktisk er registrert? Den er
        ikke det samme som å gå god for publisering — det er steg 2. Et punkt som ikke lot seg
        bedømme er ikke et bestått punkt, og et utfall på «Bekreftet» krever at alle sju punktene
        holder og at ingen evidenslenke står uavklart.
      </p>

      <fieldset className="admin-form__section">
        <legend>De sju kontrollpunktene</legend>
        {CLAIM_CHECKPOINTS.map((checkpoint) => (
          <div className="admin-form__field" key={checkpoint.key}>
            <label htmlFor={`${outcomeId}-${checkpoint.key}`}>{checkpoint.label}</label>
            <select
              id={`${outcomeId}-${checkpoint.key}`}
              onChange={(event) => setChecks({ ...checks, [checkpoint.key]: event.target.value })}
              value={checks[checkpoint.key]}
            >
              {VERIFICATION_CHECK_RESULTS.map((value) => (
                <option key={value} value={value}>
                  {VERIFICATION_CHECK_RESULT_LABELS[value]}
                </option>
              ))}
            </select>
            <p className="admin-form__hint">{checkpoint.question}</p>
          </div>
        ))}
      </fieldset>

      <fieldset className="admin-form__section">
        <legend>Hver evidenslenke</legend>
        <p className="admin-form__hint">
          Kontrollen må dekke hele evidenssettet, også lenkene som motsier påstanden. Den samlede
          kildetilgangen blir den svakeste av dem — en bekreftelse kan ikke hvile på et sammendrag
          fra et annet ledd.
        </p>
        {dossier.links.map((link) => {
          const assessment = links[link.claimEvidenceLinkId] ?? emptyLinkAssessment()
          return (
            <div className="admin-form__group" key={link.claimEvidenceLinkId}>
              <h4>{link.evidenceItem.sourceTitle}</h4>
              <div className="admin-form__field">
                <label htmlFor={`${rationaleId}-access-${link.claimEvidenceLinkId}`}>
                  Hva hadde du tilgang til?
                </label>
                <select
                  id={`${rationaleId}-access-${link.claimEvidenceLinkId}`}
                  onChange={(event) =>
                    setLinks({
                      ...links,
                      [link.claimEvidenceLinkId]: {
                        ...assessment,
                        sourceAccess: event.target.value,
                      },
                    })
                  }
                  value={assessment.sourceAccess}
                >
                  {VERIFICATION_SOURCE_ACCESSES.map((value) => (
                    <option
                      disabled={
                        value !== 'derived_summary' && link.evidenceItem.sourceVersion === null
                      }
                      key={value}
                      value={value}
                    >
                      {VERIFICATION_SOURCE_ACCESS_LABELS[value]}
                    </option>
                  ))}
                </select>
                {link.evidenceItem.sourceVersion === null ? (
                  <p className="admin-form__hint">
                    Denne lenken har ingen registrert kildeversjon, så kontrollen din kan ikke
                    knyttes til en etterprøvbar representasjon. Registrer kildeversjonen først hvis
                    kontrollen skal kunne bygge på den.
                  </p>
                ) : null}
              </div>
              <div className="admin-form__field">
                <label htmlFor={`${rationaleId}-rel-${link.claimEvidenceLinkId}`}>
                  Holder den registrerte relasjonstypen?
                </label>
                <select
                  id={`${rationaleId}-rel-${link.claimEvidenceLinkId}`}
                  onChange={(event) =>
                    setLinks({
                      ...links,
                      [link.claimEvidenceLinkId]: {
                        ...assessment,
                        relationshipSupported: event.target.value,
                      },
                    })
                  }
                  value={assessment.relationshipSupported}
                >
                  {VERIFICATION_CHECK_RESULTS.map((value) => (
                    <option key={value} value={value}>
                      {VERIFICATION_CHECK_RESULT_LABELS[value]}
                    </option>
                  ))}
                </select>
              </div>
              <div className="admin-form__field">
                <label htmlFor={`${rationaleId}-finding-${link.claimEvidenceLinkId}`}>
                  Hva fant du? (påkrevd når relasjonstypen ikke holder)
                </label>
                <textarea
                  id={`${rationaleId}-finding-${link.claimEvidenceLinkId}`}
                  onChange={(event) =>
                    setLinks({
                      ...links,
                      [link.claimEvidenceLinkId]: { ...assessment, finding: event.target.value },
                    })
                  }
                  rows={2}
                  value={assessment.finding}
                />
              </div>
            </div>
          )
        })}
      </fieldset>

      <div className="admin-form__field">
        <label htmlFor={outcomeId}>Samlet utfall</label>
        <select id={outcomeId} onChange={(event) => setOutcome(event.target.value)} value={outcome}>
          {VERIFICATION_OUTCOMES.map((value) => (
            <option key={value} value={value}>
              {VERIFICATION_OUTCOME_LABELS[value]}
            </option>
          ))}
        </select>
      </div>

      <div className="admin-form__field">
        <label htmlFor={rationaleId}>Faglig begrunnelse</label>
        <textarea
          id={rationaleId}
          onChange={(event) => setRationale(event.target.value)}
          required
          rows={4}
          value={rationale}
        />
      </div>

      <div className="admin-form__field">
        <label htmlFor={findingsId}>Funn (påkrevd når utfallet ikke er «Bekreftet»)</label>
        <textarea
          id={findingsId}
          onChange={(event) => setFindings(event.target.value)}
          rows={3}
          value={findings}
        />
      </div>

      {problem === null ? null : (
        <p className="admin-form__problem" id={problemId} role="alert">
          Kontrollen ble ikke registrert. {problem}
        </p>
      )}

      <button disabled={submitting} type="submit">
        {submitting ? 'Registrerer …' : 'Registrer kontrollen'}
      </button>
    </form>
  )
}

// ----------------------------------------------------------------------------
// Skjema 2 — publiseringsgodkjenningen
// ----------------------------------------------------------------------------

function PublicationApprovalForm({
  workspace,
  onRegistered,
}: {
  readonly workspace: ClaimReviewWorkspace
  readonly onRegistered: () => void
}) {
  const availability = useAntidepClient()
  const { approvalReadiness, dossier } = workspace.revision
  // Forutsetningene skriveveien krever før en godkjenning, lest av den samme
  // funksjonen databasen bruker (migrasjon 006e). Er de ikke oppfylt, tilbys
  // ikke godkjenning i det hele tatt: å la valget stå ville vært å tilby en
  // handling som uansett blir avvist. De to andre beslutningene står igjen —
  // det er nettopp nå de trengs.
  const canApprove = approvalReadiness.status === 'passes'
  const decisions = canApprove
    ? APPROVAL_DECISIONS
    : APPROVAL_DECISIONS.filter((value) => value !== 'approved')
  const [decision, setDecision] = useState<string>('changes_requested')
  const [rationale, setRationale] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)

  const decisionId = useId()
  const rationaleId = useId()

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (availability.status !== 'ready') {
      return
    }
    setSubmitting(true)
    setProblem(null)
    const result = await registerPublicationApproval(availability.client, {
      claimRevisionId: dossier.claimRevisionId,
      seenEvidenceSetDigest: dossier.evidenceSetDigest,
      decision,
      rationale,
    })
    setSubmitting(false)
    if (result.status === 'error') {
      setProblem(result.message)
      return
    }
    onRegistered()
  }

  return (
    <form className="admin-form admin-form--review" onSubmit={(event) => void handleSubmit(event)}>
      <h3>2. Registrer publiseringsbeslutningen</h3>
      <p className="admin-form__intro">
        Dette er en egen beslutning: går du god for at påstanden kan publiseres slik den står, på
        dette evidensgrunnlaget? Den erstatter ikke kontrollen i steg 1 — publiseringsgaten krever
        begge, og en godkjenning kan først gis når kontrollen i steg 1 er gjort. Et avslag og en
        anmodning om endringer bevares på lik linje med en godkjenning.
      </p>

      {canApprove ? null : (
        <div className="knowledge-notice knowledge-notice--absence" role="note">
          <p className="knowledge-notice__lead">
            Du kan ikke gå god for publisering ennå: grunnlaget er ikke ferdig kontrollert.
          </p>
          <p className="knowledge-notice__caveat">
            Det er den samme blokkeringen som står øverst på siden: forutsetningene før en
            godkjenning er nettopp de kravene publiseringsgaten stiller før den spør etter
            godkjenningen i det hele tatt.
          </p>
          <p className="knowledge-notice__caveat">
            En godkjenning skal gjelde innhold som er kontrollert mot kilden. Den blir stående som
            den gjeldende beslutningen, så en godkjenning gitt nå ville båret publiseringen den
            dagen kontrollen kom — uten at noen hadde sett innholdet i kontrollert stand. Et avslag
            og en anmodning om endringer kan du registrere som vanlig.
          </p>
        </div>
      )}

      <div className="admin-form__field">
        <label htmlFor={decisionId}>Beslutning</label>
        <select
          id={decisionId}
          onChange={(event) => setDecision(event.target.value)}
          value={decision}
        >
          {decisions.map((value) => (
            <option key={value} value={value}>
              {REVIEW_OUTCOME_LABELS[value]}
            </option>
          ))}
        </select>
      </div>

      <div className="admin-form__field">
        <label htmlFor={rationaleId}>Faglig begrunnelse</label>
        <textarea
          id={rationaleId}
          onChange={(event) => setRationale(event.target.value)}
          required
          rows={4}
          value={rationale}
        />
      </div>

      {problem === null ? null : (
        <p className="admin-form__problem" role="alert">
          Beslutningen ble ikke registrert. {problem}
        </p>
      )}

      <button disabled={submitting} type="submit">
        {submitting ? 'Registrerer …' : 'Registrer beslutningen'}
      </button>
    </form>
  )
}

// ----------------------------------------------------------------------------
// Selve flaten
// ----------------------------------------------------------------------------

function ReviewWorkspaceView({
  workspace,
  onRegistered,
}: {
  readonly workspace: ClaimReviewWorkspace
  readonly onRegistered: () => void
}) {
  const { revision } = workspace
  const { dossier } = revision
  const isOwnRevision = dossier.createdByActorId === workspace.reviewerActorId

  return (
    <>
      <PublicationGatePanel
        gate={revision.publicationGate}
        isPublished={revision.isPublishedRevision}
      />

      <ClaimStatementPanel revision={dossier} />

      <section className="review-panel">
        <h3>{`Evidensgrunnlaget (${String(dossier.links.length)} lenker)`}</h3>
        <p className="review-panel__lead">
          Hele evidenssettet, også lenkene som motsier påstanden. Kontrollen din må dekke alle.
        </p>
        {dossier.links.map((link) => (
          <EvidenceLinkPanel key={link.claimEvidenceLinkId} link={link} />
        ))}
      </section>

      <UnlinkedEvidencePanel revision={dossier} />
      <EvidenceAssessmentPanel assessment={revision.evidenceAssessment} />
      <VerificationHistoryPanel
        currentId={revision.currentClaimVerificationId}
        records={revision.claimVerifications}
      />
      <DecisionHistoryPanel
        currentId={revision.currentReviewDecisionId}
        records={revision.reviewDecisions}
      />

      {isOwnRevision ? (
        <div className="knowledge-notice knowledge-notice--absence" role="note">
          <p className="knowledge-notice__lead">
            Du har selv formulert denne revisjonen, og kan derfor verken kontrollere eller godkjenne
            den.
          </p>
          <p className="knowledge-notice__caveat">
            Generering og kontroll skal være atskilte operasjoner, og den som godkjenner kan ikke
            være den som skrev. En annen kvalifisert reviewer må gjøre begge stegene.
          </p>
        </div>
      ) : (
        <>
          <ClaimVerificationForm onRegistered={onRegistered} workspace={workspace} />
          <PublicationApprovalForm onRegistered={onRegistered} workspace={workspace} />
        </>
      )}
    </>
  )
}

function ClaimReviewFetch({
  claimRevisionId,
  onRegistered,
}: {
  readonly claimRevisionId: Uuid
  readonly onRegistered: () => void
}) {
  const query = useCallback(
    (client: Parameters<typeof fetchClaimReview>[0]) => fetchClaimReview(client, claimRevisionId),
    [claimRevisionId],
  )
  const review = useReadModel(query)

  switch (review.status) {
    case 'loading':
      return (
        <p
          className="knowledge-notice knowledge-notice--loading"
          aria-busy="true"
          aria-live="polite"
        >
          Henter grunnlaget …
        </p>
      )
    case 'error':
      return (
        <div className="knowledge-notice knowledge-notice--error" role="alert">
          <p className="knowledge-notice__lead">
            Antidep fikk ikke hentet grunnlaget. Dette er en teknisk feil, ikke et svar om at
            påstanden ikke kan publiseres — grunnlaget under er ufullstendig eller helt fraværende.
          </p>
          <p className="knowledge-notice__detail">Teknisk årsak: {review.message}</p>
          <p className="knowledge-notice__caveat">
            Mangler kontoen din reviewer-rollen for dette innholdsområdet, står grunnen i teksten
            over. <Link to={accessPath()}>Se «Min tilgang»</Link>.
          </p>
        </div>
      )
    case 'ok':
      return <ReviewWorkspaceView onRegistered={onRegistered} workspace={review.workspace} />
  }
}

/**
 * Henter grunnlaget på nytt etter hver registrering.
 *
 * Både beslutningshistorikken og publiseringsgatens svar endrer seg av en
 * registrering, og en flate som fortsatte å vise det forrige svaret, ville vist
 * en blokkering som ikke lenger gjelder — eller skjult en som nettopp oppstod.
 *
 * Ny henting utløses ved å montere hentekomponenten på nytt (`key`), ikke ved å
 * legge en teller i spørringens avhengigheter. Det tømmer samtidig skjemaene,
 * som er riktig: feltene beskrev vurderingen som nå er registrert, og en
 * gjenstående utfylling ville sett ut som en påbegynt ny vurdering.
 */
function ClaimReviewLookup({ claimRevisionId }: { readonly claimRevisionId: Uuid }) {
  const [reloadToken, setReloadToken] = useState(0)
  return (
    <ClaimReviewFetch
      claimRevisionId={claimRevisionId}
      key={reloadToken}
      onRegistered={() => setReloadToken((token) => token + 1)}
    />
  )
}

function ClaimReviewBody({
  authState,
  claimRevisionId,
}: {
  readonly authState: AuthSessionState
  readonly claimRevisionId: string | undefined
}) {
  if (claimRevisionId === undefined) {
    return (
      <div className="knowledge-notice knowledge-notice--absence" role="note">
        <p className="knowledge-notice__lead">Adressen peker ikke på en påstandsrevisjon.</p>
        <p className="knowledge-notice__caveat">
          <Link to={reviewQueuePath()}>Gå til reviewkøen</Link> og velg en revisjon derfra.
        </p>
      </div>
    )
  }
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
      return <ClaimReviewLookup claimRevisionId={claimRevisionId} key={authState.userId} />
  }
}

export function ClaimReviewPage() {
  usePageTitle('Faglig vurdering av påstand')
  const authState = useAuthSession()
  const { claimRevisionId } = useParams()

  return (
    <>
      <p className="page-kicker">
        <Link to={reviewQueuePath()}>Review</Link>
      </p>
      <h2>Faglig vurdering av påstand</h2>
      <ClaimReviewBody authState={authState} claimRevisionId={claimRevisionId} />
    </>
  )
}
