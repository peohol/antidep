-- Migrasjon 002 — struktur i catalog.
--
-- Verifiserer at katalogfundamentet fra MVP_IMPLEMENTATION_PLAN.md §19 finnes
-- med den identiteten, de vokabularene og de relasjonene
-- DATABASE_ARCHITECTURE.md §8-§12 krever. Constraint-atferd testes i
-- 050_catalog_constraints_test.sql, tilgang i 060_catalog_access_test.sql.
--
-- Filen holder i tillegg vaktposten over hvilke objekter som finnes utenfor
-- catalog. Den vaktposten gjelder alle senere migrasjoner og må utvides, ikke
-- omgås, når et nytt schema tas i bruk.
begin;

create extension if not exists pgtap with schema extensions;

select plan(41);

-- ---------------------------------------------------------------------------
-- Tabellene i migrasjon 002, og ingen flere
-- ---------------------------------------------------------------------------
select has_table('catalog', 'drugs', 'catalog.drugs finnes');
select has_table('catalog', 'drug_names', 'catalog.drug_names finnes');
select has_table('catalog', 'drug_identifiers', 'catalog.drug_identifiers finnes');
select has_table('catalog', 'clinical_concepts', 'catalog.clinical_concepts finnes');
select has_table('catalog', 'populations', 'catalog.populations finnes');

-- catalog.drug_products og ingest hører til migrasjon 009 og skal ikke ha
-- sneket seg inn i dette steget.
select hasnt_table('catalog', 'drug_products', 'catalog.drug_products er ikke opprettet ennå');
select is_empty(
  $$
    select n.nspname
    from pg_namespace n
    where n.nspname = 'ingest'
  $$,
  'ingest-schemaet er ikke opprettet ennå'
);

-- Vaktpost for hvor langt schemaet faktisk har kommet. Migrasjon 003 la til
-- kilde- og evidenslaget i knowledge, migrasjon 004 påstandslaget og migrasjon
-- 006 publiseringshistorikken, og listen under er uttømmende: den skal utvides
-- av den migrasjonen som legger til en tabell, slik at et objekt ingen har
-- bestemt seg for ikke kan gli inn ubemerket. api-projeksjonene hører til
-- migrasjon 007 og skal ikke opprettes i knowledge.
select set_eq(
  $$
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'knowledge'
      and c.relkind in ('r', 'p', 'v', 'm')
  $$,
  $$values ('sources'), ('source_identifiers'), ('source_versions'), ('evidence_items'),
           ('claims'), ('claim_revisions'), ('claim_evidence_links'),
           ('evidence_assessments'), ('publication_events')$$,
  'knowledge inneholder nøyaktig tabellene fra migrasjon 003, 004 og 006'
);

-- Samme uttømmende vaktpost for de øvrige schemaene. Migrasjon 005 tok
-- workflow og provenance i bruk, og listene under er like uttømmende som listen
-- over knowledge: en tabell eller et view ingen har bestemt seg for skal ikke
-- kunne gli inn ubemerket bare fordi schemaet allerede er tatt i bruk.
select set_eq(
  $$
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'workflow'
      and c.relkind in ('r', 'p', 'v', 'm')
  $$,
  $$values ('user_roles'), ('evidence_verifications'), ('claim_verifications'),
           ('claim_verification_citations'), ('review_decisions')$$,
  'workflow inneholder nøyaktig tabellene fra migrasjon 005, med kontrollradene fra 005j'
);
select set_eq(
  $$
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'provenance'
      and c.relkind in ('r', 'p', 'v', 'm')
  $$,
  $$values ('actors'), ('agent_identities'), ('agent_runs')$$,
  'provenance inneholder nøyaktig aktørtabellen fra migrasjon 005 og de to agenttabellene fra 005e'
);

-- provenance.agent_runs var bevisst utsatt til det fantes en faktisk skrivevei
-- inn i den (MVP_IMPLEMENTATION_PLAN.md §22). Migrasjon 005e ga den en:
-- api.begin_agent_run(...) og api.complete_agent_run(...). Vaktposten er derfor
-- snudd framfor fjernet — den påstod at tabellen ikke fantes, og påstår nå at
-- den bærer nøyaktig de premissene DATABASE_ARCHITECTURE.md §33 krever av en
-- agentkjøring. En kolonne som forsvant, ville gjort en KI-operasjon
-- urekonstruerbar uten at noe sa fra.
select has_table(
  'provenance', 'agent_runs',
  'provenance.agent_runs finnes etter migrasjon 005e'
);
select set_eq(
  $$
    select a.attname
    from pg_attribute a
    where a.attrelid = 'provenance.agent_runs'::regclass
      and a.attnum > 0 and not a.attisdropped
  $$,
  $$values ('id'), ('agent_identity_id'), ('actor_id'), ('agent_role'),
           ('provider'), ('model'), ('model_version'),
           ('prompt_template_version'), ('pipeline_version'),
           ('status'), ('input_manifest'), ('output_manifest'),
           ('failure_reason'), ('started_at'), ('completed_at'),
           ('created_at'), ('updated_at')$$,
  'provenance.agent_runs bærer rolle, identitet, modell- og pipelineversjon, input, output og tidspunkter (DATABASE_ARCHITECTURE.md §33)'
);

