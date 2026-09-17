// ============================================================================
// Antideps egne deterministiske kontroller, kjørt planlagt
//
// Ekstraksjonskontrollen og kildestøttekontrollen er Antideps egen kode, og de
// har alltid vært det. Det som manglet, var at noen kjørte dem: et registrert
// agentsvar la ikke kontrollen i gang av seg selv, og kjeden sto stille til et
// menneske åpnet et terminalvindu (issue #101).
//
// Fra migrasjon 012b legger databasen selv kontrollen i køen — en vanlig
// `workflow.pipeline_jobs`-rad i kontrolleddets egen rolle, med leie,
// forsøkstelling og append-only spor som alt annet arbeid. Denne kommandoen er
// den som tar den ut og gjør arbeidet.
//
// ----------------------------------------------------------------------------
// Hvorfor dette er en kommando og ikke en databasefunksjon
//
// Kontrollene er flere tusen linjer deterministisk TypeScript: ordrette søk i
// artikkelteksten, tallsammenligninger med enhet og fortegn, og hele
// konfidensintervall-logikken. En SQL-kopi av dem ville vært en andre
// implementasjon av den ene tingen som skal være uomtvistelig — og den dagen de
// to var uenige, ville ingen visst hvilken som gjaldt.
//
// Kjøringen er derfor teknisk drift, som tekstuttrekket: en tidsplan, en maskin
// og ingen i transporten (`.github/workflows/deterministic-controls.yml`).
// Selve *overgangen* — at kontrollen skal kjøres — er databasens egen og ikke
// kjøreplanens. Uten en kjøring står arbeidet i kø; det blir aldri borte, og det
// blir aldri en menneskeoppgave.
//
// ----------------------------------------------------------------------------
// Hvorfor hvert ledd har sin egen legitimasjon
//
// Rollen er rettighetsgrensen. Ekstraksjonskontrollen og kildestøttekontrollen
// deler verken aktør, identitet eller hemmelighet, og en kjøring i det ene
// leddet kan ikke utføre operasjonene i det andre. Kommandoen kjører begge, men
// med hver sin legitimasjon — den slår dem ikke sammen
// (ANTIDEP_CONSTITUTION.md regel 3).
//
// ----------------------------------------------------------------------------
// Hva som skjer når kontrollen ikke kan konkludere
//
// En kontroll som *konkluderte* — `verified`, `needs_correction`, `rejected`
// eller `uncertain` — har gjort jobben sin, og uttaket meldes fullført. En
// kontroll som ikke fikk se kilden i det hele tatt, har ikke det: uttaket meldes
// mislykket med begrunnelsen, jobben går tilbake i køen, og først når forsøkene
// er brukt opp blir den stående som stoppet arbeid — synlig i den åpne
// oversikten og i den tekniske problemoversikten, og aldri som en ny oppgave til
// et menneske (ANTIDEP_CONSTITUTION.md regel 4).
//
// ----------------------------------------------------------------------------
// Utrygg inndata
//
// Kildeteksten kontrollen leser, er data og aldri instruksjoner. Den brukes bare
// som høystakk for ordrette søk, og den skrives aldri til loggen: kjøringen er
// planlagt i et offentlig repo.
// ============================================================================

import type { ClaimedJob, PipelineJobApi } from '../agents/pipeline-job.ts'
import type { Uuid } from '../types/api.ts'

/** Hva ett uttak endte med, sett fra køen. */
export interface ControlOutcome {
  readonly agentRunId: Uuid
  /**
   * Om kontrollen faktisk registrerte en rad.
   *
   * `false` betyr at den ikke fikk konkludert — ikke at den konkluderte
   * negativt. De to er forskjellige tilstander, og bare den første er stoppet
   * arbeid (ANTIDEP_CONSTITUTION.md regel 4).
   */
  readonly registered: boolean
  /** Hvorfor ingen rad ble registrert. Alltid satt når `registered` er `false`. */
  readonly reason: string | null
  /** Utfallet kontrollen kom til, når den kom til ett. */
  readonly outcome: string | null
}

/**
 * Ett kontrolledd: køen det henter fra, og arbeidet det gjør.
 *
 * Injisert framfor bygget her, slik at hele orkestreringen kan prøves uten en
 * database og uten en artikkel — og slik at de to leddene ikke kan komme til å
 * dele legitimasjon ved et uhell.
 */
export interface ControlStep {
  /** `provenance.agent_role`. Går til køen, aldri til en logg som er offentlig. */
  readonly agentRole: string
  /** Leddet i produktets egne ord, til loggen. */
  readonly label: string
  readonly jobs: PipelineJobApi
  execute(job: ClaimedJob): Promise<ControlOutcome>
}

/** Hva én kjøring gjorde. Tallene er det kommandoen rapporterer. */
export interface ControlWorkerReport {
  /** Kjedeoverganger som ble tatt igjen fordi en tidligere kjøring ikke fikk lagt dem inn. */
  readonly resumed: number
  /** Kandidater som ble forseglet av den samme opprydningen. */
  readonly candidatesBuilt: number
  /**
   * Påstander opprydningen gjorde synlig at venter på en redaksjonell avgjørelse.
   *
   * Ikke arbeid kjøringen kan gjøre noe med — det er nettopp poenget. Uten
   * tallet ville en opprydning som fant ny kunnskap ingen visste om, vært
   * usynlig i driftsloggen.
   */
  readonly revisionReviews: number
  readonly claimed: number
  readonly completed: number
  /** Uttak der kontrollen ikke fikk konkludert. Prøves igjen. */
  readonly stalled: number
}

