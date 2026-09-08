-- Migrasjon 005j og 005k — den kontrollerte skriveveien for claim-verifikasjon.
--
-- Dekker det samme som 440_extraction_verification_registration_test.sql dekket
-- for ekstraksjonsverifikasjonen: kontrakten (hva som faktisk er eksponert),
-- autentiseringen, konsekvensen (raden, kontrollradene og auditraden), og
-- avvisningene fra tabellenes egne regler.
--
-- I tillegg dekker filen de fire tingene som er nye i dette leddet:
--
--   * mandatet — hvem som i det hele tatt kan kontrollere en påstand
--   * dekningen — at kontrollen gikk gjennom hele evidenssettet
--   * kildegrunnlaget per lenke, og at fingeravtrykket ikke kan finnes på
--   * at radens samlede kildetilgang er den svakeste av lenkenes
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23503 = foreign_key_violation, 23514 = check_violation,
-- 23001 = restrict_violation, P0002 = no_data_found.
begin;

create extension if not exists pgtap with schema extensions;

select plan(35);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'register_claim_verification', 'api.register_claim_verification() finnes'
);
select has_function(
  'audit', 'record_claim_verification_event',
  'audit.record_claim_verification_event() finnes'
);
select has_table(
  'workflow', 'claim_verification_citations',
  'workflow.claim_verification_citations finnes'
);
select has_trigger(
  'workflow', 'claim_verifications', 'claim_verifications_record_creation_audit_event',
  'enhver registrert claim-verifikasjon auditeres'
);
select has_trigger(
  'workflow', 'claim_verifications', 'claim_verifications_assert_complete',
  'dekningskontrollen ligger på tabellen, ikke bare i skriveveien'
);
select has_trigger(
  'workflow', 'claim_verifications', 'claim_verifications_enforce_verifier_mandate',
  'mandatkontrollen ligger på tabellen, ikke bare i skriveveien'
);

-- Constraint-triggeren er utsatt med vilje (migrasjon 005j, avsnitt 7): den
-- kontrollerer forholdet mellom moderraden og kontrollradene, og de siste finnes
-- ikke ennå når moderraden settes inn. Utsettelsen er en egenskap ved
-- kontrakten, ikke en tilfeldighet, og prøves derfor eksplisitt.
select ok(
  (select t.tgdeferrable and t.tginitdeferred
   from pg_trigger t
   where t.tgrelid = 'workflow.claim_verifications'::regclass
     and t.tgname = 'claim_verifications_assert_complete'),
  'dekningskontrollen er utsatt til commit, slik at kontrollradene rekker å bli skrevet'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.register_claim_verification(text,text,uuid,uuid,text,text,text,text,text,text,text,text,jsonb,text,text)'::regprocedure),
  'api.register_claim_verification() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
select ok(
  not (select p.prosecdef from pg_proc p
       where p.oid = 'audit.record_claim_verification_event()'::regprocedure),
  'audit.record_claim_verification_event() er ikke SECURITY DEFINER'
);

select is_empty(
  $$
    select r.role_name
    from (values ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.register_claim_verification(text,text,uuid,uuid,text,text,text,text,text,text,text,text,jsonb,text,text)'::regprocedure,
      'execute'
    )
  $$,
  'api.register_claim_verification() er kjørbar for verken service_role eller PUBLIC'
);
select is_empty(
  $$
    select r.role_name, p.priv
    from (values ('anon'), ('authenticated'), ('public')) as r(role_name),
         (values ('select'), ('insert'), ('update'), ('delete')) as p(priv)
    where has_table_privilege(r.role_name, 'workflow.claim_verification_citations', p.priv)
  $$,
  'anon, authenticated og public har ingen tabellrettighet på workflow.claim_verification_citations'
);
select ok(
  (select c.relrowsecurity from pg_class c
   where c.oid = 'workflow.claim_verification_citations'::regclass),
  'RLS er aktivert på workflow.claim_verification_citations'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- Én kilde med to etterprøvbare kildeversjoner, to evidensfunn laget av
-- ekstraksjonsagenten, og to påstandsrevisjoner:
--
--   R1  formulert av agent:claim-synthesis, lenket til begge funnene.
--       Grunnlaget for den lykkede stien og for dekningskontrollen.
--   R2  formulert av claim-verifikatoren selv, lenket til ett funn.
--       Finnes bare for å prøve selvverifikasjonsregelen med en aktør som
--       faktisk har mandatet — ellers ville mandatet felt forsøket først, og
--       CHECK-en stått uprøvd bak den.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;

insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'mirtazapin', id from catalog.drugs where canonical_name = 'mirtazapin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'claim_verifier', id from provenance.actors where actor_key = 'agent:citation-support-verification';

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values (
  '47000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 470',
  'Testforfatter 470', (select id from fixture where name = 'editor')
);

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id
)
values
  ('47000000-0000-4000-8000-000000000021', '47000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/470-a', 'sha256:' || repeat('a', 64),
   (select id from fixture where name = 'extractor')),
  ('47000000-0000-4000-8000-000000000022', '47000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/470-b', 'sha256:' || repeat('b', 64),
   (select id from fixture where name = 'extractor'));

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values
  ('47000000-0000-4000-8000-000000000011', '47000000-0000-4000-8000-000000000001',
   '47000000-0000-4000-8000-000000000021',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 470.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Første funn, for 470.',
   'not_reported', 'not_stated', 'not_reported', 'not_reported',
   'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor')),
  ('47000000-0000-4000-8000-000000000012', '47000000-0000-4000-8000-000000000001',
   '47000000-0000-4000-8000-000000000022',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 470.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Andre funn, for 470.',
   'not_reported', 'not_stated', 'not_reported', 'not_reported',
   'Avsnitt 2', 'ai_assisted', (select id from fixture where name = 'extractor'));

