// ============================================================================
// Klinikerflaten: ett publisert innhold, med proveniensen og historikken
//
// Innholdet er den forseglede raden en navngitt fagperson godkjente, ordrett.
// Det er ikke bygget på nytt av dagens tilstand: en gjenoppbygging ville vist
// noe annet enn det som ble godkjent, og forskjellen mellom «hva sier vi nå» og
// «hva ble godkjent» er nettopp den som må holdes (ANTIDEP_CONSTITUTION.md
// regel 5).
//
// ----------------------------------------------------------------------------
// Tilbaketrekking og rollback står på den samme siden
//
// De er handlinger på det som vises, og de krever publisher-mandat. Databasen
// avgjør retten på hvert kall; flaten viser handlingene og lar avvisningen komme
// derfra den faktisk kommer fra. Rollback peker på en tidligere publisert
// versjon, hentet ut av historikken — ikke på noe kalleren skriver fritt.
//
// Historikken vises alltid, også når ingenting er publisert. En tilbaketrekking
// som ikke vises, er ikke synlig (ANTIDEP_CONSTITUTION.md regel 6).
//
// Utrygg inndata: innholdet er data. React escaper all tekst.
// ============================================================================

import { useCallback, useEffect, useState, type FormEvent } from 'react'

import { rollbackTargets, type PublishedClaimView } from '../lib/published-claim'
import { PUBLICATION_ACTION_LABELS, label } from '../lib/vocabulary-view'
import type { PublicationGateway } from './publication-gateway'
import { SealedContentView } from './SealedContentView'
import { pageMessage } from './gateway'

export interface PublishedClaimPageProps {
  readonly claimId: string
  readonly gateway: PublicationGateway
}