export interface ControlWorkerOptions {
  readonly steps: readonly ControlStep[]
  /**
   * Tar igjen de kjedeovergangene en teknisk svikt etterlot.
   *
   * Kalles én gang først i kjøringen. Den legger aldri inn noe en trigger ikke
   * ville lagt inn — den leser hva databasens egen tilstand tilsier — og den er
   * derfor trygg å gjenta.
   */
  resume(): Promise<{
    readonly queued: number
    readonly candidatesBuilt: number
    readonly revisionReviews: number
  }>
  /** Hvor mange uttak hvert ledd tar i én kjøring. */
  readonly maxTasksPerStep?: number
  readonly leaseSeconds?: number
  readonly log?: (line: string) => void
}

/**
 * Tar uttak til køen er tom, eller til grensen er nådd.
 *
 * Grensen finnes for at en planlagt kjøring skal være en kjøring og ikke en
 * tjeneste: en kommando uten tak ville blitt stående og holdt leier i det
 * uendelige om databasen svarte feil.
 */
export async function runControlWorker(
  options: ControlWorkerOptions,
): Promise<ControlWorkerReport> {
  const log = options.log ?? (() => {})
  const maxTasks = options.maxTasksPerStep ?? 10
  const leaseSeconds = options.leaseSeconds ?? 900

  // Først opprydningen. En overgang som ikke lot seg legge inn forrige gang —
  // en tapt forbindelse midt i en transaksjon — er arbeid som venter, og det
  // skal komme i køen før kjøringen begynner å tømme den.
  const resumed = await options.resume()
  if (resumed.queued > 0 || resumed.candidatesBuilt > 0) {
    log(
      `${String(resumed.queued)} stykke(r) arbeid lagt i køen på nytt, og ` +
        `${String(resumed.candidatesBuilt)} kandidat(er) forseglet.`,
    )
  }
  // Egen linje, fordi det er noe annet: dette er arbeid kjøringen ikke kan gjøre
  // noe med, men som et menneske skal ta stilling til. En opprydning som fant
  // ny kunnskap ingen visste om, skal ikke være usynlig i driftsloggen.
  if (resumed.revisionReviews > 0) {
    log(
      `${String(resumed.revisionReviews)} påstand(er) venter nå på at en redaktør ` +
        'avgjør om ny forskning skal inn i dem.',
    )
  }

  let claimed = 0
  let completed = 0
  let stalled = 0

  for (const step of options.steps) {
    for (let taken = 0; taken < maxTasks; taken += 1) {
      const claim = await step.jobs.claim(step.agentRole, leaseSeconds)
      if (!claim.claimed) {
        break
      }
      claimed += 1

      let outcome: ControlOutcome
      try {
        outcome = await step.execute(claim.job)
      } catch (cause) {
        // Et uttak som ble tatt og aldri meldt, ville blitt stående til leien
        // løp ut — og begrunnelsen, den ene opplysningen som forklarer hva som
        // skjedde, ville vært borte. Feilen meldes derfor først, og kastes
        // videre etterpå: kalleren skal vite at den skjedde.
        const reason = cause instanceof Error ? cause.message : String(cause)
        await step.jobs.fail(claim.job.pipelineJobId, claim.job.leaseToken, reason)
        throw cause
      }

      if (!outcome.registered) {
        const report = await step.jobs.fail(
          claim.job.pipelineJobId,
          claim.job.leaseToken,
          outcome.reason ?? 'Kontrollen konkluderte ikke, og oppga ingen grunn.',
        )
        stalled += 1
        log(
          report.willRetry
            ? `${step.label}: kontrollen fikk ikke konkludert. Arbeidet prøves igjen.`
            : `${step.label}: kontrollen fikk ikke konkludert, og forsøkene er brukt opp. ` +
                'Arbeidet blir stående, og er meldt som et teknisk problem.',
        )
        continue
      }

      await step.jobs.complete(claim.job.pipelineJobId, claim.job.leaseToken, outcome.agentRunId)
      completed += 1
      log(`${step.label}: kontrollen er registrert.`)
    }
  }

  return {
    resumed: resumed.queued,
    candidatesBuilt: resumed.candidatesBuilt,
    revisionReviews: resumed.revisionReviews,
    claimed,
    completed,
    stalled,
  }
}

/** Én setning om hva kjøringen gjorde, til den som planla den. */
export function describeControlReport(report: ControlWorkerReport): string {
  if (report.claimed === 0) {
    return report.resumed === 0 && report.candidatesBuilt === 0
      ? 'Ingen kontroller ventet.'
      : `${String(report.resumed)} stykke(r) arbeid lagt i køen på nytt og ` +
          `${String(report.candidatesBuilt)} kandidat(er) forseglet. Ingen kontroller ventet.`
  }
  return (
    `${String(report.claimed)} kontroll(er) tatt: ${String(report.completed)} registrert, ` +
    `${String(report.stalled)} fikk ikke konkludert og prøves igjen.`
  )
}
