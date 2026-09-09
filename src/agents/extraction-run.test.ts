// ============================================================================
// Ekstraksjonskjøringen, prøvd uten database og uten nett
//
// Det som prøves er arbeidsdelingen: kjøringen skriver ingenting den ikke har
// hentet og kontrollert, og alt den gjør er sporbart i en agentkjøring.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { AgentApiError } from './agent-api'
import type {
  AgentRunPremises,
  EvidenceExtractionApi,
  RegisterAgentExtractionArgs,
} from './agent-api'
import { sourceVersionContentHash } from './content-hash'
import {
  EXTRACTION_PROPOSAL_VERSION,
  parseExtractionProposal,
  type ExtractionProposal,
} from './extraction-proposal'
import { runEvidenceExtraction, type RetrieveLike } from './extraction-run'
import { FIXTURE_SOURCE_TEXT } from './test-support'

const PREMISSER: AgentRunPremises = {
  provider: 'antidep',
  model: 'proposal-grounded-extraction',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'evidence-extraction/proposal/1',
  pipelineVersion: 'antidep-evidence/1',
}

const RUN_ID = '11111111-1111-4111-8111-111111111111'
const ITEM_ID = '33333333-3333-4333-8333-333333333333'
const EXISTING_ITEM_ID = '44444444-4444-4444-8444-444444444444'

interface FakeApi extends EvidenceExtractionApi {
  readonly registered: RegisterAgentExtractionArgs[]
  readonly manifests: Record<string, unknown>[]
  readonly completions: {
    status: string
    outputManifest: Record<string, unknown> | null
    failureReason: string | null
  }[]
}

function fakeApi(overrides: Partial<FakeApi> = {}): FakeApi {
  const registered: RegisterAgentExtractionArgs[] = []
  const manifests: Record<string, unknown>[] = []
  const completions: FakeApi['completions'] = []

  return {
    registered,
    manifests,
    completions,
    beginRun: (_premises, inputManifest) => {
      manifests.push(inputManifest)
      return Promise.resolve(RUN_ID)
    },
    registerExtraction: (args) => {
      registered.push(args)
      return Promise.resolve(ITEM_ID)
    },
    completeRun: (_runId, status, outputManifest, failureReason) => {
      completions.push({ status, outputManifest, failureReason })
      return Promise.resolve()
    },
    ...overrides,
  }
}

function retrieveFixture(overrides: { content?: string; hash?: string } = {}): RetrieveLike {
  return async (url) => ({
    status: 'ok',
    representation: {
      url,
      status: 200,
      contentType: 'text/xml',
      content: overrides.content ?? FIXTURE_SOURCE_TEXT,
      byteLength: (overrides.content ?? FIXTURE_SOURCE_TEXT).length,
      contentHash: overrides.hash ?? (await sourceVersionContentHash(FIXTURE_SOURCE_TEXT)),
      bytesAreUtf8: true,
    },
  })
}

async function proposal(
  overrides: { excerpt?: string; hash?: string } = {},
): Promise<ExtractionProposal> {
  return parseExtractionProposal({
    proposal_version: EXTRACTION_PROPOSAL_VERSION,
    source_id: '50000000-0000-4000-8000-000000000001',
    source_version_id: '51000000-0000-4000-8000-000000000001',
    retrieved_from: 'https://eksempel.invalid/kilde',
    content_hash: overrides.hash ?? (await sourceVersionContentHash(FIXTURE_SOURCE_TEXT)),
    extraction: {
      design_code: 'randomized_controlled_trial',
      population_availability: 'not_reported',
      population_detail: 'Voksne med depressiv lidelse.',
      sample_size_availability: 'reported_value',
      sample_size: 284,
      intervention_drug_id: '40000000-0000-4000-8000-000000000001',
      comparator_kind: 'none',
      outcome_concept_id: '41000000-0000-4000-8000-000000000001',
      outcome_detail: 'Gjennomsnittlig vektendring.',
      timepoint_availability: 'not_reported',
      reported_direction: 'increase',
      estimate: '1.5',
      estimate_unit: 'kg',
      estimate_availability: 'reported_value',
      confidence_interval_availability: 'not_reported',
      source_locator: 'Sammendrag, resultatavsnittet',
      source_quote: 'Sertraline patients (N = 284) with major',
    },
    field_groundings: [
      {
        check_field: 'intervention_arm',
        source_excerpt:
          overrides.excerpt ?? 'Sertraline patients (N = 284) with major depressive disorder',
        source_locator: 'Sammendrag, METHODS',
        justification: 'Armen er navngitt i metodeavsnittet.',
      },
      {
        check_field: 'sample_size',
        source_excerpt: 'Sertraline patients (N = 284)',
        source_locator: 'Sammendrag, METHODS',
        justification: 'Utvalgsstørrelsen står ved siden av armen.',
      },
    ],
  })
}

