// ============================================================================
// Testrigg for klinikerflaten
//
// Rendrer skallet på en gitt adresse med en injisert klient, slik at en test
// kan stå på `/drugs/…` uten nettleserhistorikk og uten miljøvariabler.
//
// Den falske klienten svarer på nivået `published-read-model.ts` faktisk
// spør på — `from(view).select().eq().order()` — framfor å stubbe
// lesefunksjonene. Da er det den virkelige spørringen som kjøres, og et filter
// som forsvinner fra en lesefunksjon blir synlig i en sidetest.
//
// ----------------------------------------------------------------------------
// Testdataene er syntetiske, og det er ikke en formalitet
//
// Ingenting her er innhold. Virkelige påstander kommer fra databasen gjennom
// review- og publiseringsgatene (ANTIDEP_CONSTITUTION.md §12), aldri fra en
// fikstur. Virkestoffnavnene i påstandsfiksturene er derfor oppdiktede, og
// formuleringene er merket som testpåstander. De virkelige pilotnavnene brukes
// bare der testen handler om adressen og ikke om innhold.
// ============================================================================

import { render } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { AppLayout } from './App'
import { AntidepClientProvider, type AntidepClientAvailability } from './antidep-client'
import type { AntidepClient } from '../lib/supabase'
import type {
  EditorDrugRow,
  EditorEvidenceItemRow,
  EditorOutcomeRow,
  EditorPopulationRow,
  EditorSourceRow,
  EditorSourceVersionRow,
  MyActorRow,
  MyRoleRow,
  PublishedClaimEvidenceRow,
  PublishedClaimRow,
  PublishedDrugRow,
} from '../types/api'

/** Hva ett view svarer: rader, en feil, eller aldri (for ventetilstanden). */
export type FakeOutcome<Row> =
  readonly Row[] | { readonly error: string } | { readonly pending: true }

/** Hva ett RPC-kall svarer: en verdi, eller en feil — aldri rader. */
export type FakeRpcAnswer<Data> = { readonly data: Data } | { readonly error: string }

/**
 * Svaret på ett RPC-navn: ett svar, eller en sekvens.
 *
 * Sekvensen finnes for de testene som handler om hva som skjer *mellom* to kall
 * — en registrering som avvises fordi grunnlaget er endret, og den nye
 * hentingen etterpå. Med bare ett svar per navn ville en slik test måttet late
 * som at grunnlaget var uendret, og da hadde den prøvd noe annet enn den sier.
 * Siste svar gjentas når sekvensen er brukt opp.
 */
export type FakeRpcOutcome<Data> =
  FakeRpcAnswer<Data> | readonly [FakeRpcAnswer<Data>, ...FakeRpcAnswer<Data>[]]

export interface FakeApi {
  readonly published_drugs?: FakeOutcome<PublishedDrugRow>
  readonly published_claims?: FakeOutcome<PublishedClaimRow>
  readonly published_claim_evidence?: FakeOutcome<PublishedClaimEvidenceRow>
  readonly my_actor?: FakeOutcome<MyActorRow>
  readonly my_roles?: FakeOutcome<MyRoleRow>
  // Den redaksjonelle lesemodellen (migrasjon 007d), for steg 3 av adminflyten.
  readonly editor_sources?: FakeOutcome<EditorSourceRow>
  readonly editor_source_versions?: FakeOutcome<EditorSourceVersionRow>
  readonly editor_drugs?: FakeOutcome<EditorDrugRow>
  readonly editor_outcomes?: FakeOutcome<EditorOutcomeRow>
  readonly editor_populations?: FakeOutcome<EditorPopulationRow>
  readonly editor_evidence_items?: FakeOutcome<EditorEvidenceItemRow>
  /** Steg 2 av adminflyten (§29, §74.24): `api.create_source(...)`. */
  readonly create_source?: FakeRpcOutcome<string>
  /** Steg 3 av adminflyten (§29): `api.create_evidence_item(...)`. */
  readonly create_evidence_item?: FakeRpcOutcome<string>
  /** Kildeversjoner (migrasjon 007f, issue #44): `api.create_source_version(...)`. */
  readonly create_source_version?: FakeRpcOutcome<string>
  /**
   * Reviewflaten (migrasjon 005o): `api.claim_review_workspace(uuid)`.
   *
   * To nøkler for én funksjon, fordi den svarer på to spørsmål avhengig av om
   * den får en revisjons-ID: uten den er svaret arbeidskøen, med den er svaret
   * arbeidsflaten for én revisjon. Faken dispatcher på argumentet, slik den
   * ekte funksjonen gjør.
   */
  readonly claim_review_queue?: FakeRpcOutcome<unknown>
  readonly claim_review_workspace?: FakeRpcOutcome<unknown>
  /** De to beslutningene (migrasjon 005n og 006d). */
  readonly register_human_claim_verification?: FakeRpcOutcome<string>
  readonly register_publication_approval?: FakeRpcOutcome<string>
  /**
   * Kildekontrollen (migrasjon 005s og 005t). Samme dispatch som reviewflaten:
   * uten en evidens-ID er svaret køen, med den er svaret arbeidsflaten.
   */
  readonly extraction_review_queue?: FakeRpcOutcome<unknown>
  readonly extraction_review_workspace?: FakeRpcOutcome<unknown>
  readonly register_human_extraction_verification?: FakeRpcOutcome<string>
  /** Publiseringshandlingen (migrasjon 006h). */
  readonly publish_claim_revision?: FakeRpcOutcome<string>
}

interface RecordedQuery {
  readonly view: string
  readonly filters: [string, unknown][]
  readonly orders: [string, boolean][]
}

function outcomeFor(api: FakeApi, view: string): FakeOutcome<Record<string, unknown>> {
  const outcome = (api as Record<string, FakeOutcome<Record<string, unknown>> | undefined>)[view]
  return outcome ?? []
}

/** Standardsvaret fra en skrivevei fiksturen ikke sier noe om: den lyktes. */
const DEFAULT_RPC_ID = '00000000-0000-4000-8000-999999999999'

