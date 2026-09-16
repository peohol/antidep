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

select plan(176);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('workflow', 'full_text_requests', 'workflow.full_text_requests finnes');
select has_table('workflow', 'full_text_intake', 'workflow.full_text_intake finnes');
select has_table('workflow', 'technical_incidents', 'workflow.technical_incidents finnes');
select has_table('workflow', 'technical_incident_events',
                 'workflow.technical_incident_events finnes');
select has_table('workflow', 'client_diagnostics', 'workflow.client_diagnostics finnes');

-- De tre nye tabellene er private på nøyaktig samme måte som resten av
-- workflow: RLS, ingen grants, ingen policy. Originalfilen i innboksen er den
-- samme gjengivelsesgrensen som biblioteket bærer.
select is_empty(
  $$
    select t.name || ' for ' || r.role_name
    from (values ('workflow.full_text_requests'), ('workflow.full_text_intake'),
                 ('workflow.technical_incidents'), ('workflow.technical_incident_events'),
                 ('workflow.client_diagnostics'))
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
                 ('api.resume_blocked_full_text_extractions()'),
                 ('api.technical_problem_board()'),
                 ('api.technical_problem_summary()'),
                 ('api.report_technical_problem(text,text,text,text,integer,text,uuid)'),
                 ('api.record_client_diagnostic(uuid,text,text,text,text,integer,text,text)')) as f(name)
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

-- Og det samme for råmaterialet, som en uttømmende liste: nøyaktig én
-- api-funksjon nevner tabellen i det hele tatt, og det er den som skriver til
-- den. En senere funksjon som begynte å lese den, ville blitt fanget her.
select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text)
   from pg_proc p
   where p.pronamespace = 'api'::regnamespace
     and p.prosrc like '%client_diagnostics%'),
  array['api.record_client_diagnostic(uuid,text,text,text,text,integer,text,text)'],
  'bare skriveveien nevner den rå årsaken — ingen api-funksjon leser den ut igjen'
);

-- ===========================================================================
-- Del 2 — Fikstur: en redaktør, en admin, en kliniker og en publikasjon
-- ===========================================================================
insert into auth.users (id, email) values
  ('80000000-0000-4000-8000-00000000000b', 'redaktor-800@test.invalid'),
  ('80000000-0000-4000-8000-00000000000c', 'admin-800@test.invalid'),
  ('80000000-0000-4000-8000-00000000000d', 'kliniker-800@test.invalid'),
  ('80000000-0000-4000-8000-00000000000e', 'tilbaketrukket-800@test.invalid');

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

-- En aktør som er trukket tilbake, men som fortsatt har en rolletildeling som
-- ikke er utløpt. Nettopp denne kombinasjonen er grunnen til at merket og
-- oversikten må ha den samme aktørgrensen: en svakere kontroll ett sted ville
-- latt denne brukeren lese et tall den andre veien nekter dem.
insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id,
   retired_at, retirement_note)
values
  ('ac800000-0000-4000-8000-00000000000e', 'human', 'human:tilbaketrukket-800',
   'Tilbaketrukket admin 800', 'Aktør med admin-rolle, men trukket tilbake.',
   '80000000-0000-4000-8000-00000000000e', now() - interval '1 day',
   'Trukket tilbake av prøven, for å kontrollere at grensene er de samme.');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('80000000-0000-4000-8000-00000000000b', 'editor', null, now() - interval '1 year',
   'ac800000-0000-4000-8000-00000000000b', 'Gyldig editor-tildeling for 800.'),
  ('80000000-0000-4000-8000-00000000000c', 'admin', null, now() - interval '1 year',
   'ac800000-0000-4000-8000-00000000000b', 'Gyldig admin-tildeling for 800.'),
  ('80000000-0000-4000-8000-00000000000e', 'admin', null, now() - interval '1 year',
   'ac800000-0000-4000-8000-00000000000b', 'Admin-tildeling som ennå ikke er avsluttet.');

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
-- Del 8 — En teknisk svikt er noe annet, og den blir aldri en menneskeoppgave
--
-- Dette er skillet hele leveransen står og faller på. En fil Antidep ikke får
-- behandlet fordi verktøyet mangler på maskinen, er driften som står — ikke
-- filen som er feil. Innboksen skal derfor *ikke* be om en ny PDF, filen skal
-- bli liggende, og arbeidet skal fortsette av seg selv når problemet er rettet.
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
insert into result select 'inbox_c', jsonb_build_object('items', api.full_text_inbox());
-- En blokkert rad skal ikke tas ut igjen: verktøyet mangler fortsatt, og et
-- nytt uttak ville bare brukt opp forsøkene på det samme.
insert into result select 'claim_blocked', api.claim_full_text_extraction(600);
reset role;

select is(
  (select payload ->> 'state' from result where label = 'failed_c'),
  'blocked',
  'et manglende verktøy blokkerer arbeidet framfor å avvise filen'
);
select ok(
  (select i.content is not null from workflow.full_text_intake i
   where i.source_id = '80000000-0000-4000-8000-000000000002'
     and i.state = 'blocked'),
  'og filen blir liggende, slik at ingen må laste den opp på nytt'
);
select is(
  (select payload -> 'items' -> 0 ->> 'state' from result where label = 'inbox_c'),
  'blocked',
  'innboksen sier at Antidep står fast, og ber ikke om noe'
);
select is(
  (select (payload ->> 'available')::boolean from result where label = 'claim_blocked'),
  false,
  'og en blokkert fil tas ikke ut på nytt så lenge problemet står'
);

-- Og slik ser det ut for den uinnloggede: arbeidet har stoppet, og det som står
-- i veien er ikke at artikkelen mangler.
set local role anon;
insert into result select 'board_blocked', jsonb_build_object('items', api.public_work_board());
reset role;

select is(
  (select item ->> 'status'
   from result, lateral jsonb_array_elements(payload -> 'items') as item
   where label = 'board_blocked' and item ->> 'activity' = 'full_text'),
  'failed',
  'den åpne oversikten sier at arbeidet har stoppet'
);
select is(
  (select (item ->> 'waiting_for_full_text')::boolean
   from result, lateral jsonb_array_elements(payload -> 'items') as item
   where label = 'board_blocked' and item ->> 'activity' = 'full_text'),
  false,
  'og at det ikke er artikkelen det står på'
);

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

