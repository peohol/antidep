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
import { asObjectList, fieldsOf, raw, rejectUnknown } from './strict-fields.ts'
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
  parseProposedClaimRevision(fields, raw(fields, 'claim'), claimBinding)
  const links = asObjectList(fields, 'evidence_links').map((link, index) =>
    parseProposedEvidenceLink(fields, link, index),
  )
  rejectUnknown(fields)

  if (links.length === 0) {
    return 'Utkastet lenker ikke til noe evidensfunn. En påstand uten grunnlag er ikke en syntese.'
  }
  const allowed = new Set(evidenceIdsIn(binding))
  const seen = new Set<string>()
  for (const link of links) {
    if (!allowed.has(link.evidenceItemId)) {
      return 'Utkastet lenker til et evidensfunn som ikke står i oppgaven.'
    }
    if (seen.has(link.evidenceItemId)) {
      return 'Utkastet fører det samme evidensfunnet mer enn én gang.'
    }
    seen.add(link.evidenceItemId)
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
    if (task.role === 'evidence_extraction') {
      return extractionProblem(task, result)
    }
    if (task.role === 'claim_synthesis') {
      return synthesisProblem(task, result)
    }
    return assessmentProblem(result)
  } catch (cause) {
    return cause instanceof Error ? cause.message : String(cause)
  }
}
