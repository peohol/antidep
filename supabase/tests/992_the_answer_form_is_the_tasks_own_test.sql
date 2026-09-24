-- Migrasjon 014i — svarformen er oppgavens egen.
--
-- De to første vellykkede kjøringene av kildeoppdagelsen i drift ga to avviste
-- svar av tre, og de samme to feilene gjentok seg. Kontrollen gjorde rett i å
-- avvise dem begge. Disse prøvene holder begge sider:
--
--   * oppgaven sier nøyaktig hvilke runder dette leddet kan erstatte med et
--     smalere søk (`narrowable_rounds`) — bare leddets egne, bare de avkortede
--     som ingen senere runde har dekket, hver med plattformen og metoden
--     erstatningen må bruke — også når oppgaven viser det andre leddets
--     avkortede søk ved siden av,
--   * kandidatkilden med registrert tilgangsbegrensning står med den i
--     oppgaven, og regelen er sagt som den tilstandsregelen raden håndhever,
--   * importen avviser fortsatt «excluded» for en tilgangsbegrenset kilde, og
--     et narrows_request som ikke er leddets egen runde — i begge kildeleddene,
--   * og det riktige svaret — «awaiting_access», og en erstatning av en faktisk
--     avkortet runde fra oppgaven — importeres.
--
-- SQLSTATE 22023 = invalid_parameter_value.
begin;

create extension if not exists pgtap with schema extensions;

select plan(26);

-- ===========================================================================
-- Del 1 — Kontoene, bestillingen og modelltildelingene
-- ===========================================================================
insert into auth.users (id, email)
values ('99200000-0000-4000-8000-00000000000a', 'redaktor-992@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac992000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-992',
   'Redaktør 992',
   'Editor uten avgrensning, for prøven av den oppgavespesifikke svarformen i 992.',
   '99200000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('99200000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
   'ac992000-0000-4000-8000-00000000000a', 'Editor-tildeling for 992.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table jobs (label text primary key, id uuid not null) on commit drop;
create temporary table refs (label text primary key, value text not null) on commit drop;
create temporary table runs (label text primary key, id uuid not null) on commit drop;
create temporary table cred (label text primary key, secret text not null) on commit drop;
grant select, insert on svar to authenticated, anon;
grant select, insert on runs to anon;
grant select on jobs, refs, runs, cred to authenticated, anon;

select set_config('request.jwt.claims',
                  '{"sub":"99200000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 992.');
insert into svar (label, payload)
select 'modell_discovery', api.assign_agent_role_model(
  'source_discovery', 'prøve-992-a', 'Generatormodell 992', 'ikke-eksponert',
  'not_exposed', 'Prøve i 992.', 'Prøve i 992: generatorens modell.');
insert into svar (label, payload)
select 'modell_kontroll', api.assign_agent_role_model(
  'source_quality_assessment', 'prøve-992-b', 'Kontrollmodell 992', 'ikke-eksponert',
  'not_exposed', 'Prøve i 992.', 'Prøve i 992: kontrollens modell.');
reset role;

insert into cred (label, secret)
select 'discovery', provenance.issue_agent_identity_credential(
  'agent-identity:source-discovery-01', 'human:redaktor-992');
insert into cred (label, secret)
select 'kontroll', provenance.issue_agent_identity_credential(
  'agent-identity:source-quality-assessment-01', 'human:redaktor-992');

-- Den EFF-planen vi følger, runden den åpnet, og en runde på en annen plan.
insert into refs (label, value)
select 'plan', p.reference
from workflow.monograph_search_plans p
join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
where sp.code = 'EFF'
order by p.created_at
limit 1;

insert into refs (label, value)
select 'runde1', r.reference
from workflow.monograph_search_requests r
join workflow.monograph_search_plans p on p.id = r.plan_id
where p.reference = (select value from refs where label = 'plan')
  and r.requested_for_role = 'source_discovery'
  and r.platform is null and r.method is null;

insert into refs (label, value)
select 'annen_plans_runde', r.reference
from workflow.monograph_search_requests r
join workflow.monograph_search_plans p on p.id = r.plan_id
where p.reference <> (select value from refs where label = 'plan')
  and r.requested_for_role = 'source_discovery'
order by r.created_at
limit 1;

-- ===========================================================================
-- Del 2 — Runde 1: to avkortede søk, og en kilde bak en tilgangsbegrensning
-- ===========================================================================
set local role anon;
insert into runs (label, id)
select 'discovery', api.begin_agent_run(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  'source_discovery', 'antidep', 'search-execution-and-registration', '1.0.0',
  'source-discovery/machine-execution/2', 'antidep-evidence/1',
  jsonb_build_object('search_plan_reference', (select value from refs where label = 'plan')));

insert into svar (label, payload)
select 'europepmc', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'plan'),
  (select value from refs where label = 'runde1'),
  'Europe PMC', '"sertralin" AND ("depressiv lidelse")', 'pageSize=25',
  'https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=x',
  'sha256:' || repeat('a', 64),
  'executed', 400, 25, true, 'Bare den første siden av trefflisten ble lest.', null,
  array['bibliographic_database'],
  jsonb_build_array(
    jsonb_build_object(
      'identifier_kind', 'doi',
      'identifier_value', '10.1000/992-apen',
      'title', 'En åpent tilgjengelig studie (prøve 992)',
      'discovery_path', 'Europe PMC, søk gjennom det åpne REST-endepunktet',
      'access_limited', false),
    jsonb_build_object(
      'identifier_kind', 'pmid',
      'identifier_value', '99200001',
      'title', 'En studie bak betalingsmur (prøve 992)',
      'discovery_path', 'Europe PMC, søk gjennom det åpne REST-endepunktet',
      'access_limited', true,
      'access_limitation_note', 'Bare sammendraget er åpent tilgjengelig.')));

