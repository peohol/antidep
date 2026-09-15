-- ============================================================================
-- Migrasjon 010a — modellproveniensen blir sann også når leverandøren ikke
-- forteller alt
--
-- Fram til nå har `provenance.agent_runs` og `provenance.role_model_assignments`
-- krevd tre utfylte felter: leverandør, modell og modellversjon. Det holdt så
-- lenge hvert ledd var Antideps egen deterministiske kode, der «versjonen» er
-- vår egen og alltid kjent.
--
-- Fra nå av utføres det semantiske arbeidet av en ekstern KI-agent — i praksis
-- vanlig ChatGPT i et nettleservindu — og den tjenesten eksponerer ikke noen
-- intern build. Et krav om en eksakt modellversjon ville derfor tvunget fram én
-- av to ting, og begge er verre enn å si det som det er:
--
--   * en oppdiktet versjonsstreng, som er en usann proveniens, eller
--   * en fri tekst per svar («ukjent», «unknown», «n/a»), som ville gjort to
--     kjøringer av *samme* modell til to forskjellige modellidentiteter — og da
--     ville separasjonsregelen sluttet å virke nettopp der den betyr mest.
--
-- ----------------------------------------------------------------------------
-- 1. Eksponeringen er en egen opplysning, og den ukjente versjonen er kanonisk
--
-- `model_version_disclosure` sier hvilken av to ting versjonsfeltet er:
--
--   exact         tjenesten oppgir en eksakt versjon eller build, og den står
--   not_exposed   tjenesten oppgir ingen, og feltet bærer den kanoniske verdien
--                 'ikke-eksponert'
--
-- Kanonisk, og ikke fri tekst, er hele poenget. Exclusion-regelen som hindrer at
-- to roller deler modellidentitet, sammenligner leverandør, modell og
-- modellversjon. Med én kanonisk verdi for «ikke eksponert» er to ukjente
-- versjoner av den samme modellen den SAMME identiteten — som er sant — framfor
-- to forskjellige, som ville vært en stille svekkelse av regelen.
--
-- ----------------------------------------------------------------------------
-- 2. Hvem som registrerte, og hvem som tenkte, er to opplysninger
--
-- En registreringskjøring er Antideps egen deterministiske kode: den leser et
-- forslag, kontrollerer det og skriver raden. Modellen som faktisk leste
-- artikkelen og formulerte forslaget, er en annen aktør, og fram til nå har den
-- bare vært en erklæring inne i `input_manifest`.
--
-- Det holder ikke lenger. ANTIDEP_CONSTITUTION.md regel 3 krever at generator,
-- kildestøttekontroll og evidensvurdering er reelt separate, håndhevet på
-- modellidentitet — og når det semantiske arbeidet flyttes ut til eksterne
-- agenter, er det nettopp de eksterne identitetene regelen må gjelde. En regel
-- som måtte grave i et JSON-felt for å finne dem, ville vært en regel ingen
-- constraint kunne håndheve.
--
-- `semantic_*` er derfor egne kolonner på kjøringen: leverandøren, modellen,
-- versjonen og eksponeringsgraden til den eksterne agenten som produserte
-- innholdet kjøringen registrerer. NULL betyr at ingen ekstern modell var
-- involvert — at leddet er Antideps egen deterministiske kontroll — og det er en
-- reell tilstand, ikke et hull.
--
-- ----------------------------------------------------------------------------
-- 3. Registeret får en kapasitet
--
-- `provenance.role_model_assignments` har hittil svart på ett spørsmål: hvilken
-- modellidentitet handler denne rollen som? Nå er det to spørsmål med hvert sitt
-- svar:
--
--   registration  hvilken kode som skriver raden (Antideps egen, deterministisk)
--   semantic      hvilken ekstern KI-agent som gjør det semantiske arbeidet
--
-- `capacity` skiller dem. Regelen om at ingen to roller deler modellidentitet
-- står urørt og gjelder på tvers av begge — det er nettopp den regelen som gjør
-- at ekstraksjonsutkastet og evidensvurderingen ikke kan komme fra den samme
-- eksterne modellen.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 3, 4, 7
--   docs/DATABASE_ARCHITECTURE.md §33, §35, §50
--   docs/EVIDENCE_PIPELINE.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Vokabularene
-- ----------------------------------------------------------------------------
create type provenance.model_version_disclosure as enum ('exact', 'not_exposed');

