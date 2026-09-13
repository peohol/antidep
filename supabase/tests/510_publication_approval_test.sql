-- Migrasjon 006d — den kontrollerte skriveveien for en publiseringsgodkjenning.
--
-- workflow.review_decisions har fantes siden migrasjon 005 og publiseringsgatens
-- G11, G12 og G13 har lest den siden migrasjon 006, men ingen har kunnet skrive
-- raden. Filen dekker kontrakten (hva som faktisk er eksponert), autorisasjonen i
-- hver av sine grener, konsekvensen (raden og auditraden), vokabularet, og de
-- invariantene tabellen har hatt hele tiden og som skriveveien arver: reviewer må
-- være et menneske, kan ikke være den som formulerte revisjonen, må ha hatt
-- gyldig reviewer-rolle på beslutningstidspunktet, og raden er append-only.
--
-- Selve publiseringsgaten prøves i 250, 490 og 530; her prøves skriveveien.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23514 = check_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(46);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'register_publication_approval', 'api.register_publication_approval() finnes'
);
select has_function(
  'audit', 'record_review_decision_event', 'audit.record_review_decision_event() finnes'
);
select has_trigger(
  'workflow', 'review_decisions', 'review_decisions_record_creation_audit_event',
  'enhver registrert reviewbeslutning auditeres'
);
select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.register_publication_approval(uuid,text,text,text)'::regprocedure),
  'api.register_publication_approval() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
select ok(
  not (select p.prosecdef from pg_proc p
       where p.oid = 'audit.record_review_decision_event()'::regprocedure),
  'audit.record_review_decision_event() er ikke SECURITY DEFINER: auditskriveren skal aldri være mer privilegert enn operasjonen'
);
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.register_publication_approval(uuid,text,text,text)'::regprocedure,
      'execute'
    )
  $$,
  'api.register_publication_approval() er kjørbar bare for authenticated'
);
-- Klientrollene har et tabellvidt SELECT fra migrasjon 006a, avgrenset av
-- policyen review_decisions_extraction_withdrawal_read til beslutninger om
-- ekstraksjoner på publiserte påstander. Det som skal være umulig, er å SKRIVE.
select is_empty(
  $$
    select r.role_name, p.priv
    from (values ('anon'), ('authenticated'), ('public')) as r(role_name),
         (values ('insert'), ('update'), ('delete')) as p(priv)
    where has_table_privilege(r.role_name, 'workflow.review_decisions', p.priv)
  $$,
  'klientrollene har ingen skriverettighet på workflow.review_decisions'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- Samme åtte autorisasjonsgrener som i 500, og tre påstandsrevisjoner:
--
--   R1  formulert av agent:claim-synthesis. Den lykkede stien.
--   R2  formulert av reviewer H sin egen aktør. Selvgodkjenning.
--   R3  formulert av agent:claim-synthesis, uten evidensvurdering, slik at
--       evidenssettet kan utvides etter en godkjenning.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';

insert into catalog.clinical_concepts (id, canonical_label, concept_type)
values ('51000000-0000-4000-8000-0000000000f0', 'søvnkvalitet for 510', 'outcome');

insert into auth.users (id, instance_id, aud, role, email)
select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u.email
from (values
  ('51000000-0000-4000-8000-0000000000a0'::uuid, 'a510@example.test'),
  ('51000000-0000-4000-8000-0000000000b0'::uuid, 'b510@example.test'),
  ('51000000-0000-4000-8000-0000000000c0'::uuid, 'c510@example.test'),
  ('51000000-0000-4000-8000-0000000000d0'::uuid, 'd510@example.test'),
  ('51000000-0000-4000-8000-0000000000e0'::uuid, 'e510@example.test'),
  ('51000000-0000-4000-8000-0000000000f1'::uuid, 'f510@example.test'),
  ('51000000-0000-4000-8000-000000000090'::uuid, 'g510@example.test'),
  ('51000000-0000-4000-8000-000000000080'::uuid, 'h510@example.test')
) as u(id, email);

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id, retired_at, retirement_note)
values
  ('51000000-0000-4000-8000-0000000000b1', 'human:b-510', 'human', 'Kaller B 510',
   'Aktør uten rolle, for 510.', '51000000-0000-4000-8000-0000000000b0', null, null),
  ('51000000-0000-4000-8000-0000000000c1', 'human:c-510', 'human', 'Kaller C 510',
   'Tilbaketrukket aktør, for 510.', '51000000-0000-4000-8000-0000000000c0',
   now() - interval '1 day', 'Tilbaketrukket for testene i 510.'),
  ('51000000-0000-4000-8000-0000000000d1', 'human:d-510', 'human', 'Kaller D 510',
   'Editor uten reviewer-rolle, for 510.', '51000000-0000-4000-8000-0000000000d0', null, null),
  ('51000000-0000-4000-8000-0000000000e1', 'human:e-510', 'human', 'Kaller E 510',
   'Avgrenset reviewer for et annet tema, for 510.', '51000000-0000-4000-8000-0000000000e0', null, null),
  ('51000000-0000-4000-8000-0000000000f2', 'human:f-510', 'human', 'Kaller F 510',
   'Avgrenset reviewer for riktig tema, for 510.', '51000000-0000-4000-8000-0000000000f1', null, null),
  ('51000000-0000-4000-8000-000000000091', 'human:g-510', 'human', 'Kaller G 510',
   'Avsluttet reviewer-tildeling, for 510.', '51000000-0000-4000-8000-000000000090', null, null),
  ('51000000-0000-4000-8000-000000000081', 'human:h-510', 'human', 'Kaller H 510',
   'Uavgrenset reviewer, for 510.', '51000000-0000-4000-8000-000000000080', null, null);

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to,
   granted_by_actor_id, grant_reason, ended_by_actor_id, end_reason)
