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
import { SEARCH_REQUEST_METHODS, SEARCH_REQUEST_PLATFORMS } from '../ops/search-method-catalog.ts'
import { ASSESSMENT_FRAMEWORKS } from './evidence-assessment-proposal.ts'
import {
  ACCESS_LIMITED_DECISIONS,
  CANDIDATE_DECISIONS,
  narrowableReferences,
  type AppraisableCandidate,
  type DiscoveryAnswerBounds,
  type NarrowableRound,
} from './discovery-answer-bounds.ts'

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

// ----------------------------------------------------------------------------
// Kildeoppdagelsen og kontrollen av søkedekningen
//
// Fra migrasjon 013v er formen en annen, og forskjellen er hele arbeidsdelingen:
// søkene er utført av Antideps egen kode og ligger i oppgaven med endepunkt og
// responsavtrykk. Leddet vurderer dem. Det rapporterer ikke søk, og det legger
// ikke til kandidatkilder — en kilde uten en oppdagelsesvei er ikke funnet av
// noe søk (SOURCE_POLICY.md §4.3).
//
// `searches` finnes derfor ikke lenger i noen av de to svarformene, og et svar
// som fortsatt bærer feltet, avvises av både flaten og databasen med en setning
// som sier hvorfor. Trengs det flere søk, ber leddet om dem: `search_requests`
// er den ene veien fra en semantisk vurdering til et nytt maskinelt søk.
// ----------------------------------------------------------------------------

export { SEARCH_OUTCOMES } from './search-outcomes.ts'

export { CANDIDATE_DECISIONS, CANDIDATE_IDENTIFIER_KINDS } from './discovery-answer-bounds.ts'

/**
 * Plattformene og metodene en søkeforespørsel kan navngi.
 *
 * Utledet av katalogen over søkemetodene, som speiler registeret i databasen
 * (`knowledge.monograph_search_methods`, migrasjon 014c). En forespørsel kan
 * ikke oppgi en adresse: en tjeneste ingen har vurdert, finnes ikke å be om
 * (ANTIDEP_CONSTITUTION.md regel 7).
 */
export const SEARCH_PLATFORMS: readonly string[] = SEARCH_REQUEST_PLATFORMS
export const SEARCH_METHOD_NAMES: readonly string[] = SEARCH_REQUEST_METHODS

/** Identifikatorformene en sentral kilde kan følges med. */
export const SEED_IDENTIFIER_KINDS = ['doi', 'pmid', 'pmcid'] as const

/** Hvor mange sentrale kilder én forespørsel kan be Antidep følge. Samme tall som raden. */
export const SEARCH_REQUEST_MAX_SEEDS = 10

/** Formene en maskinell søkerunde kan ha. */
export const SEARCH_STRATEGIES = ['broad', 'targeted'] as const

/** Hvor mange termer én søkeforespørsel kan bære. Samme tall som raden. */
export const SEARCH_REQUEST_MAX_TERMS = 8

// ----------------------------------------------------------------------------
// Svarformen er oppgavens egen (migrasjon 014i)
//
// Hvilke kilder svaret kan vurdere, hvilke av dem som ikke kan ekskluderes, og
// hvilke runder det kan erstatte med et smalere søk, står i oppgaven. Formen
// bygges av det (`discovery-answer-bounds.ts`), slik at det gale svaret ikke
// bare er forbudt i prosa, men ikke finnes å skrive: en tilgangsbegrenset kilde
// har ikke «excluded» blant sine valg, og narrows_request tar bare en av de
// rundene leddet faktisk kan erstatte — eller finnes ikke, når ingen kan det.
// ----------------------------------------------------------------------------

const ACCESS_LIMITED_DECISION =
  'Denne kilden har en registrert tilgangsbegrensning: Antidep har ikke fått lest den. Da finnes ikke «excluded» — heller ikke med en faglig grunn lest av tittelen eller sammendraget. Sett «awaiting_access» og skriv hvorfor i decision_reason; mener du kilden ikke er relevant, si det der og la could_change_conclusion være false.'

