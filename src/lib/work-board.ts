// ============================================================================
// Den åpne arbeidsoversikten, lest og sagt på norsk
//
// Databasen svarer med et lukket produktvokabular og ingenting annet: hva slags
// arbeid det er, hvilken tilstand det står i, hvilke virkestoff det gjelder, og
// en ugjennomsiktig referanse. Modulen her leser det svaret strengt, og eier
// oversettelsen til setninger et menneske kan lese.
//
// Den ligger i `lib` og ikke i komponentfilen av samme grunn som
// `vocabulary-view.ts`: den leses av flere flater, og en fil som eksporterer
// både en komponent og en konstant, mister hot-reloaden sin.
//
// ----------------------------------------------------------------------------
// Hvorfor en ukjent verdi ikke blir borte
//
// Vokabularene er lukket i databasen, men en flate som er eldre enn databasen,
// vil før eller siden møte en verdi den ikke kjenner. Den vises da som «annet
// arbeid» framfor å forsvinne: en oppgave som ikke lot seg oversette, er
// fortsatt en oppgave, og en oversikt som stilltiende utelot den, ville løyet
// om hvor mye som står igjen (ANTIDEP_CONSTITUTION.md regel 4).
//
// ----------------------------------------------------------------------------
// Status uttrykkes aldri med farge alene
//
// Hver tilstand har et tegn, en tekst og en farge, og de tre følges alltid ad.
// Tegnene er forskjellige former og ikke bare forskjellige farger, slik at de
// skiller seg også i svart-hvitt og for den som ikke ser fargeforskjellen.
// ============================================================================

import { asText, fieldsOf, raw, type Fields } from '../agents/strict-fields.ts'

const SUBJECT = 'Arbeidsoversikten'

/** De fire tilstandene issue #99 navngir, og ingen flere. */
export type WorkStatus = 'planned' | 'in_progress' | 'failed' | 'done'

const WORK_STATUSES: readonly WorkStatus[] = ['planned', 'in_progress', 'failed', 'done']

export interface WorkBoardItem {
  readonly reference: string
  /** Produktets eget ord for hva slags arbeid det er. Aldri en agentrolle. */
  readonly activity: string
  readonly status: WorkStatus
  /** Om det som står i veien, er at fullteksten mangler. */
  readonly waitingForFullText: boolean
  /** Virkestoffene arbeidet gjelder. Kan være tom. */
  readonly subjects: readonly string[]
  readonly updatedAt: string
}

/** Hvordan én tilstand skal vises: tegn, tekst og fargeklasse — alltid alle tre. */
export interface StatusPresentation {
  readonly symbol: string
  readonly label: string
  readonly tone: 'planned' | 'progress' | 'failed' | 'done'
}

const STATUS_PRESENTATION: Readonly<Record<WorkStatus, StatusPresentation>> = {
  planned: { symbol: '◻', label: 'Planlagt', tone: 'planned' },
  in_progress: { symbol: '◐', label: 'Pågår', tone: 'progress' },
  failed: { symbol: '✕', label: 'Stoppet', tone: 'failed' },
  done: { symbol: '✓', label: 'Fullført', tone: 'done' },
}

export function statusPresentation(status: WorkStatus): StatusPresentation {
  return STATUS_PRESENTATION[status]
}

/** Rekkefølgen oversikten vises i: det som pågår først, historikken sist. */
export const WORK_STATUS_ORDER: readonly WorkStatus[] = ['in_progress', 'planned', 'failed', 'done']

const ACTIVITY_LABELS: Readonly<Record<string, string>> = {
  full_text: 'Skaffe fullteksten til en forskningsartikkel',
  findings: 'Hente funn ut av en forskningsartikkel',
  findings_check: 'Kontrollere funnene mot artikkelen',
  claim: 'Formulere en klinisk påstand av funnene',
  claim_check: 'Kontrollere at påstanden har dekning i kildene',
  assessment: 'Vurdere hvor sikker evidensen er',
}

/** Hva slags arbeid dette er, i klinikerens språk. */
export function activityLabel(activity: string): string {
  return ACTIVITY_LABELS[activity] ?? 'Annet arbeid i kunnskapsgrunnlaget'
}

/**
 * Setningen som står under en oppgave.
 *
 * «Venter på fulltekst» er den ene formuleringen issue #99 navngir, og den er
 * en produkttilstand: kjeden kan ikke gå videre, men ingenting er i stykker.
 */
export function workStatusNote(item: WorkBoardItem): string | null {
  if (item.waitingForFullText) {
    return 'Venter på fulltekst'
  }
  if (item.status === 'failed') {
    return 'Antidep kom ikke videre med denne, og ser på den igjen'
  }
  return null
}

function asStatus(fields: Fields, key: string): WorkStatus {
  const value = asText(fields, key)
  if (!WORK_STATUSES.includes(value as WorkStatus)) {
    throw new Error(`${SUBJECT} er ugyldig: ${fields.where}.${key} er en ukjent tilstand.`)
  }
  return value as WorkStatus
}

function asStringList(fields: Fields, key: string): readonly string[] {
  const value = raw(fields, key)
  if (!Array.isArray(value)) {
    throw new Error(`${SUBJECT} er ugyldig: ${fields.where}.${key} er ikke en liste.`)
  }
  return value.map((entry, index) => {
    if (typeof entry !== 'string' || entry.length === 0) {
      throw new Error(
        `${SUBJECT} er ugyldig: ${fields.where}.${key}[${String(index)}] er ikke en tekst.`,
      )
    }
    return entry
  })
}

export function parseWorkBoard(value: unknown): readonly WorkBoardItem[] {
  if (!Array.isArray(value)) {
    throw new Error(`${SUBJECT} er ugyldig: svaret er ikke en liste.`)
  }
  return value.map((entry, index) => {
    const fields = fieldsOf(entry, SUBJECT, `rad ${String(index)}`)
    const waiting = raw(fields, 'waiting_for_full_text')
    if (typeof waiting !== 'boolean') {
      throw new Error(
        `${SUBJECT} er ugyldig: ${fields.where}.waiting_for_full_text er ikke en boolsk verdi.`,
      )
    }
    return {
      reference: asText(fields, 'reference'),
      activity: asText(fields, 'activity'),
      status: asStatus(fields, 'status'),
      waitingForFullText: waiting,
      subjects: asStringList(fields, 'subjects'),
      updatedAt: asText(fields, 'updated_at'),
    }
  })
}

/** Oppgavene gruppert slik oversikten viser dem, uten tomme grupper. */
export function groupByStatus(
  items: readonly WorkBoardItem[],
): readonly { readonly status: WorkStatus; readonly items: readonly WorkBoardItem[] }[] {
  return WORK_STATUS_ORDER.map((status) => ({
    status,
    items: items.filter((item) => item.status === status),
  })).filter((group) => group.items.length > 0)
}
