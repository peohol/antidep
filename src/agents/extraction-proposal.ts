// ============================================================================
// Ekstraksjonsforslaget: den permanente grensen mellom forslagsleddet og Antidep
//
// Et forslag er ikke en ekstraksjon. Det er inndata til den, og det blir en
// ekstraksjon først når det er registrert gjennom `api.register_agent_extraction`
// innenfor en åpen agentkjøring — med hvert utdrag prøvd ordrett mot den
// representasjonen som faktisk ble hentet (`extraction-run.ts`).
//
// ----------------------------------------------------------------------------
// Hvorfor forslaget er sin egen modul, og leses fra en fil
//
// Leddet som *leser* en artikkel og foreslår strukturerte verdier, er en
// modelloperasjon. Alt det andre i kjeden er deterministisk og skal ikke ligge
// i den samme prosessen: hentingen, den ordrette kontrollen av hvert utdrag,
// kjøringens proveniens og selve registreringen.
//
// Forslaget er derfor grenseflaten mellom de to, og den er skrevet for å være
// permanent (ANTIDEP_CONSTITUTION.md §20). Formen er den samme enten den er
// skrevet av et menneske, av ChatGPT utenfor Antidep, eller av modell-leddet i
// `drafting-run.ts` — og den kontrolleres like strengt uansett hvem som skrev
// den. Et nytt modelladapter er derfor et nytt ledd foran denne filen, ikke en
// endring av den.
//
// ----------------------------------------------------------------------------
// Hva forslagsprodusenten *ikke* kan
//
// Den kan ikke skrive til databasen. Den produserer en fil; alt som rører basen
// skjer etterpå, i kjøringen, med agentlegitimasjon og under de deterministiske
// kontrollene. Det er ikke en konvensjon, men en konsekvens av at forslaget er
// data: det finnes ingen skrivevei som tar imot et forslag.
//
// ----------------------------------------------------------------------------
// Hvorfor forslaget sier hvem som laget det
//
// `generated_by` er et krav og ikke en opplysning. `provenance.agent_runs`
// krever leverandør, modell, modellversjon og promptmalversjon for hver
// kjøring, og uten feltet ville kjøringen måttet oppgi en fast verdi for alle
// forslag — altså registrert et menneskes ekstraksjon som en modells, og
// omvendt (ANTIDEP_CONSTITUTION.md §14, §20, EVIDENCE_PIPELINE.md §65).
//
// `producer` er den ene opplysningen som ikke kan utledes av de andre: om det
// var en modell eller et menneske som leste artikkelen. Den avgjør
// `knowledge.evidence_items.extraction_method`, og den avgjør hva kontrolløren
// faktisk holder på med — å etterprøve et maskinutkast er noe annet enn å
// etterprøve en kollegas arbeid (§12).
//
// Feltet er en *erklæring* fra den som skrev filen, på samme måte som
// kildeversjonen og utdragene er det. Databasen kan ikke kontrollere hvilken
// modell som skrev en fil, men den kan kreve at påstanden står der og bevares.
//
// ----------------------------------------------------------------------------
// Hvorfor formen kontrolleres her og ikke bare av databasen
//
// Databasen er fasiten, og dens avvisninger propageres uendret. Men en
// agentkjøring som sender et halvferdig forslag, ville fått en fremmednøkkel-
// eller castingfeil ut av `api`, og feilen ville pekt på en kolonne framfor på
// det som faktisk mangler i forslaget. Kontrollen her sier hvilket felt i
// forslaget som er galt, før noe skrives.
//
// Disiplinen — ukjent felt er en feil, ingenting fylles inn, vokabularene er
// lukket — er `strict-fields.ts`, og deles med oppdraget og modellopptaket.
// Vokabularene leses fra `src/types/api.ts`, som `tests/api-vocabularies.test.ts`
// holder identisk med enum-ene i migrasjonene.
//
// Utrygg inndata: forslaget er data, aldri instruksjoner (CLAUDE.md). Ingenting
// i det tolkes som noe annet enn verdier og tekst.
// ============================================================================

