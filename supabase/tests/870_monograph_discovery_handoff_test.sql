-- Migrasjon 013f — kildeoppdagelsen gjennom den faktiske agentarbeidsformen.
--
-- Filen dekker at de to nye rollene går gjennom nøyaktig den samme kontrakten
-- som de tre som fantes, og at det som skiller dem, holder:
--
--   * en ny søkeplan legger søkeoppgaven i køen av seg selv, som en ekstern
--     agentoppgave i den samme jobbtabellen,
--   * oppgaven bærer spørsmålene, sporene og stoppkravene — og ingen forventet
--     klinisk konklusjon,
--   * et svar registreres som agentrapportert utførelse, aldri som maskinelt
--     bekreftet,
--   * et registrert søkesvar legger kontrolloppgaven i køen,
--   * kontrollens erklæring om egne søk avvises uten et registrert eget søk,
--   * en bruk for et behov utenfor oppgaven avvises,
--   * en godtatt kontroll som holder porten, erklærer søkedekningen ferdig i den
--     samme transaksjonen, og
--   * et svar avgitt på et grunnlag som er blitt et annet, avvises.
--
-- SQLSTATE 22023 = invalid_parameter_value, 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(28);

-- ===========================================================================
-- Del 1 — Kontoene, bestillingen og modelltildelingene
-- ===========================================================================
insert into auth.users (id, email)
values ('87000000-0000-4000-8000-00000000000a', 'redaktor-870@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac870000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-870',
   'Redaktør 870',
   'Editor uten avgrensning, for prøven av kildeoppdagelsen gjennom handoff-kontrakten i 870.',
   '87000000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('87000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
   'ac870000-0000-4000-8000-00000000000a', 'Editor-tildeling for 870.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table jobs (label text primary key, id uuid not null) on commit drop;
create temporary table refs (label text primary key, value text not null) on commit drop;
grant select, insert on svar to authenticated;
grant select on jobs, refs to authenticated;

select set_config('request.jwt.claims',
                  '{"sub":"87000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 870.');
insert into svar (label, payload)
select 'modell_discovery', api.assign_agent_role_model(
  'source_discovery', 'prøve-870-a', 'Generatormodell 870', 'ikke-eksponert',
  'not_exposed', 'Prøve i 870.', 'Prøve i 870: generatorens modell.');
insert into svar (label, payload)
select 'modell_kontroll', api.assign_agent_role_model(
  'source_quality_assessment', 'prøve-870-b', 'Kontrollmodell 870', 'ikke-eksponert',
  'not_exposed', 'Prøve i 870.', 'Prøve i 870: kontrollens modell.');
reset role;

select is(
  (select (payload -> 'assigned')::boolean from svar where label = 'modell_discovery'),
  true,
  'kildeoppdagelsen kan tildeles en ekstern KI-tjeneste'
);

-- ===========================================================================
-- Del 2 — Søkeoppgaven ligger i køen av seg selv
-- ===========================================================================
select cmp_ok(
  (select count(*)::integer from workflow.pipeline_jobs
   where agent_role = 'source_discovery'),
  '>', 0,
  'bestillingen la søkeoppgavene i køen'
);
select is_empty(
  $$
    select j.id from workflow.pipeline_jobs j
    where j.agent_role = 'source_discovery'
      and not exists (
        select 1 from workflow.agent_handoff_jobs h where h.pipeline_job_id = j.id
      )
  $$,
  'hver søkeoppgave er registrert som en ekstern agentoppgave'
);
select is_empty(
  $$
    select j.job_key, count(*)
    from workflow.pipeline_jobs j
    where j.agent_role = 'source_discovery'
    group by j.job_key having count(*) > 1
  $$,
  'og to oppgaver om den samme planen er ikke to jobber'
);

-- Den EFF-planen vi følger.
insert into jobs (label, id)
select 'discovery', j.id
from workflow.pipeline_jobs j
join workflow.monograph_search_plans p
  on p.id = workflow.manifest_uuid(j.input_manifest, 'search_plan_id')
join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
where j.agent_role = 'source_discovery' and sp.code = 'EFF'
order by j.enqueued_at
limit 1;

insert into refs (label, value)
select 'plan', p.reference
from workflow.monograph_search_plans p
join workflow.pipeline_jobs j on workflow.manifest_uuid(j.input_manifest, 'search_plan_id') = p.id
where j.id = (select id from jobs where label = 'discovery');

select is(
  (select workflow.agent_task_problem(j, null) from workflow.pipeline_jobs j
   where j.id = (select id from jobs where label = 'discovery')),
  null,
  'oppgaven kan utføres: grunnlaget er klart og modellen er valgt'
);

-- ===========================================================================
-- Del 3 — Oppgaven bærer spørsmålene og kriteriene, ikke et forventet svar
-- ===========================================================================
insert into svar (label, payload)
select 'oppgave', workflow.agent_task(j) from workflow.pipeline_jobs j
where j.id = (select id from jobs where label = 'discovery');

select ok(
  (select bool_and(need ? 'question' and need ? 'need_reference'
                   and not (need ? 'expected_answer'))
   from svar, jsonb_array_elements(payload -> 'input' -> 'needs') as need
   where label = 'oppgave'),
  'behovene i oppgaven bærer spørsmålet og referansen, og ingen forventet konklusjon'
);
select ok(
  (select jsonb_array_length(payload -> 'input' -> 'closure_criteria' -> 'not_sufficient') = 4
   from svar where label = 'oppgave'),
  'oppgaven navngir de fire grunnene som uttrykkelig ikke holder for å avslutte'
);
select ok(
  (select jsonb_array_length(payload -> 'input' -> 'required_tracks') > 0
   from svar where label = 'oppgave'),
  'og de obligatoriske søkesporene med tilstanden sin'
);
select is(
  (select payload -> 'subject' ->> 'kind' from svar where label = 'oppgave'),
  'søkeplan',
  'oppgavens subjekt er søkeplanen'
);
select matches(
  (select payload -> 'registered_model' ->> 'model' from svar where label = 'oppgave'),
  'Generatormodell 870',
  'og oppgaven bærer den tildelte modellen, som inngår i avtrykket'
);

-- ===========================================================================
-- Del 4 — Svaret registreres som agentrapportert utførelse
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"87000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'import', api.import_agent_answer(
  (select id from jobs where label = 'discovery'),
  jsonb_build_object(
    'answer_version', 'antidep/agent-answer@1',
    'task_version', 'antidep/agent-task@1',
    'role', 'source_discovery',
    'job_key', (select payload ->> 'job_key' from svar where label = 'oppgave'),
    'request_digest', (select payload ->> 'request_digest' from svar where label = 'oppgave'),
    'output_schema_version', 'antidep/source-discovery-draft@1',
    'identity', jsonb_build_object(
      'provider', 'prøve-870-a', 'model', 'Generatormodell 870',
      'model_version_disclosure', 'not_exposed'),
    'result', jsonb_build_object(
      'searches', jsonb_build_array(jsonb_build_object(
        'platform', 'Europe PMC',
        'query_string', 'sertraline AND depressive disorder AND systematic review',
        'filters', 'ingen språk- eller årsavgrensning',
        'outcome', 'executed',
        'result_count', 31,
        'screened_count', 31,
        'truncated', false,
        'track_codes', jsonb_build_array('bibliographic_database', 'systematic_review_search'))),
      'candidates', jsonb_build_array(jsonb_build_object(
        'identifier_kind', 'doi',
        'identifier_value', '10.1000/870-oversikt',
        'title', 'Oversikt om effekt ved depressiv lidelse (prøve 870)',
        'discovery_path', 'Oversiktssøk i Europe PMC',
        'decision', 'selected_for_retrieval',
        'decision_reason', 'Dekker endepunktet og avgrensningen behovet gjelder.',
        'uses', jsonb_build_array(jsonb_build_object(
          'need_reference', (select payload -> 'input' -> 'needs' -> 0 ->> 'need_reference'
                             from svar where label = 'oppgave'),
          'proposed_use', 'Kan dokumentere endringen i symptomskår for den avgrensede populasjonen.')))),
      'term_proposals', jsonb_build_array())));
