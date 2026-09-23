-- Migrasjon 014h — søkeleddene tar igjen sine egne overganger.
--
-- Etter 014g la kjedeovergangen inn en ny vurderingsoppgave når en runde
-- vokste — men bare når noe kjørte den. Lukkingen av en søkerunde gjorde det,
-- og ellers bare api.resume_chain_transitions(...), som kjøres av de
-- deterministiske kontrolleddene. I produksjon har de aldri kjørt. Filen prøver
-- de tre stedene der planen da ble stående uten en oppgave agenten kunne hente:
--
--   * en redaktør registrerer et søkespor for hånd, og grunnlaget vokser,
--   * en plan tas ut av pause etter at runden ble ferdig søkt under pausen, og
--   * en oppgave en kjøring holdt da runden vokste, løper ut,
--
-- og at søkeleddenes egen kjøring (api.resume_search_round_tasks) tar igjen det
-- som mangler for sitt eget ledd, uten duplikater, og bare med en kildeidentitet.
begin;

create extension if not exists pgtap with schema extensions;

select plan(38);

insert into auth.users (id, email)
values ('99100000-0000-4000-8000-00000000000a', 'redaktor-991@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac991000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-991',
   'Redaktør 991', 'Editor for prøven av søkeleddenes egne overganger i 991.',
   '99100000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('99100000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
   'ac991000-0000-4000-8000-00000000000a', 'Editor-tildeling for 991.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table refs (label text primary key, value text not null) on commit drop;
create temporary table runs (label text primary key, id uuid not null) on commit drop;
create temporary table cred (label text primary key, secret text not null) on commit drop;
create temporary table jobs (label text primary key, id uuid not null) on commit drop;
grant select, insert on svar to authenticated, anon;
grant select on refs, runs, cred to authenticated, anon;

select set_config('request.jwt.claims',
                  '{"sub":"99100000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 991.');
insert into svar (label, payload)
select 'modell_discovery', api.assign_agent_role_model(
  'source_discovery', 'prøve-991-a', 'Generatormodell 991', 'ikke-eksponert',
  'not_exposed', 'Prøve i 991.', 'Prøve i 991: generatorens modell.');
insert into svar (label, payload)
select 'modell_kontroll', api.assign_agent_role_model(
  'source_quality_assessment', 'prøve-991-b', 'Kontrollmodell 991', 'ikke-eksponert',
  'not_exposed', 'Prøve i 991.', 'Prøve i 991: kontrollens modell.');
insert into svar (label, payload)
select 'kjorer', api.register_agent_runner(
  'agent-runner:source-discovery', 'Antidep kildeoppdagelse',
  'source_discovery', 'Antidep Kildeoppdagelse (ChatGPT)', 'not_exposed',
  'Prøve 991: den planlagte kjøreren av kildeoppdagelsen.');
insert into svar (label, payload)
select 'pairing', api.issue_agent_runner_pairing_code('agent-runner:source-discovery');
reset role;

insert into svar (label, payload)
select 'pkce', jsonb_build_object(
  'verifier', 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
  'challenge', workflow.pkce_s256_challenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'));

insert into cred (label, secret)
select 'discovery', provenance.issue_agent_identity_credential(
  'agent-identity:source-discovery-01', 'human:redaktor-991');
insert into cred (label, secret)
select 'kontroll', provenance.issue_agent_identity_credential(
  'agent-identity:source-quality-assessment-01', 'human:redaktor-991');
insert into cred (label, secret)
select 'ekstraksjonskontroll', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:redaktor-991');

-- Tre planer. A har et forsøksregisterspor, slik at en redaktør kan føre det
-- for hånd når registeret mister veien. B og C er de to andre med færrest
-- maskinelle runder, slik at prøven er kort og lik fra gang til gang.
insert into refs (label, value)
select 'A', p.reference
from workflow.monograph_search_plans p
where p.closed_at is null and p.paused_at is null
  and exists (
    select 1 from workflow.monograph_search_track_attempts a
    join knowledge.monograph_search_tracks k on k.id = a.track_id
    where a.plan_id = p.id and k.code = 'trial_registries' and a.state = 'pending')
order by (select count(*) from workflow.monograph_search_requests r
          where r.plan_id = p.id and r.requested_for_role = 'source_discovery'),
         p.reference
limit 1;

insert into refs (label, value)
select v.label, x.reference
from (
  select p.reference,
         row_number() over (
           order by (select count(*) from workflow.monograph_search_requests r
                     where r.plan_id = p.id and r.requested_for_role = 'source_discovery'),
                    p.reference) as n
  from workflow.monograph_search_plans p
  where p.closed_at is null and p.paused_at is null
    and p.reference <> (select value from refs where label = 'A')
) x
join (values ('B', 1), ('C', 2)) as v(label, n) on v.n = x.n;

set local role anon;
insert into svar (label, payload)
select 'client', api.register_agent_runner_client(
  'Prøveklient 991', array['https://chatgpt.example/callback']);
insert into svar (label, payload)
select 'grant', api.authorize_agent_runner(
  (select payload ->> 'pairing_code' from svar where label = 'pairing'),
  (select payload ->> 'client_id' from svar where label = 'client'),
  'https://chatgpt.example/callback',
  (select payload ->> 'challenge' from svar where label = 'pkce'),
  'S256', 'https://antidep.example/mcp');
insert into svar (label, payload)
select 'tokens', api.exchange_agent_runner_code(
  (select payload ->> 'authorization_code' from svar where label = 'grant'),
  (select payload ->> 'verifier' from svar where label = 'pkce'),
  (select payload ->> 'client_id' from svar where label = 'client'),
  'https://chatgpt.example/callback', 'https://antidep.example/mcp');
reset role;

insert into runs (label, id)
select 'discovery', api.begin_agent_run(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  'source_discovery', 'antidep', 'search-execution-and-registration', '1.0.0',
  'source-discovery/machine-execution/2', 'antidep-evidence/1',
  jsonb_build_object('search_plan_reference', (select value from refs where label = 'A')));
insert into runs (label, id)
select 'kontroll', api.begin_agent_run(
  'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
  'source_quality_assessment', 'antidep', 'coverage-control-registration', '1.0.0',
  'source-coverage/machine-countersearch/1', 'antidep-evidence/1',
  jsonb_build_object('search_plan_reference', (select value from refs where label = 'C')));

create function pg_temp.plan_id(p_label text)
  returns uuid
  language sql
  stable
as $$
  select p.id from workflow.monograph_search_plans p
  where p.reference = (select value from refs where label = p_label);
$$;

create function pg_temp.active(p_label text, p_role provenance.agent_role default 'source_discovery')
  returns setof workflow.pipeline_jobs
  language sql
  stable
as $$
  select j.* from workflow.pipeline_jobs j
  where j.agent_role = p_role
    and j.input_manifest ->> 'search_plan_id' = pg_temp.plan_id(p_label)::text
    and j.state in ('ready', 'leased')
    and not workflow.pipeline_job_withdrawn(j.id);
$$;

-- Kjøreren lukker hver ventende runde planen står i. Ingen søk er registrert,
-- så hver av dem blir en registrert begrensning — som ikke holder porten.
create function pg_temp.close_round(
  p_label text,
  p_role provenance.agent_role default 'source_discovery'
)
  returns jsonb
  language plpgsql
as $$
declare
  v_ref text;
  v_last jsonb;
  v_guard integer := 0;
begin
  loop
    v_ref := null;
    select r.reference into v_ref
    from workflow.monograph_search_requests r
    join workflow.monograph_search_plans p on p.id = r.plan_id
    where p.id = pg_temp.plan_id(p_label)
      and r.plan_version = p.plan_version
      and r.requested_for_role = p_role
      and r.search_round = workflow.monograph_search_round(p.id, p_role)
      and r.state = 'pending'
    order by r.reference
    limit 1;
    exit when v_ref is null;

    v_last := case p_role
      when 'source_discovery' then api.close_monograph_search_request(
        'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
        (select id from runs where label = 'discovery'), v_ref)
      else api.close_monograph_search_request(
        'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
        (select id from runs where label = 'kontroll'), v_ref)
    end;

    v_guard := v_guard + 1;
    if v_guard > 100 then
      raise exception 'Runden ble aldri lukket.';
    end if;
  end loop;
  return v_last;
end;
$$;

create function pg_temp.basis(p_label text, p_role provenance.agent_role default 'source_discovery')
  returns jsonb
  language sql
  stable
as $$
  select workflow.monograph_search_basis(p.id, p.plan_version, p_role)
  from workflow.monograph_search_plans p where p.id = pg_temp.plan_id(p_label);
$$;

create function pg_temp.pending()
  returns jsonb
  language sql
as $$
  select api.list_pending_agent_tasks(
    (select payload ->> 'access_token' from svar where label = 'tokens'),
    'https://antidep.example/mcp');
$$;

-- Søkekjøringens eget kall, med leddets identitet.
create function pg_temp.catch_up(p_label text)
  returns jsonb
  language sql
as $$
  select case p_label
    when 'discovery' then api.resume_search_round_tasks(
      'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'))
    else api.resume_search_round_tasks(
      'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'))
  end;
