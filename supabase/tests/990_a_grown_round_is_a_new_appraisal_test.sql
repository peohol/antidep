-- Migrasjon 014g — en runde som vokser, er en ny vurdering.
--
-- Produksjonsfeilen etter PR #120: registeret åpnet nye maskinelle søk i den
-- runden planene sto i, etter at rundens vurderingsoppgave var lagt inn.
-- Oppgaven hadde det samme manifestet før og etter, og en fullført, feilet
-- eller oppbrukt oppgave stoppet dermed hver ny oppgave for det utvidede
-- grunnlaget — for alltid. Køen talte samtidig foreldet historikk som noe som
-- ventet på et menneske. Filen prøver invarianten slik en kjører møter den:
--
--   * en foreldet eller feilet oppgave hindrer aldri en ny, når runden faktisk
--     krever nytt arbeid, og den nye kan hentes av agenten,
--   * en ledig eller tatt oppgave for det samme grunnlaget gir ingen duplikat,
--   * en fullført oppgave for nøyaktig det samme grunnlaget kjøres ikke om,
--   * en tilbaketrukket oppgave er historikk: den står med sporet sitt, men
--     den er ikke ventende arbeid, ikke blokkert og ikke et teknisk problem,
--   * en plan på pause eller en lukket plan får ingen oppgave, og
--   * dekningskontrollen følger den samme regelen.
--
-- Kappløpet mellom to samtidige overganger prøves i
-- scripts/db-chain-race-test.sh, og oppgraderingen av eksisterende data i
-- scripts/db-upgrade-grown-round.sh.
begin;

create extension if not exists pgtap with schema extensions;

select plan(53);

insert into auth.users (id, email)
values ('99000000-0000-4000-8000-00000000000a', 'redaktor-990@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac990000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-990',
   'Redaktør 990', 'Editor for prøven av runder som vokser i 990.',
   '99000000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('99000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
   'ac990000-0000-4000-8000-00000000000a', 'Editor-tildeling for 990.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table refs (label text primary key, value text not null) on commit drop;
create temporary table runs (label text primary key, id uuid not null) on commit drop;
create temporary table cred (label text primary key, secret text not null) on commit drop;
create temporary table jobs (label text primary key, id uuid not null) on commit drop;
grant select, insert on svar to authenticated, anon;
grant select on refs, runs, cred to authenticated, anon;

select set_config('request.jwt.claims',
                  '{"sub":"99000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 990.');
insert into svar (label, payload)
select 'modell_discovery', api.assign_agent_role_model(
  'source_discovery', 'prøve-990-a', 'Generatormodell 990', 'ikke-eksponert',
  'not_exposed', 'Prøve i 990.', 'Prøve i 990: generatorens modell.');
insert into svar (label, payload)
select 'modell_kontroll', api.assign_agent_role_model(
  'source_quality_assessment', 'prøve-990-b', 'Kontrollmodell 990', 'ikke-eksponert',
  'not_exposed', 'Prøve i 990.', 'Prøve i 990: kontrollens modell.');
insert into svar (label, payload)
select 'kjorer', api.register_agent_runner(
  'agent-runner:source-discovery', 'Antidep kildeoppdagelse',
  'source_discovery', 'Antidep Kildeoppdagelse (ChatGPT)', 'not_exposed',
  'Prøve 990: den planlagte kjøreren av kildeoppdagelsen.');
insert into svar (label, payload)
select 'pairing', api.issue_agent_runner_pairing_code('agent-runner:source-discovery');
reset role;

-- PKCE-utfordringen regnes ut før rollen byttes (som i 790).
insert into svar (label, payload)
select 'pkce', jsonb_build_object(
  'verifier', 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
  'challenge', workflow.pkce_s256_challenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'));

insert into cred (label, secret)
select 'discovery', provenance.issue_agent_identity_credential(
  'agent-identity:source-discovery-01', 'human:redaktor-990');
insert into cred (label, secret)
select 'kontroll', provenance.issue_agent_identity_credential(
  'agent-identity:source-quality-assessment-01', 'human:redaktor-990');

-- To planer: de to med færrest maskinelle runder, slik at prøven er kort og
-- lik fra gang til gang.
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
) x
join (values ('A', 1), ('B', 2)) as v(label, n) on v.n = x.n;

-- Den autonome kjøreren kobler seg til, som i 790.
set local role anon;
insert into svar (label, payload)
select 'client', api.register_agent_runner_client(
  'Prøveklient 990', array['https://chatgpt.example/callback']);
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
  jsonb_build_object('search_plan_reference', (select value from refs where label = 'A')));

