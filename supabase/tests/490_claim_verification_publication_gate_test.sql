-- Migrasjon 005j og publiseringsgatens G8, G9, G9b og G9c.
--
-- 250_publication_gate_test.sql går gjennom hele gaten punkt for punkt. Denne
-- filen tar de fire punktene som gjelder claim-verifikasjonen, og gjør det med
-- rader registrert gjennom den faktiske skriveveien framfor skrevet rett inn i
-- tabellen — slik at kjeden fra `api.register_claim_verification(...)` til gaten
-- er prøvd i sammenheng.
--
-- Rekkefølgen er den samme som i 250: hver forutsetning legges til én om gangen,
-- slik at hver gate prøves alene. Fixturen stopper bevisst før evidensvurderingen
-- (G10): når gaten svarer «mangler evidensvurdering», har den passert G8, G9,
-- G9b og G9c, og det er nettopp den positive assertionen for alle fire.
--
-- SQLSTATE 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(11);

-- ===========================================================================
-- Fikstur: en revisjon der alt fram til claim-verifikasjonen er på plass
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'extraction_verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';
insert into fixture (name, id) select 'claim_verifier', id from provenance.actors where actor_key = 'agent:citation-support-verification';

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('49000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 490',
        'Testforfatter 490', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id
)
values
  ('49000000-0000-4000-8000-000000000021', '49000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/490-a', 'sha256:' || repeat('a', 64),
   (select id from fixture where name = 'extractor')),
  ('49000000-0000-4000-8000-000000000022', '49000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/490-b', 'sha256:' || repeat('b', 64),
   (select id from fixture where name = 'extractor'));

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values
  ('49000000-0000-4000-8000-000000000011', '49000000-0000-4000-8000-000000000001',
   '49000000-0000-4000-8000-000000000021',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 490.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Første funn, for 490.',
   'not_reported', 'increase', 'not_reported', 'not_reported',
   'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor')),
  ('49000000-0000-4000-8000-000000000012', '49000000-0000-4000-8000-000000000001',
   '49000000-0000-4000-8000-000000000022',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 490.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Andre funn, for 490.',
   'not_reported', 'increase', 'not_reported', 'not_reported',
   'Avsnitt 2', 'ai_assisted', (select id from fixture where name = 'extractor'));

