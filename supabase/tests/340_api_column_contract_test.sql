-- Kolonnekontrakten i api, kontrollert mot databasen.
--
-- MVP_IMPLEMENTATION_PLAN.md §74.7 har ført det som gjeld siden migrasjon 007:
-- radtypene i `src/types/api.ts` er håndskrevne påstander om `api`, og en
-- kolonne som skifter navn, endrer type eller blir nullbar gjør dem usanne uten
-- at noe feiler. Vokabularhalvdelen ble lukket i `tests/api-vocabularies.test.ts`;
-- kolonnenavn, kolonnetyper og nullbarhet stod igjen.
--
-- Kontrakten er erklært nøyaktig ett sted — `contract`-tabellen under — og
-- kontrolleres derfra i to retninger, i hver sin CI-jobb:
--
--   denne filen              kontrakten mot den kjørende databasen
--   tests/api-columns.test.ts  kontrakten mot radtypene i src/types/api.ts
--
-- Den TypeScript-siden leser `values`-listen under ut av denne filen. Uten den
-- lenken ville de to halvdelene vært to uavhengige påstander, og typene ville
-- fortsatt ikke vært bundet til databasen. Endres formatet på listen, må
-- parseren der endres med — den krever at hver rad lar seg lese, og kaster
-- framfor å hoppe over en rad den ikke forstår.
--
-- ----------------------------------------------------------------------------
-- Hvorfor nullbarheten måles og ikke leses
--
-- `information_schema.columns` rapporterer `is_nullable = 'YES'` for *hver*
-- kolonne i et view: PostgreSQL gjør ingen nullbarhetsanalyse gjennom views.
-- Kolonnenavn og kolonnetyper kan leses derfra; nullbarhet kan ikke. Begge
-- begrensningene er festet som egne assertions under, slik at de ikke blir en
-- kommentar ingen kontrollerer — og slik at kontrollen sier fra dersom en
-- framtidig PostgreSQL-versjon skulle begynne å svare presist.
--
-- Nullbarheten måles derfor på faktiske rader. Filen publiserer sitt eget
-- innhold inne i transaksjonen og ruller alt tilbake, på samme måte som 260 og
-- 290, i tre former valgt for å spenne ut kontrakten:
--
--   rik      hver valgfri verdi er utfylt, og ekstraksjonen trekkes tilbake
--            etter publisering, slik at tilbaketrekkingskolonnene bærer verdi
--   minimal  hver valgfri verdi er utelatt, på påstand, evidensfunn og kilde
--   peker    publiseringspekeren flyttes utenom den kontrollerte operasjonen,
--            som er den dokumenterte grunnen til at published_at og
--            last_reviewed_at kan være NULL
--
-- De to viewene fra migrasjon 007b projiserer ikke publisert innhold, men
-- kallerens eget, og de er lesbare for authenticated og ikke for anon. Formene
-- deres er derfor en egenskap ved *kalleren* og ikke ved innholdet:
--
--   kaller med aktør      en aktør som ikke er trukket tilbake, med to
--                         tildelinger — én uavgrenset og uten sluttdato, én
--                         avgrenset og med planlagt utløp
--   tilbaketrukket kaller en aktør som er tatt ut av bruk, slik at retired_at
--                         bærer verdi i minst én probe-rad
--
-- Fordi de to formene krever hver sin innloggede kaller, kan ikke alle cellene
-- leses i én spørring. Radene materialiseres derfor i en temptabell under den
-- klientrollen som faktisk skal kunne lese dem, og sammenlignes etterpå. Det er
-- en innstramming og ikke en lettelse: før ble cellene lest av en set_eq som
-- tilfeldigvis kjørte som anon, nå står det eksplisitt hvilken rolle og hvilket
-- token hver enkelt celle ble lest med.
--
-- Påstanden som kontrolleres er nøyaktig denne, i begge retninger:
--
--   en kolonne merket nullbar i kontrakten er NULL i minst én av probe-radene
--   en kolonne merket ikke-nullbar er NULL i ingen av dem
--
-- Den andre retningen er den som fanger «kolonnen ble nullbar»: en join som
-- gjøres om til en LEFT JOIN, et uttrykk som endres, eller en kolonne som
-- projiseres fra et annet sted, slår ut i den minimale raden.
--
-- Det den *ikke* fanger, står i §74.19 og som en innstrammet gjeldspost i
-- §74.7: en basiskolonne som stille mister sin NOT NULL. Fiksturen setter den
-- fortsatt, fordi insert-setningen navngir den, og probe-raden ville sett lik
-- ut. Kolonnenavn og kolonnetyper er derimot uttømmende dekket.
--
-- SQLSTATE 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(21);

-- ===========================================================================
-- Del 1 — Kontrakten
--
-- Én rad per kolonne i api: view, kolonnenavn, SQL-type slik format_type()
-- skriver den, og om kolonnen kan være NULL.
--
-- Typen er hentet fra pg_attribute og ikke fra information_schema.columns.
-- Sistnevnte kollapser hver array-type til 'ARRAY' og taper elementtypen, som
-- er nettopp det TypeScript-siden må vite for å skille `string[]` fra `number[]`.
-- ===========================================================================
create temporary table contract (
  view_name   text not null,
  column_name text not null,
  sql_type    text not null,
  nullable    boolean not null,
  primary key (view_name, column_name)
) on commit drop;

