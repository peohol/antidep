-- Korreksjonsmigrasjon 006a — entydig serialisering av content_hash.
--
-- MVP_IMPLEMENTATION_PLAN.md §74.7 registrerte at
-- knowledge.set_evidence_item_content_hash() skjøtet de kanoniske feltene med
-- concat_ws('|', …) mens fritekstfelt lovlig kan inneholde «|», og at hashen er
-- UNIQUE. Konsekvensen var ikke en sammenblanding, men en avvisning: to
-- forskjellige evidensfunn kunne serialiseres likt, og det andre ville blitt
-- nektet innsatt som dublett. §42 krever eksplisitte negative tester på nettopp
-- den klassen feil, og ANTIDEP_CONSTITUTION.md §9 krever at motstridende
-- evidens kan bevares — et funn som ikke slipper inn, kan ikke motsi noe.
--
-- Testen bygger derfor to rader som *faktisk* kolliderte under den gamle
-- definisjonen. Fikstruren gjenskaper v1-kanoniseringen lokalt og påstår at de
-- to radene ga samme streng, slik at testen ikke bare hevder å teste
-- kollisjonen, men viser at den forelå.
--
-- SQLSTATE 23505 = unique_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(15);

-- ---------------------------------------------------------------------------
-- Testdata som bare finnes inne i denne transaksjonen
--
-- Milepæl B er ikke nådd, og ingenting er publisert (§74.4). Radene her
-- opprettes derfor inne i transaksjonen og rulles tilbake, framfor å seedes.
-- ---------------------------------------------------------------------------
create function pg_temp.extraction_actor() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'agent:evidence-extraction'
$$;

insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
values ('journal_article', 'Serialiseringstestkilde', 'Testforfatter S', pg_temp.extraction_actor());

-- To fritekstfelter som ligger ved siden av hverandre i kanoniseringen.
-- Alle andre felter er like, slik at forskjellen mellom radene er nøyaktig der
-- testen påstår den er.
create function pg_temp.insert_evidence(limits text, locator text)
  returns uuid language sql as $$
  insert into knowledge.evidence_items (
    source_id, design_code, population_id, population_availability,
    population_detail, sample_size, sample_size_availability, intervention_drug_id,
    comparator_kind, outcome_concept_id, outcome_detail,
    timepoint_min, timepoint_max, timepoint_availability,
    reported_direction, effect_measure, estimate, estimate_unit, estimate_availability,
    confidence_interval_availability, limitations_text, source_locator,
    extraction_method, created_by_actor_id
  )
  select
    s.id, 'randomized_controlled_trial', p.id, 'reported_value',
    'Voksne med depressiv lidelse i testdata', 100, 'reported_value', d.id,
    'none', c.id, 'Gjennomsnittlig vektendring i testdata',
    interval '8 weeks', interval '8 weeks', 'reported_value',
    'increase', 'mean_change', 1.5, 'kg', 'reported_value',
    'not_reported', limits, locator, 'ai_assisted', pg_temp.extraction_actor()
  from knowledge.sources s
  join catalog.drugs d on d.canonical_name = 'sertralin'
  join catalog.clinical_concepts c on c.canonical_label = 'vektendring'
  join catalog.populations p on p.canonical_label = 'voksne med depressiv lidelse'
  where s.title = 'Serialiseringstestkilde'
  returning id;
$$;

-- Den gamle kanoniseringen, gjenskapt ordrett fra migrasjon 003. Den finnes
-- bare her, og bare for å vise at fikstruren treffer den faktiske feilen.
create function pg_temp.v1_canonical(item knowledge.evidence_items)
  returns text language sql immutable as $$
  select concat_ws(
    '|', 'sha256-v1',
    item.source_id::text, coalesce(item.source_version_id::text, ''),
    item.design_code::text, coalesce(item.population_id::text, ''),
    item.population_availability::text, item.population_detail,
    coalesce(item.sample_size::text, ''), item.sample_size_availability::text,
    item.intervention_drug_id::text, coalesce(item.intervention_detail, ''),
    item.comparator_kind::text, coalesce(item.comparator_drug_id::text, ''),
    coalesce(item.comparator_detail, ''), item.outcome_concept_id::text,
    item.outcome_detail,
    coalesce(extract(epoch from item.timepoint_min)::text, ''),
    coalesce(extract(epoch from item.timepoint_max)::text, ''),
    item.timepoint_availability::text, item.reported_direction::text,
    coalesce(item.effect_measure::text, ''),
    coalesce(trim_scale(item.estimate)::text, ''),
    coalesce(item.estimate_unit::text, ''), item.estimate_availability::text,
    coalesce(trim_scale(item.ci_lower)::text, ''),
    coalesce(trim_scale(item.ci_upper)::text, ''),
    coalesce(trim_scale(item.ci_level_percent)::text, ''),
    item.confidence_interval_availability::text,
    coalesce(item.limitations_text, ''), item.source_locator,
    item.extraction_method::text, coalesce(item.raw_extraction::text, '')
  )
