-- Migrasjon 005ad og 005ae — kontrollleddet som kan bære et globalt fravær.
--
-- `not_reported` («ikke rapportert i kilden») og `not_measured` («ikke målt i
-- studien») er påstander om kilden eller studien som helhet. Fram til 005ae
-- hadde Antidep ikke noe kontrollgrunnlag som kunne bære dem: den menneskelige
-- kildekontrollen ser ett lokalt utdrag, og et utdrag viser hva som står ett
-- sted — ikke hva som ikke står noe sted (issue #74).
--
-- Påstanden er nå delt i de to halvdelene som har hvert sitt grunnlag:
--
--   availability_semantics   den LOKALE: er grunnen av riktig art, og mangler
--                            verdien der forankringsutdraget viser at den ville
--                            stått? Et menneske avgjør den.
--   source_wide_absence      den KILDEOMFATTENDE: fant et søk gjennom hele den
--                            kontrollerte representasjonen ingen slik verdi? En
--                            maskin avgjør den, og bare en maskin.
--
-- Filen prøver de fire tingene som holder skillet oppe: at settet er utledet av
-- raden selv, at gaten krever den kildeomfattende halvdelen når og bare når
-- raden gjør påstanden, at kontrolløkten aldri får et steg for den, og at ingen
-- menneskelig kontroll kan føre den opp.
--
-- SQLSTATE 23514 = check_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(21);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'workflow', 'source_wide_absence_fields', array['uuid'],
  'workflow.source_wide_absence_fields(uuid) finnes'
);
select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'workflow.source_wide_absence_fields(uuid)'::regprocedure),
  'funksjonen er SECURITY DEFINER: knowledge har RLS med default deny'
);
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name, 'workflow.source_wide_absence_fields(uuid)'::regprocedure, 'execute')
  $$,
  'ingen klientrolle kan kalle den: den leses av gaten og av grunnlagsflatene'
);

