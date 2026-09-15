-- ============================================================================
-- Migrasjon 009b — varig, idempotent jobbtilstand for agentkjeden
--
-- Modell-leddet har hittil hatt sin tilstand i en kjøremappe på disk
-- (`src/agents/drafting-job.ts`). Den løser ett problem godt: at arbeidet gjøres
-- av en aktør Antidep ikke kaller, slik at åpning og lukking må være to
-- kommandoer. Den løser ikke det andre: *hvilke* oppdrag som står igjen, hvem
-- som holder på med hvilket akkurat nå, og hva som skjer med et oppdrag der
-- kjøreren forsvant midt i. Svaret på alle tre lå i hodet på den som kjørte.
--
-- En kjede som skal kunne gjenopptas trygt, trenger tilstanden i databasen.
--
-- ----------------------------------------------------------------------------
-- Idempotens er en nøkkel, ikke en konvensjon
--
-- `(agent_role, job_key)` er unik. `job_key` utledes deterministisk av hva
-- jobben *handler om* — kildeversjonen, evidensfunnet, påstandsrevisjonen —
-- så den samme jobben lagt inn to ganger er én rad. Det er det som gjør det
-- trygt å kjøre den som legger inn arbeid, om igjen: en avbrutt orkestrering
-- kan gjenta hele listen sin uten å doble noe.
--
-- Den samme regelen gjelder ut: `api.complete_pipeline_job` på en jobb som
-- allerede er fullført, skriver ingenting og svarer med det som ble registrert.
-- En kjører som rakk å fullføre og mistet svaret, kan spørre igjen.
--
-- ----------------------------------------------------------------------------
-- Leie framfor lås
--
-- En jobb tas ut med `for update skip locked` og får en *leie* med utløpstid.
-- To kjørere kan dermed arbeide samtidig uten å ta det samme oppdraget, og en
-- kjører som forsvinner, blokkerer ikke køen for alltid: leien løper ut, og
-- jobben blir tilgjengelig igjen. En lås i en transaksjon ville ikke overlevd
-- at prosessen døde; en leie er nettopp den tilstanden som skal overleve det.
--
-- ----------------------------------------------------------------------------
-- Fail-closed på gjentatt feil
--
-- Hvert mislykket forsøk telles. Når `attempts` når `max_attempts`, blir jobben
-- stående som `failed` og tas ikke ut igjen. Alternativet — å prøve i det
-- uendelige — ville gjort en reell feil om til en jobb som så ut som om den
-- fortsatt var underveis, og det er den ene tilstanden ANTIDEP_CONSTITUTION.md
-- regel 4 krever at aldri forveksles med noe annet.
--
-- ----------------------------------------------------------------------------
-- Hvorfor sporet ligger i en egen tabell
--
-- `workflow.pipeline_jobs` er tilstand, og tilstand endres. Overgangene er
-- derimot historikk, og historikk overskrives ikke: hver overgang skriver en
-- rad i `workflow.pipeline_job_events`, som er append-only. Da kan «hva skjedde
-- med denne jobben» besvares også etter at jobben har fått en ny tilstand.
--
-- Jobbene er ikke auditobjekter i `audit.events` sin forstand: de avgjør
-- ingenting klinisk og gir ingen rettighet. De sier hvilket arbeid som gjenstår.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 4, 7
--   docs/DATABASE_ARCHITECTURE.md §33, §43, §48, §50
--   docs/EVIDENCE_PIPELINE.md
-- ============================================================================

create type workflow.pipeline_job_state as enum ('ready', 'leased', 'succeeded', 'failed');

-- PUBLIC har som standard usage på nye typer, og Antidep gir privilegier
-- eksplisitt (migrasjon 001).
revoke usage on type workflow.pipeline_job_state from public;

comment on type workflow.pipeline_job_state is
  'Hvor en pipelinejobb står: ready (venter på en kjører), leased (en kjører holder den, med en utløpstid), succeeded (fullført, med utdatamanifest) eller failed (oppbrukte forsøk, med begrunnelse). De fire er uttømmende, og skillet mellom failed og ready er hele poenget: en oppbrukt jobb skal ikke se ut som en jobb som fortsatt er underveis (ANTIDEP_CONSTITUTION.md regel 4).';

