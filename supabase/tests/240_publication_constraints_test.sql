-- Migrasjon 006 — constraints, FK-integritet og immutabilitet i publiseringslaget.
--
-- Testene her går direkte på tabellen, forbi publiseringsfunksjonene, og
-- kontrollerer at reglene holder også når noen skriver rett i historikken. Det
-- er ikke et hypotetisk scenario: tabelleieren og senere migrasjoner kan gjøre
-- nettopp det, og en regel som bare finnes i funksjonen ville da vært ingen regel
-- (DATABASE_ARCHITECTURE.md §57).
--
-- Selve gatene testes i 250 og tilgang i 260.
--
-- SQLSTATE 23514 = check_violation, 23503 = foreign_key_violation,
-- 23505 = unique_violation, 23001 = restrict_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(24);

-- ---------------------------------------------------------------------------
-- Testdata som bare finnes inne i denne transaksjonen.
--
-- Fixturen gir én evidenssyntese med to revisjoner, ett deterministisk faktum
-- med én revisjon, og én menneskelig aktør å attribuere hendelser til.
-- ---------------------------------------------------------------------------
create temporary table fixture (name text primary key, id uuid not null) on commit drop;

insert into auth.users (id, email)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'publisher-240@test.invalid');

insert into provenance.actors (actor_type, actor_key, display_name, description, auth_user_id)
values ('human', 'human:publisher-240', 'Testpublisher',
        'Menneskelig aktør for constrainttestene i 240.',
        'aaaaaaaa-0000-0000-0000-000000000001');

insert into fixture (name, id)
select 'publisher', id from provenance.actors where actor_key = 'human:publisher-240';
insert into fixture (name, id)
select 'synthesis_actor', id from provenance.actors where actor_key = 'agent:claim-synthesis';

-- Den seedede sertralinpåstanden med sin ene revisjon.
insert into fixture (name, id)
select 'claim', c.id
from knowledge.claims c
join catalog.drugs d on d.id = c.subject_drug_id
where d.canonical_name = 'sertralin';
insert into fixture (name, id)
select 'rev1', r.id
from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'claim');

-- En andre revisjon av den samme påstanden, slik at replace og rollback kan
-- uttrykkes i det hele tatt.
insert into knowledge.claim_revisions (
  claim_id, revision_number, knowledge_type, subject_drug_id, supersedes_revision_id,
  statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id
)
select
  c.id, 2, c.knowledge_type, c.subject_drug_id, (select id from fixture where name = 'rev1'),
  'Andre formulering av den samme påstanden, opprettet for constrainttestene.',
  'Testomfang.',
  'none',
  'Testusikkerhet.',
  (select id from fixture where name = 'synthesis_actor')
from knowledge.claims c
where c.id = (select id from fixture where name = 'claim');

insert into fixture (name, id)
select 'rev2', r.id
from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'claim')
  and r.revision_number = 2;

-- En påstand av en annen identitet, for å vise at hendelsen ikke kan blande dem.
insert into fixture (name, id)
select 'other_claim', c.id
from knowledge.claims c
join catalog.drugs d on d.id = c.subject_drug_id
where d.canonical_name = 'mirtazapin';
insert into fixture (name, id)
select 'other_rev', r.id
from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'other_claim');

