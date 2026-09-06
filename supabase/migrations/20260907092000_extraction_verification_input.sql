-- ============================================================================
-- Migrasjon 005h — lesegrunnlaget ekstraksjonsverifikatoren trenger
--
-- Migrasjon 005g bygget skriveveien inn i workflow.evidence_verifications, men
-- ikke veien inn: en agentkjører har ingen brukerkonto og kaller Data API-et som
-- `anon` (§74.31), og `anon` ser ingenting i knowledge — hverken evidensfunnet
-- den skal kontrollere, eller kildeversjonen den skal kontrollere det mot. Uten
-- denne migrasjonen kan verifikatoren registrere et resultat den ikke har hatt
-- grunnlag for å komme fram til, og bare det.
--
-- ANTIDEP_CONSTITUTION.md §11 er eksplisitt: verifikatoren skal ha tilgang til
-- kildematerialet og skal ikke godkjenne ut fra andre agenters sammendrag alene.
-- Denne funksjonen er det leddet som gjør den setningen mulig å oppfylle i
-- praksis — den gir verifikatoren ekstraksjonen ordrett og adressen til
-- representasjonen den ble gjort fra, slik at kontrollen kan skje mot kilden og
-- ikke mot en beskrivelse av den.
--
-- Utvider agentmodellen fra migrasjon 005e/005f/005g og får derfor neste
-- bokstav i den rekken, selv om objektet ligger i `api`: det er samme mønster
-- som 005g, som også er en api-funksjon. Nummeret 009 er fortsatt reservert for
-- DrugProduct-/importfundamentet (§26).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §10, §11, §14, §20
--   docs/DATABASE_ARCHITECTURE.md §29, §33, §43, §44, §49, §50
--   docs/EVIDENCE_PIPELINE.md §25 Extraction-verifier, §61 agentroller,
--     §63 minst mulig privilegier
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §16, §49, §74.30-§74.32
--
-- ----------------------------------------------------------------------------
-- Hvorfor dette er en funksjon og ikke et view
--
-- Den redaksjonelle lesemodellen (migrasjon 007d) er views med RLS-policyer
-- under seg, fordi kalleren der er en innlogget bruker med en `auth.uid()` en
-- policy kan lese. En agent har ingen slik identitet: den har en legitimasjon
-- den oppgir i kallet. En policy kan ikke se den, så radgrensen kan ikke ligge
-- i RLS — den må ligge i en funksjon som autentiserer først og leser etterpå.
--
-- Det er samtidig strammere enn et view ville vært. Funksjonen gir ingenting før
-- tre krav er oppfylt samtidig: gyldig legitimasjon, riktig rolle, og en åpen
-- agentkjøring som tilhører nøyaktig den identiteten. En lesing utenfor en
-- kjøring finnes ikke — proveniensen for hva verifikatoren faktisk fikk se, er
-- dermed like sporbar som skrivingen (DATABASE_ARCHITECTURE.md §34).
--
-- ----------------------------------------------------------------------------
-- Hva køen inneholder, og hvorfor akkurat det
--
-- Uten p_evidence_item_id svarer funksjonen med arbeidskøen: evidensfunn denne
-- verifikatoren *kan* kontrollere og ennå ikke har kontrollert.
--
--   * Funn aktøren selv har laget er utelatt. De kan aldri kontrolleres av den
--     (evidence_verifications_separate_actor_check), så å ha dem i køen ville
--     vært å be om et kall som må avvises.
--   * Funn denne aktøren allerede har kontrollert er utelatt. En annen
--     verifikatoraktør ser dem fortsatt: to uavhengige kontrollag er to aktører
--     (migrasjon 005e), og workflow.evidence_verifications er append-only, så
--     begge kontrollene består ved siden av hverandre.
--   * Alt annet er med, også funn uten registrert kildeversjon. Å skjule dem
--     ville skjult et reelt hull: et funn uten kildeversjon *kan* kontrolleres
--     mot originalkilden, men ikke mot en etterprøvbar representasjon (§74.32),
--     og det er verifikatorens vurdering å ta — ikke køens.
--
-- Med p_evidence_item_id svarer den om nøyaktig det funnet, også når det
-- allerede er kontrollert: en ny kontroll av et allerede kontrollert funn er en
-- legitim operasjon, og en ny rad.
--
-- ----------------------------------------------------------------------------
-- Hvorfor svaret er jsonb og ikke en tabell
--
-- Grunnlaget er en trestruktur — funn, kilde, kildeversjon, katalogetiketter og
-- den rå ekstraksjonen — og en flat rad ville enten duplisert kilden per funn
-- eller krevd flere kall som ikke var atomiske mot hverandre. jsonb er dessuten
-- den formen provenance.agent_runs.input_manifest allerede bruker for premisser,
-- så kjøreren kan legge det den fikk inn, inn i manifestet uten å bygge det om.
--
-- Formen er stabil og dokumentert i funksjonskommentaren; den er en kontrakt
-- utad på samme måte som kolonnene i et api-view (§44).
-- ============================================================================

