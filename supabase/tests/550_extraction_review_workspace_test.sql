-- Migrasjon 005r og 005t — arbeidsflaten for den menneskelige
-- ekstraksjonskontrollen, og at den viser nøyaktig det maskinen leser.
--
-- Speilbildet av 520_claim_review_workspace_test.sql for evidensfunn. Filen
-- dekker kontrakten, radgrensen (køens avgrensning og det direkte oppslaget),
-- hva flaten faktisk svarer med, og den avgjørende assertionen: at
-- ekstraksjonsverifikatorens lesegrunnlag er *nøyaktig* det samme uttrykket
-- flaten viser — én formulering av kildegrunnlaget, ikke to.
--
-- I tillegg dekker den at feltdekningen flaten viser er publiseringsgatens egne
-- funksjoner, og ikke en kopi av dem.
--
-- SQLSTATE 42501 = insufficient_privilege, P0002 = no_data_found.
begin;

create extension if not exists pgtap with schema extensions;

select plan(26);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'extraction_review_workspace', 'api.extraction_review_workspace() finnes'
);
select has_function(
  'workflow', 'evidence_extraction_dossier', 'workflow.evidence_extraction_dossier() finnes'
);
select has_function(
  'workflow', 'evidence_verification_history', 'workflow.evidence_verification_history() finnes'
);
select has_function(
  'workflow', 'covered_check_fields', 'workflow.covered_check_fields() finnes'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.extraction_review_workspace(uuid)'::regprocedure),
  'api.extraction_review_workspace() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name, 'api.extraction_review_workspace(uuid)'::regprocedure, 'execute')
  $$,
  'api.extraction_review_workspace() er kjørbar bare for authenticated'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- Tre evidensfunn på «vektendring» og ett på et annet endepunkt, slik at både
-- køens avgrensning og radgrensen for en avgrenset tildeling kan prøves.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'extraction_verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';

insert into catalog.clinical_concepts (id, canonical_label, concept_type)
values ('55000000-0000-4000-8000-0000000000f0', 'søvnkvalitet for 550', 'outcome');

insert into auth.users (id, instance_id, aud, role, email)
select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u.email
from (values
  ('55000000-0000-4000-8000-0000000000d0'::uuid, 'd550@example.test'),
  ('55000000-0000-4000-8000-0000000000f1'::uuid, 'f550@example.test'),
  ('55000000-0000-4000-8000-000000000080'::uuid, 'h550@example.test')
) as u(id, email);

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values
  ('55000000-0000-4000-8000-0000000000d1', 'human:d-550', 'human', 'Kaller D 550',
   'Editor uten reviewer-rolle, for 550.', '55000000-0000-4000-8000-0000000000d0'),
  ('55000000-0000-4000-8000-0000000000f2', 'human:f-550', 'human', 'Kaller F 550',
   'Avgrenset reviewer for et annet endepunkt, for 550.', '55000000-0000-4000-8000-0000000000f1'),
  ('55000000-0000-4000-8000-000000000081', 'human:h-550', 'human', 'Kaller H 550',
   'Uavgrenset reviewer, for 550.', '55000000-0000-4000-8000-000000000080');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('55000000-0000-4000-8000-0000000000d0', 'editor', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Tildeling for kaller D i 550.'),
  ('55000000-0000-4000-8000-0000000000f1', 'reviewer', '55000000-0000-4000-8000-0000000000f0',
   now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Tildeling for kaller F i 550.'),
  ('55000000-0000-4000-8000-000000000080', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Tildeling for kaller H i 550.');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('55000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 550',
        'Testforfatter 550', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
values ('55000000-0000-4000-8000-000000000021', '55000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/550-a', 'sha256:' || repeat('a', 64),
        (select id from fixture where name = 'extractor'));

create function pg_temp.make_evidence(p_id uuid, p_outcome uuid, p_author uuid, p_note text)
  returns void language sql as $$
  insert into knowledge.evidence_items (
    id, source_id, source_version_id, design_code, population_availability, population_detail,
    sample_size_availability, intervention_drug_id, comparator_kind,
    outcome_concept_id, outcome_detail, timepoint_availability,
    reported_direction, estimate_availability, confidence_interval_availability,
    source_locator, extraction_method, created_by_actor_id
  )
  values (
    p_id, '55000000-0000-4000-8000-000000000001', '55000000-0000-4000-8000-000000000021',
    'randomized_controlled_trial', 'not_reported', 'Prøve i 550.',
    'not_reported', (select id from fixture where name = 'sertralin'), 'none',
    p_outcome, p_note, 'not_reported', 'increase', 'not_reported', 'not_reported',
    'Avsnitt for 550', 'ai_assisted', p_author
  );
$$;

-- E1: vanlig funn på vektendring, laget av ekstraksjonsagenten.
select pg_temp.make_evidence('55000000-0000-4000-8000-000000000011',
  (select id from fixture where name = 'weight'),
  (select id from fixture where name = 'extractor'), 'Første funn, for 550.');
-- E2: laget av reviewer H selv — skal ikke stå i H sin kø.
select pg_temp.make_evidence('55000000-0000-4000-8000-000000000012',
  (select id from fixture where name = 'weight'),
  '55000000-0000-4000-8000-000000000081', 'Andre funn, laget av H selv, for 550.');
-- E3: på et annet endepunkt — skal ikke stå i en tildeling avgrenset til vektendring.
select pg_temp.make_evidence('55000000-0000-4000-8000-000000000013',
  '55000000-0000-4000-8000-0000000000f0',
  (select id from fixture where name = 'extractor'), 'Tredje funn, annet endepunkt, for 550.');
-- E4: allerede kontrollert av H — skal ikke stå i H sin kø.
select pg_temp.make_evidence('55000000-0000-4000-8000-000000000014',
  (select id from fixture where name = 'weight'),
  (select id from fixture where name = 'extractor'), 'Fjerde funn, kontrollert av H, for 550.');

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
   outcome, source_access, checked_fields, findings, rationale, verified_at)
values ('55000000-0000-4000-8000-000000000014',
        (select id from fixture where name = 'extractor'),
        '55000000-0000-4000-8000-000000000081',
        'uncertain', 'original_source',
        array['source_locator']::workflow.evidence_check_field[],
        'Prøve i 550: kontrollen konkluderte ikke.',
        'Prøve i 550: H har allerede sett på dette funnet.', now());

-- En delkontroll fra agenten på E1, slik at dekningen er ufullstendig og
-- historikken har noe å vise.
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
   outcome, source_access, checked_fields, rationale, verified_at)
values ('55000000-0000-4000-8000-000000000011',
        (select id from fixture where name = 'extractor'),
        (select id from fixture where name = 'extraction_verifier'),
        'verified', 'verifiable_representation',
        array['source_locator', 'raw_extraction', 'outcome']::workflow.evidence_check_field[],
        'Prøve i 550: den deterministiske kontrollen bedømte en delmengde.', now());

-- En påstandsrevisjon som lenker til E1, slik at flaten kan vise hva funnet bærer.
with c as (
  insert into knowledge.claims
    (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  values ('55000000-0000-4000-8000-000000000051', 'evidence_synthesis',
          (select id from fixture where name = 'weight'),
          (select id from fixture where name = 'sertralin'),
          (select id from fixture where name = 'synthesis'))
  returning id, knowledge_type, subject_drug_id, created_by_actor_id
)
insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
select '55000000-0000-4000-8000-000000000031', c.id, 1, c.knowledge_type, c.subject_drug_id,
       'Testpåstand for 550.', 'Gjelder bare som testdata i 550.', 'none', 'increase',
       'Testusikkerhet.', c.created_by_actor_id
from c;

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('55000000-0000-4000-8000-000000000041', '55000000-0000-4000-8000-000000000031',
        '55000000-0000-4000-8000-000000000011', 'supports', 'direct',
        'Lenke i 550.', (select id from fixture where name = 'synthesis'));

-- ===========================================================================
-- Del 3 — Radgrensen
-- ===========================================================================
create temporary table workspace (label text primary key, payload jsonb) on commit drop;
grant insert, select on workspace to authenticated;

-- D: editor uten reviewer-rolle
select set_config('request.jwt.claims',
                  '{"sub":"55000000-0000-4000-8000-0000000000d0"}', true);
set local role authenticated;
select throws_ok(
  $$select api.extraction_review_workspace()$$,
  '42501', 'Brukeren har ikke gyldig reviewer-rolle.',
  'en editor uten reviewer-rolle får ikke se køen i det hele tatt'
);
reset role;

-- F: avgrenset reviewer for et annet endepunkt
select set_config('request.jwt.claims',
                  '{"sub":"55000000-0000-4000-8000-0000000000f1"}', true);
set local role authenticated;
insert into workspace select 'f-kø', api.extraction_review_workspace();
select throws_ok(
  $$select api.extraction_review_workspace('55000000-0000-4000-8000-000000000011')$$,
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'en avgrenset tildeling gir ikke innsyn utenfor sitt eget endepunkt, heller ikke ved direkte oppslag'
);
reset role;

select results_eq(
  $$
    select item ->> 'evidence_item_id'
    from workspace, jsonb_array_elements(payload -> 'queue') as item
    where label = 'f-kø'
  $$,
  $$values ('55000000-0000-4000-8000-000000000013')$$,
  'en avgrenset reviewer ser bare funn om sitt eget endepunkt'
);

-- H: uavgrenset reviewer
select set_config('request.jwt.claims',
                  '{"sub":"55000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
insert into workspace select 'h-kø', api.extraction_review_workspace();
insert into workspace select 'h-e1', api.extraction_review_workspace('55000000-0000-4000-8000-000000000011');
select throws_ok(
  $$select api.extraction_review_workspace('55000000-0000-4000-8000-0000000000ff')$$,
  'P0002', $q$Evidensfunnet '55000000-0000-4000-8000-0000000000ff' finnes ikke.$q$,
  'et evidensfunn som ikke finnes gir en setning som sier nettopp det'
);
reset role;

select is(
  (select count(*)::integer
   from workspace, jsonb_array_elements(payload -> 'queue') as item
   where label = 'h-kø'
     and item ->> 'evidence_item_id' in (
       '55000000-0000-4000-8000-000000000012', '55000000-0000-4000-8000-000000000014')),
  0,
  'køen utelater både funn kalleren selv har laget og funn kalleren allerede har kontrollert'
);
select ok(
  (select bool_or(item ->> 'evidence_item_id' = '55000000-0000-4000-8000-000000000011')
   from workspace, jsonb_array_elements(payload -> 'queue') as item
   where label = 'h-kø'),
  'et funn en annen aktør har kontrollert står fortsatt i køen: to kontrollag er to aktører'
);

-- ===========================================================================
-- Del 4 — Hva køraden sier, og hva den ikke sier
-- ===========================================================================
create temporary table queue_row (payload jsonb) on commit drop;
insert into queue_row
select item
from workspace, jsonb_array_elements(payload -> 'queue') as item
where label = 'h-kø' and item ->> 'evidence_item_id' = '55000000-0000-4000-8000-000000000011';

select is(
  (select payload ->> 'current_extraction_verification_outcome' from queue_row),
  'verified',
  'køraden bærer utfallet av den gjeldende kontrollen'
);
select is(
  (select item ->> 'current_extraction_verification_outcome'
   from workspace, jsonb_array_elements(payload -> 'queue') as item
   where label = 'f-kø'),
  null,
  'et funn uten registrert kontroll står som NULL — ikke som en kontroll med et negativt utfall'
);
select is(
  (select payload -> 'required_check_fields' from queue_row),
  to_jsonb(workflow.required_check_fields('55000000-0000-4000-8000-000000000011')::text[]),
  'kravet til dekning er publiseringsgatens egen funksjon, ikke en kopi av den'
);
select is(
  (select payload -> 'covered_check_fields' from queue_row),
  to_jsonb(workflow.covered_check_fields('55000000-0000-4000-8000-000000000011')::text[]),
  'den registrerte dekningen er publiseringsgatens egen funksjon, ikke en kopi av den'
);
select isnt(
  (select payload -> 'required_check_fields' from queue_row),
  (select payload -> 'covered_check_fields' from queue_row),
  'og de to er ikke de samme her: en delkontroll dekker mindre enn funnet påstår'
);

-- ===========================================================================
-- Del 5 — Oppslaget på ett funn
-- ===========================================================================
select is(
  (select payload #>> '{item,extraction_digest}' from workspace where label = 'h-e1'),
  workflow.evidence_extraction_digest('55000000-0000-4000-8000-000000000011'),
  'flaten leverer avtrykket vurderingen bindes til'
);
select is(
  (select payload #>> '{item,current_extraction_verification_id}' from workspace where label = 'h-e1'),
  (select ev.id::text from workflow.evidence_verifications ev
   where ev.evidence_item_id = '55000000-0000-4000-8000-000000000011'
   order by ev.verified_at desc, ev.created_at desc, ev.id desc limit 1),
  'den gjeldende kontrollen er den samme raden publiseringsgaten leser'
);
select is(
  (select jsonb_array_length(payload #> '{item,extraction_verifications}')
   from workspace where label = 'h-e1'),
  1,
  'historikken viser den registrerte kontrollen'
);
select is(
  (select payload #>> '{item,extraction_verifications,0,verifier_actor_type}'
   from workspace where label = 'h-e1'),
  'agent',
  'og sier at den ble gjort av en maskin, ikke av et menneske'
);
select is(
  (select payload #>> '{item,extraction,source_locator}' from workspace where label = 'h-e1'),
  'Avsnitt for 550',
  'hele ekstraksjonen er med, ordrett'
);
select is(
  (select payload #>> '{item,source_version,content_hash}' from workspace where label = 'h-e1'),
  'sha256:' || repeat('a', 64),
  'kildeversjonens fingeravtrykk er med, slik at kontrollen kan skje mot en etterprøvbar representasjon'
);
select results_eq(
  $$
    select rev ->> 'claim_revision_id', rev ->> 'relationship_type'
    from workspace, jsonb_array_elements(payload #> '{item,linked_claim_revisions}') as rev
    where label = 'h-e1'
  $$,
  $$values ('55000000-0000-4000-8000-000000000031', 'supports')$$,
  'flaten sier hvilke påstander funnet allerede bærer'
);

-- ===========================================================================
-- Del 6 — Den avgjørende assertionen: mennesket og maskinen leser det samme
-- ===========================================================================
create temporary table cred (label text primary key, secret text) on commit drop;
insert into cred select 'extraction', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman');
grant select on cred to anon;
create temporary table agent_run (label text primary key, id uuid) on commit drop;
grant insert, select on agent_run to anon;
create temporary table agent_view (payload jsonb) on commit drop;
grant insert, select on agent_view to anon;

set local role anon;
insert into agent_run select 'r', api.begin_agent_run(
  'agent-identity:extraction-verification-01', (select secret from cred where label = 'extraction'),
  'extraction_verification', 'testleverandør', 'testmodell', '2026-09-10',
  'extraction-verification/1', 'antidep-evidence/1', '{"mode": "test-550"}'::jsonb);
insert into agent_view select api.extraction_verification_input(
  'agent-identity:extraction-verification-01', (select secret from cred where label = 'extraction'),
  (select id from agent_run where label = 'r'), '55000000-0000-4000-8000-000000000011')
  -> 'items' -> 0;
reset role;

select is(
  (select payload - 'verifications_by_this_actor' - 'verifications_total' from agent_view),
  workflow.evidence_extraction_dossier('55000000-0000-4000-8000-000000000011'),
  'ekstraksjonsverifikatorens lesegrunnlag er nøyaktig det samme uttrykket reviewflaten viser: én formulering av kildegrunnlaget, ikke to'
);
select ok(
  (select workflow.evidence_extraction_dossier('55000000-0000-4000-8000-000000000011')
          <@ (payload -> 'item')
   from workspace where label = 'h-e1'),
  'og hele dossieret ligger uendret i flatens svar'
);

select finish();
rollback;
