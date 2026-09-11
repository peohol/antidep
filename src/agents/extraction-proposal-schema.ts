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
import { EXTRACTION_PROPOSAL_VERSION, PROPOSAL_PRODUCERS } from './extraction-proposal.ts'
import { MIN_SOURCE_EXCERPT_LENGTH } from './source-excerpt.ts'

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
    description:
      'Antall observasjoner estimatet faktisk bygger på, når kilden uttrykkelig knytter tallet til nettopp dette estimatet. Ikke antallet randomisert i studien, og aldri utledet av en nærliggende tabell eller av et annet antall. Uten en slik passasje utelates verdien, og sample_size_availability sier hvorfor.',
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

/**
 * De to delene et modell-ledd faktisk produserer.
 *
 * Skilt ut fordi de er nøyaktig det `parseExtractionDraft` leser, og fordi de
 * er det promptmalen legger ved som formkrav (`extraction-prompt.ts`). Ett
 * uttrykk, brukt av begge skjemaene: en modell som fikk en litt annen form enn
 * den kjøringen krever, ville produsert utkast som ikke lot seg registrere.
 */
const DRAFT_PROPERTIES: Record<string, Schema> = {
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
            'Det ordrette, sammenhengende kildeutdraget verdien er lest ut av. Normalt minst én hel setning, og aldri et utsnitt som begynner eller slutter midt i et ord. Det skal være langt nok til at en kontrollør kan se hva opplysningen gjelder — hvilken behandlingsarm, hvilken populasjon, hvilket tidspunkt og hva et tall er en verdi av — uten å åpne artikkelen. Gir én setning ikke det, tas den nærmeste tilstøtende setningen med. Målet er den minste SAMMENHENGENDE teksten som er tilstrekkelig for menneskelig kontroll, ikke den minste strengen maskinen kan gjenfinne. Må stå ordrett i kildeversjonen; kjøringen prøver det.',
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
}

const DRAFT_REQUIRED = ['extraction', 'field_groundings']

/**
 * Formen et modell-ledd skal svare med.
 *
 * Kildebindingen er ikke med: den er oppdragets og settes av kjøringen. Å be en
 * modell om å gjenta `source_version_id` og `content_hash` ville vært å be den
 * om en opplysning den ikke kan kontrollere, og gitt den en måte å binde
 * ekstraksjonen til feil utgave på.
 */
export function buildExtractionDraftSchema(): Schema {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'https://antidep.no/schema/extraction-draft-1.json',
    title: 'Antidep ExtractionDraft',
    description:
      'De strukturerte verdiene for ett evidensfunn, lest ut av én representasjon, med én ordrett kildeforankring per semantisk felt. Utkastet skriver ingenting: det blir et ExtractionProposal først når kjøringen har lagt kildebindingen på det, og en ekstraksjon først når det er registrert under de deterministiske kontrollene.',
    type: 'object',
    additionalProperties: false,
    required: DRAFT_REQUIRED,
    properties: DRAFT_PROPERTIES,
  }
}

