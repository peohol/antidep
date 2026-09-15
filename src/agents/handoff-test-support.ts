// ============================================================================
// Syntetiske oppgaver og svar for prøvene av den eksterne agent-handoffen
//
// Formen er nøyaktig den `api.agent_task_payload(...)` svarer med, og
// `handoff-contract.test.ts` pinner den mot migrasjonen. Fiksturet finnes her og
// ikke i hver prøve, fordi fire prøver trenger den samme oppgaven — og fire
// kopier ville kunnet drive fra hverandre uten at noen av dem ble røde.
//
// Alt innhold er syntetisk. Ingen linje her er en klinisk påstand, og teksten er
// ikke hentet fra noen publikasjon.
// ============================================================================

import { AGENT_ANSWER_VERSION, AGENT_TASK_VERSION, HANDOFF_CONTRACTS } from './agent-task.ts'
import type { HandoffRole } from './agent-task.ts'

export const TEST_SOURCE_ID = '78000000-0000-4000-8000-000000000001'
export const TEST_SOURCE_VERSION_ID = '78000000-0000-4000-8000-000000000002'
export const TEST_JOB_ID = '78000000-0000-4000-8000-0000000000a1'
export const TEST_DRUG_ID = '78000000-0000-4000-8000-0000000000d1'
export const TEST_OTHER_DRUG_ID = '78000000-0000-4000-8000-0000000000d2'
export const TEST_OUTCOME_ID = '78000000-0000-4000-8000-0000000000c1'
export const TEST_POPULATION_ID = '78000000-0000-4000-8000-0000000000b1'
export const TEST_EVIDENCE_ID = '78000000-0000-4000-8000-0000000000e1'
export const TEST_OTHER_EVIDENCE_ID = '78000000-0000-4000-8000-0000000000e2'
export const TEST_TOPIC_ID = '78000000-0000-4000-8000-0000000000f1'
export const TEST_REVISION_ID = '78000000-0000-4000-8000-0000000000c9'

export const TEST_CONTENT_HASH = `sha256:${'9'.repeat(64)}`

/** Den syntetiske «artikkelen» ekstraksjonsoppgaven inneholder. */
export const TEST_REPRESENTATION = [
  'Syntetisk artikkel om testmiddel og vektendring.',
  '',
  'Patients (N = 100) with major depressive disorder were randomly assigned to testmiddel for 8 weeks.',
  '',
  'Mean weight change from baseline was 0.8 kg in the testmiddel arm at 8 weeks.',
  '',
  'No confidence interval was reported for the mean weight change.',
  '',
  'The study was limited by its short duration and its open-label design.',
  '',
].join('\n')

const EXCERPT = 'Mean weight change from baseline was 0.8 kg in the testmiddel arm at 8 weeks.'

function digestFor(role: HandoffRole): string {
  const seed = { evidence_extraction: '1', claim_synthesis: '2', evidence_assessment: '3' }[role]
  return `sha256:${seed.repeat(64)}`
}

/** Én oppgave, slik databasen bygger den. */
export function taskPayload(
  role: HandoffRole,
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  const contract = HANDOFF_CONTRACTS[role]
  const input = {
    evidence_extraction: {
      source_id: TEST_SOURCE_ID,
      source_version_id: TEST_SOURCE_VERSION_ID,
      content_hash: TEST_CONTENT_HASH,
      representation: 'full_text',
      document_sha256: `sha256:${'a'.repeat(64)}`,
      drug_ids: [TEST_DRUG_ID, TEST_OTHER_DRUG_ID],
      outcome_concept_ids: [TEST_OUTCOME_ID],
      population_ids: [TEST_POPULATION_ID],
    },
    claim_synthesis: {
      topic_concept_id: TEST_TOPIC_ID,
      subject_drug_id: TEST_DRUG_ID,
      claim_id: null,
      population_ids: [TEST_POPULATION_ID],
      evidence: [{ evidence_item_id: TEST_EVIDENCE_ID, content_hash: TEST_CONTENT_HASH }],
    },
    evidence_assessment: {
      claim_revision_id: TEST_REVISION_ID,
      revision_content_hash: TEST_CONTENT_HASH,
      evidence_set_digest: `sha256:${'b'.repeat(64)}`,
    },
  }[role]

  const material = {
    evidence_extraction: {
      source: {
        source_id: TEST_SOURCE_ID,
        title: 'Syntetisk testkilde',
        authors_or_issuer: 'Testforfatter',
        publisher_or_journal: 'Syntetisk tidsskrift',
        publication_date: '2026-01-01',
        source_type: 'journal_article',
      },
      source_version: {
        source_version_id: TEST_SOURCE_VERSION_ID,
        retrieved_from: 'file:///syntetisk.pdf',
        retrieved_at: '2026-09-01T00:00:00Z',
        content_hash: TEST_CONTENT_HASH,
        representation: 'full_text',
        document_sha256: `sha256:${'a'.repeat(64)}`,
      },
      representation_text: TEST_REPRESENTATION,
      drugs: [
        { drug_id: TEST_DRUG_ID, label: 'testmiddel' },
        { drug_id: TEST_OTHER_DRUG_ID, label: 'annet testmiddel' },
      ],
      outcomes: [{ outcome_concept_id: TEST_OUTCOME_ID, label: 'vektendring' }],
      populations: [{ population_id: TEST_POPULATION_ID, label: 'voksne i syntetisk prøve' }],
    },
    claim_synthesis: {
      topic: { topic_concept_id: TEST_TOPIC_ID, label: 'vektendring' },
      subject_drug: { drug_id: TEST_DRUG_ID, label: 'testmiddel' },
      claim_id: null,
      populations: [{ population_id: TEST_POPULATION_ID, label: 'voksne i syntetisk prøve' }],
      evidence: [{ evidence_item_id: TEST_EVIDENCE_ID, source: { title: 'Syntetisk testkilde' } }],
    },
    evidence_assessment: {
      dossier: {
        claim_revision_id: TEST_REVISION_ID,
        claim: { statement: 'Syntetisk testpåstand.' },
        links: [{ evidence_item: { evidence_item_id: TEST_EVIDENCE_ID } }],
      },
      seen_evidence_set_digest: `sha256:${'b'.repeat(64)}`,
    },
  }[role]

  const subject = {
    evidence_extraction: { kind: 'kilde', label: 'Syntetisk testkilde' },
    claim_synthesis: { kind: 'påstand', label: 'testmiddel — vektendring' },
    evidence_assessment: { kind: 'påstandsrevisjon', label: 'Syntetisk testpåstand.' },
  }[role]

  return {
    task_version: AGENT_TASK_VERSION,
    answer_version: AGENT_ANSWER_VERSION,
    pipeline_job_id: TEST_JOB_ID,
    job_key: `agent-handoff:${role}:abcdef123456`,
    role,
    prompt_template_version: contract.promptTemplateVersion,
    output_schema_version: contract.outputSchemaVersion,
    request_digest: digestFor(role),
    binding: {
      task_version: AGENT_TASK_VERSION,
      role,
      job_key: `agent-handoff:${role}:abcdef123456`,
      pipeline_job_id: TEST_JOB_ID,
      prompt_template_version: contract.promptTemplateVersion,
      output_schema_version: contract.outputSchemaVersion,
      input,
      prior_runs: [],
    },
    subject,
    registered_model: null,
    input: material,
    ...overrides,
  }
}

