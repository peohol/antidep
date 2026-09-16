-- Migrasjon 012a — den klinikervennlige arbeidsflaten.
--
-- Filen dekker de fem tingene migrasjonen faktisk innfører:
--
--   * at den åpne arbeidsoversikten er lesbar uten innlogging og likevel ikke
--     bærer én eneste intern verdi,
--   * at «venter på fulltekst» er en produkttilstand og ikke en teknisk feil,
--   * at hele forløpet — forespørsel, opplasting, Antideps eget tekstuttrekk,
--     registrering, kølegging — går uten at noen oppgir en teknisk verdi,
--   * at grensene holder: uinnlogget, uten rolle, editor, admin, og
--   * at den rå diagnosen finnes, men aldri forlater databasen gjennom api.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 02000 = no_data_found.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(79);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('workflow', 'full_text_requests', 'workflow.full_text_requests finnes');
select has_table('workflow', 'full_text_intake', 'workflow.full_text_intake finnes');
select has_table('workflow', 'technical_incidents', 'workflow.technical_incidents finnes');
select has_table('workflow', 'technical_incident_events',
                 'workflow.technical_incident_events finnes');

-- De tre nye tabellene er private på nøyaktig samme måte som resten av
-- workflow: RLS, ingen grants, ingen policy. Originalfilen i innboksen er den
-- samme gjengivelsesgrensen som biblioteket bærer.
select is_empty(
  $$
    select t.name || ' for ' || r.role_name
    from (values ('workflow.full_text_requests'), ('workflow.full_text_intake'),
                 ('workflow.technical_incidents'), ('workflow.technical_incident_events'))
         as t(name),
         (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    where has_table_privilege(r.role_name, t.name, 'SELECT')
  $$,
  'ingen klientrolle kan lese de nye tabellene direkte'
);

-- Den åpne oversikten er den ene funksjonen anon får. Alt annet i leveransen
-- krever innlogging.
select ok(
  has_function_privilege('anon', 'api.public_work_board()', 'EXECUTE')
    and has_function_privilege('authenticated', 'api.public_work_board()', 'EXECUTE'),
  'arbeidsoversikten er lesbar uten innlogging'
);
select is_empty(
  $$
    select f.name || ' for anon'
    from (values ('api.full_text_inbox()'),
                 ('api.submit_full_text(text,text)'),
                 ('api.request_full_text(uuid,uuid[],uuid[],uuid[],text)'),
                 ('api.claim_full_text_extraction(integer)'),
                 ('api.complete_full_text_extraction(uuid,text,text)'),
                 ('api.fail_full_text_extraction(uuid,text)'),
                 ('api.technical_problem_board()'),
                 ('api.technical_problem_summary()'),
                 ('api.report_technical_problem(text,text)')) as f(name)
    where has_function_privilege('anon', f.name, 'EXECUTE')
       or has_function_privilege('public', f.name, 'EXECUTE')
       or has_function_privilege('service_role', f.name, 'EXECUTE')
  $$,
  'ingen av de innloggede veiene er åpne for anon, PUBLIC eller service_role'
);

-- Diagnosen har ingen vei ut. Kontrollen er på navnet og ikke på tilfellet:
-- en senere funksjon som begynte å lese kolonnen, ville blitt fanget her.
select is_empty(
  $$
    select p.oid::regprocedure::text
    from pg_proc p
    where p.pronamespace = 'api'::regnamespace
      and p.prosrc like '%technical_incidents%'
      and p.prosrc like '%diagnosis%'
  $$,
  'ingen api-funksjon leser den rå diagnosen'
);

-- ===========================================================================
-- Del 2 — Fikstur: en redaktør, en admin, en kliniker og en publikasjon
-- ===========================================================================
insert into auth.users (id, email) values
  ('80000000-0000-4000-8000-00000000000b', 'redaktor-800@test.invalid'),
  ('80000000-0000-4000-8000-00000000000c', 'admin-800@test.invalid'),
  ('80000000-0000-4000-8000-00000000000d', 'kliniker-800@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac800000-0000-4000-8000-00000000000b', 'human', 'human:redaktor-800',
   'Redaktør 800', 'Aktør med gyldig editor-tildeling, for 800.',
   '80000000-0000-4000-8000-00000000000b'),
  ('ac800000-0000-4000-8000-00000000000c', 'human', 'human:admin-800',
   'Admin 800', 'Aktør med gyldig admin-tildeling, for 800.',
   '80000000-0000-4000-8000-00000000000c'),
  ('ac800000-0000-4000-8000-00000000000d', 'human', 'human:kliniker-800',
   'Kliniker 800', 'Aktør uten mandat, for 800.',
   '80000000-0000-4000-8000-00000000000d');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('80000000-0000-4000-8000-00000000000b', 'editor', null, now() - interval '1 year',
   'ac800000-0000-4000-8000-00000000000b', 'Gyldig editor-tildeling for 800.'),
  ('80000000-0000-4000-8000-00000000000c', 'admin', null, now() - interval '1 year',
   'ac800000-0000-4000-8000-00000000000b', 'Gyldig admin-tildeling for 800.');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, publication_date,
                               publication_date_precision, created_by_actor_id)
