-- Migrasjon 009e og 009f — publiseringen, tilbaketrekkingen og rollbacken.
--
-- ANTIDEP_CONSTITUTION.md regel 5 og 6: bare nøyaktig godkjent kandidat kan
-- publiseres, publisert historikk bevares, og tilbaketrekking og rollback skal
-- være synlig. Filen dekker at de setningene nå betyr noe:
--
--   * ingen publisering uten en sluttkontroll, og ingen på en som er gjort om,
--   * ingen publisering av en kandidat som ikke lenger er den gjeldende,
--   * ingen publisering uten publisher-mandat, og ingen fra en agentidentitet,
--   * det publiserte innholdet er den forseglede raden, ikke en ny påstand,
--   * historikken kan ikke forgrenes, og to gjeldende sannheter kan ikke oppstå,
--   * tilbaketrekking bevarer historikken og fjerner innholdet som gjeldende,
--   * rollback lager ny historikk og gjenoppretter riktig tidligere innhold, og
--   * klientrollene kan ikke skrive rundt API-et.
--
-- Samtidigheten mellom to *forbindelser* prøves i scripts/db-lock-test.sh;
-- pgTAP kjører i én transaksjon og kan bare prøve reglene som gjelder innenfor
-- den.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23505 = unique_violation, P0002 = no_data_found.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(62);

create temporary table fixture (name text primary key, id uuid not null) on commit drop;
-- Fiksturtabellen leses fra kall som kjører som `authenticated` og `anon`.
-- Granten gjelder bare denne transaksjonslokale tabellen.
grant select on fixture to anon, authenticated;

-- Svarene fra api-kallene samles her. Tabellene opprettes før rollebyttene, av
-- den økten som eier transaksjonen, og granten er transaksjonslokal.
create temporary table built (label text primary key, payload jsonb) on commit drop;
create temporary table utfall (label text primary key, payload jsonb) on commit drop;
-- Avtrykkene leses av kall som kjører som klientrolle, og klientrollene har ikke
-- usage på knowledge. De hentes derfor av økten selv, én gang, og sendes inn
-- igjen uendret — nøyaktig slik en flate ville sendt tilbake det avtrykket den
-- viste.
create temporary table avtrykk (label text primary key, value text not null) on commit drop;
grant select, insert on built, utfall to authenticated;
grant select on avtrykk to anon, authenticated;

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select is_empty(
  $$
    select f.name, r.role_name
    from (values
      ('api.publish_candidate(uuid,text,text)'),
      ('api.withdraw_claim_publication(uuid,text)'),
      ('api.rollback_claim_publication(uuid,uuid,text,text)'),
      ('api.published_claim(uuid)'),
      ('api.published_claim_index()'),
      ('api.claim_publication_history(uuid)')
    ) as f(name),
    (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(r.role_name, f.name, 'EXECUTE')
  $$,
  'ingen av publiseringsveiene er åpne for anon, service_role eller PUBLIC'
);

select is_empty(
  $$
    select f.name
    from (values
      ('api.publish_candidate(uuid,text,text)'),
      ('api.withdraw_claim_publication(uuid,text)'),
      ('api.rollback_claim_publication(uuid,uuid,text,text)'),
      ('api.published_claim(uuid)'),
      ('api.published_claim_index()'),
      ('api.claim_publication_history(uuid)')
    ) as f(name)
    where not has_function_privilege('authenticated', f.name, 'EXECUTE')
  $$,
  'alle seks er kjørbare for authenticated: mandatet avgjøres av databasen, ikke av granten'
);

-- Skriveveien er funksjonen, ikke tabellen. En klientrolle som kunne skrive i
-- historikken direkte, kunne registrert en publisering som aldri passerte gaten.
select is_empty(
  $$
    select t.table_name, r.role_name, p.privilege
    from (values ('knowledge.publication_events'), ('knowledge.candidates'),
                 ('knowledge.claims'), ('workflow.candidate_final_controls'))
           as t(table_name),
         (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name),
         (values ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, t.table_name, p.privilege)
  $$,
  'ingen klientrolle kan skrive i historikken, kandidatene eller pekeren utenom API-et'
);

select has_column('knowledge', 'publication_events', 'candidate_id',
                  'hendelsen navngir det forseglede innholdet');
select has_column('knowledge', 'publication_events', 'final_control_id',
                  'hendelsen navngir sluttkontrollen den hviler på');
select has_column('knowledge', 'claims', 'current_published_candidate_id',
                  'publiseringspekeren navngir innholdet, ikke bare revisjonen');
select col_not_null('workflow', 'candidate_final_controls', 'registration_ordinal',
                    'sluttkontrollen har et registreringsnummer, så «den gjeldende» er et faktum');

-- ===========================================================================
-- Del 2 — Fiksturet: én påstand med to fullt publiserbare revisjoner
-- ===========================================================================
insert into auth.users (id, email) values
  ('77000000-0000-4000-8000-000000000001', 'publisher-770@test.invalid'),
  ('77000000-0000-4000-8000-000000000002', 'fagperson-770@test.invalid'),
  ('77000000-0000-4000-8000-000000000003', 'kliniker-770@test.invalid'),
  ('77000000-0000-4000-8000-000000000004', 'redaktor-770@test.invalid');

insert into provenance.actors (actor_type, actor_key, display_name, description, auth_user_id)
values
  ('human', 'human:publisher-770', 'Publisher 770', 'Har publisher-rollen.',
   '77000000-0000-4000-8000-000000000001'),
  ('human', 'human:fagperson-770', 'Fagperson 770', 'Har reviewer-rollen for vektendring.',
   '77000000-0000-4000-8000-000000000002'),
  ('human', 'human:kliniker-770', 'Kliniker 770', 'Har ingen rolle i det hele tatt.',
   '77000000-0000-4000-8000-000000000003'),
  ('human', 'human:redaktor-770', 'Redaktør 770', 'Har editor-rollen.',
   '77000000-0000-4000-8000-000000000004');

insert into fixture (name, id)
select 'publisher', id from provenance.actors where actor_key = 'human:publisher-770';
insert into fixture (name, id)
select 'fagperson', id from provenance.actors where actor_key = 'human:fagperson-770';
insert into fixture (name, id)
select 'synthesis_actor', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id)
select 'verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';
insert into fixture (name, id)
select 'claim_verifier', id from provenance.actors
where actor_key = 'agent:citation-support-verification';
insert into fixture (name, id)
select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'drug', id from catalog.drugs where canonical_name = 'sertralin';

