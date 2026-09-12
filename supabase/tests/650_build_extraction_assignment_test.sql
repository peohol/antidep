-- Migrasjon 007i — ekstraksjonsoppdraget bygget av databasens egne rader.
--
-- Oppdraget er en tiltrodd inndata: registreringen kontrollerer forslaget mot
-- det (migrasjon 005ab), så det er halvparten av kontrollen. Filen prøver
-- derfor tre ting:
--
--   * at kildebindingen kommer fra én rad, og bærer dokumentbindingen når
--     versjonen er utledet av et originaldokument (migrasjon 003e),
--   * at katalogvalgene slås opp på kanoniske navn, og at et navn som ikke
--     finnes, gir en avvisning framfor et oppdrag med én avgrensning mindre, og
--   * at en kildeversjon som ikke kan bære en ekstraksjon, avvises før arbeidet.
--
-- SQLSTATE P0002 = no_data_found, 22023 = invalid_parameter_value,
-- 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(21);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'build_extraction_assignment', 'api.build_extraction_assignment() finnes'
);
select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.build_extraction_assignment(uuid,text[],text[],text[])'::regprocedure),
  'funksjonen er SECURITY DEFINER'
);
select ok(
  (select exists (
     select 1
     from pg_proc p, unnest(coalesce(p.proconfig, array[]::text[])) as cfg
     where p.oid = 'api.build_extraction_assignment(uuid,text[],text[],text[])'::regprocedure
       and cfg like 'search_path=%'
   )),
  'funksjonen har tomt search_path'
);
select ok(
  has_function_privilege('authenticated',
    'api.build_extraction_assignment(uuid,text[],text[],text[])', 'EXECUTE'),
  'authenticated kan bygge et oppdrag'
);
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name, 'api.build_extraction_assignment(uuid,text[],text[],text[])', 'EXECUTE')
  $$,
  'verken anon, service_role eller PUBLIC kan bygge et oppdrag'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
--   A  aktør uten rolletildeling
--   B  aktør med gyldig editor-tildeling
--
-- To kildeversjoner på samme kilde: én dokumentutledet fulltekst og ett
-- sammendrag hentet fra en adresse. Og to som ikke kan bære et oppdrag: én uten
-- fingeravtrykk, én uten representasjonstype.
-- ===========================================================================
insert into auth.users (id, email) values
  ('65000000-0000-4000-8000-00000000000a', 'oppdrag-650-a@test.invalid'),
  ('65000000-0000-4000-8000-00000000000b', 'oppdrag-650-b@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac650000-0000-4000-8000-00000000000a', 'human', 'human:oppdrag-650-a', 'Kaller A',
   'Aktør uten rolletildeling, for 650.', '65000000-0000-4000-8000-00000000000a'),
  ('ac650000-0000-4000-8000-00000000000b', 'human', 'human:oppdrag-650-b', 'Kaller B',
   'Aktør med gyldig editor-tildeling, for 650.', '65000000-0000-4000-8000-00000000000b');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('65000000-0000-4000-8000-00000000000b', 'editor', null, now() - interval '1 year',
   'ac650000-0000-4000-8000-00000000000b', 'Gyldig tildeling for kaller B i 650.');

insert into knowledge.sources
  (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('50650000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 650',
   'Testforfatter 650', 'ac650000-0000-4000-8000-00000000000b');

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation,
   document_sha256, document_byte_size, document_media_type,
   text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
   text_extraction_transform, retrieved_by_actor_id)
values
  ('5f650000-0000-4000-8000-000000000001', '50650000-0000-4000-8000-000000000001',
   now() - interval '1 day', 'https://doi.org/10.0000/650',
   'sha256:' || repeat('a', 64), 'full_text',
   'sha256:' || repeat('b', 64), 481253, 'application/pdf',
   'pdftotext', 'pdftotext 24.02.0', '-bbox-layout -enc UTF-8 -eol unix',
   'antidep-reading-order@1',
   'ac650000-0000-4000-8000-00000000000b');

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation,
   retrieved_by_actor_id)
values
  ('5f650000-0000-4000-8000-000000000002', '50650000-0000-4000-8000-000000000001',
   now() - interval '2 days', 'https://eutils.ncbi.nlm.nih.gov/650',
   'sha256:' || repeat('c', 64), 'abstract', 'ac650000-0000-4000-8000-00000000000b'),
  ('5f650000-0000-4000-8000-000000000003', '50650000-0000-4000-8000-000000000001',
   now() - interval '3 days', 'https://eksempel.invalid/650-uten-hash',
   null, 'abstract', 'ac650000-0000-4000-8000-00000000000b'),
  ('5f650000-0000-4000-8000-000000000004', '50650000-0000-4000-8000-000000000001',
   now() - interval '4 days', 'https://eksempel.invalid/650-uten-type',
   'sha256:' || repeat('d', 64), null, 'ac650000-0000-4000-8000-00000000000b');

-- ===========================================================================
-- Del 3 — Autorisasjonen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"65000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  $$
    select api.build_extraction_assignment(
      '5f650000-0000-4000-8000-000000000001', array['sertralin'], array['vektendring'])
  $$,
  '42501', null,
  'en innlogget bruker uten editor-rolle får ikke bygge et oppdrag'
);
reset role;
select set_config('request.jwt.claims', '', true);

-- ===========================================================================
-- Del 4 — Oppdraget av en dokumentutledet fulltekst
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"65000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;

create temporary table built (name text primary key, value jsonb not null) on commit drop;
grant select, insert on built to authenticated;

