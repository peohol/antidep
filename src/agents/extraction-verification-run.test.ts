import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

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
  /** Inndatamanifestet kjøringen ble åpnet med, slik proveniensen fikk det. */
  readonly openedWith: (Record<string, unknown> | null)[]
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
  const openedWith: (Record<string, unknown> | null)[] = []

  return {
    registered,
    completions,
    openedWith,
    beginRun: (_premises, inputManifest) => {
      openedWith.push(inputManifest)
      return Promise.resolve(RUN_ID)
    },
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
    created_by_actor_id: item.createdByActorId,
    created_by_actor_key: item.createdByActorKey,
    extraction_method: item.extractionMethod,
    content_hash: item.contentHash,
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
            representation: item.sourceVersion.representation,
            document:
              item.sourceVersion.document === null
                ? null
                : {
                    sha256: item.sourceVersion.document.sha256,
                    byte_size: item.sourceVersion.document.byteSize,
                    media_type: item.sourceVersion.document.mediaType,
                    text_extraction: {
                      tool: item.sourceVersion.document.textExtraction.tool,
                      tool_version: item.sourceVersion.document.textExtraction.toolVersion,
                      arguments: item.sourceVersion.document.textExtraction.arguments,
                    },
                  },
            has_storage_reference: item.sourceVersion.hasStorageReference,
          },
    // Kontrollgrunnlaget: forankringen og de to feltsettene kontrollen leser.
    field_groundings: item.fieldGroundings.map((grounding) => ({
      field_grounding_id: grounding.fieldGroundingId,
      check_field: grounding.checkField,
      source_excerpt: grounding.sourceExcerpt,
      source_locator: grounding.sourceLocator,
      justification: grounding.justification,
      created_at: grounding.createdAt,
      created_by_actor_id: grounding.createdByActorId,
    })),
    semantic_check_fields: item.semanticCheckFields,
    grounded_check_fields: item.groundedCheckFields,
    source_wide_absence_fields: item.sourceWideAbsenceFields,
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

/**
 * Et funn som lar seg reprodusere, og som IKKE fører noe globalt fravær.
 *
 * Standardfiksturen fører tidspunktet som `not_reported`, og et slikt fravær
 * krever en kildeomfattende gjennomlesning som ikke finnes i disse prøvene
 * (`absence-review.ts`). Da ville hver prøve om registrering blitt `uncertain`
 * av en grunn den ikke prøver. Selve halvdelen prøves for seg, lenger nede.
 */