/** Svaret for dette kallet i rekken. Siste svar gjentas når sekvensen er brukt opp. */
function answerAt<Data>(outcome: FakeRpcOutcome<Data>, callIndex: number): FakeRpcAnswer<Data> {
  if (!Array.isArray(outcome)) {
    return outcome as FakeRpcAnswer<Data>
  }
  const answers = outcome as readonly FakeRpcAnswer<Data>[]
  return answers[Math.min(callIndex, answers.length - 1)] as FakeRpcAnswer<Data>
}

function fakeRpcOutcome(api: FakeApi, name: string, args: unknown): FakeRpcOutcome<unknown> {
  switch (name) {
    case 'create_source':
      return api.create_source ?? { data: DEFAULT_RPC_ID }
    case 'create_evidence_item':
      return api.create_evidence_item ?? { data: DEFAULT_RPC_ID }
    case 'create_source_version':
      return api.create_source_version ?? { data: DEFAULT_RPC_ID }
    case 'claim_review_workspace': {
      // Samme dispatch som den ekte funksjonen: uten en revisjons-ID er svaret
      // køen, med den er svaret arbeidsflaten.
      const revisionId = (args as { p_claim_revision_id?: string | null } | undefined)
        ?.p_claim_revision_id
      if (revisionId == null) {
        return api.claim_review_queue ?? { data: reviewQueuePayload([]) }
      }
      return api.claim_review_workspace ?? { data: claimReviewPayload() }
    }
    case 'register_human_claim_verification':
      return api.register_human_claim_verification ?? { data: DEFAULT_RPC_ID }
    case 'register_publication_approval':
      return api.register_publication_approval ?? { data: DEFAULT_RPC_ID }
    case 'extraction_review_workspace': {
      const evidenceItemId = (args as { p_evidence_item_id?: string | null } | undefined)
        ?.p_evidence_item_id
      if (evidenceItemId == null) {
        return api.extraction_review_queue ?? { data: extractionQueuePayload([]) }
      }
      return api.extraction_review_workspace ?? { data: extractionReviewPayload() }
    }
    case 'register_human_extraction_verification':
      return api.register_human_extraction_verification ?? { data: DEFAULT_RPC_ID }
    case 'publish_claim_revision':
      return api.publish_claim_revision ?? { data: DEFAULT_RPC_ID }
    default:
      throw new Error(`fakeClient.rpc(): ukjent funksjon «${name}».`)
  }
}

// ----------------------------------------------------------------------------
// Fake `auth`, for Min tilgang (§74.22)
//
// Nok til å teste det klientkoden faktisk gjør mot `client.auth`: lese
// sesjonen ved montering, abonnere på endringer, logge inn og logge ut. Faken
// validerer *ikke* e-post/passord mot noe — det er Supabases jobb på ekte, ikke
// vår klientkodes — så et vellykket forsøk er standard, og
// `FakeAuthOptions.signInError` gjør forsøket avvist når en test trenger det.
// ----------------------------------------------------------------------------

interface FakeSession {
  readonly user: { readonly id: string }
}

type FakeAuthListener = (event: string, session: FakeSession | null) => void

export interface FakeAuthOptions {
  /** Sesjonen når rendringen starter. `null` (standard) betyr ikke innlogget. */
  readonly initialUserId?: string | null
  /**
   * Gjør et innloggingsforsøk avvist med denne meldingen, uansett hva som er
   * skrevet inn. Utelatt (standard) betyr at forsøket lykkes.
   */
  readonly signInError?: string
  /** Identiteten et vellykket innloggingsforsøk gir. */
  readonly signInUserId?: string
}

export const TEST_USER_IDS = {
  a: '99999999-9999-4999-8999-111111111111',
  b: '99999999-9999-4999-8999-222222222222',
} as const

/**
 * Ett registrert `signOut()`-kall, slik det faktisk ble gjort mot faken.
 *
 * Finnes for å teste `scope` eksplisitt: supabase-js sin standard er
 * `'global'` — logger kalleren ut av *alle* enheter — og en «Logg ut»-knapp
 * skal ikke ha den sideeffekten uten at det er et bevisst produktvalg. Uten en
 * assertion på det faktiske kallet kunne `AccessPage.tsx` sluttet å sende
 * `scope: 'local'` uten at noen test merket det.
 */
export interface FakeSignOutCall {
  readonly scope?: string
}

function fakeAuth(options: FakeAuthOptions, signOutCalls: FakeSignOutCall[]) {
  let session: FakeSession | null =
    options.initialUserId == null ? null : { user: { id: options.initialUserId } }
  const listeners = new Set<FakeAuthListener>()

  function emit(event: string) {
    for (const listener of listeners) {
      listener(event, session)
    }
  }

  return {
    getSession: () => Promise.resolve({ data: { session } }),
    onAuthStateChange: (callback: FakeAuthListener) => {
      listeners.add(callback)
      return { data: { subscription: { unsubscribe: () => listeners.delete(callback) } } }
    },
    // Ingen parameter: faken validerer aldri e-post/passord mot noe — det er
    // Supabases jobb på ekte, ikke klientkodens. Se doc-kommentaren over.
    signInWithPassword: () => {
      if (options.signInError !== undefined) {
        return Promise.resolve({
          data: { session: null, user: null },
          error: { message: options.signInError },
        })
      }
      session = { user: { id: options.signInUserId ?? TEST_USER_IDS.a } }
      emit('SIGNED_IN')
      return Promise.resolve({ data: { session, user: session.user }, error: null })
    },
    signOut: (signOutOptions?: FakeSignOutCall) => {
      signOutCalls.push(signOutOptions ?? {})
      session = null
      emit('SIGNED_OUT')
      return Promise.resolve({ error: null })
    },
  }
}

export interface RecordedRpcCall {
  readonly name: string
  readonly args: unknown
}

