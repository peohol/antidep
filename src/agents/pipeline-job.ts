// ============================================================================
// Den varige jobbkøen, sett fra en kjører
//
// `drafting-job.ts` løser hvordan *ett* modellsteg kan deles i to kommandoer
// med en tilstand imellom. Det den ikke løser, er hvilke oppdrag som står
// igjen, hvem som holder på med hvilket akkurat nå, og hva som skjer med et
// oppdrag der kjøreren forsvant midt i. Svaret på alle tre lå i hodet på den
// som kjørte.
//
// Migrasjon 009b flyttet det inn i databasen. Denne modulen er den porten en
// kjører kjenner: ta ut ett oppdrag, gjør arbeidet, meld et utfall.
//
// ----------------------------------------------------------------------------
// Hvorfor nøkkelen utledes og ikke velges
//
// Idempotensen hviler på at den samme jobben får den samme nøkkelen hver gang.
// En nøkkel som inneholdt et tidspunkt eller et løpenummer, ville gitt to rader
// for det samme arbeidet, og en gjenopptatt orkestrering ville doblet køen.
// `jobKey` bygger den derfor av hva jobben *handler om*, og ingenting annet.
//
// ----------------------------------------------------------------------------
// Hvorfor «tom kø» ikke er en feil
//
// `api.claim_pipeline_job` svarer `{claimed: false}` når det ikke er noe å
// gjøre. En kjører som behandlet det som en feil, ville logget en feil hver
// gang alt var i orden — og da ville loggen sluttet å bety noe.
//
// ----------------------------------------------------------------------------
// Ingen orkestrering her
//
// Modulen tar ut én jobb og melder ett utfall. Den bestemmer ikke hvilke jobber
// som skal finnes, når de skal kjøres eller hva som skjer etterpå; det er
// innleggingens og kjøreplanens ansvar. En løkke her ville vært en
// arbeidsflytmotor, og det er ikke det dette er.
// ============================================================================

import { AgentApiError, type AgentClient } from './agent-api.ts'
import type { AgentCredential } from './agent-credential.ts'
import { asText, fieldsOf, problem, raw, type Fields } from './strict-fields.ts'
import type { Uuid } from '../types/api.ts'

const JOB_SUBJECT = 'Jobben'

/**
 * Nøkkelen ett stykke arbeid identifiseres av.
 *
 * `kind` sier hva slags arbeid det er, og `subject` hvilken rad det gjelder.
 * Formen er stabil og leselig, slik at en kø kan leses av et menneske uten et
 * oppslag — og deterministisk, slik at den samme jobben lagt inn to ganger er
 * én rad.
 */
export function jobKey(kind: string, subject: string): string {
  const cleanKind = kind.trim()
  const cleanSubject = subject.trim()
  if (cleanKind.length === 0 || cleanSubject.length === 0) {
    throw new Error(
      'En jobbnøkkel skal si hva jobben handler om. Både arten og subjektet må ha innhold; ' +
        'en tom del ville gjort to forskjellige oppdrag til den samme nøkkelen.',
    )
  }
  return `${cleanKind}:${cleanSubject}`
}

/** Ett oppdrag, slik kjøreren mottar det. */
export interface ClaimedJob {
  readonly pipelineJobId: Uuid
  readonly jobKey: string
  readonly agentRole: string
  readonly inputManifest: Record<string, unknown>
  readonly attempt: number
  readonly maxAttempts: number
  /**
   * Nøkkelen for nettopp dette uttaket.
   *
   * Sendes tilbake med utfallet. Agentidentiteten er per rolle og deles av alle
   * kjørere i den, så identiteten alene kan ikke skille en kjører hvis leie er
   * løpt ut, fra den som nå holder jobben — og et foreldet utfall ville ellers
   * blitt skrevet over det forsøket som faktisk arbeider.
   */
  readonly leaseToken: Uuid
  /** Begrunnelsen fra forrige mislykkede forsøk, når det var ett. */
  readonly lastFailureReason: string | null
}

export type ClaimResult =
  { readonly claimed: false } | { readonly claimed: true; readonly job: ClaimedJob }

function optionalText(fields: Fields, key: string): string | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'string') {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke tekst')
  }
  return value
}

function asPositiveInteger(fields: Fields, key: string): number {
  const value = raw(fields, key)
  if (typeof value !== 'number' || !Number.isInteger(value) || value <= 0) {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke et helt tall større enn null')
  }
  return value as number
}

/**
 * Leser svaret fra `api.claim_pipeline_job`.
 *
 * Avviser alt som ikke er kontrakten, framfor å gjette. Et svar med et manglende
 * felt ville ellers blitt til en kjøring som arbeidet på `undefined`.
 */
export function parseClaimedJob(value: unknown): ClaimResult {
  const fields = fieldsOf(value, JOB_SUBJECT, 'jobbsvaret')
  const claimed = raw(fields, 'claimed')
  if (typeof claimed !== 'boolean') {
    problem(JOB_SUBJECT, 'jobbsvaret.claimed', 'er ikke en boolsk verdi')
  }
  if (claimed !== true) {
    return { claimed: false }
  }

  const manifest = raw(fields, 'input_manifest')
  if (typeof manifest !== 'object' || manifest === null || Array.isArray(manifest)) {
    problem(JOB_SUBJECT, 'jobbsvaret.input_manifest', 'er ikke et objekt')
  }

  return {
    claimed: true,
    job: {
      pipelineJobId: asText(fields, 'pipeline_job_id') as Uuid,
      jobKey: asText(fields, 'job_key'),
      agentRole: asText(fields, 'agent_role'),
      inputManifest: manifest as Record<string, unknown>,
      attempt: asPositiveInteger(fields, 'attempt'),
      maxAttempts: asPositiveInteger(fields, 'max_attempts'),
      leaseToken: asText(fields, 'lease_token') as Uuid,
      lastFailureReason: optionalText(fields, 'last_failure_reason'),
    },
  }
}

