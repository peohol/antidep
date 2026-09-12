// ============================================================================
// Selve agentkjøringen: fra åpnet kjøring til registrert verifikasjon
//
// Kjeden MVP_IMPLEMENTATION_PLAN.md §15 ledd 3 beskriver, kjørt i praksis:
//
//   api.begin_agent_run                  premissene registreres
//   api.extraction_verification_input    grunnlaget hentes (005h)
//   resolveRepresentation                kilden skaffes på nytt: hentet fra
//                                        adressen, eller hentet ut av
//                                        originaldokumentet
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
import {
  readAbsenceReviewOutcome,
  writeAbsenceReviewJob,
  type AbsenceReviewJobReport,
} from './absence-review-job.ts'
import { checkExtraction, type ExtractionCheckReport } from './extraction-checks.ts'
import { CommittablePathRefused } from './git-paths.ts'
import { resolveRepresentation, type ResolvePorts } from './source-binding.ts'
import type { RetrieveLike } from './source-retrieval.ts'
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
  /** Kjøremappa den kildeomfattende gjennomlesningen ble lagt igjen i, når den ble skrevet. */
  readonly absencePromptDirectory?: string
  /**
   * Hva en kildeomfattende dekning hvilte på, når en ble gitt.
   *
   * Står i kjøringens `output_manifest` fordi den er proveniensen for et
   * KI-ledd som kan være den avgjørende grunnen til at publiseringsgaten åpnet:
   * hvilken modell som vurderte, når, mot hvilken forespørsel og hvilket svar —
   * og for et `not_measured` det ordrette stedet kilden sier at størrelsen ikke
   * ble målt. Uten det ville beviset bare ligget i en midlertidig arbeidsmappe
   * (EVIDENCE_PIPELINE.md §3.7, §65).
   */
  readonly sourceWideAbsence?: ExtractionCheckReport['sourceWideAbsence']
}

export interface RunReport {
  readonly agentRunId: Uuid
  readonly runStatus: 'succeeded' | 'aborted' | 'failed'
  readonly items: readonly ItemResult[]
}

export type { RetrieveLike }

export interface RunOptions extends ResolvePorts {
  readonly api: ExtractionVerificationApi
  readonly premises: AgentRunPremises
  /** Ett bestemt evidensfunn, eller `null` for hele arbeidskøen. */
  readonly evidenceItemId?: Uuid | null
  /** Kontroller og rapporter, men registrer ingenting. */
  readonly dryRun?: boolean
  /** Hvor mange funn kjøringen tar i ett. `null` for alle. */
  readonly limit?: number | null
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
  /**
   * Katalogen de kildeomfattende gjennomlesningene leses fra.
   *
   * Uten den dekkes `source_wide_absence` aldri, og et funn som fører et
   * globalt fravær kommer ut som `uncertain` med en begrunnelse som sier at
   * halvdelen står åpen. Det er riktig svar og ikke en mangel: et deterministisk
   * søk som ikke fant noe, er ikke et bevis for et fravær (issue #74).
   */
  readonly absenceReviews?: string | null
  /**
   * Katalogen forespørslene om en slik gjennomlesning legges igjen i.
   *
   * Settes den, registrerer kjøringen ingenting: den henter representasjonen,
   * skriver prompten for hvert funn som fører et globalt fravær, og lukkes som
   * en tørrkjøring. Aktøren som svarer, ser bare filer.
   */
  readonly absencePrompts?: string | null
  readonly log?: (line: string) => void
}

function summarize(item: VerificationItem): string {
  return `${item.evidenceItemId} (${item.sourceTitle})`
}

/** Hvor de kildeomfattende gjennomlesningene leses fra og skrives til. */
interface AbsencePorts {
  readonly reviews: string | null
  readonly prompts: string | null
}

type Evaluation =
  | { readonly kind: 'skip'; readonly reason: string }
  | {
      readonly kind: 'checked'
      readonly report: ExtractionCheckReport
      /** Mappa forespørselen ble lagt igjen i, eller `null` når ingen ble skrevet. */
      readonly promptDirectory: string | null
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
  ports: ResolvePorts,
  absence: AbsencePorts,
): Promise<Evaluation> {
  try {
    return await evaluateItemUnguarded(item, ports, absence)
  } catch (cause) {
    // Ett unntak slipper forbi innkapslingen: en kjøremappe kildeteksten ikke
    // får skrives til. Den gjelder katalogen operatøren oppgav, altså hvert funn
    // i køen, og et `skip` per funn ville gjort en feil i oppsettet til en
    // egenskap ved radene. Kjøringen lukkes som `failed` med grunnen
    // (`git-paths.ts`).
    if (cause instanceof CommittablePathRefused) {
      throw cause
    }
    const reason = cause instanceof Error ? cause.message : String(cause)
    return {
      kind: 'skip',
      reason: `Kontrollen av dette funnet feilet uventet, og ble ikke registrert: ${reason}`,
    }
  }
}

