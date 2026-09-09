-- Migrasjon 006 — publiseringsgaten, punkt for punkt.
--
-- Dette er den viktigste testfilen i steget. DATABASE_ARCHITECTURE.md §38 lister
-- hva publiseringsoperasjonen skal kontrollere, og MVP_IMPLEMENTATION_PLAN.md
-- §42 krever eksplisitte negative tester på at systemet nekter å publisere uten
-- evidens, uten menneskelig review, og når revisjonen er endret etter review.
--
-- Testen er bygget opp trinnvis: revisjonen starter uten noe som helst, og hver
-- forutsetning legges til én om gangen. Hver assertion viser at gaten avviser
-- nøyaktig det som mangler, og den siste at den slipper gjennom når alt er på
-- plass. Rekkefølgen er ikke tilfeldig — den gjør at hver gate testes alene, uten
-- at en annen manglende forutsetning kunne avvist den samme raden.
--
-- Deretter legges blokkerende funn til én om gangen på en revisjon som allerede
-- passerer, og fjernes igjen ved at en nyere beslutning eller kontroll gjelder
-- foran den. Hver blokkering har derfor både en negativ og en positiv assertion,
-- slik at ingen av dem kan passere fordi gaten avviser alt.
--
-- Revieweren i fixturen har en generell reviewer-rolle uten scope. Det er den
-- normale tildelingen, og den er tilstrekkelig for alle tre kunnskapstypene. At
-- en tildeling som *er* avgrenset til et klinisk tema må dekke påstandens tema,
-- håndheves når beslutningen registreres og er testet i
-- 190_workflow_constraints_test.sql.
--
-- Fixturen bruker daterte hendelsestidspunkter bakover i tid, fordi de kallerstyrte
-- tidspunktene er bundet mot databaseeide created_at og now() er konstant gjennom
-- transaksjonen. To tidsstempeltriggere slås derfor av mens fixturen bygges, i et
-- så smalt vindu som mulig, slik at rolletildelingene og evidenslenkene kan ligge
-- før godkjenningene som viser til dem — som er den realistiske rekkefølgen.
begin;

create extension if not exists pgtap with schema extensions;

select plan(38);

create temporary table fixture (name text primary key, id uuid not null) on commit drop;

-- ---------------------------------------------------------------------------
-- Aktører, brukerkontoer og roller
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'reviewer-250@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'verifier-250@test.invalid');

insert into provenance.actors (actor_type, actor_key, display_name, description, auth_user_id)
values
  ('human', 'human:reviewer-250', 'Reviewer',
   'Kvalifisert redaktør med generell reviewer-rolle.',
   'bbbbbbbb-0000-0000-0000-000000000001'),
  ('human', 'human:verifier-250', 'Verifikator',
   'Utfører ekstraksjons- og claim-verifikasjoner i testene.',
   'bbbbbbbb-0000-0000-0000-000000000003');

insert into fixture (name, id)
select 'reviewer_global', id from provenance.actors where actor_key = 'human:reviewer-250';
insert into fixture (name, id)
select 'verifier', id from provenance.actors where actor_key = 'human:verifier-250';
insert into fixture (name, id)
select 'synthesis_actor', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id)
select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'drug', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id)
select 'evidence_a', e.id from knowledge.evidence_items e
join knowledge.sources s on s.id = e.source_id
where s.title like 'Fluoxetine versus sertraline%';
insert into fixture (name, id)
select 'evidence_b', e.id from knowledge.evidence_items e
join knowledge.sources s on s.id = e.source_id
where s.title like 'Comparison of the effects of mirtazapine%';

-- Rolletildelingene må ha eksistert før godkjenningene som viser til dem
-- (workflow.enforce_reviewer_qualification()). created_at eies av databasen, så
-- triggeren slås av i det smalest mulige vinduet.
alter table workflow.user_roles disable trigger user_roles_set_row_timestamps;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason, created_at)
values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'verifier'), 'Generell reviewer-rolle.',
   now() - interval '1 year'),
  -- Verifikatoren trenger selv reviewer-rollen fra og med migrasjon 005j: en
  -- claim-verifikasjon krever mandat, og for et menneske er mandatet nettopp
  -- reviewer-rollen for innholdsområdet (MVP_IMPLEMENTATION_PLAN.md §74.30
  -- punkt 3). Rollen er ikke det samme som godkjenningsretten — det er
  -- reviewbeslutningen i workflow.review_decisions som er godkjenningen, og den
  -- registreres av reviewer-250.
  ('bbbbbbbb-0000-0000-0000-000000000003', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'reviewer_global'), 'Generell reviewer-rolle for verifikatoren.',
   now() - interval '1 year');
