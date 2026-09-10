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
  /**
   * Et snevrere utvalg av inndataen enn `evidenceItemId` alene gir.
   *
   * Hvilken rad kjøringen gjelder, avgjøres av `evidenceItemId`, og ingenting
   * annet: re-ekstraksjonen får id-en fra registreringen, eller — når den samme
   * ekstraksjonen alt var registrert — fra dublettavvisningen, som navngir raden
   * etter den samme kanoniske identiteten som UNIQUE-regelen bruker (migrasjon
   * 007h). Utvalget her gjenfinner altså ingenting; det avgjør bare hva som
   * faktisk skal kontrolleres av det kalleren allerede har pekt på.
   *
   * Re-ekstraksjonen trenger det til én ting: et funn som allerede bærer et
   * gjeldende maskinbevis, skal ikke kontrolleres om igjen — en ny kontroll ville
   * vært en ny rad uten et nytt svar, og den samme filen kjørt om igjen skal ikke
   * skrive noe.
   *
   * Inndataen sendes derfor inn som den er, ikke som et ja eller nei. Ingen
   * kontroll blir løsere av det: hvert funn som slipper gjennom, kontrolleres
   * nøyaktig som før.
   */
  readonly select?: (items: readonly VerificationItem[]) => readonly VerificationItem[]
  readonly log?: (line: string) => void
}

function summarize(item: VerificationItem): string {
  return `${item.evidenceItemId} (${item.sourceTitle})`
}

/**
 * Vurderer ett funn, og lar aldri en uventet feil nå kalleren.
 *
 * Kildeinnhold er utrygg ekstern data, og en representasjon kan inneholde noe
 * ingen har tenkt på. Skulle kontrollen kaste, er det den ene kilden som ikke
 * lot seg kontrollere — ikke hele køen. Uten denne innkapslingen ville én slik
 * kilde stoppet alle funnene bak seg i køen, og det er en tilgjengelighetsfeil
 * som ser ut som en tom arbeidsliste.
 *
 * Feilen forsvinner ikke: den blir årsaken raden føres som overhoppet med, og
 * står i kjøringens `output_manifest`.
 */
async function evaluateItem(
  item: VerificationItem,
  retrieve: RetrieveLike,
): Promise<
  | { readonly kind: 'skip'; readonly reason: string }
  | { readonly kind: 'checked'; readonly report: ExtractionCheckReport }
> {
  try {
    return await evaluateItemUnguarded(item, retrieve)
  } catch (cause) {
    const reason = cause instanceof Error ? cause.message : String(cause)
    return {
      kind: 'skip',
      reason: `Kontrollen av dette funnet feilet uventet, og ble ikke registrert: ${reason}`,
    }
  }
}

async function evaluateItemUnguarded(
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
    // `selected` sier at kjøringen arbeidet på et utvalg av køen, ikke på hele
    // den. Uten det ville manifestet påstått «queue» om en kjøring som bevisst
    // lot resten av køen stå.
    mode:
      evidenceItemId === null ? (options.select === undefined ? 'queue' : 'selected') : 'single',
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
    const selected = options.select === undefined ? input.items : options.select(input.items)
    const queue = limit === null ? selected : selected.slice(0, limit)
    log(
      `${String(input.items.length)} evidensfunn i grunnlaget, ${String(queue.length)} tas i denne kjøringen.`,
    )
    if (options.select !== undefined) {
      log(
        `Utvalget er avgrenset til funn som svarer til forslaget: ` +
          `${String(selected.length)} av ${String(input.items.length)}.`,
      )
    }

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
      // Registreringen ligger innenfor den samme innkapslingen som kontrollen:
      // en avvist rad — en verdi basen ikke tar imot, et brudd på en
      // begrensning — er den ene radens problem, ikke køens. Uten dette ville
      // én slik avvisning felt hele kjøringen, og de øvrige funnene ville
      // stått ukontrollert av en grunn som ikke er deres.
      let verificationId: Uuid
      try {
        verificationId = await api.registerVerification(args)
      } catch (cause) {
        const reason = cause instanceof Error ? cause.message : String(cause)
        log(`— ${summarize(item)}: ingen verifikasjon registrert. ${reason}`)
        results.push({
          evidenceItemId: item.evidenceItemId,
          sourceTitle: item.sourceTitle,
          decision: 'skipped',
          reason: `Registreringen ble avvist av databasen: ${reason}`,
        })
        continue
      }
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
