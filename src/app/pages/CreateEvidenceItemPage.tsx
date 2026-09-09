// ============================================================================
// Registrer evidensfunn — `/evidence/new`
//
// Steg 3 av «manuell adminflyt» (MVP_IMPLEMENTATION_PLAN.md §29): «Editor
// registrerer EvidenceItem» (§15), leddet etter «Editor oppretter Source».
// Verifikasjon av ekstraksjonen, ClaimRevision, claim-evidenslenker, review og
// publisering hører til senere PR-er (§51).
//
// ----------------------------------------------------------------------------
// Ingen rollegate her heller — bare en innloggingsgate
//
// Samme doktrine som `CreateSourcePage.tsx`: skjemaet vises til enhver innlogget
// bruker, og retten kontrolleres av `knowledge.assert_editor_authorized(uuid)`
// på sitt eget kall (DATABASE_ARCHITECTURE.md §43, §48). Det er ikke bare et
// prinsipp her: for et evidensfunn avhenger retten av *endepunktet* funnet
// gjelder, fordi en editor-tildeling kan være avgrenset til ett klinisk begrep
// (migrasjon 007e). En klient som gjettet på svaret måtte gjettet per endepunkt,
// og ville tatt feil så snart en tildeling ble endret.
//
// De redaksjonelle oppslagene er derimot styrt av RLS, og en kaller uten
// editor-rolle ser ingen kilder. Siden sier da at det ikke finnes noe å
// registrere mot *for denne brukeren* — ikke at kunnskapsbasen er tom.
//
// ----------------------------------------------------------------------------
// Null/ukjent-semantikken er skjemaets form
//
// Fem felter på et evidensfunn bærer en `*_availability`, og databasen håndhever
// at verdien finnes hvis og bare hvis statusen sier det (§19.1). Skjemaet spør
// derfor alltid om statusen først, og viser verdifeltet bare når statusen er en
// av de to som betyr at kilden faktisk oppgir noe. Det gjør det umulig å fylle
// ut et par databasen ville avvist — og, viktigere, det tvinger fram et svar på
// *hvorfor* et tall mangler framfor å la feltet stå tomt
// (ANTIDEP_CONSTITUTION.md §6, §17). Kanoniseringen ligger i
// `lib/evidence-registration.ts`.
//
// ----------------------------------------------------------------------------
// Bekreftelsen viser funnet under kilden, ikke bare en id
//
// Kravet fra oppgaven denne siden løser er at registreringen skal kunne ses
// under riktig kilde. Etter et vellykket kall leses derfor
// `api.editor_evidence_items` på nytt for den kilden, og listen står som
// bekreftelse. Den viser bevisst ikke estimat, konfidensintervall,
// utvalgsstørrelse eller tidsrom: de fire bærer hver sin status, og et tall vist
// uten sin status er falsk presisjon (§6). Den fulle visningen av et funn hører
// til evidensdrilldownen, som bygger på publisert kunnskap.
// ============================================================================

import { useCallback, useId, useMemo, useState, type FormEvent, type ReactNode } from 'react'
import { Link } from 'react-router'
import { GroundingFieldset } from '../../components/GroundingFieldset'
import {
  COMPARATOR_KIND_LABELS,
  DRUG_STATUS_LABELS,
  EVIDENCE_CHECK_FIELD_LABELS,
  EXTRACTION_METHOD_LABELS,
  MEASURE_LABELS,
  REPORTED_DIRECTION_LABELS,
  STUDY_DESIGN_LABELS,
  UNIT_LABELS,
  VALUE_AVAILABILITY_LABELS,
  VOCABULARY_STATUS_LABELS,
  termText,
} from '../../components/vocabulary-labels'
import { describeClaimComparator } from '../../lib/claim-effect'
import { createEvidenceItem } from '../../lib/create-evidence-item'
import { collectFieldGroundings, type GroundingDraft } from '../../lib/grounding-draft'
import { sourceChoice, withStatus, type Choice } from '../../lib/source-choice'
import {
  fetchEditorDrugs,
  fetchEditorEvidenceItems,
  fetchEditorOutcomes,
  fetchEditorPopulations,
  fetchEditorSourceVersions,
  fetchEditorSources,
} from '../../lib/editor-read-model'
import {
  EMPTY_CONFIDENCE_INTERVAL_DRAFT,
  EMPTY_NUMBER_DRAFT,
  EMPTY_POPULATION_DRAFT,
  EMPTY_TIMEPOINT_DRAFT,
  TIMEPOINT_UNITS,
  availabilityHasValue,
  canonicalConfidenceInterval,
  canonicalNumber,
  canonicalPopulation,
  canonicalTimepoint,
  type EvidenceConfidenceIntervalDraft,
  type EvidenceNumberDraft,
  type EvidencePopulationDraft,
  type EvidenceTimepointDraft,
  type TimepointUnit,
} from '../../lib/evidence-registration'
import {
  readDrugStatus,
  readExtractionMethod,
  readReportedDirection,
  readStudyDesign,
  readVocabularyStatus,
} from '../../lib/evidence-item'
import {
  formatTimestampAsDate,
  formatTimestampWithClock,
  renderedText,
} from '../../lib/norwegian-format'
import {
  COMPARATOR_KINDS,
  EFFECT_MEASURES,
  ESTIMATE_UNITS,
  REPORTED_DIRECTIONS,
  STUDY_DESIGNS,
  VALUE_AVAILABILITIES,
} from '../../types/api'
import { useAntidepClient } from '../antidep-client'
import { useAuthSession, type AuthSessionState } from '../use-auth-session'
import { usePageTitle } from '../use-page-title'
import { useReadModel } from '../use-read-model'
import { accessPath, newSourcePath } from '../routes'
import type { CreateEvidenceItemResult } from '../../lib/create-evidence-item'
import type { EditorReadResult } from '../../lib/editor-read-model'
import type {
  EditorDrugRow,
  EditorEvidenceItemRow,
  EditorOutcomeRow,
  EditorPopulationRow,
  EditorSourceRow,
  EditorSourceVersionRow,
  Uuid,
  ValueAvailability,
} from '../../types/api'

