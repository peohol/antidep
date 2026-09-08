-- Migrasjon 007a — publiserings- og reviewtidspunkt i api.published_claims.
--
-- Gjeldsposten i MVP_IMPLEMENTATION_PLAN.md §74.7 var at en kliniker så «sist
-- faglig vurdert» bare for de kunnskapstypene som har en evidensvurdering: et
-- deterministisk faktum fikk ingen dato i det hele tatt. Den sentrale testen i
-- denne filen er derfor del 4, der nettopp et deterministic_fact får en
-- godkjenningsdato uten å ha noen evidensvurdering.
--
-- Governance-beslutningen migrasjonen hviler på er «kun tidsstempler»
-- (PRODUCT_INFORMATION_ARCHITECTURE.md §58). Del 6 kontrollerer den andre
-- halvdelen av den beslutningen: at reviewers identitet, begrunnelsen og
-- publiseringshistorikken forøvrig fortsatt er utenfor klientflaten.
--
-- Godkjenningen utføres inne i transaksjonen, av aktører som opprettes her, og
-- rulles tilbake med den. Ingen fiktiv godkjenning blir stående
-- (ANTIDEP_CONSTITUTION.md §12).
begin;

create extension if not exists pgtap with schema extensions;

select plan(38);

create temporary table fixture (name text primary key, id uuid) on commit drop;

-- Deler av assertionene kjøres som anon og sammenligner mot en id fra
-- fikstureren. Temptabellen er lokal til transaksjonen og rulles tilbake.
grant select on fixture to anon, authenticated;

-- Tidspunkter som skal sammenlignes inne i en anon-blokk. anon har verken usage
-- på workflow eller knowledge, så verdiene må hentes ut som eier først;
-- sammenligningen ville ellers feilet på schematilgang framfor på verdien.
create temporary table expected_ts (name text primary key, at timestamptz) on commit drop;
grant select on expected_ts to anon, authenticated;

-- ===========================================================================
-- Del 1 — Struktur: kolonnen, regelen og triggeren som eier verdien
-- ===========================================================================

select has_column('knowledge', 'publication_events', 'approval_decided_at',
  'publiseringshendelsen bærer godkjenningstidspunktet');
select col_type_is('knowledge', 'publication_events', 'approval_decided_at',
  'timestamp with time zone',
  'godkjenningstidspunktet er timestamptz, som alle tidspunkter (DATABASE_ARCHITECTURE.md §7.3)');
select col_is_null('knowledge', 'publication_events', 'approval_decided_at',
  'kolonnen er nullbar: en avpublisering har ingen godkjenning å vise til');

select has_trigger('knowledge', 'publication_events',
  'publication_events_set_approval_decided_at',
  'triggeren som fryser godkjenningstidspunktet finnes');

-- Verdien skal eies av databasen. Var funksjonen SECURITY INVOKER, ville den
-- ikke kunnet lese reviewbeslutningene bak RLS, og datoen ville blitt NULL for
-- alle andre enn eieren.
select is(
  (select p.prosecdef from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'knowledge' and p.proname = 'set_publication_approval_decided_at'),
  true,
  'triggerfunksjonen er SECURITY DEFINER, slik at datoen kan leses bak RLS');

-- Samme idiom som 230: PostgreSQL skriver tomt search_path som search_path=""
-- eller search_path= avhengig av versjon, og begge er tomme.
select ok(
  exists (
    select 1
    from pg_proc p, unnest(coalesce(p.proconfig, array[]::text[])) as cfg
    where p.oid = 'knowledge.set_publication_approval_decided_at()'::regprocedure
      and cfg in ('search_path=""', 'search_path=')
  ),
  'triggerfunksjonen har tomt search_path (DATABASE_ARCHITECTURE.md §50)');

select ok(
  not has_function_privilege('public', 'knowledge.set_publication_approval_decided_at()', 'execute'),
  'triggerfunksjonen er ikke kjørbar for PUBLIC');

-- ===========================================================================
-- Del 2 — Aktører, roller og en fullt publiserbar påstand
-- ===========================================================================

