// ============================================================================
// Ekstraksjonsforslaget: den permanente grensen mellom forslagsleddet og Antidep
//
// Et forslag er ikke en ekstraksjon. Det er inndata til den, og det blir en
// ekstraksjon først når det er registrert gjennom `api.register_agent_extraction`
// innenfor en åpen agentkjøring — med hvert utdrag prøvd ordrett mot den
// representasjonen som faktisk ble hentet (`extraction-run.ts`).
//
// ----------------------------------------------------------------------------
// Hvorfor forslaget er sin egen modul, og leses fra en fil
//
// Leddet som *leser* en artikkel og foreslår strukturerte verdier, krever en
// språkmodell, og dermed en leverandør og en konto (issue #63). Alt det andre i
// kjeden er deterministisk og skal ikke vente på den: hentingen, den ordrette
// kontrollen av hvert utdrag, kjøringens proveniens og selve registreringen.
//
// Forslaget er derfor grenseflaten mellom de to, og den er skrevet for å være
// permanent (ANTIDEP_CONSTITUTION.md §20). Formen er den samme enten den er
// skrevet av et menneske, av ChatGPT utenfor Antidep, eller en dag av et
// innebygd modell-ledd — og den kontrolleres like strengt uansett hvem som
// skrev den. Et framtidig modelladapter er derfor et nytt ledd foran denne
// filen, ikke en endring av den.
//
// ----------------------------------------------------------------------------
// Hva forslagsprodusenten *ikke* kan
//
// Den kan ikke skrive til databasen. Den produserer en fil; alt som rører basen
// skjer etterpå, i kjøringen, med agentlegitimasjon og under de deterministiske
// kontrollene. Det er ikke en konvensjon, men en konsekvens av at forslaget er
// data: det finnes ingen skrivevei som tar imot et forslag.
//
// ----------------------------------------------------------------------------
// Hvorfor formen kontrolleres her og ikke bare av databasen
//
// Databasen er fasiten, og dens avvisninger propageres uendret. Men en
// agentkjøring som sender et halvferdig forslag, ville fått en fremmednøkkel-
// eller castingfeil ut av `api`, og feilen ville pekt på en kolonne framfor på
// det som faktisk mangler i forslaget. Kontrollen her sier hvilket felt i
// forslaget som er galt, før noe skrives.
//
// Tre regler gjør kontrollen streng nok til å være en grense:
//
//   1. **Et ukjent felt er en feil, ikke noe som ignoreres.** Et forslag med
//      `extimate` i stedet for `estimate` ville ellers blitt registrert uten
//      estimatet, og feilen ville sett ut som en manglende verdi i kilden.
//   2. **Ingenting fylles inn.** Et forslag uten en verdi er et forslag uten
//      den verdien (§6). Manglende forankring blir ikke gjettet fram, verken
//      fra andre felter eller fra en samlet tolkning.
//   3. **Vokabularene er lukket.** De leses fra `src/types/api.ts`, som
//      `tests/api-vocabularies.test.ts` holder identisk med enum-ene i
//      migrasjonene. En verdi utenfor vokabularet avvises her, med feltnavnet.
//
// Utrygg inndata: forslaget er data, aldri instruksjoner (CLAUDE.md). Ingenting
// i det tolkes som noe annet enn verdier og tekst.
// ============================================================================

import {
  COMPARATOR_KINDS,
  EFFECT_MEASURES,
  ESTIMATE_UNITS,
  EVIDENCE_CHECK_FIELDS,
  REPORTED_DIRECTIONS,
  STUDY_DESIGNS,
  VALUE_AVAILABILITIES,
  type Uuid,
} from '../types/api.ts'

/**
 * Versjonen av selve kontrakten, oppgitt i hvert forslag.
 *
 * Uten den ville en senere utvidelse av formen ikke kunnet skilles fra et
 * forslag skrevet mot en eldre form: begge ville manglet det samme feltet, og
 * bare det ene ville vært en feil. Verdien er et *krav*, ikke en opplysning —
 * et forslag som oppgir noe annet, avvises.
 */
export const EXTRACTION_PROPOSAL_VERSION = 'antidep/extraction-proposal@1'

