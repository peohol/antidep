// ============================================================================
// Kontrolløkten for én påstandsrevisjon — `/review/:claimRevisionId`
//
// Hele den menneskelige kjeden i én sammenhengende flyt, ett spørsmål om gangen:
//
//   1. hvilken påstand som skal kontrolleres
//   2. hvilken tilgang kontrolløren faktisk har til hver kilde
//   3. hvert ekstraksjonsfelt mot kilden, ett av gangen
//   4. påstanden mot det ferdig kontrollerte grunnlaget
//   5. den eksplisitte publiseringsbeslutningen
//   6. publiseringen, når gaten tillater den
//
// ----------------------------------------------------------------------------
// Fire beslutningsobjekter, fortsatt fire
//
// Økten er én arbeidsflyt, men den skriver de samme fire radene i de samme fire
// tabellene, gjennom de samme fire skriveveiene, hver med sin egen knapp:
// ekstraksjonskontrollen (G5), claim-kontrollen (G9), publiseringsgodkjenningen
// (G11) og publiseringen. Ingenting er slått sammen, og ingen rad skrives uten
// at kontrolløren har trykket på noe som sier hva som blir registrert.
//
// ----------------------------------------------------------------------------
// To lesekall, ikke ett nytt
//
// Grunnlaget hentes med `api.claim_review_workspace(uuid)` og — for hver lenket
// ekstraksjon — `api.extraction_review_workspace(uuid)`. Begge finnes fra før og
// er de samme flatene de to skriveveiene forventer, med avtrykk, feltdekning og
// forankring. En ny samlefunksjon ville vært en tredje formulering av det samme
// grunnlaget, og da kunne økten og skriveveiene kontrollert hvert sitt bilde.
//
// ----------------------------------------------------------------------------
// Endret grunnlag rammer det som faktisk er endret
//
// Etter hvert forsøk hentes grunnlaget på nytt, og svarene på de stegene som nå
// viser noe annet, nullstilles — bare de. Garantien ligger fortsatt i databasen:
// `workflow.assert_extraction_unchanged(...)` og
// `workflow.assert_evidence_set_unchanged(...)` avviser en registrering der noe
// er endret, under radlåsen.
// ============================================================================

import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router'
import { ControlWizard, type WizardStep } from '../../components/ControlWizard'
import { ReviewTechnicalDetails } from '../../components/ReviewDossier'
import { ExtractionTechnicalDetails } from '../../components/ExtractionDossier'
import { SourceAccessCaveat } from '../../components/SourceAccessCaveat'
import {
  buildExtractionSteps,
  derivedExtractionFor,
} from '../../components/extraction-control-steps'
import {
  answeredLinksFor,
  approvalRationale,
  buildClaimSteps,
  derivedClaimFor,
  emptyClaimSessionState,
  publicationReason,
  type ClaimSessionHandlers,
  type ClaimSessionState,
} from '../../components/claim-control-steps'
import {
  checkResultFor,
  claimTally,
  emptyExtractionSessionState,
  extractionTally,
  pruneExtractionSession,
  retainAnswers,
  type ControlAnswer,
  type ControlTally,
  type ExtractionSessionState,
} from '../../lib/control-session'
import {
  checkpointStepId,
  claimStepBasis,
  extractionStepBasis,
  fieldStepId,
  linkStepId,
  sourceAccessStepId,
} from '../../lib/control-steps'
import { fetchExtractionReview, uncoveredCheckFields } from '../../lib/extraction-review'
import { fetchClaimReview } from '../../lib/review-workspace'
import { publishClaimRevision } from '../../lib/publish-claim-revision'
import { registerHumanClaimVerification } from '../../lib/register-human-claim-verification'
import { registerHumanExtractionVerification } from '../../lib/register-human-extraction-verification'
import { registerPublicationApproval } from '../../lib/register-publication-approval'
import {
  extractionSessionHandlers,
  type ExtractionSessionUpdate,
} from '../extraction-session-handlers'
import { useAntidepClient } from '../antidep-client'
import { useAuthSession, type AuthSessionState } from '../use-auth-session'
import { usePageTitle } from '../use-page-title'
import { accessPath, claimReviewPath, reviewQueuePath } from '../routes'
import type { ExtractionReviewItem } from '../../lib/extraction-review'
import type { ClaimReviewWorkspace } from '../../lib/review-workspace'
import type { AntidepClient } from '../../lib/supabase'
import type { Uuid } from '../../types/api'

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

