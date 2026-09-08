// ============================================================================
// Appskallet og rutingen
//
// ----------------------------------------------------------------------------
// Avhengighetsvalget for ruting (§7)
//
// MVP_IMPLEMENTATION_PLAN.md §7 lister ruting som en av kategoriene MVP-en skal
// bruke et bibliotek til, og lar valget ligge til den PR-en som først trenger
// det. Valget er `react-router` i deklarativ modus: én avhengighet
// (`cookie-es`), og den etablerte standarden i React-økosystemet.
//
// Alternativet — en håndskrevet ruter på History API-et — ville spart
// avhengigheten og kostet nettopp de detaljene en ruter finnes for: at ctrl-,
// cmd- og midtklikk fortsatt skal åpne i ny fane, at `popstate` og
// nettleserens fram/tilbake skal virke, og at eksterne lenker ikke fanges. Det
// er en klasse feil som ser ut som ingenting til den dagen den ikke gjør det.
//
// Data-modusen (loaders, `createBrowserRouter`) er bevisst *ikke* tatt i bruk.
// Den ville innført et server-state-mønster gjennom bakdøren, og §7 ber om at
// den kategorien utsettes til behovet er demonstrert. Se `use-read-model.ts`.
//
// ----------------------------------------------------------------------------
// Fokus etter navigering
//
// En klientside-navigering flytter ikke fokus av seg selv, så en skjermleser
// eller en tastaturbruker blir stående igjen i forrige side uten å få vite at
// innholdet er byttet. Fokus flyttes derfor til hovedområdet ved hver
// adresseendring — men ikke ved første render, der brukeren allerede står
// øverst (PRODUCT_INFORMATION_ARCHITECTURE.md §50, §52).
// ============================================================================

import { useEffect, useMemo, useRef, type RefObject } from 'react'
import { BrowserRouter, Link, Route, Routes, useLocation } from 'react-router'
import { AntidepClientProvider, resolveAntidepClient } from './antidep-client'
import { AccessPage } from './pages/AccessPage'
import { ClaimEvidencePage } from './pages/ClaimEvidencePage'
import { ClaimReviewPage } from './pages/ClaimReviewPage'
import { CreateEvidenceItemPage } from './pages/CreateEvidenceItemPage'
import { CreateSourcePage } from './pages/CreateSourcePage'
import { CreateSourceVersionPage } from './pages/CreateSourceVersionPage'
import { DrugPage } from './pages/DrugPage'
import { ExtractionReviewPage } from './pages/ExtractionReviewPage'
import { ExtractionReviewQueuePage } from './pages/ExtractionReviewQueuePage'
import { HomePage } from './pages/HomePage'
import { NotFoundPage } from './pages/NotFoundPage'
import { ReviewQueuePage } from './pages/ReviewQueuePage'
import { SourcePage } from './pages/SourcePage'
import { TopicPage } from './pages/TopicPage'
import {
  ROUTE_PATTERNS,
  accessPath,
  homePath,
  newEvidenceItemPath,
  extractionReviewQueuePath,
  newSourcePath,
  newSourceVersionPath,
  reviewQueuePath,
} from './routes'

const MAIN_ID = 'hovedinnhold'

function useFocusMainOnNavigation(main: RefObject<HTMLElement | null>) {
  const { pathname } = useLocation()
  const isFirstRender = useRef(true)

  useEffect(() => {
    if (isFirstRender.current) {
      isFirstRender.current = false
      return
    }
    main.current?.focus()
  }, [main, pathname])
}

/**
 * Skallet rundt sidene, uten ruter-provider og uten klient.
 *
 * Eksportert for tester, som setter opp begge selv: en test skal kunne stå på
 * en gitt adresse med en injisert klient uten å røre miljøvariabler eller
 * nettleserhistorikk.
 */
