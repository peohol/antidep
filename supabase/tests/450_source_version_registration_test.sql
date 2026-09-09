-- Migrasjon 007f — den kontrollerte skriveveien for å registrere en kildeversjon.
--
-- Leddet mellom kildeopprettelsen (370_source_creation_test.sql) og
-- evidensregistreringen (390_evidence_item_registration_test.sql): issue #44 og
-- MVP_IMPLEMENTATION_PLAN.md §74.30 punkt 1. Filen dekker de samme fire tingene
-- som de to, i samme rekkefølge — kontrakten, autorisasjonen, konsekvensen og
-- avvisningene — og i tillegg det som er nytt her og ikke finnes noe annet sted:
-- at content_hash eies av databasen og ikke av kalleren.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23502 = not_null_violation,
-- 23503 = foreign_key_violation, 23505 = unique_violation,
-- 23514 = check_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(34);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function('api', 'create_source_version', 'api.create_source_version() finnes');
select has_function(
  'knowledge', 'record_source_version', 'knowledge.record_source_version() finnes'
);
select has_function(
  'knowledge', 'source_version_content_hash',
  'knowledge.source_version_content_hash() finnes'
);
select has_function(
  'audit', 'record_source_version_event', 'audit.record_source_version_event() finnes'
);
select has_trigger(
  'knowledge', 'source_versions', 'source_versions_record_registration_audit_event',
  'enhver registrert kildeversjon auditeres'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.create_source_version(uuid,timestamptz,text,text,text,text,text)'::regprocedure),
  'api.create_source_version() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
-- Auditskriveren skal aldri være mer privilegert enn operasjonen den
-- registrerer (samme regel som for de fire auditskriverne før den).
select ok(
  not (select p.prosecdef from pg_proc p
       where p.oid = 'audit.record_source_version_event()'::regprocedure),
  'audit.record_source_version_event() er ikke SECURITY DEFINER'
);
-- Innsettingen er delt fra inngangspunktet for at en senere skrivevei med en
-- annen autorisasjonsmodell skal kunne gjenbruke den. Da må den heller ikke
-- selv være et inngangspunkt: uten denne kontrollen kunne en kaller nå
-- innsettingen uten å gå gjennom noen autorisasjon i det hele tatt.
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'knowledge.record_source_version(uuid,timestamptz,text,text,text,text,text,uuid)'::regprocedure,
      'execute'
    )
  $$,
  'ingen klientrolle kan kalle knowledge.record_source_version() forbi autorisasjonen'
);

select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.create_source_version(uuid,timestamptz,text,text,text,text,text)'::regprocedure,
      'execute'
    )
  $$,
  'api.create_source_version() er kjørbar bare for authenticated, ikke for anon, service_role eller PUBLIC'
);
select ok(
  has_function_privilege(
    'authenticated',
    'api.create_source_version(uuid,timestamptz,text,text,text,text,text)'::regprocedure,
    'execute'
  ),
  'authenticated har EXECUTE på api.create_source_version()'
);

-- Hashen er ikke en parameter, og det er kontrakten og ikke en implementasjons-
-- detalj: en `p_content_hash` lagt til senere ville gjort verdien til en
-- klientpåstand igjen, uten at noe annet i testpakken sa fra.
select is_empty(
  $$
    select argname
    from pg_proc p
    cross join lateral unnest(p.proargnames) as argname
    where p.oid = 'api.create_source_version(uuid,timestamptz,text,text,text,text,text)'::regprocedure
      and argname in ('p_content_hash', 'p_retrieved_by_actor_id')
  $$,
  'verken hashen eller aktøren kan oppgis av kalleren'
);