/**
 * Hvor kort et ordrett kildeutdrag kan være og fortsatt bære kontekst.
 *
 * Et utdrag er kontrollgrunnlaget et menneske ser på venstre side i
 * kontrolløkten, og «284» eller «8 weeks» alene er ikke et grunnlag: tallet står
 * kanskje fem steder i artikkelen, og utdraget sier ikke hvilket. Grensen er den
 * samme som `MIN_QUOTE_LENGTH` i `extraction-checks.ts` bruker for at et sitat
 * skal være verdt å kontrollere ordrett, og av samme grunn.
 */
export const MIN_SOURCE_EXCERPT_LENGTH = 24

/** Én forankring: feltet, utdraget, pekeren og begrunnelsen. */
export interface ProposedGrounding {
  readonly checkField: string
  readonly sourceExcerpt: string
  readonly sourceLocator: string
  readonly justification: string
}

/** De strukturerte verdiene forslaget påstår om studien. */
export interface ProposedExtraction {
  readonly designCode: string
  readonly populationId: Uuid | null
  readonly populationAvailability: string
  readonly populationDetail: string
  readonly sampleSize: number | null
  readonly sampleSizeAvailability: string
  readonly interventionDrugId: Uuid
  readonly interventionDetail: string | null
  readonly comparatorKind: string
  readonly comparatorDrugId: Uuid | null
  readonly comparatorDetail: string | null
  readonly outcomeConceptId: Uuid
  readonly outcomeDetail: string
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
  readonly sourceQuote: string | null
}

/** Hele forslaget: kontraktsversjonen, hvilken kilde, hvilken versjon, verdiene og forankringen. */
export interface ExtractionProposal {
  readonly proposalVersion: typeof EXTRACTION_PROPOSAL_VERSION
  readonly sourceId: Uuid
  readonly sourceVersionId: Uuid
  /**
   * Adressen kildeversjonen ble hentet fra, og fingeravtrykket den ble
   * registrert med.
   *
   * Begge står i forslaget fordi agenten ikke kan lese
   * `knowledge.source_versions` — den har ingen editor-rolle, og lesetilgangen
   * er ikke gitt til agentroller. Kjøringen henter adressen på nytt og krever
   * at fingeravtrykket stemmer, slik at utdragene prøves mot nøyaktig den
   * utgaven ekstraksjonen skal peke på.
   *
   * Skulle et forslag oppgi feil fingeravtrykk, blir ekstraksjonen likevel
   * fanget: den deterministiske ekstraksjonskontrollen henter kildeversjonens
   * *egen* adresse og sammenligner med dens *egen* hash, og uten den kan ingen
   * menneskelig bekreftelse registreres (migrasjon 005x).
   */
  readonly retrievedFrom: string
  readonly contentHash: string
  readonly extraction: ProposedExtraction
  readonly fieldGroundings: readonly ProposedGrounding[]
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const CONTENT_HASH_PATTERN = /^sha256:[0-9a-f]{64}$/

function problem(where: string, what: string): never {
  throw new Error(`Ekstraksjonsforslaget er ugyldig: ${where} ${what}.`)
}

/**
 * Én oppslagsbok med regnskap over hvilke nøkler som faktisk er lest.
 *
 * Regnskapet er hele poenget: uten det ville et felt med skrivefeil vært
 * usynlig, og forslaget ville blitt registrert uten verdien det trodde det
 * leverte.
 */
interface Fields {
  readonly where: string
  readonly record: Record<string, unknown>
  readonly seen: Set<string>
}

function fieldsOf(value: unknown, where: string): Fields {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    problem(where, 'er ikke et objekt')
  }
  return { where, record: value as Record<string, unknown>, seen: new Set() }
}

function raw(fields: Fields, key: string): unknown {
  fields.seen.add(key)
  return fields.record[key]
}

/**
 * Ingen ukjente felter slipper gjennom.
 *
 * `raw_extraction` navngis særskilt. Feltet finnes på raden i basen som
 * ekstraksjonens egen tolkning, men det er ikke noe et forslag skal levere:
 * verdiene er de strukturerte kolonnene, og grunnlaget er de ordrette utdragene.
 * Et forslag som sendte en samlet tolkning ved siden av, ville invitert til at
 * noen leste verdier ut av den (EVIDENCE_PIPELINE.md §21).
 */
