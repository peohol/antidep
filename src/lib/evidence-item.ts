// ============================================================================
// Den strukturerte betydningen bak ett evidensfunn
//
// Tredje søsken til `claim-certainty.ts` og `claim-effect.ts`, og bygget etter
// samme regel: en verdi som ikke lar seg tolke skal bli en eksplisitt ukjent
// tilstand, ikke havne i en godartet gren.
//
// Evidensfunnet er den eneste raden i `api` der «hvorfor mangler denne
// verdien?» er registrert som data. Seks felter bærer en `*_availability`, og
// de finnes nettopp for at en tom verdi aldri skal kunne leses som en nullverdi
// (ANTIDEP_CONSTITUTION.md §17, DATABASE_ARCHITECTURE.md §19.1). Hele modulen
// er bygget rundt det skillet.
//
// ----------------------------------------------------------------------------
// Fire akser som ser like ut og betyr forskjellige ting
//
//   relationship_type   Antideps vurdering av hvordan funnet forholder seg til
//                       påstanden: støtter, motsier, er nøytralt, er indirekte.
//   directness          om funnet treffer påstandens populasjon, endepunkt,
//                       komparator og tidsrom direkte. Egen akse, slik at et
//                       indirekte funn som *motsier* påstanden kan uttrykkes.
//   reported_direction  retningen kilden selv oppgir. Ikke Antideps vurdering,
//                       og ikke påstandens `direction`: vokabularet har en
//                       fjerde verdi, `not_stated`.
//   *_availability      hvorfor et felt har eller ikke har en verdi.
//
// De to første er Antideps tolkning, den tredje er kildens egen, og den fjerde
// sier hva slags fravær et fravær er. Slått sammen ville «kilden oppgir ingen
// retning», «Antidep vurderer funnet som nøytralt» og «størrelsen ble ikke
// målt» kunne bytte plass — tre helt forskjellige utsagn (§5, §9, §17).
//
// ----------------------------------------------------------------------------
// Hva denne koden antar om schemaet, og hva som håndhever det
//
//   verdi finnes ⇔ availability sier at den gjør det   migrasjon 003 håndhever
//   timepoint_min og _max er paret                     migrasjon 003 håndhever
//   ci_lower, ci_upper og ci_level_percent er paret    migrasjon 003 håndhever
//   utvalgsstørrelsen er et positivt heltall           migrasjon 003 håndhever
//   enhet følger effektmålet                           migrasjon 003 håndhever
//   komparatoren er ikke intervensjonen selv           migrasjon 003 håndhever
//   publiseringsdato ⇔ datopresisjon                   migrasjon 003 håndhever
//   relationship_type 'indirect' ⇒ directness          migrasjon 004 håndhever
//     'indirect'
//   et kontrastivt effektmål krever en komparator      INGENTING håndhever dette
//
// Alle kontrolleres likevel her, av samme grunn som i de to søskenmodulene:
// klienten leser også en database den ikke selv har migrert, og et view er en
// projeksjon — en kolonne kan endre betydning uten at klienten får vite det.
// Den siste er den samme registrerte gjelden som for påstandsraden
// (MVP_IMPLEMENTATION_PLAN.md §74.7); den lukkes ikke her.
// ============================================================================

import {
  describeClaimComparator,
  describeClaimMagnitude,
  describeMeasureUnit,
  type ClaimComparatorState,
  type ClaimMagnitudeFault,
} from './claim-effect'
import {
  CERTAINTY_LEVELS,
  COMPARATOR_KINDS,
  DATE_PRECISIONS,
  KNOWLEDGE_TYPES,
  DRUG_STATUSES,
  EFFECT_MEASURES,
  ESTIMATE_UNITS,
  EVIDENCE_CHECK_FIELDS,
  EVIDENCE_DIRECTNESS_VALUES,
  EVIDENCE_RELATIONSHIP_TYPES,
  EXTRACTION_METHODS,
  GRADE_DOMAIN_RATINGS,
  REPORTED_DIRECTIONS,
  REVIEW_OUTCOMES,
  SOURCE_REPRESENTATIONS,
  SOURCE_STATUSES,
  SOURCE_TYPES,
  STUDY_DESIGNS,
  VALUE_AVAILABILITIES,
  VERIFICATION_CHECK_RESULTS,
  VERIFICATION_OUTCOMES,
  VERIFICATION_SOURCE_ACCESSES,
  VOCABULARY_STATUSES,
  type CertaintyLevel,
  type ComparatorKind,
  type DatePrecision,
  type DrugStatus,
  type EffectMeasure,
  type EstimateUnit,
  type EvidenceCheckField,
  type EvidenceDirectness,
  type EvidenceRelationshipType,
  type ExtractionMethod,
  type GradeDomainRating,
  type KnowledgeType,
  type PublishedClaimEvidenceRow,
  type ReportedDirection,
  type ReviewOutcome,
  type SourceRepresentation,
  type SourceStatus,
  type SourceType,
  type StudyDesign,
  type ValueAvailability,
  type VerificationCheckResult,
  type VerificationOutcome,
  type VerificationSourceAccess,
  type VocabularyStatus,
} from '../types/api'

