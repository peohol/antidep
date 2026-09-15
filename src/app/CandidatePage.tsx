// ============================================================================
// Klinikerflaten: ett kandidatinnhold, lest én gang, og sluttkontrollert der
//
// ANTIDEP_CONSTITUTION.md krever at fagpersonen vurderer det ferdige produktet
// i **samme visning** som klinikeren får. Det er derfor én komponent og ikke to:
// en egen kontrollflate ville vært en godkjenning av noe annet enn det som
// vises, uansett hvor like de to så ut.
//
// ----------------------------------------------------------------------------
// Hva som vises, og hvorfor akkurat det
//
// Påstanden og usikkerheten står øverst, fordi det er produktet. Deretter
// evidensvurderingen, så kildedekningen, så hvert evidensfunn med sine ordrette
// utdrag. Kildedekningen er ikke en fotnote: den svarer på hvor mye av det
// raden påstår, som faktisk er kontrollert — og et felt som ingen kontroll
// dekker, står navngitt framfor å være utelatt. Et felt som er borte fra
// visningen, leses som et felt uten avvik (ANTIDEP_CONSTITUTION.md regel 4).
//
// ----------------------------------------------------------------------------
// Hva flaten ikke kan
//
// Den publiserer ingenting. Sluttkontrollen registrerer en beslutning, og
// publiseringen er en egen, fortsatt stengt handling. Flaten sier det selv,
// framfor å la fraværet av en knapp være forklaringen.
//
// Utrygg inndata: innholdet er data. React escaper all tekst, og ingenting her
// tolker en verdi som markup.
// ============================================================================

import { useCallback, useEffect, useState, type FormEvent } from 'react'

import {
  canBeFinalControlled,
  coverageRatio,
  uncoveredCheckFields,
  type CandidateEvidence,
  type CandidateView,
} from '../lib/candidate-view'
import type { CandidateGateway } from './candidate-gateway'

/** Utfallene en sluttkontroll kan ha (migrasjon 009d). */
const DECISIONS = [
  { value: 'approved', label: 'Godkjent' },
  { value: 'changes_requested', label: 'Endring kreves' },
  { value: 'rejected', label: 'Avvist' },
] as const

const CERTAINTY_LABELS: Readonly<Record<string, string>> = {
  high: 'høy',
  moderate: 'moderat',
  low: 'lav',
  very_low: 'svært lav',
  no_assessable_evidence: 'ingen vurderbar evidens',
}

/**
 * En vokabularverdi vist på norsk, eller verdien selv.
 *
 * Ukjente verdier vises ordrett framfor å bli borte: en verdi som ikke lar seg
 * oversette, er en eksplisitt ukjent tilstand, ikke et fravær.
 */
function label(value: string, labels: Readonly<Record<string, string>>): string {
  return labels[value] ?? value
}

function EvidenceCard({ evidence }: { readonly evidence: CandidateEvidence }): React.JSX.Element {
  const ratio = coverageRatio(evidence)
  const uncovered = uncoveredCheckFields(evidence)

  return (
    <li>
      <h4>{evidence.sourceTitle}</h4>
      <p>
        {evidence.outcomeDetail} Retning: {evidence.reportedDirection}.
        {evidence.estimate === null
          ? ' Estimat er ikke rapportert.'
          : ` Estimat: ${evidence.estimate}${evidence.estimateUnit === null ? '' : ` ${evidence.estimateUnit}`}.`}
      </p>
      <p>
        Kontrollert: {String(ratio.covered)} av {String(ratio.required)} felter.{' '}
        {evidence.extractionCheckOutcome === null
          ? 'Ingen ekstraksjonskontroll er registrert.'
          : `Siste ekstraksjonskontroll: ${evidence.extractionCheckOutcome}.`}{' '}
        {evidence.groundingMachineProved
          ? 'Maskinbeviset for kildeforankringen gjelder.'
          : 'Maskinbeviset for kildeforankringen gjelder ikke.'}
      </p>
      {uncovered.length === 0 ? null : (
        <p className="notice">Ikke kontrollerte felter: {uncovered.join(', ')}.</p>
      )}
      {evidence.groundings.length === 0 ? (
        <p className="notice">Ingen ordrette utdrag er registrert for dette funnet.</p>
      ) : (
        <ul>
          {evidence.groundings.map((grounding) => (
            <li key={`${grounding.checkField}:${grounding.sourceExcerpt}`}>
              <strong>{grounding.checkField}</strong> ({grounding.sourceLocator}):{' '}
              <q>{grounding.sourceExcerpt}</q>
            </li>
          ))}
        </ul>
      )}
    </li>
  )
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

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Kandidat til sluttkontroll</p>
      <h1>{view.claim.statement}</h1>
      <p className="notice">
        Eksperimentelt utkast. Ikke publisert, og en sluttkontroll her publiserer ingenting.
      </p>

      <section aria-labelledby="paastand-title">
        <h2 id="paastand-title">Påstanden</h2>
        <p className="lead">{view.claim.statement}</p>
        <p>
          Virkestoff: {view.claim.subjectDrug}. Tema: {view.claim.topic}.{' '}
          {view.claim.population === null
            ? 'Populasjon er ikke angitt.'
            : `Populasjon: ${view.claim.population}.`}
        </p>
        <p>Avgrensning: {view.claim.scope}</p>
        <p>Usikkerhet: {view.claim.uncertaintySummary}</p>
        {view.claim.qualifiers === null ? null : <p>Forbehold: {view.claim.qualifiers}</p>}
      </section>

      <section aria-labelledby="vurdering-title">
        <h2 id="vurdering-title">Evidensvurdering</h2>
        {view.assessment === null ? (
          <p className="notice">
            Ingen evidensvurdering er registrert. Det er noe annet enn en vurdering som konkluderte
            med lav sikkerhet.
          </p>
        ) : (
          <>
            <p>
              Sikkerhet i grunnlaget ({view.assessment.framework}):{' '}
              {label(view.assessment.certaintyLevel, CERTAINTY_LABELS)}.
            </p>
            <p>{view.assessment.rationale}</p>
            {view.assessment.evidenceGap === null ? null : (
              <p>Kunnskapshull: {view.assessment.evidenceGap}</p>
            )}
          </>
        )}
      </section>

      <section aria-labelledby="dekning-title">
        <h2 id="dekning-title">Kildedekning</h2>
        {view.sourceCoverage.length === 0 ? (
          <p className="notice">Ingen kilder er knyttet til kandidaten.</p>
        ) : (
          <ul>
            {view.sourceCoverage.map((source) => (
              <li key={source.sourceId}>
                <strong>{source.title}</strong>: {String(source.evidenceItemCount)} evidensfunn.{' '}
                {source.fullTextInLibrary
                  ? 'Fullteksten ligger i biblioteket.'
                  : 'Fullteksten ligger ikke i biblioteket.'}{' '}
                {source.readabilityChecked
                  ? 'Lesbarheten er kontrollert.'
                  : 'Lesbarheten er ikke kontrollert.'}{' '}
                {source.groundingMachineProved
                  ? 'Kildeforankringen er maskinelt bevist.'
                  : 'Kildeforankringen er ikke maskinelt bevist.'}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section aria-labelledby="evidens-title">
        <h2 id="evidens-title">Evidensgrunnlaget</h2>
        {view.evidence.length === 0 ? (
          <p className="notice">Ingen evidensfunn er lenket til kandidaten.</p>
        ) : (
          <ul>
            {view.evidence.map((evidence) => (
              <EvidenceCard evidence={evidence} key={evidence.evidenceItemId} />
            ))}
          </ul>
        )}
      </section>

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
    </main>
  )
}
