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
  /**
   * Hva arbeidet venter på utenfor kjeden, eller `null`.
   *
   * Ett felt med ett ord i, og ikke ett boolsk felt per ting det kan vente på:
   * to felter som utelukker hverandre, ville vært to formuleringer av det
   * samme spørsmålet, og det tredje som en gang kommer, ville blitt et tredje
   * felt.
   */
  readonly waitingFor: string | null
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
  claim_revision: 'Vurdere om ny forskning endrer en påstand Antidep allerede har',
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
 * Setningene om hva et stykke arbeid venter på.
 *
 * Begge er produkttilstander: kjeden kan ikke gå videre av seg selv, men
 * ingenting er i stykker (ANTIDEP_CONSTITUTION.md regel 4). Den andre er
 * planlagt redaksjonelt arbeid — ny kunnskap finnes, og en redaktør skal
 * avgjøre om den eksisterende teksten skal skrives om i lys av den.
 */
const WAITING_NOTES: Readonly<Record<string, string>> = {
  full_text: 'Venter på fulltekst',
  editorial_decision:
    'Ny forskning er kommet til, og venter på at en redaktør avgjør om påstanden ' +
    'skal oppdateres',
}

/**
 * Setningen som står under en oppgave.
 *
 * En ventetilstand flaten ikke kjenner, gir ingen setning framfor en gjettet:
 * en oversikt som fant på en forklaring, ville sagt noe den ikke vet.
 */
export function workStatusNote(item: WorkBoardItem): string | null {
  if (item.waitingFor !== null) {
    return WAITING_NOTES[item.waitingFor] ?? null
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
    const waiting = raw(fields, 'waiting_for')
    if (waiting !== null && waiting !== undefined && typeof waiting !== 'string') {
      throw new Error(
        `${SUBJECT} er ugyldig: ${fields.where}.waiting_for er verken en tekst eller tom.`,
      )
    }
    return {
      reference: asText(fields, 'reference'),
      activity: asText(fields, 'activity'),
      status: asStatus(fields, 'status'),
      waitingFor: typeof waiting === 'string' && waiting.length > 0 ? waiting : null,
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
