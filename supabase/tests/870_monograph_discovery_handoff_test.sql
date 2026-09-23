-- Migrasjon 013v — kildeleddene gjennom den faktiske agentarbeidsformen, etter
-- at søkeutførelsen ble Antideps egen kode.
--
-- Filen dekker den feilen som faktisk oppsto i drift. Den autonome Workspace
-- Agent-en kom fram til sin første `source_discovery`-oppgave og frigjorde den
-- med `could_not_complete`, fordi oppgaven krevde databasesøk som ingen av
-- Antideps fem verktøy kan utføre. Motsigelsen var Antideps, og disse prøvene
-- holder de to sidene sammen:
--
--   * en ny søkeplan åpner en MASKINELL søkerunde og ingen semantisk oppgave,
--   * den semantiske oppgaven finnes først når runden faktisk er utført,
--   * oppgaven bærer de maskinelt utførte søkene med endepunkt og
--     responsavtrykk, de søkeveiene som ikke svarte, og kandidatene de ga,
--   * et svar som rapporterer utførte søk, avvises med sin egen setning,
--   * et svar som legger til en kandidatkilde uten oppdagelsesvei, avvises,
--   * en søkeforespørsel åpner en ny runde, og oppgaven kommer tilbake først
--     når den er utført,
--   * dekningskontrollen får sine EGNE maskinelt utførte motsøk under sin egen
--     rolle, og kan ikke erklære uavhengigheten sin selv,
--   * en søkevei som ikke svarte, registreres ærlig og låser ingenting, og
--   * et svar avgitt på et grunnlag som er blitt et annet, avvises.
--
-- SQLSTATE 22023 = invalid_parameter_value, 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(61);

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
create temporary table runs (label text primary key, id uuid not null) on commit drop;
create temporary table cred (label text primary key, secret text not null) on commit drop;
grant select, insert on svar to authenticated, anon;
grant select, insert on runs to anon;
grant select on jobs, refs, runs, cred to authenticated, anon;

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

insert into cred (label, secret)
select 'discovery', provenance.issue_agent_identity_credential(
  'agent-identity:source-discovery-01', 'human:redaktor-870');
insert into cred (label, secret)
select 'kontroll', provenance.issue_agent_identity_credential(
  'agent-identity:source-quality-assessment-01', 'human:redaktor-870');

select is(
  (select (payload -> 'assigned')::boolean from svar where label = 'modell_discovery'),
  true,
  'kildeoppdagelsen kan tildeles en ekstern KI-tjeneste'
);

-- ===========================================================================
-- Del 2 — Bestillingen åpner en maskinell søkerunde, ikke en modelloppgave
-- ===========================================================================
select cmp_ok(
  (select count(*)::integer from workflow.monograph_search_requests
   where requested_for_role = 'source_discovery' and state = 'pending'),
  '>', 0,
  'bestillingen åpnet de maskinelle søkerundene av seg selv'
);
select is(
  (select count(*)::integer from workflow.pipeline_jobs
   where agent_role = 'source_discovery'),
  0,
  'og ingen semantisk kildeoppgave finnes ennå: den ville krevd søke-I/O agenten ikke har verktøy til'
);
select is_empty(
  $$
    select p.id
    from workflow.monograph_search_plans p
    join knowledge.monograph_editions e on e.id = p.edition_id
    where p.closed_at is null and p.paused_at is null and e.superseded_at is null
      and not exists (
        select 1 from workflow.monograph_search_requests r
        where r.plan_id = p.id and r.requested_for_role = 'source_discovery'
      )
  $$,
  'ingen åpen plan står uten en maskinell søkerunde'
);

-- Den EFF-planen vi følger, og runden den åpnet.
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

select matches(
  workflow.monograph_search_phase_problem(
    (select p.id from workflow.monograph_search_plans p
     where p.reference = (select value from refs where label = 'plan')),
    'source_discovery'),
  'ikke ferdig',
  'porten sier hvorfor den semantiske oppgaven ikke finnes: søkene er ikke utført'
);
select is(
  (select r.origin::text from workflow.monograph_search_requests r
   where r.reference = (select value from refs where label = 'runde1')),
  'plan_opened',
  'den første runden er planens egen, og ikke noe en modell ba om'
);
select is(
  (select r.strategy::text from workflow.monograph_search_requests r
   where r.reference = (select value from refs where label = 'runde1')),
  'broad',
  'og den er det brede orienterende søket (SOURCE_POLICY.md §4.1)'
);

