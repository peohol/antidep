-- Migrasjon 005n — den menneskelige skriveveien inn i workflow.claim_verifications.
--
-- Speilbildet av 470_claim_verification_registration_test.sql for den grenen av
-- workflow.claim_verifier_has_mandate(uuid, uuid, timestamptz) som gjelder et
-- menneske. Filen dekker kontrakten (hva som faktisk er eksponert),
-- autorisasjonen i hver av sine grener, konsekvensen (raden, kontrollradene og
-- auditraden), og de invariantene som skal gjelde likt uansett om det er en
-- maskin eller et menneske som registrerer: dekning av hele evidenssettet,
-- «alle sju må holde» for verified, forbudet mot selvverifikasjon, og
-- append-only.
--
-- I tillegg dekker den de to tingene som er nye i dette leddet:
--
--   * at vurderingen gjelder det evidenssettet revieweren faktisk så
--   * at skriveveiens egen autorisasjon ikke er den eneste sperren — raden har
--     sin egen, og den holder når skriveveiens er mutert bort
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23514 = check_violation, 42501 dekker også
-- manglende tabellrettighet.
begin;

create extension if not exists pgtap with schema extensions;

select plan(43);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'register_human_claim_verification',
  'api.register_human_claim_verification() finnes'
);
select has_function(
  'workflow', 'assert_reviewer_authorized', 'workflow.assert_reviewer_authorized() finnes'
);
select has_function(
  'workflow', 'record_claim_verification', 'workflow.record_claim_verification() finnes'
);
select has_function(
  'workflow', 'assert_evidence_set_unchanged',
  'workflow.assert_evidence_set_unchanged() finnes'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.register_human_claim_verification(uuid,text,text,text,text,text,text,text,text,text,jsonb,text,text)'::regprocedure),
  'api.register_human_claim_verification() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);

-- En faglig vurdering forutsetter en innlogget person. anon skal ikke kunne
-- kalle den i det hele tatt — til forskjell fra agentveien, der legitimasjonen
-- og ikke Data API-rollen er kontrollen.
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.register_human_claim_verification(uuid,text,text,text,text,text,text,text,text,text,jsonb,text,text)'::regprocedure,
      'execute'
    )
  $$,
  'api.register_human_claim_verification() er kjørbar bare for authenticated'
);
select ok(
  has_function_privilege(
    'authenticated',
    'api.register_human_claim_verification(uuid,text,text,text,text,text,text,text,text,text,jsonb,text,text)'::regprocedure,
    'execute'
  ),
  'authenticated kan kalle den'
);