insert into svar (label, payload)
select 'crossref', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'plan'),
  (select value from refs where label = 'runde1'),
  'Crossref', '"sertralin"', 'rows=25',
  'https://api.crossref.org/works?query.bibliographic=x',
  'sha256:' || repeat('b', 64),
  'executed', 900, 25, true, 'Bare den første siden av trefflisten ble lest.', null,
  array['bibliographic_database', 'independent_second_database'], null);
reset role;

-- De øvrige rundene planen åpnet, som søk uten treff.
insert into svar (label, payload)
select 'runde1|' || r.platform || '|' || r.method, api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'plan'),
  r.reference, r.platform, 'Prøve 992: ' || r.method, null,
  'https://example.test/' || r.method, 'sha256:' || repeat('e', 64),
  'zero_results', 0, 0, false, null, null, r.track_codes, null, r.method)
from workflow.monograph_search_requests r
join workflow.monograph_search_plans p on p.id = r.plan_id
where p.reference = (select value from refs where label = 'plan')
  and r.requested_for_role = 'source_discovery'
  and r.method is not null;
insert into svar (label, payload)
select 'lukk1|' || r.platform || '|' || r.method, api.close_monograph_search_request(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'), r.reference)
from workflow.monograph_search_requests r
join workflow.monograph_search_plans p on p.id = r.plan_id
where p.reference = (select value from refs where label = 'plan')
  and r.requested_for_role = 'source_discovery'
  and r.method is not null;

set local role anon;
insert into svar (label, payload)
select 'lukk1', api.close_monograph_search_request(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'runde1'));
reset role;

insert into jobs (label, id)
select 'discovery', j.id
from workflow.pipeline_jobs j
join workflow.monograph_search_plans p
  on p.id = workflow.manifest_uuid(j.input_manifest, 'search_plan_id')
where j.agent_role = 'source_discovery'
  and p.reference = (select value from refs where label = 'plan');

insert into svar (label, payload)
select 'oppgave', workflow.agent_task(j) from workflow.pipeline_jobs j
where j.id = (select id from jobs where label = 'discovery');

