// ============================================================================
// Antideps egen tekstuttrekker
//
// Redaktøren velger riktig PDF i fulltekstinnboksen. Alt etter det er Antideps
// arbeid, og dette er leddet som faktisk gjør det: henter én opplastet fil,
// kjører den registrerte oppskriften — `pdftotext` med den låste argumentlisten
// og Antideps leserekkefølge — og leverer teksten tilbake.
//
// ----------------------------------------------------------------------------
// Hvorfor dette ikke er en menneskeoppgave
//
// Oppskriften kjøres på nytt ved hver etterprøving, og en nettleser kan ikke
// kjøre den. Før issue #99 var konsekvensen at et menneske måtte ha artikkelen
// liggende lokalt og kjøre `npm run editor:assignment -- --pdf …` selv. Nå er
// det denne kommandoen som gjør det, planlagt, uten noen i transporten.
//
// Kommandoen er teknisk drift og ingen produktflate. Den hører sammen med
// deployen, ikke med redaksjonen (AGENTS.md).
//
// ----------------------------------------------------------------------------
// Ingen faglig avgjørelse tas her
//
// Om filen faktisk *er* artikkelen, om teksten lar seg lese, og om
// kildeversjonen kan registreres, avgjøres av databasen i
// `api.complete_full_text_extraction(...)`. Denne kommandoen leverer bare
// teksten oppskriften ga, og rapporterer hva databasen svarte. Et ledd som
// hadde tatt den avgjørelsen her, ville vært en kontroll utenfor den
// kontrollerte skriveveien (ANTIDEP_CONSTITUTION.md regel 7).
//
// ----------------------------------------------------------------------------
// Utrygg inndata
//
// Dokumentet er data, aldri instruksjoner. Bytene går på stdin til verktøyet og
// blir aldri et argument, og teksten som kommer ut, går rett videre til
// databasen uten å bli tolket av noe her.
// ============================================================================

import { currentPdfRecipe, extractDocumentText, type RunTool } from '../agents/document-text.ts'
import { asText, fieldsOf, raw, type Fields } from '../agents/strict-fields.ts'

const SUBJECT = 'Uttrekksoppdraget'

/** Hva kommandoen trenger av databasen, som en injiserbar grenseflate. */
export interface FullTextIntakeApi {
  claim(leaseSeconds: number): Promise<unknown>
  complete(handle: string, extractedText: string, toolVersion: string): Promise<unknown>
  fail(handle: string, stage: FailureStage): Promise<unknown>
  /** Setter i gang igjen alt som sto blokkert på et driftsproblem. */
  resume(): Promise<unknown>
}

/**
 * De to stopppunktene databasen kjenner. Lukket: Antidep skriver setningen.
 *
 * Skillet mellom dem er ikke en nyanse — det avgjør om filen blir liggende
 * eller om et menneske blir bedt om en ny:
 *
 *   tool_missing  verktøyet fantes ikke. Da vet kommandoen ingenting om filen,
 *                 og databasen blokkerer raden med filen i behold.
 *   tool_failed   verktøyet kjørte og fikk ingenting brukbart ut av nettopp
 *                 denne filen. Det er en opplysning om filen, og den telles.
 *
 * Det finnes ikke et tredje for «ga ingen tekst». `extractDocumentText` avviser
 * allerede en PDF uten tekstlag og en tekst uten avgjort leserekkefølge, og
 * begge kommer hit som `tool_failed`. En egen kode for noe kommandoen ikke kan
 * skille fra utsiden, ville vært en opplysning som så presis ut uten å være
 * det (ANTIDEP_CONSTITUTION.md regel 4).
 */
export type FailureStage = 'tool_missing' | 'tool_failed'

export type ClaimedTask =
  | { readonly available: false }
  | {
      readonly available: true
      readonly handle: string
      readonly reference: string
      readonly documentBase64: string
    }

export function parseClaimedTask(value: unknown): ClaimedTask {
  const fields = fieldsOf(value, SUBJECT, 'svaret')
  const available = raw(fields, 'available')
  if (typeof available !== 'boolean') {
    throw new Error(`${SUBJECT} er ugyldig: svaret.available er ikke en boolsk verdi.`)
  }
  if (!available) {
    return { available: false }
  }
  return {
    available: true,
    handle: asText(fields, 'handle'),
    reference: asText(fields, 'reference'),
    documentBase64: asText(fields, 'document_base64'),
  }
}

/** Hva databasen gjorde med teksten. Ingen av utfallene er en feil her. */
export interface CompletionOutcome {
  readonly status: 'registered' | 'rejected'
  readonly rejection: string | null
}

function optional(fields: Fields, key: string): string | null {
  const value = raw(fields, key)
  if (value === null || value === undefined) {
    return null
  }
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`Uttrekkssvaret er ugyldig: svaret.${key} er ikke en tekst.`)
  }
  return value
}

export function parseCompletionOutcome(value: unknown): CompletionOutcome {
  const fields = fieldsOf(value, 'Uttrekkssvaret', 'svaret')
  const status = asText(fields, 'status')
  if (status !== 'registered' && status !== 'rejected') {
    throw new Error('Uttrekkssvaret er ugyldig: svaret.status er ukjent.')
  }
  return { status, rejection: optional(fields, 'rejection') }
}

/** Hvor mange rader som ble satt i gang igjen. Lest med samme strenghet som resten. */
export function parseResumedCount(value: unknown): number {
  const fields = fieldsOf(value, 'Gjenopptakelsen', 'svaret')
  const resumed = raw(fields, 'resumed')
  if (typeof resumed !== 'number' || !Number.isInteger(resumed) || resumed < 0) {
    throw new Error('Gjenopptakelsen er ugyldig: svaret.resumed er ikke et antall.')
  }
  return resumed
}

