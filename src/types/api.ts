// ============================================================================
// Radtyper for kontraktslaget `api`
//
// Speiler de elleve viewene migrasjon 007, 007a, 007b og 007d eksponerer:
//
//   api.published_drugs           virkestoff Antidep har publisert påstander om
//   api.published_claims          én rad per publisert påstand
//   api.published_claim_evidence  evidensgrunnlaget bak hver påstand
//   api.my_actor                  kallerens egen aktørrad, eller ingen rad
//   api.my_roles                  kallerens egne rolletildelinger som gjelder nå
//   api.editor_sources            kildene et evidensfunn kan knyttes til
//   api.editor_source_versions    øyeblikksbildene under hver kilde
//   api.editor_drugs              virkestoffene i katalogen
//   api.editor_outcomes           de kliniske begrepene som er endepunkter
//   api.editor_populations        populasjonene i katalogen
//   api.editor_evidence_items     evidensfunnene som er registrert
//
// De tre første er publisert innhold og lesbare for `anon`. De åtte siste er
// lesbare bare for `authenticated`, og de er ikke en del av klinikerflaten: de
// finnes for adminflyten (MVP_IMPLEMENTATION_PLAN.md §29). `my_*` svarer på
// hvem kalleren er, `editor_*` på hva det finnes å registrere mot.
//
// Kilden er migrasjonene, ikke denne filen. Kolonnekommentarene i
// `supabase/migrations/20260820140000_api_published_read_model.sql`,
// `20260821143000_api_publication_timestamps.sql`,
// `20260828090000_api_caller_authorization.sql` og
// `20260904091000_editor_registration_read_model.sql` er den normative
// beskrivelsen av hva hver verdi betyr; her gjentas bare det en klient må
// vite for ikke å lese en verdi feil.
//
// ----------------------------------------------------------------------------
// Hvorfor noen vokabularer er lukkede unioner og andre bare er `string`
//
// Enum-verdiene castes til text i viewene med hensikt: kontrakten er en streng
// fra et dokumentert vokabular, ikke PostgreSQL-typen. En lukket union i
// TypeScript er derfor en påstand om databasen som ingenting her håndhever, og
// en ny enum-verdi ville gjort typen usann uten at noe feilet.
//
// Linjen er trukket etter klinisk konsekvens, ikke etter hva som er praktisk:
//
//   Lukket union der klienten forgrener på verdien, og der en uventet verdi
//   som faller i feil gren ville vært klinisk feil — kunnskapstype (§5),
//   sikkerhetsgrad (§6, §17), påstandens retning (§17), komparator og
//   effektmål (§4, §6), relasjon til evidensen og dens direkthet (§9), hvorfor
//   en verdi mangler (§17), retningen kilden selv rapporterer (§5),
//   studiedesign og dokumenttype (§4) og kildestatus (§14). Presisjonen på en
//   publiseringsdato hører også hit: en `year`-presis dato vist som en hel dato
//   er falsk presisjon (§6).
//
//   Dokumentert `string` ellers. Å promotere et vokabular til union hører til
//   den PR-en som faktisk forgrener på det.
//
// En lukket union alene fanger ingenting i kjøretid, og det er kjøretids-
// kontrollen som gjør en ukjent verdi til en eksplisitt ukjent tilstand framfor
// en godartet gren. Kontrollene ligger i avledningene:
//
//   claim-certainty.ts   kunnskapstype, sikkerhetsgrad
//   claim-effect.ts      påstandens retning, komparator, effektmål, enhet
//   evidence-item.ts     relasjonstype, direkthet, `*_availability`,
//                        rapportert retning, studiedesign, dokumenttype,
//                        kildestatus, datopresisjon, ekstraksjonsmetode,
//                        virkestoffstatus, vokabularstatus
//
// Alle vokabularene som i dag er lukkede unioner her, har dermed en
// kjøretidskontroll. Et nytt vokabular skal ikke promoteres til union uten at
// den PR-en som forgrener på det, legger til kontrollen samtidig.
//
// Et vokabular er det samme uansett hvilken rad det står i, så komparator,
// effektmål og enhet er lukket på evidensradene også. Avledningene i
// `claim-effect.ts` tar imot `string | null` nettopp for at `evidence-item.ts`
// skal kunne gjenbruke dem uten å endre dem.
//
// `tests/api-vocabularies.test.ts` kontrollerer at hver lukket union her er
// nøyaktig den enum-en migrasjonene definerer.
//
// Paragrafhenvisninger er til docs/ANTIDEP_CONSTITUTION.md der ikke annet står.
// ============================================================================

