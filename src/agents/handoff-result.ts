// ============================================================================
// De deterministiske kontrollene av et eksternt agentsvar, før det sendes
//
// `agent-answer.ts` kontrollerer at svaret hører til oppgaven. Denne modulen
// kontrollerer innholdet: at utkastet har kontraktens form, at det holder seg
// innenfor den avgrensningen oppgaven ga, og — for ekstraksjonsleddet — at hvert
// kildeutdrag faktisk står ordrett i den kildeteksten oppgaven inneholdt.
//
// ----------------------------------------------------------------------------
// Hvorfor kontrollene kjøres her og ikke bare i databasen
//
// Fordi det er den samme koden kjederunnerne allerede bruker
// (`drafting-run.ts`), og fordi en andre implementasjon av den ordrette
// kontrollen ville vært en andre kilde til sannhet. Normaliseringen — hva som
// er et ord, hva en blokkgrense er, hvordan entiteter og etiketter håndteres —
// bor ett sted (`extraction-checks.ts`), og to kontroller som kunne svare
// forskjellig på den samme artikkelen, er verre enn én.
//
// Kontrollen her er heller ikke *den* kontrollen. Den uavhengige
// ekstraksjonskontrollen er en egen rolle, med en egen identitet og en egen
// kjøring, senere i kjeden, og uten den kan ingen menneskelig bekreftelse
// registreres. Kontrollen her er generatorens egen aktsomhet: uten den ville et
// oppdiktet utdrag blitt en rad, og så noe en kontrollør måtte avvise. Med den
// blir det ingen rad.
//
// ----------------------------------------------------------------------------
// Hva databasen gjør uansett
//
// Databasen kontrollerer avgrensningen om igjen ved import, av oppgaven slik den
// er *da* (migrasjon 010c). Den henter dessuten alle registrerte verdier ut av
// svaret selv, så en flate kan ikke bytte dem ut underveis. Det som ligger her,
// er derfor et første, forklarende ledd — ikke grensen databasen hviler på.
// ============================================================================

import { searchProjections, verbatimOccursIn } from './extraction-checks.ts'
import { excerptSourceProblem } from './source-excerpt.ts'
import { parseExtractionDraft } from './extraction-proposal.ts'
import {
  parseProposedClaimRevision,
  parseProposedEvidenceLink,
  type ClaimBinding,
} from './claim-synthesis-proposal.ts'
import { parseProposedAssessment } from './evidence-assessment-proposal.ts'
import { CANDIDATE_DECISIONS, SEARCH_OUTCOMES } from './handoff-schemas.ts'
import {
  asObjectList,
  asOptionalInteger,
  asOptionalText,
  asOptionalVocabulary,
  asText,
  asUuid,
  asVocabulary,
  fieldsOf,
  nestedFields,
  problem,
  raw,
  rejectUnknown,
  type Fields,
} from './strict-fields.ts'
import type { AgentTask } from './agent-task.ts'
import type { Uuid } from '../types/api.ts'

const RESULT_SUBJECT = 'Agentsvaret'

function textList(input: Record<string, unknown>, key: string): readonly string[] {
  const value = input[key]
  return Array.isArray(value)
    ? value.filter((entry): entry is string => typeof entry === 'string')
    : []
}

function textOf(input: Record<string, unknown>, key: string): string {
  const value = input[key]
  return typeof value === 'string' ? value : ''
}

function evidenceIdsIn(input: Record<string, unknown>): readonly string[] {
  const value = input['evidence']
  if (!Array.isArray(value)) {
    return []
  }
  return value.flatMap((entry) => {
    if (typeof entry !== 'object' || entry === null) {
      return []
    }
    const id = (entry as Record<string, unknown>)['evidence_item_id']
    return typeof id === 'string' ? [id] : []
  })
}

/**
 * Kontrollerer ekstraksjonsutkastet mot oppgaven det ble laget under.
 *
 * Tre ting, og alle tre er ting en modell kan ta feil av på en måte som ikke
 * synes senere: formen, avgrensningen og de ordrette utdragene.
 */
