-- Migrasjon 013g — avgrensningen som følger påstanden, og den godkjente
--                  kildebruken som lar databasen finne den.
--
-- Filen dekker den ene grensen i den eksisterende kjeden som ellers ville
-- stoppet monografien, og radene som gjør det mulig å komme forbi den:
--
--   * en godkjent kildebruk knytter én kildeversjon til ett kunnskapsbehov,
--     med hva den er godkjent for der,
--   * databasen utleder hvilket behov et evidensfunn svarer på, og svarer
--     ingenting når svaret er tvetydig,
--   * avgrensningen settes på påstanden av evidenslenkene og aldri av en
--     kaller, og den er uforanderlig når den først er satt,
--   * en eksisterende påstand for det samme temaet og virkestoffet stanser
--     ikke lenger syntesen av et *annet* spørsmål — mens den uavgrensede
--     påstanden likevel får sin revisjonsoppgave,
--   * grunnlaget en syntese bygges av, er avgrenset til behovet,
--   * studien er atskilt fra rapportene om den, koblingen krever et
--     dokumentert grunnlag, og en usikker kobling er synlig som usikker,
--   * et forslag kan navngi behovet verdien ble dokumentert under, og aksepten
--     forgrener nettopp det behovet, og
--   * ingen klientrolle kommer til radene direkte.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23505 = unique_violation,
-- 02000/P0002 = no_data_found.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(59);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('knowledge', 'monograph_source_uses',
                 'knowledge.monograph_source_uses finnes');
select has_table('knowledge', 'studies', 'knowledge.studies finnes');
select has_table('knowledge', 'study_reports', 'knowledge.study_reports finnes');
select has_column('knowledge', 'claims', 'monograph_need_id',
                  'knowledge.claims bærer kunnskapsbehovet påstanden svarer på');
select has_function('knowledge', 'monograph_need_for_evidence_item',
                    'knowledge.monograph_need_for_evidence_item(uuid) finnes');
select has_function('workflow', 'claim_synthesis_subject',
                    'workflow.claim_synthesis_subject(text,text,text) finnes');

select is_empty(
  $$
    select t.table_name, r.role_name, p.privilege
    from (values ('knowledge.monograph_source_uses'),
                 ('knowledge.studies'),
                 ('knowledge.study_reports')) as t(table_name),
         (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, t.table_name, p.privilege)
  $$,
  'ingen klientrolle kan skrive i kildebruken, studiene eller rapportkoblingene'
);

-- Subjektnavnet er det samme som før når påstanden ikke er monografiavgrenset.
-- Oppgavene som alt står i køen, skal ikke skifte subjekt under føttene.
select is(
  workflow.claim_synthesis_subject('a', 'b', null),
  'a+b',
  'uten et kunnskapsbehov er subjektet ordrett det det var'
);
select is(
  workflow.claim_synthesis_subject('a', 'b', 'c'),
  'a+b+c',
  'og med et behov bærer det avgrensningen'
);
select is(
  workflow.agent_task_manifest_subject(
    'claim_synthesis'::provenance.agent_role,
    jsonb_build_object('subject_drug_id', 'a', 'topic_concept_id', 'b')),
  'a+b',
  'oppgaveflaten leser subjektet fra det samme stedet'
);
select is(
  workflow.agent_task_manifest_subject(
    'claim_synthesis'::provenance.agent_role,
    jsonb_build_object('subject_drug_id', 'a', 'topic_concept_id', 'b',
                       'monograph_need_id', 'c')),
  'a+b+c',
  'også når manifestet bærer avgrensningen'
);

-- ===========================================================================
-- Del 2 — Kontoene og bestillingen
-- ===========================================================================
insert into auth.users (id, email)
values ('88000000-0000-4000-8000-00000000000a', 'redaktor-880@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values ('ac880000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-880',
        'Redaktør 880', 'Editor uten avgrensning, for 880.',
        '88000000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('88000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
        'ac880000-0000-4000-8000-00000000000a', 'Editor-tildeling for 880.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
-- Referansene leses som eier og leses *herfra* når rollen er `authenticated`:
-- en klientrolle kommer ikke til de interne schemaene, og det er hele poenget.
create temporary table ref (name text primary key, value text not null) on commit drop;
grant select, insert on svar to authenticated;
grant select on fixture to authenticated;
grant select on ref to authenticated;

insert into fixture (name, id)
select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id)
select 'mirtazapin', id from catalog.drugs where canonical_name = 'mirtazapin';
insert into fixture (name, id)
select 'vektendring', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'adults', id from catalog.populations
where canonical_label = 'voksne med depressiv lidelse';
insert into fixture (name, id)
select 'extractor', pg_temp.extraction_actor_id();
insert into fixture (name, id)
select 'verifier', id from provenance.actors
where actor_key = 'agent:extraction-verification';
insert into fixture (name, id)
select 'owner', id from provenance.actors where actor_key = 'human:peder-holman';

select set_config('request.jwt.claims',
                  '{"sub":"88000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 880.');