$$;

-- ===========================================================================
-- Del 1 — Et spor en redaktør fører for hånd, gir den nye oppgaven med en gang
-- ===========================================================================
-- Registeret mister forsøksregisteret (i denne transaksjonen), og sporet står
-- uten en maskinell vei — det eneste en redaktør får føre for hånd.
delete from knowledge.monograph_search_platforms
where platform = 'ClinicalTrials.gov' and method = 'registry_search'
  and track_code = 'trial_registries';

select cmp_ok(
  workflow.mark_tracks_without_machine_path(pg_temp.plan_id('A')),
  '>', 0,
  'forsøksregistersporet på plan A står uten en maskinell vei'
);

insert into svar (label, payload) select 'A_runde1', pg_temp.close_round('A');
insert into jobs (label, id) select 'T1', id from pg_temp.active('A');

select is(
  (select (payload ->> 'enqueued_job')::boolean from svar where label = 'A_runde1'),
  true,
  'når runden er ferdig søkt, ligger vurderingsoppgaven klar'
);

select set_config('request.jwt.claims',
                  '{"sub":"99100000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'redaktor_spor', api.record_monograph_track_by_editor(
  (select value from refs where label = 'A'), 'trial_registries', 'covered',
  'Søkt manuelt i forsøksregisteret; søket ga ingen treff.',
  'ClinicalTrials.gov', '"sertraline"', null, now() - interval '1 hour', 0, 0, false, null);