create table workflow.pipeline_jobs (
  id uuid primary key default gen_random_uuid(),

  agent_role provenance.agent_role not null,
  -- Idempotensnøkkelen. Utledet av hva jobben handler om, ikke av når den ble
  -- lagt inn: den samme jobben lagt inn to ganger er én rad.
  job_key text not null,
  input_manifest jsonb not null,

  state workflow.pipeline_job_state not null default 'ready',
  attempts integer not null default 0,
  max_attempts integer not null default 3,

  leased_by_agent_identity_id uuid
    references provenance.agent_identities (id) on update restrict on delete restrict,
  lease_expires_at timestamptz,
  -- Selve leien, og ikke bare hvem som holder den.
  --
  -- Identiteten er *per rolle*, ikke per kjører: to kjørere i samme rolle deler
  -- den. Uten en egen nøkkel per uttak kunne en kjører hvis leie var løpt ut,
  -- meldt utfall på det uttaket en annen nettopp hadde tatt — og skrevet sitt
  -- foreldede resultat over det som faktisk pågikk. Nøkkelen er ugjettbar og ny
  -- for hvert uttak, så et utfall hører alltid til det forsøket som gjorde
  -- arbeidet.
  lease_token uuid,

  agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  output_manifest jsonb,
  failure_reason text,

  enqueued_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  enqueued_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint pipeline_jobs_role_key_key unique (agent_role, job_key),
  constraint pipeline_jobs_job_key_shape_check
    check (job_key = btrim(job_key) and length(job_key) between 1 and 300),
  constraint pipeline_jobs_attempts_check
    check (attempts >= 0 and max_attempts between 1 and 20 and attempts <= max_attempts),
  constraint pipeline_jobs_failure_reason_shape_check
    check (failure_reason is null
           or (failure_reason = btrim(failure_reason)
               and length(failure_reason) between 1 and 4000)),

  -- Hva som skal være satt følger av tilstanden, og regelen er uttømmende over
  -- vokabularet. Uten else-grenen ville en ny tilstandsverdi gitt NULL, og en
  -- NULL passerer en CHECK — regelen ville stilltiende sluttet å gjelde for
  -- nettopp den tilstanden som er ny. Samme mønster som agent_runs_status_shape_check.
  constraint pipeline_jobs_state_shape_check
    check (
      case state
        when 'ready' then
          leased_by_agent_identity_id is null and lease_expires_at is null
          and completed_at is null and output_manifest is null
        when 'leased' then
          leased_by_agent_identity_id is not null and lease_expires_at is not null
          and completed_at is null and output_manifest is null
        when 'succeeded' then
          leased_by_agent_identity_id is not null and completed_at is not null
          and output_manifest is not null and failure_reason is null
        when 'failed' then
          completed_at is not null and failure_reason is not null
          and output_manifest is null
        else false
      end
    ),
  constraint pipeline_jobs_completed_after_enqueued_check
    check (completed_at is null or completed_at >= enqueued_at),
  -- Leienøkkelen følger leieholderen: finnes den ene, finnes den andre.
  constraint pipeline_jobs_lease_token_pairing_check
    check ((leased_by_agent_identity_id is null) = (lease_token is null)),
  -- En fullført jobb skal peke på kjøringen som gjorde arbeidet. Uten kravet
  -- kunne en identitet tatt ut en jobb og meldt den fullført med et vilkårlig
  -- manifest, uten at noen kjøring med premisser noen gang ble åpnet — og køen
  -- ville rapportert utført agentarbeid uten proveniens (ANTIDEP_CONSTITUTION.md
  -- regel 4, 7).
  constraint pipeline_jobs_succeeded_needs_agent_run_check
    check (state <> 'succeeded' or agent_run_id is not null)
);

comment on table workflow.pipeline_jobs is
  'Varig jobbtilstand for agentkjeden (ANTIDEP_CONSTITUTION.md regel 4, DATABASE_ARCHITECTURE.md §33). Én rad per stykke arbeid som gjenstår eller er gjort, identifisert av (agent_role, job_key) der job_key utledes deterministisk av hva jobben handler om. Unikheten er idempotensen: den som legger inn arbeid, kan gjenta hele listen sin uten å doble noe, og en avbrutt orkestrering kan derfor gjenopptas trygt. En jobb tas ut med en leie som løper ut, slik at en kjører som forsvinner ikke blokkerer køen — og telles ned mot max_attempts, slik at en jobb som virkelig feiler, blir stående som failed framfor å se ut som om den fortsatt er underveis. Tilstanden endres; overgangene bevares i workflow.pipeline_job_events.';
comment on column workflow.pipeline_jobs.job_key is
  'Idempotensnøkkelen, utledet deterministisk av hva jobben handler om — kildeversjonen, evidensfunnet, påstandsrevisjonen. Aldri et tidspunkt eller et løpenummer: to jobber om det samme arbeidet skal være én rad, ikke to.';
comment on column workflow.pipeline_jobs.lease_token is
  'Den ugjettbare nøkkelen for *dette* uttaket, ny for hvert forsøk. Agentidentiteten er per rolle og deles av alle kjørere i den, så identiteten alene kan ikke skille en kjører hvis leie er løpt ut, fra den som nå holder den. Nøkkelen kan: et utfall meldes bare av det forsøket som faktisk gjorde arbeidet. Følger leieholderen — finnes den ene, finnes den andre.';
comment on column workflow.pipeline_jobs.lease_expires_at is
  'Når leien på en leased jobb løper ut. En utløpt leie gjør jobben tilgjengelig igjen for en annen kjører. NULL i alle andre tilstander, håndhevet av pipeline_jobs_state_shape_check.';
comment on column workflow.pipeline_jobs.attempts is
  'Antall forsøk som er påbegynt. Økes når jobben tas ut, ikke når den feiler, slik at en kjører som dør uten å melde fra, også telles — ellers ville nettopp den feilformen kunnet prøves i det uendelige.';
