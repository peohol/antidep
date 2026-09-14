-- Antidep 2 starts without active derived claims or assessments.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);
select is((select count(*) from knowledge.claims), 0::bigint, 'active claims are empty after reset');
select is((select count(*) from knowledge.claim_revisions), 0::bigint, 'active claim revisions are empty after reset');
select is((select count(*) from knowledge.claim_evidence_links), 0::bigint, 'active claim/evidence links are empty after reset');
select is((select count(*) from knowledge.evidence_assessments), 0::bigint, 'active assessments are empty after reset');
select is((select count(*) from knowledge.publication_events), 0::bigint, 'there is no publication history in the resettable prototype baseline');
select * from finish();
rollback;
