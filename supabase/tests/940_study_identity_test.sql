-- Migrasjon 013l — studien som en virksom del av arbeidsflyten.
--
-- 013g ga studien og rapportkoblingen sine regler. 880 prøver reglene. Denne
-- filen prøver at koblingen faktisk *brukes*: at det finnes en kontrollert
-- skrivevei, at kildeoppdagelsen fyller den av seg selv når treffet kom på et
-- forsøksregisternummer, og at grunnlaget for en syntese sier hvor mange
-- uavhengige studier det hviler på.
--
-- Kravet er fra SOURCE_POLICY.md §7: hovedartikkel, sekundæranalyse og
-- langtidsoppfølging fra den samme studien er ikke tre uavhengige
-- deltakerutvalg. Et skjema ingen leser, hindrer ingen dobbelttelling.
--
-- SQLSTATE 22023 = invalid_parameter_value, 23001 = restrict_violation,
-- 02000 = no_data_found, 42501 = insufficient_privilege.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(27);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function('knowledge', 'study_units_for_evidence', array['uuid[]'],
                    'knowledge.study_units_for_evidence(uuid[]) finnes');
select has_function('knowledge', 'register_study_report',
                    'knowledge.register_study_report(...) finnes');
select has_function('api', 'register_study_report',
                    'api.register_study_report(...) finnes');

select is_empty(
  $$
    select t.name, r.role_name
    from (values ('knowledge.studies'), ('knowledge.study_reports')) as t(name),
         (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, t.name, p.privilege)
  $$,
  'ingen klientrolle skriver i studien eller rapportkoblingen direkte'
);

-- ===========================================================================
-- Del 2 — Oppsettet: to publikasjoner om den samme studien
-- ===========================================================================
insert into auth.users (id, email)
values ('94000000-0000-4000-8000-00000000000a', 'redaktor-940@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values ('ac940000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-940',
        'Redaktør 940', 'Editor uten avgrensning, for 940.',
        '94000000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('94000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
        'ac940000-0000-4000-8000-00000000000a', 'Editor-tildeling for 940.');

create temporary table fixture (name text primary key, id uuid not null) on commit drop;
create temporary table svar (label text primary key, payload jsonb) on commit drop;
grant select on fixture to authenticated;
grant select, insert on svar to authenticated;

insert into fixture (name, id) values ('redaktor', 'ac940000-0000-4000-8000-00000000000a');
insert into fixture (name, id)
select 'owner', id from provenance.actors where actor_key = 'human:peder-holman';

-- Hovedartikkelen og langtidsoppfølgingen: to kilder, samme studie.
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('94000000-0000-4000-8000-000000000001', 'journal_article',
   'Syntetisk hovedartikkel for 940', 'Testforfatter A mfl.',
   (select id from fixture where name = 'owner')),
  ('94000000-0000-4000-8000-000000000002', 'journal_article',
   'Syntetisk langtidsoppfølging for 940', 'Testforfatter A mfl.',
   (select id from fixture where name = 'owner')),
  ('94000000-0000-4000-8000-000000000003', 'journal_article',
   'Syntetisk uavhengig studie for 940', 'Testforfatter B mfl.',
   (select id from fixture where name = 'owner'));

-- ===========================================================================
-- Del 3 — Den kontrollerte skriveveien
-- ===========================================================================
select throws_ok(
  format($$select knowledge.register_study_report(
    %L, 'clinicaltrials_gov', 'NCT00940940', 'Syntetisk studie for 940',
    'primary_report', '   ', 'documented', %L, null)$$,
    '94000000-0000-4000-8000-000000000001',
    (select id from fixture where name = 'redaktor')),
  '22023', null,
  'en kobling uten et dokumentert grunnlag avvises: tittel-likhet er ikke et grunnlag'
);

select throws_ok(
  format($$select knowledge.register_study_report(
    %L, 'clinicaltrials_gov', 'NCT00940940', 'Syntetisk studie for 940',
    'primary_report', 'Artikkelen oppgir registernummeret.', 'documented', %L, null)$$,
    '00000000-0000-4000-8000-0000000000ff',
    (select id from fixture where name = 'redaktor')),
  'P0002', null,
  'og en kobling til en kilde som ikke finnes, avvises'
);

insert into fixture (name, id)
select 'studie', knowledge.register_study_report(
  '94000000-0000-4000-8000-000000000001', 'clinicaltrials_gov', 'NCT00940940',
  'Syntetisk studie for 940', 'primary_report',
  'Hovedartikkelen oppgir NCT00940940 i metodeavsnittet.', 'documented',
  (select id from fixture where name = 'redaktor'), null);