insert into workflow.user_roles
  (user_id, role_code, scope_id, granted_by_actor_id, grant_reason)
values
  ('77000000-0000-4000-8000-000000000001', 'publisher', null,
   (select id from fixture where name = 'fagperson'), 'Publiseringsrett for testene i 770.'),
  ('77000000-0000-4000-8000-000000000002', 'reviewer',
   (select id from fixture where name = 'topic'),
   (select id from fixture where name = 'publisher'), 'Sluttkontrollmandat for testene i 770.'),
  ('77000000-0000-4000-8000-000000000004', 'editor', null,
   (select id from fixture where name = 'publisher'), 'Byggerett for testene i 770.');

with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'drug' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'claim', id from inserted;

insert into knowledge.claim_revisions (
  claim_id, revision_number, knowledge_type, subject_drug_id,
  statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id
)
select c.id, n.revision_number, c.knowledge_type, c.subject_drug_id,
       format('Testformulering nummer %s i 770.', n.revision_number),
       'Gjelder bare testene i denne filen.', 'none', 'Testusikkerhet.',
       c.created_by_actor_id
from knowledge.claims c, (values (1), (2)) as n(revision_number)
where c.id = (select id from fixture where name = 'claim');

insert into fixture (name, id)
select 'rev1', r.id from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'claim') and r.revision_number = 1;
insert into fixture (name, id)
select 'rev2', r.id from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'claim') and r.revision_number = 2;

-- Den kildeomfattende halvdelen av et globalt fravær kan bare føres opp av en
-- maskinell kontroll med sin egen agentkjøring (migrasjon 005ae).
create function pg_temp.cover_source_wide_absence(p_evidence_item_id uuid)
  returns void
  language plpgsql
as $fn$
declare
  v_run_id uuid;
  v_actor_id uuid;
begin
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
         'Fikstur: hele den kontrollerte representasjonen er gjennomsøkt.',
         now() - interval '30 days', v_run_id
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;
end;
$fn$;

select pg_temp.cover_source_wide_absence(e.id) from knowledge.evidence_items e;

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'verified', 'original_source',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Kontrollert mot originalkilden.', now() - interval '20 days'
from knowledge.evidence_items e, fixture v
where v.name = 'verifier';

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select r.id, e.id, 'supports', 'direct', 'Funnet støtter formuleringen.',
       r.created_by_actor_id
