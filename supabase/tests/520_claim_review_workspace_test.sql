-- Migrasjon 005m og 005o — reviewarbeidsflaten.
--
-- Dekker fire ting:
--
--   * kontrakten: hva som er eksponert, og for hvem
--   * autorisasjonen: hvem som får se noe i det hele tatt, og hvor langt
--   * køen: hvilke revisjoner som er arbeid, og hvilke som ikke er det
--   * arbeidsflaten: at grunnlaget er fullstendig, at beslutningshistorikken er
--     hel, og at blokkeringen kommer fra publiseringsgaten selv
--
-- Den viktigste assertionen i filen er den siste i Del 5: at grunnlaget
-- mennesket ser, er nøyaktig det grunnlaget claim-verifikatoren leser. To
-- formuleringer av evidensgrunnlaget ville før eller siden latt mennesket og
-- maskinen kontrollere påstanden mot hvert sitt bilde av evidensen.
--
-- SQLSTATE 42501 = insufficient_privilege, P0002 = no_data_found.
begin;

create extension if not exists pgtap with schema extensions;

select plan(32);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function('api', 'claim_review_workspace', 'api.claim_review_workspace() finnes');
select has_function(
  'workflow', 'claim_evidence_dossier', 'workflow.claim_evidence_dossier() finnes'
);
select has_function(
  'workflow', 'claim_review_history', 'workflow.claim_review_history() finnes'
);
select has_function(
  'workflow', 'caller_is_active_reviewer', 'workflow.caller_is_active_reviewer() finnes'
);
select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.claim_review_workspace(uuid)'::regprocedure),
  'api.claim_review_workspace() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name, 'api.claim_review_workspace(uuid)'::regprocedure, 'execute'
    )
  $$,
  'api.claim_review_workspace() er kjørbar bare for authenticated'
);
select is_empty(
  $$
    select f.signature, r.role_name
    from (values
      ('workflow.claim_evidence_dossier(uuid)'),
      ('workflow.claim_review_history(uuid)')
    ) as f(signature)
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    where has_function_privilege(r.role_name, f.signature::regprocedure, 'execute')
  $$,
  'lesegrunnlaget og historikken er ikke kjørbare for noen klientrolle: veien inn går gjennom api-funksjonen som autoriserer først'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- Fire påstandsrevisjoner, hver med sin grunn til å være der:
--
--   R1  formulert av agent:claim-synthesis, to lenker, evidensvurdering.
--       Arbeidsflaten og hele kjeden.
--   R2  formulert av reviewer H selv. Skal ikke stå i køen.
--   R3  formulert av agent:claim-synthesis, uten evidenslenker. Skal ikke stå
--       i køen: det finnes ikke noe å kontrollere mot.
--   R4  formulert av agent:claim-synthesis, med lenke, men påstanden er
--       trukket tilbake. Skal ikke stå i køen.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id) select 'extraction_verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';

insert into catalog.clinical_concepts (id, canonical_label, concept_type)
values ('52000000-0000-4000-8000-0000000000f0', 'søvnkvalitet for 520', 'outcome');