-- Problemet lukkes av at driften kommer tilbake, og ikke av at noen klikker det
-- bort — og aller minst av at noen laster opp filen på nytt.
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'resumed', api.resume_blocked_full_text_extractions();
insert into result select 'claim_d', api.claim_full_text_extraction(600);
insert into result select 'rejected_d', api.complete_full_text_extraction(
  (select (payload ->> 'handle')::uuid from result where label = 'claim_d'),
  pg_temp.bound_800(),
  '24.02.0');
reset role;

select is(
  (select (payload ->> 'resumed')::int from result where label = 'resumed'),
  1,
  'arbeidet settes i gang igjen av seg selv når verktøyet er på plass'
);
select is(
  (select (payload ->> 'available')::boolean from result where label = 'claim_d'),
  true,
  'og den samme filen tas ut igjen — ingen ble bedt om å laste den opp på nytt'
);

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select is(
  (api.technical_problem_summary() ->> 'unresolved')::int,
  0,
  'og det tekniske problemet er lukket'
);
reset role;

select is(
  (select count(*)::int from workflow.technical_incident_events),
  2,
  'begge overgangene er bevart som append-only spor'
);
select ok(
  (select e.diagnosis from workflow.technical_incident_events e
   where e.transition = 'opened') like '%fant ikke verktøyet%',
  'og hver observasjon bærer sin egen diagnose, slik at rekken kan leses senere'
);
select is(
  (select e.diagnosis from workflow.technical_incident_events e
   where e.transition = 'resolved'),
  null,
  'mens en lukking ikke er en observasjon av noe galt, og bærer ingen'
);

-- ===========================================================================
-- Del 8b — Grensen mellom teknisk svikt og produktavvisning går bare én vei
--
-- Når verktøyet faktisk har lest filen tre ganger uten å få brukbar tekst, er
-- filen svaret, og den avvises. Da er det tekniske problemet *om den raden*
-- avgjort og skal lukkes: et problem som blir stående åpent for alltid etter at
-- systemet selv har konkludert, er et problem ingen kan gjøre noe med.
--
-- Men leddet er ikke friskmeldt av det. Én rar PDF og et verktøy som er i
-- stykker, ser like ut rad for rad — derfor får leddet sin egen rad, som teller
-- oppover og lukkes av at et tekstuttrekk faktisk gir tekst.
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'inbox_e', jsonb_build_object('items', api.full_text_inbox());
insert into result select 'submitted_e', api.submit_full_text(
  (select payload -> 'items' -> 0 ->> 'reference' from result where label = 'inbox_e'),
  (select value from fixture where name = 'pdf'));

-- Tre ganger der verktøyet kjørte og ikke fikk brukbar tekst ut av filen.
do $$
declare
  v_claim jsonb;
begin
  for i in 1..3 loop
    v_claim := api.claim_full_text_extraction(600);
    perform api.fail_full_text_extraction((v_claim ->> 'handle')::uuid, 'tool_failed');
  end loop;
end;
$$;

-- Og det fjerde uttaket, der grensen passeres.
insert into result select 'claim_after_three', api.claim_full_text_extraction(600);
reset role;

-- Raden identifiseres av håndtaket opplastingen svarte med. Alt i prøven skjer
-- i én transaksjon, så now() er det samme for hver rad: en sortering på
-- tidspunkt ville pekt på en vilkårlig av dem.
select is(
  (select i.state::text from workflow.full_text_intake i
   where i.reference = (select payload ->> 'reference' from result where label = 'submitted_e')),
  'rejected',
  'tre mislykkede kjøringer på den samme filen gjør filen til svaret'
);
select is(
  (select i.rejection::text from workflow.full_text_intake i
   where i.reference = (select payload ->> 'reference' from result where label = 'submitted_e')),
  'extraction_failed',
  'med sin egen grunn, som innboksen oversetter til «prøv en annen utgave»'
);
select isnt(
  (select ti.resolved_at
   from workflow.technical_incidents ti
   join workflow.full_text_intake i on ti.signature = 'intake:' || i.id::text
   where i.reference = (select payload ->> 'reference' from result where label = 'submitted_e')),
  null,
  'og radens eget tekniske problem lukkes, framfor å bli stående for alltid'
);
select ok(
  (select ti.resolved_at is null from workflow.technical_incidents ti
   where ti.area = 'full_text_intake' and ti.signature = 'extraction'),
  'men leddet får sin egen rad, som står til et tekstuttrekk faktisk gir tekst'
);

-- Og det er nettopp det som lukker den: en ny fil som lar seg lese. Hva teksten
-- viser seg å være, er en annen sak — dette er fortsatt et fungerende uttrekk.
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'inbox_f', jsonb_build_object('items', api.full_text_inbox());
insert into result select 'submitted_f', api.submit_full_text(
  (select payload -> 'items' -> 0 ->> 'reference' from result where label = 'inbox_f'),
  (select value from fixture where name = 'pdf'));
insert into result select 'claim_f', api.claim_full_text_extraction(600);
insert into result select 'completed_f', api.complete_full_text_extraction(
  (select (payload ->> 'handle')::uuid from result where label = 'claim_f'),
  pg_temp.bound_800(),
  '24.02.0');
reset role;

