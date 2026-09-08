// ============================================================================
// Arbeidsflaten for ekstraksjonskontroll, lest trygt
//
// `api.extraction_review_workspace(uuid)` (migrasjon 005t) svarer med et
// jsonb-objekt og ikke med kolonner. En jsonb-form har ingen typer PostgREST
// kan håndheve, så den leses her på samme måte som reviewflaten for påstander
// leses i `review-workspace.ts`: et svar som ikke har den formen kontrakten
// dokumenterer, avvises framfor å gjettes på. En kontrollflate som stille mistet
// et felt, ville latt en reviewer bekrefte mer enn hen faktisk så
// (ANTIDEP_CONSTITUTION.md §11).
//
// ----------------------------------------------------------------------------
// Grunnlaget leses av den samme leseren agenten bruker
//
// Selve evidensfunnet med kilden, kildeversjonen og ekstraksjonen er nøyaktig
// den formen `workflow.evidence_extraction_dossier(uuid)` bygger, og den formen
// har allerede en leser: `parseVerificationItem`. Den gjenbrukes her. To lesere
// av samme form ville før eller siden lest den forskjellig — den samme grunnen
// migrasjon 005r gir for at det bare finnes én projeksjon i databasen.
//
// Det denne modulen leser i tillegg, er det bare et menneske trenger:
// kontrollhistorikken, avtrykket vurderingen bindes til, feltdekningen, og hvilke
// påstander funnet allerede bærer.
//
// ----------------------------------------------------------------------------
// Feltdekningen er databasens, og differansen er ren mengdelære
//
// `requiredCheckFields` og `coveredCheckFields` kommer fra publiseringsgatens
// egne funksjoner. Det denne modulen gjør med dem, er å trekke den ene fra den
// andre — et rent mengdeuttrykk over to lister databasen har levert, ikke en
// andre formulering av regelen. Hvilke felter som *kreves*, og hva som *teller*
// som dekket, avgjøres fortsatt bare ett sted.
//
// ----------------------------------------------------------------------------
// Ingen «du kan bekrefte»-boolean («FELLE 4»)
//
// Modulen svarer på hva som ER registrert, aldri på hva kalleren KAN gjøre.
// Skriveveien tar avgjørelsen på nytt, på sitt eget kall
// (DATABASE_ARCHITECTURE.md §43, §48).
// ============================================================================

import { parseVerificationItem, type VerificationItem } from '../agents/verification-input'
import type { AntidepClient } from './supabase'
import type { Uuid } from '../types/api'

const SOURCE = 'api.extraction_review_workspace'

function asRecord(value: unknown, where: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`Svaret fra ${SOURCE} mangler et objekt i ${where}.`)
  }
  return value as Record<string, unknown>
}

function asString(value: unknown, where: string): string {
  if (typeof value !== 'string') {
    throw new Error(`Svaret fra ${SOURCE} mangler ${where}.`)
  }
  return value
}

function asOptionalString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function asBoolean(value: unknown, where: string): boolean {
  if (typeof value !== 'boolean') {
    throw new Error(`Svaret fra ${SOURCE} mangler den boolske verdien ${where}.`)
  }
  return value
}

function asInteger(value: unknown, where: string): number {
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new Error(`Svaret fra ${SOURCE} mangler heltallet ${where}.`)
  }
  return value
}

function asArray(value: unknown, where: string): readonly unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`Svaret fra ${SOURCE} mangler listen ${where}.`)
  }
  return value
}

function asStringArray(value: unknown, where: string): readonly string[] {
  return asArray(value, where).map((entry, index) => asString(entry, `${where}[${String(index)}]`))
}

// ----------------------------------------------------------------------------
// Formene
// ----------------------------------------------------------------------------

/** Én registrert kontroll av ekstraksjonen mot kilden. */
export interface ExtractionVerificationRecord {
  readonly evidenceVerificationId: Uuid
  readonly outcome: string
  readonly sourceAccess: string
  /** Feltene nettopp denne kontrollen gikk gjennom — ikke den samlede dekningen. */
  readonly checkedFields: readonly string[]
  readonly findings: string | null
  readonly rationale: string
  readonly verifiedAt: string
  readonly verifierActorId: Uuid
  readonly verifierActorKey: string
  readonly verifierActorType: string
  readonly verifierDisplayName: string
  /** `null` betyr at kontrollen ble gjort av et menneske, ikke av en agentkjøring. */
  readonly agentRunId: Uuid | null
}

/** Én påstandsrevisjon evidensfunnet allerede er lenket til. */
export interface LinkedClaimRevision {
  readonly claimRevisionId: Uuid
  readonly claimId: Uuid
  readonly revisionNumber: number
  readonly statement: string
  readonly subjectDrugName: string
  readonly topicLabel: string
  readonly relationshipType: string
  readonly isPublishedRevision: boolean
}