-- ---------------------------------------------------------------------------
-- Hver handling er en bestemt tilstandsovergang
-- ---------------------------------------------------------------------------
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'publish', null, null, null, null, null, null,
           p.id, 'human', 'Uten revisjon.', now()
    from fixture f, fixture p where f.name = 'claim' and p.name = 'publisher'
  $$,
  '%publication_events_action_pointer_check%',
  'en publisering må si hvilken revisjon som ble publisert'
);
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       previous_revision_id, previous_revision_number,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       previous_candidate_id, previous_candidate_digest,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'publish', r2.id, 2, r1.id, 1,
           pg_temp.sealed_candidate_id(r2.id), pg_temp.sealed_candidate_digest(r2.id),
           pg_temp.sealed_final_control_id(r2.id), 'approved',
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           p.id, 'human', 'Med forgjenger.', now()
    from fixture f, fixture r1, fixture r2, fixture p
    where f.name = 'claim' and r1.name = 'rev1' and r2.name = 'rev2' and p.name = 'publisher'
  $$,
  '%publication_events_action_pointer_check%',
  'en publisering kan ikke ha en forutgående publisert revisjon; da er den en erstatning'
);
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       previous_revision_id, previous_revision_number, previous_event_id,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       previous_candidate_id, previous_candidate_digest,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'replace', r1.id, 1, r2.id, 2, null,
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           pg_temp.sealed_final_control_id(r1.id), 'approved',
           pg_temp.sealed_candidate_id(r2.id), pg_temp.sealed_candidate_digest(r2.id),
           p.id, 'human', 'Bakover.', now()
    from fixture f, fixture r1, fixture r2, fixture p
    where f.name = 'claim' and r1.name = 'rev1' and r2.name = 'rev2' and p.name = 'publisher'
  $$,
  '%publication_events_action_pointer_check%',
  'en erstatning må peke framover i revisjonshistorikken'
);
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       previous_revision_id, previous_revision_number, previous_event_id,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       previous_candidate_id, previous_candidate_digest,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'rollback', r2.id, 2, r1.id, 1, null,
           pg_temp.sealed_candidate_id(r2.id), pg_temp.sealed_candidate_digest(r2.id),
           pg_temp.sealed_final_control_id(r2.id), 'approved',
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           p.id, 'human', 'Framover.', now()
    from fixture f, fixture r1, fixture r2, fixture p
    where f.name = 'claim' and r1.name = 'rev1' and r2.name = 'rev2' and p.name = 'publisher'
  $$,
  '%publication_events_action_pointer_check%',
  'en rollback må peke bakover i revisjonshistorikken (DATABASE_ARCHITECTURE.md §40)'
);
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       previous_revision_id, previous_revision_number, previous_event_id,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       previous_candidate_id, previous_candidate_digest,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'withdraw', r1.id, 1, r2.id, 2, null,
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           pg_temp.sealed_final_control_id(r1.id), 'approved',
           pg_temp.sealed_candidate_id(r2.id), pg_temp.sealed_candidate_digest(r2.id),
           p.id, 'human', 'Med ny revisjon.', now()
    from fixture f, fixture r1, fixture r2, fixture p
    where f.name = 'claim' and r1.name = 'rev1' and r2.name = 'rev2' and p.name = 'publisher'
  $$,
  '%publication_events_action_pointer_check%',
  'en avpublisering kan ikke etterlate en publisert revisjon'
);
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       previous_revision_id, previous_revision_number, previous_event_id,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       previous_candidate_id, previous_candidate_digest,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'withdraw', null, null, r1.id, 1, null,
           null, null, null, null,
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           p.id, 'human', 'Først av alt.', now()
    from fixture f, fixture r1, fixture p
    where f.name = 'claim' and r1.name = 'rev1' and p.name = 'publisher'
  $$,
  '%publication_events_first_event_is_publish_check%',
  'den første hendelsen for en påstand må være en publisering'
);

-- Speilene kan ikke settes fritt: de er låst til revisjonsraden.
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'publish', r1.id, 7,
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           pg_temp.sealed_final_control_id(r1.id), 'approved',
           p.id, 'human', 'Feil speil.', now()
    from fixture f, fixture r1, fixture p
    where f.name = 'claim' and r1.name = 'rev1' and p.name = 'publisher'
  $$,
  '%publication_events_revision_fkey%',
  'speilet av revisjonsnummeret kan ikke si noe annet enn revisjonsraden'
);
-- ... og revisjonen må tilhøre den påstanden hendelsen gjelder.
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'publish', o.id, 1,
           pg_temp.sealed_candidate_id(o.id), pg_temp.sealed_candidate_digest(o.id),
           pg_temp.sealed_final_control_id(o.id), 'approved',
           p.id, 'human', 'Feil påstand.', now()
    from fixture f, fixture o, fixture p
    where f.name = 'claim' and o.name = 'other_rev' and p.name = 'publisher'
  $$,
  '%publication_events_revision_fkey%',
  'publiseringspekeren kan ikke peke på en revisjon av en annen påstand (DATABASE_ARCHITECTURE.md §58)'
);

