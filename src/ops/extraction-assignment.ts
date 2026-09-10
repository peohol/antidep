// ============================================================================
// Fra en lokal original-PDF til et ferdig ekstraksjonsoppdrag
//
// Ett skritt for den som har artikkelen liggende, og som ikke skal måtte kjenne
// en eneste uuid:
//
//   loadDocumentFile          PDF-en leses, og får sitt fingeravtrykk
//   currentPdfRecipe          verktøyet og versjonen som faktisk er installert
//   extractDocumentText       teksten hentes ut, og hashes
//   api.create_source_version_from_document
//                             kildeversjonen registreres — databasen beregner
//                             begge fingeravtrykkene selv
//   (dokumentlageret)         PDF-en legges under fingeravtrykket sitt, slik at
//                             resten av kjeden finner den uten et filnavn
//   api.build_extraction_assignment
//                             oppdraget bygges av databasens egne rader
//   parseExtractionAssignment svaret leses med den samme strengheten som en fil
//   → assignments/<navn>.json
//
// ----------------------------------------------------------------------------
// Hvorfor oppdraget kommer fra databasen og ikke settes sammen her
//
// Oppdraget er en **tiltrodd** inndata: registreringen kontrollerer forslaget
// mot det (`extraction-run.ts`), så oppdraget er halvparten av kontrollen. Et
// oppdrag satt sammen her av verdier lest ut av flere svar, ville vært en
// kontroll mot en kopi — og en kildebinding satt sammen av `retrieved_from` fra
// én rad og `content_hash` fra en annen, ville sendt hele kjeden til feil tekst
// uten at noe merket det.
//
// Denne modulen velger derfor bare *hvilken* kildeversjon og *hvilken*
// avgrensning som gjelder, og lar `api.build_extraction_assignment(...)` skrive
// oppdraget (migrasjon 007i).
//
// ----------------------------------------------------------------------------
// Hvorfor kommandoen er idempotent
//
// Den samme PDF-en registrert to ganger er den samme observasjonen, og
// `source_versions_source_content_key` avviser den. Kommandoen slår derfor opp
// om kildeversjonen allerede finnes — på **teksten sitt** fingeravtrykk — og
// bruker den framfor å stoppe. En avbrutt kjøring kan da kjøres om igjen, som
// er den normale tilstanden når noe går galt midtveis.
//
// ----------------------------------------------------------------------------
// Ingen skrivevei inn i modell-leddet
//
// Denne modulen har editor-legitimasjon og skriver rader. Den er derfor ikke
// nåbar fra modell-leddet, og skal ikke bli det: modell-leddet leser en fil
// (EVIDENCE_PIPELINE.md §63, `drafting-no-write-path.test.ts`).
// ============================================================================

import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

import { documentDigest } from '../agents/document-binding.ts'
import {
  currentPdfRecipe,
  extractDocumentText,
  type RunTool,
  type TextExtractionRecipe,
} from '../agents/document-text.ts'
import {
  parseExtractionAssignment,
  type ExtractionAssignment,
} from '../agents/extraction-assignment.ts'
import { loadDocumentFile, type LoadedDocument } from '../agents/source-document.ts'
import type { EditorSourceRow, EditorSourceVersionRow, Uuid } from '../types/api.ts'

/** Hva kommandoen trenger av databasen, som en injiserbar grenseflate. */
export interface EditorCatalogApi {
  listSources(): Promise<readonly EditorSourceRow[]>
  listSourceVersions(sourceId: Uuid): Promise<readonly EditorSourceVersionRow[]>
  createSourceVersionFromDocument(input: DocumentVersionInput): Promise<Uuid>
  buildAssignment(input: BuildAssignmentInput): Promise<unknown>
}

export interface DocumentVersionInput {
  readonly sourceId: Uuid
  readonly retrievedAt: string
  readonly retrievedFrom: string
  readonly documentBase64: string
  readonly extractedText: string
  readonly representation: string
  readonly recipe: TextExtractionRecipe
  readonly externalVersion: string | null
}

export interface BuildAssignmentInput {
  readonly sourceVersionId: Uuid
  readonly drugs: readonly string[]
  readonly outcomes: readonly string[]
  readonly populations: readonly string[]
}

/** Katalogen kommandoen leter i, og hva den fant. */
export interface SourceMatch {
  readonly source: EditorSourceRow
}

function describeSource(row: EditorSourceRow): string {
  return `${row.title} — ${row.authors_or_issuer}`
}