// ----------------------------------------------------------------------------
// Små byggeklosser for skjemaet
//
// Feltene deler oppsett, id-håndtering og hjelpetekst. Skrevet ut for hånd
// tretti ganger ville `htmlFor`/`id` og `aria-describedby` før eller siden kommet
// i utakt i ett av dem, og et felt uten etikett er usynlig for en skjermleser.
// ----------------------------------------------------------------------------

interface ControlProps {
  readonly id: string
  readonly 'aria-describedby': string | undefined
}

function Field({
  label,
  hint,
  children,
}: {
  readonly label: string
  readonly hint?: string | undefined
  readonly children: (props: ControlProps) => ReactNode
}) {
  const id = useId()
  const hintId = useId()
  return (
    <div className="admin-form__field">
      <label htmlFor={id}>{label}</label>
      {children({ id, 'aria-describedby': hint === undefined ? undefined : hintId })}
      {hint === undefined ? null : (
        <p className="admin-form__hint" id={hintId}>
          {hint}
        </p>
      )}
    </div>
  )
}

function SelectField({
  label,
  hint,
  value,
  choices,
  onChange,
  required,
  disabled,
}: {
  readonly label: string
  readonly hint?: string | undefined
  readonly value: string
  readonly choices: readonly Choice[]
  readonly onChange: (value: string) => void
  readonly required?: boolean | undefined
  readonly disabled?: boolean | undefined
}) {
  return (
    <Field hint={hint} label={label}>
      {(props) => (
        <select
          {...props}
          disabled={disabled}
          onChange={(event) => onChange(event.target.value)}
          required={required}
          value={value}
        >
          {choices.map((choice) => (
            <option key={choice.value} value={choice.value}>
              {choice.label}
            </option>
          ))}
        </select>
      )}
    </Field>
  )
}

function TextField({
  label,
  hint,
  value,
  onChange,
  required,
  inputMode,
}: {
  readonly label: string
  readonly hint?: string | undefined
  readonly value: string
  readonly onChange: (value: string) => void
  readonly required?: boolean | undefined
  readonly inputMode?: 'decimal' | 'numeric' | undefined
}) {
  return (
    <Field hint={hint} label={label}>
      {(props) => (
        <input
          {...props}
          inputMode={inputMode}
          onChange={(event) => onChange(event.target.value)}
          required={required}
          type="text"
          value={value}
        />
      )}
    </Field>
  )
}

function TextAreaField({
  label,
  hint,
  value,
  onChange,
  required,
}: {
  readonly label: string
  readonly hint?: string | undefined
  readonly value: string
  readonly onChange: (value: string) => void
  readonly required?: boolean | undefined
}) {
  return (
    <Field hint={hint} label={label}>
      {(props) => (
        <textarea
          {...props}
          onChange={(event) => onChange(event.target.value)}
          required={required}
          rows={3}
          value={value}
        />
      )}
    </Field>
  )
}

/** Statusvalget som hører til et felt med null/ukjent-semantikk. */
const AVAILABILITY_CHOICES: readonly Choice[] = VALUE_AVAILABILITIES.map((availability) => ({
  value: availability,
  label: VALUE_AVAILABILITY_LABELS[availability],
}))

function AvailabilitySelect({
  label,
  hint,
  availability,
  onChange,
}: {
  readonly label: string
  readonly hint?: string | undefined
  readonly availability: ValueAvailability
  readonly onChange: (availability: ValueAvailability) => void
}) {
  return (
    <SelectField
      choices={AVAILABILITY_CHOICES}
      hint={hint}
      label={label}
      onChange={(value) => onChange(value as ValueAvailability)}
      value={availability}
    />
  )
}

// ----------------------------------------------------------------------------
// Etikettene i nedtrekkslistene
//
// En katalogoppføring som ikke lenger er i bruk merkes. Et virkestoff eller et
// begrep som er faset ut kan fortsatt være riktig for et funn fra en eldre
// publikasjon — å skjule dem ville gjort registreringen umulig framfor riktig —
// men det skal ikke se ut som alle andre valg.
// ----------------------------------------------------------------------------

/**
 * Hva kildeversjonsfeltet sier når det ikke finnes en liste å velge fra.
 *
 * De fire tekstene er bevisst forskjellige. «Ingen registrert kildeversjon» er
 * en påstand om kilden, og den skal ikke stå der svaret ennå er ukjent.
 */
/**
 * Nok av `sha256:…` til å skille to øyeblikksbilder, uten å fylle valglisten
 * med resten av hashen. Prefikset er ikke en identitet, bare et kjennemerke;
 * kolliderer to av dem, tar konstruksjonen under over.
 */
const HASH_PREFIX_LENGTH = 'sha256:'.length + 8

const VERSION_PLACEHOLDERS = {
  no_source: 'Velg kilden først',
  loading: 'Henter kildeversjoner …',
  error: 'Kildeversjonene kunne ikke hentes',
  none: 'Ingen registrert kildeversjon',
} as const

const TIMEPOINT_UNIT_LABELS: Record<TimepointUnit, string> = {
  days: 'Dager',
  weeks: 'Uker',
  months: 'Måneder',
  years: 'År',
}

/**
 * Komparatoren på ett registrert funn, som tekst.
 *
 * `comparator_drug_name` alene holder ikke: den er NULL både for placebo og for
 * et armspesifikt funn, og de to er ikke det samme — `none` betyr at funnet
 * gjelder én behandlingsarm, ikke at komparatoren er ukjent. En linje som
 * utelot begge ville vist en placebokontrollert studie som armspesifikk.
 *
 * Avledningen er den samme `describeClaimComparator()` evidensdrilldownen
 * bruker, med den samme kjøretidskontrollen: en kategori Antidep ikke kjenner
 * blir en eksplisitt ukjent tilstand framfor å falle i en godartet gren.
 */
