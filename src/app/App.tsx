import { BrowserRouter, Link, Route, Routes } from 'react-router'
import { HOME_PATH } from './routes'

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

export function AppLayout() {
  return (
    <Routes>
      <Route element={<ResetHome />} path={HOME_PATH} />
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
