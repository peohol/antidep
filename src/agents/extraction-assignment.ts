// ============================================================================
// Oppdraget: det modell-leddet får vite som ikke står i artikkelen
//
// Et ekstraksjonsforslag inneholder fire opplysninger som ikke kan leses ut av
// teksten — `source_id`, `source_version_id`, `retrieved_from` og
// `content_hash` — og tre lister med identifikatorer fra katalogen som en
// modell umulig kan kjenne: virkestoffene, endepunktene og populasjonene raden
// kan peke på. Oppdraget er nøyaktig de opplysningene, samlet i én fil.
//
// ----------------------------------------------------------------------------
// Hvorfor de kommer fra en fil og ikke fra databasen
//
// Modell-leddet har ingen databasetilgang, og skal ikke ha det: det leser
// utrygt eksternt innhold, og en agent som gjør det, skal ikke samtidig ha
// tilgang til noe den ikke trenger (EVIDENCE_PIPELINE.md §63). Å la leddet slå
// opp katalogen selv ville gitt det en leseflate inn i Antidep for å slippe å
// skrive en fil.
//
// Filen lages av en kvalifisert redaktør, som *har* leseflaten: verdiene står i
// `api.editor_source_versions`, `api.editor_drugs`, `api.editor_outcomes` og
// `api.editor_populations`. Se `assignments/README.md`.
//
// ----------------------------------------------------------------------------
// Hvorfor katalogen er en lukket liste og ikke et fritt søk
//
// Hvilket virkestoff og hvilket endepunkt et evidensfunn gjelder, er en faglig
// avgrensning. En modell som fikk velge fritt blant alt i katalogen, ville
// kunnet flytte funnet til et naboendepunkt uten at noe i kjeden merket det:
// utdragene ville fortsatt stått ordrett i kilden, og den deterministiske
// kontrollen kontrollerer utdrag, ikke avgrensning.
//
// Listen er derfor redaktørens avgrensning, og modellen velger innenfor den.
// Kjøringen håndhever det etterpå: en id som ikke står i oppdraget, avvises
// (`drafting-run.ts`).
//
// Navnene ved siden av id-ene er for modellens skyld — en uuid alene sier ikke
// hvilket virkestoff det er — og brukes aldri som nøkkel. Det er id-en som
// registreres.
//
// Utrygg inndata: oppdraget er data, aldri instruksjoner (CLAUDE.md).
// ============================================================================

import type { Uuid } from '../types/api.ts'
import type { ExtractionProposal, ProposedExtraction } from './extraction-proposal.ts'
import {
  asObjectList,
  asOptionalObjectList,
  asText,
  asUuid,
  fieldsOf,
  nestedFields,
  problem,
  rejectUnknown,
  type Fields,
} from './strict-fields.ts'

const ASSIGNMENT_SUBJECT = 'Oppdraget'

/**
 * Versjonen av oppdragsformen, oppgitt i hver fil.
 *
 * Samme begrunnelse som `EXTRACTION_PROPOSAL_VERSION`: uten den kan en fil
 * skrevet mot en eldre form ikke skilles fra en fil med et manglende felt.
 */
export const EXTRACTION_ASSIGNMENT_VERSION = 'antidep/extraction-assignment@1'

/** Ett valg i katalogen, med id-en som registreres og navnet modellen leser. */
export interface CatalogChoice {
  readonly id: Uuid
  readonly label: string
}

export interface ExtractionAssignment {
  readonly assignmentVersion: typeof EXTRACTION_ASSIGNMENT_VERSION
  readonly sourceId: Uuid
  readonly sourceVersionId: Uuid
  readonly retrievedFrom: string
  readonly contentHash: string
  /** Virkestoffene funnet kan gjelde. Minst ett; ellers er det ikke et oppdrag. */
  readonly drugs: readonly CatalogChoice[]
  /** Endepunktene funnet kan gjelde. Minst ett. */
  readonly outcomes: readonly CatalogChoice[]
  /**
   * Populasjonene funnet kan peke på.
   *
   * Kan være tom, og det er en reell tilstand og ikke et hull: passer ingen
   * registrert populasjon, skal `population_availability` si hvorfor framfor at
   * en nesten-riktig populasjon velges (ANTIDEP_CONSTITUTION.md §6).
   */
  readonly populations: readonly CatalogChoice[]
}

const CONTENT_HASH_PATTERN = /^sha256:[0-9a-f]{64}$/

function parseChoice(parent: Fields, value: unknown, where: string, idKey: string): CatalogChoice {
  const fields = nestedFields(parent, value, where)
  const choice: CatalogChoice = {
    id: asUuid(fields, idKey),
    label: asText(fields, 'label'),
  }
  rejectUnknown(fields)
  return choice
}

function parseChoices(
  fields: Fields,
  key: string,
  idKey: string,
  entries: readonly unknown[],
): readonly CatalogChoice[] {
  const choices = entries.map((value, index) =>
    parseChoice(fields, value, `${key}[${String(index)}]`, idKey),
  )
  const seen = new Set<string>()
  for (const choice of choices) {
    if (seen.has(choice.id)) {
      problem(fields.subject, key, `fører ${choice.id} mer enn én gang`)
    }
    seen.add(choice.id)
  }
  return choices
}