create function pg_temp.plan_id(p_label text)
  returns uuid
  language sql
  stable
as $$
  select p.id from workflow.monograph_search_plans p
  where p.reference = (select value from refs where label = p_label);
$$;

-- Planens kildeoppgaver i leddet som fortsatt er aktive: ledige eller tatt ut,
-- og ikke trukket tilbake.
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

-- Kjøreren lukker hver ventende runde planen står i, slik
-- api.monograph_discovery_work(...) gir dem. Ingen søk er registrert, så hver
-- av dem blir en registrert begrensning (unavailable) — som ikke holder porten.
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

-- Registeret får en ny søkevei i runden planen står i. Det er nøyaktig det
-- `workflow.mark_tracks_without_machine_path(...)` gjør med `registry_opened`.
create function pg_temp.grow(p_label text, p_term text)
  returns uuid
  language sql
as $$
  select workflow.open_monograph_search_request(
    p.id, 'source_discovery', p.discovery_round,
    'registry_opened', 'targeted',
    'Prøve 990: registeret har fått en ny søkevei for et spor i runden planen står i.',
    null, null, array[]::text[], array[p_term], array[]::text[], null, null,
    p.created_by_actor_id)
  from workflow.monograph_search_plans p where p.id = pg_temp.plan_id(p_label);
$$;

-- Søkegrunnlaget leddet har på planen nå.
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

create function pg_temp.open_incident(p_job uuid)
  returns boolean
  language sql
  stable
as $$
  select exists (
    select 1 from workflow.technical_incidents ti
    where ti.area = 'automatic_task'
      and ti.signature = 'pipeline-job:' || p_job::text
      and ti.resolved_at is null);
$$;

-- ===========================================================================
-- Del 1 — En foreldet oppgave hindrer ikke den nye
-- ===========================================================================
-- Nøyaktig det 013v etterlot i produksjon: en oppgave bygget under den forrige
-- kildekontrakten, uten runde, gått til failed med en foreldelsesgrunn — og
-- med det tekniske problemet overgangen åpnet.
insert into workflow.pipeline_jobs (agent_role, job_key, input_manifest, enqueued_by_actor_id)
select 'source_discovery',
       workflow.agent_task_job_key('source_discovery',
         jsonb_build_object('search_plan_id', p.id, 'plan_version', p.plan_version)),
       jsonb_build_object('search_plan_id', p.id, 'plan_version', p.plan_version),
       'ac990000-0000-4000-8000-00000000000a'
from workflow.monograph_search_plans p where p.id = pg_temp.plan_id('A');
insert into jobs (label, id)
select 'foreldet', j.id from workflow.pipeline_jobs j
where j.agent_role = 'source_discovery'
  and j.input_manifest = jsonb_build_object(
        'search_plan_id', pg_temp.plan_id('A'),
        'plan_version', (select plan_version from workflow.monograph_search_plans
                         where id = pg_temp.plan_id('A')));
insert into workflow.agent_handoff_jobs (pipeline_job_id, registered_by_actor_id)
select id, 'ac990000-0000-4000-8000-00000000000a' from jobs where label = 'foreldet';
update workflow.pipeline_jobs
set state = 'failed', completed_at = now(),
    failure_reason = 'Foreldet av migrasjon 013v: oppgaven ble bygget under den forrige kildekontrakten.'
where id = (select id from jobs where label = 'foreldet');