// ----------------------------------------------------------------------------
// Radtypene er `type`, ikke `interface`, og det er ikke en stilpreferanse
//
// supabase-js krever at hver Row oppfyller `Record<string, unknown>` for at
// schemaet skal gjenkjennes. Et interface har ingen implisitt indekssignatur og
// oppfyller den ikke; et type-alias gjør det. Skrives de om til interface,
// forkastes hele Database-typen stille og hver spørring gir `never[]` — som er
// tilordnbart til alt, så typecheck fortsetter å passere mens typene ikke
// lenger betyr noe. Kompileringsvakten i
// `src/lib/published-read-model.test.ts` finnes for å fange nettopp det.
// ----------------------------------------------------------------------------

/** Databasegenerert uuid. Aldri et navn og aldri en ekstern kode. */
export type Uuid = string

/** `timestamptz`, slik PostgREST serialiserer den: ISO 8601 med tidssone. */
export type Timestamptz = string

/** `date`, slik PostgREST serialiserer den: `YYYY-MM-DD`. */
export type DateText = string

/** `interval`, slik PostgREST serialiserer den. Ikke et tall, og ikke en dato. */
export type IntervalText = string

// ----------------------------------------------------------------------------
// Lukkede vokabularer
// ----------------------------------------------------------------------------

/**
 * De tre kunnskapstypene. Ulik epistemisk status og ulike valideringskrav; en
 * klient skal ikke presentere dem likt (§5).
 */
export const KNOWLEDGE_TYPES = [
  'deterministic_fact',
  'evidence_synthesis',
  'clinical_recommendation',
] as const
export type KnowledgeType = (typeof KNOWLEDGE_TYPES)[number]

/**
 * GRADE-sikkerhet. Merk at `no_assessable_evidence` er en vurdert tilstand og
 * ikke en lav gradering: grunnlaget er vurdert og lar seg ikke gradere, og
 * `evidence_gap` er da utfylt (§6, §17).
 */
export const CERTAINTY_LEVELS = [
  'high',
  'moderate',
  'low',
  'very_low',
  'no_assessable_evidence',
] as const
export type CertaintyLevel = (typeof CERTAINTY_LEVELS)[number]

/**
 * Antideps vurdering av hvordan et evidensfunn forholder seg til påstanden.
 * `contradicts` skal vises på lik linje med `supports` (§9).
 */
export const EVIDENCE_RELATIONSHIP_TYPES = [
  'supports',
  'partially_supports',
  'contradicts',
  'neutral_contextual',
  'indirect',
] as const
export type EvidenceRelationshipType = (typeof EVIDENCE_RELATIONSHIP_TYPES)[number]

/**
 * Hvorfor en verdi eventuelt mangler. Finnes nettopp for at en tom verdi aldri
 * skal kunne leses som en nullverdi (§17): et manglende estimat er ikke et
 * estimat på null, og et manglende konfidensintervall betyr upresist grunnlag.
 */
export const VALUE_AVAILABILITIES = [
  'reported_value',
  'not_measured',
  'not_reported',
  'not_applicable',
  'not_extractable',
  'uncertain_extraction',
] as const
export type ValueAvailability = (typeof VALUE_AVAILABILITIES)[number]

/**
 * Kildens status. En kilde kan trekkes tilbake etter at påstanden ble
 * publisert; en klient skal vise det framfor å skjule det (§14).
 */
export const SOURCE_STATUSES = [
  'active',
  'outdated',
  'superseded',
  'retracted',
  'withdrawn',
] as const
export type SourceStatus = (typeof SOURCE_STATUSES)[number]

/**
 * Om et evidensfunn treffer påstandens populasjon, endepunkt, komparator og
 * tidsrom direkte, eller bare indirekte. Egen akse fra `relationship_type`, slik
 * at et indirekte funn som *motsier* påstanden kan uttrykkes (migrasjon 004).
 */
export const EVIDENCE_DIRECTNESS_VALUES = ['direct', 'indirect'] as const
export type EvidenceDirectness = (typeof EVIDENCE_DIRECTNESS_VALUES)[number]

/**
 * Studiedesignet for det konkrete evidensfunnet, ikke for dokumentet. Én kilde
 * kan rapportere ulike design for ulike utfall, så designet hører til funnet
 * (migrasjon 003).
 */
export const STUDY_DESIGNS = ['randomized_controlled_trial'] as const
export type StudyDesign = (typeof STUDY_DESIGNS)[number]

/**
 * Hva slags dokument kilden er. Egen akse fra studiedesign: en retningslinje og
 * en preparatomtale leses ikke som en primærstudie, og forskjellen er klinisk
 * (migrasjon 003).
 */