comment on column workflow.pipeline_jobs.failure_reason is
  'Begrunnelsen fra siste mislykkede forsøk. Står også på en ready-rad, fordi forrige forsøks begrunnelse er den opplysningen som forklarer hvorfor jobben er tilbake i køen. Påkrevd i tilstanden failed.';

alter table workflow.pipeline_jobs enable row level security;

create index pipeline_jobs_ready_idx
  on workflow.pipeline_jobs (agent_role, enqueued_at)
  where state in ('ready', 'leased');

create trigger pipeline_jobs_set_row_timestamps
  before insert or update on workflow.pipeline_jobs
  for each row execute function catalog.set_row_timestamps();

create table workflow.pipeline_job_events (
  id uuid primary key default gen_random_uuid(),

  pipeline_job_id uuid not null
    references workflow.pipeline_jobs (id) on update restrict on delete restrict,
  from_state workflow.pipeline_job_state,
  to_state workflow.pipeline_job_state not null,
  attempt integer not null,
  note text,

  -- Hvem som utløste overgangen. Enten en aktør (innleggingen) eller en
  -- agentidentitet (uttaket og utfallet); aldri begge, og aldri ingen.
  actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  agent_identity_id uuid
    references provenance.agent_identities (id) on update restrict on delete restrict,

  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint pipeline_job_events_single_origin_check
    check (num_nonnulls(actor_id, agent_identity_id) = 1),
  constraint pipeline_job_events_attempt_check check (attempt >= 0),
  constraint pipeline_job_events_note_shape_check
    check (note is null or (note = btrim(note) and length(note) between 1 and 4000))
);

comment on table workflow.pipeline_job_events is
  'Append-only spor over hver tilstandsovergang på en pipelinejobb (DATABASE_ARCHITECTURE.md §33). Jobben selv er tilstand og endres; overgangene er historikk og overskrives ikke. Uten denne tabellen ville «hva skjedde med denne jobben» vært ubesvarlig så snart jobben hadde fått en ny tilstand — og et forsøk som feilet og ble prøvd om igjen, ville vært usynlig.';

alter table workflow.pipeline_job_events enable row level security;

create index pipeline_job_events_job_idx
  on workflow.pipeline_job_events (pipeline_job_id, occurred_at);

-- Tabellen har ingen updated_at, fordi en rad aldri endres. Da må created_at
-- settes av databasen også når kalleren oppgir den: en default gjelder bare
-- når kolonnen utelates, og et spor som kunne dateres fritt, ville ikke vært
-- et spor (supabase/tests/180_workflow_structure_test.sql).
create trigger pipeline_job_events_set_created_at
  before insert on workflow.pipeline_job_events
  for each row execute function catalog.set_created_at();

create trigger pipeline_job_events_are_append_only
  before update or delete on workflow.pipeline_job_events
  for each row execute function knowledge.reject_append_only_mutation(
    'Et jobbspor sier hva som faktisk skjedde. En ny overgang er en ny rad.'
  );

-- ----------------------------------------------------------------------------
-- Bindingen mellom ett uttak og den kjøringen som gjorde arbeidet
--
-- At en jobb peker på en agentkjøring i riktig rolle, med riktig identitet og
-- med et vellykket utfall, beviser bare at *identiteten en gang har hatt en
-- vellykket kjøring i den rollen*. Kjøringens id velges av kalleren, så en
-- kjører kunne tatt ut jobb B og meldt den ferdig med kjøringen fra jobb A —
-- og raden ville sett like riktig ut.
--
-- Bindingen må derfor skrives når kjøringen åpnes, av databasen, mot det
-- uttaket som gjelder da. `api.begin_pipeline_job_run` er den ene veien inn:
-- den kontrollerer leien og nøkkelen før kjøringen åpnes, og skriver raden her.
--
-- Kjøringen er unik i tabellen. Én kjøring tjener nøyaktig ett uttak av én
-- jobb, og kan aldri gjenbrukes til et annet — det er hele regelen, uttrykt som
-- en nøkkel framfor som en kontroll noen må huske å gjøre.
-- ----------------------------------------------------------------------------
create table workflow.pipeline_job_runs (
  id uuid primary key default gen_random_uuid(),

  -- Unik, ikke bare en fremmednøkkel: én kjøring tjener nøyaktig ett uttak av
  -- én jobb, og kan aldri gjenbrukes til et annet.
  agent_run_id uuid not null unique
    references provenance.agent_runs (id) on update restrict on delete restrict,

  pipeline_job_id uuid not null
    references workflow.pipeline_jobs (id) on update restrict on delete restrict,
  -- Nøkkelen for nettopp det uttaket kjøringen ble åpnet for. Uten den ville
  -- bindingen holdt på tvers av forsøk: et nytt uttak av den samme jobben ville
  -- kunnet melde utfall med kjøringen fra det forrige.
  lease_token uuid not null,
  attempt integer not null,

  created_at timestamptz not null default now(),

  constraint pipeline_job_runs_attempt_check check (attempt > 0)
);

