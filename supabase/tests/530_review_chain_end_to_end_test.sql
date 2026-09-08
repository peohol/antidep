-- Hele beslutningskjeden, fra deterministisk «uncertain» til publisert påstand.
--
-- 470, 490, 500, 510 og 520 prøver hvert ledd for seg. Denne filen prøver dem i
-- sammenheng, i den rekkefølgen de faktisk skjer, og med hvert ledd registrert
-- gjennom sin egen faktiske skrivevei:
--
--   1. Den deterministiske claim-verifikatoren konkluderer med uncertain.
--      Gaten blokkerer på G9. Det er riktig svar og ikke en mangel: tre av de
--      sju kontrollpunktene kan en deterministisk kontroll aldri sette til ok
--      (MVP_IMPLEMENTATION_PLAN.md §74.35).
--   2. En kvalifisert menneskelig reviewer gjør den faglige vurderingen og
--      konkluderer med verified. Gaten blokkerer nå på G11: kontrollen mot
--      grunnlaget er ikke det samme som å gå god for publisering.
--   3. Den samme revieweren registrerer publiseringsgodkjenningen. Gaten slipper
--      gjennom.
--   4. En publisher — en annen rolle, og her en annen person — publiserer.
--
-- Poenget med filen er punkt 2 og 3 som to atskilte ledd. De er to
-- beslutningsobjekter i to tabeller, og gaten krever dem hver for seg
-- (ANTIDEP_CONSTITUTION.md §11 og §12 er to forskjellige krav).
--
-- SQLSTATE 42501 = insufficient_privilege, 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(20);

-- ===========================================================================
-- Fikstur
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'extraction_verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';
insert into fixture (name, id) select 'claim_verifier', id from provenance.actors where actor_key = 'agent:citation-support-verification';

insert into auth.users (id, instance_id, aud, role, email)
select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u.email
from (values
  ('53000000-0000-4000-8000-0000000000a0'::uuid, 'reviewer530@example.test'),
  ('53000000-0000-4000-8000-0000000000b0'::uuid, 'publisher530@example.test')
) as u(id, email);

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values
  ('53000000-0000-4000-8000-0000000000a1', 'human:reviewer-530', 'human', 'Reviewer 530',
   'Kvalifisert reviewer, for 530.', '53000000-0000-4000-8000-0000000000a0'),
  ('53000000-0000-4000-8000-0000000000b1', 'human:publisher-530', 'human', 'Publisher 530',
   'Publisher, for 530.', '53000000-0000-4000-8000-0000000000b0');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('53000000-0000-4000-8000-0000000000a0', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Reviewer-tildeling for 530.'),
  ('53000000-0000-4000-8000-0000000000b0', 'publisher', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Publisher-tildeling for 530.');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('53000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 530',
        'Testforfatter 530', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
values ('53000000-0000-4000-8000-000000000021', '53000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/530', 'sha256:' || repeat('a', 64),
        (select id from fixture where name = 'extractor'));

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values ('53000000-0000-4000-8000-000000000011', '53000000-0000-4000-8000-000000000001',
        '53000000-0000-4000-8000-000000000021',
        'randomized_controlled_trial', 'not_reported', 'Prøve i 530.',
        'not_reported', (select id from fixture where name = 'sertralin'), 'none',
        (select id from fixture where name = 'weight'), 'Funn for 530.',
        'not_reported', 'increase', 'not_reported', 'not_reported',
        'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor'));

with c as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis',
         (select id from fixture where name = 'weight'),
         (select id from fixture where name = 'sertralin'),
         (select id from fixture where name = 'synthesis')
  returning id, knowledge_type, subject_drug_id, created_by_actor_id
)
insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
select '53000000-0000-4000-8000-000000000031', c.id, 1, c.knowledge_type, c.subject_drug_id,
       'Testpåstand for 530.', 'Gjelder bare som testdata i 530.', 'none', 'increase',
       'Testusikkerhet.', c.created_by_actor_id
from c;

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('53000000-0000-4000-8000-000000000041', '53000000-0000-4000-8000-000000000031',
        '53000000-0000-4000-8000-000000000011', 'supports', 'direct',
        'Lenke i 530.', (select id from fixture where name = 'synthesis'));

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'verified', 'original_source', workflow.required_check_fields(e.id),
       'Prøve i 530: fullstendig kontrollert ekstraksjon.', now()