-- ===========================================================================
-- Del 3 — Den maskinelle søkerunden, og oppgaven den åpner
-- ===========================================================================
set local role anon;
insert into runs (label, id)
select 'discovery', api.begin_agent_run(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  'source_discovery', 'antidep', 'search-execution-and-registration', '1.0.0',
  'source-discovery/machine-execution/2', 'antidep-evidence/1',
  jsonb_build_object('search_plan_reference', (select value from refs where label = 'plan')));

insert into svar (label, payload)
select 'maskinsok', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'plan'),
  (select value from refs where label = 'runde1'),
  'Europe PMC', '"sertralin" AND ("depressiv lidelse")', 'pageSize=25',
  'https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=x',
  'sha256:' || repeat('a', 64),
  'executed', 31, 25, false, null, null,
  array['bibliographic_database'],
  jsonb_build_array(jsonb_build_object(
    'identifier_kind', 'doi',
    'identifier_value', '10.1000/870-oversikt',
    'title', 'Oversikt om effekt ved depressiv lidelse (prøve 870)',
    'discovery_path', 'Europe PMC, søk gjennom det åpne REST-endepunktet')));

-- En søkevei som ikke svarte i det hele tatt. Den har ingen responsavtrykk å
-- bære, og den skal likevel kunne registreres: ellers ville den ærlige
-- begrensningen ikke hatt noen vei inn (SOURCE_POLICY.md §8.2).
insert into svar (label, payload)
select 'utilgjengelig', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'plan'),
  (select value from refs where label = 'runde1'),
  'PubMed', '"sertralin"', null,
  'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed',
  null,
  'unavailable', null, 0, false, null,
  'Søkeveien svarte ikke: tidsavbrudd.',
  array['bibliographic_database'], null);

-- Det uavhengige sporet svarte heller ikke. Et spor der ingen søkevei svarte,
-- er ikke forsøkt: det står og venter på neste runde.
insert into svar (label, payload)
select 'uavhengig_nede', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'plan'),
  (select value from refs where label = 'runde1'),
  'Crossref', '"sertralin"', null,
  'https://api.crossref.org/works?query.bibliographic=x',
  null,
  'unavailable', null, 0, false, null,
  'Søkeveien svarte ikke: HTTP 503 etter siste forsøk.',
  array['bibliographic_database', 'independent_second_database'], null);

-- De øvrige rundene planen åpnet — én per søkemetode registeret har for de
-- ventende sporene (migrasjon 014d). Kjøreren utfører hver av dem; her står
-- de som søk uten treff, og lukkes. Den semantiske oppgaven kommer først når
-- den siste er lukket.
reset role;
insert into svar (label, payload)
select 'runde1|' || r.platform || '|' || r.method, api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'plan'),
  r.reference, r.platform, 'Prøve 870: ' || r.method, null,
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

select is(
  (select count(*)::integer from svar where label like 'lukk1|%' and (payload -> 'enqueued_job')::boolean),
  0,
  'ingen semantisk oppgave før hver runde planen åpnet, er utført'
);

set local role anon;
insert into svar (label, payload)
select 'lukk1', api.close_monograph_search_request(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'runde1'));
reset role;

select is(
  (select s.response_digest from workflow.monograph_searches s
   where s.platform = 'PubMed'
     and s.outcome = 'unavailable'
     and s.plan_id = (select p.id from workflow.monograph_search_plans p
                      where p.reference = (select value from refs where label = 'plan'))),
  null,
  'en søkevei som aldri svarte, registreres uten et responsavtrykk framfor å bli avvist'
);
select is(
  (select (payload ->> 'state') from svar where label = 'lukk1'),
  'fulfilled',
  'runden er utført fordi minst ett søk faktisk gikk'
);
select is(
  (select (payload -> 'enqueued_job')::boolean from svar where label = 'lukk1'),
  true,
  'og lukkingen er det som legger den semantiske vurderingsoppgaven i køen'
);

insert into jobs (label, id)
select 'discovery', j.id
from workflow.pipeline_jobs j
join workflow.monograph_search_plans p
  on p.id = workflow.manifest_uuid(j.input_manifest, 'search_plan_id')
where j.agent_role = 'source_discovery'
  and p.reference = (select value from refs where label = 'plan');

select is(
  (select (j.input_manifest ->> 'discovery_round')::integer from workflow.pipeline_jobs j
   where j.id = (select id from jobs where label = 'discovery')),
  1,
  'oppgaven hører til runde 1, og runden står i manifestet'
);
select is(
  (select workflow.agent_task_problem(j, null) from workflow.pipeline_jobs j
   where j.id = (select id from jobs where label = 'discovery')),
  null,
  'oppgaven kan utføres: søkene er gjort og modellen er valgt'
);