/** Grunnlaget økten arbeider fra: påstanden, og ekstraksjonen bak hver lenke. */
interface SessionData {
  readonly workspace: ClaimReviewWorkspace
  readonly extractions: Readonly<Record<string, ExtractionReviewItem>>
  /** Lenker der ekstraksjonsgrunnlaget ikke lot seg hente. Aldri stilltiende tomt. */
  readonly extractionProblems: Readonly<Record<string, string>>
  /** Avtrykket av det stegene viser nå. Sendes inn igjen ved neste henting. */
  readonly basis: Readonly<Record<string, string>>
}

type Loaded =
  | { readonly status: 'loading' }
  | { readonly status: 'error'; readonly message: string }
  | { readonly status: 'ok'; readonly data: SessionData }

/** Summen av delkontroller i hele økten, ekstraksjon og påstand under ett. */
function sessionTallyFor(
  data: SessionData,
  extractionSessions: Readonly<Record<string, ExtractionSessionState>>,
  claimSession: ClaimSessionState,
  sourceAccessFor: (evidenceItemId: string) => string | null,
): ControlTally {
  const claimCounts = claimTally(
    claimSession.checkpoints,
    answeredLinksFor(data.workspace.revision, claimSession, sourceAccessFor),
  )
  let total = claimCounts.total
  let answered = claimCounts.answered
  let confirmed = claimCounts.confirmed
  let deviations = claimCounts.deviations
  let unresolved = claimCounts.unresolved
  for (const [evidenceItemId, item] of Object.entries(data.extractions)) {
    const state = extractionSessions[evidenceItemId] ?? emptyExtractionSessionState()
    const counts = extractionTally(item.dossier.semanticCheckFields, state.fields)
    total += counts.total
    answered += counts.answered
    confirmed += counts.confirmed
    deviations += counts.deviations
    unresolved += counts.unresolved
  }
  return { total, answered, confirmed, deviations, unresolved }
}

