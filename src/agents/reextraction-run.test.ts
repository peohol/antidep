// ============================================================================
// Re-ekstraksjonen: at den registrerer, kontrollerer, og lar det gamle stå
//
// Testene her prøver orkestreringen, ikke leddene: at kontrollen kjøres på
// nøyaktig det funnet som nettopp ble registrert, at en dublett ikke skriver
// noe, at en rettet forankring går gjennom som et nytt funn, og at en
// tørrkjøring verken registrerer eller kontrollerer.
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
import {
  EXTRACTION_PROPOSAL_VERSION,
  parseExtractionProposal,
  type ExtractionProposal,
} from './extraction-proposal'
import type { RetrieveLike } from './extraction-run'
import { runReextraction } from './reextraction-run'
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
const OTHER_ITEM_ID = '77777777-7777-4777-8777-777777777777' as Uuid
const VERIFIER_ACTOR_ID = '44444444-4444-4444-8444-444444444444'

/**
 * De strukturerte verdiene, som en delt konstant.
 *
 * Delt fordi to av testene under skal skille seg fra hverandre *bare* i
 * forankringen. Var verdiene skrevet av to ganger, kunne de kommet fra hverandre
 * uten at testen sa fra, og påstanden om at forankringen alene gjør forskjellen,
 * ville sluttet å holde.
 */
const PROPOSAL_EXTRACTION = {
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
}

async function proposal(): Promise<ExtractionProposal> {
  return parseExtractionProposal({
    proposal_version: EXTRACTION_PROPOSAL_VERSION,
    source_id: '50000000-0000-4000-8000-000000000001',
    source_version_id: '51000000-0000-4000-8000-000000000001',
    retrieved_from: 'https://eksempel.invalid/kilde',
    content_hash: await sourceVersionContentHash(FIXTURE_SOURCE_TEXT),
    extraction: PROPOSAL_EXTRACTION,
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
  /** Raden dublettavvisningen navngir. `ITEM_ID` hvis utelatt, `null` for «ukjent». */
  readonly collidesWith?: Uuid | null
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
              options.collidesWith === null
                ? 'Den kolliderende raden lot seg ikke slå opp.'
                : `evidence_item_id=${options.collidesWith ?? ITEM_ID}`,
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
        // Doblet oppfører seg som api.extraction_verification_input: med en id
        // svarer den om nøyaktig det funnet, også et allerede kontrollert; uten
        // en id svarer den med arbeidskøen. Uten den oppførselen ville testene
        // ikke sagt noe om at kjøreren slår opp riktig rad.
        const all = options.queue ?? []
        const items =
          evidenceItemId === null
            ? all
            : all.filter((item) => item.evidenceItemId === evidenceItemId)
        return Promise.resolve({
          agent_run_id: VERIFICATION_RUN_ID,
          verifier_actor_id: VERIFIER_ACTOR_ID,
          items: items.map(verificationItemPayload),
        })
      },
      registerVerification: (args) => {
        verified.push(args.evidenceItemId)
        return Promise.resolve(VERIFICATION_RUN_ID)
      },
    },
  }
}

