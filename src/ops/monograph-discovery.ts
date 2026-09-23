// ============================================================================
// Kjøringen som faktisk søker
//
// Henter de maskinelle søkerundene kildeleddene har åpne, kjører søkene mot de
// navngitte offentlige plattformene, og registrerer hvert søk gjennom den
// kontrollerte skriveveien — med endepunktet og et fingeravtrykk av svaret,
// slik at utførelsen er maskinelt bekreftet og ikke en beretning.
//
// ----------------------------------------------------------------------------
// Hvorfor kjøringen henter *runder* og ikke bare planer
//
// Fordi arbeidsdelingen går begge veier. Fram til migrasjon 013v kjørte denne
// kommandoen de samme tre søkene mot hver åpne plan, hver gang, og den
// semantiske agenten ble samtidig bedt om å utføre sine egne søk — noe den
// ikke har verktøy til. Nå er det ett kretsløp: Antidep søker, agenten vurderer
// og ber om flere søk, Antidep søker igjen. Runden er bestillingen, og den sier
// hvilken strategi, hvilke termer og hvilken plattform søket gjelder.
//
// ----------------------------------------------------------------------------
// Hva kjøringen ikke gjør
//
// Den tar ingen faglig avgjørelse. Den velger ikke kilder, den avgjør ikke om
// dekningen holder, og den kan ikke lukke en søkeplan. Alle tre er faglige
// vurderinger med hver sin rolle og hver sin kontroll: utvalget er
// kildeoppdagelsens, dekningen er den separate kontrollens, og lukkingen er en
// port i databasen som leser begge (SOURCE_POLICY.md §8.1).
//
// Kjøringen legger med andre ord *grunnlag* i loggen. Den er en søkemotor med
// kvittering, ikke et ledd som konkluderer.
//
// ----------------------------------------------------------------------------
// Loggen er offentlig
//
// Kommandoen kjøres planlagt i et offentlig repo. Den skriver derfor bare
// stabile driftssetninger og aldri en videreformidlet feiltekst: en avvisning
// fra databasen kan navngi en kilde eller en avgrensning, og en offentlig logg
// skal ikke bli et sted slikt samler seg (AGENTS.md).
// ============================================================================

import { guardedGet } from '../agents/guarded-http.ts'
import type { Fetcher, MachineSearch, SearchScope } from './monograph-search.ts'
import { createPoliteFetcher, type PoliteFetcherOptions } from './search-http.ts'
import { resolveRequestMethods, SEARCH_METHODS, type SearchMethod } from './search-methods.ts'

/**
 * De to leddene kjøringen kan utføre søk for.
 *
 * De er atskilte med vilje, og de kjører med hver sin legitimasjon: et motsøk
 * registrert under generatorens identitet ville ikke vært et motsøk, og
 * databasen utleder kontrollens uavhengighet av nettopp hvilken rolle kjøringen
 * gikk under (SOURCE_POLICY.md §6).
 */
export type DiscoveryLeg = 'discovery' | 'coverage'

/** Premissene registreringsleddet kjører under (provenance.role_model_assignments). */
export const DISCOVERY_REGISTRATION_PREMISES = {
  provider: 'antidep',
  model: 'search-execution-and-registration',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'source-discovery/machine-execution/2',
  pipelineVersion: 'antidep-evidence/1',
} as const

/** Og premissene dekningskontrollens egne motsøk kjøres under. Egen tildeling. */
export const COVERAGE_REGISTRATION_PREMISES = {
  provider: 'antidep',
  model: 'coverage-control-registration',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'source-coverage/machine-countersearch/1',
  pipelineVersion: 'antidep-evidence/1',
} as const

/** Hvilken agentrolle og hvilke premisser hvert ledd kjører under. */
export const LEGS: Readonly<
  Record<
    DiscoveryLeg,
    {
      readonly agentRole: 'source_discovery' | 'source_quality_assessment'
      readonly premises:
        typeof DISCOVERY_REGISTRATION_PREMISES | typeof COVERAGE_REGISTRATION_PREMISES
      readonly label: string
    }
  >