-- R1 og R2.
with c1 as (
  insert into knowledge.claims (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', (select id from fixture where name = 'weight'),
         (select id from fixture where name = 'sertralin'),
         (select id from fixture where name = 'synthesis')
  returning id, knowledge_type, subject_drug_id, created_by_actor_id
)
insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id)
select '47000000-0000-4000-8000-000000000031', c1.id, 1, c1.knowledge_type, c1.subject_drug_id,
       'Testpåstand for 470, formulert av synteseagenten.',
       'Gjelder bare som testdata i 470.', 'none', 'Testusikkerhet.', c1.created_by_actor_id
from c1;

with c2 as (
  insert into knowledge.claims (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', (select id from fixture where name = 'weight'),
         (select id from fixture where name = 'mirtazapin'),
         (select id from fixture where name = 'claim_verifier')
  returning id, knowledge_type, subject_drug_id, created_by_actor_id
)
insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id)
select '47000000-0000-4000-8000-000000000032', c2.id, 1, c2.knowledge_type, c2.subject_drug_id,
       'Testpåstand for 470, formulert av claim-verifikatoren selv.',
       'Gjelder bare som testdata i 470.', 'none', 'Testusikkerhet.', c2.created_by_actor_id
from c2;

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values
  ('47000000-0000-4000-8000-000000000041', '47000000-0000-4000-8000-000000000031',
   '47000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Første lenke i 470.', (select id from fixture where name = 'synthesis')),
  ('47000000-0000-4000-8000-000000000042', '47000000-0000-4000-8000-000000000031',
   '47000000-0000-4000-8000-000000000012', 'contradicts', 'direct',
   'Andre lenke i 470, med motstridende stance.', (select id from fixture where name = 'synthesis')),
  ('47000000-0000-4000-8000-000000000043', '47000000-0000-4000-8000-000000000032',
   '47000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Lenke på revisjonen claim-verifikatoren selv formulerte.',
   (select id from fixture where name = 'claim_verifier'));

create temporary table cred (label text primary key, secret text);
insert into cred
select 'claim', provenance.issue_agent_identity_credential(
  'agent-identity:citation-support-verification-01', 'human:peder-holman'
);
insert into cred
select 'extraction', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman'
);
grant select on cred to anon;

create temporary table run (label text primary key, id uuid);
grant insert, select on run to anon;