values
  ('51000000-0000-4000-8000-0000000000c0', 'reviewer', null,
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller C i 510.', null, null),
  ('51000000-0000-4000-8000-0000000000d0', 'editor', null,
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller D i 510.', null, null),
  ('51000000-0000-4000-8000-0000000000e0', 'reviewer', '51000000-0000-4000-8000-0000000000f0',
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller E i 510.', null, null),
  ('51000000-0000-4000-8000-0000000000f1', 'reviewer', (select id from fixture where name = 'weight'),
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller F i 510.', null, null),
  ('51000000-0000-4000-8000-000000000090', 'reviewer', null,
   now() - interval '2 years', now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Tildeling for kaller G i 510.',
   (select id from fixture where name = 'editor'), 'Avsluttet for testene i 510.'),
  ('51000000-0000-4000-8000-000000000080', 'reviewer', null,
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller H i 510.', null, null);

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('51000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 510',
        'Testforfatter 510', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
values ('51000000-0000-4000-8000-000000000021', '51000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/510', 'sha256:' || repeat('a', 64),
        (select id from fixture where name = 'extractor'));

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values
  ('51000000-0000-4000-8000-000000000011', '51000000-0000-4000-8000-000000000001',
   '51000000-0000-4000-8000-000000000021',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 510.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Første funn, for 510.',
   'not_reported', 'increase', 'not_reported', 'not_reported',
   'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor')),
  ('51000000-0000-4000-8000-000000000012', '51000000-0000-4000-8000-000000000001',
   '51000000-0000-4000-8000-000000000021',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 510.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Andre funn, for 510.',
   'not_reported', 'increase', 'not_reported', 'not_reported',
   'Avsnitt 2', 'ai_assisted', (select id from fixture where name = 'extractor'));

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
         p_statement, 'Gjelder bare som testdata i 510.', 'none', 'increase',
         'Testusikkerhet.', c.created_by_actor_id
  from c;
end;
$$;

select pg_temp.make_revision('51000000-0000-4000-8000-000000000031',
  (select id from fixture where name = 'synthesis'), 'Testpåstand R1 for 510.');
select pg_temp.make_revision('51000000-0000-4000-8000-000000000032',
  '51000000-0000-4000-8000-000000000081', 'Testpåstand R2 for 510, formulert av reviewer H.');
select pg_temp.make_revision('51000000-0000-4000-8000-000000000033',
  (select id from fixture where name = 'synthesis'), 'Testpåstand R3 for 510.');

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values
  ('51000000-0000-4000-8000-000000000041', '51000000-0000-4000-8000-000000000031',
   '51000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Lenke på R1 i 510.', (select id from fixture where name = 'synthesis')),
  ('51000000-0000-4000-8000-000000000042', '51000000-0000-4000-8000-000000000032',
   '51000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Lenke på R2 i 510.', '51000000-0000-4000-8000-000000000081'),
  ('51000000-0000-4000-8000-000000000043', '51000000-0000-4000-8000-000000000033',
   '51000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Lenke på R3 i 510.', (select id from fixture where name = 'synthesis'));

-- R4 har sitt eget evidensfunn, slik at Del 10 kan bygge kontrollene opp fra
-- ingenting uten å røre grunnlaget de andre revisjonene hviler på.
insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values
  ('51000000-0000-4000-8000-000000000013', '51000000-0000-4000-8000-000000000001',
   '51000000-0000-4000-8000-000000000021',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 510.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Tredje funn, for 510.',
   'not_reported', 'increase', 'not_reported', 'not_reported',
   'Avsnitt 3', 'ai_assisted', (select id from fixture where name = 'extractor'));

select pg_temp.make_revision('51000000-0000-4000-8000-000000000034',
  (select id from fixture where name = 'synthesis'), 'Testpåstand R4 for 510.');

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values
  ('51000000-0000-4000-8000-000000000045', '51000000-0000-4000-8000-000000000034',
   '51000000-0000-4000-8000-000000000013', 'supports', 'direct',
   'Lenke på R4 i 510.', (select id from fixture where name = 'synthesis'));

create temporary table digest (label text primary key, value text) on commit drop;
insert into digest values
  ('r31', knowledge.claim_evidence_set_digest('51000000-0000-4000-8000-000000000031')),
  ('r32', knowledge.claim_evidence_set_digest('51000000-0000-4000-8000-000000000032')),
  ('r33', knowledge.claim_evidence_set_digest('51000000-0000-4000-8000-000000000033')),
  ('r34', knowledge.claim_evidence_set_digest('51000000-0000-4000-8000-000000000034'));
grant select on digest to authenticated;

create function pg_temp.approval_sql(p_revision uuid, p_digest text, p_decision text)
  returns text language sql as $$
  select 'select api.register_publication_approval('
    || quote_literal(p_revision) || '::uuid, '
    || quote_literal(p_digest) || ', '
    || quote_literal(p_decision) || ', '
    || $q$'Prøve i 510: faglig begrunnelse.')$q$;
$$;

create function pg_temp.citation(p_link uuid) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'claim_evidence_link_id', p_link,
    'source_access', 'original_source',
    'source_version_id', '51000000-0000-4000-8000-000000000021',
    'checked_content_hash', 'sha256:' || repeat('a', 64),
    'relationship_supported', 'ok'));
$$;
grant execute on function pg_temp.citation(uuid) to authenticated;

-- ===========================================================================
-- Del 2b — Grunnlaget bak R1 og R2 er kontrollert
--
-- Fra migrasjon 006e kan en godkjenning ikke registreres på et ukontrollert
-- utkast: `approved` krever publiseringsgatens G1 til G10. Fikstruen må derfor
-- bygge livsløpet i den rekkefølgen det faktisk skjer — kildekontroll, deretter
-- kontroll av påstanden mot grunnlaget — før noen kan gå god for publisering.
-- Det er ikke en omgåelse av regelen, men prøven på den: den lykkede stien i
-- Del 4 og selvgodkjenningen i Del 6 skal treffe nøyaktig sin egen sperre, og
-- ikke stoppe på en manglende kontroll lenger nede.
--
-- R3 og R4 står med vilje ukontrollerte.
-- ===========================================================================
-- Den kildeomfattende halvdelen av et globalt fravær (`not_reported`,
-- `not_measured`) kan bare føres opp av en maskinell kontroll med sin egen
-- agentkjøring (migrasjon 005ae,
-- evidence_verifications_source_wide_absence_check): ingen menneskelig
-- kontrolløkt søker gjennom hele representasjonen, og blir aldri spurt om det.
-- En fikstur som skal ha full dekning, trenger derfor begge leddene.
create function pg_temp.cover_source_wide_absence(p_evidence_item_id uuid)
  returns void
  language plpgsql
as $fn$
declare
  v_run_id uuid;
  v_actor_id uuid;
begin
  -- Fører ikke raden en slik påstand, kreves feltet ikke, og en rad som førte
  -- det opp ville påstått en kontroll av ingenting.
  if 'source_wide_absence' <> all (workflow.required_check_fields(p_evidence_item_id)) then
    return;
  end if;

  insert into provenance.agent_runs
    (agent_identity_id, actor_id, agent_role, provider, model, model_version,
     prompt_template_version, pipeline_version, input_manifest)
  select ai.id, ai.actor_id, 'extraction_verification', 'prøve', 'prøve', '1',
         'extraction-verification/1', 'antidep-evidence/1', '{"mode": "fikstur"}'::jsonb
  from provenance.agent_identities ai
  where ai.identity_key = 'agent-identity:extraction-verification-01'
  returning id, actor_id into v_run_id, v_actor_id;

  insert into workflow.evidence_verifications
    (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
     source_access, checked_fields, rationale, verified_at, agent_run_id)
  select e.id, e.created_by_actor_id, v_actor_id, 'verified', 'verifiable_representation',
         array['source_wide_absence']::workflow.evidence_check_field[],
         'Fikstur: et søk gjennom hele den kontrollerte representasjonen fant ingen verdi '
         || 'for de feltene raden fører som fraværende i kilden.',
         now() - interval '30 days', v_run_id
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;
end;
$fn$;

-- Den maskinelle halvdelen først, slik at den menneskelige kontrollen blir
-- den gjeldende (registreringsrekkefølgen avgjør, migrasjon 005å).
select pg_temp.cover_source_wide_absence(e.id)
from knowledge.evidence_items e where e.id = '51000000-0000-4000-8000-000000000011';

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from provenance.actors where actor_key = 'agent:extraction-verification'),
       'verified', 'original_source',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Prøve i 510: fullstendig kontrollert ekstraksjon.', now()
from knowledge.evidence_items e where e.id = '51000000-0000-4000-8000-000000000011';

-- Vurderingen attribueres til evidensvurderingsaktøren, ikke til den som
-- formulerte revisjonen: publiseringsgatens G10b krever at den som gjorde
-- vurderingen, hadde mandat til det (migrasjon 005ap). Ansvarsgrensen mellom
-- påstandsdannelse og evidensvurdering er en teknisk grense
-- (EVIDENCE_PIPELINE.md §61).
insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select r.id, 'evidence_synthesis', 'grade', 'low',
       'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
       'Prøve i 510: lav sikkerhet er en vurdering, ikke et fravær av evidens.',
       now(), (select id from provenance.actors where actor_key = 'agent:evidence-assessment')
from (values ('51000000-0000-4000-8000-000000000031'::uuid),
             ('51000000-0000-4000-8000-000000000032'::uuid),
             ('51000000-0000-4000-8000-000000000034'::uuid)) as r(id);

-- Kontrollen av R1 gjøres av reviewer H, som ikke har formulert den. Kontrollen
-- av R2 gjøres av reviewer F, siden R2 er formulert av H selv.
select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.register_human_claim_verification(
      '51000000-0000-4000-8000-000000000031'::uuid,
      (select value from digest where label = 'r31'),
      'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
      pg_temp.citation('51000000-0000-4000-8000-000000000041'),
      'Prøve i 510: påstanden er kontrollert mot grunnlaget.')
  $$,
  'R1 er kontrollert mot grunnlaget før noen tar stilling til publisering'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-0000000000f1"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.register_human_claim_verification(
      '51000000-0000-4000-8000-000000000032'::uuid,
      (select value from digest where label = 'r32'),
      'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
      pg_temp.citation('51000000-0000-4000-8000-000000000042'),
      'Prøve i 510: påstanden er kontrollert mot grunnlaget.')
  $$,
  'R2 er kontrollert mot grunnlaget av en annen enn den som formulerte den'
);
reset role;

