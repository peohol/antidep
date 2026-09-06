// ============================================================================
// Registrer kildeversjon — `/source-versions/new`
//
// Leddet mellom «Editor oppretter Source» og «Editor registrerer EvidenceItem»
// (MVP_IMPLEMENTATION_PLAN.md §15, issue #44). En kilde opprettet gjennom
// `/sources/new` har ingen registrert versjon, og et evidensfunn på den har da
// ingenting å kontrolleres mot: `verifiable_representation` forutsetter en
// adresse og et fingeravtrykk (§74.32).
//
// ----------------------------------------------------------------------------
// Hvorfor skjemaet ber om innholdet og ikke om hashen
//
// Fingeravtrykket beregnes av databasen (migrasjon 007f). En redaktør som
// oppga en hash, ville oppgitt en garanti hen ikke kan stå for — og en hash
// ingen kan etterprøve, er verre enn ingen hash. Skjemaet ber derfor om
// representasjonen ordrett, og forklarer hvordan man får tak i den.
//
// Feltet er bevisst en `textarea` uten formattering, uten «lim inn som ren
// tekst»-magi og uten trimming: hashen skal reproduseres av `sha256sum` på
// svaret fra adressen, så alt som endrer én byte, endrer svaret. Det er ikke en
// svakhet ved skjemaet — det er selve mekanismen, og teksten på siden sier det.
//
// ----------------------------------------------------------------------------
// Ingen rollegate, bare en innloggingsgate
//
// Samme doktrine som `CreateSourcePage.tsx` og `CreateEvidenceItemPage.tsx`:
// `knowledge.assert_editor_authorized(uuid)` tar avgjørelsen på sitt eget
// tidspunkt, og en klient som skjulte skjemaet ville lovet noe den ikke kan
// stå for (DATABASE_ARCHITECTURE.md §43, §48).
// ============================================================================

import { useId, useState, type FormEvent } from 'react'
import { Link } from 'react-router'
import { createSourceVersion } from '../../lib/create-source-version'
import { fetchEditorSources } from '../../lib/editor-read-model'
import { localInputValueToIso, nowAsLocalInputValue } from '../../lib/local-datetime'
import { sourceChoice } from '../../lib/source-choice'
import { useAntidepClient } from '../antidep-client'
import { useAuthSession, type AuthSessionState } from '../use-auth-session'
import { usePageTitle } from '../use-page-title'
import { useReadModel } from '../use-read-model'
import { accessPath, newEvidenceItemPath, newSourcePath } from '../routes'
import type { CreateSourceVersionResult } from '../../lib/create-source-version'
import type { EditorSourceRow, Uuid } from '../../types/api'

function SignedOutNotice() {
  return (
    <div className="knowledge-notice knowledge-notice--absence" role="note">
      <p className="knowledge-notice__lead">Du må logge inn for å registrere en kildeversjon.</p>
      <p className="knowledge-notice__caveat">
        <Link to={accessPath()}>Logg inn under «Min tilgang»</Link>, og kom tilbake hit.
      </p>
    </div>
  )
}

/** Tom streng fra et valgfritt tekstfelt betyr «ikke oppgitt», ikke en verdi å lagre. */
function blankToNull(value: string): string | null {
  return value.trim().length === 0 ? null : value
}

interface FormState {
  readonly sourceId: string
  readonly retrievedAt: string
  readonly retrievedFrom: string
  readonly retrievedContent: string
  readonly externalVersion: string
  readonly storageReference: string
}

function CreatedNotice({ sourceVersionId }: { readonly sourceVersionId: Uuid }) {
  return (
    <div className="knowledge-notice knowledge-notice--ok" role="status">
      <p className="knowledge-notice__lead">Kildeversjonen er registrert.</p>
      <p className="knowledge-notice__detail">
        Kildeversjonens id: <code>{sourceVersionId}</code>
      </p>
      <p className="knowledge-notice__detail">
        Fingeravtrykket er beregnet av databasen av innholdet du limte inn. Neste steg er å{' '}
        <Link to={newEvidenceItemPath()}>registrere et evidensfunn</Link> som peker på denne
        versjonen.
      </p>
    </div>
  )
}

