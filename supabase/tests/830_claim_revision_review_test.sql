-- Migrasjon 012d — revisjonen av en påstand som allerede finnes.
--
-- Filen dekker det siste stedet kjeden med vilje stopper før den er tom for
-- arbeid, og hele veien ut av det:
--
--   * ny evidens om et par som allerede har en påstand, synteseres ikke om
--     igjen automatisk — men den blir en varig, eksplisitt tilstand,
--   * flere nye funn om det samme paret gir én oppgave og ikke flere,
--   * oppgaven står i den åpne arbeidsoversikten som planlagt, redaksjonelt
--     arbeid, uten en eneste intern verdi,
--   * redaktørflaten viser påstanden og den nye forskningen, og ingen uuid,
--   * en beslutning tatt på et foreldet evidensgrunnlag avvises,
--   * mandatgrensen gjelder endepunktet påstanden hører under,
--   * en besluttet revisjon bygger synteseoppgaven med hele grunnlaget og med
--     påstanden den skal gjelde, og resten av kjeden går som før helt fram til
--     en ny kandidat,
--   * historiske revisjoner, kandidater og publiseringer står uendret,
--   * «sett til side» er en faglig konklusjon med begrunnelse, og den åpner seg
--     igjen når det kommer enda mer ny evidens,
--   * en synteseoppgave som stopper teknisk, blir aldri en ny menneskeoppgave,
--     og
--   * rekonsilieringen tar igjen en observasjon en teknisk svikt etterlot.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, P0002 = no_data_found slik plpgsql reiser den.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(115);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('workflow', 'claim_revision_reviews',
                 'workflow.claim_revision_reviews finnes');
select has_table('workflow', 'claim_revision_review_events',
                 'workflow.claim_revision_review_events finnes');
select has_function('workflow', 'notice_claim_revision_need',
                    'workflow.notice_claim_revision_need(uuid, uuid) finnes');
select has_function('workflow', 'claim_synthesis_manifest',
                    'workflow.claim_synthesis_manifest(uuid, uuid, uuid) finnes');

-- Å avgjøre hva en påstand skal si i lys av ny kunnskap er en redaksjonell
-- handling. Ingen av de tre veiene er åpne for en uinnlogget, for service_role
-- eller for PUBLIC.
select is_empty(
  $$
    select f.name, r.role_name
    from (values
      ('api.claim_revision_queue()'),
      ('api.claim_revision_for_decision(text)'),
      ('api.record_claim_revision_decision(text,text,text,text)')
    ) as f(name),
    (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(r.role_name, f.name, 'EXECUTE')
  $$,
  'den redaksjonelle revisjonsflaten er stengt for anon, service_role og PUBLIC'
);

-- Skriveveien er funksjonen og ikke tabellen: en klientrolle som kunne skrive i
-- tilstanden direkte, kunne registrert en avgjørelse ingen tok.
select is_empty(
  $$
    select t.table_name, r.role_name, p.privilege
    from (values ('workflow.claim_revision_reviews'),
                 ('workflow.claim_revision_review_events')) as t(table_name),
         (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, t.table_name, p.privilege)
  $$,
  'ingen klientrolle kan lese eller skrive i den redaksjonelle tilstanden direkte'
);

-- ===========================================================================
-- Del 2 — Fiksturet: en etablert, publisert påstand om et eget endepunkt
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
create temporary table cred (name text primary key, secret text not null) on commit drop;
create temporary table avtrykk (label text primary key, value text not null) on commit drop;
create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table board (label text primary key, payload jsonb not null) on commit drop;
grant select on fixture, cred, avtrykk to anon, authenticated;
grant select, insert on svar, board to anon, authenticated;

insert into fixture (name, id)
select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id)
select 'mirtazapin', id from catalog.drugs where canonical_name = 'mirtazapin';

-- Et eget endepunkt for prøven. Fiksturets sertralin/vektendring bærer allerede
-- en påstand som andre prøver leser, og denne filen skal eie hele forløpet sitt.
insert into catalog.clinical_concepts (id, canonical_label, concept_type)
values ('83000000-0000-4000-8000-0000000000c1', 'søvnlengde i prøve 830', 'outcome'),
       ('83000000-0000-4000-8000-0000000000c2', 'appetitt i prøve 830', 'outcome');
insert into fixture (name, id)
values ('topic', '83000000-0000-4000-8000-0000000000c1'),
       ('annet_endepunkt', '83000000-0000-4000-8000-0000000000c2');

insert into fixture (name, id)
select 'adults', id from catalog.populations
where canonical_label = 'voksne med depressiv lidelse';
insert into fixture (name, id)
select 'owner', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id)
select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id)
select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id)
select 'extraction_verifier', id from provenance.actors
where actor_key = 'agent:extraction-verification';
insert into fixture (name, id)
select 'claim_verifier', id from provenance.actors
where actor_key = 'agent:citation-support-verification';
insert into fixture (name, id)
select 'assessor', id from provenance.actors where actor_key = 'agent:evidence-assessment';

insert into cred
select 'control', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman');

-- Menneskene: en redaktør uten avgrensning, en redaktør avgrenset til et annet
-- endepunkt, en fagperson med sluttkontrollmandat og en med publiseringsrett.
insert into auth.users (id, email) values
  ('83000000-0000-4000-8000-00000000000a', 'redaktor-830@test.invalid'),
  ('83000000-0000-4000-8000-00000000000b', 'annen-redaktor-830@test.invalid'),
  ('83000000-0000-4000-8000-00000000000c', 'fagperson-830@test.invalid'),
  ('83000000-0000-4000-8000-00000000000d', 'publisher-830@test.invalid'),
  ('83000000-0000-4000-8000-00000000000e', 'kliniker-830@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac830000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-830',
   'Redaktør 830', 'Editor uten avgrensning, for 830.',
   '83000000-0000-4000-8000-00000000000a'),
  ('ac830000-0000-4000-8000-00000000000b', 'human', 'human:annen-redaktor-830',
   'Redaktør 830 med avgrenset mandat',
   'Editor avgrenset til et annet endepunkt, for 830.',
   '83000000-0000-4000-8000-00000000000b'),
  ('ac830000-0000-4000-8000-00000000000c', 'human', 'human:fagperson-830',
   'Fagperson 830', 'Reviewer for endepunktet i 830.',
   '83000000-0000-4000-8000-00000000000c'),
  ('ac830000-0000-4000-8000-00000000000d', 'human', 'human:publisher-830',
   'Publisher 830', 'Publiseringsrett for 830.',
   '83000000-0000-4000-8000-00000000000d'),
  ('ac830000-0000-4000-8000-00000000000e', 'human', 'human:kliniker-830',
   'Kliniker 830', 'Uten noen rolle i det hele tatt, for 830.',
   '83000000-0000-4000-8000-00000000000e');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('83000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
   'ac830000-0000-4000-8000-00000000000a', 'Editor-tildeling for 830.'),
  ('83000000-0000-4000-8000-00000000000b', 'editor',
   '83000000-0000-4000-8000-0000000000c2', now() - interval '1 year',
   'ac830000-0000-4000-8000-00000000000a', 'Avgrenset editor-tildeling for 830.'),
  ('83000000-0000-4000-8000-00000000000c', 'reviewer',
   '83000000-0000-4000-8000-0000000000c1', now() - interval '1 year',
   'ac830000-0000-4000-8000-00000000000a', 'Sluttkontrollmandat for 830.'),
  ('83000000-0000-4000-8000-00000000000d', 'publisher', null, now() - interval '1 year',
   'ac830000-0000-4000-8000-00000000000a', 'Publiseringsrett for 830.');

insert into knowledge.sources
  (id, source_type, title, authors_or_issuer, publisher_or_journal, publication_date,
   publication_date_precision, created_by_actor_id)