insert into auth.users (id, instance_id, aud, role, email)
select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u.email
from (values
  ('52000000-0000-4000-8000-0000000000a0'::uuid, 'a520@example.test'),
  ('52000000-0000-4000-8000-0000000000d0'::uuid, 'd520@example.test'),
  ('52000000-0000-4000-8000-0000000000e0'::uuid, 'e520@example.test'),
  ('52000000-0000-4000-8000-000000000080'::uuid, 'h520@example.test')
) as u(id, email);

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values
  ('52000000-0000-4000-8000-0000000000d1', 'human:d-520', 'human', 'Kaller D 520',
   'Editor uten reviewer-rolle, for 520.', '52000000-0000-4000-8000-0000000000d0'),
  ('52000000-0000-4000-8000-0000000000e1', 'human:e-520', 'human', 'Kaller E 520',
   'Avgrenset reviewer for et annet tema, for 520.', '52000000-0000-4000-8000-0000000000e0'),
  ('52000000-0000-4000-8000-000000000081', 'human:h-520', 'human', 'Kaller H 520',
   'Uavgrenset reviewer, for 520.', '52000000-0000-4000-8000-000000000080');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('52000000-0000-4000-8000-0000000000d0', 'editor', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Tildeling for kaller D i 520.'),
  ('52000000-0000-4000-8000-0000000000e0', 'reviewer', '52000000-0000-4000-8000-0000000000f0',
   now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Tildeling for kaller E i 520.'),
  ('52000000-0000-4000-8000-000000000080', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Tildeling for kaller H i 520.');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('52000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 520',
        'Testforfatter 520', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
values
  ('52000000-0000-4000-8000-000000000021', '52000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/520-a', 'sha256:' || repeat('a', 64),
   (select id from fixture where name = 'extractor')),
  ('52000000-0000-4000-8000-000000000022', '52000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/520-b', 'sha256:' || repeat('b', 64),
   (select id from fixture where name = 'extractor'));

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
values
  ('52000000-0000-4000-8000-000000000011', '52000000-0000-4000-8000-000000000001',
   '52000000-0000-4000-8000-000000000021',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 520.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Første funn, for 520.',
   'not_reported', 'increase', 'not_reported', 'not_reported',
   'Avsnitt 1', 'ai_assisted', (select id from fixture where name = 'extractor')),
  ('52000000-0000-4000-8000-000000000012', '52000000-0000-4000-8000-000000000001',
   '52000000-0000-4000-8000-000000000022',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 520.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Andre funn, for 520.',
   'not_reported', 'increase', 'not_reported', 'not_reported',
   'Avsnitt 2', 'ai_assisted', (select id from fixture where name = 'extractor')),
  -- Registrert evidens på samme virkestoff og endepunkt, ikke lenket til noen
  -- revisjon: kandidaten for urepresentert evidens (DATABASE_ARCHITECTURE.md §30).
  ('52000000-0000-4000-8000-000000000013', '52000000-0000-4000-8000-000000000001',
   '52000000-0000-4000-8000-000000000021',
   'randomized_controlled_trial', 'not_reported', 'Prøve i 520.',
   'not_reported', (select id from fixture where name = 'sertralin'), 'none',
   (select id from fixture where name = 'weight'), 'Ulenket funn, for 520.',
   'not_reported', 'decrease', 'not_reported', 'not_reported',
   'Avsnitt 3', 'ai_assisted', (select id from fixture where name = 'extractor'));

create function pg_temp.make_revision(p_revision_id uuid, p_author uuid, p_statement text)
  returns uuid language plpgsql as $$
declare v_claim_id uuid;
begin
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis',
         (select id from fixture where name = 'weight'),
         (select id from fixture where name = 'sertralin'),
         p_author
  returning id into v_claim_id;

  insert into knowledge.claim_revisions
    (id, claim_id, revision_number, knowledge_type, subject_drug_id,
     statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
  select p_revision_id, v_claim_id, 1, c.knowledge_type, c.subject_drug_id,
         p_statement, 'Gjelder bare som testdata i 520.', 'none', 'increase',
         'Testusikkerhet.', c.created_by_actor_id
  from knowledge.claims c where c.id = v_claim_id;

  return v_claim_id;
end;
$$;

select pg_temp.make_revision('52000000-0000-4000-8000-000000000031',
  (select id from fixture where name = 'synthesis'), 'Testpåstand R1 for 520.');
select pg_temp.make_revision('52000000-0000-4000-8000-000000000032',
  '52000000-0000-4000-8000-000000000081', 'Testpåstand R2 for 520, formulert av reviewer H.');
select pg_temp.make_revision('52000000-0000-4000-8000-000000000033',
  (select id from fixture where name = 'synthesis'), 'Testpåstand R3 for 520, uten evidens.');
create temporary table retired_claim (id uuid) on commit drop;
insert into retired_claim select pg_temp.make_revision('52000000-0000-4000-8000-000000000034',
  (select id from fixture where name = 'synthesis'), 'Testpåstand R4 for 520, tilbaketrukket.');

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values
  ('52000000-0000-4000-8000-000000000041', '52000000-0000-4000-8000-000000000031',
   '52000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Første lenke på R1 i 520.', (select id from fixture where name = 'synthesis')),
  ('52000000-0000-4000-8000-000000000042', '52000000-0000-4000-8000-000000000031',
   '52000000-0000-4000-8000-000000000012', 'contradicts', 'direct',
   'Andre lenke på R1 i 520, motstridende.', (select id from fixture where name = 'synthesis')),
  ('52000000-0000-4000-8000-000000000043', '52000000-0000-4000-8000-000000000032',
   '52000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Lenke på R2 i 520.', '52000000-0000-4000-8000-000000000081'),
  ('52000000-0000-4000-8000-000000000044', '52000000-0000-4000-8000-000000000034',
   '52000000-0000-4000-8000-000000000011', 'supports', 'direct',
   'Lenke på R4 i 520.', (select id from fixture where name = 'synthesis'));

update knowledge.claims
set retired_at = now(), retirement_note = 'Tilbaketrukket for testene i 520.'
where id = (select id from retired_claim);

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'verified', 'original_source', workflow.required_check_fields(e.id),
       'Prøve i 520: fullstendig kontrollert ekstraksjon.', now()
from knowledge.evidence_items e
where e.id in ('52000000-0000-4000-8000-000000000011', '52000000-0000-4000-8000-000000000012');

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
values ('52000000-0000-4000-8000-000000000031', 'evidence_synthesis', 'grade', 'low',
        'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
        'Prøve i 520: lav sikkerhet.', now(),
        (select id from fixture where name = 'synthesis'));

-- ===========================================================================
-- Del 3 — Autorisasjon
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"52000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select throws_ok(
  $$select api.claim_review_workspace()$$,
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en kaller uten aktørrad ser ingenting av reviewflaten'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"52000000-0000-4000-8000-0000000000d0"}', true);
set local role authenticated;
select throws_ok(
  $$select api.claim_review_workspace()$$,
  '42501', 'Brukeren har ikke gyldig reviewer-rolle.',
  'editor-rollen gir ikke innsyn i reviewflaten'
);
reset role;

select set_config('request.jwt.claims', '', true);
set local role authenticated;
select throws_ok(
  $$select api.claim_review_workspace()$$,
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en uinnlogget kaller ser ingenting av reviewflaten'
);
reset role;

-- ===========================================================================
-- Del 4 — Køen
-- ===========================================================================
create temporary table queue_snapshot (payload jsonb) on commit drop;
grant select, insert on queue_snapshot to authenticated;

select set_config('request.jwt.claims',
                  '{"sub":"52000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
insert into queue_snapshot select api.claim_review_workspace() -> 'queue';
reset role;

select ok(
  (select exists (
     select 1 from queue_snapshot q,
     lateral jsonb_array_elements(q.payload) as item
     where item ->> 'claim_revision_id' = '52000000-0000-4000-8000-000000000031')),
  'en revisjon med evidenslenker, formulert av en annen aktør, står i køen'
);
select ok(
  (select not exists (
     select 1 from queue_snapshot q,
     lateral jsonb_array_elements(q.payload) as item
     where item ->> 'claim_revision_id' = '52000000-0000-4000-8000-000000000032')),
  'en revisjon revieweren selv har formulert står ikke i køen: den kan verken kontrolleres eller godkjennes av hen'
);
select ok(
  (select not exists (
     select 1 from queue_snapshot q,
     lateral jsonb_array_elements(q.payload) as item
     where item ->> 'claim_revision_id' = '52000000-0000-4000-8000-000000000033')),
  'en revisjon uten evidenslenker står ikke i køen: det finnes ikke noe å kontrollere mot'
);
select ok(
  (select not exists (
     select 1 from queue_snapshot q,
     lateral jsonb_array_elements(q.payload) as item
     where item ->> 'claim_revision_id' = '52000000-0000-4000-8000-000000000034')),
  'en revisjon på en tilbaketrukket påstand står ikke i køen'
);
select is(
  (select (item ->> 'evidence_link_count') || '|' || (item ->> 'is_published_revision')
   from queue_snapshot q, lateral jsonb_array_elements(q.payload) as item
   where item ->> 'claim_revision_id' = '52000000-0000-4000-8000-000000000031'),
  '2|false',
  'køraden teller evidenslenkene, og «ikke publisert» er false og ikke ukjent'
);

-- En avgrenset reviewer ser ikke utenfor sitt eget innholdsområde.
create temporary table scoped_queue (payload jsonb) on commit drop;
grant select, insert on scoped_queue to authenticated;
select set_config('request.jwt.claims',
                  '{"sub":"52000000-0000-4000-8000-0000000000e0"}', true);
set local role authenticated;
insert into scoped_queue select api.claim_review_workspace() -> 'queue';
select throws_ok(
  $$select api.claim_review_workspace('52000000-0000-4000-8000-000000000031')$$,
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'en avgrenset reviewer kommer ikke inn på en revisjon utenfor sitt eget innholdsområde, heller ikke ved direkte oppslag'
);
reset role;

select is(
  (select jsonb_array_length(payload) from scoped_queue),
  0,
  'en avgrenset reviewer får en tom kø når ingen revisjon hører til hens innholdsområde'
);

-- ===========================================================================
-- Del 5 — Arbeidsflaten
-- ===========================================================================
create temporary table workspace (label text primary key, payload jsonb) on commit drop;
grant select, insert on workspace to authenticated;

-- Avtrykket hentes her, som eier: authenticated har ikke usage på schemaet
-- knowledge, og skal ikke ha det. En reell klient leser verdien av
-- api.claim_review_workspace(uuid) og sender den tilbake — det er nøyaktig det
-- «det evidenssettet revieweren faktisk så» betyr.
create temporary table digest (label text primary key, value text) on commit drop;
insert into digest values
  ('r31', knowledge.claim_evidence_set_digest('52000000-0000-4000-8000-000000000031'));
grant select on digest to authenticated;

select set_config('request.jwt.claims',
                  '{"sub":"52000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_ok(
  $$select api.claim_review_workspace('00000000-0000-4000-8000-0000000000ff')$$,
  'P0002', 'Påstandsrevisjonen ''00000000-0000-4000-8000-0000000000ff'' finnes ikke.',
  'en revisjon som ikke finnes avvises eksplisitt'
);
insert into workspace select 'før', api.claim_review_workspace('52000000-0000-4000-8000-000000000031');
reset role;

select is(
  (select jsonb_array_length(payload #> '{revision,links}') from workspace where label = 'før'),
  2,
  'arbeidsflaten viser alle evidenslenkene på revisjonen, også den motstridende'
);
select is(
  (select payload #>> '{revision,links,0,evidence_item,source_version,content_hash}'
   from workspace where label = 'før'),
  'sha256:' || repeat('a', 64),
  'kildeversjonens fingeravtrykk er med, slik at revieweren kan slå opp nøyaktig den representasjonen'
);
select is(
  (select payload #>> '{revision,links,0,current_extraction_verification,outcome}'
   from workspace where label = 'før'),
  'verified',
  'den gjeldende ekstraksjonsverifikasjonen for hvert funn er med'
);
-- Medlemskap, ikke posisjon. Lista er sortert på funnets uuid, og seeden har
-- egne registrerte funn på sertralin og vektendring som kan sortere før eller
-- etter dette; en assertion på indeks 0 ville vært en assertion om en tilfeldig
-- uuid, ikke om at kandidaten er med.
select ok(
  (select exists (
     select 1
     from workspace w,
     lateral jsonb_array_elements(w.payload #> '{revision,unlinked_related_evidence}') as kandidat
     where w.label = 'før'
       and kandidat ->> 'evidence_item_id' = '52000000-0000-4000-8000-000000000013')),
  'registrert evidens på samme virkestoff og endepunkt som ikke er lenket, står som kandidat for urepresentert evidens'
);
select is(
  (select payload #>> '{revision,evidence_assessment,certainty_level}'
   from workspace where label = 'før'),
  'low',
  'evidensvurderingen med GRADE-domenene er med'
);
select is(
  (select (payload #>> '{revision,publication_gate,status}') || '|'
       || (payload #>> '{revision,publication_gate,sqlstate}')
   from workspace where label = 'før'),
  'blocked|23001',
  'blokkeringen kommer fra publiseringsgaten selv, med gatens egen SQLSTATE'
);
select alike(
  (select payload #>> '{revision,publication_gate,message}' from workspace where label = 'før'),
  '%ingen registrert claim-verifikasjon%',
  'og med gatens egen setning om hva som mangler'
);
select is(
  (select payload #>> '{revision,current_claim_verification_id}' from workspace where label = 'før'),
  null,
  'ingen registrert kontroll er NULL — ikke en kontroll med et negativt utfall'
);

-- Den avgjørende assertionen: mennesket og maskinen leser det samme grunnlaget.
create temporary table cred (label text primary key, secret text) on commit drop;
insert into cred select 'claim', provenance.issue_agent_identity_credential(
  'agent-identity:citation-support-verification-01', 'human:peder-holman');
grant select on cred to anon;
create temporary table agent_run (label text primary key, id uuid) on commit drop;
grant insert, select on agent_run to anon;
create temporary table agent_view (payload jsonb) on commit drop;
grant insert, select on agent_view to anon;

set local role anon;
insert into agent_run select 'r', api.begin_agent_run(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  'citation_support_verification', 'testleverandør', 'testmodell', '2026-09-09',
  'claim-verification/1', 'antidep-evidence/1', '{"mode": "test-520"}'::jsonb);
insert into agent_view select api.claim_verification_input(
  'agent-identity:citation-support-verification-01', (select secret from cred where label = 'claim'),
  (select id from agent_run where label = 'r'), '52000000-0000-4000-8000-000000000031')
  -> 'revisions' -> 0;
reset role;

select is(
  (select payload - 'verifications_by_this_actor' - 'verifications_total' from agent_view),
  workflow.claim_evidence_dossier('52000000-0000-4000-8000-000000000031'),
  'agentens lesegrunnlag er nøyaktig det samme uttrykket reviewflaten viser: én formulering av evidensgrunnlaget, ikke to'
);

-- ===========================================================================
-- Del 6 — Historikken, og gaten som slipper gjennom
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"52000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select api.register_human_claim_verification(
  '52000000-0000-4000-8000-000000000031',
  (select value from digest where label = 'r31'),
  'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
  jsonb_build_array(
    jsonb_build_object(
      'claim_evidence_link_id', '52000000-0000-4000-8000-000000000041',
      'source_access', 'original_source',
      'source_version_id', '52000000-0000-4000-8000-000000000021',
      'checked_content_hash', 'sha256:' || repeat('a', 64),
      'relationship_supported', 'ok'),
    jsonb_build_object(
      'claim_evidence_link_id', '52000000-0000-4000-8000-000000000042',
      'source_access', 'original_source',
      'source_version_id', '52000000-0000-4000-8000-000000000022',
      'checked_content_hash', 'sha256:' || repeat('b', 64),
      'relationship_supported', 'ok')),
  'Prøve i 520: kontrollen holder på alle punkter.');
insert into workspace select 'etter kontroll',
  api.claim_review_workspace('52000000-0000-4000-8000-000000000031');
select api.register_publication_approval(
  '52000000-0000-4000-8000-000000000031',
  (select value from digest where label = 'r31'),
  'approved', 'Prøve i 520: går god for publisering.');
insert into workspace select 'etter godkjenning',
  api.claim_review_workspace('52000000-0000-4000-8000-000000000031');
reset role;

select is(
  (select jsonb_array_length(payload #> '{revision,claim_verifications,0,citations}')
   from workspace where label = 'etter kontroll'),
  2,
  'historikken viser hva kontrollen faktisk gikk gjennom, lenke for lenke'
);
select is(
  (select payload #>> '{revision,claim_verifications,0,claim_verification_id}'
   from workspace where label = 'etter kontroll'),
  (select payload #>> '{revision,current_claim_verification_id}'
   from workspace where label = 'etter kontroll'),
  'den gjeldende kontrollen er den samme raden publiseringsgaten leser'
);
select alike(
  (select payload #>> '{revision,publication_gate,message}'
   from workspace where label = 'etter kontroll'),
  '%ikke godkjent av en kvalifisert redaktør%',
  'etter kontrollen er det godkjenningen gaten venter på: de to er to beslutninger, ikke én'
);
select is(
  (select payload #>> '{revision,review_decisions,0,decision}'
   from workspace where label = 'etter godkjenning'),
  'approved',
  'godkjenningen står i historikken, med sin egen begrunnelse og sitt eget avtrykk'
);
select is(
  (select payload #> '{revision,publication_gate}'
   from workspace where label = 'etter godkjenning'),
  '{"status": "passes"}'::jsonb,
  'når begge beslutningene er registrert, slipper publiseringsgaten gjennom'
);

select finish();
rollback;
