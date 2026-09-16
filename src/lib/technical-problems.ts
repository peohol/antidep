// ============================================================================
// De tekniske problemene, sagt slik en ikke-teknisk admin kan lese dem
//
// Databasen svarer med et område, to tidspunkter, en teller og om problemet
// fortsatt pågår. Den svarer aldri med diagnosen: den blir liggende privat,
// til Claude Code og ChatGPT (migrasjon 012a).
//
// Modulen her eier oversettelsen av områdevokabularet til setninger som sier
// hva slags konsekvens problemet har — ikke hva som teknisk er galt. «Antidep
// får ikke lest arbeidskøen» er noe en admin kan forholde seg til; navnet på
// funksjonen som feilet, er det ikke.
// ============================================================================

import { asOptionalText, asText, fieldsOf, raw, type Fields } from '../agents/strict-fields.ts'

const SUBJECT = 'Problemoversikten'

export interface TechnicalProblem {
  readonly reference: string
  readonly area: string
  readonly firstSeenAt: string
  readonly lastSeenAt: string
  readonly occurrenceCount: number
  readonly ongoing: boolean
  readonly resolvedAt: string | null
}

const AREA_SENTENCES: Readonly<Record<string, string>> = {
  work_queue: 'Antidep får ikke lest arbeidsoversikten',
  automatic_task: 'En automatisk oppgave har stoppet',
  agent_service: 'Tilkoblingen til agenttjenesten virker ikke',
  full_text_intake: 'En opplastet fulltekst kunne ikke behandles',
  clinical_content: 'Klinikerinnholdet kunne ikke vises',
}

/**
 * Hva slags problem dette er, uten et eneste teknisk begrep.
 *
 * En ukjent verdi får en sann, generell setning framfor å bli borte: et problem
 * som forsvant fra oversikten fordi flaten ikke kjente navnet på det, ville
 * vært verre enn et problem uten navn (ANTIDEP_CONSTITUTION.md regel 4).
 */
export function areaSentence(area: string): string {
  return AREA_SENTENCES[area] ?? 'Noe i Antidep virker ikke som det skal'
}

function asCount(fields: Fields, key: string): number {
  const value = raw(fields, key)
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    throw new Error(`${SUBJECT} er ugyldig: ${fields.where}.${key} er ikke et antall.`)
  }
  return value
}

function asFlag(fields: Fields, key: string): boolean {
  const value = raw(fields, key)
  if (typeof value !== 'boolean') {
    throw new Error(`${SUBJECT} er ugyldig: ${fields.where}.${key} er ikke en boolsk verdi.`)
  }
  return value
}

export function parseTechnicalProblems(value: unknown): readonly TechnicalProblem[] {
  if (!Array.isArray(value)) {
    throw new Error(`${SUBJECT} er ugyldig: svaret er ikke en liste.`)
  }
  return value.map((entry, index) => {
    const fields = fieldsOf(entry, SUBJECT, `rad ${String(index)}`)
    return {
      reference: asText(fields, 'reference'),
      area: asText(fields, 'area'),
      firstSeenAt: asText(fields, 'first_seen_at'),
      lastSeenAt: asText(fields, 'last_seen_at'),
      occurrenceCount: asCount(fields, 'occurrence_count'),
      ongoing: asFlag(fields, 'ongoing'),
      resolvedAt: asOptionalText(fields, 'resolved_at'),
    }
  })
}

/** Merket i navigasjonen: om det skal vises i det hele tatt, og hvor mange. */
export interface TechnicalProblemSummary {
  readonly visible: boolean
  readonly unresolved: number
}

export function parseTechnicalProblemSummary(value: unknown): TechnicalProblemSummary {
  const fields = fieldsOf(value, 'Problemtellingen', 'svaret')
  return {
    visible: asFlag(fields, 'visible'),
    unresolved: asCount(fields, 'unresolved'),
  }
}