-- ===========================================================================
-- Del 4 — Oppgaven bærer det maskinen hentet, og ingen beskjed om å søke
-- ===========================================================================
insert into svar (label, payload)
select 'oppgave', workflow.agent_task(j) from workflow.pipeline_jobs j
where j.id = (select id from jobs where label = 'discovery');

select ok(
  (select jsonb_array_length(payload -> 'input' -> 'machine_searches') = 6
   from svar where label = 'oppgave'),
  'oppgaven bærer de maskinelt utførte søkene — fritekstsøkene, oversiktssøkene og forsøksregisteret'
);
select ok(
  (select bool_and(s ->> 'execution_evidence' = 'machine_executed' and s ? 'endpoint')
   from svar, jsonb_array_elements(payload -> 'input' -> 'machine_searches') as s
   where label = 'oppgave'),
  'hvert av dem med utførelsesbeviset og endepunktet Antidep faktisk kalte'
);
select ok(
  (select jsonb_array_length(payload -> 'input' -> 'search_limitations') = 2
   from svar where label = 'oppgave'),
  'søkeveiene som ikke svarte, står for seg som begrensninger og ikke som null treff'
);
select ok(
  (select jsonb_array_length(payload -> 'input' -> 'candidates') = 1
   from svar where label = 'oppgave'),
  'og kandidatkilden søket ga, ligger klar til vurdering'
);
select ok(
  (select bool_and(need ? 'question' and need ? 'need_reference'
                   and not (need ? 'expected_answer'))
   from svar, jsonb_array_elements(payload -> 'input' -> 'needs') as need
   where label = 'oppgave'),
  'behovene bærer spørsmålet og referansen, og ingen forventet konklusjon'
);
select ok(
  (select payload -> 'input' -> 'search_request_options' -> 'platforms'
          = (select jsonb_agg(distinct m.platform) from knowledge.monograph_search_methods m)
   from svar where label = 'oppgave'),
  'og oppgaven sier uttømmende hvilke søketjenester en forespørsel kan navngi — lest av registeret'
);
select ok(
  (select bool_and(m ? 'covers' and m ? 'follows_central_sources')
   from svar, jsonb_array_elements(payload -> 'input' -> 'search_request_options' -> 'methods') as m
   where label = 'oppgave'),
  'og hver søkemetode står med hva den dekker, og om den følger sentrale kilder'
);
select is(
  (select payload ->> 'output_schema_version' from svar where label = 'oppgave'),
  'antidep/source-discovery-draft@5',
  'svarformen er den som ikke har et felt for utførte søk'
);

-- ===========================================================================
-- Del 5 — Et svar kan ikke hevde å ha utført søk, og ikke finne på en kilde
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"87000000-0000-4000-8000-00000000000a"}', true);
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
        'candidate_appraisals', jsonb_build_array(),
        'searches', jsonb_build_array(jsonb_build_object(
          'platform', 'PubMed', 'query_string', 'sertraline[tiab]',
          'outcome', 'executed', 'result_count', 12)))))
  $$,
  (select id from jobs where label = 'discovery'),
  (select payload ->> 'job_key' from svar where label = 'oppgave'),
  (select payload ->> 'request_digest' from svar where label = 'oppgave')),
  '22023',
  'Svaret rapporterer utførte søk, og det kan ikke dette agentleddet.',
  'et modellrapportert søk kan ikke fremstilles som utført arbeid'
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
        'candidate_appraisals', jsonb_build_array(jsonb_build_object(
          'identifier_kind', 'doi',
          'identifier_value', '10.1000/870-fra-hukommelsen',
          'decision', 'included',
          'decision_reason', 'En kilde ingen søk fant.')))))
  $$,
  (select id from jobs where label = 'discovery'),
  (select payload ->> 'job_key' from svar where label = 'oppgave'),
  (select payload ->> 'request_digest' from svar where label = 'oppgave')),
  '22023',
  null,
  'en kilde som ikke er funnet av et registrert søk, kan ikke vurderes inn'
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
          'query_terms', jsonb_build_array('weight gain'),
          'narrows_request', repeat('0', 32))))))
  $$,
  (select id from jobs where label = 'discovery'),
  (select payload ->> 'job_key' from svar where label = 'oppgave'),
  (select payload ->> 'request_digest' from svar where label = 'oppgave')),
  '22023',
  'Søkeforespørselen sier at den snevrer inn en søkerunde som ikke finnes på denne planen for dette leddet.',
  'et smalere søk kan ikke si at det erstatter en runde som ikke finnes'
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
          'query_terms', jsonb_build_array('weight gain'),
          'platform', 'ClinicalTrials.gov', 'method', 'registry_search', 'narrows_request', %L)))))
  $$,
  (select id from jobs where label = 'discovery'),
  (select payload ->> 'job_key' from svar where label = 'oppgave'),
  (select payload ->> 'request_digest' from svar where label = 'oppgave'),
  (select value from refs where label = 'runde1')),
  '22023',
  'Den smalere runden bruker ingen av søkemetodene i runden den sier den erstatter.',
  'og et forsøksregistersøk kan ikke erstatte et avkortet fritekstsøk: det sier ingenting om resten'
);

