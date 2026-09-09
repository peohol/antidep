-- Migrasjon 007e — den kontrollerte skriveveien for å registrere et EvidenceItem.
--
-- Steg 3 av «manuell adminflyt» (MVP_IMPLEMENTATION_PLAN.md §29): «Editor
-- registrerer EvidenceItem» (§15), leddet etter kildeopprettelsen i
-- 370_source_creation_test.sql. Filen dekker de samme fire tingene som 370, i
-- samme rekkefølge: kontrakten (hva som faktisk er eksponert), autorisasjonen
-- (nå med scope, som er det nye), konsekvensen (raden og auditraden), og
-- avvisningene fra tabellens egne constraints.
--
-- SQLSTATE 42501 = insufficient_privilege, 22P02 = invalid_text_representation,
-- 23001 = restrict_violation, 23503 = foreign_key_violation,
-- 23505 = unique_violation, 23514 = check_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(35);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function('api', 'create_evidence_item', 'api.create_evidence_item() finnes');
select has_function(
  'audit', 'record_evidence_item_event', 'audit.record_evidence_item_event() finnes'
);
select has_trigger(
  'knowledge', 'evidence_items', 'evidence_items_record_creation_audit_event',
  'ethvert innsatt evidensfunn auditeres'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.create_evidence_item(uuid,text,text,text,text,uuid,text,uuid,text,text,text,text,text,text,uuid,uuid,integer,text,uuid,text,text,text,text,numeric,text,numeric,numeric,numeric,text,text)'::regprocedure),
  'api.create_evidence_item() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
-- Auditskriveren skal aldri være mer privilegert enn operasjonen den
-- registrerer (samme regel som for de tre auditskriverne før den).
select ok(
  not (select p.prosecdef from pg_proc p
       where p.oid = 'audit.record_evidence_item_event()'::regprocedure),
  'audit.record_evidence_item_event() er ikke SECURITY DEFINER'
);

select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.create_evidence_item(uuid,text,text,text,text,uuid,text,uuid,text,text,text,text,text,text,uuid,uuid,integer,text,uuid,text,text,text,text,numeric,text,numeric,numeric,numeric,text,text)'::regprocedure,
      'execute'
    )
  $$,
  'api.create_evidence_item() er kjørbar bare for authenticated, ikke for anon, service_role eller PUBLIC'
);
select ok(
  has_function_privilege(
    'authenticated',
    'api.create_evidence_item(uuid,text,text,text,text,uuid,text,uuid,text,text,text,text,text,text,uuid,uuid,integer,text,uuid,text,text,text,text,numeric,text,numeric,numeric,numeric,text,text)'::regprocedure,
    'execute'
  ),
  'authenticated har EXECUTE på api.create_evidence_item()'
);

-- ===========================================================================
-- Del 2 — Uinnlogget og direkte tabellskriving er begge stengt (§43)
-- ===========================================================================
set local role anon;
select throws_ok(
  $$
    select api.create_evidence_item(
      p_source_id := gen_random_uuid(),
      p_design_code := 'randomized_controlled_trial',
      p_population_availability := 'not_reported',
      p_population_detail := 'Anonymt forsøk.',
      p_sample_size_availability := 'not_reported',
      p_intervention_drug_id := gen_random_uuid(),
      p_comparator_kind := 'none',
      p_outcome_concept_id := gen_random_uuid(),
      p_outcome_detail := 'Anonymt forsøk.',
      p_timepoint_availability := 'not_reported',
      p_reported_direction := 'not_stated',
      p_estimate_availability := 'not_reported',
      p_confidence_interval_availability := 'not_reported',
      p_source_locator := 'Anonymt forsøk'
    )
  $$,
  '42501', null,
  'anon kan ikke registrere et evidensfunn gjennom skriveveien'
);
reset role;

set local role authenticated;
select throws_ok(
  $$
    insert into knowledge.evidence_items (
      source_id, design_code, population_availability, population_detail,
      sample_size_availability, intervention_drug_id, comparator_kind,
      outcome_concept_id, outcome_detail, timepoint_availability,
      reported_direction, estimate_availability, confidence_interval_availability,
      source_locator, extraction_method, created_by_actor_id
    )
    values (
      gen_random_uuid(), 'randomized_controlled_trial', 'not_reported', 'Direkte forsøk.',
      'not_reported', gen_random_uuid(), 'none', gen_random_uuid(), 'Direkte forsøk.',
      'not_reported', 'not_stated', 'not_reported', 'not_reported',
      'Direkte forsøk', 'manual', gen_random_uuid()
    )
  $$,
  '42501', null,
  'en innlogget bruker kan ikke omgå funksjonen ved å skrive direkte i knowledge.evidence_items'
);
reset role;

