// ============================================================================
// Den kontrollerte skriveveien for å registrere et EvidenceItem
//
// Steg 3 av «manuell adminflyt» (MVP_IMPLEMENTATION_PLAN.md §29): «Editor
// registrerer EvidenceItem» (§15). Ett kall til `api.create_evidence_item(...)`
// (migrasjon 007e) — ingen egen validering her utover det formen selv samler
// inn, fordi constraintene på `knowledge.evidence_items` er fasiten
// (DATABASE_ARCHITECTURE.md §43, §48, §57), ikke en kopi av dem i klienten.
//
// ----------------------------------------------------------------------------
// Ingen «du har lov»-boolean her heller
//
// Samme doktrine som `create-source.ts` og `caller-authorization.ts`: denne
// modulen avgjør ikke om kalleren FÅR registrere et funn. Den sender forsøket
// og returnerer det databasen svarer, inkludert en avvisning fra
// `knowledge.assert_editor_authorized(uuid)` — som her også kontrollerer at en
// avgrenset editor-tildeling dekker endepunktet funnet gjelder.
//
// ----------------------------------------------------------------------------
// Tallene sendes som tekst, ikke som JavaScript-tall
//
// `estimate`, konfidensgrensene og utvalgsstørrelsen er strenger her, og de er
// allerede kontrollert på form av `evidence-registration.ts`. Grunnen er at
// PostgreSQL sin `numeric` er vilkårlig presis mens et JavaScript-tall er en
// IEEE-754 double: et estimat med flere signifikante siffer enn en double
// rommer, ville blitt avrundet på vei inn og lagret — og hashet — som en annen
// verdi enn kilden oppgir. PostgREST tar imot en JSON-streng for en `numeric`-
// eller `integer`-parameter og lar PostgreSQL gjøre casten; prøvd mot stacken.
//
// ----------------------------------------------------------------------------
// Fire felter finnes ikke i inputen, og det er med hensikt
//
//   created_by_actor_id  utledes av den innloggede brukeren, i databasen
//   content_hash         eies av databasen; en hash klienten kunne oppgi ville
//                        sett ut som en garanti uten å være det
//   extraction_method    alltid `manual` for denne veien: en registrering
//                        gjennom skjemaet ER en menneskelig ekstraksjon
//   raw_extraction       bygges av `sourceQuote` i databasen, under én
//                        dokumentert nøkkel
//
// ----------------------------------------------------------------------------
// Kildeforankringen følger med ekstraksjonen, i samme kall
//
// `fieldGroundings` er koblingen mellom hvert kontrollerbart felt og det
// grunnlaget ekstraksjonen faktisk hvilte på (migrasjon 005u). Den sendes i det
// samme kallet, og ikke i et eget etterpå: to kall er to transaksjoner, og
// mellom dem ville det finnes et evidensfunn uten forankring som en kontrollør
// kunne rukket å hente fram.
//
// Tom liste er lovlig og betyr det den sier: ingen forankring er registrert.
// Kontrollflaten viser det som fravær og gjetter aldri et utdrag ut av
// `raw_extraction` (ANTIDEP_CONSTITUTION.md §6, §8).
// ============================================================================

import type { AntidepClient } from './supabase'
import type { FieldGroundingInput } from './grounding-draft'
import type { Uuid } from '../types/api'

/**
 * Feltene skjemaet samler inn, i den formen kallet trenger dem.
 *
 * Tomme valgfrie felter er `null`, ikke tomstreng: fravær og tom tekst er ikke
 * det samme, og databasen avviser en tom tekst der den forventer enten innhold
 * eller NULL. Verdien i et `*Availability`-felt sier hvorfor det tilhørende
 * feltet har eller ikke har en verdi (DATABASE_ARCHITECTURE.md §19.1).
 */
export interface CreateEvidenceItemInput {
  readonly sourceId: Uuid
  readonly sourceVersionId: Uuid | null
  readonly designCode: string

  readonly populationId: Uuid | null
  readonly populationAvailability: string
  readonly populationDetail: string

  readonly sampleSize: string | null
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
  /** Ordrett sitat fra kilden. Bevares i `raw_extraction` for verifikasjon. */
  readonly sourceQuote: string | null
  /** Kildeforankringen per kontrollfelt. Tom liste = ingen forankring registrert. */
  readonly fieldGroundings: readonly FieldGroundingInput[]
}

export type CreateEvidenceItemResult =
  | { readonly status: 'ok'; readonly evidenceItemId: Uuid }
  | { readonly status: 'error'; readonly message: string }

/**
 * Kaller `api.create_evidence_item(...)`. Returnerer aldri en avvisning som et
 * kastet unntak: siden skal kunne vise enhver avvisning — manglende aktør,
 * manglende eller for smal editor-rolle, en dublett, en verdi uten sin status —
 * med databasens egen tekst, uten å måtte skille feiltyper fra hverandre her.
 */
export async function createEvidenceItem(
  client: AntidepClient,
  input: CreateEvidenceItemInput,
): Promise<CreateEvidenceItemResult> {
  const { data, error } = await client.rpc('create_evidence_item', {
    p_source_id: input.sourceId,
    p_source_version_id: input.sourceVersionId,
    p_design_code: input.designCode,
    p_population_id: input.populationId,
    p_population_availability: input.populationAvailability,
    p_population_detail: input.populationDetail,
    p_sample_size: input.sampleSize,
    p_sample_size_availability: input.sampleSizeAvailability,
    p_intervention_drug_id: input.interventionDrugId,
    p_intervention_detail: input.interventionDetail,
    p_comparator_kind: input.comparatorKind,
    p_comparator_drug_id: input.comparatorDrugId,
    p_comparator_detail: input.comparatorDetail,
    p_outcome_concept_id: input.outcomeConceptId,
    p_outcome_detail: input.outcomeDetail,
    p_timepoint_min: input.timepointMin,
    p_timepoint_max: input.timepointMax,
    p_timepoint_availability: input.timepointAvailability,
    p_reported_direction: input.reportedDirection,
    p_effect_measure: input.effectMeasure,
    p_estimate: input.estimate,
    p_estimate_unit: input.estimateUnit,
    p_estimate_availability: input.estimateAvailability,
    p_ci_lower: input.ciLower,
    p_ci_upper: input.ciUpper,
    p_ci_level_percent: input.ciLevelPercent,
    p_confidence_interval_availability: input.confidenceIntervalAvailability,
    p_limitations_text: input.limitationsText,
    p_source_locator: input.sourceLocator,
    p_source_quote: input.sourceQuote,
    p_field_groundings: input.fieldGroundings.map((grounding) => ({
      check_field: grounding.checkField,
      source_excerpt: grounding.sourceExcerpt,
      source_locator: grounding.sourceLocator,
      justification: grounding.justification,
    })),
  })
  if (error !== null) {
    return { status: 'error', message: error.message }
  }
  return { status: 'ok', evidenceItemId: data }
}