from knowledge.claim_revisions r, knowledge.evidence_items e
where r.claim_id = (select id from fixture where name = 'claim')
  and e.id = (select e2.id
              from knowledge.evidence_items e2
              join catalog.drugs d on d.id = e2.intervention_drug_id
              where d.canonical_name = 'sertralin');

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'Forsøkt falsifisert.',
       now() - interval '15 days'
from knowledge.claim_revisions r, fixture v
where r.claim_id = (select id from fixture where name = 'claim') and v.name = 'claim_verifier';

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select r.id, r.knowledge_type, 'grade', 'low',
       'serious', 'not_assessable', 'serious', 'serious', 'not_assessable',
       'Domenene vurdert enkeltvis.', now() - interval '10 days',
       (select id from provenance.actors where actor_key = 'agent:evidence-assessment')
from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'claim');

-- Kandidatene bygges gjennom den ekte skriveveien, som en redaktør.
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000004"}', true);
set local role authenticated;
insert into built (label, payload)
select 'rev1', api.build_candidate((select id from fixture where name = 'rev1'));
insert into built (label, payload)
select 'rev2', api.build_candidate((select id from fixture where name = 'rev2'));
reset role;

insert into fixture (name, id)
select 'cand1', (payload ->> 'candidate_id')::uuid from built where label = 'rev1';
insert into fixture (name, id)
select 'cand2', (payload ->> 'candidate_id')::uuid from built where label = 'rev2';
insert into avtrykk (label, value)
select 'cand1', payload ->> 'candidate_digest' from built where label = 'rev1';
insert into avtrykk (label, value)
select 'cand2', payload ->> 'candidate_digest' from built where label = 'rev2';

-- ===========================================================================
-- Del 3 — Ingen publisering uten en sluttkontroll som faktisk tillater den
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;

select throws_ok(
  format(
    $$select api.publish_candidate(%L, %L, 'Publisering uten sluttkontroll.')$$,
    (select id from fixture where name = 'cand1'),
    (select value from avtrykk where label = 'cand1')),
  '23001', null,
  'en kandidat uten sluttkontroll kan ikke publiseres'
);
reset role;

-- En sluttkontroll som ber om endringer, er ikke en godkjenning.
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000002"}', true);
set local role authenticated;
select api.record_candidate_final_control(
  (select id from fixture where name = 'cand1'),
  (select value from avtrykk where label = 'cand1'),
  'changes_requested', 'Forbeholdet må stå i selve formuleringen.');
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;
select throws_like(
  format(
    $$select api.publish_candidate(%L, %L, 'Publisering etter changes_requested.')$$,
    (select id from fixture where name = 'cand1'),
    (select value from avtrykk where label = 'cand1')),
  '%er changes_requested, ikke approved%',
  'en kandidat der fagpersonen ba om endringer, kan ikke publiseres'
);
reset role;

-- En avvisning er heller ikke en godkjenning, og den gjeldende er den som ble
-- skrevet sist.
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000002"}', true);
set local role authenticated;
select api.record_candidate_final_control(
  (select id from fixture where name = 'cand1'),
  (select value from avtrykk where label = 'cand1'),
  'rejected', 'Grunnlaget bærer ikke formuleringen.');
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;
select throws_like(
  format(
    $$select api.publish_candidate(%L, %L, 'Publisering etter rejected.')$$,
    (select id from fixture where name = 'cand1'),
    (select value from avtrykk where label = 'cand1')),
  '%er rejected, ikke approved%',
  'en avvist kandidat kan ikke publiseres'
);
reset role;

-- ... og en godkjenning etterpå gjelder foran begge, fordi rekkefølgen leses av
-- registreringsnummeret.
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000002"}', true);
set local role authenticated;
select api.record_candidate_final_control(
  (select id from fixture where name = 'cand1'),
  (select value from avtrykk where label = 'cand1'),
  'approved', 'Formuleringen holder mot grunnlaget.');
select api.record_candidate_final_control(
  (select id from fixture where name = 'cand2'),
  (select value from avtrykk where label = 'cand2'),
  'approved', 'Den nyere formuleringen holder også.');
reset role;

-- ===========================================================================
-- Del 4 — Mandatet, og avtrykket
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000002"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$select api.publish_candidate(%L, %L, 'Fagpersonen publiserer selv.')$$,
    (select id from fixture where name = 'cand1'),
    (select value from avtrykk where label = 'cand1')),
  '42501', null,
  'å sluttkontrollere gir ikke publiseringsrett: det er to mandater og to handlinger'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000003"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$select api.publish_candidate(%L, %L, 'Kliniker publiserer.')$$,
    (select id from fixture where name = 'cand1'),
    (select value from avtrykk where label = 'cand1')),
  '42501', null,
  'en innlogget bruker uten publisher-rolle kan ikke publisere'
);
reset role;

