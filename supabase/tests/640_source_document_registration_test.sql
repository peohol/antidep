-- Migrasjon 003e — kildeversjonen som er utledet av et originaldokument.
--
-- Filen dekker de samme fire tingene som 450_source_version_registration_test.sql
-- gjør for tekstveien — kontrakten, autorisasjonen, konsekvensen og
-- avvisningene — og i tillegg det som bare gjelder her:
--
--   * at fingeravtrykket av dokumentet, størrelsen og mediatypen eies av
--     databasen og ikke av kalleren,
--   * at dokumentbindingen og oppskriften er alt-eller-ingenting,
--   * at begge er uforanderlige etter registreringen, og
--   * at en PDF ikke kan presses gjennom tekstveien, og at et sammendrag som
--     allerede er registrert, ikke kan registreres på nytt som fulltekst.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23505 = unique_violation, 23514 = check_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(31);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'create_source_version_from_document',
  'api.create_source_version_from_document() finnes'
);
select has_function(
  'knowledge', 'source_document_fingerprint',
  'knowledge.source_document_fingerprint() finnes'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.create_source_version_from_document(uuid,timestamptz,text,text,text,text,text,text,text,text,text)'::regprocedure),
  'skriveveien er SECURITY DEFINER'
);
select ok(
  (select exists (
     select 1
     from pg_proc p, unnest(coalesce(p.proconfig, array[]::text[])) as cfg
     where p.oid = 'api.create_source_version_from_document(uuid,timestamptz,text,text,text,text,text,text,text,text,text)'::regprocedure
       and cfg like 'search_path=%'
   )),
  'skriveveien har tomt search_path'
);

select ok(
  has_function_privilege('authenticated',
    'api.create_source_version_from_document(uuid,timestamptz,text,text,text,text,text,text,text,text,text)', 'EXECUTE'),
  'authenticated kan kalle skriveveien'
);
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.create_source_version_from_document(uuid,timestamptz,text,text,text,text,text,text,text,text,text)',
      'EXECUTE'
    )
  $$,
  'verken anon, service_role eller PUBLIC kan kalle den'
);

-- Fingeravtrykket, størrelsen og mediatypen er ikke parametre. Kunne kalleren
-- oppgi dem, ville de vært påstander om seg selv framfor observasjoner av
-- dokumentet.
select is_empty(
  $$
    select argname
    from pg_proc p
    cross join lateral unnest(p.proargnames) as argname
    where p.oid = 'api.create_source_version_from_document(uuid,timestamptz,text,text,text,text,text,text,text,text,text)'::regprocedure
      and argname in ('p_document_sha256', 'p_document_byte_size', 'p_document_media_type',
                      'p_content_hash', 'p_retrieved_by_actor_id')
  $$,
  'verken dokumentets fingeravtrykk, størrelse, mediatype, teksthashen eller aktøren kan oppgis av kalleren'
);

-- ===========================================================================
-- Del 2 — Fingeravtrykket: hva som faktisk hashes
--
-- Samme referanseverdi som tekstveien bruker (`printf 'antidep' | sha256sum`),
-- men over bytene. At de to gir samme verdi for samme innhold, er nettopp det
-- som gjør at en tredjepart kan etterprøve begge med det samme verktøyet.
-- ===========================================================================
select is(
  knowledge.source_document_fingerprint(decode('YW50aWRlcA==', 'base64')),
  'sha256:4f031f35e9e54f26eaed0a8e2333d6d51dd0be1d72d67a74ee8b72ca46b0dfba',
  'fingeravtrykket er sha256 av bytene — samme verdi som `printf ''antidep'' | sha256sum`'
);
select is(
  knowledge.source_document_fingerprint(null),
  null,
  'ingen byte gir ingen påstand om et fingeravtrykk'
);

