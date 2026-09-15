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

select plan(37);

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
-- Del 5 — Fullføringen er bundet til forsøket, og til arbeidet som ble gjort
--
-- Agentidentiteten er per rolle og deles av alle kjørere i den, så identiteten
-- alene kan ikke skille et uttak fra et annet — og heller ikke si hvilken
-- kjøring som gjorde hvilken jobb. Leienøkkelen skiller uttakene, og
-- workflow.pipeline_job_runs binder kjøringen til uttaket.
-- ===========================================================================
select ok(
  (select payload ->> 'lease_token' from result where label = 'claimed') is not null,
  'uttaket får sin egen leienøkkel, som utfallet meldes med'
);

-- En vellykket kjøring i en annen rolle, med en registrert identitet. Den
-- gjorde ikke dette arbeidet, og skal ikke kunne bære det.
insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest,
   status, completed_at, output_manifest)
select '74000000-0000-4000-8000-0000000000a2', ai.id, ai.actor_id, 'extraction_verification',
       'antidep', 'deterministic-extraction-check', '1.0.0',
       'extraction-verification/check/1', 'antidep-evidence/1',
       '{"mode": "test-740"}'::jsonb,
       'succeeded', now(), '{"registered": true}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';

-- Kjøringen som faktisk gjør arbeidet, åpnes *for uttaket*. Rollen oppgis ikke
-- av kalleren: den hentes fra jobben.
set local role anon;
insert into result select 'run', jsonb_build_object(
  'agent_run_id', api.begin_pipeline_job_run(
    'agent-identity:evidence-extraction-01',
    (select secret from cred where label = 'extractor'),
    (select (payload ->> 'pipeline_job_id')::uuid from result where label = 'claimed'),
    (select (payload ->> 'lease_token')::uuid from result where label = 'claimed'),
    'antidep', 'proposal-grounded-extraction', '1.1.0',
    'evidence-extraction/proposal/1', 'antidep-evidence/1',
    '{"mode": "test-740"}'::jsonb,
    'f2000000-0000-4000-8000-000000000002'));

-- En leie kalleren ikke holder, gir ingen kjøring å arbeide under.
select throws_ok(
  format(
    $$select api.begin_pipeline_job_run(
        'agent-identity:evidence-extraction-01', %L, %L,
        '74000000-0000-4000-8000-0000000000ff'::uuid,
        'antidep', 'proposal-grounded-extraction', '1.1.0',
        'evidence-extraction/proposal/1', 'antidep-evidence/1',
        '{"mode": "test-740"}'::jsonb,
        'f2000000-0000-4000-8000-000000000002')$$,
    (select secret from cred where label = 'extractor'),
    (select payload ->> 'pipeline_job_id' from result where label = 'claimed')
  ),
  '23001', null,
  'en kjøring kan ikke åpnes på en leie kalleren ikke holder'
);

-- En kjører hvis leie er løpt ut, har den gamle nøkkelen. Uten denne regelen
-- ville hen skrevet sitt foreldede resultat over det uttaket som nå arbeider.
select throws_ok(
  format(
    $$select api.complete_pipeline_job(
        'agent-identity:evidence-extraction-01', %L, %L,
        '74000000-0000-4000-8000-0000000000ff'::uuid, %L)$$,
    (select secret from cred where label = 'extractor'),
    (select payload ->> 'pipeline_job_id' from result where label = 'claimed'),
    (select payload ->> 'agent_run_id' from result where label = 'run')
  ),
  '23001', null,
  'et utfall meldt med en annen leienøkkel enn uttakets egen, avvises'
);

-- En jobb uten kjøring ville vært utført agentarbeid uten premisser og uten
-- spor (ANTIDEP_CONSTITUTION.md regel 4, 7).
select throws_ok(
  format(
    $$select api.complete_pipeline_job(
        'agent-identity:evidence-extraction-01', %L, %L, %L, null)$$,
    (select secret from cred where label = 'extractor'),
    (select payload ->> 'pipeline_job_id' from result where label = 'claimed'),
    (select payload ->> 'lease_token' from result where label = 'claimed')
  ),
  '22023', 'En fullført jobb skal peke på agentkjøringen som gjorde arbeidet.',
  'et utfall uten agentkjøring avvises'
);

