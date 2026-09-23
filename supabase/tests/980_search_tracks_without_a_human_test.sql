-- Migrasjon 014c–014e — søkesporene uten et menneske i løkka.
--
-- 970 prøver registeret. Denne filen prøver det registeret skal gjøre for en
-- faktisk bestilling, og de tingene som ikke kan slippe gjennom når
-- maskinen gjør arbeidet et menneske gjorde før:
--
--   * sertralinpiloten: ingen plan står og venter på et menneske,
--   * en kandidatkilde flere planer finner, er bundet til hver plan og til
--     søket på den planen som fant den,
--   * en søkevei som ikke svarte, er en begrensning og aldri null treff,
--   * hver plan vurderer en delt kilde for sin egen avgrensning, og hver
--     sentral kilde følges — også når sporet alt er dekket,
--   * en avkortet treffliste kan ikke lukke dekningen: resten er dekket bare av
--     det samme søket lest helt, eller av et smalere søk med den samme metoden
--     som uttrykkelig erstatter det,
--   * dekningskontrollen er et atskilt ledd: den arver ikke generatorens søk,
--     og generatorens søk gjør den ikke uavhengig, og
--   * når det samme behovet hører til to planer, har hver plan sin egen bruk av
--     en delt kilde, og bare planens egen beslutning driver den.
--
-- SQLSTATE 23514 = check_violation, 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(44);

insert into auth.users (id, email)
values ('98000000-0000-4000-8000-00000000000a', 'redaktor-980@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac980000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-980',
   'Redaktør 980', 'Editor for prøven av søkesporene uten et menneske i 980.',
   '98000000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('98000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
   'ac980000-0000-4000-8000-00000000000a', 'Editor-tildeling for 980.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table refs (label text primary key, value text not null) on commit drop;
create temporary table runs (label text primary key, id uuid not null) on commit drop;
create temporary table cred (label text primary key, secret text not null) on commit drop;
grant select, insert on svar to authenticated, anon;
grant select, insert on runs to anon;
grant select on refs, runs, cred to authenticated, anon;

select set_config('request.jwt.claims',
                  '{"sub":"98000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 980.');
insert into svar (label, payload)
select 'modell_discovery', api.assign_agent_role_model(
  'source_discovery', 'prøve-980-a', 'Generatormodell 980', 'ikke-eksponert',
  'not_exposed', 'Prøve i 980.', 'Prøve i 980: generatorens modell.');
insert into svar (label, payload)
select 'modell_kontroll', api.assign_agent_role_model(
  'source_quality_assessment', 'prøve-980-b', 'Kontrollmodell 980', 'ikke-eksponert',
  'not_exposed', 'Prøve i 980.', 'Prøve i 980: kontrollens modell.');
reset role;

insert into cred (label, secret)
select 'discovery', provenance.issue_agent_identity_credential(
  'agent-identity:source-discovery-01', 'human:redaktor-980');
insert into cred (label, secret)
select 'kontroll', provenance.issue_agent_identity_credential(
  'agent-identity:source-quality-assessment-01', 'human:redaktor-980');

insert into refs (label, value)
select 'p_' || lower(sp.code), p.reference
from (select distinct on (profile_id) id, profile_id, reference
      from workflow.monograph_search_plans order by profile_id, created_at) p
join knowledge.monograph_source_profiles sp on sp.id = p.profile_id;

-- Runden en plan åpnet for én søkemetode. NULL/NULL er fritekstsøkene.
create function pg_temp.runde(p_label text, p_platform text, p_method text)
  returns text
  language sql
  stable
as $$
  select r.reference
  from workflow.monograph_search_requests r
  join workflow.monograph_search_plans p on p.id = r.plan_id
  where p.reference = (select value from refs where label = p_label)
    and r.requested_for_role = 'source_discovery'
    and r.platform is not distinct from p_platform
    and r.method is not distinct from p_method
  order by r.created_at
  limit 1;
$$;

insert into refs (label, value)
select v.label, pg_temp.runde(v.plan, v.platform, v.method)
from (values
  ('r|p_ae||', 'p_ae', null, null),
  ('r|p_eff||', 'p_eff', null, null),
  ('r|p_reg|DMP FEST|product_register', 'p_reg', 'DMP FEST', 'product_register'),
  ('r|p_tox|Europe PMC|systematic_review_filter', 'p_tox', 'Europe PMC', 'systematic_review_filter'),
  ('r|p_tox|PubMed|systematic_review_filter', 'p_tox', 'PubMed', 'systematic_review_filter')) as v(label, plan, platform, method);

set local role anon;
insert into runs (label, id)
select 'discovery', api.begin_agent_run(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  'source_discovery', 'antidep', 'search-execution-and-registration', '1.0.0',
  'source-discovery/machine-execution/2', 'antidep-evidence/1',
  jsonb_build_object('search_plan_reference', (select value from refs where label = 'p_eff')));
reset role;

-- ===========================================================================
-- Del 1 — Sertralinpiloten: ingen plan venter på et menneske
-- ===========================================================================
-- Før 014c sto hver eneste av de 70 planene i denne bestillingen fast på minst
-- ett spor uten maskinell vei, med 217 slike spor til sammen. Et menneske måtte
-- søke og registrere hvert av dem før en eneste plan kunne lukkes.
create temporary table menneskeblokkert on commit drop as
  select distinct p.id
  from workflow.monograph_search_plans p
  join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
  join workflow.monograph_search_track_attempts a on a.plan_id = p.id
  join knowledge.monograph_search_tracks k on k.id = a.track_id
  where p.closed_at is null
    and (a.state = 'no_machine_path'
         or (a.state = 'pending'
             and not exists (
               select 1
               from knowledge.monograph_search_platforms c
               where c.track_code = k.code
                 and (c.profile_codes is null or sp.code = any (c.profile_codes)))));

select cmp_ok(
  (select count(*)::integer from workflow.monograph_search_plans),
  '>', 60,
  'bestillingen gir fortsatt en søkeplan for hvert kunnskapsbehov som krever søk'
);
select is(
  (select count(*)::integer from menneskeblokkert),
  0,
  'og ingen av dem står fast på et spor bare et menneske kan utføre'
);
select is_empty(
  $$
    select p.id from workflow.monograph_search_plans p
    where not exists (
      select 1 from workflow.monograph_search_requests r
      where r.plan_id = p.id and r.state = 'pending')
  $$,
  'hver plan har maskinelle søkerunder som venter på kjøreren, ikke på en redaktør'
);

-- ===========================================================================
-- Del 2 — En kilde to planer finner, er bundet til hver av dem
-- ===========================================================================
-- EFF og AE søker i den samme litteraturen, og finner den samme oversikten.
-- Før 014c ble kilden bare liggende på den planen som fant den først.
set local role anon;
insert into svar (label, payload)
select 'eff_sok', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'p_eff'),
  (select value from refs where label = 'r|p_eff||'),
  'Europe PMC', '"sertraline"', 'pageSize=100',
  'https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=sertraline',
  'sha256:' || repeat('a', 64),
  'executed', 14, 14, false, null, null,
  array['bibliographic_database'],
  jsonb_build_array(jsonb_build_object(
    'identifier_kind', 'doi', 'identifier_value', '10.1000/980-felles',
    'title', 'Felles oversikt om sertralin (prøve 980)')),
  'keyword');
