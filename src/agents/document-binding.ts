// ============================================================================
// Dokumentbindingen: hvilket originaldokument en representasjon kom fra
//
// En kildeversjon er enten teksten som lå på en adresse, eller tekst hentet ut
// av et originaldokument — i praksis PDF-en av en fulltekstartikkel. Er den det
// siste, bærer raden to opplysninger til (migrasjon 003e):
//
//   * **fingeravtrykket av dokumentet**, beregnet av databasen av bytene, og
//   * **oppskriften teksten ble hentet ut med**: verktøy, versjon, argumenter og
//     Antideps egen etterbehandling av verktøyets utdata.
//
// Til sammen er de kontrakten utad: *kjør denne oppskriften på dokumentet med
// dette fingeravtrykket, og sha256 av resultatet skal være `content_hash`.*
//
// ----------------------------------------------------------------------------
// Hvorfor dette er sin egen modul
//
// Formen bæres av tre filer — oppdraget, forslaget og kontrollgrunnlaget — og
// leses av fire ledd, hvorav ett er nettleseren: kontrolløkten viser hvilket
// dokument utdragene står i. Modulen har derfor **ingen** Node-avhengighet, og
// skal ikke få noen. Selve oppslaget av dokumentet (`source-document.ts`),
// tekstuttrekkingen (`document-text.ts`) og hentingen (`source-binding.ts`)
// ligger hver for seg, over denne.
//
// Utrygg inndata: bindingen er data, aldri instruksjoner (CLAUDE.md).
// ============================================================================

import { CONTENT_HASH_PREFIX } from './content-hash.ts'
import {
  asText,
  fieldsOf,
  nestedFields,
  problem,
  raw,
  rejectUnknown,
  type Fields,
} from './strict-fields.ts'

/** Verktøyet, versjonen av det, argumentene — og Antideps egen etterbehandling. */
export interface TextExtractionRecipe {
  readonly tool: string
  readonly toolVersion: string
  /** Argumentene, som én streng, slik de står i basen og i en kommandolinje. */
  readonly arguments: string
  /**
   * Antideps egen omforming av verktøyets utdata, med versjon, eller `null`.
   *
   * `null` betyr at teksten er nøyaktig det verktøyet skrev. Det er tilstanden
   * til hver kildeversjon registrert før leserekkefølgen ble rekonstruert, og
   * den må bevares: de radene skal etterprøves slik de faktisk ble laget, ikke
   * skrives om til å se ut som om de ble laget på den nye måten.
   */
  readonly transform: string | null
}

/** Originaldokumentet en kildeversjon er utledet av. */
export interface DocumentBinding {
  /** sha256 av originaldokumentets byte, slik databasen beregnet det. */
  readonly sha256: string
  readonly byteSize: number
  readonly mediaType: string
  /** Oppskriften teksten ble hentet ut med, og som gjentas ved etterprøving. */
  readonly textExtraction: TextExtractionRecipe
}

/**
 * Alt som skal til for å skaffe representasjonen på nytt.
 *
 * Den samme formen i oppdraget, i forslaget og i kontrollgrunnlaget, fordi det
 * er den samme opplysningen: tre ledd som beskrev den hver for seg, ville vært
 * tre steder å beskrive den litt forskjellig.
 */
export interface RepresentationBinding {
  readonly retrievedFrom: string
  readonly contentHash: string
  /** `null` når representasjonen er teksten på adressen, ikke et dokument. */
  readonly document: DocumentBinding | null
}

// ----------------------------------------------------------------------------
// Oppskriften er en lukket liste, ikke et fritekstfelt
//
// Oppskriften er den ene registrerte verdien som senere blir en **prosess**:
// etterprøvingen kjører verktøyet med argumentene som står i raden. Var feltet
// fritt, kunne en redaktør skrevet `sh` i det, og en verdi lest ut av basen
// ville blitt en kommando kjørt med rettighetene og miljøet til den som
// kontrollerer — altså kodekjøring ut av en skriverettighet. Det bryter med den
// ene regelen som gjelder alt importert og lagret innhold: data blir aldri
// instruksjoner (CLAUDE.md).
//
// Listen har i dag to rader: oppskriften nye kildeversjoner registreres med, og
// den hver eldre dokumentutledet rad allerede bærer. Den andre står der fordi
// etterprøvingen av en gammel rad skal gjenta det som faktisk ble gjort — ikke
// fordi den fortsatt brukes. Listen håndheves to steder — av CHECK-en på
// `knowledge.source_versions` (migrasjon 003f, utvidet i 003g) og her,
// umiddelbart før en prosess startes (`document-text.ts`) — fordi de to
// grensene er forskjellige grenser: den ene stenger for at verdien blir lagret,
// den andre for at en verdi som likevel er lagret, blir kjørt.
//
// Versjonen er med vilje ikke med i listen. Den er en opplysning, ikke noe som
// kjøres: den forklarer et avvik når to bygg gir forskjellig tekst, og fasiten
// er uansett fingeravtrykket av teksten.
// ----------------------------------------------------------------------------

