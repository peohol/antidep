-- Migrasjon 013m — overlappet gjennom en systematisk oversikt, og bindingen.
--
-- 013l grupperte evidensfunn på studien kilden er en rapport om. To ting
-- manglet, og begge er reelle hull i vernet mot dobbelttelling:
--
--   1. **Oversikten og primærstudiene den inkluderer.** SOURCE_POLICY.md §7 og
--      §11 sier at de ikke er uavhengige kilder — teller man begge, teller man
--      de samme deltakerne to ganger. Relasjonen er mange-til-mange, og
--      `knowledge.study_reports` kan ikke bære den: der hører én kilde til
--      høyst én studie.
--   2. **Grupperingen lå utenfor bindingen.** Den sto i materialet agenten
--      leser, men ikke i det forespørselsavtrykket svaret bindes til. To
--      rapporter som først så ut som to uavhengige kilder og siden ble koblet
--      til den samme studien, kunne derfor få et svar bygget på den
--      dobbelttelte tilstanden registrert i ettertid.
--
-- Filen prøver begge, og prøver dem i den rekkefølgen de skjer: grunnlaget
-- teller tre uavhengige utvalg, oppgavene utstedes, overlappet registreres, og
-- da skal både tellingen og avtrykket være et annet — mens jobbnøkkelen er den
-- samme, fordi oppgaven fortsatt er den samme oppgaven.
--
-- SQLSTATE 22023 = invalid_parameter_value, 23001 = restrict_violation,
-- 42501 = insufficient_privilege.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(26);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('knowledge', 'review_included_studies',
                 'knowledge.review_included_studies finnes');
select has_function('knowledge', 'link_review_included_study',
                    'knowledge.link_review_included_study(...) finnes');
select has_function('api', 'link_review_included_study',
                    'api.link_review_included_study(...) finnes');
select has_function('knowledge', 'study_unit_digest', array['uuid[]'],
                    'knowledge.study_unit_digest(uuid[]) finnes');

select is_empty(
  $$
    select r.role_name, p.privilege
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, 'knowledge.review_included_studies', p.privilege)
  $$,
  'ingen klientrolle skriver i eller leser oversiktskoblingen direkte'
);

-- ===========================================================================
-- Del 2 — Oppsettet: en oversikt og de to primærstudiene den bygger på
-- ===========================================================================
insert into auth.users (id, email)
values ('95000000-0000-4000-8000-00000000000a', 'redaktor-950@test.invalid'),
       ('95000000-0000-4000-8000-00000000000b', 'kliniker-950@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values ('ac950000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-950',
        'Redaktør 950', 'Editor uten avgrensning, for 950.',
        '95000000-0000-4000-8000-00000000000a'),
       ('ac950000-0000-4000-8000-00000000000b', 'human', 'human:kliniker-950',
        'Kliniker 950', 'Uten redaktørmandat, for 950.',
        '95000000-0000-4000-8000-00000000000b');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('95000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
        'ac950000-0000-4000-8000-00000000000a', 'Editor-tildeling for 950.');

create temporary table maalt (label text primary key, payload jsonb) on commit drop;
grant select, insert on maalt to authenticated;

-- Oversikten er en artikkel som alle andre. Kildetypen sier hva dokumentet er,
-- ikke hvilket design funnet har (DATABASE_ARCHITECTURE.md §17), og overlappet
-- her handler om deltakerne og ikke om designet.
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('95000000-0000-4000-8000-000000000001', 'journal_article',
   'Syntetisk systematisk oversikt for 950', 'Testforfatter Oversikt mfl.',
   pg_temp.owner_actor_id()),
  ('95000000-0000-4000-8000-000000000002', 'journal_article',
   'Syntetisk primærstudie A for 950', 'Testforfatter A mfl.',
   pg_temp.owner_actor_id()),
  ('95000000-0000-4000-8000-000000000003', 'journal_article',
   'Syntetisk primærstudie B for 950', 'Testforfatter B mfl.',
   pg_temp.owner_actor_id());

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference,
   representation, retrieved_by_actor_id, document_sha256, document_byte_size,
   document_media_type, text_extraction_tool, text_extraction_tool_version,
   text_extraction_arguments, text_extraction_transform)
select v.id::uuid, v.source_id::uuid, now(), v.url,
       knowledge.source_version_content_hash(v.text),
       'private://syntetisk-950/' || v.id || '.pdf',
       'full_text', pg_temp.owner_actor_id(),
       pg_temp.synthetic_pdf_digest(v.id),
       octet_length(pg_temp.synthetic_pdf(v.id)),
       'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from (values
  ('95000000-0000-4000-8000-000000000021', '95000000-0000-4000-8000-000000000001',
   'https://example.test/950-oversikt', 'Oversikten for 950.'),
  ('95000000-0000-4000-8000-000000000022', '95000000-0000-4000-8000-000000000002',
   'https://example.test/950-a', 'Primærstudie A for 950.'),
  ('95000000-0000-4000-8000-000000000023', '95000000-0000-4000-8000-000000000003',
   'https://example.test/950-b', 'Primærstudie B for 950.')
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
       pg_temp.owner_actor_id()
