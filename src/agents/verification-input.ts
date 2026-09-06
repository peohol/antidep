// ============================================================================
// Svaret fra `api.extraction_verification_input(...)`, lest trygt
//
// Formen er dokumentert i funksjonskommentaren i migrasjon 005h og er en
// kontrakt utad på samme måte som kolonnene i et api-view. Denne modulen
// oversetter den til typer runneren kan regne på, og avviser et svar som ikke
// har den formen framfor å gjette.
//
// Hvorfor svaret leses defensivt når det kommer fra vår egen database: en
// jsonb-form har ingen kolonnetyper PostgREST kan håndheve, så en feil her
// ville ellers dukket opp som `undefined` midt i en kontroll — og en kontroll
// som stille mistet et felt, ville rapportert at den kontrollerte mer enn den
// gjorde. Det er nøyaktig den feilen `checked_fields` finnes for å hindre
// (DATABASE_ARCHITECTURE.md §29).
// ============================================================================

/** Kildeversjonen et evidensfunn ble lest ut av, når en er registrert. */
export interface VerificationSourceVersion {
  readonly sourceVersionId: string
  readonly retrievedAt: string
  readonly retrievedFrom: string
  readonly externalVersion: string | null
  /** NULL betyr et sporet besøk uten fingeravtrykk (MVP_IMPLEMENTATION_PLAN.md §74.32). */
  readonly contentHash: string | null
  readonly hasStorageReference: boolean
}

/** Ekstraksjonen slik den er registrert, ordrett. */
export interface VerificationExtraction {
  readonly designCode: string
  readonly populationLabel: string | null
  readonly populationAvailability: string
  readonly populationDetail: string
  readonly sampleSize: number | null
  readonly sampleSizeAvailability: string
  readonly interventionDrugName: string
  readonly interventionDetail: string | null
  readonly comparatorKind: string
  readonly comparatorDrugName: string | null
  readonly comparatorDetail: string | null
  readonly outcomeLabel: string
  readonly outcomeDetail: string
  readonly timepointAvailability: string
  readonly reportedDirection: string
  readonly effectMeasure: string | null
  readonly estimate: string | null
  readonly estimateUnit: string | null
  readonly estimateAvailability: string
  readonly ciLower: string | null
  readonly ciUpper: string | null
  readonly ciLevelPercent: string | null
  readonly confidenceIntervalAvailability: string
  readonly limitationsText: string | null
  readonly sourceLocator: string
  /**
   * Den rå ekstraksjonen, slik den er lagret.
   *
   * Bevisst utypet: `knowledge.evidence_items.raw_extraction` er jsonb nettopp
   * fordi variasjonen mellom kildetyper er reell (migrasjon 003, §20). Den
   * manuelle skriveveien lagrer ett sitat under nøkkelen `sitat` (migrasjon
   * 007e), mens de seedede funnene fra migrasjon 003 bruker en rikere form med
   * `metode`, `resultat` og `populasjon`. Kontrollen leser derfor formen den
   * finner, framfor å kreve én bestemt (se `verbatimQuotes`).
   */
  readonly rawExtraction: unknown
}

export interface VerificationItem {
  readonly evidenceItemId: string
  readonly createdByActorKey: string
  readonly sourceId: string
  readonly sourceTitle: string
  readonly sourceVersion: VerificationSourceVersion | null
  readonly extraction: VerificationExtraction
  readonly verificationsByThisActor: number
}

export interface VerificationInput {
  readonly agentRunId: string
  readonly verifierActorId: string
  readonly items: readonly VerificationItem[]
}

function asRecord(value: unknown, where: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`Svaret fra api.extraction_verification_input mangler et objekt i ${where}.`)
  }
  return value as Record<string, unknown>
}

function asString(value: unknown, where: string): string {
  if (typeof value !== 'string') {
    throw new Error(`Svaret fra api.extraction_verification_input mangler ${where}.`)
  }
  return value
}

/**
 * Tekst eller fravær. `null` og `undefined` er det samme her, og begge betyr
 * fravær — ikke tom tekst. Skillet mellom «ingen verdi» og «hvorfor det ikke er
 * noen verdi» ligger i den ledsagende `*_availability`-verdien, ikke her
 * (DATABASE_ARCHITECTURE.md §19.1).
 */
function asOptionalString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