function rejectUnknown(fields: Fields): void {
  const unknown = Object.keys(fields.record)
    .filter((key) => !fields.seen.has(key))
    .sort()
  if (unknown.length === 0) {
    return
  }
  if (unknown.includes('raw_extraction')) {
    problem(
      `${fields.where}.raw_extraction`,
      'hører ikke hjemme i et forslag. De strukturerte verdiene er kolonnene, og grunnlaget er de ordrette utdragene per felt — en samlet tolkning ved siden av ville vært noe å lese verdier ut av',
    )
  }
  problem(fields.where, `har ukjente felter: ${unknown.join(', ')}`)
}

function asText(fields: Fields, key: string): string {
  const value = raw(fields, key)
  if (typeof value !== 'string' || value.trim().length === 0) {
    problem(`${fields.where}.${key}`, 'mangler eller er tom')
  }
  return value
}

function asOptionalText(fields: Fields, key: string): string | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'string') {
    problem(`${fields.where}.${key}`, 'er ikke tekst')
  }
  const trimmed = value.trim()
  return trimmed.length === 0 ? null : value
}

function inVocabulary(
  fields: Fields,
  key: string,
  vocabulary: readonly string[],
  value: string,
): string {
  if (!vocabulary.includes(value)) {
    problem(
      `${fields.where}.${key}`,
      `er ${JSON.stringify(value)}, som ikke er en kjent verdi. Gyldige verdier: ${vocabulary.join(', ')}`,
    )
  }
  return value
}

function asVocabulary(fields: Fields, key: string, vocabulary: readonly string[]): string {
  return inVocabulary(fields, key, vocabulary, asText(fields, key))
}

function asOptionalVocabulary(
  fields: Fields,
  key: string,
  vocabulary: readonly string[],
): string | null {
  const value = asOptionalText(fields, key)
  return value === null ? null : inVocabulary(fields, key, vocabulary, value)
}

function asUuid(fields: Fields, key: string): Uuid {
  const value = asText(fields, key)
  if (!UUID_PATTERN.test(value)) {
    problem(`${fields.where}.${key}`, 'er ikke en uuid')
  }
  return value as Uuid
}

function asOptionalUuid(fields: Fields, key: string): Uuid | null {
  const value = asOptionalText(fields, key)
  if (value === null) {
    return null
  }
  if (!UUID_PATTERN.test(value)) {
    problem(`${fields.where}.${key}`, 'er ikke en uuid')
  }
  return value as Uuid
}

function asOptionalInteger(fields: Fields, key: string): number | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    problem(`${fields.where}.${key}`, 'er ikke et heltall')
  }
  return value
}

/**
 * Et tall bevares som tekst, ordrett slik forslaget skrev det.
 *
 * `1.50` og `1.5` er samme tall, men ikke samme oppgitte verdi, og en tur
 * innom `Number` ville stille endret det som skal kontrolleres mot kilden.
 */
function asOptionalNumericText(fields: Fields, key: string): string | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value === 'number') {
    problem(
      `${fields.where}.${key}`,
      'er oppgitt som et tall. Tallverdier skal stå som tekst, slik at skrivemåten bevares ordrett',
    )
  }
  if (typeof value !== 'string' || value.trim().length === 0) {
    problem(`${fields.where}.${key}`, 'er ikke et tall som tekst')
  }
  return value
}

function parseGrounding(value: unknown, index: number): ProposedGrounding {
  const fields = fieldsOf(value, `field_groundings[${String(index)}]`)
  const grounding: ProposedGrounding = {
    checkField: asVocabulary(fields, 'check_field', EVIDENCE_CHECK_FIELDS),
    sourceExcerpt: asText(fields, 'source_excerpt'),
    sourceLocator: asText(fields, 'source_locator'),
    justification: asText(fields, 'justification'),
  }
  rejectUnknown(fields)

  if (grounding.sourceExcerpt.trim().length < MIN_SOURCE_EXCERPT_LENGTH) {
    problem(
      `${fields.where}.source_excerpt`,
      `er kortere enn ${String(MIN_SOURCE_EXCERPT_LENGTH)} tegn og bærer derfor ikke nok kontekst til å være kontrollgrunnlag. Ta med setningen verdien står i, ordrett`,
    )
  }
  return grounding
}