from (values
  ('95000000-0000-4000-8000-000000000031', '95000000-0000-4000-8000-000000000001',
   '95000000-0000-4000-8000-000000000021'),
  ('95000000-0000-4000-8000-000000000032', '95000000-0000-4000-8000-000000000002',
   '95000000-0000-4000-8000-000000000022'),
  ('95000000-0000-4000-8000-000000000033', '95000000-0000-4000-8000-000000000003',
   '95000000-0000-4000-8000-000000000023')
) as v(id, source_id, version_id);

-- Primærstudiene er registrerte studier. Oversikten er foreløpig bare en kilde:
-- Antidep vet ennå ikke at den bygger på de to andre.
select knowledge.register_study_report(
  '95000000-0000-4000-8000-000000000002', 'clinicaltrials_gov', 'NCT00950001',
  'Syntetisk primærstudie A', 'primary_report',
  'Artikkelen oppgir NCT00950001 i metodeavsnittet.', 'documented',
  'ac950000-0000-4000-8000-00000000000a', null);

select knowledge.register_study_report(
  '95000000-0000-4000-8000-000000000003', 'clinicaltrials_gov', 'NCT00950002',
  'Syntetisk primærstudie B', 'primary_report',
  'Artikkelen oppgir NCT00950002 i metodeavsnittet.', 'documented',
  'ac950000-0000-4000-8000-00000000000a', null);

create temporary view grunnlag as
select array['95000000-0000-4000-8000-000000000031'::uuid,
             '95000000-0000-4000-8000-000000000032'::uuid,
             '95000000-0000-4000-8000-000000000033'::uuid] as funn;

-- ===========================================================================
-- Del 3 — Før overlappet er kjent, ser grunnlaget bredere ut enn det er
-- ===========================================================================
select is(
  (knowledge.study_units_for_evidence((select funn from grunnlag))
     ->> 'independent_units')::integer,
  3,
  'tre funn fra tre kilder teller som tre uavhengige utvalg så lenge overlappet er ukjent'
);

select is(
  (knowledge.study_units_for_evidence((select funn from grunnlag))
     ->> 'review_overlaps')::integer,
  0,
  'og ingen av enhetene er merket med overlapp gjennom en oversikt'
);

-- ===========================================================================
-- Del 4 — Oppgavene utstedes på det grunnlaget
-- ===========================================================================
insert into workflow.pipeline_jobs
  (id, agent_role, job_key, input_manifest, enqueued_by_actor_id)
select '95000000-0000-4000-8000-000000000041', 'claim_synthesis',
       workflow.agent_task_job_key('claim_synthesis', m.manifest), m.manifest,
       'ac950000-0000-4000-8000-00000000000a'
from (select jsonb_build_object(
        'topic_concept_id', (select id from catalog.clinical_concepts
                             where canonical_label = 'vektendring'),
        'subject_drug_id', (select id from catalog.drugs
                            where canonical_name = 'sertralin'),
        'evidence_item_ids', jsonb_build_array(
          '95000000-0000-4000-8000-000000000031',
          '95000000-0000-4000-8000-000000000032',
          '95000000-0000-4000-8000-000000000033')) as manifest) m;

