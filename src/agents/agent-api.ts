// ============================================================================
// Data API-flaten en agentkjører bruker
//
// Sju funksjoner, alle i `api`, alle kalt uten brukersesjon: en agent har ingen
// brukerkonto, så kalleren er `anon` i Data API-et og legitimasjonen — ikke
// Data API-rollen — er kontrollen (migrasjon 005e sin hodekommentar).
//
//   api.begin_agent_run                  åpner kjøringen og registrerer premissene
//   api.complete_agent_run               lukker kjøringen med et utfall
//   api.extraction_verification_input    grunnlaget ekstraksjonskontrollen gjøres mot (005h)
//   api.register_extraction_verification registrerer resultatet av den (005g)
//   api.claim_verification_input         grunnlaget claim-kontrollen gjøres mot (005k)
//   api.register_claim_verification      registrerer resultatet av den (005k)
//   api.register_agent_extraction        registrerer én forankret ekstraksjon (005v)
//
// De to første er felles for alle agentledd. De fire neste kommer i par, ett par
// per verifikatorrolle: grunnlaget leses, resultatet registreres. Paret er
// grenseflaten det enkelte leddet kjenner, og kjøringen som omslutter det er den
// samme mekanismen i alle tilfeller — derfor er den skrevet én gang, i
// `createAgentRunApi`.
//
// Ekstraksjonsleddet har ingen leseflate: det leser ikke Antidep, det leser
// kilden. Grunnlaget er selve representasjonen, hentet over nett, og forslaget
// om hva som står i den (`extraction-proposal.ts`).
//
// ----------------------------------------------------------------------------
// Hvorfor typene utvider `Database` framfor å være en ny kopi
//
// `src/types/database.ts` beskriver kontraktslaget slik nettleseren ser det, og
// disse fire hører ikke hjemme der: appen skal aldri kalle dem, og en type som
// sa at den kunne, ville vært en invitasjon. Samtidig er viewene og de
// editorfunksjonene de samme objektene, og to uavhengige beskrivelser av samme
// schema ville kunnet drive fra hverandre. `AgentDatabase` utvider derfor den
// eksisterende typen med nøyaktig de fire.
//
// ----------------------------------------------------------------------------
// Hvorfor runneren snakker med en port og ikke med supabase-js direkte
//
// `ExtractionVerificationApi` er de fire kallene som en grenseflate. Runneren
// kjenner bare den, så hele orkestreringen — rekkefølgen, hva som skjer når
// kilden ikke lar seg hente, hva som skrives når kontrollen ikke konkluderer —
// kan prøves uten database og uten nett. Det er den samme grunnen til at
// `checkExtraction` er en ren funksjon.
// ============================================================================

import { createClient, type SupabaseClient } from '@supabase/supabase-js'

import type { Database } from '../types/database.ts'
import type { ProposedExtraction, ProposedGrounding } from './extraction-proposal.ts'
import type { Uuid } from '../types/api.ts'
import type { AgentCredential } from './agent-credential.ts'

