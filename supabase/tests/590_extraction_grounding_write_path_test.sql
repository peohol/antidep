-- Migrasjon 005v — agenten produserer sin egen kildeforankring.
--
-- Filen dekker skriveveien inn i knowledge.evidence_field_groundings: at den
-- går gjennom ekstraksjonsagenten og ingen andre, at forankringen blir til i
-- samme transaksjon som evidensfunnet og attribueres til kjøringens egen aktør,
-- at en ufullstendig forankring ikke etterlater noe, og at den menneskelige
-- editorveien verken kan skrive forankring eller later som om den kan.
--
-- Den siste påstanden er den bærende for kontrollflaten: venstresiden i en
-- kontrolløkt skal være noe ekstraksjonen leste ut av kilden, aldri noe et
-- menneske skrev inn ved siden av verdien (ANTIDEP_CONSTITUTION.md §8, §11).
--
-- SQLSTATE 22023 = invalid_parameter_value, P0002 = no_data_found,
-- 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(29);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'register_agent_extraction', 'api.register_agent_extraction() finnes'
);

select ok(
  (select p.prosecdef from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname = 'register_agent_extraction'),
  'api.register_agent_extraction() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);

-- Samme rettighetsform som de øvrige agentendepunktene: en agent har ingen
-- brukerkonto, og kontrollen er legitimasjonen inne i funksjonen.
select is_empty(
  $$
    select r.role_name
    from (values ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api' and p.proname = 'register_agent_extraction'),
      'execute'
    )
  $$,
  'PUBLIC har ingen EXECUTE på agentens skrivevei'
);

-- Editorveien tar ingen forankringsparameter. En som gjorde det, ville latt et
-- menneske skrive venstresiden kontrolløren skal prøve høyresiden mot.
select is(
  (select count(*) from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname = 'create_evidence_item'),
  1::bigint,
  'det finnes nøyaktig én api.create_evidence_item, ikke to overloads'
);

select is_empty(
  $$
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and p.proname = 'create_evidence_item'
      and 'p_field_groundings' = any (p.proargnames)
  $$,
  'editorveien har ingen forankringsparameter'
);

-- ===========================================================================
-- Del 2 — Fikstur: katalog, kilde, to kildeversjoner, legitimasjon, kjøring
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
grant select on fixture to anon;

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('59000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 590',
        'Testforfatter 590', (select id from fixture where name = 'editor'));

-- Med representasjon: kan bære en agentekstraksjon.
insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation, retrieved_by_actor_id)
values ('59000000-0000-4000-8000-000000000021', '59000000-0000-4000-8000-000000000001',
        now(), 'https://eutils.example.test/efetch.fcgi?db=pubmed&id=590',
        'sha256:' || repeat('b', 64), 'full_text',
        (select id from fixture where name = 'editor'));

-- Uten representasjon: tilstanden alle versjoner registrert før migrasjon 003b
-- er i. Da vet ingen hva ekstraksjonen faktisk bygde på.
insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
values ('59000000-0000-4000-8000-000000000022', '59000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/590-legacy', 'sha256:' || repeat('c', 64),
        (select id from fixture where name = 'editor'));

create temporary table cred (label text primary key, secret text not null) on commit drop;
insert into cred
select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman'
);
grant select on cred to anon;

create temporary table run (label text primary key, id uuid not null) on commit drop;
grant select, insert on run to anon;

create temporary table registered (name text primary key, id uuid not null) on commit drop;
grant select, insert on registered to anon, authenticated;

set local role anon;
insert into run
select 'open', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_role := 'evidence_extraction',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-12', p_prompt_template_version := 'evidence-extraction/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_source_version_id := '59000000-0000-4000-8000-000000000021',
  p_input_manifest := jsonb_build_object('source_version_ids',
    array['59000000-0000-4000-8000-000000000021'])
);
reset role;

