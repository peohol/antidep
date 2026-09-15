-- Migrasjon 009a — det private fulltekstbiblioteket.
--
-- Filen dekker de fire tingene migrasjonen faktisk innfører:
--
--   * at originalfilen blir liggende, privat, og at identiteten er innholdet,
--   * at publikasjonstilhørigheten kontrolleres av teksten framfor å erklæres,
--   * at lesbarheten kontrolleres, tabellene særskilt, og
--   * at gaten for klinisk evidens nå krever alle tre.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23514 = check_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(28);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('knowledge', 'source_documents', 'knowledge.source_documents finnes');
select has_table('knowledge', 'source_document_publications',
                 'knowledge.source_document_publications finnes');
select has_table('knowledge', 'full_text_readability_checks',
                 'knowledge.full_text_readability_checks finnes');

-- Biblioteket er privat. Ikke «bare RLS», og ikke «bare uten grants»: begge,
-- fordi et grant uten policy og en policy uten grant hver for seg er en
-- halvåpen dør (DATABASE_ARCHITECTURE.md §44).
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    where has_table_privilege(r.role_name, 'knowledge.source_documents', 'SELECT')
  $$,
  'ingen rolle kan lese originalfilene direkte'
);
select ok(
  (select c.relrowsecurity from pg_class c
   where c.oid = 'knowledge.source_documents'::regclass),
  'biblioteket har RLS'
);

select ok(
  has_function_privilege('authenticated',
    'api.upload_full_text_document(uuid,timestamptz,text,text,text,text,text,text,text,text)',
    'EXECUTE'),
  'authenticated kan kalle opplastingen'
);
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.upload_full_text_document(uuid,timestamptz,text,text,text,text,text,text,text,text)',
      'EXECUTE')
  $$,
  'verken anon, service_role eller PUBLIC kan laste opp'
);

-- Fingeravtrykket, størrelsen, mediatypen og representasjonen er ikke
-- parametre. Kunne kalleren oppgi dem, ville de vært påstander om seg selv
-- framfor observasjoner av dokumentet.
select is_empty(
  $$
    select argname
    from pg_proc p
    cross join lateral unnest(p.proargnames) as argname
    where p.oid = 'api.upload_full_text_document(uuid,timestamptz,text,text,text,text,text,text,text,text)'::regprocedure
      and argname in ('p_document_sha256', 'p_document_byte_size', 'p_document_media_type',
                      'p_representation', 'p_content_hash', 'p_actor_id')
  $$,
  'verken fingeravtrykk, størrelse, mediatype, representasjon eller aktør kan oppgis av kalleren'
);

-- ===========================================================================
-- Del 2 — Lesbarhetsdommen, felt på tall
-- ===========================================================================

-- En fulltekst som faktisk ser ut som en artikkel: brødtekst nok, og en tabell
-- som overlevde tekstuttrekkingen.
--
-- Mellomrommene mellom cellene er *enkle*, slik Antideps leserekkefølge faktisk
-- setter dem (src/agents/reading-order.ts). En fikstur med kolonner justert av
-- flere mellomrom ville vært en fikstur av «pdftotext -layout», som Antidep
-- ikke registrerer nye kildeversjoner med — og prøven ville bekreftet en regel
-- kjeden aldri møter.
create function pg_temp.readable_full_text() returns text language sql immutable as $$
  select repeat(
    'Patients with major depressive disorder were randomised to treatment.'
    || chr(10), 80)
    || 'Table 1 Baseline characteristics' || chr(10)
    || 'Age (years) 42.1 41.8' || chr(10)
    || 'Weight (kg) 74.2 73.9' || chr(10)
    || 'BMI (kg/m2) 25.1 24.8' || chr(10)
$$;

-- Den samme artikkelen der tabellen ble droppet som et bilde. Brødteksten er
-- uendret, og det er nettopp derfor denne formen er farlig: teksten ser hel ut
-- samtidig som de kliniske tallene mangler.
create function pg_temp.full_text_without_tables() returns text language sql immutable as $$
  select repeat(
    'Patients with major depressive disorder were randomised to treatment.'
    || chr(10), 80)
    || 'Table 1 Baseline characteristics' || chr(10)
$$;

