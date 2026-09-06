// ============================================================================
// Selve agentkjøringen: fra åpnet kjøring til registrert verifikasjon
//
// Kjeden MVP_IMPLEMENTATION_PLAN.md §15 ledd 3 beskriver, kjørt i praksis:
//
//   api.begin_agent_run                  premissene registreres
//   api.extraction_verification_input    grunnlaget hentes (005h)
//   retrieveRepresentation               kilden hentes på nytt, over nett
//   checkExtraction                      kontrollen gjøres, deterministisk
//   api.register_extraction_verification resultatet registreres (005g)
//   api.complete_agent_run               kjøringen lukkes
//
// Alt som rører omverdenen er injisert (`api`, `retrieve`, `log`), så hele
// orkestreringen kan prøves uten database og uten nett.
//
// ----------------------------------------------------------------------------
// Når kjøringen IKKE registrerer noe, og hvorfor det er det strengeste valget
//
// `workflow.evidence_verifications.source_access` er en påstand om hva
// verifikatoren faktisk hadde tilgang til, og den skal være sann. Tre tilfeller
// gir ingen rad i det hele tatt:
//
//   1. Funnet har ingen registrert kildeversjon, eller kildeversjonen har ingen
//      content_hash. Da finnes det ikke noe etterprøvbart grunnlag å vise til
//      (MVP_IMPLEMENTATION_PLAN.md §74.32), og databasen ville avvist
//      `verifiable_representation` uansett.
//   2. Kilden lot seg ikke hente. En kontroll som ikke fikk se kilden, er ingen
//      kontroll (ANTIDEP_CONSTITUTION.md §11).
//   3. Kilden lot seg hente, men fingeravtrykket stemmer ikke med den
//      registrerte kildeversjonen. Da har verifikatoren sett *en* utgave, men
//      ikke den ekstraksjonen ble gjort fra — og ingen av de tre verdiene i
//      `workflow.verification_source_access` beskriver det sant.
//
// Det tredje tilfellet er det viktigste, og det er bevisst ikke gjort om til en
// `uncertain`-rad: en rad må oppgi et kildegrunnlag, og å oppgi et som ikke er
// sant for å få registrert at kontrollen mislyktes, ville vært å bytte en
// manglende opplysning mot en usann. Avviket forsvinner ikke — det står i
// kjøringens `output_manifest`, som er proveniensen for KI-operasjoner
// (DATABASE_ARCHITECTURE.md §33), og kjøringen er sporbar derfra.
// ============================================================================

import type { Uuid } from '../types/api.ts'
import type {
  AgentRunPremises,
  ExtractionVerificationApi,
  RegisterVerificationArgs,
} from './agent-api.ts'
import { checkExtraction, type ExtractionCheckReport } from './extraction-checks.ts'
import type { RetrievalResult, RetrieveOptions } from './source-retrieval.ts'
import { retrieveRepresentation } from './source-retrieval.ts'
import { parseVerificationInput, type VerificationItem } from './verification-input.ts'

/**
 * `workflow.verification_source_access`. Den eneste verdien denne kjøreren
 * bruker: den henter kildeversjonens adresse på nytt og kontrollerer den mot
 * fingeravtrykket, og det er nøyaktig det `verifiable_representation` beskriver
 * (migrasjon 005g, §74.32).
 */
const SOURCE_ACCESS = 'verifiable_representation'

export type ItemDecision = 'registered' | 'previewed' | 'skipped'

export interface ItemResult {
  readonly evidenceItemId: Uuid
  readonly sourceTitle: string
  readonly decision: ItemDecision
  readonly verificationId?: Uuid
  readonly outcome?: ExtractionCheckReport['outcome']
  readonly checkedFields?: readonly string[]
  readonly findings?: string | null
  /** Hvorfor ingen rad ble registrert. Alltid satt for `skipped`. */
  readonly reason?: string
}

export interface RunReport {
  readonly agentRunId: Uuid
  readonly runStatus: 'succeeded' | 'aborted' | 'failed'
  readonly items: readonly ItemResult[]
}

export type RetrieveLike = (url: string) => Promise<RetrievalResult>

export interface RunOptions {
  readonly api: ExtractionVerificationApi
  readonly premises: AgentRunPremises
  /** Ett bestemt evidensfunn, eller `null` for hele arbeidskøen. */
  readonly evidenceItemId?: Uuid | null
  /** Kontroller og rapporter, men registrer ingenting. */
  readonly dryRun?: boolean
  /** Hvor mange funn kjøringen tar i ett. `null` for alle. */
  readonly limit?: number | null
  readonly retrieve?: RetrieveLike
  readonly retrieveOptions?: RetrieveOptions
  readonly log?: (line: string) => void
}

function summarize(item: VerificationItem): string {
  return `${item.evidenceItemId} (${item.sourceTitle})`
}

async function evaluateItem(
  item: VerificationItem,
  retrieve: RetrieveLike,
): Promise<
  | { readonly kind: 'skip'; readonly reason: string }
  | { readonly kind: 'checked'; readonly report: ExtractionCheckReport }
