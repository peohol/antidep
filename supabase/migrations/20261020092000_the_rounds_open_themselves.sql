-- ============================================================================
-- Migrasjon 014d — rundene åpner seg selv for de søkeveiene som finnes
--
-- 014c gjorde registeret sant om hva Antidep kan søke i. Denne migrasjonen
-- gjør det til noe som skjer. Den endrer ingen port og løsner ingen kontroll;
-- den kobler de nye søkeveiene til den kjeden som alt finnes:
--
--   plan opprettes   → Antideps kode åpner én runde per søkemetode registeret
--                      har for planens ventende spor, og utfører dem
--   kildeoppdagelsen → vurderer treffene, velger sentrale kilder og ber
--                      eventuelt om flere søk
--   svaret registres → Antidep åpner neste runde selv for sporene som følger
--                      de valgte kildene (referanser, siterende arbeider), og
--                      for alt leddet ba om
--   runden lukkes    → den semantiske oppgaven kommer tilbake på det nye
--                      grunnlaget, og deretter dekningskontrollens egne motsøk
--
-- Ingen agent har fått nettilgang, og ingen agent får erklære et søk. Det
-- semantiske leddet avgjør *hvilke* kilder som er sentrale; Antideps kode følger
-- dem. En kilde som følges, er en kandidat leddet selv har valgt til innhenting
-- eller inkludert, eller vurdert som mulig konklusjonsendrende — aldri en
-- kilde kjøreren har gjettet på.
--
-- Og en kilde er ikke lenger bare den første planens. Oppgaven, vurderingen og
-- porten leser koblingen fra 014c, slik at en preparatomtale funnet av atten
-- REG-planer kan vurderes i hver av dem.
--
-- Styrende dokumenter: docs/SOURCE_POLICY.md §4.1–§4.4, §6, §8,
-- docs/ANTIDEP_CONSTITUTION.md regel 3, 4, 7, AGENTS.md.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Å åpne én runde, nå med metoden og kildene den skal følge
-- ----------------------------------------------------------------------------

drop function workflow.open_monograph_search_request(
  uuid, provenance.agent_role, integer, workflow.monograph_search_request_origin,
  workflow.monograph_search_strategy, text, text, text[], text[], text, uuid, uuid);

