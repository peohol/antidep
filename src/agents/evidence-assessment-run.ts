// ============================================================================
// Selve agentkjøringen: fra vurderingsforslag til registrert evidensvurdering
//
//   api.begin_agent_run              premissene registreres
//   api.register_evidence_assessment vurderingen for én revisjon (005am)
//   api.complete_agent_run           kjøringen lukkes
//
// Alt som rører omverdenen er injisert (`api`, `log`), så hele orkestreringen
// kan prøves uten database — samme form som de øvrige kjøringene.
//
// ----------------------------------------------------------------------------
// Hva kjøringen er, og hvorfor den er sin egen
//
// Den er **registreringen** av en gradering, ikke leddet som gjorde den.
// Modellen leste den kontrollerte revisjonen med grunnlaget sitt og skrev en
// fil; denne kjøringen kontrollerer formen og skriver raden.
//
// Den er et annet ledd enn påstandsdannelsen, med en annen rolle og en annen
// legitimasjon. EVIDENCE_PIPELINE.md §61 skiller `EvidenceAssessor` fra
// `ClaimAgent` og krever at ansvarsgrensen samtidig er en teknisk grense; fram
// til migrasjon 005am skrev synteseveien begge deler i én transaksjon, og
// skillet var dermed bare et navn.
//
// Den kommer **etter** claim-verifikasjonen (MVP_IMPLEMENTATION_PLAN.md §15).
// Databasen håndhever det: `api.register_evidence_assessment` avviser en
// revisjon uten en gjeldende, bekreftet kildestøtteverifikasjon som dekker
// nøyaktig det evidenssettet som ligger der nå.
//
// Den godkjenner ingenting. En vurdering herfra er et KI-utarbeidet forslag, og
// et menneske tar stilling til hele revisjonen i /review
// (ANTIDEP_CONSTITUTION.md §11, §12).
//
// ----------------------------------------------------------------------------
// Hvorfor ett forslag som ikke holder mål, ikke stopper de andre
//
// Samme grunn og samme mekanikk som på synteseveien: hvert forslag er sin egen
// registrering i sin egen transaksjon, og bare en avvisning databasen svarer med
// en kjent, forslagsspesifikk SQLSTATE på, føres som «overhoppet»
// (`isProposalRejection`). En driftsfeil og et uavklart utfall velter begge
// kjøringen — skriveveien er ikke idempotent, og en ny kjøring etter et uavklart
// utfall ville kunnet registrere den samme graderingen en gang til.
// ============================================================================

import type { Uuid } from '../types/api.ts'
import { isProposalRejection } from './agent-api.ts'
import type { AgentRunPremises, EvidenceAssessmentApi } from './agent-api.ts'
import type { LabelledProposal } from './drafted-proposal-files.ts'
import type { EvidenceAssessmentProposal } from './evidence-assessment-proposal.ts'
import { asText, asUuid, fieldsOf } from './strict-fields.ts'

/** Ett vurderingsforslag, med navnet det ble lest under. */
export type LabelledAssessmentProposal = LabelledProposal<EvidenceAssessmentProposal>

/** Det databasen svarer med når en vurdering er registrert (migrasjon 005am). */
export interface EvidenceAssessmentResult {
  readonly evidenceAssessmentId: Uuid
  readonly claimRevisionId: Uuid
  readonly claimId: Uuid
  readonly certaintyLevel: string
  readonly assessedAt: string
  readonly evidenceSetDigest: string
}

/**
 * Leser svaret strengt, av samme grunn som grunnlagene leses strengt: en
 * jsonb-form har ingen kolonnetyper PostgREST kan håndheve, og en rapport som
 * stille mistet vurderings-ID-en ville sagt at noe ble registrert uten å kunne
 * si hva.
 */
export function parseEvidenceAssessmentResult(value: unknown): EvidenceAssessmentResult {
  const fields = fieldsOf(value, 'Svaret fra api.register_evidence_assessment', 'svaret')
  return {
    evidenceAssessmentId: asUuid(fields, 'evidence_assessment_id'),
    claimRevisionId: asUuid(fields, 'claim_revision_id'),
    claimId: asUuid(fields, 'claim_id'),
    certaintyLevel: asText(fields, 'certainty_level'),
    assessedAt: asText(fields, 'assessed_at'),
    evidenceSetDigest: asText(fields, 'evidence_set_digest'),
  }
}