function comparatorText(row: EditorEvidenceItemRow): string {
  const comparator = describeClaimComparator({
    drug_id: row.intervention_drug_id,
    comparator_kind: row.comparator_kind,
    comparator_drug_id: row.comparator_drug_id,
    comparator_drug_name: row.comparator_drug_name,
  })
  switch (comparator.kind) {
    case 'drug':
      return `mot ${comparator.drugName}`
    case 'placebo':
      return 'mot placebo'
    case 'none':
      return '(én behandlingsarm)'
    case 'unknown':
      return `(komparatoren er ikke tolkbar: «${comparator.rawComparatorKind}»)`
  }
}

/**
 * Et tidspunkt som norsk dato.
 *
 * Uten klokkeslett, som resten av flaten: `formatTimestampAsDate()` utelater
 * det med hensikt, og en registrering skal ikke vises med en presisjon de
 * kliniske datoene ved siden av ikke har.
 */
function registeredAt(raw: string): string {
  return renderedText(formatTimestampAsDate(raw), 'tidspunkt')
}

/**
 * Etikettene på kildeversjonene, garantert innbyrdes forskjellige.
 *
 * Feltets formål er å velge den *eksakte* representasjonen ekstraksjonen ble
 * lest av. To øyeblikksbilder av samme kilde er tillatt fra samme adresse samme
 * dag — `knowledge.source_versions` har ingen regel som hindrer det, og en
 * kilde hentet før og etter en korreksjon er nettopp et slikt par. Da må de to
 * være til å skille fra hverandre i valglisten: velges feil versjon, kan
 * koblingen ikke rettes i raden etterpå, fordi evidensfunn er append-only.
 *
 * Etiketten bærer derfor hentetidspunktet med klokkeslett, versjonsmerket
 * kilden selv oppgir når det finnes, begynnelsen av innholdshashen når den
 * finnes, og adressen. Skulle to etiketter *likevel* bli like — to hentinger
 * samme minutt fra samme adresse, uten versjonsmerke og uten hash — får de
 * kolliderende radene hele sin egen id lagt til. Hele, ikke en forkortelse:
 * poenget med den grenen er å være entydig ved konstruksjon, og et prefiks
 * ville flyttet antakelsen ett hakk framfor å fjerne den.
 */
function sourceVersionChoices(rows: readonly EditorSourceVersionRow[]): readonly Choice[] {
  const described = rows.map((version) => ({
    value: version.source_version_id,
    label: [
      renderedText(formatTimestampWithClock(version.retrieved_at), 'tidspunkt'),
      version.external_version,
      version.content_hash?.slice(0, HASH_PREFIX_LENGTH),
      version.retrieved_from,
    ]
      .filter((part): part is string => part !== null && part !== undefined && part.length > 0)
      .join(' — '),
  }))
  const seen = new Map<string, number>()
  for (const choice of described) {
    seen.set(choice.label, (seen.get(choice.label) ?? 0) + 1)
  }
  return described.map((choice) =>
    (seen.get(choice.label) ?? 0) > 1
      ? { ...choice, label: `${choice.label} — ${choice.value}` }
      : choice,
  )
}

function drugChoice(drug: EditorDrugRow): Choice {
  const status = readDrugStatus(drug.status)
  return {
    value: drug.drug_id,
    label:
      status.kind === 'known' && status.value === 'active'
        ? drug.canonical_name
        : withStatus(drug.canonical_name, termText(status, DRUG_STATUS_LABELS, 'status')),
  }
}

function vocabularyChoice(id: string, label: string, status: string): Choice {
  const read = readVocabularyStatus(status)
  return {
    value: id,
    label:
      read.kind === 'known' && read.value === 'active'
        ? label
        : withStatus(label, termText(read, VOCABULARY_STATUS_LABELS, 'status')),
  }
}

// ----------------------------------------------------------------------------
// Oppslagene skjemaet trenger før det kan vises
// ----------------------------------------------------------------------------

type LookupState =
  | { readonly status: 'loading' }
  | { readonly status: 'error'; readonly message: string }
  /** Kalleren ser ingenting å registrere mot. Ikke det samme som en feil. */
  | { readonly status: 'nothing_to_register' }
  | {
      readonly status: 'ready'
      readonly sources: readonly [EditorSourceRow, ...EditorSourceRow[]]
      readonly drugs: readonly [EditorDrugRow, ...EditorDrugRow[]]
      readonly outcomes: readonly [EditorOutcomeRow, ...EditorOutcomeRow[]]
      readonly populations: readonly EditorPopulationRow[]
    }

type Loaded<Row> = { readonly status: 'loading' } | EditorReadResult<Row>

/**
 * Slår de fire oppslagene sammen til én tilstand.
 *
 * Kilder, virkestoff og endepunkter er alle påkrevde kolonner på et evidensfunn,
 * så et tomt svar fra én av dem gjør registrering umulig — og siden må si det,
 * ikke vise et skjema med tomme lister. Populasjoner er valgfrie: et funn kan
 * registreres uten kobling til katalogen, med en registrert grunn.
 */
function combineLookups(
  sources: Loaded<EditorSourceRow>,
  drugs: Loaded<EditorDrugRow>,
  outcomes: Loaded<EditorOutcomeRow>,
  populations: Loaded<EditorPopulationRow>,
): LookupState {
  const all = [sources, drugs, outcomes, populations]
  const failed = all.find((result) => result.status === 'error')
  if (failed !== undefined && failed.status === 'error') {
    return { status: 'error', message: failed.message }
  }
  if (all.some((result) => result.status === 'loading')) {
    return { status: 'loading' }
  }
  if (sources.status !== 'ok' || drugs.status !== 'ok' || outcomes.status !== 'ok') {
    return { status: 'nothing_to_register' }
  }
  return {
    status: 'ready',
    sources: sources.rows,
    drugs: drugs.rows,
    outcomes: outcomes.rows,
    populations: populations.status === 'ok' ? populations.rows : [],
  }
}

// ----------------------------------------------------------------------------
// Bekreftelsen: funnet, under kilden det ble registrert på
// ----------------------------------------------------------------------------

/**
 * Listen over funn registrert på én kilde.
 *
 * Komponenten kjenner ikke til at den skal hente på nytt etter en registrering.
 * Kallstedet monterer den friskt med en `key` som endres for hver registrering,
 * og da kjører `useReadModel()` spørringen på nytt av seg selv — framfor at en
 * tellerverdi må smugles inn i en avhengighetsliste den ikke hører hjemme i.
 */
