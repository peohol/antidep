-- Migrasjon 005am, 005an og 004b — evidensvurderingen som sitt eget ledd.
--
-- Fram til migrasjon 005am skrev api.register_claim_synthesis(...) påstanden,
-- evidenslenkene OG den endelige GRADE-vurderingen i én transaksjon, med samme
-- aktør og samme legitimasjon. EVIDENCE_PIPELINE.md §61 skiller `ClaimAgent` fra
-- `EvidenceAssessor` og krever at ansvarsgrensen samtidig er en teknisk grense;
-- med den gamle veien var skillet bare et navn.
--
-- Filen dekker den nye veien: at graderingen krever rollen evidence_assessment
-- og ingen annen, at den kommer ETTER kildestøtteverifikasjonen
-- (MVP_IMPLEMENTATION_PLAN.md §15), at kontrollnivået på evidensen leses på nytt
-- på vurderingstidspunktet, at vurderingen gjelder nøyaktig det evidenssettet
-- kalleren så, og at den forsegler settet.
--
-- Den bærende påstanden: hvert vilkår er prøvd ved å svekke det. En vakt som
-- aldri er sett feile, er ikke en vakt.
--
-- SQLSTATE 22023 = invalid_parameter_value, P0002 = no_data_found,
-- 23001 = restrict_violation, 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(34);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'register_evidence_assessment', 'api.register_evidence_assessment() finnes'
);

select ok(
  (select p.prosecdef from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname = 'register_evidence_assessment'),
  'api.register_evidence_assessment() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);

select is_empty(
  $$
    select r.role_name
    from (values ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api' and p.proname = 'register_evidence_assessment'),
      'execute'
    )
  $$,
  'verken service_role eller PUBLIC har EXECUTE på vurderingsveien'
);

select ok(
  has_function_privilege(
    'anon',
    (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'api' and p.proname = 'register_evidence_assessment'),
    'execute'
  ),
  'anon har EXECUTE: kontrollen er legitimasjonen, ikke Data API-rollen'
);

select has_function(
  'workflow', 'assert_claim_verified_before_assessment',
  'workflow.assert_claim_verified_before_assessment() finnes'
);

-- Proveniensen på vurderingen (migrasjon 004b).
select has_column(
  'knowledge', 'evidence_assessments', 'agent_run_id',
  'knowledge.evidence_assessments har agent_run_id'
);
select has_column(
  'knowledge', 'evidence_assessments', 'agent_run_role',
  'knowledge.evidence_assessments har agent_run_role'
);
select col_is_null(
  'knowledge', 'evidence_assessments', 'agent_run_id',
  'agent_run_id er NULL-bar: en redaktørs egen vurdering kom ikke av en kjøring'
);
select ok(
  (select a.attgenerated = 's'
   from pg_attribute a
   where a.attrelid = 'knowledge.evidence_assessments'::regclass
     and a.attname = 'agent_run_role'),
  'agent_run_role er en generert kolonne, ikke en verdi kalleren oppgir'
);

-- ===========================================================================
-- Del 2 — Fikstur
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'drug', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';
insert into fixture (name, id) select 'synthesiser', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'assessor', id from provenance.actors where actor_key = 'agent:evidence-assessment';
grant select on fixture to anon;

-- En kvalifisert reviewer med egen konto, som i 610 og 690: den navngitte
-- redaktøren har ingen auth-konto i en fersk database, og tilbaketrekkingen i
-- del 11 er en faglig beslutning som krever en kvalifisert aktør.
insert into auth.users (id, instance_id, aud, role, email)
values ('70000000-0000-4000-8000-0000000000a0', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'reviewer700@example.test');

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values ('70000000-0000-4000-8000-0000000000a1', 'human:reviewer-700', 'human', 'Reviewer 700',
        'Kvalifisert reviewer, for 700.', '70000000-0000-4000-8000-0000000000a0');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('70000000-0000-4000-8000-0000000000a0', 'reviewer', null, now() - interval '1 year',
        (select id from fixture where name = 'editor'), 'Reviewer-tildeling for 700.');

insert into fixture (name, id) values ('reviewer', '70000000-0000-4000-8000-0000000000a1');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('70000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 700',
        'Testforfatter 700', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation, retrieved_by_actor_id)
values ('70000000-0000-4000-8000-000000000021', '70000000-0000-4000-8000-000000000001',
        now(), 'https://eutils.example.test/efetch.fcgi?db=pubmed&id=700',
        'sha256:' || repeat('c', 64), 'full_text',
        (select id from fixture where name = 'editor'));

create temporary table cred (label text primary key, secret text not null) on commit drop;
insert into cred select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman');
insert into cred select 'verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman');
insert into cred select 'synthesiser', provenance.issue_agent_identity_credential(
  'agent-identity:claim-synthesis-01', 'human:peder-holman');
