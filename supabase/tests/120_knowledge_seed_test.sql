-- Antidep 2 starts without active derived clinical findings. The source library remains.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);
select is((select count(*) from knowledge.evidence_items), 0::bigint, 'active evidence is empty after reset');
select is((select count(*) from knowledge.evidence_field_groundings), 0::bigint, 'active groundings are empty after reset');
select is((select count(*) from knowledge.sources), 2::bigint, 'the source library is retained');
select is((select count(*) from knowledge.source_versions), 2::bigint, 'source representations are retained for later full-text reacquisition');
select * from finish();
rollback;