insert into contract (view_name, column_name, sql_type, nullable) values
  ('published_drugs', 'drug_id', 'uuid', false),
  ('published_drugs', 'canonical_name', 'text', false),

  ('published_drugs', 'status', 'text', false),
  ('published_drugs', 'atc_codes', 'text[]', true),
  ('published_drugs', 'published_claim_count', 'bigint', false),

  ('published_claims', 'claim_id', 'uuid', false),
  ('published_claims', 'claim_revision_id', 'uuid', false),
  ('published_claims', 'revision_number', 'integer', false),
  ('published_claims', 'knowledge_type', 'text', false),
  ('published_claims', 'drug_id', 'uuid', false),
  ('published_claims', 'drug_name', 'text', false),
  ('published_claims', 'topic_concept_id', 'uuid', false),
  ('published_claims', 'topic_label', 'text', false),
  ('published_claims', 'statement', 'text', false),
  ('published_claims', 'scope', 'text', false),
  ('published_claims', 'population_id', 'uuid', true),
  ('published_claims', 'population_label', 'text', true),
  ('published_claims', 'timeframe_min', 'interval', true),
  ('published_claims', 'timeframe_max', 'interval', true),
  ('published_claims', 'comparator_kind', 'text', false),
  ('published_claims', 'comparator_drug_id', 'uuid', true),
  ('published_claims', 'comparator_drug_name', 'text', true),
  ('published_claims', 'direction', 'text', true),
  ('published_claims', 'magnitude_measure', 'text', true),
  ('published_claims', 'magnitude_value', 'numeric', true),
  ('published_claims', 'magnitude_unit', 'text', true),
  ('published_claims', 'qualifiers', 'text', true),
  ('published_claims', 'uncertainty_summary', 'text', true),
  ('published_claims', 'certainty_framework', 'text', true),
  ('published_claims', 'certainty_level', 'text', true),
  ('published_claims', 'certainty_rationale', 'text', true),
  ('published_claims', 'evidence_gap', 'text', true),
  ('published_claims', 'last_assessed_at', 'timestamp with time zone', true),
  ('published_claims', 'withdrawn_evidence_count', 'bigint', false),
  ('published_claims', 'content_hash', 'text', false),
  ('published_claims', 'revision_created_at', 'timestamp with time zone', false),
  ('published_claims', 'published_at', 'timestamp with time zone', true),
  ('published_claims', 'last_reviewed_at', 'timestamp with time zone', true),

  ('published_claim_evidence', 'claim_id', 'uuid', false),
  ('published_claim_evidence', 'claim_revision_id', 'uuid', false),
  ('published_claim_evidence', 'claim_evidence_link_id', 'uuid', false),
  ('published_claim_evidence', 'relationship_type', 'text', false),
  ('published_claim_evidence', 'directness', 'text', false),
  ('published_claim_evidence', 'relevance_note', 'text', false),
  ('published_claim_evidence', 'evidence_item_id', 'uuid', false),
  ('published_claim_evidence', 'study_design', 'text', false),
  ('published_claim_evidence', 'population_id', 'uuid', true),
  ('published_claim_evidence', 'population_label', 'text', true),
  ('published_claim_evidence', 'population_detail', 'text', false),
  ('published_claim_evidence', 'population_availability', 'text', false),
  ('published_claim_evidence', 'sample_size', 'integer', true),
  ('published_claim_evidence', 'sample_size_availability', 'text', false),
  ('published_claim_evidence', 'intervention_drug_id', 'uuid', false),
  ('published_claim_evidence', 'intervention_drug_name', 'text', false),
  ('published_claim_evidence', 'intervention_detail', 'text', true),
  ('published_claim_evidence', 'comparator_kind', 'text', false),
  ('published_claim_evidence', 'comparator_drug_id', 'uuid', true),
  ('published_claim_evidence', 'comparator_drug_name', 'text', true),
  ('published_claim_evidence', 'comparator_detail', 'text', true),
  ('published_claim_evidence', 'outcome_concept_id', 'uuid', false),
  ('published_claim_evidence', 'outcome_label', 'text', false),
  ('published_claim_evidence', 'outcome_detail', 'text', false),
  ('published_claim_evidence', 'timepoint_min', 'interval', true),
  ('published_claim_evidence', 'timepoint_max', 'interval', true),
  ('published_claim_evidence', 'timepoint_availability', 'text', false),
  ('published_claim_evidence', 'reported_direction', 'text', false),
  ('published_claim_evidence', 'effect_measure', 'text', true),
  ('published_claim_evidence', 'estimate', 'numeric', true),
  ('published_claim_evidence', 'estimate_unit', 'text', true),
  ('published_claim_evidence', 'estimate_availability', 'text', false),
  ('published_claim_evidence', 'ci_lower', 'numeric', true),
  ('published_claim_evidence', 'ci_upper', 'numeric', true),
  ('published_claim_evidence', 'ci_level_percent', 'numeric', true),
  ('published_claim_evidence', 'confidence_interval_availability', 'text', false),
  ('published_claim_evidence', 'limitations_text', 'text', true),
  ('published_claim_evidence', 'source_locator', 'text', false),
  ('published_claim_evidence', 'extraction_withdrawn', 'boolean', false),
  ('published_claim_evidence', 'extraction_withdrawn_at', 'timestamp with time zone', true),
  ('published_claim_evidence', 'extraction_withdrawal_rationale', 'text', true),
  ('published_claim_evidence', 'source_version_id', 'uuid', true),
  ('published_claim_evidence', 'source_version_retrieved_at', 'timestamp with time zone', true),
  ('published_claim_evidence', 'source_version_retrieved_from', 'text', true),
  ('published_claim_evidence', 'source_version_external_version', 'text', true),
  ('published_claim_evidence', 'source_version_content_hash', 'text', true),
  ('published_claim_evidence', 'source_id', 'uuid', false),
  ('published_claim_evidence', 'source_type', 'text', false),
  ('published_claim_evidence', 'source_title', 'text', false),
  ('published_claim_evidence', 'source_authors_or_issuer', 'text', false),
  ('published_claim_evidence', 'source_publisher_or_journal', 'text', true),
  ('published_claim_evidence', 'source_publication_date', 'date', true),
  ('published_claim_evidence', 'source_publication_date_precision', 'text', true),
  ('published_claim_evidence', 'source_status', 'text', false),
  ('published_claim_evidence', 'source_status_note', 'text', true),
  ('published_claim_evidence', 'source_dois', 'text[]', true),
  ('published_claim_evidence', 'source_pmids', 'text[]', true),

  ('my_actor', 'actor_id', 'uuid', false),
  ('my_actor', 'actor_key', 'text', false),
  ('my_actor', 'display_name', 'text', false),
  ('my_actor', 'retired_at', 'timestamp with time zone', true),

  ('my_roles', 'role_code', 'text', false),
  ('my_roles', 'scope_id', 'uuid', true),
  ('my_roles', 'scope_type', 'text', true),
  ('my_roles', 'valid_from', 'timestamp with time zone', false),
  ('my_roles', 'valid_to', 'timestamp with time zone', true),

  ('editor_sources', 'source_id', 'uuid', false),
  ('editor_sources', 'source_type', 'text', false),
  ('editor_sources', 'title', 'text', false),
  ('editor_sources', 'authors_or_issuer', 'text', false),
  ('editor_sources', 'publisher_or_journal', 'text', true),
  ('editor_sources', 'publication_date', 'date', true),
  ('editor_sources', 'publication_date_precision', 'text', true),
  ('editor_sources', 'source_status', 'text', false),
  ('editor_sources', 'status_note', 'text', true),

  ('editor_source_versions', 'source_version_id', 'uuid', false),
  ('editor_source_versions', 'source_id', 'uuid', false),
  ('editor_source_versions', 'retrieved_at', 'timestamp with time zone', false),
  ('editor_source_versions', 'retrieved_from', 'text', false),
  ('editor_source_versions', 'external_version', 'text', true),
  ('editor_source_versions', 'content_hash', 'text', true),
  ('editor_source_versions', 'representation', 'text', true),
  ('editor_source_versions', 'document_sha256', 'text', true),
  ('editor_source_versions', 'document_byte_size', 'bigint', true),
  ('editor_source_versions', 'document_media_type', 'text', true),
  ('editor_source_versions', 'text_extraction_tool', 'text', true),
  ('editor_source_versions', 'text_extraction_tool_version', 'text', true),
  ('editor_source_versions', 'text_extraction_arguments', 'text', true),

  ('editor_drugs', 'drug_id', 'uuid', false),
  ('editor_drugs', 'canonical_name', 'text', false),
  ('editor_drugs', 'status', 'text', false),

  ('editor_outcomes', 'outcome_concept_id', 'uuid', false),
  ('editor_outcomes', 'canonical_label', 'text', false),
  ('editor_outcomes', 'status', 'text', false),

  ('editor_populations', 'population_id', 'uuid', false),
  ('editor_populations', 'canonical_label', 'text', false),
  ('editor_populations', 'status', 'text', false),

  ('editor_evidence_items', 'evidence_item_id', 'uuid', false),
  ('editor_evidence_items', 'source_id', 'uuid', false),
  ('editor_evidence_items', 'source_title', 'text', false),
  ('editor_evidence_items', 'source_version_id', 'uuid', true),
  ('editor_evidence_items', 'study_design', 'text', false),
  ('editor_evidence_items', 'intervention_drug_id', 'uuid', false),
  ('editor_evidence_items', 'intervention_drug_name', 'text', false),
  ('editor_evidence_items', 'comparator_kind', 'text', false),
  ('editor_evidence_items', 'comparator_drug_id', 'uuid', true),
  ('editor_evidence_items', 'comparator_drug_name', 'text', true),
  ('editor_evidence_items', 'outcome_label', 'text', false),
  ('editor_evidence_items', 'outcome_detail', 'text', false),
  ('editor_evidence_items', 'reported_direction', 'text', false),
  ('editor_evidence_items', 'source_locator', 'text', false),
  ('editor_evidence_items', 'extraction_method', 'text', false),
  ('editor_evidence_items', 'created_at', 'timestamp with time zone', false);