values ('80000000-0000-4000-8000-000000000001', 'journal_article',
        'Arbeidsflatens testartikkel om vektendring', 'Testforfatter 800',
        '2019-01-01', 'year', 'ac800000-0000-4000-8000-00000000000b');

insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
values ('80000000-0000-4000-8000-000000000001', 'doi', '10.1234/antidep.800');

create function pg_temp.readable_800() returns text language sql immutable as $$
  select repeat(
    'Patients with major depressive disorder were randomised to treatment.'
    || chr(10), 80)
    || 'Table 1 Baseline characteristics' || chr(10)
    || 'Age (years) 42.1 41.8' || chr(10)
    || 'Weight (kg) 74.2 73.9' || chr(10)
    || 'BMI (kg/m2) 25.1 24.8' || chr(10)
$$;
create function pg_temp.bound_800() returns text language sql immutable as $$
  select 'doi: 10.1234/antidep.800' || chr(10) || pg_temp.readable_800()
$$;

create temporary table fixture (name text primary key, value text not null) on commit drop;
grant select, insert on fixture to anon, authenticated;
insert into fixture (name, value) values
  ('pdf', encode(convert_to('%PDF-1.4' || chr(10) || 'Syntetisk fulltekst for 800.', 'UTF8'),
                 'base64')),
  ('ikke_pdf', encode(convert_to('<article>ikke en pdf</article>', 'UTF8'), 'base64'));

create temporary table result (label text primary key, payload jsonb not null) on commit drop;
grant select, insert on result to anon, authenticated;

-- Avgrensningen leses ut av katalogen mens prøven fortsatt er privilegert.
-- `authenticated` har ingen tilgang til catalog, og det er nettopp poenget: en
-- redaktør velger virkestoff og endepunkt gjennom den redaksjonelle
-- lesemodellen, ikke ved å lese katalogtabellene.
create temporary table scope (
  label text primary key,
  drug_ids uuid[] not null,
  outcome_ids uuid[] not null,
  population_ids uuid[] not null
) on commit drop;
grant select on scope to authenticated;
-- Katalogens id-er er databasegenererte og dermed nye i hver database. De leses
-- derfor her framfor å skrives inn som konstanter.
insert into scope (label, drug_ids, outcome_ids, population_ids)
select 'valgt',
       (select array_agg(id) from catalog.drugs where canonical_name = 'sertralin'),
       (select array_agg(id) from catalog.clinical_concepts
        where concept_type = 'outcome' and canonical_label = 'vektendring'),
       (select array_agg(id) from catalog.populations
        where canonical_label = 'voksne med depressiv lidelse');

