-- ============================================================================
-- Migrasjon 005m — grunnlaget for en påstandskontroll, ett sted
--
-- Den menneskelige reviewflaten (005o) skal vise nøyaktig det samme grunnlaget
-- claim-verifikatoren arbeider mot i dag: påstanden i sin helhet, hver
-- evidenslenke med evidensfunnet ordrett, kildens og kildeversjonens adresse og
-- fingeravtrykk, den gjeldende ekstraksjonsverifikasjonen for hvert funn, og
-- registrert evidens på samme virkestoff og endepunkt som ikke er lenket til
-- revisjonen.
--
-- Den projeksjonen finnes allerede — den står inne i
-- api.claim_verification_input(text, text, uuid, uuid) fra migrasjon 005k. To
-- kopier av den ville vært to formuleringer av det samme grunnlaget, og da ville
-- mennesket og maskinen etter hvert kontrollert påstanden mot hvert sitt bilde
-- av evidensen. Det er nøyaktig den feilen ANTIDEP_CONSTITUTION.md §4 og §9 er
-- til for å hindre.
--
-- Denne migrasjonen flytter derfor projeksjonen ut i én funksjon,
-- workflow.claim_evidence_dossier(uuid), og lar api.claim_verification_input
-- kalle den. Ingenting i svaret endres: funksjonen bygger de samme nøklene med
-- de samme uttrykkene, og de to feltene som avhenger av hvem som spør
-- (verifications_by_this_actor og verifications_total) blir liggende igjen i
-- api-funksjonen, der aktøren er kjent.
--
-- Fremover-skrivende, ikke en retusjert linje i 005k: 20260908093000 er allerede
-- kjørt i det hostede prosjektet, og Supabase kjører aldri en registrert
-- migrasjonsversjon på nytt (§74.32). Erstatningen skjer med
-- `create or replace function` som bytter kroppen uten å endre signatur, eier
-- eller rettigheter.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §9, §11, §12
--   docs/DATABASE_ARCHITECTURE.md §21, §29, §30, §43, §50
--   docs/EVIDENCE_PIPELINE.md §39-§41
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §74.30, §74.35
-- ============================================================================

-- ----------------------------------------------------------------------------
-- workflow.claim_evidence_dossier(uuid) — grunnlaget for én påstandsrevisjon
--
-- Tar ingen kaller-identitet og gjør ingen autorisasjon: den er et lesegrunnlag
-- og ikke et endepunkt. Hver flate som eksponerer den, autentiserer først og
-- kaller den etterpå — agenten med legitimasjon (005k), mennesket med sesjon og
-- reviewer-rolle (005o). EXECUTE er revokert fra PUBLIC og gis ingen
-- klientrolle: den eneste veien til innholdet går gjennom en api-funksjon som
-- har avgjort hvem kalleren er.
--
-- NULL for en revisjon som ikke finnes. En tom liste betyr aldri at det ikke
-- finnes noe — se kommentarene på de enkelte nøklene.
-- ----------------------------------------------------------------------------
create function workflow.claim_evidence_dossier(p_claim_revision_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
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
      -- ::text på alle numeric-verdier, av samme grunn som i 005h og 005k: et
      -- JSON-tall blir en IEEE-754 double før noen linje i kjøreren eller
      -- nettleseren leser det, og en avrundet størrelse kunne blitt bekreftet i
      -- stedet for den registrerte.
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
          -- «siste vinner»-rekkefølge som publiseringsgatens G5 bruker, slik at
          -- de to aldri kan bli uenige om hva som er nyest. NULL betyr at ingen
          -- kontroll er registrert — ikke at kontrollen var negativ.
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
    -- Det ene §30-spørsmålet som ikke kan besvares fra lenkene selv: registrert
    -- evidens for samme virkestoff og samme endepunkt som ikke er lenket til
    -- revisjonen. Listen er evidens Antidep HAR registrert, ikke evidensen som
    -- finnes — en tom liste betyr aldri at det ikke finnes motstridende
    -- forskning (ANTIDEP_CONSTITUTION.md §17).
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
    )
  )
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  join provenance.actors author on author.id = r.created_by_actor_id
  join catalog.drugs subject on subject.id = cl.subject_drug_id
  join catalog.clinical_concepts topic on topic.id = cl.topic_concept_id
  left join catalog.populations pop on pop.id = r.population_id
  left join catalog.drugs comparator on comparator.id = r.comparator_drug_id
  where r.id = p_claim_revision_id;
$$;

comment on function workflow.claim_evidence_dossier(uuid) is
  'Hele grunnlaget en kontroll av én påstandsrevisjon skal gjøres mot, som ett jsonb-objekt: påstanden i sin helhet, evidenssettets avtrykk, hver evidenslenke med relasjonstype og begrunnelse, hele evidensfunnet ordrett, kildens og kildeversjonens adresse og fingeravtrykk, den gjeldende ekstraksjonsverifikasjonen for funnet, og unlinked_related_evidence — registrerte evidensfunn for samme virkestoff og endepunkt som ikke er lenket til revisjonen (ANTIDEP_CONSTITUTION.md §4, §9, §11, DATABASE_ARCHITECTURE.md §30). Den siste lista er evidens Antidep har registrert, ikke evidensen som finnes: en tom liste betyr aldri at det ikke finnes motstridende forskning (§17). storage_reference er ikke eksponert, bare om den finnes. NULL når revisjonen ikke finnes. Funksjonen tar ingen kaller-identitet og gjør ingen autorisasjon — den er grunnlaget, ikke endepunktet: api.claim_verification_input(text, text, uuid, uuid) autentiserer en agent før den kaller den, api.claim_review_workspace(uuid) et menneske med reviewer-rolle. At begge leser det samme uttrykket, er poenget: to formuleringer av grunnlaget ville latt mennesket og maskinen kontrollere påstanden mot hvert sitt bilde av evidensen. SECURITY DEFINER fordi knowledge, catalog, provenance og workflow har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

revoke execute on function workflow.claim_evidence_dossier(uuid) from public;

-- ----------------------------------------------------------------------------
-- api.claim_verification_input(...) bygger nå svaret sitt av dossieret
--
-- Signatur, sikkerhetsmodus, rettigheter og svar er uendret. Det eneste som er
-- flyttet, er hvordan hver revisjons objekt settes sammen: nøklene som ikke
-- avhenger av hvem som spør, kommer fra workflow.claim_evidence_dossier(uuid),
-- og de to som gjør det — verifications_by_this_actor og verifications_total —
-- legges på her, der aktøren er kjent. `||` på to jsonb-objekter er en union der
-- høyre side vinner; nøklene er disjunkte, så ingen verdi overskrives.
--
-- Kommentaren på funksjonen er ikke gjentatt: `create or replace function`
-- beholder den, og den beskriver fortsatt funksjonen presist.
-- ----------------------------------------------------------------------------
create or replace function api.claim_verification_input(
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
    select workflow.claim_evidence_dossier(r.id) || jsonb_build_object(
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