/**
 * En klient som oppfører seg som PostgREST på de tre tingene lesemodellen
 * bruker: kolonnevalg, `eq`-filtre og sortering. Filtrene anvendes faktisk, så
 * en side som slutter å filtrere på `drug_id` vil vise andre virkestoffs
 * påstander i testen — som i produksjon.
 */
export function fakeClient(
  api: FakeApi = {},
  authOptions: FakeAuthOptions = {},
): {
  client: AntidepClient
  queries: RecordedQuery[]
  signOutCalls: FakeSignOutCall[]
  rpcCalls: RecordedRpcCall[]
} {
  const queries: RecordedQuery[] = []
  const signOutCalls: FakeSignOutCall[] = []
  const rpcCalls: RecordedRpcCall[] = []
  const rpcCallCounts = new Map<string, number>()

  const client = {
    // Steg 2 og 3 av adminflyten (§29, §74.24): de to kontrollerte
    // skriveveiene. Bare disse to er kjent; en ukjent funksjon feiler høyt
    // framfor å svare stille, slik at en glemt fikstur ikke ser ut som en
    // vellykket registrering.
    rpc(name: string, args: unknown) {
      // Tellingen er per navn *og* per form på kallet: den samme funksjonen
      // svarer på to spørsmål avhengig av om den får en id, og en sekvens for
      // det ene skal ikke telles ned av det andre.
      const key = `${name}:${JSON.stringify(args ?? null)}`
      const callIndex = rpcCallCounts.get(key) ?? 0
      rpcCallCounts.set(key, callIndex + 1)
      rpcCalls.push({ name, args })
      const outcome = answerAt(fakeRpcOutcome(api, name, args), callIndex)
      return Promise.resolve(
        'error' in outcome
          ? { data: null, error: { message: outcome.error } }
          : { data: outcome.data, error: null },
      )
    },
    from(view: string) {
      const recorded: RecordedQuery = { view, filters: [], orders: [] }
      const builder = {
        select() {
          queries.push(recorded)
          return builder
        },
        eq(column: string, value: unknown) {
          recorded.filters.push([column, value])
          return builder
        },
        order(column: string, options: { ascending: boolean }) {
          recorded.orders.push([column, options.ascending])
          return builder
        },
        then<Result>(resolve: (value: unknown) => Result) {
          const outcome = outcomeFor(api, view)
          if ('pending' in outcome) {
            // Aldri: ventetilstanden er en tilstand som skal kunne observeres.
            return new Promise<Result>(() => undefined)
          }
          if ('error' in outcome) {
            return Promise.resolve({ data: null, error: { message: outcome.error } }).then(resolve)
          }
          const rows = outcome.filter((row) =>
            recorded.filters.every(([column, value]) => row[column] === value),
          )
          return Promise.resolve({ data: rows, error: null }).then(resolve)
        },
      }
      return builder
    },
    auth: fakeAuth(authOptions, signOutCalls),
  }

  return { client: client as unknown as AntidepClient, queries, signOutCalls, rpcCalls }
}

export interface RenderRouteOptions {
  readonly api?: FakeApi
  readonly auth?: FakeAuthOptions
  /** Overstyrer klienttilstanden helt, for å teste manglende konfigurasjon. */
  readonly availability?: AntidepClientAvailability
}

/** Rendrer hele skallet på én adresse. */
export function renderRoute(path: string, options: RenderRouteOptions = {}) {
  const fake = fakeClient(options.api, options.auth)
  const availability: AntidepClientAvailability = options.availability ?? {
    status: 'ready',
    client: fake.client,
  }
  const result = render(
    <AntidepClientProvider value={availability}>
      <MemoryRouter initialEntries={[path]}>
        <AppLayout />
      </MemoryRouter>
    </AntidepClientProvider>,
  )
  return {
    ...result,
    queries: fake.queries,
    signOutCalls: fake.signOutCalls,
    rpcCalls: fake.rpcCalls,
  }
}

const DRUG_A = '11111111-1111-4111-8111-111111111111'
const DRUG_B = '11111111-1111-4111-8111-222222222222'
const TOPIC_WEIGHT = '44444444-4444-4444-8444-111111111111'
const CLAIM_A = '22222222-2222-4222-8222-111111111111'
const CLAIM_B = '22222222-2222-4222-8222-222222222222'
const CLAIM_C = '22222222-2222-4222-8222-333333333333'
const REVISION_A = '33333333-3333-4333-8333-111111111111'
const SOURCE_A = '88888888-8888-4888-8888-111111111111'

export const TEST_DRUG_IDS = { a: DRUG_A, b: DRUG_B } as const
export const TEST_TOPIC_IDS = { weight: TOPIC_WEIGHT } as const
export const TEST_CLAIM_IDS = { a: CLAIM_A, b: CLAIM_B, c: CLAIM_C } as const
export const TEST_REVISION_IDS = { a: REVISION_A } as const
export const TEST_SOURCE_IDS = { a: SOURCE_A } as const

export function drugRow(overrides: Partial<PublishedDrugRow> = {}): PublishedDrugRow {
  return {
    drug_id: DRUG_A,
    canonical_name: 'virkestoff a',
    status: 'active',
    atc_codes: ['N06AB99'],
    published_claim_count: 1,
    ...overrides,
  }
}

