// ============================================================================
// Den maskinlesbare formen på et ekstraksjonsforslag
//
// `extraction-proposal.ts` er fasiten: den er koden som faktisk avviser et
// ugyldig forslag. Dette er den samme kontrakten uttrykt som JSON Schema, slik
// at den kan leveres til noen — et menneske, ChatGPT, eller en dag et innebygd
// modell-ledd — som skal *produsere* et forslag uten å lese TypeScript.
//
// Skjemaet bygges av de samme vokabularkonstantene som parseren bruker, og kan
// derfor ikke drive fra den. `proposals/extraction-proposal.schema.json` er den
// gjengitte filen, og `extraction-proposal-schema.test.ts` krever at den er
// identisk med det denne funksjonen bygger. Regenerer den med:
//
//   npm run agent:extract-evidence -- --schema > proposals/extraction-proposal.schema.json
//
// Skjemaet er en *nødvendig* betingelse, ikke en tilstrekkelig: det sier hvilke
// felter som finnes og hvilke verdier de kan ha. At utdragene faktisk står i
// kilden, avgjøres av den ordrette kontrollen i kjøringen og av den
// deterministiske ekstraksjonskontrollen etterpå — aldri av formen alene.
// ============================================================================

import {
  COMPARATOR_KINDS,
  EFFECT_MEASURES,
  ESTIMATE_UNITS,
  EVIDENCE_CHECK_FIELDS,
  REPORTED_DIRECTIONS,
  STUDY_DESIGNS,
  VALUE_AVAILABILITIES,
} from '../types/api.ts'
import { EXTRACTION_PROPOSAL_VERSION, MIN_SOURCE_EXCERPT_LENGTH } from './extraction-proposal.ts'

const UUID_PATTERN = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
const CONTENT_HASH_PATTERN = '^sha256:[0-9a-f]{64}$'

type Schema = Record<string, unknown>

function text(description: string): Schema {
  return { type: 'string', minLength: 1, description }
}

function optionalText(description: string): Schema {
  return { type: ['string', 'null'], description }
}

/** Et tall bevares som tekst, slik at skrivemåten i kilden ikke endres. */
function numericText(description: string): Schema {
  return { type: ['string', 'null'], description }
}

function vocabulary(values: readonly string[], description: string): Schema {
  return { type: 'string', enum: [...values], description }
}

function optionalVocabulary(values: readonly string[], description: string): Schema {
  return { type: ['string', 'null'], enum: [...values, null], description }
}

function uuid(description: string): Schema {
  return { type: 'string', pattern: UUID_PATTERN, description }
}

function optionalUuid(description: string): Schema {
  return { type: ['string', 'null'], pattern: UUID_PATTERN, description }
}

const EXTRACTION_PROPERTIES: Record<string, Schema> = {
  design_code: vocabulary(STUDY_DESIGNS, 'Studiedesignen funnet er hentet fra.'),
  population_id: optionalUuid(
    'Den registrerte populasjonen i catalog.populations, når en av dem passer. Utelates når ingen gjør det.',
  ),
  population_availability: vocabulary(
    VALUE_AVAILABILITIES,
    'Hvorfor population_id eventuelt mangler. En tom verdi skal aldri kunne leses som en nullverdi.',
  ),
  population_detail: text('Populasjonen slik kilden beskriver den, kort og på norsk.'),
  sample_size: {
    type: ['integer', 'null'],
    description: 'Antall deltakere, når kilden oppgir det.',
  },
  sample_size_availability: vocabulary(
    VALUE_AVAILABILITIES,
    'Hvorfor sample_size eventuelt mangler.',
  ),
  intervention_drug_id: uuid('Virkestoffet som ble gitt, fra catalog.drugs.'),
  intervention_detail: optionalText('Dose, form eller annen presisering av intervensjonsarmen.'),
  comparator_kind: vocabulary(
    COMPARATOR_KINDS,
    'Hva funnet sammenlignes mot. none betyr at det ikke finnes en komparator, ikke at den er ukjent.',
  ),
  comparator_drug_id: optionalUuid('Komparatorvirkestoffet, når comparator_kind er drug.'),
  comparator_detail: optionalText('Presisering av komparatorarmen.'),
  outcome_concept_id: uuid('Endepunktet, fra catalog.clinical_concepts.'),
  outcome_detail: text('Endepunktet slik kilden måler det, kort og på norsk.'),
  timepoint_min: optionalText(
    'Tidligste måletidspunkt, som PostgreSQL-intervall, for eksempel «56 days».',
  ),
  timepoint_max: optionalText('Seneste måletidspunkt, som PostgreSQL-intervall.'),
  timepoint_availability: vocabulary(
    VALUE_AVAILABILITIES,
    'Hvorfor tidspunktet eventuelt mangler.',
  ),
  reported_direction: vocabulary(
    REPORTED_DIRECTIONS,
    'Retningen kilden selv rapporterer. not_stated er noe annet enn no_clear_difference.',
  ),
  effect_measure: optionalVocabulary(
    EFFECT_MEASURES,
    'Effektmålet estimatet er uttrykt i. Et tall uten sitt mål er ikke tolkbart.',
  ),
  estimate: numericText('Estimatet, som tekst, ordrett slik kilden skriver det.'),
  estimate_unit: optionalVocabulary(
    ESTIMATE_UNITS,
    'Enheten. Påkrevd for mean_change og mean_difference, forbudt for de dimensjonsløse målene.',
  ),
  estimate_availability: vocabulary(VALUE_AVAILABILITIES, 'Hvorfor estimatet eventuelt mangler.'),
  ci_lower: numericText('Nedre konfidensgrense, som tekst.'),
  ci_upper: numericText('Øvre konfidensgrense, som tekst.'),
  ci_level_percent: numericText('Konfidensnivået i prosent, som tekst, for eksempel «95».'),
  confidence_interval_availability: vocabulary(
    VALUE_AVAILABILITIES,
    'Hvorfor konfidensintervallet eventuelt mangler.',
  ),
  limitations_text: optionalText('Forbehold kilden selv oppgir.'),
  source_locator: text(
    'Hvor i dokumentet funnet som helhet står, for eksempel «Results, avsnitt 2».',
  ),
  source_quote: optionalText(
    'Ett ordrett sitat for funnet som helhet. Forankringen per felt er field_groundings.',
  ),
}