-- Ingen klientrolle får kjøre registreringsleddet direkte: det gjør ingen
-- autorisasjon, og er ment å kalles fra innsiden av en api-funksjon som har
-- avgjort hvem kalleren er.
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'workflow.record_claim_verification(uuid,uuid,uuid,text,text,text,text,text,text,text,text,jsonb,text,text)'::regprocedure,
      'execute'
    )
  $$,
  'ingen klientrolle kan kalle workflow.record_claim_verification() utenom en api-funksjon'
);
select is_empty(
  $$
    select r.role_name, p.priv
    from (values ('anon'), ('authenticated'), ('public')) as r(role_name),
         (values ('select'), ('insert'), ('update'), ('delete')) as p(priv)
    where has_table_privilege(r.role_name, 'workflow.claim_verifications', p.priv)
  $$,
  'klientrollene har ingen tabellrettighet på workflow.claim_verifications'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- Åtte brukerkontoer, én per autorisasjonsgren, og tre påstandsrevisjoner:
--
--   R1  formulert av agent:claim-synthesis, to evidenslenker. Den lykkede
--       stien, dekningen og «alle sju må holde».
--   R2  formulert av reviewer H sin egen aktør, én lenke. Finnes bare for å
--       prøve selvverifikasjonsregelen med en aktør som faktisk har mandatet.
--   R3  formulert av agent:claim-synthesis, én lenke, uten evidensvurdering —
--       så evidenssettet kan utvides og avtrykket bli utdatert.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'extraction_verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';

-- Et annet innholdsområde, slik at en avgrenset tildeling kan prøves mot et
-- tema den ikke dekker.
insert into catalog.clinical_concepts (id, canonical_label, concept_type)
values ('50000000-0000-4000-8000-0000000000f0', 'søvnkvalitet for 500', 'outcome');

insert into auth.users (id, instance_id, aud, role, email)
select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u.email
from (values
  ('50000000-0000-4000-8000-0000000000a0'::uuid, 'a500@example.test'),
  ('50000000-0000-4000-8000-0000000000b0'::uuid, 'b500@example.test'),
  ('50000000-0000-4000-8000-0000000000c0'::uuid, 'c500@example.test'),
  ('50000000-0000-4000-8000-0000000000d0'::uuid, 'd500@example.test'),
  ('50000000-0000-4000-8000-0000000000e0'::uuid, 'e500@example.test'),
  ('50000000-0000-4000-8000-0000000000f1'::uuid, 'f500@example.test'),
  ('50000000-0000-4000-8000-000000000090'::uuid, 'g500@example.test'),
  ('50000000-0000-4000-8000-000000000080'::uuid, 'h500@example.test')
) as u(id, email);

insert into provenance.actors (id, actor_key, actor_type, display_name, description, auth_user_id, retired_at, retirement_note)
values
  -- B: aktør uten noen rolletildeling.
  ('50000000-0000-4000-8000-0000000000b1', 'human:b-500', 'human', 'Kaller B 500',
   'Aktør uten rolle, for 500.', '50000000-0000-4000-8000-0000000000b0', null, null),
  -- C: tilbaketrukket aktør med en ellers gyldig reviewer-tildeling.
  ('50000000-0000-4000-8000-0000000000c1', 'human:c-500', 'human', 'Kaller C 500',
   'Tilbaketrukket aktør, for 500.', '50000000-0000-4000-8000-0000000000c0',
   now() - interval '1 day', 'Tilbaketrukket for testene i 500.'),
  -- D: editor, ikke reviewer.
  ('50000000-0000-4000-8000-0000000000d1', 'human:d-500', 'human', 'Kaller D 500',
   'Editor uten reviewer-rolle, for 500.', '50000000-0000-4000-8000-0000000000d0', null, null),
  -- E: reviewer avgrenset til et annet innholdsområde.
  ('50000000-0000-4000-8000-0000000000e1', 'human:e-500', 'human', 'Kaller E 500',
   'Avgrenset reviewer for et annet tema, for 500.', '50000000-0000-4000-8000-0000000000e0', null, null),
  -- F: reviewer avgrenset til nøyaktig dette innholdsområdet.
  ('50000000-0000-4000-8000-0000000000f2', 'human:f-500', 'human', 'Kaller F 500',
   'Avgrenset reviewer for riktig tema, for 500.', '50000000-0000-4000-8000-0000000000f1', null, null),
  -- G: reviewer-tildeling som er avsluttet.
  ('50000000-0000-4000-8000-000000000091', 'human:g-500', 'human', 'Kaller G 500',
   'Avsluttet reviewer-tildeling, for 500.', '50000000-0000-4000-8000-000000000090', null, null),
  -- H: uavgrenset reviewer.
  ('50000000-0000-4000-8000-000000000081', 'human:h-500', 'human', 'Kaller H 500',
   'Uavgrenset reviewer, for 500.', '50000000-0000-4000-8000-000000000080', null, null);

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to,
   granted_by_actor_id, grant_reason, ended_by_actor_id, end_reason)
