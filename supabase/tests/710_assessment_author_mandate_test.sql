-- Migrasjon 005ap — evidensvurderingens opphav som publiseringsvilkår (G10b).
--
-- Fiksturen gjenskaper tilstanden produksjon faktisk sto i etter migrasjon
-- 005am, og som teknisk review fant hullet i:
--
--   * revisjon 1 har en GRADE-vurdering laget av `agent:claim-synthesis`
--     gjennom den gamle synteseveien, uten peker til noen kjøring
--   * revisjon 2 viderefører revisjon 1, laget gjennom den korrigerte veien
--   * den gamle raden lot seg ikke forkaste: discard-veien avviser en påstand
--     hvis evidensfunn er menneskelig kildekontrollert
--
-- Den bærende påstanden: **selv når revisjon 1 får en ellers gyldig
-- claim-verifikasjon, skal den ikke kunne godkjennes eller publiseres.** Uten
-- G10b ville den ordinære reviewflaten kunnet publisere nøyaktig det artefaktet
-- migrasjon 005am ble laget for å erstatte.
--
-- Motprøven står ved siden av: revisjon 2, med kontroll og en vurdering
-- registrert gjennom den korrigerte veien, slipper gjennom de samme
-- forutsetningene. En vakt som avviser alt, er ingen vakt.
--
-- SQLSTATE 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(19);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'workflow', 'assessment_author_has_mandate',
  'workflow.assessment_author_has_mandate() finnes'
);

select ok(
  (select p.prosecdef from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'workflow' and p.proname = 'assessment_author_has_mandate'),
  'mandatfunksjonen er SECURITY DEFINER: den leser bak RLS med default deny'
);

select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'workflow' and p.proname = 'assessment_author_has_mandate'),
      'execute'
    )
  $$,
  'ingen klientrolle kan kjøre mandatfunksjonen direkte'
);

-- ===========================================================================
-- Del 2 — Fikstur: produksjonstilstanden, gjenskapt
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'drug', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extraction_verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';
insert into fixture (name, id) select 'synthesiser', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'assessor', id from provenance.actors where actor_key = 'agent:evidence-assessment';
grant select on fixture to anon, authenticated;

-- En kvalifisert reviewer med egen konto, som i 610, 690 og 700: den navngitte
-- redaktøren har ingen auth-konto i en fersk database.
insert into auth.users (id, instance_id, aud, role, email)
values ('71000000-0000-4000-8000-0000000000a0', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'reviewer710@example.test');

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values ('71000000-0000-4000-8000-0000000000a1', 'human:reviewer-710', 'human', 'Reviewer 710',
        'Kvalifisert reviewer, for 710.', '71000000-0000-4000-8000-0000000000a0');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('71000000-0000-4000-8000-0000000000a0', 'reviewer', null, now() - interval '1 year',
        (select id from fixture where name = 'editor'), 'Reviewer-tildeling for 710.');

insert into fixture (name, id) values ('reviewer', '71000000-0000-4000-8000-0000000000a1');

-- Et menneske UTEN redaktørrolle, til motprøven på mandatet.
insert into auth.users (id, instance_id, aud, role, email)
values ('71000000-0000-4000-8000-0000000000b0', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'ukvalifisert710@example.test');
insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values ('71000000-0000-4000-8000-0000000000b1', 'human:ukvalifisert-710', 'human', 'Ukvalifisert 710',
        'Menneske uten redaktørrolle, for 710.', '71000000-0000-4000-8000-0000000000b0');
insert into fixture (name, id) values ('ukvalifisert', '71000000-0000-4000-8000-0000000000b1');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('71000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 710',
        'Testforfatter 710', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation, retrieved_by_actor_id)
values ('71000000-0000-4000-8000-000000000021', '71000000-0000-4000-8000-000000000001',
        now(), 'https://eutils.example.test/efetch.fcgi?db=pubmed&id=710',
        'sha256:' || repeat('e', 64), 'full_text',
        (select id from fixture where name = 'editor'));

