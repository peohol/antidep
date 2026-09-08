// ============================================================================
// Svaret fra `api.claim_verification_input(...)`, lest trygt
//
// Formen er dokumentert i funksjonskommentaren i migrasjon 005k og er en
// kontrakt utad på samme måte som kolonnene i et api-view. Denne modulen
// oversetter den til typer kontrollen kan regne på, og avviser et svar som ikke
// har den formen framfor å gjette — samme begrunnelse som `verification-input.ts`
// gir for ekstraksjonssiden: en jsonb-form har ingen kolonnetyper PostgREST kan
// håndheve, og en kontroll som stille mistet et felt, ville rapportert at den
// kontrollerte mer enn den gjorde.
//
// Evidensfunnet under hver lenke leses av `parseVerificationItem` fra den
// modulen. De to api-funksjonene bygger med vilje den samme formen for et
// evidensfunn, og gjenbruket her er det som gjør at de ikke kan komme fra
// hverandre.
// ============================================================================

import { parseVerificationItem, type VerificationItem } from './verification-input.ts'

/** Påstandsrevisjonen slik den er formulert, i sin helhet. */
export interface ClaimStatement {
  readonly statement: string
  readonly scope: string
  readonly populationId: string | null
  readonly populationLabel: string | null
  /** PostgreSQL-interval som tekst, for eksempel «182 days». `null` = ikke tidsavgrenset. */
  readonly timeframeMin: string | null
  readonly timeframeMax: string | null
  readonly comparatorKind: string
  readonly comparatorDrugId: string | null
  readonly comparatorDrugName: string | null
  /** `null` betyr at påstanden ikke uttrykker en strukturert retning. */
  readonly direction: string | null
  readonly magnitudeMeasure: string | null
  /** `numeric` som tekst, av samme grunn som estimatene på evidensfunnene. */
  readonly magnitudeValue: string | null
  readonly magnitudeUnit: string | null
  readonly qualifiers: string | null
  readonly uncertaintySummary: string | null
}

/** Den gjeldende ekstraksjonsverifikasjonen for ett evidensfunn. */
export interface CurrentExtractionVerification {
  readonly evidenceVerificationId: string
  readonly outcome: string
  readonly sourceAccess: string
  readonly checkedFields: readonly string[]
  readonly verifiedAt: string
}

/** Én registrert kobling mellom revisjonen og et evidensfunn. */
export interface ClaimEvidenceLink {
  readonly claimEvidenceLinkId: string
  readonly relationshipType: string
  readonly directness: string
  readonly relevanceNote: string
  readonly evidenceItem: VerificationItem
  /** `null` betyr at ingen ekstraksjonskontroll er registrert — ikke at den var negativ. */
  readonly currentExtractionVerification: CurrentExtractionVerification | null
}

/**
 * Et registrert evidensfunn på samme virkestoff og endepunkt som ikke er lenket
 * til revisjonen.
 *
 * Kandidat for urepresentert evidens, ikke en konklusjon: at listen er tom,
 * betyr aldri at det ikke finnes motstridende forskning
 * (ANTIDEP_CONSTITUTION.md §17).
 */
export interface UnlinkedRelatedEvidence {
  readonly evidenceItemId: string
  readonly sourceTitle: string
  readonly sourceStatus: string
  readonly interventionDrugName: string
  readonly outcomeLabel: string
  readonly reportedDirection: string
  readonly effectMeasure: string | null
  readonly estimate: string | null
  readonly estimateUnit: string | null
  readonly createdByActorKey: string
}

export interface ClaimRevisionInput {
  readonly claimRevisionId: string
  readonly claimId: string
  readonly revisionNumber: number
  readonly knowledgeType: string
  readonly createdByActorId: string
  readonly createdByActorKey: string
  readonly contentHash: string
  /** `null` betyr at påstanden ikke er trukket tilbake. */
  readonly claimRetiredAt: string | null
  readonly topicConceptId: string
  readonly topicLabel: string
  readonly subjectDrugId: string
  readonly subjectDrugName: string
  /** Avtrykket av evidenssettet kontrollen ville gjelde (migrasjon 005j). */
  readonly evidenceSetDigest: string
  readonly claim: ClaimStatement
  readonly links: readonly ClaimEvidenceLink[]
  readonly unlinkedRelatedEvidence: readonly UnlinkedRelatedEvidence[]
  readonly verificationsByThisActor: number
  readonly verificationsTotal: number
}