values
  ('50000000-0000-4000-8000-0000000000c0', 'reviewer', null,
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller C i 500.', null, null),
  ('50000000-0000-4000-8000-0000000000d0', 'editor', null,
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller D i 500.', null, null),
  ('50000000-0000-4000-8000-0000000000e0', 'reviewer', '50000000-0000-4000-8000-0000000000f0',
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller E i 500.', null, null),
  ('50000000-0000-4000-8000-0000000000f1', 'reviewer', (select id from fixture where name = 'weight'),
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller F i 500.', null, null),
  ('50000000-0000-4000-8000-000000000090', 'reviewer', null,
   now() - interval '2 years', now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Tildeling for kaller G i 500.',
   (select id from fixture where name = 'editor'), 'Avsluttet for testene i 500.'),
  ('50000000-0000-4000-8000-000000000080', 'reviewer', null,
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller H i 500.', null, null);

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('50000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 500',
        'Testforfatter 500', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
values
  ('50000000-0000-4000-8000-000000000021', '50000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/500-a', 'sha256:' || repeat('a', 64),
   (select id from fixture where name = 'extractor')),
  ('50000000-0000-4000-8000-000000000022', '50000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/500-b', 'sha256:' || repeat('b', 64),
   (select id from fixture where name = 'extractor'));

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values
  ('50000000-0000-4000-8000-000000000011', '50000000-0000-4000-8000-000000000001',
   '50000000-0000-4000-8000-000000000021',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 500.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Første funn, for 500.',
   'not_reported', 'increase', 'not_reported', 'not_reported',
   'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor')),
  ('50000000-0000-4000-8000-000000000012', '50000000-0000-4000-8000-000000000001',
   '50000000-0000-4000-8000-000000000022',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 500.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Andre funn, for 500.',
   'not_reported', 'increase', 'not_reported', 'not_reported',
   'Avsnitt 2', 'ai_assisted', (select id from fixture where name = 'extractor')),
  ('50000000-0000-4000-8000-000000000013', '50000000-0000-4000-8000-000000000001',
   '50000000-0000-4000-8000-000000000021',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 500.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Tredje funn, for 500.',
   'not_reported', 'increase', 'not_reported', 'not_reported',
   'Avsnitt 3', 'ai_assisted', (select id from fixture where name = 'extractor'));

create function pg_temp.make_revision(p_revision_id uuid, p_author uuid, p_statement text)
  returns void language plpgsql as $$
begin
  with c as (
    insert into knowledge.claims
      (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
    select 'evidence_synthesis',
           (select id from fixture where name = 'weight'),
           (select id from fixture where name = 'sertralin'),
           p_author
    returning id, knowledge_type, subject_drug_id, created_by_actor_id
  )
  insert into knowledge.claim_revisions
    (id, claim_id, revision_number, knowledge_type, subject_drug_id,
     statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
  select p_revision_id, c.id, 1, c.knowledge_type, c.subject_drug_id,
         p_statement, 'Gjelder bare som testdata i 500.', 'none', 'increase',
         'Testusikkerhet.', c.created_by_actor_id
  from c;
end;
$$;

select pg_temp.make_revision('50000000-0000-4000-8000-000000000031',
  (select id from fixture where name = 'synthesis'), 'Testpåstand R1 for 500.');
select pg_temp.make_revision('50000000-0000-4000-8000-000000000032',
  '50000000-0000-4000-8000-000000000081', 'Testpåstand R2 for 500, formulert av reviewer H.');
-- To revisjoner uten evidenslenker, for låseprøven i Del 7 og Del 10. De må stå
-- urørte: hver innsetting i knowledge.claim_evidence_links tar selv FOR UPDATE
-- på revisjonen, så en revisjon med en lenke ville allerede vært låst av
-- fiksturen og prøven ville målt fiksturen framfor kontrollen.
select pg_temp.make_revision('50000000-0000-4000-8000-000000000035',
  (select id from fixture where name = 'synthesis'), 'Testpåstand R5 for 500, uten lenker.');
select pg_temp.make_revision('50000000-0000-4000-8000-000000000036',
  (select id from fixture where name = 'synthesis'), 'Testpåstand R6 for 500, uten lenker.');

select pg_temp.make_revision('50000000-0000-4000-8000-000000000033',
  (select id from fixture where name = 'synthesis'), 'Testpåstand R3 for 500.');

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values
  ('50000000-0000-4000-8000-000000000041', '50000000-0000-4000-8000-000000000031',
   '50000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Første lenke på R1 i 500.', (select id from fixture where name = 'synthesis')),
  ('50000000-0000-4000-8000-000000000042', '50000000-0000-4000-8000-000000000031',
   '50000000-0000-4000-8000-000000000012', 'contradicts', 'direct',
   'Andre lenke på R1 i 500, motstridende.', (select id from fixture where name = 'synthesis')),
  ('50000000-0000-4000-8000-000000000043', '50000000-0000-4000-8000-000000000032',
   '50000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Lenke på R2 i 500.', '50000000-0000-4000-8000-000000000081'),
  ('50000000-0000-4000-8000-000000000044', '50000000-0000-4000-8000-000000000033',
   '50000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Lenke på R3 i 500.', (select id from fixture where name = 'synthesis'));

-- Kontrollradene, som de ville sett ut fra en reviewer som gikk til
-- originalkilden for begge lenkene på R1.
create temporary table cit (label text primary key, payload jsonb) on commit drop;
insert into cit values
  ('r31-ok', jsonb_build_array(
     jsonb_build_object(
       'claim_evidence_link_id', '50000000-0000-4000-8000-000000000041',
       'source_access', 'original_source',
       'source_version_id', '50000000-0000-4000-8000-000000000021',
       'checked_content_hash', 'sha256:' || repeat('a', 64),
       'relationship_supported', 'ok'),
     jsonb_build_object(
       'claim_evidence_link_id', '50000000-0000-4000-8000-000000000042',
       'source_access', 'original_source',
       'source_version_id', '50000000-0000-4000-8000-000000000022',
       'checked_content_hash', 'sha256:' || repeat('b', 64),
       'relationship_supported', 'ok'))),
  ('r31-blandet', jsonb_build_array(
     jsonb_build_object(
       'claim_evidence_link_id', '50000000-0000-4000-8000-000000000041',
       'source_access', 'original_source',
       'source_version_id', '50000000-0000-4000-8000-000000000021',
       'checked_content_hash', 'sha256:' || repeat('a', 64),
       'relationship_supported', 'ok'),
     jsonb_build_object(
       'claim_evidence_link_id', '50000000-0000-4000-8000-000000000042',
       'source_access', 'derived_summary',
       'relationship_supported', 'not_assessable',
       'finding', 'Bare et sammendrag var tilgjengelig for denne lenken.'))),
  -- Begge lenkene kontrollert mot originalkilden, men den ene lot seg ikke
  -- bedømme. Kildetilgangen er dermed sterk nok for en bekreftelse, slik at det
  -- er dekningskontrollen og ikke source_access-regelen som feller forsøket.
  ('r31-uavklart', jsonb_build_array(
     jsonb_build_object(
       'claim_evidence_link_id', '50000000-0000-4000-8000-000000000041',
       'source_access', 'original_source',
       'source_version_id', '50000000-0000-4000-8000-000000000021',
       'checked_content_hash', 'sha256:' || repeat('a', 64),
       'relationship_supported', 'ok'),
     jsonb_build_object(
       'claim_evidence_link_id', '50000000-0000-4000-8000-000000000042',
       'source_access', 'original_source',
       'source_version_id', '50000000-0000-4000-8000-000000000022',
       'checked_content_hash', 'sha256:' || repeat('b', 64),
       'relationship_supported', 'not_assessable',
       'finding', 'Relasjonstypen lot seg ikke bedømme mot kilden.'))),
  ('r31-halv', jsonb_build_array(
     jsonb_build_object(
       'claim_evidence_link_id', '50000000-0000-4000-8000-000000000041',
       'source_access', 'original_source',
       'source_version_id', '50000000-0000-4000-8000-000000000021',
       'checked_content_hash', 'sha256:' || repeat('a', 64),
       'relationship_supported', 'ok'))),
  ('r32', jsonb_build_array(
     jsonb_build_object(
       'claim_evidence_link_id', '50000000-0000-4000-8000-000000000043',
       'source_access', 'original_source',
       'source_version_id', '50000000-0000-4000-8000-000000000021',
       'checked_content_hash', 'sha256:' || repeat('a', 64),
       'relationship_supported', 'ok'))),
  ('r33', jsonb_build_array(
     jsonb_build_object(
       'claim_evidence_link_id', '50000000-0000-4000-8000-000000000044',
       'source_access', 'original_source',
       'source_version_id', '50000000-0000-4000-8000-000000000021',
       'checked_content_hash', 'sha256:' || repeat('a', 64),
       'relationship_supported', 'ok')));
grant select on cit to authenticated;

create temporary table digest (label text primary key, value text) on commit drop;
insert into digest values
  ('r31', knowledge.claim_evidence_set_digest('50000000-0000-4000-8000-000000000031')),
  ('r32', knowledge.claim_evidence_set_digest('50000000-0000-4000-8000-000000000032')),
  ('r33', knowledge.claim_evidence_set_digest('50000000-0000-4000-8000-000000000033'));
grant select on digest to authenticated;

-- ===========================================================================
-- Del 3 — Hver autorisasjonsgren, prøvd med den faktiske funksjonen
-- ===========================================================================
-- Kallet er det samme i hver gren; bare hvem som gjør det er forskjellig.
-- Funksjonen bygger bare setningen — hvem kalleren er, settes eksplisitt på
-- kallstedet, slik at det står synlig hvilken bruker hver assertion gjelder.
create function pg_temp.registration_sql(p_revision uuid, p_digest text, p_citations jsonb)
  returns text language sql as $$
  select 'select api.register_human_claim_verification('
    || quote_literal(p_revision) || '::uuid, '
    || quote_literal(p_digest) || ', '
    || $q$'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable', $q$
    || quote_literal(p_citations::text) || '::jsonb, '
    || $q$'Prøve i 500.', 'Prøve i 500: ikke alle punkter lot seg bedømme.')$q$;
$$;

-- A — ingen aktørrad
select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql(
    '50000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'),
    (select payload from cit where label = 'r31-blandet')),
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en kaller uten aktørrad kan ikke registrere en faglig vurdering i sitt eget navn'
);
reset role;

-- B — aktør, ingen rolletildeling
select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-0000000000b0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql(
    '50000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'),
    (select payload from cit where label = 'r31-blandet')),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'en aktør uten noen rolletildeling avvises med rollefeilen, ikke aktørfeilen'
);
reset role;

-- C — tilbaketrukket aktør med gyldig reviewer-tildeling
select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-0000000000c0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql(
    '50000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'),
    (select payload from cit where label = 'r31-blandet')),
  '42501', 'Aktøren er trukket tilbake og kan ikke registrere en faglig vurdering.',
  'en tilbaketrukket aktør avvises, selv med en ellers gyldig reviewer-tildeling'
);
reset role;