-- ---------------------------------------------------------------------------
-- Attribusjon: bare mennesker publiserer
-- ---------------------------------------------------------------------------
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'publish', r1.id, 1,
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           pg_temp.sealed_final_control_id(r1.id), 'approved',
           a.id, 'agent', 'Agentpublisering.', now()
    from fixture f, fixture r1, fixture a
    where f.name = 'claim' and r1.name = 'rev1' and a.name = 'synthesis_actor'
  $$,
  '%publication_events_publisher_is_human_check%',
  'en KI-aktør kan ikke stå oppført som den som publiserte (MVP_IMPLEMENTATION_PLAN.md §49)'
);
-- ... og aktørtypen kan ikke forfalskes, fordi den er låst til aktørraden.
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'publish', r1.id, 1,
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           pg_temp.sealed_final_control_id(r1.id), 'approved',
           a.id, 'human', 'Agent utgir seg for menneske.', now()
    from fixture f, fixture r1, fixture a
    where f.name = 'claim' and r1.name = 'rev1' and a.name = 'synthesis_actor'
  $$,
  '%publication_events_publisher_fkey%',
  'aktørtypen på hendelsen kan ikke si noe annet enn aktørraden'
);

-- ---------------------------------------------------------------------------
-- Begrunnelse og datering
-- ---------------------------------------------------------------------------
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'publish', r1.id, 1,
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           pg_temp.sealed_final_control_id(r1.id), 'approved',
           p.id, 'human', '   ', now()
    from fixture f, fixture r1, fixture p
    where f.name = 'claim' and r1.name = 'rev1' and p.name = 'publisher'
  $$,
  '%publication_events_reason_check%',
  'en publisering uten reell begrunnelse er ikke etterprøvbar (ANTIDEP_CONSTITUTION.md §14)'
);
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'publish', r1.id, 1,
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           pg_temp.sealed_final_control_id(r1.id), 'approved',
           p.id, 'human', 'Framtidsdatert.',
           now() + interval '1 hour'
    from fixture f, fixture r1, fixture p
    where f.name = 'claim' and r1.name = 'rev1' and p.name = 'publisher'
  $$,
  '%publication_events_published_at_not_future_check%',
  'en publisering kan ikke ha funnet sted i framtiden'
);

-- Registreringstiden eies av databasen: en oppgitt created_at overstyres, og kan
-- derfor ikke brukes til å flytte referansepunktet published_at måles mot.
--
-- Den oppgitte verdien peker framover i tid med hensikt. En bakoverdatert
-- created_at ville i tillegg brutt published_at <= created_at, og da ville denne
-- assertionen passert selv om tidsstempeltriggeren ble fjernet — det er den
-- andre regelen som hadde stoppet raden. Med en framtidsdatert verdi er
-- triggeren den eneste regelen i spill.
insert into knowledge.publication_events
  (claim_id, action, revision_id, revision_number,
   candidate_id, candidate_digest, final_control_id, final_control_decision,
   published_by_actor_id, published_by_actor_type, reason, published_at, created_at)
select f.id, 'publish', r1.id, 1,
       pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
       pg_temp.sealed_final_control_id(r1.id), 'approved',
       p.id, 'human', 'Første publisering i testfixturen.',
       now(), now() + interval '10 years'
from fixture f, fixture r1, fixture p
where f.name = 'claim' and r1.name = 'rev1' and p.name = 'publisher';

select is(
  (select count(*) from knowledge.publication_events where created_at > now()),
  0::bigint,
  'en oppgitt created_at overstyres av databasen (catalog.set_created_at())'
);