create temporary table cred (label text primary key, secret text not null) on commit drop;
insert into cred select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman');
insert into cred select 'synthesiser', provenance.issue_agent_identity_credential(
  'agent-identity:claim-synthesis-01', 'human:peder-holman');
insert into cred select 'claim', provenance.issue_agent_identity_credential(
  'agent-identity:citation-support-verification-01', 'human:peder-holman');
insert into cred select 'assessor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-assessment-01', 'human:peder-holman');
insert into cred select 'extraction_verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman');
grant select on cred to anon;

create temporary table run (label text primary key, id uuid not null) on commit drop;
grant select, insert on run to anon;

set local role anon;
insert into run
select 'extraction', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_role := 'evidence_extraction',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-24', p_prompt_template_version := 'evidence-extraction/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_source_version_id := '71000000-0000-4000-8000-000000000021',
  p_input_manifest := jsonb_build_object('test', 710)
);
insert into run
select 'extraction_verification', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'extraction_verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-24', p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('test', 710)
);
insert into run
select 'synthesis', api.begin_agent_run(
  p_identity_key := 'agent-identity:claim-synthesis-01',
  p_secret := (select secret from cred where label = 'synthesiser'),
  p_agent_role := 'claim_synthesis',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-24', p_prompt_template_version := 'claim-synthesis/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('test', 710)
);
insert into run
select 'claim', api.begin_agent_run(
  p_identity_key := 'agent-identity:citation-support-verification-01',
  p_secret := (select secret from cred where label = 'claim'),
  p_agent_role := 'citation_support_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-24', p_prompt_template_version := 'claim-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('test', 710)
);
insert into run
select 'assessment', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-assessment-01',
  p_secret := (select secret from cred where label = 'assessor'),
  p_agent_role := 'evidence_assessment',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-24', p_prompt_template_version := 'evidence-assessment/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('test', 710)
);
reset role;

create temporary table item (label text primary key, id uuid not null) on commit drop;
grant select, insert on item to anon;

create function pg_temp.extract() returns uuid language plpgsql as $$
declare
  v_secret text;
  v_run uuid;
begin
  select secret into v_secret from cred where label = 'extractor';
  select id into v_run from run where label = 'extraction';
  perform set_config('role', 'anon', true);
  return api.register_agent_extraction(
    p_identity_key => 'agent-identity:evidence-extraction-01',
    p_secret => v_secret,
    p_agent_run_id => v_run,
    p_source_id => '71000000-0000-4000-8000-000000000001',
    p_source_version_id => '71000000-0000-4000-8000-000000000021',
    p_design_code => 'randomized_controlled_trial',
    p_population_availability => 'not_reported',
    p_population_detail => 'Prøve i 710.',
    p_sample_size_availability => 'not_reported',
    p_intervention_drug_id => (select id from fixture where name = 'drug'),
    p_comparator_kind => 'none',
    p_outcome_concept_id => (select id from fixture where name = 'topic'),
    p_outcome_detail => 'Funn som kan bære en påstand, 710.',
    p_timepoint_availability => 'not_reported',
    p_reported_direction => 'increase',
    p_estimate_availability => 'not_reported',
    p_confidence_interval_availability => 'not_reported',
    p_source_locator => 'Avsnitt for 710',
    p_extraction_method => 'ai_assisted',
    p_field_groundings => jsonb_build_array(
      jsonb_build_object('check_field', 'intervention_arm',
        'source_excerpt', 'Patients received sertraline.',
        'source_locator', 'Metode, avsnitt 1',
        'justification', 'Behandlingsarmen er navngitt i metodeavsnittet.'),
      jsonb_build_object('check_field', 'outcome',
        'source_excerpt', 'Weight change was the primary outcome.',
        'source_locator', 'Metode, avsnitt 2',
        'justification', 'Endepunktet er navngitt i metodeavsnittet.'),
      jsonb_build_object('check_field', 'reported_direction',
        'source_excerpt', 'Weight increased from baseline.',
        'source_locator', 'Resultater, avsnitt 1',
        'justification', 'Retningen står som en økning i resultatavsnittet.'),
      jsonb_build_object('check_field', 'availability_semantics',
        'source_excerpt', 'No values were reported for the weight analysis.',
        'source_locator', 'Resultater, avsnitt 2',
        'justification', 'Feltene uten verdi er ført som ikke rapportert, som kilden sier.')
    )
  );