reset role;

-- ===========================================================================
-- Del 6 — Svaret, og søkeforespørselen som åpner neste runde
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"87000000-0000-4000-8000-00000000000a"}', true);
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
    -- Regresjon (013u): svaret har ingen identity i det hele tatt. Det er
    -- nøyaktig det en ChatGPT Workspace Agent leverer.
    'result', jsonb_build_object(
      'candidate_appraisals', jsonb_build_array(jsonb_build_object(
        'identifier_kind', 'doi',
        'identifier_value', '10.1000/870-oversikt',
        'decision', 'selected_for_retrieval',
        'decision_reason', 'Dekker endepunktet og avgrensningen behovet gjelder.',
        'could_change_conclusion', true,
        'materiality_reason', 'Er den eneste oversikten som rapporterer nettopp dette utfallet.',
        'uses', jsonb_build_array(jsonb_build_object(
          'need_reference', (select payload -> 'input' -> 'needs' -> 0 ->> 'need_reference'
                             from svar where label = 'oppgave'),
          'proposed_use', 'Kan dokumentere endringen i symptomskår for den avgrensede populasjonen.')))),
      'search_requests', jsonb_build_array(jsonb_build_object(
        'rationale', 'Det uavhengige andre sporet svarte ikke, og et målrettet søk mangler.',
        'strategy', 'targeted',
        'query_terms', jsonb_build_array('sertraline'),
        'narrows_request', (select value from refs where label = 'runde1'))),
      'note', 'PubMed svarte ikke i denne runden.')));
reset role;

select is(
  (select (payload -> 'imported')::boolean from svar where label = 'import'),
  true,
  'vurderingssvaret ble importert gjennom den samme skriveveien de øvrige leddene bruker'
);
select is(
  (select array_agg(p.reference)
   from workflow.monograph_candidate_source_needs cn
   join workflow.monograph_candidate_sources c on c.id = cn.candidate_source_id
   join workflow.monograph_search_plans p on p.id = cn.plan_id
   where c.identifier_value = '10.1000/870-oversikt'),
  array[(select value from refs where label = 'plan')],
  'og bruken svaret foreslo, er bundet til planen svaret gjaldt (migrasjon 014c)'
);
select is(
  (select (payload -> 'outcome' -> 'search_requests_opened')::integer
   from svar where label = 'import'),
  1,
  'søkeforespørselen åpnet en ny maskinell runde'
);
select is(
  (select c.could_change_conclusion from workflow.monograph_candidate_sources c
   where c.identifier_value = '10.1000/870-oversikt'),
  true,
  'vesentligheten er den semantiske vurderingen, og den er registrert'
);
select is(
  (select p.discovery_round from workflow.monograph_search_plans p
   where p.reference = (select value from refs where label = 'plan')),
  2,
  'planen står nå i runde 2'
);
select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   join workflow.monograph_search_plans p
     on p.id = workflow.manifest_uuid(j.input_manifest, 'search_plan_id')
   where j.agent_role = 'source_discovery' and j.state = 'ready'
     and p.reference = (select value from refs where label = 'plan')),
  0,
  'og ingen ny vurderingsoppgave finnes før de bestilte søkene faktisk er utført'
);
select is(
  (select (payload -> 'outcome' ->> 'next_job_id') from svar where label = 'import'),
  null,
  'kontrolloppgaven legges ikke i køen når leddet ba om flere søk'
);

-- Runde 2 utføres, og vurderingsoppgaven kommer tilbake.
insert into refs (label, value)
select 'runde2', r.reference
from workflow.monograph_search_requests r
join workflow.monograph_search_plans p on p.id = r.plan_id
where p.reference = (select value from refs where label = 'plan')
  and r.requested_for_role = 'source_discovery'
  and r.search_round = 2
  and r.origin = 'agent_requested';