select ok(
  (select ti.resolved_at is not null from workflow.technical_incidents ti
   where ti.area = 'full_text_intake' and ti.signature = 'extraction'),
  'et tekstuttrekk som gir tekst, friskmelder leddet — også når filen avvises'
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

-- De to nye feltene er maskinidentifikatorer, og de kontrolleres mot noe
-- databasen selv vet. Det er nettopp kontrollen som gjør at de ikke er
-- fritekst: en verdi som må treffe et funksjonsnavn eller en kodeform, kan
-- ikke bære et filnavn, en adresse eller en del av et svar.
select throws_ok(
  $$select api.report_technical_problem('work_queue', 'unavailable', 'en feilmelding på avveie')$$,
  '22023', 'Ukjent operasjon.',
  'operasjonen må være en api-funksjon som faktisk finnes'
);
select throws_ok(
  $$select api.report_technical_problem('work_queue', 'unavailable', 'public_work_board',
                                        'JWT expired')$$,
  '22023', 'Ukjent kodeform.',
  'og koden må ha en kodes form, ikke en setnings'
);
select throws_ok(
  $$select api.report_technical_problem('work_queue', 'unavailable', 'public_work_board',
                                        null, 9000)$$,
  '22023', 'Ukjent statuskode.',
  'statusen må være en HTTP-status'
);
select throws_ok(
  $$select api.report_technical_problem('work_queue', 'unavailable', 'public_work_board',
                                        null, null, 'litt av hvert')$$,
  '22023', 'Ukjent transportform.',
  'og transportformen må være en form databasen kjenner'
);

do $$ begin
  perform api.report_technical_problem(
    'work_queue', 'unavailable', 'public_work_board', 'PGRST301', 503, 'http');
  -- Og den rå årsaken, på sin egen vei. Den går i produksjon gjennom ruten
  -- `/diagnostics` nettopp fordi den ikke skal være avhengig av at kallet over
  -- kom fram; her kalles den samme funksjonen direkte.
  perform api.record_client_diagnostic(
    gen_random_uuid(),
    'work_queue', 'unavailable', 'public_work_board', 'PGRST301', 503, 'http',
    'TypeError: Failed to fetch' || chr(10) ||
    '    at callRpc (gateway.ts:1:1)' || chr(10) ||
    'authorization: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.hemmelig.signatur');
end $$;
reset role;

select is(
  (select ti.self_reported from workflow.technical_incidents ti where ti.area = 'work_queue'),
  true,
  'en selvmelding merkes som nettopp det: hva klienten SA, ikke hva databasen SÅ'
);

-- Dette er hele poenget med de to feltene: den rå årsaken er varig gjenfinnbar
-- for Claude Code og ChatGPT — hvilket kall som sviktet, og med hvilken kode —
-- uten at en videreformidlet feiltekst noen gang havner i databasen.
select ok(
  (select ti.diagnosis from workflow.technical_incidents ti where ti.area = 'work_queue')
    like '%api.public_work_board%',
  'diagnosen sier hvilket kall som sviktet'
);
select ok(
  (select ti.diagnosis from workflow.technical_incidents ti where ti.area = 'work_queue')
    like '%PGRST301%',
  'og hvilken kode svaret bar'
);

-- Koden mangler nettopp når svaret aldri kom. Uten statusen og transportformen
-- ville en teknisk agent sett *at* et kall sviktet, uten noe om hvordan.
select ok(
  (select ti.diagnosis from workflow.technical_incidents ti where ti.area = 'work_queue')
    like '%503%',
  'hvilken HTTP-status tjenesten svarte med'
);
select ok(
  (select ti.diagnosis from workflow.technical_incidents ti where ti.area = 'work_queue')
    like '%feilkode%',
  'og hvilken form svikten hadde, i Antideps egne ord'
);
select ok(
  (select ti.diagnosis from workflow.technical_incidents ti where ti.area = 'work_queue')
    not like '%JWT%',
  'men aldri feilteksten selv'
);
select is(
  (select ti.signature from workflow.technical_incidents ti where ti.area = 'work_queue'),
  'client:public_work_board',
  'og to forskjellige kall som svikter, blir to problemer framfor ett'
);

-- Og den rå årsaken selv, som er det #99 faktisk krever bevart: den ligger i
-- databasen og overlever at fanen lukkes, uten å ha en eneste vei til en flate.
-- Avgrenset til prøvens egen bruker. Tabellen er append-only og deles med
-- samtidighetsprøven (`npm run db:test:quota`), som legger igjen sine egne
-- rader; en påstand om «den ene raden» ville vært en påstand om hele databasen.
select ok(
  (select d.detail from workflow.client_diagnostics d
   where d.reported_by_user_id = '80000000-0000-4000-8000-00000000000d' and d.operation = 'public_work_board')
    like '%at callRpc (gateway.ts:1:1)%',
  'stacken er bevart, ikke bare klassifiseringen av den'
);
select ok(
  (select d.detail from workflow.client_diagnostics d
   where d.reported_by_user_id = '80000000-0000-4000-8000-00000000000d' and d.operation = 'public_work_board')
    not like '%hemmelig.signatur%',
  'men en tokenformet streng er vasket bort før lagring'
);
select is(
  (select ti.area::text from workflow.technical_incidents ti
   join workflow.client_diagnostics d on d.technical_incident_id = ti.id
   where d.reported_by_user_id = '80000000-0000-4000-8000-00000000000d' and d.operation = 'public_work_board'),
  'work_queue',
  'og raden peker på problemet den hører til, slik en agent finner veien'
);

-- En selvmeldt rad er et hjerteslag og ikke en tilstand: den gjelder så lenge
-- den fornyes. Det er hele grunnen til at flaten ikke lukker den selv — et
-- minne i en fane ville vært borte ved første sideoppfriskning, og meldingen
-- ville blitt stående som et uløst problem for alltid.
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select is(
  (api.technical_problem_summary() ->> 'unresolved')::int,
  1,
  'en fersk selvmelding teller som et uløst problem'
);
reset role;

-- Ingen rører klienten. Meldingen blir bare stående uten å bli fornyet.
update workflow.technical_incidents ti
set first_seen_at = statement_timestamp() - workflow.self_report_heartbeat() - interval '2 minutes',
    last_seen_at = statement_timestamp() - workflow.self_report_heartbeat() - interval '1 minute'
where ti.area = 'work_queue';

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select is(
  (api.technical_problem_summary() ->> 'unresolved')::int,
  0,
  'en selvmelding som ikke fornyes, er over — uten at noen klient sa fra'
);
insert into result select 'board_selfreport',
  jsonb_build_object('items', api.technical_problem_board());
reset role;

select is(
  (select item ->> 'area'
   from result, lateral jsonb_array_elements(payload -> 'items') as item
   where label = 'board_selfreport' and (item ->> 'ongoing')::boolean),
  null,
  'og oversikten viser den som avsluttet'
);
select isnt(
  (select ti.resolved_at from workflow.technical_incidents ti where ti.area = 'work_queue'),
  null,
  'som også skrives ned, slik at historikken stemmer med det som vises'
);
select is(
  (select count(*)::int from workflow.technical_incident_events e
   join workflow.technical_incidents ti on ti.id = e.technical_incident_id
   where ti.area = 'work_queue' and e.transition = 'resolved'),
  1,
  'og sporet får overgangen resolved, som alle andre lukkinger'
);

-- ===========================================================================
-- Del 9c — Grensene som gjør en klientskrevet tekst forsvarlig
--
-- Teksten kommer fra en nettleser, og det er nettopp derfor den er bundet:
-- attribusjon, mengde, lengde og innhold. Uten dem ville tabellen vært et sted
-- hvem som helst kunne fylle med hva som helst.
-- ===========================================================================
select is(
  (select count(*)::int from workflow.client_diagnostics
   where reported_by_user_id = '80000000-0000-4000-8000-00000000000d'),
  1,
  'råmaterialet har nøyaktig de radene som faktisk er meldt inn'
);

-- Lengden klippes, slik at ingen kan fylle tabellen med én rad.
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
do $$ begin
  perform api.record_client_diagnostic(gen_random_uuid(), 'agent_service', 'unavailable',
                                       'agent_work_queue', null, null, 'network',
                                       repeat('x', 12000));
end $$;
reset role;

select is(
  (select length(d.detail) from workflow.client_diagnostics d
   where d.reported_by_user_id = '80000000-0000-4000-8000-00000000000d' and d.operation = 'agent_work_queue'),
  4000,
  'en tekst over grensen klippes framfor å bli avvist — en klippet årsak er bedre enn ingen'
);

-- Mengden begrenses per bruker og time. Problemet telles fortsatt; det er
-- teksten som droppes, og det er riktig vei å tape på.
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
do $$
begin
  for i in 1..70 loop
    perform api.report_technical_problem('agent_service', 'unavailable', 'agent_task_payload',
                                         null, null, 'network');
    perform api.record_client_diagnostic(gen_random_uuid(), 'agent_service', 'unavailable',
                                         'agent_task_payload', null, null, 'network',
                                         'rå årsak nummer ' || i);
  end loop;
end;
$$;
reset role;

select ok(
  (select count(*)::int from workflow.client_diagnostics
   where reported_by_user_id = '80000000-0000-4000-8000-00000000000d') <= 60,
  'en flate som svikter i en løkke, kan ikke fylle tabellen'
);

-- En levering som ikke ble bekreftet, prøves på nytt. Den skal bli den samme
-- raden og ikke en til — ellers ville utboksen doblet årsakene hver gang en
-- fane lukket seg midt i sendingen.
do $$
declare
  v_event uuid := gen_random_uuid();
  v_before integer;
begin
  select count(*) into v_before from workflow.client_diagnostics
  where reported_by_user_id = '80000000-0000-4000-8000-00000000000c';
  set local role authenticated;
  perform set_config('request.jwt.claims',
                     '{"sub":"80000000-0000-4000-8000-00000000000c"}', true);
  perform api.record_client_diagnostic(v_event, 'clinical_content', 'unavailable',
                                       'candidate_control_queue', null, null, 'network', 'én gang');
  perform api.record_client_diagnostic(v_event, 'clinical_content', 'unavailable',
                                       'candidate_control_queue', null, null, 'network', 'én gang');
  reset role;
  insert into result select 'idempotent',
    jsonb_build_object('lagt_til',
      (select count(*) from workflow.client_diagnostics
       where reported_by_user_id = '80000000-0000-4000-8000-00000000000c') - v_before);
end;
$$;

select is(
  (select (payload ->> 'lagt_til')::int from result where label = 'idempotent'),
  1,
  'den samme observasjonen levert to ganger blir én rad'
);
select ok(
  (select ti.occurrence_count from workflow.technical_incidents ti
   where ti.signature = 'client:agent_task_payload') >= 70,
  'men problemet telles fortsatt hver eneste gang'
);

-- ===========================================================================
-- Del 9b — En episode som er over, blir lukket selv om ingen ser etter
--
-- Hjerteslaget regner ut at en stille rad er over, men regnestykket alene
-- etterlater et hull i historikken: kommer den samme svikten tilbake uten at
-- noen har åpnet oversikten i mellomtiden, ville raden fortsatt hatt
-- resolved_at null, og sporet ville fått en `seen` framfor en `resolved` og en
-- ny `opened`. Da ville historikken vist én sammenhengende episode over et
-- tidsrom der problemet ikke pågikk.
--
-- Lukkingen skjer derfor i skriveveien selv, før den nye observasjonen
-- gjenbruker raden — og ingen admin er involvert her.
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
do $$ begin
  perform api.report_technical_problem('clinical_content', 'unavailable', 'candidate_control_queue',
                                       null, null, 'network');
end $$;
reset role;

-- Den blir stille. Ingen leser oversikten.
update workflow.technical_incidents ti
set first_seen_at = statement_timestamp() - workflow.self_report_heartbeat() - interval '2 hours',
    last_seen_at = statement_timestamp() - workflow.self_report_heartbeat() - interval '1 hour'
where ti.area = 'clinical_content';

-- Og så kommer den samme svikten tilbake.
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
do $$ begin
  perform api.report_technical_problem('clinical_content', 'unavailable', 'candidate_control_queue',
                                       null, null, 'network');
end $$;
reset role;

-- Sortert på navn og ikke på tidspunkt: alt i prøven skjer i én transaksjon, så
-- now() er det samme for hver rad. Påstanden er uansett hvilke overganger som
-- finnes — at det ble en lukking og en ny åpning, og ikke bare en `seen`.
select is(
  (select array_agg(e.transition::text order by e.transition::text)
   from workflow.technical_incident_events e
   join workflow.technical_incidents ti on ti.id = e.technical_incident_id
   where ti.area = 'clinical_content'),
  array['opened', 'opened', 'resolved'],
  'den stille episoden lukkes i skriveveien, og den nye åpnes — uten at noen så etter'
);
select ok(
  (select ti.first_seen_at from workflow.technical_incidents ti
   where ti.area = 'clinical_content')
    > statement_timestamp() - workflow.self_report_heartbeat(),
  'og «oppsto» beskriver episoden som pågår nå, ikke en som var over'
);
select is(
  (select ti.occurrence_count from workflow.technical_incidents ti
   where ti.area = 'clinical_content'),
  1,
  'antallet teller den nye episoden, mens hele forløpet står i sporet'
);
select ok(
  (select ti.resolved_at is null from workflow.technical_incidents ti
   where ti.area = 'clinical_content'),
  'og raden er åpen igjen, som den skal være'
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

-- Og den står til noe faktisk lukker den. Hjerteslaget gjelder bare selvmeldte
-- rader: en jobb som ga opp, er fortsatt gitt opp i morgen.
update workflow.technical_incidents ti
set first_seen_at = statement_timestamp() - workflow.self_report_heartbeat() - interval '2 days',
    last_seen_at = statement_timestamp() - workflow.self_report_heartbeat() - interval '1 day'
where ti.area = 'automatic_task';

select is(
  (select count(*)::int from workflow.technical_incidents ti
   where ti.area = 'automatic_task' and workflow.technical_incident_ongoing(ti)),
  1,
  'en observasjon databasen selv gjorde, blir ikke borte av at tiden går'
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
   where ti.area = 'agent_service' and ti.signature like 'runner:%'
     and ti.resolved_at is null),
  1,
  'et teknisk kjørerkall blir et uløst problem'
);

insert into workflow.agent_runner_events (connection_id, tool_name, outcome)
select c.id, 'list_pending_agent_tasks', 'ok'
from workflow.agent_runner_connections c
where c.connection_key = 'proeve:800';

select is(
  (select count(*)::int from workflow.technical_incidents ti
   where ti.area = 'agent_service' and ti.signature like 'runner:%'
     and ti.resolved_at is null),
  0,
  'og neste kall som går gjennom, lukker det'
);

-- ===========================================================================
-- Del 13 — Merket har nøyaktig den samme aktørgrensen som oversikten
--
-- En aktør som er trukket tilbake, men som fortsatt har en rolletildeling som
-- ikke er utløpt, er den ene kombinasjonen der en svakere kontroll ville blitt
-- synlig: oversikten avviser dem, og da skal tellingen heller ikke svare med
-- noe annet enn null.
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select throws_ok(
  $$select api.technical_problem_board()$$,
  '42501', 'Aktøren er trukket tilbake.',
  'en tilbaketrukket aktør kommer ikke til den tekniske oversikten'
);
select is(
  (api.technical_problem_summary() ->> 'visible')::boolean,
  false,
  'og merket er ikke synlig for dem heller, selv om rolletildelingen står'
);
select is(
  (api.technical_problem_summary() ->> 'unresolved')::int,
  0,
  'tallet er null, så ingenting lekker den veien'
);
reset role;

-- ===========================================================================
-- Del 14 — Veien som ikke går gjennom Data API-et
--
-- Den rå årsaken skal komme fram også når PostgREST ikke svarer. Reserven er
-- en egen databaserolle med en egen forbindelse, og hele poenget med den er at
-- den skal kunne *nesten ingenting*: legge til rader gjennom to funksjoner, og
-- ikke lese én rad tilbake — heller ikke sine egne.
--
-- Prøvene her er derfor like mye på hva rollen ikke kan, som på hva den gjør.
-- ===========================================================================

-- --- Rollen, og grensene rundt den ---------------------------------------
select is(
  (select format('super=%s createdb=%s createrole=%s bypassrls=%s inherit=%s login=%s',
                 rolsuper::text, rolcreatedb::text, rolcreaterole::text,
                 rolbypassrls::text, rolinherit::text, rolcanlogin::text)
   from pg_roles where rolname = 'antidep_diagnostics'),
  'super=false createdb=false createrole=false bypassrls=false inherit=false login=true',
  'reserverollen kan logge inn, og er ellers hverken superbruker, oppretter noe, går utenom RLS eller arver noe'
);

-- Vaktpostene under leser ACL-en framfor den effektive rettigheten, og det er
-- et bevisst valg: has_table_privilege tar med alt som er gitt til PUBLIC, så
-- en uttømmende påstand på den ville blitt rød av en urelatert grant et helt
-- annet sted. Her skal det stå hva *migrasjonen* ga denne rollen — uttømmende
-- over alle de kanoniske schemaene, slik at en ny tabell ikke kan bli skrivbar
-- for den ved at noen glemmer å føre den opp.
select is_empty(
  $$
    select n.nspname || '.' || c.relname || ':' || a.privilege_type
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) a
    where n.nspname in ('catalog', 'knowledge', 'workflow', 'provenance', 'audit', 'api')
      and c.relacl is not null
      and a.grantee = 'antidep_diagnostics'::regrole::oid
  $$,
  'migrasjonen ga reserverollen ingen tabellrettighet i noen av de kanoniske schemaene'
);