export const SOURCE_TYPES = [
  'journal_article',
  'clinical_guideline',
  'summary_of_product_characteristics',
  'regulatory_communication',
  'public_dataset',
] as const
export type SourceType = (typeof SOURCE_TYPES)[number]

/**
 * Hvor presist en publiseringsdato faktisk er kjent. Datoen lagres avkortet til
 * presisjonsnivået, så en klient som viser hele datoen for en `year`-presis dato
 * viser falsk presisjon (§6).
 */
export const DATE_PRECISIONS = ['year', 'month', 'day'] as const
export type DatePrecision = (typeof DATE_PRECISIONS)[number]

/**
 * Hvordan et evidensfunn ble hentet ut (migrasjon 003). Sier hvordan raden ble
 * til, ikke om den er kontrollert: verifikasjon er en egen arbeidsflyt-
 * registrering, og generering og verifikasjon skal ikke være samme operasjon
 * (§10). Lukket fordi den redaksjonelle listen forgrener på verdien, og fordi
 * en manuell ekstraksjon og en KI-assistert har ulik epistemisk status (§5, §12).
 */
export const EXTRACTION_METHODS = ['manual', 'ai_assisted', 'deterministic_import'] as const
export type ExtractionMethod = (typeof EXTRACTION_METHODS)[number]

/**
 * Antideps forvaltningsstatus for et virkestoff. Ikke markedsstatus for et
 * norsk produkt. Lukket fordi registreringsskjemaet forgrener på den: et
 * virkestoff som ikke lenger er i bruk skal merkes i valglisten framfor å se
 * ut som alle andre.
 */
export const DRUG_STATUSES = ['active', 'historical', 'withdrawn'] as const
export type DrugStatus = (typeof DRUG_STATUSES)[number]

/**
 * Status for en oppføring i et kontrollert vokabular: `deprecated` betyr at den
 * ikke skal brukes i nytt innhold, men beholdes fordi eksisterende innhold
 * peker på den. Utfasing er en statusendring, ikke en sletting. Lukket av samme
 * grunn som virkestoffstatusen.
 */
export const VOCABULARY_STATUSES = ['active', 'deprecated'] as const
export type VocabularyStatus = (typeof VOCABULARY_STATUSES)[number]

/**
 * Retningen én kilde selv rapporterer for utfallet.
 *
 * Ikke det samme vokabularet som påstandens `direction`, og de to må ikke slås
 * sammen: dette har den fjerde verdien `not_stated`, og en påstand er Antideps
 * syntese på tvers av grunnlaget — en annen epistemisk status (§5). Slått
 * sammen ville «kilden oppgir ingen retning» og «Antidep konkluderer med ingen
 * klar forskjell» kunne bytte plass.
 *
 * `no_clear_difference` er også her et resultat, ikke et fravær av data: kilden
 * har sett etter en forskjell og ikke funnet en klar en. Kolonnen er NOT NULL
 * nettopp for at nullfunnet ikke skal kunne kollapse til NULL sammen med «ikke
 * rapportert» og «ikke målt» (§6).
 */
export const REPORTED_DIRECTIONS = [
  'increase',
  'decrease',
  'no_clear_difference',
  'not_stated',
] as const
export type ReportedDirection = (typeof REPORTED_DIRECTIONS)[number]

/**
 * Retningen en påstand selv konkluderer med.
 *
 * Vokabularet er bevisst ikke det samme som retningen én kilde rapporterer på
 * et evidensfunn (`reported_direction`). Det har en fjerde verdi, `not_stated`,
 * og en påstand er Antideps syntese på tvers av grunnlaget — en annen epistemisk
 * status (§5). Å behandle de to som samme vokabular ville latt «kilden oppgir
 * ingen retning» og «Antidep konkluderer med ingen klar forskjell» bytte plass.
 *
 * `no_clear_difference` er et resultat: grunnlaget viser ingen klar forskjell.
 * Det er noe annet enn at retningen ikke er angitt (NULL) og noe annet enn at
 * evidensen ikke lar seg vurdere (`certainty_level`). Ingen av dem betyr ingen
 * effekt eller ingen risiko (§17).
 */
export const CLAIM_DIRECTIONS = ['increase', 'decrease', 'no_clear_difference'] as const
export type ClaimDirection = (typeof CLAIM_DIRECTIONS)[number]

/**
 * Hva en påstand eller et evidensfunn sammenlignes mot. `none` betyr at det
 * ikke finnes en komparator — ikke at komparatoren er ukjent. Uten komparator
 * er en effektstørrelse ikke tolkbar (§19 i
 * PRODUCT_INFORMATION_ARCHITECTURE.md), så en klient som viser et tall må vise
 * denne verdien med det.
 */