-- Kallet, med nøyaktig de feltene fiksturraden påstår noe om. `p_source_quote`
-- er med fordi raw_extraction fortsatt er radens ordrette gjengivelse.
create function pg_temp.extract(
  p_detail text, p_groundings jsonb, p_source_version uuid
) returns uuid language plpgsql as $$
declare
  v_drug uuid;
  v_outcome uuid;
  v_secret text;
  v_run uuid;
begin
  select id into v_drug from catalog.drugs where canonical_name = 'sertralin';
  select id into v_outcome from catalog.clinical_concepts where canonical_label = 'vektendring';
  select secret into v_secret from cred where label = 'extractor';
  select id into v_run from run where label = 'open';

  perform set_config('role', 'anon', true);
  return api.register_agent_extraction(
    p_identity_key => 'agent-identity:evidence-extraction-01',
    p_secret => v_secret,
    p_agent_run_id => v_run,
    p_source_id => '59000000-0000-4000-8000-000000000001',
    p_source_version_id => p_source_version,
    p_design_code => 'randomized_controlled_trial',
    p_population_availability => 'not_reported',
    p_population_detail => 'Prøve i 590.',
    p_sample_size_availability => 'not_reported',
    p_intervention_drug_id => v_drug,
    p_comparator_kind => 'none',
    p_outcome_concept_id => v_outcome,
    p_outcome_detail => p_detail,
    p_timepoint_availability => 'not_reported',
    p_reported_direction => 'increase',
    p_estimate_availability => 'not_reported',
    p_confidence_interval_availability => 'not_reported',
    p_source_locator => 'Avsnitt for 590',
    p_extraction_method => 'ai_assisted',
    p_field_groundings => p_groundings,
    p_source_quote => 'Weight change was 1.7 kg in the sertraline arm.'
  );
end;
$$;

create function pg_temp.extract_sql(p_detail text, p_groundings text, p_source_version text)
  returns text language sql as $$
  select 'select pg_temp.extract(' || quote_literal(p_detail) || ', ' || p_groundings
    || ', ' || quote_literal(p_source_version) || '::uuid)';
$$;

-- Forankringen fiksturraden trenger: ett utdrag per semantisk felt raden
-- påstår noe om. Med `comparator_kind = 'none'` og alt annet ført som ikke
-- rapportert er det nøyaktig fire.
create function pg_temp.full_groundings() returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('check_field', 'intervention_arm',
      'source_excerpt', 'Patients received sertraline.',
      'source_locator', 'Metode, avsnitt 1',
      'justification', 'Behandlingsarmen er navngitt i metodeavsnittet.'),
    jsonb_build_object('check_field', 'outcome',
      'source_excerpt', 'Weight change was the primary outcome.',
      'source_locator', 'Metode, avsnitt 2',
      'justification', 'Endepunktet er navngitt i metodeavsnittet.'),
    jsonb_build_object('check_field', 'reported_direction',
      'source_excerpt', 'Weight increased from baseline.',
      'source_locator', 'Resultater, avsnitt 1',
      'justification', 'Retningen står som en økning i resultatavsnittet.'),
    jsonb_build_object('check_field', 'availability_semantics',
      'source_excerpt', 'No sample size was reported for the weight analysis.',
      'source_locator', 'Resultater, avsnitt 2',
      'justification', 'Feltene uten verdi er ført som ikke rapportert, som kilden sier.')
  );
$$;

-- ===========================================================================
-- Del 3 — Den lykkede stien
-- ===========================================================================
insert into registered (name, id)
select 'grounded', pg_temp.extract(
  'Funn med forankring, 590.', pg_temp.full_groundings(),
  '59000000-0000-4000-8000-000000000021'
);
reset role;

select is(
  (select count(*) from knowledge.evidence_field_groundings g
   where g.evidence_item_id = (select id from registered where name = 'grounded')),
  4::bigint,
  'forankringen blir til i samme kall som evidensfunnet'
);