-- Vokabularet må ha verdien, ellers er alt under uten mening.
select ok(
  'source_wide_absence' = any (enum_range(null::workflow.evidence_check_field)),
  'workflow.evidence_check_field har verdien source_wide_absence'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- Fire evidensfunn som skiller de fire fraværsgrunnene fra hverandre. Bare de
-- to første er påstander om kilden som helhet.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'population', id from catalog.populations where canonical_label = 'voksne med depressiv lidelse';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('66000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 660',
        'Testforfatter 660', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation,
   retrieved_by_actor_id)
values ('66000000-0000-4000-8000-000000000021', '66000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/660', 'sha256:' || repeat('b', 64), 'full_text',
        (select id from fixture where name = 'extractor'));

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_id, population_availability,
  population_detail, sample_size, sample_size_availability, intervention_drug_id,
  comparator_kind, outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, effect_measure, estimate, estimate_unit, estimate_availability,
  ci_lower, ci_upper, ci_level_percent, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values
  -- «ikke rapportert i kilden»: en påstand om kilden som helhet.
  ('66000000-0000-4000-8000-000000000011', '66000000-0000-4000-8000-000000000001',
   '66000000-0000-4000-8000-000000000021', 'randomized_controlled_trial',
   (select id from fixture where name = 'population'), 'reported_value',
   'Voksne med depressiv lidelse i 660.', 48, 'reported_value',
   (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Vektendring i 660.',
   'not_applicable', 'increase', 'mean_change', 1.5, 'kg', 'reported_value', null, null, null, 'not_reported',
   'Tabell 2', 'ai_assisted', (select id from fixture where name = 'extractor')),
  -- «ikke målt i studien»: også en påstand om studien som helhet.
  ('66000000-0000-4000-8000-000000000012', '66000000-0000-4000-8000-000000000001',
   '66000000-0000-4000-8000-000000000021', 'randomized_controlled_trial',
   (select id from fixture where name = 'population'), 'reported_value',
   'Voksne med depressiv lidelse i 660.', 48, 'reported_value',
   (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Vektendring i 660.',
   'not_measured', 'increase', 'mean_change', 1.5, 'kg', 'reported_value', null, null, null, 'not_applicable',
   'Tabell 2', 'ai_assisted', (select id from fixture where name = 'extractor')),
  -- «ikke aktuelt for funnet» og «står i kilden, men ikke entydig lesbart»:
  -- ingen av dem er en påstand om kilden som helhet.
  ('66000000-0000-4000-8000-000000000013', '66000000-0000-4000-8000-000000000001',
   '66000000-0000-4000-8000-000000000021', 'randomized_controlled_trial',
   (select id from fixture where name = 'population'), 'reported_value',
   'Voksne med depressiv lidelse i 660.', 48, 'reported_value',
   (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Vektendring i 660.',
   'not_applicable', 'increase', 'mean_change', 1.5, 'kg', 'reported_value', null, null, null, 'not_extractable',
   'Figur 1', 'ai_assisted', (select id from fixture where name = 'extractor')),
  -- Ingenting mangler: raden gjør ingen fraværspåstand i det hele tatt.
  ('66000000-0000-4000-8000-000000000014', '66000000-0000-4000-8000-000000000001',
   '66000000-0000-4000-8000-000000000021', 'randomized_controlled_trial',
   (select id from fixture where name = 'population'), 'reported_value',
   'Voksne med depressiv lidelse i 660.', 48, 'reported_value',
   (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Vektendring i 660.',
   'not_applicable', 'increase', 'mean_change', 1.5, 'kg', 'reported_value', 0.4, 2.6, 95, 'reported_value',
   'Tabell 2', 'ai_assisted', (select id from fixture where name = 'extractor'));

-- Kildeforankring for hvert semantisk felt. Poenget under er at
-- source_wide_absence IKKE er blant dem: grunnlaget for et kildeomfattende søk
-- er hele representasjonen, ikke ett utdrag.
insert into knowledge.evidence_field_groundings
  (evidence_item_id, created_by_actor_id, check_field,
   source_excerpt, source_locator, justification)
select e.id, e.created_by_actor_id, f.field,
       'Utdrag for ' || f.field::text || ' i 660.',
       'Avsnitt for ' || f.field::text,
       'Begrunnelse for ' || f.field::text || '.'
from knowledge.evidence_items e
cross join unnest(workflow.semantic_check_fields(e.id)) as f(field)
where e.id = '66000000-0000-4000-8000-000000000011';

-- ===========================================================================
-- Del 3 — Settet er utledet av raden, og bare av de to globale grunnene
-- ===========================================================================
select set_eq(
  $$select unnest(workflow.source_wide_absence_fields(
      '66000000-0000-4000-8000-000000000011'))::text$$,
  $$values ('confidence_interval')$$,
  'not_reported gjør feltet til en påstand om kilden som helhet'
);
select set_eq(
  $$select unnest(workflow.source_wide_absence_fields(
      '66000000-0000-4000-8000-000000000012'))::text$$,
  $$values ('timepoint')$$,
  'not_measured gjør det samme, og navngir det feltet som faktisk bærer grunnen'
);
select is_empty(
  $$select unnest(workflow.source_wide_absence_fields(
      '66000000-0000-4000-8000-000000000013'))::text$$,
  'not_applicable og not_extractable er smalere påstander og er ikke med'
);
select is_empty(
  $$select unnest(workflow.source_wide_absence_fields(
      '66000000-0000-4000-8000-000000000014'))::text$$,
  'en rad uten fravær gjør ingen kildeomfattende påstand'
);

-- ===========================================================================
-- Del 4 — Gaten krever halvdelen når og bare når raden gjør påstanden
-- ===========================================================================
select ok(
  'source_wide_absence' = any (workflow.required_check_fields(
    '66000000-0000-4000-8000-000000000011')),
  'gaten krever det kildeomfattende søket når raden fører et globalt fravær'
);
select ok(
  'source_wide_absence' = any (workflow.required_check_fields(
    '66000000-0000-4000-8000-000000000012')),
  'det samme gjelder not_measured'
);
select ok(
  not ('source_wide_absence' = any (workflow.required_check_fields(
    '66000000-0000-4000-8000-000000000013'))),
  'og ikke når fraværsgrunnen er en påstand om funnet eller om lesningen'
);
select ok(
  not ('source_wide_absence' = any (workflow.required_check_fields(
    '66000000-0000-4000-8000-000000000014'))),
  'og ikke når raden ikke fører noe fravær: et krav ingen kunne oppfylt'
);

-- Den lokale halvdelen kreves fortsatt, av alle rader. Den ene erstatter ikke
-- den andre: de er påstander om forskjellige ting.
select ok(
  'availability_semantics' = any (workflow.required_check_fields(
    '66000000-0000-4000-8000-000000000011')),
  'den lokale halvdelen kreves fortsatt ved siden av den kildeomfattende'
);

-- ===========================================================================
-- Del 5 — Kontrolløkten får aldri et steg for det
--
-- Kontrolløren har ikke grunnlaget: spørsmålet er om opplysningen står noe
-- annet sted i hele artikkelen, og det kan bare besvares ved å lese hele
-- artikkelen — arbeidsformen PRODUCT_INFORMATION_ARCHITECTURE.md §63.1 finnes
-- for å fjerne.
-- ===========================================================================
select ok(
  not ('source_wide_absence' = any (workflow.semantic_check_fields(
    '66000000-0000-4000-8000-000000000011'))),
  'feltet er ikke et semantisk steg: ingen kontrolløkt stiller det spørsmålet'
);

-- Og da kreves ingen kildeforankring for det heller: grunnlaget er hele
-- representasjonen, ikke ett utdrag.
select lives_ok(
  $$select workflow.assert_extraction_fully_grounded(
      '66000000-0000-4000-8000-000000000011')$$,
  'forankringskravet gjelder ikke feltet: grunnlaget er hele representasjonen'
);

-- Grunnlagsflaten navngir settet, slik at kontrollflaten og kontrollleddet
-- leser det samme som gaten framfor å regne det ut hver for seg.
select is(
  (select workflow.evidence_extraction_dossier('66000000-0000-4000-8000-000000000011')
          #>> '{source_wide_absence_fields,0}'),
  'confidence_interval',
  'grunnlaget navngir feltene som bærer en kildeomfattende fraværspåstand'
);

-- ===========================================================================
-- Del 6 — Bare en maskinell kontroll kan føre feltet opp
--
-- Et menneske blir aldri spurt om det kildeomfattende søket, og en rad som
-- førte det opp uten å ha gjort søket, ville påstått større dekning enn
-- operasjonen hadde (DATABASE_ARCHITECTURE.md §29).
-- ===========================================================================
create temporary table run (label text primary key, id uuid, actor_id uuid) on commit drop;
with r as (
  insert into provenance.agent_runs
    (agent_identity_id, actor_id, agent_role, provider, model, model_version,
     prompt_template_version, pipeline_version, input_manifest)
  select ai.id, ai.actor_id, 'extraction_verification', 'prøve', 'prøve', '1',
         'extraction-verification/1', 'antidep-evidence/1', '{"mode": "660"}'::jsonb
  from provenance.agent_identities ai
  where ai.identity_key = 'agent-identity:extraction-verification-01'
  returning id, actor_id
)
insert into run select 'verify', r.id, r.actor_id from r;

-- Uten kjøring: aktøren har mandatet, men ingen kjøring har gjort noe søk.
-- Det er nøyaktig den forskjellen constrainten finnes for; at den menneskelige
-- skriveveien avvises av den samme regelen, prøves i 570.
select throws_ok(
  $$
    insert into workflow.evidence_verifications
      (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
       source_access, checked_fields, rationale, verified_at)
    select e.id, e.created_by_actor_id,
           (select id from fixture where name = 'verifier'),
           'verified', 'original_source',
           array['source_wide_absence']::workflow.evidence_check_field[],
           'Prøve i 660: en kontroll uten kjøring forsøker å bære påstanden.',
           now()
    from knowledge.evidence_items e
    where e.id = '66000000-0000-4000-8000-000000000011'
  $$,
  '23514', null,
  'en kontroll uten agentkjøring kan ikke føre opp det kildeomfattende søket'
);

-- Med kjøring, men bare et annet ledds sammendrag å søke i: heller ikke da.
-- Et søk gjennom et sammendrag er ikke et søk gjennom kilden
-- (ANTIDEP_CONSTITUTION.md §11).
select throws_ok(
  $$
    insert into workflow.evidence_verifications
      (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
       source_access, checked_fields, rationale, verified_at, agent_run_id)
    select e.id, e.created_by_actor_id, (select actor_id from run where label = 'verify'),
           'uncertain', 'derived_summary',
           array['source_wide_absence']::workflow.evidence_check_field[],
           'Prøve i 660: søk gjennom et avledet sammendrag.',
           now(), (select id from run where label = 'verify')
    from knowledge.evidence_items e
    where e.id = '66000000-0000-4000-8000-000000000011'
  $$,
  '23514', null,
  'et søk gjennom et avledet sammendrag er ikke et kildeomfattende søk'
);

-- Med kjøring og en etterprøvbar representasjon: dette er leddet som faktisk
-- gjorde søket.
select lives_ok(
  $$
    insert into workflow.evidence_verifications
      (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
       source_access, checked_fields, rationale, findings, verified_at, agent_run_id)
    select e.id, e.created_by_actor_id, (select actor_id from run where label = 'verify'),
           'uncertain', 'verifiable_representation',
           array['source_locator', 'source_wide_absence']::workflow.evidence_check_field[],
           'Prøve i 660: hele representasjonen ble gjennomsøkt uten treff.',
           'Tallene lot seg ikke bedømme maskinelt.', now(),
           (select id from run where label = 'verify')
    from knowledge.evidence_items e
    where e.id = '66000000-0000-4000-8000-000000000011'
  $$,
  'det kildeomfattende søket registreres av leddet som faktisk gjorde det'
);

-- …og en uavklart maskinkontroll teller i dekningen, som enhver annen
-- delkontroll (migrasjon 005y).
select ok(
  'source_wide_absence' = any (workflow.covered_check_fields(
    '66000000-0000-4000-8000-000000000011')),
  'og dekningen leser det, selv når kontrollen ellers konkluderte uavklart'
);

-- Det som står igjen, er nøyaktig de feltene et menneske faktisk kan bedømme.
select is_empty(
  $$
    select f.field::text
    from unnest(workflow.required_check_fields(
      '66000000-0000-4000-8000-000000000011')) as f(field)
    where f.field <> all (workflow.covered_check_fields(
      '66000000-0000-4000-8000-000000000011'))
      and f.field <> all (workflow.semantic_check_fields(
        '66000000-0000-4000-8000-000000000011'))
      and f.field <> 'raw_extraction'
  $$,
  'etter maskinens rad står bare de semantiske feltene igjen for mennesket'
);

select * from finish();
rollback;