export function claimRow(overrides: Partial<PublishedClaimRow> = {}): PublishedClaimRow {
  return {
    claim_id: CLAIM_A,
    claim_revision_id: REVISION_A,
    revision_number: 1,
    knowledge_type: 'evidence_synthesis',

    drug_id: DRUG_A,
    drug_name: 'virkestoff a',
    topic_concept_id: TOPIC_WEIGHT,
    topic_label: 'vektendring',

    statement: 'Testpåstand: Virkestoff A er assosiert med større vektøkning enn placebo.',
    scope: 'Voksne, korttidsbehandling ved depresjon',

    population_id: null,
    population_label: null,
    timeframe_min: null,
    timeframe_max: null,
    comparator_kind: 'placebo',
    comparator_drug_id: null,
    comparator_drug_name: null,

    direction: 'increase',
    magnitude_measure: null,
    magnitude_value: null,
    magnitude_unit: null,

    qualifiers: null,
    uncertainty_summary: 'Få studier, og kort oppfølgingstid.',

    certainty_framework: 'grade',
    certainty_level: 'moderate',
    certainty_rationale: null,
    evidence_gap: null,
    last_assessed_at: '2026-08-20T10:00:00Z',

    withdrawn_evidence_count: 0,

    content_hash: 'sha256-v1:0000',
    revision_created_at: '2026-08-19T10:00:00Z',
    published_at: '2026-08-20T12:00:00Z',
    last_reviewed_at: '2026-08-21T09:15:00Z',
    ...overrides,
  }
}

/**
 * Én evidenslenke, i den formen `api.published_claim_evidence` gir den.
 *
 * Grunnformen er den enkleste raden som er gyldig etter migrasjon 003: et
 * rapportert funn med et tolkbart estimat, et konfidensintervall og en kilde
 * uten avvikende status. Testene overstyrer nøyaktig det de handler om, slik at
 * en rad som mangler noe, mangler det med hensikt.
 */
export function evidenceRow(
  overrides: Partial<PublishedClaimEvidenceRow> = {},
): PublishedClaimEvidenceRow {
  return {
    claim_id: CLAIM_A,
    claim_revision_id: REVISION_A,
    claim_evidence_link_id: '55555555-5555-4555-8555-111111111111',

    relationship_type: 'supports',
    directness: 'direct',
    relevance_note: 'Testnotat: funnet måler samme endepunkt i samme populasjon.',

    evidence_item_id: '66666666-6666-4666-8666-111111111111',
    study_design: 'randomized_controlled_trial',

    population_id: '77777777-7777-4777-8777-111111111111',
    population_label: 'voksne med depresjon',
    population_detail: 'Voksne 18–65 år i poliklinisk behandling.',
    population_availability: 'reported_value',
    sample_size: 240,
    sample_size_availability: 'reported_value',

    intervention_drug_id: DRUG_A,
    intervention_drug_name: 'virkestoff a',
    intervention_detail: null,
    comparator_kind: 'placebo',
    comparator_drug_id: null,
    comparator_drug_name: null,
    comparator_detail: null,

    outcome_concept_id: TOPIC_WEIGHT,
    outcome_label: 'vektendring',
    outcome_detail: 'Endring i kroppsvekt fra baseline.',
    timepoint_min: '56 days',
    timepoint_max: '56 days',
    timepoint_availability: 'reported_value',

    reported_direction: 'increase',
    effect_measure: 'mean_difference',
    estimate: 1.7,
    estimate_unit: 'kg',
    estimate_availability: 'reported_value',
    ci_lower: 0.9,
    ci_upper: 2.5,
    ci_level_percent: 95,
    confidence_interval_availability: 'reported_value',

    limitations_text: null,
    source_locator: 'Tabell 2, side 114',

    extraction_withdrawn: false,
    extraction_withdrawn_at: null,
    extraction_withdrawal_rationale: null,

    source_version_id: null,
    source_version_retrieved_at: null,
    source_version_retrieved_from: null,
    source_version_external_version: null,
    source_version_content_hash: null,

    source_id: SOURCE_A,
    source_type: 'journal_article',
    source_title: 'Testkilde A: vektendring ved åtte uker',
    source_authors_or_issuer: 'Testforfatter m.fl.',
    source_publisher_or_journal: 'Testtidsskrift',
    source_publication_date: '2019-03-01',
    source_publication_date_precision: 'month',
    source_status: 'active',
    source_status_note: null,
    source_dois: ['10.0000/test.a'],
    source_pmids: null,
    ...overrides,
  }
}

// ----------------------------------------------------------------------------
// Kallerens eget (migrasjon 007b), for Min tilgang (§74.22)
// ----------------------------------------------------------------------------

const ACTOR_A = '00000000-0000-4000-8000-111111111111'

export const TEST_ACTOR_IDS = { a: ACTOR_A } as const

/** Kallerens egen aktørrad, slik `api.my_actor` gir den. */
export function myActorRow(overrides: Partial<MyActorRow> = {}): MyActorRow {
  return {
    actor_id: ACTOR_A,
    actor_key: 'human:testredaktor',
    display_name: 'Test Redaktør',
    retired_at: null,
    ...overrides,
  }
}

/** Én rolletildeling som gjelder nå, slik `api.my_roles` gir den. */
export function myRoleRow(overrides: Partial<MyRoleRow> = {}): MyRoleRow {
  return {
    role_code: 'reviewer',
    scope_id: null,
    scope_type: null,
    valid_from: '2026-08-20T10:00:00Z',
    valid_to: null,
    ...overrides,
  }
}

// ----------------------------------------------------------------------------
// Den redaksjonelle lesemodellen (migrasjon 007d), for steg 3 av adminflyten
//
// Som resten av fiksturene: syntetisk innhold, ikke ekte kilder. Grunnformene
// er de enkleste radene som er gyldige, og testene overstyrer nøyaktig det de
// handler om.
// ----------------------------------------------------------------------------

const EDITOR_SOURCE = '88888888-8888-4888-8888-222222222222'
const EDITOR_SOURCE_VERSION = '88888888-8888-4888-8888-333333333333'
const EDITOR_POPULATION = '77777777-7777-4777-8777-222222222222'
const EDITOR_EVIDENCE_ITEM = '66666666-6666-4666-8666-222222222222'

export const TEST_EDITOR_IDS = {
  source: EDITOR_SOURCE,
  sourceVersion: EDITOR_SOURCE_VERSION,
  population: EDITOR_POPULATION,
  evidenceItem: EDITOR_EVIDENCE_ITEM,
} as const