alter table workflow.user_roles enable trigger user_roles_set_row_timestamps;

-- ---------------------------------------------------------------------------
-- Målrevisjonen: en evidenssyntese uten noen forutsetninger oppfylt
-- ---------------------------------------------------------------------------
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'drug' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Testpåstand for publiseringsgaten.',
         'Gjelder bare testene i denne filen.',
         'none', 'Testusikkerhet.', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'claim')
  returning id
)
insert into fixture (name, id) select 'rev', id from inserted;

-- Registrerer en bekreftet claim-verifikasjon for revisjonen, med avtrykket av
-- evidenssettet slik det er akkurat nå (migrasjon 005j).
--
-- Brukes hver gang fixturen utvider eller bytter ut grunnlaget. G9b krever at
-- den gjeldende kontrollen gjelder det settet som ville blitt publisert, så uten
-- en ny kontroll ville G9b felt en test som er skrevet for å felle på G13 — og
-- da ville G13 stått uprøvd bak den. Rekkefølgen «G9b først, så G13» er derfor
-- prøvd eksplisitt hvert sted, framfor å bli antatt.
--
-- p_at er alltid oppgitt: «den gjeldende kontrollen» er den siste sortert på
-- verified_at, og inne i én transaksjon gir now() samme tidspunkt hver gang.
create function pg_temp.verify_claim(p_revision uuid, p_at timestamptz)
returns void language sql as $$
  insert into workflow.claim_verifications
    (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
     source_access, source_support, population_match, comparator_match, timeframe_match,
     direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
     rationale, verified_at)
  select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
         'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
         'Fornyet kontroll mot det utvidede grunnlaget.', p_at
  from knowledge.claim_revisions r, fixture v
  where r.id = p_revision and v.name = 'verifier';
$$;

-- ---------------------------------------------------------------------------
-- Gatene, én om gangen
-- ---------------------------------------------------------------------------

-- §38: «claim-revisjonen finnes»
select throws_like(
  $$select knowledge.assert_claim_revision_publishable('00000000-0000-0000-0000-0000000000ff')$$,
  '%finnes ikke%',
  'gaten avviser en revisjon som ikke finnes'
);

-- §38: «nødvendige EvidenceItems finnes» — og MVP_IMPLEMENTATION_PLAN.md §42
-- sitt «publisering uten evidens når evidens kreves».
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%ingen registrerte evidenslenker%',
  'gaten avviser publisering uten evidens (ANTIDEP_CONSTITUTION.md §4)'
);

-- Evidenslenkene dateres bakover, slik at godkjenningen senere kan ligge etter
-- dem. Uten dette ville alt i transaksjonen hatt samme tidspunkt.
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_set_created_at;
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id, created_at)
select r.id, e.id, 'supports', 'direct',
       'Funnet rapporterer utfallet påstanden gjelder.',
       (select id from fixture where name = 'synthesis_actor'), now() - interval '30 days'
from fixture r, fixture e
where r.name = 'rev' and e.name = 'evidence_a';
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_set_created_at;

-- §38: «relevante EvidenceItems er verifisert»
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%uten registrert ekstraksjonsverifikasjon%',
  'gaten avviser publisering når ekstraksjonen ikke er kontrollert (ANTIDEP_CONSTITUTION.md §11)'
);

-- G5b: en delkontroll er ikke en kontrollert ekstraksjon.
--
-- Feltene under er nøyaktig de den deterministiske ekstraksjonsverifikatoren
-- kan bedømme når ingen tall er oppgitt. Den ser verken tidspunkt, retning,
-- effektmål, availability-semantikk eller forbehold, og `checked_fields` sier
-- det — men før G5b leste gaten bare `outcome`, og en slik rad passerte som om
-- hele ekstraksjonen var kontrollert.
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'verified', 'original_source',
       array['raw_extraction', 'source_locator', 'intervention_arm', 'outcome']
         ::workflow.evidence_check_field[],
       'Deterministisk kontroll av sitat, kildepeker og begreper.',
       now() - interval '26 days'
