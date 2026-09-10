// ============================================================================
// Ekstraksjonskjøringen: fra et forslag til et forankret evidensfunn
//
//   api.begin_agent_run           premissene registreres
//   retrieveRepresentation        kilden hentes, over nett
//   (fingeravtrykk)               representasjonen må være den registrerte
//   (ordrett kontroll)            hvert utdrag må stå i den, ordrett
//   api.register_agent_extraction ekstraksjonen registreres, med forankringen
//   api.complete_agent_run        kjøringen lukkes
//
// Alt som rører omverdenen er injisert (`api`, `retrieve`, `log`), så hele
// orkestreringen kan prøves uten database og uten nett.
//
// ----------------------------------------------------------------------------
// Hva denne kjøringen er, og hva den ikke er
//
// Den er *ikke* leddet som leser en artikkel og bestemmer at utvalget var 48.
// Det er `drafting-run.ts`, som er en modelloperasjon uten databasetilgang, og
// forslaget kommer hit som data (`extraction-proposal.ts`) — enten det er
// skrevet av modell-leddet, av ChatGPT utenfor Antidep eller av et menneske.
//
// Den er alt det andre, og det er den delen som må være deterministisk:
// kjøringens proveniens, at representasjonen er nøyaktig den registrerte
// kildeversjonen, at hvert utdrag faktisk står i den, og selve registreringen.
// Kontrollene er de samme uansett hvem som skrev forslaget; det eneste som
// følger med produsenten, er premissene kjøringen registreres under og hvilken
// `extraction_method` raden får (`pipeline-version.ts`).
//
// ----------------------------------------------------------------------------
// Hvorfor utdragene kontrolleres her og ikke bare av verifikatoren
//
// Den deterministiske ekstraksjonskontrollen prøver de samme utdragene senere,
// og det leddet er det som teller: det er en *separat* operasjon, av en annen
// aktør, og uten den kan ingen menneskelig bekreftelse registreres (migrasjon
// 005x). Kontrollen her er ikke den — den er ekstraksjonens egen aktsomhet.
//
// Forskjellen er hva som skjer ved et avvik. Uten kontrollen her ville et
// forslag med et oppdiktet utdrag blitt en rad i basen, som en kontrollør
// senere måtte avvise. Med den blir det ingen rad: kjøringen stopper, sier
// hvilket felt som ikke lot seg finne, og lukkes som `aborted`. Generering og
// verifikasjon er fortsatt to operasjoner (ANTIDEP_CONSTITUTION.md §10) — dette
// er generatoren som lar være å skrive noe den vet er galt.
//
// ----------------------------------------------------------------------------
// Utrygg inndata
//
// Både representasjonen og forslaget er data, aldri instruksjoner (CLAUDE.md).
// Representasjonen brukes bare som høystakk for søk; forslaget kontrolleres på
// form og sendes videre som parametre.
// ============================================================================

import type { Uuid } from '../types/api.ts'
import type { EvidenceExtractionApi } from './agent-api.ts'
import { collidingEvidenceItemId, isUniqueViolation } from './agent-api.ts'
import { assignmentMismatch, type ExtractionAssignment } from './extraction-assignment.ts'
import { searchProjections, verbatimOccursIn } from './extraction-checks.ts'
import type { ExtractionProposal } from './extraction-proposal.ts'
import {
  extractionMethodFor,
  producerForMode,
  registrationModeProblem,
  type RegistrationMode,
} from './extraction-proposal.ts'
import {
  buildExtractionDraftingRequest,
  EXTRACTION_DRAFTING_PROMPT_VERSION,
} from './extraction-prompt.ts'
import { modelRequestDigest } from './model-client.ts'
import { EVIDENCE_EXTRACTION_PREMISES } from './pipeline-version.ts'
import type { RetrieveLike, RetrieveOptions } from './source-retrieval.ts'
import { retrieveRepresentation } from './source-retrieval.ts'

export type { RetrieveLike }