export function editorSourceRow(overrides: Partial<EditorSourceRow> = {}): EditorSourceRow {
  return {
    source_id: EDITOR_SOURCE,
    source_type: 'journal_article',
    title: 'Testkilde B: vektendring ved tolv uker',
    authors_or_issuer: 'Testforfatter m.fl.',
    publisher_or_journal: 'Testtidsskrift',
    publication_date: '2021-01-01',
    publication_date_precision: 'year',
    source_status: 'active',
    status_note: null,
    ...overrides,
  }
}

export function editorSourceVersionRow(
  overrides: Partial<EditorSourceVersionRow> = {},
): EditorSourceVersionRow {
  return {
    source_version_id: EDITOR_SOURCE_VERSION,
    source_id: EDITOR_SOURCE,
    retrieved_at: '2026-09-01T10:00:00Z',
    retrieved_from: 'https://eksempel.invalid/testkilde-b',
    external_version: null,
    content_hash: null,
    representation: null,
    document_sha256: null,
    document_byte_size: null,
    document_media_type: null,
    text_extraction_tool: null,
    text_extraction_tool_version: null,
    text_extraction_arguments: null,
    ...overrides,
  }
}

export function editorDrugRow(overrides: Partial<EditorDrugRow> = {}): EditorDrugRow {
  return {
    drug_id: DRUG_A,
    canonical_name: 'virkestoff a',
    status: 'active',
    ...overrides,
  }
}

export function editorOutcomeRow(overrides: Partial<EditorOutcomeRow> = {}): EditorOutcomeRow {
  return {
    outcome_concept_id: TOPIC_WEIGHT,
    canonical_label: 'vektendring',
    status: 'active',
    ...overrides,
  }
}

export function editorPopulationRow(
  overrides: Partial<EditorPopulationRow> = {},
): EditorPopulationRow {
  return {
    population_id: EDITOR_POPULATION,
    canonical_label: 'voksne med depressiv lidelse',
    status: 'active',
    ...overrides,
  }
}

export function editorEvidenceItemRow(
  overrides: Partial<EditorEvidenceItemRow> = {},
): EditorEvidenceItemRow {
  return {
    evidence_item_id: EDITOR_EVIDENCE_ITEM,
    source_id: EDITOR_SOURCE,
    source_title: 'Testkilde B: vektendring ved tolv uker',
    source_version_id: null,
    study_design: 'randomized_controlled_trial',
    intervention_drug_id: DRUG_A,
    intervention_drug_name: 'virkestoff a',
    comparator_kind: 'none',
    comparator_drug_id: null,
    comparator_drug_name: null,
    outcome_label: 'vektendring',
    outcome_detail: 'Gjennomsnittlig vektendring i kilogram.',
    reported_direction: 'increase',
    source_locator: 'Tabell 3, side 118',
    extraction_method: 'manual',
    created_at: '2026-09-04T08:00:00Z',
    ...overrides,
  }
}

// ----------------------------------------------------------------------------
// Reviewflaten (migrasjon 005m, 005n, 005o, 006d)
//
// Fiksturene bygger jsonb-svaret slik `api.claim_review_workspace(uuid)` faktisk
// gir det — med snake_case-nøklene fra migrasjonen — og ikke den parsede formen.
// Det er med hensikt: da er det den virkelige leseren i
// `lib/review-workspace.ts` som kjøres i sidetesten, og et felt som forsvinner
// fra kontrakten blir synlig som en feil framfor som en tom visning.
//
// Som resten av fiksturene: syntetisk innhold, ikke ekte kilder.
// ----------------------------------------------------------------------------

const REVIEW_REVISION = '33333333-3333-4333-8333-222222222222'
const REVIEW_CLAIM = '22222222-2222-4222-8222-444444444444'
const REVIEW_LINK = '55555555-5555-4555-8555-222222222222'
const REVIEW_EVIDENCE_ITEM = '66666666-6666-4666-8666-333333333333'
const REVIEW_SOURCE_VERSION = '88888888-8888-4888-8888-444444444444'
const REVIEW_SYNTHESIS_ACTOR = '00000000-0000-4000-8000-222222222222'
const REVIEW_REVIEWER_ACTOR = '00000000-0000-4000-8000-333333333333'

export const TEST_REVIEW_IDS = {
  revision: REVIEW_REVISION,
  claim: REVIEW_CLAIM,
  link: REVIEW_LINK,
  evidenceItem: REVIEW_EVIDENCE_ITEM,
  sourceVersion: REVIEW_SOURCE_VERSION,
  synthesisActor: REVIEW_SYNTHESIS_ACTOR,
  reviewerActor: REVIEW_REVIEWER_ACTOR,
} as const

/** Én kørad, slik køen gir den. */
export function reviewQueueItem(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    claim_revision_id: REVIEW_REVISION,
    claim_id: REVIEW_CLAIM,
    revision_number: 1,
    knowledge_type: 'evidence_synthesis',
    created_at: '2026-09-01T08:00:00Z',
    created_by_actor_id: REVIEW_SYNTHESIS_ACTOR,
    created_by_actor_key: 'agent:claim-synthesis',
    statement: 'Testpåstand til vurdering: virkestoff a er assosiert med vektøkning.',
    subject_drug_name: 'virkestoff a',
    topic_label: 'vektendring',
    topic_concept_id: TOPIC_WEIGHT,
    evidence_link_count: 1,
    is_published_revision: false,
    current_claim_verification_outcome: null,
    current_publication_decision: null,
    ...overrides,
  }
}

/** Hele køsvaret. */
export function reviewQueuePayload(
  items: readonly Record<string, unknown>[] = [reviewQueueItem()],
): Record<string, unknown> {
  return { reviewer_actor_id: REVIEW_REVIEWER_ACTOR, queue: items }
}

/**
 * Én kildeforankring, slik `workflow.evidence_field_groundings(uuid)` gir den.
 *
 * Utdraget er syntetisk, som resten av fiksturene. Poenget er formen: ett felt,
 * ett ordrett utdrag, én presis peker og én kort begrunnelse.
 */
