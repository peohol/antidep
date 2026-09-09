// ============================================================================
// Kildekontroll av ett evidensfunn — `/extraction-review/:evidenceItemId`
//
// En guidet kontrolløkt, ikke et skjema. Kontrolløren får ett spørsmål om
// gangen: først hvilken tilgang hen har til kilden, så ett felt av gangen med
// kildeutdraget ved siden av Antideps tolkning, og til slutt én knapp som
// registrerer kontrollen.
//
// ----------------------------------------------------------------------------
// Ingen samlet utfallsmeny, og ingen retrospektiv fritekst
//
// Utfallet utledes av delsvarene (`control-session.ts`), og begrunnelsen skrives
// deterministisk av de samme svarene. Avvik beskrives der de oppdages, mens
// informasjonen er fersk, og spørres aldri om igjen til slutt.
//
// Databasen er uendret: raden som skrives er den samme
// `workflow.evidence_verifications`-raden, gjennom den samme skriveveien, med de
// samme constraintene som fasit.
//
// ----------------------------------------------------------------------------
// Endret grunnlag rammer det som faktisk er endret
//
// Skriveveien avviser en registrering hvis kildeversjonen, kildens status,
// forankringen eller kontrollhistorikken er endret siden grunnlaget ble hentet.
// Da hentes grunnlaget på nytt, og bare de stegene som nå viser noe annet, må
// besvares om igjen. Resten av arbeidet står.
// ============================================================================

import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router'
import { ControlWizard } from '../../components/ControlWizard'
import {
  buildExtractionSteps,
  derivedExtractionFor,
} from '../../components/extraction-control-steps'
import { ExtractionTechnicalDetails } from '../../components/ExtractionDossier'
import { SourceAccessCaveat } from '../../components/SourceAccessCaveat'
import {
  emptyExtractionSessionState,
  pruneExtractionSession,
  type ExtractionSessionState,
} from '../../lib/control-session'
import { extractionStepBasis, fieldStepId, sourceAccessStepId } from '../../lib/control-steps'
import { fetchExtractionReview, uncoveredCheckFields } from '../../lib/extraction-review'
import { registerHumanExtractionVerification } from '../../lib/register-human-extraction-verification'
import { extractionSessionHandlers } from '../extraction-session-handlers'
import { useAntidepClient } from '../antidep-client'
import { useAuthSession, type AuthSessionState } from '../use-auth-session'
import { usePageTitle } from '../use-page-title'
import { accessPath, claimReviewPath, extractionReviewQueuePath } from '../routes'
import type { ExtractionReviewWorkspace } from '../../lib/extraction-review'
import type { AntidepClient } from '../../lib/supabase'
import type { Uuid } from '../../types/api'

function SignedOutNotice() {
  return (
    <div className="knowledge-notice knowledge-notice--absence" role="note">
      <p className="knowledge-notice__lead">Du må logge inn for å kontrollere et evidensfunn.</p>
      <p className="knowledge-notice__caveat">
        <Link to={accessPath()}>Logg inn under «Min tilgang»</Link>, og kom tilbake hit.
      </p>
    </div>
  )
}

type Loaded =
  | { readonly status: 'loading' }
  | { readonly status: 'error'; readonly message: string }
  | {
      readonly status: 'ok'
      readonly workspace: ExtractionReviewWorkspace
      /** Avtrykket av det stegene viser nå. Sendes inn igjen ved neste henting. */
      readonly basis: Readonly<Record<string, string>>
    }