select ok(
  pg_temp.open_incident((select id from jobs where label = 'foreldet')),
  'den foreldede oppgaven står med et åpent teknisk problem, slik 013v etterlot den'
);

select is(
  (select count(*)::integer from pg_temp.active('A')),
  0,
  'mens runden søkes, finnes ingen vurderingsoppgave'
);

insert into svar (label, payload) select 'A_runde1', pg_temp.close_round('A');

select is(
  (select (payload ->> 'enqueued_job')::boolean from svar where label = 'A_runde1'),
  true,
  'når den siste runden er lukket, legges vurderingsoppgaven inn — den foreldede står ikke i veien'
);

insert into jobs (label, id) select 'T1', id from pg_temp.active('A');

select is(
  (select jsonb_build_array(j.input_manifest ->> 'discovery_round', j.input_manifest -> 'search_basis')
   from workflow.pipeline_jobs j where j.id = (select id from jobs where label = 'T1')),
  jsonb_build_array('1', pg_temp.basis('A')),
  'oppgaven bærer runden og søkegrunnlaget sitt: søkene som er bedt om, og søkene som gikk'
);

select is(
  (select jsonb_build_array(j.state::text, j.failure_reason like 'Foreldet av migrasjon 013v:%',
                            workflow.pipeline_job_withdrawn(j.id))
   from workflow.pipeline_jobs j where j.id = (select id from jobs where label = 'foreldet')),
  jsonb_build_array('failed', true, true),
  'den foreldede er trukket tilbake, men står som historikk med tilstanden og begrunnelsen sin'
);

select ok(
  not pg_temp.open_incident((select id from jobs where label = 'foreldet')),
  'og det tekniske problemet om den er lukket: den ga aldri opp, den ble trukket tilbake'
);

select is(
  (select count(*)::integer from workflow.pipeline_job_events e
   where e.pipeline_job_id = (select id from jobs where label = 'foreldet')),
  0,
  'tilbaketrekkingen av en feilet oppgave skriver ingen ny overgang: sporet er det det var'
);

-- Og agenten ser den, og kan hente den.
insert into svar (label, payload) select 'kø1', pg_temp.pending();

select is(
  (select jsonb_build_array(jsonb_array_length(payload -> 'tasks'), (payload ->> 'blocked_count')::integer)
   from svar where label = 'kø1'),
  jsonb_build_array(1, 0),
  'kjøreren ser én kjørbar oppgave, og ingen som venter på et menneske'
);

set local role anon;
insert into svar (label, payload)
select 'uttak1', api.claim_agent_task(
  (select payload ->> 'access_token' from svar where label = 'tokens'),
  'https://antidep.example/mcp',
  (select payload -> 'tasks' -> 0 ->> 'task_ref' from svar where label = 'kø1'));
insert into svar (label, payload)
select 'hent1', api.agent_task_for_runner(
  (select payload ->> 'access_token' from svar where label = 'tokens'),
  'https://antidep.example/mcp',
  (select (payload ->> 'task_handle')::uuid from svar where label = 'uttak1'));
reset role;

select is(
  (select (payload ->> 'claimed')::boolean from svar where label = 'uttak1'),
  true,
  'agenten tar oppgaven ut'
);
select is(
  (select state::text from workflow.pipeline_jobs where id = (select id from jobs where label = 'T1')),
  'leased',
  'og det er den nye oppgaven den tok'
);
select isnt(
  (select payload -> 'task' from svar where label = 'hent1'),
  null,
  'og henter hele oppgaven under leien sin'
);

-- ===========================================================================
-- Del 2 — En gyldig leie gir ingen duplikat
-- ===========================================================================
select is(
  workflow.chain_task_for_search_plan(pg_temp.plan_id('A')),
  null,
  'overgangen kjørt om igjen legger ikke inn noe'
);

-- Registeret åpner et nytt søk i runden mens agenten arbeider.
select isnt(pg_temp.grow('A', 'sertraline registry one'), null, 'registeret åpner et nytt søk i runden');
insert into svar (label, payload) select 'A_vekst1', pg_temp.close_round('A');