type SubmitStatus = 'idle' | 'submitting'

function SourceVersionForm({ sources }: { readonly sources: readonly EditorSourceRow[] }) {
  const availability = useAntidepClient()
  const [form, setForm] = useState<FormState>(() => ({
    sourceId: sources[0]?.source_id ?? '',
    retrievedAt: nowAsLocalInputValue(),
    retrievedFrom: '',
    retrievedContent: '',
    externalVersion: '',
    storageReference: '',
  }))
  const [status, setStatus] = useState<SubmitStatus>('idle')
  const [result, setResult] = useState<CreateSourceVersionResult | null>(null)
  const [problem, setProblem] = useState<string | null>(null)

  const sourceId = useId()
  const retrievedAtId = useId()
  const retrievedFromId = useId()
  const contentId = useId()
  const contentHelpId = useId()
  const externalVersionId = useId()
  const storageId = useId()
  const problemId = useId()

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (availability.status !== 'ready') {
      return
    }

    // Den ene kontrollen skjemaet gjør selv, og den handler om form og ikke om
    // innhold: `datetime-local` kan ikke uttrykke en tidssone, så verdien må
    // bygges om før den sendes. Alt annet er databasens dom.
    const retrievedAt = localInputValueToIso(form.retrievedAt)
    if (retrievedAt === null) {
      setProblem('Oppgi når representasjonen ble hentet.')
      return
    }
    setProblem(null)

    setStatus('submitting')
    const outcome = await createSourceVersion(availability.client, {
      sourceId: form.sourceId as Uuid,
      retrievedAt,
      retrievedFrom: form.retrievedFrom,
      // Ikke trimmet: hashen skal være hashen av det som faktisk ble hentet.
      retrievedContent: form.retrievedContent,
      externalVersion: blankToNull(form.externalVersion),
      storageReference: blankToNull(form.storageReference),
    })
    setStatus('idle')
    setResult(outcome)
    if (outcome.status === 'ok') {
      setForm({
        sourceId: form.sourceId,
        retrievedAt: nowAsLocalInputValue(),
        retrievedFrom: '',
        retrievedContent: '',
        externalVersion: '',
        storageReference: '',
      })
    }
  }

  return (
    <>
      {result?.status === 'ok' ? <CreatedNotice sourceVersionId={result.sourceVersionId} /> : null}
      {result?.status === 'error' ? (
        <div className="knowledge-notice knowledge-notice--error" role="alert">
          <p className="knowledge-notice__lead">Kildeversjonen ble ikke registrert.</p>
          <p className="knowledge-notice__detail">Teknisk årsak: {result.message}</p>
        </div>
      ) : null}

      <form className="admin-form" onSubmit={(event) => void handleSubmit(event)}>
        <div className="admin-form__field">
          <label htmlFor={sourceId}>Kilde</label>
          <select
            id={sourceId}
            onChange={(event) => setForm({ ...form, sourceId: event.target.value })}
            required
            value={form.sourceId}
          >
            {sources.map(sourceChoice).map((choice) => (
              <option key={choice.value} value={choice.value}>
                {choice.label}
              </option>
            ))}
          </select>
        </div>

        <div className="admin-form__field">
          <label htmlFor={retrievedFromId}>Adressen representasjonen ble hentet fra</label>
          <input
            id={retrievedFromId}
            onChange={(event) => setForm({ ...form, retrievedFrom: event.target.value })}
            required
            type="text"
            value={form.retrievedFrom}
          />
        </div>

        <div className="admin-form__field">
          <label htmlFor={retrievedAtId}>Da den ble hentet</label>
          <input
            aria-describedby={problem === null ? undefined : problemId}
            id={retrievedAtId}
            onChange={(event) => setForm({ ...form, retrievedAt: event.target.value })}
            required
            type="datetime-local"
            value={form.retrievedAt}
          />
        </div>

        <div className="admin-form__field">
          <label htmlFor={contentId}>Representasjonen, ordrett</label>
          <textarea
            aria-describedby={contentHelpId}
            id={contentId}
            onChange={(event) => setForm({ ...form, retrievedContent: event.target.value })}
            required
            rows={12}
            value={form.retrievedContent}
          />
          <p className="admin-form__hint" id={contentHelpId}>
            Lim inn svaret fra adressen nøyaktig slik det er, uten å redigere det. Antidep beregner
            et fingeravtrykk (sha256) av teksten, og det er fingeravtrykket som gjør at en
            kontrollør senere kan hente adressen på nytt og se om kilden har endret seg. Ett tegn
            fra eller til gir et annet fingeravtrykk.
          </p>
        </div>

        <div className="admin-form__field">
          <label htmlFor={externalVersionId}>Kildens eget versjonsmerke (valgfritt)</label>
          <input
            id={externalVersionId}
            onChange={(event) => setForm({ ...form, externalVersion: event.target.value })}
            type="text"
            value={form.externalVersion}
          />
        </div>

        <div className="admin-form__field">
          <label htmlFor={storageId}>Peker til lagret kopi (valgfritt)</label>
          <input
            id={storageId}
            onChange={(event) => setForm({ ...form, storageReference: event.target.value })}
            type="text"
            value={form.storageReference}
          />
        </div>

        {problem === null ? null : (
          <p className="admin-form__problem" id={problemId} role="alert">
            {problem}
          </p>
        )}

        <button disabled={status === 'submitting'} type="submit">
          {status === 'submitting' ? 'Registrerer …' : 'Registrer kildeversjon'}
        </button>
      </form>
    </>
  )
}