select set_eq(
  $$
    select p.oid::regprocedure::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(p.proacl) a
    where n.nspname in ('catalog', 'knowledge', 'workflow', 'provenance', 'audit', 'api')
      and p.proacl is not null
      and a.grantee = 'antidep_diagnostics'::regrole::oid
      and a.privilege_type = 'EXECUTE'
  $$,
  $$
    values ('workflow.ingest_client_diagnostic(text,uuid,text,text,text,text,integer,text,text)'),
           ('workflow.ingest_public_technical_problem(text,text,text,text,text,integer,text)')
  $$,
  'reserverollen er gitt nøyaktig de to append-funksjonene, og ingen andre'
);

select set_eq(
  $$
    select n.nspname || ':' || a.privilege_type
    from pg_namespace n
    cross join lateral aclexplode(n.nspacl) a
    where n.nspname in ('catalog', 'knowledge', 'workflow', 'provenance', 'audit', 'api')
      and n.nspacl is not null
      and a.grantee = 'antidep_diagnostics'::regrole::oid
  $$,
  $$values ('workflow:USAGE')$$,
  'reserverollen er gitt usage på workflow alene, og create på ingenting'
);

-- Og den effektive kontrollen der den betyr mest: rollen skal ikke kunne røre
-- de tre tabellene denne veien skriver til, uansett hvor rettigheten måtte
-- kommet fra.
select is_empty(
  $$
    select t.name, p.privilege
    from (values ('workflow.client_diagnostics'),
                 ('workflow.technical_incidents'),
                 ('workflow.technical_incident_events'),
                 ('workflow.diagnostics_attempts')) as t(name)
    cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege('antidep_diagnostics', t.name, p.privilege)
  $$,
  'og kan hverken lese eller skrive de fire tabellene denne veien rører, direkte'
);