-- En agentidentitet har ingen brukerkonto og er `anon` i Data API-et. Begge
-- halvdelene av det er strukturelle: granten mangler, og aktøren kan ikke være
-- kallerens egen.
select set_config('request.jwt.claims', '', true);
set local role anon;
select throws_ok(
  format(
    $$select api.publish_candidate(%L, %L, 'Agent publiserer.')$$,
    (select id from fixture where name = 'cand1'),
    (select value from avtrykk where label = 'cand1')),
  '42501', null,
  'en agentidentitet kan ikke publisere: veien er ikke kjørbar for anon'
);
reset role;

select is_empty(
  $$
    select a.actor_key
    from provenance.actors a
    where a.actor_type = 'agent' and a.auth_user_id is not null
  $$,
  'ingen agentaktør er knyttet til en brukerkonto, så ingen av dem kan være kallerens egen aktør'
);

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;
select throws_like(
  format(
    $$select api.publish_candidate(%L, 'sha256:%s', 'Feil avtrykk.')$$,
    (select id from fixture where name = 'cand1'), repeat('9', 64)),
  '%et annet kandidatavtrykk enn kandidatens eget%',
  'en publisering avgitt mot et annet avtrykk enn kandidatens eget avvises'
);
reset role;

-- ===========================================================================
-- Del 5 — Publiseringen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;

insert into utfall (label, payload)
select 'publisert', api.publish_candidate(
  (select id from fixture where name = 'cand1'),
  (select value from avtrykk where label = 'cand1'),
  'Første publisering i 770.');

select is(
  (select payload ->> 'action' from utfall where label = 'publisert'),
  'publish',
  'den første publiseringen registreres som publish'
);
select is(
  (select (payload ->> 'changed')::boolean from utfall where label = 'publisert'),
  true,
  'publiseringen endret noe, og sier det'
);

-- Gjentatt kall. Samme svar, ingen ny hendelse.
insert into utfall (label, payload)
select 'gjentatt', api.publish_candidate(
  (select id from fixture where name = 'cand1'),
  (select value from avtrykk where label = 'cand1'),
  'Gjentatt publisering i 770.');
reset role;

select is(
  (select (payload ->> 'changed')::boolean from utfall where label = 'gjentatt'),
  false,
  'en gjentatt publisering av det samme innholdet endrer ingenting'
);
select is(
  (select payload ->> 'publication_event_id' from utfall where label = 'gjentatt'),
  (select payload ->> 'publication_event_id' from utfall where label = 'publisert'),
  'og svarer med den hendelsen som allerede finnes'
);
select is(
  (select count(*) from knowledge.publication_events
   where claim_id = (select id from fixture where name = 'claim')),
  1::bigint,
  'historikken har fortsatt nøyaktig én hendelse'
);

select is(
  (select c.current_published_candidate_id from knowledge.claims c
   where c.id = (select id from fixture where name = 'claim')),
  (select id from fixture where name = 'cand1'),
  'publiseringspekeren navngir det forseglede innholdet'
);
select is(
  (select e.final_control_decision::text from knowledge.publication_events e
   where e.claim_id = (select id from fixture where name = 'claim')),
  'approved',
  'hendelsen bærer sluttkontrollen den hviler på, og den er en godkjenning'
);

-- Historikken kan ikke forgrenes: to publiseringer fra den samme tilstanden er
-- det samtidighetsvernet stopper. Regelen er deklarativ, og prøves her som
-- regel; to reelle forbindelser prøves i scripts/db-lock-test.sh.
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select (select id from fixture where name = 'claim'), 'publish',
           (select id from fixture where name = 'rev2'), 2,
           c.id, c.candidate_digest,
           (workflow.current_candidate_final_control(c.id)).id, 'approved',
           (select id from fixture where name = 'publisher'), 'human',
           'Andre samtidige publisering.', now()
    from knowledge.candidates c
    where c.id = (select id from fixture where name = 'cand2')
  $$,
  '%publication_events_no_forked_history_key%',
  'to publiseringer fra den samme tilstanden kan ikke begge bli historikk'
);

-- ===========================================================================
-- Del 6 — Det publiserte innholdet er den forseglede raden
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000003"}', true);
set local role authenticated;
insert into utfall (label, payload)
select 'klinikervisning', api.published_claim((select id from fixture where name = 'claim'));
reset role;

