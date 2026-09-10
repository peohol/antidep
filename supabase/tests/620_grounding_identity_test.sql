-- Migrasjon 003d — kildeforankringen er en del av evidensfunnets identitet.
--
-- Issue #66: `content_hash` ble regnet ut av kolonnene på
-- `knowledge.evidence_items` alene, mens forankringen ligger i sin egen tabell.
-- Et forslag som bare rettet et `source_excerpt`, en `source_locator` eller en
-- `justification`, ga nøyaktig den samme hashen og ble avvist som en dublett —
-- og den gale forankringen ble stående. ANTIDEP_CONSTITUTION.md §4, §8 og §11
-- krever det motsatte: kildeforankringen er grunnlaget en kontrollør prøver
-- verdien mot, og et grunnlag som ikke kan rettes, kan heller ikke etterprøves.
--
-- Filen dekker hele leveransen: kanoniseringen, avtrykket, identiteten,
-- skriveveien, den utsatte kontrollen som gjør at avtrykket ikke kan lyve, og
-- at gammel og ny rad står med hver sin kontrollstatus.
--
-- SQLSTATE 23505 = unique_violation, 23514 = check_violation,
-- 23000 = integrity_constraint_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(36);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_column(
  'knowledge', 'evidence_items', 'grounding_digest',
  'knowledge.evidence_items bærer avtrykket av sin egen kildeforankring'
);

select col_not_null(
  'knowledge', 'evidence_items', 'grounding_digest',
  'avtrykket er alltid utfylt; «ingen forankring» er avtrykket av den tomme listen, ikke NULL'
);

select col_has_default(
  'knowledge', 'evidence_items', 'grounding_digest',
  'et funn uten forankring får avtrykket av den tomme listen av databasen'
);

-- De tre funksjonene identiteten hviler på. Volatiliteten er en del av
-- kontrakten: kanoniseringen og avtrykket leser ingenting utenfor argumentet,
-- mens oppslaget mot tabellen gjør det.
select is(
  (select array_agg(p.provolatile::text order by p.proname)
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'knowledge'
     and p.proname in ('canonical_field_groundings', 'evidence_field_grounding_digest',
                       'evidence_item_grounding_digest')),
  array['i', 'i', 's'],
  'kanoniseringen og avtrykket er IMMUTABLE, og oppslaget mot tabellen er STABLE'
);

select ok(
  (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'knowledge' and p.proname = 'assert_grounding_digest_matches'),
  'kontrollen er SECURITY DEFINER: den kjører ved commit, utenfor skriveveiens egen kontekst'
);

-- Utsatt til commit, fordi funnet skrives før forankringen som peker på det.
-- En umiddelbar kontroll ville avvist enhver lovlig registrering.
select is(
  (select array_agg(t.tgname::text || ':' || t.tgdeferrable::text || t.tginitdeferred::text
                    order by t.tgname)
   from pg_trigger t
   where t.tgname in ('evidence_items_grounding_digest_matches',
                      'evidence_field_groundings_digest_matches')),
  array['evidence_field_groundings_digest_matches:truetrue',
        'evidence_items_grounding_digest_matches:truetrue'],
  'kontrollen står på begge tabellene, utsatt til commit'
);

-- ===========================================================================
-- Del 2 — Avtrykket er deterministisk
-- ===========================================================================
create function pg_temp.grounding(
  p_field text, p_excerpt text, p_locator text, p_justification text
) returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'check_field', p_field, 'source_excerpt', p_excerpt,
    'source_locator', p_locator, 'justification', p_justification);
$$;

create function pg_temp.digest(p_groundings jsonb) returns text language sql stable as $$
  select knowledge.evidence_field_grounding_digest(p_groundings);
$$;

