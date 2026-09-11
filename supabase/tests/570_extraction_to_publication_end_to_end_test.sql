-- Hele den tekniske kjeden, fra et registrert evidensfunn til en publisert
-- påstand, med hvert ledd registrert gjennom sin egen faktiske skrivevei:
--
--   EvidenceItem
--     → menneskelig ekstraksjonskontroll   (api.register_human_extraction_verification)
--     → menneskelig claim-kontroll         (api.register_human_claim_verification)
--     → publiseringsgodkjenning            (api.register_publication_approval)
--     → publisering                        (api.publish_claim_revision)
--
-- 530 prøvde kjeden fra og med claim-kontrollen, og måtte da seede en
-- fullstendig ekstraksjonsverifikasjon direkte i tabellen fordi det ikke fantes
-- noen menneskelig vei inn i den. Denne filen lukker det hullet: hvert eneste
-- ledd går gjennom en api-funksjon, og gaten spørres mellom hvert av dem.
--
-- Filen prøver også de fire tingene som skiller ekstraksjonsleddet fra de andre:
--
--   * at en deterministisk «uncertain» blokkerer på G5, og at det er riktig svar
--   * at en menneskelig bekreftelse som bare dekker en delmengde av feltene
--     blokkerer på G5b — en delkontroll er ikke en full kontroll
--   * at et senere avvik nullstiller dekningen, slik at en tidligere bekreftelse
--     ikke kan bære publiseringen
--   * at publisering krever en tredje rettighet, og at rettigheten ikke åpner
--     noen gate
--
-- SQLSTATE 42501 = insufficient_privilege, 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(28);

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