-- Ingen SECURITY DEFINER-funksjon utenom de to skal være nåbar for rollen. Det
-- er den eneste klassen som kan gjøre noe på egen hånd; en vanlig funksjon
-- kjører med rollens egne rettigheter, og de er ingen.
select is_empty(
  $$
    select p.oid::regprocedure::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('catalog', 'knowledge', 'workflow', 'provenance', 'audit', 'api')
      and p.prosecdef
      and has_function_privilege('antidep_diagnostics', p.oid, 'execute')
      and p.oid::regprocedure::text not in (
        'workflow.ingest_client_diagnostic(text,uuid,text,text,text,text,integer,text,text)',
        'workflow.ingest_public_technical_problem(text,text,text,text,text,integer,text)',
        'workflow.claim_diagnostics_attempt(text)')
  $$,
  'og kan ikke kjøre noen annen SECURITY DEFINER-funksjon, uansett hvor granten kom fra'
);

-- Kvotene binder hvor mange rader som kan skrives, men ikke hvor mye plass en
-- forbindelse kan oppta. En stjålet legitimasjon bruker ikke Antideps egen
-- klient, så tidsgrensene der beskytter ingenting mot den. Grensene må stå på
-- rollen, i databasen.
select is(
  (select rolconnlimit from pg_roles where rolname = 'antidep_diagnostics'),
  4,
  'reserverollen kan holde høyst fire forbindelser samtidig'
);
select set_eq(
  $$
    select unnest(rolconfig) from pg_roles where rolname = 'antidep_diagnostics'
  $$,
  $$
    values ('statement_timeout=5s'),
           ('idle_in_transaction_session_timeout=5s'),
           ('idle_session_timeout=30s'),
           ('lock_timeout=5s')
  $$,
  'og databasen river ned en forbindelse som henger, uansett hvilken klient som åpnet den'
);

