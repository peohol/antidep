// ============================================================================
// Monografien, lest og sagt på norsk
//
// Flaten leser fire ting: hvilke monografier som er bestilt, hvor langt hver av
// dem er kommet, hele utkastet, og hva som venter på et menneske. Modulen eier
// hvordan svarene fra databasen leses og hvilke ord de får.
//
// ----------------------------------------------------------------------------
// Hvorfor de seks dimensjonene aldri slås sammen
//
// Relevans, arbeidstilstand, faglig utfall, evidenssikkerhet, aktualitet og
// kontrollstatus betyr forskjellige ting. «Ingen relevante studier» er en
// faglig konklusjon; «venter på tilgang» er en tilgangsbegrensning; «teknisk
// stopp» er en driftssak. En flate som viste dem som ett tall, ville sagt at
// Antidep har konkludert der det bare mangler en artikkel
// (ANTIDEP_CONSTITUTION.md regel 4, MONOGRAPH_STANDARD.md §2).
//
// ----------------------------------------------------------------------------
// Hvorfor ordet er «antidepressiver»
//
// Antidep skriver om antidepressiver. Egne tekster bruker det ordet; ordrette
// kildeutdrag og originaltitler endres aldri for å normalisere terminologien
// (MONOGRAPH_STANDARD.md §1).
// ============================================================================

import { asText, fieldsOf, nestedFields, raw, type Fields } from '../agents/strict-fields.ts'

const SUBJECT = 'Monografien'

// ----------------------------------------------------------------------------
// Tilstandene, med tegn og tekst — aldri farge alene
// ----------------------------------------------------------------------------

export type MonographTone = 'planned' | 'progress' | 'failed' | 'done' | 'blocked'

export interface StatePresentation {
  readonly symbol: string
  readonly label: string
  readonly tone: MonographTone
  /** Én setning om hva tilstanden betyr for den som leser. */
  readonly note: string
}

const WORK_STATES: Readonly<Record<string, StatePresentation>> = {
  not_started: {
    symbol: '◻',
    label: 'Ikke begynt',
    tone: 'planned',
    note: 'Antidep har ikke begynt å undersøke dette spørsmålet.',
  },
  searching: {
    symbol: '◐',
    label: 'Søker',
    tone: 'progress',
    note: 'Antidep leter etter kilder.',
  },
  appraising_sources: {
    symbol: '◐',
    label: 'Vurderer kilder',
    tone: 'progress',
    note: 'Kildene er funnet, og utvalget vurderes.',
  },
  awaiting_access: {
    symbol: '⌛',
    label: 'Venter på tilgang',
    tone: 'blocked',
    note: 'Antidep mangler originalmaterialet. Dette er en tilgangsbegrensning, ikke en konklusjon om kunnskapen.',
  },
  extracting: {
    symbol: '◐',
    label: 'Leser kildene',
    tone: 'progress',
    note: 'Materialet er i hus, og opplysningene hentes ut og kontrolleres.',
  },
  awaiting_clarification: {
    symbol: '?',
    label: 'Venter på en avklaring',
    tone: 'blocked',
    note: 'Noe må avklares av et menneske før arbeidet kan fortsette. Det er ikke en konklusjon om kunnskapen.',
  },
  technical_stop: {
    symbol: '✕',
    label: 'Teknisk stopp',
    tone: 'failed',
    note: 'Antidep kom ikke videre av tekniske grunner. Det er meldt fra, og det er ikke en konklusjon om kunnskapen.',
  },
  agent_complete: {
    symbol: '✓',
    label: 'Ferdig behandlet',
    tone: 'done',
    note: 'Arbeidet er gjort, og spørsmålet har fått et faglig utfall.',
  },
}