import {
  COMPARATOR_KINDS,
  EFFECT_MEASURES,
  ESTIMATE_UNITS,
  EVIDENCE_CHECK_FIELDS,
  REPORTED_DIRECTIONS,
  STUDY_DESIGNS,
  VALUE_AVAILABILITIES,
  type ExtractionMethod,
  type Uuid,
} from '../types/api.ts'
import {
  asOptionalInteger,
  asOptionalNumericText,
  asOptionalText,
  asOptionalUuid,
  asOptionalVocabulary,
  asText,
  asUuid,
  asVocabulary,
  fieldsOf,
  isCalendarTimestamp,
  nestedFields,
  problem,
  raw,
  rejectUnknown,
  type Fields,
} from './strict-fields.ts'

/** Hva filen heter i en avvisning. */
const PROPOSAL_SUBJECT = 'Ekstraksjonsforslaget'

/**
 * Versjonen av selve kontrakten, oppgitt i hvert forslag.
 *
 * Uten den ville en senere utvidelse av formen ikke kunnet skilles fra et
 * forslag skrevet mot en eldre form: begge ville manglet det samme feltet, og
 * bare det ene ville vært en feil. Verdien er et *krav*, ikke en opplysning —
 * et forslag som oppgir noe annet, avvises.
 *
 * `@2` la til `generated_by`. Et `@1`-forslag oppgir ikke hvem som laget det,
 * og kan derfor ikke registreres med riktige premisser; det er en form som er
 * ute, ikke en form som leses med standardverdier.
 */
export const EXTRACTION_PROPOSAL_VERSION = 'antidep/extraction-proposal@2'

/**
 * Hvem som leste artikkelen og foreslo verdiene.
 *
 * To verdier, og skillet er epistemisk og ikke teknisk: et maskinutkast er et
 * forslag som venter på faglig kontroll, mens et menneskes ekstraksjon er et
 * fagarbeid som fortsatt skal kontrolleres uavhengig
 * (ANTIDEP_CONSTITUTION.md §10, §12).
 */
export const PROPOSAL_PRODUCERS = ['model', 'human'] as const
export type ProposalProducer = (typeof PROPOSAL_PRODUCERS)[number]

/**
 * Hvor kort et ordrett kildeutdrag kan være og fortsatt bære kontekst.
 *
 * Et utdrag er kontrollgrunnlaget et menneske ser på venstre side i
 * kontrolløkten, og «284» eller «8 weeks» alene er ikke et grunnlag: tallet står
 * kanskje fem steder i artikkelen, og utdraget sier ikke hvilket. Grensen er den
 * samme som `MIN_QUOTE_LENGTH` i `extraction-checks.ts` bruker for at et sitat
 * skal være verdt å kontrollere ordrett, og av samme grunn.
 */
export const MIN_SOURCE_EXCERPT_LENGTH = 24

/** Én forankring: feltet, utdraget, pekeren og begrunnelsen. */
export interface ProposedGrounding {
  readonly checkField: string
  readonly sourceExcerpt: string
  readonly sourceLocator: string
  readonly justification: string
}

/** De strukturerte verdiene forslaget påstår om studien. */
export interface ProposedExtraction {
  readonly designCode: string
  readonly populationId: Uuid | null
  readonly populationAvailability: string
  readonly populationDetail: string
  readonly sampleSize: number | null
  readonly sampleSizeAvailability: string
  readonly interventionDrugId: Uuid
  readonly interventionDetail: string | null
  readonly comparatorKind: string
  readonly comparatorDrugId: Uuid | null
  readonly comparatorDetail: string | null
  readonly outcomeConceptId: Uuid
  readonly outcomeDetail: string
  readonly timepointMin: string | null
  readonly timepointMax: string | null
  readonly timepointAvailability: string
  readonly reportedDirection: string
  readonly effectMeasure: string | null
  readonly estimate: string | null
  readonly estimateUnit: string | null
  readonly estimateAvailability: string
  readonly ciLower: string | null
  readonly ciUpper: string | null
  readonly ciLevelPercent: string | null
  readonly confidenceIntervalAvailability: string
  readonly limitationsText: string | null
  readonly sourceLocator: string
  readonly sourceQuote: string | null
}

