-- ============================================================================
-- Migrasjon 014g — en runde som vokser, er en ny vurdering
--
-- Fra 013v er kildeoppdagelsens semantiske oppgave bundet til søkeplanen og
-- runden (`<plan>#d<runde>`), med manifestet {søkeplan, versjon, runde}. Det
-- holdt så lenge en runde var ferdig i det den var åpnet. Fra 014d er den ikke
-- det: registeret åpner selv nye maskinelle søk i den runden planen står i
-- (`registry_opened`), også etter at rundens vurderingsoppgave er lagt inn. I
-- produksjon skjedde det for alle de åpne planene på én gang, da 014e førte
-- sporene deres mot registeret.
--
-- Porten gjorde jobben sin: oppgaven ble holdt tilbake til de nye søkene var
-- utført. Men manifestet — og dermed jobbnøkkelen — var det samme før og etter
-- at runden vokste. Var rundens oppgave allerede fullført, feilet eller brukt
-- opp, kunne ingen ny oppgave legges inn for det utvidede grunnlaget:
-- `workflow.agent_task_subject_queued(...)` fant den gamle, og unikheten på
-- (agent_role, job_key) ville uansett stoppet en ny. Kandidatkildene de nye
-- søkene fant, ville aldri blitt vurdert, og ingenting sa fra. Det samme
-- gjaldt et søk som ikke svarte da runden ble vurdert, og som svarte på et
-- senere forsøk, og et søk en redaktør registrerte: nye kandidater uten en
-- vurdering — som porten for å erklære dekningen ferdig så krever.
--
-- Og køen sa det motsatte av det som var sant. `api.list_pending_agent_tasks`
-- teller hver ikke-fullførte oppgave som blokkert, og en blokkert oppgave er
-- «noe som venter på et menneske». I produksjon var det 140 slike etter 014e:
-- 70 oppgaver 013v foreldet under den forrige kildekontrakten, én 014e foreldet
-- da den lukket en plan som aldri var en søkeplan, og 69 runde 1-oppgaver som
-- ventet på registerets nye søk. Ingen av dem ventet på et menneske. De 71
-- foreldede ville stått der for alltid, og hver av dem hadde et åpent teknisk
-- problem.
--
-- Rettingen er en invariant og ikke en opprydding:
--
--   * Grunnlaget en kildeoppgave vurderer, står i manifestet (`search_basis`):
--     hvor mange maskinelle søkeforespørsler leddet har på planversjonen, og
--     hvor mange av søkene som faktisk gikk. Begge radene er frosne — en
--     forespørsel kan ikke slettes, og søkeloggen er append-only — så tallene
--     bare vokser, og et nytt grunnlag er en ny jobbnøkkel. En oppgave fra før
--     denne migrasjonen leses med grunnlaget slik det var da den ble lagt inn.
--   * Kjedeovergangen legger inn en ny oppgave når, og bare når, runden er
--     ferdig søkt og det ikke står en oppgave for nøyaktig dette grunnlaget —
--     i hvilken som helst tilstand. En fullført oppgave for det samme
--     grunnlaget kjøres ikke om igjen, en som har brukt opp forsøkene sine,
--     venter fortsatt på et menneske, og en som en kjøring holder akkurat nå,
--     får gjøre seg ferdig eller løpe ut først. Aldri to aktive oppgaver om den
--     samme runden.
--   * En oppgave som ikke lenger gjelder det planen står i — en eldre versjon,
--     en eldre runde, et eldre grunnlag, en lukket plan eller den forrige
--     kildekontrakten — trekkes tilbake (`workflow.pipeline_job_withdrawals`).
--     Den blir stående som historikk med hele sporet sitt, men den er ikke
--     lenger noe køen, uttaket eller oversiktene regner som ventende arbeid,
--     og den er ikke et teknisk problem.
--
-- De eksisterende dataene repareres av migrasjonen selv (seksjon 10): hver
-- plan går gjennom de samme funksjonene, og en siste kontroll krever at hver
-- åpen plan med en ferdig søkt runde har sin oppgave. Ingen jobber, hendelser
-- eller kliniske rader slettes eller skrives om.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Grunnlaget en kildeoppgave vurderer
-- ----------------------------------------------------------------------------

create function workflow.monograph_round_manifest_key(p_role provenance.agent_role)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case p_role
    when 'source_discovery'::provenance.agent_role then 'discovery_round'
    when 'source_quality_assessment'::provenance.agent_role then 'control_round'
  end;
$$;

comment on function workflow.monograph_round_manifest_key(provenance.agent_role) is
  'Hvilket felt i manifestet som bærer den maskinelle søkerunden et av de to kildeleddenes oppgaver hører til: discovery_round for kildeoppdagelsen, control_round for dekningskontrollen. NULL for alle andre roller. Den ene stedet navnet står, slik at runden leses likt av kjedeovergangen, tilbaketrekkingen og forhåndskontrollen (migrasjon 014g).';

revoke execute on function workflow.monograph_round_manifest_key(provenance.agent_role) from public;

create function workflow.monograph_search_basis(
  p_plan_id uuid,
  p_plan_version integer,
  p_role provenance.agent_role,
  p_as_of timestamptz default null
)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select jsonb_build_object(
    -- Søkene leddet har bedt om, eller som er åpnet for det: også en runde
    -- ingen vei svarte på, er noe vurderingen skal vite om.
    'requests', (
      select count(*)
      from workflow.monograph_search_requests r
      where r.plan_id = p_plan_id
        and r.plan_version = p_plan_version
        and r.requested_for_role = p_role
        and (p_as_of is null or r.created_at <= p_as_of)),
    -- Og søkene som faktisk gikk — med et senere forsøk på en runde som ikke
    -- svarte første gang, og for kildeoppdagelsen med søkene en redaktør har
    -- registrert. Det er de som gir kandidatkildene vurderingen gjelder.
    'searches', (
      select count(*)
      from workflow.monograph_searches s
      left join workflow.monograph_search_requests r on r.id = s.search_request_id
      where s.plan_id = p_plan_id
        and s.plan_version = p_plan_version
        and s.outcome in ('executed', 'zero_results')
        and (r.requested_for_role = p_role
             or (r.id is null and p_role = 'source_discovery'::provenance.agent_role))
        and (p_as_of is null or s.created_at <= p_as_of)));
$$;

comment on function workflow.monograph_search_basis(uuid, integer, provenance.agent_role, timestamptz) is
  'Søkegrunnlaget et av kildeleddene vurderer på én planversjon: hvor mange maskinelle søkeforespørsler leddet har, og hvor mange av søkene som faktisk gikk (for kildeoppdagelsen også de en redaktør har registrert) — med et tidspunkt, slik det var da. Forespørslene kan ikke slettes og søkeloggen er append-only, så begge tallene bare vokser, og et annet grunnlag er alltid et større. Den semantiske oppgaven bærer det i manifestet (search_basis), slik at et grunnlag som har vokst etter vurderingen, er en ny oppgave (migrasjon 014g).';

revoke execute on function workflow.monograph_search_basis(uuid, integer, provenance.agent_role, timestamptz) from public;

create function workflow.monograph_search_task_basis(p_job workflow.pipeline_jobs)
  returns jsonb
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_manifest jsonb := p_job.input_manifest;
  v_basis jsonb := p_job.input_manifest -> 'search_basis';
  v_round text;