export const COMPARATOR_KINDS = ['drug', 'placebo', 'none'] as const
export type ComparatorKind = (typeof COMPARATOR_KINDS)[number]

/**
 * Effektmålet en tallverdi er uttrykt i. Vokabularet er lukket fordi målet
 * avgjør hva tallet betyr: 1,7 som `mean_difference` er en gjennomsnittsforskjell
 * i en enhet, mens 1,7 som `odds_ratio` er dimensjonsløst og har 1 som
 * nullpunkt. Et tall uten sitt mål er ikke tolkbart, og et tall med feil mål er
 * klinisk feil.
 */
export const EFFECT_MEASURES = [
  'mean_change',
  'mean_difference',
  'standardised_mean_difference',
  'risk_ratio',
  'odds_ratio',
] as const
export type EffectMeasure = (typeof EFFECT_MEASURES)[number]

/**
 * Enheten et dimensjonalt estimat er uttrykt i. Påkrevd for `mean_change` og
 * `mean_difference`, og forbudt for de dimensjonsløse målene (migrasjon 004).
 * Uten enhet er et vekttall klinisk tvetydig.
 */
export const ESTIMATE_UNITS = ['kg', 'percent'] as const
export type EstimateUnit = (typeof ESTIMATE_UNITS)[number]

/**
 * Utfallet av en kontroll av en påstand eller en ekstraksjon mot grunnlaget
 * (`workflow.verification_outcome`). `uncertain` er ikke et mildere `verified`:
 * det er en kontroll som ikke lot seg konkludere, og publiseringsgaten
 * blokkerer på den nøyaktig som på et avvik (ANTIDEP_CONSTITUTION.md §6, §11).
 */
/**
 * Hva slags representasjon av en kilde som faktisk ble hentet og lest
 * (`knowledge.source_representation`). Vokabularet er EVIDENCE_PIPELINE.md §13
 * sin egen liste, ord for ord.
 *
 * Verdien beskriver hva *ekstraksjonen* bygger på. Hva en senere kontrollør
 * hadde tilgang til, er `VERIFICATION_SOURCE_ACCESSES`, og de to er
 * forskjellige opplysninger: en kliniker med fulltekst kan kontrollere en
 * ekstraksjon som ble laget av et sammendrag.
 */
export const SOURCE_REPRESENTATIONS = [
  'full_text',
  'abstract',
  'registry_record',
  'regulatory_summary',
  'secondary_report',
  'other_limited',
] as const
export type SourceRepresentation = (typeof SOURCE_REPRESENTATIONS)[number]

export const VERIFICATION_OUTCOMES = [
  'verified',
  'needs_correction',
  'rejected',
  'uncertain',
] as const
export type VerificationOutcome = (typeof VERIFICATION_OUTCOMES)[number]

/**
 * Resultatet av ett enkelt kontrollpunkt (`workflow.verification_check_result`).
 * `not_assessable` er ikke det samme som `ok`: et punkt som ikke lot seg
 * bedømme er nettopp den usikkerheten §11 skal fram i lyset, og en bekreftelse
 * krever at alle punktene er `ok`.
 */
export const VERIFICATION_CHECK_RESULTS = ['ok', 'deviation', 'not_assessable'] as const
export type VerificationCheckResult = (typeof VERIFICATION_CHECK_RESULTS)[number]

/**
 * Hva kontrollen faktisk hadde tilgang til
 * (`workflow.verification_source_access`). Rekkefølgen er fra sterkest til
 * svakest, og den er ikke kosmetisk: en samlet kontroll er aldri sterkere enn
 * sitt svakeste ledd, og et sammendrag laget av et annet ledd kan ikke bære en
 * bekreftelse (ANTIDEP_CONSTITUTION.md §11).
 */
export const VERIFICATION_SOURCE_ACCESSES = [
  'original_source',
  'verifiable_representation',
  'derived_summary',
] as const
export type VerificationSourceAccess = (typeof VERIFICATION_SOURCE_ACCESSES)[number]

/**
 * Feltene en ekstraksjonskontroll kan ha gått gjennom
 * (`workflow.evidence_check_field`). Rekkefølgen er den samme som i databasen,
 * og den er ikke kosmetisk: den følger kolonnene på et evidensfunn, slik at en
 * flate som lister dem, lister dem i samme rekkefølge som raden er bygget.
 *
 * `availability_semantics` er ikke et felt på raden, men kontrollen av at
 * `not_measured`, `not_reported`, `not_extractable` og `uncertain_extraction` er
 * brukt riktig — en av de enkleste måtene en ekstraksjon kan være feil på uten
 * at noe tall ser galt ut (ANTIDEP_CONSTITUTION.md §6).
 */