select is(
  (select s.registry_kind || ':' || s.registry_id from knowledge.studies s
   where s.id = (select id from fixture where name = 'studie')),
  'clinicaltrials_gov:NCT00940940',
  'studien er opprettet med registernummeret som identitet'
);

-- Den samme studien igjen, for den andre publikasjonen: ingen ny studie.
select is(
  knowledge.register_study_report(
    '94000000-0000-4000-8000-000000000002', 'clinicaltrials_gov', 'NCT00940940',
    'Syntetisk studie for 940', 'long_term_followup',
    'Oppfølgingen oppgir det samme registernummeret.', 'documented',
    (select id from fixture where name = 'redaktor'), null),
  (select id from fixture where name = 'studie'),
  'den andre publikasjonen kobles til den samme studien, og ikke til en ny'
);

select is(
  (select count(*)::integer from knowledge.study_reports r
   where r.study_id = (select id from fixture where name = 'studie')),
  2,
  'studien har to rapporter'
);

select is(
  knowledge.register_study_report(
    '94000000-0000-4000-8000-000000000002', 'clinicaltrials_gov', 'NCT00940940',
    'Syntetisk studie for 940', 'long_term_followup',
    'Den samme koblingen registrert på nytt.', 'documented',
    (select id from fixture where name = 'redaktor'), null),
  (select id from fixture where name = 'studie'),
  'og den samme koblingen registrert på nytt er den samme koblingen'
);

select is(
  (select count(*)::integer from knowledge.study_reports r
   where r.study_id = (select id from fixture where name = 'studie')),
  2,
  'fortsatt to rapporter: registreringen er idempotent'
);

-- Én kilde hører til høyst én studie.
select throws_ok(
  format($$select knowledge.register_study_report(
    %L, 'clinicaltrials_gov', 'NCT00940941', 'En annen syntetisk studie for 940',
    'primary_report', 'En motstridende kobling.', 'documented', %L, null)$$,
    '94000000-0000-4000-8000-000000000001',
    (select id from fixture where name = 'redaktor')),
  '23001', null,
  'en kilde kan ikke bli rapport om en annen studie i tillegg'
);

-- ===========================================================================
-- Del 4 — Grupperingen: hvor mange uavhengige studier grunnlaget hviler på
-- ===========================================================================
-- Tre evidensfunn: to fra den samme studien, ett fra en annen.
-- Kliniske evidensfunn krever dokumentbundet fulltekst (migrasjon 009a).
-- Fiksturets syntetiske PDF-maskineri gir de tre radene gaten leser: filen,
-- publikasjonstilhørigheten og lesbarhetskontrollen.
insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference,
   representation, retrieved_by_actor_id, document_sha256, document_byte_size,
   document_media_type, text_extraction_tool, text_extraction_tool_version,
   text_extraction_arguments, text_extraction_transform)
select v.id::uuid, v.source_id::uuid, now(), v.url,
       knowledge.source_version_content_hash(v.text),
       'private://syntetisk-940/' || v.id || '.pdf',
       'full_text', (select id from fixture where name = 'owner'),
       pg_temp.synthetic_pdf_digest(v.id),
       octet_length(pg_temp.synthetic_pdf(v.id)),
       'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from (values
  ('94000000-0000-4000-8000-000000000021', '94000000-0000-4000-8000-000000000001',
   'https://example.test/940-a', 'Hovedartikkelen for 940.'),
  ('94000000-0000-4000-8000-000000000022', '94000000-0000-4000-8000-000000000002',
   'https://example.test/940-b', 'Langtidsoppfølgingen for 940.'),
  ('94000000-0000-4000-8000-000000000023', '94000000-0000-4000-8000-000000000003',
   'https://example.test/940-c', 'Den uavhengige studien for 940.')
) as v(id, source_id, url, text);

insert into knowledge.evidence_items
  (id, source_id, source_version_id, design_code, population_availability,
   population_id, population_detail, sample_size_availability, intervention_drug_id,
   comparator_kind, outcome_concept_id, outcome_detail, timepoint_availability,
   reported_direction, estimate_availability, confidence_interval_availability,
   source_locator, extraction_method, created_by_actor_id)