-- ===========================================================================
-- Del 2 — De to begrensningene i information_schema, festet som assertions
-- ===========================================================================

-- Dette er grunnen til at nullbarheten måles på rader lenger nede. Skulle en
-- framtidig PostgreSQL-versjon begynne å svare presist, feiler denne, og da er
-- probe-fiksturen ikke lenger den eneste veien.
select is_empty(
  $$
    select table_name, column_name, is_nullable
    from information_schema.columns
    where table_schema = 'api'
      and is_nullable <> 'YES'
  $$,
  'information_schema.columns sier YES om nullbarhet for hver kolonne i api, og kan ikke bære kontraktens nullbarhetspåstand'
);

-- Og dette er grunnen til at typen leses med format_type(): elementtypen i en
-- array finnes ikke i information_schema.columns.data_type.
select set_eq(
  $$
    select ic.table_name || '.' || ic.column_name
    from information_schema.columns ic
    where ic.table_schema = 'api'
      and ic.data_type = 'ARRAY'
  $$,
  $$
    values ('published_claim_evidence.source_dois'),
           ('published_claim_evidence.source_pmids'),
           ('published_drugs.atc_codes')
  $$,
  'information_schema.columns kollapser hver array-kolonne i api til ARRAY og taper elementtypen'
);

-- ===========================================================================
-- Del 3 — Kontrakten mot katalogen: navn og typer, uttømmende
--
-- Et nytt view i api, en ny kolonne, en fjernet kolonne, et endret navn eller
-- en endret type gir alle utslag her. Sammenligningen går begge veier, så
-- kontrakten kan verken være for kort eller for lang.
-- ===========================================================================
select set_eq(
  $$
    select c.relname::text, a.attname::text, format_type(a.atttypid, a.atttypmod)
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
    where n.nspname = 'api'
      and c.relkind = 'v'
      and a.attnum > 0
      and not a.attisdropped
  $$,
  $$select view_name, column_name, sql_type from contract$$,
  'kontrakten navngir nøyaktig kolonnene og typene api faktisk har'
);