insert into built (name, value)
select 'fulltekst', api.build_extraction_assignment(
  '5f650000-0000-4000-8000-000000000001',
  array['Sertralin'],
  array['Vektendring'],
  array['voksne med depressiv lidelse']
);
insert into built (name, value)
select 'sammendrag', api.build_extraction_assignment(
  '5f650000-0000-4000-8000-000000000002', array['mirtazapin'], array['vektendring']);

reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (select value ->> 'assignment_version' from built where name = 'fulltekst'),
  'antidep/extraction-assignment@2',
  'oppdraget bærer kontraktsversjonen kjørerne leser'
);
select is(
  (select (value ->> 'source_id') || ' ' || (value ->> 'source_version_id')
          || ' ' || (value ->> 'retrieved_from') || ' ' || (value ->> 'content_hash')
   from built where name = 'fulltekst'),
  '50650000-0000-4000-8000-000000000001 5f650000-0000-4000-8000-000000000001 '
    || 'https://doi.org/10.0000/650 sha256:' || repeat('a', 64),
  'hele kildebindingen kommer fra én og samme rad'
);
select is(
  (select value -> 'document' from built where name = 'fulltekst'),
  jsonb_build_object(
    'sha256', 'sha256:' || repeat('b', 64),
    'byte_size', 481253,
    'media_type', 'application/pdf',
    'text_extraction', jsonb_build_object(
      'tool', 'pdftotext',
      'tool_version', 'pdftotext 24.02.0',
      'arguments', '-bbox-layout -enc UTF-8 -eol unix',
      -- Etterbehandlingen er en del av oppskriften: uten den kommer ingen
      -- tredjepart fram til den samme teksten (migrasjon 003g).
      'transform', 'antidep-reading-order@1'
    )
  ),
  'dokumentbindingen følger raden, med hele oppskriften'
);
select is(
  (select value -> 'drugs' -> 0 ->> 'label' from built where name = 'fulltekst'),
  'sertralin',
  'navneoppslaget er ufølsomt for store og små bokstaver, og svarer med det kanoniske navnet'
);
select is(
  (select value -> 'drugs' -> 0 ->> 'drug_id' from built where name = 'fulltekst'),
  (select id::text from catalog.drugs where canonical_name = 'sertralin'),
  'det er katalogens egen id som havner i oppdraget'
);
select is(
  (select value -> 'populations' -> 0 ->> 'population_id' from built where name = 'fulltekst'),
  (select id::text from catalog.populations where canonical_label = 'voksne med depressiv lidelse'),
  'populasjonen slås opp på den kanoniske etiketten'
);
select is(
  (select value -> 'document' from built where name = 'sammendrag'),
  'null'::jsonb,
  'en versjon som ikke er utledet av et dokument, får null — ikke et objekt med tomme felter'
);
select is(
  (select jsonb_array_length(value -> 'populations') from built where name = 'sammendrag'),
  0,
  'en tom populasjonsliste er en reell tilstand, ikke en feil'
);

-- ===========================================================================
-- Del 5 — Avvisningene
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"65000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;

select throws_ok(
  $$
    select api.build_extraction_assignment(
      '5f650000-0000-4000-8000-000000000001', array['fluoksetin'], array['vektendring'])
  $$,
  'P0002', 'Ukjent virkestoff i katalogen: ''fluoksetin''.',
  'et virkestoff som ikke finnes, navngis — oppdraget blir ikke bygget uten det'
);
select throws_ok(
  $$
    select api.build_extraction_assignment(
      '5f650000-0000-4000-8000-000000000001', array['sertralin'], array['depressiv lidelse'])
  $$,
  'P0002', 'Ukjent endepunkt i katalogen: ''depressiv lidelse''.',
  'et begrep som ikke er et endepunkt, kan et evidensfunn ikke peke på'
);
select throws_ok(
  $$
    select api.build_extraction_assignment(
      '5f650000-0000-4000-8000-000000000001', array['sertralin'], array['vektendring'],
      array['barn og unge'])
  $$,
  'P0002', 'Ukjent populasjon i katalogen: ''barn og unge''.',
  'en populasjon som ikke finnes, navngis'
);
select throws_ok(
  $$
    select api.build_extraction_assignment(
      '5f650000-0000-4000-8000-000000000001', array[]::text[], array['vektendring'])
  $$,
  '22023', 'Et oppdrag må åpne for minst ett virkestoff.',
  'en tom avgrensning ville latt modellen velge fritt, og avvises'
);
select throws_ok(
  $$
    select api.build_extraction_assignment(
      '5f650000-0000-4000-8000-000000000003', array['sertralin'], array['vektendring'])
  $$,
  '22023', 'Kildeversjonen har ingen content_hash, og kan derfor ikke bære et ekstraksjonsoppdrag.',
  'en versjon uten fingeravtrykk avvises før arbeidet, ikke etter'
);
select throws_ok(
  $$
    select api.build_extraction_assignment(
      '5f650000-0000-4000-8000-000000000004', array['sertralin'], array['vektendring'])
  $$,
  '22023', 'Kildeversjonen sier ikke hva slags representasjon den er.',
  'en versjon uten representasjonstype avvises: ingen ville visst om ekstraksjonen bygde på et sammendrag eller en fulltekst'
);
select throws_ok(
  $$
    select api.build_extraction_assignment(
      '5f650000-0000-4000-8000-0000000000ff', array['sertralin'], array['vektendring'])
  $$,
  'P0002', null,
  'en kildeversjon som ikke finnes, gir ingen tom struktur'
);

reset role;
select set_config('request.jwt.claims', '', true);

select finish();

rollback;