export function fieldGrounding(
  checkField: string,
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    field_grounding_id: `99999999-9999-4999-8999-${checkField.slice(0, 12).padEnd(12, '0')}`,
    check_field: checkField,
    source_excerpt: `Testutdrag for ${checkField}.`,
    source_locator: `Testkilde A, avsnittet om ${checkField}`,
    justification: `Testbegrunnelse for hvordan utdraget ble til verdien for ${checkField}.`,
    created_at: '2026-08-30T08:00:00Z',
    created_by_actor_id: '00000000-0000-4000-8000-444444444444',
    ...overrides,
  }
}

/**
 * Feltene fiksturen forankrer: de semantiske feltene funnet påstår noe om, slik
 * en fersk agentekstraksjon må levere dem (`api.register_agent_extraction`).
 *
 * `raw_extraction` og `source_locator` står ikke her. De er provenansfelter, og
 * hver forankring bærer sitt eget ordrette utdrag og sin egen peker.
 */
export const TEST_SEMANTIC_FIELDS: readonly string[] = [
  'intervention_arm',
  'outcome',
  'reported_direction',
  'availability_semantics',
  'effect_measure',
  'comparator_arm',
  'population',
  'sample_size',
  'timepoint',
  'estimate',
  'confidence_interval',
]

export const TEST_FIELD_GROUNDINGS: readonly Record<string, unknown>[] = TEST_SEMANTIC_FIELDS.map(
  (field) => fieldGrounding(field),
)

/**
 * Kilden i dossieret, med sine globale identifikatorer.
 *
 * Egen byggefunksjon fordi identifikatorene er det den menneskelige lenken
 * bygges av: en test som varierer dem, skal slippe å gjenta hele kilden.
 */
export function reviewSource(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    source_id: SOURCE_A,
    source_type: 'journal_article',
    title: 'Testkilde A: vektendring ved åtte uker',
    authors_or_issuer: 'Testforfatter m.fl.',
    publisher_or_journal: 'Testtidsskrift',
    publication_date: '2019-03-01',
    publication_date_precision: 'month',
    source_status: 'active',
    status_note: null,
    identifiers: [
      { identifier_system: 'doi', identifier_value: '10.1000/testkilde-a.1' },
      { identifier_system: 'pmid', identifier_value: '10999999' },
    ],
    ...overrides,
  }
}

/**
 * Ekstraksjonen i dossieret, felt for felt.
 *
 * Egen byggefunksjon fordi flere tester varierer ett enkelt felt — et
 * konfidensintervall som mangler, et tidsrom oppgitt i uker — og et objekt som
 * måtte gjentas i sin helhet for hver variasjon, ville drevet fra originalen.
 */
export function reviewExtraction(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    design_code: 'randomized_controlled_trial',
    population_id: null,
    population_label: 'voksne med depresjon',
    population_availability: 'reported_value',
    population_detail: 'Voksne 18–65 år i poliklinisk behandling.',
    sample_size: 240,
    sample_size_availability: 'reported_value',
    intervention_drug_id: DRUG_A,
    intervention_drug_name: 'virkestoff a',
    intervention_detail: null,
    comparator_kind: 'placebo',
    comparator_drug_id: null,
    comparator_drug_name: null,
    comparator_detail: null,
    outcome_concept_id: TOPIC_WEIGHT,
    outcome_label: 'vektendring',
    outcome_detail: 'Endring i kroppsvekt fra baseline.',
    timepoint_min: '56 days',
    timepoint_max: '56 days',
    timepoint_availability: 'reported_value',
    reported_direction: 'increase',
    effect_measure: 'mean_difference',
    estimate: '1.7',
    estimate_unit: 'kg',
    estimate_availability: 'reported_value',
    ci_lower: '0.9',
    ci_upper: '2.5',
    ci_level_percent: '95',
    confidence_interval_availability: 'reported_value',
    limitations_text: null,
    source_locator: 'Tabell 2, side 114',
    raw_extraction: null,
    ...overrides,
  }
}

/** Én evidenslenke i grunnlaget, slik dossieret gir den. */
export function reviewLink(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    claim_evidence_link_id: REVIEW_LINK,
    relationship_type: 'supports',
    directness: 'direct',
    relevance_note: 'Testnotat: funnet måler samme endepunkt i samme populasjon.',
    evidence_item: {
      evidence_item_id: REVIEW_EVIDENCE_ITEM,
      created_at: '2026-08-30T08:00:00Z',
      created_by_actor_id: '00000000-0000-4000-8000-444444444444',
      created_by_actor_key: 'agent:evidence-extraction',
      created_by_actor_type: 'agent',
      extraction_method: 'ai_assisted',
      content_hash: `sha256-v2:${'e'.repeat(64)}`,
      source: reviewSource(),
      source_version: {
        source_version_id: REVIEW_SOURCE_VERSION,
        retrieved_at: '2026-09-01T09:00:00Z',
        // Maskinens henteadresse. Den skal aldri være lenken kontrolløren får.
        retrieved_from: 'https://eutils.eksempel.invalid/efetch.fcgi?db=pubmed&id=10999999',
        external_version: null,
        content_hash: `sha256:${'a'.repeat(64)}`,
        representation: 'full_text',
        has_storage_reference: false,
      },
      field_groundings: TEST_FIELD_GROUNDINGS,
      semantic_check_fields: TEST_SEMANTIC_FIELDS,
      grounded_check_fields: TEST_SEMANTIC_FIELDS,
      // Maskinen har prøvd utdragene mot kilden. Uten dette stopper økten før
      // feltskuffene (migrasjon 005x, 005æ).
      grounding_machine_proved: true,
      source_wide_absence_fields: sourceWideAbsenceFieldsOf(reviewExtraction()),
      extraction: reviewExtraction(),
    },
    current_extraction_verification: {
      evidence_verification_id: '77777777-7777-4777-8777-333333333333',
      outcome: 'verified',
      source_access: 'original_source',
      checked_fields: ['estimate', 'reported_direction'],
      verified_at: '2026-09-02T10:00:00Z',
    },
    ...overrides,
  }
}

