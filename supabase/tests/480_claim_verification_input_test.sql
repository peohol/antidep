-- Migrasjon 005k — lesegrunnlaget claim-verifikatoren arbeider fra.
--
-- Samme mønster som 460_extraction_verification_input_test.sql: kontrakten,
-- de tre samtidige kravene før noe gis ut, hva arbeidskøen inneholder og ikke
-- inneholder, og formen på svaret.
--
-- Det som er nytt her, og som er selve grunnen til at funksjonen finnes, er de
-- to siste delene: at grunnlaget bærer den gjeldende ekstraksjonsverifikasjonen
-- for hvert funn, og at det bærer registrert evidens for samme virkestoff og
-- endepunkt som *ikke* er lenket til revisjonen. Uten den siste er
-- DATABASE_ARCHITECTURE.md §30 sitt spørsmål om urepresentert motstridende
-- evidens ubesvarbart av konstruksjon.
--
-- SQLSTATE 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(23);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'claim_verification_input', 'api.claim_verification_input() finnes'
);
select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.claim_verification_input(text,text,uuid,uuid)'::regprocedure),
  'api.claim_verification_input() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
select is_empty(
  $$
    select r.role_name
    from (values ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name, 'api.claim_verification_input(text,text,uuid,uuid)'::regprocedure, 'execute')
  $$,
  'api.claim_verification_input() er kjørbar for verken service_role eller PUBLIC'
);
select ok(
  has_function_privilege(
    'anon', 'api.claim_verification_input(text,text,uuid,uuid)'::regprocedure, 'execute'),
  'anon har EXECUTE — en agent har ingen brukerkonto og kaller som anon'
);
select ok(
  has_function_privilege(
    'authenticated', 'api.claim_verification_input(text,text,uuid,uuid)'::regprocedure, 'execute'),
  'authenticated har EXECUTE, av samme grunn'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
--   R1  formulert av synteseagenten, lenket til ett funn. I køen.
--   R2  formulert av claim-verifikatoren selv. Aldri i køen.
--   R3  formulert av synteseagenten, uten en eneste evidenslenke. Aldri i køen,
--       fordi en kontroll av en påstand er en kontroll mot et grunnlag.
--
-- Et fjerde evidensfunn er registrert på samme virkestoff og endepunkt som R1,
-- men ikke lenket til den. Det er kandidaten for urepresentert evidens.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'mirtazapin', id from catalog.drugs where canonical_name = 'mirtazapin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'claim_verifier', id from provenance.actors where actor_key = 'agent:citation-support-verification';
insert into fixture (name, id) select 'extraction_verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('48000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 480',
        'Testforfatter 480', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id
)
values ('48000000-0000-4000-8000-000000000021', '48000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/480-a', 'sha256:' || repeat('a', 64),
        (select id from fixture where name = 'extractor'));

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, effect_measure, estimate, estimate_unit, estimate_availability,
  confidence_interval_availability, source_locator, extraction_method,
  raw_extraction, created_by_actor_id
)
values
  ('48000000-0000-4000-8000-000000000011', '48000000-0000-4000-8000-000000000001',
   '48000000-0000-4000-8000-000000000021',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 480.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Lenket funn, for 480.',
   'not_reported', 'increase', 'mean_change', 1.50, 'kg', 'reported_value', 'not_reported',
   'Avsnitt 1', 'ai_assisted',
   '{"resultat": "Sertraline-treated patients had a mean weight change of 1.5 kg."}'::jsonb,
   (select id from fixture where name = 'extractor')),
  ('48000000-0000-4000-8000-000000000012', '48000000-0000-4000-8000-000000000001',
   '48000000-0000-4000-8000-000000000021',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 480.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Ulenket funn på samme virkestoff og endepunkt.',
   'not_reported', 'decrease', null, null, null, 'not_reported', 'not_reported',
   'Avsnitt 2', 'ai_assisted', '{}'::jsonb,
   (select id from fixture where name = 'extractor'));

-- To ekstraksjonsverifikasjoner på det lenkede funnet: den siste er den
-- gjeldende, med samme rekkefølge publiseringsgatens G5 bruker.
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, findings, rationale, verified_at)
values
  ('48000000-0000-4000-8000-000000000011', (select id from fixture where name = 'extractor'),
   (select id from fixture where name = 'extraction_verifier'), 'verified',
   'verifiable_representation',
   array['raw_extraction', 'source_locator']::workflow.evidence_check_field[],
   null, 'Prøve i 480: første kontroll.', now() - interval '2 days'),
  ('48000000-0000-4000-8000-000000000011', (select id from fixture where name = 'extractor'),
   (select id from fixture where name = 'extraction_verifier'), 'uncertain',
   'verifiable_representation',
   array['raw_extraction', 'source_locator']::workflow.evidence_check_field[],
   'Prøve i 480: tallet lot seg ikke gjenfinne.', 'Prøve i 480: andre kontroll.',
   now() - interval '1 day');