-- Og det Antidep åpnet selv: leddet valgte oversikten til innhenting og vurderte
-- den som mulig konklusjonsendrende. Referanselisten og de siterende arbeidene
-- til den følges nå av Antideps kode, uten at leddet måtte be om det.
select is(
  (select (payload -> 'outcome' -> 'machine_requests_opened')::integer
   from svar where label = 'import'),
  3,
  'Antidep åpnet selv én runde per kildefølgende metode for kilden leddet valgte'
);
select bag_eq(
  $$select r.platform || '|' || r.method || '|' || array_to_string(r.seed_identifiers, ',')
    from workflow.monograph_search_requests r
    where r.origin = 'selection_opened' and r.search_round = 2$$,
  $$values ('Europe PMC|references|doi:10.1000/870-oversikt'),
           ('Europe PMC|citations|doi:10.1000/870-oversikt'),
           ('Crossref|references|doi:10.1000/870-oversikt')$$,
  'og den følger nøyaktig den kilden kildeoppdagelsen valgte'
);

select is(
  (select r.origin::text from workflow.monograph_search_requests r
   where r.reference = (select value from refs where label = 'runde2')),
  'agent_requested',
  'runden er bestilt av det semantiske leddet, og opphavet står på raden'
);
select is(
  (select e.reference from workflow.monograph_search_requests r
   join workflow.monograph_search_requests e on e.id = r.supersedes_request_id
   where r.reference = (select value from refs where label = 'runde2')),
  (select value from refs where label = 'runde1'),
  'og den står som den smalere runden som uttrykkelig erstatter den brede'
);

set local role anon;
insert into svar (label, payload)
select 'maskinsok2', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'plan'),
  (select value from refs where label = 'runde2'),
  'Crossref', '"sertralin" AND "sertraline"', null,
  'https://api.crossref.org/works?query.bibliographic=x',
  'sha256:' || repeat('b', 64),
  'zero_results', 0, 0, false, null, null,
  array['bibliographic_database', 'independent_second_database'], null);
insert into svar (label, payload)
select 'lukk2', api.close_monograph_search_request(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'runde2'));
reset role;

-- Antideps kode følger kilden: Europe PMC har referanselisten, ingen i Europe
-- PMC siterer den ennå, og Crossref har ingen deponert liste.
insert into svar (label, payload)
select 'kilde|' || r.platform || '|' || r.method, api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'plan'),
  r.reference, r.platform,
  r.method || ' for ' || array_to_string(r.seed_identifiers, ', '), null,
  'https://example.test/' || r.method,
  case when r.platform = 'Crossref' then null else 'sha256:' || repeat('f', 64) end,
  case when r.platform = 'Crossref' then 'unavailable'
       when r.method = 'citations' then 'zero_results'
       else 'executed' end,
  case when r.platform = 'Crossref' then null
       when r.method = 'citations' then 0 else 2 end,
  case when r.platform = 'Crossref' or r.method = 'citations' then 0 else 2 end,
  false, null,
  case when r.platform = 'Crossref'
       then 'Utgiveren har ikke deponert en referanseliste i Crossref.' end,
  r.track_codes, null, r.method)
from workflow.monograph_search_requests r
where r.origin = 'selection_opened'
order by r.platform desc;
insert into svar (label, payload)
select 'lukk_kilde|' || r.platform || '|' || r.method, api.close_monograph_search_request(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'), r.reference)
from workflow.monograph_search_requests r
where r.origin = 'selection_opened';

select bag_eq(
  $$select k.code || '|' || a.state::text
    from workflow.monograph_search_track_attempts a
    join knowledge.monograph_search_tracks k on k.id = a.track_id
    join workflow.monograph_search_plans p on p.id = a.plan_id
    where p.reference = (select value from refs where label = 'plan')
      and k.code in ('reference_lists', 'citing_works')$$,
  $$values ('reference_lists|covered'), ('citing_works|covered')$$,
  'referanselisten og de siterende arbeidene er dekket av søk Antidep faktisk gjorde — en Crossref uten liste ble en begrensning, ikke null referanser'
);

insert into jobs (label, id)
select 'discovery2', j.id
from workflow.pipeline_jobs j
join workflow.monograph_search_plans p
  on p.id = workflow.manifest_uuid(j.input_manifest, 'search_plan_id')
where j.agent_role = 'source_discovery' and j.state = 'ready'
  and p.reference = (select value from refs where label = 'plan');

select isnt(
  (select id from jobs where label = 'discovery2'),
  (select id from jobs where label = 'discovery'),
  'den utførte runden ga en NY vurderingsoppgave, og ikke den gamle om igjen'
);
select is(
  (select (j.input_manifest ->> 'discovery_round')::integer from workflow.pipeline_jobs j
   where j.id = (select id from jobs where label = 'discovery2')),
  2,
  'og den hører til runde 2'
);

-- ===========================================================================
-- Del 7 — Kontrollens egne motsøk er maskinelt utførte, ikke erklærte
-- ===========================================================================
insert into svar (label, payload)
select 'oppgave2', workflow.agent_task(j) from workflow.pipeline_jobs j
where j.id = (select id from jobs where label = 'discovery2');

select set_config('request.jwt.claims',
                  '{"sub":"87000000-0000-4000-8000-00000000000a"}', true);
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
      'note', 'Det uavhengige sporet ga ingen treff. Ingen flere søk trengs nå.')));
