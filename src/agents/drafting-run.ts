// ============================================================================
// Modell-leddet: fra en registrert kildeversjon til et ekstraksjonsforslag
//
//   resolveRepresentation    kilden skaffes: hentet fra adressen, eller hentet
//                            ut av originaldokumentet med den registrerte oppskriften
//   (fingeravtrykk)          representasjonen må være den registrerte
//   buildDraftingRequest     den versjonerte promptmalen, med teksten inngjerdet
//   model.complete           modellen leser og foreslår
//   parseExtractionDraft     svaret må ha kontraktens form
//   (katalogkontroll)        bare id-ene oppdraget åpnet for
//   (ordrett kontroll)       hvert utdrag må stå i representasjonen
//   → ExtractionProposal     en fil, ikke en rad
//
// ----------------------------------------------------------------------------
// Hva dette leddet ikke har
//
// Ingen databasetilgang. Ingen agentlegitimasjon. Ingen skrivevei. Det leser en
// kilde og skriver en fil, og filen må gjennom hele den deterministiske kjeden
// etterpå — registrering under en agentkjøring, ordrett kontroll av hvert utdrag
// på nytt, en separat maskinell ekstraksjonskontroll av en annen identitet, og
// en menneskelig faglig bekreftelse — før noe kan publiseres
// (ANTIDEP_CONSTITUTION.md §10, §11, §12, EVIDENCE_PIPELINE.md §63).
//
// Det er ikke en begrensning som kan lempes på senere. Leddet leser utrygt
// eksternt innhold, og et ledd som gjør det, skal ikke samtidig kunne skrive en
// rad.
//
// ----------------------------------------------------------------------------
// Hvorfor generatoren kontrollerer sitt eget svar
//
// Kontrollene her er ikke *den* kontrollen. Den er en separat operasjon, av en
// annen identitet, senere i kjeden, og uten den kan ingen menneskelig
// bekreftelse registreres (migrasjon 005x). Kontrollen her er generatorens egen
// aktsomhet, og forskjellen er hva som skjer ved et avvik: uten den ville et
// oppdiktet utdrag blitt en fil, så en rad, så noe en kontrollør måtte avvise.
// Med den blir det ingen fil.
//
// Tre ting kontrolleres, og alle tre er ting modellen kan ta feil av på en måte
// som ikke synes senere:
//
//   1. **Katalogen.** En uuid som ikke står i oppdraget, flytter funnet til et
//      annet virkestoff eller et naboendepunkt. Utdragene ville fortsatt stått
//      ordrett i kilden, og den deterministiske kontrollen kontrollerer utdrag,
//      ikke avgrensning.
//   2. **Utdragene.** Hvert `source_excerpt` må stå ordrett i representasjonen,
//      og det må stå der som hele ord: et utsnitt som begynner inne i
//      «fluoxetine», er ordrett til stede og likevel ubrukelig som
//      kontrollgrunnlag (`source-excerpt.ts`).
//   3. **Sitatet.** `source_quote` blir `raw_extraction` på raden, og
//      ekstraksjonskontrollen prøver det ordrett senere. Et sitat modellen
//      skrev om, ville blitt en rad som var dømt til å avvises.
//
// ----------------------------------------------------------------------------
// Hvorfor kildeversjonen hentes her og ikke tas for gitt
//
// Modellen skal lese nøyaktig den utgaven ekstraksjonen kommer til å peke på.
// Hentes teksten et annet sted fra — en PDF på disk, et utklipp — kan utdragene
// være ordrett riktige i *den* teksten og fraværende i representasjonen
// databasen kjenner. Kjøringen henter derfor adressen selv og krever at
// fingeravtrykket er kildeversjonens eget, før den bygger en eneste forespørsel.
// ============================================================================

