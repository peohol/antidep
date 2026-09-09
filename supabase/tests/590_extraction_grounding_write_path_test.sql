-- Migrasjon 007f — ekstraksjonen produserer sin egen kildeforankring.
--
-- Filen dekker skriveveien inn i knowledge.evidence_field_groundings: at den
-- gamle signaturen er borte og den nye har de samme rettighetene, at
-- forankringen blir til i samme transaksjon som evidensfunnet og attribueres
-- til den som laget det, at formfeilene avvises med en setning som sier hva som
-- er galt, og at et funn registrert uten forankring står som uforankret —
-- aldri som forankret på noe som er gjettet.
--
-- Den siste påstanden er den viktigste for kontrollflaten: et gammelt funn skal
-- ikke kunne se kontrollerbart ut (ANTIDEP_CONSTITUTION.md §6, §11).
--
-- SQLSTATE 22023 = invalid_parameter_value, 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(24);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'create_evidence_item', 'api.create_evidence_item() finnes'
);

-- Den gamle signaturen er sluppet, ikke stående ved siden av den nye: to
-- kandidater ville latt klienten og ikke kontrakten avgjøre hvilken PostgREST
-- kaller.
select is(
  (select count(*) from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname = 'create_evidence_item'),
  1::bigint,
  'det finnes nøyaktig én api.create_evidence_item, ikke to overloads'
);

select ok(
  (select p.pronargs from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api' and p.proname = 'create_evidence_item') = 31,
  'signaturen har fått forankringsparameteren'
);

select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'api' and p.proname = 'create_evidence_item'),
      'execute'
    )
  $$,
  'skriveveien er kjørbar bare for authenticated, som før'
);

-- ===========================================================================
-- Del 2 — Fikstur: én editor, én kilde, én kildeversjon.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';

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

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('59000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 590',
        'Testforfatter 590', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
values ('59000000-0000-4000-8000-000000000021', '59000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/590', 'sha256:' || repeat('b', 64),
        (select id from fixture where name = 'editor'));

-- Kaller skriveveien som en innlogget bruker. Katalogoppslagene gjøres før
-- rollebyttet: en temp-tabell eies av sesjonsbrukeren, og authenticated har
-- ingen rettighet på den.
create function pg_temp.register(p_user uuid, p_detail text, p_groundings jsonb)
  returns uuid language plpgsql as $$
declare
  v_drug uuid;
  v_outcome uuid;
  v_id uuid;
begin
  select id into v_drug from catalog.drugs where canonical_name = 'sertralin';
  select id into v_outcome from catalog.clinical_concepts where canonical_label = 'vektendring';

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user)::text, true);
  perform set_config('role', 'authenticated', true);

  v_id := api.create_evidence_item(
    p_source_id => '59000000-0000-4000-8000-000000000001',
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
    p_source_version_id => '59000000-0000-4000-8000-000000000021',
    p_field_groundings => p_groundings
  );

  -- 'none' er det SET ROLE NONE gjør: tilbake til sesjonsbrukeren, uten å
  -- navngi hvilken den er.
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
  return v_id;
end;
$$;

-- Kallet som tekst, for de grenene som skal avvises.
create function pg_temp.register_sql(p_user text, p_detail text, p_groundings text)
  returns text language sql as $$
  select 'select pg_temp.register(' || quote_literal(p_user) || '::uuid, '
    || quote_literal(p_detail) || ', ' || p_groundings || ')';
$$;

-- ===========================================================================
-- Del 3 — Den lykkede stien
-- ===========================================================================
create temporary table registered (name text primary key, id uuid not null) on commit drop;
-- Flaten kjenner id-en den nettopp fikk. Her leses den fra tabellen inne i
-- kallet, og da må kalleren kunne lese den.
grant select on registered to authenticated;

insert into registered (name, id)
select 'grounded', pg_temp.register(
  '59000000-0000-4000-8000-0000000000a0',
  'Funn med forankring, 590.',
  jsonb_build_array(
    jsonb_build_object(
      'check_field', 'outcome',
      'source_excerpt', 'Weight change was the primary outcome.',
      'source_locator', 'Metode, avsnitt 2',
      'justification', 'Endepunktet er navngitt i metodeavsnittet.'
    ),
    jsonb_build_object(
      'check_field', 'source_locator',
      'source_excerpt', 'Table 2 reports the weight outcome.',
      'source_locator', 'Tabell 2, overskriften',
      'justification', 'Kildepekeren viser til tabellen som rapporterer endepunktet.'
    )
  )
);