from knowledge.evidence_items e, fixture v
where e.id = (select id from fixture where name = 'evidence_a') and v.name = 'verifier';

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%uten fullstendig kontrollert ekstraksjon%',
  'en delkontroll med outcome verified tilfredsstiller ikke publiseringsgaten'
);

-- Tidspunktet er en av feltene den deterministiske kontrollen aldri ser, og
-- raden oppgir det. Kravet må nevne det.
select ok(
  'timepoint' = any (workflow.required_check_fields(
    (select id from fixture where name = 'evidence_a'))),
  'et rapportert tidspunkt kreves kontrollert før publisering'
);

-- At feltene er ført som rapportert eller ikke rapportert, er selv en påstand
-- om kilden, og kreves alltid kontrollert.
select ok(
  'availability_semantics' = any (workflow.required_check_fields(
    (select id from fixture where name = 'evidence_a'))),
  'availability-semantikken kreves kontrollert uansett hvordan raden er fylt ut'
);

-- Kravet gjelder unionen: to verifikatorledd kan dele arbeidet, og det andre
-- leddet dekker resten.
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'verified', 'original_source',
       -- Full dekning, utledet av raden selv: publiseringsgatens G5b krever at
       -- kontrollene til sammen dekker det funnet påstår noe om.
       workflow.required_check_fields(e.id),
       'Kontrollert mot originalkilden.', now() - interval '25 days'
from knowledge.evidence_items e, fixture v
where e.id = (select id from fixture where name = 'evidence_a') and v.name = 'verifier';

-- §38: «ClaimEvidenceLinks er kontrollert» — claim-verifikasjonen i §30
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%ingen registrert claim-verifikasjon%',
  'gaten avviser publisering når påstanden ikke er kontrollert mot grunnlaget'
);

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Forsøkt falsifisert mot kilden.', now() - interval '20 days'
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'rev') and v.name = 'verifier';

-- §38: «EvidenceAssessment finnes»
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%mangler evidensvurdering%',
  'gaten avviser en evidenssyntese uten eksplisitt sikkerhetsvurdering (ANTIDEP_CONSTITUTION.md §6)'
);

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select r.id, r.knowledge_type, 'grade', 'low',
       'serious', 'not_assessable', 'serious', 'serious', 'not_assessable',
       'Ett funn fra én studie; domenene vurdert enkeltvis.',
       now() - interval '15 days', r.created_by_actor_id
from knowledge.claim_revisions r
where r.id = (select id from fixture where name = 'rev');

-- §38: «nødvendig menneskelig review er godkjent» — og MVP_IMPLEMENTATION_PLAN.md
-- §42 sitt «publisering uten human review når dette kreves».
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%ikke godkjent av en kvalifisert redaktør%',
  'gaten avviser publisering uten menneskelig faglig godkjenning (ANTIDEP_CONSTITUTION.md §12)'
);

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Gjennomgått mot kilden; formuleringen holder.',
       rg.id, 'human', now() - interval '10 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'rev') and rg.name = 'reviewer_global';

-- Den positive kontrollen: gaten slipper gjennom når alt faktisk er på plass.
-- Uten denne ville hver enkelt negative assertion over kunne passert fordi gaten
-- avviser alt.
select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  'gaten slipper gjennom en revisjon som oppfyller alle kravene'
);

-- ---------------------------------------------------------------------------
-- Blokkerende funn: hvert av dem stopper en revisjon som ellers passerer, og
-- oppheves av at en nyere kontroll eller beslutning gjelder foran den.
-- ---------------------------------------------------------------------------

-- §38: «ingen blokkerende verifikasjonsfunn er åpne»
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, findings, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'needs_correction', 'original_source',
       array['estimate']::workflow.evidence_check_field[],
       'Estimatet er gjengitt med feil fortegn.',
       'Ny gjennomgang av tallene.', now() - interval '9 days'
