-- API column/type contract. Nullability is a conservative TypeScript contract;
-- Antidep 2's stricter clinical full-text invariant is enforced structurally by
-- the EvidenceItem trigger and tested in 720_antidep2_reset_test.sql.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

create temporary table contract (
  view_name text not null,
  column_name text not null,
  sql_type text not null,
  nullable boolean not null,
  primary key (view_name, column_name)
) on commit drop;

insert into contract (view_name, column_name, sql_type, nullable) values
  ('published_drugs', 'drug_id', 'uuid', false),
  ('published_drugs', 'canonical_name', 'text', false),
  ('published_drugs', 'status', 'text', false),
  ('published_drugs', 'atc_codes', 'text[]', true),
  ('published_drugs', 'published_claim_count', 'bigint', false),
  ('published_claims', 'claim_id', 'uuid', false),
  ('published_claims', 'claim_revision_id', 'uuid', false),
  ('published_claims', 'revision_number', 'integer', false),
  ('published_claims', 'knowledge_type', 'text', false),
  ('published_claims', 'drug_id', 'uuid', false),
  ('published_claims', 'drug_name', 'text', false),
  ('published_claims', 'topic_concept_id', 'uuid', false),
  ('published_claims', 'topic_label', 'text', false),
  ('published_claims', 'statement', 'text', false),
  ('published_claims', 'scope', 'text', false),
  ('published_claims', 'population_id', 'uuid', true),
  ('published_claims', 'population_label', 'text', true),
  ('published_claims', 'timeframe_min', 'interval', true),
  ('published_claims', 'timeframe_max', 'interval', true),
  ('published_claims', 'comparator_kind', 'text', false),
  ('published_claims', 'comparator_drug_id', 'uuid', true),
  ('published_claims', 'comparator_drug_name', 'text', true),
  ('published_claims', 'direction', 'text', true),
  ('published_claims', 'magnitude_measure', 'text', true),
  ('published_claims', 'magnitude_value', 'numeric', true),
  ('published_claims', 'magnitude_unit', 'text', true),
  ('published_claims', 'qualifiers', 'text', true),
  ('published_claims', 'uncertainty_summary', 'text', true),
  ('published_claims', 'certainty_framework', 'text', true),
  ('published_claims', 'certainty_level', 'text', true),
  ('published_claims', 'certainty_rationale', 'text', true),
  ('published_claims', 'evidence_gap', 'text', true),
  ('published_claims', 'last_assessed_at', 'timestamp with time zone', true),
  ('published_claims', 'withdrawn_evidence_count', 'bigint', false),
  ('published_claims', 'content_hash', 'text', false),
  ('published_claims', 'revision_created_at', 'timestamp with time zone', false),
  ('published_claims', 'published_at', 'timestamp with time zone', true),
  ('published_claims', 'last_reviewed_at', 'timestamp with time zone', true),
  ('published_claim_evidence', 'claim_id', 'uuid', false),
  ('published_claim_evidence', 'claim_revision_id', 'uuid', false),
  ('published_claim_evidence', 'claim_evidence_link_id', 'uuid', false),
  ('published_claim_evidence', 'relationship_type', 'text', false),
  ('published_claim_evidence', 'directness', 'text', false),
  ('published_claim_evidence', 'relevance_note', 'text', false),
  ('published_claim_evidence', 'evidence_item_id', 'uuid', false),
  ('published_claim_evidence', 'study_design', 'text', false),
  ('published_claim_evidence', 'population_id', 'uuid', true),
  ('published_claim_evidence', 'population_label', 'text', true),
  ('published_claim_evidence', 'population_detail', 'text', false),
  ('published_claim_evidence', 'population_availability', 'text', false),
  ('published_claim_evidence', 'sample_size', 'integer', true),
  ('published_claim_evidence', 'sample_size_availability', 'text', false),
  ('published_claim_evidence', 'intervention_drug_id', 'uuid', false),
  ('published_claim_evidence', 'intervention_drug_name', 'text', false),
  ('published_claim_evidence', 'intervention_detail', 'text', true),
  ('published_claim_evidence', 'comparator_kind', 'text', false),
  ('published_claim_evidence', 'comparator_drug_id', 'uuid', true),
  ('published_claim_evidence', 'comparator_drug_name', 'text', true),
  ('published_claim_evidence', 'comparator_detail', 'text', true),
  ('published_claim_evidence', 'outcome_concept_id', 'uuid', false),
  ('published_claim_evidence', 'outcome_label', 'text', false),
  ('published_claim_evidence', 'outcome_detail', 'text', false),
  ('published_claim_evidence', 'timepoint_min', 'interval', true),
  ('published_claim_evidence', 'timepoint_max', 'interval', true),
  ('published_claim_evidence', 'timepoint_availability', 'text', false),
  ('published_claim_evidence', 'reported_direction', 'text', false),
  ('published_claim_evidence', 'effect_measure', 'text', true),
  ('published_claim_evidence', 'estimate', 'numeric', true),
  ('published_claim_evidence', 'estimate_unit', 'text', true),
  ('published_claim_evidence', 'estimate_availability', 'text', false),
  ('published_claim_evidence', 'ci_lower', 'numeric', true),
  ('published_claim_evidence', 'ci_upper', 'numeric', true),
  ('published_claim_evidence', 'ci_level_percent', 'numeric', true),
  ('published_claim_evidence', 'confidence_interval_availability', 'text', false),
  ('published_claim_evidence', 'limitations_text', 'text', true),
  ('published_claim_evidence', 'source_locator', 'text', false),
  ('published_claim_evidence', 'extraction_withdrawn', 'boolean', false),
  ('published_claim_evidence', 'extraction_withdrawn_at', 'timestamp with time zone', true),
  ('published_claim_evidence', 'extraction_withdrawal_rationale', 'text', true),
  ('published_claim_evidence', 'source_version_id', 'uuid', true),
  ('published_claim_evidence', 'source_version_retrieved_at', 'timestamp with time zone', true),
  ('published_claim_evidence', 'source_version_retrieved_from', 'text', true),
  ('published_claim_evidence', 'source_version_external_version', 'text', true),
  ('published_claim_evidence', 'source_version_content_hash', 'text', true),
  ('published_claim_evidence', 'source_id', 'uuid', false),
  ('published_claim_evidence', 'source_type', 'text', false),
  ('published_claim_evidence', 'source_title', 'text', false),
  ('published_claim_evidence', 'source_authors_or_issuer', 'text', false),
  ('published_claim_evidence', 'source_publisher_or_journal', 'text', true),
  ('published_claim_evidence', 'source_publication_date', 'date', true),
  ('published_claim_evidence', 'source_publication_date_precision', 'text', true),
  ('published_claim_evidence', 'source_status', 'text', false),
  ('published_claim_evidence', 'source_status_note', 'text', true),
  ('published_claim_evidence', 'source_dois', 'text[]', true),
  ('published_claim_evidence', 'source_pmids', 'text[]', true),
  ('my_actor', 'actor_id', 'uuid', false),
  ('my_actor', 'actor_key', 'text', false),
  ('my_actor', 'display_name', 'text', false),
  ('my_actor', 'retired_at', 'timestamp with time zone', true),
  ('my_roles', 'role_code', 'text', false),
  ('my_roles', 'scope_id', 'uuid', true),
  ('my_roles', 'scope_type', 'text', true),
  ('my_roles', 'valid_from', 'timestamp with time zone', false),
  ('my_roles', 'valid_to', 'timestamp with time zone', true),
  ('editor_sources', 'source_id', 'uuid', false),
  ('editor_sources', 'source_type', 'text', false),
  ('editor_sources', 'title', 'text', false),
  ('editor_sources', 'authors_or_issuer', 'text', false),
  ('editor_sources', 'publisher_or_journal', 'text', true),
  ('editor_sources', 'publication_date', 'date', true),
  ('editor_sources', 'publication_date_precision', 'text', true),
  ('editor_sources', 'source_status', 'text', false),
  ('editor_sources', 'status_note', 'text', true),
  ('editor_source_versions', 'source_version_id', 'uuid', false),
  ('editor_source_versions', 'source_id', 'uuid', false),
  ('editor_source_versions', 'retrieved_at', 'timestamp with time zone', false),
  ('editor_source_versions', 'retrieved_from', 'text', false),
  ('editor_source_versions', 'external_version', 'text', true),
  ('editor_source_versions', 'content_hash', 'text', true),
  ('editor_source_versions', 'representation', 'text', true),
  ('editor_source_versions', 'document_sha256', 'text', true),
  ('editor_source_versions', 'document_byte_size', 'bigint', true),
  ('editor_source_versions', 'document_media_type', 'text', true),
  ('editor_source_versions', 'text_extraction_tool', 'text', true),
  ('editor_source_versions', 'text_extraction_tool_version', 'text', true),
  ('editor_source_versions', 'text_extraction_arguments', 'text', true),
  ('editor_source_versions', 'text_extraction_transform', 'text', true),
  ('editor_drugs', 'drug_id', 'uuid', false),
  ('editor_drugs', 'canonical_name', 'text', false),
  ('editor_drugs', 'status', 'text', false),
  ('editor_outcomes', 'outcome_concept_id', 'uuid', false),
  ('editor_outcomes', 'canonical_label', 'text', false),
  ('editor_outcomes', 'status', 'text', false),
  ('editor_populations', 'population_id', 'uuid', false),
  ('editor_populations', 'canonical_label', 'text', false),
  ('editor_populations', 'status', 'text', false),
  ('editor_evidence_items', 'evidence_item_id', 'uuid', false),
  ('editor_evidence_items', 'source_id', 'uuid', false),
  ('editor_evidence_items', 'source_title', 'text', false),
  ('editor_evidence_items', 'source_version_id', 'uuid', true),
  ('editor_evidence_items', 'study_design', 'text', false),
  ('editor_evidence_items', 'intervention_drug_id', 'uuid', false),
  ('editor_evidence_items', 'intervention_drug_name', 'text', false),
  ('editor_evidence_items', 'comparator_kind', 'text', false),
  ('editor_evidence_items', 'comparator_drug_id', 'uuid', true),
  ('editor_evidence_items', 'comparator_drug_name', 'text', true),
  ('editor_evidence_items', 'outcome_label', 'text', false),
  ('editor_evidence_items', 'outcome_detail', 'text', false),
  ('editor_evidence_items', 'reported_direction', 'text', false),
  ('editor_evidence_items', 'source_locator', 'text', false),
  ('editor_evidence_items', 'extraction_method', 'text', false),
  ('editor_evidence_items', 'created_at', 'timestamp with time zone', false);

select is_empty(
  $$select table_name, column_name, is_nullable
    from information_schema.columns
    where table_schema = 'api' and is_nullable <> 'YES'$$,
  'PostgreSQL reports view-column nullability conservatively'
);

select set_eq(
  $$select ic.table_name || '.' || ic.column_name
    from information_schema.columns ic
    where ic.table_schema = 'api' and ic.data_type = 'ARRAY'$$,
  $$values ('published_claim_evidence.source_dois'),
           ('published_claim_evidence.source_pmids'),
           ('published_drugs.atc_codes')$$,
  'array element types need the pg_attribute contract rather than information_schema'
);

select set_eq(
  $$select c.relname::text, a.attname::text, format_type(a.atttypid, a.atttypmod)
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
    where n.nspname = 'api' and c.relkind = 'v'
      and a.attnum > 0 and not a.attisdropped$$,
  $$select view_name, column_name, sql_type from contract$$,
  'the contract names exactly the columns and SQL types exposed by api'
);

select has_trigger(
  'knowledge', 'evidence_items', 'evidence_items_require_clinical_full_text',
  'EvidenceItems are structurally guarded by the Antidep 2 full-text trigger'
);

select * from finish();
rollback;
