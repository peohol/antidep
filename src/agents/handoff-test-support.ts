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
export const TEST_SEARCH_PLAN_ID = '78000000-0000-4000-8000-0000000000a9'
export const TEST_NEED_REFERENCE = 'abcdef0123456789abcdef0123456789'

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

const DIGEST_SEEDS: Readonly<Record<HandoffRole, string>> = {
  evidence_extraction: '1',
  claim_synthesis: '2',
  evidence_assessment: '3',
  source_discovery: '4',
  source_quality_assessment: '5',
  monograph_answer: '6',
}

function digestFor(role: HandoffRole): string {
  return `sha256:${DIGEST_SEEDS[role].repeat(64)}`
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
    source_discovery: {
      search_plan_id: TEST_SEARCH_PLAN_ID,
      plan_version: 1,
      profile_code: 'EFF',
      scope_digest: `sha256:${'c'.repeat(64)}`,
      need_ids: [TEST_OUTCOME_ID],
      searches_seen: 0,
      candidates_seen: 0,
    },
    source_quality_assessment: {
      search_plan_id: TEST_SEARCH_PLAN_ID,
      plan_version: 1,
      profile_code: 'EFF',
      scope_digest: `sha256:${'c'.repeat(64)}`,
      need_ids: [TEST_OUTCOME_ID],
      searches_seen: 1,
      candidates_seen: 1,
    },
    monograph_answer: {
      monograph_need_id: TEST_OUTCOME_ID,
      scope_digest: `sha256:${'c'.repeat(64)}`,
      source_version_id: TEST_SOURCE_VERSION_ID,
      content_hash: `sha256:${'d'.repeat(64)}`,
      representation: 'regulatory_summary',
    },
  }[role]

  const discoveryMaterial = {
    search_plan_id: TEST_SEARCH_PLAN_ID,
    plan_reference: 'a'.repeat(32),
    plan_version: 1,
    drug: 'testmiddel',
    standard_version: '1.0.0',
    source_profile: {
      code: 'EFF',
      question: 'Effekt, dose–respons, behandlingsfaser og sammenligning',
      first_choice: 'Relevante systematiske oversikter',
      supplement_and_control: 'Oppdateringssøk etter oversiktens siste søkedato',
    },
    scope: { drug: 'testmiddel', outcome: 'vektendring' },
    needs: [
      {
        need_reference: TEST_NEED_REFERENCE,
        template: 'MN12',
        section: '3.3 Dokumentert effekt',
        question: 'Hvor stor er endringen i relevante symptomer sammenlignet med komparator?',
        requirement: 'B: aktiv indikasjon',
        answer_form: 'estimate',
      },
    ],
    required_tracks: [
      {
        code: 'bibliographic_database',
        label: 'PubMed/MEDLINE eller et tilsvarende bibliografisk søk',
        state: 'pending',
        note: null,
      },
    ],
    searches_so_far: [],
    candidates_so_far: [],
    closure_criteria: {
      outstanding: 'Disse obligatoriske søkesporene er ikke forsøkt ennå: PubMed/MEDLINE.',
      requirements: ['Hvert obligatorisk søkespor må være forsøkt og dokumentert.'],
      not_sufficient: ['At tre artikler er funnet.'],
    },
    rules: ['En foreslått søkestreng er ikke et utført søk.'],
  }

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
    monograph_answer: {
      need: {
        need_reference: TEST_NEED_REFERENCE,
        template_code: 'MN03',
        question:
          'Hvilke norske produkter finnes? Handelsnavn, formulering, administrasjonsvei, styrke og relevant pakningsidentitet.',
        answer_form: 'table',
        requirement: 'mandatory',
        scope: null,
        scope_not_applicable: [],
        standard_version: '1.0.0',
      },
      approved_use: 'Oppgir handelsnavn, formulering, styrke og pakningsidentitet.',
      drug: 'testmiddel',
      source: {
        title: 'Syntetisk preparatomtale',
        authors_or_issuer: 'Syntetisk myndighet',
        publisher_or_journal: null,
        source_type: 'summary_of_product_characteristics',
        publication_date: null,
      },
      source_version: {
        retrieved_from: 'https://example.test/preparatomtale',
        retrieved_at: '2026-09-15T09:00:00Z',
        representation: 'regulatory_summary',
        content_hash: `sha256:${'d'.repeat(64)}`,
      },
      representation_text: 'Testmiddel tabletter 50 mg. Pakning med 28 tabletter.',
    },
    source_discovery: discoveryMaterial,
    source_quality_assessment: {
      ...discoveryMaterial,
      control_task: {
        instruction: 'Kontroller søkedekningen.',
        own_search_required: true,
        own_search_rule: 'Rapporter dine egne motsøk i «searches».',
        excluded_candidates: [],
        unresolved_candidates: [],
      },
    },
  }[role]

  const subject = {
    evidence_extraction: { kind: 'kilde', label: 'Syntetisk testkilde' },
    claim_synthesis: { kind: 'påstand', label: 'testmiddel — vektendring' },
    evidence_assessment: { kind: 'påstandsrevisjon', label: 'Syntetisk testpåstand.' },
    source_discovery: {
      kind: 'søkeplan',
      label: 'testmiddel — Effekt, dose–respons, behandlingsfaser og sammenligning',
    },
    source_quality_assessment: {
      kind: 'kontroll av søkedekning',
      label: 'testmiddel — Effekt, dose–respons, behandlingsfaser og sammenligning',
    },
    monograph_answer: { kind: 'monografisvar', label: 'testmiddel — MN03' },
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

/**
 * Svaret en ekstern agent leverer, per rolle.
 *
 * `identity` kan være `null`, og da utelates feltet helt. Det er ikke et
 * kunstig tilfelle: en Workspace Agent som ikke får vite hvilken modell den
 * kjører, skal levere svaret uten feltet framfor å gjette.
 */
export function answerFor(
  role: HandoffRole,
  identity: { provider: string; model: string } | null,
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
    ...(identity === null
      ? {}
      : { identity: { ...identity, model_version_disclosure: 'not_exposed' } }),
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
  if (role === 'source_discovery') {
    return {
      searches: [
        {
          platform: 'Europe PMC',
          query_string: 'testmiddel AND weight change AND systematic review',
          filters: 'ingen språk- eller årsavgrensning',
          outcome: 'executed',
          result_count: 12,
          screened_count: 12,
          truncated: false,
          truncation_note: null,
          limitation_note: null,
          track_codes: ['bibliographic_database'],
        },
      ],
      candidates: [
        {
          identifier_kind: 'doi',
          identifier_value: '10.1000/syntetisk-oversikt',
          title: 'Syntetisk oversikt om testmiddel og vektendring',
          authors_or_issuer: 'Testforfatter',
          publisher_or_journal: 'Syntetisk tidsskrift',
          publication_year: 2025,
          discovery_path: 'Oversiktssøk i Europe PMC',
          access_limited: false,
          access_limitation_note: null,
          could_change_conclusion: false,
          materiality_reason: null,
          decision: 'selected_for_retrieval',
          decision_reason: 'Dekker endepunktet og avgrensningen behovet gjelder.',
          uses: [
            {
              need_reference: TEST_NEED_REFERENCE,
              proposed_use: 'Kan dokumentere endringen i vekt for den avgrensede populasjonen.',
            },
          ],
        },
      ],
      term_proposals: [],
      note: null,
    }
  }
  if (role === 'monograph_answer') {
    return {
      answer: {
        knowledge_type: 'product_data',
        statement:
          'Testmiddel finnes som tabletter 50 mg i pakning med 28 tabletter, ifølge preparatomtalen.',
        structured_value: { strength_mg: 50, pack_size: 28 },
        uncertainty_summary: null,
        limitation_note: null,
        as_of: '2026-09-01',
        source_quote: 'Testmiddel tabletter 50 mg. Pakning med 28 tabletter.',
        source_locator: 'Avsnitt 3',
        recommending_body: null,
        recommendation_date: null,
        additional_sources: [],
      },
    }
  }
  if (role === 'source_quality_assessment') {
    return {
      searches: [
        {
          platform: 'PubMed',
          query_string: 'testmiddel[tiab] AND (weight OR appetite)',
          filters: null,
          outcome: 'zero_results',
          result_count: 0,
          screened_count: 0,
          truncated: false,
          truncation_note: null,
          limitation_note: null,
          track_codes: ['bibliographic_database'],
        },
      ],
      candidates: [],
      control: {
        outcome: 'accepted',
        note: 'Eget motsøk i et uavhengig spor ga ingen oversette kilder, og eksklusjonene er gjennomgått.',
        searched_independently: true,
        missed_candidates: 0,
        exclusions_checked: 1,
        materiality_assessed: true,
      },
      note: null,
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
