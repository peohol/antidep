// ============================================================================
// Hva et svar på én bestemt kildeoppgave kan si
//
// Svarformen for kildeleddene var den samme for hver oppgave, og to feil var
// derfor like lette å skrive som det riktige svaret — og de gjentok seg i drift
// (migrasjon 014i):
//
//   1. «excluded» for en kandidatkilde med registrert tilgangsbegrensning.
//      Raden forbyr det uansett grunn, men svarformen tilbød «excluded» for hver
//      kilde, og oppgaven sa regelen som en regel om begrunnelsen.
//   2. En `narrows_request` som ikke er en runde dette leddet kan erstatte.
//      Søkene i oppgaven er begge kildeleddenes, og svarformen sa bare «32
//      heksadesimale tegn».
//
// Grensene for det svaret kan si, leses her én gang av det databasen la i
// oppgaven, og brukes av tre lag som derfor ikke kan bli uenige: svarformen
// agenten får (`handoff-schemas.ts`), oppgaveteksten den leser
// (`agent-task-file.ts`) og kontrollen før svaret sendes (`handoff-result.ts`).
// Databasen avviser de samme svarene uansett. Dette er det som gjør at det
// riktige svaret er det naturlige — ikke grensen.
//
// Lesingen er lukket: en rad som ikke har formen, gir ingen mulighet i svaret.
// En runde som ikke kan leses, kan ikke tilbys, og en kilde uten et entydig
// `access_limited: false` behandles som tilgangsbegrenset.
// ============================================================================

import { SEARCH_REQUEST_METHODS, SEARCH_REQUEST_PLATFORMS } from '../ops/search-method-catalog.ts'

/** Utvalgsbeslutningene om én kandidatkilde. */
export const CANDIDATE_DECISIONS = [
  'proposed',
  'selected_for_retrieval',
  'included',
  'excluded',
  'awaiting_access',
  'awaiting_clarification',
] as const

/** Identifikatorformene en kandidatkilde kan stå med. */
export const CANDIDATE_IDENTIFIER_KINDS = [
  'doi',
  'pmid',
  'pmcid',
  'url',
  'title',
  'registry_id',
] as const

/** En kandidatkilde oppgaven har, slik svaret skal oppgi den. */
export interface AppraisableCandidate {
  readonly identifierKind: string
  readonly identifierValue: string
  readonly accessLimited: boolean
}

/**
 * Én søkerunde leddet kan erstatte med et smalere søk, og med hva.
 *
 * Én per (runde, plattform, metode): en runde som ble avkortet på to
 * plattformer, kan erstattes på hver av dem.
 */
export interface NarrowableRound {
  readonly requestReference: string
  readonly platform: string
  readonly method: string
  readonly queries: readonly string[]
}

export interface DiscoveryAnswerBounds {
  readonly candidates: readonly AppraisableCandidate[]
  readonly narrowableRounds: readonly NarrowableRound[]
}

/** Utvalgsbeslutningene en kilde med registrert tilgangsbegrensning kan få. */
export const ACCESS_LIMITED_DECISIONS: readonly string[] = CANDIDATE_DECISIONS.filter(
  (decision) => decision !== 'excluded',
)

const REQUEST_REFERENCE = /^[0-9a-f]{32}$/

function rows(value: unknown): readonly Record<string, unknown>[] {
  return Array.isArray(value)
    ? value.filter(
        (entry): entry is Record<string, unknown> =>
          typeof entry === 'object' && entry !== null && !Array.isArray(entry),
      )
    : []
}

function nonEmpty(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value : null
}

function candidateKey(kind: string, value: string): string {
  return `${kind}\u0000${value}`
}

function roundKey(round: Pick<NarrowableRound, 'requestReference' | 'platform' | 'method'>) {
  return `${round.requestReference}\u0000${round.platform}\u0000${round.method}`
}