/** Kandidatkildene gruppert på identifikatorform og tilgang, i oppgavens rekkefølge. */
function candidateGroups(candidates: readonly AppraisableCandidate[]): Schema[] {
  const groups = new Map<string, { kind: string; limited: boolean; values: string[] }>()
  for (const candidate of candidates) {
    const key = `${candidate.identifierKind}|${String(candidate.accessLimited)}`
    const group = groups.get(key) ?? {
      kind: candidate.identifierKind,
      limited: candidate.accessLimited,
      values: [],
    }
    group.values.push(candidate.identifierValue)
    groups.set(key, group)
  }
  return [...groups.values()].map((group) => ({
    description: group.limited
      ? `Kilder med registrert tilgangsbegrensning (${group.kind}). ${ACCESS_LIMITED_DECISION}`
      : `Kilder uten registrert tilgangsbegrensning (${group.kind}).`,
    properties: {
      identifier_kind: { const: group.kind },
      identifier_value: { enum: group.values },
      ...(group.limited
        ? { decision: optionalVocabulary(ACCESS_LIMITED_DECISIONS, ACCESS_LIMITED_DECISION) }
        : {}),
    },
  }))
}

function candidateAppraisalSchema(candidates: readonly AppraisableCandidate[]): Schema {
  const description =
    'Vurderingen din av kandidatkildene de registrerte søkene ga. Søkene er enten Antideps maskinelle kall eller passeringer en redaktør utførte og registrerte; oppgaven sier om hvert av dem hvem som utførte det. Bare kilder som står i oppgaven: en kilde som ikke er funnet av et registrert søk, har ingen oppdagelsesvei, og den skal ikke fylles inn fra hukommelsen. Mangler en kilde du mener bør være der, be om et søk som ville funnet den.'
  if (candidates.length === 0) {
    return {
      type: 'array',
      maxItems: 0,
      description: `${description} Denne oppgaven har ingen kandidatkilder å vurdere, så listen er tom.`,
    }
  }
  const kinds = [...new Set(candidates.map((candidate) => candidate.identifierKind))]
  return {
    type: 'array',
    description,
    items: {
      type: 'object',
      additionalProperties: false,
      required: ['identifier_kind', 'identifier_value'],
      properties: {
        identifier_kind: vocabulary(
          kinds,
          'Identifikatorformen, ordrett fra kandidatlisten i oppgaven.',
        ),
        identifier_value: {
          type: 'string',
          enum: candidates.map((candidate) => candidate.identifierValue),
          description: 'Identifikatoren, ordrett fra kandidatlisten i oppgaven.',
        },
        could_change_conclusion: {
          type: ['boolean', 'null'],
          description:
            'Om kilden med rimelighet kan endre hovedkonklusjonen. Dette er en vurdering søket ikke kan gjøre — det leser en treffliste — og det er den opplysningen som hindrer at søket avsluttes for tidlig. En uavklart kilde som kan endre konklusjonen, hindrer at dekningen erklæres ferdig.',
        },
        materiality_reason: optionalText(
          'Hvorfor kilden kan endre konklusjonen. Påkrevd når could_change_conclusion er true.',
        ),
        decision: optionalVocabulary(
          CANDIDATE_DECISIONS,
          'Utvalgsbeslutningen din. «excluded» krever en faglig grunn, og finnes bare for en kilde uten registrert tilgangsbegrensning. En kilde merket TILGANGSBEGRENSET i kandidatlisten kan ikke ekskluderes, uansett grunn: den hører under «awaiting_access».',
        ),
        decision_reason: optionalText('Begrunnelsen for beslutningen.'),
        uses: {
          type: 'array',
          description:
            'Hva kilden kan brukes til, per kunnskapsbehov. En kilde godkjennes for en bestemt bruk og avgrensning, ikke universelt. Bruk bare need_reference-verdier som står i oppgaven.',
          items: {
            type: 'object',
            additionalProperties: false,
            required: ['need_reference', 'proposed_use'],
            properties: {
              need_reference: text('Behovets referanse, ordrett fra oppgaven.'),
              proposed_use: text(
                'Hva kilden kan dokumentere for nettopp dette behovet, og innen hvilken avgrensning.',
              ),
            },
          },
        },
      },
      // Hver kilde hører til nøyaktig én gruppe, og gruppen sier hvilke
      // beslutninger den kan få.
      anyOf: candidateGroups(candidates),
    },
  }
}

/** Én vei å erstatte en avkortet runde på: referansen, plattformen og metoden. */
function narrowingAlternative(round: NarrowableRound): Schema {
  return {
    description: `Et smalere søk som erstatter runden ${round.requestReference}: ${round.platform}, ${round.method}.`,
    required: ['narrows_request', 'platform', 'method'],
    properties: {
      narrows_request: { const: round.requestReference },
      platform: { const: round.platform },
      method: { const: round.method },
    },
  }
}

