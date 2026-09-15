-- Migrasjon 010a, 010b og 010c — ekstern agent-handoff som arbeidsform.
--
-- Filen dekker at setningene i migrasjonene betyr noe:
--
--   * oppgaven bygges av databasen og bærer den kontrollerte kildeteksten,
--   * avtrykket er stabilt for et uendret grunnlag, og et svar avgitt på et
--     annet grunnlag kan ikke importeres,
--   * svaret er data: ukjente felter avvises, og verdiene hentes ut av svaret,
--   * modellidentiteten registreres, og to agentledd kan ikke dele modell,
--   * en ikke-eksponert versjon er kanonisk, slik at to ukjente er én modell,
--   * det samme svaret sendt inn igjen lager ingen doble kliniske artefakter,
--   * og kildeteksten er like privat som originalfilen.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23505 = unique_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(49);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('knowledge', 'source_version_texts',
                 'knowledge.source_version_texts finnes');
select has_table('workflow', 'agent_handoff_imports',
                 'workflow.agent_handoff_imports finnes');

-- Oppgaven inneholder hele forskningsartikkelen. Ingen klientrolle uten mandat
-- skal kunne be om den, og ingen skal kunne lese tabellen den ligger i.
select is_empty(
  $$
    select f.name
    from (values
      ('api.agent_work_queue()'),
      ('api.agent_task_payload(uuid)'),
      ('api.import_agent_answer(uuid,jsonb)'),
      ('api.enqueue_agent_task(text,jsonb)'),
      ('api.release_agent_role_model(text,text)')
    ) as f(name)
    where has_function_privilege('anon', f.name, 'EXECUTE')
       or has_function_privilege('public', f.name, 'EXECUTE')
       or has_function_privilege('service_role', f.name, 'EXECUTE')
  $$,
  'ingen av agenthandoff-veiene er åpne for anon, service_role eller PUBLIC'
);

select is_empty(
  $$
    select r.rolname
    from (values ('anon'), ('authenticated'), ('service_role')) as r(rolname)
    where has_table_privilege(r.rolname, 'knowledge.source_version_texts', 'SELECT')
  $$,
  'ingen klientrolle kan lese den lagrede kildeteksten direkte'
);

-- ===========================================================================
-- Del 2 — Grunnlaget
-- ===========================================================================
create temporary table rep (text text) on commit drop;
insert into rep values (
  E'Syntetisk artikkel om sertralin og vektendring.\n\n' ||
  E'Patients (N = 100) with major depressive disorder were randomly assigned to sertraline for 8 weeks.\n\n' ||
  E'Mean weight change from baseline was 0.8 kg in the sertraline arm at 8 weeks.\n\n' ||
  E'No confidence interval was reported for the mean weight change.\n\n' ||
  E'The study was limited by its short duration and its open-label design.\n');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('78000000-0000-4000-8000-000000000001', 'journal_article',
        'Syntetisk handoff-kilde for 780', 'Testforfatter', pg_temp.extraction_actor_id());

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, external_version, content_hash,
  representation, retrieved_by_actor_id, document_sha256, document_byte_size,
  document_media_type, text_extraction_tool, text_extraction_tool_version,
  text_extraction_arguments, text_extraction_transform
)
select '78000000-0000-4000-8000-000000000002', '78000000-0000-4000-8000-000000000001',
       now(), 'file:///handoff-780.pdf', 'handoff-v1',
       knowledge.source_version_content_hash(r.text),
       'full_text', pg_temp.extraction_actor_id(),
       pg_temp.synthetic_pdf_digest('78000000-0000-4000-8000-000000000002'),
       octet_length(pg_temp.synthetic_pdf('78000000-0000-4000-8000-000000000002')),
       'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from rep r;

insert into knowledge.source_version_texts (source_version_id, representation, stored_by_actor_id)
select '78000000-0000-4000-8000-000000000002', r.text, pg_temp.extraction_actor_id() from rep r;

-- Fingeravtrykket er databasens, ikke en påstand: en annen tekst under den samme
-- kildeversjonen avvises.
select throws_ok(
  $$
    insert into knowledge.source_version_texts
      (source_version_id, representation, stored_by_actor_id)
    values ('f2000000-0000-4000-8000-000000000002', 'en helt annen tekst',
            (select id from provenance.actors where actor_key = 'agent:evidence-extraction'))
  $$,
  '23001',
  null,
  'en tekst som ikke er kildeversjonens registrerte representasjon, avvises'
);

insert into auth.users (id, email) values
  ('78000000-0000-4000-8000-00000000000e', 'redaktor-780@test.invalid'),
  ('78000000-0000-4000-8000-00000000000f', 'utenmandat-780@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac780000-0000-4000-8000-00000000000e', 'human', 'human:redaktor-780', 'Redaktør 780',
   'Aktør med editor-tildeling, for 780.', '78000000-0000-4000-8000-00000000000e'),
  ('ac780000-0000-4000-8000-00000000000f', 'human', 'human:utenmandat-780', 'Uten mandat 780',
   'Aktør uten editor-tildeling, for 780.', '78000000-0000-4000-8000-00000000000f');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('78000000-0000-4000-8000-00000000000e', 'editor', null, now() - interval '1 year',
   (select id from provenance.actors where actor_key = 'human:peder-holman'),
   'Gyldig editor-tildeling for 780.');