select is(
  (select payload -> 'content' from utfall where label = 'klinikervisning'),
  (select c.content from knowledge.candidates c
   where c.id = (select id from fixture where name = 'cand1')),
  'klinikerflaten viser nøyaktig det forseglede kandidatinnholdet, ikke en ny sammensetning'
);
select is(
  knowledge.source_version_content_hash(
    ((select payload -> 'content' from utfall where label = 'klinikervisning'))::text),
  (select c.candidate_digest from knowledge.candidates c
   where c.id = (select id from fixture where name = 'cand1')),
  'og innholdet hasher til nøyaktig det avtrykket sluttkontrollen ble bundet til'
);
select is(
  (select payload -> 'final_control' ->> 'reviewer' from utfall where label = 'klinikervisning'),
  'Fagperson 770',
  'proveniensen navngir fagpersonen som sluttkontrollerte innholdet'
);
select is(
  (select jsonb_array_length(payload -> 'history') from utfall where label = 'klinikervisning'),
  1,
  'og historikken følger med der innholdet leses'
);

-- Interne kandidater er fortsatt private: den samme klinikeren har ikke mandat
-- til å lese en kandidat, bare det som faktisk er publisert.
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000003"}', true);
set local role authenticated;
select throws_ok(
  format($$select api.candidate_for_control(%L)$$,
         (select id from fixture where name = 'cand2')),
  '42501', null,
  'en kliniker uten mandat kan lese publisert innhold, men ikke en intern kandidat'
);
insert into utfall (label, payload)
select 'katalog', api.published_claim_index();
reset role;

select is(
  (select jsonb_array_length(payload) from utfall where label = 'katalog'),
  1,
  'den publiserte katalogen viser påstanden'
);

-- ===========================================================================
-- Del 7 — En kandidat som ikke lenger er den gjeldende, publiseres ikke
-- ===========================================================================
-- Grunnlaget under revisjon 2 endres etter forseglingen: kildestøttekontrollen
-- er en del av det forseglede innholdet, så en ny kontroll gir et annet avtrykk.
-- Endringen gjelder bare revisjon 2, slik at revisjon 1 fortsatt er den
-- kandidaten som faktisk ble publisert.
insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Kontrollert på nytt etter at kandidaten ble forseglet.', now()
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'rev2') and v.name = 'claim_verifier';

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;
select throws_like(
  format(
    $$select api.publish_candidate(%L, %L, 'Publisering av foreldet kandidat.')$$,
    (select id from fixture where name = 'cand2'),
    (select value from avtrykk where label = 'cand2')),
  '%ikke den gjeldende for påstandsrevisjonen sin%',
  'en kandidat hvis grunnlag er endret etter forseglingen, kan ikke publiseres'
);
reset role;

-- Det endrede innholdet bygges og sluttkontrolleres på nytt, som er nøyaktig
-- det regelen krever.
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000004"}', true);
set local role authenticated;
insert into built (label, payload)
select 'rev2_ny', api.build_candidate((select id from fixture where name = 'rev2'));
reset role;

insert into fixture (name, id)
select 'cand2_ny', (payload ->> 'candidate_id')::uuid from built where label = 'rev2_ny';
insert into avtrykk (label, value)
select 'cand2_ny', payload ->> 'candidate_digest' from built where label = 'rev2_ny';

select isnt(
  (select id from fixture where name = 'cand2_ny'),
  (select id from fixture where name = 'cand2'),
  'et endret grunnlag gir en ny kandidat med sitt eget avtrykk'
);

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000002"}', true);
set local role authenticated;
select api.record_candidate_final_control(
  (select id from fixture where name = 'cand2_ny'),
  (select value from avtrykk where label = 'cand2_ny'),
  'approved', 'Det endrede innholdet er lest på nytt.');
reset role;

-- ===========================================================================
-- Del 8 — Erstatning og rollback
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;
insert into utfall (label, payload)
select 'erstattet', api.publish_candidate(
  (select id from fixture where name = 'cand2_ny'),
  (select value from avtrykk where label = 'cand2_ny'),
  'Erstattet med den nyere revisjonen.');

select is(
  (select payload ->> 'action' from utfall where label = 'erstattet'),
  'replace',
  'en nyere revisjon erstatter den publiserte, og registreres som replace'
);

