-- Migrasjon 005ah — den guardede veien til å fjerne et testartefakt på
-- påstandssiden.
--
-- Søsteren til 670. Der prøvde vi veien som fjerner evidensfunnet; her prøves
-- den som fjerner påstanden som ble laget av det. De to må holde det samme
-- samtidig:
--
--   1. at veien **finnes** og faktisk fjerner hele opphenget — revisjon, lenke,
--      vurdering, claim-kontroll og sitat — med et spor etter seg, og uten å
--      røre evidensfunnet, kilden, kildeversjonen eller auditraden,
--   2. at den er **stengt** for alt annet: for hver klientrolle, for en kaller
--      uten redaktørrolle, for en liste som ikke er gjennomgått, og for hver
--      påstand som har kommet lenger i livssyklusen.
--
-- Den siste er den som betyr noe. En reset som kunne ta en publisert påstand
-- eller en menneskelig kontrollert en, ville vært en vei fra «pipelinen bygges
-- fortsatt» til «klinisk historikk kan forsvinne».
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(35);

-- ===========================================================================
-- Del 1 — Kontrakten og stengslene
-- ===========================================================================
select has_function(
  'knowledge', 'discard_unpublished_claim_artifacts',
  'knowledge.discard_unpublished_claim_artifacts() finnes'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'knowledge.discard_unpublished_claim_artifacts(uuid[],text)'::regprocedure),
  'veien er SECURITY DEFINER: den må kunne slå av og på tabellenes eget vern'
);

select ok(
  (select exists (
     select 1
     from pg_proc p, unnest(coalesce(p.proconfig, array[]::text[])) as cfg
     where p.oid = 'knowledge.discard_unpublished_claim_artifacts(uuid[],text)'::regprocedure
       and cfg like 'search_path=%'
   )),
  'veien har tomt search_path'
);

-- Den viktigste raden i filen: ingen klientrolle kan nå den.
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'knowledge.discard_unpublished_claim_artifacts(uuid[],text)', 'EXECUTE')
  $$,
  'ingen klientrolle kan kalle fjerningen — verken anon, authenticated, service_role eller PUBLIC'
);

select ok(
  (select 'claim_artifact_discarded' = any (
     select e.enumlabel from pg_enum e
     join pg_type t on t.oid = e.enumtypid
     where t.typname = 'event_operation'
   )),
  'audit.event_operation kjenner claim_artifact_discarded'
);

-- Rekkefølgen lås-før-kontroll, prøvd på funksjonskroppen. Den kan ikke
-- observeres fra én økt: en lås tatt i en undertransaksjon slippes når den
-- rulles tilbake, og en avvisning er nettopp det. Uten rekkefølgen kunne en
-- publisering commitet mellom kontrollen og slettingen blitt lest som
-- fraværende og så fjernet.
select ok(
  (select position('lock table knowledge.claims in access exclusive mode' in p.prosrc) > 0
      and position('lock table knowledge.claims in access exclusive mode' in p.prosrc)
        < position('current_published_revision_id is not null' in p.prosrc)
   from pg_proc p
   where p.oid = 'knowledge.discard_unpublished_claim_artifacts(uuid[],text)'::regprocedure),
  'tabellene låses før kontrollene leser dem, så kallet feiler lukket også under samtidighet'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- Tre påstander, hver med sitt eget evidensfunn registrert gjennom den ekte
-- ekstraksjonsveien:
--
--   ren          en påstand ingen har kommet videre med
--   menneskelig  en påstand et menneske har kontrollert
--   besluttet    en påstand med en reviewbeslutning på funnet under seg
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid) on commit drop;
insert into fixture (name, id)
select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id)
select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
grant select on fixture to anon;