-- Kontrollradene den lykkede stien sender inn, bygget her og ikke inne i et
-- anon-kall: anon ser ingenting i knowledge, som er hele poenget med at
-- grunnlaget leses gjennom api.claim_verification_input(...). En reell kjører
-- ville hentet de samme verdiene derfra.
create temporary table cit (label text primary key, payload jsonb not null) on commit drop;
insert into cit (label, payload)
select 'r' || right(l.claim_revision_id::text, 2),
       jsonb_agg(jsonb_build_object(
         'claim_evidence_link_id', l.id,
         'source_access', 'verifiable_representation',
         'source_version_id', e.source_version_id,
         'checked_content_hash', sv.content_hash,
         'relationship_supported', 'not_assessable',
         'finding', 'Relasjonstypen lot seg ikke bedømme deterministisk.'
       ))
from knowledge.claim_evidence_links l
join knowledge.evidence_items e on e.id = l.evidence_item_id
join knowledge.source_versions sv on sv.id = e.source_version_id
where l.claim_revision_id in ('47000000-0000-4000-8000-000000000031',
                              '47000000-0000-4000-8000-000000000032')
group by l.claim_revision_id;
grant select on cit to anon;

-- ===========================================================================
-- Del 3 — Åpne kjøringene, som anon, uten brukerkonto
-- ===========================================================================
set local role anon;
insert into run
select 'claim-open', api.begin_agent_run(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  'citation_support_verification', 'testleverandør', 'testmodell', '2026-09-08',
  'claim-verification/1', 'antidep-evidence/1', '{"mode": "test-470"}'::jsonb
);
insert into run
select 'claim-closed', api.begin_agent_run(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  'citation_support_verification', 'testleverandør', 'testmodell', '2026-09-08',
  'claim-verification/1', 'antidep-evidence/1', '{"mode": "test-470"}'::jsonb
);
insert into run
select 'extraction-open', api.begin_agent_run(
  'agent-identity:extraction-verification-01', (select secret from cred where label = 'extraction'),
  'extraction_verification', 'testleverandør', 'testmodell', '2026-09-08',
  'extraction-verification/1', 'antidep-evidence/1', '{"mode": "test-470"}'::jsonb
);
select api.complete_agent_run(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  (select id from run where label = 'claim-closed'), 'aborted', null,
  'Prøve i 470: lukket med hensikt for å prøve avvisningen av en avsluttet kjøring.'
);
reset role;

-- ===========================================================================
-- Del 4 — Den lykkede stien
-- ===========================================================================
create temporary table result (label text primary key, id uuid);
grant insert, select on result to anon;

set local role anon;
insert into result
select 'ok', api.register_claim_verification(
  p_identity_key := 'agent-identity:citation-support-verification-01',
  p_secret := (select secret from cred where label = 'claim'),
  p_agent_run_id := (select id from run where label = 'claim-open'),
  p_claim_revision_id := '47000000-0000-4000-8000-000000000031',
  p_outcome := 'uncertain',
  p_source_support := 'not_assessable',
  p_population_match := 'ok',
  p_comparator_match := 'ok',
  p_timeframe_match := 'ok',
  p_direction_and_magnitude := 'ok',
  p_qualifiers_complete := 'not_assessable',
  p_contradictory_evidence_represented := 'not_assessable',
  p_citations := (select payload from cit where label = 'r31'),
  p_rationale := 'Prøve i 470: deterministisk kontroll mot det registrerte grunnlaget.',
  p_findings := 'Ordlyden og forbeholdene krever språkforståelse og lot seg ikke bedømme.'
);
reset role;

select results_eq(
  $$
    select cv.claim_revision_id, cv.verified_revision_creator_actor_id, cv.verifier_actor_id,
           cv.outcome::text, cv.source_access::text, cv.agent_run_id, cv.agent_run_role::text,
           cv.verified_evidence_set_digest
             = knowledge.claim_evidence_set_digest(cv.claim_revision_id),
           cv.verified_at <= cv.created_at
    from workflow.claim_verifications cv
    where cv.id = (select id from result where label = 'ok')
  $$,
  $$
    values ('47000000-0000-4000-8000-000000000031'::uuid,
            (select id from fixture where name = 'synthesis'),
            (select id from fixture where name = 'claim_verifier'),
            'uncertain', 'verifiable_representation',
            (select id from run where label = 'claim-open'), 'citation_support_verification',
            true, true)
  $$,
  'raden er attribuert til den autentiserte agentaktøren, bundet til kjøringen, og bærer avtrykket av evidenssettet slik det er nå'
);