const OUTCOMES: Readonly<Record<string, StatePresentation>> = {
  answered: {
    symbol: '✓',
    label: 'Besvart',
    tone: 'done',
    note: 'Spørsmålet har et kildebelagt svar.',
  },
  no_qualifying_evidence: {
    symbol: '∅',
    label: 'Ingen kvalifiserende studier',
    tone: 'done',
    note: 'Søket ble gjennomført og dokumentert, og fant ingen studier som oppfyller kravene. Det er et resultat, ikke et hull i arbeidet.',
  },
  insufficient_evidence: {
    symbol: '≈',
    label: 'Utilstrekkelig evidens',
    tone: 'done',
    note: 'Det finnes studier, men de er ikke tilstrekkelige til å svare. Dette er en faglig konklusjon.',
  },
  conflicting_evidence: {
    symbol: '⇄',
    label: 'Motstridende evidens',
    tone: 'done',
    note: 'Kildene peker i forskjellige retninger, og motsetningen er dokumentert.',
  },
  not_applicable: {
    symbol: '–',
    label: 'Ikke relevant',
    tone: 'planned',
    note: 'Spørsmålet er vurdert som ikke relevant for dette virkestoffet, med en begrunnelse.',
  },
}

const RELEVANCE: Readonly<Record<string, StatePresentation>> = {
  relevant: { symbol: '•', label: 'Relevant', tone: 'progress', note: 'Spørsmålet skal besvares.' },
  not_applicable: {
    symbol: '–',
    label: 'Ikke relevant',
    tone: 'planned',
    note: 'Avgjort som ikke relevant, med en begrunnelse og en navngitt avgjørelse.',
  },
  undetermined: {
    symbol: '?',
    label: 'Uavklart relevans',
    tone: 'blocked',
    note: 'Ingen har ennå tatt stilling til om spørsmålet er relevant. Uavklart er ikke det samme som «ikke relevant».',
  },
}

const KNOWLEDGE_TYPES: Readonly<Record<string, string>> = {
  regulatory_fact: 'Regulatorisk opplysning',
  product_data: 'Preparatdata',
  research_finding: 'Forskningsfunn',
  attributed_advice: 'Attribuert råd',
  reasoning: 'Farmakologisk resonnement',
  derived: 'Avledet av andre svar',
}

const CERTAINTY: Readonly<Record<string, string>> = {
  high: 'Høy sikkerhet',
  moderate: 'Moderat sikkerhet',
  low: 'Lav sikkerhet',
  very_low: 'Svært lav sikkerhet',
}

const FALLBACK: StatePresentation = {
  symbol: '?',
  label: 'Ukjent tilstand',
  tone: 'blocked',
  note: 'Antidep kjenner ikke denne tilstanden. Den vises som ukjent framfor å bli gjettet på.',
}

export function workStatePresentation(state: string): StatePresentation {
  return WORK_STATES[state] ?? FALLBACK
}

export function outcomePresentation(outcome: string): StatePresentation {
  return OUTCOMES[outcome] ?? FALLBACK
}

export function relevancePresentation(relevance: string): StatePresentation {
  return RELEVANCE[relevance] ?? FALLBACK
}

export function knowledgeTypeLabel(type: string): string {
  return KNOWLEDGE_TYPES[type] ?? type
}

export function certaintyLabel(level: string | null): string | null {
  return level === null ? null : (CERTAINTY[level] ?? level)
}

// ----------------------------------------------------------------------------
// Dekningen
// ----------------------------------------------------------------------------

export interface MonographCounts {
  readonly total: number
  readonly relevant: number
  readonly justifiedNotApplicable: number
  readonly undeterminedRelevance: number
  readonly answered: number
  readonly reviewedGaps: number
  readonly open: number
}

export interface MonographBlocked {
  readonly awaitingAccess: number
  readonly awaitingClarification: number
  readonly technicalStop: number
}

export interface MonographCoverage {
  readonly reference: string
  readonly drug: string
  readonly standardVersion: string
  readonly editionNo: number
  readonly orderedAt: string
  readonly counts: MonographCounts
  readonly blocked: MonographBlocked
  readonly handled: number
  readonly denominator: number
  readonly percent: number | null
  readonly level: string
  readonly partial: boolean
}