$$;

-- «Utvalget var lite|Tabell 2» + «side 7» og «Utvalget var lite» +
-- «Tabell 2|side 7» er to forskjellige registreringer: den ene sier at
-- begrensningen står i tabell 2, den andre at funnet er hentet derfra.
select pg_temp.insert_evidence('Utvalget var lite|Tabell 2', 'side 7');

-- ---------------------------------------------------------------------------
-- Den rettede skjøten
-- ---------------------------------------------------------------------------
select lives_ok(
  $$select pg_temp.insert_evidence('Utvalget var lite', 'Tabell 2|side 7')$$,
  'et evidensfunn som bare skiller seg fra et annet ved hvor skilletegnet står i fritekstfeltene, blir registrert'
);

select is(
  (select count(distinct pg_temp.v1_canonical(e))
   from knowledge.evidence_items e
   where e.source_locator in ('side 7', 'Tabell 2|side 7')),
  1::bigint,
  'de to radene ga samme kanoniske streng under den gamle definisjonen; fikstruren treffer den faktiske kollisjonen'
);

select is(
  (select count(distinct e.content_hash)
   from knowledge.evidence_items e
   where e.source_locator in ('side 7', 'Tabell 2|side 7')),
  2::bigint,
  'de samme to radene får ulike fingeravtrykk under den nye definisjonen'
);

-- Den andre halvdelen av feilen: nullbare felter ble coalesce-et til tom
-- streng, slik at NULL og '' var samme verdi. Ingen CHECK slipper i dag inn en
-- tom streng i et nullbart fritekstfelt, så skillet testes direkte mot
-- funksjonen, som er der kontrakten ligger.
select isnt(
  (select knowledge.evidence_item_content_hash(
            jsonb_populate_record(e, '{"intervention_detail": null}'::jsonb))
   from knowledge.evidence_items e where e.source_locator = 'side 7'),
  (select knowledge.evidence_item_content_hash(
            jsonb_populate_record(e, '{"intervention_detail": ""}'::jsonb))
   from knowledge.evidence_items e where e.source_locator = 'side 7'),
  'et felt som er NULL gir et annet fingeravtrykk enn det samme feltet som tom streng'
);

-- ---------------------------------------------------------------------------
-- Hvert kanonisk felt inngår faktisk i fingeravtrykket
--
-- Funksjonen tar hele raden som argument. Feltlisten er likevel eksplisitt, så
-- en kolonne som legges til senere blir ikke hashet av seg selv, og et
-- evidensfunn som skiller seg fra et annet bare på den kolonnen, ville blitt
-- avvist som dublett. Kontrollen er derfor kolonneuttømmende og ikke en liste
-- håndplukkede felter: den nuller ut én kolonne om gangen på en ferdig utfylt
-- rad og krever at fingeravtrykket endrer seg.
--
-- Raden bygges i minnet med jsonb_populate_record og settes aldri inn, slik at
-- den kan ha alle nullbare felter utfylt samtidig uten å bryte de kryssende
-- CHECK-ene på tabellen.
--
-- Unntakslisten er kontrakten for hva som bevisst ikke inngår: id og created_at
-- fordi fingeravtrykket identifiserer innhold og ikke rad, content_hash fordi
-- den er resultatet, required_outcome_type fordi den er en teknisk konstant, og
-- created_by_actor_id fordi kolonnen kom til i migrasjon 005 uten å bli tatt
-- inn i definisjonen, og agent_run_id/agent_run_role fordi fingeravtrykket
-- identifiserer *innholdet* i ekstraksjonen og ikke hvilken kjøring som
-- produserte det: to kjøringer som leser samme kilde og kommer fram til samme
-- verdier, skal fortsatt kollidere som dublett. Skal en ny kolonne holdes
-- utenfor, må den føres opp her.
-- ---------------------------------------------------------------------------
create function pg_temp.utfylt_rad() returns knowledge.evidence_items
  language sql stable as $$
  select jsonb_populate_record(e, jsonb_build_object(
    'source_version_id',   '11111111-1111-4111-8111-111111111111',
    'population_id',       '22222222-2222-4222-8222-222222222222',
    'sample_size',         137,
    'intervention_detail', 'sertralin 50 mg daglig',
    'comparator_drug_id',  '33333333-3333-4333-8333-333333333333',
    'comparator_detail',   'mirtazapin 30 mg daglig',
    'timepoint_min',       '8 weeks',
    'timepoint_max',       '12 weeks',
    'effect_measure',      'mean_difference',
    'estimate',            1.5,
    'estimate_unit',       'kg',
    'ci_lower',            0.4,
    'ci_upper',            2.6,
    'ci_level_percent',    95,
    'limitations_text',    'Kort oppfølgingstid',
    'raw_extraction',      jsonb_build_object('sitat', 'ordrett')
  ))
  from knowledge.evidence_items e where e.source_locator = 'side 7'