-- Aktøren er kjøringens egen, og den sammensatte fremmednøkkelen låser den til
-- evidensfunnets skaper. Ingen parameter kan velge en annen.
select is(
  (select distinct g.created_by_actor_id from knowledge.evidence_field_groundings g
   where g.evidence_item_id = (select id from registered where name = 'grounded')),
  (select id from fixture where name = 'extractor'),
  'forankringen attribueres til agenten som faktisk laget ekstraksjonen'
);

select is(
  (select g.source_excerpt from knowledge.evidence_field_groundings g
   where g.evidence_item_id = (select id from registered where name = 'grounded')
     and g.check_field = 'outcome'),
  'Weight change was the primary outcome.',
  'utdraget lagres ordrett'
);

select is(
  (select e.extraction_method::text from knowledge.evidence_items e
   where e.id = (select id from registered where name = 'grounded')),
  'ai_assisted',
  'ekstraksjonsmetoden er agentens, og er ikke en parameter kalleren velger'
);

-- Den bærende påstanden om det nye leddet: forankringen dekker nøyaktig de
-- semantiske feltene kontrolløkten stiller spørsmål om.
select set_eq(
  format(
    $$select unnest(workflow.semantic_check_fields(%L::uuid))::text$$,
    (select id from registered where name = 'grounded')
  ),
  format(
    $$select unnest(workflow.grounded_check_fields(%L::uuid))::text$$,
    (select id from registered where name = 'grounded')
  ),
  'ekstraksjonen forankrer nøyaktig de feltene kontrolløkten spør om'
);

-- Og de feltene ingen kontrolløkt stiller spørsmål om, er fortsatt i gatens
-- krav: de to provenansfeltene, og — fordi denne raden fører et felt som ikke
-- rapportert — det kildeomfattende søket, som bare en maskin kan bære
-- (migrasjon 005ae).
select set_eq(
  format(
    $$select unnest(workflow.required_check_fields(%L::uuid))::text
      except select unnest(workflow.semantic_check_fields(%L::uuid))::text$$,
    (select id from registered where name = 'grounded'),
    (select id from registered where name = 'grounded')
  ),
  $$values ('raw_extraction'), ('source_locator'), ('source_wide_absence')$$,
  'gatens krav er de semantiske feltene, de to provenansfeltene og det kildeomfattende søket'
);

-- ===========================================================================
-- Del 4 — Det agentveien nekter
-- ===========================================================================
select throws_ok(
  pg_temp.extract_sql('Hull i forankringen, 590.',
    $q$jsonb_build_array(
        jsonb_build_object('check_field', 'outcome', 'source_excerpt', 'Utdrag hull 590',
                           'source_locator', 'B', 'justification', 'C'))$q$,
    '59000000-0000-4000-8000-000000000021'),
  '22023',
  null,
  'en ekstraksjon med hull i forankringen avvises'
);
reset role;

select is(
  (select count(*) from knowledge.evidence_field_groundings g
   where g.source_excerpt = 'Utdrag hull 590'),
  0::bigint,
  'og den ufullstendige ekstraksjonen etterlater ingenting'
);

select throws_ok(
  pg_temp.extract_sql('Uten representasjon, 590.', 'pg_temp.full_groundings()',
    '59000000-0000-4000-8000-000000000022'),
  '22023',
  'Kildeversjonen sier ikke hva slags representasjon den er.',
  'en kildeversjon uten registrert representasjon kan ikke bære en agentekstraksjon'
);
reset role;

select throws_ok(
  $$select pg_temp.extract('Ukjent versjon, 590.', pg_temp.full_groundings(),
      '59000000-0000-4000-8000-0000000000ff'::uuid)$$,
  'P0002',
  null,
  'en kildeversjon som ikke finnes, avvises'
);
reset role;

-- ===========================================================================
-- Del 5 — Editorveien skriver ingen forankring
-- ===========================================================================
insert into auth.users (id, instance_id, aud, role, email)
values ('59000000-0000-4000-8000-0000000000a0', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'a590@example.test');

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values ('59000000-0000-4000-8000-0000000000a1', 'human:a-590', 'human', 'Kaller A 590',
        'Editor for 590.', '59000000-0000-4000-8000-0000000000a0');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to, granted_by_actor_id, grant_reason)