function number(fields: Fields, key: string): number {
  const value = raw(fields, key)
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function nullableNumber(fields: Fields, key: string): number | null {
  const value = raw(fields, key)
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function boolean(fields: Fields, key: string): boolean {
  return raw(fields, key) === true
}

export function parseMonographCoverage(value: unknown): MonographCoverage {
  const fields = fieldsOf(value, SUBJECT, 'dekning')
  const edition = nestedFields(fields, raw(fields, 'edition'), 'dekning.edition')
  const needs = nestedFields(fields, raw(fields, 'needs'), 'dekning.needs')
  const blocked = nestedFields(fields, raw(fields, 'blocked'), 'dekning.blocked')
  const work = nestedFields(fields, raw(fields, 'work_coverage'), 'dekning.work_coverage')
  const completion = nestedFields(fields, raw(fields, 'completion'), 'dekning.completion')

  return {
    reference: asText(edition, 'reference'),
    drug: asText(edition, 'drug'),
    standardVersion: asText(edition, 'standard_version'),
    editionNo: number(edition, 'edition_no'),
    orderedAt: asText(edition, 'ordered_at'),
    counts: {
      total: number(needs, 'total'),
      relevant: number(needs, 'relevant'),
      justifiedNotApplicable: number(needs, 'justified_not_applicable'),
      undeterminedRelevance: number(needs, 'undetermined_relevance'),
      answered: number(needs, 'answered'),
      reviewedGaps: number(needs, 'reviewed_gaps'),
      open: number(needs, 'open'),
    },
    blocked: {
      awaitingAccess: number(blocked, 'awaiting_access'),
      awaitingClarification: number(blocked, 'awaiting_clarification'),
      technicalStop: number(blocked, 'technical_stop'),
    },
    handled: number(work, 'handled'),
    denominator: number(work, 'denominator'),
    percent: nullableNumber(work, 'percent'),
    level: asText(completion, 'level'),
    partial: boolean(completion, 'partial'),
  }
}

export function parseMonographOrders(value: unknown): readonly MonographCoverage[] {
  if (!Array.isArray(value)) {
    throw new Error(`${SUBJECT}: svaret er ikke en liste over bestillinger.`)
  }
  return value.map((entry) => parseMonographCoverage(entry))
}

/**
 * Nivået monografien er kommet til, i klinikerens språk.
 *
 * Standardens egen inndeling: et dekningskart er ikke en agentferdig monografi,
 * og en agentferdig monografi er ikke et publisert innhold
 * (MONOGRAPH_STANDARD.md §5.4).
 */
export function completionLabel(coverage: MonographCoverage): string {
  if (coverage.level === 'no_coverage_map') return 'Ingen kunnskapsbehov opprettet ennå'
  if (coverage.level === 'agent_complete') return 'Alle spørsmål er behandlet av Antidep'
  return 'Dekningskart under arbeid'
}

/** De blokkeringene som aldri skal leses som en faglig konklusjon. */
export function blockedSummary(coverage: MonographCoverage): readonly string[] {
  const lines: string[] = []
  if (coverage.blocked.awaitingAccess > 0) {
    lines.push(
      `${coverage.blocked.awaitingAccess} spørsmål venter på at Antidep får tilgang til ` +
        'originalmaterialet.',
    )
  }
  if (coverage.blocked.awaitingClarification > 0) {
    lines.push(
      `${coverage.blocked.awaitingClarification} spørsmål venter på en avklaring fra et menneske.`,
    )
  }
  if (coverage.blocked.technicalStop > 0) {
    lines.push(`${coverage.blocked.technicalStop} spørsmål står på en teknisk feil.`)
  }
  return lines
}

// ----------------------------------------------------------------------------
// Utkastet
// ----------------------------------------------------------------------------

export interface MonographSource {
  readonly title: string
  readonly authorsOrIssuer: string | null
  readonly publisherOrJournal: string | null
  readonly locator: string | null
  readonly asOf: string | null
  readonly retrievedFrom: string | null
}

export interface MonographAnswer {
  readonly revisionReference: string
  readonly revisionNumber: number
  readonly knowledgeType: string
  readonly origin: string
  readonly statement: string
  readonly uncertaintySummary: string | null
  readonly limitationNote: string | null
  readonly asOf: string | null
  readonly recommendingBody: string | null
  readonly certainty: string | null
  readonly sources: readonly MonographSource[]
  readonly controlledFields: readonly string[]
}

export interface MonographEntry {
  readonly needReference: string
  readonly templateCode: string
  readonly question: string
  readonly requirement: string
  readonly scope: string | null
  readonly relevance: string
  readonly relevanceReason: string | null
  readonly workState: string
  readonly workStateNote: string | null
  readonly outcome: string | null
  readonly answer: MonographAnswer | null
}

export interface MonographSection {
  readonly section: string
  readonly entries: readonly MonographEntry[]
}

export interface MonographDraft {
  readonly reference: string
  readonly drug: string
  readonly standardVersion: string
  readonly sections: readonly MonographSection[]
  readonly coverage: MonographCoverage
  readonly latestCandidate: {
    readonly reference: string
    readonly candidateNo: number
    readonly staleReason: string | null
    readonly finalControl: {
      readonly decision: string
      readonly reviewer: string | null
      readonly rationale: string
    } | null
  } | null
  readonly publishedCandidate: string | null
}

function optionalText(fields: Fields, key: string): string | null {
  const value = raw(fields, key)
  return typeof value === 'string' && value.trim().length > 0 ? value : null
}

function parseSource(value: unknown): MonographSource {
  const fields = fieldsOf(value, SUBJECT, 'kilde')
  return {
    title: asText(fields, 'title'),
    authorsOrIssuer: optionalText(fields, 'authors_or_issuer'),
    publisherOrJournal: optionalText(fields, 'publisher_or_journal'),
    locator: optionalText(fields, 'locator'),
    asOf: optionalText(fields, 'as_of'),
    retrievedFrom: optionalText(fields, 'retrieved_from'),
  }
}

function parseAnswer(value: unknown): MonographAnswer {
  const fields = fieldsOf(value, SUBJECT, 'svar')
  const sources = raw(fields, 'sources')
  const evidence = raw(fields, 'evidence_sources')
  const controlled = raw(fields, 'controlled_fields')
  return {
    revisionReference: asText(fields, 'revision_reference'),
    revisionNumber: number(fields, 'revision_number'),
    knowledgeType: asText(fields, 'knowledge_type'),
    origin: asText(fields, 'origin'),
    statement: asText(fields, 'statement'),
    uncertaintySummary: optionalText(fields, 'uncertainty_summary'),
    limitationNote: optionalText(fields, 'limitation_note'),
    asOf: optionalText(fields, 'as_of'),
    recommendingBody: optionalText(fields, 'recommending_body'),
    certainty: optionalText(fields, 'certainty'),
    sources: [
      ...(Array.isArray(sources) ? sources.map((entry) => parseSource(entry)) : []),
      ...(Array.isArray(evidence) ? evidence.map((entry) => parseSource(entry)) : []),
    ],
    controlledFields: Array.isArray(controlled)
      ? controlled.filter((field): field is string => typeof field === 'string')
      : [],
  }
}

function parseEntry(value: unknown): MonographEntry {
  const fields = fieldsOf(value, SUBJECT, 'spørsmål')
  const answer = raw(fields, 'answer')
  return {
    needReference: asText(fields, 'need_reference'),
    templateCode: asText(fields, 'template_code'),
    question: asText(fields, 'question'),
    requirement: asText(fields, 'requirement'),
    scope: optionalText(fields, 'scope'),
    relevance: asText(fields, 'relevance'),
    relevanceReason: optionalText(fields, 'relevance_reason'),
    workState: asText(fields, 'work_state'),
    workStateNote: optionalText(fields, 'work_state_note'),
    outcome: optionalText(fields, 'outcome'),
    answer: answer === null || answer === undefined ? null : parseAnswer(answer),
  }
}

export function parseMonographDraft(value: unknown): MonographDraft {
  const fields = fieldsOf(value, SUBJECT, 'utkast')
  const edition = nestedFields(fields, raw(fields, 'edition'), 'utkast.edition')
  const sections = raw(fields, 'sections')
  const candidate = raw(fields, 'latest_candidate')
  const published = raw(fields, 'published')

  const parsedCandidate =
    candidate === null || candidate === undefined
      ? null
      : (() => {
          const candidateFields = fieldsOf(candidate, SUBJECT, 'utkast.latest_candidate')
          const control = raw(candidateFields, 'final_control')
          return {
            reference: asText(candidateFields, 'reference'),
            candidateNo: number(candidateFields, 'candidate_no'),
            staleReason: optionalText(candidateFields, 'stale_reason'),
            finalControl:
              control === null || control === undefined
                ? null
                : (() => {
                    const controlFields = fieldsOf(
                      control,
                      SUBJECT,
                      'utkast.latest_candidate.final_control',
                    )
                    return {
                      decision: asText(controlFields, 'decision'),
                      reviewer: optionalText(controlFields, 'reviewer'),
                      rationale: asText(controlFields, 'rationale'),
                    }
                  })(),
          }
        })()

  return {
    reference: asText(edition, 'reference'),
    drug: asText(edition, 'drug'),
    standardVersion: asText(edition, 'standard_version'),
    sections: Array.isArray(sections)
      ? sections.map((entry) => {
          const sectionFields = fieldsOf(entry, SUBJECT, 'utkast.sections[]')
          const entries = raw(sectionFields, 'entries')
          return {
            section: asText(sectionFields, 'section'),
            entries: Array.isArray(entries) ? entries.map((row) => parseEntry(row)) : [],
          }
        })
      : [],
    coverage: parseMonographCoverage(raw(fields, 'coverage')),
    latestCandidate: parsedCandidate,
    publishedCandidate:
      published === null || published === undefined
        ? null
        : asText(fieldsOf(published, SUBJECT, 'utkast.published'), 'candidate_reference'),
  }
}

// ----------------------------------------------------------------------------
// Det som venter på et menneske
// ----------------------------------------------------------------------------

export interface MonographRequest {
  readonly reference: string
  readonly kind: 'research_full_text' | 'authority_document'
  readonly title: string
  readonly authorsOrIssuer: string | null
  readonly publisherOrJournal: string | null
  readonly professionalReason: string | null
  readonly accessLimitation: string | null
}

export function parseMonographRequests(value: unknown): readonly MonographRequest[] {
  const fields = fieldsOf(value, SUBJECT, 'bestillinger')
  const read = (key: string): readonly MonographRequest[] => {
    const rows = raw(fields, key)
    if (!Array.isArray(rows)) return []
    return rows.map((entry) => {
      const row = nestedFields(fields, entry, `bestillinger.${key}[]`)
      const kind = asText(row, 'kind')
      return {
        reference: asText(row, 'reference'),
        kind: kind === 'authority_document' ? 'authority_document' : 'research_full_text',
        title: asText(row, 'title'),
        authorsOrIssuer: optionalText(row, 'authors_or_issuer'),
        publisherOrJournal: optionalText(row, 'publisher_or_journal'),
        professionalReason: optionalText(row, 'professional_reason'),
        accessLimitation: optionalText(row, 'access_limitation'),
      }
    })
  }
  return [...read('research_full_text'), ...read('authority_documents')]
}

export interface MonographProposal {
  readonly reference: string
  readonly kind: string
  readonly templateCode: string
  readonly question: string
  readonly scope: string | null
  readonly rationale: string
  readonly sourceTitle: string | null
}

export function parseMonographProposals(value: unknown): readonly MonographProposal[] {
  const fields = fieldsOf(value, SUBJECT, 'avvik')
  const rows = raw(fields, 'proposals')
  if (!Array.isArray(rows)) return []
  return rows.map((entry) => {
    const row = nestedFields(fields, entry, 'avvik.proposals[]')
    return {
      reference: asText(row, 'reference'),
      kind: asText(row, 'kind'),
      templateCode: asText(row, 'template_code'),
      question: asText(row, 'question'),
      scope: optionalText(row, 'scope'),
      rationale: asText(row, 'rationale'),
      sourceTitle: optionalText(row, 'source_title'),
    }
  })
}

/** Hva et avvik er, i klinikerens språk. */
export function proposalLabel(kind: string): string {
  if (kind === 'locked_answer_challenged') {
    return 'Nytt kontrollert grunnlag for et låst svar'
  }
  if (kind === 'restricted_source_offered') {
    return 'Relevant kilde utenfor de forhåndsgodkjente'
  }
  return kind
}