revoke usage on type provenance.model_version_disclosure from public;

comment on type provenance.model_version_disclosure is
  'Om modellversjonen er en versjon tjenesten faktisk oppgir (exact), eller om tjenesten ikke eksponerer noen (not_exposed). Skillet er en opplysning og ikke et tomt felt: en ekstern KI-tjeneste som ikke oppgir noen intern build, skal ikke tvinges til å finne på en — en oppdiktet versjon ville sett like troverdig ut som en sann (ANTIDEP_CONSTITUTION.md regel 4).';

create type provenance.model_capacity as enum ('registration', 'semantic');

revoke usage on type provenance.model_capacity from public;

comment on type provenance.model_capacity is
  'Hva en modelltildeling handler om: registration er koden som kontrollerer og skriver raden (Antideps egen, deterministiske), semantic er den eksterne KI-agenten som gjør selve det semantiske arbeidet. To spørsmål med hvert sitt svar, og begge er premisser en kjøring må kunne leses tilbake til.';

-- Den kanoniske verdien versjonsfeltet bærer når tjenesten ikke oppgir noen.
--
-- IMMUTABLE fordi den brukes i CHECK-constraints under. Verdien står likevel
-- ordrett i hver enkelt constraint: en CHECK som kalte funksjonen, ville vært
-- avhengig av at funksjonen aldri endret seg, og en endret funksjon ville
-- stilltiende endret betydningen av rader som allerede lå der.
create function provenance.unexposed_model_version()
  returns text
  language sql
  immutable
  set search_path = ''
as $$ select 'ikke-eksponert'::text $$;

comment on function provenance.unexposed_model_version() is
  'Den kanoniske verdien provenance.agent_runs.model_version og provenance.role_model_assignments.model_version bærer når model_version_disclosure er not_exposed. Kanonisk og ikke fri tekst, fordi exclusion-regelen som hindrer at to roller deler modellidentitet, sammenligner versjonsstrengen: med én verdi er to ukjente versjoner av den samme modellen den samme identiteten, som er sant, framfor to forskjellige, som ville vært en stille svekkelse av separasjonen (ANTIDEP_CONSTITUTION.md regel 3).';

revoke execute on function provenance.unexposed_model_version() from public;

-- ----------------------------------------------------------------------------
-- 2. Kjøringen: eksponeringsgrad, og hvem som faktisk tenkte
-- ----------------------------------------------------------------------------
alter table provenance.agent_runs
  add column model_version_disclosure provenance.model_version_disclosure
    not null default 'exact',
  add column semantic_provider text,
  add column semantic_model text,
  add column semantic_model_version text,
  add column semantic_model_version_disclosure provenance.model_version_disclosure;

alter table provenance.agent_runs
  add constraint agent_runs_model_version_disclosure_check
    check ((model_version_disclosure = 'not_exposed')
           = (model_version = 'ikke-eksponert')),
  -- De fire semantiske feltene settes sammen eller ikke i det hele tatt. En
  -- leverandør uten modellnavn ville ikke vært en identitet, og et modellnavn
  -- uten eksponeringsgrad ville gjort versjonsfeltet tvetydig.
  add constraint agent_runs_semantic_model_pairing_check
    check (
      (semantic_provider is null and semantic_model is null
       and semantic_model_version is null and semantic_model_version_disclosure is null)
      or (semantic_provider is not null and semantic_model is not null
          and semantic_model_version is not null
          and semantic_model_version_disclosure is not null
          and (semantic_model_version_disclosure = 'not_exposed')
              = (semantic_model_version = 'ikke-eksponert'))
    ),
  add constraint agent_runs_semantic_provider_shape_check
    check (semantic_provider is null
           or (semantic_provider = btrim(semantic_provider)
               and length(semantic_provider) between 1 and 200)),
  add constraint agent_runs_semantic_model_shape_check
    check (semantic_model is null
           or (semantic_model = btrim(semantic_model)
               and length(semantic_model) between 1 and 200)),
  add constraint agent_runs_semantic_model_version_shape_check
    check (semantic_model_version is null
           or (semantic_model_version = btrim(semantic_model_version)
               and length(semantic_model_version) between 1 and 200));