create function workflow.open_monograph_search_request(
  p_plan_id uuid,
  p_role provenance.agent_role,
  p_round integer,
  p_origin workflow.monograph_search_request_origin,
  p_strategy workflow.monograph_search_strategy,
  p_rationale text,
  p_platform text,
  p_method text,
  p_drug_aliases text[],
  p_query_terms text[],
  p_seed_identifiers text[],
  p_filters_note text,
  p_agent_run_id uuid,
  p_actor_id uuid,
  p_supersedes_request_id uuid default null
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_edition knowledge.monograph_editions;
  v_profile text;
  v_platform text := nullif(btrim(coalesce(p_platform, '')), '');
  v_method text := nullif(btrim(coalesce(p_method, '')), '');
  v_tracks text[] := array[]::text[];
  v_id uuid;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;

  if not found or v_plan.closed_at is not null or v_plan.paused_at is not null then
    return null;
  end if;

  if p_role not in ('source_discovery'::provenance.agent_role,
                    'source_quality_assessment'::provenance.agent_role) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Bare kildeleddene har maskinelle søkerunder.';
  end if;

  -- Sporene runden kan erklære: profilens obligatoriske spor som nettopp de
  -- metodene runden betyr, faktisk dekker for profilen. Kontrollens motsøk kan
  -- ikke erklære noen, og raden håndhever det (013v).
  if p_role = 'source_discovery' then
    select e.* into v_edition
    from knowledge.monograph_editions e where e.id = v_plan.edition_id;
    select sp.code into v_profile
    from knowledge.monograph_source_profiles sp where sp.id = v_plan.profile_id;

    select coalesce(array_agg(k.code order by k.ordinal), array[]::text[]) into v_tracks
    from knowledge.monograph_search_tracks k
    join knowledge.monograph_search_track_profiles kp on kp.track_id = k.id
    where k.standard_version = v_edition.standard_version
      and kp.profile_id = v_plan.profile_id
      and exists (
        select 1
        from workflow.monograph_request_methods(v_platform, v_method) rm
        join knowledge.monograph_search_platforms c
          on c.platform = rm.platform and c.method = rm.method
        where c.track_code = k.code
          and (c.profile_codes is null or v_profile = any (c.profile_codes)));
  end if;

  insert into workflow.monograph_search_requests (
    plan_id, plan_version, requested_for_role, search_round,
    origin, strategy, rationale, platform, method,
    drug_aliases, query_terms, seed_identifiers, filters_note, supersedes_request_id,
    track_codes, requested_by_agent_run_id, requested_by_actor_id
  )
  values (
    p_plan_id, v_plan.plan_version, p_role, p_round,
    p_origin, p_strategy, btrim(p_rationale), v_platform, v_method,
    coalesce(p_drug_aliases, array[]::text[]),
    coalesce(p_query_terms, array[]::text[]),
    coalesce(p_seed_identifiers, array[]::text[]),
    nullif(btrim(coalesce(p_filters_note, '')), ''), p_supersedes_request_id,
    v_tracks, p_agent_run_id,
    coalesce(p_actor_id, v_plan.created_by_actor_id)
  )
  on conflict on constraint monograph_search_requests_round_key do nothing
  returning id into v_id;

  return v_id;
end;
$$;

comment on function workflow.open_monograph_search_request(uuid, provenance.agent_role, integer, workflow.monograph_search_request_origin, workflow.monograph_search_strategy, text, text, text, text[], text[], text[], text, uuid, uuid, uuid) is
  'Åpner én maskinell søkerunde på en søkeplanversjon, idempotent på innholdet (strategi, plattform, metode, synonymer, termer og kilder å følge), eventuelt med den brede runden den uttrykkelig erstatter. Sporene runden kan erklære, utledes her av registeret og ikke av kalleren: profilens obligatoriske spor som nettopp rundens søkemetoder dekker for profilen (migrasjon 014c). Dekningskontrollens motsøk får ingen spor. Svarer med rundens id, eller NULL når den fantes fra før eller planen er lukket eller står på pause.';

revoke execute on function workflow.open_monograph_search_request(uuid, provenance.agent_role, integer, workflow.monograph_search_request_origin, workflow.monograph_search_strategy, text, text, text, text[], text[], text[], text, uuid, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. Kildene som skal følges, valgt av kildeoppdagelsen og ikke av kjøreren
-- ----------------------------------------------------------------------------

create function workflow.monograph_unchased_seeds(
  p_plan_id uuid,
  p_platform text,
  p_method text
)
  returns text[]
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(array_agg(x.seed order by x.priority, x.created_at, x.seed), array[]::text[])
  from (
    select c.identifier_kind || ':' || c.identifier_value as seed,
           case
             when l.decision = 'included'::workflow.monograph_candidate_decision then 0
             when l.could_change_conclusion then 1
             else 2
           end as priority,
           c.created_at
    from workflow.monograph_candidate_source_plans l
    join workflow.monograph_candidate_sources c on c.id = l.candidate_source_id
    join workflow.monograph_search_plans p on p.id = l.plan_id
    join knowledge.monograph_search_methods m
      on m.platform = p_platform and m.method = p_method and m.requires_seeds
    where l.plan_id = p_plan_id
      and (l.decision in ('selected_for_retrieval'::workflow.monograph_candidate_decision,
                          'included'::workflow.monograph_candidate_decision)
           or l.could_change_conclusion)
      and c.identifier_kind = any (m.seed_identifier_kinds)
      and workflow.monograph_seed_identifiers_shaped(
            array[c.identifier_kind || ':' || c.identifier_value])
      -- En kilde som allerede er fulgt med denne metoden på denne
      -- planversjonen — i en runde som står, som ble utført, eller som ble gitt
      -- opp — følges ikke én gang til.
      and not exists (
        select 1
        from workflow.monograph_search_requests r
        cross join lateral workflow.monograph_request_methods(r.platform, r.method) rm
        where r.plan_id = p_plan_id
          and r.plan_version = p.plan_version
          and rm.platform = p_platform
          and rm.method = p_method
          and (c.identifier_kind || ':' || c.identifier_value) = any (r.seed_identifiers))
  ) x;
$$;

comment on function workflow.monograph_unchased_seeds(uuid, text, text) is
  'De sentrale kildene på planen som én kildefølgende metode ennå ikke har fulgt: kandidater kildeoppdagelsen har valgt til innhenting, inkludert eller vurdert som mulig konklusjonsendrende, med en identifikatorform metoden kan slå opp. Hvilke kilder som er sentrale, er leddets faglige avgjørelse (SOURCE_POLICY.md §4.2); kjøreren følger bare dem.';

revoke execute on function workflow.monograph_unchased_seeds(uuid, text, text) from public;

create function workflow.monograph_plan_has_unchased_seeds(p_plan_id uuid)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select exists (
    select 1
    from workflow.monograph_search_plans p
    join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
    join workflow.monograph_search_track_attempts a
      on a.plan_id = p.id and a.state in ('pending', 'covered', 'unavailable')
    join knowledge.monograph_search_tracks k on k.id = a.track_id
    join knowledge.monograph_search_platforms c
      on c.track_code = k.code
     and (c.profile_codes is null or sp.code = any (c.profile_codes))
    join knowledge.monograph_search_methods m
      on m.platform = c.platform and m.method = c.method and m.requires_seeds
    where p.id = p_plan_id
      and cardinality(workflow.monograph_unchased_seeds(p.id, m.platform, m.method)) > 0
  );
$$;

comment on function workflow.monograph_plan_has_unchased_seeds(uuid) is
  'Om planen har sentrale kilder en kildefølgende metode for et av planens spor ennå ikke har fulgt. Et oppbrukt søkebudsjett med slike kilder igjen er åpent, ventende arbeid og ikke en fullført følging.';

revoke execute on function workflow.monograph_plan_has_unchased_seeds(uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. Rundene registeret har en vei til
-- ----------------------------------------------------------------------------

create function workflow.open_monograph_machine_rounds(
  p_plan_id uuid,
  p_round integer,
  p_origin workflow.monograph_search_request_origin,
  p_actor_id uuid,
  p_agent_run_id uuid
)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_profile text;
  v_pending text[];
  v_searched text[];
  v_row record;
  v_default_opened boolean := false;
  v_seeds text[];
  v_labels text;
  v_rationale text;
  v_opened integer := 0;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;

  if not found or v_plan.closed_at is not null or v_plan.paused_at is not null
     or p_round > 4 then
    return 0;
  end if;

  select sp.code into v_profile
  from knowledge.monograph_source_profiles sp where sp.id = v_plan.profile_id;

  select coalesce(array_agg(k.code order by k.ordinal)
                    filter (where a.state = 'pending'), array[]::text[]),
         coalesce(array_agg(k.code order by k.ordinal)
                    filter (where a.state in ('pending', 'covered', 'unavailable')),
                  array[]::text[])
    into v_pending, v_searched
  from workflow.monograph_search_track_attempts a
  join knowledge.monograph_search_tracks k on k.id = a.track_id
  where a.plan_id = p_plan_id;

  -- Én runde per søkemetode registeret har for planens ventende spor. De
  -- bibliografiske fritekstsøkene er én runde sammen, slik de alltid har vært:
  -- det er dem en forespørsel uten navngitt metode betyr.
  --
  -- Metodene som følger kilder, vurderes også når sporet deres alt er dekket.
  -- Et spor er dekket av den første kilden som ble fulgt, men hver sentral
  -- kilde skal følges: en kilde leddet valgte etter den første runden, eller
  -- som ikke fikk plass i den, ville ellers aldri blitt fulgt.
  for v_row in
    select m.platform, m.method, m.requires_seeds, m.default_for_requests, m.description,
           array_agg(distinct c.track_code order by c.track_code) as tracks
    from knowledge.monograph_search_methods m
    join knowledge.monograph_search_platforms c
      on c.platform = m.platform and c.method = m.method
    where (c.track_code = any (v_pending)
           or (m.requires_seeds and c.track_code = any (v_searched)))
      and (c.profile_codes is null or v_profile = any (c.profile_codes))
    group by m.platform, m.method, m.requires_seeds, m.default_for_requests, m.description
    order by m.default_for_requests desc, m.requires_seeds, m.platform, m.method
  loop
    select string_agg(k.label, '; ' order by k.ordinal) into v_labels
    from knowledge.monograph_search_tracks k
    join knowledge.monograph_editions e on e.standard_version = k.standard_version
    where e.id = v_plan.edition_id and k.code = any (v_row.tracks);

    -- En runde som allerede står åpen for nøyaktig denne metoden, dekker den.
    -- Kildefølgende metoder vurderes per kilde under, ikke per runde.
    if not v_row.requires_seeds and exists (
      select 1
      from workflow.monograph_search_requests r
      cross join lateral workflow.monograph_request_methods(r.platform, r.method) rm
      where r.plan_id = p_plan_id
        and r.plan_version = v_plan.plan_version
        and r.requested_for_role = 'source_discovery'::provenance.agent_role
        and r.state in ('pending'::workflow.monograph_search_request_state,
                        'unavailable'::workflow.monograph_search_request_state)
        and rm.platform = v_row.platform
        and rm.method = v_row.method
    ) then
      continue;
    end if;

    if v_row.requires_seeds then
      -- Høyst ti kilder per runde, så mange runder som trengs: en runde er én
      -- avgrenset jobb, og hver sentral kilde skal følges. En kilde som står i
      -- en runde, regnes ikke lenger som ufulgt, så løkken går mot tom.
      v_rationale := format(
        'Kildeoppdagelsen har valgt ut sentrale kilder, og Antideps kode følger dem (%s, %s) for sporene: %s. %s',
        v_row.platform, v_row.method, v_labels, v_row.description);
      loop
        v_seeds := (workflow.monograph_unchased_seeds(p_plan_id, v_row.platform, v_row.method))[1:10];
        exit when v_seeds is null or cardinality(v_seeds) = 0;
        exit when workflow.open_monograph_search_request(
                    p_plan_id, 'source_discovery'::provenance.agent_role, p_round, p_origin,
                    'broad'::workflow.monograph_search_strategy, v_rationale,
                    v_row.platform, v_row.method, array[]::text[], array[]::text[], v_seeds,
                    null, p_agent_run_id, p_actor_id) is null;
        v_opened := v_opened + 1;
      end loop;
    elsif v_row.default_for_requests then
      if v_default_opened then
        continue;
      end if;
      v_default_opened := true;
      v_rationale := case p_origin
        when 'plan_opened'::workflow.monograph_search_request_origin then
          'Den nye søkeplanens første maskinelle søkerunde: et bredt orienterende søk over avgrensningen (SOURCE_POLICY.md §4.1).'
        else format(
          'De bibliografiske fritekstsøkene for spor som fortsatt ikke er forsøkt: %s.', v_labels)
      end;
      if workflow.open_monograph_search_request(
           p_plan_id, 'source_discovery'::provenance.agent_role, p_round, p_origin,
           'broad'::workflow.monograph_search_strategy, v_rationale,
           null, null, array[]::text[], array[]::text[], array[]::text[],
           null, p_agent_run_id, p_actor_id) is not null then
        v_opened := v_opened + 1;
      end if;
    else
      v_rationale := format(
        '%s for sporene: %s. %s',
        case p_origin
          when 'plan_opened'::workflow.monograph_search_request_origin
            then 'Den nye søkeplanens første maskinelle runde'
          when 'registry_opened'::workflow.monograph_search_request_origin
            then 'Registeret over søkeveier har fått en maskinell metode'
          else 'En maskinell runde for spor som fortsatt ikke er forsøkt'
        end,
        v_labels, v_row.description);
      if workflow.open_monograph_search_request(
           p_plan_id, 'source_discovery'::provenance.agent_role, p_round, p_origin,
           'broad'::workflow.monograph_search_strategy, v_rationale,
           v_row.platform, v_row.method, array[]::text[], array[]::text[], array[]::text[],
           null, p_agent_run_id, p_actor_id) is not null then
        v_opened := v_opened + 1;
      end if;
    end if;
  end loop;

  return v_opened;
end;
$$;

comment on function workflow.open_monograph_machine_rounds(uuid, integer, workflow.monograph_search_request_origin, uuid, uuid) is
  'Åpner, i én runde, de maskinelle søkene registeret har en vei til for planens ventende obligatoriske spor: én forespørsel per søkemetode, de bibliografiske fritekstsøkene samlet som før, og for referanser og siterende arbeider én forespørsel per metode med de sentrale kildene kildeoppdagelsen har valgt og som ennå ikke er fulgt. En metode som allerede har en åpen runde, åpnes ikke på nytt, og en kilde som er fulgt, følges ikke igjen. Svarer med hvor mange forespørsler som ble åpnet. Brukes når planen opprettes (plan_opened), når kildeoppdagelsens vurdering er registrert (selection_opened), og når registeret får en ny søkevei for et spor (registry_opened) — slik at et utførbart spor aldri venter på at noen husker å be om det (migrasjon 014d).';

revoke execute on function workflow.open_monograph_machine_rounds(uuid, integer, workflow.monograph_search_request_origin, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Kjedeovergangene, med de nye rundene
-- ----------------------------------------------------------------------------

create or replace function workflow.chain_task_for_search_plan(p_plan_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_manifest jsonb;
  v_subject text;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;

  if not found or v_plan.closed_at is not null or v_plan.paused_at is not null then
    return null;
  end if;

  -- Den første runden åpnes her, der planen blir til. Senere runder åpnes av
  -- det semantiske leddets egne søkeforespørsler, og skal ikke kunne oppstå av
  -- seg selv: en runde ingen ba om, ville vært et søk uten en begrunnelse.
  --
  -- Fra migrasjon 014d er den første runden ikke ett bredt litteratursøk, men
  -- én forespørsel per søkemetode registeret har for planens ventende spor: FEST
  -- for den norske myndighetskilden, ClinicalTrials.gov for forsøksregistrene,
  -- oversiktsfilteret for oversiktssøket, og så videre. En plan for en
  -- regulatorisk profil får ikke lenger et litteratursøk den ikke har bruk for.
  if v_plan.discovery_round = 1 then
    perform workflow.open_monograph_machine_rounds(
      p_plan_id, 1, 'plan_opened'::workflow.monograph_search_request_origin,
      v_plan.created_by_actor_id, null);
  end if;

  -- Og porten: den semantiske oppgaven finnes ikke før søkene er utført.
  if workflow.monograph_search_phase_problem(
       p_plan_id, 'source_discovery'::provenance.agent_role) is not null then
    return null;
  end if;

  v_manifest := jsonb_build_object(
    'search_plan_id', v_plan.id,
    'plan_version', v_plan.plan_version,
    'discovery_round', v_plan.discovery_round);

  v_subject := format('%s#d%s', v_plan.id::text, v_plan.discovery_round::text);
  perform workflow.lock_chain_subject('source_discovery'::provenance.agent_role, v_subject);
  if workflow.agent_task_subject_queued('source_discovery'::provenance.agent_role, v_subject) then
    return null;
  end if;

  return workflow.chain_enqueue_job(
    'source_discovery'::provenance.agent_role,
    workflow.agent_task_job_key('source_discovery'::provenance.agent_role, v_manifest),
    v_manifest,
    (select e.ordered_by_actor_id from knowledge.monograph_editions e
     where e.id = v_plan.edition_id),
    null,
    true,
    'Vurderingsoppgaven lagt i køen av den gjennomførte maskinelle søkerunden.');
end;
$$;


comment on function workflow.chain_task_for_search_plan(uuid) is
  'Åpner den maskinelle søkefasen for en ny søkeplan — én runde per søkemetode registeret har for planens ventende spor (migrasjon 014d) — og legger kildeoppdagelsens semantiske vurderingsoppgave i køen når fasen for gjeldende runde er gjort. Rekkefølgen er en port: Antideps deterministiske kode søker først, og den semantiske agenten vurderer resultatene etterpå. Idempotent på planen og runden. Gjør ingenting for en plan som er erklært ferdig eller står på pause. Svarer med jobbens id, eller NULL.';

create or replace function workflow.chain_task_for_search_coverage(p_plan_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_manifest jsonb;
  v_subject text;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;

  if not found or v_plan.closed_at is not null or v_plan.paused_at is not null then
    return null;
  end if;

  -- Kontrollen kontrollerer et utført søk. Finnes det ikke, er det ingenting å
  -- kontrollere ennå (SOURCE_POLICY.md §6).
  if not exists (
    select 1 from workflow.monograph_searches s
    where s.plan_id = p_plan_id
      and s.plan_version = v_plan.plan_version
      and s.outcome in ('executed', 'zero_results')
  ) then
    return null;
  end if;

  if exists (
    select 1 from workflow.monograph_coverage_controls cc
    where cc.plan_id = p_plan_id and cc.plan_version = v_plan.plan_version
  ) then
    return null;
  end if;

  -- Kontrollens egen motsøkerunde. Den åpnes her og ikke av kontrollen selv,
  -- fordi kontrollen ikke skal måtte be om å få være uavhengig: uavhengigheten
  -- er noe Antidep utfører for den, under dens egen identitet og kjøring, og
  -- med en annen strategi enn generatorens (SOURCE_POLICY.md §6).
  if not exists (
    select 1 from workflow.monograph_search_requests r
    where r.plan_id = p_plan_id
      and r.plan_version = v_plan.plan_version
      and r.requested_for_role = 'source_quality_assessment'::provenance.agent_role
      and r.search_round = v_plan.control_round
  ) then
    perform workflow.open_monograph_search_request(
      p_plan_id, 'source_quality_assessment'::provenance.agent_role, v_plan.control_round,
      'control_opened'::workflow.monograph_search_request_origin,
      'targeted'::workflow.monograph_search_strategy,
      'Dekningskontrollens egen maskinelle motsøkerunde: målrettede passeringer per akse, atskilt fra generatorens brede søk, slik at kontrollen leter etter det generatoren overså (SOURCE_POLICY.md §6).',
      null, null, array[]::text[], array[]::text[], array[]::text[],
      null, null, v_plan.created_by_actor_id);
  end if;

  if workflow.monograph_search_phase_problem(
       p_plan_id, 'source_quality_assessment'::provenance.agent_role) is not null then
    return null;
  end if;

  v_manifest := jsonb_build_object(
    'search_plan_id', v_plan.id,
    'plan_version', v_plan.plan_version,
    'control_round', v_plan.control_round);

  v_subject := format('%s#c%s', v_plan.id::text, v_plan.control_round::text);
  perform workflow.lock_chain_subject(
    'source_quality_assessment'::provenance.agent_role, v_subject);
  if workflow.agent_task_subject_queued(
       'source_quality_assessment'::provenance.agent_role, v_subject) then
    return null;
  end if;

  return workflow.chain_enqueue_job(
    'source_quality_assessment'::provenance.agent_role,
    workflow.agent_task_job_key('source_quality_assessment'::provenance.agent_role, v_manifest),
    v_manifest,
    (select e.ordered_by_actor_id from knowledge.monograph_editions e
     where e.id = v_plan.edition_id),
    null,
    true,
    'Kontrolloppgaven lagt i køen av den gjennomførte maskinelle motsøkerunden.');
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. Planene bygges bare for profiler som søker
-- ----------------------------------------------------------------------------

create or replace function workflow.build_monograph_search_plans(p_edition_id uuid)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_edition knowledge.monograph_editions;
  v_created integer := 0;
  v_row record;
  v_plan_id uuid;
  v_plan_key text;
  v_new_plans uuid[] := array[]::uuid[];
  v_plan uuid;
begin
  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.id = p_edition_id
  for update;

  if not found or v_edition.superseded_at is not null then
    return 0;
  end if;

  for v_row in
    select
      n.id as need_id,
      n.indication_concept_id, n.outcome_concept_id, n.population_id,
      n.comparator_drug_id, n.switch_target_drug_id,
      n.scope_labels, n.scope_digest,
      sp.id as profile_id, sp.code as profile_code
    from knowledge.monograph_needs n
    join knowledge.monograph_question_templates t on t.id = n.template_id
    join knowledge.monograph_template_profiles tp on tp.template_id = t.id
    join knowledge.monograph_source_profiles sp on sp.id = tp.profile_id
    where n.edition_id = p_edition_id
      and n.relevance = 'relevant'
      and n.work_state <> 'agent_complete'
      -- En profil uten ett eneste obligatorisk spor som er et søk, gjør ingen
      -- selvstendig litteraturjakt, og en søkeplan for den ville vært
      -- søkearbeid uten et spørsmål bak seg (SOURCE_POLICY.md §4.2). Det
      -- gjelder sammendragsleddet: gjenbrukskontrollen er svarkontrollens
      -- derivation_basis (migrasjon 014c).
      and knowledge.monograph_profile_has_search_tracks(sp.id)
    order by n.created_at, sp.ordinal
  loop
    v_plan_key := format('%s|%s', v_row.profile_code, v_row.scope_digest);

    select p.id into v_plan_id
    from workflow.monograph_search_plans p
    where p.edition_id = p_edition_id and p.plan_key = v_plan_key;

    if v_plan_id is null then
      insert into workflow.monograph_search_plans (
        edition_id, profile_id, plan_key,
        indication_concept_id, outcome_concept_id, population_id,
        comparator_drug_id, switch_target_drug_id,
        scope_labels, scope_digest, created_by_actor_id
      )
      values (
        p_edition_id, v_row.profile_id, v_plan_key,
        v_row.indication_concept_id, v_row.outcome_concept_id, v_row.population_id,
        v_row.comparator_drug_id, v_row.switch_target_drug_id,
        v_row.scope_labels, v_row.scope_digest, v_edition.ordered_by_actor_id
      )
      on conflict (edition_id, plan_key) do nothing
      returning id into v_plan_id;

      if v_plan_id is null then
        select p.id into v_plan_id
        from workflow.monograph_search_plans p
        where p.edition_id = p_edition_id and p.plan_key = v_plan_key;
      else
        v_created := v_created + 1;
        v_new_plans := v_new_plans || v_plan_id;

        insert into workflow.monograph_search_track_attempts (plan_id, track_id)
        select v_plan_id, k.id
        from knowledge.monograph_search_tracks k
        join knowledge.monograph_search_track_profiles kp on kp.track_id = k.id
        where k.standard_version = v_edition.standard_version
          and kp.profile_id = v_row.profile_id
        on conflict (plan_id, track_id) do nothing;
      end if;
    end if;

    insert into workflow.monograph_search_plan_needs (plan_id, need_id)
    values (v_plan_id, v_row.need_id)
    on conflict (plan_id, need_id) do nothing;
  end loop;

  -- Søkeoppgavene legges inn etter at sporene og behovskoblingene står, slik at
  -- forhåndskontrollen av grunnlaget leser en komplett plan.
  foreach v_plan in array v_new_plans loop
    perform workflow.chain_task_for_search_plan(v_plan);
  end loop;

  return v_created;
end;
$$;


comment on function workflow.build_monograph_search_plans(uuid) is
  'Bygger søkeplanene for én monografiutgave av de relevante behovene og kildeprofilene deres, og svarer med hvor mange nye planer som ble opprettet. Deterministisk og idempotent. Behov med uavklart relevans får ingen plan, og fra migrasjon 014c heller ikke behov for en profil uten ett eneste obligatorisk spor som er et søk: sammendragsleddet gjør ingen selvstendig litteraturjakt, og gjenbrukskontrollen dets er svarkontrollens (derivation_basis). Oppretter samtidig de obligatoriske søkesporene, som settes til riktig tilstand mot registeret over søkemetoder.';


-- ----------------------------------------------------------------------------
-- 6. Søkeloggen bærer metoden
-- ----------------------------------------------------------------------------

drop function workflow.record_monograph_search(
  uuid, text, text, text, timestamptz, integer, integer, boolean, text,
  workflow.monograph_search_outcome, text, workflow.monograph_execution_evidence,
  text, text, text[], uuid, uuid, uuid);

create function workflow.record_monograph_search(
  p_plan_id uuid,
  p_platform text,
  p_query_string text,
  p_filters text,
  p_executed_at timestamptz,
  p_result_count integer,
  p_screened_count integer,
  p_truncated boolean,
  p_truncation_note text,
  p_outcome workflow.monograph_search_outcome,
  p_limitation_note text,
  p_execution_evidence workflow.monograph_execution_evidence,
  p_evidence_endpoint text,
  p_response_digest text,
  p_track_codes text[],
  p_agent_run_id uuid,
  p_actor_id uuid,
  p_search_request_id uuid,
  p_search_method text
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_edition knowledge.monograph_editions;
  v_unknown text;
  v_search_id uuid;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.id = p_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen finnes ikke.';
  end if;

  if v_plan.closed_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Søkedekningen for denne planen er erklært ferdig.',
      hint = 'Et søk etter at dekningen er erklært, hører til en ny planversjon med sin egen dekningskontroll. Ellers ville erklæringen vist til noe annet enn det som er gjort.';
  end if;

  select e.* into v_edition
  from knowledge.monograph_editions e where e.id = v_plan.edition_id;

  -- Sporkodene skal finnes i standardversjonen, og de skal være obligatoriske
  -- for nettopp denne profilen. Uten kravet kunne et søk erklært å dekke et
  -- spor planen aldri hadde, og porten ville sett dekket ut.
  select string_agg(w.code, ', ' order by w.code) into v_unknown
  from unnest(coalesce(p_track_codes, array[]::text[])) as w(code)
  where not exists (
    select 1
    from knowledge.monograph_search_tracks k
    join knowledge.monograph_search_track_profiles kp on kp.track_id = k.id
    where k.standard_version = v_edition.standard_version
      and k.code = w.code
      and kp.profile_id = v_plan.profile_id
  );
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Søkesporene %s er ikke obligatoriske for denne kildeprofilen.', v_unknown),
      hint = 'Et søk kan bare erklære å dekke et spor profilen faktisk krever (SOURCE_POLICY.md §4.2). Ellers ville porten sett dekket ut uten at noe var forsøkt.';
  end if;

  insert into workflow.monograph_searches (
    plan_id, plan_version, platform, query_string, filters, executed_at,
    result_count, screened_count, truncated, truncation_note,
    outcome, limitation_note,
    execution_evidence, evidence_endpoint, response_digest,
    track_codes, agent_run_id, recorded_by_actor_id, search_request_id,
    search_method
  )
  values (
    p_plan_id, v_plan.plan_version, btrim(p_platform), btrim(p_query_string),
    nullif(btrim(coalesce(p_filters, '')), ''), p_executed_at,
    p_result_count, coalesce(p_screened_count, 0),
    coalesce(p_truncated, false), nullif(btrim(coalesce(p_truncation_note, '')), ''),
    p_outcome, nullif(btrim(coalesce(p_limitation_note, '')), ''),
    p_execution_evidence,
    nullif(btrim(coalesce(p_evidence_endpoint, '')), ''),
    nullif(btrim(coalesce(p_response_digest, '')), ''),
    coalesce(p_track_codes, array[]::text[]), p_agent_run_id, p_actor_id,
    p_search_request_id, nullif(btrim(coalesce(p_search_method, '')), '')
  )
  returning id into v_search_id;

  -- Sporene søket dekket. Et søk som gikk, dekker sporet; et søk som ikke
  -- kunne gå, registrerer sporet som utilgjengelig framfor som dekket — det er
  -- skillet mellom en begrensning og et resultat (SOURCE_POLICY.md §8.2).
  if p_outcome in ('executed', 'zero_results') then
    update workflow.monograph_search_track_attempts a
    set state = 'covered', search_id = v_search_id, note = null
    where a.plan_id = p_plan_id
      and a.state <> 'covered'
      and a.track_id in (
        select k.id from knowledge.monograph_search_tracks k
        where k.standard_version = v_edition.standard_version
          and k.code = any (coalesce(p_track_codes, array[]::text[])));
  else
    update workflow.monograph_search_track_attempts a
    set state = 'unavailable', search_id = null,
        note = coalesce(p_limitation_note, 'Søkeveien var ikke tilgjengelig.')
    where a.plan_id = p_plan_id
      and a.state = 'pending'
      and a.track_id in (
        select k.id from knowledge.monograph_search_tracks k
        where k.standard_version = v_edition.standard_version
          and k.code = any (coalesce(p_track_codes, array[]::text[])));
  end if;

  -- Behovene planen dekker, er nå under søk. Tilstanden er arbeidets og ikke et
  -- faglig utfall.
  update knowledge.monograph_needs n
  set work_state = 'searching', work_state_note = null
  where n.id in (
    select pn.need_id from workflow.monograph_search_plan_needs pn
    where pn.plan_id = p_plan_id)
    and n.relevance = 'relevant'
    and n.work_state in ('not_started', 'technical_stop');

  return v_search_id;
end;
$$;


comment on function workflow.record_monograph_search(uuid, text, text, text, timestamptz, integer, integer, boolean, text, workflow.monograph_search_outcome, text, workflow.monograph_execution_evidence, text, text, text[], uuid, uuid, uuid, text) is
  'Registrerer ett faktisk utført søk på én søkeplan, og oppdaterer sporene søket dekket. Et søk som gikk, dekker sporet; et søk som ikke kunne gå, registrerer sporet som utilgjengelig med sin begrensning framfor som dekket (SOURCE_POLICY.md §8.2). Sporkodene må være obligatoriske for planens kildeprofil, og fra migrasjon 014c bærer søket søkemetoden, som porten på tabellen måler mot registeret. Autentiserer ingenting selv og kalles fra innsiden av en api-funksjon som allerede har fastslått hvem kalleren er.';

revoke execute on function workflow.record_monograph_search(uuid, text, text, text, timestamptz, integer, integer, boolean, text, workflow.monograph_search_outcome, text, workflow.monograph_execution_evidence, text, text, text[], uuid, uuid, uuid, text) from public;


-- ----------------------------------------------------------------------------
-- 7. Arbeidet den maskinelle kjøringen henter, med metodene og kildene
--
-- Med én bestilling er det flere runder enn før, og rekkefølgen betyr noe.
-- Planene til én utgave blir til i én transaksjon og har det samme
-- tidsstempelet, så «order by created_at» ga en tilfeldig rekkefølge mellom
-- dem. Nå tas de i den rekkefølgen rundene ble åpnet — den eldste ventende
-- runden først — slik at en runde som følger en kilde, eller som registeret
-- åpnet, venter i kø framfor bak planer som tilfeldigvis kom først.
-- Planreferansen er valgfri: driften kan kjøre én bestemt plan nå, og
-- ende-til-ende-prøven kjører den planen den følger.
-- ----------------------------------------------------------------------------

drop function api.monograph_discovery_work(text, text);

create function api.monograph_discovery_work(
  p_identity_key text,
  p_secret text,
  p_plan_reference text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity provenance.agent_identities;
  v_identity_id uuid;
  v_rows jsonb;
begin
  select i.* into v_identity
  from provenance.agent_identities i
  where i.identity_key = p_identity_key;

  if not found or v_identity.agent_role not in
       ('source_discovery'::provenance.agent_role,
        'source_quality_assessment'::provenance.agent_role) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Søkearbeidet hentes bare av kildeleddene.',
      hint = 'Kildeoppdagelsen og den separate dekningskontrollen har hver sin identitet. Ingen annen rolle har en vei hit.';
  end if;

  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, v_identity.agent_role);

  select coalesce(jsonb_agg(x.payload order by x.queued_at, x.created_at, x.id), '[]'::jsonb)
    into v_rows
  from (
    select q.queued_at, p.created_at, p.id, jsonb_build_object(
      'plan_reference', p.reference,
      'plan_version', p.plan_version,
      'search_round', workflow.monograph_search_round(p.id, v_identity.agent_role),
      'drug', d.canonical_name,
      'edition_reference', e.reference,
      'standard_version', e.standard_version,
      'profile', jsonb_build_object(
        'code', sp.code,
        'question', sp.question,
        'first_choice', sp.first_choice,
        'supplement', sp.supplement),
      -- Avgrensningen, lesbart. Søkeoppgaven skal kunne oppdage bredere enn den
      -- senere analyseavgrensningen, så dette er rammen og ikke et filter
      -- (SOURCE_POLICY.md §4.1).
      'scope', jsonb_strip_nulls(jsonb_build_object(
        'drug', d.canonical_name,
        -- Katalogens egne synonymer og ATC-koder. Et norsk kanonisk navn gir
        -- ikke treff i EMAs eller ClinicalTrials.govs engelske datasett, og
        -- FEST slås opp på ATC-koden framfor på et navn (migrasjon 014d).
        'drug_aliases', (select coalesce(jsonb_agg(dn.name order by dn.name), '[]'::jsonb)
                         from catalog.drug_names dn
                         where dn.drug_id = d.id and dn.name_type = 'alias'),
        'atc_codes', (select coalesce(jsonb_agg(di.identifier_value order by di.identifier_value), '[]'::jsonb)
                      from catalog.drug_identifiers di
                      where di.drug_id = d.id and di.identifier_system = 'atc'),
        'indication', (select c.canonical_label from catalog.clinical_concepts c
                       where c.id = p.indication_concept_id),
        'outcome', (select c.canonical_label from catalog.clinical_concepts c
                    where c.id = p.outcome_concept_id),
        'population', (select pop.canonical_label from catalog.populations pop
                       where pop.id = p.population_id),
        'comparator', (select cd.canonical_name from catalog.drugs cd
                       where cd.id = p.comparator_drug_id),
        'switch_target', (select td.canonical_name from catalog.drugs td
                          where td.id = p.switch_target_drug_id),
        'labels', case when p.scope_labels = '{}'::jsonb then null else p.scope_labels end)),
      -- Rundene som står uutført. Dette er hele arbeidslisten: kjøringen søker
      -- det noen faktisk har bedt om, og ikke det samme om igjen.
      'requests', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'request_reference', r.reference,
                 'search_round', r.search_round,
                 'origin', r.origin::text,
                 'strategy', r.strategy::text,
                 'rationale', r.rationale,
                 'platform', r.platform,
                 'method', r.method,
                 -- Nøyaktig de (plattform, metode) runden betyr, lest av den
                 -- samme funksjonen registreringen kontrollerer mot. Kjøreren
                 -- gjetter ikke hva en forespørsel uten metode betyr.
                 'methods', (
                   select coalesce(jsonb_agg(jsonb_build_object(
                            'platform', rm.platform, 'method', rm.method)
                            order by rm.platform, rm.method), '[]'::jsonb)
                   from workflow.monograph_request_methods(r.platform, r.method) rm),
                 'seed_identifiers', to_jsonb(r.seed_identifiers),
                 'drug_aliases', to_jsonb(r.drug_aliases),
                 'query_terms', to_jsonb(r.query_terms),
                 'filters_note', r.filters_note,
                 'track_codes', to_jsonb(r.track_codes),
                 'attempts', r.attempts,
                 'state', r.state::text) order by r.created_at), '[]'::jsonb)
        from workflow.monograph_search_requests r
        where r.plan_id = p.id
          and r.plan_version = p.plan_version
          and r.requested_for_role = v_identity.agent_role
          and r.state in ('pending', 'unavailable')),
      -- Behovene planen dekker, med spørsmålet ordrett. Ikke et forventet
      -- klinisk svar: standarden definerer spørsmål, ikke svar
      -- (MONOGRAPH_STANDARD.md §1).
      'needs', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'need_reference', n.reference,
                 'template', t.code,
                 'question', t.prompt,
                 'requirement', t.requirement_text,
                 'answer_form', n.answer_form::text) order by t.ordinal), '[]'::jsonb)
        from workflow.monograph_search_plan_needs pn
        join knowledge.monograph_needs n on n.id = pn.need_id
        join knowledge.monograph_question_templates t on t.id = n.template_id
        where pn.plan_id = p.id),
      -- De obligatoriske søkesporene, med tilstanden sin. Det er disse som må
      -- være forsøkt og dokumentert før dekningen kan erklæres ferdig.
      'tracks', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'code', k.code,
                 'label', k.label,
                 'state', a.state::text,
                 'note', a.note) order by k.ordinal), '[]'::jsonb)
        from workflow.monograph_search_track_attempts a
        join knowledge.monograph_search_tracks k on k.id = a.track_id
        where a.plan_id = p.id),
      'searches_so_far', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'platform', s.platform,
                 'method', s.search_method,
                 'query', s.query_string,
                 'outcome', s.outcome::text,
                 'result_count', s.result_count,
                 'screened_count', s.screened_count,
                 'truncated', s.truncated,
                 'execution_evidence', s.execution_evidence::text,
                 'executed_at', s.executed_at) order by s.executed_at), '[]'::jsonb)
        from workflow.monograph_searches s
        where s.plan_id = p.id and s.plan_version = p.plan_version),
      'candidate_count', (
        select count(*) from workflow.monograph_candidate_source_plans l
        where l.plan_id = p.id),
      -- Kriteriene for å avslutte, som én setning om hva som mangler. Oppgaven
      -- bærer stoppkravene og ikke et forventet svar (SOURCE_POLICY.md §8.1).
      'closure_problem', workflow.monograph_search_closure_problem(p.id)
    ) as payload
    from workflow.monograph_search_plans p
    join knowledge.monograph_editions e on e.id = p.edition_id
    join catalog.drugs d on d.id = e.drug_id
    join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
    cross join lateral (
      select min(r.created_at) as queued_at
      from workflow.monograph_search_requests r
      where r.plan_id = p.id
        and r.plan_version = p.plan_version
        and r.requested_for_role = v_identity.agent_role
        and r.state in ('pending', 'unavailable')
    ) q
    where p.closed_at is null
      and p.paused_at is null
      and e.superseded_at is null
      and q.queued_at is not null
      and (p_plan_reference is null or p.reference = p_plan_reference)
    order by q.queued_at, p.created_at, p.id
    limit 25
  ) x;

  return jsonb_build_object(
    'identity_key', v_identity.identity_key,
    'agent_role', v_identity.agent_role::text,
    'plans', v_rows);