-- ===========================================================================
-- Del 3 — Hver autorisasjonsgren
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'), 'approved'),
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en kaller uten aktørrad kan ikke godkjenne noe i sitt eget navn'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-0000000000b0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'), 'approved'),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'en aktør uten noen rolletildeling kan ikke godkjenne'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-0000000000c0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'), 'approved'),
  '42501', 'Aktøren er trukket tilbake og kan ikke registrere en faglig vurdering.',
  'en tilbaketrukket aktør kan ikke godkjenne, selv med gyldig reviewer-tildeling'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-0000000000d0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'), 'approved'),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'editor-rollen gir ikke publiseringsgodkjenningsrett'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-0000000000e0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'), 'approved'),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'en avgrenset reviewer-tildeling godkjenner ikke utenfor sitt eget innholdsområde'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-000000000090"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'), 'approved'),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'en avsluttet reviewer-tildeling gir ingen godkjenningsrett'
);
reset role;

select set_config('request.jwt.claims', '', true);
set local role authenticated;
select throws_ok(
  $$
    select api.register_publication_approval(
      '51000000-0000-4000-8000-000000000031'::uuid, 'sha256-v1:' || repeat('0', 64),
      'approved', 'Skal aldri nå fram.')
  $$,
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en uinnlogget kaller har ingen aktør og kan ikke godkjenne'
);
reset role;

