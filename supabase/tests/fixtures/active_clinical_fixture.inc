-- Isolated Antidep 2 fixture. Included after BEGIN and rolled back by each test.
-- It turns the pre-reset graph shape into explicitly synthetic content and binds
-- every EvidenceItem to a valid document-derived full-text source version.
create function pg_temp.insert_fixture_rows(p_table
regclass, p_rows jsonb) returns void language plpgsql as $$ declare v_columns text; begin select
string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_columns from pg_attribute a where
a.attrelid = p_table and a.attnum > 0 and not a.attisdropped and a.attgenerated = '' and
a.attidentity = ''; execute format( 'insert into %s (%s) select %s from
jsonb_populate_recordset(null::%s, $1)', p_table, v_columns, v_columns, p_table ) using p_rows; end;
$$; create function pg_temp.synthetic_source_id() returns uuid language sql stable as $$ select
'f2000000-0000-4000-8000-000000000001'::uuid $$; create function pg_temp.synthetic_version_id()
returns uuid language sql stable as $$ select 'f2000000-0000-4000-8000-000000000002'::uuid $$;
create function pg_temp.synthetic_source_id_b() returns uuid language sql stable as $$ select
'f2000000-0000-4000-8000-000000000003'::uuid $$; create function pg_temp.synthetic_version_id_b()
returns uuid language sql stable as $$ select 'f2000000-0000-4000-8000-000000000004'::uuid $$;
create function pg_temp.synthetic_source_for(p_original uuid) returns uuid language sql stable as $$
select case source_number when 1 then pg_temp.synthetic_source_id() else
pg_temp.synthetic_source_id_b() end from ( select original_id, row_number() over (order by
original_id) source_number from ( select distinct (value->>'source_id')::uuid original_id from
audit.prototype_resets r, jsonb_array_elements(r.snapshot->'evidence_items') value where r.reset_id
= 'antidep-2-reset-2026-09' ) distinct_ids ) numbered_ids where original_id = p_original $$; create
function pg_temp.synthetic_version_for(p_original uuid) returns uuid language sql stable as $$
select case when pg_temp.synthetic_source_for(p_original) = pg_temp.synthetic_source_id() then
pg_temp.synthetic_version_id() else pg_temp.synthetic_version_id_b() end $$; create function
pg_temp.extraction_actor_id() returns uuid language sql stable as $$ select id from
provenance.actors where actor_key = 'agent:evidence-extraction' $$; insert into knowledge.sources (
id, source_type, title, authors_or_issuer, source_status, created_by_actor_id ) values (
pg_temp.synthetic_source_id(), 'journal_article', 'Syntetisk fulltekstkilde A for databasetest',
'Testforfatter', 'active', pg_temp.extraction_actor_id() ), ( pg_temp.synthetic_source_id_b(),
'journal_article', 'Syntetisk fulltekstkilde B for databasetest', 'Testforfatter', 'active',
pg_temp.extraction_actor_id() ); insert into knowledge.source_versions ( id, source_id,
retrieved_at, retrieved_from, external_version, content_hash, storage_reference, representation,
retrieved_by_actor_id, document_sha256, document_byte_size, document_media_type,
text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
text_extraction_transform ) values ( pg_temp.synthetic_version_id(), pg_temp.synthetic_source_id(),
now(), 'file:///syntetisk-antidep2-fixture-a.pdf', 'synthetic-v1', 'sha256:' || repeat('1', 64),
'private://syntetisk-antidep2-fixture-a.pdf', 'full_text', pg_temp.extraction_actor_id(), 'sha256:'
|| repeat('2', 64), 2048, 'application/pdf', 'pdftotext', '24.02.0', '-bbox-layout -enc UTF-8 -eol
unix', 'antidep-reading-order@1' ), ( pg_temp.synthetic_version_id_b(),
pg_temp.synthetic_source_id_b(), now(), 'file:///syntetisk-antidep2-fixture-b.pdf', 'synthetic-v1',
'sha256:' || repeat('3', 64), 'private://syntetisk-antidep2-fixture-b.pdf', 'full_text',
pg_temp.extraction_actor_id(), 'sha256:' || repeat('4', 64), 2048, 'application/pdf', 'pdftotext',
'24.02.0', '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@1' );

-- Test setup that creates an unrelated EvidenceItem gets its own valid full-text
-- version unless it deliberately supplies one. The production gate still runs
-- after this trigger and validates the resulting binding.
create function pg_temp.bind_test_evidence_to_full_text() returns trigger language plpgsql
as $$ declare v_version uuid; begin if new.source_version_id is null then select id into v_version
from knowledge.source_versions where source_id = new.source_id and representation = 'full_text' and
document_sha256 is not null order by created_at limit 1; if v_version is null then insert into
knowledge.source_versions ( source_id, retrieved_at, retrieved_from, content_hash,
storage_reference, representation, retrieved_by_actor_id, document_sha256, document_byte_size,
document_media_type, text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
text_extraction_transform ) values ( new.source_id, now(), 'file:///syntetisk-testoppsett.pdf',
'sha256:' || encode(extensions.digest(new.source_id::text || clock_timestamp()::text, 'sha256'),
'hex'), 'private://syntetisk-testoppsett.pdf', 'full_text', coalesce(new.created_by_actor_id,
pg_temp.extraction_actor_id()), 'sha256:' || encode(extensions.digest(new.source_id::text ||
'document' || clock_timestamp()::text, 'sha256'), 'hex'), 1024, 'application/pdf', 'pdftotext',
'24.02.0', '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@1' ) returning id into
v_version; end if; new.source_version_id := v_version; end if; return new; end; $$; create trigger
evidence_items_bind_synthetic_test_full_text before insert on knowledge.evidence_items for each row
execute function pg_temp.bind_test_evidence_to_full_text();

-- Restore only the relational shape/identities used by legacy invariant tests.
-- Clinical prose and source bindings are replaced before insertion.
with snapshot as ( select snapshot from audit.prototype_resets where reset_id =
'antidep-2-reset-2026-09' ), rows as ( select jsonb_agg(
jsonb_set(jsonb_set(jsonb_set(jsonb_set(value, '{source_id}',
to_jsonb(pg_temp.synthetic_source_for((value->>'source_id')::uuid))), '{source_version_id}',
to_jsonb(pg_temp.synthetic_version_for((value->>'source_id')::uuid))), '{population_detail}',
'"Syntetisk testpopulasjon"'), '{outcome_detail}', '"Syntetisk testutfall"') ) value from snapshot,
jsonb_array_elements(snapshot->'evidence_items') ) select
pg_temp.insert_fixture_rows('knowledge.evidence_items', coalesce(value, '[]')) from rows; select
pg_temp.insert_fixture_rows('knowledge.evidence_field_groundings',
snapshot->'evidence_field_groundings') from audit.prototype_resets where reset_id =
'antidep-2-reset-2026-09'; select pg_temp.insert_fixture_rows('knowledge.claims',
snapshot->'claims') from audit.prototype_resets where reset_id = 'antidep-2-reset-2026-09'; with s
as (select snapshot from audit.prototype_resets where reset_id = 'antidep-2-reset-2026-09'), r as (
select jsonb_agg(jsonb_set(jsonb_set(value, '{statement}', '"Syntetisk testpåstand"'), '{scope}',
'"Kun syntetisk databasetest"')) value from s, jsonb_array_elements(snapshot->'claim_revisions') )
select pg_temp.insert_fixture_rows('knowledge.claim_revisions', coalesce(value, '[]')) from r;
select pg_temp.insert_fixture_rows('knowledge.claim_evidence_links',
snapshot->'claim_evidence_links') from audit.prototype_resets where reset_id =
'antidep-2-reset-2026-09'; select pg_temp.insert_fixture_rows('knowledge.evidence_assessments',
snapshot->'evidence_assessments') from audit.prototype_resets where reset_id =
'antidep-2-reset-2026-09'; select pg_temp.insert_fixture_rows('workflow.evidence_verifications',
snapshot->'evidence_verifications') from audit.prototype_resets where reset_id =
'antidep-2-reset-2026-09'; select pg_temp.insert_fixture_rows('workflow.claim_verifications',
snapshot->'claim_verifications') from audit.prototype_resets where reset_id =
'antidep-2-reset-2026-09'; select
pg_temp.insert_fixture_rows('workflow.claim_verification_citations',
snapshot->'claim_verification_citations') from audit.prototype_resets where reset_id =
'antidep-2-reset-2026-09'; select pg_temp.insert_fixture_rows('workflow.review_decisions',
snapshot->'review_decisions') from audit.prototype_resets where reset_id =
'antidep-2-reset-2026-09';
