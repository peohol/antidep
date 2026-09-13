// ============================================================================
// Selve agentkjøringen: fra syntesforslag til registrert påstandsrevisjon
//
//   api.begin_agent_run            premissene registreres
//   api.register_claim_synthesis   påstand, revisjon, lenker og vurdering (005aj)
//   api.complete_agent_run         kjøringen lukkes
//
// Alt som rører omverdenen er injisert (`api`, `log`), så hele orkestreringen
// kan prøves uten database — samme form som de øvrige kjøringene.
//
// ----------------------------------------------------------------------------
// Hva kjøringen er, og hva den ikke er
//
// Den er **registreringen**, ikke leddet som formulerte påstanden. Modellen
// leste det registrerte evidensgrunnlaget og skrev en fil; denne kjøringen
// kontrollerer formen og skriver raden. Premissene sier derfor nøyaktig det, og
// erklæringen om hvem som laget utkastet, føres i `input_manifest` — kolonnen
// for hva kjøringen fikk inn (`pipeline-version.ts`, ANTIDEP_CONSTITUTION.md
// §20).
//
// Den godkjenner ingenting. Revisjonen er et forslag: uten claim-verifikasjon,
// uten reviewbeslutning og uten publiseringspeker. Neste ledd er en *separat*
// kontrollfase med sin egen identitet (`npm run agent:verify-claims`), og
// deretter et menneske i /review (ANTIDEP_CONSTITUTION.md §11, §12).
//
// ----------------------------------------------------------------------------
// Hvorfor ett forslag som ikke holder mål, ikke stopper de andre
//
// En levering på to påstander skal ikke være alt-eller-ingenting når det ene
// grunnlaget ikke har nådd kontrollnivået sitt. Hvert forslag er sin egen
// registrering i sin egen transaksjon, og rapporten sier hva som skjedde med
// hvert enkelt — inkludert databasens egen setning om hva som stoppet det.
// ============================================================================

import type { Uuid } from '../types/api.ts'
import type { AgentRunPremises, ClaimSynthesisApi } from './agent-api.ts'
import type { ClaimSynthesisProposal } from './claim-synthesis-proposal.ts'
import { asOptionalUuid, asText, asUuid, fieldsOf, raw } from './strict-fields.ts'

/** Ett forslag, med navnet det ble lest under, slik rapporten kan navngi det. */
export interface LabelledSynthesisProposal {
  readonly label: string
  readonly proposal: ClaimSynthesisProposal
}

/** Det databasen svarer med når en syntese er registrert (migrasjon 005aj). */
export interface ClaimSynthesisResult {
  readonly claimId: Uuid
  readonly claimRevisionId: Uuid
  readonly revisionNumber: number
  readonly supersedesRevisionId: Uuid | null
  readonly evidenceAssessmentId: Uuid
  readonly evidenceSetDigest: string
  readonly evidenceLinkIds: readonly Uuid[]
}

/**
 * Leser svaret strengt, av samme grunn som grunnlagene leses strengt: en
 * jsonb-form har ingen kolonnetyper PostgREST kan håndheve, og en rapport som
 * stille mistet revisjons-ID-en ville sagt at noe ble registrert uten å kunne
 * si hva.
 */
export function parseClaimSynthesisResult(value: unknown): ClaimSynthesisResult {
  const fields = fieldsOf(value, 'Svaret fra api.register_claim_synthesis', 'svaret')
  const revisionNumber = raw(fields, 'revision_number')
  if (typeof revisionNumber !== 'number' || !Number.isInteger(revisionNumber)) {
    throw new Error(
      'Svaret fra api.register_claim_synthesis er ugyldig: svaret.revision_number er ikke et heltall.',
    )
  }
  const links = raw(fields, 'evidence_links')
  if (!Array.isArray(links)) {
    throw new Error(
      'Svaret fra api.register_claim_synthesis er ugyldig: svaret.evidence_links er ikke en liste.',
    )
  }

  return {
    claimId: asUuid(fields, 'claim_id'),
    claimRevisionId: asUuid(fields, 'claim_revision_id'),
    revisionNumber,
    supersedesRevisionId: asOptionalUuid(fields, 'supersedes_revision_id'),
    evidenceAssessmentId: asUuid(fields, 'evidence_assessment_id'),
    evidenceSetDigest: asText(fields, 'evidence_set_digest'),
    evidenceLinkIds: links.map((link) => {
      const entry = fieldsOf(link, 'Svaret fra api.register_claim_synthesis', 'evidence_links[]')
      return asUuid(entry, 'claim_evidence_link_id')
    }),
  }
}

export type SynthesisDecision = 'registered' | 'previewed' | 'skipped'

export interface SynthesisResult {
  readonly label: string
  readonly decision: SynthesisDecision
  readonly statement: string
  readonly registered?: ClaimSynthesisResult
  /** Databasens egen setning om hva som stoppet forslaget. Alltid satt for `skipped`. */
  readonly reason?: string
}

export interface SynthesisReport {
  readonly agentRunId: Uuid
  readonly runStatus: 'succeeded' | 'aborted' | 'failed'
  readonly results: readonly SynthesisResult[]
  readonly registered: number
  readonly skipped: number
}