create temporary table ids (name text primary key, id uuid) on commit drop;
insert into ids select 'drug', id from catalog.drugs where canonical_name = 'sertralin';
insert into ids select 'other_drug', id from catalog.drugs where canonical_name = 'mirtazapin';
insert into ids select 'outcome', id from catalog.clinical_concepts
  where canonical_label = 'vektendring' and concept_type = 'outcome';
insert into ids select 'other_outcome', id from catalog.clinical_concepts
  where concept_type = 'outcome' and canonical_label <> 'vektendring' limit 1;
insert into ids select 'population', id from catalog.populations
  where canonical_label = 'voksne med depressiv lidelse';

create temporary table res (label text primary key, payload jsonb) on commit drop;
grant select, insert on res to authenticated;
grant select on ids to authenticated;

-- ===========================================================================
-- Del 3 — Køen og oppgaven
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000f"}', true);
set local role authenticated;
select throws_ok(
  $$ select api.agent_work_queue() $$,
  '42501',
  null,
  'en innlogget bruker uten editor-mandat får ikke se agentkøen'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;

insert into res
select 'enqueued', api.enqueue_agent_task('evidence_extraction', jsonb_build_object(
  'source_version_id', '78000000-0000-4000-8000-000000000002',
  'drug_ids', jsonb_build_array((select id from ids where name = 'drug')),
  'outcome_concept_ids', jsonb_build_array((select id from ids where name = 'outcome')),
  'population_ids', jsonb_build_array((select id from ids where name = 'population'))
));
insert into res
select 'enqueued_again', api.enqueue_agent_task('evidence_extraction', jsonb_build_object(
  'source_version_id', '78000000-0000-4000-8000-000000000002',
  'drug_ids', jsonb_build_array((select id from ids where name = 'drug')),
  'outcome_concept_ids', jsonb_build_array((select id from ids where name = 'outcome')),
  'population_ids', jsonb_build_array((select id from ids where name = 'population'))
));

-- Oppgaven kan ikke hentes ut før noen har valgt hvilken KI-tjeneste leddet
-- skal utføres av. Tildelingen inngår i bindingen avtrykket er regnet av, og en
-- oppgave bygget uten den ville bedt om et svar ingen kunne si var uavhengig
-- (ANTIDEP_CONSTITUTION.md regel 3).
select throws_ok(
  format($$ select api.agent_task_payload(%L::uuid) $$,
         (select payload ->> 'pipeline_job_id' from res where label = 'enqueued')),
  '23001',
  null,
  'en oppgave kan ikke hentes ut før en KI-tjeneste er valgt for agentleddet'
);

insert into res
select 'assigned', api.assign_agent_role_model(
  'evidence_extraction', 'openai', 'GPT-5 Thinking', null, 'not_exposed',
  'Prøve 780: tjenesten eieren bruker for ekstraksjonsutkast.');
insert into res
select 'assigned_again', api.assign_agent_role_model(
  'evidence_extraction', 'openai', 'GPT-5 Thinking', null, 'not_exposed',
  'Prøve 780: den samme tildelingen én gang til.');

insert into res
select 'task', api.agent_task_payload(
  (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'enqueued'));
insert into res
select 'task_again', api.agent_task_payload(
  (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'enqueued'));
reset role;

select is(
  (select (payload ->> 'already_assigned')::boolean from res where label = 'assigned_again'),
  true,
  'den samme tildelingen gjort to ganger er én tildeling'
);

-- Tildelingen er en attestert avgjørelse, tatt av den som har tilgangen — og
-- ikke en registrering svaret gjør på egne vegne.
select is(
  (select a.registered_by_actor_id from provenance.role_model_assignments a
   where a.agent_role = 'evidence_extraction' and a.capacity = 'semantic'
     and a.valid_to is null),
  'ac780000-0000-4000-8000-00000000000e'::uuid,
  'tildelingen er registrert av redaktøren som tok avgjørelsen'
);

select is(
  (select payload ->> 'pipeline_job_id' from res where label = 'enqueued'),
  (select payload ->> 'pipeline_job_id' from res where label = 'enqueued_again'),
  'den samme oppgaven lagt inn to ganger er én rad'
);

select is(
  (select payload ->> 'request_digest' from res where label = 'task'),
  (select payload ->> 'request_digest' from res where label = 'task_again'),
  'et uendret grunnlag gir det samme avtrykket'
);

select ok(
  (select payload -> 'input' ->> 'representation_text' from res where label = 'task')
    like '%Mean weight change from baseline was 0.8 kg%',
  'oppgaven bærer den kontrollerte kildeteksten'
);

select is(
  (select payload -> 'registered_model' ->> 'model' from res where label = 'task'),
  'GPT-5 Thinking',
  'oppgaven sier hvilken KI-tjeneste leddet er tildelt'
);

-- Avtrykket dekker tildelingen. Uten det kunne et svar avgitt under en tidligere
-- tildeling kommet tilbake etter et modellbytte og registrert den gamle
-- modellen på nytt.
select is(
  (select payload -> 'binding' -> 'semantic_model' ->> 'model'
   from res where label = 'task'),
  'GPT-5 Thinking',
  'bindingen avtrykket er regnet av, dekker modelltildelingen'
);

-- ===========================================================================
-- Del 4 — Importen
-- ===========================================================================
create temporary table answers (label text primary key, payload jsonb) on commit drop;
grant select on answers to authenticated;

insert into answers
select 'chatgpt', jsonb_build_object(
  'answer_version', 'antidep/agent-answer@1',
  'task_version', 'antidep/agent-task@1',
  'role', 'evidence_extraction',
  'job_key', t.payload ->> 'job_key',
  'request_digest', t.payload ->> 'request_digest',
  'output_schema_version', t.payload ->> 'output_schema_version',
  'identity', jsonb_build_object(
    'provider', 'openai', 'model', 'GPT-5 Thinking',
    'model_version_disclosure', 'not_exposed'),
  'answered_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'result', jsonb_build_object(
    'extraction', jsonb_build_object(
      'design_code', 'randomized_controlled_trial',
      'population_id', (select id from ids where name = 'population'),
      'population_availability', 'reported_value',
      'population_detail', 'Voksne med depressiv lidelse',
      'sample_size', 100,
      'sample_size_availability', 'reported_value',
      'intervention_drug_id', (select id from ids where name = 'drug'),
      'intervention_detail', 'sertralin',
      'comparator_kind', 'none',
      'comparator_drug_id', null,
      'comparator_detail', null,
      'outcome_concept_id', (select id from ids where name = 'outcome'),
      'outcome_detail', 'Vektendring fra baseline',
      'timepoint_min', '8 weeks',
      'timepoint_max', '8 weeks',
      'timepoint_availability', 'reported_value',
      'reported_direction', 'increase',
      'effect_measure', 'mean_change',
      'estimate', '0.8',
      'estimate_unit', 'kg',
      'estimate_availability', 'reported_value',
      'ci_lower', null, 'ci_upper', null, 'ci_level_percent', null,
      'confidence_interval_availability', 'not_reported',
      'limitations_text', 'Kort varighet og åpen design.',
      'source_locator', 'Avsnitt 3',
      'source_quote', 'Mean weight change from baseline was 0.8 kg in the sertraline arm at 8 weeks.'
    ),
    'field_groundings', (
      select jsonb_agg(jsonb_build_object(
        'check_field', f,
        'source_excerpt', 'Mean weight change from baseline was 0.8 kg in the sertraline arm at 8 weeks.',
        'source_locator', 'Avsnitt 3',
        'justification', 'Utdraget oppgir verdien for ' || f || '.'))
      from unnest(array['intervention_arm','outcome','reported_direction','availability_semantics',
                        'effect_measure','population','sample_size','timepoint','estimate',
                        'limitations']) as f
    )
  ))
