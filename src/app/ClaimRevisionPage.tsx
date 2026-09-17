// ============================================================================
// Én påstand, den nye forskningen, og avgjørelsen
//
// Alt som trengs for den faglige avgjørelsen, og ikke noe mer: hva påstanden
// sier i dag, hvilket virkestoff og endepunkt den gjelder, og hva slags ny
// forskning som er kommet til siden den sist ble formulert.
//
// Ingen uuid, ingen jobbnøkkel, ingen agentrolle, ingen modell og ingen
// terminalkommando. Det tekniske arbeidet — å bygge synteseoppgaven med hele
// det oppdaterte evidensgrunnlaget, kontrollere den nye teksten mot kildene,
// vurdere hvor sikker evidensen er og forsegle kandidaten — gjør Antidep selv,
// og ingen av leddene er synlige her (AGENTS.md, issue #99).
//
// ----------------------------------------------------------------------------
// De to utfallene, og hvorfor det ikke finnes et tredje
//
// Enten skal påstanden skrives om med det oppdaterte grunnlaget, eller så er
// konklusjonen at den nye forskningen ikke endrer den. Det andre krever en
// begrunnelse, fordi det er den som gjør det til en faglig konklusjon framfor
// til en utsettelse. Kommer det senere enda mer ny forskning, åpner oppgaven seg
// igjen av seg selv.
//
// ----------------------------------------------------------------------------
// Avgjørelsen er bundet til det som ble lest
//
// Avtrykket av evidensgrunnlaget følger med avgjørelsen, uendret fra det siden
// fikk. Er grunnlaget blitt et annet mens siden sto åpen, avvises avgjørelsen,
// og siden ber om fersk tilstand (ANTIDEP_CONSTITUTION.md regel 5). Verdien
// vises aldri: den er ikke noe et menneske skal lese.
//
// Utrygg inndata: innholdet er data. React escaper all tekst, og ingenting her
// tolker en verdi som markup.
// ============================================================================

import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router'

import {
  MEASURE_LABELS,
  REPORTED_DIRECTION_LABELS,
  STUDY_DESIGN_LABELS,
  UNIT_LABELS,
} from '../components/vocabulary-labels'
import {
  decisionOutcomeSentence,
  decisionProblem,
  newEvidenceSentence,
  type ClaimRevisionDecision,
  type ClaimRevisionTask,
  type NewEvidenceSummary,
} from '../lib/claim-revision'
import { CERTAINTY_LABELS, label } from '../lib/vocabulary-view'
import { formatNumber, renderedText } from '../lib/norwegian-format'
import { claimRevisionQueuePath } from './routes'
import type { ClaimRevisionGateway } from './claim-revision-gateway'
import { pageMessage } from './gateway'

export interface ClaimRevisionPageProps {
  readonly reference: string
  readonly gateway: ClaimRevisionGateway
}

/** Tallet slik en kliniker leser det, eller ingenting når det ikke finnes. */
function number(value: number | null): string | null {
  return value === null ? null : renderedText(formatNumber(value), 'tall')
}

/** Størrelsen på funnet, i én setning — eller `null` når kilden ikke oppgir noen. */
function magnitudeSentence(evidence: NewEvidenceSummary): string | null {
  const estimate = number(evidence.estimate)
  if (estimate === null) {
    return null
  }
  const unit = evidence.estimateUnit === null ? '' : ` ${label(evidence.estimateUnit, UNIT_LABELS)}`
  const measure =
    evidence.effectMeasure === null ? '' : ` (${label(evidence.effectMeasure, MEASURE_LABELS)})`
  const lower = number(evidence.ciLower)
  const upper = number(evidence.ciUpper)
  const level = number(evidence.ciLevelPercent)
  const interval =
    lower === null || upper === null
      ? ''
      : `, ${level === null ? 'konfidensintervall' : `${level} % konfidensintervall`} ` +
        `fra ${lower} til ${upper}`
  return `Størrelse: ${estimate}${unit}${measure}${interval}.`
}

function NewEvidenceEntry({
  evidence,
}: {
  readonly evidence: NewEvidenceSummary
}): React.JSX.Element {
  const magnitude = magnitudeSentence(evidence)
  return (
    <li className="inbox-item">
      <h3>{evidence.articleTitle}</h3>
      <p className="inbox-item__article">
        {evidence.articleAuthors}
        {evidence.publishedYear === null ? '' : `, ${String(evidence.publishedYear)}`}.{' '}
        {label(evidence.studyDesign, STUDY_DESIGN_LABELS)}
        {evidence.participants === null
          ? ''
          : `, ${renderedText(formatNumber(evidence.participants), 'antall')} deltakere`}
        .
      </p>
      {evidence.population === null ? null : <p>Populasjon: {evidence.population}.</p>}
      <p>{evidence.finding}</p>
      <p>{label(evidence.direction, REPORTED_DIRECTION_LABELS)}.</p>
      {magnitude === null ? null : <p>{magnitude}</p>}
      {evidence.limitations === null ? null : (
        <p className="notice">Forbehold fra kilden: {evidence.limitations}</p>
      )}
    </li>
  )
}