-- ===========================================================================
-- Del 3 — Fikstur
--
--   A  aktør uten rolletildeling
--   B  aktør med gyldig editor-tildeling
-- ===========================================================================
insert into auth.users (id, email) values
  ('64000000-0000-4000-8000-00000000000a', 'dokument-640-a@test.invalid'),
  ('64000000-0000-4000-8000-00000000000b', 'dokument-640-b@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac640000-0000-4000-8000-00000000000a', 'human', 'human:dokument-640-a', 'Kaller A',
   'Aktør uten rolletildeling, for 640.', '64000000-0000-4000-8000-00000000000a'),
  ('ac640000-0000-4000-8000-00000000000b', 'human', 'human:dokument-640-b', 'Kaller B',
   'Aktør med gyldig editor-tildeling, for 640.', '64000000-0000-4000-8000-00000000000b');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('64000000-0000-4000-8000-00000000000b', 'editor', null, now() - interval '1 year',
   'ac640000-0000-4000-8000-00000000000b', 'Gyldig tildeling for kaller B i 640.');

insert into knowledge.sources
  (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('50640000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 640',
   'Testforfatter 640', 'ac640000-0000-4000-8000-00000000000b');

-- En liten «PDF»: bare signaturen og litt innhold. Databasen leser signaturen,
-- ikke dokumentstrukturen — tekstuttrekkingen er kjørerens ansvar, og prøves
-- der (src/agents/source-binding.test.ts, scripts/agent-chain-test.ts).
create temporary table fixture (name text primary key, value text not null) on commit drop;
grant select, insert on fixture to authenticated;
insert into fixture (name, value) values
  ('pdf', encode(convert_to('%PDF-1.4' || chr(10) || 'Mean weight change 1.0%.', 'UTF8'), 'base64')),
  ('annen_pdf', encode(convert_to('%PDF-1.4' || chr(10) || 'En annen artikkel.', 'UTF8'), 'base64')),
  ('ikke_pdf', encode(convert_to('<PubmedArticle>ikke en pdf</PubmedArticle>', 'UTF8'), 'base64'));

-- ===========================================================================
-- Del 4 — Autorisasjonen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"64000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  $$
    select api.create_source_version_from_document(
      '50640000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/640',
      (select value from fixture where name = 'pdf'), 'Mean weight change 1.0%.',
      'full_text', 'pdftotext', 'pdftotext 24.02.0', '-layout -enc UTF-8 -eol unix')
  $$,
  '42501', null,
  'en innlogget bruker uten editor-rolle får ikke registrere en dokumentutledet kildeversjon'
);
reset role;
select set_config('request.jwt.claims', '', true);

-- ===========================================================================
-- Del 5 — Konsekvensen: hva som faktisk blir skrevet
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"64000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;

insert into fixture (name, value)
select 'version', api.create_source_version_from_document(
  '50640000-0000-4000-8000-000000000001',
  now() - interval '1 hour',
  'https://doi.org/10.0000/640',
  (select value from fixture where name = 'pdf'),
  'Mean weight change 1.0%.',
  'full_text',
  'pdftotext', 'pdftotext 24.02.0', '-layout -enc UTF-8 -eol unix'
)::text;

reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (select sv.document_sha256 from knowledge.source_versions sv
   where sv.id = (select value from fixture where name = 'version')::uuid),
  knowledge.source_document_fingerprint(
    decode((select value from fixture where name = 'pdf'), 'base64')),
  'dokumentets fingeravtrykk er databasens egen beregning av bytene kalleren sendte'
);
select is(
  (select sv.document_byte_size from knowledge.source_versions sv
   where sv.id = (select value from fixture where name = 'version')::uuid),
  octet_length(decode((select value from fixture where name = 'pdf'), 'base64'))::bigint,
  'størrelsen er målt, ikke oppgitt'
);
select is(
  (select sv.document_media_type from knowledge.source_versions sv
   where sv.id = (select value from fixture where name = 'version')::uuid),
  'application/pdf',
  'mediatypen er avlest av dokumentets egen signatur'
);
select is(
  (select sv.content_hash from knowledge.source_versions sv
   where sv.id = (select value from fixture where name = 'version')::uuid),
  knowledge.source_version_content_hash('Mean weight change 1.0%.'),
  'content_hash er hashen av teksten oppskriften ga, ikke av dokumentet'
);
select is(
  (select sv.representation::text from knowledge.source_versions sv
   where sv.id = (select value from fixture where name = 'version')::uuid),
  'full_text',
  'representasjonstypen er den kalleren oppga'
);
select is(
  (select sv.text_extraction_tool || ' | ' || sv.text_extraction_tool_version
          || ' | ' || sv.text_extraction_arguments
   from knowledge.source_versions sv
   where sv.id = (select value from fixture where name = 'version')::uuid),
  'pdftotext | pdftotext 24.02.0 | -layout -enc UTF-8 -eol unix',
  'hele oppskriften er bevart ordrett, slik at teksten kan reproduseres'
);
select is(
  (select sv.retrieved_by_actor_id from knowledge.source_versions sv
   where sv.id = (select value from fixture where name = 'version')::uuid),
  'ac640000-0000-4000-8000-00000000000b'::uuid,
  'raden er attribuert til kallerens egen aktør'
);
select is(
  (select count(*) from audit.events e
   where e.object_id = (select value from fixture where name = 'version')::uuid
     and e.operation = 'source_version_registered'),
  1::bigint,
  'registreringen har sin auditrad, skrevet i den samme transaksjonen'
);

