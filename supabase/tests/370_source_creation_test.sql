-- Migrasjon 007c — den kontrollerte skriveveien for å opprette en Source.
--
-- Steg 2 av «manuell adminflyt» (MVP_IMPLEMENTATION_PLAN.md §29, §74.21,
-- §74.22): «Editor oppretter Source» (§15), det første leddet i
-- admin-workflowen. Testen dekker tre ting samlet, fordi de hører til samme
-- lille skrivevei: kontrakten (hva som faktisk er eksponert), autorisasjonen
-- (knowledge.assert_editor_authorized(), prøvd i hver av sine grener) og
-- konsekvensen (raden som settes inn, og auditraden som følger den).
--
-- SQLSTATE 42501 = insufficient_privilege, 22P02 = invalid_text_representation,
-- 23514 = check_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(31);

-- ===========================================================================
-- Del 1 — Kontrakten: hva migrasjon 003a, 008a og 007c faktisk åpnet
-- ===========================================================================

select col_not_null(
  'knowledge', 'sources', 'created_by_actor_id',
  'enhver kilde er attribuert til en aktør (ANTIDEP_CONSTITUTION.md §14)'
);
select fk_ok(
  'knowledge', 'sources', 'created_by_actor_id',
  'provenance', 'actors', 'id',
  'attribusjonen peker på en normalisert aktør'
);

select enum_has_labels(
  'audit', 'event_operation',
  array[
    'claim_published', 'claim_publication_replaced', 'claim_publication_withdrawn',
    'claim_publication_rolled_back', 'role_granted', 'role_ended', 'source_created',
    'evidence_item_created', 'agent_identity_registered',
    'agent_identity_credential_issued', 'agent_identity_revoked',
    'evidence_verification_registered'
  ],
  'audit.event_operation dekker nå også kildeopprettelse, evidensregistrering, agentidentitetenes livssyklus og ekstraksjonsverifikasjon'
);

select has_function('api', 'create_source', 'api.create_source() finnes');
select has_function(
  'knowledge', 'assert_editor_authorized', 'knowledge.assert_editor_authorized() finnes'
);
select has_function('audit', 'record_source_event', 'audit.record_source_event() finnes');
select has_trigger(
  'knowledge', 'sources', 'sources_record_creation_audit_event',
  'enhver innsatt kilde auditeres'
);

