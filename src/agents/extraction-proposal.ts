// ============================================================================
// Ekstraksjonsforslaget: det ett agentledd foreslår om én studie
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
// språkmodell, og dermed en leverandør og en konto — en beslutning som ikke er
// teknisk (issue #63). Alt det andre i kjeden er deterministisk og skal ikke
// vente på den: hentingen, den ordrette kontrollen av hvert utdrag, kjøringens
// proveniens og selve registreringen.
//
// Forslaget er derfor grenseflaten mellom de to. Et modell-ledd som skriver
// denne formen, kan kobles på uten at noe annet i kjeden endres — og formen
// kontrolleres like strengt uansett hvem som skrev den.
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
// Ingen verdi *utledes* her, og ingen mangel fylles inn: et forslag uten en
// verdi er et forslag uten den verdien (ANTIDEP_CONSTITUTION.md §6).
// ============================================================================

import type { Uuid } from '../types/api.ts'

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

/** Hele forslaget: hvilken kilde, hvilken versjon, verdiene og forankringen. */
export interface ExtractionProposal {
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

function problem(where: string, what: string): never {
  throw new Error(`Ekstraksjonsforslaget er ugyldig: ${where} ${what}.`)
}

function asRecord(value: unknown, where: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    problem(where, 'er ikke et objekt')
  }
  return value as Record<string, unknown>
}

function asText(record: Record<string, unknown>, key: string, where: string): string {
  const value = record[key]
  if (typeof value !== 'string' || value.trim().length === 0) {
    problem(`${where}.${key}`, 'mangler eller er tom')
  }
  return value
}

function asOptionalText(
  record: Record<string, unknown>,
  key: string,
  where: string,
): string | null {
  const value = record[key]
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'string') {
    problem(`${where}.${key}`, 'er ikke tekst')
  }
  const trimmed = value.trim()
  return trimmed.length === 0 ? null : value
}

function asOptionalInteger(
  record: Record<string, unknown>,
  key: string,
  where: string,
): number | null {
  const value = record[key]
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    problem(`${where}.${key}`, 'er ikke et heltall')
  }
  return value
}

/**
 * Et tall bevares som tekst, ordrett slik forslaget skrev det.
 *
 * `1.50` og `1.5` er samme tall, men ikke samme oppgitte verdi, og en tur
 * innom `Number` ville stille endret det som skal kontrolleres mot kilden.
 */
function asOptionalNumericText(
  record: Record<string, unknown>,
  key: string,
  where: string,
): string | null {
  const value = record[key]
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value === 'number') {
    problem(
      `${where}.${key}`,
      'er oppgitt som et tall. Tallverdier skal stå som tekst, slik at skrivemåten bevares ordrett',
    )
  }
  if (typeof value !== 'string' || value.trim().length === 0) {
    problem(`${where}.${key}`, 'er ikke et tall som tekst')
  }
  return value
}

function parseGrounding(value: unknown, index: number): ProposedGrounding {
  const where = `field_groundings[${String(index)}]`
  const record = asRecord(value, where)
  return {
    checkField: asText(record, 'check_field', where),
    sourceExcerpt: asText(record, 'source_excerpt', where),
    sourceLocator: asText(record, 'source_locator', where),
    justification: asText(record, 'justification', where),
  }
}

function parseExtraction(value: unknown): ProposedExtraction {
  const where = 'extraction'
  const record = asRecord(value, where)
  return {
    designCode: asText(record, 'design_code', where),
    populationId: asOptionalText(record, 'population_id', where) as Uuid | null,
    populationAvailability: asText(record, 'population_availability', where),
    populationDetail: asText(record, 'population_detail', where),
    sampleSize: asOptionalInteger(record, 'sample_size', where),
    sampleSizeAvailability: asText(record, 'sample_size_availability', where),
    interventionDrugId: asText(record, 'intervention_drug_id', where) as Uuid,
    interventionDetail: asOptionalText(record, 'intervention_detail', where),
    comparatorKind: asText(record, 'comparator_kind', where),
    comparatorDrugId: asOptionalText(record, 'comparator_drug_id', where) as Uuid | null,
    comparatorDetail: asOptionalText(record, 'comparator_detail', where),
    outcomeConceptId: asText(record, 'outcome_concept_id', where) as Uuid,
    outcomeDetail: asText(record, 'outcome_detail', where),
    timepointMin: asOptionalText(record, 'timepoint_min', where),
    timepointMax: asOptionalText(record, 'timepoint_max', where),
    timepointAvailability: asText(record, 'timepoint_availability', where),
    reportedDirection: asText(record, 'reported_direction', where),
    effectMeasure: asOptionalText(record, 'effect_measure', where),
    estimate: asOptionalNumericText(record, 'estimate', where),
    estimateUnit: asOptionalText(record, 'estimate_unit', where),
    estimateAvailability: asText(record, 'estimate_availability', where),
    ciLower: asOptionalNumericText(record, 'ci_lower', where),
    ciUpper: asOptionalNumericText(record, 'ci_upper', where),
    ciLevelPercent: asOptionalNumericText(record, 'ci_level_percent', where),
    confidenceIntervalAvailability: asText(record, 'confidence_interval_availability', where),
    limitationsText: asOptionalText(record, 'limitations_text', where),
    sourceLocator: asText(record, 'source_locator', where),
    sourceQuote: asOptionalText(record, 'source_quote', where),
  }
}

/**
 * Leser og kontrollerer ett forslag.
 *
 * Kontrollen gjelder formen, ikke innholdet: at et felt finnes og har riktig
 * type, aldri at verdien er riktig. Om verdien følger av kilden, avgjøres av
 * den ordrette kontrollen og av mennesket etterpå.
 */
export function parseExtractionProposal(value: unknown): ExtractionProposal {
  const record = asRecord(value, 'forslaget')
  const groundings = record['field_groundings']
  if (!Array.isArray(groundings) || groundings.length === 0) {
    problem('field_groundings', 'mangler eller er tom')
  }

  const parsed = groundings.map(parseGrounding)
  const seen = new Set<string>()
  for (const grounding of parsed) {
    if (seen.has(grounding.checkField)) {
      problem('field_groundings', `forankrer «${grounding.checkField}» mer enn én gang`)
    }
    seen.add(grounding.checkField)
  }

  return {
    sourceId: asText(record, 'source_id', 'forslaget') as Uuid,
    sourceVersionId: asText(record, 'source_version_id', 'forslaget') as Uuid,
    retrievedFrom: asText(record, 'retrieved_from', 'forslaget'),
    contentHash: asText(record, 'content_hash', 'forslaget'),
    extraction: parseExtraction(record['extraction']),
    fieldGroundings: parsed,
  }
}