select throws_ok(
  format(
    $$select api.complete_pipeline_job(
        'agent-identity:evidence-extraction-01', %L, %L, %L,
        '74000000-0000-4000-8000-0000000000a2')$$,
    (select secret from cred where label = 'extractor'),
    (select payload ->> 'pipeline_job_id' from result where label = 'claimed'),
    (select payload ->> 'lease_token' from result where label = 'claimed')
  ),
  '22023', 'Agentkjøringen tilhører ikke identiteten og rollen som melder utfallet.',
  'en kjøring fra en annen rolle kan ikke stå som premisset bak utfallet'
);

-- En åpen kjøring har ikke konkludert. Meldte køen jobben fullført likevel,
-- ville «ferdig» vært en påstand køen skrev om seg selv, ikke et utfall
-- proveniensen bærer (ANTIDEP_CONSTITUTION.md regel 4).
select throws_ok(
  format(
    $$select api.complete_pipeline_job(
        'agent-identity:evidence-extraction-01', %L, %L, %L, %L)$$,
    (select secret from cred where label = 'extractor'),
    (select payload ->> 'pipeline_job_id' from result where label = 'claimed'),
    (select payload ->> 'lease_token' from result where label = 'claimed'),
    (select payload ->> 'agent_run_id' from result where label = 'run')
  ),
  '22023', 'Agentkjøringen er ikke avsluttet med et vellykket utfall.',
  'en kjøring som fortsatt står som running, kan ikke bære en fullført jobb'
);

-- Arbeidet er gjort, og kjøringen lukkes med sitt utfall.
select lives_ok(
  format(
    $$select api.complete_agent_run(
        'agent-identity:evidence-extraction-01', %L, %L, 'succeeded',
        '{"registered": true}'::jsonb, null)$$,
    (select secret from cred where label = 'extractor'),
    (select payload ->> 'agent_run_id' from result where label = 'run')
  ),
  'kjøringen lukkes med et vellykket utfall'
);

select lives_ok(
  format(
    $$select api.complete_pipeline_job(
        'agent-identity:evidence-extraction-01', %L, %L, %L, %L)$$,
    (select secret from cred where label = 'extractor'),
    (select payload ->> 'pipeline_job_id' from result where label = 'claimed'),
    (select payload ->> 'lease_token' from result where label = 'claimed'),
    (select payload ->> 'agent_run_id' from result where label = 'run')
  ),
  'leieholderen kan melde et utfall'
);

-- Idempotent på nøkkelen: den som gjorde arbeidet og mistet svaret, kan spørre
-- igjen.
insert into result select 'completed_again', api.complete_pipeline_job(
  'agent-identity:evidence-extraction-01', (select secret from cred where label = 'extractor'),
  (select (payload ->> 'pipeline_job_id')::uuid from result where label = 'claimed'),
  (select (payload ->> 'lease_token')::uuid from result where label = 'claimed'),
  (select (payload ->> 'agent_run_id')::uuid from result where label = 'run'));

-- Et annet forsøk eier ikke utfallet, og kan heller ikke bekrefte det.
select throws_ok(
  format(
    $$select api.complete_pipeline_job(
        'agent-identity:evidence-extraction-01', %L, %L,
        '74000000-0000-4000-8000-0000000000ff'::uuid, %L)$$,
    (select secret from cred where label = 'extractor'),
    (select payload ->> 'pipeline_job_id' from result where label = 'claimed'),
    (select payload ->> 'agent_run_id' from result where label = 'run')
  ),
  '42501', 'Jobben er allerede fullført av et annet forsøk.',
  'en fullført jobb kan ikke bekreftes av et annet forsøk enn det som gjorde arbeidet'
);
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
-- En fullført jobb uten kjøring ville vært utført arbeid uten spor. Regelen
-- står på raden, ikke bare i skriveveien.
select is(
  (select j.agent_run_id from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid from result where label = 'claimed')),
  (select (payload ->> 'agent_run_id')::uuid from result where label = 'run'),
  'den fullførte jobben peker på kjøringen som gjorde arbeidet'
);
select throws_ok(
  $$update workflow.pipeline_jobs set agent_run_id = null
    where state = 'succeeded'$$,
  '23514', null,
  'en fullført jobb kan ikke stå uten kjøringen som gjorde arbeidet'
);

