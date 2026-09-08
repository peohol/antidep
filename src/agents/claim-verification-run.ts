// ============================================================================
// Selve agentkjøringen: fra åpnet kjøring til registrert claim-verifikasjon
//
// Kjeden MVP_IMPLEMENTATION_PLAN.md §15 ledd 7 beskriver, kjørt i praksis:
//
//   api.begin_agent_run             premissene registreres
//   api.claim_verification_input    grunnlaget hentes (005k)
//   retrieveRepresentation          hver kildeversjon hentes på nytt, over nett
//   checkClaim                      kontrollen gjøres, deterministisk
//   api.register_claim_verification resultatet registreres (005k)
//   api.complete_agent_run          kjøringen lukkes
//
// Alt som rører omverdenen er injisert (`api`, `retrieve`, `log`), så hele
// orkestreringen kan prøves uten database og uten nett — samme form som
// `extraction-verification-run.ts`.
//
// ----------------------------------------------------------------------------
// Hvorfor en revisjon hoppes over i sin helhet
//
// En claim-verifikasjon må dekke **hele** evidenssettet til revisjonen
// (workflow.assert_claim_verification_complete). Det er ikke en teknisk
// begrensning: en påstand hviler på hele grunnlaget sitt, også den delen som
// motsier den (ANTIDEP_CONSTITUTION.md §4, §9), og en kontroll som hoppet over
// en lenke ville bekreftet påstanden uten å ha sett det som kunne felt den.
//
// Lar én av lenkenes kildeversjoner seg ikke etterprøve, kan kontrollen derfor
// ikke registreres delvis — og den skal ikke registreres med en usann
// `source_access` for å få skrevet at den mislyktes. Revisjonen hoppes over, og
// grunnen står i kjøringens `output_manifest`, som er proveniensen for
// KI-operasjoner (DATABASE_ARCHITECTURE.md §33).
//
// Fire tilfeller gir ingen rad:
//
//   1. En lenkes evidensfunn har ingen registrert kildeversjon, eller
//      kildeversjonen har ingen content_hash. Da finnes det ikke noe
//      etterprøvbart grunnlag å vise til (§74.32).
//   2. Kilden lot seg ikke hente. En kontroll som ikke fikk se kilden, er ingen
//      kontroll (ANTIDEP_CONSTITUTION.md §11).
//   3. Svaret er ikke ren UTF-8, så fingeravtrykket kan ikke sammenlignes byte
//      for byte med det registrerte.
//   4. Fingeravtrykket stemmer ikke. Da har verifikatoren sett *en* utgave, men
//      ikke den ekstraksjonen ble gjort fra.
// ============================================================================

import type { Uuid } from '../types/api.ts'
import type {
  AgentRunPremises,
  ClaimVerificationApi,
  RegisterClaimVerificationArgs,
} from './agent-api.ts'
import { checkClaim, type ClaimCheckReport, type CheckedLink } from './claim-checks.ts'
import { parseClaimVerificationInput, type ClaimRevisionInput } from './claim-verification-input.ts'
import type { RetrievalResult, RetrieveOptions } from './source-retrieval.ts'
import { retrieveRepresentation } from './source-retrieval.ts'

/**
 * `workflow.verification_source_access`. Den eneste verdien denne kjøreren
 * bruker: den henter hver kildeversjons adresse på nytt og kontrollerer den mot
 * fingeravtrykket, og det er nøyaktig det `verifiable_representation` beskriver
 * (§74.32).
 */
const SOURCE_ACCESS = 'verifiable_representation'

/** Lengdegrensen `workflow.claim_verifications` og kontrollradene håndhever. */
const MAX_TEXT = 4000

export type RevisionDecision = 'registered' | 'previewed' | 'skipped'

export interface RevisionResult {
  readonly claimRevisionId: Uuid
  readonly statement: string
  readonly decision: RevisionDecision
  readonly verificationId?: Uuid
  readonly outcome?: ClaimCheckReport['outcome']
  readonly checks?: ClaimCheckReport['checks']
  readonly findings?: string | null
  /** Hvorfor ingen rad ble registrert. Alltid satt for `skipped`. */
  readonly reason?: string
}

export interface RunReport {
  readonly agentRunId: Uuid
  readonly runStatus: 'succeeded' | 'aborted' | 'failed'
  readonly revisions: readonly RevisionResult[]
}

export type RetrieveLike = (url: string) => Promise<RetrievalResult>