from res t where t.label = 'task';

select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;

insert into res
select 'imported', api.import_agent_answer(
  (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'enqueued'),
  (select payload from answers where label = 'chatgpt'));

insert into res
select 'imported_again', api.import_agent_answer(
  (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'enqueued'),
  (select payload from answers where label = 'chatgpt'));
reset role;

select is(
  (select (payload ->> 'imported')::boolean from res where label = 'imported'),
  true,
  'et gyldig svar registreres'
);

select is(
  (select (payload ->> 'already_imported')::boolean from res where label = 'imported_again'),
  true,
  'det samme svaret sendt inn igjen svarer med det som allerede ble registrert'
);

-- Retries skal ikke gi doble kliniske artefakter.
select is(
  (select count(*) from knowledge.evidence_items
   where source_id = '78000000-0000-4000-8000-000000000001'),
  1::bigint,
  'to importer av det samme svaret gir ett evidensfunn'
);

select is(
  (select j.state::text from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'enqueued')),
  'succeeded',
  'jobben står som fullført etter importen'
);

-- Kjøringen er bundet til nettopp det uttaket den ble åpnet for — den samme
-- regelen et automatisert ledd hviler på.
select is(
  (select (b.pipeline_job_id = j.id and b.lease_token = j.lease_token)
   from workflow.pipeline_job_runs b
   join workflow.pipeline_jobs j on j.id = b.pipeline_job_id
   where b.agent_run_id = (select (payload ->> 'agent_run_id')::uuid
                           from res where label = 'imported')),
  true,
  'kjøringen er bundet til nettopp det uttaket importen tok'
);

select is(
  (select format('%s/%s/%s', r.semantic_provider, r.semantic_model, r.semantic_model_version)
   from provenance.agent_runs r
   where r.id = (select (payload ->> 'agent_run_id')::uuid from res where label = 'imported')),
  'openai/GPT-5 Thinking/ikke-eksponert',
  'kjøringen bærer den eksterne modellen som faktisk gjorde arbeidet'
);

select is(
  (select a.model from provenance.role_model_assignments a
   where a.agent_role = 'evidence_extraction' and a.capacity = 'semantic'
     and a.valid_to is null),
  'GPT-5 Thinking',
  'kjøringen er registrert under den modellen leddet var tildelt'
);