reset role;

select is(
  (select jsonb_build_array(payload ->> 'state', (payload ->> 'search_recorded')::boolean,
                            (payload ->> 'tasks_enqueued')::integer)
   from svar where label = 'redaktor_spor'),
  jsonb_build_array('covered', true, 1),
  'redaktørens søk føres, og den nye vurderingsoppgaven legges inn i det samme kallet'
);

insert into jobs (label, id) select 'T2', id from pg_temp.active('A');

select is(
  (select jsonb_build_array(state::text, workflow.pipeline_job_withdrawn(id))
   from workflow.pipeline_jobs where id = (select id from jobs where label = 'T1')),
  jsonb_build_array('failed', true),
  'oppgaven for det mindre grunnlaget er trukket tilbake, og står som historikk'
);

select is(
  (select jsonb_build_array(count(*)::integer, bool_and(j.id <> (select id from jobs where label = 'T1')),
                            bool_and(j.input_manifest -> 'search_basis' = pg_temp.basis('A')))
   from pg_temp.active('A') j),
  jsonb_build_array(1, true, true),
  'regresjon: planen har nøyaktig én aktiv oppgave, og den gjelder grunnlaget med redaktørens søk'
);

select is(
  (select jsonb_build_array(jsonb_array_length(q -> 'tasks'), (q ->> 'blocked_count')::integer)
   from pg_temp.pending() q),
  jsonb_build_array(1, 0),
  'agenten ser den nye som kjørbar, og ingen som venter på et menneske'
);