-- ===========================================================================
-- Del 3 — Fikstur
--
--   A  ingen aktørrad i det hele tatt
--   B  aktør, men ingen rolletildeling
--   C  aktør, tilbaketrukket, med en ellers gyldig editor-tildeling
--   D  aktør, reviewer-tildeling (ikke editor)
--   E  aktør, editor-tildeling avgrenset til «vektendring»
--   F  aktør, editor-tildeling uavgrenset
--
-- Et andre endepunkt registreres, slik at avgrensningen i det hele tatt kan
-- prøves i begge retninger: uten det ville «avgrenset til vektendring» og «alle
-- endepunkter» vært samme mengde.
-- ===========================================================================
insert into auth.users (id, email) values
  ('39000000-0000-4000-8000-00000000000a', 'evidens-390-a@test.invalid'),
  ('39000000-0000-4000-8000-00000000000b', 'evidens-390-b@test.invalid'),
  ('39000000-0000-4000-8000-00000000000c', 'evidens-390-c@test.invalid'),
  ('39000000-0000-4000-8000-00000000000d', 'evidens-390-d@test.invalid'),
  ('39000000-0000-4000-8000-00000000000e', 'evidens-390-e@test.invalid'),
  ('39000000-0000-4000-8000-00000000000f', 'evidens-390-f@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id, retired_at, retirement_note)
values
  ('ac390000-0000-4000-8000-00000000000b', 'human', 'human:evidens-390-b', 'Kaller B',
   'Aktør uten rolletildeling, for 390.', '39000000-0000-4000-8000-00000000000b', null, null),
  ('ac390000-0000-4000-8000-00000000000c', 'human', 'human:evidens-390-c', 'Kaller C',
   'Tilbaketrukket aktør med en ellers gyldig editor-tildeling, for 390.',
   '39000000-0000-4000-8000-00000000000c',
   now() - interval '1 day', 'Trukket tilbake for testene i 390.'),
  ('ac390000-0000-4000-8000-00000000000d', 'human', 'human:evidens-390-d', 'Kaller D',
   'Aktør med reviewer-rolle, ikke editor, for 390.', '39000000-0000-4000-8000-00000000000d',
   null, null),
  ('ac390000-0000-4000-8000-00000000000e', 'human', 'human:evidens-390-e', 'Kaller E',
   'Aktør med editor-rolle avgrenset til vektendring, for 390.',
   '39000000-0000-4000-8000-00000000000e', null, null),
  ('ac390000-0000-4000-8000-00000000000f', 'human', 'human:evidens-390-f', 'Kaller F',
   'Aktør med uavgrenset editor-rolle, for 390.', '39000000-0000-4000-8000-00000000000f',
   null, null);

insert into catalog.clinical_concepts (canonical_label, concept_type, status)
values ('søvnkvalitet', 'outcome', 'active');

create temporary table fixture (name text primary key, id uuid not null) on commit drop;
-- Kallene under kjøres som authenticated, og de slår opp de seedede
-- katalogradenes id-er her. Samme mønster som probe-tabellen i
-- 340_api_column_contract_test.sql: en temptabell gir ingen rettigheter av seg
-- selv, og granten gjelder bare inne i denne transaksjonen.
grant select on fixture to authenticated;
insert into fixture (name, id)
select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'sleep', id from catalog.clinical_concepts where canonical_label = 'søvnkvalitet';
insert into fixture (name, id)
select 'condition', id from catalog.clinical_concepts where canonical_label = 'depressiv lidelse';
insert into fixture (name, id)
select 'population', id from catalog.populations
where canonical_label = 'voksne med depressiv lidelse';
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'mirtazapin', id from catalog.drugs where canonical_name = 'mirtazapin';
insert into fixture (name, id) select 'actor_e', id from provenance.actors where actor_key = 'human:evidens-390-e';
insert into fixture (name, id) select 'actor_f', id from provenance.actors where actor_key = 'human:evidens-390-f';
insert into fixture (name, id) select 'actor_c', id from provenance.actors where actor_key = 'human:evidens-390-c';

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('39000000-0000-4000-8000-00000000000c', 'editor', null, now() - interval '1 year',
   (select id from fixture where name = 'actor_c'), 'Ellers gyldig tildeling for tilbaketrukket kaller C.'),
  ('39000000-0000-4000-8000-00000000000d', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'actor_e'), 'Reviewer, ikke editor, for kaller D.'),
  ('39000000-0000-4000-8000-00000000000e', 'editor', (select id from fixture where name = 'weight'),
   now() - interval '1 year',
   (select id from fixture where name = 'actor_e'), 'Avgrenset editor-tildeling for kaller E.'),
  ('39000000-0000-4000-8000-00000000000f', 'editor', null, now() - interval '1 year',
   (select id from fixture where name = 'actor_f'), 'Uavgrenset editor-tildeling for kaller F.');

