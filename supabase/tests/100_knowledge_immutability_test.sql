-- Migrasjon 003 — immutabilitet og databaseeide felter i knowledge.
--
-- MVP_IMPLEMENTATION_PLAN.md §20 krever en immutabilitetsstrategi for
-- EvidenceItem, §42 krever en eksplisitt negativ test på at en uforanderlig rad
-- ikke kan redigeres, og DATABASE_ARCHITECTURE.md §7.1 og §36 krever at
-- historikk verken overskrives eller slettes i vanlig redaksjonelt arbeid.
--
-- Valgt strategi: knowledge.evidence_items er append-only. Testen kontrollerer
-- både at vernet holder, og at det ikke overblokkerer: kilder skal fortsatt
-- kunne oppdateres, og et øyeblikksbilde skal kunne flytte lagringsreferansen
-- uten at selve observasjonen kan endres.
--
-- SQLSTATE 23001 = restrict_violation, 23505 = unique_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(30);

-- ---------------------------------------------------------------------------
-- Testdata som bare finnes inne i denne transaksjonen
-- ---------------------------------------------------------------------------

-- Migrasjon 005 gjorde created_by_actor_id påkrevd på kunnskapsobjektene
-- (ANTIDEP_CONSTITUTION.md §14). Testdata attribueres til den samme aktøren som
-- produserte de seedede radene, slik at fikstursradene ikke er mindre
-- attribuerte enn kunnskapsbasen ellers.
create function pg_temp.extraction_actor() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'agent:evidence-extraction'
$$;

insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
values ('journal_article', 'Immutabilitetstestkilde', 'Testforfatter I', pg_temp.extraction_actor());

insert into knowledge.source_versions
  (source_id, retrieved_at, retrieved_from, external_version, content_hash,
   retrieved_by_actor_id)
select id, timestamptz '2026-01-02T03:04:05Z', 'https://example.invalid/immutabilitet',
       'testversjon 1', 'sha256:' || repeat('b', 64), pg_temp.extraction_actor()
from knowledge.sources where title = 'Immutabilitetstestkilde';

create function pg_temp.insert_evidence(
  locator text,
  est numeric default 1.5,
  raw jsonb default null,
  method knowledge.extraction_method default 'ai_assisted'
) returns uuid language sql as $$
  insert into knowledge.evidence_items (
    source_id, source_version_id, design_code, population_id, population_availability,
    population_detail, sample_size, sample_size_availability, intervention_drug_id,
    comparator_kind, outcome_concept_id, outcome_detail,
    timepoint_min, timepoint_max, timepoint_availability,
    reported_direction, effect_measure, estimate, estimate_unit, estimate_availability,
    confidence_interval_availability, source_locator, extraction_method, raw_extraction,
    created_by_actor_id
  )
  select
    s.id, v.id, 'randomized_controlled_trial', p.id, 'reported_value',
    'Voksne med depressiv lidelse i testdata', 100, 'reported_value', d.id,
    'none', c.id, 'Gjennomsnittlig vektendring i testdata',
    interval '8 weeks', interval '8 weeks', 'reported_value',
    'increase', 'mean_change', est, 'kg', 'reported_value',
    'not_reported', locator, method, raw, pg_temp.extraction_actor()
  from knowledge.sources s
  join knowledge.source_versions v on v.source_id = s.id
  join catalog.drugs d on d.canonical_name = 'sertralin'
  join catalog.clinical_concepts c on c.canonical_label = 'vektendring'
  join catalog.populations p on p.canonical_label = 'voksne med depressiv lidelse'
  where s.title = 'Immutabilitetstestkilde'
  returning id;
$$;

select pg_temp.insert_evidence('Sammendrag, immutabilitetstest');

-- ---------------------------------------------------------------------------
-- knowledge.evidence_items er append-only
--
-- Hver kolonnegruppe testes for seg, slik at testen sier hvilken endring som
-- ble forsøkt, og slik at et halvveis vern ikke kan se ut som et helt.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$update knowledge.evidence_items set estimate = 9.9 where source_locator = 'Sammendrag, immutabilitetstest'$$,
  '23001', null,
  'estimatet på et evidensfunn kan ikke endres etter innsetting'
);
select throws_ok(
  $$update knowledge.evidence_items set estimate_availability = 'not_reported',
           estimate = null where source_locator = 'Sammendrag, immutabilitetstest'$$,
  '23001', null,
  'null/ukjent-statusen kan ikke endres etter innsetting'
);
select throws_ok(
  $$update knowledge.evidence_items set reported_direction = 'decrease' where source_locator = 'Sammendrag, immutabilitetstest'$$,
  '23001', null,
  'den rapporterte retningen kan ikke endres etter innsetting'
);
select throws_ok(
  $$update knowledge.evidence_items set source_locator = 'Et annet sted' where source_locator = 'Sammendrag, immutabilitetstest'$$,
  '23001', null,
  'kildepekeren kan ikke endres etter innsetting'
);
select throws_ok(
  $$update knowledge.evidence_items set population_id = null,
           population_availability = 'not_extractable' where source_locator = 'Sammendrag, immutabilitetstest'$$,
  '23001', null,
  'populasjonskoblingen kan ikke endres etter innsetting'
);
select throws_ok(
  $$update knowledge.evidence_items set limitations_text = 'Ny tekst' where source_locator = 'Sammendrag, immutabilitetstest'$$,
  '23001', null,
  'heller ikke fritekstfeltene kan endres; hele raden er uforanderlig'
);
select throws_ok(
  $$update knowledge.evidence_items set raw_extraction = '{}'::jsonb where source_locator = 'Sammendrag, immutabilitetstest'$$,
  '23001', null,
  'rå ekstraksjon kan ikke endres etter innsetting'
);