-- ===========================================================================
-- Del 2 — Hashen: hva som faktisk hashes
--
-- Verdien skal kunne reproduseres av `sha256sum` på svaret fra retrieved_from,
-- av hvem som helst, uten å kjenne til noen kanonisk form. Kontrollen er derfor
-- mot en kjent sha256-verdi og ikke bare mot funksjonen selv: en normalisering
-- lagt inn senere ville ellers vært usynlig her.
--
-- Referanseverdien er sha256 av strengen «antidep» (`printf 'antidep' |
-- sha256sum`).
-- ===========================================================================
select is(
  knowledge.source_version_content_hash('antidep'),
  'sha256:4f031f35e9e54f26eaed0a8e2333d6d51dd0be1d72d67a74ee8b72ca46b0dfba',
  'hashen er sha256 av bytene, uten normalisering — samme verdi som `printf ''antidep'' | sha256sum`'
);

-- ===========================================================================
-- Del 3 — Fikstur
--
--   A  ingen aktørrad i det hele tatt
--   B  aktør, men ingen rolletildeling
--   C  aktør, tilbaketrukket, med en ellers gyldig editor-tildeling
--   D  aktør, editor-tildeling avgrenset til «vektendring»
-- ===========================================================================
insert into auth.users (id, email) values
  ('45000000-0000-4000-8000-00000000000a', 'kildeversjon-450-a@test.invalid'),
  ('45000000-0000-4000-8000-00000000000b', 'kildeversjon-450-b@test.invalid'),
  ('45000000-0000-4000-8000-00000000000c', 'kildeversjon-450-c@test.invalid'),
  ('45000000-0000-4000-8000-00000000000d', 'kildeversjon-450-d@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id, retired_at, retirement_note)
values
  ('ac450000-0000-4000-8000-00000000000b', 'human', 'human:kildeversjon-450-b', 'Kaller B',
   'Aktør uten rolletildeling, for 450.', '45000000-0000-4000-8000-00000000000b', null, null),
  ('ac450000-0000-4000-8000-00000000000c', 'human', 'human:kildeversjon-450-c', 'Kaller C',
   'Tilbaketrukket aktør med en ellers gyldig editor-tildeling, for 450.',
   '45000000-0000-4000-8000-00000000000c',
   now() - interval '1 day', 'Trukket tilbake for testene i 450.'),
  ('ac450000-0000-4000-8000-00000000000d', 'human', 'human:kildeversjon-450-d', 'Kaller D',
   'Aktør med editor-rolle avgrenset til vektendring, for 450.',
   '45000000-0000-4000-8000-00000000000d', null, null);

create temporary table fixture (name text primary key, id uuid not null) on commit drop;
grant select on fixture to authenticated;
insert into fixture (name, id)
select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'actor_c', id from provenance.actors where actor_key = 'human:kildeversjon-450-c';
insert into fixture (name, id)
select 'actor_d', id from provenance.actors where actor_key = 'human:kildeversjon-450-d';
insert into fixture (name, id)
select 'extraction', id from provenance.actors where actor_key = 'agent:evidence-extraction';

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('45000000-0000-4000-8000-00000000000c', 'editor', null, now() - interval '1 year',
   (select id from fixture where name = 'actor_d'),
   'Ellers gyldig tildeling for tilbaketrukket kaller C.'),
  ('45000000-0000-4000-8000-00000000000d', 'editor',
   (select id from fixture where name = 'weight'), now() - interval '1 year',
   (select id from fixture where name = 'actor_d'),
   'Avgrenset editor-tildeling for kaller D.');

insert into knowledge.sources
  (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('50450000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 450',
   'Testforfatter 450', (select id from fixture where name = 'actor_d'));

-- ===========================================================================
-- Del 4 — Ingen vei utenom funksjonen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"45000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
select throws_ok(
  $$
    insert into knowledge.source_versions
      (source_id, retrieved_at, retrieved_from, retrieved_by_actor_id)
    values ('50450000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/450-direkte',
            'ac450000-0000-4000-8000-00000000000d')
  $$,
  '42501', null,
  'en innlogget bruker kan ikke omgå funksjonen ved å skrive direkte i knowledge.source_versions'
);
reset role;

-- ===========================================================================
-- Del 5 — Autorisasjonsgrenene, prøvd med den faktiske funksjonen
-- ===========================================================================
create function pg_temp.register(
  p_from text,
  p_content text default 'Representasjonen slik den ble hentet.',
  p_source uuid default '50450000-0000-4000-8000-000000000001',
  p_at timestamptz default null,
  p_external text default null,
  p_storage text default null
)
  returns uuid
  language sql
as $$
  select api.create_source_version(
    p_source_id := p_source,
    p_retrieved_at := coalesce(p_at, now() - interval '1 minute'),
    p_retrieved_from := p_from,
    p_retrieved_content := p_content,
    p_external_version := p_external,
    p_storage_reference := p_storage
  );
$$;

-- A — ingen aktørrad
select set_config('request.jwt.claims',
                  '{"sub":"45000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  $$select pg_temp.register('https://eksempel.invalid/450-a')$$,
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en kaller uten aktørrad kan ikke registrere en kildeversjon i sitt eget navn'
);
reset role;

-- B — aktør, ingen rolletildeling
select set_config('request.jwt.claims',
                  '{"sub":"45000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  $$select pg_temp.register('https://eksempel.invalid/450-b')$$,
  '42501', 'Brukeren har ikke gyldig editor-rolle.',
  'en kaller uten editor-rolle avvises'
);
reset role;

-- C — tilbaketrukket aktør
select set_config('request.jwt.claims',
                  '{"sub":"45000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select throws_ok(
  $$select pg_temp.register('https://eksempel.invalid/450-c')$$,
  '42501', 'Aktøren er trukket tilbake og kan ikke registrere nytt innhold.',
  'en tilbaketrukket aktør avvises selv med en ellers gyldig tildeling'
);
reset role;

-- D — avgrenset editor-tildeling. En kildeversjon er, som kilden selv, ikke
-- avgrenset til noe klinisk begrep, så avgrensningen skal ikke stenge her
-- (samme grense som api.create_source(...) trekker).
select set_config('request.jwt.claims',
                  '{"sub":"45000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
select lives_ok(
  $$select pg_temp.register('https://eksempel.invalid/450-d')$$,
  'en editor avgrenset til ett begrep kan registrere en kildeversjon: versjonen er ikke selv avgrenset'
);
reset role;

-- ===========================================================================
-- Del 6 — Konsekvensen: raden, hashen og auditraden
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"45000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
select lives_ok(
  $$
    select pg_temp.register(
      'https://eksempel.invalid/450-konsekvens',
      'antidep',
      p_external := 'utgave 3',
      p_storage := 'lagring://testbøtte/450.xml'
    )
  $$,
  'en gyldig registrering går gjennom'
);
reset role;

select is(
  (select content_hash from knowledge.source_versions
   where retrieved_from = 'https://eksempel.invalid/450-konsekvens'),
  knowledge.source_version_content_hash('antidep'),
  'databasen hashet nøyaktig den representasjonen kalleren oppga'
);
select is(
  (select retrieved_by_actor_id from knowledge.source_versions
   where retrieved_from = 'https://eksempel.invalid/450-konsekvens'),
  'ac450000-0000-4000-8000-00000000000d'::uuid,
  'raden er attribuert til kallerens egen aktør, ikke til en oppgitt verdi'
);
select is(
  (select external_version from knowledge.source_versions
   where retrieved_from = 'https://eksempel.invalid/450-konsekvens'),
  'utgave 3',
  'kildens eget versjonsmerke lagres slik det ble oppgitt'
);
select is(
  (select storage_reference from knowledge.source_versions
   where retrieved_from = 'https://eksempel.invalid/450-konsekvens'),
  'lagring://testbøtte/450.xml',
  'en lagret kopi kan registreres ved siden av hashen, men er ikke påkrevd'
);

select is(
  (select count(*)::integer from audit.events e
   join knowledge.source_versions v on v.id = e.object_id
   where v.retrieved_from = 'https://eksempel.invalid/450-konsekvens'
     and e.operation = 'source_version_registered'),
  1,
  'registreringen etterlater nøyaktig én auditrad'
);
select is(
  (select e.actor_id from audit.events e
   join knowledge.source_versions v on v.id = e.object_id
   where v.retrieved_from = 'https://eksempel.invalid/450-konsekvens'
     and e.operation = 'source_version_registered'),
  'ac450000-0000-4000-8000-00000000000d'::uuid,
  'auditraden peker på aktøren som faktisk hentet representasjonen'
);
select is(
  (select e.object_schema || '.' || e.object_table from audit.events e
   join knowledge.source_versions v on v.id = e.object_id
   where v.retrieved_from = 'https://eksempel.invalid/450-konsekvens'
     and e.operation = 'source_version_registered'),
  'knowledge.source_versions',
  'auditraden peker på riktig objekt, avledet av operasjonen og ikke oppgitt ved siden av den'
);
select is(
  (select e.new_revision_or_snapshot ->> 'content_hash' from audit.events e
   join knowledge.source_versions v on v.id = e.object_id
   where v.retrieved_from = 'https://eksempel.invalid/450-konsekvens'
     and e.operation = 'source_version_registered'),
  knowledge.source_version_content_hash('antidep'),
  'snapshotet bevarer hashen, slik at en senere endring ville vært synlig'
);
-- Den hentede representasjonen skal ikke ligge i auditsporet. Snapshotet er
-- hele raden, og raden inneholder bevisst ikke innholdet: det er hashen og
-- adressen som er sporet (migrasjon 003), og et audittabell full av
-- kildefulltekst ville vært en kopi av kilden ingen har tatt stilling til.
select is_empty(
  $$
    select e.id from audit.events e
    join knowledge.source_versions v on v.id = e.object_id
    where v.retrieved_from = 'https://eksempel.invalid/450-konsekvens'
      and e.new_revision_or_snapshot::text like '%Representasjonen slik den ble hentet%'
  $$,
  'auditsporet inneholder hashen, ikke selve representasjonen'
);

-- ===========================================================================
-- Del 7 — Avvisningene
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"45000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;

select throws_ok(
  $$select pg_temp.register('https://eksempel.invalid/450-tom', '   ')$$,
  '22023', 'Den hentede representasjonen mangler, og da kan ingen kildeversjon registreres.',
  'en tom representasjon avvises: hashen av ingenting identifiserer ingenting'
);
select throws_ok(
  $$select pg_temp.register('https://eksempel.invalid/450-null', null)$$,
  '22023', 'Den hentede representasjonen mangler, og da kan ingen kildeversjon registreres.',
  'en manglende representasjon avvises på samme måte som en tom'
);
select throws_ok(
  $$select pg_temp.register('https://eksempel.invalid/450-dublett', 'antidep')$$,
  '23505', 'Nøyaktig samme innhold er allerede registrert som en kildeversjon for denne kilden.',
  'samme representasjon av samme kilde to ganger er én observasjon, ikke to'
);
select throws_ok(
  $$select pg_temp.register('   ')$$,
  '23514', null,
  'en kildeversjon uten hentaddresse avvises av tabellens egen constraint'
);
select throws_ok(
  $$select pg_temp.register(
      'https://eksempel.invalid/450-framtid', 'noe annet',
      p_at := now() + interval '1 hour')$$,
  '23514', null,
  'en kildeversjon datert fram i tid avvises'
);
select throws_ok(
  $$select pg_temp.register(
      'https://eksempel.invalid/450-ukjent-kilde', 'noe tredje',
      p_source := '50450000-0000-4000-8000-0000000000ff')$$,
  '23503', null,
  'en kildeversjon på en kilde som ikke finnes avvises'
);
reset role;

-- ===========================================================================
-- Del 8 — Observasjonen er uforanderlig også etter skriveveien
-- ===========================================================================
select throws_ok(
  $$
    update knowledge.source_versions
    set content_hash = knowledge.source_version_content_hash('noe helt annet')
    where retrieved_from = 'https://eksempel.invalid/450-konsekvens'
  $$,
  '23001', null,
  'hashen på en registrert kildeversjon kan ikke skrives om i ettertid'
);

select * from finish();
rollback;