-- ===========================================================================
-- Del 4 — Den lykkede stien (kaller F, avgrenset til nøyaktig dette temaet)
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-0000000000f1"}', true);
set local role authenticated;
select lives_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'), 'approved'),
  'en reviewer med avgrenset tildeling som dekker temaet kan godkjenne revisjonen'
);
reset role;

select is(
  (select rd.reviewer_actor_id from workflow.review_decisions rd
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000031'),
  '51000000-0000-4000-8000-0000000000f2'::uuid,
  'godkjenningen er attribuert til kallerens egen aktør, ikke til en annen'
);
select is(
  (select rd.review_type::text || '/' || rd.object_type::text
   from workflow.review_decisions rd
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000031'),
  'publication_approval/claim_revision',
  'skriveveien registrerer en publiseringsgodkjenning på en påstandsrevisjon, og ikke noe annet'
);
select is(
  (select rd.approved_evidence_set_digest from workflow.review_decisions rd
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000031'),
  (select value from digest where label = 'r31'),
  'avtrykket av det godkjente evidenssettet eies av databasen'
);
select is(
  (select rd.claim_revision_creator_actor_id from workflow.review_decisions rd
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000031'),
  (select id from fixture where name = 'synthesis'),
  'speilet av forfatteren leses fra revisjonen, ikke fra kalleren'
);
select is(
  (select rd.reviewer_actor_type::text from workflow.review_decisions rd
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000031'),
  'human',
  'beslutningen er registrert som en menneskelig beslutning (ANTIDEP_CONSTITUTION.md §12)'
);
select ok(
  (select rd.decided_at <= rd.created_at from workflow.review_decisions rd
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000031'),
  'beslutningen er ikke datert fram i tid'
);
select is(
  (select e.actor_id::text || '|' || e.reason
   from audit.events e
   join workflow.review_decisions rd on rd.id = e.object_id
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000031'
     and e.operation = 'review_decision_registered'),
  '51000000-0000-4000-8000-0000000000f2|Prøve i 510: faglig begrunnelse.',
  'auditraden er attribuert til revieweren og bærer beslutningens egen begrunnelse'
);
select is(
  (select e.object_schema || '.' || e.object_table
   from audit.events e
   join workflow.review_decisions rd on rd.id = e.object_id
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000031'
     and e.operation = 'review_decision_registered'),
  'workflow.review_decisions',
  'auditraden peker på riktig tabell, avledet av operasjonen'
);
select ok(
  (select e.old_revision_or_snapshot is null and e.new_revision_or_snapshot is not null
   from audit.events e
   join workflow.review_decisions rd on rd.id = e.object_id
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000031'
     and e.operation = 'review_decision_registered'),
  'en registrering har bare et etter-snapshot: tabellen er append-only'
);

-- Tabellgrantet fra migrasjon 006a er ikke en vei inn: klientrollene har ikke
-- usage på schemaet workflow i det hele tatt, så et direkte oppslag avvises før
-- RLS i det hele tatt vurderes. Veien til godkjenningen er
-- api.claim_review_workspace(uuid), som autoriserer kalleren først.
select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-0000000000f1"}', true);
set local role authenticated;
select throws_ok(
  $$select id from workflow.review_decisions
    where claim_revision_id = '51000000-0000-4000-8000-000000000031'$$,
  '42501', 'permission denied for schema workflow',
  'godkjenningen er ikke lesbar direkte fra tabellen, heller ikke for den som registrerte den'
);
reset role;

-- ===========================================================================
-- Del 5 — Vokabular
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000033',
    (select value from digest where label = 'r33'), 'godkjent'),
  '22023', $$'godkjent' er ikke en kjent reviewbeslutning.$$,
  'en ukjent beslutning avvises med en setning som sier hva som er galt'
);
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000033',
    (select value from digest where label = 'r33'), 'extraction_withdrawn'),
  '23514', null,
  'en beslutning om en ekstraksjon kan ikke registreres som en publiseringsgodkjenning'
);
select lives_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000033',
    (select value from digest where label = 'r33'), 'changes_requested'),
  'en reviewer kan be om endringer, ikke bare godkjenne eller avslå'
);
reset role;