function RegisteredFindings({ sourceId }: { readonly sourceId: Uuid }) {
  const query = useCallback(
    (client: Parameters<typeof fetchEditorEvidenceItems>[0]) =>
      fetchEditorEvidenceItems(client, sourceId),
    [sourceId],
  )
  const findings = useReadModel(query)

  if (findings.status === 'loading') {
    return (
      <p className="knowledge-notice knowledge-notice--loading" aria-busy="true" aria-live="polite">
        Henter evidensfunnene som er registrert på kilden …
      </p>
    )
  }
  if (findings.status === 'error') {
    return (
      <div className="knowledge-notice knowledge-notice--error" role="alert">
        <p className="knowledge-notice__lead">
          Funnet er registrert, men Antidep fikk ikke hentet listen over funn på kilden.
        </p>
        <p className="knowledge-notice__detail">Teknisk årsak: {findings.message}</p>
      </div>
    )
  }
  if (findings.status === 'none') {
    return null
  }

  const [first] = findings.rows
  return (
    <section className="evidence-registered">
      <h3>Registrerte evidensfunn på «{first.source_title}»</h3>
      <ul className="evidence-registered__list">
        {findings.rows.map((row) => (
          <li className="evidence-registered__item" key={row.evidence_item_id}>
            <p className="evidence-registered__headline">
              {row.outcome_label}: {row.outcome_detail}
            </p>
            <p className="evidence-registered__meta">
              {termText(readStudyDesign(row.study_design), STUDY_DESIGN_LABELS, 'studiedesign')} ·{' '}
              {row.intervention_drug_name} {comparatorText(row)} ·{' '}
              {termText(
                readReportedDirection(row.reported_direction),
                REPORTED_DIRECTION_LABELS,
                'retning',
              )}
            </p>
            <p className="evidence-registered__meta">
              {row.source_locator} ·{' '}
              {termText(
                readExtractionMethod(row.extraction_method),
                EXTRACTION_METHOD_LABELS,
                'ekstraksjonsmetode',
              )}{' '}
              · {registeredAt(row.created_at)}
            </p>
          </li>
        ))}
      </ul>
      <p className="evidence-registered__caveat">
        Funnene er registrert, ikke kontrollert eller publisert. Kontroll mot kilden og faglig
        godkjenning er egne steg, og de er ikke bygget ennå.
      </p>
    </section>
  )
}

// ----------------------------------------------------------------------------
// Skjemaets egen tilstand
// ----------------------------------------------------------------------------

interface FormState {
  readonly sourceId: string
  readonly sourceVersionId: string
  readonly designCode: string
  readonly population: EvidencePopulationDraft
  readonly populationDetail: string
  readonly sampleSize: EvidenceNumberDraft
  readonly interventionDrugId: string
  readonly interventionDetail: string
  readonly comparatorKind: string
  readonly comparatorDrugId: string
  readonly comparatorDetail: string
  readonly outcomeConceptId: string
  readonly outcomeDetail: string
  readonly timepoint: EvidenceTimepointDraft
  readonly reportedDirection: string
  readonly effectMeasure: string
  readonly estimate: EvidenceNumberDraft
  readonly estimateUnit: string
  readonly confidenceInterval: EvidenceConfidenceIntervalDraft
  readonly limitationsText: string
  readonly sourceLocator: string
  readonly sourceQuote: string
  /** Kildeforankringen per kontrollfelt. Feltene som ikke fylles ut, står tomme. */
  readonly fieldGroundings: Readonly<Record<string, GroundingDraft>>
}

const NO_SELECTION = ''

function emptyForm(lookups: Extract<LookupState, { status: 'ready' }>): FormState {
  return {
    sourceId: NO_SELECTION,
    sourceVersionId: NO_SELECTION,
    designCode: STUDY_DESIGNS[0],
    population: EMPTY_POPULATION_DRAFT,
    populationDetail: '',
    sampleSize: EMPTY_NUMBER_DRAFT,
    interventionDrugId: NO_SELECTION,
    interventionDetail: '',
    comparatorKind: 'none',
    comparatorDrugId: NO_SELECTION,
    comparatorDetail: '',
    outcomeConceptId:
      lookups.outcomes.length === 1 ? lookups.outcomes[0].outcome_concept_id : NO_SELECTION,
    outcomeDetail: '',
    timepoint: EMPTY_TIMEPOINT_DRAFT,
    reportedDirection: 'not_stated',
    effectMeasure: NO_SELECTION,
    estimate: EMPTY_NUMBER_DRAFT,
    estimateUnit: NO_SELECTION,
    confidenceInterval: EMPTY_CONFIDENCE_INTERVAL_DRAFT,
    limitationsText: '',
    sourceLocator: '',
    sourceQuote: '',
    fieldGroundings: {},
  }
}

/** Tom streng fra et valgfritt felt betyr «ikke oppgitt», ikke en verdi å lagre. */
function blankToNull(value: string): string | null {
  return value.trim().length === 0 ? null : value
}

/**
 * Effektmålene som krever en enhet, og de som ikke skal ha en
 * (`evidence_items_estimate_unit_check`). Skjemaet viser enhetsfeltet nøyaktig
 * når målet krever det, framfor å la redaktøren fylle ut noe databasen avviser.
 */
const DIMENSIONAL_MEASURES: readonly string[] = ['mean_change', 'mean_difference']

