-- Migrasjon 005ab og 005ac — hvem som leste kilden, og under hvilke premisser.
--
-- 005ab: `api.register_agent_extraction(...)` hardkodet `extraction_method` til
-- `ai_assisted`. Den samme skriveveien tar nå imot både et maskinutkast fra
-- modell-leddet og et menneskes egen ekstraksjon levert som fil, og en fast
-- verdi ville registrert det ene som det andre (ANTIDEP_CONSTITUTION.md §12,
-- §14). Filen dekker at parameteren er påkrevd, at vokabularet er lukket til de
-- to verdiene denne veien faktisk beskriver, at en avvisning ikke etterlater
-- noe, og at de to verdiene gir to forskjellige rader — fordi metoden inngår i
-- evidensfunnets fingeravtrykk, og append-only står.
--
-- 005ac: kontrollgrunnlaget bærer to ting som er forskjellige og som ikke skal
-- forveksles — `drafted_by`, erklæringen om hvem som laget utkastet og når, lest
-- ut av kjøringens `input_manifest`, og `registered_by`, kjøringen som faktisk
-- skrev raden, med sine egne premisser og sitt eget tidspunkt
-- (EVIDENCE_PIPELINE.md §46, §65). Filen dekker at begge finnes med alle sine
-- felter, at hver av dem er NULL i den tilstanden fraværet faktisk betyr noe,
-- og at begge flatene som eksponerer grunnlaget, leser den samme ene
-- projeksjonen.
--
-- SQLSTATE 22023 = invalid_parameter_value.
begin;

create extension if not exists pgtap with schema extensions;

select plan(27);

-- ===========================================================================
-- Del 1 — Kontrakten på skriveveien
-- ===========================================================================
select is(
  (select count(*) from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname = 'register_agent_extraction'),
  1::bigint,
  'det finnes nøyaktig én api.register_agent_extraction — den gamle signaturen står ikke igjen'
);

select isnt_empty(
  $$
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and p.proname = 'register_agent_extraction'
      and 'p_extraction_method' = any (p.proargnames)
  $$,
  'skriveveien tar imot p_extraction_method'
);

-- Uten default: en kjører som glemmer feltet, skal få en avvisning framfor en
-- antakelse om at en modell laget raden (ANTIDEP_CONSTITUTION.md §6).
select is(
  (select p.pronargdefaults::integer from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname = 'register_agent_extraction'),
  15,
  'p_extraction_method har ingen standardverdi: de femten valgfrie parameterne er de samme som før'
);

select ok(
  (select p.prosecdef from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname = 'register_agent_extraction'),
  'api.register_agent_extraction() er fortsatt SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);

select is_empty(
  $$
    select r.role_name
    from (values ('public'), ('service_role')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api' and p.proname = 'register_agent_extraction'),
      'execute'
    )
  $$,
  'verken PUBLIC eller service_role har EXECUTE på skriveveien'
);

select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated')) as r(role_name)
    where not has_function_privilege(
      r.role_name,
      (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api' and p.proname = 'register_agent_extraction'),
      'execute'
    )
  $$,
  'anon og authenticated har EXECUTE, som for de øvrige agentendepunktene'
);

-- ===========================================================================
-- Del 2 — Fikstur
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
grant select on fixture to anon;

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('63000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 630',
        'Testforfatter 630', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation, retrieved_by_actor_id)
values ('63000000-0000-4000-8000-000000000021', '63000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/630', 'sha256:' || repeat('d', 64), 'full_text',
        (select id from fixture where name = 'editor'));

create temporary table cred (label text primary key, secret text not null) on commit drop;
insert into cred
select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman'
);
insert into cred
select 'verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman'
);
grant select on cred to anon;

create temporary table run (label text primary key, id uuid not null) on commit drop;
grant select, insert on run to anon;
create temporary table registered (name text primary key, id uuid not null) on commit drop;
grant select, insert on registered to anon;