/**
 * Erklæringen om hvem som laget forslaget, og når.
 *
 * Erklæringen beskriver *utkastet*, ikke registreringen av det. De to er
 * forskjellige operasjoner på forskjellige tidspunkter — utkastet lages
 * utenfor Antidep, registreringen skjer når noen kjører kommandoen — og
 * erklæringen føres derfor i registreringskjøringens `input_manifest`, som er
 * kolonnen for hva kjøringen fikk inn. Premissekolonnene på
 * `provenance.agent_runs` beskriver kjøringen selv (`pipeline-version.ts`).
 *
 * Pipelineversjonen står bevisst ikke her: den er Antideps egen, og et forslag
 * utenfra skal ikke kunne påstå noe om hvilken pipeline som registrerte det.
 */
export interface GeneratedBy {
  readonly producer: ProposalProducer
  readonly provider: string
  readonly model: string
  readonly modelVersion: string
  readonly promptTemplateVersion: string
  /**
   * Da utkastet ble laget — ikke da det ble registrert.
   *
   * Uten det ville det eneste tidspunktet i proveniensen vært
   * registreringskjøringens `started_at`, som kan ligge dager etter at modellen
   * faktisk leste artikkelen. «Hva ble kjørt når» ville da vært ubesvarlig for
   * nettopp den operasjonen det gjelder (EVIDENCE_PIPELINE.md §65).
   */
  readonly draftedAt: string
  /**
   * Fingeravtrykket av forespørselen modellen svarte på, når det finnes.
   *
   * Det dekker representasjonen, katalogen i oppdraget og promptmalen, og er
   * derfor den ene verdien som gjør en modellkjøring identifiserbar i ettertid.
   * `null` for et menneskeskrevet forslag: der finnes ingen forespørsel.
   */
  readonly requestDigest: string | null
}

/**
 * De to delene et modell-ledd faktisk produserer.
 *
 * Kildebindingen står ikke her, med vilje. Modellen får representasjonen og
 * skal lese verdier ut av den; hvilken kildeversjon representasjonen *er*, er
 * oppdragets opplysning og settes av kjøringen (`drafting-run.ts`). En modell
 * som kunne oppgitt kildebindingen selv, kunne oppgitt feil kildebinding — og
 * feilen ville vært usynlig, fordi utdragene ville stått ordrett i den teksten
 * den faktisk fikk.
 */
export interface ExtractionDraft {
  readonly extraction: ProposedExtraction
  readonly fieldGroundings: readonly ProposedGrounding[]
}

/** Hele forslaget: kontraktsversjonen, opphavet, hvilken kilde, verdiene og forankringen. */
export interface ExtractionProposal extends ExtractionDraft {
  readonly proposalVersion: typeof EXTRACTION_PROPOSAL_VERSION
  readonly generatedBy: GeneratedBy
  readonly sourceId: Uuid
  readonly sourceVersionId: Uuid
  /**
   * Adressen kildeversjonen ble hentet fra, og fingeravtrykket den ble
   * registrert med.
   *
   * Begge står i forslaget fordi agenten ikke kan lese
   * `knowledge.source_versions` — den har ingen editor-rolle, og lesetilgangen
   * er ikke gitt til agentroller. Kjøringen henter adressen på nytt og krever
   * at fingeravtrykket stemmer, slik at utdragene prøves mot nøyaktig den
   * utgaven ekstraksjonen skal peke på.
   *
   * Skulle et forslag oppgi feil fingeravtrykk, blir ekstraksjonen likevel
   * fanget: den deterministiske ekstraksjonskontrollen henter kildeversjonens
   * *egen* adresse og sammenligner med dens *egen* hash, og uten den kan ingen
   * menneskelig bekreftelse registreres (migrasjon 005x).
   */
  readonly retrievedFrom: string
  readonly contentHash: string
}

const CONTENT_HASH_PATTERN = /^sha256:[0-9a-f]{64}$/

/**
 * Ekstraksjonsmetoden et forslag fra denne produsenten blir registrert med.
 *
 * Oversettelsen står her, ved siden av vokabularet den oversetter, og ikke i
 * kjøreren: `knowledge.extraction_method` er en egenskap ved *hvordan raden ble
 * til*, og det er nøyaktig det `producer` sier. To steder som oversatte hver
 * for seg, ville vært to steder å registrere et menneskes arbeid som en
 * modells.
 */