from knowledge.evidence_items e where e.id = '53000000-0000-4000-8000-000000000011';

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
values ('53000000-0000-4000-8000-000000000031', 'evidence_synthesis', 'grade', 'low',
        'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
        'Prøve i 530: lav sikkerhet, og det er hele poenget: lav sikkerhet er ikke det samme som ingen evidens.',
        now(), (select id from fixture where name = 'synthesis'));

create temporary table digest (label text primary key, value text) on commit drop;
insert into digest values
  ('r31', knowledge.claim_evidence_set_digest('53000000-0000-4000-8000-000000000031'));
grant select on digest to authenticated;

create temporary table citations (label text primary key, payload jsonb) on commit drop;
insert into citations values
  ('ok', jsonb_build_array(jsonb_build_object(
     'claim_evidence_link_id', '53000000-0000-4000-8000-000000000041',
     'source_access', 'original_source',
     'source_version_id', '53000000-0000-4000-8000-000000000021',
     'checked_content_hash', 'sha256:' || repeat('a', 64),
     'relationship_supported', 'ok'))),
  ('uavklart', jsonb_build_array(jsonb_build_object(
     'claim_evidence_link_id', '53000000-0000-4000-8000-000000000041',
     'source_access', 'verifiable_representation',
     'source_version_id', '53000000-0000-4000-8000-000000000021',
     'checked_content_hash', 'sha256:' || repeat('a', 64),
     'relationship_supported', 'not_assessable',
     'finding', 'Relasjonstypen lot seg ikke bedømme deterministisk.')));
grant select on citations to anon, authenticated;

create temporary table cred (label text primary key, secret text) on commit drop;
insert into cred select 'claim', provenance.issue_agent_identity_credential(
  'agent-identity:citation-support-verification-01', 'human:peder-holman');
grant select on cred to anon;
create temporary table agent_run (label text primary key, id uuid) on commit drop;
grant insert, select on agent_run to anon;

-- now() er transaksjonens starttidspunkt, så to kontroller registrert i denne
-- transaksjonen ville fått samme verified_at og «den siste» ville vært avgjort
-- av en tilfeldig uuid. Den foregående dyttes derfor en time bakover, slik en
-- reell kjøring får det av at hver registrering er sin egen transaksjon. Samme
-- grep og samme begrunnelse som i 490.
create function pg_temp.age_earlier_verifications() returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update workflow.claim_verifications
  set verified_at = verified_at - interval '1 hour',
      created_at = created_at - interval '1 hour'
  where claim_revision_id = '53000000-0000-4000-8000-000000000031';
  set local session_replication_role = origin;
end;
$$;

-- ===========================================================================
-- Ledd 1 — Den deterministiske kontrollen konkluderer med uncertain
-- ===========================================================================
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '53000000-0000-4000-8000-000000000031')$$,
  '%ingen registrert claim-verifikasjon%',
  'før noe er kontrollert, blokkerer gaten på G8'
);

set local role anon;
insert into agent_run select 'r', api.begin_agent_run(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  'citation_support_verification', 'testleverandør', 'testmodell', '2026-09-09',
  'claim-verification/1', 'antidep-evidence/1', '{"mode": "test-530"}'::jsonb);
select lives_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01',
      (select secret from cred where label = 'claim'),
      (select id from agent_run where label = 'r'),
      '53000000-0000-4000-8000-000000000031',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      (select payload from citations where label = 'uavklart'),
      'Prøve i 530: deterministisk kontroll uten avvik, men uten mulighet til å konkludere.',
      'Ordlyd, forbehold og urepresentert motstridende evidens krever menneskelig vurdering.')
  $$,
  'den deterministiske claim-verifikatoren registrerer sin kontroll'
);
reset role;

select is(
  (select cv.outcome::text from workflow.claim_verifications cv
   where cv.claim_revision_id = '53000000-0000-4000-8000-000000000031'),
  'uncertain',
  'den deterministiske kontrollen konkluderer med uncertain, som er det beste den kan gi'
);
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '53000000-0000-4000-8000-000000000031')$$,
  '%konkluderer ikke med verified%',
  'G9 blokkerer: en uavklart kontroll er ingen bekreftelse'
);

