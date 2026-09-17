// ============================================================================
// Én monografi: dekningen, utkastet, det som venter, og det redaktøren gjør
//
// Få hovedpunkter øverst, og dybden bak et klikk. Den som åpner siden, skal se
// hvor langt Antidep er kommet og hva som står i veien — ikke 109 spørsmål på
// rad.
//
// ----------------------------------------------------------------------------
// De seks dimensjonene står hver for seg
//
// Relevans, arbeidstilstand, faglig utfall, evidenssikkerhet, aktualitet og
// kontrollstatus vises som forskjellige opplysninger, fordi de betyr
// forskjellige ting. «Venter på tilgang» er ikke «utilstrekkelig evidens», og
// «uavklart relevans» er ikke «ikke relevant» (ANTIDEP_CONSTITUTION.md regel 4).
//
// Hver tilstand har et tegn, en tekst og en farge — aldri en farge alene
// (WCAG 1.4.1).
// ============================================================================

import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router'

import {
  blockedSummary,
  certaintyLabel,
  completionLabel,
  knowledgeTypeLabel,
  outcomePresentation,
  proposalLabel,
  relevancePresentation,
  workStatePresentation,
  type MonographDraft,
  type MonographEntry,
  type MonographProposal,
  type MonographRequest,
  type StatePresentation,
} from '../lib/monograph'
import type { MonographGateway } from './monograph-gateway'
import { monographPath } from './routes'
import { pageMessage } from './gateway'

export interface MonographEditionPageProps {
  readonly gateway: MonographGateway
  readonly reference: string
}

function StateBadge({ state }: { readonly state: StatePresentation }): React.JSX.Element {
  return (
    <span className={`status status--${state.tone}`}>
      <span aria-hidden="true" className="status__mark">
        {state.symbol}
      </span>
      {state.label}
    </span>
  )
}

function Entry({
  entry,
  gateway,
  onChanged,
}: {
  readonly entry: MonographEntry
  readonly gateway: MonographGateway
  readonly onChanged: () => void
}): React.JSX.Element {
  const [open, setOpen] = useState(false)
  const [statement, setStatement] = useState(entry.answer?.statement ?? '')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState<string | null>(null)

  const work = workStatePresentation(entry.workState)
  const relevance = relevancePresentation(entry.relevance)
  const outcome = entry.outcome === null ? null : outcomePresentation(entry.outcome)

  async function save(event: React.FormEvent): Promise<void> {
    event.preventDefault()
    if (busy) return
    setBusy(true)
    setNote(null)
    try {
      await gateway.editAnswer({
        needReference: entry.needReference,
        statement,
        changeReason: reason,
      })
      setReason('')
      setNote('Rettelsen er lagret som en ny revisjon. Den forrige står fortsatt.')
      onChanged()
    } catch (cause: unknown) {
      setNote(pageMessage(cause))
    } finally {
      setBusy(false)
    }
  }

  async function lock(): Promise<void> {
    setBusy(true)
    setNote(null)
    try {
      await gateway.lockAnswer(
        entry.needReference,
        reason.trim().length > 0 ? reason : 'Formuleringen er avklart og skal ikke overskrives.',
      )
      setNote(
        'Svaret er låst mot automatisk overskriving. Ny evidens som utfordrer det, blir et ' +
          'synlig avvik — låsen skjuler ingen kritikk.',
      )
      onChanged()
    } catch (cause: unknown) {
      setNote(pageMessage(cause))
    } finally {
      setBusy(false)
    }
  }

  return (
    <li className="work-item">
      <p className="monograph-entry__states">
        <StateBadge state={relevance} />
        <StateBadge state={work} />
        {outcome === null ? null : <StateBadge state={outcome} />}
      </p>
      <h4>
        {entry.templateCode}
        {entry.scope === null ? '' : ` · ${entry.scope}`}
      </h4>
      <p className="work-item__what">{entry.question}</p>
      {entry.answer === null ? (
        <p className="work-item__note">{work.note}</p>
      ) : (
        <>
          <p className="monograph-answer">{entry.answer.statement}</p>
          <p className="work-item__subjects">
            {knowledgeTypeLabel(entry.answer.knowledgeType)}
            {entry.answer.certainty === null
              ? ''
              : ` · ${String(certaintyLabel(entry.answer.certainty))}`}
            {entry.answer.asOf === null ? '' : ` · Gjaldt ${entry.answer.asOf}`}
          </p>
        </>
      )}
      {entry.workStateNote === null ? null : (
        <p className="work-item__note">{entry.workStateNote}</p>
      )}
      {entry.relevanceReason === null ? null : (
        <p className="work-item__note">Begrunnelse: {entry.relevanceReason}</p>
      )}

      <p>
        <button type="button" onClick={() => setOpen(!open)} aria-expanded={open}>
          {open ? 'Skjul detaljene' : 'Vis detaljene'}
        </button>
      </p>

      {!open ? null : (
        <div className="monograph-detail">
          {entry.answer === null ? (
            <p>Ingen kontrollert opplysning ennå.</p>
          ) : (
            <>
              {entry.answer.uncertaintySummary === null ? null : (
                <p>
                  <strong>Usikkerhet:</strong> {entry.answer.uncertaintySummary}
                </p>
              )}
              {entry.answer.limitationNote === null ? null : (
                <p>
                  <strong>Søke- og tilgangsbegrensninger:</strong> {entry.answer.limitationNote}
                </p>
              )}
              {entry.answer.recommendingBody === null ? null : (
                <p>
                  <strong>Anbefalt av:</strong> {entry.answer.recommendingBody}
                </p>
              )}
              <p>
                <strong>Kontrollert:</strong>{' '}
                {entry.answer.controlledFields.length === 0
                  ? 'ingen felter registrert'
                  : entry.answer.controlledFields.join(', ')}
              </p>
              <p>
                <strong>Kilder:</strong>
              </p>
              <ul>
                {entry.answer.sources.map((source, index) => (
                  <li key={`${source.title}-${index}`}>
                    {source.title}
                    {source.authorsOrIssuer === null ? '' : ` — ${source.authorsOrIssuer}`}
                    {source.locator === null ? '' : ` (${source.locator})`}
                  </li>
                ))}
              </ul>

              <form onSubmit={save}>
                <p>
                  <label htmlFor={`tekst-${entry.needReference}`}>Rett teksten</label>
                  <br />
                  <textarea
                    id={`tekst-${entry.needReference}`}
                    value={statement}
                    rows={3}
                    onChange={(event) => setStatement(event.target.value)}
                    disabled={busy}
                  />
                </p>
                <p>
                  <label htmlFor={`grunn-${entry.needReference}`}>Begrunnelse</label>
                  <br />
                  <input
                    id={`grunn-${entry.needReference}`}
                    type="text"
                    value={reason}
                    onChange={(event) => setReason(event.target.value)}
                    disabled={busy}
                  />
                </p>
                <p>
                  <button type="submit" disabled={busy}>
                    Lagre rettelsen
                  </button>{' '}
                  <button type="button" onClick={lock} disabled={busy}>
                    Lås mot automatisk overskriving
                  </button>
                </p>
              </form>
            </>
          )}
          {note === null ? null : <p className="notice">{note}</p>}
        </div>
      )}
    </li>
  )
}

