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
--      utdragene står ordrett i nettopp denne utgaven av kilden, og
--   4. at «senere» avgjøres av registreringsrekkefølgen og ikke av klokka
--      (migrasjon 005å). Selve tildelingen — at nummeret følger den rekkefølgen
--      radene faktisk skrives i — kan bare prøves med to forbindelser, og det
--      gjør scripts/db-lock-test.sh. Her prøves kontrakten og at leserne
--      faktisk bruker nummeret.
--
-- SQLSTATE 23503 = foreign_key_violation, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation (fra append-only- og freeze-triggerne).
begin;

create extension if not exists pgtap with schema extensions;

select plan(46);

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
           ('evidence_items_agent_run_role_fkey'),
           ('evidence_items_agent_run_source_version_fkey')$$,
  'kjøringen er bundet til aktøren, rollen og kildeversjonen den leste, deklarativt'
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
  p_input_source_version_id := '60000000-0000-4000-8000-000000000021',
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
  p_extraction_method := 'ai_assisted',
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

-- ===========================================================================
-- Del 6 — Kjøringen er bundet til kildeversjonen den ble åpnet for
-- ===========================================================================
select is(
  (select r.input_source_version_id from provenance.agent_runs r
   where r.id = (select id from run where label = 'extract')),
  '60000000-0000-4000-8000-000000000021'::uuid,
  'ekstraksjonskjøringen sier hvilken kildeversjon den ble åpnet for'
);

-- En kjøring som ikke sier hva den skal lese, er ikke en ekstraksjonskjøring.
set local role anon;
select throws_ok(
  $$
    select api.begin_agent_run(
      p_identity_key := 'agent-identity:evidence-extraction-01',
      p_secret := (select secret from cred where label = 'extractor'),
      p_agent_role := 'evidence_extraction',
      p_provider := 'testleverandør', p_model := 'testmodell',
      p_model_version := '2026-09-12', p_prompt_template_version := 'evidence-extraction/1',
      p_pipeline_version := 'antidep-evidence/1',
      p_input_manifest := '{"mode": "uten kildeversjon"}'::jsonb)
  $$,
  '22023',
  'En ekstraksjonskjøring må åpnes for den kildeversjonen den skal lese.',
  'en ekstraksjonskjøring uten kildeversjon avvises'
);
reset role;

-- Verifikatorkjøringene leser en arbeidskø, ikke én versjon, og kravet gjelder
-- dem ikke.
select is(
  (select r.input_source_version_id from provenance.agent_runs r
   where r.id = (select id from run where label = 'verify')),
  null::uuid,
  'en verifikatorkjøring trenger ingen kildeversjon, og har ingen'
);

-- Den sammensatte fremmednøkkelen: et evidensfunn kan ikke vise til en annen
-- kildeversjon enn den kjøringen ble åpnet for. Regelen er deklarativ, så
-- ingen skrivevei kan omgå den.
insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation, retrieved_by_actor_id)
values ('60000000-0000-4000-8000-000000000022', '60000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/600-b', 'sha256:' || repeat('c', 64), 'abstract',
        (select id from fixture where name = 'editor'));

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
        '60000000-0000-4000-8000-000000000022',
        'randomized_controlled_trial', 'not_reported', 'Feil kildeversjon, 600.',
        'not_reported', %L, 'none', %L, 'Feil kildeversjon, 600.',
        'not_reported', 'increase', 'not_reported', 'not_reported',
        'Avsnitt for 600', 'ai_assisted', %L, %L
      )
    $$,
    (select id from fixture where name = 'sertralin'),
    (select id from fixture where name = 'weight'),
    (select id from fixture where name = 'extractor'),
    (select id from run where label = 'extract')
  ),
  '23503',
  null,
  'et evidensfunn kan ikke peke på en annen kildeversjon enn den kjøringen leste'
);

-- ===========================================================================
-- Del 7 — Dekningen er unionen, og ingen rad påstår mer enn sin operasjon
-- ===========================================================================
-- Maskinens rad dekker provenansfeltene; den er `uncertain` fordi tallene og
-- begrepene ikke lot seg bedømme maskinelt. Fram til migrasjon 005y ville den
-- ikke telt i det hele tatt.
select set_eq(
  format(
    $$select unnest(workflow.covered_check_fields(%L::uuid))::text$$,
    (select id from registered where name = 'item')
  ),
  $$values ('raw_extraction'), ('source_locator')$$,
  'en uavklart maskinkontroll gir dekning for nøyaktig de feltene den bekreftet'
);

