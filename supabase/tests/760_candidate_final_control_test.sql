-- Migrasjon 009d — kandidaten, kildedekningen og den kandidatbundne
-- sluttkontrollen.
--
-- ANTIDEP_CONSTITUTION.md regel 5 sier at bare nøyaktig godkjent kandidat kan
-- publiseres. Filen dekker at den setningen nå betyr noe:
--
--   * kandidaten forsegler et innhold, og avtrykket er innholdet,
--   * byggingen er idempotent, og et endret grunnlag gir en ny kandidat,
--   * sluttkontrollen kan strukturelt ikke vise til et annet innhold,
--   * en kandidat hvis grunnlag er endret, kan ikke sluttkontrolleres, og
--   * kontrollen publiserer ingenting.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23503 = foreign_key_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(23);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('knowledge', 'candidates', 'knowledge.candidates finnes');
select has_table('workflow', 'candidate_final_controls',
                 'workflow.candidate_final_controls finnes');

-- Utkast er tilgangsbegrenset, og sluttkontroll er et menneskes beslutning.
-- Ingen av de fire veiene er derfor åpne for anon.
select is_empty(
  $$
    select f.name
    from (values
      ('api.build_candidate(uuid)'),
      ('api.record_candidate_final_control(uuid,text,text,text)'),
      ('api.candidate_for_control(uuid)'),
      ('api.candidate_control_queue()')
    ) as f(name)
    where has_function_privilege('anon', f.name, 'EXECUTE')
       or has_function_privilege('public', f.name, 'EXECUTE')
       or has_function_privilege('service_role', f.name, 'EXECUTE')
  $$,
  'ingen av kandidatveiene er åpne for anon, service_role eller PUBLIC'
);

-- Sluttkontrollen publiserer fortsatt ingenting. Fra migrasjon 009f finnes
-- publiseringen som en egen, eksplisitt handling med et annet mandat — og
-- `anon` er ikke en av dem som har det: en agentidentitet er anon i Data
-- API-et, og et menneske uten publisher-rolle avvises av gaten.
select is_empty(
  $$
    select f.name
    from (values
      ('api.publish_candidate(uuid,text,text)'),
      ('api.withdraw_claim_publication(uuid,text)'),
      ('api.rollback_claim_publication(uuid,uuid,text,text)')
    ) as f(name)
    where has_function_privilege('anon', f.name, 'EXECUTE')
       or has_function_privilege('public', f.name, 'EXECUTE')
       or has_function_privilege('service_role', f.name, 'EXECUTE')
  $$,
  'publiseringsveien er stengt for anon, service_role og PUBLIC'
);

-- ===========================================================================
-- Del 2 — Fikstur: en revisjon som faktisk er ferdig
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'owner', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'extraction_verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';
insert into fixture (name, id) select 'claim_verifier', id from provenance.actors where actor_key = 'agent:citation-support-verification';
insert into fixture (name, id) select 'assessor', id from provenance.actors where actor_key = 'agent:evidence-assessment';

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('76000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 760',
        'Testforfatter 760', (select id from fixture where name = 'owner'));

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id
)
values ('76000000-0000-4000-8000-000000000021', '76000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/760', 'sha256:' || repeat('a', 64),
        (select id from fixture where name = 'extractor'));

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values ('76000000-0000-4000-8000-000000000011', '76000000-0000-4000-8000-000000000001',
        '76000000-0000-4000-8000-000000000021',
        'randomized_controlled_trial', 'not_reported', 'Prøve i 760.',
        'not_reported', (select id from fixture where name = 'sertralin'), 'none',
        (select id from fixture where name = 'weight'), 'Funn for 760.',
        'not_reported', 'increase', 'not_reported', 'not_reported',
        'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor'));

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
select '76000000-0000-4000-8000-000000000031', c.id, 1, c.knowledge_type, c.subject_drug_id,
       'Sertralin er forbundet med en liten vektøkning ved langtidsbruk.',
       'Gjelder bare som testdata i 760.', 'none', 'increase',
       'Testusikkerhet: grunnlaget er syntetisk.', c.created_by_actor_id
from c;

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('76000000-0000-4000-8000-000000000031', '76000000-0000-4000-8000-000000000011',
        'supports', 'direct', 'Eneste lenke i 760.',
        (select id from fixture where name = 'synthesis'));

