-- Migrasjon 004 — immutabilitet og databaseeide felter i påstandslaget.
--
-- MVP_IMPLEMENTATION_PLAN.md §21 krever immutable revisjoner, §42 krever en
-- eksplisitt negativ test på at en publisert immutable revisjon ikke kan
-- redigeres, og DATABASE_ARCHITECTURE.md §7.1 og §36 krever at historikk verken
-- overskrives eller slettes i vanlig redaksjonelt arbeid.
--
-- Valgt strategi:
--   * knowledge.claim_revisions, claim_evidence_links og evidence_assessments
--     er append-only. En rettelse er en ny revisjon.
--   * knowledge.claims har per-kolonne frys på identitetsfeltene, fordi
--     publiseringspeker og tilbaketrekking er livssyklus og må kunne endres.
--
-- Testen kontrollerer både at vernet holder, og at det ikke overblokkerer.
-- Særlig viktig: at korreksjonsveien faktisk er farbar. Fordi lenkene og
-- vurderingen er append-only og vurderingen finnes i nøyaktig ett eksemplar per
-- revisjon, må en ny revisjon med ordrett samme formulering kunne opprettes.
-- Var content_hash unik, ville den blitt avvist som dublett, og en feil i en
-- GRADE-vurdering hadde vært umulig å rette.
--
-- SQLSTATE 23001 = restrict_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(31);

-- ---------------------------------------------------------------------------
-- Testdata som bare finnes inne i denne transaksjonen
-- ---------------------------------------------------------------------------

-- Migrasjon 005 gjorde created_by_actor_id påkrevd på kunnskapsobjektene
-- (ANTIDEP_CONSTITUTION.md §14). Testdata attribueres til den samme aktøren som
-- produserte de seedede radene, slik at fikstursradene ikke er mindre
-- attribuerte enn kunnskapsbasen ellers.
create function pg_temp.synthesis_actor() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'agent:claim-synthesis'
$$;

insert into knowledge.claims
  (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
select 'evidence_synthesis', c.id, d.id, pg_temp.synthesis_actor()
from catalog.clinical_concepts c, catalog.drugs d
where c.canonical_label = 'depressiv lidelse' and d.canonical_name = 'sertralin';

create function pg_temp.test_claim() returns uuid language sql as $$
  select cl.id
  from knowledge.claims cl
  join catalog.clinical_concepts c on c.id = cl.topic_concept_id
  where c.canonical_label = 'depressiv lidelse';
$$;

create function pg_temp.insert_revision(
  number integer,
  claim_statement text default 'Testpåstand om vektendring i testdata.'
) returns uuid language sql as $$
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, population_id, timeframe_min, timeframe_max,
    comparator_kind, direction, uncertainty_summary, created_by_actor_id
  )
  select
    cl.id, number, cl.knowledge_type, cl.subject_drug_id,
    claim_statement,
    'Gjelder gjennomsnittlig vektendring fra behandlingsstart i testdata.',
    p.id, interval '8 weeks', interval '8 weeks',
    'none', 'increase', 'Ett evidensfunn i testdata.', pg_temp.synthesis_actor()
  from knowledge.claims cl
  cross join catalog.populations p
  where cl.id = pg_temp.test_claim()
    and p.canonical_label = 'voksne med depressiv lidelse'
  returning id;
$$;

select pg_temp.insert_revision(1);

insert into knowledge.claim_evidence_links (
  claim_revision_id, evidence_item_id, relationship_type, directness, relevance_note,
  created_by_actor_id
)
select r.id, e.id, 'supports', 'direct', 'Testbegrunnelse for evidenslenken.',
       pg_temp.synthesis_actor()
from knowledge.claim_revisions r
join knowledge.evidence_items e on true
join catalog.drugs d on d.id = e.intervention_drug_id
where r.claim_id = pg_temp.test_claim() and r.revision_number = 1
  and d.canonical_name = 'sertralin';

insert into knowledge.evidence_assessments (
  claim_revision_id, assessed_knowledge_type, framework, certainty_level,
  risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
  rationale, assessed_at, created_by_actor_id
)
select
  r.id, r.knowledge_type, 'grade', 'very_low',
  'serious', 'not_assessable', 'not_serious', 'very_serious', 'not_assessable',
  'Testbegrunnelse for sikkerhetsgraden.', now(), pg_temp.synthesis_actor()
from knowledge.claim_revisions r
where r.claim_id = pg_temp.test_claim() and r.revision_number = 1;