-- Rekkefølgen i et forslag er tilfeldig: ett felt har én forankring, og hvilken
-- linje som står først i filen, er ingen opplysning. En flyttet linje skal
-- derfor ikke bli et nytt evidensfunn.
select is(
  pg_temp.digest(jsonb_build_array(
    pg_temp.grounding('outcome', 'Utdrag A', 'Side 1', 'Begrunnelse A'),
    pg_temp.grounding('intervention_arm', 'Utdrag B', 'Side 2', 'Begrunnelse B'))),
  pg_temp.digest(jsonb_build_array(
    pg_temp.grounding('intervention_arm', 'Utdrag B', 'Side 2', 'Begrunnelse B'),
    pg_temp.grounding('outcome', 'Utdrag A', 'Side 1', 'Begrunnelse A'))),
  'kanonisk rekkefølge: den samme forankringen gir det samme avtrykket uansett rekkefølge'
);

-- Verdien selv, festet mot en kjent referanse. Uten den ville en utilsiktet
-- omdefinering av kanoniseringen bare gjort alle radene til nye funn — stille,
-- fordi hver av testene over ville holdt fortsatt.
select is(
  pg_temp.digest(jsonb_build_array(
    pg_temp.grounding('outcome', 'Utdrag A', 'Side 1', 'Begrunnelse A'),
    pg_temp.grounding('intervention_arm', 'Utdrag B', 'Side 2', 'Begrunnelse B'))),
  'sha256-v1:bad7c1af3f4fdc42de19b0a4cad1f7483ebbc60fea150035d190402b25b8f4d8',
  'avtrykket er den verdien definisjonen faktisk gir, ikke bare en verdi som er stabil med seg selv'
);

select isnt(
  pg_temp.digest(jsonb_build_array(pg_temp.grounding('outcome', 'Utdrag A', 'Side 1', 'Fordi'))),
  pg_temp.digest(jsonb_build_array(pg_temp.grounding('outcome', 'Utdrag B', 'Side 1', 'Fordi'))),
  'et rettet ordrett utdrag gir et annet avtrykk'
);

select isnt(
  pg_temp.digest(jsonb_build_array(pg_temp.grounding('outcome', 'Utdrag A', 'Side 1', 'Fordi'))),
  pg_temp.digest(jsonb_build_array(pg_temp.grounding('outcome', 'Utdrag A', 'Side 2', 'Fordi'))),
  'en rettet kildepeker gir et annet avtrykk'
);

select isnt(
  pg_temp.digest(jsonb_build_array(pg_temp.grounding('outcome', 'Utdrag A', 'Side 1', 'Fordi'))),
  pg_temp.digest(jsonb_build_array(pg_temp.grounding('outcome', 'Utdrag A', 'Side 1', 'Derfor'))),
  'en rettet begrunnelse gir et annet avtrykk'
);

-- Normaliseringen speiler CHECK-ene på tabellen: det som lagres, er btrim-et, og
-- avtrykket skal derfor regnes av den samme verdien. Ellers ville et forslag med
-- et mellomrom for mye fått et avtrykk som ikke stemte med radene det skrev.
select is(
  pg_temp.digest(jsonb_build_array(pg_temp.grounding('outcome', '  Utdrag A  ', ' Side 1 ', ' Fordi '))),
  pg_temp.digest(jsonb_build_array(pg_temp.grounding('outcome', 'Utdrag A', 'Side 1', 'Fordi'))),
  'utdrag, peker og begrunnelse normaliseres som tabellen gjør det'
);

select is(
  pg_temp.digest(null),
  pg_temp.digest('[]'::jsonb),
  'ingen forankring og en tom liste er den samme tilstanden'
);

select isnt(
  pg_temp.digest('[]'::jsonb),
  pg_temp.digest(jsonb_build_array(pg_temp.grounding('outcome', 'Utdrag A', 'Side 1', 'Fordi'))),
  'og den tilstanden er ikke den samme som å ha en forankring'
);

-- ===========================================================================
-- Del 3 — Identiteten dekker forankringen
-- ===========================================================================
select matches(
  (select e.content_hash from knowledge.evidence_items e limit 1),
  '^sha256-v3:[0-9a-f]{64}$',
  'fingeravtrykket er versjonert til sha256-v3, som er definisjonen med forankringen i seg'
);