end;
$$;


comment on function api.monograph_discovery_work(text, text, text) is
  'De åpne maskinelle søkerundene kallerens eget kildeledd skal utføre nå, høyst 25 planer, den eldste ventende runden først: avgrensningen med katalogens synonymer og ATC-koder, kildeprofilen, behovene, de obligatoriske søkesporene med tilstanden sin, søkene som er gjort, og selve søkeforespørslene — fra migrasjon 014d med søkemetoden, nøyaktig de (plattform, metode) runden betyr, og de sentrale kildene som skal følges. Med en planreferanse bare den planen. Krever kildeoppdagelsens eller dekningskontrollens egen identitet og legitimasjon, og gir hver av dem bare sine egne runder. SECURITY DEFINER fordi knowledge, workflow og catalog har RLS med default deny.';

revoke execute on function api.monograph_discovery_work(text, text, text) from public;
grant execute on function api.monograph_discovery_work(text, text, text) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 8. Den maskinelle søkeveien, med metoden søket faktisk brukte
--
-- Parameteren er den siste og har en standardverdi, slik at en kjører fra før
-- denne migrasjonen fortsatt registrerer det den gjorde — det bibliografiske
-- fritekstsøket — og ikke noe annet.
-- ----------------------------------------------------------------------------

drop function api.record_monograph_machine_search(
  text, text, uuid, text, text, text, text, text, text, text, text,
  integer, integer, boolean, text, text, text[], jsonb);