-- ---------------------------------------------------------------------------
-- knowledge.claim_revisions er append-only
--
-- Hver kolonnegruppe testes for seg, slik at testen sier hvilken endring som ble
-- forsøkt, og slik at et halvveis vern ikke kan se ut som et helt.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$update knowledge.claim_revisions set statement = 'Endret formulering.'
    where claim_id = pg_temp.test_claim()$$,
  '23001', null,
  'formuleringen i en revisjon kan ikke endres etter innsetting'
);
select throws_ok(
  $$update knowledge.claim_revisions set direction = 'decrease'
    where claim_id = pg_temp.test_claim()$$,
  '23001', null,
  'retningen i en revisjon kan ikke endres etter innsetting'
);
select throws_ok(
  $$update knowledge.claim_revisions set population_id = null
    where claim_id = pg_temp.test_claim()$$,
  '23001', null,
  'populasjonsavgrensningen kan ikke endres etter innsetting'
);
select throws_ok(
  $$update knowledge.claim_revisions
    set magnitude_measure = 'mean_change', magnitude_value = 0.8, magnitude_unit = 'kg'
    where claim_id = pg_temp.test_claim()$$,
  '23001', null,
  'en størrelse kan ikke legges til i en eksisterende revisjon'
);
select throws_ok(
  $$update knowledge.claim_revisions set uncertainty_summary = 'Ny usikkerhetstekst.'
    where claim_id = pg_temp.test_claim()$$,
  '23001', null,
  'usikkerhetsteksten kan ikke endres etter innsetting'
);
select throws_ok(
  $$update knowledge.claim_revisions set revision_number = 9
    where claim_id = pg_temp.test_claim()$$,
  '23001', null,
  'revisjonsnummeret kan ikke endres etter innsetting'
);
select throws_ok(
  $$delete from knowledge.claim_revisions where claim_id = pg_temp.test_claim()$$,
  '23001', null,
  'en revisjon kan ikke slettes'
);

-- ---------------------------------------------------------------------------
-- knowledge.claim_evidence_links og knowledge.evidence_assessments er
-- append-only
-- ---------------------------------------------------------------------------
select throws_ok(
  $$update knowledge.claim_evidence_links set relationship_type = 'contradicts'$$,
  '23001', null,
  'relasjonstypen på en evidenslenke kan ikke endres etter innsetting'
);
select throws_ok(
  $$update knowledge.claim_evidence_links set relevance_note = 'Endret begrunnelse.'$$,
  '23001', null,
  'begrunnelsen på en evidenslenke kan ikke endres etter innsetting'
);
select throws_ok(
  $$delete from knowledge.claim_evidence_links$$,
  '23001', null,
  'en evidenslenke kan ikke slettes'
);
select throws_ok(
  $$update knowledge.evidence_assessments set certainty_level = 'high'$$,
  '23001', null,
  'sikkerhetsgraden i en evidensvurdering kan ikke endres etter innsetting'
);
select throws_ok(
  $$update knowledge.evidence_assessments set rationale = 'Endret begrunnelse.'$$,
  '23001', null,
  'begrunnelsen i en evidensvurdering kan ikke endres etter innsetting'
);
select throws_ok(
  $$delete from knowledge.evidence_assessments$$,
  '23001', null,
  'en evidensvurdering kan ikke slettes'
);

-- ---------------------------------------------------------------------------
-- Korreksjonsveien er reell
--
-- Dette er den viktigste gruppen i filen. Vurderingen finnes i nøyaktig ett
-- eksemplar per revisjon og kan ikke endres, så en feil GRADE-vurdering må
-- kunne rettes ved å opprette en ny revisjon — også når formuleringen er ordrett
-- den samme. Med UNIQUE på content_hash hadde den nye revisjonen blitt avvist
-- som dublett, og feilen vært umulig å rette.
-- ---------------------------------------------------------------------------
select lives_ok(
  $$select pg_temp.insert_revision(2)$$,
  'en ny revisjon med ordrett samme formulering kan opprettes, slik at en feil vurdering kan rettes'
);
select is(
  (select count(distinct content_hash) from knowledge.claim_revisions
   where claim_id = pg_temp.test_claim()),
  1::bigint,
  'de to revisjonene har samme fingeravtrykk, fordi det faglige innholdet er likt'
);
-- Revisjon 1 er vurdert, og evidenssettet er dermed forseglet. Uten den regelen
-- kunne et nytt funn blitt hengt på en allerede vurdert revisjon, og vurderingen
-- ville stilltiende gjeldt et annet grunnlag enn det som står registrert.
select throws_ok(
  $$
    insert into knowledge.claim_evidence_links (
      claim_revision_id, evidence_item_id, relationship_type, directness, relevance_note,
      created_by_actor_id
    )
    select r.id, e.id, 'contradicts', 'direct',
           'Motstridende funn oppdaget etter at vurderingen forelå.',
           pg_temp.synthesis_actor()
    from knowledge.claim_revisions r
    join knowledge.evidence_items e on true
    join catalog.drugs d on d.id = e.intervention_drug_id
    where r.claim_id = pg_temp.test_claim() and r.revision_number = 1
      and d.canonical_name = 'mirtazapin'
  $$,
  '23001', null,
  'en vurdert revisjon kan ikke få nye evidenslenker'
);