> = {
  discovery: {
    agentRole: 'source_discovery',
    premises: DISCOVERY_REGISTRATION_PREMISES,
    label: 'kildeoppdagelsen',
  },
  coverage: {
    agentRole: 'source_quality_assessment',
    premises: COVERAGE_REGISTRATION_PREMISES,
    label: 'dekningskontrollens motsøk',
  },
}

/** Én bestilt søkerunde, slik `api.monograph_discovery_work` gir den. */
export interface SearchRequest {
  readonly requestReference: string
  readonly searchRound: number
  readonly origin: string
  readonly strategy: 'broad' | 'targeted'
  readonly rationale: string
  /** Plattformen runden gjelder, eller null for alle. */
  readonly platform: string | null
  /** Søkemetoden runden gjelder, eller null for de bibliografiske fritekstsøkene. */
  readonly method: string | null
  /**
   * Nøyaktig de (plattform, metode) runden betyr, slik databasen leser den
   * (`workflow.monograph_request_methods`). Kjøreren utfører denne listen og
   * gjetter ikke selv hva en forespørsel uten metode betyr.
   */
  readonly methods: readonly { readonly platform: string; readonly method: string }[]
  /** De sentrale kildene runden skal følge, som «doi:…», «pmid:…» eller «pmcid:…». */
  readonly seedIdentifiers: readonly string[]
  /**
   * Virkestoffnavn som skal søkes som ALTERNATIVER til det kanoniske.
   *
   * Egen liste og ikke en term: et synonym lagt til som et ekstra påkrevd
   * begrep gir «"sertralin" AND "sertraline"», og da kan ikke en artikkel som
   * bare bruker det engelske navnet, treffe i det hele tatt.
   */
  readonly drugAliases: readonly string[]
  readonly queryTerms: readonly string[]
  readonly filtersNote: string | null
  /**
   * De obligatoriske søkesporene runden kan erklære å dekke.
   *
   * Listen kommer fra databasen og ikke fra plattformdefinisjonene: hvilke spor
   * som er obligatoriske, er en kildepolitisk avgjørelse, og en kjører som
   * avgjorde det selv, kunne fått porten til å se dekket ut (SOURCE_POLICY.md
   * §4.2). Dekningskontrollens motsøk har alltid ingen.
   */
  readonly trackCodes: readonly string[]
  readonly attempts: number
  readonly state: string
}

/** Én søkeplan med de rundene som står åpne for kallerens eget ledd. */
export interface DiscoveryPlan {
  readonly planReference: string
  readonly drug: string
  readonly editionReference: string
  readonly scope: SearchScope
  readonly profileCode: string
  readonly searchRound: number
  readonly requests: readonly SearchRequest[]
}

/** Databasegrensen kjøringen bruker. Et smalt grensesnitt, av to grunner:
 *  prøvene trenger ingen Supabase-klient, og kjøringen kan ikke røre noe annet. */
export interface DiscoveryApi {
  readonly work: () => Promise<readonly DiscoveryPlan[]>
  readonly beginRun: (planReference: string) => Promise<string>
  readonly recordSearch: (
    agentRunId: string,
    planReference: string,
    requestReference: string,
    search: MachineSearch,
  ) => Promise<void>
  /** Lukker runden, og lar databasen avgjøre hva den ble. */
  readonly closeRequest: (
    agentRunId: string,
    requestReference: string,
  ) => Promise<{ readonly state: string; readonly enqueuedJob: boolean }>
  /** Lukker kjøringen. En mislykket kjøring bærer grunnen (provenance.agent_runs). */
  readonly completeRun: (
    agentRunId: string,
    status: 'succeeded' | 'failed',
    outcome: Record<string, unknown>,
    failureReason?: string,
  ) => Promise<void>
}

export interface DiscoveryReport {
  readonly plans: number
  readonly requests: number
  readonly searches: number
  readonly executed: number
  readonly zeroResults: number
  readonly unavailable: number
  readonly failed: number
  readonly candidates: number
  readonly fulfilled: number
  readonly stillUnavailable: number
  readonly tasksOpened: number
  readonly problems: readonly string[]
}