-- Kilden funnene registreres på, med to øyeblikksbilder, og en andre kilde som
-- ingen av dem tilhører. Den siste finnes bare for å prøve at kildeversjonen må
-- høre til samme kilde.
insert into knowledge.sources
  (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('50390000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 390',
   'Testforfatter 390', (select id from fixture where name = 'actor_f')),
  ('50390000-0000-4000-8000-000000000002', 'journal_article', 'Annen testkilde for 390',
   'Testforfatter 390', (select id from fixture where name = 'actor_f'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, retrieved_by_actor_id)
values
  ('51390000-0000-4000-8000-000000000001', '50390000-0000-4000-8000-000000000001',
   now() - interval '2 days', 'https://eksempel.invalid/390',
   (select id from provenance.actors where actor_key = 'agent:evidence-extraction')),
  ('51390000-0000-4000-8000-000000000002', '50390000-0000-4000-8000-000000000002',
   now() - interval '2 days', 'https://eksempel.invalid/390-annen',
   (select id from provenance.actors where actor_key = 'agent:evidence-extraction'));

-- Et minimalt, gyldig kall. Testene under overstyrer nøyaktig det de handler om.
create function pg_temp.register(
  p_outcome uuid,
  p_detail text,
  p_source uuid default '50390000-0000-4000-8000-000000000001',
  p_version uuid default null
)
  returns uuid
  language sql
as $$
  select api.create_evidence_item(
    p_source_id := p_source,
    p_source_version_id := p_version,
    p_design_code := 'randomized_controlled_trial',
    p_population_availability := 'not_reported',
    p_population_detail := 'Populasjonen er ikke beskrevet i kilden.',
    p_sample_size_availability := 'not_reported',
    p_intervention_drug_id := (select id from fixture where name = 'sertralin'),
    p_comparator_kind := 'none',
    p_outcome_concept_id := p_outcome,
    p_outcome_detail := p_detail,
    p_timepoint_availability := 'not_reported',
    p_reported_direction := 'not_stated',
    p_estimate_availability := 'not_reported',
    p_confidence_interval_availability := 'not_reported',
    p_source_locator := 'Avsnitt 1'
  );
$$;

-- ===========================================================================
-- Del 4 — Autorisasjonsgrenene, prøvd med den faktiske funksjonen
-- ===========================================================================

-- A — ingen aktørrad
select set_config('request.jwt.claims',
                  '{"sub":"39000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  $$select pg_temp.register(
      (select id from fixture where name = 'weight'), 'Vektendring, ikke tallfestet.')$$,
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en kaller uten aktørrad avvises eksplisitt, og får ikke et evidensfunn registrert i sitt navn'
);
reset role;

-- B — aktør, ingen rolletildeling
select set_config('request.jwt.claims',
                  '{"sub":"39000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  $$select pg_temp.register(
      (select id from fixture where name = 'weight'), 'Vektendring, ikke tallfestet.')$$,
  '42501', 'Brukeren har ikke gyldig editor-rolle for dette innholdsområdet.',
  'en aktør uten noen rolletildeling avvises med rollefeilen, ikke aktørfeilen'
);
reset role;

-- C — tilbaketrukket aktør med en ellers gyldig editor-tildeling
select set_config('request.jwt.claims',
                  '{"sub":"39000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select throws_ok(
  $$select pg_temp.register(
      (select id from fixture where name = 'weight'), 'Vektendring, ikke tallfestet.')$$,
  '42501', 'Aktøren er trukket tilbake og kan ikke registrere nytt innhold.',
  'en tilbaketrukket aktør avvises, selv med en ellers gyldig editor-tildeling'
);
reset role;