-- ===========================================================================
-- Del 3 — Oppgaven sier hva svaret kan oppgi
-- ===========================================================================
select is(
  (select jsonb_agg(jsonb_build_array(n ->> 'request_reference', n ->> 'platform', n ->> 'method')
                    order by n ->> 'platform')
   from svar, jsonb_array_elements(payload -> 'input' -> 'narrowable_rounds') as n
   where label = 'oppgave'),
  jsonb_build_array(
    jsonb_build_array((select value from refs where label = 'runde1'), 'Crossref', 'keyword'),
    jsonb_build_array((select value from refs where label = 'runde1'), 'Europe PMC', 'keyword')),
  'oppgaven lister hver avkortet runde leddet kan erstatte, med plattformen og metoden erstatningen må bruke'
);
select ok(
  (select n -> 'queries' ? '"sertralin" AND ("depressiv lidelse")'
   from svar, jsonb_array_elements(payload -> 'input' -> 'narrowable_rounds') as n
   where label = 'oppgave' and n ->> 'platform' = 'Europe PMC'),
  'og søkestrengen som ble avkortet, så det smalere søket kan skrives mot den'
);
select is(
  (select c -> 'access_limited'
   from svar, jsonb_array_elements(payload -> 'input' -> 'candidates') as c
   where label = 'oppgave' and c ->> 'identifier_value' = '99200001'),
  'true'::jsonb,
  'kilden bak betalingsmuren står i oppgaven med sin registrerte tilgangsbegrensning'
);
select ok(
  (select bool_or(rule #>> '{}' like '%kan ikke ekskluderes, uansett grunn%awaiting_access%')
   from svar, jsonb_array_elements(payload -> 'input' -> 'rules') as rule
   where label = 'oppgave'),
  'og regelen er sagt som den tilstandsregelen raden håndhever, ikke som en regel om begrunnelsen'
);
select is(
  (select jsonb_build_array(payload ->> 'prompt_template_version', payload ->> 'output_schema_version')
   from svar where label = 'oppgave'),
  jsonb_build_array('source-discovery/machine-search-appraisal/6', 'antidep/source-discovery-draft@5'),
  'oppgaven er bygget under den nye promptmalen og svarformen'
);

-- ===========================================================================
-- Del 4 — Kildeoppdagelsen: de to gjentakende feilene avvises fortsatt
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"99200000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format($$
    select api.import_agent_answer(%L, jsonb_build_object(
      'answer_version', 'antidep/agent-answer@2',
      'task_version', 'antidep/agent-task@1',
      'role', 'source_discovery',
      'job_key', %L,
      'request_digest', %L,
      'output_schema_version', 'antidep/source-discovery-draft@5',
      'result', jsonb_build_object(
        'candidate_appraisals', jsonb_build_array(jsonb_build_object(
          'identifier_kind', 'pmid',
          'identifier_value', '99200001',
          'decision', 'excluded',
          'decision_reason', 'Tittelen viser at studien gjelder en annen populasjon.')))))
  $$,
  (select id from jobs where label = 'discovery'),
  (select payload ->> 'job_key' from svar where label = 'oppgave'),
  (select payload ->> 'request_digest' from svar where label = 'oppgave')),
  '22023',
  'En kilde med registrert tilgangsbegrensning kan ikke ekskluderes.',
  'en tilgangsbegrenset kilde kan fortsatt ikke ekskluderes — heller ikke med en faglig begrunnelse'
);
select throws_ok(
  format($$
    select api.import_agent_answer(%L, jsonb_build_object(
      'answer_version', 'antidep/agent-answer@2',
      'task_version', 'antidep/agent-task@1',
      'role', 'source_discovery',
      'job_key', %L,
      'request_digest', %L,
      'output_schema_version', 'antidep/source-discovery-draft@5',
      'result', jsonb_build_object(
        'candidate_appraisals', jsonb_build_array(),
        'search_requests', jsonb_build_array(jsonb_build_object(
          'rationale', 'Et smalere søk enn det brede.',
          'strategy', 'targeted',
          'query_terms', jsonb_build_array('weight gain'),
          'platform', 'Europe PMC', 'method', 'keyword', 'narrows_request', %L)))))
  $$,
  (select id from jobs where label = 'discovery'),
  (select payload ->> 'job_key' from svar where label = 'oppgave'),
  (select payload ->> 'request_digest' from svar where label = 'oppgave'),
  (select value from refs where label = 'annen_plans_runde')),
  '22023',
  'Søkeforespørselen sier at den snevrer inn en søkerunde som ikke finnes på denne planen for dette leddet.',
  'og et smalere søk kan fortsatt ikke erstatte en runde som ikke er en av oppgavens'
);
reset role;