-- ===========================================================================
-- Del 3 — Grensene rundt fulltekstinnboksen
-- ===========================================================================
set local role anon;
select throws_ok(
  $$select api.full_text_inbox()$$,
  '42501', null,
  'en uinnlogget kaller kommer ikke til fulltekstinnboksen'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
select throws_ok(
  $$select api.full_text_inbox()$$,
  '42501', 'Brukeren har ikke gyldig editor- eller admin-rolle.',
  'en innlogget kliniker uten mandat kommer ikke til fulltekstinnboksen'
);
select throws_ok(
  $$select api.technical_problem_board()$$,
  '42501', 'Brukeren har ikke gyldig admin-rolle.',
  'en kliniker uten admin-mandat kommer ikke til den tekniske oversikten'
);
select is(
  (api.technical_problem_summary() ->> 'visible')::boolean,
  false,
  'tellingen svarer stille «ikke synlig» framfor å avvise en vanlig bruker'
);
reset role;

-- ===========================================================================
-- Del 4 — «Venter på fulltekst» er en produkttilstand
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;

insert into result select 'request', api.request_full_text(
  '80000000-0000-4000-8000-000000000001', (select drug_ids from scope where label = 'valgt'), (select outcome_ids from scope where label = 'valgt'));
insert into result select 'request_again', api.request_full_text(
  '80000000-0000-4000-8000-000000000001', (select drug_ids from scope where label = 'valgt'), (select outcome_ids from scope where label = 'valgt'));

-- Avgrensningen kontrolleres der den kan rettes, ikke først når oppgaven
-- bygges.
select throws_ok(
  $$select api.request_full_text(
      '80000000-0000-4000-8000-000000000001',
      array['80000000-0000-4000-8000-0000000000ee']::uuid[],
      (select outcome_ids from scope where label = 'valgt'))$$,
  '22023', 'Ett av virkestoffene finnes ikke i katalogen.',
  'en avgrensning med et ukjent virkestoff avvises ved forespørselen'
);
reset role;

select is(
  (select (payload ->> 'requested')::boolean from result where label = 'request'),
  true,
  'første forespørsel oppretter ventingen'
);
select is(
  (select (payload ->> 'requested')::boolean from result where label = 'request_again'),
  false,
  'den samme artikkelen etterspurt to ganger er én forespørsel'
);
select is(
  (select r.retrieved_from from workflow.full_text_requests r
   where r.source_id = '80000000-0000-4000-8000-000000000001'),
  'https://doi.org/10.1234/antidep.800',
  'adressen utledes av kildens egen DOI framfor å bli spurt om'
);

-- En PMID utledes bevisst ikke: PubMed viser sammendraget og ikke dokumentet,
-- så en utledet PubMed-adresse ville pekt et sted fullteksten ikke er å finne.
-- Da er det riktigere å be om adressen enn å gjette den.
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('80000000-0000-4000-8000-000000000003', 'journal_article',
        'En artikkel som bare har PMID', 'Testforfatter 800',
        'ac800000-0000-4000-8000-00000000000b');
insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
values ('80000000-0000-4000-8000-000000000003', 'pmid', '11111111');

select is(
  workflow.source_retrieval_address('80000000-0000-4000-8000-000000000003'),
  null,
  'en PMID blir ingen utledet adresse — en PubMed-side er ikke dokumentet'
);

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  $$select api.request_full_text(
      '80000000-0000-4000-8000-000000000003',
      (select drug_ids from scope where label = 'valgt'),
      (select outcome_ids from scope where label = 'valgt'))$$,
  '22023', 'Kilden har ingen registrert DOI, så Antidep kan ikke utlede hvor fullteksten hentes fra.',
  'og da spør Antidep om adressen framfor å oppgi en den ikke vet'
);

-- Den samme artikkelen med en *annen* avgrensning er en annen bestilling. Et
-- stille ja her ville latt arbeidet forsvinne uten at noen merket det.
select throws_ok(
  $$select api.request_full_text(
      '80000000-0000-4000-8000-000000000001',
      (select drug_ids from scope where label = 'valgt'),
      (select outcome_ids from scope where label = 'valgt'),
      (select population_ids from scope where label = 'valgt'))$$,
  '23001', 'Antidep venter allerede på denne artikkelen, med en annen avgrensning.',
  'en annen avgrensning på den samme artikkelen avvises framfor å svelges stille'
);

-- Og den samme avgrensningen skrevet i en annen rekkefølge er den samme
-- bestillingen: `{a,b}` og `{b,a,b}` er den samme redaksjonelle avgrensningen.
insert into result select 'request_reordered', api.request_full_text(
  '80000000-0000-4000-8000-000000000001',
  (select drug_ids || drug_ids from scope where label = 'valgt'),
  (select outcome_ids from scope where label = 'valgt'));
reset role;

select is(
  (select (payload ->> 'requested')::boolean from result where label = 'request_reordered'),
  false,
  'den samme avgrensningen skrevet på nytt er fortsatt én forespørsel'
);

-- Og slik ser det ut for en uinnlogget: planlagt arbeid som venter på
-- fullteksten, med virkestoffet og ingenting annet.
set local role anon;
insert into result select 'board_waiting', jsonb_build_object('items', api.public_work_board());
reset role;