-- D — editor, ikke reviewer
select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-0000000000d0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql(
    '50000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'),
    (select payload from cit where label = 'r31-blandet')),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'editor-rollen gir ikke faglig godkjenningsrett: å registrere innhold og å gå god for det er forskjellige handlinger'
);
reset role;

-- E — reviewer avgrenset til et annet innholdsområde
select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-0000000000e0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql(
    '50000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'),
    (select payload from cit where label = 'r31-blandet')),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'en avgrenset reviewer-tildeling gjelder ikke utenfor sitt eget innholdsområde'
);
reset role;

-- G — reviewer-tildeling som er avsluttet
select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-000000000090"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql(
    '50000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'),
    (select payload from cit where label = 'r31-blandet')),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'en avsluttet reviewer-tildeling gir ingen rett: tilbakekallingen virker umiddelbart'
);
reset role;

-- Uinnlogget: ingen auth.uid(), altså ingen aktør.
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select throws_ok(
  $$
    select api.register_human_claim_verification(
      '50000000-0000-4000-8000-000000000031'::uuid, 'sha256-v1:' || repeat('0', 64),
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      '[]'::jsonb, 'Prøve i 500.', 'Skal aldri nå fram.')
  $$,
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en uinnlogget kaller har ingen aktør og kommer ikke inn'
);
reset role;