insert into auth.users (id, email) values
  ('33330000-0000-0000-0000-000000000001', 'reviewer-330@test.invalid'),
  ('33330000-0000-0000-0000-000000000002', 'publisher-330@test.invalid'),
  ('33330000-0000-0000-0000-000000000003', 'verifier-330@test.invalid');

insert into provenance.actors (actor_type, actor_key, display_name, description, auth_user_id)
values
  ('human', 'human:reviewer-330', 'Reviewer', 'Kvalifisert redaktør for testene i 330.',
   '33330000-0000-0000-0000-000000000001'),
  ('human', 'human:publisher-330', 'Publisher', 'Utfører publiseringen i testene i 330.',
   '33330000-0000-0000-0000-000000000002'),
  ('human', 'human:verifier-330', 'Verifikator', 'Utfører verifikasjonene i testene i 330.',
   '33330000-0000-0000-0000-000000000003');

insert into fixture (name, id)
select 'reviewer', id from provenance.actors where actor_key = 'human:reviewer-330';
insert into fixture (name, id)
select 'publisher', id from provenance.actors where actor_key = 'human:publisher-330';
insert into fixture (name, id)
select 'verifier', id from provenance.actors where actor_key = 'human:verifier-330';
insert into fixture (name, id)
select 'synthesis_actor', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id)
select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id)
select 'evidence_sertralin', e.id from knowledge.evidence_items e
join knowledge.sources s on s.id = e.source_id
where s.title like 'Fluoxetine versus sertraline%';

-- Rolletildelingene må ha eksistert før beslutningene som viser til dem
-- (workflow.enforce_reviewer_qualification()).
alter table workflow.user_roles disable trigger user_roles_set_row_timestamps;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason, created_at)
values
  ('33330000-0000-0000-0000-000000000001', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'verifier'), 'Reviewrett for testene i 330.',
   now() - interval '1 year'),
  ('33330000-0000-0000-0000-000000000002', 'publisher', null, now() - interval '1 year',
   (select id from fixture where name = 'verifier'), 'Publiseringsrett for testene i 330.',
   now() - interval '1 year'),
  -- Verifikatoren trenger selv reviewer-rollen fra og med migrasjon 005j: en
  -- claim-verifikasjon krever mandat, og for et menneske er mandatet
  -- reviewer-rollen for innholdsområdet (MVP_IMPLEMENTATION_PLAN.md §74.30 punkt 3).
  ('33330000-0000-0000-0000-000000000003', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'reviewer'), 'Reviewrett for verifikatoren i 330.',
   now() - interval '1 year');
alter table workflow.user_roles enable trigger user_roles_set_row_timestamps;

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'verified', 'original_source',
       -- Full dekning, utledet av raden selv: publiseringsgatens G5b krever at
       -- kontrollene til sammen dekker det funnet påstår noe om.
       workflow.required_check_fields(e.id),
       'Kontrollert mot originalkilden.', now() - interval '9 days'
from knowledge.evidence_items e, fixture v
where v.name = 'verifier'
  and e.id = (select id from fixture where name = 'evidence_sertralin');

-- Evidenssyntesen. Godkjenningen dateres bevisst to døgn tilbake, slik at
-- «sist faglig vurdert» og «publisert» ikke kan forveksles: publiseringen skjer
-- nå, godkjenningen skjedde før.
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'sertralin' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Testpåstand som publiseres i 330.',
         'Gjelder bare testene i denne filen.', 'none',
         'Testusikkerhet.', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'claim')
  returning id
)
insert into fixture (name, id) select 'rev1', id from inserted;

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select (select id from fixture where name = 'rev1'),
       (select id from fixture where name = 'evidence_sertralin'),
       'supports', 'direct', 'Funnet støtter formuleringen.',
       (select id from fixture where name = 'synthesis_actor');

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'Forsøkt falsifisert.',
       now() - interval '8 days'
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'rev1') and v.name = 'verifier';

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select r.id, r.knowledge_type, 'grade', 'low',
       'serious', 'not_assessable', 'serious', 'serious', 'not_assessable',
       'Domenene vurdert enkeltvis.', now() - interval '3 days', r.created_by_actor_id
from knowledge.claim_revisions r
where r.id = (select id from fixture where name = 'rev1');

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Gjennomgått mot kilden.', rg.id, 'human', now() - interval '2 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'rev1') and rg.name = 'reviewer';

