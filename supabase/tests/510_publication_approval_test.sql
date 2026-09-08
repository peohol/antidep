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

select plan(36);

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

insert into knowledge.evidence_items (
  id, source_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values
  ('51000000-0000-4000-8000-000000000011', '51000000-0000-4000-8000-000000000001',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 510.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Første funn, for 510.',
   'not_reported', 'increase', 'not_reported', 'not_reported',
   'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor')),
  ('51000000-0000-4000-8000-000000000012', '51000000-0000-4000-8000-000000000001',
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

create temporary table digest (label text primary key, value text) on commit drop;
insert into digest values
  ('r31', knowledge.claim_evidence_set_digest('51000000-0000-4000-8000-000000000031')),
  ('r32', knowledge.claim_evidence_set_digest('51000000-0000-4000-8000-000000000032')),
  ('r33', knowledge.claim_evidence_set_digest('51000000-0000-4000-8000-000000000033'));
grant select on digest to authenticated;

create function pg_temp.approval_sql(p_revision uuid, p_digest text, p_decision text)
  returns text language sql as $$
  select 'select api.register_publication_approval('
    || quote_literal(p_revision) || '::uuid, '
    || quote_literal(p_digest) || ', '
    || quote_literal(p_decision) || ', '
    || $q$'Prøve i 510: faglig begrunnelse.')$q$;
$$;

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
-- Del 9 — Mutasjonstest: skriveveiens kontroll er ikke den eneste sperren
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