/**
 * Finner nøyaktig én kilde av et fritekstsøk, eller sier hvorfor ikke.
 *
 * Søket går mot tittelen og forfatterne, ufølsomt for store og små bokstaver.
 * Treffer det flere, avvises det med hele listen: hvilken artikkel en
 * ekstraksjon gjelder, er ikke noe en kommando skal gjette.
 */
export function matchSource(
  sources: readonly EditorSourceRow[],
  query: string,
): { readonly source: EditorSourceRow } | { readonly error: string } {
  const needle = query.trim().toLowerCase()
  if (needle.length === 0) {
    return { error: 'Søket etter kilde er tomt.' }
  }
  const hits = sources.filter(
    (row) =>
      row.title.toLowerCase().includes(needle) ||
      row.authors_or_issuer.toLowerCase().includes(needle),
  )
  if (hits.length === 0) {
    return {
      error:
        `Fant ingen kilde som stemmer med «${query}». Registrerte kilder:\n` +
        sources.map((row) => `  - ${describeSource(row)}`).join('\n'),
    }
  }
  if (hits.length > 1) {
    return {
      error:
        `«${query}» treffer ${String(hits.length)} kilder:\n` +
        hits.map((row) => `  - ${describeSource(row)}`).join('\n') +
        '\nGjør søket mer presist. Hvilken artikkel et oppdrag gjelder, skal ikke gjettes.',
    }
  }
  return { source: hits[0] as EditorSourceRow }
}

/**
 * Velger kildeversjonen et oppdrag skal gjelde.
 *
 * Den nyeste av dem som har den representasjonstypen kalleren ba om. Uten et
 * ønske: den nyeste med et fingeravtrykk i det hele tatt. En versjon uten
 * `content_hash` velges aldri — den er ikke en etterprøvbar representasjon
 * (MVP_IMPLEMENTATION_PLAN.md §74.32) — og en versjon uten representasjonstype
 * heller ikke, siden en agentekstraksjon ikke kan bygge på den.
 */
export function chooseSourceVersion(
  versions: readonly EditorSourceVersionRow[],
  representation: string | null,
): { readonly version: EditorSourceVersionRow } | { readonly error: string } {
  const usable = versions.filter((row) => row.content_hash !== null && row.representation !== null)
  const wanted =
    representation === null ? usable : usable.filter((row) => row.representation === representation)
  const newest = [...wanted].sort((a, b) => b.retrieved_at.localeCompare(a.retrieved_at))[0]
  if (newest === undefined) {
    const what = representation === null ? 'noen brukbar kildeversjon' : `en ${representation}`
    return {
      error:
        `Kilden har ikke ${what} med både fingeravtrykk og representasjonstype. ` +
        `Registrerte versjoner: ${
          versions.length === 0
            ? 'ingen'
            : versions
                .map(
                  (row) =>
                    `${row.representation ?? 'uten representasjonstype'} fra ${row.retrieved_at}`,
                )
                .join(', ')
        }. Oppgi --pdf for å registrere fullteksten fra originaldokumentet.`,
    }
  }
  return { version: newest }
}

export interface AssignmentBuildOptions {
  readonly catalog: EditorCatalogApi
  /** Fritekstsøket etter kilden: en del av tittelen eller en forfatter. */
  readonly sourceQuery: string
  /** Originaldokumentet, når en ny kildeversjon skal registreres av det. */
  readonly documentPath?: string
  /**
   * Representasjonstypen.
   *
   * Med `--pdf`: hva den registrerte versjonen blir. Uten: hvilken av de
   * registrerte versjonene oppdraget skal gjelde. Standardverdien er
   * `full_text` i det første tilfellet, fordi det er hele grunnen til at noen
   * oppgir en original-PDF — og ingen standardverdi i det andre.
   */
  readonly representation?: string
  /** Adressen dokumentet ble hentet fra, for eksempel artikkelens DOI-adresse. */
  readonly retrievedFrom?: string
  readonly externalVersion?: string | null
  readonly drugs: readonly string[]
  readonly outcomes: readonly string[]
  readonly populations: readonly string[]
  /** Katalogen originaldokumentene ligger i, addressert på fingeravtrykk. */
  readonly documentStore?: string
  readonly now?: () => string
  readonly runTool?: RunTool
  readonly log?: (line: string) => void
}

export interface AssignmentBuildReport {
  readonly assignment: ExtractionAssignment
  /** Oppdraget slik det skrives til fil, ordrett som databasen svarte. */
  readonly json: unknown
  readonly source: EditorSourceRow
  readonly sourceVersionId: Uuid
  readonly representation: string
  /** `registered` når en ny kildeversjon ble skrevet, `reused` når en fantes. */
  readonly versionOutcome: 'registered' | 'reused' | 'selected'
  /** Dokumentet, når oppdraget gjelder en dokumentutledet versjon. */
  readonly document?: { readonly digest: string; readonly storedAt: string | null }
}