function searchRequestSchema(rounds: readonly NarrowableRound[]): Schema {
  const properties: Record<string, Schema> = {
    rationale: text(
      'Hvorfor dette søket trengs: hvilket hull i dekningen det skal fylle, eller hvilken kilde du mener kan finnes og ikke er funnet ennå.',
    ),
    platform: optionalVocabulary(
      SEARCH_PLATFORMS,
      'Plattformen søket skal gå mot, når det gjelder én bestemt. Utelat for alle som har metoden. En annen tjeneste kan ikke oppgis, og en adresse kan ikke oppgis.',
    ),
    method: optionalVocabulary(
      SEARCH_METHOD_NAMES,
      'Søkemetoden, slik oppgaven lister dem under «Søk du kan be om» med hva hver av dem dekker. Utelat for de bibliografiske fritekstsøkene. «references» og «citations» følger de sentrale kildene du navngir i seed_candidates.',
    ),
    seed_candidates: {
      type: 'array',
      maxItems: SEARCH_REQUEST_MAX_SEEDS,
      description:
        'De sentrale kildene Antidep skal følge med «references» eller «citations» — kandidatkilder fra oppgaven, med identifikatoren ordrett. Hvilke kilder som er sentrale, avgjør du; Antidep følger dem. Kildene du velger til innhenting, inkluderer eller vurderer som mulig konklusjonsendrende, følges uansett i neste runde.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['identifier_kind', 'identifier_value'],
        properties: {
          identifier_kind: vocabulary(
            SEED_IDENTIFIER_KINDS,
            'Identifikatorformen, ordrett fra kandidatlisten i oppgaven.',
          ),
          identifier_value: text('Identifikatoren, ordrett fra kandidatlisten i oppgaven.'),
        },
      },
    },
    strategy: optionalVocabulary(
      SEARCH_STRATEGIES,
      '«broad» setter avgrensningsaksene som ELLER-ledd; «targeted» gjør én passering per akse eller term. Utelat for «targeted».',
    ),
    drug_aliases: {
      type: 'array',
      maxItems: SEARCH_REQUEST_MAX_TERMS,
      items: { type: 'string', minLength: 2, maxLength: 120 },
      description:
        'Virkestoffnavn som skal søkes som ALTERNATIVER til det kanoniske: den engelske stavemåten, et handelsnavn, et navn på et annet språk. De hører hjemme her og ikke i query_terms — et synonym lagt til som en term ville blitt et ekstra påkrevd begrep, og da kunne ikke en artikkel som bare bruker det andre navnet, treffe i det hele tatt.',
    },
    query_terms: {
      type: 'array',
      maxItems: SEARCH_REQUEST_MAX_TERMS,
      items: { type: 'string', minLength: 2, maxLength: 120 },
      description:
        'Begrepene som skal legges til avgrensningen som egne krav — et studiedesign, en aldersgruppe, et utfall. Høyst åtte, uten anførselstegn og uten linjeskift. Et annet navn på virkestoffet hører i drug_aliases.',
    },
    filters_note: optionalText(
      'En avgrensning som er faglig begrunnet. Ingen automatisk avgrensning til åpen tilgang, engelsk språk, siste fem år eller statistisk signifikante resultater.',
    ),
  }
  const description =
    'Flere eller mer målrettede søk du ber Antidep utføre. Dette er den ene veien fra din vurdering til et nytt søk: du utfører ingen søk selv, og du trenger ingen nettilgang. Antidep kjører forespørslene, registrerer dem med endepunkt og responsavtrykk, og gir deg en ny vurderingsrunde på resultatet.'

  // Ingen runde kan erstattes: feltet finnes ikke, og et svar som bærer det,
  // har et felt formen ikke kjenner.
  if (rounds.length === 0) {
    return {
      type: 'array',
      description: `${description} Ingen avkortet søkerunde i denne oppgaven kan snevres inn av dette leddet, så en forespørsel har ikke feltet narrows_request.`,
      items: { type: 'object', additionalProperties: false, required: ['rationale'], properties },
    }
  }

  return {
    type: 'array',
    description,
    items: {
      type: 'object',
      additionalProperties: false,
      required: ['rationale'],
      properties: {
        ...properties,
        narrows_request: {
          type: 'string',
          enum: narrowableReferences(rounds),
          description:
            'Den avkortede runden dette smalere søket erstatter — bare en av dem oppgaven lister under «Søkerunder du kan snevre inn», og med nøyaktig den plattformen og metoden som står ved den. Et avkortet søk holder søkedekningen åpen til det samme søket er lest helt, eller til et smalere søk som uttrykkelig erstatter det, er lest helt. Utelat feltet for et søk som ikke erstatter noen runde.',
        },
      },
      anyOf: [
        {
          description: 'Et søk som ikke erstatter noen runde.',
          not: { required: ['narrows_request'] },
        },
        ...rounds.map(narrowingAlternative),
      ],
    },
  }
}

