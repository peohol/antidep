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

select plan(96);

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
create temporary table fixture_950 (name text primary key, id uuid not null) on commit drop;
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
-- Dette er hele skillet. Oversikten legger ikke til et deltakerutvalg — men den
-- gjør heller ikke de to primærstudiene til det samme utvalget. At en oversikt
-- nevner A og B, sier ingenting om at A og B deler deltakere.
select is(
  (knowledge.study_units_for_evidence((select funn from grunnlag))
     ->> 'independent_units')::integer,
  2,
  'oversikten teller ikke som et eget utvalg, og primærstudiene står fortsatt hver for seg: to uavhengige enheter'
);

select is(
  (knowledge.study_units_for_evidence((select funn from grunnlag))
     ->> 'derived_reviews')::integer,
  1,
  'og oversikten står som avledet av grunnlaget den er et sammendrag av'
);

select is(
  (knowledge.study_units_for_evidence((select funn from grunnlag))
     ->> 'review_overlaps')::integer,
  0,
  'ingen enheter er slått sammen: sammenslåing brukes bare der de samme deltakerne faktisk telles to ganger'
);

select is(
  (knowledge.study_units_for_evidence((select funn from grunnlag))
     ->> 'evidence_items')::integer,
  3,
  'grupperingen sletter ingenting: alle tre funnene står fortsatt i grunnlaget'
);

-- Den avledede enheten sier hvilke enheter den er et sammendrag av. Uten det
-- ville leseren sett at den ikke teller, men ikke hvorfor.
select is(
  (select count(*)::integer
   from jsonb_array_elements(
          knowledge.study_units_for_evidence((select funn from grunnlag)) -> 'units') as u(value),
        jsonb_array_elements(u.value -> 'derives_from')
   where u.value ->> 'role' = 'derived_review'),
  2,
  'og den avledede oversikten navngir begge primærstudiene den bygger på'
);

select is(
  (select count(*)::integer
   from jsonb_array_elements(
          knowledge.study_units_for_evidence((select funn from grunnlag)) -> 'units') as u(value)
   where (u.value ->> 'independent')::boolean),
  2,
  'nøyaktig to av de tre enhetene er uavhengige, og det er de to primærstudiene'
);

-- ===========================================================================
-- Del 6b — Delvis overlapp: oversikten beholder det bare den bærer
-- ===========================================================================
-- Oversikten fører A og B. Består grunnlaget av oversikten og *bare* A, er B
-- fortsatt noe ingen andre har lagt fram. Fram til migrasjon 013o ble hele
-- oversikten merket som avledet i det A fantes direkte, og da forsvant B ut av
-- uavhengighetsmodellen — grunnlaget så smalere ut enn det er.
select is(
  (knowledge.study_units_for_evidence(array[
     '95000000-0000-4000-8000-000000000031'::uuid,
     '95000000-0000-4000-8000-000000000032'::uuid])
     ->> 'independent_units')::integer,
  2,
  'oversikten pluss én av de to studiene den fører, er to enheter: B finnes bare gjennom oversikten'
);

select is(
  (knowledge.study_units_for_evidence(array[
     '95000000-0000-4000-8000-000000000031'::uuid,
     '95000000-0000-4000-8000-000000000032'::uuid])
     ->> 'derived_reviews')::integer,
  0,
  'og oversikten er ikke avledet: den bærer noe som ikke er lagt fram for seg'
);

select is(
  (select (u.value ->> 'unique_studies')::integer
   from jsonb_array_elements(
          knowledge.study_units_for_evidence(array[
            '95000000-0000-4000-8000-000000000031'::uuid,
            '95000000-0000-4000-8000-000000000032'::uuid]) -> 'units') as u(value)
   where u.value ->> 'role' = 'partially_derived_review'),
  1,
  'den sier hvor mye bare den bærer, og hvilken studie den deler med grunnlaget ellers'
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
  2,
  'og den nye oppgaven viser to uavhengige utvalg der den gamle viste tre'
);