/**
 * Legger originaldokumentet i lageret, under fingeravtrykket sitt.
 *
 * Filnavnet er fingeravtrykket, men **innholdet** er fasiten: oppslaget senere
 * hasher bytene og bryr seg ikke om navnet (`documentsIn`). En fil som ligger
 * der fra før, gjenbrukes derfor bare når bytene faktisk er dokumentets — ellers
 * skrives den på nytt. Uten den kontrollen ville en avbrutt skriving etterlatt
 * en halv fil under riktig navn, kommandoen ville meldt at alt gikk bra, og
 * hvert eneste ledd videre ville stanset med «fant ingen fil».
 *
 * Skrivingen går via en midlertidig fil og `rename`, som er atomisk innenfor
 * samme filsystem: en avbrutt kjøring etterlater da en `.tmp`-fil med et navn
 * oppslaget ikke bryr seg om, aldri en halv fil under fingeravtrykket.
 */
async function storeDocument(document: LoadedDocument, directory: string): Promise<string> {
  await mkdir(directory, { recursive: true })
  const path = join(directory, `${document.digest.replace('sha256:', '')}.pdf`)
  try {
    if ((await documentDigest(new Uint8Array(await readFile(path)))) === document.digest) {
      return path
    }
  } catch {
    // Filen finnes ikke, eller lot seg ikke lese. Begge deler betyr at den skal
    // skrives — og en fil som ikke lar seg lese, er ikke et dokument.
  }
  const temporary = `${path}.${String(process.pid)}.tmp`
  await writeFile(temporary, document.bytes)
  await rename(temporary, path)
  return path
}

/**
 * Registrerer fullteksten fra en original-PDF, eller gjenbruker den som finnes.
 *
 * Fingeravtrykkene beregnes to steder, og det er med hensikt: her, av
 * kommandoen, for å kunne slå opp om versjonen allerede finnes — og av
 * databasen, som det som faktisk lagres. Skulle de sprike, er det databasens
 * som gjelder, og kjeden ville sagt fra ved neste ledd.
 */
async function registerFromDocument(
  options: AssignmentBuildOptions,
  source: EditorSourceRow,
  documentPath: string,
): Promise<
  | {
      readonly sourceVersionId: Uuid
      readonly representation: string
      readonly outcome: 'registered' | 'reused'
      readonly document: LoadedDocument
    }
  | { readonly error: string }
> {
  const log = options.log ?? (() => {})
  const representation = options.representation ?? 'full_text'

  const loaded = await loadDocumentFile(documentPath)
  if (loaded.status === 'error') {
    return { error: loaded.message }
  }
  const document = loaded.document
  log(`Originaldokument ${document.path}: ${String(document.byteSize)} byte, ${document.digest}.`)

  const recipe = await currentPdfRecipe(options.runTool)
  if (recipe.status === 'error') {
    return { error: recipe.message }
  }
  const extracted = await extractDocumentText({
    bytes: document.bytes,
    recipe: recipe.recipe,
    ...(options.runTool === undefined ? {} : { run: options.runTool }),
  })
  if (extracted.status === 'error') {
    return { error: extracted.message }
  }
  log(
    `Tekstuttrekking med «${recipe.recipe.toolVersion} ${recipe.recipe.arguments}»: ` +
      `${String(extracted.extracted.text.length)} tegn, ${extracted.extracted.contentHash}.`,
  )

  // Finnes den samme teksten allerede for denne kilden, er det den samme
  // observasjonen. Databasen ville avvist dubletten; her gjenbrukes den, slik at
  // en avbrutt kjøring kan kjøres om igjen.
  //
  // Men bare når raden er bundet til **dette** dokumentet. Den samme teksten kan
  // komme av en annen PDF — den samme artikkelen fra to utgivere — eller av
  // tekstveien, uten noe dokument i det hele tatt. Gjenbrukte kommandoen raden
  // likevel, ville oppdraget pekt på den *gamle* bindingen mens lageret fikk den
  // *nye* filen, og hvert ledd videre ville stanset med «fant ingen fil» etter at
  // kommandoen hadde meldt at alt gikk bra.
  const existing = (await options.catalog.listSourceVersions(source.source_id)).find(
    (row) => row.content_hash === extracted.extracted.contentHash,
  )
  if (existing !== undefined) {
    if (existing.document_sha256 !== document.digest) {
      return {
        error:
          `Den samme teksten er allerede registrert for denne kilden, som kildeversjon ` +
          `${existing.source_version_id} — men ${
            existing.document_sha256 === null
              ? 'uten noe originaldokument (den er registrert som tekst hentet fra en adresse)'
              : `utledet av dokumentet ${existing.document_sha256}`
          }, ikke av ${document.path} (${document.digest}). En ny rad ville vært den samme ` +
          'observasjonen om igjen, og databasen ville avvist den. Bygg oppdraget av den ' +
          'registrerte versjonen med --representation framfor --pdf, eller bruk det ' +
          'dokumentet den faktisk er utledet av.',
      }
    }
    log(`Kildeversjonen er allerede registrert: ${existing.source_version_id}.`)
    return {
      sourceVersionId: existing.source_version_id,
      representation: existing.representation ?? representation,
      outcome: 'reused',
      document,
    }
  }

  const retrievedFrom = options.retrievedFrom?.trim()
  if (retrievedFrom === undefined || retrievedFrom.length === 0) {
    return {
      error:
        'Oppgi --retrieved-from: hvor originaldokumentet ble hentet fra, for eksempel ' +
        'artikkelens DOI-adresse. Fingeravtrykket identifiserer filen, men ikke hvor den ' +
        'kommer fra, og en kildeversjon uten det er ikke sporbar til en utgiver.',
    }
  }

  const sourceVersionId = await options.catalog.createSourceVersionFromDocument({
    sourceId: source.source_id,
    retrievedAt: (options.now ?? (() => new Date().toISOString()))(),
    retrievedFrom,
    // Bytene sendes, ikke fingeravtrykket: databasen skal eie hashen
    // (migrasjon 003e). Dokumentet lagres ikke.
    documentBase64: Buffer.from(document.bytes).toString('base64'),
    extractedText: extracted.extracted.text,
    representation,
    recipe: recipe.recipe,
    externalVersion: options.externalVersion ?? null,
  })
  log(`Kildeversjon registrert: ${sourceVersionId} (${representation}).`)
  return { sourceVersionId, representation, outcome: 'registered', document }
}

