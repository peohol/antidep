// ============================================================================
// Syntesforslaget: formen én foreslått påstandsrevisjon kommer inn på
//
// Påstandsdannelsen er et modell-ledd (EVIDENCE_PIPELINE.md §27), og modellen
// kjører ikke inne i Antidep. Den leser det registrerte evidensgrunnlaget og
// skriver en fil; kjøreren leser filen, kontrollerer formen og registrerer
// forslaget gjennom `api.register_claim_synthesis`. Det er den samme
// arbeidsdelingen som på ekstraksjonssiden, og den finnes av samme grunn: et
// modell-ledd med skrivevei til kunnskapsbasen ville vært ett ledd, ikke to
// (ANTIDEP_CONSTITUTION.md §10, §12, §20).
//
// ----------------------------------------------------------------------------
// Hva filen ikke får bestemme
//
//   * **Kunnskapstypen.** Skriveveien registrerer `evidence_synthesis` og
//     ingenting annet (migrasjon 005aj). En fil som kunne oppgi den, kunne
//     oppgitt `clinical_recommendation` — en normativ påstand om hva klinikeren
//     bør gjøre, som ikke skal ha en KI-kjøring som opphav.
//   * **Hvem som formulerte den.** Aktøren er kjøringens egen, hentet av
//     databasen fra legitimasjonen. `generated_by` er en *erklæring* om hvilken
//     modell som laget utkastet, og havner i kjøringens `input_manifest` — ikke
//     en attribusjon filen kan velge.
//   * **Revisjonsnummeret og hva revisjonen erstatter.** Begge følger av
//     `claim_id`: databasen teller selv. En fil som kunne sette dem, kunne laget
//     et hull eller en sirkel i historikken.
//   * **Evidensvurderingens tidspunkt.** Databasen eier det, som på kontrollene.
//
// ----------------------------------------------------------------------------
// Hva kontrollen her er, og hva den ikke er
//
// Kontrollen gjelder **formen**: at et felt finnes, har riktig type og en verdi
// innenfor sitt vokabular. Den sier ingenting om hvorvidt påstanden følger av
// evidensen — det er claim-verifikasjonens spørsmål og deretter menneskets
// (ANTIDEP_CONSTITUTION.md §11, §12).
//
// Utrygg inndata: filen er data, aldri instruksjoner (CLAUDE.md).
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
  type Uuid,
} from '../types/api.ts'
import { parseGeneratedBy, type GeneratedBy } from './extraction-proposal.ts'
import {
  asOptionalNumericText,
  asOptionalText,
  asOptionalUuid,
  asObjectList,
  asText,
  asUuid,
  asVocabulary,
  asOptionalVocabulary,
  fieldsOf,
  nestedFields,
  problem,
  raw,
  rejectUnknown,
  type Fields,
} from './strict-fields.ts'

const PROPOSAL_SUBJECT = 'Syntesforslaget'

/**
 * Kontraktsversjonen, i filen.
 *
 * Den står der av samme grunn som på ekstraksjonsforslaget: en fil laget mot en
 * eldre form skal avvises med det som årsak, framfor å bli lest som om den var
 * ny og mangle et felt.
 */
export const CLAIM_SYNTHESIS_PROPOSAL_VERSION = 'antidep/claim-synthesis-proposal@1'

/** Metoden en evidensvurdering bruker (knowledge.assessment_framework). */
export const ASSESSMENT_FRAMEWORKS = ['grade'] as const

/** Én foreslått kobling mellom revisjonen og et registrert evidensfunn. */
export interface ProposedEvidenceLink {
  readonly evidenceItemId: Uuid
  readonly relationshipType: string
  readonly directness: string
  readonly relevanceNote: string
}