select is(
  (select jsonb_array_length(payload -> 'items') from result where label = 'board_waiting'),
  1,
  'den åpne oversikten viser den ventende artikkelen'
);
select is(
  (select payload -> 'items' -> 0 ->> 'status' from result where label = 'board_waiting'),
  'planned',
  'en artikkel som mangler, står som planlagt arbeid'
);
select is(
  (select (payload -> 'items' -> 0 ->> 'waiting_for_full_text')::boolean
   from result where label = 'board_waiting'),
  true,
  'og den sier at det som står i veien, er at fullteksten mangler'
);
select is(
  (select payload -> 'items' -> 0 -> 'subjects' ->> 0 from result where label = 'board_waiting'),
  'sertralin',
  'virkestoffet er med, fordi det er det eneste her som er klinisk interessant'
);

-- Ingen intern verdi forlater databasen her. Kontrollen er på nøkkelnavnene
-- framfor på verdiene: en senere utvidelse som la på en tittel eller en rolle,
-- ville blitt fanget.
select is(
  (select array_agg(k order by k)
   from result, lateral jsonb_object_keys(payload -> 'items' -> 0) as k
   where label = 'board_waiting'),
  array['activity', 'reference', 'status', 'subjects', 'updated_at', 'waiting_for_full_text'],
  'den åpne oversikten bærer nøyaktig seks felter, og ingen av dem er interne'
);
select ok(
  (select payload -> 'items' -> 0 ->> 'reference' from result where label = 'board_waiting')
    not in (select id::text from workflow.full_text_requests),
  'referansen er et avtrykk av raden og ikke radens egen id'
);

-- «Venter på fulltekst» er ikke et teknisk problem, og skal ikke få merket i
-- navigasjonen til å lyse.
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select is(
  (api.technical_problem_summary() ->> 'unresolved')::int,
  0,
  'en artikkel som mangler, teller ikke som et teknisk problem'
);
reset role;

-- ===========================================================================
-- Del 5 — Opplastingen: ett valg, og ingen tekniske verdier
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;

insert into result select 'inbox', jsonb_build_object('items', api.full_text_inbox());

-- Innboksen sier hvilken artikkel som mangler, og ingenting mer.
select is(
  (select array_agg(k order by k)
   from result, lateral jsonb_object_keys(payload -> 'items' -> 0) as k
   where label = 'inbox'),
  array['authors', 'previous_rejection', 'published_year', 'reference', 'requested_at',
        'state', 'title'],
  'innboksen bærer bibliografien og tilstanden, og ingen teknisk verdi'
);
select is(
  (select payload -> 'items' -> 0 ->> 'title' from result where label = 'inbox'),
  'Arbeidsflatens testartikkel om vektendring',
  'og den sier hvilken artikkel det gjelder, i klartekst'
);
select is(
  (select payload -> 'items' -> 0 ->> 'state' from result where label = 'inbox'),
  'needs_upload',
  'tilstanden er «last opp», ikke en teknisk kode'
);

-- En fil som ikke er en PDF, stoppes av bytene sine.
select throws_ok(
  format(
    $$select api.submit_full_text(%L, %L)$$,
    (select payload -> 'items' -> 0 ->> 'reference' from result where label = 'inbox'),
    (select value from fixture where name = 'ikke_pdf')
  ),
  '22023', 'Originaldokumentet er ikke en PDF.',
  'en fil som ikke er en PDF, avvises på signaturen og ikke på navnet'
);

insert into result select 'submitted', api.submit_full_text(
  (select payload -> 'items' -> 0 ->> 'reference' from result where label = 'inbox'),
  (select value from fixture where name = 'pdf'));
insert into result select 'submitted_again', api.submit_full_text(
  (select payload -> 'items' -> 0 ->> 'reference' from result where label = 'inbox'),
  (select value from fixture where name = 'pdf'));
reset role;

select is(
  (select (payload ->> 'accepted')::boolean from result where label = 'submitted'),
  true,
  'filen tas imot'
);
select is(
  (select (payload ->> 'accepted')::boolean from result where label = 'submitted_again'),
  false,
  'den samme filen sendt inn igjen er det samme arbeidet'
);
select is(
  (select i.sha256 from workflow.full_text_intake i),
  knowledge.source_document_fingerprint(
    decode((select value from fixture where name = 'pdf'), 'base64')),
  'fingeravtrykket er filens, beregnet av databasen'
);

-- For den uinnloggede er det nå Antidep som arbeider, ikke noe som venter.
set local role anon;
insert into result select 'board_processing', jsonb_build_object('items', api.public_work_board());
reset role;

select is(
  (select payload -> 'items' -> 0 ->> 'status' from result where label = 'board_processing'),
  'in_progress',
  'når filen er levert, står arbeidet som pågående'
);
select is(
  (select (payload -> 'items' -> 0 ->> 'waiting_for_full_text')::boolean
   from result where label = 'board_processing'),
  false,
  'og ventingen er over'
);

