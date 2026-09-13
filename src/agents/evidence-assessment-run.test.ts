import { describe, expect, it } from 'vitest'

import {
  AgentApiError,
  type AgentRunPremises,
  type EvidenceAssessmentApi,
  type RegisterEvidenceAssessmentArgs,
} from './agent-api'
import {
  EVIDENCE_ASSESSMENT_PROPOSAL_VERSION,
  parseEvidenceAssessmentProposal,
  type EvidenceAssessmentProposal,
} from './evidence-assessment-proposal'
import {
  parseEvidenceAssessmentResult,
  runEvidenceAssessment,
  type LabelledAssessmentProposal,
} from './evidence-assessment-run'

const PREMISSER: AgentRunPremises = {
  provider: 'antidep',
  model: 'proposal-registered-assessment',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'evidence-assessment/proposal/1',
  pipelineVersion: 'antidep-evidence/1',
}

const RUN_ID = '11111111-1111-4111-8111-111111111111'
const CLAIM_ID = '22222222-2222-4222-8222-222222222222'
const REVISION_ID = '33333333-3333-4333-8333-333333333333'
const ASSESSMENT_ID = '44444444-4444-4444-8444-444444444444'
const DIGEST = `sha256-v1:${'a'.repeat(64)}`

function svar(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    evidence_assessment_id: ASSESSMENT_ID,
    claim_revision_id: REVISION_ID,
    claim_id: CLAIM_ID,
    certainty_level: 'very_low',
    assessed_at: '2026-09-24T09:00:00+00:00',
    evidence_set_digest: DIGEST,
    ...overrides,
  }
}

interface FakeApi extends EvidenceAssessmentApi {
  readonly registered: RegisterEvidenceAssessmentArgs[]
  readonly runs: { manifest: Record<string, unknown> }[]
  readonly completions: {
    status: string
    outputManifest: Record<string, unknown> | null
    failureReason: string | null
  }[]
}

function fakeApi(overrides: Partial<EvidenceAssessmentApi> = {}): FakeApi {
  const registered: RegisterEvidenceAssessmentArgs[] = []
  const runs: FakeApi['runs'] = []
  const completions: FakeApi['completions'] = []

  return {
    registered,
    runs,
    completions,
    beginRun: (_premises, manifest) => {
      runs.push({ manifest })
      return Promise.resolve(RUN_ID)
    },
    registerAssessment: (args) => {
      registered.push(args)
      return Promise.resolve(svar())
    },
    completeRun: (_runId, status, outputManifest, failureReason) => {
      completions.push({ status, outputManifest, failureReason })
      return Promise.resolve()
    },
    ...overrides,
  }
}

function forslag(overrides: Record<string, unknown> = {}): EvidenceAssessmentProposal {
  return parseEvidenceAssessmentProposal({
    proposal_version: EVIDENCE_ASSESSMENT_PROPOSAL_VERSION,
    generated_by: {
      producer: 'model',
      provider: 'testleverandør',
      model: 'testmodell',
      model_version: '2026-09-13',
      prompt_template_version: 'evidence-assessment/1',
      drafted_at: '2026-09-13T09:00:00Z',
      request_digest: null,
    },
    claim_revision_id: REVISION_ID,
    evidence_set_digest: DIGEST,
    assessment: {
      framework: 'grade',
      certainty_level: 'very_low',
      risk_of_bias: 'serious',
      inconsistency: 'not_assessable',
      indirectness: 'serious',
      imprecision: 'serious',
      publication_bias: 'not_assessable',
      other_considerations: null,
      rationale: 'Ett evidensfunn fra én randomisert studie ligger til grunn.',
      evidence_gap: 'Størrelsen er ikke tallfestet i grunnlaget.',
    },
    ...overrides,
  })
}

function kø(...proposals: EvidenceAssessmentProposal[]): LabelledAssessmentProposal[] {
  return proposals.map((proposal, index) => ({
    label: `vurdering-${String(index + 1)}.json`,
    proposal,
  }))
}