const REQUIRED_EXTRACTION_FIELDS = [
  'design_code',
  'population_availability',
  'population_detail',
  'sample_size_availability',
  'intervention_drug_id',
  'comparator_kind',
  'outcome_concept_id',
  'outcome_detail',
  'timepoint_availability',
  'reported_direction',
  'estimate_availability',
  'confidence_interval_availability',
  'source_locator',
]

/** Bygger JSON Schema-formen av kontrakten, fra de samme konstantene parseren bruker. */
export function buildExtractionProposalSchema(): Schema {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'https://antidep.no/schema/extraction-proposal-1.json',
    title: 'Antidep ExtractionProposal',
    description:
      'Ett forslag om ett evidensfunn, lest ut av én bestemt kildeversjon. Forslaget skriver ingenting: det leses av npm run agent:extract-evidence, som henter kildeversjonen på nytt, krever at fingeravtrykket stemmer, og prøver hvert source_excerpt ordrett mot den før noe registreres. Ukjente felter avvises, og ingenting fylles inn automatisk.',
    type: 'object',
    additionalProperties: false,
    required: [
      'proposal_version',
      'source_id',
      'source_version_id',
      'retrieved_from',
      'content_hash',
      'extraction',
      'field_groundings',
    ],
    properties: {
      proposal_version: {
        const: EXTRACTION_PROPOSAL_VERSION,
        description: 'Versjonen av denne kontrakten. Et forslag med en annen verdi avvises.',
      },
      source_id: uuid('Kilden funnet er hentet fra, slik den er registrert i knowledge.sources.'),
      source_version_id: uuid(
        'Den eksakte kildeversjonen som ble lest. Ekstraksjonen bindes til nøyaktig denne utgaven.',
      ),
      retrieved_from: {
        type: 'string',
        minLength: 1,
        description:
          'Den tekniske henteadressen kildeversjonen ble registrert med. Ikke en menneskelig kildelenke: DOI og PubMed-id er det, og de står på kilden.',
      },
      content_hash: {
        type: 'string',
        pattern: CONTENT_HASH_PATTERN,
        description:
          'Fingeravtrykket kildeversjonen er registrert med. Kjøringen henter adressen på nytt og nekter å registrere noe dersom avtrykket ikke stemmer.',
      },
      extraction: {
        type: 'object',
        additionalProperties: false,
        description: 'De strukturerte verdiene forslaget påstår om studien.',
        required: REQUIRED_EXTRACTION_FIELDS,
        properties: EXTRACTION_PROPERTIES,
      },
      field_groundings: {
        type: 'array',
        minItems: 1,
        description:
          'Én forankring per semantisk felt raden påstår noe om. Databasen avviser en ekstraksjon som ikke forankrer dem alle, og ingen forankring fylles inn automatisk. Forankringen er en del av evidensfunnets identitet: et forslag med de samme strukturerte verdiene, men et rettet utdrag, en rettet peker eller en rettet begrunnelse, registreres som et nytt funn ved siden av det gamle og må kontrolleres på nytt. Rekkefølgen i listen betyr ingenting.',
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['check_field', 'source_excerpt', 'source_locator', 'justification'],
          properties: {
            check_field: vocabulary(
              EVIDENCE_CHECK_FIELDS,
              'Hvilket kontrollfelt forankringen gjelder. Hvert felt kan forankres én gang.',
            ),
            source_excerpt: {
              type: 'string',
              minLength: MIN_SOURCE_EXCERPT_LENGTH,
              description:
                'Det ordrette kildeutdraget, med nok kontekst til å være kontrollgrunnlag. Må stå ordrett i kildeversjonen; kjøringen prøver det.',
            },
            source_locator: text(
              'Den presise pekeren for nettopp dette utdraget, for eksempel «Results, tabell 2».',
            ),
            justification: text(
              'Kort og eksplisitt: hvordan utdraget ble til den strukturerte verdien. Ikke en tankerekke.',
            ),
          },
        },
      },
    },
  }
}