/**
 * Verktøyet Antidep bruker, valgene det brukes med, og omformingen etterpå.
 *
 * `-bbox-layout` gir ikke tekst, men **posisjonsdata**: hvert ord med sine
 * koordinater, gruppert i linjer og blokker. Det er hele poenget. Den forrige
 * oppskriften var `-layout`, som gjenskaper den *fysiske* plasseringen på
 * papiret — og i en tospaltet artikkel legger den dermed venstre og høyre
 * spalte ved siden av hverandre på den samme tekstlinjen. Antideps ordrette
 * kontroll normaliserer blanktegn før den søker, og to uavhengige spalter ble
 * da én sammenhengende tegnstrøm: en klinisk opplysning kunne tilskrives feil
 * arm eller feil studie (issue #84).
 *
 * `antidep-reading-order@2` er Antideps eget, deterministiske ledd som gjør
 * posisjonsdataene om til **logisk leserekkefølge** — spalte for spalte, ovenfra
 * og ned, med full sidebredde håndtert av den samme regelen, og med en avvisning
 * framfor en gjetning når rekkefølgen ikke er gitt av oppsettet
 * (`reading-order.ts`). Den er en del av oppskriften på lik linje med
 * argumentene: uten den kommer ingen tredjepart fram til den samme teksten, og
 * `content_hash` ville vært et fingeravtrykk av noe bare Antidep kunne lage.
 *
 * `-enc UTF-8` og `-eol unix` gjør resultatet uavhengig av maskinen: uten dem
 * ville den samme PDF-en gitt forskjellige byte på Windows og Linux, og
 * fingeravtrykket ville beskrevet operativsystemet.
 *
 * Verdiene står ordrett likt i migrasjon 003g. De er den samme kontrakten sett
 * fra hver sin side av databasegrensen, og pinnes derfor av en prøve på begge.
 */
export const PDF_TEXT_TOOL = 'pdftotext'
export const PDF_TEXT_ARGUMENTS = '-bbox-layout -enc UTF-8 -eol unix'
export const PDF_TEXT_TRANSFORM = 'antidep-reading-order@2'

/** En oppskrift uten versjonen: nøyaktig det som blir kjørt. */
export interface AllowedRecipe {
  readonly tool: string
  readonly arguments: string
  readonly transform: string | null
}

/**
 * Oppskriftene Antidep kjører, og ingen andre.
 *
 * Listen har to rader, og det er ikke en overgangsordning som skal ryddes bort.
 * Den nederste er oppskriften alle dokumentutledede kildeversjoner registrert
 * før migrasjon 003g bærer, og etterprøvingen av *dem* skal gjenta det som
 * faktisk ble gjort. En liste med bare den nye ville gjort hver eldre rad
 * ukontrollerbar — og alternativet, å skrive om de gamle radene, ville vært å
 * påstå at de ble laget på en måte de ikke ble laget på.
 *
 * Nye registreringer bruker bare den øverste. Det håndheves der en ny rad
 * skrives (`api.create_source_version_from_document`), ikke her: denne listen
 * svarer på hva som kan *kjøres*, som er et annet spørsmål enn hva som kan
 * *lagres*.
 *
 * `antidep-reading-order@1` står med vilje ikke her. Den rakk aldri å bli
 * sluppet: den delte ikke en tabellrad Poppler hadde lagt i én blokk, og lot
 * dermed et sitat gå fra en radetikett og inn i en fremmed celle
 * (`reading-order.ts`). Databasen godtar den fortsatt som en *lagret* verdi, så
 * de radene som bærer den, ikke må skrives om for å se ut som noe annet enn det
 * de er — men den skal ikke kunne kjøres igjen, og et kall som ber om den,
 * avvises her framfor å gi en tekst ingen skal bygge videre på.
 */
export const ALLOWED_PDF_RECIPES: readonly AllowedRecipe[] = [
  { tool: PDF_TEXT_TOOL, arguments: PDF_TEXT_ARGUMENTS, transform: PDF_TEXT_TRANSFORM },
  { tool: PDF_TEXT_TOOL, arguments: '-layout -enc UTF-8 -eol unix', transform: null },
]

/** Oppskriften en **ny** kildeversjon registreres med. */
export const CURRENT_PDF_RECIPE: AllowedRecipe = {
  tool: PDF_TEXT_TOOL,
  arguments: PDF_TEXT_ARGUMENTS,
  transform: PDF_TEXT_TRANSFORM,
}