-- En rollback til et *annet innhold av den samme revisjonen* er ikke en
-- rollback: revisjonen er versjoneringsenheten, og et endret innhold tas i bruk
-- ved en ny kandidat og en ny sluttkontroll.
select throws_like(
  format(
    $$select api.rollback_claim_publication(%L, %L, %L, 'Rollback til forrige innhold.')$$,
    (select id from fixture where name = 'claim'),
    (select id from fixture where name = 'cand2'),
    (select value from avtrykk where label = 'cand2')),
  '%er allerede den publiserte%',
  'en rollback til et annet innhold av den publiserte revisjonen er ikke en rollback'
);

insert into utfall (label, payload)
select 'rullet', api.rollback_claim_publication(
  (select id from fixture where name = 'claim'),
  (select id from fixture where name = 'cand1'),
  (select value from avtrykk where label = 'cand1'),
  'Den nyere formuleringen var feil; tilbake til den forrige.');
reset role;

select is(
  (select payload ->> 'action' from utfall where label = 'rullet'),
  'rollback',
  'rollbacken er en ny hendelse, ikke en omskriving av den gamle'
);
select is(
  (select count(*) from knowledge.publication_events
   where claim_id = (select id from fixture where name = 'claim')),
  3::bigint,
  'historikken har tre hendelser: ingen av dem er fjernet'
);
select is(
  (select c.current_published_candidate_id from knowledge.claims c
   where c.id = (select id from fixture where name = 'claim')),
  (select id from fixture where name = 'cand1'),
  'pekeren står på det innholdet rollbacken gikk tilbake til'
);