create function api.record_monograph_machine_search(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_plan_reference text,
  p_request_reference text,
  p_platform text,
  p_query_string text,
  p_filters text,
  p_endpoint text,
  p_response_digest text,
  p_outcome text,
  p_result_count integer,
  p_screened_count integer,
  p_truncated boolean,
  p_truncation_note text,
  p_limitation_note text,
  p_track_codes text[],
  p_candidates jsonb,
  p_search_method text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity provenance.agent_identities;
  v_identity_id uuid;
  v_plan workflow.monograph_search_plans;
  v_request workflow.monograph_search_requests;
  v_outcome workflow.monograph_search_outcome;
  v_tracks text[];
  v_search_id uuid;
  v_candidate jsonb;
  v_unknown text;
  v_recorded integer := 0;
  v_candidate_id uuid;
  v_method text := coalesce(nullif(btrim(coalesce(p_search_method, '')), ''), 'keyword');
begin
  select i.* into v_identity
  from provenance.agent_identities i
  where i.identity_key = p_identity_key;

  if not found or v_identity.agent_role not in
       ('source_discovery'::provenance.agent_role,
        'source_quality_assessment'::provenance.agent_role) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Et maskinelt utført søk registreres bare av kildeleddene.';
  end if;

  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, v_identity.agent_role);
  perform provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.reference = p_plan_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen finnes ikke.';
  end if;

  -- Runden søket utføres for. Den er obligatorisk: et maskinelt søk uten en
  -- bestilling ville vært en kjøring som søkte fordi den kunne, og ingen runde
  -- ville blitt lukket av det.
  select r.* into v_request
  from workflow.monograph_search_requests r
  where r.reference = p_request_reference
  for update;

  if not found or v_request.plan_id <> v_plan.id then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkerunden finnes ikke på denne søkeplanen.';
  end if;

  if v_request.requested_for_role <> v_identity.agent_role then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Søkerunden hører til det andre kildeleddet.',
      hint = 'Kildeoppdagelsens runder og dekningskontrollens motsøk er to atskilte sett. En kjøring som utførte den andres runde, ville gjort kontrollen til en fortsettelse av det den kontrollerer (SOURCE_POLICY.md §6).';
  end if;

  if v_request.plan_version <> v_plan.plan_version then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Søkerunden hører til en tidligere planversjon.';
  end if;

  if v_request.state not in ('pending', 'unavailable') then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Søkerunden er avsluttet.',
      hint = 'En utført eller oppgitt runde er et historisk faktum søkeloggen hviler på. Trengs det flere søk, er det en ny runde.';
  end if;

  -- Søket må være et av dem runden faktisk bestilte. En runde som ba om
  -- ClinicalTrials.gov, lukkes ikke av et PubMed-søk, og en forespørsel om
  -- oversiktsfilteret oppfylles ikke av et søk uten (migrasjon 014c).
  if not exists (
    select 1 from workflow.monograph_request_methods(v_request.platform, v_request.method) rm
    where rm.platform = btrim(p_platform) and rm.method = v_method
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Søket (%s, %s) er ikke et av dem denne runden bestilte.',
                       btrim(p_platform), v_method),
      hint = 'Hvilke plattformer og metoder en runde betyr, står i søkearbeidet som «methods». Et søk runden ikke ba om, ville lukket en bestilling det ikke utførte.';
  end if;

  -- Sporene søket kan erklære, er rundens og ikke kjøringens. Dekningskontrollens
  -- motsøk har ingen, og et forsøk på å erklære et er en feil og ikke en
  -- utelatelse.
  v_tracks := array(
    select code from unnest(coalesce(p_track_codes, array[]::text[])) as w(code)
    where code = any (v_request.track_codes));

  if cardinality(coalesce(p_track_codes, array[]::text[])) <> cardinality(v_tracks) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Søket erklærer et søkespor denne runden ikke kan dekke.',
      hint = 'Hvilke obligatoriske spor en runde kan erklære, er avgjort når runden åpnes. Dekningskontrollens motsøk kan ikke dekke noen: et motsøk som dekket generatorens spor, ville produsert nettopp den dekningen det kontrollerer (SOURCE_POLICY.md §4.2, §6).';
  end if;

  begin
    v_outcome := p_outcome::workflow.monograph_search_outcome;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke et søkeutfall.', p_outcome),
        hint = 'Utfallene er executed, zero_results, unavailable og failed. De to siste er ikke null treff (SOURCE_POLICY.md §8.2).';
  end;

  v_search_id := workflow.record_monograph_search(
    -- statement_timestamp() og ikke now(): et søk utført nå, og ikke da
    -- transaksjonen begynte. To søk i den samme transaksjonen skal ha to
    -- tidspunkter.
    v_plan.id, p_platform, p_query_string, p_filters, statement_timestamp(),
    p_result_count, p_screened_count, p_truncated, p_truncation_note,
    v_outcome, p_limitation_note,
    'machine_executed'::workflow.monograph_execution_evidence,
    p_endpoint, p_response_digest,
    v_tracks, p_agent_run_id,
    (select r.actor_id from provenance.agent_runs r where r.id = p_agent_run_id),
    v_request.id, v_method);

  if p_candidates is not null then
    if jsonb_typeof(p_candidates) <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Kandidatlisten er ikke en JSON-liste.';
    end if;

    for v_candidate in select value from jsonb_array_elements(p_candidates) loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_candidate) as k(value)
      where k.value not in (
        'identifier_kind', 'identifier_value', 'title', 'authors_or_issuer',
        'publisher_or_journal', 'publication_year', 'discovery_path',
        'access_limited', 'access_limitation_note',
        'could_change_conclusion', 'materiality_reason'
      );
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('Kandidatkilden har felter denne kontrakten ikke kjenner: %s.', v_unknown),
          hint = 'Ukjente felter avvises framfor å ignoreres: et felt med skrivefeil ville ellers sett ut som en utelatt opplysning.';
      end if;

      v_candidate_id := workflow.record_monograph_candidate_source(
        v_plan.id, v_search_id,
        v_candidate ->> 'identifier_kind',
        v_candidate ->> 'identifier_value',
        v_candidate ->> 'title',
        v_candidate ->> 'authors_or_issuer',
        v_candidate ->> 'publisher_or_journal',
        (v_candidate ->> 'publication_year')::integer,
        coalesce(v_candidate ->> 'discovery_path',
                 format('Maskinelt søk i %s', btrim(p_platform))),
        coalesce((v_candidate ->> 'access_limited')::boolean, false),
        v_candidate ->> 'access_limitation_note',
        coalesce((v_candidate ->> 'could_change_conclusion')::boolean, false),
        v_candidate ->> 'materiality_reason',
        p_agent_run_id,
        (select r.actor_id from provenance.agent_runs r where r.id = p_agent_run_id));

      if v_candidate_id is not null then
        v_recorded := v_recorded + 1;
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'plan_reference', v_plan.reference,
    'request_reference', v_request.reference,
    'recorded', true,
    'outcome', v_outcome::text,
    'execution_evidence', 'machine_executed',
    'search_method', v_method,
    'candidates_recorded', v_recorded,
    'closure_problem', workflow.monograph_search_closure_problem(v_plan.id));
end;
$$;


comment on function api.record_monograph_machine_search(text, text, uuid, text, text, text, text, text, text, text, text, integer, integer, boolean, text, text, text[], jsonb, text) is
  'Registrerer ett søk Antidep faktisk utførte selv for én åpen søkerunde, med endepunktet og responsavtrykket som utførelsesbevis, søkemetoden, og kandidatkildene det ga. Utførelsesbeviset settes av funksjonen og kan ikke oppgis av en kaller. Søket må høre til en åpen runde bestilt for kallerens eget ledd, (plattform, metode) må være en av dem runden betyr, og det kan bare erklære de søkesporene runden fikk — og som registeret sier at metoden dekker for planens profil (migrasjon 014c). Uten metode er søket det bibliografiske fritekstsøket, slik en eldre kjører mente det. Krever kildeleddets egen identitet, legitimasjon og en åpen kjøring som tilhører den.';