/** Svaret en ekstern agent leverer, per rolle. */
export function answerFor(
  role: HandoffRole,
  identity: { provider: string; model: string },
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  const contract = HANDOFF_CONTRACTS[role]
  return {
    answer_version: AGENT_ANSWER_VERSION,
    task_version: AGENT_TASK_VERSION,
    role,
    job_key: `agent-handoff:${role}:abcdef123456`,
    request_digest: digestFor(role),
    output_schema_version: contract.outputSchemaVersion,
    identity: { ...identity, model_version_disclosure: 'not_exposed' },
    answered_at: '2026-09-15T10:12:00Z',
    result: resultFor(role),
    ...overrides,
  }
}

const GROUNDED_FIELDS = [
  'intervention_arm',
  'outcome',
  'reported_direction',
  'availability_semantics',
  'effect_measure',
  'population',
  'sample_size',
  'timepoint',
  'estimate',
  'limitations',
]

/** Et gyldig utkast per rolle. */
export function resultFor(role: HandoffRole): Record<string, unknown> {
  if (role === 'evidence_extraction') {
    return {
      extraction: {
        design_code: 'randomized_controlled_trial',
        population_id: TEST_POPULATION_ID,
        population_availability: 'reported_value',
        population_detail: 'Voksne i syntetisk prøve',
        sample_size: 100,
        sample_size_availability: 'reported_value',
        intervention_drug_id: TEST_DRUG_ID,
        intervention_detail: 'testmiddel',
        comparator_kind: 'none',
        comparator_drug_id: null,
        comparator_detail: null,
        outcome_concept_id: TEST_OUTCOME_ID,
        outcome_detail: 'Vektendring fra baseline',
        timepoint_min: '8 weeks',
        timepoint_max: '8 weeks',
        timepoint_availability: 'reported_value',
        reported_direction: 'increase',
        effect_measure: 'mean_change',
        estimate: '0.8',
        estimate_unit: 'kg',
        estimate_availability: 'reported_value',
        ci_lower: null,
        ci_upper: null,
        ci_level_percent: null,
        confidence_interval_availability: 'not_reported',
        limitations_text: 'Kort varighet og åpen design.',
        source_locator: 'Avsnitt 3',
        source_quote: EXCERPT,
      },
      field_groundings: GROUNDED_FIELDS.map((field) => ({
        check_field: field,
        source_excerpt: EXCERPT,
        source_locator: 'Avsnitt 3',
        justification: `Utdraget oppgir verdien for ${field}.`,
      })),
    }
  }
  if (role === 'claim_synthesis') {
    return {
      claim: {
        statement: 'Testmiddel gir vektøkning etter åtte uker i syntetisk prøve.',
        scope: 'Kun syntetisk databaseprøve.',
        population_id: TEST_POPULATION_ID,
        timeframe_min: '8 weeks',
        timeframe_max: '8 weeks',
        comparator_kind: 'none',
        comparator_drug_id: null,
        direction: 'increase',
        magnitude_measure: 'mean_change',
        magnitude_value: '0.8',
        magnitude_unit: 'kg',
        qualifiers: null,
        uncertainty_summary: 'Ett lite funn, ingen konfidensintervall.',
      },
      evidence_links: [
        {
          evidence_item_id: TEST_EVIDENCE_ID,
          relationship_type: 'supports',
          directness: 'direct',
          relevance_note: 'Funnet gjelder samme virkestoff, endepunkt og tidspunkt.',
        },
      ],
    }
  }
  return {
    assessment: {
      framework: 'grade',
      certainty_level: 'very_low',
      risk_of_bias: 'serious',
      inconsistency: 'not_assessable',
      indirectness: 'not_serious',
      imprecision: 'serious',
      publication_bias: 'not_assessable',
      other_considerations: null,
      rationale: 'Ett lite, åpent funn uten presisjonsmål.',
      evidence_gap: null,
    },
  }
}
