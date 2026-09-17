-- Migrasjon 012b — de automatiske kjedeovergangene.
--
-- Filen dekker at setningene i migrasjonen betyr noe:
--
--   * et registrert evidensfunn legger ekstraksjonskontrollen i køen selv,
--   * en bekreftet ekstraksjonskontroll legger synteseoppgaven i køen,
--   * en registrert påstandsrevisjon legger kildestøttekontrollen i køen,
--   * en bekreftet kildestøttekontroll legger evidensvurderingen i køen,
--   * en registrert evidensvurdering forsegler kandidaten,
--   * ingen av overgangene kan lage to semantisk like oppgaver,
--   * en teknisk svikt i en overgang ruller ikke tilbake det kliniske arbeidet,
--     men blir et teknisk problem og stoppet arbeid,
--   * reparasjonsveien legger inn nøyaktig det triggerne ville lagt inn, og
--     ingenting mer, uansett hvor mange ganger den kjøres,
--   * et kontrolledd er ikke en ekstern agentoppgave og kan ikke hentes ut som
--     en, og
--   * den registrerte representasjonen forlater bare databasen til et
--     kontrolledd med riktig rolle, riktig hemmelighet og en åpen kjøring.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 02000 = no_data_found.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(47);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function('workflow', 'chain_enqueue_job',
                    'workflow.chain_enqueue_job(...) finnes');
select has_function('workflow', 'chain_control_for_evidence_item',
                    'workflow.chain_control_for_evidence_item(uuid) finnes');
select has_function('knowledge', 'build_candidate_row',
                    'knowledge.build_candidate_row(uuid, uuid) finnes');

-- De to nye api-veiene er kontrolleddenes, og kontrollen er legitimasjonen og
-- ikke Data API-rollen — som for de øvrige agentveiene. `service_role` og
-- `public` skal derimot aldri ha dem.
select is_empty(
  $$
    select f.name
    from (values
      ('api.control_source_representation(text,text,uuid,uuid)'),
      ('api.resume_chain_transitions(text,text)')
    ) as f(name)
    where has_function_privilege('public', f.name, 'EXECUTE')
       or has_function_privilege('service_role', f.name, 'EXECUTE')
  $$,
  'kontrolleddenes veier er stengt for service_role og PUBLIC'
);

-- ===========================================================================
-- Del 2 — Fikstur: en artikkel, en kildetekst og legitimasjonen til begge
--         kontrolleddene
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
create temporary table cred (name text primary key, secret text not null) on commit drop;
-- Prøven kaller agentveiene som `anon`, fordi det er slik en agent faktisk når
-- dem: legitimasjonen og ikke Data API-rollen er kontrollen.
create temporary table expected (name text primary key, value text not null) on commit drop;
-- Prøven kaller agentveiene som `anon`, fordi det er slik en agent faktisk når
-- dem: legitimasjonen og ikke Data API-rollen er kontrollen. Da er `knowledge`
-- utilgjengelig, så forventningene regnes ut her og leses derfra.
grant select on fixture to anon;
grant select on cred to anon;
grant select on expected to anon;

insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
-- Et eget endepunkt for prøven. Fiksturets sertralin/vektendring har allerede en
-- påstand, og kjeden synteserer med vilje ikke om igjen en påstand som finnes:
-- å revidere den i lys av ny evidens er en redaksjonell avgjørelse om hva
-- påstanden skal si, ikke en transport.
insert into catalog.clinical_concepts (id, canonical_label, concept_type)
values ('81000000-0000-4000-8000-0000000000c1', 'søvnkvalitet i prøve 810', 'outcome');
insert into fixture (name, id)
select 'topic', id from catalog.clinical_concepts
where canonical_label = 'søvnkvalitet i prøve 810';
insert into fixture (name, id) select 'adults', id from catalog.populations where canonical_label = 'voksne med depressiv lidelse';
insert into fixture (name, id) select 'owner', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'extraction_verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';
insert into fixture (name, id) select 'claim_verifier', id from provenance.actors where actor_key = 'agent:citation-support-verification';
insert into fixture (name, id) select 'assessor', id from provenance.actors where actor_key = 'agent:evidence-assessment';

insert into cred
select 'extraction_verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman');
insert into cred
select 'claim_verifier', provenance.issue_agent_identity_credential(
  'agent-identity:citation-support-verification-01', 'human:peder-holman');