export function PublishedClaimPage({
  claimId,
  gateway,
}: PublishedClaimPageProps): React.JSX.Element {
  const [view, setView] = useState<PublishedClaimView | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [withdrawReason, setWithdrawReason] = useState('')
  const [rollbackReason, setRollbackReason] = useState('')
  const [rollbackTarget, setRollbackTarget] = useState('')
  const [busy, setBusy] = useState(false)

  const load = useCallback(() => {
    let cancelled = false
    gateway
      .readPublished(claimId)
      .then((next) => {
        if (!cancelled) {
          setView(next)
          setError(null)
        }
      })
      .catch((cause: unknown) => {
        if (!cancelled) {
          setView(null)
          setError(pageMessage(cause))
        }
      })
    return () => {
      cancelled = true
    }
  }, [claimId, gateway])

  useEffect(load, [load])

  const run = (work: Promise<unknown>): void => {
    setBusy(true)
    work
      .then(() => {
        setActionError(null)
        setWithdrawReason('')
        setRollbackReason('')
        load()
      })
      .catch((cause: unknown) => {
        setActionError(pageMessage(cause))
      })
      .finally(() => {
        setBusy(false)
      })
  }

  const withdraw = (event: FormEvent): void => {
    event.preventDefault()
    if (busy) {
      return
    }
    run(gateway.withdraw({ claimId, reason: withdrawReason }))
  }

  const rollback = (event: FormEvent): void => {
    event.preventDefault()
    if (view === null || busy) {
      return
    }
    const target = rollbackTargets(view).find(
      (candidate) => candidate.candidateId === rollbackTarget,
    )
    const targetCandidateId = target?.candidateId ?? null
    const seenCandidateDigest = target?.candidateDigest ?? null
    if (targetCandidateId === null || seenCandidateDigest === null) {
      setActionError('Velg en tidligere publisert versjon å gå tilbake til.')
      return
    }
    run(
      gateway.rollback({
        claimId,
        targetCandidateId,
        // Avtrykket flaten faktisk viste, uendret.
        seenCandidateDigest,
        reason: rollbackReason,
      }),
    )
  }

  if (error !== null) {
    return (
      <main id="hovedinnhold">
        <p className="eyebrow">Publisert</p>
        <h1>Innholdet kunne ikke vises</h1>
        <p className="notice">{error}</p>
      </main>
    )
  }

  if (view === null) {
    return (
      <main id="hovedinnhold">
        <p className="eyebrow">Publisert</p>
        <h1>Henter innholdet …</h1>
      </main>
    )
  }

  const targets = rollbackTargets(view)

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">{view.published ? 'Publisert' : 'Ikke publisert'}</p>
      <h1>
        {view.content === null
          ? 'Ingenting er publisert om denne påstanden nå'
          : view.content.claim.statement}
      </h1>

      {view.content === null ? (
        <p className="notice">
          {view.withdrawn
            ? 'Innholdet er trukket tilbake, og presenteres ikke lenger som gjeldende. Historikken under viser hva som ble sagt, av hvem og hvorfor det ble trukket.'
            : 'Ingenting er publisert om denne påstanden. Det er ikke det samme som at ingenting er kontrollert.'}
        </p>
      ) : (
        <>
          <p>
            Sluttkontrollert av {view.finalControl?.reviewer ?? 'ukjent fagperson'}
            {view.finalControl === null ? '' : ` ${view.finalControl.decidedAt}`}. Publisert av{' '}
            {view.publication?.publishedBy ?? 'ukjent'}
            {view.publication === null ? '' : ` ${view.publication.publishedAt}`}.
          </p>
          <p>
            Innholdsavtrykk: <code>{view.candidateDigest}</code>
          </p>
          <SealedContentView
            content={view.content}
            sealNote="Dette er innholdet en navngitt fagperson godkjente, ordrett. Avsnittene over er den lesbare visningen av det."
          />
        </>
      )}

      <section aria-labelledby="historikk-title">
        <h2 id="historikk-title">Publiseringshistorikk</h2>
        {view.history.length === 0 ? (
          <p>Ingen publiseringshendelse er registrert for denne påstanden.</p>
        ) : (
          <ul>
            {view.history.map((event) => (
              <li key={event.publicationEventId}>
                {label(event.action, PUBLICATION_ACTION_LABELS)} — {event.publishedBy},{' '}
                {event.publishedAt}: {event.reason}
                {event.finalControl === null
                  ? ''
                  : ` Sluttkontrollert av ${event.finalControl.reviewer}: ${event.finalControl.rationale}`}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section aria-labelledby="handlinger-title">
        <h2 id="handlinger-title">Tilbaketrekking og rollback</h2>
        <p>
          Begge krever publisher-mandat, og begge er nye hendelser: ingen historikk slettes eller
          skrives om.
        </p>

        <form onSubmit={withdraw}>
          <p>
            <label htmlFor="tilbaketrekking">Begrunnelse for tilbaketrekking</label>
            <br />
            <textarea
              id="tilbaketrekking"
              onChange={(event) => {
                setWithdrawReason(event.target.value)
              }}
              required
              rows={3}
              value={withdrawReason}
            />
          </p>
          <button disabled={busy || withdrawReason.trim().length === 0} type="submit">
            Trekk tilbake
          </button>
        </form>

        {targets.length === 0 ? (
          <p className="notice">Det finnes ingen tidligere publisert versjon å gå tilbake til.</p>
        ) : (
          <form onSubmit={rollback}>
            <p>
              <label htmlFor="rollbackmaal">Gå tilbake til</label>{' '}
              <select
                id="rollbackmaal"
                onChange={(event) => {
                  setRollbackTarget(event.target.value)
                }}
                value={rollbackTarget}
              >
                <option value="">Velg en tidligere publisert versjon</option>
                {targets.map((target) => (
                  <option key={target.publicationEventId} value={target.candidateId ?? ''}>
                    Revisjon {String(target.revisionNumber ?? 0)} — {target.publishedAt}
                  </option>
                ))}
              </select>
            </p>
            <p>
              <label htmlFor="rollbackbegrunnelse">Begrunnelse for rollback</label>
              <br />
              <textarea
                id="rollbackbegrunnelse"
                onChange={(event) => {
                  setRollbackReason(event.target.value)
                }}
                required
                rows={3}
                value={rollbackReason}
              />
            </p>
            <button
              disabled={busy || rollbackReason.trim().length === 0 || rollbackTarget.length === 0}
              type="submit"
            >
              Rull tilbake
            </button>
          </form>
        )}
        {actionError === null ? null : <p className="notice">{actionError}</p>}
      </section>
    </main>
  )
}
