// ============================================================================
// Kjøringen som faktisk søker
//
// Henter det arbeidet kildeoppdagelsen har åpent, kjører de maskinelle søkene
// mot de tre offentlige plattformene, og registrerer hvert søk gjennom den
// kontrollerte skriveveien — med endepunktet og et fingeravtrykk av svaret,
// slik at utførelsen er maskinelt bekreftet og ikke en beretning.
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
// Kommandoen kan kjøres planlagt i et offentlig repo. Den skriver derfor bare
// stabile driftssetninger og aldri en videreformidlet feiltekst: en avvisning
// fra databasen kan navngi en kilde eller en avgrensning, og en offentlig logg
// skal ikke bli et sted slikt samler seg (AGENTS.md).
// ============================================================================

import type { Fetcher, MachineSearch, SearchScope } from './monograph-search.ts'
import { runSearch, SEARCH_PLATFORMS, type SearchPlatform } from './monograph-search.ts'

/** Premissene registreringsleddet kjører under (provenance.role_model_assignments). */
export const DISCOVERY_REGISTRATION_PREMISES = {
  provider: 'antidep',
  model: 'search-execution-and-registration',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'source-discovery/machine-execution/1',
  pipelineVersion: 'antidep-evidence/1',
} as const

/** Én søkeplan, slik `api.monograph_discovery_work` gir den. */
export interface DiscoveryPlan {
  readonly planReference: string
  readonly drug: string
  readonly editionReference: string
  readonly scope: SearchScope
  readonly profileCode: string
}

/** Databasegrensen kjøringen bruker. Et smalt grensesnitt, av to grunner:
 *  prøvene trenger ingen Supabase-klient, og kjøringen kan ikke røre noe annet. */
export interface DiscoveryApi {
  readonly work: () => Promise<readonly DiscoveryPlan[]>
  readonly beginRun: (planReference: string) => Promise<string>
  readonly recordSearch: (
    agentRunId: string,
    planReference: string,
    search: MachineSearch,
  ) => Promise<void>
  readonly completeRun: (
    agentRunId: string,
    status: 'succeeded' | 'failed',
    outcome: Record<string, unknown>,
  ) => Promise<void>
}

export interface DiscoveryReport {
  readonly plans: number
  readonly searches: number
  readonly executed: number
  readonly zeroResults: number
  readonly unavailable: number
  readonly failed: number
  readonly candidates: number
  readonly problems: readonly string[]
}

export interface DiscoveryOptions {
  /** Hvor mange planer én kjøring tar. En driftskjøring er ikke en støvsuger. */
  readonly maxPlans: number
  readonly platforms: readonly SearchPlatform[]
  readonly fetcher?: Fetcher | undefined
}

export const DISCOVERY_DEFAULTS = {
  maxPlans: 5,
  platforms: SEARCH_PLATFORMS,
} as const

/**
 * Kjører søkene for de åpne søkeplanene.
 *
 * Feiler aldri på én plan: en plan som ikke lot seg registrere, telles som et
 * problem og resten kjøres. En kjøring som stoppet på den første avvisningen,
 * ville latt resten av monografien stå.
 */
export async function runMonographDiscovery(
  api: DiscoveryApi,
  options: Partial<DiscoveryOptions> = {},
): Promise<DiscoveryReport> {
  const settings: DiscoveryOptions = { ...DISCOVERY_DEFAULTS, ...options }
  const plans = (await api.work()).slice(0, settings.maxPlans)

  let searches = 0
  let executed = 0
  let zeroResults = 0
  let unavailable = 0
  let failed = 0
  let candidates = 0
  const problems: string[] = []

  for (const plan of plans) {
    let agentRunId: string
    try {
      agentRunId = await api.beginRun(plan.planReference)
    } catch {
      problems.push(`Kunne ikke åpne en kjøring for én søkeplan (${plan.profileCode}).`)
      continue
    }

    let recorded = 0
    for (const platform of settings.platforms) {
      const search = await runSearch(platform, plan.scope, settings.fetcher)
      searches += 1
      if (search.outcome === 'executed') executed += 1
      if (search.outcome === 'zero_results') zeroResults += 1
      if (search.outcome === 'unavailable') unavailable += 1
      if (search.outcome === 'failed') failed += 1
      candidates += search.candidates.length

      try {
        await api.recordSearch(agentRunId, plan.planReference, search)
        recorded += 1
      } catch {
        problems.push(
          `Et søk mot ${platform.name} lot seg ikke registrere for én søkeplan (${plan.profileCode}).`,
        )
      }
    }

    try {
      await api.completeRun(agentRunId, 'succeeded', {
        plan_reference: plan.planReference,
        searches_recorded: recorded,
      })
    } catch {
      problems.push(`Kjøringen for én søkeplan (${plan.profileCode}) lot seg ikke lukkes.`)
    }
  }

  return {
    plans: plans.length,
    searches,
    executed,
    zeroResults,
    unavailable,
    failed,
    candidates,
    problems,
  }
}

/** Rapporten, i klartekst. Ingen kildenavn og ingen avgrensninger: loggen er offentlig. */
export function describeDiscoveryReport(report: DiscoveryReport): string {
  const lines = [
    `Søkeplaner tatt: ${report.plans}`,
    `Søk utført: ${report.searches} ` +
      `(${report.executed} med treff, ${report.zeroResults} uten treff, ` +
      `${report.unavailable} utilgjengelige, ${report.failed} uleselige svar)`,
    `Kandidatkilder registrert: ${report.candidates}`,
  ]
  if (report.problems.length > 0) {
    lines.push('Problemer:')
    for (const problem of report.problems) {
      lines.push(`  - ${problem}`)
    }
  }
  return lines.join('\n')
}
