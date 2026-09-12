-- Migrasjon 005af — den ene, sterkt guardede veien til å fjerne et testartefakt.
--
-- Antidep sletter ikke klinisk historikk. Denne filen prøver derfor to ting som
-- må holde samtidig:
--
--   1. at veien **finnes** og faktisk fjerner det den skal, med et spor etter
--      seg og uten å røre kilder, kildeversjoner, agentkjøringer eller audit,
--   2. at den er **stengt** for alt annet: for hver klientrolle, for en kaller
--      uten redaktørrolle, for en liste som ikke er gjennomgått, og for hver rad
--      som har kommet lenger i livssyklusen.
--
-- Den siste er den som betyr noe. En reset som kunne ta en menneskelig
-- kontrollert rad eller et funn en påstand hviler på, ville vært en vei fra
-- «pipelinen bygges fortsatt» til «klinisk historikk kan forsvinne».
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(30);

-- ===========================================================================
-- Del 1 — Kontrakten og stengslene
-- ===========================================================================
select has_function(
  'knowledge', 'discard_unpublished_extraction_artifacts',
  'knowledge.discard_unpublished_extraction_artifacts() finnes'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'knowledge.discard_unpublished_extraction_artifacts(uuid[],text)'::regprocedure),
  'veien er SECURITY DEFINER: den må kunne slå av og på tabellens eget vern'
);

select ok(
  (select exists (
     select 1
     from pg_proc p, unnest(coalesce(p.proconfig, array[]::text[])) as cfg
     where p.oid = 'knowledge.discard_unpublished_extraction_artifacts(uuid[],text)'::regprocedure
       and cfg like 'search_path=%'
   )),
  'veien har tomt search_path'
);

-- Den viktigste raden i filen: ingen klientrolle kan nå den. Veien er nåbar
-- bare for den som allerede har eiertilgang til databasen, og innskrenker
-- dermed en operasjon eieren ellers kunne gjort uten spor.
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'knowledge.discard_unpublished_extraction_artifacts(uuid[],text)', 'EXECUTE')
  $$,
  'ingen klientrolle kan kalle fjerningen — verken anon, authenticated, service_role eller PUBLIC'
);

-- Auditvokabularet dekker operasjonen. Uten dette ville en fjerning ikke kunnet
-- få en auditrad i det hele tatt, og sporet ville manglet uten at noe sa fra.
select ok(
  (select 'extraction_artifact_discarded' = any (
     select e.enumlabel from pg_enum e
     join pg_type t on t.oid = e.enumtypid
     where t.typname = 'event_operation'
   )),
  'audit.event_operation kjenner extraction_artifact_discarded'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- To evidensfunn registrert gjennom den ekte ekstraksjonsveien, slik at de har
-- forankring, avtrykk og en maskinell kontroll som de reelle radene har:
--
--   ren     et funn ingen har kommet videre med
--   bundet  et funn en påstandsrevisjon hviler på
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid) on commit drop;
insert into fixture (name, id)
select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id)
select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id)
select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
grant select on fixture to anon;

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('67000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 670',
        'Testforfatter 670', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation,
   retrieved_by_actor_id)
values ('67000000-0000-4000-8000-000000000021', '67000000-0000-4000-8000-000000000001',
        now(), 'https://eksempel.invalid/670', 'sha256:' || repeat('7', 64), 'full_text',
        (select id from fixture where name = 'editor'));

create temporary table cred (label text primary key, secret text not null) on commit drop;
insert into cred
select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman');
grant select on cred to anon;

create temporary table run (label text primary key, id uuid not null) on commit drop;
grant select, insert on run to anon;

set local role anon;
insert into run
select 'extraction', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_role := 'evidence_extraction',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-18', p_prompt_template_version := 'evidence-extraction/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_source_version_id := '67000000-0000-4000-8000-000000000021',
  p_input_manifest := jsonb_build_object('source_version_ids',
    array['67000000-0000-4000-8000-000000000021'])
);
reset role;

create function pg_temp.extract(p_detail text) returns uuid language plpgsql as $$
declare
  v_secret text;
  v_run uuid;