values
  ('83000000-0000-4000-8000-000000000001', 'journal_article',
   'Den første artikkelen i prøve 830', 'Testforfatter A', 'Tidsskrift 830',
   date '2019-01-01', 'year', (select id from fixture where name = 'owner')),
  ('83000000-0000-4000-8000-000000000002', 'journal_article',
   'Den nye artikkelen i prøve 830', 'Testforfatter B', 'Tidsskrift 830',
   date '2026-01-01', 'year', (select id from fixture where name = 'owner'));

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, external_version, content_hash,
  storage_reference, representation, retrieved_by_actor_id, document_sha256,
  document_byte_size, document_media_type, text_extraction_tool,
  text_extraction_tool_version, text_extraction_arguments, text_extraction_transform
)
select v.id, v.source_id, now(), v.address, 'synthetic-830',
       knowledge.source_version_content_hash('Syntetisk kildetekst ' || v.id::text),
       'private://830-' || v.id::text || '.pdf', 'full_text',
       (select id from fixture where name = 'extractor'),
       pg_temp.synthetic_pdf_digest(v.id::text),
       octet_length(pg_temp.synthetic_pdf(v.id::text)),
       'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from (values
  ('83000000-0000-4000-8000-000000000021'::uuid,
   '83000000-0000-4000-8000-000000000001'::uuid, 'https://example.test/830-a'),
  ('83000000-0000-4000-8000-000000000022'::uuid,
   '83000000-0000-4000-8000-000000000002'::uuid, 'https://example.test/830-b')
) as v(id, source_id, address);

-- Hvert evidensfunn i prøven bygges likt, og skiller seg bare i id, kilde,
-- virkestoff og endepunkt. Én funksjon framfor fire nesten like innsettinger.
create function pg_temp.legg_inn_funn(
  p_id uuid, p_source uuid, p_version uuid, p_drug uuid, p_topic uuid, p_detalj text,
  p_peker text
) returns void language sql as $$
  insert into knowledge.evidence_items (
    id, source_id, source_version_id, design_code, population_id,
    population_availability, population_detail, sample_size, sample_size_availability,
    intervention_drug_id, comparator_kind, outcome_concept_id, outcome_detail,
    timepoint_availability, reported_direction, estimate_availability,
    confidence_interval_availability, source_locator, extraction_method,
    created_by_actor_id
  )
  values (p_id, p_source, p_version, 'randomized_controlled_trial',
          (select id from fixture where name = 'adults'),
          'reported_value', 'Voksne med depressiv lidelse i prøve 830.', 120,
          'reported_value', p_drug, 'none', p_topic, p_detalj,
          'not_reported', 'increase', 'not_reported', 'not_reported',
          p_peker, 'ai_assisted', (select id from fixture where name = 'extractor'));
$$;

-- Og kontrollen av ett funn, i de to radene dekningen krever: den
-- kildeomfattende halvdelen av et globalt fravær kan bare føres opp av en
-- maskinell kontroll med sin egen kjøring (migrasjon 005ae).
create function pg_temp.kontroller_funn(p_id uuid, p_run uuid)
  returns void language sql as $$
  insert into provenance.agent_runs
    (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
     prompt_template_version, pipeline_version, input_manifest)
  select p_run, ai.id, ai.actor_id, 'extraction_verification', 'antidep',
         'deterministic-extraction-check', '1.0.0',
         'extraction-verification/deterministic/1', 'antidep-evidence/1',
         '{"mode": "test-830"}'::jsonb
  from provenance.agent_identities ai
  where ai.identity_key = 'agent-identity:extraction-verification-01';

  insert into workflow.evidence_verifications
    (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
     source_access, checked_fields, rationale, verified_at, agent_run_id)
  select e.id, e.created_by_actor_id,
         (select id from fixture where name = 'extraction_verifier'),
         'verified', 'verifiable_representation',
         array['source_wide_absence']::workflow.evidence_check_field[],
         'Prøve i 830: et søk gjennom hele representasjonen fant ingen verdi.',
         now() - interval '1 hour', p_run
  from knowledge.evidence_items e
  where e.id = p_id and 'source_wide_absence' = any (workflow.required_check_fields(e.id));

  insert into workflow.evidence_verifications
    (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
     source_access, checked_fields, rationale, verified_at)
  select e.id, e.created_by_actor_id,
         (select id from fixture where name = 'extraction_verifier'),
         'verified', 'verifiable_representation',
         array_remove(workflow.required_check_fields(e.id),
                      'source_wide_absence'::workflow.evidence_check_field),
         'Prøve i 830: fullstendig kontrollert ekstraksjon.', now()
  from knowledge.evidence_items e
  where e.id = p_id;
$$;

-- Kildestøttekontrollen av én påstandsrevisjon, som over: Antideps egen
-- deterministiske kode, med sin egen kjøring og sin egen rolle.
create function pg_temp.kontroller_paastand(p_revision uuid, p_run uuid)
  returns void language sql as $$
  insert into provenance.agent_runs
    (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
     prompt_template_version, pipeline_version, input_manifest)
  select p_run, ai.id, ai.actor_id, 'citation_support_verification', 'antidep',
         'deterministic-claim-check', '1.0.0', 'claim-verification/deterministic/1',
         'antidep-evidence/1', '{"mode": "test-830"}'::jsonb
  from provenance.agent_identities ai
  where ai.identity_key = 'agent-identity:citation-support-verification-01';

  insert into workflow.claim_verifications
    (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
     source_access, source_support, population_match, comparator_match, timeframe_match,
     direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
     rationale, verified_at, agent_run_id)
  select r.id, r.created_by_actor_id,
         (select id from fixture where name = 'claim_verifier'),
         'verified', 'verifiable_representation', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
         'Prøve i 830: påstanden dekkes av grunnlaget.', now(), p_run
  from knowledge.claim_revisions r where r.id = p_revision;

  insert into workflow.claim_verification_citations
    (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
     source_access, source_version_id, checked_content_hash, relationship_supported)
  select v.id, v.claim_revision_id, l.id, l.evidence_item_id, 'verifiable_representation',
         e.source_version_id, sv.content_hash, 'ok'
  from workflow.claim_verifications v
  join knowledge.claim_evidence_links l on l.claim_revision_id = v.claim_revision_id
  join knowledge.evidence_items e on e.id = l.evidence_item_id
  join knowledge.source_versions sv on sv.id = e.source_version_id
  where v.claim_revision_id = p_revision
    and v.agent_run_id = p_run;
$$;

create function pg_temp.vurder_paastand(p_revision uuid, p_run uuid)
  returns void language sql as $$
  insert into provenance.agent_runs
    (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
     prompt_template_version, pipeline_version, input_manifest)
  select p_run, ai.id, ai.actor_id, 'evidence_assessment', 'antidep',
         'proposal-registered-assessment', '1.0.0', 'evidence-assessment/proposal/1',
         'antidep-evidence/1', '{"mode": "test-830"}'::jsonb
  from provenance.agent_identities ai
  where ai.identity_key = 'agent-identity:evidence-assessment-01';

  insert into knowledge.evidence_assessments
    (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
     risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
     rationale, evidence_gap, assessed_at, created_by_actor_id, agent_run_id)
  select r.id, r.knowledge_type, 'grade', 'low', 'serious', 'not_assessable',
         'not_serious', 'serious', 'not_assessable',
         'Prøve i 830: vurdering med alle nødvendige domener.',
         'Syntetisk grunnlag har med vilje begrenset dekning.', now(),
         (select id from fixture where name = 'assessor'), p_run
  from knowledge.claim_revisions r where r.id = p_revision;
$$;