export interface RunOptions {
  readonly api: ClaimVerificationApi
  readonly premises: AgentRunPremises
  /** Én bestemt påstandsrevisjon, eller `null` for hele arbeidskøen. */
  readonly claimRevisionId?: Uuid | null
  /** Kontroller og rapporter, men registrer ingenting. */
  readonly dryRun?: boolean
  /** Hvor mange revisjoner kjøringen tar i ett. `null` for alle. */
  readonly limit?: number | null
  readonly retrieve?: RetrieveLike
  readonly retrieveOptions?: RetrieveOptions
  readonly log?: (line: string) => void
}

/**
 * Trimmer og kutter en tekst til det databasen tar imot.
 *
 * Grensene er tabellens egne (1-4000 tegn, `btrim`-lik). En kontroll av en
 * revisjon med mange lenker kan skrive mer enn det, og en avvisning på lengde
 * ville betydd at hele kontrollen gikk tapt framfor at teksten ble kortet.
 * Kuttet er markert, slik at en leser ser at det er kuttet.
 */
export function clampText(value: string): string {
  const trimmed = value.trim()
  if (trimmed.length <= MAX_TEXT) {
    return trimmed
  }
  const marker = '\n- […] Funnlisten er kuttet for å passe grensen på 4000 tegn.'
  return trimmed.slice(0, MAX_TEXT - marker.length).trim() + marker
}

function summarize(revision: ClaimRevisionInput): string {
  return `${revision.claimRevisionId} (${revision.subjectDrugName}, ${revision.topicLabel})`
}

/**
 * Henter representasjonene revisjonen trenger, eller sier hvorfor den ikke lot
 * seg kontrollere.
 *
 * Hentingen deles på tvers av lenker som peker på den samme kildeversjonen: to
 * evidensfunn fra samme kilde er vanlig, og to henteforsøk mot samme adresse
 * ville vært to sjanser til å få forskjellig svar.
 */
async function collectLinks(
  revision: ClaimRevisionInput,
  retrieve: RetrieveLike,
  cache: Map<string, string>,
): Promise<
  | { readonly kind: 'ready'; readonly links: readonly CheckedLink[] }
  | { readonly kind: 'skip'; readonly reason: string }