select is(
  (select count(*) from knowledge.evidence_field_groundings g
   where g.evidence_item_id = (select id from registered where name = 'grounded')),
  2::bigint,
  'forankringen blir til i samme kall som evidensfunnet'
);

-- Aktøren er kallerens egen, og den sammensatte fremmednøkkelen låser den til
-- evidensfunnets skaper. Ingen parameter kan velge en annen.
select is(
  (select distinct g.created_by_actor_id from knowledge.evidence_field_groundings g
   where g.evidence_item_id = (select id from registered where name = 'grounded')),
  '59000000-0000-4000-8000-0000000000a1'::uuid,
  'forankringen attribueres til den som faktisk laget ekstraksjonen'
);

select is(
  (select g.source_excerpt from knowledge.evidence_field_groundings g
   where g.evidence_item_id = (select id from registered where name = 'grounded')
     and g.check_field = 'outcome'),
  'Weight change was the primary outcome.',
  'utdraget lagres ordrett'
);

-- ===========================================================================
-- Del 4 — Et funn uten forankring står som uforankret
-- ===========================================================================
insert into registered (name, id)
select 'bare', pg_temp.register(
  '59000000-0000-4000-8000-0000000000a0', 'Funn uten forankring, 590.', null
);

select is(
  workflow.evidence_field_groundings((select id from registered where name = 'bare')),
  '[]'::jsonb,
  'et funn registrert uten forankring har ingen — og får ingen gjettet ut av raw_extraction'
);

select is(
  workflow.evidence_extraction_dossier((select id from registered where name = 'bare'))
    -> 'field_groundings',
  '[]'::jsonb,
  'og kontrollflaten ser fraværet som fravær'
);

insert into registered (name, id)
select 'tom', pg_temp.register(
  '59000000-0000-4000-8000-0000000000a0', 'Funn med tom forankringsliste, 590.', '[]'::jsonb
);

select is(
  workflow.evidence_field_groundings((select id from registered where name = 'tom')),
  '[]'::jsonb,
  'en tom liste betyr det samme som ingen liste'
);

-- ===========================================================================
-- Del 5 — Formfeilene
-- ===========================================================================
select throws_ok(
  pg_temp.register_sql('59000000-0000-4000-8000-0000000000a0', 'Feil form, 590.',
    $q$'{"check_field": "outcome"}'::jsonb$q$),
  '22023',
  'p_field_groundings må være en jsonb-liste av kildeforankringer.',
  'et objekt er ikke en liste'
);

select throws_ok(
  pg_temp.register_sql('59000000-0000-4000-8000-0000000000a0', 'Dublett, 590.',
    $q$jsonb_build_array(
        jsonb_build_object('check_field', 'outcome', 'source_excerpt', 'A',
                           'source_locator', 'B', 'justification', 'C'),
        jsonb_build_object('check_field', 'outcome', 'source_excerpt', 'D',
                           'source_locator', 'E', 'justification', 'F'))$q$),
  '22023',
  'Feltet ''outcome'' er forankret mer enn én gang.',
  'to forankringer av samme felt avvises med feltets navn'
);

select throws_ok(
  pg_temp.register_sql('59000000-0000-4000-8000-0000000000a0', 'Ukjent felt, 590.',
    $q$jsonb_build_array(
        jsonb_build_object('check_field', 'noe_helt_annet', 'source_excerpt', 'A',
                           'source_locator', 'B', 'justification', 'C'))$q$),
  '22023',
  'En av kildeforankringene viser til et felt som ikke finnes.',
  'et felt utenfor vokabularet avvises'
);

select throws_ok(
  pg_temp.register_sql('59000000-0000-4000-8000-0000000000a0', 'Manglende peker, 590.',
    $q$jsonb_build_array(
        jsonb_build_object('check_field', 'outcome', 'source_excerpt', 'A',
                           'justification', 'C'))$q$),
  '22023',
  'En av kildeforankringene mangler et påkrevd felt.',
  'et utdrag uten kildepeker er ikke etterprøvbart'
);

-- ===========================================================================
-- Del 6 — Autorisasjonen er uendret
-- ===========================================================================
insert into auth.users (id, instance_id, aud, role, email)
values ('59000000-0000-4000-8000-0000000000b0', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'b590@example.test');

select throws_ok(
  pg_temp.register_sql('59000000-0000-4000-8000-0000000000b0', 'Uautorisert prøve, 590.',
    $q$jsonb_build_array(
        jsonb_build_object('check_field', 'outcome', 'source_excerpt', 'Utdrag A 590',
                           'source_locator', 'B', 'justification', 'C'))$q$),
  '42501',
  null,
  'en kaller uten editor-rolle avvises, og forankringen åpner ingen dør'
);