select is(
  knowledge.full_text_readability_problem(pg_temp.readable_full_text()),
  null,
  'en fulltekst med brødtekst og en overlevd tabell godtas'
);
select ok(
  knowledge.full_text_readability_problem(pg_temp.full_text_without_tables())
    like '%datarad%',
  'en fulltekst der tabellen ble borte, avvises med tabellkontrollen som grunn'
);
select ok(
  knowledge.full_text_readability_problem('Kort sammendrag.') like '%3000%',
  'et sammendrag avvises på mengde tekst'
);
select is(
  (knowledge.full_text_readability_metrics(pg_temp.readable_full_text()) ->> 'table_rows')::int,
  3,
  'målingen teller de tre faktiske dataradene'
);
-- En resultatsetning har tall i seg uten å være en tabellrad. Uten dette
-- skillet ville en artikkel uten tabeller sett ut som en med.
select is(
  (knowledge.full_text_readability_metrics(
     'Mean percent weight change was 1.0% at endpoint with a 95% confidence interval from 0.5% to 1.5%.'
   ) ->> 'table_rows')::int,
  0,
  'en resultatsetning er brødtekst, ikke en datarad'
);
select is(
  (knowledge.full_text_readability_metrics(pg_temp.readable_full_text())
     ->> 'table_declarations')::int,
  1,
  'målingen teller tabellerklæringen'
);

-- ===========================================================================
-- Del 3 — Fikstur: en redaktør og en publikasjon med registrert DOI
-- ===========================================================================
insert into auth.users (id, email)
values ('73000000-0000-4000-8000-00000000000b', 'bibliotek-730@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values ('ac730000-0000-4000-8000-00000000000b', 'human', 'human:bibliotek-730',
        'Redaktør 730', 'Aktør med gyldig editor-tildeling, for 730.',
        '73000000-0000-4000-8000-00000000000b');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('73000000-0000-4000-8000-00000000000b', 'editor', null, now() - interval '1 year',
        'ac730000-0000-4000-8000-00000000000b', 'Gyldig tildeling for 730.');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('73000000-0000-4000-8000-000000000001', 'journal_article',
        'Fulltekstbibliotekets testartikkel om vektendring', 'Testforfatter 730',
        'ac730000-0000-4000-8000-00000000000b'),
       ('73000000-0000-4000-8000-000000000002', 'journal_article',
        'En helt annen testartikkel uten noen identitet i teksten', 'Testforfatter 730',
        'ac730000-0000-4000-8000-00000000000b');

insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
values ('73000000-0000-4000-8000-000000000001', 'doi', '10.1234/antidep.730');

create temporary table fixture (name text primary key, value text not null) on commit drop;
grant select, insert on fixture to authenticated;
insert into fixture (name, value) values
  ('pdf', encode(convert_to('%PDF-1.4' || chr(10) || 'Syntetisk fulltekst for 730.', 'UTF8'),
                 'base64')),
  ('annen_pdf', encode(convert_to('%PDF-1.4' || chr(10) || 'En annen fil for 730.', 'UTF8'),
                       'base64')),
  ('ikke_pdf', encode(convert_to('<article>ikke en pdf</article>', 'UTF8'), 'base64'));

-- Teksten bærer kildens DOI, som er det sterkeste bindingsgrunnlaget.
create function pg_temp.bound_full_text() returns text language sql immutable as $$
  select 'doi: 10.1234/antidep.730' || chr(10) || pg_temp.readable_full_text()
$$;

create temporary table uploaded (name text primary key, payload jsonb not null) on commit drop;
grant select, insert on uploaded to authenticated;

-- ===========================================================================
-- Del 4 — Autorisasjonen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-8000-0000000000ff"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$select api.upload_full_text_document(
        '73000000-0000-4000-8000-000000000001', now(), 'https://example.test/730',
        %L, %L, 'pdftotext', '24.02.0',
        '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2')$$,
    (select value from fixture where name = 'pdf'),
    pg_temp.bound_full_text()
  ),
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en kaller uten aktørrad kan ikke laste opp'
);
reset role;

-- ===========================================================================
-- Del 5 — Opplastingen, og de tre kontrollene
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"73000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;