comment on column provenance.agent_runs.model_version_disclosure is
  'Om model_version er en versjon tjenesten faktisk oppgir, eller den kanoniske «ikke-eksponert». Alle eksisterende kjøringer er exact: de er Antideps egen deterministiske kode, der versjonen er vår egen.';
comment on column provenance.agent_runs.semantic_provider is
  'Leverandøren av den eksterne KI-agenten som gjorde det semantiske arbeidet kjøringen registrerer, eller NULL når ingen ekstern modell var involvert. Egen kolonne og ikke en erklæring inne i input_manifest, fordi separasjonsregelen i ANTIDEP_CONSTITUTION.md regel 3 må kunne håndheves av en constraint — en regel som måtte grave i et JSON-felt, ville ikke vært en regel.';
comment on column provenance.agent_runs.semantic_model is
  'Det bruker- og produktvisbare modellnavnet til den eksterne KI-agenten som gjorde det semantiske arbeidet, eller NULL. Navnet er det tjenesten faktisk viser; Antidep finner ikke på et internt navn på vegne av en leverandør.';
comment on column provenance.agent_runs.semantic_model_version is
  'Den eksakte versjonen eller builden den eksterne KI-agenten oppga, eller den kanoniske «ikke-eksponert» når tjenesten ikke oppgir noen. Aldri en gjetning: en oppdiktet versjon ville sett like troverdig ut som en sann.';
comment on column provenance.agent_runs.semantic_model_version_disclosure is
  'Om semantic_model_version er en oppgitt versjon eller den kanoniske «ikke-eksponert». Settes sammen med de øvrige semantiske feltene, eller ikke i det hele tatt.';

-- Fryseren må dekke de nye premissene også. En kjøring som kunne fått en annen
-- semantisk modell i ettertid, ville sagt noe annet enn det som faktisk skjedde
-- — og det er nettopp den opplysningen separasjonsregelen hviler på.
create or replace function provenance.freeze_agent_run()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Agentkjøring %L kan ikke slettes.', old.id),
      hint = 'En kjøring dokumenterer hva som faktisk ble kjørt med hvilke premisser, og er grunnlaget for at et KI-produsert objekt kan spores bakover (DATABASE_ARCHITECTURE.md §34).';
  end if;

  if new.agent_identity_id is distinct from old.agent_identity_id
    or new.actor_id is distinct from old.actor_id
    or new.agent_role is distinct from old.agent_role
    or new.provider is distinct from old.provider
    or new.model is distinct from old.model
    or new.model_version is distinct from old.model_version
    or new.model_version_disclosure is distinct from old.model_version_disclosure
    or new.semantic_provider is distinct from old.semantic_provider
    or new.semantic_model is distinct from old.semantic_model
    or new.semantic_model_version is distinct from old.semantic_model_version
    or new.semantic_model_version_disclosure
       is distinct from old.semantic_model_version_disclosure
    or new.prompt_template_version is distinct from old.prompt_template_version
    or new.pipeline_version is distinct from old.pipeline_version
    or new.input_manifest is distinct from old.input_manifest
    or new.started_at is distinct from old.started_at
    or new.created_at is distinct from old.created_at
  then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Premissene for agentkjøring %L er uforanderlige og kan ikke endres.', old.id
      ),
      hint = 'Registrer en ny kjøring dersom operasjonen skal kjøres om igjen med andre premisser. En kjøring som kunne omskrives i ettertid, ville ikke dokumentert noe.';
  end if;

  -- Én overgang, én vei. En kjøring som kunne gjenåpnes, ville kunnet
  -- produsere objekter etter at den var rapportert ferdig.
  if old.status <> 'running' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Agentkjøring %L er avsluttet med statusen %L og kan ikke endres.', old.id, old.status
      ),
      hint = 'En avsluttet kjøring er endelig. Registrer en ny kjøring for et nytt forsøk.';
  end if;

  if new.status = 'running' then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Agentkjøring %L kan bare endres ved å avsluttes.', old.id),
      hint = 'Sett status til succeeded, failed eller aborted sammen med completed_at.';
  end if;

  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. Registeret: kapasitet og eksponeringsgrad