select is(
  (select (payload -> 'input' -> 'study_units' ->> 'independent_units')::integer
   from maalt where label = 'vurdering-etter'),
  2,
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

-- ===========================================================================
-- Del 9 — To oversikter som deler en studie ingen har lagt fram
--
-- Fram til migrasjon 013n krevde kanten at den delte primærstudien selv var en
-- enhet i grunnlaget. Hviler grunnlaget på to oversikter som begge inkluderer
-- studie S, uten at noen rapport om S er valgt, fantes ingen kant — og de to
-- sto som to uavhengige bekreftelser. SOURCE_POLICY.md §7 sier uttrykkelig at
-- overlapp må vurderes ved bruk av flere oversikter.
-- ===========================================================================
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('95000000-0000-4000-8000-000000000004', 'journal_article',
   'Syntetisk oversikt R1 for 950', 'Testforfatter R1 mfl.',
   pg_temp.owner_actor_id()),
  ('95000000-0000-4000-8000-000000000005', 'journal_article',
   'Syntetisk oversikt R2 for 950', 'Testforfatter R2 mfl.',
   pg_temp.owner_actor_id()),
  ('95000000-0000-4000-8000-000000000006', 'journal_article',
   'Syntetisk hovedartikkel for den navngitte studien 950', 'Testforfatter N mfl.',
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
  ('95000000-0000-4000-8000-000000000024', '95000000-0000-4000-8000-000000000004',
   'https://example.test/950-r1', 'Oversikt R1 for 950.'),
  ('95000000-0000-4000-8000-000000000025', '95000000-0000-4000-8000-000000000005',
   'https://example.test/950-r2', 'Oversikt R2 for 950.'),
  ('95000000-0000-4000-8000-000000000026', '95000000-0000-4000-8000-000000000006',
   'https://example.test/950-n', 'Hovedartikkelen for den navngitte studien.')
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
  ('95000000-0000-4000-8000-000000000034', '95000000-0000-4000-8000-000000000004',
   '95000000-0000-4000-8000-000000000024'),
  ('95000000-0000-4000-8000-000000000035', '95000000-0000-4000-8000-000000000005',
   '95000000-0000-4000-8000-000000000025'),
  ('95000000-0000-4000-8000-000000000036', '95000000-0000-4000-8000-000000000006',
   '95000000-0000-4000-8000-000000000026')
) as v(id, source_id, version_id);

create temporary view oversiktsgrunnlag as
select array['95000000-0000-4000-8000-000000000034'::uuid,
             '95000000-0000-4000-8000-000000000035'::uuid] as funn;

-- Før overlappet er registrert, ser de to oversiktene ut som to uavhengige
-- bekreftelser.
select is(
  (knowledge.study_units_for_evidence((select funn from oversiktsgrunnlag))
     ->> 'independent_units')::integer,
  2,
  'to oversikter uten registrert overlapp står som to enheter'
);

select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into maalt (label, payload)
select 'r1-deler', api.link_review_included_study(
  'Syntetisk oversikt R1 for 950', 'clinicaltrials_gov', 'NCT00950050',
  'Den delte primærstudien for 950',
  'R1 fører NCT00950050 i tabellen over inkluderte studier.', true);

insert into maalt (label, payload)
select 'r2-deler', api.link_review_included_study(
  'Syntetisk oversikt R2 for 950', 'clinicaltrials_gov', 'NCT00950050',
  'Den delte primærstudien for 950',
  'R2 fører den samme NCT00950050 i tabellen over inkluderte studier.', true);
reset role;

-- Ingen rapport om NCT00950050 er lagt fram. Overlappet må virke likevel.
select is(
  (select count(*)::integer from knowledge.study_reports r
   join knowledge.studies s on s.id = r.study_id
   where s.registry_id = 'NCT00950050'),
  0,
  'ingen har lagt fram artikkelen om den delte studien'
);

select is(
  (knowledge.study_units_for_evidence((select funn from oversiktsgrunnlag))
     ->> 'independent_units')::integer,
  1,
  'men de to oversiktene bærer de samme deltakerne, og er derfor én enhet og ikke to'
);

select is(
  (knowledge.study_units_for_evidence((select funn from oversiktsgrunnlag))
     ->> 'derived_reviews')::integer,
  1,
  'og den ene står som avledet: alt den dekker, dekkes av den andre'
);

select is(
  (knowledge.study_units_for_evidence((select funn from oversiktsgrunnlag))
     ->> 'evidence_items')::integer,
  2,
  'begge funnene står fortsatt i grunnlaget'
);

-- ===========================================================================
-- Del 10 — En studie som først var navngitt, og senere fikk et registernummer
--
-- En oversikt kan liste en studie lenge før noen legger fram artikkelen om den.
-- Kommer artikkelen senere med både navnet og nummeret, må det bli den samme
-- studien. Fram til migrasjon 013n gikk oppslaget bare på paret
-- (register, nummer), så det ble en rad til — og da pekte oversiktskoblingen på
-- den ene og rapporten på den andre, slik at overlappet var uten virkning.
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into maalt (label, payload)
select 'navngitt-inklusjon', api.link_review_included_study(
  'Syntetisk oversikt R1 for 950', null, null,
  'Studien som bare hadde et navn i 950',
  'R1 fører studien bare med forfatter og år; oversikten oppgir intet registernummer.', true);
reset role;

select is(
  (select count(*)::integer from knowledge.studies s
   where s.registry_kind is null
     and s.label = 'Studien som bare hadde et navn i 950'),
  1,
  'oversikten kan registrere en inkludert studie som bare har et navn'
);

insert into fixture_950 (name, id)
select 'navngitt-studie', ri.study_id
from knowledge.review_included_studies ri
join knowledge.studies s on s.id = ri.study_id
where s.label = 'Studien som bare hadde et navn i 950';

-- Hovedartikkelen kommer, med det samme navnet og et registernummer.
select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into maalt (label, payload)
select 'navngitt-rapport', api.register_study_report(
  'Syntetisk hovedartikkel for den navngitte studien 950',
  'clinicaltrials_gov', 'NCT00950060',
  'Studien som bare hadde et navn i 950', 'primary_report',
  'Artikkelen oppgir NCT00950060, og er hovedrapporten om studien oversikten førte med navn.', true);
reset role;

select is(
  (select r.study_id from knowledge.study_reports r
   where r.source_id = '95000000-0000-4000-8000-000000000006'),
  (select id from fixture_950 where name = 'navngitt-studie'),
  'artikkelen lander på den studien oversikten alt hadde registrert, og ikke på en ny'
);

select is(
  (select s.registry_kind || ':' || s.registry_id from knowledge.studies s
   where s.id = (select id from fixture_950 where name = 'navngitt-studie')),
  'clinicaltrials_gov:NCT00950060',
  'og den navngitte studien bærer nå registernummeret sitt'
);

select is(
  (select count(*)::integer from knowledge.study_identity_upgrades u
   where u.study_id = (select id from fixture_950 where name = 'navngitt-studie')),
  1,
  'oppgraderingen er ført som en egen opplysning, med grunnlaget og hvem som sto bak'
);

select ok(
  (select num_nonnulls(u.upgraded_by_actor_id, u.upgraded_by_agent_run_id) = 1
     and length(u.basis) > 20
   from knowledge.study_identity_upgrades u
   where u.study_id = (select id from fixture_950 where name = 'navngitt-studie')),
  'med nøyaktig én proveniens: en sammenslåing ingen står bak, kan ikke etterprøves'
);

-- Og nå virker overlappet: oversikten er avledet av studien den listet.
-- R1 fører to studier: den delte NCT00950050, som ingen har lagt fram, og den
-- navngitte som nå er lagt fram. Overlappet virker — men R1 bærer fortsatt noe
-- ingen andre har lagt fram, og står derfor igjen som uavhengig for nettopp det.
select is(
  (knowledge.study_units_for_evidence(array[
     '95000000-0000-4000-8000-000000000034'::uuid,
     '95000000-0000-4000-8000-000000000036'::uuid])
     ->> 'review_overlaps')::integer,
  1,
  'oversikten overlapper nå den studien den listet med navn: koblingen virker'
);

select is(
  (select (u.value ->> 'unique_studies')::integer
   from jsonb_array_elements(
          knowledge.study_units_for_evidence(array[
            '95000000-0000-4000-8000-000000000034'::uuid,
            '95000000-0000-4000-8000-000000000036'::uuid]) -> 'units') as u(value)
   where u.value ->> 'role' = 'partially_derived_review'),
  1,
  'og den oppgir at én av studiene den fører, fortsatt bare finnes gjennom den'
);

-- Men et navn som ikke er entydig, slås ikke sammen. To studier uten
-- registernummer kan hete det samme, og da ville en sammenslåing knyttet
-- nummeret til feil studie.
insert into knowledge.studies (id, registry_kind, registry_id, label, created_by_actor_id)
values
  ('95000000-0000-4000-8000-0000000000e1', null, null,
   'Tvetydig navn i 950', pg_temp.owner_actor_id()),
  ('95000000-0000-4000-8000-0000000000e2', null, null,
   'tvetydig navn i 950', pg_temp.owner_actor_id());

select throws_ok(
  format($$select knowledge.find_or_create_study(
    'clinicaltrials_gov', 'NCT00950070', 'Tvetydig navn i 950', %L, null)$$,
    'ac950000-0000-4000-8000-00000000000a'),
  '23001', null,
  'et navn som treffer to studier uten registernummer, slås ikke sammen — det avvises'
);

select is(
  (select count(*)::integer from knowledge.studies s
   where s.registry_id = 'NCT00950070'),
  0,
  'og ingen studie ble opprettet på veien ut: avslaget etterlater ingen halv identitet'
);

-- ===========================================================================
-- Del 11 — Den motsatte rekkefølgen splitter heller ikke identiteten
--
-- Registreres hovedartikkelen først med navn *og* registernummer, og kobler en
-- oversikt senere den samme studien bare med navnet, lette navnegrenen fram til
-- migrasjon 013o bare blant rader uten registernummer. Den registerbærende
-- studien ble oversett, og det ble opprettet en parallell identitet ved siden
-- av — med nøyaktig den samme følgen: oversiktskoblingen peker på én rad og
-- rapporten på en annen.
-- ===========================================================================
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('95000000-0000-4000-8000-000000000007', 'journal_article',
        'Syntetisk artikkel med nummer først for 950', 'Testforfatter M mfl.',
        pg_temp.owner_actor_id());

select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into maalt (label, payload)
select 'nummer-forst', api.register_study_report(
  'Syntetisk artikkel med nummer først for 950',
  'clinicaltrials_gov', 'NCT00950080',
  'Studien med nummer først i 950', 'primary_report',
  'Artikkelen oppgir NCT00950080 i metodeavsnittet.', true);

insert into maalt (label, payload)
select 'oversikt-bare-navn', api.link_review_included_study(
  'Syntetisk oversikt R2 for 950', null, null,
  'Studien med nummer først i 950',
  'R2 fører studien bare med navn, uten å gjenta registernummeret.', true);
reset role;

select is(
  (select ri.study_id from knowledge.review_included_studies ri
   join knowledge.studies s on s.id = ri.study_id
   where ri.review_source_id = '95000000-0000-4000-8000-000000000005'
     and s.label = 'Studien med nummer først i 950'),
  (select r.study_id from knowledge.study_reports r
   where r.source_id = '95000000-0000-4000-8000-000000000007'),
  'oversiktskoblingen på bare navnet treffer den studien artikkelen alt registrerte med nummer'
);

select is(
  (select count(*)::integer from knowledge.studies s
   where lower(s.label) = 'studien med nummer først i 950'),
  1,
  'og det ble ikke opprettet noen parallell identitet ved siden av'
);

-- Et navn som treffer flere studier, avvises også i den rene navnegrenen.
select throws_ok(
  format($$select knowledge.find_or_create_study(
    null, null, 'Tvetydig navn i 950', %L, null)$$,
    'ac950000-0000-4000-8000-00000000000a'),
  '23001', null,
  'og et navn som treffer flere studier, avvises framfor å knytte grunnlaget til feil studie'
);

-- ===========================================================================
-- Del 12 — En usikker inklusjon er synlig, bundet, og kan avklares
--
-- SOURCE_POLICY.md §7: en usikker kobling skal være synlig og aldri løses ved
-- en udokumentert sammenslåing, men den hindrer at rapportene regnes som
-- uavhengige. Fram til migrasjon 013p fulgte `ri.certainty` ikke med inn i
-- grupperingen, så en oversikt som bare *kanskje* inkluderte studien, kunne stå
-- som avledet med `uncertain_linkage = false` — og avtrykket bandt det ikke, så
-- en senere avklaring gjorde ikke et utestående svar foreldet. Skriveveien
-- kunne heller ikke avklare: `on conflict do nothing` lot den usikre raden
-- stå, mens redaktørsvaret speilet det innsendte og svarte «sikker».
-- ===========================================================================
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('95000000-0000-4000-8000-000000000008', 'journal_article',
   'Syntetisk oversikt R3 for 950', 'Testforfatter R3 mfl.',
   pg_temp.owner_actor_id()),
  ('95000000-0000-4000-8000-000000000009', 'journal_article',
   'Syntetisk primærstudie P for 950', 'Testforfatter P mfl.',
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
  ('95000000-0000-4000-8000-000000000027', '95000000-0000-4000-8000-000000000008',
   'https://example.test/950-r3', 'Oversikt R3 for 950.'),
  ('95000000-0000-4000-8000-000000000028', '95000000-0000-4000-8000-000000000009',
   'https://example.test/950-p', 'Primærstudie P for 950.')
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
  ('95000000-0000-4000-8000-000000000037', '95000000-0000-4000-8000-000000000008',
   '95000000-0000-4000-8000-000000000027'),
  ('95000000-0000-4000-8000-000000000038', '95000000-0000-4000-8000-000000000009',
   '95000000-0000-4000-8000-000000000028')
) as v(id, source_id, version_id);

select knowledge.register_study_report(
  '95000000-0000-4000-8000-000000000009', 'clinicaltrials_gov', 'NCT00950090',
  'Primærstudie P for 950', 'primary_report',
  'Artikkelen oppgir NCT00950090 i metodeavsnittet.', 'documented',
  'ac950000-0000-4000-8000-00000000000a', null);

create temporary view usikkert as
select array['95000000-0000-4000-8000-000000000037'::uuid,
             '95000000-0000-4000-8000-000000000038'::uuid] as funn;

-- Oversikten inkluderer primærstudien, men bare usikkert.
select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into maalt (label, payload)
select 'usikker-inklusjon', api.link_review_included_study(
  'Syntetisk oversikt R3 for 950', 'clinicaltrials_gov', 'NCT00950090',
  'Primærstudie P for 950',
  'R3 viser til «Testforfatter P» uten å oppgi registernummeret; det kan være den samme studien.',
  false);
reset role;

select is(
  (select payload ->> 'certain' from maalt where label = 'usikker-inklusjon'),
  'false',
  'redaktøren kan registrere en inklusjon som usikker'
);

insert into fixture_950 (name, id)
select 'r3-inklusjon', ri.id
from knowledge.review_included_studies ri
join knowledge.studies s on s.id = ri.study_id
where ri.review_source_id = '95000000-0000-4000-8000-000000000008'
  and s.registry_id = 'NCT00950090';

-- Den forsiktige lesningen står: materialet behandles som overlappende.
select is(
  (knowledge.study_units_for_evidence((select funn from usikkert))
     ->> 'derived_reviews')::integer,
  1,
  'en usikker inklusjon dedupliserer som en dokumentert: den forsiktige lesningen står'
);

-- Men usikkerheten er synlig der den betyr noe.
select is(
  (knowledge.study_units_for_evidence((select funn from usikkert))
     ->> 'uncertain_linkage')::integer,
  1,
  'og enheten sier at sammenslåingen hviler på en usikker relasjon'
);

select is(
  (select count(*)::integer
   from jsonb_array_elements(
          knowledge.study_units_for_evidence((select funn from usikkert)) -> 'units') as u(value),
        jsonb_array_elements(u.value -> 'uncertain_inclusions')
   where u.value ->> 'role' = 'derived_review'),
  1,
  'og navngir hvilken studie det er sammenslåingen bare antar'
);

-- Oppgaven utstedes mens grunnlaget er usikkert.
insert into workflow.pipeline_jobs
  (id, agent_role, job_key, input_manifest, enqueued_by_actor_id)
select '95000000-0000-4000-8000-000000000043', 'claim_synthesis',
       workflow.agent_task_job_key('claim_synthesis', m.manifest), m.manifest,
       'ac950000-0000-4000-8000-00000000000a'
from (select jsonb_build_object(
        'topic_concept_id', (select id from catalog.clinical_concepts
                             where canonical_label = 'vektendring'),
        'subject_drug_id', (select id from catalog.drugs
                            where canonical_name = 'sertralin'),
        'evidence_item_ids', jsonb_build_array(
          '95000000-0000-4000-8000-000000000037',
          '95000000-0000-4000-8000-000000000038')) as manifest) m;

insert into maalt (label, payload)
select 'usikker-oppgave', workflow.agent_task(j)
from workflow.pipeline_jobs j where j.id = '95000000-0000-4000-8000-000000000043';

insert into maalt (label, payload)
select 'usikkert-avtrykk',
       to_jsonb(knowledge.study_unit_digest((select funn from usikkert)));

-- Så avklares koblingen.
select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into maalt (label, payload)
select 'avklart-inklusjon', api.link_review_included_study(
  'Syntetisk oversikt R3 for 950', 'clinicaltrials_gov', 'NCT00950090',
  'Primærstudie P for 950',
  'R3 sitt vedlegg B oppgir NCT00950090 for den studien; inklusjonen er dokumentert.',
  true);
reset role;

select is(
  (select payload ->> 'certain' from maalt where label = 'avklart-inklusjon')
    || '/' || (select payload ->> 'clarified' from maalt where label = 'avklart-inklusjon'),
  'true/true',
  'svaret sier at koblingen nå er dokumentert, og at det var en avklaring'
);

select is(
  knowledge.review_inclusion_certainty(
    (select id from fixture_950 where name = 'r3-inklusjon'))::text,
  'documented',
  'og den gjeldende sikkerheten i databasen er den samme som svaret oppgir'
);

-- Den første vurderingen står urørt: avklaringen er en ny rad.
select is(
  (select ri.certainty::text from knowledge.review_included_studies ri
   where ri.id = (select id from fixture_950 where name = 'r3-inklusjon')),
  'uncertain',
  'den første vurderingen står urørt: avklaringen overskriver ingen proveniens'
);

select is(
  (select a.previous_certainty::text || '->' || a.certainty::text
   from knowledge.review_inclusion_assessments a
   where a.review_included_study_id = (select id from fixture_950 where name = 'r3-inklusjon')),
  'uncertain->documented',
  'avklaringen er ført som sin egen opplysning, med et før og et etter'
);

select ok(
  (select num_nonnulls(a.assessed_by_actor_id, a.assessed_by_agent_run_id) = 1
     and length(a.basis) > 20
   from knowledge.review_inclusion_assessments a
   where a.review_included_study_id = (select id from fixture_950 where name = 'r3-inklusjon')),
  'med nøyaktig én proveniens og sitt eget grunnlag'
);

select is(
  (knowledge.study_units_for_evidence((select funn from usikkert))
     ->> 'uncertain_linkage')::integer,
  0,
  'og grupperingen sier ikke lenger at sammenslåingen er usikker'
);

select is(
  (knowledge.study_units_for_evidence((select funn from usikkert))
     ->> 'derived_reviews')::integer,
  1,
  'mens dedupliseringen står som før: avklaringen endret sikkerheten, ikke tellingen'
);

-- Og avklaringen gjør et utestående svar foreldet.
select isnt(
  knowledge.study_unit_digest((select funn from usikkert)),
  (select payload #>> '{}' from maalt where label = 'usikkert-avtrykk'),
  'avtrykket av uavhengighetsstrukturen er et annet etter avklaringen'
);

insert into maalt (label, payload)
select 'avklart-oppgave', workflow.agent_task(j)
from workflow.pipeline_jobs j where j.id = '95000000-0000-4000-8000-000000000043';

select isnt(
  (select payload ->> 'request_digest' from maalt where label = 'avklart-oppgave'),
  (select payload ->> 'request_digest' from maalt where label = 'usikker-oppgave'),
  'og et svar avgitt da grunnlaget var usikkert, avvises som foreldet'
);

select is(
  (select payload ->> 'job_key' from maalt where label = 'avklart-oppgave'),
  (select payload ->> 'job_key' from maalt where label = 'usikker-oppgave'),
  'men jobbnøkkelen står: en avklaring lager ingen ny oppgave'
);

-- Den samme vurderingen på nytt er ingen ny opplysning.
select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into maalt (label, payload)
select 'avklart-igjen', api.link_review_included_study(
  'Syntetisk oversikt R3 for 950', 'clinicaltrials_gov', 'NCT00950090',
  'Primærstudie P for 950',
  'Den samme dokumenterte inklusjonen registrert på nytt.', true);
reset role;

select is(
  (select payload ->> 'clarified' from maalt where label = 'avklart-igjen'),
  'false',
  'den samme vurderingen på nytt er ingen avklaring'
);

select is(
  (select count(*)::integer from knowledge.review_inclusion_assessments a
   where a.review_included_study_id = (select id from fixture_950 where name = 'r3-inklusjon')),
  1,
  'og den legger ingen rad til: sporet bærer vurderinger, ikke gjentakelser'
);

-- ===========================================================================
-- Del 13 — Usikkerheten følger dekningen, uansett lesningsrekkefølge
--
-- Fram til migrasjon 013q husket dekningen *hvilke* studier som var dekket, men
-- ikke hvor sikkert. Inkluderte R usikkert studie S og R' den samme S
-- dokumentert, uten at noen rapport om S var lagt fram, og R ble lest først,
-- ble R uavhengig uten overlapp — og R' avledet mot en dekning R bare antok.
-- Hele grunnlaget endte med uncertain_linkage = 0. I motsatt rekkefølge kom
-- usikkerheten fram. Et svar som avhenger av lesningsrekkefølgen, er ikke et
-- svar, så begge rekkefølgene prøves.
--
-- Rekkefølgen avgjøres av enhetsnøkkelen, som for en oversikt uten egen
-- studierapport er «kilde:<kilde-id>». Kilde-id-ene under er valgt slik at den
-- usikre leses først i det første paret, og den dokumenterte først i det andre.
-- ===========================================================================
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
select v.id::uuid, 'journal_article', v.tittel, 'Testforfatter mfl.',
       pg_temp.owner_actor_id()
from (values
  ('95000000-0000-4000-8000-00000000000a', 'Syntetisk oversikt R4 for 950 (usikker, leses først)'),
  ('95000000-0000-4000-8000-00000000000b', 'Syntetisk oversikt R5 for 950 (dokumentert, leses sist)'),
  ('95000000-0000-4000-8000-00000000000c', 'Syntetisk oversikt R6 for 950 (dokumentert, leses først)'),
  ('95000000-0000-4000-8000-00000000000d', 'Syntetisk oversikt R7 for 950 (usikker, leses sist)')
) as v(id, tittel);

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference,
   representation, retrieved_by_actor_id, document_sha256, document_byte_size,
   document_media_type, text_extraction_tool, text_extraction_tool_version,
   text_extraction_arguments, text_extraction_transform)
select v.id::uuid, v.source_id::uuid, now(), 'https://example.test/' || v.id,
       knowledge.source_version_content_hash('Oversikt ' || v.id || ' for 950.'),
       'private://syntetisk-950/' || v.id || '.pdf',
       'full_text', pg_temp.owner_actor_id(),
       pg_temp.synthetic_pdf_digest(v.id),
       octet_length(pg_temp.synthetic_pdf(v.id)),
       'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from (values
  ('95000000-0000-4000-8000-00000000002a', '95000000-0000-4000-8000-00000000000a'),
  ('95000000-0000-4000-8000-00000000002b', '95000000-0000-4000-8000-00000000000b'),
  ('95000000-0000-4000-8000-00000000002c', '95000000-0000-4000-8000-00000000000c'),
  ('95000000-0000-4000-8000-00000000002d', '95000000-0000-4000-8000-00000000000d')
) as v(id, source_id);

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
  ('95000000-0000-4000-8000-00000000003a', '95000000-0000-4000-8000-00000000000a',
   '95000000-0000-4000-8000-00000000002a'),
  ('95000000-0000-4000-8000-00000000003b', '95000000-0000-4000-8000-00000000000b',
   '95000000-0000-4000-8000-00000000002b'),
  ('95000000-0000-4000-8000-00000000003c', '95000000-0000-4000-8000-00000000000c',
   '95000000-0000-4000-8000-00000000002c'),
  ('95000000-0000-4000-8000-00000000003d', '95000000-0000-4000-8000-00000000000d',
   '95000000-0000-4000-8000-00000000002d')
) as v(id, source_id, version_id);