-- ---------------------------------------------------------------------------
-- Historikken kan ikke forgrenes
--
-- To hendelser for samme påstand kan ikke ha samme forgjenger. Regelen er
-- samtidighetsvernet: to samtidige publiseringer leser den samme tilstanden og
-- ville skrevet den samme forgjengeren.
-- ---------------------------------------------------------------------------
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'publish', r2.id, 2,
           pg_temp.sealed_candidate_id(r2.id), pg_temp.sealed_candidate_digest(r2.id),
           pg_temp.sealed_final_control_id(r2.id), 'approved',
           p.id, 'human', 'Andre samtidige publisering.', now()
    from fixture f, fixture r2, fixture p
    where f.name = 'claim' and r2.name = 'rev2' and p.name = 'publisher'
  $$,
  '%publication_events_no_forked_history_key%',
  'to publiseringer av samme påstand kan ikke begge være den første; historikken kan ikke forgrenes'
);
-- Kontroll først: en erstatning som følger den forrige hendelsen i kjeden er
-- lovlig. Uten denne assertionen kunne duplikattesten under passert fordi
-- innsetting i tabellen alltid feiler.
select lives_ok(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       previous_revision_id, previous_revision_number, previous_event_id,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       previous_candidate_id, previous_candidate_digest,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'replace', r2.id, 2, r1.id, 1, first_event.id,
           pg_temp.sealed_candidate_id(r2.id), pg_temp.sealed_candidate_digest(r2.id),
           pg_temp.sealed_final_control_id(r2.id), 'approved',
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           p.id, 'human',
           'Legitim erstatning.', now()
    from fixture f, fixture r1, fixture r2, fixture p,
         (select e.id from knowledge.publication_events e
          where e.previous_event_id is null) as first_event
    where f.name = 'claim' and r1.name = 'rev1' and r2.name = 'rev2' and p.name = 'publisher'
  $$,
  'en erstatning som følger den forrige hendelsen i kjeden er lovlig'
);
select is(
  (select count(*) from knowledge.publication_events),
  2::bigint,
  'begge de lovlige hendelsene ble faktisk lagret'
);

-- ... og en andre hendelse fra den samme tilstanden avvises, uansett handling.
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       previous_revision_id, previous_revision_number, previous_event_id,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       previous_candidate_id, previous_candidate_digest,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select f.id, 'withdraw', null, null, r1.id, 1, first_event.id,
           null, null, null, null,
           pg_temp.sealed_candidate_id(r1.id), pg_temp.sealed_candidate_digest(r1.id),
           p.id, 'human',
           'Andre hendelse fra samme tilstand.', now()
    from fixture f, fixture r1, fixture p,
         (select e.id from knowledge.publication_events e
          where e.previous_event_id is null) as first_event
    where f.name = 'claim' and r1.name = 'rev1' and p.name = 'publisher'
  $$,
  '%publication_events_no_forked_history_key%',
  'to hendelser kan ikke ha samme forgjenger, uansett handling'
);

-- Forgjengeren må gjelde den samme påstanden.
select throws_like(
  $$
    insert into knowledge.publication_events
      (claim_id, action, revision_id, revision_number,
       previous_revision_id, previous_revision_number, previous_event_id,
       candidate_id, candidate_digest, final_control_id, final_control_decision,
       previous_candidate_id, previous_candidate_digest,
       published_by_actor_id, published_by_actor_type, reason, published_at)
    select o.id, 'withdraw', null, null, orv.id, 1, other_event.id,
           null, null, null, null,
           pg_temp.sealed_candidate_id(orv.id), pg_temp.sealed_candidate_digest(orv.id),
           p.id, 'human',
           'Kjede på tvers av påstander.', now()
    from fixture o, fixture orv, fixture p,
         (select e.id from knowledge.publication_events e
          where e.previous_event_id is null) as other_event
    where o.name = 'other_claim' and orv.name = 'other_rev' and p.name = 'publisher'
  $$,
  '%publication_events_previous_event_fkey%',
  'hendelseskjeden kan ikke krysse mellom to påstander'
);

-- ---------------------------------------------------------------------------
-- Historikken er append-only (DATABASE_ARCHITECTURE.md §36, §40)
-- ---------------------------------------------------------------------------
select throws_ok(
  $$update knowledge.publication_events set reason = 'Omskrevet begrunnelse.'$$,
  '23001', null,
  'en registrert publiseringshendelse kan ikke endres'
);
select throws_ok(
  $$delete from knowledge.publication_events$$,
  '23001', null,
  'en registrert publiseringshendelse kan ikke slettes; en rollback er ny historikk'
);