describe('runEvidenceExtraction — den lykkede stien', () => {
  it('registrerer ekstraksjonen og lukker kjøringen', async () => {
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
      premises: PREMISSER,
      proposal: await proposal(),
      retrieve: retrieveFixture(),
    })

    expect(report.runStatus).toBe('succeeded')
    expect(report.decision).toBe('registered')
    expect(report.evidenceItemId).toBe(ITEM_ID)
    expect(api.registered).toHaveLength(1)
    expect(api.completions[0]?.status).toBe('succeeded')
  })

  it('sender forankringen videre uendret, felt for felt', async () => {
    const api = fakeApi()
    await runEvidenceExtraction({
      api,
      premises: PREMISSER,
      proposal: await proposal(),
      retrieve: retrieveFixture(),
    })

    expect(api.registered[0]?.fieldGroundings.map((g) => g.checkField)).toEqual([
      'intervention_arm',
      'sample_size',
    ])
    expect(api.registered[0]?.sourceVersionId).toBe('51000000-0000-4000-8000-000000000001')
  })

  // §74.31: en KI-operasjon uten proveniens er ikke en KI-operasjon Antidep
  // kjenner. Kjøringen skal si hva den bygde på.
  it('registrerer hva kjøringen bygde på', async () => {
    const api = fakeApi()
    await runEvidenceExtraction({
      api,
      premises: PREMISSER,
      proposal: await proposal(),
      retrieve: retrieveFixture(),
    })

    expect(api.manifests[0]).toMatchObject({
      source_version_id: '51000000-0000-4000-8000-000000000001',
      retrieved_from: 'https://eksempel.invalid/kilde',
      grounded_fields: ['intervention_arm', 'sample_size'],
    })
  })
})