/** Leser og kontrollerer ett oppdrag, eller sier hvilket felt som er galt. */
export function parseExtractionAssignment(value: unknown): ExtractionAssignment {
  const fields = fieldsOf(value, ASSIGNMENT_SUBJECT, 'oppdraget')

  const version = asText(fields, 'assignment_version')
  if (version !== EXTRACTION_ASSIGNMENT_VERSION) {
    problem(
      ASSIGNMENT_SUBJECT,
      'oppdraget.assignment_version',
      `er ${JSON.stringify(version)}, men denne kjøreren leser ${JSON.stringify(EXTRACTION_ASSIGNMENT_VERSION)}`,
    )
  }

  const sourceId = asUuid(fields, 'source_id')
  const sourceVersionId = asUuid(fields, 'source_version_id')
  const retrievedFrom = asText(fields, 'retrieved_from')
  const contentHash = asText(fields, 'content_hash')
  if (!CONTENT_HASH_PATTERN.test(contentHash)) {
    problem(
      ASSIGNMENT_SUBJECT,
      'oppdraget.content_hash',
      'har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn, som er den kildeversjonene er registrert med',
    )
  }

  const drugEntries = asObjectList(fields, 'drugs')
  const outcomeEntries = asObjectList(fields, 'outcomes')
  const populationEntries = asOptionalObjectList(fields, 'populations')
  rejectUnknown(fields)

  return {
    assignmentVersion: EXTRACTION_ASSIGNMENT_VERSION,
    sourceId,
    sourceVersionId,
    retrievedFrom,
    contentHash,
    drugs: parseChoices(fields, 'drugs', 'drug_id', drugEntries),
    outcomes: parseChoices(fields, 'outcomes', 'outcome_concept_id', outcomeEntries),
    populations: parseChoices(fields, 'populations', 'population_id', populationEntries),
  }
}

/** Leser oppdraget fra en fil, og navngir filen når den ikke er gyldig JSON. */
export function parseAssignmentJson(path: string, text: string): ExtractionAssignment {
  let json: unknown
  try {
    json = JSON.parse(text) as unknown
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`${path} er ikke gyldig JSON: ${message}`, { cause })
  }
  try {
    return parseExtractionAssignment(json)
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`${path}: ${message}`, { cause })
  }
}

// ----------------------------------------------------------------------------
// Kontrollen av at et forslag holder seg innenfor oppdraget
//
// Avgrensningen er den ene tingen den ordrette kontrollen *ikke* kan fange. Et
// utdrag kan stå ordrett i kilden og likevel være ført på feil virkestoff eller
// et naboendepunkt; teksten ville vært like sann, og raden like gal.
//
// Kontrollen kjøres derfor to steder, og det er med hensikt:
//
//   * i modell-leddet, før et forslag i det hele tatt blir en fil, og
//   * i registreringen, mot oppdragsfilen redaktøren eier.
//
// Den andre er ikke en gjentakelse av den første. Mellom dem ligger en
// overlevering — en fil som har vært innom en økt som leste utrygt eksternt
// innhold — og en kontroll som bare kjørte *før* den overleveringen, er ingen
// kontroll av det som faktisk blir registrert (EVIDENCE_PIPELINE.md §63).
// ----------------------------------------------------------------------------

/** Katalogkontrollen: bare id-ene oppdraget faktisk åpnet for. */
export function catalogProblem(
  assignment: ExtractionAssignment,
  extraction: ProposedExtraction,
): string | null {
  const known = (choices: readonly CatalogChoice[], id: string): boolean =>
    choices.some((choice) => choice.id === id)

  if (!known(assignment.drugs, extraction.interventionDrugId)) {
    return `intervention_drug_id ${extraction.interventionDrugId} står ikke blant virkestoffene i oppdraget`
  }
  if (
    extraction.comparatorDrugId !== null &&
    !known(assignment.drugs, extraction.comparatorDrugId)
  ) {
    return `comparator_drug_id ${extraction.comparatorDrugId} står ikke blant virkestoffene i oppdraget`
  }
  if (!known(assignment.outcomes, extraction.outcomeConceptId)) {
    return `outcome_concept_id ${extraction.outcomeConceptId} står ikke blant endepunktene i oppdraget`
  }
  if (extraction.populationId !== null && !known(assignment.populations, extraction.populationId)) {
    return `population_id ${extraction.populationId} står ikke blant populasjonene i oppdraget`
  }
  return null
}

/**
 * Om et forslag holder seg innenfor oppdraget det skal ha vært laget under.
 *
 * Kontrollerer både kildebindingen og katalogen. Kildebindingen først: et
 * forslag som peker på en annen kildeversjon enn oppdraget, er ikke det
 * oppdraget ba om, uansett hvor riktige verdiene måtte være.
 *
 * Returnerer `null` når alt stemmer, ellers én setning som sier hva som ikke
 * gjorde det.
 */
export function assignmentMismatch(
  assignment: ExtractionAssignment,
  proposal: ExtractionProposal,
): string | null {
  const binding: readonly (readonly [string, string, string])[] = [
    ['source_id', proposal.sourceId, assignment.sourceId],
    ['source_version_id', proposal.sourceVersionId, assignment.sourceVersionId],
    ['retrieved_from', proposal.retrievedFrom, assignment.retrievedFrom],
    ['content_hash', proposal.contentHash, assignment.contentHash],
  ]
  for (const [key, proposed, expected] of binding) {
    if (proposed !== expected) {
      return `${key} er ${proposed} i forslaget, men ${expected} i oppdraget`
    }
  }
  return catalogProblem(assignment, proposal.extraction)
}
