-- Migrasjon 005g — den kontrollerte skriveveien for ekstraksjonsverifikasjon.
--
-- Dekker det samme som 390_evidence_item_registration_test.sql dekket for
-- api.create_evidence_item(...): kontrakten (hva som faktisk er eksponert),
-- autentiseringen (nå av en agent, ikke en innlogget bruker), konsekvensen
-- (raden og auditraden), og avvisningene fra tabellens egne constraints. I
-- tillegg dekker filen det 430_agent_run_lifecycle_test.sql ikke gjorde: at
-- selve skriveveien — ikke bare den underliggende autentiseringsmekanismen —
-- avviser feil rolle, en avsluttet eller fremmed kjøring, en selvverifikasjon
-- og et forsøk på å forfalske aktør eller rolle utenom funksjonen.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23503 = foreign_key_violation, 23514 = check_violation,
-- P0002 = no_data_found.
begin;

create extension if not exists pgtap with schema extensions;

select plan(24);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'register_extraction_verification',
  'api.register_extraction_verification() finnes'
);
select has_function(
  'audit', 'record_evidence_verification_event',
  'audit.record_evidence_verification_event() finnes'
);
select has_trigger(
  'workflow', 'evidence_verifications', 'evidence_verifications_record_creation_audit_event',
  'enhver registrert verifikasjon auditeres'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.register_extraction_verification(text,text,uuid,uuid,text,text,text[],text,text)'::regprocedure),
  'api.register_extraction_verification() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
select ok(
  not (select p.prosecdef from pg_proc p
       where p.oid = 'audit.record_evidence_verification_event()'::regprocedure),
  'audit.record_evidence_verification_event() er ikke SECURITY DEFINER'
);

select is_empty(
  $$
    select r.role_name
    from (values ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.register_extraction_verification(text,text,uuid,uuid,text,text,text[],text,text)'::regprocedure,
      'execute'
    )
  $$,
  'api.register_extraction_verification() er kjørbar for verken service_role eller PUBLIC'
);
select ok(
  has_function_privilege(
    'anon',
    'api.register_extraction_verification(text,text,uuid,uuid,text,text,text[],text,text)'::regprocedure,
    'execute'
  ),
  'anon har EXECUTE — en agent har ingen brukerkonto og kaller som anon (migrasjon 005e)'
);
select ok(
  has_function_privilege(
    'authenticated',
    'api.register_extraction_verification(text,text,uuid,uuid,text,text,text[],text,text)'::regprocedure,
    'execute'
  ),
  'authenticated har EXECUTE, av samme grunn som for api.begin_agent_run(...)'
);

-- Ingen bredere tabelltilgang som bivirkning av de nye grantene: klientrollene
-- kan verken lese eller skrive workflow.evidence_verifications direkte. Kontrollen
-- er legitimasjonen inne i funksjonen, ikke en Data API-rettighet på tabellen.
select is_empty(
  $$
    select r.role_name, p.priv
    from (values ('anon'), ('authenticated'), ('public')) as r(role_name),
         (values ('select'), ('insert'), ('update'), ('delete')) as p(priv)
    where has_table_privilege(r.role_name, 'workflow.evidence_verifications', p.priv)
  $$,
  'anon, authenticated og public har ingen tabellrettighet i det hele tatt på workflow.evidence_verifications'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- En kilde og to evidensfunn: det ene laget av ekstraksjonsagenten (kan
-- verifiseres av verifikatoren), det andre laget av verifikatoren selv (kan
-- aldri verifiseres av den samme). En andre agentidentitet i en annen rolle,
-- registrert bare for denne testen, for å prøve rollegrensen gjennom selve
-- skriveveien og ikke bare gjennom autentiseringsfunksjonen alene.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;

insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values (
  '44000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 440',
  'Testforfatter 440', (select id from fixture where name = 'editor')
);

-- Et lagret øyeblikksbilde av kilden (knowledge.source_versions,
-- migrasjon 20260819064500). Finnes for at det første evidensfunnet skal ha et
-- reelt grunnlag å registrere `verifiable_representation` mot: uten denne
-- raden, og uten evidensfunnets source_version_id koblet til den, ville
-- outcome := 'verified' + source_access := 'verifiable_representation' vært en
-- påstand uten grunnlag, som §74.30 punkt 1 krever at funksjonen avviser (se
-- avsnitt 8).
insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash
)
values (
  '44000000-0000-4000-8000-000000000021', '44000000-0000-4000-8000-000000000001',
  now(), 'https://example.test/440-kilde',
  'sha256:' || repeat('a', 64)
);

-- Et sporet besøk uten fingeravtrykk: retrieved_from er satt, content_hash er
-- det bevisst ikke. Brukes i avsnitt 8 til å prøve grensen §74.30 punkt 2
-- trekker opp — at source_version_id alene ikke er nok, kildeversjonen må
-- selv ha content_hash for å telle som en etterprøvbar representasjon.
insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from
)
values (
  '44000000-0000-4000-8000-000000000022', '44000000-0000-4000-8000-000000000001',
  now(), 'https://example.test/440-kilde-uten-hash'
);

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values (
  '44000000-0000-4000-8000-000000000011', '44000000-0000-4000-8000-000000000001',
  '44000000-0000-4000-8000-000000000021',
  'randomized_controlled_trial', 'not_reported', 'Prøve i 440.',
  'not_reported', (select id from fixture where name = 'sertralin'), 'none',
  (select id from fixture where name = 'weight'), 'Funn laget av ekstraksjonsagenten, for 440.',
  'not_reported', 'not_stated', 'not_reported', 'not_reported',
  'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor')
),
(
  -- Har en lagret kildeversjon, av samme grunn som 000011: denne raden brukes
  -- til å prøve selvverifikasjonsregelen (del 7), ikke source_version-sjekken,
  -- og skal derfor ikke i tillegg trigge den nye avvisningen fra §74.30 punkt 1.
  '44000000-0000-4000-8000-000000000012', '44000000-0000-4000-8000-000000000001',
  '44000000-0000-4000-8000-000000000021',
  'randomized_controlled_trial', 'not_reported', 'Prøve i 440.',
  'not_reported', (select id from fixture where name = 'sertralin'), 'none',
  (select id from fixture where name = 'weight'), 'Funn laget av verifikatoren selv, for 440.',
  'not_reported', 'not_stated', 'not_reported', 'not_reported',
  'Avsnitt 2', 'ai_assisted', (select id from fixture where name = 'verifier')
),
(
  '44000000-0000-4000-8000-000000000013', '44000000-0000-4000-8000-000000000001',
  null,
  'randomized_controlled_trial', 'not_reported', 'Prøve i 440.',
  'not_reported', (select id from fixture where name = 'sertralin'), 'none',
  (select id from fixture where name = 'weight'), 'Funn laget av redaktøren, brukt bare til å prøve forfalskningsforsøk.',
  'not_reported', 'not_stated', 'not_reported', 'not_reported',
  'Avsnitt 3', 'manual', (select id from fixture where name = 'editor')
),
(
  -- Uten lagret kildeversjon (source_version_id NULL). Brukes i avsnitt 8 til å
  -- prøve at `verifiable_representation` avvises når det ikke finnes noe å vise
  -- til, uten å blande inn selvverifikasjonsregelen 000012 finnes for.
  '44000000-0000-4000-8000-000000000014', '44000000-0000-4000-8000-000000000001',
  null,
  'randomized_controlled_trial', 'not_reported', 'Prøve i 440.',
  'not_reported', (select id from fixture where name = 'sertralin'), 'none',
  (select id from fixture where name = 'weight'),
  'Funn laget av ekstraksjonsagenten, uten lagret kildeversjon, for 440.',
  'not_reported', 'not_stated', 'not_reported', 'not_reported',
  'Avsnitt 4', 'ai_assisted', (select id from fixture where name = 'extractor')
),
(
  -- Kildeversjon uten content_hash (000022). Brukes i avsnitt 8 til å prøve at
  -- verifiable_representation avvises selv når source_version_id er satt, når
  -- kildeversjonen selv ikke har noe fingeravtrykk å etterprøve mot.
  '44000000-0000-4000-8000-000000000015', '44000000-0000-4000-8000-000000000001',
  '44000000-0000-4000-8000-000000000022',
  'randomized_controlled_trial', 'not_reported', 'Prøve i 440.',
  'not_reported', (select id from fixture where name = 'sertralin'), 'none',
  (select id from fixture where name = 'weight'),
  'Funn laget av ekstraksjonsagenten, med kildeversjon uten content_hash, for 440.',
  'not_reported', 'not_stated', 'not_reported', 'not_reported',
  'Avsnitt 5', 'ai_assisted', (select id from fixture where name = 'extractor')
);