-- Kjøringen registreres med sine *egne* premisser — Antideps deterministiske
-- registreringsvei — mens erklæringen om hvem som laget utkastet, ligger i
-- manifestet, som er kolonnen for hva kjøringen fikk inn. De to beskriver
-- forskjellige operasjoner på forskjellige tidspunkter.
set local role anon;
insert into run
select 'draft', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_role := 'evidence_extraction',
  p_provider := 'antidep', p_model := 'proposal-grounded-extraction',
  p_model_version := '1.0.0',
  p_prompt_template_version := 'evidence-extraction/proposal/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_source_version_id := '63000000-0000-4000-8000-000000000021',
  p_input_manifest := jsonb_build_object(
    'mode', 'test-630',
    'generated_by', jsonb_build_object(
      'producer', 'model',
      'provider', 'en-leverandør',
      'model', 'en-modell',
      'model_version', '2026-09-15',
      'prompt_template_version', 'evidence-extraction/proposal-drafting/1',
      'drafted_at', '2026-09-15T09:00:00+00:00',
      'request_digest', 'sha256:' || repeat('f', 64)
    )
  )
);
reset role;

-- Kallet, med nøyaktig de feltene fiksturraden påstår noe om.
create function pg_temp.extract(p_method text, p_detail text, p_run text default 'draft')
  returns uuid
  language plpgsql as $$
declare
  v_id uuid;
begin
  perform set_config('role', 'anon', true);
  v_id := api.register_agent_extraction(
    p_identity_key := 'agent-identity:evidence-extraction-01',
    p_secret := (select secret from cred where label = 'extractor'),
    p_agent_run_id := (select id from run where label = p_run),
    p_source_id := '63000000-0000-4000-8000-000000000001',
    p_source_version_id := '63000000-0000-4000-8000-000000000021',
    p_design_code := 'randomized_controlled_trial',
    p_population_availability := 'not_reported',
    p_population_detail := 'Voksne.',
    p_sample_size_availability := 'not_reported',
    p_intervention_drug_id := (select id from fixture where name = 'sertralin'),
    p_comparator_kind := 'none',
    p_outcome_concept_id := (select id from fixture where name = 'weight'),
    p_outcome_detail := p_detail,
    p_timepoint_availability := 'not_reported',
    p_reported_direction := 'increase',
    p_estimate_availability := 'not_reported',
    p_confidence_interval_availability := 'not_reported',
    p_source_locator := 'Avsnitt for 630',
    p_extraction_method := p_method,
    p_field_groundings := jsonb_build_array(
      jsonb_build_object('check_field', 'intervention_arm',
                         'source_excerpt', 'Patients received sertraline for eight weeks.',
                         'source_locator', 'Metode', 'justification', 'Armen står i metodeavsnittet.'),
      jsonb_build_object('check_field', 'outcome',
                         'source_excerpt', 'Weight change was the reported outcome.',
                         'source_locator', 'Metode', 'justification', 'Endepunktet står i metodeavsnittet.'),
      jsonb_build_object('check_field', 'reported_direction',
                         'source_excerpt', 'Weight increased during treatment.',
                         'source_locator', 'Resultater', 'justification', 'Retningen står i resultatavsnittet.'),
      jsonb_build_object('check_field', 'availability_semantics',
                         'source_excerpt', 'No numeric estimate was reported.',
                         'source_locator', 'Resultater', 'justification', 'Feltene uten verdi er ført som ikke rapportert.')
    )
  );
  perform set_config('role', 'postgres', true);
  return v_id;
end;
$$;

-- ===========================================================================
-- Del 3 — Verdien er forslagets, og vokabularet er lukket
-- ===========================================================================
insert into registered select 'ai', pg_temp.extract('ai_assisted', 'Vektendring, maskinutkast.');
insert into registered select 'human', pg_temp.extract('manual', 'Vektendring, menneskets ekstraksjon.');

select is(
  (select e.extraction_method::text from knowledge.evidence_items e
   where e.id = (select id from registered where name = 'ai')),
  'ai_assisted',
  'et maskinutkast registreres som ai_assisted'
);

select is(
  (select e.extraction_method::text from knowledge.evidence_items e
   where e.id = (select id from registered where name = 'human')),
  'manual',
  'et menneskes ekstraksjon registreres som manual, på den samme skriveveien'
);

-- Metoden inngår i content_hash. To rader og ikke én rad som skifter mening:
-- append-only står, og ingen historikk endres av at metoden er en parameter.
select isnt(
  (select e.content_hash from knowledge.evidence_items e
   where e.id = (select id from registered where name = 'ai')),
  (select e.content_hash from knowledge.evidence_items e
   where e.id = (select id from registered where name = 'human')),
  'de to metodene gir hvert sitt fingeravtrykk, og dermed to rader'
);