export const EVIDENCE_CHECK_FIELDS = [
  'population',
  'sample_size',
  'intervention_arm',
  'comparator_arm',
  'outcome',
  'timepoint',
  'reported_direction',
  'effect_measure',
  'estimate',
  'confidence_interval',
  'availability_semantics',
  'limitations',
  'source_locator',
  'raw_extraction',
] as const
export type EvidenceCheckField = (typeof EVIDENCE_CHECK_FIELDS)[number]

/**
 * Utfallet av en menneskelig reviewbeslutning (`workflow.review_outcome`). De
 * tre første gjelder en publiseringsgodkjenning; de to siste gjelder en
 * beslutning om en ekstraksjon, og hører til en annen skrivevei.
 */
export const REVIEW_OUTCOMES = [
  'approved',
  'rejected',
  'changes_requested',
  'extraction_withdrawn',
  'extraction_upheld',
] as const
export type ReviewOutcome = (typeof REVIEW_OUTCOMES)[number]

/**
 * Vurderingen av ett GRADE-domene (`knowledge.grade_domain_rating`).
 * `not_assessable` betyr at domenet ikke lot seg vurdere — ikke at det er
 * uproblematisk (ANTIDEP_CONSTITUTION.md §6).
 */
export const GRADE_DOMAIN_RATINGS = [
  'not_serious',
  'serious',
  'very_serious',
  'not_assessable',
] as const
export type GradeDomainRating = (typeof GRADE_DOMAIN_RATINGS)[number]

// ----------------------------------------------------------------------------
// api.published_drugs
// ----------------------------------------------------------------------------

/** Ett virkestoff Antidep har minst én publisert påstand om. */
export type PublishedDrugRow = {
  drug_id: Uuid
  canonical_name: string
  /**
   * Antideps forvaltningsstatus for virkestoffet. Et virkestoff som ikke lenger
   * er i bruk kan ha publiserte påstander, så verdien skal ikke leses som at
   * kunnskapen er trukket tilbake.
   */
  status: DrugStatus
  /**
   * ATC-koder på femte nivå, sortert. Array fordi et virkestoff kan ha flere.
   * `null` betyr at ingen kode er registrert i Antidep — ikke at virkestoffet
   * mangler en.
   */
  atc_codes: string[] | null
  /** Talt over det RLS-filtrerte settet, så tallet er kallerens egen visning. */
  published_claim_count: number
}

// ----------------------------------------------------------------------------
// api.published_claims
// ----------------------------------------------------------------------------

/** Én publisert påstand, i den revisjonen publiseringspekeren peker på. */
export type PublishedClaimRow = {
  /** Stabil identitet på tvers av revisjoner. Bruk denne til lenker (§7). */
  claim_id: Uuid
  /** Den eksakte publiserte revisjonen. Endrer seg ved hver publisering. */
  claim_revision_id: Uuid
  revision_number: number
  knowledge_type: KnowledgeType

  drug_id: Uuid
  drug_name: string
  topic_concept_id: Uuid
  topic_label: string

  statement: string
  scope: string

  /** `null` betyr uavgrenset til en registrert populasjon, ikke ukjent populasjon. */
  population_id: Uuid | null
  population_label: string | null
  /** `null` betyr at revisjonen ikke er avgrenset i tid. */
  timeframe_min: IntervalText | null
  timeframe_max: IntervalText | null
  /** Uten komparator er en effektstørrelse ikke tolkbar. */
  comparator_kind: ComparatorKind
  comparator_drug_id: Uuid | null
  comparator_drug_name: string | null

  /**
   * `null` betyr at revisjonen ikke angir retning — ikke at retningen er
   * nøytral og ikke at det ikke er noen forskjell (§17). Bruk
   * `describeClaimEffect()` framfor å forgrene her.
   */
  direction: ClaimDirection | null
  magnitude_measure: EffectMeasure | null
  /** `null` betyr at effekten ikke er kvantifisert, ikke at den er null (§17). */
  magnitude_value: number | null
  magnitude_unit: EstimateUnit | null

  qualifiers: string | null
  /** Alltid utfylt for evidenssynteser og kliniske anbefalinger (§6). */
  uncertainty_summary: string | null

  certainty_framework: string | null
  /**
   * `null` hvis og bare hvis `knowledge_type` er `deterministic_fact`: ingen
   * GRADE-vurdering gjelder for typen. Det er en annen tilstand enn
   * `no_assessable_evidence`, og ingen av dem betyr lav risiko eller ingen
   * effekt (§6, §17). Bruk `describeClaimCertainty()` framfor å forgrene her.
   */
  certainty_level: CertaintyLevel | null
  certainty_rationale: string | null
  /** Alltid utfylt når `certainty_level` er `no_assessable_evidence`. */
  evidence_gap: string | null
  /** Siste evidensvurdering. `null` for deterministiske fakta. */
  last_assessed_at: Timestamptz | null

  /**
   * Antall evidenslenker der ekstraksjonen er trukket tilbake etter
   * publisering. Normalt 0. Over 0 betyr at Antidep har underkjent deler av
   * grunnlaget under en påstand som fortsatt står publisert, og påstanden skal
   * ikke presenteres som uberørt.
   */
  withdrawn_evidence_count: number

  /** Databaseeid avtrykk av revisjonens kliniske innhold. Egnet som cachenøkkel. */
  content_hash: string
  /** Da revisjonen ble skrevet. Verken publisert eller faglig vurdert. */
  revision_created_at: Timestamptz
  /**
   * Da revisjonen som står publisert nå, ble publisert. `null` betyr ukjent
   * publiseringsdato — ikke at påstanden er upublisert, og skal ikke vises som
   * en fersk dato.
   */
  published_at: Timestamptz | null
  /**
   * Sist faglig vurdert: den menneskelige godkjenningen publiseringen hviler
   * på (§12). Finnes for alle kunnskapstyper, også deterministiske fakta.
   * `null` betyr ukjent, aldri «ikke vurdert» og aldri «nylig vurdert».
   */
  last_reviewed_at: Timestamptz | null
}

