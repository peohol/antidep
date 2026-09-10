-- ============================================================================
-- Migrasjon 005ac — grunnlaget sier hvem som laget verdiene, og under hvilke
-- premisser
--
-- Formål: kontrolløren som bedømmer en ekstraksjon felt for felt, kunne se
-- *hva* som stod der og *hvem* raden var attribuert til, men ikke hvilken
-- modell som faktisk leste artikkelen, hvilken modellversjon det var, eller
-- hvilken promptmal utkastet ble laget med. Opplysningene fantes — de står på
-- `provenance.agent_runs` — men ikke i det bildet mennesket og den maskinelle
-- kontrollen arbeider fra.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md
--     §8 evidens og proveniens er førsteklasses data
--     §11 verifikasjon skal forsøke å falsifisere
--     §12 KI kan foreslå; mennesker har det faglige ansvaret
--     §14 endringer skal være attribuerte og rapporterbare
--     §20 leverandøruavhengighet, og versjonerte prompts og modeller
--   docs/DATABASE_ARCHITECTURE.md §29, §33, §43, §50
--   docs/EVIDENCE_PIPELINE.md §46, §61, §65
--   docs/MVP_IMPLEMENTATION_PLAN.md §15
--
-- ----------------------------------------------------------------------------
-- Hvorfor dette er kontrollgrunnlag og ikke driftsinformasjon
--
-- EVIDENCE_PIPELINE.md §46 sier hva en reviewer minst skal se, og §65 sier at
-- Antidep skal kunne rekonstruere hva som ble kjørt med hvilke premisser. Det
-- andre er verdiløst for den som faktisk vurderer, hvis det bare kan leses av
-- noen med databasetilgang etterpå.
--
-- Forskjellen er praktisk: en kontrollør som vet at verdiene er et maskinutkast
-- fra en bestemt modell og en bestemt promptmal, leser dem annerledes enn en
-- som tror en kollega skrev dem — og motsatt. Blir en promptmal senere funnet å
-- ha en systematisk svakhet, er «hvilke funn ble laget med den» et spørsmål
-- kontrollflaten kan svare på, ikke bare en spørring noen må huske å skrive.
--
-- ----------------------------------------------------------------------------
-- Hvorfor NULL, og ikke et tomt objekt
--
-- Et evidensfunn registrert på editorveien har ingen agentkjøring, og skal ikke
-- få et objekt med tomme felter: fravær av en kjøring er en opplysning, ikke en
-- struktur uten verdier (ANTIDEP_CONSTITUTION.md §6). Det samme valget som
-- `source_version` allerede gjør i den samme projeksjonen.
--
-- ----------------------------------------------------------------------------
-- Hvorfor ett uttrykk og ikke ett per flate
--
-- `workflow.evidence_extraction_dossier(uuid)` er den ene projeksjonen både den
-- maskinelle ekstraksjonskontrollen og den menneskelige kontrolløkten leser
-- (migrasjon 005r). Nøkkelen legges derfor til her, og begge flatene får den
-- samtidig. To formuleringer ville før eller siden latt mennesket og maskinen
-- kontrollere hvert sitt grunnlag.
--
-- Fremover-skrivende med `create or replace function`: signatur, eier og
-- rettigheter er uendret, og svaret får én ny nøkkel uten at noen eksisterende
-- endrer form. Ingen CHECK, constraint, trigger, policy eller grant er fjernet
-- eller svekket, og ingen ny tabelltilgang er gitt til `anon` eller
-- `authenticated`: funksjonen er SECURITY DEFINER, og hver flate som eksponerer
-- den autentiserer først.
-- ============================================================================

begin;