-- deterministic_import beskriver en maskinell import fra en strukturert kilde,
-- altså en vei inn i basen som ikke går gjennom et forankret forslag.
select throws_ok(
  $$select pg_temp.extract('deterministic_import', 'Vektendring, import.')$$,
  '22023',
  null,
  'deterministic_import avvises på denne skriveveien'
);

select throws_ok(
  $$select pg_temp.extract('ki-assistert', 'Vektendring, ukjent metode.')$$,
  '22023',
  null,
  'en verdi utenfor vokabularet avvises'
);

select throws_ok(
  $$select pg_temp.extract(null, 'Vektendring, uten metode.')$$,
  '22023',
  null,
  'en manglende metode avvises framfor å bli en antakelse'
);

select is(
  (select count(*) from knowledge.evidence_items e
   where e.source_id = '63000000-0000-4000-8000-000000000001'),
  2::bigint,
  'de tre avvisningene etterlot ingen rad'
);

-- ===========================================================================
-- Del 4 — Kontrollgrunnlaget skiller utkastet fra registreringen
-- ===========================================================================
select is(
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai')) -> 'drafted_by' ->> 'producer'),
  'model',
  'grunnlaget sier at en modell, og ikke et menneske, laget utkastet'
);

select is(
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai')) -> 'drafted_by' ->> 'provider')
  || '|' ||
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai')) -> 'drafted_by' ->> 'model')
  || '|' ||
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai')) -> 'drafted_by' ->> 'model_version'),
  'en-leverandør|en-modell|2026-09-15',
  'grunnlaget sier hvilken leverandør, modell og modellversjon som svarte'
);

select is(
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai'))
          -> 'drafted_by' ->> 'prompt_template_version'),
  'evidence-extraction/proposal-drafting/1',
  'grunnlaget sier hvilken promptmal utkastet ble laget med'
);

-- Tidspunktet er utkastets, ikke registreringens. Uten det ville det eneste
-- tidspunktet i proveniensen vært kjøringens started_at, som kan ligge dager
-- etter at modellen faktisk leste artikkelen.
select isnt(
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai')) -> 'drafted_by' ->> 'drafted_at'),
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai')) -> 'registered_by' ->> 'started_at'),
  'utkastets tidspunkt er et annet enn registreringens'
);

-- Avtrykket dekker representasjonen, katalogen i oppdraget og promptmalen, og
-- er det som gjør modellkjøringen identifiserbar i ettertid.
select is(
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai')) -> 'drafted_by' ->> 'request_digest'),
  'sha256:' || repeat('f', 64),
  'grunnlaget navngir forespørselen modellen svarte på'
);

select is(
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai')) -> 'registered_by' ->> 'provider')
  || '|' ||
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai')) -> 'registered_by' ->> 'model'),
  'antidep|proposal-grounded-extraction',
  'kjøringen står med sine egne premisser, ikke med modellens'
);

select is(
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai'))
          -> 'registered_by' ->> 'pipeline_version'),
  'antidep-evidence/1',
  'kjøringen sier hvilken pipelineversjon den var en del av'
);

select is(
  (select workflow.evidence_extraction_dossier(
            (select id from registered where name = 'ai')) -> 'registered_by' ->> 'agent_role')
  || '|' ||
  ((select workflow.evidence_extraction_dossier(
             (select id from registered where name = 'ai'))
           -> 'registered_by' ->> 'agent_run_id') is not null)::text
  || '|' ||
  ((select workflow.evidence_extraction_dossier(
             (select id from registered where name = 'ai'))
           -> 'registered_by' ->> 'started_at') is not null)::text,
  'evidence_extraction|true|true',
  'kjøringen navngir seg selv, sin rolle og når den startet'
);

-- En kjøring uten erklæring i manifestet: tilstanden alle funn registrert før
-- migrasjon 005ab er i. Kjøringen finnes, erklæringen gjør det ikke, og de to
-- svarene skal være uavhengige.
set local role anon;
select api.complete_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_run_id := (select id from run where label = 'draft'),
  p_status := 'succeeded',
  p_output_manifest := '{"mode": "test-630"}'::jsonb
);
insert into run
select 'uten', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_role := 'evidence_extraction',
  p_provider := 'antidep', p_model := 'proposal-grounded-extraction',
  p_model_version := '1.0.0',
  p_prompt_template_version := 'evidence-extraction/proposal/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_source_version_id := '63000000-0000-4000-8000-000000000021',
  p_input_manifest := '{"mode": "test-630-uten-erklæring"}'::jsonb
);
reset role;

