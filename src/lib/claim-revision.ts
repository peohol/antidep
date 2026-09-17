// ============================================================================
// Ny evidens på en påstand som allerede finnes, lest og sagt på norsk
//
// Dette er den tredje redaksjonelle handlingen i kjeden, og den er like faglig
// som de to andre: å avgjøre hva en påstand skal si i lys av ny forskning.
// Antidep oppdager at kunnskapen finnes, og bygger revisjonen når avgjørelsen
// er tatt — men avgjørelsen selv er et menneskes (docs/ROADMAP.md).
//
// Modulen eier tre ting: hvordan svaret fra databasen leses, hva en redaktør
// faktisk får se, og setningene rundt det. Ingen uuid, ingen jobbnøkkel, ingen
// agentrolle og ingen modell finnes i noen av dem.
//
// ----------------------------------------------------------------------------
// Hvorfor evidensgrunnlaget sendes uendret tilbake
//
// Beslutningen er bundet til nøyaktig det grunnlaget redaktøren tok stilling
// til. Avtrykket flaten fikk, følger derfor med beslutningen, og databasen
// avviser den dersom grunnlaget er blitt et annet i mellomtiden
// (ANTIDEP_CONSTITUTION.md regel 5). Samme grep som sluttkontrollen bruker mot
// kandidatens avtrykk — og flaten regner like lite ut selv her: en verdi
// klienten kunne beregne, ville vært en påstand om seg selv.
//
// Verdien vises aldri. Den er ikke noe et menneske skal lese, og den er ikke
// noe et menneske skal skrive.
// ============================================================================

import { asText, fieldsOf, raw, type Fields } from '../agents/strict-fields.ts'

const SUBJECT = 'Revisjonsoppgaven'

/** Én ny forskningsartikkel, slik den faglige avgjørelsen trenger den. */
export interface NewEvidenceSummary {
  readonly articleTitle: string
  readonly articleAuthors: string
  readonly publishedYear: number | null
  readonly studyDesign: string
  readonly population: string | null
  readonly populationDetail: string | null
  readonly participants: number | null
  readonly finding: string
  readonly direction: string
  readonly effectMeasure: string | null
  readonly estimate: number | null
  readonly estimateUnit: string | null
  readonly ciLower: number | null
  readonly ciUpper: number | null
  readonly ciLevelPercent: number | null
  readonly limitations: string | null
}

/** Én oppgave i redaktørkøen, eller den samme oppgaven åpnet i sin helhet. */
export interface ClaimRevisionTask {
  /** Det ugjennomsiktige håndtaket flaten peker med. Aldri en intern id. */
  readonly reference: string
  readonly subjectDrug: string
  readonly topic: string
  readonly statement: string
  readonly scope: string
  readonly uncertaintySummary: string | null
  readonly revisionNumber: number
  readonly published: boolean
  readonly certaintyLevel: string | null
  readonly existingEvidenceCount: number
  readonly newEvidenceCount: number
  readonly noticedAt: string
  /** Avtrykket som sendes uendret tilbake med beslutningen. Vises aldri. */
  readonly evidenceBasis: string
  /** Den nye forskningen. Tom i køen, fylt når oppgaven åpnes. */
  readonly newEvidence: readonly NewEvidenceSummary[]
}

/** De to utfallene en redaktør kan velge mellom, og ingen flere. */
export type ClaimRevisionDecision = 'revise' | 'set_aside'

export interface ClaimRevisionOutcome {
  readonly reference: string
  readonly decision: string
  /** Om dette kallet faktisk endret noe, eller gjentok en avgjørelse som sto. */
  readonly recorded: boolean
}

function asNumberOrNull(fields: Fields, key: string): number | null {
  const value = raw(fields, key)
  if (value === null || value === undefined) {
    return null
  }
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`${SUBJECT} er ugyldig: ${fields.where}.${key} er ikke et tall.`)
  }
  return value
}

function asNumber(fields: Fields, key: string): number {
  const value = asNumberOrNull(fields, key)
  if (value === null) {
    throw new Error(`${SUBJECT} er ugyldig: ${fields.where}.${key} mangler.`)
  }
  return value
}

function asTextOrNull(fields: Fields, key: string): string | null {
  const value = raw(fields, key)
  if (value === null || value === undefined) {
    return null
  }
  if (typeof value !== 'string') {
    throw new Error(`${SUBJECT} er ugyldig: ${fields.where}.${key} er ikke en tekst.`)
  }
  return value.length === 0 ? null : value
}

function asFlag(fields: Fields, key: string): boolean {
  const value = raw(fields, key)
  if (typeof value !== 'boolean') {
    throw new Error(`${SUBJECT} er ugyldig: ${fields.where}.${key} er ikke en boolsk verdi.`)
  }
  return value
}