comment on table workflow.pipeline_job_runs is
  'Hvilken agentkjøring som ble åpnet for hvilket uttak av hvilken pipelinejobb (DATABASE_ARCHITECTURE.md §33, §43). Skrives av api.begin_pipeline_job_run når kjøringen åpnes, etter at leien og leienøkkelen er kontrollert, og aldri av kalleren. Uten raden ville api.complete_pipeline_job bare kunnet kontrollere at kjøringen tilhørte den samme identiteten og rollen — og en kjører kunne meldt jobb B ferdig med kjøringen fra jobb A. Kjøringen er unik i tabellen: én kjøring tjener nøyaktig ett uttak av én jobb, og kan aldri gjenbrukes til et annet.';
comment on column workflow.pipeline_job_runs.lease_token is
  'Uttaket kjøringen ble åpnet for. Bindingen gjelder det forsøket og ikke jobben som sådan: et nytt uttak må åpne sin egen kjøring.';

alter table workflow.pipeline_job_runs enable row level security;

create index pipeline_job_runs_job_idx
  on workflow.pipeline_job_runs (pipeline_job_id, lease_token);

create trigger pipeline_job_runs_set_created_at
  before insert on workflow.pipeline_job_runs
  for each row execute function catalog.set_created_at();

create trigger pipeline_job_runs_are_append_only
  before update or delete on workflow.pipeline_job_runs
  for each row execute function knowledge.reject_append_only_mutation(
    'Bindingen sier hvilken kjøring som faktisk gjorde hvilket uttak. En ny kjøring er en ny rad.'
  );

-- ----------------------------------------------------------------------------
-- Overgangsskriveren
--
-- Én funksjon, kalt av hver skrivevei, framfor fire steder å glemme sporet.
-- ----------------------------------------------------------------------------
create function workflow.record_pipeline_job_event(
  p_pipeline_job_id uuid,
  p_from_state workflow.pipeline_job_state,
  p_to_state workflow.pipeline_job_state,
  p_attempt integer,
  p_actor_id uuid,
  p_agent_identity_id uuid,
  p_note text
)
  returns uuid
  language sql
  set search_path = ''
as $$
  insert into workflow.pipeline_job_events (
    pipeline_job_id, from_state, to_state, attempt, note, actor_id, agent_identity_id
  )
  values (
    p_pipeline_job_id, p_from_state, p_to_state, p_attempt,
    nullif(btrim(coalesce(p_note, '')), ''), p_actor_id, p_agent_identity_id
  )
  returning id;
$$;

comment on function workflow.record_pipeline_job_event(uuid, workflow.pipeline_job_state, workflow.pipeline_job_state, integer, uuid, uuid, text) is
  'Skriver én rad i sporet over jobbens tilstandsoverganger. Ett sted framfor fire, slik at ingen skrivevei kan endre en jobb uten å etterlate sporet. Kalles fra innsiden av en SECURITY DEFINER-funksjon og trenger derfor ikke være det selv.';

revoke execute on function workflow.record_pipeline_job_event(uuid, workflow.pipeline_job_state, workflow.pipeline_job_state, integer, uuid, uuid, text) from public;

-- ----------------------------------------------------------------------------
-- Innlegging: idempotent på (rolle, nøkkel)
-- ----------------------------------------------------------------------------
create function api.enqueue_pipeline_job(
  p_agent_role text,
  p_job_key text,
  p_input_manifest jsonb
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_role provenance.agent_role;
  v_job workflow.pipeline_jobs;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role),
        hint = 'Gyldige roller er de eksplisitte agentrollene i EVIDENCE_PIPELINE.md.';
  end;

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.agent_role = v_role and j.job_key = p_job_key;

  if found then
    -- Idempotent: den samme jobben lagt inn igjen er den samme jobben. Et
    -- inndatamanifest som avviker, er derimot et *annet* oppdrag under samme
    -- navn, og en stille gjenbruk ville latt en kjører arbeide på noe annet enn
    -- det som ble bedt om.
    if v_job.input_manifest is distinct from p_input_manifest then
      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'Jobben %L finnes allerede for rollen %L, men med et annet inndatamanifest.',
          p_job_key, p_agent_role
        ),
        hint = 'Jobbnøkkelen skal utledes av hva jobben handler om. To forskjellige oppdrag under samme nøkkel ville gjort køen tvetydig; velg en nøkkel som skiller dem.';
    end if;
    return jsonb_build_object(
      'pipeline_job_id', v_job.id, 'state', v_job.state::text, 'enqueued', false
    );
  end if;

  insert into workflow.pipeline_jobs (agent_role, job_key, input_manifest, enqueued_by_actor_id)
  values (v_role, p_job_key, p_input_manifest, v_actor_id)
  returning * into v_job;

  perform workflow.record_pipeline_job_event(
    v_job.id, null, 'ready'::workflow.pipeline_job_state, 0, v_actor_id, null, null
  );

  return jsonb_build_object(
    'pipeline_job_id', v_job.id, 'state', v_job.state::text, 'enqueued', true
  );
