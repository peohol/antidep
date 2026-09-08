// ============================================================================
// Kildekontroll av ett evidensfunn — `/extraction-review/:evidenceItemId`
//
// Her gjøres den menneskelige kontrollen ANTIDEP_CONSTITUTION.md §11 krever:
// gjengir denne ekstraksjonen det kilden faktisk rapporterer? Flaten viser hele
// grunnlaget — kilden med sin status, kildeversjonen med adresse og
// fingeravtrykk, hele den strukturerte ekstraksjonen, den rå ekstraksjonen,
// feltdekningen slik publiseringsgaten regner den, kontrollene som allerede
// finnes med sine åpne funn, og hvilke påstander funnet allerede bærer.
//
// ----------------------------------------------------------------------------
// Dette er ikke den faglige vurderingen av en påstand
//
// Kontrollen av ekstraksjonen mot kilden (EVIDENCE_PIPELINE.md §25) og
// kontrollen av at grunnlaget støtter påstanden (§39) er to forskjellige
// spørsmål om to forskjellige objekter, og publiseringsgaten krever dem hver for
// seg (G5 og G9). Derfor er de to flater og ikke én.
//
// ----------------------------------------------------------------------------
// Ingenting er forhåndsutfylt som om det var vurdert
//
// Ingen felter er huket av på forhånd: `checked_fields` starter tom, fordi en
// avhuking er en påstand om at revieweren faktisk har sammenlignet feltet med
// kilden. Kildetilgangen starter på den svakeste verdien og utfallet på det mest
// forbeholdne, slik at en reviewer som ikke rører feltet, ikke har hevdet mer
// enn hen så (ANTIDEP_CONSTITUTION.md §6).
//
// ----------------------------------------------------------------------------
// Ingen validering som gjentar databasens
//
// At en bekreftelse krever at kildepekeren er kontrollert, at et annet utfall
// enn «bekreftet» krever et funn, at en bekreftelse ikke kan hvile på et
// sammendrag alene, og at ingen kan kontrollere sin egen ekstraksjon — alt
// håndheves av constraintene og triggerne på tabellen, og deres avvisninger
// vises ordrett (DATABASE_ARCHITECTURE.md §43, §57). Det flaten gjør, er å si det
// på forhånd, slik at regelen ikke er en overraskelse.
//
// ----------------------------------------------------------------------------
// Avtrykket sendes tilbake uendret
//
// Skriveveien får avtrykket av grunnlaget slik flaten faktisk viste det. Endres
// kildeversjonen, kildens status eller kontrollhistorikken mens vurderingen
// pågår, avvises registreringen — og det er riktig: kontrollen gjelder det
// revieweren faktisk så.
// ============================================================================