-- Kalleren er filens egen, av samme grunn som i 670: den registrerte redaktøren
-- har ingen brukerkonto i en lokal stack eller i CI (migrasjon 005b), og en
-- jwt-claim bygget av den ville vært tom.
insert into auth.users (id, email) values
  ('68000000-0000-4000-8000-0000000000a0', 'fjerning-680-a@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac680000-0000-4000-8000-0000000000a0', 'human', 'human:fjerning-680-a', 'Kaller A',
   'Redaktør og reviewer, for 680.', '68000000-0000-4000-8000-0000000000a0');

insert into fixture (name, id) values ('editor', 'ac680000-0000-4000-8000-0000000000a0');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('68000000-0000-4000-8000-0000000000a0', 'editor', null, now() - interval '1 year',
   'ac680000-0000-4000-8000-0000000000a0', 'Gyldig editor-tildeling for kaller A i 680.'),
  ('68000000-0000-4000-8000-0000000000a0', 'reviewer', null, now() - interval '1 year',
   'ac680000-0000-4000-8000-0000000000a0', 'Gyldig reviewer-tildeling for kaller A i 680.');

-- Den menneskelige kontrolløren er en *annen* aktør enn den som laget
-- revisjonen: claim_verifications_separate_actor_check krever det, og den
-- oppdelingen er selve poenget med en kontroll.
insert into auth.users (id, email) values
  ('68000000-0000-4000-8000-0000000000c0', 'fjerning-680-c@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac680000-0000-4000-8000-0000000000c0', 'human', 'human:fjerning-680-c', 'Kontrollør C',
   'Menneskelig kontrollør, for 680.', '68000000-0000-4000-8000-0000000000c0');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('68000000-0000-4000-8000-0000000000c0', 'reviewer', null, now() - interval '1 year',
   'ac680000-0000-4000-8000-0000000000a0', 'Gyldig reviewer-tildeling for kontrollør C i 680.');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('68000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 680',
        'Testforfatter 680', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation,
   retrieved_by_actor_id)
values ('68000000-0000-4000-8000-000000000021', '68000000-0000-4000-8000-000000000001',
        now(), 'https://eksempel.invalid/680', 'sha256:' || repeat('8', 64), 'full_text',
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
  p_model_version := '2026-09-21', p_prompt_template_version := 'evidence-extraction/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_source_version_id := '68000000-0000-4000-8000-000000000021',
  p_input_manifest := jsonb_build_object('source_version_ids',
    array['68000000-0000-4000-8000-000000000021'])
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
    p_source_id => '68000000-0000-4000-8000-000000000001',
    p_source_version_id => '68000000-0000-4000-8000-000000000021',
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
    p_source_locator => 'Avsnitt for 680',
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

insert into fixture (name, id) select 'funn_ren', pg_temp.extract('Rent testartefakt i 680.');
reset role;
insert into fixture (name, id) select 'funn_menneskelig', pg_temp.extract('Menneskelig i 680.');
reset role;
insert into fixture (name, id) select 'funn_besluttet', pg_temp.extract('Besluttet i 680.');
reset role;

-- Én påstand med én revisjon og én lenke per funn. Bygget direkte mot tabellene,
-- som i 670: det som prøves her, er fjerningen, ikke skriveveien inn.
create function pg_temp.build_claim(p_label text, p_claim uuid, p_revision uuid, p_item uuid)
returns void language plpgsql as $$
begin
  insert into knowledge.claims (id, knowledge_type, topic_concept_id, subject_drug_id,
                                created_by_actor_id)
  values (p_claim, 'evidence_synthesis',
          (select id from fixture where name = 'weight'),
          (select id from fixture where name = 'sertralin'),
          (select id from fixture where name = 'editor'));

  insert into knowledge.claim_revisions
    (id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
     comparator_kind, uncertainty_summary, created_by_actor_id)
  values (p_revision, p_claim, 1, 'evidence_synthesis',
          (select id from fixture where name = 'sertralin'),
          format('Testpåstand %s for 680.', p_label), 'Gjelder prøven i 680.', 'none',
          'Ett funn fra én prøve.', (select id from fixture where name = 'editor'));

  insert into knowledge.claim_evidence_links
    (claim_revision_id, evidence_item_id, relationship_type, directness, relevance_note,
     created_by_actor_id)
  values (p_revision, p_item, 'supports', 'direct',
          'Funnet rapporterer utfallet påstanden gjelder.',
          (select id from fixture where name = 'editor'));

  insert into fixture (name, id) values (p_label, p_claim);
end;
$$;

select pg_temp.build_claim('ren', '68000000-0000-4000-8000-000000000031',
                           '68000000-0000-4000-8000-000000000041',
                           (select id from fixture where name = 'funn_ren'));
select pg_temp.build_claim('menneskelig', '68000000-0000-4000-8000-000000000032',
                           '68000000-0000-4000-8000-000000000042',
                           (select id from fixture where name = 'funn_menneskelig'));
select pg_temp.build_claim('besluttet', '68000000-0000-4000-8000-000000000033',
                           '68000000-0000-4000-8000-000000000043',
                           (select id from fixture where name = 'funn_besluttet'));

-- Evidensvurderingen på den rene lenken, slik at den lykkede stien faktisk har
-- en å fjerne.
insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level, risk_of_bias,
   inconsistency, indirectness, imprecision, publication_bias, rationale, assessed_at,
   created_by_actor_id)