export function extractionMethodFor(producer: ProposalProducer): ExtractionMethod {
  return producer === 'model' ? 'ai_assisted' : 'manual'
}

// ----------------------------------------------------------------------------
// Registreringsmodusen: den tiltrodde halvdelen av «hvem laget dette»
//
// `producer` avgjør `knowledge.evidence_items.extraction_method`, og den er
// ikke pynt: migrasjon 005ab innførte feltet nettopp for at en kontrollør skal
// vite om hen etterprøver et maskinutkast eller en kollegas arbeid, og verdien
// inngår i evidensfunnets identitet (ANTIDEP_CONSTITUTION.md §8, §12, §14).
//
// Feltet står i forslaget, og forslaget er utrygg inndata: det har vært innom
// en økt som leste en artikkel Antidep ikke kontrollerer, og som har skall.
// Lot registreringen filen alene avgjøre verdien, kunne et maskinutkast blitt
// ført som et menneskes arbeid ved å endre ett ord — og kontrolløren ville lest
// raden som noe annet enn den er.
//
// Den tiltrodde halvdelen er hvilken *modus* kalleren registrerte under, og de
// to modusene er de to reelle arbeidsformene:
//
//   * med oppdrag    — modell-leddets flyt. Oppdraget finnes fordi en modell
//                      ikke skal velge fritt i katalogen.
//   * uten oppdrag   — en redaktørs egen ekstraksjon ut av en fulltekst. Det
//                      finnes ikke noe oppdrag, fordi avgrensningen *er* det
//                      faglige arbeidet.
//
// Erklæringen i filen beholdes likevel, og må stemme. En modus som bare
// overstyrte feltet, ville skjult at noen hadde endret det; et avvik skal si
// fra.
// ----------------------------------------------------------------------------

/**
 * Hvilken arbeidsform registreringen ble kjørt under. Kallerens valg, og
 * påkrevd: uten den ville forslaget selv avgjort hva det ble registrert som.
 *
 *   `with_assignment`    modell-leddets flyt. Oppdraget følger med, og
 *                        avgrensningen mot katalogen kontrolleres.
 *   `without_assignment` en redaktørs egen ekstraksjon ut av en fulltekst.
 *                        Det finnes ikke noe oppdrag, fordi avgrensningen *er*
 *                        det faglige arbeidet.
 *   `unchecked_model`    et modellforslag uten oppdrag. Det er en reell
 *                        tilstand for forslag laget før oppdragene fantes, og
 *                        for et utkast ChatGPT skrev utenfor Antidep. Raden
 *                        føres som KI-assistert — den er det — og kjøringen
 *                        fører at avgrensningen ikke ble kontrollert.
 */
export type RegistrationMode = 'with_assignment' | 'without_assignment' | 'unchecked_model'

/**
 * Produsenten en modus beskriver.
 *
 * To av tre modi er en modells. Det er med vilje: den ene tilstanden som *ikke*
 * skal kunne oppstå av en endret fil, er at et maskinutkast føres som et
 * menneskes arbeid — og `without_assignment` er den eneste veien til `human`,
 * som en kaller må velge uttrykkelig.
 */
export function producerForMode(mode: RegistrationMode): ProposalProducer {
  return mode === 'without_assignment' ? 'human' : 'model'
}

/** Om modusen krever at oppdraget følger med. Bare den ene gjør det. */
export function modeRequiresAssignment(mode: RegistrationMode): boolean {
  return mode === 'with_assignment'
}

/**
 * Om forslagets egen erklæring stemmer med modusen det registreres under.
 *
 * Returnerer `null` når de stemmer, ellers én setning som sier hva som ikke
 * gjorde det.
 */
export function registrationModeProblem(
  mode: RegistrationMode,
  producer: ProposalProducer,
): string | null {
  const expected = producerForMode(mode)
  if (producer === expected) {
    return null
  }
  if (mode === 'without_assignment') {
    return (
      `forslaget er erklært laget av «${producer}», men registreres som en redaktørs eget ` +
      'arbeid. Et maskinutkast skal registreres som et maskinutkast, med oppdraget det ble laget ' +
      'under der det finnes ett'
    )
  }
  return (
    `forslaget er erklært laget av «${producer}», men registreres som et maskinutkast. Verdien ` +
    'ville blitt ført som en menneskelig ekstraksjon (extraction_method «manual»). Er det ' +
    'virkelig en redaktørs eget arbeid, registrer det under den arbeidsformen; er det et ' +
    'maskinutkast, skal producer være «model»'
  )
}