-- En andre agentidentitet, i rollen evidence_extraction, registrert bare for
-- denne testen. Finnes for å prøve at skriveveien avviser feil rolle, ikke bare
-- at autentiseringsfunksjonen gjør det alene (420 dekker allerede den siste).
insert into provenance.agent_identities (
  actor_id, agent_role, identity_key,
  registered_by_actor_id, registered_by_actor_type, registration_reason
)
select
  (select id from fixture where name = 'extractor'), 'evidence_extraction'::provenance.agent_role,
  'agent-identity:evidence-extraction-test-440',
  (select id from fixture where name = 'editor'), 'human',
  'Prøve i 440: en andre agentidentitet i en annen rolle, for å prøve at skriveveien avviser feil rolle.';

create temporary table cred (label text primary key, secret text);
insert into cred
select 'verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman'
);
insert into cred
select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-test-440', 'human:peder-holman'
);
grant select on cred to anon;

create temporary table run (label text primary key, id uuid);
grant insert, select on run to anon;

-- ===========================================================================
-- Del 3 — Åpne kjøringene testene trenger, som anon, uten brukerkonto
-- ===========================================================================
set local role anon;
insert into run
select 'verifier-open', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-06', p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('evidence_item_ids', array['44000000-0000-4000-8000-000000000011'])
);
insert into run
select 'verifier-closed', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-06', p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('evidence_item_ids', array['44000000-0000-4000-8000-000000000011'])
);
insert into run
select 'extractor-open', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-test-440',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_role := 'evidence_extraction',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-06', p_prompt_template_version := 'evidence-extraction/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('source_ids', array['44000000-0000-4000-8000-000000000001'])
);
select api.complete_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_run_id := (select id from run where label = 'verifier-closed'),
  p_status := 'aborted',
  p_failure_reason := 'Prøve i 440: lukket med hensikt for å prøve avvisningen av en avsluttet kjøring.'
);
reset role;