select v.id::uuid, v.source_id::uuid, v.version_id::uuid,
       'randomized_controlled_trial', 'reported_value',
       (select id from catalog.populations
        where canonical_label = 'voksne med depressiv lidelse'),
       'Voksne med depressiv lidelse.', 'not_reported',
       (select id from catalog.drugs where canonical_name = 'sertralin'),
       'none',
       (select id from catalog.clinical_concepts where canonical_label = 'vektendring'),
       'Vektendring ved endepunkt.', 'not_reported', 'no_clear_difference',
       'not_reported', 'not_reported', 'Tabell 1', 'manual',
       (select id from fixture where name = 'owner')
from (values
  ('94000000-0000-4000-8000-000000000031', '94000000-0000-4000-8000-000000000001',
   '94000000-0000-4000-8000-000000000021'),
  ('94000000-0000-4000-8000-000000000032', '94000000-0000-4000-8000-000000000002',
   '94000000-0000-4000-8000-000000000022'),
  ('94000000-0000-4000-8000-000000000033', '94000000-0000-4000-8000-000000000003',
   '94000000-0000-4000-8000-000000000023')
) as v(id, source_id, version_id);

select is(
  (knowledge.study_units_for_evidence(array[
    '94000000-0000-4000-8000-000000000031'::uuid,
    '94000000-0000-4000-8000-000000000032'::uuid,
    '94000000-0000-4000-8000-000000000033'::uuid]) ->> 'evidence_items')::integer,
  3,
  'grunnlaget har tre evidensfunn'
);

-- Dette er hele poenget: tre funn, men bare to uavhengige deltakerutvalg.
select is(
  (knowledge.study_units_for_evidence(array[
    '94000000-0000-4000-8000-000000000031'::uuid,
    '94000000-0000-4000-8000-000000000032'::uuid,
    '94000000-0000-4000-8000-000000000033'::uuid]) ->> 'independent_units')::integer,
  2,
  'men bare to uavhengige studier: to av funnene deler deltakerutvalg'
);

select is(
  (knowledge.study_units_for_evidence(array[
    '94000000-0000-4000-8000-000000000031'::uuid,
    '94000000-0000-4000-8000-000000000032'::uuid,
    '94000000-0000-4000-8000-000000000033'::uuid]) ->> 'shared_studies')::integer,
  1,
  'og én av enhetene bæres av mer enn én rapport'
);

-- Grupperingen sletter ingenting: begge funnene fra den delte studien står.
select is(
  (select count(*)::integer
   from jsonb_array_elements(
          knowledge.study_units_for_evidence(array[
            '94000000-0000-4000-8000-000000000031'::uuid,
            '94000000-0000-4000-8000-000000000032'::uuid,
            '94000000-0000-4000-8000-000000000033'::uuid]) -> 'units') as u(value),
        jsonb_array_elements_text(u.value -> 'evidence_item_ids')),
  3,
  'og ingen av funnene er borte: grupperingen teller, den sletter ikke'
);

-- En kilde uten registrert kobling er sin egen enhet.
select is(
  (knowledge.study_units_for_evidence(array[
    '94000000-0000-4000-8000-000000000033'::uuid]) ->> 'independent_units')::integer,
  1,
  'en kilde uten registrert studiekobling er sin egen enhet'
);

select is(
  (knowledge.study_units_for_evidence(array[]::uuid[]) ->> 'independent_units')::integer,
  0,
  'og et tomt grunnlag hviler på ingen studier'
);

-- En usikker kobling telles for seg, slik at «vi vet ikke» ikke ser ut som
-- «vi har kontrollert det».
select is(
  knowledge.register_study_report(
    '94000000-0000-4000-8000-000000000003', null, null,
    'Syntetisk studie uten registernummer for 940', 'secondary_analysis',
    'Samme forfattergruppe og samme rekrutteringsperiode, men uten oppgitt registernummer.',
    'uncertain', (select id from fixture where name = 'redaktor'), null)
    is not null,
  true,
  'en usikker kobling kan registreres, og blir registrert som usikker'
);

select is(
  (knowledge.study_units_for_evidence(array[
    '94000000-0000-4000-8000-000000000033'::uuid]) ->> 'uncertain_linkage')::integer,
  1,
  'og den telles som usikker i grupperingen'
);

-- ===========================================================================
-- Del 5 — Redaktørens vei, og mandatet
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"94000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'redaktorkobling', api.register_study_report(
  'Syntetisk hovedartikkel for 940', 'clinicaltrials_gov', 'NCT00940940',
  'Syntetisk studie for 940', 'primary_report',
  'Redaktøren bekreftet registernummeret mot metodeavsnittet.', true);
