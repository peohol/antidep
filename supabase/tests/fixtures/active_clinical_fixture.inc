-- Explicit synthetic Antidep 2 graph. Included after BEGIN and rolled back by each test.
-- Preserve the migrated audit baseline so this shared fixture does not pollute
-- tests that make exhaustive assertions about their own audit effects.
create temporary table fixture_audit_baseline on commit drop as
select id from audit.events;

create function pg_temp.extraction_actor_id() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'agent:evidence-extraction'
$$;
create function pg_temp.synthesis_actor_id() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'agent:claim-synthesis'
$$;
create function pg_temp.assessment_actor_id() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'agent:evidence-assessment'
$$;

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('f2000000-0000-4000-8000-000000000001', 'journal_article', 'Syntetisk fulltekstkilde A for databasetest', 'Testforfatter', pg_temp.extraction_actor_id()),
  ('f2000000-0000-4000-8000-000000000003', 'journal_article', 'Syntetisk fulltekstkilde B for databasetest', 'Testforfatter', pg_temp.extraction_actor_id());

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, external_version, content_hash,
  storage_reference, representation, retrieved_by_actor_id, document_sha256,
  document_byte_size, document_media_type, text_extraction_tool,
  text_extraction_tool_version, text_extraction_arguments, text_extraction_transform
) values
  ('f2000000-0000-4000-8000-000000000002', 'f2000000-0000-4000-8000-000000000001', now(), 'file:///syntetisk-a.pdf', 'synthetic-v1', 'sha256:' || repeat('1', 64), 'private://syntetisk-a.pdf', 'full_text', pg_temp.extraction_actor_id(), 'sha256:' || repeat('2', 64), 2048, 'application/pdf', 'pdftotext', '24.02.0', '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@1'),
  ('f2000000-0000-4000-8000-000000000004', 'f2000000-0000-4000-8000-000000000003', now(), 'file:///syntetisk-b.pdf', 'synthetic-v1', 'sha256:' || repeat('3', 64), 'private://syntetisk-b.pdf', 'full_text', pg_temp.extraction_actor_id(), 'sha256:' || repeat('4', 64), 2048, 'application/pdf', 'pdftotext', '24.02.0', '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@1');

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_id,
  population_availability, population_detail, sample_size, sample_size_availability,
  intervention_drug_id, comparator_kind, outcome_concept_id, outcome_detail,
  timepoint_min, timepoint_max, timepoint_availability, reported_direction,
  effect_measure, estimate, estimate_unit, estimate_availability,
  confidence_interval_availability, limitations_text, source_locator,
  extraction_method, raw_extraction, created_by_actor_id
)
select
  case d.canonical_name when 'sertralin' then 'f2000000-0000-4000-8000-000000000011'::uuid else 'f2000000-0000-4000-8000-000000000012'::uuid end,
  case d.canonical_name when 'sertralin' then 'f2000000-0000-4000-8000-000000000001'::uuid else 'f2000000-0000-4000-8000-000000000003'::uuid end,
  case d.canonical_name when 'sertralin' then 'f2000000-0000-4000-8000-000000000002'::uuid else 'f2000000-0000-4000-8000-000000000004'::uuid end,
  'randomized_controlled_trial', p.id, 'reported_value', 'Syntetisk testpopulasjon',
  100, 'reported_value', d.id, 'none', c.id, 'Syntetisk testutfall',
  interval '8 weeks', interval '8 weeks', 'reported_value', 'increase',
  'mean_change', case d.canonical_name when 'sertralin' then null else 0.8 end,
  case d.canonical_name when 'sertralin' then 'percent'::knowledge.estimate_unit else 'kg'::knowledge.estimate_unit end,
  case d.canonical_name when 'sertralin' then 'not_reported'::knowledge.value_availability else 'reported_value'::knowledge.value_availability end,
  'not_reported', 'Kun syntetiske data.', 'Syntetisk tabell 1', 'ai_assisted',
  jsonb_build_object('synthetic', true), pg_temp.extraction_actor_id()