async function matchingItem(
  extraction: Partial<VerificationItem['extraction']> = {},
): Promise<VerificationItem> {
  return verificationItemFixture({
    extraction: { timepointAvailability: 'not_applicable', ...extraction },
    sourceVersion: {
      sourceVersionId: '51000000-0000-4000-8000-000000000001',
      retrievedAt: '2026-09-01T00:00:00+00:00',
      retrievedFrom: 'https://eksempel.invalid/kilde',
      externalVersion: null,
      contentHash: await sourceVersionContentHash(FIXTURE_SOURCE_TEXT),
      representation: 'full_text',
      document: null,
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
          representation: 'full_text',
          document: null,
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
            representation: 'full_text',
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

// ----------------------------------------------------------------------------
// Funn kjøringen ikke kan skaffe dokumentet til
//
// Køen er sortert på created_at, og et overhoppet funn får ingen
// verifikasjonsrad — det blir derfor stående i køen. Talte de mot `--limit`,
// ville en kjøring uten dokumentene tatt de samme funnene om igjen hver gang, og
// aldri nådd fram til dem den faktisk kan kontrollere.
// ----------------------------------------------------------------------------

async function documentBoundItem(evidenceItemId: string): Promise<VerificationItem> {
  const item = await matchingItem()
  return {
    ...item,
    evidenceItemId,
    sourceVersion: {
      ...(item.sourceVersion as NonNullable<VerificationItem['sourceVersion']>),
      document: {
        sha256: `sha256:${'d'.repeat(64)}`,
        byteSize: 481253,
        mediaType: 'application/pdf',
        textExtraction: {
          tool: 'pdftotext',
          toolVersion: 'pdftotext 24.02.0',
          arguments: '-layout -enc UTF-8 -eol unix',
        },
      },
    },
  }
}

describe('runExtractionVerification — dokumentbundne funn uten dokumentet', () => {
  it('lar dem ikke bruke opp plassen --limit gir', async () => {
    const nettverksfunn = { ...(await matchingItem()), evidenceItemId: 'over-nett' }
    const api = fakeApi([
      await documentBoundItem('pdf-1'),
      await documentBoundItem('pdf-2'),
      nettverksfunn,
    ])

    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
      limit: 1,
    })

    // Uten fiksen ville de to PDF-funnene fylt grensen, og det tredje ville
    // aldri blitt kontrollert — hver eneste kjøring, i det uendelige.
    expect(api.registered.map((row) => row.evidenceItemId)).toEqual(['over-nett'])
    expect(
      report.items.filter((item) => item.decision === 'skipped').map((item) => item.evidenceItemId),
    ).toEqual(['pdf-1', 'pdf-2'])
  })

  it('sier hva som mangler, og fører det i kjøringens manifest', async () => {
    const api = fakeApi([await documentBoundItem('pdf-1')])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
    })

    expect(report.items[0]?.reason).toMatch(/ANTIDEP_DOCUMENT_DIR/)
    expect(api.registered).toEqual([])
    expect(api.completions[0]?.outputManifest?.['skipped_without_document']).toBe(1)
  })

  it('kontrollerer dem når dokumentet ligger i katalogen', async () => {
    const api = fakeApi([await documentBoundItem('pdf-1')])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      documents: () =>
        Promise.resolve({
          status: 'ok',
          document: {
            path: '/lager/d.pdf',
            bytes: new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d]),
            digest: `sha256:${'d'.repeat(64)}`,
            byteSize: 481253,
            mediaType: 'application/pdf',
          },
        }),
      runTool: () =>
        Promise.resolve({ status: 'ran', exitCode: 0, stdout: FIXTURE_SOURCE_TEXT, stderr: '' }),
    })

    expect(report.items[0]?.decision).toBe('registered')
    expect(api.registered).toHaveLength(1)
  })
})

// ----------------------------------------------------------------------------
// Den kildeomfattende halvdelen, gjennom hele kjøreren
//
// To trinn med en fil imellom: kjøringen legger igjen spørsmålet, en aktør uten
// legitimasjon svarer, og neste kjøring lar svaret avgjøre. Prøvene under er
// den ene ende-til-ende-prøven på at `source_wide_absence` faktisk kan dekkes —
// og på at den ikke blir dekket av et søk alene (issue #74).
// ----------------------------------------------------------------------------

const kataloger: string[] = []

function katalog(): string {
  const path = mkdtempSync(join(tmpdir(), 'antidep-kjoring-'))
  kataloger.push(path)
  return path
}

afterEach(() => {
  for (const path of kataloger.splice(0)) {
    rmSync(path, { recursive: true, force: true })
  }
})

/** En kildetekst uten noe konfidensintervall noe sted. */
const UTEN_INTERVALL = FIXTURE_SOURCE_TEXT.replace(' (95% CI 0.4 to 2.6)', '')

/**
 * Et funn som fører konfidensintervallet som ikke rapportert i kilden.
 *
 * Utdragene følger med: fiksturens eget resultatutdrag gjengir intervallet, og
 * et utdrag som ikke står i teksten, ville felt raden på noe annet enn det
 * prøvene her handler om.
 */
const UTEN_KI = {
  ciLower: null,
  ciUpper: null,
  ciLevelPercent: null,
  confidenceIntervalAvailability: 'not_reported',
  rawExtraction: {
    metode:
      'Sertraline patients (N = 284) with major depressive disorder were randomised. ' +
      'Fluoxetine was the comparator.',
    resultat:
      'Sertraline-treated patients with major depressive disorder had a mean weight ' +
      'change of 1.5 kg',
  },
} as const