-- ----------------------------------------------------------------------------
alter table provenance.role_model_assignments
  add column capacity provenance.model_capacity not null default 'registration',
  add column model_version_disclosure provenance.model_version_disclosure
    not null default 'exact';

alter table provenance.role_model_assignments
  add constraint role_model_assignments_model_version_disclosure_check
    check ((model_version_disclosure = 'not_exposed')
           = (model_version = 'ikke-eksponert'));

comment on column provenance.role_model_assignments.capacity is
  'Hva tildelingen handler om: registration er Antideps egen deterministiske kode som kontrollerer og skriver raden, semantic er den eksterne KI-agenten som gjør selve det semantiske arbeidet. En rolle har høyst én gyldig tildeling i hver kapasitet om gangen; regelen om at ingen to roller deler modellidentitet gjelder på tvers av begge, og det er den regelen som gjør at ekstraksjonsutkastet og evidensvurderingen ikke kan komme fra den samme eksterne modellen (ANTIDEP_CONSTITUTION.md regel 3).';
comment on column provenance.role_model_assignments.model_version_disclosure is
  'Om model_version er en versjon tjenesten faktisk oppgir, eller den kanoniske «ikke-eksponert». En ekstern tjeneste som ikke eksponerer noen intern build, registreres som not_exposed framfor med en oppdiktet versjon.';

-- Én gyldig tildeling per rolle *og kapasitet*. Uten kapasiteten i regelen
-- kunne en rolle ikke hatt både en registreringsidentitet og en semantisk
-- identitet samtidig — og det er nettopp det den skal ha.
alter table provenance.role_model_assignments
  drop constraint role_model_assignments_one_per_role_excl;

alter table provenance.role_model_assignments
  add constraint role_model_assignments_one_per_role_capacity_excl
    exclude using gist (agent_role with =, capacity with =, validity with &&);

-- Fryseren dekker de to nye kolonnene av samme grunn som de øvrige: hvilken
-- kapasitet en tildeling gjaldt, og om versjonen var oppgitt eller ikke, er
-- historiske fakta kjøringene i perioden hviler på.
create or replace function provenance.freeze_role_model_assignment()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.agent_role is distinct from old.agent_role
     or new.capacity is distinct from old.capacity
     or new.provider is distinct from old.provider
     or new.model is distinct from old.model
     or new.model_version is distinct from old.model_version
     or new.model_version_disclosure is distinct from old.model_version_disclosure
     or new.valid_from is distinct from old.valid_from
     or new.registered_by_actor_id is distinct from old.registered_by_actor_id
     or new.reason is distinct from old.reason
     or new.created_at is distinct from old.created_at
     or new.id is distinct from old.id then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En modelltildeling er uforanderlig bortsett fra at den kan avsluttes.',
      hint = 'Hvilken modell en rolle handlet som i en periode, er et historisk faktum kjøringene i perioden hviler på. Sett valid_to og registrer en ny tildeling for den nye modellen; en omskriving ville gjort de gamle kjøringene uforklarlige (ANTIDEP_CONSTITUTION.md regel 3, 7).';
  end if;

  if old.valid_to is not null
     and (new.valid_to is distinct from old.valid_to
          or new.closed_by_actor_id is distinct from old.closed_by_actor_id
          or new.close_reason is distinct from old.close_reason) then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En avsluttet modelltildeling kan ikke avsluttes på nytt eller gjenåpnes.',
      hint = 'Avslutningen er selv et historisk faktum. En gjenåpning er en ny tildeling.';
  end if;

  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Oppslagene, ett per kapasitet
-- ----------------------------------------------------------------------------
create or replace function provenance.current_role_model(p_agent_role provenance.agent_role)
  returns provenance.role_model_assignments
  language sql
  stable
  set search_path = ''
