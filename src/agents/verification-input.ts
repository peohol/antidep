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
  /**
   * Hva slags representasjon som faktisk ble hentet (EVIDENCE_PIPELINE.md §13).
   *
   * `null` betyr at opplysningen ikke er registrert — tilstanden alle
   * kildeversjoner registrert før migrasjon 003b er i — aldri at
   * representasjonen er ukjent men brukbar. En agentekstraksjon kan ikke bygge
   * på en versjon uten den.
   */
  readonly representation: string | null
  readonly hasStorageReference: boolean
}

/** En global bibliografisk identifikator for kilden. */
export interface SourceIdentifier {
  /** `doi` eller `pmid`. */
  readonly system: string
  readonly value: string
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
  /** PostgreSQL-interval som tekst, for eksempel «182 days». `null` = ikke oppgitt. */
  readonly timepointMin: string | null
  readonly timepointMax: string | null
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

/**
 * Kildeforankringen av ett kontrollerbart felt (migrasjon 005u).
 *
 * Fire ting, og ikke en femte: hvilket felt forankringen gjelder, det ordrette
 * kildeutdraget verdien er lest ut av, den presise kildepekeren for nettopp det
 * utdraget, og en kort eksplisitt begrunnelse for hvordan utdraget ble til den
 * strukturerte verdien.
 *
 * Den strukturerte verdien selv står *ikke* her, og det er hele poenget: den er
 * kolonnen på evidensfunnet, og en kopi ved siden av kunne kommet i utakt med
 * den. En kontrollør som bekreftet kopien, ville da bekreftet noe annet enn det
 * databasen holder (ANTIDEP_CONSTITUTION.md §4, §8).
 */
export interface EvidenceFieldGrounding {
  readonly fieldGroundingId: string
  /** En verdi fra `workflow.evidence_check_field`. */
  readonly checkField: string
  readonly sourceExcerpt: string
  readonly sourceLocator: string
  readonly justification: string
  readonly createdAt: string
  readonly createdByActorId: string
}

export interface VerificationItem {
  readonly evidenceItemId: string
  readonly createdByActorId: string
  readonly createdByActorKey: string
  /**
   * Hvordan raden ble til. Sier hvem eller hva som laget ekstraksjonen, aldri om
   * den er kontrollert — kontrollen er en egen hendelse
   * (ANTIDEP_CONSTITUTION.md §10).
   */
  readonly extractionMethod: string
  /**
   * Fingeravtrykket databasen har beregnet av hele ekstraksjonen. Bundet til
   * raden og ikke til id-en: en korrigert ekstraksjon er et nytt funn med et
   * annet avtrykk.
   */
  readonly contentHash: string
  readonly sourceId: string
  readonly sourceTitle: string
  /**
   * Dokumenttypen kilden har. Egen akse fra studiedesignet på funnet: én artikkel
   * kan rapportere flere design, og en retningslinje leses ikke som en
   * primærstudie.
   */
  readonly sourceType: string
  readonly sourceAuthorsOrIssuer: string
  readonly sourcePublisherOrJournal: string | null
  /** Alltid avkortet til presisjonen under. `null` = ingen dato er registrert. */
  readonly sourcePublicationDate: string | null
  readonly sourcePublicationDatePrecision: string | null
  /**
   * Kildens status. `retracted` og `withdrawn` blokkerer publisering
   * (publiseringsgatens G7), og en flate som ikke viste den, ville latt en
   * reviewer gå god for en påstand som hviler på en tilbaketrukket kilde
   * (ANTIDEP_CONSTITUTION.md §14).
   */
  readonly sourceStatus: string
  /** `null` betyr «ingen begrunnelse er registrert», ikke «statusen er normal». */
  readonly sourceStatusNote: string | null
  /**
   * Kildens globale identifikatorer.
   *
   * Den menneskelige lenken til kilden bygges av disse, ikke av
   * `sourceVersion.retrievedFrom`: den siste er maskinens eksakte henteadresse
   * — for et EUtils-kall er den XML — og skal bevares for hashing og proveniens,
   * men den er ikke artikkelen et menneske skal åpne (`source-links.ts`).
   */
  readonly sourceIdentifiers: readonly SourceIdentifier[]
  readonly sourceVersion: VerificationSourceVersion | null
  /**
   * Kildeforankringen per kontrollfelt, i vokabularets egen rekkefølge.
   *
   * Tom liste betyr at ingen forankring er registrert — tilstanden alle funn
   * registrert før migrasjon 005u er i. Den skal vises som fravær, aldri fylles
   * inn fra `rawExtraction`: et utdrag gjettet ut av den rå ekstraksjonen ville
   * vært å konstruere nettopp det grunnlaget kontrollen skal prøve.
   */
  readonly fieldGroundings: readonly EvidenceFieldGrounding[]
  /**
   * Feltene funnet påstår noe om studien, og som kontrolleres ett av gangen.
   *
   * `workflow.required_check_fields(uuid)` uten `raw_extraction` og
   * `source_locator`: de to er provenansfelter, ikke kliniske påstander en lege
   * bedømmer som egne beslutninger. Garantien de bærer er ikke svekket, men
   * flyttet dit den er sterkere — hver forankring har sitt eget ordrette utdrag
   * og sin egen presise peker (migrasjon 005v).
   */
  readonly semanticCheckFields: readonly string[]
  /** Feltene forankringen faktisk dekker. Differansen mot settet over er det som mangler. */
  readonly groundedCheckFields: readonly string[]
  /**
   * Om maskinen har bevist venstresiden for nøyaktig dette grunnlaget.
   *
   * `workflow.grounding_machine_proved(uuid)`: det finnes en maskinell
   * ekstraksjonskontroll som gjelder det grunnlaget raden har nå, og som fant
   * hvert forankret utdrag ordrett i en reprodusert representasjon. Uten den
   * kan ingen menneskelig bekreftelse registreres (migrasjon 005x), og
   * kontrolløkten skal si det før noen begynner å bedømme semantikken.
   */
  readonly groundingMachineProved: boolean
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
    representation: asOptionalString(record['representation']),
    hasStorageReference: record['has_storage_reference'] === true,
  }
}

