// ============================================================================
// Svarstrukturene den eksterne agent-handoffen ber om, som JSON Schema
//
// Ekstraksjonsutkastet har allerede sin form (`extraction-proposal-schema.ts`),
// bygget av de samme konstantene parseren håndhever. Denne filen gjør det samme
// for de to andre semantiske leddene, av nøyaktig de samme vokabularene
// `parseProposedClaimRevision` og `parseProposedAssessment` bruker.
//
// Skjemaene legges ved oppgavefilen framfor en prosaisk feltliste. En
// beskrivelse i ord ville vært en andre kilde til sannhet, og den ville blitt
// utdatert stille — mens et skjema bygget av de samme konstantene ikke kan komme
// i utakt med det som faktisk godtas.
//
// ----------------------------------------------------------------------------
// Hva skjemaene IKKE ber om
//
// Avgrensningen. Hvilken kildeversjon, hvilket tema, hvilket virkestoff og
// hvilke evidensfunn oppgaven gjelder, står i oppgaven og settes av databasen.
// En modell som kunne oppgitt dem, kunne oppgitt feil uten at noe i kjeden
// merket det — akkurat som en modell som kunne oppgitt kildebindingen i et
// ekstraksjonsutkast (`extraction-prompt.ts`).
// ============================================================================

import {
  CERTAINTY_LEVELS,
  CLAIM_DIRECTIONS,
  COMPARATOR_KINDS,
  EFFECT_MEASURES,
  ESTIMATE_UNITS,
  EVIDENCE_DIRECTNESS_VALUES,
  EVIDENCE_RELATIONSHIP_TYPES,
  GRADE_DOMAIN_RATINGS,
} from '../types/api.ts'
import { ASSESSMENT_FRAMEWORKS } from './evidence-assessment-proposal.ts'

type Schema = Record<string, unknown>

const UUID_PATTERN = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

function text(description: string): Schema {
  return { type: 'string', minLength: 1, description }
}

function optionalText(description: string): Schema {
  return { type: ['string', 'null'], description }
}

function vocabulary(values: readonly string[], description: string): Schema {
  return { type: 'string', enum: [...values], description }
}

function optionalVocabulary(values: readonly string[], description: string): Schema {
  return { type: ['string', 'null'], enum: [...values, null], description }
}

/** Formen et synteseutkast skal ha. */
export function buildClaimSynthesisDraftSchema(): Schema {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'https://antidep.no/schema/claim-synthesis-draft-1.json',
    title: 'Antidep ClaimSynthesisDraft',
    description:
      'Én påstandsformulering med sitt evidensgrunnlag, foreslått av de evidensfunnene oppgaven avgrenser. Utkastet skriver ingenting: det blir en revisjon først når Antidep har registrert det under de deterministiske kontrollene, og publisert innhold først etter en uavhengig kildestøttekontroll, en uavhengig evidensvurdering og en navngitt fagpersons sluttkontroll.',
    type: 'object',
    additionalProperties: false,
    required: ['claim', 'evidence_links'],
    properties: {
      claim: {
        type: 'object',
        additionalProperties: false,
        required: ['statement', 'scope', 'comparator_kind', 'uncertainty_summary'],
        description:
          'Selve formuleringen. Tema, virkestoff og påstandsidentitet står i oppgaven og hører ikke hjemme her.',
        properties: {
          statement: text(
            'Påstanden i én setning på norsk bokmål, klinisk presis og uten anbefaling.',
          ),
          scope: text('Hva påstanden gjelder og ikke gjelder, kort.'),
          population_id: {
            type: ['string', 'null'],
            pattern: UUID_PATTERN,
            description:
              'Populasjonen påstanden gjelder, valgt blant dem oppgaven lister. Utelat når ingen passer.',
          },
          timeframe_min: optionalText(
            'Nedre ende av tidsrommet, som «8 weeks». Står sammen med timeframe_max, eller ingen av dem.',
          ),
          timeframe_max: optionalText('Øvre ende av tidsrommet, som «8 weeks».'),
          comparator_kind: vocabulary(
            COMPARATOR_KINDS,
            'Hva påstanden sammenligner med: et virkestoff, placebo, eller ingenting.',
          ),
          comparator_drug_id: {
            type: ['string', 'null'],
            pattern: UUID_PATTERN,
            description: 'Komparatorvirkestoffet, når comparator_kind er «drug».',
          },
          direction: optionalVocabulary(
            CLAIM_DIRECTIONS,
            'Retningen påstanden angir. Utelat når grunnlaget ikke gir en retning.',
          ),
          magnitude_measure: optionalVocabulary(
            EFFECT_MEASURES,
            'Effektmålet størrelsen er uttrykt i. Bevar det målet kildene faktisk brukte.',
          ),
          magnitude_value: {
            type: ['string', 'null'],
            description:
              'Størrelsen som tekst, med nøyaktig den skrivemåten grunnlaget bruker. 1.50 og 1.5 er samme tall, men ikke samme oppgitte verdi.',
          },
          magnitude_unit: optionalVocabulary(ESTIMATE_UNITS, 'Enheten størrelsen er uttrykt i.'),
          qualifiers: optionalText('Forbehold som hører til påstanden, kort.'),
          uncertainty_summary: text(
            'Hva som er usikkert i grunnlaget, i klartekst. Alltid påkrevd: en evidenssyntese uten usikkerhetstekst mangler halve påstanden.',
          ),
        },
      },
      evidence_links: {
        type: 'array',
        minItems: 1,
        description:
          'Hvordan hvert evidensfunn i oppgaven forholder seg til påstanden. Ett funn kan stå nøyaktig én gang, og bare funn oppgaven lister, kan brukes.',
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['evidence_item_id', 'relationship_type', 'directness', 'relevance_note'],
          properties: {
            evidence_item_id: {
              type: 'string',
              pattern: UUID_PATTERN,
              description: 'Evidensfunnet, valgt blant dem oppgaven lister.',
            },
            relationship_type: vocabulary(
              EVIDENCE_RELATIONSHIP_TYPES,
              'Hvordan funnet forholder seg til påstanden. Et funn som motsier, skal føres som contradicts.',
            ),
            directness: vocabulary(
              EVIDENCE_DIRECTNESS_VALUES,
              'Om funnet treffer påstandens populasjon, endepunkt, komparator og tidsrom direkte.',
            ),
            relevance_note: text(
              'Hvorfor nettopp dette funnet har nettopp denne relasjonen til nettopp denne formuleringen. Alltid påkrevd.',
            ),
          },
        },
      },
    },
  }
}

