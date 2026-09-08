-- ============================================================================
-- Migrasjon 005k — flaten claim-verifikatoren arbeider gjennom
--
-- To funksjoner i `api`, i samme form og med samme begrunnelse som 005g og 005h
-- gjorde for ekstraksjonsverifikatoren:
--
--   api.claim_verification_input(...)      grunnlaget kontrollen gjøres mot
--   api.register_claim_verification(...)   resultatet, med det som ble kontrollert
--
-- Utvider agentmodellen fra 005e-005j og får derfor neste bokstav i den rekken.
-- Nummeret 009 er fortsatt reservert for DrugProduct-/importfundamentet (§26).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §9, §10, §11, §12, §14, §20
--   docs/DATABASE_ARCHITECTURE.md §21, §30, §33, §43, §44, §49, §50
--   docs/EVIDENCE_PIPELINE.md §39-§41 Citation-verifier, §61, §63
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §49, §74.30-§74.34
--
-- ----------------------------------------------------------------------------
-- Hvorfor lesegrunnlaget er en funksjon og ikke et view
--
-- Samme grunn som for 005h: en agent har ingen `auth.uid()` en RLS-policy kan
-- lese — den har en legitimasjon den oppgir i kallet. Radgrensen må derfor ligge
-- i en funksjon som autentiserer først og leser etterpå, og det er samtidig
-- strammere enn et view: ingenting gis ut før gyldig legitimasjon, riktig rolle
-- og en åpen agentkjøring som tilhører nøyaktig den identiteten, alle tre
-- samtidig.
--
-- ----------------------------------------------------------------------------
-- Hva grunnlaget inneholder, og hvorfor akkurat det
--
-- Spørsmålet claim-verifikatoren skal svare på er EVIDENCE_PIPELINE.md §39 sitt:
-- «støtter denne kilden faktisk denne konkrete påstanden slik den er
-- formulert?» Det krever fire ting, og alle fire er med:
--
--   1. Påstandsrevisjonen i sin helhet — ordlyd, anvendelsesområde, populasjon,
--      tidsrom, komparator, retning, størrelse, forbehold og usikkerhet. En
--      kontroll mot sammendraget av en påstand ville vært den samme feilen §11
--      forbyr på kildesiden.
--   2. Hver evidenslenke med sin registrerte relasjonstype og begrunnelse, og
--      hele evidensfunnet ordrett — i nøyaktig samme form som
--      api.extraction_verification_input(...) leverer det, slik at kjøreren
--      leser de to grunnlagene med den samme koden.
--   3. Kildeversjonens adresse og fingeravtrykk, slik at verifikatoren kan hente
--      representasjonen på nytt og kontrollere at den er den samme
--      ekstraksjonen ble gjort fra (ANTIDEP_CONSTITUTION.md §11).
--   4. Den gjeldende ekstraksjonsverifikasjonen for hvert funn. Uten den ville
--      claim-verifikatoren kontrollert en påstand mot tall ingen har kontrollert
--      mot kilden, og de to leddene ville sett like sikre ut.
--
-- I tillegg: **evidensfunn i basen som *ikke* er lenket til revisjonen, men som
-- gjelder samme virkestoff og samme endepunkt.** Det er det ene spørsmålet i
-- DATABASE_ARCHITECTURE.md §30 en verifikator ikke kan svare på ved å lese
-- lenkene sine — «finnes relevant motstridende evidens som ikke er
-- representert?» — og uten dette leddet ville punktet vært ubesvarbart av
-- konstruksjon (ANTIDEP_CONSTITUTION.md §9, §11).
--
-- Merk hva listen *ikke* er: den er evidens Antidep har registrert, ikke
-- evidensen som finnes. At den er tom, betyr aldri at det ikke finnes
-- motstridende forskning (ANTIDEP_CONSTITUTION.md §17), og funksjonskommentaren
-- sier det der en leser ser det.
-- ============================================================================

