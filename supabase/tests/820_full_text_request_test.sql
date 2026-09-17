-- Migrasjon 012c — å be om en artikkel Antidep mangler, uten en terminal.
--
-- Filen dekker at setningene i migrasjonen betyr noe:
--
--   * en redaktør kan bestille med bare bibliografi og en faglig avgrensning,
--   * kilden opprettes eller gjenfinnes på DOI-en, og aldri to ganger,
--   * bestillingen går gjennom nøyaktig den skriveveien migrasjon 011 skrev,
--   * den samme bestillingen to ganger er én, og en annen avgrensning avvises,
--   * katalogvalgene er navn, og et navn utenfor katalogen avvises med navnet,
--   * en DOI som ikke er en DOI, avvises før noe skrives,
--   * bestillingen krever editor-mandat — ikke admin, og ikke ingenting, og
--   * flaten kan spørre hva den innloggede kan gjøre, uten å bli avvist.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(34);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select is_empty(
  $$
    select f.name
    from (values
      ('api.request_missing_full_text(text,text,text,text[],text[],text[],text,integer)'),
      ('api.full_text_request_options()'),
      ('api.full_text_capabilities()')
    ) as f(name)
    where has_function_privilege('anon', f.name, 'EXECUTE')
       or has_function_privilege('public', f.name, 'EXECUTE')
       or has_function_privilege('service_role', f.name, 'EXECUTE')
  $$,
  'bestillingsveiene er stengt for anon, service_role og PUBLIC'
);
select ok(
  has_function_privilege(
    'authenticated',
    'api.request_missing_full_text(text,text,text,text[],text[],text[],text,integer)',
    'EXECUTE'),
  'og åpne for authenticated, der mandatet avgjør'
);

-- ===========================================================================
-- Del 2 — Fikstur: en redaktør, en admin og en kliniker uten mandat
-- ===========================================================================
insert into auth.users (id, email) values
  ('82000000-0000-4000-8000-00000000000b', 'redaktor-820@test.invalid'),
  ('82000000-0000-4000-8000-00000000000c', 'admin-820@test.invalid'),
  ('82000000-0000-4000-8000-00000000000d', 'kliniker-820@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac820000-0000-4000-8000-00000000000b', 'human', 'human:redaktor-820',
   'Redaktør 820', 'Aktør med gyldig editor-tildeling, for 820.',
   '82000000-0000-4000-8000-00000000000b'),
  ('ac820000-0000-4000-8000-00000000000c', 'human', 'human:admin-820',
   'Admin 820', 'Aktør med gyldig admin-tildeling, for 820.',
   '82000000-0000-4000-8000-00000000000c'),
  ('ac820000-0000-4000-8000-00000000000d', 'human', 'human:kliniker-820',
   'Kliniker 820', 'Aktør uten mandat, for 820.',
   '82000000-0000-4000-8000-00000000000d');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('82000000-0000-4000-8000-00000000000b', 'editor', null, now() - interval '1 year',
   'ac820000-0000-4000-8000-00000000000b', 'Gyldig editor-tildeling for 820.'),
  ('82000000-0000-4000-8000-00000000000c', 'admin', null, now() - interval '1 year',
   'ac820000-0000-4000-8000-00000000000b', 'Gyldig admin-tildeling for 820.');

create temporary table result (label text primary key, payload jsonb not null) on commit drop;
grant select, insert on result to authenticated;

-- ===========================================================================
-- Del 3 — Hva flaten kan vise til hvem
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'cap_editor', api.full_text_capabilities();
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
insert into result select 'cap_admin', api.full_text_capabilities();
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
insert into result select 'cap_clinician', api.full_text_capabilities();
reset role;

select is(
  (select payload from result where label = 'cap_editor'),
  '{"may_request": true, "may_upload": true}'::jsonb,
  'en redaktør kan både bestille og laste opp'
);
select is(
  (select payload from result where label = 'cap_admin'),
  '{"may_request": false, "may_upload": true}'::jsonb,
  'en admin kan laste opp, men bestillingen er en redaksjonell avgjørelse'
);
select is(
  (select payload from result where label = 'cap_clinician'),
  '{"may_request": false, "may_upload": false}'::jsonb,
  'og en kliniker uten mandat får et stille nei framfor en avvisning'
);

-- ===========================================================================
-- Del 4 — Valgene er navn, og bare navn
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'options', api.full_text_request_options();
reset role;

select ok(
  (select payload -> 'drugs' ? 'sertralin' from result where label = 'options'),
  'valgene navngir virkestoffene i katalogen'
);
select ok(
  (select payload -> 'outcomes' ? 'vektendring' from result where label = 'options'),
  'og endepunktene'
);
select is_empty(
  $$
    select 1 from result
    where label = 'options' and payload::text ~ '[0-9a-f]{8}-[0-9a-f]{4}-'
  $$,
  'og ikke én eneste uuid'
);