values ('68000000-0000-4000-8000-000000000041', 'evidence_synthesis', 'grade', 'low',
        'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
        'Én prøve, ett funn.', now(), (select id from fixture where name = 'editor'));

-- Claim-kontroll av en agent på den rene påstanden: den skal ikke stoppe noe.
-- Det er *menneskelige* kontroller som er faglige handlinger med en ansvarlig
-- bak, og bare de.
insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   findings, rationale, verified_at)
select '68000000-0000-4000-8000-000000000041',
       (select id from fixture where name = 'editor'),
       a.id, 'uncertain', 'derived_summary', 'not_assessable', 'not_assessable',
       'not_assessable', 'not_assessable', 'not_assessable', 'not_assessable',
       'not_assessable', 'Ingen av punktene lot seg bedømme av sammendraget.', 'Maskinell kontroll i 680.', now()
from provenance.actors a
where a.actor_key = 'agent:citation-support-verification';

insert into workflow.claim_verification_citations
  (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
   source_access, relationship_supported, finding)
select cv.id, cv.claim_revision_id, l.id, l.evidence_item_id,
       'derived_summary', 'not_assessable',
       'Sammendraget bærer ikke relasjonen påstanden hviler på.'
from workflow.claim_verifications cv
join knowledge.claim_evidence_links l on l.claim_revision_id = cv.claim_revision_id
where cv.claim_revision_id = '68000000-0000-4000-8000-000000000041';

-- Den menneskelige kontrollen, på sin egen påstand.
insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   findings, rationale, verified_at)
values ('68000000-0000-4000-8000-000000000042',
        (select id from fixture where name = 'editor'),
        'ac680000-0000-4000-8000-0000000000c0',
        'needs_correction', 'original_source', 'deviation', 'not_assessable',
        'not_assessable', 'not_assessable', 'not_assessable', 'not_assessable',
        'not_assessable', 'Kildestøtten avviker fra påstanden.', 'Menneskelig kontroll i 680.', now());

-- Kontrollen må si hvilke evidenslenker den kontrollerte — én rad per lenke på
-- revisjonen (workflow.assert_claim_verification_complete). Det gjelder også den
-- menneskelige.
insert into workflow.claim_verification_citations
  (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
   source_access, relationship_supported, finding)
select cv.id, cv.claim_revision_id, l.id, l.evidence_item_id,
       'original_source', 'deviation',
       'Kilden bærer ikke retningen påstanden oppgir.'
from workflow.claim_verifications cv
join knowledge.claim_evidence_links l on l.claim_revision_id = cv.claim_revision_id
where cv.claim_revision_id = '68000000-0000-4000-8000-000000000042';