insert into svar (label, payload)
select 'annen-bestilling', api.order_monograph('mirtazapin', 'Prøve i 880, en annen utgave.');
-- Utfallet standarden ikke navngir selv: det kommer av litteraturen, gjennom
-- den kontrollerte skriveveien. Aksepten er en egen avgjørelse.
insert into svar (label, payload)
select 'utfall', api.propose_monograph_term(
  (select payload ->> 'reference' from svar where label = 'bestilling'),
  'outcome', 'vektendring',
  'Prøve i 880: vektendring er et dokumentert delutfall for sertralin.');
insert into svar (label, payload)
select 'utfall-akseptert', api.decide_monograph_term(
  (select payload ->> 'reference' from svar where label = 'utfall'), true, null);
reset role;

select ok(
  (select (payload -> 'needs_created')::integer > 0
   from svar where label = 'utfall-akseptert'),
  'en akseptert utfallsverdi utvider dekningskartet med konkrete behov'
);

select ok(
  (select count(*) > 1 from knowledge.monograph_needs n
   join knowledge.monograph_editions e on e.id = n.edition_id
   where e.drug_id = (select id from fixture where name = 'sertralin')
     and n.outcome_concept_id = (select id from fixture where name = 'vektendring')),
  'og flere maler spør om nettopp det utfallet'
);

-- To av dem, navngitt, slik resten av prøven kan snakke om dem.
insert into fixture (name, id)
select 'behov-a', n.id
from knowledge.monograph_needs n
join knowledge.monograph_editions e on e.id = n.edition_id
join knowledge.monograph_question_templates t on t.id = n.template_id
where e.drug_id = (select id from fixture where name = 'sertralin')
  and n.outcome_concept_id = (select id from fixture where name = 'vektendring')
  and t.code = 'MN29'
limit 1;

insert into fixture (name, id)
select 'behov-b', n.id
from knowledge.monograph_needs n
join knowledge.monograph_editions e on e.id = n.edition_id
join knowledge.monograph_question_templates t on t.id = n.template_id
where e.drug_id = (select id from fixture where name = 'sertralin')
  and n.outcome_concept_id = (select id from fixture where name = 'vektendring')
  and t.code = 'MN35'
limit 1;

select isnt(
  (select id from fixture where name = 'behov-a'), null,
  'MN29 har et konkret behov om vektendring'
);
select isnt(
  (select id from fixture where name = 'behov-b'), null,
  'og MN35 har sitt eget, med samme utfall og en annen mal'
);

select is(
  knowledge.monograph_need_scope_label((select id from fixture where name = 'behov-a')),
  'utfall: vektendring',
  'avgrensningen er lesbar, slik to like spørsmål kan skilles fra hverandre'
);

-- ===========================================================================
-- Del 3 — Kilden, den godkjente bruken og et nytt funn
-- ===========================================================================
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('88000000-0000-4000-8000-000000000001', 'journal_article',
        'Syntetisk monografikilde for 880', 'Testforfatter 880',
        (select id from fixture where name = 'owner'));

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, external_version, content_hash,
  storage_reference, representation, retrieved_by_actor_id, document_sha256,
  document_byte_size, document_media_type, text_extraction_tool,
  text_extraction_tool_version, text_extraction_arguments, text_extraction_transform
)
values (
  '88000000-0000-4000-8000-000000000021', '88000000-0000-4000-8000-000000000001',
  now(), 'https://example.test/880', 'synthetic-880',
  knowledge.source_version_content_hash('Syntetisk kildetekst for prøve 880.'),
  'private://880.pdf', 'full_text', (select id from fixture where name = 'extractor'),
  pg_temp.synthetic_pdf_digest('88000000-0000-4000-8000-000000000021'),
  octet_length(pg_temp.synthetic_pdf('88000000-0000-4000-8000-000000000021')),
  'application/pdf', 'pdftotext', '24.02.0',
  '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2');

insert into knowledge.source_version_texts
  (source_version_id, representation, stored_by_actor_id)
values ('88000000-0000-4000-8000-000000000021', 'Syntetisk kildetekst for prøve 880.',
        (select id from fixture where name = 'extractor'));

-- Kilden er godkjent for ett bestemt behov, og for en bestemt bruk der.
insert into knowledge.monograph_source_uses
  (need_id, source_version_id, approved_use, scope_digest, approved_by_actor_id)
select (select id from fixture where name = 'behov-a'),
       '88000000-0000-4000-8000-000000000021',
       'Rapporterer vektendring i kg og andel med klinisk definert vektøkning.',
       n.scope_digest,
       (select id from fixture where name = 'owner')
from knowledge.monograph_needs n
where n.id = (select id from fixture where name = 'behov-a');

select throws_ok(
  $$
    update knowledge.monograph_source_uses
    set approved_use = 'noe annet'
    where approved_use like 'Rapporterer%'
  $$,
  '23001',
  null,
  'en godkjent kildebruk skrives ikke om i ettertid'
);