end;
$$;

comment on function api.enqueue_pipeline_job(text, text, jsonb) is
  'Legger ett stykke agentarbeid i køen, idempotent på (agent_role, job_key) (DATABASE_ARCHITECTURE.md §43). Kontrollerer at kalleren har en registrert, aktiv aktør og gyldig editor-rolle. Er jobben lagt inn fra før, skrives ingenting og svaret sier enqueued: false — slik at en avbrutt orkestrering kan gjenta hele listen sin. Et avvikende inndatamanifest under samme nøkkel avvises framfor å gjenbrukes stille: det ville vært et annet oppdrag under samme navn. SECURITY DEFINER fordi workflow og provenance har RLS med default deny; tomt search_path, og kalleren valideres på funksjonens eget kall (§50).';

revoke execute on function api.enqueue_pipeline_job(text, text, jsonb) from public;
grant execute on function api.enqueue_pipeline_job(text, text, jsonb) to authenticated;

-- ----------------------------------------------------------------------------
-- Uttak: én jobb, én leie, ingen to kjørere på samme oppdrag
-- ----------------------------------------------------------------------------
create function api.claim_pipeline_job(
  p_identity_key text,
  p_secret text,
  p_agent_role text,
  p_lease_seconds integer default 900
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_role provenance.agent_role;
  v_identity_id uuid;
  v_job workflow.pipeline_jobs;
  v_from workflow.pipeline_job_state;
begin
  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role),
        hint = 'Gyldige roller er de eksplisitte agentrollene i EVIDENCE_PIPELINE.md.';
  end;

  v_identity_id := provenance.authenticate_agent_identity(p_identity_key, p_secret, v_role);

  if p_lease_seconds is null or p_lease_seconds < 30 or p_lease_seconds > 86400 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Leietiden %s sekunder er utenfor 30–86400.', coalesce(p_lease_seconds::text, 'NULL')),
      hint = 'En leie som er for kort, utløper mens arbeidet pågår og lar to kjørere ta det samme oppdraget. En som er for lang, holder et oppdrag utilgjengelig lenge etter at kjøreren er borte.';
  end if;

  -- `skip locked` framfor å vente: to kjørere som spør samtidig, skal få hver
  -- sin jobb, ikke stå i kø bak hverandre. En utløpt leie regnes som ledig —
  -- det er nettopp den tilstanden som skal overleve at en prosess døde.
  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.agent_role = v_role
    and (
      j.state = 'ready'
      or (j.state = 'leased' and j.lease_expires_at <= now())
    )
    and j.attempts < j.max_attempts
  order by j.enqueued_at, j.id
  for update skip locked
  limit 1;

  if not found then
    return jsonb_build_object('claimed', false);
  end if;

  v_from := v_job.state;

  update workflow.pipeline_jobs j
  set state = 'leased',
      attempts = j.attempts + 1,
      leased_by_agent_identity_id = v_identity_id,
      -- Ny nøkkel for hvert uttak. Den forrige slutter å gjelde i det samme
      -- øyeblikket, så et utfall fra en utløpt leie treffer ingenting.
      lease_token = gen_random_uuid(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds)
  where j.id = v_job.id
  returning * into v_job;

  perform workflow.record_pipeline_job_event(
    v_job.id, v_from, 'leased'::workflow.pipeline_job_state, v_job.attempts,
    null, v_identity_id,
    case when v_from = 'leased' then 'Forrige leie var utløpt.' else null end
  );

  return jsonb_build_object(
    'claimed', true,
    'pipeline_job_id', v_job.id,
    'job_key', v_job.job_key,
    'agent_role', v_job.agent_role::text,
    'input_manifest', v_job.input_manifest,
    'attempt', v_job.attempts,
    'max_attempts', v_job.max_attempts,
    'lease_token', v_job.lease_token,
    'lease_expires_at', v_job.lease_expires_at,
    'last_failure_reason', v_job.failure_reason
  );
end;
$$;

comment on function api.claim_pipeline_job(text, text, text, integer) is
  'Tar ut én jobb for rollen legitimasjonen er autentisert for, og gir den en leie med utløpstid (DATABASE_ARCHITECTURE.md §33, §43). Bruker FOR UPDATE SKIP LOCKED, slik at to kjørere som spør samtidig får hver sin jobb framfor å stå i kø. En jobb med utløpt leie regnes som ledig: en kjører som forsvant, skal ikke blokkere køen for alltid. attempts økes ved uttaket og ikke ved feilen, slik at en kjører som dør uten å melde fra, også telles — ellers ville nettopp den feilformen kunnet prøves i det uendelige. Svarer {claimed: false} når køen er tom; det er ikke en feil. EXECUTE går til anon fordi en agent ikke har brukerkonto — legitimasjonen og ikke Data API-rollen er kontrollen.';

