// ============================================================================
// Reviewarbeidsflaten, lest trygt
//
// `api.claim_review_workspace(uuid)` (migrasjon 005o) svarer med et jsonb-objekt
// og ikke med kolonner. En jsonb-form har ingen typer PostgREST kan håndheve, så
// den leses her på samme måte som agentens lesegrunnlag leses i
// `src/agents/claim-verification-input.ts`: et svar som ikke har den formen
// kontrakten dokumenterer, avvises framfor å gjettes på. En reviewflate som
// stille mistet en evidenslenke, ville latt en reviewer kontrollere en påstand
// mot mindre enn det som faktisk er registrert (ANTIDEP_CONSTITUTION.md §4, §9).
//
// ----------------------------------------------------------------------------
// Grunnlaget leses av den samme funksjonen agenten bruker
//
// Selve påstandsrevisjonen med evidenslenkene sine er nøyaktig den formen
// `workflow.claim_evidence_dossier(uuid)` bygger, og den formen har allerede en
// leser: `parseClaimRevisionDossier`. Den gjenbrukes her. To lesere av samme
// form ville før eller siden lest den forskjellig — den samme grunnen migrasjon
// 005m gir for at det bare finnes én projeksjon i databasen.
//
// Det denne modulen leser i tillegg, er det bare et menneske trenger:
// beslutningshistorikken, evidensvurderingen, og hva publiseringsgaten svarer.
//
// ----------------------------------------------------------------------------
// Ingen «du kan godkjenne»-boolean («FELLE 4»)
//
// Modulen svarer på hva som ER registrert, aldri på hva kalleren KAN gjøre.
// Hvem som er kaller og hvem som formulerte revisjonen står som fakta, og
// visningen leser sammenhengen selv. Skriveveiene tar avgjørelsen på nytt, på
// sitt eget kall (DATABASE_ARCHITECTURE.md §43, §48).
// ============================================================================

import {
  parseClaimRevisionDossier,
  type ClaimRevisionInput,
} from '../agents/claim-verification-input'
import type { AntidepClient } from './supabase'
import type { Uuid } from '../types/api'

const SOURCE = 'api.claim_review_workspace'

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

// ----------------------------------------------------------------------------
// Formene
// ----------------------------------------------------------------------------

/** De sju kontrollpunktene, som råverdier fra vokabularet. */
export interface ClaimCheckpointResults {
  readonly sourceSupport: string
  readonly populationMatch: string
  readonly comparatorMatch: string
  readonly timeframeMatch: string
  readonly directionAndMagnitude: string
  readonly qualifiersComplete: string
  readonly contradictoryEvidenceRepresented: string
}

/** Hva én registrert kontroll faktisk gikk gjennom, for én evidenslenke. */
export interface ClaimVerificationCitation {
  readonly claimEvidenceLinkId: Uuid
  readonly evidenceItemId: Uuid
  readonly sourceAccess: string
  readonly sourceVersionId: Uuid | null
  readonly checkedContentHash: string | null
  readonly relationshipSupported: string
  readonly finding: string | null
}

/** Én registrert kontroll av påstanden mot grunnlaget. */
export interface ClaimVerificationRecord {
  readonly claimVerificationId: Uuid
  readonly outcome: string
  readonly sourceAccess: string
  readonly verifiedAt: string
  readonly verifierActorId: Uuid
  readonly verifierActorKey: string
  readonly verifierActorType: string
  readonly verifierDisplayName: string
  /** `null` betyr at kontrollen ble gjort av et menneske, ikke av en agentkjøring. */
  readonly agentRunId: Uuid | null
  readonly verifiedEvidenceSetDigest: string
  readonly checks: ClaimCheckpointResults
  readonly findings: string | null
  readonly rationale: string
  readonly citations: readonly ClaimVerificationCitation[]
}

/** Én registrert publiseringsbeslutning. */
export interface ReviewDecisionRecord {
  readonly reviewDecisionId: Uuid
  readonly decision: string
  readonly decidedAt: string
  readonly reviewerActorId: Uuid
  readonly reviewerActorKey: string
  readonly reviewerDisplayName: string
  readonly rationale: string
  readonly approvedEvidenceSetDigest: string | null
}