-- ===========================================================================
-- Del 4 — Probe-innholdet
--
-- Testinnhold som ruller tilbake. Godkjenningen utføres her, av en aktør som
-- opprettes her, slik at ingen fiktiv godkjenning blir stående i databasen
-- (ANTIDEP_CONSTITUTION.md §12).
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;

insert into auth.users (id, email) values
  ('e3a40000-0000-4000-8000-000000000001', 'reviewer-340@test.invalid'),
  ('e3a40000-0000-4000-8000-000000000002', 'publisher-340@test.invalid'),
  ('e3a40000-0000-4000-8000-000000000003', 'verifier-340@test.invalid'),
  -- Bare for api.my_actor: uten en tilbaketrukket aktør ville retired_at aldri
  -- båret verdi i noen probe-rad, og nullbarhetspåstanden vært uten dekning.
  ('e3a40000-0000-4000-8000-000000000004', 'retired-340@test.invalid');

insert into provenance.actors (actor_type, actor_key, display_name, description, auth_user_id)
values
  ('human', 'human:reviewer-340', 'Reviewer', 'Kvalifisert redaktør for testene i 340.',
   'e3a40000-0000-4000-8000-000000000001'),
  ('human', 'human:publisher-340', 'Publisher', 'Utfører publiseringen i testene i 340.',
   'e3a40000-0000-4000-8000-000000000002'),
  ('human', 'human:verifier-340', 'Verifikator', 'Utfører verifikasjonene i testene i 340.',
   'e3a40000-0000-4000-8000-000000000003');

insert into provenance.actors
  (actor_type, actor_key, display_name, description, auth_user_id,
   retired_at, retirement_note)
values
  ('human', 'human:retired-340', 'Tilbaketrukket aktør',
   'Aktør som er tatt ut av bruk, for probe-raden i api.my_actor.',
   'e3a40000-0000-4000-8000-000000000004',
   now() - interval '10 days', 'Tatt ut av bruk for testene i 340.');

insert into fixture (name, id)
select 'reviewer', id from provenance.actors where actor_key = 'human:reviewer-340';
insert into fixture (name, id)
select 'publisher', id from provenance.actors where actor_key = 'human:publisher-340';
insert into fixture (name, id)
select 'verifier', id from provenance.actors where actor_key = 'human:verifier-340';
insert into fixture (name, id)
select 'synthesis', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id)
select 'extraction', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id)
select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'population', id from catalog.populations
where canonical_label = 'voksne med depressiv lidelse';
insert into fixture (name, id)
select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id)
select 'mirtazapin', id from catalog.drugs where canonical_name = 'mirtazapin';

-- Rolletildelingene må ha eksistert før beslutningene som viser til dem
-- (workflow.enforce_reviewer_qualification()).
alter table workflow.user_roles disable trigger user_roles_set_row_timestamps;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason, created_at)
values
  ('e3a40000-0000-4000-8000-000000000001', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'verifier'), 'Reviewrett for testene i 340.',
   now() - interval '1 year'),
  ('e3a40000-0000-4000-8000-000000000002', 'publisher', null, now() - interval '1 year',
   (select id from fixture where name = 'verifier'), 'Publiseringsrett for testene i 340.',
   now() - interval '1 year'),
  -- Verifikatoren trenger selv reviewer-rollen fra og med migrasjon 005j: en
  -- claim-verifikasjon krever mandat, og for et menneske er mandatet
  -- reviewer-rollen for innholdsområdet (MVP_IMPLEMENTATION_PLAN.md §74.30 punkt 3).
  ('e3a40000-0000-4000-8000-000000000003', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'reviewer'), 'Reviewrett for verifikatoren i 340.',
   now() - interval '1 year');
alter table workflow.user_roles enable trigger user_roles_set_row_timestamps;

-- Bare for api.my_roles. Den uavgrensede reviewer-tildelingen over dekker
-- scope_id, scope_type og valid_to som NULL; denne dekker dem som utfylt. En
-- planlagt utløpsdato satt allerede ved tildeling må oppgi hvem som satte den
-- og hvorfor (user_roles_end_actor_pairing_check).
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to,
   granted_by_actor_id, grant_reason, ended_by_actor_id, end_reason)
values
  ('e3a40000-0000-4000-8000-000000000001', 'editor',
   (select id from fixture where name = 'topic'),
   now() - interval '1 year', now() + interval '1 year',
   (select id from fixture where name = 'verifier'),
   'Avgrenset redigeringsrett med planlagt utløp, for kolonnekontrakten i 340.',
   (select id from fixture where name = 'verifier'),
   'Planlagt utløp satt ved tildeling.');

