-- Registreringsrekkefølgen på reviewbeslutningene (migrasjon 006i).
--
-- Hele publiseringskjeden hviler på at den *siste* beslutningen er den
-- gjeldende: publiseringsgatens G6, G11 og G12 leser den, frysingen av
-- godkjenningstidspunktet på publiseringshendelsen leser den, og den publiserte
-- lesemodellen leser den for å si om en ekstraksjon er trukket tilbake.
--
-- «Siste» ble avgjort av decided_at, som settes med now() — transaksjonens
-- starttidspunkt, ikke tidspunktet raden ble skrevet. To samtidige
-- registreringer kan derfor starte i én rekkefølge og skrive i den motsatte, og
-- da bærer raden som faktisk ble skrevet sist det eldste tidsstempelet.
--
-- Filen prøver begge retningene, og prøver dem der de gjør skade:
--
--   * en godkjenning skrevet sist, med det eldste tidsstempelet, skal slippe
--     revisjonen gjennom gaten, og godkjenningstidspunktet som fryses på
--     hendelsen skal være dens.
--   * en avvisning skrevet sist, med det eldste tidsstempelet, skal blokkere
--     publiseringen på G12 og stå som den gjeldende i reviewerflaten.
--   * en tilbaketrekking skrevet sist, med det eldste tidsstempelet, skal slå
--     gjennom i den publiserte lesemodellen.
--
-- Klokka dyttes bakover på nøyaktig den raden som ble skrevet sist, slik den
-- ville sett ut om den var skrevet av en transaksjon som *startet* først og
-- skrev sist. Samme grep og samme begrunnelse som i 600.
--
-- Det pgTAP ikke kan nå — hva som skjer mellom to reelle forbindelser — er prøve
-- 5 i scripts/db-lock-test.sh.
--
-- SQLSTATE 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(29);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select col_not_null(
  'workflow', 'review_decisions', 'registration_ordinal',
  'reviewbeslutningen har alltid en plass i registreringsrekkefølgen'
);

-- Ingen DEFAULT, med vilje: en default evalueres før BEFORE-triggerne fyrer,
-- altså før radlåsen er tatt, og ville gitt nøyaktig den rekkefølgen migrasjonen
-- finnes for å unngå.
select is_empty(
  $$
    select a.attname::text
    from pg_attribute a
    where a.attrelid = 'workflow.review_decisions'::regclass
      and a.attname = 'registration_ordinal'
      and a.atthasdef
  $$,
  'nummeret har ingen default: det tildeles på innsiden av låsen eller ikke i det hele tatt'
);

select has_trigger(
  'workflow', 'review_decisions', 'review_decisions_set_registration_ordinal',
  'triggeren som tildeler nummeret finnes på reviewbeslutningen'
);

-- BEFORE INSERT, ikke AFTER: en AFTER-trigger kan ikke sette en kolonne på raden.
select is_empty(
  $$
    select t.tgname::text
    from pg_trigger t
    where t.tgname = 'review_decisions_set_registration_ordinal'
      and not (t.tgtype & 2 = 2 and t.tgtype & 4 = 4)
  $$,
  'triggeren er BEFORE INSERT'
);

-- cache 1 er en del av garantien: en bufret sekvens deler ut blokker per økt, og
-- to økter kunne da fått numre i motsatt rekkefølge av skrivingene.
select is(
  (select s.seqcache
   from pg_sequence s
   join pg_class c on c.oid = s.seqrelid
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'workflow' and c.relname = 'review_decision_registration_seq'),
  1::bigint,
  'sekvensen deler ut ett nummer om gangen'
);

select set_eq(
  $$
    select c.conname::text
    from pg_constraint c
    where c.contype = 'u'
      and c.conrelid = 'workflow.review_decisions'::regclass
      and c.conname like '%registration_ordinal%'
  $$,
  $$values ('review_decisions_registration_ordinal_key')$$,
  'nummeret er entydig i tabellen'
);

