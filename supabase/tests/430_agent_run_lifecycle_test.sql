-- Migrasjon 005e — agentkjøringen: inngangspunktene, livssyklusen og de to
-- lagene som gjør at en agent ikke kan verifisere sitt eget arbeid.
--
-- 420 dekker legitimasjonen og rollen som rettighetsgrense. Denne filen dekker
-- operasjonen: at en kjører uten brukerkonto faktisk kommer gjennom Data
-- API-flaten med legitimasjon alene, at premissene DATABASE_ARCHITECTURE.md §33
-- krever faktisk registreres, at en kjøring bare kan avsluttes én gang og aldri
-- omskrives — og at aktør- og rollespeilene ikke lar seg forfalske.
--
-- Til slutt lag 2: workflow.evidence_verifications avviser en verifikasjon der
-- verifikator og ekstraktør er samme aktør, uansett hvordan raden kom dit. Det
-- er den kontrollen neste PR sin skrivevei skal skrive inn i, og den prøves her
-- med den agentaktøren som faktisk skal utføre den.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23503 = foreign_key_violation,
-- 23514 = check_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(18);

create temporary table cred(label text primary key, secret text);
insert into cred
select 'verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman'
);
-- Kjøreren er ikke en innlogget bruker, og skal derfor prøves som anon. Temptabellen
-- er testens egen, ikke en del av modellen.
grant select on cred to anon;

create temporary table run(label text primary key, id uuid);
grant insert, select on run to anon;

-- ===========================================================================
-- Del 1 — En kjører uten brukerkonto kommer gjennom med legitimasjon alene
-- ===========================================================================
set local role anon;

select throws_ok(
  $$
    select api.begin_agent_run(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := 'feil-hemmelighet',
      p_agent_role := 'extraction_verification',
      p_provider := 'testleverandør', p_model := 'testmodell',
      p_model_version := '1', p_prompt_template_version := '1',
      p_pipeline_version := '1',
      p_input_manifest := '{"evidence_item_ids": []}'::jsonb)
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'uten gyldig legitimasjon kommer ingen kjøring i gang, selv fra Data API-flaten'
);

-- Rollen er et krav operasjonen stiller, ikke en verdi kalleren velger fritt.
select throws_ok(
  $$
    select api.begin_agent_run(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_role := 'evidence_extraction',
      p_provider := 'testleverandør', p_model := 'testmodell',
      p_model_version := '1', p_prompt_template_version := '1',
      p_pipeline_version := '1',
      p_input_manifest := '{"source_ids": []}'::jsonb)
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'verifikatoridentiteten kan ikke åpne en kjøring i ekstraksjonsrollen'
);