values ('59000000-0000-4000-8000-0000000000a0', 'editor', null,
        now() - interval '1 year', null,
        (select id from fixture where name = 'editor'), 'Tildeling for kaller A i 590.');

create function pg_temp.register_manual() returns uuid language plpgsql as $$
declare
  v_drug uuid;
  v_outcome uuid;
begin
  select id into v_drug from catalog.drugs where canonical_name = 'sertralin';
  select id into v_outcome from catalog.clinical_concepts where canonical_label = 'vektendring';
  perform set_config('request.jwt.claims',
                     '{"sub":"59000000-0000-4000-8000-0000000000a0"}', true);
  perform set_config('role', 'authenticated', true);
  return api.create_evidence_item(
    p_source_id => '59000000-0000-4000-8000-000000000001',
    p_design_code => 'randomized_controlled_trial',
    p_population_availability => 'not_reported',
    p_population_detail => 'Manuell prøve i 590.',
    p_sample_size_availability => 'not_reported',
    p_intervention_drug_id => v_drug,
    p_comparator_kind => 'none',
    p_outcome_concept_id => v_outcome,
    p_outcome_detail => 'Manuelt funn, 590.',
    p_timepoint_availability => 'not_reported',
    p_reported_direction => 'increase',
    p_estimate_availability => 'not_reported',
    p_confidence_interval_availability => 'not_reported',
    p_source_locator => 'Avsnitt for 590',
    p_source_version_id => '59000000-0000-4000-8000-000000000021'
  );
end;
$$;

insert into registered (name, id) select 'manual', pg_temp.register_manual();
select set_config('role', 'none', true);
select set_config('request.jwt.claims', '', true);

select is(
  workflow.evidence_field_groundings((select id from registered where name = 'manual')),
  '[]'::jsonb,
  'et funn registrert av en redaktør har ingen forankring — og får ingen gjettet ut av raw_extraction'
);

select is(
  workflow.evidence_extraction_dossier((select id from registered where name = 'manual'))
    -> 'field_groundings',
  '[]'::jsonb,
  'og kontrollflaten ser fraværet som fravær'
);

-- Nøyaktig den forskjellen kontrolløkten leser for å stoppe: det manuelle
-- funnet har semantiske felter uten forankring.
select isnt_empty(
  format(
    $$select unnest(workflow.semantic_check_fields(%L::uuid))::text
      except select unnest(workflow.grounded_check_fields(%L::uuid))::text$$,
    (select id from registered where name = 'manual'),
    (select id from registered where name = 'manual')
  ),
  'et manuelt funn står med hull i forankringen, og kan ikke kontrolleres felt for felt'
);