-- Reviewbeslutningen, på funnet under den tredje påstanden.
insert into workflow.review_decisions
  (evidence_item_id, evidence_item_creator_actor_id, review_type, decision, rationale,
   reviewer_actor_id, reviewer_actor_type, decided_at)
select ei.id, ei.created_by_actor_id, 'extraction_withdrawal', 'extraction_upheld',
       'Beslutning i 680.', (select id from fixture where name = 'editor'), 'human', now()
from knowledge.evidence_items ei
where ei.id = (select id from fixture where name = 'funn_besluttet');

-- Fikstureringen legger igjen utsatte kontrollhendelser (claim_verifications har
-- en CONSTRAINT TRIGGER som er utsatt til commit). De tømmes her, slik at det
-- som prøves nedenfor, er fjerningen — og ikke en kø fiksturen etterlot.
set constraints all immediate;

-- ===========================================================================
-- Del 3 — Avvisningene, prøvd som redaktør
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"68000000-0000-4000-8000-0000000000a0"}', true);

select throws_ok(
  format(
    $$select knowledge.discard_unpublished_claim_artifacts(array['%s']::uuid[], '  ')$$,
    (select id from fixture where name = 'ren')),
  '22023', 'Fjerningen mangler en begrunnelse, og da kan den ikke registreres.',
  'en fjerning uten begrunnelse avvises: begrunnelsen er det som gjør den rapporterbar'
);

select throws_ok(
  $$select knowledge.discard_unpublished_claim_artifacts(array[]::uuid[], 'Prøve.')$$,
  '22023', 'Ingen påstander er oppgitt.',
  'en tom liste avvises: veien kan ikke feie'
);

select throws_ok(
  format(
    $$select knowledge.discard_unpublished_claim_artifacts(array['%s','%s']::uuid[], 'Prøve.')$$,
    (select id from fixture where name = 'ren'), (select id from fixture where name = 'ren')),
  '22023', 'Listen inneholder samme påstand mer enn én gang.',
  'en dublett avvises: listen er da ikke den gjennomgåtte listen'
);

select throws_ok(
  format(
    $$select knowledge.discard_unpublished_claim_artifacts(array['%s','%s']::uuid[], 'Prøve.')$$,
    (select id from fixture where name = 'ren'),
    '68000000-0000-4000-8000-0000000000ff'),
  '22023', null,
  'en id som ikke finnes avvises, og tar hele kallet med seg'
);

-- Kjernen: en menneskelig kontrollert påstand fjernes ikke, og det stopper
-- kallet også for den rene påstanden i den samme listen.
select throws_ok(
  format(
    $$select knowledge.discard_unpublished_claim_artifacts(array['%s','%s']::uuid[], 'Prøve.')$$,
    (select id from fixture where name = 'ren'),
    (select id from fixture where name = 'menneskelig')),
  '23001', null,
  'en menneskelig kontrollert påstand fjernes ikke: kontrollen er en faglig handling med en ansvarlig bak'
);

select throws_ok(
  format(
    $$select knowledge.discard_unpublished_claim_artifacts(array['%s']::uuid[], 'Prøve.')$$,
    (select id from fixture where name = 'besluttet')),
  '23001', null,
  'en påstand med en reviewbeslutning på funnet under seg fjernes ikke'
);

select is(
  (select count(*) from knowledge.claims c
   where c.id in (select id from fixture where name in ('ren', 'menneskelig', 'besluttet'))),
  3::bigint,
  'ingen av de avviste kallene fjernet noe'
);

-- Vernet står igjen etter en avbrutt kjøring.
select is(
  (select array_agg(t.tgenabled::text order by t.tgname)
   from pg_trigger t
   where t.tgname in ('claim_revisions_reject_mutation',
                      'claim_evidence_links_reject_mutation',
                      'evidence_assessments_reject_mutation',
                      'claim_verifications_reject_mutation',
                      'claim_verification_citations_reject_mutation')),
  array['O', 'O', 'O', 'O', 'O'],
  'append-only-vernet er påslått etter en avvist fjerning'
);

