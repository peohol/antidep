// ============================================================================
// Modell-leddet: fra en registrert kildeversjon til et ekstraksjonsforslag
//
//   retrieveRepresentation   kilden hentes, over nett
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
//   2. **Utdragene.** Hvert `source_excerpt` må stå ordrett i representasjonen.
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
import type { ExtractionAssignment } from './extraction-assignment.ts'
import {
  parseExtractionDraft,
  type ExtractionProposal,
  EXTRACTION_PROPOSAL_VERSION,
} from './extraction-proposal.ts'
import { buildExtractionDraftingRequest } from './extraction-prompt.ts'
import { modelRequestDigest, type ModelClient, type ModelRequest } from './model-client.ts'
import type { RetrieveLike } from './extraction-run.ts'
import { retrieveRepresentation, type RetrieveOptions } from './source-retrieval.ts'

const DRAFT_SUBJECT = 'Modellsvaret'

export interface DraftingRunOptions {
  readonly assignment: ExtractionAssignment
  readonly model: ModelClient
  readonly retrieve?: RetrieveLike
  readonly retrieveOptions?: RetrieveOptions
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
 * Henter representasjonen og krever at den er kildeversjonens egen.
 *
 * Rekkefølgen er ikke tilfeldig: uten riktig fingeravtrykk er det ingen vits i
 * å spørre en modell, fordi svaret da ville vært lest ut av en annen utgave enn
 * den ekstraksjonen skal peke på.
 */
async function readRepresentation(
  assignment: ExtractionAssignment,
  retrieve: RetrieveLike,
): Promise<{ readonly text: string } | { readonly error: string }> {
  const retrieved = await retrieve(assignment.retrievedFrom)
  if (retrieved.status === 'error') {
    return { error: retrieved.message }
  }
  const representation = retrieved.representation
  if (!representation.bytesAreUtf8) {
    return {
      error:
        `Svaret fra ${assignment.retrievedFrom} er ikke ren UTF-8, så fingeravtrykket kan ikke ` +
        'sammenlignes byte for byte med den registrerte kildeversjonen.',
    }
  }
  if (representation.contentHash !== assignment.contentHash) {
    return {
      error:
        `Kilden har endret seg: ${assignment.retrievedFrom} gir nå ` +
        `${representation.contentHash}, mens kildeversjonen er registrert med ` +
        `${assignment.contentHash}. Et utkast lest ut av den ville pekt på en annen utgave ` +
        'enn den som faktisk ble registrert.',
    }
  }
  return { text: representation.content }
}

/**
 * Bygger forespørselen for et oppdrag, uten å spørre noen modell.
 *
 * Brukes av `--prepare`, som skriver prompten og et tomt opptak med riktig
 * avtrykk. Det er den veien et utkast lages i dag: prompten kjøres utenfor
 * Antidep, og svaret limes inn i opptaket.
 */
export async function prepareDraftingRequest(options: {
  readonly assignment: ExtractionAssignment
  readonly retrieve?: RetrieveLike
  readonly retrieveOptions?: RetrieveOptions
}): Promise<PreparedRequest> {
  const retrieve =
    options.retrieve ?? ((url: string) => retrieveRepresentation(url, options.retrieveOptions))
  const read = await readRepresentation(options.assignment, retrieve)
  if ('error' in read) {
    throw new Error(read.error)
  }
  const request = buildExtractionDraftingRequest({
    assignment: options.assignment,
    representation: read.text,
  })
  return { request, requestDigest: await modelRequestDigest(request) }
}

/**
 * Modellsvaret som JSON, med ett innpakningsmønster tålt.
 *
 * Malen ber uttrykkelig om JSON uten kodegjerder, og et svar med gjerder er
 * derfor et svar som ikke fulgte malen. Ett enkelt gjerde rundt hele svaret
 * pakkes likevel ut, fordi det er den ene avviksformen som er entydig og som
 * ikke endrer et eneste tegn i innholdet. Alt annet — forklaring foran, to
 * objekter, tekst etter — avvises, fordi det ikke finnes én riktig måte å tolke
 * det på.
 */
function parseCompletionJson(text: string): unknown {
  const trimmed = text.trim()
  const fenced = /^```(?:json)?\s*\n([\s\S]*)\n```$/.exec(trimmed)
  return JSON.parse(fenced?.[1] ?? trimmed) as unknown
}

/** Katalogkontrollen: bare id-ene oppdraget faktisk åpnet for. */
function catalogProblem(
  assignment: ExtractionAssignment,
  extraction: ExtractionProposal['extraction'],
): string | null {
  const known = (choices: readonly { readonly id: string }[], id: string): boolean =>
    choices.some((choice) => choice.id === id)

  if (!known(assignment.drugs, extraction.interventionDrugId)) {
    return `intervention_drug_id ${extraction.interventionDrugId} står ikke blant virkestoffene i oppdraget`
  }
  if (
    extraction.comparatorDrugId !== null &&
    !known(assignment.drugs, extraction.comparatorDrugId)
  ) {
    return `comparator_drug_id ${extraction.comparatorDrugId} står ikke blant virkestoffene i oppdraget`
  }
  if (!known(assignment.outcomes, extraction.outcomeConceptId)) {
    return `outcome_concept_id ${extraction.outcomeConceptId} står ikke blant endepunktene i oppdraget`
  }
  if (extraction.populationId !== null && !known(assignment.populations, extraction.populationId)) {
    return `population_id ${extraction.populationId} står ikke blant populasjonene i oppdraget`
  }
  return null
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
  const missing = draft.fieldGroundings
    .filter((grounding) => !verbatimOccursIn(projections, grounding.sourceExcerpt))
    .map((grounding) => grounding.checkField)
  if (missing.length > 0) {
    return `kildeforankringen for ${missing.join(', ')} oppgir utdrag som ikke står ordrett i representasjonen`
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
  const { assignment, model, log = () => {} } = options
  const retrieve =
    options.retrieve ?? ((url: string) => retrieveRepresentation(url, options.retrieveOptions))

  const read = await readRepresentation(assignment, retrieve)
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
    },
    sourceId: assignment.sourceId,
    sourceVersionId: assignment.sourceVersionId,
    retrievedFrom: assignment.retrievedFrom,
    contentHash: assignment.contentHash,
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