> {
  if (revision.links.length === 0) {
    return {
      kind: 'skip',
      reason:
        'Revisjonen har ingen registrerte evidenslenker. En kontroll av en påstand er en ' +
        'kontroll mot et grunnlag.',
    }
  }

  const links: CheckedLink[] = []

  for (const link of revision.links) {
    const version = link.evidenceItem.sourceVersion
    if (version === null) {
      return {
        kind: 'skip',
        reason:
          `Evidensfunnet i lenke ${link.claimEvidenceLinkId} har ingen registrert kildeversjon, ` +
          'så det finnes ingen adresse og ingen fingeravtrykk å kontrollere mot.',
      }
    }
    if (version.contentHash === null) {
      return {
        kind: 'skip',
        reason:
          `Kildeversjonen (${version.retrievedFrom}) i lenke ${link.claimEvidenceLinkId} har ` +
          'ingen content_hash. Et sporet besøk uten fingeravtrykk er ikke en etterprøvbar ' +
          'representasjon.',
      }
    }

    const cached = cache.get(version.sourceVersionId)
    if (cached !== undefined) {
      links.push({ link, sourceText: cached })
      continue
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

    cache.set(version.sourceVersionId, representation.content)
    links.push({ link, sourceText: representation.content })
  }

  return { kind: 'ready', links }
}

/**
 * Vurderer én revisjon, og lar aldri en uventet feil nå kalleren.
 *
 * Kildeinnhold er utrygg ekstern data, og en representasjon kan inneholde noe
 * ingen har tenkt på. Skulle kontrollen kaste, er det den ene revisjonen som
 * ikke lot seg kontrollere — ikke hele køen. Feilen forsvinner ikke: den blir
 * årsaken revisjonen føres som overhoppet med, og står i kjøringens
 * `output_manifest`.
 */
async function evaluateRevision(
  revision: ClaimRevisionInput,
  retrieve: RetrieveLike,
  cache: Map<string, string>,
): Promise<
  | { readonly kind: 'skip'; readonly reason: string }
  | { readonly kind: 'checked'; readonly report: ClaimCheckReport }
> {
  try {
    const collected = await collectLinks(revision, retrieve, cache)
    if (collected.kind === 'skip') {
      return collected
    }
    return { kind: 'checked', report: checkClaim({ revision, links: collected.links }) }
  } catch (cause) {
    const reason = cause instanceof Error ? cause.message : String(cause)
    return {
      kind: 'skip',
      reason: `Kontrollen av denne revisjonen feilet uventet, og ble ikke registrert: ${reason}`,
    }
  }
}

function registerArgs(
  agentRunId: Uuid,
  revision: ClaimRevisionInput,
  report: ClaimCheckReport,
): RegisterClaimVerificationArgs {
  return {
    agentRunId,
    claimRevisionId: revision.claimRevisionId,
    outcome: report.outcome,
    checks: report.checks,
    citations: report.citations.map((citation) => ({
      claimEvidenceLinkId: citation.claimEvidenceLinkId,
      sourceAccess: SOURCE_ACCESS,
      sourceVersionId: citation.sourceVersionId,
      checkedContentHash: citation.checkedContentHash,
      relationshipSupported: citation.relationshipSupported,
      finding: citation.finding === null ? null : clampText(citation.finding),
    })),
    rationale: clampText(report.rationale),
    findings: report.findings === null ? null : clampText(report.findings),
  }
}

/**
 * Kjører claim-verifikasjonen for én revisjon eller for hele køen.
 *
 * Kjøringen lukkes alltid: `succeeded` når den kom gjennom, `aborted` for en
 * tørrkjøring som med hensikt ikke skrev noe, og `failed` når noe uventet
 * skjedde. En kjøring som ble stående åpen, ville blokkert den neste og
 * etterlatt en proveniensrad uten utfall (migrasjon 005e).
 */
export async function runClaimVerification(options: RunOptions): Promise<RunReport> {
  const {
    api,
    premises,
    claimRevisionId = null,
    dryRun = false,
    limit = null,
    log = () => {},
  } = options
  const retrieve: RetrieveLike =
    options.retrieve ?? ((url) => retrieveRepresentation(url, options.retrieveOptions ?? {}))

  const inputManifest: Record<string, unknown> = {
    mode: claimRevisionId === null ? 'queue' : 'single',
    claim_revision_id: claimRevisionId,
    dry_run: dryRun,
    limit,
    check: 'deterministic-claim-check',
  }

  const agentRunId = await api.beginRun(premises, inputManifest)
  log(`Agentkjøring åpnet: ${agentRunId}`)

  const results: RevisionResult[] = []
  const cache = new Map<string, string>()

  try {
    const input = parseClaimVerificationInput(await api.readInput(agentRunId, claimRevisionId))
    const queue = limit === null ? input.revisions : input.revisions.slice(0, limit)
    log(
      `${String(input.revisions.length)} påstandsrevisjoner i grunnlaget, ` +
        `${String(queue.length)} tas i denne kjøringen.`,
    )

    for (const revision of queue) {
      const evaluation = await evaluateRevision(revision, retrieve, cache)

      if (evaluation.kind === 'skip') {
        log(`— ${summarize(revision)}: ingen kontroll registrert. ${evaluation.reason}`)
        results.push({
          claimRevisionId: revision.claimRevisionId,
          statement: revision.claim.statement,
          decision: 'skipped',
          reason: evaluation.reason,
        })
        continue
      }

      const report = evaluation.report
      if (dryRun) {
        log(`— ${summarize(revision)}: ${report.outcome} (tørrkjøring, ingenting registrert).`)
        results.push({
          claimRevisionId: revision.claimRevisionId,
          statement: revision.claim.statement,
          decision: 'previewed',
          outcome: report.outcome,
          checks: report.checks,
          findings: report.findings,
        })
        continue
      }

      // Registreringen ligger innenfor den samme innkapslingen som kontrollen:
      // en avvist rad — en verdi basen ikke tar imot, et brudd på en
      // begrensning — er den ene revisjonens problem, ikke køens.
      let verificationId: Uuid
      try {
        verificationId = await api.registerVerification(registerArgs(agentRunId, revision, report))
      } catch (cause) {
        const reason = cause instanceof Error ? cause.message : String(cause)
        log(`— ${summarize(revision)}: ingen kontroll registrert. ${reason}`)
        results.push({
          claimRevisionId: revision.claimRevisionId,
          statement: revision.claim.statement,
          decision: 'skipped',
          reason: `Registreringen ble avvist av databasen: ${reason}`,
        })
        continue
      }

      log(`— ${summarize(revision)}: ${report.outcome}, registrert som ${verificationId}.`)
      results.push({
        claimRevisionId: revision.claimRevisionId,
        statement: revision.claim.statement,
        decision: 'registered',
        verificationId,
        outcome: report.outcome,
        checks: report.checks,
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
        'Tørrkjøring: kontrollen ble gjennomført, men ingen claim-verifikasjon ble registrert.',
      )
      return { agentRunId, runStatus: 'aborted', revisions: results }
    }

    await api.completeRun(agentRunId, 'succeeded', outputManifest, null)
    return { agentRunId, runStatus: 'succeeded', revisions: results }
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