export function AppLayout() {
  const main = useRef<HTMLElement | null>(null)
  useFocusMainOnNavigation(main)

  return (
    <>
      {/* Første fokuserbare element på siden, synlig først når det har fokus
          (§49, §52). Uten det må en tastaturbruker gå gjennom toppen på nytt
          for hver navigering. */}
      <a className="skip-link" href={`#${MAIN_ID}`}>
        Hopp til hovedinnhold
      </a>
      <header>
        <h1>
          <Link to={homePath()}>Antidep</Link>
        </h1>
        <p>Klinisk arbeidsverktøy om antidepressiver for helsepersonell i Norge</p>
        <p className="development-notice">
          Antidep er under utvikling. Kunnskapsbasen er ufullstendig, og innholdet skal ikke brukes
          som grunnlag for kliniske beslutninger ennå.
        </p>
        {/* Steg 1 av adminflyten (§29, §74.22): innlogging og «Min tilgang» er
            nå den samme siden for alle, innlogget eller ikke — se
            AccessPage.tsx. Lenken står i toppen slik forsidelenken gjør, ikke
            gjemt bak klinikerflaten. */}
        <nav aria-label="Konto">
          <Link to={accessPath()}>Min tilgang</Link>
        </nav>
        {/* Steg 2 og 3 av adminflyten (§29, §74.24): begge sidene viser
            skjemaet sitt til enhver innlogget bruker og lar retten kontrolleres
            på serveren, på sitt eget tidspunkt — ingen rollegate i lenkene
            heller (se sidenes egne doc-kommentarer). Rekkefølgen er kjedens: en
            kilde må finnes før en versjon av den kan registreres, og en versjon
            før et evidensfunn kan peke på den. */}
        <nav aria-label="Admin">
          <Link to={newSourcePath()}>Opprett kilde</Link>
          <Link to={newSourceVersionPath()}>Registrer kildeversjon</Link>
          <Link to={newEvidenceItemPath()}>Registrer evidensfunn</Link>
          {/* Steg 4 og 5 (§15). Begge er kontroller, og de er to fordi de spør om
              to forskjellige ting: om ekstraksjonen gjengir kilden riktig, og om
              grunnlaget støtter påstanden. Publiseringsgaten krever dem hver for
              seg (G5 og G9). Lenkene står sammen med registreringsstegene fordi de
              er neste ledd i den samme kjeden — men handlingen er en annen rolles:
              å registrere innhold og å gå god for det er forskjellige rettigheter
              (MVP_IMPLEMENTATION_PLAN.md §16). */}
          <Link to={extractionReviewQueuePath()}>Kildekontroll</Link>
          <Link to={reviewQueuePath()}>Faglig vurdering</Link>
        </nav>
      </header>
      {/* tabIndex -1 gjør hovedområdet fokuserbart programmatisk, ikke med tab. */}
      <main id={MAIN_ID} ref={main} tabIndex={-1}>
        <Routes>
          <Route element={<HomePage />} path={ROUTE_PATTERNS.home} />
          <Route element={<DrugPage />} path={ROUTE_PATTERNS.drug} />
          <Route element={<TopicPage />} path={ROUTE_PATTERNS.topic} />
          <Route element={<ClaimEvidencePage />} path={ROUTE_PATTERNS.claimEvidence} />
          <Route element={<CreateSourcePage />} path={ROUTE_PATTERNS.sourceNew} />
          <Route element={<CreateSourceVersionPage />} path={ROUTE_PATTERNS.sourceVersionNew} />
          <Route element={<CreateEvidenceItemPage />} path={ROUTE_PATTERNS.evidenceNew} />
          <Route element={<ReviewQueuePage />} path={ROUTE_PATTERNS.reviewQueue} />
          <Route element={<ClaimReviewPage />} path={ROUTE_PATTERNS.claimReview} />
          <Route
            element={<ExtractionReviewQueuePage />}
            path={ROUTE_PATTERNS.extractionReviewQueue}
          />
          <Route element={<ExtractionReviewPage />} path={ROUTE_PATTERNS.extractionReview} />
          <Route element={<SourcePage />} path={ROUTE_PATTERNS.source} />
          <Route element={<AccessPage />} path={ROUTE_PATTERNS.access} />
          <Route element={<NotFoundPage />} path="*" />
        </Routes>
      </main>
    </>
  )
}

export function App() {
  // Konfigurasjonen leses én gang. Et kast her ville tatt ned hele flaten;
  // tilstanden vises i stedet av sidene, som en feil og aldri som tomhet.
  const availability = useMemo(() => resolveAntidepClient(), [])

  return (
    <AntidepClientProvider value={availability}>
      <BrowserRouter>
        <AppLayout />
      </BrowserRouter>
    </AntidepClientProvider>
  )
}