select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
select throws_ok(
  $$ select api.full_text_request_options() $$,
  '42501',
  null,
  'en kliniker uten mandat kommer ikke til valgene'
);
reset role;

-- ===========================================================================
-- Del 5 — Bestillingen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'first', api.request_missing_full_text(
  'https://doi.org/10.1234/Antidep.820',
  'Sertralin og vektendring over 52 uker',
  'Testforfatter 820 m.fl.',
  array['sertralin'],
  array['vektendring'],
  array['voksne med depressiv lidelse'],
  'Journal of Synthetic Trials',
  2019);
reset role;

select is(
  (select (payload ->> 'requested')::boolean from result where label = 'first'),
  true,
  'bestillingen tas imot'
);
select is(
  (select (payload ->> 'source_registered')::boolean from result where label = 'first'),
  true,
  'og kilden opprettes, fordi artikkelen ikke fantes fra før'
);
select is(
  (select i.identifier_value from knowledge.source_identifiers i
   join knowledge.sources s on s.id = i.source_id
   where s.title = 'Sertralin og vektendring over 52 uker'),
  '10.1234/antidep.820',
  'DOI-en normaliseres til små bokstaver, og doi.org-lenken er bare en skrivemåte'
);
select is(
  (select s.publication_date_precision::text from knowledge.sources s
   where s.title = 'Sertralin og vektendring over 52 uker'),
  'year',
  'og årstallet registreres med den presisjonen det faktisk har'
);
select is(
  (select r.state::text from workflow.full_text_requests r
   join knowledge.sources s on s.id = r.source_id
   where s.title = 'Sertralin og vektendring over 52 uker'),
  'open',
  'forespørselen står som åpen: Antidep venter på fullteksten'
);
select is(
  (select r.retrieved_from from workflow.full_text_requests r
   join knowledge.sources s on s.id = r.source_id
   where s.title = 'Sertralin og vektendring over 52 uker'),
  'https://doi.org/10.1234/antidep.820',
  'og adressen dokumentet hentes fra, utledes av DOI-en uten at noen oppgir den'
);
select is(
  (select cardinality(r.drug_ids) from workflow.full_text_requests r
   join knowledge.sources s on s.id = r.source_id
   where s.title = 'Sertralin og vektendring over 52 uker'),
  1,
  'avgrensningen er oversatt fra navn til katalograder'
);

-- Den uinnloggede ser at Antidep venter, uten å se artikkelen eller noe teknisk.
create temporary table board (payload jsonb) on commit drop;
grant select, insert on board to anon;
set local role anon;
insert into board select api.public_work_board();
reset role;

select ok(
  (select exists (
     select 1 from board, lateral jsonb_array_elements(payload) as item
     where item ->> 'activity' = 'full_text'
       and item ->> 'waiting_for' = 'full_text'
       and item -> 'subjects' ? 'sertralin')),
  'og den uinnloggede ser «venter på fulltekst» som planlagt arbeid'
);
select is_empty(
  $$
    select 1 from board, lateral jsonb_array_elements(payload) as item
    where item::text like '%10.1234/antidep.820%'
       or item::text like '%Sertralin og vektendring%'
  $$,
  'uten at artikkelen eller DOI-en forlater databasen der'
);

-- Og redaktøren ser den i innboksen, i klartekst, som neste handling.
select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'inbox', jsonb_build_object('rows', api.full_text_inbox());
reset role;

select ok(
  (select exists (
     select 1 from result, lateral jsonb_array_elements(payload -> 'rows') as item
     where label = 'inbox'
       and item ->> 'title' = 'Sertralin og vektendring over 52 uker'
       and item ->> 'state' = 'needs_upload')),
  'og fulltekstinnboksen ber om nettopp den artikkelen'
);

-- ===========================================================================
-- Del 6 — Gjentakelse, og en annen avgrensning
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'again', api.request_missing_full_text(
  '10.1234/ANTIDEP.820',
  'Sertralin og vektendring over 52 uker',
  'Testforfatter 820 m.fl.',
  array['sertralin'],
  array['vektendring'],
  array['voksne med depressiv lidelse'],
  'Journal of Synthetic Trials',
  2019);
reset role;

select is(
  (select (payload ->> 'requested')::boolean from result where label = 'again'),
  false,
  'den samme bestillingen to ganger er én bestilling'
);
select is(
  (select count(*)::integer from knowledge.sources s
   where s.title = 'Sertralin og vektendring over 52 uker'),
  1,
  'og artikkelen ble ikke registrert to ganger'
);
select is(
  (select count(*)::integer from workflow.full_text_requests r
   join knowledge.sources s on s.id = r.source_id
   where s.title = 'Sertralin og vektendring over 52 uker'),
  1,
  'og ventelisten har fortsatt nøyaktig én rad for den'
);