/** Et køfunn som bærer nøyaktig forslagets forankring. */
async function grounded(
  forslag: ExtractionProposal,
  overrides: Parameters<typeof verificationItemFixture>[0] = {},
): Promise<VerificationItem> {
  return verificationItemFixture({
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
    ...overrides,
  })
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
    const forslag = await proposal()
    const spy = spies({
      duplicate: true,
      queue: [await grounded(forslag, { evidenceItemId: ITEM_ID, groundingMachineProved: true })],
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
    expect(spy.registered).toHaveLength(0)
    // Raden slås opp på den id-en databasen navnga, og den bar allerede et
    // maskinbevis: kjeden er komplett, og ingenting skrives.
    expect(spy.readInputFor).toEqual([ITEM_ID])
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
        await grounded(forslag, { evidenceItemId: ITEM_ID }),
        // Et *annet* funn på den samme kildeversjonen, med nøyaktig den samme
        // forankringen. Det er lovlig: to funn fra én studie kan dele
        // utvalgsutdraget og likevel gjelde ulike utfall. Kjøreren skal aldri
        // kunne velge det, fordi den slår opp på id-en databasen navnga.
        await grounded(forslag, { evidenceItemId: OTHER_ITEM_ID }),
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
    // Oppslaget går på id-en dublettavvisningen navnga, og kontrollen treffer
    // nøyaktig den raden — ikke det andre funnet med den samme forankringen.
    expect(spy.readInputFor).toEqual([ITEM_ID])
    expect(spy.verified).toEqual([ITEM_ID])
  })

  // Et funn uten registrert maskinbevis er ikke deterministisk kontrollert, og
  // kjøringen skal ikke rapportere at kjeden er komplett.
  it('rapporterer et funn uten maskinbevis som ukontrollert', async () => {
    const forslag = await proposal()
    const spy = spies({
      queue: [
        // Uten kildeversjon kan kontrollen ikke gjennomføres, og den registrerer
        // ingenting. Det er en utgang runExtractionVerification har med vilje.
        await grounded(forslag, { evidenceItemId: ITEM_ID, sourceVersion: null }),
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

    expect(report.registered).toBe(1)
    expect(report.unverified).toBe(1)
    expect(report.results[0]?.verified).toBe(false)
    expect(spy.verified).toEqual([])
  })

  // Kildeforankringen er en del av identiteten (migrasjon 003d). Et forslag der
  // bare et utdrag er rettet, er derfor ikke en dublett: det registreres som et
  // nytt funn og kontrolleres som et hvilket som helst annet nytt funn.
  it('registrerer en rettet forankring som et nytt funn og kontrollerer det', async () => {
    const opprinnelig = await proposal()
    const rettet = parseExtractionProposal({
      proposal_version: EXTRACTION_PROPOSAL_VERSION,
      source_id: opprinnelig.sourceId,
      source_version_id: opprinnelig.sourceVersionId,
      retrieved_from: opprinnelig.retrievedFrom,
      content_hash: opprinnelig.contentHash,
      extraction: PROPOSAL_EXTRACTION,
      // Samme strukturerte verdier, ett annet ordrett utdrag — som fortsatt står
      // i kilden, slik at ekstraksjonens egen kontroll slipper det gjennom.
      field_groundings: [
        {
          check_field: 'sample_size',
          source_excerpt: 'Sertraline patients (N = 284)',
          source_locator: 'Sammendrag, METHODS',
          justification: 'Utvalgsstørrelsen står ved siden av armen.',
        },
      ],
    })

    const spy = spies()
    const report = await runReextraction({
      extractionApi: spy.extractionApi,
      verificationApi: spy.verificationApi,
      extractionPremises: EXTRACTION_PREMISES,
      verificationPremises: VERIFICATION_PREMISES,
      proposals: [{ label: 'rettet.json', proposal: rettet }],
      retrieve: retrieveFixture(),
    })

    expect(report.registered).toBe(1)
    expect(report.alreadyRegistered).toBe(0)
    expect(report.unverified).toBe(0)
    expect(spy.registered).toHaveLength(1)
    // Det rettede utdraget er det som sendes videre — ikke det gamle.
    expect(report.results[0]?.extraction.groundedFields).toEqual(['sample_size'])
    expect(spy.readInputFor).toEqual([ITEM_ID])
  })

  // Kontrollen gjelder den raden databasen navnga, og ingen annen: et annet
  // forankret funn på den samme kildeversjonen skal verken kontrolleres eller
  // gjøre kjeden ufullstendig.
  it('lar et annet funn på kildeversjonen stå urørt når den navngitte raden er kontrollert', async () => {
    const forslag = await proposal()
    const spy = spies({
      duplicate: true,
      queue: [
        await grounded(forslag, { evidenceItemId: ITEM_ID, groundingMachineProved: true }),
        await grounded(forslag, { evidenceItemId: OTHER_ITEM_ID }),
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

    expect(report.alreadyRegistered).toBe(1)
    expect(report.unverified).toBe(0)
    expect(spy.verified).toEqual([])
  })

  // Databasen kunne ikke navngi raden. Da finnes det ingen rad å kontrollere
  // herfra, og kjøringen skal ikke påstå at kjeden er komplett.
  it('rapporterer en dublett uten navngitt rad som ukontrollert', async () => {
    const spy = spies({ duplicate: true, collidesWith: null })

    const report = await runReextraction({
      extractionApi: spy.extractionApi,
      verificationApi: spy.verificationApi,
      extractionPremises: EXTRACTION_PREMISES,
      verificationPremises: VERIFICATION_PREMISES,
      proposals: [{ label: 'fava.json', proposal: await proposal() }],
      retrieve: retrieveFixture(),
    })

    expect(report.unverified).toBe(1)
    expect(report.results[0]?.verified).toBe(false)
    expect(report.results[0]?.unverifiedReason).toMatch(/kunne ikke navngi/)
    expect(spy.readInputFor).toEqual([])
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