/** Kontraktslaget slik en agentkjører ser det: appens flate, pluss de fire. */
export type AgentDatabase = {
  api: Omit<Database['api'], 'Functions'> & {
    Functions: Database['api']['Functions'] & {
      begin_agent_run: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_role: string
          p_provider: string
          p_model: string
          p_model_version: string
          p_prompt_template_version: string
          p_pipeline_version: string
          p_input_manifest: Record<string, unknown>
          p_input_source_version_id?: Uuid | null
        }
        Returns: Uuid
      }
      complete_agent_run: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_run_id: Uuid
          p_status: string
          p_output_manifest?: Record<string, unknown> | null
          p_failure_reason?: string | null
        }
        Returns: Uuid
      }
      claim_verification_input: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_run_id: Uuid
          p_claim_revision_id?: Uuid | null
        }
        // jsonb. Formen er dokumentert i migrasjon 005k og leses av
        // `parseClaimVerificationInput`, som avviser et svar som ikke har den.
        Returns: unknown
      }
      register_claim_verification: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_run_id: Uuid
          p_claim_revision_id: Uuid
          p_outcome: string
          p_source_support: string
          p_population_match: string
          p_comparator_match: string
          p_timeframe_match: string
          p_direction_and_magnitude: string
          p_qualifiers_complete: string
          p_contradictory_evidence_represented: string
          p_citations: readonly Record<string, unknown>[]
          p_rationale: string
          p_findings?: string | null
        }
        Returns: Uuid
      }
      extraction_verification_input: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_run_id: Uuid
          p_evidence_item_id?: Uuid | null
        }
        // jsonb. Formen er dokumentert i migrasjon 005h og leses av
        // `parseVerificationInput`, som avviser et svar som ikke har den.
        Returns: unknown
      }
      register_extraction_verification: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_run_id: Uuid
          p_evidence_item_id: Uuid
          p_outcome: string
          p_source_access: string
          p_checked_fields: readonly string[]
          p_rationale: string
          p_findings?: string | null
        }
        Returns: Uuid
      }
      register_agent_extraction: {
        Args: {
          p_identity_key: string
          p_secret: string
          p_agent_run_id: Uuid
          p_source_id: Uuid
          p_source_version_id: Uuid
          p_design_code: string
          p_population_availability: string
          p_population_detail: string
          p_sample_size_availability: string
          p_intervention_drug_id: Uuid
          p_comparator_kind: string
          p_outcome_concept_id: Uuid
          p_outcome_detail: string
          p_timepoint_availability: string
          p_reported_direction: string
          p_estimate_availability: string
          p_confidence_interval_availability: string
          p_source_locator: string
          p_field_groundings: readonly Record<string, string>[]
          p_population_id?: Uuid | null
          p_sample_size?: number | null
          p_intervention_detail?: string | null
          p_comparator_drug_id?: Uuid | null
          p_comparator_detail?: string | null
          p_timepoint_min?: string | null
          p_timepoint_max?: string | null
          p_effect_measure?: string | null
          p_estimate?: string | null
          p_estimate_unit?: string | null
          p_ci_lower?: string | null
          p_ci_upper?: string | null
          p_ci_level_percent?: string | null
          p_limitations_text?: string | null
          p_source_quote?: string | null
        }
        Returns: Uuid
      }
    }
  }
}

export type AgentClient = SupabaseClient<AgentDatabase, 'api'>

export interface AgentClientConfig {
  readonly url: string
  readonly publishableKey: string
}

export function createAgentClient(config: AgentClientConfig): AgentClient {
  return createClient<AgentDatabase, 'api'>(config.url, config.publishableKey, {
    db: { schema: 'api' },
    // Ingen sesjon å lagre eller fornye: kjøreren har ingen brukerkonto, og en
    // klient som prøvde å oppdatere en token i bakgrunnen, ville holdt
    // prosessen i live etter at kjøringen er lukket.
    auth: { persistSession: false, autoRefreshToken: false },
  })
}

/** Premissene en kjøring registreres med (provenance.agent_runs). */
export interface AgentRunPremises {
  readonly provider: string
  readonly model: string
  readonly modelVersion: string
  readonly promptTemplateVersion: string
  readonly pipelineVersion: string
}

export interface RegisterVerificationArgs {
  readonly agentRunId: Uuid
  readonly evidenceItemId: Uuid
  readonly outcome: string
  readonly sourceAccess: string
  readonly checkedFields: readonly string[]
  readonly rationale: string
  readonly findings: string | null
}

/** Én kontrollert evidenslenke, slik `api.register_claim_verification` tar imot den. */
export interface ClaimCitationArgs {
  readonly claimEvidenceLinkId: Uuid
  readonly sourceAccess: string
  readonly sourceVersionId: Uuid | null
  readonly checkedContentHash: string | null
  readonly relationshipSupported: string
  readonly finding: string | null
}

/** De sju kontrollpunktene DATABASE_ARCHITECTURE.md §30 krever. */
export interface ClaimCheckResults {
  readonly sourceSupport: string
  readonly populationMatch: string
  readonly comparatorMatch: string
  readonly timeframeMatch: string
  readonly directionAndMagnitude: string
  readonly qualifiersComplete: string
  readonly contradictoryEvidenceRepresented: string
}

