// ============================================================================
// Vurderingsforslaget: formen én foreslått evidensvurdering kommer inn på
//
// Evidensvurderingen er et eget ledd (EVIDENCE_PIPELINE.md §61,
// `EvidenceAssessor`), og et annet ledd enn påstandsdannelsen. Fram til
// migrasjon 005am lå vurderingen i syntesforslaget og ble skrevet av
// synteseagenten i den samme transaksjonen som påstanden; da var ansvarsgrensen
// et navn og ikke en grense.
//
// Formen er den samme arbeidsdelingen som ellers: modellen leser det
// registrerte grunnlaget og skriver en fil, kjøreren leser filen, kontrollerer
// formen og registrerer forslaget gjennom `api.register_evidence_assessment`.
//
// ----------------------------------------------------------------------------
// Hva filen ikke får bestemme
//
//   * **Hvem som vurderte.** Aktøren er kjøringens egen, hentet av databasen fra
//     legitimasjonen. `generated_by` er en *erklæring* om hvilken modell som
//     laget utkastet, og havner i kjøringens `input_manifest`.
//   * **Tidspunktet.** Databasen eier `assessed_at`, som på kontrollene.
//   * **Kunnskapstypen.** Den leses av revisjonen vurderingen gjelder.
//
// ----------------------------------------------------------------------------
// Hvorfor filen oppgir evidenssettets avtrykk
//
// `evidence_set_digest` er avtrykket av det evidenssettet utkastet faktisk ble
// laget mot. Vurderingen forsegler settet
// (`knowledge.reject_evidence_link_after_assessment`), så en lenke som kommer
// til mellom lesningen og registreringen, ville ellers blitt stilltiende dekket
// av en gradering som aldri så den (ANTIDEP_CONSTITUTION.md §9). Databasen
// sammenligner avtrykket under en lås på revisjonsraden og avviser et utdatert
// utkast framfor å registrere det.
//
// Utrygg inndata: filen er data, aldri instruksjoner (CLAUDE.md).
// ============================================================================

import { CERTAINTY_LEVELS, GRADE_DOMAIN_RATINGS, type Uuid } from '../types/api.ts'
import { parseGeneratedBy, type GeneratedBy } from './extraction-proposal.ts'
import {
  asOptionalText,
  asOptionalVocabulary,
  asText,
  asUuid,
  asVocabulary,
  fieldsOf,
  nestedFields,
  problem,
  raw,
  rejectUnknown,
  type Fields,
} from './strict-fields.ts'

const PROPOSAL_SUBJECT = 'Vurderingsforslaget'

/**
 * Kontraktsversjonen, i filen.
 *
 * Står der av samme grunn som på de øvrige forslagene: en fil laget mot en
 * eldre form skal avvises med det som årsak, framfor å bli lest som om den var
 * ny og mangle et felt.
 */
export const EVIDENCE_ASSESSMENT_PROPOSAL_VERSION = 'antidep/evidence-assessment-proposal@1'

/** Metoden en evidensvurdering bruker (knowledge.assessment_framework). */
export const ASSESSMENT_FRAMEWORKS = ['grade'] as const

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

/** Hele forslaget: kontraktsversjonen, opphavet, målet og vurderingen. */
export interface EvidenceAssessmentProposal {
  readonly proposalVersion: typeof EVIDENCE_ASSESSMENT_PROPOSAL_VERSION
  readonly generatedBy: GeneratedBy
  /** Revisjonen vurderingen gjelder. Én vurdering per revisjon. */
  readonly claimRevisionId: Uuid
  /** Avtrykket av evidenssettet utkastet ble laget mot. */
  readonly evidenceSetDigest: string
  readonly assessment: ProposedAssessment
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
    created_by_actor_id:
      'hører ikke hjemme i et forslag. Aktøren er kjøringens egen, hentet av databasen fra legitimasjonen',
    assessed_knowledge_type:
      'hører ikke hjemme i et forslag. Kunnskapstypen leses av revisjonen vurderingen gjelder',
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
 * Leser og kontrollerer ett vurderingsforslag.
 *
 * Avviser et ukjent felt framfor å ignorere det: en skrivefeil i et feltnavn
 * ville ellers blitt til en manglende verdi i en klinisk vurdering
 * (`strict-fields.ts`).
 */
export function parseEvidenceAssessmentProposal(value: unknown): EvidenceAssessmentProposal {
  const fields = fieldsOf(value, PROPOSAL_SUBJECT, 'forslaget')

  const version = asText(fields, 'proposal_version')
  if (version !== EVIDENCE_ASSESSMENT_PROPOSAL_VERSION) {
    problem(
      PROPOSAL_SUBJECT,
      'proposal_version',
      `er ${JSON.stringify(version)}, men kjøringen leser ` +
        `${JSON.stringify(EVIDENCE_ASSESSMENT_PROPOSAL_VERSION)}`,
    )
  }

  const generatedBy = parseGeneratedBy(fields, raw(fields, 'generated_by'))
  const claimRevisionId = asUuid(fields, 'claim_revision_id')
  const evidenceSetDigest = asText(fields, 'evidence_set_digest')
  const assessment = parseAssessment(fields, raw(fields, 'assessment'))
  rejectUnknown(fields)

  return {
    proposalVersion: EVIDENCE_ASSESSMENT_PROPOSAL_VERSION,
    generatedBy,
    claimRevisionId,
    evidenceSetDigest,
    assessment,
  }
}