/** Formen et svar på nettopp denne kildeoppdagelsesoppgaven skal ha. */
export function buildSourceDiscoveryDraftSchema(bounds: DiscoveryAnswerBounds): Schema {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'https://antidep.no/schema/source-discovery-draft-5.json',
    title: 'Antidep SourceDiscoveryDraft',
    description:
      'Vurderingen av de registrerte søkene for én søkeplan: hvilke av kandidatkildene som er relevante og til hva, hvilke flere søk som trengs, og hvilke avgrensningsverdier monografien bør dekke. Hvilken plan, hvilken avgrensning og hvilke behov det gjelder, står i oppgaven og hører ikke hjemme i svaret. Svaret skal ikke inneholde et klinisk svar på noe av spørsmålene: dette leddet finner grunnlaget, det leser det ikke. Det rapporterer heller ikke søk — søkene er utført av andre enn deg: Antideps egen kode, eller en redaktør for de søkesporene Antidep ikke har en maskinell vei til.',
    type: 'object',
    additionalProperties: false,
    required: ['candidate_appraisals'],
    properties: {
      candidate_appraisals: candidateAppraisalSchema(bounds.candidates),
      search_requests: searchRequestSchema(bounds.narrowableRounds),
      term_proposals: {
        type: 'array',
        description:
          'Nye avgrensningsverdier du mener monografien bør dekke — en indikasjon, et risikoområde, et gen. Dette er forslag: aksepten er en egen handling med et annet opphav, og du kan ikke akseptere ditt eget forslag.',
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['axis', 'label', 'rationale'],
          properties: {
            axis: text('Avgrensningsaksen verdien hører til, for eksempel «indication».'),
            label: text('Verdien, slik den bør hete.'),
            rationale: text('Hvorfor verdien er relevant for denne monografien.'),
            from_need: optionalText(
              'need_reference til behovet verdien ble dokumentert under, når den hører til nettopp det. Et delutfall du så rapportert for ett spørsmål, hører til det spørsmålet — uten dette feltet utvides monografien på malenes egen hovedakse i stedet.',
            ),
          },
        },
      },
      note: optionalText(
        'Kort merknad om søkearbeidet: hva de utførte søkene dekker, og hva de ikke dekker. En søkevei som ikke svarte, står allerede som en begrensning i oppgaven — gjenta den ikke som et resultat.',
      ),
    },
  }
}

/** Formen et svar på nettopp denne kontrollen av søkedekningen skal ha. */
export function buildSourceCoverageControlDraftSchema(bounds: DiscoveryAnswerBounds): Schema {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'https://antidep.no/schema/source-coverage-control-draft-4.json',
    title: 'Antidep SourceCoverageControlDraft',
    description:
      'Den separate kontrollen av søkedekningen for én søkeplan: vurderingen av dine egne, separat utførte motsøk, av de kildene generatoren overså, og av om begrunnelsen for å avslutte holder. Motsøkene er kjørt av Antideps egen kode under din rolle og din kjøring, og de ligger i oppgaven — du kan verken erklære eller bestride at de ble gjort. Enighet med generatoren er ikke i seg selv fasit.',
    type: 'object',
    additionalProperties: false,
    required: ['candidate_appraisals'],
    // En kontrollrunde har nøyaktig ett utfall: den avgjør, eller den ber om
    // flere motsøk. Alternativene står her og ikke bare i prosaen, fordi det er
    // dette skjemaet agenten faktisk følger — et svar som var gyldig etter
    // skjemaet og likevel ble avvist av kontrakten, ville vært vår feil og ikke
    // agentens.
    oneOf: [
      {
        required: ['control'],
        description: 'Runden avgjør dekningen.',
      },
      {
        required: ['search_requests'],
        properties: { search_requests: { minItems: 1 } },
        description: 'Runden ber om flere motsøk, og avgjør i neste runde.',
      },
    ],
    properties: {
      candidate_appraisals: candidateAppraisalSchema(bounds.candidates),
      search_requests: searchRequestSchema(bounds.narrowableRounds),
      control: {
        type: 'object',
        additionalProperties: false,
        required: ['outcome', 'note', 'materiality_assessed'],
        description:
          'Avgjørelsen din. Utelat den i en runde der du ber om flere motsøk: en avgjørelse tatt samtidig med at grunnlaget blir bedt om, hviler ikke på det grunnlaget.',
        properties: {
          outcome: vocabulary(
            ['accepted', 'insufficient'],
            'Om du godtar begrunnelsen for å avslutte søket. «accepted» krever at et eget motsøk faktisk har gått, og at du vurderte vesentligheten av de uavklarte kildene.',
          ),
          note: text(
            'Hva du kontrollerte, hva du fant, og hvorfor du godtar eller avviser begrunnelsen.',
          ),
          missed_candidates: {
            type: ['integer', 'null'],
            minimum: 0,
            description: 'Hvor mange kilder generatoren overså, og som motsøkene dine fant.',
          },
          exclusions_checked: {
            type: ['integer', 'null'],
            minimum: 0,
            description: 'Hvor mange av generatorens eksklusjoner du gikk gjennom.',
          },
          materiality_assessed: {
            type: 'boolean',
            description:
              'Om du vurderte om de uavklarte kildene med rimelighet kan endre hovedkonklusjonen.',
          },
        },
      },
      note: optionalText('Kort merknad om kontrollarbeidet, om noe trenger å sies.'),
    },
  }
}