export interface RegisterClaimVerificationArgs {
  readonly agentRunId: Uuid
  readonly claimRevisionId: Uuid
  readonly outcome: string
  readonly checks: ClaimCheckResults
  readonly citations: readonly ClaimCitationArgs[]
  readonly rationale: string
  readonly findings: string | null
}

/** Kjøringen, som er den samme mekanismen for hvert agentledd. */
export interface AgentRunApi {
  /**
   * Åpner kjøringen.
   *
   * `inputSourceVersionId` er kildeversjonen kjøringen skal lese, og er
   * påkrevd for rollen `evidence_extraction`: evidensfunnet kjøringen
   * registrerer, bindes deklarativt til nettopp den (migrasjon 005z).
   * Verifikatorleddene leser en arbeidskø og lar den stå.
   */
  beginRun(
    premises: AgentRunPremises,
    inputManifest: Record<string, unknown>,
    inputSourceVersionId?: Uuid | null,
  ): Promise<Uuid>
  completeRun(
    agentRunId: Uuid,
    status: 'succeeded' | 'failed' | 'aborted',
    outputManifest: Record<string, unknown> | null,
    failureReason: string | null,
  ): Promise<void>
}

/** Kallene ekstraksjonsverifikatoren gjør, som én grenseflate. */
export interface ExtractionVerificationApi extends AgentRunApi {
  readInput(agentRunId: Uuid, evidenceItemId: Uuid | null): Promise<unknown>
  registerVerification(args: RegisterVerificationArgs): Promise<Uuid>
}

/**
 * Én ekstraksjon, slik `api.register_agent_extraction` tar imot den.
 *
 * Formen er databasens, ikke kjørerens: parameterlisten er kontrakten
 * migrasjon 005v dokumenterer.
 */
export interface RegisterAgentExtractionArgs {
  readonly agentRunId: Uuid
  readonly sourceId: Uuid
  readonly sourceVersionId: Uuid
  readonly extraction: ProposedExtraction
  readonly fieldGroundings: readonly ProposedGrounding[]
}

/** Kallet ekstraksjonsagenten gjør, som én grenseflate. */
export interface EvidenceExtractionApi extends AgentRunApi {
  registerExtraction(args: RegisterAgentExtractionArgs): Promise<Uuid>
}

/** Kallene claim-verifikatoren gjør, som én grenseflate. */
export interface ClaimVerificationApi extends AgentRunApi {
  readInput(agentRunId: Uuid, claimRevisionId: Uuid | null): Promise<unknown>
  registerVerification(args: RegisterClaimVerificationArgs): Promise<Uuid>
}

/** Agentrollene kjøringene handler i (provenance.agent_role). */
export const EVIDENCE_EXTRACTION_ROLE = 'evidence_extraction'
export const EXTRACTION_VERIFICATION_ROLE = 'extraction_verification'
export const CITATION_SUPPORT_VERIFICATION_ROLE = 'citation_support_verification'

/**
 * En avvisning fra `api`, med databasens egen SQLSTATE bevart.
 *
 * Koden er der fordi én avvisning er en *forventet* utgang av et riktig utfylt
 * forslag: `unique_violation` fra `evidence_items_content_hash_key` betyr at
 * nøyaktig det samme evidensfunnet allerede er registrert. En kjøring som skal
 * kunne kjøres om igjen uten å skrive noe nytt, må kunne skille den fra en
 * reell feil — og en tekstsammenligning på en norsk setning ville vært en
 * kontrakt ingen har inngått.
 */
export class AgentApiError extends Error {
  readonly code: string | null

  constructor(operation: string, message: string, code: string | null) {
    super(`${operation} ble avvist: ${message}`)
    this.name = 'AgentApiError'
    this.code = code
  }
}

/** SQLSTATE 23505: raden finnes allerede, med nøyaktig det samme innholdet. */
export const UNIQUE_VIOLATION = '23505'

/** Om avvisningen er «dette er allerede registrert», og ikke en feil. */
export function isUniqueViolation(cause: unknown): boolean {
  return cause instanceof AgentApiError && cause.code === UNIQUE_VIOLATION
}