/** Ett evidensfunn med alt en reviewer trenger for å kontrollere det mot kilden. */
export interface ExtractionReviewItem {
  /** Evidensfunnet, kilden, kildeversjonen og hele ekstraksjonen, ordrett. */
  readonly dossier: VerificationItem
  /** Avtrykket kontrollen bindes til. Sendes tilbake uendret av skriveveien. */
  readonly extractionDigest: string
  /** Feltene funnet faktisk påstår noe om (publiseringsgatens G5b). */
  readonly requiredCheckFields: readonly string[]
  /** Feltene som per nå teller som kontrollert. Et avvik nullstiller dem. */
  readonly coveredCheckFields: readonly string[]
  /** `null` betyr at ingen kontroll er registrert — ikke at en var negativ. */
  readonly currentExtractionVerificationId: Uuid | null
  readonly extractionVerifications: readonly ExtractionVerificationRecord[]
  readonly linkedClaimRevisions: readonly LinkedClaimRevision[]
}

export interface ExtractionReviewWorkspace {
  readonly reviewerActorId: Uuid
  readonly item: ExtractionReviewItem
}

/** Én rad i arbeidskøen: nok til å velge, ikke nok til å vurdere. */
export interface ExtractionQueueItem {
  readonly evidenceItemId: Uuid
  readonly createdByActorKey: string
  readonly sourceId: Uuid
  readonly sourceTitle: string
  readonly sourceStatus: string
  readonly interventionDrugName: string
  readonly outcomeLabel: string
  /** `null` betyr at ingen kontroll er registrert — ikke at den var negativ. */
  readonly currentExtractionVerificationOutcome: string | null
  readonly verificationCount: number
  readonly requiredCheckFields: readonly string[]
  readonly coveredCheckFields: readonly string[]
  readonly linkedClaimRevisionCount: number
}

/**
 * Feltene som står igjen å kontrollere.
 *
 * Ren mengdelære over to lister databasen har levert, og ikke en ny avgjørelse:
 * hva som kreves og hva som teller, avgjøres av `workflow.required_check_fields`
 * og `workflow.covered_check_fields` — de samme funksjonene publiseringsgaten
 * bruker.
 */
export function uncoveredCheckFields(item: {
  readonly requiredCheckFields: readonly string[]
  readonly coveredCheckFields: readonly string[]
}): readonly string[] {
  const covered = new Set(item.coveredCheckFields)
  return item.requiredCheckFields.filter((field) => !covered.has(field))
}

// ----------------------------------------------------------------------------
// Leserne
// ----------------------------------------------------------------------------

function parseVerification(value: unknown): ExtractionVerificationRecord {
  const record = asRecord(value, 'extraction_verifications[]')
  return {
    evidenceVerificationId: asString(
      record['evidence_verification_id'],
      'extraction_verifications[].evidence_verification_id',
    ),
    outcome: asString(record['outcome'], 'extraction_verifications[].outcome'),
    sourceAccess: asString(record['source_access'], 'extraction_verifications[].source_access'),
    checkedFields: asStringArray(
      record['checked_fields'],
      'extraction_verifications[].checked_fields',
    ),
    findings: asOptionalString(record['findings']),
    rationale: asString(record['rationale'], 'extraction_verifications[].rationale'),
    verifiedAt: asString(record['verified_at'], 'extraction_verifications[].verified_at'),
    verifierActorId: asString(
      record['verifier_actor_id'],
      'extraction_verifications[].verifier_actor_id',
    ),
    verifierActorKey: asString(
      record['verifier_actor_key'],
      'extraction_verifications[].verifier_actor_key',
    ),
    verifierActorType: asString(
      record['verifier_actor_type'],
      'extraction_verifications[].verifier_actor_type',
    ),
    verifierDisplayName: asString(
      record['verifier_display_name'],
      'extraction_verifications[].verifier_display_name',
    ),
    agentRunId: asOptionalString(record['agent_run_id']),
  }
}

function parseLinkedRevision(value: unknown): LinkedClaimRevision {
  const record = asRecord(value, 'linked_claim_revisions[]')
  return {
    claimRevisionId: asString(
      record['claim_revision_id'],
      'linked_claim_revisions[].claim_revision_id',
    ),
    claimId: asString(record['claim_id'], 'linked_claim_revisions[].claim_id'),
    revisionNumber: asInteger(
      record['revision_number'],
      'linked_claim_revisions[].revision_number',
    ),
    statement: asString(record['statement'], 'linked_claim_revisions[].statement'),
    subjectDrugName: asString(
      record['subject_drug_name'],
      'linked_claim_revisions[].subject_drug_name',
    ),
    topicLabel: asString(record['topic_label'], 'linked_claim_revisions[].topic_label'),
    relationshipType: asString(
      record['relationship_type'],
      'linked_claim_revisions[].relationship_type',
    ),
    isPublishedRevision: asBoolean(
      record['is_published_revision'],
      'linked_claim_revisions[].is_published_revision',
    ),
  }
}