-- Låsen skal dekke begge review_type-variantene. Bare den ene tas av
-- workflow.set_review_evidence_set_digest(), og en garanti som hviler på en
-- annen triggers navn er ingen garanti.
select matches(
  pg_get_functiondef('workflow.set_review_decision_registration_ordinal()'::regprocedure),
  'from knowledge\.claim_revisions r\s+where r\.id = new\.claim_revision_id\s+for update',
  'nummeret på en publiseringsgodkjenning tildeles på innsiden av låsen på revisjonen'
);
select matches(
  pg_get_functiondef('workflow.set_review_decision_registration_ordinal()'::regprocedure),
  'from knowledge\.evidence_items e\s+where e\.id = new\.evidence_item_id\s+for update',
  'nummeret på en tilbaketrekking tildeles på innsiden av låsen på evidensfunnet'
);

-- Vaktposten under de to over: triggeren låser nøyaktig de objekttypene som
-- finnes. Kommer det en tredje objektpeker på tabellen, feiler denne
-- assertionen, og den som legger den til må ta stilling til sin egen lås —
-- framfor at raden stille får et nummer uten en.
select set_eq(
  $$
    select a.attname::text
    from pg_constraint c
    join pg_attribute a
      on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.conrelid = 'workflow.review_decisions'::regclass
      and c.contype = 'f'
      and array_length(c.conkey, 1) = 1
      and c.confrelid in ('knowledge.claim_revisions'::regclass,
                          'knowledge.evidence_items'::regclass)
  $$,
  $$values ('claim_revision_id'), ('evidence_item_id')$$,
  'beslutningen peker på nøyaktig to objekttyper, og triggeren låser begge'
);


-- ===========================================================================
-- Fikstur
--
-- To påstandsrevisjoner som publiseringsgatens G1 til G10 slipper gjennom, slik
-- at det eneste som avgjør utfallet, er hvilken beslutning som er den
-- gjeldende. Uten det ville gaten stoppet på et tidligere vilkår, og prøven
-- ville ikke sagt noe om beslutningen.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'mirtazapin', id from catalog.drugs where canonical_name = 'mirtazapin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'extraction_verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';

insert into auth.users (id, instance_id, aud, role, email)
select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u.email
from (values
  ('61000000-0000-4000-8000-0000000000a0'::uuid, 'reviewer610@example.test'),
  ('61000000-0000-4000-8000-0000000000b0'::uuid, 'publisher610@example.test')
) as u(id, email);

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values
  ('61000000-0000-4000-8000-0000000000a1', 'human:reviewer-610', 'human', 'Reviewer 610',
   'Kvalifisert reviewer, for 610.', '61000000-0000-4000-8000-0000000000a0'),
  ('61000000-0000-4000-8000-0000000000b1', 'human:publisher-610', 'human', 'Publisher 610',
   'Publisher, for 610.', '61000000-0000-4000-8000-0000000000b0');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('61000000-0000-4000-8000-0000000000a0', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Reviewer-tildeling for 610.'),
  ('61000000-0000-4000-8000-0000000000b0', 'publisher', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Publisher-tildeling for 610.');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('61000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 610',
        'Testforfatter 610', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation,
   retrieved_by_actor_id)
values ('61000000-0000-4000-8000-000000000021', '61000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/610', 'sha256:' || repeat('a', 64), 'abstract',
        (select id from fixture where name = 'extractor'));

-- Ett evidensfunn per revisjon. To revisjoner kunne delt ett funn, men da ville
-- tilbaketrekkingen i del 4 også rammet den andre revisjonen, og prøven ville
-- målt to ting på én gang.
insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
select v.id, '61000000-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000021',
       'randomized_controlled_trial', 'not_reported', 'Prøve i 610.',
       'not_reported', (select id from fixture where name = v.drug), 'none',
       (select id from fixture where name = 'weight'), 'Funn for 610.',
       'not_reported', 'increase', 'not_reported', 'not_reported',
       'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor')
