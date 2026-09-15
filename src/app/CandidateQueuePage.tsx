// ============================================================================
// Køen: hvilke kandidater den innloggede fagpersonen har mandat til å se
//
// Nok til å velge én, ikke nok til å vurdere den. Vurderingen skjer i
// `CandidatePage`, som viser hele innholdet — og en kø som viste et sammendrag
// av et klinisk utsagn, ville vært en visning noen kunne ta stilling til uten å
// ha lest det.
//
// En tom kø er ikke en avvisning. En kaller uten mandat får ingen rader, og det
// er den samme tilstanden som «ingenting venter»: begge deler betyr at det ikke
// er noe her for deg, og ingen av dem er en feil.
// ============================================================================

import { useEffect, useState } from 'react'
import { Link } from 'react-router'

import { candidatePath } from './routes'
import type { CandidateGateway, CandidateQueueEntry } from './candidate-gateway'

export interface CandidateQueuePageProps {
  readonly gateway: CandidateGateway
}

export function CandidateQueuePage({ gateway }: CandidateQueuePageProps): React.JSX.Element {
  const [entries, setEntries] = useState<readonly CandidateQueueEntry[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    gateway
      .listQueue()
      .then((rows) => {
        if (!cancelled) {
          setEntries(rows)
          setError(null)
        }
      })
      .catch((cause: unknown) => {
        if (!cancelled) {
          setEntries(null)
          setError(cause instanceof Error ? cause.message : String(cause))
        }
      })
    return () => {
      cancelled = true
    }
  }, [gateway])

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Sluttkontroll</p>
      <h1>Kandidater til sluttkontroll</h1>
      <p className="notice">
        Eksperimentelt og upublisert innhold. Ingenting her er klinisk veiledning.
      </p>
      {error !== null ? (
        <p className="notice">{error}</p>
      ) : entries === null ? (
        <p>Henter køen …</p>
      ) : entries.length === 0 ? (
        <p>Ingen kandidater venter på deg nå.</p>
      ) : (
        <ul>
          {entries.map((entry) => (
            <li key={entry.candidateId}>
              <Link to={candidatePath(entry.candidateId)}>{entry.statement}</Link>
              <br />
              {entry.subjectDrug} / {entry.topic} — {String(entry.sourceCount)} kilder,{' '}
              {String(entry.finalControlCount)} registrerte sluttkontroller.
              {entry.certaintyLevel === null
                ? ' Ingen evidensvurdering er registrert.'
                : ` Sikkerhet: ${entry.certaintyLevel}.`}
            </li>
          ))}
        </ul>
      )}
    </main>
  )
}