async function evaluateItemUnguarded(
  item: VerificationItem,
  ports: ResolvePorts,
  absence: AbsencePorts,
): Promise<Evaluation> {
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

  // Hvordan representasjonen skaffes, avgjøres av den registrerte raden og ikke
  // av kjøringen: en dokumentbundet versjon hentes ut av originaldokumentet med
  // den registrerte oppskriften, aldri over nett, og en tekstversjon hentes fra
  // adressen (`source-binding.ts`, migrasjon 003e). Uten dokumentet konkluderer
  // kontrollen ikke — den henter aldri adressen i stedet, for da ville den
  // gjeldt en annen tekst enn ekstraksjonen ble gjort fra.
  const resolved = await resolveRepresentation(
    {
      retrievedFrom: version.retrievedFrom,
      contentHash: version.contentHash,
      document: version.document,
    },
    ports,
  )
  if (resolved.status === 'error') {
    return { kind: 'skip', reason: resolved.message }
  }

  // Den kildeomfattende halvdelen, når raden fører et globalt fravær. Begge
  // veier bruker NØYAKTIG den teksten kontrollen selv hentet: forespørselen
  // bygges av den, og svaret bindes til avtrykket av den. Et svar avgitt på en
  // annen utgave av kilden kan derfor ikke dekke noe her.
  const needsAbsence = item.sourceWideAbsenceFields.length > 0
  const job = { item, representation: resolved.text, contentHash: version.contentHash }

  let promptJob: AbsenceReviewJobReport | null = null
  if (needsAbsence && absence.prompts != null) {
    promptJob = await writeAbsenceReviewJob({ ...job, directory: absence.prompts })
  }

  const absenceReview =
    needsAbsence && absence.reviews != null
      ? await readAbsenceReviewOutcome({ ...job, directory: absence.reviews })
      : null

  return {
    kind: 'checked',
    report: checkExtraction({
      item,
      sourceText: resolved.text,
      representationReproduced: true,
      absenceReview,
      // Satt bare når den registrerte oppskriften er avløst og dagens kom fram
      // til nøyaktig det registrerte fingeravtrykket. Kontrollen fører det i
      // begrunnelsen, slik at et menneske ser hvilken oppskrift som faktisk
      // gjenskapte teksten (`source-binding.ts`).
      reproducedWith: resolved.reproducedWith ?? null,
    }),
    promptDirectory: promptJob?.directory ?? null,
  }
}

/**
 * Om kjøringen i det hele tatt kan skaffe representasjonen til dette funnet.
 *
 * Bare dokumentbundne funn kan svare nei: teksten deres finnes ikke på noen
 * adresse, og et ledd uten originaldokumentet henter aldri `retrieved_from` i
 * stedet (`source-binding.ts`). Kontrollen er hele oppslaget og ikke bare «har
 * kjøringen en dokumentkatalog»: katalogen finnes alltid, den er bare tom der
 * dokumentene ikke ligger.
 *
 * Den kjører ikke tekstuttrekkingen. Spørsmålet her er om dokumentet er
 * tilgjengelig, ikke om kontrollen går gjennom.
 */