/** Hele svaret på et oppslag av én revisjon. */
export function claimReviewPayload(
  revisionOverrides: Record<string, unknown> = {},
  reviewerActorId: string = REVIEW_REVIEWER_ACTOR,
): Record<string, unknown> {
  return {
    reviewer_actor_id: reviewerActorId,
    revision: {
      claim_revision_id: REVIEW_REVISION,
      claim_id: REVIEW_CLAIM,
      revision_number: 1,
      knowledge_type: 'evidence_synthesis',
      created_at: '2026-09-01T08:00:00Z',
      created_by_actor_id: REVIEW_SYNTHESIS_ACTOR,
      created_by_actor_key: 'agent:claim-synthesis',
      created_by_actor_type: 'agent',
      content_hash: `sha256-v2:${'f'.repeat(64)}`,
      claim_retired_at: null,
      topic_concept_id: TOPIC_WEIGHT,
      topic_label: 'vektendring',
      subject_drug_id: DRUG_A,
      subject_drug_name: 'virkestoff a',
      evidence_set_digest: `sha256-v1:${'d'.repeat(64)}`,
      claim: {
        statement: 'Testpåstand til vurdering: virkestoff a er assosiert med vektøkning.',
        scope: 'Voksne, korttidsbehandling ved depresjon',
        population_id: null,
        population_label: null,
        timeframe_min: '56 days',
        timeframe_max: '56 days',
        comparator_kind: 'placebo',
        comparator_drug_id: null,
        comparator_drug_name: null,
        direction: 'increase',
        magnitude_measure: null,
        magnitude_value: null,
        magnitude_unit: null,
        qualifiers: null,
        uncertainty_summary: 'Få studier, og kort oppfølgingstid.',
      },
      links: [reviewLink()],
      unlinked_related_evidence: [],
      current_claim_verification_id: null,
      claim_verifications: [],
      current_review_decision_id: null,
      review_decisions: [],
      evidence_assessment: {
        evidence_assessment_id: '99999999-9999-4999-8999-333333333333',
        framework: 'grade',
        certainty_level: 'low',
        risk_of_bias: 'serious',
        inconsistency: 'not_assessable',
        indirectness: 'not_serious',
        imprecision: 'serious',
        publication_bias: 'not_assessable',
        other_considerations: null,
        rationale: 'Testbegrunnelse for sikkerhetsgraden.',
        evidence_gap: null,
        assessed_at: '2026-09-02T12:00:00Z',
      },
      is_published_revision: false,
      publication_gate: {
        status: 'blocked',
        sqlstate: '23001',
        message: 'Revisjon har ingen registrert claim-verifikasjon.',
        hint: 'En separat kontrollfase skal ha forsøkt å falsifisere påstanden.',
      },
      approval_readiness: {
        status: 'blocked',
        sqlstate: '23001',
        message: 'Revisjon har ingen registrert claim-verifikasjon.',
        hint: 'En separat kontrollfase skal ha forsøkt å falsifisere påstanden.',
      },
      ...revisionOverrides,
    },
  }
}

/** Én registrert claim-verifikasjon, slik historikken gir den. */
export function reviewVerificationRecord(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    claim_verification_id: '11111111-1111-4111-8111-333333333333',
    outcome: 'uncertain',
    source_access: 'verifiable_representation',
    verified_at: '2026-09-03T10:00:00Z',
    created_at: '2026-09-03T10:00:00Z',
    verifier_actor_id: '00000000-0000-4000-8000-555555555555',
    verifier_actor_key: 'agent:citation-support-verification',
    verifier_actor_type: 'agent',
    verifier_display_name: 'Claim-verifikator',
    agent_run_id: '11111111-1111-4111-8111-444444444444',
    verified_evidence_set_digest: `sha256-v1:${'d'.repeat(64)}`,
    checks: {
      source_support: 'not_assessable',
      population_match: 'ok',
      comparator_match: 'ok',
      timeframe_match: 'ok',
      direction_and_magnitude: 'ok',
      qualifiers_complete: 'not_assessable',
      contradictory_evidence_represented: 'not_assessable',
    },
    findings: 'Ordlyd og forbehold krever språkforståelse.',
    rationale: 'Deterministisk kontroll uten avvik, men uten mulighet til å konkludere.',
    citations: [
      {
        claim_evidence_link_id: REVIEW_LINK,
        evidence_item_id: REVIEW_EVIDENCE_ITEM,
        source_access: 'verifiable_representation',
        source_version_id: REVIEW_SOURCE_VERSION,
        checked_content_hash: `sha256:${'a'.repeat(64)}`,
        relationship_supported: 'not_assessable',
        finding: 'Relasjonstypen lot seg ikke bedømme deterministisk.',
      },
    ],
    ...overrides,
  }
}

/** Én registrert publiseringsbeslutning. */
export function reviewDecisionRecord(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    review_decision_id: '11111111-1111-4111-8111-555555555555',
    decision: 'approved',
    decided_at: '2026-09-04T10:00:00Z',
    created_at: '2026-09-04T10:00:00Z',
    reviewer_actor_id: REVIEW_REVIEWER_ACTOR,
    reviewer_actor_key: 'human:testreviewer',
    reviewer_display_name: 'Test Reviewer',
    rationale: 'Går god for at påstanden kan publiseres på dette grunnlaget.',
    approved_evidence_set_digest: `sha256-v1:${'d'.repeat(64)}`,
    ...overrides,
  }
}

// ----------------------------------------------------------------------------
// Kildekontroll av ett evidensfunn (migrasjon 005r, 005s, 005t)
//
// Fiksturene bygger jsonb-svaret slik `api.extraction_review_workspace(uuid)`
// faktisk gir det. Selve evidensfunnet er nøyaktig den formen
// `workflow.evidence_extraction_dossier(uuid)` bygger, og den formen finnes
// allerede i `reviewLink()` — den gjenbrukes her, av samme grunn som databasen
// bare har én projeksjon: to fiksturer av samme form ville før eller siden
// beskrevet to forskjellige grunnlag.
// ----------------------------------------------------------------------------

