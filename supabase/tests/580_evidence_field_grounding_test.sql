-- Migrasjon 005u — kildeforankringen per kontrollfelt.
--
-- Filen dekker fire ting:
--
--   * kontrakten: tabellen, kolonnene, RLS, at ingen klientrolle rører den, og
--     at leseren ikke er kjørbar for noen klientrolle
--   * radinvariantene: at forankringen tilhører den som laget ekstraksjonen (og
--     at det er en fremmednøkkel og ikke en konvensjon), at ett felt har én
--     forankring, formkravene på de tre tekstfeltene, og append-only
--   * grunnlaget: at dossieret bærer forankringen, at rekkefølgen er
--     vokabularets egen, og at et funn uten forankring gir en tom liste —
--     aldri noe gjettet ut av raw_extraction
--   * avtrykket: at en forankring som kommer til, endrer grunnlagsavtrykket, og
--     dermed avviser en kontroll som ble hentet fram før den
--
-- SQLSTATE 23503 = foreign_key_violation, 23505 = unique_violation,
-- 23514 = check_violation, 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(31);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table(
  'knowledge', 'evidence_field_groundings', 'knowledge.evidence_field_groundings finnes'
);
select has_column('knowledge', 'evidence_field_groundings', 'check_field', 'check_field finnes');
select has_column(
  'knowledge', 'evidence_field_groundings', 'source_excerpt', 'source_excerpt finnes'
);
select has_column(
  'knowledge', 'evidence_field_groundings', 'source_locator', 'source_locator finnes'
);
select has_column(
  'knowledge', 'evidence_field_groundings', 'justification', 'justification finnes'
);

-- Den strukturerte verdien lagres bevisst ikke her: den er kolonnen på
-- evidensfunnet, og en kopi ville kunnet komme i utakt med den kanoniske
-- verdien (ANTIDEP_CONSTITUTION.md §4, §8).
select hasnt_column(
  'knowledge', 'evidence_field_groundings', 'interpretation',
  'tolkningen lagres ikke ved siden av den kanoniske verdien'
);
select hasnt_column(
  'knowledge', 'evidence_field_groundings', 'reasoning',
  'ingen kolonne for skjult resonnement'
);

select ok(
  (select c.relrowsecurity from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'knowledge' and c.relname = 'evidence_field_groundings'),
  'RLS er på, med default deny'
);

select is_empty(
  $$
    select r.role_name, p.priv
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('select'), ('insert'), ('update'), ('delete')) as p(priv)
    where has_table_privilege(r.role_name, 'knowledge.evidence_field_groundings', p.priv)
  $$,
  'ingen klientrolle har tabellrettighet på forankringen'
);

select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name, 'workflow.evidence_field_groundings(uuid)'::regprocedure, 'execute'
    )
  $$,
  'leseren er ikke kjørbar for noen klientrolle: den er et lesegrunnlag, ikke et endepunkt'
);