-- En fil som ikke er en PDF, stoppes av bytene sine og ikke av navnet.
select throws_ok(
  format(
    $$select api.upload_full_text_document(
        '73000000-0000-4000-8000-000000000001', now(), 'https://example.test/730',
        %L, %L, 'pdftotext', '24.02.0',
        '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2')$$,
    (select value from fixture where name = 'ikke_pdf'),
    pg_temp.bound_full_text()
  ),
  '22023', 'Originaldokumentet er ikke en PDF.',
  'en fil som ikke er en PDF, avvises på signaturen'
);

-- Publikasjonstilhørigheten: den samme filen under en kilde teksten ikke
-- nevner, blir ingen fulltekstversjon.
select throws_ok(
  format(
    $$select api.upload_full_text_document(
        '73000000-0000-4000-8000-000000000002', now(), 'https://example.test/730-feil',
        %L, %L, 'pdftotext', '24.02.0',
        '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2')$$,
    (select value from fixture where name = 'pdf'),
    pg_temp.bound_full_text()
  ),
  '23001', 'Fullteksten bærer ingen av kildens registrerte identiteter, og kan derfor ikke vises å være denne publikasjonen.',
  'en fil som ikke kan vises å tilhøre publikasjonen, avvises'
);

-- Lesbarheten: en artikkel der tabellene ble borte, blir ingen fulltekst.
select throws_ok(
  format(
    $$select api.upload_full_text_document(
        '73000000-0000-4000-8000-000000000001', now(), 'https://example.test/730-uten-tabell',
        %L, %L, 'pdftotext', '24.02.0',
        '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2')$$,
    (select value from fixture where name = 'annen_pdf'),
    'doi: 10.1234/antidep.730' || chr(10) || pg_temp.full_text_without_tables()
  ),
  '23001', null,
  'en fulltekst der tabellene ble borte, avvises av opplastingen'
);

-- Den gyldige opplastingen.
insert into uploaded (name, payload)
select 'first', api.upload_full_text_document(
  '73000000-0000-4000-8000-000000000001', now(), 'https://example.test/730',
  (select value from fixture where name = 'pdf'), pg_temp.bound_full_text(),
  'pdftotext', '24.02.0', '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
);

-- Og den samme igjen: idempotens er hele grunnen til at en avbrutt jobb kan
-- gjenopptas uten å rydde.
insert into uploaded (name, payload)
select 'again', api.upload_full_text_document(
  '73000000-0000-4000-8000-000000000001', now(), 'https://example.test/730',
  (select value from fixture where name = 'pdf'), pg_temp.bound_full_text(),
  'pdftotext', '24.02.0', '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
);
reset role;

select is(
  (select payload -> 'publication_binding' ->> 'basis' from uploaded where name = 'first'),
  'doi',
  'bindingen er gjort på kildens registrerte DOI'
);
select is(
  (select (payload ->> 'document_stored')::boolean
          and (payload ->> 'source_version_created')::boolean
     from uploaded where name = 'first'),
  true,
  'første opplasting oppretter både filen og kildeversjonen'
);
select is(
  (select (payload ->> 'document_stored')::boolean
          or (payload ->> 'source_version_created')::boolean
     from uploaded where name = 'again'),
  false,
  'en gjentatt opplasting av den samme filen oppretter ingenting nytt'
);
select is(
  (select payload ->> 'source_version_id' from uploaded where name = 'first'),
  (select payload ->> 'source_version_id' from uploaded where name = 'again'),
  'gjentakelsen finner den samme kildeversjonen'
);
select is(
  (select count(*)::int from knowledge.source_documents d
   where d.sha256 = (select payload ->> 'document_sha256' from uploaded where name = 'first')),
  1,
  'filen ligger i biblioteket i nøyaktig én kopi'
);
select is(
  (select knowledge.source_document_fingerprint(d.content)
   from knowledge.source_documents d
   where d.sha256 = (select payload ->> 'document_sha256' from uploaded where name = 'first')),
  (select payload ->> 'document_sha256' from uploaded where name = 'first'),
  'fingeravtrykket i raden er fingeravtrykket av innholdet'
);