-- ===========================================================================
-- Del 5 — Kildeoppdagelsen: det riktige svaret importeres
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"99200000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'import', api.import_agent_answer(
  (select id from jobs where label = 'discovery'),
  jsonb_build_object(
    'answer_version', 'antidep/agent-answer@2',
    'task_version', 'antidep/agent-task@1',
    'role', 'source_discovery',
    'job_key', (select payload ->> 'job_key' from svar where label = 'oppgave'),
    'request_digest', (select payload ->> 'request_digest' from svar where label = 'oppgave'),
    'output_schema_version', 'antidep/source-discovery-draft@5',
    'result', jsonb_build_object(
      'candidate_appraisals', jsonb_build_array(
        jsonb_build_object(
          'identifier_kind', 'pmid',
          'identifier_value', '99200001',
          'decision', 'awaiting_access',
          'decision_reason', 'Tittelen tyder på en annen populasjon, men Antidep har ikke lest studien.'),
        jsonb_build_object(
          'identifier_kind', 'doi',
          'identifier_value', '10.1000/992-apen',
          'decision', 'excluded',
          'decision_reason', 'Studien gjelder en annen populasjon enn behovet.')),
      'search_requests', jsonb_build_array(jsonb_build_object(
        'rationale', 'Trefflisten i Europe PMC ble avkortet; det som betyr noe er vektendringen.',
        'strategy', 'targeted',
        'query_terms', jsonb_build_array('weight gain'),
        'platform', 'Europe PMC',
        'method', 'keyword',
        'narrows_request', (select value from refs where label = 'runde1'))))));
reset role;

select is(
  (select (payload -> 'imported')::boolean from svar where label = 'import'),
  true,
  'svaret som setter den tilgangsbegrensede kilden til «avventer tilgang», importeres'
);
select bag_eq(
  $$select c.identifier_value || '|' || l.decision::text
    from workflow.monograph_candidate_source_plans l
    join workflow.monograph_candidate_sources c on c.id = l.candidate_source_id
    join workflow.monograph_search_plans p on p.id = l.plan_id
    where p.reference = (select value from refs where label = 'plan')$$,
  $$values ('99200001|awaiting_access'), ('10.1000/992-apen|excluded')$$,
  'og en åpent tilgjengelig kilde kan fortsatt ekskluderes med en faglig grunn'
);
select is(
  (select (payload -> 'outcome' -> 'search_requests_opened')::integer
   from svar where label = 'import'),
  1,
  'erstatningen av en faktisk avkortet runde fra oppgaven åpnet en ny runde'
);

insert into refs (label, value)
select 'runde2', r.reference
from workflow.monograph_search_requests r
join workflow.monograph_search_plans p on p.id = r.plan_id
where p.reference = (select value from refs where label = 'plan')
  and r.requested_for_role = 'source_discovery'
  and r.search_round = 2
  and r.origin = 'agent_requested';

select is(
  (select e.reference || '|' || r.platform || '|' || r.method
   from workflow.monograph_search_requests r
   join workflow.monograph_search_requests e on e.id = r.supersedes_request_id
   where r.reference = (select value from refs where label = 'runde2')),
  (select value from refs where label = 'runde1') || '|Europe PMC|keyword',
  'og den står som den smalere runden som uttrykkelig erstatter den avkortede, med samme plattform og metode'
);

-- Runde 2 leses helt. Europe PMC-avkortingen i runde 1 er da dekket; Crossref
-- sin er det ikke.
set local role anon;
insert into svar (label, payload)
select 'maskinsok2', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'plan'),
  (select value from refs where label = 'runde2'),
  'Europe PMC', '"sertralin" AND "weight gain"', 'pageSize=25',
  'https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=y',
  'sha256:' || repeat('c', 64),
  'executed', 18, 18, false, null, null,
  array['bibliographic_database'], null, 'keyword');
