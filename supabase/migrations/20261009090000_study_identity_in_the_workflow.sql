-- Migrasjon 013l — studien som en virksom del av arbeidsflyten
--
-- 013g opprettet `knowledge.studies` og `knowledge.study_reports` med sine
-- regler: én kilde hører til høyst én studie, en kobling må ha et dokumentert
-- grunnlag, og en usikker kobling er lagret som usikker. Men ingenting *brukte*
-- dem. Tabellene var et skjema, og et skjema hindrer ingen dobbelttelling.
--
-- Det som manglet, var tre ting:
--
--   1. **En kontrollert skrivevei.** Ingen funksjon opprettet en studie eller
--      koblet en rapport til den, så koblingen kunne bare oppstå ved direkte
--      SQL — og da med den skriverens egen disiplin framfor databasens.
--   2. **En operativ vei som fyller koblingen.** Kildeoppdagelsen registrerer
--      alt forsøksregisternummer som en kildeidentitet (013e, 013h). Den
--      opplysningen er nettopp studiens identitet, og den ble kastet.
--   3. **En leser som bruker den.** Synteseoppgaven ga agenten N evidensfunn
--      uten å si at to av dem er to rapporter om det samme deltakerutvalget.
--      Hovedartikkel, sekundæranalyse og langtidsoppfølging fra samme studie
--      ville dermed kunne bli lest som tre uavhengige utvalg
--      (SOURCE_POLICY.md §7, MONOGRAPH_STANDARD.md).
--
-- Denne migrasjonen lukker alle tre.
--
-- ----------------------------------------------------------------------------
-- Hvorfor grupperingen ikke fjerner noe fra grunnlaget
--
-- Et funn fra en sekundæranalyse er ikke ugyldig fordi hovedartikkelen finnes.
-- Det skal være med i grunnlaget. Det som ikke skal skje, er at *antallet
-- uavhengige utvalg* blir større enn det er. Grupperingen sier derfor hvor mange
-- uavhengige studier grunnlaget faktisk hviler på, og hvilke funn som deler
-- utvalg — den sletter ingenting.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en kilde uten kobling er sin egen enhet
--
-- Fraværet av en registrert kobling er ikke bevis på at to kilder deler studie,
-- og det er heller ikke bevis på at de er uavhengige. Antidep velger den
-- forsiktige lesningen i den retningen som ikke skjuler noe: en ukoblet kilde
-- telles som sin egen enhet, og den usikre koblingen telles for seg, slik at
-- «vi vet ikke» aldri ser ut som «vi har kontrollert det».

-- ----------------------------------------------------------------------------
-- 1. Grupperingen: hvor mange uavhengige studier et evidenssett hviler på
-- ----------------------------------------------------------------------------
create function knowledge.study_units_for_evidence(p_evidence_item_ids uuid[])
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  with funn as (
    select e.id as evidence_item_id, v.source_id
    from unnest(coalesce(p_evidence_item_ids, array[]::uuid[])) as i(id)
    join knowledge.evidence_items e on e.id = i.id
    left join knowledge.source_versions v on v.id = e.source_version_id
  ),
  -- Studien kilden hører til, når koblingen er registrert. Er den ikke det, er
  -- kilden sin egen enhet: et fravær er ikke en opplysning om at to kilder
  -- deler deltakerutvalg.
  enheter as (
    select
      f.evidence_item_id,
      f.source_id,
      r.study_id,
      r.report_role,
      r.certainty,
      coalesce(r.study_id::text, 'kilde:' || coalesce(f.source_id::text, f.evidence_item_id::text))
        as unit_key
    from funn f
    left join knowledge.study_reports r on r.source_id = f.source_id
  ),
  gruppert as (
    select
      u.unit_key,
      max(u.study_id::text) as study_id,
      count(distinct u.evidence_item_id)::integer as evidence_items,
      count(distinct u.source_id)::integer as reports,
      bool_or(u.certainty = 'uncertain') as uncertain,
      array_agg(distinct u.evidence_item_id) as evidence_item_ids
    from enheter u
    group by u.unit_key
  )
  select jsonb_build_object(
    'evidence_items', (select count(*)::integer from enheter),
    -- Tallet som betyr noe: hvor mange uavhengige deltakerutvalg grunnlaget
    -- faktisk hviler på. Er det lavere enn antallet funn, deler noen av dem
    -- studie, og et svar som talte funnene som uavhengige, ville overdrevet
    -- grunnlaget.
    'independent_units', (select count(*)::integer from gruppert),
    'shared_studies', (select count(*)::integer from gruppert g where g.reports > 1),
    'uncertain_linkage', (select count(*)::integer from gruppert g where g.uncertain),
    'units', coalesce((
      select jsonb_agg(jsonb_build_object(
               'study', case when g.study_id is null then null else jsonb_build_object(
                 'label', (select s.label from knowledge.studies s where s.id = g.study_id::uuid),
                 'registry', (select case when s.registry_kind is null then null
                                          else s.registry_kind || ':' || s.registry_id end
                              from knowledge.studies s where s.id = g.study_id::uuid)) end,
               'evidence_items', g.evidence_items,
               'reports', g.reports,
               'uncertain_linkage', g.uncertain,
               'evidence_item_ids', to_jsonb(g.evidence_item_ids))
             order by g.unit_key)
      from gruppert g), '[]'::jsonb));