const EXTRACTION_VERIFICATION = '77777777-7777-4777-8777-555555555555'

export const TEST_EXTRACTION_IDS = {
  evidenceItem: REVIEW_EVIDENCE_ITEM,
  sourceVersion: REVIEW_SOURCE_VERSION,
  extractorActor: '00000000-0000-4000-8000-444444444444',
  reviewerActor: REVIEW_REVIEWER_ACTOR,
  verification: EXTRACTION_VERIFICATION,
  digest: `sha256-v1:${'b'.repeat(64)}`,
} as const

/** Feltene funnet i fiksturen påstår noe om, slik gaten regner dem ut. */
/**
 * Feltene raden fører uten verdi med en begrunnelse som gjelder kilden SOM
 * HELHET, utledet slik `workflow.source_wide_absence_fields(uuid)` gjør det.
 *
 * Avledet av ekstraksjonen framfor satt fast, slik at en test som bytter én
 * availability-verdi, automatisk får det grunnlaget databasen ville gitt. En
 * fast liste ville latt fiksturen si noe annet enn raden.
 */
export function sourceWideAbsenceFieldsOf(extraction: Record<string, unknown>): readonly string[] {
  const global = (key: string) =>
    extraction[key] === 'not_reported' || extraction[key] === 'not_measured'
  return [
    ...(global('population_availability') ? ['population'] : []),
    ...(global('sample_size_availability') ? ['sample_size'] : []),
    ...(global('timepoint_availability') ? ['timepoint'] : []),
    ...(global('estimate_availability') ? ['estimate'] : []),
    ...(global('confidence_interval_availability') ? ['confidence_interval'] : []),
  ]
}

const EXTRACTION_REQUIRED_FIELDS = [
  'raw_extraction',
  'source_locator',
  'intervention_arm',
  'outcome',
  'reported_direction',
  'availability_semantics',
  'effect_measure',
  'comparator_arm',
  'population',
  'sample_size',
  'timepoint',
  'estimate',
  'confidence_interval',
]

/** Én kørad, slik køen gir den. */
export function extractionQueueItem(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    evidence_item_id: REVIEW_EVIDENCE_ITEM,
    created_at: '2026-08-30T08:00:00Z',
    created_by_actor_id: TEST_EXTRACTION_IDS.extractorActor,
    created_by_actor_key: 'agent:evidence-extraction',
    source_id: SOURCE_A,
    source_title: 'Testkilde A: vektendring ved åtte uker',
    source_status: 'active',
    intervention_drug_name: 'virkestoff a',
    outcome_label: 'vektendring',
    outcome_concept_id: TOPIC_WEIGHT,
    current_extraction_verification_outcome: null,
    verification_count: 0,
    required_check_fields: EXTRACTION_REQUIRED_FIELDS,
    covered_check_fields: [],
    linked_claim_revision_count: 1,
    ...overrides,
  }
}

/** Hele køsvaret. */
export function extractionQueuePayload(
  items: readonly Record<string, unknown>[] = [extractionQueueItem()],
): Record<string, unknown> {
  return { reviewer_actor_id: REVIEW_REVIEWER_ACTOR, queue: items }
}

/** Én registrert ekstraksjonskontroll, slik historikken gir den. */
export function extractionVerificationRecord(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    evidence_verification_id: EXTRACTION_VERIFICATION,
    outcome: 'uncertain',
    source_access: 'verifiable_representation',
    checked_fields: ['source_locator', 'raw_extraction'],
    findings: 'Fant ikke utdraget som dekker tidspunktet.',
    rationale: 'Deterministisk kontroll mot den lagrede representasjonen.',
    verified_at: '2026-09-02T10:00:00Z',
    created_at: '2026-09-02T10:00:00Z',
    verifier_actor_id: '00000000-0000-4000-8000-666666666666',
    verifier_actor_key: 'agent:extraction-verification',
    verifier_actor_type: 'agent',
    verifier_display_name: 'Ekstraksjonsverifikator',
    agent_run_id: '11111111-1111-4111-8111-666666666666',
    ...overrides,
  }
}

/** Hele svaret på et oppslag av ett evidensfunn. */
export function extractionReviewPayload(
  itemOverrides: Record<string, unknown> = {},
  reviewerActorId: string = REVIEW_REVIEWER_ACTOR,
): Record<string, unknown> {
  const dossier = reviewLink()['evidence_item'] as Record<string, unknown>
  // Avledet etter at overstyringene er lagt på, slik at en test som endrer en
  // availability-verdi får både fraværslisten og gatens krav som databasen
  // ville gitt dem (migrasjon 005ae).
  const extraction = (itemOverrides['extraction'] ?? dossier['extraction']) as Record<
    string,
    unknown
  >
  const sourceWide = sourceWideAbsenceFieldsOf(extraction)
  return {
    reviewer_actor_id: reviewerActorId,
    item: {
      ...dossier,
      source_wide_absence_fields: sourceWide,
      extraction_digest: TEST_EXTRACTION_IDS.digest,
      required_check_fields:
        sourceWide.length === 0
          ? EXTRACTION_REQUIRED_FIELDS
          : [...EXTRACTION_REQUIRED_FIELDS, 'source_wide_absence'],
      covered_check_fields: [],
      current_extraction_verification_id: null,
      extraction_verifications: [],
      linked_claim_revisions: [
        {
          claim_revision_id: REVIEW_REVISION,
          claim_id: REVIEW_CLAIM,
          revision_number: 1,
          statement: 'Testpåstand til vurdering: virkestoff a er assosiert med vektøkning.',
          subject_drug_name: 'virkestoff a',
          topic_label: 'vektendring',
          relationship_type: 'supports',
          is_published_revision: false,
        },
      ],
      ...itemOverrides,
    },
  }
}