select is(
  (select rd.decision::text from workflow.review_decisions rd
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000033'),
  'changes_requested',
  'beslutningen er bevart som den ble tatt'
);

-- ===========================================================================
-- Del 6 — Selvgodkjenning
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000032',
    (select value from digest where label = 'r32'), 'approved'),
  '23514', null,
  'en reviewer kan ikke godkjenne en påstand hen selv har formulert (ANTIDEP_CONSTITUTION.md §10, §12)'
);
reset role;

-- ===========================================================================
-- Del 7 — Godkjenningen gjelder det evidenssettet revieweren faktisk så
-- ===========================================================================
insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('51000000-0000-4000-8000-000000000044', '51000000-0000-4000-8000-000000000033',
        '51000000-0000-4000-8000-000000000012', 'contradicts', 'direct',
        'Lenke som kom til etter godkjenningen, i 510.',
        (select id from fixture where name = 'synthesis'));

select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000033',
    (select value from digest where label = 'r33'), 'approved'),
  '23001', 'Evidensgrunnlaget er endret etter at du hentet det fram.',
  'en lenke som kommer til mens vurderingen pågår, avviser godkjenningen framfor å bli stilltiende dekket'
);
reset role;

-- Og det er nøyaktig den forskjellen publiseringsgatens G13 leser på en
-- godkjenning som allerede er registrert.
select isnt(
  (select rd.approved_evidence_set_digest from workflow.review_decisions rd
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000033'),
  knowledge.claim_evidence_set_digest('51000000-0000-4000-8000-000000000033'),
  'en registrert godkjenning bærer avtrykket av det settet den gjaldt, og det er nå utdatert'
);

-- ===========================================================================
-- Del 8 — Append-only og direkte omgåelse
-- ===========================================================================
select throws_ok(
  $$
    update workflow.review_decisions set decision = 'rejected'
    where claim_revision_id = '51000000-0000-4000-8000-000000000031'
  $$,
  '23001', null,
  'en registrert beslutning kan ikke endres i etterkant; en omgjøring er en ny rad'
);
select throws_ok(
  $$
    delete from workflow.review_decisions
    where claim_revision_id = '51000000-0000-4000-8000-000000000031'
  $$,
  '23001', null,
  'en registrert beslutning kan ikke slettes'
);

select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_ok(
  $$
    insert into workflow.review_decisions
      (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
       rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
    values ('51000000-0000-4000-8000-000000000031',
            '00000000-0000-4000-8000-0000000000ff',
            'publication_approval', 'approved', 'Forsøk på å skrive rett i tabellen.',
            '51000000-0000-4000-8000-000000000081', 'human', now())
  $$,
  '42501', null,
  'en innlogget reviewer kan ikke skrive rett i workflow.review_decisions utenom skriveveien'
);
reset role;

-- ===========================================================================
-- Del 9 — En godkjenning kan ikke gis til et ukontrollert utkast
--
-- Migrasjon 006e. Godkjenningen er append-only og bundet bare til hvilke
-- evidenslenker som fantes — ikke til hvilke kontroller som var gjeldende. Uten
-- vilkåret kunne en reviewer godkjent mens G5 eller G9 blokkerte, og den gamle
-- godkjenningen ville blitt stående og båret publiseringen den dagen kontrollene
-- kom. Godkjenningen ville da gjeldt noe annet enn det som ble publisert
-- (ANTIDEP_CONSTITUTION.md §13, KNOWLEDGE_MODEL.md §20).
--
-- R4 bygges opp fra ingenting, i den rekkefølgen livsløpet faktisk har.
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000034',
    (select value from digest where label = 'r34'), 'approved'),
  '23001',
  'Evidensfunn uten registrert ekstraksjonsverifikasjon: 51000000-0000-4000-8000-000000000013.',
  'en godkjenning kan ikke registreres før ekstraksjonen er kildekontrollert'
);
-- ... men et avslag og en anmodning om endringer skal fortsatt kunne
-- registreres, for det er nettopp da de trengs.
select lives_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000034',
    (select value from digest where label = 'r34'), 'changes_requested'),
  'en reviewer kan be om endringer nettopp mens grunnlaget ikke er kontrollert'
);
reset role;