/** Formen et monografisvar fra et myndighetsdokument skal ha. */
export function buildMonographAnswerDraftSchema(): Schema {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'https://antidep.no/schema/monograph-answer-draft-1.json',
    title: 'Antidep MonographAnswerDraft',
    description:
      'Svaret på ett kunnskapsbehov, lest ut av det registrerte myndighets-, preparat- eller retningslinjedokumentet. Hvilket behov og hvilken kildeversjon det gjelder, står i oppgaven og hører ikke hjemme i svaret. Et forskningsfunn skrives ikke her: det bindes deterministisk til en påstandsrevisjon som alt er kontrollert og vurdert.',
    type: 'object',
    additionalProperties: false,
    required: ['answer'],
    properties: {
      answer: {
        type: 'object',
        additionalProperties: false,
        required: ['knowledge_type', 'statement', 'as_of', 'source_quote', 'source_locator'],
        properties: {
          knowledge_type: vocabulary(
            ['regulatory_fact', 'product_data', 'attributed_advice'],
            'Hva slags opplysning dette er: en regulatorisk opplysning, en preparatdata, eller et råd som er attribuert til den som anbefaler det. Et forskningsfunn, et avledet svar og et resonnement skrives ikke av denne rollen.',
          ),
          statement: text(
            'Svaret slik en kliniker leser det. Ta med forbeholdene som hører til; en viktig kvalifikasjon som bare står i et annet felt, er borte for den som leser svaret.',
          ),
          structured_value: {
            type: ['object', 'null'],
            description:
              'Den strukturerte verdien, når opplysningen har en: styrker, formuleringer, aldersgrenser, vilkår. Bruk enheter og tall slik kilden oppgir dem.',
          },
          uncertainty_summary: optionalText(
            'Faglig usikkerhet ved opplysningen: hva kilden ikke sier, og hva som er uklart.',
          ),
          limitation_note: optionalText(
            'Søke- eller tilgangsbegrensninger. Hold dem atskilt fra den faglige usikkerheten: at et dokument manglet, er ikke en konklusjon om innholdet.',
          ),
          as_of: text(
            'Datoen opplysningen gjaldt, slik dokumentet selv oppgir den (ÅÅÅÅ-MM-DD). Ikke dagens dato med mindre dokumentet sier det.',
          ),
          source_quote: text(
            'Det ordrette utdraget opplysningen hviler på. Det må stå tegn for tegn i dokumentteksten du fikk; Antidep kontrollerer det maskinelt og avviser svaret ellers.',
          ),
          source_locator: text(
            'Hvor i dokumentet utdraget står: avsnittsnummer, overskrift eller tabellnavn.',
          ),
          recommending_body: optionalText(
            'Hvem som anbefaler rådet. Påkrevd når knowledge_type er «attributed_advice»: et råd uten en avsender er ikke attribuert.',
          ),
          recommendation_date: optionalText(
            'Datoen anbefalingen ble gitt eller sist oppdatert (ÅÅÅÅ-MM-DD). Påkrevd når knowledge_type er «attributed_advice».',
          ),
          additional_sources: {
            type: 'array',
            description:
              'Flere kildeversjoner svaret hviler på, når ett behov krever mer enn én. Hver av dem kontrolleres på nøyaktig samme måte som den primære.',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['source_version_id', 'source_quote', 'source_locator', 'as_of'],
              properties: {
                source_version_id: text('Kildeversjonen, slik den står i oppgaven.'),
                source_quote: text('Det ordrette utdraget fra denne kilden.'),
                source_locator: text('Hvor i dokumentet utdraget står.'),
                as_of: text('Datoen opplysningen gjaldt (ÅÅÅÅ-MM-DD).'),
              },
            },
          },
        },
      },
    },
  }
}