insert into auth.users (id, instance_id, aud, role, email)
select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u.email
from (values
  ('57000000-0000-4000-8000-0000000000a0'::uuid, 'reviewer570@example.test'),
  ('57000000-0000-4000-8000-0000000000b0'::uuid, 'publisher570@example.test')
) as u(id, email);

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values
  ('57000000-0000-4000-8000-0000000000a1', 'human:reviewer-570', 'human', 'Reviewer 570',
   'Kvalifisert reviewer, for 570.', '57000000-0000-4000-8000-0000000000a0'),
  ('57000000-0000-4000-8000-0000000000b1', 'human:publisher-570', 'human', 'Publisher 570',
   'Publisher, for 570.', '57000000-0000-4000-8000-0000000000b0');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('57000000-0000-4000-8000-0000000000a0', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Reviewer-tildeling for 570.'),
  ('57000000-0000-4000-8000-0000000000b0', 'publisher', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Publisher-tildeling for 570.');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('57000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 570',
        'Testforfatter 570', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
values ('57000000-0000-4000-8000-000000000021', '57000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/570', 'sha256:' || repeat('a', 64),
        (select id from fixture where name = 'extractor'));

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values ('57000000-0000-4000-8000-000000000011', '57000000-0000-4000-8000-000000000001',
        '57000000-0000-4000-8000-000000000021',
        'randomized_controlled_trial', 'not_reported', 'Prøve i 570.',
        'not_reported', (select id from fixture where name = 'sertralin'), 'none',
        (select id from fixture where name = 'weight'), 'Funn for 570.',
        'not_reported', 'increase', 'not_reported', 'not_reported',
        'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor'));

-- Kildeforankring for hvert semantisk felt. Fra migrasjon 005x kan en
-- bekreftelse ikke registreres på en rad uten den: da fantes det ingen
-- venstreside å ha kontrollert. Utdragene er syntetiske, som resten av
-- fiksturen — det som prøves her er leseflaten, ikke gjenfinningen.
insert into knowledge.evidence_field_groundings
  (evidence_item_id, created_by_actor_id, check_field,
   source_excerpt, source_locator, justification)
select e.id, e.created_by_actor_id, f.field,
       'Utdrag for ' || f.field::text || ' i 570.',
       'Avsnitt for ' || f.field::text,
       'Begrunnelse for ' || f.field::text || '.'
from knowledge.evidence_items e
cross join unnest(workflow.semantic_check_fields(e.id)) as f(field)
where e.source_id = '57000000-0000-4000-8000-000000000001';

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
select '57000000-0000-4000-8000-000000000031', c.id, 1, c.knowledge_type, c.subject_drug_id,
       'Testpåstand for 570.', 'Gjelder bare som testdata i 570.', 'none', 'increase',
       'Testusikkerhet.', c.created_by_actor_id
from c;

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('57000000-0000-4000-8000-000000000041', '57000000-0000-4000-8000-000000000031',
        '57000000-0000-4000-8000-000000000011', 'supports', 'direct',
        'Lenke i 570.', (select id from fixture where name = 'synthesis'));

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
values ('57000000-0000-4000-8000-000000000031', 'evidence_synthesis', 'grade', 'low',
        'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
        'Prøve i 570: lav sikkerhet, som er noe annet enn ingen vurderbar evidens.',
        now(), (select id from fixture where name = 'synthesis'));

-- Avtrykkene leveres av flaten, ikke regnes ut av klienten:
-- workflow.evidence_extraction_digest() er ikke kjørbar for authenticated.
-- Tabellen friskes opp mellom leddene, slik testen gjør det en reell flate gjør
-- ved ny henting.
create temporary table digest (label text primary key, value text) on commit drop;
grant select on digest to authenticated;
create function pg_temp.refresh_digests() returns void language sql as $$
  insert into digest values
    ('e11', workflow.evidence_extraction_digest('57000000-0000-4000-8000-000000000011')),
    ('r31', knowledge.claim_evidence_set_digest('57000000-0000-4000-8000-000000000031'))
  on conflict (label) do update set value = excluded.value;
$$;
select pg_temp.refresh_digests();

create temporary table citations (label text primary key, payload jsonb) on commit drop;
insert into citations values
  ('ok', jsonb_build_array(jsonb_build_object(
     'claim_evidence_link_id', '57000000-0000-4000-8000-000000000041',
     'source_access', 'original_source',
     'source_version_id', '57000000-0000-4000-8000-000000000021',
     'checked_content_hash', 'sha256:' || repeat('a', 64),
     'relationship_supported', 'ok')));
grant select on citations to authenticated;

-- now() er transaksjonens starttidspunkt, så to kontroller registrert i denne
-- transaksjonen ville fått samme verified_at og «den siste» ville vært avgjort
-- av en tilfeldig uuid. Den foregående dyttes derfor en time bakover, slik en
-- reell kjøring får det av at hver registrering er sin egen transaksjon. Samme
-- grep og samme begrunnelse som i 490 og 530.
create function pg_temp.age_earlier_extraction_checks() returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update workflow.evidence_verifications
  set verified_at = verified_at - interval '1 hour',
      created_at = created_at - interval '1 hour'
  where evidence_item_id = '57000000-0000-4000-8000-000000000011';
  set local session_replication_role = origin;
end;
$$;

-- ===========================================================================
-- Ledd 1 — Ingen ekstraksjonskontroll: gaten stopper på G4
-- ===========================================================================
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '57000000-0000-4000-8000-000000000031')$$,
  '%uten registrert ekstraksjonsverifikasjon%',
  'før noe er kontrollert, blokkerer gaten på G4'
);

-- ===========================================================================
-- Ledd 2 — Den deterministiske kontrollen konkluderer med uncertain
--
-- Nøyaktig tilstanden begge produksjonsrevisjonene står i (§74.36): kontrollen
-- fant ikke utdragene den trengte, og «uncertain» er det beste den kan gi.
-- ===========================================================================
create temporary table cred (label text primary key, secret text) on commit drop;
insert into cred select 'extraction', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman');
grant select on cred to anon;
create temporary table agent_run (label text primary key, id uuid) on commit drop;
grant insert, select on agent_run to anon;

set local role anon;
insert into agent_run select 'r', api.begin_agent_run(
  'agent-identity:extraction-verification-01', (select secret from cred where label = 'extraction'),
  'extraction_verification', 'testleverandør', 'testmodell', '2026-09-10',
  'extraction-verification/1', 'antidep-evidence/1', '{"mode": "test-570"}'::jsonb);