-- …og gaten er ikke tilfredsstilt av den alene.
select isnt_empty(
  format(
    $$select unnest(workflow.required_check_fields(%L::uuid))::text
      except select unnest(workflow.covered_check_fields(%L::uuid))::text$$,
    (select id from registered where name = 'item'),
    (select id from registered where name = 'item')
  ),
  'maskinen alene dekker ikke det raden påstår: de semantiske feltene står igjen'
);

-- Mennesket registrerer sin rad med bare de semantiske feltene det bedømte, og
-- til sammen dekker de to radene nøyaktig det gaten krever.
select pg_temp.refresh_digest();
select set_config('request.jwt.claims',
                  '{"sub":"60000000-0000-4000-8000-0000000000c0"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.register_human_extraction_verification(
      (select id from registered where name = 'item'),
      (select value from digest where label = 'e'),
      'verified', 'original_source',
      array['intervention_arm', 'outcome', 'reported_direction', 'availability_semantics'],
      'Prøve i 600: bedømte de semantiske feltene mot hvert felts eget kildeutdrag.')
  $$,
  'mennesket bekrefter med bare de feltene det faktisk bedømte'
);
reset role;

select is_empty(
  format(
    $$select unnest(workflow.required_check_fields(%L::uuid))::text
      except select unnest(workflow.covered_check_fields(%L::uuid))::text$$,
    (select id from registered where name = 'item'),
    (select id from registered where name = 'item')
  ),
  'og de to radene dekker til sammen nøyaktig det gaten krever'
);

-- Ingen av dem påstår mer enn sin egen operasjon.
select is_empty(
  format(
    $$
      select ev.id::text
      from workflow.evidence_verifications ev
      where ev.evidence_item_id = %L::uuid
        and ev.agent_run_id is null
        and ('source_locator' = any (ev.checked_fields)
             or 'raw_extraction' = any (ev.checked_fields))
    $$,
    (select id from registered where name = 'item')
  ),
  'menneskets rad fører ikke opp provenansfeltene den aldri ble spurt om'
);

-- ===========================================================================
-- Del 8 — Beviset gjelder grunnlaget, ikke tidspunktet
--
-- Det overlever at andre kontroller registreres — menneskets rad over er selv
-- en slik — men ikke at grunnlaget endres. En ny forankring er en endring av
-- grunnlaget.
-- ===========================================================================
select ok(
  workflow.grounding_machine_proved((select id from registered where name = 'item')),
  'beviset står selv etter at en annen kontroll er registrert'
);

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

-- ===========================================================================
-- Del 9 — Et nyere avvik underkjenner et eldre bevis
--
-- Beviset skal være det *gjeldende*, ikke bare et som en gang fantes. Uten
-- denne regelen ville en maskinkontroll som fant et avvik på det samme
-- grunnlaget, latt det gamle beviset stå — og den menneskelige feltkontrollen
-- ville fortsatt åpnet.
-- ===========================================================================
-- Nytt funn, med sin egen kjøring og sin egen forankring, slik at Del 8 ikke
-- forstyrrer sekvensen.
set local role anon;
insert into run select 'extract-b', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_role := 'evidence_extraction',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-12', p_prompt_template_version := 'evidence-extraction/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_source_version_id := '60000000-0000-4000-8000-000000000022',
  p_input_manifest := '{"mode": "test-600-b"}'::jsonb);

insert into registered select 'item-b', api.register_agent_extraction(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_run_id := (select id from run where label = 'extract-b'),
  p_source_id := '60000000-0000-4000-8000-000000000001',
  p_source_version_id := '60000000-0000-4000-8000-000000000022',
  p_design_code := 'randomized_controlled_trial',
  p_population_availability := 'not_reported',
  p_population_detail := 'Andre prøve i 600.',
  p_sample_size_availability := 'not_reported',
  p_intervention_drug_id := (select id from fixture where name = 'sertralin'),
  p_comparator_kind := 'none',
  p_outcome_concept_id := (select id from fixture where name = 'weight'),
  p_outcome_detail := 'Andre funn for 600.',
  p_timepoint_availability := 'not_reported',
  p_reported_direction := 'increase',
  p_estimate_availability := 'not_reported',
  p_confidence_interval_availability := 'not_reported',
  p_source_locator := 'Avsnitt B for 600',
  p_extraction_method := 'ai_assisted',
  p_field_groundings := jsonb_build_array(
    jsonb_build_object('check_field', 'intervention_arm', 'source_excerpt', 'Patients received sertraline.',
                       'source_locator', 'Metode', 'justification', 'Armen står i metodeavsnittet.'),
    jsonb_build_object('check_field', 'outcome', 'source_excerpt', 'Weight change was the outcome.',
                       'source_locator', 'Metode', 'justification', 'Endepunktet står i metodeavsnittet.'),
    jsonb_build_object('check_field', 'reported_direction', 'source_excerpt', 'Weight increased.',
                       'source_locator', 'Resultater', 'justification', 'Retningen står i resultatavsnittet.'),
    jsonb_build_object('check_field', 'availability_semantics', 'source_excerpt', 'No numeric estimate was given.',
                       'source_locator', 'Resultater', 'justification', 'Feltene uten verdi er ført som ikke rapportert.')));