-- ===========================================================================
-- Del 4 — Den lykkede stien (kaller F, avgrenset til nøyaktig dette temaet)
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-0000000000f1"}', true);
set local role authenticated;
select lives_ok(
  pg_temp.registration_sql(
    '50000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'),
    (select payload from cit where label = 'r31-blandet')),
  'en reviewer med avgrenset tildeling som dekker temaet kan registrere kontrollen'
);
reset role;

select is(
  (select cv.verifier_actor_id from workflow.claim_verifications cv
   where cv.claim_revision_id = '50000000-0000-4000-8000-000000000031'),
  '50000000-0000-4000-8000-0000000000f2'::uuid,
  'kontrollen er attribuert til kallerens egen aktør, ikke til en annen'
);
select is(
  (select cv.agent_run_id from workflow.claim_verifications cv
   where cv.claim_revision_id = '50000000-0000-4000-8000-000000000031'),
  null::uuid,
  'en menneskelig vurdering har ingen agentkjøring; kolonnen fra 005j er bygget for nettopp det'
);
select is(
  (select cv.verified_evidence_set_digest from workflow.claim_verifications cv
   where cv.claim_revision_id = '50000000-0000-4000-8000-000000000031'),
  (select value from digest where label = 'r31'),
  'avtrykket av evidenssettet eies av databasen og er settet slik det faktisk var'
);
select is(
  (select cv.source_access::text from workflow.claim_verifications cv
   where cv.claim_revision_id = '50000000-0000-4000-8000-000000000031'),
  'derived_summary',
  'den samlede kildetilgangen er den svakeste av lenkenes, ikke den sterkeste'
);
select is(
  (select count(*)::integer from workflow.claim_verification_citations c
   join workflow.claim_verifications cv on cv.id = c.claim_verification_id
   where cv.claim_revision_id = '50000000-0000-4000-8000-000000000031'),
  2,
  'kontrollen registrerte én kontrollrad per evidenslenke på revisjonen'
);
select is(
  (select count(*)::integer from audit.events e
   where e.operation = 'review_decision_registered'),
  0,
  'en claim-verifikasjon er ikke en reviewbeslutning og skriver ingen slik auditrad'
);
select is(
  (select e.actor_id from audit.events e
   join workflow.claim_verifications cv on cv.id = e.object_id
   where cv.claim_revision_id = '50000000-0000-4000-8000-000000000031'
     and e.operation = 'claim_verification_registered'),
  '50000000-0000-4000-8000-0000000000f2'::uuid,
  'auditraden er attribuert til den menneskelige verifikatoren'
);
select lives_ok(
  $$set constraints all immediate$$,
  'den utsatte dekningskontrollen godtar kontrollen når den tvinges fram'
);
set constraints all deferred;