reset role;

select is(
  (select (payload -> 'imported')::boolean from svar where label = 'import'),
  true,
  'søkesvaret ble importert gjennom den samme skriveveien de øvrige leddene bruker'
);
select is(
  (select s.execution_evidence::text from workflow.monograph_searches s
   join workflow.monograph_search_plans p on p.id = s.plan_id
   where p.reference = (select value from refs where label = 'plan')),
  'agent_reported',
  'og søket står som agentrapportert utførelse, aldri som maskinelt bekreftet'
);
select is(
  (select s.response_digest from workflow.monograph_searches s
   join workflow.monograph_search_plans p on p.id = s.plan_id
   where p.reference = (select value from refs where label = 'plan')),
  null,
  'et agentrapportert søk bærer ikke et responsavtrykk'
);
select is(
  (select (payload -> 'outcome' -> 'candidates_recorded')::integer
   from svar where label = 'import'),
  1,
  'kandidatkilden agenten fant, er registrert'
);
select is(
  (select cn.proposed_use
   from workflow.monograph_candidate_source_needs cn
   join workflow.monograph_candidate_sources c on c.id = cn.candidate_source_id
   where c.identifier_value = '10.1000/870-oversikt'),
  'Kan dokumentere endringen i symptomskår for den avgrensede populasjonen.',
  'og hva den kan brukes til for nettopp dette behovet'
);
select is(
  (select r.semantic_model from provenance.agent_runs r
   where r.id = (select (payload ->> 'agent_run_id')::uuid from svar where label = 'import')),
  'Generatormodell 870',
  'kjøringen bærer den eksterne modellen som faktisk gjorde arbeidet'
);