function extractionProblem(task: AgentTask, result: Record<string, unknown>): string | null {
  const draft = parseExtractionDraft(result, RESULT_SUBJECT)

  const binding = (task.binding['input'] ?? {}) as Record<string, unknown>
  const drugs = textList(binding, 'drug_ids')
  const outcomes = textList(binding, 'outcome_concept_ids')
  const populations = textList(binding, 'population_ids')
  const e = draft.extraction

  if (!drugs.includes(e.interventionDrugId)) {
    return 'Utkastet oppgir et virkestoff som ikke står blant virkestoffene i oppgaven.'
  }
  if (e.comparatorDrugId !== null && !drugs.includes(e.comparatorDrugId)) {
    return 'Utkastet oppgir et komparatorvirkestoff som ikke står blant virkestoffene i oppgaven.'
  }
  if (!outcomes.includes(e.outcomeConceptId)) {
    return 'Utkastet oppgir et endepunkt som ikke står blant endepunktene i oppgaven.'
  }
  if (e.populationId !== null && !populations.includes(e.populationId)) {
    return 'Utkastet oppgir en populasjon som ikke står blant populasjonene i oppgaven.'
  }

  const representation = textOf(task.input, 'representation_text')
  if (representation.length === 0) {
    return 'Oppgaven inneholdt ingen kildetekst, så utdragene kan ikke kontrolleres.'
  }
  const projections = searchProjections(representation)
  for (const grounding of draft.fieldGroundings) {
    const issue = excerptSourceProblem(projections, grounding.sourceExcerpt)
    if (issue !== null) {
      return `Kildeforankringen for ${grounding.checkField} oppgir et utdrag som ${issue}.`
    }
  }
  const quote = e.sourceQuote
  if (quote !== null && !verbatimOccursIn(projections, quote)) {
    return 'source_quote står ikke ordrett i kildeteksten oppgaven inneholdt.'
  }
  return null
}

/** Kontrollerer synteseutkastet mot evidenssettet oppgaven avgrenset. */
function synthesisProblem(task: AgentTask, result: Record<string, unknown>): string | null {
  const binding = (task.binding['input'] ?? {}) as Record<string, unknown>
  const claimBinding: ClaimBinding = {
    claimId: (binding['claim_id'] as Uuid | null) ?? null,
    topicConceptId: String(binding['topic_concept_id'] ?? '') as Uuid,
    subjectDrugId: String(binding['subject_drug_id'] ?? '') as Uuid,
  }

  const fields = fieldsOf(result, RESULT_SUBJECT, 'utkastet')
  const claim = parseProposedClaimRevision(fields, raw(fields, 'claim'), claimBinding)
  const links = asObjectList(fields, 'evidence_links').map((link, index) =>
    parseProposedEvidenceLink(fields, link, index),
  )
  rejectUnknown(fields)

  // Populasjonen er en faglig avgrensning redaktøren har gjort, på linje med
  // katalogen i et ekstraksjonsoppdrag. En id kopiert ut av dossieret ville
  // passert fremmednøkkelen og flyttet påstanden til en annen populasjon enn
  // den oppgaven gjelder.
  const populations = textList(binding, 'population_ids')
  if (claim.populationId !== null && !populations.includes(claim.populationId)) {
    return 'Utkastet oppgir en populasjon som ikke står blant populasjonene i oppgaven.'
  }

  // Hele evidenssettet, og ikke en delmengde av det. Et utkast som utelot et
  // funn som MOTSIER påstanden, ville gitt en syntese som hvilte på et annet
  // grunnlag enn det redaktøren avgrenset — og uenigheten ville vært borte uten
  // at noe i kjeden sa fra (ANTIDEP_CONSTITUTION.md regel 4).
  const assigned = evidenceIdsIn(binding)
  const seen = new Set<string>()
  for (const link of links) {
    if (!assigned.includes(link.evidenceItemId)) {
      return 'Utkastet lenker til et evidensfunn som ikke står i oppgaven.'
    }
    if (seen.has(link.evidenceItemId)) {
      return 'Utkastet fører det samme evidensfunnet mer enn én gang.'
    }
    seen.add(link.evidenceItemId)
  }
  const missing = assigned.filter((id) => !seen.has(id))
  if (missing.length > 0) {
    return (
      `Utkastet mangler ${String(missing.length)} av evidensfunnene oppgaven avgrenset. ` +
      'Hvert funn skal ha en relasjon til påstanden — også et funn som motsier den, som da ' +
      'føres som contradicts.'
    )
  }
  return null
}

