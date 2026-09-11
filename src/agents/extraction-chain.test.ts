// ============================================================================
// Kjeden fra ekstraksjon til publiserbar dekning, med ekte kode i hvert ledd
//
// Testene her krysser grensene der leddene kan gli fra hverandre. Bare de to
// ytterste punktene er fikstur — kildeteksten og forslaget — og alt imellom er
// koden som faktisk kjører:
//
//   runEvidenceExtraction      den ekte ekstraksjonskjøringen
//     → registerExtraction     nøyaktig det den ville sendt til api
//     → dossierFor             det api.extraction_verification_input ville gitt
//   runExtractionVerification  den ekte verifikatorkjøringen
//     → checkExtraction        maskinbeviset, ordrett mot samme kildetekst
//   deriveExtractionVerification  menneskets rad, utledet av delsvarene
//     → coveredFields          publiseringsgatens G5b, som ren mengdelære
//
// ----------------------------------------------------------------------------
// Hva som ikke krysses her, og hvor det krysses i stedet
//
// Selve skriveveien er SQL, og den kan ikke kjøres herfra. Den er prøvd i
// supabase/tests/590 og 600, som går den samme kjeden gjennom
// api.register_agent_extraction, api.register_extraction_verification,
// api.register_human_extraction_verification og publiseringsgaten.
//
// Grensen denne filen dekker, er den andre: at det ekstraksjonen *skriver*, er
// nøyaktig det verifikatoren *leser*, og at de to radene til sammen dekker det
// gaten krever — uten at noen av dem påstår mer enn sin egen operasjon gjorde.
// ============================================================================

import { describe, expect, it } from 'vitest'

import type {
  AgentRunPremises,
  EvidenceExtractionApi,
  ExtractionVerificationApi,
  RegisterAgentExtractionArgs,
  RegisterVerificationArgs,
} from './agent-api'
import { sourceVersionContentHash } from './content-hash'
import {
  EXTRACTION_PROPOSAL_VERSION,
  parseExtractionProposal,
  type ExtractionProposal,
} from './extraction-proposal'
import { runEvidenceExtraction } from './extraction-run'
import { runExtractionVerification } from './extraction-verification-run'
import type { RetrieveLike } from './extraction-verification-run'
import { deriveExtractionVerification, type AnsweredCheck } from '../lib/control-session'

const VERIFICATION_PREMISES: AgentRunPremises = {
  provider: 'antidep',
  model: 'deterministic-extraction-check',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'extraction-verification/deterministic/1',
  pipelineVersion: 'antidep-evidence/1',
}

const SOURCE_ID = '50000000-0000-4000-8000-000000000001'
const VERSION_ID = '51000000-0000-4000-8000-000000000001'
const ITEM_ID = '33333333-3333-4333-8333-333333333333'
const RETRIEVED_FROM = 'https://eutils.eksempel.invalid/efetch.fcgi?db=pubmed&id=1'

/**
 * Kilden, én gang.
 *
 * Både ekstraksjonen og verifikatoren henter den samme teksten, som i en reell
 * kjøring: den ene leser den, den andre prøver utdragene mot den.
 */
const KILDETEKST = [
  '<PubmedArticle>',
  '  <AbstractText Label="METHODS">Sertraline patients (N = 284) with major',
  '  depressive disorder were randomised to sertraline for 8 weeks.</AbstractText>',
  '  <AbstractText Label="RESULTS">Sertraline weight change was 1.5 kg from',
  '  baseline.</AbstractText>',
  '</PubmedArticle>',
].join('\n')

/**
 * Feltene raden påstår noe om, slik `workflow.required_check_fields` regner dem
 * ut for nøyaktig denne raden. Speilet her, som i `test-support.ts`, fordi
 * kjeden skal kunne prøves uten database; originalen er prøvd i pgTAP.
 */
const REQUIRED_FIELDS = [
  'source_locator',
  'intervention_arm',
  'outcome',
  'reported_direction',
  'availability_semantics',
  'raw_extraction',
  'effect_measure',
  'sample_size',
  'timepoint',
  'estimate',
]

const SEMANTIC_FIELDS = REQUIRED_FIELDS.filter(
  (field) => field !== 'raw_extraction' && field !== 'source_locator',
)