-- Den maskinelle halvdelen først, slik at den menneskelige kontrollen blir
-- den gjeldende (registreringsrekkefølgen avgjør, migrasjon 005å).
select pg_temp.cover_source_wide_absence(e.id)
from knowledge.evidence_items e where e.id = '51000000-0000-4000-8000-000000000013';

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from provenance.actors where actor_key = 'agent:extraction-verification'),
       'verified', 'original_source',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Prøve i 510: fullstendig kontrollert ekstraksjon av R4s funn.', now()
from knowledge.evidence_items e where e.id = '51000000-0000-4000-8000-000000000013';

select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_like(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000034',
    (select value from digest where label = 'r34'), 'approved'),
  '%ingen registrert claim-verifikasjon%',
  'kildekontroll alene er ikke nok: påstanden må også være kontrollert mot grunnlaget'
);
select lives_ok(
  $$
    select api.register_human_claim_verification(
      '51000000-0000-4000-8000-000000000034'::uuid,
      (select value from digest where label = 'r34'),
      'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
      pg_temp.citation('51000000-0000-4000-8000-000000000045'),
      'Prøve i 510: påstanden er kontrollert mot grunnlaget.')
  $$,
  'revieweren registrerer den faglige kontrollen som sitt eget beslutningsobjekt'
);
reset role;