-- Det første funnet, og påstanden det bærer. Påstanden lages før kontrollen av
-- funnet, slik at kjeden ser en påstand som finnes — nøyaktig den tilstanden
-- synteseagenten ville etterlatt etter å ha besvart oppgaven sin.
select pg_temp.legg_inn_funn(
  '83000000-0000-4000-8000-000000000011', '83000000-0000-4000-8000-000000000001',
  '83000000-0000-4000-8000-000000000021', (select id from fixture where name = 'sertralin'),
  (select id from fixture where name = 'topic'), 'Lengre søvn ved 8 uker.', 'Tabell 1');

insert into knowledge.claims
  (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
values ('83000000-0000-4000-8000-000000000041', 'evidence_synthesis',
        (select id from fixture where name = 'topic'),
        (select id from fixture where name = 'sertralin'),
        (select id from fixture where name = 'synthesis'));
insert into fixture (name, id)
values ('claim', '83000000-0000-4000-8000-000000000041');

insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
   comparator_kind, direction, uncertainty_summary, created_by_actor_id)
values ('83000000-0000-4000-8000-000000000051',
        '83000000-0000-4000-8000-000000000041', 1, 'evidence_synthesis',
        (select id from fixture where name = 'sertralin'),
        'Sertralin er forbundet med noe lengre søvn ved åtte uker.',
        'Gjelder bare som testdata i 830.', 'none', 'increase',
        'Testusikkerhet: grunnlaget er syntetisk.',
        (select id from fixture where name = 'synthesis'));

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('83000000-0000-4000-8000-000000000051', '83000000-0000-4000-8000-000000000011',
        'supports', 'direct', 'Den opprinnelige lenken i 830.',
        (select id from fixture where name = 'synthesis'));

select pg_temp.kontroller_funn('83000000-0000-4000-8000-000000000011',
                               '83000000-0000-4000-8000-000000000061');

select is(
  (select count(*)::integer from workflow.claim_revision_reviews),
  0,
  'evidens påstanden allerede hviler på, er ikke ny evidens'
);

select pg_temp.kontroller_paastand('83000000-0000-4000-8000-000000000051',
                                   '83000000-0000-4000-8000-000000000062');
select pg_temp.vurder_paastand('83000000-0000-4000-8000-000000000051',
                               '83000000-0000-4000-8000-000000000063');

insert into fixture (name, id)
select 'kandidat1', c.id from knowledge.candidates c
where c.claim_revision_id = '83000000-0000-4000-8000-000000000051';
insert into avtrykk (label, value)
select 'kandidat1', c.candidate_digest from knowledge.candidates c
where c.claim_revision_id = '83000000-0000-4000-8000-000000000051';

select is(
  (select count(*)::integer from fixture where name = 'kandidat1'),
  1,
  'den etablerte påstanden er kommet helt fram til en forseglet kandidat'
);

-- Sluttkontrollen og publiseringen: påstanden er ikke bare etablert, den er det
-- Antidep faktisk sier.
select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select api.record_candidate_final_control(
  (select id from fixture where name = 'kandidat1'),
  (select value from avtrykk where label = 'kandidat1'),
  'approved', 'Prøve i 830: fagpersonen godkjenner det ferdige produktet.');
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'publisert', api.publish_candidate(
  (select id from fixture where name = 'kandidat1'),
  (select value from avtrykk where label = 'kandidat1'),
  'Prøve i 830: første publisering.');
reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (select c.current_published_revision_id from knowledge.claims c
   where c.id = '83000000-0000-4000-8000-000000000041'),
  '83000000-0000-4000-8000-000000000051'::uuid,
  'og den er publisert — dette er en påstand Antidep allerede sier noe med'
);

-- ===========================================================================
-- Del 3 — Ny evidens synteseres ikke om igjen, men blir en synlig oppgave
-- ===========================================================================
select pg_temp.legg_inn_funn(
  '83000000-0000-4000-8000-000000000012', '83000000-0000-4000-8000-000000000002',
  '83000000-0000-4000-8000-000000000022', (select id from fixture where name = 'sertralin'),
  (select id from fixture where name = 'topic'),
  'Kortere søvn ved 12 uker i en ny studie.', 'Tabell 2');
select pg_temp.kontroller_funn('83000000-0000-4000-8000-000000000012',
                               '83000000-0000-4000-8000-000000000064');