function describeRecipe(recipe: AllowedRecipe): string {
  const transform = recipe.transform === null ? 'uten etterbehandling' : `+ ${recipe.transform}`
  return `${recipe.tool} ${recipe.arguments} ${transform}`
}

/**
 * Hvorfor en oppskrift ikke er en Antidep kan kjøre, eller `null` når den er det.
 *
 * Svarer med én setning, slik at avvisningen sier hva som var galt uten å
 * gjenta den forbudte verdien som om den var et forslag.
 */
export function disallowedRecipeReason(recipe: TextExtractionRecipe): string | null {
  const allowed = ALLOWED_PDF_RECIPES.some(
    (candidate) =>
      candidate.tool === recipe.tool &&
      candidate.arguments === recipe.arguments &&
      candidate.transform === recipe.transform,
  )
  if (allowed) {
    return null
  }
  return (
    `Oppskriften ${JSON.stringify(describeRecipe(recipe))} er ikke en Antidep kjører. ` +
    `Listen er lukket, og har i dag ${ALLOWED_PDF_RECIPES.map((candidate) => JSON.stringify(describeRecipe(candidate))).join(' og ')}. ` +
    'Et registrert verktøynavn og et registrert argument blir en prosess ved etterprøving, ' +
    'og et fritt felt ville latt en skriverettighet bli kodekjøring hos den som kontrollerer.'
  )
}

const DOCUMENT_DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/

/** Om en verdi har formen `knowledge.source_versions.document_sha256` krever. */
export function isDocumentDigest(value: string): boolean {
  return DOCUMENT_DIGEST_PATTERN.test(value)
}

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
}

/**
 * sha256 av bytene slik de er, med algoritmen som prefiks.
 *
 * Samme form og samme algoritme som `sourceVersionContentHash`, men over
 * *bytes* og ikke over tekst. Skillet er hele poenget: en PDF er ikke tekst, og
 * en hash av «PDF-en dekodet som UTF-8» ville verken vært reproduserbar eller
 * meningsfull (`source-retrieval.ts`).
 */
export async function documentDigest(bytes: Uint8Array): Promise<string> {
  // Kopieres inn i en egen ArrayBuffer: en Uint8Array kan være et utsnitt av en
  // større buffer, og `crypto.subtle.digest` ville da hashet hele bufferen.
  const copy = new Uint8Array(bytes.byteLength)
  copy.set(bytes)
  return CONTENT_HASH_PREFIX + toHex(await crypto.subtle.digest('SHA-256', copy.buffer))
}

// ----------------------------------------------------------------------------
// Hva slags fil dette er, lest av bytene og ikke av navnet
//
// Endelsen `.pdf` er en påstand den som lagret filen gjorde. De første bytene
// er dokumentet selv. Kontrollen er bevisst smal: den avgjør bare om noe *er*
// en PDF, som er den ene formen kjeden i dag kan hente tekst ut av med
// etterprøvbar proveniens.
// ----------------------------------------------------------------------------

/** Mediatypen en PDF registreres med. */
export const PDF_MEDIA_TYPE = 'application/pdf'

/** PDF-signaturen, ordrett. */
export const PDF_MAGIC = '%PDF-'

/** Om bytene begynner med PDF-signaturen. */
export function looksLikePdf(bytes: Uint8Array): boolean {
  if (bytes.length < PDF_MAGIC.length) {
    return false
  }
  for (let index = 0; index < PDF_MAGIC.length; index += 1) {
    if (bytes[index] !== PDF_MAGIC.charCodeAt(index)) {
      return false
    }
  }
  return true
}

/**
 * Om en tekst begynner med PDF-signaturen.
 *
 * Motstykket til `looksLikePdf` for veien der en fil allerede er blitt til
 * tekst — et innlimt felt, en fil lest som UTF-8, en `retrieved_content`. En
 * PDF som har vært innom den veien, er ikke lenger dokumentet: bytene er
 * omkodet, og fingeravtrykket ville beskrevet omkodingen framfor filen.
 */
export function textLooksLikePdf(text: string): boolean {
  return text.startsWith(PDF_MAGIC)
}

// ----------------------------------------------------------------------------
// Formen dokumentbindingen har i en fil
//
// Oppdraget og forslaget bærer den samme blokka, lest av den samme koden. To
// lesere ville vært to steder å stave et feltnavn feil — og feilen ville først
// vist seg som en kildeversjon som ble hentet på feil måte.
// ----------------------------------------------------------------------------

const DIGEST_HINT = 'har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn'