// ----------------------------------------------------------------------------
// Ett vokabular om gangen
// ----------------------------------------------------------------------------

/**
 * En verdi fra et lukket vokabular, med den ukjente verdien bevart.
 *
 * En lukket union i `src/types/api.ts` er en påstand om databasen som ingenting
 * håndhever. Kontrollen som gjør påstanden til noe mer, er denne: verdien blir
 * enten en kjent term visningen kan oversette, eller en eksplisitt ukjent term
 * som bærer råverdien — aldri en verdi som stilltiende faller i en godartet
 * gren.
 */
export type VocabularyTerm<Term extends string> =
  | { readonly kind: 'known'; readonly value: Term }
  | { readonly kind: 'unknown'; readonly raw: string }

function readTerm<Term extends string>(
  vocabulary: readonly Term[],
  value: string,
): VocabularyTerm<Term> {
  return (vocabulary as readonly string[]).includes(value)
    ? { kind: 'known', value: value as Term }
    : { kind: 'unknown', raw: value }
}

/** Retningen kilden selv rapporterer. Ikke Antideps vurdering, og ikke påstandens. */
export function readReportedDirection(value: string): VocabularyTerm<ReportedDirection> {
  return readTerm(REPORTED_DIRECTIONS, value)
}

/**
 * Kunnskapstypen påstanden har. De tre typene har ulik epistemisk status og skal
 * aldri presenteres likt (ANTIDEP_CONSTITUTION.md §5), så en ukjent verdi må
 * heller ikke kunne falle sammen med en av dem.
 */
export function readKnowledgeType(value: string): VocabularyTerm<KnowledgeType> {
  return readTerm(KNOWLEDGE_TYPES, value)
}

/** Studiedesignet for funnet. Ikke dokumenttypen kilden har. */
export function readStudyDesign(value: string): VocabularyTerm<StudyDesign> {
  return readTerm(STUDY_DESIGNS, value)
}

/** Dokumenttypen kilden har. Ikke studiedesignet funnet er hentet fra. */
export function readSourceType(value: string): VocabularyTerm<SourceType> {
  return readTerm(SOURCE_TYPES, value)
}

/**
 * Hvordan funnet ble hentet ut. Sier hvordan raden ble til, ikke om den er
 * kontrollert: verifikasjon er en egen arbeidsflytregistrering, og generering
 * og verifikasjon skal ikke være samme operasjon (ANTIDEP_CONSTITUTION.md §10).
 */
export function readExtractionMethod(value: string): VocabularyTerm<ExtractionMethod> {
  return readTerm(EXTRACTION_METHODS, value)
}

/** Antideps forvaltningsstatus for et virkestoff. Ikke markedsstatus for et produkt. */
export function readDrugStatus(value: string): VocabularyTerm<DrugStatus> {
  return readTerm(DRUG_STATUSES, value)
}

/** Status for en oppføring i et kontrollert vokabular: i bruk eller utfaset. */
export function readVocabularyStatus(value: string): VocabularyTerm<VocabularyStatus> {
  return readTerm(VOCABULARY_STATUSES, value)
}

/**
 * Kildens status. En kilde kan trekkes tilbake etter at påstanden ble
 * publisert, og en klient skal vise det framfor å skjule det (§14). En ukjent
 * status må derfor aldri kunne falle sammen med `active`.
 */
export function readSourceStatus(value: string): VocabularyTerm<SourceStatus> {
  return readTerm(SOURCE_STATUSES, value)
}

/**
 * Hvilken representasjon av kilden ekstraksjonen faktisk bygde på. En ukjent
 * verdi må aldri kunne falle sammen med `full_text`: en flate som gjorde det,
 * ville framstilt et sammendrag som fulltekst (EVIDENCE_PIPELINE.md §13).
 */
export function readSourceRepresentation(value: string): VocabularyTerm<SourceRepresentation> {
  return readTerm(SOURCE_REPRESENTATIONS, value)
}