begin
  select secret into v_secret from cred where label = 'extractor';
  select id into v_run from run where label = 'extraction';
  perform set_config('role', 'anon', true);
  return api.register_agent_extraction(
    p_identity_key => 'agent-identity:evidence-extraction-01',
    p_secret => v_secret,
    p_agent_run_id => v_run,
    p_source_id => '67000000-0000-4000-8000-000000000001',
    p_source_version_id => '67000000-0000-4000-8000-000000000021',
    p_design_code => 'randomized_controlled_trial',
    p_population_availability => 'not_reported',
    p_population_detail => p_detail,
    p_sample_size_availability => 'not_reported',
    p_intervention_drug_id => (select id from fixture where name = 'sertralin'),
    p_comparator_kind => 'none',
    p_outcome_concept_id => (select id from fixture where name = 'weight'),
    p_outcome_detail => p_detail,
    p_timepoint_availability => 'not_reported',
    p_reported_direction => 'increase',
    p_estimate_availability => 'not_reported',
    p_confidence_interval_availability => 'not_reported',
    p_source_locator => 'Avsnitt for 670',
    p_extraction_method => 'ai_assisted',
    p_field_groundings => jsonb_build_array(
      jsonb_build_object('check_field', 'intervention_arm',
        'source_excerpt', 'Patients received sertraline.',
        'source_locator', 'Metode', 'justification', 'Armen er navngitt.'),
      jsonb_build_object('check_field', 'outcome',
        'source_excerpt', 'Weight change was the primary outcome.',
        'source_locator', 'Metode', 'justification', 'Endepunktet er navngitt.'),
      jsonb_build_object('check_field', 'reported_direction',
        'source_excerpt', 'Weight increased from baseline.',
        'source_locator', 'Resultater', 'justification', 'Retningen står der.'),
      jsonb_build_object('check_field', 'availability_semantics',
        'source_excerpt', 'No sample size was reported for the weight analysis.',
        'source_locator', 'Resultater', 'justification', 'Fraværene er ført som kilden sier.')
    ),
    p_source_quote => 'Weight change was 1.7 kg in the sertraline arm.'
  );
end;
$$;

insert into fixture (name, id) select 'ren', pg_temp.extract('Rent testartefakt i 670.');
reset role;
insert into fixture (name, id) select 'bundet', pg_temp.extract('Bundet testartefakt i 670.');
reset role;

-- Påstandsrevisjonen «bundet» hviler på.
insert into knowledge.claims (id, knowledge_type, topic_concept_id, subject_drug_id,
                              created_by_actor_id)
values ('67000000-0000-4000-8000-000000000031', 'evidence_synthesis',
        (select id from fixture where name = 'weight'),
        (select id from fixture where name = 'sertralin'),
        (select id from fixture where name = 'editor'));

insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
   comparator_kind, uncertainty_summary, created_by_actor_id)
values ('67000000-0000-4000-8000-000000000032', '67000000-0000-4000-8000-000000000031',
        1, 'evidence_synthesis', (select id from fixture where name = 'sertralin'),
        'Testpåstand for 670.', 'Gjelder prøven i 670.', 'none',
        'Ett funn fra én prøve.', (select id from fixture where name = 'editor'));

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness, relevance_note,
   created_by_actor_id)
values ('67000000-0000-4000-8000-000000000032', (select id from fixture where name = 'bundet'),
        'supports', 'direct', 'Funnet rapporterer utfallet påstanden gjelder.',
        (select id from fixture where name = 'editor'));

-- ===========================================================================
-- Del 3 — Avvisningene, prøvd som redaktør
--
-- Ingenting skal slettes av noen av dem, og det kontrolleres etterpå.
-- ===========================================================================
select set_config('request.jwt.claims',
                  format('{"sub":"%s"}', (select u.id from auth.users u
                                          join provenance.actors a on a.auth_user_id = u.id
                                          where a.actor_key = 'human:peder-holman')), true);

select throws_ok(
  format(
    $$select knowledge.discard_unpublished_extraction_artifacts(array['%s']::uuid[], '  ')$$,
    (select id from fixture where name = 'ren')),
  '22023', 'Fjerningen mangler en begrunnelse, og da kan den ikke registreres.',
  'en fjerning uten begrunnelse avvises: begrunnelsen er det som gjør den rapporterbar'
);

select throws_ok(
  $$select knowledge.discard_unpublished_extraction_artifacts(array[]::uuid[], 'Prøve.')$$,
  '22023', 'Ingen evidensfunn er oppgitt.',
  'en tom liste avvises — veien kan ikke kalles med et predikat, og kan ikke feie'
);

