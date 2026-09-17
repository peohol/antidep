// ============================================================================
// Kontrollkjøreren: hva den gjør med et uttak, og hva den aldri gjør
//
// Kjøreren er transporten mellom køen og Antideps egen deterministiske kode, og
// den tar ingen faglig avgjørelse. Prøvene her handler derfor om de to tingene
// den *kan* gjøre galt:
//
//   1. melde et uttak fullført når kontrollen ikke konkluderte — da ville kjeden
//      gått videre på en kontroll som aldri ble registrert, og
//   2. la et uttak stå uten å melde noe — da ville leien måttet løpe ut, og
//      begrunnelsen, den ene opplysningen som forklarer hva som skjedde, vært
//      borte.
//
// Alt som rører databasen er injisert, så hele orkestreringen prøves uten en
// stack og uten en artikkel.
// ============================================================================

import { describe, expect, it } from 'vitest'

import type {
  ClaimedJob,
  ClaimResult,
  FailureReport,
  PipelineJobApi,
} from '../agents/pipeline-job.ts'
import type { Uuid } from '../types/api.ts'
import {
  describeControlReport,
  runControlWorker,
  type ControlOutcome,
  type ControlStep,
} from './control-worker.ts'

const RUN_ID = '11111111-1111-4111-8111-111111111111' as Uuid

function job(index: number): ClaimedJob {
  return {
    pipelineJobId: `22222222-2222-4222-8222-00000000000${index}` as Uuid,
    jobKey: `kontroll:ekstraksjon:funn-${String(index)}`,
    agentRole: 'extraction_verification',
    inputManifest: { evidence_item_id: `funn-${String(index)}` },
    attempt: 1,
    maxAttempts: 3,
    leaseToken: `33333333-3333-4333-8333-00000000000${index}` as Uuid,
    lastFailureReason: null,
  }
}

interface FakeJobs extends PipelineJobApi {
  readonly completed: { jobId: string; leaseToken: string; runId: string }[]
  readonly failed: { jobId: string; reason: string }[]
}

/**
 * Køen som en dobbel: en liste uttak, og et spor over hva kjøreren meldte.
 *
 * `willRetry` er databasens svar og ikke kjørerens: en jobb med forsøk igjen
 * går tilbake i køen, og en oppbrukt blir stående. Doblen kan sette begge, slik
 * at begge setningene kjøreren skriver, faktisk prøves.
 */
function fakeJobs(queue: readonly ClaimedJob[], willRetry = true): FakeJobs {
  const remaining = [...queue]
  const completed: FakeJobs['completed'] = []
  const failed: FakeJobs['failed'] = []
  return {
    completed,
    failed,
    claim: (): Promise<ClaimResult> => {
      const next = remaining.shift()
      return Promise.resolve(next === undefined ? { claimed: false } : { claimed: true, job: next })
    },
    complete: (pipelineJobId, leaseToken, agentRunId): Promise<void> => {
      completed.push({ jobId: pipelineJobId, leaseToken, runId: agentRunId })
      return Promise.resolve()
    },
    fail: (pipelineJobId, _leaseToken, failureReason): Promise<FailureReport> => {
      failed.push({ jobId: pipelineJobId, reason: failureReason })
      return Promise.resolve({
        state: willRetry ? 'ready' : 'failed',
        attempts: 1,
        maxAttempts: 3,
        willRetry,
      })
    },
  }
}

function step(jobs: PipelineJobApi, execute: ControlStep['execute']): ControlStep {
  return { agentRole: 'extraction_verification', label: 'Ekstraksjonskontrollen', jobs, execute }
}

const registered: ControlOutcome = {
  agentRunId: RUN_ID,
  registered: true,
  reason: null,
  outcome: 'verified',
}

const nothing = () => Promise.resolve({ queued: 0, candidatesBuilt: 0 })

