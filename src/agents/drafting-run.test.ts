// ============================================================================
// Modell-leddet, prøvd uten leverandør og uten nett
//
// Det som prøves er arbeidsdelingen: leddet henter kildeversjonen selv, spør en
// modell, og skriver et forslag bare når svaret holder mål. Alt annet er en
// begrunnet avvisning — aldri et halvferdig forslag som neste ledd må rydde i.
//
// Modellen er en injisert `ModelClient`, og kildehentingen en injisert
// `retrieve`. Ingen av dem går ut av prosessen.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { sourceVersionContentHash } from './content-hash'
import { runExtractionDrafting, prepareDraftingRequest } from './drafting-run'
import { parseExtractionAssignment } from './extraction-assignment'
import {
  parseExtractionProposal,
  serializeExtractionProposal,
  EXTRACTION_PROPOSAL_VERSION,
} from './extraction-proposal'
import { EXTRACTION_DRAFTING_PROMPT_VERSION } from './extraction-prompt'
import type { ModelClient } from './model-client'
import type { RetrieveLike } from './extraction-run'
import { FIXTURE_SOURCE_TEXT } from './test-support'

const DRUG = '40000000-0000-4000-8000-000000000001'
const OTHER_DRUG = '40000000-0000-4000-8000-000000000002'
const OUTCOME = '41000000-0000-4000-8000-000000000001'
const POPULATION = '42000000-0000-4000-8000-000000000001'

const EXCERPT = 'Sertraline patients (N = 284) with major depressive disorder'
const QUOTE = 'mean weight change of 1.5 kg'