select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
-- Par 1: den usikre leses først.
insert into maalt (label, payload)
select 'r4-usikker', api.link_review_included_study(
  'Syntetisk oversikt R4 for 950 (usikker, leses først)',
  'clinicaltrials_gov', 'NCT00950100', 'Den delte studien S for 950',
  'R4 viser til studien uten å oppgi registernummeret; det kan være S.', false);
insert into maalt (label, payload)
select 'r5-dokumentert', api.link_review_included_study(
  'Syntetisk oversikt R5 for 950 (dokumentert, leses sist)',
  'clinicaltrials_gov', 'NCT00950100', 'Den delte studien S for 950',
  'R5 fører NCT00950100 i tabellen over inkluderte studier.', true);
-- Par 2: den dokumenterte leses først.
insert into maalt (label, payload)
select 'r6-dokumentert', api.link_review_included_study(
  'Syntetisk oversikt R6 for 950 (dokumentert, leses først)',
  'clinicaltrials_gov', 'NCT00950110', 'Den delte studien T for 950',
  'R6 fører NCT00950110 i tabellen over inkluderte studier.', true);
insert into maalt (label, payload)
select 'r7-usikker', api.link_review_included_study(
  'Syntetisk oversikt R7 for 950 (usikker, leses sist)',
  'clinicaltrials_gov', 'NCT00950110', 'Den delte studien T for 950',
  'R7 viser til studien uten å oppgi registernummeret; det kan være T.', false);