insert into cred
select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman');

-- En redaktør, fordi det å kaste et upublisert artefakt er en redaksjonell
-- avgjørelse med mandat.
insert into auth.users (id, email)
values ('81000000-0000-4000-8000-00000000000b', 'redaktor-810@test.invalid');
insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values ('ac810000-0000-4000-8000-00000000000b', 'human', 'human:redaktor-810',
        'Redaktør 810', 'Aktør med gyldig editor-tildeling, for 810.',
        '81000000-0000-4000-8000-00000000000b');
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('81000000-0000-4000-8000-00000000000b', 'editor', null, now() - interval '1 year',
        'ac810000-0000-4000-8000-00000000000b', 'Gyldig editor-tildeling for 810.');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('81000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 810',
        'Testforfatter 810', (select id from fixture where name = 'owner'));

-- Kildeversjonen er dokumentbundet fulltekst, og fiksturets egen trigger legger
-- filen, publikasjonsbindingen og lesbarhetskontrollen på plass. Fingeravtrykket
-- av *teksten* settes til avtrykket av nøyaktig den teksten prøven lagrer, slik
-- at den registrerte representasjonen faktisk kan legges ved siden av.
insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, external_version, content_hash,
  storage_reference, representation, retrieved_by_actor_id, document_sha256,
  document_byte_size, document_media_type, text_extraction_tool,
  text_extraction_tool_version, text_extraction_arguments, text_extraction_transform
)
values (
  '81000000-0000-4000-8000-000000000021', '81000000-0000-4000-8000-000000000001',
  now(), 'https://example.test/810', 'synthetic-810',
  knowledge.source_version_content_hash('Syntetisk kildetekst for prøve 810.'),
  'private://810.pdf', 'full_text', (select id from fixture where name = 'extractor'),
  pg_temp.synthetic_pdf_digest('81000000-0000-4000-8000-000000000021'),
  octet_length(pg_temp.synthetic_pdf('81000000-0000-4000-8000-000000000021')),
  'application/pdf', 'pdftotext', '24.02.0',
  '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2');

insert into expected
select 'source_text_hash',
       knowledge.source_version_content_hash('Syntetisk kildetekst for prøve 810.');

insert into knowledge.source_version_texts
  (source_version_id, representation, stored_by_actor_id)
values ('81000000-0000-4000-8000-000000000021', 'Syntetisk kildetekst for prøve 810.',
        (select id from fixture where name = 'extractor'));

-- ===========================================================================
-- Del 3 — Et registrert evidensfunn legger kontrollen i køen selv
-- ===========================================================================
insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_id,
  population_availability, population_detail, sample_size_availability,
  intervention_drug_id, comparator_kind, outcome_concept_id, outcome_detail,
  timepoint_availability, reported_direction, estimate_availability,
  confidence_interval_availability, source_locator, extraction_method,
  created_by_actor_id
)
values ('81000000-0000-4000-8000-000000000011', '81000000-0000-4000-8000-000000000001',
        '81000000-0000-4000-8000-000000000021', 'randomized_controlled_trial',
        (select id from fixture where name = 'adults'),
        'reported_value', 'Prøve i 810.', 'not_reported',
        (select id from fixture where name = 'sertralin'), 'none',
        (select id from fixture where name = 'topic'), 'Funn for 810.',
        'not_reported', 'increase', 'not_reported', 'not_reported',
        'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor'));