async function oppdrag(overrides: Record<string, unknown> = {}) {
  return parseExtractionAssignment({
    assignment_version: 'antidep/extraction-assignment@1',
    source_id: '50000000-0000-4000-8000-000000000001',
    source_version_id: '51000000-0000-4000-8000-000000000001',
    retrieved_from: 'https://eksempel.invalid/kilde',
    content_hash: await sourceVersionContentHash(FIXTURE_SOURCE_TEXT),
    drugs: [{ drug_id: DRUG, label: 'sertralin' }],
    outcomes: [{ outcome_concept_id: OUTCOME, label: 'vektendring' }],
    populations: [],
    ...overrides,
  })
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

function utkast(overrides: { extraction?: Record<string, unknown>; groundings?: unknown } = {}) {
  return {
    extraction: {
      design_code: 'randomized_controlled_trial',
      population_availability: 'not_reported',
      population_detail: 'Voksne med depressiv lidelse.',
      sample_size: 284,
      sample_size_availability: 'reported_value',
      intervention_drug_id: DRUG,
      comparator_kind: 'none',
      outcome_concept_id: OUTCOME,
      outcome_detail: 'Gjennomsnittlig vektendring.',
      timepoint_availability: 'not_reported',
      reported_direction: 'increase',
      estimate: '1.5',
      estimate_unit: 'kg',
      estimate_availability: 'reported_value',
      confidence_interval_availability: 'not_reported',
      source_locator: 'Sammendrag, RESULTS',
      source_quote: QUOTE,
      ...overrides.extraction,
    },
    field_groundings: overrides.groundings ?? [
      {
        check_field: 'intervention_arm',
        source_excerpt: EXCERPT,
        source_locator: 'Sammendrag, METHODS',
        justification: 'Armen er navngitt i metodeavsnittet.',
      },
      {
        check_field: 'sample_size',
        source_excerpt: EXCERPT,
        source_locator: 'Sammendrag, METHODS',
        justification: 'Utvalgsstørrelsen står ved siden av armen.',
      },
    ],
  }
}

function modell(text: string): ModelClient {
  return {
    identity: { provider: 'en-leverandør', model: 'en-modell', modelVersion: '2026-09-15' },
    complete: () => Promise.resolve({ text }),
  }
}

function svarer(draft: unknown): ModelClient {
  return modell(JSON.stringify(draft))
}

describe('runExtractionDrafting — den lykkede stien', () => {
  it('skriver et forslag av modellens utkast og oppdragets kildebinding', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: svarer(utkast()),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('drafted')
    expect(report.proposal?.proposalVersion).toBe(EXTRACTION_PROPOSAL_VERSION)
    expect(report.proposal?.sourceVersionId).toBe('51000000-0000-4000-8000-000000000001')
    expect(report.proposal?.fieldGroundings).toHaveLength(2)
  })

  // Premissene er modellens egne, og kjøringen som registrerer forslaget
  // etterpå leser dem derfra (ANTIDEP_CONSTITUTION.md §20).
  it('fører opp leverandøren, modellen og promptmalen som faktisk svarte', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: svarer(utkast()),
      retrieve: retrieveFixture(),
      now: () => '2026-09-15T09:00:00Z',
    })

    expect(report.proposal?.generatedBy).toEqual({
      producer: 'model',
      provider: 'en-leverandør',
      model: 'en-modell',
      modelVersion: '2026-09-15',
      promptTemplateVersion: EXTRACTION_DRAFTING_PROMPT_VERSION,
      draftedAt: '2026-09-15T09:00:00Z',
      requestDigest: report.requestDigest,
    })
  })

  // Tidspunktet er utkastets, ikke registreringens: registreringen skjer når
  // noen kjører kommandoen, kanskje dager senere. Uten dette ville det eneste
  // tidspunktet i proveniensen vært registreringskjøringens
  // (EVIDENCE_PIPELINE.md §65).
  it('leser klokka når modellen svarte, ikke når filen registreres', async () => {
    const tidspunkter = ['2026-09-15T09:00:00Z', '2026-09-16T09:00:00Z']
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: svarer(utkast()),
      retrieve: retrieveFixture(),
      now: () => tidspunkter.shift() ?? 'brukt opp',
    })

    expect(report.proposal?.generatedBy.draftedAt).toBe('2026-09-15T09:00:00Z')
  })

  // Avtrykket dekker representasjonen, katalogen i oppdraget og promptmalen, og
  // er det som gjør modellkjøringen identifiserbar i ettertid.
  it('binder forslaget til fingeravtrykket av forespørselen modellen svarte på', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: svarer(utkast()),
      retrieve: retrieveFixture(),
    })

    expect(report.proposal?.generatedBy.requestDigest).toBe(report.requestDigest)
    expect(report.requestDigest).toMatch(/^sha256:[0-9a-f]{64}$/)
  })

  // Filen leddet skriver, skal være nøyaktig den formen neste ledd leser.
  it('gir et forslag som går uendret gjennom forslagsleseren', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: svarer(utkast()),
      retrieve: retrieveFixture(),
    })

    const rundtur = parseExtractionProposal(
      JSON.parse(JSON.stringify(serializeExtractionProposal(report.proposal!))) as unknown,
    )
    expect(rundtur).toEqual(report.proposal)
  })

  // Malen ber om JSON uten kodegjerder, men ett gjerde rundt hele svaret er den
  // ene avviksformen som er entydig og ikke endrer et tegn i innholdet.
  it('tåler at svaret står i ett kodegjerde', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: modell(`\`\`\`json\n${JSON.stringify(utkast())}\n\`\`\``),
      retrieve: retrieveFixture(),
    })
    expect(report.decision).toBe('drafted')
  })
})