reset role;

insert into maalt (label, payload)
select 'par1-avtrykk', to_jsonb(knowledge.study_unit_digest(array[
  '95000000-0000-4000-8000-00000000003a'::uuid,
  '95000000-0000-4000-8000-00000000003b'::uuid]));

select is(
  (knowledge.study_units_for_evidence(array[
     '95000000-0000-4000-8000-00000000003a'::uuid,
     '95000000-0000-4000-8000-00000000003b'::uuid]) ->> 'uncertain_linkage')::integer,
  1,
  'usikkerheten kommer fram også når den usikre oversikten leses først: dekningen bærer hvor sikkert studien er dekket'
);

select is(
  (select count(*)::integer
   from jsonb_array_elements(
          knowledge.study_units_for_evidence(array[
            '95000000-0000-4000-8000-00000000003a'::uuid,
            '95000000-0000-4000-8000-00000000003b'::uuid]) -> 'units') as u(value),
        jsonb_array_elements(u.value -> 'uncertain_inclusions')),
  1,
  'og den navngir studien dedupliseringen bare antar'
);

-- Rekkefølgen prøven hviler på, festet: er det den *dokumenterte* oversikten som
-- blir avledet, ble den usikre lest først. Uten denne kontrollen kunne prøven
-- stille slutte å dekke tilfellet den er skrevet for.
select is(
  (select u.value -> 'evidence_item_ids' ->> 0
   from jsonb_array_elements(
          knowledge.study_units_for_evidence(array[
            '95000000-0000-4000-8000-00000000003a'::uuid,
            '95000000-0000-4000-8000-00000000003b'::uuid]) -> 'units') as u(value)
   where u.value ->> 'role' = 'derived_review'),
  '95000000-0000-4000-8000-00000000003b',
  'og det er den dokumenterte oversikten som ble avledet: den usikre ble lest først'
);