select results_eq(
  $$
    select c.claim_evidence_link_id, c.evidence_item_id, c.source_access::text,
           c.source_version_id, c.checked_content_hash, c.relationship_supported::text
    from workflow.claim_verification_citations c
    where c.claim_verification_id = (select id from result where label = 'ok')
    order by c.claim_evidence_link_id::text
  $$,
  $$
    values ('47000000-0000-4000-8000-000000000041'::uuid,
            '47000000-0000-4000-8000-000000000011'::uuid,
            'verifiable_representation',
            '47000000-0000-4000-8000-000000000021'::uuid,
            'sha256:' || repeat('a', 64), 'not_assessable'),
           ('47000000-0000-4000-8000-000000000042'::uuid,
            '47000000-0000-4000-8000-000000000012'::uuid,
            'verifiable_representation',
            '47000000-0000-4000-8000-000000000022'::uuid,
            'sha256:' || repeat('b', 64), 'not_assessable')
  $$,
  'begge evidenslenkene er ført som kontrollert, hver mot sin egen kildeversjon og sitt eget registrerte fingeravtrykk'
);

-- Den utsatte dekningskontrollen kjører ved commit, og da er
-- SECURITY DEFINER-konteksten i skriveveien forlatt: den effektive brukeren er
-- klientrollen som gjorde kallet. Her tvinges den fram i nøyaktig den
-- situasjonen — som `anon`, uten usage på workflow — fordi en transaksjon som
-- avsluttes med `rollback` aldri ville kjørt den (migrasjon 005l).
--
-- Uten SECURITY DEFINER på de to funksjonene feller denne assertionen med
-- «permission denied for schema workflow», som er nøyaktig det den ekte
-- kjøringen mot det hostede prosjektet svarte.
set local role anon;
select lives_ok(
  $$set constraints all immediate$$,
  'den utsatte dekningskontrollen kjører når kalleren er anon, som ved commit'
);
set constraints all deferred;
reset role;

select is(
  (select count(*)::integer from audit.events
   where object_table = 'claim_verifications'
     and object_id = (select id from result where label = 'ok')),
  1,
  'registreringen ga nøyaktig én auditrad'
);
select results_eq(
  $$
    select e.operation::text, e.object_schema, e.actor_id, e.old_revision_or_snapshot,
           e.new_revision_or_snapshot ->> 'outcome'
    from audit.events e
    where e.object_id = (select id from result where label = 'ok')
  $$,
  $$
    values ('claim_verification_registered', 'workflow',
            (select id from fixture where name = 'claim_verifier'), null::jsonb, 'uncertain')
  $$,
  'auditraden peker på kontrollen, attribueres til verifikatoraktøren, har intet old-snapshot, og bærer utfallet'
);

-- ===========================================================================
-- Del 5 — Feil rolle, lukket kjøring og fremmed kjøring
-- ===========================================================================
set local role anon;
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:extraction-verification-01', (select secret from cred where label = 'extraction'),
      (select id from run where label = 'extraction-open'),
      '47000000-0000-4000-8000-000000000031',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      (select payload from cit where label = 'r31'),
      'Prøve i 470: ekstraksjonsverifikatoren forsøker å kontrollere en påstand.',
      'Skal aldri nå fram.'
    )
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'ekstraksjonsverifikatoren kan ikke kontrollere en påstand, selv med en åpen kjøring i sin egen rolle'
);
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-closed'),
      '47000000-0000-4000-8000-000000000031',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      (select payload from cit where label = 'r31'),
      'Prøve i 470: forsøk mot en avsluttet kjøring.', 'Skal aldri nå fram.'
    )
  $$,
  '42501', 'Det finnes ingen åpen agentkjøring med denne identiteten.',
  'en avsluttet kjøring kan ikke brukes til å registrere en claim-verifikasjon'
);
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'extraction-open'),
      '47000000-0000-4000-8000-000000000031',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      (select payload from cit where label = 'r31'),
      'Prøve i 470: forsøk mot en kjøring som tilhører en annen identitet.', 'Skal aldri nå fram.'
    )
  $$,
  '42501', 'Det finnes ingen åpen agentkjøring med denne identiteten.',
  'en kjøring som tilhører en annen agentidentitet kan ikke brukes, selv om den er åpen'
);