as $$
  select a.*
  from provenance.role_model_assignments a
  where a.agent_role = p_agent_role
    and a.capacity = 'registration'
    and a.valid_from <= statement_timestamp()
    and (a.valid_to is null or a.valid_to > statement_timestamp())
  limit 1;
$$;

comment on function provenance.current_role_model(provenance.agent_role) is
  'Registreringstildelingen som gjelder for rollen akkurat nå, eller ingen rad. Filtrerer på capacity = registration: det er premissene api.begin_agent_run kontrollerer, altså hvilken kode som skriver raden. Den eksterne KI-agenten som gjorde det semantiske arbeidet, slås opp med provenance.current_semantic_model(provenance.agent_role). Gyldighet måles med statement_timestamp() og ikke med transaksjonens starttidspunkt, slik at en avsluttet tildeling virker umiddelbart. Exclusion-regelen garanterer at det finnes høyst én.';

create function provenance.current_semantic_model(p_agent_role provenance.agent_role)
  returns provenance.role_model_assignments
  language sql
  stable
  set search_path = ''
as $$
  select a.*
  from provenance.role_model_assignments a
  where a.agent_role = p_agent_role
    and a.capacity = 'semantic'
    and a.valid_from <= statement_timestamp()
    and (a.valid_to is null or a.valid_to > statement_timestamp())
  limit 1;
$$;

comment on function provenance.current_semantic_model(provenance.agent_role) is
  'Den eksterne KI-agenten rollen er registrert med for det semantiske arbeidet akkurat nå, eller ingen rad. Ingen rad er en reell tilstand og ikke en feil i seg selv: en rolle uten registrert semantisk modell kan ikke ta imot et eksternt agentsvar, og det er riktig utfall — alternativet ville vært å ta imot et svar fra en modell ingen har tatt stilling til (ANTIDEP_CONSTITUTION.md regel 3).';

revoke execute on function provenance.current_semantic_model(provenance.agent_role) from public;

-- ----------------------------------------------------------------------------
-- 5. Kjøringen registreres med den eksponeringsgraden registeret oppgir
--
-- Signaturen er uendret, så `create or replace`: da står grantene, og PostgREST
-- får ingen overload å velge mellom.
-- ----------------------------------------------------------------------------
create or replace function api.begin_agent_run(
  p_identity_key text,
  p_secret text,
  p_agent_role text,
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
  v_role provenance.agent_role;
  v_identity_id uuid;
  v_actor_id uuid;
  v_run_id uuid;
  v_assignment provenance.role_model_assignments;
begin
  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role),
        hint = 'Gyldige roller er de eksplisitte agentrollene i ANTIDEP_CONSTITUTION.md §10 og EVIDENCE_PIPELINE.md §61.';
  end;

  v_identity_id := provenance.authenticate_agent_identity(p_identity_key, p_secret, v_role);

  v_assignment := provenance.current_role_model(v_role);
  if v_assignment.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig modelltildeling.', p_agent_role),
      hint = 'Hvilken modell en rolle handler som, er en registrert avgjørelse i provenance.role_model_assignments, ikke en verdi kalleren oppgir. En kjøring uten den ville hatt premisser ingen har tatt stilling til.';
  end if;

  if p_provider is distinct from v_assignment.provider
     or p_model is distinct from v_assignment.model
     or p_model_version is distinct from v_assignment.model_version then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Rollen %L er registrert med modellidentiteten %L/%L/%L, men kjøringen oppgir %L/%L/%L.',
        p_agent_role, v_assignment.provider, v_assignment.model, v_assignment.model_version,
        p_provider, p_model, p_model_version
      ),
      hint = 'Modellidentiteten er registeret sitt svar, ikke kallerens. Uten den regelen kunne to ledd i kjeden oppgitt den samme modellen, og separasjonen mellom generator, kildestøttekontroll og evidensvurdering ville vært et navn framfor en grense (ANTIDEP_CONSTITUTION.md regel 3). Promptmalversjon og pipelineversjon er fortsatt frie.';
  end if;

  select ai.actor_id into v_actor_id
  from provenance.agent_identities ai
  where ai.id = v_identity_id;

  insert into provenance.agent_runs (
    agent_identity_id, actor_id, agent_role,
    provider, model, model_version, model_version_disclosure,
    prompt_template_version, pipeline_version,
    status, input_manifest, input_source_version_id
  )
  values (
    v_identity_id, v_actor_id, v_role,
    p_provider, p_model, p_model_version, v_assignment.model_version_disclosure,
    p_prompt_template_version, p_pipeline_version,
    'running', p_input_manifest, p_input_source_version_id
  )
  returning id into v_run_id;

  return v_run_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. Forbudet mot egenverifikasjon gjelder også den semantiske identiteten