select ok(
  exists (select 1 from workflow.monograph_search_requests r
          where r.plan_id = pg_temp.plan_id('A')
            and r.requested_for_role = 'source_quality_assessment'),
  'og dekningskontrollens motsøk er åpnet for planen, nå som den har et utført søk'
);

select is(workflow.monograph_search_task_invariant_problem(), null,
  'invarianten holder etter redaktørens spor');

-- ===========================================================================
-- Del 2 — En plan som tas ut av pause, får oppgaven for runden som ble søkt
-- ===========================================================================
set local role authenticated;
insert into svar (label, payload)
select 'pause_B', api.pause_monograph_search_plan(
  (select value from refs where label = 'B'), 'Prøve 991: planen settes på pause mens runden søkes.');
reset role;

insert into svar (label, payload) select 'B_runde1', pg_temp.close_round('B');

select is(
  (select (payload ->> 'enqueued_job')::boolean from svar where label = 'B_runde1'),
  false,
  'mens planen står på pause, legges ingen oppgave inn'
);
select is((select count(*)::integer from pg_temp.active('B')), 0,
  'og planen har ingen aktiv oppgave');

set local role authenticated;
insert into svar (label, payload)
select 'resume_B', api.resume_monograph_search_plan((select value from refs where label = 'B'));
reset role;

select is(
  (select jsonb_build_array((payload ->> 'resumed')::boolean, (payload ->> 'tasks_enqueued')::integer)
   from svar where label = 'resume_B'),
  jsonb_build_array(true, 1),
  'regresjon: når planen tas ut av pause, legges oppgaven for den ferdig søkte runden inn med det samme'
);
select is(
  (select jsonb_build_array(count(*)::integer,
                            bool_and(j.input_manifest -> 'search_basis' = pg_temp.basis('B')))
   from pg_temp.active('B') j),
  jsonb_build_array(1, true),
  'nøyaktig én, for rundens grunnlag'
);

set local role authenticated;
insert into svar (label, payload)
select 'resume_B2', api.resume_monograph_search_plan((select value from refs where label = 'B'));
reset role;

select is(
  (select (payload ->> 'tasks_enqueued')::integer from svar where label = 'resume_B2'),
  0,
  'og å ta den ut av pause én gang til legger ikke inn en til'
);

select is(workflow.monograph_search_task_invariant_problem(), null,
  'invarianten holder etter pausen');

-- ===========================================================================
-- Del 3 — En oppgave som ble erstattet mens den var tatt ut, tas igjen av
-- søkekjøringen
-- ===========================================================================
-- Kjøreren har én tilkobling, og oppgavens referanse er bundet til den.
insert into refs (label, value)
select 'T2_ref', workflow.agent_runner_task_ref(c.id, (select id from jobs where label = 'T2'))
from workflow.agent_runner_connections c;

set local role anon;
insert into svar (label, payload)
select 'uttak_A', api.claim_agent_task(
  (select payload ->> 'access_token' from svar where label = 'tokens'),
  'https://antidep.example/mcp',
  (select value from refs where label = 'T2_ref'));
reset role;

select is(
  (select state::text from workflow.pipeline_jobs where id = (select id from jobs where label = 'T2')),
  'leased',
  'agenten tar ut oppgaven for plan A'
);