select isnt(
  (select knowledge.evidence_item_content_hash(
            jsonb_populate_record(e, jsonb_build_object(
              'grounding_digest', pg_temp.digest('[]'::jsonb))))
   from knowledge.evidence_items e limit 1),
  (select knowledge.evidence_item_content_hash(
            jsonb_populate_record(e, jsonb_build_object(
              'grounding_digest', pg_temp.digest(
                jsonb_build_array(pg_temp.grounding('outcome', 'X', 'Y', 'Z'))))))
   from knowledge.evidence_items e limit 1),
  'to funn med identiske strukturerte verdier og ulik forankring har ulik identitet'
);

-- ===========================================================================
-- Del 4 — Fikstur for skriveveien
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
grant select on fixture to anon;

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('62000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 620',
        'Testforfatter 620', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation, retrieved_by_actor_id)
values ('62000000-0000-4000-8000-000000000021', '62000000-0000-4000-8000-000000000001',
        now(), 'https://eutils.example.test/efetch.fcgi?db=pubmed&id=620',
        'sha256:' || repeat('e', 64), 'full_text',
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
grant select on cred to anon;

create temporary table run (label text primary key, id uuid not null) on commit drop;
grant select, insert on run to anon;
create temporary table registered (name text primary key, id uuid) on commit drop;
grant select, insert on registered to anon;

set local role anon;
insert into run
select 'extraction', api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred where label = 'extractor'),
  p_agent_role := 'evidence_extraction',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-14', p_prompt_template_version := 'evidence-extraction/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_source_version_id := '62000000-0000-4000-8000-000000000021',
  p_input_manifest := jsonb_build_object('source_version_ids',
    array['62000000-0000-4000-8000-000000000021'])
);
reset role;

-- Forankringen fiksturraden trenger: ett utdrag per semantisk felt raden
-- påstår noe om. Parametrene er de tre verdiene rettelsene under endrer, ett om
-- gangen, slik at alt annet er beviselig likt.
create function pg_temp.groundings(
  p_excerpt text default 'Weight change was the primary outcome.',
  p_locator text default 'Metode, avsnitt 2',
  p_justification text default 'Endepunktet er navngitt i metodeavsnittet.'
) returns jsonb language sql as $$
  select jsonb_build_array(
    pg_temp.grounding('intervention_arm', 'Patients received sertraline.',
      'Metode, avsnitt 1', 'Behandlingsarmen er navngitt i metodeavsnittet.'),
    pg_temp.grounding('outcome', p_excerpt, p_locator, p_justification),
    pg_temp.grounding('reported_direction', 'Weight increased from baseline.',
      'Resultater, avsnitt 1', 'Retningen står som en økning i resultatavsnittet.'),
    pg_temp.grounding('availability_semantics',
      'No sample size was reported for the weight analysis.',
      'Resultater, avsnitt 2', 'Feltene uten verdi er ført som ikke rapportert, som kilden sier.')
  );
$$;

-- Nøyaktig de samme strukturerte verdiene hver gang. Det eneste som varierer
-- mellom kallene, er forankringen — som er hele påstanden filen prøver.
create function pg_temp.extract(p_groundings jsonb) returns uuid language plpgsql as $$
declare
  v_secret text;
  v_run uuid;