-- Et virkestoff uten ATC-kode. Begge de seedede har en, og uten dette ville
-- api.published_drugs.atc_codes aldri vært NULL i noen probe-rad.
with inserted as (
  insert into catalog.drugs (canonical_name, status)
  values ('testvirkestoff-340', 'active')
  returning id
)
insert into fixture (name, id) select 'plain_drug', id from inserted;

-- ---------------------------------------------------------------------------
-- Den rike påstanden: hver valgfri kolonne er utfylt
-- ---------------------------------------------------------------------------
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'sertralin' and a.name = 'synthesis'
  returning id
)
insert into fixture (name, id) select 'rich_claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, population_id, timeframe_min, timeframe_max,
    comparator_kind, comparator_drug_id, direction,
    magnitude_measure, magnitude_value, magnitude_unit,
    qualifiers, uncertainty_summary, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Rik testpåstand for kolonnekontrakten i 340.',
         'Gjelder bare testene i denne filen.',
         (select id from fixture where name = 'population'),
         interval '8 weeks', interval '12 weeks',
         'drug', (select id from fixture where name = 'mirtazapin'), 'increase',
         'mean_difference', 1.7, 'kg',
         'Gjelder bare testinnhold.', 'Testusikkerhet.', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'rich_claim')
  returning id
)
insert into fixture (name, id) select 'rich_rev', id from inserted;

-- Kilden er outdated og ikke superseded: begge krever et status_note, men
-- superseded krever i tillegg en peker til etterfølgeren, og withdrawn og
-- retracted blokkeres av publiseringsgaten G7.
with inserted as (
  insert into knowledge.sources
    (source_type, title, authors_or_issuer, publisher_or_journal,
     publication_date, publication_date_precision, source_status, status_note,
     created_by_actor_id)
  values ('journal_article', 'Rik testkilde for 340', 'Testforfatter A; Testforfatter B',
          'Testtidsskriftet', date '2024-03-01', 'month', 'outdated',
          'Nyere testkunnskap finnes.', (select id from fixture where name = 'extraction'))
  returning id
)
insert into fixture (name, id) select 'rich_source', id from inserted;

insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
values ((select id from fixture where name = 'rich_source'), 'doi', '10.1000/antidep-340'),
       ((select id from fixture where name = 'rich_source'), 'pmid', '39000340');

-- Den rike versjonen er dokumentutledet: den bærer representasjonstypen, hele
-- dokumentbindingen og oppskriften teksten ble hentet ut med (migrasjon 003e).
-- Uten en slik rad ville de sju kolonnene aldri båret en verdi i noen probe-rad,
-- og kontrollen «hver kolonne bærer en verdi et sted» ville stått uten dekning.
with inserted as (
  insert into knowledge.source_versions
    (source_id, retrieved_at, retrieved_from, external_version, content_hash,
     representation, retrieved_by_actor_id,
     document_sha256, document_byte_size, document_media_type,
     text_extraction_tool, text_extraction_tool_version, text_extraction_arguments)
  values ((select id from fixture where name = 'rich_source'), now() - interval '10 days',
          'https://eksempel.invalid/340', 'v2', 'sha256:' || repeat('a', 64),
          'full_text', (select id from fixture where name = 'extraction'),
          'sha256:' || repeat('b', 64), 481253, 'application/pdf',
          'pdftotext', 'pdftotext 24.02.0', '-layout -enc UTF-8 -eol unix')
  returning id
)
insert into fixture (name, id) select 'rich_version', id from inserted;

with inserted as (
  insert into knowledge.evidence_items (
    source_id, source_version_id, design_code,
    population_id, population_availability, population_detail,
    sample_size, sample_size_availability,
    intervention_drug_id, intervention_detail,
    comparator_kind, comparator_drug_id, comparator_detail,
    outcome_concept_id, outcome_detail,
    timepoint_min, timepoint_max, timepoint_availability,
    reported_direction, effect_measure, estimate, estimate_unit, estimate_availability,
    ci_lower, ci_upper, ci_level_percent, confidence_interval_availability,
    limitations_text, source_locator, extraction_method, created_by_actor_id
  )
  select (select id from fixture where name = 'rich_source'),
         (select id from fixture where name = 'rich_version'),
         'randomized_controlled_trial',
         (select id from fixture where name = 'population'), 'reported_value',
         'Voksne i testpopulasjonen.',
         240, 'reported_value',
         (select id from fixture where name = 'sertralin'), '50 mg daglig',
         'drug', (select id from fixture where name = 'mirtazapin'), '30 mg daglig',
         (select id from fixture where name = 'topic'), 'Vektendring i kilogram.',
         interval '8 weeks', interval '12 weeks', 'reported_value',
         'increase', 'mean_difference', 1.7, 'kg', 'reported_value',
         0.9, 2.5, 95, 'reported_value',
         'Åpen etikett i den ene armen.', 'Tabell 2, side 5', 'manual',
         (select id from fixture where name = 'extraction')
  returning id
)
insert into fixture (name, id) select 'rich_evidence', id from inserted;

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select (select id from fixture where name = 'rich_rev'),
       (select id from fixture where name = 'rich_evidence'),
       'supports', 'direct',
       'Funnet rapporterer utfallet påstanden gjelder.',
       (select id from fixture where name = 'synthesis');