from knowledge.evidence_items e, fixture v
where e.id = (select id from fixture where name = 'evidence_a') and v.name = 'verifier';

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%åpent verifikasjonsfunn%',
  'et senere verifikasjonsavvik blokkerer, selv om en tidligere bekreftelse finnes'
);

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'verified', 'original_source',
       -- Full dekning, utledet av raden selv: publiseringsgatens G5b krever at
       -- kontrollene til sammen dekker det funnet påstår noe om.
       workflow.required_check_fields(e.id),
       'Fortegnet var riktig ved fornyet kontroll mot kilden.', now() - interval '8 days'
from knowledge.evidence_items e, fixture v
where e.id = (select id from fixture where name = 'evidence_a') and v.name = 'verifier';

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  'en nyere bekreftelse opphever det tidligere avviket'
);

-- G5b har samme gjeldende-semantikk som G5 for *avvik*.
--
-- Uten den kunne et avvik forsvinne uten å bli avklart: en delkontroll som
-- aldri så på det omstridte feltet, ville sluppet gjennom G5 (siste utfall er
-- verified) og gjennom G5b (dekningen for feltet hentes fra en *eldre*
-- bekreftelse, den avviket nettopp underkjente).
--
-- Fra migrasjon 005y er det bare et avvik som nullstiller. En uavklart kontroll
-- motsier ingenting, og feltene den førte opp, gikk den faktisk gjennom — det
-- er nettopp arbeidsdelingen mellom maskinen, som beviser provenansfeltene, og
-- mennesket, som bedømmer de semantiske. At noen konkluderte, er fortsatt G5
-- sin oppgave.
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, findings, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'needs_correction', 'original_source',
       array['source_locator']::workflow.evidence_check_field[],
       'Tidspunktet i kilden er et annet enn det raden oppgir.',
       'Fornyet gjennomgang av sammendraget.', now() - interval '7 days 3 hours'
from knowledge.evidence_items e, fixture v
where e.id = (select id from fixture where name = 'evidence_a') and v.name = 'verifier';

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%åpent verifikasjonsfunn%',
  'en uavklart kontroll blokkerer, som et hvilket som helst annet åpent funn'
);

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'verified', 'original_source',
       array['raw_extraction', 'source_locator', 'intervention_arm', 'outcome']
         ::workflow.evidence_check_field[],
       'Deterministisk kontroll av sitat, kildepeker og begreper.',
       now() - interval '7 days 2 hours'
from knowledge.evidence_items e, fixture v
where e.id = (select id from fixture where name = 'evidence_a') and v.name = 'verifier';

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%uten fullstendig kontrollert ekstraksjon%',
  'en delkontroll etter et åpent funn henter ikke dekning fra bekreftelser foran funnet'
);

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'verified', 'original_source',
       workflow.required_check_fields(e.id),
       'Tidspunktet er lest på nytt mot tabellen, og hele ekstraksjonen er kontrollert.',
       now() - interval '7 days 1 hour'
from knowledge.evidence_items e, fixture v
where e.id = (select id from fixture where name = 'evidence_a') and v.name = 'verifier';

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  'en kontroll som faktisk re-kontrollerer det omstridte feltet, åpner gaten igjen'
);

-- Overleveringen fra migrasjon 005: tilbaketrukket ekstraksjon er en avledet
-- tilstand, ikke en statuskolonne, og gaten må lese den.
insert into workflow.review_decisions
  (evidence_item_id, evidence_item_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select e.id, e.created_by_actor_id, 'extraction_withdrawal', 'extraction_withdrawn',
       'Ekstraksjonen bygger på en tabell som ikke gjelder dette utfallet.',
       rg.id, 'human', now() - interval '7 days'
from knowledge.evidence_items e, fixture rg
where e.id = (select id from fixture where name = 'evidence_a') and rg.name = 'reviewer_global';

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%tilbaketrukket ekstraksjon%',
  'en revisjon som hviler på et tilbaketrukket evidensfunn kan ikke publiseres'
);

insert into workflow.review_decisions
  (evidence_item_id, evidence_item_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select e.id, e.created_by_actor_id, 'extraction_withdrawal', 'extraction_upheld',
       'Tabellhenvisningen var korrekt; tilbaketrekkingen var feil.',
       rg.id, 'human', now() - interval '6 days'
from knowledge.evidence_items e, fixture rg
where e.id = (select id from fixture where name = 'evidence_a') and rg.name = 'reviewer_global';

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  'en senere beslutning som opprettholder ekstraksjonen opphever tilbaketrekkingen'
);