-- Importen registrerer ingen ny tildeling. Ett svar, én tildeling: den som
-- fantes før svaret kom.
select is(
  (select count(*) from provenance.role_model_assignments a
   where a.agent_role = 'evidence_extraction' and a.capacity = 'semantic'),
  1::bigint,
  'importen lager ingen ny modelltildeling'
);

-- ===========================================================================
-- Del 5 — Det som skal avvises
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;

select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'enqueued'),
    (select (payload || jsonb_build_object('answered_at', '2026-09-15T11:00:00Z'))::text
     from answers where label = 'chatgpt')
  ),
  '23505',
  null,
  'et annet svar på en jobb som allerede er besvart, avvises'
);

-- En ny jobb, for de resterende avvisningene.
insert into res
select 'job2', api.enqueue_agent_task('evidence_extraction', jsonb_build_object(
  'source_version_id', '78000000-0000-4000-8000-000000000002',
  'drug_ids', jsonb_build_array((select id from ids where name = 'drug'),
                                (select id from ids where name = 'other_drug')),
  'outcome_concept_ids', jsonb_build_array((select id from ids where name = 'outcome')),
  'population_ids', jsonb_build_array((select id from ids where name = 'population'))
));
insert into res
select 'task2', api.agent_task_payload(
  (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'job2'));
reset role;

insert into answers
select 'for_job2', (select payload from answers where label = 'chatgpt')
  || jsonb_build_object(
       'job_key', t.payload ->> 'job_key',
       'request_digest', t.payload ->> 'request_digest')
from res t where t.label = 'task2';

select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;

select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'job2'),
    (select (payload || jsonb_build_object('request_digest', 'sha256:' || repeat('a', 64)))::text
     from answers where label = 'for_job2')
  ),
  '22023',
  null,
  'et svar avgitt på et annet grunnlag kan ikke importeres'
);

select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'job2'),
    (select (payload || jsonb_build_object('notat', 'noe ekstra'))::text
     from answers where label = 'for_job2')
  ),
  '22023',
  null,
  'et ukjent felt i svaret avvises framfor å ignoreres'
);

select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'job2'),
    (select (payload || jsonb_build_object('identity', jsonb_build_object(
       'provider', 'openai', 'model', 'GPT-5 Thinking',
       'model_version_disclosure', 'exact')))::text
     from answers where label = 'for_job2')
  ),
  '22023',
  null,
  'en erklæring om en eksakt versjon uten versjon avvises framfor å bli gjettet'
);

select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'job2'),
    (select (payload || jsonb_build_object('identity', jsonb_build_object(
       'provider', 'openai', 'model', 'GPT-5 Thinking',
       'model_version', 'en annen build', 'model_version_disclosure', 'exact')))::text
     from answers where label = 'for_job2')
  ),
  '22023',
  null,
  'en annen modellidentitet enn rollens registrerte avvises'
);

-- En versjon oppgitt sammen med «ikke eksponert» er en selvmotsigelse. Forkastet
-- stille ville proveniensen sagt «ikke eksponert» mens svaret faktisk oppga en
-- versjon, og ingen ville fått vite at den ble borte.
select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'job2'),
    (select (payload || jsonb_build_object('identity', jsonb_build_object(
       'provider', 'openai', 'model', 'GPT-5 Thinking',
       'model_version', 'gpt-5-2026-01', 'model_version_disclosure', 'not_exposed')))::text
     from answers where label = 'for_job2')
  ),
  '22023',
  null,
  'en oppgitt versjon under «ikke eksponert» avvises framfor å bli forkastet stille'
);

select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'job2'),
    (select jsonb_set(payload, '{result,extraction,outcome_concept_id}',
                      to_jsonb((select id::text from ids where name = 'other_outcome')))::text
     from answers where label = 'for_job2')
  ),
  '22023',
  null,
  'et endepunkt utenfor oppgavens avgrensning avvises'
);

-- Et svar avgitt i framtiden er ikke en unøyaktighet, men en usann proveniens.
select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'job2'),
    (select (payload || jsonb_build_object('answered_at', '2099-01-01T00:00:00Z'))::text
     from answers where label = 'for_job2')
  ),
  '22023',
  null,
  'et svartidspunkt utenfor oppgaven avvises'
);
reset role;

-- ===========================================================================
-- Del 6 — Separasjonen, avgjort før arbeidet gjøres
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;

-- Den samme modellen kan ikke både lage innholdet og gjøre et annet semantisk
-- ledd. Avvisningen kommer der avgjørelsen tas — før noen har brukt en økt i en
-- KI-tjeneste på et svar som uansett ikke kunne registreres (regel 3).
select throws_ok(
  $$ select api.assign_agent_role_model('claim_synthesis', 'openai', 'GPT-5 Thinking') $$,
  '23001',
  null,
  'den samme eksterne modellen kan ikke tildeles to agentledd'
);

insert into res
select 'assigned_synthesis', api.assign_agent_role_model(
  'claim_synthesis', 'anthropic', 'Claude Opus', null, 'not_exposed',
  'Prøve 780: en annen tjeneste for synteseleddet.');