begin
  select secret into v_secret from cred where label = 'extractor';
  select id into v_run from run where label = 'extraction';
  perform set_config('role', 'anon', true);
  return api.register_agent_extraction(
    p_identity_key => 'agent-identity:evidence-extraction-01',
    p_secret => v_secret,
    p_agent_run_id => v_run,
    p_source_id => '62000000-0000-4000-8000-000000000001',
    p_source_version_id => '62000000-0000-4000-8000-000000000021',
    p_design_code => 'randomized_controlled_trial',
    p_population_availability => 'not_reported',
    p_population_detail => 'Prøve i 620.',
    p_sample_size_availability => 'not_reported',
    p_intervention_drug_id => (select id from fixture where name = 'sertralin'),
    p_comparator_kind => 'none',
    p_outcome_concept_id => (select id from fixture where name = 'weight'),
    p_outcome_detail => 'Identitetsprøve, utfall.',
    p_timepoint_availability => 'not_reported',
    p_reported_direction => 'increase',
    p_estimate_availability => 'not_reported',
    p_confidence_interval_availability => 'not_reported',
    p_source_locator => 'Avsnitt for 620',
    p_extraction_method => 'ai_assisted',
    p_field_groundings => p_groundings,
    p_source_quote => 'Weight change was 1.7 kg in the sertraline arm.'
  );
end;
$$;

insert into registered (name, id) select 'original', pg_temp.extract(pg_temp.groundings());
reset role;

-- ===========================================================================
-- Del 5 — Den samme ekstraksjonen er fortsatt én rad
-- ===========================================================================
select throws_ok(
  $$select pg_temp.extract(pg_temp.groundings())$$,
  '23505',
  'Nøyaktig det samme evidensfunnet er allerede registrert.',
  'nøyaktig det samme forslaget avvises fortsatt som dublett'
);
reset role;

-- Og avvisningen navngir fortsatt riktig rad, slått opp med den identiteten
-- UNIQUE-regelen bruker — nå med forankringen i seg (migrasjon 007h).
create temporary table dublett (label text primary key, detail text) on commit drop;
do $$
declare v_detail text;
begin
  begin
    perform pg_temp.extract(pg_temp.groundings());
  exception when unique_violation then
    get stacked diagnostics v_detail = pg_exception_detail;
    insert into dublett (label, detail) values ('exact', v_detail);
  end;
end;
$$;
reset role;

select is(
  (select detail from dublett where label = 'exact'),
  (select 'evidence_item_id=' || id::text from registered where name = 'original'),
  'dublettavvisningen navngir fortsatt nøyaktig raden som kolliderte'
);

-- Rekkefølgen på forankringene i forslaget er ikke informasjon, og skal derfor
-- heller ikke lage en ny rad.
select throws_ok(
  $$
    select pg_temp.extract((
      select jsonb_agg(g.value order by g.ordinality desc)
      from jsonb_array_elements(pg_temp.groundings()) with ordinality as g(value, ordinality)))
  $$,
  '23505',
  'Nøyaktig det samme evidensfunnet er allerede registrert.',
  'den samme forankringen i motsatt rekkefølge er fortsatt den samme ekstraksjonen'
);
reset role;

-- ===========================================================================
-- Del 6 — En rettet forankring er et nytt evidensfunn
--
-- Kjernen i issue #66. De strukturerte verdiene er identiske i alle tre
-- tilfellene; det eneste som er rettet, er henholdsvis utdraget, kildepekeren
-- og begrunnelsen.
-- ===========================================================================
insert into registered (name, id)
select 'rettet_utdrag',
       pg_temp.extract(pg_temp.groundings(p_excerpt => 'Weight change was measured as the primary outcome.'));
reset role;

insert into registered (name, id)
select 'rettet_peker', pg_temp.extract(pg_temp.groundings(p_locator => 'Metode, avsnitt 3'));
reset role;

insert into registered (name, id)
select 'rettet_begrunnelse',
       pg_temp.extract(pg_temp.groundings(p_justification => 'Endepunktet står i metodeavsnittets andre setning.'));
reset role;

select is(
  (select count(*) from knowledge.evidence_items
   where source_id = '62000000-0000-4000-8000-000000000001'),
  4::bigint,
  'et rettet utdrag, en rettet peker og en rettet begrunnelse blir hvert sitt nye evidensfunn'
);

select is(
  (select count(distinct content_hash) from knowledge.evidence_items
   where source_id = '62000000-0000-4000-8000-000000000001'),
  4::bigint,
  'og de fire radene har hvert sitt fingeravtrykk'
);