-- Den nye revisjonen bygger sitt eget, fullstendige evidenssett før den vurderes.
select lives_ok(
  $$
    insert into knowledge.claim_evidence_links (
      claim_revision_id, evidence_item_id, relationship_type, directness, relevance_note,
      created_by_actor_id
    )
    select r.id, e.id, 'contradicts', 'direct',
           'Motstridende funn tatt med i den nye revisjonens evidenssett.',
           pg_temp.synthesis_actor()
    from knowledge.claim_revisions r
    join knowledge.evidence_items e on true
    join catalog.drugs d on d.id = e.intervention_drug_id
    where r.claim_id = pg_temp.test_claim() and r.revision_number = 2
      and d.canonical_name = 'mirtazapin'
  $$,
  'en revisjon som ennå ikke er vurdert kan bygge opp evidenssettet sitt'
);

select lives_ok(
  $$
    insert into knowledge.evidence_assessments (
      claim_revision_id, assessed_knowledge_type, framework, certainty_level,
      risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
      rationale, assessed_at, created_by_actor_id
    )
    select
      r.id, r.knowledge_type, 'grade', 'low',
      'not_serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
      'Rettet begrunnelse for sikkerhetsgraden.', now(), pg_temp.synthesis_actor()
    from knowledge.claim_revisions r
    where r.claim_id = pg_temp.test_claim() and r.revision_number = 2
  $$,
  'den nye revisjonen kan få den korrigerte evidensvurderingen'
);

-- Og forseglingen gjelder også den: rekkefølgen lenker-så-vurdering er den
-- eneste lovlige, uansett hvilken revisjon det gjelder.
select throws_ok(
  $$
    insert into knowledge.claim_evidence_links (
      claim_revision_id, evidence_item_id, relationship_type, directness, relevance_note,
      created_by_actor_id
    )
    select r.id, e.id, 'supports', 'direct', 'Enda et funn, etter vurderingen.',
           pg_temp.synthesis_actor()
    from knowledge.claim_revisions r
    join knowledge.evidence_items e on true
    join catalog.drugs d on d.id = e.intervention_drug_id
    where r.claim_id = pg_temp.test_claim() and r.revision_number = 2
      and d.canonical_name = 'sertralin'
  $$,
  '23001', null,
  'forseglingen gjelder enhver vurdert revisjon, ikke bare den første'
);

-- Kontroll av at innsettingene over faktisk traff rader: en lives_ok på en
-- setning som ikke berører noen rad ville passert uten å bevise noe.
select results_eq(
  $$
    select r.revision_number, count(l.id)
    from knowledge.claim_revisions r
    left join knowledge.claim_evidence_links l on l.claim_revision_id = r.id
    where r.claim_id = pg_temp.test_claim()
    group by r.revision_number
    order by r.revision_number
  $$,
  $$values (1, 1::bigint), (2, 1::bigint)$$,
  'begge revisjonene har sitt eget evidenssett, og forseglingen har hindret utvidelse av dem'
);
select is(
  (select count(*) from knowledge.evidence_assessments a
   join knowledge.claim_revisions r on r.id = a.claim_revision_id
   where r.claim_id = pg_temp.test_claim()),
  2::bigint,
  'begge vurderingene er bevart, én per revisjon'
);

-- ---------------------------------------------------------------------------
-- content_hash eies av databasen
-- ---------------------------------------------------------------------------
select matches(
  (select content_hash from knowledge.claim_revisions
   where claim_id = pg_temp.test_claim() and revision_number = 1),
  '^sha256-v1:[0-9a-f]{64}$',
  'content_hash settes av databasen med versjonert algoritmeprefiks'
);

-- Testen oppgir bevisst en forfalsket hash. Uten trigger ville verdien blitt
-- lagret som den er.
insert into knowledge.claim_revisions (
  claim_id, revision_number, knowledge_type, subject_drug_id,
  statement, scope, comparator_kind, uncertainty_summary, content_hash,
  created_by_actor_id
)
select
  cl.id, 3, cl.knowledge_type, cl.subject_drug_id,
  'Testpåstand med forfalsket fingeravtrykk.', 'Testomfang.', 'none',
  'Testusikkerhet.', 'sha256-v1:' || repeat('0', 64), pg_temp.synthesis_actor()