-- ---------------------------------------------------------------------------
-- Den minimale påstanden: hver valgfri kolonne er utelatt
--
-- Deterministisk faktum, slik at evidensvurderingen — og dermed hele
-- certainty-blokken i api.published_claims — er fraværende og ikke bare tom.
-- ---------------------------------------------------------------------------
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'deterministic_fact', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'plain_drug' and a.name = 'synthesis'
  returning id
)
insert into fixture (name, id) select 'lean_claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Minimal testpåstand for kolonnekontrakten i 340.',
         'Gjelder bare testene i denne filen.',
         'none', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'lean_claim')
  returning id
)
insert into fixture (name, id) select 'lean_rev', id from inserted;

with inserted as (
  insert into knowledge.sources
    (source_type, title, authors_or_issuer, source_status, created_by_actor_id)
  values ('journal_article', 'Minimal testkilde for 340', 'Testforfatter C', 'active',
          (select id from fixture where name = 'extraction'))
  returning id
)
insert into fixture (name, id) select 'lean_source', id from inserted;

-- Et øyeblikksbilde uten versjonsmerke og uten hash. Den rike versjonen over
-- har begge, og uten denne ville external_version og content_hash aldri vært
-- NULL i noen probe-rad for api.editor_source_versions. Evidensfunnet under
-- peker bevisst ikke på den: source_version_id skal også kunne være NULL.
insert into knowledge.source_versions
  (source_id, retrieved_at, retrieved_from, external_version, content_hash,
   retrieved_by_actor_id)
values ((select id from fixture where name = 'lean_source'), now() - interval '9 days',
        'https://eksempel.invalid/340-minimal', null, null,
        (select id from fixture where name = 'extraction'));

with inserted as (
  insert into knowledge.evidence_items (
    source_id, design_code,
    population_availability, population_detail,
    sample_size_availability,
    intervention_drug_id,
    comparator_kind,
    outcome_concept_id, outcome_detail,
    timepoint_availability,
    reported_direction, estimate_availability, confidence_interval_availability,
    source_locator, extraction_method, created_by_actor_id
  )
  select (select id from fixture where name = 'lean_source'),
         'randomized_controlled_trial',
         'not_reported', 'Populasjonen er ikke beskrevet i kilden.',
         'not_reported',
         (select id from fixture where name = 'plain_drug'),
         'none',
         (select id from fixture where name = 'topic'), 'Vektendring, ikke tallfestet.',
         'not_reported',
         'not_stated', 'not_reported', 'not_reported',
         'Avsnitt 3', 'manual',
         (select id from fixture where name = 'extraction')
  returning id
)
insert into fixture (name, id) select 'lean_evidence', id from inserted;

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select (select id from fixture where name = 'lean_rev'),
       (select id from fixture where name = 'lean_evidence'),
       'neutral_contextual', 'indirect',
       'Funnet beskriver konteksten uten å tallfeste den.',
       (select id from fixture where name = 'synthesis');

-- ---------------------------------------------------------------------------
-- Verifikasjoner, vurdering og godkjenning for begge påstandene
-- ---------------------------------------------------------------------------
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'verified', 'original_source',
       -- Full dekning, utledet av raden selv: publiseringsgatens G5b krever at
       -- kontrollene til sammen dekker det funnet påstår noe om.
       workflow.required_check_fields(e.id),
       'Kontrollert mot originalkilden.', now() - interval '5 days'
from knowledge.evidence_items e, fixture v
where v.name = 'verifier'
  and e.id in (select id from fixture where name in ('rich_evidence', 'lean_evidence'));

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Forsøkt falsifisert mot kilden.', now() - interval '4 days'
from knowledge.claim_revisions r, fixture v
where v.name = 'verifier'
  and r.id in (select id from fixture where name in ('rich_rev', 'lean_rev'));

-- Bare den rike påstanden har en evidensvurdering: migrasjon 004 tillater den
-- ikke på et deterministisk faktum, og publiseringsgaten G10 krever den ikke.
insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, evidence_gap, assessed_at, created_by_actor_id)
select r.id, r.knowledge_type, 'grade', 'low',
       'serious', 'not_assessable', 'serious', 'serious', 'not_assessable',
       'Ett funn; domenene vurdert enkeltvis.',
       'Ingen studier over tolv uker i testgrunnlaget.',
       now() - interval '3 days', r.created_by_actor_id
from knowledge.claim_revisions r
where r.id = (select id from fixture where name = 'rich_rev');

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Gjennomgått mot kilden; formuleringen holder.',
       rg.id, 'human', now() - interval '2 days'
from knowledge.claim_revisions r, fixture rg
where rg.name = 'reviewer'
  and r.id in (select id from fixture where name in ('rich_rev', 'lean_rev'));

select set_config('request.jwt.claims',
                  '{"sub":"e3a40000-0000-4000-8000-000000000002"}', true);

select lives_ok(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rich_rev'),
      (select id from fixture where name = 'publisher'),
      'Publisert for kolonnekontrakten i 340.')$$,
  'den rike påstanden lar seg publisere gjennom den kontrollerte operasjonen'
);

select lives_ok(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'lean_rev'),
      (select id from fixture where name = 'publisher'),
      'Publisert for kolonnekontrakten i 340.')$$,
  'den minimale påstanden lar seg publisere gjennom den kontrollerte operasjonen'
);

select set_config('request.jwt.claims', '', true);