export function ClaimRevisionPage({
  reference,
  gateway,
}: ClaimRevisionPageProps): React.JSX.Element {
  const [task, setTask] = useState<ClaimRevisionTask | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [done, setDone] = useState(false)

  useEffect(() => {
    let cancelled = false
    gateway
      .read(reference)
      .then((row) => {
        if (!cancelled) {
          setTask(row)
          setError(null)
        }
      })
      .catch((cause: unknown) => {
        if (!cancelled) {
          setTask(null)
          setError(pageMessage(cause))
        }
      })
    return () => {
      cancelled = true
    }
  }, [gateway, reference])

  const decide = useCallback(
    (decision: ClaimRevisionDecision) => {
      if (task === null) {
        return
      }
      const problem = decisionProblem(decision, note)
      if (problem !== null) {
        setNotice(problem)
        return
      }
      setBusy(true)
      setNotice(null)
      void (async () => {
        try {
          const outcome = await gateway.decide({
            reference: task.reference,
            decision,
            // Uendret fra det siden faktisk viste.
            seenEvidenceBasis: task.evidenceBasis,
            note,
          })
          setNotice(decisionOutcomeSentence(outcome))
          setDone(true)
        } catch (cause: unknown) {
          setNotice(pageMessage(cause))
        } finally {
          setBusy(false)
        }
      })()
    },
    [gateway, note, task],
  )

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Ny forskning</p>
      {error !== null ? (
        <>
          <h1>Oppgaven er ikke tilgjengelig</h1>
          <p className="notice">{error}</p>
          <p>
            <Link to={claimRevisionQueuePath()}>Til listen over påstander</Link>
          </p>
        </>
      ) : task === null ? (
        <>
          <h1>Henter oppgaven …</h1>
        </>
      ) : (
        <>
          <h1>
            {task.subjectDrug} — {task.topic}
          </h1>
          <section aria-labelledby="dagens-paastand">
            <h2 id="dagens-paastand">Det Antidep sier i dag</h2>
            <p className="lead">{task.statement}</p>
            <p>{task.scope}</p>
            {task.uncertaintySummary === null ? null : <p>Usikkerhet: {task.uncertaintySummary}</p>}
            <p>
              Formulering nummer {String(task.revisionNumber)}, bygget på{' '}
              {String(task.existingEvidenceCount)} kilder.
              {task.certaintyLevel === null
                ? ' Ingen evidensvurdering er registrert.'
                : ` Evidensen er vurdert som ${label(task.certaintyLevel, CERTAINTY_LABELS)}.`}
              {task.published ? ' Påstanden er publisert og i bruk nå.' : ' Ikke publisert ennå.'}
            </p>
          </section>
          <section aria-labelledby="ny-forskning">
            <h2 id="ny-forskning">Dette er kommet til</h2>
            <p>{newEvidenceSentence(task)}</p>
            <ul className="inbox-list">
              {task.newEvidence.map((evidence, index) => (
                <NewEvidenceEntry evidence={evidence} key={`${evidence.articleTitle}-${index}`} />
              ))}
            </ul>
          </section>
          <section aria-labelledby="avgjorelsen">
            <h2 id="avgjorelsen">Avgjørelsen</h2>
            <p>
              Skal påstanden skrives om med den nye forskningen? Sier du ja, setter Antidep i gang
              selv: teksten formuleres på nytt med hele det oppdaterte grunnlaget, kontrolleres mot
              kildene og vurderes på nytt, og du får den til sluttkontroll når den er ferdig.
            </p>
            <p>
              <label htmlFor="begrunnelse">
                Begrunnelse (påkrevd hvis den nye forskningen ikke endrer påstanden)
              </label>
              <br />
              <textarea
                disabled={busy || done}
                id="begrunnelse"
                onChange={(event) => {
                  setNote(event.target.value)
                }}
                rows={3}
                value={note}
              />
            </p>
            <p>
              <button
                disabled={busy || done}
                onClick={() => {
                  decide('revise')
                }}
                type="button"
              >
                Skriv påstanden om med den nye forskningen
              </button>{' '}
              <button
                disabled={busy || done}
                onClick={() => {
                  decide('set_aside')
                }}
                type="button"
              >
                Den nye forskningen endrer ikke påstanden
              </button>
            </p>
            {notice === null ? null : (
              <p aria-live="polite" className={done ? undefined : 'notice'}>
                {notice}
              </p>
            )}
            <p>
              <Link to={claimRevisionQueuePath()}>Til listen over påstander</Link>
            </p>
          </section>
        </>
      )}
    </main>
  )
}
