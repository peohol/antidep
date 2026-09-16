// ============================================================================
// Fulltekstinnboksen, lest og sagt på norsk
//
// Innboksen er den ene flaten der et menneske gjør noe for at kjeden skal gå
// videre, og handlingen er redaksjonell: å kjenne igjen hvilken artikkel som
// mangler, og velge riktig fil. Alt annet — bindingen, identitetskontrollen,
// lesbarhetskontrollen, tekstuttrekket, registreringen og kølegging av neste
// ledd — er Antideps eget arbeid (issue #99).
//
// Svaret bærer derfor bibliografien og en tilstand, og ingen uuid, ingen hash,
// ingen oppskrift og ingen rå årsak. Modulen her eier oversettelsen av de to
// lukkede vokabularene som finnes: tilstanden, og grunnen til at forrige fil
// ikke kunne brukes.
// ============================================================================

import { asOptionalText, asText, fieldsOf, raw, type Fields } from '../agents/strict-fields.ts'

const SUBJECT = 'Fulltekstinnboksen'

export type InboxState = 'needs_upload' | 'processing'

const INBOX_STATES: readonly InboxState[] = ['needs_upload', 'processing']

export interface FullTextInboxItem {
  readonly reference: string
  readonly title: string
  readonly authors: string
  readonly publishedYear: number | null
  readonly state: InboxState
  /** Hvorfor forrige fil ikke kunne brukes, som en lukket kode. */
  readonly previousRejection: string | null
}

/**
 * Hvorfor forrige fil ikke kunne brukes, i én setning som sier hva som kan
 * gjøres i stedet.
 *
 * Kodene er lukkede i databasen. En ukjent kode får en sann, generell setning
 * framfor å bli borte: en avvisning som forsvant, ville sett ut som om
 * ingenting hadde skjedd.
 */
const REJECTION_SENTENCES: Readonly<Record<string, string>> = {
  not_this_article:
    'Forrige fil så ikke ut til å være denne artikkelen. Antidep fant verken artikkelens DOI, ' +
    'dens PubMed-nummer eller tittelen i teksten. Velg filen som hører til nettopp denne ' +
    'artikkelen.',
  unreadable:
    'Forrige fil lot seg ikke lese godt nok. Det skjer typisk når tabellene er bilder framfor ' +
    'tekst, eller når filen er en skannet kopi. Prøv utgiverens egen PDF.',
  not_a_pdf: 'Forrige fil var ikke en PDF. Antidep tar bare imot PDF-filer.',
  other_document_same_text:
    'Den samme teksten er allerede registrert for denne artikkelen, fra en annen fil. Bruk den ' +
    'filen artikkelen faktisk ble registrert fra.',
  extraction_failed:
    'Antidep fikk ikke hentet tekst ut av forrige fil. Det er meldt videre som et teknisk ' +
    'problem; prøv gjerne en annen utgave av artikkelen.',
}

export function rejectionSentence(code: string): string {
  return (
    REJECTION_SENTENCES[code] ??
    'Forrige fil kunne ikke brukes. Prøv en annen utgave av artikkelen.'
  )
}

/** Hva innboksen ber om, i én setning per tilstand. */
export function inboxStateSentence(state: InboxState): string {
  return state === 'needs_upload'
    ? 'Last opp fullteksten for at Antidep skal kunne fortsette.'
    : 'Antidep arbeider med filen du lastet opp. Du trenger ikke gjøre noe mer.'
}

/** Artikkelen slik den vises: forfattere og år, når de finnes. */
export function describeArticle(item: FullTextInboxItem): string {
  return item.publishedYear === null
    ? item.authors
    : `${item.authors} (${String(item.publishedYear)})`
}

function asState(fields: Fields, key: string): InboxState {
  const value = asText(fields, key)
  if (!INBOX_STATES.includes(value as InboxState)) {
    throw new Error(`${SUBJECT} er ugyldig: ${fields.where}.${key} er en ukjent tilstand.`)
  }
  return value as InboxState
}

function asOptionalYear(fields: Fields, key: string): number | null {
  const value = raw(fields, key)
  if (value === null || value === undefined) {
    return null
  }
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new Error(`${SUBJECT} er ugyldig: ${fields.where}.${key} er ikke et årstall.`)
  }
  return value
}

export function parseFullTextInbox(value: unknown): readonly FullTextInboxItem[] {
  if (!Array.isArray(value)) {
    throw new Error(`${SUBJECT} er ugyldig: svaret er ikke en liste.`)
  }
  return value.map((entry, index) => {
    const fields = fieldsOf(entry, SUBJECT, `rad ${String(index)}`)
    return {
      reference: asText(fields, 'reference'),
      title: asText(fields, 'title'),
      authors: asText(fields, 'authors'),
      publishedYear: asOptionalYear(fields, 'published_year'),
      state: asState(fields, 'state'),
      previousRejection: asOptionalText(fields, 'previous_rejection'),
    }
  })
}

/** Utfallet av én opplasting, slik flaten trenger det. */
export interface FullTextSubmission {
  readonly accepted: boolean
}

export function parseFullTextSubmission(value: unknown): FullTextSubmission {
  const fields = fieldsOf(value, 'Opplastingssvaret', 'svaret')
  const accepted = raw(fields, 'accepted')
  if (typeof accepted !== 'boolean') {
    throw new Error('Opplastingssvaret er ugyldig: svaret.accepted er ikke en boolsk verdi.')
  }
  return { accepted }
}
