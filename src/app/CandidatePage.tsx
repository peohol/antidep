// ============================================================================
// Kandidatflaten: ett forseglet innhold, lest én gang, sluttkontrollert der —
// og publisert som en egen, senere handling
//
// Rendereren er delt med klinikerflaten (`SealedContentView`), fordi
// ANTIDEP_CONSTITUTION.md krever at fagpersonen vurderer det ferdige produktet i
// **samme visning** som klinikeren får. To komponenter ville vært en godkjenning
// av noe annet enn det som vises, uansett hvor like de så ut.
//
// ----------------------------------------------------------------------------
// Sluttkontroll og publisering er to handlinger, og de ser ut som to
//
// De står i hver sin seksjon, med hver sin knapp og hver sin begrunnelse. Det er
// ikke en presentasjonsdetalj: de krever forskjellige mandater — reviewer for
// sluttkontrollen, publisher for publiseringen — og databasen avgjør begge på
// hvert sitt kall. Flaten viser publiseringen for alle, og lar avvisningen komme
// derfra den faktisk kommer fra. En knapp som var skjult for noen, ville vært en
// «du har lov»-verdi utledet i nettleseren, og den ville kunnet ta feil.
//
// Publiseringen sender med det avtrykket flaten faktisk viste. Databasen stoler
// ikke på det: den krever at det er kandidatens eget *og* at kandidaten fortsatt
// er den gjeldende for revisjonen sin.
//
// Utrygg inndata: innholdet er data. React escaper all tekst, og ingenting her
// tolker en verdi som markup.
// ============================================================================

import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Link } from 'react-router'

import { canBeFinalControlled, type CandidateView } from '../lib/candidate-view'
import type { PublicationOutcome } from '../lib/published-claim'
import type { CandidateGateway } from './candidate-gateway'
import { publishedClaimPath } from './routes'
import { SealedContentView } from './SealedContentView'

/** Utfallene en sluttkontroll kan ha (migrasjon 009d). */
const DECISIONS = [
  { value: 'approved', label: 'Godkjent' },
  { value: 'changes_requested', label: 'Endring kreves' },
  { value: 'rejected', label: 'Avvist' },
] as const

/** Den gjeldende sluttkontrollen: den som ble registrert sist. */
function currentDecision(view: CandidateView): string | null {
  return view.finalControls[0]?.decision ?? null
}

export interface CandidatePageProps {
  readonly candidateId: string
  readonly gateway: CandidateGateway
}