function SourceVersionLookup() {
  const sources = useReadModel(fetchEditorSources)

  switch (sources.status) {
    case 'loading':
      return (
        <p
          className="knowledge-notice knowledge-notice--loading"
          aria-busy="true"
          aria-live="polite"
        >
          Henter kilder …
        </p>
      )
    case 'error':
      return (
        <div className="knowledge-notice knowledge-notice--error" role="alert">
          <p className="knowledge-notice__lead">Antidep fikk ikke hentet kildene.</p>
          <p className="knowledge-notice__detail">Teknisk årsak: {sources.message}</p>
        </div>
      )
    case 'none':
      return (
        <div className="knowledge-notice knowledge-notice--absence" role="note">
          <p className="knowledge-notice__lead">
            Du har ingen kilder å registrere en kildeversjon for.
          </p>
          <p className="knowledge-notice__caveat">
            Det betyr enten at kontoen din ikke har redaktørrettigheter ennå, eller at ingen kilde
            er opprettet. <Link to={accessPath()}>Se «Min tilgang»</Link> for hva kontoen din har,
            og <Link to={newSourcePath()}>opprett en kilde</Link> hvis den mangler.
          </p>
        </div>
      )
    case 'ok':
      return <SourceVersionForm sources={sources.rows} />
  }
}

function CreateSourceVersionBody({ authState }: { readonly authState: AuthSessionState }) {
  switch (authState.status) {
    case 'loading':
      return (
        <p
          className="knowledge-notice knowledge-notice--loading"
          aria-busy="true"
          aria-live="polite"
        >
          Sjekker innloggingen …
        </p>
      )
    case 'unavailable':
      return (
        <div className="knowledge-notice knowledge-notice--error" role="alert">
          <p className="knowledge-notice__lead">Antidep fikk ikke sjekket innloggingen din.</p>
          <p className="knowledge-notice__detail">Teknisk årsak: {authState.message}</p>
        </div>
      )
    case 'signed_out':
      return <SignedOutNotice />
    case 'signed_in':
      return <SourceVersionLookup key={authState.userId} />
  }
}

export function CreateSourceVersionPage() {
  usePageTitle('Registrer kildeversjon')
  const authState = useAuthSession()

  return (
    <>
      <p className="page-kicker">Admin</p>
      <h2>Registrer kildeversjon</h2>
      <p className="admin-form__intro">
        En kildeversjon er øyeblikksbildet Antidep faktisk leste: hvilken adresse, når, og hva
        innholdet var. Den gjør et evidensfunn etterprøvbart — en kontrollør kan hente adressen på
        nytt og se om kilden har endret seg siden funnet ble registrert.
      </p>
      <CreateSourceVersionBody authState={authState} />
    </>
  )
}