-- audit fikk auditloggen i migrasjon 008, og ikke noe mer. Vaktposten er derfor
-- snevret framfor fjernet: den påstod at schemaet var tomt, og påstår nå at det
-- inneholder nøyaktig én relasjon. Et view eller en tabell som sniker seg inn i
-- audit uten en migrasjon som forklarer den, fanges fortsatt. Innholdet i
-- audit.events er en egen kontrakt i 300_audit_structure_test.sql.
--
-- api fikk sine tre lesemodell-views i migrasjon 007; inventaret der er en egen
-- kontrakt i 290_api_read_model_access_test.sql og hører ikke hjemme i en test
-- av katalogstrukturen.
select set_eq(
  $$
    select c.relname::text
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'audit'
      and c.relkind in ('r', 'p', 'v', 'm')
  $$,
  array['events'],
  'audit inneholder nøyaktig auditloggen fra migrasjon 008'
);

-- ---------------------------------------------------------------------------
-- Kontrollerte vokabularer
-- ---------------------------------------------------------------------------
select enum_has_labels(
  'catalog', 'drug_status', array['active', 'historical', 'withdrawn'],
  'catalog.drug_status har statusene active, historical og withdrawn'
);
select enum_has_labels(
  'catalog', 'drug_name_type', array['alias', 'trade_name', 'historical_name'],
  'catalog.drug_name_type skiller alias, handelsnavn og historisk navn'
);
select enum_has_labels(
  'catalog', 'drug_identifier_system', array['atc'],
  'catalog.drug_identifier_system dekker atc'
);
select enum_has_labels(
  'catalog', 'clinical_concept_type',
  array['condition', 'outcome', 'pharmacokinetic_property', 'interaction_mechanism'],
  'catalog.clinical_concept_type dekker pilottemaene i MVP_IMPLEMENTATION_PLAN.md §11'
);
select enum_has_labels(
  'catalog', 'vocabulary_status', array['active', 'deprecated'],
  'catalog.vocabulary_status har active og deprecated'
);
select enum_has_labels(
  'catalog', 'population_pregnancy_context',
  array['pregnancy', 'breastfeeding', 'pregnancy_or_breastfeeding'],
  'catalog.population_pregnancy_context dekker graviditet og amming'
);

select is_empty(
  $$
    select t.type_name
    from (values ('catalog.drug_status'), ('catalog.drug_name_type'),
                 ('catalog.drug_identifier_system'), ('catalog.clinical_concept_type'),
                 ('catalog.vocabulary_status'), ('catalog.population_pregnancy_context'))
           as t(type_name)
    where has_type_privilege('public', t.type_name, 'usage')
  $$,
  'PUBLIC har ikke usage på noen av katalogtypene'
);

-- ---------------------------------------------------------------------------
-- Stabil identitet (DATABASE_ARCHITECTURE.md §7, §8)
-- ---------------------------------------------------------------------------
select col_is_pk('catalog', 'drugs', 'id', 'catalog.drugs har uuid-primærnøkkel på id');
select col_not_null('catalog', 'drugs', 'canonical_name', 'kanonisk navn er påkrevd');
select col_type_is(
  'catalog', 'drugs', 'status', 'catalog.drug_status',
  'status på catalog.drugs er et kontrollert vokabular, ikke fritekst'
);
select col_type_is(
  'catalog', 'drugs', 'updated_at', 'timestamp with time zone',
  'catalog.drugs.updated_at er timestamptz (KNOWLEDGE_MODEL.md §4)'
);
select has_index(
  'catalog', 'drugs', 'drugs_canonical_name_key',
  'kanonisk navn er unikt, men ikke primærnøkkel'
);

-- Eksterne identifikatorer er egne relasjoner, aldri intern primærnøkkel.
select col_isnt_pk(
  'catalog', 'drug_identifiers', 'identifier_value',
  'ATC-verdien er ikke primærnøkkel (DATABASE_ARCHITECTURE.md §8)'
);
select col_is_unique(
  'catalog', 'drug_identifiers', array['identifier_system', 'identifier_value'],
  'samme identifikator i samme system kan ikke peke på to virkestoffer'
);