select is(
  (select (payload ->> 'enqueued_job')::boolean from svar where label = 'A_vekst1'),
  false,
  'runden er ferdig søkt igjen, men agenten holder rundens oppgave: ingen ny legges inn'
);
select is(
  (select array_agg(id) from pg_temp.active('A')),
  array[(select id from jobs where label = 'T1')],
  'den tatte oppgaven står, og den er den eneste aktive'
);

-- Svaret agenten er i ferd med å gi, gjelder et mindre grunnlag enn det som nå
-- ligger der. Holderen avvises av grunnlaget og ikke av sin egen leie.
select is(
  (select workflow.agent_task_problem(j, j.lease_token)
   from workflow.pipeline_jobs j where j.id = (select id from jobs where label = 'T1')),
  'Søkegrunnlaget har vokst siden oppgaven ble lagt inn: det er kommet maskinelle søk eller resultater oppgaven ikke gjaldt. Vurderingen hører til en ny oppgave for hele grunnlaget, som legges inn når søkene er utført.',
  'et svar på det gamle grunnlaget kan ikke registreres som rundens vurdering'
);

-- Kjøreren gir oppgaven fra seg. Da er den ikke lenger holdt, og overgangen
-- erstatter den.
set local role anon;
insert into svar (label, payload)
select 'frigitt1', api.release_agent_task(
  (select payload ->> 'access_token' from svar where label = 'tokens'),
  'https://antidep.example/mcp',
  (select (payload ->> 'task_handle')::uuid from svar where label = 'uttak1'),
  'blocked_by_task');
reset role;

select isnt(
  workflow.chain_task_for_search_plan(pg_temp.plan_id('A')),
  null,
  'når leien er gitt fra seg, legger overgangen inn oppgaven for det utvidede grunnlaget'
);

insert into jobs (label, id) select 'T2', id from pg_temp.active('A');

select is(
  (select jsonb_build_array(j.input_manifest -> 'search_basis', j.state::text)
   from workflow.pipeline_jobs j where j.id = (select id from jobs where label = 'T2')),
  jsonb_build_array(pg_temp.basis('A'), 'ready'),
  'den nye oppgaven gjelder hele runden'
);
select is(
  (select jsonb_build_array(j.state::text, workflow.pipeline_job_withdrawn(j.id),
                            pg_temp.open_incident(j.id))
   from workflow.pipeline_jobs j where j.id = (select id from jobs where label = 'T1')),
  jsonb_build_array('failed', true, false),
  'og den forrige er trukket tilbake, uten et teknisk problem'
);

-- ===========================================================================
-- Del 3 — En ledig oppgave gir ingen duplikat
-- ===========================================================================
select is(
  workflow.chain_task_for_search_plan(pg_temp.plan_id('A')),
  null,
  'en ledig oppgave for det samme grunnlaget: overgangen legger ikke inn noe'
);
select is(
  (select count(*)::integer from pg_temp.active('A')),
  1,
  'fortsatt nøyaktig én aktiv oppgave for runden'
);

-- Vokser runden mens oppgaven er ledig, trekkes den tilbake med det samme: den
-- gjelder et grunnlag som ikke finnes lenger, og den venter ikke på noen.
select isnt(pg_temp.grow('A', 'sertraline registry two'), null, 'registeret åpner enda et søk i runden');
select is(
  workflow.chain_task_for_search_plan(pg_temp.plan_id('A')),
  null,
  'mens det nye søket står uutført, legges ingen oppgave inn'
);
select is(
  (select jsonb_build_array(j.state::text, workflow.pipeline_job_withdrawn(j.id))
   from workflow.pipeline_jobs j where j.id = (select id from jobs where label = 'T2')),
  jsonb_build_array('failed', true),
  'men den ledige oppgaven om det mindre grunnlaget er trukket tilbake'
);
select is(
  (select jsonb_build_array(jsonb_array_length(q -> 'tasks'), (q ->> 'blocked_count')::integer)
   from pg_temp.pending() q),
  jsonb_build_array(0, 0),
  'køen er tom og sier ikke at noe venter på et menneske: det er maskinen som søker'
);