export interface ExtractionRunOptions {
  readonly api: EvidenceExtractionApi
  /**
   * Forslaget kjøringen registrerer.
   *
   * Kjøringens premisser tas ut av det (`extractionPremisesFor`) framfor å
   * oppgis av kalleren: hvem som leste artikkelen, er en egenskap ved forslaget,
   * og en kaller som kunne oppgitt noe annet, kunne registrert et menneskes
   * ekstraksjon som en modells.
   */
  readonly proposal: ExtractionProposal
  /**
   * Oppdraget forslaget skal ha vært laget under, når kalleren har det.
   *
   * Oppgitt, kontrolleres forslaget mot det før noe skrives: kildebindingen og
   * hver katalogverdi. Det er den ene kontrollen den ordrette kan ikke gjøre —
   * et utdrag kan stå ordrett i kilden og likevel være ført på feil virkestoff.
   *
   * Grunnen til at den hører hjemme *her* og ikke bare i modell-leddet, er
   * overleveringen: forslaget har vært innom en økt som leste utrygt eksternt
   * innhold, og en kontroll som bare kjørte før den overleveringen, kontrollerer
   * ikke det som faktisk blir registrert (EVIDENCE_PIPELINE.md §63).
   *
   * Oppdraget er redaktørens egen fil og kommer en annen vei enn forslaget.
   */
  readonly assignment?: ExtractionAssignment
  /**
   * Arbeidsformen kalleren registrerer under, når kalleren har en.
   *
   * Oppgitt, må forslagets egen `generated_by.producer` stemme med den. Feltet
   * avgjør `extraction_method`, og forslaget er utrygg inndata: uten dette
   * kunne et maskinutkast blitt ført som et menneskes arbeid ved å endre ett
   * ord i filen (`extraction-proposal.ts`).
   */
  readonly mode?: RegistrationMode
  /** Kontroller og rapporter, men registrer ingenting. */
  readonly dryRun?: boolean
  readonly retrieve?: RetrieveLike
  readonly retrieveOptions?: RetrieveOptions
  readonly log?: (line: string) => void
}

export interface ExtractionRunReport {
  readonly agentRunId: Uuid
  readonly runStatus: 'succeeded' | 'aborted' | 'failed'
  /**
   * `already_registered` er ikke en feil. `evidence_items_content_hash_key`
   * dekker hele radens faglige innhold, kildeforankringen medregnet (migrasjon
   * 003d), så nøyaktig det samme forslaget kjørt om igjen skriver ingenting — og
   * det er nettopp det som gjør kjøringen idempotent. En korreksjon av et
   * hvilket som helst felt, eller av et utdrag, en kildepeker eller en
   * begrunnelse, gir en ny hash og registreres ved siden av den gamle;
   * ingenting overskrives.
   */
  readonly decision: 'registered' | 'already_registered' | 'previewed' | 'skipped'
  readonly evidenceItemId?: Uuid
  /**
   * Raden dublettavvisningen navngir, når den gjorde det (migrasjon 007h).
   *
   * Bare satt ved `already_registered`, og bare når databasen kunne slå opp den
   * kolliderende raden. Den er identifisert med nøyaktig den identiteten
   * UNIQUE-regelen bruker, så en kaller som vil fullføre en avbrutt kjøring, vet
   * hvilken rad det gjelder framfor å gjette.
   */
  readonly existingEvidenceItemId?: Uuid
  /** Feltene forslaget forankrer, i forslagets egen rekkefølge. */
  readonly groundedFields: readonly string[]
  /** Hvorfor ingenting ble registrert. Alltid satt for `skipped`. */
  readonly reason?: string
}

type Verdict =
  | { readonly kind: 'skip'; readonly reason: string }
  /** `requestDigestChecked` sier om forespørselsavtrykket lot seg rekonstruere. */
  | { readonly kind: 'ok'; readonly requestDigestChecked: boolean }

/**
 * Representasjonen må være den registrerte, og hvert utdrag må stå i den.
 *
 * Rekkefølgen er ikke tilfeldig: uten riktig fingeravtrykk er det ingen vits i
 * å søke, fordi et treff da ville vært i en annen utgave enn den ekstraksjonen
 * skal peke på.
 */