import { searchProjections, verbatimOccursIn } from './extraction-checks.ts'
import { excerptSourceProblem } from './source-excerpt.ts'
import {
  assignmentBinding,
  catalogProblem,
  type ExtractionAssignment,
} from './extraction-assignment.ts'
import {
  parseExtractionDraft,
  type ExtractionProposal,
  EXTRACTION_PROPOSAL_VERSION,
} from './extraction-proposal.ts'
import { buildExtractionDraftingRequest } from './extraction-prompt.ts'
import { parseCompletionJson } from './model-answer.ts'
import { modelRequestDigest, type ModelClient, type ModelRequest } from './model-client.ts'
import { resolveRepresentation, type ResolvePorts } from './source-binding.ts'

const DRAFT_SUBJECT = 'Modellsvaret'

export interface DraftingRunOptions extends ResolvePorts {
  readonly assignment: ExtractionAssignment
  readonly model: ModelClient
  /**
   * Klokka, injisert.
   *
   * Tidspunktet er en del av proveniensen — det sier når utkastet faktisk ble
   * laget, i motsetning til når det senere ble registrert — og da må det kunne
   * festes i en prøve. Standardverdien er den ekte klokka.
   */
  readonly now?: () => string
  readonly log?: (line: string) => void
}

export interface DraftingReport {
  /** `drafted` når et gyldig forslag kom ut, `rejected` når ingenting gjorde det. */
  readonly decision: 'drafted' | 'rejected'
  /** Fingeravtrykket av forespørselen, når en ble bygget. */
  readonly requestDigest: string | null
  readonly promptTemplateVersion: string
  readonly proposal?: ExtractionProposal
  /** Modellens svar, ordrett. Bare satt når en modell faktisk svarte. */
  readonly completion?: string
  /** Hvorfor ingenting ble foreslått. Alltid satt for `rejected`. */
  readonly reason?: string
}

/** Det kalleren trenger for å skrive ut prompten uten å be modellen om noe. */
export interface PreparedRequest {
  readonly request: ModelRequest
  readonly requestDigest: string
}

function rejected(
  promptTemplateVersion: string,
  requestDigest: string | null,
  reason: string,
): DraftingReport {
  return { decision: 'rejected', requestDigest, promptTemplateVersion, reason }
}

/**
 * Skaffer representasjonen og krever at den er kildeversjonens egen.
 *
 * Rekkefølgen er ikke tilfeldig: uten riktig fingeravtrykk er det ingen vits i
 * å spørre en modell, fordi svaret da ville vært lest ut av en annen utgave enn
 * den ekstraksjonen skal peke på.
 *
 * Hvordan teksten skaffes — hentet fra adressen, eller hentet ut av
 * originaldokumentet med den registrerte oppskriften — avgjøres av oppdraget og
 * ikke av dette leddet (`source-binding.ts`).
 */
async function readRepresentation(
  assignment: ExtractionAssignment,
  ports: ResolvePorts,
): Promise<{ readonly text: string } | { readonly error: string }> {
  const resolved = await resolveRepresentation(assignmentBinding(assignment), ports)
  if (resolved.status === 'error') {
    return { error: resolved.message }
  }
  return { text: resolved.text }
}

/**
 * Bygger forespørselen for et oppdrag, uten å spørre noen modell.
 *
 * Brukes av `--prepare`, som skriver prompten og et tomt opptak med riktig
 * avtrykk. Det er den veien et utkast lages i dag: prompten kjøres utenfor
 * Antidep, og svaret limes inn i opptaket.
 */
export async function prepareDraftingRequest(
  options: ResolvePorts & { readonly assignment: ExtractionAssignment },
): Promise<PreparedRequest> {
  const read = await readRepresentation(options.assignment, options)
  if ('error' in read) {
    throw new Error(read.error)
  }
  const request = buildExtractionDraftingRequest({
    assignment: options.assignment,
    representation: read.text,
  })
  return { request, requestDigest: await modelRequestDigest(request) }
}