begin
  if v_manifest ? 'search_basis' then
    if jsonb_typeof(v_basis) is distinct from 'object' then
      return null;
    end if;
    if (select count(*) from jsonb_object_keys(v_basis)) = 2
       and jsonb_typeof(v_basis -> 'requests') = 'number'
       and jsonb_typeof(v_basis -> 'searches') = 'number'
       and (v_basis ->> 'requests') ~ '^[0-9]{1,9}$'
       and (v_basis ->> 'searches') ~ '^[0-9]{1,9}$' then
      return jsonb_build_object(
        'requests', (v_basis ->> 'requests')::integer,
        'searches', (v_basis ->> 'searches')::integer);
    end if;
    return null;
  end if;

  -- En oppgave lagt inn før migrasjon 014g, eller av en redaktør som ikke
  -- oppga grunnlaget. Den gjaldt grunnlaget slik det var da den ble lagt inn.
  v_round := v_manifest ->> workflow.monograph_round_manifest_key(p_job.agent_role);
  if workflow.manifest_uuid(v_manifest, 'search_plan_id') is null
     or coalesce(v_manifest ->> 'plan_version', '') !~ '^[0-9]{1,9}$'
     or coalesce(v_round, '') !~ '^[0-9]{1,9}$' then
    return null;
  end if;

  return workflow.monograph_search_basis(
    workflow.manifest_uuid(v_manifest, 'search_plan_id'),
    (v_manifest ->> 'plan_version')::integer,
    p_job.agent_role,
    p_job.enqueued_at);
end;
$$;

comment on function workflow.monograph_search_task_basis(workflow.pipeline_jobs) is
  'Søkegrunnlaget en kildeoppgave vurderer. Fra migrasjon 014g står det i manifestet (search_basis); for en oppgave uten det leses grunnlaget slik det var da oppgaven ble lagt inn. NULL når manifestet ikke sier nok til å avgjøre det.';

revoke execute on function workflow.monograph_search_task_basis(workflow.pipeline_jobs) from public;

-- ----------------------------------------------------------------------------
-- 2. Om en kildeoppgave fortsatt gjelder det planen står i
--
-- Den ene definisjonen. Forhåndskontrollen, køen, uttaket og importen leser
-- den gjennom `workflow.agent_task_input_problem(...)`, og tilbaketrekkingen
-- leser den direkte — slik at de ikke kan bli uenige om hvilken oppgave som
-- er rundens.
-- ----------------------------------------------------------------------------

create function workflow.monograph_search_task_supersession(p_job workflow.pipeline_jobs)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_manifest jsonb := p_job.input_manifest;
  v_plan workflow.monograph_search_plans;
  v_version text := v_manifest ->> 'plan_version';
  v_round text;
  v_current integer;
  v_basis jsonb;
begin
  if p_job.agent_role not in ('source_discovery'::provenance.agent_role,
                              'source_quality_assessment'::provenance.agent_role) then
    return null;
  end if;

  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.id = workflow.manifest_uuid(v_manifest, 'search_plan_id');
  if not found then
    return null;
  end if;

  if (case when v_version ~ '^[0-9]{1,9}$' then v_version::integer end)
     is distinct from v_plan.plan_version then
    return 'Søkeplanen har fått en ny versjon siden oppgaven ble lagt inn. Arbeidet hører til den nye versjonen.';
  end if;

  if v_plan.closed_at is not null then
    return 'Søkedekningen for denne planen er allerede erklært ferdig.';
  end if;

  -- Runden oppgaven hører til. En oppgave bygget før migrasjon 013v bærer den
  -- ikke, og den er foreldet med vilje: den ba agenten utføre søk den ikke
  -- har — og skal ikke ha — verktøy til.
  v_round := v_manifest ->> workflow.monograph_round_manifest_key(p_job.agent_role);
  if v_round is null then
    return 'Oppgaven er bygget under en tidligere kildekontrakt som ba agenten utføre søkene selv. Den kontrakten gjelder ikke lenger: Antideps egen kode utfører søkene, og oppgaven bygges på nytt når den maskinelle søkerunden er gjort.';
  end if;

  v_current := workflow.monograph_search_round(v_plan.id, p_job.agent_role);
  if (case when v_round ~ '^[0-9]{1,9}$' then v_round::integer end)
     is distinct from v_current then
    return 'Søkeplanen har fått en ny maskinell søkerunde siden oppgaven ble lagt inn. Arbeidet hører til den nye runden.';
  end if;

  -- Og grunnlaget. Har leddet fått flere søk etter at oppgaven ble lagt inn —
  -- en ny runde fra registeret, et søk som svarte på et senere forsøk, eller et
  -- redaktørregistrert søk — er vurderingen den ba om, en vurdering av noe
  -- mindre enn det som nå ligger der. Den hører til en ny oppgave for hele
  -- grunnlaget (migrasjon 014g).
  v_basis := workflow.monograph_search_task_basis(p_job);
  if v_basis is null then
    return 'Oppgaven sier ikke hvilket søkegrunnlag den vurderer.';
  end if;
  if v_basis is distinct from workflow.monograph_search_basis(
       v_plan.id, v_plan.plan_version, p_job.agent_role) then
    return 'Søkegrunnlaget har vokst siden oppgaven ble lagt inn: det er kommet maskinelle søk eller resultater oppgaven ikke gjaldt. Vurderingen hører til en ny oppgave for hele grunnlaget, som legges inn når søkene er utført.';
  end if;

  return null;
end;
$$;

comment on function workflow.monograph_search_task_supersession(workflow.pipeline_jobs) is
  'Én setning om hvorfor en kildeoppgave ikke lenger er det arbeidet planen står foran, eller NULL når den er det: planen har fått en ny versjon, planen er lukket, oppgaven er bygget under den forrige kildekontrakten, planen har fått en ny runde, eller søkegrunnlaget har vokst etter at oppgaven ble lagt inn. En pause er ikke med: arbeidet på en plan som står på pause, er fortsatt planens arbeid. NULL også for andre roller og for en plan som ikke finnes, som forhåndskontrollen sier fra om selv. Leses av forhåndskontrollen og av tilbaketrekkingen, slik at de to ikke kan bli uenige (migrasjon 014g).';

revoke execute on function workflow.monograph_search_task_supersession(workflow.pipeline_jobs) from public;

-- ----------------------------------------------------------------------------
-- 3. En oppgave Antidep har trukket tilbake
--
-- `failed` er den tilstanden en oppgave som aldri kommer til å bli gjort, har
-- hatt siden 012b (`workflow.chain_close_discarded_job(...)`), og den blir
-- stående. Men `failed` alene sier ikke *hvorfor*: en oppgave som ga opp etter
-- tre forsøk, venter på et menneske, og en som Antidep trakk tilbake fordi
-- arbeidet er lagt inn på nytt, gjør ikke det. Forskjellen er en egen,
-- append-only opplysning — og ikke et mønster i en fritekst.
-- ----------------------------------------------------------------------------

create table workflow.pipeline_job_withdrawals (
  id uuid primary key default gen_random_uuid(),

  pipeline_job_id uuid not null unique
    references workflow.pipeline_jobs (id) on update restrict on delete restrict,
  reason text not null,
  withdrawn_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,

  created_at timestamptz not null default now(),

  constraint pipeline_job_withdrawals_reason_shape_check
    check (reason = btrim(reason) and length(reason) between 1 and 1000)
);

comment on table workflow.pipeline_job_withdrawals is
  'At Antidep har trukket en oppgave tilbake fordi arbeidet den gjaldt, ikke lenger er det gjeldende — en eldre versjon, runde eller et eldre søkegrunnlag, en lukket plan eller en foreldet kontrakt (migrasjon 014g). Oppgaven står igjen med hele sporet sitt, i tilstanden failed, men den er ikke ventende arbeid: køen, uttaket og oversiktene regner den ikke med, og den er ikke et teknisk problem. Én rad per oppgave, append-only.';
comment on column workflow.pipeline_job_withdrawals.reason is
  'Antideps egen setning om hvorfor oppgaven ikke lenger gjelder, lest av den samme funksjonen forhåndskontrollen leser.';