async function proposal(): Promise<ExtractionProposal> {
  return parseExtractionProposal({
    proposal_version: EXTRACTION_PROPOSAL_VERSION,
    generated_by: {
      producer: 'model',
      provider: 'antidep',
      model: 'opptaksmodell',
      model_version: '1',
      prompt_template_version: 'evidence-extraction/proposal-drafting/1',
      drafted_at: '2026-09-15T09:00:00Z',
    },
    source_id: SOURCE_ID,
    source_version_id: VERSION_ID,
    retrieved_from: RETRIEVED_FROM,
    content_hash: await sourceVersionContentHash(KILDETEKST),
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
      timepoint_min: '56 days',
      timepoint_max: '56 days',
      timepoint_availability: 'reported_value',
      reported_direction: 'increase',
      effect_measure: 'mean_change',
      estimate: '1.5',
      estimate_unit: 'kg',
      estimate_availability: 'reported_value',
      confidence_interval_availability: 'not_reported',
      source_locator: 'Sammendrag (MEDLINE-post)',
      source_quote: 'Sertraline weight change was 1.5 kg from baseline',
    },
    field_groundings: [
      {
        check_field: 'intervention_arm',
        source_excerpt:
          'Sertraline patients (N = 284) with major depressive disorder were randomised to sertraline for 8 weeks.',
        source_locator: 'Sammendrag, METHODS',
        justification: 'Armen er navngitt i metodeavsnittet.',
      },
      {
        check_field: 'outcome',
        source_excerpt: 'Sertraline weight change was 1.5 kg from baseline.',
        source_locator: 'Sammendrag, RESULTS',
        justification: 'Endepunktet er navngitt i resultatavsnittet.',
      },
      {
        check_field: 'reported_direction',
        source_excerpt: 'Sertraline weight change was 1.5 kg from baseline.',
        source_locator: 'Sammendrag, RESULTS',
        justification: 'Retningen leses av endringen fra baseline.',
      },
      {
        check_field: 'availability_semantics',
        source_excerpt:
          'Sertraline patients (N = 284) with major depressive disorder were randomised to sertraline for 8 weeks.',
        source_locator: 'Sammendrag, METHODS',
        justification: 'Feltene uten verdi er ført som ikke rapportert.',
      },
      {
        check_field: 'effect_measure',
        source_excerpt: 'Sertraline weight change was 1.5 kg from baseline.',
        source_locator: 'Sammendrag, RESULTS',
        justification: 'Effektmålet er gjennomsnittlig endring innen armen.',
      },
      {
        check_field: 'sample_size',
        source_excerpt:
          'Sertraline patients (N = 284) with major depressive disorder were randomised to sertraline for 8 weeks.',
        source_locator: 'Sammendrag, METHODS',
        justification: 'Utvalgsstørrelsen står ved siden av armen.',
      },
      {
        check_field: 'timepoint',
        source_excerpt:
          'Sertraline patients (N = 284) with major depressive disorder were randomised to sertraline for 8 weeks.',
        source_locator: 'Sammendrag, METHODS',
        justification: 'Behandlingsvarigheten er åtte uker.',
      },
      {
        check_field: 'estimate',
        source_excerpt: 'Sertraline weight change was 1.5 kg from baseline.',
        source_locator: 'Sammendrag, RESULTS',
        justification: 'Estimatet står ved siden av armen og endepunktet.',
      },
    ],
  })
}

function retrieve(): RetrieveLike {
  return async (url) => ({
    status: 'ok',
    representation: {
      url,
      status: 200,
      contentType: 'text/xml',
      content: KILDETEKST,
      byteLength: KILDETEKST.length,
      contentHash: await sourceVersionContentHash(KILDETEKST),
      bytesAreUtf8: true,
    },
  })
}

/**
 * Det ekstraksjonen skrev, oversatt til det leseflaten ville gitt verifikatoren.
 *
 * Dette er selve grensen testen finnes for: nøklene er databasens, og en
 * ekstraksjon som skrev noe verifikatoren ikke leser, ville blitt fanget her.
 */