-- ===========================================================================
-- Del 4 — Den lykkede stien
-- ===========================================================================
create temporary table result (label text primary key, id uuid);
grant insert, select on result to anon;

set local role anon;
insert into result
select 'ok', api.register_extraction_verification(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_run_id := (select id from run where label = 'verifier-open'),
  p_evidence_item_id := '44000000-0000-4000-8000-000000000011',
  p_outcome := 'verified',
  p_source_access := 'verifiable_representation',
  p_checked_fields := array['source_locator', 'outcome', 'reported_direction'],
  p_rationale := 'Prøve i 440: kontrollert mot et lagret øyeblikksbilde av kilden.'
);
reset role;

select results_eq(
  $$
    select ev.evidence_item_id, ev.verified_item_creator_actor_id, ev.verifier_actor_id,
           ev.outcome::text, ev.source_access::text,
           ev.checked_fields = array['source_locator', 'outcome', 'reported_direction']::workflow.evidence_check_field[],
           ev.findings, ev.agent_run_id, ev.agent_run_role::text,
           ev.verified_at <= ev.created_at, ev.verified_at >= now() - interval '1 minute'
    from workflow.evidence_verifications ev
    where ev.id = (select id from result where label = 'ok')
  $$,
  $$
    values ('44000000-0000-4000-8000-000000000011'::uuid,
            (select id from fixture where name = 'extractor'),
            (select id from fixture where name = 'verifier'),
            'verified', 'verifiable_representation', true, null::text,
            (select id from run where label = 'verifier-open'), 'extraction_verification',
            true, true)
  $$,
  'raden bærer nøyaktig det oppgitte, attribuert til den autentiserte agentaktøren og bundet til kjøringen den ble registrert i'
);

