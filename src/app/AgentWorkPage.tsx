// ============================================================================
// Agentarbeid: den operative flaten for Antidep → ekstern KI-agent → Antidep
//
// Antidep har ingen modellnøkkel og skal ikke ha en. Det semantiske arbeidet
// gjøres av KI-agenter eieren allerede har tilgang til, og den uunngåelige
// manuelle grensen er tre handlinger:
//
//   1. last ned oppgaven
//   2. last den opp i et chatvindu og be agenten utføre den
//   3. last opp svaret her
//
// Alt annet gjør Antidep selv. Siden viser derfor ingen filnavn, ingen interne
// id-er og ingen pipelinebegreper: det er tre knapper og en setning om hva som
// skjedde.
//
// ----------------------------------------------------------------------------
// «Venter på deg» og «kan ikke kjøres ennå» er to forskjellige tilstander
//
// En oppgave hvis grunnlag ikke er på plass, står med sin egen setning om hva
// som mangler, og uten nedlastingsknapp. En flate som viste de to likt, ville
// bedt noen gjøre noe som ikke går — og en teknisk feil ville sett ut som
// «ingenting å gjøre» (ANTIDEP_CONSTITUTION.md regel 4).
//
// ----------------------------------------------------------------------------
// Kontrollene kjøres før svaret sendes, men de er ikke grensen
//
// Flaten leser svaret, kontrollerer bindingen og kjører de samme
// deterministiske kontrollene kjederunnerne bruker, slik at et menneske får en
// setning på norsk om hva som er galt. Databasen gjør deretter hele
// kontrollen om igjen på sin side, av sine egne rader. Det som avgjør, er
// databasens svar.
//
// Utrygg inndata: svarfilen er data. React escaper all tekst, og ingenting her
// tolker en verdi som markup.
// ============================================================================

import { useCallback, useEffect, useRef, useState, type ChangeEvent } from 'react'

import {
  HANDOFF_CONTRACTS,
  type AgentTask,
  type AgentWorkItem,
  type ImportOutcome,
} from '../agents/agent-task'
import { answerBindingProblem, parseAgentAnswer, parseAnswerJson } from '../agents/agent-answer'
import { agentTaskFileName, renderAgentTaskFile } from '../agents/agent-task-file'
import { handoffResultProblem } from '../agents/handoff-result'
import { describeModelIdentity } from '../agents/model-identity'
import type { AgentWorkGateway } from './agent-work-gateway'

/** Hvordan en fil havner hos brukeren. Byttes ut i prøver. */
export type SaveFile = (name: string, text: string) => void

/**
 * Nedlastingen, slik en nettleser gjør den.
 *
 * Ligger bak en port fordi en prøve ikke har noe filsystem å laste ned til, og
 * fordi en prøve skal kunne lese nøyaktig den filen brukeren ville fått.
 */
