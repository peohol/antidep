import { describe, expect, it } from 'vitest'

import type { AgentRunPremises, ClaimSynthesisApi, RegisterClaimSynthesisArgs } from './agent-api'
import {
  CLAIM_SYNTHESIS_PROPOSAL_VERSION,
  parseClaimSynthesisProposal,
  type ClaimSynthesisProposal,
} from './claim-synthesis-proposal'
import {
  parseClaimSynthesisResult,
  runClaimSynthesis,
  type LabelledSynthesisProposal,
} from './claim-synthesis-run'
import { parseSynthesisArguments } from './cli-arguments'

const PREMISSER: AgentRunPremises = {
  provider: 'antidep',
  model: 'proposal-registered-synthesis',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'claim-synthesis/proposal/1',
  pipelineVersion: 'antidep-evidence/1',
}

const RUN_ID = '11111111-1111-4111-8111-111111111111'
const CLAIM_ID = '22222222-2222-4222-8222-222222222222'
const REVISION_ID = '33333333-3333-4333-8333-333333333333'
const ASSESSMENT_ID = '44444444-4444-4444-8444-444444444444'
const LINK_ID = '55555555-5555-4555-8555-555555555555'
const ITEM_ID = '66666666-6666-4666-8666-666666666666'

function svar(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    claim_id: CLAIM_ID,
    claim_revision_id: REVISION_ID,
    revision_number: 1,
    supersedes_revision_id: null,
    evidence_links: [{ claim_evidence_link_id: LINK_ID, evidence_item_id: ITEM_ID }],
    evidence_assessment_id: ASSESSMENT_ID,
    evidence_set_digest: `sha256-v1:${'a'.repeat(64)}`,
    ...overrides,
  }
}

interface FakeApi extends ClaimSynthesisApi {
  readonly registered: RegisterClaimSynthesisArgs[]
  readonly runs: { manifest: Record<string, unknown> }[]
  readonly completions: {
    status: string
    outputManifest: Record<string, unknown> | null
    failureReason: string | null
  }[]
}

/**
 * Databasen som en dobbel. Kallene er kontrakten, ikke returverdiene: prøvene
 * ser på hva som faktisk ble sendt og i hvilken rekkefølge.
 */