-- ===========================================================================
-- Del 6 — Antideps eget tekstuttrekk, og kølegging av neste ledd
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;

insert into result select 'claim', api.claim_full_text_extraction(600);

select is(
  (select (payload ->> 'available')::boolean from result where label = 'claim'),
  true,
  'Antideps egen arbeider får oppdraget'
);
select is(
  (select payload -> 'recipe' ->> 'tool' from result where label = 'claim'),
  'pdftotext',
  'og får oppskriften av Antidep framfor å velge den selv'
);

insert into result select 'completed', api.complete_full_text_extraction(
  (select (payload ->> 'handle')::uuid from result where label = 'claim'),
  pg_temp.bound_800(),
  '24.02.0');
reset role;

select is(
  (select payload ->> 'status' from result where label = 'completed'),
  'registered',
  'fullteksten registreres'
);
select is(
  (select r.state::text from workflow.full_text_requests r
   where r.source_id = '80000000-0000-4000-8000-000000000001'),
  'fulfilled',
  'og ventingen lukkes'
);
select is(
  (select i.content from workflow.full_text_intake i),
  null,
  'originalfilen blir ikke liggende igjen i innboksen'
);
select is(
  (select count(*)::int from knowledge.source_versions sv
   where sv.source_id = '80000000-0000-4000-8000-000000000001'
     and sv.representation = 'full_text'),
  1,
  'kildeversjonen er registrert gjennom den vanlige veien'
);
select is(
  (select count(*)::int from knowledge.full_text_readability_checks c
   join knowledge.source_versions sv on sv.id = c.source_version_id
   where sv.source_id = '80000000-0000-4000-8000-000000000001'),
  1,
  'lesbarhetskontrollen er kjørt og registrert, som i den gamle veien'
);
select is(
  (select p.binding_basis::text from knowledge.source_document_publications p
   where p.source_id = '80000000-0000-4000-8000-000000000001'),
  'doi',
  'og publikasjonstilhørigheten er kontrollert på kildens DOI'
);
select is(
  (select (payload ->> 'work_enqueued')::boolean from result where label = 'completed'),
  true,
  'neste ledd legges i køen av seg selv'
);
select is(
  (select j.agent_role::text from workflow.pipeline_jobs j),
  'evidence_extraction',
  'og oppgaven er ekstraksjonen av nettopp denne artikkelen'
);
select is(
  (select workflow.manifest_uuids(j.input_manifest, 'drug_ids') from workflow.pipeline_jobs j),
  (select drug_ids from scope where label = 'valgt'),
  'med den avgrensningen forespørselen alt bar, uten at noen ble spurt igjen'
);

-- Og for den uinnloggede: arbeidet er planlagt, uten at noe teknisk er synlig.
set local role anon;
insert into result select 'board_queued', jsonb_build_object('items', api.public_work_board());
reset role;

select is(
  (select payload -> 'items' -> 0 ->> 'activity' from result where label = 'board_queued'),
  'findings',
  'oversikten sier hva slags arbeid det er, i produktets egne ord'
);
select is(
  (select payload -> 'items' -> 0 ->> 'status' from result where label = 'board_queued'),
  'planned',
  'og at det er planlagt'
);
select is_empty(
  $$
    select 1 from result, lateral jsonb_array_elements(payload -> 'items') as item
    where label = 'board_queued'
      and (item::text like '%evidence_extraction%'
           or item::text like '%Arbeidsflatens testartikkel%'
           or item::text like '%10.1234%')
  $$,
  'og hverken agentrollen, artikkeltittelen eller kildens identitet står der'
);

-- ===========================================================================
-- Del 7 — En avvist fil er en produkttilstand, ikke en teknisk feil
-- ===========================================================================
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('80000000-0000-4000-8000-000000000002', 'journal_article',
        'En annen testartikkel som filen ikke er', 'Testforfatter 800',
        'ac800000-0000-4000-8000-00000000000b');
insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
values ('80000000-0000-4000-8000-000000000002', 'doi', '10.1234/antidep.800b');

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;

insert into result select 'request_b', api.request_full_text(
  '80000000-0000-4000-8000-000000000002', (select drug_ids from scope where label = 'valgt'), (select outcome_ids from scope where label = 'valgt'));
insert into result select 'inbox_b', jsonb_build_object('items', api.full_text_inbox());
insert into result select 'submitted_b', api.submit_full_text(
  (select payload -> 'items' -> 0 ->> 'reference' from result where label = 'inbox_b'),
  (select value from fixture where name = 'pdf'));