-- Den kildeomfattende halvdelen av et globalt fravær kan bare føres opp av en
-- maskinell kontroll med sin egen agentkjøring (migrasjon 005ae). En fikstur
-- som skal ha full dekning, trenger derfor begge leddene — samme grep som i
-- 490_claim_verification_publication_gate_test.sql.
insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '76000000-0000-4000-8000-000000000051', ai.id, ai.actor_id, 'extraction_verification',
       'antidep', 'deterministic-extraction-check', '1.0.0',
       'extraction-verification/deterministic/1', 'antidep-evidence/1',
       '{"mode": "test-760"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at, agent_run_id)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'verified', 'verifiable_representation',
       array['source_wide_absence']::workflow.evidence_check_field[],
       'Prøve i 760: et søk gjennom hele representasjonen fant ingen verdi for de '
       || 'feltene raden fører som fraværende.',
       now() - interval '30 days', '76000000-0000-4000-8000-000000000051'
from knowledge.evidence_items e
where e.id = '76000000-0000-4000-8000-000000000011'
  and 'source_wide_absence' = any (workflow.required_check_fields(e.id));

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'verified', 'original_source',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Prøve i 760: fullstendig kontrollert ekstraksjon.', now()
from knowledge.evidence_items e
where e.id = '76000000-0000-4000-8000-000000000011';

insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '76000000-0000-4000-8000-000000000052', ai.id, ai.actor_id,
       'citation_support_verification', 'antidep', 'deterministic-claim-check', '1.0.0',
       'claim-verification/deterministic/1', 'antidep-evidence/1', '{"mode": "test-760"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:citation-support-verification-01';

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at, agent_run_id)
select r.id, r.created_by_actor_id, (select id from fixture where name = 'claim_verifier'),
       'verified', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Prøve i 760: påstanden dekkes av det registrerte evidensgrunnlaget.', now(),
       '76000000-0000-4000-8000-000000000052'
from knowledge.claim_revisions r
where r.id = '76000000-0000-4000-8000-000000000031';

insert into workflow.claim_verification_citations
  (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
   source_access, source_version_id, checked_content_hash, relationship_supported)
select v.id, v.claim_revision_id, l.id, l.evidence_item_id, 'original_source',
       e.source_version_id, sv.content_hash, 'ok'
from workflow.claim_verifications v
join knowledge.claim_evidence_links l on l.claim_revision_id = v.claim_revision_id
join knowledge.evidence_items e on e.id = l.evidence_item_id
join knowledge.source_versions sv on sv.id = e.source_version_id
where v.claim_revision_id = '76000000-0000-4000-8000-000000000031';

insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '76000000-0000-4000-8000-000000000053', ai.id, ai.actor_id, 'evidence_assessment',
       'antidep', 'proposal-registered-assessment', '1.0.0',
       'evidence-assessment/proposal/1', 'antidep-evidence/1', '{"mode": "test-760"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:evidence-assessment-01';

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, evidence_gap, assessed_at, created_by_actor_id, agent_run_id)
select r.id, r.knowledge_type, 'grade', 'low', 'serious', 'not_assessable',
       'not_serious', 'serious', 'not_assessable',
       'Prøve i 760: vurdering med alle nødvendige domener.',
       'Syntetisk grunnlag har med vilje begrenset dekning.', now(),
       (select id from fixture where name = 'assessor'), '76000000-0000-4000-8000-000000000053'
from knowledge.claim_revisions r
where r.id = '76000000-0000-4000-8000-000000000031';

-- Redaktøren som bygger, og fagpersonen som sluttkontrollerer. To forskjellige
-- mandater, og med vilje to forskjellige mennesker.
insert into auth.users (id, email) values
  ('76000000-0000-4000-8000-00000000000e', 'redaktor-760@test.invalid'),
  ('76000000-0000-4000-8000-00000000000c', 'fagperson-760@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac760000-0000-4000-8000-00000000000e', 'human', 'human:redaktor-760', 'Redaktør 760',
   'Aktør med editor-tildeling, for 760.', '76000000-0000-4000-8000-00000000000e'),
  ('ac760000-0000-4000-8000-00000000000c', 'human', 'human:fagperson-760', 'Fagperson 760',
   'Aktør med reviewer-tildeling for vektendring, for 760.',
   '76000000-0000-4000-8000-00000000000c');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('76000000-0000-4000-8000-00000000000e', 'editor', null, now() - interval '1 year',
   (select id from fixture where name = 'owner'), 'Gyldig editor-tildeling for 760.'),
  ('76000000-0000-4000-8000-00000000000c', 'reviewer',
   (select id from fixture where name = 'weight'), now() - interval '1 year',
   (select id from fixture where name = 'owner'), 'Gyldig reviewer-tildeling for 760.');