-- ... og å gå framover igjen er en publisering, ikke en rollback.
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;
select throws_like(
  format(
    $$select api.rollback_claim_publication(%L, %L, %L, 'Rollback framover.')$$,
    (select id from fixture where name = 'claim'),
    (select id from fixture where name = 'cand2_ny'),
    (select value from avtrykk where label = 'cand2_ny')),
  '%er nyere enn den publiserte revisjonen%',
  'en rollback kan ikke peke framover i revisjonshistorikken'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000003"}', true);
set local role authenticated;
insert into utfall (label, payload)
select 'etter_rollback', api.published_claim((select id from fixture where name = 'claim'));
reset role;

select is(
  (select payload -> 'content' from utfall where label = 'etter_rollback'),
  (select c.content from knowledge.candidates c
   where c.id = (select id from fixture where name = 'cand1')),
  'klinikerflaten viser igjen nøyaktig det tidligere godkjente innholdet'
);

-- ===========================================================================
-- Del 9 — Tilbaketrekking
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000003"}', true);
set local role authenticated;
select throws_ok(
  format($$select api.withdraw_claim_publication(%L, 'Kliniker trekker tilbake.')$$,
         (select id from fixture where name = 'claim')),
  '42501', null,
  'tilbaketrekking krever publisher-mandat, som alt annet i publiseringslaget'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;
insert into utfall (label, payload)
select 'trukket', api.withdraw_claim_publication(
  (select id from fixture where name = 'claim'),
  'Nye data gjør formuleringen misvisende.');
insert into utfall (label, payload)
select 'trukket_igjen', api.withdraw_claim_publication(
  (select id from fixture where name = 'claim'),
  'Gjentatt tilbaketrekking.');
reset role;

select is(
  (select payload ->> 'action' from utfall where label = 'trukket'),
  'withdraw',
  'tilbaketrekkingen er en egen handling i historikken'
);
select is(
  (select payload ->> 'previous_candidate_id' from utfall where label = 'trukket'),
  (select id::text from fixture where name = 'cand1'),
  'og den navngir hvilket forseglet innhold som ble tatt ut av visning'
);
select is(
  (select (payload ->> 'changed')::boolean from utfall where label = 'trukket_igjen'),
  false,
  'en gjentatt tilbaketrekking endrer ingenting'
);
select is(
  (select count(*) from knowledge.publication_events
   where claim_id = (select id from fixture where name = 'claim')),
  4::bigint,
  'og historikken har fire hendelser, ikke fem'
);

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000003"}', true);
set local role authenticated;
insert into utfall (label, payload)
select 'etter_withdraw', api.published_claim((select id from fixture where name = 'claim'));
insert into utfall (label, payload)
select 'katalog_etter', api.published_claim_index();
insert into utfall (label, payload)
select 'historikk', api.claim_publication_history((select id from fixture where name = 'claim'));
reset role;

select is(
  (select payload -> 'content' from utfall where label = 'etter_withdraw'),
  'null'::jsonb,
  'det tilbaketrukne innholdet presenteres ikke lenger som gjeldende'
);
select is(
  (select (payload ->> 'withdrawn')::boolean from utfall where label = 'etter_withdraw'),
  true,
  'og fraværet er sagt som en tilbaketrekking, ikke som en tom side'
);
select is(
  (select jsonb_array_length(payload) from utfall where label = 'katalog_etter'),
  0,
  'den publiserte katalogen viser ikke lenger påstanden'
);
select is(
  (select jsonb_array_length(payload -> 'events') from utfall where label = 'historikk'),
  4,
  'men hele historikken er fortsatt etterprøvbar'
);
select is(
  (select payload -> 'events' -> 0 ->> 'action' from utfall where label = 'historikk'),
  'withdraw',
  'og tilbaketrekkingen står øverst i den, synlig'
);

-- Pekerne kan ikke si hver sin ting: en halv peker finnes ikke.
select throws_ok(
  format(
    $$update knowledge.claims set current_published_revision_id = %L where id = %L$$,
    (select id from fixture where name = 'rev1'),
    (select id from fixture where name = 'claim')),
  '23514', null,
  'en revisjonspeker uten innholdspeker avvises: to gjeldende sannheter kan ikke oppstå'
);

-- ===========================================================================
-- Del 10 — Mandatet gjelder også når handlingen allerede er utført
-- ===========================================================================
-- De tre handlingene svarer `changed: false` når det ikke er noe å endre.
-- Svaret er formet som et vellykket utfall, og skal derfor ikke kunne hentes av
-- en kaller uten publisher-mandat: da ville «handlingen krever mandat» vært
-- usant for nettopp det tilfellet (migrasjon 009h).
--
-- Kliniker 0003 har ingen publisher-rolle. Påstanden er tilbaketrukket her, så
-- kallet under ville ellers vært den idempotente no-op-en.
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000003"}', true);
set local role authenticated;
select throws_ok(
  format($$select api.withdraw_claim_publication(%L, 'Gjentatt tilbaketrekking uten mandat.')$$,
         (select id from fixture where name = 'claim')),
  '42501', null,
  'en gjentatt tilbaketrekking uten publisher-mandat avvises, den er ikke en gratis no-op'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;
insert into utfall (label, payload)
select 'publisert_paa_nytt', api.publish_candidate(
  (select id from fixture where name = 'cand1'),
  (select value from avtrykk where label = 'cand1'),
  'Publiseres på nytt etter tilbaketrekkingen.');
reset role;

select is(
  (select payload ->> 'action' from utfall where label = 'publisert_paa_nytt'),
  'publish',
  'en tilbaketrukket påstand kan publiseres på nytt, og det er en ny publish'
);

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000003"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$select api.publish_candidate(%L, %L, 'Gjentatt publisering uten mandat.')$$,
    (select id from fixture where name = 'cand1'),
    (select value from avtrykk where label = 'cand1')),
  '42501', null,
  'en gjentatt publisering uten publisher-mandat avvises, selv om den ikke ville endret noe'
);
select throws_ok(
  format(
    $$select api.rollback_claim_publication(%L, %L, %L, 'Gjentatt rollback uten mandat.')$$,
    (select id from fixture where name = 'claim'),
    (select id from fixture where name = 'cand1'),
    (select value from avtrykk where label = 'cand1')),
  '42501', null,
  'og en rollback til det som allerede står, avvises på samme måte'
);
reset role;

select is(
  (select count(*) from knowledge.publication_events
   where claim_id = (select id from fixture where name = 'claim')),
  5::bigint,
  'ingen av de avviste kallene rørte historikken'
);

-- ===========================================================================
-- Del 11 — To historisk publiserte innhold av den samme eldre revisjonen
-- ===========================================================================
-- Regresjonen fra migrasjon 009h. En revisjon kan ha vært publisert som flere
-- forskjellige kandidater: A publiseres, grunnlaget endres, den bygges om til B,
-- og B publiseres. Begge har vært vist, og begge står i historikken flaten
-- tilbyr som rollback-mål. Tar den kontrollerte operasjonen bare revisjonen,
-- ender en rollback mot A med å publisere B — et annet innhold enn det som ble
-- valgt.
--
-- Grunnlaget under revisjon 1 endres, slik det ble gjort for revisjon 2 over.
insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Revisjon 1 kontrollert på nytt etter at innholdet var publisert.', now()
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'rev1') and v.name = 'claim_verifier';

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000004"}', true);
set local role authenticated;
insert into built (label, payload)
select 'rev1_ny', api.build_candidate((select id from fixture where name = 'rev1'));
reset role;

