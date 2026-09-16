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
  HANDOFF_ROLES,
  type AgentRunnerConnection,
  type AgentRunnerPairingCode,
  type AgentTask,
  type AgentWorkItem,
  type ImportOutcome,
} from '../agents/agent-task'
import { answerBindingProblem, parseAgentAnswer, parseAnswerJson } from '../agents/agent-answer'
import { agentTaskFileName, renderAgentTaskFile } from '../agents/agent-task-file'
import { handoffResultProblem } from '../agents/handoff-result'
import { describeModelIdentity } from '../agents/model-identity'
import type { AgentWorkGateway, RoleModelChoice, RunnerRegistration } from './agent-work-gateway'

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
  const [runners, setRunners] = useState<RunnerListing>({ state: 'loading' })
  // Oppgaven som ble lastet ned sist for hver rad. Svaret kontrolleres mot den
  // før det sendes, slik at et menneske får en setning på norsk framfor en
  // SQLSTATE. Er den ikke der, hentes den på nytt ved opplasting.
  const tasks = useRef(new Map<string, AgentTask>())

  const loadRunners = useCallback(() => {
    // Ingen tilbakestilling til «henter» her: en oppfriskning etter en
    // registrering skal ikke blinke bort listen som allerede står der.
    gateway
      .listRunners()
      .then((connections) => {
        setRunners({ state: 'loaded', connections })
      })
      // En kjørerliste som ikke kan leses, skal ikke ta ned agentkøen: den
      // manuelle veien virker uten den, og det er hele poenget med at den
      // består. Men den skal heller ikke bli til en tom liste: «ingen kjører er
      // registrert» er et svar, og et svar er nettopp det vi ikke har. Da ville
      // et nettverksavbrudd sett ut som at alt agentarbeid gjøres manuelt —
      // mens en kjører kanskje arbeider akkurat nå.
      .catch((cause: unknown) => {
        setRunners({
          state: 'failed',
          reason: cause instanceof Error ? cause.message : String(cause),
        })
      })
  }, [gateway])

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
  useEffect(loadRunners, [loadRunners])

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

  // Køen er det som venter, så en oppgave som er besvart, forsvinner fra den.
  // Setningen om hva som faktisk ble registrert, skal ikke forsvinne med raden:
  // den som nettopp lastet opp et svar, skal få vite hva det ble til
  // (ANTIDEP_CONSTITUTION.md regel 4).
  const waiting = new Set((items ?? []).map((item) => item.pipelineJobId))
  const finished = items === null ? [] : Object.entries(statuses).filter(([id]) => !waiting.has(id))

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

      <AutonomousRunners gateway={gateway} onChanged={loadRunners} runners={runners} />

      {finished.length > 0 ? (
        <section>
          <h2>Nettopp registrert</h2>
          {finished.map(([id, status]) => (
            <p aria-live="polite" className={status.tone === 'ok' ? undefined : 'notice'} key={id}>
              {status.message}
            </p>
          ))}
        </section>
      ) : null}

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

      {item.registeredModel === null ? (
        <ServicePicker busy={busy} item={item} onAssign={onAssign} />
      ) : (
        <>
          <p>Skal utføres av {describeModelIdentity(item.registeredModel)}.</p>

          {item.heldByRunner !== null ? (
            // Arbeidet pågår automatisk akkurat nå. «Blokkert» ville vært feil
            // ord, og en flate som sa det, ville bedt noen gripe inn i noe som
            // går av seg selv (ANTIDEP_CONSTITUTION.md regel 4).
            <p>Utføres automatisk nå av {item.heldByRunner}.</p>
          ) : item.blockedReason !== null ? (
            // Ingen «bytt tjeneste» her. Byttet gjelder agentleddet, og en rad
            // som ikke kan utføres, er ikke stedet å ta den avgjørelsen —
            // byttet ville ikke gjort den utførbar.
            <p className="notice">Kan ikke utføres ennå: {item.blockedReason}</p>
          ) : (
            <>
              <ServicePicker busy={busy} item={item} onAssign={onAssign} />
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

// ---------------------------------------------------------------------------
// Den autonome kjøreren
//
// Registreringen er en avgjørelse om hvem som utfører kjedens arbeid, og den
// hører hjemme her — hos den som har tilgangen, i den samme flaten som valget av
// KI-tjeneste. Nedlast/opplast-veien over består uansett: den er fallback når en
// planlagt kjøring er nede, den er nyttig ved feilsøking, og den er veien inn
// for en tjeneste uten en autonom integrasjon.
//
// Engangskoden vises én gang og lagres aldri i klartekst. Siden sier det, fordi
// en kode som ser ut som noe man kan hente igjen, er en kode noen lar bli
// liggende.
// ---------------------------------------------------------------------------

/** Én setning om hva plattformen faktisk viser om modellen bak kjøreren. */
function describeDisclosure(value: string): string {
  return value === 'platform_pinned'
    ? 'Plattformen pinner modellen, og separasjonen mellom agentleddene kan etterprøves der.'
    : 'Plattformen oppgir ikke hvilken modell agenten kjører. Separasjonen hviler da på ' +
        'modelltildelingen over, ikke på plattformen — og Antidep later ikke som noe annet.'
}

/** «Én oppgave» eller «N oppgaver» — tallet skal kunne leses som en setning. */
function describeReleased(count: number): string {
  return count === 1 ? 'Én oppgave den holdt,' : `${String(count)} oppgaver den holdt,`
}

/**
 * Tre tilstander, fordi de betyr tre forskjellige ting for den som leser siden.
 *
 * «Henter» er ikke et svar, «ingen kjørere» er et svar, og «kunne ikke leses»
 * er fraværet av et svar. Slås de to siste sammen, sier siden noe den ikke vet.
 */
type RunnerListing =
  | { readonly state: 'loading' }
  | { readonly state: 'loaded'; readonly connections: readonly AgentRunnerConnection[] }
  | { readonly state: 'failed'; readonly reason: string }

interface AutonomousRunnersProps {
  readonly gateway: AgentWorkGateway
  readonly runners: RunnerListing
  readonly onChanged: () => void
}

function AutonomousRunners({
  gateway,
  runners,
  onChanged,
}: AutonomousRunnersProps): React.JSX.Element {
  const [code, setCode] = useState<AgentRunnerPairingCode | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const act = useCallback(
    async (work: () => Promise<string | null>) => {
      setBusy(true)
      setMessage(null)
      try {
        const said = await work()
        if (said !== null) {
          setMessage(said)
        }
        onChanged()
      } catch (cause) {
        setMessage(cause instanceof Error ? cause.message : String(cause))
      } finally {
        setBusy(false)
      }
    },
    [onChanged],
  )

  const issue = (connectionKey: string): void => {
    void act(async () => {
      const issued = await gateway.issuePairingCode(connectionKey)
      setCode(issued)
      return null
    })
  }

  const revoke = (connectionKey: string): void => {
    void act(async () => {
      const revocation = await gateway.revokeRunner(
        connectionKey,
        'Trukket tilbake fra agentarbeidsflaten av den som eier innholdet.',
      )
      setCode(null)
      // Hvor mye arbeid som ble ledig igjen, er det den som eier innholdet
      // faktisk trenger å vite: kjøreren kommer ikke tilbake for å levere det,
      // og oppgavene skal kunne gjøres av den som overtar leddet.
      return revocation.releasedTasks === 0
        ? 'Kjøreren er trukket tilbake, og tokenene sluttet å gjelde med det samme.'
        : `Kjøreren er trukket tilbake, og tokenene sluttet å gjelde med det samme. ${describeReleased(revocation.releasedTasks)} ble ledig igjen.`
    })
  }

  const register = (registration: RunnerRegistration): void => {
    void act(async () => {
      await gateway.registerRunner(registration)
      return 'Kjøreren er registrert. Hent en tilkoblingskode når du kobler den til.'
    })
  }

  return (
    <section>
      <h2>Autonom kjører</h2>
      <p>
        En planlagt KI-agent kan hente arbeidet selv, utføre det og levere svaret tilbake gjennom de
        samme kontrollene. Den får arbeid i nøyaktig ett agentledd, og ingen databasetilgang utover
        det. Nedlastingen og opplastingen over virker uansett.
      </p>

      {runners.state === 'loading' ? (
        <p>Henter kjørerne …</p>
      ) : runners.state === 'failed' ? (
        <p className="notice" role="status">
          Kjørerlisten kunne ikke leses, så siden vet ikke om noen autonom kjører finnes:{' '}
          {runners.reason} Nedlastingen og opplastingen over virker uansett.
        </p>
      ) : runners.connections.length === 0 ? (
        <p>Ingen autonom kjører er registrert. Alt agentarbeid gjøres manuelt.</p>
      ) : (
        <ul>
          {runners.connections.map((runner) => (
            <li key={runner.connectionKey}>
              <h3>{runner.displayName}</h3>
              <p>
                Utfører{' '}
                {HANDOFF_CONTRACTS[runner.role as keyof typeof HANDOFF_CONTRACTS]?.label ??
                  runner.role}
                . Agent: {runner.platformAgentReference}.{' '}
                {runner.connected ? 'Tilkoblet nå.' : 'Ikke tilkoblet.'}{' '}
                {runner.deliveredAnswers === 0
                  ? 'Har ikke levert noe svar ennå.'
                  : runner.deliveredAnswers === 1
                    ? 'Har levert ett svar.'
                    : `Har levert ${String(runner.deliveredAnswers)} svar.`}
              </p>
              <p className="notice">{describeDisclosure(runner.platformModelDisclosure)}</p>
              <p>
                <button disabled={busy} onClick={() => issue(runner.connectionKey)} type="button">
                  Hent tilkoblingskode
                </button>{' '}
                <button disabled={busy} onClick={() => revoke(runner.connectionKey)} type="button">
                  Trekk tilbake
                </button>
              </p>
            </li>
          ))}
        </ul>
      )}

      {code !== null ? (
        <p aria-live="polite">
          Tilkoblingskode for {code.displayName}: <code>{code.pairingCode}</code>. Lim den inn i
          tilkoblingsvinduet. Den gjelder én gang og utløper {code.expiresAt}. Koden vises bare nå.
        </p>
      ) : null}

      {message !== null ? (
        <p aria-live="polite" className="notice">
          {message}
        </p>
      ) : null}

      <RunnerForm busy={busy} onRegister={register} />
    </section>
  )
}

interface RunnerFormProps {
  readonly busy: boolean
  readonly onRegister: (registration: RunnerRegistration) => void
}

/**
 * Registreringen av én kjører.
 *
 * Ingen liste over plattformer er hardkodet, av samme grunn som i
 * `ServicePicker`: Antidep kan ikke vite hvilke agentplattformer eieren faktisk
 * har. Feltene er fri tekst, og navnet skal være det plattformen selv viser.
 */
function RunnerForm({ busy, onRegister }: RunnerFormProps): React.JSX.Element {
  const [role, setRole] = useState<string>(HANDOFF_ROLES[0])
  const [name, setName] = useState('')
  const [reference, setReference] = useState('')
  const [pinned, setPinned] = useState(false)

  const ready = name.trim() !== '' && reference.trim() !== ''

  const submit = (event: React.FormEvent): void => {
    event.preventDefault()
    if (!ready) {
      return
    }
    onRegister({
      // Nøkkelen utledes av rollen framfor å være enda et felt å fylle ut: den
      // er maskinlesbar, og et menneske har ingenting å bidra med der.
      connectionKey: `agent-runner:${role.replaceAll('_', '-')}`,
      displayName: name.trim(),
      role,
      platformAgentReference: reference.trim(),
      platformModelDisclosure: pinned ? 'platform_pinned' : 'not_exposed',
      reason: null,
    })
    setName('')
    setReference('')
  }

  return (
    <form onSubmit={submit}>
      <h3>Registrer en kjører</h3>
      <p>
        <label htmlFor="runner-role">Agentledd</label>{' '}
        <select
          disabled={busy}
          id="runner-role"
          onChange={(event) => {
            setRole(event.target.value)
          }}
          value={role}
        >
          {HANDOFF_ROLES.map((value) => (
            <option key={value} value={value}>
              {HANDOFF_CONTRACTS[value].label}
            </option>
          ))}
        </select>
      </p>
      <p>
        <label htmlFor="runner-name">Navn på kjøreren</label>{' '}
        <input
          disabled={busy}
          id="runner-name"
          onChange={(event) => {
            setName(event.target.value)
          }}
          type="text"
          value={name}
        />
      </p>
      <p>
        <label htmlFor="runner-reference">Agentens navn i plattformen</label>{' '}
        <input
          disabled={busy}
          id="runner-reference"
          onChange={(event) => {
            setReference(event.target.value)
          }}
          type="text"
          value={reference}
        />
      </p>
      <p>
        <label htmlFor="runner-pinned">
          <input
            checked={pinned}
            disabled={busy}
            id="runner-pinned"
            onChange={(event) => {
              setPinned(event.target.checked)
            }}
            type="checkbox"
          />{' '}
          Plattformen pinner og viser hvilken modell agenten kjører
        </label>
      </p>
      <p>
        <button disabled={busy || !ready} type="submit">
          Registrer kjøreren
        </button>
      </p>
    </form>
  )
}