comment on column workflow.pipeline_job_withdrawals.withdrawn_by_actor_id is
  'Aktøren tilbaketrekkingen føres på: den som bestilte utgaven når kjedeovergangen trekker tilbake, og grunnaktøren når en migrasjon gjør det.';

alter table workflow.pipeline_job_withdrawals enable row level security;

create trigger pipeline_job_withdrawals_set_created_at
  before insert on workflow.pipeline_job_withdrawals
  for each row execute function catalog.set_created_at();

create trigger pipeline_job_withdrawals_are_append_only
  before update or delete on workflow.pipeline_job_withdrawals
  for each row execute function knowledge.reject_append_only_mutation(
    'En tilbaketrekking sier at en oppgave ikke lenger var gjeldende arbeid. Skal arbeidet gjøres, er det en ny oppgave.'
  );

create function workflow.pipeline_job_withdrawn(p_pipeline_job_id uuid)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select exists (
    select 1 from workflow.pipeline_job_withdrawals w
    where w.pipeline_job_id = p_pipeline_job_id
  );
$$;

comment on function workflow.pipeline_job_withdrawn(uuid) is
  'Om Antidep har trukket oppgaven tilbake (migrasjon 014g).';

revoke execute on function workflow.pipeline_job_withdrawn(uuid) from public;

create function workflow.withdraw_pipeline_job(
  p_pipeline_job_id uuid,
  p_reason text,
  p_actor_id uuid
)
  returns boolean
  language plpgsql
  set search_path = ''
as $$
declare
  v_job workflow.pipeline_jobs;
begin
  -- Radlåsen er den samme uttaket tar. Et uttak som kom først, har en løpende
  -- leie når låsen slippes, og den oppgaven får gjøre seg ferdig.
  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.id = p_pipeline_job_id
  for update;

  if not found
     or v_job.state = 'succeeded'
     or (v_job.state = 'leased'
         and v_job.lease_expires_at is not null
         and v_job.lease_expires_at > statement_timestamp())
     or exists (
       select 1 from workflow.agent_handoff_imports i where i.pipeline_job_id = v_job.id)
     or workflow.pipeline_job_withdrawn(v_job.id) then
    return false;
  end if;

  -- Tilbaketrekkingen først, slik at overgangen til failed under ikke leses
  -- som en jobb som ga opp.
  insert into workflow.pipeline_job_withdrawals (pipeline_job_id, reason, withdrawn_by_actor_id)
  values (v_job.id, p_reason, p_actor_id);

  if v_job.state in ('ready', 'leased') then
    update workflow.pipeline_jobs
    set state = 'failed',
        leased_by_agent_identity_id = null,
        lease_expires_at = null,
        lease_token = null,
        completed_at = now(),
        failure_reason = p_reason
    where id = v_job.id;

    perform workflow.record_pipeline_job_event(
      v_job.id, v_job.state, 'failed'::workflow.pipeline_job_state, v_job.attempts,
      p_actor_id, null,
      'Trukket tilbake av Antidep: arbeidet oppgaven gjaldt, er ikke lenger det gjeldende.');
  end if;

  -- En oppgave som allerede sto som feilet, kan ha et åpent teknisk problem.
  -- Det var aldri et teknisk problem, og det lukkes her.
  perform workflow.resolve_technical_incident(
    'automatic_task'::workflow.technical_area, 'pipeline-job:' || v_job.id::text);

  return true;
end;
$$;

comment on function workflow.withdraw_pipeline_job(uuid, text, uuid) is
  'Trekker én oppgave tilbake fordi arbeidet den gjaldt, ikke lenger er det gjeldende. En ledig oppgave, eller en med utløpt leie, går til failed med begrunnelsen og en overgang i sporet; en som allerede sto som feilet, beholder tilstanden sin, og et åpent teknisk problem om den lukkes. Rører aldri en fullført oppgave, en med et importert svar eller en som en kjøring holder akkurat nå. Svarer om oppgaven ble trukket tilbake nå (migrasjon 014g).';

revoke execute on function workflow.withdraw_pipeline_job(uuid, text, uuid) from public;

create or replace function workflow.track_pipeline_job_incident()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  -- En oppgave Antidep har trukket tilbake, ga ikke opp. Tilbaketrekkingen er
  -- skrevet før overgangen (migrasjon 014g).
  if new.state = 'failed' and not workflow.pipeline_job_withdrawn(new.id) then
    perform workflow.record_technical_incident(
      'automatic_task',
      'pipeline-job:' || new.id::text,
      format('Pipelinejobben %s i agentleddet %s ga opp etter %s forsøk. Begrunnelsen fra siste forsøk står i workflow.pipeline_jobs.failure_reason, og hele forløpet i workflow.pipeline_job_events.',
             new.id, new.agent_role, new.attempts));
  elsif new.state = 'succeeded' then
    perform workflow.resolve_technical_incident(
      'automatic_task', 'pipeline-job:' || new.id::text);
  end if;
  return null;
end;
$$;

create function workflow.withdraw_superseded_search_tasks(
  p_plan_id uuid,
  p_role provenance.agent_role,
  p_actor_id uuid
)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_job workflow.pipeline_jobs;
  v_reason text;
  v_withdrawn integer := 0;
begin
  for v_job in
    select j.*
    from workflow.pipeline_jobs j
    join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
    where j.agent_role = p_role
      and j.input_manifest ->> 'search_plan_id' = p_plan_id::text
      and j.state <> 'succeeded'
      and not exists (
        select 1 from workflow.agent_handoff_imports i where i.pipeline_job_id = j.id)
      and not workflow.pipeline_job_withdrawn(j.id)
    order by j.enqueued_at, j.id
  loop
    v_reason := workflow.monograph_search_task_supersession(v_job);
    if v_reason is not null
       and workflow.withdraw_pipeline_job(v_job.id, v_reason, p_actor_id) then
      v_withdrawn := v_withdrawn + 1;
    end if;
  end loop;

  return v_withdrawn;
end;
$$;

comment on function workflow.withdraw_superseded_search_tasks(uuid, provenance.agent_role, uuid) is
  'Trekker tilbake hver oppgave ett kildeledd har på én søkeplan, som ikke lenger gjelder det planen står i (workflow.monograph_search_task_supersession). En oppgave en kjøring holder akkurat nå, får stå til leien er over. Svarer med hvor mange som ble trukket tilbake (migrasjon 014g).';