select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'extraction_verification'
     and j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000011'),
  1,
  'et registrert evidensfunn legger ekstraksjonskontrollen i køen, i det samme kallet'
);
select is(
  (select j.state::text from workflow.pipeline_jobs j
   where j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000011'),
  'ready',
  'og jobben står klar til å tas ut'
);
select is(
  (select workflow.manifest_uuid(j.input_manifest, 'evidence_item_id')
   from workflow.pipeline_jobs j
   where j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000011'),
  '81000000-0000-4000-8000-000000000011'::uuid,
  'med nøyaktig det funnet som utløste den'
);

-- Sporet bærer opphavet. Evidensfunnet her er skrevet direkte og ikke av en
-- agentkjøring, så aktøren er den som skrev det.
select is(
  (select e.actor_id from workflow.pipeline_job_events e
   join workflow.pipeline_jobs j on j.id = e.pipeline_job_id
   where j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000011'),
  (select id from fixture where name = 'extractor'),
  'og sporet sier hvem sitt arbeid som utløste overgangen'
);

-- Et kontrolledd er Antideps egen kode og aldri en ekstern agentoppgave.
select is_empty(
  $$
    select 1 from workflow.agent_handoff_jobs h
    join workflow.pipeline_jobs j on j.id = h.pipeline_job_id
    where j.agent_role in ('extraction_verification', 'citation_support_verification')
  $$,
  'en kontrolljobb er ikke en ekstern agentoppgave og kan ikke hentes ut som en'
);

-- ===========================================================================
-- Del 4 — Idempotens: den samme overgangen kjørt om igjen skriver ingenting
-- ===========================================================================
select is(
  workflow.chain_control_for_evidence_item('81000000-0000-4000-8000-000000000011'),
  null,
  'overgangen kjørt om igjen legger ingenting inn'
);
select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000011'),
  1,
  'og køen har fortsatt nøyaktig én kontroll for funnet'
);

-- ===========================================================================
-- Del 4b — Et funn som kastes, etterlater ingen lampe
-- ===========================================================================
-- Kontrolljobben peker på raden gjennom inndatamanifestet og ikke gjennom en
-- fremmednøkkel. Uten opprydningen ville den blitt tatt ut, feilet til
-- forsøkene var brukt opp, og endt som et uløst teknisk problem om noe som var
-- ment å forsvinne.
insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_id,
  population_availability, population_detail, sample_size_availability,
  intervention_drug_id, comparator_kind, outcome_concept_id, outcome_detail,
  timepoint_availability, reported_direction, estimate_availability,
  confidence_interval_availability, source_locator, extraction_method,
  created_by_actor_id
)
values ('81000000-0000-4000-8000-000000000013', '81000000-0000-4000-8000-000000000001',
        '81000000-0000-4000-8000-000000000021', 'randomized_controlled_trial',
        (select id from fixture where name = 'adults'),
        'reported_value', 'Prøve i 810, et funn som kastes.', 'not_reported',
        (select id from fixture where name = 'sertralin'), 'none',
        (select id from fixture where name = 'topic'), 'Et funn som kastes.',
        'not_reported', 'decrease', 'not_reported', 'not_reported',
        'Avsnitt 3', 'ai_assisted', (select id from fixture where name = 'extractor'));

select is(
  (select j.state::text from workflow.pipeline_jobs j
   where j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000013'),
  'ready',
  'også dette funnet får sin kontroll i køen'
);

select set_config('request.jwt.claims',
                  '{"sub":"81000000-0000-4000-8000-00000000000b"}', true);
select lives_ok(
  $$ select knowledge.discard_unpublished_extraction_artifacts(
       array['81000000-0000-4000-8000-000000000013']::uuid[],
       'Prøve i 810: funnet kastes med vilje.') $$,
  'funnet kan kastes'
);
select set_config('request.jwt.claims', '', true);

select is(
  (select j.state::text from workflow.pipeline_jobs j
   where j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000013'),
  'failed',
  'og kontrollen i køen lukkes, framfor å bli tatt ut og feile tre ganger'
);
select is_empty(
  $$
    select 1 from workflow.technical_incidents ti
    join workflow.pipeline_jobs j
      on ti.signature = 'pipeline-job:' || j.id::text
    where j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000013'
      and ti.resolved_at is null
  $$,
  'uten at det blir et uløst teknisk problem om noe som var ment å forsvinne'
);

-- ===========================================================================
-- Del 5 — Den registrerte representasjonen
-- ===========================================================================
insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '81000000-0000-4000-8000-000000000051', ai.id, ai.actor_id, 'extraction_verification',
       'antidep', 'deterministic-extraction-check', '1.0.0',
       'extraction-verification/deterministic/1', 'antidep-evidence/1',
       '{"mode": "test-810"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';

insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '81000000-0000-4000-8000-000000000052', ai.id, ai.actor_id, 'evidence_extraction',
       'antidep', 'proposal-registered-extraction', '1.0.0',
       'evidence-extraction/proposal/1', 'antidep-evidence/1', '{"mode": "test-810"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:evidence-extraction-01';

set local role anon;
select is(
  (select api.control_source_representation(
     'agent-identity:extraction-verification-01',
     (select secret from cred where name = 'extraction_verifier'),
     '81000000-0000-4000-8000-000000000051',
     '81000000-0000-4000-8000-000000000021') ->> 'text'),
  'Syntetisk kildetekst for prøve 810.',
  'kontrolleddet får den lagrede representasjonen, ordrett'
);
select is(
  (select api.control_source_representation(
     'agent-identity:extraction-verification-01',
     (select secret from cred where name = 'extraction_verifier'),
     '81000000-0000-4000-8000-000000000051',
     '81000000-0000-4000-8000-000000000021') ->> 'content_hash'),
  (select value from expected where name = 'source_text_hash'),
  'og fingeravtrykket den skal regnes mot'
);

-- Et semantisk ledd har ingen vei hit: det får artikkelen i oppgaven sin, og en
-- rolle som kunne lest kildeteksten uten en oppgave, ville vært en vei utenom
-- avgrensningen.
select throws_ok(
  format(
    $$ select api.control_source_representation(
         'agent-identity:evidence-extraction-01', %L,
         '81000000-0000-4000-8000-000000000052',
         '81000000-0000-4000-8000-000000000021') $$,
    (select secret from cred where name = 'extractor')),
  '42501',
  null,
  'et semantisk agentledd kommer ikke til den registrerte representasjonen'
);

select throws_ok(
  $$ select api.control_source_representation(
       'agent-identity:extraction-verification-01', 'feil-hemmelighet',
       '81000000-0000-4000-8000-000000000051',
       '81000000-0000-4000-8000-000000000021') $$,
  '42501',
  null,
  'og heller ikke den som oppgir feil hemmelighet'
);

-- Kjøringen må tilhøre identiteten. Uten den bindingen ville en lesning av
-- kildetekst kunnet skje uten en proveniensrad.
select throws_ok(
  format(
    $$ select api.control_source_representation(
         'agent-identity:extraction-verification-01', %L,
         '81000000-0000-4000-8000-000000000052',
         '81000000-0000-4000-8000-000000000021') $$,
    (select secret from cred where name = 'extraction_verifier')),
  '42501',
  null,
  'en kjøring som tilhører et annet ledd, gir ingen lesning'
);
reset role;

-- ===========================================================================
-- Del 6 — En bekreftet ekstraksjonskontroll legger synteseoppgaven i køen
-- ===========================================================================
-- Først en kontroll som IKKE bekrefter. Et avvik er et resultat kjeden skal
-- stoppe på, ikke gå videre fra.
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, findings, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'needs_correction', 'verifiable_representation',
       array['source_locator']::workflow.evidence_check_field[],
       'Prøve i 810: kildepekeren stemmer ikke.',
       'Prøve i 810: kontrollen fant et avvik.', now() - interval '2 hours'
from knowledge.evidence_items e
where e.id = '81000000-0000-4000-8000-000000000011';

select is(
  (select count(*)::integer from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  0,
  'en kontroll med åpent avvik legger ingen synteseoppgave i køen'
);

-- Og så den som bekrefter, med full dekning. Den kildeomfattende halvdelen av et
-- globalt fravær kan bare føres opp av en maskinell kontroll med sin egen
-- agentkjøring (migrasjon 005ae), så dekningen kommer i to rader — samme grep
-- som i 760_candidate_final_control_test.sql.
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at, agent_run_id)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'verified', 'verifiable_representation',
       array['source_wide_absence']::workflow.evidence_check_field[],
       'Prøve i 810: et søk gjennom hele representasjonen fant ingen verdi for de '
       || 'feltene raden fører som fraværende.',
       now() - interval '1 hour', '81000000-0000-4000-8000-000000000051'
from knowledge.evidence_items e
where e.id = '81000000-0000-4000-8000-000000000011'
  and 'source_wide_absence' = any (workflow.required_check_fields(e.id));

select is(
  (select count(*)::integer from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  0,
  'en kontroll som bare dekker halvparten av det raden påstår, åpner ingenting'
);

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'verified', 'verifiable_representation',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Prøve i 810: fullstendig kontrollert ekstraksjon.', now()
from knowledge.evidence_items e
where e.id = '81000000-0000-4000-8000-000000000011';

select is(
  (select count(*)::integer from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  1,
  'en bekreftet ekstraksjonskontroll legger synteseoppgaven i køen'
);
select is(
  (select workflow.manifest_uuid(j.input_manifest, 'subject_drug_id')
   from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  (select id from fixture where name = 'sertralin'),
  'med virkestoffet funnet gjelder'
);
select is(
  (select workflow.manifest_uuid(j.input_manifest, 'topic_concept_id')
   from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  (select id from fixture where name = 'topic'),
  'og endepunktet funnet gjelder'
);
select ok(
  (select j.input_manifest -> 'evidence_item_ids' ? '81000000-0000-4000-8000-000000000011'
   from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  'og evidensgrunnlaget den skal bygge på'
);
select ok(
  (select exists (select 1 from workflow.agent_handoff_jobs h where h.pipeline_job_id = j.id)
   from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  'synteseoppgaven er en ekstern agentoppgave, og kan hentes ut som en'
);

-- En ny bekreftelse på det samme funnet er ikke et nytt oppdrag. Nøkkelen ville
-- vært en annen om evidenssettet vokste, så duplikatkontrollen går på subjektet.
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'verified', 'verifiable_representation',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Prøve i 810: kontrollert en gang til.', now()
from knowledge.evidence_items e
where e.id = '81000000-0000-4000-8000-000000000011';

select is(
  (select count(*)::integer from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  1,
  'en gjentatt bekreftelse lager ingen andre, semantisk lik synteseoppgave'
);

-- ===========================================================================
-- Del 7 — Påstandsrevisjonen, kildestøttekontrollen, vurderingen og kandidaten
-- ===========================================================================
with c as (
  insert into knowledge.claims (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', (select id from fixture where name = 'topic'),
         (select id from fixture where name = 'sertralin'),
         (select id from fixture where name = 'synthesis')
  returning id, knowledge_type, subject_drug_id, created_by_actor_id
)
insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
select '81000000-0000-4000-8000-000000000031', c.id, 1, c.knowledge_type, c.subject_drug_id,
       'Sertralin er forbundet med en liten vektøkning ved langtidsbruk.',
       'Gjelder bare som testdata i 810.', 'none', 'increase',
       'Testusikkerhet: grunnlaget er syntetisk.', c.created_by_actor_id
from c;

select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.job_key = 'kontroll:kildestotte:81000000-0000-4000-8000-000000000031'),
  1,
  'en registrert påstandsrevisjon legger kildestøttekontrollen i køen'
);
select is(
  (select j.agent_role::text from workflow.pipeline_jobs j
   where j.job_key = 'kontroll:kildestotte:81000000-0000-4000-8000-000000000031'),
  'citation_support_verification',
  'i kildestøttekontrollens egen rolle'
);

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('81000000-0000-4000-8000-000000000031', '81000000-0000-4000-8000-000000000011',
        'supports', 'direct', 'Eneste lenke i 810.',
        (select id from fixture where name = 'synthesis'));

insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '81000000-0000-4000-8000-000000000053', ai.id, ai.actor_id,
       'citation_support_verification', 'antidep', 'deterministic-claim-check', '1.0.0',
       'claim-verification/deterministic/1', 'antidep-evidence/1', '{"mode": "test-810"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:citation-support-verification-01';

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at, agent_run_id)
select r.id, r.created_by_actor_id, (select id from fixture where name = 'claim_verifier'),
       'verified', 'verifiable_representation', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Prøve i 810: påstanden dekkes av grunnlaget.', now(),
       '81000000-0000-4000-8000-000000000053'
from knowledge.claim_revisions r
where r.id = '81000000-0000-4000-8000-000000000031';

insert into workflow.claim_verification_citations
  (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
   source_access, source_version_id, checked_content_hash, relationship_supported)
select v.id, v.claim_revision_id, l.id, l.evidence_item_id, 'verifiable_representation',
       e.source_version_id, sv.content_hash, 'ok'
from workflow.claim_verifications v
join knowledge.claim_evidence_links l on l.claim_revision_id = v.claim_revision_id
join knowledge.evidence_items e on e.id = l.evidence_item_id
join knowledge.source_versions sv on sv.id = e.source_version_id
where v.claim_revision_id = '81000000-0000-4000-8000-000000000031';

select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'evidence_assessment'),
  1,
  'en bekreftet kildestøttekontroll legger evidensvurderingen i køen'
);
select is(
  (select workflow.manifest_uuid(j.input_manifest, 'claim_revision_id')
   from workflow.pipeline_jobs j where j.agent_role = 'evidence_assessment'),
  '81000000-0000-4000-8000-000000000031'::uuid,
  'for nøyaktig den revisjonen som ble kontrollert'
);

insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '81000000-0000-4000-8000-000000000054', ai.id, ai.actor_id, 'evidence_assessment',
       'antidep', 'proposal-registered-assessment', '1.0.0',
       'evidence-assessment/proposal/1', 'antidep-evidence/1', '{"mode": "test-810"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:evidence-assessment-01';

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, evidence_gap, assessed_at, created_by_actor_id, agent_run_id)
select r.id, r.knowledge_type, 'grade', 'low', 'serious', 'not_assessable',
       'not_serious', 'serious', 'not_assessable',
       'Prøve i 810: vurdering med alle nødvendige domener.',
       'Syntetisk grunnlag har med vilje begrenset dekning.', now(),
       (select id from fixture where name = 'assessor'),
       '81000000-0000-4000-8000-000000000054'
from knowledge.claim_revisions r
where r.id = '81000000-0000-4000-8000-000000000031';

select is(
  (select count(*)::integer from knowledge.candidates c
   where c.claim_revision_id = '81000000-0000-4000-8000-000000000031'),
  1,
  'en registrert evidensvurdering forsegler kandidaten, og kjeden er framme'
);
select is(
  (select c.candidate_digest from knowledge.candidates c
   where c.claim_revision_id = '81000000-0000-4000-8000-000000000031'),
  (select knowledge.source_version_content_hash(c.content::text) from knowledge.candidates c
   where c.claim_revision_id = '81000000-0000-4000-8000-000000000031'),
  'og avtrykket er avtrykket av dens eget innhold'
);

-- Det som gjenstår, er den ene avgjørelsen som skal være et menneskes.
select throws_like(
  $$ select knowledge.assert_claim_revision_publishable(
       '81000000-0000-4000-8000-000000000031') $$,
  '%er ikke sluttkontrollert%',
  'kjeden stopper foran sluttkontrollen, som er den ene menneskeoppgaven'
);

-- ===========================================================================
-- Del 8 — Den åpne oversikten sier hva som skjer, uten en eneste intern verdi
-- ===========================================================================
create temporary table board (payload jsonb) on commit drop;
grant select, insert on board to anon;
set local role anon;
insert into board select api.public_work_board();
reset role;

select ok(
  (select exists (
     select 1 from board, lateral jsonb_array_elements(payload) as item
     where item ->> 'activity' = 'claim'
       and item ->> 'status' = 'planned'
       and item -> 'subjects' ? 'sertralin')),
  'den uinnloggede ser synteseoppgaven som planlagt arbeid, med virkestoffet'
);
select is_empty(
  $$
    select 1 from board, lateral jsonb_array_elements(payload) as item
    where item::text like '%kontroll:%'
       or item::text like '%agent-handoff%'
       or item::text like '%81000000%'
  $$,
  'og ingen jobbnøkkel, ingen uuid og ingen agentrolle forlater databasen der'
);

-- ===========================================================================
-- Del 9 — Reparasjonsveien legger inn det som mangler, og aldri mer enn det
-- ===========================================================================
-- Slettingen etterligner en overgang som aldri kom inn: forbindelsen falt bort
-- mellom det kliniske arbeidet og innleggingen. Triggeren har allerede kjørt,
-- så dette er den eneste måten å framkalle tilstanden på i en prøve.
set local session_replication_role = replica;
delete from workflow.pipeline_job_events e
where e.pipeline_job_id in (
  select j.id from workflow.pipeline_jobs j
  where j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000011');
delete from workflow.pipeline_jobs j
where j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000011';
set local session_replication_role = origin;

create temporary table resumed (label text primary key, payload jsonb not null) on commit drop;
grant select, insert on resumed to anon;
set local role anon;
insert into resumed
select 'first', api.resume_chain_transitions(
  'agent-identity:extraction-verification-01',
  (select secret from cred where name = 'extraction_verifier'));
insert into resumed
select 'again', api.resume_chain_transitions(
  'agent-identity:extraction-verification-01',
  (select secret from cred where name = 'extraction_verifier'));
reset role;

-- Antallet er ikke 1: det delte fiksturet rydder bort sine egne kjedeoverganger,
-- og opprydningen finner dem igjen — som den skal. Det som prøves her, er at
-- nettopp den overgangen som manglet, kom tilbake.
select ok(
  exists (select 1 from workflow.pipeline_jobs j
          where j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000011'),
  'reparasjonsveien legger inn overgangen som manglet'
);
select is(
  (select (payload ->> 'queued')::integer from resumed where label = 'again'),
  0,
  'og kjørt om igjen legger den ingenting inn'
);
select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.job_key = 'kontroll:ekstraksjon:81000000-0000-4000-8000-000000000011'),
  1,
  'køen har fortsatt nøyaktig én kontroll for funnet'
);
select is(
  (select count(*)::integer from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  1,
  'og ingen av de andre leddene ble doblet av opprydningen'
);

-- Veien er kontrolleddenes, og den tar ikke imot ett eneste felt fra kalleren.
set local role anon;
select throws_ok(
  format(
    $$ select api.resume_chain_transitions('agent-identity:evidence-extraction-01', %L) $$,
    (select secret from cred where name = 'extractor')),
  '42501',
  null,
  'et semantisk agentledd kan ikke drive kjeden videre'
);
select throws_ok(
  $$ select api.resume_chain_transitions(
       'agent-identity:extraction-verification-01', 'feil-hemmelighet') $$,
  '42501',
  null,
  'og heller ikke den som oppgir feil hemmelighet'
);
reset role;

-- ===========================================================================
-- Del 10 — En teknisk svikt stopper arbeidet, ikke registreringen
-- ===========================================================================
-- Overgangen gjøres umulig med vilje. `create or replace function` er
-- transaksjonell, så erstatningen forsvinner med prøven.
create or replace function workflow.control_job_key(p_kind text, p_subject uuid)
  returns text
  language plpgsql
  set search_path = ''
as $$
begin
  raise exception using errcode = 'io_error', message = 'Prøve i 810: framkalt teknisk svikt.';
end;
$$;

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_id,
  population_availability, population_detail, sample_size_availability,
  intervention_drug_id, comparator_kind, outcome_concept_id, outcome_detail,
  timepoint_availability, reported_direction, estimate_availability,
  confidence_interval_availability, source_locator, extraction_method,
  created_by_actor_id
)
values ('81000000-0000-4000-8000-000000000012', '81000000-0000-4000-8000-000000000001',
        '81000000-0000-4000-8000-000000000021', 'randomized_controlled_trial',
        (select id from fixture where name = 'adults'),
        'reported_value', 'Prøve i 810, andre funn.', 'not_reported',
        (select id from fixture where name = 'sertralin'), 'none',
        (select id from fixture where name = 'topic'), 'Et annet funn for 810.',
        'not_reported', 'decrease', 'not_reported', 'not_reported',
        'Avsnitt 2', 'ai_assisted', (select id from fixture where name = 'extractor'));

select is(
  (select count(*)::integer from knowledge.evidence_items e
   where e.id = '81000000-0000-4000-8000-000000000012'),
  1,
  'en svikt i overgangen ruller ikke tilbake det kliniske arbeidet som nettopp lyktes'
);
select is(
  (select count(*)::integer from workflow.technical_incidents ti
   where ti.area = 'automatic_task' and ti.signature = 'kjede:ekstraksjonskontroll'
     and ti.resolved_at is null),
  1,
  'men den blir et uløst teknisk problem, og aldri en ny menneskeoppgave'
);
select is_empty(
  $$
    select 1 from workflow.technical_incidents ti
    where ti.signature = 'kjede:ekstraksjonskontroll'
      and ti.diagnosis like '%framkalt teknisk svikt%'
  $$,
  'og diagnosen er Antideps egen setning, aldri den videreformidlede feilteksten'
);
select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where workflow.manifest_uuid(j.input_manifest, 'evidence_item_id')
         = '81000000-0000-4000-8000-000000000012'),
  0,
  'arbeidet står, og ingen halvferdig jobb ble liggende igjen'
);

select * from finish();
rollback;