create function pg_temp.new_revision(
  p_id uuid, p_drug text, p_author text, p_statement text
) returns void language plpgsql as $$
declare
  v_claim uuid;
begin
  insert into knowledge.claims (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis',
         (select id from catalog.clinical_concepts where canonical_label = 'vektendring'),
         (select id from catalog.drugs where canonical_name = p_drug),
         (select id from provenance.actors where actor_key = p_author)
  returning id into v_claim;

  insert into knowledge.claim_revisions
    (id, claim_id, revision_number, knowledge_type, subject_drug_id,
     statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
  select p_id, v_claim, 1, cl.knowledge_type, cl.subject_drug_id,
         p_statement, 'Gjelder bare som testdata i 480.', 'none', 'increase',
         'Testusikkerhet.', cl.created_by_actor_id
  from knowledge.claims cl where cl.id = v_claim;
end;
$$;

select pg_temp.new_revision('48000000-0000-4000-8000-000000000031', 'sertralin',
  'agent:claim-synthesis', 'Testpåstand i køen, formulert av synteseagenten.');
select pg_temp.new_revision('48000000-0000-4000-8000-000000000032', 'mirtazapin',
  'agent:citation-support-verification', 'Testpåstand formulert av claim-verifikatoren selv.');
select pg_temp.new_revision('48000000-0000-4000-8000-000000000033', 'sertralin',
  'agent:claim-synthesis', 'Testpåstand uten en eneste evidenslenke.');

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values
  ('48000000-0000-4000-8000-000000000041', '48000000-0000-4000-8000-000000000031',
   '48000000-0000-4000-8000-000000000011', 'partially_supports', 'direct',
   'Funnet underbygger retningen, men ikke størrelsen.',
   (select id from fixture where name = 'synthesis')),
  ('48000000-0000-4000-8000-000000000042', '48000000-0000-4000-8000-000000000032',
   '48000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Lenke på revisjonen claim-verifikatoren selv formulerte.',
   (select id from fixture where name = 'claim_verifier'));

create temporary table cred (label text primary key, secret text);
insert into cred select 'claim', provenance.issue_agent_identity_credential(
  'agent-identity:citation-support-verification-01', 'human:peder-holman');
insert into cred select 'extraction', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman');
grant select on cred to anon;

create temporary table run (label text primary key, id uuid);
grant insert, select on run to anon;
create temporary table answer (label text primary key, payload jsonb);
grant insert, select on answer to anon;

set local role anon;
insert into run select 'claim-open', api.begin_agent_run(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  'citation_support_verification', 'testleverandør', 'testmodell', '2026-09-08',
  'claim-verification/1', 'antidep-evidence/1', '{"mode": "test-480"}'::jsonb);
insert into run select 'claim-closed', api.begin_agent_run(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  'citation_support_verification', 'testleverandør', 'testmodell', '2026-09-08',
  'claim-verification/1', 'antidep-evidence/1', '{"mode": "test-480"}'::jsonb);
insert into run select 'extraction-open', api.begin_agent_run(
  'agent-identity:extraction-verification-01', (select secret from cred where label = 'extraction'),
  'extraction_verification', 'testleverandør', 'testmodell', '2026-09-08',
  'extraction-verification/1', 'antidep-evidence/1', '{"mode": "test-480"}'::jsonb);
select api.complete_agent_run(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  (select id from run where label = 'claim-closed'), 'aborted', null,
  'Prøve i 480: lukket med hensikt.');

-- ===========================================================================
-- Del 3 — De tre samtidige kravene
-- ===========================================================================
select throws_ok(
  $$
    select api.claim_verification_input(
      'agent-identity:extraction-verification-01', (select secret from cred where label = 'extraction'),
      (select id from run where label = 'extraction-open'))
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'ekstraksjonsverifikatoren får ikke se claim-verifikatorens grunnlag'
);
select throws_ok(
  $$
    select api.claim_verification_input(
      'agent-identity:citation-support-verification-01', 'feil hemmelighet',
      (select id from run where label = 'claim-open'))
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'feil legitimasjon gir samme anonyme avvisning som enhver mislykket agentautentisering'
);
select throws_ok(
  $$
    select api.claim_verification_input(
      'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
      (select id from run where label = 'claim-closed'))
  $$,
  '42501', 'Det finnes ingen åpen agentkjøring med denne identiteten.',
  'en avsluttet kjøring gir ingenting: proveniensen for hva verifikatoren fikk se er like sporbar som skrivingen'
);

insert into answer
select 'queue', api.claim_verification_input(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  (select id from run where label = 'claim-open'));
insert into answer
select 'single', api.claim_verification_input(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  (select id from run where label = 'claim-open'),
  '48000000-0000-4000-8000-000000000032');
reset role;

-- ===========================================================================
-- Del 4 — Hva køen inneholder, og hva den ikke inneholder
-- ===========================================================================
select is(
  (select payload ->> 'verifier_actor_id' from answer where label = 'queue'),
  (select id::text from fixture where name = 'claim_verifier'),
  'aktøren i svaret er kjøringens egen, ikke noe kalleren kunne bedt om'
);
select ok(
  (select payload -> 'revisions' @> jsonb_build_array(
     jsonb_build_object('claim_revision_id', '48000000-0000-4000-8000-000000000031'))
   from answer where label = 'queue'),
  'en revisjon aktøren ikke har formulert og som har evidenslenker, står i køen'
);
select ok(
  not (select payload -> 'revisions' @> jsonb_build_array(
         jsonb_build_object('claim_revision_id', '48000000-0000-4000-8000-000000000032'))
       from answer where label = 'queue'),
  'en revisjon aktøren selv formulerte står aldri i køen: den kan aldri kontrolleres av den'
);
select ok(
  not (select payload -> 'revisions' @> jsonb_build_array(
         jsonb_build_object('claim_revision_id', '48000000-0000-4000-8000-000000000033'))
       from answer where label = 'queue'),
  'en revisjon uten en eneste evidenslenke står ikke i køen: køen skal ikke inneholde arbeid som må avvises'
);
select is(
  (select jsonb_array_length(payload -> 'revisions') from answer where label = 'single'),
  1,
  'et direkte oppslag svarer om nøyaktig den revisjonen, også en aktøren selv formulerte'
);

-- ===========================================================================
-- Del 5 — Formen på svaret
-- ===========================================================================
create temporary table rev as
select r as payload
from answer a
cross join lateral jsonb_array_elements(a.payload -> 'revisions') as r
where a.label = 'queue'
  and r ->> 'claim_revision_id' = '48000000-0000-4000-8000-000000000031';

select is(
  (select count(*)::integer from rev), 1,
  'revisjonen fra køen lar seg plukke ut entydig'
);
select is(
  (select payload -> 'claim' ->> 'statement' from rev),
  'Testpåstand i køen, formulert av synteseagenten.',
  'påstanden gis i sin helhet, ikke som et sammendrag'
);
select is(
  (select payload ->> 'evidence_set_digest' from rev),
  knowledge.claim_evidence_set_digest('48000000-0000-4000-8000-000000000031'),
  'avtrykket av evidenssettet er med, slik at kjøreren kan se hvilket grunnlag kontrollen gjelder'
);
select is(
  (select jsonb_typeof(payload -> 'links' -> 0 -> 'evidence_item' -> 'extraction' -> 'estimate')
   from rev),
  'string',
  'kliniske tallverdier kommer som tekst, slik at de ikke avrundes av JSON-lesingen før kontrollen ser dem'
);
select is(
  (select payload -> 'links' -> 0 -> 'evidence_item' -> 'extraction' ->> 'estimate' from rev),
  '1.50',
  'estimatet gjengis nøyaktig som det er lagret, med sin egen presisjon'
);
select is(
  (select payload -> 'links' -> 0 ->> 'relationship_type' from rev),
  'partially_supports',
  'lenkens registrerte relasjonstype er med: det er den kontrollen skal bedømme (EVIDENCE_PIPELINE.md §40)'
);
select is(
  (select payload -> 'links' -> 0 -> 'evidence_item' -> 'source_version' ->> 'content_hash' from rev),
  'sha256:' || repeat('a', 64),
  'kildeversjonens fingeravtrykk er med, slik at representasjonen kan hentes på nytt og etterprøves'
);
select is(
  (select payload -> 'links' -> 0 -> 'current_extraction_verification' ->> 'outcome' from rev),
  'uncertain',
  'den gjeldende ekstraksjonsverifikasjonen er den siste, ikke den første: en eldre bekreftelse skjuler ikke et senere avvik'
);

-- ===========================================================================
-- Del 6 — Urepresentert evidens
-- ===========================================================================
select ok(
  (select payload -> 'unlinked_related_evidence' @> jsonb_build_array(
     jsonb_build_object('evidence_item_id', '48000000-0000-4000-8000-000000000012'))
   from rev),
  'et registrert funn på samme virkestoff og endepunkt som ikke er lenket, står oppført som kandidat (DATABASE_ARCHITECTURE.md §30)'
);
select ok(
  not (select payload -> 'unlinked_related_evidence' @> jsonb_build_array(
         jsonb_build_object('evidence_item_id', '48000000-0000-4000-8000-000000000011'))
       from rev),
  'funnet som *er* lenket står ikke i den listen'
);

select finish();

rollback;