select is(
  (knowledge.study_units_for_evidence(array[
     '95000000-0000-4000-8000-00000000003c'::uuid,
     '95000000-0000-4000-8000-00000000003d'::uuid]) ->> 'uncertain_linkage')::integer,
  1,
  'og i motsatt rekkefølge gir lesningen det samme svaret'
);

select is(
  (select u.value -> 'evidence_item_ids' ->> 0
   from jsonb_array_elements(
          knowledge.study_units_for_evidence(array[
            '95000000-0000-4000-8000-00000000003c'::uuid,
            '95000000-0000-4000-8000-00000000003d'::uuid]) -> 'units') as u(value)
   where u.value ->> 'role' = 'derived_review'),
  '95000000-0000-4000-8000-00000000003d',
  'der det er den usikre oversikten som ble avledet'
);

-- Avklares den usikre siden, forsvinner usikkerheten — og avtrykket endres.
select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into maalt (label, payload)
select 'r4-avklart', api.link_review_included_study(
  'Syntetisk oversikt R4 for 950 (usikker, leses først)',
  'clinicaltrials_gov', 'NCT00950100', 'Den delte studien S for 950',
  'R4 sitt vedlegg oppgir NCT00950100; inklusjonen er dokumentert.', true);
reset role;

select is(
  (knowledge.study_units_for_evidence(array[
     '95000000-0000-4000-8000-00000000003a'::uuid,
     '95000000-0000-4000-8000-00000000003b'::uuid]) ->> 'uncertain_linkage')::integer,
  0,
  'en avklaring på den siden som dekket studien først, fjerner usikkerheten'
);