/** Den foreslåtte evidensvurderingen (knowledge.evidence_assessments). */
export interface ProposedAssessment {
  readonly framework: string
  readonly certaintyLevel: string
  readonly riskOfBias: string | null
  readonly inconsistency: string | null
  readonly indirectness: string | null
  readonly imprecision: string | null
  readonly publicationBias: string | null
  readonly otherConsiderations: string | null
  readonly rationale: string
  readonly evidenceGap: string | null
}

/** Selve påstandsrevisjonen, slik den foreslås formulert. */
export interface ProposedClaimRevision {
  /**
   * Påstandsidentiteten revisjonen hører til, eller `null` for en ny påstand.
   *
   * Ikke utledet av tema og virkestoff: to atomiske påstander om samme
   * virkestoff og samme endepunkt er normalt og riktig (EVIDENCE_PIPELINE.md
   * §28), og et oppslag ville slått dem sammen til revisjoner av hverandre.
   */
  readonly claimId: Uuid | null
  readonly topicConceptId: Uuid
  readonly subjectDrugId: Uuid
  readonly statement: string
  readonly scope: string
  readonly populationId: Uuid | null
  /** PostgreSQL-interval som tekst, for eksempel «8 weeks». */
  readonly timeframeMin: string | null
  readonly timeframeMax: string | null
  readonly comparatorKind: string
  readonly comparatorDrugId: Uuid | null
  readonly direction: string | null
  readonly magnitudeMeasure: string | null
  /** `numeric` som tekst, av samme grunn som estimatene på evidensfunnene. */
  readonly magnitudeValue: string | null
  readonly magnitudeUnit: string | null
  readonly qualifiers: string | null
  readonly uncertaintySummary: string
}

/** Hele forslaget: kontraktsversjonen, opphavet, påstanden, grunnlaget og vurderingen. */
export interface ClaimSynthesisProposal {
  readonly proposalVersion: typeof CLAIM_SYNTHESIS_PROPOSAL_VERSION
  readonly generatedBy: GeneratedBy
  readonly claim: ProposedClaimRevision
  readonly evidenceLinks: readonly ProposedEvidenceLink[]
  readonly assessment: ProposedAssessment
}

function parseClaim(parent: Fields, value: unknown): ProposedClaimRevision {
  const fields = nestedFields(parent, value, 'claim')
  const claim: ProposedClaimRevision = {
    claimId: asOptionalUuid(fields, 'claim_id'),
    topicConceptId: asUuid(fields, 'topic_concept_id'),
    subjectDrugId: asUuid(fields, 'subject_drug_id'),
    statement: asText(fields, 'statement'),
    scope: asText(fields, 'scope'),
    populationId: asOptionalUuid(fields, 'population_id'),
    timeframeMin: asOptionalText(fields, 'timeframe_min'),
    timeframeMax: asOptionalText(fields, 'timeframe_max'),
    comparatorKind: asVocabulary(fields, 'comparator_kind', COMPARATOR_KINDS),
    comparatorDrugId: asOptionalUuid(fields, 'comparator_drug_id'),
    direction: asOptionalVocabulary(fields, 'direction', CLAIM_DIRECTIONS),
    magnitudeMeasure: asOptionalVocabulary(fields, 'magnitude_measure', EFFECT_MEASURES),
    magnitudeValue: asOptionalNumericText(fields, 'magnitude_value'),
    magnitudeUnit: asOptionalVocabulary(fields, 'magnitude_unit', ESTIMATE_UNITS),
    qualifiers: asOptionalText(fields, 'qualifiers'),
    // Påkrevd her og ikke bare i basen: en evidenssyntese SKAL ha en eksplisitt
    // usikkerhetstekst (ANTIDEP_CONSTITUTION.md §6), og et forslag uten den er
    // ikke et ufullstendig forslag — det er et forslag som mangler halve
    // påstanden.
    uncertaintySummary: asText(fields, 'uncertainty_summary'),
  }
  rejectUnknown(fields, {
    knowledge_type:
      'hører ikke hjemme i et forslag. Skriveveien registrerer evidence_synthesis og ingenting annet; et deterministisk faktum avgjøres mot en autoritativ kilde, og en klinisk anbefaling skal ikke ha en KI-kjøring som opphav',
    revision_number:
      'hører ikke hjemme i et forslag. Databasen teller selv, slik at historikken ikke kan få et hull eller en sirkel',
    supersedes_revision_id:
      'hører ikke hjemme i et forslag. Hva revisjonen erstatter, følger av claim_id og settes av databasen',
    created_by_actor_id:
      'hører ikke hjemme i et forslag. Aktøren er kjøringens egen, hentet av databasen fra legitimasjonen',
  })

  // Det ene paret databasen ikke kan si noe presist om før raden er skrevet.
  // En CHECK ville sagt «brudd på claim_revisions_timeframe_pairing_check»; her
  // kan feilen si hva som mangler, i filens egne navn.
  if ((claim.timeframeMin === null) !== (claim.timeframeMax === null)) {
    problem(
      fields.subject,
      'claim',
      'oppgir bare den ene enden av tidsrommet. Et tidsrom er et intervall: enten står både ' +
        'timeframe_min og timeframe_max, eller ingen av dem',
    )
  }

  return claim
}

