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
import { parseExtractionAssignment } from './extraction-assignment'
import { runEvidenceExtraction, type RetrieveLike } from './extraction-run'
import { ANTIDEP_EVIDENCE_PIPELINE_VERSION, EVIDENCE_EXTRACTION_PREMISES } from './pipeline-version'
import { FIXTURE_SOURCE_TEXT } from './test-support'

const RUN_ID = '11111111-1111-4111-8111-111111111111'
const ITEM_ID = '33333333-3333-4333-8333-333333333333'
const EXISTING_ITEM_ID = '44444444-4444-4444-8444-444444444444'

interface FakeApi extends EvidenceExtractionApi {
  readonly registered: RegisterAgentExtractionArgs[]
  readonly premises: AgentRunPremises[]
  readonly manifests: Record<string, unknown>[]
  readonly completions: {
    status: string
    outputManifest: Record<string, unknown> | null
    failureReason: string | null
  }[]
}

function fakeApi(overrides: Partial<FakeApi> = {}): FakeApi {
  const registered: RegisterAgentExtractionArgs[] = []
  const premises: AgentRunPremises[] = []
  const manifests: Record<string, unknown>[] = []
  const completions: FakeApi['completions'] = []

  return {
    registered,
    premises,
    manifests,
    completions,
    beginRun: (runPremises, inputManifest) => {
      premises.push(runPremises)
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
  overrides: {
    excerpt?: string
    hash?: string
    generatedBy?: Record<string, unknown>
  } = {},
): Promise<ExtractionProposal> {
  return parseExtractionProposal({
    proposal_version: EXTRACTION_PROPOSAL_VERSION,
    generated_by: overrides.generatedBy ?? {
      producer: 'model',
      provider: 'antidep',
      model: 'opptaksmodell',
      model_version: '1',
      prompt_template_version: 'evidence-extraction/proposal-drafting/1',
      drafted_at: '2026-09-15T09:00:00Z',
    },
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

/** Oppdraget forslaget over holder seg innenfor. */
async function oppdrag(overrides: Record<string, unknown> = {}) {
  return parseExtractionAssignment({
    assignment_version: 'antidep/extraction-assignment@1',
    source_id: '50000000-0000-4000-8000-000000000001',
    source_version_id: '51000000-0000-4000-8000-000000000001',
    retrieved_from: 'https://eksempel.invalid/kilde',
    content_hash: await sourceVersionContentHash(FIXTURE_SOURCE_TEXT),
    drugs: [{ drug_id: '40000000-0000-4000-8000-000000000001', label: 'sertralin' }],
    outcomes: [
      { outcome_concept_id: '41000000-0000-4000-8000-000000000001', label: 'vektendring' },
    ],
    populations: [],
    ...overrides,
  })
}

// ----------------------------------------------------------------------------
// Kontrollen mot oppdraget
//
// Avgrensningen mot katalogen er den ene kontrollen den ordrette ikke kan gjøre:
// et utdrag kan stå ordrett i kilden og likevel være ført på feil virkestoff.
// Den ble gjort i modell-leddet, men *før* forslaget ble overlevert fra en økt
// som leste utrygt eksternt innhold — så den må gjøres om igjen her, mot
// redaktørens egen oppdragsfil (EVIDENCE_PIPELINE.md §63).
// ----------------------------------------------------------------------------

describe('runEvidenceExtraction — kontrollen mot oppdraget', () => {
  it('registrerer et forslag som holder seg innenfor oppdraget', async () => {
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
      proposal: await proposal(),
      assignment: await oppdrag(),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('registered')
    expect(api.manifests[0]?.assignment_checked).toBe(true)
  })

  it('fører i manifestet når kjøringen ikke hadde noe oppdrag å kontrollere mot', async () => {
    const api = fakeApi()
    await runEvidenceExtraction({ api, proposal: await proposal(), retrieve: retrieveFixture() })

    expect(api.manifests[0]?.assignment_checked).toBe(false)
  })

  it('registrerer ingenting når virkestoffet ikke står i oppdraget', async () => {
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
      proposal: await proposal(),
      assignment: await oppdrag({
        drugs: [{ drug_id: '40000000-0000-4000-8000-0000000000ff', label: 'et annet virkestoff' }],
      }),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('skipped')
    expect(report.reason).toMatch(/intervention_drug_id/)
    expect(api.registered).toEqual([])
    expect(api.completions[0]?.status).toBe('aborted')
  })

  it('registrerer ingenting når endepunktet ikke står i oppdraget', async () => {
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
      proposal: await proposal(),
      assignment: await oppdrag({
        outcomes: [
          { outcome_concept_id: '41000000-0000-4000-8000-0000000000ff', label: 'et naboendepunkt' },
        ],
      }),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('skipped')
    expect(report.reason).toMatch(/outcome_concept_id/)
    expect(api.registered).toEqual([])
  })

  it('registrerer ingenting når forslaget peker på en annen kildeversjon enn oppdraget', async () => {
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
      proposal: await proposal(),
      assignment: await oppdrag({ source_version_id: '51000000-0000-4000-8000-0000000000ff' }),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('skipped')
    expect(report.reason).toMatch(/source_version_id/)
    expect(api.registered).toEqual([])
  })

  it('kontrollerer oppdraget før kilden i det hele tatt søkes i', async () => {
    // Et forslag utenfor oppdraget skal avvises selv om utdragene er ordrett
    // riktige. Det er nettopp den kombinasjonen kontrollen finnes for.
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
      proposal: await proposal(),
      assignment: await oppdrag({
        drugs: [{ drug_id: '40000000-0000-4000-8000-0000000000ff', label: 'et annet virkestoff' }],
      }),
      retrieve: retrieveFixture(),
    })

    expect(report.reason).not.toMatch(/ordrett/)
  })
})

describe('runEvidenceExtraction — den lykkede stien', () => {
  it('registrerer ekstraksjonen og lukker kjøringen', async () => {
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
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
      proposal: await proposal(),
      retrieve: retrieveFixture(),
    })

    expect(api.manifests[0]).toMatchObject({
      source_version_id: '51000000-0000-4000-8000-000000000001',
      retrieved_from: 'https://eksempel.invalid/kilde',
      grounded_fields: ['intervention_arm', 'sample_size'],
      extraction_method: 'ai_assisted',
    })
  })
})

// ---------------------------------------------------------------------------
// Kjøringens premisser er kjøringens, og erklæringen er forslagets
// ---------------------------------------------------------------------------

describe('runEvidenceExtraction — hvem forslaget sier laget det', () => {
  // Kjøringen er ikke leddet som leste artikkelen: den henter, kontrollerer og
  // registrerer, deterministisk, på det tidspunktet noen kjører kommandoen. Lot
  // premissene si hvilken modell som laget utkastet, ville `started_at` og
  // manifestene beskrevet noe annet enn det som skjedde
  // (ANTIDEP_CONSTITUTION.md §20, EVIDENCE_PIPELINE.md §65).
  it('registrerer kjøringen med sine egne premisser, ikke med modellens', async () => {
    const api = fakeApi()
    await runEvidenceExtraction({
      api,
      proposal: await proposal({
        generatedBy: {
          producer: 'model',
          provider: 'en-leverandør',
          model: 'en-modell',
          model_version: '2026-09-15',
          prompt_template_version: 'evidence-extraction/proposal-drafting/1',
          drafted_at: '2026-09-15T09:00:00Z',
        },
      }),
      retrieve: retrieveFixture(),
    })

    expect(api.premises[0]).toEqual(EVIDENCE_EXTRACTION_PREMISES)
    expect(api.premises[0]?.pipelineVersion).toBe(ANTIDEP_EVIDENCE_PIPELINE_VERSION)
  })

  // Erklæringen står i manifestet — kolonnen for hva kjøringen fikk inn — med
  // utkastets eget tidspunkt og fingeravtrykket av forespørselen. Uten dem er
  // modelloperasjonen ikke identifiserbar i ettertid.
  it('fører forslagets erklæring ordrett i kjøringens manifest', async () => {
    const api = fakeApi()
    await runEvidenceExtraction({
      api,
      proposal: await proposal({
        generatedBy: {
          producer: 'model',
          provider: 'en-leverandør',
          model: 'en-modell',
          model_version: '2026-09-15',
          prompt_template_version: 'evidence-extraction/proposal-drafting/1',
          drafted_at: '2026-09-15T09:00:00Z',
          request_digest: `sha256:${'b'.repeat(64)}`,
        },
      }),
      retrieve: retrieveFixture(),
    })

    expect(api.manifests[0]?.['generated_by']).toEqual({
      producer: 'model',
      provider: 'en-leverandør',
      model: 'en-modell',
      model_version: '2026-09-15',
      prompt_template_version: 'evidence-extraction/proposal-drafting/1',
      drafted_at: '2026-09-15T09:00:00Z',
      request_digest: `sha256:${'b'.repeat(64)}`,
    })
  })

  // extraction_method sier hvordan raden ble til. En modell og et menneske er
  // ikke det samme, og raden skal ikke påstå at de er det (§12).
  it('registrerer et maskinutkast som ai_assisted og et menneskes forslag som manual', async () => {
    const maskin = fakeApi()
    await runEvidenceExtraction({
      api: maskin,
      proposal: await proposal(),
      retrieve: retrieveFixture(),
    })
    expect(maskin.registered[0]?.extractionMethod).toBe('ai_assisted')

    const menneske = fakeApi()
    await runEvidenceExtraction({
      api: menneske,
      proposal: await proposal({
        generatedBy: {
          producer: 'human',
          provider: 'human',
          model: 'manuell-ekstraksjon',
          model_version: 'not_applicable',
          prompt_template_version: 'not_applicable',
          drafted_at: '2026-09-15T08:00:00Z',
        },
      }),
      retrieve: retrieveFixture(),
    })
    expect(menneske.registered[0]?.extractionMethod).toBe('manual')
  })
})

describe('runEvidenceExtraction — det den nekter å registrere', () => {
  // Generatoren skriver ikke noe den vet er galt. Verifikatoren er fortsatt en
  // egen operasjon, av en annen aktør (ANTIDEP_CONSTITUTION.md §10).
  it('registrerer ingenting når et utdrag ikke står i representasjonen', async () => {
    const api = fakeApi()
    const report = await runEvidenceExtraction({
      api,
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
        proposal: await proposal(),
        retrieve: retrieveFixture(),
      }),
    ).rejects.toThrow('Kildeversjonen finnes ikke')
    expect(api.completions[0]?.status).toBe('failed')
  })
})