-- ===========================================================================
-- Del 6 — Hele kjeden, fra en fersk agentekstraksjon til en publisert påstand
--
-- Det nye leddet er det første: ekstraksjonsagenten produserer forankringen
-- selv, av en kildeversjon med kjent representasjon. Resten av kjeden er den
-- samme som 570 prøver, og går her på det forankrede funnet:
--
--   api.register_agent_extraction
--     → api.register_extraction_verification   (maskinen beviser utdragene)
--     → api.register_human_extraction_verification
--     → api.register_human_claim_verification
--     → api.register_publication_approval
--     → api.publish_claim_revision
-- ===========================================================================
insert into auth.users (id, instance_id, aud, role, email)
select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u.email
from (values
  ('59000000-0000-4000-8000-0000000000c0'::uuid, 'c590@example.test'),
  ('59000000-0000-4000-8000-0000000000d0'::uuid, 'd590@example.test')
) as u(id, email);

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values
  ('59000000-0000-4000-8000-0000000000c1', 'human:c-590', 'human', 'Reviewer C 590',
   'Kvalifisert reviewer, for 590.', '59000000-0000-4000-8000-0000000000c0'),
  ('59000000-0000-4000-8000-0000000000d1', 'human:d-590', 'human', 'Publisher D 590',
   'Publisher, for 590.', '59000000-0000-4000-8000-0000000000d0');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('59000000-0000-4000-8000-0000000000c0', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Reviewer-tildeling for 590.'),
  ('59000000-0000-4000-8000-0000000000d0', 'publisher', null, now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Publisher-tildeling for 590.');

with c as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis',
         (select id from fixture where name = 'weight'),
         (select id from fixture where name = 'sertralin'),
         (select id from provenance.actors where actor_key = 'agent:claim-synthesis')
  returning id, knowledge_type, subject_drug_id, created_by_actor_id
)
insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
select '59000000-0000-4000-8000-000000000031', c.id, 1, c.knowledge_type, c.subject_drug_id,
       'Testpåstand for 590.', 'Gjelder bare som testdata i 590.', 'none', 'increase',
       'Testusikkerhet.', c.created_by_actor_id
from c;

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select '59000000-0000-4000-8000-000000000041', '59000000-0000-4000-8000-000000000031',
       (select id from registered where name = 'grounded'), 'supports', 'direct',
       'Lenke i 590.', (select id from provenance.actors where actor_key = 'agent:claim-synthesis');

-- Vurderingen attribueres til evidensvurderingsaktøren, ikke til den som
-- formulerte revisjonen: publiseringsgatens G10b krever at den som gjorde
-- vurderingen, hadde mandat til det (migrasjon 005ap). Ansvarsgrensen mellom
-- påstandsdannelse og evidensvurdering er en teknisk grense
-- (EVIDENCE_PIPELINE.md §61).
insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select '59000000-0000-4000-8000-000000000031', 'evidence_synthesis', 'grade', 'low',
       'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
       'Prøve i 590: lav sikkerhet, som er noe annet enn ingen vurderbar evidens.',
       now(), (select id from provenance.actors where actor_key = 'agent:evidence-assessment');

-- Avtrykkene leveres av flaten, ikke regnes ut av klienten: de to
-- avtrykksfunksjonene er ikke kjørbare for authenticated.
create temporary table digest (label text primary key, value text) on commit drop;
grant select on digest to authenticated;
create function pg_temp.refresh_digests() returns void language sql as $$
  insert into digest
  select 'e', workflow.evidence_extraction_digest((select id from registered where name = 'grounded'))
  union all
  select 'r', knowledge.claim_evidence_set_digest('59000000-0000-4000-8000-000000000031')
  on conflict (label) do update set value = excluded.value;
$$;
select pg_temp.refresh_digests();

create temporary table citations (label text primary key, payload jsonb) on commit drop;
insert into citations
select 'ok', jsonb_build_array(jsonb_build_object(
  'claim_evidence_link_id', '59000000-0000-4000-8000-000000000041',
  'source_access', 'verifiable_representation',
  'source_version_id', '59000000-0000-4000-8000-000000000021',
  'checked_content_hash', 'sha256:' || repeat('b', 64),
  'relationship_supported', 'ok'));
grant select on citations to authenticated;

-- Ledd 1: den deterministiske kontrollen beviser venstresiden. Den fører opp
-- raw_extraction og source_locator som kontrollert, som den gjør når
-- representasjonen lot seg reprodusere og hvert forankret utdrag ble gjenfunnet
-- ordrett. Uten dette leddet avviser migrasjon 005x den menneskelige
-- bekreftelsen under.
insert into cred
select 'verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman'
);