// ----------------------------------------------------------------------------
// api.published_claim_evidence
// ----------------------------------------------------------------------------

/**
 * Én evidenslenke på en publisert revisjon, med funnet og kilden under.
 * Settet er komplett med hensikt: støttende, motstridende, nøytrale og
 * indirekte lenker står side om side, og en klient skal ikke filtrere bort de
 * motstridende (§9).
 */
export type PublishedClaimEvidenceRow = {
  claim_id: Uuid
  claim_revision_id: Uuid
  claim_evidence_link_id: Uuid

  relationship_type: EvidenceRelationshipType
  /** Egen akse fra `relationship_type`: `direct` eller `indirect`. */
  directness: EvidenceDirectness
  relevance_note: string

  evidence_item_id: Uuid
  /** Designet for dette funnet, ikke for dokumentet det står i. */
  study_design: StudyDesign

  population_id: Uuid | null
  population_label: string | null
  population_detail: string
  population_availability: ValueAvailability
  sample_size: number | null
  sample_size_availability: ValueAvailability

  intervention_drug_id: Uuid
  intervention_drug_name: string
  intervention_detail: string | null
  comparator_kind: ComparatorKind
  comparator_drug_id: Uuid | null
  comparator_drug_name: string | null
  comparator_detail: string | null

  outcome_concept_id: Uuid
  outcome_label: string
  outcome_detail: string
  timepoint_min: IntervalText | null
  timepoint_max: IntervalText | null
  timepoint_availability: ValueAvailability

  /**
   * Retningen kilden selv rapporterer, fra `knowledge.effect_direction` — et
   * annet vokabular enn påstandens `direction`, med den fjerde verdien
   * `not_stated`. Antideps egen vurdering av funnet ligger i
   * `relationship_type`.
   */
  reported_direction: ReportedDirection
  effect_measure: EffectMeasure | null
  estimate: number | null
  estimate_unit: EstimateUnit | null
  estimate_availability: ValueAvailability
  ci_lower: number | null
  ci_upper: number | null
  ci_level_percent: number | null
  confidence_interval_availability: ValueAvailability

  limitations_text: string | null
  /** Hvor i kilden funnet står. Uten den er verifikasjon mot originalen upraktisk (§16). */
  source_locator: string

  /**
   * Aldri `null`. `true` betyr at funnet er underkjent og ikke lenger står som
   * gyldig evidens, selv om påstanden over det fortsatt er publisert. Et slikt
   * funn merkes, det skjules ikke (§14).
   */
  extraction_withdrawn: boolean
  extraction_withdrawn_at: Timestamptz | null
  extraction_withdrawal_rationale: string | null

  /** `null` betyr at ingen versjon er registrert — ikke at kilden er uendret. */
  source_version_id: Uuid | null
  source_version_retrieved_at: Timestamptz | null
  source_version_retrieved_from: string | null
  source_version_external_version: string | null
  source_version_content_hash: string | null

  source_id: Uuid
  source_type: SourceType
  source_title: string
  source_authors_or_issuer: string
  source_publisher_or_journal: string | null
  /**
   * Alltid avkortet til presisjonen under. `null` hvis og bare hvis presisjonen
   * er `null` (migrasjon 003), og betyr at ingen dato er registrert.
   */
  source_publication_date: DateText | null
  /** Hvor mye av datoen over som faktisk er kjent. Uten den er datoen falsk presisjon. */
  source_publication_date_precision: DatePrecision | null
  source_status: SourceStatus
  source_status_note: string | null
  /** Sorterte arrays: kildemodellen tillater flere, og ingen er definert som primær. */
  source_dois: string[] | null
  source_pmids: string[] | null
}

