-- ============================================================================
-- Migrasjon 012a — arbeidet blir forståelig, og teknikken blir Antideps eget
--
-- Fram til nå har den operative flaten bedt et menneske om å gjøre teknisk
-- arbeid: velge KI-tjeneste for et agentledd, registrere en «kjører», hente en
-- tilkoblingskode, laste ned en oppgavefil og laste opp et svar. Ingen av
-- delene er klinisk eller redaksjonelt arbeid, og ingen av dem er noe en
-- kliniker skal måtte forstå. Samtidig hadde Antidep ingen måte å si
-- «jeg venter på artikkelen» på: en manglende fulltekst var ikke en tilstand,
-- bare fravær av en rad.
--
-- Denne migrasjonen flytter grensen. Det et menneske gjør, er å velge riktig
-- PDF til en artikkel Antidep sier den mangler. Alt annet — bindingen,
-- identitetskontrollen, lesbarhetskontrollen, det registrerte tekstuttrekket,
-- registreringen og kølegging av neste ledd — er Antideps eget arbeid.
--
-- ----------------------------------------------------------------------------
-- Fire nye tilstander, og ikke én ny skrivevei
--
--   workflow.full_text_requests   hvilke artikler Antidep faktisk mangler, med
--                                 den redaksjonelle avgrensningen som gjelder
--   workflow.full_text_intake     én opplastet fil på vei gjennom kontrollene
--   workflow.technical_incidents  tekniske problemer, med rå diagnose privat
--   workflow.technical_incident_events  append-only spor over det samme
--
-- Ingen av dem er en ny faglig skrivevei. Fullteksten registreres fortsatt av
-- nøyaktig den transaksjonen migrasjon 009a skrev; den er bare løftet ut i
-- workflow.register_full_text_document(uuid, uuid, bytea, timestamptz, text, text, text, text, text, text, text) slik at både den gamle
-- api.upload_full_text_document(uuid, timestamptz, text, text, text, text, text, text, text, text) og innboksen deler den. En andre
-- skrivevei ville vært en andre kontroll å glemme (AGENTS.md).
--
-- ----------------------------------------------------------------------------
-- Hvorfor tekstuttrekket ikke skjer i nettleseren
--
-- Den registrerte oppskriften er `pdftotext` med en låst argumentliste og
-- Antideps egen leserekkefølge (migrasjon 003f, 003g). Oppskriften kjøres på
-- nytt ved hver etterprøving, og en nettleser kan ikke kjøre den. Å registrere
-- en *annen* oppskrift for nettleserveien ville gjort fullteksten uprøvbar
-- mot det som faktisk ble kjørt, og dermed svekket ANTIDEP_CONSTITUTION.md
-- regel 1 og 2.
--
-- Filen blir derfor liggende i innboksen til Antideps egen tekniske arbeider
-- henter den, kjører den registrerte oppskriften og leverer teksten tilbake.
-- For den som lastet opp, er dette usynlig: oppgaven står som «pågår» til den
-- er registrert. Ventingen er Antideps, ikke klinikerens.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en manglende artikkel ikke er en teknisk feil
--
-- «Venter på fulltekst» er en normal arbeidsblokkering: kjeden kan ikke gå
-- videre, men ingenting er i stykker. En mislykket automatisk prosess er noe
-- annet. De to holdes fra hverandre i modellen og ikke bare i ordlyden:
-- forespørselen er en rad i workflow.full_text_requests, mens et teknisk
-- problem er en rad i workflow.technical_incidents. Ingen flate kan derfor
-- blande dem (ANTIDEP_CONSTITUTION.md regel 4).
--
-- ----------------------------------------------------------------------------
-- Og hvorfor en teknisk feil heller ikke blir en menneskeoppgave
--
-- Den motsatte forvekslingen er like alvorlig. Hvis Antidep ikke får kjørt
-- tekstuttrekket fordi verktøyet mangler på maskinen som skal kjøre det, er det
-- driften som står — ikke filen som er feil. En innboks som svarte «last opp
-- fullteksten» på det, ville bedt et menneske om å rette et driftsproblem det
-- verken kan se eller gjøre noe med.
--
-- Innboksraden har derfor tilstanden `blocked`: filen blir liggende, ingenting
-- avsluttes, og api.resume_blocked_full_text_extractions() setter alt i gang
-- igjen i det driften svarer. Først når det registrerte tekstuttrekket faktisk
-- har kjørt på filen tre ganger uten å få brukbar tekst ut av den, er det en
-- opplysning om filen — og da, og bare da, ber innboksen om en annen utgave.
--
-- ----------------------------------------------------------------------------
-- Hvorfor det åpne dashboardet ikke bærer en eneste intern verdi
--
-- api.public_work_board() er den ene funksjonen `anon` får, og den svarer med
-- et lukket produktvokabular: hva slags arbeid det er, hvilken tilstand det
-- står i, hvilke virkestoff det gjelder, og en ugjennomsiktig referanse som
-- ikke er noen rads id. Ingen agentrolle, ingen modell, ingen kjører, ingen
-- jobbnøkkel, ingen artikkeltittel og ingen feiltekst forlater databasen der.
-- Referansen er et avtrykk av raden og ikke raden selv, slik at den kan brukes
-- som et håndtak uten å være en nøkkel noen kan gjette seg til.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 1, 2, 4, 7
--   docs/DATABASE_ARCHITECTURE.md §33, §43, §44, §48, §50
--   docs/EVIDENCE_PIPELINE.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Admin-mandatet
--
-- `workflow.app_role` har hatt 'admin' siden migrasjon 001, men ingen kontroll
-- har lest den. Den tekniske problemoversikten er den første flaten som hører
-- til nettopp den rollen: den handler om driften av Antidep og ikke om
-- innholdet, og en redaktør skal ikke måtte forholde seg til den.
--
-- Formen er den samme som knowledge.assert_editor_authorized(uuid): aktøren
-- må finnes og ikke være trukket tilbake, og rollen leses av
-- workflow.user_roles på kallets eget tidspunkt — aldri av en JWT-claim
-- (DATABASE_ARCHITECTURE.md §46).
-- ----------------------------------------------------------------------------
-- Rolleoppslaget for seg, fordi tre kontroller trenger det og et fjerde sted å
-- gjenta tidsvinduet ville vært et fjerde sted å skrive det feil.
create function workflow.has_app_role(p_role workflow.app_role)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select exists (
    select 1
    from workflow.user_roles ur
    where ur.user_id = auth.uid()
      and ur.role_code = p_role
      and ur.valid_from <= statement_timestamp()
      and (ur.valid_to is null or ur.valid_to > statement_timestamp())
  );
$$;

comment on function workflow.has_app_role(workflow.app_role) is
  'Om den innloggede brukeren har en gyldig, uavgrenset eller avgrenset tildeling av rollen akkurat nå. Leser workflow.user_roles og aldri en JWT-claim (DATABASE_ARCHITECTURE.md §46), og bruker statement_timestamp() slik at en tilbakekalling virker umiddelbart. Svarer på hva kalleren HAR; hva kalleren KAN, avgjøres av den kontrollen som spør.';

revoke execute on function workflow.has_app_role(workflow.app_role) from public;

-- Aktøren for seg, i to former. Den stille formen finnes fordi én lesevei
-- svarer «ikke synlig» framfor å avvise (api.technical_problem_summary()), og
-- den skal ha nøyaktig den samme grensen som den som avviser — ikke en svakere.
-- Uten en delt kontroll ville de to grensene før eller siden glidd fra
-- hverandre, og den svakeste ville vært den som lakk.
create function workflow.active_actor_id()
  returns uuid
  language sql
  stable
  set search_path = ''
as $$
  select a.id
  from provenance.actors a
  where a.auth_user_id = auth.uid() and a.retired_at is null;
$$;

comment on function workflow.active_actor_id() is
  'Aktøren den innloggede brukeren er, når den finnes og ikke er trukket tilbake — ellers null. Den stille formen av workflow.assert_active_actor(), til den ene leseveien som svarer «ikke synlig» framfor å avvise. Samme grense, uttrykt én gang.';

revoke execute on function workflow.active_actor_id() from public;

create function workflow.assert_active_actor()
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_retired_at timestamptz;
begin
  select a.id, a.retired_at into v_actor_id, v_retired_at
  from provenance.actors a
  where a.auth_user_id = auth.uid();

  if v_actor_id is null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kontoen din er ikke knyttet til en aktør i Antidep.';
  end if;

  if v_retired_at is not null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Aktøren er trukket tilbake.';
  end if;

  return v_actor_id;
end;
$$;

comment on function workflow.assert_active_actor() is
  'Kontrollerer at den innloggede brukeren er en registrert, ikke-tilbaketrukket aktør, og returnerer aktørens id. Sier ingenting om hva aktøren KAN — det avgjør den kontrollen som spør. Finnes for at aktørgrensen skal stå ett sted: to kopier ville før eller siden vært to forskjellige grenser.';

revoke execute on function workflow.assert_active_actor() from public;

create function workflow.assert_admin_authorized()
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_actor_id uuid := workflow.assert_active_actor();
begin
  if not workflow.has_app_role('admin') then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Brukeren har ikke gyldig admin-rolle.';
  end if;

  return v_actor_id;
end;
$$;

comment on function workflow.assert_admin_authorized() is
  'Kontrollerer at den innloggede brukeren har en registrert, ikke-tilbaketrukket aktør og en gyldig admin-rolle på kallets eget tidspunkt, og returnerer aktørens id. Admin er driftsrollen: den tekniske problemoversikten hører til den, og ingenting i det kliniske eller redaksjonelle innholdet gjør det.';

revoke execute on function workflow.assert_admin_authorized() from public;

-- Fulltekstinnboksen er redaktørens arbeid, og admin skal komme til den uten å
-- måtte be om en redaktørtildeling for å gjøre en driftsoppgave. Kontrollen er
-- derfor «editor eller admin», og den returnerer aktøren fordi alt som skrives
-- videre, attribueres til den.
create function workflow.assert_full_text_inbox_authorized()
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_actor_id uuid := workflow.assert_active_actor();
begin
  if not (workflow.has_app_role('editor') or workflow.has_app_role('admin')) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Brukeren har ikke gyldig editor- eller admin-rolle.';
  end if;

  return v_actor_id;
end;
$$;

comment on function workflow.assert_full_text_inbox_authorized() is
  'Mandatet for fulltekstinnboksen: en registrert, ikke-tilbaketrukket aktør med gyldig editor- eller admin-rolle. Editor fordi det å avgjøre hvilken artikkel som er riktig, er redaksjonelt arbeid; admin fordi den samme innboksen er stedet en drift kan se at Antidep står og venter. Returnerer aktørens id, som alt videre attribueres til.';

revoke execute on function workflow.assert_full_text_inbox_authorized() from public;