-- ===========================================================================
-- Del 5 — Kontrolloppgaven ligger i køen, og den har sine egne krav
-- ===========================================================================
select isnt(
  (select payload -> 'outcome' ->> 'next_job_id' from svar where label = 'import'),
  null,
  'det registrerte søkesvaret la kontrolloppgaven i køen'
);

insert into jobs (label, id)
select 'kontroll', (payload -> 'outcome' ->> 'next_job_id')::uuid
from svar where label = 'import';

insert into svar (label, payload)
select 'kontrolloppgave', workflow.agent_task(j) from workflow.pipeline_jobs j
where j.id = (select id from jobs where label = 'kontroll');

select is(
  (select payload -> 'subject' ->> 'kind' from svar where label = 'kontrolloppgave'),
  'kontroll av søkedekning',
  'kontrolloppgavens subjekt er kontrollen av søkedekningen'
);
select ok(
  (select (payload -> 'input' -> 'control_task' -> 'own_search_required')::boolean
   from svar where label = 'kontrolloppgave'),
  'og oppgaven sier uttrykkelig at kontrollen må søke selv'
);
select ok(
  (select jsonb_array_length(payload -> 'binding' -> 'prior_runs') > 0
   from svar where label = 'kontrolloppgave'),
  'kontrollen hviler på generatorens kjøring, og den står i bindingen'
);

-- En erklæring om egne søk uten et registrert eget søk avvises.
select set_config('request.jwt.claims',
                  '{"sub":"87000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format($$
    select api.import_agent_answer(%L, jsonb_build_object(
      'answer_version', 'antidep/agent-answer@1',
      'task_version', 'antidep/agent-task@1',
      'role', 'source_quality_assessment',
      'job_key', %L,
      'request_digest', %L,
      'output_schema_version', 'antidep/source-coverage-control-draft@1',
      'identity', jsonb_build_object(
        'provider', 'prøve-870-b', 'model', 'Kontrollmodell 870',
        'model_version_disclosure', 'not_exposed'),
      'result', jsonb_build_object(
        'searches', jsonb_build_array(),
        'control', jsonb_build_object(
          'outcome', 'accepted',
          'note', 'Prøve i 870: leste generatorens referanser og fant ingen mangler.',
          'searched_independently', true,
          'materiality_assessed', true))))
  $$,
  (select id from jobs where label = 'kontroll'),
  (select payload ->> 'job_key' from svar where label = 'kontrolloppgave'),
  (select payload ->> 'request_digest' from svar where label = 'kontrolloppgave')),
  '22023',
  'Kontrollen erklærer at den søkte selv, men har ikke rapportert et eget søk som gikk.',
  'en erklæring om egne søk uten et registrert eget søk avvises'
);

