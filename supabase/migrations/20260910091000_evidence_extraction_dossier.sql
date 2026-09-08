-- ============================================================================
-- Migrasjon 005r — grunnlaget for en ekstraksjonskontroll, ett sted
--
-- Den menneskelige ekstraksjonskontrollen (005t) skal vise nøyaktig det samme
-- grunnlaget den deterministiske ekstraksjonsverifikatoren arbeider mot i dag:
-- evidensfunnet ordrett, kilden med sin status, kildeversjonen med adresse og
-- fingeravtrykk, hele den strukturerte ekstraksjonen og den rå ekstraksjonen.
--
-- Den projeksjonen finnes allerede — den står inne i
-- api.extraction_verification_input(text, text, uuid, uuid) fra migrasjon 005h.
-- To kopier av den ville vært to formuleringer av det samme grunnlaget, og da
-- ville mennesket og maskinen etter hvert kontrollert ekstraksjonen mot hvert
-- sitt bilde av kilden. Det er nøyaktig den feilen ANTIDEP_CONSTITUTION.md §4 og
-- §11 er til for å hindre, og det er det samme grepet migrasjon 005m gjorde for
-- påstandskontrollen.
--
-- Denne migrasjonen flytter derfor projeksjonen ut i én funksjon,
-- workflow.evidence_extraction_dossier(uuid), og lar api-funksjonen kalle den.
-- Ingenting i svaret endres: funksjonen bygger de samme nøklene med de samme
-- uttrykkene, og de to feltene som avhenger av hvem som spør
-- (verifications_by_this_actor og verifications_total) blir liggende igjen i
-- api-funksjonen, der aktøren er kjent.
--
-- Fremover-skrivende, ikke en retusjert linje i 005h: 20260907092000 er allerede
-- kjørt i det hostede prosjektet, og Supabase kjører aldri en registrert
-- migrasjonsversjon på nytt (§74.32). Erstatningen skjer med
-- `create or replace function` som bytter kroppen uten å endre signatur, eier
-- eller rettigheter.
--
-- ----------------------------------------------------------------------------
-- Funksjonen tar ingen kaller-identitet
--
-- Den er et lesegrunnlag og ikke et endepunkt. Hver flate som eksponerer den,
-- autentiserer først og kaller den etterpå — agenten med legitimasjon (005h),
-- mennesket med sesjon og reviewer-rolle (005t). EXECUTE er revokert fra PUBLIC
-- og gis ingen klientrolle: den eneste veien til innholdet går gjennom en
-- api-funksjon som har avgjort hvem kalleren er.
--
-- NULL for et evidensfunn som ikke finnes. Alle de indre koblingene går på
-- NOT NULL-kolonner med fremmednøkkel (source_id, created_by_actor_id,
-- intervention_drug_id, outcome_concept_id), så en rad som finnes, gir alltid et
-- svar — og NULL betyr derfor «funnet finnes ikke», aldri «noe manglet».
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §6, §10, §11
--   docs/DATABASE_ARCHITECTURE.md §19, §29, §43, §50
--   docs/EVIDENCE_PIPELINE.md §25, §61
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §74.32, §74.36
-- ============================================================================

create function workflow.evidence_extraction_dossier(p_evidence_item_id uuid)
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

comment on function workflow.evidence_extraction_dossier(uuid) is
  'Grunnlaget for én ekstraksjonskontroll: evidensfunnets identitet og opphav, kilden med sin status, kildeversjonen (eller null når ingen er registrert, med retrieved_from og content_hash når den finnes) og hele den strukturerte ekstraksjonen ordrett, inkludert source_locator og raw_extraction (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29). Uttrykket lå inne i api.extraction_verification_input(text, text, uuid, uuid) fra migrasjon 005h og er flyttet hit uendret, slik at den menneskelige kontrollflaten og den deterministiske verifikatoren leser nøyaktig det samme bildet av kilden — to formuleringer ville før eller siden latt mennesket og maskinen kontrollere hvert sitt grunnlag (§4, §9). storage_reference er ikke eksponert, bare om den finnes. Numeriske verdier er ::text, slik at et eksakt desimaltall ikke går veien om en IEEE-754 double før noen leser det. NULL når evidensfunnet ikke finnes; alle de indre koblingene går på NOT NULL-kolonner med fremmednøkkel, så et funn som finnes gir alltid et svar. Tar ingen kaller-identitet og gjør ingen autorisasjon: den er et lesegrunnlag og ikke et endepunkt, og hver flate som eksponerer den autentiserer først. SECURITY DEFINER fordi knowledge, catalog og provenance har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

revoke execute on function workflow.evidence_extraction_dossier(uuid) from public;

-- ----------------------------------------------------------------------------
-- api.extraction_verification_input(...) — uendret utad, ett lesegrunnlag
--
-- Signatur, rettigheter, svarform og avvisninger er de samme. Den eneste
-- forskjellen er hvor projeksjonen står. De to tellingene blir liggende her,
-- fordi de avhenger av hvem som spør og ikke av evidensfunnet.
-- ----------------------------------------------------------------------------
create or replace function api.extraction_verification_input(
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
    select workflow.evidence_extraction_dossier(e.id)
      || jsonb_build_object(
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
    where
      case
        when p_evidence_item_id is not null then e.id = p_evidence_item_id
        else
          -- Arbeidskøen. Se hodekommentaren i migrasjon 005h for hvert av de to
          -- leddene.
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