select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'claim_synthesis'),
  0,
  'ny evidens om et par som allerede har en påstand, synteseres ikke om igjen'
);
select is(
  (select count(*)::integer from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000041'),
  1,
  'men tilstanden er eksplisitt: én rad sier at ny evidens venter på en avgjørelse'
);
select is(
  (select r.state::text from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000041'),
  'open',
  'og den står åpen'
);
select is(
  (select count(*)::integer from workflow.claim_revision_review_events e
   join workflow.claim_revision_reviews r on r.id = e.claim_revision_review_id
   where r.claim_id = '83000000-0000-4000-8000-000000000041'
     and e.transition = 'opened'),
  1,
  'sporet sier at Antidep la merke til den'
);
select is(
  (select e.actor_id from workflow.claim_revision_review_events e
   join workflow.claim_revision_reviews r on r.id = e.claim_revision_review_id
   where r.claim_id = '83000000-0000-4000-8000-000000000041' and e.transition = 'opened'),
  null,
  'og at det ikke var et menneske som gjorde det — det er ingen avgjørelse ennå'
);
select is(
  (select count(*)::integer from workflow.technical_incidents ti
   where ti.area = 'automatic_task' and ti.resolved_at is null
     and ti.signature like 'kjede:%'),
  0,
  'et faglig «venter på beslutning» registreres aldri som en teknisk feil'
);

-- Idempotens: den samme kontrollen om igjen, og deretter overgangen kalt
-- direkte, skriver ingenting nytt.
select pg_temp.kontroller_funn('83000000-0000-4000-8000-000000000012',
                               '83000000-0000-4000-8000-000000000065');
select is(
  (select count(*)::integer from workflow.claim_revision_reviews),
  1,
  'en gjentatt kontroll lager ingen andre menneskeoppgave'
);
select is(
  (select count(*)::integer from workflow.claim_revision_review_events),
  1,
  'og ingen ny linje i sporet, fordi grunnlaget er det samme'
);

-- Enda et nytt funn om det samme paret. Fortsatt én oppgave — det som endrer
-- seg, er grunnlaget.
select pg_temp.legg_inn_funn(
  '83000000-0000-4000-8000-000000000013', '83000000-0000-4000-8000-000000000002',
  '83000000-0000-4000-8000-000000000022', (select id from fixture where name = 'sertralin'),
  (select id from fixture where name = 'topic'),
  'Et tredje funn om søvnlengde.', 'Tabell 3');
select pg_temp.kontroller_funn('83000000-0000-4000-8000-000000000013',
                               '83000000-0000-4000-8000-000000000066');

select is(
  (select count(*)::integer from workflow.claim_revision_reviews),
  1,
  'to nye funn om det samme paret gir fortsatt én menneskeoppgave'
);
select is(
  (select count(*)::integer from workflow.claim_revision_review_events e
   where e.transition = 'widened'),
  1,
  'men sporet sier at oppgaven har vokst'
);
select is(
  (select e.new_evidence_count from workflow.claim_revision_review_events e
   where e.transition = 'widened'),
  2,
  'og hvor mye ny evidens som da ventet'
);

-- ===========================================================================
-- Del 4 — Den åpne arbeidsoversikten sier det i vanlig språk
-- ===========================================================================
set local role anon;
insert into board (label, payload) select 'aapen', api.public_work_board();
reset role;

select ok(
  (select exists (
     select 1 from board, lateral jsonb_array_elements(payload) as item
     where label = 'aapen'
       and item ->> 'activity' = 'claim_revision'
       and item ->> 'status' = 'planned'
       and item ->> 'waiting_for' = 'editorial_decision'
       and item -> 'subjects' ? 'sertralin')),
  'den uinnloggede ser at ny kunnskap venter på en redaksjonell avgjørelse'
);
select is_empty(
  $$
    select 1 from board, lateral jsonb_array_elements(payload) as item
    where label = 'aapen'
      and item ->> 'activity' = 'claim_revision'
      and (item::text like '%83000000%'
           or item::text like '%søvnlengde%'
           or item::text like '%Sertralin er forbundet%'
           or item::text like '%claim_synthesis%'
           or item::text like '%sha256%')
  $$,
  'og ingen uuid, ingen påstandstekst, ingen agentrolle og ingen avtrykk forlater databasen der'
);
select is(
  (select array_agg(k order by k)
   from board, lateral jsonb_array_elements(payload) as item,
        lateral jsonb_object_keys(item) as k
   where label = 'aapen' and item ->> 'activity' = 'claim_revision'),
  array['activity', 'reference', 'status', 'subjects', 'updated_at', 'waiting_for'],
  'raden bærer de samme seks feltene som resten av oversikten'
);

-- ===========================================================================
-- Del 5 — Redaktørflaten: nok til å ta avgjørelsen, og ikke noe mer
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select throws_ok(
  $$ select api.claim_revision_queue() $$,
  '42501', null,
  'en innlogget uten redaktørmandat kommer ikke til køen'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload) select 'ko', api.claim_revision_queue();
reset role;

select is(
  (select jsonb_array_length(payload) from svar where label = 'ko'),
  1,
  'redaktøren ser nøyaktig den ene oppgaven'
);
select is(
  (select payload -> 0 ->> 'statement' from svar where label = 'ko'),
  'Sertralin er forbundet med noe lengre søvn ved åtte uker.',
  'med påstanden slik den står i dag'
);
select is(
  (select payload -> 0 ->> 'subject_drug' from svar where label = 'ko'),
  'sertralin',
  'virkestoffet den gjelder'
);
select is(
  (select payload -> 0 ->> 'topic' from svar where label = 'ko'),
  'søvnlengde i prøve 830',
  'endepunktet den gjelder'
);
-- To funn, men fra den *samme* artikkelen: ett evidensfunn er ett konkret funn,
-- og flere funn kan komme fra samme studie. En kø som kalte dem to artikler,
-- ville latt den samme studien telle to ganger i den faglige vurderingen.
select is(
  (select (payload -> 0 ->> 'new_article_count')::integer from svar where label = 'ko'),
  1,
  'og hvor mange nye artikler som er kommet til'
);
select is(
  (select (payload -> 0 ->> 'new_finding_count')::integer from svar where label = 'ko'),
  2,
  'og hvor mange nye funn de bærer'
);
select ok(
  (select (payload -> 0 ->> 'published')::boolean from svar where label = 'ko'),
  'og at dette er en påstand Antidep allerede sier noe med'
);

insert into fixture (name, id)
select 'referanse_raw', r.id from workflow.claim_revision_reviews r
where r.claim_id = '83000000-0000-4000-8000-000000000041';
create temporary table handtak (label text primary key, value text not null) on commit drop;
grant select on handtak to anon, authenticated;
insert into handtak (label, value)
select 'oppgave', r.reference from workflow.claim_revision_reviews r
where r.claim_id = '83000000-0000-4000-8000-000000000041';
insert into handtak (label, value)
select 'grunnlag', payload -> 0 ->> 'evidence_basis' from svar where label = 'ko';

select ok(
  (select value not in (select id::text from workflow.claim_revision_reviews)
   from handtak where label = 'oppgave'),
  'håndtaket flaten peker med, er ikke radens egen id'
);

set local role authenticated;
insert into svar (label, payload)
select 'oppgave', api.claim_revision_for_decision(
  (select value from handtak where label = 'oppgave'));
reset role;

select is(
  (select jsonb_array_length(payload -> 'new_evidence') from svar where label = 'oppgave'),
  1,
  'hele oppgaven viser én artikkel, og ikke det samme funnet to ganger'
);
select is(
  (select payload -> 'new_evidence' -> 0 ->> 'article_title' from svar where label = 'oppgave'),
  'Den nye artikkelen i prøve 830',
  'navngitt med bibliografien sin, som er det en redaktør kjenner den igjen på'
);
select is(
  (select jsonb_array_length(payload -> 'new_evidence' -> 0 -> 'findings')
   from svar where label = 'oppgave'),
  2,
  'med begge funnene samlet under artikkelen de faktisk kommer fra'
);
select is(
  (select payload -> 'new_evidence' -> 0 -> 'findings' -> 0 ->> 'study_design'
   from svar where label = 'oppgave'),
  'randomized_controlled_trial',
  'med studiedesignen den faglige avgjørelsen trenger'
);
select is(
  (select payload -> 'new_evidence' -> 0 -> 'findings' -> 0 ->> 'population'
   from svar where label = 'oppgave'),
  'voksne med depressiv lidelse',
  'og populasjonen funnet gjelder'
);
select is_empty(
  $$
    select 1 from svar
    where label = 'oppgave'
      and (payload - 'evidence_basis')::text ~ '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
  $$,
  'og ingen uuid står i det redaktøren får se'
);

-- ===========================================================================
-- Del 6 — Mandatgrensen gjelder endepunktet påstanden hører under
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$ select api.record_claim_revision_decision(%L, 'revise', %L) $$,
    (select value from handtak where label = 'oppgave'),
    (select value from handtak where label = 'grunnlag')),
  '42501', null,
  'en redaktør med mandat for et annet endepunkt kan ikke avgjøre denne'
);

-- Og grensen gjelder like mye ved lesing: hele påstanden og hele det nye
-- evidensgrunnlaget står i svaret, så en kø som viste dem for et område
-- kalleren ikke har mandat i, ville vist klinisk innhold ingen hadde gitt
-- vedkommende adgang til — og bedt om en avgjørelse som uansett blir avvist.
insert into svar (label, payload) select 'ko_avgrenset', api.claim_revision_queue();
select throws_ok(
  format(
    $$ select api.claim_revision_for_decision(%L) $$,
    (select value from handtak where label = 'oppgave')),
  '42501', null,
  'og kan ikke åpne den heller'
);
reset role;

select is(
  (select jsonb_array_length(payload) from svar where label = 'ko_avgrenset'),
  0,
  'og ser den ikke i køen i det hele tatt'
);

select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$ select api.record_claim_revision_decision(%L, 'revise', %L) $$,
    (select value from handtak where label = 'oppgave'),
    (select value from handtak where label = 'grunnlag')),
  '42501', null,
  'og en uten mandat i det hele tatt kommer ingen vei'
);
reset role;

-- ===========================================================================
-- Del 7 — En beslutning på et foreldet grunnlag avvises
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$ select api.record_claim_revision_decision(%L, 'revise', %L) $$,
    (select value from handtak where label = 'oppgave'),
    'sha256-v1:' || repeat('a', 64)),
  '23001', null,
  'en beslutning bundet til et annet grunnlag enn det som ligger der, avvises'
);
select throws_ok(
  format(
    $$ select api.record_claim_revision_decision(%L, 'utsett', %L) $$,
    (select value from handtak where label = 'oppgave'),
    (select value from handtak where label = 'grunnlag')),
  '22023', null,
  'og et tredje utfall finnes ikke'
);
select throws_ok(
  format(
    $$ select api.record_claim_revision_decision(%L, 'set_aside', %L) $$,
    (select value from handtak where label = 'oppgave'),
    (select value from handtak where label = 'grunnlag')),
  '22023', null,
  'en konklusjon om at evidensen ikke endrer påstanden, krever en begrunnelse'
);
reset role;

-- ===========================================================================
-- Del 8 — Redaktøren beslutter revisjon, og kjeden tar over igjen
-- ===========================================================================
set local role authenticated;
insert into svar (label, payload)
select 'beslutning', api.record_claim_revision_decision(
  (select value from handtak where label = 'oppgave'),
  'revise',
  (select value from handtak where label = 'grunnlag'),
  'Den nye studien peker i motsatt retning av dagens formulering.');