reset role;

select isnt(
  (select (payload -> 'outcome' ->> 'search_plan_id') from svar where label = 'import2'),
  null,
  'en runde uten nye søkeforespørsler avslutter kildeoppdagelsens arbeid'
);
select is(
  (select count(*)::integer from workflow.monograph_search_requests r
   join workflow.monograph_search_plans p on p.id = r.plan_id
   where p.reference = (select value from refs where label = 'plan')
     and r.requested_for_role = 'source_quality_assessment'),
  1,
  'og den åpner dekningskontrollens egen maskinelle motsøkerunde'
);
select is(
  (select count(*)::integer from workflow.pipeline_jobs
   where agent_role = 'source_quality_assessment'),
  0,
  'kontrolloppgaven finnes ikke før dens egne motsøk er utført'
);

insert into refs (label, value)
select 'kontrollrunde', r.reference
from workflow.monograph_search_requests r
join workflow.monograph_search_plans p on p.id = r.plan_id
where p.reference = (select value from refs where label = 'plan')
  and r.requested_for_role = 'source_quality_assessment';

select is(
  (select r.strategy::text from workflow.monograph_search_requests r
   where r.reference = (select value from refs where label = 'kontrollrunde')),
  'targeted',
  'kontrollens motsøk har en annen strategi enn generatorens brede søk'
);
select is(
  (select cardinality(r.track_codes) from workflow.monograph_search_requests r
   where r.reference = (select value from refs where label = 'kontrollrunde')),
  0,
  'og den kan ikke dekke generatorens obligatoriske spor: da ville den produsert det den kontrollerer'
);

set local role anon;
insert into runs (label, id)
select 'kontroll', api.begin_agent_run(
  'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
  'source_quality_assessment', 'antidep', 'coverage-control-registration', '1.0.0',
  'source-coverage/machine-countersearch/1', 'antidep-evidence/1',
  jsonb_build_object('search_plan_reference', (select value from refs where label = 'plan')));
reset role;

set local role anon;
select throws_ok(
  format($$
    select api.record_monograph_machine_search(
      'agent-identity:source-quality-assessment-01', %L, %L, %L, %L,
      'Crossref', '"sertralin"', null, 'https://api.crossref.org/works?query=x',
      'sha256:' || repeat('c', 64), 'executed', 2, 2, false, null, null,
      array['bibliographic_database'], null)
  $$,
  (select secret from cred where label = 'kontroll'),
  (select id from runs where label = 'kontroll'),
  (select value from refs where label = 'plan'),
  (select value from refs where label = 'kontrollrunde')),
  '22023',
  'Søket erklærer et søkespor denne runden ikke kan dekke.',
  'kontrollens motsøk kan ikke dekke generatorens obligatoriske søkespor'
);
reset role;

-- Første motsøkerunde: ingen søkevei svarte. Den registreres ærlig, den lukkes,
-- og den låser ingenting — men den gir heller ingen uavhengighet.
set local role anon;
insert into svar (label, payload)
select 'motsok_nede', api.record_monograph_machine_search(
  'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
  (select id from runs where label = 'kontroll'),
  (select value from refs where label = 'plan'),
  (select value from refs where label = 'kontrollrunde'),
  'Crossref', '"sertralin" AND "depressiv lidelse"', null,
  'https://api.crossref.org/works?query=x', null,
  'unavailable', null, 0, false, null,
  'Søkeveien svarte ikke i denne kjøringen.',
  array[]::text[], null);
insert into svar (label, payload)
select 'lukk_kontroll1', api.close_monograph_search_request(
  'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
  (select id from runs where label = 'kontroll'),
  (select value from refs where label = 'kontrollrunde'));
reset role;