select is(
  (select count(*)::integer from audit.events
   where object_table = 'evidence_verifications'
     and object_id = (select id from result where label = 'ok')),
  1,
  'registreringen ga nøyaktig én auditrad'
);
select results_eq(
  $$
    select e.operation::text, e.object_schema, e.actor_id, e.old_revision_or_snapshot,
           e.new_revision_or_snapshot ->> 'outcome'
    from audit.events e
    where e.object_id = (select id from result where label = 'ok')
  $$,
  $$
    values ('evidence_verification_registered', 'workflow',
            (select id from fixture where name = 'verifier'), null::jsonb, 'verified')
  $$,
  'auditraden peker på verifikasjonen, attribueres til verifikatoraktøren, har intet old-snapshot, og bærer utfallet'
);

-- ===========================================================================
-- Del 5 — Feil rolle avvises av selve skriveveien
-- ===========================================================================
set local role anon;
select throws_ok(
  $$
    select api.register_extraction_verification(
      p_identity_key := 'agent-identity:evidence-extraction-test-440',
      p_secret := (select secret from cred where label = 'extractor'),
      p_agent_run_id := (select id from run where label = 'extractor-open'),
      p_evidence_item_id := '44000000-0000-4000-8000-000000000011',
      p_outcome := 'verified',
      p_source_access := 'verifiable_representation',
      p_checked_fields := array['source_locator'],
      p_rationale := 'Prøve i 440: en ekstraksjonsagent forsøker å registrere en verifikasjon.'
    )
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'en agent i rollen evidence_extraction kan ikke kalle ekstraksjonsverifikasjonens skrivevei, selv med en åpen kjøring i sin egen rolle'
);
reset role;

-- ===========================================================================
-- Del 6 — Avsluttet og fremmed kjøring avvises
-- ===========================================================================
set local role anon;
select throws_ok(
  format($$
    select api.register_extraction_verification(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := %L::uuid,
      p_evidence_item_id := '44000000-0000-4000-8000-000000000011',
      p_outcome := 'verified', p_source_access := 'verifiable_representation',
      p_checked_fields := array['source_locator'],
      p_rationale := 'Prøve i 440: forsøk mot en avsluttet kjøring.'
    )
  $$, (select id from run where label = 'verifier-closed')),
  '42501', 'Det finnes ingen åpen agentkjøring med denne identiteten.',
  'en avsluttet kjøring kan ikke brukes til å registrere en verifikasjon'
);
select throws_ok(
  format($$
    select api.register_extraction_verification(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := %L::uuid,
      p_evidence_item_id := '44000000-0000-4000-8000-000000000011',
      p_outcome := 'verified', p_source_access := 'verifiable_representation',
      p_checked_fields := array['source_locator'],
      p_rationale := 'Prøve i 440: forsøk mot en kjøring som tilhører en annen identitet.'
    )
  $$, (select id from run where label = 'extractor-open')),
  '42501', 'Det finnes ingen åpen agentkjøring med denne identiteten.',
  'en kjøring som tilhører en annen agentidentitet kan ikke brukes, selv om den er åpen'
);
reset role;