function fail(
  operation: string,
  error: { readonly message: string; readonly code?: string },
): never {
  throw new AgentApiError(operation, error.message, error.code ?? null)
}

type Identity = { readonly p_identity_key: string; readonly p_secret: string }

function identityOf(credential: AgentCredential): Identity {
  return { p_identity_key: credential.identityKey, p_secret: credential.secret.reveal() }
}

/**
 * Kjøringen, implementert én gang.
 *
 * `api.begin_agent_run` og `api.complete_agent_run` er de samme to kallene for
 * hvert agentledd; det eneste som skiller dem, er rollen kjøringen åpnes i. Å
 * skrive dem om igjen per ledd ville vært to steder å glemme et felt.
 */
function createAgentRunApi(client: AgentClient, identity: Identity, role: string): AgentRunApi {
  return {
    async beginRun(premises, inputManifest, inputSourceVersionId = null) {
      const { data, error } = await client.rpc('begin_agent_run', {
        ...identity,
        p_agent_role: role,
        p_provider: premises.provider,
        p_model: premises.model,
        p_model_version: premises.modelVersion,
        p_prompt_template_version: premises.promptTemplateVersion,
        p_pipeline_version: premises.pipelineVersion,
        p_input_manifest: inputManifest,
        p_input_source_version_id: inputSourceVersionId,
      })
      if (error !== null) {
        fail('api.begin_agent_run', error)
      }
      return data
    },

    async completeRun(agentRunId, status, outputManifest, failureReason) {
      const { error } = await client.rpc('complete_agent_run', {
        ...identity,
        p_agent_run_id: agentRunId,
        p_status: status,
        p_output_manifest: outputManifest,
        p_failure_reason: failureReason,
      })
      if (error !== null) {
        fail('api.complete_agent_run', error)
      }
    },
  }
}

/**
 * Ekstraksjonsverifikatorens port mot en faktisk Supabase-klient.
 *
 * Legitimasjonen hentes ut på det ene stedet den faktisk sendes, og
 * `AgentSecret` sørger for at den ikke kan havne i en logg på veien
 * (se `agent-credential.ts`).
 */
export function createExtractionVerificationApi(
  client: AgentClient,
  credential: AgentCredential,
): ExtractionVerificationApi {
  const identity = identityOf(credential)

  return {
    ...createAgentRunApi(client, identity, EXTRACTION_VERIFICATION_ROLE),

    async readInput(agentRunId, evidenceItemId) {
      const { data, error } = await client.rpc('extraction_verification_input', {
        ...identity,
        p_agent_run_id: agentRunId,
        p_evidence_item_id: evidenceItemId,
      })
      if (error !== null) {
        fail('api.extraction_verification_input', error)
      }
      return data
    },

    async registerVerification(args) {
      const { data, error } = await client.rpc('register_extraction_verification', {
        ...identity,
        p_agent_run_id: args.agentRunId,
        p_evidence_item_id: args.evidenceItemId,
        p_outcome: args.outcome,
        p_source_access: args.sourceAccess,
        p_checked_fields: args.checkedFields,
        p_rationale: args.rationale,
        p_findings: args.findings,
      })
      if (error !== null) {
        fail('api.register_extraction_verification', error)
      }
      return data
    },
  }
}

/**
 * Claim-verifikatorens port. Samme form, egen rolle og egen legitimasjon: en
 * identitet i det ene leddet kan ikke utføre operasjonene i det andre
 * (MVP_IMPLEMENTATION_PLAN.md §49).
 */
