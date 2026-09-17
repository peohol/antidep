// ============================================================================
// Påstander som har fått ny forskning
//
// Den tredje redaksjonelle flaten, og den siste menneskehandlingen i kjeden som
// ikke hadde en: å avgjøre om ny kunnskap skal inn i en påstand Antidep
// allerede har. Antidep oppdager at forskningen finnes, og bygger revisjonen
// når avgjørelsen er tatt — men avgjørelsen selv er faglig, og den er et
// menneskes (docs/ROADMAP.md, AGENTS.md).
//
// Køen sier bare hva oppgaven gjelder og hvor mye nytt som er kommet til. Selve
// avgjørelsen tas på oppgavens egen side, der hele den nye forskningen står:
// en kø som viste nok til å bestemme seg, ville bedt om en avgjørelse tatt på
// et sammendrag.
//
// En tom kø er ikke en avvisning: den betyr at ingen påstand venter på noe fra
// deg akkurat nå.
// ============================================================================

import { useEffect, useState } from 'react'
import { Link } from 'react-router'

import { claimRevisionPath } from './routes'
import { newEvidenceSentence, type ClaimRevisionTask } from '../lib/claim-revision'
import { formatTimestampAsDate, renderedText } from '../lib/norwegian-format'
import type { ClaimRevisionGateway } from './claim-revision-gateway'
import { pageMessage } from './gateway'

export interface ClaimRevisionQueuePageProps {
  readonly gateway: ClaimRevisionGateway
}

function QueueEntry({ task }: { readonly task: ClaimRevisionTask }): React.JSX.Element {
  return (
    <li className="inbox-item">
      <h3>
        <Link to={claimRevisionPath(task.reference)}>{task.statement}</Link>
      </h3>
      <p className="inbox-item__article">
        {task.subjectDrug} — {task.topic}
        {task.published ? '. Publisert og i bruk nå.' : '. Ikke publisert ennå.'}
      </p>
      <p>{newEvidenceSentence(task)}</p>
      <p className="work-item__when">
        Oppdaget {renderedText(formatTimestampAsDate(task.noticedAt), 'tidspunkt')}
      </p>
    </li>
  )
}

export function ClaimRevisionQueuePage({
  gateway,
}: ClaimRevisionQueuePageProps): React.JSX.Element {
  const [tasks, setTasks] = useState<readonly ClaimRevisionTask[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    gateway
      .listQueue()
      .then((rows) => {
        if (!cancelled) {
          setTasks(rows)
          setError(null)
        }
      })
      .catch((cause: unknown) => {
        if (!cancelled) {
          setTasks(null)
          // Setningen er allerede flatens egen (`gateway.ts`). Den rå årsaken
          // har gått til observability og kommer aldri hit.
          setError(pageMessage(cause))
        }
      })
    return () => {
      cancelled = true
    }
  }, [gateway])

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Ny forskning</p>
      <h1>Påstander som har fått ny forskning</h1>
      <p className="lead">
        Antidep har funnet og kontrollert ny forskning om noe det allerede sier noe om. Hva
        påstanden skal si i lys av den, er en faglig avgjørelse. Åpne en oppgave for å se den nye
        forskningen og avgjøre om påstanden skal skrives om.
      </p>
      {error !== null ? (
        <p className="notice">{error}</p>
      ) : tasks === null ? (
        <p>Henter listen …</p>
      ) : tasks.length === 0 ? (
        <p className="notice">
          Ingen påstander venter på en avgjørelse nå. Dukker det opp ny forskning om noe Antidep
          allerede sier, står den her.
        </p>
      ) : (
        <ul className="inbox-list">
          {tasks.map((task) => (
            <QueueEntry key={task.reference} task={task} />
          ))}
        </ul>
      )}
    </main>
  )
}