from (values
  ('61000000-0000-4000-8000-000000000011'::uuid, 'sertralin'),
  ('61000000-0000-4000-8000-000000000012'::uuid, 'mirtazapin')
) as v(id, drug);

insert into knowledge.claims
  (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
select v.id, 'evidence_synthesis',
       (select id from fixture where name = 'weight'),
       (select id from fixture where name = v.drug),
       (select id from fixture where name = 'synthesis')
from (values
  ('61000000-0000-4000-8000-000000000031'::uuid, 'sertralin'),
  ('61000000-0000-4000-8000-000000000032'::uuid, 'mirtazapin')
) as v(id, drug);

insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
select v.revision, v.claim, 1, 'evidence_synthesis',
       (select id from fixture where name = v.drug),
       'Testpåstand for 610.', 'Gjelder bare som testdata i 610.', 'none', 'increase',
       'Testusikkerhet.', (select id from fixture where name = 'synthesis')
from (values
  ('61000000-0000-4000-8000-000000000041'::uuid, '61000000-0000-4000-8000-000000000031'::uuid, 'sertralin'),
  ('61000000-0000-4000-8000-000000000042'::uuid, '61000000-0000-4000-8000-000000000032'::uuid, 'mirtazapin')
) as v(revision, claim, drug);

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values
  ('61000000-0000-4000-8000-000000000051', '61000000-0000-4000-8000-000000000041',
   '61000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Lenke i 610.', (select id from fixture where name = 'synthesis')),
  ('61000000-0000-4000-8000-000000000052', '61000000-0000-4000-8000-000000000042',
   '61000000-0000-4000-8000-000000000012', 'supports', 'direct',
   'Lenke i 610.', (select id from fixture where name = 'synthesis'));

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
where e.id in ('61000000-0000-4000-8000-000000000011',
               '61000000-0000-4000-8000-000000000012');

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'verified', 'original_source',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Prøve i 610: fullstendig kontrollert ekstraksjon.', now()
from knowledge.evidence_items e
where e.id in ('61000000-0000-4000-8000-000000000011',
               '61000000-0000-4000-8000-000000000012');

with parent as (
  insert into workflow.claim_verifications
    (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
     source_access, source_support, population_match, comparator_match, timeframe_match,
     direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
     rationale, verified_at)
  select r.id, r.created_by_actor_id, '61000000-0000-4000-8000-0000000000a1',
         'verified', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
         'Prøve i 610: påstanden er kontrollert mot grunnlaget.', now()
  from knowledge.claim_revisions r
  where r.id in ('61000000-0000-4000-8000-000000000041',
                 '61000000-0000-4000-8000-000000000042')
  returning id, claim_revision_id
)
insert into workflow.claim_verification_citations
  (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
   source_access, relationship_supported)
select parent.id, l.claim_revision_id, l.id, l.evidence_item_id, 'original_source', 'ok'
from parent
join knowledge.claim_evidence_links l on l.claim_revision_id = parent.claim_revision_id;

-- Vurderingen attribueres til evidensvurderingsaktøren, ikke til den som
-- formulerte revisjonen: publiseringsgatens G10b krever at den som gjorde
-- vurderingen, hadde mandat til det (migrasjon 005ap). Ansvarsgrensen mellom
-- påstandsdannelse og evidensvurdering er en teknisk grense
-- (EVIDENCE_PIPELINE.md §61).
insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select v.revision, 'evidence_synthesis', 'grade', 'low',
       'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
       'Prøve i 610: lav sikkerhet, registrert bare for at gaten skal ha en vurdering å lese.',
       now(), (select id from provenance.actors where actor_key = 'agent:evidence-assessment')
from (values
  ('61000000-0000-4000-8000-000000000041'::uuid),
  ('61000000-0000-4000-8000-000000000042'::uuid)
) as v(revision);

create temporary table digest (label text primary key, value text) on commit drop;
insert into digest values
  ('r41', knowledge.claim_evidence_set_digest('61000000-0000-4000-8000-000000000041')),
  ('r42', knowledge.claim_evidence_set_digest('61000000-0000-4000-8000-000000000042'));
grant select on digest to authenticated;

-- Klokka dyttes bakover på én navngitt rad, slik den ville sett ut om raden var
-- skrevet av en transaksjon som startet først og skrev sist. Triggerne slås av
-- med session_replication_role og ikke med ALTER TABLE: tabellen er append-only,
-- og regelen skal ikke mykes opp for en prøve.
create function pg_temp.invert_clock(p_decision_id uuid) returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update workflow.review_decisions
  set decided_at = decided_at - interval '3 hours',
      created_at = created_at - interval '3 hours'
  where id = p_decision_id;
  set local session_replication_role = origin;
end;
$$;

create function pg_temp.newest_by_clock(p_claim_revision_id uuid) returns text language sql stable as $$
  select rd.decision::text
  from workflow.review_decisions rd
  where rd.claim_revision_id = p_claim_revision_id
    and rd.review_type = 'publication_approval'
  order by rd.decided_at desc, rd.created_at desc, rd.id desc
  limit 1;
$$;

-- Triggeren avviser ingenting selv: en rad uten objektpeker er
-- review_decisions_single_object_check sin avvisning, og den skal være den
-- kalleren ser. En trigger som rakk å avvise først, ville byttet ut
-- constraintens SQLSTATE med en annen, og gjort det uklart hvilken regel som
-- faktisk sviktet. Assertionen står her og ikke i del 1, fordi en beslutning
-- først må komme forbi kvalifikasjonskontrollen for å nå CHECK-ene i det hele
-- tatt — og revieweren finnes fra fiksturen over.
select throws_ok(
  $$
    insert into workflow.review_decisions
      (review_type, decision, rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
    values ('publication_approval', 'approved', 'Prøve i 610: ingen objektpeker.',
            '61000000-0000-4000-8000-0000000000a1', 'human', now())
  $$,
  '23514',
  null,
  'en beslutning uten objektpeker avvises av constrainten, ikke av triggeren'
);

-- ===========================================================================
-- Del 2 — En godkjenning skrevet sist gjelder, også med det eldste tidsstempelet
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"61000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select api.register_publication_approval(
  '61000000-0000-4000-8000-000000000041'::uuid,
  (select value from digest where label = 'r41'),
  'rejected',
  'Prøve i 610: første beslutning, en avvisning.');
select api.register_publication_approval(
  '61000000-0000-4000-8000-000000000041'::uuid,
  (select value from digest where label = 'r41'),
  'approved',
  'Prøve i 610: omgjøring, skrevet etter avvisningen.');
reset role;

create temporary table decisions (label text primary key, id uuid not null) on commit drop;
insert into decisions
select 'r41_approved', rd.id from workflow.review_decisions rd
where rd.claim_revision_id = '61000000-0000-4000-8000-000000000041' and rd.decision = 'approved';
insert into decisions
select 'r41_rejected', rd.id from workflow.review_decisions rd
where rd.claim_revision_id = '61000000-0000-4000-8000-000000000041' and rd.decision = 'rejected';

select pg_temp.invert_clock((select id from decisions where label = 'r41_approved'));

select is(
  pg_temp.newest_by_clock('61000000-0000-4000-8000-000000000041'),
  'rejected',
  'forutsetningen: sortert på klokka ville avvisningen sett ut som den gjeldende'
);
select is(
  (select rd.decision::text from workflow.review_decisions rd
   where rd.claim_revision_id = '61000000-0000-4000-8000-000000000041'
   order by rd.registration_ordinal desc limit 1),
  'approved',
  'men registreringsrekkefølgen sier godkjenningen, som faktisk ble skrevet sist'
);
select is(
  (select workflow.claim_review_history('61000000-0000-4000-8000-000000000041')
          ->> 'current_review_decision_id'),
  (select id::text from decisions where label = 'r41_approved'),
  'reviewerflaten peker på den raden som ble skrevet sist'
);
select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      '61000000-0000-4000-8000-000000000041')$$,
  'gaten slipper gjennom: G12 leser godkjenningen, ikke klokka'
);