insert into result select 'claim_b', api.claim_full_text_extraction(600);
insert into result select 'rejected_b', api.complete_full_text_extraction(
  (select (payload ->> 'handle')::uuid from result where label = 'claim_b'),
  pg_temp.bound_800(),
  '24.02.0');
insert into result select 'inbox_b_after', jsonb_build_object('items', api.full_text_inbox());
reset role;

select is(
  (select payload ->> 'status' from result where label = 'rejected_b'),
  'rejected',
  'en fil som ikke kan vises å være artikkelen, avvises'
);
select is(
  (select payload ->> 'rejection' from result where label = 'rejected_b'),
  'not_this_article',
  'med en lukket grunn flaten kan oversette, og ingen rå årsak'
);
select is(
  (select payload -> 'items' -> 0 ->> 'previous_rejection'
   from result where label = 'inbox_b_after'),
  'not_this_article',
  'og innboksen ber om en ny fil, med den samme grunnen'
);
select is(
  (select payload -> 'items' -> 0 ->> 'state' from result where label = 'inbox_b_after'),
  'needs_upload',
  'artikkelen venter igjen på en fil'
);

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select is(
  (api.technical_problem_summary() ->> 'unresolved')::int,
  0,
  'en avvist fil er ikke et teknisk problem'
);
reset role;

-- ===========================================================================
-- Del 8 — En teknisk svikt er noe annet, og admin ser den uten diagnosen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
-- Den avviste artikkelen venter igjen, og redaktøren prøver en fil på nytt.
insert into result select 'submitted_c', api.submit_full_text(
  (select payload -> 'items' -> 0 ->> 'reference' from result where label = 'inbox_b_after'),
  (select value from fixture where name = 'pdf'));
insert into result select 'claim_c', api.claim_full_text_extraction(600);
insert into result select 'failed_c', api.fail_full_text_extraction(
  (select (payload ->> 'handle')::uuid from result where label = 'claim_c'), 'tool_missing');
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
insert into result select 'board_admin', jsonb_build_object('items', api.technical_problem_board());
select is(
  (api.technical_problem_summary() ->> 'unresolved')::int,
  1,
  'en mislykket automatisk prosess er et uløst teknisk problem'
);
reset role;

select is(
  (select array_agg(k order by k)
   from result, lateral jsonb_object_keys(payload -> 'items' -> 0) as k
   where label = 'board_admin'),
  array['area', 'first_seen_at', 'last_seen_at', 'occurrence_count', 'ongoing', 'reference',
        'resolved_at'],
  'den tekniske oversikten bærer område og tidspunkt, og aldri diagnosen'
);
select is(
  (select payload -> 'items' -> 0 ->> 'area' from result where label = 'board_admin'),
  'full_text_intake',
  'og den sier hvilket område som har problemer'
);
select ok(
  (select (payload -> 'items' -> 0 ->> 'ongoing')::boolean from result where label = 'board_admin'),
  'og at det fortsatt pågår'
);
select is_empty(
  $$
    select 1 from result, lateral jsonb_array_elements(payload -> 'items') as item
    where label = 'board_admin' and item::text like '%verktøyet%'
  $$,
  'diagnosen følger ikke med ut'
);
select ok(
  (select ti.diagnosis from workflow.technical_incidents ti
   where ti.area = 'full_text_intake') like '%fant ikke verktøyet%',
  'men den er bevart i databasen, der Claude Code og ChatGPT kan lese den'
);

-- Problemet lukkes av at det samme arbeidet går gjennom, og ikke av at noen
-- klikker det bort.
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'claim_d', api.claim_full_text_extraction(600);
insert into result select 'rejected_d', api.complete_full_text_extraction(
  (select (payload ->> 'handle')::uuid from result where label = 'claim_d'),
  pg_temp.bound_800(),
  '24.02.0');
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select is(
  (api.technical_problem_summary() ->> 'unresolved')::int,
  0,
  'og det lukkes når uttrekket kommer gjennom'
);
reset role;

select is(
  (select count(*)::int from workflow.technical_incident_events),
  2,
  'begge overgangene er bevart som append-only spor'
);