-- ===========================================================================
-- Del 7 — Ingen agent kan verifisere sitt eget arbeid, heller ikke gjennom
-- den nye skriveveien
-- ===========================================================================
set local role anon;
select throws_ok(
  $$
    select api.register_extraction_verification(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := (select id from run where label = 'verifier-open'),
      p_evidence_item_id := '44000000-0000-4000-8000-000000000012',
      p_outcome := 'verified', p_source_access := 'verifiable_representation',
      p_checked_fields := array['source_locator'],
      p_rationale := 'Prøve i 440: verifikatoren forsøker å verifisere sitt eget funn.'
    )
  $$,
  '23514', null,
  'verifikatoren kan ikke registrere en verifikasjon av et funn den selv laget'
);
reset role;

-- ===========================================================================
-- Del 8 — Vokabular og eksistens, propagert fra tabellens egne regler
-- ===========================================================================
set local role anon;
select throws_ok(
  $$
    select api.register_extraction_verification(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := (select id from run where label = 'verifier-open'),
      p_evidence_item_id := '44000000-0000-4000-8000-000000000011',
      p_outcome := 'ikke-et-utfall', p_source_access := 'verifiable_representation',
      p_checked_fields := array['source_locator'],
      p_rationale := 'Prøve i 440: ukjent utfall.'
    )
  $$,
  '22023', null,
  'et ukjent verifikasjonsutfall avvises av databasen'
);
select throws_ok(
  $$
    select api.register_extraction_verification(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := (select id from run where label = 'verifier-open'),
      p_evidence_item_id := '44000000-0000-4000-8000-000000000011',
      p_outcome := 'uncertain', p_source_access := 'verifiable_representation',
      p_checked_fields := array[]::text[],
      p_rationale := 'Prøve i 440: ingen felter faktisk kontrollert.'
    )
  $$,
  '23514', null,
  'en verifikasjon uten et eneste kontrollert felt avvises: en kontroll som ikke kontrollerte noe er ikke en kontroll'
);
select throws_ok(
  $$
    select api.register_extraction_verification(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := (select id from run where label = 'verifier-open'),
      p_evidence_item_id := '00000000-0000-4000-8000-000000000000',
      p_outcome := 'uncertain', p_source_access := 'verifiable_representation',
      p_checked_fields := array['source_locator'],
      p_rationale := 'Prøve i 440: evidensfunnet finnes ikke.'
    )
  $$,
  'P0002', null,
  'et evidensfunn som ikke finnes avvises eksplisitt, framfor å feile på en fremmednøkkel lenger nede'
);

-- §74.30 punkt 1: `verifiable_representation` uten noe lagret grunnlag å vise
-- til skal avvises av funksjonen selv, ikke bare stole på kallerens ord.
-- 000014 har ingen source_version_id, i motsetning til 000011 fikstureren i
-- del 2 kobler til en faktisk knowledge.source_versions-rad.
select throws_ok(
  $$
    select api.register_extraction_verification(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := (select id from run where label = 'verifier-open'),
      p_evidence_item_id := '44000000-0000-4000-8000-000000000014',
      p_outcome := 'verified', p_source_access := 'verifiable_representation',
      p_checked_fields := array['source_locator'],
      p_rationale := 'Prøve i 440: forsøk på å registrere verifiable_representation uten lagret kildeversjon.'
    )
  $$,
  '22023', 'Evidensfunnet har ingen lagret kildeversjon å vise til.',
  'verifiable_representation avvises når evidensfunnet ikke har noen lagret, etterprøvbar kildeversjon å vise til'
);