/** Grensene for svaret, lest av oppgavematerialet databasen bygget. */
export function discoveryAnswerBounds(input: Record<string, unknown>): DiscoveryAnswerBounds {
  const candidates = new Map<string, AppraisableCandidate>()
  for (const row of rows(input['candidates'])) {
    const identifierKind = nonEmpty(row['identifier_kind'])
    const identifierValue = nonEmpty(row['identifier_value'])
    if (
      identifierKind === null ||
      identifierValue === null ||
      !(CANDIDATE_IDENTIFIER_KINDS as readonly string[]).includes(identifierKind)
    ) {
      continue
    }
    const key = candidateKey(identifierKind, identifierValue)
    const accessLimited =
      row['access_limited'] !== false || candidates.get(key)?.accessLimited === true
    candidates.set(key, { identifierKind, identifierValue, accessLimited })
  }

  const narrowable = new Map<string, NarrowableRound>()
  for (const row of rows(input['narrowable_rounds'])) {
    const requestReference = nonEmpty(row['request_reference'])
    const platform = nonEmpty(row['platform'])
    const method = nonEmpty(row['method'])
    if (
      requestReference === null ||
      !REQUEST_REFERENCE.test(requestReference) ||
      platform === null ||
      !SEARCH_REQUEST_PLATFORMS.includes(platform) ||
      method === null ||
      !SEARCH_REQUEST_METHODS.includes(method)
    ) {
      continue
    }
    const queries = Array.isArray(row['queries'])
      ? row['queries'].filter((query): query is string => typeof query === 'string')
      : []
    const round = { requestReference, platform, method, queries }
    narrowable.set(roundKey(round), round)
  }

  return { candidates: [...candidates.values()], narrowableRounds: [...narrowable.values()] }
}

/** Kandidatkilden svaret vurderer, eller `null` når oppgaven ikke har den. */
export function appraisableCandidate(
  bounds: DiscoveryAnswerBounds,
  identifierKind: string,
  identifierValue: string,
): AppraisableCandidate | null {
  return (
    bounds.candidates.find(
      (candidate) =>
        candidate.identifierKind === identifierKind &&
        candidate.identifierValue === identifierValue.trim(),
    ) ?? null
  )
}

/** Utvalgsbeslutningene svaret kan gi nettopp denne kilden. */
export function decisionsFor(candidate: AppraisableCandidate): readonly string[] {
  return candidate.accessLimited ? ACCESS_LIMITED_DECISIONS : CANDIDATE_DECISIONS
}

/** De ulike referansene svaret kan oppgi i `narrows_request`. */
export function narrowableReferences(rounds: readonly NarrowableRound[]): string[] {
  return [...new Set(rounds.map((round) => round.requestReference))]
}

/** Hvordan rundene kan erstattes, i én linje: referansen, plattformen og metoden. */
export function describeNarrowableRounds(rounds: readonly NarrowableRound[]): string {
  return rounds
    .map(
      (round) =>
        `«${round.requestReference}» med platform «${round.platform}» og method «${round.method}»`,
    )
    .join('; ')
}

/**
 * Hvorfor en erstatning ikke kan oppgis slik, eller `null` når den kan.
 *
 * Plattformen og metoden må være de rundene står med: et smalere søk erstatter
 * bare det samme slaget søk (SOURCE_POLICY.md §4.3).
 */
export function narrowingProblem(
  bounds: DiscoveryAnswerBounds,
  narrows: string,
  platform: string | null,
  method: string | null,
): string | null {
  if (bounds.narrowableRounds.length === 0) {
    return (
      'viser til en søkerunde, men ingen runde i denne oppgaven kan snevres inn av dette ' +
      'agentleddet. Utelat feltet'
    )
  }
  const rounds = bounds.narrowableRounds.filter((round) => round.requestReference === narrows)
  if (rounds.length === 0) {
    return (
      'er ikke en av søkerundene dette agentleddet kan snevre inn i denne oppgaven. Rundene ' +
      `som kan snevres inn, er ${describeNarrowableRounds(bounds.narrowableRounds)}`
    )
  }
  if (!rounds.some((round) => round.platform === platform && round.method === method)) {
    return (
      'erstatter en runde med en annen plattform eller metode enn runden brukte. Et smalere ' +
      `søk må være det samme slaget søk: ${describeNarrowableRounds(rounds)}`
    )
  }
  return null
}