-- ===========================================================================
-- Del 6 — Uforanderligheten
-- ===========================================================================
select throws_ok(
  $$
    update knowledge.source_versions
    set document_sha256 = 'sha256:' || repeat('0', 64)
    where id = (select value from fixture where name = 'version')::uuid
  $$,
  '23001', null,
  'dokumentets fingeravtrykk kan ikke endres etterpå'
);
select throws_ok(
  $$
    update knowledge.source_versions
    set text_extraction_arguments = '-raw'
    where id = (select value from fixture where name = 'version')::uuid
  $$,
  '23001', null,
  'oppskriften kan ikke endres etterpå — den er halve etterprøvbarheten'
);

-- ===========================================================================
-- Del 7 — Avvisningene
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"64000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;

select throws_ok(
  $$
    select api.create_source_version_from_document(
      '50640000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/640-ikke-pdf',
      (select value from fixture where name = 'ikke_pdf'), 'noe tekst',
      'full_text', 'pdftotext', 'pdftotext 24.02.0', '-layout')
  $$,
  '22023', 'Originaldokumentet er ikke en PDF.',
  'et dokument som ikke er en PDF, avvises på sin egen signatur'
);
select throws_ok(
  $$
    select api.create_source_version_from_document(
      '50640000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/640-tom',
      '', 'noe tekst', 'full_text', 'pdftotext', 'pdftotext 24.02.0', '-layout')
  $$,
  '22023', 'Originaldokumentet mangler, og da kan ingen dokumentbundet kildeversjon registreres.',
  'et manglende dokument avvises'
);
select throws_ok(
  $$
    select api.create_source_version_from_document(
      '50640000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/640-uten-type',
      (select value from fixture where name = 'annen_pdf'), 'noe tekst',
      '  ', 'pdftotext', 'pdftotext 24.02.0', '-layout')
  $$,
  '22023', 'Representasjonstypen mangler.',
  'en dokumentutledet versjon uten representasjonstype avvises — det er den tilstanden veien finnes for å unngå'
);
select throws_ok(
  $$
    select api.create_source_version_from_document(
      '50640000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/640-pdf-som-tekst',
      (select value from fixture where name = 'annen_pdf'),
      '%PDF-1.4' || chr(10) || 'dokumentet en gang til',
      'full_text', 'pdftotext', 'pdftotext 24.02.0', '-layout')
  $$,
  '22023', 'Den uttrukne teksten er selv en PDF, og er dermed ikke tekst noen kan lese et ordrett utdrag ut av.',
  'dokumentet sendt inn som «tekst» avvises'
);
select throws_ok(
  $$
    select api.create_source_version_from_document(
      '50640000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/640-igjen',
      (select value from fixture where name = 'annen_pdf'), 'Mean weight change 1.0%.',
      'abstract', 'pdftotext', 'pdftotext 24.02.0', '-layout')
  $$,
  '23505', 'Nøyaktig samme innhold er allerede registrert som en kildeversjon for denne kilden.',
  'den samme teksten kan ikke registreres på nytt under en annen representasjonstype'
);