/**
 * Utfallet av en kontroll mot grunnlaget. En ukjent verdi må aldri kunne falle
 * sammen med `verified`: en flate som gjorde det, ville vist en kontroll som
 * bestått uten å vite at den var det (ANTIDEP_CONSTITUTION.md §11).
 */
export function readVerificationOutcome(value: string): VocabularyTerm<VerificationOutcome> {
  return readTerm(VERIFICATION_OUTCOMES, value)
}

/**
 * Resultatet av ett kontrollpunkt. Samme regel som over, og med samme skjerpelse
 * §6 krever: `not_assessable` er ikke `ok`, og en ukjent verdi er ingen av dem.
 */
export function readVerificationCheckResult(
  value: string,
): VocabularyTerm<VerificationCheckResult> {
  return readTerm(VERIFICATION_CHECK_RESULTS, value)
}

/** Hva kontrollen faktisk hadde tilgang til for grunnlaget den vurderte. */
export function readVerificationSourceAccess(
  value: string,
): VocabularyTerm<VerificationSourceAccess> {
  return readTerm(VERIFICATION_SOURCE_ACCESSES, value)
}

/**
 * Ett felt en ekstraksjonskontroll kan ha gått gjennom. En ukjent verdi må ikke
 * kunne falle sammen med et kjent felt: en flate som gjorde det, ville vist et
 * felt som kontrollert uten å vite hvilket (DATABASE_ARCHITECTURE.md §29).
 */
export function readEvidenceCheckField(value: string): VocabularyTerm<EvidenceCheckField> {
  return readTerm(EVIDENCE_CHECK_FIELDS, value)
}

/**
 * Hvorfor et felt har eller ikke har en verdi. En ukjent verdi må aldri kunne
 * falle sammen med `reported_value`: en flate som gjorde det, ville vist et
 * fravær som en registrert verdi (ANTIDEP_CONSTITUTION.md §6).
 */
export function readValueAvailability(value: string): VocabularyTerm<ValueAvailability> {
  return readTerm(VALUE_AVAILABILITIES, value)
}

/**
 * Kontrasten i selve funnet. `none` betyr at funnet gjelder én behandlingsarm,
 * ikke at komparatoren er ukjent, og en ukjent verdi er ingen av delene.
 */
export function readComparatorKind(value: string): VocabularyTerm<ComparatorKind> {
  return readTerm(COMPARATOR_KINDS, value)
}

/** Effektmålet kilden rapporterte. */
export function readEffectMeasure(value: string): VocabularyTerm<EffectMeasure> {
  return readTerm(EFFECT_MEASURES, value)
}

/** Enheten et estimat er oppgitt i. */
export function readEstimateUnit(value: string): VocabularyTerm<EstimateUnit> {
  return readTerm(ESTIMATE_UNITS, value)
}

/** Utfallet av en menneskelig reviewbeslutning. */
export function readReviewOutcome(value: string): VocabularyTerm<ReviewOutcome> {
  return readTerm(REVIEW_OUTCOMES, value)
}

/** Sikkerheten i kunnskapsgrunnlaget, slik evidensvurderingen graderer den. */
export function readCertaintyLevel(value: string): VocabularyTerm<CertaintyLevel> {
  return readTerm(CERTAINTY_LEVELS, value)
}

/** Vurderingen av ett GRADE-domene. `not_assessable` er ikke `not_serious`. */
export function readGradeDomainRating(value: string): VocabularyTerm<GradeDomainRating> {
  return readTerm(GRADE_DOMAIN_RATINGS, value)
}

// ----------------------------------------------------------------------------
// Relasjonen mellom funnet og påstanden
// ----------------------------------------------------------------------------

/**
 * Kontraktsbrudd på de to relasjonsaksene.
 *
 *   `unrecognised_relationship`  en relasjonstype utenfor vokabularet. Må aldri
 *                                falle sammen med `supports`: en klient som
 *                                gjør det, presenterer et motstridende funn som
 *                                støtte (§9).
 *   `unrecognised_directness`    en direkthetsverdi utenfor vokabularet.
 *   `indirect_relationship_claiming_directness`
 *                                relasjonen sier at funnets forhold til
 *                                påstanden bare kan bedømmes indirekte, mens
 *                                direktheten hevder det motsatte. Migrasjon 004
 *                                forbyr paret; de to sier forskjellige ting om
 *                                samme lenke.
 */
export type EvidenceStanceFault =
  | 'unrecognised_relationship'
  | 'unrecognised_directness'
  | 'indirect_relationship_claiming_directness'

