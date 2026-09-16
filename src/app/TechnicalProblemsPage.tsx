// ============================================================================
// Den tekniske problemoversikten
//
// Driftens egen side, og ingen kliniker skal noen gang trenge å åpne den. Den
// svarer på tre ting, og ingen flere: hvilket område som har problemer, når
// problemet oppsto og sist ble sett, og om det fortsatt pågår.
//
// ----------------------------------------------------------------------------
// Ingen rå diagnose, og det er ikke et hull
//
// Den rå årsaken finnes — i workflow.technical_incidents, privat, der Claude
// Code og ChatGPT kan lese den. Den kommer bare ikke hit. En admin som ikke er
// tekniker, blir ikke hjulpet av en SQLSTATE eller et funksjonsnavn, og en
// flate som viste dem, ville gjort feilsøking til en menneskeoppgave i UI
// (issue #99, punkt 6).
//
// ----------------------------------------------------------------------------
// Faglige blokkeringer står ikke her
//
// «Venter på fulltekst» er ikke et teknisk problem. Det er normal
// arbeidsblokkering, og det hører hjemme i arbeidsoversikten og i
// fulltekstinnboksen (ANTIDEP_CONSTITUTION.md regel 4).
// ============================================================================

import { useEffect, useState } from 'react'
import { Link } from 'react-router'

import { areaSentence, type TechnicalProblem } from '../lib/technical-problems'
import { formatTimestampWithClock, renderedText } from '../lib/norwegian-format'
import { fullTextInboxPath, workBoardPath } from './routes'
import type { TechnicalGateway } from './technical-gateway'
import { pageMessage } from './gateway'

export interface TechnicalProblemsPageProps {
  readonly gateway: TechnicalGateway
}

function when(raw: string): string {
  return renderedText(formatTimestampWithClock(raw), 'tidspunkt')
}

function ProblemEntry({ problem }: { readonly problem: TechnicalProblem }): React.JSX.Element {
  return (
    <li className="problem-item">
      <span className={`status status--${problem.ongoing ? 'failed' : 'done'}`}>
        <span aria-hidden="true" className="status__mark">
          {problem.ongoing ? '✕' : '✓'}
        </span>
        {problem.ongoing ? 'Pågår' : 'Løst'}
      </span>
      <p className="problem-item__what">{areaSentence(problem.area)}</p>
      <p className="problem-item__when">
        Oppsto {when(problem.firstSeenAt)}. Sist sett {when(problem.lastSeenAt)}.
        {problem.occurrenceCount > 1
          ? ` Registrert ${String(problem.occurrenceCount)} ganger.`
          : ''}
        {problem.resolvedAt === null ? '' : ` Løst ${when(problem.resolvedAt)}.`}
      </p>
    </li>
  )
}

export function TechnicalProblemsPage({ gateway }: TechnicalProblemsPageProps): React.JSX.Element {
  const [problems, setProblems] = useState<readonly TechnicalProblem[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    gateway
      .list()
      .then((rows) => {
        if (!cancelled) {
          setProblems(rows)
          setError(null)
        }
      })
      .catch((cause: unknown) => {
        if (!cancelled) {
          setProblems(null)
          setError(pageMessage(cause))
        }
      })
    return () => {
      cancelled = true
    }
  }, [gateway])

  const ongoing = problems?.filter((problem) => problem.ongoing) ?? []
  const resolved = problems?.filter((problem) => !problem.ongoing) ?? []

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Drift</p>
      <h1>Tekniske problemer</h1>
      <p className="lead">
        Siden viser hva som ikke virker som det skal i Antidep, og når det skjedde. Detaljene om
        årsaken er lagret sikkert og leses av dem som vedlikeholder Antidep — de vises ikke her,
        fordi de ikke er til nytte for noen som skal bruke systemet.
      </p>
      <p>
        At Antidep venter på en artikkel, er ikke et teknisk problem. Det står i{' '}
        <Link to={workBoardPath()}>arbeidsoversikten</Link> og i{' '}
        <Link to={fullTextInboxPath()}>fulltekstinnboksen</Link>.
      </p>
      {error !== null ? (
        <p className="notice">{error}</p>
      ) : problems === null ? (
        <p>Henter oversikten …</p>
      ) : problems.length === 0 ? (
        <p className="notice">Ingen tekniske problemer er registrert.</p>
      ) : (
        <>
          <section aria-labelledby="pagaende">
            <h2 id="pagaende">Pågår nå</h2>
            {ongoing.length === 0 ? (
              <p>Ingenting pågår nå.</p>
            ) : (
              <ul className="problem-list">
                {ongoing.map((problem) => (
                  <ProblemEntry key={problem.reference} problem={problem} />
                ))}
              </ul>
            )}
          </section>
          {resolved.length === 0 ? null : (
            <section aria-labelledby="loste">
              <h2 id="loste">Løst tidligere</h2>
              <ul className="problem-list">
                {resolved.map((problem) => (
                  <ProblemEntry key={problem.reference} problem={problem} />
                ))}
              </ul>
            </section>
          )}
        </>
      )}
    </main>
  )
}