function ClaimControlSession({ claimRevisionId }: { readonly claimRevisionId: Uuid }) {
  const availability = useAntidepClient()
  const client = availability.status === 'ready' ? availability.client : null
  const [loaded, setLoaded] = useState<Loaded>({ status: 'loading' })
  const [extractionSessions, setExtractionSessions] = useState<
    Readonly<Record<string, ExtractionSessionState>>
  >({})
  const [claimSession, setClaimSession] = useState<ClaimSessionState>(emptyClaimSessionState)
  const [staleSteps, setStaleSteps] = useState(0)

  const load = useCallback(
    async (target: AntidepClient, previousBasis: Readonly<Record<string, string>>) => {
      const review = await fetchClaimReview(target, claimRevisionId)
      if (review.status === 'error') {
        setLoaded({ status: 'error', message: review.message })
        return
      }
      const links = review.workspace.revision.dossier.links
      const results = await Promise.all(
        links.map(async (link) => ({
          evidenceItemId: link.evidenceItem.evidenceItemId,
          result: await fetchExtractionReview(target, link.evidenceItem.evidenceItemId),
        })),
      )
      const extractions: Record<string, ExtractionReviewItem> = {}
      const extractionProblems: Record<string, string> = {}
      for (const entry of results) {
        if (entry.result.status === 'ok') {
          extractions[entry.evidenceItemId] = entry.result.workspace.item
        } else {
          extractionProblems[entry.evidenceItemId] = entry.result.message
        }
      }

      const nextBasis: Record<string, string> = {
        ...claimStepBasis(review.workspace.revision.dossier),
      }
      for (const item of Object.values(extractions)) {
        Object.assign(nextBasis, extractionStepBasis(item))
      }

      let dropped = 0
      setExtractionSessions((current) => {
        const next: Record<string, ExtractionSessionState> = {}
        for (const [evidenceItemId, item] of Object.entries(extractions)) {
          const state = current[evidenceItemId] ?? emptyExtractionSessionState()
          const pruned = pruneExtractionSession({
            state,
            semanticFields: item.dossier.semanticCheckFields,
            sourceAccessStepId: sourceAccessStepId(evidenceItemId),
            fieldStepIdFor: (field) => fieldStepId(evidenceItemId, field),
            previousBasis,
            nextBasis,
          })
          dropped +=
            Object.keys(state.fields).length -
            Object.keys(pruned.fields).length +
            (state.sourceAccess !== null && pruned.sourceAccess === null ? 1 : 0)
          next[evidenceItemId] = pruned
        }
        return next
      })

      setClaimSession((current) => {
        const checkpoints = retainAnswers(
          current.checkpoints,
          previousBasis,
          nextBasis,
          checkpointStepId,
        )
        const linkAnswers = retainAnswers(current.links, previousBasis, nextBasis, linkStepId)
        dropped += checkpoints.dropped.length + linkAnswers.dropped.length
        return {
          ...current,
          checkpoints: checkpoints.kept,
          links: linkAnswers.kept,
          savingClaim: false,
          savingDecision: false,
          publishing: false,
        }
      })

      // Første henting har ingen tidligere avtrykk, og da er «nullstilt» ikke en
      // opplysning: ingenting var besvart.
      setStaleSteps(Object.keys(previousBasis).length === 0 ? 0 : dropped)
      setLoaded({
        status: 'ok',
        data: { workspace: review.workspace, extractions, extractionProblems, basis: nextBasis },
      })
    },
    [claimRevisionId],
  )

  useEffect(() => {
    if (client === null) {
      return
    }
    void (async () => {
      await load(client, {})
    })()
  }, [client, load])

  const updateExtraction: ExtractionSessionUpdate = (evidenceItemId, change) => {
    setExtractionSessions((current) => ({
      ...current,
      [evidenceItemId]: change(current[evidenceItemId] ?? emptyExtractionSessionState()),
    }))
  }

  function sourceAccessFor(evidenceItemId: string): string | null {
    return extractionSessions[evidenceItemId]?.sourceAccess ?? null
  }

  const extractionHandlers = extractionSessionHandlers(updateExtraction, (evidenceItemId) => {
    if (client === null || loaded.status !== 'ok') {
      return
    }
    const item = loaded.data.extractions[evidenceItemId]
    const state = extractionSessions[evidenceItemId]
    if (item === undefined || state === undefined) {
      return
    }
    const basis = loaded.data.basis
    const derived = derivedExtractionFor(item, state)
    updateExtraction(evidenceItemId, (current) => ({ ...current, saving: true, problem: null }))
    void (async () => {
      const result = await registerHumanExtractionVerification(client, {
        evidenceItemId,
        seenExtractionDigest: item.extractionDigest,
        outcome: derived.outcome,
        sourceAccess: state.sourceAccess ?? 'derived_summary',
        checkedFields: derived.checkedFields,
        rationale: derived.rationale,
        findings: derived.findings,
      })
      updateExtraction(evidenceItemId, (current) => ({
        ...current,
        saving: false,
        problem: result.status === 'error' ? result.message : null,
        savedVerificationId:
          result.status === 'ok' ? result.evidenceVerificationId : current.savedVerificationId,
      }))
      await load(client, basis)
    })()
  })

  const claimHandlers: ClaimSessionHandlers = {
    onStart: () => setClaimSession((current) => ({ ...current, started: true })),
    onCheckpoint: (key, answer) =>
      setClaimSession((current) => ({
        ...current,
        checkpoints: {
          ...current.checkpoints,
          [key]: { answer, note: current.checkpoints[key]?.note ?? '' },
        },
      })),
    onCheckpointNote: (key, note) =>
      setClaimSession((current) => ({
        ...current,
        checkpoints: {
          ...current.checkpoints,
          [key]: {
            answer: current.checkpoints[key]?.answer ?? ('cannot_determine' as ControlAnswer),
            note,
          },
        },
      })),
    onLink: (linkId, answer) =>
      setClaimSession((current) => ({
        ...current,
        links: { ...current.links, [linkId]: { answer, note: current.links[linkId]?.note ?? '' } },
      })),
    onLinkNote: (linkId, note) =>
      setClaimSession((current) => ({
        ...current,
        links: {
          ...current.links,
          [linkId]: {
            answer: current.links[linkId]?.answer ?? ('cannot_determine' as ControlAnswer),
            note,
          },
        },
      })),
    onSaveClaim: () => {
      if (client === null || loaded.status !== 'ok') {
        return
      }
      const { revision } = loaded.data.workspace
      const basis = loaded.data.basis
      const derived = derivedClaimFor(revision, claimSession, sourceAccessFor)
      const answered = answeredLinksFor(revision, claimSession, sourceAccessFor)
      setClaimSession((current) => ({ ...current, savingClaim: true, claimProblem: null }))
      void (async () => {
        const result = await registerHumanClaimVerification(client, {
          claimRevisionId: revision.dossier.claimRevisionId,
          seenEvidenceSetDigest: revision.dossier.evidenceSetDigest,
          outcome: derived.outcome,
          sourceSupport: checkResultFor(claimSession.checkpoints['sourceSupport']?.answer),
          populationMatch: checkResultFor(claimSession.checkpoints['populationMatch']?.answer),
          comparatorMatch: checkResultFor(claimSession.checkpoints['comparatorMatch']?.answer),
          timeframeMatch: checkResultFor(claimSession.checkpoints['timeframeMatch']?.answer),
          directionAndMagnitude: checkResultFor(
            claimSession.checkpoints['directionAndMagnitude']?.answer,
          ),
          qualifiersComplete: checkResultFor(
            claimSession.checkpoints['qualifiersComplete']?.answer,
          ),
          contradictoryEvidenceRepresented: checkResultFor(
            claimSession.checkpoints['contradictoryEvidenceRepresented']?.answer,
          ),
          citations: revision.dossier.links.map((link) => {
            const entry = answered.find(
              (candidate) => candidate.claimEvidenceLinkId === link.claimEvidenceLinkId,
            )
            const access = entry?.sourceAccess ?? 'derived_summary'
            const version = link.evidenceItem.sourceVersion
            // Adressen og fingeravtrykket hører sammen: databasen krever at de
            // er begge satt eller begge tomme, og et sporet besøk uten
            // fingeravtrykk er ikke en etterprøvbar representasjon (§74.32).
            const representable =
              access !== 'derived_summary' && version !== null && version.contentHash !== null
            const relationshipSupported = checkResultFor(entry?.answer)
            return {
              claimEvidenceLinkId: link.claimEvidenceLinkId,
              sourceAccess: access,
              sourceVersionId: representable ? version.sourceVersionId : null,
              checkedContentHash: representable ? version.contentHash : null,
              relationshipSupported,
              finding:
                relationshipSupported === 'ok'
                  ? null
                  : entry !== undefined && entry.note.trim().length > 0
                    ? entry.note.trim()
                    : relationshipSupported === 'deviation'
                      ? 'Kontrolløren fant et avvik uten å beskrive det nærmere.'
                      : 'Lot seg ikke avgjøre mot det registrerte grunnlaget.',
            }
          }),
          rationale: derived.rationale,
          findings: derived.findings,
        })
        setClaimSession((current) => ({
          ...current,
          savingClaim: false,
          claimProblem: result.status === 'error' ? result.message : null,
          savedClaimVerificationId:
            result.status === 'ok' ? result.claimVerificationId : current.savedClaimVerificationId,
        }))
        await load(client, basis)
      })()
    },
    onDecision: (decision) => setClaimSession((current) => ({ ...current, decision })),
    onDecisionRationale: (rationale) =>
      setClaimSession((current) => ({ ...current, decisionRationale: rationale })),
    onSaveDecision: () => {
      if (client === null || loaded.status !== 'ok' || claimSession.decision === null) {
        return
      }
      const { revision } = loaded.data.workspace
      const basis = loaded.data.basis
      const decision = claimSession.decision
      const tally = sessionTallyFor(loaded.data, extractionSessions, claimSession, sourceAccessFor)
      const rationale =
        decision === 'approved' ? approvalRationale(tally) : claimSession.decisionRationale.trim()
      setClaimSession((current) => ({ ...current, savingDecision: true, decisionProblem: null }))
      void (async () => {
        const result = await registerPublicationApproval(client, {
          claimRevisionId: revision.dossier.claimRevisionId,
          seenEvidenceSetDigest: revision.dossier.evidenceSetDigest,
          decision,
          rationale,
        })
        setClaimSession((current) => ({
          ...current,
          savingDecision: false,
          decisionProblem: result.status === 'error' ? result.message : null,
          savedDecisionId:
            result.status === 'ok' ? result.reviewDecisionId : current.savedDecisionId,
        }))
        await load(client, basis)
      })()
    },
    onPublish: () => {
      if (client === null || loaded.status !== 'ok') {
        return
      }
      const { revision } = loaded.data.workspace
      const basis = loaded.data.basis
      setClaimSession((current) => ({ ...current, publishing: true, publishProblem: null }))
      void (async () => {
        const result = await publishClaimRevision(client, {
          claimRevisionId: revision.dossier.claimRevisionId,
          reason: publicationReason(revision),
        })
        setClaimSession((current) => ({
          ...current,
          publishing: false,
          publishProblem: result.status === 'error' ? result.message : null,
          publishedEventId:
            result.status === 'ok' ? result.publicationEventId : current.publishedEventId,
        }))
        await load(client, basis)
      })()
    },
  }

  switch (loaded.status) {
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
            påstanden ikke kan publiseres.
          </p>
          <p className="knowledge-notice__detail">Teknisk årsak: {loaded.message}</p>
          <p className="knowledge-notice__caveat">
            Mangler kontoen din reviewer-rollen for dette innholdsområdet, står grunnen i teksten
            over. <Link to={accessPath()}>Se «Min tilgang»</Link>.
          </p>
        </div>
      )
    case 'ok': {
      const { data } = loaded
      const { revision, reviewerActorId } = data.workspace
      const isOwnRevision = revision.dossier.createdByActorId === reviewerActorId
      const tally = sessionTallyFor(data, extractionSessions, claimSession, sourceAccessFor)

      const steps: WizardStep[] = []
      const claimSteps = buildClaimSteps({
        revision,
        isOwnRevision,
        state: claimSession,
        handlers: claimHandlers,
        sourceAccessFor,
        sessionTally: tally,
      })
      // Innledningen først, så kildegrunnlaget, så resten av påstandskontrollen.
      steps.push(...claimSteps.slice(0, 1))

      if (claimSession.started && !isOwnRevision) {
        revision.dossier.links.forEach((link, index) => {
          const evidenceItemId = link.evidenceItem.evidenceItemId
          const item = data.extractions[evidenceItemId]
          if (item === undefined) {
            steps.push({
              id: `extraction-problem:${evidenceItemId}`,
              title: `Kildegrunnlag ${String(index + 1)}: grunnlaget lot seg ikke hente`,
              answerSummary: 'Kan ikke kontrolleres',
              isComplete: true,
              countsTowardProgress: false,
              content: (
                <div className="knowledge-notice knowledge-notice--error" role="alert">
                  <p className="knowledge-notice__lead">
                    Antidep fikk ikke hentet ekstraksjonsgrunnlaget for{' '}
                    {link.evidenceItem.sourceTitle}.
                  </p>
                  <p className="knowledge-notice__detail">
                    Teknisk årsak: {data.extractionProblems[evidenceItemId] ?? 'ukjent'}
                  </p>
                </div>
              ),
            })
            return
          }
          steps.push(
            ...buildExtractionSteps({
              item,
              reviewerActorId,
              state: extractionSessions[evidenceItemId] ?? emptyExtractionSessionState(),
              handlers: extractionHandlers,
              includeFieldSteps: uncoveredCheckFields(item).length > 0,
              titlePrefix: `Kilde ${String(index + 1)}:`,
            }),
          )
        })
      }
      if (claimSession.started) {
        // For en egen påstand er resten av listen den ene merknaden om hvorfor
        // økten stopper her; den skal vises, ikke falle bort.
        steps.push(...claimSteps.slice(1))
      }

      return (
        <>
          {staleSteps > 0 ? (
            <div className="knowledge-notice knowledge-notice--absence" role="alert">
              <p className="knowledge-notice__lead">
                Grunnlaget er endret mens du arbeidet, og{' '}
                {`${String(staleSteps)} av delkontrollene dine gjelder ikke lenger.`}
              </p>
              <p className="knowledge-notice__caveat">
                Bare de delkontrollene som viser noe annet enn før, er nullstilt. Resten av arbeidet
                ditt står.
              </p>
            </div>
          ) : null}
          <SourceAccessCaveat
            sources={Object.values(data.extractions)
              .filter(
                (item) =>
                  extractionSessions[item.dossier.evidenceItemId]?.sourceAccess ===
                  'derived_summary',
              )
              .map((item) => item.dossier.sourceTitle)}
          />
          <ControlWizard progressLabel="Delkontroll" steps={steps} />
          <ReviewTechnicalDetails revision={revision} />
          {Object.values(data.extractions).map((item) => (
            <ExtractionTechnicalDetails
              claimHrefFor={(linked) => claimReviewPath(linked.claimRevisionId)}
              item={item}
              key={item.dossier.evidenceItemId}
            />
          ))}
        </>
      )
    }
  }
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
      return <ClaimControlSession claimRevisionId={claimRevisionId} key={authState.userId} />
  }
}

export function ClaimReviewPage() {
  usePageTitle('Kontroll av påstand')
  const authState = useAuthSession()
  const { claimRevisionId } = useParams()

  return (
    <>
      <p className="page-kicker">
        <Link to={reviewQueuePath()}>Kontroll</Link>
      </p>
      <h2>Kontroll av påstand</h2>
      <ClaimReviewBody authState={authState} claimRevisionId={claimRevisionId} />
    </>
  )
}