function parseGrounding(parent: Fields, value: unknown, index: number): ProposedGrounding {
  const fields = nestedFields(parent, value, `field_groundings[${String(index)}]`)
  const grounding: ProposedGrounding = {
    checkField: asVocabulary(fields, 'check_field', EVIDENCE_CHECK_FIELDS),
    sourceExcerpt: asText(fields, 'source_excerpt'),
    sourceLocator: asText(fields, 'source_locator'),
    justification: asText(fields, 'justification'),
  }
  rejectUnknown(fields)

  if (grounding.sourceExcerpt.trim().length < MIN_SOURCE_EXCERPT_LENGTH) {
    problem(
      fields.subject,
      `${fields.where}.source_excerpt`,
      `er kortere enn ${String(MIN_SOURCE_EXCERPT_LENGTH)} tegn og bærer derfor ikke nok kontekst til å være kontrollgrunnlag. Ta med setningen verdien står i, ordrett`,
    )
  }
  return grounding
}

/**
 * `raw_extraction` navngis særskilt.
 *
 * Feltet finnes på raden i basen som ekstraksjonens egen tolkning, men det er
 * ikke noe et forslag skal levere: verdiene er de strukturerte kolonnene, og
 * grunnlaget er de ordrette utdragene. Et forslag som sendte en samlet tolkning
 * ved siden av, ville invitert til at noen leste verdier ut av den
 * (EVIDENCE_PIPELINE.md §21).
 */
const RAW_EXTRACTION_EXPLANATION =
  'hører ikke hjemme i et forslag. De strukturerte verdiene er kolonnene, og grunnlaget er de ordrette utdragene per felt — en samlet tolkning ved siden av ville vært noe å lese verdier ut av'

function parseExtraction(parent: Fields, value: unknown): ProposedExtraction {
  const fields = nestedFields(parent, value, 'extraction')
  const extraction: ProposedExtraction = {
    designCode: asVocabulary(fields, 'design_code', STUDY_DESIGNS),
    populationId: asOptionalUuid(fields, 'population_id'),
    populationAvailability: asVocabulary(fields, 'population_availability', VALUE_AVAILABILITIES),
    populationDetail: asText(fields, 'population_detail'),
    sampleSize: asOptionalInteger(fields, 'sample_size'),
    sampleSizeAvailability: asVocabulary(fields, 'sample_size_availability', VALUE_AVAILABILITIES),
    interventionDrugId: asUuid(fields, 'intervention_drug_id'),
    interventionDetail: asOptionalText(fields, 'intervention_detail'),
    comparatorKind: asVocabulary(fields, 'comparator_kind', COMPARATOR_KINDS),
    comparatorDrugId: asOptionalUuid(fields, 'comparator_drug_id'),
    comparatorDetail: asOptionalText(fields, 'comparator_detail'),
    outcomeConceptId: asUuid(fields, 'outcome_concept_id'),
    outcomeDetail: asText(fields, 'outcome_detail'),
    timepointMin: asOptionalText(fields, 'timepoint_min'),
    timepointMax: asOptionalText(fields, 'timepoint_max'),
    timepointAvailability: asVocabulary(fields, 'timepoint_availability', VALUE_AVAILABILITIES),
    reportedDirection: asVocabulary(fields, 'reported_direction', REPORTED_DIRECTIONS),
    effectMeasure: asOptionalVocabulary(fields, 'effect_measure', EFFECT_MEASURES),
    estimate: asOptionalNumericText(fields, 'estimate'),
    estimateUnit: asOptionalVocabulary(fields, 'estimate_unit', ESTIMATE_UNITS),
    estimateAvailability: asVocabulary(fields, 'estimate_availability', VALUE_AVAILABILITIES),
    ciLower: asOptionalNumericText(fields, 'ci_lower'),
    ciUpper: asOptionalNumericText(fields, 'ci_upper'),
    ciLevelPercent: asOptionalNumericText(fields, 'ci_level_percent'),
    confidenceIntervalAvailability: asVocabulary(
      fields,
      'confidence_interval_availability',
      VALUE_AVAILABILITIES,
    ),
    limitationsText: asOptionalText(fields, 'limitations_text'),
    sourceLocator: asText(fields, 'source_locator'),
    sourceQuote: asOptionalText(fields, 'source_quote'),
  }
  rejectUnknown(fields, { raw_extraction: RAW_EXTRACTION_EXPLANATION })
  return extraction
}