-- Og identiteten kan ikke lånes: et ekstraksjonssvar som utgir seg for å være
-- den modellen synteseleddet er tildelt, avvises. Uten tildelingen på forhånd
-- var dette nettopp hullet — en oppgitt identitet kunne gått klar av regelen om
-- at to ledd ikke deler modell, fordi svaret selv etablerte premisset.
select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'job2'),
    (select (payload || jsonb_build_object('identity', jsonb_build_object(
       'provider', 'anthropic', 'model', 'Claude Opus',
       'model_version_disclosure', 'not_exposed')))::text
     from answers where label = 'for_job2')
  ),
  '22023',
  null,
  'et svar som utgir seg for å være et annet ledds modell, avvises'
);
reset role;

-- Evidensen syntesen skal bygge på, må ha nådd kontrollnivået EVIDENCE_PIPELINE
-- krever. Fiksturet registrerer ingen ekstraksjonskontroll, så prøven gjør det
-- selv — med de feltene funnet faktisk påstår noe om, og fra en egen kjøring i
-- kontrollrollen, siden en kildeomfattende fraværspåstand bare kan føres opp av
-- en agentkjøring med mer enn et sammendrag som grunnlag.
insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '78000000-0000-4000-8000-0000000000b1', ai.id, ai.actor_id, 'extraction_verification',
       'antidep', 'deterministic-extraction-verification', '1.0.0',
       'extraction-verification/deterministic/1', 'antidep-evidence/1',
       '{"mode":"780"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';

create function pg_temp.verify_extraction_780(p_item uuid) returns void
language sql as $$
  insert into workflow.evidence_verifications
    (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
     source_access, checked_fields, rationale, verified_at, agent_run_id)
  select e.id, e.created_by_actor_id,
         (select actor_id from provenance.agent_runs
          where id = '78000000-0000-4000-8000-0000000000b1'),
         'verified', 'original_source',
         workflow.required_check_fields(e.id),
         'Prøve 780: ekstraksjonen er kontrollert mot kilden.', now(),
         '78000000-0000-4000-8000-0000000000b1'
  from knowledge.evidence_items e
  where e.id = p_item;
$$;

-- ===========================================================================
-- Del 6a — Køen er ikke mildere enn importen
-- ===========================================================================
-- Funnet importen nettopp registrerte, er ikke kontrollert av noen ennå. En
-- syntese på det ville blitt avvist ved registreringen, og oppgaven skal derfor
-- ikke kunne legges inn: alternativet er at noen bruker en hel økt i en
-- KI-tjeneste på et svar som aldri kunne godtas (ANTIDEP_CONSTITUTION.md regel 4).
insert into ids select 'imported_item', e.id
from knowledge.evidence_items e
where e.source_id = '78000000-0000-4000-8000-000000000001';

select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$ select api.enqueue_agent_task('claim_synthesis', %L::jsonb) $$,
    jsonb_build_object(
      'topic_concept_id', (select id from ids where name = 'outcome'),
      'subject_drug_id', (select id from ids where name = 'drug'),
      'evidence_item_ids', jsonb_build_array(
        (select id from ids where name = 'imported_item'))
    )::text
  ),
  '22023',
  null,
  'en synteseoppgave på et ukontrollert evidensfunn kan ikke legges inn'
);
reset role;

select pg_temp.verify_extraction_780('f2000000-0000-4000-8000-000000000011');
select pg_temp.verify_extraction_780('f2000000-0000-4000-8000-000000000012');

-- ===========================================================================
-- Del 6b — Avgrensningen gjelder også syntesen
-- ===========================================================================
insert into res
select 'synthesis_job2', jsonb_build_object('pipeline_job_id', j.id)
from (
  select (api.enqueue_agent_task('claim_synthesis', jsonb_build_object(
    'topic_concept_id', (select id from ids where name = 'outcome'),
    'subject_drug_id', (select id from ids where name = 'drug'),
    -- Med vilje uten populasjoner: avgrensningen er redaktørens, og et svar som
    -- oppgir en populasjon oppgaven ikke åpnet for, skal avvises.
    'evidence_item_ids', jsonb_build_array('f2000000-0000-4000-8000-000000000011',
                                           'f2000000-0000-4000-8000-000000000012')
  )) ->> 'pipeline_job_id')::uuid as id
) j;

select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;

insert into res
select 'synthesis_task2', api.agent_task_payload(
  (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'synthesis_job2'));

-- Et utkast som utelot det ene funnet — typisk det som motsier påstanden —
-- ville gitt en syntese som hvilte på et annet grunnlag enn det redaktøren
-- avgrenset (ANTIDEP_CONSTITUTION.md regel 4).
select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'synthesis_job2'),
    (select jsonb_build_object(
       'answer_version', 'antidep/agent-answer@1',
       'task_version', 'antidep/agent-task@1',
       'role', 'claim_synthesis',
       'job_key', t.payload ->> 'job_key',
       'request_digest', t.payload ->> 'request_digest',
       'output_schema_version', t.payload ->> 'output_schema_version',
       'identity', jsonb_build_object('provider', 'anthropic', 'model', 'Claude Opus',
                                      'model_version_disclosure', 'not_exposed'),
       'result', jsonb_build_object(
         'claim', jsonb_build_object('statement', 'x'),
         'evidence_links', jsonb_build_array(jsonb_build_object(
           'evidence_item_id', 'f2000000-0000-4000-8000-000000000011',
           'relationship_type', 'supports', 'directness', 'direct',
           'relevance_note', 'Syntetisk.'))))::text
     from res t where t.label = 'synthesis_task2')
  ),
  '22023',
  null,
  'et synteseutkast som ikke dekker hele evidenssettet, avvises'
);