create or replace function workflow.evidence_extraction_dossier(p_evidence_item_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select jsonb_build_object(
    'evidence_item_id', e.id,
    'created_at', e.created_at,
    'created_by_actor_id', e.created_by_actor_id,
    'created_by_actor_key', creator.actor_key,
    'created_by_actor_type', creator.actor_type::text,
    'extraction_method', e.extraction_method::text,
    'content_hash', e.content_hash,
    -- Premissene kjøringen som produserte raden, ble gjort under. NULL for et
    -- funn registrert på editorveien: der finnes ingen kjøring, og et objekt
    -- med tomme felter ville påstått at det gjorde det.
    'drafted_by', case
      when ar.id is null then null
      else jsonb_build_object(
        'agent_run_id', ar.id,
        'agent_role', ar.agent_role::text,
        'provider', ar.provider,
        'model', ar.model,
        'model_version', ar.model_version,
        'prompt_template_version', ar.prompt_template_version,
        'pipeline_version', ar.pipeline_version,
        'started_at', ar.started_at
      )
    end,
    'source', jsonb_build_object(
      'source_id', s.id,
      'source_type', s.source_type::text,
      'title', s.title,
      'authors_or_issuer', s.authors_or_issuer,
      'publisher_or_journal', s.publisher_or_journal,
      'publication_date', s.publication_date,
      'publication_date_precision', s.publication_date_precision::text,
      'source_status', s.source_status::text,
      'status_note', s.status_note,
      -- De globale identifikatorene, som den menneskelige lenken bygges av.
      'identifiers', (
        select coalesce(jsonb_agg(
          jsonb_build_object(
            'identifier_system', si.identifier_system::text,
            'identifier_value', si.identifier_value
          )
          order by si.identifier_system::text
        ), '[]'::jsonb)
        from knowledge.source_identifiers si
        where si.source_id = s.id
      )
    ),
    'source_version', case
      when sv.id is null then null
      else jsonb_build_object(
        'source_version_id', sv.id,
        'retrieved_at', sv.retrieved_at,
        'retrieved_from', sv.retrieved_from,
        'external_version', sv.external_version,
        'content_hash', sv.content_hash,
        -- NULL betyr at opplysningen ikke er registrert, aldri at
        -- representasjonen er ukjent men brukbar (migrasjon 003b).
        'representation', sv.representation::text,
        'has_storage_reference', sv.storage_reference is not null
      )
    end,
    'field_groundings', workflow.evidence_field_groundings(e.id),
    -- Feltene en kliniker kontrollerer ett av gangen, og feltene forankringen
    -- faktisk dekker. Differansen er hva som mangler før funnet kan kontrolleres
    -- felt for felt, og den er ren mengdelære over to lister databasen leverer.
    'semantic_check_fields', to_jsonb(workflow.semantic_check_fields(e.id)::text[]),
    'grounded_check_fields', to_jsonb(workflow.grounded_check_fields(e.id)::text[]),
    -- Om maskinen har bevist venstresiden for nøyaktig dette grunnlaget. Uten
    -- den kan ingen menneskelig bekreftelse registreres (migrasjon 005x), og
    -- kontrolløkten skal si det før noen begynner å bedømme semantikken.
    'grounding_machine_proved', workflow.grounding_machine_proved(e.id),
    'extraction', jsonb_build_object(
      'design_code', e.design_code::text,
      'population_id', e.population_id,
      'population_label', pop.canonical_label,
      'population_availability', e.population_availability::text,
      'population_detail', e.population_detail,
      'sample_size', e.sample_size,
      'sample_size_availability', e.sample_size_availability::text,
      'intervention_drug_id', e.intervention_drug_id,
      'intervention_drug_name', d.canonical_name,
      'intervention_detail', e.intervention_detail,
      'comparator_kind', e.comparator_kind::text,
      'comparator_drug_id', e.comparator_drug_id,
      'comparator_drug_name', cd.canonical_name,
      'comparator_detail', e.comparator_detail,
      'outcome_concept_id', e.outcome_concept_id,
      'outcome_label', oc.canonical_label,
      'outcome_detail', e.outcome_detail,
      'timepoint_min', e.timepoint_min::text,
      'timepoint_max', e.timepoint_max::text,
      'timepoint_availability', e.timepoint_availability::text,
      'reported_direction', e.reported_direction::text,
      'effect_measure', e.effect_measure::text,
      'estimate', e.estimate::text,
      'estimate_unit', e.estimate_unit::text,
      'estimate_availability', e.estimate_availability::text,
      'ci_lower', e.ci_lower::text,
      'ci_upper', e.ci_upper::text,
      'ci_level_percent', e.ci_level_percent::text,
      'confidence_interval_availability', e.confidence_interval_availability::text,
      'limitations_text', e.limitations_text,
      'source_locator', e.source_locator,
      'raw_extraction', e.raw_extraction
    )
  )
  from knowledge.evidence_items e
  join knowledge.sources s on s.id = e.source_id
  join provenance.actors creator on creator.id = e.created_by_actor_id
  join catalog.drugs d on d.id = e.intervention_drug_id
  join catalog.clinical_concepts oc on oc.id = e.outcome_concept_id
  left join catalog.drugs cd on cd.id = e.comparator_drug_id
  left join catalog.populations pop on pop.id = e.population_id
  left join knowledge.source_versions sv on sv.id = e.source_version_id
  -- LEFT JOIN, fordi agent_run_id er nullbar: editorveien registrerer et funn
  -- uten kjøring (migrasjon 005u).
  left join provenance.agent_runs ar on ar.id = e.agent_run_id
  where e.id = p_evidence_item_id;
$$;

comment on function workflow.evidence_extraction_dossier(uuid) is
  'Grunnlaget for én ekstraksjonskontroll: evidensfunnets identitet og opphav, premissene kjøringen som produserte det ble gjort under (drafted_by: rolle, leverandør, modell, modellversjon, promptmalversjon, pipelineversjon og starttidspunkt — NULL når funnet ble registrert på editorveien og ingen kjøring finnes), kilden med sin status og sine identifikatorer, kildeversjonen (eller null når ingen er registrert, med retrieved_from, content_hash og representasjonstype når den finnes), kildeforankringen per felt, feltsettene og maskinbeviset, og hele den strukturerte ekstraksjonen ordrett, inkludert source_locator og raw_extraction (ANTIDEP_CONSTITUTION.md §11, §12, §20, DATABASE_ARCHITECTURE.md §29, EVIDENCE_PIPELINE.md §46, §65). drafted_by er kontrollgrunnlag og ikke driftsinformasjon: en kontrollør leser et maskinutkast annerledes enn en kollegas ekstraksjon, og «hvilke funn ble laget med denne promptmalen» skal kunne besvares fra kontrollflaten. Uttrykket er den ene projeksjonen både den menneskelige kontrollflaten og den deterministiske verifikatoren leser, slik at de aldri kontrollerer hvert sitt grunnlag (§4, §9). storage_reference er ikke eksponert, bare om den finnes. Numeriske verdier er ::text, slik at et eksakt desimaltall ikke går veien om en IEEE-754 double før noen leser det. NULL når evidensfunnet ikke finnes. Tar ingen kaller-identitet og gjør ingen autorisasjon: den er et lesegrunnlag og ikke et endepunkt, og hver flate som eksponerer den autentiserer først. SECURITY DEFINER fordi knowledge, catalog og provenance har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

commit;