-- --- Raden reserven skriver ------------------------------------------------
--
-- Den skal være den samme raden som normalveien skriver, i den samme private
-- tabellen — bare med en annen avsender, siden ingen token kan kontrolleres
-- når PostgREST er nede.
select lives_ok(
  $$
    select workflow.ingest_client_diagnostic(
      repeat('a', 64), '7f000000-0000-4000-8000-00000000d001', 'work_queue', 'unavailable',
      'public_work_board', 'PGRST301', 503, 'http',
      'TypeError: Failed to fetch' || chr(10) || '    at callRpc (gateway.ts:1:1)')
  $$,
  'reserveveien tar imot en observasjon'
);
select is(
  (select detail from workflow.client_diagnostics
   where client_event_id = '7f000000-0000-4000-8000-00000000d001'),
  'TypeError: Failed to fetch' || chr(10) || '    at callRpc (gateway.ts:1:1)',
  'og stacken er i behold, linjeskift og alt'
);
select is(
  (select coalesce(reported_by_user_id::text, '(ingen)') || '|' || reporter_ip_hash
          || '|' || reporter_key
   from workflow.client_diagnostics
   where client_event_id = '7f000000-0000-4000-8000-00000000d001'),
  '(ingen)|' || repeat('a', 64) || '|ip:' || repeat('a', 64),
  'raden er merket som serverens observasjon, og nøkkelen er utledet av den'
);

-- Og det som manglet: selve problemet.
--
-- Meldingen om at området ikke svarer, går normalt over Data API-et. Kommer
-- reserveveien i bruk, betyr det at nettopp den meldingen ikke kom fram — så
-- uten dette ville en Data API-svikt vært varig *diagnostisert* uten at merket
-- eller problemoversikten viste noe som helst.
select is(
  (select ti.resolved_at is null and ti.self_reported
   from workflow.technical_incidents ti
   where ti.area = 'work_queue' and ti.signature = 'client:public_work_board'),
  true,
  'reserveveien melder også selve problemet, ikke bare årsaken'
);
select is(
  (select count(*)::int from workflow.technical_incident_events e
   where e.reporter_key = 'ip:' || repeat('a', 64)),
  1,
  'og sporet navngir reserveveien som avsender, slik at mengden kan telles'
);
select is(
  (select count(*)::int from workflow.technical_incidents ti
   where ti.area = 'work_queue' and ti.signature = 'client:public_work_board'
     and ti.diagnosis like '%Data API-et ikke tok imot%'
     and ti.diagnosis not like '%callRpc%'),
  1,
  'og diagnosen er Antideps egen setning, uten feilteksten'
);

-- Vaskingen gjelder her også. En token som havnet i en feilmelding, skal ikke
-- bli liggende lesbar fordi den kom inn på reserveveien.
select lives_ok(
  $$
    select workflow.ingest_client_diagnostic(
      repeat('b', 64), '7f000000-0000-4000-8000-00000000d002', 'work_queue', 'unavailable',
      'public_work_board', null, null, 'network',
      'authorization: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.hemmelig.signatur')
  $$,
  'reserveveien tar imot en observasjon med en tokenformet streng'
);
select unalike(
  (select detail from workflow.client_diagnostics
   where client_event_id = '7f000000-0000-4000-8000-00000000d002'),
  '%hemmelig.signatur%',
  'og den er vasket bort før lagring, som på normalveien'
);

-- Idempotens: et ubekreftet forsøk prøves på nytt, og skal ikke bli to rader.
select lives_ok(
  $$
    select workflow.ingest_client_diagnostic(
      repeat('a', 64), '7f000000-0000-4000-8000-00000000d001', 'work_queue', 'unavailable',
      'public_work_board', 'PGRST301', 503, 'http', 'en annen tekst')
  $$,
  'det samme nummeret levert igjen går gjennom'
);
select is(
  (select count(*)::int from workflow.client_diagnostics
   where client_event_id = '7f000000-0000-4000-8000-00000000d001'),
  1,
  'og blir fortsatt én rad'
);

-- Avsendersummen er serverens egen observasjon. En verdi som ikke har formen,
-- er ikke en sum, og da finnes ingen å telle på.
select throws_ok(
  $$
    select workflow.ingest_client_diagnostic(
      'ikke-en-sum', '7f000000-0000-4000-8000-00000000d003', 'work_queue', 'unavailable')
  $$,
  '22023',
  'Observasjonen mangler serverens egen avsendersum.',
  'reserveveien krever en avsendersum av riktig form'
);

-- --- Den uinnloggede besøkende --------------------------------------------
--
-- Ingen fritekst i det hele tatt, og bare de to flatene en uinnlogget kan se.
select throws_ok(
  $$
    select workflow.ingest_public_technical_problem(
      repeat('c', 64), 'full_text_intake', 'unavailable', 'full_text_inbox')
  $$,
  '22023',
  'Området er ikke offentlig.',
  'en anonym melding om en flate bak innlogging avvises'
);
select lives_ok(
  $$
    select workflow.ingest_public_technical_problem(
      repeat('c', 64), 'work_queue', 'unavailable', 'public_work_board', 'PGRST301', 503, 'http')
  $$,
  'en anonym melding om den offentlige arbeidsoversikten tas imot'
);
select is(
  (select count(*)::int from workflow.technical_incident_events e
   where e.reporter_key = 'offentlig:' || repeat('c', 64)),
  1,
  'og den står på sporet med avsenderen serveren observerte'
);
select is(
  (select ti.self_reported::text from workflow.technical_incidents ti
   where ti.area = 'work_queue' and ti.signature = 'client:public_work_board'),
  'true',
  'problemet er selvmeldt, altså et hjerteslag databasen selv lukker'
);