-- now() er transaksjonens starttidspunkt, så anmodningen om endringer og
-- godkjenningen ville fått samme decided_at og «den gjeldende» ville vært
-- avgjort av en tilfeldig uuid. Den foregående dyttes derfor en time bakover,
-- slik en reell kjøring får det av at hver registrering er sin egen
-- transaksjon. Samme grep og samme begrunnelse som i 530.
create function pg_temp.age_earlier_decisions(p_revision uuid) returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update workflow.review_decisions
  set decided_at = decided_at - interval '1 hour',
      created_at = created_at - interval '1 hour'
  where claim_revision_id = p_revision;
  set local session_replication_role = origin;
end;
$$;
select pg_temp.age_earlier_decisions('51000000-0000-4000-8000-000000000034');

select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select lives_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000034',
    (select value from digest where label = 'r34'), 'approved'),
  'med kildekontrollen og claim-kontrollen på plass kan godkjenningen registreres'
);
reset role;

select is(
  (select rd.decision::text from workflow.review_decisions rd
   where rd.claim_revision_id = '51000000-0000-4000-8000-000000000034'
   order by rd.decided_at desc, rd.created_at desc, rd.id desc limit 1),
  'approved',
  'godkjenningen er den gjeldende beslutningen, og anmodningen om endringer er bevart ved siden av'
);
select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      '51000000-0000-4000-8000-000000000034')$$,
  'hele publiseringsgaten slipper gjennom når leddene er tatt i riktig rekkefølge'
);

-- Dekningskontrollen på claim_verifications er utsatt til commit, og denne
-- transaksjonen rulles tilbake. Uten dette ville de fire kontrollene i filen
-- aldri blitt kontrollert av den.
select lives_ok(
  $$set constraints all immediate$$,
  'den utsatte dekningskontrollen godtar alle kontrollene filen har registrert'
);

-- ===========================================================================
-- Del 10 — Mutasjonstest: skriveveiens kontroll er ikke den eneste sperren
--
-- workflow.assert_reviewer_authorized(uuid) muteres til å slippe alle gjennom.
-- Kallet skal fortsatt avvises, av tabellens egen
-- workflow.enforce_reviewer_qualification(), som har ligget der siden migrasjon
-- 005 og er den som gjør regelen sann.
-- ===========================================================================
create or replace function workflow.assert_reviewer_authorized(p_scope_concept_id uuid default null)
  returns uuid
  language sql
  set search_path = ''
as $$
  select a.id from provenance.actors a where a.auth_user_id = auth.uid();
$$;

select set_config('request.jwt.claims',
                  '{"sub":"51000000-0000-4000-8000-0000000000b0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.approval_sql('51000000-0000-4000-8000-000000000031',
    (select value from digest where label = 'r31'), 'approved'),
  '42501', 'Reviewaktøren hadde ikke gyldig reviewer-rolle for dette innholdsområdet på beslutningstidspunktet.',
  'raden har sin egen kvalifikasjonskontroll: en aktør uten reviewer-rolle slipper ikke gjennom selv om skriveveiens kontroll er mutert bort'
);
reset role;

select finish();
rollback;
