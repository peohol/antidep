// ============================================================================
// Den åpne arbeidsoversikten
//
// Erstatter den tekniske flaten `/agentarbeid`. Der ble et menneske bedt om å
// velge KI-tjeneste, registrere en kjører, hente en tilkoblingskode, laste ned
// en oppgavefil og laste opp et svar. Ingen av delene er klinisk eller
// redaksjonelt arbeid, og ingen av dem hører hjemme i et produkt en kliniker
// skal kunne bruke (issue #99).
//
// Det som er igjen, er et spørsmål en kliniker faktisk har: hva arbeider
// Antidep med nå? Svaret er read-only, åpent, og på høyt abstraksjonsnivå.
//
// ----------------------------------------------------------------------------
// Tilstanden er databasens, ikke denne komponentens
//
// Alt som vises, kommer fra `api.public_work_board()`. Ingenting bygges opp av
// hva denne fanen har sett skje: historikken er varig, og den er den samme for
// alle som leser den (issue #99, punkt 9).
//
// ----------------------------------------------------------------------------
// Status uttrykkes aldri med farge alene
//
// Hver rad har et tegn, en tekst og en farge. Tegnene er forskjellige former —
// ikke bare forskjellige farger — slik at de skiller seg også i svart-hvitt og
// for den som ikke ser fargeforskjellen. Fargen ligger i en klasse på elementet
// og bærer aldri informasjon alene (WCAG 1.4.1).
// ============================================================================

import { useEffect, useState } from 'react'

import {
  activityLabel,
  groupByStatus,
  statusPresentation,
  workStatusNote,
  type WorkBoardItem,
  type WorkStatus,
} from '../lib/work-board'
import { formatTimestampWithClock, renderedText } from '../lib/norwegian-format'
import type { WorkBoardGateway } from './work-board-gateway'
import { pageMessage } from './gateway'

export interface WorkBoardPageProps {
  readonly gateway: WorkBoardGateway
}

const GROUP_HEADINGS: Readonly<Record<WorkStatus, string>> = {
  in_progress: 'Pågår nå',
  planned: 'Planlagt',
  failed: 'Stoppet',
  done: 'Fullført',
}

const GROUP_NOTES: Readonly<Record<WorkStatus, string>> = {
  in_progress: 'Antidep arbeider med dette akkurat nå.',
  planned: 'Dette står i kø, eller venter på noe.',
  failed: 'Antidep kom ikke videre. Det er meldt fra, og noen ser på det.',
  done: 'Arbeid Antidep har gjort ferdig.',
}

function StatusBadge({ status }: { readonly status: WorkStatus }): React.JSX.Element {
  const presentation = statusPresentation(status)
  return (
    <span className={`status status--${presentation.tone}`}>
      <span aria-hidden="true" className="status__mark">
        {presentation.symbol}
      </span>
      {presentation.label}
    </span>
  )
}

function WorkItem({ item }: { readonly item: WorkBoardItem }): React.JSX.Element {
  const note = workStatusNote(item)
  return (
    <li className="work-item">
      <StatusBadge status={item.status} />
      <p className="work-item__what">{activityLabel(item.activity)}</p>
      {item.subjects.length > 0 ? (
        <p className="work-item__subjects">Gjelder: {item.subjects.join(', ')}</p>
      ) : null}
      {note === null ? null : <p className="work-item__note">{note}</p>}
      <p className="work-item__when">
        Sist endret {renderedText(formatTimestampWithClock(item.updatedAt), 'tidspunkt')}
      </p>
    </li>
  )
}

export function WorkBoardPage({ gateway }: WorkBoardPageProps): React.JSX.Element {
  const [items, setItems] = useState<readonly WorkBoardItem[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    gateway
      .list()
      .then((rows) => {
        if (!cancelled) {
          setItems(rows)
          setError(null)
        }
      })
      .catch((cause: unknown) => {
        if (!cancelled) {
          setItems(null)
          // Setningen er allerede flatens egen (`gateway.ts`). Den rå årsaken
          // har gått til observability og kommer aldri hit.
          setError(pageMessage(cause))
        }
      })
    return () => {
      cancelled = true
    }
  }, [gateway])

  const groups = items === null ? [] : groupByStatus(items)

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Arbeidsoversikt</p>
      <h1>Dette arbeider Antidep med</h1>
      <p className="lead">
        Antidep bygger kunnskapsgrunnlaget i flere steg: skaffe artikkelen, hente funn ut av den,
        kontrollere funnene, formulere påstanden og vurdere hvor sikker evidensen er. Oversikten
        viser hvor arbeidet står nå.
      </p>
      {error !== null ? (
        <p className="notice">{error}</p>
      ) : items === null ? (
        <p>Henter oversikten …</p>
      ) : items.length === 0 ? (
        <p className="notice">
          Ingenting står i kø nå. Det betyr ikke at kunnskapsgrunnlaget er ferdig — bare at det ikke
          er noe arbeid underveis i dette øyeblikket.
        </p>
      ) : (
        groups.map((group) => (
          <section aria-labelledby={`gruppe-${group.status}`} key={group.status}>
            <h2 id={`gruppe-${group.status}`}>{GROUP_HEADINGS[group.status]}</h2>
            <p>{GROUP_NOTES[group.status]}</p>
            <ul className="work-list">
              {group.items.map((item) => (
                <WorkItem item={item} key={item.reference} />
              ))}
            </ul>
          </section>
        ))
      )}
    </main>
  )
}