function parseEvidenceLink(parent: Fields, value: unknown, index: number): ProposedEvidenceLink {
  const fields = nestedFields(parent, value, `evidence_links[${String(index)}]`)
  const link: ProposedEvidenceLink = {
    evidenceItemId: asUuid(fields, 'evidence_item_id'),
    relationshipType: asVocabulary(fields, 'relationship_type', EVIDENCE_RELATIONSHIP_TYPES),
    directness: asVocabulary(fields, 'directness', EVIDENCE_DIRECTNESS_VALUES),
    // Alltid påkrevd: en kilde som bare omhandler samme tema, skal ikke kunne
    // telle som støtte (ANTIDEP_CONSTITUTION.md §4, KNOWLEDGE_MODEL.md §12).
    relevanceNote: asText(fields, 'relevance_note'),
  }
  rejectUnknown(fields)

  if (link.relationshipType === 'indirect' && link.directness !== 'indirect') {
    problem(
      fields.subject,
      `evidence_links[${String(index)}]`,
      'er ført som relationship_type «indirect», men directness «direct». Et funn som bare kan ' +
        'bedømmes indirekte, treffer ikke påstanden direkte. Et direkte relevant funn som ' +
        'verken støtter eller motsier påstanden, er neutral_contextual',
    )
  }

  return link
}