select throws_ok(
  $$
    insert into knowledge.monograph_source_uses
      (need_id, source_version_id, approved_use, scope_digest, approved_by_actor_id)
    select n.id, '88000000-0000-4000-8000-000000000021',
           'en annen bruk for det samme behovet', n.scope_digest,
           (select id from fixture where name = 'owner')
    from knowledge.monograph_needs n
    where n.id = (select id from fixture where name = 'behov-a')
  $$,
  '23505',
  null,
  'og den samme kildeversjonen godkjennes bare én gang per behov'
);

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_id,
  population_availability, population_detail, sample_size_availability,
  intervention_drug_id, comparator_kind, outcome_concept_id, outcome_detail,
  timepoint_availability, reported_direction, estimate_availability,
  confidence_interval_availability, source_locator, extraction_method,
  created_by_actor_id
)
values ('88000000-0000-4000-8000-000000000011', '88000000-0000-4000-8000-000000000001',
        '88000000-0000-4000-8000-000000000021', 'randomized_controlled_trial',
        (select id from fixture where name = 'adults'),
        'reported_value', 'Prøve i 880.', 'not_reported',
        (select id from fixture where name = 'sertralin'), 'none',
        (select id from fixture where name = 'vektendring'), 'Funn for 880.',
        'not_reported', 'increase', 'not_reported', 'not_reported',
        'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor'));

select is(
  knowledge.monograph_need_for_evidence_item('88000000-0000-4000-8000-000000000011'),
  (select id from fixture where name = 'behov-a'),
  'databasen utleder hvilket kunnskapsbehov funnet svarer på'
);

-- Fiksturets eget funn om det samme paret har ingen godkjent kildebruk, og
-- hører derfor ikke til noe behov. Det er den forsiktige oppførselen: en
-- gjetning ville plassert et kontrollert funn under et spørsmål ingen
-- kontrollerte det for.
select is(
  knowledge.monograph_need_for_evidence_item('f2000000-0000-4000-8000-000000000011'),
  null,
  'et funn uten en godkjent kildebruk hører ikke til noe behov'
);

-- ===========================================================================
-- Del 4 — Porten som stanset monografien
-- ===========================================================================
-- Fiksturet har allerede en påstand om sertralin og vektendring, uten
-- monografiavgrensning. Før 013g stoppet den all videre automatisk syntese om
-- det paret, uansett hvilket spørsmål det nye funnet svarte på.
select is(
  (select count(*)::integer from knowledge.claims c
   where c.subject_drug_id = (select id from fixture where name = 'sertralin')
     and c.topic_concept_id = (select id from fixture where name = 'vektendring')
     and c.monograph_need_id is null),
  1,
  'den artikkelbaserte påstanden om paret finnes fra før'
);

-- Dekningen kommer i to rader, som i 810: den kildeomfattende halvdelen av et
-- globalt fravær kan bare føres opp av en maskinell kontroll med sin egen
-- agentkjøring (migrasjon 005ae).
insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '88000000-0000-4000-8000-000000000061', ai.id, ai.actor_id,
       'extraction_verification', 'antidep', 'deterministic-extraction-check', '1.0.0',
       'extraction-verification/deterministic/1', 'antidep-evidence/1',
       '{"mode": "test-880"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at, agent_run_id)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'verifier'),
       'verified', 'verifiable_representation',
       array['source_wide_absence']::workflow.evidence_check_field[],
       'Prøve i 880: et søk gjennom hele representasjonen fant ingen verdi for de '
       || 'feltene raden fører som fraværende.',
       now() - interval '1 hour', '88000000-0000-4000-8000-000000000061'
from knowledge.evidence_items e
where e.id = '88000000-0000-4000-8000-000000000011'
  and 'source_wide_absence' = any (workflow.required_check_fields(e.id));

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'verifier'),
       'verified', 'verifiable_representation',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Prøve i 880: fullstendig kontrollert ekstraksjon.', now()
from knowledge.evidence_items e
where e.id = '88000000-0000-4000-8000-000000000011';

select is(
  (select count(*)::integer
   from workflow.pipeline_jobs j
   where j.agent_role = 'claim_synthesis'
     and j.id not in (select id from fixture_pipeline_baseline)),
  1,
  'en eksisterende påstand for det samme paret stanser ikke syntesen av et annet spørsmål'
);

select is(
  (select workflow.manifest_uuid(j.input_manifest, 'monograph_need_id')
   from workflow.pipeline_jobs j
   where j.agent_role = 'claim_synthesis'
     and j.id not in (select id from fixture_pipeline_baseline)),
  (select id from fixture where name = 'behov-a'),
  'og oppgaven sier hvilket kunnskapsbehov syntesen skal svare på'
);

select is(
  (select j.job_key
   from workflow.pipeline_jobs j
   where j.agent_role = 'claim_synthesis'
     and j.id not in (select id from fixture_pipeline_baseline))
    like 'agent-handoff:' ||
         (select id::text from fixture where name = 'sertralin') || '+' ||
         (select id::text from fixture where name = 'vektendring') || '+' ||
         (select id::text from fixture where name = 'behov-a') || ':%',
  true,
  'subjektet i nøkkelen bærer avgrensningen'
);

