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
// Hvilken tjeneste som gjør hvert ledd, velges her — og først
//
// Valget er en attestert avgjørelse, tatt av den som faktisk har tilgangen, før
// oppgaven hentes ut. Det er ikke en innstilling for ryddighetens skyld: lot vi
// svaret oppgi sin egen identitet ved første import, ville separasjonen mellom
// generator og kontroll hvilt på en erklæring modellen avga om seg selv, og et
// feil navn ville gått klar av regelen om at to ledd ikke deler modell
// (ANTIDEP_CONSTITUTION.md regel 3). Valget inngår derfor i oppgavens avtrykk,
// og byttes tjenesten, gjelder ikke de utestående oppgavene lenger.
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
import type { AgentWorkGateway, RoleModelChoice } from './agent-work-gateway'

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

/**
 * Hva som faktisk skjedde, og hva som ikke skjedde.
 *
 * Setningen lover ikke at kjeden går videre av seg selv. De uavhengige
 * kontrollene som følger, er Antideps egen deterministiske kode og kjøres ennå
 * ikke herfra (docs/ROADMAP.md) — og en flate som sa noe annet, ville gjort en
 * manglende kontroll til en utført (ANTIDEP_CONSTITUTION.md regel 4).
 */
function outcomeMessage(outcome: ImportOutcome): string {
  const what = describeOutcome(outcome.outcome)
  const model = outcome.model === null ? '' : ` Utført av ${describeModelIdentity(outcome.model)}.`
  if (outcome.alreadyImported) {
    return `Dette svaret var allerede registrert, og ingenting nytt ble skrevet.${what}${model}`
  }
  return (
    `Svaret er godtatt og registrert.${what}${model} Det neste leddet er en uavhengig ` +
    'kontroll, og den kjøres ennå ikke fra denne siden.'
  )
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

  const assign = useCallback(
    async (item: AgentWorkItem, choice: Omit<RoleModelChoice, 'role' | 'reason'>) => {
      setBusy(item.pipelineJobId)
      setStatus(item.pipelineJobId, { tone: 'venter', message: 'Registrerer valget …' })
      try {
        const assignment = await gateway.assignRoleModel({
          ...choice,
          role: item.role,
          reason: null,
        })
        // Oppgavene som lå i økta, ble bygget for den forrige tjenesten. De har
        // et annet avtrykk nå, og en oppgave som fortsatt lå der, ville gitt et
        // svar databasen måtte avvise. Hele hurtiglageret tømmes: tildelingen
        // gjelder agentleddet, og flere rader kan gjelde det samme leddet.
        tasks.current.clear()
        setStatus(item.pipelineJobId, {
          tone: 'ok',
          message: assignment.replaced
            ? `Leddet utføres nå av ${describeModelIdentity(assignment.model)}. Oppgaver som ` +
              'allerede var lastet ned, gjelder ikke lenger — last dem ned på nytt.'
            : `Leddet skal utføres av ${describeModelIdentity(assignment.model)}.`,
        })
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
              onAssign={(choice) => void assign(item, choice)}
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
  readonly onAssign: (choice: Omit<RoleModelChoice, 'role' | 'reason'>) => void
  readonly onDownload: () => void
  readonly onUpload: (file: File) => void
}

function AgentWorkRow({
  item,
  status,
  busy,
  onAssign,
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

      {item.answered ? (
        <p>
          Besvart og registrert. Det neste leddet er en uavhengig kontroll, og den kjøres ennå ikke
          fra denne siden.
        </p>
      ) : item.registeredModel === null ? (
        <ServicePicker busy={busy} item={item} onAssign={onAssign} />
      ) : (
        <>
          <p>Skal utføres av {describeModelIdentity(item.registeredModel)}.</p>
          <ServicePicker busy={busy} item={item} onAssign={onAssign} />

          {item.blockedReason !== null ? (
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

interface ServicePickerProps {
  readonly item: AgentWorkItem
  readonly busy: boolean
  readonly onAssign: (choice: Omit<RoleModelChoice, 'role' | 'reason'>) => void
}

/**
 * Valget av KI-tjeneste for ett agentledd.
 *
 * Ingen liste over leverandører er hardkodet. Antidep kan ikke vite hvilke
 * tjenester eieren faktisk har tilgang til, og en liste ville enten utelatt den
 * ene som fantes eller foreslått en som ikke gjorde det. Feltene er derfor fri
 * tekst, og navnet skal være det tjenesten selv viser.
 *
 * Versjonsfeltet er valgfritt med vilje: de fleste chattjenester oppgir ingen
 * eksakt build, og «vet ikke» registreres da som nettopp det framfor som en
 * oppdiktet versjon (ANTIDEP_CONSTITUTION.md regel 4).
 */
function ServicePicker({ item, busy, onAssign }: ServicePickerProps): React.JSX.Element {
  const [provider, setProvider] = useState('')
  const [model, setModel] = useState('')
  const [version, setVersion] = useState('')
  const [why, setWhy] = useState('')

  const switching = item.registeredModel !== null
  const field = (name: string): string => `${name}-${item.pipelineJobId}`
  const ready = provider.trim() !== '' && model.trim() !== '' && (!switching || why.trim() !== '')

  const submit = (event: React.FormEvent): void => {
    event.preventDefault()
    if (!ready) {
      return
    }
    onAssign({
      provider: provider.trim(),
      model: model.trim(),
      modelVersion: version.trim() === '' ? null : version.trim(),
      replacesReason: switching ? why.trim() : null,
    })
  }

  const fields = (
    <form onSubmit={submit}>
      <p>
        <label htmlFor={field('tjeneste')}>Tjeneste</label>{' '}
        <input
          disabled={busy}
          id={field('tjeneste')}
          onChange={(event) => setProvider(event.target.value)}
          placeholder="for eksempel openai"
          value={provider}
        />
      </p>
      <p>
        <label htmlFor={field('modell')}>Modellnavn, slik tjenesten viser det</label>{' '}
        <input
          disabled={busy}
          id={field('modell')}
          onChange={(event) => setModel(event.target.value)}
          value={model}
        />
      </p>
      <p>
        <label htmlFor={field('versjon')}>Eksakt versjon, dersom tjenesten oppgir en</label>{' '}
        <input
          disabled={busy}
          id={field('versjon')}
          onChange={(event) => setVersion(event.target.value)}
          value={version}
        />
      </p>
      {switching ? (
        <p>
          <label htmlFor={field('hvorfor')}>Hvorfor byttes tjenesten</label>{' '}
          <input
            disabled={busy}
            id={field('hvorfor')}
            onChange={(event) => setWhy(event.target.value)}
            value={why}
          />
        </p>
      ) : null}
      <p>
        <button disabled={busy || !ready} type="submit">
          {switching ? 'Bytt tjeneste' : 'Velg tjeneste'}
        </button>
      </p>
    </form>
  )

  if (switching) {
    return (
      <details>
        <summary>Bytt KI-tjeneste for dette agentleddet</summary>
        <p>
          Byttet blir stående med hvem og hvorfor, og oppgaver som allerede er lastet ned, gjelder
          ikke lenger. Den samme tjenesten kan ikke gjøre to av leddene i kjeden.
        </p>
        {fields}
      </details>
    )
  }

  return (
    <>
      <p>
        Velg hvilken KI-tjeneste dette agentleddet skal utføres av. Valget må gjøres før oppgaven
        kan hentes ut, og den samme tjenesten kan ikke gjøre to av leddene i kjeden: da ville en
        kontroll vært den samme vurderingen gjort to ganger.
      </p>
      {fields}
    </>
  )
}