insert into cred select 'claim', provenance.issue_agent_identity_credential(
  'agent-identity:citation-support-verification-01', 'human:peder-holman');
insert into cred select 'assessor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-assessment-01', 'human:peder-holman');
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
  p_input_source_version_id := '70000000-0000-4000-8000-000000000021',
  p_input_manifest := jsonb_build_object('test', 700)
);
insert into run
select 'verification', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-24', p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('test', 700)
);
insert into run
select 'synthesis', api.begin_agent_run(
  p_identity_key := 'agent-identity:claim-synthesis-01',
  p_secret := (select secret from cred where label = 'synthesiser'),
  p_agent_role := 'claim_synthesis',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-24', p_prompt_template_version := 'claim-synthesis/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('test', 700)
);
insert into run
select 'claim', api.begin_agent_run(
  p_identity_key := 'agent-identity:citation-support-verification-01',
  p_secret := (select secret from cred where label = 'claim'),
  p_agent_role := 'citation_support_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-24', p_prompt_template_version := 'claim-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('test', 700)
);
insert into run
select 'assessment', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-assessment-01',
  p_secret := (select secret from cred where label = 'assessor'),
  p_agent_role := 'evidence_assessment',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-24', p_prompt_template_version := 'evidence-assessment/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('test', 700)
);
reset role;

create function pg_temp.extract(p_detail text) returns uuid language plpgsql as $$
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
    p_source_id => '70000000-0000-4000-8000-000000000001',
    p_source_version_id => '70000000-0000-4000-8000-000000000021',
    p_design_code => 'randomized_controlled_trial',
    p_population_availability => 'not_reported',
    p_population_detail => 'Prøve i 700.',
    p_sample_size_availability => 'not_reported',
    p_intervention_drug_id => (select id from fixture where name = 'drug'),
    p_comparator_kind => 'none',
    p_outcome_concept_id => (select id from fixture where name = 'topic'),
    p_outcome_detail => p_detail,
    p_timepoint_availability => 'not_reported',
    p_reported_direction => 'increase',
    p_estimate_availability => 'not_reported',
    p_confidence_interval_availability => 'not_reported',
    p_source_locator => 'Avsnitt for 700',
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

create temporary table item (label text primary key, id uuid not null) on commit drop;
grant select, insert on item to anon;
insert into item select 'ok', pg_temp.extract('Funn som kan bære en påstand, 700.');
reset role;

insert into workflow.evidence_verifications (
  evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
  agent_run_id, outcome, source_access, checked_fields, rationale, verified_at
)
select
  i.id, e.created_by_actor_id,
  (select id from fixture where name = 'verifier'),
  (select id from run where label = 'verification'),
  'verified', 'verifiable_representation',
  workflow.required_check_fields(i.id),
  'Kontroll registrert av fiksturen i 700.', now()
from item i join knowledge.evidence_items e on e.id = i.id
where i.label = 'ok';

-- Én påstandsrevisjon per scenario. Alt annet enn ordlyden er likt, slik at en
-- avvisning ikke kan komme av at to kall var forskjellige på noe annet.
create function pg_temp.synthesise(p_statement text) returns jsonb
  language plpgsql as $$
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
grant select, insert on revision to anon;
insert into revision select 'verified', pg_temp.synthesise('Påstand 700-A: kontrollert og klar til gradering.');
reset role;
insert into revision select 'unverified', pg_temp.synthesise('Påstand 700-B: ingen kildestøtteverifikasjon.');
reset role;
insert into revision select 'uncertain', pg_temp.synthesise('Påstand 700-C: kontrollen konkluderte ikke.');
reset role;
insert into revision select 'withdrawn', pg_temp.synthesise('Påstand 700-D: ekstraksjonen trekkes tilbake etterpå.');
reset role;

-- Kildestøtteverifikasjonen. Kontrollen må dekke hele evidenssettet, så
-- sitatraden bygges av de lenkene revisjonen faktisk har.
create function pg_temp.verify_claim(p_label text, p_outcome text, p_supported text)
  returns uuid language plpgsql as $$