$$;

select is_empty(
  $$
    select a.attname
    from pg_attribute a
    where a.attrelid = 'knowledge.evidence_items'::regclass
      and a.attnum > 0
      and not a.attisdropped
      and a.attname not in (
        'id', 'content_hash', 'created_at', 'created_by_actor_id',
        'required_outcome_type', 'agent_run_id', 'agent_run_role'
      )
      and knowledge.evidence_item_content_hash(
            jsonb_populate_record(
              pg_temp.utfylt_rad(), jsonb_build_object(a.attname, null))
          ) = knowledge.evidence_item_content_hash(pg_temp.utfylt_rad())
  $$,
  'hver kanonisk kolonne på et evidensfunn påvirker fingeravtrykket'
);

-- ---------------------------------------------------------------------------
-- Det som ikke skal ha endret seg
-- ---------------------------------------------------------------------------
select throws_ok(
  $$select pg_temp.insert_evidence('Utvalget var lite', 'Tabell 2|side 7')$$,
  '23505', null,
  'nøyaktig samme registrering avvises fortsatt som dublett'
);

-- Testen oppgir bevisst en forfalsket hash med gyldig format og gjeldende
-- prefiks, slik at assertion bare kan holde fordi databasen faktisk regnet ut
-- verdien på nytt.
insert into knowledge.evidence_items (
  source_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, content_hash, created_by_actor_id
)
select
  s.id, 'randomized_controlled_trial', 'not_extractable', 'Testpopulasjon',
  'not_reported', d.id, 'none', c.id, 'Testutfall', 'not_reported',
  'not_stated', 'not_reported', 'not_reported',
  'Serialiseringstest, forfalsket hash', 'ai_assisted',
  'sha256-v2:' || repeat('0', 64), pg_temp.extraction_actor()
from knowledge.sources s
join catalog.drugs d on d.canonical_name = 'sertralin'
join catalog.clinical_concepts c on c.canonical_label = 'vektendring'
where s.title = 'Serialiseringstestkilde';

select isnt(
  (select content_hash from knowledge.evidence_items
   where source_locator = 'Serialiseringstest, forfalsket hash'),
  'sha256-v2:' || repeat('0', 64),
  'en hash oppgitt av kalleren ignoreres og overskrives av databasen'
);

-- ---------------------------------------------------------------------------
-- Migrasjonen etterlot ingen halv tilstand
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select id, content_hash from knowledge.evidence_items
    where content_hash !~ '^sha256-v2:[0-9a-f]{64}$'
  $$,
  'ingen rad står igjen på en eldre hashdefinisjon etter rehashingen'
);

select is(
  (select count(distinct content_hash) from knowledge.evidence_items e
   join knowledge.sources s on s.id = e.source_id
   where s.title <> 'Serialiseringstestkilde'
     and e.content_hash ~ '^sha256-v2:[0-9a-f]{64}$'),
  2::bigint,
  'de to seedede evidensfunnene er rehashet til den nye definisjonen og har fortsatt hvert sitt fingeravtrykk'
);

-- ---------------------------------------------------------------------------
-- Kontrakten til den nye funksjonen
--
-- At den ikke er kjørbar for PUBLIC, dekkes uttømmende for hele knowledge av
-- 080_knowledge_structure_test.sql, og gjentas ikke her.
-- ---------------------------------------------------------------------------
select is(
  (select p.provolatile from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'knowledge' and p.proname = 'evidence_item_content_hash'),
  'i'::"char",
  'kanoniseringen er IMMUTABLE; den leser ingenting utenfor argumentet'
);

-- Samme aksepterte skrivemåter som i 030_conventions_test.sql.
select is_empty(
  $$
    select array_to_string(p.proconfig, ', ')
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'knowledge'
      and p.proname = 'evidence_item_content_hash'
      and not exists (
        select 1 from unnest(coalesce(p.proconfig, array[]::text[])) as cfg
        where cfg in ('search_path=""', 'search_path=')
      )
  $$,
  'kanoniseringen kjører med tom search_path og schemakvalifiserte navn'
);