-- ===========================================================================
-- Del 5 — verified krever at alt holder, også for et menneske
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_ok(
  $$
    select api.register_human_claim_verification(
      '50000000-0000-4000-8000-000000000033'::uuid,
      (select value from digest where label = 'r33'),
      'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'not_assessable',
      (select payload from cit where label = 'r33'),
      'Prøve i 500: bekreftelse med ett ubedømt punkt.')
  $$,
  '23514', null,
  'et menneske kan ikke bekrefte med et ubedømt kontrollpunkt: not_assessable er ikke ok'
);
select throws_ok(
  $$
    select api.register_human_claim_verification(
      '50000000-0000-4000-8000-000000000031'::uuid,
      (select value from digest where label = 'r31'),
      'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
      (select payload from cit where label = 'r31-uavklart'),
      'Prøve i 500: bekreftelse med en uavklart lenke under seg.')
  $$,
  '23001', null,
  'en bekreftelse kan ikke ha en uavklart evidenslenke under seg'
);
select throws_ok(
  $$
    select api.register_human_claim_verification(
      '50000000-0000-4000-8000-000000000031'::uuid,
      (select value from digest where label = 'r31'),
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      (select payload from cit where label = 'r31-halv'),
      'Prøve i 500: kontrollen dekker bare halve evidenssettet.',
      'Skal aldri nå fram.')
  $$,
  '23001', null,
  'en kontroll som hopper over en evidenslenke avvises, også når et menneske gjør den'
);
select lives_ok(
  $$
    select api.register_human_claim_verification(
      '50000000-0000-4000-8000-000000000033'::uuid,
      (select value from digest where label = 'r33'),
      'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
      (select payload from cit where label = 'r33'),
      'Prøve i 500: alle sju punktene holder, og lenken er kontrollert mot originalkilden.')
  $$,
  'et menneske kan konkludere med verified når alle sju punktene og alle lenkene holder'
);
reset role;

select is(
  (select cv.outcome::text from workflow.claim_verifications cv
   where cv.claim_revision_id = '50000000-0000-4000-8000-000000000033'),
  'verified',
  'bekreftelsen er registrert som verified'
);

-- ===========================================================================
-- Del 6 — Selvverifikasjon, med mandatet i orden
--
-- Kaller H har uavgrenset reviewer-rolle og kan kontrollere andres påstander.
-- R2 er formulert av H sin egen aktør, og da er det ikke mandatet som feller
-- forsøket, men regelen om at generering og verifikasjon er atskilte
-- operasjoner (ANTIDEP_CONSTITUTION.md §10).
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_ok(
  $$
    select api.register_human_claim_verification(
      '50000000-0000-4000-8000-000000000032'::uuid,
      (select value from digest where label = 'r32'),
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      (select payload from cit where label = 'r32'),
      'Prøve i 500: reviewer kontrollerer sin egen påstand.',
      'Skal aldri nå fram.')
  $$,
  '23514', null,
  'en reviewer kan ikke kontrollere en påstand hen selv har formulert, selv med mandatet i orden'
);
reset role;

