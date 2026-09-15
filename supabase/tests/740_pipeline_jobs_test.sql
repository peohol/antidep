-- Migrasjon 009b — den varige, idempotente jobbtilstanden.
--
-- Filen dekker de fire egenskapene som gjør at agentarbeid kan gjenopptas
-- trygt:
--
--   * innlegging er idempotent på (rolle, nøkkel),
--   * uttak gir en leie, og to kjørere tar aldri det samme oppdraget,
--   * fullføring er idempotent og bundet til leieholderen, og
--   * gjentatt feil er fail-closed: jobben blir stående, den prøves ikke evig.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23514 = check_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(21);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('workflow', 'pipeline_jobs', 'workflow.pipeline_jobs finnes');
select has_table('workflow', 'pipeline_job_events', 'workflow.pipeline_job_events finnes');

select ok(
  has_function_privilege('authenticated', 'api.enqueue_pipeline_job(text,text,jsonb)', 'EXECUTE')
    and not has_function_privilege('anon', 'api.enqueue_pipeline_job(text,text,jsonb)', 'EXECUTE'),
  'innlegging er en redaktørvei: authenticated ja, anon nei'
);
select ok(
  has_function_privilege('anon', 'api.claim_pipeline_job(text,text,text,integer)', 'EXECUTE'),
  'uttak er en agentvei og kjørbar for anon, fordi en agent ikke har brukerkonto'
);

-- ===========================================================================
-- Del 2 — Fikstur
-- ===========================================================================
insert into auth.users (id, email)
values ('74000000-0000-4000-8000-00000000000b', 'jobb-740@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values ('ac740000-0000-4000-8000-00000000000b', 'human', 'human:jobb-740',
        'Redaktør 740', 'Aktør med gyldig editor-tildeling, for 740.',
        '74000000-0000-4000-8000-00000000000b');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('74000000-0000-4000-8000-00000000000b', 'editor', null, now() - interval '1 year',
        'ac740000-0000-4000-8000-00000000000b', 'Gyldig tildeling for 740.');

create temporary table cred (label text primary key, secret text) on commit drop;
grant select on cred to anon;
insert into cred select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman');
insert into cred select 'verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman');

create temporary table result (label text primary key, payload jsonb not null) on commit drop;
grant select, insert on result to anon, authenticated;

-- ===========================================================================
-- Del 3 — Innleggingen er idempotent
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"74000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;

insert into result select 'enqueued', api.enqueue_pipeline_job(
  'evidence_extraction', 'source-version:740-a', '{"source_version_id": "740-a"}'::jsonb);
insert into result select 'again', api.enqueue_pipeline_job(
  'evidence_extraction', 'source-version:740-a', '{"source_version_id": "740-a"}'::jsonb);

-- Den samme nøkkelen med et annet oppdrag er et *annet* oppdrag under samme
-- navn, og en stille gjenbruk ville latt en kjører arbeide på noe annet enn
-- det som ble bedt om.
select throws_ok(
  $$select api.enqueue_pipeline_job(
      'evidence_extraction', 'source-version:740-a', '{"source_version_id": "740-b"}'::jsonb)$$,
  '23001', null,
  'samme nøkkel med et annet inndatamanifest avvises framfor å gjenbrukes stille'
);
reset role;

select is(
  (select (payload ->> 'enqueued')::boolean from result where label = 'enqueued'),
  true,
  'første innlegging oppretter jobben'
);
select is(
  (select (payload ->> 'enqueued')::boolean from result where label = 'again'),
  false,
  'en gjentatt innlegging oppretter ingenting nytt'
);
select is(
  (select payload ->> 'pipeline_job_id' from result where label = 'enqueued'),
  (select payload ->> 'pipeline_job_id' from result where label = 'again'),
  'gjentakelsen finner den samme jobben'
);

-- ===========================================================================
-- Del 4 — Uttaket gir en leie, og ingen to kjørere får den samme jobben
-- ===========================================================================
set local role anon;
insert into result select 'claimed', api.claim_pipeline_job(
  'agent-identity:evidence-extraction-01', (select secret from cred where label = 'extractor'),
  'evidence_extraction', 900);
insert into result select 'empty', api.claim_pipeline_job(
  'agent-identity:evidence-extraction-01', (select secret from cred where label = 'extractor'),
  'evidence_extraction', 900);

