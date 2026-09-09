-- ============================================================================
-- Migrasjon 005æ — grunnlaget sier om maskinen har bevist venstresiden
--
-- Migrasjon 005x gjorde maskinbeviset til en forutsetning for en menneskelig
-- bekreftelse, men bare ved lagring. Kontrollflaten fikk ingen bevisstatus, og
-- viste de samme «Ordrett tekst»-utdragene enten de var prøvd mot kilden eller
-- ikke. En kontrollør kunne gjøre hele den semantiske jobben og først få
-- avvisningen til slutt.
--
-- Rekkefølgen skal være maskinbevis → menneskelig semantikk, ikke menneskelig
-- semantikk → databaseavvisning. Grunnlaget bærer derfor
-- `grounding_machine_proved`, og kontrolløkten stopper før feltskuffene når det
-- mangler eller er foreldet.
--
-- Fremover-skrivende med `create or replace function`, som i 005r, 005u og
-- 005v: signatur, eier og rettigheter er uendret, og svaret får én ny nøkkel
-- uten at noen eksisterende endrer form. Både
-- `api.extraction_review_workspace` og `api.claim_review_workspace` leser denne
-- ene projeksjonen, så begge flatene får opplysningen av samme endring.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §2, §11, §17
--   docs/DATABASE_ARCHITECTURE.md §29, §50
--   docs/PRODUCT_INFORMATION_ARCHITECTURE.md §42
-- ============================================================================

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
  where e.id = p_evidence_item_id;
$$;