export type EvidenceStance =
  | {
      readonly kind: 'known'
      readonly relationship: EvidenceRelationshipType
      readonly directness: EvidenceDirectness
    }
  | {
      readonly kind: 'unknown'
      readonly reason: EvidenceStanceFault
      readonly rawRelationship: string
      readonly rawDirectness: string
    }

/** Feltene relasjonsavledningen leser. `PublishedClaimEvidenceRow` oppfyller den. */
export interface EvidenceStanceInput {
  readonly relationship_type: string
  readonly directness: string
}

export function describeEvidenceStance(link: EvidenceStanceInput): EvidenceStance {
  const raw = {
    rawRelationship: link.relationship_type,
    rawDirectness: link.directness,
  } as const

  const relationship = readTerm(EVIDENCE_RELATIONSHIP_TYPES, link.relationship_type)
  if (relationship.kind === 'unknown') {
    return { kind: 'unknown', reason: 'unrecognised_relationship', ...raw }
  }
  const directness = readTerm(EVIDENCE_DIRECTNESS_VALUES, link.directness)
  if (directness.kind === 'unknown') {
    return { kind: 'unknown', reason: 'unrecognised_directness', ...raw }
  }
  if (relationship.value === 'indirect' && directness.value !== 'indirect') {
    return { kind: 'unknown', reason: 'indirect_relationship_claiming_directness', ...raw }
  }
  return { kind: 'known', relationship: relationship.value, directness: directness.value }
}

// ----------------------------------------------------------------------------
// Hvorfor en verdi finnes eller mangler
// ----------------------------------------------------------------------------

/** De to statusene der en verdi faktisk står i kolonnen (migrasjon 003). */
const PRESENT_AVAILABILITIES = ['reported_value', 'uncertain_extraction'] as const

/** Statusene der kolonnen skal være tom, hver med sin egen grunn. */
const ABSENT_AVAILABILITIES = [
  'not_measured',
  'not_reported',
  'not_applicable',
  'not_extractable',
] as const

/**
 * Hvorfor en verdi ikke står i kolonnen. Ingen av dem betyr null, og de betyr
 * ikke det samme: «ikke målt» er en egenskap ved studien, «ikke rapportert» ved
 * publikasjonen, «ikke aktuelt» ved funnet og «ikke uttrekkbar» ved
 * ekstraksjonen.
 */
export type AbsentAvailability = (typeof ABSENT_AVAILABILITIES)[number]

/**
 * Kontraktsbrudd på paret verdi/status.
 *
 *   `unrecognised_availability`  en status utenfor vokabularet. Må aldri falle
 *                                sammen med et registrert fravær: da ville en
 *                                ukjent grunn blitt til en kjent.
 *   `missing_value`              statusen sier at en verdi står her, og den gjør
 *                                det ikke.
 *   `unexpected_value`           statusen sier at kolonnen er tom, og det står
 *                                en verdi i den. Verdien vises ikke: den er
 *                                merket som noe kilden ikke oppgir.
 *   `incomplete_value`           et felt som består av flere ledd har bare noen
 *                                av dem. Halve verdien er ikke en verdi.
 *   `implausible_value`          verdien står, men kan ikke være det kolonnen
 *                                sier at den er — en utvalgsstørrelse på null,
 *                                et intervall med grensene i feil rekkefølge.
 *                                Vises ikke: den ville sett ut som et tall.
 */
export type AvailabilityFault =
  | 'unrecognised_availability'
  | 'missing_value'
  | 'unexpected_value'
  | 'incomplete_value'
  | 'implausible_value'

export type EvidenceValueState<Value> =
  /**
   * Kilden oppgir verdien. `uncertainExtraction` betyr at verdien er lest ut,
   * men at ekstraksjonen selv er usikker — verdien står, med forbehold.
   */
  | { readonly kind: 'reported'; readonly value: Value; readonly uncertainExtraction: boolean }
  /** Ingen verdi, med den registrerte grunnen. Aldri det samme som null. */
  | { readonly kind: 'absent'; readonly reason: AbsentAvailability }
  | {
      readonly kind: 'unknown'
      readonly reason: AvailabilityFault
      readonly rawAvailability: string
    }

type AvailabilityClass =
  | { readonly presence: 'present'; readonly uncertainExtraction: boolean }
  | { readonly presence: 'absent'; readonly reason: AbsentAvailability }

/**
 * Deler vokabularet i de to halvdelene migrasjon 003 faktisk skiller på.
 *
 * `null` for alt annet, med hensikt: en ny enum-verdi skal bli et synlig
 * kontraktsbrudd her, ikke stilltiende havne i «ikke rapportert». Listene er
 * derfor skrevet ut, ikke avledet av hverandre — en avledning ville gjort den
 * nye verdien til en av halvdelene uten at noen tok stilling til hvilken.
 */
