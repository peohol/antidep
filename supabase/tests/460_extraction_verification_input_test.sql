-- Migrasjon 005h — lesegrunnlaget ekstraksjonsverifikatoren arbeider fra.
--
-- Motstykket til 440_extraction_verification_registration_test.sql: den filen
-- dekker skrivingen, denne dekker veien inn. ANTIDEP_CONSTITUTION.md §11 krever
-- at verifikatoren kontrollerer mot kildematerialet og ikke mot et annet ledds
-- sammendrag; uten en lesevei ville kravet vært umulig å oppfylle for en agent
-- som kaller Data API-et som `anon`.
--
-- Filen dekker fire ting: kontrakten (hva som er eksponert), autentiseringen
-- (rollen og den åpne kjøringen, gjennom selve funksjonen), innholdet (at
-- grunnlaget faktisk er med, og at det som ikke skal ut, ikke er med), og køens
-- to filtre (eget arbeid, og allerede utført kontroll).
--
-- SQLSTATE 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(37);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'extraction_verification_input', 'api.extraction_verification_input() finnes'
);
select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.extraction_verification_input(text,text,uuid,uuid)'::regprocedure),
  'api.extraction_verification_input() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
select is_empty(
  $$
    select r.role_name
    from (values ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.extraction_verification_input(text,text,uuid,uuid)'::regprocedure,
      'execute'
    )
  $$,
  'api.extraction_verification_input() er kjørbar for verken service_role eller PUBLIC'
);
select ok(
  has_function_privilege(
    'anon',
    'api.extraction_verification_input(text,text,uuid,uuid)'::regprocedure,
    'execute'
  ),
  'anon har EXECUTE — en agent har ingen brukerkonto og kaller som anon (migrasjon 005e)'
);
select ok(
  has_function_privilege(
    'authenticated',
    'api.extraction_verification_input(text,text,uuid,uuid)'::regprocedure,
    'execute'
  ),
  'authenticated har EXECUTE, av samme grunn som for api.begin_agent_run(...)'
);