reset role;

select ok(
  (select (payload ->> 'recorded')::boolean from svar where label = 'beslutning'),
  'beslutningen registreres'
);
select is(
  (select r.state::text from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000041'),
  'revision_ordered',
  'og tilstanden sier at revisjon er besluttet'
);
select is(
  (select r.decided_by_actor_id from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000041'),
  'ac830000-0000-4000-8000-00000000000a'::uuid,
  'med navnet på den som tok den'
);
select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'claim_synthesis'),
  1,
  'Antidep bygger selv synteseoppgaven, og nøyaktig én'
);
select is(
  (select workflow.manifest_uuid(j.input_manifest, 'claim_id')
   from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  '83000000-0000-4000-8000-000000000041'::uuid,
  'oppgaven sier hvilken påstand revisjonen gjelder'
);
select is(
  (select jsonb_array_length(j.input_manifest -> 'evidence_item_ids')
   from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  3,
  'og bærer hele det gjeldende evidensgrunnlaget, ikke bare det nye'
);
select ok(
  (select exists (select 1 from workflow.agent_handoff_jobs h where h.pipeline_job_id = j.id)
   from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  'den er en vanlig ekstern agentoppgave, ikke en parallell arkitektur'
);
select is(
  (select j.id from workflow.pipeline_jobs j where j.agent_role = 'claim_synthesis'),
  (select r.pipeline_job_id from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000041'),
  'og beslutningen peker på nøyaktig det arbeidet den utløste'
);

-- Oppgaven er ute av den åpne oversikten og ute av køen.
set local role anon;
insert into board (label, payload) select 'etter_beslutning', api.public_work_board();
reset role;
select is_empty(
  $$
    select 1 from board, lateral jsonb_array_elements(payload) as item
    where label = 'etter_beslutning' and item ->> 'activity' = 'claim_revision'
  $$,
  'den redaksjonelle oppgaven er ikke lenger noe som venter på et menneske'
);

set local role authenticated;
insert into svar (label, payload) select 'ko_etter', api.claim_revision_queue();
reset role;
select is(
  (select jsonb_array_length(payload) from svar where label = 'ko_etter'),
  0,
  'og redaktørkøen er tom'
);

-- Idempotens, og fail-closed mot en annen avgjørelse på den samme oppgaven.
set local role authenticated;
insert into svar (label, payload)
select 'gjentatt', api.record_claim_revision_decision(
  (select value from handtak where label = 'oppgave'),
  'revise',
  (select value from handtak where label = 'grunnlag'),
  'Den samme beslutningen en gang til.');
reset role;
select is(
  (select (payload ->> 'recorded')::boolean from svar where label = 'gjentatt'),
  false,
  'den samme beslutningen på det samme grunnlaget er den samme beslutningen'
);
select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'claim_synthesis'),
  1,
  'og den lager ingen andre synteseoppgave'
);

set local role authenticated;
select throws_ok(
  format(
    $$ select api.record_claim_revision_decision(%L, 'set_aside', %L, 'Ombestemte meg.') $$,
    (select value from handtak where label = 'oppgave'),
    (select value from handtak where label = 'grunnlag')),
  '23001', null,
  'og en annen avgjørelse på en oppgave som alt er avgjort, avvises'
);
reset role;
select set_config('request.jwt.claims', '', true);

-- ===========================================================================
-- Del 9 — Resten av kjeden går som før, helt fram til en ny kandidat
-- ===========================================================================
-- Synteseagentens svar, skrevet gjennom den samme veien som før: en ny revisjon
-- av den samme påstanden, med hele grunnlaget lenket.
insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   supersedes_revision_id, statement, scope, comparator_kind, direction,
   uncertainty_summary, created_by_actor_id)
values ('83000000-0000-4000-8000-000000000052',
        '83000000-0000-4000-8000-000000000041', 2, 'evidence_synthesis',
        (select id from fixture where name = 'sertralin'),
        '83000000-0000-4000-8000-000000000051',
        'Sertralin har usikker effekt på søvnlengde; nyere data spriker.',
        'Gjelder bare som testdata i 830.', 'none', 'no_clear_difference',
        'Testusikkerhet: to studier peker i hver sin retning.',
        (select id from fixture where name = 'synthesis'));

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select '83000000-0000-4000-8000-000000000052', e.id,
       case when e.id = '83000000-0000-4000-8000-000000000012'
            then 'contradicts'::knowledge.claim_evidence_relationship
            else 'supports'::knowledge.claim_evidence_relationship end,
       'direct', 'Lenke i den reviderte påstanden i 830.',
       (select id from fixture where name = 'synthesis')
from knowledge.evidence_items e
where e.id in ('83000000-0000-4000-8000-000000000011',
               '83000000-0000-4000-8000-000000000012',
               '83000000-0000-4000-8000-000000000013');

select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.job_key = 'kontroll:kildestotte:83000000-0000-4000-8000-000000000052'),
  1,
  'den nye revisjonen legger kildestøttekontrollen i køen, som enhver revisjon'
);

select pg_temp.kontroller_paastand('83000000-0000-4000-8000-000000000052',
                                   '83000000-0000-4000-8000-000000000067');
select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'evidence_assessment'
     and workflow.manifest_uuid(j.input_manifest, 'claim_revision_id')
         = '83000000-0000-4000-8000-000000000052'),
  1,
  'og den beståtte kontrollen legger evidensvurderingen i køen'
);

select pg_temp.vurder_paastand('83000000-0000-4000-8000-000000000052',
                               '83000000-0000-4000-8000-000000000068');
select is(
  (select count(*)::integer from knowledge.candidates c
   where c.claim_revision_id = '83000000-0000-4000-8000-000000000052'),
  1,
  'og den registrerte vurderingen forsegler en ny kandidat til sluttkontroll'
);
select throws_like(
  $$ select knowledge.assert_claim_revision_publishable(
       '83000000-0000-4000-8000-000000000052') $$,
  '%er ikke sluttkontrollert%',
  'kjeden stopper foran sluttkontrollen, som er den ene menneskeoppgaven'
);

-- Historikken er urørt.
select is(
  (select c.candidate_digest from knowledge.candidates c
   where c.id = (select id from fixture where name = 'kandidat1')),
  (select value from avtrykk where label = 'kandidat1'),
  'den forrige kandidaten er uendret'
);
select is(
  (select count(*)::integer from knowledge.publication_events pe
   where pe.revision_id = '83000000-0000-4000-8000-000000000051'),
  1,
  'og den forrige publiseringen står som den sto'
);
select is(
  (select c.current_published_revision_id from knowledge.claims c
   where c.id = '83000000-0000-4000-8000-000000000041'),
  '83000000-0000-4000-8000-000000000051'::uuid,
  'det publiserte innholdet endres ikke av at en ny revisjon er bygget'
);