function classifyAvailability(availability: string): AvailabilityClass | null {
  if ((PRESENT_AVAILABILITIES as readonly string[]).includes(availability)) {
    return { presence: 'present', uncertainExtraction: availability === 'uncertain_extraction' }
  }
  if ((ABSENT_AVAILABILITIES as readonly string[]).includes(availability)) {
    return { presence: 'absent', reason: availability as AbsentAvailability }
  }
  return null
}

/**
 * Ett felt, med sin status.
 *
 * Bare det ene leddet statusen faktisk gjelder. Feltene som består av flere ledd
 * — et tidsrom, et konfidensintervall — bygger den sammensatte verdien etterpå,
 * ut fra denne, slik at den er ferdig kontrollert i det den finnes. Alternativet,
 * en `complete`-tilbakekalling her, ville gitt kallerne en verditype med ledd som
 * i praksis aldri er tomme — altså grener ingen test kan nå, og en uprøvbar vakt
 * ser ut som et vern uten å være det.
 */
function describeEvidenceValue<Value>(
  availability: string,
  value: Value | null,
): EvidenceValueState<Value> {
  const classified = classifyAvailability(availability)
  if (classified === null) {
    return { kind: 'unknown', reason: 'unrecognised_availability', rawAvailability: availability }
  }
  if (classified.presence === 'absent') {
    return value === null
      ? { kind: 'absent', reason: classified.reason }
      : { kind: 'unknown', reason: 'unexpected_value', rawAvailability: availability }
  }
  if (value === null) {
    return { kind: 'unknown', reason: 'missing_value', rawAvailability: availability }
  }
  return { kind: 'reported', value, uncertainExtraction: classified.uncertainExtraction }
}

/** Et brudd på ett felt, med statusen som ble brutt. */
function availabilityFault(
  availability: string,
  reason: AvailabilityFault,
): EvidenceValueState<never> {
  return { kind: 'unknown', reason, rawAvailability: availability }
}

// ----------------------------------------------------------------------------
// De seks feltene som bærer en status
// ----------------------------------------------------------------------------

// Avledningene tar imot `string` og ikke den lukkede unionen fra
// `src/types/api.ts`, av samme grunn som `describeClaimCertainty()` gjør det:
// radtypen er en påstand om databasen, ikke en garanti. Tok de imot unionen,
// ville en verdi utenfor vokabularet vært en typefeil i testen framfor en
// tilstand koden faktisk håndterer — og kjøretidskontrollen ville vært
// uprøvbar.

/** Feltene populasjonsavledningen leser. */
export interface EvidencePopulationInput {
  readonly population_availability: string
  readonly population_label: string | null
}

/** Populasjonen funnet gjelder, slik katalogen navngir den. */
export function describeEvidencePopulation(
  row: EvidencePopulationInput,
): EvidenceValueState<string> {
  return describeEvidenceValue(row.population_availability, row.population_label)
}

/**
 * Utvalgsstørrelsen.
 *
 * Migrasjon 003 krever et positivt heltall. Kontrollen gjentas her fordi et
 * utvalg på 0 er nettopp den feilen §17 handler om: den ser ut som et tall og
 * leses som «ingen deltakere», mens den i praksis er en ødelagt rad.
 */
export interface EvidenceSampleSizeInput {
  readonly sample_size_availability: string
  readonly sample_size: number | null
}

export function describeEvidenceSampleSize(
  row: EvidenceSampleSizeInput,
): EvidenceValueState<number> {
  const state = describeEvidenceValue(row.sample_size_availability, row.sample_size)
  if (state.kind === 'reported' && !(Number.isInteger(state.value) && state.value > 0)) {
    return availabilityFault(row.sample_size_availability, 'implausible_value')
  }
  return state
}

/**
 * Måletidspunktet, som det paret databasen lagrer. Begge ledd, aldri ett: et
 * enslig ledd blir et brudd i avledningen framfor halve verdien her.
 */
export interface EvidenceTimepoint {
  readonly min: string
  readonly max: string
}

export interface EvidenceTimepointInput {
  readonly timepoint_availability: string
  readonly timepoint_min: string | null
  readonly timepoint_max: string | null
}