/**
 * Kildens identifikatorer.
 *
 * En manglende nøkkel leses som en tom liste: et svar fra en eldre
 * projeksjonsversjon har den ikke, og en kilde uten registrerte
 * identifikatorer har heller ikke noen. Er nøkkelen der, men ikke en liste, er
 * det et kontraktsbrudd og sier fra.
 */
function parseSourceIdentifiers(value: unknown): readonly SourceIdentifier[] {
  if (value === null || value === undefined) {
    return []
  }
  if (!Array.isArray(value)) {
    throw new Error('Svaret fra api.extraction_verification_input mangler listen identifiers.')
  }
  return value.map((entry, index) => {
    const record = asRecord(entry, `identifiers[${String(index)}]`)
    return {
      system: asString(
        record['identifier_system'],
        `identifiers[${String(index)}].identifier_system`,
      ),
      value: asString(record['identifier_value'], `identifiers[${String(index)}].identifier_value`),
    }
  })
}

/** En liste med feltnavn, eller en tom liste når nøkkelen ikke finnes. */
function parseCheckFieldList(value: unknown, where: string): readonly string[] {
  if (value === null || value === undefined) {
    return []
  }
  if (!Array.isArray(value)) {
    throw new Error(`Svaret fra api.extraction_verification_input mangler listen ${where}.`)
  }
  return value.map((entry, index) => asString(entry, `${where}[${String(index)}]`))
}

/**
 * Én forankringsrad, eller en feil som sier hva som manglet.
 *
 * Leses like strengt som resten: en forankring som stille mistet utdraget sitt,
 * ville vist kontrolløren en tom rute der grunnlaget skulle stått — og en tom
 * rute ser ut som «ingenting å innvende», ikke som «grunnlaget mangler».
 */