-- Signaturen bærer bare operasjonen, og diagnosen er Antideps egen setning.
-- Ingen av delene kan bære et ord fra den som meldte.
select is(
  (select count(*)::int from workflow.technical_incident_events e
   where e.reporter_key = 'offentlig:' || repeat('c', 64)
     and e.diagnosis like '%uinnlogget besøkende%'
     and e.diagnosis like '%bærer derfor ingen feiltekst%'),
  1,
  'diagnosen er Antideps egen setning, og sier selv at den ikke bærer noen feiltekst'
);

-- Operasjonen må treffe en api-funksjon som faktisk finnes. Det er denne
-- kontrollen som gjør antallet problemrader den anonyme veien kan skape,
-- endelig: uten den kunne hver oppdiktede operasjon blitt en ny rad, og kvoten
-- per avsender ville ikke hjulpet mot mange avsendere.
select throws_ok(
  $$
    select workflow.ingest_public_technical_problem(
      repeat('c', 64), 'work_queue', 'unavailable', 'en_oppdiktet_operasjon')
  $$,
  '22023',
  'Ukjent operasjon.',
  'en anonym melding om en operasjon som ikke finnes, avvises'
);
select throws_ok(
  $$
    select workflow.ingest_public_technical_problem(
      repeat('c', 64), 'work_queue', 'unavailable', 'public_work_board', 'en fri tekst')
  $$,
  '22023',
  'Ukjent kode.',
  'og koden må ha formen til en maskinkode, ikke være fritekst'
);

-- Kvoten: tjue i timen per avsender, og den tjueførste skrives ikke.
do $$
declare
  i integer;
begin
  for i in 1..25 loop
    perform workflow.ingest_public_technical_problem(
      repeat('d', 64), 'clinical_content', 'unavailable', 'published_claim_index');
  end loop;
end
$$;
select is(
  (select count(*)::int from workflow.technical_incident_events e
   where e.reporter_key = 'offentlig:' || repeat('d', 64)),
  20,
  'den anonyme veien skriver høyst tjue observasjoner i timen per avsender'
);

-- --- Maskinidentifikatorene er like lukket som på den innloggede veien -----
--
-- Uten disse kunne en som fikk tak i legitimasjonen, skrevet fritekst i felter
-- som skal være lukkede vokabularer og kontrollerte former.
select throws_ok(
  $$
    select workflow.ingest_client_diagnostic(
      repeat('e', 64), '7f000000-0000-4000-8000-00000000e001', 'work_queue',
      'en oppdiktet svikttype', 'public_work_board', null, null, 'network', 'en tekst')
  $$,
  '22023', 'Ukjent svikttype.',
  'reserveveien avviser en svikttype utenfor vokabularet'
);
select throws_ok(
  $$
    select workflow.ingest_client_diagnostic(
      repeat('e', 64), '7f000000-0000-4000-8000-00000000e002', 'work_queue',
      'unavailable', 'en_oppdiktet_operasjon', null, null, 'network', 'en tekst')
  $$,
  '22023', 'Ukjent operasjon.',
  'og en operasjon som ikke finnes i api'
);
select throws_ok(
  $$
    select workflow.ingest_client_diagnostic(
      repeat('e', 64), '7f000000-0000-4000-8000-00000000e003', 'work_queue',
      'unavailable', 'public_work_board', 'en fri tekst', null, 'network', 'en tekst')
  $$,
  '22023', 'Ukjent kode.',
  'og en kode som ikke har formen til en maskinkode'
);
select throws_ok(
  $$
    select workflow.ingest_client_diagnostic(
      repeat('e', 64), '7f000000-0000-4000-8000-00000000e004', 'work_queue',
      'unavailable', 'public_work_board', null, null, 'en fri tekst', 'en tekst')
  $$,
  '22023', 'Ukjent transportform.',
  'og en transportform utenfor vokabularet'
);
select throws_ok(
  $$
    select workflow.ingest_client_diagnostic(
      repeat('e', 64), '7f000000-0000-4000-8000-00000000e005', 'work_queue',
      'unavailable', 'public_work_board', null, 9000, 'network', 'en tekst')
  $$,
  '22023', 'Ukjent statuskode.',
  'og en status som ikke er en HTTP-status'
);

-- --- Forsøksgrensen, som er felles for alle instansene ---------------------
--
-- Punkt 2 fra tolvte gjennomgang. Grensen foran rundturen til
-- autentiseringstjenesten lå i minnet til den serverless funksjonen, og en
-- serverless flate har mange instanser: hver kald eller parallell instans
-- startet med sitt eget friske budsjett, så den som ville, kunne få så mange
-- budsjetter den ville. Det er en demper, ikke et vern.
--
-- Den står her i stedet, fordi databasen er den ene tilstanden alle instansene
-- deler — og den er nåbar akkurat når den trengs, siden det er PostgREST som er
-- nede i den grenen, ikke Postgres.
select throws_ok(
  $$select workflow.claim_diagnostics_attempt('ikke-en-sum')$$,
  '22023',
  'Forsøket mangler serverens egen avsendersum.',
  'forsøksgrensen krever en avsendersum av riktig form'
);
select throws_ok(
  $$select workflow.claim_diagnostics_attempt(null)$$,
  '22023',
  'Forsøket mangler serverens egen avsendersum.',
  'og den finnes ikke uten en i det hele tatt'
);

select is(
  workflow.claim_diagnostics_attempt(repeat('1', 64)),
  true,
  'det første forsøket er innenfor'
);
select is(
  (select attempts from workflow.diagnostics_attempts
   where reporter_ip_hash = repeat('1', 64)),
  1,
  'og det er talt, i minuttet det hører til'
);

-- Tretti i minuttet. Trettien er ikke.
do $$
declare
  i integer;
begin
  for i in 2..30 loop
    perform workflow.claim_diagnostics_attempt(repeat('1', 64));
  end loop;
end
$$;
select is(
  workflow.claim_diagnostics_attempt(repeat('1', 64)),
  false,
  'forsøk nummer trettien er over grensen'
);
select is(
  (select attempts from workflow.diagnostics_attempts
   where reporter_ip_hash = repeat('1', 64)),
  31,
  'og telleren står likevel: et forsøk over grensen er fortsatt et forsøk'
);