-- De kontrollerte skriveveiene er de eneste funksjonene i api eller knowledge
-- en klientrolle kan kjøre. Uttømmende over begge schemaene, framfor bare et
-- oppslag på funksjonen selv: en framtidig funksjon i knowledge skal ikke
-- kunne bli kjørbar for en klientrolle ved et uhell (samme mønster som
-- 270_publication_access_test.sql). Listen utvides av den migrasjonen som
-- åpner en ny skrivevei, og bare av den.
select is_empty(
  $$
    select p.oid::regprocedure::text, r.role_name
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    where n.nspname in ('knowledge', 'api')
      and has_function_privilege(r.role_name, p.oid, 'execute')
      and p.oid::regprocedure::text not in (
        'api.create_source(text,text,text,text,text,text,text,date,text)',
        'api.create_evidence_item(uuid,text,text,text,text,uuid,text,uuid,text,text,text,text,text,text,uuid,uuid,integer,text,uuid,text,text,text,text,numeric,text,numeric,numeric,numeric,text,text)',
        -- Migrasjon 005e. De to eneste funksjonene i api som anon kan kjøre, og
        -- de rører ingen kunnskapsobjekter: de åpner og lukker en agentkjøring,
        -- og gjør ingenting før legitimasjonen er autentisert. Hvilke roller som
        -- faktisk har EXECUTE på hvilken funksjon, kontrolleres i
        -- 410_agent_identity_structure_test.sql; her er poenget at listen er
        -- uttømmende.
        'api.begin_agent_run(text,text,text,text,text,text,text,text,jsonb)',
        'api.complete_agent_run(text,text,uuid,text,jsonb,text)',
        -- Migrasjon 005g. Samme begrunnelse som de to over: en autentisert
        -- ekstraksjonsverifikator kaller den som anon, og den rører ingenting
        -- før autentiseringen og den åpne kjøringen er kontrollert. Hvilke
        -- roller som faktisk har EXECUTE, kontrolleres i
        -- 440_extraction_verification_registration_test.sql.
        'api.register_extraction_verification(text,text,uuid,uuid,text,text,text[],text,text)'
      )
  $$,
  'ingen annen funksjon i knowledge eller api enn de fem kontrollerte inngangspunktene er kjørbar for noen klientrolle'
);
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.create_source(text,text,text,text,text,text,text,date,text)'::regprocedure,
      'execute'
    )
  $$,
  'api.create_source() er kjørbar bare for authenticated, ikke for anon, service_role eller PUBLIC'
);
select ok(
  has_function_privilege(
    'authenticated',
    'api.create_source(text,text,text,text,text,text,text,date,text)'::regprocedure,
    'execute'
  ),
  'authenticated har EXECUTE på api.create_source()'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.create_source(text,text,text,text,text,text,text,date,text)'::regprocedure),
  'api.create_source() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
-- Auditskriveren skal aldri være mer privilegert enn operasjonen den
-- registrerer (samme regel som for de to auditskriverne migrasjon 008 innførte).
select ok(
  not (select p.prosecdef from pg_proc p
       where p.oid = 'audit.record_source_event()'::regprocedure),
  'audit.record_source_event() er ikke SECURITY DEFINER'
);

-- ===========================================================================
-- Del 2 — Uinnlogget og direkte tabellskriving er begge stengt (§43)
-- ===========================================================================
set local role anon;
select throws_ok(
  $$select api.create_source('journal_article', 'Anonymt forsøk', 'Anon')$$,
  '42501', null,
  'anon kan ikke opprette en kilde gjennom skriveveien'
);
select throws_ok(
  $$
    insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
    values ('journal_article', 'Anonymt forsøk', 'Anon', gen_random_uuid())
  $$,
  '42501', null,
  'anon kan ikke skrive direkte i knowledge.sources'
);
reset role;

set local role authenticated;
select throws_ok(
  $$
    insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
    values ('journal_article', 'Direkte forsøk', 'Autentisert', gen_random_uuid())
  $$,
  '42501', null,
  'en innlogget bruker kan ikke omgå funksjonen ved å skrive direkte i knowledge.sources'
);
reset role;

-- ===========================================================================
-- Del 3 — Fikstur: seks kontoer som spenner ut autorisasjonsgrenene
--
--   A  ingen aktørrad i det hele tatt
--   B  aktør, men ingen rolletildeling
--   C  aktør, tilbaketrukket, med en ellers gyldig editor-tildeling
--   D  aktør, reviewer-tildeling (ikke editor)
--   E  aktør, editor-tildeling avgrenset til «vektendring»
--   F  aktør, editor-tildeling uavgrenset, og en avsluttet tildeling ved siden av
-- ===========================================================================
insert into auth.users (id, email) values
  ('37000000-0000-4000-8000-00000000000a', 'kilde-370-a@test.invalid'),
  ('37000000-0000-4000-8000-00000000000b', 'kilde-370-b@test.invalid'),
  ('37000000-0000-4000-8000-00000000000c', 'kilde-370-c@test.invalid'),
  ('37000000-0000-4000-8000-00000000000d', 'kilde-370-d@test.invalid'),
  ('37000000-0000-4000-8000-00000000000e', 'kilde-370-e@test.invalid'),
  ('37000000-0000-4000-8000-00000000000f', 'kilde-370-f@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id, retired_at, retirement_note)
values
  ('ac370000-0000-4000-8000-00000000000b', 'human', 'human:kilde-370-b', 'Kaller B',
   'Aktør uten rolletildeling, for 370.', '37000000-0000-4000-8000-00000000000b', null, null),
  ('ac370000-0000-4000-8000-00000000000c', 'human', 'human:kilde-370-c', 'Kaller C',
   'Tilbaketrukket aktør med en ellers gyldig editor-tildeling, for 370.',
   '37000000-0000-4000-8000-00000000000c',
   now() - interval '1 day', 'Trukket tilbake for testene i 370.'),
  ('ac370000-0000-4000-8000-00000000000d', 'human', 'human:kilde-370-d', 'Kaller D',
   'Aktør med reviewer-rolle, ikke editor, for 370.', '37000000-0000-4000-8000-00000000000d',
   null, null),
  ('ac370000-0000-4000-8000-00000000000e', 'human', 'human:kilde-370-e', 'Kaller E',
   'Aktør med editor-rolle avgrenset til vektendring, for 370.',
   '37000000-0000-4000-8000-00000000000e', null, null),
  ('ac370000-0000-4000-8000-00000000000f', 'human', 'human:kilde-370-f', 'Kaller F',
   'Aktør med uavgrenset editor-rolle, for 370.', '37000000-0000-4000-8000-00000000000f',
   null, null);

create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id)
select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'actor_c', id from provenance.actors where actor_key = 'human:kilde-370-c';
insert into fixture (name, id) select 'actor_e', id from provenance.actors where actor_key = 'human:kilde-370-e';
insert into fixture (name, id) select 'actor_f', id from provenance.actors where actor_key = 'human:kilde-370-f';

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to, granted_by_actor_id, grant_reason,
   ended_by_actor_id, end_reason)