-- DATABASE_ARCHITECTURE.md §36: vanlig redaksjonelt arbeid skal ikke fysisk
-- slette kanonisk kunnskap.
select throws_ok(
  $$delete from knowledge.evidence_items where source_locator = 'Sammendrag, immutabilitetstest'$$,
  '23001', null,
  'et evidensfunn kan ikke slettes'
);
select throws_ok(
  $$delete from knowledge.evidence_items$$,
  '23001', null,
  'et forsøk på å tømme evidenstabellen avvises'
);

-- Korreksjonsveien er en ny rad ved siden av den gamle, ikke en overskriving.
select lives_ok(
  $$select pg_temp.insert_evidence('Sammendrag, korrigert ekstraksjon', 2.5)$$,
  'en korrigert ekstraksjon registreres som et nytt evidensfunn'
);
select is(
  (select count(*) from knowledge.evidence_items ei
   join knowledge.sources s on s.id = ei.source_id
   where s.title = 'Immutabilitetstestkilde'),
  2::bigint,
  'begge ekstraksjonene er bevart'
);

-- ---------------------------------------------------------------------------
-- content_hash eies av databasen
-- ---------------------------------------------------------------------------
select matches(
  (select content_hash from knowledge.evidence_items
   where source_locator = 'Sammendrag, immutabilitetstest'),
  '^sha256-v3:[0-9a-f]{64}$',
  'content_hash settes av databasen med versjonert algoritmeprefiks'
);

-- Testen oppgir bevisst en forfalsket hash. Uten trigger ville verdien blitt
-- lagret som den er.
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
  'Sammendrag, forfalsket hash', 'ai_assisted', 'sha256-v3:' || repeat('0', 64),
  pg_temp.extraction_actor()
from knowledge.sources s
join catalog.drugs d on d.canonical_name = 'sertralin'
join catalog.clinical_concepts c on c.canonical_label = 'vektendring'
where s.title = 'Immutabilitetstestkilde';

select isnt(
  (select content_hash from knowledge.evidence_items
   where source_locator = 'Sammendrag, forfalsket hash'),
  'sha256-v3:' || repeat('0', 64),
  'en hash oppgitt av kalleren ignoreres og overskrives av databasen'
);

-- Korreksjonsveien må virke for hvert felt, ikke bare for de kanoniske. Et
-- feilsitat i raw_extraction er nettopp det en verifikator kontrollerer mot
-- originalen (ANTIDEP_CONSTITUTION.md §11). Hashet bare de kanoniske feltene,
-- ville en rettet rad hatt samme hash som den feilsiterte og blitt avvist som
-- dublett — og raden kunne heller ikke oppdateres. Da hadde feilen vært umulig
-- å rette.
-- Egen kildepeker for denne gruppen, slik at radene ikke forstyrrer
-- oppslagene over. source_locator er selv et kanonisk felt, så den må være lik
-- på tvers av de tre radene for at testen skal si det den påstår.
select pg_temp.insert_evidence('Sammendrag, korreksjonsvei', 1.5,
  '{"resultat": "feilsitert ordrett sitat"}'::jsonb);

select lives_ok(
  $$select pg_temp.insert_evidence('Sammendrag, korreksjonsvei', 1.5,
      '{"resultat": "rettet ordrett sitat"}'::jsonb)$$,
  'en rettet råekstraksjon kan registreres selv om de kanoniske feltene er uendret'
);
select lives_ok(
  $$select pg_temp.insert_evidence('Sammendrag, korreksjonsvei', 1.5,
      '{"resultat": "feilsitert ordrett sitat"}'::jsonb, 'manual')$$,
  'en rettet ekstraksjonsmetode kan registreres selv om de kanoniske feltene er uendret'
);
select throws_ok(
  $$select pg_temp.insert_evidence('Sammendrag, korreksjonsvei', 1.5,
      '{"resultat": "feilsitert ordrett sitat"}'::jsonb)$$,
  '23505', null,
  'en helt identisk registrering avvises fortsatt som dublett'
);

-- Samme kanoniske innhold gir samme fingeravtrykk, og en dublett avvises.
select throws_ok(
  $$select pg_temp.insert_evidence('Sammendrag, immutabilitetstest')$$,
  '23505', null,
  'nøyaktig samme funn kan ikke registreres to ganger'
);
select isnt(
  (select content_hash from knowledge.evidence_items
   where source_locator = 'Sammendrag, immutabilitetstest'),
  (select content_hash from knowledge.evidence_items
   where source_locator = 'Sammendrag, korrigert ekstraksjon'),
  'to ulike funn får ulike fingeravtrykk'
);

