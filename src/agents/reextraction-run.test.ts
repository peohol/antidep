// ============================================================================
// Re-ekstraksjonen: at den registrerer, kontrollerer, og lar det gamle stå
//
// Testene her prøver orkestreringen, ikke leddene: at kontrollen kjøres på
// nøyaktig det funnet som nettopp ble registrert, at en dublett ikke skriver
// noe, og at en tørrkjøring verken registrerer eller kontrollerer.
//
// Ingen database og ingen nett: begge portene er doble, og kilden er fikstur.
// Selve skriveveien er SQL og prøves i supabase/tests/590 og 600.
// ============================================================================

import { describe, expect, it } from 'vitest'

import type {
  AgentRunPremises,
  EvidenceExtractionApi,
  ExtractionVerificationApi,
} from './agent-api'
import { AgentApiError } from './agent-api'
import { sourceVersionContentHash } from './content-hash'
import { EXTRACTION_PROPOSAL_VERSION, parseExtractionProposal } from './extraction-proposal'
import type { RetrieveLike } from './extraction-run'
import { runReextraction } from './reextraction-run'
import { FIXTURE_SOURCE_TEXT } from './test-support'
import type { Uuid } from '../types/api'

const EXTRACTION_PREMISES: AgentRunPremises = {
  provider: 'antidep',
  model: 'proposal-grounded-extraction',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'evidence-extraction/proposal/1',
  pipelineVersion: 'antidep-evidence/1',
}
const VERIFICATION_PREMISES: AgentRunPremises = {
  provider: 'antidep',
  model: 'deterministic-extraction-check',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'extraction-verification/deterministic/1',
  pipelineVersion: 'antidep-evidence/1',
}

const EXTRACTION_RUN_ID = '11111111-1111-4111-8111-111111111111' as Uuid
const VERIFICATION_RUN_ID = '22222222-2222-4222-8222-222222222222' as Uuid
const ITEM_ID = '33333333-3333-4333-8333-333333333333' as Uuid
const VERIFIER_ACTOR_ID = '44444444-4444-4444-8444-444444444444'

async function proposal(): Promise<ReturnType<typeof parseExtractionProposal>> {
  return parseExtractionProposal({
    proposal_version: EXTRACTION_PROPOSAL_VERSION,
    source_id: '50000000-0000-4000-8000-000000000001',
    source_version_id: '51000000-0000-4000-8000-000000000001',
    retrieved_from: 'https://eksempel.invalid/kilde',
    content_hash: await sourceVersionContentHash(FIXTURE_SOURCE_TEXT),
    extraction: {
      design_code: 'randomized_controlled_trial',
      population_availability: 'not_reported',
      population_detail: 'Voksne med depressiv lidelse.',
      sample_size: 284,
      sample_size_availability: 'reported_value',
      intervention_drug_id: '40000000-0000-4000-8000-000000000001',
      comparator_kind: 'none',
      outcome_concept_id: '41000000-0000-4000-8000-000000000001',
      outcome_detail: 'Gjennomsnittlig vektendring.',
      timepoint_availability: 'not_reported',
      reported_direction: 'increase',
      estimate_availability: 'not_reported',
      confidence_interval_availability: 'not_reported',
      source_locator: 'Sammendrag, resultatavsnittet',
    },
    field_groundings: [
      {
        check_field: 'sample_size',
        source_excerpt: 'Sertraline patients (N = 284) with major depressive disorder',
        source_locator: 'Sammendrag, METHODS',
        justification: 'Utvalgsstørrelsen står ved siden av armen.',
      },
    ],
  })
}

function retrieveFixture(): RetrieveLike {
  return async (url) => ({
    status: 'ok',
    representation: {
      url,
      status: 200,
      contentType: 'text/xml',
      content: FIXTURE_SOURCE_TEXT,
      byteLength: FIXTURE_SOURCE_TEXT.length,
      contentHash: await sourceVersionContentHash(FIXTURE_SOURCE_TEXT),
      bytesAreUtf8: true,
    },
  })
}

interface Spy {
  readonly extractionApi: EvidenceExtractionApi
  readonly verificationApi: ExtractionVerificationApi
  readonly registered: unknown[]
  readonly readInputFor: (Uuid | null)[]
  readonly completions: { readonly run: Uuid; readonly status: string }[]
}

function spies(options: { readonly duplicate?: boolean } = {}): Spy {
  const registered: unknown[] = []
  const readInputFor: (Uuid | null)[] = []
  const completions: { run: Uuid; status: string }[] = []

  return {
    registered,
    readInputFor,
    completions,
    extractionApi: {
      beginRun: () => Promise.resolve(EXTRACTION_RUN_ID),
      completeRun: (run, status) => {
        completions.push({ run, status })
        return Promise.resolve()
      },
      registerExtraction: (args) => {
        if (options.duplicate === true) {
          return Promise.reject(
            new AgentApiError(
              'api.register_agent_extraction',
              'Nøyaktig det samme evidensfunnet er allerede registrert.',
              '23505',
            ),
          )
        }
        registered.push(args)
        return Promise.resolve(ITEM_ID)
      },
    },
    verificationApi: {
      beginRun: () => Promise.resolve(VERIFICATION_RUN_ID),
      completeRun: (run, status) => {
        completions.push({ run, status })
        return Promise.resolve()
      },
      readInput: (_runId, evidenceItemId) => {
        readInputFor.push(evidenceItemId)
        // Tom kø: kontrollen av selve kontrollen ligger i
        // extraction-verification-run.test.ts og i kjedeprøven. Det som prøves
        // her, er at den kjøres på riktig funn.
        return Promise.resolve({
          agent_run_id: VERIFICATION_RUN_ID,
          verifier_actor_id: VERIFIER_ACTOR_ID,
          items: [],
        })
      },
      registerVerification: () => Promise.resolve(VERIFICATION_RUN_ID),
    },
  }
}