function ExtractionControlSession({ evidenceItemId }: { readonly evidenceItemId: Uuid }) {
  const availability = useAntidepClient()
  const client = availability.status === 'ready' ? availability.client : null
  const [loaded, setLoaded] = useState<Loaded>({ status: 'loading' })
  // Nøklet på evidensfunnet, som i påstandsøkten: én form for begge flatene, og
  // dermed én oppførsel.
  const [sessions, setSessions] = useState<Readonly<Record<string, ExtractionSessionState>>>({})
  const [staleSteps, setStaleSteps] = useState(0)

  const load = useCallback(
    async (target: AntidepClient, previousBasis: Readonly<Record<string, string>>) => {
      const result = await fetchExtractionReview(target, evidenceItemId)
      if (result.status === 'error') {
        setLoaded({ status: 'error', message: result.message })
        return
      }
      const { item } = result.workspace
      const nextBasis = extractionStepBasis(item)
      setSessions((current) => {
        const state = current[evidenceItemId] ?? emptyExtractionSessionState()
        const pruned = pruneExtractionSession({
          state,
          requiredFields: item.requiredCheckFields,
          sourceAccessStepId: sourceAccessStepId(evidenceItemId),
          fieldStepIdFor: (field) => fieldStepId(evidenceItemId, field),
          previousBasis,
          nextBasis,
        })
        // Første henting har ingen tidligere avtrykk, og da er «nullstilt» ikke
        // en opplysning: ingenting var besvart.
        setStaleSteps(
          Object.keys(previousBasis).length === 0
            ? 0
            : Object.keys(state.fields).length -
                Object.keys(pruned.fields).length +
                (state.sourceAccess !== null && pruned.sourceAccess === null ? 1 : 0),
        )
        return { ...current, [evidenceItemId]: pruned }
      })
      setLoaded({ status: 'ok', workspace: result.workspace, basis: nextBasis })
    },
    [evidenceItemId],
  )

  useEffect(() => {
    if (client === null) {
      return
    }
    void (async () => {
      await load(client, {})
    })()
  }, [client, load])

  const session = sessions[evidenceItemId] ?? emptyExtractionSessionState()

  const handlers = extractionSessionHandlers(
    (id, change) =>
      setSessions((current) => ({
        ...current,
        [id]: change(current[id] ?? emptyExtractionSessionState()),
      })),
    (id) => {
      if (client === null || loaded.status !== 'ok') {
        return
      }
      const { item } = loaded.workspace
      const basis = loaded.basis
      const derived = derivedExtractionFor(item, session)
      setSessions((current) => ({
        ...current,
        [id]: { ...(current[id] ?? emptyExtractionSessionState()), saving: true, problem: null },
      }))
      void (async () => {
        const result = await registerHumanExtractionVerification(client, {
          evidenceItemId: id,
          seenExtractionDigest: item.extractionDigest,
          outcome: derived.outcome,
          sourceAccess: session.sourceAccess ?? 'derived_summary',
          checkedFields: derived.checkedFields,
          rationale: derived.rationale,
          findings: derived.findings,
        })
        setSessions((current) => {
          const previous = current[id] ?? emptyExtractionSessionState()
          return {
            ...current,
            [id]: {
              ...previous,
              saving: false,
              problem: result.status === 'error' ? result.message : null,
              savedVerificationId:
                result.status === 'ok'
                  ? result.evidenceVerificationId
                  : previous.savedVerificationId,
            },
          }
        })
        // Alltid ny henting: både ved suksess (dekningen og avtrykket er
        // endret) og ved avvisning (den kan nettopp skyldes at grunnlaget er
        // endret, og da skal kontrolløren se hva som er nytt).
        await load(client, basis)
      })()
    },
  )

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
            ekstraksjonen er i orden.
          </p>
          <p className="knowledge-notice__detail">Teknisk årsak: {loaded.message}</p>
          <p className="knowledge-notice__caveat">
            Mangler kontoen din reviewer-rollen for dette endepunktet, står grunnen i teksten over.{' '}
            <Link to={accessPath()}>Se «Min tilgang»</Link>.
          </p>
        </div>
      )
    case 'ok': {
      const { item, reviewerActorId } = loaded.workspace
      const steps = buildExtractionSteps({
        item,
        reviewerActorId,
        state: session,
        handlers,
        includeFieldSteps: true,
        titlePrefix: null,
      })
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
            sources={session.sourceAccess === 'derived_summary' ? [item.dossier.sourceTitle] : []}
          />
          <ControlWizard progressLabel="Delkontroll" steps={steps} />
          <ExtractionTechnicalDetails
            claimHrefFor={(linked) => claimReviewPath(linked.claimRevisionId)}
            item={item}
          />
          {uncoveredCheckFields(item).length === 0 ? (
            <div className="knowledge-notice knowledge-notice--ok" role="note">
              <p className="knowledge-notice__lead">
                Alle feltene dette funnet påstår noe om, er nå kontrollert mot kilden.
              </p>
            </div>
          ) : null}
        </>
      )
    }
  }
}

function ExtractionReviewBody({
  authState,
  evidenceItemId,
}: {
  readonly authState: AuthSessionState
  readonly evidenceItemId: string | undefined
}) {
  if (evidenceItemId === undefined) {
    return (
      <div className="knowledge-notice knowledge-notice--absence" role="note">
        <p className="knowledge-notice__lead">Adressen peker ikke på et evidensfunn.</p>
        <p className="knowledge-notice__caveat">
          <Link to={extractionReviewQueuePath()}>Gå til køen</Link> og velg et funn derfra.
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
      return <ExtractionControlSession evidenceItemId={evidenceItemId} key={authState.userId} />
  }
}

export function ExtractionReviewPage() {
  usePageTitle('Kildekontroll av evidensfunn')
  const authState = useAuthSession()
  const { evidenceItemId } = useParams()

  return (
    <>
      <p className="page-kicker">
        <Link to={extractionReviewQueuePath()}>Kildekontroll</Link>
      </p>
      <h2>Kildekontroll av evidensfunn</h2>
      <ExtractionReviewBody authState={authState} evidenceItemId={evidenceItemId} />
    </>
  )
}
