-- Migrasjon 005aj og 004a — synteseagentens skrivevei, og proveniensen på
-- påstandsrevisjonen.
--
-- Filen dekker den ene veien en påstand kan bli til på: at den går gjennom
-- rollen claim_synthesis og ingen annen, at påstand, revisjon, evidenslenker og
-- evidensvurdering blir til i samme transaksjon eller ikke i det hele tatt, at
-- evidensen må ha nådd kontrollnivået EVIDENCE_PIPELINE.md §26 og §27 krever før
-- den kan bære en påstand, og at revisjonen etterlater en auditrad.
--
-- Den bærende påstanden: hvert vilkår i
-- workflow.assert_evidence_usable_for_synthesis(uuid[]) er prøvd ved å svekke
-- det. En vakt som aldri er sett feile, er ikke en vakt.
--
-- SQLSTATE 22023 = invalid_parameter_value, P0002 = no_data_found,
-- 23001 = restrict_violation, 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(47);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'register_claim_synthesis', 'api.register_claim_synthesis() finnes'
);

select ok(
  (select p.prosecdef from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname = 'register_claim_synthesis'),
  'api.register_claim_synthesis() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);

select is_empty(
  $$
    select 1
    where has_function_privilege(
      'public',
      (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api' and p.proname = 'register_claim_synthesis'),
      'execute'
    )
  $$,
  'PUBLIC har ingen EXECUTE på synteseagentens skrivevei'
);

select ok(
  has_function_privilege(
    'anon',
    (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'api' and p.proname = 'register_claim_synthesis'),
    'execute'
  ),
  'anon har EXECUTE: kontrollen er legitimasjonen, ikke Data API-rollen'
);

select has_function(
  'workflow', 'assert_evidence_usable_for_synthesis',
  'workflow.assert_evidence_usable_for_synthesis() finnes'
);

-- Kunnskapstypen er ikke en parameter kalleren kan velge (migrasjon 005aj).
select is_empty(
  $$
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and p.proname = 'register_claim_synthesis'
      and 'p_knowledge_type' = any (p.proargnames)
  $$,
  'skriveveien har ingen kunnskapstype-parameter'
);

-- Proveniensen på revisjonen (migrasjon 004a).
select has_column(
  'knowledge', 'claim_revisions', 'agent_run_id',
  'knowledge.claim_revisions har agent_run_id'
);
select has_column(
  'knowledge', 'claim_revisions', 'agent_run_role',
  'knowledge.claim_revisions har agent_run_role'
);
select col_is_null(
  'knowledge', 'claim_revisions', 'agent_run_id',
  'agent_run_id er NULL-bar: en redaktørs egen revisjon kom ikke av en kjøring'
);

-- Rollen er en generert konstant, som på de tre øvrige tabellene som peker på
-- en agentkjøring. En kaller kan dermed ikke oppgi den, og ikke oppgi den feil.
select ok(
  (select a.attgenerated = 's'
   from pg_attribute a
   where a.attrelid = 'knowledge.claim_revisions'::regclass
     and a.attname = 'agent_run_role'),
  'agent_run_role er en generert kolonne, ikke en verdi kalleren oppgir'
);

-- ===========================================================================
-- Del 2 — Fikstur
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'drug', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';
insert into fixture (name, id) select 'synthesiser', id from provenance.actors where actor_key = 'agent:claim-synthesis';
grant select on fixture to anon;

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('69000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 690',
   'Testforfatter 690', (select id from fixture where name = 'editor')),
  ('69000000-0000-4000-8000-000000000002', 'journal_article', 'Tilbaketrukket testkilde for 690',
   'Testforfatter 690', (select id from fixture where name = 'editor'));

update knowledge.sources
set source_status = 'retracted',
    status_note = 'Tilbaketrukket i fiksturen, for å prøve vilkåret om kildestatus.'
where id = '69000000-0000-4000-8000-000000000002';

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation, retrieved_by_actor_id)
values
  ('69000000-0000-4000-8000-000000000021', '69000000-0000-4000-8000-000000000001',
   now(), 'https://eutils.example.test/efetch.fcgi?db=pubmed&id=690',
   'sha256:' || repeat('b', 64), 'full_text',
   (select id from fixture where name = 'editor')),
  ('69000000-0000-4000-8000-000000000022', '69000000-0000-4000-8000-000000000002',
   now(), 'https://eutils.example.test/efetch.fcgi?db=pubmed&id=691',
   'sha256:' || repeat('d', 64), 'full_text',
   (select id from fixture where name = 'editor'));

create temporary table cred (label text primary key, secret text not null) on commit drop;
insert into cred
select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman'
);
insert into cred
select 'verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman'
);
insert into cred
select 'synthesiser', provenance.issue_agent_identity_credential(
  'agent-identity:claim-synthesis-01', 'human:peder-holman'
);
grant select on cred to anon;