export function describeEvidenceTimepoint(
  row: EvidenceTimepointInput,
): EvidenceValueState<EvidenceTimepoint> {
  // Statusen gjelder `timepoint_min` (migrasjon 003), så tilstedeværelsen leses
  // av den. Den øvre grensen er paret med den, og et enslig ledd er et brudd.
  const state = describeEvidenceValue(row.timepoint_availability, row.timepoint_min)
  if (state.kind !== 'reported') {
    return state
  }
  if (row.timepoint_max === null) {
    return availabilityFault(row.timepoint_availability, 'incomplete_value')
  }
  return { ...state, value: { min: state.value, max: row.timepoint_max } }
}

/**
 * Konfidensintervallet, med nivået det gjelder på. Alle tre ledd, aldri færre:
 * «0,9 til 2,5» betyr forskjellige ting på 90 % og på 99 %, så et intervall uten
 * nivå er ikke et intervall.
 */
export interface EvidenceConfidenceInterval {
  readonly lower: number
  readonly upper: number
  readonly levelPercent: number
}

export interface EvidenceConfidenceIntervalInput {
  readonly confidence_interval_availability: string
  readonly ci_lower: number | null
  readonly ci_upper: number | null
  readonly ci_level_percent: number | null
}

/**
 * Konfidensintervallet.
 *
 * Aldri løsrevet fra sin egen status: et manglende intervall betyr upresist
 * grunnlag, ikke et presist estimat. Det er samme regel som at et tall på
 * påstandskortet aldri står uten komparatoren sin.
 */
export function describeEvidenceConfidenceInterval(
  row: EvidenceConfidenceIntervalInput,
): EvidenceValueState<EvidenceConfidenceInterval> {
  const availability = row.confidence_interval_availability
  // Statusen gjelder `ci_lower` (migrasjon 003); de to andre leddene er paret
  // med den.
  const state = describeEvidenceValue(availability, row.ci_lower)
  if (state.kind !== 'reported') {
    return state
  }
  if (row.ci_upper === null || row.ci_level_percent === null) {
    return availabilityFault(availability, 'incomplete_value')
  }
  if (row.ci_upper < state.value) {
    return availabilityFault(availability, 'implausible_value')
  }
  return {
    ...state,
    value: { lower: state.value, upper: row.ci_upper, levelPercent: row.ci_level_percent },
  }
}

// ----------------------------------------------------------------------------
// Estimatet
// ----------------------------------------------------------------------------

/** Kontraktsbrudd på estimatet: både statusen og selve størrelsen kan svikte. */
export type EvidenceEstimateFault = AvailabilityFault | ClaimMagnitudeFault

export type EvidenceEstimateState =
  /** Kilden oppgir et tolkbart estimat, med det målet og den enheten tallet krever. */
  | {
      readonly kind: 'quantified'
      readonly measure: EffectMeasure
      readonly value: number
      /** `null` bare for de dimensjonsløse målene, der en enhet ville vært feil. */
      readonly unit: EstimateUnit | null
      readonly uncertainExtraction: boolean
    }
  /**
   * Kilden oppgir ikke noe estimat, og sier hvorfor. Effektmålet kan likevel
   * være registrert — «kilden målte gjennomsnittsforskjell, men oppgir ikke
   * tallet» er et annet utsagn enn «kilden målte ingenting».
   */
  | {
      readonly kind: 'absent'
      readonly reason: AbsentAvailability
      readonly measure: EffectMeasure | null
    }
  | {
      readonly kind: 'unknown'
      readonly reason: EvidenceEstimateFault
      readonly rawAvailability: string
      readonly rawMeasure: string | null
      readonly rawValue: number | null
      readonly rawUnit: string | null
    }

function isEffectMeasure(value: string): value is EffectMeasure {
  return (EFFECT_MEASURES as readonly string[]).includes(value)
}

/** Feltene estimatavledningen leser. `PublishedClaimEvidenceRow` oppfyller den. */
export interface EvidenceEstimateInput {
  readonly estimate_availability: string
  readonly effect_measure: string | null
  readonly estimate: number | null
  readonly estimate_unit: string | null
}

/**
 * Estimatet, med statusen først og størrelsen etterpå.
 *
 * Rekkefølgen er ikke tilfeldig. Statusen avgjør om det i det hele tatt skal stå
 * et tall her, og bare når den sier ja, er størrelsesreglene fra
 * `claim-effect.ts` de riktige å bruke. Motsatt vei ville et felt merket «ikke
 * rapportert» blitt behandlet som en påstand som mangler tallet sitt.
 *
 * Komparatoren kommer inn som argument, av samme grunn som i
 * `describeClaimEffect()`: et kontrastivt effektmål uten komparator er ikke
 * tolkbart, og den regelen skal ikke ha to utgaver.
 */