const saveFileInBrowser: SaveFile = (name, text) => {
  const blob = new Blob([text], { type: 'text/markdown;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = name
  document.body.append(link)
  link.click()
  link.remove()
  URL.revokeObjectURL(url)
}

/** Hva som sist skjedde med én oppgave, i klartekst. */
interface ItemStatus {
  readonly tone: 'venter' | 'ok' | 'feil'
  readonly message: string
}

function outcomeMessage(outcome: ImportOutcome): string {
  const what = describeOutcome(outcome.outcome)
  const model = outcome.model === null ? '' : ` Utført av ${describeModelIdentity(outcome.model)}.`
  if (outcome.alreadyImported) {
    return `Dette svaret var allerede registrert, og ingenting nytt ble skrevet.${what}${model}`
  }
  return `Svaret er godtatt og registrert.${what}${model} Antidep fortsetter kjeden herfra.`
}

/**
 * Hva importen faktisk laget, i ord.
 *
 * Interne id-er vises ikke: de sier ingenting til den som skal lese setningen,
 * og en flate full av uuid-er er en flate som krever at man kan lese en
 * database.
 */
function describeOutcome(outcome: Record<string, unknown>): string {
  if (typeof outcome['evidence_item_id'] === 'string') {
    return ' Ett evidensfunn er registrert.'
  }
  if (typeof outcome['claim_revision_id'] === 'string') {
    return ' Én påstandsformulering er registrert.'
  }
  if (typeof outcome['evidence_assessment_id'] === 'string') {
    return ' Evidensvurderingen er registrert.'
  }
  return ''
}

export interface AgentWorkPageProps {
  readonly gateway: AgentWorkGateway
  /** Byttes ut i prøver. Standard er nettleserens egen nedlasting. */
  readonly saveFile?: SaveFile
}

export function AgentWorkPage({ gateway, saveFile }: AgentWorkPageProps): React.JSX.Element {
  const [items, setItems] = useState<readonly AgentWorkItem[] | null>(null)
  const [unknownRoles, setUnknownRoles] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [statuses, setStatuses] = useState<Readonly<Record<string, ItemStatus>>>({})
  const [busy, setBusy] = useState<string | null>(null)
  // Oppgaven som ble lastet ned sist for hver rad. Svaret kontrolleres mot den
  // før det sendes, slik at et menneske får en setning på norsk framfor en
  // SQLSTATE. Er den ikke der, hentes den på nytt ved opplasting.
  const tasks = useRef(new Map<string, AgentTask>())

  const load = useCallback(() => {
    let cancelled = false
    gateway
      .listQueue()
      .then((queue) => {
        if (!cancelled) {
          setItems(queue.items)
          setUnknownRoles(queue.unknownRoles)
          setError(null)
        }
      })
      .catch((cause: unknown) => {
        if (!cancelled) {
          setItems(null)
          setError(cause instanceof Error ? cause.message : String(cause))
        }
      })
    return () => {
      cancelled = true
    }
  }, [gateway])

  useEffect(load, [load])

  const setStatus = useCallback((id: string, status: ItemStatus) => {
    setStatuses((current) => ({ ...current, [id]: status }))
  }, [])

  const download = useCallback(
    async (item: AgentWorkItem) => {
      setBusy(item.pipelineJobId)
      setStatus(item.pipelineJobId, { tone: 'venter', message: 'Henter oppgaven …' })
      try {
        const task = await gateway.readTask(item.pipelineJobId)
        tasks.current.set(item.pipelineJobId, task)
        ;(saveFile ?? saveFileInBrowser)(agentTaskFileName(task), renderAgentTaskFile(task))
        setStatus(item.pipelineJobId, {
          tone: 'venter',
          message:
            'Oppgaven er lastet ned. Last filen opp i KI-tjenesten og skriv: «Utfør ' +
            'Antidep-oppgaven i den vedlagte filen.» Last deretter opp svarfilen her.',
        })
      } catch (cause) {
        setStatus(item.pipelineJobId, {
          tone: 'feil',
          message: cause instanceof Error ? cause.message : String(cause),
        })
      } finally {
        setBusy(null)
      }
    },
    [gateway, saveFile, setStatus],
  )

  const upload = useCallback(
    async (item: AgentWorkItem, file: File) => {
      setBusy(item.pipelineJobId)
      setStatus(item.pipelineJobId, { tone: 'venter', message: 'Leser svaret …' })
      try {
        const text = await file.text()
        const parsed = parseAgentAnswer(parseAnswerJson(text))

        // Oppgaven hentes på nytt dersom den ikke ligger i økta. Da fanges også
        // det tilfellet at grunnlaget er endret siden nedlastingen: oppgaven får
        // et annet avtrykk, og svaret gjelder ikke lenger.
        const task =
          tasks.current.get(item.pipelineJobId) ?? (await gateway.readTask(item.pipelineJobId))
        tasks.current.set(item.pipelineJobId, task)

        const bindingIssue = answerBindingProblem(task, parsed)
        if (bindingIssue !== null) {
          setStatus(item.pipelineJobId, { tone: 'feil', message: bindingIssue })
          return
        }
        const resultIssue = handoffResultProblem(task, parsed.result)
        if (resultIssue !== null) {
          setStatus(item.pipelineJobId, {
            tone: 'feil',
            message: `Svaret holdt ikke mål, og ingenting er registrert. ${resultIssue}`,
          })
          return
        }

        const outcome = await gateway.importAnswer(
          item.pipelineJobId,
          parseAnswerJson(text) as Record<string, unknown>,
        )
        setStatus(item.pipelineJobId, { tone: 'ok', message: outcomeMessage(outcome) })
        load()
      } catch (cause) {
        setStatus(item.pipelineJobId, {
          tone: 'feil',
          message: cause instanceof Error ? cause.message : String(cause),
        })
      } finally {
        setBusy(null)
      }
    },
    [gateway, load, setStatus],
  )

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Agentarbeid</p>
      <h1>Oppgaver til KI-agentene</h1>
      <p className="lead">
        Antidep lager oppgaven og kontrollerer svaret. Selve lesingen og utkastet gjøres av en
        KI-tjeneste du allerede bruker. Last ned oppgaven, gi den til tjenesten, og last opp
        svarfilen her.
      </p>
      <p className="notice">
        Oppgavefilen kan inneholde hele forskningsartikkelen. Den er ment å gå rett fra denne siden
        og inn i KI-tjenesten — ikke i e-post, ikke i et delt dokument og ikke i et kodelager.
      </p>

      {error !== null ? (
        <p className="notice">{error}</p>
      ) : items === null ? (
        <p>Henter oppgavene …</p>
      ) : items.length === 0 ? (
        <p>Ingen agentoppgaver venter nå.</p>
      ) : (
        <ul>
          {items.map((item) => (
            <AgentWorkRow
              key={item.pipelineJobId}
              busy={busy === item.pipelineJobId}
              item={item}
              onDownload={() => void download(item)}
              onUpload={(file) => void upload(item, file)}
              status={statuses[item.pipelineJobId] ?? null}
            />
          ))}
        </ul>
      )}

      {unknownRoles > 0 ? (
        <p className="notice">
          {unknownRoles === 1
            ? 'Én oppgave gjelder et agentledd denne versjonen av Antidep ikke kan vise ennå.'
            : `${String(unknownRoles)} oppgaver gjelder agentledd denne versjonen av Antidep ikke kan vise ennå.`}
        </p>
      ) : null}
    </main>
  )
}

interface AgentWorkRowProps {
  readonly item: AgentWorkItem
  readonly status: ItemStatus | null
  readonly busy: boolean
  readonly onDownload: () => void
  readonly onUpload: (file: File) => void
}

function AgentWorkRow({
  item,
  status,
  busy,
  onDownload,
  onUpload,
}: AgentWorkRowProps): React.JSX.Element {
  const contract = HANDOFF_CONTRACTS[item.role]
  const uploadId = `svar-${item.pipelineJobId}`

  const chooseFile = (event: ChangeEvent<HTMLInputElement>): void => {
    const file = event.target.files?.[0]
    if (file !== undefined) {
      onUpload(file)
    }
    // Den samme filen valgt to ganger skal gi to forsøk. Uten dette ville
    // nettleseren sett den andre gangen som «ingen endring».
    event.target.value = ''
  }

  return (
    <li>
      <h2>{item.subjectLabel}</h2>
      <p>
        <strong>{contract.label}.</strong> {contract.summary}
      </p>

      {item.registeredModel === null ? (
        <p>
          Ingen KI-modell er registrert for dette leddet ennå. Den som svarer først, blir leddets
          modell — og ingen andre ledd kan da bruke den samme.
        </p>
      ) : (
        <p>Skal utføres av {describeModelIdentity(item.registeredModel)}.</p>
      )}

      {item.answered ? (
        <p>Besvart og registrert. Antidep har tatt arbeidet videre.</p>
      ) : item.blockedReason !== null ? (
        <p className="notice">Kan ikke utføres ennå: {item.blockedReason}</p>
      ) : (
        <>
          {item.failureReason !== null ? (
            <p className="notice">Forrige forsøk stoppet: {item.failureReason}</p>
          ) : null}
          <p>
            <button disabled={busy} onClick={onDownload} type="button">
              Last ned oppgaven
            </button>
          </p>
          <p>
            <label htmlFor={uploadId}>Last opp svaret fra KI-tjenesten</label>{' '}
            <input
              accept="application/json,.json,.txt"
              disabled={busy}
              id={uploadId}
              onChange={chooseFile}
              type="file"
            />
          </p>
        </>
      )}

      {status !== null ? (
        <p aria-live="polite" className={status.tone === 'ok' ? undefined : 'notice'}>
          {status.message}
        </p>
      ) : null}
    </li>
  )
}
