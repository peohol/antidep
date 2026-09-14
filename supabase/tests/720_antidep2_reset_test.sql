begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

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
  $$update audit.prototype_resets set reason = 'changed'$$,
  '23001', null,
  'the private reset snapshot is append-only even for its owner'
);

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference,
  representation, document_sha256, document_byte_size, document_media_type,
  text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
  text_extraction_transform, retrieved_by_actor_id
)
select '72000000-0000-4000-8000-000000000001', id, now(),
       'file:///synthetic-antidep2-test.pdf', 'sha256:' || repeat('a', 64),
       'private://synthetic-antidep2-test.pdf', 'full_text',
       'sha256:' || repeat('b', 64), 1024, 'application/pdf',
       'pdftotext', '24.02.0', '-bbox-layout -enc UTF-8 -eol unix',
       'antidep-reading-order@1',
       (select id from provenance.actors where actor_key = 'agent:evidence-extraction')
from knowledge.sources order by id limit 1;

select lives_ok(
  $$select knowledge.assert_clinical_full_text(
      (select source_id from knowledge.source_versions where id = '72000000-0000-4000-8000-000000000001'),
      '72000000-0000-4000-8000-000000000001')$$,
  'a legitimate document-bound full-text version passes'
);
select lives_ok(
  $$insert into knowledge.evidence_items (
      source_id, source_version_id, design_code, population_availability,
      population_detail, sample_size_availability, intervention_drug_id,
      comparator_kind, outcome_concept_id, outcome_detail, timepoint_availability,
      reported_direction, estimate_availability, confidence_interval_availability,
      source_locator, extraction_method, created_by_actor_id
    )
    select sv.source_id, sv.id, 'randomized_controlled_trial', 'not_reported',
           'Syntetisk testpopulasjon', 'not_reported', d.id, 'none', c.id,
           'Syntetisk testutfall', 'not_reported', 'increase', 'not_reported',
           'not_reported', 'Syntetisk fulltekst, side 1', 'ai_assisted', a.id
    from knowledge.source_versions sv
    join catalog.drugs d on d.canonical_name = 'sertralin'
    join catalog.clinical_concepts c on c.canonical_label = 'vektendring'
    join provenance.actors a on a.actor_key = 'agent:evidence-extraction'
    where sv.id = '72000000-0000-4000-8000-000000000001'$$,
  'a legitimate EvidenceItem passes the production full-text trigger'
);

select throws_ok(
  $$select knowledge.assert_clinical_full_text('00000000-0000-0000-0000-000000000000', '72000000-0000-4000-8000-000000000001')$$,
  '23000', 'Kildeversjonen tilhører ikke evidensfunnets kilde.',
  'a source/version mismatch is rejected precisely'
);

insert into knowledge.source_versions (id, source_id, retrieved_at, retrieved_from, content_hash, representation, retrieved_by_actor_id)
select '72000000-0000-4000-8000-000000000002', id, now(), 'https://example.invalid/abstract',
       'sha256:' || repeat('c', 64), 'abstract',
       (select id from provenance.actors where actor_key = 'agent:evidence-extraction')
from knowledge.sources order by id limit 1;
select throws_ok(
  $$select knowledge.assert_clinical_full_text(
      (select source_id from knowledge.source_versions where id = '72000000-0000-4000-8000-000000000002'),
      '72000000-0000-4000-8000-000000000002')$$,
  '23001', 'Abstract og begrensede representasjoner er bare til kildeoppdagelse; klinisk evidens krever fulltekst.',
  'an abstract is discovery-only'
);
select throws_ok(
  $$select knowledge.assert_clinical_full_text('00000000-0000-0000-0000-000000000000', null)$$,
  '22023', 'Kliniske evidensfunn krever en eksplisitt fulltekstversjon.',
  'missing full text is rejected precisely'
);
select * from finish();
rollback;