function parseExtraction(value: unknown): ProposedExtraction {
  const fields = fieldsOf(value, 'extraction')
  const extraction: ProposedExtraction = {
    designCode: asVocabulary(fields, 'design_code', STUDY_DESIGNS),
    populationId: asOptionalUuid(fields, 'population_id'),
    populationAvailability: asVocabulary(fields, 'population_availability', VALUE_AVAILABILITIES),
    populationDetail: asText(fields, 'population_detail'),
    sampleSize: asOptionalInteger(fields, 'sample_size'),
    sampleSizeAvailability: asVocabulary(fields, 'sample_size_availability', VALUE_AVAILABILITIES),
    interventionDrugId: asUuid(fields, 'intervention_drug_id'),
    interventionDetail: asOptionalText(fields, 'intervention_detail'),
    comparatorKind: asVocabulary(fields, 'comparator_kind', COMPARATOR_KINDS),
    comparatorDrugId: asOptionalUuid(fields, 'comparator_drug_id'),
    comparatorDetail: asOptionalText(fields, 'comparator_detail'),
    outcomeConceptId: asUuid(fields, 'outcome_concept_id'),
    outcomeDetail: asText(fields, 'outcome_detail'),
    timepointMin: asOptionalText(fields, 'timepoint_min'),
    timepointMax: asOptionalText(fields, 'timepoint_max'),
    timepointAvailability: asVocabulary(fields, 'timepoint_availability', VALUE_AVAILABILITIES),
    reportedDirection: asVocabulary(fields, 'reported_direction', REPORTED_DIRECTIONS),
    effectMeasure: asOptionalVocabulary(fields, 'effect_measure', EFFECT_MEASURES),
    estimate: asOptionalNumericText(fields, 'estimate'),
    estimateUnit: asOptionalVocabulary(fields, 'estimate_unit', ESTIMATE_UNITS),
    estimateAvailability: asVocabulary(fields, 'estimate_availability', VALUE_AVAILABILITIES),
    ciLower: asOptionalNumericText(fields, 'ci_lower'),
    ciUpper: asOptionalNumericText(fields, 'ci_upper'),
    ciLevelPercent: asOptionalNumericText(fields, 'ci_level_percent'),
    confidenceIntervalAvailability: asVocabulary(
      fields,
      'confidence_interval_availability',
      VALUE_AVAILABILITIES,
    ),
    limitationsText: asOptionalText(fields, 'limitations_text'),
    sourceLocator: asText(fields, 'source_locator'),
    sourceQuote: asOptionalText(fields, 'source_quote'),
  }
  rejectUnknown(fields)
  return extraction
}

/**
 * Leser og kontrollerer ett forslag.
 *
 * Kontrollen gjelder formen, ikke innholdet: at et felt finnes, har riktig type
 * og en verdi innenfor sitt vokabular — aldri at verdien er riktig. Om verdien
 * følger av kilden, avgjøres av den ordrette kontrollen mot representasjonen og
 * av mennesket etterpå.
 */
export function parseExtractionProposal(value: unknown): ExtractionProposal {
  const fields = fieldsOf(value, 'forslaget')

  const version = asText(fields, 'proposal_version')
  if (version !== EXTRACTION_PROPOSAL_VERSION) {
    problem(
      'forslaget.proposal_version',
      `er ${JSON.stringify(version)}, men denne kjøreren leser ${JSON.stringify(EXTRACTION_PROPOSAL_VERSION)}`,
    )
  }

  const sourceId = asUuid(fields, 'source_id')
  const sourceVersionId = asUuid(fields, 'source_version_id')
  const retrievedFrom = asText(fields, 'retrieved_from')
  const contentHash = asText(fields, 'content_hash')
  if (!CONTENT_HASH_PATTERN.test(contentHash)) {
    problem(
      'forslaget.content_hash',
      'har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn, som er den kildeversjonene er registrert med',
    )
  }

  const extraction = parseExtraction(raw(fields, 'extraction'))

  const groundings = raw(fields, 'field_groundings')
  if (!Array.isArray(groundings) || groundings.length === 0) {
    problem('field_groundings', 'mangler eller er tom')
  }
  rejectUnknown(fields)

  const parsed = groundings.map(parseGrounding)
  const seen = new Set<string>()
  for (const grounding of parsed) {
    if (seen.has(grounding.checkField)) {
      problem('field_groundings', `forankrer «${grounding.checkField}» mer enn én gang`)
    }
    seen.add(grounding.checkField)
  }

  return {
    proposalVersion: EXTRACTION_PROPOSAL_VERSION,
    sourceId,
    sourceVersionId,
    retrievedFrom,
    contentHash,
    extraction,
    fieldGroundings: parsed,
  }
}