--
-- Fram til nå sammenlignet kontrollen bare de tre feltene på kjøringen, som for
-- Antideps egne ledd er registreringsidentiteten. Den er per rolle og alltid
-- forskjellig, så regelen var sann og samtidig uten kraft mot det den nå skal
-- fange: at det samme *eksterne* modellsvaret ligger bak både innholdet og
-- kontrollen av det.
-- ----------------------------------------------------------------------------
create or replace function provenance.assert_distinct_model_identity(
  p_checking_run_id uuid,
  p_checked_run_id uuid,
  p_what text
)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_same boolean;
  v_same_semantic boolean;
  v_semantic text;
begin
  if p_checking_run_id is null or p_checked_run_id is null then
    -- Et menneskes registrering har ingen kjøring, og et objekt laget av et
    -- menneske har det heller ikke. Fraværet er ikke et sammenfall.
    return;
  end if;

  select a.provider = b.provider
     and a.model = b.model
     and a.model_version = b.model_version,
       a.semantic_provider is not null
     and a.semantic_provider = b.semantic_provider
     and a.semantic_model = b.semantic_model
     and a.semantic_model_version = b.semantic_model_version,
       format('%s/%s/%s', a.semantic_provider, a.semantic_model, a.semantic_model_version)
    into v_same, v_same_semantic, v_semantic
  from provenance.agent_runs a, provenance.agent_runs b
  where a.id = p_checking_run_id and b.id = p_checked_run_id;

  if coalesce(v_same, false) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        '%s ble gjort av den samme modellidentiteten som laget det som kontrolleres.',
        p_what
      ),
      hint = 'Generator, kildestøttekontroll og evidensvurdering er separate roller, og egenverifikasjon er forbudt (ANTIDEP_CONSTITUTION.md regel 3). En kontroll utført av den samme modellen som produserte innholdet, er ikke en uavhengig kontroll — den er den samme vurderingen gjort to ganger.';
  end if;

  if coalesce(v_same_semantic, false) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        '%s hviler på det samme eksterne modellsvaret (%s) som laget det som kontrolleres.',
        p_what, v_semantic
      ),
      hint = 'Det semantiske arbeidet bak de to leddene kom fra den samme eksterne KI-agenten. Bruk en annen modell du allerede har tilgang til for det uavhengige leddet; finnes det ingen, skal kjeden stoppe framfor å registrere en kontroll som ikke er uavhengig (ANTIDEP_CONSTITUTION.md regel 3, 4).';
  end if;
end;
$$;

comment on function provenance.assert_distinct_model_identity(uuid, uuid, text) is
  'Avviser en kontroll utført av den samme modellidentiteten som produserte det kontrollerte (ANTIDEP_CONSTITUTION.md regel 3). Sammenligner to identiteter per kjøring: registreringsidentiteten, som er koden som skrev raden, og den semantiske identiteten, som er den eksterne KI-agenten som gjorde arbeidet. Den andre er den som betyr noe når det semantiske arbeidet utføres av eksterne agenter: registreringsidentiteten er per rolle og dermed alltid forskjellig, mens to roller godt kunne fått sitt innhold fra det samme ChatGPT-svaret. NULL på en av sidene er ikke et sammenfall: et menneskes registrering har ingen agentkjøring, og en kjøring uten semantisk modell er Antideps egen deterministiske kontroll.';