function parseNewEvidence(value: unknown, where: string): NewEvidenceSummary {
  const fields = fieldsOf(value, SUBJECT, where)
  return {
    articleTitle: asText(fields, 'article_title'),
    articleAuthors: asText(fields, 'article_authors'),
    publishedYear: asNumberOrNull(fields, 'published_year'),
    studyDesign: asText(fields, 'study_design'),
    population: asTextOrNull(fields, 'population'),
    populationDetail: asTextOrNull(fields, 'population_detail'),
    participants: asNumberOrNull(fields, 'participants'),
    finding: asText(fields, 'finding'),
    direction: asText(fields, 'direction'),
    effectMeasure: asTextOrNull(fields, 'effect_measure'),
    estimate: asNumberOrNull(fields, 'estimate'),
    estimateUnit: asTextOrNull(fields, 'estimate_unit'),
    ciLower: asNumberOrNull(fields, 'ci_lower'),
    ciUpper: asNumberOrNull(fields, 'ci_upper'),
    ciLevelPercent: asNumberOrNull(fields, 'ci_level_percent'),
    limitations: asTextOrNull(fields, 'limitations'),
  }
}

function parseTask(value: unknown, where: string): ClaimRevisionTask {
  const fields = fieldsOf(value, SUBJECT, where)
  const evidence = raw(fields, 'new_evidence')
  if (evidence !== undefined && evidence !== null && !Array.isArray(evidence)) {
    throw new Error(`${SUBJECT} er ugyldig: ${where}.new_evidence er ikke en liste.`)
  }
  return {
    reference: asText(fields, 'reference'),
    subjectDrug: asText(fields, 'subject_drug'),
    topic: asText(fields, 'topic'),
    statement: asText(fields, 'statement'),
    scope: asText(fields, 'scope'),
    uncertaintySummary: asTextOrNull(fields, 'uncertainty_summary'),
    revisionNumber: asNumber(fields, 'revision_number'),
    published: asFlag(fields, 'published'),
    certaintyLevel: asTextOrNull(fields, 'certainty_level'),
    existingEvidenceCount: asNumber(fields, 'existing_evidence_count'),
    newEvidenceCount: asNumber(fields, 'new_evidence_count'),
    noticedAt: asText(fields, 'noticed_at'),
    evidenceBasis: asText(fields, 'evidence_basis'),
    newEvidence: Array.isArray(evidence)
      ? evidence.map((entry, index) => parseNewEvidence(entry, `${where}.new_evidence[${index}]`))
      : [],
  }
}

export function parseClaimRevisionQueue(value: unknown): readonly ClaimRevisionTask[] {
  if (!Array.isArray(value)) {
    throw new Error(`${SUBJECT} er ugyldig: svaret er ikke en liste.`)
  }
  return value.map((entry, index) => parseTask(entry, `rad ${String(index)}`))
}

export function parseClaimRevisionTask(value: unknown): ClaimRevisionTask {
  return parseTask(value, 'oppgaven')
}

export function parseClaimRevisionOutcome(value: unknown): ClaimRevisionOutcome {
  const fields = fieldsOf(value, SUBJECT, 'svaret')
  return {
    reference: asText(fields, 'reference'),
    decision: asText(fields, 'decision'),
    recorded: asFlag(fields, 'recorded'),
  }
}

/**
 * Hvorfor en avgjørelse ikke kan sendes ennå, eller `null`.
 *
 * Bare én regel, og den er faglig: en konklusjon om at den nye forskningen ikke
 * endrer påstanden, må si hvorfor. Uten begrunnelsen ville den vært en
 * utsettelse forkledd som en konklusjon.
 */
export function decisionProblem(decision: ClaimRevisionDecision, note: string): string | null {
  if (decision === 'set_aside' && note.trim().length === 0) {
    return 'Skriv kort hvorfor den nye forskningen ikke endrer påstanden.'
  }
  return null
}

/** Hvor mye ny forskning som venter, i én lesbar setning. */
export function newEvidenceSentence(task: ClaimRevisionTask): string {
  if (task.newEvidenceCount === 1) {
    return 'Én ny forskningsartikkel er kommet til siden påstanden sist ble formulert.'
  }
  return (
    `${String(task.newEvidenceCount)} nye forskningsartikler er kommet til siden ` +
    'påstanden sist ble formulert.'
  )
}

/** Hva som skjedde, i én setning til den som avgjorde. */
export function decisionOutcomeSentence(outcome: ClaimRevisionOutcome): string {
  if (outcome.decision === 'set_aside') {
    return outcome.recorded
      ? 'Takk — konklusjonen er registrert. Påstanden står som den står, og oppgaven kommer ' +
          'tilbake dersom det senere kommer enda mer ny forskning.'
      : 'Den samme konklusjonen var allerede registrert. Ingenting er dublert.'
  }
  return outcome.recorded
    ? 'Takk — Antidep skriver nå påstanden på nytt med hele det oppdaterte ' +
        'evidensgrunnlaget, kontrollerer den mot kildene og vurderer hvor sikker evidensen ' +
        'er. Du får den til sluttkontroll når den er ferdig.'
    : 'Revisjonen var allerede besluttet, og Antidep arbeider med den. Ingenting er dublert.'
}