function fakeApi(overrides: Partial<ClaimSynthesisApi> = {}): FakeApi {
  const registered: RegisterClaimSynthesisArgs[] = []
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
    registerSynthesis: (args) => {
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

function forslag(overrides: Record<string, unknown> = {}): ClaimSynthesisProposal {
  return parseClaimSynthesisProposal({
    proposal_version: CLAIM_SYNTHESIS_PROPOSAL_VERSION,
    generated_by: {
      producer: 'model',
      provider: 'testleverandør',
      model: 'testmodell',
      model_version: '2026-09-13',
      prompt_template_version: 'claim-synthesis/1',
      drafted_at: '2026-09-13T09:00:00Z',
      request_digest: null,
    },
    claim: {
      claim_id: null,
      topic_concept_id: '77777777-7777-4777-8777-777777777777',
      subject_drug_id: '88888888-8888-4888-8888-888888888888',
      statement: 'Hos voksne er behandling forbundet med en gjennomsnittlig vektøkning.',
      scope: 'Gjelder gjennomsnittlig vektendring fra behandlingsstart i åtte uker.',
      population_id: null,
      timeframe_min: '8 weeks',
      timeframe_max: '8 weeks',
      comparator_kind: 'none',
      comparator_drug_id: null,
      direction: 'increase',
      magnitude_measure: null,
      magnitude_value: null,
      magnitude_unit: null,
      qualifiers: null,
      uncertainty_summary: 'Ett evidensfunn fra én studie ligger til grunn.',
    },
    evidence_links: [
      {
        evidence_item_id: ITEM_ID,
        relationship_type: 'supports',
        directness: 'indirect',
        relevance_note: 'Funnet rapporterer vektendring for behandlingsarmen påstanden gjelder.',
      },
    ],
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

function kø(...proposals: ClaimSynthesisProposal[]): LabelledSynthesisProposal[] {
  return proposals.map((proposal, index) => ({
    label: `forslag-${String(index + 1)}.json`,
    proposal,
  }))
}

describe('runClaimSynthesis', () => {
  it('registrerer forslaget og lukker kjøringen', async () => {
    const api = fakeApi()
    const report = await runClaimSynthesis({ api, premises: PREMISSER, proposals: kø(forslag()) })

    expect(report.runStatus).toBe('succeeded')
    expect(report.registered).toBe(1)
    expect(api.registered).toHaveLength(1)
    expect(api.registered[0]?.agentRunId).toBe(RUN_ID)
    expect(report.results[0]?.registered?.claimRevisionId).toBe(REVISION_ID)
    expect(api.completions[0]?.status).toBe('succeeded')
  })

  it('fører erklæringen om hvem som laget utkastet i kjøringens inndatamanifest', async () => {
    // Premissene beskriver registreringen, ikke modellen som formulerte
    // påstanden. Uten erklæringen i manifestet ville proveniensen sagt at
    // Antideps egen kode skrev den kliniske formuleringen.
    const api = fakeApi()
    await runClaimSynthesis({ api, premises: PREMISSER, proposals: kø(forslag()) })

    const proposals = api.runs[0]?.manifest['proposals'] as Record<string, unknown>[]
    const declaration = proposals[0]?.['generated_by'] as Record<string, unknown>
    expect(declaration['model']).toBe('testmodell')
    expect(declaration['drafted_at']).toBe('2026-09-13T09:00:00Z')
  })

  it('skriver ingenting i en tørrkjøring, men lukker kjøringen som aborted', async () => {
    const api = fakeApi()
    const report = await runClaimSynthesis({
      api,
      premises: PREMISSER,
      proposals: kø(forslag()),
      dryRun: true,
    })

    expect(api.registered).toHaveLength(0)
    expect(report.runStatus).toBe('aborted')
    expect(report.results[0]?.decision).toBe('previewed')
    expect(api.completions[0]?.failureReason).toMatch(/Tørrkjøring/)
  })

  it('lar ett avvist forslag stå alene: de øvrige registreres', async () => {
    let calls = 0
    const api = fakeApi({
      registerSynthesis: () => {
        calls += 1
        if (calls === 1) {
          return Promise.reject(
            new Error(
              'Evidensfunn med åpent verifikasjonsfunn: 66666666-6666-4666-8666-666666666666.',
            ),
          )
        }
        return Promise.resolve(svar({ revision_number: 2 }))
      },
    })

    const report = await runClaimSynthesis({
      api,
      premises: PREMISSER,
      proposals: kø(forslag(), forslag()),
    })

    expect(report.registered).toBe(1)
    expect(report.skipped).toBe(1)
    expect(report.results[0]?.decision).toBe('skipped')
    // Databasens egen setning er det som når kalleren; en generisk melding ville
    // sendt den som skrev forslaget på leting.
    expect(report.results[0]?.reason).toMatch(/åpent verifikasjonsfunn/)
    expect(report.results[1]?.decision).toBe('registered')
    expect(report.runStatus).toBe('succeeded')
  })

  it('lukker kjøringen som failed når noe uventet skjer', async () => {
    const api = fakeApi({
      completeRun: () => Promise.resolve(),
      registerSynthesis: () => Promise.resolve(svar()),
    })
    const brutt: ClaimSynthesisApi = {
      ...api,
      registerSynthesis: () => Promise.resolve({ ikke: 'en syntese' }),
    }
    const samler = { ...api, ...brutt } as FakeApi

    const report = await runClaimSynthesis({
      api: samler,
      premises: PREMISSER,
      proposals: kø(forslag()),
    })
    // Et svar som ikke har formen, er det ene forslagets problem: kjøringen
    // fører det som avvist framfor å velte køen.
    expect(report.results[0]?.decision).toBe('skipped')
    expect(report.results[0]?.reason).toMatch(/ugyldig/)
  })
})

describe('parseClaimSynthesisResult', () => {
  it('leser svaret fra databasen', () => {
    const parsed = parseClaimSynthesisResult(svar())
    expect(parsed.claimRevisionId).toBe(REVISION_ID)
    expect(parsed.revisionNumber).toBe(1)
    expect(parsed.supersedesRevisionId).toBeNull()
    expect(parsed.evidenceLinkIds).toEqual([LINK_ID])
  })

  it('leser en videreføring', () => {
    const parsed = parseClaimSynthesisResult(
      svar({ revision_number: 2, supersedes_revision_id: REVISION_ID }),
    )
    expect(parsed.revisionNumber).toBe(2)
    expect(parsed.supersedesRevisionId).toBe(REVISION_ID)
  })

  it('avviser et svar uten revisjons-ID framfor å rapportere en registrering uten den', () => {
    const uten = svar()
    delete uten['claim_revision_id']
    expect(() => parseClaimSynthesisResult(uten)).toThrow(/claim_revision_id/)
  })

  it('avviser et revisjonsnummer som ikke er et heltall', () => {
    expect(() => parseClaimSynthesisResult(svar({ revision_number: '1' }))).toThrow(
      /revision_number/,
    )
  })
})

describe('parseSynthesisArguments', () => {
  it('leser en katalog', () => {
    expect(parseSynthesisArguments(['--directory', 'syntheses'])).toEqual({
      directory: 'syntheses',
      proposalPaths: [],
      dryRun: false,
    })
  })

  it('leser flere enkeltfiler og tørrkjøring', () => {
    expect(
      parseSynthesisArguments(['--proposal', 'a.json', '--proposal', 'b.json', '--dry-run']),
    ).toEqual({
      directory: null,
      proposalPaths: ['a.json', 'b.json'],
      dryRun: true,
    })
  })

  it('krever at noe er oppgitt', () => {
    expect(() => parseSynthesisArguments([])).toThrow(/--directory/)
  })

  it('avviser katalog og enkeltfil sammen: rekkefølgen ville vært uklar', () => {
    expect(() =>
      parseSynthesisArguments(['--directory', 'syntheses', '--proposal', 'a.json']),
    ).toThrow(/ikke begge/)
  })

  it('avviser et ukjent valg framfor å ignorere det', () => {
    expect(() => parseSynthesisArguments(['--registrer-alt'])).toThrow(/Ukjent valg/)
  })

  it('avviser et stiflagg uten verdi', () => {
    expect(() => parseSynthesisArguments(['--proposal'])).toThrow(/krever en sti/)
    expect(() => parseSynthesisArguments(['--directory', '--dry-run'])).toThrow(/krever en sti/)
  })

  it('svarer help på --help', () => {
    expect(parseSynthesisArguments(['--help'])).toBe('help')
  })
})