-- Tilbaketrekkingen skjer etter publisering, fordi publiseringsgaten G6 nekter
-- å publisere et grunnlag som allerede er underkjent. Uten den ville
-- extraction_withdrawn_at og extraction_withdrawal_rationale aldri båret verdi
-- i noen probe-rad.
insert into workflow.review_decisions
  (evidence_item_id, evidence_item_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select e.id, e.created_by_actor_id, 'extraction_withdrawal', 'extraction_withdrawn',
       'Ekstraksjonen er underkjent i ettertid, for testene i 340.',
       rg.id, 'human', now() - interval '1 day'
from knowledge.evidence_items e, fixture rg
where rg.name = 'reviewer'
  and e.id = (select id from fixture where name = 'rich_evidence');

-- ---------------------------------------------------------------------------
-- Den tredje formen: publiseringspekeren flyttet utenom den kontrollerte
-- operasjonen.
--
-- Det er den dokumenterte grunnen til at api.published_claims.published_at og
-- last_reviewed_at kan være NULL — kolonnekommentarene i migrasjon 007a sier
-- det eksplisitt. Uten denne raden ville de to kolonnenes nullbarhet vært en
-- påstand uten dekning, fordi en publisering gjennom gaten alltid setter dem.
-- ---------------------------------------------------------------------------
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'deterministic_fact', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'plain_drug' and a.name = 'synthesis'
  returning id
)
insert into fixture (name, id) select 'pointer_claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Påstand med peker satt utenom publiseringsoperasjonen, for 340.',
         'Gjelder bare testene i denne filen.',
         'none', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'pointer_claim')
  returning id
)
insert into fixture (name, id) select 'pointer_rev', id from inserted;

update knowledge.claims
   set current_published_revision_id = (select id from fixture where name = 'pointer_rev')
 where id = (select id from fixture where name = 'pointer_claim');

-- ===========================================================================
-- Del 5 — Probe-radene, lest med de faktiske klientrettighetene
--
-- Radene telles først. En set_eq over et tomt view ville ellers vært stille
-- sann i den ene retningen og ubrukelig i den andre: uten rader er ingen
-- kolonne NULL, og ingen kolonne er ikke-NULL.
--
-- Cellene materialiseres underveis, fordi de fem viewene ikke kan leses av én
-- og samme kaller: de tre publiserte leses av anon, og de to fra migrasjon 007b
-- av hver sin innloggede bruker. Temptabellen bærer hele raden som jsonb, slik
-- at settet av kolonner utledes av radens egen form og ingen kolonne kan
-- glemmes.
-- ===========================================================================
create temporary table probe_cell (
  view_name text not null,
  key       text not null,
  value     jsonb not null
) on commit drop;
grant insert on probe_cell to anon, authenticated;

set local role anon;

select is(
  (select count(*) from api.published_drugs), 2::bigint,
  'probe-innholdet gir to rader i api.published_drugs: sertralin med ATC-kode og testvirkestoffet uten'
);

select is(
  (select count(*) from api.published_claims), 3::bigint,
  'probe-innholdet gir tre rader i api.published_claims: rik, minimal og peker'
);

select is(
  (select count(*) from api.published_claim_evidence), 2::bigint,
  'probe-innholdet gir to rader i api.published_claim_evidence: ett rikt og ett minimalt funn'
);

-- Begge grenene av tilbaketrekkingen er faktisk kjørt. Uten dette kunne
-- fiksturen slutte å trekke tilbake uten at noe sa fra, og nullbarheten på de
-- to tilbaketrekkingskolonnene ville vært målt på bare den ene grenen.
select set_eq(
  $$select distinct extraction_withdrawn from api.published_claim_evidence$$,
  $$values (true), (false)$$,
  'probe-radene dekker både en tilbaketrukket og en stående ekstraksjon'
);

insert into probe_cell (view_name, key, value)
select 'published_drugs', j.key, j.value
from api.published_drugs v, lateral jsonb_each(to_jsonb(v)) j;
insert into probe_cell (view_name, key, value)
select 'published_claims', j.key, j.value
from api.published_claims v, lateral jsonb_each(to_jsonb(v)) j;
insert into probe_cell (view_name, key, value)
select 'published_claim_evidence', j.key, j.value
from api.published_claim_evidence v, lateral jsonb_each(to_jsonb(v)) j;

reset role;

-- ---------------------------------------------------------------------------
-- Kaller med aktør: én aktørrad som ikke er trukket tilbake, og to tildelinger
-- som til sammen dekker begge formene av scope og sluttdato.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
                  '{"sub":"e3a40000-0000-4000-8000-000000000001"}', true);
set local role authenticated;

select is(
  (select count(*) from api.my_actor), 1::bigint,
  'kalleren med aktør gir én rad i api.my_actor'
);
select is(
  (select count(*) from api.my_roles), 2::bigint,
  'kalleren med aktør gir to rader i api.my_roles: den uavgrensede og den avgrensede med planlagt utløp'
);

insert into probe_cell (view_name, key, value)
select 'my_actor', j.key, j.value
from api.my_actor v, lateral jsonb_each(to_jsonb(v)) j;
insert into probe_cell (view_name, key, value)
select 'my_roles', j.key, j.value
from api.my_roles v, lateral jsonb_each(to_jsonb(v)) j;

reset role;

-- ---------------------------------------------------------------------------
-- Tilbaketrukket kaller: den eneste probe-raden der retired_at bærer verdi.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
                  '{"sub":"e3a40000-0000-4000-8000-000000000004"}', true);
set local role authenticated;

select is(
  (select count(*) from api.my_actor), 1::bigint,
  'den tilbaketrukne kalleren gir én rad i api.my_actor'
);