-- En PDF gjennom tekstveien: den ene feilen dokumentveien gjør lettere å gjøre,
-- og derfor den ene som stenges eksplisitt. Hashen ville ellers vært av
-- omkodingen framfor av filen, og ingen kunne reprodusert den med sha256sum.
select throws_ok(
  $$
    select api.create_source_version(
      '50640000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/640-tekstveien',
      '%PDF-1.4' || chr(10) || 'binærinnhold', null, null, 'full_text')
  $$,
  '22023', 'Innholdet er en PDF, og en PDF kan ikke registreres som en tekstrepresentasjon.',
  'tekstveien avviser en PDF, og sier hvilken vei som gjelder i stedet'
);

reset role;
select set_config('request.jwt.claims', '', true);

-- ===========================================================================
-- Del 8 — Alt-eller-ingenting, prøvd der regelen bor
--
-- Kjøres som eier og direkte mot tabellen: CHECK-en er fasiten uansett hvilken
-- skrivevei som en dag fører hit, og en halv dokumentbinding er en påstand
-- ingen kan etterprøve.
-- ===========================================================================
select throws_ok(
  $$
    insert into knowledge.source_versions
      (source_id, retrieved_at, retrieved_from, content_hash, representation,
       document_sha256, retrieved_by_actor_id)
    values ('50640000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/640-halv',
            'sha256:' || repeat('e', 64), 'full_text', 'sha256:' || repeat('f', 64),
            'ac640000-0000-4000-8000-00000000000b')
  $$,
  '23514', null,
  'et dokumentfingeravtrykk uten oppskrift avvises: det ville sagt hvilken fil, men ikke hvordan'
);
select throws_ok(
  $$
    insert into knowledge.source_versions
      (source_id, retrieved_at, retrieved_from, content_hash, representation,
       text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
       retrieved_by_actor_id)
    values ('50640000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/640-oppskrift',
            'sha256:' || repeat('d', 64), 'full_text',
            'pdftotext', 'pdftotext 24.02.0', '-layout',
            'ac640000-0000-4000-8000-00000000000b')
  $$,
  '23514', null,
  'en oppskrift uten dokument avvises: den ville sagt hvordan, men ikke av hva'
);
select throws_ok(
  $$
    insert into knowledge.source_versions
      (source_id, retrieved_at, retrieved_from, content_hash,
       document_sha256, document_byte_size, document_media_type,
       text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
       retrieved_by_actor_id)
    values ('50640000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/640-uten-rep',
            'sha256:' || repeat('c', 64),
            'sha256:' || repeat('b', 64), 1234, 'application/pdf',
            'pdftotext', 'pdftotext 24.02.0', '-layout',
            'ac640000-0000-4000-8000-00000000000b')
  $$,
  '23514', null,
  'en dokumentutledet versjon uten representasjonstype avvises av CHECK-en, ikke bare av skriveveien'
);
select throws_ok(
  $$
    insert into knowledge.source_versions
      (source_id, retrieved_at, retrieved_from, content_hash, representation,
       document_sha256, document_byte_size, document_media_type,
       text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
       retrieved_by_actor_id)
    values ('50640000-0000-4000-8000-000000000001', now(), 'https://eksempel.invalid/640-tekstmedia',
            'sha256:' || repeat('9', 64), 'full_text',
            'sha256:' || repeat('8', 64), 1234, 'text/plain',
            'pdftotext', 'pdftotext 24.02.0', '-layout',
            'ac640000-0000-4000-8000-00000000000b')
  $$,
  '23514', null,
  'et «dokument» med en tekstlig mediatype avvises: er representasjonen tekst, er den sitt eget fingeravtrykk'
);

-- ===========================================================================
-- Del 9 — Den redaksjonelle lesemodellen viser bindingen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"64000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select is(
  (select v.document_media_type || ' / ' || v.representation
   from api.editor_source_versions v
   where v.source_version_id = (select value from fixture where name = 'version')::uuid),
  'application/pdf / full_text',
  'editoren ser både representasjonstypen og hva slags dokument versjonen er utledet av'
);
reset role;
select set_config('request.jwt.claims', '', true);

select finish();

rollback;