-- DATABASE_ARCHITECTURE.md §58: en tilbaketrukket kilde skal ikke ubemerket
-- tilfredsstille en gate som om statusen var normal.
update knowledge.sources
set source_status = 'retracted',
    status_note = 'Trukket tilbake av tidsskriftet i testscenarioet.'
where id = (select e.source_id from knowledge.evidence_items e
            where e.id = (select id from fixture where name = 'evidence_a'));

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%retracted eller withdrawn%',
  'en tilbaketrukket kilde kan ikke bære en publisert påstand (DATABASE_ARCHITECTURE.md §58)'
);

update knowledge.sources
set source_status = 'active', status_note = null
where id = (select e.source_id from knowledge.evidence_items e
            where e.id = (select id from fixture where name = 'evidence_a'));

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  'gaten slipper gjennom igjen når kilden har normal status'
);

-- En senere claim-verifikasjon som ikke konkluderer, blokkerer.
insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   findings, rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'uncertain', 'original_source',
       'ok', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Populasjonen i kilden lar seg ikke avgjøre.',
       'Fornyet kontroll.', now() - interval '5 days'
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'rev') and v.name = 'verifier';

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%konkluderer ikke med verified%',
  'en uavklart claim-verifikasjon blokkerer, og teller ikke som bestått'
);

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Populasjonen bekreftet ved fornyet lesing av kilden.', now() - interval '4 days'
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'rev') and v.name = 'verifier';

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  'en nyere bekreftet claim-verifikasjon opphever den uavklarte'
);

-- En senere reviewbeslutning gjelder foran den tidligere godkjenningen.
insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'changes_requested',
       'Forbeholdet om at grunnlaget er armspesifikt må stå i selve formuleringen.',
       rg.id, 'human', now() - interval '3 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'rev') and rg.name = 'reviewer_global';

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%er changes_requested, ikke approved%',
  'en senere omgjøring gjelder foran den tidligere godkjenningen'
);

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Forbeholdet står nå i formuleringen; godkjennes.',
       rg.id, 'human', now() - interval '2 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'rev') and rg.name = 'reviewer_global';

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  'en fornyet godkjenning gjør revisjonen publiserbar igjen'
);

-- ---------------------------------------------------------------------------
-- Et deterministisk faktum, og «review av en revisjon som senere er endret»
--
-- Testen bruker et deterministisk faktum med hensikt. Det får ingen
-- evidensvurdering, så forseglingen fra migrasjon 004 kan ikke fyre, og det er
-- derfor den eneste kunnskapstypen der en lenke faktisk kan legges til etter at
-- revisjonen er godkjent. Nettopp derfor er det også den typen
-- MVP_IMPLEMENTATION_PLAN.md §42 sitt tredje krav må håndheves for.
-- ---------------------------------------------------------------------------
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'deterministic_fact', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'drug' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'fact_claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Deterministisk testfaktum for publiseringsgaten.',
         'Gjelder bare testene i denne filen.', 'none', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'fact_claim')
  returning id
)
insert into fixture (name, id) select 'fact_rev', id from inserted;

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'verified', 'original_source',
       -- Full dekning, utledet av raden selv: publiseringsgatens G5b krever at
       -- kontrollene til sammen dekker det funnet påstår noe om.
       workflow.required_check_fields(e.id),
       'Kontrollert mot originalkilden.', now() - interval '25 days'
from knowledge.evidence_items e, fixture v
where e.id = (select id from fixture where name = 'evidence_b') and v.name = 'verifier';

alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_set_created_at;
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id, created_at)
select r.id, e.id, 'supports', 'direct',
       'Kilden dokumenterer faktumet.',
       (select id from fixture where name = 'synthesis_actor'), now() - interval '30 days'
from fixture r, fixture e
where r.name = 'fact_rev' and e.name = 'evidence_b';
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_set_created_at;

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Faktumet kontrollert mot kilden.', now() - interval '20 days'
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'fact_rev') and v.name = 'verifier';

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Faktumet stemmer med kilden.', rg.id, 'human', now() - interval '10 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'fact_rev') and rg.name = 'reviewer_global';