export interface DiscoveryOptions {
  /** Hvor mange planer én kjøring tar. En driftskjøring er ikke en støvsuger. */
  readonly maxPlans: number
  readonly methods: readonly SearchMethod[]
  readonly fetcher?: Fetcher | undefined
  /**
   * Takt, nye forsøk og deling innen kjøringen (`search-http.ts`). `false` slår
   * det av — bare for prøver som spiller av et opptak og ikke skal vente.
   */
  readonly politeness?: Partial<PoliteFetcherOptions> | false | undefined
  readonly now?: (() => Date) | undefined
}

export const DISCOVERY_DEFAULTS = {
  maxPlans: 5,
  methods: SEARCH_METHODS,
} as const

/**
 * Kjører de åpne søkerundene.
 *
 * Feiler aldri på én plan: en runde som ikke lot seg registrere, telles som et
 * problem og resten kjøres. En kjøring som stoppet på den første avvisningen,
 * ville latt resten av monografien stå.
 */
export async function runMonographDiscovery(
  api: DiscoveryApi,
  options: Partial<DiscoveryOptions> = {},
): Promise<DiscoveryReport> {
  const settings: DiscoveryOptions = { ...DISCOVERY_DEFAULTS, ...options }
  const plans = (await api.work()).slice(0, settings.maxPlans)
  const baseFetcher = settings.fetcher ?? guardedGet
  // Én høflig henter for hele kjøringen: takten og delingen gjelder på tvers av
  // planene, og det er nettopp der FEST og EMAs datasett leses mange ganger.
  const fetcher =
    settings.politeness === false
      ? baseFetcher
      : createPoliteFetcher(baseFetcher, settings.politeness ?? {})
  const memo = new Map<string, unknown>()
  const now = settings.now ?? (() => new Date())

  let requests = 0
  let searches = 0
  let executed = 0
  let zeroResults = 0
  let unavailable = 0
  let failed = 0
  let candidates = 0
  let fulfilled = 0
  let stillUnavailable = 0
  let tasksOpened = 0
  const problems: string[] = []

  for (const plan of plans) {
    if (plan.requests.length === 0) {
      continue
    }

    let agentRunId: string
    try {
      agentRunId = await api.beginRun(plan.planReference)
    } catch {
      problems.push(`Kunne ikke åpne en kjøring for én søkeplan (${plan.profileCode}).`)
      continue
    }

    let recorded = 0
    let closed = 0
    // Problemene denne planens kjøring fikk. En kjøring med et teknisk problem
    // er en mislykket kjøring, og står slik i proveniensen — ikke som en
    // vellykket kjøring med en begrensning i evidensen.
    const planProblemsFrom = problems.length

    for (const request of plan.requests) {
      requests += 1
      // Hva runden betyr, er databasens svar. Mangler det — en eldre base —
      // leses det av den samme regelen her.
      const wanted =
        request.methods.length > 0
          ? request.methods
          : resolveRequestMethods(settings.methods, request.platform, request.method)
      const aliases = [...new Set([...(plan.scope.drugAliases ?? []), ...request.drugAliases])]

      // En metode databasen kjenner og kjøreren ikke har, er en feil i
      // utrullingen og ikke et søk uten treff. Runden røres da ikke: den
      // utføres ikke halvt, og den lukkes ikke — en lukket runde uten søk ville
      // blitt «utilgjengelig», sluppet den semantiske oppgaven fri og til slutt
      // blitt gitt opp, uten at en eneste tjeneste var spurt. Den står åpen til
      // en kjører som har metoden, tar den.
      const methods = wanted.map((entry) => ({
        entry,
        method: settings.methods.find(
          (candidate) => candidate.platform === entry.platform && candidate.method === entry.method,
        ),
      }))
      const missing = methods.filter((pair) => pair.method === undefined)
      if (missing.length > 0) {
        for (const { entry } of missing) {
          problems.push(
            `Kjøreren har ikke søkemetoden ${entry.platform} (${entry.method}) som én søkerunde ba om (${plan.profileCode}); runden står åpen.`,
          )
        }
        continue
      }

      let unrecorded = 0
      for (const { method } of methods) {
        if (method === undefined) continue

        const results = await method.execute({
          scope: plan.scope,
          profileCode: plan.profileCode,
          strategy: request.strategy,
          queryTerms: request.queryTerms,
          drugAliases: aliases,
          seeds: request.seedIdentifiers,
          allowedTracks: request.trackCodes,
          fetcher,
          memo,
          now: now(),
        })

        for (const search of results) {
          searches += 1
          if (search.outcome === 'executed') executed += 1
          if (search.outcome === 'zero_results') zeroResults += 1
          if (search.outcome === 'unavailable') unavailable += 1
          if (search.outcome === 'failed') failed += 1
          candidates += search.candidates.length

          try {
            await api.recordSearch(agentRunId, plan.planReference, request.requestReference, search)
            recorded += 1
          } catch {
            unrecorded += 1
            problems.push(
              `Et søk mot ${method.platform} (${method.method}) lot seg ikke registrere for én søkerunde (${plan.profileCode}); runden står åpen.`,
            )
          }
        }
      }

      // Et søk som ble utført, men ikke registrert, er en teknisk svikt og ikke
      // en søkevei som ikke svarte. Runden lukkes da ikke: en lukket runde uten
      // det søket ville blitt «utilgjengelig» eller «utført» på et grunnlag
      // søkeloggen ikke har, og sluppet den semantiske oppgaven fram. Den står
      // åpen, og neste kjøring utfører den på nytt.
      if (unrecorded > 0) {
        continue
      }

      // Ellers lukkes runden uansett hva søkene ga. Det er lukkingen som avgjør
      // om den semantiske oppgaven finnes nå — og en runde som aldri ble lukket,
      // ville latt planen stå uten at noe sa hvorfor.
      try {
        const outcome = await api.closeRequest(agentRunId, request.requestReference)
        closed += 1
        if (outcome.state === 'fulfilled') fulfilled += 1
        if (outcome.state === 'unavailable' || outcome.state === 'abandoned') stillUnavailable += 1
        if (outcome.enqueuedJob) tasksOpened += 1
      } catch {
        problems.push(`En søkerunde lot seg ikke lukkes for én søkeplan (${plan.profileCode}).`)
      }
    }

    const planProblems = problems.slice(planProblemsFrom)
    try {
      const outcome = {
        plan_reference: plan.planReference,
        searches_recorded: recorded,
        requests_closed: closed,
      }
      if (planProblems.length === 0) {
        await api.completeRun(agentRunId, 'succeeded', outcome)
      } else {
        await api.completeRun(agentRunId, 'failed', outcome, planProblems.join(' ').slice(0, 4000))
      }
    } catch {
      problems.push(`Kjøringen for én søkeplan (${plan.profileCode}) lot seg ikke lukkes.`)
    }
  }

  return {
    plans: plans.length,
    requests,
    searches,
    executed,
    zeroResults,
    unavailable,
    failed,
    candidates,
    fulfilled,
    stillUnavailable,
    tasksOpened,
    problems,
  }
}

/** Rapporten, i klartekst. Ingen kildenavn og ingen avgrensninger: loggen er offentlig. */
export function describeDiscoveryReport(report: DiscoveryReport): string {
  const lines = [
    `Søkeplaner tatt: ${report.plans}`,
    `Søkerunder utført: ${report.requests} ` +
      `(${report.fulfilled} gjennomført, ${report.stillUnavailable} uten en søkevei som svarte)`,
    `Søk utført: ${report.searches} ` +
      `(${report.executed} med treff, ${report.zeroResults} uten treff, ` +
      `${report.unavailable} utilgjengelige, ${report.failed} uleselige svar)`,
    `Kandidatkilder registrert: ${report.candidates}`,
    `Vurderingsoppgaver åpnet: ${report.tasksOpened}`,
  ]
  if (report.problems.length > 0) {
    lines.push('Problemer:')
    for (const problem of report.problems) {
      lines.push(`  - ${problem}`)
    }
  }
  return lines.join('\n')
}