declare
  v_secret text;
  v_run uuid;
  v_revision uuid;
  v_citations jsonb;
begin
  select secret into v_secret from cred where label = 'claim';
  select id into v_run from run where label = 'claim';
  select (payload ->> 'claim_revision_id')::uuid into v_revision
  from revision where label = p_label;

  select jsonb_agg(jsonb_build_object(
    'claim_evidence_link_id', l.id,
    'source_access', 'original_source',
    'source_version_id', e.source_version_id,
    'checked_content_hash', sv.content_hash,
    'relationship_supported', p_supported,
    'finding', case when p_supported = 'ok' then null
                    else 'Relasjonstypen lot seg ikke bedømme i fiksturen for 700.' end
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
    p_outcome => p_outcome,
    p_source_support => p_supported,
    p_population_match => p_supported,
    p_comparator_match => p_supported,
    p_timeframe_match => p_supported,
    p_direction_and_magnitude => p_supported,
    p_qualifiers_complete => p_supported,
    p_contradictory_evidence_represented => p_supported,
    p_citations => v_citations,
    p_rationale => 'Kontroll registrert av fiksturen i 700.',
    p_findings => case when p_outcome = 'verified' then null else 'Kontrollen konkluderte ikke.' end
  );
end;
$$;

select pg_temp.verify_claim('verified', 'verified', 'ok');
reset role;
select pg_temp.verify_claim('uncertain', 'uncertain', 'not_assessable');
reset role;
select pg_temp.verify_claim('withdrawn', 'verified', 'ok');
reset role;

-- Kallet som prøves. Alt som varierer, er parametre.
create function pg_temp.assess(
  p_label text,
  p_digest text default null,
  p_revision uuid default null
) returns jsonb language plpgsql as $$
declare
  v_secret text;
  v_run uuid;
  v_revision uuid;
  v_digest text;
begin
  select secret into v_secret from cred where label = 'assessor';
  select id into v_run from run where label = 'assessment';
  v_revision := coalesce(
    p_revision, (select (payload ->> 'claim_revision_id')::uuid from revision where label = p_label)
  );
  -- Avtrykket leses før rollebyttet: knowledge ligger bak RLS med default deny,
  -- og anon har ingen lesetilgang dit. En kjører henter det fra svaret
  -- synteseveien ga, eller fra claim-review-flaten.
  v_digest := coalesce(p_digest, knowledge.claim_evidence_set_digest(v_revision));

  perform set_config('role', 'anon', true);
  return api.register_evidence_assessment(
    p_identity_key => 'agent-identity:evidence-assessment-01',
    p_secret => v_secret,
    p_agent_run_id => v_run,
    p_claim_revision_id => v_revision,
    p_seen_evidence_set_digest => v_digest,
    p_framework => 'grade',
    p_certainty_level => 'very_low',
    p_rationale => 'Ett evidensfunn fra én randomisert studie ligger til grunn i fiksturen for 700.',
    p_risk_of_bias => 'serious',
    p_inconsistency => 'not_assessable',
    p_indirectness => 'not_serious',
    p_imprecision => 'not_assessable',
    p_publication_bias => 'not_assessable',
    p_evidence_gap => 'Størrelsen er ikke tallfestet i det registrerte grunnlaget.'
  );
end;
$$;

-- ===========================================================================
-- Del 3 — Den lykkede stien
-- ===========================================================================
create temporary table assessed (label text primary key, payload jsonb not null) on commit drop;
grant select, insert on assessed to anon;
insert into assessed select 'first', pg_temp.assess('verified');
reset role;

select is(
  (select a.certainty_level::text from knowledge.evidence_assessments a
   where a.id = (select (payload ->> 'evidence_assessment_id')::uuid from assessed where label = 'first')),
  'very_low',
  'graderingen er registrert slik forslaget oppga den'
);

select is(
  (select a.created_by_actor_id from knowledge.evidence_assessments a
   where a.id = (select (payload ->> 'evidence_assessment_id')::uuid from assessed where label = 'first')),
  (select id from fixture where name = 'assessor'),
  'vurderingen er attribuert til evidensvurderingsagenten, ikke til synteseagenten'
);

select is(
  (select a.agent_run_role::text from knowledge.evidence_assessments a
   where a.id = (select (payload ->> 'evidence_assessment_id')::uuid from assessed where label = 'first')),
  'evidence_assessment',
  'vurderingen bærer rollen kjøringen hadde'
);

select is(
  (select a.agent_run_id from knowledge.evidence_assessments a
   where a.id = (select (payload ->> 'evidence_assessment_id')::uuid from assessed where label = 'first')),
  (select id from run where label = 'assessment'),
  'vurderingen peker på den åpne kjøringen'
);

select is(
  (select a.assessed_knowledge_type::text from knowledge.evidence_assessments a
   where a.id = (select (payload ->> 'evidence_assessment_id')::uuid from assessed where label = 'first')),
  'evidence_synthesis',
  'kunnskapstypen leses av revisjonen og speiles på vurderingen'
);

select is(
  (select (payload ->> 'claim_revision_id')::uuid from assessed where label = 'first'),
  (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'verified'),
  'svaret navngir revisjonen vurderingen gjelder'
);

-- Vurderingen forsegler evidenssettet: en lenke til kan ikke legges til etterpå.
select throws_ok(
  $$
    insert into knowledge.claim_evidence_links (
      claim_revision_id, evidence_item_id, relationship_type, directness,
      relevance_note, created_by_actor_id
    )
    select
      (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'verified'),
      (select id from item where label = 'ok'),
      'supports', 'direct', 'Forsøk på å utvide et forseglet evidenssett.',
      (select id from fixture where name = 'synthesiser')
  $$,
  '23001', null,
  'evidenssettet er forseglet av vurderingen'
);

-- ===========================================================================
-- Del 4 — Kjeden fram til menneskets beslutning er nå komplett
-- ===========================================================================
select lives_ok(
  format(
    $$select knowledge.assert_claim_revision_ready_for_approval(%L::uuid)$$,
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'verified')
  ),
  'publiseringsgatens G1 til G10 holder: revisjonen er klar for menneskelig vurdering'
);