/**
 * Bygger oppdraget, og registrerer kildeversjonen først når en PDF er oppgitt.
 *
 * Kaster med én setning når noe ikke går: dette er en kommando et menneske
 * kjører, og enhver avvisning skal si hva som må gjøres i stedet.
 */
export async function buildAssignmentFromCatalog(
  options: AssignmentBuildOptions,
): Promise<AssignmentBuildReport> {
  const log = options.log ?? (() => {})

  const matched = matchSource(await options.catalog.listSources(), options.sourceQuery)
  if ('error' in matched) {
    throw new Error(matched.error)
  }
  const source = matched.source
  log(`Kilde: ${describeSource(source)}`)

  let sourceVersionId: Uuid
  let representation: string
  let versionOutcome: AssignmentBuildReport['versionOutcome']
  let document: LoadedDocument | null = null

  if (options.documentPath === undefined) {
    const chosen = chooseSourceVersion(
      await options.catalog.listSourceVersions(source.source_id),
      options.representation ?? null,
    )
    if ('error' in chosen) {
      throw new Error(chosen.error)
    }
    sourceVersionId = chosen.version.source_version_id
    representation = chosen.version.representation as string
    versionOutcome = 'selected'
    log(
      `Kildeversjon: ${sourceVersionId} (${representation}), hentet ${chosen.version.retrieved_at}.`,
    )
  } else {
    const registered = await registerFromDocument(options, source, options.documentPath)
    if ('error' in registered) {
      throw new Error(registered.error)
    }
    sourceVersionId = registered.sourceVersionId
    representation = registered.representation
    versionOutcome = registered.outcome
    document = registered.document
  }

  const json = await options.catalog.buildAssignment({
    sourceVersionId,
    drugs: options.drugs,
    outcomes: options.outcomes,
    populations: options.populations,
  })

  // Databasens svar leses med nøyaktig den samme strengheten som en fil noen
  // har skrevet for hånd. Kontrakten er kontrakten, og en projeksjon som en dag
  // svarer med én nøkkel for lite, skal stoppe her — ikke i modell-leddet.
  const assignment = parseExtractionAssignment(json)

  let storedAt: string | null = null
  if (document !== null && options.documentStore !== undefined) {
    storedAt = await storeDocument(document, options.documentStore)
    log(`Originaldokumentet ligger i dokumentlageret: ${storedAt}`)
  }

  return {
    assignment,
    json,
    source,
    sourceVersionId,
    representation,
    versionOutcome,
    ...(document === null ? {} : { document: { digest: document.digest, storedAt } }),
  }
}