-- Maskinen beviser venstresiden.
insert into run select 'verify-b', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-12', p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := '{"mode": "test-600-b"}'::jsonb);
select api.register_extraction_verification(
  'agent-identity:extraction-verification-01',
  (select secret from cred where label = 'verifier'),
  (select id from run where label = 'verify-b'),
  (select id from registered where name = 'item-b'),
  'uncertain', 'verifiable_representation',
  array['raw_extraction', 'source_locator'],
  'Prøve i 600: utdragene ble gjenfunnet ordrett.',
  'Tallene lot seg ikke bedømme maskinelt.');
reset role;

select ok(
  workflow.grounding_machine_proved((select id from registered where name = 'item-b')),
  'beviset står etter den første maskinkontrollen'
);

-- …og en senere kontroll finner et avvik på det samme grunnlaget.
--
-- now() er transaksjonens starttidspunkt, og verified_at kan ikke ligge fram i
-- tid (evidence_verifications_verified_at_not_future_check). Den første
-- kontrollen dyttes derfor en time bakover, slik en reell kjøring får det av at
-- hver registrering er sin egen transaksjon. Samme grep som i 490, 530, 570 og
-- 590.
set local session_replication_role = replica;
update workflow.evidence_verifications
set verified_at = verified_at - interval '1 hour',
    created_at = created_at - interval '1 hour'
where evidence_item_id = (select id from registered where name = 'item-b');
set local session_replication_role = origin;

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, findings, rationale, verified_at,
   agent_run_id, verified_grounding_digest)
select e.id, e.created_by_actor_id,
       (select id from provenance.actors where actor_key = 'agent:extraction-verification'),
       'needs_correction', 'verifiable_representation',
       array['source_locator']::workflow.evidence_check_field[],
       'Utdraget for endepunktet står ikke i representasjonen likevel.',
       'Fornyet deterministisk kontroll.',
       now(),
       (select id from run where label = 'verify-b'),
       workflow.evidence_grounding_digest(e.id)
from knowledge.evidence_items e
where e.id = (select id from registered where name = 'item-b');

select ok(
  not workflow.grounding_machine_proved((select id from registered where name = 'item-b')),
  'et nyere avvik underkjenner det eldre beviset'
);

-- ===========================================================================
-- Del 10 — Kjøringens kildeversjon er et uforanderlig premiss
-- ===========================================================================
select throws_ok(
  format(
    $$update provenance.agent_runs
      set status = 'aborted',
          completed_at = now(),
          failure_reason = 'Prøve i 600.',
          input_source_version_id = %L
      where id = %L$$,
    '60000000-0000-4000-8000-000000000021',
    (select id from run where label = 'extract-b')
  ),
  '23001',
  null,
  'kildeversjonen kan ikke skrives om, heller ikke sammen med en gyldig statusovergang'
);

-- ===========================================================================
-- Del 11 — Registreringsrekkefølgen er fasiten, ikke klokka (migrasjon 005å)
-- ===========================================================================
-- Kontrakten først.
select col_not_null(
  'workflow', 'evidence_verifications', 'registration_ordinal',
  'ekstraksjonskontrollen har alltid en plass i registreringsrekkefølgen'
);
select col_not_null(
  'workflow', 'claim_verifications', 'registration_ordinal',
  'claim-kontrollen har alltid en plass i registreringsrekkefølgen'
);

-- Ingen DEFAULT, med vilje: en default evalueres før BEFORE-triggerne fyrer,
-- altså før radlåsen er tatt, og ville gitt nøyaktig den rekkefølgen migrasjonen
-- finnes for å unngå.
select is_empty(
  $$
    select t.table_name
    from (values ('workflow.evidence_verifications'),
                 ('workflow.claim_verifications')) as t(table_name)
    join pg_attribute a
      on a.attrelid = t.table_name::regclass and a.attname = 'registration_ordinal'
    where a.atthasdef
  $$,
  'nummeret har ingen default: det tildeles på innsiden av låsen eller ikke i det hele tatt'
);