with c as (
  insert into knowledge.claims (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', (select id from fixture where name = 'weight'),
         (select id from fixture where name = 'sertralin'),
         (select id from fixture where name = 'synthesis')
  returning id, knowledge_type, subject_drug_id, created_by_actor_id
)
insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
select '49000000-0000-4000-8000-000000000031', c.id, 1, c.knowledge_type, c.subject_drug_id,
       'Testpåstand for 490.', 'Gjelder bare som testdata i 490.', 'none', 'increase',
       'Testusikkerhet.', c.created_by_actor_id
from c;

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('49000000-0000-4000-8000-000000000041', '49000000-0000-4000-8000-000000000031',
        '49000000-0000-4000-8000-000000000011', 'supports', 'direct',
        'Første lenke i 490.', (select id from fixture where name = 'synthesis'));

-- Ekstraksjonsverifikasjonene, med full dekning, slik at G4, G5 og G5b er ute av
-- veien og gaten faktisk kommer fram til claim-verifikasjonen.
-- Den kildeomfattende halvdelen av et globalt fravær (`not_reported`,
-- `not_measured`) kan bare føres opp av en maskinell kontroll med sin egen
-- agentkjøring (migrasjon 005ae,
-- evidence_verifications_source_wide_absence_check): ingen menneskelig
-- kontrolløkt søker gjennom hele representasjonen, og blir aldri spurt om det.
-- En fikstur som skal ha full dekning, trenger derfor begge leddene.
create function pg_temp.cover_source_wide_absence(p_evidence_item_id uuid)
  returns void
  language plpgsql
as $fn$
declare
  v_run_id uuid;
  v_actor_id uuid;
begin
  -- Fører ikke raden en slik påstand, kreves feltet ikke, og en rad som førte
  -- det opp ville påstått en kontroll av ingenting.
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
         'Fikstur: et søk gjennom hele den kontrollerte representasjonen fant ingen verdi '
         || 'for de feltene raden fører som fraværende i kilden.',
         now() - interval '30 days', v_run_id
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;
end;
$fn$;

-- Den maskinelle halvdelen først, slik at den menneskelige kontrollen blir
-- den gjeldende (registreringsrekkefølgen avgjør, migrasjon 005å).
select pg_temp.cover_source_wide_absence(e.id)
from knowledge.evidence_items e
where e.id in ('49000000-0000-4000-8000-000000000011', '49000000-0000-4000-8000-000000000012');

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'verified', 'original_source',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Prøve i 490: fullstendig kontrollert ekstraksjon.', now()
from knowledge.evidence_items e
where e.id in ('49000000-0000-4000-8000-000000000011', '49000000-0000-4000-8000-000000000012');

-- Legitimasjon og en åpen kjøring for claim-verifikatoren.
create temporary table cred (label text primary key, secret text);
insert into cred select 'claim', provenance.issue_agent_identity_credential(
  'agent-identity:citation-support-verification-01', 'human:peder-holman');
grant select on cred to anon;
create temporary table run (label text primary key, id uuid);
grant insert, select on run to anon;

-- now() er transaksjonens starttidspunkt, så hver kontroll som registreres i
-- denne testen ville fått samme verified_at og samme created_at, og «den siste»
-- ville vært avgjort av en tilfeldig uuid. Hver gang en ny kontroll skal
-- registreres, dyttes derfor de foregående en time bakover — den samme
-- rekkefølgen en reell kjøring får av at hver registrering er sin egen
-- transaksjon.
--
-- Vernet mot endring slås av med session_replication_role og ikke med
-- ALTER TABLE, og det er en nødvendighet og ikke en smakssak: den utsatte
-- dekningskontrollen har ventende hendelser etter hver registrering, og en
-- ALTER TABLE på tabellen ville feilet med «pending trigger events». Vinduet er
-- like smalt, og oppdateringen rører bare tidsstempler.
create function pg_temp.age_earlier_verifications() returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update workflow.claim_verifications
  set verified_at = verified_at - interval '1 hour',
      created_at = created_at - interval '1 hour'
  where claim_revision_id = '49000000-0000-4000-8000-000000000031';
  set local session_replication_role = origin;
end;
$$;

set local role anon;
insert into run select 'r', api.begin_agent_run(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  'citation_support_verification', 'testleverandør', 'testmodell', '2026-09-08',
  'claim-verification/1', 'antidep-evidence/1', '{"mode": "test-490"}'::jsonb);
reset role;

-- ===========================================================================
-- G8 — det finnes ingen kontroll
-- ===========================================================================
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '49000000-0000-4000-8000-000000000031')$$,
  '%ingen registrert claim-verifikasjon%',
  'gaten avviser publisering av en påstand ingen har kontrollert mot grunnlaget'
);

-- ===========================================================================
-- G9 — en uavklart kontroll er ingen bekreftelse
--
-- Dette er utfallet den deterministiske kjøreren faktisk produserer: den kan
-- falsifisere, men aldri bekrefte, fordi urepresentert motstridende evidens
-- ikke lar seg utelukke fra basen alene (ANTIDEP_CONSTITUTION.md §17).
-- ===========================================================================
set local role anon;
select api.register_claim_verification(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  (select id from run where label = 'r'), '49000000-0000-4000-8000-000000000031',
  'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
  jsonb_build_array(jsonb_build_object(
    'claim_evidence_link_id', '49000000-0000-4000-8000-000000000041',
    'source_access', 'verifiable_representation',
    'source_version_id', '49000000-0000-4000-8000-000000000021',
    'checked_content_hash', 'sha256:' || repeat('a', 64),
    'relationship_supported', 'not_assessable',
    'finding', 'Prøve i 490: relasjonstypen lot seg ikke bedømme.')),
  'Prøve i 490: deterministisk kontroll som ikke konkluderte.',
  'Ordlyden og forbeholdene krever språkforståelse.');