-- ===========================================================================
-- Del 4 — En publisert påstand fjernes ikke
-- ===========================================================================
-- Publiseringen settes direkte, fordi det som prøves er kontrollen i
-- fjerningen — ikke publiseringsgaten, som har sine egne prøver.
update knowledge.claims
set current_published_revision_id = '68000000-0000-4000-8000-000000000041'
where id = '68000000-0000-4000-8000-000000000031';

select throws_ok(
  format(
    $$select knowledge.discard_unpublished_claim_artifacts(array['%s']::uuid[], 'Prøve.')$$,
    (select id from fixture where name = 'ren')),
  '23001', null,
  'en publisert påstand fjernes ikke: den er klinisk historikk og trekkes tilbake med et spor'
);

update knowledge.claims
set current_published_revision_id = null
where id = '68000000-0000-4000-8000-000000000031';

-- ===========================================================================
-- Del 5 — Den lykkede stien
-- ===========================================================================
create temporary table utfall (label text primary key, value jsonb) on commit drop;
insert into utfall (label, value)
select 'ren', knowledge.discard_unpublished_claim_artifacts(
  array[(select id from fixture where name = 'ren')],
  'Testartefakt fra den foreløpige pipelinen, issue #84.');

select is(
  (select value -> 'deleted_claim_revisions' from utfall where label = 'ren'),
  to_jsonb(1),
  'kallet melder at én påstandsrevisjon ble fjernet'
);

select is(
  (select value -> 'deleted_evidence_links' from utfall where label = 'ren'),
  to_jsonb(1),
  'og at påstandslenken ble fjernet'
);

select is(
  (select value -> 'deleted_evidence_assessments' from utfall where label = 'ren'),
  to_jsonb(1),
  'og at evidensvurderingen ble fjernet'
);

select is(
  (select value -> 'deleted_claim_verifications' from utfall where label = 'ren'),
  to_jsonb(1),
  'og at claim-kontrollen ble fjernet'
);

select is(
  (select value -> 'deleted_claim_verification_citations' from utfall where label = 'ren'),
  to_jsonb(1),
  'og at sitatet ble fjernet'
);

select is_empty(
  $$select 1 from knowledge.claims c
    where c.id = '68000000-0000-4000-8000-000000000031'$$,
  'påstanden er borte'
);

select is_empty(
  $$select 1 from knowledge.claim_revisions cr
    where cr.id = '68000000-0000-4000-8000-000000000041'$$,
  'revisjonen er borte'
);

select is_empty(
  $$select 1 from knowledge.claim_evidence_links l
    where l.claim_revision_id = '68000000-0000-4000-8000-000000000041'$$,
  'påstandslenken er borte'
);

select is_empty(
  $$select 1 from workflow.claim_verifications cv
    where cv.claim_revision_id = '68000000-0000-4000-8000-000000000041'$$,
  'claim-kontrollen er borte'
);

-- Det som ikke skal røres. En kildeversjon er et øyeblikksbilde med verdi
-- uavhengig av hvilke påstander som ble laget av funnene fra den.
select is(
  (select count(*) from knowledge.evidence_items ei
   where ei.id = (select id from fixture where name = 'funn_ren')),
  1::bigint,
  'evidensfunnet står urørt: denne veien rører ikke 005af sine tabeller'
);

select is(
  (select count(*) from knowledge.source_versions sv
   where sv.id = '68000000-0000-4000-8000-000000000021'),
  1::bigint,
  'kildeversjonen står urørt'
);

select is(
  (select count(*) from knowledge.evidence_field_groundings g
   where g.evidence_item_id = (select id from fixture where name = 'funn_ren')),
  4::bigint,
  'forankringene på funnet står urørt'
);