insert into svar (label, payload) select 'A_vekst2', pg_temp.close_round('A');
insert into jobs (label, id) select 'T3', id from pg_temp.active('A');

select is(
  (select (payload ->> 'enqueued_job')::boolean from svar where label = 'A_vekst2'),
  true,
  'når søket er utført, legges oppgaven for hele runden inn'
);

-- ===========================================================================
-- Del 4 — En oppbrukt oppgave venter på et menneske, til runden vokser
-- ===========================================================================
-- Tilstanden settes direkte, slik kjøreren setter den etter siste forsøk:
-- det er overgangens lesning av den som prøves her.
update workflow.pipeline_jobs
set state = 'failed', attempts = max_attempts, completed_at = now(),
    failure_reason = 'Kjøreren fikk ikke fullført arbeidet.'
where id = (select id from jobs where label = 'T3');

select is(
  workflow.chain_task_for_search_plan(pg_temp.plan_id('A')),
  null,
  'en oppbrukt oppgave for det samme grunnlaget kjøres ikke om igjen av seg selv'
);
select is(
  (select jsonb_build_array(workflow.pipeline_job_withdrawn(id), pg_temp.open_incident(id),
                            (select (q ->> 'blocked_count')::integer from pg_temp.pending() q))
   from workflow.pipeline_jobs where id = (select id from jobs where label = 'T3')),
  jsonb_build_array(false, true, 1),
  'den står som et teknisk problem, og køen sier at den venter på et menneske'
);
select is(
  (select count(*)::integer from jsonb_array_elements(api.public_work_board()) e
   where e ->> 'status' = 'failed'),
  1,
  'og den åpne oversikten viser den ene feilen — ikke oppgavene som er trukket tilbake'
);

select isnt(pg_temp.grow('A', 'sertraline registry three'), null, 'runden vokser igjen');
insert into svar (label, payload) select 'A_vekst3', pg_temp.close_round('A');
insert into jobs (label, id) select 'T4', id from pg_temp.active('A');

select is(
  (select (payload ->> 'enqueued_job')::boolean from svar where label = 'A_vekst3'),
  true,
  'regresjon: en feilet oppgave hindrer ikke den nye når runden krever nytt arbeid'
);
select is(
  (select jsonb_build_array(workflow.pipeline_job_withdrawn(id), pg_temp.open_incident(id))
   from workflow.pipeline_jobs where id = (select id from jobs where label = 'T3')),
  jsonb_build_array(true, false),
  'den oppbrukte er trukket tilbake, og problemet om den er lukket'
);

-- ===========================================================================
-- Del 5 — En fullført oppgave for det samme grunnlaget kjøres ikke om
-- ===========================================================================
update workflow.pipeline_jobs
set state = 'succeeded', attempts = 1, completed_at = now(),
    leased_by_agent_identity_id = (select ai.id from provenance.agent_identities ai
                                   where ai.identity_key = 'agent-identity:source-discovery-01'),
    lease_token = gen_random_uuid(), lease_expires_at = now() + interval '15 minutes',
    agent_run_id = (select id from runs where label = 'discovery'),
    output_manifest = '{}'::jsonb
where id = (select id from jobs where label = 'T4');

select is(
  workflow.chain_task_for_search_plan(pg_temp.plan_id('A')),
  null,
  'en fullført vurdering av nøyaktig dette grunnlaget kjøres ikke om igjen'
);

select isnt(pg_temp.grow('A', 'sertraline registry four'), null, 'runden vokser etter at vurderingen er fullført');
insert into svar (label, payload) select 'A_vekst4', pg_temp.close_round('A');
insert into jobs (label, id) select 'T5', id from pg_temp.active('A');