/** Bygger JSON Schema-formen av kontrakten, fra de samme konstantene parseren bruker. */
export function buildExtractionProposalSchema(): Schema {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'https://antidep.no/schema/extraction-proposal-3.json',
    title: 'Antidep ExtractionProposal',
    description:
      'Ett forslag om ett evidensfunn, lest ut av én bestemt kildeversjon. Forslaget skriver ingenting: det leses av npm run agent:extract-evidence, som henter kildeversjonen på nytt, krever at fingeravtrykket stemmer, og prøver hvert source_excerpt ordrett mot den før noe registreres. Ukjente felter avvises, og ingenting fylles inn automatisk.',
    type: 'object',
    additionalProperties: false,
    required: [
      'proposal_version',
      'generated_by',
      'source_id',
      'source_version_id',
      'retrieved_from',
      'content_hash',
      'document',
      ...DRAFT_REQUIRED,
    ],
    properties: {
      proposal_version: {
        const: EXTRACTION_PROPOSAL_VERSION,
        description: 'Versjonen av denne kontrakten. Et forslag med en annen verdi avvises.',
      },
      generated_by: {
        type: 'object',
        additionalProperties: false,
        description:
          'Hvem som leste kilden og foreslo verdiene. Registreres som premissene for agentkjøringen som skriver raden, og avgjør om funnet føres som et KI-assistert forslag eller som en menneskelig ekstraksjon. Pipelineversjonen hører ikke hjemme her: den er Antideps egen og settes av kjøringen.',
        required: [
          'producer',
          'provider',
          'model',
          'model_version',
          'prompt_template_version',
          'drafted_at',
        ],
        properties: {
          producer: vocabulary(
            PROPOSAL_PRODUCERS,
            'model når en språkmodell leste kilden, human når et menneske gjorde det. Verdien avgjør knowledge.evidence_items.extraction_method, og skal si hva som faktisk skjedde.',
          ),
          provider: text(
            'Leverandøren av modellen, for eksempel openai. For et menneskeskrevet forslag: human.',
          ),
          model: text(
            'Modellen som svarte, eller for et menneskeskrevet forslag en kort beskrivelse av arbeidsformen, for eksempel manuell-ekstraksjon.',
          ),
          model_version: text(
            'Modellversjonen, så presist leverandøren oppgir den. For et menneskeskrevet forslag: not_applicable.',
          ),
          prompt_template_version: text(
            'Versjonen av promptmalen forslaget ble laget med. For et menneskeskrevet forslag: not_applicable.',
          ),
          drafted_at: text(
            'Da utkastet ble laget, med tidssone, for eksempel 2026-09-15T09:00:00Z. Ikke da det ble registrert: de to er forskjellige operasjoner på forskjellige tidspunkter.',
          ),
          request_digest: {
            type: ['string', 'null'],
            pattern: CONTENT_HASH_PATTERN,
            description:
              'Fingeravtrykket av forespørselen modellen svarte på. Dekker representasjonen, katalogen i oppdraget og promptmalen, og er det som gjør modellkjøringen identifiserbar i ettertid. Utelates for et menneskeskrevet forslag.',
          },
        },
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
          'Fingeravtrykket kildeversjonen er registrert med. Kjøringen skaffer representasjonen på nytt og nekter å registrere noe dersom avtrykket ikke stemmer.',
      },
      document: {
        type: ['object', 'null'],
        additionalProperties: false,
        description:
          'Originaldokumentet kildeversjonen er utledet av, når den er det — i praksis PDF-en av en fulltekstartikkel. null betyr at representasjonen er teksten som lå på retrieved_from. Verdien er oppdragets, ikke modellens: den avgjør hvordan kjeden skaffer teksten på nytt, og et forslag som oppga noe annet enn oppdraget, ville pekt kontrollen mot et annet dokument enn ekstraksjonen ble lest av.',
        required: ['sha256', 'byte_size', 'media_type', 'text_extraction'],
        properties: {
          sha256: {
            type: 'string',
            pattern: CONTENT_HASH_PATTERN,
            description:
              'sha256 av originaldokumentets byte, beregnet av databasen. Kan reproduseres med sha256sum på filen.',
          },
          byte_size: {
            type: 'integer',
            minimum: 1,
            description: 'Antall byte i originaldokumentet.',
          },
          media_type: text(
            'Hva slags dokument originalen er, avlest av dokumentets egen signatur. I dag application/pdf.',
          ),
          text_extraction: {
            type: 'object',
            additionalProperties: false,
            description:
              'Oppskriften teksten ble hentet ut med. Kjør den på dokumentet med sha256 over, og sha256 av resultatet skal være content_hash.',
            required: ['tool', 'tool_version', 'arguments'],
            properties: {
              tool: text('Verktøyet, for eksempel pdftotext.'),
              tool_version: text('Versjonen verktøyet selv oppgir.'),
              arguments: text('Argumentene verktøyet ble kjørt med, ordrett.'),
            },
          },
        },
      },
      ...DRAFT_PROPERTIES,
    },
  }
}
