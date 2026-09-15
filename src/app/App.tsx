import { BrowserRouter, Link, Route, Routes, useParams } from 'react-router'

import { CandidatePage } from './CandidatePage'
import { CandidateQueuePage } from './CandidateQueuePage'
import { createCandidateGateway, type CandidateGateway } from './candidate-gateway'
import { CANDIDATE_PATH, CANDIDATE_QUEUE_PATH, HOME_PATH, candidateQueuePath } from './routes'

export function ResetHome() {
  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Antidep 2</p>
      <h1>Kunnskapsgrunnlaget bygges på nytt</h1>
      <p className="lead">
        Antidep er et eksperimentelt kunnskapsverktøy for helsepersonell. Det gamle
        prototypeinnholdet er tatt ut av aktiv bruk.
      </p>
      <section aria-labelledby="status-title">
        <h2 id="status-title">Status</h2>
        <p>
          Agentkjeden og kildegrunnlaget videreutvikles. Forskningsfunn krever kontrollert
          fulltekst, og ferdige produkter skal vurderes av en navngitt fagperson før publisering.
        </p>
        <p className="notice">Ingen klinisk veiledning er tilgjengelig i denne versjonen.</p>
        <p>
          <Link to={candidateQueuePath()}>Kandidater til sluttkontroll</Link> — krever mandat, og
          viser eksperimentelt, upublisert innhold.
        </p>
      </section>
    </main>
  )
}

export function NotFound() {
  return (
    <main id="hovedinnhold">
      <p className="eyebrow">404</p>
      <h1>Siden finnes ikke</h1>
      <p>Den tidligere produktflaten er avviklet.</p>
      <Link to={HOME_PATH}>Til forsiden</Link>
    </main>
  )
}

/**
 * Henter kandidat-id-en ut av adressen.
 *
 * En adresse uten id er ikke en kandidat, og skal ikke bli til et kall med en
 * tom streng: da ville avvisningen kommet fra databasen, om en kandidat som
 * aldri ble bedt om.
 */
function CandidateRoute({ gateway }: { readonly gateway: CandidateGateway | undefined }) {
  const { candidateId } = useParams()
  if (candidateId === undefined || candidateId.length === 0) {
    return <NotFound />
  }
  return <CandidatePage candidateId={candidateId} gateway={gateway ?? createCandidateGateway()} />
}

/**
 * Køen, med klienten opprettet først når ruten faktisk vises.
 *
 * Opprettelsen ligger inne i komponenten og ikke i rutetabellen, fordi
 * `element`-uttrykkene evalueres for *hver* rute uansett hvilken som treffer.
 * En klient laget der ville kastet på forsiden i et miljø uten konfigurasjon —
 * og forsiden trenger den ikke.
 */
function QueueRoute({ gateway }: { readonly gateway: CandidateGateway | undefined }) {
  return <CandidateQueuePage gateway={gateway ?? createCandidateGateway()} />
}

export interface AppLayoutProps {
  /**
   * Veien til databasen.
   *
   * Injisert framfor hentet inne i komponentene, slik at flaten kan prøves uten
   * en Supabase-stack — og slik at en prøve kan beskrive nøyaktig hva databasen
   * svarte, også når den svarte noe galt.
   */
  readonly gateway?: CandidateGateway | undefined
}

export function AppLayout({ gateway }: AppLayoutProps = {}) {
  return (
    <Routes>
      <Route element={<ResetHome />} path={HOME_PATH} />
      <Route element={<QueueRoute gateway={gateway} />} path={CANDIDATE_QUEUE_PATH} />
      <Route element={<CandidateRoute gateway={gateway} />} path={CANDIDATE_PATH} />
      <Route element={<NotFound />} path="*" />
    </Routes>
  )
}

export function App() {
  return (
    <BrowserRouter>
      <AppLayout />
    </BrowserRouter>
  )
}
