// ============================================================================
// Navigasjonen, og det ene merket som kan dukke opp i den
//
// Lenkene er de samme for alle. Hvilke av dem som faktisk gir noe, avgjøres av
// mandatet når siden åpnes — ikke av navigasjonen, som ikke vet noe om det og
// ikke skal late som.
//
// ----------------------------------------------------------------------------
// Merket for tekniske problemer
//
// `api.technical_problem_summary()` svarer stille «ikke synlig» til alle som
// ikke har admin-mandat. Navigasjonen kan derfor spørre på hver side uten at
// noen andre får en feilmelding om noe de verken kan eller skal gjøre noe med.
//
// Feiler kallet — for eksempel fordi ingen er innlogget — vises ingenting. Det
// er riktig utfall: et merke er en beskjed til en drift, og en besøkende som
// ikke er det, skal ikke se det.
//
// Merket er ikke en farge alene: det bærer tallet og en tekstlig etikett, og
// lenken sier hva den fører til.
// ============================================================================

import { useEffect, useState } from 'react'
import { Link } from 'react-router'

import {
  candidateQueuePath,
  fullTextInboxPath,
  fullTextRequestPath,
  homePath,
  publishedPath,
  technicalProblemsPath,
  workBoardPath,
} from './routes'
import { antidepClient, flushPendingDiagnostics } from './gateway'
import { createTechnicalGateway, type TechnicalGateway } from './technical-gateway'

export interface SiteNavProps {
  /** Veien til problemtellingen, injisert slik at flaten kan prøves uten stack. */
  readonly technical?: TechnicalGateway | undefined
}

export function SiteNav({ technical }: SiteNavProps): React.JSX.Element {
  const [unresolved, setUnresolved] = useState<number | null>(null)

  useEffect(() => {
    let cancelled = false
    let gateway: TechnicalGateway
    try {
      // Klienten opprettes her og ikke i rutetabellen, av samme grunn som
      // `App.tsx` gjør det per rute: navigasjonen vises på hver side, også i et
      // miljø uten konfigurasjon, og en klient laget der ville kastet før noe
      // som helst kunne vises.
      gateway = technical ?? createTechnicalGateway()
    } catch {
      return
    }

    // Restansen fra en tidligere økt går med her. Ble Antidep utilgjengelig
    // mens noen sto i appen, er dette øyeblikket da årsakene endelig kommer
    // fram — og navigasjonen er den ene komponenten som vises på hver side.
    try {
      flushPendingDiagnostics(antidepClient())
    } catch {
      // Ingen klient, altså ingen konfigurasjon. Restansen blir liggende.
    }

    gateway
      .summary()
      .then((summary) => {
        if (!cancelled) {
          setUnresolved(summary.visible && summary.unresolved > 0 ? summary.unresolved : null)
        }
      })
      .catch(() => {
        // Ingen beskjed. Et merke som ikke kunne hentes, er ikke en beskjed til
        // den som står her — og den rå årsaken har allerede gått til
        // observability (`gateway.ts`).
        if (!cancelled) {
          setUnresolved(null)
        }
      })
    return () => {
      cancelled = true
    }
  }, [technical])

  return (
    <nav aria-label="Hovedmeny" className="sitenav">
      <ul>
        <li>
          <Link to={homePath()}>Forsiden</Link>
        </li>
        <li>
          <Link to={workBoardPath()}>Arbeidsoversikt</Link>
        </li>
        <li>
          <Link to={publishedPath()}>Publisert</Link>
        </li>
        <li>
          <Link to={candidateQueuePath()}>Sluttkontroll</Link>
        </li>
        <li>
          <Link to={fullTextInboxPath()}>Fulltekst</Link>
        </li>
        <li>
          <Link to={fullTextRequestPath()}>Be om en artikkel</Link>
        </li>
        {unresolved === null ? null : (
          <li>
            <Link to={technicalProblemsPath()}>
              Tekniske problemer{' '}
              <span className="badge">
                {String(unresolved)} <span className="badge__what">uløste</span>
              </span>
            </Link>
          </li>
        )}
      </ul>
    </nav>
  )
}