-- ===========================================================================
-- Del 6 — Selvverifikasjon, med mandatet i orden
-- ===========================================================================
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-open'),
      '47000000-0000-4000-8000-000000000032',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      (select payload from cit where label = 'r32'),
      'Prøve i 470: verifikatoren forsøker å kontrollere sin egen påstand.', 'Skal aldri nå fram.'
    )
  $$,
  '23514', null,
  'verifikatoren kan ikke kontrollere en påstand den selv formulerte, uansett at mandatet er i orden'
);

-- ===========================================================================
-- Del 7 — Dekningen
-- ===========================================================================
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-open'),
      '47000000-0000-4000-8000-000000000031',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      jsonb_build_array(jsonb_build_object(
        'claim_evidence_link_id', '47000000-0000-4000-8000-000000000041',
        'source_access', 'verifiable_representation',
        'source_version_id', '47000000-0000-4000-8000-000000000021',
        'checked_content_hash', 'sha256:' || repeat('a', 64),
        'relationship_supported', 'not_assessable',
        'finding', 'Prøve i 470: bare den ene lenken kontrollert.')),
      'Prøve i 470: kontrollen dekker bare halve evidenssettet.', 'Skal aldri nå fram.'
    )
  $$,
  '23001', null,
  'en kontroll som hopper over en evidenslenke avvises: den har ikke sett det som kunne felt påstanden'
);
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-open'),
      '47000000-0000-4000-8000-000000000031',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      '[]'::jsonb,
      'Prøve i 470: ingen kontrollerte lenker oppgitt.', 'Skal aldri nå fram.'
    )
  $$,
  '22023', 'Kontrollen oppgir ingen kontrollerte evidenslenker.',
  'en kontroll uten en eneste kontrollert lenke avvises: en kontroll av en påstand er en kontroll mot et grunnlag'
);
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-open'),
      '47000000-0000-4000-8000-000000000031',
      'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
      (select payload from cit where label = 'r31'),
      'Prøve i 470: bekreftelse med uavklarte lenker under seg.'
    )
  $$,
  '23001', null,
  'en bekreftet claim-verifikasjon kan ikke ha uavklarte evidenslenker under seg'
);
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-open'),
      '47000000-0000-4000-8000-000000000031',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      (select payload from cit where label = 'r32'),
      'Prøve i 470: kontrollrad som viser til en annen revisjons lenke.', 'Skal aldri nå fram.'
    )
  $$,
  '22023', null,
  'en kontrollrad kan ikke vise til en evidenslenke fra en annen påstandsrevisjon'
);
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-open'),
      '00000000-0000-4000-8000-0000000000ff',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      '[]'::jsonb,
      'Prøve i 470: revisjonen finnes ikke.', 'Skal aldri nå fram.'
    )
  $$,
  'P0002', null,
  'en påstandsrevisjon som ikke finnes avvises eksplisitt, framfor å feile på en fremmednøkkel lenger nede'
);