select lives_ok(
  $$
    select api.register_extraction_verification(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'extraction'),
      (select id from agent_run where label = 'r'),
      '57000000-0000-4000-8000-000000000011',
      'uncertain', 'verifiable_representation',
      -- source_wide_absence er det kildeomfattende søket: raden fører et felt
      -- som ikke rapportert, og maskinen har gjennomsøkt hele representasjonen
      -- uten å finne en verdi for det (migrasjon 005ae). Det er den ene
      -- halvdelen av den påstanden ingen menneskelig økt kan bære.
      array['source_locator', 'raw_extraction', 'source_wide_absence'],
      'Prøve i 570: den deterministiske kontrollen fant ikke utdragene den trengte.',
      'Tidspunkt, retning og forbehold lot seg ikke bedømme maskinelt.')
  $$,
  'den deterministiske ekstraksjonsverifikatoren registrerer sin kontroll'
);
reset role;

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '57000000-0000-4000-8000-000000000031')$$,
  '%med åpent verifikasjonsfunn%',
  'G5 blokkerer: en uavklart kontroll er ingen bekreftelse'
);

-- ===========================================================================
-- Ledd 3 — Menneskets kontroll, men bare av en delmengde
--
-- G5 slipper nå gjennom — den siste kontrollen er verified — men G5b gjør det
-- ikke: dekningen er mindre enn det funnet påstår noe om. Uten G5b ville en
-- delkontroll alene tilfredsstilt en gate som er ment å bety at ekstraksjonen er
-- kontrollert.
-- ===========================================================================
select pg_temp.age_earlier_extraction_checks();
select pg_temp.refresh_digests();

select set_config('request.jwt.claims',
                  '{"sub":"57000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.register_human_extraction_verification(
      '57000000-0000-4000-8000-000000000011'::uuid,
      (select value from digest where label = 'e11'),
      'verified', 'original_source',
      array['source_locator', 'raw_extraction'],
      'Prøve i 570: gikk gjennom sitatet og kildepekeren mot originalkilden.')
  $$,
  'revieweren registrerer en bekreftelse som dekker en delmengde av feltene'
);
reset role;

select is(
  (select ev.outcome::text from workflow.evidence_verifications ev
   where ev.evidence_item_id = '57000000-0000-4000-8000-000000000011'
   order by ev.verified_at desc, ev.created_at desc, ev.id desc limit 1),
  'verified',
  'den gjeldende kontrollen er nå menneskets bekreftelse'
);
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '57000000-0000-4000-8000-000000000031')$$,
  '%uten fullstendig kontrollert ekstraksjon%',
  'G5b blokkerer likevel: en delkontroll er ikke en full kontroll'
);

-- ===========================================================================
-- Ledd 4 — Menneskets fullstendige kontroll
-- ===========================================================================
select pg_temp.age_earlier_extraction_checks();
select pg_temp.refresh_digests();

-- Mennesket bedømmer alt funnet påstår noe om, unntatt det kildeomfattende
-- søket: kontrolløkten stiller ikke det spørsmålet, og maskinen har allerede
-- besvart det i ledd 2.
create temporary table required_fields (value text[]) on commit drop;
insert into required_fields
select array_remove(
  workflow.required_check_fields('57000000-0000-4000-8000-000000000011'),
  'source_wide_absence'::workflow.evidence_check_field)::text[];
grant select on required_fields to authenticated;

select set_config('request.jwt.claims',
                  '{"sub":"57000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;

-- …og kan ikke ta den på seg heller. En kontrolløkt som førte opp feltet, ville
-- påstått et søk gjennom hele representasjonen som aldri ble gjort
-- (migrasjon 005ae).
select throws_ok(
  $$
    select api.register_human_extraction_verification(
      '57000000-0000-4000-8000-000000000011'::uuid,
      (select value from digest where label = 'e11'),
      'verified', 'original_source',
      array['source_locator', 'source_wide_absence'],
      'Prøve i 570: et menneske forsøker å bære den kildeomfattende påstanden.')
  $$,
  '23514', null,
  'et menneske kan ikke registrere den kildeomfattende fraværskontrollen'
);

select lives_ok(
  $$
    select api.register_human_extraction_verification(
      '57000000-0000-4000-8000-000000000011'::uuid,
      (select value from digest where label = 'e11'),
      'verified', 'original_source',
      (select value from required_fields),
      'Prøve i 570: gikk gjennom hvert felt funnet påstår noe om, mot originalkilden.')
  $$,
  'revieweren registrerer en bekreftelse som dekker alt funnet påstår noe om'
);
reset role;

select is(
  (select count(*)::integer from workflow.evidence_verifications
   where evidence_item_id = '57000000-0000-4000-8000-000000000011'),
  3,
  'alle tre kontrollene er bevart ved siden av hverandre: tabellen er append-only'
);
select is(
  (select ev.agent_run_id from workflow.evidence_verifications ev
   where ev.evidence_item_id = '57000000-0000-4000-8000-000000000011'
   order by ev.verified_at desc, ev.created_at desc, ev.id desc limit 1),
  null::uuid,
  'den menneskelige kontrollen har ingen agentkjøring bak seg'
);
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '57000000-0000-4000-8000-000000000031')$$,
  '%ingen registrert claim-verifikasjon%',
  'G4, G5, G5b og G5c er passert, og G8 står igjen: ekstraksjonen er kontrollert, påstanden ikke'
);