-- En *annen* avgrensning er en annen bestilling, og skal ikke svelges stille:
-- et stille ja ville latt det nye arbeidet forsvinne uten at noen merket det.
select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  $$ select api.request_missing_full_text(
       '10.1234/antidep.820', 'Sertralin og vektendring over 52 uker',
       'Testforfatter 820 m.fl.', array['sertralin', 'mirtazapin'],
       array['vektendring'], array[]::text[], null, null) $$,
  '23001',
  null,
  'en annen avgrensning på den samme artikkelen avvises framfor å svelges stille'
);

-- ===========================================================================
-- Del 7 — Det flaten ikke kan sende
-- ===========================================================================
select throws_ok(
  $$ select api.request_missing_full_text(
       'ikke-en-doi', 'En artikkel', 'En forfatter',
       array['sertralin'], array['vektendring'], array[]::text[], null, null) $$,
  '22023',
  null,
  'en DOI som ikke er en DOI, avvises før noe skrives'
);
select throws_ok(
  $$ select api.request_missing_full_text(
       '10.1234/antidep.820b', '   ', 'En forfatter',
       array['sertralin'], array['vektendring'], array[]::text[], null, null) $$,
  '22023',
  null,
  'og en bestilling uten tittel: innboksen ville ikke kunnet vise hvilken artikkel det gjaldt'
);
select throws_like(
  $$ select api.request_missing_full_text(
       '10.1234/antidep.820c', 'En artikkel', 'En forfatter',
       array['finnes-ikke'], array['vektendring'], array[]::text[], null, null) $$,
  '%finnes-ikke%',
  'et virkestoff utenfor katalogen avvises med navnet, aldri med en id'
);
select throws_ok(
  $$ select api.request_missing_full_text(
       '10.1234/antidep.820d', 'En artikkel', 'En forfatter',
       array['sertralin'], array[]::text[], array[]::text[], null, null) $$,
  '22023',
  null,
  'og en bestilling uten endepunkt: avgrensningen ville ikke kunnet bli en oppgave'
);
reset role;

select is(
  (select count(*)::integer from knowledge.source_identifiers i
   where i.identifier_value in ('10.1234/antidep.820b', '10.1234/antidep.820c',
                                '10.1234/antidep.820d')),
  0,
  'en avvist bestilling etterlater ingen halv kilde'
);

-- ===========================================================================
-- Del 7b — En katalograd som er tatt ut av bruk mens skjemaet sto åpent
-- ===========================================================================
-- Listen flaten velger fra, er de radene som er i bruk. Et skjema lastes én
-- gang og sendes inn senere, og i mellomtiden kan en rad ha blitt tatt ut —
-- et virkestoff trukket fra markedet, for eksempel. Da bærer skjemaet fortsatt
-- navnet, og den autoritative veien er det eneste stedet det kan stoppes.
--
-- Prøven bruker en egen katalograd og rører ingen seedet verdi: det som prøves
-- her, er porten, ikke hvilke virkestoff Antidep kjenner.
insert into catalog.drugs (id, canonical_name, status)
values ('82000000-0000-4000-8000-0000000000d1', 'prøvestoff 820', 'active');

select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'options_active', api.full_text_request_options();
reset role;

select ok(
  (select payload -> 'drugs' ? 'prøvestoff 820' from result where label = 'options_active'),
  'et virkestoff i bruk står i listen redaktøren velger fra'
);

update catalog.drugs set status = 'withdrawn'
where id = '82000000-0000-4000-8000-0000000000d1';

set local role authenticated;
insert into result select 'options_withdrawn', api.full_text_request_options();
select throws_like(
  $$ select api.request_missing_full_text(
       '10.1234/antidep.820g', 'En artikkel om et trukket virkestoff', 'En forfatter',
       array['prøvestoff 820'], array['vektendring'], array[]::text[], null, null) $$,
  '%ikke lenger i bruk%',
  'og en bestilling på det etter at det er tatt ut av bruk, avvises — ikke som en skrivefeil'
);
reset role;

select ok(
  not (select payload -> 'drugs' ? 'prøvestoff 820' from result where label = 'options_withdrawn'),
  'listen tilbyr det ikke lenger'
);
select is(
  (select count(*)::integer from knowledge.source_identifiers i
   where i.identifier_value = '10.1234/antidep.820g'),
  0,
  'og den avviste bestillingen etterlot ingen halv kilde'
);

-- ===========================================================================
-- Del 8 — Mandatet
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select throws_ok(
  $$ select api.request_missing_full_text(
       '10.1234/antidep.820e', 'En artikkel', 'En forfatter',
       array['sertralin'], array['vektendring'], array[]::text[], null, null) $$,
  '42501',
  null,
  'en admin kan ikke bestille: hvilken artikkel Antidep trenger, er en redaksjonell avgjørelse'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"82000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
select throws_ok(
  $$ select api.request_missing_full_text(
       '10.1234/antidep.820f', 'En artikkel', 'En forfatter',
       array['sertralin'], array['vektendring'], array[]::text[], null, null) $$,
  '42501',
  null,
  'og en kliniker uten mandat kan det heller ikke'
);
reset role;

select * from finish();
rollback;