insert into probe_cell (view_name, key, value)
select 'my_actor', j.key, j.value
from api.my_actor v, lateral jsonb_each(to_jsonb(v)) j;

reset role;

-- ---------------------------------------------------------------------------
-- Redaksjonell kaller: de seks viewene fra migrasjon 007d.
--
-- Samme konto som «kaller med aktør» over. Den har en editor-tildeling som
-- gjelder nå — avgrenset til «vektendring», og en avgrenset tildeling teller
-- for lesbarheten (migrasjon 007d) — så den ser hele registeret og ikke bare
-- det publiserte utvalget. Nullbarheten i disse seks radene hviler derfor på
-- den samme rike/minimale fiksturen som resten av filen: den rike kilden har
-- utgiver, dato og statusmerknad, den minimale har ingen av dem; den rike
-- kildeversjonen har versjonsmerke og hash, den minimale har ingen; det rike
-- funnet har både kildeversjon og komparatorvirkestoff, det minimale har
-- ingen av dem.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
                  '{"sub":"e3a40000-0000-4000-8000-000000000001"}', true);
set local role authenticated;

select is(
  (select count(*) from api.editor_sources), 4::bigint,
  'den redaksjonelle kalleren ser fire kilder: de to seedede, den rike og den minimale'
);
select is(
  (select count(*) from api.editor_source_versions), 4::bigint,
  'den redaksjonelle kalleren ser fire kildeversjoner: de to seedede, den rike og den minimale'
);
select is(
  (select count(*) from api.editor_drugs), 3::bigint,
  'den redaksjonelle kalleren ser tre virkestoff: de to seedede og testvirkestoffet uten ATC-kode'
);
select is(
  (select count(*) from api.editor_outcomes), 1::bigint,
  'den redaksjonelle kalleren ser det ene endepunktet i katalogen; diagnosebegrepet er ikke et endepunkt'
);
select is(
  (select count(*) from api.editor_populations), 1::bigint,
  'den redaksjonelle kalleren ser den ene populasjonen i katalogen'
);
select is(
  (select count(*) from api.editor_evidence_items), 4::bigint,
  'den redaksjonelle kalleren ser fire evidensfunn: de to seedede, det rike og det minimale'
);

insert into probe_cell (view_name, key, value)
select 'editor_sources', j.key, j.value
from api.editor_sources v, lateral jsonb_each(to_jsonb(v)) j;
insert into probe_cell (view_name, key, value)
select 'editor_source_versions', j.key, j.value
from api.editor_source_versions v, lateral jsonb_each(to_jsonb(v)) j;
insert into probe_cell (view_name, key, value)
select 'editor_drugs', j.key, j.value
from api.editor_drugs v, lateral jsonb_each(to_jsonb(v)) j;
insert into probe_cell (view_name, key, value)
select 'editor_outcomes', j.key, j.value
from api.editor_outcomes v, lateral jsonb_each(to_jsonb(v)) j;
insert into probe_cell (view_name, key, value)
select 'editor_populations', j.key, j.value
from api.editor_populations v, lateral jsonb_each(to_jsonb(v)) j;
insert into probe_cell (view_name, key, value)
select 'editor_evidence_items', j.key, j.value
from api.editor_evidence_items v, lateral jsonb_each(to_jsonb(v)) j;

reset role;
select set_config('request.jwt.claims', '', true);

set local role anon;

reset role;

-- ===========================================================================
-- Del 6 — Nullbarheten, målt på probe-radene
--
-- Cellene ble hentet med jsonb_each over hele raden framfor kolonne for
-- kolonne. En kolonne kan da ikke glemmes: settet er utledet av radens egen
-- form, ikke av en liste noen må huske å utvide.
--
-- Sammenligningene kjører som eier, mot temptabellen. Klientrettighetene er
-- allerede utøvd — hver celle ble lest av den rollen og med det tokenet som
-- faktisk skal kunne lese den — og det er den lesingen påstanden hviler på.
-- ===========================================================================

-- Selvtest av selvtesten: hvert view i kontrakten har faktisk bidratt med
-- celler. Uten dette ville et view som ingen probe-rad traff falt helt ut av de
-- to sammenligningene under — dets nullbare kolonner ville manglet på venstre
-- side og dets kolonner på høyre, altså to feil som peker hver sin vei og som
-- lett leses som «kontrakten er for lang».
select set_eq(
  $$select distinct view_name from probe_cell$$,
  $$select distinct view_name from contract$$,
  'hvert view i kontrakten har bidratt med minst én probe-rad'
);

-- En kolonne merket nullbar er NULL i minst én probe-rad, og en kolonne merket
-- ikke-nullbar er NULL i ingen. set_eq gir begge retninger: en kolonne som blir
-- nullbar dukker opp på venstre side, og en nullbarhetspåstand uten dekning
-- blir stående alene på høyre.
select set_eq(
  $$select distinct view_name, key from probe_cell where value = 'null'::jsonb$$,
  $$select view_name, column_name from contract where nullable$$,
  'nøyaktig kontraktens nullbare kolonner er NULL i minst én probe-rad'
);

-- Og motsatt: hver kolonne bærer verdi et sted. En kolonne som alltid er NULL —
-- et uttrykk koblet til feil sted, en join som aldri treffer — ville passert
-- kontrollen over så lenge kontrakten kalte den nullbar.
select set_eq(
  $$select distinct view_name, key from probe_cell where value <> 'null'::jsonb$$,
  $$select view_name, column_name from contract$$,
  'hver kolonne i kontrakten bærer en verdi i minst én probe-rad'
);

select finish();

rollback;
