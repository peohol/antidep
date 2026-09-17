// ============================================================================
// Bestillingen av en artikkel Antidep mangler, lest og sagt på norsk
//
// Dette er den andre av de to handlingene et menneske gjør i kjeden, og den er
// like redaksjonell som den første: å avgjøre hvilken artikkel Antidep trenger,
// og hva et funn fra den kan gjelde. Alt annet — kilderaden, adressen
// dokumentet hentes fra, kildeversjonen, jobbnøkkelen, agentrollen — utleder
// Antidep selv (issue #101, punkt 3).
//
// Modulen eier tre ting: hva flaten kan velge mellom, hva den kan sende, og
// hvordan en bestilling beskrives etterpå. Ingen av delene bærer en uuid, en
// hash, et rpc-navn eller en transportverdi.
//
// ----------------------------------------------------------------------------
// Hvorfor DOI-en kontrolleres her *og* i databasen
//
// Databasens kontroll er den som gjelder. Kontrollen her finnes for at den som
// skriver feil, skal få vite det mens feltet står foran dem — framfor å sende
// en bestilling som kommer tilbake som en avvisning uten å si hvilket felt det
// gjaldt. Samme grep som `fileProblem` i `full-text-inbox.ts`, og av samme
// grunn: en høflighet mot den som skrev feil, ikke en sikkerhetsgrense.
// ============================================================================

import { asText, fieldsOf, raw } from '../agents/strict-fields.ts'

const SUBJECT = 'Bestillingen'

/** De faglige valgene en bestilling kan avgrenses med. Navn, aldri id-er. */
export interface FullTextRequestOptions {
  readonly drugs: readonly string[]
  readonly outcomes: readonly string[]
  readonly populations: readonly string[]
}

function asNameList(value: unknown, where: string): readonly string[] {
  if (!Array.isArray(value)) {
    throw new Error(`${SUBJECT} er ugyldig: ${where} er ikke en liste.`)
  }
  return value.map((entry, index) => {
    if (typeof entry !== 'string' || entry.length === 0) {
      throw new Error(`${SUBJECT} er ugyldig: ${where}[${String(index)}] er ikke et navn.`)
    }
    return entry
  })
}

export function parseRequestOptions(value: unknown): FullTextRequestOptions {
  const fields = fieldsOf(value, SUBJECT, 'valgene')
  return {
    drugs: asNameList(raw(fields, 'drugs'), 'valgene.drugs'),
    outcomes: asNameList(raw(fields, 'outcomes'), 'valgene.outcomes'),
    populations: asNameList(raw(fields, 'populations'), 'valgene.populations'),
  }
}

/** Hva den innloggede kan gjøre på fulltekstflatene. */
export interface FullTextCapabilities {
  readonly mayRequest: boolean
  readonly mayUpload: boolean
}

function asFlag(value: unknown, where: string): boolean {
  if (typeof value !== 'boolean') {
    throw new Error(`${SUBJECT} er ugyldig: ${where} er ikke en boolsk verdi.`)
  }
  return value
}

export function parseCapabilities(value: unknown): FullTextCapabilities {
  const fields = fieldsOf(value, SUBJECT, 'svaret')
  return {
    mayRequest: asFlag(raw(fields, 'may_request'), 'svaret.may_request'),
    mayUpload: asFlag(raw(fields, 'may_upload'), 'svaret.may_upload'),
  }
}

/** Én bestilling, slik flaten sender den. */
export interface FullTextRequestDraft {
  readonly doi: string
  readonly title: string
  readonly authors: string
  readonly journal: string
  readonly year: string
  readonly drugs: readonly string[]
  readonly outcomes: readonly string[]
  readonly populations: readonly string[]
}

export const EMPTY_REQUEST: FullTextRequestDraft = {
  doi: '',
  title: '',
  authors: '',
  journal: '',
  year: '',
  drugs: [],
  outcomes: [],
  populations: [],
}

/**
 * Formen en DOI har.
 *
 * Gjentatt fra `knowledge.source_identifiers`, med vilje og ikke som en andre
 * sannhet: databasen avviser uansett. Verdien fra flaten normaliseres på den
 * samme måten databasen gjør — små bokstaver, uten doi.org foran — slik at det
 * som vises i feltet, er det som faktisk blir lagret.
 */
const DOI_SHAPE = /^10\.[0-9]{4,9}\/\S+$/

export function normaliseDoi(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\/(dx\.)?doi\.org\//, '')
}

/**
 * Hvorfor bestillingen ikke kan sendes ennå, eller `null`.
 *
 * Én setning om gangen, og alltid om feltet som står nærmest. En liste over alt
 * som mangler, ville vært en feilmelding og ikke en hjelp.
 */
export function requestProblem(draft: FullTextRequestDraft): string | null {
  if (draft.title.trim().length === 0) {
    return 'Skriv artikkelens tittel.'
  }
  if (draft.authors.trim().length === 0) {
    return 'Skriv forfatterne, slik de står på artikkelen.'
  }
  if (!DOI_SHAPE.test(normaliseDoi(draft.doi))) {
    return (
      'Skriv artikkelens DOI. Den begynner med 10. og et firesifret tall, for eksempel ' +
      '10.1016/j.jad.2019.01.001, og står på artikkelens forside og i referanselisten. ' +
      'En lenke til doi.org kan limes inn som den er.'
    )
  }
  if (draft.year.trim().length > 0) {
    const year = Number(draft.year.trim())
    const nextYear = new Date().getFullYear() + 1
    if (!Number.isInteger(year) || year < 1800 || year > nextYear) {
      return 'Årstallet ser ikke ut til å høre til en publisert artikkel.'
    }
  }
  if (draft.drugs.length === 0) {
    return 'Velg minst ett virkestoff et funn fra artikkelen kan gjelde.'
  }
  if (draft.outcomes.length === 0) {
    return 'Velg minst ett endepunkt et funn fra artikkelen kan gjelde.'
  }
  return null
}

/** Utfallet av én bestilling, slik flaten trenger det. */
export interface FullTextRequestResult {
  readonly requested: boolean
  readonly state: string
  readonly title: string
}

export function parseRequestResult(value: unknown): FullTextRequestResult {
  const fields = fieldsOf(value, SUBJECT, 'svaret')
  const requested = raw(fields, 'requested')
  if (typeof requested !== 'boolean') {
    throw new Error(`${SUBJECT} er ugyldig: svaret.requested er ikke en boolsk verdi.`)
  }
  return {
    requested,
    state: asText(fields, 'state'),
    title: asText(fields, 'title'),
  }
}

/**
 * Hva som skjedde, i én setning til den som bestilte.
 *
 * «Allerede bestilt» er ikke en feil, og skal ikke se ut som en: to redaktører
 * som ber om den samme artikkelen, har begge gjort riktig.
 */
export function requestOutcomeSentence(result: FullTextRequestResult): string {
  if (result.requested) {
    return (
      `Takk — Antidep venter nå på «${result.title}». Den står i fulltekstinnboksen, og ` +
      'i arbeidsoversikten som planlagt arbeid. Du trenger ikke gjøre noe mer før PDF-en ' +
      'skal velges.'
    )
  }
  if (result.state === 'open') {
    return (
      `Antidep venter allerede på «${result.title}», med den samme avgrensningen. ` +
      'Bestillingen er den samme, og ingenting er dublert.'
    )
  }
  return (
    `«${result.title}» er allerede behandlet av Antidep. Skal den avgrenses på en ny måte, ` +
    'er det en ny bestilling etter at fullteksten er registrert.'
  )
}