-- ===========================================================================
-- Del 9 — Selvmeldingen fra en brukerflate
-- ===========================================================================
set local role anon;
select throws_ok(
  $$select api.report_technical_problem('work_queue', 'unavailable')$$,
  '42501', null,
  'en uinnlogget besøkende kan ikke få merket til å lyse'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
select throws_ok(
  $$select api.report_technical_problem('work_queue', 'not_authorized')$$,
  '22023', 'Ukjent svikttype.',
  'en manglende rettighet er ikke et teknisk problem og kan ikke meldes som det'
);
do $$ begin perform api.report_technical_problem('work_queue', 'unavailable'); end $$;
reset role;

select is(
  (select ti.self_reported from workflow.technical_incidents ti where ti.area = 'work_queue'),
  true,
  'en selvmelding merkes som nettopp det: hva klienten SA, ikke hva databasen SÅ'
);
select ok(
  (select ti.diagnosis from workflow.technical_incidents ti where ti.area = 'work_queue')
    like '%observability%',
  'og Antidep skriver setningen selv, uten en videreformidlet feiltekst'
);

-- ===========================================================================
-- Del 10 — Historikken er databasens, ikke flatens
-- ===========================================================================
create temporary table cred (label text primary key, secret text) on commit drop;
grant select on cred to anon;
insert into cred select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman');

set local role anon;
insert into result select 'claimed_job', api.claim_pipeline_job(
  'agent-identity:evidence-extraction-01', (select secret from cred where label = 'extractor'),
  'evidence_extraction', 900);
reset role;

select is(
  (select (payload ->> 'claimed')::boolean from result where label = 'claimed_job'),
  false,
  'den eksterne agentoppgaven tas ikke av en intern kjører'
);

-- En fullført jobb er historikk, og den står i den åpne oversikten som fullført
-- uten at noen flate husker den.
with opened as (
  insert into provenance.agent_runs
    (agent_identity_id, actor_id, agent_role, provider, model, model_version,
     prompt_template_version, pipeline_version, input_manifest,
     status, completed_at, output_manifest)
  select ai.id, ai.actor_id, 'evidence_extraction', 'antidep', 'proposal-grounded-extraction',
         '1.1.0', 'evidence-extraction/proposal/1', 'antidep-evidence/1',
         '{"mode": "test-800"}'::jsonb, 'succeeded', now(), '{"registered": true}'::jsonb
  from provenance.agent_identities ai
  where ai.identity_key = 'agent-identity:evidence-extraction-01'
  returning id, agent_identity_id
)
update workflow.pipeline_jobs j
set state = 'succeeded',
    leased_by_agent_identity_id = opened.agent_identity_id,
    lease_token = gen_random_uuid(),
    agent_run_id = opened.id,
    output_manifest = '{"registered": true}'::jsonb,
    completed_at = now()
from opened
where j.agent_role = 'evidence_extraction';

set local role anon;
insert into result select 'board_done', jsonb_build_object('items', api.public_work_board());
reset role;

select is(
  (select item ->> 'status'
   from result, lateral jsonb_array_elements(payload -> 'items') as item
   where label = 'board_done' and item ->> 'activity' = 'findings'),
  'done',
  'fullført arbeid står som fullført historikk, hentet av databasens egen tilstand'
);

-- ===========================================================================
-- Del 10b — Tilbaketrekkingen, som gjør en feil bestilling til noe man kommer
--           videre fra
-- ===========================================================================
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('80000000-0000-4000-8000-000000000004', 'journal_article',
        'En artikkel som viste seg å være feil', 'Testforfatter 800',
        'ac800000-0000-4000-8000-00000000000b');
insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
values ('80000000-0000-4000-8000-000000000004', 'doi', '10.1234/antidep.800d');

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'request_d', api.request_full_text(
  '80000000-0000-4000-8000-000000000004',
  (select drug_ids from scope where label = 'valgt'),
  (select outcome_ids from scope where label = 'valgt'));

select throws_ok(
  format($$select api.withdraw_full_text_request(%L, '')$$,
         (select payload ->> 'reference' from result where label = 'request_d')),
  '22023', 'En tilbaketrekking skal ha en begrunnelse.',
  'en tilbaketrekking uten begrunnelse avvises'
);

insert into result select 'withdrawn_d', api.withdraw_full_text_request(
  (select payload ->> 'reference' from result where label = 'request_d'),
  'Artikkelen viste seg å være feil.');

-- Og etterpå er veien åpen for den avgrensningen som faktisk skulle vært der.
insert into result select 'request_d2', api.request_full_text(
  '80000000-0000-4000-8000-000000000004',
  (select drug_ids from scope where label = 'valgt'),
  (select outcome_ids from scope where label = 'valgt'),
  (select population_ids from scope where label = 'valgt'));
reset role;

select is(
  (select payload ->> 'state' from result where label = 'withdrawn_d'),
  'withdrawn',
  'en åpen forespørsel kan trekkes tilbake med en begrunnelse'
);
select is(
  (select (payload ->> 'requested')::boolean from result where label = 'request_d2'),
  true,
  'og en ny bestilling med en annen avgrensning kommer gjennom etterpå'
);

-- ===========================================================================
-- Del 11 — En automatisk oppgave som stopper, er et teknisk problem
--
-- Og den er det på en annen måte enn «venter på fulltekst»: den står som
-- «stoppet» i den åpne oversikten, uten at noen får vite hvorfor, og som et
-- uløst problem i admins egen oversikt, uten at noen får vite det der heller.
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'internal_job', api.enqueue_pipeline_job(
  'evidence_extraction', 'intern-jobb:800', '{"mode": "test-800"}'::jsonb);
reset role;

-- Tre uttak og tre mislykkede forsøk: fail-closed gjør jobben stående framfor å
-- prøve den i det uendelige.
do $$
declare
  v_secret text;
  v_claim jsonb;
begin
  select secret into v_secret from cred where label = 'extractor';
  set local role anon;
  for i in 1..3 loop
    v_claim := api.claim_pipeline_job(
      'agent-identity:evidence-extraction-01', v_secret, 'evidence_extraction', 900);
    perform api.fail_pipeline_job(
      'agent-identity:evidence-extraction-01', v_secret,
      (v_claim ->> 'pipeline_job_id')::uuid, (v_claim ->> 'lease_token')::uuid,
      'Prøvens egen syntetiske feil.');
  end loop;
  reset role;
end;
$$;

select is(
  (select j.state::text from workflow.pipeline_jobs j where j.job_key = 'intern-jobb:800'),
  'failed',
  'en jobb med oppbrukte forsøk blir stående som mislykket'
);

set local role anon;
insert into result select 'board_failed', jsonb_build_object('items', api.public_work_board());
reset role;

select is(
  (select count(*)::int
   from result, lateral jsonb_array_elements(payload -> 'items') as item
   where label = 'board_failed' and item ->> 'status' = 'failed'),
  1,
  'og den står som stoppet i den åpne oversikten'
);
select is_empty(
  $$
    select 1 from result, lateral jsonb_array_elements(payload -> 'items') as item
    where label = 'board_failed' and item::text like '%syntetiske feil%'
  $$,
  'uten at begrunnelsen følger med ut'
);

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
insert into result select 'board_admin2', jsonb_build_object('items', api.technical_problem_board());
reset role;

select is(
  (select count(*)::int
   from result, lateral jsonb_array_elements(payload -> 'items') as item
   where label = 'board_admin2'
     and item ->> 'area' = 'automatic_task'
     and (item ->> 'ongoing')::boolean),
  1,
  'admin ser at en automatisk oppgave har stoppet'
);
select ok(
  (select ti.diagnosis from workflow.technical_incidents ti where ti.area = 'automatic_task')
    like '%pipeline_jobs.failure_reason%',
  'og den rå diagnosen peker teknikeren dit begrunnelsen faktisk ligger, uten å gjenta den'
);

-- ===========================================================================
-- Del 12 — Et teknisk kjørerkall, og det som lukker det
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'runner', coalesce(api.register_agent_runner(
  'proeve:800', 'Prøvekjører 800', 'claim_synthesis', 'workspace-agent/proeve-800',
  'not_exposed', 'Registrert av prøven.'), '{}'::jsonb);
reset role;

insert into workflow.agent_runner_events (connection_id, tool_name, outcome)
select c.id, 'submit_agent_answer', 'server_error'
from workflow.agent_runner_connections c
where c.connection_key = 'proeve:800';

select is(
  (select count(*)::int from workflow.technical_incidents ti
   where ti.area = 'agent_service' and ti.resolved_at is null),
  1,
  'et teknisk kjørerkall blir et uløst problem'
);

insert into workflow.agent_runner_events (connection_id, tool_name, outcome)
select c.id, 'list_pending_agent_tasks', 'ok'
from workflow.agent_runner_connections c
where c.connection_key = 'proeve:800';

select is(
  (select count(*)::int from workflow.technical_incidents ti
   where ti.area = 'agent_service' and ti.resolved_at is null),
  0,
  'og neste kall som går gjennom, lukker det'
);

select * from finish();
rollback;