create temporary table run (label text primary key, id uuid not null) on commit drop;
grant select, insert on run to anon;

set local role anon;
insert into run
select 'extraction', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_role := 'evidence_extraction',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-23', p_prompt_template_version := 'evidence-extraction/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_source_version_id := '69000000-0000-4000-8000-000000000021',
  p_input_manifest := jsonb_build_object('test', 690)
);
-- Kjøringen er bundet til den kildeversjonen den leser (migrasjon 005z), så en
-- fikstur med to kildeversjoner trenger to ekstraksjonskjøringer.
insert into run
select 'extraction-retracted', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_role := 'evidence_extraction',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-23', p_prompt_template_version := 'evidence-extraction/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_source_version_id := '69000000-0000-4000-8000-000000000022',
  p_input_manifest := jsonb_build_object('test', 690)
);
insert into run
select 'verification', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-23', p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('test', 690)
);
insert into run
select 'synthesis', api.begin_agent_run(
  p_identity_key := 'agent-identity:claim-synthesis-01',
  p_secret := (select secret from cred where label = 'synthesiser'),
  p_agent_role := 'claim_synthesis',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-23', p_prompt_template_version := 'claim-synthesis/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('test', 690)
);
reset role;

-- Et evidensfunn med komplett forankring. Fiksturen varierer bare
-- outcome_detail, slik at hvert funn er sin egen rad
-- (evidence_items_content_hash_key).
create function pg_temp.extract(p_detail text, p_source_version uuid) returns uuid
  language plpgsql as $$
declare
  v_secret text;
  v_run uuid;
  v_source uuid;
begin
  select secret into v_secret from cred where label = 'extractor';
  select id into v_run from run
  where label = case
    when p_source_version = '69000000-0000-4000-8000-000000000022' then 'extraction-retracted'
    else 'extraction'
  end;
  select sv.source_id into v_source
  from knowledge.source_versions sv where sv.id = p_source_version;

  perform set_config('role', 'anon', true);
  return api.register_agent_extraction(
    p_identity_key => 'agent-identity:evidence-extraction-01',
    p_secret => v_secret,
    p_agent_run_id => v_run,
    p_source_id => v_source,
    p_source_version_id => p_source_version,
    p_design_code => 'randomized_controlled_trial',
    p_population_availability => 'not_reported',
    p_population_detail => 'Prøve i 690.',
    p_sample_size_availability => 'not_reported',
    p_intervention_drug_id => (select id from fixture where name = 'drug'),
    p_comparator_kind => 'none',
    p_outcome_concept_id => (select id from fixture where name = 'topic'),
    p_outcome_detail => p_detail,
    p_timepoint_availability => 'not_reported',
    p_reported_direction => 'increase',
    p_estimate_availability => 'not_reported',
    p_confidence_interval_availability => 'not_reported',
    p_source_locator => 'Avsnitt for 690',
    p_extraction_method => 'ai_assisted',
    p_field_groundings => jsonb_build_array(
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
        'source_excerpt', 'No values were reported for the weight analysis.',
        'source_locator', 'Resultater, avsnitt 2',
        'justification', 'Feltene uten verdi er ført som ikke rapportert, som kilden sier.')
    )
  );
end;
$$;

-- En registrert kontroll av et funn. `checked_fields` hentes av
-- workflow.required_check_fields(uuid) når kontrollen skal dekke alt, slik at
-- fiksturen ikke kan komme i utakt med hva raden faktisk påstår.
create function pg_temp.verify(
  p_item uuid, p_outcome text, p_fields workflow.evidence_check_field[]
) returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  insert into workflow.evidence_verifications (
    evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
    agent_run_id, outcome, source_access, checked_fields,
    findings, rationale, verified_at
  )
  select
    p_item,
    e.created_by_actor_id,
    (select id from fixture where name = 'verifier'),
    (select id from run where label = 'verification'),
    p_outcome::workflow.verification_outcome,
    'verifiable_representation',
    p_fields,
    case when p_outcome = 'verified' then null else 'Avvik i fiksturen for 690.' end,
    'Kontroll registrert av fiksturen i 690.',
    now()
  from knowledge.evidence_items e
  where e.id = p_item
  returning id into v_id;

  return v_id;