-- D — reviewer, ikke editor
select set_config('request.jwt.claims',
                  '{"sub":"39000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
select throws_ok(
  $$select pg_temp.register(
      (select id from fixture where name = 'weight'), 'Vektendring, ikke tallfestet.')$$,
  '42501', 'Brukeren har ikke gyldig editor-rolle for dette innholdsområdet.',
  'reviewer-rollen gir ikke rett til å registrere evidens; å godkjenne og å registrere er forskjellige handlinger'
);
reset role;

-- E — editor avgrenset til «vektendring». Her ligger hele forskjellen fra
-- kildeopprettelsen: et evidensfunn ER avgrenset til et endepunkt, og
-- avgrensningen skal derfor gjelde.
select set_config('request.jwt.claims',
                  '{"sub":"39000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select lives_ok(
  $$select pg_temp.register(
      (select id from fixture where name = 'weight'), 'Vektendring, ikke tallfestet.')$$,
  'en editor avgrenset til vektendring kan registrere et funn om vektendring'
);
select throws_ok(
  $$select pg_temp.register(
      (select id from fixture where name = 'sleep'), 'Søvnkvalitet, ikke tallfestet.')$$,
  '42501', 'Brukeren har ikke gyldig editor-rolle for dette innholdsområdet.',
  'den samme editoren kan ikke registrere et funn om et endepunkt tildelingen ikke dekker'
);
reset role;

select is(
  (select e.created_by_actor_id from knowledge.evidence_items e
   where e.outcome_detail = 'Vektendring, ikke tallfestet.'),
  (select id from fixture where name = 'actor_e'),
  'funnet fra kaller E er attribuert til kaller E sin egen aktør, ikke til en annen'
);

-- F — uavgrenset editor. Dekker begge endepunktene.
select set_config('request.jwt.claims',
                  '{"sub":"39000000-0000-4000-8000-00000000000f"}', true);
set local role authenticated;
select lives_ok(
  $$select pg_temp.register(
      (select id from fixture where name = 'sleep'), 'Søvnkvalitet, ikke tallfestet.')$$,
  'en uavgrenset editor-tildeling dekker et endepunkt en avgrenset tildeling ikke gjør'
);

-- ===========================================================================
-- Del 5 — Den lykkede stien, kontrollert i detalj (kaller F, fortsatt innlogget)
-- ===========================================================================
select lives_ok(
  $$
    select api.create_evidence_item(
      p_source_id := '50390000-0000-4000-8000-000000000001',
      p_source_version_id := '51390000-0000-4000-8000-000000000001',
      p_design_code := 'randomized_controlled_trial',
      p_population_id := (select id from fixture where name = 'population'),
      p_population_availability := 'reported_value',
      p_population_detail := 'Voksne i testpopulasjonen for 390.',
      p_sample_size := 240,
      p_sample_size_availability := 'reported_value',
      p_intervention_drug_id := (select id from fixture where name = 'sertralin'),
      p_intervention_detail := '50 mg daglig',
      p_comparator_kind := 'drug',
      p_comparator_drug_id := (select id from fixture where name = 'mirtazapin'),
      p_comparator_detail := '30 mg daglig',
      p_outcome_concept_id := (select id from fixture where name = 'weight'),
      p_outcome_detail := 'Gjennomsnittlig vektendring i kilogram.',
      p_timepoint_min := '8 weeks',
      p_timepoint_max := '12 weeks',
      p_timepoint_availability := 'reported_value',
      p_reported_direction := 'increase',
      p_effect_measure := 'mean_difference',
      p_estimate := 1.7,
      p_estimate_unit := 'kg',
      p_estimate_availability := 'reported_value',
      p_ci_lower := 0.9,
      p_ci_upper := 2.5,
      p_ci_level_percent := 95,
      p_confidence_interval_availability := 'reported_value',
      p_limitations_text := 'Åpen etikett i den ene armen.',
      p_source_locator := 'Tabell 2, side 5',
      p_source_quote := '  Mean difference 1.7 kg (95% CI 0.9 to 2.5).  '
    )
  $$,
  'et fullstendig utfylt evidensfunn lar seg registrere'
);
reset role;

select results_eq(
  $$
    select e.source_id, e.source_version_id, e.design_code::text,
           e.population_id, e.population_availability::text, e.population_detail,
           e.sample_size, e.sample_size_availability::text,
           e.intervention_drug_id, e.intervention_detail,
           e.comparator_kind::text, e.comparator_drug_id, e.comparator_detail,
           e.outcome_concept_id, e.outcome_detail,
           e.timepoint_min, e.timepoint_max, e.timepoint_availability::text,
           e.reported_direction::text, e.effect_measure::text, e.estimate,
           e.estimate_unit::text, e.estimate_availability::text,
           e.ci_lower, e.ci_upper, e.ci_level_percent,
           e.confidence_interval_availability::text,
           e.limitations_text, e.source_locator, e.created_by_actor_id
    from knowledge.evidence_items e
    where e.outcome_detail = 'Gjennomsnittlig vektendring i kilogram.'
  $$,
  $$
    values ('50390000-0000-4000-8000-000000000001'::uuid,
            '51390000-0000-4000-8000-000000000001'::uuid,
            'randomized_controlled_trial',
            (select id from fixture where name = 'population'), 'reported_value',
            'Voksne i testpopulasjonen for 390.',
            240, 'reported_value',
            (select id from fixture where name = 'sertralin'), '50 mg daglig',
            'drug', (select id from fixture where name = 'mirtazapin'), '30 mg daglig',
            (select id from fixture where name = 'weight'),
            'Gjennomsnittlig vektendring i kilogram.',
            interval '8 weeks', interval '12 weeks', 'reported_value',
            'increase', 'mean_difference', 1.7::numeric, 'kg', 'reported_value',
            0.9::numeric, 2.5::numeric, 95::numeric, 'reported_value',
            'Åpen etikett i den ene armen.', 'Tabell 2, side 5',
            (select id from fixture where name = 'actor_f'))
  $$,
  'raden bærer nøyaktig det oppgitte, og er attribuert til kalleren'
);

-- De fire kolonnene som ikke er parametre.
select is(
  (select e.extraction_method::text from knowledge.evidence_items e
   where e.outcome_detail = 'Gjennomsnittlig vektendring i kilogram.'),
  'manual',
  'ekstraksjonsmetoden er manual og kan ikke oppgis av kalleren: en registrering gjennom skjemaet ER en menneskelig ekstraksjon'
);
select is(
  (select e.raw_extraction from knowledge.evidence_items e
   where e.outcome_detail = 'Gjennomsnittlig vektendring i kilogram.'),
  jsonb_build_object('sitat', 'Mean difference 1.7 kg (95% CI 0.9 to 2.5).'),
  'det ordrette sitatet bevares i raw_extraction, trimmet og under den ene dokumenterte nøkkelen'
);
select matches(
  (select e.content_hash from knowledge.evidence_items e
   where e.outcome_detail = 'Gjennomsnittlig vektendring i kilogram.'),
  '^sha256-v[0-9]+:[0-9a-f]{64}$',
  'fingeravtrykket er satt av databasen, ikke av kalleren'
);

-- Valgfrie felter som ikke oppgis, forblir NULL — funksjonen finner ikke på noe
-- parameterlisten ikke oppga.
select results_eq(
  $$
    select e.source_version_id, e.population_id, e.sample_size, e.intervention_detail,
           e.comparator_drug_id, e.comparator_detail, e.timepoint_min, e.timepoint_max,
           e.effect_measure, e.estimate, e.estimate_unit, e.ci_lower, e.ci_upper,
           e.ci_level_percent, e.limitations_text, e.raw_extraction
    from knowledge.evidence_items e
    where e.outcome_detail = 'Vektendring, ikke tallfestet.'
  $$,
  $$
    values (null::uuid, null::uuid, null::integer, null::text,
            null::uuid, null::text, null::interval, null::interval,
            null::knowledge.effect_measure, null::numeric,
            null::knowledge.estimate_unit, null::numeric, null::numeric,
            null::numeric, null::text, null::jsonb)
  $$,
  'valgfrie felter som ikke oppgis, forblir NULL'
);

-- ===========================================================================
-- Del 6 — Auditraden som fulgte registreringen
-- ===========================================================================
select is(
  (select count(*)::integer from audit.events
   where object_id = (select e.id from knowledge.evidence_items e
                       where e.outcome_detail = 'Gjennomsnittlig vektendring i kilogram.')),
  1,
  'registreringen ga nøyaktig én auditrad'
);

select results_eq(
  $$
    select ev.operation::text, ev.object_schema, ev.object_table, ev.actor_id,
           ev.old_revision_or_snapshot,
           ev.new_revision_or_snapshot ->> 'source_locator',
           ev.new_revision_or_snapshot ->> 'extraction_method'
    from audit.events ev
    where ev.object_id = (select e.id from knowledge.evidence_items e
                           where e.outcome_detail = 'Gjennomsnittlig vektendring i kilogram.')
  $$,
  $$
    values ('evidence_item_created', 'knowledge', 'evidence_items',
            (select id from fixture where name = 'actor_f'),
            null::jsonb, 'Tabell 2, side 5', 'manual')
  $$,
  'auditraden peker på funnet, attribueres til den som registrerte det, har intet old-snapshot, og new-snapshotet er den faktiske raden'
);

-- ===========================================================================
-- Del 7 — Avvisningene fra tabellens egne regler, gjennom funksjonen
--
-- Ingen av dem er reimplementert i funksjonen. Poenget med testene er nettopp
-- at de kommer fra databasen og propageres uendret (§57).
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"39000000-0000-4000-8000-00000000000f"}', true);
set local role authenticated;