> {
  const version = item.sourceVersion
  if (version === null) {
    return {
      kind: 'skip',
      reason:
        'Funnet har ingen registrert kildeversjon, så det finnes ingen adresse og ingen ' +
        'fingeravtrykk å kontrollere mot.',
    }
  }
  if (version.contentHash === null) {
    return {
      kind: 'skip',
      reason:
        `Kildeversjonen (${version.retrievedFrom}) har ingen content_hash. Et sporet besøk ` +
        'uten fingeravtrykk er ikke en etterprøvbar representasjon.',
    }
  }

  const retrieved = await retrieve(version.retrievedFrom)
  if (retrieved.status === 'error') {
    return { kind: 'skip', reason: retrieved.message }
  }

  const representation = retrieved.representation
  if (!representation.bytesAreUtf8) {
    return {
      kind: 'skip',
      reason:
        `Svaret fra ${version.retrievedFrom} er ikke ren UTF-8, så fingeravtrykket kan ikke ` +
        'sammenlignes byte for byte med den registrerte kildeversjonen.',
    }
  }

  if (representation.contentHash !== version.contentHash) {
    return {
      kind: 'skip',
      reason:
        `Kilden har endret seg: ${version.retrievedFrom} gir nå ${representation.contentHash}, ` +
        `mens kildeversjonen er registrert med ${version.contentHash}. Kontrollen ville ` +
        'gjeldt en annen utgave enn ekstraksjonen ble gjort fra.',
    }
  }

  return {
    kind: 'checked',
    report: checkExtraction({
      item,
      sourceText: representation.content,
      representationReproduced: true,
    }),
  }
}

/**
 * Kjører ekstraksjonsverifikasjonen for ett funn eller for hele køen.
 *
 * Kjøringen lukkes alltid: `succeeded` når den kom gjennom, `aborted` for en
 * tørrkjøring som med hensikt ikke skrev noe, og `failed` når noe uventet
 * skjedde. En kjøring som ble stående åpen, ville blokkert den neste og
 * etterlatt en proveniensrad uten utfall (migrasjon 005e).
 */
export async function runExtractionVerification(options: RunOptions): Promise<RunReport> {
  const {
    api,
    premises,
    evidenceItemId = null,
    dryRun = false,
    limit = null,
    log = () => {},
  } = options
  const retrieve: RetrieveLike =
    options.retrieve ?? ((url) => retrieveRepresentation(url, options.retrieveOptions ?? {}))

  const inputManifest: Record<string, unknown> = {
    mode: evidenceItemId === null ? 'queue' : 'single',
    evidence_item_id: evidenceItemId,
    dry_run: dryRun,
    limit,
    check: 'deterministic-extraction-check',
  }

  const agentRunId = await api.beginRun(premises, inputManifest)
  log(`Agentkjøring åpnet: ${agentRunId}`)

  const results: ItemResult[] = []

  try {
    const input = parseVerificationInput(await api.readInput(agentRunId, evidenceItemId))
    const queue = limit === null ? input.items : input.items.slice(0, limit)
    log(
      `${String(input.items.length)} evidensfunn i grunnlaget, ${String(queue.length)} tas i denne kjøringen.`,
    )

    for (const item of queue) {
      const evaluation = await evaluateItem(item, retrieve)

      if (evaluation.kind === 'skip') {
        log(`— ${summarize(item)}: ingen verifikasjon registrert. ${evaluation.reason}`)
        results.push({
          evidenceItemId: item.evidenceItemId,
          sourceTitle: item.sourceTitle,
          decision: 'skipped',
          reason: evaluation.reason,
        })
        continue
      }

      const report = evaluation.report
      if (dryRun) {
        log(`— ${summarize(item)}: ${report.outcome} (tørrkjøring, ingenting registrert).`)
        results.push({
          evidenceItemId: item.evidenceItemId,
          sourceTitle: item.sourceTitle,
          decision: 'previewed',
          outcome: report.outcome,
          checkedFields: report.checkedFields,
          findings: report.findings,
        })
        continue
      }

      const args: RegisterVerificationArgs = {
        agentRunId,
        evidenceItemId: item.evidenceItemId,
        outcome: report.outcome,
        sourceAccess: SOURCE_ACCESS,
        checkedFields: report.checkedFields,
        rationale: report.rationale,
        findings: report.findings,
      }
      const verificationId = await api.registerVerification(args)
      log(`— ${summarize(item)}: ${report.outcome}, registrert som ${verificationId}.`)
      results.push({
        evidenceItemId: item.evidenceItemId,
        sourceTitle: item.sourceTitle,
        decision: 'registered',
        verificationId,
        outcome: report.outcome,
        checkedFields: report.checkedFields,
        findings: report.findings,
      })
    }

    const outputManifest: Record<string, unknown> = {
      checked: results.length,
      registered: results.filter((result) => result.decision === 'registered').length,
      skipped: results.filter((result) => result.decision === 'skipped').length,
      results,
    }

    if (dryRun) {
      await api.completeRun(
        agentRunId,
        'aborted',
        outputManifest,
        'Tørrkjøring: kontrollen ble gjennomført, men ingen verifikasjon ble registrert.',
      )
      return { agentRunId, runStatus: 'aborted', items: results }
    }

    await api.completeRun(agentRunId, 'succeeded', outputManifest, null)
    return { agentRunId, runStatus: 'succeeded', items: results }
  } catch (cause) {
    const reason = cause instanceof Error ? cause.message : String(cause)
    // Kjøringen lukkes selv om lukkingen også feiler: den opprinnelige årsaken
    // er den som skal nå kalleren, ikke en oppfølgingsfeil på vei ut.
    try {
      await api.completeRun(agentRunId, 'failed', null, reason.slice(0, 4000))
    } catch {
      log(`Kjøringen ${agentRunId} kunne ikke lukkes etter feilen under.`)
    }
    throw cause
  }
}