-- Registeret legger et nytt søk inn i runden mens agenten holder oppgaven.
select isnt(
  (select workflow.open_monograph_search_request(
     p.id, 'source_discovery', p.discovery_round,
     'registry_opened', 'targeted',
     'Prøve 991: registeret har fått en ny søkevei for et spor i runden planen står i.',
     null, null, array[]::text[], array['sertraline registry 991'], array[]::text[], null, null,
     p.created_by_actor_id)
   from workflow.monograph_search_plans p where p.id = pg_temp.plan_id('A')),
  null,
  'runden vokser mens oppgaven er tatt ut'
);
insert into svar (label, payload) select 'A_vekst', pg_temp.close_round('A');

select is(
  (select (payload ->> 'enqueued_job')::boolean from svar where label = 'A_vekst'),
  false,
  'en gyldig leie på den forrige gir ingen ny oppgave ennå'
);

-- Leien løper ut. Ingen hendelse legger inn den nye.
update workflow.pipeline_jobs
set lease_expires_at = now() - interval '1 second'
where id = (select id from jobs where label = 'T2');

select is(
  (select jsonb_build_array(jsonb_array_length(q -> 'tasks'), (q ->> 'blocked_count')::integer)
   from pg_temp.pending() q),
  jsonb_build_array(1, 1),
  'uten en ny overgang ser agenten bare plan Bs oppgave, og plan As står som blokkert — slik produksjonen så ut'
);
select isnt(workflow.monograph_search_task_invariant_problem(), null,
  'og invarianten sier fra om runden uten oppgave');

insert into svar (label, payload) select 'feiing1', pg_temp.catch_up('discovery');
insert into jobs (label, id) select 'T3', id from pg_temp.active('A');

select is(
  (select jsonb_build_array(payload ->> 'agent_role', (payload ->> 'tasks_enqueued')::integer)
   from svar where label = 'feiing1'),
  jsonb_build_array('source_discovery', 1),
  'regresjon: søkekjøringen tar igjen kildeoppdagelsens ledd og legger inn én ny oppgave'
);
select is(
  (select jsonb_build_array(state::text, workflow.pipeline_job_withdrawn(id))
   from workflow.pipeline_jobs where id = (select id from jobs where label = 'T2')),
  jsonb_build_array('failed', true),
  'oppgaven med den utløpte leien er trukket tilbake'
);
select is(
  (select jsonb_build_array(count(*)::integer,
                            bool_and(j.input_manifest -> 'search_basis' = pg_temp.basis('A')))
   from pg_temp.active('A') j),
  jsonb_build_array(1, true),
  'og planen har én aktiv oppgave, for hele grunnlaget'
);
select is(
  (select jsonb_build_array(jsonb_array_length(q -> 'tasks'), (q ->> 'blocked_count')::integer)
   from pg_temp.pending() q),
  jsonb_build_array(2, 0),
  'agenten ser den nye for plan A og den for plan B, og ingen blokkert'
);

insert into svar (label, payload) select 'feiing2', pg_temp.catch_up('discovery');
select is(
  (select (payload ->> 'tasks_enqueued')::integer from svar where label = 'feiing2'),
  0,
  'feiingen kjørt om igjen legger ikke inn noe'
);
select is(workflow.monograph_search_task_invariant_problem(), null,
  'invarianten holder etter feiingen');

-- ===========================================================================
-- Del 4 — Dekningskontrollens ledd tar igjen sitt eget
-- ===========================================================================
-- Plan C har et utført søk og ingen motsøkerunde.
insert into workflow.monograph_searches
  (plan_id, plan_version, platform, search_method, query_string, executed_at,
   result_count, screened_count, outcome, execution_evidence, evidence_endpoint,
   response_digest, track_codes, recorded_by_actor_id)
select p.id, p.plan_version, 'Europe PMC', 'keyword', '"sertralin" 991', now(), 3, 3,
       'executed', 'machine_executed',
       'https://www.ebi.ac.uk/europepmc/webservices/rest/search',
       'sha256:' || repeat('d', 64),
       array['bibliographic_database'],
       'ac991000-0000-4000-8000-00000000000a'