-- Og rekkefølgen er bindende: godkjenningen kan ikke gis nå. Uten det vilkåret
-- kunne revieweren godkjent her, og den godkjenningen ville blitt stående og
-- båret publiseringen etter at kontrollen kom — altså en godkjenning gitt til et
-- ukontrollert utkast (migrasjon 006e, ANTIDEP_CONSTITUTION.md §13).
select set_config('request.jwt.claims',
                  '{"sub":"53000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select throws_like(
  $$
    select api.register_publication_approval(
      '53000000-0000-4000-8000-000000000031'::uuid,
      (select value from digest where label = 'r31'),
      'approved',
      'Prøve i 530: forsøk på å godkjenne før kontrollen er gjort.')
  $$,
  '%konkluderer ikke med verified%',
  'godkjenningen kan ikke registreres før påstanden er kontrollert mot grunnlaget'
);
reset role;

-- ===========================================================================
-- Ledd 2 — Den menneskelige faglige kontrollen
-- ===========================================================================
select lives_ok(
  $$set constraints all immediate$$,
  'den utsatte dekningskontrollen godtar den deterministiske kontrollen'
);
set constraints all deferred;
select pg_temp.age_earlier_verifications();

select set_config('request.jwt.claims',
                  '{"sub":"53000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.register_human_claim_verification(
      '53000000-0000-4000-8000-000000000031'::uuid,
      (select value from digest where label = 'r31'),
      'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
      (select payload from citations where label = 'ok'),
      'Prøve i 530: gikk gjennom ordlyd, forbehold og grunnlaget for urepresentert evidens, og fant ingenting som felte påstanden.')
  $$,
  'revieweren registrerer sin egen faglige kontroll, mot originalkilden'
);
reset role;

select is(
  (select count(*)::integer from workflow.claim_verifications
   where claim_revision_id = '53000000-0000-4000-8000-000000000031'),
  2,
  'den deterministiske kontrollen er bevart ved siden av den menneskelige: tabellen er append-only'
);
select is(
  (select cv.verifier_actor_id from workflow.claim_verifications cv
   where cv.claim_revision_id = '53000000-0000-4000-8000-000000000031'
   order by cv.verified_at desc, cv.created_at desc, cv.id desc limit 1),
  '53000000-0000-4000-8000-0000000000a1'::uuid,
  'den gjeldende kontrollen er menneskets, og den er attribuert til det mennesket'
);
select is(
  (select cv.agent_run_id from workflow.claim_verifications cv
   where cv.claim_revision_id = '53000000-0000-4000-8000-000000000031'
   order by cv.verified_at desc, cv.created_at desc, cv.id desc limit 1),
  null::uuid,
  'den menneskelige kontrollen har ingen agentkjøring bak seg'
);
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '53000000-0000-4000-8000-000000000031')$$,
  '%ikke godkjent av en kvalifisert redaktør%',
  'G8, G9, G9b og G9c er passert, og G11 står igjen: kontrollen mot grunnlaget er ikke en godkjenning'
);

-- ===========================================================================
-- Ledd 3 — Publiseringsgodkjenningen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"53000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.register_publication_approval(
      '53000000-0000-4000-8000-000000000031'::uuid,
      (select value from digest where label = 'r31'),
      'approved',
      'Prøve i 530: går god for at påstanden kan publiseres på dette grunnlaget.')
  $$,
  'revieweren registrerer publiseringsgodkjenningen som en egen beslutning'
);
reset role;

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      '53000000-0000-4000-8000-000000000031')$$,
  'med begge beslutningene registrert slipper hele publiseringsgaten gjennom'
);

-- De to beslutningene er to objekter, i to tabeller, med hver sin begrunnelse.
-- Det er dette som gjør at flaten ikke kan ha én «godkjenn alt»-knapp.
select is(
  (select count(distinct t)::integer from (
     select 'claim_verification' as t from workflow.claim_verifications
     where claim_revision_id = '53000000-0000-4000-8000-000000000031'
       and verifier_actor_id = '53000000-0000-4000-8000-0000000000a1'
     union all
     select 'review_decision' from workflow.review_decisions
     where claim_revision_id = '53000000-0000-4000-8000-000000000031'
       and reviewer_actor_id = '53000000-0000-4000-8000-0000000000a1'
   ) as decisions),
  2,
  'revieweren har registrert to atskilte beslutninger, ikke én'
);