/** Evidensvurderingen med GRADE-domenene, når den er registrert. */
export interface EvidenceAssessmentRecord {
  readonly evidenceAssessmentId: Uuid
  readonly framework: string
  readonly certaintyLevel: string
  readonly riskOfBias: string | null
  readonly inconsistency: string | null
  readonly indirectness: string | null
  readonly imprecision: string | null
  readonly publicationBias: string | null
  readonly otherConsiderations: string | null
  readonly rationale: string
  readonly evidenceGap: string | null
  readonly assessedAt: string
}

/**
 * Hva publiseringsgaten svarer, lest av gaten selv og ikke regnet ut på nytt.
 *
 * Gaten stopper på det første vilkåret som svikter, så `blocked` navngir én
 * blokkering om gangen. Det er ikke en mangel i flaten: det er gaten som er
 * fasiten, og en andre formulering av den ville kunnet si «klar» om noe gaten
 * stenger.
 */
export type PublicationGateState =
  | { readonly status: 'passes' }
  | {
      readonly status: 'blocked'
      readonly sqlstate: string
      readonly message: string
      readonly hint: string | null
    }

/** En påstandsrevisjon med grunnlaget, historikken og gatens svar. */
export interface ClaimReviewRevision {
  readonly dossier: ClaimRevisionInput
  readonly currentClaimVerificationId: Uuid | null
  readonly claimVerifications: readonly ClaimVerificationRecord[]
  readonly currentReviewDecisionId: Uuid | null
  readonly reviewDecisions: readonly ReviewDecisionRecord[]
  /** `null` betyr at ingen vurdering er registrert — ikke at grunnlaget er svakt. */
  readonly evidenceAssessment: EvidenceAssessmentRecord | null
  readonly isPublishedRevision: boolean
  readonly publicationGate: PublicationGateState
}

export interface ClaimReviewWorkspace {
  readonly reviewerActorId: Uuid
  readonly revision: ClaimReviewRevision
}

/** Én rad i arbeidskøen: nok til å velge, ikke nok til å vurdere. */
export interface ReviewQueueItem {
  readonly claimRevisionId: Uuid
  readonly claimId: Uuid
  readonly revisionNumber: number
  readonly knowledgeType: string
  readonly createdByActorKey: string
  readonly statement: string
  readonly subjectDrugName: string
  readonly topicLabel: string
  readonly evidenceLinkCount: number
  readonly isPublishedRevision: boolean
  /** `null` betyr at ingen kontroll er registrert — ikke at den var negativ. */
  readonly currentClaimVerificationOutcome: string | null
  /** `null` betyr at ingen beslutning er registrert — ikke at den var et avslag. */
  readonly currentPublicationDecision: string | null
}

// ----------------------------------------------------------------------------
// Leserne
// ----------------------------------------------------------------------------

function parseCitation(value: unknown): ClaimVerificationCitation {
  const record = asRecord(value, 'claim_verifications[].citations[]')
  return {
    claimEvidenceLinkId: asString(record['claim_evidence_link_id'], 'citations[].link'),
    evidenceItemId: asString(record['evidence_item_id'], 'citations[].evidence_item_id'),
    sourceAccess: asString(record['source_access'], 'citations[].source_access'),
    sourceVersionId: asOptionalString(record['source_version_id']),
    checkedContentHash: asOptionalString(record['checked_content_hash']),
    relationshipSupported: asString(
      record['relationship_supported'],
      'citations[].relationship_supported',
    ),
    finding: asOptionalString(record['finding']),
  }
}

function parseChecks(value: unknown): ClaimCheckpointResults {
  const record = asRecord(value, 'claim_verifications[].checks')
  return {
    sourceSupport: asString(record['source_support'], 'checks.source_support'),
    populationMatch: asString(record['population_match'], 'checks.population_match'),
    comparatorMatch: asString(record['comparator_match'], 'checks.comparator_match'),
    timeframeMatch: asString(record['timeframe_match'], 'checks.timeframe_match'),
    directionAndMagnitude: asString(
      record['direction_and_magnitude'],
      'checks.direction_and_magnitude',
    ),
    qualifiersComplete: asString(record['qualifiers_complete'], 'checks.qualifiers_complete'),
    contradictoryEvidenceRepresented: asString(
      record['contradictory_evidence_represented'],
      'checks.contradictory_evidence_represented',
    ),
  }
}

