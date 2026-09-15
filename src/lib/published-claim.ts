// ============================================================================
// Det publiserte klinikerinnholdet, lest
//
// `api.published_claim(uuid)` svarer med jsonb, og jsonb har ingen kolonnetyper
// PostgREST kan håndheve. Formen leses derfor her, med den samme strengheten
// kandidatsvaret leses med: et felt som mangler, er en feil — ikke en tom rute i
// en klinisk visning.
//
// ----------------------------------------------------------------------------
// Hvorfor innholdet leses av den samme funksjonen som kandidatens
//
// Det *er* den samme raden. Klinikeren ser `knowledge.candidates.content` for
// den kandidaten publiseringspekeren navngir, og sluttkontrolløren så den samme
// raden før publiseringen. To lesinger av det samme avtrykket ville før eller
// siden vist forskjellige ting, og da ville «det som ble godkjent» og «det som
// vises» vært to påstander framfor én (ANTIDEP_CONSTITUTION.md regel 5).
//
// ----------------------------------------------------------------------------
// Hvorfor «ikke publisert» er en egen tilstand og ikke en tom side
//
// En påstand som er trukket tilbake, har fortsatt en historikk, og den
// historikken er hele poenget med at tilbaketrekkingen er synlig
// (ANTIDEP_CONSTITUTION.md regel 6). `content` er derfor `null` og ikke et tomt
// objekt, og `withdrawn` sier hvorfor.
//
// Utrygg inndata: svaret er data. Ingenting her tolker en verdi som markup.
// ============================================================================

import { parseSealedContent, type SealedContent } from './candidate-view.ts'

/** Én hendelse i publiseringshistorikken, slik den skal vises. */
export interface PublicationEvent {
  readonly publicationEventId: string
  /**
   * Påstanden hendelsen gjelder.
   *
   * `null` når hendelsen er lest ut av historikken for én påstand: da er den
   * allerede kjent, og svaret gjentar den ikke.
   */
  readonly claimId: string | null
  /** Plassen i hendelseskjeden. Rekkefølgen er kjedens, aldri klokkas. */
  readonly sequence: number
  readonly action: string
  readonly publishedAt: string
  readonly publishedBy: string
  readonly reason: string
  readonly claimRevisionId: string | null
  readonly revisionNumber: number | null
  readonly candidateId: string | null
  readonly candidateDigest: string | null
  readonly previousCandidateId: string | null
  readonly previousCandidateDigest: string | null
  /** `null` på en tilbaketrekking: den hviler ikke på en godkjenning. */
  readonly finalControl: PublishedFinalControl | null
}

export interface PublishedFinalControl {
  readonly decision: string
  readonly decidedAt: string
  readonly reviewer: string
  readonly rationale: string
}

/** Det klinikerflaten viser om én påstand. */
export interface PublishedClaimView {
  readonly claimId: string
  readonly published: boolean
  /** `true` når det siste som skjedde, var en tilbaketrekking. */
  readonly withdrawn: boolean
  /** `null` når ingenting er publisert nå — ikke et tomt innhold. */
  readonly content: SealedContent | null
  readonly claimRevisionId: string | null
  readonly candidateId: string | null
  readonly candidateDigest: string | null
  readonly evidenceSetDigest: string | null
  readonly publication: PublicationEvent | null
  readonly finalControl: PublishedFinalControl | null
  readonly history: readonly PublicationEvent[]
}

/** Én rad i den publiserte katalogen: nok til å velge én påstand. */
export interface PublishedClaimEntry {
  readonly claimId: string
  readonly candidateId: string
  readonly candidateDigest: string
  readonly statement: string
  readonly subjectDrug: string
  readonly topic: string
  readonly certaintyLevel: string | null
  readonly sourceCount: number
  readonly publishedAt: string
}

const SUBJECT = 'Det publiserte svaret'

function fail(where: string, what: string): never {
  throw new Error(`${SUBJECT} er ugyldig: ${where} ${what}.`)
}

function objectAt(value: unknown, where: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    fail(where, 'er ikke et objekt')
  }
  return value as Record<string, unknown>
}

function text(record: Record<string, unknown>, key: string, where: string): string {
  const value = record[key]
  if (typeof value !== 'string' || value.length === 0) {
    fail(`${where}.${key}`, 'mangler')
  }
  return value
}

function optionalText(record: Record<string, unknown>, key: string, where: string): string | null {
  const value = record[key]
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'string') {
    fail(`${where}.${key}`, 'er ikke tekst')
  }
  return value
}

function flag(record: Record<string, unknown>, key: string, where: string): boolean {
  const value = record[key]
  if (typeof value !== 'boolean') {
    fail(`${where}.${key}`, 'er ikke en ja/nei-verdi')
  }
  return value
}

function count(record: Record<string, unknown>, key: string, where: string): number {
  const value = record[key]
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    fail(`${where}.${key}`, 'er ikke et tall')
  }
  return value
}

function optionalCount(record: Record<string, unknown>, key: string, where: string): number | null {
  const value = record[key]
  if (value === undefined || value === null) {
    return null
  }
  return count(record, key, where)
}

function list(record: Record<string, unknown>, key: string, where: string): unknown[] {
  const value = record[key]
  if (!Array.isArray(value)) {
    fail(`${where}.${key}`, 'er ikke en liste')
  }
  return value
}