select isnt(
  knowledge.study_unit_digest(array[
    '95000000-0000-4000-8000-00000000003a'::uuid,
    '95000000-0000-4000-8000-00000000003b'::uuid]),
  (select payload #>> '{}' from maalt where label = 'par1-avtrykk'),
  'og avtrykket er et annet, også i den rekkefølgen der usikkerheten før forsvant'
);

-- ===========================================================================
-- Del 14 — Sporet er uforanderlig, ikke bare kalt uforanderlig
-- ===========================================================================
select throws_ok(
  format($$update knowledge.review_included_studies set certainty = 'documented' where id = %L$$,
         (select id from fixture_950 where name = 'r3-inklusjon')),
  '23001', null,
  'en inklusjonskobling kan ikke skrives om: den første vurderingen står'
);

select throws_ok(
  format($$delete from knowledge.review_included_studies where id = %L$$,
         (select id from fixture_950 where name = 'r3-inklusjon')),
  '23001', null,
  'og den kan ikke slettes'
);

select throws_ok(
  $$update knowledge.review_inclusion_assessments set certainty = 'uncertain'$$,
  '23001', null,
  'en avklaring kan ikke skrives om i ettertid: da er den ikke et spor'
);

select throws_ok(
  $$delete from knowledge.review_inclusion_assessments$$,
  '23001', null,
  'og den kan ikke slettes'
);

select throws_ok(
  $$update knowledge.study_identity_upgrades set registry_id = 'NCT99999999'$$,
  '23001', null,
  'en oppgradering av en studieidentitet kan ikke skrives om'
);

select throws_ok(
  $$delete from knowledge.study_identity_upgrades$$,
  '23001', null,
  'og den kan ikke slettes'
);

-- ===========================================================================
-- Del 15 — To motsatte avklaringer i samme transaksjon
--
-- `created_at` er transaksjonens starttid, så alle vurderinger i den samme
-- transaksjonen deler tidsstempel. Fram til migrasjon 013q avgjorde tilfeldig
-- UUID-rekkefølge hvilken som var «den siste», og usikker → dokumentert →
-- usikker kunne etterpå leses som dokumentert. Løpenummeret avgjør nå.
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into maalt (label, payload)
select 'r3-tilbake-usikker', api.link_review_included_study(
  'Syntetisk oversikt R3 for 950', 'clinicaltrials_gov', 'NCT00950090',
  'Primærstudie P for 950',
  'Ved ny gjennomlesing er det likevel ikke sikkert at R3 fører nettopp denne studien.', false);
insert into maalt (label, payload)
select 'r3-dokumentert-igjen', api.link_review_included_study(
  'Syntetisk oversikt R3 for 950', 'clinicaltrials_gov', 'NCT00950090',
  'Primærstudie P for 950',
  'Vedlegg B ble hentet fram igjen, og der står NCT00950090 oppført.', true);
insert into maalt (label, payload)
select 'r3-usikker-til-slutt', api.link_review_included_study(
  'Syntetisk oversikt R3 for 950', 'clinicaltrials_gov', 'NCT00950090',
  'Primærstudie P for 950',
  'Vedlegg B viste seg å gjelde en annen oversikt; inklusjonen er usikker igjen.', false);
reset role;

select is(
  knowledge.review_inclusion_certainty(
    (select id from fixture_950 where name = 'r3-inklusjon'))::text,
  'uncertain',
  'den siste vurderingen gjelder, også når tre avklaringer skjer i samme transaksjon'
);

select results_eq(
  format($$select a.assessment_number, a.previous_certainty::text, a.certainty::text
           from knowledge.review_inclusion_assessments a
           where a.review_included_study_id = %L
           order by a.assessment_number$$,
         (select id from fixture_950 where name = 'r3-inklusjon')),
  $$values (1, 'uncertain', 'documented'),
          (2, 'documented', 'uncertain'),
          (3, 'uncertain', 'documented'),
          (4, 'documented', 'uncertain')$$,
  'og sporet leser kjeden i den rekkefølgen den faktisk skjedde'
);

select is(
  (select count(distinct a.created_at)::integer
   from knowledge.review_inclusion_assessments a
   where a.review_included_study_id = (select id from fixture_950 where name = 'r3-inklusjon')),
  1,
  'alle fire deler tidsstempel: rekkefølgen kunne ikke vært lest av created_at'
);

-- ===========================================================================
-- Del 16 — En feilregistrert inklusjon kan trekkes tilbake
--
-- Fram til migrasjon 013r kunne den ikke det. Den eneste etterfølgende
-- tilstanden sporet bar, var sikkerheten — og både `documented` og `uncertain`
-- betyr operativt at studien fortsatt regnes som inkludert. Viste en kobling
-- seg å være feil, ble feilregistreringen permanent virksom i grupperingen, og
-- et reelt uavhengig bidrag ble undertrykt i syntesen og i GRADE-leddet for
-- alltid.
--
-- Her brukes oversikten R3 og primærstudien P fra Del 12: R3 fører P, så P er
-- avledet-dekket og oversikten teller ikke som eget utvalg. Trekkes koblingen
-- tilbake, skal oversikten stå som sitt eget utvalg igjen.
-- ===========================================================================
select is(
  (knowledge.study_units_for_evidence((select funn from usikkert))
     ->> 'independent_units')::integer,
  1,
  'med koblingen i kraft teller oversikten ikke som et eget utvalg'
);

insert into maalt (label, payload)
select 'for-tilbaketrekking', to_jsonb(knowledge.study_unit_digest((select funn from usikkert)));

insert into maalt (label, payload)
select 'oppgave-for-tilbaketrekking', workflow.agent_task(j)
from workflow.pipeline_jobs j where j.id = '95000000-0000-4000-8000-000000000043';

-- En tilbaketrekking av noe som ikke er registrert, er ingen opplysning.
select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  $$select api.retract_review_included_study(
      'Syntetisk oversikt R3 for 950', 'clinicaltrials_gov', 'NCT00959999',
      'En studie Antidep ikke kjenner',
      'Forsøk på å trekke tilbake noe som ikke finnes.')$$,
  'P0002', null,
  'en tilbaketrekking av en kobling som ikke finnes, avvises'
);