// ----------------------------------------------------------------------------
// Kallerens eget (migrasjon 007b)
//
// De to radtypene under beskriver ikke publisert kunnskap, men den innloggede
// brukerens egen aktør og egne rettigheter. `anon` har ingen SELECT på noen av
// viewene, så et kall uten sesjon gir avslag og ikke et tomt svar.
// ----------------------------------------------------------------------------

/**
 * Aktørraden som er knyttet til den innloggede brukerkontoen.
 *
 * Viewet gir null eller én rad. **Ingen rad betyr «ingen aktør er knyttet til
 * kontoen», ikke «kalleren er ukjent»**: en brukerkonto kan finnes før noen har
 * registrert en aktør for den, og en menneskelig aktør kan registreres før
 * kontoen finnes. En klient som viser noe annet enn nettopp det, hevder mer enn
 * viewet sier.
 *
 * Aktørtypen er ikke med: bare et menneske kan ha en brukerkonto
 * (`actors_auth_user_is_human_check`), så feltet ville hatt én mulig verdi.
 */
export type MyActorRow = {
  /** Aktørens stabile identitet, og den verdien skriveoperasjoner attribueres til. */
  actor_id: Uuid
  /** Maskinlesbar, språkuavhengig og stabil nøkkel på formen «type:navn». */
  actor_key: string
  /** Visningsnavn. Presentasjon, ikke identitet — det kan endres. */
  display_name: string
  /**
   * Tidspunktet aktøren ble tatt ut av bruk, eller `null`.
   *
   * En tilbaketrukket aktør beholder historikken sin, men kan ikke utføre nye
   * handlinger — publiseringsoperasjonen avviser den. En klient som ignorerer
   * verdien vil vise rettigheter kalleren ikke får brukt.
   */
  retired_at: Timestamptz | null
}

/**
 * Én rolletildeling som gjelder **nå** for den innloggede brukeren.
 *
 * Viewet filtrerer på det halvåpne intervallet `[valid_from, valid_to)`, målt
 * med `statement_timestamp()`. En avsluttet tildeling og en som først begynner
 * å gjelde senere er begge fraværende, og et tomt svar betyr «ingen rettighet
 * nå» — det skiller ikke en utløpt tildeling fra en som aldri fantes.
 *
 * Radene er ikke autorisasjonen selv. Skriveoperasjonene kontrollerer
 * rettigheten på nytt på sitt eget tidspunkt, og en klient som lar noe avhenge
 * av innholdet her, viser en forventning — den avgjør ingenting.
 */
export type MyRoleRow = {
  /**
   * Applikasjonsrollen, som tekst: `editor`, `reviewer`, `publisher` eller
   * `admin`. De er forskjellige rettigheter — `admin` er bruker- og
   * systemforvaltning og gir ingen faglig godkjenningsrett — og skal ikke slås
   * sammen i visningen.
   *
   * Bevisst ikke en lukket union ennå. Regelen over i denne filen er at et
   * vokabular promoteres av den PR-en som faktisk forgrener på det, og som
   * samtidig legger til kjøretidskontrollen; ingen klientkode leser dette feltet
   * i dag. `string` er dessuten den tryggere typen for en klient som ennå ikke
   * finnes: den tvinger fram et default-tilfelle framfor å invitere til en
   * `switch` som antar at listen er uttømmende.
   */
  role_code: string
  /**
   * Det kliniske begrepet tildelingen er avgrenset til, eller `null` for en
   * uavgrenset tildeling. `null` betyr «uten avgrensning», ikke «ukjent
   * avgrensning». Etiketten er ikke eksponert.
   */
  scope_id: Uuid | null
  /**
   * Hva `scope_id` peker på, eller `null` når tildelingen er uavgrenset. De to
   * er alltid `null` sammen eller utfylt sammen.
   *
   * Feltet finnes for at en klient skal kunne se at en tildeling *er* avgrenset
   * uten å kunne slå opp begrepet: en avgrenset rettighet lest som uavgrenset
   * er den farligste retningen å ta feil i.
   */
  scope_type: string | null
  /** Tidspunktet tildelingen begynte å gjelde. Alltid i fortiden for en rad som vises. */
  valid_from: Timestamptz
  /**
   * Tidspunktet tildelingen opphører, eller `null` når ingen sluttdato er satt.
   *
   * En verdi her er en planlagt utløpsdato som ennå ikke har inntruffet — raden
   * vises jo — og ikke en tilbakekalling som allerede har virket.
   */
  valid_to: Timestamptz | null
}