select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'synthesis_job2'),
    (select jsonb_build_object(
       'answer_version', 'antidep/agent-answer@1',
       'task_version', 'antidep/agent-task@1',
       'role', 'claim_synthesis',
       'job_key', t.payload ->> 'job_key',
       'request_digest', t.payload ->> 'request_digest',
       'output_schema_version', t.payload ->> 'output_schema_version',
       'identity', jsonb_build_object('provider', 'anthropic', 'model', 'Claude Opus',
                                      'model_version_disclosure', 'not_exposed'),
       'result', jsonb_build_object(
         'claim', jsonb_build_object(
           'statement', 'x',
           'population_id', (select id from ids where name = 'population')),
         'evidence_links', jsonb_build_array(
           jsonb_build_object('evidence_item_id', 'f2000000-0000-4000-8000-000000000011',
                              'relationship_type', 'supports', 'directness', 'direct',
                              'relevance_note', 'Syntetisk.'),
           jsonb_build_object('evidence_item_id', 'f2000000-0000-4000-8000-000000000012',
                              'relationship_type', 'contradicts', 'directness', 'direct',
                              'relevance_note', 'Syntetisk.'))))::text
     from res t where t.label = 'synthesis_task2')
  ),
  '22023',
  null,
  'en populasjon utenfor oppgavens avgrensning avvises'
);
reset role;

-- ===========================================================================
-- Del 6c — Et modellbytte ugyldiggjør de utestående oppgavene
-- ===========================================================================
-- Tildelingen inngår i bindingen. Uten den ville et svar avgitt under den gamle
-- tildelingen kunnet komme tilbake etter et bytte og registrere den gamle
-- modellen på nytt — og separasjonen ville hvilt på hvilken oppgavefil noen
-- fortsatt hadde liggende (ANTIDEP_CONSTITUTION.md regel 3).
select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;

-- Et bytte uten begrunnelse er en endring uten ansvar, og avvises.
select throws_ok(
  $$ select api.assign_agent_role_model(
       'claim_synthesis', 'mistral', 'Mistral Large') $$,
  '23001',
  null,
  'en gjeldende modelltildeling kan ikke byttes uten en begrunnelse'
);

-- Med begrunnelse skjer avslutningen og den nye tildelingen i den samme
-- transaksjonen, slik at leddet aldri står uten modell underveis.
insert into res
select 'synthesis_reassigned', api.assign_agent_role_model(
  'claim_synthesis', 'mistral', 'Mistral Large', null, 'not_exposed',
  'Prøve 780: den nye tjenesten for synteseleddet.',
  'Prøve 780: synteseleddet bytter tjeneste.');

insert into res
select 'synthesis_task2_after', api.agent_task_payload(
  (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'synthesis_job2'));
reset role;

select is(
  (select (payload ->> 'replaced')::boolean from res where label = 'synthesis_reassigned'),
  true,
  'byttet avslutter den gamle tildelingen og registrerer den nye i ett'
);

select isnt(
  (select payload ->> 'request_digest' from res where label = 'synthesis_task2_after'),
  (select payload ->> 'request_digest' from res where label = 'synthesis_task2'),
  'et modellbytte gir den utestående oppgaven et nytt avtrykk'
);

select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'synthesis_job2'),
    (select jsonb_build_object(
       'answer_version', 'antidep/agent-answer@1',
       'task_version', 'antidep/agent-task@1',
       'role', 'claim_synthesis',
       'job_key', t.payload ->> 'job_key',
       'request_digest', t.payload ->> 'request_digest',
       'output_schema_version', t.payload ->> 'output_schema_version',
       'identity', jsonb_build_object('provider', 'anthropic', 'model', 'Claude Opus',
                                      'model_version_disclosure', 'not_exposed'),
       'result', jsonb_build_object(
         'claim', jsonb_build_object('statement', 'x'),
         'evidence_links', jsonb_build_array(
           jsonb_build_object('evidence_item_id', 'f2000000-0000-4000-8000-000000000011',
                              'relationship_type', 'supports', 'directness', 'direct',
                              'relevance_note', 'Syntetisk.'),
           jsonb_build_object('evidence_item_id', 'f2000000-0000-4000-8000-000000000012',
                              'relationship_type', 'contradicts', 'directness', 'direct',
                              'relevance_note', 'Syntetisk.'))))::text
     from res t where t.label = 'synthesis_task2')
  ),
  '22023',
  null,
  'et svar avgitt under den forrige modelltildelingen kan ikke importeres etter byttet'
);
reset role;