function CreateEvidenceItemForm() {
  const availability = useAntidepClient()
  const sources = useReadModel(fetchEditorSources)
  const drugs = useReadModel(fetchEditorDrugs)
  const outcomes = useReadModel(fetchEditorOutcomes)
  const populations = useReadModel(fetchEditorPopulations)
  const lookups = combineLookups(sources, drugs, outcomes, populations)

  if (lookups.status === 'loading') {
    return (
      <p className="knowledge-notice knowledge-notice--loading" aria-busy="true" aria-live="polite">
        Henter kilder og katalog …
      </p>
    )
  }
  if (lookups.status === 'error') {
    return (
      <div className="knowledge-notice knowledge-notice--error" role="alert">
        <p className="knowledge-notice__lead">
          Antidep fikk ikke hentet det du kan registrere mot.
        </p>
        <p className="knowledge-notice__detail">Teknisk årsak: {lookups.message}</p>
      </div>
    )
  }
  if (lookups.status === 'nothing_to_register') {
    return (
      <div className="knowledge-notice knowledge-notice--absence" role="note">
        <p className="knowledge-notice__lead">
          Du har ingen kilder, virkestoff eller endepunkter å registrere et evidensfunn mot.
        </p>
        <p className="knowledge-notice__caveat">
          Det betyr enten at kontoen din ikke har redaktørrettigheter ennå, eller at det ikke er
          registrert noe å knytte funnet til. <Link to={accessPath()}>Se «Min tilgang»</Link> for
          hva kontoen din har, og <Link to={newSourcePath()}>opprett en kilde</Link> hvis den
          mangler.
        </p>
      </div>
    )
  }

  return <EvidenceItemForm availability={availability} lookups={lookups} />
}

type SubmitStatus = 'idle' | 'submitting'