insert into svar (label, payload)
select 'ae_sok', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'p_ae'),
  (select value from refs where label = 'r|p_ae||'),
  'Europe PMC', '"sertraline" AND "adverse"', 'pageSize=100',
  'https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=sertraline+adverse',
  'sha256:' || repeat('b', 64),
  'executed', 9, 9, false, null, null,
  array['bibliographic_database'],
  jsonb_build_array(jsonb_build_object(
    'identifier_kind', 'doi', 'identifier_value', '10.1000/980-felles',
    'title', 'Felles oversikt om sertralin (prøve 980)')),
  'keyword');
reset role;

select is(
  (select count(*)::integer from workflow.monograph_candidate_sources
   where identifier_value = '10.1000/980-felles'),
  1,
  'kilden er én kandidat på utgaven, ikke to'
);
select bag_eq(
  $$
    select p.reference as plan_reference, sp_search.reference as search_plan_reference
    from workflow.monograph_candidate_source_plans l
    join workflow.monograph_candidate_sources c on c.id = l.candidate_source_id
    join workflow.monograph_search_plans p on p.id = l.plan_id
    join workflow.monograph_searches s on s.id = l.search_id
    join workflow.monograph_search_plans sp_search on sp_search.id = s.plan_id
    where c.identifier_value = '10.1000/980-felles'
  $$,
  $$
    values ((select value from refs where label = 'p_eff'), (select value from refs where label = 'p_eff')),
           ((select value from refs where label = 'p_ae'), (select value from refs where label = 'p_ae'))
  $$,
  'og den er bundet til begge planene, hver gang til søket på den samme planen som fant den'
);
select ok(
  (select bool_and(
     exists (
       select 1 from jsonb_array_elements(
         workflow.monograph_search_plan_payload(p) -> 'candidates') as c
       where c ->> 'identifier_value' = '10.1000/980-felles'))
   from workflow.monograph_search_plans p
   where p.reference in ((select value from refs where label = 'p_eff'),
                         (select value from refs where label = 'p_ae'))),
  'og den står i begge planenes søkegrunnlag, slik at hver av dem kan vurdere den'
);
select is(
  (select array_agg(s.search_method || '|' || s.platform order by s.registration_ordinal)
   from workflow.monograph_searches s
   join workflow.monograph_search_plans p on p.id = s.plan_id
   where p.reference = (select value from refs where label = 'p_eff')),
  array['keyword|Europe PMC'],
  'søket bærer metoden det brukte, og ikke bare plattformen'
);

-- ===========================================================================
-- Del 2b — Hver plan vurderer kilden for sin egen avgrensning
-- ===========================================================================
-- Den samme oversikten kan være sentral for effektspørsmålet og uten betydning
-- for bivirkningen. En felles beslutning ville latt den siste planen som
-- vurderte kilden, skrive over de andres.
create function pg_temp.plan_id(p_label text) returns uuid language sql stable as $$
  select p.id from workflow.monograph_search_plans p
  where p.reference = (select value from refs where label = p_label);
$$;
create function pg_temp.kilde(p_value text) returns uuid language sql stable as $$
  select c.id from workflow.monograph_candidate_sources c where c.identifier_value = p_value;
$$;

select workflow.appraise_monograph_candidate_source(
  pg_temp.kilde('10.1000/980-felles'), pg_temp.plan_id('p_eff'), true,
  'Den eneste oversikten som rapporterer effekten for nettopp denne avgrensningen.', null);
select workflow.decide_monograph_candidate_source(
  pg_temp.kilde('10.1000/980-felles'), pg_temp.plan_id('p_ae'), 'excluded',
  'Handler ikke om bivirkningene denne planen spør om.',
  'ac980000-0000-4000-8000-00000000000a', null);