function judge(
  proposal: ExtractionProposal,
  sourceText: string,
  assignment: ExtractionAssignment | undefined,
): string | null {
  if (assignment !== undefined) {
    const mismatch = assignmentMismatch(assignment, proposal)
    if (mismatch !== null) {
      return (
        `Forslaget holder seg ikke innenfor oppdraget: ${mismatch}. Ekstraksjonen ble ikke ` +
        'registrert.'
      )
    }
  }
  const projections = searchProjections(sourceText)
  const missing = proposal.fieldGroundings.filter(
    (grounding) => !verbatimOccursIn(projections, grounding.sourceExcerpt),
  )
  if (missing.length > 0) {
    const fields = missing.map((grounding) => grounding.checkField).join(', ')
    return (
      `Kildeforankringen for ${fields} oppgir utdrag som ikke står ordrett i ` +
      `representasjonen fra ${proposal.retrievedFrom}. Ekstraksjonen ble ikke registrert.`
    )
  }
  return null
}

/**
 * Forespørselsavtrykket, rekonstruert der det lar seg rekonstruere.
 *
 * `request_digest` er den ene verdien i `generated_by` som ikke bare er en
 * påstand: forespørselen er en ren funksjon av oppdraget, representasjonen og
 * promptmalen, og registreringen har alle tre — oppdraget fra redaktøren,
 * representasjonen hentet på nytt, malen fra sin egen kode. Der er avtrykket
 * *etterprøvbart*, og da skal det prøves framfor kopieres.
 *
 * Det lar seg ikke alltid gjøre, og det er en reell tilstand og ikke et hull:
 *
 *   * uten oppdrag finnes ikke halve inndataen,
 *   * et menneskeskrevet forslag har ingen forespørsel,
 *   * et utkast laget under en *eldre* promptmal ville gitt et annet avtrykk,
 *     og det er malen som er endret — ikke utkastet som er galt,
 *   * en representasjon som selv inneholder gjerdemarkøren, kan ikke bygges
 *     til en forespørsel i det hele tatt.
 *
 * I de tilfellene forblir avtrykket en erklæring, og kjøringen fører at det var
 * det. Å oppgi noe annet ville vært å kalle en påstand et bevis.
 */
async function requestDigestVerdict(
  proposal: ExtractionProposal,
  assignment: ExtractionAssignment | undefined,
  sourceText: string,
): Promise<Verdict> {
  const declared = proposal.generatedBy.requestDigest
  if (
    assignment === undefined ||
    declared === null ||
    proposal.generatedBy.promptTemplateVersion !== EXTRACTION_DRAFTING_PROMPT_VERSION
  ) {
    return { kind: 'ok', requestDigestChecked: false }
  }

  let expected: string
  try {
    expected = await modelRequestDigest(
      buildExtractionDraftingRequest({ assignment, representation: sourceText }),
    )
  } catch {
    return { kind: 'ok', requestDigestChecked: false }
  }

  if (expected !== declared) {
    return {
      kind: 'skip',
      reason:
        `Forslaget oppgir forespørselsavtrykket ${declared}, men oppdraget og representasjonen ` +
        `gir ${expected} under promptmalen ${EXTRACTION_DRAFTING_PROMPT_VERSION}. Utkastet kan ` +
        'ikke ha vært lest ut av denne forespørselen. Ekstraksjonen ble ikke registrert.',
    }
  }
  return { kind: 'ok', requestDigestChecked: true }
}

async function fetchAndJudge(
  proposal: ExtractionProposal,
  retrieve: RetrieveLike,
  assignment: ExtractionAssignment | undefined,
): Promise<Verdict> {
  const retrieved = await retrieve(proposal.retrievedFrom)
  if (retrieved.status === 'error') {
    return { kind: 'skip', reason: retrieved.message }
  }

  const representation = retrieved.representation
  if (!representation.bytesAreUtf8) {
    return {
      kind: 'skip',
      reason:
        `Svaret fra ${proposal.retrievedFrom} er ikke ren UTF-8, så fingeravtrykket kan ikke ` +
        'sammenlignes byte for byte med den registrerte kildeversjonen.',
    }
  }

  if (representation.contentHash !== proposal.contentHash) {
    return {
      kind: 'skip',
      reason:
        `Kilden har endret seg: ${proposal.retrievedFrom} gir nå ` +
        `${representation.contentHash}, mens kildeversjonen er registrert med ` +
        `${proposal.contentHash}. Ekstraksjonen ville pekt på en annen utgave enn den ` +
        'som faktisk ble lest.',
    }
  }

  const problem = judge(proposal, representation.content, assignment)
  if (problem !== null) {
    return { kind: 'skip', reason: problem }
  }
  return await requestDigestVerdict(proposal, assignment, representation.content)
}