-- Nøyaktig samme registrering to ganger. Den ene avvisningen som er oversatt.
select throws_ok(
  $$select pg_temp.register(
      (select id from fixture where name = 'sleep'), 'Søvnkvalitet, ikke tallfestet.')$$,
  '23505', 'Nøyaktig det samme evidensfunnet er allerede registrert.',
  'en dublett avvises, med en setning framfor med constraint-navnet'
);

-- Null/ukjent-semantikken: en verdi uten en status som sier at den finnes.
select throws_ok(
  $$
    select api.create_evidence_item(
      p_source_id := '50390000-0000-4000-8000-000000000001',
      p_design_code := 'randomized_controlled_trial',
      p_population_availability := 'not_reported',
      p_population_detail := 'Populasjonen er ikke beskrevet i kilden.',
      p_sample_size := 100,
      p_sample_size_availability := 'not_reported',
      p_intervention_drug_id := (select id from fixture where name = 'sertralin'),
      p_comparator_kind := 'none',
      p_outcome_concept_id := (select id from fixture where name = 'weight'),
      p_outcome_detail := 'Utvalgsstørrelse uten status.',
      p_timepoint_availability := 'not_reported',
      p_reported_direction := 'not_stated',
      p_estimate_availability := 'not_reported',
      p_confidence_interval_availability := 'not_reported',
      p_source_locator := 'Avsnitt 1'
    )
  $$,
  '23514', null,
  'en verdi merket som ikke rapportert avvises av databasen, ikke lagret som om den var oppgitt'
);