-- Et deterministisk faktum har ingen evidensvurdering, og skal likevel kunne
-- publiseres. Uten denne assertionen kunne kravet om evidensvurdering ha vært
-- skrevet for bredt uten at noen test sa fra.
select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'fact_rev'))$$,
  'et deterministisk faktum publiseres uten evidensvurdering, som migrasjon 004 heller ikke tillater for typen'
);

-- Evidensgrunnlaget utvides etter godkjenningen. Lenken får databaseeid
-- registreringstid, altså nå, mens godkjenningen er ti dager gammel.
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select r.id, e.id, 'supports', 'direct',
       'Ytterligere grunnlag lagt til i ettertid.',
       (select id from fixture where name = 'synthesis_actor')
from fixture r, fixture e
where r.name = 'fact_rev' and e.name = 'evidence_a';

-- G9b slår ut først: kontrollen gjaldt et smalere sett enn det som nå ville
-- blitt publisert, og en bekreftelse av et smalere grunnlag er ikke en
-- bekreftelse av det utvidede (migrasjon 005j).
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'fact_rev'))$$,
  '%endret etter den gjeldende claim-verifikasjonen%',
  'en utvidelse av evidenssettet gjør den gjeldende claim-verifikasjonen utdatert'
);

select pg_temp.verify_claim(
  (select id from fixture where name = 'fact_rev'), now() - interval '9 days');

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'fact_rev'))$$,
  '%er endret etter godkjenningen%',
  'en revisjon som har fått nytt evidensgrunnlag etter godkjenningen kan ikke publiseres uten nytt review (MVP_IMPLEMENTATION_PLAN.md §42)'
);

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Det utvidede grunnlaget er gjennomgått og godkjent.',
       rg.id, 'human', now()
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'fact_rev') and rg.name = 'reviewer_global';

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'fact_rev'))$$,
  'en ny godkjenning som dekker det utvidede grunnlaget gjør revisjonen publiserbar igjen'
);

-- ---------------------------------------------------------------------------
-- Regresjonstest: samtidighet kan ikke skjule en endring i evidensgrunnlaget
--
-- Rapportert på PR #15. Den opprinnelige G13 sammenlignet lenkens created_at med
-- godkjenningens decided_at. Den regelen er ikke samtidighetssikker: now() er
-- transaksjonens starttidspunkt, ikke committidspunktet, så en transaksjon som
-- registrerer en lenke kan starte før godkjenningen, commite etter den, og
-- likevel bære en created_at som ligger foran decided_at. Reviewer kunne umulig
-- ha sett lenken, men tidsregelen ville sagt at godkjenningen dekker den.
--
-- Testen gjenskaper nøyaktig den tilstanden kappløpet etterlater — en lenke som
-- kom til etter godkjenningen, men som bærer en tidligere created_at — og
-- kontrollerer at gaten nekter likevel. Assertionen under viser først at den
-- gamle regelen ikke ville funnet noe å reagere på, slik at testen ikke kan
-- passere av feil grunn.
--
-- Tilstanden konstrueres uten to sesjoner, fordi den nye regelen ikke avhenger av
-- rekkefølge: avtrykket av evidenssettet avviker uansett hvordan radene ble til.
-- Det er nettopp derfor rettelsen er en avtrykkssammenligning og ikke en
-- strammere tidsregel.
-- ---------------------------------------------------------------------------
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'deterministic_fact', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'drug' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'race_claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Deterministisk testfaktum for samtidighetsregresjonen.',
         'Gjelder bare testene i denne filen.', 'none', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'race_claim')
  returning id
)
insert into fixture (name, id) select 'race_rev', id from inserted;

-- Lenke A: den reviewer faktisk så.
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_set_created_at;
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id, created_at)
select r.id, e.id, 'supports', 'direct', 'Grunnlaget reviewer så.',
       (select id from fixture where name = 'synthesis_actor'), now() - interval '30 days'
from fixture r, fixture e
where r.name = 'race_rev' and e.name = 'evidence_b';
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_set_created_at;

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Faktumet kontrollert mot kilden.', now() - interval '20 days'
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'race_rev') and v.name = 'verifier';

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Godkjent på grunnlag av lenke A.', rg.id, 'human', now() - interval '10 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'race_rev') and rg.name = 'reviewer_global';

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'race_rev'))$$,
  'revisjonen er publiserbar på det grunnlaget godkjenningen faktisk gjaldt'
);