-- Leseveien skal ikke ha gitt klientrollene bredere tilgang som bivirkning.
-- knowledge-tabellene har hatt SELECT for anon siden migrasjon 007, med RLS som
-- radgrense (del 7 prøver at grensen faktisk holder for radene her);
-- workflow.evidence_verifications har ingen grant i det hele tatt, og skal ikke
-- få en fordi en agent nå leser gjennom en funksjon.
select is_empty(
  $$
    select r.role_name, p.priv
    from (values ('anon'), ('authenticated'), ('public')) as r(role_name),
         (values ('select'), ('insert'), ('update'), ('delete')) as p(priv)
    where has_table_privilege(r.role_name, 'workflow.evidence_verifications', p.priv)
  $$,
  'anon, authenticated og public har fortsatt ingen tabellrettighet på workflow.evidence_verifications'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- Én kilde med to øyeblikksbilder (ett med fingeravtrykk, ett uten) og tre
-- evidensfunn: ett fra ekstraksjonsagenten som skal stå i køen, ett fra
-- verifikatoren selv som aldri kan stå der, og ett fra ekstraksjonsagenten som
-- gjøres ferdigkontrollert underveis.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;

insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'mirtazapin', id from catalog.drugs where canonical_name = 'mirtazapin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'population', id from catalog.populations where canonical_label = 'voksne med depressiv lidelse';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values (
  '46000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 460',
  'Testforfatter 460', (select id from fixture where name = 'editor')
);

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, external_version, content_hash,
  storage_reference, retrieved_by_actor_id
)
values (
  '46000000-0000-4000-8000-000000000021', '46000000-0000-4000-8000-000000000001',
  now() - interval '1 hour', 'https://example.test/460-kilde', 'utgave 1',
  knowledge.source_version_content_hash('representasjonen for 460'),
  'lagring://testbøtte/460.xml', (select id from fixture where name = 'extractor')
);

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_id, population_availability,
  population_detail, sample_size, sample_size_availability,
  intervention_drug_id, comparator_kind, comparator_drug_id,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, effect_measure, estimate, estimate_unit, estimate_availability,
  ci_lower, ci_upper, ci_level_percent, confidence_interval_availability,
  source_locator, extraction_method, raw_extraction, created_by_actor_id
)
values (
  -- I køen: laget av ekstraksjonsagenten, ikke kontrollert av noen.
  '46000000-0000-4000-8000-000000000011', '46000000-0000-4000-8000-000000000001',
  '46000000-0000-4000-8000-000000000021',
  'randomized_controlled_trial', (select id from fixture where name = 'population'),
  'reported_value', 'Voksne med depressiv lidelse i 460.', 120, 'reported_value',
  (select id from fixture where name = 'sertralin'), 'drug',
  (select id from fixture where name = 'mirtazapin'),
  (select id from fixture where name = 'weight'), 'Vektendring i 460.',
  -- Estimatet har flere signifikante siffer enn en IEEE-754 double rommer:
  -- kom det ut av api-funksjonen som et JSON-tall, ville det blitt avrundet
  -- til 1 i det klienten leste svaret, og kontrollen ville lett etter feil tall.
  'not_reported', 'increase', 'mean_change', 1.0000000000000000001, 'kg', 'reported_value',
  0.4, 2.6, 95, 'reported_value',
  'Sammendrag, avsnitt 2', 'ai_assisted',
  jsonb_build_object('sitat', 'Ordrett sitat fra kilden, for 460.'),
  (select id from fixture where name = 'extractor')
),
(
  -- Aldri i køen: verifikatoren kan ikke kontrollere sitt eget arbeid.
  '46000000-0000-4000-8000-000000000012', '46000000-0000-4000-8000-000000000001',
  '46000000-0000-4000-8000-000000000021',
  'randomized_controlled_trial', null, 'not_reported', 'Ikke beskrevet i 460.',
  null, 'not_reported',
  (select id from fixture where name = 'sertralin'), 'none', null,
  (select id from fixture where name = 'weight'), 'Funn laget av verifikatoren selv, for 460.',
  'not_reported', 'not_stated', null, null, null, 'not_reported',
  null, null, null, 'not_reported',
  'Sammendrag, avsnitt 3', 'ai_assisted', null,
  (select id from fixture where name = 'verifier')
),
(
  -- Uten registrert kildeversjon: skal stå i køen likevel, slik at fraværet er
  -- verifikatorens vurdering og ikke køens.
  '46000000-0000-4000-8000-000000000013', '46000000-0000-4000-8000-000000000001',
  null,
  'randomized_controlled_trial', null, 'not_reported', 'Ikke beskrevet i 460.',
  null, 'not_reported',
  (select id from fixture where name = 'sertralin'), 'none', null,
  (select id from fixture where name = 'weight'), 'Funn uten registrert kildeversjon, for 460.',
  'not_reported', 'not_stated', null, null, null, 'not_reported',
  null, null, null, 'not_reported',
  'Sammendrag, avsnitt 4', 'ai_assisted', null,
  (select id from fixture where name = 'extractor')
);

-- Kildeforankring for hvert semantisk felt. Fra migrasjon 005x kan en
-- bekreftelse ikke registreres på en rad uten den: da fantes det ingen
-- venstreside å ha kontrollert. Utdragene er syntetiske, som resten av
-- fiksturen — det som prøves her er leseflaten, ikke gjenfinningen.
insert into knowledge.evidence_field_groundings
  (evidence_item_id, created_by_actor_id, check_field,
   source_excerpt, source_locator, justification)
select e.id, e.created_by_actor_id, f.field,
       'Utdrag for ' || f.field::text || ' i 460.',
       'Avsnitt for ' || f.field::text,
       'Begrunnelse for ' || f.field::text || '.'
