begin;
select plan(12);
select is((select count(*) from knowledge.evidence_items), 0::bigint, 'fresh database has no active evidence items');
select is((select count(*) from knowledge.claims), 0::bigint, 'fresh database has no active claims');
select is((select count(*) from knowledge.claim_revisions), 0::bigint, 'fresh database has no active claim revisions');
select is((select count(*) from knowledge.sources), 2::bigint, 'source library survives the reset');
select is((select count(*) from catalog.drugs), 2::bigint, 'catalog survives the reset');
select is((select count(*) from audit.prototype_resets), 1::bigint, 'one private reset snapshot exists');
select isnt((select snapshot_sha256 from audit.prototype_resets), null, 'snapshot has a fingerprint');
select ok(has_function_privilege('postgres', 'knowledge.assert_clinical_full_text(uuid,uuid)', 'EXECUTE'), 'internal owner can execute full-text gate');
select ok(not has_function_privilege('anon', 'knowledge.assert_clinical_full_text(uuid,uuid)', 'EXECUTE'), 'anonymous role cannot execute internal gate');
select ok(not has_function_privilege('authenticated', 'api.claim_review_workspace(uuid)', 'EXECUTE'), 'old claim workspace is closed');
select ok(not has_function_privilege('authenticated', 'api.extraction_review_workspace(uuid)', 'EXECUTE'), 'old extraction workspace is closed');
select throws_ok(
  $$select knowledge.assert_clinical_full_text('00000000-0000-0000-0000-000000000000', null)$$,
  '22023', 'Kliniske evidensfunn krever en eksplisitt fulltekstversjon.',
  'missing full text is rejected precisely'
);
select * from finish();
rollback;
