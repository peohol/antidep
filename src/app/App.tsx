import { BrowserRouter, Link, Route, Routes, useParams } from 'react-router'

import { CandidatePage } from './CandidatePage'
import { CandidateQueuePage } from './CandidateQueuePage'
import { FullTextInboxPage } from './FullTextInboxPage'
import { PublishedClaimPage } from './PublishedClaimPage'
import { PublishedIndexPage } from './PublishedIndexPage'
import { SiteNav } from './SiteNav'
import { TechnicalProblemsPage } from './TechnicalProblemsPage'
import { WorkBoardPage } from './WorkBoardPage'
import { createCandidateGateway, type CandidateGateway } from './candidate-gateway'
import { createFullTextGateway, type FullTextGateway } from './full-text-gateway'
import { createPublicationGateway, type PublicationGateway } from './publication-gateway'
import { createTechnicalGateway, type TechnicalGateway } from './technical-gateway'
import { createWorkBoardGateway, type WorkBoardGateway } from './work-board-gateway'
import {
  CANDIDATE_PATH,
  CANDIDATE_QUEUE_PATH,
  FULL_TEXT_INBOX_PATH,
  HOME_PATH,
  PUBLISHED_CLAIM_PATH,
  PUBLISHED_PATH,
  TECHNICAL_PROBLEMS_PATH,
  WORK_BOARD_PATH,
  candidateQueuePath,
  fullTextInboxPath,
  publishedPath,
  workBoardPath,
} from './routes'

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
          <Link to={workBoardPath()}>Arbeidsoversikt</Link> — hva Antidep arbeider med nå, og hva
          som er gjort ferdig. Åpen for alle.
        </p>
        <p>
          <Link to={publishedPath()}>Publisert klinikerinnhold</Link> — det Antidep faktisk sier nå,
          slik en navngitt fagperson godkjente det. Krever innlogging.
        </p>
        <p>
          <Link to={candidateQueuePath()}>Kandidater til sluttkontroll</Link> — krever mandat, og
          viser eksperimentelt, upublisert innhold.
        </p>
        <p>
          <Link to={fullTextInboxPath()}>Fulltekst</Link> — artiklene Antidep mangler, og
          opplastingen av dem. Krever mandat.
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

/** Den åpne arbeidsoversikten, med klienten opprettet først når ruten vises. */
function WorkBoardRoute({ gateway }: { readonly gateway: WorkBoardGateway | undefined }) {
  return <WorkBoardPage gateway={gateway ?? createWorkBoardGateway()} />
}

/** Fulltekstinnboksen, med klienten opprettet først når ruten vises. */
function FullTextRoute({ gateway }: { readonly gateway: FullTextGateway | undefined }) {
  return <FullTextInboxPage gateway={gateway ?? createFullTextGateway()} />
}

/** Den tekniske problemoversikten, med klienten opprettet først når ruten vises. */
function TechnicalRoute({ gateway }: { readonly gateway: TechnicalGateway | undefined }) {
  return <TechnicalProblemsPage gateway={gateway ?? createTechnicalGateway()} />
}

/** Den publiserte katalogen, med klienten opprettet først når ruten vises. */
function PublishedRoute({ gateway }: { readonly gateway: PublicationGateway | undefined }) {
  return <PublishedIndexPage gateway={gateway ?? createPublicationGateway()} />
}

/**
 * Én publisert påstand.
 *
 * En adresse uten id er ikke en påstand, og skal ikke bli til et kall med en tom
 * streng: da ville avvisningen kommet fra databasen, om noe som aldri ble bedt om.
 */
function PublishedClaimRoute({ gateway }: { readonly gateway: PublicationGateway | undefined }) {
  const { claimId } = useParams()
  if (claimId === undefined || claimId.length === 0) {
    return <NotFound />
  }
  return <PublishedClaimPage claimId={claimId} gateway={gateway ?? createPublicationGateway()} />
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
  /** Veien til det publiserte innholdet, injisert av samme grunn som over. */
  readonly publication?: PublicationGateway | undefined
  /** Veien til den åpne arbeidsoversikten, injisert av samme grunn som over. */
  readonly workBoard?: WorkBoardGateway | undefined
  /** Veien til fulltekstinnboksen, injisert av samme grunn som over. */
  readonly fullText?: FullTextGateway | undefined
  /** Veien til den tekniske problemoversikten, injisert av samme grunn som over. */
  readonly technical?: TechnicalGateway | undefined
}

export function AppLayout({
  gateway,
  publication,
  workBoard,
  fullText,
  technical,
}: AppLayoutProps = {}) {
  return (
    <>
      <SiteNav technical={technical} />
      <Routes>
        <Route element={<ResetHome />} path={HOME_PATH} />
        <Route element={<QueueRoute gateway={gateway} />} path={CANDIDATE_QUEUE_PATH} />
        <Route element={<CandidateRoute gateway={gateway} />} path={CANDIDATE_PATH} />
        <Route element={<WorkBoardRoute gateway={workBoard} />} path={WORK_BOARD_PATH} />
        <Route element={<FullTextRoute gateway={fullText} />} path={FULL_TEXT_INBOX_PATH} />
        <Route element={<TechnicalRoute gateway={technical} />} path={TECHNICAL_PROBLEMS_PATH} />
        <Route element={<PublishedRoute gateway={publication} />} path={PUBLISHED_PATH} />
        <Route
          element={<PublishedClaimRoute gateway={publication} />}
          path={PUBLISHED_CLAIM_PATH}
        />
        <Route element={<NotFound />} path="*" />
      </Routes>
    </>
  )
}

export function App() {
  return (
    <BrowserRouter>
      <AppLayout />
    </BrowserRouter>
  )
}
