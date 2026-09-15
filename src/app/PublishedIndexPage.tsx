// ============================================================================
// Klinikerflaten: hva Antidep faktisk publiserer nå
//
// Listen er det som er publisert — ikke kandidatkøen. En påstand som er trukket
// tilbake, står ikke her; historikken om den er fortsatt etterprøvbar på
// påstandens egen side (ANTIDEP_CONSTITUTION.md regel 6).
//
// Verdiene leses ut av det forseglede innholdet, og ikke av dagens rader, slik
// at listen og siden bak den ikke kan si forskjellige ting.
// ============================================================================

import { useEffect, useState } from 'react'
import { Link } from 'react-router'

import type { PublishedClaimEntry } from '../lib/published-claim'
import type { PublicationGateway } from './publication-gateway'
import { publishedClaimPath } from './routes'
import { CERTAINTY_LABELS, label } from '../lib/vocabulary-view'

export interface PublishedIndexPageProps {
  readonly gateway: PublicationGateway
}

export function PublishedIndexPage({ gateway }: PublishedIndexPageProps): React.JSX.Element {
  const [entries, setEntries] = useState<readonly PublishedClaimEntry[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    gateway
      .listPublished()
      .then((next) => {
        if (!cancelled) {
          setEntries(next)
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

  if (error !== null) {
    return (
      <main id="hovedinnhold">
        <p className="eyebrow">Publisert</p>
        <h1>Det publiserte innholdet kunne ikke vises</h1>
        <p className="notice">{error}</p>
      </main>
    )
  }

  if (entries === null) {
    return (
      <main id="hovedinnhold">
        <p className="eyebrow">Publisert</p>
        <h1>Henter det publiserte innholdet …</h1>
      </main>
    )
  }

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Publisert</p>
      <h1>Publisert klinikerinnhold</h1>
      {entries.length === 0 ? (
        <p className="notice">
          Antidep publiserer ingenting nå. Det er ikke det samme som at ingenting er kontrollert: et
          innhold blir publisert først når en navngitt fagperson har sluttkontrollert det og en
          publisher har tatt det i bruk.
        </p>
      ) : (
        <ul>
          {entries.map((entry) => (
            <li key={entry.claimId}>
              <Link to={publishedClaimPath(entry.claimId)}>{entry.statement}</Link>
              <br />
              Virkestoff: {entry.subjectDrug}. Tema: {entry.topic}.{' '}
              {entry.certaintyLevel === null
                ? 'Ingen evidensvurdering er registrert.'
                : `Sikkerhet i grunnlaget: ${label(entry.certaintyLevel, CERTAINTY_LABELS)}.`}{' '}
              Kilder: {String(entry.sourceCount)}. Publisert: {entry.publishedAt}.
            </li>
          ))}
        </ul>
      )}
    </main>
  )
}