-- ===========================================================================
-- Del 3 — Godkjenningstidspunktet som fryses, er den gjeldende beslutningens
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"61000000-0000-4000-8000-0000000000b0"}', true);
select lives_ok(
  $$
    select knowledge.publish_claim_revision(
      '61000000-0000-4000-8000-000000000041',
      '61000000-0000-4000-8000-0000000000b1',
      'Prøve i 610: publisering på den gjeldende godkjenningen.')
  $$,
  'en publisher publiserer revisjonen'
);
select set_config('request.jwt.claims', '', true);

select is(
  (select e.approval_decided_at from knowledge.publication_events e
   where e.revision_id = '61000000-0000-4000-8000-000000000041'),
  (select rd.decided_at from workflow.review_decisions rd
   where rd.id = (select id from decisions where label = 'r41_approved')),
  'godkjenningstidspunktet på hendelsen er den gjeldende beslutningens, også når den bærer det eldste tidsstempelet'
);

-- ===========================================================================
-- Del 4 — En avvisning skrevet sist blokkerer, også med det eldste tidsstempelet
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"61000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select api.register_publication_approval(
  '61000000-0000-4000-8000-000000000042'::uuid,
  (select value from digest where label = 'r42'),
  'approved',
  'Prøve i 610: første beslutning, en godkjenning.');