select is(
  (select (payload ->> 'state') from svar where label = 'lukk_kontroll1'),
  'unavailable',
  'en runde der ingen søkevei svarte, er utilgjengelig og ikke utført'
);
select is(
  (select (payload -> 'enqueued_job')::boolean from svar where label = 'lukk_kontroll1'),
  true,
  'og den låser ingenting: kontrolloppgaven kommer likevel, med begrensningen synlig'
);
select is(
  workflow.monograph_control_searched_independently(
    (select p.id from workflow.monograph_search_plans p
     where p.reference = (select value from refs where label = 'plan'))),
  false,
  'men kontrollen har ennå ingen egne søk som faktisk gikk'
);

insert into jobs (label, id)
select 'kontrolljobb', j.id from workflow.pipeline_jobs j
where j.agent_role = 'source_quality_assessment' and j.state = 'ready'
limit 1;

insert into svar (label, payload)
select 'kontrolloppgave', workflow.agent_task(j) from workflow.pipeline_jobs j
where j.id = (select id from jobs where label = 'kontrolljobb');

select is(
  (select payload -> 'subject' ->> 'kind' from svar where label = 'kontrolloppgave'),
  'kontroll av søkedekning',
  'kontrolloppgavens subjekt er kontrollen av søkedekningen'
);
select is(
  (select (payload -> 'input' -> 'control_task' -> 'independent_search_confirmed')::boolean
   from svar where label = 'kontrolloppgave'),
  false,
  'og oppgaven sier ærlig at ingen egne motsøk har gått ennå'
);

-- En godtatt dekning uten et eget motsøk som gikk, avvises.
select set_config('request.jwt.claims',
                  '{"sub":"87000000-0000-4000-8000-00000000000a"}', true);
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
        'control', jsonb_build_object(
          'outcome', 'accepted',
          'note', 'Prøve i 870: leste generatorens referanser og fant ingen mangler.',
          'materiality_assessed', true))))
  $$,
  (select id from jobs where label = 'kontrolljobb'),
  (select payload ->> 'job_key' from svar where label = 'kontrolloppgave'),
  (select payload ->> 'request_digest' from svar where label = 'kontrolloppgave')),
  '23001',
  'Kontrollen godtar dekningen uten at et eget motsøk faktisk har gått.',
  'en dekning kan ikke godtas av et kontrolledd som ikke har søkt selv'
);

-- Og kontrollen kan ikke erklære sin egen uavhengighet.
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
        'control', jsonb_build_object(
          'outcome', 'insufficient',
          'note', 'Prøve i 870.',
          'searched_independently', true,
          'materiality_assessed', true))))
  $$,
  (select id from jobs where label = 'kontrolljobb'),
  (select payload ->> 'job_key' from svar where label = 'kontrolloppgave'),
  (select payload ->> 'request_digest' from svar where label = 'kontrolloppgave')),
  '22023',
  null,
  'en erklæring om egen uavhengighet er ikke en opplysning svaret gir'
);
reset role;

-- ===========================================================================
-- Del 8 — Kontrollen ber om en ny motsøkerunde, og avgjør på resultatet
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"87000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'kontrollimport1', api.import_agent_answer(
  (select id from jobs where label = 'kontrolljobb'),
  jsonb_build_object(
    'answer_version', 'antidep/agent-answer@2',
    'task_version', 'antidep/agent-task@1',
    'role', 'source_quality_assessment',
    'job_key', (select payload ->> 'job_key' from svar where label = 'kontrolloppgave'),
    'request_digest', (select payload ->> 'request_digest' from svar where label = 'kontrolloppgave'),
    'output_schema_version', 'antidep/source-coverage-control-draft@4',
    'result', jsonb_build_object(
      'candidate_appraisals', jsonb_build_array(),
      'search_requests', jsonb_build_array(jsonb_build_object(
        'rationale', 'Motsøket nådde ikke fram. Uten et eget søk kan dekningen ikke vurderes.',
        'platform', 'Crossref',
        'strategy', 'targeted')))));
reset role;

select is(
  (select (payload -> 'outcome' -> 'search_requests_opened')::integer
   from svar where label = 'kontrollimport1'),
  1,
  'kontrollen kan be om en ny motsøkerunde framfor å avgjøre uten grunnlag'
);
select is(
  (select count(*)::integer from workflow.monograph_coverage_controls cc
   join workflow.monograph_search_plans p on p.id = cc.plan_id
   where p.reference = (select value from refs where label = 'plan')),
  0,
  'og ingen dekningskontroll er registrert av en runde som bare ba om søk'
);