insert into registered
select 'uten', pg_temp.extract('ai_assisted', 'Vektendring, uten erklæring.', 'uten');

select is(
  (workflow.evidence_extraction_dossier((select id from registered where name = 'uten'))
   -> 'drafted_by')::text
  || '|' ||
  ((workflow.evidence_extraction_dossier((select id from registered where name = 'uten'))
    -> 'registered_by') is not null)::text,
  'null|true',
  'en kjøring uten erklæring gir null for utkastet, men bærer fortsatt seg selv'
);

-- Et funn registrert uten agentkjøring har verken erklæring eller kjøring.
-- Fravær skal vises som fravær, aldri som et objekt med tomme felter
-- (ANTIDEP_CONSTITUTION.md §6).
insert into knowledge.evidence_items
  (id, source_id, source_version_id, design_code, population_availability, population_detail,
   sample_size_availability, intervention_drug_id, comparator_kind, outcome_concept_id,
   outcome_detail, timepoint_availability, reported_direction, estimate_availability,
   confidence_interval_availability, source_locator, extraction_method, created_by_actor_id)
values ('63000000-0000-4000-8000-000000000031', '63000000-0000-4000-8000-000000000001',
        '63000000-0000-4000-8000-000000000021', 'randomized_controlled_trial',
        'not_reported', 'Voksne.', 'not_reported',
        (select id from fixture where name = 'sertralin'), 'none',
        (select id from fixture where name = 'weight'), 'Vektendring, editorveien.',
        'not_reported', 'increase', 'not_reported', 'not_reported', 'Avsnitt',
        'manual', (select id from fixture where name = 'editor'));

select ok(
  (workflow.evidence_extraction_dossier('63000000-0000-4000-8000-000000000031')
   -> 'drafted_by') = 'null'::jsonb
  and (workflow.evidence_extraction_dossier('63000000-0000-4000-8000-000000000031')
       -> 'registered_by') = 'null'::jsonb,
  'et funn uten agentkjøring har verken erklæring eller kjøring, og sier det med null'
);

-- ===========================================================================
-- Del 5 — Begge flatene leser den samme ene projeksjonen
-- ===========================================================================
select matches(
  pg_get_functiondef((
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and p.proname = 'extraction_verification_input'
  )),
  'workflow\.evidence_extraction_dossier',
  'verifikatorens lesegrunnlag bygges av den samme projeksjonen'
);

select matches(
  pg_get_functiondef((
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and p.proname = 'extraction_review_workspace'
  )),
  'workflow\.evidence_extraction_dossier',
  'den menneskelige kontrollflaten bygges av den samme projeksjonen'
);

-- Kjeden hele veien ut: den autentiserte verifikatoren ser premissene i sitt
-- eget lesegrunnlag, ikke bare i en funksjon ingen klientrolle kan kalle.
set local role anon;
insert into run
select 'verify', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'antidep', p_model := 'deterministic-extraction-check',
  p_model_version := '1.0.0',
  p_prompt_template_version := 'extraction-verification/deterministic/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := '{"mode": "test-630"}'::jsonb
);
reset role;

set local role anon;
select is(
  (select item -> 'drafted_by' ->> 'model'
   from jsonb_array_elements(
     api.extraction_verification_input(
       p_identity_key := 'agent-identity:extraction-verification-01',
       p_secret := (select secret from cred where label = 'verifier'),
       p_agent_run_id := (select id from run where label = 'verify'),
       p_evidence_item_id := (select id from registered where name = 'ai')
     ) -> 'items'
   ) as item),
  'en-modell',
  'verifikatoren ser erklæringen i sitt eget lesegrunnlag'
);
reset role;

-- Ingen eksisterende nøkkel er borte. En projeksjon som stille mistet et felt,
-- ville latt en kontrollør bekrefte mindre enn hen trodde.
select is_empty(
  $$
    select k
    from unnest(array['evidence_item_id', 'extraction_method', 'content_hash', 'source',
                      'source_version', 'field_groundings', 'semantic_check_fields',
                      'grounded_check_fields', 'grounding_machine_proved', 'extraction',
                      'drafted_by', 'registered_by']) as k
    where not (workflow.evidence_extraction_dossier(
                 (select id from registered where name = 'ai')) ? k)
  $$,
  'projeksjonen har fortsatt hver nøkkel den hadde'
);

select * from finish();
rollback;
