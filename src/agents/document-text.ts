// ============================================================================
// Fra et originaldokument til den teksten ekstraksjonen faktisk leste
//
// En PDF er ikke tekst. Skal en ekstraksjon kunne kontrolleres ordrett mot
// kilden, må det finnes en tekstrepresentasjon — og skal *den* være
// etterprøvbar, må den kunne lages om igjen av noen andre og gi nøyaktig de
// samme bytene (ANTIDEP_CONSTITUTION.md §11, EVIDENCE_PIPELINE.md §13, §19).
//
// ----------------------------------------------------------------------------
// Oppskriften er proveniensen
//
// Tekstuttrekking er ikke én operasjon: to verktøy gir to forskjellige tekster
// av den samme PDF-en, og det samme verktøyet gir forskjellig tekst med
// forskjellige valg. En kildeversjon som bare sa «tekst hentet ut av en PDF»,
// ville derfor ikke kunnet reproduseres i det hele tatt.
//
// Kildeversjonen bærer derfor **oppskriften**: verktøyet, versjonen av det,
// argumentene ordrett (migrasjon 003e) og Antideps egen etterbehandling av
// verktøyets utdata med versjon (migrasjon 003g). Den som vil etterprøve, kjører
// den samme kommandoen på det samme dokumentet, gjør den samme etterbehandlingen
// og sammenligner sha256 av resultatet med `content_hash`.
//
// ----------------------------------------------------------------------------
// Hvorfor det er en etterbehandling i det hele tatt
//
// `pdftotext -layout` gjenskaper den fysiske plasseringen på papiret. I en
// tospaltet artikkel legger den dermed venstre og høyre spalte ved siden av
// hverandre på den samme tekstlinjen, og Antideps ordrette kontroll — som
// normaliserer blanktegn før den søker — kunne lese to uavhengige spalter som én
// sammenhengende setning. Det er en evidensintegritetsfeil (issue #84).
//
// Oppskriften henter derfor **posisjonsdata** (`-bbox-layout`), og Antideps eget
// deterministiske ledd (`reading-order.ts`) bygger den logiske leserekkefølgen av
// dem — eller nekter, når rekkefølgen ikke er gitt av oppsettet. Etterbehandlingen
// er ren: den flytter blokker, og skriver ikke ett eneste tegn.
//
// ----------------------------------------------------------------------------
// Oppskriften er en lukket liste
//
// Oppskriften er den ene registrerte verdien som senere blir en **prosess**.
// Var den fri, ville en verdi lest ut av basen kunnet bli en kommando kjørt med
// rettighetene til den som kontrollerer — kodekjøring ut av en skriverettighet.
// Listen står i `document-binding.ts` og har i dag to rader: den nye
// oppskriften, og den hver eldre dokumentutledet rad allerede bærer. Den
// håndheves ved databasegrensen (migrasjon 003f, utvidet i 003g) og på nytt her,
// umiddelbart før prosessen startes: en oppskrift utenfor listen gir en
// avvisning uten at verktøyet i det hele tatt blir kalt.
//
// ----------------------------------------------------------------------------
// Hvorfor versjonen ikke er et krav, men en opplysning
//
// Kjøringen nekter *ikke* å kjøre fordi den installerte versjonen er en annen
// enn den registrerte. Fasiten er fingeravtrykket: gir en annen versjon
// nøyaktig den samme teksten, er teksten den samme, og en avvisning ville vært
// en formalitet uten innhold. Gir den en annen tekst, stemmer ikke hashen, og
// da sier avvisningen hvilke to versjoner det gjelder — som er den
// opplysningen som faktisk hjelper.
//
// ----------------------------------------------------------------------------
// Hvorfor et eksternt verktøy og ikke et bibliotek
//
// Modell-leddet skal ikke ha en eneste tredjepartsavhengighet i importgrafen
// (`drafting-no-write-path.test.ts`), og en PDF-parser skrevet her ville vært
// et stykke sikkerhetskritisk kode som leser utrygg inndata. `pdftotext` fra
// poppler er dessuten det verktøyet en utenforstående faktisk har for hånden
// når hen skal etterprøve — og det er poenget med en reproduserbar oppskrift.
//
// Utrygg inndata: dokumentet er data. Bytene sendes til verktøyet på stdin, og
// ingen del av dem blir noen gang et argument på en kommandolinje.
// ============================================================================

import { execFile } from 'node:child_process'

import { sourceVersionContentHash } from './content-hash.ts'
import {
  disallowedRecipeReason,
  PDF_TEXT_ARGUMENTS,
  PDF_TEXT_TOOL,
  PDF_TEXT_TRANSFORM,
  type TextExtractionRecipe,
} from './document-binding.ts'
import { reconstructReadingOrder } from './reading-order.ts'

export type { TextExtractionRecipe }