values
  ('37000000-0000-4000-8000-00000000000c', 'editor', null, now() - interval '1 year', null,
   (select id from fixture where name = 'actor_c'), 'Ellers gyldig tildeling for tilbaketrukket kaller C.',
   null, null),
  ('37000000-0000-4000-8000-00000000000d', 'reviewer', null, now() - interval '1 year', null,
   (select id from fixture where name = 'actor_e'), 'Reviewer, ikke editor, for kaller D.',
   null, null),
  ('37000000-0000-4000-8000-00000000000e', 'editor', (select id from fixture where name = 'topic'),
   now() - interval '1 year', null,
   (select id from fixture where name = 'actor_e'), 'Avgrenset editor-tildeling for kaller E.',
   null, null),
  ('37000000-0000-4000-8000-00000000000f', 'editor', null, now() - interval '1 year', null,
   (select id from fixture where name = 'actor_f'), 'Uavgrenset editor-tildeling for kaller F.',
   null, null),
  -- Ved siden av F sin gyldige tildeling: en avsluttet editor-tildeling som
  -- ikke skal telle. Uten den ville en mutasjon som leser «finnes det NOEN
  -- tildeling» framfor «finnes det en GYLDIG NÅ tildeling» ikke blitt fanget.
  ('37000000-0000-4000-8000-00000000000f', 'publisher', null,
   now() - interval '2 years', now() - interval '1 year',
   (select id from fixture where name = 'actor_f'), 'Avsluttet publisher-tildeling for kaller F.',
   (select id from fixture where name = 'actor_f'), 'Avsluttet for testene i 370.');

-- ===========================================================================
-- Del 4 — Hver avvisningsgren, prøvd med den faktiske funksjonen
-- ===========================================================================

-- A — ingen aktørrad
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  $$select api.create_source('journal_article', 'Uten aktør', 'Kaller A')$$,
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en kaller uten aktørrad avvises eksplisitt, og får ikke en kilde opprettet i sitt navn'
);
reset role;

-- B — aktør, ingen rolletildeling i det hele tatt
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  $$select api.create_source('journal_article', 'Uten rolle', 'Kaller B')$$,
  '42501', 'Brukeren har ikke gyldig editor-rolle.',
  'en aktør uten noen rolletildeling avvises med rollefeilen, ikke aktørfeilen'
);
reset role;

-- C — tilbaketrukket aktør med en ellers gyldig editor-tildeling
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select throws_ok(
  $$select api.create_source('journal_article', 'Tilbaketrukket', 'Kaller C')$$,
  '42501', 'Aktøren er trukket tilbake og kan ikke registrere nytt innhold.',
  'en tilbaketrukket aktør avvises, selv med en ellers gyldig editor-tildeling'
);
reset role;