end;
$$;

create temporary table item (label text primary key, id uuid not null) on commit drop;
grant select, insert on item to anon;

insert into item select 'ok', pg_temp.extract('Funn som kan bære en påstand, 690.', '69000000-0000-4000-8000-000000000021');
reset role;
insert into item select 'unverified', pg_temp.extract('Funn uten kontroll, 690.', '69000000-0000-4000-8000-000000000021');
reset role;
insert into item select 'needs_correction', pg_temp.extract('Funn med åpent avvik, 690.', '69000000-0000-4000-8000-000000000021');
reset role;
insert into item select 'partial', pg_temp.extract('Funn med delvis kontroll, 690.', '69000000-0000-4000-8000-000000000021');
reset role;
insert into item select 'withdrawn', pg_temp.extract('Funn med tilbaketrukket ekstraksjon, 690.', '69000000-0000-4000-8000-000000000021');
reset role;
insert into item select 'retracted', pg_temp.extract('Funn på tilbaketrukket kilde, 690.', '69000000-0000-4000-8000-000000000022');
reset role;

select pg_temp.verify(
  (select id from item where label = 'ok'), 'verified',
  workflow.required_check_fields((select id from item where label = 'ok'))
);
select pg_temp.verify(
  (select id from item where label = 'needs_correction'), 'needs_correction',
  workflow.required_check_fields((select id from item where label = 'needs_correction'))
);
select pg_temp.verify(
  (select id from item where label = 'partial'), 'verified',
  array['source_locator']::workflow.evidence_check_field[]
);
select pg_temp.verify(
  (select id from item where label = 'withdrawn'), 'verified',
  workflow.required_check_fields((select id from item where label = 'withdrawn'))
);
select pg_temp.verify(
  (select id from item where label = 'retracted'), 'verified',
  workflow.required_check_fields((select id from item where label = 'retracted'))
);

insert into workflow.review_decisions (
  evidence_item_id, evidence_item_creator_actor_id, review_type,
  decision, rationale, reviewer_actor_id, reviewer_actor_type, decided_at
)
select
  i.id, e.created_by_actor_id, 'extraction_withdrawal',
  'extraction_withdrawn',
  'Trukket tilbake i fiksturen, for å prøve vilkåret om tilbaketrukket ekstraksjon.',
  (select id from fixture where name = 'editor'), 'human', now()
from item i
join knowledge.evidence_items e on e.id = i.id
where i.label = 'withdrawn';

-- Kallet. Alt som varierer mellom prøvene, er parametre; resten er fast, slik
-- at en avvisning ikke kan komme av at to kall var forskjellige på noe annet.
create function pg_temp.synthesise(
  p_links jsonb,
  p_claim uuid default null,
  p_statement text default 'Hos voksne er behandling med sertralin i det registrerte grunnlaget forbundet med en gjennomsnittlig vektøkning fra behandlingsstart.',
  p_topic uuid default null,
  p_drug uuid default null
) returns jsonb language plpgsql as $$
declare
  v_secret text;
  v_run uuid;
begin
  select secret into v_secret from cred where label = 'synthesiser';
  select id into v_run from run where label = 'synthesis';

  perform set_config('role', 'anon', true);
  return api.register_claim_synthesis(
    p_identity_key => 'agent-identity:claim-synthesis-01',
    p_secret => v_secret,
    p_agent_run_id => v_run,
    p_claim_id => p_claim,
    p_topic_concept_id => coalesce(p_topic, (select id from fixture where name = 'topic')),
    p_subject_drug_id => coalesce(p_drug, (select id from fixture where name = 'drug')),
    p_statement => p_statement,
    p_scope => 'Gjelder gjennomsnittlig vektendring fra behandlingsstart. Gjelder ikke andelen med klinisk betydelig vektøkning.',
    p_comparator_kind => 'none',
    p_direction => 'increase',
    p_qualifiers => 'Grunnlaget er armspesifikt og tillater ingen sammenligning med andre virkestoffer.',
    p_uncertainty_summary => 'Grunnlaget er ett evidensfunn fra én studie, uten tallverdi og uten konfidensintervall.',
    p_evidence_links => p_links,
    p_assessment => jsonb_build_object(
      'framework', 'grade',
      'certainty_level', 'very_low',
      'risk_of_bias', 'serious',
      'inconsistency', 'not_assessable',
      'indirectness', 'not_serious',
      'imprecision', 'not_assessable',
      'publication_bias', 'not_assessable',
      'rationale', 'Ett evidensfunn fra én randomisert studie ligger til grunn i fiksturen for 690.',
      'evidence_gap', 'Størrelsen er ikke tallfestet i det registrerte grunnlaget.'
    )
  );