function EvidenceItemForm({
  availability,
  lookups,
}: {
  readonly availability: ReturnType<typeof useAntidepClient>
  readonly lookups: Extract<LookupState, { status: 'ready' }>
}) {
  const [form, setForm] = useState<FormState>(() => emptyForm(lookups))
  const [status, setStatus] = useState<SubmitStatus>('idle')
  const [result, setResult] = useState<CreateEvidenceItemResult | null>(null)
  const [registered, setRegistered] = useState<{
    readonly sourceId: Uuid
    readonly token: number
  } | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const problemId = useId()

  // Uten en valgt kilde finnes det ikke noe spørsmål å stille databasen. Uten
  // denne grenen ville hver visning av skjemaet sendt et oppslag med en tom
  // uuid, og PostgREST ville svart 400 — en feilende forespørsel ved hver
  // rendring, som dessuten ville skjult en ekte feil i loggen.
  const versionsQuery = useCallback(
    (
      client: Parameters<typeof fetchEditorSourceVersions>[0],
    ): Promise<EditorReadResult<EditorSourceVersionRow>> =>
      form.sourceId === NO_SELECTION
        ? Promise.resolve({ status: 'none' })
        : fetchEditorSourceVersions(client, form.sourceId),
    [form.sourceId],
  )
  const versions = useReadModel(versionsQuery)

  const sourceChoices = useMemo(
    () => [
      { value: NO_SELECTION, label: 'Velg kilden funnet er hentet fra' },
      ...lookups.sources.map(sourceChoice),
    ],
    [lookups.sources],
  )
  const drugChoices = useMemo(
    () => [{ value: NO_SELECTION, label: 'Velg virkestoff' }, ...lookups.drugs.map(drugChoice)],
    [lookups.drugs],
  )
  const outcomeChoices = useMemo(
    () => [
      { value: NO_SELECTION, label: 'Velg endepunkt' },
      ...lookups.outcomes.map((outcome) =>
        vocabularyChoice(outcome.outcome_concept_id, outcome.canonical_label, outcome.status),
      ),
    ],
    [lookups.outcomes],
  )
  const populationChoices = useMemo(
    () => [
      { value: NO_SELECTION, label: 'Velg populasjon' },
      ...lookups.populations.map((population) =>
        vocabularyChoice(population.population_id, population.canonical_label, population.status),
      ),
    ],
    [lookups.populations],
  )

  // Fire tilstander, og «laster» og «feilet» er to av dem.
  //
  // Uten skillet ville begge blitt rendret som «Ingen registrert kildeversjon»
  // — samme tekst som når kilden faktisk ikke har noen — og en editor kunne
  // registrert funnet med `source_version_id = null` mens et øyeblikksbilde
  // fantes. Proveniensen ville da vært borte uten at noe sa fra, og
  // `knowledge.evidence_items` er append-only, så feilen kan ikke rettes i
  // raden etterpå. Samme regel som i lesemodellen ellers: laster må aldri kunne
  // leses som tomt, og en feil må aldri kunne leses som fravær
  // (ANTIDEP_CONSTITUTION.md §17, MVP_IMPLEMENTATION_PLAN.md §74.12).
  const versionState = form.sourceId === NO_SELECTION ? { status: 'no_source' as const } : versions

  const versionChoices: readonly Choice[] =
    versionState.status === 'ok'
      ? [
          { value: NO_SELECTION, label: 'Ingen registrert kildeversjon' },
          ...sourceVersionChoices(versionState.rows),
        ]
      : [{ value: NO_SELECTION, label: VERSION_PLACEHOLDERS[versionState.status] }]

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (availability.status !== 'ready') {
      return
    }

    // Kildeversjonene må ha svart. En registrering mens oppslaget står på eller
    // har feilet, ville sendt `source_version_id = null` uten at noen vet om
    // det er sant — se kommentaren på `versionState`.
    if (versionState.status === 'loading' || versionState.status === 'error') {
      setProblem(
        'Vent til kildeversjonene er hentet. Uten svaret er det ukjent om kilden har et registrert øyeblikksbilde funnet skal knyttes til.',
      )
      return
    }

    // Kanoniseringen bygger verdiene statusene krever. Er noe `incomplete`, har
    // redaktøren sagt at kilden oppgir en verdi uten å fylle den ut — da finnes
    // det ingen verdi å sende. Alt annet er fortsatt databasens dom.
    const population = canonicalPopulation(form.population)
    const sampleSize = canonicalNumber(form.sampleSize, {
      missingMessage: 'Fyll inn antall deltakere, eller si hvorfor tallet mangler.',
      whole: true,
    })
    const timepoint = canonicalTimepoint(form.timepoint)
    const estimate = canonicalNumber(form.estimate, {
      missingMessage: 'Fyll inn estimatet, eller si hvorfor det mangler.',
    })
    const confidenceInterval = canonicalConfidenceInterval(form.confidenceInterval)
    const incomplete = [population, sampleSize, timepoint, estimate, confidenceInterval].find(
      (value) => value.status === 'incomplete',
    )
    if (incomplete !== undefined && incomplete.status === 'incomplete') {
      setProblem(incomplete.message)
      return
    }
    if (
      population.status !== 'ok' ||
      sampleSize.status !== 'ok' ||
      timepoint.status !== 'ok' ||
      estimate.status !== 'ok' ||
      confidenceInterval.status !== 'ok'
    ) {
      return
    }

    // Forankringen samles inn på samme premiss: en halvferdig forankring er
    // ikke en forankring, og den skal ikke sendes som om den var det.
    const groundings = collectFieldGroundings(
      form.fieldGroundings,
      (field) =>
        EVIDENCE_CHECK_FIELD_LABELS[field as keyof typeof EVIDENCE_CHECK_FIELD_LABELS] ?? field,
    )
    if (groundings.status === 'incomplete') {
      setProblem(groundings.message)
      return
    }
    setProblem(null)

    setStatus('submitting')
    const outcome = await createEvidenceItem(availability.client, {
      sourceId: form.sourceId,
      sourceVersionId: blankToNull(form.sourceVersionId),
      designCode: form.designCode,
      populationId: population.populationId,
      populationAvailability: form.population.availability,
      populationDetail: form.populationDetail,
      sampleSize: sampleSize.value,
      sampleSizeAvailability: form.sampleSize.availability,
      interventionDrugId: form.interventionDrugId,
      interventionDetail: blankToNull(form.interventionDetail),
      comparatorKind: form.comparatorKind,
      comparatorDrugId: form.comparatorKind === 'drug' ? blankToNull(form.comparatorDrugId) : null,
      comparatorDetail: blankToNull(form.comparatorDetail),
      outcomeConceptId: form.outcomeConceptId,
      outcomeDetail: form.outcomeDetail,
      timepointMin: timepoint.min,
      timepointMax: timepoint.max,
      timepointAvailability: form.timepoint.availability,
      reportedDirection: form.reportedDirection,
      effectMeasure: blankToNull(form.effectMeasure),
      estimate: estimate.value,
      estimateUnit: DIMENSIONAL_MEASURES.includes(form.effectMeasure)
        ? blankToNull(form.estimateUnit)
        : null,
      estimateAvailability: form.estimate.availability,
      ciLower: confidenceInterval.lower,
      ciUpper: confidenceInterval.upper,
      ciLevelPercent: confidenceInterval.level,
      confidenceIntervalAvailability: form.confidenceInterval.availability,
      limitationsText: blankToNull(form.limitationsText),
      sourceLocator: form.sourceLocator,
      sourceQuote: blankToNull(form.sourceQuote),
      fieldGroundings: groundings.groundings,
    })
    setStatus('idle')
    setResult(outcome)
    if (outcome.status === 'ok') {
      // Kilden blir stående valgt: den neste registreringen er som regel et
      // funn til fra den samme publikasjonen (KNOWLEDGE_MODEL.md §11).
      const sourceId = form.sourceId
      setForm({ ...emptyForm(lookups), sourceId })
      setRegistered((previous) => ({
        sourceId,
        token: previous === null ? 1 : previous.token + 1,
      }))
    }
  }

  return (
    <>
      {result?.status === 'ok' ? (
        <div className="knowledge-notice knowledge-notice--ok" role="status">
          <p className="knowledge-notice__lead">Evidensfunnet er registrert.</p>
          <p className="knowledge-notice__detail">
            Funnets id: <code>{result.evidenceItemId}</code>
          </p>
        </div>
      ) : null}
      {result?.status === 'error' ? (
        <div className="knowledge-notice knowledge-notice--error" role="alert">
          <p className="knowledge-notice__lead">Evidensfunnet ble ikke registrert.</p>
          <p className="knowledge-notice__detail">Teknisk årsak: {result.message}</p>
        </div>
      ) : null}
      {registered === null ? null : (
        <RegisteredFindings
          key={`${registered.sourceId}:${registered.token}`}
          sourceId={registered.sourceId}
        />
      )}

      <form className="admin-form" onSubmit={(event) => void handleSubmit(event)}>
        <fieldset className="admin-form__section">
          <legend>Kilden funnet er hentet fra</legend>
          <SelectField
            choices={sourceChoices}
            label="Kilde"
            onChange={(sourceId) => setForm({ ...form, sourceId, sourceVersionId: NO_SELECTION })}
            required
            value={form.sourceId}
          />
          <SelectField
            choices={versionChoices}
            disabled={versionState.status !== 'ok' && versionState.status !== 'none'}
            hint="Det hentede øyeblikksbildet ekstraksjonen er lest av. Er ingen registrert, står funnet uten en versjon å kontrolleres mot."
            label="Kildeversjon (valgfritt)"
            onChange={(sourceVersionId) => setForm({ ...form, sourceVersionId })}
            value={form.sourceVersionId}
          />
          {versionState.status === 'error' ? (
            <div className="knowledge-notice knowledge-notice--error" role="alert">
              <p className="knowledge-notice__lead">
                Antidep fikk ikke hentet kildeversjonene for denne kilden.
              </p>
              <p className="knowledge-notice__detail">Teknisk årsak: {versionState.message}</p>
              <p className="knowledge-notice__caveat">
                Funnet kan ikke registreres før oppslaget svarer: uten det er det ukjent om kilden
                har et registrert øyeblikksbilde å knytte funnet til.
              </p>
            </div>
          ) : null}
          <TextField
            hint="Side, tabell, figur eller avsnitt. Uten den kan ikke funnet kontrolleres mot originalen."
            label="Hvor i kilden står funnet?"
            onChange={(sourceLocator) => setForm({ ...form, sourceLocator })}
            required
            value={form.sourceLocator}
          />
          <TextAreaField
            hint="Bevares ordrett, slik at en kontroll senere kan sammenlignes med originalen."
            label="Ordrett sitat fra kilden (valgfritt)"
            onChange={(sourceQuote) => setForm({ ...form, sourceQuote })}
            value={form.sourceQuote}
          />
        </fieldset>

        <fieldset className="admin-form__section">
          <legend>Studien og hvem den gjaldt</legend>
          <SelectField
            choices={STUDY_DESIGNS.map((design) => ({
              value: design,
              label: STUDY_DESIGN_LABELS[design],
            }))}
            hint="Designet for dette funnet, ikke for hele publikasjonen."
            label="Studiedesign"
            onChange={(designCode) => setForm({ ...form, designCode })}
            required
            value={form.designCode}
          />
          <AvailabilitySelect
            availability={form.population.availability}
            hint="Populasjonen er gyldighetsgrensen funnet indekseres under. Er den ikke koblet, skal grunnen stå her."
            label="Kobling til en populasjon i katalogen"
            onChange={(availability) =>
              setForm({ ...form, population: { ...form.population, availability } })
            }
          />
          {availabilityHasValue(form.population.availability) ? (
            <SelectField
              choices={populationChoices}
              label="Populasjon"
              onChange={(populationId) =>
                setForm({ ...form, population: { ...form.population, populationId } })
              }
              value={form.population.populationId}
            />
          ) : null}
          <TextAreaField
            hint="Alltid utfylt: den studerte populasjonen slik kilden selv beskriver den, med kjente forbehold."
            label="Populasjonen slik kilden beskriver den"
            onChange={(populationDetail) => setForm({ ...form, populationDetail })}
            required
            value={form.populationDetail}
          />
          <AvailabilitySelect
            availability={form.sampleSize.availability}
            label="Antall deltakere analysen omfatter"
            onChange={(availability) =>
              setForm({ ...form, sampleSize: { ...form.sampleSize, availability } })
            }
          />
          {availabilityHasValue(form.sampleSize.availability) ? (
            <TextField
              hint="Antallet analysen faktisk omfatter, ikke antallet randomisert, når de er forskjellige."
              inputMode="numeric"
              label="Antall deltakere"
              onChange={(value) => setForm({ ...form, sampleSize: { ...form.sampleSize, value } })}
              value={form.sampleSize.value}
            />
          ) : null}
        </fieldset>

        <fieldset className="admin-form__section">
          <legend>Behandlingen som er undersøkt</legend>
          <SelectField
            choices={drugChoices}
            label="Virkestoff"
            onChange={(interventionDrugId) => setForm({ ...form, interventionDrugId })}
            required
            value={form.interventionDrugId}
          />
          <TextField
            hint="For eksempel dose, varighet og hvor mange som fikk behandlingen."
            label="Detaljer om behandlingen (valgfritt)"
            onChange={(interventionDetail) => setForm({ ...form, interventionDetail })}
            value={form.interventionDetail}
          />
          <SelectField
            choices={COMPARATOR_KINDS.map((kind) => ({
              value: kind,
              label: COMPARATOR_KIND_LABELS[kind],
            }))}
            hint="Kontrasten i selve funnet. Er funnet armspesifikt, velg «ingen komparator» også når studien hadde en."
            label="Sammenlignet med"
            onChange={(comparatorKind) => setForm({ ...form, comparatorKind })}
            required
            value={form.comparatorKind}
          />
          {form.comparatorKind === 'drug' ? (
            <SelectField
              choices={drugChoices}
              label="Komparatorvirkestoff"
              onChange={(comparatorDrugId) => setForm({ ...form, comparatorDrugId })}
              value={form.comparatorDrugId}
            />
          ) : null}
          <TextField
            label="Detaljer om komparatoren (valgfritt)"
            onChange={(comparatorDetail) => setForm({ ...form, comparatorDetail })}
            value={form.comparatorDetail}
          />
        </fieldset>

        <fieldset className="admin-form__section">
          <legend>Endepunktet som ble målt</legend>
          <SelectField
            choices={outcomeChoices}
            hint="Endepunktet avgjør også hvilke redaktører som kan registrere funnet: en avgrenset redaktørrolle gjelder bare sitt eget endepunkt."
            label="Endepunkt"
            onChange={(outcomeConceptId) => setForm({ ...form, outcomeConceptId })}
            required
            value={form.outcomeConceptId}
          />
          <TextAreaField
            hint="Begrepet alene er for grovt: si om det gjelder gjennomsnittlig endring i kilo, prosentvis endring eller andelen med en gitt økning."
            label="Hva ble faktisk målt?"
            onChange={(outcomeDetail) => setForm({ ...form, outcomeDetail })}
            required
            value={form.outcomeDetail}
          />
          <AvailabilitySelect
            availability={form.timepoint.availability}
            label="Oppfølgingstid"
            onChange={(availability) =>
              setForm({ ...form, timepoint: { ...form.timepoint, availability } })
            }
          />
          {availabilityHasValue(form.timepoint.availability) ? (
            <>
              <SelectField
                choices={TIMEPOINT_UNITS.map((unit) => ({
                  value: unit,
                  label: TIMEPOINT_UNIT_LABELS[unit],
                }))}
                label="Enhet for oppfølgingstiden"
                onChange={(unit) =>
                  setForm({
                    ...form,
                    timepoint: { ...form.timepoint, unit: unit as TimepointUnit },
                  })
                }
                value={form.timepoint.unit}
              />
              <TextField
                inputMode="decimal"
                label="Oppfølgingstid, fra"
                onChange={(from) => setForm({ ...form, timepoint: { ...form.timepoint, from } })}
                value={form.timepoint.from}
              />
              <TextField
                hint="Fyll inn bare hvis kilden oppgir et spenn, for eksempel 26 til 32 uker. Står feltet tomt, gjelder funnet ett tidspunkt."
                inputMode="decimal"
                label="Oppfølgingstid, til og med (valgfritt)"
                onChange={(to) => setForm({ ...form, timepoint: { ...form.timepoint, to } })}
                value={form.timepoint.to}
              />
            </>
          ) : null}
        </fieldset>

        <fieldset className="admin-form__section">
          <legend>Resultatet kilden rapporterer</legend>
          <SelectField
            choices={REPORTED_DIRECTIONS.map((direction) => ({
              value: direction,
              label: REPORTED_DIRECTION_LABELS[direction],
            }))}
            hint="«Kilden fant ingen klar forskjell» er et resultat. «Kilden oppgir ingen retning» er ikke."
            label="Retning"
            onChange={(reportedDirection) => setForm({ ...form, reportedDirection })}
            required
            value={form.reportedDirection}
          />
          <SelectField
            choices={[
              { value: NO_SELECTION, label: 'Kilden oppgir ikke noe effektmål' },
              ...EFFECT_MEASURES.map((measure) => ({
                value: measure,
                label: MEASURE_LABELS[measure],
              })),
            ]}
            hint="Et tall uten sitt effektmål er ikke tolkbart."
            label="Effektmål"
            onChange={(effectMeasure) => setForm({ ...form, effectMeasure })}
            value={form.effectMeasure}
          />
          <AvailabilitySelect
            availability={form.estimate.availability}
            label="Tallverdi for effekten"
            onChange={(availability) =>
              setForm({ ...form, estimate: { ...form.estimate, availability } })
            }
          />
          {availabilityHasValue(form.estimate.availability) ? (
            <TextField
              hint="Skriv tallet slik kilden oppgir det. Komma og punktum betyr det samme her."
              inputMode="decimal"
              label="Estimat"
              onChange={(value) => setForm({ ...form, estimate: { ...form.estimate, value } })}
              value={form.estimate.value}
            />
          ) : null}
          {DIMENSIONAL_MEASURES.includes(form.effectMeasure) ? (
            <SelectField
              choices={[
                { value: NO_SELECTION, label: 'Velg enhet' },
                ...ESTIMATE_UNITS.map((unit) => ({ value: unit, label: UNIT_LABELS[unit] })),
              ]}
              hint="Uten enhet er et vekttall klinisk tvetydig."
              label="Enhet"
              onChange={(estimateUnit) => setForm({ ...form, estimateUnit })}
              value={form.estimateUnit}
            />
          ) : null}
          <AvailabilitySelect
            availability={form.confidenceInterval.availability}
            hint="Et manglende konfidensintervall betyr upresist grunnlag, ikke et presist estimat."
            label="Konfidensintervall"
            onChange={(availability) =>
              setForm({
                ...form,
                confidenceInterval: { ...form.confidenceInterval, availability },
              })
            }
          />
          {availabilityHasValue(form.confidenceInterval.availability) ? (
            <>
              <TextField
                inputMode="decimal"
                label="Nedre grense"
                onChange={(lower) =>
                  setForm({ ...form, confidenceInterval: { ...form.confidenceInterval, lower } })
                }
                value={form.confidenceInterval.lower}
              />
              <TextField
                inputMode="decimal"
                label="Øvre grense"
                onChange={(upper) =>
                  setForm({ ...form, confidenceInterval: { ...form.confidenceInterval, upper } })
                }
                value={form.confidenceInterval.upper}
              />
              <TextField
                hint="Vanligvis 95."
                inputMode="decimal"
                label="Konfidensnivå i prosent"
                onChange={(level) =>
                  setForm({ ...form, confidenceInterval: { ...form.confidenceInterval, level } })
                }
                value={form.confidenceInterval.level}
              />
            </>
          ) : null}
        </fieldset>

        <fieldset className="admin-form__section">
          <legend>Forbehold</legend>
          <TextAreaField
            hint="Kjente svakheter ved akkurat dette funnet: frafall, åpen etikett, at studiekonteksten var en annen enn kontrasten som er registrert."
            label="Begrensninger ved funnet (valgfritt)"
            onChange={(limitationsText) => setForm({ ...form, limitationsText })}
            value={form.limitationsText}
          />
        </fieldset>

        <GroundingFieldset
          drafts={form.fieldGroundings}
          onChange={(field, draft) =>
            setForm({ ...form, fieldGroundings: { ...form.fieldGroundings, [field]: draft } })
          }
        />

        {problem === null ? null : (
          <p className="admin-form__problem" id={problemId} role="alert">
            {problem}
          </p>
        )}

        <button disabled={status === 'submitting'} type="submit">
          {status === 'submitting' ? 'Registrerer …' : 'Registrer evidensfunn'}
        </button>
      </form>
    </>
  )
}