select throws_ok(
  format(
    $$select knowledge.assert_claim_revision_publishable(%L::uuid)$$,
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'verified')
  ),
  '23001', null,
  'gaten stopper likevel publisering: ingen har godkjent noe (G11)'
);

-- ===========================================================================
-- Del 5 — Rekkefølgen: vurderingen kommer etter kildestøtteverifikasjonen
-- ===========================================================================
select throws_ok(
  $$select pg_temp.assess('unverified')$$,
  '23001', null,
  'en revisjon uten claim-verifikasjon kan ikke graderes (G8)'
);
select throws_like(
  $$select pg_temp.assess('unverified')$$,
  '%ingen registrert claim-verifikasjon%',
  'avvisningen sier at kontrollen mangler, ikke bare at noe gikk galt'
);

select throws_ok(
  $$select pg_temp.assess('uncertain')$$,
  '23001', null,
  'en revisjon med uavklart claim-verifikasjon kan ikke graderes (G9)'
);
select throws_like(
  $$select pg_temp.assess('uncertain')$$,
  '%konkluderer ikke med verified%',
  'avvisningen sier at kontrollen ikke bekreftet påstanden'
);

-- ===========================================================================
-- Del 6 — Vurderingen gjelder det evidenssettet kalleren så
-- ===========================================================================
select throws_ok(
  $$select pg_temp.assess('withdrawn', 'sha256-v1:' || repeat('f', 64))$$,
  '23001', null,
  'et utdatert avtrykk avvises framfor å forsegle et sett vurderingen aldri så'
);
select throws_like(
  $$select pg_temp.assess('withdrawn', 'sha256-v1:' || repeat('f', 64))$$,
  '%Evidensgrunnlaget er endret%',
  'avvisningen sier hva som er galt med avtrykket'
);

-- ===========================================================================
-- Del 7 — Rollen er rettighetsgrensen
-- ===========================================================================
select throws_ok(
  format(
    $$select api.register_evidence_assessment(
        'agent-identity:claim-synthesis-01', %L,
        (select id from run where label = 'assessment'),
        %L::uuid,
        knowledge.claim_evidence_set_digest(%L::uuid),
        'grade', 'very_low', 'Forsøk fra synteseagenten.',
        'serious', 'not_assessable', 'not_serious', 'not_assessable', 'not_assessable')$$,
    (select secret from cred where label = 'synthesiser'),
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'withdrawn'),
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'withdrawn')
  ),
  '42501', null,
  'synteseagenten kan ikke gradere grunnlaget under sin egen påstand'
);

