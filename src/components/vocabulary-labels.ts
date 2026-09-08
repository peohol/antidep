// ============================================================================
// Vokabularene fra `api`, oversatt til norsk
//
// Ett sted, fordi de samme verdiene står i flere rader og i flere visninger.
// `magnitude_measure` på en publisert påstand er Antideps syntese,
// `effect_measure` på et evidensfunn er det kilden målte; målet betyr likevel
// nøyaktig det samme — en oddsratio er en oddsratio uansett hvilken rad den står
// i — og to oversettelser av samme vokabular ville før eller siden drevet fra
// hverandre og latt de to radene se ut som forskjellige størrelser. Det samme
// gjelder kildens dokumenttype og status, som nå står både på hvert evidensfunn
// og på kildesiden (PRODUCT_INFORMATION_ARCHITECTURE.md §42).
//
// Oversettelsen ligger her, og det gjør også `termText()`: gjengivelsen av en
// term som *ikke* lot seg kjenne igjen er en del av oversettelsen, og den må
// være den samme overalt. Hva en verdi *betyr*, og hvordan det avgjøres om den
// er kjent, hører fortsatt hjemme i avledningene (`claim-effect.ts`,
// `evidence-item.ts`); en oppslagstabell er ingen kjøretidskontroll, og en
// `Record` over en lukket union kan ikke slå opp en verdi utenfor den.
// ============================================================================

import type { EvidenceStance, VocabularyTerm } from '../lib/evidence-item'
import type {
  CertaintyLevel,
  ComparatorKind,
  DrugStatus,
  EffectMeasure,
  EstimateUnit,
  EvidenceCheckField,
  EvidenceRelationshipType,
  ExtractionMethod,
  GradeDomainRating,
  KnowledgeType,
  ReportedDirection,
  ReviewOutcome,
  SourceStatus,
  SourceType,
  StudyDesign,
  ValueAvailability,
  VerificationCheckResult,
  VerificationOutcome,
  VerificationSourceAccess,
  VocabularyStatus,
} from '../types/api'

/**
 * En vokabularverdi, oversatt — eller sagt at den er ukjent, aldri gjettet.
 *
 * Råverdien skrives ut sammen med meldingen. Uten den ville en klient som møter
 * en ny enum-verdi bare kunne si «ukjent», og den som skal rette feilen måtte
 * lete i databasen etter hva som faktisk stod der.
 */
export function termText<Term extends string>(
  term: VocabularyTerm<Term>,
  labels: Record<Term, string>,
  what: string,
): string {
  return term.kind === 'known' ? labels[term.value] : `Ukjent ${what} («${term.raw}»)`
}

export const KNOWLEDGE_TYPE_LABELS: Record<KnowledgeType, string> = {
  deterministic_fact: 'Deterministisk faktum',
  evidence_synthesis: 'Evidensbasert syntese',
  clinical_recommendation: 'Klinisk anbefaling',
}

export const MEASURE_LABELS: Record<EffectMeasure, string> = {
  mean_change: 'Gjennomsnittlig endring',
  mean_difference: 'Gjennomsnittsforskjell',
  standardised_mean_difference: 'Standardisert gjennomsnittsforskjell (SMD)',
  risk_ratio: 'Relativ risiko (RR)',
  odds_ratio: 'Oddsratio (OR)',
}

export const UNIT_LABELS: Record<EstimateUnit, string> = {
  kg: 'kg',
  percent: '%',
}

/**
 * Antideps vurdering av hvordan ett evidensfunn forholder seg til påstanden.
 *
 * Formulert som utsagn om påstanden, ikke som etiketter: «Støtter» alene ville
 * ikke sagt hva funnet støtter.
 *
 * Bevisst ikke eksportert. Oppslaget går gjennom `stanceText()`, som tar imot
 * den avledede relasjonen og ikke råverdien — da finnes det ingen vei der en
 * relasjon Antidep ikke kjenner, kan slå opp som noe annet enn ukjent, og et
 * motstridende funn kan ikke presenteres som støtte (ANTIDEP_CONSTITUTION.md §9).
 */
const RELATIONSHIP_LABELS: Record<EvidenceRelationshipType, string> = {
  supports: 'Støtter påstanden',
  partially_supports: 'Støtter deler av påstanden',
  contradicts: 'Motsier påstanden',
  neutral_contextual: 'Verken for eller mot påstanden',
  indirect: 'Bare indirekte bedømbart mot påstanden',
}

/**
 * Relasjonen ett funn har til påstanden, som tekst.
 *
 * Den ukjente tilstanden har sin egen setning og deler ingen ordlyd med de fem
 * kjente. Begge visningene som viser et funn — evidensvisningen og kildesiden —
 * bruker denne, slik at «motsier påstanden» ikke kan bli til noe annet det ene
 * stedet (§9). Hvorfor relasjonen ikke lot seg tolke, hører til
 * evidensvisningen, som har plass til hele forklaringen.
 */