-- ===========================================================================
-- Del 8 — Kildegrunnlaget per lenke
-- ===========================================================================
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-open'),
      '47000000-0000-4000-8000-000000000031',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      jsonb_build_array(
        jsonb_build_object(
          'claim_evidence_link_id', '47000000-0000-4000-8000-000000000041',
          'source_access', 'verifiable_representation',
          'source_version_id', '47000000-0000-4000-8000-000000000021',
          'checked_content_hash', 'sha256:' || repeat('c', 64),
          'relationship_supported', 'not_assessable', 'finding', 'Prøve i 470.'),
        jsonb_build_object(
          'claim_evidence_link_id', '47000000-0000-4000-8000-000000000042',
          'source_access', 'verifiable_representation',
          'source_version_id', '47000000-0000-4000-8000-000000000022',
          'checked_content_hash', 'sha256:' || repeat('b', 64),
          'relationship_supported', 'not_assessable', 'finding', 'Prøve i 470.')),
      'Prøve i 470: oppgir et fingeravtrykk kildeversjonen ikke har.', 'Skal aldri nå fram.'
    )
  $$,
  '23503', null,
  'et fingeravtrykk kildeversjonen ikke er registrert med, avvises: kontrollen kan ikke oppgi et den fant på'
);
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-open'),
      '47000000-0000-4000-8000-000000000031',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      jsonb_build_array(
        jsonb_build_object(
          'claim_evidence_link_id', '47000000-0000-4000-8000-000000000041',
          'source_access', 'verifiable_representation',
          'source_version_id', '47000000-0000-4000-8000-000000000022',
          'checked_content_hash', 'sha256:' || repeat('b', 64),
          'relationship_supported', 'not_assessable', 'finding', 'Prøve i 470.'),
        jsonb_build_object(
          'claim_evidence_link_id', '47000000-0000-4000-8000-000000000042',
          'source_access', 'verifiable_representation',
          'source_version_id', '47000000-0000-4000-8000-000000000022',
          'checked_content_hash', 'sha256:' || repeat('b', 64),
          'relationship_supported', 'not_assessable', 'finding', 'Prøve i 470.')),
      'Prøve i 470: kontrollerer lenke A mot lenke B sin kildeversjon.', 'Skal aldri nå fram.'
    )
  $$,
  '23503', null,
  'en kontrollrad kan ikke vise til en kildeversjon evidensfunnet ikke er lest ut av'
);
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-open'),
      '47000000-0000-4000-8000-000000000031',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      jsonb_build_array(
        jsonb_build_object(
          'claim_evidence_link_id', '47000000-0000-4000-8000-000000000041',
          'source_access', 'verifiable_representation',
          'relationship_supported', 'not_assessable', 'finding', 'Prøve i 470.'),
        jsonb_build_object(
          'claim_evidence_link_id', '47000000-0000-4000-8000-000000000042',
          'source_access', 'verifiable_representation',
          'source_version_id', '47000000-0000-4000-8000-000000000022',
          'checked_content_hash', 'sha256:' || repeat('b', 64),
          'relationship_supported', 'not_assessable', 'finding', 'Prøve i 470.')),
      'Prøve i 470: verifiable_representation uten kildeversjon.', 'Skal aldri nå fram.'
    )
  $$,
  '23514', null,
  'verifiable_representation uten en kildeversjon å vise til avvises: da finnes det ikke noe etterprøvbart grunnlag'
);
select throws_ok(
  $$
    select api.register_claim_verification(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-open'),
      '47000000-0000-4000-8000-000000000031',
      'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
      jsonb_build_array(
        jsonb_build_object(
          'claim_evidence_link_id', '47000000-0000-4000-8000-000000000041',
          'source_access', 'derived_summary',
          'source_version_id', '47000000-0000-4000-8000-000000000021',
          'checked_content_hash', 'sha256:' || repeat('a', 64),
          'relationship_supported', 'not_assessable', 'finding', 'Prøve i 470.'),
        jsonb_build_object(
          'claim_evidence_link_id', '47000000-0000-4000-8000-000000000042',
          'source_access', 'verifiable_representation',
          'source_version_id', '47000000-0000-4000-8000-000000000022',
          'checked_content_hash', 'sha256:' || repeat('b', 64),
          'relationship_supported', 'not_assessable', 'finding', 'Prøve i 470.')),
      'Prøve i 470: derived_summary som samtidig oppgir en representasjon.', 'Skal aldri nå fram.'
    )
  $$,
  '23514', null,
  'et avledet sammendrag kan ikke samtidig oppgi kildeversjonens representasjon: det ville vært å si to ting'
);

-- Den samlede kildetilgangen er den svakeste av lenkenes, ikke den sterkeste.
insert into result
select 'weakest', api.register_claim_verification(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  (select id from run where label = 'claim-open'),
  '47000000-0000-4000-8000-000000000031',
  'uncertain', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'not_assessable', 'not_assessable',
  jsonb_build_array(
    jsonb_build_object(
      'claim_evidence_link_id', '47000000-0000-4000-8000-000000000041',
      'source_access', 'original_source',
      'relationship_supported', 'not_assessable', 'finding', 'Prøve i 470: originalkilden lest.'),
    jsonb_build_object(
      'claim_evidence_link_id', '47000000-0000-4000-8000-000000000042',
      'source_access', 'derived_summary',
      'relationship_supported', 'not_assessable', 'finding', 'Prøve i 470: bare et sammendrag.')),
  'Prøve i 470: ulik kildetilgang per lenke.',
  'Den ene lenken er bare kontrollert mot et sammendrag.'
);
reset role;