end;
$$;

insert into item select 'ok', pg_temp.extract();
reset role;

insert into workflow.evidence_verifications (
  evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
  agent_run_id, outcome, source_access, checked_fields, rationale, verified_at
)
select
  i.id, e.created_by_actor_id,
  (select id from fixture where name = 'extraction_verifier'),
  (select id from run where label = 'extraction_verification'),
  'verified', 'verifiable_representation',
  workflow.required_check_fields(i.id),
  'Kontroll registrert av fiksturen i 710.', now()
from item i join knowledge.evidence_items e on e.id = i.id
where i.label = 'ok';

create function pg_temp.synthesise(p_statement text, p_claim uuid default null)
  returns jsonb language plpgsql as $$
declare
  v_secret text;
  v_run uuid;
begin
  select secret into v_secret from cred where label = 'synthesiser';
  select id into v_run from run where label = 'synthesis';
  perform set_config('role', 'anon', true);
  return api.register_claim_synthesis(
    p_identity_key => 'agent-identity:claim-synthesis-01',
    p_secret => v_secret,
    p_agent_run_id => v_run,
    p_claim_id => p_claim,
    p_topic_concept_id => (select id from fixture where name = 'topic'),
    p_subject_drug_id => (select id from fixture where name = 'drug'),
    p_statement => p_statement,
    p_scope => 'Gjelder gjennomsnittlig vektendring fra behandlingsstart.',
    p_comparator_kind => 'none',
    p_direction => 'increase',
    p_uncertainty_summary => 'Grunnlaget er ett evidensfunn fra én studie, uten tallverdi.',
    p_evidence_links => jsonb_build_array(jsonb_build_object(
      'evidence_item_id', (select id from item where label = 'ok'),
      'relationship_type', 'supports',
      'directness', 'direct',
      'relevance_note', 'Funnet rapporterer vektendring for behandlingsarmen påstanden gjelder.'
    ))
  );
end;
$$;

create temporary table revision (label text primary key, payload jsonb not null) on commit drop;
grant select, insert on revision to anon, authenticated;
insert into revision select 'old', pg_temp.synthesise('Påstand 710: revisjonen med den gamle vurderingen.');
reset role;
insert into revision
select 'new', pg_temp.synthesise(
  'Påstand 710: revisjonen laget gjennom den korrigerte veien.',
  (select (payload ->> 'claim_id')::uuid from revision where label = 'old')
);
reset role;

-- Den gamle vurderingen, slik synteseveien faktisk skrev den før 005am: aktøren
-- er synteseagenten, og det finnes ingen peker til noen kjøring.
insert into knowledge.evidence_assessments (
  claim_revision_id, assessed_knowledge_type, framework, certainty_level,
  risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
  rationale, evidence_gap, assessed_at, created_by_actor_id
)
values (
  (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'old'),
  'evidence_synthesis', 'grade', 'very_low',
  'serious', 'not_assessable', 'not_serious', 'not_assessable', 'not_assessable',
  'Vurdering skrevet av synteseveien før migrasjon 005am, gjenskapt i fiksturen for 710.',
  'Størrelsen er ikke tallfestet i det registrerte grunnlaget.',
  now(), (select id from fixture where name = 'synthesiser')
);

-- En gyldig kildestøtteverifikasjon for begge revisjonene. Den er nettopp det
-- som gjør prøven skarp: revisjon 1 mangler ikke lenger noe annet enn et gyldig
-- vurderingsopphav.
create function pg_temp.verify_claim(p_label text) returns uuid language plpgsql as $$
declare
  v_secret text;
  v_run uuid;
  v_revision uuid;
  v_citations jsonb;