select has_trigger(
  'knowledge', 'evidence_field_groundings', 'evidence_field_groundings_reject_mutation',
  'raden er append-only'
);
select has_trigger(
  'knowledge', 'evidence_field_groundings', 'evidence_field_groundings_record_audit_event',
  'registreringen etterlater et auditspor'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- To evidensfunn fra samme kilde, laget av samme aktør:
--   E1 med forankring, E2 uten. E2 er tilstanden alle funn registrert før
--   migrasjon 005u er i.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('58000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 580',
        'Testforfatter 580', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
values ('58000000-0000-4000-8000-000000000021', '58000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/580', 'sha256:' || repeat('a', 64),
        (select id from fixture where name = 'extractor'));

create function pg_temp.make_evidence(p_id uuid, p_author uuid, p_note text)
  returns void language sql as $$
  insert into knowledge.evidence_items (
    id, source_id, source_version_id, design_code, population_availability, population_detail,
    sample_size_availability, intervention_drug_id, comparator_kind,
    outcome_concept_id, outcome_detail, timepoint_availability,
    reported_direction, estimate_availability, confidence_interval_availability,
    source_locator, extraction_method, created_by_actor_id
  )
  values (
    p_id, '58000000-0000-4000-8000-000000000001', '58000000-0000-4000-8000-000000000021',
    'randomized_controlled_trial', 'not_reported', 'Prøve i 580.',
    'not_reported', (select id from fixture where name = 'sertralin'), 'none',
    (select id from fixture where name = 'weight'), p_note,
    'not_reported', 'increase', 'not_reported', 'not_reported',
    'Avsnitt for 580', 'ai_assisted', p_author
  );
$$;

select pg_temp.make_evidence(
  '58000000-0000-4000-8000-000000000011',
  (select id from fixture where name = 'extractor'),
  'Funn med forankring, 580.'
);
select pg_temp.make_evidence(
  '58000000-0000-4000-8000-000000000012',
  (select id from fixture where name = 'extractor'),
  'Funn uten forankring, 580.'
);

insert into knowledge.evidence_field_groundings
  (evidence_item_id, created_by_actor_id, check_field, source_excerpt, source_locator, justification)
values
  ('58000000-0000-4000-8000-000000000011', (select id from fixture where name = 'extractor'),
   'outcome', 'Weight change was the primary outcome.', 'Metode, avsnitt 2',
   'Endepunktet er navngitt i metodeavsnittet.'),
  ('58000000-0000-4000-8000-000000000011', (select id from fixture where name = 'extractor'),
   'source_locator', 'Table 2 reports the weight outcome.', 'Tabell 2, overskriften',
   'Kildepekeren viser til tabellen som faktisk rapporterer endepunktet.');

-- ===========================================================================
-- Del 3 — Radinvariantene
-- ===========================================================================

-- Forankringen tilhører den som laget ekstraksjonen. Regelen er en sammensatt
-- fremmednøkkel og ikke en konvensjon: en annen aktør kan ikke feste et utdrag
-- på en annen aktørs ekstraksjon (DATABASE_ARCHITECTURE.md §59).
select throws_ok(
  $$
    insert into knowledge.evidence_field_groundings
      (evidence_item_id, created_by_actor_id, check_field,
       source_excerpt, source_locator, justification)
    values ('58000000-0000-4000-8000-000000000011',
            (select id from fixture where name = 'editor'),
            'estimate', 'Mean difference 1.7 kg.', 'Tabell 2', 'Tallet står i resultatraden.')
  $$,
  '23503',
  null,
  'en annen aktør enn ekstraktøren kan ikke forankre ekstraksjonen'
);

select throws_ok(
  $$
    insert into knowledge.evidence_field_groundings
      (evidence_item_id, created_by_actor_id, check_field,
       source_excerpt, source_locator, justification)
    values ('58000000-0000-4000-8000-000000000011',
            (select id from fixture where name = 'extractor'),
            'outcome', 'Et annet utdrag om det samme feltet.', 'Metode, avsnitt 3',
            'To forankringer av samme felt.')
  $$,
  '23505',
  null,
  'ett felt har én forankring: to ville vært to påstander om hva verdien hviler på'
);

select throws_ok(
  $$
    insert into knowledge.evidence_field_groundings
      (evidence_item_id, created_by_actor_id, check_field,
       source_excerpt, source_locator, justification)
    values ('58000000-0000-4000-8000-000000000012',
            (select id from fixture where name = 'extractor'),
            'estimate', '   ', 'Tabell 2', 'Tom tekst er ikke et utdrag.')
  $$,
  '23514',
  null,
  'et tomt utdrag er ikke et utdrag'
);

select throws_ok(
  $$
    insert into knowledge.evidence_field_groundings
      (evidence_item_id, created_by_actor_id, check_field,
       source_excerpt, source_locator, justification)
    values ('58000000-0000-4000-8000-000000000012',
            (select id from fixture where name = 'extractor'),
            'estimate', ' Mean difference 1.7 kg. ', 'Tabell 2', 'Utrimmet tekst.')
  $$,
  '23514',
  null,
  'utdraget lagres trimmet, slik at to like utdrag ikke kan se forskjellige ut'
);

select throws_ok(
  $$
    update knowledge.evidence_field_groundings
    set source_excerpt = 'Et helt annet utdrag.'
    where evidence_item_id = '58000000-0000-4000-8000-000000000011'
  $$,
  '23001',
  null,
  'forankringen kan ikke endres: er den feil, er ekstraksjonen feil'
);

select throws_ok(
  $$
    delete from knowledge.evidence_field_groundings
    where evidence_item_id = '58000000-0000-4000-8000-000000000011'
  $$,
  '23001',
  null,
  'forankringen kan ikke slettes'
);

-- ===========================================================================
-- Del 4 — Leseren og grunnlaget
-- ===========================================================================
select is(
  jsonb_array_length(
    workflow.evidence_field_groundings('58000000-0000-4000-8000-000000000011')
  ),
  2,
  'leseren gir de registrerte forankringene'
);

-- Rekkefølgen er vokabularets egen, som følger kolonnene på evidensfunnet, slik
-- at en kontrollflate lister feltene i den rekkefølgen raden er bygget.
select is(
  (select string_agg(g ->> 'check_field', ',')
   from jsonb_array_elements(
     workflow.evidence_field_groundings('58000000-0000-4000-8000-000000000011')
   ) as g),
  'outcome,source_locator',
  'rekkefølgen er vokabularets egen, ikke innsettingsrekkefølgen'
);

select is(
  workflow.evidence_field_groundings('58000000-0000-4000-8000-000000000012'),
  '[]'::jsonb,
  'et funn uten forankring gir en tom liste, aldri noe gjettet'
);

select is(
  workflow.evidence_extraction_dossier('58000000-0000-4000-8000-000000000011')
    -> 'field_groundings' -> 0 ->> 'source_excerpt',
  'Weight change was the primary outcome.',
  'dossieret bærer forankringen, slik at mennesket og maskinen leser den samme'
);

select is(
  workflow.evidence_extraction_dossier('58000000-0000-4000-8000-000000000012')
    -> 'field_groundings',
  '[]'::jsonb,
  'et funn uten forankring viser fraværet som fravær i dossieret'
);

-- Den rå ekstraksjonen står fortsatt der den stod, og er ikke blitt en kilde
-- til forankring: de to er forskjellige ting.
select is(
  (workflow.evidence_extraction_dossier('58000000-0000-4000-8000-000000000012')
    -> 'extraction') ? 'raw_extraction',
  true,
  'raw_extraction er uendret i dossieret, og er ikke gjort om til forankring'
);

-- ===========================================================================
-- Del 5 — Avtrykket
-- ===========================================================================
create temporary table digest_before (value text) on commit drop;
insert into digest_before (value)
select workflow.evidence_extraction_digest('58000000-0000-4000-8000-000000000012');

insert into knowledge.evidence_field_groundings
  (evidence_item_id, created_by_actor_id, check_field, source_excerpt, source_locator, justification)
values ('58000000-0000-4000-8000-000000000012', (select id from fixture where name = 'extractor'),
        'estimate', 'Mean difference 1.7 kg.', 'Tabell 2', 'Tallet står i resultatraden.');

select isnt(
  workflow.evidence_extraction_digest('58000000-0000-4000-8000-000000000012'),
  (select value from digest_before),
  'en forankring som kommer til, endrer grunnlagsavtrykket'
);

select throws_ok(
  format(
    $$select workflow.assert_extraction_unchanged(
        '58000000-0000-4000-8000-000000000012', %L)$$,
    (select value from digest_before)
  ),
  '23001',
  null,
  'en kontroll hentet fram før forankringen kom til, avvises som utdatert'
);

select lives_ok(
  $$
    select workflow.assert_extraction_unchanged(
      '58000000-0000-4000-8000-000000000012',
      workflow.evidence_extraction_digest('58000000-0000-4000-8000-000000000012'))
  $$,
  'og passerer på det avtrykket som gjelder nå'
);

-- ===========================================================================
-- Del 6 — Auditsporet
-- ===========================================================================
select is(
  (select count(*) from audit.events
   where operation = 'evidence_field_grounding_recorded'),
  3::bigint,
  'hver registrert forankring har sin auditrad'
);

select is(
  (select distinct e.object_schema || '.' || e.object_table from audit.events e
   where e.operation = 'evidence_field_grounding_recorded'),
  'knowledge.evidence_field_groundings',
  'auditraden peker på riktig tabell, avledet av operasjonen'
);

select is(
  (select e.new_revision_or_snapshot ->> 'check_field' from audit.events e
   where e.operation = 'evidence_field_grounding_recorded'
     and e.new_revision_or_snapshot ->> 'evidence_item_id'
         = '58000000-0000-4000-8000-000000000012'),
  'estimate',
  'hele raden er snapshotet'
);

select is(
  (select count(*) from audit.events e
   where e.operation = 'evidence_field_grounding_recorded'
     and e.old_revision_or_snapshot is not null),
  0::bigint,
  'en forankring er en opprettelse: det finnes ingen forrige tilstand'
);

select finish();
rollback;