-- §74.30 punkt 2: source_version_id alene er ikke nok — kildeversjonen må selv
-- ha content_hash. 000015 peker på 000022, en kildeversjon med retrieved_from
-- men uten content_hash, i motsetning til 000011 sin 000021 som har begge.
select throws_ok(
  $$
    select api.register_extraction_verification(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := (select id from run where label = 'verifier-open'),
      p_evidence_item_id := '44000000-0000-4000-8000-000000000015',
      p_outcome := 'verified', p_source_access := 'verifiable_representation',
      p_checked_fields := array['source_locator'],
      p_rationale := 'Prøve i 440: forsøk på å registrere verifiable_representation mot en kildeversjon uten content_hash.'
    )
  $$,
  '22023', 'Kildeversjonen evidensfunnet peker på har ingen lagret fingeravtrykk (content_hash).',
  'verifiable_representation avvises når kildeversjonen mangler content_hash, selv om source_version_id er satt'
);
reset role;

-- Uinnlogget/agentløs direkte tabellskriving er fortsatt stengt (§43), også med
-- gyldige verdier.
set local role authenticated;
select throws_ok(
  $$
    insert into workflow.evidence_verifications (
      evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
      outcome, source_access, checked_fields, rationale, verified_at
    )
    values (
      '44000000-0000-4000-8000-000000000011'::uuid,
      '00000000-0000-4000-8000-000000000001'::uuid,
      '00000000-0000-4000-8000-000000000002'::uuid,
      'verified', 'verifiable_representation',
      array['source_locator'],
      'Prøve i 440: en innlogget bruker forsøker å omgå funksjonen.',
      now()
    )
  $$,
  '42501', null,
  'en innlogget bruker kan ikke omgå funksjonen ved å skrive direkte i workflow.evidence_verifications'
);
reset role;

-- ===========================================================================
-- Del 9 — Aktør og rolle kan ikke forfalskes utenom funksjonen
--
-- Funksjonen har ingen parameter for verifikator-aktør i det hele tatt (se
-- signaturen brukt gjennom hele filen). Denne delen prøver at det heller ikke
-- er mulig å komme utenom ved å skrive raden direkte: de to sammensatte
-- fremmednøklene fra denne migrasjonen håndhever det uansett hvordan raden kom
-- dit, som resten av tabellens regler.
-- ===========================================================================
-- Begge forsøkene bruker det tredje funnet, laget av redaktøren: verken
-- verifikator-aktøren som forsøkes eller den ekte kjøringsaktøren er den samme
-- som skapte funnet, slik at evidence_verifications_separate_actor_check ikke
-- er det som slår ut — det er nettopp de to nye fremmednøklene fra denne
-- migrasjonen som skal fange forsøket.
select throws_ok(
  $$
    insert into workflow.evidence_verifications (
      evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
      outcome, source_access, checked_fields, findings, rationale, verified_at, agent_run_id
    )
    select '44000000-0000-4000-8000-000000000013',
           (select id from fixture where name = 'editor'),
           (select id from fixture where name = 'extractor'),
           'uncertain', 'verifiable_representation',
           array['source_locator']::workflow.evidence_check_field[],
           'Prøve i 440: ikke konkludert.',
           'Prøve i 440: forsøker å attribuere raden til en annen aktør enn kjøringens egen.',
           now(), (select id from run where label = 'verifier-open')
  $$,
  '23503', null,
  'en verifikasjon kan ikke attribueres til en annen aktør enn den agentkjøringen faktisk tilhører'
);
select throws_ok(
  $$
    insert into workflow.evidence_verifications (
      evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
      outcome, source_access, checked_fields, findings, rationale, verified_at, agent_run_id
    )
    select '44000000-0000-4000-8000-000000000013',
           (select id from fixture where name = 'editor'),
           (select id from fixture where name = 'extractor'),
           'uncertain', 'verifiable_representation',
           array['source_locator']::workflow.evidence_check_field[],
           'Prøve i 440: ikke konkludert.',
           'Prøve i 440: riktig aktør, men kjøringen kjørte i en annen rolle enn extraction_verification.',
           now(), (select id from run where label = 'extractor-open')
  $$,
  '23503', null,
  'en verifikasjon kan ikke peke på en agentkjøring som ikke kjørte i rollen extraction_verification, selv når aktøren stemmer'
);

select finish();

rollback;