// Oppskriften Antidep kjører, og kontrollen av den, hører til formen og ligger
// derfor i `document-binding.ts` — den modulen har ingen Node-avhengighet, og
// den samme lukkede listen leses også der ingen prosess kan startes.
export { disallowedRecipeReason, PDF_TEXT_ARGUMENTS, PDF_TEXT_TOOL, PDF_TEXT_TRANSFORM }

/** Hvor lenge tekstuttrekkingen får holde på før den regnes som mislykket. */
const EXTRACTION_TIMEOUT_MS = 120_000

/**
 * Hvor mye tekst ett dokument får gi.
 *
 * En fulltekstartikkel er noen hundre kilobyte. Grensen finnes for at et
 * dokument som ikke er det — et innskannet bind, en fil som er noe annet enn
 * den utgir seg for — ikke skal kunne fylle minnet til en kjøring.
 */
const MAX_TEXT_BYTES = 32 * 1024 * 1024

/**
 * Ett kall til et eksternt verktøy, beskrevet slik kalleren kan bedømme det.
 *
 * `failed` er bare for det som skjedde *utenfor* verktøyet — det finnes ikke,
 * det kunne ikke startes, det ble avbrutt. Alt verktøyet selv sier, også når
 * det avslutter med en feilkode, er et `ran`: `pdftotext -v` avslutter med kode
 * 99 og skriver versjonen på stderr, og en grenseflate som kalte det en feil,
 * ville gjort den ene opplysningen vi ba om, utilgjengelig.
 */
export type ToolRun =
  | {
      readonly status: 'ran'
      readonly exitCode: number
      readonly stdout: string
      readonly stderr: string
    }
  | { readonly status: 'failed'; readonly message: string }

/**
 * Kjøringen av det eksterne verktøyet, som en injiserbar grenseflate.
 *
 * Finnes for at hvert ledd som trenger tekst ut av et dokument, skal kunne
 * prøves uten poppler installert — og for at en prøve skal kunne beskrive
 * nøyaktig hva verktøyet svarte, også når det svarte noe galt.
 */
export type RunTool = (
  tool: string,
  args: readonly string[],
  stdin?: Uint8Array,
) => Promise<ToolRun>

function decode(bytes: Buffer): string {
  return new TextDecoder('utf-8', { fatal: false, ignoreBOM: true }).decode(bytes)
}

/** Kjører et verktøy, og lar aldri en feil nå kalleren som et kastet unntak. */
export const runToolWithNode: RunTool = (tool, args, stdin) =>
  new Promise<ToolRun>((resolve) => {
    const child = execFile(
      tool,
      [...args],
      { timeout: EXTRACTION_TIMEOUT_MS, maxBuffer: MAX_TEXT_BYTES, encoding: 'buffer' },
      (error, stdout, stderr) => {
        if (error !== null && typeof error.code === 'string') {
          // En streng i `code` er operativsystemets egen feil — ENOENT når
          // verktøyet ikke finnes, ETIMEDOUT når det ble avbrutt. En tallkode
          // er verktøyets egen exit-kode, og den er et svar.
          resolve({
            status: 'failed',
            message:
              `${tool} kunne ikke kjøres (${error.code}). Er poppler installert? ` +
              '(Debian/Ubuntu: apt-get install poppler-utils. macOS: brew install poppler.)',
          })
          return
        }
        resolve({
          status: 'ran',
          exitCode: typeof error?.code === 'number' ? error.code : 0,
          stdout: decode(stdout),
          stderr: decode(stderr),
        })
      },
    )
    if (stdin !== undefined) {
      child.stdin?.on('error', () => {
        // Verktøyet kan ha avsluttet før alt er skrevet. Feilen som betyr noe,
        // er den fra kjøringen selv, og den håndteres over.
      })
      child.stdin?.end(stdin)
    }
  })

export type VersionResult =
  | { readonly status: 'ok'; readonly version: string }
  | { readonly status: 'error'; readonly message: string }

/** Leser versjonen verktøyet selv oppgir, slik den registreres. */
export async function readToolVersion(
  tool: string = PDF_TEXT_TOOL,
  run: RunTool = runToolWithNode,
): Promise<VersionResult> {
  if (tool !== PDF_TEXT_TOOL) {
    // Også versjonsavlesningen starter en prosess på et verktøynavn, og et
    // navn utenfor listen skal ikke bli en kommando her heller.
    return {
      status: 'error',
      message: `Antidep leser bare versjonen av «${PDF_TEXT_TOOL}», ikke av ${JSON.stringify(tool)}.`,
    }
  }
  const result = await run(tool, ['-v'])
  if (result.status === 'failed') {
    return { status: 'error', message: result.message }
  }
  // Versjonen står på stderr for poppler og på stdout for enkelte bygg. Begge
  // leses, framfor å gjøre kontrollen avhengig av hvilken strøm et bygg valgte.
  const match = /pdftotext version ([^\s]+)/.exec(`${result.stderr}\n${result.stdout}`)
  if (match?.[1] === undefined) {
    return {
      status: 'error',
      message:
        `Klarte ikke å lese versjonen av ${tool}. Uten den kan tekstuttrekkingen ikke ` +
        'registreres med en proveniens noen kan etterprøve.',
    }
  }
  return { status: 'ok', version: `${tool} ${match[1]}` }
}