/** Formen et evidensvurderingsutkast skal ha. */
export function buildEvidenceAssessmentDraftSchema(): Schema {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'https://antidep.no/schema/evidence-assessment-draft-1.json',
    title: 'Antidep EvidenceAssessmentDraft',
    description:
      'GRADE-vurderingen av kunnskapsgrunnlaget bak én påstandsrevisjon. Vurderingen gjelder nøyaktig det evidenssettet oppgaven viser; hvilken revisjon og hvilket sett det er, står i oppgaven og hører ikke hjemme i svaret.',
    type: 'object',
    additionalProperties: false,
    required: ['assessment'],
    properties: {
      assessment: {
        type: 'object',
        additionalProperties: false,
        required: ['framework', 'certainty_level', 'rationale'],
        properties: {
          framework: vocabulary(ASSESSMENT_FRAMEWORKS, 'Rammeverket vurderingen er gjort i.'),
          certainty_level: vocabulary(
            CERTAINTY_LEVELS,
            'Sikkerheten i grunnlaget. «no_assessable_evidence» er en vurdert tilstand og ikke en femte grad: den betyr at grunnlaget ikke lar seg gradere, og da skal evidence_gap si hva som mangler.',
          ),
          risk_of_bias: optionalVocabulary(
            GRADE_DOMAIN_RATINGS,
            'Risiko for systematisk skjevhet. Utelates bare når certainty_level er «no_assessable_evidence».',
          ),
          inconsistency: optionalVocabulary(GRADE_DOMAIN_RATINGS, 'Inkonsistens mellom funnene.'),
          indirectness: optionalVocabulary(
            GRADE_DOMAIN_RATINGS,
            'Indirekthet mot påstandens populasjon, endepunkt, komparator og tidsrom.',
          ),
          imprecision: optionalVocabulary(GRADE_DOMAIN_RATINGS, 'Upresishet i estimatene.'),
          publication_bias: optionalVocabulary(GRADE_DOMAIN_RATINGS, 'Publikasjonsskjevhet.'),
          other_considerations: optionalText('Andre forhold som påvirket graderingen.'),
          rationale: text(
            'Hvorfor grunnlaget fikk nettopp denne sikkerheten, kort og klinisk presist på norsk bokmål.',
          ),
          evidence_gap: optionalText(
            'Hva som mangler i grunnlaget. Påkrevd når certainty_level er «no_assessable_evidence».',
          ),
        },
      },
    },
  }
}