select is(
  (select count(*) from knowledge.evidence_field_groundings g
   where g.source_excerpt = 'Utdrag A 590'),
  0::bigint,
  'og ingen forankring ble skrevet av det avviste forsøket'
);

-- ===========================================================================
-- Del 7 — Hele kjeden, fra en fersk forankret ekstraksjon til en publisert
--         påstand
--
-- Det nye leddet er det første: ekstraksjonen produserer forankringen selv, og
-- forankringen dekker nøyaktig de feltene publiseringsgaten senere krever
-- kontrollert. Resten av kjeden er den samme som 570 prøver, og går her på det
-- forankrede funnet:
--
--   api.create_evidence_item (med forankring)
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

-- Funnet kjeden går på: registrert gjennom skriveveien, med forankring for hvert
-- felt raden påstår noe om.
insert into registered (name, id)
select 'chain', pg_temp.register(
  '59000000-0000-4000-8000-0000000000a0',
  'Funn for kjeden i 590.',
  jsonb_build_array(
    jsonb_build_object('check_field', 'raw_extraction',
      'source_excerpt', 'Weight change was 1.7 kg in the sertraline arm.',
      'source_locator', 'Resultater, avsnitt 1',
      'justification', 'Setningen er bevart ordrett ved siden av de strukturerte feltene.'),
    jsonb_build_object('check_field', 'source_locator',
      'source_excerpt', 'Results are reported in the first paragraph.',
      'source_locator', 'Resultater, overskriften',
      'justification', 'Kildepekeren viser til avsnittet funnet er lest ut av.'),
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
  )
);

-- Den bærende påstanden om det nye leddet: forankringen dekker nøyaktig det
-- publiseringsgaten senere krever kontrollert. En ekstraksjon som forankret
-- mindre, ville sendt kontrolløren til et felt uten grunnlag.
select set_eq(
  format(
    $$select unnest(workflow.required_check_fields(%L::uuid))::text$$,
    (select id from registered where name = 'chain')
  ),
  format(
    $$select g ->> 'check_field'
      from jsonb_array_elements(workflow.evidence_field_groundings(%L::uuid)) as g$$,
    (select id from registered where name = 'chain')
  ),
  'ekstraksjonen forankrer nøyaktig de feltene publiseringsgaten krever kontrollert'
);

-- Påstanden funnet skal bære, formulert av en annen aktør enn den som
-- kontrollerer den.
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
       (select id from registered where name = 'chain'), 'supports', 'direct',
       'Lenke i 590.', (select id from provenance.actors where actor_key = 'agent:claim-synthesis');

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select '59000000-0000-4000-8000-000000000031', 'evidence_synthesis', 'grade', 'low',
       'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
       'Prøve i 590: lav sikkerhet, som er noe annet enn ingen vurderbar evidens.',
       now(), (select id from provenance.actors where actor_key = 'agent:claim-synthesis');

-- Avtrykkene leveres av flaten, ikke regnes ut av klienten: de to
-- avtrykksfunksjonene er ikke kjørbare for authenticated.
create temporary table digest (label text primary key, value text) on commit drop;
grant select on digest to authenticated;
create function pg_temp.refresh_digests() returns void language sql as $$
  insert into digest
  select 'e', workflow.evidence_extraction_digest((select id from registered where name = 'chain'))
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

-- Ledd 1: den menneskelige ekstraksjonskontrollen, med nøyaktig de feltene
-- forankringen dekker.
select set_config('request.jwt.claims',
                  '{"sub":"59000000-0000-4000-8000-0000000000c0"}', true);
set local role authenticated;
select lives_ok(
  $$
    select api.register_human_extraction_verification(
      (select id from registered where name = 'chain'),
      (select value from digest where label = 'e'),
      'verified', 'verifiable_representation',
      array['raw_extraction', 'source_locator', 'intervention_arm', 'outcome',
            'reported_direction', 'availability_semantics'],
      'Prøve i 590: kontrollert felt for felt mot kilden i en guidet kontrolløkt.')
  $$,
  'kontrolløren bekrefter ekstraksjonen, felt for felt'
);
reset role;

select is(
  cardinality(workflow.covered_check_fields(
    (select id from registered where name = 'chain'))),
  6,
  'og dekningen er komplett: hvert felt funnet påstår noe om, er kontrollert'
);

-- Ledd 2: claim-kontrollen.
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

-- Ledd 3: publiseringsgodkjenningen, som er en egen beslutning.
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

-- Ledd 4: publiseringen, med sin tredje rettighet.
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
  'og påstanden står publisert, med den reviderte forankringen i bunn'
);

select finish();
rollback;