-- De skiller seg *bare* i forankringen. Uten denne påstanden kunne testen over
-- holdt fordi noe annet også var ulikt.
select is(
  (select count(distinct (
     e.outcome_detail, e.source_locator, e.design_code, e.reported_direction,
     e.population_detail, e.raw_extraction))
   from knowledge.evidence_items e
   where e.source_id = '62000000-0000-4000-8000-000000000001'),
  1::bigint,
  'de fire radene har identiske strukturerte verdier'
);

select is(
  (select count(distinct grounding_digest) from knowledge.evidence_items
   where source_id = '62000000-0000-4000-8000-000000000001'),
  4::bigint,
  'og er skilt fra hverandre av forankringen alene'
);

-- Den gamle raden er uendret. Append-only er ikke bare en trigger: rettelsen
-- skal komme *ved siden av*, ikke i stedet for (ANTIDEP_CONSTITUTION.md §14).
select is(
  (select g.source_excerpt from knowledge.evidence_field_groundings g
   where g.evidence_item_id = (select id from registered where name = 'original')
     and g.check_field = 'outcome'),
  'Weight change was the primary outcome.',
  'det opprinnelige funnet står med sin opprinnelige forankring'
);

select is(
  (select e.grounding_digest from knowledge.evidence_items e
   where e.id = (select id from registered where name = 'original')),
  pg_temp.digest(pg_temp.groundings()),
  'og med avtrykket av nøyaktig den forankringen'
);

-- ===========================================================================
-- Del 7 — Avtrykket kan ikke lyve
--
-- Kontrollen er utsatt til commit, og pgTAP-filen commiter aldri. Den tvinges
-- derfor fram med `set constraints all immediate` inne i den samme setningen
-- som bruddet, slik at throws_ok fanger den.
-- ===========================================================================
select throws_ok(
  format(
    $$
      insert into knowledge.evidence_field_groundings
        (evidence_item_id, created_by_actor_id, check_field,
         source_excerpt, source_locator, justification)
      select %L::uuid, e.created_by_actor_id, 'population',
             'Forankring lagt til i etterkant', 'Side 9', 'Retroaktiv begrunnelse'
      from knowledge.evidence_items e where e.id = %L::uuid;
      set constraints all immediate;
    $$,
    (select id from registered where name = 'original'),
    (select id from registered where name = 'original')
  ),
  '23000',
  'Kildeforankringen på evidensfunnet stemmer ikke med avtrykket funnet er registrert med.',
  'en forankring lagt til på et allerede registrert funn avvises'
);

select is(
  (select count(*) from knowledge.evidence_field_groundings
   where source_excerpt = 'Forankring lagt til i etterkant'),
  0::bigint,
  'og etterlater ingenting'
);

select throws_ok(
  $$
    insert into knowledge.evidence_items (
      source_id, design_code, population_availability, population_detail,
      sample_size_availability, intervention_drug_id, comparator_kind,
      outcome_concept_id, outcome_detail, timepoint_availability,
      reported_direction, estimate_availability, confidence_interval_availability,
      source_locator, extraction_method, grounding_digest, created_by_actor_id)
    select '62000000-0000-4000-8000-000000000001', 'randomized_controlled_trial',
           'not_reported', 'Løgnprøve i 620.', 'not_reported',
           f.id, 'none', w.id, 'Løgnprøve, utfall.', 'not_reported', 'increase',
           'not_reported', 'not_reported', 'Avsnitt for løgnprøven', 'manual',
           knowledge.evidence_field_grounding_digest(
             jsonb_build_array(jsonb_build_object(
               'check_field', 'outcome', 'source_excerpt', 'Et utdrag som ikke er registrert',
               'source_locator', 'Side 1', 'justification', 'Fordi'))),
           (select id from fixture where name = 'editor')
    from fixture f, fixture w where f.name = 'sertralin' and w.name = 'weight';
    set constraints all immediate;
  $$,
  '23000',
  'Kildeforankringen på evidensfunnet stemmer ikke med avtrykket funnet er registrert med.',
  'et funn som oppgir et avtrykk uten å ha forankringen, avvises'
);