select is(
  (select (payload ->> 'enqueued_job')::boolean from svar where label = 'A_vekst4'),
  true,
  'regresjon: en fullført oppgave hindrer ikke vurderingen av søkene som kom etter'
);
select is(
  (select jsonb_build_array(state::text, workflow.pipeline_job_withdrawn(id))
   from workflow.pipeline_jobs where id = (select id from jobs where label = 'T4')),
  jsonb_build_array('succeeded', false),
  'den fullførte står som den er: utført arbeid trekkes aldri tilbake'
);
select is(
  (select jsonb_build_array(jsonb_array_length(q -> 'tasks'), (q ->> 'blocked_count')::integer)
   from pg_temp.pending() q),
  jsonb_build_array(1, 0),
  'og kjøreren ser nøyaktig den nye'
);

-- ===========================================================================
-- Del 6 — Et søk som svarer på et senere forsøk
-- ===========================================================================
-- Registeret åpner en runde som ingen vei svarer på første gang. Den er en
-- registrert begrensning, og holder ikke porten: oppgaven legges inn.
select isnt(pg_temp.grow('A', 'sertraline later answer'), null, 'registeret åpner et søk som ikke svarer første gang');
insert into refs (label, value)
select 'A_sen', r.reference
from workflow.monograph_search_requests r
where r.plan_id = pg_temp.plan_id('A') and r.state = 'pending';
insert into svar (label, payload) select 'A_vekst5', pg_temp.close_round('A');
insert into jobs (label, id) select 'T6', id from pg_temp.active('A');

select is(
  (select jsonb_build_array(r.state::text, (s.payload ->> 'enqueued_job')::boolean)
   from workflow.monograph_search_requests r, svar s
   where r.reference = (select value from refs where label = 'A_sen') and s.label = 'A_vekst5'),
  jsonb_build_array('unavailable', true),
  'en runde ingen vei svarte på, holder ikke vurderingen tilbake'
);

-- Kjøreren prøver igjen, og nå svarer søkeveien — med en kilde ingen har
-- vurdert. Den kilden ville ellers stått uten en beslutning for alltid, og
-- søkedekningen kunne aldri blitt erklært ferdig.
select lives_ok(
  format($$
    select api.record_monograph_machine_search(
      'agent-identity:source-discovery-01', %L, %L, %L, %L,
      'Europe PMC', '"sertraline"', 'pageSize=100',
      'https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=sertraline',
      'sha256:' || repeat('9', 64), 'executed', 1, 1, false, null, null,
      array[]::text[],
      jsonb_build_array(jsonb_build_object(
        'identifier_kind', 'doi', 'identifier_value', '10.1000/990-sen',
        'title', 'Kilde fra et senere forsøk (prøve 990)')),
      'keyword')
  $$,
  (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'A'),
  (select value from refs where label = 'A_sen')),
  'søket svarer på det neste forsøket'
);
select is(
  (select workflow.agent_task_problem(j) from workflow.pipeline_jobs j
   where j.id = (select id from jobs where label = 'T6')),
  'Søkegrunnlaget har vokst siden oppgaven ble lagt inn: det er kommet maskinelle søk eller resultater oppgaven ikke gjaldt. Vurderingen hører til en ny oppgave for hele grunnlaget, som legges inn når søkene er utført.',
  'oppgaven som ble lagt inn før svaret, gjelder ikke lenger hele grunnlaget'
);

