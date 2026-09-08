import { describe, expect, it } from 'vitest'

import type {
  AgentRunPremises,
  ExtractionVerificationApi,
  RegisterVerificationArgs,
} from './agent-api'
import { runExtractionVerification, type RetrieveLike } from './extraction-verification-run'
import { sourceVersionContentHash } from './content-hash'
import { FIXTURE_SOURCE_TEXT, verificationItemFixture } from './test-support'
import type { VerificationItem } from './verification-input'

const PREMISSER: AgentRunPremises = {
  provider: 'antidep',
  model: 'deterministic-extraction-check',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'extraction-verification/deterministic/1',
  pipelineVersion: 'antidep-evidence/1',
}

const RUN_ID = '11111111-1111-4111-8111-111111111111'

interface FakeApi extends ExtractionVerificationApi {
  readonly registered: RegisterVerificationArgs[]
  readonly completions: {
    status: string
    outputManifest: Record<string, unknown> | null
    failureReason: string | null
  }[]
}

/**
 * Databasen som en dobbel. Hele orkestreringen kan dermed prøves uten stack,
 * og hvert kall som faktisk ble gjort, er observerbart — det er kallene som er
 * kontrakten, ikke returverdiene.
 */
function fakeApi(items: readonly VerificationItem[], overrides: Partial<FakeApi> = {}): FakeApi {
  const registered: RegisterVerificationArgs[] = []
  const completions: FakeApi['completions'] = []

  return {
    registered,
    completions,
    beginRun: () => Promise.resolve(RUN_ID),
    readInput: () =>
      Promise.resolve({
        agent_run_id: RUN_ID,
        verifier_actor_id: '22222222-2222-4222-8222-222222222222',
        items: items.map((item) => toPayload(item)),
      }),
    registerVerification: (args) => {
      registered.push(args)
      return Promise.resolve(`ver-${String(registered.length)}`)
    },
    completeRun: (_runId, status, outputManifest, failureReason) => {
      completions.push({ status, outputManifest, failureReason })
      return Promise.resolve()
    },
    ...overrides,
  }
}