export function CandidatePage({ candidateId, gateway }: CandidatePageProps): React.JSX.Element {
  const [view, setView] = useState<CandidateView | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [decision, setDecision] = useState<string>('approved')
  const [rationale, setRationale] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [publishReason, setPublishReason] = useState('')
  const [publishing, setPublishing] = useState(false)
  const [published, setPublished] = useState<PublicationOutcome | null>(null)
  const [publishError, setPublishError] = useState<string | null>(null)

  const load = useCallback(() => {
    let cancelled = false
    gateway
      .read(candidateId)
      .then((next) => {
        if (!cancelled) {
          setView(next)
          setError(null)
        }
      })
      .catch((cause: unknown) => {
        if (!cancelled) {
          setView(null)
          setError(cause instanceof Error ? cause.message : String(cause))
        }
      })
    return () => {
      cancelled = true
    }
  }, [candidateId, gateway])

  useEffect(load, [load])

  const submit = (event: FormEvent): void => {
    event.preventDefault()
    if (view === null || submitting) {
      return
    }
    setSubmitting(true)
    gateway
      .recordFinalControl({
        candidateId: view.candidateId,
        // Avtrykket flaten faktisk viste, uendret. Se `candidate-gateway.ts`.
        seenCandidateDigest: view.candidateDigest,
        decision,
        rationale,
      })
      .then(() => {
        setRationale('')
        setError(null)
        load()
      })
      .catch((cause: unknown) => {
        setError(cause instanceof Error ? cause.message : String(cause))
      })
      .finally(() => {
        setSubmitting(false)
      })
  }

  const publish = (event: FormEvent): void => {
    event.preventDefault()
    if (view === null || publishing) {
      return
    }
    setPublishing(true)
    gateway
      .publish({
        candidateId: view.candidateId,
        seenCandidateDigest: view.candidateDigest,
        reason: publishReason,
      })
      .then((outcome) => {
        setPublished(outcome)
        setPublishReason('')
        setPublishError(null)
        load()
      })
      .catch((cause: unknown) => {
        setPublished(null)
        setPublishError(cause instanceof Error ? cause.message : String(cause))
      })
      .finally(() => {
        setPublishing(false)
      })
  }

  if (error !== null && view === null) {
    return (
      <main id="hovedinnhold">
        <p className="eyebrow">Kandidat</p>
        <h1>Kandidaten kunne ikke vises</h1>
        <p className="notice">{error}</p>
      </main>
    )
  }

  if (view === null) {
    return (
      <main id="hovedinnhold">
        <p className="eyebrow">Kandidat</p>
        <h1>Henter kandidaten …</h1>
      </main>
    )
  }

  const controllable = canBeFinalControlled(view)
  const approved = currentDecision(view) === 'approved'

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Kandidat til sluttkontroll</p>
      <h1>{view.claim.statement}</h1>
      <p className="notice">
        Eksperimentelt utkast. Sluttkontrollen under publiserer ingenting: publiseringen er en egen
        handling, med et annet mandat.
      </p>

      <SealedContentView
        content={view}
        sealNote="Sluttkontrollen og publiseringen under gjelder hele dette innholdet, ordrett. Avsnittene over er den lesbare visningen av det, ikke en avgrensning av hva som attesteres."
      />

      <section aria-labelledby="kontroll-title">
        <h2 id="kontroll-title">Sluttkontroll</h2>
        <p>
          Kandidatavtrykk: <code>{view.candidateDigest}</code>
        </p>
        {view.finalControls.length === 0 ? (
          <p>Ingen sluttkontroll er registrert for denne kandidaten.</p>
        ) : (
          <ul>
            {view.finalControls.map((control) => (
              <li key={`${control.decidedAt}:${control.reviewer}`}>
                {control.decision} — {control.reviewer}, {control.decidedAt}: {control.rationale}
              </li>
            ))}
          </ul>
        )}

        {controllable ? (
          <form onSubmit={submit}>
            <p>
              <label htmlFor="beslutning">Beslutning</label>{' '}
              <select
                id="beslutning"
                onChange={(event) => {
                  setDecision(event.target.value)
                }}
                value={decision}
              >
                {DECISIONS.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </select>
            </p>
            <p>
              <label htmlFor="begrunnelse">Begrunnelse</label>
              <br />
              <textarea
                id="begrunnelse"
                onChange={(event) => {
                  setRationale(event.target.value)
                }}
                required
                rows={4}
                value={rationale}
              />
            </p>
            <button disabled={submitting || rationale.trim().length === 0} type="submit">
              Registrer sluttkontroll
            </button>
          </form>
        ) : (
          <p className="notice">
            Grunnlaget kandidaten ble forseglet av, er endret siden den ble bygget. Den kan ikke
            sluttkontrolleres før den er bygget på nytt: en godkjenning av et innhold som ikke
            lenger er det som ligger her, er ikke en godkjenning av noe.
          </p>
        )}
        {error === null ? null : <p className="notice">{error}</p>}
      </section>

      <section aria-labelledby="publisering-title">
        <h2 id="publisering-title">Publisering</h2>
        <p>
          Publisering er en egen og eksplisitt handling etter sluttkontrollen, og krever
          publisher-mandat. Den gjelder nøyaktig dette avtrykket.
        </p>
        {approved ? null : (
          <p className="notice">
            Den gjeldende sluttkontrollen er ikke en godkjenning. Databasen avviser en publisering
            av dette innholdet.
          </p>
        )}
        {controllable ? null : (
          <p className="notice">
            Kandidaten er ikke lenger den gjeldende for påstandsrevisjonen sin, og kan ikke
            publiseres. Bygg innholdet på nytt og få den nye kandidaten sluttkontrollert.
          </p>
        )}
        <form onSubmit={publish}>
          <p>
            <label htmlFor="publiseringsbegrunnelse">Begrunnelse for publiseringen</label>
            <br />
            <textarea
              id="publiseringsbegrunnelse"
              onChange={(event) => {
                setPublishReason(event.target.value)
              }}
              required
              rows={3}
              value={publishReason}
            />
          </p>
          <button disabled={publishing || publishReason.trim().length === 0} type="submit">
            Publiser kandidaten
          </button>
        </form>
        {published === null ? null : (
          <p>
            {published.changed
              ? `Publisert som ${published.event.action}.`
              : 'Dette innholdet var allerede publisert; ingen ny hendelse ble registrert.'}{' '}
            {published.event.claimId === null ? null : (
              <Link to={publishedClaimPath(published.event.claimId)}>Se klinikervisningen</Link>
            )}
          </p>
        )}
        {publishError === null ? null : <p className="notice">{publishError}</p>}
      </section>
    </main>
  )
}