-- ===========================================================================
-- Del 6 — Sporet
-- ===========================================================================
select is(
  (select count(*) from audit.events e
   where e.operation = 'claim_artifact_discarded'
     and e.object_id = '68000000-0000-4000-8000-000000000031'),
  1::bigint,
  'fjerningen skrev én auditrad for påstanden'
);

select is(
  (select e.object_schema || '.' || e.object_table from audit.events e
   where e.operation = 'claim_artifact_discarded'
     and e.object_id = '68000000-0000-4000-8000-000000000031'),
  'knowledge.claims',
  'auditraden peker på knowledge.claims, avledet av operasjonen'
);

select is(
  (select e.actor_id from audit.events e
   where e.operation = 'claim_artifact_discarded'
     and e.object_id = '68000000-0000-4000-8000-000000000031'),
  'ac680000-0000-4000-8000-0000000000a0'::uuid,
  'auditraden navngir den som bestemte fjerningen, ikke «databasen»'
);

select is(
  (select e.reason from audit.events e
   where e.operation = 'claim_artifact_discarded'
     and e.object_id = '68000000-0000-4000-8000-000000000031'),
  'Testartefakt fra den foreløpige pipelinen, issue #84.',
  'begrunnelsen står i sporet'
);

select ok(
  (select e.new_revision_or_snapshot is null
      and e.old_revision_or_snapshot -> 'claim' is not null
      and jsonb_array_length(e.old_revision_or_snapshot -> 'revisions') = 1
      and jsonb_array_length(e.old_revision_or_snapshot -> 'evidence_links') = 1
      and jsonb_array_length(e.old_revision_or_snapshot -> 'evidence_assessments') = 1
      and jsonb_array_length(e.old_revision_or_snapshot -> 'claim_verifications') = 1
      and jsonb_array_length(e.old_revision_or_snapshot -> 'claim_verification_citations') = 1
   from audit.events e
   where e.operation = 'claim_artifact_discarded'
     and e.object_id = '68000000-0000-4000-8000-000000000031'),
  'øyeblikksbildet bærer hele opphenget som ble fjernet, og det finnes ingen ny tilstand'
);

-- ===========================================================================
-- Del 7 — Stengt for alt annet
-- ===========================================================================
select is(
  (select array_agg(t.tgenabled::text order by t.tgname)
   from pg_trigger t
   where t.tgname in ('claim_revisions_reject_mutation',
                      'claim_evidence_links_reject_mutation',
                      'evidence_assessments_reject_mutation',
                      'claim_verifications_reject_mutation',
                      'claim_verification_citations_reject_mutation')),
  array['O', 'O', 'O', 'O', 'O'],
  'append-only-vernet er påslått igjen etter en lykket fjerning'
);

select throws_ok(
  $$delete from knowledge.claim_revisions
    where id = '68000000-0000-4000-8000-000000000042'$$,
  '23001', null,
  'en vanlig DELETE avvises fortsatt: vernet gjelder alle andre skriveveier'
);

-- Uten redaktørrolle er veien stengt, selv for en registrert aktør.
insert into auth.users (id, email) values
  ('68000000-0000-4000-8000-0000000000b0', 'fjerning-680-b@test.invalid');
insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac680000-0000-4000-8000-0000000000b0', 'human', 'human:fjerning-680-b', 'Kaller B',
   'Uten redaktørrolle, for 680.', '68000000-0000-4000-8000-0000000000b0');

select set_config('request.jwt.claims',
                  '{"sub":"68000000-0000-4000-8000-0000000000b0"}', true);

select throws_ok(
  format(
    $$select knowledge.discard_unpublished_claim_artifacts(array['%s']::uuid[], 'Prøve.')$$,
    (select id from fixture where name = 'menneskelig')),
  '42501', null,
  'en kaller uten redaktørrolle kan ikke fjerne noe, selv om aktøren er registrert'
);

select * from finish();
rollback;