select throws_ok(
  format(
    $$select api.register_evidence_assessment(
        'agent-identity:citation-support-verification-01', %L,
        (select id from run where label = 'assessment'),
        %L::uuid,
        knowledge.claim_evidence_set_digest(%L::uuid),
        'grade', 'very_low', 'Forsøk fra claim-verifikatoren.',
        'serious', 'not_assessable', 'not_serious', 'not_assessable', 'not_assessable')$$,
    (select secret from cred where label = 'claim'),
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'withdrawn'),
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'withdrawn')
  ),
  '42501', null,
  'claim-verifikatoren kan ikke gradere grunnlaget den selv kontrollerte'
);

select throws_ok(
  format(
    $$select api.register_evidence_assessment(
        'agent-identity:evidence-assessment-01', %L,
        (select id from run where label = 'synthesis'),
        %L::uuid,
        knowledge.claim_evidence_set_digest(%L::uuid),
        'grade', 'very_low', 'Forsøk på en annen identitets kjøring.',
        'serious', 'not_assessable', 'not_serious', 'not_assessable', 'not_assessable')$$,
    (select secret from cred where label = 'assessor'),
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'withdrawn'),
    (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'withdrawn')
  ),
  '42501', null,
  'vurderingsagenten kan ikke skrive på en kjøring som tilhører en annen identitet'
);

-- ===========================================================================
-- Del 8 — Én vurdering per revisjon, og revisjonen må finnes
-- ===========================================================================
select throws_ok(
  $$select pg_temp.assess('verified')$$,
  '23001', null,
  'en revisjon kan ikke få en andre vurdering: en endret gradering er en ny revisjon'
);

select throws_ok(
  $$select pg_temp.assess(null, null, '70000000-0000-4000-8000-0000000000ff'::uuid)$$,
  'P0002', null,
  'en vurdering av en revisjon som ikke finnes, avvises med sin egen feil'
);

-- ===========================================================================
-- Del 9 — En avvist vurdering etterlater ingenting
-- ===========================================================================
create temporary table before_counts as
select (select count(*) from knowledge.evidence_assessments) as assessments;

do $$
begin
  begin
    perform pg_temp.assess('unverified');
  exception when others then
    null;
  end;
end;
$$;
reset role;

select is(
  (select count(*) from knowledge.evidence_assessments),
  (select assessments from before_counts),
  'en avvist vurdering etterlater ingen rad'
);

-- ===========================================================================
-- Del 10 — Vurderingen godkjenner og publiserer ingenting
-- ===========================================================================
select is(
  (select count(*) from workflow.review_decisions d
   where d.claim_revision_id = (select (payload ->> 'claim_revision_id')::uuid from revision where label = 'verified')),
  0::bigint,
  'skriveveien registrerer ingen reviewbeslutning: den faglige godkjenningen er et menneskes'
);

select is(
  (select c.current_published_revision_id
   from knowledge.claims c
   where c.id = (select (payload ->> 'claim_id')::uuid from revision where label = 'verified')),
  null,
  'skriveveien publiserer ingenting'
);

-- ===========================================================================
-- Del 11 — Kontrollnivået på evidensen leses på NYTT ved vurderingen
--
-- Revisjonen 700-D er kildestøtteverifisert og har et gyldig avtrykk. Trekkes
-- ekstraksjonen tilbake etterpå, skal graderingen avvises: en vurdering er en
-- påstand om hvor sikkert grunnlaget er, og et tilbaketrukket funn er ikke et
-- grunnlag. Uten denne lesningen ville vilkåret bare vært lest da påstanden ble
-- laget.
-- ===========================================================================
insert into workflow.review_decisions (
  evidence_item_id, evidence_item_creator_actor_id, review_type,
  decision, rationale, reviewer_actor_id, reviewer_actor_type, decided_at
)
select
  i.id, e.created_by_actor_id, 'extraction_withdrawal',
  'extraction_withdrawn',
  'Trukket tilbake i fiksturen, for å prøve at kontrollnivået leses på nytt ved vurderingen.',
  (select id from fixture where name = 'reviewer'), 'human', now()
from item i join knowledge.evidence_items e on e.id = i.id
where i.label = 'ok';

select throws_ok(
  $$select pg_temp.assess('withdrawn')$$,
  '23001', null,
  'et funn med tilbaketrukket ekstraksjon kan ikke graderes, heller ikke etter en bekreftet kontroll'
);
select throws_like(
  $$select pg_temp.assess('withdrawn')$$,
  '%tilbaketrukket ekstraksjon%',
  'avvisningen sier at ekstraksjonen er trukket tilbake'
);

select * from finish();
rollback;