select bag_eq(
  $$
    select p.reference as plan_reference, l.decision::text as decision,
           l.could_change_conclusion as material
    from workflow.monograph_candidate_source_plans l
    join workflow.monograph_search_plans p on p.id = l.plan_id
    where l.candidate_source_id = pg_temp.kilde('10.1000/980-felles')
  $$,
  $$
    values ((select value from refs where label = 'p_eff'), 'proposed', true),
           ((select value from refs where label = 'p_ae'), 'excluded', false)
  $$,
  'hver plan har sin egen vurdering av den samme kilden'
);
select is(
  (select c.decision::text || '|' || c.could_change_conclusion::text
   from workflow.monograph_candidate_sources c
   where c.id = pg_temp.kilde('10.1000/980-felles')),
  'proposed|true',
  'og én plans eksklusjon gjør ikke kilden ekskludert for utgaven: en annen plan har ikke tatt stilling'
);
select is(
  (select jsonb_build_array(
     jsonb_array_length(workflow.monograph_discovery_task_input(pg_temp.plan_id('p_eff'),
       'source_quality_assessment') -> 'control_task' -> 'excluded_candidates'),
     jsonb_array_length(workflow.monograph_discovery_task_input(pg_temp.plan_id('p_ae'),
       'source_quality_assessment') -> 'control_task' -> 'excluded_candidates'))),
  jsonb_build_array(0, 1),
  'kontrollen av effektplanen ser ingen eksklusjon; kontrollen av bivirkningsplanen ser sin egen'
);

select workflow.decide_monograph_candidate_source(
  pg_temp.kilde('10.1000/980-felles'), pg_temp.plan_id('p_eff'), 'included',
  'Inkludert for effektstørrelsen i den avgrensede populasjonen.',
  'ac980000-0000-4000-8000-00000000000a', null);

select is(
  (select c.decision::text || '|' ||
          (select l.decision::text from workflow.monograph_candidate_source_plans l
           where l.candidate_source_id = c.id and l.plan_id = pg_temp.plan_id('p_ae'))
   from workflow.monograph_candidate_sources c
   where c.id = pg_temp.kilde('10.1000/980-felles')),
  'included|excluded',
  'en kilde én plan inkluderer, hentes for utgaven — uten at den andre planens eksklusjon er skrevet over'
);

-- Og bruken følger planens egen beslutning. Bivirkningsplanen foreslo en bruk
-- for sitt behov og ekskluderte kilden; effektplanen inkluderte den med en bruk
-- for sitt. Effektplanens valg skal verken føre opp bivirkningsplanens bruk
-- eller sette dens behov i arbeid.
create temporary table behov on commit drop as
  select 'ae'::text as label,
         (select pn.need_id from workflow.monograph_search_plan_needs pn
          where pn.plan_id = pg_temp.plan_id('p_ae') order by pn.need_id limit 1) as need_id
  union all
  select 'eff',
         (select pn.need_id from workflow.monograph_search_plan_needs pn
          where pn.plan_id = pg_temp.plan_id('p_eff') order by pn.need_id limit 1);
create temporary table behov_for on commit drop as
  select b.label, b.need_id, n.work_state::text as work_state
  from behov b join knowledge.monograph_needs n on n.id = b.need_id;

insert into workflow.monograph_candidate_source_needs
  (candidate_source_id, need_id, plan_id, proposed_use)
values
  (pg_temp.kilde('10.1000/980-felles'), (select need_id from behov where label = 'ae'),
   pg_temp.plan_id('p_ae'), 'Foreslått av bivirkningsplanen før den ekskluderte kilden.'),
  (pg_temp.kilde('10.1000/980-felles'), (select need_id from behov where label = 'eff'),
   pg_temp.plan_id('p_eff'), 'Effektstørrelsen i den avgrensede populasjonen.');

select is(
  (select array_agg(w.need_id)
   from workflow.monograph_wanted_candidate_needs w
   where w.candidate_source_id = pg_temp.kilde('10.1000/980-felles')),
  array[(select need_id from behov where label = 'eff')],
  'bare effektplanens bruk er ønsket: planen som ekskluderte kilden, får ikke sin bruk ført videre'
);
select isnt(
  (select n.work_state::text from knowledge.monograph_needs n
   where n.id = (select need_id from behov where label = 'eff')),
  (select work_state from behov_for where label = 'eff'),
  'innhentingen gikk for effektplanens behov'
);
select is(
  (select n.work_state::text from knowledge.monograph_needs n
   where n.id = (select need_id from behov where label = 'ae')),
  (select work_state from behov_for where label = 'ae'),
  'og innhentingen effektplanens valg utløste, rørte ikke bivirkningsplanens behov'
);
select is(
  (select jsonb_build_array(
     (select jsonb_agg(u ->> 'need_reference')
      from jsonb_array_elements(workflow.monograph_discovery_task_input(pg_temp.plan_id('p_eff'),
             'source_discovery') -> 'candidates') as c,
           jsonb_array_elements(c -> 'uses') as u
      where c ->> 'identifier_value' = '10.1000/980-felles'),
     (select jsonb_agg(u ->> 'need_reference')
      from jsonb_array_elements(workflow.monograph_discovery_task_input(pg_temp.plan_id('p_ae'),
             'source_discovery') -> 'candidates') as c,
           jsonb_array_elements(c -> 'uses') as u
      where c ->> 'identifier_value' = '10.1000/980-felles'))),
  jsonb_build_array(
    jsonb_build_array((select n.reference from knowledge.monograph_needs n
                       where n.id = (select need_id from behov where label = 'eff'))),
    jsonb_build_array((select n.reference from knowledge.monograph_needs n
                       where n.id = (select need_id from behov where label = 'ae')))),
  'og hver plans oppgave viser bare bruken for planens egne behov'
);