-- En rad kan ikke bære et fingeravtrykk som ikke er innholdets. Det er
-- forskjellen på en garanti og en påstand.
select throws_ok(
  $$insert into knowledge.source_documents (sha256, byte_size, media_type, content, stored_by_actor_id)
    select 'sha256:' || repeat('0', 64), 9, 'application/pdf',
           convert_to('%PDF-1.4', 'UTF8'),
           (select id from provenance.actors where actor_key = 'human:peder-holman')$$,
  '23514', null,
  'et oppdiktet fingeravtrykk kan ikke lagres'
);

-- ===========================================================================
-- Del 6 — Gaten for klinisk evidens krever biblioteket
-- ===========================================================================
select lives_ok(
  format(
    $$select knowledge.assert_clinical_full_text(
        '73000000-0000-4000-8000-000000000001', %L)$$,
    (select payload ->> 'source_version_id' from uploaded where name = 'first')
  ),
  'en fulltekst fra biblioteket passerer gaten'
);

-- En kildeversjon med komplett dokumentbinding, men uten filen i biblioteket:
-- nøyaktig den tilstanden som var lovlig før migrasjon 009a.
insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash, representation,
  document_sha256, document_byte_size, document_media_type, text_extraction_tool,
  text_extraction_tool_version, text_extraction_arguments, text_extraction_transform,
  retrieved_by_actor_id
)
values ('73000000-0000-4000-8000-000000000031', '73000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/730-uten-bibliotek', 'sha256:' || repeat('c', 64),
        'full_text', 'sha256:' || repeat('d', 64), 1024, 'application/pdf',
        'pdftotext', '24.02.0', '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2',
        'ac730000-0000-4000-8000-00000000000b');

select throws_ok(
  $$select knowledge.assert_clinical_full_text(
      '73000000-0000-4000-8000-000000000001', '73000000-0000-4000-8000-000000000031')$$,
  '23001', 'Originaldokumentet ligger ikke i fulltekstbiblioteket.',
  'en fulltekst ingen kan hente fram igjen, bærer ikke klinisk evidens'
);

-- Og den samme filen i biblioteket, men uten lesbarhetskontroll for nettopp
-- denne kildeversjonen: fraværet av kontrollraden er dommen.
insert into knowledge.source_documents (sha256, byte_size, media_type, content, stored_by_actor_id)
select knowledge.source_document_fingerprint(convert_to('%PDF-1.4' || chr(10) || '730-c', 'UTF8')),
       octet_length(convert_to('%PDF-1.4' || chr(10) || '730-c', 'UTF8')), 'application/pdf',
       convert_to('%PDF-1.4' || chr(10) || '730-c', 'UTF8'),
       'ac730000-0000-4000-8000-00000000000b';

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash, representation,
  document_sha256, document_byte_size, document_media_type, text_extraction_tool,
  text_extraction_tool_version, text_extraction_arguments, text_extraction_transform,
  retrieved_by_actor_id
)
select '73000000-0000-4000-8000-000000000032', '73000000-0000-4000-8000-000000000001',
       now(), 'https://example.test/730-uten-lesbarhet', 'sha256:' || repeat('e', 64),
       'full_text',
       knowledge.source_document_fingerprint(convert_to('%PDF-1.4' || chr(10) || '730-c', 'UTF8')),
       octet_length(convert_to('%PDF-1.4' || chr(10) || '730-c', 'UTF8')), 'application/pdf',
       'pdftotext', '24.02.0', '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2',
       'ac730000-0000-4000-8000-00000000000b';

insert into knowledge.source_document_publications
  (source_document_id, source_id, binding_basis, binding_evidence, bound_by_actor_id)
select d.id, '73000000-0000-4000-8000-000000000001', 'title', 'syntetisk binding for 730',
       'ac730000-0000-4000-8000-00000000000b'
from knowledge.source_documents d
where d.sha256 = knowledge.source_document_fingerprint(
  convert_to('%PDF-1.4' || chr(10) || '730-c', 'UTF8'));

select throws_ok(
  $$select knowledge.assert_clinical_full_text(
      '73000000-0000-4000-8000-000000000001', '73000000-0000-4000-8000-000000000032')$$,
  '23001', 'Fulltekstversjonen har ingen bestått lesbarhetskontroll.',
  'en fulltekst uten bestått lesbarhetskontroll bærer ikke klinisk evidens'
);

select * from finish();
rollback;