-- ---------------------------------------------------------------------------
-- Databasekommentarer skal ikke navngi funksjoner som ikke finnes
--
-- Kolonnekommentaren på catalog.drugs.updated_at viste til
-- catalog.set_updated_at(), som aldri har eksistert; funksjonen heter
-- catalog.set_row_timestamps(). Feilen lå fra migrasjon 002 fordi ingenting
-- kontrollerte klassen. Vakten er derfor generell, ikke en enkeltassertion.
--
-- En kommentar som skal peke framover på noe som ennå ikke finnes, skriver
-- navnet uten parentes; vakten leser bare referanser på kallform.
-- ---------------------------------------------------------------------------
-- pg_description identifiserer et objekt med paret (classoid, objoid), ikke med
-- objoid alene: OID-ene er unike innenfor hver systemkatalog, ikke på tvers av
-- dem. Et oppslag som bare joiner på objoid kan derfor treffe en urelatert rad i
-- en annen katalog. Migrasjon 007 gjorde dette relevant — policykommentarene der
-- er de første kommentarene i Antidep-schemaene som verken beskriver en
-- relasjon, en funksjon eller en type — så hver gren binder nå sin egen
-- classoid, og policyer er tatt inn i vakten framfor å falle utenfor den.
create view pg_temp.commented_object as
select n.nspname as schema_name, c.relname as object_name, d.description
from pg_description d
join pg_class c on c.oid = d.objoid and d.classoid = 'pg_class'::regclass
join pg_namespace n on n.oid = c.relnamespace
union all
select n.nspname, p.proname, d.description
from pg_description d
join pg_proc p on p.oid = d.objoid and d.classoid = 'pg_proc'::regclass
join pg_namespace n on n.oid = p.pronamespace
union all
select n.nspname, t.typname, d.description
from pg_description d
join pg_type t on t.oid = d.objoid and d.classoid = 'pg_type'::regclass
join pg_namespace n on n.oid = t.typnamespace
union all
select n.nspname, c.relname || '.' || pol.polname, d.description
from pg_description d
join pg_policy pol on pol.oid = d.objoid and d.classoid = 'pg_policy'::regclass
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace;

create view pg_temp.violation_comment_names_missing_function as
select distinct
  x.schema_name || '.' || x.object_name as beskrevet_objekt,
  m[1] as funksjonsreferanse
from pg_temp.commented_object x
cross join lateral
  regexp_matches(x.description, '([a-z_]+\.[a-z_]+\([a-z_, .]*\))', 'g') m
where x.schema_name in ('catalog', 'knowledge', 'workflow', 'provenance', 'audit', 'api')
  and to_regprocedure(m[1]) is null;

select is_empty(
  $$select * from pg_temp.violation_comment_names_missing_function$$,
  'ingen kommentar i de kanoniske schemaene navngir en funksjon som ikke finnes'
);

select is(
  col_description('catalog.drugs'::regclass, (
    select attnum from pg_attribute
    where attrelid = 'catalog.drugs'::regclass and attname = 'updated_at'
  )),
  'Tidspunkt for siste metadataendring på identitetsraden. Settes av catalog.set_row_timestamps().',
  'kolonnekommentaren på catalog.drugs.updated_at navngir triggerfunksjonen som faktisk setter feltet'
);

-- ---------------------------------------------------------------------------
-- Selvtest: de to schemauttømmende vaktene skal fange bevisste brudd
--
-- En vakt som ikke er mutasjonstestet, sier bare at den ikke fant noe — ikke at
-- den ville funnet noe. Begge bruddene plantes her og rulles tilbake med
-- transaksjonen.
-- ---------------------------------------------------------------------------
create table knowledge.bad_probe_comment (id uuid primary key);
comment on table knowledge.bad_probe_comment is
  'Bevisst brudd: viser til knowledge.finnes_ikke_her() som ikke er definert.';

select bag_eq(
  $$select funksjonsreferanse from pg_temp.violation_comment_names_missing_function
    where beskrevet_objekt = 'knowledge.bad_probe_comment'$$,
  $$values ('knowledge.finnes_ikke_her()')$$,
  'kommentarvakten fanger en kommentar som navngir en funksjon som ikke finnes'
);

-- Den nye grenen selvtestes på samme måte: en policykommentar skal holdes til
-- samme standard som en tabellkommentar. Uten denne kontrollen ville
-- policygrenen kunnet være stille ødelagt.
alter table knowledge.bad_probe_comment enable row level security;
create policy bad_probe_comment_read on knowledge.bad_probe_comment
  for select to authenticated using (true);
comment on policy bad_probe_comment_read on knowledge.bad_probe_comment is
  'Bevisst brudd: viser til knowledge.heller_ikke_her() som ikke er definert.';

select bag_eq(
  $$select funksjonsreferanse from pg_temp.violation_comment_names_missing_function
    where beskrevet_objekt = 'knowledge.bad_probe_comment.bad_probe_comment_read'$$,
  $$values ('knowledge.heller_ikke_her()')$$,
  'kommentarvakten dekker også policykommentarer'
);

select * from finish();
rollback;