-- Velger bivirkningsplanen siden kilden selv, tas dens behov med — selv om
-- kildens samlede utfall ikke endres, fordi effektplanen alt hadde valgt den.
select workflow.decide_monograph_candidate_source(
  pg_temp.kilde('10.1000/980-felles'), pg_temp.plan_id('p_ae'), 'included',
  'Ved nærmere vurdering dekker oversikten også bivirkningen.',
  'ac980000-0000-4000-8000-00000000000a', null);

select bag_eq(
  $$select w.need_id from workflow.monograph_wanted_candidate_needs w
    where w.candidate_source_id = pg_temp.kilde('10.1000/980-felles')$$,
  $$select need_id from behov$$,
  'når bivirkningsplanen selv inkluderer kilden, er dens bruk ønsket også'
);

insert into refs (label, value)
select 'felles', c.reference from workflow.monograph_candidate_sources c
where c.identifier_value = '10.1000/980-felles';

select set_config('request.jwt.claims',
                  '{"sub":"98000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select api.decide_monograph_candidate(
  (select value from refs where label = 'felles'),
  'awaiting_clarification',
  'Redaktøren vil avklare om oversikten dekker begge avgrensningene.');
reset role;

select is(
  (select array_agg(distinct l.decision::text)
   from workflow.monograph_candidate_source_plans l
   where l.candidate_source_id = pg_temp.kilde('10.1000/980-felles')),
  array['awaiting_clarification'],
  'redaktørens beslutning om utgaven gjelder hver plan kilden står på'
);

-- ===========================================================================
-- Del 2c — Hver sentral kilde følges, også når sporet alt er dekket
-- ===========================================================================
-- Tolv nye kilder kildeoppdagelsen vurderer som mulig konklusjonsendrende for
-- effektplanen. En runde følger høyst ti; resten får sin egen runde, og ingen
-- kilde blir liggende fordi den ikke fikk plass.
select workflow.record_monograph_candidate_source(
  pg_temp.plan_id('p_eff'),
  (select s.id from workflow.monograph_searches s
   where s.plan_id = pg_temp.plan_id('p_eff') order by s.registration_ordinal limit 1),
  'doi', '10.1000/980-sentral-' || n, 'Sentral kilde ' || n || ' (prøve 980)',
  null, null, 2020, 'Europe PMC, søk gjennom det åpne REST-endepunktet', false, null,
  true, 'Kan endre konklusjonen for effektplanen (prøve 980).',
  null, 'ac980000-0000-4000-8000-00000000000a')
from generate_series(1, 12) as n;

select is(
  workflow.open_monograph_machine_rounds(
    pg_temp.plan_id('p_eff'), 2, 'selection_opened'::workflow.monograph_search_request_origin,
    'ac980000-0000-4000-8000-00000000000a', null),
  6,
  'tretten sentrale kilder gir to runder per kildefølgende metode: ti og tre'
);
select is(
  (select count(distinct seed)::integer
   from workflow.monograph_search_requests r, unnest(r.seed_identifiers) as seed
   where r.plan_id = pg_temp.plan_id('p_eff')
     and r.platform = 'Europe PMC' and r.method = 'references'),
  13,
  'og hver av dem står i en runde'
);

-- Referanselisten til den første følges, og sporet er dermed dekket. En ny
-- sentral kilde etter det skal likevel følges.
select workflow.record_monograph_search(
  pg_temp.plan_id('p_eff'), 'Europe PMC', 'Referanselisten til doi:10.1000/980-sentral-1',
  null, now(), 5, 5, false, null, 'executed', null, 'machine_executed',
  'https://www.ebi.ac.uk/europepmc/webservices/rest/MED/1/references?format=json',
  'sha256:' || repeat('9', 64), array['reference_lists'], null,
  'ac980000-0000-4000-8000-00000000000a',
  (select r.id from workflow.monograph_search_requests r
   where r.plan_id = pg_temp.plan_id('p_eff')
     and r.platform = 'Europe PMC' and r.method = 'references'
   order by r.created_at limit 1),
  'references');
select workflow.record_monograph_candidate_source(
  pg_temp.plan_id('p_eff'), null,
  'doi', '10.1000/980-sentral-sen', 'En sentral kilde valgt etter at sporet var dekket (prøve 980)',
  null, null, 2021, 'Europe PMC, søk gjennom det åpne REST-endepunktet', false, null,
  true, 'Kan endre konklusjonen for effektplanen (prøve 980).',
  null, 'ac980000-0000-4000-8000-00000000000a');

select is(
  (select a.state::text from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   where a.plan_id = pg_temp.plan_id('p_eff') and k.code = 'reference_lists'),
  'covered',
  'referanselistesporet er dekket'
);
select is(
  workflow.open_monograph_machine_rounds(
    pg_temp.plan_id('p_eff'), 3, 'selection_opened'::workflow.monograph_search_request_origin,
    'ac980000-0000-4000-8000-00000000000a', null),
  3,
  'og den nye kilden følges likevel, med hver kildefølgende metode'
);
select bag_eq(
  $$
    select r.platform || '|' || r.method
    from workflow.monograph_search_requests r
    where r.plan_id = pg_temp.plan_id('p_eff') and r.search_round = 3
      and 'doi:10.1000/980-sentral-sen' = any (r.seed_identifiers)
  $$,
  $$values ('Europe PMC|references'), ('Europe PMC|citations'), ('Crossref|references')$$,
  'også referanselistene, selv om sporet deres alt var dekket'
);