select throws_ok(
  $$
    insert into knowledge.evidence_items (
      source_id, design_code, population_availability, population_detail,
      sample_size_availability, intervention_drug_id, comparator_kind,
      outcome_concept_id, outcome_detail, timepoint_availability,
      reported_direction, estimate_availability, confidence_interval_availability,
      source_locator, extraction_method, grounding_digest, created_by_actor_id)
    select '62000000-0000-4000-8000-000000000001', 'randomized_controlled_trial',
           'not_reported', 'Formprøve i 620.', 'not_reported',
           f.id, 'none', w.id, 'Formprøve, utfall.', 'not_reported', 'increase',
           'not_reported', 'not_reported', 'Avsnitt for formprøven', 'manual',
           'ikke et avtrykk', (select id from fixture where name = 'editor')
    from fixture f, fixture w where f.name = 'sertralin' and w.name = 'weight'
  $$,
  '23514',
  null,
  'og et avtrykk som ikke har avtrykkets form, avvises av CHECK-en'
);

-- ===========================================================================
-- Del 8 — Gammel og ny rad har hver sin kontrollstatus
--
-- Det korrigerte funnet arver ingenting. Maskinbeviset gjelder den raden det
-- ble registrert på, og den nye må selv gjennom kontrollen før den kan brukes
-- i publisering (ANTIDEP_CONSTITUTION.md §11, §12).
-- ===========================================================================
set local role anon;
insert into run
select 'verification', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-14', p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('evidence_item_ids',
    array[(select id from registered where name = 'original')])
);

select lives_ok(
  $$
    select api.register_extraction_verification(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'verifier'),
      (select id from run where label = 'verification'),
      (select id from registered where name = 'original'),
      'uncertain', 'verifiable_representation',
      array['raw_extraction', 'source_locator'],
      'Prøve i 620: hvert forankret utdrag ble gjenfunnet ordrett i den reproduserte representasjonen.',
      'Tallene lot seg ikke bedømme maskinelt.')
  $$,
  'maskinkontrollen registreres på det opprinnelige funnet'
);
reset role;

select ok(
  workflow.grounding_machine_proved((select id from registered where name = 'original')),
  'og beviset gjelder det funnet'
);

select ok(
  not workflow.grounding_machine_proved((select id from registered where name = 'rettet_utdrag')),
  'det korrigerte funnet arver ikke maskinbeviset, og må kontrolleres selv'
);

select is(
  (select count(*) from workflow.evidence_verifications ev
   where ev.evidence_item_id = (select id from registered where name = 'rettet_utdrag')),
  0::bigint,
  'ingen kontroll er registrert på det korrigerte funnet'
);

select is(
  (select count(*) from knowledge.claim_evidence_links l
   where l.evidence_item_id in (
     select id from registered where name in
       ('rettet_utdrag', 'rettet_peker', 'rettet_begrunnelse'))),
  0::bigint,
  'og ingen claim-lenke følger med over på en korrigert rad'
);

-- ===========================================================================
-- Del 9 — Migrasjonen etterlot ingen halv tilstand
-- ===========================================================================
select is_empty(
  $$
    select e.id, e.grounding_digest
    from knowledge.evidence_items e
    where e.grounding_digest is distinct from knowledge.evidence_item_grounding_digest(e.id)
  $$,
  'hver rad bærer avtrykket av nøyaktig den forankringen som er registrert på den'
);

select is_empty(
  $$
    select id, content_hash from knowledge.evidence_items
    where content_hash is distinct from knowledge.evidence_item_content_hash(
      knowledge.evidence_items.*)
  $$,
  'og fingeravtrykket på hver rad er det den gjeldende definisjonen gir'
);

select * from finish();
rollback;