-- ===========================================================================
-- Del 6d — En fullført jobb er historikk, ikke noe som venter
-- ===========================================================================
-- Køen, uttaket og importen leser den samme regelen. Uten den ene regelen ville
-- en jobb som alt hadde et utfall — for eksempel en kjøring fra et automatisert
-- ledd — stått i flaten med nedlasting og opplasting, mens importen uansett
-- måtte avvise svaret (ANTIDEP_CONSTITUTION.md regel 4).
select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
insert into res
select 'done_job', api.enqueue_agent_task('evidence_extraction', jsonb_build_object(
  'source_version_id', '78000000-0000-4000-8000-000000000002',
  'drug_ids', jsonb_build_array((select id from ids where name = 'other_drug')),
  'outcome_concept_ids', jsonb_build_array((select id from ids where name = 'outcome'))
));
insert into res select 'queue', api.agent_work_queue();
reset role;

-- Positiv kontroll: den nye jobben er utførbar slik den står.
select is(
  (select workflow.agent_task_problem(j)
   from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid
                 from res where label = 'done_job')),
  null,
  'en jobb som venter, er utførbar'
);

-- Og den samme jobben med et registrert utfall er det ikke. Tilstanden byttes i
-- en radverdi framfor i tabellen: en «succeeded»-rad krever et uttak, en kjøring
-- og et utfallsmanifest, og en rad som omgikk de kravene ville prøvd noe annet
-- enn regelen (workflow.pipeline_jobs sine egne constraints).
select matches(
  (select workflow.agent_task_problem(
            jsonb_populate_record(
              null::workflow.pipeline_jobs,
              to_jsonb(j) || jsonb_build_object('state', 'succeeded')))
   from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid
                 from res where label = 'done_job')),
  'fullført',
  'en fullført pipelinejobb er ikke en utførbar agentoppgave'
);

-- Og den oppgaven som faktisk tok imot et svar, står som blokkert i køen framfor
-- som noe som venter på et menneske.
select isnt(
  (select q.value ->> 'blocked_reason'
   from res, jsonb_array_elements(res.payload) as q(value)
   where res.label = 'queue'
     and q.value ->> 'pipeline_job_id'
         = (select payload ->> 'pipeline_job_id' from res r2 where r2.label = 'enqueued')),
  null,
  'køen viser en besvart oppgave som blokkert framfor som utførbar'
);

-- En oppbrukt oppgave skal ikke kunne hentes ut heller: alternativet er en hel
-- økt i en KI-tjeneste på et svar importen uansett måtte avvise.
update workflow.pipeline_jobs
set attempts = max_attempts
where id = (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'synthesis_job2');

select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$ select api.agent_task_payload(%L::uuid) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'synthesis_job2')
  ),
  '23001',
  null,
  'en oppgave med oppbrukte forsøk kan ikke hentes ut'
);
reset role;

-- Regelen gjentas der den gjelder, på selve kontrollradene. Registeret gjør
-- allerede to roller ute av stand til å dele modell; denne prøven omgår
-- registeret med vilje og skriver kjøringene direkte, fordi regelen skal holde
-- også den dagen registeret er feilkonfigurert — og det er nettopp da den betyr
-- noe (ANTIDEP_CONSTITUTION.md regel 3).
insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   semantic_provider, semantic_model, semantic_model_version,
   semantic_model_version_disclosure,
   prompt_template_version, pipeline_version, input_manifest, status,
   completed_at, output_manifest)
select '78000000-0000-4000-8000-0000000000c1', ai.id, ai.actor_id, 'claim_synthesis',
       'antidep', 'proposal-registered-synthesis', '1.0.0',
       'samme-leverandør', 'samme-modell', 'ikke-eksponert', 'not_exposed',
       'claim-synthesis/proposal/1', 'antidep-evidence/1', '{"mode":"780"}'::jsonb,
       'succeeded', now(), '{"mode":"780"}'::jsonb
from provenance.agent_identities ai where ai.identity_key = 'agent-identity:claim-synthesis-01';

insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   semantic_provider, semantic_model, semantic_model_version,
   semantic_model_version_disclosure,
   prompt_template_version, pipeline_version, input_manifest)
select '78000000-0000-4000-8000-0000000000c2', ai.id, ai.actor_id, 'evidence_assessment',
       'antidep', 'proposal-registered-assessment', '1.0.0',
       'samme-leverandør', 'samme-modell', 'ikke-eksponert', 'not_exposed',
       'evidence-assessment/proposal/1', 'antidep-evidence/1', '{"mode":"780"}'::jsonb
from provenance.agent_identities ai where ai.identity_key = 'agent-identity:evidence-assessment-01';

-- Revisjonene er append-only, så prøven lager sin egen: en påstand hvis
-- formulering er registrert av synteseleddets kjøring over.
insert into knowledge.claims (id, knowledge_type, topic_concept_id, subject_drug_id,
                              created_by_actor_id)
select '78000000-0000-4000-8000-0000000000c3', 'evidence_synthesis',
       (select id from ids where name = 'outcome'),
       (select id from ids where name = 'drug'),
       (select actor_id from provenance.agent_runs
        where id = '78000000-0000-4000-8000-0000000000c1');

insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
   comparator_kind, uncertainty_summary, created_by_actor_id, agent_run_id)
select '78000000-0000-4000-8000-0000000000c4', '78000000-0000-4000-8000-0000000000c3', 1,
       'evidence_synthesis', (select id from ids where name = 'drug'),
       'Syntetisk prøvepåstand for 780.', 'Kun syntetisk databaseprøve.',
       'none', 'Syntetisk usikkerhet.',
       (select actor_id from provenance.agent_runs
        where id = '78000000-0000-4000-8000-0000000000c1'),
       '78000000-0000-4000-8000-0000000000c1';

select throws_ok(
  $$
    insert into knowledge.evidence_assessments
      (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
       risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
       rationale, assessed_at, created_by_actor_id, agent_run_id)
    values ('78000000-0000-4000-8000-0000000000c4', 'evidence_synthesis', 'grade', 'low',
            'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
            'Prøve 780: samme eksterne modell på begge ledd.', now(),
            (select actor_id from provenance.agent_runs
             where id = '78000000-0000-4000-8000-0000000000c2'),
            '78000000-0000-4000-8000-0000000000c2')
  $$,
  '23001',
  null,
  'en vurdering som hviler på det samme eksterne modellsvaret som innholdet, avvises'
);

-- ===========================================================================
-- Del 6e — Forhåndskontrollen for en vurdering er importens egen
-- ===========================================================================
-- Registreringen av en evidensvurdering krever en gjeldende kildestøttekontroll
-- som gjelder nøyaktig det evidenssettet som ligger der. Køen leser det samme
-- vilkåret, med den samme funksjonen: en mildere forhåndskontroll ville latt noen
-- få vite om avvisningen først etter at arbeidet var gjort.
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select '78000000-0000-4000-8000-0000000000c4', 'f2000000-0000-4000-8000-000000000011',
       'supports', 'direct', 'Syntetisk relevans for 780.',
       (select actor_id from provenance.agent_runs
        where id = '78000000-0000-4000-8000-0000000000c1');

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select '78000000-0000-4000-8000-0000000000c4', r.created_by_actor_id,
       (select id from provenance.actors where actor_key = 'agent:citation-support-verification'),
       'verified', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Prøve 780: kontrollert mot grunnlaget slik det er nå.', now()
from knowledge.claim_revisions r
where r.id = '78000000-0000-4000-8000-0000000000c4';

select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;

insert into res
select 'assessment_job', api.enqueue_agent_task('evidence_assessment', jsonb_build_object(
  'claim_revision_id', '78000000-0000-4000-8000-0000000000c4'));
insert into res
select 'assigned_assessment', api.assign_agent_role_model(
  'evidence_assessment', 'google', 'Gemini 3 Pro', null, 'not_exposed',
  'Prøve 780: en tredje tjeneste for vurderingsleddet.');
insert into res
select 'assessment_task', api.agent_task_payload(
  (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'assessment_job'));
reset role;

select ok(
  (select payload ->> 'request_digest' from res where label = 'assessment_task') is not null,
  'en vurderingsoppgave med gjeldende kildestøttekontroll kan hentes ut'
);

-- Et funn som kommer til etterpå, gjør kontrollen foreldet. Da er oppgaven ikke
-- utførbar lenger, og køen skal si det framfor å la svaret bli avvist etterpå.
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select '78000000-0000-4000-8000-0000000000c4', 'f2000000-0000-4000-8000-000000000012',
       'contradicts', 'direct', 'Syntetisk motsigelse for 780.',
       (select actor_id from provenance.agent_runs
        where id = '78000000-0000-4000-8000-0000000000c1');

select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select throws_like(
  format($$ select api.agent_task_payload(%L::uuid) $$,
         (select payload ->> 'pipeline_job_id' from res where label = 'assessment_job')),
  '%Kildestøttekontrollen av påstanden holder ikke%',
  'en vurderingsoppgave med foreldet kildestøttekontroll kan ikke hentes ut'
);
reset role;

-- ===========================================================================
-- Del 7 — Registeret kan avsluttes, men aldri skrives om
-- ===========================================================================
select throws_ok(
  $$
    update provenance.role_model_assignments
    set model = 'noe annet'
    where agent_role = 'evidence_extraction' and capacity = 'semantic'
  $$,
  '23001',
  null,
  'en registrert semantisk modelltildeling kan ikke skrives om'
);

select set_config('request.jwt.claims',
                  '{"sub":"78000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
insert into res
select 'released', api.release_agent_role_model(
  'evidence_extraction', 'Prøve 780: modellen byttes ut.');
reset role;

select is(
  (select (payload ->> 'released')::boolean from res where label = 'released'),
  true,
  'en semantisk modelltildeling kan avsluttes'
);

-- To avslutninger i denne filen: synteseleddet byttet tjeneste i del 6c, og
-- ekstraksjonsleddet avsluttes her.
select is(
  (select count(*) from audit.events e
   where e.operation = 'role_model_assignment_closed'),
  2::bigint,
  'hver avslutning etterlater sin egen auditrad'
);

select * from finish();
rollback;