describe('runEvidenceAssessment', () => {
  it('registrerer vurderingen og lukker kjøringen', async () => {
    const api = fakeApi()
    const report = await runEvidenceAssessment({
      api,
      premises: PREMISSER,
      proposals: kø(forslag()),
    })

    expect(report.runStatus).toBe('succeeded')
    expect(report.registered).toBe(1)
    expect(api.registered[0]?.agentRunId).toBe(RUN_ID)
    expect(api.registered[0]?.claimRevisionId).toBe(REVISION_ID)
    expect(report.results[0]?.registered?.evidenceAssessmentId).toBe(ASSESSMENT_ID)
    expect(api.completions[0]?.status).toBe('succeeded')
  })

  it('sender avtrykket utkastet ble laget mot, slik at et utdatert utkast avvises', async () => {
    // Vurderingen forsegler evidenssettet. Uten avtrykket ville en lenke som kom
    // til underveis, blitt stilltiende dekket av en gradering som aldri så den.
    const api = fakeApi()
    await runEvidenceAssessment({ api, premises: PREMISSER, proposals: kø(forslag()) })
    expect(api.registered[0]?.seenEvidenceSetDigest).toBe(DIGEST)
  })

  it('fører erklæringen om hvem som laget utkastet i kjøringens inndatamanifest', async () => {
    const api = fakeApi()
    await runEvidenceAssessment({ api, premises: PREMISSER, proposals: kø(forslag()) })

    const proposals = api.runs[0]?.manifest['proposals'] as Record<string, unknown>[]
    const declaration = proposals[0]?.['generated_by'] as Record<string, unknown>
    expect(declaration['model']).toBe('testmodell')
    expect(proposals[0]?.['claim_revision_id']).toBe(REVISION_ID)
  })

  it('skriver ingenting i en tørrkjøring, men lukker kjøringen som aborted', async () => {
    const api = fakeApi()
    const report = await runEvidenceAssessment({
      api,
      premises: PREMISSER,
      proposals: kø(forslag()),
      dryRun: true,
    })

    expect(api.registered).toHaveLength(0)
    expect(report.runStatus).toBe('aborted')
    expect(report.results[0]?.decision).toBe('previewed')
  })

  it('lar ett avvist forslag stå alene: de øvrige registreres', async () => {
    let calls = 0
    const api = fakeApi({
      registerAssessment: () => {
        calls += 1
        if (calls === 1) {
          return Promise.reject(
            new AgentApiError(
              'api.register_evidence_assessment',
              'Revisjon 33333333-3333-4333-8333-333333333333 har ingen registrert claim-verifikasjon, og grunnlaget kan ikke graderes ennå.',
              '23001',
              null,
            ),
          )
        }
        return Promise.resolve(svar())
      },
    })

    const report = await runEvidenceAssessment({
      api,
      premises: PREMISSER,
      proposals: kø(forslag(), forslag()),
    })

    expect(report.skipped).toBe(1)
    expect(report.registered).toBe(1)
    expect(report.results[0]?.reason).toMatch(/ingen registrert claim-verifikasjon/)
    expect(report.runStatus).toBe('succeeded')
  })

  it.each([
    ['40P01', 'deadlock detected'],
    ['40001', 'could not serialize access due to concurrent update'],
    ['42501', 'permission denied for function register_evidence_assessment'],
    ['XX000', 'internal error'],
  ])(
    'velter kjøringen på SQLSTATE %s framfor å føre forslaget som overhoppet',
    async (kode, melding) => {
      const api = fakeApi({
        registerAssessment: () =>
          Promise.reject(
            new AgentApiError('api.register_evidence_assessment', melding, kode, null),
          ),
      })

      await expect(
        runEvidenceAssessment({ api, premises: PREMISSER, proposals: kø(forslag(), forslag()) }),
      ).rejects.toThrow(/utfallet er ukjent/)
      expect(api.completions[0]?.status).toBe('failed')
    },
  )

  it('stopper kjøringen når svaret ikke har formen: skrivingen kan ha gått gjennom', async () => {
    const api = fakeApi({ registerAssessment: () => Promise.resolve({ ikke: 'en vurdering' }) })

    await expect(
      runEvidenceAssessment({ api, premises: PREMISSER, proposals: kø(forslag()) }),
    ).rejects.toThrow(/utfallet er ukjent/)
    expect(api.completions[0]?.status).toBe('failed')
  })
})

describe('parseEvidenceAssessmentResult', () => {
  it('leser svaret fra databasen', () => {
    const parsed = parseEvidenceAssessmentResult(svar())
    expect(parsed.evidenceAssessmentId).toBe(ASSESSMENT_ID)
    expect(parsed.claimRevisionId).toBe(REVISION_ID)
    expect(parsed.certaintyLevel).toBe('very_low')
  })

  it('avviser et svar uten vurderings-ID framfor å rapportere en registrering uten den', () => {
    const uten = svar()
    delete uten['evidence_assessment_id']
    expect(() => parseEvidenceAssessmentResult(uten)).toThrow(/evidence_assessment_id/)
  })
})