export type AssessmentDecision = 'registered' | 'previewed' | 'skipped'

export interface AssessmentOutcome {
  readonly label: string
  readonly decision: AssessmentDecision
  readonly claimRevisionId: Uuid
  readonly certaintyLevel: string
  readonly registered?: EvidenceAssessmentResult
  /** Databasens egen setning om hva som stoppet forslaget. Alltid satt for `skipped`. */
  readonly reason?: string
}

export interface AssessmentReport {
  readonly agentRunId: Uuid
  readonly runStatus: 'succeeded' | 'aborted' | 'failed'
  readonly results: readonly AssessmentOutcome[]
  readonly registered: number
  readonly skipped: number
}

export interface AssessmentRunOptions {
  readonly api: EvidenceAssessmentApi
  readonly premises: AgentRunPremises
  readonly proposals: readonly LabelledAssessmentProposal[]
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
function declarationOf(proposal: EvidenceAssessmentProposal): Record<string, unknown> {
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
 * Registrerer én eller flere evidensvurderinger, i den rekkefølgen de kom.
 *
 * Kjøringen lukkes alltid: `succeeded` når den kom gjennom, `aborted` for en
 * tørrkjøring som med hensikt ikke skrev noe, og `failed` når noe uventet
 * skjedde. En kjøring som ble stående åpen, ville blokkert den neste og
 * etterlatt en proveniensrad uten utfall (migrasjon 005e).
 */
export async function runEvidenceAssessment(
  options: AssessmentRunOptions,
): Promise<AssessmentReport> {
  const { api, premises, proposals, dryRun = false, log = () => {} } = options

  const inputManifest: Record<string, unknown> = {
    proposals: proposals.map((entry) => ({
      label: entry.label,
      proposal_version: entry.proposal.proposalVersion,
      claim_revision_id: entry.proposal.claimRevisionId,
      evidence_set_digest: entry.proposal.evidenceSetDigest,
      certainty_level: entry.proposal.assessment.certaintyLevel,
      generated_by: declarationOf(entry.proposal),
    })),
    dry_run: dryRun,
  }

  const agentRunId = await api.beginRun(premises, inputManifest)
  log(`Agentkjøring åpnet: ${agentRunId}`)

  const results: AssessmentOutcome[] = []

  try {
    for (const { label, proposal } of proposals) {
      log(`\n${label}`)
      const target = {
        label,
        claimRevisionId: proposal.claimRevisionId,
        certaintyLevel: proposal.assessment.certaintyLevel,
      }

      if (dryRun) {
        log('— formen er kontrollert (tørrkjøring, ingenting registrert).')
        results.push({ ...target, decision: 'previewed' })
        continue
      }

      try {
        const registered = parseEvidenceAssessmentResult(
          await api.registerAssessment({
            agentRunId,
            claimRevisionId: proposal.claimRevisionId,
            seenEvidenceSetDigest: proposal.evidenceSetDigest,
            assessment: proposal.assessment,
          }),
        )
        log(
          `— registrert som evidensvurdering ${registered.evidenceAssessmentId} ` +
            `for revisjon ${registered.claimRevisionId}, ` +
            `samlet sikkerhet ${registered.certaintyLevel}.`,
        )
        results.push({ ...target, decision: 'registered', registered })
      } catch (cause) {
        const reason = cause instanceof Error ? cause.message : String(cause)

        if (!isProposalRejection(cause)) {
          // Enten en driftsfeil, eller et ukjent utfall. Kjøringen skal ikke
          // fortsette som om raden ikke finnes, og den skal ikke lukkes som
          // `succeeded`: den ytre fangsten under lukker den som `failed` og lar
          // årsaken nå kalleren.
          throw new Error(
            `${label}: registreringen ble ikke bekreftet, og utfallet er ukjent. ` +
              'Kontroller i /review om revisjonen har fått en evidensvurdering FØR du kjører ' +
              'filen om igjen — skriveveien er ikke idempotent. ' +
              `Årsak: ${reason}`,
            { cause },
          )
        }

        log(`— ingen evidensvurdering registrert. ${reason}`)
        results.push({ ...target, decision: 'skipped', reason })
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
        'Tørrkjøring: formen er kontrollert, men ingen evidensvurdering ble registrert.',
      )
      return { agentRunId, runStatus: 'aborted', results, registered: 0, skipped: 0 }
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