reset role;

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '49000000-0000-4000-8000-000000000031')$$,
  '%konkluderer ikke med verified%',
  'en uavklart claim-verifikasjon blokkerer, og teller ikke som bestått (ANTIDEP_CONSTITUTION.md §6)'
);

-- ===========================================================================
-- En bekreftelse slipper de fire punktene gjennom
--
-- Alle sju kontrollpunktene og alle kontrollradene må holde. At den
-- deterministiske kjøreren aldri kommer hit, er en egenskap ved kjøreren og
-- ikke ved gaten: en menneskelig reviewer eller et senere modellbasert ledd kan.
-- Fixturen registrerer den gjennom den samme skriveveien, slik at
-- fullstendighetskontrollen faktisk kjører på veien inn.
-- ===========================================================================
-- Den utsatte dekningskontrollen kjører ellers først ved commit, og denne
-- transaksjonen avsluttes med rollback. Den tvinges derfor fram her, mens
-- evidenssettet fortsatt er det kontrollen faktisk gjaldt — så assertionen er en
-- prøve på at registreringen over dekker settet sitt, og ikke bare på at den
-- gikk gjennom skriveveien.
select lives_ok(
  $$set constraints all immediate$$,
  'den utsatte dekningskontrollen godtar den registrerte kontrollen når den tvinges fram'
);
set constraints all deferred;

select pg_temp.age_earlier_verifications();
set local role anon;
select api.register_claim_verification(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  (select id from run where label = 'r'), '49000000-0000-4000-8000-000000000031',
  'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
  jsonb_build_array(jsonb_build_object(
    'claim_evidence_link_id', '49000000-0000-4000-8000-000000000041',
    'source_access', 'verifiable_representation',
    'source_version_id', '49000000-0000-4000-8000-000000000021',
    'checked_content_hash', 'sha256:' || repeat('a', 64),
    'relationship_supported', 'ok')),
  'Prøve i 490: kontrollen holder på alle punkter.');
reset role;

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '49000000-0000-4000-8000-000000000031')$$,
  '%mangler evidensvurdering%',
  'gaten er forbi G8, G9, G9b og G9c: den neste innvendingen gjelder evidensvurderingen'
);

-- Den nyeste kontrollen er den gjeldende, uansett hvor mange bekreftelser som
-- ligger foran den (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29).
select is(
  (select cv.outcome::text from workflow.claim_verifications cv
   where cv.claim_revision_id = '49000000-0000-4000-8000-000000000031'
   order by cv.verified_at desc, cv.created_at desc, cv.id desc limit 1),
  'verified',
  'begge kontrollene består ved siden av hverandre; den siste er den gjeldende'
);
select is(
  (select count(*)::integer from workflow.claim_verifications
   where claim_revision_id = '49000000-0000-4000-8000-000000000031'),
  2,
  'den uavklarte kontrollen er ikke overskrevet: tabellen er append-only'
);

-- ===========================================================================
-- G9b — en kontroll av et smalere grunnlag er ikke en kontroll av det utvidede
-- ===========================================================================
insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('49000000-0000-4000-8000-000000000042', '49000000-0000-4000-8000-000000000031',
        '49000000-0000-4000-8000-000000000012', 'contradicts', 'direct',
        'Motstridende funn lagt til etter kontrollen.',
        (select id from fixture where name = 'synthesis'));

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '49000000-0000-4000-8000-000000000031')$$,
  '%endret etter den gjeldende claim-verifikasjonen%',
  'et evidenssett som er utvidet etter kontrollen gjør bekreftelsen utdatert — og den nye lenken er nettopp den motstridende evidensen kontrollen skulle lete etter'
);