async function documentIsAvailable(item: VerificationItem, ports: ResolvePorts): Promise<boolean> {
  const document = item.sourceVersion?.document ?? null
  if (document === null) {
    return true
  }
  if (ports.documents === undefined) {
    return false
  }
  try {
    return (await ports.documents(document.sha256)).status === 'ok'
  } catch {
    return false
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
    limit = null,
    absenceReviews = null,
    absencePrompts = null,
    log = () => {},
  } = options
  const absence: AbsencePorts = { reviews: absenceReviews, prompts: absencePrompts }
  // Å legge igjen forespørsler er per definisjon en tørrkjøring: kjøringen
  // stiller et spørsmål den ennå ikke har svaret på, og en rad registrert før
  // svaret foreligger ville vært en kontroll som konkluderte uten det ene
  // leddet som kan konkludere.
  const dryRun = (options.dryRun ?? false) || absencePrompts !== null
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
    // Om den kildeomfattende halvdelen i det hele tatt kunne bli dekket i denne
    // kjøringen. En kjøring uten gjennomlesninger lar hvert globale fravær stå
    // åpent, og proveniensen skal si det framfor å la det se ut som et funn.
    source_wide_absence_reviews: absenceReviews === null ? 'none' : 'provided',
    source_wide_absence_prompts: absencePrompts === null ? 'none' : 'written',
  }

  const agentRunId = await api.beginRun(premises, inputManifest)
  log(`Agentkjøring åpnet: ${agentRunId}`)

  const results: ItemResult[] = []

  try {
    const input = parseVerificationInput(await api.readInput(agentRunId, evidenceItemId))
    const selected = options.select === undefined ? input.items : options.select(input.items)

    // Funn kjøringen ikke kan skaffe dokumentet til, tas ut *før* grensen — ikke
    // etter.
    //
    // Uten det ville en kjøring med `--limit` sultet: køen er sortert på
    // created_at, et overhoppet funn får ingen verifikasjonsrad og blir derfor
    // stående i køen, og en hostet kjøring uten dokumentene ville tatt de samme
    // n dokumentbundne funnene om igjen hver eneste gang — og aldri nådd fram
    // til dem den faktisk kan kontrollere over nett.
    //
    // De rapporteres likevel, med en begrunnelse som sier hva som må gjøres.
    // De bruker bare ikke opp plassen til noe som kunne blitt kontrollert.
    const unavailable: VerificationItem[] = []
    const available: VerificationItem[] = []
    for (const item of selected) {
      ;((await documentIsAvailable(item, options)) ? available : unavailable).push(item)
    }

    const queue = limit === null ? available : available.slice(0, limit)
    log(
      `${String(input.items.length)} evidensfunn i grunnlaget, ${String(queue.length)} tas i denne kjøringen.`,
    )
    if (options.select !== undefined) {
      log(
        `Utvalget er avgrenset til funn som svarer til forslaget: ` +
          `${String(selected.length)} av ${String(input.items.length)}.`,
      )
    }
    if (unavailable.length > 0) {
      log(
        `${String(unavailable.length)} funn er utledet av et originaldokument som ikke ligger i ` +
          'dokumentkatalogen. De kontrolleres fra en maskin som har dokumentet, og teller ikke ' +
          'mot --limit.',
      )
    }

    for (const item of unavailable) {
      // Setningen er hele beskjeden operatøren får, og den skal navngi den
      // kjøringen som faktisk lukker gaten for nettopp dette funnet. Fører raden
      // et globalt fravær, holder det ikke å kontrollere én gang: den halvdelen
      // avgjøres av to trinn, og en kommando uten dem ville gitt `uncertain` om
      // igjen uten å si hvorfor (migrasjon 005ae, `absence-review-job.ts`).
      const command = `ANTIDEP_DOCUMENT_DIR=<katalog> npm run agent:verify-extraction -- --evidence-item ${item.evidenceItemId}`
      const reason =
        'Funnet er utledet av originaldokumentet ' +
        `${item.sourceVersion?.document?.sha256 ?? 'ukjent'}, som ikke ligger i ` +
        'dokumentkatalogen denne kjøringen leser. Kontrollen krever dokumentet, og henter aldri ' +
        'adressen i stedet. Kjør den fra en maskin som har det: ' +
        (item.sourceWideAbsenceFields.length > 0
          ? `${command} --absence-prompts <katalog> — la deretter en aktør uten legitimasjon ` +
            `svare i svar.json, og kjør ${command} --absence-reviews <katalog> for å registrere. ` +
            'Funnet fører et fravær som gjelder hele kildeversjonen, og den halvdelen dekkes ' +
            'bare av de to trinnene.'
          : command)
      log(`— ${summarize(item)}: ingen verifikasjon registrert. ${reason}`)
      results.push({
        evidenceItemId: item.evidenceItemId,
        sourceTitle: item.sourceTitle,
        decision: 'skipped',
        reason,
      })
    }

    for (const item of queue) {
      const evaluation = await evaluateItem(item, options, absence)

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
      if (evaluation.promptDirectory !== null) {
        log(
          `— ${summarize(item)}: forespørsel om kildeomfattende gjennomlesning lagt i ` +
            `${evaluation.promptDirectory}.`,
        )
      }
      if (dryRun) {
        log(`— ${summarize(item)}: ${report.outcome} (tørrkjøring, ingenting registrert).`)
        results.push({
          evidenceItemId: item.evidenceItemId,
          sourceTitle: item.sourceTitle,
          decision: 'previewed',
          outcome: report.outcome,
          checkedFields: report.checkedFields,
          findings: report.findings,
          ...(evaluation.promptDirectory === null
            ? {}
            : { absencePromptDirectory: evaluation.promptDirectory }),
          ...(report.sourceWideAbsence === undefined
            ? {}
            : { sourceWideAbsence: report.sourceWideAbsence }),
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
        ...(report.sourceWideAbsence === undefined
          ? {}
          : { sourceWideAbsence: report.sourceWideAbsence }),
      })
    }

    const outputManifest: Record<string, unknown> = {
      checked: results.length,
      registered: results.filter((result) => result.decision === 'registered').length,
      skipped: results.filter((result) => result.decision === 'skipped').length,
      // Overhoppet fordi originaldokumentet ikke lå i katalogen — ikke fordi
      // kontrollen fant noe galt. Tallet står for seg selv, slik at «hva gjorde
      // denne kjøringen» kan besvares uten å lese hver begrunnelse.
      skipped_without_document: unavailable.length,
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