set local role anon;
insert into run
select 'verify', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-12', p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('evidence_item_ids',
    array[(select id from registered where name = 'grounded')])
);
select lives_ok(
  $$
    select api.register_extraction_verification(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'verifier'),
      (select id from run where label = 'verify'),
      (select id from registered where name = 'grounded'),
      'uncertain', 'verifiable_representation',
      -- Den kildeomfattende halvdelen av et globalt fravær hører til her og
      -- ingen andre steder: den er et søk gjennom hele representasjonen, og
      -- kontrolløkten stiller aldri det spørsmålet (migrasjon 005ae).
      array['raw_extraction', 'source_locator', 'source_wide_absence'],
      'Prøve i 590: hvert forankret utdrag ble gjenfunnet ordrett i den reproduserte representasjonen.',
      'Tallene og begrepene lot seg ikke bedømme maskinelt, så kontrollen konkluderte ikke om raden som helhet.')
  $$,
  'den deterministiske kontrollen beviser at utdragene står i kilden'
);
reset role;

select ok(
  workflow.grounding_machine_proved((select id from registered where name = 'grounded')),
  'og beviset gjelder nøyaktig det grunnlaget funnet har nå'
);

-- now() er transaksjonens starttidspunkt, så to kontroller registrert her ville
-- fått samme verified_at, og «den siste» ville vært avgjort av en tilfeldig
-- uuid. Maskinens kontroll dyttes derfor en time bakover, slik en reell kjøring
-- får det av at hver registrering er sin egen transaksjon. Samme grep og samme
-- begrunnelse som i 490, 530 og 570.
set local session_replication_role = replica;
update workflow.evidence_verifications
set verified_at = verified_at - interval '1 hour',
    created_at = created_at - interval '1 hour'
where evidence_item_id = (select id from registered where name = 'grounded');
set local session_replication_role = origin;

-- Maskinens kontroll er selv en del av grunnlagsavtrykket: kontrolløren skal
-- se at den er kommet til. Avtrykkene hentes derfor på nytt.
select pg_temp.refresh_digests();

-- Ledd 2: den menneskelige ekstraksjonskontrollen. Feltene er de fire
-- semantiske pluss de to provenansfeltene en bekreftelse fører opp.
select set_config('request.jwt.claims',
                  '{"sub":"59000000-0000-4000-8000-0000000000c0"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.register_human_extraction_verification(
      (select id from registered where name = 'grounded'),
      (select value from digest where label = 'e'),
      'verified', 'verifiable_representation',
      array['raw_extraction', 'source_locator', 'intervention_arm', 'outcome',
            'reported_direction', 'availability_semantics'],
      'Prøve i 590: kontrollert felt for felt mot agentens forankring i en guidet kontrolløkt.')
  $$,
  'kontrolløren bekrefter ekstraksjonen, felt for felt'
);
reset role;

select is(
  cardinality(workflow.covered_check_fields(
    (select id from registered where name = 'grounded'))),
  -- Seks fra mennesket og kontrollleddet over, pluss det kildeomfattende søket
  -- maskinen gjorde: til sammen nøyaktig det raden påstår noe om.
  7,
  'og dekningen er komplett: hvert felt funnet påstår noe om, er kontrollert'
);

-- Ledd 3: claim-kontrollen.
select pg_temp.refresh_digests();
select set_config('request.jwt.claims',
                  '{"sub":"59000000-0000-4000-8000-0000000000c0"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.register_human_claim_verification(
      '59000000-0000-4000-8000-000000000031',
      (select value from digest where label = 'r'),
      'verified', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
      (select payload from citations where label = 'ok'),
      'Prøve i 590: kontrollert punkt for punkt mot det registrerte grunnlaget.')
  $$,
  'kontrolløren bekrefter påstanden mot det ferdig kontrollerte grunnlaget'
);

-- Ledd 4: publiseringsgodkjenningen, som er en egen beslutning.
select lives_ok(
  $$
    select api.register_publication_approval(
      '59000000-0000-4000-8000-000000000031',
      (select value from digest where label = 'r'),
      'approved',
      'Godkjent for publisering etter en fullført kontrolløkt i 590.')
  $$,
  'og går god for publisering som en egen beslutning'
);
reset role;