export function stanceText(stance: EvidenceStance): string {
  return stance.kind === 'known'
    ? RELATIONSHIP_LABELS[stance.relationship]
    : 'Antideps vurdering av dette funnet er ikke tolkbar'
}

/** Hva slags dokument kilden er. Egen akse fra studiedesignet funnet er hentet fra. */
export const SOURCE_TYPE_LABELS: Record<SourceType, string> = {
  journal_article: 'Fagfellevurdert artikkel',
  clinical_guideline: 'Klinisk retningslinje',
  summary_of_product_characteristics: 'Preparatomtale (SPC)',
  regulatory_communication: 'Regulatorisk melding',
  public_dataset: 'Offentlig datasett',
}

/**
 * Kildestatusene, formulert som utsagn om dokumentet. `active` skrives ut som
 * alle de andre: en status som bare vises når den er avvikende, gjør fravær av
 * merking til en påstand ingen har tatt stilling til.
 */
export const SOURCE_STATUS_LABELS: Record<SourceStatus, string> = {
  active: 'I bruk',
  outdated: 'Utdatert, uten at en bestemt etterfølger er registrert',
  superseded: 'Erstattet av en nyere kilde',
  retracted: 'Trukket tilbake av tidsskrift eller utgiver',
  withdrawn: 'Tatt ut av bruk av utgiveren',
}

/**
 * Studiedesignet for ett funn. Ligger på funnet og ikke på dokumentet: én
 * publikasjon kan rapportere flere design.
 */
export const STUDY_DESIGN_LABELS: Record<StudyDesign, string> = {
  randomized_controlled_trial: 'Randomisert kontrollert studie',
}

/**
 * Retningen kilden selv rapporterer. `not_stated` er den fjerde verdien
 * påstandens eget retningsvokabular ikke har, og formuleringen sier eksplisitt
 * at det er kilden som ikke oppgir noe — ikke at det ikke ble funnet noe.
 */
export const REPORTED_DIRECTION_LABELS: Record<ReportedDirection, string> = {
  increase: 'Kilden rapporterer en økning',
  decrease: 'Kilden rapporterer en reduksjon',
  no_clear_difference: 'Kilden fant ingen klar forskjell',
  not_stated: 'Kilden oppgir ingen retning',
}

/**
 * Hvorfor et felt har eller ikke har en verdi.
 *
 * De fire fraværsgrunnene er egenskaper ved forskjellige ting — studien,
 * publikasjonen, funnet, ekstraksjonen — og ingen av dem betyr null
 * (ANTIDEP_CONSTITUTION.md §6, DATABASE_ARCHITECTURE.md §19.1). De to første er
 * tilstandene der en verdi faktisk står i kolonnen.
 *
 * Samme oppslag brukes av visningen av et funn og av registreringsskjemaet.
 * Det er hele grunnen til at det står her: to oversettelser av samme vokabular
 * ville før eller siden latt «ikke målt» og «ikke rapportert» bytte plass i den
 * ene av dem.
 */
export const VALUE_AVAILABILITY_LABELS: Record<ValueAvailability, string> = {
  reported_value: 'Kilden oppgir verdien',
  uncertain_extraction: 'Verdien er lest ut, men ekstraksjonen er usikker',
  not_measured: 'Ikke målt i studien',
  not_reported: 'Ikke rapportert i kilden',
  not_applicable: 'Ikke aktuelt for dette funnet',
  not_extractable: 'Står i kilden, men lar seg ikke lese entydig ut',
}

/**
 * Kontrasten i selve funnet. `none` betyr at funnet gjelder én behandlingsarm,
 * ikke at komparatoren er ukjent — uten den forskjellen ville et armspesifikt
 * funn og et funn med ukjent sammenligning sett like ut.
 */
export const COMPARATOR_KIND_LABELS: Record<ComparatorKind, string> = {
  drug: 'Et annet virkestoff',
  placebo: 'Placebo',
  none: 'Ingen komparator: funnet gjelder én behandlingsarm',
}

/**
 * Hvordan et evidensfunn ble hentet ut. Formuleringene sier hvem eller hva som
 * laget raden, ikke om den er kontrollert (ANTIDEP_CONSTITUTION.md §10, §12).
 */
export const EXTRACTION_METHOD_LABELS: Record<ExtractionMethod, string> = {
  manual: 'Registrert manuelt',
  ai_assisted: 'KI-assistert ekstraksjon',
  deterministic_import: 'Maskinell import fra strukturert kilde',
}

/**
 * Antideps forvaltningsstatus for et virkestoff, ikke markedsstatus for et
 * norsk produkt.
 */
export const DRUG_STATUS_LABELS: Record<DrugStatus, string> = {
  active: 'I bruk',
  historical: 'Historisk',
  withdrawn: 'Utgått',
}

/** Status for en oppføring i et kontrollert vokabular. */
/**
 * De sju kontrollpunktene i en claim-verifikasjon, i den rekkefølgen
 * DATABASE_ARCHITECTURE.md §30 lister dem, med spørsmålet hvert punkt faktisk
 * svarer på. Rekkefølgen er kontraktens og ikke visningens: en flate som stokket
 * om på dem, ville vist en annen kontroll enn den som er registrert.
 */