// ----------------------------------------------------------------------------
// Den redaksjonelle lesemodellen (migrasjon 007d)
//
// Seks views som ikke beskriver publisert kunnskap, men hva en editor kan velge
// mellom når et evidensfunn skal registreres — og hva som allerede er
// registrert. `anon` har ingen SELECT på noen av dem, så et kall uten sesjon
// gir avslag og ikke et tomt svar.
//
// Radgrensen er RLS: en editor ser hele registeret, en annen innlogget kaller
// ser bare det som allerede er publisert. Et tomt svar betyr derfor «du ser
// ingenting her», ikke «det finnes ingenting».
// ----------------------------------------------------------------------------

/** Én kilde et evidensfunn kan knyttes til. */
export type EditorSourceRow = {
  /** Kildens stabile identitet, og verdien `api.create_evidence_item` tar imot. */
  source_id: Uuid
  source_type: SourceType
  title: string
  authors_or_issuer: string
  publisher_or_journal: string | null
  /** Alltid avkortet til presisjonen under. `null` betyr at ingen dato er registrert. */
  publication_date: DateText | null
  /** Hvor mye av datoen over som faktisk er kjent. Uten den er datoen falsk presisjon (§6). */
  publication_date_precision: DatePrecision | null
  /**
   * En `retracted` eller `withdrawn` kilde skal ikke stille passere som en
   * normal kilde i en valgliste (§14).
   */
  source_status: SourceStatus
  /** `null` betyr «ingen begrunnelse er registrert», ikke «statusen er normal». */
  status_note: string | null
}

/** Ett registrert øyeblikksbilde av én kilde. */
export type EditorSourceVersionRow = {
  source_version_id: Uuid
  source_id: Uuid
  /** Da representasjonen ble hentet. Et hendelsestidspunkt, ikke registreringstidspunktet. */
  retrieved_at: Timestamptz
  /** Adressen som ble hentet og hashet, slik at hashen kan reproduseres. */
  retrieved_from: string
  /** `null` betyr at kilden ikke eksponerer noe versjonsmerke, ikke at versjonen er ukjent. */
  external_version: string | null
  /** `null` betyr at det ikke ble hashet noe øyeblikksbilde. */
  content_hash: string | null
}

/** Ett virkestoff i katalogen, som intervensjon eller komparator. */
export type EditorDrugRow = {
  drug_id: Uuid
  canonical_name: string
  status: DrugStatus
}

/** Ett klinisk begrep av typen endepunkt. Begreper av andre typer står ikke her. */
export type EditorOutcomeRow = {
  outcome_concept_id: Uuid
  canonical_label: string
  status: VocabularyStatus
}

/** Én populasjon i katalogen. Etiketten er et håndtak, ikke gyldighetsgrensen selv. */
export type EditorPopulationRow = {
  population_id: Uuid
  canonical_label: string
  status: VocabularyStatus
}

/**
 * Ett registrert evidensfunn, med kilden det hører til.
 *
 * Bevisst uten estimat, konfidensintervall, utvalgsstørrelse og tidsrom: de
 * fire bærer hver sin `*_availability`, og et tall vist uten sin status er
 * falsk presisjon (§6, §17). Den visningen finnes i evidensdrilldownen
 * (`PublishedClaimEvidenceRow`). Formålet her er gjenkjenning.
 */
export type EditorEvidenceItemRow = {
  evidence_item_id: Uuid
  source_id: Uuid
  source_title: string
  /** `null` betyr at funnet ikke er knyttet til et registrert øyeblikksbilde. */
  source_version_id: Uuid | null
  /** Designet for dette funnet, ikke for dokumentet det står i. */
  study_design: StudyDesign
  intervention_drug_id: Uuid
  intervention_drug_name: string
  /** `none` betyr at funnet er armspesifikt, ikke at komparatoren er ukjent. */
  comparator_kind: ComparatorKind
  /** `null` når kontrasten ikke er et virkestoff. Da sier `comparator_kind` hva den er. */
  comparator_drug_id: Uuid | null
  comparator_drug_name: string | null
  outcome_label: string
  outcome_detail: string
  /** Retningen kilden selv rapporterer. Ikke Antideps vurdering. */
  reported_direction: ReportedDirection
  source_locator: string
  /** Hvordan raden ble til. Sier ikke om den er kontrollert. */
  extraction_method: ExtractionMethod
  created_at: Timestamptz
}