export interface SynthesisRunOptions {
  readonly api: ClaimSynthesisApi
  readonly premises: AgentRunPremises
  readonly proposals: readonly LabelledSynthesisProposal[]
  /** Kontroller formen og rapporter, men registrer ingenting. */
  readonly dryRun?: boolean
  readonly log?: (line: string) => void
}

/** Lengdegrensen `provenance.agent_runs.failure_reason` håndhever. */
const MAX_TEXT = 4000

/**
 * Erklæringen om hvem som laget utkastet, slik den føres i kjøringens
 * `input_manifest`.
 *
 * Nøklene er snake_case fordi manifestet er en databaseverdi et menneske leser
 * ved siden av radene, ikke en intern struktur.
 */
function declarationOf(proposal: ClaimSynthesisProposal): Record<string, unknown> {
  const by = proposal.generatedBy
  return {
    producer: by.producer,
    provider: by.provider,
    model: by.model,
    model_version: by.modelVersion,
    prompt_template_version: by.promptTemplateVersion,
    drafted_at: by.draftedAt,
    request_digest: by.requestDigest,
  }
}

/**
 * Registrerer ett eller flere syntesforslag, i den rekkefølgen de kom.
 *
 * Kjøringen lukkes alltid: `succeeded` når den kom gjennom, `aborted` for en
 * tørrkjøring som med hensikt ikke skrev noe, og `failed` når noe uventet
 * skjedde. En kjøring som ble stående åpen, ville blokkert den neste og
 * etterlatt en proveniensrad uten utfall (migrasjon 005e).
 */
export async function runClaimSynthesis(options: SynthesisRunOptions): Promise<SynthesisReport> {
  const { api, premises, proposals, dryRun = false, log = () => {} } = options

  const inputManifest: Record<string, unknown> = {
    proposals: proposals.map((entry) => ({
      label: entry.label,
      proposal_version: entry.proposal.proposalVersion,
      statement: entry.proposal.claim.statement,
      evidence_item_ids: entry.proposal.evidenceLinks.map((link) => link.evidenceItemId),
      generated_by: declarationOf(entry.proposal),
    })),
    dry_run: dryRun,
  }

  const agentRunId = await api.beginRun(premises, inputManifest)
  log(`Agentkjøring åpnet: ${agentRunId}`)

  const results: SynthesisResult[] = []

  try {
    for (const { label, proposal } of proposals) {
      log(`\n${label}`)

      if (dryRun) {
        log(`— formen er kontrollert (tørrkjøring, ingenting registrert).`)
        results.push({ label, decision: 'previewed', statement: proposal.claim.statement })
        continue
      }

      // Registreringen ligger i sin egen innkapsling: en avvist syntese — et
      // evidensfunn som ikke har nådd kontrollnivået sitt, en verdi basen ikke
      // tar imot — er det ene forslagets problem, ikke køens.
      try {
        const registered = parseClaimSynthesisResult(
          await api.registerSynthesis({
            agentRunId,
            claim: proposal.claim,
            evidenceLinks: proposal.evidenceLinks,
            assessment: proposal.assessment,
          }),
        )
        log(
          `— registrert som revisjon ${registered.claimRevisionId} ` +
            `(nummer ${String(registered.revisionNumber)}) av påstand ${registered.claimId}, ` +
            `med ${String(registered.evidenceLinkIds.length)} evidenslenke` +
            `${registered.evidenceLinkIds.length === 1 ? '' : 'r'}.`,
        )
        results.push({
          label,
          decision: 'registered',
          statement: proposal.claim.statement,
          registered,
        })
      } catch (cause) {
        const reason = cause instanceof Error ? cause.message : String(cause)
        log(`— ingen påstand registrert. ${reason}`)
        results.push({
          label,
          decision: 'skipped',
          statement: proposal.claim.statement,
          reason,
        })
      }
    }

    const outputManifest: Record<string, unknown> = {
      registered: results.filter((result) => result.decision === 'registered').length,
      skipped: results.filter((result) => result.decision === 'skipped').length,
      results,
    }

    if (dryRun) {
      await api.completeRun(
        agentRunId,
        'aborted',
        outputManifest,
        'Tørrkjøring: formen er kontrollert, men ingen påstandsrevisjon ble registrert.',
      )
      return {
        agentRunId,
        runStatus: 'aborted',
        results,
        registered: 0,
        skipped: 0,
      }
    }

    await api.completeRun(agentRunId, 'succeeded', outputManifest, null)
    return {
      agentRunId,
      runStatus: 'succeeded',
      results,
      registered: results.filter((result) => result.decision === 'registered').length,
      skipped: results.filter((result) => result.decision === 'skipped').length,
    }
  } catch (cause) {
    const reason = cause instanceof Error ? cause.message : String(cause)
    // Kjøringen lukkes selv om lukkingen også feiler: den opprinnelige årsaken
    // er den som skal nå kalleren, ikke en oppfølgingsfeil på vei ut.
    try {
      await api.completeRun(agentRunId, 'failed', null, reason.slice(0, MAX_TEXT))
    } catch {
      log(`Kjøringen ${agentRunId} kunne ikke lukkes etter feilen under.`)
    }
    throw cause
  }
}