select is(
  (select cv.source_access::text from workflow.claim_verifications cv
   where cv.id = (select id from result where label = 'weakest')),
  'derived_summary',
  'radens samlede kildetilgang er den svakeste av lenkenes, slik at §11 ikke kan omgås ved å aggregere'
);

-- ===========================================================================
-- Del 9 — Mandatet, og at det ikke kan omgås utenom skriveveien
-- ===========================================================================
select throws_ok(
  $$
    insert into workflow.claim_verifications (
      claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id,
      outcome, source_access, source_support, population_match, comparator_match,
      timeframe_match, direction_and_magnitude, qualifiers_complete,
      contradictory_evidence_represented, findings, rationale, verified_at
    )
    select '47000000-0000-4000-8000-000000000031',
           (select id from fixture where name = 'synthesis'),
           (select id from fixture where name = 'extractor'),
           'uncertain', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'not_assessable',
           'Prøve i 470: ikke konkludert.',
           'Prøve i 470: ekstraksjonsagenten forsøker å kontrollere en påstand direkte.',
           now()
  $$,
  '42501', 'Verifikatoraktøren hadde ikke mandat til å kontrollere denne påstanden mot grunnlaget.',
  'en agent i ekstraksjonsrollen kan ikke registrere en claim-verifikasjon, heller ikke ved å skrive direkte i tabellen'
);

set local role authenticated;
select throws_ok(
  $$
    insert into workflow.claim_verifications (
      claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id,
      outcome, source_access, source_support, population_match, comparator_match,
      timeframe_match, direction_and_magnitude, qualifiers_complete,
      contradictory_evidence_represented, rationale, verified_at
    )
    values (
      '47000000-0000-4000-8000-000000000031'::uuid,
      '00000000-0000-4000-8000-000000000001'::uuid,
      '00000000-0000-4000-8000-000000000002'::uuid,
      'verified', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
      'Prøve i 470: en innlogget bruker forsøker å omgå funksjonen.', now()
    )
  $$,
  '42501', null,
  'en innlogget bruker kan ikke omgå funksjonen ved å skrive direkte i workflow.claim_verifications'
);
select throws_ok(
  $$
    insert into workflow.claim_verification_citations (
      claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
      source_access, relationship_supported, finding
    )
    values (
      '00000000-0000-4000-8000-000000000003'::uuid,
      '47000000-0000-4000-8000-000000000031'::uuid,
      '47000000-0000-4000-8000-000000000041'::uuid,
      '47000000-0000-4000-8000-000000000011'::uuid,
      'original_source', 'ok', null
    )
  $$,
  '42501', null,
  'en innlogget bruker kan heller ikke skrive kontrollrader direkte'
);
reset role;

-- ===========================================================================
-- Del 10 — Aktør og rolle kan ikke forfalskes utenom funksjonen
--
-- Forsøkene bruker revisjonen claim-verifikatoren selv formulerte, slik at
-- selvverifikasjonsregelen ikke er det som slår ut: det er de to sammensatte
-- fremmednøklene fra migrasjon 005j som skal fange forsøket.
-- ===========================================================================
select throws_ok(
  format($$
    insert into workflow.claim_verifications (
      claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id,
      outcome, source_access, source_support, population_match, comparator_match,
      timeframe_match, direction_and_magnitude, qualifiers_complete,
      contradictory_evidence_represented, findings, rationale, verified_at, agent_run_id
    )
    select '47000000-0000-4000-8000-000000000031',
           (select id from fixture where name = 'synthesis'),
           (select id from fixture where name = 'claim_verifier'),
           'uncertain', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'not_assessable',
           'Prøve i 470: ikke konkludert.',
           'Prøve i 470: peker på en kjøring som kjørte i en annen rolle.',
           now(), %L::uuid
  $$, (select id from run where label = 'extraction-open')),
  '23503', null,
  'en claim-verifikasjon kan ikke peke på en agentkjøring som ikke kjørte i rollen citation_support_verification'
);

select finish();

rollback;