-- D — reviewer, ikke editor
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
select throws_ok(
  $$select api.create_source('journal_article', 'Feil rolle', 'Kaller D')$$,
  '42501', 'Brukeren har ikke gyldig editor-rolle.',
  'reviewer-rollen gir ikke rett til å opprette kilder; å godkjenne og å opprette er forskjellige handlinger'
);
reset role;

-- E — editor, men avgrenset til et klinisk begrep. Kilden er ikke selv
-- avgrenset til noe (se migrasjonens hodekommentar), så dette skal LYKKES.
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select lives_ok(
  $$select api.create_source('journal_article', 'Avgrenset editor', 'Kaller E')$$,
  'en editor-tildeling avgrenset til et klinisk begrep er tilstrekkelig: en Source er ikke selv avgrenset'
);
reset role;

select is(
  (select s.created_by_actor_id from knowledge.sources s where s.title = 'Avgrenset editor'),
  (select id from fixture where name = 'actor_e'),
  'kilden fra kaller E er attribuert til kaller E sin egen aktør, ikke til en annen'
);

-- ===========================================================================
-- Del 5 — Den lykkede stien, kontrollert i detalj (kaller F, uavgrenset)
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000f"}', true);
set local role authenticated;

-- Kallet selv skjer som authenticated (det er nettopp autorisasjonen som
-- prøves); innholdet i raden verifiseres etterpå som eieren, av samme grunn
-- som lag 1 i 360_caller_authorization_test.sql: authenticated har ikke usage
-- på knowledge og kan ikke lese tilbake fra tabellen i samme setning som den
-- kaller funksjonen — det ville vært et forsøk på å omgå §43 fra innsiden av
-- en test, ikke en reell klientspørring.
select lives_ok(
  $$
    select api.create_source(
      p_source_type := 'journal_article',
      p_title := 'Fullstendig testkilde for 370',
      p_authors_or_issuer := 'Testforfatter F',
      p_publisher_or_journal := 'Testtidsskriftet',
      p_publication_date := date '2024-06-01',
      p_publication_date_precision := 'month'
    )
  $$,
  'en uavgrenset editor-tildeling oppretter kilden'
);
select lives_ok(
  $$select api.create_source('clinical_guideline', 'Minimal testkilde for 370', 'Testutgiver')$$,
  'en kilde med bare de påkrevde feltene kan opprettes'
);

-- Databasens vokabularkontroll er fasiten, ikke en klientside-gjetning
-- (felle 4 i oppgaveteksten): en verdi utenfor knowledge.source_type avvises av
-- casten inne i funksjonen.
select throws_ok(
  $$select api.create_source('preprint', 'Ukjent kildetype', 'Testforfatter')$$,
  '22P02', null,
  'en kildetype utenfor det kontrollerte vokabularet avvises av databasen, ikke antatt gyldig'
);
-- Og CHECK-constraintene på selve tabellen: en tom tittel avvises akkurat som
-- ved en direkte innsetting (090_knowledge_constraints_test.sql), gjennom
-- funksjonen og uten at funksjonen selv reimplementerer regelen.
select throws_ok(
  $$select api.create_source('journal_article', '', 'Testforfatter')$$,
  '23514', null,
  'en tom tittel avvises av knowledge.sources sin egen CHECK, ikke duplisert i funksjonen'
);

reset role;

-- Innholdet, kontrollert som eieren.
select results_eq(
  $$
    select s.source_type::text, s.title, s.authors_or_issuer, s.publisher_or_journal,
           s.publication_date::text, s.publication_date_precision::text, s.source_status::text,
           s.status_note, s.superseded_by_source_id, s.created_by_actor_id
    from knowledge.sources s
    where s.title = 'Fullstendig testkilde for 370'
  $$,
  $$
    values ('journal_article', 'Fullstendig testkilde for 370', 'Testforfatter F',
            'Testtidsskriftet', '2024-06-01', 'month', 'active', null, null::uuid,
            (select id from fixture where name = 'actor_f'))
  $$,
  'raden bærer nøyaktig det oppgitte, starter active uten status_note eller erstatter, og er attribuert til kalleren'
);