function Requests({
  requests,
}: {
  readonly requests: readonly MonographRequest[]
}): React.JSX.Element {
  if (requests.length === 0) {
    return <p>Antidep venter ikke på noe originalmateriale nå.</p>
  }
  return (
    <ul className="work-list">
      {requests.map((request) => (
        <li className="work-item" key={request.reference}>
          <h3>{request.title}</h3>
          <p className="work-item__subjects">
            {request.authorsOrIssuer ?? 'Utgiver ikke oppgitt i treffet'}
            {request.publisherOrJournal === null ? '' : ` · ${request.publisherOrJournal}`}
          </p>
          {request.professionalReason === null ? null : (
            <p className="work-item__what">{request.professionalReason}</p>
          )}
          {request.accessLimitation === null ? null : (
            <p className="work-item__note">
              Tilgangsbegrensning: {request.accessLimitation}. Dette er en tilgangsbegrensning og
              ingen faglig utelukkelse.
            </p>
          )}
        </li>
      ))}
    </ul>
  )
}

function Proposals({
  proposals,
  gateway,
  onChanged,
}: {
  readonly proposals: readonly MonographProposal[]
  readonly gateway: MonographGateway
  readonly onChanged: () => void
}): React.JSX.Element {
  const [busy, setBusy] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)

  async function decide(reference: string, accept: boolean): Promise<void> {
    setBusy(reference)
    setNote(null)
    try {
      await gateway.decideProposal(
        reference,
        accept,
        accept ? '' : 'Avviket er vurdert, og innholdet står som det er.',
      )
      onChanged()
    } catch (cause: unknown) {
      setNote(pageMessage(cause))
    } finally {
      setBusy(null)
    }
  }

  if (proposals.length === 0) {
    return <p>Ingen åpne avvik.</p>
  }

  return (
    <>
      {note === null ? null : <p className="notice">{note}</p>}
      <ul className="work-list">
        {proposals.map((proposal) => (
          <li className="work-item" key={proposal.reference}>
            <h3>{proposalLabel(proposal.kind)}</h3>
            <p className="work-item__subjects">
              {proposal.templateCode}
              {proposal.scope === null ? '' : ` · ${proposal.scope}`}
            </p>
            <p className="work-item__what">{proposal.rationale}</p>
            {proposal.sourceTitle === null ? null : (
              <p className="work-item__note">Kilde: {proposal.sourceTitle}</p>
            )}
            <p>
              <button
                type="button"
                onClick={() => decide(proposal.reference, true)}
                disabled={busy !== null}
              >
                Godta
              </button>{' '}
              <button
                type="button"
                onClick={() => decide(proposal.reference, false)}
                disabled={busy !== null}
              >
                Avvis
              </button>
            </p>
          </li>
        ))}
      </ul>
    </>
  )
}