/**
 * En klinisk `numeric` — estimat og konfidensgrenser — som tekst.
 *
 * Verdien *må* komme som tekst, og et tall er en kontraktsbrudd som skal si
 * fra. Grunnen er at avrundingen ikke kan angres her: `numeric` er
 * vilkårlig presis, men et JSON-tall blir en IEEE-754 double i det
 * `JSON.parse` leser svaret — før noen linje i denne filen kjører. Et lagret
 * `9007199254740993` er da allerede blitt `9007199254740992`, og
 * `0.1234567890123456789` er blitt `0.12345678901234568`.
 *
 * Konsekvensen ville vært en falsk bekreftelse: står den avrundede verdien i
 * kilden, mens den lagrede ikke gjør det, ville kontrollen ført `estimate` som
 * kontrollert for et tall som ikke står der. Det er nøyaktig det denne
 * verifikatoren finnes for å hindre.
 *
 * `api.extraction_verification_input(...)` serialiserer derfor feltene med
 * `::text`, slik `timepoint_min` og `timepoint_max` alt gjorde. Kastet her er
 * det som gjør at en senere endring i den funksjonen ikke kan gjeninnføre
 * avrundingen stille. Samme resonnement som `lib/create-evidence-item.ts`.
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

function asOptionalInteger(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) ? value : null
}

function parseSourceVersion(value: unknown): VerificationSourceVersion | null {
  if (value === null || value === undefined) {
    return null
  }
  const record = asRecord(value, 'source_version')
  return {
    sourceVersionId: asString(record['source_version_id'], 'source_version.source_version_id'),
    retrievedAt: asString(record['retrieved_at'], 'source_version.retrieved_at'),
    retrievedFrom: asString(record['retrieved_from'], 'source_version.retrieved_from'),
    externalVersion: asOptionalString(record['external_version']),
    contentHash: asOptionalString(record['content_hash']),
    hasStorageReference: record['has_storage_reference'] === true,
  }
}

function parseExtraction(value: unknown): VerificationExtraction {
  const record = asRecord(value, 'extraction')

  return {
    designCode: asString(record['design_code'], 'extraction.design_code'),
    populationLabel: asOptionalString(record['population_label']),
    populationAvailability: asString(
      record['population_availability'],
      'extraction.population_availability',
    ),
    populationDetail: asString(record['population_detail'], 'extraction.population_detail'),
    sampleSize: asOptionalInteger(record['sample_size']),
    sampleSizeAvailability: asString(
      record['sample_size_availability'],
      'extraction.sample_size_availability',
    ),
    interventionDrugName: asString(
      record['intervention_drug_name'],
      'extraction.intervention_drug_name',
    ),
    interventionDetail: asOptionalString(record['intervention_detail']),
    comparatorKind: asString(record['comparator_kind'], 'extraction.comparator_kind'),
    comparatorDrugName: asOptionalString(record['comparator_drug_name']),
    comparatorDetail: asOptionalString(record['comparator_detail']),
    outcomeLabel: asString(record['outcome_label'], 'extraction.outcome_label'),
    outcomeDetail: asString(record['outcome_detail'], 'extraction.outcome_detail'),
    timepointAvailability: asString(
      record['timepoint_availability'],
      'extraction.timepoint_availability',
    ),
    reportedDirection: asString(record['reported_direction'], 'extraction.reported_direction'),
    effectMeasure: asOptionalString(record['effect_measure']),
    estimate: asOptionalNumericText(record['estimate'], 'extraction.estimate'),
    estimateUnit: asOptionalString(record['estimate_unit']),
    estimateAvailability: asString(
      record['estimate_availability'],
      'extraction.estimate_availability',
    ),
    ciLower: asOptionalNumericText(record['ci_lower'], 'extraction.ci_lower'),
    ciUpper: asOptionalNumericText(record['ci_upper'], 'extraction.ci_upper'),
    ciLevelPercent: asOptionalNumericText(
      record['ci_level_percent'],
      'extraction.ci_level_percent',
    ),
    confidenceIntervalAvailability: asString(
      record['confidence_interval_availability'],
      'extraction.confidence_interval_availability',
    ),
    limitationsText: asOptionalString(record['limitations_text']),
    sourceLocator: asString(record['source_locator'], 'extraction.source_locator'),
    rawExtraction: record['raw_extraction'] ?? null,
  }
}

function parseItem(value: unknown): VerificationItem {
  const record = asRecord(value, 'items[]')
  const source = asRecord(record['source'], 'items[].source')
  const byThisActor = record['verifications_by_this_actor']

  return {
    evidenceItemId: asString(record['evidence_item_id'], 'items[].evidence_item_id'),
    createdByActorKey: asString(record['created_by_actor_key'], 'items[].created_by_actor_key'),
    sourceId: asString(source['source_id'], 'items[].source.source_id'),
    sourceTitle: asString(source['title'], 'items[].source.title'),
    sourceVersion: parseSourceVersion(record['source_version']),
    extraction: parseExtraction(record['extraction']),
    verificationsByThisActor: typeof byThisActor === 'number' ? byThisActor : 0,
  }
}

/** Leser svaret fra databasen, eller kaster med en setning som sier hva som manglet. */
export function parseVerificationInput(payload: unknown): VerificationInput {
  const record = asRecord(payload, 'svaret')
  const items = record['items']
  if (!Array.isArray(items)) {
    throw new Error('Svaret fra api.extraction_verification_input mangler listen items.')
  }
  return {
    agentRunId: asString(record['agent_run_id'], 'agent_run_id'),
    verifierActorId: asString(record['verifier_actor_id'], 'verifier_actor_id'),
    items: items.map(parseItem),
  }
}