from workflow.monograph_search_plans p where p.id = pg_temp.plan_id('C');

select is(
  (select count(*)::integer from workflow.monograph_search_requests r
   where r.plan_id = pg_temp.plan_id('C') and r.requested_for_role = 'source_quality_assessment'),
  0,
  'før feiingen har plan C ingen motsøkerunde'
);

insert into svar (label, payload) select 'kontrollfeiing', pg_temp.catch_up('kontroll');

select is(
  (select payload ->> 'agent_role' from svar where label = 'kontrollfeiing'),
  'source_quality_assessment',
  'dekningskontrollens identitet tar igjen dekningskontrollens ledd'
);
select cmp_ok(
  (select count(*)::integer from workflow.monograph_search_requests r
   where r.plan_id = pg_temp.plan_id('C') and r.requested_for_role = 'source_quality_assessment'
     and r.state = 'pending'),
  '>', 0,
  'regresjon: motsøkerunden åpnes av søkekjøringen selv, uten kontrolleddene'
);
select is((select count(*)::integer from pg_temp.active('C', 'source_quality_assessment')), 0,
  'kontrolloppgaven venter på at motsøkene er utført');

insert into svar (label, payload) select 'C_motsok', pg_temp.close_round('C', 'source_quality_assessment');
select is(
  (select (payload ->> 'enqueued_job')::boolean from svar where label = 'C_motsok'),
  true,
  'når motsøkene er utført, legges kontrolloppgaven inn'
);
select is(
  (select (pg_temp.catch_up('kontroll') ->> 'tasks_enqueued')::integer),
  0,
  'og feiingen legger ikke inn en til'
);

-- ===========================================================================
-- Del 5 — Bare kildeleddene, og kontrolleddenes feiing er den samme
-- ===========================================================================
select throws_ok(
  format($$select api.resume_search_round_tasks('agent-identity:extraction-verification-01', %L)$$,
         (select secret from cred where label = 'ekstraksjonskontroll')),
  '42501',
  null,
  'en identitet utenfor kildeleddene får ikke kjøre feiingen'
);
select throws_ok(
  $$select api.resume_search_round_tasks('agent-identity:source-discovery-01', 'feil-hemmelighet')$$,
  '42501',
  null,
  'og ikke uten riktig legitimasjon'
);
select ok(
  has_function_privilege('anon', 'api.resume_search_round_tasks(text, text)', 'execute')
  and not has_function_privilege('anon', 'workflow.resume_search_round_tasks(provenance.agent_role)', 'execute')
  and not has_function_privilege('authenticated', 'workflow.chain_search_plan_tasks(uuid)', 'execute'),
  'agentveien er åpen for kjøreren, og arbeidsfunksjonene bak den er det ikke'
);

insert into svar (label, payload)
select 'resume', api.resume_chain_transitions(
  'agent-identity:extraction-verification-01', (select secret from cred where label = 'ekstraksjonskontroll'));

select is(
  (select (payload ->> 'search_tasks')::integer from svar where label = 'resume'),
  0,
  'kontrolleddenes rekonsiliering finner ingenting søkeleddene ikke alt har tatt igjen'
);
select is(
  (select array_agg(c.step order by c.step) from workflow.chain_reconciliation_cursors c
   where c.step in ('kildeoppdagelse', 'dekningskontroll') and c.sweeps_completed > 0),
  array['dekningskontroll', 'kildeoppdagelse'],
  'begge kildeleddene føres på sin egen markør, den samme for begge kjøringene'
);
select is(
  (select count(*)::integer from workflow.technical_incidents ti
   where ti.signature in ('kjede:kildeoppdagelse', 'kjede:dekningskontroll')
     and ti.resolved_at is null),
  0,
  'og ingen av dem har et åpent teknisk problem'
);

select is(workflow.monograph_search_task_invariant_problem(), null,
  'invarianten holder til slutt');

select * from finish();
rollback;