begin
  select secret into v_secret from cred where label = 'claim';
  select id into v_run from run where label = 'claim';
  select (payload ->> 'claim_revision_id')::uuid into v_revision from revision where label = p_label;

  select jsonb_agg(jsonb_build_object(
    'claim_evidence_link_id', l.id,
    'source_access', 'original_source',
    'source_version_id', e.source_version_id,
    'checked_content_hash', sv.content_hash,
    'relationship_supported', 'ok'
  ))
    into v_citations
  from knowledge.claim_evidence_links l
  join knowledge.evidence_items e on e.id = l.evidence_item_id
  join knowledge.source_versions sv on sv.id = e.source_version_id
  where l.claim_revision_id = v_revision;

  perform set_config('role', 'anon', true);
  return api.register_claim_verification(
    p_identity_key => 'agent-identity:citation-support-verification-01',
    p_secret => v_secret,
    p_agent_run_id => v_run,
    p_claim_revision_id => v_revision,
    p_outcome => 'verified',
    p_source_support => 'ok', p_population_match => 'ok', p_comparator_match => 'ok',
    p_timeframe_match => 'ok', p_direction_and_magnitude => 'ok',
    p_qualifiers_complete => 'ok', p_contradictory_evidence_represented => 'ok',
    p_citations => v_citations,
    p_rationale => 'Kontroll registrert av fiksturen i 710.'
  );
end;
$$;

select pg_temp.verify_claim('old');
reset role;
select pg_temp.verify_claim('new');
reset role;

-- Den nye revisjonen får vurderingen sin gjennom den korrigerte veien.
create function pg_temp.assess(p_label text) returns jsonb language plpgsql as $$
declare
  v_secret text;
  v_run uuid;
  v_revision uuid;
  v_digest text;
begin
  select secret into v_secret from cred where label = 'assessor';
  select id into v_run from run where label = 'assessment';
  select (payload ->> 'claim_revision_id')::uuid into v_revision from revision where label = p_label;
  v_digest := knowledge.claim_evidence_set_digest(v_revision);

  perform set_config('role', 'anon', true);
  return api.register_evidence_assessment(
    p_identity_key => 'agent-identity:evidence-assessment-01',
    p_secret => v_secret,
    p_agent_run_id => v_run,
    p_claim_revision_id => v_revision,
    p_seen_evidence_set_digest => v_digest,
    p_framework => 'grade',
    p_certainty_level => 'very_low',
    p_rationale => 'Vurdering registrert gjennom den korrigerte veien i fiksturen for 710.',
    p_risk_of_bias => 'serious',
    p_inconsistency => 'not_assessable',
    p_indirectness => 'not_serious',
    p_imprecision => 'not_assessable',
    p_publication_bias => 'not_assessable',
    p_evidence_gap => 'Størrelsen er ikke tallfestet i det registrerte grunnlaget.'
  );
end;
$$;

select pg_temp.assess('new');
reset role;

-- ===========================================================================
-- Del 3 — Mandatet, aktørtype for aktørtype
-- ===========================================================================
select ok(
  workflow.assessment_author_has_mandate(
    (select id from fixture where name = 'assessor'),
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'new'),
    now()
  ),
  'evidensvurderingsagenten har mandatet: rollen er evidence_assessment'
);

select ok(
  not workflow.assessment_author_has_mandate(
    (select id from fixture where name = 'synthesiser'),
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'old'),
    now()
  ),
  'synteseagenten har det ikke: å formulere en påstand er ikke å gradere grunnlaget under den'
);

select ok(
  not workflow.assessment_author_has_mandate(
    (select id from fixture where name = 'extraction_verifier'),
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'new'),
    now()
  ),
  'ekstraksjonsverifikatoren har det heller ikke'
);

select ok(
  not workflow.assessment_author_has_mandate(
    (select id from fixture where name = 'ukvalifisert'),
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'new'),
    now()
  ),
  'et menneske uten editor-tildeling har ikke mandatet'
);

select ok(
  not workflow.assessment_author_has_mandate(
    '71000000-0000-4000-8000-0000000000ff',
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'new'),
    now()
  ),
  'en aktør som ikke finnes, har ikke mandatet — funksjonen svarer nei, den feiler ikke'
);