select ok(
  (select exists (
     select 1 from workflow.agent_handoff_jobs h
     join workflow.pipeline_jobs j on j.id = h.pipeline_job_id
     where j.agent_role = 'claim_synthesis'
       and j.id not in (select id from fixture_pipeline_baseline))),
  'synteseoppgaven går gjennom den samme eksterne agentkontrakten som før'
);

-- Og den uavgrensede påstanden blir ikke stille stående: grunnlaget for den er
-- blitt et annet, og det er en redaksjonell avgjørelse.
select is(
  (select count(*)::integer
   from workflow.claim_revision_reviews r
   join knowledge.claims c on c.id = r.claim_id
   where c.monograph_need_id is null
     and c.subject_drug_id = (select id from fixture where name = 'sertralin')
     and c.topic_concept_id = (select id from fixture where name = 'vektendring')
     and r.state = 'open'),
  1,
  'den artikkelbaserte påstanden får sin revisjonsoppgave likevel'
);

-- Grunnlaget en syntese bygges av, er avgrenset til behovet.
select is(
  workflow.claim_subject_evidence(
    (select id from fixture where name = 'sertralin'),
    (select id from fixture where name = 'vektendring'),
    (select id from fixture where name = 'behov-a')),
  array['88000000-0000-4000-8000-000000000011'::uuid],
  'grunnlaget for behovet er bare de funnene som svarer på nettopp det'
);

-- ===========================================================================
-- Del 4b — Ett tema, to spørsmål, to kilder
-- ===========================================================================
-- En annen kilde, godkjent for det andre behovet om det samme temaet. Den samme
-- malen ville ikke skilt dem; avgrensningen gjør det.
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('88000000-0000-4000-8000-000000000002', 'journal_article',
        'En annen syntetisk monografikilde for 880', 'Testforfatter 880',
        (select id from fixture where name = 'owner'));

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, external_version, content_hash,
  storage_reference, representation, retrieved_by_actor_id, document_sha256,
  document_byte_size, document_media_type, text_extraction_tool,
  text_extraction_tool_version, text_extraction_arguments, text_extraction_transform
)
values (
  '88000000-0000-4000-8000-000000000022', '88000000-0000-4000-8000-000000000002',
  now(), 'https://example.test/880b', 'synthetic-880b',
  knowledge.source_version_content_hash('En annen syntetisk kildetekst for prøve 880.'),
  'private://880b.pdf', 'full_text', (select id from fixture where name = 'extractor'),
  pg_temp.synthetic_pdf_digest('88000000-0000-4000-8000-000000000022'),
  octet_length(pg_temp.synthetic_pdf('88000000-0000-4000-8000-000000000022')),
  'application/pdf', 'pdftotext', '24.02.0',
  '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2');

insert into knowledge.source_version_texts
  (source_version_id, representation, stored_by_actor_id)
values ('88000000-0000-4000-8000-000000000022',
        'En annen syntetisk kildetekst for prøve 880.',
        (select id from fixture where name = 'extractor'));

insert into knowledge.monograph_source_uses
  (need_id, source_version_id, approved_use, scope_digest, approved_by_actor_id)
select n.id, '88000000-0000-4000-8000-000000000022',
       'Rapporterer andre plagsomme bivirkninger, uten tall for vekt.',
       n.scope_digest, (select id from fixture where name = 'owner')
from knowledge.monograph_needs n
where n.id = (select id from fixture where name = 'behov-b');

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_id,
  population_availability, population_detail, sample_size_availability,
  intervention_drug_id, comparator_kind, outcome_concept_id, outcome_detail,
  timepoint_availability, reported_direction, estimate_availability,
  confidence_interval_availability, source_locator, extraction_method,
  created_by_actor_id
)
values ('88000000-0000-4000-8000-000000000012', '88000000-0000-4000-8000-000000000002',
        '88000000-0000-4000-8000-000000000022', 'randomized_controlled_trial',
        (select id from fixture where name = 'adults'),
        'reported_value', 'Prøve i 880, det andre funnet.', 'not_reported',
        (select id from fixture where name = 'sertralin'), 'none',
        (select id from fixture where name = 'vektendring'),
        'Funn for 880, under det andre spørsmålet.',
        'not_reported', 'increase', 'not_reported', 'not_reported',
        'Avsnitt 2', 'ai_assisted', (select id from fixture where name = 'extractor'));

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at, agent_run_id)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'verifier'),
       'verified', 'verifiable_representation',
       array['source_wide_absence']::workflow.evidence_check_field[],
       'Prøve i 880: et søk gjennom hele representasjonen fant ingen verdi for de '
       || 'feltene raden fører som fraværende.',
       now() - interval '1 hour', '88000000-0000-4000-8000-000000000061'
from knowledge.evidence_items e
where e.id = '88000000-0000-4000-8000-000000000012'
  and 'source_wide_absence' = any (workflow.required_check_fields(e.id));

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'verifier'),
       'verified', 'verifiable_representation',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Prøve i 880: fullstendig kontrollert ekstraksjon av det andre funnet.', now()
from knowledge.evidence_items e
where e.id = '88000000-0000-4000-8000-000000000012';