-- ===========================================================================
-- Del 7 — Vurderingen gjelder det evidenssettet revieweren faktisk så
-- ===========================================================================
insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('50000000-0000-4000-8000-000000000045', '50000000-0000-4000-8000-000000000033',
        '50000000-0000-4000-8000-000000000013', 'contradicts', 'direct',
        'Lenke som kom til mens vurderingen pågikk, i 500.',
        (select id from fixture where name = 'synthesis'));

select isnt(
  knowledge.claim_evidence_set_digest('50000000-0000-4000-8000-000000000033'),
  (select value from digest where label = 'r33'),
  'en ny evidenslenke gir revisjonen et nytt avtrykk'
);

select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_ok(
  $$
    select api.register_human_claim_verification(
      '50000000-0000-4000-8000-000000000033'::uuid,
      (select value from digest where label = 'r33'),
      'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
      (select payload from cit where label = 'r33'),
      'Prøve i 500: vurdering av et grunnlag som har endret seg under vurderingen.')
  $$,
  '23001', 'Evidensgrunnlaget er endret etter at du hentet det fram.',
  'en lenke som kommer til mens vurderingen pågår, avviser registreringen framfor å bli stilltiende dekket'
);
reset role;

-- Kontrollen er ikke bare en sammenligning: den tar FOR UPDATE på revisjonen
-- *før* den sammenligner, og holder låsen ut transaksjonen (migrasjon 006f).
--
-- Uten den låsen er kontrollen bare et øyeblikksbilde. Avtrykket som faktisk
-- lagres, beregnes senere av triggeren på raden, og en lenke som commitet i
-- vinduet mellom de to ville blitt en del av det lagrede avtrykket — hvorpå både
-- G9b og G13 ville passert på et evidenssett revieweren aldri så.
--
-- xmax på raden settes når noen tar radlåsen. Revisjonen er opprettet av denne
-- transaksjonen og finnes ikke for noen annen forbindelse, så en xmax som går
-- fra 0 til noe annet kan bare komme fra kontrollens egen FOR UPDATE.
select is(
  (select r.xmax::text from knowledge.claim_revisions r
   where r.id = '50000000-0000-4000-8000-000000000035'),
  '0',
  'revisjonen er ulåst før kontrollen kalles'
);
select lives_ok(
  $$
    select workflow.assert_evidence_set_unchanged(
      '50000000-0000-4000-8000-000000000035',
      knowledge.claim_evidence_set_digest('50000000-0000-4000-8000-000000000035'))
  $$,
  'kontrollen passerer når evidenssettet er det kalleren så'
);
select isnt(
  (select r.xmax::text from knowledge.claim_revisions r
   where r.id = '50000000-0000-4000-8000-000000000035'),
  '0',
  'og transaksjonen holder nå radlåsen på revisjonen: kontrollen og registreringen er én atomisk grense'
);

-- Låsen betyr noe bare fordi motparten tar den samme. Hver innsetting i
-- knowledge.claim_evidence_links går gjennom to BEFORE-triggere som begge låser
-- revisjonsraden først. Forsvinner det, forsvinner serialiseringen med det.
select is_empty(
  $$
    select f.function_name
    from (values ('knowledge.reject_evidence_link_after_assessment()'),
                 ('knowledge.reject_evidence_link_after_publication()'))
           as f(function_name)
    where position('for update' in
           (select p.prosrc from pg_proc p where p.oid = f.function_name::regprocedure)) = 0
  $$,
  'en ny evidenslenke låser den samme revisjonsraden, så de to veiene serialiseres mot hverandre'
);

-- ===========================================================================
-- Del 8 — Append-only og direkte omgåelse
-- ===========================================================================
select throws_ok(
  $$
    update workflow.claim_verifications set outcome = 'verified'
    where claim_revision_id = '50000000-0000-4000-8000-000000000031'
  $$,
  '23001', null,
  'en registrert kontroll kan ikke endres i etterkant'
);
select throws_ok(
  $$
    delete from workflow.claim_verifications
    where claim_revision_id = '50000000-0000-4000-8000-000000000031'
  $$,
  '23001', null,
  'en registrert kontroll kan ikke slettes'
);