select api.register_publication_approval(
  '61000000-0000-4000-8000-000000000042'::uuid,
  (select value from digest where label = 'r42'),
  'rejected',
  'Prøve i 610: omgjøring, skrevet etter godkjenningen.');
reset role;

insert into decisions
select 'r42_rejected', rd.id from workflow.review_decisions rd
where rd.claim_revision_id = '61000000-0000-4000-8000-000000000042' and rd.decision = 'rejected';

select pg_temp.invert_clock((select id from decisions where label = 'r42_rejected'));

select is(
  pg_temp.newest_by_clock('61000000-0000-4000-8000-000000000042'),
  'approved',
  'forutsetningen: sortert på klokka ville godkjenningen sett ut som den gjeldende'
);
select is(
  (select workflow.claim_review_history('61000000-0000-4000-8000-000000000042')
          ->> 'current_review_decision_id'),
  (select id::text from decisions where label = 'r42_rejected'),
  'reviewerflaten peker på avvisningen, som ble skrevet sist'
);
select throws_ok(
  $$select knowledge.assert_claim_revision_publishable(
      '61000000-0000-4000-8000-000000000042')$$,
  '23001',
  null,
  'G12 blokkerer: et menneskes nei forsvinner ikke bak en godkjenning som ble skrevet før det'
);
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '61000000-0000-4000-8000-000000000042')$$,
  '%er rejected, ikke approved%',
  'og gaten navngir nettopp den gjeldende beslutningen'
);

-- Reviewerens kø viser den samme beslutningen som gaten stopper på. Uten det
-- kunne flaten sagt «godkjent» om noe databasen avviser.
select set_config('request.jwt.claims',
                  '{"sub":"61000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select is(
  (select item ->> 'current_publication_decision'
   from jsonb_array_elements(api.claim_review_workspace() -> 'queue') as item
   where item ->> 'claim_revision_id' = '61000000-0000-4000-8000-000000000042'),
  'rejected',
  'reviewerens kø viser avvisningen som den gjeldende beslutningen'
);
reset role;
select set_config('request.jwt.claims', '', true);