-- En påstandsrevisjon på det samme grunnlaget, slik at evidensvurderingen kan
-- utstedes på det også: GRADE-leddet leser presisjon og konsistens av hvor
-- mange uavhengige utvalg grunnlaget hviler på.
insert into knowledge.claims
  (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
values ('95000000-0000-4000-8000-000000000051', 'evidence_synthesis',
        (select id from catalog.clinical_concepts where canonical_label = 'vektendring'),
        (select id from catalog.drugs where canonical_name = 'sertralin'),
        pg_temp.synthesis_actor_id());

insert into knowledge.claim_revisions (
  id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
  population_id, comparator_kind, direction, uncertainty_summary, created_by_actor_id
)
values ('95000000-0000-4000-8000-000000000052',
        '95000000-0000-4000-8000-000000000051', 1, 'evidence_synthesis',
        (select id from catalog.drugs where canonical_name = 'sertralin'),
        'Prøve i 950: sertralin er forbundet med vektendring i den undersøkte gruppen.',
        'Voksne med depressiv lidelse, 8 uker.',
        (select id from catalog.populations
         where canonical_label = 'voksne med depressiv lidelse'),
        'none', 'no_clear_difference',
        'Prøve i 950: tre funn, uten presisjonsmål.',
        pg_temp.synthesis_actor_id());

insert into knowledge.claim_evidence_links (
  claim_revision_id, evidence_item_id, relationship_type, directness,
  relevance_note, created_by_actor_id
)
select '95000000-0000-4000-8000-000000000052', f.id, 'supports', 'direct',
       'Prøve i 950: funnet er en del av grunnlaget for påstanden.',
       pg_temp.synthesis_actor_id()
from unnest((select funn from grunnlag)) as f(id);

insert into workflow.pipeline_jobs
  (id, agent_role, job_key, input_manifest, enqueued_by_actor_id)
select '95000000-0000-4000-8000-000000000042', 'evidence_assessment',
       workflow.agent_task_job_key('evidence_assessment', m.manifest), m.manifest,
       'ac950000-0000-4000-8000-00000000000a'
from (select jsonb_build_object(
        'claim_revision_id', '95000000-0000-4000-8000-000000000052') as manifest) m;

insert into maalt (label, payload)
select 'syntese-for', workflow.agent_task(j)
from workflow.pipeline_jobs j where j.id = '95000000-0000-4000-8000-000000000041';

insert into maalt (label, payload)
select 'vurdering-for', workflow.agent_task(j)
from workflow.pipeline_jobs j where j.id = '95000000-0000-4000-8000-000000000042';

select is(
  (select payload -> 'binding' -> 'input' ->> 'study_unit_digest'
   from maalt where label = 'syntese-for'),
  knowledge.study_unit_digest((select funn from grunnlag)),
  'synteseoppgavens binding bærer avtrykket av uavhengighetsstrukturen'
);

select is(
  (select (payload -> 'input' -> 'study_units' ->> 'independent_units')::integer
   from maalt where label = 'syntese-for'),
  3,
  'og materialet agenten leser sier det samme: tre uavhengige utvalg'
);

select is(
  (select payload -> 'binding' -> 'input' ->> 'study_unit_digest'
   from maalt where label = 'vurdering-for'),
  knowledge.study_unit_digest((select funn from grunnlag)),
  'evidensvurderingen bindes til den samme strukturen, og ikke bare syntesen'
);

select is(
  (select (payload -> 'input' -> 'study_units' ->> 'independent_units')::integer
   from maalt where label = 'vurdering-for'),
  3,
  'og evidensvurderingen får grupperingen i materialet sitt: GRADE-leddet leser ikke tre der det er ett'
);

-- ===========================================================================
-- Del 5 — Redaktøren registrerer at oversikten inkluderer begge primærstudiene
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  $$select api.link_review_included_study(
      'Syntetisk systematisk oversikt for 950', 'clinicaltrials_gov', 'NCT00950001',
      'Syntetisk primærstudie A', 'Uten mandat.', true)$$,
  '42501', null,
  'en kliniker uten redaktørmandat kan ikke registrere et overlapp'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;

select throws_ok(
  $$select api.link_review_included_study(
      'Syntetisk systematisk oversikt for 950', 'clinicaltrials_gov', 'NCT00950001',
      'Syntetisk primærstudie A', '   ', true)$$,
  '22023', null,
  'og en inklusjon uten et dokumentert grunnlag avvises, akkurat som rapportkoblingen'
);

insert into maalt (label, payload)
select 'inklusjon-a', api.link_review_included_study(
  'Syntetisk systematisk oversikt for 950', 'clinicaltrials_gov', 'NCT00950001',
  'Syntetisk primærstudie A',
  'Oversikten fører NCT00950001 i tabell 1 over inkluderte studier.', true);

insert into maalt (label, payload)
select 'inklusjon-b', api.link_review_included_study(
  'Syntetisk systematisk oversikt for 950', 'clinicaltrials_gov', 'NCT00950002',
  'Syntetisk primærstudie B',
  'Oversikten fører NCT00950002 i tabell 1 over inkluderte studier.', true);

insert into maalt (label, payload)
select 'inklusjon-a-igjen', api.link_review_included_study(
  'Syntetisk systematisk oversikt for 950', 'clinicaltrials_gov', 'NCT00950001',
  'Syntetisk primærstudie A',
  'Den samme inklusjonen registrert på nytt.', true);
reset role;

select is(
  (select payload ->> 'registry' from maalt where label = 'inklusjon-a'),
  'clinicaltrials_gov:NCT00950001',
  'redaktøren når oversikten med tittelen og studien med registernummeret, uten en eneste intern id'
);

select is(
  (select (payload ->> 'included_studies')::integer from maalt where label = 'inklusjon-a-igjen'),
  2,
  'og den samme inklusjonen registrert på nytt legger ingen ny rad til: to inkluderte studier, ikke tre'
);

-- ===========================================================================
-- Del 6 — Nå ser grunnlaget ut som det er
-- ===========================================================================
select is(
  (knowledge.study_units_for_evidence((select funn from grunnlag))
     ->> 'independent_units')::integer,
  1,
  'oversikten og de to primærstudiene er ett deltakerutvalg, og ikke tre'
);

select is(
  (knowledge.study_units_for_evidence((select funn from grunnlag))
     ->> 'review_overlaps')::integer,
  1,
  'og enheten er merket med at sammenslåingen kom av et oversiktsoverlapp'
);

select is(
  (knowledge.study_units_for_evidence((select funn from grunnlag))
     ->> 'evidence_items')::integer,
  3,
  'grupperingen sletter ingenting: alle tre funnene står fortsatt i grunnlaget'
);

select is(
  (select count(*)::integer
   from jsonb_array_elements(
          knowledge.study_units_for_evidence((select funn from grunnlag)) -> 'units') as u(value),
        jsonb_array_elements(u.value -> 'studies')),
  2,
  'og enheten oppgir begge de registrerte studiene den hviler på, framfor å velge ett navn'
);

-- ===========================================================================
-- Del 7 — Og et svar avgitt på den gamle strukturen er foreldet
-- ===========================================================================
insert into maalt (label, payload)
select 'syntese-etter', workflow.agent_task(j)
from workflow.pipeline_jobs j where j.id = '95000000-0000-4000-8000-000000000041';

insert into maalt (label, payload)
select 'vurdering-etter', workflow.agent_task(j)
from workflow.pipeline_jobs j where j.id = '95000000-0000-4000-8000-000000000042';

select isnt(
  (select payload ->> 'request_digest' from maalt where label = 'syntese-etter'),
  (select payload ->> 'request_digest' from maalt where label = 'syntese-for'),
  'synteseoppgavens forespørselsavtrykk er et annet: et svar avgitt på den dobbelttelte tilstanden avvises'
);

select isnt(
  (select payload ->> 'request_digest' from maalt where label = 'vurdering-etter'),
  (select payload ->> 'request_digest' from maalt where label = 'vurdering-for'),
  'og evidensvurderingens avtrykk likeså'
);

select is(
  (select payload ->> 'job_key' from maalt where label = 'syntese-etter'),
  (select payload ->> 'job_key' from maalt where label = 'syntese-for'),
  'men jobbnøkkelen er den samme: oppgaven er fortsatt den samme oppgaven, og det lages ingen dublett'
);

select is(
  (select (payload -> 'input' -> 'study_units' ->> 'independent_units')::integer
   from maalt where label = 'syntese-etter'),
  1,
  'og den nye oppgaven viser én enhet der den gamle viste tre'
);

select is(
  (select (payload -> 'input' -> 'study_units' ->> 'independent_units')::integer
   from maalt where label = 'vurdering-etter'),
  1,
  'også for evidensvurderingen'
);

-- ===========================================================================
-- Del 8 — Det som ikke skal slås sammen
-- ===========================================================================
-- En oversikt over en studie som ikke er i grunnlaget, overlapper ikke med noe
-- her. Uten den avgrensningen ville en oversikt kunnet slå sammen enheter
-- alene, på grunnlag av studier ingen har lagt fram.
select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into maalt (label, payload)
select 'inklusjon-utenfor', api.link_review_included_study(
  'Syntetisk primærstudie A for 950', 'clinicaltrials_gov', 'NCT00950099',
  'En studie ingen har lagt fram artikkelen til',
  'Oversikten fører NCT00950099, som Antidep ikke har noen rapport om.', true);
reset role;

select is(
  (knowledge.study_units_for_evidence(array[
     '95000000-0000-4000-8000-000000000033'::uuid]) ->> 'independent_units')::integer,
  1,
  'en inklusjon av en studie som ikke er i grunnlaget, slår ingenting sammen'
);

-- Oversikten kan ikke inkludere den studien den selv er en rapport om: en kilde
-- overlapper alltid med seg selv, og opplysningen sier ingenting om uavhengighet.
select knowledge.register_study_report(
  '95000000-0000-4000-8000-000000000001', 'clinicaltrials_gov', 'NCT00950003',
  'Syntetisk oversikt som egen oppføring', 'primary_report',
  'Oversikten er registrert med sin egen oppføring NCT00950003.', 'documented',
  'ac950000-0000-4000-8000-00000000000a', null);

select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  $$select api.link_review_included_study(
      'Syntetisk systematisk oversikt for 950', 'clinicaltrials_gov', 'NCT00950003',
      'Syntetisk oversikt som egen oppføring',
      'Oversikten fører seg selv.', true)$$,
  '22023', null,
  'og en oversikt kan ikke inkludere den studien den selv er en rapport om'
);
reset role;

select * from finish();
rollback;