create function api.claim_verification_input(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_claim_revision_id uuid default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity_id uuid;
  v_verifier_actor_id uuid;
  v_revisions jsonb;
begin
  -- Autentiser eksplisitt for rollen citation_support_verification. En identitet
  -- i en annen rolle — også ekstraksjonsverifikatoren — avvises her, før noe
  -- leses.
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'citation_support_verification'::provenance.agent_role
  );

  -- Krev en åpen kjøring som tilhører nøyaktig denne identiteten, og la
  -- returverdien være aktøren køen filtreres for. Aktøren er dermed ikke noe
  -- kalleren kan be om på vegne av en annen.
  v_verifier_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  select coalesce(jsonb_agg(revision order by revision ->> 'created_at'), '[]'::jsonb)
  into v_revisions
  from (
    select jsonb_build_object(
      'claim_revision_id', r.id,
      'claim_id', r.claim_id,
      'revision_number', r.revision_number,
      'knowledge_type', r.knowledge_type::text,
      'created_at', r.created_at,
      'created_by_actor_id', r.created_by_actor_id,
      'created_by_actor_key', author.actor_key,
      'created_by_actor_type', author.actor_type::text,
      'content_hash', r.content_hash,
      'claim_retired_at', cl.retired_at,
      'topic_concept_id', cl.topic_concept_id,
      'topic_label', topic.canonical_label,
      'subject_drug_id', cl.subject_drug_id,
      'subject_drug_name', subject.canonical_name,
      'evidence_set_digest', knowledge.claim_evidence_set_digest(r.id),
      'claim', jsonb_build_object(
        'statement', r.statement,
        'scope', r.scope,
        'population_id', r.population_id,
        'population_label', pop.canonical_label,
        'timeframe_min', r.timeframe_min::text,
        'timeframe_max', r.timeframe_max::text,
        'comparator_kind', r.comparator_kind::text,
        'comparator_drug_id', r.comparator_drug_id,
        'comparator_drug_name', comparator.canonical_name,
        'direction', r.direction::text,
        'magnitude_measure', r.magnitude_measure::text,
        -- ::text på alle numeric-verdier, av samme grunn som i 005h: et
        -- JSON-tall blir en IEEE-754 double før noen linje i kjøreren leser det,
        -- og en avrundet størrelse kunne blitt bekreftet i stedet for den
        -- registrerte.
        'magnitude_value', r.magnitude_value::text,
        'magnitude_unit', r.magnitude_unit::text,
        'qualifiers', r.qualifiers,
        'uncertainty_summary', r.uncertainty_summary
      ),
      'links', (
        select coalesce(jsonb_agg(
          jsonb_build_object(
            'claim_evidence_link_id', l.id,
            'relationship_type', l.relationship_type::text,
            'directness', l.directness::text,
            'relevance_note', l.relevance_note,
            'evidence_item', jsonb_build_object(
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
              'source_version', case
                when sv.id is null then null
                else jsonb_build_object(
                  'source_version_id', sv.id,
                  'retrieved_at', sv.retrieved_at,
                  'retrieved_from', sv.retrieved_from,
                  'external_version', sv.external_version,
                  'content_hash', sv.content_hash,
                  'has_storage_reference', sv.storage_reference is not null
                )
              end,
              'extraction', jsonb_build_object(
                'design_code', e.design_code::text,
                'population_id', e.population_id,
                'population_label', epop.canonical_label,
                'population_availability', e.population_availability::text,
                'population_detail', e.population_detail,
                'sample_size', e.sample_size,
                'sample_size_availability', e.sample_size_availability::text,
                'intervention_drug_id', e.intervention_drug_id,
                'intervention_drug_name', ed.canonical_name,
                'intervention_detail', e.intervention_detail,
                'comparator_kind', e.comparator_kind::text,
                'comparator_drug_id', e.comparator_drug_id,
                'comparator_drug_name', ecd.canonical_name,
                'comparator_detail', e.comparator_detail,
                'outcome_concept_id', e.outcome_concept_id,
                'outcome_label', eoc.canonical_label,
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
            ),
            -- Den gjeldende ekstraksjonsverifikasjonen, med samme
            -- «siste vinner»-rekkefølge som publiseringsgatens G5 bruker, slik
            -- at de to aldri kan bli uenige om hva som er nyest. NULL betyr at
            -- ingen kontroll er registrert — ikke at kontrollen var negativ.
            'current_extraction_verification', (
              select jsonb_build_object(
                'evidence_verification_id', ev.id,
                'outcome', ev.outcome::text,
                'source_access', ev.source_access::text,
                'checked_fields', to_jsonb(ev.checked_fields),
                'verified_at', ev.verified_at
              )
              from workflow.evidence_verifications ev
              where ev.evidence_item_id = e.id
              order by ev.verified_at desc, ev.created_at desc, ev.id desc
              limit 1
            )
          )
          order by l.id::text
        ), '[]'::jsonb)
        from knowledge.claim_evidence_links l
        join knowledge.evidence_items e on e.id = l.evidence_item_id
        join knowledge.sources s on s.id = e.source_id
        join provenance.actors creator on creator.id = e.created_by_actor_id
        join catalog.drugs ed on ed.id = e.intervention_drug_id
        join catalog.clinical_concepts eoc on eoc.id = e.outcome_concept_id
        left join catalog.drugs ecd on ecd.id = e.comparator_drug_id
        left join catalog.populations epop on epop.id = e.population_id
        left join knowledge.source_versions sv on sv.id = e.source_version_id
        where l.claim_revision_id = r.id
      ),
      -- Se hodekommentaren: det ene §30-spørsmålet som ikke kan besvares fra
      -- lenkene selv. Registrert evidens for samme virkestoff og samme
      -- endepunkt som ikke er lenket til revisjonen.
      'unlinked_related_evidence', (
        select coalesce(jsonb_agg(
          jsonb_build_object(
            'evidence_item_id', ue.id,
            'source_title', us.title,
            'source_status', us.source_status::text,
            'intervention_drug_name', ud.canonical_name,
            'outcome_label', uoc.canonical_label,
            'reported_direction', ue.reported_direction::text,
            'effect_measure', ue.effect_measure::text,
            'estimate', ue.estimate::text,
            'estimate_unit', ue.estimate_unit::text,
            'created_by_actor_key', ucreator.actor_key
          )
          order by ue.id::text
        ), '[]'::jsonb)
        from knowledge.evidence_items ue
        join knowledge.sources us on us.id = ue.source_id
        join catalog.drugs ud on ud.id = ue.intervention_drug_id
        join catalog.clinical_concepts uoc on uoc.id = ue.outcome_concept_id
        join provenance.actors ucreator on ucreator.id = ue.created_by_actor_id
        where ue.intervention_drug_id = cl.subject_drug_id
          and ue.outcome_concept_id = cl.topic_concept_id
          and not exists (
            select 1
            from knowledge.claim_evidence_links l2
            where l2.claim_revision_id = r.id
              and l2.evidence_item_id = ue.id
          )
      ),
      'verifications_by_this_actor', (
        select count(*)
        from workflow.claim_verifications cv
        where cv.claim_revision_id = r.id
          and cv.verifier_actor_id = v_verifier_actor_id
      ),
      'verifications_total', (
        select count(*)
        from workflow.claim_verifications cv
        where cv.claim_revision_id = r.id
      )
    ) as revision
    from knowledge.claim_revisions r
    join knowledge.claims cl on cl.id = r.claim_id
    join provenance.actors author on author.id = r.created_by_actor_id
    join catalog.drugs subject on subject.id = cl.subject_drug_id
    join catalog.clinical_concepts topic on topic.id = cl.topic_concept_id
    left join catalog.populations pop on pop.id = r.population_id
    left join catalog.drugs comparator on comparator.id = r.comparator_drug_id
    where
      case
        when p_claim_revision_id is not null then r.id = p_claim_revision_id
        else
          -- Arbeidskøen, med samme tre ledd som 005h bruker for evidensfunn.
          --
          --   * Revisjoner aktøren selv har formulert er utelatt: de kan aldri
          --     kontrolleres av den (claim_verifications_separate_actor_check),
          --     så å ha dem i køen ville vært å be om et kall som må avvises.
          --   * Revisjoner denne aktøren allerede har kontrollert er utelatt. En
          --     annen verifikatoraktør ser dem fortsatt: to uavhengige
          --     kontrollag er to aktører, og tabellen er append-only.
          --   * Revisjoner uten en eneste evidenslenke er utelatt. En kontroll
          --     av en påstand er en kontroll mot et grunnlag, og
          --     workflow.assert_claim_verification_complete(uuid) avviser en
          --     registrering uten kontrollerte lenker — køen skal ikke inneholde
          --     arbeid som må avvises.
          r.created_by_actor_id <> v_verifier_actor_id
          and not exists (
            select 1
            from workflow.claim_verifications cv
            where cv.claim_revision_id = r.id
              and cv.verifier_actor_id = v_verifier_actor_id
          )
          and exists (
            select 1
            from knowledge.claim_evidence_links l3
            where l3.claim_revision_id = r.id
          )
      end
  ) as revisions;

  return jsonb_build_object(
    'agent_run_id', p_agent_run_id,
    'verifier_actor_id', v_verifier_actor_id,
    'revisions', v_revisions
  );
end;
$$;

comment on function api.claim_verification_input(text, text, uuid, uuid) is
  'Lesegrunnlaget en autentisert claim-verifikator arbeider fra (ANTIDEP_CONSTITUTION.md §4, §9, §11, EVIDENCE_PIPELINE.md §39, DATABASE_ARCHITECTURE.md §30, §43). Autentiserer identiteten eksplisitt for rollen citation_support_verification og krever en åpen agentkjøring som tilhører den (provenance.assert_agent_run_open(uuid, uuid)); uten begge deler returneres ingenting, og avvisningen er den samme som for enhver mislykket agentautentisering. Uten p_claim_revision_id svarer den med arbeidskøen: påstandsrevisjoner aktøren ikke selv har formulert, ikke selv har kontrollert, og som har minst én evidenslenke. Med p_claim_revision_id svarer den om nøyaktig den revisjonen, også en allerede kontrollert. Svaret er et jsonb-objekt med agent_run_id, verifier_actor_id og revisions, der hver revisjon har påstanden i sin helhet, evidenssettets avtrykk, hver evidenslenke med relasjonstype, begrunnelse, hele evidensfunnet ordrett, kildeversjonens adresse og fingeravtrykk og den gjeldende ekstraksjonsverifikasjonen for funnet, samt unlinked_related_evidence: registrerte evidensfunn for samme virkestoff og endepunkt som ikke er lenket til revisjonen. Den siste lista er det som gjør DATABASE_ARCHITECTURE.md §30 sitt spørsmål om urepresentert motstridende evidens besvarbart i det hele tatt — men den er evidens Antidep har registrert, ikke evidensen som finnes: en tom liste betyr aldri at det ikke finnes motstridende forskning (ANTIDEP_CONSTITUTION.md §17). storage_reference er ikke eksponert, bare om den finnes. SECURITY DEFINER fordi knowledge, catalog, provenance og workflow har RLS med default deny; tomt search_path, og kalleren autentiseres på funksjonens eget kall (§50). EXECUTE går til anon og authenticated av samme grunn som api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb): en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';

revoke execute on function api.claim_verification_input(text, text, uuid, uuid) from public;
grant execute on function api.claim_verification_input(text, text, uuid, uuid)
  to anon, authenticated;

-- ----------------------------------------------------------------------------
-- api.register_claim_verification(...) — den eneste skriveveien
--
-- Samme form og samme begrunnelse som api.register_extraction_verification(...):
-- SECURITY DEFINER, tomt search_path, schemakvalifiserte navn, EXECUTE revokert
-- fra PUBLIC og gitt til anon og authenticated — en agent har ingen brukerkonto,
-- så en kaller uten brukersesjon er anon i Data API-et, og det er legitimasjonen
-- og ikke Data API-rollen som er kontrollen.
--
-- Fire ting er bevisst *ikke* parametre, fordi en parameter er noe kalleren kan
-- velge fritt:
--
--   verifier_actor_id                  utledes av kjøringen (§33)
--   verified_revision_creator_actor_id leses fra revisjonen selv
--   verified_evidence_set_digest       beregnes av databasen (migrasjon 005j)
--   source_access                      utledes som den svakeste av lenkenes
--
-- Den siste er verdt å lese to ganger: den samlede kildetilgangen er den
-- *svakeste* av det verifikatoren faktisk hadde per lenke. Var den en parameter,
-- kunne en kontroll der én lenke bare hadde et sammendrag likevel blitt
-- registrert som `original_source` — og ANTIDEP_CONSTITUTION.md §11 sitt forbud
-- mot å godkjenne på andre agenters sammendrag ville vært omgåelig ved å
-- aggregere.
-- ----------------------------------------------------------------------------
create function api.register_claim_verification(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_claim_revision_id uuid,
  p_outcome text,
  p_source_support text,
  p_population_match text,
  p_comparator_match text,
  p_timeframe_match text,
  p_direction_and_magnitude text,
  p_qualifiers_complete text,
  p_contradictory_evidence_represented text,
  p_citations jsonb,
  p_rationale text,
  p_findings text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_outcome workflow.verification_outcome;
  v_checks workflow.verification_check_result[];
  v_identity_id uuid;
  v_verifier_actor_id uuid;
  v_creator_actor_id uuid;
  v_source_access workflow.verification_source_access;
  v_verification_id uuid;
  v_unknown text;
begin
  -- Vokabularparametrene castes først og for seg, slik at en ukjent verdi gir en
  -- setning som sier hva som er galt, framfor en fremmednøkkelfeil lenger ned.
  -- Vokabularene er offentlig dokumentert (DATABASE_ARCHITECTURE.md §30), så
  -- meldingene røper ingenting autentiseringen skjuler.
  begin
    v_outcome := p_outcome::workflow.verification_outcome;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke et kjent verifikasjonsutfall.', p_outcome),
        hint = 'Gyldige utfall er verified, needs_correction, rejected og uncertain (DATABASE_ARCHITECTURE.md §30).';
  end;

  begin
    v_checks := array[
      p_source_support, p_population_match, p_comparator_match, p_timeframe_match,
      p_direction_and_magnitude, p_qualifiers_complete,
      p_contradictory_evidence_represented
    ]::workflow.verification_check_result[];
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Ett eller flere av de sju kontrollpunktene har en ukjent verdi.',
        hint = 'Gyldige verdier er ok, deviation og not_assessable (DATABASE_ARCHITECTURE.md §30). not_assessable er ikke det samme som ok.';
  end;

  if jsonb_typeof(p_citations) is distinct from 'array' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'p_citations må være en jsonb-liste av kontrollerte evidenslenker.',
      hint = 'Hvert element skal ha claim_evidence_link_id, source_access og relationship_supported, og kan ha source_version_id, checked_content_hash og finding.';
  end if;

  -- Autentiser identiteten eksplisitt for rollen citation_support_verification.
  -- En identitet i en annen rolle — også ekstraksjonsverifikatoren — avvises her,
  -- før noe leses eller skrives.
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'citation_support_verification'::provenance.agent_role
  );

  -- Krev en åpen kjøring som tilhører nøyaktig denne identiteten, og la
  -- returverdien — ikke en klientoppgitt parameter — være aktøren raden
  -- attribueres til. Det finnes ingen parameter å be om en annen aktør gjennom.
  v_verifier_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  -- Hvem som formulerte revisjonen leses her, ikke oppgis av kalleren:
  -- claim_verifications_revision_fkey håndhever at raden peker på den virkelige
  -- forfatteren, og en verdi kalleren kunne valgt fritt ville vært nøyaktig den
  -- innsnikingen kontrollen finnes for å hindre.
  select r.created_by_actor_id into v_creator_actor_id
  from knowledge.claim_revisions r
  where r.id = p_claim_revision_id;

  if v_creator_actor_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstandsrevisjonen %L finnes ikke.', p_claim_revision_id),
      hint = 'Publisering og verifikasjon peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  -- En kontrollrad som viser til en lenke fra en annen revisjon — eller til en
  -- lenke som ikke finnes — avvises med en setning som sier hvilken. De
  -- sammensatte fremmednøklene ville fanget det uansett, men da med en melding
  -- som ikke sier hva kalleren gjorde galt.
  select string_agg(distinct value ->> 'claim_evidence_link_id', ', ')
    into v_unknown
  from jsonb_array_elements(p_citations)
  where not exists (
    select 1
    from knowledge.claim_evidence_links l
    where l.id = nullif(value ->> 'claim_evidence_link_id', '')::uuid
      and l.claim_revision_id = p_claim_revision_id
  );

  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Evidenslenker som ikke tilhører denne revisjonen: %s.', v_unknown),
      hint = 'Hver kontrollrad skal vise til en knowledge.claim_evidence_links-rad på nøyaktig den revisjonen som kontrolleres. Grunnlaget leses fra api.claim_verification_input(text, text, uuid, uuid).';
  end if;

  -- Den samlede kildetilgangen er den svakeste av lenkenes. Se hodekommentaren
  -- over funksjonen for hvorfor dette utledes framfor å oppgis.
  begin
    select c.access into v_source_access
    from (
      select (value ->> 'source_access')::workflow.verification_source_access as access
      from jsonb_array_elements(p_citations)
    ) as c
    order by workflow.source_access_strength(c.access), c.access
    limit 1;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'En av kontrollradene oppgir en ukjent kildetilgang.',
        hint = 'Gyldige verdier er original_source, verifiable_representation og derived_summary (ANTIDEP_CONSTITUTION.md §11).';
  end;

  if v_source_access is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kontrollen oppgir ingen kontrollerte evidenslenker.',
      hint = 'En kontroll av en påstand er en kontroll mot et bestemt grunnlag. Registrer én kontrollrad per evidenslenke på revisjonen (ANTIDEP_CONSTITUTION.md §4, §11).';
  end if;

  insert into workflow.claim_verifications (
    claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id,
    outcome, source_access,
    source_support, population_match, comparator_match, timeframe_match,
    direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
    findings, rationale, verified_at, agent_run_id
  )
  values (
    p_claim_revision_id, v_creator_actor_id, v_verifier_actor_id,
    v_outcome, v_source_access,
    v_checks[1], v_checks[2], v_checks[3], v_checks[4],
    v_checks[5], v_checks[6], v_checks[7],
    p_findings, p_rationale, now(), p_agent_run_id
  )
  returning id into v_verification_id;

  -- Evidensfunnet leses fra lenken, ikke fra kalleren, av samme grunn som
  -- forfatteren over: da kan ingen kontrollrad påstå å ha kontrollert lenke L
  -- mot et annet funn enn det L faktisk peker på.
  begin
    insert into workflow.claim_verification_citations (
      claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
      source_access, source_version_id, checked_content_hash,
      relationship_supported, finding
    )
    select
      v_verification_id,
      p_claim_revision_id,
      l.id,
      l.evidence_item_id,
      (c.value ->> 'source_access')::workflow.verification_source_access,
      nullif(c.value ->> 'source_version_id', '')::uuid,
      nullif(c.value ->> 'checked_content_hash', ''),
      (c.value ->> 'relationship_supported')::workflow.verification_check_result,
      nullif(c.value ->> 'finding', '')
    from jsonb_array_elements(p_citations) as c
    join knowledge.claim_evidence_links l
      on l.id = nullif(c.value ->> 'claim_evidence_link_id', '')::uuid;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'En av kontrollradene har en ukjent verdi for kildetilgang eller kontrollresultat.',
        hint = 'source_access skal være original_source, verifiable_representation eller derived_summary; relationship_supported skal være ok, deviation eller not_assessable.';
  end;

  -- Umiddelbart, i tillegg til constraint-triggeren som kjører ved commit:
  -- skriveveien skal avvise med en gang, og kontrollen skal kunne prøves i en
  -- transaksjon som rulles tilbake (migrasjon 005j, avsnitt 7).
  perform workflow.assert_claim_verification_complete(v_verification_id);

  return v_verification_id;
end;
$$;

comment on function api.register_claim_verification(
  text, text, uuid, uuid, text, text, text, text, text, text, text, text, jsonb, text, text
) is
  'Den kontrollerte skriveveien for at en autentisert claim-verifikator registrerer en kontroll av én påstandsrevisjon mot det registrerte evidensgrunnlaget (ANTIDEP_CONSTITUTION.md §4, §9, §11, DATABASE_ARCHITECTURE.md §30, §43, EVIDENCE_PIPELINE.md §39-§41). Autentiserer identiteten eksplisitt for rollen citation_support_verification (avviser enhver annen rolle, også extraction_verification), krever en åpen agentkjøring i samme rolle som tilhører samme identitet (provenance.assert_agent_run_open(uuid, uuid), som tar radlås på kjøringen), og attribuerer raden til den aktøren kjøringen faktisk tilhører — verken aktør, rolle eller kjøring er parametre kalleren kan oppgi fritt. verified_revision_creator_actor_id leses fra revisjonen selv, verified_evidence_set_digest beregnes av databasen, og source_access utledes som den svakeste kildetilgangen blant de kontrollerte lenkene, slik at en samlet påstand aldri blir sterkere enn det svakeste leddet den hviler på. p_citations er én rad per evidenslenke som ble kontrollert, med claim_evidence_link_id, source_access og relationship_supported, og eventuelt source_version_id, checked_content_hash og finding; evidensfunnet leses fra lenken. Kontrollen må dekke hele evidenssettet til revisjonen, og en bekreftelse kan ikke ha uavklarte lenker under seg — workflow.assert_claim_verification_complete(uuid) kalles på slutten av kallet og håndheves i tillegg av en constraint-trigger ved commit. verified_at settes til now(): denne veien registrerer alltid kontrollen i det den konkluderes. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi workflow, knowledge og provenance har RLS med default deny; tomt search_path, og kalleren autentiseres på funksjonens eget kall (§50). EXECUTE går til anon og authenticated av samme grunn som api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb): en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen. Utover vokabularcastene og lenkekontrollen er ingen feltvalidering duplisert her: constraintene på workflow.claim_verifications og workflow.claim_verification_citations er fasiten, og deres avvisninger propageres uendret — inkludert at en agent aldri kan verifisere sin egen påstand, og at en aktør uten mandat ikke kan registrere raden i det hele tatt.';

revoke execute on function api.register_claim_verification(
  text, text, uuid, uuid, text, text, text, text, text, text, text, text, jsonb, text, text
) from public;
grant execute on function api.register_claim_verification(
  text, text, uuid, uuid, text, text, text, text, text, text, text, text, jsonb, text, text
) to anon, authenticated;