select lives_ok(
  $$select knowledge.assert_claim_revision_publishable(
      '59000000-0000-4000-8000-000000000031')$$,
  'hele publiseringsgaten passerer'
);

-- Ledd 5: publiseringen, med sin tredje rettighet.
select set_config('request.jwt.claims',
                  '{"sub":"59000000-0000-4000-8000-0000000000d0"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.publish_claim_revision(
      '59000000-0000-4000-8000-000000000031',
      'Publisert etter fullført kontroll av kildegrunnlag og påstand, 590.')
  $$,
  'publiseringen utføres av den som har publisher-rollen'
);
reset role;

select is(
  (select c.current_published_revision_id from knowledge.claims c
   join knowledge.claim_revisions r on r.claim_id = c.id
   where r.id = '59000000-0000-4000-8000-000000000031'),
  '59000000-0000-4000-8000-000000000031'::uuid,
  'og påstanden står publisert, med agentens egen forankring i bunn'
);

-- ===========================================================================
-- Dublettavvisningen navngir raden som kolliderte (migrasjon 007h)
--
-- Uten den måtte en kjøring som ble avbrutt mellom registreringen og
-- kontrollen, gjette hvilken rad den kolliderte med — og en gjetning på noe
-- annet enn den kanoniske identiteten kan peke på feil rad: to funn fra den
-- samme kildeversjonen kan legitimt dele kildeforankring og likevel gjelde
-- ulike utfall.
-- ===========================================================================
create temporary table dublett (label text primary key, id uuid, detail text) on commit drop;

insert into dublett (label, id)
select 'first', knowledge.record_evidence_item(
  '59000000-0000-4000-8000-000000000001',
  'randomized_controlled_trial', 'not_reported', 'Dublettprøve i 590.', 'not_reported',
  (select id from fixture where name = 'sertralin'), 'none',
  (select id from fixture where name = 'weight'), 'Dublettprøve, utfall.',
  'not_reported', 'increase', 'not_reported', 'not_reported', 'Avsnitt 9',
  '59000000-0000-4000-8000-000000000021',
  null, null, null, null, null, null, null, null, null, null, null, null, null, null, null,
  '[]'::jsonb, 'manual', (select id from fixture where name = 'editor'), null);

do $$
declare
  v_detail text;
begin
  begin
    perform knowledge.record_evidence_item(
      '59000000-0000-4000-8000-000000000001',
      'randomized_controlled_trial', 'not_reported', 'Dublettprøve i 590.', 'not_reported',
      (select id from fixture where name = 'sertralin'), 'none',
      (select id from fixture where name = 'weight'), 'Dublettprøve, utfall.',
      'not_reported', 'increase', 'not_reported', 'not_reported', 'Avsnitt 9',
      '59000000-0000-4000-8000-000000000021',
      null, null, null, null, null, null, null, null, null, null, null, null, null, null, null,
      '[]'::jsonb, 'manual', (select id from fixture where name = 'editor'), null);
  exception
    when unique_violation then
      get stacked diagnostics v_detail = pg_exception_detail;
      insert into dublett (label, detail) values ('second', v_detail);
  end;
end
$$;

select is(
  (select detail from dublett where label = 'second'),
  (select 'evidence_item_id=' || id::text from dublett where label = 'first'),
  'dublettavvisningen navngir nøyaktig raden som kolliderte'
);

-- Og den er slått opp med den samme identiteten UNIQUE-regelen bruker, ikke med
-- en likhet noen fant på: avtrykket på den navngitte raden er avtrykket av det
-- innholdet innsettingen forsøkte.
select is(
  (select e.content_hash from knowledge.evidence_items e
   where e.id = (select id from dublett where label = 'first')),
  (select e.content_hash from knowledge.evidence_items e
   where e.id = (select id from dublett where label = 'first')
     and e.content_hash = knowledge.evidence_item_content_hash(e)),
  'og raden er funnet på den kanoniske identiteten, ikke på en likhet ved siden av'
);

select finish();
rollback;