export interface ExtractedText {
  readonly text: string
  readonly contentHash: string
  readonly recipe: TextExtractionRecipe
}

export type ExtractionResult =
  | { readonly status: 'ok'; readonly extracted: ExtractedText }
  | { readonly status: 'error'; readonly message: string }

/**
 * Deler argumentstrengen slik den skal sendes til verktøyet.
 *
 * Bevisst enkel: argumentene er kontrollert mot den lukkede listen før dette
 * kalles, så strengen er nøyaktig `PDF_TEXT_ARGUMENTS` og splittingen gir
 * nøyaktig de leddene den består av. Ingen del av den går gjennom et skall, og
 * ingen del av dokumentet blir noen gang et argument.
 */
export function recipeArguments(recipe: TextExtractionRecipe): readonly string[] {
  return recipe.arguments.split(/\s+/).filter((argument) => argument.length > 0)
}

/**
 * Kjører oppskriften på dokumentet og gir teksten med sitt fingeravtrykk.
 *
 * Dokumentet sendes på stdin og resultatet leses av stdout, slik at ingen
 * midlertidig kopi av en opphavsrettslig beskyttet fulltekst blir liggende
 * igjen på disk (EVIDENCE_PIPELINE.md §14).
 */
export async function extractDocumentText(options: {
  readonly bytes: Uint8Array
  readonly recipe: TextExtractionRecipe
  readonly run?: RunTool
}): Promise<ExtractionResult> {
  // Kontrollen står her, og ikke bare ved databasegrensen, fordi det er her
  // en registrert verdi ville blitt en prosess. `run` er ikke kalt ennå, og
  // skal ikke bli det: en oppskrift utenfor listen er ikke noe å prøve.
  const disallowed = disallowedRecipeReason(options.recipe)
  if (disallowed !== null) {
    return { status: 'error', message: disallowed }
  }
  const run = options.run ?? runToolWithNode
  const args = [...recipeArguments(options.recipe), '-', '-']
  const result = await run(options.recipe.tool, args, options.bytes)
  if (result.status === 'failed') {
    return { status: 'error', message: result.message }
  }
  if (result.exitCode !== 0) {
    return {
      status: 'error',
      message:
        `${options.recipe.tool} avsluttet med kode ${String(result.exitCode)} og fikk ingen ` +
        `brukbar tekst ut av dokumentet: ${result.stderr.trim()}`,
    }
  }
  if (result.stdout.trim().length === 0) {
    return {
      status: 'error',
      message:
        `${options.recipe.tool} ga ingen tekst av dokumentet. En innskannet PDF uten tekstlag ` +
        'kan ikke bære en ordrett kontroll, og en tom representasjon er ikke en fulltekst.',
    }
  }

  // Etterbehandlingen. `transform` er kontrollert mot den lukkede listen over,
  // så verdien her er enten den ene Antidep har, eller ingen — og «ingen» betyr
  // at teksten er verktøyets utdata ordrett, som er det hver kildeversjon
  // registrert før migrasjon 003g bærer.
  let text = result.stdout
  if (options.recipe.transform === PDF_TEXT_TRANSFORM) {
    const ordered = reconstructReadingOrder(result.stdout)
    if (ordered.status === 'rejected') {
      return {
        status: 'error',
        message:
          `Dokumentet er ikke trygt ekstraherbart: ${ordered.message} Ekstraksjonen stopper her. ` +
          'En tekst med en gjettet leserekkefølge ville vært verre enn ingen tekst: kliniske ' +
          'opplysninger kunne blitt tilskrevet feil arm, feil studie eller feil endepunkt.',
      }
    }
    text = ordered.text
  }

  return {
    status: 'ok',
    extracted: {
      text,
      contentHash: await sourceVersionContentHash(text),
      recipe: options.recipe,
    },
  }
}

/**
 * Oppskriften Antidep bruker i dag, med versjonen lest av verktøyet som
 * faktisk er installert.
 *
 * Brukes når en **ny** kildeversjon registreres. Ved etterprøving brukes
 * derimot den registrerte oppskriften, ikke denne: kontrollen skal gjenta det
 * som ble gjort, ikke det som gjøres nå.
 */
export async function currentPdfRecipe(
  run: RunTool = runToolWithNode,
): Promise<
  | { readonly status: 'ok'; readonly recipe: TextExtractionRecipe }
  | { readonly status: 'error'; readonly message: string }
> {
  const version = await readToolVersion(PDF_TEXT_TOOL, run)
  if (version.status === 'error') {
    return version
  }
  return {
    status: 'ok',
    recipe: {
      tool: PDF_TEXT_TOOL,
      toolVersion: version.version,
      arguments: PDF_TEXT_ARGUMENTS,
      transform: PDF_TEXT_TRANSFORM,
    },
  }
}