/** Leser `document`-blokka, eller `null` når den ikke står der. */
export function parseDocumentBinding(parent: Fields, key = 'document'): DocumentBinding | null {
  const value = raw(parent, key)
  if (value === undefined || value === null) {
    return null
  }
  const fields = nestedFields(parent, value, key)

  const sha256 = asText(fields, 'sha256')
  if (!isDocumentDigest(sha256)) {
    problem(fields.subject, `${key}.sha256`, DIGEST_HINT)
  }

  const byteSize = raw(fields, 'byte_size')
  if (typeof byteSize !== 'number' || !Number.isInteger(byteSize) || byteSize <= 0) {
    problem(fields.subject, `${key}.byte_size`, 'er ikke et helt tall større enn null')
  }

  const mediaType = asText(fields, 'media_type')
  const extraction = nestedFields(fields, raw(fields, 'text_extraction'), `${key}.text_extraction`)
  const transform = raw(extraction, 'transform')
  if (transform !== undefined && transform !== null && typeof transform !== 'string') {
    problem(extraction.subject, `${key}.text_extraction.transform`, 'er verken en tekst eller null')
  }
  const recipe: TextExtractionRecipe = {
    tool: asText(extraction, 'tool'),
    toolVersion: asText(extraction, 'tool_version'),
    arguments: asText(extraction, 'arguments'),
    // Utelatt felt og `null` betyr det samme: teksten er verktøyets utdata
    // ordrett. Formen må godta utelatelsen, fordi hver fil og hvert
    // kontrollgrunnlag skrevet før migrasjon 003g er uten feltet.
    transform: typeof transform === 'string' ? transform : null,
  }
  rejectUnknown(extraction)
  rejectUnknown(fields)

  return { sha256, byteSize, mediaType, textExtraction: recipe }
}

/**
 * Den samme blokka lest ut av en verdi som ikke ligger i et felt.
 *
 * Kontrollgrunnlaget fra databasen er ett jsonb-objekt og ikke en fil, og
 * `document` ligger inne i `source_version`. Formen skal likevel leses av
 * nøyaktig den samme koden: to lesere ville vært to steder å godta litt
 * forskjellige former, og forskjellen ville vist seg som en kontroll som hentet
 * teksten på feil måte.
 */
export function parseDocumentBindingValue(
  value: unknown,
  subject: string,
  where: string,
): DocumentBinding | null {
  if (value === undefined || value === null) {
    return null
  }
  return parseDocumentBinding(fieldsOf({ document: value }, subject, where), 'document')
}

/** Skriver `document`-blokka slik `parseDocumentBinding` leser den. */
export function serializeDocumentBinding(document: DocumentBinding | null): unknown {
  if (document === null) {
    return null
  }
  return {
    sha256: document.sha256,
    byte_size: document.byteSize,
    media_type: document.mediaType,
    text_extraction: {
      tool: document.textExtraction.tool,
      tool_version: document.textExtraction.toolVersion,
      arguments: document.textExtraction.arguments,
      transform: document.textExtraction.transform,
    },
  }
}

/**
 * Om to dokumentbindinger beskriver det samme dokumentet og den samme
 * oppskriften.
 *
 * Returnerer `null` når de gjør det, ellers én setning som sier hva som
 * skiller dem. Fraværet av en binding er også en verdi: en fulltekstversjon som
 * plutselig ikke har noe dokument, er ikke den samme kildeversjonen.
 */
export function documentBindingMismatch(
  expected: DocumentBinding | null,
  actual: DocumentBinding | null,
): string | null {
  if (expected === null && actual === null) {
    return null
  }
  if (expected === null || actual === null) {
    return actual === null
      ? 'forslaget oppgir ingen dokumentbinding, mens oppdraget er utledet av et originaldokument'
      : 'forslaget oppgir en dokumentbinding, mens oppdraget ikke er utledet av et originaldokument'
  }
  const pairs: readonly (readonly [string, string, string])[] = [
    ['document.sha256', actual.sha256, expected.sha256],
    ['document.byte_size', String(actual.byteSize), String(expected.byteSize)],
    ['document.media_type', actual.mediaType, expected.mediaType],
    ['document.text_extraction.tool', actual.textExtraction.tool, expected.textExtraction.tool],
    [
      'document.text_extraction.tool_version',
      actual.textExtraction.toolVersion,
      expected.textExtraction.toolVersion,
    ],
    [
      'document.text_extraction.arguments',
      actual.textExtraction.arguments,
      expected.textExtraction.arguments,
    ],
    [
      'document.text_extraction.transform',
      actual.textExtraction.transform ?? 'ingen',
      expected.textExtraction.transform ?? 'ingen',
    ],
  ]
  for (const [key, proposed, wanted] of pairs) {
    if (proposed !== wanted) {
      return `${key} er ${JSON.stringify(proposed)} i forslaget, men ${JSON.stringify(wanted)} i oppdraget`
    }
  }
  return null
}