from catalog.drugs d
cross join catalog.populations p
cross join catalog.clinical_concepts c
where d.canonical_name in ('sertralin', 'mirtazapin')
  and p.canonical_label = 'voksne med depressiv lidelse'
  and c.canonical_label = 'vektendring';

insert into knowledge.claims (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
select case d.canonical_name when 'sertralin' then 'f2000000-0000-4000-8000-000000000021'::uuid else 'f2000000-0000-4000-8000-000000000022'::uuid end,
       'evidence_synthesis', c.id, d.id, pg_temp.synthesis_actor_id()
from catalog.drugs d cross join catalog.clinical_concepts c
where d.canonical_name in ('sertralin', 'mirtazapin') and c.canonical_label = 'vektendring';

insert into knowledge.claim_revisions (
  id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
  population_id, timeframe_min, timeframe_max, comparator_kind, direction,
  qualifiers, uncertainty_summary, created_by_actor_id
)
select case d.canonical_name when 'sertralin' then 'f2000000-0000-4000-8000-000000000031'::uuid else 'f2000000-0000-4000-8000-000000000032'::uuid end,
       cl.id, 1, cl.knowledge_type, cl.subject_drug_id, 'Syntetisk testpåstand',
       'Kun syntetisk databasetest', p.id, interval '8 weeks', interval '8 weeks',
       'none', 'increase', 'Ingen klinisk betydning.', 'Syntetisk usikkerhet.',
       pg_temp.synthesis_actor_id()
from knowledge.claims cl
join catalog.drugs d on d.id = cl.subject_drug_id
cross join catalog.populations p
where p.canonical_label = 'voksne med depressiv lidelse';

insert into knowledge.claim_evidence_links (
  claim_revision_id, evidence_item_id, relationship_type, directness,
  relevance_note, created_by_actor_id
)
select r.id, e.id, 'supports', 'direct', 'Syntetisk relevans.', pg_temp.synthesis_actor_id()
from knowledge.claim_revisions r
join knowledge.evidence_items e on e.intervention_drug_id = r.subject_drug_id;

insert into knowledge.evidence_assessments (
  claim_revision_id, assessed_knowledge_type, framework, certainty_level,
  risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
  rationale, evidence_gap, assessed_at, created_by_actor_id
)
select r.id, r.knowledge_type, 'grade', 'very_low', 'serious', 'not_assessable',
       'not_serious', 'not_assessable', 'not_assessable',
       'Syntetisk vurdering med alle nødvendige domener.',
       'Syntetisk testgrunnlag har med vilje begrenset dekning.', now(),
       pg_temp.assessment_actor_id()
from knowledge.claim_revisions r;

-- Remove only audit rows produced by the shared synthetic graph. Tests that
-- create rows after this point still see and can assert their own audit events.
set local session_replication_role = replica;
delete from audit.events e
where not exists (select 1 from fixture_audit_baseline b where b.id = e.id);
set local session_replication_role = origin;

-- Older invariant tests create their own source versions using the pre-Antidep-2
-- column set. For known test fixtures, complete the row at INSERT time while
-- preserving its id. Agent runs and EvidenceItems must reference exactly the
-- same source-version id.
create function pg_temp.complete_legacy_test_source_version() returns trigger language plpgsql as $$
declare
  v_prefix text := left(new.id::text, 3);
  v_title text;
begin
  select s.title into v_title from knowledge.sources s where s.id = new.source_id;
  if v_prefix in ('340','400','440','460','470','480','490','590','600','610','620','630','670','680','690','700','710')
     or v_title in ('Immutabilitetstestkilde', 'Upublisert testkilde for 400') then
    new.representation := 'full_text';
    new.content_hash := coalesce(new.content_hash,
      'sha256:' || encode(extensions.digest(convert_to(new.id::text || ':text', 'UTF8'), 'sha256'), 'hex'));
    new.storage_reference := coalesce(new.storage_reference,
      'private://syntetisk-testoppsett/' || new.id::text || '/original.pdf');
    new.document_sha256 := coalesce(new.document_sha256,
      'sha256:' || encode(extensions.digest(convert_to(new.id::text || ':pdf', 'UTF8'), 'sha256'), 'hex'));
    new.document_byte_size := coalesce(new.document_byte_size, 1024);
    new.document_media_type := coalesce(new.document_media_type, 'application/pdf');
    new.text_extraction_tool := coalesce(new.text_extraction_tool, 'pdftotext');
    new.text_extraction_tool_version := coalesce(new.text_extraction_tool_version, '24.02.0');
    new.text_extraction_arguments := coalesce(new.text_extraction_arguments, '-bbox-layout -enc UTF-8 -eol unix');
    new.text_extraction_transform := coalesce(new.text_extraction_transform, 'antidep-reading-order@1');
  end if;
  return new;
end;
$$;
create trigger source_versions_complete_legacy_test_fulltext
  before insert on knowledge.source_versions
  for each row execute function pg_temp.complete_legacy_test_source_version();

-- Tests that omit source_version_id entirely predate Antidep 2. Give only those
-- rows a synthetic full-text binding. Explicit references are never remapped:
-- invalid/cross-source references must still be rejected by production rules.
create function pg_temp.bind_test_evidence_to_full_text() returns trigger language plpgsql as $$
declare
  v_version uuid;
begin
  if new.source_version_id is not null then
    return new;
  end if;

  select sv.id into v_version
  from knowledge.source_versions sv
  where sv.source_id = new.source_id
    and sv.representation = 'full_text'::knowledge.source_representation
    and sv.document_sha256 ~ '^sha256:[0-9a-f]{64}$'
    and sv.document_byte_size > 0
    and sv.document_media_type = 'application/pdf'
    and sv.content_hash ~ '^sha256:[0-9a-f]{64}$'
    and nullif(btrim(sv.text_extraction_tool), '') is not null
    and nullif(btrim(sv.text_extraction_tool_version), '') is not null
    and nullif(btrim(sv.text_extraction_arguments), '') is not null
  order by sv.created_at, sv.id
  limit 1;

  if v_version is null then
    insert into knowledge.source_versions (
      source_id, retrieved_at, retrieved_from, content_hash, storage_reference,
      representation, retrieved_by_actor_id, document_sha256, document_byte_size,
      document_media_type, text_extraction_tool, text_extraction_tool_version,
      text_extraction_arguments, text_extraction_transform
    ) values (
      new.source_id, now(),
      'file:///syntetisk-testoppsett-' || new.source_id::text || '.pdf',
      'sha256:' || encode(extensions.digest(convert_to(new.source_id::text || ':test-fulltext', 'UTF8'), 'sha256'), 'hex'),
      'private://syntetisk-testoppsett/' || new.source_id::text || '/original.pdf',
      'full_text', coalesce(new.created_by_actor_id, pg_temp.extraction_actor_id()),
      'sha256:' || encode(extensions.digest(convert_to(new.source_id::text || ':test-document', 'UTF8'), 'sha256'), 'hex'),
      1024, 'application/pdf', 'pdftotext', '24.02.0',
      '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@1'
    ) returning id into v_version;
  end if;

  new.source_version_id := v_version;
  return new;
end;
$$;
create trigger evidence_items_bind_synthetic_test_full_text
  before insert on knowledge.evidence_items
  for each row execute function pg_temp.bind_test_evidence_to_full_text();

-- Registration-order tests still exercise the durable database ordering rule
-- through a retired helper RPC. Re-open it only inside the pgTAP transaction;
-- production keeps the Antidep 2 REVOKE from migration 20260925090000.
grant execute on function api.register_publication_approval(uuid, text, text, text) to authenticated;