select throws_ok(
  $$
    select api.begin_agent_run(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_role := 'finnes_ikke',
      p_provider := 'testleverandør', p_model := 'testmodell',
      p_model_version := '1', p_prompt_template_version := '1',
      p_pipeline_version := '1',
      p_input_manifest := '{"a": 1}'::jsonb)
  $$,
  '22023', '''finnes_ikke'' er ikke en kjent agentrolle.',
  'en ukjent agentrolle avvises med en setning som sier hva som er galt'
);

-- En kjøring uten premisser kunne ikke rekonstrueres, og proveniensgrafen ville
-- hatt et hull nøyaktig der KI-leddet står (DATABASE_ARCHITECTURE.md §34).
select throws_ok(
  $$
    select api.begin_agent_run(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_role := 'extraction_verification',
      p_provider := 'testleverandør', p_model := 'testmodell',
      p_model_version := '1', p_prompt_template_version := '1',
      p_pipeline_version := '1',
      p_input_manifest := '{}'::jsonb)
  $$,
  '23514', null,
  'en kjøring uten inputmanifest avvises'
);

reset role;
set local role anon;
insert into run
select 'first', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør',
  p_model := 'testmodell',
  p_model_version := '2026-09-01',
  p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := '{"evidence_item_ids": ["prøve"]}'::jsonb
);
reset role;

-- ===========================================================================
-- Del 2 — Premissene er registrert, og speilene peker på identiteten
-- ===========================================================================
select results_eq(
  $$
    select ar.status::text, ar.agent_role::text, actor.actor_key,
           ai.identity_key, ar.provider, ar.model_version,
           ar.prompt_template_version, ar.pipeline_version,
           ar.completed_at is null, ar.output_manifest is null
    from provenance.agent_runs ar
    join provenance.agent_identities ai on ai.id = ar.agent_identity_id
    join provenance.actors actor on actor.id = ar.actor_id
  $$,
  $$values ('running', 'extraction_verification', 'agent:extraction-verification',
            'agent-identity:extraction-verification-01', 'testleverandør',
            '2026-09-01', 'extraction-verification/1', 'antidep-evidence/1',
            true, true)$$,
  'kjøringen bærer rolle, aktør, identitet og alle fire versjonsfeltene, og er åpen'
);

-- Lag 3: speilene lar seg ikke forfalske. En kjøring som kunne oppgi en annen
-- aktør enn identitetens, ville gjort attribusjonen til en påstand kalleren
-- skriver om seg selv.
select throws_ok(
  $$
    insert into provenance.agent_runs
      (agent_identity_id, actor_id, agent_role, provider, model, model_version,
       prompt_template_version, pipeline_version, input_manifest)
    select ai.id,
           (select id from provenance.actors where actor_key = 'agent:evidence-extraction'),
           'extraction_verification', 'x', 'x', 'x', 'x', 'x', '{"a": 1}'::jsonb
    from provenance.agent_identities ai
    where ai.identity_key = 'agent-identity:extraction-verification-01'
  $$,
  '23503', null,
  'en kjøring kan ikke attribueres til en annen aktør enn identitetens'
);
select throws_ok(
  $$
    insert into provenance.agent_runs
      (agent_identity_id, actor_id, agent_role, provider, model, model_version,
       prompt_template_version, pipeline_version, input_manifest)
    select ai.id, ai.actor_id, 'claim_synthesis', 'x', 'x', 'x', 'x', 'x',
           '{"a": 1}'::jsonb
    from provenance.agent_identities ai
    where ai.identity_key = 'agent-identity:extraction-verification-01'
  $$,
  '23503', null,
  'en kjøring kan ikke handle i en annen rolle enn identitetens'
);

-- ===========================================================================
-- Del 3 — Avslutningen
-- ===========================================================================
set local role anon;

select throws_ok(
  format($$
    select api.complete_agent_run(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := %L::uuid, p_status := 'running')
  $$, (select id from run where label = 'first')),
  '22023', 'En agentkjøring kan ikke avsluttes med statusen running.',
  'en kjøring kan ikke «avsluttes» ved å forbli åpen'
);

-- En kjøring som lyktes uten å si hva den produserte, ville vært en bekreftelse
-- uten innhold. Regelen er tabellens, og avvisningen propageres uendret.
select throws_ok(
  format($$
    select api.complete_agent_run(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := %L::uuid, p_status := 'succeeded')
  $$, (select id from run where label = 'first')),
  '23514', null,
  'en vellykket kjøring uten outputmanifest avvises'
);

-- En ukjent kjøring gir samme avvisning som en mislykket autentisering, slik at
-- flaten ikke kan brukes til å lete etter kjøringer.
select throws_ok(
  $$
    select api.complete_agent_run(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := '00000000-0000-0000-0000-000000000000'::uuid,
      p_status := 'aborted', p_failure_reason := 'x')
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'en ukjent kjøring avvises uten å røpe at den ikke finnes'
);

select is(
  (select api.complete_agent_run(
     p_identity_key := 'agent-identity:extraction-verification-01',
     p_secret := (select secret from cred where label = 'verifier'),
     p_agent_run_id := (select id from run where label = 'first'),
     p_status := 'succeeded',
     p_output_manifest := '{"evidence_verification_ids": ["prøve"]}'::jsonb)),
  (select id from run where label = 'first'),
  'kjøringen avsluttes som vellykket med et outputmanifest'
);

select throws_ok(
  format($$
    select api.complete_agent_run(
      p_identity_key := 'agent-identity:extraction-verification-01',
      p_secret := (select secret from cred where label = 'verifier'),
      p_agent_run_id := %L::uuid, p_status := 'aborted',
      p_failure_reason := 'Prøver å gjenåpne.')
  $$, (select id from run where label = 'first')),
  '42501', 'Det finnes ingen åpen agentkjøring med denne identiteten.',
  'en avsluttet kjøring kan ikke avsluttes en gang til'
);

reset role;

select results_eq(
  $$
    select ar.status::text, ar.completed_at is not null,
           ar.output_manifest ? 'evidence_verification_ids',
           ar.completed_at >= ar.started_at
    from provenance.agent_runs ar
  $$,
  $$values ('succeeded', true, true, true)$$,
  'den avsluttede kjøringen bærer utfall, tidspunkt og hva den produserte'
);

-- ===========================================================================
-- Del 4 — Kjøringen kan ikke omskrives eller slettes
-- ===========================================================================
select throws_ok(
  $$update provenance.agent_runs set model_version = 'en annen'$$,
  '23001', null,
  'premissene for en kjøring kan ikke endres i ettertid'
);
select throws_ok(
  $$delete from provenance.agent_runs$$,
  '23001', null,
  'en agentkjøring kan ikke slettes'
);

-- ===========================================================================
-- Del 5 — Lag 2: en aktør kan ikke verifisere sin egen ekstraksjon
--
-- Kontrollen ligger på raden og gjelder uansett hvordan den kom dit. Den prøves
-- her med de aktørene som faktisk skal utføre stegene: de to seedede
-- evidensfunnene er laget av ekstraksjonsagenten, og verifikatoren er en annen
-- aktør.
-- ===========================================================================
select lives_ok(
  $$
    insert into workflow.evidence_verifications
      (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
       outcome, source_access, checked_fields, findings, rationale, verified_at)
    select ei.id, ei.created_by_actor_id,
           (select id from provenance.actors where actor_key = 'agent:extraction-verification'),
           'uncertain', 'verifiable_representation',
           array['source_locator']::workflow.evidence_check_field[],
           'Prøve i 430: kontrollen konkluderte ikke.',
           'Prøve i 430: kontrollerer at en separat agentaktør slipper til.',
           now()
    from knowledge.evidence_items ei
    order by ei.id
    limit 1
  $$,
  'en agentaktør i verifikatorrollen kan registrere en verifikasjon av en annen aktørs ekstraksjon'
);

-- Fra migrasjon 005q ligger mandatkontrollen foran selvverifikasjonsregelen: den
-- er BEFORE INSERT og fyrer før CHECK-en. De to er forskjellige grenser, og
-- fiksturen må skille dem — ellers ville den ene skjult den andre.
select throws_ok(
  $$
    insert into workflow.evidence_verifications
      (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
       outcome, source_access, checked_fields, rationale, verified_at)
    select ei.id, ei.created_by_actor_id, ei.created_by_actor_id,
           'verified', 'original_source',
           array['source_locator']::workflow.evidence_check_field[],
           'Prøve i 430: ekstraksjonsagenten kontrollerer sin egen ekstraksjon.',
           now()
    from knowledge.evidence_items ei
    order by ei.id
    limit 1
  $$,
  '42501', 'Verifikatoraktøren hadde ikke mandat til å kontrollere denne ekstraksjonen mot kilden.',
  'en ekstraksjonsagent har ikke mandat til å kontrollere en ekstraksjon i det hele tatt'
);

-- Et funn laget av verifikatoraktøren selv: her har verifikator mandatet, og
-- selvverifikasjonsregelen er derfor det som faktisk feller forsøket.
insert into knowledge.evidence_items (
  source_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
select
  ei.source_id, 'randomized_controlled_trial', 'not_reported',
  'Testdata i 430; bare til for å prøve selvverifikasjonsregelen.',
  'not_reported', ei.intervention_drug_id, 'none',
  ei.outcome_concept_id, 'Testendepunkt i 430.', 'not_reported',
  'increase', 'not_reported', 'not_reported',
  'Avsnitt for 430', 'ai_assisted',
  (select id from provenance.actors where actor_key = 'agent:extraction-verification')
from knowledge.evidence_items ei
order by ei.id
limit 1;

select throws_ok(
  $$
    insert into workflow.evidence_verifications
      (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
       outcome, source_access, checked_fields, rationale, verified_at)
    select ei.id, ei.created_by_actor_id, ei.created_by_actor_id,
           'verified', 'original_source',
           array['source_locator']::workflow.evidence_check_field[],
           'Prøve i 430: aktøren kontrollerer sin egen ekstraksjon.',
           now()
    from knowledge.evidence_items ei
    where ei.created_by_actor_id
          = (select id from provenance.actors where actor_key = 'agent:extraction-verification')
  $$,
  '23514', null,
  'ingen aktør kan verifisere sin egen ekstraksjon, heller ikke en agent med mandatet'
);

select finish();

rollback;