export interface ClaimVerificationInput {
  readonly agentRunId: string
  readonly verifierActorId: string
  readonly revisions: readonly ClaimRevisionInput[]
}

const SOURCE = 'api.claim_verification_input'

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

/**
 * En klinisk `numeric` som tekst.
 *
 * Samme kontrakt og samme begrunnelse som `asOptionalNumericText` i
 * `verification-input.ts`: gikk verdien gjennom et JSON-tall, ville den vært
 * avrundet av `JSON.parse` før noen linje her kjørte, og en påstand kunne blitt
 * bekreftet av den avrundede verdien framfor den registrerte.
 */
function asOptionalNumericText(value: unknown, field: string): string | null {
  if (typeof value === 'string') {
    return value
  }
  if (value === null || value === undefined) {
    return null
  }
  throw new Error(
    `${field} kom som ${typeof value} og ikke som tekst. Kliniske tallverdier må ` +
      'serialiseres med ::text, ellers er de allerede avrundet av JSON-lesingen.',
  )
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

function parseClaim(value: unknown): ClaimStatement {
  const record = asRecord(value, 'claim')
  return {
    statement: asString(record['statement'], 'claim.statement'),
    scope: asString(record['scope'], 'claim.scope'),
    populationId: asOptionalString(record['population_id']),
    populationLabel: asOptionalString(record['population_label']),
    timeframeMin: asOptionalString(record['timeframe_min']),
    timeframeMax: asOptionalString(record['timeframe_max']),
    comparatorKind: asString(record['comparator_kind'], 'claim.comparator_kind'),
    comparatorDrugId: asOptionalString(record['comparator_drug_id']),
    comparatorDrugName: asOptionalString(record['comparator_drug_name']),
    direction: asOptionalString(record['direction']),
    magnitudeMeasure: asOptionalString(record['magnitude_measure']),
    magnitudeValue: asOptionalNumericText(record['magnitude_value'], 'claim.magnitude_value'),
    magnitudeUnit: asOptionalString(record['magnitude_unit']),
    qualifiers: asOptionalString(record['qualifiers']),
    uncertaintySummary: asOptionalString(record['uncertainty_summary']),
  }
}

function parseCurrentExtractionVerification(value: unknown): CurrentExtractionVerification | null {
  if (value === null || value === undefined) {
    return null
  }
  const record = asRecord(value, 'links[].current_extraction_verification')
  const fields = asArray(
    record['checked_fields'],
    'links[].current_extraction_verification.checked_fields',
  )
  return {
    evidenceVerificationId: asString(
      record['evidence_verification_id'],
      'links[].current_extraction_verification.evidence_verification_id',
    ),
    outcome: asString(record['outcome'], 'links[].current_extraction_verification.outcome'),
    sourceAccess: asString(
      record['source_access'],
      'links[].current_extraction_verification.source_access',
    ),
    checkedFields: fields.map((field, index) =>
      asString(field, `links[].current_extraction_verification.checked_fields[${String(index)}]`),
    ),
    verifiedAt: asString(
      record['verified_at'],
      'links[].current_extraction_verification.verified_at',
    ),
  }
}

function parseLink(value: unknown): ClaimEvidenceLink {
  const record = asRecord(value, 'links[]')
  return {
    claimEvidenceLinkId: asString(
      record['claim_evidence_link_id'],
      'links[].claim_evidence_link_id',
    ),
    relationshipType: asString(record['relationship_type'], 'links[].relationship_type'),
    directness: asString(record['directness'], 'links[].directness'),
    relevanceNote: asString(record['relevance_note'], 'links[].relevance_note'),
    // `verifications_by_this_actor` finnes ikke på denne formen og blir 0.
    // Feltet hører til ekstraksjonskøen og leses ikke av claim-kontrollen.
    evidenceItem: parseVerificationItem(record['evidence_item']),
    currentExtractionVerification: parseCurrentExtractionVerification(
      record['current_extraction_verification'],
    ),
  }
}

function parseUnlinked(value: unknown): UnlinkedRelatedEvidence {
  const record = asRecord(value, 'unlinked_related_evidence[]')
  return {
    evidenceItemId: asString(
      record['evidence_item_id'],
      'unlinked_related_evidence[].evidence_item_id',
    ),
    sourceTitle: asString(record['source_title'], 'unlinked_related_evidence[].source_title'),
    sourceStatus: asString(record['source_status'], 'unlinked_related_evidence[].source_status'),
    interventionDrugName: asString(
      record['intervention_drug_name'],
      'unlinked_related_evidence[].intervention_drug_name',
    ),
    outcomeLabel: asString(record['outcome_label'], 'unlinked_related_evidence[].outcome_label'),
    reportedDirection: asString(
      record['reported_direction'],
      'unlinked_related_evidence[].reported_direction',
    ),
    effectMeasure: asOptionalString(record['effect_measure']),
    estimate: asOptionalNumericText(record['estimate'], 'unlinked_related_evidence[].estimate'),
    estimateUnit: asOptionalString(record['estimate_unit']),
    createdByActorKey: asString(
      record['created_by_actor_key'],
      'unlinked_related_evidence[].created_by_actor_key',
    ),
  }
}

function parseRevision(value: unknown): ClaimRevisionInput {
  const record = asRecord(value, 'revisions[]')
  const links = asArray(record['links'], 'revisions[].links')
  const unlinked = asArray(
    record['unlinked_related_evidence'],
    'revisions[].unlinked_related_evidence',
  )
  return {
    claimRevisionId: asString(record['claim_revision_id'], 'revisions[].claim_revision_id'),
    claimId: asString(record['claim_id'], 'revisions[].claim_id'),
    revisionNumber: asInteger(record['revision_number'], 'revisions[].revision_number'),
    knowledgeType: asString(record['knowledge_type'], 'revisions[].knowledge_type'),
    createdByActorId: asString(record['created_by_actor_id'], 'revisions[].created_by_actor_id'),
    createdByActorKey: asString(record['created_by_actor_key'], 'revisions[].created_by_actor_key'),
    contentHash: asString(record['content_hash'], 'revisions[].content_hash'),
    claimRetiredAt: asOptionalString(record['claim_retired_at']),
    topicConceptId: asString(record['topic_concept_id'], 'revisions[].topic_concept_id'),
    topicLabel: asString(record['topic_label'], 'revisions[].topic_label'),
    subjectDrugId: asString(record['subject_drug_id'], 'revisions[].subject_drug_id'),
    subjectDrugName: asString(record['subject_drug_name'], 'revisions[].subject_drug_name'),
    evidenceSetDigest: asString(record['evidence_set_digest'], 'revisions[].evidence_set_digest'),
    claim: parseClaim(record['claim']),
    links: links.map(parseLink),
    unlinkedRelatedEvidence: unlinked.map(parseUnlinked),
    verificationsByThisActor:
      typeof record['verifications_by_this_actor'] === 'number'
        ? record['verifications_by_this_actor']
        : 0,
    verificationsTotal:
      typeof record['verifications_total'] === 'number' ? record['verifications_total'] : 0,
  }
}

/** Leser svaret fra databasen, eller kaster med en setning som sier hva som manglet. */
export function parseClaimVerificationInput(payload: unknown): ClaimVerificationInput {
  const record = asRecord(payload, 'svaret')
  const revisions = asArray(record['revisions'], 'revisions')
  return {
    agentRunId: asString(record['agent_run_id'], 'agent_run_id'),
    verifierActorId: asString(record['verifier_actor_id'], 'verifier_actor_id'),
    revisions: revisions.map(parseRevision),
  }
}