insert into svar (label, payload)
select 'A_sent_svar', api.close_monograph_search_request(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'), (select value from refs where label = 'A_sen'));
insert into jobs (label, id) select 'T7', id from pg_temp.active('A');

select is(
  (select jsonb_build_array(payload ->> 'state', (payload ->> 'enqueued_job')::boolean)
   from svar where label = 'A_sent_svar'),
  jsonb_build_array('fulfilled', true),
  'regresjon: et svar på et senere forsøk gir en ny vurdering av hele grunnlaget'
);
select is(
  (select jsonb_build_array(workflow.pipeline_job_withdrawn(t6.id), t7.input_manifest -> 'search_basis')
   from workflow.pipeline_jobs t6, workflow.pipeline_jobs t7
   where t6.id = (select id from jobs where label = 'T6')
     and t7.id = (select id from jobs where label = 'T7')),
  jsonb_build_array(true, pg_temp.basis('A')),
  'den forrige er trukket tilbake, og den nye bærer grunnlaget med svaret'
);

-- ===========================================================================
-- Del 7 — Pause og lukking
-- ===========================================================================
update workflow.monograph_search_plans
set paused_at = now(), paused_reason = 'Prøve 990: planen står på pause.'
where id = pg_temp.plan_id('B');

select is(
  workflow.chain_task_for_search_plan(pg_temp.plan_id('B')),
  null,
  'en plan på pause får ingen oppgave'
);

update workflow.monograph_search_plans
set paused_at = null, paused_reason = null
where id = pg_temp.plan_id('B');
insert into svar (label, payload) select 'B_runde1', pg_temp.close_round('B');

select is(
  (select count(*)::integer from pg_temp.active('B')),
  1,
  'tatt av pause og ferdig søkt: nøyaktig én oppgave'
);

update workflow.monograph_search_plans
set closed_at = now(), closed_note = 'Prøve 990: søkedekningen erklært ferdig.',
    closed_by_actor_id = 'ac990000-0000-4000-8000-00000000000a'
where id = pg_temp.plan_id('B');

select is(
  workflow.chain_task_for_search_plan(pg_temp.plan_id('B')),
  null,
  'en lukket plan får ingen oppgave'
);
select is(
  workflow.withdraw_superseded_search_tasks(
    pg_temp.plan_id('B'), 'source_discovery', 'ac990000-0000-4000-8000-00000000000a'),
  1,
  'og oppgaven den hadde, trekkes tilbake: planen har ikke noe arbeid igjen'
);

-- ===========================================================================
-- Del 8 — Dekningskontrollen følger den samme regelen
-- ===========================================================================
-- Kontrollen kontrollerer et utført søk, og plan A har nå ett (del 6).
select is(
  workflow.chain_task_for_search_coverage(pg_temp.plan_id('A')),
  null,
  'kontrollens motsøk åpnes, og oppgaven venter på dem'
);
insert into svar (label, payload) select 'A_kontroll', pg_temp.close_round('A', 'source_quality_assessment');

select is(
  (select jsonb_agg(j.input_manifest -> 'search_basis')
   from pg_temp.active('A', 'source_quality_assessment') j),
  jsonb_build_array(pg_temp.basis('A', 'source_quality_assessment')),
  'kontrolloppgaven legges inn én gang, med sitt eget søkegrunnlag'
);
select is(
  workflow.chain_task_for_search_coverage(pg_temp.plan_id('A')),
  null,
  'og overgangen kjørt om igjen legger ikke inn en til'
);

-- ===========================================================================
-- Del 9 — Invariantene, lest av databasen
-- ===========================================================================
select is_empty(
  $$
    select j.agent_role, j.input_manifest ->> 'search_plan_id',
           j.input_manifest ->> workflow.monograph_round_manifest_key(j.agent_role)
    from workflow.pipeline_jobs j
    where j.agent_role in ('source_discovery', 'source_quality_assessment')
      and j.state in ('ready', 'leased')
      and not workflow.pipeline_job_withdrawn(j.id)
    group by 1, 2, 3
    having count(*) > 1
  $$,
  'aldri to aktive oppgaver om den samme runden'
);
select is_empty(
  $$
    select j.id from workflow.pipeline_jobs j
    where workflow.pipeline_job_withdrawn(j.id)
      and (j.state in ('ready', 'leased', 'succeeded')
           or workflow.agent_task_problem(j) is null)
  $$,
  'en tilbaketrukket oppgave er avsluttet og kan ikke tas ut'
);
select throws_ok(
  $$ update workflow.pipeline_job_withdrawals set reason = 'Endret.' $$,
  '23001',
  null,
  'en tilbaketrekking kan ikke skrives om'
);

select * from finish();
rollback;
