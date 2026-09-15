// ============================================================================
// Kandidaten, lest slik klinikerflaten skal vise den
//
// `api.candidate_for_control` svarer med jsonb, og jsonb har ingen kolonnetyper
// PostgREST kan håndheve. Formen leses derfor her, med den samme strengheten en
// fil leses med: et felt som mangler, er en feil — ikke en tom rute i en klinisk
// visning.
//
// ----------------------------------------------------------------------------
// Hvorfor fravær ikke blir til tomhet
//
// ANTIDEP_CONSTITUTION.md regel 4 krever at forskningsusikkerhet, agentuenighet
// og teknisk feil er forskjellige tilstander. En visning som tegnet «ingen
// evidensvurdering» og «vurdering uten sikkerhetsgrad» likt, ville slått dem
// sammen til én. Typene under skiller derfor `null` fra en tom liste fra en
// verdi — og lesingen kaster framfor å fylle inn.
//
// ----------------------------------------------------------------------------
// Hvorfor dekningen regnes ut her og ikke i visningen
//
// Kildedekningen er en klinisk opplysning, ikke pynt. Regnes den i en komponent,
// finnes den bare der den tilfeldigvis er skrevet; regnes den her, er den den
// samme overalt og kan prøves uten en nettleser.
//
// Utrygg inndata: svaret er data. Ingenting her tolker en verdi som noe annet
// enn en verdi.
// ============================================================================

export interface CandidateClaim {
  readonly statement: string
  readonly scope: string
  readonly subjectDrug: string
  readonly topic: string
  readonly population: string | null
  readonly direction: string | null
  readonly uncertaintySummary: string
  readonly qualifiers: string | null
}

export interface CandidateAssessment {
  readonly framework: string
  readonly certaintyLevel: string
  readonly rationale: string
  readonly evidenceGap: string | null
}

export interface CandidateSourceCoverage {
  readonly sourceId: string
  readonly title: string
  readonly evidenceItemCount: number
  readonly fullTextInLibrary: boolean
  readonly readabilityChecked: boolean
  readonly groundingMachineProved: boolean
}

export interface CandidateGrounding {
  readonly checkField: string
  readonly sourceExcerpt: string
  readonly sourceLocator: string
}

export interface CandidateEvidence {
  readonly evidenceItemId: string
  readonly relationshipType: string
  readonly directness: string
  readonly sourceTitle: string
  readonly outcome: string
  readonly outcomeDetail: string
  readonly reportedDirection: string
  readonly estimate: string | null
  readonly estimateUnit: string | null
  readonly requiredCheckFields: readonly string[]
  readonly coveredCheckFields: readonly string[]
  readonly groundingMachineProved: boolean
  readonly groundings: readonly CandidateGrounding[]
  readonly extractionCheckOutcome: string | null
}

export interface CandidateFinalControl {
  readonly decision: string
  readonly rationale: string
  readonly decidedAt: string
  readonly reviewer: string
  readonly candidateDigest: string
}

export interface CandidateView {
  readonly candidateId: string
  readonly claimRevisionId: string
  readonly candidateDigest: string
  readonly builtAt: string
  /** `false` betyr at grunnlaget er endret siden kandidaten ble forseglet. */
  readonly isCurrent: boolean
  readonly currentDigest: string
  readonly experimental: boolean
  readonly published: boolean
  readonly claim: CandidateClaim
  /** `null` når ingen evidensvurdering er registrert — ikke en tom vurdering. */
  readonly assessment: CandidateAssessment | null
  readonly evidence: readonly CandidateEvidence[]
  readonly sourceCoverage: readonly CandidateSourceCoverage[]
  readonly finalControls: readonly CandidateFinalControl[]
}

const SUBJECT = 'Kandidatsvaret'

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
    fail(`${where}.${key}`, 'er ikke en tekst med innhold')
  }
  return value
}

function optionalText(record: Record<string, unknown>, key: string, where: string): string | null {
  const value = record[key]
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'string') {
    fail(`${where}.${key}`, 'er verken en tekst eller fraværende')
  }
  return value
}

function flag(record: Record<string, unknown>, key: string, where: string): boolean {
  const value = record[key]
  if (typeof value !== 'boolean') {
    fail(`${where}.${key}`, 'er ikke en boolsk verdi')
  }
  return value
}

function count(record: Record<string, unknown>, key: string, where: string): number {
  const value = record[key]
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    fail(`${where}.${key}`, 'er ikke et helt tall som ikke er negativt')
  }
  return value
}

function list(record: Record<string, unknown>, key: string, where: string): readonly unknown[] {
  const value = record[key]
  if (!Array.isArray(value)) {
    fail(`${where}.${key}`, 'er ikke en liste')
  }
  return value
}

function textList(record: Record<string, unknown>, key: string, where: string): readonly string[] {
  return list(record, key, where).map((entry, index) => {
    if (typeof entry !== 'string') {
      fail(`${where}.${key}[${String(index)}]`, 'er ikke en tekst')
    }
    return entry
  })
}