-- ===========================================================================
-- Del 4 — Den gamle revisjonen slipper ikke gjennom, uansett hvor langt den
--         ellers er kommet
-- ===========================================================================
select is(
  (select cv.outcome::text from workflow.claim_verifications cv
   where cv.claim_revision_id = (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'old')),
  'verified',
  'forutsetningen for prøven: den gamle revisjonen HAR en bekreftet claim-verifikasjon'
);

select throws_ok(
  format(
    $$select knowledge.assert_claim_revision_ready_for_approval(%L::uuid)$$,
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'old')
  ),
  '23001', null,
  'gaten avviser den gamle revisjonen selv om alt annet er på plass (G10b)'
);

select throws_like(
  format(
    $$select knowledge.assert_claim_revision_ready_for_approval(%L::uuid)$$,
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'old')
  ),
  '%uten mandat til å vurdere evidenssikkerheten%',
  'avvisningen sier at det er vurderingens opphav som er problemet'
);

select throws_ok(
  format(
    $$select knowledge.assert_claim_revision_publishable(%L::uuid)$$,
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'old')
  ),
  '23001', null,
  'publiseringsveien avviser den av samme grunn'
);

-- Den ordinære reviewflaten er der konsekvensen faktisk inntreffer: en reviewer
-- som åpner den gamle revisjonen og forsøker å godkjenne den, skal få nei.
--
-- Avtrykket regnes ut før rollebyttet: knowledge ligger bak RLS med default
-- deny, og en reviewer får det gjennom api.claim_review_workspace(uuid), ikke
-- ved å kalle knowledge selv.
create temporary table digest (label text primary key, value text not null) on commit drop;
insert into digest
select 'old', knowledge.claim_evidence_set_digest(
  (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'old'));
grant select on digest to authenticated;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '71000000-0000-4000-8000-0000000000a0', 'role', 'authenticated')::text,
  true
);

select throws_like(
  format(
    $$select api.register_publication_approval(
        %L::uuid,
        %L,
        'approved',
        'Prøve i 710: forsøk på å godkjenne revisjonen med den gamle vurderingen.')$$,
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'old'),
    (select value from digest where label = 'old')
  ),
  '%uten mandat til å vurdere evidenssikkerheten%',
  'den ordinære godkjenningsveien avviser den: normal flyt kan ikke publisere artefaktet'
);
reset role;

-- ===========================================================================
-- Del 5 — Motprøven: den korrigerte revisjonen slipper gjennom
-- ===========================================================================
select lives_ok(
  format(
    $$select knowledge.assert_claim_revision_ready_for_approval(%L::uuid)$$,
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'new')
  ),
  'revisjonen med en vurdering fra riktig ledd er klar for menneskelig vurdering'
);

select is(
  (select ac.actor_key
   from knowledge.evidence_assessments a
   join provenance.actors ac on ac.id = a.created_by_actor_id
   where a.claim_revision_id = (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'new')),
  'agent:evidence-assessment',
  'den nye vurderingen er attribuert til evidensvurderingsagenten'
);

select isnt(
  (select a.agent_run_id from knowledge.evidence_assessments a
   where a.claim_revision_id = (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'new')),
  null,
  'og den peker på kjøringen som gjorde den'
);

-- ===========================================================================
-- Del 6 — Ingenting er fjernet
-- ===========================================================================
select is(
  (select count(*) from knowledge.evidence_assessments a
   where a.claim_revision_id = (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'old')),
  1::bigint,
  'den gamle vurderingen står urørt: gaten sier nei, den sletter ikke historikk'
);

select is(
  (select ac.actor_key
   from knowledge.evidence_assessments a
   join provenance.actors ac on ac.id = a.created_by_actor_id
   where a.claim_revision_id = (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'old')),
  'agent:claim-synthesis',
  'og den bærer fortsatt sin opprinnelige attribusjon: den ble faktisk laget slik'
);

select is(
  (select r.supersedes_revision_id from knowledge.claim_revisions r
   where r.id = (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'new')),
  (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'old'),
  'den korrigerte revisjonen viderefører den gamle framfor å erstatte den i stillhet'
);

select * from finish();
rollback;