insert into maalt (label, payload)
select 'tilbaketrukket', api.retract_review_included_study(
  'Syntetisk oversikt R3 for 950', 'clinicaltrials_gov', 'NCT00950090',
  'Primærstudie P for 950',
  'Ved kontroll mot vedlegg B fører R3 ikke denne studien i det hele tatt; koblingen var en feilregistrering.');
reset role;

select is(
  (select payload ->> 'active' from maalt where label = 'tilbaketrukket'),
  'false',
  'redaktøren kan trekke tilbake en kobling som viste seg å være feil'
);

select is(
  (select (payload ->> 'included_studies')::integer from maalt where label = 'tilbaketrukket'),
  0,
  'og oversikten fører da ingen gjeldende inklusjoner'
);

-- Dette er hele poenget: det uavhengige bidraget er ikke undertrykt lenger.
select is(
  (knowledge.study_units_for_evidence((select funn from usikkert))
     ->> 'independent_units')::integer,
  2,
  'oversikten står som sitt eget utvalg igjen: en feilregistrering undertrykker ikke et reelt bidrag'
);

select is(
  (knowledge.study_units_for_evidence((select funn from usikkert))
     ->> 'derived_reviews')::integer,
  0,
  'og ingen enhet er avledet av en kobling som er trukket tilbake'
);