select has_trigger(
  'workflow', 'evidence_verifications', 'evidence_verifications_set_registration_ordinal',
  'triggeren som tildeler nummeret finnes på ekstraksjonskontrollen'
);
select has_trigger(
  'workflow', 'claim_verifications', 'claim_verifications_set_registration_ordinal',
  'triggeren som tildeler nummeret finnes på claim-kontrollen'
);

-- BEFORE INSERT, ikke AFTER: en AFTER-trigger kan ikke sette en kolonne på raden.
select is_empty(
  $$
    select t.tgname::text
    from pg_trigger t
    where t.tgname in ('evidence_verifications_set_registration_ordinal',
                       'claim_verifications_set_registration_ordinal')
      and not (t.tgtype & 2 = 2 and t.tgtype & 4 = 4)
  $$,
  'begge triggerne er BEFORE INSERT'
);

-- cache 1 er en del av garantien: en bufret sekvens deler ut blokker per økt, og
-- to økter kunne da fått numre i motsatt rekkefølge av skrivingene.
select is_empty(
  $$
    select c.relname::text
    from pg_sequence s
    join pg_class c on c.oid = s.seqrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'workflow'
      and c.relname in ('evidence_verification_registration_seq',
                        'claim_verification_registration_seq')
      and s.seqcache <> 1
  $$,
  'begge sekvensene deler ut ett nummer om gangen'
);

select set_eq(
  $$
    select c.conname::text
    from pg_constraint c
    where c.contype = 'u'
      and c.conrelid in ('workflow.evidence_verifications'::regclass,
                         'workflow.claim_verifications'::regclass)
      and c.conname like '%registration_ordinal%'
  $$,
  $$values ('evidence_verifications_registration_ordinal_key'),
           ('claim_verifications_registration_ordinal_key')$$,
  'nummeret er entydig i begge tabellene'
);

-- ---------------------------------------------------------------------------
-- …og at leserne faktisk bruker det.
--
-- Avviksraden fra del 9 ble skrevet sist og har derfor det høyeste nummeret.
-- Klokka dyttes nå bakover på nettopp den raden, slik den ville sett ut om den
-- var skrevet av en transaksjon som *startet* før bekreftelsen og skrev etterpå:
-- den nyeste registreringen bærer det eldste tidsstempelet. Sortert på klokka
-- ville avviket forsvunnet bak bekreftelsen. Det er dette migrasjonen retter.
-- ---------------------------------------------------------------------------
create temporary table inverted (label text primary key, id uuid not null) on commit drop;
insert into inverted
select 'deviation', ev.id
from workflow.evidence_verifications ev
where ev.evidence_item_id = (select id from registered where name = 'item-b')
  and ev.outcome = 'needs_correction';

set local session_replication_role = replica;
update workflow.evidence_verifications
set verified_at = verified_at - interval '3 hours',
    created_at = created_at - interval '3 hours'
where id = (select id from inverted where label = 'deviation');
set local session_replication_role = origin;

select is(
  (select count(*) from workflow.evidence_verifications ev
   where ev.evidence_item_id = (select id from registered where name = 'item-b')
     and ev.verified_at < (select verified_at from workflow.evidence_verifications
                           where id = (select id from inverted where label = 'deviation'))),
  0::bigint,
  'forutsetningen: avviket bærer nå det eldste tidsstempelet på funnet'
);
select is(
  (select count(*) from workflow.evidence_verifications ev
   where ev.evidence_item_id = (select id from registered where name = 'item-b')
     and ev.registration_ordinal > (select registration_ordinal
                                    from workflow.evidence_verifications
                                    where id = (select id from inverted where label = 'deviation'))),
  0::bigint,
  'og det høyeste registreringsnummeret: det ble faktisk skrevet sist'
);

select is(
  (select workflow.evidence_verification_history(
            (select id from registered where name = 'item-b'))
          ->> 'current_extraction_verification_id'),
  (select id::text from inverted where label = 'deviation'),
  'den gjeldende kontrollen er den som ble skrevet sist, ikke den med nyeste klokke'
);

select ok(
  not workflow.grounding_machine_proved((select id from registered where name = 'item-b')),
  'maskinbeviset er fortsatt underkjent når avviket bærer det eldste tidsstempelet'
);

select is_empty(
  format(
    $$select unnest(workflow.covered_check_fields(%L::uuid))::text$$,
    (select id from registered where name = 'item-b')
  ),
  'og dekningen er fortsatt nullstilt av avviket'
);


select finish();
rollback;