revoke execute on function api.claim_pipeline_job(text, text, text, integer) from public;
grant execute on function api.claim_pipeline_job(text, text, text, integer) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Å åpne en kjøring *for* et uttak
--
-- Rollen hentes fra jobben og oppgis ikke av kalleren: hvilken rolle arbeidet
-- gjøres i, er allerede avgjort av jobben som ble lagt inn, og en kaller som
-- kunne oppgitt en annen, ville kunnet åpne en kjøring i feil rolle for et
-- uttak hen faktisk holdt.
--
-- Premissene går uendret videre til api.begin_agent_run, som beholder hele sin
-- egen kontroll: autentisering, modellgaten og kravet om kildeversjon for
-- ekstraksjonsrollen. Denne funksjonen legger til én ting — bindingen — og
-- duplikerer ingenting av det.
-- ----------------------------------------------------------------------------
create function api.begin_pipeline_job_run(
  p_identity_key text,
  p_secret text,
  p_pipeline_job_id uuid,
  p_lease_token uuid,
  p_provider text,
  p_model text,
  p_model_version text,
  p_prompt_template_version text,
  p_pipeline_version text,
  p_input_manifest jsonb,
  p_input_source_version_id uuid default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_job workflow.pipeline_jobs;
  v_identity_id uuid;
  v_run_id uuid;
begin
  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.id = p_pipeline_job_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Pipelinejobben %L finnes ikke.', p_pipeline_job_id);
  end if;

  v_identity_id := provenance.authenticate_agent_identity(p_identity_key, p_secret, v_job.agent_role);

  if v_job.state <> 'leased'
     or v_job.leased_by_agent_identity_id is distinct from v_identity_id
     or v_job.lease_token is distinct from p_lease_token then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Jobben %L står som %L, og dette forsøket holder ikke leien.',
        p_pipeline_job_id, v_job.state::text
      ),
      hint = 'En kjøring åpnes for det uttaket som arbeider. Ta jobben ut på nytt framfor å åpne en kjøring på en leie som ikke er din.';
  end if;

  v_run_id := api.begin_agent_run(
    p_identity_key, p_secret, v_job.agent_role::text,
    p_provider, p_model, p_model_version,
    p_prompt_template_version, p_pipeline_version,
    p_input_manifest, p_input_source_version_id
  );

  insert into workflow.pipeline_job_runs (agent_run_id, pipeline_job_id, lease_token, attempt)
  values (v_run_id, v_job.id, v_job.lease_token, v_job.attempts);

  return v_run_id;
end;
$$;

comment on function api.begin_pipeline_job_run(text, text, uuid, uuid, text, text, text, text, text, jsonb, uuid) is
  'Åpner en agentkjøring for ett bestemt uttak av én pipelinejobb, og binder de to i workflow.pipeline_job_runs (DATABASE_ARCHITECTURE.md §33, §43). Leien og leienøkkelen kontrolleres først, og rollen hentes fra jobben framfor å oppgis av kalleren. Selve kjøringen åpnes av api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb, uuid), som beholder hele sin egen kontroll — autentisering, modellgaten og kravet om kildeversjon for ekstraksjonsrollen — slik at ingenting av den er duplisert her. Uten denne veien kunne api.complete_pipeline_job bare kontrollert at kjøringen tilhørte den samme identiteten og rollen, og en kjører kunne meldt jobb B ferdig med kjøringen fra jobb A: bindingen er det som gjør raden til et bevis om *denne* jobben. EXECUTE går til anon av samme grunn som api.claim_pipeline_job(text, text, text, integer).';

