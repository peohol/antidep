// ============================================================================
// Bestillingen: «Bygg monografi for sertralin»
//
// Én handling, og den er hele inngangen. Klinikeren velger et virkestoff og
// trykker på knappen; alt annet — kunnskapsbehovene, søkeplanene,
// kildeoppdagelsen, innhentingen, kontrollene — gjør Antidep selv.
//
// Det står ingen artikkelliste her, og det skal ikke stå en. Å foreslå
// artikler én for én er ikke det klinikeren skal gjøre (MONOGRAPH_PLAN.md).
//
// ----------------------------------------------------------------------------
// Framdriften er tall og tegn, aldri en farge alene
//
// Hver bestilling viser hvor mange spørsmål som er besvart, hvor mange som er
// gjennomgåtte kunnskapshull, hvor mange som er avgjort som ikke relevante,
// hvor mange som er uavklarte, og hvor mange som står åpne — og de blokkerte
// står for seg, fordi manglende tilgang aldri er en konklusjon om kunnskapen.
// ============================================================================

import { useEffect, useState } from 'react'
import { Link } from 'react-router'

import {
  blockedSummary,
  completionLabel,
  type MonographCoverage,
} from '../lib/monograph'
import { formatTimestampWithClock, renderedText } from '../lib/norwegian-format'
import type { MonographGateway } from './monograph-gateway'
import { monographEditionPath } from './routes'
import { pageMessage } from './gateway'

export interface MonographPageProps {
  readonly gateway: MonographGateway
}

function CoverageSummary({ coverage }: { readonly coverage: MonographCoverage }) {
  const blocked = blockedSummary(coverage)
  return (
    <li className="work-item">
      <h3>
        <Link to={monographEditionPath(coverage.reference)}>
          Monografi for {coverage.drug}
        </Link>
      </h3>
      <p className="work-item__what">{completionLabel(coverage)}</p>
      <p className="work-item__subjects">
        {coverage.counts.answered} av {coverage.counts.total} spørsmål er besvart.{' '}
        {coverage.counts.reviewedGaps} er gjennomgåtte kunnskapshull eller motstrider,{' '}
        {coverage.counts.justifiedNotApplicable} er avgjort som ikke relevante, og{' '}
        {coverage.counts.undeterminedRelevance} har uavklart relevans.{' '}
        {coverage.counts.open} står fortsatt åpne.
      </p>
      {blocked.length === 0 ? null : (
        <ul className="monograph-blocked">
          {blocked.map((line) => (
            <li key={line}>{line}</li>
          ))}
        </ul>
      )}
      <p className="work-item__when">
        Bestilt {renderedText(formatTimestampWithClock(coverage.orderedAt), 'tidspunkt')} · Standard{' '}
        {coverage.standardVersion}
      </p>
    </li>
  )
}

export function MonographPage({ gateway }: MonographPageProps): React.JSX.Element {
  const [orders, setOrders] = useState<readonly MonographCoverage[] | null>(null)
  const [drugs, setDrugs] = useState<readonly string[]>([])
  const [templates, setTemplates] = useState<number>(0)
  const [drug, setDrug] = useState<string>('')
  const [note, setNote] = useState<string>('')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    Promise.all([gateway.listOrders(), gateway.options()])
      .then(([rows, options]) => {
        if (cancelled) return
        setOrders(rows)
        setDrugs(options.drugs)
        setTemplates(options.questionTemplates)
        setDrug((current) => (current.length > 0 ? current : (options.drugs[0] ?? '')))
        setError(null)
      })
      .catch((cause: unknown) => {
        if (!cancelled) {
          setOrders(null)
          setError(pageMessage(cause))
        }
      })
    return () => {
      cancelled = true
    }
  }, [gateway])

  async function submit(event: React.FormEvent): Promise<void> {
    event.preventDefault()
    if (drug.length === 0 || busy) return
    setBusy(true)
    setMessage(null)
    try {
      await gateway.order(drug, note)
      const rows = await gateway.listOrders()
      setOrders(rows)
      setMessage(
        `Monografien for ${drug} er bestilt. Antidep oppretter kunnskapsbehovene og ` +
          'begynner å lete etter kilder selv.',
      )
      setNote('')
      setError(null)
    } catch (cause: unknown) {
      setError(pageMessage(cause))
    } finally {
      setBusy(false)
    }
  }

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Monografi</p>
      <h1>Bygg en monografi</h1>
      <p className="lead">
        Velg et virkestoff, så gjør Antidep resten: oppretter kunnskapsbehovene, leter etter
        kilder, vurderer dem og bygger et kontrollert utkast. Du skal ikke foreslå artikler én
        for én.
      </p>
      <p className="notice">
        Antidep er et eksperimentelt kunnskapsverktøy om antidepressiver. Ingenting her er
        klinisk veiledning, og et utkast er ikke godkjent innhold.
      </p>

      <section aria-labelledby="bestill-title">
        <h2 id="bestill-title">Ny bestilling</h2>
        {templates > 0 ? (
          <p>
            Standarden stiller {templates} spørsmål. Antidep gjentar dem der avgrensningen krever
            det, så det faktiske antallet kunnskapsbehov blir større.
          </p>
        ) : null}
        <form onSubmit={submit}>
          <p>
            <label htmlFor="virkestoff">Virkestoff</label>
            <br />
            <select
              id="virkestoff"
              value={drug}
              onChange={(event) => setDrug(event.target.value)}
              disabled={drugs.length === 0 || busy}
            >
              {drugs.map((name) => (
                <option key={name} value={name}>
                  {name}
                </option>
              ))}
            </select>
          </p>
          <p>
            <label htmlFor="merknad">Merknad (valgfri)</label>
            <br />
            <textarea
              id="merknad"
              value={note}
              rows={2}
              onChange={(event) => setNote(event.target.value)}
              disabled={busy}
            />
          </p>
          <p>
            <button type="submit" disabled={drug.length === 0 || busy}>
              {busy ? 'Bestiller …' : `Bygg monografi for ${drug || 'virkestoffet'}`}
            </button>
          </p>
        </form>
        {message === null ? null : <p className="notice">{message}</p>}
      </section>

      <section aria-labelledby="bestilte-title">
        <h2 id="bestilte-title">Bestilte monografier</h2>
        {error === null ? null : <p className="notice">{error}</p>}
        {orders === null ? (
          <p>Henter …</p>
        ) : orders.length === 0 ? (
          <p>Ingen monografier er bestilt ennå.</p>
        ) : (
          <ul className="work-list">
            {orders.map((coverage) => (
              <CoverageSummary key={coverage.reference} coverage={coverage} />
            ))}
          </ul>
        )}
      </section>
    </main>
  )
}