from knowledge.evidence_items e
cross join unnest(workflow.semantic_check_fields(e.id)) as f(field)
where e.source_id = '46000000-0000-4000-8000-000000000001';

create temporary table cred (label text primary key, secret text);
insert into cred
select 'verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman'
);
grant select on cred to anon;

create temporary table run (label text primary key, id uuid);
grant insert, select on run to anon;

create temporary table answer (label text primary key, payload jsonb);
grant insert, select on answer to anon;

set local role anon;
insert into run
select 'open', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-07', p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('mode', 'queue')
);
insert into run
select 'closed', api.begin_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_role := 'extraction_verification',
  p_provider := 'testleverandør', p_model := 'testmodell',
  p_model_version := '2026-09-07', p_prompt_template_version := 'extraction-verification/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('mode', 'queue')
);
select api.complete_agent_run(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_run_id := (select id from run where label = 'closed'),
  p_status := 'aborted',
  p_failure_reason := 'Prøve i 460: lukket med hensikt.'
);
reset role;

-- ===========================================================================
-- Del 3 — Autentiseringen, gjennom selve leseveien
-- ===========================================================================
set local role anon;
select throws_ok(
  $$
    select api.extraction_verification_input(
      'agent-identity:extraction-verification-01', 'feil hemmelighet',
      (select id from run where label = 'open')
    )
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'feil legitimasjon gir ingenting, og gir den samme avvisningen som alle andre'
);
select throws_ok(
  $$
    select api.extraction_verification_input(
      'agent-identity:finnes-ikke', 'hva som helst',
      (select id from run where label = 'open')
    )
  $$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'en ukjent identitet gir nøyaktig samme svar: flaten kan ikke brukes til å telle opp identiteter'
);
select throws_ok(
  $$
    select api.extraction_verification_input(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'verifier'),
      (select id from run where label = 'closed')
    )
  $$,
  '42501', 'Det finnes ingen åpen agentkjøring med denne identiteten.',
  'en avsluttet kjøring gir ingen lesing: grunnlaget leses inne i kjøringen som brukte det'
);
select throws_ok(
  $$
    select api.extraction_verification_input(
      'agent-identity:extraction-verification-01',
      (select secret from cred where label = 'verifier'),
      '46000000-0000-4000-8000-0000000000ff'
    )
  $$,
  '42501', 'Det finnes ingen åpen agentkjøring med denne identiteten.',
  'en kjøring som ikke finnes avvises på samme måte som en avsluttet'
);
reset role;

-- ===========================================================================
-- Del 4 — Køen
-- ===========================================================================
set local role anon;
insert into answer
select 'queue', api.extraction_verification_input(
  'agent-identity:extraction-verification-01',
  (select secret from cred where label = 'verifier'),
  (select id from run where label = 'open')
);
reset role;

select is(
  (select payload ->> 'verifier_actor_id' from answer where label = 'queue'),
  (select id::text from fixture where name = 'verifier'),
  'svaret navngir aktøren kjøringen tilhører, og ikke en aktør kalleren kunne bedt om'
);
-- Avgrenset til denne testens egen kilde. De to seedede funnene fra migrasjon
-- 003 står også i køen, og det er riktig: de er laget av ekstraksjonsagenten og
-- ikke kontrollert av noen. Å kreve at køen er tom for øvrig ville gjort testen
-- til en påstand om seeddata framfor om filteret.
select set_eq(
  $$
    select item ->> 'evidence_item_id'
    from answer, jsonb_array_elements(payload -> 'items') as item
    where label = 'queue'
      and item -> 'source' ->> 'source_id' = '46000000-0000-4000-8000-000000000001'
  $$,
  $$
    values ('46000000-0000-4000-8000-000000000011'),
           ('46000000-0000-4000-8000-000000000013')
  $$,
  'køen inneholder funnene verifikatoren kan kontrollere, og bare dem'
);
-- Den viktigste av de to: et funn verifikatoren selv har laget kan aldri
-- kontrolleres av den (evidence_verifications_separate_actor_check), så å ha det
-- i køen ville vært å be om et kall som må avvises.
select is_empty(
  $$
    select item ->> 'evidence_item_id'
    from answer, jsonb_array_elements(payload -> 'items') as item
    where label = 'queue'
      and item ->> 'evidence_item_id' = '46000000-0000-4000-8000-000000000012'
  $$,
  'verifikatorens eget arbeid står aldri i køen'
);