async function dossierFor(written: RegisterAgentExtractionArgs): Promise<Record<string, unknown>> {
  const e = written.extraction
  return {
    evidence_item_id: ITEM_ID,
    created_by_actor_id: '99999999-9999-4999-8999-999999999999',
    created_by_actor_key: 'agent:evidence-extraction',
    created_at: '2026-09-01T00:00:00+00:00',
    extraction_method: 'ai_assisted',
    content_hash: `sha256-v2:${'a'.repeat(64)}`,
    verifications_by_this_actor: 0,
    source: {
      source_id: written.sourceId,
      source_type: 'journal_article',
      title: 'Testkilde',
      authors_or_issuer: 'Testforfatter m.fl.',
      publisher_or_journal: 'Testtidsskrift',
      publication_date: '2024-01-01',
      publication_date_precision: 'day',
      source_status: 'active',
      status_note: null,
    },
    source_version: {
      source_version_id: written.sourceVersionId,
      retrieved_at: '2026-09-01T00:00:00+00:00',
      retrieved_from: RETRIEVED_FROM,
      external_version: null,
      content_hash: await sourceVersionContentHash(KILDETEKST),
      representation: 'abstract',
      has_storage_reference: false,
    },
    field_groundings: written.fieldGroundings.map((grounding, index) => ({
      field_grounding_id: `61000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`,
      check_field: grounding.checkField,
      source_excerpt: grounding.sourceExcerpt,
      source_locator: grounding.sourceLocator,
      justification: grounding.justification,
      created_at: '2026-09-01T00:00:00+00:00',
      created_by_actor_id: '99999999-9999-4999-8999-999999999999',
    })),
    semantic_check_fields: SEMANTIC_FIELDS,
    grounded_check_fields: written.fieldGroundings.map((grounding) => grounding.checkField),
    grounding_machine_proved: false,
    extraction: {
      design_code: e.designCode,
      population_label: null,
      population_availability: e.populationAvailability,
      population_detail: e.populationDetail,
      sample_size: e.sampleSize,
      sample_size_availability: e.sampleSizeAvailability,
      intervention_drug_name: 'sertraline',
      intervention_detail: e.interventionDetail,
      comparator_kind: e.comparatorKind,
      comparator_drug_name: null,
      comparator_detail: e.comparatorDetail,
      outcome_label: 'weight change',
      outcome_detail: e.outcomeDetail,
      timepoint_min: e.timepointMin,
      timepoint_max: e.timepointMax,
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
      raw_extraction: e.sourceQuote === null ? null : { sitat: e.sourceQuote },
    },
  }
}

/** Kjører ekstraksjonen, og gir tilbake det den skrev. */
async function extract(): Promise<RegisterAgentExtractionArgs> {
  const written: RegisterAgentExtractionArgs[] = []
  const api: EvidenceExtractionApi = {
    beginRun: () => Promise.resolve('11111111-1111-4111-8111-111111111111'),
    registerExtraction: (args) => {
      written.push(args)
      return Promise.resolve(ITEM_ID)
    },
    completeRun: () => Promise.resolve(),
  }
  const report = await runEvidenceExtraction({
    mode: 'unchecked_model',
    api,
    proposal: await proposal(),
    retrieve: retrieve(),
  })
  expect(report.decision).toBe('registered')
  const first = written[0]
  if (first === undefined) {
    throw new Error('Ekstraksjonen registrerte ingenting.')
  }
  return first
}

/** Kjører verifikatoren på det ekstraksjonen skrev, og gir tilbake dens rad. */
async function verify(written: RegisterAgentExtractionArgs): Promise<RegisterVerificationArgs> {
  const registered: RegisterVerificationArgs[] = []
  const dossier = await dossierFor(written)
  const api: ExtractionVerificationApi = {
    beginRun: () => Promise.resolve('22222222-2222-4222-8222-222222222222'),
    readInput: () =>
      Promise.resolve({
        agent_run_id: '22222222-2222-4222-8222-222222222222',
        verifier_actor_id: '88888888-8888-4888-8888-888888888888',
        items: [dossier],
      }),
    registerVerification: (args) => {
      registered.push(args)
      return Promise.resolve('44444444-4444-4444-8444-444444444444')
    },
    completeRun: () => Promise.resolve(),
  }
  await runExtractionVerification({
    api,
    premises: VERIFICATION_PREMISES,
    retrieve: retrieve(),
  })
  const first = registered[0]
  if (first === undefined) {
    throw new Error('Verifikatoren registrerte ingenting.')
  }
  return first
}

/**
 * Publiseringsgatens G5b, som ren mengdelære.
 *
 * `workflow.covered_check_fields` er unionen over kontroller som ikke fant et
 * avvik (migrasjon 005y). Speilet her fordi kjeden skal kunne prøves uten
 * database; originalen er prøvd i pgTAP.
 */
function coveredFields(rows: readonly { outcome: string; checkedFields: readonly string[] }[]) {
  return new Set(
    rows
      .filter((row) => row.outcome === 'verified' || row.outcome === 'uncertain')
      .flatMap((row) => row.checkedFields),
  )
}