revoke execute on function api.record_monograph_machine_search(text, text, uuid, text, text, text, text, text, text, text, text, integer, integer, boolean, text, text, text[], jsonb, text) from public;
grant execute on function api.record_monograph_machine_search(text, text, uuid, text, text, text, text, text, text, text, text, integer, integer, boolean, text, text, text[], jsonb, text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 9. Porten leser koblingen, og sier hva et ventende kildefølgende spor venter på
--
-- Kravene er de samme som før. Ingen er fjernet og ingen er mildere; det som
-- er endret, er hvilke kilder «planens kilder» er, og setningen om et spor som
-- venter på at sentrale kilder blir valgt.
-- ----------------------------------------------------------------------------

-- Hva slags søk en rad er, for spørsmålet om et senere søk dekker resten av det:
-- søkemetoden for Antideps egne kall (en eldre maskinell rad uten metode var
-- fritekstsøket), og ellers hvem som utførte det.
create function workflow.monograph_search_kind(p_search workflow.monograph_searches)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case when p_search.execution_evidence = 'machine_executed'
              then coalesce(p_search.search_method, 'keyword')
              else p_search.execution_evidence::text end;
$$;

comment on function workflow.monograph_search_kind(workflow.monograph_searches) is
  'Søkets slag: søkemetoden for et maskinelt utført søk, og ellers hvem som utførte det. Stoppkravet lar et senere søk dekke resten av en avkortet treffliste bare når det er det samme slaget søk på den samme plattformen.';

revoke execute on function workflow.monograph_search_kind(workflow.monograph_searches) from public;

-- Om en runde, direkte eller gjennom en kjede av smalere runder, uttrykkelig
-- erstatter en annen.
create function workflow.monograph_request_supersedes(p_later uuid, p_earlier uuid)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  with recursive chain (id) as (
    select r.supersedes_request_id
    from workflow.monograph_search_requests r
    where r.id = p_later and r.supersedes_request_id is not null
    union
    select r.supersedes_request_id
    from workflow.monograph_search_requests r
    join chain on r.id = chain.id
    where r.supersedes_request_id is not null
  )
  select p_earlier is not null and exists (select 1 from chain where chain.id = p_earlier);
$$;

comment on function workflow.monograph_request_supersedes(uuid, uuid) is
  'Om den senere søkerunden uttrykkelig erstatter den tidligere, direkte eller gjennom en kjede av stadig smalere runder.';

revoke execute on function workflow.monograph_request_supersedes(uuid, uuid) from public;

-- Om resten av en avkortet treffliste er dekket. Et senere, helt lest søk av
-- det samme slaget på den samme plattformen dekker den bare når det er det
-- samme søket — den samme strengen med de samme filtrene — eller når det står
-- i en runde som uttrykkelig erstatter runden det avkortede søket hørte til.
-- Et kort søk om noe annet sier ingenting om resten av en lang treffliste.
create function workflow.monograph_truncation_resolved(p_search workflow.monograph_searches)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select not p_search.truncated or exists (
    select 1 from workflow.monograph_searches later
    where later.plan_id = p_search.plan_id
      and later.plan_version = p_search.plan_version
      and later.platform = p_search.platform
      and workflow.monograph_search_kind(later) = workflow.monograph_search_kind(p_search)
      and not later.truncated
      and later.outcome in ('executed', 'zero_results')
      and later.registration_ordinal > p_search.registration_ordinal
      and ((later.query_string = p_search.query_string
            and later.filters is not distinct from p_search.filters)
           or workflow.monograph_request_supersedes(
                later.search_request_id, p_search.search_request_id))
  );
$$;

comment on function workflow.monograph_truncation_resolved(workflow.monograph_searches) is
  'Om resten av et avkortet søk er dekket: av det samme søket lest helt senere, eller av et helt lest søk med den samme plattformen og metoden i en runde som uttrykkelig erstatter runden det avkortede søket hørte til (SOURCE_POLICY.md §4.1, §4.3).';

revoke execute on function workflow.monograph_truncation_resolved(workflow.monograph_searches) from public;

create or replace function workflow.monograph_search_closure_problem(p_plan_id uuid)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_pending text;
  v_no_path text;
  v_count integer;
  v_last_candidate_ordinal bigint;
  v_control workflow.monograph_coverage_controls;
  v_unresolved text;
  v_open_truncation text;
  v_open_screening text;
  v_seeded_pending text;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.id = p_plan_id;

  if not found then
    return 'Søkeplanen finnes ikke.';
  end if;

  -- 0. Et oppbrukt budsjett er åpent arbeid, ikke en ferdig søkedekning.
  if v_plan.paused_at is not null then
    return format(
      'Søket står på pause og er ikke ferdig: %s. En oppbrukt ressursgrense gir åpent, ventende arbeid og aldri en konklusjon om evidensen.',
      v_plan.paused_reason);
  end if;

  -- 1. Planen skal dekke minst ett behov.
  select count(*) into v_count
  from workflow.monograph_search_plan_needs n where n.plan_id = p_plan_id;
  if v_count = 0 then
    return 'Søkeplanen dekker ikke noe kunnskapsbehov.';
  end if;

  -- 2. Hvert obligatorisk søkespor skal være forsøkt og dokumentert.
  --
  --    Sporene som bare kan utføres ved å følge sentrale kilder — referanse-
  --    lister og siterende arbeider — får sin egen setning. De venter ikke på
  --    en tjeneste; de venter på at kildeoppdagelsen velger ut kildene som er
  --    sentrale, og Antidep følger dem i neste runde (migrasjon 014d).
  select string_agg(t.label, '; ' order by t.ordinal) filter (
           where not exists (
             select 1
             from knowledge.monograph_search_platforms c
             join knowledge.monograph_search_methods m
               on m.platform = c.platform and m.method = c.method
             join knowledge.monograph_source_profiles sp on sp.id = v_plan.profile_id
             where c.track_code = t.code
               and not m.requires_seeds
               and (c.profile_codes is null or sp.code = any (c.profile_codes)))
           and exists (
             select 1
             from knowledge.monograph_search_platforms c
             join knowledge.monograph_search_methods m
               on m.platform = c.platform and m.method = c.method
             where c.track_code = t.code and m.requires_seeds)),
         string_agg(t.label, '; ' order by t.ordinal)
    into v_seeded_pending, v_pending
  from workflow.monograph_search_track_attempts a
  join knowledge.monograph_search_tracks t on t.id = a.track_id
  where a.plan_id = p_plan_id and a.state = 'pending';
  if v_pending is not null then
    return format(
      'Disse obligatoriske søkesporene er ikke forsøkt ennå: %s. Et spor som ikke er forsøkt, hindrer at søkedekningen kan erklæres ferdig (SOURCE_POLICY.md §4.2).%s',
      v_pending,
      case when v_seeded_pending is null then ''
           else format(
             ' %s følger de sentrale kildene: Antidep følger kildene kildeoppdagelsen har valgt til innhenting, inkludert eller vurdert som mulig konklusjonsendrende, i neste maskinelle runde.',
             v_seeded_pending)
      end);
  end if;

  -- 2b. Et spor ingen registrert søkevei dekker, er dokumentert, men ikke
  --     forsøkt. Det kan ikke telle som dekning — da ville porten sagt «dekket»
  --     om et spor ingen har søkt i, som er nøyaktig feilen 013v fjernet. Men
  --     det kan heller ikke bli stående som en stillhet: her står det hvilke
  --     spor det gjelder og hva som løser dem.
  select string_agg(t.label, '; ' order by t.ordinal) into v_no_path
  from workflow.monograph_search_track_attempts a
  join knowledge.monograph_search_tracks t on t.id = a.track_id
  where a.plan_id = p_plan_id and a.state = 'no_machine_path';
  if v_no_path is not null then
    return format(
      'Ingen av Antideps registrerte søkeveier dekker disse obligatoriske søkesporene: %s. Sporet er dokumentert, men ikke forsøkt, og et forsøk som ikke er gjort, kan ikke telle som dekning. En redaktør registrerer utfallet med api.record_monograph_track_by_editor(...) — enten søket redaktøren har gjort, eller hvorfor sporet ikke var tilgjengelig (SOURCE_POLICY.md §4.2).',
      v_no_path);
  end if;

  -- 3. Minst ett søk må faktisk ha gått.
  select count(*) into v_count
  from workflow.monograph_searches s
  where s.plan_id = p_plan_id
    and s.plan_version = v_plan.plan_version
    and s.outcome in ('executed', 'zero_results');
  if v_count = 0 then
    return 'Ingen søk i denne planversjonen har faktisk gått. En utilgjengelig søkevei er en registrert begrensning og ikke en gjennomført søkedekning (SOURCE_POLICY.md §8.2).';
  end if;

  -- 4. Ingen skjult treffavkorting (workflow.monograph_truncation_resolved).
  select string_agg(distinct s.platform || ' (' || workflow.monograph_search_kind(s) || ')', ', '
                    order by s.platform || ' (' || workflow.monograph_search_kind(s) || ')')
    into v_open_truncation
  from workflow.monograph_searches s
  where s.plan_id = p_plan_id
    and s.plan_version = v_plan.plan_version
    and s.truncated
    and not workflow.monograph_truncation_resolved(s);
  if v_open_truncation is not null then
    return format(
      'Trefflisten ble avkortet på %s uten at et senere søk dekket resten. En side med ti treff er ikke et søk uten flere treff (SOURCE_POLICY.md §4.3). Resten er dekket når det samme søket er lest helt, eller når et helt lest, smalere søk med den samme metoden står i en runde som uttrykkelig erstatter den brede (narrows_request).',
      v_open_truncation);
  end if;

  -- 5. Ingen uavklart kilde som med rimelighet kan endre hovedkonklusjonen —
  --    for denne planen. Vurderingen står per plan (migrasjon 014c): en annen
  --    plans eksklusjon lukker ikke denne planens port.
  select string_agg(c.title, '; ' order by c.title) into v_unresolved
  from workflow.monograph_candidate_sources c
  join workflow.monograph_candidate_source_plans l
    on l.candidate_source_id = c.id and l.plan_id = p_plan_id
  where l.could_change_conclusion
    and l.decision not in ('included', 'excluded');
  if v_unresolved is not null then
    return format(
      'Disse kildene kan endre hovedkonklusjonen og er fortsatt uavklarte: %s. En ulest eller utilgjengelig kilde som med rimelighet kan endre svaret, hindrer at søket kan avsluttes (SOURCE_POLICY.md §8.1).',
      v_unresolved);
  end if;

  -- 5b. En manuell passering som ga treff, må enten ha gitt kandidatkilder
  --     eller bære en registrert gjennomgang. For et maskinelt søk leser den
  --     semantiske agenten de registrerte treffene selv; en manuell passering
  --     er det bare redaktøren som har sett, og treffene ville forsvunnet
  --     stille mellom en søkelogg som sa «fire treff, fire gjennomgått» og en
  --     kandidatliste som var tom.
  select string_agg(format('%s (%s treff)', s.platform, s.result_count), '; '
                    order by s.registration_ordinal) into v_open_screening
  from workflow.monograph_searches s
  where s.plan_id = p_plan_id
    and s.plan_version = v_plan.plan_version
    and s.execution_evidence = 'editor_recorded'
    and coalesce(s.result_count, 0) > 0
    and s.screening_note is null
    and not exists (
      select 1 from workflow.monograph_candidate_source_plans l
      where l.search_id = s.id)
    and not exists (
      select 1 from workflow.monograph_candidate_sources c
      where c.search_id = s.id);
  if v_open_screening is not null then
    return format(
      'Disse manuelt utførte søkepasseringene ga treff, men verken en kandidatkilde eller en registrert gjennomgang: %s. Treffene er sett av én person, og en dekning som lukkes her, mister dem stille (SOURCE_POLICY.md §4.3).',
      v_open_screening);
  end if;

  -- 6. Metningssignalet: to supplerende søkepasseringer uten nye kilder.
  --    Gjelder de profilene som faktisk søker i litteraturen. De autoritative
  --    regulatoriske profilene kan klare seg med én riktig, gjeldende kilde, og
  --    sammendragsleddet gjør ingen selvstendig litteraturjakt (§4.2, §8.1) —
  --    å kreve to søkepasseringer av et ledd som ikke søker, er et krav som
  --    aldri kan oppfylles.
  if workflow.monograph_profile_searches_literature(v_plan.profile_id) then
    -- Nytt for planen, og ikke for utgaven: en kilde en annen plan fant først,
    -- er like ny for denne planen som en ingen hadde sett (migrasjon 014c).
    select max(s.registration_ordinal) into v_last_candidate_ordinal
    from workflow.monograph_searches s
    join workflow.monograph_candidate_source_plans l on l.search_id = s.id
    where l.plan_id = p_plan_id;

    if exists (
      select 1 from workflow.monograph_candidate_source_plans l
      where l.plan_id = p_plan_id and l.search_id is null
        and l.created_at > coalesce(
          (select s.created_at from workflow.monograph_searches s
           where s.plan_id = p_plan_id
             and s.plan_version = v_plan.plan_version
             and s.outcome in ('executed', 'zero_results')
           order by s.registration_ordinal desc limit 1),
          '-infinity'::timestamptz)
    ) then
      return 'En kandidatkilde er lagt til etter siste søkepassering. Metningssignalet krever to supplerende passeringer uten nye potensielt konklusjonsendrende kilder (SOURCE_POLICY.md §8.1).';
    end if;

    select count(distinct s.platform) into v_count
    from workflow.monograph_searches s
    where s.plan_id = p_plan_id
      and s.plan_version = v_plan.plan_version
      and s.outcome in ('executed', 'zero_results')
      and (v_last_candidate_ordinal is null
           or s.registration_ordinal > v_last_candidate_ordinal);

    if v_count < 2 then
      return 'Metningssignalet mangler: to ulike supplerende søkepasseringer uten nye potensielt konklusjonsendrende kilder er ikke gjennomført. Dette er Antideps v1-heuristikk og ikke et bevis på uttømmende dekning, men verken «tre artikler er funnet» eller «de første ti treffene er gjennomgått» erstatter den (SOURCE_POLICY.md §8.1).';
    end if;
  end if;

  -- 7. Og den separate kontrollen må godta begrunnelsen for å stoppe.
  select cc.* into v_control
  from workflow.monograph_coverage_controls cc
  where cc.plan_id = p_plan_id and cc.plan_version = v_plan.plan_version;

  if not found then
    return 'Den separate kontrollen av søkedekningen er ikke utført for denne planversjonen. Enighet mellom agenter er ikke i seg selv fasit, og et kontrollledd som bare leser generatorens valgte referanser, kan ikke vurdere dekningsgraden (SOURCE_POLICY.md §6, §8.1).';
  end if;

  if v_control.outcome <> 'accepted' then
    return format(
      'Den separate kontrollen av søkedekningen godtar ikke begrunnelsen for å stoppe: %s',
      v_control.note);
  end if;

  return null;
end;
$$;


-- ----------------------------------------------------------------------------
-- 10. Redaktørens lesning av planen, med metoden og koblingen
-- ----------------------------------------------------------------------------

create or replace function workflow.monograph_search_plan_payload(p_plan workflow.monograph_search_plans)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select jsonb_build_object(
    'reference', p_plan.reference,
    'plan_version', p_plan.plan_version,
    'profile', (select sp.code from knowledge.monograph_source_profiles sp
                where sp.id = p_plan.profile_id),
    'profile_question', (select sp.question from knowledge.monograph_source_profiles sp
                         where sp.id = p_plan.profile_id),
    'scope', jsonb_strip_nulls(jsonb_build_object(
      'indication', (select c.canonical_label from catalog.clinical_concepts c
                     where c.id = p_plan.indication_concept_id),
      'outcome', (select c.canonical_label from catalog.clinical_concepts c
                  where c.id = p_plan.outcome_concept_id),
      'population', (select pop.canonical_label from catalog.populations pop
                     where pop.id = p_plan.population_id),
      'comparator', (select cd.canonical_name from catalog.drugs cd
                     where cd.id = p_plan.comparator_drug_id),
      'switch_target', (select td.canonical_name from catalog.drugs td
                        where td.id = p_plan.switch_target_drug_id),
      'labels', case when p_plan.scope_labels = '{}'::jsonb then null
                     else p_plan.scope_labels end)),
    'needs', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'template', t.code,
               'question', t.prompt,
               'relevance', n.relevance::text,
               'work_state', n.work_state::text) order by t.ordinal), '[]'::jsonb)
      from workflow.monograph_search_plan_needs pn
      join knowledge.monograph_needs n on n.id = pn.need_id
      join knowledge.monograph_question_templates t on t.id = n.template_id
      where pn.plan_id = p_plan.id),
    'tracks', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'label', k.label, 'state', a.state::text, 'note', a.note)
               order by k.ordinal), '[]'::jsonb)
      from workflow.monograph_search_track_attempts a
      join knowledge.monograph_search_tracks k on k.id = a.track_id
      where a.plan_id = p_plan.id),
    -- Søkeloggen slik en fagperson skal kunne lese den: plattform, streng,
    -- filtre, tidspunkt, treffantall, gjennomgått omfang, avkorting og
    -- utførelsesbevis (SOURCE_POLICY.md §4.3).
    'searches', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'platform', s.platform,
               'method', s.search_method,
               'query', s.query_string,
               'filters', s.filters,
               'executed_at', s.executed_at,
               'outcome', s.outcome::text,
               'result_count', s.result_count,
               'screened_count', s.screened_count,
               'truncated', s.truncated,
               'truncation_note', s.truncation_note,
               'limitation_note', s.limitation_note,
               'execution_evidence', s.execution_evidence::text,
               'tracks', to_jsonb(s.track_codes)) order by s.executed_at), '[]'::jsonb)
      from workflow.monograph_searches s where s.plan_id = p_plan.id),
    'candidates', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'reference', c.reference,
               'identifier_kind', c.identifier_kind,
               'identifier_value', c.identifier_value,
               'title', c.title,
               'authors_or_issuer', c.authors_or_issuer,
               'publisher_or_journal', c.publisher_or_journal,
               'publication_year', c.publication_year,
               'discovery_path', c.discovery_path,
               'decision', l.decision::text,
               'decision_reason', l.decision_reason,
               'access_limited', c.access_limited,
               'access_limitation_note', c.access_limitation_note,
               'could_change_conclusion', l.could_change_conclusion,
               'materiality_reason', l.materiality_reason,
               'registered', c.source_id is not null,
               'uses', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'template', t.code, 'proposed_use', cn.proposed_use)
                          order by t.ordinal), '[]'::jsonb)
                 from workflow.monograph_candidate_source_needs cn
                 join knowledge.monograph_needs n on n.id = cn.need_id
                 join knowledge.monograph_question_templates t on t.id = n.template_id
                 -- Bare bruken for planens egne behov: bruken en annen plan har
                 -- foreslått for sine, er den planens (migrasjon 014c).
                 join workflow.monograph_search_plan_needs pn
                   on pn.need_id = cn.need_id and pn.plan_id = p_plan.id
                 where cn.candidate_source_id = c.id))
             order by c.created_at), '[]'::jsonb)
      from workflow.monograph_candidate_sources c
      join workflow.monograph_candidate_source_plans l
        on l.candidate_source_id = c.id and l.plan_id = p_plan.id),
    'coverage_control', (
      select jsonb_build_object(
               'outcome', cc.outcome::text,
               'note', cc.note,
               'searched_independently', cc.searched_independently,
               'missed_candidates', cc.missed_candidates,
               'exclusions_checked', cc.exclusions_checked,
               'materiality_assessed', cc.materiality_assessed,
               'plan_version', cc.plan_version)
      from workflow.monograph_coverage_controls cc
      where cc.plan_id = p_plan.id and cc.plan_version = p_plan.plan_version),
    'closed_at', p_plan.closed_at,
    'closed_note', p_plan.closed_note,
    'paused_at', p_plan.paused_at,
    'paused_reason', p_plan.paused_reason,
    'closure_problem', workflow.monograph_search_closure_problem(p_plan.id));
$$;

-- ----------------------------------------------------------------------------
-- 11. Oppgavematerialet: metodene, hva de dekker, og kildene planen fant
-- ----------------------------------------------------------------------------

