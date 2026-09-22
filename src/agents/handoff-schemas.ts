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

/** Utfallene ett søk kan ha. De to siste er ikke null treff. */
export const SEARCH_OUTCOMES = ['executed', 'zero_results', 'unavailable', 'failed'] as const

/** Utvalgsbeslutningene om én kandidatkilde. */
export const CANDIDATE_DECISIONS = [
  'proposed',
  'selected_for_retrieval',
  'included',
  'excluded',
  'awaiting_access',
  'awaiting_clarification',
] as const

/**
 * Plattformene en søkeforespørsel kan navngi.
 *
 * Listen er uttømmende, og den er den samme i `workflow.monograph_search_requests`.
 * En forespørsel kan ikke oppgi en adresse: en tjeneste ingen har vurdert,
 * finnes ikke å be om (ANTIDEP_CONSTITUTION.md regel 7).
 */
export const SEARCH_PLATFORMS = ['Europe PMC', 'PubMed', 'Crossref'] as const

/** Formene en maskinell søkerunde kan ha. */
export const SEARCH_STRATEGIES = ['broad', 'targeted'] as const

/** Hvor mange termer én søkeforespørsel kan bære. Samme tall som raden. */
export const SEARCH_REQUEST_MAX_TERMS = 8

function candidateAppraisalSchema(): Schema {
  return {
    type: 'array',
    description:
      'Vurderingen din av kandidatkildene de maskinelt utførte søkene ga. Bare kilder som står i oppgaven: en kilde som ikke er funnet av et registrert søk, har ingen oppdagelsesvei, og den skal ikke fylles inn fra hukommelsen. Mangler en kilde du mener bør være der, be om et søk som ville funnet den.',
    items: {
      type: 'object',
      additionalProperties: false,
      required: ['identifier_kind', 'identifier_value'],
      properties: {
        identifier_kind: vocabulary(
          ['doi', 'pmid', 'pmcid', 'url', 'title', 'registry_id'],
          'Identifikatorformen, ordrett fra kandidatlisten i oppgaven.',
        ),
        identifier_value: text('Identifikatoren, ordrett fra kandidatlisten i oppgaven.'),
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
          'Utvalgsbeslutningen din. «excluded» krever en faglig grunn, og kan ikke brukes på en kilde Antidep bare ikke kom til: en betalingsmur er en tilgangsbegrensning, og den hører under «awaiting_access».',
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
    },
  }
}

function searchRequestSchema(): Schema {
  return {
    type: 'array',
    description:
      'Flere eller mer målrettede søk du ber Antidep utføre. Dette er den ene veien fra din vurdering til et nytt søk: du utfører ingen søk selv, og du trenger ingen nettilgang. Antidep kjører forespørslene, registrerer dem med endepunkt og responsavtrykk, og gir deg en ny vurderingsrunde på resultatet.',
    items: {
      type: 'object',
      additionalProperties: false,
      required: ['rationale'],
      properties: {
        rationale: text(
          'Hvorfor dette søket trengs: hvilket hull i dekningen det skal fylle, eller hvilken kilde du mener kan finnes og ikke er funnet ennå.',
        ),
        platform: optionalVocabulary(
          SEARCH_PLATFORMS,
          'Plattformen søket skal gå mot, når det gjelder én bestemt. Utelat for alle tre. En annen tjeneste kan ikke oppgis, og en adresse kan ikke oppgis.',
        ),
        strategy: optionalVocabulary(
          SEARCH_STRATEGIES,
          '«broad» setter avgrensningsaksene som ELLER-ledd; «targeted» gjør én passering per akse eller term. Utelat for «targeted».',
        ),
        query_terms: {
          type: 'array',
          maxItems: SEARCH_REQUEST_MAX_TERMS,
          items: { type: 'string', minLength: 2, maxLength: 120 },
          description:
            'Termene som skal legges til avgrensningen — synonymer, et studiedesign, et virkestoffnavn på et annet språk. Høyst åtte, uten anførselstegn og uten linjeskift.',
        },
        filters_note: optionalText(
          'En avgrensning som er faglig begrunnet. Ingen automatisk avgrensning til åpen tilgang, engelsk språk, siste fem år eller statistisk signifikante resultater.',
        ),
      },
    },
  }
}

/** Formen et kildeoppdagelsessvar skal ha. */
export function buildSourceDiscoveryDraftSchema(): Schema {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'https://antidep.no/schema/source-discovery-draft-3.json',
    title: 'Antidep SourceDiscoveryDraft',
    description:
      'Vurderingen av de maskinelt utførte søkene for én søkeplan: hvilke av kandidatkildene som er relevante og til hva, hvilke flere søk som trengs, og hvilke avgrensningsverdier monografien bør dekke. Hvilken plan, hvilken avgrensning og hvilke behov det gjelder, står i oppgaven og hører ikke hjemme i svaret. Svaret skal ikke inneholde et klinisk svar på noe av spørsmålene: dette leddet finner grunnlaget, det leser det ikke. Det rapporterer heller ikke søk — søkene er utført av Antideps egen kode.',
    type: 'object',
    additionalProperties: false,
    required: ['candidate_appraisals'],
    properties: {
      candidate_appraisals: candidateAppraisalSchema(),
      search_requests: searchRequestSchema(),
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

/** Formen en kontroll av søkedekningen skal ha. */
export function buildSourceCoverageControlDraftSchema(): Schema {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'https://antidep.no/schema/source-coverage-control-draft-2.json',
    title: 'Antidep SourceCoverageControlDraft',
    description:
      'Den separate kontrollen av søkedekningen for én søkeplan: vurderingen av dine egne, separat utførte motsøk, av de kildene generatoren overså, og av om begrunnelsen for å avslutte holder. Motsøkene er kjørt av Antideps egen kode under din rolle og din kjøring, og de ligger i oppgaven — du kan verken erklære eller bestride at de ble gjort. Enighet med generatoren er ikke i seg selv fasit.',
    type: 'object',
    additionalProperties: false,
    required: ['candidate_appraisals'],
    properties: {
      candidate_appraisals: candidateAppraisalSchema(),
      search_requests: searchRequestSchema(),
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