$$;

comment on function knowledge.study_units_for_evidence(uuid[]) is
  'Hvor mange uavhengige studier et evidenssett hviler på, og hvilke funn som deler deltakerutvalg (SOURCE_POLICY.md §7). Grupperer funnene på studien kilden er registrert som en rapport om; en kilde uten registrert kobling er sin egen enhet, fordi et fravær verken beviser at to kilder deler utvalg eller at de er uavhengige. Sletter ingenting: et funn fra en sekundæranalyse hører fortsatt til grunnlaget, men hovedartikkel og sekundæranalyse teller som én enhet og ikke som to. `uncertain_linkage` teller enhetene der koblingen er registrert som usikker, slik at «vi vet ikke» aldri ser ut som «vi har kontrollert det».';

revoke execute on function knowledge.study_units_for_evidence(uuid[]) from public;

-- ----------------------------------------------------------------------------
-- 2. Den kontrollerte skriveveien
-- ----------------------------------------------------------------------------
create function knowledge.register_study_report(
  p_source_id uuid,
  p_registry_kind text,
  p_registry_id text,
  p_label text,
  p_report_role knowledge.study_report_role,
  p_linkage_basis text,
  p_certainty knowledge.study_link_certainty,
  p_actor_id uuid,
  p_agent_run_id uuid)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_study_id uuid;
  v_existing uuid;
  v_label text;
  v_registry_id text;