-- ===========================================================================
-- Del 5 — En tilbaketrekking skrevet sist slår gjennom i lesemodellen
--
-- Beslutningen om en ekstraksjon har ingen api-skrivevei ennå og skrives derfor
-- rett i tabellen. Det er samtidig den eneste varianten som låser
-- knowledge.evidence_items, så innsettingen prøver også den grenen.
-- ===========================================================================
insert into workflow.review_decisions
  (id, evidence_item_id, evidence_item_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select '61000000-0000-4000-8000-000000000061', e.id, e.created_by_actor_id,
       'extraction_withdrawal', 'extraction_upheld',
       'Prøve i 610: ekstraksjonen opprettholdes.',
       '61000000-0000-4000-8000-0000000000a1', 'human', now()
from knowledge.evidence_items e where e.id = '61000000-0000-4000-8000-000000000011';

insert into workflow.review_decisions
  (id, evidence_item_id, evidence_item_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select '61000000-0000-4000-8000-000000000062', e.id, e.created_by_actor_id,
       'extraction_withdrawal', 'extraction_withdrawn',
       'Prøve i 610: ekstraksjonen trekkes tilbake, skrevet etter opprettholdelsen.',
       '61000000-0000-4000-8000-0000000000a1', 'human', now()
from knowledge.evidence_items e where e.id = '61000000-0000-4000-8000-000000000011';

select is(
  (select count(*)::integer from workflow.review_decisions rd
   where rd.id in ('61000000-0000-4000-8000-000000000061',
                   '61000000-0000-4000-8000-000000000062')
     and rd.registration_ordinal is not null),
  2,
  'også en tilbaketrekking får sin plass i registreringsrekkefølgen'
);
select ok(
  (select rd.registration_ordinal from workflow.review_decisions rd
   where rd.id = '61000000-0000-4000-8000-000000000062')
  > (select rd.registration_ordinal from workflow.review_decisions rd
     where rd.id = '61000000-0000-4000-8000-000000000061'),
  'og numrene følger rekkefølgen radene ble skrevet i'
);

select pg_temp.invert_clock('61000000-0000-4000-8000-000000000062');

select is(
  (select rd.decision::text from workflow.review_decisions rd
   where rd.evidence_item_id = '61000000-0000-4000-8000-000000000011'
   order by rd.decided_at desc, rd.created_at desc, rd.id desc limit 1),
  'extraction_upheld',
  'forutsetningen: sortert på klokka ville opprettholdelsen sett ut som den gjeldende'
);

set local role anon;
select is(
  (select pc.withdrawn_evidence_count::integer from api.published_claims pc
   where pc.claim_revision_id = '61000000-0000-4000-8000-000000000041'),
  1,
  'påstandssammendraget teller den tilbaketrukne ekstraksjonen'
);
select is(
  (select pce.extraction_withdrawn from api.published_claim_evidence pce
   where pce.claim_evidence_link_id = '61000000-0000-4000-8000-000000000051'),
  true,
  'og evidensflaten viser funnet som trukket tilbake'
);
reset role;

-- Gaten leser den samme beslutningen. En revisjon som hviler på en tilbaketrukket
-- ekstraksjon, kan ikke publiseres på nytt.
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '61000000-0000-4000-8000-000000000041')$$,
  '%tilbaketrukket ekstraksjon%',
  'G6 blokkerer på den samme tilbaketrekkingen'
);

-- Ingenting er filtrert bort: begge beslutningene står, og omgjøringen er en ny
-- rad ved siden av den gamle (DATABASE_ARCHITECTURE.md §31).
select is(
  (select count(*)::integer from workflow.review_decisions rd
   where rd.claim_revision_id = '61000000-0000-4000-8000-000000000041'),
  2,
  'både avvisningen og godkjenningen er bevart'
);
select is(
  (select jsonb_array_length(
            workflow.claim_review_history('61000000-0000-4000-8000-000000000041')
            -> 'review_decisions')),
  2,
  'og reviewerflaten viser dem begge'
);

select finish();
rollback;