-- ---------------------------------------------------------------------------
-- Relasjoner, med RESTRICT som hovedregel (DATABASE_ARCHITECTURE.md §37)
-- ---------------------------------------------------------------------------
select fk_ok(
  'catalog', 'drug_names', 'drug_id', 'catalog', 'drugs', 'id',
  'catalog.drug_names peker på catalog.drugs'
);
select fk_ok(
  'catalog', 'drug_identifiers', 'drug_id', 'catalog', 'drugs', 'id',
  'catalog.drug_identifiers peker på catalog.drugs'
);
select fk_ok(
  'catalog', 'clinical_concepts', 'parent_concept_id', 'catalog', 'clinical_concepts', 'id',
  'begrepshierarkiet peker på seg selv'
);
select fk_ok(
  'catalog', 'populations', array['indication_concept_id', 'required_condition_type'],
  'catalog', 'clinical_concepts', array['id', 'concept_type'],
  'indikasjon peker på et begrep med riktig type'
);
select fk_ok(
  'catalog', 'populations', array['comorbidity_concept_id', 'required_condition_type'],
  'catalog', 'clinical_concepts', array['id', 'concept_type'],
  'komorbiditet peker på et begrep med riktig type'
);

select is_empty(
  $$
    select n.nspname, rel.relname, con.conname, con.confdeltype, con.confupdtype
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'catalog'
      and con.contype = 'f'
      and (con.confdeltype <> 'r' or con.confupdtype <> 'r')
  $$,
  'alle fremmednøkler i catalog bruker RESTRICT ved delete og update'
);

-- ---------------------------------------------------------------------------
-- Populasjonsdimensjoner (DATABASE_ARCHITECTURE.md §12)
-- ---------------------------------------------------------------------------
select col_is_null(
  'catalog', 'populations', 'age_min_years',
  'alder er en valgfri avgrensning; NULL betyr ingen nedre grense'
);
select col_is_null(
  'catalog', 'populations', 'pregnancy_context',
  'graviditet/amming er en valgfri avgrensning'
);
select col_is_null(
  'catalog', 'populations', 'comorbidity_concept_id',
  'komorbiditet er en valgfri avgrensning'
);

-- ---------------------------------------------------------------------------
-- Tidsstempler eies av databasen, ikke av klienten
--
-- Triggeren må dekke INSERT i tillegg til UPDATE. En default alene gjelder bare
-- når kolonnen utelates, og etterlater created_at/updated_at forfalskbare.
-- tgtype-bitene: 2 = BEFORE, 4 = INSERT, 16 = UPDATE.
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'catalog'
      and c.relkind = 'r'
      and not exists (
        select 1
        from pg_trigger t
        where t.tgrelid = c.oid
          and not t.tgisinternal
          and t.tgfoid = 'catalog.set_row_timestamps()'::regprocedure
          and (t.tgtype & 2) <> 0
          and (t.tgtype & 4) <> 0
          and (t.tgtype & 16) <> 0
      )
  $$,
  'alle katalogtabeller setter created_at og updated_at ved både INSERT og UPDATE'
);

-- Populasjonsdefinisjonen er uforanderlig, slik at eksisterende
-- ClaimRevision-/EvidenceItem-referanser beholder sin betydning
-- (DATABASE_ARCHITECTURE.md §7, §7.1).
select has_trigger(
  'catalog', 'populations', 'populations_freeze_definition',
  'catalog.populations har en immutable-row guard på definisjonen'
);

select is_empty(
  $$
    select f.function_name
    from (values ('catalog.set_row_timestamps()'),
                 ('catalog.freeze_population_definition()')) as f(function_name)
    where has_function_privilege('public', f.function_name, 'execute')
  $$,
  'PUBLIC kan ikke kjøre katalogets triggerfunksjoner'
);

-- ---------------------------------------------------------------------------
-- Dokumentasjon i databasen
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'catalog'
      and c.relkind = 'r'
      and coalesce(obj_description(c.oid, 'pg_class'), '') = ''
  $$,
  'alle katalogtabeller har en kommentar som dokumenterer formålet'
);
select is_empty(
  $$
    select t.typname
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'catalog'
      and t.typtype = 'e'
      and coalesce(obj_description(t.oid, 'pg_type'), '') = ''
  $$,
  'alle kontrollerte vokabularer i catalog er dokumentert'
);

select * from finish();

rollback;