-- ===========================================================================
-- Del 5 — Innholdet: grunnlaget skal faktisk være med
-- ===========================================================================
create temporary view pg_temp.queued as
select item
from answer, jsonb_array_elements(payload -> 'items') as item
where label = 'queue'
  and item ->> 'evidence_item_id' = '46000000-0000-4000-8000-000000000011';

select is(
  (select item -> 'source_version' ->> 'retrieved_from' from pg_temp.queued),
  'https://example.test/460-kilde',
  'adressen representasjonen ble hentet fra er med: uten den kan ingen hente kilden på nytt'
);
select is(
  (select item -> 'source_version' ->> 'content_hash' from pg_temp.queued),
  knowledge.source_version_content_hash('representasjonen for 460'),
  'fingeravtrykket er med: uten det kan ingen se om kilden har endret seg'
);
select is(
  (select item -> 'source_version' ->> 'has_storage_reference' from pg_temp.queued),
  'true',
  'at det finnes en lagret kopi er synlig'
);
-- Selve adressen til den lagrede kopien er driftsinformasjon, som i
-- api.editor_source_versions. Verifikatoren trenger å vite at kopien finnes,
-- ikke hvor den ligger.
select is_empty(
  $$
    select 1 from pg_temp.queued
    where item::text like '%testbøtte%'
  $$,
  'adressen til den lagrede kopien er ikke eksponert, bare at den finnes'
);
select is(
  (select item -> 'extraction' -> 'raw_extraction' ->> 'sitat' from pg_temp.queued),
  'Ordrett sitat fra kilden, for 460.',
  'den rå ekstraksjonen er med ordrett: det er nettopp den som skal kontrolleres mot kilden'
);
select is(
  (select item -> 'extraction' ->> 'source_locator' from pg_temp.queued),
  'Sammendrag, avsnitt 2',
  'kildepekeren er med: en bekreftet ekstraksjon forutsetter at den selv er kontrollert'
);
select is(
  (select item -> 'extraction' ->> 'intervention_drug_name' from pg_temp.queued),
  'sertralin',
  'katalogetikettene er med, ikke bare identifikatorene: verifikatoren leser kilden på norsk'
);
select is(
  (select item -> 'extraction' ->> 'comparator_drug_name' from pg_temp.queued),
  'mirtazapin',
  'komparatoren er med når kontrasten er et virkestoff'
);
select is(
  (select item -> 'extraction' ->> 'outcome_label' from pg_temp.queued),
  'vektendring',
  'endepunktet er med som etikett'
);
select is(
  (select item -> 'extraction' ->> 'sample_size_availability' from pg_temp.queued),
  'reported_value',
  'availability-statusene er med: en verdi uten sin status er ikke kontrollerbar (ANTIDEP_CONSTITUTION.md §6)'
);
-- Kliniske tallverdier er `numeric` i basen, altså vilkårlig presise. Kom de
-- ut som JSON-tall, ville de blitt IEEE-754 doubles i det klienten leste
-- svaret — før noen linje i verifikatoren kjørte — og et estimat kunne blitt
-- bekreftet av den avrundede verdien framfor den registrerte. De serialiseres
-- derfor med ::text, slik timepoint_min/max alt gjorde.
select is(
  (select jsonb_typeof(item -> 'extraction' -> 'estimate')
       || ',' || jsonb_typeof(item -> 'extraction' -> 'ci_lower')
       || ',' || jsonb_typeof(item -> 'extraction' -> 'ci_upper')
       || ',' || jsonb_typeof(item -> 'extraction' -> 'ci_level_percent')
   from pg_temp.queued),
  'string,string,string,string',
  'kliniske tallverdier er tekst i svaret, ikke JSON-tall som ville blitt avrundet av klienten'
);
select is(
  (select item -> 'extraction' ->> 'estimate' from pg_temp.queued),
  '1.0000000000000000001',
  'estimatet beholder hvert siffer: en double ville gjort dette til 1'
);