select set_config('request.jwt.claims',
                  '{"sub":"33330000-0000-0000-0000-000000000002"}', true);
select lives_ok(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Publisert for testene i 330.')$$,
  'evidenssyntesen lar seg publisere');
select set_config('request.jwt.claims', '', true);

-- ===========================================================================
-- Del 3 — Triggeren fryser godkjenningen på hendelsen
-- ===========================================================================

select is(
  (select pe.approval_decided_at
   from knowledge.publication_events pe
   where pe.revision_id = (select id from fixture where name = 'rev1')),
  (select rd.decided_at
   from workflow.review_decisions rd
   where rd.claim_revision_id = (select id from fixture where name = 'rev1')
     and rd.review_type = 'publication_approval'),
  'hendelsen bærer nøyaktig godkjenningens decided_at, ikke publiseringstidspunktet');

select isnt(
  (select pe.approval_decided_at from knowledge.publication_events pe
   where pe.revision_id = (select id from fixture where name = 'rev1')),
  (select pe.published_at from knowledge.publication_events pe
   where pe.revision_id = (select id from fixture where name = 'rev1')),
  'godkjenning og publisering er to ulike tidspunkter, og forveksles ikke');

-- Kolonnekommentaren lover at verdien er frosset. Løftet hviler på at
-- hendelsestabellen er append-only (migrasjon 006), og den triggeren ble skrevet
-- før denne kolonnen fantes. Kontrollert framfor antatt.
select throws_like(
  $$
    update knowledge.publication_events
    set approval_decided_at = now()
    where revision_id = (select id from fixture where name = 'rev1')
  $$,
  '%append-only%',
  'godkjenningsdatoen kan ikke endres i ettertid: hendelsen er append-only');

-- ===========================================================================
-- Del 4 — Gjeldsposten: et deterministisk faktum får en dato
--
-- Typen har ingen evidensvurdering (migrasjon 004 tillater den ikke), så
-- last_assessed_at er NULL. Nettopp derfor sto den uten «sist faglig vurdert»
-- før 007a.
-- ===========================================================================

with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'deterministic_fact', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'sertralin' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'fact_claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Deterministisk testfaktum i 330.',
         'Gjelder bare testene i denne filen.', 'none', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'fact_claim')
  returning id
)
insert into fixture (name, id) select 'fact_rev', id from inserted;

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select (select id from fixture where name = 'fact_rev'),
       (select id from fixture where name = 'evidence_sertralin'),
       'supports', 'direct', 'Funnet dokumenterer faktumet.',
       (select id from fixture where name = 'synthesis_actor');

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'Kontrollert mot kilden.',
       now() - interval '7 days'
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'fact_rev') and v.name = 'verifier';

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Faktumet kontrollert mot autoritativ kilde.', rg.id, 'human',
       now() - interval '6 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'fact_rev') and rg.name = 'reviewer';

select set_config('request.jwt.claims',
                  '{"sub":"33330000-0000-0000-0000-000000000002"}', true);
select lives_ok(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'fact_rev'),
      (select id from fixture where name = 'publisher'),
      'Publisert deterministisk faktum for testene i 330.')$$,
  'det deterministiske faktumet lar seg publisere uten evidensvurdering');
select set_config('request.jwt.claims', '', true);

insert into expected_ts (name, at)
select 'fact_approval', rd.decided_at from workflow.review_decisions rd
where rd.claim_revision_id = (select id from fixture where name = 'fact_rev');
insert into expected_ts (name, at)
select 'synthesis_published', pe.published_at from knowledge.publication_events pe
where pe.revision_id = (select id from fixture where name = 'rev1');

set local role anon;

select is(
  (select last_assessed_at from api.published_claims
   where claim_id = (select id from fixture where name = 'fact_claim')),
  null::timestamptz,
  'det deterministiske faktumet har ingen evidensvurdering, så last_assessed_at er NULL');

select isnt(
  (select last_reviewed_at from api.published_claims
   where claim_id = (select id from fixture where name = 'fact_claim')),
  null::timestamptz,
  'men det har en godkjenningsdato: gjeldsposten i §74.7 er innfridd');

