-- Migrasjon 007g og 005x — ekstraksjonens proveniens, og maskinbeviset som
-- forutsetning.
--
-- Filen dekker tre ting som henger sammen:
--
--   1. at et agentgenerert evidensfunn er bundet til nøyaktig den kjøringen som
--      produserte det, deklarativt og ikke med en trigger som kan glemmes,
--   2. at kildeversjonens representasjonstype er like uforanderlig som resten
--      av øyeblikksbildet, og
--   3. at en menneskelig bekreftelse forutsetter at maskinen har bevist at
--      utdragene står ordrett i nettopp denne utgaven av kilden.
--
-- SQLSTATE 23503 = foreign_key_violation, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation (fra append-only- og freeze-triggerne).
begin;

create extension if not exists pgtap with schema extensions;

select plan(20);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_column(
  'knowledge', 'evidence_items', 'agent_run_id',
  'knowledge.evidence_items har agent_run_id'
);

select col_is_null(
  'knowledge', 'evidence_items', 'agent_run_id',
  'agent_run_id er nullbar: editorveien er ingen agentkjøring'
);

select is(
  (select a.attgenerated from pg_attribute a
   where a.attrelid = 'knowledge.evidence_items'::regclass
     and a.attname = 'agent_run_role'),
  's',
  'agent_run_role er en generert speilkolonne, ikke data noen kan sette'
);

-- De to sammensatte fremmednøklene er hele vernet. En trigger kunne glemmes;
-- disse kan ikke.
select set_eq(
  $$
    select c.conname::text
    from pg_constraint c
    where c.conrelid = 'knowledge.evidence_items'::regclass
      and c.contype = 'f'
      and c.confrelid = 'provenance.agent_runs'::regclass
  $$,
  $$values ('evidence_items_agent_run_actor_fkey'),
           ('evidence_items_agent_run_role_fkey')$$,
  'kjøringen er bundet både til aktøren og til rollen, deklarativt'
);

select has_function(
  'workflow', 'grounding_machine_proved',
  'workflow.grounding_machine_proved() finnes'
);

select has_function(
  'workflow', 'evidence_grounding_digest',
  'workflow.evidence_grounding_digest() finnes'
);

-- Det snevrere avtrykket skal ikke endre seg av at en kontroll registreres —
-- det er hele grunnen til at det finnes ved siden av det brede.
select isnt(
  (select pg_get_functiondef('workflow.evidence_grounding_digest(uuid)'::regprocedure)),
  (select pg_get_functiondef('workflow.evidence_extraction_digest(uuid)'::regprocedure)),
  'de to avtrykkene er forskjellige funksjoner, ikke to navn på det samme'
);

-- ===========================================================================
-- Del 2 — Fikstur
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
grant select on fixture to anon;

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('60000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 600',
        'Testforfatter 600', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation, retrieved_by_actor_id)
values ('60000000-0000-4000-8000-000000000021', '60000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/600', 'sha256:' || repeat('b', 64), 'abstract',
        (select id from fixture where name = 'editor'));

create temporary table cred (label text primary key, secret text not null) on commit drop;
insert into cred
select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman');
insert into cred
select 'verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman');
grant select on cred to anon;

create temporary table run (label text primary key, id uuid not null) on commit drop;
grant select, insert on run to anon;
create temporary table registered (name text primary key, id uuid not null) on commit drop;
grant select, insert on registered to anon, authenticated;

set local role anon;
insert into run select 'extract', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_role := 'evidence_extraction',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-12', p_prompt_template_version := 'evidence-extraction/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := '{"mode": "test-600"}'::jsonb);
insert into run select 'verify', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-12', p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := '{"mode": "test-600"}'::jsonb);