function parseEvidence(value: unknown, index: number): CandidateEvidence {
  const where = `content.evidence[${String(index)}]`
  const record = objectAt(value, where)
  const source = objectAt(record['source'], `${where}.source`)
  const coverage = objectAt(record['coverage'], `${where}.coverage`)
  const check = record['extraction_check']

  return {
    evidenceItemId: text(record, 'evidence_item_id', where),
    relationshipType: text(record, 'relationship_type', where),
    directness: text(record, 'directness', where),
    sourceTitle: text(source, 'title', `${where}.source`),
    outcome: text(record, 'outcome', where),
    outcomeDetail: text(record, 'outcome_detail', where),
    reportedDirection: text(record, 'reported_direction', where),
    estimate: optionalText(record, 'estimate', where),
    estimateUnit: optionalText(record, 'estimate_unit', where),
    requiredCheckFields: textList(coverage, 'required_check_fields', `${where}.coverage`),
    coveredCheckFields: textList(coverage, 'covered_check_fields', `${where}.coverage`),
    groundingMachineProved: flag(coverage, 'grounding_machine_proved', `${where}.coverage`),
    groundings: list(record, 'field_groundings', where).map((entry, groundingIndex) => {
      const groundingWhere = `${where}.field_groundings[${String(groundingIndex)}]`
      const grounding = objectAt(entry, groundingWhere)
      return {
        checkField: text(grounding, 'check_field', groundingWhere),
        sourceExcerpt: text(grounding, 'source_excerpt', groundingWhere),
        sourceLocator: text(grounding, 'source_locator', groundingWhere),
      }
    }),
    extractionCheckOutcome:
      check === undefined || check === null
        ? null
        : text(
            objectAt(check, `${where}.extraction_check`),
            'outcome',
            `${where}.extraction_check`,
          ),
  }
}

/** Leser svaret fra `api.candidate_for_control`, og avviser alt annet. */
export function parseCandidateView(value: unknown): CandidateView {
  const record = objectAt(value, 'svaret')
  const content = objectAt(record['content'], 'content')
  const claim = objectAt(content['claim_revision'], 'content.claim_revision')
  const assessmentValue = content['evidence_assessment']

  return {
    candidateId: text(record, 'candidate_id', 'svaret'),
    claimRevisionId: text(record, 'claim_revision_id', 'svaret'),
    candidateDigest: text(record, 'candidate_digest', 'svaret'),
    builtAt: text(record, 'built_at', 'svaret'),
    isCurrent: flag(record, 'is_current', 'svaret'),
    currentDigest: text(record, 'current_digest', 'svaret'),
    experimental: flag(record, 'experimental', 'svaret'),
    published: flag(record, 'published', 'svaret'),
    claim: {
      statement: text(claim, 'statement', 'content.claim_revision'),
      scope: text(claim, 'scope', 'content.claim_revision'),
      subjectDrug: text(claim, 'subject_drug', 'content.claim_revision'),
      topic: text(claim, 'topic', 'content.claim_revision'),
      population: optionalText(claim, 'population', 'content.claim_revision'),
      direction: optionalText(claim, 'direction', 'content.claim_revision'),
      uncertaintySummary: text(claim, 'uncertainty_summary', 'content.claim_revision'),
      qualifiers: optionalText(claim, 'qualifiers', 'content.claim_revision'),
    },
    assessment:
      assessmentValue === undefined || assessmentValue === null
        ? null
        : (() => {
            const assessment = objectAt(assessmentValue, 'content.evidence_assessment')
            return {
              framework: text(assessment, 'framework', 'content.evidence_assessment'),
              certaintyLevel: text(assessment, 'certainty_level', 'content.evidence_assessment'),
              rationale: text(assessment, 'rationale', 'content.evidence_assessment'),
              evidenceGap: optionalText(assessment, 'evidence_gap', 'content.evidence_assessment'),
            }
          })(),
    evidence: list(content, 'evidence', 'content').map(parseEvidence),
    sourceCoverage: list(content, 'source_coverage', 'content').map((entry, index) => {
      const where = `content.source_coverage[${String(index)}]`
      const coverage = objectAt(entry, where)
      return {
        sourceId: text(coverage, 'source_id', where),
        title: text(coverage, 'title', where),
        evidenceItemCount: count(coverage, 'evidence_item_count', where),
        fullTextInLibrary: flag(coverage, 'full_text_in_library', where),
        readabilityChecked: flag(coverage, 'readability_checked', where),
        groundingMachineProved: flag(coverage, 'grounding_machine_proved', where),
      }
    }),
    finalControls: list(record, 'final_controls', 'svaret').map((entry, index) => {
      const where = `final_controls[${String(index)}]`
      const control = objectAt(entry, where)
      return {
        decision: text(control, 'decision', where),
        rationale: text(control, 'rationale', where),
        decidedAt: text(control, 'decided_at', where),
        reviewer: text(control, 'reviewer', where),
        candidateDigest: text(control, 'candidate_digest', where),
      }
    }),
  }
}

/** Hvor mange av kontrollfeltene et evidensfunn faktisk har dekning for. */
export function coverageRatio(evidence: CandidateEvidence): {
  readonly covered: number
  readonly required: number
} {
  const covered = evidence.requiredCheckFields.filter((field) =>
    evidence.coveredCheckFields.includes(field),
  ).length
  return { covered, required: evidence.requiredCheckFields.length }
}

/**
 * Kontrollfeltene raden påstår noe om, men som ingen kontroll dekker.
 *
 * Vises som en egen liste framfor å utelates: et felt som ikke er kontrollert,
 * er ikke det samme som et felt som er kontrollert og funnet i orden, og en
 * visning som bare viste det andre, ville latt det første se ut som det.
 */
export function uncoveredCheckFields(evidence: CandidateEvidence): readonly string[] {
  return evidence.requiredCheckFields.filter(
    (field) => !evidence.coveredCheckFields.includes(field),
  )
}

/**
 * Om kandidaten kan sluttkontrolleres nå.
 *
 * `false` når grunnlaget er endret siden forseglingen. Da er svaret å bygge
 * kandidaten på nytt, ikke å godkjenne den gamle: teksten ville stemt, og det
 * den hviler på, ville vært noe annet (ANTIDEP_CONSTITUTION.md regel 5).
 */
export function canBeFinalControlled(view: CandidateView): boolean {
  return view.isCurrent && view.candidateDigest === view.currentDigest
}