/** Speiler formen migrasjon 005h dokumenterer. */
function toPayload(item: VerificationItem): Record<string, unknown> {
  const e = item.extraction
  return {
    evidence_item_id: item.evidenceItemId,
    created_by_actor_key: item.createdByActorKey,
    created_at: '2026-09-01T00:00:00+00:00',
    verifications_by_this_actor: item.verificationsByThisActor,
    source: {
      source_id: item.sourceId,
      source_type: 'journal_article',
      title: item.sourceTitle,
      authors_or_issuer: 'Testforfatter m.fl.',
      publisher_or_journal: 'Testtidsskrift',
      publication_date: '2024-01-01',
      publication_date_precision: 'day',
      source_status: 'active',
      status_note: null,
    },
    source_version:
      item.sourceVersion === null
        ? null
        : {
            source_version_id: item.sourceVersion.sourceVersionId,
            retrieved_at: item.sourceVersion.retrievedAt,
            retrieved_from: item.sourceVersion.retrievedFrom,
            external_version: item.sourceVersion.externalVersion,
            content_hash: item.sourceVersion.contentHash,
            has_storage_reference: item.sourceVersion.hasStorageReference,
          },
    extraction: {
      design_code: e.designCode,
      population_label: e.populationLabel,
      population_availability: e.populationAvailability,
      population_detail: e.populationDetail,
      sample_size: e.sampleSize,
      sample_size_availability: e.sampleSizeAvailability,
      intervention_drug_name: e.interventionDrugName,
      intervention_detail: e.interventionDetail,
      comparator_kind: e.comparatorKind,
      comparator_drug_name: e.comparatorDrugName,
      comparator_detail: e.comparatorDetail,
      outcome_label: e.outcomeLabel,
      outcome_detail: e.outcomeDetail,
      timepoint_availability: e.timepointAvailability,
      reported_direction: e.reportedDirection,
      effect_measure: e.effectMeasure,
      estimate: e.estimate,
      estimate_unit: e.estimateUnit,
      estimate_availability: e.estimateAvailability,
      ci_lower: e.ciLower,
      ci_upper: e.ciUpper,
      ci_level_percent: e.ciLevelPercent,
      confidence_interval_availability: e.confidenceIntervalAvailability,
      limitations_text: e.limitationsText,
      source_locator: e.sourceLocator,
      raw_extraction: e.rawExtraction,
    },
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

async function matchingItem(): Promise<VerificationItem> {
  return verificationItemFixture({
    sourceVersion: {
      sourceVersionId: '51000000-0000-4000-8000-000000000001',
      retrievedAt: '2026-09-01T00:00:00+00:00',
      retrievedFrom: 'https://eksempel.invalid/kilde',
      externalVersion: null,
      contentHash: await sourceVersionContentHash(FIXTURE_SOURCE_TEXT),
      hasStorageReference: false,
    },
  })
}

describe('runExtractionVerification — den lykkede stien', () => {
  it('registrerer en verifikasjon og lukker kjøringen som succeeded', async () => {
    const api = fakeApi([await matchingItem()])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
    })

    expect(report.runStatus).toBe('succeeded')
    expect(api.registered).toHaveLength(1)
    expect(api.completions[0]?.status).toBe('succeeded')
  })

  it('oppgir verifiable_representation som kildegrunnlag', async () => {
    const api = fakeApi([await matchingItem()])
    await runExtractionVerification({ api, premises: PREMISSER, retrieve: retrieveFixture() })
    expect(api.registered[0]?.sourceAccess).toBe('verifiable_representation')
  })

  it('sender kontrollens egne felter videre uendret', async () => {
    const api = fakeApi([await matchingItem()])
    await runExtractionVerification({ api, premises: PREMISSER, retrieve: retrieveFixture() })
    expect(api.registered[0]?.checkedFields).toContain('source_locator')
    expect(api.registered[0]?.outcome).toBe('verified')
    expect(api.registered[0]?.findings).toBeNull()
  })
})

describe('runExtractionVerification — når ingenting skal registreres', () => {
  it('registrerer ingenting for et funn uten kildeversjon', async () => {
    const api = fakeApi([verificationItemFixture({ sourceVersion: null })])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
    })

    expect(api.registered).toHaveLength(0)
    expect(report.items[0]).toMatchObject({ decision: 'skipped' })
    expect(report.items[0]?.reason).toContain('ingen registrert kildeversjon')
  })

  it('registrerer ingenting når kildeversjonen mangler fingeravtrykk', async () => {
    const api = fakeApi([
      verificationItemFixture({
        sourceVersion: {
          sourceVersionId: '51000000-0000-4000-8000-000000000002',
          retrievedAt: '2026-09-01T00:00:00+00:00',
          retrievedFrom: 'https://eksempel.invalid/sporet-besok',
          externalVersion: null,
          contentHash: null,
          hasStorageReference: false,
        },
      }),
    ])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
    })

    expect(api.registered).toHaveLength(0)
    expect(report.items[0]?.reason).toContain('content_hash')
  })

  it('registrerer ingenting når kilden ikke lot seg hente', async () => {
    const api = fakeApi([await matchingItem()])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: () => Promise.resolve({ status: 'error', message: 'Kilden svarte 503.' }),
    })

    expect(api.registered).toHaveLength(0)
    expect(report.items[0]?.reason).toBe('Kilden svarte 503.')
  })

  // Den viktigste av dem: en rad må oppgi et kildegrunnlag, og ingen av de tre
  // verdiene beskriver «jeg så en annen utgave enn den registrerte» sant.
  it('registrerer ingenting når kilden har endret seg siden ekstraksjonen', async () => {
    const api = fakeApi([await matchingItem()])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture({ content: 'noe helt annet', hash: `sha256:${'b'.repeat(64)}` }),
    })

    expect(api.registered).toHaveLength(0)
    expect(report.items[0]?.reason).toContain('Kilden har endret seg')
  })

  it('registrerer ingenting når svaret ikke er ren UTF-8', async () => {
    const api = fakeApi([await matchingItem()])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: (url) =>
        Promise.resolve({
          status: 'ok',
          representation: {
            url,
            status: 200,
            contentType: null,
            content: FIXTURE_SOURCE_TEXT,
            byteLength: 1,
            contentHash: `sha256:${'a'.repeat(64)}`,
            bytesAreUtf8: false,
          },
        }),
    })

    expect(api.registered).toHaveLength(0)
    expect(report.items[0]?.reason).toContain('ikke ren UTF-8')
  })

  // Kildeinnhold er utrygg ekstern data. Én kilde som får kontrollen til å
  // kaste, skal ikke stoppe funnene bak seg i køen — den blir ett overhoppet
  // funn med en årsak, og resten kontrolleres.
  it('lar én kilde som feiler uventet, ikke stoppe resten av køen', async () => {
    const first = await matchingItem()
    const api = fakeApi([first, { ...first, evidenceItemId: 'det-andre-funnet' }])
    let call = 0
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: (url) => {
        call += 1
        if (call === 1) {
          throw new Error('noe uventet i den første kilden')
        }
        return retrieveFixture()(url)
      },
    })

    expect(report.runStatus).toBe('succeeded')
    expect(report.items[0]).toMatchObject({ decision: 'skipped' })
    expect(report.items[0]?.reason).toContain('noe uventet i den første kilden')
    expect(report.items[1]).toMatchObject({ decision: 'registered' })
    expect(api.registered).toHaveLength(1)
  })

  it('lar en overhoppet kontroll stå i kjøringens outputmanifest', async () => {
    const api = fakeApi([verificationItemFixture({ sourceVersion: null })])
    await runExtractionVerification({ api, premises: PREMISSER, retrieve: retrieveFixture() })
    expect(api.completions[0]?.outputManifest).toMatchObject({ registered: 0, skipped: 1 })
  })
})

