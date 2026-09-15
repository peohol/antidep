-- Migrasjon 006 — tilgang til publiseringslaget.
--
-- Kritisk negativ test fra MVP_IMPLEMENTATION_PLAN.md §42, §47 og §48 og
-- DATABASE_ARCHITECTURE.md §5, §48, §49, §50 og §67: verken anonyme eller
-- vanlige innloggede brukere skal kunne publisere, avpublisere, flytte
-- publiseringspekeren eller lese publiseringshistorikken direkte. Klientflaten
-- leser publiserte projeksjoner i api (migrasjon 007).
--
-- Migrasjon 007a åpnet én smal lesevei: fire kolonner på de radene som beskriver
-- den gjeldende publiseringen, slik at api.published_claims kan vise
-- publiserings- og godkjenningsdato. Den er nøyaktig avgrenset her. Selve
-- oppførselen — hva viewet svarer, og hva som ikke er lesbart — står i
-- 330_api_publication_timestamps_test.sql.
--
-- Publiseringsfunksjonene er SECURITY DEFINER, og det gjør EXECUTE-privilegiet
-- til den avgjørende sperren. Kunne en vanlig bruker kalt dem, ville de kjørt med
-- definerens rettigheter og lest både rollemodellen og reviewbeslutningene forbi
-- RLS. Testene her kontrollerer derfor både at privilegiet mangler, og at de to
-- andre veiene til den samme tilstanden — direkte skriving i historikken og
-- direkte flytting av pekeren — er stengt.
--
-- SQLSTATE 42501 = insufficient_privilege.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(24);

-- ---------------------------------------------------------------------------
-- Testdata som bare finnes inne i denne transaksjonen, slik at et tomt resultat
-- under RLS ikke kan forveksles med en tom tabell.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email)
values ('dddddddd-0000-0000-0000-000000000001', 'publisher-270@test.invalid');

insert into provenance.actors (actor_type, actor_key, display_name, description, auth_user_id)
values ('human', 'human:publisher-270', 'Testpublisher',
        'Menneskelig aktør for tilgangstestene i 270.',
        'dddddddd-0000-0000-0000-000000000001');

-- Fra migrasjon 009e navngir en publiseringshendelse også det forseglede
-- innholdet og sluttkontrollen den hviler på. Fiksturet gir dem, framfor å
-- skrive en hendelse uten innhold — som databasen nå riktignok ikke tillater.
insert into knowledge.publication_events
  (claim_id, action, revision_id, revision_number,
   candidate_id, candidate_digest, final_control_id, final_control_decision,
   published_by_actor_id, published_by_actor_type, reason, published_at)
select r.claim_id, 'publish', r.id, r.revision_number,
       pg_temp.sealed_candidate_id(r.id), pg_temp.sealed_candidate_digest(r.id),
       pg_temp.sealed_final_control_id(r.id), 'approved',
       a.id, 'human',
       'Hendelse opprettet for tilgangstestene.', now()
from knowledge.claim_revisions r, provenance.actors a
join catalog.drugs d on true
where a.actor_key = 'human:publisher-270'
  and d.canonical_name = 'sertralin'
  and r.subject_drug_id = d.id;

-- ---------------------------------------------------------------------------
-- Lag 1: grants
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select r.role_name, p.privilege
    from (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'),
                       ('references'), ('trigger')) as p(privilege)
    where has_table_privilege(r.role_name, 'knowledge.publication_events', p.privilege)
  $$,
  'ingen klientrolle har noe tabellvidt privilegium på publiseringshistorikken'
);

