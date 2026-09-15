import { describe, expect, it, vi } from 'vitest'

import {
  jobKey,
  parseClaimedJob,
  parseFailureReport,
  runOnePipelineJob,
  type ClaimResult,
  type FailureReport,
  type PipelineJobApi,
} from './pipeline-job.ts'
import type { Uuid } from '../types/api.ts'

const JOB_ID = '11111111-1111-4111-8111-111111111111' as Uuid
const LEASE = '22222222-2222-4222-8222-222222222222' as Uuid
const RUN_ID = '33333333-3333-4333-8333-333333333333' as Uuid

function claimedPayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    claimed: true,
    pipeline_job_id: JOB_ID,
    job_key: 'extraction:kildeversjon-1',
    agent_role: 'evidence_extraction',
    input_manifest: { source_version_id: 'kildeversjon-1' },
    attempt: 1,
    max_attempts: 3,
    lease_token: LEASE,
    last_failure_reason: null,
    ...overrides,
  }
}

describe('jobKey', () => {
  it('bygger en stabil nøkkel av hva jobben handler om', () => {
    expect(jobKey('extraction', 'kildeversjon-1')).toBe('extraction:kildeversjon-1')
    // Den samme jobben gir den samme nøkkelen. Det er hele idempotensen.
    expect(jobKey(' extraction ', ' kildeversjon-1 ')).toBe('extraction:kildeversjon-1')
  })

  it('avviser en tom del framfor å lage en nøkkel som dekker alt', () => {
    expect(() => jobKey('extraction', '   ')).toThrow(/jobbnøkkel/)
  })
})

describe('parseClaimedJob', () => {
  it('leser et uttatt oppdrag', () => {
    const result = parseClaimedJob(claimedPayload())
    expect(result.claimed).toBe(true)
    if (!result.claimed) return
    expect(result.job.pipelineJobId).toBe(JOB_ID)
    expect(result.job.leaseToken).toBe(LEASE)
    expect(result.job.inputManifest).toEqual({ source_version_id: 'kildeversjon-1' })
  })

  it('leser en tom kø som en tom kø, ikke som en feil', () => {
    expect(parseClaimedJob({ claimed: false })).toEqual({ claimed: false })
  })

  it('bærer begrunnelsen fra forrige mislykkede forsøk videre', () => {
    const result = parseClaimedJob(
      claimedPayload({ attempt: 2, last_failure_reason: 'Kilden svarte ikke.' }),
    )
    expect(result.claimed && result.job.lastFailureReason).toBe('Kilden svarte ikke.')
  })

  it('avviser et svar uten kontraktens form framfor å arbeide på undefined', () => {
    expect(() => parseClaimedJob(claimedPayload({ input_manifest: 'ikke et objekt' }))).toThrow(
      /input_manifest/,
    )
    expect(() => parseClaimedJob(claimedPayload({ attempt: 0 }))).toThrow(/attempt/)
    expect(() => parseClaimedJob({ claimed: 'ja' })).toThrow(/claimed/)
    // Uten nøkkelen for nettopp dette uttaket kan utfallet ikke meldes, og en
    // kjører som gjettet den ville skrevet over det forsøket som nå arbeider.
    expect(() => parseClaimedJob(claimedPayload({ lease_token: null }))).toThrow(/lease_token/)
  })
})

describe('parseFailureReport', () => {
  it('skiller et forsøk som prøves om igjen fra et som er brukt opp', () => {
    const retry = parseFailureReport({
      state: 'ready',
      attempts: 1,
      max_attempts: 3,
      will_retry: true,
    })
    expect(retry.willRetry).toBe(true)

    const exhausted = parseFailureReport({
      state: 'failed',
      attempts: 3,
      max_attempts: 3,
      will_retry: false,
    })
    expect(exhausted).toMatchObject<Partial<FailureReport>>({ state: 'failed', willRetry: false })
  })
})

function fakeApi(claim: ClaimResult): {
  readonly api: PipelineJobApi
  readonly completed: ReturnType<typeof vi.fn>
  readonly failed: ReturnType<typeof vi.fn>
} {
  const completed = vi.fn(async () => {})
  const failed = vi.fn(async () => ({
    state: 'ready',
    attempts: 1,
    maxAttempts: 3,
    willRetry: true,
  }))
  return {
    api: {
      claim: async () => claim,
      complete: completed,
      fail: failed,
    },
    completed,
    failed,
  }
}

describe('runOnePipelineJob', () => {
  it('gjør ingenting når køen er tom', async () => {
    const { api, completed, failed } = fakeApi({ claimed: false })
    expect(
      await runOnePipelineJob(api, 'evidence_extraction', async () => ({
        output: {},
        agentRunId: RUN_ID,
      })),
    ).toEqual({ ran: false })
    expect(completed).not.toHaveBeenCalled()
    expect(failed).not.toHaveBeenCalled()
  })

  it('melder utfallet når arbeidet gikk gjennom', async () => {
    const claim = parseClaimedJob(claimedPayload())
    const { api, completed } = fakeApi(claim)
    await runOnePipelineJob(api, 'evidence_extraction', async () => ({
      output: { registered: true },
      agentRunId: RUN_ID,
    }))
    // Leienøkkelen og kjøringen følger utfallet: uten dem kan databasen
    // verken vite hvilket forsøk som melder, eller hvilket arbeid som ble gjort.
    expect(completed).toHaveBeenCalledWith(JOB_ID, LEASE, { registered: true }, RUN_ID)
  })

  // En jobb som ble tatt ut og aldri meldt, ville blitt stående til leien løp
  // ut, og begrunnelsen — den ene opplysningen som forklarer hva som skjedde —
  // ville vært borte.
  it('melder feilen før den kastes videre', async () => {
    const claim = parseClaimedJob(claimedPayload())
    const { api, failed, completed } = fakeApi(claim)
    await expect(
      runOnePipelineJob(api, 'evidence_extraction', async () => {
        throw new Error('Dokumentet lå ikke i biblioteket.')
      }),
    ).rejects.toThrow('Dokumentet lå ikke i biblioteket.')
    expect(failed).toHaveBeenCalledWith(JOB_ID, LEASE, 'Dokumentet lå ikke i biblioteket.')
    expect(completed).not.toHaveBeenCalled()
  })
})