revoke execute on function api.begin_pipeline_job_run(text, text, uuid, uuid, text, text, text, text, text, jsonb, uuid) from public;
grant execute on function api.begin_pipeline_job_run(text, text, uuid, uuid, text, text, text, text, text, jsonb, uuid) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Fullføring: idempotent, og bundet til den som holder leien
-- ----------------------------------------------------------------------------
create function api.complete_pipeline_job(
  p_identity_key text,
  p_secret text,
  p_pipeline_job_id uuid,
  p_lease_token uuid,
  p_output_manifest jsonb,
  p_agent_run_id uuid
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_job workflow.pipeline_jobs;
  v_identity_id uuid;
  v_from workflow.pipeline_job_state;
begin
  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.id = p_pipeline_job_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Pipelinejobben %L finnes ikke.', p_pipeline_job_id);
  end if;

  v_identity_id := provenance.authenticate_agent_identity(p_identity_key, p_secret, v_job.agent_role);

  -- Idempotent: en kjører som rakk å fullføre og mistet svaret, kan spørre
  -- igjen. Ingenting skrives, og det registrerte utfallet er svaret.
  --
  -- Nøkkelen avgjør, ikke identiteten: det er *forsøket* som eier utfallet.
  if v_job.state = 'succeeded' then
    if v_job.lease_token is distinct from p_lease_token then
      raise exception using
        errcode = 'insufficient_privilege',
        message = 'Jobben er allerede fullført av et annet forsøk.',
        hint = 'Utfallet hører til det forsøket som gjorde arbeidet. Et annet forsøk kan ikke bekrefte eller overskrive det.';
    end if;
    return jsonb_build_object(
      'pipeline_job_id', v_job.id, 'state', v_job.state::text,
      'output_manifest', v_job.output_manifest, 'completed', false
    );
  end if;

  if v_job.state <> 'leased'
     or v_job.leased_by_agent_identity_id is distinct from v_identity_id
     or v_job.lease_token is distinct from p_lease_token then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Jobben %L står som %L og kan ikke fullføres av dette forsøket.',
        p_pipeline_job_id, v_job.state::text
      ),
      hint = 'Bare det uttaket som holder leien, kan melde et utfall, og leienøkkelen er uttakets egen. Er leien løpt ut og tatt av et nytt forsøk, er arbeidet gjort om igjen der; ta jobben ut på nytt framfor å skrive over utfallet.';
  end if;

  if p_output_manifest is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En fullført jobb skal ha et utdatamanifest.',
      hint = 'Manifestet er det som gjør utfallet lesbart i ettertid. En jobb som bare sier «ferdig», sier ingenting om hva den gjorde.';
  end if;

  if p_agent_run_id is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En fullført jobb skal peke på agentkjøringen som gjorde arbeidet.',
      hint = 'Uten kjøringen ville køen rapportert utført agentarbeid uten premisser og uten spor — og en jobb kunne blitt meldt fullført uten at noe arbeid noen gang ble åpnet (ANTIDEP_CONSTITUTION.md regel 4, 7).';
  end if;

  if not exists (
    select 1
    from provenance.agent_runs r
    where r.id = p_agent_run_id
      and r.agent_identity_id = v_identity_id
      and r.agent_role = v_job.agent_role
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Agentkjøringen tilhører ikke identiteten og rollen som melder utfallet.',
      hint = 'Kjøringen knytter jobben til premissene arbeidet faktisk ble gjort under. En kjøring fra en annen identitet eller en annen rolle ville vært en usann kobling.';
  end if;

  -- Bindingen, og ikke identiteten, er beviset.
  --
  -- Identitet og rolle sier bare at kjøringen kunne ha vært denne jobbens.
  -- Raden i workflow.pipeline_job_runs sier at kjøringen ble åpnet *for dette
  -- uttaket*, av databasen, mens leien var gyldig. Uten den kunne et uttak av
  -- jobb B blitt meldt ferdig med en gammel, vellykket kjøring fra jobb A.
  if not exists (
    select 1
    from workflow.pipeline_job_runs b
    where b.agent_run_id = p_agent_run_id
      and b.pipeline_job_id = v_job.id
      and b.lease_token = v_job.lease_token
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Agentkjøringen ble ikke åpnet for dette uttaket av denne jobben.',
      hint = 'Kjøringen bindes til uttaket når den åpnes, av api.begin_pipeline_job_run. En kjøring fra en annen jobb eller et annet forsøk ville gjort raden til et bevis om noe annet enn dette arbeidet (ANTIDEP_CONSTITUTION.md regel 4, 7).';
  end if;

  -- En åpen kjøring har ikke konkludert, og en som feilet eller ble stoppet,
  -- har konkludert med noe annet enn suksess. Uten denne kontrollen kunne køen
  -- meldt vellykket agentarbeid mens kjøringen bak fortsatt sto som `running`
  -- — og «ferdig» ville vært en påstand køen skrev om seg selv, ikke et utfall
  -- proveniensen bærer (ANTIDEP_CONSTITUTION.md regel 4).
  if not exists (
    select 1
    from provenance.agent_runs r
    where r.id = p_agent_run_id
      and r.status = 'succeeded'
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Agentkjøringen er ikke avsluttet med et vellykket utfall.',
      hint = 'En jobb er ikke vellykket før arbeidet bak den er det. Avslutt kjøringen med api.complete_agent_run før utfallet meldes; en kjøring som fortsatt står som running, failed eller aborted, kan ikke bære en fullført jobb (ANTIDEP_CONSTITUTION.md regel 4).';
  end if;

  v_from := v_job.state;

  update workflow.pipeline_jobs j
  set state = 'succeeded',
      output_manifest = p_output_manifest,
      agent_run_id = p_agent_run_id,
      failure_reason = null,
      -- Leienøkkelen blir stående: den er nøkkelen det fullførte forsøket
      -- spør med når det gjentar kallet.
      lease_expires_at = null,
      completed_at = now()
  where j.id = v_job.id
  returning * into v_job;

  perform workflow.record_pipeline_job_event(
    v_job.id, v_from, 'succeeded'::workflow.pipeline_job_state, v_job.attempts,
    null, v_identity_id, null
  );

  return jsonb_build_object(
    'pipeline_job_id', v_job.id, 'state', v_job.state::text,
    'output_manifest', v_job.output_manifest, 'completed', true
  );
end;
$$;

comment on function api.complete_pipeline_job(text, text, uuid, uuid, jsonb, uuid) is
  'Melder et vellykket utfall på det uttaket p_lease_token navngir (DATABASE_ARCHITECTURE.md §33, §43). Idempotent: en allerede fullført jobb skriver ingenting og svarer med det registrerte utdatamanifestet, slik at en kjører som mistet svaret sitt, kan spørre igjen med den samme nøkkelen. Nøkkelen og ikke identiteten er kontrollen: agentidentiteten er per rolle og deles av alle kjørere i den, så uten en nøkkel per uttak kunne en kjører hvis leie var løpt ut, skrevet sitt foreldede resultat over det uttaket en annen nettopp hadde tatt. p_agent_run_id er påkrevd, må være bundet til nettopp dette uttaket av denne jobben gjennom workflow.pipeline_job_runs, må tilhøre den samme identiteten og rollen, og må være avsluttet med status succeeded: uten kjøringen ville køen rapportert utført agentarbeid uten premisser og uten spor, og med en kjøring som fortsatt står som running, ville «ferdig» vært en påstand køen skrev om seg selv framfor et utfall proveniensen bærer. EXECUTE går til anon av samme grunn som api.claim_pipeline_job(text, text, text, integer).';

revoke execute on function api.complete_pipeline_job(text, text, uuid, uuid, jsonb, uuid) from public;
grant execute on function api.complete_pipeline_job(text, text, uuid, uuid, jsonb, uuid) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Feil: tilbake i køen, eller endelig
-- ----------------------------------------------------------------------------
create function api.fail_pipeline_job(
  p_identity_key text,
  p_secret text,
  p_pipeline_job_id uuid,
  p_lease_token uuid,
  p_failure_reason text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_job workflow.pipeline_jobs;
  v_identity_id uuid;
  v_from workflow.pipeline_job_state;
  v_next workflow.pipeline_job_state;
begin
  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.id = p_pipeline_job_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Pipelinejobben %L finnes ikke.', p_pipeline_job_id);
  end if;

  v_identity_id := provenance.authenticate_agent_identity(p_identity_key, p_secret, v_job.agent_role);

  if v_job.state <> 'leased'
     or v_job.leased_by_agent_identity_id is distinct from v_identity_id
     or v_job.lease_token is distinct from p_lease_token then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Jobben %L står som %L og kan ikke meldes mislykket av dette forsøket.',
        p_pipeline_job_id, v_job.state::text
      ),
      hint = 'Leienøkkelen er uttakets egen. Er leien løpt ut og tatt av et nytt forsøk, hører utfallet til det forsøket.';
  end if;

  if nullif(btrim(coalesce(p_failure_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En mislykket jobb skal ha en begrunnelse.',
      hint = 'Uten begrunnelsen er en teknisk feil og et forslag som ikke holdt mål, samme tilstand — og de to er forskjellige tilstander (ANTIDEP_CONSTITUTION.md regel 4).';
  end if;

  v_from := v_job.state;
  -- Fail-closed: oppbrukte forsøk gir en jobb som blir stående, ikke en jobb
  -- som prøves i det uendelige og hele tiden ser ut som om den er underveis.
  v_next := case when v_job.attempts >= v_job.max_attempts then 'failed' else 'ready' end;

  update workflow.pipeline_jobs j
  set state = v_next,
      failure_reason = btrim(p_failure_reason),
      leased_by_agent_identity_id =
        case when v_next = 'failed' then j.leased_by_agent_identity_id else null end,
      -- Nøkkelen følger leieholderen (pipeline_jobs_lease_token_pairing_check):
      -- en jobb som er tilbake i køen, har ingen leie og dermed ingen nøkkel.
      lease_token = case when v_next = 'failed' then j.lease_token else null end,
      lease_expires_at = null,
      completed_at = case when v_next = 'failed' then now() else null end
  where j.id = v_job.id
  returning * into v_job;

  perform workflow.record_pipeline_job_event(
    v_job.id, v_from, v_next, v_job.attempts, null, v_identity_id, btrim(p_failure_reason)
  );

  return jsonb_build_object(
    'pipeline_job_id', v_job.id,
    'state', v_job.state::text,
    'attempts', v_job.attempts,
    'max_attempts', v_job.max_attempts,
    'will_retry', v_next = 'ready'
  );
end;
$$;

comment on function api.fail_pipeline_job(text, text, uuid, uuid, text) is
  'Melder et mislykket forsøk på det uttaket p_lease_token navngir (ANTIDEP_CONSTITUTION.md regel 4, DATABASE_ARCHITECTURE.md §33). Jobben går tilbake til ready så lenge det er forsøk igjen, og blir stående som failed når de er brukt opp — fail-closed, slik at en reell feil ikke ser ut som en jobb som fortsatt er underveis. Begrunnelsen er påkrevd: uten den ville en teknisk feil og et forslag som ikke holdt mål, vært samme tilstand. EXECUTE går til anon av samme grunn som api.claim_pipeline_job(text, text, text, integer).';

revoke execute on function api.fail_pipeline_job(text, text, uuid, uuid, text) from public;
grant execute on function api.fail_pipeline_job(text, text, uuid, uuid, text) to anon, authenticated;