-- Lenke B: kom til etter godkjenningen, men bærer et tidligere tidspunkt —
-- nøyaktig avtrykket av en transaksjon som startet før og commitet etter.
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_set_created_at;
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id, created_at)
select r.id, e.id, 'supports', 'direct', 'Grunnlag fra kappløpet.',
       (select id from fixture where name = 'synthesis_actor'), now() - interval '20 days'
from fixture r, fixture e
where r.name = 'race_rev' and e.name = 'evidence_a';
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_set_created_at;

-- Kontroll av at testen tester det den påstår: den gamle tidsregelen ville ikke
-- funnet en eneste lenke å reagere på i denne tilstanden.
select is(
  (select count(*)
   from knowledge.claim_evidence_links l
   join workflow.review_decisions rd on rd.claim_revision_id = l.claim_revision_id
   where l.claim_revision_id = (select id from fixture where name = 'race_rev')
     and rd.review_type = 'publication_approval'
     and l.created_at > rd.decided_at),
  0::bigint,
  'den opprinnelige tidsregelen ville ikke funnet noen lenke registrert etter godkjenningen'
);

-- Samme rekkefølge som over: kontrollen er utdatert før godkjenningen er det.
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'race_rev'))$$,
  '%endret etter den gjeldende claim-verifikasjonen%',
  'også her fanger avtrykket at kontrollen gjaldt et annet sett, uansett tidsstempler'
);

select pg_temp.verify_claim(
  (select id from fixture where name = 'race_rev'), now() - interval '9 days');

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'race_rev'))$$,
  '%er endret etter godkjenningen%',
  'gaten nekter likevel, fordi den sammenligner avtrykket av evidenssettet og ikke tidspunkter'
);

-- ... og en ny godkjenning som dekker det utvidede settet åpner den igjen.
insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Det utvidede grunnlaget er gjennomgått og godkjent.',
       rg.id, 'human', now()
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'race_rev') and rg.name = 'reviewer_global';

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'race_rev'))$$,
  'en ny godkjenning som dekker det utvidede grunnlaget gjør revisjonen publiserbar igjen'
);

-- Avtrykket dekker lenkenes identitet, ikke bare antallet. Regelen betyr noe
-- nettopp i den unntaksvise vedlikeholdsveien DATABASE_ARCHITECTURE.md §36 åpner
-- for: en feilopprettet rad kan slettes fysisk, og da ville en ren telling holdt
-- seg uendret mens settet ble et annet. Testen sletter én lenke og registrerer en
-- ny mot det samme evidensfunnet, slik at antallet er identisk og id-settet ikke
-- er det. Append-only-vernet slås av i det smalest mulige vinduet, slik en reell
-- vedlikeholdsoperasjon ville gjort det.
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_reject_mutation;
delete from knowledge.claim_evidence_links
where claim_revision_id = (select id from fixture where name = 'race_rev')
  and relevance_note = 'Grunnlag fra kappløpet.';
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_mutation;

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select r.id, e.id, 'supports', 'direct', 'Erstatningslenke med ny identitet.',
       (select id from fixture where name = 'synthesis_actor')
from fixture r, fixture e
where r.name = 'race_rev' and e.name = 'evidence_a';

select is(
  (select count(*) from knowledge.claim_evidence_links l
   where l.claim_revision_id = (select id from fixture where name = 'race_rev')),
  2::bigint,
  'antallet evidenslenker er uendret etter utskiftingen'
);
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'race_rev'))$$,
  '%endret etter den gjeldende claim-verifikasjonen%',
  'avtrykket fanger et utskiftet evidenssett selv når antallet er det samme, også for claim-verifikasjonen'
);

select pg_temp.verify_claim(
  (select id from fixture where name = 'race_rev'), now() - interval '8 days');

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'race_rev'))$$,
  '%er endret etter godkjenningen%',
  'avtrykket fanger et utskiftet evidenssett selv når antallet er det samme'
);