-- Valgfrie felter utelates til NULL, ikke til tomstreng eller en annen
-- standardverdi — funksjonen finner ikke på noe parameterlisten ikke oppga.
select results_eq(
  $$
    select s.publisher_or_journal, s.volume, s.issue, s.pages,
           s.publication_date, s.publication_date_precision
    from knowledge.sources s
    where s.title = 'Minimal testkilde for 370'
  $$,
  $$ values (null, null, null, null, null::date, null::knowledge.date_precision) $$,
  'valgfrie felter som ikke oppgis, forblir NULL'
);

-- ===========================================================================
-- Del 6 — Auditraden som fulgte den lykkede opprettelsen
-- ===========================================================================
select is(
  (select count(*)::integer from audit.events
   where object_id = (select s.id from knowledge.sources s
                       where s.title = 'Fullstendig testkilde for 370')),
  1,
  'opprettelsen ga nøyaktig én auditrad'
);

select results_eq(
  $$
    select e.operation::text, e.object_schema, e.object_table, e.actor_id,
           e.old_revision_or_snapshot,
           e.new_revision_or_snapshot ->> 'title',
           e.new_revision_or_snapshot ->> 'authors_or_issuer'
    from audit.events e
    where e.object_id = (select s.id from knowledge.sources s
                          where s.title = 'Fullstendig testkilde for 370')
  $$,
  $$
    values ('source_created', 'knowledge', 'sources',
            (select id from fixture where name = 'actor_f'),
            null::jsonb, 'Fullstendig testkilde for 370', 'Testforfatter F')
  $$,
  'auditraden peker på kilden, attribueres til oppretteren, har intet old-snapshot, og new-snapshotet er den faktiske raden'
);

-- ===========================================================================
-- Del 7 — Gyldighet måles på setningen, ikke på transaksjonen (§74.6)
--
-- Samme deterministiske vindu som 360_caller_authorization_test.sql: en
-- editor-tildeling trer i kraft midt i transaksjonen, og en annen utløper midt
-- i den. now() ville svart feil på begge.
-- ===========================================================================
insert into auth.users (id, email) values
  ('37000000-0000-4000-8000-000000000010', 'kilde-370-g@test.invalid'),
  ('37000000-0000-4000-8000-000000000011', 'kilde-370-h@test.invalid');

insert into provenance.actors (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac370000-0000-4000-8000-000000000010', 'human', 'human:kilde-370-g', 'Kaller G',
   'Tildeling som trer i kraft underveis, for 370.', '37000000-0000-4000-8000-000000000010'),
  ('ac370000-0000-4000-8000-000000000011', 'human', 'human:kilde-370-h', 'Kaller H',
   'Tildeling som utløper underveis, for 370.', '37000000-0000-4000-8000-000000000011');

insert into workflow.user_roles
  (user_id, role_code, valid_from, valid_to, granted_by_actor_id, grant_reason,
   ended_by_actor_id, end_reason)
values
  ('37000000-0000-4000-8000-000000000010', 'editor',
   now() + interval '250 milliseconds', null,
   'ac370000-0000-4000-8000-000000000010', 'Trer i kraft underveis, for 370.', null, null),
  ('37000000-0000-4000-8000-000000000011', 'editor',
   now() - interval '1 day', now() + interval '250 milliseconds',
   'ac370000-0000-4000-8000-000000000011', 'Utløper underveis, for 370.',
   'ac370000-0000-4000-8000-000000000011', 'Planlagt utløp under transaksjonen.');

select pg_sleep(1);

select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-000000000010"}', true);
set local role authenticated;
select lives_ok(
  $$select api.create_source('journal_article', 'Tildeling trådte i kraft underveis', 'Kaller G')$$,
  'en editor-tildeling som trådte i kraft mens transaksjonen løp, gjelder nå'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-000000000011"}', true);
set local role authenticated;
select throws_ok(
  $$select api.create_source('journal_article', 'Tildeling utløp underveis', 'Kaller H')$$,
  '42501', 'Brukeren har ikke gyldig editor-rolle.',
  'en editor-tildeling som utløp mens transaksjonen løp, gjelder ikke lenger'
);
reset role;

select set_config('request.jwt.claims', '', true);

select * from finish();

rollback;