-- En bruk for et behov utenfor oppgaven avvises.
select throws_ok(
  format($$
    select api.import_agent_answer(%L, jsonb_build_object(
      'answer_version', 'antidep/agent-answer@1',
      'task_version', 'antidep/agent-task@1',
      'role', 'source_quality_assessment',
      'job_key', %L,
      'request_digest', %L,
      'output_schema_version', 'antidep/source-coverage-control-draft@1',
      'identity', jsonb_build_object(
        'provider', 'prøve-870-b', 'model', 'Kontrollmodell 870',
        'model_version_disclosure', 'not_exposed'),
      'result', jsonb_build_object(
        'searches', jsonb_build_array(jsonb_build_object(
          'platform', 'PubMed', 'query_string', 'sertraline[tiab]',
          'outcome', 'zero_results', 'result_count', 0, 'screened_count', 0,
          'truncated', false,
          'track_codes', jsonb_build_array('independent_second_database'))),
        'candidates', jsonb_build_array(jsonb_build_object(
          'identifier_kind', 'doi', 'identifier_value', '10.1000/870-utenfor',
          'title', 'En kilde med en bruk utenfor oppgaven',
          'discovery_path', 'Eget motsøk',
          'uses', jsonb_build_array(jsonb_build_object(
            'need_reference', %L,
            'proposed_use', 'Noe helt annet.')))),
        'control', jsonb_build_object(
          'outcome', 'insufficient',
          'note', 'Prøve i 870.',
          'searched_independently', true,
          'materiality_assessed', true))))
  $$,
  (select id from jobs where label = 'kontroll'),
  (select payload ->> 'job_key' from svar where label = 'kontrolloppgave'),
  (select payload ->> 'request_digest' from svar where label = 'kontrolloppgave'),
  repeat('0', 32)),
  '22023',
  'Svaret oppgir en bruk for et kunnskapsbehov som ikke står i oppgaven.',
  'en bruk for et behov utenfor oppgaven avvises'
);
reset role;

-- ===========================================================================
-- Del 6 — Og et svar på et grunnlag som er blitt et annet, avvises
-- ===========================================================================
-- Et maskinelt utført søk kommer inn mellom oppgaven og svaret, og
-- avgrensningsgrunnlaget er dermed et annet enn det kontrollen fikk.
insert into workflow.monograph_searches
  (plan_id, plan_version, platform, query_string, executed_at, result_count,
   screened_count, outcome, execution_evidence, evidence_endpoint, response_digest,
   track_codes, recorded_by_actor_id)
select p.id, p.plan_version, 'CENTRAL', 'sertraline', now(), 5, 5,
       'executed', 'machine_executed', 'https://example.test',
       'sha256:' || repeat('7', 64),
       array['independent_second_database'], 'ac870000-0000-4000-8000-00000000000a'
from workflow.monograph_search_plans p
where p.reference = (select value from refs where label = 'plan');

select isnt(
  (select workflow.agent_task(j) ->> 'request_digest' from workflow.pipeline_jobs j
   where j.id = (select id from jobs where label = 'kontroll')),
  (select payload ->> 'request_digest' from svar where label = 'kontrolloppgave'),
  'et nytt søk gir oppgaven et nytt avtrykk'
);