describe('kontrollkjøreren', () => {
  it('melder et uttak fullført når kontrollen faktisk registrerte noe', async () => {
    const jobs = fakeJobs([job(1)])
    const report = await runControlWorker({
      steps: [step(jobs, () => Promise.resolve(registered))],
      resume: nothing,
    })

    expect(report.claimed).toBe(1)
    expect(report.completed).toBe(1)
    expect(report.stalled).toBe(0)
    expect(jobs.completed).toEqual([
      { jobId: job(1).pipelineJobId, leaseToken: job(1).leaseToken, runId: RUN_ID },
    ])
    expect(jobs.failed).toEqual([])
  })

  it('melder uttaket mislykket når kontrollen ikke fikk konkludert', async () => {
    // Et utfall er ikke det samme som at kontrollen ikke kunne gjøres. Bare det
    // siste er stoppet arbeid, og bare det skal sende jobben tilbake i køen.
    const jobs = fakeJobs([job(1)])
    const report = await runControlWorker({
      steps: [
        step(jobs, () =>
          Promise.resolve({
            agentRunId: RUN_ID,
            registered: false,
            reason: 'Kildeteksten er ikke lagret for denne kildeversjonen.',
            outcome: null,
          }),
        ),
      ],
      resume: nothing,
    })

    expect(report.completed).toBe(0)
    expect(report.stalled).toBe(1)
    expect(jobs.completed).toEqual([])
    expect(jobs.failed[0]?.reason).toMatch(/Kildeteksten er ikke lagret/)
  })

  it('melder et negativt kontrollutfall som fullført arbeid', async () => {
    // `needs_correction` er en registrert kontroll, og kontrollen har gjort
    // jobben sin. At kjeden ikke går videre, avgjøres av porten foran neste
    // ledd — ikke av at uttaket meldes mislykket.
    const jobs = fakeJobs([job(1)])
    await runControlWorker({
      steps: [
        step(jobs, () =>
          Promise.resolve({
            agentRunId: RUN_ID,
            registered: true,
            reason: null,
            outcome: 'needs_correction',
          }),
        ),
      ],
      resume: nothing,
    })

    expect(jobs.completed).toHaveLength(1)
    expect(jobs.failed).toEqual([])
  })

  it('melder uttaket mislykket før den lar en uventet feil nå kalleren', async () => {
    // Et uttak som ble tatt og aldri meldt, ville blitt stående til leien løp
    // ut — og begrunnelsen ville vært borte.
    const jobs = fakeJobs([job(1)])
    await expect(
      runControlWorker({
        steps: [
          step(jobs, () => {
            throw new Error('Forbindelsen falt bort.')
          }),
        ],
        resume: nothing,
      }),
    ).rejects.toThrow('Forbindelsen falt bort.')

    expect(jobs.failed[0]?.reason).toBe('Forbindelsen falt bort.')
    expect(jobs.completed).toEqual([])
  })

  it('tar ikke flere uttak enn grensen, selv om køen er full', async () => {
    // En planlagt kjøring skal være en kjøring og ikke en tjeneste: uten et tak
    // ville kommandoen kunnet bli stående og holde leier i det uendelige om
    // databasen svarte feil.
    const jobs = fakeJobs([job(1), job(2), job(3), job(4)])
    const report = await runControlWorker({
      steps: [step(jobs, () => Promise.resolve(registered))],
      resume: nothing,
      maxTasksPerStep: 2,
    })

    expect(report.claimed).toBe(2)
    expect(jobs.completed).toHaveLength(2)
  })

  it('kjører hvert ledd for seg, med sin egen kø', async () => {
    // Rollen er rettighetsgrensen. De to kontrolleddene deler verken aktør,
    // identitet eller hemmelighet, og kjøreren slår dem ikke sammen.
    const first = fakeJobs([job(1)])
    const second = fakeJobs([job(2)])
    const roles: string[] = []
    const report = await runControlWorker({
      steps: [
        { ...step(first, () => Promise.resolve(registered)), agentRole: 'extraction_verification' },
        {
          agentRole: 'citation_support_verification',
          label: 'Kildestøttekontrollen',
          jobs: {
            ...second,
            claim: (role) => {
              roles.push(role)
              return second.claim(role)
            },
          },
          execute: () => Promise.resolve(registered),
        },
      ],
      resume: nothing,
    })

    expect(report.completed).toBe(2)
    expect(roles).toContain('citation_support_verification')
  })

  it('rydder opp i kjedeovergangene før den tømmer køen', async () => {
    const order: string[] = []
    const jobs = fakeJobs([job(1)])
    const report = await runControlWorker({
      steps: [
        step(jobs, () => {
          order.push('kontroll')
          return Promise.resolve(registered)
        }),
      ],
      resume: () => {
        order.push('opprydning')
        return Promise.resolve({ queued: 2, candidatesBuilt: 1 })
      },
    })

    expect(order).toEqual(['opprydning', 'kontroll'])
    expect(report.resumed).toBe(2)
    expect(report.candidatesBuilt).toBe(1)
  })

  it('sier stille fra når ingenting ventet', async () => {
    const report = await runControlWorker({
      steps: [step(fakeJobs([]), () => Promise.resolve(registered))],
      resume: nothing,
    })
    expect(describeControlReport(report)).toBe('Ingen kontroller ventet.')
  })

  it('forteller hva kjøringen faktisk gjorde', async () => {
    const report = await runControlWorker({
      steps: [
        step(fakeJobs([job(1), job(2)], false), (claimed) =>
          Promise.resolve(
            claimed.jobKey.endsWith('funn-1')
              ? registered
              : { agentRunId: RUN_ID, registered: false, reason: 'Ingen kilde.', outcome: null },
          ),
        ),
      ],
      resume: nothing,
    })
    expect(describeControlReport(report)).toBe(
      '2 kontroll(er) tatt: 1 registrert, 1 fikk ikke konkludert og prøves igjen.',
    )
  })
})