select is(
  (select item ->> 'created_by_actor_key' from pg_temp.queued),
  'agent:evidence-extraction',
  'hvem som laget ekstraksjonen er med, slik at verifikatoren ser at det ikke er den selv'
);
select is(
  (select item ->> 'verifications_by_this_actor' from pg_temp.queued),
  '0',
  'antall egne kontroller er med, og er null før den første'
);

-- Et funn uten registrert kildeversjon skal ha `null` og ikke et tomt objekt:
-- fraværet er en opplysning verifikatoren skal handle på.
select is(
  (select item -> 'source_version'
   from answer, jsonb_array_elements(payload -> 'items') as item
   where label = 'queue'
     and item ->> 'evidence_item_id' = '46000000-0000-4000-8000-000000000013'),
  'null'::jsonb,
  'et funn uten registrert kildeversjon svarer null, ikke et tomt objekt'
);

-- ===========================================================================
-- Del 6 — Oppslag på ett funn, og køen etter en registrert kontroll
-- ===========================================================================
set local role anon;
insert into answer
select 'single', api.extraction_verification_input(
  'agent-identity:extraction-verification-01',
  (select secret from cred where label = 'verifier'),
  (select id from run where label = 'open'),
  '46000000-0000-4000-8000-000000000012'
);
reset role;

-- Et direkte oppslag er ikke køen: også et funn verifikatoren selv har laget
-- kan slås opp. Det gir ingen ny rettighet — skriveveien avviser det uansett —
-- men et oppslag som løy om hva som finnes, ville vært verre enn et som ikke
-- fantes.
select is(
  (select jsonb_array_length(payload -> 'items') from answer where label = 'single'),
  1,
  'et direkte oppslag svarer om nøyaktig det funnet det spør om'
);

set local role anon;
select api.register_extraction_verification(
  p_identity_key := 'agent-identity:extraction-verification-01',
  p_secret := (select secret from cred where label = 'verifier'),
  p_agent_run_id := (select id from run where label = 'open'),
  p_evidence_item_id := '46000000-0000-4000-8000-000000000011',
  p_outcome := 'verified',
  p_source_access := 'verifiable_representation',
  p_checked_fields := array['source_locator', 'outcome', 'reported_direction'],
  p_rationale := 'Prøve i 460: kontrollert mot kildeversjonens adresse og fingeravtrykk.'
);
insert into answer
select 'after', api.extraction_verification_input(
  'agent-identity:extraction-verification-01',
  (select secret from cred where label = 'verifier'),
  (select id from run where label = 'open')
);
reset role;

select set_eq(
  $$
    select item ->> 'evidence_item_id'
    from answer, jsonb_array_elements(payload -> 'items') as item
    where label = 'after'
      and item -> 'source' ->> 'source_id' = '46000000-0000-4000-8000-000000000001'
  $$,
  $$values ('46000000-0000-4000-8000-000000000013')$$,
  'et funn denne verifikatoren har kontrollert, står ikke lenger i køen'
);

set local role anon;
insert into answer
select 'recheck', api.extraction_verification_input(
  'agent-identity:extraction-verification-01',
  (select secret from cred where label = 'verifier'),
  (select id from run where label = 'open'),
  '46000000-0000-4000-8000-000000000011'
);
reset role;