/**
 * De to delene, lest ut av et objekt som allerede er åpnet.
 *
 * Skilt ut fordi modell-leddet leverer nøyaktig disse to og ingenting mer:
 * kildebindingen er oppdragets, ikke modellens. Ved å lese dem med den samme
 * koden kan et modellutkast ikke være gyldig etter en litt annen regel enn et
 * forslag fra en fil.
 */
function parseBody(fields: Fields): ExtractionDraft {
  const extraction = parseExtraction(fields, raw(fields, 'extraction'))

  const groundings = raw(fields, 'field_groundings')
  if (!Array.isArray(groundings) || groundings.length === 0) {
    problem(fields.subject, 'field_groundings', 'mangler eller er tom')
  }

  const parsed = groundings.map((value, index) => parseGrounding(fields, value, index))
  const seen = new Set<string>()
  for (const grounding of parsed) {
    if (seen.has(grounding.checkField)) {
      problem(
        fields.subject,
        'field_groundings',
        `forankrer «${grounding.checkField}» mer enn én gang`,
      )
    }
    seen.add(grounding.checkField)
  }

  return { extraction, fieldGroundings: parsed }
}

/**
 * Leser det et modell-ledd produserer: de strukturerte verdiene og forankringen.
 *
 * `subject` er hva svaret heter i en avvisning, slik at en feil i et modellsvar
 * ikke ser ut som en feil i en fil noen har skrevet.
 */
export function parseExtractionDraft(value: unknown, subject: string): ExtractionDraft {
  const fields = fieldsOf(value, subject, 'utkastet')
  const draft = parseBody(fields)
  rejectUnknown(fields, { raw_extraction: RAW_EXTRACTION_EXPLANATION })
  return draft
}

function parseGeneratedBy(parent: Fields, value: unknown): GeneratedBy {
  const fields = nestedFields(parent, value, 'generated_by')
  const draftedAt = asText(fields, 'drafted_at')
  if (!isCalendarTimestamp(draftedAt)) {
    problem(
      fields.subject,
      'generated_by.drafted_at',
      'er ikke et tidspunkt på formen «2026-09-15T09:00:00Z», med tidssone',
    )
  }
  const requestDigest = asOptionalText(fields, 'request_digest')
  if (requestDigest !== null && !CONTENT_HASH_PATTERN.test(requestDigest)) {
    problem(
      fields.subject,
      'generated_by.request_digest',
      'har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn',
    )
  }
  const generatedBy: GeneratedBy = {
    producer: asVocabulary(fields, 'producer', PROPOSAL_PRODUCERS) as ProposalProducer,
    provider: asText(fields, 'provider'),
    model: asText(fields, 'model'),
    modelVersion: asText(fields, 'model_version'),
    promptTemplateVersion: asText(fields, 'prompt_template_version'),
    draftedAt,
    requestDigest,
  }
  rejectUnknown(fields, {
    pipeline_version:
      'hører ikke hjemme i et forslag. Pipelineversjonen er Antideps egen og settes av kjøringen, ikke av den som skrev forslaget',
  })
  return generatedBy
}

/**
 * Leser og kontrollerer ett forslag.
 *
 * Kontrollen gjelder formen, ikke innholdet: at et felt finnes, har riktig type
 * og en verdi innenfor sitt vokabular — aldri at verdien er riktig. Om verdien
 * følger av kilden, avgjøres av den ordrette kontrollen mot representasjonen og
 * av mennesket etterpå.
 */