export const CLAIM_CHECKPOINTS = [
  {
    key: 'sourceSupport',
    label: 'Kildestøtte',
    question: 'Støtter det registrerte grunnlaget faktisk ordlyden i påstanden?',
  },
  {
    key: 'populationMatch',
    label: 'Populasjon',
    question: 'Svarer populasjonen påstanden gjelder for til den grunnlaget dekker?',
  },
  {
    key: 'comparatorMatch',
    label: 'Komparator',
    question: 'Er komparatoren i påstanden den samme som i grunnlaget?',
  },
  {
    key: 'timeframeMatch',
    label: 'Tidsrom',
    question: 'Er tidsrommet i påstanden dekket av grunnlaget?',
  },
  {
    key: 'directionAndMagnitude',
    label: 'Retning og størrelse',
    question: 'Er retning og eventuelle tallstørrelser gjengitt riktig, uten falsk presisjon?',
  },
  {
    key: 'qualifiersComplete',
    label: 'Forbehold',
    question: 'Mangler det vesentlige forbehold i påstanden?',
  },
  {
    key: 'contradictoryEvidenceRepresented',
    label: 'Motstridende evidens',
    question: 'Finnes det relevant motstridende evidens som ikke er representert?',
  },
] as const

export type ClaimCheckpointKey = (typeof CLAIM_CHECKPOINTS)[number]['key']

export const VERIFICATION_OUTCOME_LABELS: Record<VerificationOutcome, string> = {
  verified: 'Bekreftet',
  needs_correction: 'Må rettes',
  rejected: 'Avvist',
  uncertain: 'Uavklart',
}

export const VERIFICATION_CHECK_RESULT_LABELS: Record<VerificationCheckResult, string> = {
  ok: 'Holder',
  deviation: 'Avvik',
  // Ikke «ukjent» og ikke «ikke relevant»: punktet ble forsøkt bedømt og lot seg
  // ikke bedømme, og det er en registrert usikkerhet (ANTIDEP_CONSTITUTION.md §6).
  not_assessable: 'Lot seg ikke bedømme',
}

export const VERIFICATION_SOURCE_ACCESS_LABELS: Record<VerificationSourceAccess, string> = {
  original_source: 'Originalkilden',
  verifiable_representation: 'Etterprøvbar representasjon',
  derived_summary: 'Sammendrag fra et annet ledd',
}

/**
 * Feltene en ekstraksjonskontroll kan ha gått gjennom, som det kliniske
 * innholdet de faktisk dekker — ikke som kolonnenavn. En reviewer skal kunne
 * lese listen som «hva har jeg faktisk sammenlignet mot kilden?», og
 * `availability_semantics` er nettopp det punktet som er lettest å hoppe over:
 * det gjelder ikke en verdi, men begrunnelsen for at en verdi mangler.
 */
export const EVIDENCE_CHECK_FIELD_LABELS: Record<EvidenceCheckField, string> = {
  population: 'Populasjonen funnet gjelder',
  sample_size: 'Antall deltakere',
  intervention_arm: 'Behandlingsarmen',
  comparator_arm: 'Sammenligningsarmen',
  outcome: 'Endepunktet',
  timepoint: 'Tidspunktet målingen gjelder',
  reported_direction: 'Retningen kilden rapporterer',
  effect_measure: 'Effektmålet',
  estimate: 'Selve estimatet',
  confidence_interval: 'Konfidensintervallet',
  availability_semantics: 'Begrunnelsen for felter uten verdi',
  limitations: 'Forbeholdene',
  source_locator: 'Hvor i kilden funnet står',
  raw_extraction: 'Den rå ekstraksjonen, ordrett',
}

export const REVIEW_OUTCOME_LABELS: Record<ReviewOutcome, string> = {
  approved: 'Godkjent for publisering',
  rejected: 'Avslått',
  changes_requested: 'Endringer bedt om',
  extraction_withdrawn: 'Ekstraksjon trukket tilbake',
  extraction_upheld: 'Ekstraksjon opprettholdt',
}

export const CERTAINTY_LEVEL_LABELS: Record<CertaintyLevel, string> = {
  high: 'Høy sikkerhet',
  moderate: 'Moderat sikkerhet',
  low: 'Lav sikkerhet',
  very_low: 'Svært lav sikkerhet',
  // En egen systemtilstand, ikke bunnen av skalaen (ANTIDEP_CONSTITUTION.md §6).
  no_assessable_evidence: 'Ingen vurderbar evidens',
}

export const GRADE_DOMAIN_LABELS: Record<GradeDomainRating, string> = {
  not_serious: 'Ikke alvorlig',
  serious: 'Alvorlig',
  very_serious: 'Svært alvorlig',
  not_assessable: 'Lot seg ikke vurdere',
}

export const VOCABULARY_STATUS_LABELS: Record<VocabularyStatus, string> = {
  active: 'I bruk',
  deprecated: 'Utfaset',
}