-- Og reviewflaten for påstanden viser den nye kontrollen som den gjeldende, etter
-- ny henting. De to flatene leser den samme raden med den samme rekkefølgen, så
-- en kontroll registrert på ekstraksjonsflaten kan ikke bli usynlig på den andre.
create temporary table workspace (label text primary key, payload jsonb) on commit drop;
grant insert, select on workspace to authenticated;

select set_config('request.jwt.claims',
                  '{"sub":"57000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
insert into workspace select 'etter ekstraksjonskontroll',
  api.claim_review_workspace('57000000-0000-4000-8000-000000000031');
reset role;

select is(
  (select payload #>> '{revision,links,0,current_extraction_verification,outcome}'
   from workspace where label = 'etter ekstraksjonskontroll'),
  'verified',
  'claim-reviewflaten viser den menneskelige ekstraksjonskontrollen som den gjeldende'
);
select is(
  (select payload #>> '{revision,links,0,current_extraction_verification,evidence_verification_id}'
   from workspace where label = 'etter ekstraksjonskontroll'),
  (select ev.id::text from workflow.evidence_verifications ev
   where ev.evidence_item_id = '57000000-0000-4000-8000-000000000011'
   order by ev.verified_at desc, ev.created_at desc, ev.id desc limit 1),
  'og det er nøyaktig den raden publiseringsgaten leser som den gjeldende'
);
select alike(
  (select payload #>> '{revision,approval_readiness,message}'
   from workspace where label = 'etter ekstraksjonskontroll'),
  '%ingen registrert claim-verifikasjon%',
  'forutsetningene før godkjenningen har flyttet seg fra ekstraksjonen til påstanden'
);

-- ===========================================================================
-- Ledd 5 — Claim-kontrollen og godkjenningen, som to atskilte beslutninger
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"57000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select throws_like(
  $$
    select api.register_publication_approval(
      '57000000-0000-4000-8000-000000000031'::uuid,
      (select value from digest where label = 'r31'),
      'approved',
      'Prøve i 570: forsøk på å godkjenne før påstanden er kontrollert.')
  $$,
  '%ingen registrert claim-verifikasjon%',
  'godkjenningen kan ikke registreres før påstanden er kontrollert mot grunnlaget'
);
select lives_ok(
  $$
    select api.register_human_claim_verification(
      '57000000-0000-4000-8000-000000000031'::uuid,
      (select value from digest where label = 'r31'),
      'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
      (select payload from citations where label = 'ok'),
      'Prøve i 570: gikk gjennom ordlyd, forbehold og urepresentert evidens.')
  $$,
  'revieweren registrerer sin faglige kontroll av påstanden'
);
reset role;

select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '57000000-0000-4000-8000-000000000031')$$,
  '%ikke godkjent av en kvalifisert redaktør%',
  'G11 står igjen: kontrollen mot grunnlaget er ikke en godkjenning'
);

select set_config('request.jwt.claims',
                  '{"sub":"57000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.register_publication_approval(
      '57000000-0000-4000-8000-000000000031'::uuid,
      (select value from digest where label = 'r31'),
      'approved',
      'Prøve i 570: går god for at påstanden kan publiseres på dette grunnlaget.')
  $$,
  'revieweren registrerer publiseringsgodkjenningen som en egen beslutning'
);
reset role;

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      '57000000-0000-4000-8000-000000000031')$$,
  'med alle beslutningene registrert slipper hele publiseringsgaten gjennom'
);