export function parseExtractionProposal(value: unknown): ExtractionProposal {
  const fields = fieldsOf(value, PROPOSAL_SUBJECT, 'forslaget')

  const version = asText(fields, 'proposal_version')
  if (version !== EXTRACTION_PROPOSAL_VERSION) {
    problem(
      PROPOSAL_SUBJECT,
      'forslaget.proposal_version',
      `er ${JSON.stringify(version)}, men denne kjøreren leser ${JSON.stringify(EXTRACTION_PROPOSAL_VERSION)}`,
    )
  }

  const generatedBy = parseGeneratedBy(fields, raw(fields, 'generated_by'))
  const sourceId = asUuid(fields, 'source_id')
  const sourceVersionId = asUuid(fields, 'source_version_id')
  const retrievedFrom = asText(fields, 'retrieved_from')
  const contentHash = asText(fields, 'content_hash')
  if (!CONTENT_HASH_PATTERN.test(contentHash)) {
    problem(
      PROPOSAL_SUBJECT,
      'forslaget.content_hash',
      'har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn, som er den kildeversjonene er registrert med',
    )
  }

  const body = parseBody(fields)
  rejectUnknown(fields, { raw_extraction: RAW_EXTRACTION_EXPLANATION })

  return {
    proposalVersion: EXTRACTION_PROPOSAL_VERSION,
    generatedBy,
    sourceId,
    sourceVersionId,
    retrievedFrom,
    contentHash,
    ...body,
  }
}

/**
 * Forslaget som JSON-formen det leses fra.
 *
 * Motstykket til `parseExtractionProposal`, og skrevet ved siden av den med
 * vilje: modell-leddet produserer et forslag i minnet, og den filen det skriver,
 * skal være nøyaktig den formen kjøringen etterpå leser. To oversettelser i
 * hver sin fil ville vært to steder å stave et feltnavn feil — og feilen ville
 * først vist seg som en manglende verdi i en registrert rad.
 *
 * Valgfrie felter skrives ut med `null` framfor å utelates. En utelatt nøkkel
 * og en nøkkel med `null` leses likt av parseren, men bare den ene sier
 * eksplisitt at verdien ble vurdert og ikke funnet.
 */
export function serializeExtractionProposal(proposal: ExtractionProposal): unknown {
  const e = proposal.extraction
  return {
    proposal_version: proposal.proposalVersion,
    generated_by: {
      producer: proposal.generatedBy.producer,
      provider: proposal.generatedBy.provider,
      model: proposal.generatedBy.model,
      model_version: proposal.generatedBy.modelVersion,
      prompt_template_version: proposal.generatedBy.promptTemplateVersion,
      drafted_at: proposal.generatedBy.draftedAt,
      request_digest: proposal.generatedBy.requestDigest,
    },
    source_id: proposal.sourceId,
    source_version_id: proposal.sourceVersionId,
    retrieved_from: proposal.retrievedFrom,
    content_hash: proposal.contentHash,
    extraction: {
      design_code: e.designCode,
      population_id: e.populationId,
      population_availability: e.populationAvailability,
      population_detail: e.populationDetail,
      sample_size: e.sampleSize,
      sample_size_availability: e.sampleSizeAvailability,
      intervention_drug_id: e.interventionDrugId,
      intervention_detail: e.interventionDetail,
      comparator_kind: e.comparatorKind,
      comparator_drug_id: e.comparatorDrugId,
      comparator_detail: e.comparatorDetail,
      outcome_concept_id: e.outcomeConceptId,
      outcome_detail: e.outcomeDetail,
      timepoint_min: e.timepointMin,
      timepoint_max: e.timepointMax,
      timepoint_availability: e.timepointAvailability,
      reported_direction: e.reportedDirection,
      effect_measure: e.effectMeasure,
      estimate: e.estimate,
      estimate_unit: e.estimateUnit,
      estimate_availability: e.estimateAvailability,
      ci_lower: e.ciLower,
      ci_upper: e.ciUpper,
      ci_level_percent: e.ciLevelPercent,
      confidence_interval_availability: e.confidenceIntervalAvailability,
      limitations_text: e.limitationsText,
      source_locator: e.sourceLocator,
      source_quote: e.sourceQuote,
    },
    field_groundings: proposal.fieldGroundings.map((grounding) => ({
      check_field: grounding.checkField,
      source_excerpt: grounding.sourceExcerpt,
      source_locator: grounding.sourceLocator,
      justification: grounding.justification,
    })),
  }
}