function EvidenceItemLoading() {
  return (
    <p className="knowledge-notice knowledge-notice--loading" aria-busy="true" aria-live="polite">
      Sjekker innloggingen …
    </p>
  )
}

function EvidenceItemAuthError({ message }: { readonly message: string }) {
  return (
    <div className="knowledge-notice knowledge-notice--error" role="alert">
      <p className="knowledge-notice__lead">Antidep fikk ikke sjekket innloggingen din.</p>
      <p className="knowledge-notice__detail">Teknisk årsak: {message}</p>
    </div>
  )
}

function SignedOutNotice() {
  return (
    <div className="knowledge-notice knowledge-notice--absence" role="note">
      <p className="knowledge-notice__lead">Du må logge inn for å registrere et evidensfunn.</p>
      <p className="knowledge-notice__caveat">
        <Link to={accessPath()}>Logg inn under «Min tilgang»</Link>, og kom tilbake hit.
      </p>
    </div>
  )
}

function CreateEvidenceItemBody({ authState }: { readonly authState: AuthSessionState }) {
  switch (authState.status) {
    case 'loading':
      return <EvidenceItemLoading />
    case 'unavailable':
      return <EvidenceItemAuthError message={authState.message} />
    case 'signed_out':
      return <SignedOutNotice />
    case 'signed_in':
      // Friskt tre ved hver innlogging eller brukerbytte, samme strukturelle
      // gate som `CreateSourcePage.tsx`.
      return <CreateEvidenceItemForm key={authState.userId} />
  }
}

export function CreateEvidenceItemPage() {
  usePageTitle('Registrer evidensfunn')
  const authState = useAuthSession()

  return (
    <>
      <p className="page-kicker">Admin</p>
      <h2>Registrer evidensfunn</h2>
      <p className="admin-form__intro">
        Et evidensfunn er ett konkret resultat fra én kilde: hva som ble målt, i hvilken gruppe, med
        hvilket resultat, og nøyaktig hvor i kilden det står. Kilden må være opprettet først. Funnet
        er et forslag inntil det er kontrollert og godkjent — de stegene er ikke bygget ennå.
      </p>
      <CreateEvidenceItemBody authState={authState} />
    </>
  )
}