describe('runEvidenceExtraction — det den nekter å registrere', () => {
  // Generatoren skriver ikke noe den vet er galt. Verifikatoren er fortsatt en
  // egen operasjon, av en annen aktør (ANTIDEP_CONSTITUTION.md §10).
  it('registrerer ingenting når et utdrag ikke står i representasjonen', async () => {
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
      premises: PREMISSER,
      proposal: await proposal({ excerpt: 'Patients received paroxetine only.' }),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('skipped')
    expect(report.reason).toContain('intervention_arm')
    expect(api.registered).toHaveLength(0)
    expect(api.completions[0]?.status).toBe('aborted')
    // agent_runs_status_shape_check godtar ikke en avsluttet kjøring uten et
    // svar på hvorfor den ble stoppet.
    expect(api.completions[0]?.failureReason).toContain('intervention_arm')
  })

  it('registrerer ingenting når representasjonen ikke er den registrerte utgaven', async () => {
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
      premises: PREMISSER,
      proposal: await proposal({ hash: `sha256:${'0'.repeat(64)}` }),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('skipped')
    expect(report.reason).toContain('Kilden har endret seg')
    expect(api.registered).toHaveLength(0)
  })

  it('registrerer ingenting når kilden ikke lot seg hente', async () => {
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
      premises: PREMISSER,
      proposal: await proposal(),
      retrieve: () => Promise.resolve({ status: 'error', message: 'Tidsavbrudd mot kilden.' }),
    })

    expect(report.decision).toBe('skipped')
    expect(report.reason).toBe('Tidsavbrudd mot kilden.')
    expect(api.registered).toHaveLength(0)
  })

  it('kontrollerer men registrerer ingenting i en tørrkjøring', async () => {
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
      premises: PREMISSER,
      proposal: await proposal(),
      retrieve: retrieveFixture(),
      dryRun: true,
    })

    expect(report.decision).toBe('previewed')
    expect(api.registered).toHaveLength(0)
    // Også en tørrkjøring er sporbar.
    expect(api.completions[0]?.status).toBe('aborted')
    expect(api.completions[0]?.outputManifest).toMatchObject({ dry_run: true })
    expect(api.completions[0]?.failureReason).toMatch(/Tørrkjøring/)
  })

  // En kjøring som ble stående åpen, ville blokkert den neste.
  it('lukker kjøringen som failed når registreringen avvises', async () => {
    const api = fakeApi({
      registerExtraction: () =>
        Promise.reject(new Error('api.register_agent_extraction ble avvist')),
    })

    await expect(
      runEvidenceExtraction({
        api,
        premises: PREMISSER,
        proposal: await proposal(),
        retrieve: retrieveFixture(),
      }),
    ).rejects.toThrow('avvist')
    expect(api.completions[0]?.status).toBe('failed')
  })

  // Den ene forventede avvisningen: raden finnes allerede, med nøyaktig det
  // samme innholdet. evidence_items_content_hash_key dekker hele radens
  // faglige innhold, så det samme forslaget kjørt om igjen skriver ingenting —
  // og det er nettopp det som gjør kjøringen idempotent.
  it('rapporterer en dublett som already_registered framfor som en feil', async () => {
    const api = fakeApi({
      registerExtraction: () =>
        Promise.reject(
          new AgentApiError(
            'api.register_agent_extraction',
            'Nøyaktig det samme evidensfunnet er allerede registrert.',
            '23505',
            `evidence_item_id=${EXISTING_ITEM_ID}`,
          ),
        ),
    })

    const report = await runEvidenceExtraction({
      api,
      premises: PREMISSER,
      proposal: await proposal(),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('already_registered')
    expect(report.runStatus).toBe('aborted')
    expect(report.evidenceItemId).toBeUndefined()
    // Databasen navngir raden som kolliderte, slått opp med den samme
    // identiteten UNIQUE-regelen bruker (migrasjon 007h). Uten den måtte en
    // kaller som vil fullføre en avbrutt kjøring, gjette hvilken rad det var.
    expect(report.existingEvidenceItemId).toBe(EXISTING_ITEM_ID)
    expect(api.completions[0]?.outputManifest).toMatchObject({ already_registered: true })
    // agent_runs_status_shape_check godtar ikke en avsluttet kjøring uten et
    // svar på hvorfor den ble stoppet.
    expect(api.completions[0]?.failureReason).toContain('allerede registrert')
  })

  // En annen avvisning er fortsatt en feil. Uten dette skillet ville en
  // fremmednøkkelfeil sett ut som «allerede registrert», og kjøringen ville
  // rapportert suksess for noe som aldri ble skrevet.
  it('skiller en dublett fra enhver annen avvisning', async () => {
    const api = fakeApi({
      registerExtraction: () =>
        Promise.reject(
          new AgentApiError(
            'api.register_agent_extraction',
            'Kildeversjonen finnes ikke.',
            '23503',
            null,
          ),
        ),
    })

    await expect(
      runEvidenceExtraction({
        api,
        premises: PREMISSER,
        proposal: await proposal(),
        retrieve: retrieveFixture(),
      }),
    ).rejects.toThrow('Kildeversjonen finnes ikke')
    expect(api.completions[0]?.status).toBe('failed')
  })
})