describe('runExtractionDrafting — det den nekter å foreslå', () => {
  it('spør ingen modell når kilden ikke lot seg hente', async () => {
    let spurt = false
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: {
        identity: { provider: 'p', model: 'm', modelVersion: '1' },
        complete: () => {
          spurt = true
          return Promise.resolve({ text: '{}' })
        },
      },
      retrieve: () => Promise.resolve({ status: 'error', message: 'Kilden svarte ikke.' }),
    })

    expect(report.decision).toBe('rejected')
    expect(report.reason).toMatch(/Kilden svarte ikke/)
    expect(spurt).toBe(false)
  })

  // Et utkast lest ut av en annen utgave enn den registrerte, ville pekt på noe
  // annet enn det ekstraksjonen bindes til.
  it('spør ingen modell når representasjonen ikke er den registrerte utgaven', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: svarer(utkast()),
      retrieve: retrieveFixture({ hash: `sha256:${'0'.repeat(64)}` }),
    })

    expect(report.decision).toBe('rejected')
    expect(report.reason).toMatch(/Kilden har endret seg/)
    expect(report.proposal).toBeUndefined()
  })

  it('avviser et svar som ikke er JSON', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: modell('Her er et forslag, men jeg skrev det som prosa.'),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('rejected')
    expect(report.completion).toMatch(/prosa/)
  })

  it('avviser et utkast med et ukjent felt', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: svarer({ ...utkast(), confidence: 0.9 }),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('rejected')
    expect(report.reason).toMatch(/ukjente felter: confidence/)
  })

  // Utdragene ville stått ordrett i kilden også for et funn flyttet til feil
  // virkestoff. Katalogkontrollen er den eneste som fanger den forvekslingen.
  it('avviser et virkestoff som ikke står i oppdraget', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: svarer(utkast({ extraction: { intervention_drug_id: OTHER_DRUG } })),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('rejected')
    expect(report.reason).toMatch(/intervention_drug_id .* står ikke blant virkestoffene/)
  })

  it('avviser en populasjon som ikke står i oppdraget', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: svarer(utkast({ extraction: { population_id: POPULATION } })),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('rejected')
    expect(report.reason).toMatch(/population_id .* står ikke blant populasjonene/)
  })

  it('godtar en populasjon oppdraget faktisk åpnet for', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag({
        populations: [{ population_id: POPULATION, label: 'voksne' }],
      }),
      model: svarer(utkast({ extraction: { population_id: POPULATION } })),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('drafted')
  })

  // Generatoren skriver ikke noe den vet er galt. Kontrollen etterpå er
  // fortsatt en egen operasjon, av en annen identitet.
  it('avviser et utdrag som ikke står ordrett i representasjonen', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: svarer(
        utkast({
          groundings: [
            {
              check_field: 'intervention_arm',
              source_excerpt: 'Patients received paroxetine 20 mg daily for eight weeks.',
              source_locator: 'Sammendrag',
              justification: 'Armen står i metodeavsnittet.',
            },
          ],
        }),
      ),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('rejected')
    expect(report.reason).toMatch(/intervention_arm/)
  })

  // source_quote blir raw_extraction på raden, og ekstraksjonskontrollen prøver
  // det ordrett senere. Et omskrevet sitat ville blitt en rad dømt til å avvises.
  it('avviser et sitat som ikke står ordrett i representasjonen', async () => {
    const report = await runExtractionDrafting({
      assignment: await oppdrag(),
      model: svarer(
        utkast({ extraction: { source_quote: 'Vekten økte med halvannen kilo i snitt.' } }),
      ),
      retrieve: retrieveFixture(),
    })

    expect(report.decision).toBe('rejected')
    expect(report.reason).toMatch(/source_quote står ikke ordrett/)
  })
})

describe('prepareDraftingRequest', () => {
  it('bygger forespørselen og avtrykket uten å spørre noen modell', async () => {
    const { request, requestDigest } = await prepareDraftingRequest({
      assignment: await oppdrag(),
      retrieve: retrieveFixture(),
    })

    expect(request.promptTemplateVersion).toBe(EXTRACTION_DRAFTING_PROMPT_VERSION)
    expect(request.user).toContain('Sertraline patients')
    expect(requestDigest).toMatch(/^sha256:[0-9a-f]{64}$/)
  })

  it('kaster når kildeversjonen ikke lot seg hente', async () => {
    await expect(
      prepareDraftingRequest({
        assignment: await oppdrag(),
        retrieve: () => Promise.resolve({ status: 'error', message: 'Kilden svarte ikke.' }),
      }),
    ).rejects.toThrow(/Kilden svarte ikke/)
  })
})