/** Utfallet av å melde en jobb mislykket. */
export interface FailureReport {
  readonly state: string
  readonly attempts: number
  readonly maxAttempts: number
  /** `false` betyr at forsøkene er brukt opp: jobben blir stående. */
  readonly willRetry: boolean
}

export function parseFailureReport(value: unknown): FailureReport {
  const fields = fieldsOf(value, JOB_SUBJECT, 'feilsvaret')
  const willRetry = raw(fields, 'will_retry')
  if (typeof willRetry !== 'boolean') {
    problem(JOB_SUBJECT, 'feilsvaret.will_retry', 'er ikke en boolsk verdi')
  }
  return {
    state: asText(fields, 'state'),
    attempts: asPositiveInteger(fields, 'attempts'),
    maxAttempts: asPositiveInteger(fields, 'max_attempts'),
    willRetry: willRetry as boolean,
  }
}

/** De tre kallene en kjører gjør mot køen, som én grenseflate. */
export interface PipelineJobApi {
  claim(agentRole: string, leaseSeconds?: number): Promise<ClaimResult>
  /**
   * Melder et vellykket utfall.
   *
   * Idempotent i databasen: en allerede fullført jobb skriver ingenting og
   * svarer med det registrerte utfallet. En kjører som mistet svaret sitt, kan
   * derfor spørre igjen framfor å måtte gjette.
   */
  complete(
    pipelineJobId: Uuid,
    leaseToken: Uuid,
    outputManifest: Record<string, unknown>,
    agentRunId: Uuid,
  ): Promise<void>
  fail(pipelineJobId: Uuid, leaseToken: Uuid, failureReason: string): Promise<FailureReport>
}

function rejection(operation: string, error: { message: string; code?: string; details?: string }) {
  return new AgentApiError(operation, error.message, error.code ?? null, error.details ?? null)
}

export function createPipelineJobApi(
  client: AgentClient,
  credential: AgentCredential,
): PipelineJobApi {
  const auth = { p_identity_key: credential.identityKey, p_secret: credential.secret.reveal() }

  return {
    async claim(agentRole, leaseSeconds = 900) {
      const { data, error } = await client.rpc('claim_pipeline_job', {
        ...auth,
        p_agent_role: agentRole,
        p_lease_seconds: leaseSeconds,
      })
      if (error !== null) {
        throw rejection('api.claim_pipeline_job', error)
      }
      return parseClaimedJob(data)
    },

    async complete(pipelineJobId, leaseToken, outputManifest, agentRunId) {
      const { error } = await client.rpc('complete_pipeline_job', {
        ...auth,
        p_pipeline_job_id: pipelineJobId,
        p_lease_token: leaseToken,
        p_output_manifest: outputManifest,
        p_agent_run_id: agentRunId,
      })
      if (error !== null) {
        throw rejection('api.complete_pipeline_job', error)
      }
    },

    async fail(pipelineJobId, leaseToken, failureReason) {
      const { data, error } = await client.rpc('fail_pipeline_job', {
        ...auth,
        p_pipeline_job_id: pipelineJobId,
        p_lease_token: leaseToken,
        p_failure_reason: failureReason,
      })
      if (error !== null) {
        throw rejection('api.fail_pipeline_job', error)
      }
      return parseFailureReport(data)
    },
  }
}

/**
 * Tar ut én jobb, kjører arbeidet, og melder utfallet — i den rekkefølgen.
 *
 * Et kast fra arbeidet blir en meldt feil framfor et kast videre: en jobb som
 * ble tatt ut og aldri meldt, ville blitt stående til leien løp ut, og
 * begrunnelsen — den ene opplysningen som forklarer hva som skjedde — ville
 * vært borte. Feilen kastes likevel etterpå, fordi kalleren skal vite at den
 * skjedde (ANTIDEP_CONSTITUTION.md regel 4: en teknisk feil er ikke det samme
 * som at det ikke var noe å gjøre).
 */
export async function runOnePipelineJob(
  api: PipelineJobApi,
  agentRole: string,
  work: (job: ClaimedJob) => Promise<{
    readonly output: Record<string, unknown>
    readonly agentRunId: Uuid
  }>,
  leaseSeconds?: number,
): Promise<{ readonly ran: false } | { readonly ran: true; readonly job: ClaimedJob }> {
  const claim = await api.claim(agentRole, leaseSeconds)
  if (!claim.claimed) {
    return { ran: false }
  }

  let result: { readonly output: Record<string, unknown>; readonly agentRunId: Uuid }
  try {
    result = await work(claim.job)
  } catch (cause) {
    const reason = cause instanceof Error ? cause.message : String(cause)
    await api.fail(claim.job.pipelineJobId, claim.job.leaseToken, reason)
    throw cause
  }

  await api.complete(
    claim.job.pipelineJobId,
    claim.job.leaseToken,
    result.output,
    result.agentRunId,
  )
  return { ran: true, job: claim.job }
}