insert into registered select 'item', api.register_agent_extraction(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_run_id := (select id from run where label = 'extract'),
  p_source_id := '60000000-0000-4000-8000-000000000001',
  p_source_version_id := '60000000-0000-4000-8000-000000000021',
  p_design_code := 'randomized_controlled_trial',
  p_population_availability := 'not_reported',
  p_population_detail := 'Prøve i 600.',
  p_sample_size_availability := 'not_reported',
  p_intervention_drug_id := (select id from fixture where name = 'sertralin'),
  p_comparator_kind := 'none',
  p_outcome_concept_id := (select id from fixture where name = 'weight'),
  p_outcome_detail := 'Funn for 600.',
  p_timepoint_availability := 'not_reported',
  p_reported_direction := 'increase',
  p_estimate_availability := 'not_reported',
  p_confidence_interval_availability := 'not_reported',
  p_source_locator := 'Avsnitt for 600',
  p_field_groundings := jsonb_build_array(
    jsonb_build_object('check_field', 'intervention_arm', 'source_excerpt', 'Patients received sertraline.',
                       'source_locator', 'Metode', 'justification', 'Armen står i metodeavsnittet.'),
    jsonb_build_object('check_field', 'outcome', 'source_excerpt', 'Weight change was the outcome.',
                       'source_locator', 'Metode', 'justification', 'Endepunktet står i metodeavsnittet.'),
    jsonb_build_object('check_field', 'reported_direction', 'source_excerpt', 'Weight increased.',
                       'source_locator', 'Resultater', 'justification', 'Retningen står i resultatavsnittet.'),
    jsonb_build_object('check_field', 'availability_semantics', 'source_excerpt', 'No numeric estimate was given.',
                       'source_locator', 'Resultater', 'justification', 'Feltene uten verdi er ført som ikke rapportert.')),
  p_source_quote := 'Weight increased.');
reset role;

-- ===========================================================================
-- Del 3 — Kjøringen er bundet til raden
-- ===========================================================================
select is(
  (select e.agent_run_id from knowledge.evidence_items e
   where e.id = (select id from registered where name = 'item')),
  (select id from run where label = 'extract'),
  'agentveien binder funnet til kjøringen som produserte det'
);

select is(
  (select e.agent_run_role::text from knowledge.evidence_items e
   where e.id = (select id from registered where name = 'item')),
  'evidence_extraction',
  'og speilkolonnen sier hvilken rolle kjøringen må ha'
);

-- En rad kan ikke omskrives i det hele tatt: append-only-triggeren feller
-- ethvert UPDATE før fremmednøklene i det hele tatt får ordet.
select throws_ok(
  format(
    $$update knowledge.evidence_items set agent_run_id = null where id = %L$$,
    (select id from registered where name = 'item')
  ),
  '23001',
  null,
  'et evidensfunn kan ikke omskrives til å ha en annen kjøring'
);

-- …og en ny rad kan ikke vise til en kjøring som tilhører en annen aktør.
-- Verifikatorens kjøring tilhører en annen aktør *og* en annen rolle, så begge
-- fremmednøklene ville felt den; poenget er at det ikke finnes en vei rundt.
select throws_ok(
  format(
    $$
      insert into knowledge.evidence_items (
        source_id, source_version_id, design_code, population_availability,
        population_detail, sample_size_availability, intervention_drug_id,
        comparator_kind, outcome_concept_id, outcome_detail,
        timepoint_availability, reported_direction, estimate_availability,
        confidence_interval_availability, source_locator, extraction_method,
        created_by_actor_id, agent_run_id
      )
      values (
        '60000000-0000-4000-8000-000000000001',
        '60000000-0000-4000-8000-000000000021',
        'randomized_controlled_trial', 'not_reported', 'Feil kjøring, 600.',
        'not_reported', %L, 'none', %L, 'Feil kjøring, 600.',
        'not_reported', 'increase', 'not_reported', 'not_reported',
        'Avsnitt for 600', 'ai_assisted', %L, %L
      )
    $$,
    (select id from fixture where name = 'sertralin'),
    (select id from fixture where name = 'weight'),
    (select id from fixture where name = 'extractor'),
    (select id from run where label = 'verify')
  ),
  '23503',
  null,
  'en kjøring som tilhører en annen aktør eller rolle, kan ikke tilskrives en ekstraksjon'
);

-- Editorveien setter ingen kjøring: et skjema er ikke en agentkjøring.
select is(
  (select count(*) from knowledge.evidence_items e
   where e.extraction_method = 'manual' and e.agent_run_id is not null),
  0::bigint,
  'ingen manuell ekstraksjon påstår å ha en agentkjøring bak seg'
);

