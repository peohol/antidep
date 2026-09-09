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
import { matchesProposal, runReextraction } from './reextraction-run'
import {
  FIXTURE_SOURCE_TEXT,
  sourceVersionFixture,
  verificationItemFixture,
  verificationItemPayload,
} from './test-support'
import type { VerificationItem } from './verification-input'
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
  readonly verified: Uuid[]
  readonly completions: { readonly run: Uuid; readonly status: string }[]
}

interface SpyOptions {
  readonly duplicate?: boolean
  /** Køen api.extraction_verification_input svarer med. Tom hvis utelatt. */
  readonly queue?: readonly VerificationItem[]
}

function spies(options: SpyOptions = {}): Spy {
  const registered: unknown[] = []
  const readInputFor: (Uuid | null)[] = []
  const verified: Uuid[] = []
  const completions: { run: Uuid; status: string }[] = []

  return {
    registered,
    readInputFor,
    verified,
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
        // Køen er tom hvis testen ikke oppgir noe: kontrollen av selve
        // kontrollen ligger i extraction-verification-run.test.ts og i
        // kjedeprøven. Det som prøves her, er hvilket funn den kjøres på.
        return Promise.resolve({
          agent_run_id: VERIFICATION_RUN_ID,
          verifier_actor_id: VERIFIER_ACTOR_ID,
          items: (options.queue ?? []).map(verificationItemPayload),
        })
      },
      registerVerification: (args) => {
        verified.push(args.evidenceItemId)
        return Promise.resolve(VERIFICATION_RUN_ID)
      },
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
    expect(report.unverified).toBe(0)
    expect(report.groundingConflicts).toBe(0)
    expect(spy.registered).toHaveLength(0)
    // Arbeidskøen er «funn denne verifikatoren ikke har kontrollert». At funnet
    // ikke ligger der, er derfor et bevis på at det allerede er kontrollert:
    // kjeden er komplett, og det er ingenting igjen å gjøre.
    expect(spy.readInputFor).toEqual([null])
    expect(spy.verified).toEqual([])
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

  // Registreringen og kontrollen er to skrivinger. Dør prosessen mellom dem,
  // finnes raden uten maskinbevis, og en ny kjøring får bare «dublett» tilbake —
  // uten en id å kontrollere. Da må funnet gjenfinnes i køen, ellers kan den
  // idempotente kjøringen aldri fullføre kjeden.
  it('fullfører kjeden når en tidligere kjøring rakk å registrere men ikke å kontrollere', async () => {
    const forslag = await proposal()
    const spy = spies({
      duplicate: true,
      queue: [
        verificationItemFixture({
          evidenceItemId: ITEM_ID,
          // Kildeversjonen må bære det avtrykket kilden faktisk gir, ellers
          // stopper kontrollen på fingeravtrykket og registrerer ingenting.
          sourceVersion: sourceVersionFixture({
            contentHash: await sourceVersionContentHash(FIXTURE_SOURCE_TEXT),
          }),
          fieldGroundings: forslag.fieldGroundings.map((grounding, index) => ({
            fieldGroundingId: `9000000${String(index)}-0000-4000-8000-000000000001`,
            checkField: grounding.checkField,
            sourceExcerpt: grounding.sourceExcerpt,
            sourceLocator: grounding.sourceLocator,
            justification: grounding.justification,
            createdAt: '2026-09-01T00:00:00+00:00',
            createdByActorId: '99999999-9999-4999-8999-999999999999',
          })),
        }),
        // Et funn på den samme kildeversjonen som forslaget ikke gjelder. Det
        // skal ikke dras med: utvalget er strengere enn databasens dublettregel.
        verificationItemFixture({
          evidenceItemId: '77777777-7777-4777-8777-777777777777',
          fieldGroundings: [],
        }),
      ],
    })

    const report = await runReextraction({
      extractionApi: spy.extractionApi,
      verificationApi: spy.verificationApi,
      extractionPremises: EXTRACTION_PREMISES,
      verificationPremises: VERIFICATION_PREMISES,
      proposals: [{ label: 'fava.json', proposal: forslag }],
      retrieve: retrieveFixture(),
    })

    expect(report.registered).toBe(0)
    expect(report.alreadyRegistered).toBe(1)
    expect(report.unverified).toBe(0)
    // Køen leses uten id-filter, og utvalget treffer nøyaktig det ene funnet.
    expect(spy.readInputFor).toEqual([null])
    expect(spy.verified).toEqual([ITEM_ID])
  })

  // Et funn uten registrert maskinbevis er ikke deterministisk kontrollert, og
  // kjøringen skal ikke rapportere at kjeden er komplett.
  it('rapporterer et funn uten maskinbevis som ukontrollert', async () => {
    const spy = spies({
      queue: [
        // Uten kildeversjon kan kontrollen ikke gjennomføres, og den registrerer
        // ingenting. Det er en utgang runExtractionVerification har med vilje.
        verificationItemFixture({ evidenceItemId: ITEM_ID, sourceVersion: null }),
      ],
    })

    const report = await runReextraction({
      extractionApi: spy.extractionApi,
      verificationApi: spy.verificationApi,
      extractionPremises: EXTRACTION_PREMISES,
      verificationPremises: VERIFICATION_PREMISES,
      proposals: [{ label: 'fava.json', proposal: await proposal() }],
      retrieve: retrieveFixture(),
    })

    expect(report.registered).toBe(1)
    expect(report.unverified).toBe(1)
    expect(report.results[0]?.verified).toBe(false)
    expect(spy.verified).toEqual([])
  })

  // Avtrykket databasen sammenligner, dekker de strukturerte verdiene og ikke
  // forankringen. Et forslag som bare retter et utdrag, treffer derfor den samme
  // dublettregelen — og skal ikke rapporteres som «allerede gjort».
  it('skiller en rettet forankring fra et identisk forslag', async () => {
    const forslag = await proposal()
    const spy = spies({
      duplicate: true,
      queue: [
        verificationItemFixture({
          evidenceItemId: ITEM_ID,
          sourceVersion: sourceVersionFixture({
            contentHash: await sourceVersionContentHash(FIXTURE_SOURCE_TEXT),
          }),
          // Den registrerte raden bærer en annen forankring enn forslagets.
          fieldGroundings: forslag.fieldGroundings.map((grounding) => ({
            fieldGroundingId: '90000000-0000-4000-8000-000000000001',
            checkField: grounding.checkField,
            sourceExcerpt: 'Et helt annet utdrag enn det forslaget oppgir.',
            sourceLocator: grounding.sourceLocator,
            justification: grounding.justification,
            createdAt: '2026-09-01T00:00:00+00:00',
            createdByActorId: '99999999-9999-4999-8999-999999999999',
          })),
        }),
      ],
    })

    const report = await runReextraction({
      extractionApi: spy.extractionApi,
      verificationApi: spy.verificationApi,
      extractionPremises: EXTRACTION_PREMISES,
      verificationPremises: VERIFICATION_PREMISES,
      proposals: [{ label: 'rettet.json', proposal: forslag }],
      retrieve: retrieveFixture(),
    })

    expect(report.groundingConflicts).toBe(1)
    expect(report.unverified).toBe(0)
    expect(report.results[0]?.verified).toBe(false)
    expect(report.results[0]?.groundingConflict).toMatch(/forankringen i basen er en annen/)
    // Ingenting skrives, verken en rad eller en kontroll av en fremmed rad.
    expect(spy.registered).toHaveLength(0)
    expect(spy.verified).toEqual([])
  })

  // En legacy-rad uten forankring på den samme kildeversjonen er ikke en rettet
  // forankring, og skal ikke bli meldt som en konflikt.
  it('melder ingen konflikt for et uforankret funn på den samme kildeversjonen', async () => {
    const spy = spies({
      duplicate: true,
      queue: [verificationItemFixture({ evidenceItemId: ITEM_ID, fieldGroundings: [] })],
    })

    const report = await runReextraction({
      extractionApi: spy.extractionApi,
      verificationApi: spy.verificationApi,
      extractionPremises: EXTRACTION_PREMISES,
      verificationPremises: VERIFICATION_PREMISES,
      proposals: [{ label: 'fava.json', proposal: await proposal() }],
      retrieve: retrieveFixture(),
    })

    expect(report.groundingConflicts).toBe(0)
    expect(report.alreadyRegistered).toBe(1)
    expect(spy.verified).toEqual([])
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

describe('matchesProposal', () => {
  it('treffer funnet som bærer nøyaktig forslagets forankring', async () => {
    const forslag = await proposal()
    const item = verificationItemFixture({
      fieldGroundings: forslag.fieldGroundings.map((grounding) => ({
        fieldGroundingId: '90000000-0000-4000-8000-000000000001',
        checkField: grounding.checkField,
        sourceExcerpt: grounding.sourceExcerpt,
        sourceLocator: grounding.sourceLocator,
        justification: grounding.justification,
        createdAt: '2026-09-01T00:00:00+00:00',
        createdByActorId: '99999999-9999-4999-8999-999999999999',
      })),
    })
    expect(matchesProposal(item, forslag)).toBe(true)
  })

  // En legacy-rad har ingen forankring, og skal aldri kunne bli tatt for å være
  // det forslaget beskriver.
  it('treffer aldri et funn uten forankring', async () => {
    expect(
      matchesProposal(verificationItemFixture({ fieldGroundings: [] }), await proposal()),
    ).toBe(false)
  })

  it('treffer ikke et funn fra en annen kildeversjon', async () => {
    const forslag = await proposal()
    const item = verificationItemFixture({
      sourceVersion: {
        sourceVersionId: '51000000-0000-4000-8000-000000000099',
        retrievedAt: '2026-09-01T00:00:00+00:00',
        retrievedFrom: 'https://eksempel.invalid/annen',
        externalVersion: null,
        contentHash: `sha256:${'b'.repeat(64)}`,
        representation: 'abstract',
        hasStorageReference: false,
      },
      fieldGroundings: forslag.fieldGroundings.map((grounding) => ({
        fieldGroundingId: '90000000-0000-4000-8000-000000000001',
        checkField: grounding.checkField,
        sourceExcerpt: grounding.sourceExcerpt,
        sourceLocator: grounding.sourceLocator,
        justification: grounding.justification,
        createdAt: '2026-09-01T00:00:00+00:00',
        createdByActorId: '99999999-9999-4999-8999-999999999999',
      })),
    })
    expect(matchesProposal(item, forslag)).toBe(false)
  })

  // Et rettet utdrag er en annen forankring. At databasen likevel avviser det
  // som en dublett, er en begrensning i avtrykket — ikke noe utvalget her skal
  // late som om det ikke finnes.
  it('treffer ikke et funn der et utdrag er et annet', async () => {
    const forslag = await proposal()
    const item = verificationItemFixture({
      fieldGroundings: forslag.fieldGroundings.map((grounding) => ({
        fieldGroundingId: '90000000-0000-4000-8000-000000000001',
        checkField: grounding.checkField,
        sourceExcerpt: `${grounding.sourceExcerpt} (rettet)`,
        sourceLocator: grounding.sourceLocator,
        justification: grounding.justification,
        createdAt: '2026-09-01T00:00:00+00:00',
        createdByActorId: '99999999-9999-4999-8999-999999999999',
      })),
    })
    expect(matchesProposal(item, forslag)).toBe(false)
  })
})