-- En identitet i en annen rolle kan ikke ta jobben, uansett legitimasjon.
select throws_ok(
  $$select api.claim_pipeline_job(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'verifier'),
      'evidence_extraction', 900)$$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'en identitet i en annen rolle kan ikke ta jobben'
);
reset role;

select is(
  (select (payload ->> 'claimed')::boolean from result where label = 'claimed'),
  true,
  'jobben tas ut av kjøreren i riktig rolle'
);
select is(
  (select (payload ->> 'claimed')::boolean from result where label = 'empty'),
  false,
  'en tom kø svarer claimed: false framfor å feile'
);
select is(
  (select (payload ->> 'attempt')::int from result where label = 'claimed'),
  1,
  'forsøket telles ved uttaket, ikke ved feilen'
);
select is(
  (select j.state::text from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid from result where label = 'claimed')),
  'leased',
  'jobben står som leased mens kjøreren holder den'
);

-- ===========================================================================
-- Del 5 — Fullføringen er idempotent og bundet til leieholderen
-- ===========================================================================
set local role anon;
select lives_ok(
  format(
    $$select api.complete_pipeline_job(
        'agent-identity:evidence-extraction-01', %L, %L, '{"ok": true}'::jsonb)$$,
    (select secret from cred where label = 'extractor'),
    (select payload ->> 'pipeline_job_id' from result where label = 'claimed')
  ),
  'leieholderen kan melde et utfall'
);

insert into result select 'completed_again', api.complete_pipeline_job(
  'agent-identity:evidence-extraction-01', (select secret from cred where label = 'extractor'),
  (select (payload ->> 'pipeline_job_id')::uuid from result where label = 'claimed'),
  '{"ok": true}'::jsonb);
reset role;

select is(
  (select (payload ->> 'completed')::boolean from result where label = 'completed_again'),
  false,
  'en allerede fullført jobb skriver ingenting og svarer med det registrerte utfallet'
);
select is(
  (select j.state::text from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid from result where label = 'claimed')),
  'succeeded',
  'jobben står som succeeded'
);

-- ===========================================================================
-- Del 6 — Gjentatt feil er fail-closed
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"74000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'flaky', api.enqueue_pipeline_job(
  'evidence_extraction', 'source-version:740-flaky', '{"source_version_id": "740-flaky"}'::jsonb);
reset role;

-- max_attempts er 3. Tre mislykkede forsøk skal ende med en jobb som blir
-- stående, ikke en som fortsatt ser ut som om den er underveis.
create function pg_temp.fail_once() returns jsonb language plpgsql as $fn$
declare
  v_claim jsonb;
begin
  perform set_config('role', 'anon', true);
  v_claim := api.claim_pipeline_job(
    'agent-identity:evidence-extraction-01',
    (select secret from cred where label = 'extractor'),
    'evidence_extraction', 900);
  if not (v_claim ->> 'claimed')::boolean then
    return v_claim;
  end if;
  return api.fail_pipeline_job(
    'agent-identity:evidence-extraction-01',
    (select secret from cred where label = 'extractor'),
    (v_claim ->> 'pipeline_job_id')::uuid,
    'Prøve i 740: kjøringen kom ikke gjennom.');
end;
$fn$;

insert into result select 'fail1', pg_temp.fail_once();
insert into result select 'fail2', pg_temp.fail_once();
insert into result select 'fail3', pg_temp.fail_once();
reset role;

select is(
  (select (payload ->> 'will_retry')::boolean from result where label = 'fail1'),
  true,
  'et første mislykket forsøk legger jobben tilbake i køen'
);
select is(
  (select (payload ->> 'will_retry')::boolean from result where label = 'fail3'),
  false,
  'det siste forsøket lar jobben bli stående'
);
select is(
  (select payload ->> 'state' from result where label = 'fail3'),
  'failed',
  'en oppbrukt jobb står som failed, ikke som noe som fortsatt er underveis'
);

-- Sporet bevarer hver overgang, også de som ble prøvd om igjen.
select ok(
  (select count(*) from workflow.pipeline_job_events e
   where e.pipeline_job_id = (select (payload ->> 'pipeline_job_id')::uuid
                              from result where label = 'fail3')) >= 7,
  'hver overgang etterlater en rad i det append-only jobbsporet'
);
select throws_ok(
  $$delete from workflow.pipeline_job_events$$,
  '23001', null,
  'jobbsporet kan ikke slettes'
);

select * from finish();
rollback;