-- Og oppgaven kommer ikke tilbake: den nye revisjonen hviler på alt som fantes.
select is(
  (select cardinality(workflow.claim_revision_new_evidence(
     '83000000-0000-4000-8000-000000000041')))::integer,
  0,
  'etter revisjonen er det ingen ny evidens som venter'
);
select is(
  (select r.state::text from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000041'),
  'revision_ordered',
  'og oppgaven blir stående som avgjort'
);

-- ===========================================================================
-- Del 9b — «Det Antidep sier i dag» er det publiserte, ikke det nyeste bygde
-- ===========================================================================
-- Revisjon 2 er bygget og ligger til sluttkontroll; revisjon 1 er fortsatt den
-- klinikeren får se. En flate som viste revisjon 2 under «det Antidep sier i
-- dag» og samtidig sa «publisert og i bruk nå», ville sagt at et utkast er det
-- Antidep faktisk sier (ANTIDEP_CONSTITUTION.md regel 5, 6).
select is(
  (select workflow.claim_revision_task(r, false) ->> 'statement'
   from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000041'),
  'Sertralin er forbundet med noe lengre søvn ved åtte uker.',
  'flaten viser den publiserte formuleringen, og ikke den nyeste bygde'
);
select is(
  (select (workflow.claim_revision_task(r, false) ->> 'revision_number')::integer
   from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000041'),
  1,
  'med dens eget formuleringsnummer'
);
select ok(
  (select (workflow.claim_revision_task(r, false) ->> 'newer_unpublished_revision')::boolean
   from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000041'),
  'og sier eksplisitt at en nyere formulering allerede er bygget, men ikke publisert'
);

-- ===========================================================================
-- Del 10 — «Sett til side» er en faglig konklusjon, ikke en utsettelse
-- ===========================================================================
select pg_temp.legg_inn_funn(
  '83000000-0000-4000-8000-000000000014', '83000000-0000-4000-8000-000000000001',
  '83000000-0000-4000-8000-000000000021', (select id from fixture where name = 'mirtazapin'),
  (select id from fixture where name = 'topic'), 'Mirtazapin og søvnlengde.', 'Tabell 4');

insert into knowledge.claims
  (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
values ('83000000-0000-4000-8000-000000000042', 'evidence_synthesis',
        (select id from fixture where name = 'topic'),
        (select id from fixture where name = 'mirtazapin'),
        (select id from fixture where name = 'synthesis'));

insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
   comparator_kind, direction, uncertainty_summary, created_by_actor_id)
values ('83000000-0000-4000-8000-000000000053',
        '83000000-0000-4000-8000-000000000042', 1, 'evidence_synthesis',
        (select id from fixture where name = 'mirtazapin'),
        'Mirtazapin er forbundet med lengre søvn.',
        'Gjelder bare som testdata i 830.', 'none', 'increase',
        'Testusikkerhet: grunnlaget er syntetisk.',
        (select id from fixture where name = 'synthesis'));

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('83000000-0000-4000-8000-000000000053', '83000000-0000-4000-8000-000000000014',
        'supports', 'direct', 'Den opprinnelige lenken for mirtazapin i 830.',
        (select id from fixture where name = 'synthesis'));

select pg_temp.kontroller_funn('83000000-0000-4000-8000-000000000014',
                               '83000000-0000-4000-8000-000000000069');

select pg_temp.legg_inn_funn(
  '83000000-0000-4000-8000-000000000015', '83000000-0000-4000-8000-000000000002',
  '83000000-0000-4000-8000-000000000022', (select id from fixture where name = 'mirtazapin'),
  (select id from fixture where name = 'topic'),
  'Et lite tilleggsfunn om mirtazapin.', 'Tabell 5');
select pg_temp.kontroller_funn('83000000-0000-4000-8000-000000000015',
                               '83000000-0000-4000-8000-00000000006a');

select is(
  (select r.state::text from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  'open',
  'også den andre påstanden får sin egen oppgave når ny evidens kommer'
);

insert into handtak (label, value)
select 'mirtazapin', r.reference from workflow.claim_revision_reviews r
where r.claim_id = '83000000-0000-4000-8000-000000000042';

select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'mirtazapin_oppgave', api.claim_revision_for_decision(
  (select value from handtak where label = 'mirtazapin'));
reset role;

insert into handtak (label, value)
select 'mirtazapin_grunnlag', payload ->> 'evidence_basis'
from svar where label = 'mirtazapin_oppgave';

set local role authenticated;
insert into svar (label, payload)
select 'satt_til_side', api.record_claim_revision_decision(
  (select value from handtak where label = 'mirtazapin'),
  'set_aside',
  (select value from handtak where label = 'mirtazapin_grunnlag'),
  'Tilleggsfunnet peker samme vei, og endrer ikke formuleringen.');
reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (select r.state::text from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  'set_aside',
  'konklusjonen om at evidensen ikke endrer påstanden, er en tilstand'
);
select is(
  (select r.decision_note from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  'Tilleggsfunnet peker samme vei, og endrer ikke formuleringen.',
  'med den faglige begrunnelsen som skiller den fra en utsettelse'
);
select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'claim_synthesis'
     and workflow.manifest_uuid(j.input_manifest, 'subject_drug_id')
         = (select id from fixture where name = 'mirtazapin')),
  0,
  'og ingen syntese settes i gang'
);

set local role anon;
insert into board (label, payload) select 'etter_sett_til_side', api.public_work_board();
reset role;
select is_empty(
  $$
    select 1 from board, lateral jsonb_array_elements(payload) as item
    where label = 'etter_sett_til_side' and item ->> 'activity' = 'claim_revision'
  $$,
  'oppgaven blir ikke stående i den åpne oversikten som noe ingen kommer til å gjøre'
);

-- Men den åpner seg igjen når grunnlaget faktisk er blitt et annet.
select pg_temp.legg_inn_funn(
  '83000000-0000-4000-8000-000000000016', '83000000-0000-4000-8000-000000000002',
  '83000000-0000-4000-8000-000000000022', (select id from fixture where name = 'mirtazapin'),
  (select id from fixture where name = 'topic'),
  'Enda en studie om mirtazapin og søvn.', 'Tabell 6');
select pg_temp.kontroller_funn('83000000-0000-4000-8000-000000000016',
                               '83000000-0000-4000-8000-00000000006b');

select is(
  (select r.state::text from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  'open',
  'enda mer ny evidens åpner den avgjorte oppgaven igjen'
);
select is(
  (select count(*)::integer from workflow.claim_revision_review_events e
   join workflow.claim_revision_reviews r on r.id = e.claim_revision_review_id
   where r.claim_id = '83000000-0000-4000-8000-000000000042'
     and e.transition = 'reopened'),
  1,
  'og sporet sier hvorfor'
);
select is(
  (select r.decided_evidence_digest from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  null,
  'mens den forrige avgjørelsen ikke lenger står som den gjeldende'
);
select is(
  (select count(*)::integer from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  1,
  'og det er fortsatt én rad, ikke en ny oppgave ved siden av den gamle'
);

-- ===========================================================================
-- Del 11 — En teknisk svikt blir aldri en menneskeoppgave
-- ===========================================================================
update workflow.pipeline_jobs j
set state = 'failed', completed_at = now(),
    failure_reason = 'Prøve i 830: synteseoppgaven stoppet teknisk.'
where j.agent_role = 'claim_synthesis';

select pg_temp.legg_inn_funn(
  '83000000-0000-4000-8000-000000000017', '83000000-0000-4000-8000-000000000002',
  '83000000-0000-4000-8000-000000000022', (select id from fixture where name = 'sertralin'),
  (select id from fixture where name = 'topic'),
  'Et funn som kommer mens synteseoppgaven står fast.', 'Tabell 7');
select pg_temp.kontroller_funn('83000000-0000-4000-8000-000000000017',
                               '83000000-0000-4000-8000-00000000006c');

select is(
  (select r.state::text from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000041'),
  'revision_ordered',
  'en synteseoppgave som stoppet teknisk, gir ingen ny menneskeoppgave'
);
select ok(
  (select exists (
     select 1 from workflow.technical_incidents ti
     where ti.area = 'automatic_task' and ti.resolved_at is null)),
  'svikten er et teknisk problem, og den er synlig som det'
);

-- ===========================================================================
-- Del 12 — En tilbaketrukket påstand får ingen oppgave
-- ===========================================================================
insert into knowledge.claims
  (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id,
   retired_at, retirement_note)
values ('83000000-0000-4000-8000-000000000043', 'evidence_synthesis',
        (select id from fixture where name = 'annet_endepunkt'),
        (select id from fixture where name = 'sertralin'),
        (select id from fixture where name = 'synthesis'),
        now(), 'Trukket tilbake i prøve 830.');

select pg_temp.legg_inn_funn(
  '83000000-0000-4000-8000-000000000018', '83000000-0000-4000-8000-000000000001',
  '83000000-0000-4000-8000-000000000021', (select id from fixture where name = 'sertralin'),
  (select id from fixture where name = 'annet_endepunkt'),
  'Appetitt i prøve 830.', 'Tabell 8');
select pg_temp.kontroller_funn('83000000-0000-4000-8000-000000000018',
                               '83000000-0000-4000-8000-00000000006d');

select is(
  (select count(*)::integer from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000043'),
  0,
  'en tilbaketrukket påstand kan ikke revideres, og får ingen oppgave'
);
select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'claim_synthesis'
     and workflow.manifest_uuid(j.input_manifest, 'topic_concept_id')
         = (select id from fixture where name = 'annet_endepunkt')),
  0,
  'og kjeden synteserer den ikke om igjen bak ryggen på noen'
);

-- ===========================================================================
-- Del 13 — Rekonsilieringen tar igjen en observasjon som gikk tapt
-- ===========================================================================
-- Slettingen etterligner en overgang som aldri kom inn. Triggeren har allerede
-- kjørt, så dette er den eneste måten å framkalle tilstanden på i en prøve.
set local session_replication_role = replica;
delete from workflow.claim_revision_review_events e
where e.claim_revision_review_id in (
  select r.id from workflow.claim_revision_reviews r
  where r.claim_id = '83000000-0000-4000-8000-000000000042');
delete from workflow.claim_revision_reviews r
where r.claim_id = '83000000-0000-4000-8000-000000000042';
set local session_replication_role = origin;

select is(
  (select count(*)::integer from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  0,
  'observasjonen er borte, som etter en teknisk svikt i overgangen'
);

set local role anon;
insert into svar (label, payload)
select 'gjenopptatt', api.resume_chain_transitions(
  'agent-identity:extraction-verification-01',
  (select secret from cred where name = 'control'));
reset role;

select is(
  (select (payload ->> 'revision_reviews')::integer from svar where label = 'gjenopptatt'),
  1,
  'rekonsilieringen melder at den tok igjen nøyaktig én'
);
select is(
  (select r.state::text from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  'open',
  'og oppgaven er synlig igjen'
);

set local role anon;
insert into svar (label, payload)
select 'gjenopptatt2', api.resume_chain_transitions(
  'agent-identity:extraction-verification-01',
  (select secret from cred where name = 'control'));
reset role;
select is(
  (select (payload ->> 'revision_reviews')::integer from svar where label = 'gjenopptatt2'),
  0,
  'en ny kjøring legger ingenting til: veien er idempotent'
);
select is(
  (select count(*)::integer from workflow.claim_revision_reviews),
  2,
  'og det finnes fortsatt nøyaktig én oppgave per påstand'
);

-- ===========================================================================
-- Del 13b — faller den siste nye evidensen bort, er det ikke lenger noe å avgjøre
-- ===========================================================================
-- Et funn kan bli trukket tilbake eller få et åpent avvik etter at oppgaven ble
-- åpnet. Uten en eksplisitt håndtering ville raden blitt stående `open`, vist
-- seg i den åpne arbeidsoversikten som planlagt arbeid, og bedt et menneske om
-- en avgjørelse beslutningsveien uansett avviser — en menneskeoppgave uten et
-- utfall (ANTIDEP_CONSTITUTION.md regel 4).
create function pg_temp.avvis_funn(p_id uuid) returns void language sql as $$
  insert into workflow.evidence_verifications
    (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
     source_access, checked_fields, findings, rationale, verified_at)
  select e.id, e.created_by_actor_id,
         (select id from fixture where name = 'extraction_verifier'),
         'needs_correction', 'verifiable_representation',
         array['source_locator']::workflow.evidence_check_field[],
         'Prøve i 830: kildepekeren stemmer ikke.',
         'Prøve i 830: kontrollen fant et avvik, og funnet er ikke brukbart.', now()
  from knowledge.evidence_items e where e.id = p_id;
$$;

select pg_temp.avvis_funn('83000000-0000-4000-8000-000000000015');
select is(
  (select r.state::text from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  'open',
  'ett av to funn trukket tilbake lar oppgaven stå åpen'
);
select is(
  (select r.pending_evidence_count from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  1,
  'med ett funn igjen å ta stilling til'
);
select is(
  (select count(*)::integer from workflow.claim_revision_review_events e
   join workflow.claim_revision_reviews r on r.id = e.claim_revision_review_id
   where r.claim_id = '83000000-0000-4000-8000-000000000042'
     and e.transition = 'narrowed'),
  1,
  'og sporet sier at den krympet — ikke at den vokste'
);

select pg_temp.avvis_funn('83000000-0000-4000-8000-000000000016');
select is(
  (select r.state::text from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  'lapsed',
  'faller det siste bort, er det ikke lenger noe å avgjøre'
);
select is(
  (select count(*)::integer from workflow.claim_revision_review_events e
   join workflow.claim_revision_reviews r on r.id = e.claim_revision_review_id
   where r.claim_id = '83000000-0000-4000-8000-000000000042'
     and e.transition = 'lapsed'),
  1,
  'og sporet sier hvorfor'
);

set local role anon;
insert into board (label, payload) select 'etter_bortfall', api.public_work_board();
reset role;
select is_empty(
  $$
    select 1 from board, lateral jsonb_array_elements(payload) as item
    where label = 'etter_bortfall' and item ->> 'activity' = 'claim_revision'
  $$,
  'oppgaven står ikke lenger i den åpne oversikten som planlagt arbeid'
);

select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload) select 'ko_bortfalt', api.claim_revision_queue();
select throws_ok(
  format(
    $$ select api.claim_revision_for_decision(%L) $$,
    (select value from handtak where label = 'mirtazapin')),
  'P0002', null,
  'og den kan ikke åpnes'
);
reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (select jsonb_array_length(payload) from svar where label = 'ko_bortfalt'),
  0,
  'og redaktørkøen er tom'
);
select is(
  (select count(*)::integer from workflow.technical_incidents ti
   where ti.area = 'automatic_task' and ti.signature = 'kjede:paastandsrevisjon'
     and ti.resolved_at is null),
  0,
  'et bortfall er ikke en teknisk feil'
);

-- Og kommer den nye kunnskapen tilbake, gjør oppgaven det også.
select pg_temp.kontroller_funn('83000000-0000-4000-8000-000000000016',
                               '83000000-0000-4000-8000-00000000006e');
select is(
  (select r.state::text from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  'open',
  'blir funnet brukbart igjen, åpner oppgaven seg av seg selv'
);
select is(
  (select count(*)::integer from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  1,
  'og det er fortsatt én rad, ikke en ny oppgave ved siden av den gamle'
);

-- ===========================================================================
-- Del 13c — hver vei som kan ta bort ny evidens, holder oppgaven i takt
-- ===========================================================================
-- `workflow.evidence_usable_problem(uuid[], text)` er fasiten for hva «brukbar»
-- betyr, og den leser fire ting som kan endre seg etter at oppgaven ble åpnet:
-- en ny kontroll som ikke bekrefter (prøvd i Del 13b), en kilde som trekkes
-- tilbake, en tilbaketrukket ekstraksjon, og at funnet slettes hardt. Alle fire
-- må lukke oppgaven — ellers står den igjen og ber om en avgjørelse
-- beslutningsveien uansett avviser (ANTIDEP_CONSTITUTION.md regel 4).
--
-- Utgangspunktet er tilstanden Del 13b endte i: oppgaven om mirtazapin står
-- åpen, og funnet ...0016 er det ene brukbare nye funnet.

create function pg_temp.revisjonstilstand() returns text language sql as $$
  select r.state::text from workflow.claim_revision_reviews r
  where r.claim_id = '83000000-0000-4000-8000-000000000042';
$$;

-- --- Kilden trekkes tilbake -------------------------------------------------
update knowledge.sources
set source_status = 'retracted',
    status_note = 'Prøve i 830: kilden er trukket tilbake.'
where id = '83000000-0000-4000-8000-000000000002';

select is(pg_temp.revisjonstilstand(), 'lapsed',
  'en tilbaketrukket kilde tar bort den nye kunnskapen, og oppgaven lukkes');

update knowledge.sources set source_status = 'active', status_note = null
where id = '83000000-0000-4000-8000-000000000002';

select is(pg_temp.revisjonstilstand(), 'open',
  'og en status som settes tilbake, fører den inn igjen');

-- --- Funnet slettes hardt ---------------------------------------------------
-- `knowledge.discard_unpublished_extraction_artifacts(uuid[], text)` sletter
-- evidensraden. Den feiler lukket på et funn som bærer en påstandslenke — men
-- et *nytt* funn som venter på en avgjørelse, har ingen. Etterpå finnes ingen
-- rad som fører tilbake til virkestoffet og endepunktet, så tilstanden må leses
-- på nytt i den samme transaksjonen.
select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000a"}', true);
insert into svar (label, payload)
select 'kastet_funn', knowledge.discard_unpublished_extraction_artifacts(
  array['83000000-0000-4000-8000-000000000016']::uuid[],
  'Prøve i 830: det nye funnet kastes med vilje.');
select set_config('request.jwt.claims', '', true);

select is(
  (select (payload ->> 'resynced_claim_revision_subjects')::integer
   from svar where label = 'kastet_funn'),
  1,
  'fjerningen leser den redaksjonelle tilstanden på nytt for subjektet den rørte'
);
select is(pg_temp.revisjonstilstand(), 'lapsed',
  'og en hard sletting av det siste nye funnet lukker oppgaven');
select is(
  (select count(*)::integer from knowledge.evidence_items e
   where e.id = '83000000-0000-4000-8000-000000000016'),
  0,
  'funnet er faktisk borte, og ikke bare merket'
);

set local role anon;
insert into board (label, payload) select 'etter_sletting', api.public_work_board();
reset role;
select is_empty(
  $$
    select 1 from board, lateral jsonb_array_elements(payload) as item
    where label = 'etter_sletting' and item ->> 'activity' = 'claim_revision'
  $$,
  'oppgaven står ikke i den åpne oversikten etter slettingen'
);

select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload) select 'ko_slettet', api.claim_revision_queue();
reset role;
select set_config('request.jwt.claims', '', true);
select is(
  (select jsonb_array_length(payload) from svar where label = 'ko_slettet'),
  0,
  'og redaktørkøen er tom'
);

-- --- Nettet under: rekonsilieringen ser også på oppgavene som står åpne -----
-- Skrivingen holder tilstanden i takt, og det er den normale mekanismen. Men
-- utvalget som leter etter *manglende* oppgaver, finner et par gjennom en
-- evidensrad, og etter en hard sletting finnes ingen. En oppgave som likevel
-- skulle bli stående åpen uten noe å avgjøre, må kunne nås også da. Her settes
-- den tilbake til åpen med vilje, for å prøve nettopp det nettet.
update workflow.claim_revision_reviews
set state = 'open', pending_evidence_count = 1
where claim_id = '83000000-0000-4000-8000-000000000042';

insert into svar (label, payload)
select 'rekonsiliert_bortfall', api.resume_chain_transitions(
  'agent-identity:extraction-verification-01',
  (select secret from cred where name = 'control'));

select is(pg_temp.revisjonstilstand(), 'lapsed',
  'rekonsilieringen lukker en oppgave som står åpen uten noe å avgjøre');
select is(
  (select (payload ->> 'revision_reviews')::integer
   from svar where label = 'rekonsiliert_bortfall'),
  0,
  'og teller den ikke som en oppgave som ble åpnet'
);

-- --- Ekstraksjonen trekkes tilbake ------------------------------------------
-- Enda et nytt funn, slik at det er noe å trekke tilbake.
select pg_temp.legg_inn_funn(
  '83000000-0000-4000-8000-000000000019', '83000000-0000-4000-8000-000000000002',
  '83000000-0000-4000-8000-000000000022', (select id from fixture where name = 'mirtazapin'),
  (select id from fixture where name = 'topic'),
  'Et siste funn om mirtazapin og søvn.', 'Tabell 7');
select pg_temp.kontroller_funn('83000000-0000-4000-8000-000000000019',
                               '83000000-0000-4000-8000-00000000006f');

select is(pg_temp.revisjonstilstand(), 'open',
  'ny, kontrollert forskning åpner oppgaven igjen');

create function pg_temp.tilbaketrekk(p_id uuid, p_decision text) returns void
language sql as $$
  insert into workflow.review_decisions
    (evidence_item_id, evidence_item_creator_actor_id, review_type, decision,
     rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
  select e.id, e.created_by_actor_id, 'extraction_withdrawal',
         p_decision::workflow.review_outcome,
         'Prøve i 830: beslutning om ekstraksjonen.',
         'ac830000-0000-4000-8000-00000000000c', 'human', now()
  from knowledge.evidence_items e where e.id = p_id;
$$;

select pg_temp.tilbaketrekk('83000000-0000-4000-8000-000000000019', 'extraction_withdrawn');

select is(pg_temp.revisjonstilstand(), 'lapsed',
  'en tilbaketrukket ekstraksjon lukker oppgaven på samme måte');

select pg_temp.tilbaketrekk('83000000-0000-4000-8000-000000000019', 'extraction_upheld');

select is(pg_temp.revisjonstilstand(), 'open',
  'og en beslutning om at ekstraksjonen står ved lag, åpner den igjen');

select is(
  (select count(*)::integer from workflow.technical_incidents ti
   where ti.area = 'automatic_task' and ti.signature = 'kjede:paastandsrevisjon'
     and ti.resolved_at is null),
  0,
  'ingen av de fire veiene ble til et teknisk problem'
);
-- ===========================================================================
-- Del 14 — en fjernet påstand etterlater ingen oppgave om ingenting
-- ===========================================================================
-- `knowledge.discard_unpublished_claim_artifacts(uuid[], text)` sletter
-- påstanden selv, og oppgaven peker på den. Uten at fjerningen river den ned,
-- ville enten kallet feilet på en fremmednøkkel, eller oppgaven blitt stående i
-- den åpne arbeidsoversikten og bedt om en avgjørelse om noe som ikke finnes.
select set_config('request.jwt.claims',
                  '{"sub":"83000000-0000-4000-8000-00000000000a"}', true);
insert into svar (label, payload)
select 'kastet', knowledge.discard_unpublished_claim_artifacts(
  array['83000000-0000-4000-8000-000000000042']::uuid[],
  'Prøve i 830: påstanden kastes med vilje.');
select set_config('request.jwt.claims', '', true);

select is(
  (select (payload ->> 'deleted_claim_revision_reviews')::integer
   from svar where label = 'kastet'),
  1,
  'fjerningen river ned den redaksjonelle oppgaven sammen med påstanden'
);
select is(
  (select count(*)::integer from workflow.claim_revision_reviews r
   where r.claim_id = '83000000-0000-4000-8000-000000000042'),
  0,
  'og oppgaven er borte'
);
select is_empty(
  $$
    select 1 from workflow.claim_revision_review_events e
    where not exists (
      select 1 from workflow.claim_revision_reviews r where r.id = e.claim_revision_review_id)
  $$,
  'og sporet etterlater ingen rad som peker på en oppgave som ikke finnes'
);

select * from finish();
rollback;