describe('kjeden fra ekstraksjon til dekning', () => {
  it('skriver nøyaktig det verifikatoren leser', async () => {
    const written = await extract()
    const machine = await verify(written)

    expect(machine.evidenceItemId).toBe(ITEM_ID)
    // Ingen avvik: hvert utdrag ekstraksjonen skrev, står i den samme kilden.
    // Det er nettopp denne grensen testen finnes for.
    expect(machine.outcome).not.toBe('needs_correction')
    expect(machine.rationale).toContain('forankrede utdrag ble gjenfunnet ordrett')
  })

  // Dette er maskinbeviset, uttrykt i vokabularet databasen leser
  // (`workflow.grounding_machine_proved`).
  it('gir maskinbeviset: kildepekeren føres opp som kontrollert', async () => {
    const machine = await verify(await extract())
    expect(machine.checkedFields).toContain('source_locator')
  })

  // Punkt for punkt: ingen rad påstår mer enn sin egen operasjon gjorde.
  it('lar hver rad påstå bare sin egen operasjon', async () => {
    const machine = await verify(await extract())
    const human = deriveExtractionVerification({
      requiredFields: REQUIRED_FIELDS,
      semanticFields: SEMANTIC_FIELDS,
      sourceAccess: 'original_source',
      sourceWideAbsenceFields: [],
      answers: Object.fromEntries(
        SEMANTIC_FIELDS.map((field) => [field, { answer: 'yes' as const, note: '' }]),
      ),
    })

    // Mennesket: bare de semantiske feltene det faktisk bedømte.
    expect([...human.checkedFields].sort()).toEqual([...SEMANTIC_FIELDS].sort())
    expect(human.checkedFields).not.toContain('source_locator')
    expect(human.checkedFields).not.toContain('raw_extraction')

    // Maskinen: bare felter den positivt bekreftet, aldri de semantiske den
    // ikke kan bedømme.
    expect(machine.checkedFields).not.toContain('availability_semantics')
    expect(machine.checkedFields).not.toContain('reported_direction')
  })

  // …og til sammen dekker de nøyaktig det gaten krever.
  it('lar de to radene til sammen dekke publiseringsgatens krav', async () => {
    const machine = await verify(await extract())
    const human = deriveExtractionVerification({
      requiredFields: REQUIRED_FIELDS,
      semanticFields: SEMANTIC_FIELDS,
      sourceAccess: 'original_source',
      sourceWideAbsenceFields: [],
      answers: Object.fromEntries(
        SEMANTIC_FIELDS.map((field) => [field, { answer: 'yes' as const, note: '' }]),
      ),
    })

    const covered = coveredFields([machine, human])
    expect(REQUIRED_FIELDS.filter((field) => !covered.has(field))).toEqual([])
  })

  // Uten maskinleddet mangler nøyaktig de to provenansfeltene, og gaten
  // blokkerer. Det er den samme regelen databasen håndhever i migrasjon 005x.
  it('lar ikke mennesket alene dekke gatens krav', async () => {
    const human = deriveExtractionVerification({
      requiredFields: REQUIRED_FIELDS,
      semanticFields: SEMANTIC_FIELDS,
      sourceAccess: 'original_source',
      sourceWideAbsenceFields: [],
      answers: Object.fromEntries(
        SEMANTIC_FIELDS.map((field) => [field, { answer: 'yes' as const, note: '' }]),
      ),
    })

    const covered = coveredFields([human])
    expect(REQUIRED_FIELDS.filter((field) => !covered.has(field)).sort()).toEqual([
      'raw_extraction',
      'source_locator',
    ])
  })

  // Et felt kontrolløren ikke kunne avgjøre, gir ikke dekning — heller ikke nå
  // som en uavklart kontroll teller (migrasjon 005y).
  it('lar ikke et uavklart felt gi dekning', async () => {
    const machine = await verify(await extract())
    const answers: Record<string, AnsweredCheck> = Object.fromEntries(
      SEMANTIC_FIELDS.map((field) => [field, { answer: 'yes' as const, note: '' }]),
    )
    answers['availability_semantics'] = { answer: 'cannot_determine', note: '' }
    const human = deriveExtractionVerification({
      requiredFields: REQUIRED_FIELDS,
      semanticFields: SEMANTIC_FIELDS,
      sourceAccess: 'original_source',
      sourceWideAbsenceFields: [],
      answers,
    })

    const covered = coveredFields([machine, human])
    expect(covered.has('availability_semantics')).toBe(false)
  })
})