function parseFinalControl(value: unknown, where: string): PublishedFinalControl | null {
  if (value === undefined || value === null) {
    return null
  }
  const control = objectAt(value, where)
  return {
    decision: text(control, 'decision', where),
    decidedAt: text(control, 'decided_at', where),
    reviewer: text(control, 'reviewer', where),
    rationale: text(control, 'rationale', where),
  }
}

function parseEvent(value: unknown, where: string): PublicationEvent {
  const event = objectAt(value, where)
  return {
    publicationEventId: text(event, 'publication_event_id', where),
    claimId: optionalText(event, 'claim_id', where),
    // Kjedens egen plass. Mangler den — som i svaret fra én enkelt handling —
    // er hendelsen ikke lest ut av historikken, og null er riktig svar.
    sequence: optionalCount(event, 'sequence', where) ?? 0,
    action: text(event, 'action', where),
    publishedAt: text(event, 'published_at', where),
    publishedBy: text(event, 'published_by', where),
    reason: text(event, 'reason', where),
    claimRevisionId: optionalText(event, 'claim_revision_id', where),
    revisionNumber: optionalCount(event, 'revision_number', where),
    candidateId: optionalText(event, 'candidate_id', where),
    candidateDigest: optionalText(event, 'candidate_digest', where),
    previousCandidateId: optionalText(event, 'previous_candidate_id', where),
    previousCandidateDigest: optionalText(event, 'previous_candidate_digest', where),
    finalControl: parseFinalControl(event['final_control'], `${where}.final_control`),
  }
}

/** Leser svaret fra `api.published_claim`, og avviser alt annet. */
export function parsePublishedClaim(value: unknown): PublishedClaimView {
  const record = objectAt(value, 'svaret')
  const published = flag(record, 'published', 'svaret')
  const history = list(record, 'history', 'svaret').map((entry, index) =>
    parseEvent(entry, `history[${String(index)}]`),
  )

  if (!published) {
    return {
      claimId: text(record, 'claim_id', 'svaret'),
      published: false,
      withdrawn: flag(record, 'withdrawn', 'svaret'),
      content: null,
      claimRevisionId: null,
      candidateId: null,
      candidateDigest: null,
      evidenceSetDigest: null,
      publication: null,
      finalControl: null,
      history,
    }
  }

  return {
    claimId: text(record, 'claim_id', 'svaret'),
    published: true,
    withdrawn: flag(record, 'withdrawn', 'svaret'),
    content: parseSealedContent(record['content']),
    claimRevisionId: text(record, 'claim_revision_id', 'svaret'),
    candidateId: text(record, 'candidate_id', 'svaret'),
    candidateDigest: text(record, 'candidate_digest', 'svaret'),
    evidenceSetDigest: text(record, 'evidence_set_digest', 'svaret'),
    publication: parseEvent(record['publication'], 'publication'),
    finalControl: parseFinalControl(record['final_control'], 'final_control'),
    history,
  }
}

/** Leser svaret fra `api.published_claim_index`, og avviser alt annet. */
export function parsePublishedClaimIndex(value: unknown): readonly PublishedClaimEntry[] {
  if (!Array.isArray(value)) {
    fail('katalogen', 'er ikke en liste')
  }
  return value.map((entry, index) => {
    const where = `katalogen[${String(index)}]`
    const row = objectAt(entry, where)
    return {
      claimId: text(row, 'claim_id', where),
      candidateId: text(row, 'candidate_id', where),
      candidateDigest: text(row, 'candidate_digest', where),
      statement: text(row, 'statement', where),
      subjectDrug: text(row, 'subject_drug', where),
      topic: text(row, 'topic', where),
      certaintyLevel: optionalText(row, 'certainty_level', where),
      sourceCount: count(row, 'source_count', where),
      publishedAt: text(row, 'published_at', where),
    }
  })
}

/** Leser svaret fra en publiserings-, tilbaketrekkings- eller rollbackhandling. */
export interface PublicationOutcome {
  /** `false` når handlingen allerede var utført: ingen ny hendelse ble skrevet. */
  readonly changed: boolean
  readonly published: boolean
  readonly event: PublicationEvent
}

export function parsePublicationOutcome(value: unknown): PublicationOutcome {
  const record = objectAt(value, 'svaret')
  return {
    changed: flag(record, 'changed', 'svaret'),
    published: flag(record, 'published', 'svaret'),
    event: parseEvent(record, 'svaret'),
  }
}

/**
 * De versjonene en rollback kan gå tilbake til.
 *
 * Hentet ut av historikken, fordi det er der «har vært publisert» står. Den
 * gjeldende versjonen er ikke med: en rollback til den er ingen endring, og
 * databasen ville avvist den. Listen er en bekvemmelighet for flaten og ikke en
 * garanti — `api.rollback_claim_publication` avgjør på nytt om målet fortsatt
 * holder, med hele publiseringsgaten (ANTIDEP_CONSTITUTION.md regel 6).
 */
export function rollbackTargets(view: PublishedClaimView): readonly PublicationEvent[] {
  const seen = new Set<string>()
  const targets: PublicationEvent[] = []
  for (const event of view.history) {
    if (event.candidateId === null || event.candidateId === view.candidateId) {
      continue
    }
    if (seen.has(event.candidateId)) {
      continue
    }
    seen.add(event.candidateId)
    targets.push(event)
  }
  return targets
}