describe('runExtractionVerification — den kildeomfattende fraværskontrollen', () => {
  async function itemUtenKi(): Promise<VerificationItem> {
    return verificationItemFixture({
      extraction: { timepointAvailability: 'not_applicable', ...UTEN_KI },
      sourceVersion: {
        sourceVersionId: '51000000-0000-4000-8000-000000000001',
        retrievedAt: '2026-09-01T00:00:00+00:00',
        retrievedFrom: 'https://eksempel.invalid/kilde',
        externalVersion: null,
        contentHash: await sourceVersionContentHash(UTEN_INTERVALL),
        representation: 'full_text',
        document: null,
        hasStorageReference: false,
      },
    })
  }

  async function hent(): Promise<RetrieveLike> {
    const hash = await sourceVersionContentHash(UTEN_INTERVALL)
    return retrieveFixture({ content: UTEN_INTERVALL, hash })
  }

  it('registrerer ingen dekning når ingen gjennomlesning foreligger', async () => {
    const api = fakeApi([await itemUtenKi()])
    await runExtractionVerification({ api, premises: PREMISSER, retrieve: await hent() })
    expect(api.registered[0]?.checkedFields).not.toContain('source_wide_absence')
    expect(api.registered[0]?.outcome).toBe('uncertain')
  })

  it('legger igjen spørsmålet uten å registrere noe', async () => {
    const rot = katalog()
    const item = await itemUtenKi()
    const api = fakeApi([item])
    const report = await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve: await hent(),
      absencePrompts: rot,
    })

    expect(report.runStatus).toBe('aborted')
    expect(api.registered).toHaveLength(0)
    const prompt = readFileSync(join(rot, item.evidenceItemId, 'prompt.txt'), 'utf8')
    expect(prompt).toMatch(/confidence_interval/)
    expect(report.items[0]?.absencePromptDirectory).toBe(join(rot, item.evidenceItemId))
  })

  it('dekker feltet når svaret gjelder nøyaktig den teksten kontrollen hentet', async () => {
    const rot = katalog()
    const item = await itemUtenKi()
    const retrieve = await hent()

    await runExtractionVerification({
      api: fakeApi([item]),
      premises: PREMISSER,
      retrieve,
      absencePrompts: rot,
    })

    const forespørsel = JSON.parse(
      readFileSync(join(rot, item.evidenceItemId, 'forespoersel.json'), 'utf8'),
    ) as { request_digest: string }
    writeFileSync(
      join(rot, item.evidenceItemId, 'svar.json'),
      JSON.stringify({
        answer_version: 'antidep/model-answer@1',
        request_digest: forespørsel.request_digest,
        identity: { provider: 'test', model: 'lesing', model_version: '1' },
        answered_at: '2026-09-11T09:00:00Z',
        draft: {
          review_version: 'antidep/source-wide-absence-review@1',
          evidence_item_id: item.evidenceItemId,
          fields: [
            {
              check_field: 'confidence_interval',
              verdict: 'absent',
              rationale: 'Gikk gjennom hele teksten og fant ingen presisjonsangivelse.',
            },
          ],
        },
      }),
      'utf8',
    )

    const api = fakeApi([item])
    await runExtractionVerification({
      api,
      premises: PREMISSER,
      retrieve,
      absenceReviews: rot,
    })
    expect(api.registered[0]?.checkedFields).toContain('source_wide_absence')
  })

  // Proveniensen skal si om halvdelen i det hele tatt KUNNE bli dekket i denne
  // kjøringen. Ellers ser et udekket felt ut som et funn.
  it('fører i proveniensen om gjennomlesninger var med', async () => {
    const api = fakeApi([await itemUtenKi()])
    await runExtractionVerification({ api, premises: PREMISSER, retrieve: await hent() })
    expect(api.completions[0]?.status).toBe('succeeded')
    expect(api.openedWith[0]?.source_wide_absence_reviews).toBe('none')

    const med = fakeApi([await itemUtenKi()])
    await runExtractionVerification({
      api: med,
      premises: PREMISSER,
      retrieve: await hent(),
      absenceReviews: katalog(),
    })
    expect(med.openedWith[0]?.source_wide_absence_reviews).toBe('provided')
  })
})