select set_config('request.jwt.claims',
                  '{"sub":"87000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_like(
  format($$
    select api.import_agent_answer(%L, jsonb_build_object(
      'answer_version', 'antidep/agent-answer@1',
      'task_version', 'antidep/agent-task@1',
      'role', 'source_quality_assessment',
      'job_key', %L,
      'request_digest', %L,
      'output_schema_version', 'antidep/source-coverage-control-draft@1',
      'identity', jsonb_build_object(
        'provider', 'prøve-870-b', 'model', 'Kontrollmodell 870',
        'model_version_disclosure', 'not_exposed'),
      'result', jsonb_build_object(
        'searches', jsonb_build_array(jsonb_build_object(
          'platform', 'PubMed', 'query_string', 'sertraline[tiab]',
          'outcome', 'zero_results', 'result_count', 0, 'screened_count', 0,
          'truncated', false,
          'track_codes', jsonb_build_array('independent_second_database'))),
        'control', jsonb_build_object(
          'outcome', 'insufficient',
          'note', 'Prøve i 870: dekningen holder ikke ennå.',
          'searched_independently', true,
          'materiality_assessed', true))))
  $$,
  (select id from jobs where label = 'kontroll'),
  (select payload ->> 'job_key' from svar where label = 'kontrolloppgave'),
  (select payload ->> 'request_digest' from svar where label = 'kontrolloppgave')),
  '%mens oppgaven nå er%',
  'et svar avgitt på et grunnlag som er blitt et annet, avvises'
);
reset role;

-- Med det ferske avtrykket går den gjennom, og kontrollen registreres.
insert into svar (label, payload)
select 'fersk', workflow.agent_task(j) from workflow.pipeline_jobs j
where j.id = (select id from jobs where label = 'kontroll');

select set_config('request.jwt.claims',
                  '{"sub":"87000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'kontrollimport', api.import_agent_answer(
  (select id from jobs where label = 'kontroll'),
  jsonb_build_object(
    'answer_version', 'antidep/agent-answer@1',
    'task_version', 'antidep/agent-task@1',
    'role', 'source_quality_assessment',
    'job_key', (select payload ->> 'job_key' from svar where label = 'fersk'),
    'request_digest', (select payload ->> 'request_digest' from svar where label = 'fersk'),
    'output_schema_version', 'antidep/source-coverage-control-draft@1',
    'identity', jsonb_build_object(
      'provider', 'prøve-870-b', 'model', 'Kontrollmodell 870',
      'model_version_disclosure', 'not_exposed'),
    'result', jsonb_build_object(
      'searches', jsonb_build_array(jsonb_build_object(
        'platform', 'PubMed (eget motsøk)',
        'query_string', 'sertraline[tiab] AND (depression OR "depressive disorder")',
        'outcome', 'zero_results', 'result_count', 0, 'screened_count', 0,
        'truncated', false,
        'track_codes', jsonb_build_array('independent_second_database'))),
      'control', jsonb_build_object(
        'outcome', 'insufficient',
        'note', 'Prøve i 870: fire obligatoriske søkespor er fortsatt ikke forsøkt, så dekningen holder ikke.',
        'searched_independently', true,
        'missed_candidates', 0,
        'exclusions_checked', 1,
        'materiality_assessed', true))));
reset role;

select is(
  (select (payload -> 'imported')::boolean from svar where label = 'kontrollimport'),
  true,
  'kontrollsvaret ble importert'
);
select is(
  (select cc.outcome::text from workflow.monograph_coverage_controls cc
   join workflow.monograph_search_plans p on p.id = cc.plan_id
   where p.reference = (select value from refs where label = 'plan')),
  'insufficient',
  'og kontrollen godtar ikke dekningen ennå'
);
select is(
  (select (payload -> 'outcome' -> 'search_coverage_closed')::boolean
   from svar where label = 'kontrollimport'),
  false,
  'søkedekningen er derfor ikke erklært ferdig'
);
select is(
  (select p.closed_at from workflow.monograph_search_plans p
   where p.reference = (select value from refs where label = 'plan')),
  null,
  'og planen står åpen'
);

select * from finish();

rollback;