describe('runReextraction', () => {
  it('registrerer funnet og kontrollerer nøyaktig det', async () => {
    const spy = spies()
    const report = await runReextraction({
      extractionApi: spy.extractionApi,
      verificationApi: spy.verificationApi,
      extractionPremises: EXTRACTION_PREMISES,
      verificationPremises: VERIFICATION_PREMISES,
      proposals: [{ label: 'fava.json', proposal: await proposal() }],
      retrieve: retrieveFixture(),
    })

    expect(report.registered).toBe(1)
    expect(spy.registered).toHaveLength(1)
    // Kontrollen kjøres på det nye funnet, ikke på hele køen: en
    // re-ekstraksjon skal ikke dra andre funn med seg.
    expect(spy.readInputFor).toEqual([ITEM_ID])
    expect(report.results[0]?.verification?.agentRunId).toBe(VERIFICATION_RUN_ID)
  })

  // Kjørt om igjen med den samme filen skriver den ingenting: content_hash
  // dekker hele radens faglige innhold, og databasen avviser dubletten.
  it('er idempotent: en dublett skriver ingenting og kontrolleres ikke', async () => {
    const spy = spies({ duplicate: true })
    const report = await runReextraction({
      extractionApi: spy.extractionApi,
      verificationApi: spy.verificationApi,
      extractionPremises: EXTRACTION_PREMISES,
      verificationPremises: VERIFICATION_PREMISES,
      proposals: [{ label: 'fava.json', proposal: await proposal() }],
      retrieve: retrieveFixture(),
    })

    expect(report.registered).toBe(0)
    expect(report.alreadyRegistered).toBe(1)
    expect(spy.registered).toHaveLength(0)
    expect(spy.readInputFor).toEqual([])
    expect(spy.completions).toEqual([{ run: EXTRACTION_RUN_ID, status: 'aborted' }])
  })

  it('skriver ingenting i en tørrkjøring', async () => {
    const spy = spies()
    const report = await runReextraction({
      extractionApi: spy.extractionApi,
      verificationApi: spy.verificationApi,
      extractionPremises: EXTRACTION_PREMISES,
      verificationPremises: VERIFICATION_PREMISES,
      proposals: [{ label: 'fava.json', proposal: await proposal() }],
      dryRun: true,
      retrieve: retrieveFixture(),
    })

    expect(report.registered).toBe(0)
    expect(spy.registered).toHaveLength(0)
    expect(spy.readInputFor).toEqual([])
    expect(report.results[0]?.extraction.decision).toBe('previewed')
    // Også en tørrkjøring er sporbar: kjøringen registreres og lukkes.
    expect(spy.completions).toEqual([{ run: EXTRACTION_RUN_ID, status: 'aborted' }])
  })

  it('lar de andre forslagene gå videre når ett ikke holder mål', async () => {
    const spy = spies()
    const godt = await proposal()
    const daarlig = parseExtractionProposal({
      proposal_version: EXTRACTION_PROPOSAL_VERSION,
      source_id: godt.sourceId,
      source_version_id: godt.sourceVersionId,
      retrieved_from: godt.retrievedFrom,
      content_hash: godt.contentHash,
      extraction: {
        design_code: 'randomized_controlled_trial',
        population_availability: 'not_reported',
        population_detail: 'Voksne med depressiv lidelse.',
        sample_size_availability: 'not_reported',
        intervention_drug_id: '40000000-0000-4000-8000-000000000001',
        comparator_kind: 'none',
        outcome_concept_id: '41000000-0000-4000-8000-000000000001',
        outcome_detail: 'Gjennomsnittlig vektendring.',
        timepoint_availability: 'not_reported',
        reported_direction: 'increase',
        estimate_availability: 'not_reported',
        confidence_interval_availability: 'not_reported',
        source_locator: 'Sammendrag',
      },
      field_groundings: [
        {
          check_field: 'outcome',
          source_excerpt: 'Denne setningen står ikke i kilden i det hele tatt.',
          source_locator: 'Sammendrag',
          justification: 'Et oppdiktet utdrag.',
        },
      ],
    })

    const report = await runReextraction({
      extractionApi: spy.extractionApi,
      verificationApi: spy.verificationApi,
      extractionPremises: EXTRACTION_PREMISES,
      verificationPremises: VERIFICATION_PREMISES,
      proposals: [
        { label: 'daarlig.json', proposal: daarlig },
        { label: 'godt.json', proposal: godt },
      ],
      retrieve: retrieveFixture(),
    })

    expect(report.skipped).toBe(1)
    expect(report.registered).toBe(1)
    expect(report.results.map((result) => result.label)).toEqual(['daarlig.json', 'godt.json'])
  })
})