/** Kontrollerer vurderingsutkastet. */
function assessmentProblem(result: Record<string, unknown>): string | null {
  const fields = fieldsOf(result, RESULT_SUBJECT, 'utkastet')
  parseProposedAssessment(fields, raw(fields, 'assessment'))
  rejectUnknown(fields)
  return null
}

function optionalBoolean(fields: Fields, key: string): boolean | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'boolean') {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke sann/usann')
  }
  return value
}

function requiredBoolean(fields: Fields, key: string): boolean {
  const value = optionalBoolean(fields, key)
  if (value === null) {
    problem(fields.subject, `${fields.where}.${key}`, 'mangler')
  }
  return value
}

function optionalArray(fields: Fields, key: string): readonly unknown[] {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return []
  }
  if (!Array.isArray(value)) {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke en liste')
  }
  return value
}

function requiredArray(fields: Fields, key: string): readonly unknown[] {
  const value = raw(fields, key)
  if (!Array.isArray(value)) {
    problem(fields.subject, `${fields.where}.${key}`, 'mangler eller er ikke en liste')
  }
  return value
}

function nonNegativeInteger(fields: Fields, key: string): number | null {
  const value = asOptionalInteger(fields, key)
  if (value !== null && value < 0) {
    problem(fields.subject, `${fields.where}.${key}`, 'er negativt')
  }
  return value
}

function stringArray(fields: Fields, key: string): readonly string[] {
  const values = optionalArray(fields, key)
  return values.map((value, index) => {
    if (typeof value !== 'string') {
      problem(fields.subject, `${fields.where}.${key}[${String(index)}]`, 'er ikke tekst')
    }
    return value
  })
}

function discoverySearches(fields: Fields): void {
  const searches = requiredArray(fields, 'searches')
  searches.forEach((value, index) => {
    const search = nestedFields(fields, value, `searches[${String(index)}]`)
    asText(search, 'platform')
    asText(search, 'query_string')
    asOptionalText(search, 'filters')
    asVocabulary(search, 'outcome', SEARCH_OUTCOMES)
    nonNegativeInteger(search, 'result_count')
    nonNegativeInteger(search, 'screened_count')
    optionalBoolean(search, 'truncated')
    asOptionalText(search, 'truncation_note')
    asOptionalText(search, 'limitation_note')
    stringArray(search, 'track_codes')
    rejectUnknown(search)
  })
}

function discoveryCandidates(fields: Fields): void {
  const candidates = optionalArray(fields, 'candidates')
  candidates.forEach((value, index) => {
    const candidate = nestedFields(fields, value, `candidates[${String(index)}]`)
    asVocabulary(candidate, 'identifier_kind', [
      'doi',
      'pmid',
      'pmcid',
      'url',
      'title',
      'registry_id',
    ])
    asText(candidate, 'identifier_value')
    asText(candidate, 'title')
    asOptionalText(candidate, 'authors_or_issuer')
    asOptionalText(candidate, 'publisher_or_journal')
    const year = nonNegativeInteger(candidate, 'publication_year')
    if (year !== null && (year < 1800 || year > 2200)) {
      problem(candidate.subject, `${candidate.where}.publication_year`, 'ligger utenfor 1800–2200')
    }
    asText(candidate, 'discovery_path')
    optionalBoolean(candidate, 'access_limited')
    asOptionalText(candidate, 'access_limitation_note')
    optionalBoolean(candidate, 'could_change_conclusion')
    asOptionalText(candidate, 'materiality_reason')
    asOptionalVocabulary(candidate, 'decision', CANDIDATE_DECISIONS)
    asOptionalText(candidate, 'decision_reason')

    const uses = optionalArray(candidate, 'uses')
    uses.forEach((useValue, useIndex) => {
      const use = nestedFields(candidate, useValue, `${candidate.where}.uses[${String(useIndex)}]`)
      asText(use, 'need_reference')
      asText(use, 'proposed_use')
      rejectUnknown(use)
    })
    rejectUnknown(candidate)
  })
}