-- ===========================================================================
-- Del 3 — En søkevei som ikke svarte, er ikke null treff
-- ===========================================================================
set local role anon;
insert into svar (label, payload)
select 'tox_nede', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'p_tox'),
  (select value from refs where label = 'r|p_tox|PubMed|systematic_review_filter'),
  'PubMed', '"sertraline" AND systematic[sb]', null,
  'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed',
  null,
  'unavailable', null, 0, false, null,
  'Søkeveien svarte HTTP 503 etter siste forsøk.',
  array['systematic_review_search'], null, 'systematic_review_filter');
reset role;

select is(
  (select a.state::text
   from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   join workflow.monograph_search_plans p on p.id = a.plan_id
   where p.reference = (select value from refs where label = 'p_tox')
     and k.code = 'systematic_review_search'),
  'unavailable',
  'et oversiktssøk som ikke svarte, står som utilgjengelig og ikke som dekket'
);

set local role anon;
select throws_ok(
  format($$
    select api.record_monograph_machine_search(
      'agent-identity:source-discovery-01', %L, %L, %L, %L,
      'Europe PMC', '"sertraline" AND PUB_TYPE:review', null,
      'https://www.ebi.ac.uk/europepmc/webservices/rest/search', null,
      'unavailable', 0, 0, false, null, 'Tidsavbrudd.',
      array['systematic_review_search'], null, 'systematic_review_filter')
  $$,
  (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'p_tox'),
  (select value from refs where label = 'r|p_tox|Europe PMC|systematic_review_filter')),
  '23514',
  null,
  'en søkevei som ikke svarte, kan ikke registreres med null treff: den har ikke noe treffantall'
);
select throws_ok(
  format($$
    select api.record_monograph_machine_search(
      'agent-identity:source-discovery-01', %L, %L, %L, %L,
      'Europe PMC', '"sertraline" AND PUB_TYPE:review', null,
      'https://www.ebi.ac.uk/europepmc/webservices/rest/search',
      'sha256:' || repeat('c', 64),
      'zero_results', 3, 0, false, null, null,
      array['systematic_review_search'], null, 'systematic_review_filter')
  $$,
  (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'p_tox'),
  (select value from refs where label = 'r|p_tox|Europe PMC|systematic_review_filter')),
  '23514',
  null,
  'og null treff med tre treff er ikke null treff'
);
insert into svar (label, payload)
select 'tox_null', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'p_tox'),
  (select value from refs where label = 'r|p_tox|Europe PMC|systematic_review_filter'),
  'Europe PMC', '"sertraline" AND PUB_TYPE:review', null,
  'https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=x',
  'sha256:' || repeat('d', 64),
  'zero_results', 0, 0, false, null, null,
  array['systematic_review_search'], null, 'systematic_review_filter');
reset role;

select is(
  (select a.state::text || '|' || s.platform || '|' || s.outcome::text
   from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   join workflow.monograph_search_plans p on p.id = a.plan_id
   join workflow.monograph_searches s on s.id = a.search_id
   where p.reference = (select value from refs where label = 'p_tox')
     and k.code = 'systematic_review_search'),
  'covered|Europe PMC|zero_results',
  'mens et søk som gikk og ga null treff, er et resultat og dekker sporet'
);

-- ===========================================================================
-- Del 4 — En avkortet treffliste kan ikke lukke dekningen
-- ===========================================================================
set local role anon;
insert into svar (label, payload)
select 'reg_avkortet', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'p_reg'),
  (select value from refs where label = 'r|p_reg|DMP FEST|product_register'),
  'DMP FEST', 'ATC N06AB06; sertralin', null,
  'https://www.dmp.no/globalassets/documents/om-oss/distribusjon-av-legemiddeldata/fest/festfiler/fest251.zip',
  'sha256:' || repeat('e', 64),
  'executed', 40, 25, true, 'Filen ble avbrutt etter 25 av 40 produktoppføringer.', null,
  array['norwegian_authority_source', 'all_identified_products', 'change_and_shortage_check'],
  null, 'product_register');
reset role;

select alike(
  (select payload ->> 'closure_problem' from svar where label = 'reg_avkortet'),
  '%avkortet på DMP FEST%',
  'sporene er forsøkt, men en avkortet lesning av registeret lukker ingenting'
);

set local role anon;
insert into svar (label, payload)
select 'reg_hel', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'p_reg'),
  (select value from refs where label = 'r|p_reg|DMP FEST|product_register'),
  'DMP FEST', 'ATC N06AB06; sertralin', null,
  'https://www.dmp.no/globalassets/documents/om-oss/distribusjon-av-legemiddeldata/fest/festfiler/fest251.zip',
  'sha256:' || repeat('f', 64),
  'executed', 40, 40, false, null, null,
  array['norwegian_authority_source', 'all_identified_products', 'change_and_shortage_check'],
  null, 'product_register');
insert into svar (label, payload)
select 'reg_lukk', api.close_monograph_search_request(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'r|p_reg|DMP FEST|product_register'));
reset role;

select alike(
  (select payload ->> 'closure_problem' from svar where label = 'reg_hel'),
  '%separate kontrollen%',
  'først en hel lesning flytter porten videre — til dekningskontrollen, og ikke til en redaktør'
);

-- Og et senere søk dekker resten av en avkortet treffliste bare når det er det
-- samme søket lest helt, eller et smalere søk med den samme metoden i en runde
-- som uttrykkelig erstatter den brede. Et kort søk om noe annet — et
-- oversiktssøk, eller et annet fritekstsøk ingen har sagt erstatter det — sier
-- ingenting om resten.
select workflow.open_monograph_search_request(
  pg_temp.plan_id('p_reg'), 'source_discovery', 2, 'agent_requested', 'broad',
  'Prøve i 980: et bredt fritekstsøk.', 'PubMed', 'keyword',
  array[]::text[], array[]::text[], array[]::text[], null, null,
  'ac980000-0000-4000-8000-00000000000a');