-- has_table_privilege() ser ikke kolonnegrant. Assertionen over svarer «ingen
-- tilgang» også når enkeltkolonner er åpnet, og ble stille sann i det migrasjon
-- 007a ga klientrollene SELECT på fire kolonner. Den uttømmende kontrollen må
-- derfor gå på role_column_grants. Eierens implisitte privilegier står der som
-- egen grantee og filtreres bort.
select set_eq(
  $$
    select g.grantee || ':' || g.column_name || ':' || g.privilege_type
    from information_schema.role_column_grants g
    where g.table_schema = 'knowledge'
      and g.table_name = 'publication_events'
      and g.grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC')
  $$,
  $$
    values ('anon:claim_id:SELECT'),
           ('anon:revision_id:SELECT'),
           ('anon:published_at:SELECT'),
           ('anon:approval_decided_at:SELECT'),
           ('authenticated:claim_id:SELECT'),
           ('authenticated:revision_id:SELECT'),
           ('authenticated:published_at:SELECT'),
           ('authenticated:approval_decided_at:SELECT')
  $$,
  'klientrollene har SELECT på nøyaktig de fire kolonnene api-lesemodellen trenger, ingen skriveprivilegier, og service_role ingenting'
);

-- Navngitt negativ kontroll ved siden av set_eq-en over: de kolonnene som bærer
-- hvem som publiserte, hvorfor, og hele forgjengerkjeden skal være utenfor
-- klientflaten (PRODUCT_INFORMATION_ARCHITECTURE.md §58). set_eq ville fanget
-- dette, men ikke sagt hvilken kolonne som lakk.
select is_empty(
  $$
    select r.role_name, c.column_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('reason'), ('published_by_actor_id'), ('published_by_actor_type'),
                       ('action'), ('previous_event_id'), ('previous_revision_id'),
                       ('previous_revision_number'), ('revision_number'), ('object_type'),
                       ('id'), ('created_at'))
           as c(column_name)
    where has_column_privilege(r.role_name, 'knowledge.publication_events',
                               c.column_name, 'select')
  $$,
  'publiseringsbegrunnelsen, publisererens identitet og forgjengerkjeden er ikke lesbare for noen klientrolle'
);

-- Uttømmende over schemaet: en ny funksjon i knowledge skal ikke kunne bli
-- kjørbar for en klientrolle ved at noen glemmer å føre den opp her. EXECUTE til
-- authenticated er bevisst ikke gitt: knowledge er ikke et eksponert schema i
-- Data API-en, så granten ville ikke gitt noen reell skrivevei — den eksponerte
-- RPC-flaten hører til api-schemaet i migrasjon 007.
select is_empty(
  $$
    select p.oid::regprocedure::text, r.role_name
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    where n.nspname = 'knowledge'
      and has_function_privilege(r.role_name, p.oid, 'execute')
  $$,
  'ingen klientrolle kan kjøre noen funksjon i knowledge, heller ikke publiseringsoperasjonene'
);

-- ---------------------------------------------------------------------------
-- Lag 2: RLS er aktivert, uten policies i dette steget
-- ---------------------------------------------------------------------------
select ok(
  (select c.relrowsecurity from pg_class c
   where c.oid = 'knowledge.publication_events'::regclass),
  'RLS er aktivert på publiseringshistorikken'
);
-- Fram til migrasjon 007a stod tabellen uten policy. Den har nå nøyaktig én,
-- og assertionen er uttømmende framfor å bare bekrefte at den finnes: en ny
-- policy skal ikke kunne legges til uten at den føres opp her.
select set_eq(
  $$
    select p.polname
    from pg_policy p
    where p.polrelid = 'knowledge.publication_events'::regclass
  $$,
  $$ values ('publication_events_current_publication_read') $$,
  'publiseringshistorikken har nøyaktig én RLS-policy: leseveien migrasjon 007a åpnet for den gjeldende publiseringen'
);

select is(
  (select p.polcmd::text
   from pg_policy p
   where p.polrelid = 'knowledge.publication_events'::regclass
     and p.polname = 'publication_events_current_publication_read'),
  'r',
  'policyen gjelder bare SELECT; den kontrollerte skriveveien er fortsatt en funksjon, ikke tabelltilgang'
);