export function describeEvidenceEstimate(
  row: EvidenceEstimateInput,
  comparator: ClaimComparatorState,
): EvidenceEstimateState {
  const raw = {
    rawAvailability: row.estimate_availability,
    rawMeasure: row.effect_measure,
    rawValue: row.estimate,
    rawUnit: row.estimate_unit,
  } as const

  const classified = classifyAvailability(row.estimate_availability)
  if (classified === null) {
    return { kind: 'unknown', reason: 'unrecognised_availability', ...raw }
  }

  if (classified.presence === 'absent') {
    if (row.estimate !== null) {
      return { kind: 'unknown', reason: 'unexpected_value', ...raw }
    }
    if (row.effect_measure === null) {
      // Enheten kan ikke stå alene: uten et mål sier «kg» ingenting om hva som
      // ble målt, og migrasjon 003 forbyr paret.
      if (row.estimate_unit !== null) {
        return { kind: 'unknown', reason: 'unit_on_dimensionless_measure', ...raw }
      }
      return { kind: 'absent', reason: classified.reason, measure: null }
    }
    if (!isEffectMeasure(row.effect_measure)) {
      return { kind: 'unknown', reason: 'unrecognised_measure', ...raw }
    }
    // Enhetsregelen gjelder også uten et tall: migrasjon 003 knytter enheten til
    // målet, ikke til estimatet.
    const pairing = describeMeasureUnit(row.effect_measure, row.estimate_unit)
    if (pairing.kind === 'unknown') {
      return { kind: 'unknown', reason: pairing.reason, ...raw }
    }
    return { kind: 'absent', reason: classified.reason, measure: row.effect_measure }
  }

  // Statusen sier at et tall står her. Da er det påstandskortets størrelsesregler
  // som gjelder, uendret: mål uten tall, tall uten mål, enhet mot mål, og mål mot
  // komparator.
  const magnitude = describeClaimMagnitude(
    {
      magnitude_measure: row.effect_measure,
      magnitude_value: row.estimate,
      magnitude_unit: row.estimate_unit,
    },
    comparator,
  )
  switch (magnitude.kind) {
    case 'quantified':
      return {
        kind: 'quantified',
        measure: magnitude.measure,
        value: magnitude.value,
        unit: magnitude.unit,
        uncertainExtraction: classified.uncertainExtraction,
      }
    case 'not_quantified':
      // Ingen av de tre feltene er utfylt, mens statusen lovet en verdi.
      // «Mangler» er da den presise grunnen, ikke noe om selve størrelsen.
      return { kind: 'unknown', reason: 'missing_value', ...raw }
    case 'unknown':
      return { kind: 'unknown', reason: magnitude.reason, ...raw }
  }
}

// ----------------------------------------------------------------------------
// Kilden
// ----------------------------------------------------------------------------

/**
 * Kontraktsbrudd på publiseringsdatoen.
 *
 *   `unrecognised_precision`  et presisjonsnivå utenfor vokabularet. Uten et
 *                             kjent nivå vet vi ikke hvor mye av datoen som er
 *                             ekte, og hele datoen ville vært falsk presisjon.
 *   `date_without_precision`  en dato uten presisjonsnivå. Samme konsekvens.
 *   `precision_without_date`  et presisjonsnivå uten dato.
 */
export type PublicationDateFault =
  'unrecognised_precision' | 'date_without_precision' | 'precision_without_date'

export type PublicationDateState =
  | { readonly kind: 'dated'; readonly date: string; readonly precision: DatePrecision }
  /** Ingen dato er registrert i Antidep. Ikke det samme som en udatert kilde. */
  | { readonly kind: 'undated' }
  | {
      readonly kind: 'unknown'
      readonly reason: PublicationDateFault
      readonly rawDate: string | null
      readonly rawPrecision: string | null
    }

/**
 * Publiseringsdatoen, aldri uten sin presisjon.
 *
 * Migrasjon 003 parer de to og avkorter datoen til nivået. En klient som viser
 * datoen uten nivået, gjør «2019» om til «1. januar 2019» — falsk presisjon som
 * ikke er synlig som feil, fordi den ser ut som en helt vanlig dato (§6).
 */
export function describePublicationDate(
  date: string | null,
  precision: string | null,
): PublicationDateState {
  const raw = { rawDate: date, rawPrecision: precision } as const

  if (date === null) {
    return precision === null
      ? { kind: 'undated' }
      : { kind: 'unknown', reason: 'precision_without_date', ...raw }
  }
  if (precision === null) {
    return { kind: 'unknown', reason: 'date_without_precision', ...raw }
  }
  const term = readTerm(DATE_PRECISIONS, precision)
  if (term.kind === 'unknown') {
    return { kind: 'unknown', reason: 'unrecognised_precision', ...raw }
  }
  return { kind: 'dated', date, precision: term.value }
}