create temporary table built (label text primary key, payload jsonb not null) on commit drop;
grant select, insert on built to authenticated;

-- ===========================================================================
-- Del 3 — Byggingen
-- ===========================================================================
-- Fra migrasjon 012b forsegles kandidaten allerede av den registrerte
-- evidensvurderingen: kjeden går helt fram til den ene handlingen som skal være
-- et menneskes, og stopper der. Redaktørens egen bygging er derfor idempotent
-- begge ganger — den finner kandidaten kjeden alt har forseglet, og bygger den
-- ikke om igjen.
select is(
  (select count(*)::integer from knowledge.candidates c
   where c.claim_revision_id = '76000000-0000-4000-8000-000000000031'),
  1,
  'den registrerte evidensvurderingen forseglet kandidaten uten at noen ba om det'
);

select set_config('request.jwt.claims',
                  '{"sub":"76000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
insert into built select 'first', api.build_candidate('76000000-0000-4000-8000-000000000031');
insert into built select 'again', api.build_candidate('76000000-0000-4000-8000-000000000031');
reset role;

select is(
  (select (payload ->> 'built')::boolean from built where label = 'first'),
  false,
  'redaktørens bygging finner kandidaten kjeden alt har forseglet'
);
select is(
  (select (payload ->> 'built')::boolean from built where label = 'again'),
  false,
  'en gjentatt bygging av uendret innhold skriver ingen ny rad'
);
select is(
  (select payload ->> 'candidate_id' from built where label = 'first'),
  (select payload ->> 'candidate_id' from built where label = 'again'),
  'gjentakelsen finner den samme kandidaten'
);

-- Avtrykket er innholdet. En rad kan ikke bære et annet.
select is(
  (select c.candidate_digest from knowledge.candidates c
   where c.id = (select (payload ->> 'candidate_id')::uuid from built where label = 'first')),
  (select knowledge.source_version_content_hash(c.content::text) from knowledge.candidates c
   where c.id = (select (payload ->> 'candidate_id')::uuid from built where label = 'first')),
  'kandidatens avtrykk er avtrykket av dens eget innhold'
);

-- Kildedekningen ligger *inne i* det forseglede innholdet. Lå den utenfor,
-- kunne den endret seg etter godkjenningen uten at avtrykket merket det.
select is(
  (select jsonb_array_length(c.content -> 'source_coverage') from knowledge.candidates c
   where c.id = (select (payload ->> 'candidate_id')::uuid from built where label = 'first')),
  1,
  'kildedekningen er en del av det forseglede innholdet'
);
select is(
  (select c.content -> 'evidence' -> 0 -> 'coverage' ->> 'grounding_machine_proved'
   from knowledge.candidates c
   where c.id = (select (payload ->> 'candidate_id')::uuid from built where label = 'first')),
  'false',
  'dekningen sier hva maskinbeviset faktisk gir, også når svaret er nei'
);
select is(
  (select c.content -> 'evidence_assessment' ->> 'certainty_level' from knowledge.candidates c
   where c.id = (select (payload ->> 'candidate_id')::uuid from built where label = 'first')),
  'low',
  'evidensvurderingen er med i kandidaten'
);

-- ===========================================================================
-- Del 4 — Leseflaten er tilgangsbegrenset
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"76000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select throws_ok(
  format($$select api.candidate_for_control(%L)$$,
         (select payload ->> 'candidate_id' from built where label = 'first')),
  '42501', 'Kandidatinnhold er tilgangsbegrenset.',
  'en redaktør uten reviewer-mandat kan ikke lese kandidatinnholdet'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"76000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
insert into built select 'view', api.candidate_for_control(
  (select (payload ->> 'candidate_id')::uuid from built where label = 'first'));
insert into built select 'queue', jsonb_build_object('rows', api.candidate_control_queue());
reset role;

select is(
  (select (payload ->> 'is_current')::boolean from built where label = 'view'),
  true,
  'leseflaten sier at kandidaten fortsatt er gjeldende'
);
select is(
  (select (payload ->> 'published')::boolean from built where label = 'view'),
  false,
  'leseflaten sier eksplisitt at innholdet ikke er publisert'
);
select ok(
  (select jsonb_array_length(payload -> 'rows') from built where label = 'queue') >= 1,
  'kandidaten står i køen til den som har mandat'
);

-- ===========================================================================
-- Del 5 — Sluttkontrollen er bundet til nøyaktig denne kandidaten
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"76000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;

select throws_ok(
  format(
    $$select api.record_candidate_final_control(%L, %L, 'approved', 'Prøve i 760.')$$,
    (select payload ->> 'candidate_id' from built where label = 'first'),
    'sha256:' || repeat('9', 64)
  ),
  '23001', 'Sluttkontrollen viser til et annet kandidatavtrykk enn kandidatens eget.',
  'en godkjenning avgitt mot et annet avtrykk avvises'
);

insert into built select 'control', api.record_candidate_final_control(
  (select (payload ->> 'candidate_id')::uuid from built where label = 'first'),
  (select payload ->> 'candidate_digest' from built where label = 'first'),
  'approved',
  'Prøve i 760: innholdet er lest i klinikerens egen visning og holder mål.');
reset role;

select is(
  (select payload ->> 'decision' from built where label = 'control'),
  'approved',
  'sluttkontrollen registreres'
);
select is(
  (select (payload ->> 'published')::boolean from built where label = 'control'),
  false,
  'en godkjenning publiserer ingenting, og sier det selv'
);
select is(
  (select count(*)::int from knowledge.publication_events),
  0,
  'ingen publiseringshendelse er skrevet'
);

-- Bindingen er strukturell: fremmednøkkelen lar ingen rad vise til et annet
-- innhold enn det som faktisk ble lest.
select throws_ok(
  format(
    $$insert into workflow.candidate_final_controls
        (candidate_id, candidate_digest, decision, rationale, reviewer_actor_id,
         reviewer_actor_type)
      values (%L, %L, 'approved', 'Prøve i 760: forfalsket avtrykk.',
              'ac760000-0000-4000-8000-00000000000c', 'human')$$,
    (select payload ->> 'candidate_id' from built where label = 'first'),
    'sha256:' || repeat('8', 64)
  ),
  '23503', null,
  'en sluttkontrollrad kan ikke vise til et avtrykk kandidaten ikke har'
);

-- ===========================================================================
-- Del 6 — Et endret grunnlag gjør kandidaten ugjeldende
-- ===========================================================================
insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values ('76000000-0000-4000-8000-000000000012', '76000000-0000-4000-8000-000000000001',
        '76000000-0000-4000-8000-000000000021',
        'randomized_controlled_trial', 'not_reported', 'Prøve i 760, andre funn.',
        'not_reported', (select id from fixture where name = 'sertralin'), 'none',
        (select id from fixture where name = 'weight'), 'Andre funn for 760.',
        'not_reported', 'increase', 'not_reported', 'not_reported',
        'Avsnitt 2', 'ai_assisted', (select id from fixture where name = 'extractor'));

-- Evidenslenker kan ikke legges til etter at en vurdering finnes (migrasjon
-- 005ai), så det som endrer grunnlaget her, er den nye kontrollen på funnet
-- kandidaten allerede bygger på: en senere, ikke-bekreftende kontroll.
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, findings, verified_at)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'needs_correction', 'original_source',
       array['estimate']::workflow.evidence_check_field[],
       'Prøve i 760: et senere avvik på det samme funnet.',
       'Estimatet i raden stemmer ikke med tabellen i kilden.', now()
from knowledge.evidence_items e
where e.id = '76000000-0000-4000-8000-000000000011';

select set_config('request.jwt.claims',
                  '{"sub":"76000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
insert into built select 'view_after', api.candidate_for_control(
  (select (payload ->> 'candidate_id')::uuid from built where label = 'first'));

select throws_ok(
  format(
    $$select api.record_candidate_final_control(%L, %L, 'approved', 'Prøve i 760, etter endring.')$$,
    (select payload ->> 'candidate_id' from built where label = 'first'),
    (select payload ->> 'candidate_digest' from built where label = 'first')
  ),
  '23001', 'Grunnlaget kandidaten ble forseglet av, er endret siden den ble bygget.',
  'en kandidat hvis grunnlag er endret, kan ikke sluttkontrolleres'
);
reset role;

select is(
  (select (payload ->> 'is_current')::boolean from built where label = 'view_after'),
  false,
  'leseflaten viser at kandidaten ikke lenger er gjeldende'
);

select * from finish();
rollback;