function parseAssessment(parent: Fields, value: unknown): ProposedAssessment {
  const fields = nestedFields(parent, value, 'assessment')
  const assessment: ProposedAssessment = {
    framework: asVocabulary(fields, 'framework', ASSESSMENT_FRAMEWORKS),
    certaintyLevel: asVocabulary(fields, 'certainty_level', CERTAINTY_LEVELS),
    riskOfBias: asOptionalVocabulary(fields, 'risk_of_bias', GRADE_DOMAIN_RATINGS),
    inconsistency: asOptionalVocabulary(fields, 'inconsistency', GRADE_DOMAIN_RATINGS),
    indirectness: asOptionalVocabulary(fields, 'indirectness', GRADE_DOMAIN_RATINGS),
    imprecision: asOptionalVocabulary(fields, 'imprecision', GRADE_DOMAIN_RATINGS),
    publicationBias: asOptionalVocabulary(fields, 'publication_bias', GRADE_DOMAIN_RATINGS),
    otherConsiderations: asOptionalText(fields, 'other_considerations'),
    rationale: asText(fields, 'rationale'),
    evidenceGap: asOptionalText(fields, 'evidence_gap'),
  }
  rejectUnknown(fields, {
    assessed_at:
      'hører ikke hjemme i et forslag. Tidspunktet for den faglige vurderingen eies av databasen, som på kontrollene',
  })

  // De samme to reglene databasen håndhever (migrasjon 004), formulert i filens
  // egne navn. «Ingen vurderbar evidens» er en egen systemtilstand og ikke en
  // femte GRADE-grad: det finnes ikke noe å gradere ned fra, og tilstanden skal
  // aldri stå tom (ANTIDEP_CONSTITUTION.md §6).
  const domains = [
    assessment.riskOfBias,
    assessment.inconsistency,
    assessment.indirectness,
    assessment.imprecision,
    assessment.publicationBias,
  ]
  const noAssessable = assessment.certaintyLevel === 'no_assessable_evidence'
  if (noAssessable && domains.some((domain) => domain !== null)) {
    problem(
      fields.subject,
      'assessment',
      'oppgir GRADE-domener sammen med certainty_level «no_assessable_evidence». Tilstanden ' +
        'betyr at grunnlaget ikke lar seg vurdere i det hele tatt, og da finnes det ikke noe å ' +
        'gradere ned fra',
    )
  }
  if (!noAssessable && domains.some((domain) => domain === null)) {
    problem(
      fields.subject,
      'assessment',
      'mangler minst ett GRADE-domene. En sikkerhetsgrad krever eksplisitt vurdering av alle ' +
        'fem: risk_of_bias, inconsistency, indirectness, imprecision og publication_bias. Et ' +
        'domene som ikke lar seg bedømme, er «not_assessable» — ikke tomt',
    )
  }
  if (noAssessable && assessment.evidenceGap === null) {
    problem(
      fields.subject,
      'assessment.evidence_gap',
      'mangler. «Ingen vurderbar evidens» skal si hva som mangler, ellers er den ikke til å ' +
        'skille fra at ingen har sett på spørsmålet',
    )
  }

  return assessment
}

/**
 * Leser og kontrollerer ett syntesforslag.
 *
 * Avviser et ukjent felt framfor å ignorere det: en skrivefeil i et feltnavn
 * ville ellers blitt til en manglende verdi i en klinisk påstand
 * (`strict-fields.ts`).
 */
export function parseClaimSynthesisProposal(value: unknown): ClaimSynthesisProposal {
  const fields = fieldsOf(value, PROPOSAL_SUBJECT, 'forslaget')

  const version = asText(fields, 'proposal_version')
  if (version !== CLAIM_SYNTHESIS_PROPOSAL_VERSION) {
    problem(
      PROPOSAL_SUBJECT,
      'proposal_version',
      `er ${JSON.stringify(version)}, men kjøringen leser ` +
        `${JSON.stringify(CLAIM_SYNTHESIS_PROPOSAL_VERSION)}`,
    )
  }

  const generatedBy = parseGeneratedBy(fields, raw(fields, 'generated_by'))
  const claim = parseClaim(fields, raw(fields, 'claim'))
  const links = asObjectList(fields, 'evidence_links').map((link, index) =>
    parseEvidenceLink(fields, link, index),
  )
  const assessment = parseAssessment(fields, raw(fields, 'assessment'))
  rejectUnknown(fields)

  // Det samme funnet to ganger ville fått ett funn til å se ut som flere
  // uavhengige, og en vurdering til å hvile på en oppblåst evidensmengde.
  // Databasen avviser det også (claim_evidence_links_revision_item_key), men
  // her kan feilen si hvilken id det gjelder.
  const seen = new Set<string>()
  for (const link of links) {
    if (seen.has(link.evidenceItemId)) {
      problem(
        PROPOSAL_SUBJECT,
        'evidence_links',
        `fører evidensfunnet ${link.evidenceItemId} flere ganger. Ett funn kan ha nøyaktig én ` +
          'relasjon til én revisjon',
      )
    }
    seen.add(link.evidenceItemId)
  }

  return {
    proposalVersion: CLAIM_SYNTHESIS_PROPOSAL_VERSION,
    generatedBy,
    claim,
    evidenceLinks: links,
    assessment,
  }
}