-- ===========================================================================
-- Del 4 — Representasjonstypen er uforanderlig
-- ===========================================================================
select throws_ok(
  $$update knowledge.source_versions set representation = 'full_text'
    where id = '60000000-0000-4000-8000-000000000021'$$,
  '23001',
  'Et hentet øyeblikksbilde av en kilde er uforanderlig og kan ikke endres.',
  'representasjonstypen kan ikke endres i ettertid'
);

select lives_ok(
  $$update knowledge.source_versions set storage_reference = 'lagring://ny/600.xml'
    where id = '60000000-0000-4000-8000-000000000021'$$,
  'men hvor kopien ligger, er driftsinformasjon og kan endres'
);

-- ===========================================================================
-- Del 5 — Maskinbeviset
-- ===========================================================================
select ok(
  not workflow.grounding_machine_proved((select id from registered where name = 'item')),
  'før noen maskinell kontroll er kjørt, er ingenting bevist'
);

-- En menneskelig bekreftelse uten beviset avvises av databasen, ikke bare av
-- flaten.
insert into auth.users (id, instance_id, aud, role, email)
values ('60000000-0000-4000-8000-0000000000c0', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'c600@example.test');
insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values ('60000000-0000-4000-8000-0000000000c1', 'human:c-600', 'human', 'Reviewer C 600',
        'Kvalifisert reviewer, for 600.', '60000000-0000-4000-8000-0000000000c0');
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('60000000-0000-4000-8000-0000000000c0', 'reviewer', null, now() - interval '1 year',
        (select id from fixture where name = 'editor'), 'Reviewer-tildeling for 600.');

create temporary table digest (label text primary key, value text) on commit drop;
grant select on digest to authenticated;
create function pg_temp.refresh_digest() returns void language sql as $$
  insert into digest
  select 'e', workflow.evidence_extraction_digest((select id from registered where name = 'item'))
  on conflict (label) do update set value = excluded.value;
$$;
select pg_temp.refresh_digest();

create function pg_temp.human_verify_sql() returns text language sql as $$
  select $q$
    select api.register_human_extraction_verification(
      (select id from registered where name = 'item'),
      (select value from digest where label = 'e'),
      'verified', 'original_source',
      array['raw_extraction', 'source_locator', 'intervention_arm', 'outcome',
            'reported_direction', 'availability_semantics'],
      'Prøve i 600: gikk gjennom hvert felt mot utdraget.')
  $q$;
$$;

select set_config('request.jwt.claims',
                  '{"sub":"60000000-0000-4000-8000-0000000000c0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.human_verify_sql(),
  '22023',
  'Ingen maskinell kontroll har bevist at kildeutdragene står ordrett i denne utgaven av kilden.',
  'en menneskelig bekreftelse uten maskinbevis avvises av databasen'
);
reset role;

select is(
  (select count(*) from workflow.evidence_verifications ev
   where ev.evidence_item_id = (select id from registered where name = 'item')),
  0::bigint,
  'og det avviste forsøket etterlater ingenting'
);

-- Maskinen kjører, og fører opp begge provenansfeltene.
set local role anon;
select lives_ok(
  $$
    select api.register_extraction_verification(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'verifier'),
      (select id from run where label = 'verify'),
      (select id from registered where name = 'item'),
      'uncertain', 'verifiable_representation',
      array['raw_extraction', 'source_locator'],
      'Prøve i 600: hvert forankret utdrag ble gjenfunnet ordrett i den reproduserte representasjonen.',
      'Tallene lot seg ikke bedømme maskinelt.')
  $$,
  'den deterministiske kontrollen registrerer beviset'
);
reset role;

select ok(
  workflow.grounding_machine_proved((select id from registered where name = 'item')),
  'og da er venstresiden bevist for nøyaktig dette grunnlaget'
);

-- Beviset overlever at andre kontroller registreres, men ikke at grunnlaget
-- endres. En ny forankring er en endring av grunnlaget.
insert into knowledge.evidence_field_groundings
  (evidence_item_id, created_by_actor_id, check_field,
   source_excerpt, source_locator, justification)
select (select id from registered where name = 'item'),
       (select id from fixture where name = 'extractor'),
       'limitations', 'A limitation was noted.', 'Diskusjon', 'Forbeholdet står i diskusjonen.';

select ok(
  not workflow.grounding_machine_proved((select id from registered where name = 'item')),
  'endres forankringen, gjelder ikke beviset lenger'
);

select finish();
rollback;