function sourceDiscoveryProblem(
  role: 'source_discovery' | 'source_quality_assessment',
  result: Record<string, unknown>,
): string | null {
  const fields = fieldsOf(result, RESULT_SUBJECT, 'utkastet')
  discoverySearches(fields)
  discoveryCandidates(fields)

  if (role === 'source_discovery') {
    const proposals = optionalArray(fields, 'term_proposals')
    proposals.forEach((value, index) => {
      const proposal = nestedFields(fields, value, `term_proposals[${String(index)}]`)
      asText(proposal, 'axis')
      asText(proposal, 'label')
      asText(proposal, 'rationale')
      asOptionalText(proposal, 'from_need')
      rejectUnknown(proposal)
    })
  } else {
    const control = nestedFields(fields, raw(fields, 'control'), 'control')
    asVocabulary(control, 'outcome', ['accepted', 'insufficient'])
    asText(control, 'note')
    requiredBoolean(control, 'searched_independently')
    nonNegativeInteger(control, 'missed_candidates')
    nonNegativeInteger(control, 'exclusions_checked')
    requiredBoolean(control, 'materiality_assessed')
    rejectUnknown(control)
  }

  asOptionalText(fields, 'note')
  rejectUnknown(fields)
  return null
}

function optionalObject(fields: Fields, key: string): Record<string, unknown> | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'object' || Array.isArray(value)) {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke et objekt')
  }
  return value as Record<string, unknown>
}

function isCalendarDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return false
  }
  const date = new Date(`${value}T00:00:00.000Z`)
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value
}

function requiredDate(fields: Fields, key: string): string {
  const value = asText(fields, key)
  if (!isCalendarDate(value)) {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke en gyldig dato på formen ÅÅÅÅ-MM-DD')
  }
  return value
}

function optionalDate(fields: Fields, key: string): string | null {
  const value = asOptionalText(fields, key)
  if (value !== null && !isCalendarDate(value)) {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke en gyldig dato på formen ÅÅÅÅ-MM-DD')
  }
  return value
}

function monographAnswerProblem(result: Record<string, unknown>): string | null {
  const fields = fieldsOf(result, RESULT_SUBJECT, 'utkastet')
  const answer = nestedFields(fields, raw(fields, 'answer'), 'answer')

  asVocabulary(answer, 'knowledge_type', ['regulatory_fact', 'product_data', 'attributed_advice'])
  asText(answer, 'statement')
  optionalObject(answer, 'structured_value')
  asOptionalText(answer, 'uncertainty_summary')
  asOptionalText(answer, 'limitation_note')
  requiredDate(answer, 'as_of')
  asText(answer, 'source_quote')
  asText(answer, 'source_locator')
  asOptionalText(answer, 'recommending_body')
  optionalDate(answer, 'recommendation_date')

  const additionalSources = optionalArray(answer, 'additional_sources')
  additionalSources.forEach((value, index) => {
    const source = nestedFields(answer, value, `answer.additional_sources[${String(index)}]`)
    asUuid(source, 'source_version_id')
    asText(source, 'source_quote')
    asText(source, 'source_locator')
    requiredDate(source, 'as_of')
    rejectUnknown(source)
  })

  rejectUnknown(answer)
  rejectUnknown(fields)
  return null
}

/**
 * Om svaret holder mål, eller hvorfor det ikke gjør det.
 *
 * Returnerer én setning på norsk, eller `null`. Kaster aldri: en modell som
 * svarte noe annet enn kontrakten, er et normalt utfall for dette leddet, og
 * flaten skal kunne si hva som er galt framfor å gå i stykker.
 */
export function handoffResultProblem(
  task: AgentTask,
  result: Record<string, unknown>,
): string | null {
  try {
    switch (task.role) {
      case 'evidence_extraction':
        return extractionProblem(task, result)
      case 'claim_synthesis':
        return synthesisProblem(task, result)
      case 'evidence_assessment':
        return assessmentProblem(result)

      case 'source_discovery':
      case 'source_quality_assessment':
        return sourceDiscoveryProblem(task.role, result)
      case 'monograph_answer':
        return monographAnswerProblem(result)

      default: {
        const exhaustive: never = task.role
        return exhaustive
      }
    }
  } catch (cause) {
    return cause instanceof Error ? cause.message : String(cause)
  }
}