reset role;

select is(
  (select payload ->> 'registry' from svar where label = 'redaktorkobling'),
  'clinicaltrials_gov:NCT00940940',
  'redaktøren når studien med tittelen på artikkelen, og ingen intern id'
);

select is(
  (select (payload ->> 'reports')::integer from svar where label = 'redaktorkobling'),
  2,
  'og svaret sier hvor mange rapporter studien har'
);

insert into auth.users (id, email)
values ('94000000-0000-4000-8000-00000000000b', 'kliniker-940@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values ('ac940000-0000-4000-8000-00000000000b', 'human', 'human:kliniker-940',
        'Kliniker 940', 'Uten redaktørmandat, for 940.',
        '94000000-0000-4000-8000-00000000000b');

select set_config('request.jwt.claims',
                  '{"sub":"94000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  $$select api.register_study_report(
      'Syntetisk uavhengig studie for 940', null, null, 'Noe annet',
      'primary_report', 'Uten mandat.', true)$$,
  '42501', null,
  'en kliniker uten redaktørmandat kan ikke koble en rapport til en studie'
);
reset role;

-- ===========================================================================
-- Del 6 — Tittelen er ikke en identitet (migrasjon 013m)
-- ===========================================================================
-- Redaktørveien slo opp kilden på tittel og tok den eldste. To artikler med
-- samme tittel ga da en stille feilkobling, og en feilkobling er nettopp det
-- som lager en dobbelttelling. Nå avvises det tvetydige oppslaget, og
-- referansen kan i stedet være identifikatoren kilden faktisk har.
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('94000000-0000-4000-8000-000000000004', 'journal_article',
   -- Med vilje den samme tittelen som kilde 3.
   'Syntetisk uavhengig studie for 940', 'Testforfatter C mfl.',
   (select id from fixture where name = 'owner')),
  ('94000000-0000-4000-8000-000000000005', 'journal_article',
   'Syntetisk registeroppføring for 940', 'Testregister',
   (select id from fixture where name = 'owner'));

insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
values
  ('94000000-0000-4000-8000-000000000004', 'doi', '10.9400/940-d'),
  ('94000000-0000-4000-8000-000000000005', 'registry_id', 'NCT00940945');

select set_config('request.jwt.claims',
                  '{"sub":"94000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;

select throws_ok(
  $$select api.register_study_report(
      'Syntetisk uavhengig studie for 940', null, null, 'Noe nytt',
      'primary_report', 'To kilder har denne tittelen.', true)$$,
  '23001', null,
  'et titteloppslag som treffer to kilder, avvises framfor å gjette på den eldste'
);

select throws_ok(
  $$select api.register_study_report(
      'doi:10.9400/finnes-ikke', null, null, 'Noe nytt',
      'primary_report', 'En identifikator Antidep ikke har.', true)$$,
  'P0002', null,
  'og en identifikator Antidep ikke har, gir et tydelig avslag og ingen kobling'
);

-- DOI-en skrives med store bokstaver med vilje: normaliseringen er den samme
-- som kildeoppdagelsen bruker, ellers ville redaktøren ikke funnet igjen det
-- Antidep alt har registrert.
insert into svar (label, payload)
select 'doi-oppslag', api.register_study_report(
  'doi:10.9400/940-D', null, null, 'Syntetisk studie uten register for 940',
  'primary_report', 'Artikkelen er hovedrapporten om denne studien.', true);

-- Referansen er et bart forsøksregisternummer: formen sier selv hva det er.
insert into svar (label, payload)
select 'register-oppslag', api.register_study_report(
  'nct00940945', 'other', 'NCT00940945', 'Syntetisk registerstudie for 940',
  'registry_record', 'Oppføringen er registerets egen post om studien.', true);
reset role;

select is(
  (select r.source_id from knowledge.study_reports r
   where r.source_id = '94000000-0000-4000-8000-000000000004'),
  '94000000-0000-4000-8000-000000000004'::uuid,
  'kilden kan navngis med DOI-en sin, uansett skrivemåte'
);

-- Kalleren sa «other». Formen på nummeret sier «clinicaltrials_gov», og det er
-- formen som avgjør: ellers ville det samme forsøket blitt to studier.
select is(
  (select payload ->> 'registry' from svar where label = 'register-oppslag'),
  'clinicaltrials_gov:NCT00940945',
  'og et bart registernummer slår opp kilden og retter registeret nummeret hører til'
);

select * from finish();
rollback;