insert into svar (label, payload)
select 'lukk2', api.close_monograph_search_request(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'runde2'));
reset role;

insert into jobs (label, id)
select 'discovery2', j.id
from workflow.pipeline_jobs j
join workflow.monograph_search_plans p
  on p.id = workflow.manifest_uuid(j.input_manifest, 'search_plan_id')
where j.agent_role = 'source_discovery' and j.state = 'ready'
  and p.reference = (select value from refs where label = 'plan');

insert into svar (label, payload)
select 'oppgave2', workflow.agent_task(j) from workflow.pipeline_jobs j
where j.id = (select id from jobs where label = 'discovery2');

select is(
  (select jsonb_agg(jsonb_build_array(n ->> 'request_reference', n ->> 'platform', n ->> 'method'))
   from svar, jsonb_array_elements(payload -> 'input' -> 'narrowable_rounds') as n
   where label = 'oppgave2'),
  jsonb_build_array(
    jsonb_build_array((select value from refs where label = 'runde1'), 'Crossref', 'keyword')),
  'en runde som er dekket av den smalere, kan ikke erstattes igjen — bare den som fortsatt er avkortet'
);

-- Kildeoppdagelsen avslutter uten flere forespørsler, og dekningskontrollens
-- motsøkerunde åpnes.
select set_config('request.jwt.claims',
                  '{"sub":"99200000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'import2', api.import_agent_answer(
  (select id from jobs where label = 'discovery2'),
  jsonb_build_object(
    'answer_version', 'antidep/agent-answer@2',
    'task_version', 'antidep/agent-task@1',
    'role', 'source_discovery',
    'job_key', (select payload ->> 'job_key' from svar where label = 'oppgave2'),
    'request_digest', (select payload ->> 'request_digest' from svar where label = 'oppgave2'),
    'output_schema_version', 'antidep/source-discovery-draft@5',
    'result', jsonb_build_object(
      'candidate_appraisals', jsonb_build_array(),
      'note', 'Prøve i 992: ingen flere søk nå.')));
reset role;

insert into refs (label, value)
select 'kontrollrunde', r.reference
from workflow.monograph_search_requests r
join workflow.monograph_search_plans p on p.id = r.plan_id
where p.reference = (select value from refs where label = 'plan')
  and r.requested_for_role = 'source_quality_assessment';

-- ===========================================================================
-- Del 6 — Dekningskontrollen: bare dens egne runder kan erstattes
-- ===========================================================================
set local role anon;
insert into runs (label, id)
select 'kontroll', api.begin_agent_run(
  'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
  'source_quality_assessment', 'antidep', 'coverage-control-registration', '1.0.0',
  'source-coverage/machine-countersearch/1', 'antidep-evidence/1',
  jsonb_build_object('search_plan_reference', (select value from refs where label = 'plan')));
insert into svar (label, payload)
select 'motsok', api.record_monograph_machine_search(
  'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
  (select id from runs where label = 'kontroll'),
  (select value from refs where label = 'plan'),
  (select value from refs where label = 'kontrollrunde'),
  'Crossref', '"sertralin" AND "depressiv lidelse"', 'rows=25',
  'https://api.crossref.org/works?query=z', 'sha256:' || repeat('d', 64),
  'executed', 250, 25, true, 'Bare den første siden av trefflisten ble lest.', null,
  array[]::text[], null);
insert into svar (label, payload)
select 'lukk_kontroll', api.close_monograph_search_request(
  'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
  (select id from runs where label = 'kontroll'),
  (select value from refs where label = 'kontrollrunde'));
reset role;

insert into jobs (label, id)
select 'kontrolljobb', j.id from workflow.pipeline_jobs j
where j.agent_role = 'source_quality_assessment' and j.state = 'ready'
limit 1;

insert into svar (label, payload)
select 'kontrolloppgave', workflow.agent_task(j) from workflow.pipeline_jobs j
where j.id = (select id from jobs where label = 'kontrolljobb');