/**
 * Kjører ekstraksjonen for ett forslag.
 *
 * Kjøringen lukkes alltid: `succeeded` når raden ble skrevet, `aborted` for en
 * tørrkjøring og for et forslag som ikke holdt mål, og `failed` når noe uventet
 * skjedde. En kjøring som ble stående åpen, ville blokkert den neste og
 * etterlatt en proveniensrad uten utfall (migrasjon 005e).
 */
export async function runEvidenceExtraction(
  options: ExtractionRunOptions,
): Promise<ExtractionRunReport> {
  const {
    api,
    proposal,
    dryRun = false,
    retrieve = (url) => retrieveRepresentation(url, options.retrieveOptions),
    log = () => {},
  } = options

  // Modusen kontrolleres før noe åpnes: en kjøring skal ikke registreres for å
  // bli avvist på noe kalleren kunne fått vite uten å røre databasen. Kastet er
  // med vilje — dette er en feil i kallet, ikke et normalt utfall som «kilden
  // har endret seg».
  if (options.mode !== undefined) {
    const problem = registrationModeProblem(options.mode, proposal.generatedBy.producer)
    if (problem !== null) {
      throw new Error(`Registreringen ble ikke åpnet: ${problem}.`)
    }
  }

  const groundedFields = proposal.fieldGroundings.map((grounding) => grounding.checkField)
  // Utledet av modusen når kalleren oppga en, ellers av forslagets egen
  // erklæring. De to er kontrollert like over, så verdien er den samme — men
  // den kommer fra den tiltrodde halvdelen når det finnes en.
  const extractionMethod =
    options.mode === undefined
      ? extractionMethodFor(proposal.generatedBy.producer)
      : extractionMethodFor(producerForMode(options.mode))
  // Kildeversjonen oppgis strukturert, ikke bare i manifestet: den binder
  // evidensfunnet til nøyaktig den utgaven kjøringen leste, deklarativt
  // (evidence_items_agent_run_source_version_fkey, migrasjon 005z). Manifestet
  // er fortsatt dokumentasjonen av hva kjøringen fikk.
  const agentRunId = await api.beginRun(
    EVIDENCE_EXTRACTION_PREMISES,
    {
      source_id: proposal.sourceId,
      source_version_id: proposal.sourceVersionId,
      retrieved_from: proposal.retrievedFrom,
      content_hash: proposal.contentHash,
      grounded_fields: groundedFields,
      // Erklæringen om hvem som laget utkastet, ordrett slik forslaget bar den.
      //
      // Den står i manifestet og ikke i premissekolonnene, fordi den beskriver
      // en *annen* operasjon enn denne kjøringen: utkastet ble laget utenfor
      // Antidep, på sitt eget tidspunkt, av en aktør uten legitimasjon her.
      // Premissene beskriver kjøringen selv, og manifestet er kolonnen for hva
      // kjøringen fikk inn (ANTIDEP_CONSTITUTION.md §14, §20,
      // EVIDENCE_PIPELINE.md §65). `drafted_at` og `request_digest` er det som
      // gjør modelloperasjonen identifiserbar i ettertid.
      generated_by: {
        producer: proposal.generatedBy.producer,
        provider: proposal.generatedBy.provider,
        model: proposal.generatedBy.model,
        model_version: proposal.generatedBy.modelVersion,
        prompt_template_version: proposal.generatedBy.promptTemplateVersion,
        drafted_at: proposal.generatedBy.draftedAt,
        request_digest: proposal.generatedBy.requestDigest,
      },
      extraction_method: extractionMethod,
      // Om forslaget ble kontrollert mot oppdraget det skal ha vært laget
      // under. `false` er en reell tilstand og ikke et hull: et forslag skrevet
      // av en redaktør ut av en fulltekst har ikke noe oppdrag. Men valget skal
      // kunne leses i ettertid, av den som bedømmer raden.
      assignment_checked: options.assignment !== undefined,
      // Hva kalleren registrerte under, eller `null` når kalleren ikke oppga
      // en arbeidsform. Den tiltrodde halvdelen av «hvem laget dette».
      registration_mode: options.mode ?? null,
      dry_run: dryRun,
    },
    proposal.sourceVersionId,
  )
  log(`Kjøring ${agentRunId} åpnet for kildeversjon ${proposal.sourceVersionId}.`)

  try {
    const verdict = await fetchAndJudge(proposal, retrieve, options.assignment)

    if (verdict.kind === 'skip') {
      log(`Ingenting registrert: ${verdict.reason}`)
      // `aborted` krever en begrunnelse: agent_runs_status_shape_check godtar
      // ikke en avsluttet kjøring uten et svar på hvorfor den ble stoppet.
      await api.completeRun(
        agentRunId,
        'aborted',
        { skipped_reason: verdict.reason },
        verdict.reason.slice(0, 4000),
      )
      return {
        agentRunId,
        runStatus: 'aborted',
        decision: 'skipped',
        groundedFields,
        reason: verdict.reason,
      }
    }

    if (dryRun) {
      log(`Tørrkjøring: ${String(groundedFields.length)} utdrag ble gjenfunnet ordrett.`)
      await api.completeRun(
        agentRunId,
        'aborted',
        {
          dry_run: true,
          grounded_fields: groundedFields,
          request_digest_checked: verdict.requestDigestChecked,
        },
        'Tørrkjøring: forslaget ble kontrollert, men ingen ekstraksjon ble registrert.',
      )
      return { agentRunId, runStatus: 'aborted', decision: 'previewed', groundedFields }
    }

    let evidenceItemId: Uuid
    try {
      evidenceItemId = await api.registerExtraction({
        agentRunId,
        sourceId: proposal.sourceId,
        sourceVersionId: proposal.sourceVersionId,
        extraction: proposal.extraction,
        fieldGroundings: proposal.fieldGroundings,
        extractionMethod,
      })
    } catch (cause) {
      if (!isUniqueViolation(cause)) {
        throw cause
      }
      // Den ene forventede avvisningen: raden finnes allerede, med nøyaktig
      // det samme innholdet og den samme forankringen. Kjøringen lukkes som
      // `aborted` fordi den ikke produserte noe, ikke fordi noe gikk galt — og
      // det gamle funnet står urørt, som det skal (knowledge.evidence_items er
      // append-only).
      const reason = cause instanceof Error ? cause.message : String(cause)
      const existingEvidenceItemId = collidingEvidenceItemId(cause)
      log(
        'Ingenting registrert: den samme ekstraksjonen er allerede registrert' +
          (existingEvidenceItemId === null ? '.' : ` som ${existingEvidenceItemId}.`),
      )
      await api.completeRun(
        agentRunId,
        'aborted',
        { already_registered: true, existing_evidence_item_id: existingEvidenceItemId },
        reason.slice(0, 4000),
      )
      return {
        agentRunId,
        runStatus: 'aborted',
        decision: 'already_registered',
        groundedFields,
        reason,
        ...(existingEvidenceItemId === null ? {} : { existingEvidenceItemId }),
      }
    }
    log(
      `Evidensfunn ${evidenceItemId} registrert, forankret på ${String(groundedFields.length)} felter.`,
    )
    await api.completeRun(
      agentRunId,
      'succeeded',
      {
        evidence_item_id: evidenceItemId,
        grounded_fields: groundedFields,
        // Om forespørselsavtrykket lot seg rekonstruere, eller forble en
        // erklæring. Den som leser proveniensen senere, skal kunne se hvilken
        // av de to det var.
        request_digest_checked: verdict.requestDigestChecked,
      },
      null,
    )
    return {
      agentRunId,
      runStatus: 'succeeded',
      decision: 'registered',
      evidenceItemId,
      groundedFields,
    }
  } catch (cause) {
    const reason = cause instanceof Error ? cause.message : String(cause)
    // Kjøringen lukkes selv om lukkingen også feiler: en åpen kjøring ville
    // blokkert den neste, og den opprinnelige feilen er den som skal nå
    // kalleren.
    try {
      await api.completeRun(agentRunId, 'failed', null, reason)
    } catch {
      log('Kjøringen kunne ikke lukkes etter feilen.')
    }
    throw cause
  }
}