select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_ok(
  $$
    insert into workflow.claim_verifications
      (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id,
       outcome, source_access, source_support, population_match, comparator_match,
       timeframe_match, direction_and_magnitude, qualifiers_complete,
       contradictory_evidence_represented, rationale, verified_at)
    values ('50000000-0000-4000-8000-000000000031',
            '00000000-0000-4000-8000-0000000000ff',
            '50000000-0000-4000-8000-000000000081',
            'verified', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
            'Forsøk på å skrive rett i tabellen.', now())
  $$,
  '42501', null,
  'en innlogget reviewer kan ikke skrive rett i workflow.claim_verifications utenom skriveveien'
);
reset role;

-- ===========================================================================
-- Del 9 — Mutasjonstest: skriveveiens kontroll er ikke den eneste sperren
--
-- Autorisasjonen i api.register_human_claim_verification() gir en lesbar
-- avvisning, men den er ikke det som gjør regelen sann. Her muteres den bort —
-- workflow.assert_reviewer_authorized(uuid) byttes ut med en variant som
-- returnerer kallerens aktør uten å kontrollere noe — og kallet skal fortsatt
-- avvises, av radens egen mandatkontroll
-- (workflow.enforce_claim_verifier_mandate).
--
-- Endringen rulles tilbake sammen med transaksjonen.
-- ===========================================================================
create or replace function workflow.assert_reviewer_authorized(p_scope_concept_id uuid default null)
  returns uuid
  language sql
  set search_path = ''
as $$
  select a.id from provenance.actors a where a.auth_user_id = auth.uid();
$$;

select set_config('request.jwt.claims',
                  '{"sub":"50000000-0000-4000-8000-0000000000b0"}', true);
set local role authenticated;
select throws_ok(
  $$
    select api.register_human_claim_verification(
      '50000000-0000-4000-8000-000000000031'::uuid,
      (select value from digest where label = 'r31'),
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      (select payload from cit where label = 'r31-blandet'),
      'Prøve i 500: mutert autorisasjon.', 'Skal aldri nå fram.')
  $$,
  '42501', 'Verifikatoraktøren hadde ikke mandat til å kontrollere denne påstanden mot grunnlaget.',
  'raden har sin egen mandatkontroll: en aktør uten reviewer-rolle slipper ikke gjennom selv om skriveveiens kontroll er mutert bort'
);
reset role;

-- ===========================================================================
-- Del 10 — Mutasjonstest: uten låsen er kontrollen bare et øyeblikksbilde
--
-- workflow.assert_evidence_set_unchanged(uuid, text) byttes ut med kroppen den
-- hadde før migrasjon 006f: samme sammenligning, ingen lås. Raden skal da stå
-- ulåst etter kallet — og det er nøyaktig vinduet en samtidig evidenslenke kunne
-- commite i, slik at avtrykket som lagres beskriver et sett revieweren aldri så.
--
-- Prøven på selve kappløpet krever to forbindelser og ligger i
-- scripts/db-lock-test.sh; denne assertionen fanger at låsen er der.
-- ===========================================================================
create or replace function workflow.assert_evidence_set_unchanged(
  p_claim_revision_id uuid,
  p_seen_evidence_set_digest text
)
  returns void
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if knowledge.claim_evidence_set_digest(p_claim_revision_id)
     is distinct from p_seen_evidence_set_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Mutert kontroll uten lås.';
  end if;
end;
$$;

select lives_ok(
  $$
    select workflow.assert_evidence_set_unchanged(
      '50000000-0000-4000-8000-000000000036',
      knowledge.claim_evidence_set_digest('50000000-0000-4000-8000-000000000036'))
  $$,
  'den muterte kontrollen sammenligner fortsatt, og passerer'
);
select is(
  (select r.xmax::text from knowledge.claim_revisions r
   where r.id = '50000000-0000-4000-8000-000000000036'),
  '0',
  'men den holder ingen lås: uten FOR UPDATE er kontrollen bare et øyeblikksbilde, og det er kappløpet migrasjon 006f lukker'
);

select finish();
rollback;