select is(
  (select last_reviewed_at from api.published_claims
   where claim_id = (select id from fixture where name = 'fact_claim')),
  (select at from expected_ts where name = 'fact_approval'),
  'og datoen er godkjenningens, ikke publiseringens');

-- Begge de to publiserte påstandene har begge datoene. Telles framfor å sjekkes
-- med is_empty: en is_empty over dette ville passert også om projeksjonen var tom.
select is(
  (select count(*) from api.published_claims
   where published_at is not null and last_reviewed_at is not null),
  2::bigint,
  'begge de publiserte påstandene har både publiseringsdato og godkjenningsdato');

select is(
  (select published_at from api.published_claims
   where claim_id = (select id from fixture where name = 'claim')),
  (select at from expected_ts where name = 'synthesis_published'),
  'published_at i viewet er hendelsens publiseringstidspunkt');

reset role;

-- ===========================================================================
-- Del 5 — Avpublisering, republisering og verdier kalleren prøver å styre
-- ===========================================================================

-- En avpublisering har ingen etterfølgende revisjon, og dermed ingen godkjenning
-- å vise til.
select set_config('request.jwt.claims',
                  '{"sub":"33330000-0000-0000-0000-000000000002"}', true);
select lives_ok(
  $$select knowledge.withdraw_claim_publication(
      (select id from fixture where name = 'fact_claim'),
      (select id from fixture where name = 'publisher'),
      'Avpublisert for testene i 330.')$$,
  'det deterministiske faktumet lar seg avpublisere');

select is(
  (select pe.approval_decided_at from knowledge.publication_events pe
   where pe.claim_id = (select id from fixture where name = 'fact_claim')
     and pe.action = 'withdraw'),
  null::timestamptz,
  'avpubliseringshendelsen har ingen godkjenningsdato');

-- Republisering av samme revisjon: to publiseringshendelser peker nå på den.
-- Lateralen i viewet skal plukke én av dem, ikke multiplisere raden.
select lives_ok(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'fact_rev'),
      (select id from fixture where name = 'publisher'),
      'Republisert for testene i 330.')$$,
  'det deterministiske faktumet lar seg publisere på nytt');
select set_config('request.jwt.claims', '', true);

select is(
  (select count(*) from knowledge.publication_events pe
   where pe.claim_id = (select id from fixture where name = 'fact_claim')
     and pe.revision_id = (select id from fixture where name = 'fact_rev')),
  2::bigint,
  'to publiseringshendelser peker på den samme revisjonen');

set local role anon;
select is(
  (select count(*) from api.published_claims
   where claim_id = (select id from fixture where name = 'fact_claim')),
  1::bigint,
  'påstanden står likevel som nøyaktig én rad: lateralen multipliserer ikke raden');
reset role;

-- Republisering på en NY godkjenning, i samme transaksjon. Dette er tilfellet
-- den eksterne reviewen på PR #21 fant: begge hendelsene har identisk
-- published_at og created_at, fordi now() er transaksjonens starttidspunkt, men
-- de bærer ULIK approval_decided_at. En «siste hendelse»-rekkefølge som faller
-- tilbake på id — en tilfeldig uuid — plukket den gamle godkjenningen omtrent
-- annenhver gang. Viewet aggregerer derfor med max() framfor å sortere.
insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Ny gjennomgang før republisering.', rg.id, 'human', now() - interval '2 hours'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'fact_rev') and rg.name = 'reviewer';

select set_config('request.jwt.claims',
                  '{"sub":"33330000-0000-0000-0000-000000000002"}', true);
select lives_ok(
  $$select knowledge.withdraw_claim_publication(
      (select id from fixture where name = 'fact_claim'),
      (select id from fixture where name = 'publisher'),
      'Avpublisert før republisering på ny godkjenning.')$$,
  'faktumet lar seg avpublisere igjen');
select lives_ok(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'fact_rev'),
      (select id from fixture where name = 'publisher'),
      'Republisert på den nye godkjenningen.')$$,
  'faktumet lar seg republisere på den nye godkjenningen');
select set_config('request.jwt.claims', '', true);