-- ---------------------------------------------------------------------------
-- Faktiske forsøk med Data API-rollene
-- ---------------------------------------------------------------------------
set local role anon;
select throws_ok(
  'select 1 from knowledge.publication_events', '42501', null,
  'anon nektes lesing av publiseringshistorikken'
);
select throws_ok(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    values (gen_random_uuid(), 'publish', gen_random_uuid(), 1,
            gen_random_uuid(), 'human', 'Anonym publisering.', now())
  $$,
  '42501', null,
  'anon kan ikke registrere en publisering'
);
select throws_ok(
  $$select knowledge.publish_claim_revision(gen_random_uuid(), gen_random_uuid(), 'Anonym.')$$,
  '42501', null,
  'anon kan ikke kalle publiseringsoperasjonen'
);
reset role;

set local role authenticated;
select throws_ok(
  'select 1 from knowledge.publication_events', '42501', null,
  'vanlig innlogget bruker nektes lesing av publiseringshistorikken'
);
select throws_ok(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    values (gen_random_uuid(), 'publish', gen_random_uuid(), 1,
            gen_random_uuid(), 'human', 'Selvpublisering.', now())
  $$,
  '42501', null,
  'vanlig innlogget bruker kan ikke skrive rett i publiseringshistorikken og dermed forbi gaten'
);
select throws_ok(
  $$update knowledge.publication_events set reason = 'Omskrevet.'$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke skrive om en registrert publisering'
);
select throws_ok(
  $$delete from knowledge.publication_events$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke slette en publiseringshendelse for å skjule den'
);
-- Den andre veien til den samme tilstanden: pekeren selv.
select throws_ok(
  $$update knowledge.claims set current_published_revision_id = gen_random_uuid()$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke flytte publiseringspekeren direkte'
);
select throws_ok(
  $$select knowledge.publish_claim_revision(gen_random_uuid(), gen_random_uuid(), 'Forsøk.')$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke publisere gjennom operasjonen'
);
select throws_ok(
  $$select knowledge.withdraw_claim_publication(gen_random_uuid(), gen_random_uuid(), 'Forsøk.')$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke avpublisere'
);
select throws_ok(
  $$select knowledge.rollback_claim_publication(
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'Forsøk.')$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke rulle tilbake en publisering'
);
-- Gaten og rettighetskontrollen er ikke kjørbare i seg selv heller. Kunne de
-- kalles, ville gaten vært et oppslagsverktøy mot review- og verifikasjonsdata
-- for enhver innlogget bruker.
select throws_ok(
  $$select knowledge.assert_claim_revision_publishable(gen_random_uuid())$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke kjøre publiseringsgaten som oppslag'
);
select throws_ok(
  $$select knowledge.assert_publisher_authorized(gen_random_uuid(), gen_random_uuid())$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke kjøre rettighetskontrollen'
);
reset role;

-- service_role omgår RLS, men ikke grants (DATABASE_ARCHITECTURE.md §49).
set local role service_role;
select throws_ok(
  'select 1 from knowledge.publication_events', '42501', null,
  'service_role nektes lesing av publiseringshistorikken fordi grants mangler'
);
reset role;

-- ---------------------------------------------------------------------------
-- RLS er en reell sperre, ikke bare fraværet av grants
--
-- Selvtest av lag 2: hvis en framtidig migrasjon ved et uhell gir privilegier til
-- en klientrolle, skal RLS fortsatt gi null rader og avvise skriving. Grantene
-- finnes bare inne i denne transaksjonen og rulles tilbake.
-- ---------------------------------------------------------------------------
grant usage on schema knowledge to authenticated;
grant select, insert, update, delete on knowledge.publication_events to authenticated;

select isnt_empty(
  'select 1 from knowledge.publication_events',
  'publiseringshendelsen finnes, sett fra eieren'
);

set local role authenticated;
select is(
  (select count(*) from knowledge.publication_events),
  0::bigint,
  'RLS gir null publiseringshendelser selv med SELECT-grant, fordi ingen policy slipper noen inn'
);
select throws_ok(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    values (gen_random_uuid(), 'publish', gen_random_uuid(), 1,
            gen_random_uuid(), 'human', 'Publisering med grant.', now())
  $$,
  '42501', null,
  'RLS stopper skriving i publiseringshistorikken selv om INSERT-granten er gitt ved et uhell'
);
reset role;

select * from finish();

rollback;