select isnt(
  knowledge.study_unit_digest((select funn from usikkert)),
  (select payload #>> '{}' from maalt where label = 'for-tilbaketrekking'),
  'avtrykket er et annet etter tilbaketrekkingen'
);

insert into maalt (label, payload)
select 'oppgave-etter-tilbaketrekking', workflow.agent_task(j)
from workflow.pipeline_jobs j where j.id = '95000000-0000-4000-8000-000000000043';

select isnt(
  (select payload ->> 'request_digest' from maalt where label = 'oppgave-etter-tilbaketrekking'),
  (select payload ->> 'request_digest' from maalt where label = 'oppgave-for-tilbaketrekking'),
  'og et svar avgitt før tilbaketrekkingen avvises som foreldet'
);

select is(
  (select payload ->> 'job_key' from maalt where label = 'oppgave-etter-tilbaketrekking'),
  (select payload ->> 'job_key' from maalt where label = 'oppgave-for-tilbaketrekking'),
  'mens jobbnøkkelen står: en tilbaketrekking lager ingen ny oppgave'
);

-- Hele historikken består. Tilbaketrekkingen er en ny rad, ikke en sletting.
-- Tilbaketrekkingen er en *ren* tilstandsendring: sikkerheten står som den var.
-- Sa raden «-> documented» eller «-> uncertain» her, ville den som bare trakk
-- koblingen tilbake, også fått tilskrevet en endring av sikkerhetsvurderingen.
select is(
  (select a.previous_certainty::text || '->' || a.certainty::text
            || '/' || a.previous_state::text || '->' || a.state::text
   from knowledge.review_inclusion_assessments a
   where a.review_included_study_id = (select id from fixture_950 where name = 'r3-inklusjon')
   order by a.assessment_number desc limit 1),
  'uncertain->uncertain/included->retracted',
  'tilbaketrekkingen står i sporet med et før og et etter, og den lar sikkerheten stå'
);

select is(
  (select payload ->> 'certain' from maalt where label = 'tilbaketrukket'),
  'false',
  'og svaret oppgir den sikkerheten som gjelder, ikke en ny'
);

select is(
  (select count(*)::integer from knowledge.review_inclusion_assessments a
   where a.review_included_study_id = (select id from fixture_950 where name = 'r3-inklusjon')),
  5,
  'og de fire tidligere vurderingene står urørt ved siden av den'
);

select throws_ok(
  $$update knowledge.review_inclusion_assessments set state = 'included'$$,
  '23001', null,
  'sporet kan fortsatt ikke skrives om'
);

select throws_ok(
  $$delete from knowledge.review_inclusion_assessments$$,
  '23001', null,
  'og fortsatt ikke slettes'
);

-- Og en tilbaketrekking som selv var feil, kan gjenopprettes — append-only.
select set_config('request.jwt.claims',
                  '{"sub":"95000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into maalt (label, payload)
select 'gjenopprettet', api.link_review_included_study(
  'Syntetisk oversikt R3 for 950', 'clinicaltrials_gov', 'NCT00950090',
  'Primærstudie P for 950',
  'Vedlegg B ble lest på nytt: R3 fører studien likevel, og tilbaketrekkingen var feil.', true);
reset role;

select is(
  (select (payload ->> 'active')::text || '/' || (payload ->> 'certain')::text
   from maalt where label = 'gjenopprettet'),
  'true/true',
  'en tilbaketrekking som selv var feil, kan gjenopprettes uten å slette noe'
);

select is(
  (knowledge.study_units_for_evidence((select funn from usikkert))
     ->> 'derived_reviews')::integer,
  1,
  'og grupperingen leser koblingen igjen'
);

select * from finish();
rollback;