select ok(
  (select bool_or(s ->> 'request_reference' = (select value from refs where label = 'runde1')
                  and (s -> 'truncated')::boolean
                  and not (s -> 'truncation_resolved')::boolean)
   from svar, jsonb_array_elements(payload -> 'input' -> 'machine_searches') as s
   where label = 'kontrolloppgave'),
  'kontrolloppgaven viser generatorens avkortede runde ved siden av sine egne søk'
);
select is(
  (select jsonb_agg(jsonb_build_array(n ->> 'request_reference', n ->> 'platform', n ->> 'method'))
   from svar, jsonb_array_elements(payload -> 'input' -> 'narrowable_rounds') as n
   where label = 'kontrolloppgave'),
  jsonb_build_array(
    jsonb_build_array((select value from refs where label = 'kontrollrunde'), 'Crossref', 'keyword')),
  'men den kan bare erstatte sin egen avkortede runde — generatorens står ikke i listen'
);
select is(
  (select c -> 'access_limited'
   from svar, jsonb_array_elements(payload -> 'input' -> 'candidates') as c
   where label = 'kontrolloppgave' and c ->> 'identifier_value' = '99200001'),
  'true'::jsonb,
  'og kilden bak betalingsmuren står med sin tilgangsbegrensning også her'
);
select is(
  (select jsonb_build_array(payload ->> 'prompt_template_version', payload ->> 'output_schema_version')
   from svar where label = 'kontrolloppgave'),
  jsonb_build_array('source-coverage/machine-countersearch-control/6',
                    'antidep/source-coverage-control-draft@4'),
  'kontrolloppgaven er bygget under den nye promptmalen og svarformen'
);
select is(
  workflow.monograph_narrowable_rounds(
    (select p.id from workflow.monograph_search_plans p
     where p.reference = (select value from refs where label = 'plan')),
    'source_discovery'),
  (select payload -> 'input' -> 'narrowable_rounds' from svar where label = 'oppgave2'),
  'generatorens liste er den samme som før: kontrollens avkortede motsøk er ikke generatorens å erstatte'
);

select set_config('request.jwt.claims',
                  '{"sub":"99200000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format($$
    select api.import_agent_answer(%L, jsonb_build_object(
      'answer_version', 'antidep/agent-answer@2',
      'task_version', 'antidep/agent-task@1',
      'role', 'source_quality_assessment',
      'job_key', %L,
      'request_digest', %L,
      'output_schema_version', 'antidep/source-coverage-control-draft@4',
      'result', jsonb_build_object(
        'candidate_appraisals', jsonb_build_array(),
        'search_requests', jsonb_build_array(jsonb_build_object(
          'rationale', 'Generatorens Crossref-søk ble avkortet.',
          'strategy', 'targeted',
          'query_terms', jsonb_build_array('weight gain'),
          'platform', 'Crossref', 'method', 'keyword', 'narrows_request', %L)))))
  $$,
  (select id from jobs where label = 'kontrolljobb'),
  (select payload ->> 'job_key' from svar where label = 'kontrolloppgave'),
  (select payload ->> 'request_digest' from svar where label = 'kontrolloppgave'),
  (select value from refs where label = 'runde1')),
  '22023',
  'Søkeforespørselen sier at den snevrer inn en søkerunde som ikke finnes på denne planen for dette leddet.',
  'kontrollen kan fortsatt ikke erstatte generatorens runde, selv om oppgaven viser den som avkortet'
);
select throws_ok(
  format($$
    select api.import_agent_answer(%L, jsonb_build_object(
      'answer_version', 'antidep/agent-answer@2',
      'task_version', 'antidep/agent-task@1',
      'role', 'source_quality_assessment',
      'job_key', %L,
      'request_digest', %L,
      'output_schema_version', 'antidep/source-coverage-control-draft@4',
      'result', jsonb_build_object(
        'candidate_appraisals', jsonb_build_array(jsonb_build_object(
          'identifier_kind', 'pmid',
          'identifier_value', '99200001',
          'decision', 'excluded',
          'decision_reason', 'Studien er irrelevant for behovet.')))))
  $$,
  (select id from jobs where label = 'kontrolljobb'),
  (select payload ->> 'job_key' from svar where label = 'kontrolloppgave'),
  (select payload ->> 'request_digest' from svar where label = 'kontrolloppgave')),
  '22023',
  'En kilde med registrert tilgangsbegrensning kan ikke ekskluderes.',
  'og den kan heller ikke ekskludere en tilgangsbegrenset kilde'
);
reset role;