-- ---------------------------------------------------------------------------
-- knowledge.source_versions — observasjonen er frosset, driftsfeltet er ikke
-- ---------------------------------------------------------------------------
select throws_ok(
  $$update knowledge.source_versions set retrieved_at = now()$$,
  '23001', null,
  'hentetidspunktet på et øyeblikksbilde kan ikke endres'
);
select throws_ok(
  $$update knowledge.source_versions set content_hash = 'sha256:' || repeat('c', 64)$$,
  '23001', null,
  'innholdshashen på et øyeblikksbilde kan ikke endres'
);
select throws_ok(
  $$update knowledge.source_versions set retrieved_from = 'https://example.invalid/annet'$$,
  '23001', null,
  'hentaddressen på et øyeblikksbilde kan ikke endres'
);
select throws_ok(
  $$update knowledge.source_versions set external_version = 'testversjon 2'$$,
  '23001', null,
  'kildens eget versjonsmerke kan ikke endres i ettertid'
);
-- Attribusjonen er en del av observasjonen (migrasjon 20260907091000). Uten
-- denne kontrollen kunne «hvem hentet dette» skrives om i ettertid, og
-- auditraden ville stått igjen som eneste spor av den opprinnelige verdien.
select throws_ok(
  $$update knowledge.source_versions
    set retrieved_by_actor_id = (
      select id from provenance.actors where actor_key = 'agent:claim-synthesis'
    )$$,
  '23001', null,
  'aktøren som hentet et øyeblikksbilde kan ikke byttes ut i ettertid'
);

-- Vernet skal ikke overblokkere: hvor et lagret øyeblikksbilde ligger er
-- driftsinformasjon.
select lives_ok(
  $$update knowledge.source_versions
    set storage_reference = 'lagring://testbøtte/immutabilitet.xml'$$,
  'lagringsreferansen kan oppdateres uten at observasjonen endres'
);

-- ---------------------------------------------------------------------------
-- knowledge.sources er bare delvis frosset (migrasjon 003a)
--
-- Vernet er smalt med hensikt, og begge sidene av grensen prøves: identiteten og
-- opphavet kan ikke endres, mens beskrivelsen kan korrigeres og statusen kan
-- endres når kilden trekkes tilbake. En test på bare den ene siden ville ikke
-- skilt et riktig avgrenset vern fra et som overblokkerer.
--
-- Den negative testen er den viktigste: uten den hviler «opphavet kan ikke
-- skrives om» på at framtidige skriveveier lar feltet være i fred, og en
-- attribusjon som kan skrives om av den som blir attribuert, er ingen
-- attribusjon (ANTIDEP_CONSTITUTION.md §14).
--
-- Aktøren det forsøkes byttet til er en annen ekte aktør, ikke en oppdiktet
-- uuid: ellers ville fremmednøkkelen kunnet avvise forsøket før triggeren kjørte,
-- og testen ville målt feil lag.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$
    update knowledge.sources
    set created_by_actor_id =
      (select id from provenance.actors where actor_key = 'agent:claim-synthesis')
    where title = 'Immutabilitetstestkilde'
  $$,
  '23001', null,
  'opphavet til en kilde kan ikke byttes til en annen aktør'
);
select throws_ok(
  $$
    update knowledge.sources set id = gen_random_uuid()
    where title = 'Immutabilitetstestkilde'
  $$,
  '23001', null,
  'en kilde kan ikke skifte identitet; auditloggen peker på den uten fremmednøkkel'
);
-- Kontroll av at de to over ikke er stille sanne: raden finnes, og den er
-- attribuert til ekstraksjonsaktøren slik fiksturen satte den.
select is(
  (select a.actor_key from knowledge.sources s
     join provenance.actors a on a.id = s.created_by_actor_id
   where s.title = 'Immutabilitetstestkilde'),
  'agent:evidence-extraction',
  'de avviste forsøkene lot opphavet stå urørt'
);

select lives_ok(
  $$update knowledge.sources set title = 'Immutabilitetstestkilde, rettet tittel'
    where title = 'Immutabilitetstestkilde'$$,
  'en kildebeskrivelse kan korrigeres'
);
select lives_ok(
  $$update knowledge.sources
    set source_status = 'retracted', status_note = 'Trukket tilbake i testdata'
    where title = 'Immutabilitetstestkilde, rettet tittel'$$,
  'en kilde kan trekkes tilbake uten at radene som peker på den slettes'
);

-- Tidsstemplene eies av databasen ved både INSERT og UPDATE.
update knowledge.sources
set created_at = '2000-01-01T00:00:00Z', updated_at = '2000-01-01T00:00:00Z'
where title = 'Immutabilitetstestkilde, rettet tittel';
select results_eq(
  $$
    select created_at = now(), updated_at = now()
    from knowledge.sources where title = 'Immutabilitetstestkilde, rettet tittel'
  $$,
  $$values (true, true)$$,
  'created_at bevares og updated_at settes av databasen, ikke av klienten'
);

select * from finish();

rollback;