-- Forutsetningen testen hviler på: hendelsene er faktisk uskillbare på tid.
-- Uten denne ville assertionen under kunnet bestå fordi rekkefølgen tilfeldigvis
-- var entydig, ikke fordi max() gjorde jobben.
select is(
  (select count(distinct (published_at, created_at)) from knowledge.publication_events
   where claim_id = (select id from fixture where name = 'fact_claim')
     and revision_id = (select id from fixture where name = 'fact_rev')),
  1::bigint,
  'de tre hendelsene på revisjonen har identisk published_at og created_at: rekkefølgen er ikke avgjørbar på tid');

select is(
  (select count(distinct approval_decided_at) from knowledge.publication_events
   where claim_id = (select id from fixture where name = 'fact_claim')
     and revision_id = (select id from fixture where name = 'fact_rev')),
  2::bigint,
  'men de bærer to ulike godkjenningsdatoer, så det er mulig å plukke feil');

insert into expected_ts (name, at)
select 'fact_ny_godkjenning', max(rd.decided_at) from workflow.review_decisions rd
where rd.claim_revision_id = (select id from fixture where name = 'fact_rev')
  and rd.review_type = 'publication_approval' and rd.decision = 'approved';

set local role anon;
select is(
  (select last_reviewed_at from api.published_claims
   where claim_id = (select id from fixture where name = 'fact_claim')),
  (select at from expected_ts where name = 'fact_ny_godkjenning'),
  'lesemodellen viser den NYE godkjenningen republiseringen hviler på, ikke den gamle');
select is(
  (select count(*) from api.published_claims
   where claim_id = (select id from fixture where name = 'fact_claim')),
  1::bigint,
  'og påstanden står fortsatt som nøyaktig én rad');
reset role;

-- Verdien eies av databasen. En kaller som oppgir sin egen dato skal bli
-- overskrevet, ellers ville «sist faglig vurdert» vært et tall den som
-- publiserer selv valgte.
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'deterministic_fact', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'sertralin' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'direct_claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Revisjon brukt til å teste triggeren direkte.',
         'Gjelder bare testene i denne filen.', 'none', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'direct_claim')
  returning id
)
insert into fixture (name, id) select 'direct_rev', id from inserted;

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Godkjent, men se den senere beslutningen.', rg.id, 'human',
       now() - interval '5 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'direct_rev') and rg.name = 'reviewer';

select lives_ok(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       published_by_actor_id, published_by_actor_type, reason, published_at,
       approval_decided_at)
    select (select id from fixture where name = 'direct_claim'), 'publish',
           (select id from fixture where name = 'direct_rev'), 1,
           (select id from fixture where name = 'publisher'), 'human',
           'Hendelse skrevet direkte for å teste triggeren.', now(),
           timestamptz '1999-01-01 00:00:00+00'
  $$,
  'en hendelse kan skrives direkte med en oppgitt godkjenningsdato');

select is(
  (select pe.approval_decided_at from knowledge.publication_events pe
   where pe.revision_id = (select id from fixture where name = 'direct_rev')),
  (select rd.decided_at from workflow.review_decisions rd
   where rd.claim_revision_id = (select id from fixture where name = 'direct_rev')),
  'triggeren overskriver kallerens dato med godkjenningens: verdien eies av databasen');

-- En senere beslutning som ikke er «approved» gjør den gjeldende beslutningen
-- ugyldig. Speiler publiseringsgaten G12: en godkjenningsdato skal ikke bli
-- stående som gyldig når reviewer har bedt om endringer etterpå.
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'deterministic_fact', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'sertralin' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'stale_claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Revisjon der reviewer ba om endringer etter godkjenningen.',
         'Gjelder bare testene i denne filen.', 'none', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'stale_claim')
  returning id
)
insert into fixture (name, id) select 'stale_rev', id from inserted;

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Godkjent, men se den senere beslutningen.', rg.id, 'human',
       now() - interval '5 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'stale_rev') and rg.name = 'reviewer';

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'changes_requested',
       'Formuleringen må presiseres likevel.', rg.id, 'human', now() - interval '1 day'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'stale_rev') and rg.name = 'reviewer';

select lives_ok(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select (select id from fixture where name = 'stale_claim'), 'publish',
           (select id from fixture where name = 'stale_rev'), 1,
           (select id from fixture where name = 'publisher'), 'human',
           'Hendelse skrevet etter at reviewer ba om endringer.', now()
  $$,
  'en hendelse kan skrives for en revisjon der gjeldende beslutning ikke er approved');