-- Og det riktige kontrollsvaret importeres.
select set_config('request.jwt.claims',
                  '{"sub":"99200000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'kontrollimport', api.import_agent_answer(
  (select id from jobs where label = 'kontrolljobb'),
  jsonb_build_object(
    'answer_version', 'antidep/agent-answer@2',
    'task_version', 'antidep/agent-task@1',
    'role', 'source_quality_assessment',
    'job_key', (select payload ->> 'job_key' from svar where label = 'kontrolloppgave'),
    'request_digest', (select payload ->> 'request_digest' from svar where label = 'kontrolloppgave'),
    'output_schema_version', 'antidep/source-coverage-control-draft@4',
    'result', jsonb_build_object(
      'candidate_appraisals', jsonb_build_array(jsonb_build_object(
        'identifier_kind', 'pmid',
        'identifier_value', '99200001',
        'decision', 'awaiting_access',
        'decision_reason', 'Kan ikke vurderes før fullteksten er hentet.')),
      'search_requests', jsonb_build_array(jsonb_build_object(
        'rationale', 'Motsøket i Crossref ble avkortet; det som betyr noe er vektendringen.',
        'strategy', 'targeted',
        'query_terms', jsonb_build_array('weight gain'),
        'platform', 'Crossref',
        'method', 'keyword',
        'narrows_request', (select value from refs where label = 'kontrollrunde'))))));
reset role;

select is(
  (select (payload -> 'imported')::boolean from svar where label = 'kontrollimport'),
  true,
  'kontrollsvaret med «avventer tilgang» og en erstatning av dens egen avkortede runde importeres'
);
select is(
  (select (payload -> 'outcome' -> 'search_requests_opened')::integer
   from svar where label = 'kontrollimport'),
  1,
  'og erstatningen åpnet en ny motsøkerunde'
);
select is(
  (select e.reference || '|' || r.platform || '|' || r.method
   from workflow.monograph_search_requests r
   join workflow.monograph_search_requests e on e.id = r.supersedes_request_id
   where r.requested_for_role = 'source_quality_assessment'
     and r.plan_id = (select p.id from workflow.monograph_search_plans p
                      where p.reference = (select value from refs where label = 'plan'))),
  (select value from refs where label = 'kontrollrunde') || '|Crossref|keyword',
  'som uttrykkelig erstatter kontrollens egen runde, med samme plattform og metode'
);
select is(
  (select l.decision::text
   from workflow.monograph_candidate_source_plans l
   join workflow.monograph_candidate_sources c on c.id = l.candidate_source_id
   join workflow.monograph_search_plans p on p.id = l.plan_id
   where p.reference = (select value from refs where label = 'plan')
     and c.identifier_value = '99200001'),
  'awaiting_access',
  'og den tilgangsbegrensede kilden står fortsatt som «avventer tilgang»'
);

-- ===========================================================================
-- Del 7 — Kontraktene og funksjonen er databasens egne
-- ===========================================================================
select is(
  (select jsonb_build_array(c ->> 'prompt_template_version', c ->> 'output_schema_version')
   from workflow.agent_task_contract('source_discovery') as c),
  jsonb_build_array('source-discovery/machine-search-appraisal/6', 'antidep/source-discovery-draft@5'),
  'kontrakten for kildeoppdagelsen er den nye'
);
select is(
  (select jsonb_build_array(c ->> 'prompt_template_version', c ->> 'output_schema_version')
   from workflow.agent_task_contract('source_quality_assessment') as c),
  jsonb_build_array('source-coverage/machine-countersearch-control/6',
                    'antidep/source-coverage-control-draft@4'),
  'og kontrakten for dekningskontrollen'
);
select ok(
  not has_function_privilege('authenticated',
    'workflow.monograph_narrowable_rounds(uuid, provenance.agent_role)', 'execute'),
  'listen over runder som kan erstattes, leses gjennom oppgaven og ikke direkte'
);

select * from finish();

rollback;