describe('runExtractionVerification — tørrkjøring', () => {
  it('registrerer ingenting og lukker kjøringen som aborted', async () => {
    const api = fakeApi([await matchingItem()])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
      dryRun: true,
    })

    expect(api.registered).toHaveLength(0)
    expect(report.runStatus).toBe('aborted')
    expect(api.completions[0]?.failureReason).toContain('Tørrkjøring')
  })

  it('rapporterer likevel hva kontrollen ville konkludert med', async () => {
    const api = fakeApi([await matchingItem()])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
      dryRun: true,
    })
    expect(report.items[0]).toMatchObject({ decision: 'previewed', outcome: 'verified' })
  })
})

describe('runExtractionVerification — kjøringen lukkes alltid', () => {
  // En avvist registrering er den ene radens problem, ikke køens: uten denne
  // innkapslingen ville én verdi basen ikke tar imot, felt hele kjøringen, og
  // de øvrige funnene ville stått ukontrollert av en grunn som ikke er deres.
  it('lar en avvist registrering stoppe det ene funnet, ikke hele kjøringen', async () => {
    const api = fakeApi([await matchingItem()], {
      registerVerification: () => Promise.reject(new Error('avvist av databasen')),
    })

    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
    })

    expect(report.items[0]).toMatchObject({ decision: 'skipped' })
    expect(report.items[0]?.reason).toContain('avvist av databasen')
    expect(api.completions[0]?.status).toBe('succeeded')
  })

  it('avviser et svar som ikke har den dokumenterte formen', async () => {
    const api = fakeApi([], { readInput: () => Promise.resolve({ items: 'ikke en liste' }) })
    await expect(
      runExtractionVerification({ api, premises: PREMISSER, retrieve: retrieveFixture() }),
    ).rejects.toThrow(/mangler listen items/)
    expect(api.completions[0]?.status).toBe('failed')
  })
})

describe('runExtractionVerification — avgrensning', () => {
  it('tar høyst så mange funn som --limit sier', async () => {
    const first = await matchingItem()
    const api = fakeApi([first, { ...first, evidenceItemId: 'annet' }])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
      limit: 1,
    })
    expect(report.items).toHaveLength(1)
  })
})