/** Den ordrette kontrollen av modellens eget svar mot teksten den fikk. */
function verbatimProblem(
  draft: {
    readonly extraction: ExtractionProposal['extraction']
    readonly fieldGroundings: ExtractionProposal['fieldGroundings']
  },
  representation: string,
): string | null {
  const projections = searchProjections(representation)
  for (const grounding of draft.fieldGroundings) {
    const issue = excerptSourceProblem(projections, grounding.sourceExcerpt)
    if (issue !== null) {
      return `kildeforankringen for ${grounding.checkField} oppgir et utdrag som ${issue}`
    }
  }
  const quote = draft.extraction.sourceQuote
  if (quote !== null && !verbatimOccursIn(projections, quote)) {
    return 'source_quote står ikke ordrett i representasjonen'
  }
  return null
}

/**
 * Kjører modell-leddet for ett oppdrag.
 *
 * Returnerer et forslag eller en begrunnelse, aldri et halvferdig forslag. Et
 * utkast som ikke holdt mål, er ikke noe å rette videre på i neste ledd: det er
 * en modellkjøring som ikke ga et brukbart svar, og den skal si det.
 */
export async function runExtractionDrafting(options: DraftingRunOptions): Promise<DraftingReport> {
  const { assignment, model, now = () => new Date().toISOString(), log = () => {} } = options

  const read = await readRepresentation(assignment, options)
  if ('error' in read) {
    return rejected('', null, read.error)
  }

  let request: ModelRequest
  try {
    request = buildExtractionDraftingRequest({ assignment, representation: read.text })
  } catch (cause) {
    return rejected('', null, cause instanceof Error ? cause.message : String(cause))
  }

  const requestDigest = await modelRequestDigest(request)
  const version = request.promptTemplateVersion
  log(
    `Forespørsel ${requestDigest} bygget av promptmal ${version} for kildeversjon ` +
      `${assignment.sourceVersionId}.`,
  )

  const completion = await model.complete(request)
  // Tidspunktet leses her og ikke ved slutten: det er da modellen svarte, og
  // det er den operasjonen erklæringen beskriver.
  const draftedAt = now()

  let draft
  try {
    draft = parseExtractionDraft(parseCompletionJson(completion.text), DRAFT_SUBJECT)
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    return {
      ...rejected(version, requestDigest, message),
      completion: completion.text,
    }
  }

  const catalogIssue = catalogProblem(assignment, draft.extraction)
  if (catalogIssue !== null) {
    return {
      ...rejected(
        version,
        requestDigest,
        `Modellen foreslo en katalogverdi utenfor oppdraget: ${catalogIssue}. Ingenting ble foreslått.`,
      ),
      completion: completion.text,
    }
  }

  const verbatimIssue = verbatimProblem(draft, read.text)
  if (verbatimIssue !== null) {
    return {
      ...rejected(
        version,
        requestDigest,
        `Modellsvaret holdt ikke mål: ${verbatimIssue}. Ingenting ble foreslått.`,
      ),
      completion: completion.text,
    }
  }

  const proposal: ExtractionProposal = {
    proposalVersion: EXTRACTION_PROPOSAL_VERSION,
    generatedBy: {
      producer: 'model',
      provider: model.identity.provider,
      model: model.identity.model,
      modelVersion: model.identity.modelVersion,
      promptTemplateVersion: version,
      draftedAt,
      requestDigest,
    },
    sourceId: assignment.sourceId,
    sourceVersionId: assignment.sourceVersionId,
    retrievedFrom: assignment.retrievedFrom,
    contentHash: assignment.contentHash,
    document: assignment.document,
    extraction: draft.extraction,
    fieldGroundings: draft.fieldGroundings,
  }

  log(
    `Utkast fra ${model.identity.provider}/${model.identity.model} ${model.identity.modelVersion}: ` +
      `${String(draft.fieldGroundings.length)} forankrede felter, alle gjenfunnet ordrett.`,
  )

  return {
    decision: 'drafted',
    requestDigest,
    promptTemplateVersion: version,
    proposal,
    completion: completion.text,
  }
}