/** Leser svaret på et oppslag av ett evidensfunn, eller kaster med hva som manglet. */
export function parseExtractionReviewWorkspace(payload: unknown): ExtractionReviewWorkspace {
  const record = asRecord(payload, 'svaret')
  const item = asRecord(record['item'], 'item')
  return {
    reviewerActorId: asString(record['reviewer_actor_id'], 'reviewer_actor_id'),
    item: {
      dossier: parseVerificationItem(item),
      extractionDigest: asString(item['extraction_digest'], 'item.extraction_digest'),
      requiredCheckFields: asStringArray(
        item['required_check_fields'],
        'item.required_check_fields',
      ),
      coveredCheckFields: asStringArray(item['covered_check_fields'], 'item.covered_check_fields'),
      currentExtractionVerificationId: asOptionalString(item['current_extraction_verification_id']),
      extractionVerifications: asArray(
        item['extraction_verifications'],
        'item.extraction_verifications',
      ).map(parseVerification),
      linkedClaimRevisions: asArray(
        item['linked_claim_revisions'],
        'item.linked_claim_revisions',
      ).map(parseLinkedRevision),
    },
  }
}

function parseQueueItem(value: unknown): ExtractionQueueItem {
  const record = asRecord(value, 'queue[]')
  return {
    evidenceItemId: asString(record['evidence_item_id'], 'queue[].evidence_item_id'),
    createdByActorKey: asString(record['created_by_actor_key'], 'queue[].created_by_actor_key'),
    sourceId: asString(record['source_id'], 'queue[].source_id'),
    sourceTitle: asString(record['source_title'], 'queue[].source_title'),
    sourceStatus: asString(record['source_status'], 'queue[].source_status'),
    interventionDrugName: asString(
      record['intervention_drug_name'],
      'queue[].intervention_drug_name',
    ),
    outcomeLabel: asString(record['outcome_label'], 'queue[].outcome_label'),
    currentExtractionVerificationOutcome: asOptionalString(
      record['current_extraction_verification_outcome'],
    ),
    verificationCount: asInteger(record['verification_count'], 'queue[].verification_count'),
    requiredCheckFields: asStringArray(
      record['required_check_fields'],
      'queue[].required_check_fields',
    ),
    coveredCheckFields: asStringArray(
      record['covered_check_fields'],
      'queue[].covered_check_fields',
    ),
    linkedClaimRevisionCount: asInteger(
      record['linked_claim_revision_count'],
      'queue[].linked_claim_revision_count',
    ),
  }
}

/** Leser svaret på et køoppslag, eller kaster med hva som manglet. */
export function parseExtractionQueue(payload: unknown): {
  readonly reviewerActorId: Uuid
  readonly items: readonly ExtractionQueueItem[]
} {
  const record = asRecord(payload, 'svaret')
  const queue = asArray(record['queue'], 'queue')
  return {
    reviewerActorId: asString(record['reviewer_actor_id'], 'reviewer_actor_id'),
    items: queue.map(parseQueueItem),
  }
}

// ----------------------------------------------------------------------------
// Hentingen
// ----------------------------------------------------------------------------

/**
 * Køen, eller grunnen til at den ikke kan vises.
 *
 * `empty` og `error` er to forskjellige ting, og `empty` er ikke det samme som
 * «du har ikke tilgang»: en kaller uten reviewer-rolle får en avvisning fra
 * databasen og havner i `error` med databasens egen setning.
 */
export type ExtractionQueueResult =
  | {
      readonly status: 'ok'
      readonly reviewerActorId: Uuid
      readonly items: readonly [ExtractionQueueItem, ...ExtractionQueueItem[]]
    }
  | { readonly status: 'empty'; readonly reviewerActorId: Uuid }
  | { readonly status: 'error'; readonly message: string }

export type ExtractionReviewResult =
  | { readonly status: 'ok'; readonly workspace: ExtractionReviewWorkspace }
  | { readonly status: 'error'; readonly message: string }

/** Arbeidskøen for den innloggede revieweren. */
export async function fetchExtractionQueue(client: AntidepClient): Promise<ExtractionQueueResult> {
  const { data, error } = await client.rpc('extraction_review_workspace', {
    p_evidence_item_id: null,
  })
  if (error !== null) {
    return { status: 'error', message: error.message }
  }
  const parsed = parseExtractionQueue(data)
  const [first, ...rest] = parsed.items
  return first === undefined
    ? { status: 'empty', reviewerActorId: parsed.reviewerActorId }
    : { status: 'ok', reviewerActorId: parsed.reviewerActorId, items: [first, ...rest] }
}

/** Arbeidsflaten for ett evidensfunn. */
export async function fetchExtractionReview(
  client: AntidepClient,
  evidenceItemId: Uuid,
): Promise<ExtractionReviewResult> {
  const { data, error } = await client.rpc('extraction_review_workspace', {
    p_evidence_item_id: evidenceItemId,
  })
  if (error !== null) {
    return { status: 'error', message: error.message }
  }
  return { status: 'ok', workspace: parseExtractionReviewWorkspace(data) }
}
