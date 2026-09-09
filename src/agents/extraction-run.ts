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
// Det krever en språkmodell, og dermed en leverandør og en konto (issue #63).
// Forslaget kommer derfor utenfra, som data (`extraction-proposal.ts`).
//
// Den er alt det andre, og det er den delen som må være deterministisk:
// kjøringens proveniens, at representasjonen er nøyaktig den registrerte
// kildeversjonen, at hvert utdrag faktisk står i den, og selve registreringen.
// Et modell-ledd som skriver forslagsformen, kobles på uten at noe av dette
// endres — og går gjennom nøyaktig de samme kontrollene.
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
import type { AgentRunPremises, EvidenceExtractionApi } from './agent-api.ts'
import { isUniqueViolation } from './agent-api.ts'
import { searchProjections, verbatimOccursIn } from './extraction-checks.ts'
import type { ExtractionProposal } from './extraction-proposal.ts'
import type { RetrievalResult, RetrieveOptions } from './source-retrieval.ts'
import { retrieveRepresentation } from './source-retrieval.ts'

export type RetrieveLike = (url: string) => Promise<RetrievalResult>

export interface ExtractionRunOptions {
  readonly api: EvidenceExtractionApi
  readonly premises: AgentRunPremises
  readonly proposal: ExtractionProposal
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
   * dekker hele radens faglige innhold, så nøyaktig det samme forslaget kjørt
   * om igjen skriver ingenting — og det er nettopp det som gjør kjøringen
   * idempotent. En korreksjon av et hvilket som helst felt gir en ny hash og
   * registreres ved siden av den gamle; ingenting overskrives.
   */
  readonly decision: 'registered' | 'already_registered' | 'previewed' | 'skipped'
  readonly evidenceItemId?: Uuid
  /** Feltene forslaget forankrer, i forslagets egen rekkefølge. */
  readonly groundedFields: readonly string[]
  /** Hvorfor ingenting ble registrert. Alltid satt for `skipped`. */
  readonly reason?: string
}

type Verdict = { readonly kind: 'skip'; readonly reason: string } | { readonly kind: 'ok' }

/**
 * Representasjonen må være den registrerte, og hvert utdrag må stå i den.
 *
 * Rekkefølgen er ikke tilfeldig: uten riktig fingeravtrykk er det ingen vits i
 * å søke, fordi et treff da ville vært i en annen utgave enn den ekstraksjonen
 * skal peke på.
 */
function judge(proposal: ExtractionProposal, sourceText: string): Verdict {
  const projections = searchProjections(sourceText)
  const missing = proposal.fieldGroundings.filter(
    (grounding) => !verbatimOccursIn(projections, grounding.sourceExcerpt),
  )
  if (missing.length > 0) {
    const fields = missing.map((grounding) => grounding.checkField).join(', ')
    return {
      kind: 'skip',
      reason:
        `Kildeforankringen for ${fields} oppgir utdrag som ikke står ordrett i ` +
        `representasjonen fra ${proposal.retrievedFrom}. Ekstraksjonen ble ikke registrert.`,
    }
  }
  return { kind: 'ok' }
}

async function fetchAndJudge(
  proposal: ExtractionProposal,
  retrieve: RetrieveLike,
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

  return judge(proposal, representation.content)
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
    premises,
    proposal,
    dryRun = false,
    retrieve = (url) => retrieveRepresentation(url, options.retrieveOptions),
    log = () => {},
  } = options

  const groundedFields = proposal.fieldGroundings.map((grounding) => grounding.checkField)
  // Kildeversjonen oppgis strukturert, ikke bare i manifestet: den binder
  // evidensfunnet til nøyaktig den utgaven kjøringen leste, deklarativt
  // (evidence_items_agent_run_source_version_fkey, migrasjon 005z). Manifestet
  // er fortsatt dokumentasjonen av hva kjøringen fikk.
  const agentRunId = await api.beginRun(
    premises,
    {
      source_id: proposal.sourceId,
      source_version_id: proposal.sourceVersionId,
      retrieved_from: proposal.retrievedFrom,
      content_hash: proposal.contentHash,
      grounded_fields: groundedFields,
      dry_run: dryRun,
    },
    proposal.sourceVersionId,
  )
  log(`Kjøring ${agentRunId} åpnet for kildeversjon ${proposal.sourceVersionId}.`)

  try {
    const verdict = await fetchAndJudge(proposal, retrieve)

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
        { dry_run: true, grounded_fields: groundedFields },
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
      })
    } catch (cause) {
      if (!isUniqueViolation(cause)) {
        throw cause
      }
      // Den ene forventede avvisningen: raden finnes allerede, med nøyaktig
      // det samme innholdet. Kjøringen lukkes som `aborted` fordi den ikke
      // produserte noe, ikke fordi noe gikk galt — og det gamle funnet står
      // urørt, som det skal (knowledge.evidence_items er append-only).
      const reason = cause instanceof Error ? cause.message : String(cause)
      log('Ingenting registrert: evidensfunnet finnes allerede med nøyaktig dette innholdet.')
      await api.completeRun(
        agentRunId,
        'aborted',
        { already_registered: true },
        reason.slice(0, 4000),
      )
      return {
        agentRunId,
        runStatus: 'aborted',
        decision: 'already_registered',
        groundedFields,
        reason,
      }
    }
    log(
      `Evidensfunn ${evidenceItemId} registrert, forankret på ${String(groundedFields.length)} felter.`,
    )
    await api.completeRun(
      agentRunId,
      'succeeded',
      { evidence_item_id: evidenceItemId, grounded_fields: groundedFields },
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