-- ===========================================================================
-- Ledd 6 — Publisering gjennom den redaksjonelle handlingen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"57000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select throws_ok(
  $$
    select api.publish_claim_revision(
      '57000000-0000-4000-8000-000000000031',
      'Reviewer forsøker å publisere i 570.')
  $$,
  '42501', 'Brukeren har ikke gyldig publisher-rolle for dette innholdsområdet.',
  'reviewer-rollen gir ikke publiseringsrett, heller ikke gjennom den redaksjonelle handlingen'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"57000000-0000-4000-8000-0000000000b0"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.publish_claim_revision(
      '57000000-0000-4000-8000-000000000031',
      'Prøve i 570: første publisering av testpåstanden.')
  $$,
  'en publisher publiserer revisjonen gjennom api.publish_claim_revision()'
);
reset role;
select set_config('request.jwt.claims', '', true);

select is(
  (select c.current_published_revision_id
   from knowledge.claims c
   join knowledge.claim_revisions r on r.claim_id = c.id
   where r.id = '57000000-0000-4000-8000-000000000031'),
  '57000000-0000-4000-8000-000000000031'::uuid,
  'publiseringspekeren står på revisjonen som ble godkjent'
);
select is(
  (select e.action::text || '|' || e.published_by_actor_id::text
   from knowledge.publication_events e
   where e.revision_id = '57000000-0000-4000-8000-000000000031'),
  'publish|57000000-0000-4000-8000-0000000000b1',
  'publiseringshendelsen er en førstegangspublisering, attribuert til publisher og ikke til revieweren'
);
select is(
  (select count(*)::integer from api.published_claims pc
   where pc.claim_revision_id = '57000000-0000-4000-8000-000000000031'),
  1,
  'og påstanden er synlig i den offentlige projeksjonen'
);

-- Hvert ledd i kjeden står i auditloggen, med sin egen operasjon.
select is(
  (select string_agg(t.operation || '×' || t.antall::text, ', ' order by t.operation)
   from (
     select e.operation::text as operation, count(*) as antall
     from audit.events e
     where e.operation in ('evidence_verification_registered', 'claim_verification_registered',
                           'review_decision_registered', 'claim_published')
       and e.occurred_at >= now() - interval '1 minute'
     group by e.operation
   ) as t),
  'claim_published×1, claim_verification_registered×1, evidence_verification_registered×3, review_decision_registered×1',
  'hvert ledd i kjeden la igjen sin egen auditrad'
);

-- ===========================================================================
-- Ledd 7 — Et senere avvik nullstiller dekningen
--
-- Publiseringen er gjort, men gaten skal fortsatt være sann om nåtilstanden: en
-- ny kontroll som ikke bekrefter, gjør at bekreftelsene foran den ikke lenger
-- teller. Uten det kunne sekvensen «avvik → delkontroll» fjernet et åpent funn
-- uten at noen så på det omstridte feltet igjen.
-- ===========================================================================
select pg_temp.age_earlier_extraction_checks();
select pg_temp.refresh_digests();

select set_config('request.jwt.claims',
                  '{"sub":"57000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.register_human_extraction_verification(
      '57000000-0000-4000-8000-000000000011'::uuid,
      (select value from digest where label = 'e11'),
      'needs_correction', 'original_source',
      array['source_locator', 'timepoint'],
      'Prøve i 570: ny gjennomgang av tidspunktet.',
      'Tidspunktet i raden stemmer ikke med kilden.')
  $$,
  'en ny kontroll finner et avvik i et felt som allerede var bekreftet'
);
reset role;

select is(
  (select workflow.covered_check_fields('57000000-0000-4000-8000-000000000011')),
  '{}'::workflow.evidence_check_field[],
  'dekningen er nullstilt: bekreftelsene foran avviket teller ikke lenger'
);
select throws_like(
  $$select knowledge.assert_claim_revision_publishable(
      '57000000-0000-4000-8000-000000000031')$$,
  '%med åpent verifikasjonsfunn%',
  'og gaten blokkerer igjen, på nøyaktig det samme vilkåret som i ledd 2'
);

select finish();
rollback;