insert into refs (label, value)
select 'kontrollrunde2', r.reference
from workflow.monograph_search_requests r
join workflow.monograph_search_plans p on p.id = r.plan_id
where p.reference = (select value from refs where label = 'plan')
  and r.requested_for_role = 'source_quality_assessment'
  and r.search_round = 2;

set local role anon;
insert into svar (label, payload)
select 'motsok', api.record_monograph_machine_search(
  'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
  (select id from runs where label = 'kontroll'),
  (select value from refs where label = 'plan'),
  (select value from refs where label = 'kontrollrunde2'),
  'Crossref', '"sertralin" AND "depressiv lidelse"', 'rows=25',
  'https://api.crossref.org/works?query=x', 'sha256:' || repeat('d', 64),
  'executed', 4, 4, false, null, null,
  array[]::text[],
  jsonb_build_array(jsonb_build_object(
    'identifier_kind', 'doi',
    'identifier_value', '10.1000/870-oversett',
    'title', 'En kilde generatoren overså (prøve 870)',
    'discovery_path', 'Crossref, maskinelt motsøk')));
insert into svar (label, payload)
select 'lukk_kontroll2', api.close_monograph_search_request(
  'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
  (select id from runs where label = 'kontroll'),
  (select value from refs where label = 'kontrollrunde2'));
reset role;

select is(
  workflow.monograph_control_searched_independently(
    (select p.id from workflow.monograph_search_plans p
     where p.reference = (select value from refs where label = 'plan'))),
  true,
  'uavhengigheten er nå utledet av søkeloggen, og ikke erklært av svaret'
);

insert into jobs (label, id)
select 'kontrolljobb2', j.id from workflow.pipeline_jobs j
where j.agent_role = 'source_quality_assessment' and j.state = 'ready'
limit 1;

insert into svar (label, payload)
select 'kontrolloppgave2', workflow.agent_task(j) from workflow.pipeline_jobs j
where j.id = (select id from jobs where label = 'kontrolljobb2');

select ok(
  (select jsonb_array_length(payload -> 'input' -> 'control_task' -> 'own_countersearches') > 0
   from svar where label = 'kontrolloppgave2'),
  'kontrolloppgaven bærer kontrollens egne, maskinelt utførte motsøk'
);
select ok(
  (select jsonb_array_length(payload -> 'input' -> 'control_task' -> 'generator_searches') > 0
   from svar where label = 'kontrolloppgave2'),
  'og generatorens søk ved siden av, til sammenligning'
);

select set_config('request.jwt.claims',
                  '{"sub":"87000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'kontrollimport2', api.import_agent_answer(
  (select id from jobs where label = 'kontrolljobb2'),
  jsonb_build_object(
    'answer_version', 'antidep/agent-answer@2',
    'task_version', 'antidep/agent-task@1',
    'role', 'source_quality_assessment',
    'job_key', (select payload ->> 'job_key' from svar where label = 'kontrolloppgave2'),
    'request_digest', (select payload ->> 'request_digest' from svar where label = 'kontrolloppgave2'),
    'output_schema_version', 'antidep/source-coverage-control-draft@4',
    'result', jsonb_build_object(
      'candidate_appraisals', jsonb_build_array(jsonb_build_object(
        'identifier_kind', 'doi',
        'identifier_value', '10.1000/870-oversett',
        'could_change_conclusion', true,
        'materiality_reason', 'Generatoren så den ikke, og den rapporterer det samme utfallet.')),
      'control', jsonb_build_object(
        'outcome', 'insufficient',
        'note', 'Prøve i 870: motsøket fant en oversett kilde, så dekningen holder ikke.',
        'missed_candidates', 1,
        'exclusions_checked', 1,
        'materiality_assessed', true))));
reset role;

select is(
  (select (payload -> 'imported')::boolean from svar where label = 'kontrollimport2'),
  true,
  'kontrollsvaret ble importert'
);
select is(
  (select cc.searched_independently from workflow.monograph_coverage_controls cc
   join workflow.monograph_search_plans p on p.id = cc.plan_id
   where p.reference = (select value from refs where label = 'plan')),
  true,
  'og raden bærer at kontrollen faktisk søkte selv — utledet, ikke erklært'
);
select is(
  (select cc.outcome::text from workflow.monograph_coverage_controls cc
   join workflow.monograph_search_plans p on p.id = cc.plan_id
   where p.reference = (select value from refs where label = 'plan')),
  'insufficient',
  'kontrollen godtar ikke dekningen ennå'
);
select is(
  (select p.closed_at from workflow.monograph_search_plans p
   where p.reference = (select value from refs where label = 'plan')),
  null,
  'og planen står åpen'
);

select * from finish();

rollback;