-- ---------------------------------------------------------------------------
-- Klinisk anbefaling: terskelen er nøyaktig like streng
--
-- DATABASE_ARCHITECTURE.md §38 krever «minst like streng», og den er like streng:
-- en klinisk anbefaling må oppfylle alle de samme punktene som en evidenssyntese.
-- KNOWLEDGE_MODEL.md §21 sitt «ja, eksplisitt» forstås som at en navngitt
-- kvalifisert redaktør uttrykkelig godkjenner den konkrete revisjonen — noe
-- modellen allerede krever — og ikke som et krav om en egen temaavgrenset
-- reviewer-tildeling.
--
-- Scoped reviewer-roller respekteres fortsatt, men det håndheves der det hører
-- hjemme: workflow.enforce_reviewer_qualification() avviser en scoped reviewer
-- som godkjenner utenfor sitt tema. Det er testet i
-- 190_workflow_constraints_test.sql, ikke her.
-- ---------------------------------------------------------------------------
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'clinical_recommendation', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'drug' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'rec_claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Klinisk testanbefaling for publiseringsgaten.',
         'Gjelder bare testene i denne filen.', 'none',
         'Testusikkerhet.', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'rec_claim')
  returning id
)
insert into fixture (name, id) select 'rec_rev', id from inserted;

alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_set_created_at;
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id, created_at)
select r.id, e.id, 'supports', 'direct',
       'Grunnlaget anbefalingen hviler på.',
       (select id from fixture where name = 'synthesis_actor'), now() - interval '30 days'
from fixture r, fixture e
where r.name = 'rec_rev' and e.name = 'evidence_b';
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_set_created_at;

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Anbefalingen kontrollert mot grunnlaget.', now() - interval '20 days'
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'rec_rev') and v.name = 'verifier';

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select r.id, r.knowledge_type, 'grade', 'low',
       'serious', 'not_assessable', 'serious', 'serious', 'not_assessable',
       'Grunnlaget for anbefalingen er tynt.', now() - interval '15 days', r.created_by_actor_id
from knowledge.claim_revisions r
where r.id = (select id from fixture where name = 'rec_rev');

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Godkjent av redaktør med generell reviewer-rolle.',
       rg.id, 'human', now() - interval '10 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'rec_rev') and rg.name = 'reviewer_global';

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rec_rev'))$$,
  'en klinisk anbefaling godkjent av en redaktør med generell reviewer-rolle passerer gaten'
);

-- En andre anbefaling som mangler nøyaktig én ting: evidensvurderingen.
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'clinical_recommendation', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'drug' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'rec_claim_uten_vurdering', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Klinisk testanbefaling uten evidensvurdering.',
         'Gjelder bare testene i denne filen.', 'none',
         'Testusikkerhet.', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'rec_claim_uten_vurdering')
  returning id
)
insert into fixture (name, id) select 'rec_rev_uten_vurdering', id from inserted;

alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_set_created_at;
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id, created_at)
select r.id, e.id, 'supports', 'direct', 'Grunnlaget anbefalingen hviler på.',
       (select id from fixture where name = 'synthesis_actor'), now() - interval '30 days'
from fixture r, fixture e
where r.name = 'rec_rev_uten_vurdering' and e.name = 'evidence_b';
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_set_created_at;

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Anbefalingen kontrollert mot grunnlaget.', now() - interval '20 days'
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'rec_rev_uten_vurdering') and v.name = 'verifier';

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Godkjent av redaktør med generell reviewer-rolle.',
       rg.id, 'human', now() - interval '10 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'rec_rev_uten_vurdering')
  and rg.name = 'reviewer_global';

-- ... og en anbefaling er ikke unntatt noen av de øvrige kravene. Uten denne
-- assertionen kunne «like streng» vært en påstand uten dekning: en gate som
-- slapp gjennom anbefalinger uten evidensvurdering ville passert testen over.
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rec_rev_uten_vurdering'))$$,
  '%mangler evidensvurdering%',
  'en klinisk anbefaling må oppfylle de samme kravene som en evidenssyntese'
);

-- En tilbaketrukket påstand kan ikke publiseres. Testes til slutt, fordi den
-- setter målrevisjonen ut av spill for de øvrige assertionene.
update knowledge.claims
set retired_at = now(), retirement_note = 'Trukket tilbake i testscenarioet.'
where id = (select id from fixture where name = 'claim');

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      (select id from fixture where name = 'rev'))$$,
  '%er trukket tilbake og kan ikke publiseres%',
  'en revisjon av en tilbaketrukket påstand kan ikke publiseres'
);

select * from finish();

rollback;