insert into fixture (name, id)
select 'cand1_ny', (payload ->> 'candidate_id')::uuid from built where label = 'rev1_ny';
insert into avtrykk (label, value)
select 'cand1_ny', payload ->> 'candidate_digest' from built where label = 'rev1_ny';

select isnt(
  (select id from fixture where name = 'cand1_ny'),
  (select id from fixture where name = 'cand1'),
  'det endrede grunnlaget under revisjon 1 gir et nytt innhold med sitt eget avtrykk'
);

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000002"}', true);
set local role authenticated;
select api.record_candidate_final_control(
  (select id from fixture where name = 'cand1_ny'),
  (select value from avtrykk where label = 'cand1_ny'),
  'approved', 'Det endrede innholdet av revisjon 1 er lest på nytt.');
reset role;

-- Et nytt innhold av den revisjonen som *står* publisert, tas i bruk ved at
-- den tilbaketrekkes og publiseres på nytt: revisjonen er versjoneringsenheten,
-- og en publisering av den samme revisjonen er ingen tilstandsendring.
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;
select api.withdraw_claim_publication(
  (select id from fixture where name = 'claim'),
  'Tas ut mens det nye innholdet av revisjon 1 settes i drift.');
insert into utfall (label, payload)
select 'publisert_b', api.publish_candidate(
  (select id from fixture where name = 'cand1_ny'),
  (select value from avtrykk where label = 'cand1_ny'),
  'Det nye innholdet av revisjon 1.');
reset role;

select is(
  (select count(distinct e.candidate_id) from knowledge.publication_events e
   where e.revision_id = (select id from fixture where name = 'rev1')
     and e.candidate_id is not null),
  2::bigint,
  'revisjon 1 er nå publisert som to forskjellige innhold, og begge står i historikken'
);

-- En nyere revisjon erstatter den, slik at revisjon 1 blir det eldre målet en
-- rollback kan peke på.
select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;
insert into utfall (label, payload)
select 'erstattet_igjen', api.publish_candidate(
  (select id from fixture where name = 'cand2_ny'),
  (select value from avtrykk where label = 'cand2_ny'),
  'Den nyere revisjonen tas i bruk igjen.');

select is(
  (select payload ->> 'action' from utfall where label = 'erstattet_igjen'),
  'replace',
  'den nyere revisjonen erstatter den publiserte'
);

-- Kjernen: kandidat A har vært publisert for revisjon 1, men er ikke lenger
-- innholdet der. En rollback som navngir A, skal avvises — ikke stille
-- gjenopprette B.
select throws_like(
  format(
    $$select api.rollback_claim_publication(%L, %L, %L, 'Rollback til det gamle innholdet.')$$,
    (select id from fixture where name = 'claim'),
    (select id from fixture where name = 'cand1'),
    (select value from avtrykk where label = 'cand1')),
  '%ikke det gjeldende innholdet%',
  'en rollback til et innhold som har vært publisert, men ikke lenger er det gjeldende, avvises'
);

insert into utfall (label, payload)
select 'rullet_b', api.rollback_claim_publication(
  (select id from fixture where name = 'claim'),
  (select id from fixture where name = 'cand1_ny'),
  (select value from avtrykk where label = 'cand1_ny'),
  'Tilbake til det innholdet av revisjon 1 som faktisk gjelder.');
reset role;

select is(
  (select payload ->> 'action' from utfall where label = 'rullet_b'),
  'rollback',
  'rollbacken til det gjeldende innholdet av den eldre revisjonen går igjennom'
);
select is(
  (select c.current_published_candidate_id from knowledge.claims c
   where c.id = (select id from fixture where name = 'claim')),
  (select id from fixture where name = 'cand1_ny'),
  'og pekeren står på nøyaktig det innholdet kalleren navnga'
);

select set_config('request.jwt.claims',
                  '{"sub":"77000000-0000-4000-8000-000000000003"}', true);
set local role authenticated;
insert into utfall (label, payload)
select 'etter_rollback_b', api.published_claim((select id from fixture where name = 'claim'));
reset role;

select is(
  (select payload -> 'content' from utfall where label = 'etter_rollback_b'),
  (select c.content from knowledge.candidates c
   where c.id = (select id from fixture where name = 'cand1_ny')),
  'klinikerflaten viser det innholdet rollbacken navnga'
);
select isnt(
  (select payload -> 'content' from utfall where label = 'etter_rollback_b'),
  (select c.content from knowledge.candidates c
   where c.id = (select id from fixture where name = 'cand1')),
  'og ikke det eldre innholdet av den samme revisjonen'
);

select * from finish();
rollback;