select is(
  workflow.claim_subject_evidence(
    (select id from fixture where name = 'sertralin'),
    (select id from fixture where name = 'vektendring'),
    (select id from fixture where name = 'behov-b')),
  array['88000000-0000-4000-8000-000000000012'::uuid],
  'det andre behovet har sitt eget grunnlag, av sin egen kilde'
);

select is(
  workflow.claim_subject_evidence(
    (select id from fixture where name = 'sertralin'),
    (select id from fixture where name = 'vektendring')),
  array['88000000-0000-4000-8000-000000000011'::uuid,
        '88000000-0000-4000-8000-000000000012'::uuid],
  'mens grunnlaget uten en avgrensning er hele parets'
);

select is(
  (select count(*)::integer
   from workflow.pipeline_jobs j
   where j.agent_role = 'claim_synthesis'
     and j.id not in (select id from fixture_pipeline_baseline)),
  2,
  'to spørsmål om det samme temaet er to synteseoppgaver, og ikke én'
);

-- ===========================================================================
-- Del 5 — Avgrensningen settes av evidenslenkene, og er uforanderlig
-- ===========================================================================
insert into knowledge.claims
  (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
values ('88000000-0000-4000-8000-000000000031', 'evidence_synthesis',
        (select id from fixture where name = 'vektendring'),
        (select id from fixture where name = 'sertralin'),
        pg_temp.synthesis_actor_id());

select is(
  (select c.monograph_need_id from knowledge.claims c
   where c.id = '88000000-0000-4000-8000-000000000031'),
  null,
  'en ny påstand har ingen avgrensning før grunnlaget er knyttet til den'
);

insert into knowledge.claim_revisions (
  id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
  population_id, comparator_kind, direction, uncertainty_summary, created_by_actor_id
)
values ('88000000-0000-4000-8000-000000000041',
        '88000000-0000-4000-8000-000000000031', 1, 'evidence_synthesis',
        (select id from fixture where name = 'sertralin'),
        'Prøve i 880: sertralin er forbundet med vektendring i den undersøkte gruppen.',
        'Voksne med depressiv lidelse, 8 uker.',
        (select id from fixture where name = 'adults'), 'none', 'increase',
        'Prøve i 880: ett funn, uten presisjonsmål.',
        pg_temp.synthesis_actor_id());

insert into knowledge.claim_evidence_links (
  claim_revision_id, evidence_item_id, relationship_type, directness,
  relevance_note, created_by_actor_id
)
values ('88000000-0000-4000-8000-000000000041',
        '88000000-0000-4000-8000-000000000011', 'supports', 'direct',
        'Prøve i 880: funnet er grunnlaget for påstanden.',
        pg_temp.synthesis_actor_id());

select is(
  (select c.monograph_need_id from knowledge.claims c
   where c.id = '88000000-0000-4000-8000-000000000031'),
  (select id from fixture where name = 'behov-a'),
  'evidenslenken setter avgrensningen, og kalleren oppgir den ikke'
);

select throws_ok(
  $$
    update knowledge.claims
    set monograph_need_id = null
    where id = '88000000-0000-4000-8000-000000000031'
  $$,
  '23001',
  null,
  'og avgrensningen kan ikke endres etterpå: et kontrollert svar flyttes ikke til et annet spørsmål'
);

-- Nå finnes det en påstand for nettopp dette behovet. Da er videre syntese en
-- redaksjonell avgjørelse igjen — også for monografien.
select is(
  workflow.claim_awaiting_revision(
    (select id from fixture where name = 'sertralin'),
    (select id from fixture where name = 'vektendring'),
    (select id from fixture where name = 'behov-a')),
  '88000000-0000-4000-8000-000000000031'::uuid,
  'påstanden for behovet er den ny evidens om det samme spørsmålet utfordrer'
);

select isnt(
  workflow.claim_awaiting_revision(
    (select id from fixture where name = 'sertralin'),
    (select id from fixture where name = 'vektendring'),
    null),
  '88000000-0000-4000-8000-000000000031'::uuid,
  'og den er ikke den samme som den uavgrensede påstanden om paret'
);

-- ===========================================================================
-- Del 5b — Et blandet evidenssett er ingen avgrensning
--
-- Del 5 viste at ett rent funn setter avgrensningen. Dette er den andre
-- halvparten, og den viktigere: et sett der *noen* av funnene hører til et
-- behov og andre ikke hører til noe monografibehov i det hele tatt, skal ikke
-- gi en avgrensning. Filtrerte utledningen bort de behovsløse funnene før den
-- talte, ville «ett av funnene passer» blitt til «alle funnene passer», og et
-- legacy-funn ville dratt hele påstanden inn under et spørsmål det aldri ble
-- kontrollert for.
-- ===========================================================================
select is(
  knowledge.monograph_need_for_evidence_set(
    array['88000000-0000-4000-8000-000000000011'::uuid]),
  (select id from fixture where name = 'behov-a'),
  'et rent sett gir behovet alle funnene svarer på'
);

select is(
  knowledge.monograph_need_for_evidence_set(
    array['88000000-0000-4000-8000-000000000011'::uuid,
          'f2000000-0000-4000-8000-000000000011'::uuid]),
  null,
  'et blandet sett — ett funn i behovet, ett uten noe behov — gir ingen avgrensning'
);

select is(
  knowledge.monograph_need_for_evidence_set(
    array['f2000000-0000-4000-8000-000000000011'::uuid]),
  null,
  'og et sett der ingen av funnene hører til et behov, gir ingen'
);

select is(
  knowledge.monograph_need_for_evidence_set(array[]::uuid[]),
  null,
  'et tomt sett gir ingen avgrensning'
);

-- Og avgrensningen settes bare når påstanden etableres.
--
-- En påstand som har stått uavgrenset siden den ble laget, skal ikke kunne bli
-- permanent omklassifisert til ett monografibehov den dagen en senere revisjon
-- tilfeldigvis bare lenker monografievidens. Avgrensningen er en del av
-- identiteten, og en identitet etableres én gang.
insert into knowledge.claims
  (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
values ('88000000-0000-4000-8000-000000000032', 'evidence_synthesis',
        (select id from fixture where name = 'vektendring'),
        (select id from fixture where name = 'sertralin'),
        pg_temp.synthesis_actor_id());

insert into knowledge.claim_revisions (
  id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
  population_id, comparator_kind, direction, uncertainty_summary, created_by_actor_id
)
values ('88000000-0000-4000-8000-000000000042',
        '88000000-0000-4000-8000-000000000032', 1, 'evidence_synthesis',
        (select id from fixture where name = 'sertralin'),
        'Prøve i 880: en artikkelbasert påstand, bygget av evidens uten et monografibehov.',
        'Voksne, uten monografiavgrensning.',
        (select id from fixture where name = 'adults'), 'none', 'increase',
        'Prøve i 880: ett funn.',
        pg_temp.synthesis_actor_id());

insert into knowledge.claim_evidence_links (
  claim_revision_id, evidence_item_id, relationship_type, directness,
  relevance_note, created_by_actor_id
)
values ('88000000-0000-4000-8000-000000000042',
        'f2000000-0000-4000-8000-000000000011', 'supports', 'direct',
        'Prøve i 880: funnet hører ikke til noe monografibehov.',
        pg_temp.synthesis_actor_id());

select is(
  (select c.monograph_need_id from knowledge.claims c
   where c.id = '88000000-0000-4000-8000-000000000032'),
  null,
  'en påstand bygget av evidens uten et behov, står uavgrenset'
);

-- En senere revisjon, denne gangen med evidens som *entydig* hører til behov A.
insert into knowledge.claim_revisions (
  id, claim_id, revision_number, knowledge_type, subject_drug_id,
  supersedes_revision_id, statement, scope,
  population_id, comparator_kind, direction, uncertainty_summary, created_by_actor_id
)
values ('88000000-0000-4000-8000-000000000043',
        '88000000-0000-4000-8000-000000000032', 2, 'evidence_synthesis',
        (select id from fixture where name = 'sertralin'),
        '88000000-0000-4000-8000-000000000042',
        'Prøve i 880: samme påstand, skrevet om på monografievidens.',
        'Voksne med depressiv lidelse, 8 uker.',
        (select id from fixture where name = 'adults'), 'none', 'increase',
        'Prøve i 880: ett funn.',
        pg_temp.synthesis_actor_id());

insert into knowledge.claim_evidence_links (
  claim_revision_id, evidence_item_id, relationship_type, directness,
  relevance_note, created_by_actor_id
)
values ('88000000-0000-4000-8000-000000000043',
        '88000000-0000-4000-8000-000000000011', 'supports', 'direct',
        'Prøve i 880: dette funnet hører entydig til behov A.',
        pg_temp.synthesis_actor_id());

select is(
  (select c.monograph_need_id from knowledge.claims c
   where c.id = '88000000-0000-4000-8000-000000000032'),
  null,
  'og en senere revisjon omklassifiserer den ikke: identiteten ble etablert én gang'
);

-- ===========================================================================
-- Del 6 — En tvetydig avgrensning er ingen avgrensning
-- ===========================================================================
insert into knowledge.monograph_source_uses
  (need_id, source_version_id, approved_use, scope_digest, approved_by_actor_id)
select (select id from fixture where name = 'behov-b'),
       '88000000-0000-4000-8000-000000000021',
       'Rapporterer også andre plagsomme bivirkninger enn vektendring.',
       n.scope_digest,
       (select id from fixture where name = 'owner')
from knowledge.monograph_needs n
where n.id = (select id from fixture where name = 'behov-b');

select is(
  knowledge.monograph_need_for_evidence_item('88000000-0000-4000-8000-000000000011'),
  null,
  'to behov som begge kunne passe, gir ingen avgrensning framfor en gjetning'
);

-- ===========================================================================
-- Del 7 — Studien, atskilt fra rapportene om den
-- ===========================================================================
insert into knowledge.studies (id, registry_kind, registry_id, label, created_by_actor_id)
values ('88000000-0000-4000-8000-000000000051', 'clinicaltrials_gov', 'NCT00880880',
        'Syntetisk studie for 880', (select id from fixture where name = 'owner'));

insert into knowledge.study_reports
  (study_id, source_id, report_role, linkage_basis, certainty, linked_by_actor_id)
values ('88000000-0000-4000-8000-000000000051',
        '88000000-0000-4000-8000-000000000001', 'primary_report',
        'Artikkelen oppgir NCT00880880 i metodeavsnittet.', 'documented',
        (select id from fixture where name = 'owner'));

select throws_ok(
  $$
    insert into knowledge.study_reports
      (study_id, source_id, report_role, linkage_basis, certainty, linked_by_actor_id)
    values ('88000000-0000-4000-8000-000000000051',
            'f2000000-0000-4000-8000-000000000001', 'secondary_analysis',
            'Uten oppgitt grunnlag.', 'documented', null)
  $$,
  '23514',
  null,
  'en rapportkobling må si hvem eller hvilken kjøring som gjorde den'
);

insert into knowledge.studies (id, registry_kind, registry_id, label, created_by_actor_id)
values ('88000000-0000-4000-8000-000000000052', null, null,
        'En annen syntetisk studie for 880', (select id from fixture where name = 'owner'));

select throws_ok(
  $$
    insert into knowledge.study_reports
      (study_id, source_id, report_role, linkage_basis, certainty, linked_by_actor_id)
    values ('88000000-0000-4000-8000-000000000052',
            '88000000-0000-4000-8000-000000000001', 'primary_report',
            'Tittelen likner.', 'uncertain',
            (select id from provenance.actors where actor_key = 'human:peder-holman'))
  $$,
  '23505',
  null,
  'og én kilde hører til høyst én studie, ellers ville dobbelttellingsvernet vært uten virkning'
);

-- En usikker kobling er lovlig, og synlig som usikker. Den hindrer at to
-- rapporter regnes som uavhengige, men den påstår ikke at de er samme studie.
insert into knowledge.study_reports
  (study_id, source_id, report_role, linkage_basis, certainty, linked_by_actor_id)
values ('88000000-0000-4000-8000-000000000051',
        'f2000000-0000-4000-8000-000000000001', 'secondary_analysis',
        'Samme forfattergruppe og samme deltakerantall, men ingen oppgitt identifikator.',
        'uncertain', (select id from fixture where name = 'owner'));

select is(
  (select r.certainty::text from knowledge.study_reports r
   where r.source_id = 'f2000000-0000-4000-8000-000000000001'),
  'uncertain',
  'en usikker kobling er lagret som usikker og ikke løst ved en sammenslåing'
);

select is(
  (select count(*)::integer from knowledge.study_reports r
   where r.study_id = '88000000-0000-4000-8000-000000000051'),
  2,
  'to publikasjoner om den samme studien er to rapporter og én studie'
);

-- ===========================================================================
-- Del 8 — Et forslag som navngir behovet verdien kom fra
-- ===========================================================================
insert into fixture (name, id)
select 'mn12-rot', n.id
from knowledge.monograph_needs n
join knowledge.monograph_editions e on e.id = n.edition_id
join knowledge.monograph_question_templates t on t.id = n.template_id
where e.drug_id = (select id from fixture where name = 'sertralin')
  and t.code = 'MN12'
  and n.indication_concept_id is null
  and n.outcome_concept_id is null
limit 1;

insert into fixture (name, id)
select 'annet-behov', n.id
from knowledge.monograph_needs n
join knowledge.monograph_editions e on e.id = n.edition_id
where e.drug_id = (select id from fixture where name = 'mirtazapin')
limit 1;

insert into ref (name, value)
select 'bestilling', payload ->> 'reference' from svar where label = 'bestilling';
insert into ref (name, value)
select 'annet-behov', n.reference from knowledge.monograph_needs n
where n.id = (select id from fixture where name = 'annet-behov');
insert into ref (name, value)
select 'mn12-rot', n.reference from knowledge.monograph_needs n
where n.id = (select id from fixture where name = 'mn12-rot');

select set_config('request.jwt.claims',
                  '{"sub":"88000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;

select throws_ok(
  format(
    $$ select api.propose_monograph_term(%L, 'outcome', 'frafall i prøve 880',
                                         'Prøve i 880: et behov fra en annen utgave.', %L) $$,
    (select value from ref where name = 'bestilling'),
    (select value from ref where name = 'annet-behov')),
  '22023',
  null,
  'et forslag kan ikke navngi et behov fra en annen monografiutgave'
);

-- Først indikasjonen, som utvider MN12 på malens egen akse.
insert into svar (label, payload)
select 'indikasjon', api.propose_monograph_term(
  (select value from ref where name = 'bestilling'),
  'indication', 'depressiv lidelse i prøve 880',
  'Prøve i 880: en dokumentert norsk indikasjon.');
insert into svar (label, payload)
select 'indikasjon-akseptert', api.decide_monograph_term(
  (select payload ->> 'reference' from svar where label = 'indikasjon'), true, null);
reset role;

insert into fixture (name, id)
select 'mn12-indikasjon', n.id
from knowledge.monograph_needs n
join knowledge.monograph_editions e on e.id = n.edition_id
join knowledge.monograph_question_templates t on t.id = n.template_id
join catalog.clinical_concepts c on c.id = n.indication_concept_id
where e.drug_id = (select id from fixture where name = 'sertralin')
  and t.code = 'MN12'
  and c.canonical_label = 'depressiv lidelse i prøve 880'
  and n.outcome_concept_id is null
limit 1;

select isnt(
  (select id from fixture where name = 'mn12-indikasjon'), null,
  'en akseptert indikasjon gir MN12 sitt eget behov for nettopp den'
);

insert into ref (name, value)
select 'mn12-indikasjon', n.reference from knowledge.monograph_needs n
where n.id = (select id from fixture where name = 'mn12-indikasjon');

select set_config('request.jwt.claims',
                  '{"sub":"88000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'delutfall', api.propose_monograph_term(
  (select value from ref where name = 'bestilling'),
  'outcome', 'frafall i prøve 880',
  'Prøve i 880: frafall er rapportert for nettopp denne indikasjonen.',
  (select value from ref where name = 'mn12-indikasjon'));
insert into svar (label, payload)
select 'delutfall-akseptert', api.decide_monograph_term(
  (select payload ->> 'reference' from svar where label = 'delutfall'), true, null);
reset role;

select is(
  (select payload ->> 'from_need' from svar where label = 'delutfall'),
  (select value from ref where name = 'mn12-indikasjon'),
  'forslaget bærer behovet verdien ble dokumentert under'
);

select is(
  (select (payload -> 'needs_created')::integer from svar where label = 'delutfall-akseptert'),
  1,
  'og aksepten forgrener nettopp det behovet: ett nytt behov, ikke et kryssprodukt'
);

select is(
  (select count(*)::integer
   from knowledge.monograph_needs n
   join catalog.clinical_concepts c on c.id = n.outcome_concept_id
   where n.activated_by_need_id = (select id from fixture where name = 'mn12-indikasjon')
     and c.canonical_label = 'frafall i prøve 880'),
  1,
  'det nye behovet står som forgrenet fra behovet verdien kom fra'
);

select is(
  (select n.indication_concept_id
   from knowledge.monograph_needs n
   join catalog.clinical_concepts c on c.id = n.outcome_concept_id
   where n.activated_by_need_id = (select id from fixture where name = 'mn12-indikasjon')
     and c.canonical_label = 'frafall i prøve 880'),
  (select n.indication_concept_id from knowledge.monograph_needs n
   where n.id = (select id from fixture where name = 'mn12-indikasjon')),
  'og det arver indikasjonen fra forelderen, slik avgrensningen blir hele spørsmålet'
);

-- Et åpent forslag utvider ingenting. Aksepten er avgjørelsen.
select set_config('request.jwt.claims',
                  '{"sub":"88000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'apent', api.propose_monograph_term(
  (select value from ref where name = 'bestilling'),
  'outcome', 'remisjon i prøve 880',
  'Prøve i 880: et forslag ingen har tatt stilling til.',
  (select value from ref where name = 'mn12-indikasjon'));
reset role;

select is(
  (select count(*)::integer
   from knowledge.monograph_needs n
   join catalog.clinical_concepts c on c.id = n.outcome_concept_id
   where c.canonical_label = 'remisjon i prøve 880'),
  0,
  'et åpent forslag utvider ingenting'
);

select is(
  (select count(*)::integer from catalog.clinical_concepts c
   where c.canonical_label = 'remisjon i prøve 880'),
  0,
  'og etterlater ingen katalograd ingen har tatt stilling til'
);

-- ===========================================================================
-- Del 9 — Manifestet og oppgaveflaten
-- ===========================================================================
select ok(
  workflow.claim_synthesis_manifest(
    (select id from fixture where name = 'sertralin'),
    (select id from fixture where name = 'vektendring'),
    null,
    (select id from fixture where name = 'behov-b')) ? 'monograph_need_id',
  'manifestet bærer avgrensningen når syntesen svarer på et kunnskapsbehov'
);

select ok(
  not (workflow.claim_synthesis_manifest(
    (select id from fixture where name = 'sertralin'),
    (select id from fixture where name = 'vektendring'),
    null) ? 'monograph_need_id'),
  'og bærer den ikke når den ikke gjør det'
);

select is(
  knowledge.monograph_need_brief(
    (select id from fixture where name = 'behov-b')) ->> 'template_code',
  'MN35',
  'oppgaven kan bære spørsmålet behovet stiller, ordrett fra standarden'
);

select ok(
  length(knowledge.monograph_need_brief(
    (select id from fixture where name = 'behov-b')) ->> 'question') > 20,
  'og spørsmålsteksten er med, slik agenten vet hva grunnlaget er grunnlag for'
);

select is(
  knowledge.monograph_need_brief(null),
  null,
  'uten et behov er det ingenting å bære'
);

select * from finish();
rollback;