insert into refs (label, value)
select 'bred', r.reference from workflow.monograph_search_requests r
where r.plan_id = pg_temp.plan_id('p_reg')
  and r.rationale = 'Prøve i 980: et bredt fritekstsøk.';

select workflow.record_monograph_search(
  pg_temp.plan_id('p_reg'), 'PubMed', 'sertraline', null, now(), 5000, 25, true,
  'Første side av 5000 treff.', 'executed', null, 'machine_executed',
  'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=sertraline',
  'sha256:' || repeat('7', 64), array[]::text[], null,
  'ac980000-0000-4000-8000-00000000000a',
  (select r.id from workflow.monograph_search_requests r
   where r.reference = (select value from refs where label = 'bred')),
  'keyword');
select workflow.record_monograph_search(
  pg_temp.plan_id('p_reg'), 'PubMed', 'sertraline AND systematic[sb]', null, now(), 4, 4, false,
  null, 'executed', null, 'machine_executed',
  'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=sertraline+systematic',
  'sha256:' || repeat('8', 64), array[]::text[], null,
  'ac980000-0000-4000-8000-00000000000a', null, 'systematic_review_filter');
select workflow.record_monograph_search(
  pg_temp.plan_id('p_reg'), 'PubMed', 'sertraline AND "drug shortage"', null, now(), 3, 3, false,
  null, 'executed', null, 'machine_executed',
  'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=sertraline+shortage',
  'sha256:' || repeat('6', 64), array[]::text[], null,
  'ac980000-0000-4000-8000-00000000000a', null, 'keyword');

select alike(
  workflow.monograph_search_closure_problem(pg_temp.plan_id('p_reg')),
  '%avkortet på PubMed (keyword)%',
  'verken et oversiktssøk eller et annet fritekstsøk ingen har sagt erstatter det, lukker et avkortet fritekstsøk'
);

select workflow.open_monograph_search_request(
  pg_temp.plan_id('p_reg'), 'source_discovery', 3, 'agent_requested', 'targeted',
  'Prøve i 980: den delen av det brede søket som gjelder mangel.', 'PubMed', 'keyword',
  array[]::text[], array['drug shortage'], array[]::text[], null, null,
  'ac980000-0000-4000-8000-00000000000a',
  (select r2.id from workflow.monograph_search_requests r2
   where r2.reference = (select value from refs where label = 'bred')));
insert into refs (label, value)
select 'smal', r.reference from workflow.monograph_search_requests r
where r.plan_id = pg_temp.plan_id('p_reg')
  and r.rationale = 'Prøve i 980: den delen av det brede søket som gjelder mangel.';

select workflow.record_monograph_search(
  pg_temp.plan_id('p_reg'), 'PubMed', 'sertraline AND "drug shortage" AND norway', null, now(),
  2, 2, false, null, 'executed', null, 'machine_executed',
  'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=sertraline+shortage+norway',
  'sha256:' || repeat('5', 64), array[]::text[], null,
  'ac980000-0000-4000-8000-00000000000a',
  (select r.id from workflow.monograph_search_requests r
   where r.reference = (select value from refs where label = 'smal')),
  'keyword');

select alike(
  workflow.monograph_search_closure_problem(pg_temp.plan_id('p_reg')),
  '%separate kontrollen%',
  'mens et helt lest, smalere fritekstsøk i en runde som uttrykkelig erstatter den brede, gjør det'
);

-- ===========================================================================
-- Del 5 — Dekningskontrollen er et atskilt ledd
-- ===========================================================================
select workflow.chain_task_for_search_coverage(p.id)
from workflow.monograph_search_plans p
where p.reference = (select value from refs where label = 'p_reg');

insert into refs (label, value)
select 'kontrollrunde', r.reference
from workflow.monograph_search_requests r
join workflow.monograph_search_plans p on p.id = r.plan_id
where p.reference = (select value from refs where label = 'p_reg')
  and r.requested_for_role = 'source_quality_assessment';

select is(
  (select cardinality(r.track_codes) || '|' || r.strategy::text
   from workflow.monograph_search_requests r
   where r.reference = (select value from refs where label = 'kontrollrunde')),
  '0|targeted',
  'kontrollens motsøkerunde er målrettet og bærer ingen av generatorens obligatoriske spor'
);
select is(
  workflow.monograph_control_searched_independently(
    (select id from workflow.monograph_search_plans
     where reference = (select value from refs where label = 'p_reg'))),
  false,
  'generatorens søk gjør ikke kontrollen uavhengig, hvor mange de enn er'
);

set local role anon;
select throws_ok(
  format($$
    select api.record_monograph_machine_search(
      'agent-identity:source-discovery-01', %L, %L, %L, %L,
      'Crossref', '"sertralin"', null, 'https://api.crossref.org/works?query=x',
      'sha256:' || repeat('1', 64), 'executed', 2, 2, false, null, null,
      array[]::text[], null, 'keyword')
  $$,
  (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'p_reg'),
  (select value from refs where label = 'kontrollrunde')),
  '42501',
  'Søkerunden hører til det andre kildeleddet.',
  'generatoren kan ikke utføre kontrollens motsøk'
);

insert into runs (label, id)
select 'kontroll', api.begin_agent_run(
  'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
  'source_quality_assessment', 'antidep', 'coverage-control-registration', '1.0.0',
  'source-coverage/machine-countersearch/1', 'antidep-evidence/1',
  jsonb_build_object('search_plan_reference', (select value from refs where label = 'p_reg')));