/**
 * Ett tall i dekningen.
 *
 * Tallet og hva det teller står i hvert sitt element, slik at de holder sammen
 * også når siden brytes om på en telefon — og slik at ingen av tellingene blir
 * lest som en annen enn den er.
 */
function Count({
  number,
  what,
}: {
  readonly number: number
  readonly what: string
}): React.JSX.Element {
  return (
    <li>
      <span className="monograph-counts__number">{number}</span>
      <span className="monograph-counts__what">{what}</span>
    </li>
  )
}

export function MonographEditionPage({
  gateway,
  reference,
}: MonographEditionPageProps): React.JSX.Element {
  const [draft, setDraft] = useState<MonographDraft | null>(null)
  const [requests, setRequests] = useState<readonly MonographRequest[]>([])
  const [proposals, setProposals] = useState<readonly MonographProposal[]>([])
  const [error, setError] = useState<string | null>(null)
  const [openSections, setOpenSections] = useState<readonly string[]>([])

  const load = useCallback(() => {
    Promise.all([
      gateway.draft(reference),
      gateway.requests(reference),
      gateway.proposals(reference),
    ])
      .then(([draftRow, requestRows, proposalRows]) => {
        setDraft(draftRow)
        setRequests(requestRows)
        setProposals(proposalRows)
        setError(null)
      })
      .catch((cause: unknown) => {
        setDraft(null)
        setError(pageMessage(cause))
      })
  }, [gateway, reference])

  useEffect(() => {
    load()
  }, [load])

  if (error !== null) {
    return (
      <main id="hovedinnhold">
        <h1>Monografi</h1>
        <p className="notice">{error}</p>
        <p>
          <Link to={monographPath()}>Tilbake til monografiene</Link>
        </p>
      </main>
    )
  }

  if (draft === null) {
    return (
      <main id="hovedinnhold">
        <h1>Monografi</h1>
        <p>Henter …</p>
      </main>
    )
  }

  const coverage = draft.coverage
  const blocked = blockedSummary(coverage)

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Monografi</p>
      <h1>{draft.drug}</h1>
      <p className="lead">{completionLabel(coverage)}</p>
      {coverage.partial ? (
        <p className="notice">
          Dette er et delvis utkast. {coverage.counts.open} av {coverage.counts.total} spørsmål er
          ikke ferdig behandlet, og {coverage.counts.undeterminedRelevance} har uavklart relevans.
          Ingen del av dette er klinisk veiledning.
        </p>
      ) : null}

      <section aria-labelledby="dekning-title">
        <h2 id="dekning-title">Dekning</h2>
        <ul className="monograph-counts">
          <Count what="besvarte spørsmål" number={coverage.counts.answered} />
          <Count
            what="gjennomgåtte kunnskapshull eller motstrider"
            number={coverage.counts.reviewedGaps}
          />
          <Count what="begrunnet ikke relevante" number={coverage.counts.justifiedNotApplicable} />
          <Count what="med uavklart relevans" number={coverage.counts.undeterminedRelevance} />
          <Count what="fortsatt åpne" number={coverage.counts.open} />
          <Count what="spørsmål i alt" number={coverage.counts.total} />
        </ul>
        {blocked.length === 0 ? null : (
          <>
            <h3>Dette står i veien</h3>
            <ul className="monograph-blocked">
              {blocked.map((line) => (
                <li key={line}>{line}</li>
              ))}
            </ul>
            <p className="work-item__note">
              Ingen av disse er en konklusjon om kunnskapen. De sier hva Antidep mangler.
            </p>
          </>
        )}
      </section>

      <section aria-labelledby="venter-title">
        <h2 id="venter-title">Originalmateriale Antidep venter på</h2>
        <Requests requests={requests} />
      </section>

      <section aria-labelledby="avvik-title">
        <h2 id="avvik-title">Avvik som venter på en avgjørelse</h2>
        <Proposals proposals={proposals} gateway={gateway} onChanged={load} />
      </section>

      <section aria-labelledby="utkast-title">
        <h2 id="utkast-title">Utkastet</h2>
        <p>
          Spørsmålene står i standardens egne seksjoner. Åpne en seksjon for å se svarene og
          tilstanden til hvert spørsmål.
        </p>
        {draft.sections.map((section) => {
          const open = openSections.includes(section.section)
          const answered = section.entries.filter((entry) => entry.outcome === 'answered').length
          return (
            <div key={section.section} className="monograph-section">
              <h3>
                <button
                  type="button"
                  aria-expanded={open}
                  onClick={() =>
                    setOpenSections(
                      open
                        ? openSections.filter((name) => name !== section.section)
                        : [...openSections, section.section],
                    )
                  }
                >
                  {section.section} — {answered} av {section.entries.length} besvart
                </button>
              </h3>
              {!open ? null : (
                <ul className="work-list">
                  {section.entries.map((entry) => (
                    <Entry
                      key={entry.needReference}
                      entry={entry}
                      gateway={gateway}
                      onChanged={load}
                    />
                  ))}
                </ul>
              )}
            </div>
          )
        })}
      </section>

      <p>
        <Link to={monographPath()}>Tilbake til monografiene</Link>
      </p>
    </main>
  )
}