select throws_ok(
  format(
    $$select knowledge.discard_unpublished_extraction_artifacts(array['%s','%s']::uuid[], 'Prøve.')$$,
    (select id from fixture where name = 'ren'), (select id from fixture where name = 'ren')),
  '22023', 'Listen inneholder samme evidensfunn mer enn én gang.',
  'en dublett avvises: da er listen ikke den gjennomgåtte listen'
);

select throws_ok(
  format(
    $$select knowledge.discard_unpublished_extraction_artifacts(array['%s','%s']::uuid[], 'Prøve.')$$,
    (select id from fixture where name = 'ren'),
    '67000000-0000-4000-8000-0000000000ff'),
  '22023', null,
  'en id som ikke finnes avvises, og tar hele kallet med seg'
);

-- Kjernen: et funn en påstandsrevisjon hviler på, fjernes ikke — og det stopper
-- kallet også for det rene funnet i den samme listen. En delvis reset ville
-- etterlatt en tilstand ingen bestemte.
select throws_ok(
  format(
    $$select knowledge.discard_unpublished_extraction_artifacts(array['%s','%s']::uuid[], 'Prøve.')$$,
    (select id from fixture where name = 'ren'), (select id from fixture where name = 'bundet')),
  '23001', null,
  'et funn som bærer en påstandsrevisjon, fjernes ikke — publisert eller ikke'
);

select is(
  (select count(*) from knowledge.evidence_items e
   where e.id in (select id from fixture where name in ('ren', 'bundet'))),
  2::bigint,
  'ingen av de avviste kallene slettet noe'
);

-- Vernet står igjen etter en avbrutt kjøring. Uten dette ville en avvisning
-- kunnet etterlate en tabell uten sin append-only-trigger.
select is(
  (select array_agg(t.tgenabled::text order by t.tgname)
   from pg_trigger t
   where t.tgname in ('evidence_items_reject_mutation',
                      'evidence_field_groundings_reject_mutation',
                      'evidence_verifications_reject_mutation')),
  array['O', 'O', 'O'],
  'append-only-vernet er påslått etter en avvist fjerning'
);

-- ===========================================================================
-- Del 4 — En menneskelig kontrollert rad fjernes ikke
-- ===========================================================================
-- Utfallet er `needs_correction`, som er en helt reell menneskelig kontroll: en
-- bekreftelse krever i tillegg at maskinen først har bevist at utdragene står
-- ordrett i kilden, og det er en annen regel enn den som prøves her.
select lives_ok(
  format(
    $$select api.register_human_extraction_verification(
        '%s',
        workflow.evidence_extraction_digest('%s'),
        'needs_correction', 'original_source', array['outcome'], 'Prøve i 670.',
        'Utdraget dekker ikke verdien.')$$,
    (select id from fixture where name = 'ren'), (select id from fixture where name = 'ren')),
  'den menneskelige kontrollen registreres gjennom sin egen skrivevei'
);

select throws_ok(
  format(
    $$select knowledge.discard_unpublished_extraction_artifacts(array['%s']::uuid[], 'Prøve.')$$,
    (select id from fixture where name = 'ren')),
  '23001', null,
  'et menneskelig kildekontrollert funn fjernes ikke: kontrollen er en faglig handling med en ansvarlig bak'
);

-- ===========================================================================
-- Del 5 — Den lykkede stien
--
-- Et nytt, rent funn, fjernet med sitt eget kall.
-- ===========================================================================
insert into fixture (name, id) select 'engangs', pg_temp.extract('Engangsartefakt i 670.');
reset role;

select set_config('request.jwt.claims',
                  format('{"sub":"%s"}', (select u.id from auth.users u
                                          join provenance.actors a on a.auth_user_id = u.id
                                          where a.actor_key = 'human:peder-holman')), true);

create temporary table utfall (label text primary key, value jsonb) on commit drop;
insert into utfall (label, value)
select 'engangs', knowledge.discard_unpublished_extraction_artifacts(
  array[(select id from fixture where name = 'engangs')],
  'Testartefakt fra den forrige oppskriften, fjernet før ny kjøring (issue #84).');

select is(
  (select jsonb_array_length(value -> 'discarded_evidence_item_ids') from utfall
   where label = 'engangs'),
  1,
  'kallet svarer med hvilke funn som ble fjernet'
);

select is(
  (select count(*) from knowledge.evidence_items e
   where e.id = (select id from fixture where name = 'engangs')),
  0::bigint,
  'evidensfunnet er borte'
);