-- En ny kontroll av et allerede kontrollert funn er en legitim operasjon og en
-- ny rad (workflow.evidence_verifications er append-only). Oppslaget skal
-- derfor svare, selv om køen ikke lenger gjør det.
select is(
  (select payload -> 'items' -> 0 ->> 'verifications_by_this_actor'
   from answer where label = 'recheck'),
  '1',
  'et direkte oppslag svarer også om et kontrollert funn, og teller kontrollene'
);

-- ===========================================================================
-- Del 7 — Radgrensen holder utenom funksjonen
--
-- knowledge-tabellene har SELECT for anon (migrasjon 007) fordi de ligger under
-- api-viewene, men anon har ingen USAGE på selve schemaet: et direkte oppslag
-- stoppes før RLS i det hele tatt kommer til. En agentkjører kan altså ikke
-- omgå funksjonen og lese grunnlaget selv, og det er den kontrollen som gjør
-- «legitimasjonen er kontrollen» til noe mer enn en formulering.
-- ===========================================================================
set local role anon;
select throws_ok(
  $$select id from knowledge.evidence_items
    where source_id = '46000000-0000-4000-8000-000000000001'$$,
  '42501', 'permission denied for schema knowledge',
  'en agentkjører som prøver å lese tabellen direkte som anon, kommer ikke inn i schemaet i det hele tatt'
);
select throws_ok(
  $$select id from knowledge.source_versions
    where source_id = '46000000-0000-4000-8000-000000000001'$$,
  '42501', 'permission denied for schema knowledge',
  'det samme gjelder kildeversjonene: grunnlaget nås bare gjennom funksjonen'
);
reset role;

-- ----------------------------------------------------------------------------
-- Kravet publiseringsgaten stiller, utledet av raden selv
--
-- Den deterministiske kontrollen bedømmer en delmengde av feltene, og
-- `checked_fields` sier hvilken. Gaten leser nå det samme vokabularet
-- (migrasjon 20260907093000), så de to lagene må være enige om hva raden
-- faktisk påstår noe om.
-- ----------------------------------------------------------------------------
select set_eq(
  $$select unnest(workflow.required_check_fields(
      '46000000-0000-4000-8000-000000000011'))::text$$,
  $$values ('raw_extraction'), ('source_locator'), ('intervention_arm'), ('outcome'),
           ('reported_direction'), ('availability_semantics'), ('effect_measure'),
           ('comparator_arm'), ('population'), ('sample_size'), ('estimate'),
           ('confidence_interval')$$,
  'kravet dekker nøyaktig det raden påstår noe om'
);

-- Tidspunktet er ført som ikke rapportert, og raden påstår da ingenting om
-- det. Forbehold er ikke oppgitt. Ingen av dem kreves kontrollert — men *at*
-- de står som ikke rapportert, dekkes av availability_semantics.
select ok(
  not ('timepoint' = any (workflow.required_check_fields(
    '46000000-0000-4000-8000-000000000011'))),
  'et tidspunkt som ikke er rapportert, kreves ikke kontrollert'
);
select ok(
  not ('limitations' = any (workflow.required_check_fields(
    '46000000-0000-4000-8000-000000000011'))),
  'forbehold som ikke er oppgitt, kreves ikke kontrollert'
);

-- Feltene den deterministiske kontrollen kan føre opp, er en ekte delmengde av
-- kravet. Det er hele grunnen til at gaten ikke kan nøye seg med `outcome`.
select ok(
  exists (
    select 1
    from unnest(workflow.required_check_fields(
      '46000000-0000-4000-8000-000000000011')) as required(field)
    where required.field <> all (array[
      'raw_extraction', 'source_locator', 'intervention_arm', 'outcome',
      'comparator_arm', 'population', 'sample_size', 'estimate',
      'confidence_interval'
    ]::workflow.evidence_check_field[])
  ),
  'den deterministiske kontrollen kan aldri alene dekke kravet'
);

select * from finish();
rollback;