// ----------------------------------------------------------------------------
// Kilden funnet står i
// ----------------------------------------------------------------------------

/**
 * Feltene kildeavledningen leser.
 *
 * Egen form framfor hele radtypen, av samme grunn som `EvidenceStanceInput`:
 * avledningen beskriver *kilden*, og skal ikke kunne komme til å lese et felt
 * som hører til funnet. `PublishedClaimEvidenceRow` oppfyller den strukturelt.
 */
export interface SourceDescriptionInput {
  readonly source_type: string
  readonly source_status: string
  readonly source_publication_date: string | null
  readonly source_publication_date_precision: string | null
}

/** De tre aksene som beskriver dokumentet, ikke funnet. */
export interface SourceDescription {
  readonly sourceType: VocabularyTerm<SourceType>
  readonly sourceStatus: VocabularyTerm<SourceStatus>
  readonly publicationDate: PublicationDateState
}

/**
 * Kilden, avledet.
 *
 * Skilt ut fordi to visninger trenger nøyaktig de samme tre aksene: hvert
 * evidensfunn viser kilden under seg, og kildesiden har den som emne
 * (PRODUCT_INFORMATION_ARCHITECTURE.md §42). To avledninger av samme rad ville
 * kunnet gi to svar på om en status er kjent.
 */
export function describeSource(source: SourceDescriptionInput): SourceDescription {
  return {
    sourceType: readSourceType(source.source_type),
    sourceStatus: readSourceStatus(source.source_status),
    publicationDate: describePublicationDate(
      source.source_publication_date,
      source.source_publication_date_precision,
    ),
  }
}

// ----------------------------------------------------------------------------
// Hele funnet
// ----------------------------------------------------------------------------

export interface EvidenceFinding {
  readonly stance: EvidenceStance
  readonly studyDesign: VocabularyTerm<StudyDesign>
  readonly population: EvidenceValueState<string>
  readonly sampleSize: EvidenceValueState<number>
  readonly timepoint: EvidenceValueState<EvidenceTimepoint>
  readonly reportedDirection: VocabularyTerm<ReportedDirection>
  /** Komparatoren funnet selv har. Intervensjonen er subjektet den måles mot. */
  readonly comparator: ClaimComparatorState
  readonly estimate: EvidenceEstimateState
  readonly confidenceInterval: EvidenceValueState<EvidenceConfidenceInterval>
  readonly sourceType: VocabularyTerm<SourceType>
  readonly sourceStatus: VocabularyTerm<SourceStatus>
  readonly publicationDate: PublicationDateState
}

/**
 * Alle aksene, avledet sammen. Dette er inngangen en visning skal bruke.
 *
 * De enkelte avledningene er eksportert for tester og for smalere bruk, men bare
 * her møtes beskrankningene som går på tvers — særlig at estimatet ikke kan
 * avgjøres uten komparatoren.
 */
export function describeEvidenceFinding(row: PublishedClaimEvidenceRow): EvidenceFinding {
  // Komparatoren først: estimatet kan ikke avgjøres uten den. Intervensjonen er
  // funnets eget subjekt, slik virkestoffet er påstandens.
  const comparator = describeClaimComparator({
    drug_id: row.intervention_drug_id,
    comparator_kind: row.comparator_kind,
    comparator_drug_id: row.comparator_drug_id,
    comparator_drug_name: row.comparator_drug_name,
  })

  return {
    stance: describeEvidenceStance(row),
    studyDesign: readStudyDesign(row.study_design),
    population: describeEvidencePopulation(row),
    sampleSize: describeEvidenceSampleSize(row),
    timepoint: describeEvidenceTimepoint(row),
    reportedDirection: readReportedDirection(row.reported_direction),
    comparator,
    estimate: describeEvidenceEstimate(row, comparator),
    confidenceInterval: describeEvidenceConfidenceInterval(row),
    // De tre siste — `sourceType`, `sourceStatus` og `publicationDate` — kommer
    // fra den delte kildeavledningen, slik at kildesiden og funnet ikke kan få
    // hvert sitt svar om samme rad.
    ...describeSource(row),
  }
}

/** Vokabularene modulen deler i to halvdeler, for kontroll i tester. */
export const AVAILABILITY_PARTITION = {
  present: PRESENT_AVAILABILITIES,
  absent: ABSENT_AVAILABILITIES,
  all: VALUE_AVAILABILITIES,
} as const