select is(
  (select count(*) from knowledge.evidence_field_groundings g
   where g.evidence_item_id = (select id from fixture where name = 'engangs')),
  0::bigint,
  'forankringen er borte med det'
);

select is(
  (select count(*) from workflow.evidence_verifications ev
   where ev.evidence_item_id = (select id from fixture where name = 'engangs')),
  0::bigint,
  'og den maskinelle kontrollen av det'
);

-- Det som IKKE røres. En kildeversjon er et øyeblikksbilde med verdi uavhengig
-- av hvilke funn som ble laget av den, og en agentkjøring er en utført kjøring.
select is(
  (select count(*) from knowledge.source_versions sv
   where sv.id = '67000000-0000-4000-8000-000000000021'),
  1::bigint,
  'kildeversjonen står: den er ikke slettet for å få en fremmednøkkel til å gå opp'
);

select is(
  (select count(*) from knowledge.sources s
   where s.id = '67000000-0000-4000-8000-000000000001'),
  1::bigint,
  'kilden står'
);

select is(
  (select count(*) from provenance.agent_runs ar
   where ar.id = (select id from run where label = 'extraction')),
  1::bigint,
  'agentkjøringen står: den er en utført kjøring, ikke en egenskap ved raden den skrev'
);

-- Sporet. Det er raden som er borte, ikke nedtegnelsen av at den fantes.
select is(
  (select count(*) from audit.events e
   where e.object_id = (select id from fixture where name = 'engangs')
     and e.operation = 'extraction_artifact_discarded'),
  1::bigint,
  'fjerningen har sin auditrad'
);

select is(
  (select e.object_schema || '.' || e.object_table from audit.events e
   where e.object_id = (select id from fixture where name = 'engangs')
     and e.operation = 'extraction_artifact_discarded'),
  'knowledge.evidence_items',
  'auditraden peker på tabellen raden lå i, avledet av operasjonen'
);

select is(
  (select e.actor_id from audit.events e
   where e.object_id = (select id from fixture where name = 'engangs')
     and e.operation = 'extraction_artifact_discarded'),
  (select id from fixture where name = 'editor'),
  'fjerningen er attribuert til den som bestemte den, ikke til databasen'
);

select ok(
  (select e.old_revision_or_snapshot -> 'dossier' -> 'extraction' ->> 'outcome_detail'
   from audit.events e
   where e.object_id = (select id from fixture where name = 'engangs')
     and e.operation = 'extraction_artifact_discarded') = 'Engangsartefakt i 670.',
  'øyeblikksbildet bærer hele kontrollgrunnlaget: det som ble fjernet, kan fortsatt leses'
);

select ok(
  (select e.new_revision_or_snapshot is null from audit.events e
   where e.object_id = (select id from fixture where name = 'engangs')
     and e.operation = 'extraction_artifact_discarded'),
  'og ingen ny tilstand, fordi det ikke finnes en'
);

select isnt(
  (select e.reason from audit.events e
   where e.object_id = (select id from fixture where name = 'engangs')
     and e.operation = 'extraction_artifact_discarded'),
  null,
  'begrunnelsen står i sporet'
);

-- Vernet er på igjen etter en lykket fjerning, og er fortsatt fasiten for
-- enhver annen skrivevei.
select is(
  (select array_agg(t.tgenabled::text order by t.tgname)
   from pg_trigger t
   where t.tgname in ('evidence_items_reject_mutation',
                      'evidence_field_groundings_reject_mutation',
                      'evidence_verifications_reject_mutation')),
  array['O', 'O', 'O'],
  'append-only-vernet er påslått etter en lykket fjerning'
);

select set_config('request.jwt.claims', '', true);

select throws_ok(
  format(
    $$delete from knowledge.evidence_items where id = '%s'$$,
    (select id from fixture where name = 'bundet')),
  '23001', null,
  'en vanlig DELETE er fortsatt avvist: veien over er den eneste, og den er guardet'
);

-- ===========================================================================
-- Del 6 — Uten redaktørrolle
-- ===========================================================================
select throws_ok(
  format(
    $$select knowledge.discard_unpublished_extraction_artifacts(array['%s']::uuid[], 'Prøve.')$$,
    (select id from fixture where name = 'bundet')),
  '42501', null,
  'uten en autorisert redaktøridentitet fjernes ingenting, selv med eiertilgang til databasen'
);

select finish();

rollback;