select throws_ok(
  format($$
    select api.record_monograph_machine_search(
      'agent-identity:source-quality-assessment-01', %L, %L, %L, %L,
      'Crossref', '"sertralin"', null, 'https://api.crossref.org/works?query=x',
      'sha256:' || repeat('2', 64), 'executed', 2, 2, false, null, null,
      array['bibliographic_database'], null, 'keyword')
  $$,
  (select secret from cred where label = 'kontroll'),
  (select id from runs where label = 'kontroll'),
  (select value from refs where label = 'p_ae'),
  (select value from refs where label = 'r|p_ae||')),
  '42501',
  'Søkerunden hører til det andre kildeleddet.',
  'og kontrollen kan ikke utføre generatorens runder'
);

insert into svar (label, payload)
select 'motsok', api.record_monograph_machine_search(
  'agent-identity:source-quality-assessment-01', (select secret from cred where label = 'kontroll'),
  (select id from runs where label = 'kontroll'),
  (select value from refs where label = 'p_reg'),
  (select value from refs where label = 'kontrollrunde'),
  'Crossref', '"sertralin" AND "legemiddel"', 'rows=100',
  'https://api.crossref.org/works?query.bibliographic=sertralin',
  'sha256:' || repeat('3', 64), 'zero_results', 0, 0, false, null, null,
  array[]::text[], null, 'keyword');
reset role;

select is(
  workflow.monograph_control_searched_independently(
    (select id from workflow.monograph_search_plans
     where reference = (select value from refs where label = 'p_reg'))),
  true,
  'kontrollens eget motsøk, under dens egen rolle og kjøring, er det som gjør den uavhengig'
);

select is(
  (select jsonb_build_array(
            jsonb_array_length(t -> 'control_task' -> 'own_countersearches'),
            t -> 'control_task' -> 'own_countersearches' -> 0 ->> 'platform',
            jsonb_array_length(t -> 'control_task' -> 'generator_searches'))
   from (select workflow.monograph_discovery_task_input(p.id, 'source_quality_assessment') as t
         from workflow.monograph_search_plans p
         where p.reference = (select value from refs where label = 'p_reg')) x),
  jsonb_build_array(1, 'Crossref', 2),
  'og kontrolloppgaven holder dens egne motsøk atskilt fra generatorens to lesninger av FEST'
);

select is(
  (select array_agg(distinct a.state::text)
   from workflow.monograph_search_track_attempts a
   join workflow.monograph_search_plans p on p.id = a.plan_id
   where p.reference = (select value from refs where label = 'p_reg')),
  array['covered'],
  'motsøket rørte ingen av generatorens spor: de er dekket av generatorens egne søk'
);
select is(
  (select count(*)::integer
   from workflow.monograph_search_track_attempts a
   join workflow.monograph_searches s on s.id = a.search_id
   join provenance.agent_runs r on r.id = s.agent_run_id
   join workflow.monograph_search_plans p on p.id = a.plan_id
   where p.reference = (select value from refs where label = 'p_reg')
     and r.agent_role = 'source_quality_assessment'),
  0,
  'og ingen av dem peker på et av kontrollens søk'
);

-- ===========================================================================
-- Del 6 — Det samme behovet på to planer, med hver sin bruk
-- ===========================================================================
-- Et behov kan høre til flere planer. Begge planene finner den samme kilden,
-- foreslår hver sin bruk av den for det samme behovet og kommer til hver sin
-- beslutning. Hver plan ser og driver bare sin egen bruk: ingen av dem skrives
-- over av den andre, og ingen arves av den andre planen. Behovet er et
-- myndighetsbehov, slik at innhentingen skriver den faglige grunnen inn i
-- forespørselen den åpner. Bestillingen har flere effektplaner, og bare noen av
-- dem har et myndighetsbehov; hvilken av dem som er p_eff, er ikke gitt. Behovet
-- hentes derfor fra utgavens planer, helst effektplanens eget, og legges på
-- begge planene som mangler det.
create temporary table delt_behov on commit drop as
  select pn.need_id
  from workflow.monograph_search_plan_needs pn
  join workflow.monograph_search_plans p on p.id = pn.plan_id
  where p.edition_id = (select edition_id from workflow.monograph_search_plans
                        where id = pg_temp.plan_id('p_eff'))
    and knowledge.monograph_need_material_kind(pn.need_id) = 'authority_document'
  order by pn.plan_id = pg_temp.plan_id('p_eff') desc, pn.need_id
  limit 1;

insert into workflow.monograph_search_plan_needs (plan_id, need_id)
select pg_temp.plan_id(v.plan), d.need_id
from delt_behov d
cross join (values ('p_eff'), ('p_ae')) as v(plan)
where not exists (
  select 1 from workflow.monograph_search_plan_needs pn
  where pn.plan_id = pg_temp.plan_id(v.plan) and pn.need_id = d.need_id);

select workflow.record_monograph_candidate_source(
  pg_temp.plan_id(v.plan),
  (select s.id from workflow.monograph_searches s
   where s.plan_id = pg_temp.plan_id(v.plan) order by s.registration_ordinal limit 1),
  'doi', '10.1000/980-samme-behov', 'Kilde to planer bruker for det samme behovet (prøve 980)',
  null, null, 2021, 'Europe PMC, søk gjennom det åpne REST-endepunktet', false, null,
  false, null, null, 'ac980000-0000-4000-8000-00000000000a')
from (values ('p_eff'), ('p_ae')) as v(plan);

insert into workflow.monograph_candidate_source_needs
  (candidate_source_id, need_id, plan_id, proposed_use)