import { useCallback, useId, useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router'
import {
  CheckFieldCoveragePanel,
  ExtractionFieldsPanel,
  ExtractionSourcePanel,
  ExtractionVerificationHistoryPanel,
  LinkedClaimsPanel,
  RawExtractionPanel,
} from '../../components/ExtractionDossier'
import {
  EVIDENCE_CHECK_FIELD_LABELS,
  VERIFICATION_OUTCOME_LABELS,
  VERIFICATION_SOURCE_ACCESS_LABELS,
  termText,
} from '../../components/vocabulary-labels'
import { readEvidenceCheckField } from '../../lib/evidence-item'
import { registerHumanExtractionVerification } from '../../lib/register-human-extraction-verification'
import { fetchExtractionReview } from '../../lib/extraction-review'
import { VERIFICATION_OUTCOMES, VERIFICATION_SOURCE_ACCESSES } from '../../types/api'
import { useAntidepClient } from '../antidep-client'
import { useAuthSession, type AuthSessionState } from '../use-auth-session'
import { usePageTitle } from '../use-page-title'
import { useReadModel } from '../use-read-model'
import { accessPath, claimReviewPath, extractionReviewQueuePath } from '../routes'
import type { ExtractionReviewWorkspace } from '../../lib/extraction-review'
import type { Uuid } from '../../types/api'

function SignedOutNotice() {
  return (
    <div className="knowledge-notice knowledge-notice--absence" role="note">
      <p className="knowledge-notice__lead">Du må logge inn for å kontrollere et evidensfunn.</p>
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

function ExtractionVerificationForm({
  workspace,
  onRegistered,
}: {
  readonly workspace: ExtractionReviewWorkspace
  readonly onRegistered: () => void
}) {
  const availability = useAntidepClient()
  const { item } = workspace
  // Ingen felter er huket av på forhånd. En avhuking er en påstand om at
  // revieweren faktisk har sammenlignet feltet med kilden, og en forhåndsutfylt
  // liste ville gjort den påstanden på hens vegne.
  const [checked, setChecked] = useState<readonly string[]>([])
  // Den svakeste kildetilgangen og det mest forbeholdne utfallet er
  // utgangspunktet, av samme grunn.
  const [sourceAccess, setSourceAccess] = useState('derived_summary')
  const [outcome, setOutcome] = useState('uncertain')
  const [rationale, setRationale] = useState('')
  const [findings, setFindings] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)

  const fieldsId = useId()
  const accessId = useId()
  const outcomeId = useId()
  const rationaleId = useId()
  const findingsId = useId()

  const hasVerifiableVersion =
    item.dossier.sourceVersion !== null && item.dossier.sourceVersion.contentHash !== null

  function toggle(field: string) {
    setChecked((current) =>
      current.includes(field) ? current.filter((entry) => entry !== field) : [...current, field],
    )
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (availability.status !== 'ready') {
      return
    }
    setSubmitting(true)
    setProblem(null)
    const result = await registerHumanExtractionVerification(availability.client, {
      evidenceItemId: item.dossier.evidenceItemId,
      seenExtractionDigest: item.extractionDigest,
      outcome,
      sourceAccess,
      checkedFields: checked,
      rationale,
      findings: blankToNull(findings),
    })
    setSubmitting(false)
    if (result.status === 'error') {
      setProblem(result.message)
      return
    }
    onRegistered()
  }

  return (
    <form className="admin-form admin-form--review" onSubmit={(event) => void handleSubmit(event)}>
      <h3>Registrer din kontroll av ekstraksjonen</h3>
      <p className="admin-form__intro">
        Kontrollen gjelder om raden gjengir det kilden faktisk rapporterer. Huk av bare de feltene
        du selv har sammenlignet med kilden — et felt du ikke har sett på, er ikke et kontrollert
        felt. En bekreftelse krever at du har kontrollert hvor i kilden funnet står, og et annet
        utfall enn «Bekreftet» krever at du sier hva som er galt.
      </p>

      <fieldset className="admin-form__section">
        <legend id={fieldsId}>Hvilke felter har du faktisk kontrollert?</legend>
        <p className="admin-form__hint">
          Ingen er huket av på forhånd. Publiseringsgaten krever at de registrerte kontrollene til
          sammen dekker hvert felt funnet påstår noe om; se «Feltdekning» over for hva som står
          igjen.
        </p>
        <ul className="check-fields" aria-labelledby={fieldsId}>
          {item.requiredCheckFields.map((field) => (
            <li key={field}>
              <label>
                <input
                  checked={checked.includes(field)}
                  onChange={() => toggle(field)}
                  type="checkbox"
                  value={field}
                />
                {termText(
                  readEvidenceCheckField(field),
                  EVIDENCE_CHECK_FIELD_LABELS,
                  'kontrollfelt',
                )}
              </label>
            </li>
          ))}
        </ul>
      </fieldset>

      <div className="admin-form__field">
        <label htmlFor={accessId}>Hva hadde du tilgang til?</label>
        <select
          id={accessId}
          onChange={(event) => setSourceAccess(event.target.value)}
          value={sourceAccess}
        >
          {VERIFICATION_SOURCE_ACCESSES.map((value) => (
            <option
              disabled={value === 'verifiable_representation' && !hasVerifiableVersion}
              key={value}
              value={value}
            >
              {VERIFICATION_SOURCE_ACCESS_LABELS[value]}
            </option>
          ))}
        </select>
        {hasVerifiableVersion ? null : (
          <p className="admin-form__hint">
            Dette funnet har ingen kildeversjon med registrert fingeravtrykk, så kontrollen din kan
            ikke knyttes til en etterprøvbar representasjon. Registrer kildeversjonen først hvis
            kontrollen skal kunne bygge på den.
          </p>
        )}
      </div>

      <div className="admin-form__field">
        <label htmlFor={outcomeId}>Samlet utfall</label>
        <select id={outcomeId} onChange={(event) => setOutcome(event.target.value)} value={outcome}>
          {VERIFICATION_OUTCOMES.map((value) => (
            <option key={value} value={value}>
              {VERIFICATION_OUTCOME_LABELS[value]}
            </option>
          ))}
        </select>
        <p className="admin-form__hint">
          «Uavklart» er ikke et mildere «Bekreftet»: publiseringsgaten blokkerer på begge de tre
          andre utfallene, og det er meningen.
        </p>
      </div>

      <div className="admin-form__field">
        <label htmlFor={rationaleId}>Hvordan gjennomførte du kontrollen?</label>
        <textarea
          id={rationaleId}
          onChange={(event) => setRationale(event.target.value)}
          required
          rows={4}
          value={rationale}
        />
      </div>

      <div className="admin-form__field">
        <label htmlFor={findingsId}>Funn (påkrevd når utfallet ikke er «Bekreftet»)</label>
        <textarea
          id={findingsId}
          onChange={(event) => setFindings(event.target.value)}
          rows={3}
          value={findings}
        />
      </div>

      {problem === null ? null : (
        <p className="admin-form__problem" role="alert">
          Kontrollen ble ikke registrert. {problem}
        </p>
      )}

      <button disabled={submitting} type="submit">
        {submitting ? 'Registrerer …' : 'Registrer kontrollen'}
      </button>
    </form>
  )
}

function ExtractionReviewView({
  workspace,
  onRegistered,
}: {
  readonly workspace: ExtractionReviewWorkspace
  readonly onRegistered: () => void
}) {
  const { item } = workspace
  // Køen utelater funn kalleren selv har laget, men et direkte oppslag når dem
  // fortsatt. Da sier flaten hvorfor de ikke kan kontrolleres, framfor å tilby
  // et skjema databasen uansett ville avvist
  // (evidence_verifications_separate_actor_check).
  const isOwnExtraction = item.dossier.createdByActorId === workspace.reviewerActorId

  return (
    <>
      <ExtractionSourcePanel item={item.dossier} />
      <ExtractionFieldsPanel item={item.dossier} />
      <RawExtractionPanel raw={item.dossier.extraction.rawExtraction} />
      <CheckFieldCoveragePanel item={item} />
      <ExtractionVerificationHistoryPanel
        currentId={item.currentExtractionVerificationId}
        records={item.extractionVerifications}
      />
      <LinkedClaimsPanel
        hrefFor={(revision) => claimReviewPath(revision.claimRevisionId)}
        revisions={item.linkedClaimRevisions}
      />
      {isOwnExtraction ? (
        <div className="knowledge-notice knowledge-notice--absence" role="note">
          <p className="knowledge-notice__lead">
            Du har selv registrert denne ekstraksjonen, og kan derfor ikke kontrollere den.
          </p>
          <p className="knowledge-notice__caveat">
            Generering og kontroll skal være atskilte operasjoner (ANTIDEP_CONSTITUTION.md §10). En
            annen kvalifisert person eller en ekstraksjonsverifikator må gjøre kontrollen.
          </p>
        </div>
      ) : (
        <ExtractionVerificationForm onRegistered={onRegistered} workspace={workspace} />
      )}
    </>
  )
}

function ExtractionReviewFetch({
  evidenceItemId,
  onRegistered,
}: {
  readonly evidenceItemId: Uuid
  readonly onRegistered: () => void
}) {
  const query = useCallback(
    (client: Parameters<typeof fetchExtractionReview>[0]) =>
      fetchExtractionReview(client, evidenceItemId),
    [evidenceItemId],
  )
  const review = useReadModel(query)

  switch (review.status) {
    case 'loading':
      return (
        <p
          className="knowledge-notice knowledge-notice--loading"
          aria-busy="true"
          aria-live="polite"
        >
          Henter grunnlaget …
        </p>
      )
    case 'error':
      return (
        <div className="knowledge-notice knowledge-notice--error" role="alert">
          <p className="knowledge-notice__lead">
            Antidep fikk ikke hentet grunnlaget. Dette er en teknisk feil, ikke et svar om at
            ekstraksjonen er i orden — grunnlaget under er ufullstendig eller helt fraværende.
          </p>
          <p className="knowledge-notice__detail">Teknisk årsak: {review.message}</p>
          <p className="knowledge-notice__caveat">
            Mangler kontoen din reviewer-rollen for dette endepunktet, står grunnen i teksten over.{' '}
            <Link to={accessPath()}>Se «Min tilgang»</Link>.
          </p>
        </div>
      )
    case 'ok':
      return <ExtractionReviewView onRegistered={onRegistered} workspace={review.workspace} />
  }
}

/**
 * Henter grunnlaget på nytt etter hver registrering.
 *
 * Både kontrollhistorikken, feltdekningen og avtrykket endrer seg av en
 * registrering, og en flate som fortsatte å vise det forrige svaret, ville vist
 * en dekning som ikke lenger gjelder — og sendt et utdatert avtrykk ved neste
 * forsøk.
 *
 * Ny henting utløses ved å montere hentekomponenten på nytt (`key`). Det tømmer
 * samtidig skjemaet, som er riktig: avhukingene beskrev kontrollen som nå er
 * registrert, og en gjenstående utfylling ville sett ut som en påbegynt ny.
 */
function ExtractionReviewLookup({ evidenceItemId }: { readonly evidenceItemId: Uuid }) {
  const [reloadToken, setReloadToken] = useState(0)
  return (
    <ExtractionReviewFetch
      evidenceItemId={evidenceItemId}
      key={reloadToken}
      onRegistered={() => setReloadToken((token) => token + 1)}
    />
  )
}

function ExtractionReviewBody({
  authState,
  evidenceItemId,
}: {
  readonly authState: AuthSessionState
  readonly evidenceItemId: string | undefined
}) {
  if (evidenceItemId === undefined) {
    return (
      <div className="knowledge-notice knowledge-notice--absence" role="note">
        <p className="knowledge-notice__lead">Adressen peker ikke på et evidensfunn.</p>
        <p className="knowledge-notice__caveat">
          <Link to={extractionReviewQueuePath()}>Gå til køen</Link> og velg et funn derfra.
        </p>
      </div>
    )
  }
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
      return <ExtractionReviewLookup evidenceItemId={evidenceItemId} key={authState.userId} />
  }
}

export function ExtractionReviewPage() {
  usePageTitle('Kildekontroll av evidensfunn')
  const authState = useAuthSession()
  const { evidenceItemId } = useParams()

  return (
    <>
      <p className="page-kicker">
        <Link to={extractionReviewQueuePath()}>Kildekontroll</Link>
      </p>
      <h2>Kildekontroll av evidensfunn</h2>
      <ExtractionReviewBody authState={authState} evidenceItemId={evidenceItemId} />
    </>
  )
}