create or replace function workflow.monograph_discovery_task_input(
  p_plan_id uuid,
  p_role provenance.agent_role
)
  returns jsonb
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_edition knowledge.monograph_editions;
  v_profile knowledge.monograph_source_profiles;
  v_drug text;
  v_round integer;
  v_payload jsonb;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;
  if not found then
    return null;
  end if;

  select e.* into v_edition from knowledge.monograph_editions e where e.id = v_plan.edition_id;
  select sp.* into v_profile
  from knowledge.monograph_source_profiles sp where sp.id = v_plan.profile_id;
  select d.canonical_name into v_drug from catalog.drugs d where d.id = v_edition.drug_id;

  v_round := workflow.monograph_search_round(p_plan_id, p_role);

  v_payload := jsonb_build_object(
    'search_plan_id', v_plan.id,
    'plan_reference', v_plan.reference,
    'plan_version', v_plan.plan_version,
    'search_round', v_round,
    'rounds_remaining', greatest(4 - v_round, 0),
    'drug', v_drug,
    'standard_version', v_edition.standard_version,
    'source_profile', jsonb_build_object(
      'code', v_profile.code,
      'question', v_profile.question,
      'first_choice', v_profile.first_choice,
      'supplement_and_control', v_profile.supplement),
    'scope', jsonb_strip_nulls(jsonb_build_object(
      'drug', v_drug,
      'indication', (select c.canonical_label from catalog.clinical_concepts c
                     where c.id = v_plan.indication_concept_id),
      'outcome', (select c.canonical_label from catalog.clinical_concepts c
                  where c.id = v_plan.outcome_concept_id),
      'population', (select pop.canonical_label from catalog.populations pop
                     where pop.id = v_plan.population_id),
      'comparator', (select cd.canonical_name from catalog.drugs cd
                     where cd.id = v_plan.comparator_drug_id),
      'switch_target', (select td.canonical_name from catalog.drugs td
                        where td.id = v_plan.switch_target_drug_id),
      'labels', case when v_plan.scope_labels = '{}'::jsonb then null
                     else v_plan.scope_labels end)),
    -- Behovene, med spørsmålet ordrett fra standarden. Ingen forventet
    -- konklusjon, og ingen antydning om retning.
    'needs', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'need_reference', n.reference,
               'template', t.code,
               'section', t.section,
               'question', t.prompt,
               'requirement', t.requirement_text,
               'answer_form', n.answer_form::text) order by t.ordinal), '[]'::jsonb)
      from workflow.monograph_search_plan_needs pn
      join knowledge.monograph_needs n on n.id = pn.need_id
      join knowledge.monograph_question_templates t on t.id = n.template_id
      where pn.plan_id = v_plan.id),
    -- Sporene, med hvilke av Antideps søkemetoder som utfører hvert av dem for
    -- denne profilen. Et spor uten en metode står med sin begrunnelse; et spor
    -- som følger sentrale kilder, sier det (migrasjon 014d).
    'required_tracks', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', k.code, 'label', k.label,
               'state', a.state::text, 'note', a.note,
               'machine_methods', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'platform', m.platform, 'method', m.method,
                          'follows_central_sources', m.requires_seeds)
                          order by m.platform, m.method), '[]'::jsonb)
                 from knowledge.monograph_search_platforms c
                 join knowledge.monograph_search_methods m
                   on m.platform = c.platform and m.method = c.method
                 where c.track_code = k.code
                   and (c.profile_codes is null or v_profile.code = any (c.profile_codes))))
               order by k.ordinal), '[]'::jsonb)
      from workflow.monograph_search_track_attempts a
      join knowledge.monograph_search_tracks k on k.id = a.track_id
      where a.plan_id = v_plan.id),
    -- Søkene Antidep faktisk utførte, med endepunkt og responsavtrykk. Dette
    -- er grunnlaget vurderingen gjelder, og det er maskinelt bekreftet
    -- utførelse og ikke noens beretning (SOURCE_POLICY.md §4.3).
    -- Bare Antideps egne kall. Et redaktørregistrert søk har verken endepunkt
    -- eller responsavtrykk, og å legge det her ville gitt agenten falsk
    -- proveniens: oppgaveteksten sier uttrykkelig at disse er maskinelt
    -- utførte (migrasjon 014a).
    'machine_searches', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'platform', s.platform,
               'method', coalesce(s.search_method, 'keyword'),
               'query', s.query_string,
               'filters', s.filters,
               'outcome', s.outcome::text,
               'result_count', s.result_count,
               'screened_count', s.screened_count,
               'truncated', s.truncated,
               'truncation_note', s.truncation_note,
               -- Om resten av en avkortet treffliste er dekket, og runden en
               -- smalere forespørsel kan oppgi at den erstatter (narrows_request).
               'truncation_resolved', workflow.monograph_truncation_resolved(s),
               'request_reference', (select r.reference from workflow.monograph_search_requests r
                                     where r.id = s.search_request_id),
               'limitation_note', s.limitation_note,
               'endpoint', s.evidence_endpoint,
               'response_digest', s.response_digest,
               'execution_evidence', s.execution_evidence::text,
               'tracks', to_jsonb(s.track_codes),
               'executed_at', s.executed_at,
               'run_role', (select r.agent_role::text from provenance.agent_runs r
                            where r.id = s.agent_run_id))
               order by s.registration_ordinal), '[]'::jsonb)
      from workflow.monograph_searches s
      where s.plan_id = v_plan.id and s.plan_version = v_plan.plan_version
        and s.execution_evidence = 'machine_executed'),
    -- Og passeringene et menneske utførte og registrerte, hver for seg. De er
    -- like sanne, og de er noe annet: ingen kjøring, ingen adresse, intet
    -- avtrykk — en redaktørs dokumenterte arbeid, for et søkespor Antidep ikke
    -- har en maskinell vei til.
    'editor_searches', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'platform', s.platform,
               'query', s.query_string,
               'filters', s.filters,
               'outcome', s.outcome::text,
               'result_count', s.result_count,
               'screened_count', s.screened_count,
               'truncated', s.truncated,
               'truncation_note', s.truncation_note,
               'execution_evidence', s.execution_evidence::text,
               'tracks', to_jsonb(s.track_codes),
               'executed_at', s.executed_at,
               'screening_note', s.screening_note,
               'candidates_recorded', (
                 select count(*) from workflow.monograph_candidate_sources c
                 where c.search_id = s.id))
               order by s.registration_ordinal), '[]'::jsonb)
      from workflow.monograph_searches s
      where s.plan_id = v_plan.id and s.plan_version = v_plan.plan_version
        and s.execution_evidence = 'editor_recorded'),
    -- Og de søkeveiene som ikke svarte, hver for seg. En begrensning som bare
    -- sto som en rad i en lang liste, ville blitt lest som null treff.
    'search_limitations', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'platform', s.platform,
               'outcome', s.outcome::text,
               'limitation_note', s.limitation_note)
               order by s.registration_ordinal), '[]'::jsonb)
      from workflow.monograph_searches s
      where s.plan_id = v_plan.id and s.plan_version = v_plan.plan_version
        and s.outcome in ('unavailable', 'failed')),
    -- Kandidatkildene søkene ga. Vurderingen gjelder nøyaktig disse: en kilde
    -- som ikke står her, er ikke funnet av et søk, og skal ikke fylles inn fra
    -- hukommelsen.
    'candidates', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'identifier_kind', c.identifier_kind,
               'identifier_value', c.identifier_value,
               'title', c.title,
               'authors_or_issuer', c.authors_or_issuer,
               'publisher_or_journal', c.publisher_or_journal,
               'publication_year', c.publication_year,
               'discovery_path', c.discovery_path,
               -- Søket som fant kilden for nettopp denne planen. En kilde en
               -- annen plan fant først, er funnet her også (migrasjon 014c).
               'found_by_platform', (select s.platform from workflow.monograph_searches s
                                     where s.id = coalesce(l.search_id, c.search_id)),
               'found_by_method', (select coalesce(s.search_method, 'keyword')
                                   from workflow.monograph_searches s
                                   where s.id = coalesce(l.search_id, c.search_id)
                                     and s.execution_evidence = 'machine_executed'),
               'decision', l.decision::text,
               'decision_reason', l.decision_reason,
               'access_limited', c.access_limited,
               'access_limitation_note', c.access_limitation_note,
               'could_change_conclusion', l.could_change_conclusion,
               'materiality_reason', l.materiality_reason,
               'uses', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'need_reference', n.reference,
                          'proposed_use', cn.proposed_use) order by n.reference), '[]'::jsonb)
                 from workflow.monograph_candidate_source_needs cn
                 join knowledge.monograph_needs n on n.id = cn.need_id
                 -- Bare bruken for planens egne behov: bruken en annen plan har
                 -- foreslått for sine, er den planens (migrasjon 014c).
                 join workflow.monograph_search_plan_needs pn
                   on pn.need_id = cn.need_id and pn.plan_id = v_plan.id
                 where cn.candidate_source_id = c.id))
               order by c.created_at), '[]'::jsonb)
      from workflow.monograph_candidate_sources c
      join workflow.monograph_candidate_source_plans l
        on l.candidate_source_id = c.id and l.plan_id = v_plan.id),
    -- Hva en søkeforespørsel kan be om. Listen er uttømmende med vilje: en
    -- forespørsel kan ikke oppgi en adresse, og en plattform ingen har
    -- vurdert, finnes ikke å be om (ANTIDEP_CONSTITUTION.md regel 7).
    'search_request_options', jsonb_build_object(
      -- Fra registeret, ikke skrevet av. En plattform ingen har vurdert,
      -- finnes ikke å be om, og en som er registrert, skal ikke mangle her.
      'platforms', (select coalesce(jsonb_agg(distinct m.platform), '[]'::jsonb)
                    from knowledge.monograph_search_methods m),
      'methods', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'platform', m.platform,
                 'method', m.method,
                 'follows_central_sources', m.requires_seeds,
                 'seed_identifier_kinds', to_jsonb(m.seed_identifier_kinds),
                 'default_when_no_method_is_named', m.default_for_requests,
                 'description', m.description,
                 'covers', m.coverage_note,
                 'required_tracks_it_covers_here', (
                   select coalesce(jsonb_agg(c.track_code order by c.track_code), '[]'::jsonb)
                   from knowledge.monograph_search_platforms c
                   join workflow.monograph_search_track_attempts a2 on a2.plan_id = v_plan.id
                   join knowledge.monograph_search_tracks k2
                     on k2.id = a2.track_id and k2.code = c.track_code
                   where c.platform = m.platform and c.method = m.method
                     and (c.profile_codes is null or v_profile.code = any (c.profile_codes))))
                 order by m.platform, m.method), '[]'::jsonb)
        from knowledge.monograph_search_methods m),
      'max_central_sources_per_request', 10,
      'strategies', jsonb_build_array('broad', 'targeted'),
      'max_terms', 8,
      'max_drug_aliases', 8,
      'rounds_remaining', greatest(4 - v_round, 0)),
    -- Kriteriene for å avslutte, ordrett, og de fire grunnene som uttrykkelig
    -- ikke holder (SOURCE_POLICY.md §8).
    'closure_criteria', jsonb_build_object(
      'outstanding', workflow.monograph_search_closure_problem(v_plan.id),
      'requirements', jsonb_build_array(
        'Hvert obligatorisk søkespor for kildeprofilen må være forsøkt og dokumentert.',
        'Minst ett søk må faktisk ha gått. En utilgjengelig søkevei er en registrert begrensning og ikke null treff.',
        'Ingen avkortet treffliste kan stå igjen uten et oppfølgende søk på den samme plattformen.',
        'Ingen ulest eller utilgjengelig kilde som med rimelighet kan endre hovedkonklusjonen, kan stå uavklart.',
        'To ulike supplerende søkepasseringer uten nye potensielt konklusjonsendrende kilder — unntatt for de autoritative regulatoriske profilene, der én riktig, gjeldende kilde kan være nok.',
        'Den separate kontrollen av søkedekningen må godta begrunnelsen for å stoppe.'),
      'not_sufficient', jsonb_build_array(
        'At tre artikler er funnet.',
        'At to agenter er enige.',
        'At de første ti treffene er gjennomgått.',
        'At arbeidsbudsjettet er brukt opp. En oppbrukt ressursgrense gir åpent, ventende arbeid og aldri en konklusjon om evidensen.')),
    'rules', jsonb_build_array(
      'Søkene i denne oppgaven er utført av Antideps egen kode, mot navngitte offentlige søketjenester, og registrert med endepunkt og responsavtrykk. Du har ikke utført dem, og du skal ikke skrive som om du hadde.',
      'Du utfører ingen søk selv, og du trenger ingen nettilgang. Trengs det flere eller mer målrettede søk, ber du om dem som søkeforespørsler — Antidep utfører dem og gir deg neste vurderingsrunde.',
      'En kandidatkilde som ikke står i oppgaven, er ikke funnet av et søk. Ikke fyll inn en kilde fra hukommelsen: be heller om et søk som ville funnet den.',
      'En betalingsmur er en tilgangsbegrensning og ikke en faglig eksklusjonsgrunn. Sett slike kilder som «avventer tilgang» med en begrunnelse.',
      'En kilde godkjennes for en bestemt bruk og avgrensning, ikke universelt. Oppgi hva hver kilde kan brukes til for hvert behov.',
      'En søkevei som ikke svarte, står som en begrensning i oppgaven. Den er ikke null treff, og den er aldri en konklusjon om evidensen.',
      'Hvilke kilder som er sentrale, avgjør du. Referanselistene og de siterende arbeidene til kildene du velger til innhenting, inkluderer eller vurderer som mulig konklusjonsendrende, følger Antidep selv i neste runde. Vil du følge flere, be om metoden «references» eller «citations» med kildene i «seed_candidates».',
      'Hver søkemetode står i oppgaven med hva den dekker og hva den ikke dekker. Er en begrensning vesentlig for spørsmålet — en nasjonal retningslinje Antidep ikke kan søke i, et register som ikke er med — si det i merknaden: det er en opplysning kontrollen og redaktøren skal se.',
      'Et avkortet søk («truncated», og «truncation_resolved» er false) holder søkedekningen åpen: resten av trefflisten er ikke lest. Be om et smalere søk med den samme plattformen og metoden, og oppgi runden det erstatter i «narrows_request» (rundens «request_reference»). Det er din faglige avgjørelse at det smalere søket er det som betyr noe for spørsmålet; Antidep regner resten som dekket når det smalere søket er lest helt.'));

  if p_role = 'source_quality_assessment' then
    v_payload := v_payload || jsonb_build_object(
      'control_task', jsonb_build_object(
        'instruction', 'Kontroller søkedekningen. Antidep har utført dine egne, separat initierte motsøk med en annen strategi enn generatorens; vurder resultatene av dem, kontroller de sentrale eksklusjonene, og vurder vesentligheten av de kildene som står uavklarte. Godta begrunnelsen for å stoppe bare når kravene faktisk er oppfylt.',
        'own_search_rule', 'Uavhengigheten din er maskinelt utført og ikke erklært: Antidep har kjørt motsøkene under din egen rolle og din egen kjøring, og du kan verken oppgi eller bestride at de ble gjort. Vurder dem. Trengs det flere, be om dem som søkeforespørsler.',
        'independent_search_confirmed',
          workflow.monograph_control_searched_independently(v_plan.id),
        'own_countersearches', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'platform', s.platform,
                   'query', s.query_string,
                   'outcome', s.outcome::text,
                   'result_count', s.result_count,
                   'screened_count', s.screened_count,
                   'truncated', s.truncated,
                   'limitation_note', s.limitation_note,
                   'endpoint', s.evidence_endpoint,
                   'response_digest', s.response_digest)
                   order by s.registration_ordinal), '[]'::jsonb)
          from workflow.monograph_searches s
          join provenance.agent_runs r on r.id = s.agent_run_id
          where s.plan_id = v_plan.id
            and s.plan_version = v_plan.plan_version
            and s.execution_evidence = 'machine_executed'
            and r.agent_role = 'source_quality_assessment'::provenance.agent_role),
        'generator_searches', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'platform', s.platform,
                   'query', s.query_string,
                   'outcome', s.outcome::text,
                   'result_count', s.result_count,
                   'screened_count', s.screened_count,
                   'truncated', s.truncated)
                   order by s.registration_ordinal), '[]'::jsonb)
          from workflow.monograph_searches s
          join provenance.agent_runs r on r.id = s.agent_run_id
          where s.plan_id = v_plan.id
            and s.plan_version = v_plan.plan_version
            and r.agent_role = 'source_discovery'::provenance.agent_role),
        'excluded_candidates', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'identifier_kind', c.identifier_kind,
                   'identifier_value', c.identifier_value,
                   'title', c.title,
                   'decision_reason', l.decision_reason) order by c.created_at), '[]'::jsonb)
          from workflow.monograph_candidate_sources c
          join workflow.monograph_candidate_source_plans l
            on l.candidate_source_id = c.id and l.plan_id = v_plan.id
          where l.decision = 'excluded'),
        'unresolved_candidates', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'identifier_kind', c.identifier_kind,
                   'identifier_value', c.identifier_value,
                   'title', c.title,
                   'decision', l.decision::text,
                   'access_limited', c.access_limited,
                   'could_change_conclusion', l.could_change_conclusion,
                   'materiality_reason', l.materiality_reason) order by c.created_at), '[]'::jsonb)
          from workflow.monograph_candidate_sources c
          join workflow.monograph_candidate_source_plans l
            on l.candidate_source_id = c.id and l.plan_id = v_plan.id
          where l.decision not in ('included', 'excluded'))));
  end if;

  return v_payload;