export function createClaimVerificationApi(
  client: AgentClient,
  credential: AgentCredential,
): ClaimVerificationApi {
  const identity = identityOf(credential)

  return {
    ...createAgentRunApi(client, identity, CITATION_SUPPORT_VERIFICATION_ROLE),

    async readInput(agentRunId, claimRevisionId) {
      const { data, error } = await client.rpc('claim_verification_input', {
        ...identity,
        p_agent_run_id: agentRunId,
        p_claim_revision_id: claimRevisionId,
      })
      if (error !== null) {
        fail('api.claim_verification_input', error)
      }
      return data
    },

    async registerVerification(args) {
      const { data, error } = await client.rpc('register_claim_verification', {
        ...identity,
        p_agent_run_id: args.agentRunId,
        p_claim_revision_id: args.claimRevisionId,
        p_outcome: args.outcome,
        p_source_support: args.checks.sourceSupport,
        p_population_match: args.checks.populationMatch,
        p_comparator_match: args.checks.comparatorMatch,
        p_timeframe_match: args.checks.timeframeMatch,
        p_direction_and_magnitude: args.checks.directionAndMagnitude,
        p_qualifiers_complete: args.checks.qualifiersComplete,
        p_contradictory_evidence_represented: args.checks.contradictoryEvidenceRepresented,
        // Nøklene er databasens, ikke kjøreren sine: formen er kontrakten
        // migrasjon 005k dokumenterer, og oversettelsen skjer her framfor å
        // lekke snake_case inn i resten av kjøreren.
        p_citations: args.citations.map((citation) => ({
          claim_evidence_link_id: citation.claimEvidenceLinkId,
          source_access: citation.sourceAccess,
          source_version_id: citation.sourceVersionId,
          checked_content_hash: citation.checkedContentHash,
          relationship_supported: citation.relationshipSupported,
          finding: citation.finding,
        })),
        p_rationale: args.rationale,
        p_findings: args.findings,
      })
      if (error !== null) {
        fail('api.register_claim_verification', error)
      }
      return data
    },
  }
}

/**
 * Ekstraksjonsagentens port mot en faktisk Supabase-klient.
 *
 * Ett kall, og ingen leseflate: leddet leser kilden, ikke Antidep.
 * Oversettelsen til databasens parameternavn skjer her framfor å la snake_case
 * lekke inn i resten av kjøreren, som for de to verifikatorene.
 */
export function createEvidenceExtractionApi(
  client: AgentClient,
  credential: AgentCredential,
): EvidenceExtractionApi {
  const identity = identityOf(credential)

  return {
    ...createAgentRunApi(client, identity, EVIDENCE_EXTRACTION_ROLE),

    async registerExtraction(args) {
      const e = args.extraction
      const { data, error } = await client.rpc('register_agent_extraction', {
        ...identity,
        p_agent_run_id: args.agentRunId,
        p_source_id: args.sourceId,
        p_source_version_id: args.sourceVersionId,
        p_design_code: e.designCode,
        p_population_availability: e.populationAvailability,
        p_population_detail: e.populationDetail,
        p_sample_size_availability: e.sampleSizeAvailability,
        p_intervention_drug_id: e.interventionDrugId,
        p_comparator_kind: e.comparatorKind,
        p_outcome_concept_id: e.outcomeConceptId,
        p_outcome_detail: e.outcomeDetail,
        p_timepoint_availability: e.timepointAvailability,
        p_reported_direction: e.reportedDirection,
        p_estimate_availability: e.estimateAvailability,
        p_confidence_interval_availability: e.confidenceIntervalAvailability,
        p_source_locator: e.sourceLocator,
        p_field_groundings: args.fieldGroundings.map((grounding) => ({
          check_field: grounding.checkField,
          source_excerpt: grounding.sourceExcerpt,
          source_locator: grounding.sourceLocator,
          justification: grounding.justification,
        })),
        p_population_id: e.populationId,
        p_sample_size: e.sampleSize,
        p_intervention_detail: e.interventionDetail,
        p_comparator_drug_id: e.comparatorDrugId,
        p_comparator_detail: e.comparatorDetail,
        p_timepoint_min: e.timepointMin,
        p_timepoint_max: e.timepointMax,
        p_effect_measure: e.effectMeasure,
        p_estimate: e.estimate,
        p_estimate_unit: e.estimateUnit,
        p_ci_lower: e.ciLower,
        p_ci_upper: e.ciUpper,
        p_ci_level_percent: e.ciLevelPercent,
        p_limitations_text: e.limitationsText,
        p_source_quote: e.sourceQuote,
      })
      if (error !== null) {
        fail('api.register_agent_extraction', error)
      }
      return data
    },
  }
}