from knowledge.claims cl
where cl.id = pg_temp.test_claim();

select isnt(
  (select content_hash from knowledge.claim_revisions
   where claim_id = pg_temp.test_claim() and revision_number = 3),
  'sha256-v1:' || repeat('0', 64),
  'en hash oppgitt av kalleren ignoreres og overskrives av databasen'
);
select isnt(
  (select content_hash from knowledge.claim_revisions
   where claim_id = pg_temp.test_claim() and revision_number = 3),
  (select content_hash from knowledge.claim_revisions
   where claim_id = pg_temp.test_claim() and revision_number = 1),
  'to revisjoner med ulikt faglig innhold får ulike fingeravtrykk'
);

-- ---------------------------------------------------------------------------
-- knowledge.claims: identiteten er frosset, livssyklusen er ikke
-- ---------------------------------------------------------------------------
select throws_ok(
  $$update knowledge.claims set knowledge_type = 'clinical_recommendation'
    where id = pg_temp.test_claim()$$,
  '23001', null,
  'kunnskapstypen på en påstand kan ikke endres etter innsetting'
);
select throws_ok(
  $$
    update knowledge.claims
    set topic_concept_id =
      (select id from catalog.clinical_concepts where canonical_label = 'vektendring')
    where id = pg_temp.test_claim()
  $$,
  '23001', null,
  'temaet på en påstand kan ikke endres etter innsetting'
);
select throws_ok(
  $$
    update knowledge.claims
    set subject_drug_id = (select id from catalog.drugs where canonical_name = 'mirtazapin')
    where id = pg_temp.test_claim()
  $$,
  '23001', null,
  'virkestoffet på en påstand kan ikke endres etter innsetting'
);

-- Vernet skal ikke overblokkere: publiseringspeker og tilbaketrekking er
-- livssyklus, ikke identitet.
--
-- Fra migrasjon 009e er pekeren to kolonner og ikke én: revisjonen og det
-- forseglede innholdet som faktisk ble publisert. De settes sammen, og
-- claims_published_candidate_pairing_check gjør at de ikke kan settes hver for
-- seg — en peker som navnga en revisjon uten å navngi innholdet, ville ikke
-- sagt hva klinikeren fikk se.
select lives_ok(
  $$
    update knowledge.claims
    set current_published_revision_id =
          (select r.id from knowledge.claim_revisions r
           where r.claim_id = pg_temp.test_claim() and r.revision_number = 2),
        current_published_candidate_id = pg_temp.seal_and_approve_candidate(
          (select r.id from knowledge.claim_revisions r
           where r.claim_id = pg_temp.test_claim() and r.revision_number = 2))
    where id = pg_temp.test_claim()
  $$,
  'publiseringspekeren kan flyttes uten at identiteten endres'
);
-- Halv peker er ingen peker (23514 = check_violation).
select throws_ok(
  $$
    update knowledge.claims
    set current_published_candidate_id = null
    where id = pg_temp.test_claim()
  $$,
  '23514', null,
  'publiseringspekeren kan ikke navngi en revisjon uten å navngi innholdet'
);
-- DATABASE_ARCHITECTURE.md §58: pekeren må peke på en revisjon av riktig
-- identitet. Regelen håndheves av den sammensatte fremmednøkkelen, ikke av
-- applikasjonskode (23503 = foreign_key_violation).
select throws_ok(
  $$
    update knowledge.claims
    set current_published_revision_id =
          (select r.id from knowledge.claim_revisions r
           join knowledge.claims c2 on c2.id = r.claim_id
           join catalog.clinical_concepts cc on cc.id = c2.topic_concept_id
           where cc.canonical_label = 'vektendring' limit 1),
        current_published_candidate_id = pg_temp.seal_and_approve_candidate(
          (select r.id from knowledge.claim_revisions r
           join knowledge.claims c2 on c2.id = r.claim_id
           join catalog.clinical_concepts cc on cc.id = c2.topic_concept_id
           where cc.canonical_label = 'vektendring' limit 1))
    where id = pg_temp.test_claim()
  $$,
  '23503', null,
  'publiseringspekeren kan ikke peke på en revisjon av en annen påstand'
);

-- Tidsstemplene på identiteten eies av databasen ved både INSERT og UPDATE.
update knowledge.claims
set created_at = '2000-01-01T00:00:00Z', updated_at = '2000-01-01T00:00:00Z'
where id = pg_temp.test_claim();
select results_eq(
  $$
    select created_at = now(), updated_at = now()
    from knowledge.claims where id = pg_temp.test_claim()
  $$,
  $$values (true, true)$$,
  'created_at bevares og updated_at settes av databasen, ikke av klienten'
);

select * from finish();

rollback;