revoke execute on function workflow.withdraw_superseded_search_tasks(uuid, provenance.agent_role, uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Forhåndskontrollen leser den samme definisjonen
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION workflow.agent_task_input_problem(p_job workflow.pipeline_jobs)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_manifest jsonb := p_job.input_manifest;
  v_source_version_id uuid;
  v_revision_id uuid;
  v_ids uuid[];
  v_count integer;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
  v_plan_id uuid;
  v_plan workflow.monograph_search_plans;
  v_phase text;
  v_superseded text;
begin
  if p_job.agent_role = 'evidence_extraction' then
    v_source_version_id := workflow.manifest_uuid(v_manifest, 'source_version_id');
    if v_source_version_id is null then
      return 'Oppgaven sier ikke hvilken kildeversjon den gjelder.';
    end if;
    if not exists (select 1 from knowledge.source_versions sv where sv.id = v_source_version_id) then
      return 'Kildeversjonen oppgaven gjelder, finnes ikke.';
    end if;
    if knowledge.source_version_text(v_source_version_id) is null then
      return 'Kildeteksten er ikke lagret for denne kildeversjonen, så oppgaven kan ikke inneholde artikkelen. Last opp fullteksten på nytt gjennom fulltekstbiblioteket.';
    end if;

    v_ids := workflow.manifest_uuids(v_manifest, 'drug_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke virkestoff funnet kan gjelde.';
    end if;
    select count(*) into v_count from catalog.drugs d where d.id = any (v_ids);
    if v_count <> cardinality(v_ids) then
      return 'Ett av virkestoffene i oppgaven finnes ikke i katalogen.';
    end if;

    v_ids := workflow.manifest_uuids(v_manifest, 'outcome_concept_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke endepunkt funnet kan gjelde.';
    end if;
    select count(*) into v_count
    from catalog.clinical_concepts c
    where c.id = any (v_ids) and c.concept_type = 'outcome';
    if v_count <> cardinality(v_ids) then
      return 'Ett av endepunktene i oppgaven finnes ikke i katalogen.';
    end if;

    v_ids := coalesce(workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]);
    select count(*) into v_count from catalog.populations p where p.id = any (v_ids);
    if v_count <> cardinality(v_ids) then
      return 'En av populasjonene i oppgaven finnes ikke i katalogen.';
    end if;
    return null;
  end if;

  if p_job.agent_role = 'monograph_answer' then
    -- Behovet, materialet og den godkjente bruken. Uten alle tre ville
    -- oppgaven ikke kunnet utføres, og den skal da ikke stå i køen som noe
    -- som ventet på et menneske (ANTIDEP_CONSTITUTION.md regel 4).
    if workflow.manifest_uuid(v_manifest, 'monograph_need_id') is null
       or workflow.manifest_uuid(v_manifest, 'source_version_id') is null then
      return 'Oppgaven sier ikke hvilket kunnskapsbehov og hvilken kildeversjon svaret gjelder.';
    end if;
    if not exists (
      select 1 from knowledge.monograph_needs n
      where n.id = workflow.manifest_uuid(v_manifest, 'monograph_need_id')
        and n.relevance <> 'not_applicable'
    ) then
      return 'Kunnskapsbehovet finnes ikke, eller er avgjort som ikke relevant.';
    end if;
    if not exists (
      select 1 from knowledge.monograph_source_uses u
      where u.need_id = workflow.manifest_uuid(v_manifest, 'monograph_need_id')
        and u.source_version_id = workflow.manifest_uuid(v_manifest, 'source_version_id')
    ) then
      return 'Kildeversjonen er ikke godkjent for dette kunnskapsbehovet.';
    end if;
    if knowledge.source_version_text(
         workflow.manifest_uuid(v_manifest, 'source_version_id')) is null then
      return 'Kildeversjonen har ingen registrert representasjon å lese opplysningen ut av.';
    end if;
    return null;
  end if;

  if p_job.agent_role = 'claim_synthesis' then
    if workflow.manifest_uuid(v_manifest, 'topic_concept_id') is null
       or workflow.manifest_uuid(v_manifest, 'subject_drug_id') is null then
      return 'Oppgaven sier ikke hvilket tema og virkestoff påstanden skal gjelde.';
    end if;
    -- Katalogverdiene må finnes, og ikke bare ha formen. Uten dette ville
    -- oppgaven blitt bygget av et tomt oppslag, og feilen kommet først når et
    -- ferdig svar ikke lot seg registrere.
    if not exists (
      select 1 from catalog.clinical_concepts c
      where c.id = workflow.manifest_uuid(v_manifest, 'topic_concept_id')
        and c.concept_type = 'outcome'
    ) then
      return 'Temaet oppgaven gjelder, finnes ikke som et endepunkt i katalogen.';
    end if;
    if not exists (
      select 1 from catalog.drugs d
      where d.id = workflow.manifest_uuid(v_manifest, 'subject_drug_id')
    ) then
      return 'Virkestoffet oppgaven gjelder, finnes ikke i katalogen.';
    end if;
    v_ids := workflow.manifest_uuids(v_manifest, 'evidence_item_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke evidensfunn syntesen skal bygge på.';
    end if;

    -- Kontrollnivået evidensen må ha nådd, lest med skriveveiens egen funksjon.
    -- Et funn uten bekreftet ekstraksjonskontroll — eller med et senere åpent
    -- avvik — kan ikke bære en påstand, og det er like sant før oppgaven hentes
    -- ut som etter at svaret er skrevet.
    return workflow.evidence_usable_problem(
      v_ids, 'Evidensgrunnlaget er ikke klart for en syntese ennå');
  end if;

  if p_job.agent_role = 'evidence_assessment' then
    v_revision_id := workflow.manifest_uuid(v_manifest, 'claim_revision_id');
    if v_revision_id is null then
      return 'Oppgaven sier ikke hvilken påstandsrevisjon den gjelder.';
    end if;

    select r.knowledge_type, c.retired_at into v_knowledge_type, v_retired_at
    from knowledge.claim_revisions r
    join knowledge.claims c on c.id = r.claim_id
    where r.id = v_revision_id;

    if not found then
      return 'Påstandsrevisjonen oppgaven gjelder, finnes ikke.';
    end if;
    if v_knowledge_type <> 'evidence_synthesis' then
      return 'Påstanden er ikke en evidenssyntese, og skal ikke graderes. En klinisk anbefaling og et deterministisk faktum har ingen evidensvurdering.';
    end if;
    if v_retired_at is not null then
      return 'Påstanden er trukket tilbake, og skal ikke vurderes.';
    end if;
    if exists (
      select 1 from knowledge.evidence_assessments a
      where a.claim_revision_id = v_revision_id
    ) then
      return 'Påstanden er allerede vurdert. En endret vurdering av det samme grunnlaget er en ny påstandsformulering, ikke en overskriving.';
    end if;
    if not exists (
      select 1 from workflow.claim_verifications v
      where v.claim_revision_id = v_revision_id
    ) then
      return 'Påstanden er ikke kildestøttekontrollert ennå. Evidensvurderingen kommer etter den kontrollen.';
    end if;

    select array_agg(distinct l.evidence_item_id) into v_ids
    from knowledge.claim_evidence_links l
    where l.claim_revision_id = v_revision_id;

    if v_ids is null then
      return 'Påstanden har ingen evidenslenker, og det finnes ikke noe grunnlag å vurdere.';
    end if;

    -- De samme to vilkårene skriveveien leser på vurderingstidspunktet, i den
    -- samme rekkefølgen: grunnlaget må fortsatt kunne bære påstanden, og
    -- kildestøttekontrollen må være gjeldende, bekreftet og gjort av noen med
    -- mandat — på nøyaktig det evidenssettet som ligger der nå.
    return coalesce(
      workflow.evidence_usable_problem(
        v_ids, 'Evidensgrunnlaget bak påstanden er ikke lenger brukbart'),
      workflow.claim_verified_problem(
        v_revision_id, 'Kildestøttekontrollen av påstanden holder ikke'));
  end if;

  if p_job.agent_role in ('source_discovery', 'source_quality_assessment') then
    v_plan_id := workflow.manifest_uuid(v_manifest, 'search_plan_id');
    if v_plan_id is null then
      return 'Oppgaven sier ikke hvilken søkeplan den gjelder.';
    end if;

    select p.* into v_plan
    from workflow.monograph_search_plans p where p.id = v_plan_id;
    if not found then
      return 'Søkeplanen oppgaven gjelder, finnes ikke.';
    end if;

    -- Om oppgaven fortsatt gjelder det planen står i: versjonen, at planen er
    -- åpen, runden, og fra migrasjon 014g søkegrunnlaget. Den samme
    -- funksjonen avgjør hvilke oppgaver kjedeovergangen trekker tilbake, slik
    -- at køen og tilbaketrekkingen ikke kan bli uenige.
    v_superseded := workflow.monograph_search_task_supersession(p_job);
    if v_superseded is not null then
      return v_superseded;
    end if;

    if v_plan.paused_at is not null then
      return format('Søket står på pause: %s', v_plan.paused_reason);
    end if;

    if not exists (
      select 1 from workflow.monograph_search_plan_needs pn where pn.plan_id = v_plan_id
    ) then
      return 'Søkeplanen dekker ikke noe kunnskapsbehov, og det finnes ikke noe spørsmål å søke etter.';
    end if;

    -- Og rekkefølgen, som en port: ingen semantisk vurdering før Antideps egen
    -- kode faktisk har søkt og registrert resultatene.
    v_phase := workflow.monograph_search_phase_problem(v_plan_id, p_job.agent_role);
    if v_phase is not null then
      return v_phase;
    end if;

    if p_job.agent_role = 'source_quality_assessment' then
      -- Kontrollen kontrollerer et søk. Uten et utført søk å kontrollere ville
      -- den vurdert en dekning som ikke finnes (SOURCE_POLICY.md §6).
      if not exists (
        select 1 from workflow.monograph_searches s
        where s.plan_id = v_plan_id
          and s.plan_version = v_plan.plan_version
          and s.outcome in ('executed', 'zero_results')
      ) then
        return 'Ingen søk er utført på denne planversjonen ennå, så det finnes ingen søkedekning å kontrollere.';
      end if;

      if exists (
        select 1 from workflow.monograph_coverage_controls cc
        where cc.plan_id = v_plan_id and cc.plan_version = v_plan.plan_version
      ) then
        return 'Denne planversjonen er allerede dekningskontrollert. Skal dekningen kontrolleres på nytt, er planen blitt en annen.';
      end if;
    end if;

    return null;
  end if;

  return format('Rollen %s har ingen oppgaveform ennå.', p_job.agent_role);
end;
$function$;

comment on function workflow.agent_task_input_problem(workflow.pipeline_jobs) is
  'Én setning om hva som hindrer at oppgaven kan bygges av grunnlaget som faktisk ligger der, eller NULL. Fra migrasjon 013v krever kildeleddenes gren i tillegg at oppgaven hører til gjeldende maskinelle søkerunde, og at runden er utført: en semantisk oppgave som krevde søke-I/O agenten ikke har verktøy til, er ikke en oppgave — den er en umulighet, og den ble frigitt i produksjon med nettopp den begrunnelsen. En oppgave bygget under den forrige kildekontrakten bærer ingen runde, og er foreldet. Fra migrasjon 014g leser kildeleddenes gren om oppgaven fortsatt gjelder planen gjennom workflow.monograph_search_task_supersession(workflow.pipeline_jobs) — også om runden har fått flere søk enn oppgaven gjaldt — den samme definisjonen tilbaketrekkingen leser.';

-- ----------------------------------------------------------------------------
-- 5. En tilbaketrukket oppgave kan ikke tas ut
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION workflow.agent_task_problem(p_job workflow.pipeline_jobs, p_holding_lease_token uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_model provenance.role_model_assignments;
  v_holds boolean := p_holding_lease_token is not null
    and p_job.lease_token is not distinct from p_holding_lease_token
    and p_job.state = 'leased'
    and p_job.lease_expires_at is not null
    and p_job.lease_expires_at > statement_timestamp();
begin
  if not exists (
    select 1 from workflow.agent_handoff_jobs h where h.pipeline_job_id = p_job.id
  ) then
    return 'Denne jobben er ikke lagt inn som en ekstern agentoppgave, og utføres av Antideps egne kjørere.';
  end if;

  if workflow.agent_task_contract(p_job.agent_role) is null then
    return format(
      'Rollen %s utføres av Antideps egen deterministiske kode, og kan ikke settes ut til en ekstern KI-agent.',
      p_job.agent_role
    );
  end if;

  if exists (
    select 1 from workflow.agent_handoff_imports i where i.pipeline_job_id = p_job.id
  ) then
    return 'Oppgaven har allerede tatt imot et svar. Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;
  if p_job.state = 'succeeded' then
    return 'Oppgaven er allerede fullført. Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;
  -- Trukket tilbake fordi arbeidet den gjaldt, ikke lenger er det gjeldende
  -- (migrasjon 014g). Den står som historikk, og ingen skal ta den ut.
  if workflow.pipeline_job_withdrawn(p_job.id) then
    return 'Antidep har trukket oppgaven tilbake fordi arbeidet den gjaldt, ikke lenger er det gjeldende. Den blir stående som historikk; det gjeldende arbeidet er en annen oppgave.';
  end if;

  -- De to vilkårene som handler om uttaket. Den som holder leien, står innenfor
  -- dem: forsøket er allerede talt, og leien er dens egen.
  if not v_holds then
    if p_job.attempts >= p_job.max_attempts then
      return 'Oppgaven har brukt opp forsøkene sine og blir stående. Arbeidet må legges inn som en ny oppgave for å kunne gjøres om igjen.';
    end if;
    if p_job.state = 'leased'
       and p_job.lease_expires_at is not null
       and p_job.lease_expires_at > statement_timestamp() then
      return 'Oppgaven er tatt ut av en kjøring som fortsatt holder den. Den blir ledig igjen når uttaket er ferdig eller leien løper ut.';
    end if;
  end if;

  v_model := provenance.current_semantic_model(p_job.agent_role);
  if v_model.id is null then
    return 'Ingen KI-tjeneste er valgt for dette agentleddet ennå. Velg tjenesten først, slik at oppgaven bindes til den og svaret kan kontrolleres mot den.';
  end if;

  return workflow.agent_task_input_problem(p_job);
end;
$function$;

-- ----------------------------------------------------------------------------
-- 6. Kjedeovergangen: én oppgave per grunnlag
--
-- Felles for de to kildeleddene. Leddets egen overgang gjør det som er dens:
-- åpner den første runden, eller dekningskontrollens motsøk. Resten er det
-- samme for begge, og står her.
-- ----------------------------------------------------------------------------

create function workflow.chain_search_round_task(
  p_plan workflow.monograph_search_plans,
  p_role provenance.agent_role,
  p_note text
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_round integer := workflow.monograph_search_round(p_plan.id, p_role);
  v_actor uuid;
  v_manifest jsonb;
begin
  select e.ordered_by_actor_id into v_actor
  from knowledge.monograph_editions e where e.id = p_plan.edition_id;

  v_manifest := jsonb_build_object(
    'search_plan_id', p_plan.id,
    'plan_version', p_plan.plan_version,
    workflow.monograph_round_manifest_key(p_role), v_round);

  -- Den samme låsen den manuelle innleggingen tar, på det samme subjektet:
  -- planen og runden. Spørsmålet under og innleggingen som følger, er ett
  -- udelelig steg.
  perform workflow.lock_chain_subject(
    p_role, workflow.agent_task_manifest_subject(p_role, v_manifest));

  -- Det som ikke lenger gjelder, trekkes tilbake først — også mens runden
  -- fortsatt søkes. En oppgave om et grunnlag som er borte, er ikke noe som
  -- venter på et menneske.
  perform workflow.withdraw_superseded_search_tasks(p_plan.id, p_role, v_actor);

  -- Porten: den semantiske oppgaven finnes ikke før søkene er utført.
  if workflow.monograph_search_phase_problem(p_plan.id, p_role) is not null then
    return null;
  end if;

  -- Én oppgave per grunnlag. Står det en oppgave for nøyaktig dette — ledig,
  -- tatt ut, fullført, eller oppbrukt og ventende på et menneske — er det
  -- rundens oppgave. Holder en kjøring en eldre oppgave akkurat nå, får den
  -- gjøre seg ferdig eller løpe ut før den erstattes.
  if exists (
    select 1
    from workflow.pipeline_jobs j
    join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
    where j.agent_role = p_role
      and j.input_manifest ->> 'search_plan_id' = p_plan.id::text
      and not workflow.pipeline_job_withdrawn(j.id)
      and (workflow.monograph_search_task_supersession(j) is null
           or (j.state = 'leased'
               and j.lease_expires_at is not null
               and j.lease_expires_at > statement_timestamp()
               and not exists (
                 select 1 from workflow.agent_handoff_imports i
                 where i.pipeline_job_id = j.id)))
  ) then
    return null;
  end if;

  v_manifest := v_manifest || jsonb_build_object(
    'search_basis',
    workflow.monograph_search_basis(p_plan.id, p_plan.plan_version, p_role));

  return workflow.chain_enqueue_job(
    p_role,
    workflow.agent_task_job_key(p_role, v_manifest),
    v_manifest,
    v_actor,
    null,
    true,
    p_note);
end;
$$;

comment on function workflow.chain_search_round_task(workflow.monograph_search_plans, provenance.agent_role, text) is
  'Den felles delen av de to kildeleddenes kjedeovergang (migrasjon 014g). Under planens og rundens subjektlås: trekker tilbake leddets oppgaver som ikke lenger gjelder planen, holder porten til rundens maskinelle søk er utført, og legger inn én oppgave for runden slik den er nå — med søkegrunnlaget i manifestet (search_basis) — når det ikke står en oppgave for nøyaktig dette grunnlaget i noen tilstand, og ingen kjøring holder en eldre akkurat nå. Svarer med jobbens id, eller NULL.';

revoke execute on function workflow.chain_search_round_task(workflow.monograph_search_plans, provenance.agent_role, text) from public;

create or replace function workflow.chain_task_for_search_plan(p_plan_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;

  if not found or v_plan.closed_at is not null or v_plan.paused_at is not null then
    return null;
  end if;

  -- Den første runden åpnes her, der planen blir til: én forespørsel per
  -- søkemetode registeret har for planens ventende spor (migrasjon 014d).
  -- Senere runder åpnes av det semantiske leddets egne søkeforespørsler og av
  -- det Antidep selv følger opp etter en vurdering.
  if v_plan.discovery_round = 1 then
    perform workflow.open_monograph_machine_rounds(
      p_plan_id, 1, 'plan_opened'::workflow.monograph_search_request_origin,
      v_plan.created_by_actor_id, null);
  end if;

  return workflow.chain_search_round_task(
    v_plan,
    'source_discovery'::provenance.agent_role,
    'Vurderingsoppgaven lagt i køen av den gjennomførte maskinelle søkerunden.');
end;
$$;

comment on function workflow.chain_task_for_search_plan(uuid) is
  'Åpner den maskinelle søkefasen for en ny søkeplan — én runde per søkemetode registeret har for planens ventende spor (migrasjon 014d) — og legger kildeoppdagelsens semantiske vurderingsoppgave i køen når fasen for gjeldende runde er gjort. Rekkefølgen er en port: Antideps deterministiske kode søker først, og den semantiske agenten vurderer resultatene etterpå. Idempotent på planen, runden og søkegrunnlaget: vokser grunnlaget etter at oppgaven er lagt inn — en ny runde fra registeret, et søk som svarte på et senere forsøk, eller et redaktørregistrert søk, også etter at oppgaven er fullført — blir det en ny oppgave for hele grunnlaget når søkene er utført, og den gamle trekkes tilbake om den ikke er fullført (migrasjon 014g). Gjør ingenting for en plan som er erklært ferdig eller står på pause. Svarer med jobbens id, eller NULL.';

create or replace function workflow.chain_task_for_search_coverage(p_plan_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
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

  return workflow.chain_search_round_task(
    v_plan,
    'source_quality_assessment'::provenance.agent_role,
    'Kontrolloppgaven lagt i køen av den gjennomførte maskinelle motsøkerunden.');
end;
$$;

comment on function workflow.chain_task_for_search_coverage(uuid) is
  'Åpner dekningskontrollens egen maskinelle motsøkerunde for én søkeplan, og legger kontrolloppgaven i køen når runden er gjort. Motsøkene utføres av Antideps deterministiske kode under kontrollens egen identitet og kjøring, med en annen søkestrategi enn generatorens: kontrollen skal lete etter det generatoren overså, og den har ikke — og skal ikke ha — verktøy til å søke selv (SOURCE_POLICY.md §6). Gjør ingenting når det ikke finnes et utført søk å kontrollere, eller når planversjonen allerede er kontrollert. Idempotent på planen, runden og søkegrunnlaget, som kildeoppdagelsens overgang (migrasjon 014g). Svarer med jobbens id, eller NULL.';

-- ----------------------------------------------------------------------------
-- 7. Køen regner ikke det som er trukket tilbake
--
-- «Blokkert» betyr at noe venter på et menneske. En tilbaketrukket oppgave gjør
-- ikke det, og en kjører som fikk den talt med, ville meldt fra om et stopp som
-- ikke finnes (ANTIDEP_CONSTITUTION.md regel 4).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_pending_agent_tasks(p_access_token text, p_resource text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_connection workflow.agent_runner_connections;
  v_tasks jsonb;
  v_blocked integer;
begin
  v_connection := workflow.authenticated_runner_connection(p_access_token, p_resource);

  -- Bare det kjøreren trenger for å velge neste oppgave: hva den gjelder, og en
  -- ugjennomsiktig henvisning. Hele oppgaven — som bærer forskningsartikkelen —
  -- hentes først når oppgaven faktisk er tatt. En kø som leverte fulltekstene
  -- bare for å si hva som finnes, ville lastet ned hele biblioteket hver time
  -- (ANTIDEP_CONSTITUTION.md regel 2).
  select
    coalesce(
      jsonb_agg(row_to_json(q)::jsonb order by q.enqueued_at)
        filter (where q.blocked_reason is null),
      '[]'::jsonb),
    count(*) filter (where q.blocked_reason is not null)
    into v_tasks, v_blocked
  from (
    select
      workflow.agent_runner_task_ref(v_connection.id, j.id) as task_ref,
      j.agent_role::text as agent_role,
      coalesce(workflow.agent_task_subject(j) ->> 'kind', 'oppgave') as subject_kind,
      coalesce(workflow.agent_task_subject(j) ->> 'label', 'Uten tittel') as subject_label,
      j.enqueued_at,
      workflow.agent_task_problem(j) as blocked_reason
    from workflow.pipeline_jobs j
    join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
    where j.agent_role = v_connection.agent_role
      and j.state <> 'succeeded'
      and not exists (
        select 1 from workflow.agent_handoff_imports i where i.pipeline_job_id = j.id
      )
      -- Trukket tilbake er ikke ventende arbeid, og ikke noe som venter på
      -- et menneske (migrasjon 014g).
      and not workflow.pipeline_job_withdrawn(j.id)
  ) q;

  perform workflow.record_agent_runner_event(
    v_connection.id, 'list_pending_agent_tasks',
    case when jsonb_array_length(v_tasks) > 0 then 'ok'::workflow.agent_runner_outcome
         when v_blocked > 0 then 'blocked'::workflow.agent_runner_outcome
         else 'no_work'::workflow.agent_runner_outcome end,
    v_connection.agent_role, null,
    case when jsonb_array_length(v_tasks) = 0 and v_blocked > 0
      then 'Køen har bare oppgaver som venter på et menneske.' end
  );

  return jsonb_build_object(
    'agent_role', v_connection.agent_role::text,
    'tasks', v_tasks,
    -- «Ingen arbeid» og «noe venter på et menneske» er to forskjellige
    -- tilstander, og en kjører som så dem likt, ville avsluttet stille i begge
    -- (ANTIDEP_CONSTITUTION.md regel 4).
    'blocked_count', v_blocked
  );
end;
$function$;

comment on function api.list_pending_agent_tasks(text, text) is
  'Hva som venter i nettopp dette agentleddet, slik en autonom kjører trenger det: hva oppgaven gjelder, og en ugjennomsiktig henvisning (ANTIDEP_CONSTITUTION.md regel 2, 4). Inneholder ingen forskningsartikkel og ingen databaseidentitet — hele oppgaven hentes først når den faktisk er tatt, slik at én planlagt kjøring ikke laster ned hele fulltekstbiblioteket bare for å se hva som finnes. blocked_count teller de oppgavene som venter på et menneske, fordi «ingen arbeid» og «faglig blokkert» er to forskjellige tilstander. En oppgave Antidep har trukket tilbake, venter ikke på noen og er ikke med (migrasjon 014g). Rollen er tilkoblingens egen og ikke en parameter. EXECUTE går til anon: tokenet og ikke Data API-rollen er kontrollen.';

CREATE OR REPLACE FUNCTION api.agent_work_queue()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_rows jsonb;
begin
  perform knowledge.assert_editor_authorized();

  select coalesce(jsonb_agg(row_to_json(q)::jsonb order by q.enqueued_at), '[]'::jsonb)
    into v_rows
  from (
    select
      j.id as pipeline_job_id,
      j.agent_role::text as agent_role,
      j.job_key,
      j.state::text as state,
      j.attempts,
      j.max_attempts,
      j.enqueued_at,
      j.failure_reason,
      workflow.agent_task_problem(j) as blocked_reason,
      coalesce(workflow.agent_task_subject(j) ->> 'label', j.job_key) as subject_label,
      case when m.id is null then null else jsonb_build_object(
        'provider', m.provider, 'model', m.model,
        'model_version', m.model_version,
        'model_version_disclosure', m.model_version_disclosure::text) end as registered_model,
      -- Hvilken autonom kjører som holder oppgaven akkurat nå, eller NULL.
      -- Leies den ut til en planlagt kjøring, er «blokkert» feil ord for det som
      -- skjer: arbeidet er i gang.
      --
      -- Hvem som holder uttaket, leses av raden og ikke av en antakelse.
      -- Tidligere ble det utledet av at uttakshendelsen manglet en aktør, og
      -- den utledningen kunne bare svare «en kjører i denne rollen» — etter en
      -- tilbaketrekking pekte den på erstatteren, som aldri hadde tatt
      -- arbeidet. Nå navngir raden tilkoblingen selv, og en manuell import,
      -- som ikke har noen, gir NULL (ANTIDEP_CONSTITUTION.md regel 4).
      (
        select c.display_name
        from workflow.agent_runner_connections c
        where c.id = j.runner_connection_id
          and j.state = 'leased'
          and j.lease_expires_at is not null
          and j.lease_expires_at > statement_timestamp()
      ) as held_by_runner
    from workflow.pipeline_jobs j
    join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
    left join lateral provenance.current_semantic_model(j.agent_role) m on true
    where workflow.agent_task_contract(j.agent_role) is not null
      and j.state <> 'succeeded'
      and not exists (
        select 1 from workflow.agent_handoff_imports i where i.pipeline_job_id = j.id
      )
      -- En tilbaketrukket oppgave venter ikke (migrasjon 014g).
      and not workflow.pipeline_job_withdrawn(j.id)
  ) q;

  return v_rows;
end;
$function$;

CREATE OR REPLACE FUNCTION api.public_work_board()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_rows jsonb;
begin
  select coalesce(jsonb_agg(row_to_json(q)::jsonb order by q.updated_at desc), '[]'::jsonb)
    into v_rows
  from (
    -- Artiklene Antidep mangler. En åpen forespørsel uten fil er planlagt
    -- arbeid som venter på fullteksten; er filen levert, arbeider Antidep med
    -- den. Ingen av delene er en teknisk feil.
    select
      workflow.work_board_reference(r.id) as reference,
      'full_text' as activity,
      -- Tre utfall, og de betyr tre forskjellige ting for den som leser:
      -- Antidep venter på artikkelen, Antidep arbeider med den, eller Antidep
      -- står fast på noe teknisk. Bare det første er å vente på et menneske.
      case
        when i.id is null then 'planned'
        when i.state = 'blocked' then 'failed'
        else 'in_progress'
      end as status,
      case when i.id is null then 'full_text' end as waiting_for,
      (select coalesce(array_agg(d.canonical_name order by d.canonical_name), array[]::text[])
       from catalog.drugs d where d.id = any (r.drug_ids)) as subjects,
      greatest(r.requested_at, coalesce(i.submitted_at, r.requested_at)) as updated_at
    from (
      -- Bundet, som historikken under. Oversikten er offentlig og krever ingen
      -- innlogging, så den skal ikke kunne bli et vilkårlig stort arbeid å be
      -- om. Grensen ligger langt over reell mengde, og den eldste ventingen
      -- står først, fordi det er den som har stått lengst.
      select * from workflow.full_text_requests
      where state = 'open'
      order by requested_at
      limit 200
    ) r
    left join workflow.full_text_intake i
      on i.full_text_request_id = r.id
     and i.state in ('received', 'processing', 'blocked')

    union all

    -- Påstandene som har fått ny evidens, og som venter på at en redaktør
    -- avgjør om teksten skal revideres. Planlagt, redaksjonelt arbeid — aldri
    -- stoppet arbeid, og aldri et teknisk problem.
    select
      workflow.work_board_reference(rv.id),
      'claim_revision',
      'planned',
      'editorial_decision',
      (select coalesce(array_agg(d.canonical_name), array[]::text[])
       from catalog.drugs d where d.id = c.subject_drug_id),
      greatest(rv.opened_at, rv.updated_at)
    from (
      select * from workflow.claim_revision_reviews
      where state = 'open'
      order by opened_at
      limit 200
    ) rv
    join knowledge.claims c on c.id = rv.claim_id

    union all

    -- Alt annet arbeid, uavhengig av om det utføres av en ekstern KI-agent
    -- eller av Antideps egne kjørere. Hvem som gjør det, er ikke en opplysning
    -- den åpne oversikten bærer.
    select
      workflow.work_board_reference(j.id),
      case j.agent_role
        when 'evidence_extraction' then 'findings'
        when 'extraction_verification' then 'findings_check'
        when 'claim_synthesis' then 'claim'
        when 'citation_support_verification' then 'claim_check'
        when 'evidence_assessment' then 'assessment'
        else 'other'
      end,
      case j.state
        when 'succeeded' then 'done'
        when 'failed' then 'failed'
        when 'leased' then
          case when j.lease_expires_at > statement_timestamp() then 'in_progress' else 'planned' end
        else 'planned'
      end,
      null::text,
      workflow.work_board_drugs(j.input_manifest),
      coalesce(j.completed_at, j.updated_at, j.enqueued_at)
    from (
      select * from workflow.pipeline_jobs
      where state <> 'succeeded'
        -- En oppgave Antidep har trukket tilbake, har ikke feilet, og den er
        -- ikke arbeid som pågår (migrasjon 014g).
        and not workflow.pipeline_job_withdrawn(id)
      order by enqueued_at
      limit 200
    ) j

    union all

    -- Historikken. Begrenset, fordi en oversikt er en oversikt: den som vil
    -- lese hva Antidep faktisk sier, leser det publiserte innholdet.
    select
      workflow.work_board_reference(j.id),
      case j.agent_role
        when 'evidence_extraction' then 'findings'
        when 'extraction_verification' then 'findings_check'
        when 'claim_synthesis' then 'claim'
        when 'citation_support_verification' then 'claim_check'
        when 'evidence_assessment' then 'assessment'
        else 'other'
      end,
      'done',
      null::text,
      workflow.work_board_drugs(j.input_manifest),
      j.completed_at
    from (
      select * from workflow.pipeline_jobs
      where state = 'succeeded'
      order by completed_at desc
      limit 50
    ) j
  ) q;

  return v_rows;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 8. Rettighetene står som før
--
-- `create or replace` beholder dem, men de står her så en leser ser dem.
-- ----------------------------------------------------------------------------

revoke execute on function workflow.agent_task_input_problem(workflow.pipeline_jobs) from public;
revoke execute on function workflow.agent_task_problem(workflow.pipeline_jobs, uuid) from public;
revoke execute on function workflow.track_pipeline_job_incident() from public;
revoke execute on function workflow.chain_task_for_search_plan(uuid) from public;
revoke execute on function workflow.chain_task_for_search_coverage(uuid) from public;

-- ----------------------------------------------------------------------------
-- 9. Hvor køen står før reparasjonen
--
-- Skrevet ut av migrasjonen, slik at det som ble funnet, står i loggen for
-- utrullingen og ikke bare i en rapport.
-- ----------------------------------------------------------------------------

do $$
declare
  v_row record;
begin
  for v_row in
    select j.agent_role::text as role, j.state::text as state,
           coalesce(workflow.agent_task_problem(j), 'kjørbar') as problem, count(*) as n
    from workflow.pipeline_jobs j
    join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
    where j.agent_role in ('source_discovery'::provenance.agent_role,
                           'source_quality_assessment'::provenance.agent_role)
      and j.state <> 'succeeded'
      and not exists (
        select 1 from workflow.agent_handoff_imports i where i.pipeline_job_id = j.id)
    group by 1, 2, 3
    order by 1, 2, 4 desc
  loop
    raise notice 'Migrasjon 014g, før: % % × % — %', v_row.role, v_row.state, v_row.n, v_row.problem;
  end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- 10. Reparasjonen: hver plan gjennom de samme funksjonene
--
-- Ingen egen regel for de eksisterende dataene. Hver plan — også de lukkede —
-- får sine oppgaver som ikke lenger gjelder, trukket tilbake, og hver åpen plan
-- går gjennom de to kjedeovergangene, som legger inn det runden nå krever.
-- En plan hvis overgang svikter, rulles tilbake alene og står igjen for
-- rekonsilieringen; den siste kontrollen under sier fra om det ble en.
-- ----------------------------------------------------------------------------

do $$
declare
  v_actor uuid;
  v_plan record;
  v_withdrawn integer := 0;
  v_enqueued integer := 0;
  v_failed integer := 0;
begin
  select a.id into v_actor
  from provenance.actors a where a.actor_key = 'human:peder-holman';

  if v_actor is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Grunnaktøren finnes ikke, og en tilbaketrekking uten opphav ville vært arbeid ingen kan spore tilbake.';
  end if;

  for v_plan in
    select p.id, p.closed_at, p.paused_at, e.superseded_at
    from workflow.monograph_search_plans p
    join knowledge.monograph_editions e on e.id = p.edition_id
    order by p.created_at, p.id
  loop
    v_withdrawn := v_withdrawn
      + workflow.withdraw_superseded_search_tasks(
          v_plan.id, 'source_discovery'::provenance.agent_role, v_actor)
      + workflow.withdraw_superseded_search_tasks(
          v_plan.id, 'source_quality_assessment'::provenance.agent_role, v_actor);

    if v_plan.closed_at is null and v_plan.paused_at is null and v_plan.superseded_at is null then
      begin
        if workflow.chain_task_for_search_plan(v_plan.id) is not null then
          v_enqueued := v_enqueued + 1;
        end if;
        if workflow.chain_task_for_search_coverage(v_plan.id) is not null then
          v_enqueued := v_enqueued + 1;
        end if;
      exception
        when restrict_violation or no_data_found or invalid_parameter_value then
          v_failed := v_failed + 1;
          raise notice 'Migrasjon 014g: søkeplanen % fikk ingen oppgave: %', v_plan.id, sqlerrm;
      end;
    end if;
  end loop;

  raise notice 'Migrasjon 014g: % oppgaver trukket tilbake, % nye vurderingsoppgaver lagt inn, % planer uten en ny oppgave fordi grunnlaget ikke var klart.',
    v_withdrawn, v_enqueued, v_failed;
end;
$$;

-- ----------------------------------------------------------------------------
-- 11. Og den siste kontrollen: ingen ferdig søkt runde står uten sin oppgave
--
-- Invarianten selv, lest av databasen etter reparasjonen. En åpen plan med en
-- utført runde og et spørsmål å vurdere skal ha en oppgave for nøyaktig det
-- grunnlaget — i hvilken som helst tilstand — eller en kjøring som holder den
-- forrige akkurat nå. Og ingen oppgave skal både være trukket tilbake og
-- regnes som ventende arbeid. Svikter noe av det, ruller hele migrasjonen
-- tilbake, og utrullingen stopper framfor å gå videre med en kø som tier.
-- ----------------------------------------------------------------------------

do $$
declare
  v_missing integer;
  v_duplicates integer;
  v_row record;
begin
  select count(*) into v_missing
  from workflow.monograph_search_plans p
  join knowledge.monograph_editions e on e.id = p.edition_id
  cross join (values ('source_discovery'::provenance.agent_role),
                     ('source_quality_assessment'::provenance.agent_role)) as r(role)
  where p.closed_at is null
    and p.paused_at is null
    and e.superseded_at is null
    and exists (select 1 from workflow.monograph_search_plan_needs pn where pn.plan_id = p.id)
    and workflow.monograph_search_phase_problem(p.id, r.role) is null
    and (r.role = 'source_discovery'::provenance.agent_role or not exists (
      select 1 from workflow.monograph_coverage_controls cc
      where cc.plan_id = p.id and cc.plan_version = p.plan_version))
    and not exists (
      select 1
      from workflow.pipeline_jobs j
      join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
      where j.agent_role = r.role
        and j.input_manifest ->> 'search_plan_id' = p.id::text
        and not workflow.pipeline_job_withdrawn(j.id)
        and (workflow.monograph_search_task_supersession(j) is null
             or (j.state = 'leased' and j.lease_expires_at > statement_timestamp())));

  if v_missing > 0 then
    raise exception using
      errcode = 'check_violation',
      message = format('Migrasjon 014g: %s søkeplan(er) har en ferdig søkt runde uten en vurderingsoppgave.', v_missing),
      hint = 'Hver åpen plan med en utført maskinell runde skal ha én oppgave for rundens grunnlag. En runde uten den ville vært søk ingen noen gang vurderte.';
  end if;

  -- Aldri to aktive oppgaver om den samme runden.
  select count(*) into v_duplicates
  from (
    select j.agent_role, j.input_manifest ->> 'search_plan_id',
           j.input_manifest ->> workflow.monograph_round_manifest_key(j.agent_role)
    from workflow.pipeline_jobs j
    join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
    where j.agent_role in ('source_discovery'::provenance.agent_role,
                           'source_quality_assessment'::provenance.agent_role)
      and j.state in ('ready', 'leased')
      and not workflow.pipeline_job_withdrawn(j.id)
    group by 1, 2, 3
    having count(*) > 1
  ) d;

  if v_duplicates > 0 then
    raise exception using
      errcode = 'check_violation',
      message = format('Migrasjon 014g: %s søkerunde(r) har mer enn én aktiv vurderingsoppgave.', v_duplicates);
  end if;

  for v_row in
    select j.agent_role::text as role, j.state::text as state,
           coalesce(workflow.agent_task_problem(j), 'kjørbar') as problem, count(*) as n
    from workflow.pipeline_jobs j
    join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
    where j.agent_role in ('source_discovery'::provenance.agent_role,
                           'source_quality_assessment'::provenance.agent_role)
      and j.state <> 'succeeded'
      and not exists (
        select 1 from workflow.agent_handoff_imports i where i.pipeline_job_id = j.id)
      and not workflow.pipeline_job_withdrawn(j.id)
    group by 1, 2, 3
    order by 1, 2, 4 desc
  loop
    raise notice 'Migrasjon 014g, etter: % % × % — %', v_row.role, v_row.state, v_row.n, v_row.problem;
  end loop;
end;
$$;