-- ============================================================================
-- 1. Tekniske problemer
--
-- Et teknisk problem er noe som er i stykker: en automatisk oppgave som stoppet,
-- en tilkobling som ikke svarer, en brukerflate som ikke fikk lest det den
-- skulle. Det er *ikke* en faglig blokkering. «Venter på fulltekst» hører
-- hjemme i arbeidsoversikten og aldri her (ANTIDEP_CONSTITUTION.md regel 4).
--
-- Raden bærer to helt forskjellige ting, og de har hver sin vei ut:
--
--   området og tidspunktene   det en ikke-teknisk admin trenger, og det eneste
--                             api.technical_problem_board() svarer med
--   diagnosen                 den rå årsaken, som aldri forlater databasen
--                             gjennom noe api-objekt
--
-- Diagnosen er Antideps egen setning og aldri en videreformidlet feiltekst fra
-- en kilde, en modell eller en nettleser — samme regel som
-- workflow.agent_runner_events.note bærer. En flate som fikk skrive fritekst
-- hit, ville gjort loggen til et sted privat innhold samler seg.
-- ============================================================================
-- ----------------------------------------------------------------------------
-- Referansen flatene peker med
--
-- Alt en brukerflate viser fram, skal kunne pekes på uten at en intern id står
-- på skjermen (issue #99). Verdien er tilfeldig og ikke utledet av raden:
-- et avtrykk av id-en ville vært regnbart begge veier for den som kjenner
-- id-en, og en generert kolonne kan uansett ikke kalle noe som ikke er
-- immutable.
-- ----------------------------------------------------------------------------
create function workflow.new_public_reference()
  returns text
  language sql
  volatile
  set search_path = ''
as $$
  select replace(gen_random_uuid()::text, '-', '')
$$;

comment on function workflow.new_public_reference() is
  'Et nytt, ugjennomsiktig håndtak på 32 heksadesimale tegn fra databasens egen tilfeldighetskilde. Brukes som referanse i alt en brukerflate viser, slik at ingen intern id trenger å forlate databasen — og slik at en referanse ikke kan regnes tilbake til raden den peker på.';

revoke execute on function workflow.new_public_reference() from public;

create type workflow.technical_area as enum (
  'work_queue',
  'automatic_task',
  'agent_service',
  'full_text_intake',
  'clinical_content'
);

revoke usage on type workflow.technical_area from public;

comment on type workflow.technical_area is
  'Hvilket område av Antidep et teknisk problem gjelder, i et lukket produktvokabular en ikke-teknisk admin kan lese: work_queue = arbeidsoversikten kan ikke leses, automatic_task = en automatisk oppgave har stoppet, agent_service = tilkoblingen til agenttjenesten virker ikke, full_text_intake = en opplastet fulltekst kunne ikke behandles, clinical_content = klinikerinnholdet kunne ikke vises. Vokabularet er lukket fordi flaten oversetter det til norsk: en ny verdi skal tvinge fram en ny setning framfor å lekke et internt navn.';

create type workflow.technical_incident_transition as enum ('opened', 'seen', 'resolved');

revoke usage on type workflow.technical_incident_transition from public;

comment on type workflow.technical_incident_transition is
  'Overgangen et spor beskriver: opened (problemet oppsto, eller oppsto på nytt etter å ha vært løst), seen (det samme problemet ble observert igjen mens det fortsatt pågikk) eller resolved (det gikk over). Skillet mellom opened og seen er hele grunnen til at sporet finnes: uten det kunne ingen svare på om et problem har kommet tilbake.';

create table workflow.technical_incidents (
  id uuid primary key default gen_random_uuid(),

  -- Håndtaket flaten bruker. En egen, tilfeldig verdi og ikke radens id: en
  -- admin skal kunne peke på et problem uten at en intern id står på skjermen,
  -- og en referanse skal verken kunne gjettes eller regnes tilbake til noe.
  reference text not null default workflow.new_public_reference(),

  area workflow.technical_area not null,
  -- Dedupliseringsnøkkelen innenfor området: hvilken jobb, hvilken tilkobling,
  -- eller «client» for en selvmelding fra en brukerflate. To observasjoner av
  -- det samme problemet skal være én rad med en teller, ikke to rader.
  signature text not null,

  -- Om raden ble skrevet AV operasjonen den handler om, eller meldt av en
  -- flate som ikke kunne skrive sitt eget spor. Samme skille som
  -- workflow.agent_runner_events.self_reported, og av samme grunn: den ene
  -- sier hva databasen SÅ, den andre hva en klient SA.
  self_reported boolean not null default false,

  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  occurrence_count integer not null default 1,
  resolved_at timestamptz,

  -- Den rå årsaken. Antideps egen setning, aldri en videreformidlet feiltekst.
  -- Ingen api-objekt leser denne kolonnen.
  diagnosis text not null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint technical_incidents_area_signature_key unique (area, signature),
  constraint technical_incidents_reference_key unique (reference),
  constraint technical_incidents_signature_shape_check
    check (signature = btrim(signature) and length(signature) between 1 and 200),
  constraint technical_incidents_diagnosis_shape_check
    check (diagnosis = btrim(diagnosis) and length(diagnosis) between 1 and 4000),
  constraint technical_incidents_occurrence_check check (occurrence_count >= 1),
  constraint technical_incidents_seen_order_check check (last_seen_at >= first_seen_at),
  constraint technical_incidents_resolved_order_check
    check (resolved_at is null or resolved_at >= first_seen_at)
);

comment on table workflow.technical_incidents is
  'Tekniske problemer i Antidep, med den rå diagnosen privat (ANTIDEP_CONSTITUTION.md regel 4, 7). Én rad per (område, signatur), slik at det samme problemet observert ti ganger er én rad med en teller framfor ti rader. Tabellen har RLS med default deny, ingen grants og ingen policy: den eneste veien ut er api.technical_problem_board(), som svarer med område og tidspunkt og aldri med diagnosen. Et teknisk problem er ikke det samme som en faglig blokkering — «venter på fulltekst» er workflow.full_text_requests og hører ikke hjemme her.';
comment on column workflow.technical_incidents.reference is
  'Ugjennomsiktig håndtak til flaten, fra databasens egen tilfeldighetskilde (workflow.new_public_reference()). Finnes for at en admin skal kunne peke på et problem uten at en intern id står på skjermen — og verdien er tilfeldig og ikke utledet av raden, slik at den ikke kan regnes tilbake til id-en den peker på.';
comment on column workflow.technical_incidents.diagnosis is
  'Den rå årsaken, til Claude Code og ChatGPT. Antideps egen setning og aldri en videreformidlet feiltekst fra en kilde, en modell eller en nettleser — samme regel som workflow.agent_runner_events.note bærer. Ingen api-objekt leser kolonnen.';
comment on column workflow.technical_incidents.self_reported is
  'false: raden ble skrevet av operasjonen den handler om, i den samme transaksjonen, og er autoritativ. true: en brukerflate meldte fra om et kall som ikke kunne skrive sitt eget spor, og raden sier hva klienten SA. En senere autoritativ observasjon av det samme problemet setter den til false.';

alter table workflow.technical_incidents enable row level security;

create index technical_incidents_unresolved_idx
  on workflow.technical_incidents (area, last_seen_at desc)
  where resolved_at is null;

create trigger technical_incidents_set_row_timestamps
  before insert or update on workflow.technical_incidents
  for each row execute function catalog.set_row_timestamps();

create table workflow.technical_incident_events (
  id uuid primary key default gen_random_uuid(),

  technical_incident_id uuid not null
    references workflow.technical_incidents (id) on update restrict on delete restrict,
  transition workflow.technical_incident_transition not null,
  -- Diagnosen slik den var akkurat da. Tilstandsraden bærer bare den siste, og
  -- den som skal finne ut hva som faktisk skjedde, trenger den forrige også:
  -- «samme område, men en annen kode hver gang» er et helt annet problem enn
  -- «samme kode femti ganger».
  diagnosis text,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint technical_incident_events_diagnosis_shape_check
    check ((diagnosis is null) = (transition = 'resolved'))
);

comment on table workflow.technical_incident_events is
  'Append-only spor over hver overgang på et teknisk problem (DATABASE_ARCHITECTURE.md §33). Selve problemet er tilstand og endres; overgangene er historikk og overskrives ikke. Uten sporet ville «har dette kommet tilbake» vært ubesvarlig så snart raden var oppdatert. Hver observasjon bærer sin egen diagnose, slik at rekken av dem er lesbar for en teknisk agent lenge etter at tilstandsraden er skrevet over.';
comment on column workflow.technical_incident_events.diagnosis is
  'Antideps egen setning om denne ene observasjonen, med de maskinidentifikatorene som fantes. Aldri en videreformidlet feiltekst. Null for overgangen resolved, som ikke er en observasjon av noe galt.';

alter table workflow.technical_incident_events enable row level security;

create index technical_incident_events_incident_idx
  on workflow.technical_incident_events (technical_incident_id, occurred_at);

create trigger technical_incident_events_set_created_at
  before insert on workflow.technical_incident_events
  for each row execute function catalog.set_created_at();

create trigger technical_incident_events_are_append_only
  before update or delete on workflow.technical_incident_events
  for each row execute function knowledge.reject_append_only_mutation(
    'Et hendelsesspor sier hva som faktisk skjedde. En ny overgang er en ny rad.'
  );

-- ----------------------------------------------------------------------------
-- Skriveren
--
-- Én funksjon, kalt av hver vei som oppdager noe teknisk galt, framfor like
-- mange steder å glemme sporet. Den er ikke SECURITY DEFINER: den kalles alltid
-- fra innsiden av en funksjon som allerede har kontrollert kalleren.
-- ----------------------------------------------------------------------------
create function workflow.record_technical_incident(
  p_area workflow.technical_area,
  p_signature text,
  p_diagnosis text,
  p_self_reported boolean default false
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_row workflow.technical_incidents;
  v_transition workflow.technical_incident_transition;
begin
  select ti.* into v_row
  from workflow.technical_incidents ti
  where ti.area = p_area and ti.signature = p_signature
  for update;

  if v_row.id is null then
    begin
      insert into workflow.technical_incidents (area, signature, diagnosis, self_reported)
      values (p_area, p_signature, p_diagnosis, p_self_reported)
      returning * into v_row;
      v_transition := 'opened';
    exception
      -- To samtidige observasjoner av det samme problemet er fortsatt ett
      -- problem. Den som taper kappløpet, teller opp raden som vant.
      when unique_violation then
        select ti.* into v_row
        from workflow.technical_incidents ti
        where ti.area = p_area and ti.signature = p_signature
        for update;
        v_transition := null;
    end;
  end if;

  if v_transition is null then
    -- En episode hjerteslaget allerede har erklært over, avsluttes her — før
    -- den nye observasjonen gjenbruker raden.
    --
    -- Uten dette ville lukkingen hengt på at en admin tilfeldigvis åpnet
    -- oversikten: kom den samme svikten tilbake etter en stille periode, ville
    -- raden fortsatt hatt resolved_at null, og sporet ville fått en `seen`
    -- framfor en `resolved` og en ny `opened`. Historikken ville da vist én
    -- sammenhengende episode over et tidsrom der problemet ikke pågikk.
    if v_row.resolved_at is null and not workflow.technical_incident_ongoing(v_row) then
      update workflow.technical_incidents ti
      set resolved_at = v_row.last_seen_at
      where ti.id = v_row.id;

      insert into workflow.technical_incident_events (technical_incident_id, transition)
      values (v_row.id, 'resolved');

      v_row.resolved_at := v_row.last_seen_at;
    end if;

    v_transition := case when v_row.resolved_at is null then 'seen' else 'opened' end;

    update workflow.technical_incidents ti
    set last_seen_at = now(),
        -- En ny episode teller fra sin egen begynnelse. «Oppsto» og «sist sett»
        -- skal beskrive det som pågår nå: en rad som spente over en stille
        -- periode, ville sagt at problemet hadde vart hele tiden. Hele
        -- forløpet, alle episodene, står i det append-only sporet.
        first_seen_at = case when v_transition = 'opened' then now() else ti.first_seen_at end,
        occurrence_count = case when v_transition = 'opened' then 1
                                else ti.occurrence_count + 1 end,
        resolved_at = null,
        diagnosis = p_diagnosis,
        -- En autoritativ observasjon av det samme problemet gjør raden
        -- autoritativ. Den motsatte veien finnes ikke: en selvmelding kan ikke
        -- gjøre en rad databasen selv skrev, til noe noen bare har påstått.
        self_reported = ti.self_reported and p_self_reported
    where ti.id = v_row.id;
  end if;

  insert into workflow.technical_incident_events (technical_incident_id, transition, diagnosis)
  values (v_row.id, v_transition, p_diagnosis);

  return v_row.id;
end;
$$;

comment on function workflow.record_technical_incident(workflow.technical_area, text, text, boolean) is
  'Registrerer at noe teknisk er galt, eller at det samme problemet er observert igjen. Idempotent på (område, signatur): det samme problemet blir én rad med en teller, og et problem som var løst, åpnes på nytt med sporet opened framfor seen. En selvmeldt episode hjerteslaget allerede har erklært over, avsluttes her — før den nye observasjonen gjenbruker raden — slik at lukkingen ikke henger på at en admin tilfeldigvis åpner oversikten, og slik at sporet får både resolved og en ny opened. En ny episode teller fra sin egen begynnelse: «oppsto» og antallet beskriver det som pågår nå, mens hele forløpet står i workflow.technical_incident_events. Diagnosen er Antideps egen setning og lagres privat — på tilstandsraden som den siste, og på sporet som denne ene observasjonen, slik at rekken av dem er lesbar senere. Kalles fra innsiden av en funksjon som allerede har kontrollert kalleren, og er derfor ikke SECURITY DEFINER.';

revoke execute on function workflow.record_technical_incident(workflow.technical_area, text, text, boolean) from public;

create function workflow.resolve_technical_incident(
  p_area workflow.technical_area,
  p_signature text
)
  returns boolean
  language plpgsql
  set search_path = ''
as $$
declare
  v_id uuid;
begin
  update workflow.technical_incidents ti
  set resolved_at = now()
  where ti.area = p_area and ti.signature = p_signature and ti.resolved_at is null
  returning ti.id into v_id;

  if v_id is null then
    return false;
  end if;

  insert into workflow.technical_incident_events (technical_incident_id, transition)
  values (v_id, 'resolved');
  return true;
end;
$$;

comment on function workflow.resolve_technical_incident(workflow.technical_area, text) is
  'Merker et teknisk problem som løst, og etterlater sporet resolved. Sletter ingenting: en rad som var et problem, blir stående med hele historikken sin, slik at «hvor ofte skjer dette» kan besvares. Svarer false når det ikke var noe uløst problem å lukke.';

revoke execute on function workflow.resolve_technical_incident(workflow.technical_area, text) from public;

-- ----------------------------------------------------------------------------
-- Hvor lenge en selvmelding gjelder
--
-- En rad databasen selv skrev, er en tilstand: jobben ga opp, og den er
-- fortsatt gitt opp til noe lukker den. En rad en brukerflate meldte, er noe
-- annet — den sier «dette kallet gikk ikke gjennom akkurat nå», og den kan
-- ikke si noe om hva som skjedde etterpå. Fanen ble kanskje lukket.
--
-- Selvmeldingen behandles derfor som et hjerteslag og ikke som en tilstand:
-- den gjelder så lenge den fornyes. Alternativet — å la flaten lukke sin egen
-- melding når kallet går gjennom igjen — ville lagt oppryddingen av varig
-- servertilstand i et minne som forsvinner ved en sideoppfriskning, en ny fane
-- eller en ny sesjon. Da ville ett nettverksglipp kunnet bli stående som et
-- uløst problem for alltid.
--
-- Vinduet er romslig med vilje. Et problem som faktisk pågår, meldes om igjen
-- og fornyer seg selv; et som er over, slutter å bli meldt.
-- ----------------------------------------------------------------------------
create function workflow.self_report_heartbeat()
  returns interval
  language sql
  immutable
  set search_path = ''
as $$
  select interval '30 minutes'
$$;

comment on function workflow.self_report_heartbeat() is
  'Hvor lenge en selvmeldt observasjon gjelder uten å bli fornyet. Står ett sted fordi to steder ville vært to vinduer: både tellingen bak merket i navigasjonen og den tekniske oversikten leser den.';

revoke execute on function workflow.self_report_heartbeat() from public;

create function workflow.technical_incident_ongoing(p_incident workflow.technical_incidents)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select p_incident.resolved_at is null
     and (not p_incident.self_reported
          or p_incident.last_seen_at > statement_timestamp() - workflow.self_report_heartbeat())
$$;

comment on function workflow.technical_incident_ongoing(workflow.technical_incidents) is
  'Om et teknisk problem fortsatt pågår. For en rad databasen selv skrev, er svaret at ingenting har lukket den. For en selvmeldt rad kreves i tillegg at den er fornyet innenfor workflow.self_report_heartbeat(): en klient kan ikke love noe om hva som skjedde etter at fanen ble lukket, og en opprydding som hvilte på klientens minne ville etterlatt ett nettverksglipp som et uløst problem for alltid.';

revoke execute on function workflow.technical_incident_ongoing(workflow.technical_incidents) from public;

create function workflow.close_stale_self_reports()
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_id uuid;
  v_closed integer := 0;
begin
  for v_id in
    update workflow.technical_incidents ti
    set resolved_at = ti.last_seen_at
    where ti.self_reported
      and ti.resolved_at is null
      and ti.last_seen_at <= statement_timestamp() - workflow.self_report_heartbeat()
    returning ti.id
  loop
    insert into workflow.technical_incident_events (technical_incident_id, transition)
    values (v_id, 'resolved');
    v_closed := v_closed + 1;
  end loop;

  return v_closed;
end;
$$;

comment on function workflow.close_stale_self_reports() is
  'Skriver ned det workflow.technical_incident_ongoing(workflow.technical_incidents) allerede regner ut: en selvmeldt observasjon som ikke er fornyet innenfor hjerteslaget, er over, og lukkes med tidspunktet den sist ble sett. Kjøres når en admin leser den tekniske oversikten, slik at historikken stemmer med det som vises. Sletter ingenting; sporet får overgangen resolved som alle andre lukkinger.';

revoke execute on function workflow.close_stale_self_reports() from public;

-- ----------------------------------------------------------------------------
-- Den rå årsaken, lagret der den faktisk overlever
--
-- `workflow.technical_incidents.diagnosis` er og blir Antideps egen setning: én
-- rad per problem, skrevet av Antidep, aldri en videreformidlet feiltekst. Den
-- regelen står.
--
-- Men klassifiseringen er ikke diagnosen. En teknisk agent som skal finne ut
-- *hvorfor* et kall sviktet, trenger stacken og den faktiske meldingen — og en
-- `console.error` i en nettleser er ingen varig kanal: fanen lukkes, og da er
-- årsaken borte. Issue #99 krever eksplisitt at den bevares for Claude Code og
-- ChatGPT uten å vises i UI, og det kravet er ikke oppfylt av en logglinje som
-- forsvinner.
--
-- Den rå årsaken får derfor sin egen tabell, atskilt fra tilstandsraden, med
-- fire grenser som gjør en klientskrevet tekst forsvarlig:
--
--   attribusjon   hver rad bæres av en innlogget bruker, og kan ikke skrives
--                 av en anonym besøkende
--   mengde        en bruker kan skrive et begrenset antall rader per time;
--                 over grensen telles problemet fortsatt, men teksten droppes
--   lengde        teksten klippes, slik at ingen kan fylle tabellen med én rad
--   innhold       tokenformede strenger fjernes før lagring
--
-- Tabellen er append-only, som sporet ved siden av: en observasjon av hva som
-- gikk galt, skal ikke kunne endres eller fjernes av den samme veien som skrev
-- den. Mengdegrensen er derfor også det som holder den i tømme — skal den
-- ryddes, gjøres det av den som allerede har databasetilgang.
--
-- Og den viktigste: ingen vei ut. Tabellen har RLS med default deny, ingen
-- grants og ingen policy, og ingen api-funksjon leser den. Den finnes for den
-- som allerede har databasetilgang — altså for en teknisk agent, og ikke for
-- noen brukerflate (ANTIDEP_CONSTITUTION.md regel 4, 7).
--
-- Hvorfor ikke en ekstern tjeneste: en adresse i nettleserbygget er offentlig,
-- og et mottak som godtar kall fra hvem som helst uten autentisering, er enten
-- åpent for forgiftning eller avhengig av en hemmelighet en klient ikke kan
-- holde. Antidep har allerede en autentisert, serverkontrollert skrivevei med
-- hele autorisasjonen i databasen, og den er den tryggeste som finnes her.
-- Prisen er ærlig: svikter Data API-et selv, når heller ikke denne raden fram.
-- Da er *det* hendelsen, og den ser man på tjenestens egen status.
-- ----------------------------------------------------------------------------
create table workflow.client_diagnostics (
  id uuid primary key default gen_random_uuid(),

  technical_incident_id uuid
    references workflow.technical_incidents (id) on update restrict on delete restrict,

  reported_by_user_id uuid not null,
  area workflow.technical_area not null,
  kind text not null,
  operation text,
  code text,
  http_status integer,
  transport text,

  -- Den rå årsaken: stacken og meldingen slik flaten så dem, klippet og
  -- vasket av workflow.scrub_diagnostic_detail(text).
  detail text not null,

  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint client_diagnostics_detail_shape_check
    check (length(detail) between 1 and 4000),
  constraint client_diagnostics_http_status_check
    check (http_status is null or http_status between 100 and 599)
);

comment on table workflow.client_diagnostics is
  'Den rå tekniske årsaken slik en brukerflate så den, lagret privat for Claude Code og ChatGPT (issue #99, punkt 8). Atskilt fra workflow.technical_incidents med vilje: tilstandsraden bærer Antideps egen setning og aldri en videreformidlet feiltekst, mens denne bærer nettopp den videreformidlede teksten — og er derfor bundet av attribusjon, mengdegrense, lengdegrense og vasking i api.report_technical_problem(text, text, text, text, integer, text, text). Tabellen har RLS med default deny, ingen grants og ingen policy, og ingen api-funksjon leser den: den finnes for den som allerede har databasetilgang, og har ingen vei til noen brukerflate.';
comment on column workflow.client_diagnostics.detail is
  'Stacken og meldingen slik flaten så dem. Klippet til 4000 tegn og vasket for tokenformede strenger før lagring. Aldri lesbar gjennom noe api-objekt.';
comment on column workflow.client_diagnostics.reported_by_user_id is
  'Den innloggede brukeren raden er skrevet av. Finnes for at mengdegrensen skal kunne håndheves per bruker, og for at en rad ikke skal kunne skrives av noen som ikke kan tilskrives.';

alter table workflow.client_diagnostics enable row level security;

create index client_diagnostics_incident_idx
  on workflow.client_diagnostics (technical_incident_id, occurred_at desc);

create index client_diagnostics_reporter_idx
  on workflow.client_diagnostics (reported_by_user_id, occurred_at desc);

-- Append-only, som sporet ved siden av. En observasjon av hva som gikk galt,
-- skal ikke kunne endres eller fjernes av den samme veien som skrev den — og
-- allerminst av en klient. Skal tabellen ryddes, gjøres det av den som allerede
-- har databasetilgang, altså av en teknisk agent.
create trigger client_diagnostics_set_created_at
  before insert on workflow.client_diagnostics
  for each row execute function catalog.set_created_at();

create trigger client_diagnostics_are_append_only
  before update or delete on workflow.client_diagnostics
  for each row execute function knowledge.reject_append_only_mutation(
    'Den rå årsaken er en observasjon av hva som faktisk skjedde. En ny observasjon er en ny rad.'
  );

-- ----------------------------------------------------------------------------
-- Vaskingen
--
-- Klipper og fjerner det som ser ut som en hemmelighet. Bevisst smal: målet er
-- ikke å gjøre teksten trygg i seg selv — den er allerede bak RLS uten noen
-- lesevei — men å hindre at en token som havnet i en feilmelding, blir liggende
-- lesbar i en tabell lenger enn den lever.
-- ----------------------------------------------------------------------------
create function workflow.scrub_diagnostic_detail(p_detail text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select left(
    regexp_replace(
      regexp_replace(coalesce(p_detail, ''), 'eyJ[A-Za-z0-9_.-]{20,}', '[token utelatt]', 'g'),
      '(?i)(bearer|apikey|api_key|authorization|password)([=: ]+)[^\s,;"'']+',
      '\1\2[utelatt]', 'g'),
    4000)
$$;

comment on function workflow.scrub_diagnostic_detail(text) is
  'Klipper den rå årsaken til 4000 tegn og fjerner tokenformede strenger — JWT-er og verdier bak bearer, apikey, authorization eller password. Bevisst smal: teksten er allerede bak RLS uten noen lesevei, og vaskingen finnes for at en token som havnet i en feilmelding, ikke skal bli liggende lesbar lenger enn den lever.';

revoke execute on function workflow.scrub_diagnostic_detail(text) from public;

-- ============================================================================
-- 2. Hvilke artikler Antidep faktisk mangler
--
-- «Venter på fulltekst» har hittil ikke vært en tilstand i Antidep, bare fravær
-- av en rad. En kilde uten fulltekst så ut som en kilde ingen hadde bedt om,
-- og en flate kunne derfor ikke skille «vi trenger denne artikkelen» fra
-- «denne artikkelen er ikke aktuell».
--
-- Forespørselen gjør behovet eksplisitt, og bærer samtidig den redaksjonelle
-- avgrensningen ekstraksjonsoppgaven trenger — hvilke virkestoff, hvilke
-- endepunkt, hvilken populasjon et funn kan gjelde. Avgrensningen tas her,
-- én gang, av den som ber om artikkelen; den som senere laster opp PDF-en,
-- skal ikke måtte ta den om igjen. Det er nettopp den arbeidsdelingen issue #99
-- ber om: opplastingen er å velge riktig fil, ikke å konfigurere en oppgave.
-- ============================================================================
create type workflow.full_text_request_state as enum ('open', 'fulfilled', 'withdrawn');

revoke usage on type workflow.full_text_request_state from public;

comment on type workflow.full_text_request_state is
  'Hvor en fulltekstforespørsel står: open (Antidep mangler artikkelen og venter), fulfilled (fullteksten er registrert, og arbeidet er lagt i kø) eller withdrawn (forespørselen gjelder ikke lenger). En forespørsel som er open, er en normal arbeidsblokkering og aldri et teknisk problem (ANTIDEP_CONSTITUTION.md regel 4).';

create table workflow.full_text_requests (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  source_id uuid not null
    references knowledge.sources (id) on update restrict on delete restrict,

  -- Den redaksjonelle avgrensningen, tatt én gang. Ekstraksjonsoppgaven bygges
  -- av nøyaktig disse verdiene når fullteksten er registrert, slik at
  -- opplastingen ikke trenger å spørre om noe som allerede er bestemt.
  drug_ids uuid[] not null,
  outcome_concept_ids uuid[] not null,
  population_ids uuid[] not null default array[]::uuid[],

  -- Hvor originaldokumentet hentes fra. Oppgis av den som ber om artikkelen,
  -- eller utledes av kildens registrerte DOI når den har en — slik at den som
  -- laster opp, ikke blir bedt om en adresse Antidep allerede kjenner.
  retrieved_from text not null,

  state workflow.full_text_request_state not null default 'open',
  requested_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  requested_at timestamptz not null default now(),

  fulfilled_source_version_id uuid
    references knowledge.source_versions (id) on update restrict on delete restrict,
  closed_at timestamptz,
  closed_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint full_text_requests_reference_key unique (reference),
  constraint full_text_requests_scope_check
    check (cardinality(drug_ids) between 1 and 50
           and cardinality(outcome_concept_ids) between 1 and 50
           and cardinality(population_ids) between 0 and 50),
  constraint full_text_requests_retrieved_from_shape_check
    check (retrieved_from = btrim(retrieved_from)
           and length(retrieved_from) between 1 and 2000),
  constraint full_text_requests_closed_reason_shape_check
    check (closed_reason is null
           or (closed_reason = btrim(closed_reason)
               and length(closed_reason) between 1 and 1000)),
  -- Hva som skal være satt følger av tilstanden, og regelen er uttømmende over
  -- vokabularet: uten else-grenen ville en ny verdi gitt NULL, og en NULL
  -- passerer en CHECK.
  constraint full_text_requests_state_shape_check
    check (
      case state
        when 'open' then
          fulfilled_source_version_id is null and closed_at is null
        when 'fulfilled' then
          fulfilled_source_version_id is not null and closed_at is not null
        when 'withdrawn' then
          fulfilled_source_version_id is null and closed_at is not null
            and closed_reason is not null
        else false
      end
    )
);

comment on table workflow.full_text_requests is
  'Hvilke artikler Antidep mangler fullteksten til, med den redaksjonelle avgrensningen ekstraksjonsoppgaven skal bygges av (ANTIDEP_CONSTITUTION.md regel 1). Én åpen forespørsel per kilde. En åpen rad er det den åpne arbeidsoversikten viser som «venter på fulltekst» — en normal arbeidsblokkering, aldri et teknisk problem. Raden lukkes av api.complete_full_text_extraction(uuid, text, text) i det kildeversjonen er registrert, og aldri av en flate.';
comment on column workflow.full_text_requests.retrieved_from is
  'Hvor originaldokumentet hentes fra. Oppgis av den som ber om artikkelen, eller utledes av kildens registrerte DOI når den har en — den samme verdien npm run editor:assignment har bedt om siden migrasjon 003e. En PMID utledes bevisst ikke: en PubMed-side viser sammendraget og ikke dokumentet, så den ville pekt et sted fullteksten ikke er å finne, og da er det riktigere å spørre enn å gjette. Fingeravtrykket identifiserer filen, men ikke hvor den kommer fra, og en kildeversjon uten opphav er ikke sporbar til en utgiver.';

alter table workflow.full_text_requests enable row level security;

create unique index full_text_requests_open_source_key
  on workflow.full_text_requests (source_id)
  where state = 'open';

create index full_text_requests_open_idx
  on workflow.full_text_requests (requested_at)
  where state = 'open';

create trigger full_text_requests_set_row_timestamps
  before insert or update on workflow.full_text_requests
  for each row execute function catalog.set_row_timestamps();

-- ----------------------------------------------------------------------------
-- Adressen artikkelen hentes fra, utledet av kildens egen identitet
-- ----------------------------------------------------------------------------
create function workflow.source_retrieval_address(p_source_id uuid)
  returns text
  language sql
  stable
  set search_path = ''
as $$
  select 'https://doi.org/' || i.identifier_value
  from knowledge.source_identifiers i
  where i.source_id = p_source_id and i.identifier_system = 'doi'
  order by i.identifier_value
  limit 1;
$$;

comment on function workflow.source_retrieval_address(uuid) is
  'Adressen kildens fulltekst hentes fra, utledet av kildens registrerte DOI. Finnes for at en fulltekstforespørsel skal kunne opprettes uten at noen skriver en adresse Antidep allerede kjenner — det er den samme verdien npm run editor:assignment har bedt om siden migrasjon 003e, og den løser opp til utgiverens egen side for nettopp denne publikasjonen. En PMID utledes bevisst ikke: en PubMed-side viser sammendraget og ikke dokumentet, så den ville pekt et sted fullteksten ikke er å finne. Svarer NULL når kilden ikke har DOI; da må adressen oppgis av den som ber om artikkelen.';

revoke execute on function workflow.source_retrieval_address(uuid) from public;

-- ----------------------------------------------------------------------------
-- Avgrensningen kontrolleres når den registreres, ikke når den brukes
--
-- En forespørsel med et virkestoff som ikke finnes, ville blitt stående som
-- noe som ventet på et menneske, uten å kunne utføres. Kontrollen er den samme
-- workflow.agent_task_input_problem(...) gjør på ekstraksjonsoppgaven — den
-- kjøres bare tidligere, slik at feilen fanges der den kan rettes.
-- ----------------------------------------------------------------------------
create function workflow.full_text_request_scope_problem(
  p_drug_ids uuid[],
  p_outcome_concept_ids uuid[],
  p_population_ids uuid[]
)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_drug_ids is null or cardinality(p_drug_ids) = 0 then
    return 'Forespørselen sier ikke hvilke virkestoff et funn kan gjelde.';
  end if;
  select count(*) into v_count from catalog.drugs d where d.id = any (p_drug_ids);
  if v_count <> cardinality(p_drug_ids) then
    return 'Ett av virkestoffene finnes ikke i katalogen.';
  end if;

  if p_outcome_concept_ids is null or cardinality(p_outcome_concept_ids) = 0 then
    return 'Forespørselen sier ikke hvilke endepunkt et funn kan gjelde.';
  end if;
  select count(*) into v_count
  from catalog.clinical_concepts c
  where c.id = any (p_outcome_concept_ids) and c.concept_type = 'outcome';
  if v_count <> cardinality(p_outcome_concept_ids) then
    return 'Ett av endepunktene finnes ikke i katalogen.';
  end if;

  select count(*) into v_count
  from catalog.populations p
  where p.id = any (coalesce(p_population_ids, array[]::uuid[]));
  if v_count <> cardinality(coalesce(p_population_ids, array[]::uuid[])) then
    return 'En av populasjonene finnes ikke i katalogen.';
  end if;

  return null;
end;
$$;

comment on function workflow.full_text_request_scope_problem(uuid[], uuid[], uuid[]) is
  'Én setning om hva som eventuelt er galt med den redaksjonelle avgrensningen på en fulltekstforespørsel, eller NULL. Den samme kontrollen workflow.agent_task_input_problem(workflow.pipeline_jobs) gjør på ekstraksjonsoppgaven, kjørt tidligere: en avgrensning som ikke kan bli en oppgave, skal avvises der den kan rettes.';

revoke execute on function workflow.full_text_request_scope_problem(uuid[], uuid[], uuid[]) from public;

-- ----------------------------------------------------------------------------
-- To like avgrensninger skal være like
--
-- `{a,b}` og `{b,a,b}` er den samme redaksjonelle avgrensningen. Uten en
-- normalisering ville sammenligningen under sagt at de var forskjellige, og en
-- gjentatt forespørsel ville blitt avvist som noe annet enn seg selv.
-- ----------------------------------------------------------------------------
create function workflow.sorted_unique(p_ids uuid[])
  returns uuid[]
  language sql
  immutable
  set search_path = ''
as $$
  select coalesce(
    (select array_agg(distinct id order by id) from unnest(coalesce(p_ids, array[]::uuid[])) as id),
    array[]::uuid[]);
$$;

comment on function workflow.sorted_unique(uuid[]) is
  'Den samme mengden id-er, alltid i den samme formen: sortert og uten duplikater. Finnes for at to like redaksjonelle avgrensninger skal være like også som verdier, slik at en gjentatt fulltekstforespørsel kjennes igjen som seg selv.';

revoke execute on function workflow.sorted_unique(uuid[]) from public;

-- ----------------------------------------------------------------------------
-- Svaret når artikkelen allerede er etterspurt
--
-- Egen funksjon fordi den brukes to steder — når raden ble sett, og når den
-- dukket opp under et samtidig kall — og fordi to kopier ville kunnet komme i
-- utakt om hva som er «den samme bestillingen».
-- ----------------------------------------------------------------------------
create function workflow.full_text_request_outcome(
  p_existing workflow.full_text_requests,
  p_drug_ids uuid[],
  p_outcome_concept_ids uuid[],
  p_population_ids uuid[]
)
  returns jsonb
  language plpgsql
  stable
  set search_path = ''
as $$
begin
  if p_existing.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Forespørselen kunne ikke registreres, og den finnes heller ikke fra før.';
  end if;

  if p_existing.drug_ids is distinct from p_drug_ids
     or p_existing.outcome_concept_ids is distinct from p_outcome_concept_ids
     or p_existing.population_ids is distinct from p_population_ids then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Antidep venter allerede på denne artikkelen, med en annen avgrensning.',
      hint = 'Den åpne forespørselen bestemmer hva ekstraksjonsoppgaven bygges av. Vent til fullteksten er registrert og be om den nye avgrensningen da, eller trekk den åpne forespørselen tilbake med api.withdraw_full_text_request(text, text) først. Et stille ja her ville latt arbeidet forsvinne uten at noen merket det.';
  end if;

  return jsonb_build_object(
    'reference', p_existing.reference,
    'requested', false,
    'state', p_existing.state::text);
end;
$$;

comment on function workflow.full_text_request_outcome(workflow.full_text_requests, uuid[], uuid[], uuid[]) is
  'Svaret når artikkelen allerede er etterspurt: den samme avgrensningen er den samme bestillingen og svarer requested: false, mens en annen avgrensning avvises framfor å svelges stille. Egen funksjon fordi api.request_full_text(uuid, uuid[], uuid[], uuid[], text) trenger den både når raden ble sett og når den dukket opp under et samtidig kall.';

revoke execute on function workflow.full_text_request_outcome(workflow.full_text_requests, uuid[], uuid[], uuid[]) from public;

create function api.request_full_text(
  p_source_id uuid,
  p_drug_ids uuid[],
  p_outcome_concept_ids uuid[],
  p_population_ids uuid[] default array[]::uuid[],
  p_retrieved_from text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_problem text;
  v_retrieved_from text;
  v_drug_ids uuid[] := workflow.sorted_unique(p_drug_ids);
  v_outcome_ids uuid[] := workflow.sorted_unique(p_outcome_concept_ids);
  v_population_ids uuid[] := workflow.sorted_unique(p_population_ids);
  v_existing workflow.full_text_requests;
  v_reference text;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if not exists (select 1 from knowledge.sources s where s.id = p_source_id) then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kilden finnes ikke.',
      hint = 'En fulltekstforespørsel hører til en registrert publikasjon. Opprett kilden med api.create_source(...) først.';
  end if;

  v_problem := workflow.full_text_request_scope_problem(
    v_drug_ids, v_outcome_ids, v_population_ids);
  if v_problem is not null then
    raise exception using errcode = 'invalid_parameter_value', message = v_problem;
  end if;

  v_retrieved_from := coalesce(
    nullif(btrim(coalesce(p_retrieved_from, '')), ''),
    workflow.source_retrieval_address(p_source_id));
  if v_retrieved_from is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kilden har ingen registrert DOI, så Antidep kan ikke utlede hvor fullteksten hentes fra.',
      hint = 'Oppgi adressen dokumentet faktisk hentes fra, eller registrer kildens DOI. En PMID utledes bevisst ikke: en PubMed-side viser sammendraget og ikke dokumentet. Fingeravtrykket identifiserer filen, men ikke hvor den kommer fra, og en kildeversjon uten opphav er ikke sporbar til en utgiver.';
  end if;

  -- Idempotent på kilden *og* på avgrensningen: den samme artikkelen med den
  -- samme avgrensningen etterspurt to ganger er én forespørsel, så en gjentatt
  -- orkestrering ikke dobler ventelisten.
  --
  -- En *annen* avgrensning er derimot en annen bestilling, og den skal ikke
  -- svelges stille. Svarte vi `requested: false` på den, ville den som ba om
  -- et nytt virkestoff, fått beskjed om at det var i orden — mens
  -- ekstraksjonsoppgaven senere ble bygget uten det, og arbeidet forsvant uten
  -- at noen merket det. Samme regel som api.enqueue_pipeline_job(...) har:
  -- den samme nøkkelen med et annet innhold avvises framfor å gjenbrukes.
  select r.* into v_existing
  from workflow.full_text_requests r
  where r.source_id = p_source_id and r.state = 'open';

  if v_existing.id is not null then
    return workflow.full_text_request_outcome(
      v_existing, v_drug_ids, v_outcome_ids, v_population_ids);
  end if;

  begin
    insert into workflow.full_text_requests
      (source_id, drug_ids, outcome_concept_ids, population_ids,
       retrieved_from, requested_by_actor_id)
    values
      (p_source_id, v_drug_ids, v_outcome_ids, v_population_ids,
       v_retrieved_from, v_actor_id)
    returning reference into v_reference;
  exception
    -- To samtidige forespørsler om den samme artikkelen er fortsatt én
    -- forespørsel. Den partielle unike indeksen avgjør hvem som vant, og den
    -- som tapte, svarer på nøyaktig samme måte som om den hadde sett raden
    -- først — ellers ville idempotensen bare holdt når ingen andre var der.
    when unique_violation then
      select r.* into v_existing
      from workflow.full_text_requests r
      where r.source_id = p_source_id and r.state = 'open';
      return workflow.full_text_request_outcome(
        v_existing, v_drug_ids, v_outcome_ids, v_population_ids);
  end;

  return jsonb_build_object('reference', v_reference, 'requested', true, 'state', 'open');
end;
$$;

comment on function api.request_full_text(uuid, uuid[], uuid[], uuid[], text) is
  'Ber om fullteksten til én registrert kilde, med den redaksjonelle avgrensningen ekstraksjonsoppgaven skal bygges av. Idempotent på kilden: den samme artikkelen etterspurt to ganger er én forespørsel. Adressen dokumentet hentes fra, utledes av kildens egen DOI når den har en — en DOI peker på dokumentet selv, og det finnes ikke noe annet registrert kildenummer som gjør det. Krever editor-mandat: hvilken artikkel Antidep trenger og hva et funn kan gjelde, er en redaksjonell avgjørelse. SECURITY DEFINER fordi knowledge, workflow og catalog har RLS med default deny; tomt search_path, og kalleren valideres på funksjonens eget kall (§50).';

revoke execute on function api.request_full_text(uuid, uuid[], uuid[], uuid[], text) from public;
grant execute on function api.request_full_text(uuid, uuid[], uuid[], uuid[], text) to authenticated;

-- ----------------------------------------------------------------------------
-- Å trekke en forespørsel tilbake
--
-- Tilstanden `withdrawn` finnes fordi en bestilling kan bli uaktuell: artikkelen
-- viste seg å være feil, eller avgrensningen skal være en annen. Uten en vei
-- inn i den ville en åpen forespørsel med feil avgrensning vært en blindvei —
-- den ville stått i den åpne oversikten for alltid, og en ny bestilling ville
-- blitt avvist mot den.
--
-- En fil som er under behandling, stopper tilbaketrekkingen. Den filen er
-- allerede levert av et menneske, og å lukke bestillingen under den ville
-- etterlatt et uttrekk uten noe å oppfylle.
-- ----------------------------------------------------------------------------
create function api.withdraw_full_text_request(p_reference text, p_reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_request workflow.full_text_requests;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  perform knowledge.assert_editor_authorized();

  if v_reason is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En tilbaketrekking skal ha en begrunnelse.',
      hint = 'Uten den er «artikkelen var feil» og «avgrensningen skal være en annen» samme tilstand, og de to er forskjellige tilstander (ANTIDEP_CONSTITUTION.md regel 4).';
  end if;

  select r.* into v_request
  from workflow.full_text_requests r
  where r.reference = p_reference and r.state = 'open'
  for update;

  if v_request.id is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Antidep venter ikke på fulltekst for denne artikkelen nå.';
  end if;

  if exists (
    select 1 from workflow.full_text_intake i
    where i.full_text_request_id = v_request.id and i.state in ('received', 'processing')
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Antidep arbeider med en fil for denne artikkelen akkurat nå.',
      hint = 'Vent til filen er ferdig behandlet. Blir den avvist, kan forespørselen trekkes tilbake.';
  end if;

  update workflow.full_text_requests r
  set state = 'withdrawn', closed_at = now(), closed_reason = v_reason
  where r.id = v_request.id;

  return jsonb_build_object('reference', v_request.reference, 'state', 'withdrawn');
end;
$$;

comment on function api.withdraw_full_text_request(text, text) is
  'Trekker én åpen fulltekstforespørsel tilbake, med en begrunnelse. Finnes fordi en bestilling kan bli uaktuell, og fordi en åpen forespørsel med feil avgrensning ellers ville vært en blindvei: den ville stått i den åpne oversikten for alltid, og en ny bestilling ville blitt avvist mot den. En fil som er under behandling, stopper tilbaketrekkingen — den er allerede levert av et menneske. Krever editor-mandat: hvilke artikler Antidep trenger, er en redaksjonell avgjørelse.';

revoke execute on function api.withdraw_full_text_request(text, text) from public;
grant execute on function api.withdraw_full_text_request(text, text) to authenticated;

-- ============================================================================
-- 3. Den ene registreringsveien, løftet ut så to innganger kan dele den
--
-- Migrasjon 009a la fire kontroller i én transaksjon: filen inn i det private
-- biblioteket, publikasjonstilhørigheten mot kildens egen identitet,
-- lesbarheten inkludert tabellene, og kildeversjonen. Fulltekstinnboksen skal
-- gjennom nøyaktig de samme fire — ikke gjennom noe som ligner.
--
-- Kroppen flyttes derfor til workflow.register_full_text_document(uuid, uuid, bytea, timestamptz, text, text, text, text, text, text, text), og
-- api.upload_full_text_document(uuid, timestamptz, text, text, text, text, text, text, text, text) blir det den alltid har vært utad: én
-- editor-kontroll, én base64-dekoding, og så den delte veien. En andre
-- skrivevei ville vært en andre kontroll å glemme (AGENTS.md).
-- ============================================================================
create function workflow.full_text_document_problem(p_bytes bytea)
  returns text
  language plpgsql
  immutable
  set search_path = ''
as $$
declare
  v_size bigint := octet_length(p_bytes);
begin
  if p_bytes is null or v_size = 0 then
    return 'Originaldokumentet er tomt, og en tom fil identifiserer ingen artikkel.';
  end if;
  if v_size > 67108864 then
    return format('Originaldokumentet er %s byte, og grensen er 67108864.', v_size);
  end if;
  if substring(p_bytes from 1 for 5) <> '\x255044462d'::bytea then
    return 'Originaldokumentet er ikke en PDF.';
  end if;
  return null;
end;
$$;

comment on function workflow.full_text_document_problem(bytea) is
  'Én setning om hvorfor et originaldokument ikke kan tas imot — tomt, større enn grensen, eller ikke en PDF — eller NULL. Egen funksjon fordi både api.upload_full_text_document(uuid, timestamptz, text, text, text, text, text, text, text, text) og fulltekstinnboksen må avvise nøyaktig det samme, og to steder å skrive grensen ville vært to steder å endre den bare ett av.';

revoke execute on function workflow.full_text_document_problem(bytea) from public;

create function workflow.register_full_text_document(
  p_actor_id uuid,
  p_source_id uuid,
  p_bytes bytea,
  p_retrieved_at timestamptz,
  p_retrieved_from text,
  p_extracted_text text,
  p_text_extraction_tool text,
  p_text_extraction_tool_version text,
  p_text_extraction_arguments text,
  p_text_extraction_transform text,
  p_external_version text
)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_size bigint;
  v_sha text;
  v_document_id uuid;
  v_document_created boolean := false;
  v_binding jsonb;
  v_problem text;
  v_metrics jsonb;
  v_content_hash text;
  v_source_version_id uuid;
  v_version_created boolean := false;
begin
  if not exists (select 1 from knowledge.sources s where s.id = p_source_id) then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kilden %L finnes ikke.', p_source_id),
      hint = 'En fulltekst hører til en registrert publikasjon. Opprett kilden med api.create_source(...) først.';
  end if;

  v_problem := workflow.full_text_document_problem(p_bytes);
  if v_problem is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = v_problem,
      hint = 'Antidep henter i dag bare tekst ut av PDF med etterprøvbar proveniens, og en fulltekstartikkel er normalt noen få megabyte.';
  end if;

  if left(coalesce(p_extracted_text, ''), 5) = '%PDF-' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Den uttrukne teksten er selv en PDF, og er dermed ikke tekst noen kan lese et ordrett utdrag ut av.',
      hint = 'Oppgi resultatet av tekstuttrekkingen, ikke dokumentet en gang til.';
  end if;

  -- Den lukkede oppskriftslisten, sett fra skriveveien (migrasjon 003f, 003g).
  -- Bare den gjeldende oppskriften kan registreres.
  if p_text_extraction_tool is distinct from 'pdftotext'
    or p_text_extraction_arguments is distinct from '-bbox-layout -enc UTF-8 -eol unix'
    or p_text_extraction_transform is distinct from 'antidep-reading-order@2'
  then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Oppskriften er ikke den Antidep registrerer nye kildeversjoner med.',
      hint = 'Tillatt er nøyaktig verktøyet pdftotext med argumentene -bbox-layout -enc UTF-8 -eol unix og etterbehandlingen antidep-reading-order@2. Oppskriften kjøres på nytt ved hver etterprøving, og listen over hva som kan kjøres, er derfor lukket. Versjonen av verktøyet er fri: den er en opplysning, ikke noe som kjøres.';
  end if;

  v_size := octet_length(p_bytes);

  -- 1. Filidentiteten. Innholdsadressert, så en gjentatt opplasting av den
  --    samme filen finner den samme raden framfor å lage en til.
  v_sha := knowledge.source_document_fingerprint(p_bytes);
  select d.id into v_document_id
  from knowledge.source_documents d
  where d.sha256 = v_sha;

  if v_document_id is null then
    insert into knowledge.source_documents
      (sha256, byte_size, media_type, content, stored_by_actor_id)
    values (v_sha, v_size, 'application/pdf', p_bytes, p_actor_id)
    returning id into v_document_id;
    v_document_created := true;
  end if;

  -- 2. Publikasjonstilhørigheten. Fail-closed: uten et treff blir dette ingen
  --    fulltekstversjon, og transaksjonen tar filen med seg.
  v_binding := knowledge.publication_binding_for(p_source_id, p_extracted_text);
  if v_binding is null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Fullteksten bærer ingen av kildens registrerte identiteter, og kan derfor ikke vises å være denne publikasjonen.',
      hint = 'Kontrollen leter etter kildens DOI, dens PMID navngitt som en PMID, eller de første 60 tegnene av tittelen — i den uttrukne teksten. Et korrekt fingeravtrykk beviser hvilken fil dette er, ikke hvilken artikkel den er. Registrer kildens DOI eller PMID med api.create_source(...)-flyten, eller last opp riktig fil.';
  end if;

  insert into knowledge.source_document_publications
    (source_document_id, source_id, binding_basis, binding_evidence, bound_by_actor_id)
  values (
    v_document_id, p_source_id,
    (v_binding ->> 'basis')::knowledge.publication_binding_basis,
    v_binding ->> 'evidence',
    p_actor_id
  )
  on conflict on constraint source_document_publications_pairing_key do nothing;

  -- 3. Lesbarheten, tabellene inkludert.
  v_problem := knowledge.full_text_readability_problem(p_extracted_text);
  if v_problem is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = v_problem,
      hint = 'Kliniske funn krever en fulltekst som faktisk lar seg lese, tabellene inkludert (ANTIDEP_CONSTITUTION.md regel 1). En representasjon som ikke oppfyller det, registreres ikke — en manglende kontroll kan ikke kalles verifisert.';
  end if;

  -- Kildeversjonen. Idempotent: (source_id, content_hash) er unik, så den
  -- samme fullteksten lastet opp igjen finner raden framfor å kollidere.
  v_content_hash := knowledge.source_version_content_hash(p_extracted_text);
  select sv.id into v_source_version_id
  from knowledge.source_versions sv
  where sv.source_id = p_source_id and sv.content_hash = v_content_hash;

  if v_source_version_id is null then
    v_source_version_id := knowledge.record_source_version(
      p_source_id,
      p_retrieved_at,
      p_retrieved_from,
      p_extracted_text,
      p_external_version,
      null,
      'full_text',
      p_actor_id,
      v_sha,
      v_size,
      'application/pdf',
      p_text_extraction_tool,
      p_text_extraction_tool_version,
      p_text_extraction_arguments,
      p_text_extraction_transform
    );
    v_version_created := true;
  elsif exists (
    select 1
    from knowledge.source_versions sv
    where sv.id = v_source_version_id and sv.document_sha256 is distinct from v_sha
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Den uttrukne teksten er allerede registrert for denne kilden, men fra et annet originaldokument.',
      hint = 'En kildeversjon er teksten *og* dokumentet den kom av. To forskjellige filer som gir samme tekst, er to representasjoner, og bare den registrerte er den kildeversjonen bærer.';
  end if;

  v_metrics := knowledge.full_text_readability_metrics(p_extracted_text);
  insert into knowledge.full_text_readability_checks (
    source_version_id, source_document_id,
    character_count, letter_count, line_count, table_row_count, table_declaration_count
  )
  values (
    v_source_version_id, v_document_id,
    (v_metrics ->> 'character_count')::bigint,
    (v_metrics ->> 'letter_count')::bigint,
    (v_metrics ->> 'line_count')::bigint,
    (v_metrics ->> 'table_rows')::bigint,
    (v_metrics ->> 'table_declarations')::bigint
  )
  on conflict on constraint full_text_readability_checks_source_version_key do nothing;

  -- Representasjonen blir liggende privat ved siden av kildeversjonen
  -- (migrasjon 010b). Den ligger her og ikke i en egen kommando fordi en
  -- kildeversjon uten sin egen tekst ikke kan bære en agentoppgave, og en
  -- andre kommando er et sted å glemme.
  perform knowledge.record_source_version_text(v_source_version_id, p_extracted_text, p_actor_id);

  return jsonb_build_object(
    'source_document_id', v_document_id,
    'document_sha256', v_sha,
    'document_byte_size', v_size,
    'document_stored', v_document_created,
    'source_version_id', v_source_version_id,
    'source_version_created', v_version_created,
    'content_hash', v_content_hash,
    'publication_binding', v_binding,
    'readability', v_metrics
  );
end;
$$;

comment on function workflow.register_full_text_document(
  uuid, uuid, bytea, timestamptz, text, text, text, text, text, text, text
) is
  'Den ene kontrollerte registreringen av en fulltekst, løftet ut av api.upload_full_text_document(uuid, timestamptz, text, text, text, text, text, text, text, text) i migrasjon 012a slik at både den og fulltekstinnboksen går gjennom nøyaktig de samme fire kontrollene: filen inn i det private biblioteket med sha256 beregnet av bytene, publikasjonstilhørigheten mot kildens registrerte DOI, PMID eller tittel, lesbarheten inkludert tabellkontrollen, og kildeversjonen som full_text. Feiler én av dem, blir ingenting stående — heller ikke filen. Kalleren er allerede kontrollert og aktøren allerede bestemt; funksjonen tar derfor aktøren som argument og er ikke SECURITY DEFINER.';

revoke execute on function workflow.register_full_text_document(
  uuid, uuid, bytea, timestamptz, text, text, text, text, text, text, text
) from public;

-- Den gamle inngangen, nå som det den er utad: én kontroll, én dekoding, og så
-- den delte veien. Signaturen og svaret er uendret.
create or replace function api.upload_full_text_document(
  p_source_id uuid,
  p_retrieved_at timestamptz,
  p_retrieved_from text,
  p_document_base64 text,
  p_extracted_text text,
  p_text_extraction_tool text,
  p_text_extraction_tool_version text,
  p_text_extraction_arguments text,
  p_text_extraction_transform text,
  p_external_version text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_bytes bytea;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_document_base64, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Originaldokumentet mangler, og da er det ingenting å legge i biblioteket.',
      hint = 'Send filen som base64, byte for byte. Databasen beregner fingeravtrykket selv.';
  end if;

  begin
    v_bytes := decode(p_document_base64, 'base64');
  exception
    when others then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Originaldokumentet er ikke gyldig base64.',
        hint = 'Kod filen slik den er. Enhver omforming underveis ville gitt et fingeravtrykk som ikke er filens.';
  end;

  return workflow.register_full_text_document(
    v_actor_id, p_source_id, v_bytes, p_retrieved_at, p_retrieved_from,
    p_extracted_text, p_text_extraction_tool, p_text_extraction_tool_version,
    p_text_extraction_arguments, p_text_extraction_transform, p_external_version);
end;
$$;

-- ============================================================================
-- 4. Fulltekstinnboksen
--
-- Det eneste et menneske gjør her, er å velge riktig PDF til en artikkel
-- Antidep sier den mangler. Alt etterpå er Antideps eget arbeid.
--
-- ----------------------------------------------------------------------------
-- Hvorfor filen blir liggende her et øyeblikk
--
-- Tekstuttrekket må gjøres med den registrerte oppskriften — `pdftotext` med en
-- låst argumentliste og Antideps leserekkefølge — fordi oppskriften kjøres på
-- nytt ved hver etterprøving. En nettleser kan ikke kjøre den, og en *annen*
-- oppskrift for nettleserveien ville gjort fullteksten uprøvbar mot det som
-- faktisk ble kjørt.
--
-- Filen ligger derfor i innboksen til Antideps egen tekniske arbeider henter
-- den, kjører oppskriften og leverer teksten tilbake gjennom
-- api.complete_full_text_extraction(uuid, text, text). For den som lastet opp, er dette
-- usynlig: oppgaven står som «pågår» til den er registrert. Ventingen er
-- Antideps, ikke klinikerens.
--
-- ----------------------------------------------------------------------------
-- Bytene forsvinner når de ikke trengs lenger
--
-- En registrert fulltekst ligger i knowledge.source_documents, som er
-- gjengivelsesgrensen (ANTIDEP_CONSTITUTION.md regel 2). En avvist fil skal
-- ikke bli liggende i det hele tatt. `content` nulles derfor i det samme
-- kallet som avgjør utfallet, og tilstandsregelen håndhever det: en avsluttet
-- innboksrad kan ikke ha byte igjen.
--
-- ----------------------------------------------------------------------------
-- Avvisningen er en produkttilstand, ikke en feiltekst
--
-- «Filen ser ikke ut til å være denne artikkelen» og «teksten lot seg ikke
-- lese» er ting den som lastet opp kan gjøre noe med, og de registreres som
-- lukkede koder flaten oversetter til norsk. En teknisk svikt i uttrekket er
-- noe annet, og havner i workflow.technical_incidents
-- (ANTIDEP_CONSTITUTION.md regel 4).
-- ============================================================================
create type workflow.full_text_intake_state as enum
  ('received', 'processing', 'blocked', 'registered', 'rejected');

revoke usage on type workflow.full_text_intake_state from public;

comment on type workflow.full_text_intake_state is
  'Hvor en opplastet fil står: received (lastet opp, venter på Antideps eget tekstuttrekk), processing (uttrekket pågår, med en leie som løper ut), blocked (tekstuttrekket kan ikke kjøres akkurat nå — et driftsproblem, ikke noe med filen; filen blir liggende og arbeidet fortsetter av seg selv når problemet er rettet), registered (fullteksten er registrert og arbeidet lagt i kø) eller rejected (filen kunne ikke brukes, med en lukket grunn den som lastet opp kan gjøre noe med). Skillet mellom blocked og rejected er hele forskjellen mellom en teknisk feil og en menneskeoppgave (ANTIDEP_CONSTITUTION.md regel 4).';

create type workflow.full_text_rejection as enum (
  'not_this_article',
  'unreadable',
  'not_a_pdf',
  'other_document_same_text',
  'extraction_failed'
);

revoke usage on type workflow.full_text_rejection from public;

comment on type workflow.full_text_rejection is
  'Hvorfor en opplastet fil ikke kunne brukes, i et lukket vokabular flaten oversetter til norsk: not_this_article = fullteksten bærer ingen av kildens registrerte identiteter, unreadable = teksten oppfyller ikke lesbarhets- og tabellkravene, not_a_pdf = filen er ikke en PDF Antidep kan hente tekst ut av, other_document_same_text = den samme teksten er registrert for kilden fra et annet originaldokument, extraction_failed = Antidep fikk ikke hentet tekst ut av filen i det hele tatt. De fire første er noe den som lastet opp kan rette; den siste er et teknisk problem og registreres også som det.';

create table workflow.full_text_intake (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  full_text_request_id uuid not null
    references workflow.full_text_requests (id) on update restrict on delete restrict,
  source_id uuid not null
    references knowledge.sources (id) on update restrict on delete restrict,

  sha256 text not null,
  byte_size bigint not null,
  -- Originalfilen, bare så lenge den trengs. Nulles i det utfallet avgjøres.
  content bytea,

  state workflow.full_text_intake_state not null default 'received',
  -- To tellere, fordi de teller to helt forskjellige ting. `attempts` er hvor
  -- mange ganger raden er tatt ut av køen — den fanger også en arbeider som
  -- forsvant uten å si noe. `tool_failures` er hvor mange ganger verktøyet
  -- faktisk kjørte og ikke fikk brukbar tekst ut av *denne filen*. Bare den
  -- siste sier noe om filen, og bare den kan derfor lede til at Antidep ber om
  -- en annen PDF.
  attempts integer not null default 0,
  tool_failures integer not null default 0,

  -- Leien, med samme form som workflow.pipeline_jobs: en arbeider som
  -- forsvinner, skal ikke blokkere innboksen for alltid.
  lease_token uuid,
  lease_expires_at timestamptz,

  submitted_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  submitted_at timestamptz not null default now(),

  source_version_id uuid
    references knowledge.source_versions (id) on update restrict on delete restrict,
  rejection workflow.full_text_rejection,
  completed_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint full_text_intake_reference_key unique (reference),
  constraint full_text_intake_sha256_shape_check
    check (sha256 ~ '^sha256:[0-9a-f]{64}$'),
  constraint full_text_intake_byte_size_check
    check (byte_size between 1 and 67108864),
  -- Fingeravtrykket er filens, ikke en påstand kalleren skriver. Samme regel
  -- som knowledge.source_documents bærer, og av samme grunn: identiteten skal
  -- kunne regnes ut av innholdet så lenge innholdet finnes.
  constraint full_text_intake_sha256_is_the_content_check
    check (content is null
           or (sha256 = knowledge.source_document_fingerprint(content)
               and byte_size = octet_length(content))),
  constraint full_text_intake_attempts_check check (attempts between 0 and 20),
  constraint full_text_intake_tool_failures_check check (tool_failures between 0 and 20),
  constraint full_text_intake_lease_pairing_check
    check ((lease_token is null) = (lease_expires_at is null)),
  constraint full_text_intake_state_shape_check
    check (
      case state
        when 'received' then
          content is not null and lease_token is null
          and completed_at is null and source_version_id is null and rejection is null
        when 'processing' then
          content is not null and lease_token is not null
          and completed_at is null and source_version_id is null and rejection is null
        -- Filen er i behold, og ingenting er avsluttet. Det er hele poenget:
        -- et driftsproblem skal ikke koste den som lastet opp filen sin.
        when 'blocked' then
          content is not null and lease_token is null
          and completed_at is null and source_version_id is null and rejection is null
        when 'registered' then
          content is null and lease_token is null
          and completed_at is not null and source_version_id is not null and rejection is null
        when 'rejected' then
          content is null and lease_token is null
          and completed_at is not null and source_version_id is null and rejection is not null
        else false
      end
    )
);

comment on table workflow.full_text_intake is
  'Én opplastet fulltekst på vei gjennom Antideps egne kontroller (ANTIDEP_CONSTITUTION.md regel 1, 2, 4). Filen ligger her fordi det registrerte tekstuttrekket må kjøres av Antidep selv og ikke av en nettleser; for den som lastet opp, er det usynlig. Bytene nulles i det utfallet avgjøres, slik at verken en avvist fil eller en kopi av en registrert blir liggende utenfor knowledge.source_documents. Tabellen har RLS med default deny, ingen grants og ingen policy: originalfilen forlater den bare gjennom api.claim_full_text_extraction(integer), til den som allerede har mandat til å laste den opp.';
comment on column workflow.full_text_intake.content is
  'Originalfilen, bare så lenge den trengs. Nulles i det samme kallet som avgjør utfallet, og tilstandsregelen håndhever det: en avsluttet innboksrad kan ikke ha byte igjen. En blokkert rad er ikke avsluttet, og beholder filen — arbeidet skal kunne fortsette av seg selv når driftsproblemet er rettet.';
comment on column workflow.full_text_intake.attempts is
  'Hvor mange ganger raden er tatt ut av køen. Teller også et uttak der arbeideren forsvant uten å si fra, og sier derfor ingenting om filen. Brukes bare til å stoppe et uttak som går rundt uten å komme noen vei; da blokkeres raden, den avvises ikke.';
comment on column workflow.full_text_intake.tool_failures is
  'Hvor mange ganger det registrerte tekstuttrekket faktisk kjørte og ikke fikk brukbar tekst ut av denne filen. Dette er det eneste tallet som sier noe om filen, og det eneste som kan lede til at Antidep ber om en annen PDF.';
comment on column workflow.full_text_intake.rejection is
  'Hvorfor filen ikke kunne brukes, i et lukket vokabular. En avvisning er en produkttilstand den som lastet opp kan gjøre noe med, og ikke en feiltekst: flaten oversetter koden til norsk, og ingen rå årsak følger med.';

alter table workflow.full_text_intake enable row level security;

-- En blokkert rad holder fortsatt forespørselen: filen er levert, og Antidep
-- skal ikke be om en ny mens den første ligger og venter på at driften rettes.
create unique index full_text_intake_open_request_key
  on workflow.full_text_intake (full_text_request_id)
  where state in ('received', 'processing', 'blocked');

create index full_text_intake_ready_idx
  on workflow.full_text_intake (submitted_at)
  where state in ('received', 'processing');

create index full_text_intake_blocked_idx
  on workflow.full_text_intake (submitted_at)
  where state = 'blocked';

create index full_text_intake_request_idx
  on workflow.full_text_intake (full_text_request_id, submitted_at desc);

create trigger full_text_intake_set_row_timestamps
  before insert or update on workflow.full_text_intake
  for each row execute function catalog.set_row_timestamps();

-- ----------------------------------------------------------------------------
-- Opplastingen: ett valg, og ingen tekniske verdier
-- ----------------------------------------------------------------------------
create function api.submit_full_text(p_reference text, p_document_base64 text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_request workflow.full_text_requests;
  v_bytes bytea;
  v_problem text;
  v_sha text;
  v_open workflow.full_text_intake;
  v_reference text;
begin
  v_actor_id := workflow.assert_full_text_inbox_authorized();

  select r.* into v_request
  from workflow.full_text_requests r
  where r.reference = p_reference and r.state = 'open'
  for update;

  if v_request.id is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Antidep venter ikke på fulltekst for denne artikkelen nå.',
      hint = 'Forespørselen er enten allerede oppfylt eller trukket tilbake. Hent innboksen på nytt.';
  end if;

  if nullif(btrim(coalesce(p_document_base64, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ingen fil ble sendt med.';
  end if;

  begin
    v_bytes := decode(p_document_base64, 'base64');
  exception
    when others then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Filen lot seg ikke lese slik den ble sendt.',
        hint = 'Send filen byte for byte. Enhver omforming underveis ville gitt et fingeravtrykk som ikke er filens.';
  end;

  v_problem := workflow.full_text_document_problem(v_bytes);
  if v_problem is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = v_problem,
      hint = 'Antidep henter i dag bare tekst ut av PDF med etterprøvbar proveniens.';
  end if;

  -- En åpen innboksrad betyr at Antidep allerede arbeider med en fil for denne
  -- artikkelen. Den samme filen sendt inn igjen er det samme arbeidet, og
  -- svarer med raden som allerede finnes; en annen fil ville vært et nytt
  -- arbeid midt i et pågående, og avvises framfor å overta det. En blokkert rad
  -- teller med: filen er levert, og den venter på at driften rettes — ikke på
  -- at noen laster den opp en gang til.
  v_sha := knowledge.source_document_fingerprint(v_bytes);
  select i.* into v_open
  from workflow.full_text_intake i
  where i.full_text_request_id = v_request.id
    and i.state in ('received', 'processing', 'blocked');

  if v_open.id is not null then
    if v_open.sha256 = v_sha then
      return jsonb_build_object('reference', v_open.reference, 'state', v_open.state::text,
                                'accepted', false);
    end if;
    raise exception using
      errcode = 'restrict_violation',
      message = 'Antidep arbeider allerede med en fil for denne artikkelen.',
      hint = 'Vent til den er ferdig behandlet. Blir den avvist, kan en annen fil lastes opp.';
  end if;

  insert into workflow.full_text_intake
    (full_text_request_id, source_id, sha256, byte_size, content, submitted_by_actor_id)
  values
    (v_request.id, v_request.source_id, v_sha, octet_length(v_bytes), v_bytes, v_actor_id)
  returning reference into v_reference;

  return jsonb_build_object('reference', v_reference, 'state', 'received', 'accepted', true);
end;
$$;

comment on function api.submit_full_text(text, text) is
  'Tar imot originaldokumentet til én artikkel Antidep har bedt om. Det eneste kalleren oppgir, er forespørselens ugjennomsiktige referanse og filen selv: fingeravtrykket, størrelsen, publikasjonsbindingen, lesbarheten, tekstuttrekket og kølegging av neste ledd er Antideps eget arbeid. Idempotent på filen: den samme filen sendt inn igjen svarer med raden som allerede finnes. Krever editor- eller admin-mandat. SECURITY DEFINER fordi knowledge og workflow har RLS med default deny; tomt search_path, og kalleren valideres på funksjonens eget kall (§50).';

revoke execute on function api.submit_full_text(text, text) from public;
grant execute on function api.submit_full_text(text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- Innboksen: hva som mangler, i vanlig språk
--
-- Svaret bærer tittel, forfattere og år — bibliografiske opplysninger om en
-- publisert artikkel, som er nettopp det en redaktør trenger for å vite hvilken
-- PDF som er riktig. Det bærer ingen uuid, ingen hash, ingen oppskrift og ingen
-- rå årsak. Den forrige avvisningen står som en lukket kode flaten oversetter.
-- ----------------------------------------------------------------------------
create function api.full_text_inbox()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_rows jsonb;
begin
  perform workflow.assert_full_text_inbox_authorized();

  select coalesce(jsonb_agg(row_to_json(q)::jsonb order by q.requested_at), '[]'::jsonb)
    into v_rows
  from (
    select
      r.reference,
      s.title,
      s.authors_or_issuer as authors,
      case when s.publication_date is null then null
           else extract(year from s.publication_date)::integer end as published_year,
      r.requested_at,
      -- «Venter på deg», «Antidep arbeider med den» eller «Antidep står fast
      -- teknisk». Den siste er med fordi alternativet ville vært å la den som
      -- lastet opp tro at arbeidet går videre når det ikke gjør det — men den
      -- ber ikke om noe: setningen flaten skriver, sier nettopp at ingenting
      -- skal gjøres. En registrert forespørsel er ikke lenger åpen og står
      -- ikke her.
      case
        when i.id is null then 'needs_upload'
        when i.state = 'blocked' then 'blocked'
        else 'processing'
      end as state,
      -- Den forrige avvisningen, som en lukket kode. Bare den siste: en liste
      -- over alt som har vært prøvd, ville vært en teknisk logg på en
      -- redaksjonell flate.
      (
        select p.rejection::text
        from workflow.full_text_intake p
        where p.full_text_request_id = r.id and p.state = 'rejected'
        order by p.completed_at desc
        limit 1
      ) as previous_rejection
    from workflow.full_text_requests r
    join knowledge.sources s on s.id = r.source_id
    left join workflow.full_text_intake i
      on i.full_text_request_id = r.id
     and i.state in ('received', 'processing', 'blocked')
    where r.state = 'open'
  ) q;

  return v_rows;
end;
$$;

comment on function api.full_text_inbox() is
  'Artiklene Antidep mangler fullteksten til, slik en redaktør trenger dem: tittel, forfattere, år, om Antidep venter på en fil, allerede arbeider med en, eller står fast på et driftsproblem, og hva som eventuelt var galt med den forrige filen — som en lukket kode flaten oversetter til norsk. Bare den første tilstanden ber om noe; de to andre sier at ingenting skal gjøres. Inneholder ingen uuid, ingen hash, ingen oppskrift og ingen rå årsak. Krever editor- eller admin-mandat.';

revoke execute on function api.full_text_inbox() from public;
grant execute on function api.full_text_inbox() to authenticated;

-- ============================================================================
-- 5. Antideps egen tekstuttrekker
--
-- Tre kall, og ingen flere: ta én opplastet fil, lever teksten tilbake, eller
-- si fra at uttrekket ikke lot seg gjøre. Ingen av dem hører til noen
-- brukerflate — de kalles av Antideps egen tekniske arbeider, som kjører den
-- registrerte oppskriften der `pdftotext` faktisk finnes
-- (`npm run ops:full-text`).
--
-- Mandatet er redaktørens. Det er ikke en utvidelse: den som kan laste opp
-- fullteksten, har allerede filen, og arbeideren gjør bare det kallet
-- `npm run editor:assignment -- --pdf …` alltid har gjort — bare uten at et
-- menneske må sitte med filen i hånden. Leien har samme form som på
-- workflow.pipeline_jobs, slik at en arbeider som forsvinner, ikke blokkerer
-- innboksen for alltid.
-- ============================================================================
create function api.claim_full_text_extraction(p_lease_seconds integer default 600)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_lease_seconds integer := least(greatest(coalesce(p_lease_seconds, 600), 30), 3600);
  v_intake workflow.full_text_intake;
  v_token uuid := gen_random_uuid();
begin
  perform knowledge.assert_editor_authorized();

  -- En rad som har vært tatt ut for mange ganger, skal ikke tas ut igjen i det
  -- uendelige. Men hva den blir til, avhenger av *hvorfor* — og det er hele
  -- forskjellen mellom en teknisk feil og en menneskeoppgave:
  --
  --   verktøyet kjørte og fikk ikke brukbar tekst ut av filen, tre ganger
  --     → filen er problemet, og en annen utgave av artikkelen kan hjelpe.
  --       Den avvises med sin egen grunn, og innboksen ber om en ny fil.
  --       Da er det tekniske problemet om *denne raden* avgjort, og lukkes:
  --       et problem som står åpent for alltid etter at systemet selv har
  --       konkludert, er et problem ingen kan gjøre noe med.
  --
  --   uttakene ble brukt opp uten at verktøyet noen gang rakk å si fra
  --     → driften er problemet, ikke filen. Raden blokkeres med filen i behold,
  --       og fortsetter av seg selv når problemet er rettet. Å be om en ny PDF
  --       her ville vært å skyve en teknisk oppgave over på et menneske
  --       (issue #99).
  for v_intake in
    select i.*
    from workflow.full_text_intake i
    where i.state in ('received', 'processing')
      and i.attempts >= 3
      and (i.lease_expires_at is null or i.lease_expires_at <= statement_timestamp())
    for update skip locked
  loop
    if v_intake.tool_failures >= 3 then
      update workflow.full_text_intake i
      set state = 'rejected',
          rejection = 'extraction_failed',
          content = null,
          lease_token = null,
          lease_expires_at = null,
          completed_at = now()
      where i.id = v_intake.id;

      -- Raden er ferdig, og dens eget problem er over: utfallet ble en
      -- produkttilstand, ikke en åpen teknisk sak.
      perform workflow.resolve_technical_incident(
        'full_text_intake', 'intake:' || v_intake.id::text);

      -- Men *leddet* er ikke friskmeldt av det. Én rar PDF er én ting; et
      -- verktøy som ikke får tekst ut av noen fil, er noe helt annet — og
      -- utenfra ser de to likt ut rad for rad. Signaturen er derfor leddets og
      -- ikke radens: hver avvisning teller opp den samme raden, og et
      -- tekstuttrekk som faktisk gir tekst, lukker den
      -- (api.complete_full_text_extraction(uuid, text, text)). En fil som var
      -- rar, etterlater da et lukket problem; et verktøy som er i stykker,
      -- etterlater et som vokser.
      perform workflow.record_technical_incident(
        'full_text_intake',
        'extraction',
        format('Det registrerte tekstuttrekket kjørte %s ganger på innboksrad %s (kilde %s, fil %s) og fikk ingen brukbar tekst ut av filen. Filen er avvist som en produkttilstand, og innboksen ber om en annen utgave. Står denne raden åpen og teller oppover, er det ikke filene det står på.',
               v_intake.tool_failures, v_intake.id, v_intake.source_id, v_intake.sha256));
    else
      update workflow.full_text_intake i
      set state = 'blocked',
          lease_token = null,
          lease_expires_at = null
      where i.id = v_intake.id;

      perform workflow.record_technical_incident(
        'full_text_intake',
        'intake:' || v_intake.id::text,
        format('Innboksrad %s (kilde %s, fil %s) ble tatt ut %s ganger uten at tekstuttrekkeren rakk å melde noe om filen. Raden er blokkert med filen i behold; api.resume_blocked_full_text_extractions() setter den i gang igjen når driften svarer.',
               v_intake.id, v_intake.source_id, v_intake.sha256, v_intake.attempts));
    end if;
  end loop;

  select i.* into v_intake
  from workflow.full_text_intake i
  where i.state = 'received'
     or (i.state = 'processing' and i.lease_expires_at <= statement_timestamp())
  order by i.submitted_at
  for update skip locked
  limit 1;

  if v_intake.id is null then
    return jsonb_build_object('available', false);
  end if;

  update workflow.full_text_intake i
  set state = 'processing',
      attempts = i.attempts + 1,
      lease_token = v_token,
      lease_expires_at = statement_timestamp() + make_interval(secs => v_lease_seconds)
  where i.id = v_intake.id;

  return jsonb_build_object(
    'available', true,
    'handle', v_token,
    'reference', v_intake.reference,
    'document_base64', encode(v_intake.content, 'base64'),
    'recipe', jsonb_build_object(
      'tool', 'pdftotext',
      'arguments', '-bbox-layout -enc UTF-8 -eol unix',
      'transform', 'antidep-reading-order@2'));
end;
$$;

comment on function api.claim_full_text_extraction(integer) is
  'Tar én opplastet fulltekst ut av innboksen med en leie, og svarer med originaldokumentet og den oppskriften uttrekket skal kjøres med. Kalles av Antideps egen tekniske arbeider, aldri av en brukerflate. Rydder først i rader som har vært tatt ut for mange ganger, og skiller de to årsakene: en fil verktøyet faktisk har lest uten å få brukbar tekst ut av, avvises slik at innboksen kan be om en annen utgave; en rad der uttakene bare ble brukt opp, blokkeres med filen i behold og fortsetter av seg selv. Leien løper ut, slik at en arbeider som forsvinner ikke blokkerer innboksen. Krever editor-mandat: kallet gir ut originaldokumentet, og det skal bare forlate databasen til den som allerede kan laste det opp.';

revoke execute on function api.claim_full_text_extraction(integer) from public;
grant execute on function api.claim_full_text_extraction(integer) to authenticated;

create function api.complete_full_text_extraction(
  p_handle uuid,
  p_extracted_text text,
  p_text_extraction_tool_version text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_intake workflow.full_text_intake;
  v_request workflow.full_text_requests;
  v_rejection workflow.full_text_rejection;
  v_registration jsonb;
  v_source_version_id uuid;
  v_content_hash text;
  v_enqueued jsonb;
begin
  perform knowledge.assert_editor_authorized();

  select i.* into v_intake
  from workflow.full_text_intake i
  where i.lease_token = p_handle
    and i.state = 'processing'
    and i.lease_expires_at > statement_timestamp()
  for update;

  if v_intake.id is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Uttrekksoppdraget gjelder ikke lenger.',
      hint = 'Leien er utløpt eller overtatt. Ta et nytt oppdrag med api.claim_full_text_extraction(integer).';
  end if;

  -- Å komme hit er beviset på at leddet virker: den registrerte oppskriften
  -- kjørte og ga tekst. Hva teksten så viser seg å være, er en annen sak — en
  -- fil som ikke er artikkelen, avvises like etter, og det er fortsatt et
  -- fungerende tekstuttrekk. Derfor lukkes leddets eget problem her, og ikke
  -- først når noe registreres.
  perform workflow.resolve_technical_incident('full_text_intake', 'extraction');

  select r.* into v_request
  from workflow.full_text_requests r
  where r.id = v_intake.full_text_request_id
  for update;

  -- De to kontrollene som er noe den som lastet opp kan rette, kjøres først og
  -- for seg. Registreringsveien håndhever dem uansett, fail-closed; her kjøres
  -- de bare tidligere, slik at avvisningen blir en produkttilstand med en
  -- lukket grunn framfor en avvist transaksjon uten vei videre.
  if knowledge.publication_binding_for(v_intake.source_id, p_extracted_text) is null then
    v_rejection := 'not_this_article';
  elsif knowledge.full_text_readability_problem(p_extracted_text) is not null then
    v_rejection := 'unreadable';
  else
    v_content_hash := knowledge.source_version_content_hash(p_extracted_text);
    if exists (
      select 1
      from knowledge.source_versions sv
      where sv.source_id = v_intake.source_id
        and sv.content_hash = v_content_hash
        and sv.document_sha256 is distinct from v_intake.sha256
    ) then
      v_rejection := 'other_document_same_text';
    end if;
  end if;

  if v_rejection is not null then
    update workflow.full_text_intake i
    set state = 'rejected',
        rejection = v_rejection,
        content = null,
        lease_token = null,
        lease_expires_at = null,
        completed_at = now()
    where i.id = v_intake.id;

    -- En avvist fil er ikke et teknisk problem. Var det registrert et fra et
    -- tidligere forsøk på den samme raden, er det over nå.
    perform workflow.resolve_technical_incident(
      'full_text_intake', 'intake:' || v_intake.id::text);

    return jsonb_build_object(
      'reference', v_intake.reference,
      'status', 'rejected',
      'rejection', v_rejection::text);
  end if;

  v_registration := workflow.register_full_text_document(
    -- Filen attribueres til den som faktisk leverte den, ikke til arbeideren
    -- som hentet teksten ut av den.
    v_intake.submitted_by_actor_id,
    v_intake.source_id,
    v_intake.content,
    v_intake.submitted_at,
    v_request.retrieved_from,
    p_extracted_text,
    'pdftotext',
    p_text_extraction_tool_version,
    '-bbox-layout -enc UTF-8 -eol unix',
    'antidep-reading-order@2',
    null);

  v_source_version_id := (v_registration ->> 'source_version_id')::uuid;

  update workflow.full_text_intake i
  set state = 'registered',
      source_version_id = v_source_version_id,
      content = null,
      lease_token = null,
      lease_expires_at = null,
      completed_at = now()
  where i.id = v_intake.id;

  update workflow.full_text_requests r
  set state = 'fulfilled',
      fulfilled_source_version_id = v_source_version_id,
      closed_at = now()
  where r.id = v_request.id;

  perform workflow.resolve_technical_incident(
    'full_text_intake', 'intake:' || v_intake.id::text);

  -- Og videre i køen, i det samme kallet. Avgrensningen er allerede tatt på
  -- forespørselen, så ingen blir bedt om å ta den om igjen — og innleggingen er
  -- idempotent, så en omkjøring dobler ingenting.
  v_enqueued := api.enqueue_agent_task('evidence_extraction', jsonb_build_object(
    'source_version_id', v_source_version_id,
    'drug_ids', to_jsonb(v_request.drug_ids),
    'outcome_concept_ids', to_jsonb(v_request.outcome_concept_ids),
    'population_ids', to_jsonb(v_request.population_ids)));

  return jsonb_build_object(
    'reference', v_intake.reference,
    'status', 'registered',
    'source_version_created', v_registration -> 'source_version_created',
    'work_enqueued', v_enqueued -> 'enqueued');
end;
$$;

comment on function api.complete_full_text_extraction(uuid, text, text) is
  'Leverer den uttrukne teksten tilbake for ett innboksoppdrag, og gjør resten i den samme transaksjonen: publikasjonsbindingen, lesbarhetskontrollen, registreringen gjennom workflow.register_full_text_document(uuid, uuid, bytea, timestamptz, text, text, text, text, text, text, text), lukkingen av fulltekstforespørselen og innleggingen av ekstraksjonsoppgaven med den avgrensningen forespørselen allerede bærer. Oppskriften er ikke en parameter — bare verktøyversjonen er, fordi den er en opplysning og ikke noe som velges. En fil som ikke kan brukes, avvises med en lukket grunn og er en produkttilstand, ikke en teknisk feil. Krever editor-mandat.';

revoke execute on function api.complete_full_text_extraction(uuid, text, text) from public;
grant execute on function api.complete_full_text_extraction(uuid, text, text) to authenticated;

create function api.fail_full_text_extraction(p_handle uuid, p_stage text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_intake workflow.full_text_intake;
  v_description text;
  v_next workflow.full_text_intake_state;
begin
  perform knowledge.assert_editor_authorized();

  -- Antideps egen setning, valgt av et lukket vokabular. Arbeideren sender
  -- aldri en feiltekst: en videreformidlet feilmelding kan bære et filnavn,
  -- en sti eller en del av dokumentet, og et spor skal ikke bli et sted slikt
  -- samler seg (samme regel som workflow.agent_runner_events.note).
  --
  -- De to stopppunktene fører til to forskjellige tilstander, og det er ikke en
  -- detalj:
  --
  --   tool_missing  verktøyet fantes ikke. Da vet vi ingenting om filen, og
  --                 neste forsøk er like umulig. Raden blokkeres med filen i
  --                 behold og fortsetter av seg selv når driften er rettet.
  --
  --   tool_failed   verktøyet kjørte og fikk ingenting brukbart ut av nettopp
  --                 denne filen. Det er en opplysning om filen, og den telles:
  --                 etter tre slike ber innboksen om en annen utgave.
  v_description := case p_stage
    when 'tool_missing' then 'Tekstuttrekkeren fant ikke verktøyet den registrerte oppskriften krever.'
    when 'tool_failed' then 'Tekstuttrekkeren kjørte den registrerte oppskriften, og den ga ingen brukbar tekst av filen.'
    else null
  end;
  v_next := case p_stage when 'tool_missing' then 'blocked' else 'received' end;

  if v_description is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ukjent stopppunkt for tekstuttrekket.',
      hint = 'Tillatt er tool_missing eller tool_failed. Vokabularet er lukket fordi Antidep skriver setningen selv, og smalt fordi kommandoen ikke skal kunne beskrive noe den ikke vet.';
  end if;

  select i.* into v_intake
  from workflow.full_text_intake i
  where i.lease_token = p_handle
    and i.state = 'processing'
    and i.lease_expires_at > statement_timestamp()
  for update;

  if v_intake.id is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Uttrekksoppdraget gjelder ikke lenger.';
  end if;

  -- Leien gis fra seg. Filen blir liggende uansett: verken et manglende verktøy
  -- eller en mislykket kjøring er et utfall, og en rad uten byte igjen kan
  -- ikke tas opp igjen.
  update workflow.full_text_intake i
  set state = v_next,
      tool_failures = i.tool_failures + case when p_stage = 'tool_failed' then 1 else 0 end,
      lease_token = null,
      lease_expires_at = null
  where i.id = v_intake.id;

  perform workflow.record_technical_incident(
    'full_text_intake',
    'intake:' || v_intake.id::text,
    format('%s Innboksrad %s, kilde %s, fil %s, uttak %s, mislykkede kjøringer %s. Raden står nå som %s.',
           v_description, v_intake.id, v_intake.source_id, v_intake.sha256, v_intake.attempts,
           v_intake.tool_failures + case when p_stage = 'tool_failed' then 1 else 0 end,
           v_next));

  return jsonb_build_object('reference', v_intake.reference, 'state', v_next::text);
end;
$$;

comment on function api.fail_full_text_extraction(uuid, text) is
  'Melder at det registrerte tekstuttrekket ikke lot seg kjøre for ett innboksoppdrag. Filen blir liggende i begge tilfeller, og de to stopppunktene fører til hver sin tilstand: tool_missing blokkerer raden, fordi et manglende verktøy ikke sier noe om filen og neste forsøk er like umulig; tool_failed setter raden tilbake i kø og teller opp én mislykket kjøring på nettopp denne filen. Registrerer et teknisk problem med Antideps egen setning — valgt av et lukket vokabular, aldri en videreformidlet feiltekst. Dette er den ene veien der en fil i innboksen blir et teknisk problem; en fil som bare er feil artikkel eller ikke lar seg lese, er en produkttilstand og går gjennom api.complete_full_text_extraction(uuid, text, text).';

revoke execute on function api.fail_full_text_extraction(uuid, text) from public;
grant execute on function api.fail_full_text_extraction(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- Veien tilbake fra et driftsproblem
--
-- En blokkert rad er arbeid som står, ikke arbeid som er over. Den skal derfor
-- ha en vei videre som ikke går gjennom et menneske: arbeideren kaller denne
-- når den har kontrollert at verktøyet oppskriften krever, faktisk finnes — og
-- alt som sto, går i kø igjen med filen den alltid har hatt.
--
-- Uttakstelleren nullstilles, fordi den talte uttak som aldri ble et forsøk.
-- Tellingen av mislykkede kjøringer står, fordi den sier noe om filen, og den
-- opplysningen er like sann etter at driften er rettet.
-- ----------------------------------------------------------------------------
create function api.resume_blocked_full_text_extractions()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_intake workflow.full_text_intake;
  v_resumed integer := 0;
begin
  perform knowledge.assert_editor_authorized();

  for v_intake in
    select i.*
    from workflow.full_text_intake i
    where i.state = 'blocked'
    order by i.submitted_at
    for update skip locked
  loop
    update workflow.full_text_intake i
    set state = 'received',
        attempts = 0
    where i.id = v_intake.id;

    perform workflow.resolve_technical_incident(
      'full_text_intake', 'intake:' || v_intake.id::text);

    v_resumed := v_resumed + 1;
  end loop;

  return jsonb_build_object('resumed', v_resumed);
end;
$$;

comment on function api.resume_blocked_full_text_extractions() is
  'Setter i gang igjen alle opplastede fulltekster som står blokkert på et driftsproblem, og lukker det tekniske problemet hver av dem bar. Kalles av Antideps egen tekniske arbeider når den har kontrollert at verktøyet den registrerte oppskriften krever, faktisk finnes — slik at et rettet driftsproblem fortsetter arbeidet av seg selv, uten at noen blir bedt om å laste opp filen på nytt (issue #99). Nullstiller uttakstelleren, som talte uttak som aldri ble et forsøk, og lar tellingen av mislykkede kjøringer stå, som sier noe om filen. Krever editor-mandat, som de andre kallene i uttrekksveien.';

revoke execute on function api.resume_blocked_full_text_extractions() from public;
grant execute on function api.resume_blocked_full_text_extractions() to authenticated;

-- ============================================================================
-- 6. Den åpne arbeidsoversikten
--
-- Én funksjon, og den er den eneste `anon` får. Den svarer med et lukket
-- produktvokabular og ingenting annet:
--
--   reference   et avtrykk av raden, ikke raden — et håndtak uten å være nøkkel
--   activity    hva slags arbeid det er, i produktets egne ord
--   status      planlagt, pågår, feilet, fullført
--   waiting_for_full_text  om det som står i veien, er at artikkelen mangler
--   subjects    hvilke virkestoff arbeidet gjelder
--   updated_at  når det sist skjedde noe
--
-- Ingen agentrolle, ingen modell, ingen kjører, ingen jobbnøkkel, ingen
-- artikkeltittel, ingen uuid og ingen feiltekst forlater databasen her. At en
-- oppgave har feilet, er en opplysning; *hvorfor* den feilet, er en teknisk
-- detalj som blir liggende i workflow.pipeline_jobs.failure_reason.
--
-- Virkestoffnavnene er med fordi de er det eneste her som er klinisk
-- interessant, og fordi de er offentlige allerede: catalog.drugs er
-- Antideps kontrollerte vokabular, ikke innhold om noen.
-- ============================================================================
create function workflow.work_board_reference(p_id uuid)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select left(encode(sha256(convert_to(p_id::text || '|antidep-work-board', 'UTF8')), 'hex'), 24);
$$;

comment on function workflow.work_board_reference(uuid) is
  'Et stabilt, ugjennomsiktig håndtak til én rad i den åpne arbeidsoversikten. Avtrykk av radens id og ikke id-en selv: oversikten er offentlig, og en intern id som sto på skjermen, ville vært både et internt navn på avveie og et håndtak inn i noe annet. Stabil mellom kall, slik at en flate kan bruke den som nøkkel.';

revoke execute on function workflow.work_board_reference(uuid) from public;

create function workflow.work_board_drugs(p_manifest jsonb)
  returns text[]
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(array_agg(name order by name), array[]::text[])
  from (
    select distinct d.canonical_name as name
    from catalog.drugs d
    where d.id = any (coalesce(
          workflow.manifest_uuids(p_manifest, 'drug_ids'), array[]::uuid[]))
       or d.id = workflow.manifest_uuid(p_manifest, 'subject_drug_id')
       or d.id in (
            select r.subject_drug_id
            from knowledge.claim_revisions r
            where r.id = workflow.manifest_uuid(p_manifest, 'claim_revision_id')
          )
    limit 5
  ) picked;
$$;

comment on function workflow.work_board_drugs(jsonb) is
  'Hvilke virkestoff en pipelinejobb gjelder, lest av jobbens eget inndatamanifest — direkte for en ekstraksjon eller en syntese, og gjennom påstandsrevisjonen for en evidensvurdering. Finnes for at den åpne arbeidsoversikten skal kunne si noe klinisk meningsfullt uten å navngi artikkelen.';

revoke execute on function workflow.work_board_drugs(jsonb) from public;

create function api.public_work_board()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
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
      i.id is null as waiting_for_full_text,
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
      false,
      workflow.work_board_drugs(j.input_manifest),
      coalesce(j.completed_at, j.updated_at, j.enqueued_at)
    from (
      select * from workflow.pipeline_jobs
      where state <> 'succeeded'
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
      false,
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
$$;

comment on function api.public_work_board() is
  'Hva Antidep arbeider med, i klinikerens språk og uten en eneste intern verdi (issue #99). Svarer med et lukket produktvokabular: hva slags arbeid det er, om det er planlagt, pågår, har feilet eller er fullført, om det som står i veien er at artikkelen mangler, hvilke virkestoff det gjelder, og når det sist skjedde noe. Ingen agentrolle, ingen modell, ingen kjører, ingen jobbnøkkel, ingen artikkeltittel, ingen uuid og ingen feiltekst forlater databasen her — at en oppgave har feilet er en opplysning, og hvorfor den feilet er en teknisk detalj som blir liggende. Tilstanden er databasens egen og ikke en flates: den overlever en sideoppfriskning og en ny sesjon. Lesbar uten innlogging, og det er hele poenget.';

revoke execute on function api.public_work_board() from public;
grant execute on function api.public_work_board() to anon, authenticated;

-- ============================================================================
-- 7. Hvor de tekniske problemene kommer fra
--
-- Ikke fra en ny skrivevei, men fra de veiene som allerede finnes. En jobb som
-- gir opp, og et kjørerkall som ender i en teknisk feil, er begge noe databasen
-- selv ser — og en trigger kan ikke glemmes slik et kall kan.
--
-- Diagnosen er Antideps egen setning. Begrunnelsen fra et mislykket forsøk
-- kopieres bevisst *ikke* inn: den kommer fra en kjører, og den ligger allerede
-- i workflow.pipeline_jobs.failure_reason der den hører hjemme.
-- ============================================================================
create function workflow.track_pipeline_job_incident()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.state = 'failed' then
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

comment on function workflow.track_pipeline_job_incident() is
  'Holder den tekniske problemoversikten i takt med jobbtilstanden: en jobb som gir opp, blir et uløst problem, og den samme jobben fullført senere lukker det. Ligger på tabellen og ikke på skriveveien, slik at en senere skrivevei ikke kan endre tilstanden uten at oversikten følger med.';

revoke execute on function workflow.track_pipeline_job_incident() from public;

create trigger pipeline_jobs_track_technical_incident
  after update on workflow.pipeline_jobs
  for each row
  when (new.state is distinct from old.state)
  execute function workflow.track_pipeline_job_incident();

create function workflow.track_agent_runner_incident()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  -- Bare de to utfallsklassene som faktisk er tekniske. «Ingen arbeid» og
  -- «faglig blokkert» er normale kjøringer, og en avvisning er den
  -- autoritative kontrollen som gjør jobben sin (ANTIDEP_CONSTITUTION.md
  -- regel 4).
  if new.outcome in ('server_error', 'approval_blocked') then
    perform workflow.record_technical_incident(
      'agent_service',
      'runner:' || new.connection_id::text,
      format('Et kall fra den autonome kjøreren %s endte som %s. Kallene står i workflow.agent_runner_events.',
             new.connection_id, new.outcome),
      new.self_reported);
  elsif new.outcome in ('ok', 'no_work') then
    perform workflow.resolve_technical_incident(
      'agent_service', 'runner:' || new.connection_id::text);
  end if;
  return null;
end;
$$;

comment on function workflow.track_agent_runner_incident() is
  'Holder den tekniske problemoversikten i takt med den autonome kjøreren: et kall som endte i en teknisk feil eller i en godkjenning plattformen ikke ga, blir et uløst problem, og neste kall som går gjennom, lukker det. Bare de to utfallsklassene som faktisk er tekniske telles — «ingen arbeid» og «faglig blokkert» er normale kjøringer, og en avvisning er den autoritative kontrollen som gjør jobben sin.';

revoke execute on function workflow.track_agent_runner_incident() from public;

create trigger agent_runner_events_track_technical_incident
  after insert on workflow.agent_runner_events
  for each row execute function workflow.track_agent_runner_incident();

-- ----------------------------------------------------------------------------
-- Selvmeldingen fra en brukerflate
--
-- En flate som ikke fikk lest det den skulle, kan ikke skrive et autoritativt
-- spor om hvorfor — den vet det ikke. Den kan bare si hvilket område som ikke
-- svarte, og hvilken form svikten hadde. Begge er lukkede vokabularer, og
-- Antidep skriver setningen selv: en fritekst herfra ville gjort loggen til et
-- sted en videreformidlet feilmelding kunne bære et filnavn, en URL eller en
-- del av et svar.
--
-- Bare `authenticated`. En uinnlogget besøkende kan ikke tilskrives noe, og en
-- åpen skrivevei til problemoversikten ville vært en vei til å få lampen til å
-- lyse. Den rå årsaken går sin egen vei, til den private diagnostikk-kanalen
-- flaten er konfigurert med (`src/app/diagnostics-sink.ts`), og aldri hit.
-- ----------------------------------------------------------------------------
create function api.report_technical_problem(
  p_area text,
  p_kind text,
  p_operation text default null,
  p_code text default null,
  p_http_status integer default null,
  p_transport text default null,
  p_detail text default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_area workflow.technical_area;
  v_description text;
  v_transport text;
  v_incident_id uuid;
  v_detail text;
begin
  if auth.uid() is null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Meldingen kan ikke tilskrives noen.';
  end if;

  begin
    v_area := p_area::workflow.technical_area;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Ukjent område.';
  end;

  v_description := case p_kind
    when 'unavailable' then 'En brukerflate fikk ikke svar fra Antidep på dette området.'
    when 'unreadable_answer' then 'En brukerflate fikk et svar fra Antidep som ikke stemte med kontrakten.'
    else null
  end;

  if v_description is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ukjent svikttype.',
      hint = 'Tillatt er unavailable eller unreadable_answer. En manglende rettighet er ikke et teknisk problem og skal ikke meldes hit.';
  end if;

  -- Operasjonen må være en funksjon som faktisk finnes i api. Kontrollen er
  -- ikke en formalitet: den er grunnen til at feltet ikke er fritekst. En
  -- verdi som må treffe et navn databasen selv har, kan ikke bære et filnavn,
  -- en adresse eller en del av et svar.
  if p_operation is not null and not exists (
    select 1
    from pg_catalog.pg_proc pr
    join pg_catalog.pg_namespace ns on ns.oid = pr.pronamespace
    where ns.nspname = 'api' and pr.proname = p_operation
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ukjent operasjon.',
      hint = 'Operasjonen skal være navnet på den api-funksjonen kallet gjaldt. Feltet er ikke fritekst: verdien kontrolleres mot funksjonene som finnes.';
  end if;

  -- Koden er en maskinidentifikator og ingenting annet: en SQLSTATE på fem
  -- tegn, eller en PostgREST-kode. Mønsteret er stramt av samme grunn som
  -- over — en kode som må se slik ut, kan ikke bære innhold.
  if p_code is not null and p_code !~ '^([0-9A-Z]{5}|PGRST[0-9]{3})$' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ukjent kodeform.',
      hint = 'Tillatt er en SQLSTATE på fem tegn (0-9, A-Z) eller en PostgREST-kode på formen PGRST000.';
  end if;

  if p_http_status is not null and p_http_status not between 100 and 599 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ukjent statuskode.',
      hint = 'Tillatt er en HTTP-status mellom 100 og 599.';
  end if;

  -- Transportformen finnes fordi koden ofte mangler nettopp når svaret aldri
  -- kom: et brudd i nettet, en avbrutt forespørsel, en tjeneste som ikke
  -- svarte. Uten den ville en teknisk agent sett *at* et kall sviktet uten noe
  -- som helst om hvorfor. Vokabularet er lukket, og Antidep skriver setningen
  -- selv — som for alt annet her.
  v_transport := case p_transport
    when 'offline' then 'Nettleseren hadde ingen nettforbindelse.'
    when 'network' then 'Forespørselen nådde aldri fram.'
    when 'aborted' then 'Forespørselen ble avbrutt før svaret kom.'
    when 'timeout' then 'Svaret kom ikke innen tiden.'
    when 'http' then 'Tjenesten svarte, men med en feilkode.'
    when 'contract' then 'Svaret kom fram, men stemte ikke med kontrakten flaten leser det med.'
    when 'unknown' then 'Formen på svikten lot seg ikke bestemme.'
    else null
  end;

  if p_transport is not null and v_transport is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ukjent transportform.',
      hint = 'Tillatt er offline, network, aborted, timeout, http, contract eller unknown. Vokabularet er lukket fordi Antidep skriver setningen selv.';
  end if;

  v_incident_id := workflow.record_technical_incident(
    v_area,
    -- Signaturen bærer operasjonen, slik at to forskjellige kall som svikter,
    -- blir to problemer og ikke ett.
    'client:' || coalesce(p_operation, 'ukjent'),
    format('%s Kallet var api.%s, svaret bar koden %s, og HTTP-statusen var %s. %s Selve feilteksten står ikke her, men i workflow.client_diagnostics, der den er bundet av attribusjon, mengde, lengde og vasking.',
           v_description,
           coalesce(p_operation, '(ikke oppgitt)'),
           coalesce(p_code, '(ingen)'),
           coalesce(p_http_status::text, '(ingen)'),
           coalesce(v_transport, 'Transportformen ble ikke oppgitt.')),
    true);

  -- Og den rå årsaken, til den som skal finne ut hvorfor.
  --
  -- Mengdegrensen står før innsettingen og ikke etter: en flate som svikter i
  -- en løkke, skal ikke kunne fylle tabellen. Problemet telles fortsatt — det
  -- er teksten som droppes, og det er riktig vei å tape på.
  v_detail := workflow.scrub_diagnostic_detail(p_detail);
  if length(coalesce(v_detail, '')) > 0
     and (select count(*)
          from workflow.client_diagnostics d
          where d.reported_by_user_id = auth.uid()
            and d.occurred_at > statement_timestamp() - interval '1 hour') < 60
  then
    insert into workflow.client_diagnostics
      (technical_incident_id, reported_by_user_id, area, kind, operation, code,
       http_status, transport, detail)
    values
      (v_incident_id, auth.uid(), v_area, p_kind, p_operation, p_code,
       p_http_status, p_transport, v_detail);
  end if;
end;
$$;

comment on function api.report_technical_problem(text, text, text, text, integer, text, text) is
  'Lar en innlogget brukerflate melde fra om at et kall til Antidep ikke gikk gjennom, og er den eneste veien den rå årsaken bevares varig. De seks første argumentene er maskinidentifikatorer og aldri tekst: området, svikttypen og transportformen er lukkede vokabularer, operasjonen kontrolleres mot funksjonene som faktisk finnes i api, koden må være en SQLSTATE eller en PostgREST-kode, og statusen må være en HTTP-status. De skriver tilstandsraden, der setningen er Antideps egen. Det siste argumentet er feilteksten og stacken, og de går til workflow.client_diagnostics — en egen, privat tabell uten grants, uten policy og uten noen api-lesevei, der teksten er bundet av attribusjon, en mengdegrense per bruker og time, en lengdegrense og vasking av tokenformede strenger. Skillet er med vilje: tilstandsraden er Antideps ord om hva som er galt, råmaterialet er klientens ord om hva den så. Raden merkes self_reported og gjelder bare så lenge den fornyes (workflow.self_report_heartbeat()). En manglende rettighet er ikke et teknisk problem og avvises. Bare authenticated: en uinnlogget besøkende kan ikke tilskrives noe.';

revoke execute on function api.report_technical_problem(text, text, text, text, integer, text, text) from public;
grant execute on function api.report_technical_problem(text, text, text, text, integer, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- Og veien ut igjen
--
-- Ikke gjennom et kall fra flaten. En selvmeldt rad lukkes av at den slutter å
-- bli fornyet (workflow.self_report_heartbeat()), og det er en avgjørelse
-- serveren tar på egen hånd.
--
-- Alternativet var å la flaten lukke sin egen melding når det samme kallet gikk
-- gjennom igjen. Det ville virket helt til noen oppdaterte siden: minnet om
-- hva som var meldt, lever i fanen, og med fanen borte ville meldingen blitt
-- stående som et uløst problem for alltid. Opprydding av varig servertilstand
-- skal ikke hvile på flyktig klientminne — og to kall som begge er
-- fire-and-forget, har uansett ingen garantert rekkefølge.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- De to leseveiene
--
-- Oversikten krever admin og svarer aldri med diagnosen. Tellingen er det
-- navigasjonen trenger for å vite om merket skal vises, og den svarer stille
-- «ikke synlig» til alle andre — et avslag der ville blitt til en feilmelding
-- på hver eneste side, for hver eneste innlogget bruker som ikke er admin.
-- ----------------------------------------------------------------------------
create function api.technical_problem_board()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_rows jsonb;
begin
  perform workflow.assert_admin_authorized();

  -- Skriver ned det regelen allerede sier, slik at historikken stemmer med det
  -- som vises. Kjøres her og ikke i tellingen: tellingen leses av hver side for
  -- hver innlogget bruker, og en skriving der ville vært en skriving på hver
  -- sidevisning.
  perform workflow.close_stale_self_reports();

  select coalesce(jsonb_agg(row_to_json(q)::jsonb order by q.ongoing desc, q.last_seen_at desc),
                  '[]'::jsonb)
    into v_rows
  from (
    select
      ti.reference,
      ti.area::text as area,
      ti.first_seen_at,
      ti.last_seen_at,
      ti.occurrence_count,
      workflow.technical_incident_ongoing(ti) as ongoing,
      ti.resolved_at
    from workflow.technical_incidents ti
    order by workflow.technical_incident_ongoing(ti) desc, ti.last_seen_at desc
    limit 100
  ) q;

  return v_rows;
end;
$$;

comment on function api.technical_problem_board() is
  'De tekniske problemene Antidep kjenner til, slik en ikke-teknisk admin trenger dem: hvilket område det gjelder, når problemet først og sist ble sett, hvor mange ganger, og om det fortsatt pågår. Om noe pågår, avgjøres av workflow.technical_incident_ongoing(workflow.technical_incidents): en rad databasen selv skrev, står til noe lukker den, mens en selvmeldt rad gjelder så lenge den fornyes. Lukker samtidig de selvmeldte radene regelen allerede har erklært over, slik at historikken stemmer med det som vises. Diagnosen er ikke med og kan ikke leses gjennom noe api-objekt — den blir liggende i workflow.technical_incidents til Claude Code og ChatGPT. Krever admin-mandat.';

revoke execute on function api.technical_problem_board() from public;
grant execute on function api.technical_problem_board() to authenticated;

create function api.technical_problem_summary()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count integer;
begin
  -- Nøyaktig den samme grensen som api.technical_problem_board() — aktøren må
  -- finnes og ikke være trukket tilbake, og rollen må være gyldig nå. Det
  -- eneste som skiller de to, er hva som skjer når grensen ikke holder: her
  -- svares det stille, der avvises kallet. En svakere grense her ville betydd
  -- at en tilbaketrukket aktør med en rolletildeling som ennå ikke var utløpt,
  -- kunne lese tallet oversikten nekter dem.
  if workflow.active_actor_id() is null or not workflow.has_app_role('admin') then
    return jsonb_build_object('visible', false, 'unresolved', 0);
  end if;

  -- Den samme regelen som oversikten, og ingen skriving: tellingen leses av
  -- hver side for hver innlogget admin.
  select count(*) into v_count
  from workflow.technical_incidents ti
  where workflow.technical_incident_ongoing(ti);

  return jsonb_build_object('visible', true, 'unresolved', v_count);
end;
$$;

comment on function api.technical_problem_summary() is
  'Hvor mange uløste tekniske problemer som finnes, til merket i navigasjonen. Krever nøyaktig det samme som api.technical_problem_board(): en registrert, ikke-tilbaketrukket aktør med gyldig admin-rolle akkurat nå. Teller det samme som oversikten viser som pågående, og skriver ingenting: den leses av hver side for hver innlogget admin. Forskjellen på de to er bare hva som skjer når grensen ikke holder — her svares det stille «ikke synlig», framfor et avslag som ville blitt til en feilmelding på hver eneste side for hver eneste innlogget bruker som ikke er admin. Ingenting lekker av det: tallet er det eneste som finnes her, og det er null for alle andre.';

revoke execute on function api.technical_problem_summary() from public;
grant execute on function api.technical_problem_summary() to authenticated;