-- Et estimat utenfor sitt eget konfidensintervall.
select throws_ok(
  $$
    select api.create_evidence_item(
      p_source_id := '50390000-0000-4000-8000-000000000001',
      p_design_code := 'randomized_controlled_trial',
      p_population_availability := 'not_reported',
      p_population_detail := 'Populasjonen er ikke beskrevet i kilden.',
      p_sample_size_availability := 'not_reported',
      p_intervention_drug_id := (select id from fixture where name = 'sertralin'),
      p_comparator_kind := 'none',
      p_outcome_concept_id := (select id from fixture where name = 'weight'),
      p_outcome_detail := 'Estimat utenfor intervallet.',
      p_timepoint_availability := 'not_reported',
      p_reported_direction := 'increase',
      p_effect_measure := 'mean_difference',
      p_estimate := 9.9,
      p_estimate_unit := 'kg',
      p_estimate_availability := 'reported_value',
      p_ci_lower := 0.9,
      p_ci_upper := 2.5,
      p_ci_level_percent := 95,
      p_confidence_interval_availability := 'reported_value',
      p_source_locator := 'Avsnitt 1'
    )
  $$,
  '23514', null,
  'et estimat utenfor sitt eget konfidensintervall avvises høyt framfor å bli lagret stille'
);

-- Vokabularkontrollen er databasens, ikke en klientside-gjetning.
select throws_ok(
  $$
    select api.create_evidence_item(
      p_source_id := '50390000-0000-4000-8000-000000000001',
      p_design_code := 'cohort_study',
      p_population_availability := 'not_reported',
      p_population_detail := 'Populasjonen er ikke beskrevet i kilden.',
      p_sample_size_availability := 'not_reported',
      p_intervention_drug_id := (select id from fixture where name = 'sertralin'),
      p_comparator_kind := 'none',
      p_outcome_concept_id := (select id from fixture where name = 'weight'),
      p_outcome_detail := 'Ukjent studiedesign.',
      p_timepoint_availability := 'not_reported',
      p_reported_direction := 'not_stated',
      p_estimate_availability := 'not_reported',
      p_confidence_interval_availability := 'not_reported',
      p_source_locator := 'Avsnitt 1'
    )
  $$,
  '22P02', null,
  'et studiedesign utenfor det kontrollerte vokabularet avvises av databasen, ikke antatt gyldig'
);