function parseFieldGrounding(value: unknown): EvidenceFieldGrounding {
  const record = asRecord(value, 'field_groundings[]')
  return {
    fieldGroundingId: asString(
      record['field_grounding_id'],
      'field_groundings[].field_grounding_id',
    ),
    checkField: asString(record['check_field'], 'field_groundings[].check_field'),
    sourceExcerpt: asString(record['source_excerpt'], 'field_groundings[].source_excerpt'),
    sourceLocator: asString(record['source_locator'], 'field_groundings[].source_locator'),
    justification: asString(record['justification'], 'field_groundings[].justification'),
    createdAt: asString(record['created_at'], 'field_groundings[].created_at'),
    createdByActorId: asString(
      record['created_by_actor_id'],
      'field_groundings[].created_by_actor_id',
    ),
  }
}

/**
 * Forankringslisten.
 *
 * Et svar som er eldre enn migrasjon 005u har ingen nøkkel i det hele tatt, og
 * en manglende nøkkel leses derfor som en tom liste framfor som en feil. Er
 * nøkkelen der, men ikke en liste, er det et kontraktsbrudd og sier fra.
 */
function parseFieldGroundings(value: unknown): readonly EvidenceFieldGrounding[] {
  if (value === null || value === undefined) {
    return []
  }
  if (!Array.isArray(value)) {
    throw new Error('Svaret fra api.extraction_verification_input mangler listen field_groundings.')
  }
  return value.map(parseFieldGrounding)
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
    timepointMin: asOptionalString(record['timepoint_min']),
    timepointMax: asOptionalString(record['timepoint_max']),
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

/**
 * Ett evidensfunn slik både `api.extraction_verification_input(...)` og
 * `api.claim_verification_input(...)` leverer det.
 *
 * De to funksjonene bygger nøyaktig den samme formen for et evidensfunn, og det
 * er et bevisst valg i migrasjon 005k: da leser de to kjørerne det samme
 * grunnlaget med den samme koden, og en endring i formen kan ikke bli riktig
 * det ene stedet og feil det andre.
 */
export function parseVerificationItem(value: unknown): VerificationItem {
  const record = asRecord(value, 'items[]')
  const source = asRecord(record['source'], 'items[].source')
  const byThisActor = record['verifications_by_this_actor']

  return {
    evidenceItemId: asString(record['evidence_item_id'], 'items[].evidence_item_id'),
    createdByActorId: asString(record['created_by_actor_id'], 'items[].created_by_actor_id'),
    createdByActorKey: asString(record['created_by_actor_key'], 'items[].created_by_actor_key'),
    extractionMethod: asString(record['extraction_method'], 'items[].extraction_method'),
    contentHash: asString(record['content_hash'], 'items[].content_hash'),
    sourceId: asString(source['source_id'], 'items[].source.source_id'),
    sourceTitle: asString(source['title'], 'items[].source.title'),
    sourceType: asString(source['source_type'], 'items[].source.source_type'),
    sourceAuthorsOrIssuer: asString(
      source['authors_or_issuer'],
      'items[].source.authors_or_issuer',
    ),
    sourcePublisherOrJournal: asOptionalString(source['publisher_or_journal']),
    sourcePublicationDate: asOptionalString(source['publication_date']),
    sourcePublicationDatePrecision: asOptionalString(source['publication_date_precision']),
    sourceStatus: asString(source['source_status'], 'items[].source.source_status'),
    sourceStatusNote: asOptionalString(source['status_note']),
    sourceIdentifiers: parseSourceIdentifiers(source['identifiers']),
    sourceVersion: parseSourceVersion(record['source_version']),
    fieldGroundings: parseFieldGroundings(record['field_groundings']),
    semanticCheckFields: parseCheckFieldList(
      record['semantic_check_fields'],
      'semantic_check_fields',
    ),
    groundingMachineProved: record['grounding_machine_proved'] === true,
    groundedCheckFields: parseCheckFieldList(
      record['grounded_check_fields'],
      'grounded_check_fields',
    ),
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
    items: items.map(parseVerificationItem),
  }
}