function parseClaimVerification(value: unknown): ClaimVerificationRecord {
  const record = asRecord(value, 'claim_verifications[]')
  const citations = asArray(record['citations'], 'claim_verifications[].citations')
  return {
    claimVerificationId: asString(
      record['claim_verification_id'],
      'claim_verifications[].claim_verification_id',
    ),
    outcome: asString(record['outcome'], 'claim_verifications[].outcome'),
    sourceAccess: asString(record['source_access'], 'claim_verifications[].source_access'),
    verifiedAt: asString(record['verified_at'], 'claim_verifications[].verified_at'),
    verifierActorId: asString(
      record['verifier_actor_id'],
      'claim_verifications[].verifier_actor_id',
    ),
    verifierActorKey: asString(
      record['verifier_actor_key'],
      'claim_verifications[].verifier_actor_key',
    ),
    verifierActorType: asString(
      record['verifier_actor_type'],
      'claim_verifications[].verifier_actor_type',
    ),
    verifierDisplayName: asString(
      record['verifier_display_name'],
      'claim_verifications[].verifier_display_name',
    ),
    agentRunId: asOptionalString(record['agent_run_id']),
    verifiedEvidenceSetDigest: asString(
      record['verified_evidence_set_digest'],
      'claim_verifications[].verified_evidence_set_digest',
    ),
    checks: parseChecks(record['checks']),
    findings: asOptionalString(record['findings']),
    rationale: asString(record['rationale'], 'claim_verifications[].rationale'),
    citations: citations.map(parseCitation),
  }
}

function parseReviewDecision(value: unknown): ReviewDecisionRecord {
  const record = asRecord(value, 'review_decisions[]')
  return {
    reviewDecisionId: asString(record['review_decision_id'], 'review_decisions[].id'),
    decision: asString(record['decision'], 'review_decisions[].decision'),
    decidedAt: asString(record['decided_at'], 'review_decisions[].decided_at'),
    reviewerActorId: asString(record['reviewer_actor_id'], 'review_decisions[].reviewer_actor_id'),
    reviewerActorKey: asString(
      record['reviewer_actor_key'],
      'review_decisions[].reviewer_actor_key',
    ),
    reviewerDisplayName: asString(
      record['reviewer_display_name'],
      'review_decisions[].reviewer_display_name',
    ),
    rationale: asString(record['rationale'], 'review_decisions[].rationale'),
    approvedEvidenceSetDigest: asOptionalString(record['approved_evidence_set_digest']),
  }
}

function parseEvidenceAssessment(value: unknown): EvidenceAssessmentRecord | null {
  if (value === null || value === undefined) {
    return null
  }
  const record = asRecord(value, 'evidence_assessment')
  return {
    evidenceAssessmentId: asString(
      record['evidence_assessment_id'],
      'evidence_assessment.evidence_assessment_id',
    ),
    framework: asString(record['framework'], 'evidence_assessment.framework'),
    certaintyLevel: asString(record['certainty_level'], 'evidence_assessment.certainty_level'),
    riskOfBias: asOptionalString(record['risk_of_bias']),
    inconsistency: asOptionalString(record['inconsistency']),
    indirectness: asOptionalString(record['indirectness']),
    imprecision: asOptionalString(record['imprecision']),
    publicationBias: asOptionalString(record['publication_bias']),
    otherConsiderations: asOptionalString(record['other_considerations']),
    rationale: asString(record['rationale'], 'evidence_assessment.rationale'),
    evidenceGap: asOptionalString(record['evidence_gap']),
    assessedAt: asString(record['assessed_at'], 'evidence_assessment.assessed_at'),
  }
}

function parsePublicationGate(value: unknown): PublicationGateState {
  const record = asRecord(value, 'publication_gate')
  const status = asString(record['status'], 'publication_gate.status')
  if (status === 'passes') {
    return { status: 'passes' }
  }
  if (status !== 'blocked') {
    throw new Error(
      `Svaret fra ${SOURCE} oppgir en ukjent tilstand for publiseringsgaten («${status}»). ` +
        'En ukjent tilstand kan ikke leses som «klar til publisering».',
    )
  }
  return {
    status: 'blocked',
    sqlstate: asString(record['sqlstate'], 'publication_gate.sqlstate'),
    message: asString(record['message'], 'publication_gate.message'),
    hint: asOptionalString(record['hint']),
  }
}