-- Grensen er per avsender. Én som prøver for mye, skal ikke stenge ute en annen.
select is(
  workflow.claim_diagnostics_attempt(repeat('2', 64)),
  true,
  'en annen avsender er upåvirket av den som prøvde for mye'
);

-- Og taket for veien under ett, som er grensen om legitimasjonen lekker: en
-- kaller kan velge sin egen avsendersum, og kunne ellers omgått grensen over
-- ved å velge en ny sum for hvert forsøk.
do $$
declare
  i integer;
begin
  -- Førti summer à tretti forsøk = 1200, godt over taket på 600 i minuttet.
  for i in 1..40 loop
    for j in 1..30 loop
      perform workflow.claim_diagnostics_attempt(lpad(to_hex(i + 8192), 64, '0'));
    end loop;
  end loop;
end
$$;
select is(
  (select coalesce(sum(attempts), 0)::int from workflow.diagnostics_attempts),
  600,
  'veien under ett teller høyst seks hundre forsøk i minuttet, uansett hvor mange summer kalleren finner opp'
);
select is(
  workflow.claim_diagnostics_attempt(repeat('3', 64)),
  false,
  'og en fersk avsender får nei når taket er nådd — det er prisen for at summen oppgis av kalleren'
);

-- --- Den samme svikten, meldt to veier, er én svikt ------------------------
--
-- Meldingen om problemet går over Data API-et, og den rå årsaken går sin egen
-- vei. Det er et helt realistisk kappløp: meldingen kom fram, mens årsaken møtte
-- en forbigående PostgREST-feil og måtte over reserven — og reserven melder
-- problemet selv, fordi den ikke kan vite at meldingen kom fram. Uten et felles
-- nummer ville det gitt to «seen» for én observasjon, og en teller ett for høyt.
-- Nummeret flaten allerede gir hver observasjon, er det som binder de to.
create temporary table kapplop_800 (merke text primary key, tall integer);
insert into kapplop_800
select 'foer', ti.occurrence_count
from workflow.technical_incidents ti
where ti.area = 'work_queue' and ti.signature = 'client:public_work_board';

select set_config('request.jwt.claims',
                  '{"sub":"80000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
do $$ begin
  perform api.report_technical_problem(
    'work_queue', 'unavailable', 'public_work_board', 'PGRST002', 503, 'http',
    '7f000000-0000-4000-8000-00000000f001');
end $$;
reset role;

select is(
  (select ti.occurrence_count from workflow.technical_incidents ti
   where ti.area = 'work_queue' and ti.signature = 'client:public_work_board'),
  (select tall + 1 from kapplop_800 where merke = 'foer'),
  'meldingen over Data API-et teller observasjonen én gang'
);
select is(
  (select count(*)::int from workflow.technical_incident_events e
   where e.client_event_id = '7f000000-0000-4000-8000-00000000f001'),
  1,
  'og sporet bærer flatens eget nummer på den'
);

-- Og så den samme observasjonen inn den andre veien, slik reserven ville
-- gjort det når PostgREST ikke svarte på årsakens kall.
select lives_ok(
  $$
    select workflow.ingest_client_diagnostic(
      repeat('c', 64), '7f000000-0000-4000-8000-00000000f001', 'work_queue', 'unavailable',
      'public_work_board', 'PGRST002', 503, 'http', 'TypeError: Failed to fetch')
  $$,
  'reserveveien tar imot den samme observasjonen'
);
select is(
  (select ti.occurrence_count from workflow.technical_incidents ti
   where ti.area = 'work_queue' and ti.signature = 'client:public_work_board'),
  (select tall + 1 from kapplop_800 where merke = 'foer'),
  'men telleren står stille: den samme svikten er ikke to svikt'
);
select is(
  (select count(*)::int from workflow.technical_incident_events e
   where e.client_event_id = '7f000000-0000-4000-8000-00000000f001'),
  1,
  'og sporet har fortsatt nøyaktig én observasjon med det nummeret'
);

-- Men årsaken skal like fullt være berget. Det er hele grunnen til at reserven
-- finnes, og idempotensen på sporet skal ikke koste teksten.
select is(
  (select count(*)::int from workflow.client_diagnostics
   where client_event_id = '7f000000-0000-4000-8000-00000000f001'),
  1,
  'og den rå årsaken ble lagret, selv om problemet allerede var talt'
);

-- --- Grensen som gjelder om legitimasjonen lekker -------------------------
--
-- Avsendersummen oppgis av kalleren. En som stjeler legitimasjonen kan velge
-- en ny gyldig sum for hvert kall, så en kvote per avsender binder ingenting
-- alene. Prøven gjør nettopp det: sju hundre kall, hver med sin egen sum.
do $$
declare
  i integer;
begin
  for i in 1..700 loop
    perform workflow.ingest_client_diagnostic(
      lpad(to_hex(i), 64, '0'),
      ('7f000000-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::uuid,
      'work_queue', 'unavailable', 'public_work_board', null, null, 'network',
      'en årsak fra kall nummer ' || i::text);
  end loop;
end
$$;
select is(
  (select count(*)::int from workflow.client_diagnostics
   where reporter_ip_hash is not null),
  600,
  'reserven skriver høyst seks hundre rader i timen, uansett hvor mange avsendere kalleren finner opp'
);

-- Og det samme for den anonyme veien: to hundre i timen for veien under ett.
do $$
declare
  i integer;
begin
  for i in 1..250 loop
    perform workflow.ingest_public_technical_problem(
      lpad(to_hex(i + 4096), 64, '0'),
      'work_queue', 'unavailable', 'public_work_board');
  end loop;
end
$$;
select is(
  (select count(*)::int from workflow.technical_incident_events
   where reporter_key like 'offentlig:%'),
  200,
  'den anonyme veien skriver høyst to hundre observasjoner i timen under ett'
);

-- Og sporet for alt databasen selv observerte, bærer ingen avsender: kolonnen
-- finnes for kvoten på den ene veien, og ikke som en ny opplysning om alle.
select is(
  (select count(*)::int from workflow.technical_incident_events e
   join workflow.technical_incidents ti on ti.id = e.technical_incident_id
   where ti.signature like 'runner:%' and e.reporter_key is not null),
  0,
  'observasjoner databasen selv gjorde, har ingen avsender på sporet'
);

select * from finish();
rollback;