end;
$$;


comment on function workflow.monograph_discovery_task_input(uuid, provenance.agent_role) is
  'Oppgavematerialet til de to kildeleddene: de maskinelt utførte søkene med plattform, metode, endepunkt og responsavtrykk, de redaktørregistrerte passeringene hver for seg, søkeveiene som ikke svarte, kandidatkildene planen fant — også når en annen plan fant dem først — og hvilke søk runden kan be om, med hver søkemetode, hva den dekker og hva den ikke dekker (migrasjon 014d). Sporene står med metodene som utfører dem for profilen. Machine_searches og editor_searches er fortsatt to felter: et menneskes dokumenterte arbeid er ikke et maskinelt kall (014a).';

-- ----------------------------------------------------------------------------
-- 12. Svarveien: metoden, kildene som skal følges, og rundene Antidep åpner selv
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION workflow.record_monograph_discovery_answer(p_job workflow.pipeline_jobs, p_input jsonb, p_result jsonb, p_run_id uuid, p_actor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_plan_id uuid := workflow.manifest_uuid(p_input, 'search_plan_id');
  v_plan workflow.monograph_search_plans;
  v_superseded workflow.monograph_search_requests;
  v_supersedes uuid;
  v_unknown text;
  v_item jsonb;
  v_use jsonb;
  v_need_id uuid;
  v_candidate workflow.monograph_candidate_sources;
  v_decision workflow.monograph_candidate_decision;
  v_axis knowledge.monograph_scope_axis;
  v_appraised integer := 0;
  v_decisions integer := 0;
  v_proposals integer := 0;
  v_requests integer := 0;
  v_control jsonb;
  v_control_id uuid;
  v_independent boolean;
  v_closed boolean := false;
  v_paused boolean := false;
  v_closure text;
  v_next_job uuid;
  v_next_round integer;
  v_allowed text[];
  v_platform text;
  v_strategy workflow.monograph_search_strategy;
  v_terms text[];
  v_aliases text[];
  v_method text;
  v_seeds text[];
  v_seed jsonb;
  v_seed_candidate workflow.monograph_candidate_sources;
  v_auto integer := 0;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.id = v_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen oppgaven gjelder, finnes ikke lenger.';
  end if;

  -- Den ene feilen som fortjener sin egen setning. Et svar med `searches` er
  -- ikke et svar med et ukjent felt: det er et svar som gjør krav på å ha
  -- utført søk, og den veien finnes ikke lenger for et semantisk ledd
  -- (SOURCE_POLICY.md §4.3).
  if p_result ? 'searches' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret rapporterer utførte søk, og det kan ikke dette agentleddet.',
      hint = 'Søkene utføres av Antideps egen kode og registreres med endepunkt og responsavtrykk. Et modellrapportert søk kan ikke fremstilles som maskinelt bekreftet utførelse. Trengs det flere søk, be om dem i «search_requests».';
  end if;

  if p_result ? 'candidates' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret legger til kandidatkilder, og det kan ikke dette agentleddet.',
      hint = 'Kandidatkildene kommer fra de maskinelt utførte søkene. Vurder dem i «candidate_appraisals»; mangler en kilde du mener bør være der, be om et søk som ville funnet den.';
  end if;

  -- Ukjente felter avvises framfor å ignoreres: et felt med skrivefeil ville
  -- ellers sett ut som en utelatt opplysning.
  v_allowed := case p_job.agent_role
    when 'source_discovery' then
      array['candidate_appraisals', 'search_requests', 'term_proposals', 'note']
    else array['candidate_appraisals', 'search_requests', 'control', 'note']
  end;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(p_result) as k(value)
  where not (k.value = any (v_allowed));
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret har felter denne kontrakten ikke kjenner: %s.', v_unknown),
      hint = format('Feltene rollen %s leser, er %s.',
                    p_job.agent_role, array_to_string(v_allowed, ', '));
  end if;

  -- ------------------------------------------------------------------
  -- Vurderingen av de maskinelt funne kandidatkildene
  --
  -- Bare kilder som står på planen fra før. En kilde svaret fant på, ville
  -- vært en kilde uten en oppdagelsesvei — og oppdagelsesveien er
  -- dokumentasjonen på søket (SOURCE_POLICY.md §4.3).
  -- ------------------------------------------------------------------
  if p_result ? 'candidate_appraisals' then
    if jsonb_typeof(p_result -> 'candidate_appraisals') <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'candidate_appraisals er ikke en JSON-liste.';
    end if;

    for v_item in select value from jsonb_array_elements(p_result -> 'candidate_appraisals') loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_item) as k(value)
      where k.value not in (
        'identifier_kind', 'identifier_value', 'decision', 'decision_reason',
        'could_change_conclusion', 'materiality_reason', 'uses'
      );
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('En kildevurdering har felter denne kontrakten ikke kjenner: %s.', v_unknown);
      end if;

      -- Kilden må være funnet av et søk på denne planen — også når en annen
      -- plan fant den først (migrasjon 014c).
      select c.* into v_candidate
      from workflow.monograph_candidate_sources c
      join workflow.monograph_candidate_source_plans l
        on l.candidate_source_id = c.id and l.plan_id = v_plan_id
      where c.identifier_kind = (v_item ->> 'identifier_kind')
        and c.identifier_value = btrim(coalesce(v_item ->> 'identifier_value', ''));

      if not found then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format(
            'Svaret vurderer kilden %s:%s, som ikke er funnet av et registrert søk på denne søkeplanen.',
            v_item ->> 'identifier_kind', v_item ->> 'identifier_value'),
          hint = 'Vurderingen gjelder de kildene de maskinelt utførte søkene faktisk ga. Mangler en kilde du mener bør være der, be om et søk som ville funnet den — den ville ellers stått uten en oppdagelsesvei (SOURCE_POLICY.md §4.3).';
      end if;

      perform workflow.appraise_monograph_candidate_source(
        v_candidate.id,
        v_plan_id,
        coalesce((v_item ->> 'could_change_conclusion')::boolean, false),
        v_item ->> 'materiality_reason',
        p_run_id);
      v_appraised := v_appraised + 1;

      -- Hva kilden kan brukes til, per behov. Behovet må være ett av dem planen
      -- dekker: en bruk utenfor oppgaven ville flyttet kilden til et spørsmål
      -- ingen hadde avgrenset.
      if v_item ? 'uses' then
        for v_use in select value from jsonb_array_elements(coalesce(v_item -> 'uses', '[]'::jsonb)) loop
          select n.id into v_need_id
          from knowledge.monograph_needs n
          join workflow.monograph_search_plan_needs pn on pn.need_id = n.id
          where pn.plan_id = v_plan_id and n.reference = v_use ->> 'need_reference';

          if v_need_id is null then
            raise exception using
              errcode = 'invalid_parameter_value',
              message = 'Svaret oppgir en bruk for et kunnskapsbehov som ikke står i oppgaven.',
              hint = 'Hvilke behov søkeplanen dekker, er en faglig avgrensning som ligger i oppgaven. En bruk utenfor den ville flyttet kilden til et spørsmål ingen hadde avgrenset.';
          end if;

          insert into workflow.monograph_candidate_source_needs
            (candidate_source_id, need_id, proposed_use)
          values (v_candidate.id, v_need_id, v_use ->> 'proposed_use')
          on conflict (candidate_source_id, need_id) do nothing;
        end loop;
      end if;

      if v_item ->> 'decision' is not null then
        begin
          v_decision := (v_item ->> 'decision')::workflow.monograph_candidate_decision;
        exception
          when invalid_text_representation then
            raise exception using
              errcode = 'invalid_parameter_value',
              message = format('%L er ikke en utvalgsbeslutning.', v_item ->> 'decision');
        end;

        perform workflow.decide_monograph_candidate_source(
          v_candidate.id, v_plan_id, v_decision, v_item ->> 'decision_reason', null, p_run_id);
        v_decisions := v_decisions + 1;
      end if;
    end loop;
  end if;

  -- ------------------------------------------------------------------
  -- Forslagene om nye avgrensningsverdier
  --
  -- Forslag, og ikke utvidelser: aksepten er en egen handling med et annet
  -- opphav, og den kan ikke være denne kjøringen (MONOGRAPH_STANDARD.md §4).
  -- ------------------------------------------------------------------
  if p_result ? 'term_proposals' then
    if jsonb_typeof(p_result -> 'term_proposals') <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'term_proposals er ikke en JSON-liste.';
    end if;

    for v_item in select value from jsonb_array_elements(p_result -> 'term_proposals') loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_item) as k(value)
      where k.value not in ('axis', 'label', 'rationale', 'from_need');
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('Et forslag har felter denne kontrakten ikke kjenner: %s.', v_unknown);
      end if;

      begin
        v_axis := (v_item ->> 'axis')::knowledge.monograph_scope_axis;
      exception
        when invalid_text_representation then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = format('%L er ikke en avgrensningsakse.', v_item ->> 'axis');
      end;

      -- Behovet verdien ble dokumentert under, når agenten navngir det. Da
      -- forgrener aksepten nettopp det behovet framfor å utvide hele utgaven
      -- på malenes hovedakse (MONOGRAPH_STANDARD.md §3).
      v_need_id := null;
      if nullif(btrim(coalesce(v_item ->> 'from_need', '')), '') is not null then
        select n.id into v_need_id
        from knowledge.monograph_needs n
        join workflow.monograph_search_plan_needs pn on pn.need_id = n.id
        where n.reference = btrim(v_item ->> 'from_need')
          and pn.plan_id = v_plan.id;

        if v_need_id is null then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = format(
              'Forslaget viser til behovet %L, som ikke er et av oppgavens behov.',
              v_item ->> 'from_need');
        end if;
      end if;

      perform knowledge.record_monograph_term_proposal(
        v_plan.edition_id, v_axis, v_item ->> 'label', v_item ->> 'rationale',
        p_actor_id, p_run_id, v_need_id, null, null, null, null, null);
      v_proposals := v_proposals + 1;
    end loop;
  end if;

  -- ------------------------------------------------------------------
  -- Søkeforespørslene: det leddet ber Antideps kode om å utføre
  --
  -- Dette er hele den nye arbeidsdelingen i ett felt. Leddet ber om et søk;
  -- Antidep utfører det, registrerer det med endepunkt og responsavtrykk, og
  -- gir leddet neste vurderingsrunde. Modellen later aldri som om den ringte
  -- PubMed.
  -- ------------------------------------------------------------------
  v_next_round := case when p_job.agent_role = 'source_discovery'
                       then v_plan.discovery_round else v_plan.control_round end + 1;

  if p_result ? 'search_requests' then
    if jsonb_typeof(p_result -> 'search_requests') <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'search_requests er ikke en JSON-liste.';
    end if;

    if p_job.agent_role = 'source_quality_assessment'
       and jsonb_array_length(p_result -> 'search_requests') > 0
       and p_result ? 'control' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Kontrollen ber om flere søk og avgjør dekningen i det samme svaret.',
        hint = 'De to er forskjellige utfall av én kontrollrunde. Be om søkene, vurder resultatene, og avgjør etterpå — en avgjørelse tatt samtidig med at grunnlaget blir bedt om, hviler ikke på det grunnlaget.';
    end if;

    for v_item in select value from jsonb_array_elements(p_result -> 'search_requests') loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_item) as k(value)
      where k.value not in (
        'rationale', 'platform', 'method', 'strategy', 'drug_aliases', 'query_terms',
        'seed_candidates', 'filters_note', 'narrows_request');
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('En søkeforespørsel har felter denne kontrakten ikke kjenner: %s.', v_unknown);
      end if;

      v_platform := nullif(btrim(coalesce(v_item ->> 'platform', '')), '');
      v_method := nullif(btrim(coalesce(v_item ->> 'method', '')), '');
      -- Registeret, og ikke en skrevet liste, avgjør hva som finnes å be om.
      if not exists (select 1 from workflow.monograph_request_methods(v_platform, v_method)) then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('%s er ikke en søkevei Antidep kaller.',
                           concat_ws(' med metoden ', coalesce(v_platform, 'Ingen plattform'), v_method)),
          hint = format('Søkeveiene er %s. En forespørsel kan ikke oppgi en adresse: en tjeneste ingen har vurdert, finnes ikke å be om (ANTIDEP_CONSTITUTION.md regel 7).',
                        (select string_agg(m.platform || ' (' || m.method || ')', ', '
                                           order by m.platform, m.method)
                         from knowledge.monograph_search_methods m));
      end if;

      -- Kildene som skal følges. Hver av dem må være en kandidat planen har
      -- funnet: en kilde leddet husket, har ingen oppdagelsesvei, og da er
      -- referanselisten dens heller ikke funnet av noe søk (SOURCE_POLICY.md §4.3).
      v_seeds := array[]::text[];
      if v_item ? 'seed_candidates' then
        if jsonb_typeof(v_item -> 'seed_candidates') <> 'array' then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = 'seed_candidates er ikke en JSON-liste.';
        end if;
        for v_seed in select value from jsonb_array_elements(v_item -> 'seed_candidates') loop
          select c.* into v_seed_candidate
          from workflow.monograph_candidate_sources c
          join workflow.monograph_candidate_source_plans l
            on l.candidate_source_id = c.id and l.plan_id = v_plan_id
          where c.identifier_kind = (v_seed ->> 'identifier_kind')
            and c.identifier_value = btrim(coalesce(v_seed ->> 'identifier_value', ''));
          if not found then
            raise exception using
              errcode = 'invalid_parameter_value',
              message = format(
                'Søkeforespørselen vil følge kilden %s:%s, som ikke er funnet av et søk på denne søkeplanen.',
                v_seed ->> 'identifier_kind', v_seed ->> 'identifier_value'),
              hint = 'Bare kandidatkilder i oppgaven kan følges. Mangler en sentral kilde, be om et søk som ville funnet den først.';
          end if;
          v_seeds := v_seeds || (v_seed_candidate.identifier_kind || ':' || v_seed_candidate.identifier_value);
        end loop;

        if not workflow.monograph_seed_identifiers_shaped(v_seeds) then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = 'Kildene søkeforespørselen vil følge, kan ikke slås opp.',
            hint = 'Høyst ti kilder, hver med en DOI, et PubMed-nummer eller et PMC-nummer.';
        end if;
      end if;

      -- Den brede runden en smalere runde uttrykkelig erstatter. Det er leddets
      -- faglige avgjørelse at det smalere søket er det som betyr noe for
      -- spørsmålet; stoppkravet regner da resten av den brede trefflisten som
      -- dekket når det smalere søket er lest helt. Erstatningen må gjelde den
      -- samme søkemetoden: et annet slag søk sier ingenting om resten.
      v_supersedes := null;
      if v_item ? 'narrows_request' then
        select r.* into v_superseded
        from workflow.monograph_search_requests r
        where r.reference = btrim(coalesce(v_item ->> 'narrows_request', ''))
          and r.plan_id = v_plan_id
          and r.plan_version = v_plan.plan_version
          and r.requested_for_role = p_job.agent_role;

        if not found then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = 'Søkeforespørselen sier at den snevrer inn en søkerunde som ikke finnes på denne planen for dette leddet.',
            hint = 'narrows_request er referansen til en av rundene i oppgaven, slik den står ved søkene i «machine_searches».';
        end if;

        if not exists (
          select 1
          from workflow.monograph_request_methods(v_platform, v_method) a
          join workflow.monograph_request_methods(v_superseded.platform, v_superseded.method) b
            on b.platform = a.platform and b.method = a.method
        ) then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = 'Den smalere runden bruker ingen av søkemetodene i runden den sier den erstatter.',
            hint = 'Et smalere søk erstatter et bredt bare når det er det samme slaget søk: den samme plattformen og den samme metoden. Et kort søk om noe annet sier ingenting om resten av en lang treffliste.';
        end if;

        v_supersedes := v_superseded.id;
      end if;

      begin
        v_strategy := coalesce(v_item ->> 'strategy', 'targeted')::workflow.monograph_search_strategy;
      exception
        when invalid_text_representation then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = format('%L er ikke en søkestrategi.', v_item ->> 'strategy'),
            hint = 'Strategiene er «broad» (avgrensningsaksene som ELLER-ledd) og «targeted» (én passering per akse eller term).';
      end;

      v_terms := (
        select coalesce(array_agg(btrim(t.value #>> '{}')), array[]::text[])
        from jsonb_array_elements(coalesce(v_item -> 'query_terms', '[]'::jsonb)) as t(value));
      v_aliases := (
        select coalesce(array_agg(btrim(t.value #>> '{}')), array[]::text[])
        from jsonb_array_elements(coalesce(v_item -> 'drug_aliases', '[]'::jsonb)) as t(value));

      if not workflow.monograph_search_terms_shaped(v_terms)
         or not workflow.monograph_search_terms_shaped(v_aliases) then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = 'Søkeforespørselens termer har ikke formen en søkestreng kan bære.',
          hint = 'Høyst åtte termer, hver på 2 til 120 tegn, uten linjeskift og uten anførselstegn.';
      end if;

      -- Budsjettet. En runde til ser alltid billigere ut enn en avgjørelse, og
      -- en oppbrukt ressursgrense er åpent, ventende arbeid — aldri en
      -- konklusjon om evidensen (SOURCE_POLICY.md §8.2).
      if v_next_round > 4 then
        v_paused := true;
      else
        if workflow.open_monograph_search_request(
             v_plan_id, p_job.agent_role, v_next_round,
             'agent_requested'::workflow.monograph_search_request_origin,
             v_strategy,
             coalesce(nullif(btrim(coalesce(v_item ->> 'rationale', '')), ''),
                      'Leddet ba om en mer målrettet søkerunde.'),
             v_platform, v_method, v_aliases, v_terms, v_seeds, v_item ->> 'filters_note',
             p_run_id, p_actor_id, v_supersedes) is not null then
          v_requests := v_requests + 1;
        end if;
      end if;
    end loop;

  end if;

  -- ------------------------------------------------------------------
  -- Og det Antideps kode åpner selv, uten at leddet må be om det
  --
  -- Vurderingen over har nettopp sagt hvilke kilder som er sentrale. Står
  -- referanselistene eller de siterende arbeidene fortsatt som ikke forsøkt,
  -- følger Antidep de kildene i neste runde — og et annet spor registeret har
  -- en metode for, og som ingen runde ennå har utført, får sin runde der også.
  -- Et utførbart spor skal aldri vente på at noen husker å be om det
  -- (migrasjon 014d). Kontrollens runder er kontrollens egne og åpnes ikke her.
  -- ------------------------------------------------------------------
  if p_job.agent_role = 'source_discovery' and not v_paused then
    if v_next_round <= 4 then
      v_auto := workflow.open_monograph_machine_rounds(
        v_plan_id, v_next_round,
        'selection_opened'::workflow.monograph_search_request_origin,
        p_actor_id, p_run_id);
    elsif v_requests = 0 and (
      exists (
        select 1 from workflow.monograph_search_track_attempts a
        where a.plan_id = v_plan_id and a.state = 'pending')
      or workflow.monograph_plan_has_unchased_seeds(v_plan_id)
    ) then
      v_paused := true;
    end if;
  end if;

  if v_paused then
    update workflow.monograph_search_plans
    set paused_at = now(),
        paused_reason = 'Søkebudsjettet for denne planversjonen er brukt opp: de fire maskinelle søkerundene som er tillatt, er brukt, og planen har fortsatt søk som enten er bedt om eller ikke er utført. Arbeidet står åpent og ventende, og det er ingen konklusjon om evidensen (SOURCE_POLICY.md §8.2).'
    where id = v_plan_id and paused_at is null and closed_at is null;
  elsif v_requests + v_auto > 0 then
    update workflow.monograph_search_plans
    set discovery_round = case when p_job.agent_role = 'source_discovery'
                               then v_next_round else discovery_round end,
        control_round = case when p_job.agent_role = 'source_quality_assessment'
                             then v_next_round else control_round end
    where id = v_plan_id;
  end if;

  -- ------------------------------------------------------------------
  -- Kontrollen av søkedekningen
  -- ------------------------------------------------------------------
  if p_job.agent_role = 'source_quality_assessment' and p_result ? 'control' then
    v_control := p_result -> 'control';
    if v_control is null or jsonb_typeof(v_control) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen control som er et JSON-objekt.';
    end if;

    if v_control ? 'searched_independently' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Kontrollen erklærer selv at den søkte uavhengig, og det er ikke lenger en opplysning svaret gir.',
        hint = 'Uavhengigheten er maskinelt utført: Antidep kjørte motsøkene under kontrollens egen rolle og kjøring, og leser det av søkeloggen. En erklæring et svar kan bestå ved å skrive den, kontrollerer ingenting (SOURCE_POLICY.md §6).';
    end if;

    select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
    from jsonb_object_keys(v_control) as k(value)
    where k.value not in (
      'outcome', 'note', 'missed_candidates', 'exclusions_checked', 'materiality_assessed'
    );
    if v_unknown is not null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Kontrollen har felter denne kontrakten ikke kjenner: %s.', v_unknown);
    end if;

    v_independent := workflow.monograph_control_searched_independently(v_plan_id);

    if (v_control ->> 'outcome') = 'accepted' and not v_independent then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Kontrollen godtar dekningen uten at et eget motsøk faktisk har gått.',
        hint = 'Antideps motsøkerunde for kontrollen har ikke registrert et søk som gikk på denne planversjonen. Et kontrollledd som bare leser generatorens valgte referanser, kan kontrollere sitatene, men ikke vurdere dekningsgraden (SOURCE_POLICY.md §6).';
    end if;

    v_control_id := workflow.record_monograph_coverage_control(
      v_plan_id,
      (v_control ->> 'outcome')::workflow.monograph_coverage_outcome,
      v_control ->> 'note',
      v_independent,
      coalesce((v_control ->> 'missed_candidates')::integer, 0),
      coalesce((v_control ->> 'exclusions_checked')::integer, 0),
      coalesce((v_control ->> 'materiality_assessed')::boolean, false),
      p_run_id, p_actor_id);

    -- Godtar kontrollen dekningen, og holder porten, erklæres søkedekningen
    -- ferdig i den samme transaksjonen. Porten er den samme enten en redaktør
    -- eller kjeden erklærer dekningen ferdig (SOURCE_POLICY.md §10).
    if (v_control ->> 'outcome') = 'accepted' then
      v_closure := workflow.monograph_search_closure_problem(v_plan_id);
      if v_closure is null then
        update workflow.monograph_search_plans
        set closed_at = now(),
            closed_note = format('Søkedekningen erklært ferdig av den separate kontrollen: %s',
                                 v_control ->> 'note'),
            closed_by_actor_id = p_actor_id
        where id = v_plan_id;

        update knowledge.monograph_needs n
        set work_state = 'appraising_sources', work_state_note = null
        where n.id in (
          select pn.need_id from workflow.monograph_search_plan_needs pn
          where pn.plan_id = v_plan_id)
          and n.relevance = 'relevant'
          and n.work_state in ('not_started', 'searching');

        v_closed := true;
      end if;
    end if;
  end if;

  -- ------------------------------------------------------------------
  -- Og overgangen videre
  --
  -- Ba leddet om flere søk, er neste steg den maskinelle runden — ikke en ny
  -- modellvurdering. Var det kildeoppdagelsen som var ferdig, åpnes
  -- dekningskontrollens egen motsøkerunde.
  -- ------------------------------------------------------------------
  if not v_paused and v_requests = 0 and v_auto = 0 then
    if p_job.agent_role = 'source_discovery' then
      v_next_job := workflow.chain_task_for_search_coverage(v_plan_id);
    end if;
  end if;

  return jsonb_build_object(
    'search_plan_id', v_plan_id,
    'candidates_appraised', v_appraised,
    'selection_decisions', v_decisions,
    'term_proposals', v_proposals,
    'search_requests_opened', v_requests,
    'machine_requests_opened', v_auto,
    'search_budget_exhausted', v_paused,
    'coverage_control_id', v_control_id,
    'search_coverage_closed', v_closed,
    'closure_problem', workflow.monograph_search_closure_problem(v_plan_id),
    'next_job_id', v_next_job);
end;
$function$;


comment on function workflow.record_monograph_discovery_answer(workflow.pipeline_jobs, jsonb, jsonb, uuid, uuid) is
  'Registrerer ett eksternt agentsvar fra kildeoppdagelsen eller den separate kontrollen av søkedekningen. Leddet vurderer de maskinelt utførte søkene og kandidatkildene planen fant — også når en annen plan fant dem først — og ber om flere søk som strukturerte søkeforespørsler, nå med en navngitt søkemetode fra registeret og, for referanser og siterende arbeider, de sentrale kildene som skal følges. Et svar som rapporterer utførte søk eller legger til en kandidatkilde, avvises. Etter kildeoppdagelsens vurdering åpner Antidep selv neste runde for sporene registeret har en metode for og som ingen runde har utført — referanselistene og de siterende arbeidene til kildene leddet valgte — slik at et utførbart spor ikke venter på at noen husker å be om det (migrasjon 014d). Er budsjettet på fire runder brukt opp, settes planen på pause som åpent, ventende arbeid og aldri som en konklusjon om evidensen (§8.2).';

-- ----------------------------------------------------------------------------
-- 13. Kontrakten: forespørselsformen har fått metode og kilder å følge
--
-- Svarformene for begge kildeleddene har fått to felter i søkeforespørselen
-- (`method`, `seed_candidates`), og oppgavematerialet har fått søkemetodene med
-- hva de dekker. Begge versjonene heves, slik at et svar avgitt under den gamle
-- formen ikke kan importeres på en oppgave bygget under den nye.
-- ----------------------------------------------------------------------------

create or replace function workflow.agent_task_contract(p_agent_role provenance.agent_role)
  returns jsonb
  language sql
  immutable
  set search_path = ''
as $$
  select case p_agent_role
    when 'evidence_extraction' then jsonb_build_object(
      'prompt_template_version', 'evidence-extraction/handoff-drafting/2',
      'output_schema_version', 'antidep/extraction-draft@1'
    )
    when 'claim_synthesis' then jsonb_build_object(
      'prompt_template_version', 'claim-synthesis/handoff-drafting/2',
      'output_schema_version', 'antidep/claim-synthesis-draft@1'
    )
    when 'evidence_assessment' then jsonb_build_object(
      'prompt_template_version', 'evidence-assessment/handoff-drafting/2',
      'output_schema_version', 'antidep/evidence-assessment-draft@1'
    )
    -- Migrasjon 014d: søkeforespørselen kan navngi en søkemetode og de
    -- sentrale kildene som skal følges, og oppgaven viser hver søkemetode med
    -- hva den dekker.
    when 'source_discovery' then jsonb_build_object(
      'prompt_template_version', 'source-discovery/machine-search-appraisal/5',
      'output_schema_version', 'antidep/source-discovery-draft@4'
    )
    when 'source_quality_assessment' then jsonb_build_object(
      'prompt_template_version', 'source-coverage/machine-countersearch-control/5',
      'output_schema_version', 'antidep/source-coverage-control-draft@3'
    )
    when 'monograph_answer' then jsonb_build_object(
      'prompt_template_version', 'monograph-answer/handoff-fact/2',
      'output_schema_version', 'antidep/monograph-answer-draft@1'
    )
    else null
  end;
$$;

comment on function workflow.agent_task_contract(provenance.agent_role) is
  'Hvilken promptmal og hvilket svarformat hvert agentledd arbeider etter. Kildeleddenes maler er på versjon 5 og svarformene på @4 og @3 fra migrasjon 014d: søkeforespørselen kan navngi en søkemetode fra registeret og de sentrale kildene som skal følges, og oppgavematerialet viser hver søkemetode med hva den dekker og ikke dekker. Verdiene er de samme som i src/agents/agent-task.ts, og pinnes av en prøve på begge sider av databasegrensen.';