/** Leser svaret på et oppslag av én revisjon, eller kaster med hva som manglet. */
export function parseClaimReviewWorkspace(payload: unknown): ClaimReviewWorkspace {
  const record = asRecord(payload, 'svaret')
  const revision = asRecord(record['revision'], 'revision')
  const verifications = asArray(revision['claim_verifications'], 'revision.claim_verifications')
  const decisions = asArray(revision['review_decisions'], 'revision.review_decisions')
  return {
    reviewerActorId: asString(record['reviewer_actor_id'], 'reviewer_actor_id'),
    revision: {
      dossier: parseClaimRevisionDossier(revision),
      currentClaimVerificationId: asOptionalString(revision['current_claim_verification_id']),
      claimVerifications: verifications.map(parseClaimVerification),
      currentReviewDecisionId: asOptionalString(revision['current_review_decision_id']),
      reviewDecisions: decisions.map(parseReviewDecision),
      evidenceAssessment: parseEvidenceAssessment(revision['evidence_assessment']),
      isPublishedRevision: asBoolean(
        revision['is_published_revision'],
        'revision.is_published_revision',
      ),
      publicationGate: parsePublicationGate(revision['publication_gate']),
    },
  }
}

function parseQueueItem(value: unknown): ReviewQueueItem {
  const record = asRecord(value, 'queue[]')
  return {
    claimRevisionId: asString(record['claim_revision_id'], 'queue[].claim_revision_id'),
    claimId: asString(record['claim_id'], 'queue[].claim_id'),
    revisionNumber: asInteger(record['revision_number'], 'queue[].revision_number'),
    knowledgeType: asString(record['knowledge_type'], 'queue[].knowledge_type'),
    createdByActorKey: asString(record['created_by_actor_key'], 'queue[].created_by_actor_key'),
    statement: asString(record['statement'], 'queue[].statement'),
    subjectDrugName: asString(record['subject_drug_name'], 'queue[].subject_drug_name'),
    topicLabel: asString(record['topic_label'], 'queue[].topic_label'),
    evidenceLinkCount: asInteger(record['evidence_link_count'], 'queue[].evidence_link_count'),
    isPublishedRevision: asBoolean(
      record['is_published_revision'],
      'queue[].is_published_revision',
    ),
    currentClaimVerificationOutcome: asOptionalString(record['current_claim_verification_outcome']),
    currentPublicationDecision: asOptionalString(record['current_publication_decision']),
  }
}

/** Leser svaret på et køoppslag, eller kaster med hva som manglet. */
export function parseReviewQueue(payload: unknown): {
  readonly reviewerActorId: Uuid
  readonly items: readonly ReviewQueueItem[]
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
 * databasen og havner i `error` med databasens egen setning. En tom kø betyr at
 * det ikke ligger noe til vurdering nå (§74.12 punkt 1).
 */
export type ReviewQueueResult =
  | {
      readonly status: 'ok'
      readonly reviewerActorId: Uuid
      readonly items: readonly [ReviewQueueItem, ...ReviewQueueItem[]]
    }
  | { readonly status: 'empty'; readonly reviewerActorId: Uuid }
  | { readonly status: 'error'; readonly message: string }

export type ClaimReviewResult =
  | { readonly status: 'ok'; readonly workspace: ClaimReviewWorkspace }
  | { readonly status: 'error'; readonly message: string }

/** Arbeidskøen for den innloggede revieweren. */
export async function fetchReviewQueue(client: AntidepClient): Promise<ReviewQueueResult> {
  const { data, error } = await client.rpc('claim_review_workspace', {
    p_claim_revision_id: null,
  })
  if (error !== null) {
    return { status: 'error', message: error.message }
  }
  const parsed = parseReviewQueue(data)
  const [first, ...rest] = parsed.items
  return first === undefined
    ? { status: 'empty', reviewerActorId: parsed.reviewerActorId }
    : { status: 'ok', reviewerActorId: parsed.reviewerActorId, items: [first, ...rest] }
}

/** Arbeidsflaten for én påstandsrevisjon. */
export async function fetchClaimReview(
  client: AntidepClient,
  claimRevisionId: Uuid,
): Promise<ClaimReviewResult> {
  const { data, error } = await client.rpc('claim_review_workspace', {
    p_claim_revision_id: claimRevisionId,
  })
  if (error !== null) {
    return { status: 'error', message: error.message }
  }
  return { status: 'ok', workspace: parseClaimReviewWorkspace(data) }
}