begin
  if p_source_id is null or not exists (
    select 1 from knowledge.sources s where s.id = p_source_id) then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kilden finnes ikke.';
  end if;

  if btrim(coalesce(p_linkage_basis, '')) = '' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En rapportkobling må si hva den hviler på.',
      hint = 'Tittel-likhet er ikke et grunnlag: en udokumentert kobling kan slå sammen to studier, og da telles deltakerne én gang for mye eller én gang for lite (SOURCE_POLICY.md §7).';
  end if;

  v_registry_id := nullif(btrim(coalesce(p_registry_id, '')), '');
  v_label := nullif(btrim(coalesce(p_label, '')), '');

  if v_registry_id is null and v_label is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Studien må ha enten et registernummer eller et lesbart navn.';
  end if;

  -- Et registernummer uten et register er ingen identitet: NCT00000000 og
  -- ISRCTN00000000 er ikke det samme nummeret, og uten registeret vet ingen
  -- hvilket av dem raden mener.
  if v_registry_id is not null and nullif(btrim(coalesce(p_registry_kind, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et forsøksregisternummer må si hvilket register det er fra.',
      hint = 'Gyldige registre er clinicaltrials_gov, euctr, isrctn, who_ictrp og other.';
  end if;

  -- Identiteten er registernummeret når det finnes. Uten det er navnet nøkkelen,
  -- og det er en svakere identitet — derfor sier kommentaren på tabellen at
  -- registernummeret er identiteten når den finnes.
  if v_registry_id is not null then
    select s.id into v_study_id
    from knowledge.studies s
    where s.registry_kind = p_registry_kind and s.registry_id = v_registry_id;
  else
    select s.id into v_study_id
    from knowledge.studies s
    where s.registry_kind is null and lower(s.label) = lower(v_label);
  end if;

  if v_study_id is null then
    insert into knowledge.studies
      (registry_kind, registry_id, label, created_by_actor_id)
    values (
      case when v_registry_id is null then null else p_registry_kind end,
      v_registry_id,
      coalesce(v_label, p_registry_kind || ':' || v_registry_id),
      coalesce(p_actor_id,
               (select r.actor_id from provenance.agent_runs r where r.id = p_agent_run_id)))
    returning id into v_study_id;
  end if;

  -- Én kilde hører til høyst én studie. Den samme koblingen på nytt er den
  -- samme koblingen; en *annen* studie er en motsetning, og den skal si fra.
  select r.study_id into v_existing
  from knowledge.study_reports r
  where r.source_id = p_source_id;

  if v_existing is not null then
    if v_existing <> v_study_id then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Kilden er allerede registrert som en rapport om en annen studie.',
        hint = 'Én kilde hører til høyst én studie. Er den forrige koblingen feil, er det den som må rettes — to studier på den samme artikkelen ville gjort vernet mot dobbelttelling uten virkning (SOURCE_POLICY.md §7).';
    end if;
    return v_study_id;
  end if;

  insert into knowledge.study_reports
    (study_id, source_id, report_role, linkage_basis, certainty,
     linked_by_actor_id, linked_by_agent_run_id)
  values (v_study_id, p_source_id, p_report_role, btrim(p_linkage_basis), p_certainty,
          p_actor_id, p_agent_run_id);

  return v_study_id;
end;
$$;

comment on function knowledge.register_study_report(uuid, text, text, text, knowledge.study_report_role, text, knowledge.study_link_certainty, uuid, uuid) is
  'Registrerer at en kilde er en rapport om en studie, og oppretter studien når den ikke finnes (SOURCE_POLICY.md §7). Identiteten er forsøksregisternummeret når det finnes, ellers navnet. Grunnlaget for koblingen er påkrevd, og proveniensen er enten et menneske eller en agentkjøring — en kobling ingen står bak, kan ikke etterprøves. Idempotent for den samme kilden og studien; en *annen* studie på den samme kilden avvises, fordi én kilde hører til høyst én studie.';

revoke execute on function knowledge.register_study_report(uuid, text, text, text, knowledge.study_report_role, text, knowledge.study_link_certainty, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. Redaktørens vei inn
-- ----------------------------------------------------------------------------
create function api.register_study_report(
  p_source_title text,
  p_registry_kind text,
  p_registry_id text,
  p_study_label text,
  p_report_role text,
  p_linkage_basis text,
  p_certain boolean default true)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_source_id uuid;
  v_study_id uuid;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  select s.id into v_source_id
  from knowledge.sources s
  where lower(s.title) = lower(btrim(coalesce(p_source_title, '')))
  order by s.created_at
  limit 1;

  if v_source_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Antidep har ingen kilde med den tittelen.';
  end if;

  v_study_id := knowledge.register_study_report(
    v_source_id, p_registry_kind, p_registry_id, p_study_label,
    coalesce(p_report_role, 'primary_report')::knowledge.study_report_role,
    p_linkage_basis,
    case when p_certain then 'documented'::knowledge.study_link_certainty
         else 'uncertain'::knowledge.study_link_certainty end,
    v_actor_id, null);

  return jsonb_build_object(
    'study', (select s.label from knowledge.studies s where s.id = v_study_id),
    'registry', (select case when s.registry_kind is null then null
                             else s.registry_kind || ':' || s.registry_id end
                 from knowledge.studies s where s.id = v_study_id),
    'reports', (select count(*)::integer from knowledge.study_reports r
                where r.study_id = v_study_id),
    'certain', p_certain);
end;
$$;

comment on function api.register_study_report(text, text, text, text, text, text, boolean) is
  'Redaktørens vei til å si at en artikkel er en rapport om en studie Antidep alt kjenner, eller om en ny (SOURCE_POLICY.md §7). Kilden navngis med tittelen sin og aldri med en intern id: teknisk registrering er ikke klinikerens arbeid. Grunnlaget for koblingen er påkrevd, og en usikker kobling registreres som usikker framfor å bli utelatt — en kobling ingen tør stå for, er fortsatt en opplysning om at de to kan dele deltakerutvalg. Krever redaktørmandat.';

revoke execute on function api.register_study_report(text, text, text, text, text, text, boolean) from public;
grant execute on function api.register_study_report(text, text, text, text, text, text, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. Den operative veien som fyller koblingen
--
-- Uendret bortsett fra registreringen av studien når kandidaten ble funnet på
-- et forsøksregisternummer.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION workflow.ensure_monograph_candidate_source(p_candidate_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_cand workflow.monograph_candidate_sources;
  v_system knowledge.source_identifier_system;
  v_value text;
  v_profile_code text;
  v_source_id uuid;
begin
  select c.* into v_cand
  from workflow.monograph_candidate_sources c
  where c.id = p_candidate_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kandidatkilden finnes ikke.';
  end if;

  if v_cand.source_id is not null then
    return v_cand.source_id;
  end if;

  v_system := workflow.monograph_candidate_identifier_system(v_cand.identifier_kind);
  if v_system is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kandidaten er bare identifisert med en tittel, og kan ikke registreres som en kilde.',
      hint = 'En tittel er ikke en identitet: to publikasjoner kan hete det samme. Registrer treffets DOI, PMID, PMCID, adresse eller forsøksregisternummer først (SOURCE_POLICY.md §4.3).';
  end if;

  v_value := workflow.monograph_normalized_identifier(
    v_cand.identifier_kind, v_cand.identifier_value);

  select sp.code into v_profile_code
  from workflow.monograph_search_plans p
  join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
  where p.id = v_cand.plan_id;

  -- Låsen gjør «finn eller opprett» til én udelelig handling, og den står på
  -- den normaliserte identifikatoren og ikke på en rad — nettopp fordi raden
  -- ennå ikke finnes. Uten den ville to samtidige innhentinger av den samme
  -- artikkelen begge sett «finnes ikke», og begge opprettet hver sin.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'antidep:kilde-identifikator:' || v_system::text || ':' || v_value, 0));

  select i.source_id into v_source_id
  from knowledge.source_identifiers i
  where i.identifier_system = v_system and i.identifier_value = v_value;

  if v_source_id is null then
    -- Kilden og identifikatoren settes inn i den samme underblokken med vilje:
    -- taper vi kappløpet mot en annen skrivevei, skal *begge* innsettingene
    -- rulles tilbake. Lå kilderaden utenfor, ville taperen etterlatt en
    -- publikasjon uten identifikator — en rad den neste innhentingen ikke
    -- ville funnet igjen.
    begin
      insert into knowledge.sources (
        source_type, title, authors_or_issuer, publisher_or_journal,
        publication_date, publication_date_precision, created_by_actor_id
      )
      values (
        coalesce(workflow.monograph_profile_source_type(v_profile_code),
                 'journal_article'::knowledge.source_type),
        v_cand.title,
        -- Det treffet faktisk oppgav. Taushet er ikke en forfatterliste, og
        -- den står som det den er framfor å bli fylt inn ved gjetning.
        coalesce(nullif(btrim(coalesce(v_cand.authors_or_issuer, '')), ''),
                 nullif(btrim(coalesce(v_cand.publisher_or_journal, '')), ''),
                 'ikke oppgitt i søketreffet'),
        v_cand.publisher_or_journal,
        case when v_cand.publication_year is null then null
             else make_date(v_cand.publication_year, 1, 1) end,
        case when v_cand.publication_year is null then null
             else 'year'::knowledge.date_precision end,
        v_cand.recorded_by_actor_id
      )
      returning id into v_source_id;

      insert into knowledge.source_identifiers
        (source_id, identifier_system, identifier_value)
      values (v_source_id, v_system, v_value);
    exception
      when unique_violation then
        select i.source_id into v_source_id
        from knowledge.source_identifiers i
        where i.identifier_system = v_system and i.identifier_value = v_value;
        if v_source_id is null then
          raise exception using
            errcode = 'restrict_violation',
            message = 'Kilden kunne ikke registreres nå.',
            hint = 'Unikhetskravet på identifikatoren slo til, men raden som vant, fantes ikke da den ble slått opp igjen. Det er en tilstand innhentingen ikke kan tolke, og den stopper framfor å opprette en publikasjon til.';
        end if;
    end;
  end if;

  -- Forsøksregisternummeret er studiens identitet, ikke bare kildens.
  --
  -- Fant kildeoppdagelsen treffet på et registernummer, vet Antidep i det samme
  -- øyeblikket hvilken studie rapporten handler om. Koblingen registreres her,
  -- gjennom den kontrollerte veien og med kjøringen som fant den som proveniens
  -- — ellers ville opplysningen vært kastet, og hovedartikkel og
  -- langtidsoppfølging fra samme studie ville senere sett ut som to uavhengige
  -- deltakerutvalg (SOURCE_POLICY.md §7).
  if v_cand.identifier_kind = 'registry_id' then
    perform knowledge.register_study_report(
      v_source_id,
      'other',
      v_value,
      v_cand.title,
      'registry_record'::knowledge.study_report_role,
      format('Kildeoppdagelsen fant treffet på forsøksregisternummeret %s, som er studiens egen identitet.', v_value),
      'documented'::knowledge.study_link_certainty,
      case when v_cand.proposed_by_agent_run_id is null
           then v_cand.recorded_by_actor_id end,
      v_cand.proposed_by_agent_run_id);
  end if;

  update workflow.monograph_candidate_sources c
  set source_id = v_source_id
  where c.id = p_candidate_id;

  return v_source_id;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 5. Synteseoppgaven bærer grupperingen
--
-- Uendret bortsett fra `study_units` i materialet agenten leser. Feltet ligger
-- med vilje i materialet og ikke i bindingen: bindingen er det oppgavenøkkelen
-- og forespørselsavtrykket regnes av, og en kobling registrert i etterkant
-- skal ikke gjøre en utestående oppgave til en annen oppgave.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION workflow.agent_task(p_job workflow.pipeline_jobs)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_manifest jsonb := p_job.input_manifest;
  v_contract jsonb := workflow.agent_task_contract(p_job.agent_role);
  v_binding jsonb;
  v_input jsonb;
  v_subject jsonb;
  v_ignored jsonb;
  v_prior jsonb := '[]'::jsonb;
  v_model provenance.role_model_assignments;
  v_source_version_id uuid;
  v_revision_id uuid;
  v_evidence_ids uuid[];
  v_drug_ids uuid[];
  v_outcome_ids uuid[];
  v_population_ids uuid[];
  v_plan_id uuid;
begin
  if p_job.agent_role = 'evidence_extraction' then
    v_source_version_id := workflow.manifest_uuid(v_manifest, 'source_version_id');
    v_drug_ids := workflow.manifest_uuids(v_manifest, 'drug_ids');
    v_outcome_ids := workflow.manifest_uuids(v_manifest, 'outcome_concept_ids');
    v_population_ids := coalesce(workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]);

    select jsonb_build_object(
             'source_id', sv.source_id,
             'source_version_id', sv.id,
             'content_hash', sv.content_hash,
             'representation', sv.representation::text,
             'document_sha256', sv.document_sha256,
             'drug_ids', to_jsonb(v_drug_ids),
             'outcome_concept_ids', to_jsonb(v_outcome_ids),
             'population_ids', to_jsonb(v_population_ids)
           ),
           jsonb_build_object(
             'source', jsonb_build_object(
               'source_id', s.id,
               'title', s.title,
               'authors_or_issuer', s.authors_or_issuer,
               'publisher_or_journal', s.publisher_or_journal,
               'publication_date', s.publication_date,
               'source_type', s.source_type::text
             ),
             'source_version', jsonb_build_object(
               'source_version_id', sv.id,
               'retrieved_from', sv.retrieved_from,
               'retrieved_at', sv.retrieved_at,
               'content_hash', sv.content_hash,
               'representation', sv.representation::text,
               'document_sha256', sv.document_sha256
             ),
             'representation_text', knowledge.source_version_text(sv.id),
             'drugs', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'drug_id', d.id, 'label', d.canonical_name) order by d.canonical_name), '[]'::jsonb)
               from catalog.drugs d where d.id = any (v_drug_ids)
             ),
             'outcomes', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'outcome_concept_id', c.id, 'label', c.canonical_label) order by c.canonical_label), '[]'::jsonb)
               from catalog.clinical_concepts c where c.id = any (v_outcome_ids)
             ),
             'populations', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'population_id', p.id, 'label', p.canonical_label) order by p.canonical_label), '[]'::jsonb)
               from catalog.populations p where p.id = any (v_population_ids)
             )
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from knowledge.source_versions sv
    join knowledge.sources s on s.id = sv.source_id
    where sv.id = v_source_version_id;

  elsif p_job.agent_role = 'claim_synthesis' then
    v_evidence_ids := workflow.manifest_uuids(v_manifest, 'evidence_item_ids');

    select jsonb_build_object(
             'topic_concept_id', workflow.manifest_uuid(v_manifest, 'topic_concept_id'),
             'subject_drug_id', workflow.manifest_uuid(v_manifest, 'subject_drug_id'),
             'claim_id', workflow.manifest_uuid(v_manifest, 'claim_id'),
             'monograph_need_id',
               workflow.manifest_uuid(v_manifest, 'monograph_need_id'),
             'population_ids', to_jsonb(coalesce(
               workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[])),
             'evidence', (
               select coalesce(jsonb_agg(
                 jsonb_build_object('evidence_item_id', e.id, 'content_hash', e.content_hash)
                 order by e.id::text), '[]'::jsonb)
               from knowledge.evidence_items e where e.id = any (v_evidence_ids)
             )
           ),
           jsonb_build_object(
             'topic', jsonb_build_object(
               'topic_concept_id', c.id, 'label', c.canonical_label),
             'subject_drug', jsonb_build_object(
               'drug_id', d.id, 'label', d.canonical_name),
             'claim_id', workflow.manifest_uuid(v_manifest, 'claim_id'),
             -- Spørsmålet syntesen svarer på, ordrett fra standarden, med
             -- avgrensningen behovet har. Uten det ville agenten fått et
             -- grunnlag uten å få vite hvilket spørsmål det er grunnlag for
             -- (MONOGRAPH_STANDARD.md §2).
             'monograph_need', knowledge.monograph_need_brief(
               workflow.manifest_uuid(v_manifest, 'monograph_need_id')),
             -- Hvor mange uavhengige studier grunnlaget hviler på, og hvilke
             -- funn som deler deltakerutvalg. Uten dette ville agenten fått N
             -- funn uten å få vite at to av dem er to rapporter om det samme
             -- utvalget, og en syntese som talte dem som uavhengige, ville
             -- overdrevet grunnlaget (SOURCE_POLICY.md §7).
             'study_units', knowledge.study_units_for_evidence(v_evidence_ids),
             'populations', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'population_id', p.id, 'label', p.canonical_label) order by p.canonical_label), '[]'::jsonb)
               from catalog.populations p
               where p.id = any (coalesce(
                 workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]))
             ),
             'evidence', (
               select coalesce(jsonb_agg(workflow.evidence_extraction_dossier(e.id) order by e.id::text), '[]'::jsonb)
               from knowledge.evidence_items e where e.id = any (v_evidence_ids)
             )
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from catalog.clinical_concepts c, catalog.drugs d
    where c.id = workflow.manifest_uuid(v_manifest, 'topic_concept_id')
      and d.id = workflow.manifest_uuid(v_manifest, 'subject_drug_id');

    select coalesce(jsonb_agg(
             jsonb_build_object('role', r.agent_role::text, 'agent_run_id', r.id)
             order by r.id::text), '[]'::jsonb)
      into v_prior
    from knowledge.evidence_items e
    join provenance.agent_runs r on r.id = e.agent_run_id
    where e.id = any (v_evidence_ids);

  elsif p_job.agent_role = 'monograph_answer' then
    -- Bindingen er behovet, avgrensningsavtrykket og kildeversjonen. Kommer
    -- det en ny kildeversjon eller endrer avgrensningen seg imellom, får
    -- oppgaven et nytt avtrykk, og et svar avgitt på det gamle grunnlaget kan
    -- ikke importeres (ANTIDEP_CONSTITUTION.md regel 5).
    v_source_version_id := workflow.manifest_uuid(v_manifest, 'source_version_id');

    select jsonb_build_object(
             'monograph_need_id', n.id,
             'scope_digest', n.scope_digest,
             'source_version_id', sv.id,
             'content_hash', sv.content_hash,
             'representation', sv.representation::text
           ),
           jsonb_build_object(
             'need', knowledge.monograph_need_brief(n.id),
             'approved_use', (
               select u.approved_use from knowledge.monograph_source_uses u
               where u.need_id = n.id and u.source_version_id = sv.id),
             'drug', (select d.canonical_name from catalog.drugs d
                      join knowledge.monograph_editions e on e.id = n.edition_id
                      where d.id = e.drug_id),
             'source', jsonb_build_object(
               'title', s.title,
               'authors_or_issuer', s.authors_or_issuer,
               'publisher_or_journal', s.publisher_or_journal,
               'source_type', s.source_type::text,
               'publication_date', s.publication_date),
             'source_version', jsonb_build_object(
               'retrieved_from', sv.retrieved_from,
               'retrieved_at', sv.retrieved_at,
               'representation', sv.representation::text,
               'content_hash', sv.content_hash),
             'representation_text', knowledge.source_version_text(sv.id)
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from knowledge.monograph_needs n,
         knowledge.source_versions sv
         join knowledge.sources s on s.id = sv.source_id
    where n.id = workflow.manifest_uuid(v_manifest, 'monograph_need_id')
      and sv.id = v_source_version_id;

  elsif p_job.agent_role in ('source_discovery', 'source_quality_assessment') then
    v_plan_id := workflow.manifest_uuid(v_manifest, 'search_plan_id');

    -- Bindingen er søkeplanen, dens versjon, avgrensningsavtrykket, profilen og
    -- de behovene planen dekket da oppgaven ble bygget — og hvor langt søket
    -- var kommet. Kommer det et nytt søk eller en ny kandidat imellom, får
    -- oppgaven et nytt avtrykk, og et svar avgitt på det gamle grunnlaget kan
    -- ikke importeres (ANTIDEP_CONSTITUTION.md regel 5).
    select jsonb_build_object(
             'search_plan_id', p.id,
             'plan_version', p.plan_version,
             'profile_code', sp.code,
             'scope_digest', p.scope_digest,
             'need_ids', (
               select coalesce(jsonb_agg(pn.need_id order by pn.need_id::text), '[]'::jsonb)
               from workflow.monograph_search_plan_needs pn where pn.plan_id = p.id),
             'searches_seen', coalesce((
               select max(s.registration_ordinal) from workflow.monograph_searches s
               where s.plan_id = p.id and s.plan_version = p.plan_version), 0),
             'candidates_seen', (
               select count(*) from workflow.monograph_candidate_sources c
               where c.plan_id = p.id)
           ),
           workflow.monograph_discovery_task_input(p.id, p_job.agent_role),
           null::jsonb
      into v_binding, v_input, v_ignored
    from workflow.monograph_search_plans p
    join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
    where p.id = v_plan_id;

    -- Kontrollen hviler på generatorens kjøringer, og de står i bindingen:
    -- et svar kan bekrefte hvilke kjøringer det kontrollerte, men ikke velge
    -- dem.
    if p_job.agent_role = 'source_quality_assessment' then
      select coalesce(jsonb_agg(
               jsonb_build_object('role', r.agent_role::text, 'agent_run_id', r.id)
               order by r.id::text), '[]'::jsonb)
        into v_prior
      from workflow.monograph_searches s
      join provenance.agent_runs r on r.id = s.agent_run_id
      where s.plan_id = v_plan_id and s.plan_version = (
        select p.plan_version from workflow.monograph_search_plans p where p.id = v_plan_id);
    end if;

  elsif p_job.agent_role = 'evidence_assessment' then
    v_revision_id := workflow.manifest_uuid(v_manifest, 'claim_revision_id');

    select jsonb_build_object(
             'claim_revision_id', r.id,
             'revision_content_hash', r.content_hash,
             'evidence_set_digest', knowledge.claim_evidence_set_digest(r.id)
           ),
           jsonb_build_object(
             'dossier', workflow.claim_evidence_dossier(r.id),
             'seen_evidence_set_digest', knowledge.claim_evidence_set_digest(r.id)
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from knowledge.claim_revisions r
    where r.id = v_revision_id;

    select coalesce(jsonb_agg(
             jsonb_build_object('role', x.role, 'agent_run_id', x.run_id)
             order by x.role, x.run_id::text), '[]'::jsonb)
      into v_prior
    from (
      select r.agent_role::text as role, r.id as run_id
      from knowledge.claim_revisions cr
      join provenance.agent_runs r on r.id = cr.agent_run_id
      where cr.id = v_revision_id
      union all
      select r.agent_role::text, r.id
      from workflow.claim_verifications v
      join provenance.agent_runs r on r.id = v.agent_run_id
      where v.claim_revision_id = v_revision_id
    ) x;
  else
    -- Uttømmende over rollene som kan settes ut. En rolle uten en gren ville
    -- ellers gitt en oppgave uten inndata, og et svar bundet til ingenting.
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Rollen %s har ingen oppgaveform.', p_job.agent_role);
  end if;

  v_subject := workflow.agent_task_subject(p_job);
  v_model := provenance.current_semantic_model(p_job.agent_role);

  v_binding := jsonb_build_object(
    'task_version', workflow.agent_handoff_task_version(),
    'role', p_job.agent_role::text,
    'job_key', p_job.job_key,
    'pipeline_job_id', p_job.id,
    'prompt_template_version', v_contract ->> 'prompt_template_version',
    'output_schema_version', v_contract ->> 'output_schema_version',
    -- Tildelingen er en del av det som binder svaret. Byttes modellen, får hver
    -- utestående oppgave et nytt avtrykk, og et svar avgitt under den gamle
    -- tildelingen kan ikke komme tilbake og registrere den gamle modellen på
    -- nytt (ANTIDEP_CONSTITUTION.md regel 3). Tildelingens id står med, fordi to
    -- tildelinger av den samme modellen er to avgjørelser.
    'semantic_model', case when v_model.id is null then null else jsonb_build_object(
      'assignment_id', v_model.id,
      'provider', v_model.provider,
      'model', v_model.model,
      'model_version', v_model.model_version,
      'model_version_disclosure', v_model.model_version_disclosure::text
    ) end,
    'input', v_binding,
    'prior_runs', v_prior
  );

  return jsonb_build_object(
    'task_version', workflow.agent_handoff_task_version(),
    'answer_version', workflow.agent_handoff_answer_version(),
    'pipeline_job_id', p_job.id,
    'job_key', p_job.job_key,
    'role', p_job.agent_role::text,
    'prompt_template_version', v_contract ->> 'prompt_template_version',
    'output_schema_version', v_contract ->> 'output_schema_version',
    'request_digest', workflow.agent_task_digest(v_binding),
    'binding', v_binding,
    'subject', v_subject,
    'registered_model', case when v_model.id is null then null else jsonb_build_object(
      'provider', v_model.provider,
      'model', v_model.model,
      'model_version', v_model.model_version,
      'model_version_disclosure', v_model.model_version_disclosure::text
    ) end,
    'input', v_input
  );
end;
$function$;