select is(
  (select pe.approval_decided_at from knowledge.publication_events pe
   where pe.claim_id = (select id from fixture where name = 'stale_claim')),
  null::timestamptz,
  'godkjenningsdatoen er NULL når den gjeldende beslutningen ikke er approved (speiler gaten G12)');

-- Regelen som gjør en godkjenningsdato uten publisert revisjon umulig. Triggeren
-- setter alltid NULL på en avpublisering, så regelen er utilgjengelig gjennom
-- den normale veien; den kontrolleres derfor med triggeren avslått. Uten dette
-- ville assertionen vært stille sann — den ville bestått fordi triggeren ryddet
-- opp, ikke fordi regelen finnes.
alter table knowledge.publication_events
  disable trigger publication_events_set_approval_decided_at;

select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       previous_revision_id, previous_revision_number, previous_event_id,
       published_by_actor_id, published_by_actor_type, reason, published_at,
       approval_decided_at)
    select (select id from fixture where name = 'claim'), 'withdraw', null, null,
           (select id from fixture where name = 'rev1'), 1,
           (select pe.id from knowledge.publication_events pe
            where pe.revision_id = (select id from fixture where name = 'rev1')),
           (select id from fixture where name = 'publisher'), 'human',
           'Avpublisering med en godkjenningsdato den ikke kan ha.', now(),
           now() - interval '2 days'
  $$,
  '%publication_events_approval_requires_revision_check%',
  'en godkjenningsdato uten publisert revisjon avvises av databasen, ikke bare av triggeren');

alter table knowledge.publication_events
  enable trigger publication_events_set_approval_decided_at;

-- ===========================================================================
-- Del 6 — Governance-grensen: kun tidsstempler
--
-- Beslutningen bak 007a var «kun tidsstempler». Testene under er den andre
-- halvdelen av den: reviewers identitet, begrunnelsen og historikken forøvrig
-- skal ikke kunne leses, heller ikke gjennom den nye leseveien.
-- ===========================================================================

set local role anon;

-- Et view som projiserer en kolonne kalleren mangler grant på, feiler — og
-- feilmeldingen navngir tabellen, ikke bare SQLSTATE. throws_like framfor
-- throws_ok, slik at testen ikke kan bestå på et tidligere lag.
select throws_like(
  $$select reason from knowledge.publication_events$$,
  '%permission denied for schema knowledge%',
  'anon kan ikke navngi publiseringshistorikken direkte, tross kolonnegranten');

reset role;

create view api.probe_reason with (security_invoker = true) as
  select reason from knowledge.publication_events;
grant select on api.probe_reason to anon;

create view api.probe_actor with (security_invoker = true) as
  select published_by_actor_id from knowledge.publication_events;
grant select on api.probe_actor to anon;

set local role anon;
select throws_like(
  $$select * from api.probe_reason$$,
  '%permission denied for table publication_events%',
  'publiseringsbegrunnelsen er ikke lesbar selv gjennom et view som projiserer den');
select throws_like(
  $$select * from api.probe_actor$$,
  '%permission denied for table publication_events%',
  'hvem som publiserte er ikke lesbart selv gjennom et view som projiserer det');
reset role;

-- Radgrensen: bare hendelsen som beskriver den gjeldende publiseringen.
-- Historikken bak den — avpubliseringen fra del 5 — er ikke lesbar.
create view api.probe_events with (security_invoker = true) as
  select claim_id, revision_id, published_at from knowledge.publication_events;
grant select on api.probe_events to anon;

select is(
  (select count(*) from knowledge.publication_events
   where claim_id = (select id from fixture where name = 'fact_claim')),
  5::bigint,
  'det deterministiske faktumet har fem hendelser: publisert, avpublisert, republisert, avpublisert, republisert');

set local role anon;
select is(
  (select count(*) from api.probe_events
   where claim_id = (select id from fixture where name = 'fact_claim')),
  3::bigint,
  'anon ser bare de tre hendelsene som navngir den gjeldende revisjonen, ikke de to avpubliseringene');
reset role;

select * from finish();
rollback;