end;
$$;

create function pg_temp.link(p_label text, p_relationship text default 'supports',
                             p_directness text default 'direct')
  returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'evidence_item_id', (select id from item where label = p_label),
    'relationship_type', p_relationship,
    'directness', p_directness,
    'relevance_note', 'Funnet rapporterer vektendring for behandlingsarmen påstanden gjelder.'
  ));
$$;

create function pg_temp.synthesise_sql(p_links text, p_claim text default 'null')
  returns text language sql as $$
  select 'select pg_temp.synthesise(' || p_links || ', ' || p_claim || ')';
$$;

-- ===========================================================================
-- Del 3 — Den lykkede stien
-- ===========================================================================
create temporary table result (label text primary key, payload jsonb not null) on commit drop;
grant select, insert on result to anon;
insert into result select 'first', pg_temp.synthesise(pg_temp.link('ok'));
reset role;

select is(
  (select (payload ->> 'revision_number')::integer from result where label = 'first'),
  1,
  'første revisjon av en ny påstand får revisjonsnummer 1'
);

select is(
  (select payload ->> 'supersedes_revision_id' from result where label = 'first'),
  null,
  'første revisjon erstatter ingen tidligere revisjon'
);

select is(
  (select r.knowledge_type::text from knowledge.claim_revisions r
   where r.id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first')),
  'evidence_synthesis',
  'kunnskapstypen er evidence_synthesis, hardkodet av skriveveien'
);

select is(
  (select r.created_by_actor_id from knowledge.claim_revisions r
   where r.id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first')),
  (select id from fixture where name = 'synthesiser'),
  'revisjonen er attribuert til kjøringens egen aktør, ikke til en parameter'
);

select is(
  (select r.agent_run_role::text from knowledge.claim_revisions r
   where r.id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first')),
  'claim_synthesis',
  'revisjonen bærer rollen kjøringen hadde'
);

select is(
  (select r.agent_run_id from knowledge.claim_revisions r
   where r.id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first')),
  (select id from run where label = 'synthesis'),
  'revisjonen peker på den åpne kjøringen'
);

select is(
  (select count(*) from knowledge.claim_evidence_links l
   where l.claim_revision_id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first')),
  1::bigint,
  'evidenslenken er registrert i samme kall'
);

select is(
  (select a.certainty_level::text from knowledge.evidence_assessments a
   where a.claim_revision_id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first')),
  'very_low',
  'evidensvurderingen er registrert i samme kall'
);

select is(
  (select a.created_by_actor_id from knowledge.evidence_assessments a
   where a.claim_revision_id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first')),
  (select id from fixture where name = 'synthesiser'),
  'evidensvurderingen er attribuert til kjøringens egen aktør'
);

select is(
  (select payload ->> 'evidence_set_digest' from result where label = 'first'),
  (select knowledge.claim_evidence_set_digest(
     (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first'))),
  'svaret bærer avtrykket av det evidenssettet revisjonen hviler på'
);

-- Evidenssettet er forseglet av vurderingen: en lenke til kan ikke legges til.
select throws_ok(
  $$
    insert into knowledge.claim_evidence_links (
      claim_revision_id, evidence_item_id, relationship_type, directness,
      relevance_note, created_by_actor_id
    )
    select
      (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first'),
      (select id from item where label = 'unverified'),
      'supports', 'direct', 'Forsøk på å utvide et forseglet evidenssett.',
      (select id from fixture where name = 'synthesiser')
  $$,
  '23001',
  null,
  'evidenssettet er forseglet av evidensvurderingen skriveveien registrerte'
);

-- ===========================================================================
-- Del 4 — Auditraden (migrasjon 004a og 008k)
-- ===========================================================================
select is(
  (select count(*) from audit.events e
   where e.operation = 'claim_revision_created'
     and e.object_id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first')),
  1::bigint,
  'hver ny påstandsrevisjon etterlater nøyaktig én auditrad'
);

select is(
  (select e.object_schema || '.' || e.object_table from audit.events e
   where e.operation = 'claim_revision_created'
     and e.object_id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first')),
  'knowledge.claim_revisions',
  'auditraden peker på tabellen revisjonen ligger i'
);

select is(
  (select e.request_or_run_id from audit.events e
   where e.operation = 'claim_revision_created'
     and e.object_id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first')),
  (select id from run where label = 'synthesis'),
  'auditraden navngir agentkjøringen som sporingsnøkkel'
);

select is(
  (select e.old_revision_or_snapshot from audit.events e
   where e.operation = 'claim_revision_created'
     and e.object_id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first')),
  null,
  'en ny revisjon har ingen tidligere utgave av seg selv'
);

-- ===========================================================================
-- Del 5 — Videreføringen
-- ===========================================================================
insert into result
select 'second', pg_temp.synthesise(
  pg_temp.link('ok'),
  (select (payload ->> 'claim_id')::uuid from result where label = 'first'),
  'Hos voksne er behandling med sertralin i det registrerte grunnlaget forbundet med en liten gjennomsnittlig vektøkning fra behandlingsstart.'
);
reset role;

select is(
  (select (payload ->> 'revision_number')::integer from result where label = 'second'),
  2,
  'neste revisjon av samme påstand får nummer 2'
);

select is(
  (select (payload ->> 'supersedes_revision_id')::uuid from result where label = 'second'),
  (select (payload ->> 'claim_revision_id')::uuid from result where label = 'first'),
  'videreføringen peker på revisjonen den erstatter'
);

select is(
  (select (payload ->> 'claim_id')::uuid from result where label = 'second'),
  (select (payload ->> 'claim_id')::uuid from result where label = 'first'),
  'identiteten er den samme; det er revisjonen som er ny'
);

-- Et annet tema eller virkestoff er en annen påstand.
select throws_ok(
  $$select pg_temp.synthesise(
      pg_temp.link('ok'),
      (select (payload ->> 'claim_id')::uuid from result where label = 'first'),
      'Påstand med feil virkestoff.',
      null,
      (select id from catalog.drugs where canonical_name = 'mirtazapin')
    )$$,
  '22023',
  null,
  'en revisjon kan ikke flytte påstanden til et annet virkestoff'
);

-- ===========================================================================
-- Del 6 — Hvert vilkår i kontrollnivået, prøvd ved å svekke det
-- ===========================================================================
select throws_ok(
  pg_temp.synthesise_sql($$pg_temp.link('unverified')$$),
  '23001', null,
  'et funn uten registrert ekstraksjonskontroll kan ikke bære en påstand (G4)'
);

select throws_ok(
  pg_temp.synthesise_sql($$pg_temp.link('needs_correction')$$),
  '23001', null,
  'et funn med åpent verifikasjonsfunn kan ikke bære en påstand (G5)'
);

select throws_ok(
  pg_temp.synthesise_sql($$pg_temp.link('partial')$$),
  '23001', null,
  'et funn der kontrollene ikke dekker alt raden påstår, kan ikke bære en påstand (G5b)'
);

select throws_ok(
  pg_temp.synthesise_sql($$pg_temp.link('withdrawn')$$),
  '23001', null,
  'et funn med tilbaketrukket ekstraksjon kan ikke bære en påstand (G6)'
);

select throws_ok(
  pg_temp.synthesise_sql($$pg_temp.link('retracted')$$),
  '23001', null,
  'et funn på en tilbaketrukket kilde kan ikke bære en påstand (G7)'
);

select throws_ok(
  $$select pg_temp.synthesise(jsonb_build_array(jsonb_build_object(
      'evidence_item_id', '69000000-0000-4000-8000-0000000000ff',
      'relationship_type', 'supports', 'directness', 'direct',
      'relevance_note', 'Peker på et funn som ikke finnes.')))$$,
  'P0002', null,
  'en lenke til et funn som ikke finnes, avvises med sin egen feil'
);

-- ===========================================================================
-- Del 7 — Formen på kallet
-- ===========================================================================
select throws_ok(
  $$select pg_temp.synthesise('[]'::jsonb)$$,
  '22023', null,
  'en revisjon uten evidenslenker avvises'
);

select throws_ok(
  $$select pg_temp.synthesise(jsonb_build_array(jsonb_build_object(
      'evidence_item_id', (select id from item where label = 'ok'),
      'relationship_type', 'supports', 'directness', 'direct')))$$,
  '22023', null,
  'en lenke uten begrunnelse avvises: en kilde som bare omhandler temaet, teller ikke som støtte'
);

select throws_ok(
  $$select pg_temp.synthesise(
      pg_temp.link('ok') || pg_temp.link('ok'))$$,
  '22023', null,
  'det samme funnet kan ikke oppføres to ganger i det samme evidenssettet'
);

-- ===========================================================================
-- Del 8 — Rollen er rettighetsgrensen
-- ===========================================================================
select throws_ok(
  format(
    $$select api.register_claim_synthesis(
        'agent-identity:evidence-extraction-01', %L,
        (select id from run where label = 'synthesis'),
        (select id from fixture where name = 'topic'),
        (select id from fixture where name = 'drug'),
        'Påstand forsøkt registrert av ekstraksjonsagenten.',
        'Prøve i 690.', 'none', 'Prøve i 690.',
        %L::jsonb, '{}'::jsonb)$$,
    (select secret from cred where label = 'extractor'),
    pg_temp.link('ok')::text
  ),
  '42501', null,
  'ekstraksjonsagenten kan ikke formulere en påstand: rollen avvises i autentiseringen'
);

select throws_ok(
  format(
    $$select api.register_claim_synthesis(
        'agent-identity:claim-synthesis-01', %L,
        (select id from run where label = 'extraction'),
        (select id from fixture where name = 'topic'),
        (select id from fixture where name = 'drug'),
        'Påstand forsøkt registrert på en annen identitets kjøring.',
        'Prøve i 690.', 'none', 'Prøve i 690.',
        %L::jsonb, '{}'::jsonb)$$,
    (select secret from cred where label = 'synthesiser'),
    pg_temp.link('ok')::text
  ),
  '42501', null,
  'synteseagenten kan ikke skrive på en kjøring som tilhører en annen identitet'
);

-- ===========================================================================
-- Del 9 — En avvist syntese etterlater ingenting
-- ===========================================================================
create temporary table before_counts as
select
  (select count(*) from knowledge.claims) as claims,
  (select count(*) from knowledge.claim_revisions) as revisions,
  (select count(*) from knowledge.claim_evidence_links) as links,
  (select count(*) from knowledge.evidence_assessments) as assessments;

do $$
begin
  begin
    perform pg_temp.synthesise(pg_temp.link('needs_correction'));
  exception when others then
    -- Rollen hjelpefunksjonen satte, rulles tilbake med undertransaksjonen.
    null;
  end;
end;
$$;
reset role;

select is(
  (select count(*) from knowledge.claims), (select claims from before_counts),
  'en avvist syntese etterlater ingen påstandsidentitet'
);
select is(
  (select count(*) from knowledge.claim_revisions), (select revisions from before_counts),
  'en avvist syntese etterlater ingen revisjon'
);
select is(
  (select count(*) from knowledge.claim_evidence_links), (select links from before_counts),
  'en avvist syntese etterlater ingen evidenslenke'
);
select is(
  (select count(*) from knowledge.evidence_assessments), (select assessments from before_counts),
  'en avvist syntese etterlater ingen evidensvurdering'
);

-- ===========================================================================
-- Del 10 — Revisjonen er et forslag, ikke noe godkjent
-- ===========================================================================
select throws_ok(
  format(
    $$select knowledge.assert_claim_revision_publishable(%L::uuid)$$,
    (select (payload ->> 'claim_revision_id')::uuid from result where label = 'second')
  ),
  '23001', null,
  'publiseringsgaten stopper en revisjon som ikke er kontrollert av en separat fase'
);

select is(
  (select count(*) from workflow.claim_verifications cv
   where cv.claim_revision_id = (select (payload ->> 'claim_revision_id')::uuid from result where label = 'second')),
  0::bigint,
  'skriveveien registrerer ingen claim-verifikasjon: generering og verifikasjon er atskilt'
);

select is(
  (select cl.current_published_revision_id from knowledge.claims cl
   where cl.id = (select (payload ->> 'claim_id')::uuid from result where label = 'first')),
  null,
  'skriveveien publiserer ingenting'
);

select * from finish();
rollback;
