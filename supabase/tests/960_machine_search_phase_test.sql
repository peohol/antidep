-- Migrasjon 013v — den maskinelle søkefasen som en rad, og grensene den bærer.
--
-- 870 prøver forløpet. Denne filen prøver selve bestillingen: hva en
-- søkeforespørsel kan be om, hva den ikke kan be om, og hva som skjer når
-- budsjettet er brukt opp.
--
--   * tabellen er lukket som de øvrige workflow-tabellene,
--   * en forespørsel kan ikke navngi en tjeneste Antidep ikke kaller,
--   * termene har en form, fordi de havner i en søkestreng,
--   * dekningskontrollens motsøk kan ikke bære et obligatorisk søkespor,
--   * bestillingen er uforanderlig i det den bestiller,
--   * en avsluttet runde kan ikke gjenåpnes, og
--   * et oppbrukt søkebudsjett setter planen på pause som åpent, ventende
--     arbeid — aldri som en konklusjon om evidensen (SOURCE_POLICY.md §8.2).
--
-- SQLSTATE 22023 = invalid_parameter_value, 23001 = restrict_violation,
-- 23514 = check_violation, 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(23);

insert into auth.users (id, email)
values ('96000000-0000-4000-8000-00000000000a', 'redaktor-960@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac960000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-960',
   'Redaktør 960', 'Editor for prøven av den maskinelle søkefasen i 960.',
   '96000000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('96000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
   'ac960000-0000-4000-8000-00000000000a', 'Editor-tildeling for 960.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table plans (label text primary key, id uuid not null) on commit drop;
grant select, insert on svar to authenticated, anon;
grant select on plans to authenticated, anon;

select set_config('request.jwt.claims',
                  '{"sub":"96000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 960.');
insert into svar (label, payload)
select 'modell_discovery', api.assign_agent_role_model(
  'source_discovery', 'prøve-960-a', 'Generatormodell 960', 'ikke-eksponert',
  'not_exposed', 'Prøve i 960.', 'Prøve i 960.');
insert into svar (label, payload)
select 'modell_kontroll', api.assign_agent_role_model(
  'source_quality_assessment', 'prøve-960-b', 'Kontrollmodell 960', 'ikke-eksponert',
  'not_exposed', 'Prøve i 960.', 'Prøve i 960.');
reset role;

insert into plans (label, id)
select 'eff', p.id
from workflow.monograph_search_plans p
join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
where sp.code = 'EFF'
order by p.created_at
limit 1;

-- ===========================================================================
-- Del 1 — Tabellen er lukket, som de øvrige workflow-tabellene
-- ===========================================================================
select has_table('workflow', 'monograph_search_requests',
  'workflow.monograph_search_requests finnes');
select ok(
  (select c.relrowsecurity from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'workflow' and c.relname = 'monograph_search_requests'),
  'og den har row level security aktivert'
);
select is_empty(
  $$
    select r.role_name, p.privilege_type
    from (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege_type)
    where has_table_privilege(r.role_name, 'workflow.monograph_search_requests', p.privilege_type)
  $$,
  'ingen klientrolle har en rettighet på tabellen: veien inn går gjennom api-funksjonene'
);

-- ===========================================================================
-- Del 2 — Hva en bestilling kan be om
-- ===========================================================================
-- En tjeneste ingen har vurdert, finnes ikke å be om. Uten denne grensen ville
-- en forespørsel vært en proxy (ANTIDEP_CONSTITUTION.md regel 7).
select throws_ok(
  format($$
    insert into workflow.monograph_search_requests
      (plan_id, plan_version, requested_for_role, search_round, origin, strategy,
       rationale, platform, requested_by_actor_id)
    values (%L, 1, 'source_discovery', 2, 'agent_requested', 'targeted',
            'Prøve i 960.', 'Et internt arkiv', 'ac960000-0000-4000-8000-00000000000a')
  $$, (select id from plans where label = 'eff')),
  '23514',
  null,
  'en søkeforespørsel kan ikke navngi en tjeneste Antidep ikke kaller'
);

select throws_ok(
  format($$
    insert into workflow.monograph_search_requests
      (plan_id, plan_version, requested_for_role, search_round, origin, strategy,
       rationale, query_terms, requested_by_actor_id)
    values (%L, 1, 'source_discovery', 2, 'agent_requested', 'targeted',
            'Prøve i 960.', array['sertralin" OR alt annet'],
            'ac960000-0000-4000-8000-00000000000a')
  $$, (select id from plans where label = 'eff')),
  '23514',
  null,
  'en term med et anførselstegn kan ikke bæres inn i en søkestreng'
);

select throws_ok(
  format($$
    insert into workflow.monograph_search_requests
      (plan_id, plan_version, requested_for_role, search_round, origin, strategy,
       rationale, track_codes, requested_by_actor_id)
    values (%L, 1, 'source_quality_assessment', 2, 'agent_requested', 'targeted',
            'Prøve i 960.', array['bibliographic_database'],
            'ac960000-0000-4000-8000-00000000000a')
  $$, (select id from plans where label = 'eff')),
  '23514',
  null,
  'dekningskontrollens motsøk kan ikke bære et obligatorisk søkespor'
);

select throws_ok(
  format($$
    insert into workflow.monograph_search_requests
      (plan_id, plan_version, requested_for_role, search_round, origin, strategy,
       rationale, requested_by_actor_id)
    values (%L, 1, 'evidence_extraction', 2, 'agent_requested', 'targeted',
            'Prøve i 960.', 'ac960000-0000-4000-8000-00000000000a')
  $$, (select id from plans where label = 'eff')),
  '23514',
  null,
  'bare de to kildeleddene har maskinelle søkerunder'
);

select is(
  (select cardinality(r.track_codes) > 0 from workflow.monograph_search_requests r
   where r.plan_id = (select id from plans where label = 'eff')
     and r.requested_for_role = 'source_discovery'),
  true,
  'generatorens egen runde har derimot de sporene kildeprofilen krever'
);

-- ===========================================================================
-- Del 2b — To bestillinger med forskjellig innhold er to bestillinger
-- ===========================================================================
-- Uten dette ville et målrettet PubMed-søk på en aldersgruppe og et på et
-- studiedesign vært «den samme bestillingen», og det andre ville blitt stille
-- forkastet mens runden gikk videre som om begge var utført.
select lives_ok(
  format($$
    insert into workflow.monograph_search_requests
      (plan_id, plan_version, requested_for_role, search_round, origin, strategy,
       rationale, platform, query_terms, requested_by_actor_id)
    values
      (%1$L, 1, 'source_discovery', 2, 'agent_requested', 'targeted',
       'Aldersgruppen mangler.', 'PubMed', array['older adults'],
       'ac960000-0000-4000-8000-00000000000a'),
      (%1$L, 1, 'source_discovery', 2, 'agent_requested', 'targeted',
       'Studiedesignet mangler.', 'PubMed', array['randomized controlled trial'],
       'ac960000-0000-4000-8000-00000000000a')
  $$, (select id from plans where label = 'eff')),
  'to bestilte søk i samme runde, strategi og plattform med ulike termer er to rader'
);
select is(
  (select count(*)::integer from workflow.monograph_search_requests r
   where r.plan_id = (select id from plans where label = 'eff')
     and r.search_round = 2),
  2,
  'og begge står der: ingen av dem er stille forkastet'
);

-- Den samme bestillingen to ganger er derimot fortsatt én rad. Det er
-- idempotensen planåpningen og kontrollåpningen hviler på.
select throws_ok(
  format($$
    insert into workflow.monograph_search_requests
      (plan_id, plan_version, requested_for_role, search_round, origin, strategy,
       rationale, platform, query_terms, requested_by_actor_id)
    values (%L, 1, 'source_discovery', 2, 'agent_requested', 'targeted',
            'En annen begrunnelse, men nøyaktig det samme søket.', 'PubMed',
            array['older adults'], 'ac960000-0000-4000-8000-00000000000a')
  $$, (select id from plans where label = 'eff')),
  '23505',
  null,
  'den samme bestillingen to ganger er fortsatt én rad'
);

-- Og et virkestoffsynonym er en del av bestillingens identitet, ikke en
-- merknad ved siden av.
select isnt(
  (select r.request_key from workflow.monograph_search_requests r
   where r.plan_id = (select id from plans where label = 'eff')
     and r.search_round = 2 and r.query_terms = array['older adults']),
  workflow.monograph_search_request_key(
    'targeted', 'PubMed', array['sertraline'], array['older adults']),
  'to bestillinger som skiller seg bare på virkestoffsynonymet, er to bestillinger'
);

-- ===========================================================================
-- Del 3 — Bestillingen er uforanderlig, og en avsluttet runde gjenåpnes ikke
-- ===========================================================================
select throws_ok(
  format($$
    update workflow.monograph_search_requests
    set rationale = 'En annen begrunnelse enn den som ble utført.'
    where plan_id = %L and requested_for_role = 'source_discovery'
  $$, (select id from plans where label = 'eff')),
  '23001',
  'En maskinell søkeforespørsel er uforanderlig i det den bestiller.',
  'bestillingen kan ikke skrives om etter at kjøringen har utført den'
);

select throws_ok(
  format($$
    delete from workflow.monograph_search_requests where plan_id = %L
  $$, (select id from plans where label = 'eff')),
  '23001',
  null,
  'og en runde kan ikke slettes: søkeloggen viser til den'
);

update workflow.monograph_search_requests
set state = 'fulfilled', attempts = 1, completed_at = now()
where plan_id = (select id from plans where label = 'eff')
  and requested_for_role = 'source_discovery';

select throws_ok(
  format($$
    update workflow.monograph_search_requests
    set state = 'pending', completed_at = null
    where plan_id = %L and requested_for_role = 'source_discovery'
  $$, (select id from plans where label = 'eff')),
  '23001',
  'En avsluttet søkeforespørsel kan ikke gjenåpnes.',
  'en utført runde er et historisk faktum søkeloggen hviler på'
);

-- ===========================================================================
-- Del 4 — Porten, og hva den sier
-- ===========================================================================
select is(
  workflow.monograph_search_phase_problem(
    (select id from plans where label = 'eff'), 'source_discovery'),
  null,
  'en runde som er utført, holder ingenting tilbake'
);
select matches(
  workflow.monograph_search_phase_problem(
    (select id from plans where label = 'eff'), 'source_quality_assessment'),
  'ikke åpnet',
  'og en fase som ikke er åpnet, sier nettopp det'
);
select is(
  workflow.monograph_search_round(
    (select id from plans where label = 'eff'), 'source_discovery'),
  1,
  'planen står i runde 1'
);

-- ===========================================================================
-- Del 5 — Et oppbrukt søkebudsjett er åpent arbeid, aldri en konklusjon
-- ===========================================================================
-- Fire runder er taket. En runde til ser alltid billigere ut enn en avgjørelse,
-- og en oppbrukt ressursgrense skal gi ventende arbeid og aldri «utilstrekkelig
-- evidens» (SOURCE_POLICY.md §8.2).
update workflow.monograph_search_plans
set discovery_round = 4
where id = (select id from plans where label = 'eff');

-- Jobben svaret føres på. Den legges inn direkte her, fordi prøven gjelder
-- budsjettgrensen i svarveien og ikke kjedeovergangen som ellers ville laget den.
insert into workflow.pipeline_jobs
  (agent_role, job_key, input_manifest, enqueued_by_actor_id)
select 'source_discovery',
       'agent-handoff:prøve-960',
       jsonb_build_object(
         'search_plan_id', (select id from plans where label = 'eff'),
         'plan_version', 1,
         'discovery_round', 4),
       'ac960000-0000-4000-8000-00000000000a';

insert into svar (label, payload)
select 'budsjett', workflow.record_monograph_discovery_answer(
  j.*,
  jsonb_build_object('search_plan_id', (select id from plans where label = 'eff')),
  jsonb_build_object(
    'candidate_appraisals', jsonb_build_array(),
    'search_requests', jsonb_build_array(jsonb_build_object(
      'rationale', 'Prøve i 960: én runde til.',
      'strategy', 'targeted'))),
  null,
  'ac960000-0000-4000-8000-00000000000a')
from workflow.pipeline_jobs j
where j.job_key = 'agent-handoff:prøve-960';

select is(
  (select (payload -> 'search_budget_exhausted')::boolean from svar where label = 'budsjett'),
  true,
  'en femte runde blir ikke åpnet: budsjettet er brukt opp'
);
select is(
  (select (payload -> 'search_requests_opened')::integer from svar where label = 'budsjett'),
  0,
  'og ingen ny runde er lagt inn'
);
select isnt(
  (select p.paused_at from workflow.monograph_search_plans p
   where p.id = (select id from plans where label = 'eff')),
  null,
  'planen står på pause framfor å bli erklært ferdig'
);
select matches(
  (select p.paused_reason from workflow.monograph_search_plans p
   where p.id = (select id from plans where label = 'eff')),
  'åpent og ventende',
  'og pausegrunnen sier at arbeidet er åpent og ventende, ikke at evidensen mangler'
);
select alike(
  workflow.monograph_search_closure_problem((select id from plans where label = 'eff')),
  '%pause%',
  'porten leser pausen som at søket ikke er ferdig'
);

select * from finish();

rollback;