values
  (pg_temp.kilde('10.1000/980-samme-behov'), (select need_id from delt_behov),
   pg_temp.plan_id('p_eff'), 'Effektplanens bruk: effektstørrelsen ved endepunktet.'),
  (pg_temp.kilde('10.1000/980-samme-behov'), (select need_id from delt_behov),
   pg_temp.plan_id('p_ae'), 'Bivirkningsplanens bruk: frafallet på grunn av bivirkninger.');

select throws_ok(
  $$insert into workflow.monograph_candidate_source_needs
      (candidate_source_id, need_id, plan_id, proposed_use)
    values (pg_temp.kilde('10.1000/980-samme-behov'),
            (select need_id from delt_behov),
            pg_temp.plan_id('p_tox'), 'En plan som aldri fant kilden.')$$,
  '22023',
  'En bruk av en kandidatkilde må høre til en plan som har funnet kilden og dekker behovet.',
  'en plan som ikke har funnet kilden, kan ikke foreslå en bruk av den'
);

select workflow.decide_monograph_candidate_source(
  pg_temp.kilde('10.1000/980-samme-behov'), pg_temp.plan_id('p_eff'), 'excluded',
  'Effektplanen finner ikke effektmålet sitt i kilden.',
  'ac980000-0000-4000-8000-00000000000a', null);
select workflow.decide_monograph_candidate_source(
  pg_temp.kilde('10.1000/980-samme-behov'), pg_temp.plan_id('p_ae'), 'included',
  'Bivirkningsplanen bruker kilden for frafallet.',
  'ac980000-0000-4000-8000-00000000000a', null);

select bag_eq(
  $$
    select p.reference as plan_reference, cn.proposed_use
    from workflow.monograph_candidate_source_needs cn
    join workflow.monograph_search_plans p on p.id = cn.plan_id
    where cn.candidate_source_id = pg_temp.kilde('10.1000/980-samme-behov')
  $$,
  $$
    values ((select value from refs where label = 'p_eff'),
            'Effektplanens bruk: effektstørrelsen ved endepunktet.'),
           ((select value from refs where label = 'p_ae'),
            'Bivirkningsplanens bruk: frafallet på grunn av bivirkninger.')
  $$,
  'hver plan har sin egen bruk for det samme behovet, og ingen av dem er skrevet over'
);
select is(
  (select jsonb_agg(jsonb_build_array(v.plan, (
     select jsonb_agg(u ->> 'proposed_use')
     from jsonb_array_elements(workflow.monograph_discovery_task_input(pg_temp.plan_id(v.plan),
            'source_discovery') -> 'candidates') as c,
          jsonb_array_elements(c -> 'uses') as u
     where c ->> 'identifier_value' = '10.1000/980-samme-behov')) order by v.plan)
   from (values ('p_ae'), ('p_eff')) as v(plan)),
  jsonb_build_array(
    jsonb_build_array('p_ae', jsonb_build_array(
      'Bivirkningsplanens bruk: frafallet på grunn av bivirkninger.')),
    jsonb_build_array('p_eff', jsonb_build_array(
      'Effektplanens bruk: effektstørrelsen ved endepunktet.'))),
  'hver plans oppgave viser bare planens egen bruk, også når behovet er det samme'
);
select is(
  (select jsonb_agg(jsonb_build_array(v.plan, (
     select jsonb_agg(u ->> 'proposed_use')
     from jsonb_array_elements(workflow.monograph_search_plan_payload(p) -> 'candidates') as c,
          jsonb_array_elements(c -> 'uses') as u
     where c ->> 'identifier_value' = '10.1000/980-samme-behov')) order by v.plan)
   from (values ('p_ae'), ('p_eff')) as v(plan)
   join workflow.monograph_search_plans p on p.id = pg_temp.plan_id(v.plan)),
  jsonb_build_array(
    jsonb_build_array('p_ae', jsonb_build_array(
      'Bivirkningsplanens bruk: frafallet på grunn av bivirkninger.')),
    jsonb_build_array('p_eff', jsonb_build_array(
      'Effektplanens bruk: effektstørrelsen ved endepunktet.'))),
  'og det samme gjelder planens egen oversikt'
);
select bag_eq(
  $$
    select p.reference as plan_reference, w.proposed_use
    from workflow.monograph_wanted_candidate_needs w
    join workflow.monograph_search_plans p on p.id = w.plan_id
    where w.candidate_source_id = pg_temp.kilde('10.1000/980-samme-behov')
  $$,
  $$
    values ((select value from refs where label = 'p_ae'),
            'Bivirkningsplanens bruk: frafallet på grunn av bivirkninger.')
  $$,
  'bare bruken til planen som inkluderte kilden, er ønsket — effektplanens eksklusjon arver ikke bivirkningsplanens valg'
);

insert into refs (label, value)
select 'utgave', e.reference
from knowledge.monograph_editions e
join workflow.monograph_candidate_sources c on c.edition_id = e.id
where c.id = pg_temp.kilde('10.1000/980-samme-behov');

select set_config('request.jwt.claims',
                  '{"sub":"98000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'foresporsler', api.monograph_source_requests(
  (select value from refs where label = 'utgave'));
reset role;

select is(
  (select jsonb_build_array(
            position('Bivirkningsplanens bruk' in r ->> 'professional_reason') > 0,
            position('Effektplanens bruk' in r ->> 'professional_reason') > 0)
   from svar, jsonb_array_elements(payload -> 'authority_documents') as r
   where label = 'foresporsler'
     and r ->> 'title' = 'Kilde to planer bruker for det samme behovet (prøve 980)'),
  jsonb_build_array(true, false),
  'og forespørselen innhentingen åpnet, bærer bivirkningsplanens bruk som faglig grunn — ikke effektplanens'
);

select * from finish();
rollback;