-- ---------------------------------------------------------------------------
-- Publisering forsegler evidensgrunnlaget
--
-- Testen kjøres på et deterministisk faktum med hensikt. Et slikt faktum får
-- ingen evidensvurdering, så forseglingen fra migrasjon 004 kan ikke fyre, og
-- regelen som testes er den eneste som kan avvise raden. På en evidenssyntese
-- ville begge reglene avvist den samme raden, og testen ville passert selv om
-- denne regelen ble fjernet.
-- ---------------------------------------------------------------------------
insert into knowledge.claims
  (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
select 'deterministic_fact', c.topic_concept_id, c.subject_drug_id, c.created_by_actor_id
from knowledge.claims c
where c.id = (select id from fixture where name = 'claim');

insert into fixture (name, id)
select 'fact_claim', c.id from knowledge.claims c where c.knowledge_type = 'deterministic_fact';

insert into knowledge.claim_revisions (
  claim_id, revision_number, knowledge_type, subject_drug_id,
  statement, scope, comparator_kind, created_by_actor_id
)
select c.id, 1, c.knowledge_type, c.subject_drug_id,
       'Deterministisk faktum opprettet for forseglingstesten.',
       'Testomfang.', 'none', c.created_by_actor_id
from knowledge.claims c
where c.id = (select id from fixture where name = 'fact_claim');

insert into fixture (name, id)
select 'fact_rev', r.id
from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'fact_claim');

-- Kontroll: før publisering er lenken lovlig. Uten denne assertionen kunne
-- testen under passert fordi lenkeinnsetting alltid feiler.
select lives_ok(
  $$
    insert into knowledge.claim_evidence_links
      (claim_revision_id, evidence_item_id, relationship_type, directness,
       relevance_note, created_by_actor_id)
    select fr.id, e.id, 'supports', 'direct', 'Grunnlag for testfaktumet.', e.created_by_actor_id
    from fixture fr, knowledge.evidence_items e
    where fr.name = 'fact_rev'
    limit 1
  $$,
  'et upublisert deterministisk faktum kan få evidenslenker'
);
-- ... og kontrollen over traff faktisk en rad. Et lives_ok over null rader ville
-- passert uten å ha vist noe som helst.
select is(
  (select count(*) from knowledge.claim_evidence_links l
   where l.claim_revision_id = (select id from fixture where name = 'fact_rev')),
  1::bigint,
  'kontrollen satte faktisk inn en evidenslenke'
);

insert into knowledge.publication_events
  (claim_id, action, revision_id, revision_number,
   candidate_id, candidate_digest, final_control_id, final_control_decision,
   published_by_actor_id, published_by_actor_type, reason, published_at)
select fc.id, 'publish', fr.id, 1,
       pg_temp.sealed_candidate_id(fr.id), pg_temp.sealed_candidate_digest(fr.id),
       pg_temp.sealed_final_control_id(fr.id), 'approved',
       p.id, 'human', 'Publisering av testfaktumet.', now()
from fixture fc, fixture fr, fixture p
where fc.name = 'fact_claim' and fr.name = 'fact_rev' and p.name = 'publisher';

select throws_like(
  $$
    insert into knowledge.claim_evidence_links
      (claim_revision_id, evidence_item_id, relationship_type, directness,
       relevance_note, created_by_actor_id)
    select fr.id, e.id, 'supports', 'direct', 'Nytt grunnlag i ettertid.', e.created_by_actor_id
    from fixture fr, knowledge.evidence_items e
    where fr.name = 'fact_rev'
      and not exists (
        select 1 from knowledge.claim_evidence_links l
        where l.claim_revision_id = fr.id and l.evidence_item_id = e.id
      )
    limit 1
  $$,
  '%har vært publisert, og evidensgrunnlaget er forseglet%',
  'en revisjon som har vært publisert kan ikke få nytt evidensgrunnlag i ettertid'
);

-- ---------------------------------------------------------------------------
-- Hendelsestidspunktet på evidensvurderingen er bundet mot registreringstiden
-- ---------------------------------------------------------------------------
select throws_like(
  $$
    insert into knowledge.evidence_assessments
      (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
       risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
       rationale, assessed_at, created_by_actor_id)
    select r2.id, 'evidence_synthesis', 'grade', 'low',
           'serious', 'not_assessable', 'serious', 'serious', 'not_assessable',
           'Testvurdering.', now() + interval '1 hour', a.id
    from fixture r2, fixture a
    where r2.name = 'rev2' and a.name = 'synthesis_actor'
  $$,
  '%evidence_assessments_assessed_at_not_future_check%',
  'en evidensvurdering kan ikke være gjort i framtiden'
);

select * from finish();

rollback;