create function api.extraction_verification_input(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_evidence_item_id uuid default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity_id uuid;
  v_verifier_actor_id uuid;
  v_items jsonb;
begin
  -- Autentiser eksplisitt for rollen extraction_verification. En identitet i en
  -- annen rolle avvises her, før noe leses — samme første lag som
  -- api.register_extraction_verification(...) bruker.
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'extraction_verification'::provenance.agent_role
  );

  -- Krev en åpen kjøring som tilhører nøyaktig denne identiteten, og la
  -- returverdien være aktøren køen filtreres for. Aktøren er dermed ikke noe
  -- kalleren kan be om på vegne av en annen.
  v_verifier_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  select coalesce(jsonb_agg(item order by item ->> 'created_at'), '[]'::jsonb)
  into v_items
  from (
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
        'status_note', s.status_note
      ),
      -- NULL og ikke et tomt objekt: fraværet av en kildeversjon er en
      -- opplysning verifikatoren skal handle på, ikke en tom struktur den kan
      -- lese som «ingen felter satt» (ANTIDEP_CONSTITUTION.md §6).
      'source_version', case
        when sv.id is null then null
        else jsonb_build_object(
          'source_version_id', sv.id,
          'retrieved_at', sv.retrieved_at,
          'retrieved_from', sv.retrieved_from,
          'external_version', sv.external_version,
          'content_hash', sv.content_hash,
          -- Selve adressen til en lagret kopi er driftsinformasjon og er ikke
          -- eksponert (samme valg som api.editor_source_versions). At kopien
          -- finnes, er derimot noe verifikatoren skal kunne se.
          'has_storage_reference', sv.storage_reference is not null
        )
      end,
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
        'estimate', e.estimate,
        'estimate_unit', e.estimate_unit::text,
        'estimate_availability', e.estimate_availability::text,
        'ci_lower', e.ci_lower,
        'ci_upper', e.ci_upper,
        'ci_level_percent', e.ci_level_percent,
        'confidence_interval_availability', e.confidence_interval_availability::text,
        'limitations_text', e.limitations_text,
        'source_locator', e.source_locator,
        'raw_extraction', e.raw_extraction
      ),
      'verifications_by_this_actor', (
        select count(*)
        from workflow.evidence_verifications ev
        where ev.evidence_item_id = e.id
          and ev.verifier_actor_id = v_verifier_actor_id
      ),
      'verifications_total', (
        select count(*)
        from workflow.evidence_verifications ev
        where ev.evidence_item_id = e.id
      )
    ) as item
    from knowledge.evidence_items e
    join knowledge.sources s on s.id = e.source_id
    join provenance.actors creator on creator.id = e.created_by_actor_id
    join catalog.drugs d on d.id = e.intervention_drug_id
    join catalog.clinical_concepts oc on oc.id = e.outcome_concept_id
    left join catalog.drugs cd on cd.id = e.comparator_drug_id
    left join catalog.populations pop on pop.id = e.population_id
    left join knowledge.source_versions sv on sv.id = e.source_version_id
    where
      case
        when p_evidence_item_id is not null then e.id = p_evidence_item_id
        else
          -- Arbeidskøen. Se hodekommentaren for hvert av de to leddene.
          e.created_by_actor_id <> v_verifier_actor_id
          and not exists (
            select 1
            from workflow.evidence_verifications ev
            where ev.evidence_item_id = e.id
              and ev.verifier_actor_id = v_verifier_actor_id
          )
      end
  ) as items;

  return jsonb_build_object(
    'agent_run_id', p_agent_run_id,
    'verifier_actor_id', v_verifier_actor_id,
    'items', v_items
  );
end;
$$;

comment on function api.extraction_verification_input(text, text, uuid, uuid) is
  'Lesegrunnlaget en autentisert ekstraksjonsverifikator arbeider fra (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §43, MVP_IMPLEMENTATION_PLAN.md §15). Autentiserer identiteten eksplisitt for rollen extraction_verification og krever en åpen agentkjøring som tilhører den (provenance.assert_agent_run_open(uuid, uuid)); uten begge deler returneres ingenting, og avvisningen er den samme som for enhver mislykket agentautentisering. Uten p_evidence_item_id svarer den med arbeidskøen: evidensfunn aktøren ikke selv har laget og ikke selv har kontrollert. Med p_evidence_item_id svarer den om nøyaktig det funnet, også et allerede kontrollert. Svaret er et jsonb-objekt med agent_run_id, verifier_actor_id og items, der hvert element har evidensfunnets identitet og opphav, kilden, kildeversjonen (eller null når ingen er registrert, med retrieved_from og content_hash når den finnes) og hele ekstraksjonen ordrett, inkludert raw_extraction og source_locator. storage_reference er ikke eksponert, bare om den finnes. SECURITY DEFINER fordi knowledge, catalog, provenance og workflow har RLS med default deny; tomt search_path, og kalleren autentiseres på funksjonens eget kall (§50). EXECUTE går til anon og authenticated av samme grunn som api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb): en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';

revoke execute on function api.extraction_verification_input(
  text, text, uuid, uuid
) from public;
grant execute on function api.extraction_verification_input(
  text, text, uuid, uuid
) to anon, authenticated;