-- Utfallet er kjøringens eget, ikke en parallell påstand fra kalleren.
-- api.complete_pipeline_job tar ikke lenger imot et manifest i det hele tatt,
-- så køen og proveniensen kan ikke si hver sin ting om det samme arbeidet.
select is(
  (select j.output_manifest from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid from result where label = 'claimed')),
  '{"registered": true}'::jsonb,
  'jobbens utfall er det den bundne kjøringen registrerte'
);
select is(
  (select count(*)::int from pg_proc pr
   join pg_namespace n on n.oid = pr.pronamespace
   where n.nspname = 'api' and pr.proname = 'complete_pipeline_job'
     and pg_get_function_arguments(pr.oid) like '%p_output_manifest%'),
  0,
  'utfallet kan ikke oppgis av kalleren: parameteren finnes ikke'
);

-- ===========================================================================
-- Del 5b — En kjøring fra én jobb kan ikke bære en annen
--
-- Dette er hele grunnen til at bindingen finnes. Uten den ville jobb B kunnet
-- meldes ferdig med den vellykkede kjøringen fra jobb A: identitet, rolle og
-- status ville stemt, og raden ville sett like riktig ut.
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"74000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into result select 'second', api.enqueue_pipeline_job(
  'evidence_extraction', 'source-version:740-b', '{"source_version_id": "740-b"}'::jsonb);
reset role;

set local role anon;
insert into result select 'claimed_second', api.claim_pipeline_job(
  'agent-identity:evidence-extraction-01', (select secret from cred where label = 'extractor'),
  'evidence_extraction', 900);

select is(
  (select payload ->> 'pipeline_job_id' from result where label = 'claimed_second'),
  (select payload ->> 'pipeline_job_id' from result where label = 'second'),
  'den neste jobben i samme rolle tas ut som sin egen jobb'
);

select throws_ok(
  format(
    $$select api.complete_pipeline_job(
        'agent-identity:evidence-extraction-01', %L, %L, %L, %L)$$,
    (select secret from cred where label = 'extractor'),
    (select payload ->> 'pipeline_job_id' from result where label = 'claimed_second'),
    (select payload ->> 'lease_token' from result where label = 'claimed_second'),
    (select payload ->> 'agent_run_id' from result where label = 'run')
  ),
  '22023', 'Agentkjøringen ble ikke åpnet for dette uttaket av denne jobben.',
  'den vellykkede kjøringen fra den første jobben kan ikke fullføre den andre'
);
reset role;

-- Og bindingen kan ikke skrives om i etterkant til å peke på den andre jobben.
select throws_ok(
  $$update workflow.pipeline_job_runs set pipeline_job_id = pipeline_job_id$$,
  '23001', null,
  'bindingen mellom uttak og kjøring er append-only'
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
    (v_claim ->> 'lease_token')::uuid,
    'Prøve i 740: kjøringen kom ikke gjennom.');
end;
$fn$;

insert into result select 'fail1', pg_temp.fail_once();
reset role;

-- En jobb tilbake i køen har ingen leie, og dermed heller ingen leienøkkel
-- (pipeline_jobs_lease_token_pairing_check). Stod nøkkelen igjen, ville det
-- forrige forsøket fortsatt kunne meldt et utfall på et uttak det ikke har.
select ok(
  (select j.lease_token is null and j.leased_by_agent_identity_id is null
   from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid from result where label = 'fail1')),
  'en jobb tilbake i køen har verken leie eller leienøkkel'
);

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