-- ===========================================================================
-- Ledd 4 — Publisering, som er en tredje rettighet
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"53000000-0000-4000-8000-0000000000a0"}', true);
select throws_ok(
  $$
    select knowledge.publish_claim_revision(
      '53000000-0000-4000-8000-000000000031',
      '53000000-0000-4000-8000-0000000000a1',
      'Reviewer forsøker å publisere.')
  $$,
  '42501', 'Brukeren har ikke gyldig publisher-rolle for dette innholdsområdet.',
  'reviewer-rollen gir ikke publiseringsrett: å godkjenne og å publisere er to handlinger'
);

select set_config('request.jwt.claims',
                  '{"sub":"53000000-0000-4000-8000-0000000000b0"}', true);
select lives_ok(
  $$
    select knowledge.publish_claim_revision(
      '53000000-0000-4000-8000-000000000031',
      '53000000-0000-4000-8000-0000000000b1',
      'Prøve i 530: første publisering av testpåstanden.')
  $$,
  'en publisher publiserer revisjonen'
);
select set_config('request.jwt.claims', '', true);

select is(
  (select c.current_published_revision_id
   from knowledge.claims c
   join knowledge.claim_revisions r on r.claim_id = c.id
   where r.id = '53000000-0000-4000-8000-000000000031'),
  '53000000-0000-4000-8000-000000000031'::uuid,
  'publiseringspekeren står på revisjonen som ble godkjent'
);
select is(
  (select e.action::text || '|' || e.published_by_actor_id::text
   from knowledge.publication_events e
   where e.revision_id = '53000000-0000-4000-8000-000000000031'),
  'publish|53000000-0000-4000-8000-0000000000b1',
  'publiseringshendelsen er registrert som en førstegangspublisering, attribuert til publisher'
);

-- ===========================================================================
-- Proveniens: hvert ledd i kjeden står i auditloggen
--
-- Assertionen er på hvilke operasjoner som er registrert og hvor mange av hver,
-- ikke på rekkefølgen mellom dem. Det er et bevisst valg og ikke en svakere
-- test: alle radene i denne testen skrives i én transaksjon, og `now()` er
-- transaksjonens starttidspunkt, så `occurred_at` er identisk på alle fire. En
-- assertion på rekkefølge ville dermed hvilt på radenes fysiske plassering og
-- ikke på noe loggen faktisk sier — den ville passert eller feilet etter hvilken
-- uuid som tilfeldigvis ble generert.
--
-- Rekkefølgen mellom de to kontrollene er derimot prøvd, og der bærer dataene
-- den: `verified_at` skiller dem med en time, og assertionen over på hvem som
-- står som den gjeldende, er nettopp den prøven.
-- ===========================================================================
select is(
  (select string_agg(t.operation || '×' || t.antall::text, ', ' order by t.operation)
   from (
     select e.operation::text as operation, count(*) as antall
     from audit.events e
     where e.operation in ('claim_verification_registered', 'review_decision_registered',
                           'claim_published')
       and e.object_id in (
         select cv.id from workflow.claim_verifications cv
         where cv.claim_revision_id = '53000000-0000-4000-8000-000000000031'
         union all
         select rd.id from workflow.review_decisions rd
         where rd.claim_revision_id = '53000000-0000-4000-8000-000000000031'
         union all
         select c.id from knowledge.claims c
         join knowledge.claim_revisions r on r.claim_id = c.id
         where r.id = '53000000-0000-4000-8000-000000000031'
       )
     group by e.operation
   ) as t),
  'claim_published×1, claim_verification_registered×2, review_decision_registered×1',
  'hvert ledd i beslutningskjeden har etterlatt sin egen auditrad, og den deterministiske kontrollen er bevart ved siden av den menneskelige'
);

-- Og påstanden er nå synlig i den offentlige lesemodellen.
set local role anon;
select is(
  (select count(*)::integer from api.published_claims pc
   where pc.claim_revision_id = '53000000-0000-4000-8000-000000000031'),
  1,
  'den publiserte påstanden er synlig for en uinnlogget leser'
);
reset role;

select finish();
rollback;