-- En ny kontroll som dekker hele det utvidede settet åpner den igjen.
select pg_temp.age_earlier_verifications();
set local role anon;
select api.register_claim_verification(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  (select id from run where label = 'r'), '49000000-0000-4000-8000-000000000031',
  'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
  jsonb_build_array(
    jsonb_build_object(
      'claim_evidence_link_id', '49000000-0000-4000-8000-000000000041',
      'source_access', 'verifiable_representation',
      'source_version_id', '49000000-0000-4000-8000-000000000021',
      'checked_content_hash', 'sha256:' || repeat('a', 64),
      'relationship_supported', 'ok'),
    jsonb_build_object(
      'claim_evidence_link_id', '49000000-0000-4000-8000-000000000042',
      'source_access', 'verifiable_representation',
      'source_version_id', '49000000-0000-4000-8000-000000000022',
      'checked_content_hash', 'sha256:' || repeat('b', 64),
      'relationship_supported', 'ok')),
  'Prøve i 490: fornyet kontroll som dekker hele det utvidede grunnlaget.');
reset role;

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '49000000-0000-4000-8000-000000000031')$$,
  '%mangler evidensvurdering%',
  'en fornyet kontroll som dekker hele settet gjør revisjonen publiserbar igjen så langt claim-verifikasjonen rekker'
);

-- ===========================================================================
-- G9c — feil rolle, lest der konsekvensen inntreffer
--
-- Migrasjon 005j stenger dette ved innsetting. Denne delen prøver det andre
-- laget: en rad som mot formodning kom forbi det første — gjennom en senere
-- skrivevei, en vedlikeholdsoperasjon eller en rad skrevet før regelen fantes —
-- skal ikke kunne bære en publisering. Triggeren slås derfor av i det smalest
-- mulige vinduet, slik en slik rad ville sett ut.
-- ===========================================================================
select pg_temp.age_earlier_verifications();

-- Raden skrives med session_replication_role og ikke ved å slå av
-- mandattriggeren med ALTER TABLE: den utsatte dekningskontrollen har ventende
-- hendelser etter registreringene over, og en ALTER TABLE på tabellen ville
-- feilet med «pending trigger events». Sideeffekten er at heller ikke
-- avtrykktriggeren kjører, så avtrykket oppgis eksplisitt — hvilket er nettopp
-- det en rad som kom en annen vei ville hatt.
--
-- Raden får sine egne kontrollrader, slik at den er fullstendig på alle andre
-- måter: det eneste som skiller den fra en gyldig kontroll, er mandatet.
-- Registreringsnummeret oppgis av samme grunn som avtrykket: triggeren som
-- tildeler det (migrasjon 005å) er også slått av, og en rad uten nummer ville
-- ikke hatt noen plass i rekkefølgen.
set local session_replication_role = replica;
with parent as (
  insert into workflow.claim_verifications
    (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
     source_access, source_support, population_match, comparator_match, timeframe_match,
     direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
     rationale, verified_at, verified_evidence_set_digest, registration_ordinal)
  select '49000000-0000-4000-8000-000000000031',
         (select id from fixture where name = 'synthesis'),
         (select id from fixture where name = 'extractor'),
         'verified', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
         'Prøve i 490: kontroll registrert av en aktør uten mandat.', now(),
         knowledge.claim_evidence_set_digest('49000000-0000-4000-8000-000000000031'),
         nextval('workflow.claim_verification_registration_seq')
  returning id, claim_revision_id
)
insert into workflow.claim_verification_citations
  (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
   source_access, relationship_supported)
select parent.id, l.claim_revision_id, l.id, l.evidence_item_id, 'original_source', 'ok'
from parent
join knowledge.claim_evidence_links l on l.claim_revision_id = parent.claim_revision_id;
set local session_replication_role = origin;

select is(
  (select workflow.claim_verifier_has_mandate(
     (select id from fixture where name = 'extractor'),
     '49000000-0000-4000-8000-000000000031', now())),
  false,
  'ekstraksjonsagenten har ikke mandat til å kontrollere en påstand mot grunnlaget'
);
select is(
  (select workflow.claim_verifier_has_mandate(
     (select id from fixture where name = 'claim_verifier'),
     '49000000-0000-4000-8000-000000000031', now())),
  true,
  'claim-verifikatoren har det, i kraft av rollen sin'
);

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '49000000-0000-4000-8000-000000000031')$$,
  '%uten mandat%',
  'gaten avviser en publisering som hviler på en kontroll fra en aktør uten mandatet, selv når kontrollen sier verified'
);

select finish();

rollback;