/** Hva én kjøring faktisk gjorde. Tallene er det kommandoen rapporterer. */
export interface WorkerReport {
  readonly resumed: number
  readonly claimed: number
  readonly registered: number
  readonly rejected: number
  /** Filer verktøyet leste uten å få brukbar tekst ut av. Prøves igjen. */
  readonly retried: number
  /** Filer som ble liggende fordi verktøyet manglet. Ingen blir bedt om noe. */
  readonly blocked: number
}

export interface WorkerOptions {
  readonly api: FullTextIntakeApi
  /** Hvor mange oppdrag én kjøring tar. Kjøringen er planlagt, ikke evig. */
  readonly maxTasks?: number
  readonly leaseSeconds?: number
  readonly runTool?: RunTool
  readonly log?: (line: string) => void
  /**
   * Om den rå årsaken fra verktøyet skal med i loggen.
   *
   * Av som standard, og det er en sikkerhetsgrense og ikke en smakssak:
   * kjøringen er planlagt i et offentlig repo, der loggen er offentlig. En rå
   * feiltekst fra `pdftotext` kan bære deler av dokumentet, og den kontrollerte
   * kildeteksten skal aldri havne i en logg (AGENTS.md). Den som feilsøker
   * lokalt, slår den på selv.
   */
  readonly diagnostics?: boolean
}

/**
 * Tar oppdrag til køen er tom, eller til grensen er nådd.
 *
 * Grensen finnes for at en planlagt kjøring skal være en kjøring og ikke en
 * tjeneste: en kommando uten tak ville blitt stående og holde leier i det
 * uendelige om databasen svarte feil.
 */
export async function runFullTextWorker(options: WorkerOptions): Promise<WorkerReport> {
  const log = options.log ?? (() => {})
  const maxTasks = options.maxTasks ?? 10
  const leaseSeconds = options.leaseSeconds ?? 600

  let resumed = 0
  let claimed = 0
  let registered = 0
  let rejected = 0
  let retried = 0
  let blocked = 0

  // Oppskriften leses én gang, av verktøyet som faktisk er installert.
  // Verktøyet og argumentene er Antideps, og kontrolleres mot den lukkede
  // listen inne i `extractDocumentText`; versjonen er en opplysning og ikke
  // noe som velges.
  const recipe = await currentPdfRecipe(options.runTool)

  if (recipe.status === 'ok') {
    // Verktøyet finnes. Da er et driftsproblem som blokkerte arbeid tidligere,
    // over — og alt som sto, går i kø igjen her. Ingen blir bedt om noe, og
    // ingen fil lastes opp på nytt: dette er hele poenget med at en teknisk
    // svikt aldri ble en menneskeoppgave (issue #99).
    resumed = parseResumedCount(await options.api.resume())
    if (resumed > 0) {
      log(`${String(resumed)} fil(er) sto blokkert på et driftsproblem, og er satt i gang igjen.`)
    }
  }

  for (let taken = 0; taken < maxTasks; taken += 1) {
    const task = parseClaimedTask(await options.api.claim(leaseSeconds))
    if (!task.available) {
      break
    }
    claimed += 1

    if (recipe.status === 'error') {
      await options.api.fail(task.handle, 'tool_missing')
      blocked += 1
      log(
        'Tekstuttrekkeren fant ikke verktøyet oppskriften krever. Filen blir liggende, og ' +
          'arbeidet fortsetter av seg selv når verktøyet er på plass. Meldt som teknisk problem.',
      )
      // Uten verktøyet er neste oppdrag like umulig. Kjøringen stopper framfor
      // å blokkere hele innboksen på det samme.
      break
    }

    const bytes = Uint8Array.from(Buffer.from(task.documentBase64, 'base64'))
    const extracted = await extractDocumentText({
      bytes,
      recipe: recipe.recipe,
      ...(options.runTool === undefined ? {} : { run: options.runTool }),
    })

    if (extracted.status === 'error') {
      await options.api.fail(task.handle, 'tool_failed')
      retried += 1
      // Den rå årsaken går aldri inn i databasen, og ikke i en offentlig logg:
      // et spor skal ikke bli et sted en videreformidlet feiltekst kan bære et
      // filnavn eller en del av dokumentet. Den som feilsøker lokalt, ber om
      // den selv.
      log(
        options.diagnostics === true
          ? `Oppskriften ga ingen brukbar tekst: ${extracted.message}`
          : 'Oppskriften ga ingen brukbar tekst av filen. Den prøves igjen.',
      )
      continue
    }

    const outcome = parseCompletionOutcome(
      await options.api.complete(task.handle, extracted.extracted.text, recipe.recipe.toolVersion),
    )
    if (outcome.status === 'registered') {
      registered += 1
      log('Fulltekst registrert, og neste ledd lagt i køen.')
    } else {
      rejected += 1
      log(`Filen kunne ikke brukes (${outcome.rejection ?? 'uten oppgitt grunn'}).`)
    }
  }

  return { resumed, claimed, registered, rejected, retried, blocked }
}

/** Én setning om hva kjøringen gjorde, til den som planla den. */
export function describeWorkerReport(report: WorkerReport): string {
  if (report.claimed === 0) {
    return report.resumed === 0
      ? 'Ingen fulltekst ventet på tekstuttrekk.'
      : `${String(report.resumed)} fil(er) satt i gang igjen. Ingen ble behandlet i denne kjøringen.`
  }
  return (
    `${String(report.claimed)} fil(er) behandlet: ${String(report.registered)} registrert, ` +
    `${String(report.rejected)} avvist, ${String(report.retried)} prøves igjen, ` +
    `${String(report.blocked)} venter på at driften rettes.`
  )
}
