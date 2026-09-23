// ============================================================================
// Hentingen søkemetodene går gjennom
//
// Hver søkemetode henter med den samme `Fetcher`-formen som før, og hver av dem
// går fortsatt gjennom `guardedGet`: adressekontroll, redirect-kontroll,
// størrelsesgrense og tidsavbrudd er uendret. Det dette laget legger til, er
// tre ting en driftskjøring mot åpne, offentlige tjenester skylder dem:
//
//   Takt        Et minste mellomrom mellom to kall mot den samme verten.
//               NCBI ber om høyst tre kall i sekundet uten nøkkel, ClinPGx om
//               høyst to, og ClinicalTrials.gov har en grense per minutt. En
//               kjøring som slo i taket, ville fått 429 og registrert en
//               begrensning den selv hadde laget.
//   Nytt forsøk Et svar som sier «prøv igjen» — 429 og 5xx — eller en
//               forbindelse som ble brutt, prøves på nytt et par ganger med
//               økende pause. Et svar som sier noe om saken — 200, 400, 404 —
//               prøves ikke igjen: det er et svar.
//   Deling      Det samme kallet innen én kjøring hentes én gang. FEST og EMAs
//               datasett er det samme dokumentet for hver plan som leser dem,
//               og å hente dem atten ganger ville vært atten kall om det samme.
//               Søket som registreres for hver plan, bærer det samme
//               endepunktet og det samme responsavtrykket — fordi det er det
//               samme svaret som ble lest.
//
// Laget endrer ikke hva et svar *er*. En tjeneste som er nede etter siste
// forsøk, gir fortsatt et `error`- eller et 5xx-svar tilbake, og søkemetoden
// registrerer det som `unavailable` — aldri som null treff.
// ============================================================================

import type { Fetcher } from './monograph-search.ts'

type FetchResult = Awaited<ReturnType<Fetcher>>

/** Minste mellomrom mellom to kall mot en vert, i millisekunder. */
export const HOST_INTERVAL_MS: Readonly<Record<string, number>> = {
  'eutils.ncbi.nlm.nih.gov': 400,
  'api.clinpgx.org': 600,
  'clinicaltrials.gov': 1_300,
  'www.ebi.ac.uk': 150,
  'api.crossref.org': 150,
  'www.ema.europa.eu': 500,
  'www.dmp.no': 500,
}

const DEFAULT_INTERVAL_MS = 200

/** HTTP-statusene som betyr «prøv igjen», og ikke noe om saken. */
export const RETRYABLE_STATUSES: ReadonlySet<number> = new Set([429, 500, 502, 503, 504])

export interface PoliteFetcherOptions {
  /** Hvor mange nye forsøk et forbigående svar får. */
  readonly retries: number
  /** Pausen før forsøk nummer n (1, 2, …). */
  readonly backoffMs: (attempt: number) => number
  readonly sleep: (ms: number) => Promise<void>
  readonly now: () => number
  readonly intervals: Readonly<Record<string, number>>
}

export const POLITE_DEFAULTS: PoliteFetcherOptions = {
  retries: 2,
  backoffMs: (attempt) => 2_000 * attempt,
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  now: () => Date.now(),
  intervals: HOST_INTERVAL_MS,
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname
  } catch {
    return ''
  }
}

function transient(result: FetchResult): boolean {
  return result.status === 'error' || RETRYABLE_STATUSES.has(result.httpStatus)
}

/**
 * En `Fetcher` med takt per vert, nye forsøk ved forbigående svar, og deling
 * av vellykkede svar innen kjøringen.
 *
 * Lages én gang per kjøring. Delingen gjelder bare den kjøringen: neste
 * planlagte kjøring henter på nytt, slik at en oppdatert FEST-fil eller et
 * nytt EMA-datasett faktisk blir lest.
 */
export function createPoliteFetcher(
  base: Fetcher,
  options: Partial<PoliteFetcherOptions> = {},
): Fetcher {
  const settings: PoliteFetcherOptions = { ...POLITE_DEFAULTS, ...options }
  const lastCall = new Map<string, number>()
  const shared = new Map<string, Promise<FetchResult>>()

  async function paced(url: string): Promise<void> {
    const host = hostOf(url)
    const interval = settings.intervals[host] ?? DEFAULT_INTERVAL_MS
    const previous = lastCall.get(host)
    if (previous !== undefined) {
      const wait = previous + interval - settings.now()
      if (wait > 0) {
        await settings.sleep(wait)
      }
    }
    lastCall.set(host, settings.now())
  }

  async function withRetries(url: string, overrides: Parameters<Fetcher>[1]): Promise<FetchResult> {
    let result: FetchResult = { status: 'error', message: 'Ingen forsøk ble gjort.' }
    for (let attempt = 0; attempt <= settings.retries; attempt += 1) {
      if (attempt > 0) {
        await settings.sleep(settings.backoffMs(attempt))
      }
      await paced(url)
      result = await base(url, overrides)
      if (!transient(result)) {
        return result
      }
    }
    return result
  }

  return async (url, overrides) => {
    const cached = shared.get(url)
    if (cached !== undefined) {
      return cached
    }
    const pending = withRetries(url, overrides)
    shared.set(url, pending)
    const result = await pending
    // Bare et vellykket svar deles. Et forbigående svar skal få et nytt forsøk
    // neste gang noen spør, og ikke bli husket som sannheten for resten av
    // kjøringen.
    if (result.status !== 'ok' || result.httpStatus < 200 || result.httpStatus >= 300) {
      shared.delete(url)
    }
    return result
  }
}