-- Kildeversjonen må tilhøre den samme kilden. Cross-row-regelen fra migrasjon
-- 003, håndhevet av den sammensatte fremmednøkkelen.
select throws_ok(
  $$select pg_temp.register(
      (select id from fixture where name = 'weight'), 'Kildeversjon fra en annen kilde.',
      '50390000-0000-4000-8000-000000000001',
      '51390000-0000-4000-8000-000000000002')$$,
  '23503', null,
  'en kildeversjon som tilhører en annen kilde avvises: proveniensen ville pekt et annet sted enn kilden'
);

-- Endepunktet må være et begrep av typen outcome.
select throws_ok(
  $$select pg_temp.register(
      (select id from fixture where name = 'condition'), 'Diagnose brukt som endepunkt.')$$,
  '23503', null,
  'et begrep av typen condition kan ikke brukes som endepunkt'
);

-- En tom kildepeker avvises av tabellens egen CHECK, ikke av funksjonen.
select throws_ok(
  $$
    select api.create_evidence_item(
      p_source_id := '50390000-0000-4000-8000-000000000001',
      p_design_code := 'randomized_controlled_trial',
      p_population_availability := 'not_reported',
      p_population_detail := 'Populasjonen er ikke beskrevet i kilden.',
      p_sample_size_availability := 'not_reported',
      p_intervention_drug_id := (select id from fixture where name = 'sertralin'),
      p_comparator_kind := 'none',
      p_outcome_concept_id := (select id from fixture where name = 'weight'),
      p_outcome_detail := 'Uten kildepeker.',
      p_timepoint_availability := 'not_reported',
      p_reported_direction := 'not_stated',
      p_estimate_availability := 'not_reported',
      p_confidence_interval_availability := 'not_reported',
      p_source_locator := ''
    )
  $$,
  '23514', null,
  'en tom kildepeker avvises av knowledge.evidence_items sin egen CHECK, ikke duplisert i funksjonen'
);

-- Komparatoren kan ikke være intervensjonen selv.
select throws_ok(
  $$
    select api.create_evidence_item(
      p_source_id := '50390000-0000-4000-8000-000000000001',
      p_design_code := 'randomized_controlled_trial',
      p_population_availability := 'not_reported',
      p_population_detail := 'Populasjonen er ikke beskrevet i kilden.',
      p_sample_size_availability := 'not_reported',
      p_intervention_drug_id := (select id from fixture where name = 'sertralin'),
      p_comparator_kind := 'drug',
      p_comparator_drug_id := (select id from fixture where name = 'sertralin'),
      p_outcome_concept_id := (select id from fixture where name = 'weight'),
      p_outcome_detail := 'Komparator lik intervensjon.',
      p_timepoint_availability := 'not_reported',
      p_reported_direction := 'not_stated',
      p_estimate_availability := 'not_reported',
      p_confidence_interval_availability := 'not_reported',
      p_source_locator := 'Avsnitt 1'
    )
  $$,
  '23514', null,
  'et virkestoff kan ikke være sin egen komparator'
);

reset role;
select set_config('request.jwt.claims', '', true);

-- ===========================================================================
-- Del 8 — Funnene er fortsatt uforanderlige, også de som kom denne veien
-- ===========================================================================
select throws_ok(
  $$
    update knowledge.evidence_items
    set source_locator = 'Endret i ettertid'
    where outcome_detail = 'Gjennomsnittlig vektendring i kilogram.'
  $$,
  '23001', null,
  'et registrert evidensfunn kan ikke endres i ettertid, heller ikke av tabelleieren'
);
select throws_ok(
  $$
    delete from knowledge.evidence_items
    where outcome_detail = 'Gjennomsnittlig vektendring i kilogram.'
  $$,
  '23001', null,
  'et registrert evidensfunn kan ikke slettes; en korreksjon er en ny rad'
);

select * from finish();

rollback;
