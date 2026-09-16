-- ============================================================================
-- Migrasjon 011a — en autonom kjører over den eksterne agent-handoffen
--
-- Migrasjon 010c gjorde et vanlig KI-chatvindu til en støttet utfører av det
-- semantiske arbeidet: Antidep bygger oppgaven, et menneske laster den ned, gir
-- den til tjenesten, og laster svaret opp igjen. Den formen består. Den er
-- fallback når en planlagt kjøring er nede, den er nyttig ved feilsøking, og den
-- er veien inn for en KI-tjeneste som ikke har noen autonom integrasjon.
--
-- Eieren har besluttet at den ikke lenger skal være den primære arbeidsformen.
-- ChatGPT Business tilbyr nå planlagte Workspace Agents som kan bruke en privat
-- MCP-app, og da skal mennesket ut av transporten: Antidep legger arbeid i
-- databasen, den planlagte agenten henter det selv, utfører det og leverer
-- svaret tilbake gjennom nøyaktig den samme kontrollerte skriveveien.
--
-- ----------------------------------------------------------------------------
-- 1. Dette er en ny transport, ikke en ny agentarkitektur
--
-- Alt som avgjør noe fagligs, ligger allerede i 010c og under den: oppgaven
-- bygges av `workflow.agent_task`, avtrykket av `workflow.agent_task_digest`,
-- utførbarheten av `workflow.agent_task_problem`, og registreringen av de samme
-- interne skriveveiene agentkjørerne bruker. Denne migrasjonen legger til
-- nøyaktig tre ting:
--
--   en autentisert tilkobling   hvem den planlagte agenten er, registrert av et
--                               menneske med mandat, aldri av et agentsvar
--   et uttak                    en leie, slik at to planlagte kjøringer og et
--                               menneske ved flaten ikke gjør samme arbeid
--   en levering                 den samme importen, kalt med den leien
--
-- Importen er derfor flyttet ut i én intern funksjon som begge veiene kaller.
-- En kopi ville vært et andre sted å endre en regel, og den ene som ble glemt,
-- ville sluppet gjennom noe den andre stoppet — nøyaktig det argumentet
-- migrasjon 010c brukte da den flyttet syntese- og vurderingsregistreringen ut
-- av api-funksjonene sine.
--
-- Det følger av dette at MCP-veien strukturelt ikke kan få større faglige
-- skrivefullmakter enn nedlast/opplast-veien: de deler funksjonen som skriver.
--
-- ----------------------------------------------------------------------------
-- 2. Autorisasjonen ligger i databasen, ikke i MCP-serveren
--
-- Den private MCP-appen er en HTTP-flate. Den holder ingen databasehemmelighet,
-- ingen service_role-nøkkel og ingen editor-sesjon: den videresender det tokenet
-- kalleren la ved, og databasen avgjør hva det tokenet får gjøre. Serveren kan
-- derfor ikke gi seg selv mer enn tilkoblingen har, og en kompromittert server
-- er ikke en kompromittert database.
--
-- Hele OAuth-tilstanden — klienten, tilkoblingskoden, autorisasjonskoden,
-- access- og refresh-tokenet — ligger av samme grunn her, hashet. Et token i
-- klartekst finnes bare i det ene svaret som utsteder det.
--
-- Mennesket gjør én ting: en redaktør med mandat registrerer tilkoblingen og
-- henter én engangs tilkoblingskode fra agentarbeidsflaten. Koden er det som
-- beviser editor-mandat i det øyeblikket ChatGPT kobler seg til. Etterpå
-- godkjenner ingen noe per oppgave.
--
-- ----------------------------------------------------------------------------
-- 3. Modellidentiteten er fortsatt ikke agentens å bestemme
--
-- En planlagt Workspace Agent er ikke en modell. Den er en konfigurasjon som
-- kjører *en* modell, og plattformen viser ikke alltid hvilken. Tilkoblingen
-- bærer derfor to opplysninger som ikke er den samme: hvilken Workspace Agent
-- den er (`platform_agent_reference`), og om plattformen faktisk pinner/viser
-- modellen bak den (`platform_model_disclosure`).
--
-- Den semantiske modellidentiteten tildeles fortsatt på forhånd av en redaktør
-- (`api.assign_agent_role_model`), inngår i bindingen, og kontrolleres mot
-- svaret ved import. To roller kan strukturelt ikke dele modellidentitet, og
-- denne migrasjonen legger til den samme regelen ett hakk lenger ut: den samme
-- Workspace Agent-en kan ikke være kjører for to agentledd. Én konfigurasjon er
-- én modellruntime, og en kjeden der generatoren og vurderingen var den samme
-- agenten, ville vært egenverifikasjon med et ekstra ledd
-- (ANTIDEP_CONSTITUTION.md regel 3).
--
-- Er modellen ikke pinnet av plattformen, registreres det som `not_exposed` og
-- ikke som noe annet. Antidep hevder da ikke at separasjonen er bevist av
-- plattformen; den hviler på redaktørens tildeling, akkurat som i 010c, og det
-- står i proveniensen framfor i en antakelse.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 1-7
--   docs/DATABASE_ARCHITECTURE.md
--   docs/EVIDENCE_PIPELINE.md
--   docs/CHATGPT_WORKSPACE_AGENT.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Tilkoblingen
--
-- Én rad per planlagt ekstern kjører. Registrert av et menneske med
-- editor-mandat, bundet til nøyaktig ett agentledd, og mulig å trekke tilbake
-- uten en migrasjon.
-- ----------------------------------------------------------------------------
create type workflow.runner_model_disclosure as enum ('platform_pinned', 'not_exposed');

comment on type workflow.runner_model_disclosure is
  'Om plattformen kjøreren er konfigurert i, faktisk pinner og viser hvilken modell den kjører (platform_pinned), eller ikke gjør det (not_exposed). Verdien er en opplysning om plattformen og ikke om modellen: en kjører uten pinning kan gjøre arbeidet, men Antidep hevder da ikke at modellseparasjonen er bevist av plattformen (ANTIDEP_CONSTITUTION.md regel 3, 4).';

revoke usage on type workflow.runner_model_disclosure from public;

create table workflow.agent_runner_connections (
  id uuid primary key default gen_random_uuid(),

  connection_key text not null,
  display_name text not null,

  -- Ett ledd per tilkobling. Rollen er ikke et filter kalleren oppgir: den er
  -- tilkoblingens egen, satt av mennesket som registrerte den, og den er det
  -- eneste arbeidet tokenet noen gang kan få.
  agent_role provenance.agent_role not null,

  -- Hvilken Workspace Agent dette er, slik plattformen navngir den. Én
  -- konfigurasjon er én modellruntime, og den skal ikke kunne kjøre to ledd.
  platform_agent_reference text not null,
  platform_model_disclosure workflow.runner_model_disclosure not null,

  registered_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  registration_reason text not null,

  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  -- Venstresiden de to exclusion-reglene overlapper på, som i
  -- provenance.role_model_assignments. Aldri en verdi kalleren oppgir.
  validity tstzrange
    generated always as (tstzrange(valid_from, valid_to, '[)')) stored,
  revoked_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  revocation_reason text,

  created_at timestamptz not null default now(),
  -- Raden endres av tilbaketrekkingen, og bare av den. Kolonnen er signalet om
  -- at tabellen ikke er append-only, og den er databasens egen.
  updated_at timestamptz not null default now(),

  -- Nøkkelen er unik blant de GJELDENDE tilkoblingene, og ikke over all
  -- historikk. En tilbaketrukket tilkobling blir stående med sin periode, og en
  -- global unikhet ville derfor gjort tilbaketrekkingen til en blindvei: den
  -- dokumenterte gjenopprettingen — trekk tilbake, registrer på nytt — kunne
  -- ikke gjennomføres for det leddet igjen. Alle oppslag på nøkkelen leser
  -- allerede bare den gjeldende raden.
  constraint agent_runner_connections_one_live_key_excl
    exclude using gist (connection_key with =, validity with &&),
  -- Samme nøkkelform som provenance.actors.actor_key og
  -- provenance.agent_identities.identity_key: maskinlesbar og stabil.
  constraint agent_runner_connections_connection_key_format_check
    check (connection_key ~ '^[a-z0-9]+(?:[-.][a-z0-9]+)*:[a-z0-9]+(?:[-.][a-z0-9]+)*$'),
  constraint agent_runner_connections_display_name_check
    check (display_name = btrim(display_name) and length(display_name) between 1 and 200),
  constraint agent_runner_connections_platform_reference_check
    check (platform_agent_reference = btrim(platform_agent_reference)
           and length(platform_agent_reference) between 1 and 200),
  constraint agent_runner_connections_registration_reason_check
    check (registration_reason = btrim(registration_reason)
           and length(registration_reason) between 1 and 2000),
  constraint agent_runner_connections_revocation_shape_check
    check ((valid_to is null) = (revoked_by_actor_id is null)
           and (valid_to is null) = (revocation_reason is null)),
  constraint agent_runner_connections_revocation_reason_check
    check (revocation_reason is null
           or (revocation_reason = btrim(revocation_reason)
               and length(revocation_reason) between 1 and 2000)),
  constraint agent_runner_connections_validity_order_check
    check (valid_to is null or valid_to > valid_from),

  -- Ett agentledd har høyst én gjeldende autonom kjører. To ville gjort «hvem
  -- henter arbeidet i dette leddet» til et spørsmål med to svar, og en
  -- tilbaketrekking ville ikke vært en tilbaketrekking.
  constraint agent_runner_connections_one_live_per_role_excl
    exclude using gist (agent_role with =, validity with &&),

  -- Og den samme Workspace Agent-en kan ikke kjøre to agentledd i overlappende
  -- tid. Én konfigurasjon er én modellruntime, og en kjede der den samme
  -- agenten både laget innholdet og vurderte det, ville vært egenverifikasjon
  -- med et ekstra ledd (ANTIDEP_CONSTITUTION.md regel 3).
  constraint agent_runner_connections_one_role_per_agent_excl
    exclude using gist (platform_agent_reference with =, validity with &&)
);

comment on table workflow.agent_runner_connections is
  'Én registrert autonom kjører av eksternt agentarbeid — i praksis én planlagt ChatGPT Workspace Agent koblet til Antideps private MCP-app (ANTIDEP_CONSTITUTION.md regel 3, 7). Registreres av et menneske med editor-mandat og aldri av et agentsvar: en kjører som kunne registrere seg selv, ville etablert premisset som autoriserte den. Bundet til nøyaktig ett agentledd, slik at tokenet aldri kan få annet arbeid enn det leddet.';
comment on column workflow.agent_runner_connections.agent_role is
  'Agentleddet denne kjøreren utfører, og det eneste den noen gang kan få arbeid i. Rollen er tilkoblingens egen og ikke et filter kalleren oppgir.';
comment on column workflow.agent_runner_connections.platform_agent_reference is
  'Hvilken Workspace Agent dette er, slik plattformen navngir den. Én konfigurasjon er én modellruntime: den samme agenten kan derfor ikke være kjører for to agentledd samtidig, for da ville generatoren og kontrollen vært den samme (ANTIDEP_CONSTITUTION.md regel 3).';
comment on column workflow.agent_runner_connections.platform_model_disclosure is
  'Om plattformen faktisk pinner og viser modellen bak kjøreren. not_exposed er en sann opplysning og ikke en mangel som skal skjules: separasjonen hviler da på redaktørens egen modelltildeling, som i den manuelle handoffen, og Antidep hevder ikke at plattformen har bevist den.';

alter table workflow.agent_runner_connections enable row level security;

comment on column workflow.agent_runner_connections.validity is
  'Gyldighetsperioden som et intervall, generert av valid_from og valid_to. Finnes fordi de to exclusion-reglene trenger en venstreside å overlappe på.';

create trigger agent_runner_connections_set_row_timestamps
  before insert or update on workflow.agent_runner_connections
  for each row execute function catalog.set_row_timestamps();

-- Identiteten skrives aldri om. Bare tilbaketrekkingen kan endre raden, og den
-- er en avslutning med hvem og hvorfor.
create function workflow.freeze_agent_runner_connection()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.connection_key is distinct from old.connection_key
     or new.agent_role is distinct from old.agent_role
     or new.platform_agent_reference is distinct from old.platform_agent_reference
     or new.platform_model_disclosure is distinct from old.platform_model_disclosure
     or new.registered_by_actor_id is distinct from old.registered_by_actor_id
     or new.valid_from is distinct from old.valid_from
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En registrert kjørertilkobling kan ikke skrives om.',
      hint = 'Skal noe av dette endres, trekkes tilkoblingen tilbake med api.revoke_agent_runner(text, text) og en ny registreres. En identitet som kunne flyttes i ettertid, ville ikke vært noen beskyttelse.';
  end if;
  if old.valid_to is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Tilkoblingen er allerede trukket tilbake.';
  end if;
  -- En tilbaketrekking kan ikke dateres fram i tid.
  --
  -- Regelen gjør `valid_to is null` til det samme som «gjeldende», og det er
  -- nettopp den likheten sikkerhetsveiene hviler på: de avgjør gyldigheten av
  -- at feltet er tomt, framfor å sammenligne med en klokke. En sammenligning
  -- ville vært frosset til tidspunktet SETNINGEN startet, og en tilbaketrekking
  -- som ble ferdig mens kallet ventet på radlåsen, ville dermed vært usynlig for
  -- den — kallet ville autentisert seg mot en tilkobling som ikke finnes lenger.
  if new.valid_to is not null and new.valid_to > statement_timestamp() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En tilbaketrekking kan ikke dateres fram i tid.',
      hint = 'Sikkerhetsveiene leser «gjeldende» som valid_to is null. En framtidsdatert avslutning ville gjort en tilkobling gjeldende og avsluttet på samme tid.';
  end if;
  return new;
end;
$$;

comment on function workflow.freeze_agent_runner_connection() is
  'Lar bare tilbaketrekkingen endre en registrert kjørertilkobling (ANTIDEP_CONSTITUTION.md regel 7). Identiteten — nøkkelen, rollen, Workspace Agent-en og eksponeringsgraden — er uforanderlig, og en allerede tilbaketrukket tilkobling kan ikke gjenåpnes. En tilbaketrekking kan heller ikke dateres fram i tid: det er den regelen som gjør «valid_to is null» til det samme som «gjeldende», og sikkerhetsveiene avgjør gyldigheten av nettopp det framfor av en klokke som er frosset til setningens starttid.';

revoke execute on function workflow.freeze_agent_runner_connection() from public;

create trigger agent_runner_connections_are_frozen
  before update on workflow.agent_runner_connections
  for each row execute function workflow.freeze_agent_runner_connection();

create trigger agent_runner_connections_are_not_deleted
  before delete on workflow.agent_runner_connections
  for each row execute function knowledge.reject_append_only_mutation(
    'En kjørertilkobling som har hentet arbeid, er en del av proveniensen. Den trekkes tilbake, og slettes aldri.'
  );

-- ----------------------------------------------------------------------------
-- 2. OAuth-klienten
--
-- MCP-autorisasjonen krever at klienten kan registrere seg selv (RFC 7591).
-- Registreringen gir ingen tilgang i det hele tatt: en klient uten en innløst
-- tilkoblingskode kan ikke få et eneste token. Den er en adressebok over
-- redirect-URI-er, og det er hele beskyttelsesverdien.
-- ----------------------------------------------------------------------------
-- Adressekravet som en egen regel, fordi en check constraint ikke kan bære en
-- subquery. Den står her og ikke i to kopier: registreringen og constrainten
-- skal ikke kunne bli uenige om hva en lovlig redirect-adresse er.
create function workflow.agent_runner_redirect_uris_are_valid(p_uris text[])
  returns boolean
  language sql
  immutable
  set search_path = ''
as $$
  select coalesce(
    cardinality(p_uris) between 1 and 8
    and not exists (
      select 1 from unnest(p_uris) as u(uri)
      where u.uri !~ '^https://[^\s?#]+'
        and u.uri !~ '^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?(/[^\s]*)?$'
    ),
    false);
$$;

comment on function workflow.agent_runner_redirect_uris_are_valid(text[]) is
  'Om en klients redirect-adresser er lovlige: mellom én og åtte, og alle https — med unntak for loopback, som MCP-inspektøren og lokal feilsøking trenger. Egen funksjon fordi en check constraint ikke kan bære en subquery, og fordi registreringen og constrainten ikke skal kunne bli uenige om hva en lovlig adresse er.';

revoke execute on function workflow.agent_runner_redirect_uris_are_valid(text[]) from public;

create table workflow.agent_runner_clients (
  id uuid primary key default gen_random_uuid(),

  client_id text not null,
  client_name text not null,
  redirect_uris text[] not null,

  created_at timestamptz not null default now(),

  constraint agent_runner_clients_client_id_key unique (client_id),
  constraint agent_runner_clients_client_id_format_check
    check (client_id ~ '^[0-9a-f]{32,128}$'),
  constraint agent_runner_clients_client_name_check
    check (client_name = btrim(client_name) and length(client_name) between 1 and 200),
  constraint agent_runner_clients_redirect_uris_check
    check (workflow.agent_runner_redirect_uris_are_valid(redirect_uris))
);

comment on table workflow.agent_runner_clients is
  'OAuth-klienter som har registrert seg mot Antideps private MCP-app (RFC 7591). Registreringen gir ingen tilgang: uten en innløst tilkoblingskode fra en redaktør med mandat kan en klient ikke få et eneste token. Redirect-URI-ene er den eneste opplysningen som faktisk brukes til noe — en autorisasjonskode utstedes bare til en URI klienten registrerte på forhånd, slik at koden ikke kan omdirigeres et annet sted.';
comment on column workflow.agent_runner_clients.redirect_uris is
  'Adressene en autorisasjonskode kan leveres til. Bare https, med unntak for loopback, som MCP-inspektøren og lokal feilsøking trenger.';

alter table workflow.agent_runner_clients enable row level security;

create trigger agent_runner_clients_set_created_at
  before insert on workflow.agent_runner_clients
  for each row execute function catalog.set_created_at();

create trigger agent_runner_clients_are_append_only
  before update or delete on workflow.agent_runner_clients
  for each row execute function knowledge.reject_append_only_mutation(
    'En registrert OAuth-klient er en adresse et token en gang ble utstedt til. Den skrives ikke om.'
  );

-- ----------------------------------------------------------------------------
-- 3. Hemmelighetene
--
-- Fire former, én tabell, og aldri klartekst. Verdien finnes bare i det ene
-- svaret som utsteder den; det som blir liggende, er et fingeravtrykk. En
-- database som lekket, ville dermed ikke lekket et eneste brukbart token.
--
--   pairing_code         engangskoden en redaktør henter i Antidep-flaten og
--                        limer inn når ChatGPT kobler seg til. Den er beviset
--                        på editor-mandat i tilkoblingsøyeblikket.
--   authorization_code   OAuth-koden, bundet til klient, redirect-URI og
--                        PKCE-utfordringen. Lever i sekunder.
--   access_token         det tokenet hvert MCP-kall bærer.
--   refresh_token        fornyelsen, som roteres: den brukte byttes alltid ut.
-- ----------------------------------------------------------------------------
create type workflow.agent_runner_secret_kind as enum
  ('pairing_code', 'authorization_code', 'access_token', 'refresh_token');

comment on type workflow.agent_runner_secret_kind is
  'Hvilken av de fire hemmelighetene i den autonome kjørerens tilkoblingsflyt en rad bærer fingeravtrykket av. Formen inngår i fingeravtrykket, slik at et token av én form aldri kan leses som et av en annen.';

revoke usage on type workflow.agent_runner_secret_kind from public;

create table workflow.agent_runner_secrets (
  id uuid primary key default gen_random_uuid(),

  kind workflow.agent_runner_secret_kind not null,
  secret_hash text not null,

  connection_id uuid not null
    references workflow.agent_runner_connections (id) on update restrict on delete restrict,
  client_id text
    references workflow.agent_runner_clients (client_id) on update restrict on delete restrict,

  redirect_uri text,
  code_challenge text,

  -- Hvilken MCP-server hemmeligheten gjelder for (RFC 8707).
  --
  -- Et token uten publikum passer overalt. Med publikum kan Antidep avvise et
  -- token som ble utstedt for en annen tjeneste, og en tjeneste som tar imot
  -- andres tokens, er nettopp den forvirrede stedfortrederen MCP-spesifikasjonen
  -- krever at en server ikke skal være (2026-07-28, «Token Handling»).
  resource text,

  -- Hvem som satte kjeden i gang. Bare tilkoblingskoden har en: de tre andre
  -- utledes av den, og et menneske er aldri involvert i dem.
  issued_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  parent_id uuid
    references workflow.agent_runner_secrets (id) on update restrict on delete restrict,

  expires_at timestamptz not null,
  consumed_at timestamptz,
  revoked_at timestamptz,

  created_at timestamptz not null default now(),
  -- Raden endres når hemmeligheten brukes eller trekkes tilbake, og bare da.
  updated_at timestamptz not null default now(),

  constraint agent_runner_secrets_secret_hash_key unique (secret_hash),
  constraint agent_runner_secrets_secret_hash_format_check
    check (secret_hash ~ '^sha256-v1:[0-9a-f]{64}$'),
  -- Tilkoblingskoden er den ene formen et menneske utsteder, og den eneste som
  -- ikke tilhører en OAuth-klient. De tre andre gjør begge deler motsatt.
  constraint agent_runner_secrets_pairing_shape_check
    check (
      case kind
        when 'pairing_code' then
          issued_by_actor_id is not null and client_id is null
          and redirect_uri is null and code_challenge is null and parent_id is null
          -- Tilkoblingskoden er ikke et token og har intet publikum: den beviser
          -- bare at et menneske med editor-mandat ville denne tilkoblingen.
          and resource is null
        when 'authorization_code' then
          issued_by_actor_id is null and client_id is not null
          and redirect_uri is not null and code_challenge is not null
          and resource is not null
        else
          issued_by_actor_id is null and client_id is not null
          and redirect_uri is null and code_challenge is null
          and resource is not null
      end
    ),
  -- PKCE er påkrevd og alltid S256: en kode utstedt mot en ren tekst-utfordring
  -- ville vært en kode uten PKCE i praksis.
  constraint agent_runner_secrets_code_challenge_format_check
    check (code_challenge is null or code_challenge ~ '^[A-Za-z0-9_-]{43}$'),
  -- Den kanoniske formen RFC 8707 og RFC 9728 beskriver: en absolutt adresse,
  -- uten fragment. En verdi med fragment ville vært to adresser som så like ut.
  constraint agent_runner_secrets_resource_format_check
    check (
      resource is null
      or (resource ~ '^https?://[^\s#]+$' and length(resource) between 8 and 300)
    ),
  constraint agent_runner_secrets_expiry_check
    check (expires_at > created_at),
  constraint agent_runner_secrets_consumed_check
    check (consumed_at is null or consumed_at >= created_at)
);

comment on table workflow.agent_runner_secrets is
  'Fingeravtrykkene av tilkoblingskoden, autorisasjonskoden, access-tokenet og refresh-tokenet i den autonome kjørerens tilkoblingsflyt (ANTIDEP_CONSTITUTION.md regel 7). Aldri klartekst: verdien finnes bare i det ene svaret som utsteder den, og en database som lekket, ville ikke lekket et brukbart token. Hver rad har en utløpstid, og de tre engangsformene bæres av consumed_at — en kode som er brukt, er brukt.';
comment on column workflow.agent_runner_secrets.parent_id is
  'Hvilken hemmelighet denne ble utledet av: autorisasjonskoden av tilkoblingskoden, tokenparet av autorisasjonskoden, og det fornyede paret av det forrige refresh-tokenet. Kjeden gjør det mulig å se hvor en tilgang faktisk kom fra, og å trekke hele grenen tilbake i ett.';
comment on column workflow.agent_runner_secrets.code_challenge is
  'PKCE-utfordringen (S256, base64url) autorisasjonskoden er bundet til. Uten den kunne en avlyttet kode innløses av en annen enn den som ba om den.';
comment on column workflow.agent_runner_secrets.resource is
  'Den kanoniske adressen til MCP-serveren hemmeligheten gjelder for (RFC 8707, MCP 2026-07-28 «Token Handling»). Følger hele kjeden: klienten oppgir den i autorisasjonsforespørselen, den samme må oppgis når koden veksles inn, og den arves av tokenparet. MCP-serveren godtar bare et token som bærer nettopp dens egen adresse, slik at et token utstedt for en annen tjeneste ikke kan brukes her. NULL bare for tilkoblingskoden, som ikke er et token.';

alter table workflow.agent_runner_secrets enable row level security;

create index agent_runner_secrets_connection_idx
  on workflow.agent_runner_secrets (connection_id, kind, expires_at desc);

create trigger agent_runner_secrets_set_row_timestamps
  before insert or update on workflow.agent_runner_secrets
  for each row execute function catalog.set_row_timestamps();

-- Bare bruken og tilbaketrekkingen kan endre raden. Et fingeravtrykk som kunne
-- skrives om, ville gjort «denne koden er brukt» til noe som lot seg angre.
create function workflow.freeze_agent_runner_secret()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.kind is distinct from old.kind
     or new.secret_hash is distinct from old.secret_hash
     or new.connection_id is distinct from old.connection_id
     or new.client_id is distinct from old.client_id
     or new.redirect_uri is distinct from old.redirect_uri
     or new.code_challenge is distinct from old.code_challenge
     -- Publikumet er en del av det som ble utstedt, ikke en etikett på det.
     -- Uten dette kunne en oppdatering pekt et allerede utstedt token mot en
     -- annen MCP-server, og raden ville beskrevet en annen binding enn den som
     -- faktisk ble gitt (RFC 8707).
     or new.resource is distinct from old.resource
     or new.issued_by_actor_id is distinct from old.issued_by_actor_id
     or new.parent_id is distinct from old.parent_id
     or new.expires_at is distinct from old.expires_at
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En utstedt hemmelighet kan ikke skrives om.';
  end if;
  if old.consumed_at is not null and new.consumed_at is distinct from old.consumed_at then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Hemmeligheten er allerede brukt.';
  end if;
  return new;
end;
$$;

comment on function workflow.freeze_agent_runner_secret() is
  'Lar bare bruken (consumed_at) og tilbaketrekkingen (revoked_at) endre en utstedt hemmelighet, og bare én gang for bruken. Uten regelen ville «denne koden er brukt» vært noe som lot seg angre, og en engangskode ville ikke vært en engangskode. Publikumet (resource) er med blant de frosne feltene: det er en del av det som ble utstedt, og en oppdatering som kunne peke et allerede utstedt token mot en annen MCP-server, ville latt raden beskrive en annen binding enn den som faktisk ble gitt.';

revoke execute on function workflow.freeze_agent_runner_secret() from public;

create trigger agent_runner_secrets_are_frozen
  before update on workflow.agent_runner_secrets
  for each row execute function workflow.freeze_agent_runner_secret();

create trigger agent_runner_secrets_are_not_deleted
  before delete on workflow.agent_runner_secrets
  for each row execute function knowledge.reject_append_only_mutation(
    'Et utstedt token er en tilgang som en gang fantes. Det trekkes tilbake, og slettes aldri.'
  );

-- ----------------------------------------------------------------------------
-- 4. Sporet
--
-- Nok til å forstå hvorfor autonomien stoppet, og ikke ett tegn mer. Ingen
-- fulltekst, ingen modellsvar, ingen tokens: raden bærer verktøynavnet, en
-- ugjennomsiktig jobbidentifikator, rollen, utfallsklassen og tidspunktet.
--
-- Utfallsklassene er forskjellige med vilje. «Ingen arbeid» og «faglig blokkert»
-- ser like ut i en logg som bare teller feil, og de er ikke det samme: den ene
-- er en normal kjøring, den andre er noe som venter på et menneske
-- (ANTIDEP_CONSTITUTION.md regel 4).
-- ----------------------------------------------------------------------------
create type workflow.agent_runner_outcome as enum (
  'ok',
  'no_work',
  'blocked',
  'stale_task',
  'wrong_role',
  'lease_lost',
  'rejected',
  'approval_blocked',
  'server_error'
);

comment on type workflow.agent_runner_outcome is
  'Utfallsklassen for ett MCP-kall fra en autonom kjører. ok = kallet gjorde det det skulle. no_work = køen var tom, som er en normal kjøring og ikke en feil. blocked = oppgaven finnes, men noe faglig hindrer den. stale_task = oppgavehåndtaket gjelder ikke lenger. wrong_role = arbeidet hører til et annet agentledd. lease_lost = uttaket er overtatt eller utløpt. rejected = svaret ble avvist av den autoritative kontrollen. approval_blocked = plattformen krevde en godkjenning kjøringen ikke kunne få. server_error = teknisk feil i MCP-laget. Klassene er forskjellige fordi de krever forskjellige tiltak (ANTIDEP_CONSTITUTION.md regel 4).';

revoke usage on type workflow.agent_runner_outcome from public;

create table workflow.agent_runner_events (
  id uuid primary key default gen_random_uuid(),

  connection_id uuid not null
    references workflow.agent_runner_connections (id) on update restrict on delete restrict,
  tool_name text not null,
  agent_role provenance.agent_role,
  pipeline_job_id uuid
    references workflow.pipeline_jobs (id) on update restrict on delete restrict,
  outcome workflow.agent_runner_outcome not null,

  -- Hvem raden kommer fra, og dermed hva den er verdt som bevis.
  --
  -- `false`: raden ble skrevet AV operasjonen den handler om, i den samme
  -- transaksjonen som arbeidet. Da kan den ikke stå der uten at operasjonen
  -- faktisk skjedde, og den er autoritativ.
  --
  -- `true`: kjøreren meldte selv fra om et kall som ikke kunne skrive sitt eget
  -- spor. Den sier hva kjøreren SA, ikke hva databasen SÅ. Skillet står i
  -- raden framfor i et dokument, fordi en tokeninnehaver kan kalle
  -- api.record_agent_runner_outcome direkte — og da skal raden bære at den er
  -- en selvmelding.
  self_reported boolean not null default false,

  -- Én kort setning Antidep selv skriver, aldri en videreformidlet feiltekst og
  -- aldri noe som kommer fra en kilde eller en modell.
  note text,

  created_at timestamptz not null default now(),

  constraint agent_runner_events_tool_name_check
    check (tool_name = btrim(tool_name) and length(tool_name) between 1 and 80),
  constraint agent_runner_events_note_check
    check (note is null or (note = btrim(note) and length(note) between 1 and 300))
);

comment on table workflow.agent_runner_events is
  'Ett spor per MCP-kall fra en autonom kjører (ANTIDEP_CONSTITUTION.md regel 4, 7). Bærer verktøynavnet, jobben, rollen og utfallsklassen — og aldri kildetekst, aldri et modellsvar, aldri et token. Finnes for at «hvorfor stoppet autonomien» skal kunne besvares uten å lese noe privat.';
comment on column workflow.agent_runner_events.note is
  'Én kort setning Antidep selv skriver. Aldri en videreformidlet feiltekst: en avvisning kan navngi en påstand eller et kildeutdrag, og et spor skal ikke bli et sted privat innhold samler seg.';

alter table workflow.agent_runner_events enable row level security;

create index agent_runner_events_connection_idx
  on workflow.agent_runner_events (connection_id, created_at desc);

create trigger agent_runner_events_set_created_at
  before insert on workflow.agent_runner_events
  for each row execute function catalog.set_created_at();

create trigger agent_runner_events_are_append_only
  before update or delete on workflow.agent_runner_events
  for each row execute function knowledge.reject_append_only_mutation(
    'Sporet etter en kjøring skrives ikke om.'
  );

-- ----------------------------------------------------------------------------
-- 5. Hemmelighetene, lest og skrevet med de samme reglene overalt
-- ----------------------------------------------------------------------------

-- 244 bit fra databasens egen CSPRNG. Verdien forlater databasen én gang, i det
-- svaret som utsteder den, og finnes aldri lagret i klartekst.
create function workflow.new_agent_runner_secret()
  returns text
  language sql
  volatile
  set search_path = ''
as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
$$;

comment on function workflow.new_agent_runner_secret() is
  'En ny hemmelighet på 64 heksadesimale tegn fra databasens egen tilfeldighetskilde. Genereres her og ikke av kalleren, slik at hverken MCP-serveren eller en klient kan velge verdien og dermed gjette den.';

create function workflow.agent_runner_secret_hash(
  p_kind workflow.agent_runner_secret_kind,
  p_secret text
)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case
    when p_secret is null or p_kind is null then null
    else 'sha256-v1:' || encode(
      sha256(convert_to(p_kind::text || ':' || p_secret, 'UTF8')), 'hex')
  end;
$$;

comment on function workflow.agent_runner_secret_hash(workflow.agent_runner_secret_kind, text) is
  'Fingeravtrykket av en hemmelighet, med formen som en del av avtrykket. Formen står med fordi et refresh-token og et access-token ellers ville hatt samme avtrykk — og det ene ville kunnet brukes som det andre.';

revoke execute on function workflow.new_agent_runner_secret() from public;
revoke execute on function workflow.agent_runner_secret_hash(workflow.agent_runner_secret_kind, text) from public;

-- Ett svar på enhver mislykket autentisering.
--
-- Samme form som provenance.reject_agent_authentication(): et token som ikke
-- finnes, et som er utløpt og et som er trukket tilbake skal ikke kunne skilles
-- fra hverandre utenfra, for forskjellen ville vært et orakel.
create function workflow.reject_agent_runner_authentication()
  returns void
  language plpgsql
  immutable
  set search_path = ''
as $$
begin
  raise exception using
    errcode = 'insufficient_privilege',
    message = 'Tilkoblingen er ikke autentisert.',
    hint = 'Tokenet finnes ikke, er utløpt eller er trukket tilbake. Koble Antidep-appen til på nytt med en ny tilkoblingskode fra agentarbeidsflaten.';
end;
$$;

comment on function workflow.reject_agent_runner_authentication() is
  'Ett og samme svar på enhver mislykket autentisering av en autonom kjører. Et token som ikke finnes, et som er utløpt og et som er trukket tilbake skal ikke kunne skilles fra hverandre utenfra; forskjellen ville vært et orakel.';

revoke execute on function workflow.reject_agent_runner_authentication() from public;

-- Tokenet lest som en tilkobling, eller et avslag.
create function workflow.authenticated_runner_connection(
  p_access_token text,
  p_resource text
)
  returns workflow.agent_runner_connections
  language plpgsql
  -- volatile, ikke stable: kallet tar en radlås, og en lås er en skrivning.
  volatile
  set search_path = ''
as $$
declare
  v_connection workflow.agent_runner_connections;
  v_resource text;
begin
  if p_access_token is null then
    perform workflow.reject_agent_runner_authentication();
  end if;
  -- Publikumet er ikke valgfritt, og har ingen standardverdi.
  --
  -- Med `default null` ville kontrollen bare vært kjørt av de kallerne som
  -- husket å oppgi den — og de kontrollerte veiene er gitt til `anon`, så en som
  -- holder et token, kunne kalt Data API-et direkte uten den og sluppet forbi.
  -- Autorisasjonen ligger i databasen og ikke i serveren; da må den gjelde
  -- uansett hvem som kaller (ANTIDEP_CONSTITUTION.md regel 7).
  v_resource := workflow.assert_agent_runner_resource(p_resource);

  -- Alle betingelsene i ett predikat, med ett svar: rekkefølgen skal ikke bli
  -- et implisitt valg med sin egen observerbare oppførsel. Publikum er en av
  -- dem: et token utstedt for en annen tjeneste skal ikke virke her, uansett
  -- hvor gyldig det er der det hører hjemme (RFC 8707).
  -- Gyldigheten avgjøres av at raden er GJELDENDE, ikke av en klokke.
  --
  -- `statement_timestamp()` er frosset til tidspunktet setningen startet — og
  -- inne i en funksjon til det øverste kallet. En sammenligning mot den ville
  -- derfor svart på «var tilkoblingen gjeldende da kallet mitt begynte», og det
  -- er feil spørsmål etter at kallet har ventet på en lås: en tilbaketrekking
  -- som ble ferdig i mellomtiden, fikk et `valid_to` som er SENERE enn den
  -- frosne klokka, og ville sett gjeldende ut for nettopp det kallet den skulle
  -- stenge ute. Med `valid_to is null` er det den oppdaterte raden selv som
  -- svarer, og den sier nei.
  --
  -- Delt lås på tilkoblingsraden, og den holdes ut hele kallet.
  --
  -- Uten den var autentiseringen en lesning av et øyeblikk: en tilbaketrekking
  -- kunne bli ferdig ETTER at kallet hadde autentisert seg, men FØR det tok en
  -- oppgave — og uttaket som fulgte, ble ikke frigitt av tilbaketrekkingen, som
  -- allerede var forbi. Oppgaven ville da stått som opptatt av en kjører som
  -- aldri kommer tilbake, helt til leien løp ut.
  --
  -- Delt, ikke eksklusiv: flere planlagte kjøringer på den samme tilkoblingen
  -- skal kunne arbeide samtidig. Det er tilbaketrekkingen som må vente, fordi
  -- det er den som gjør tilstanden om — og når den slipper til, ser den uttaket
  -- som ble tatt i mellomtiden og frigir det. Kommer den først, treffer
  -- vilkårene her ingenting, og kallet blir avvist som det skal.
  select c.* into v_connection
  from workflow.agent_runner_secrets s
  join workflow.agent_runner_connections c on c.id = s.connection_id
  where s.kind = 'access_token'
    and s.secret_hash = workflow.agent_runner_secret_hash('access_token', p_access_token)
    and s.revoked_at is null
    and s.expires_at > statement_timestamp()
    and s.resource = v_resource
    and c.valid_from <= statement_timestamp()
    and c.valid_to is null
  for share of c;

  if v_connection.id is null then
    perform workflow.reject_agent_runner_authentication();
  end if;

  return v_connection;
end;
$$;

comment on function workflow.authenticated_runner_connection(text, text) is
  'Tilkoblingen et access-token tilhører, eller et avslag (ANTIDEP_CONSTITUTION.md regel 7). Kontrollerer tokenets gyldighet, publikumet og tilkoblingens gyldighet i ett predikat, på kallets eget tidspunkt, slik at en tilbaketrekking virker umiddelbart. p_resource er den kanoniske adressen kalleren bruker tokenet mot, og er PÅKREVD uten standardverdi: med en standardverdi ville publikumskontrollen bare vært kjørt av de kallerne som husket å oppgi den, og de kontrollerte veiene er gitt til anon — en som holder et token, kunne kalt Data API-et direkte uten den og sluppet forbi (RFC 8707, MCP 2026-07-28 «Token Handling»). Returnerer aldri noe delvis: en kaller som kommer forbi denne, har en gyldig tilkobling med en rolle. Tar en delt lås på tilkoblingsraden og holder den ut kallet, slik at en tilbaketrekking ikke kan bli ferdig mellom autentiseringen og arbeidet: uttaket som fulgte, ville ikke blitt frigitt av en tilbaketrekking som allerede var forbi.';

revoke execute on function workflow.authenticated_runner_connection(text, text) from public;

-- Den ugjennomsiktige oppgavehenvisningen.
--
-- Køen skal kunne vise hva som venter uten å gi modellen en databaseidentitet.
-- Henvisningen er derfor utledet av jobben OG tilkoblingen: den er stabil for
-- den ene kjøreren, og den samme jobben ser forskjellig ut for en annen.
create function workflow.agent_runner_task_ref(p_connection_id uuid, p_pipeline_job_id uuid)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select 'task_' || left(
    encode(sha256(convert_to(
      p_connection_id::text || ':' || p_pipeline_job_id::text, 'UTF8')), 'hex'), 24)
$$;

comment on function workflow.agent_runner_task_ref(uuid, uuid) is
  'En ugjennomsiktig henvisning til én ventende oppgave, utledet av jobben og tilkoblingen. Modellen trenger ikke en databaseidentitet for å velge neste oppgave, og en henvisning den ikke kan regne ut selv, kan den heller ikke manipulere seg til en annen jobb med. Er den likevel gjettet feil, finner uttaket ingen jobb — og svarer med det framfor å ta en annen.';

revoke execute on function workflow.agent_runner_task_ref(uuid, uuid) from public;

-- Sporet, skrevet ett sted.
create function workflow.record_agent_runner_event(
  p_connection_id uuid,
  p_tool_name text,
  p_outcome workflow.agent_runner_outcome,
  p_agent_role provenance.agent_role default null,
  p_pipeline_job_id uuid default null,
  p_note text default null,
  p_self_reported boolean default false
)
  returns void
  language sql
  volatile
  set search_path = ''
as $$
  insert into workflow.agent_runner_events
    (connection_id, tool_name, agent_role, pipeline_job_id, outcome, note, self_reported)
  values (p_connection_id, p_tool_name, p_agent_role, p_pipeline_job_id, p_outcome,
          nullif(btrim(coalesce(p_note, '')), ''), coalesce(p_self_reported, false));
$$;

comment on function workflow.record_agent_runner_event(uuid, text, workflow.agent_runner_outcome, provenance.agent_role, uuid, text, boolean) is
  'Skriver ett spor etter ett MCP-kall. Notatet er Antideps egen korte setning og aldri en videreformidlet feiltekst: en avvisning kan navngi en påstand eller et kildeutdrag, og sporet skal ikke bli et sted privat innhold samler seg. p_self_reported skiller raden operasjonen selv skrev, fra den kjøreren meldte inn etterpå.';

revoke execute on function workflow.record_agent_runner_event(uuid, text, workflow.agent_runner_outcome, provenance.agent_role, uuid, text, boolean) from public;

-- ----------------------------------------------------------------------------
-- 6. Utførbarheten, sett fra innsiden av et uttak
--
-- `workflow.agent_task_problem(workflow.pipeline_jobs)` er den ene regelen køen,
-- uttaket og importen leser, og den avviser en jobb med en løpende leie og en
-- jobb som har brukt opp forsøkene sine. Begge er riktige for en kaller som står
-- UTENFOR et uttak.
--
-- En autonom kjører som allerede HOLDER leien, står innenfor: leien er dens
-- egen, og forsøket er allerede talt og lovlig. Uten dette skillet ville en
-- kjører blitt avvist av sitt eget uttak, og siste tillatte forsøk ville aldri
-- kunnet fullføres.
--
-- Regelen er den samme; det er bare den ene kalleren som er unntatt fra de to
-- vilkårene som handler om nettopp uttaket. Den gamle signaturen delegerer hit,
-- slik at det fortsatt finnes én implementasjon.
-- ----------------------------------------------------------------------------
create function workflow.agent_task_problem(
  p_job workflow.pipeline_jobs,
  p_holding_lease_token uuid
)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
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
$$;

comment on function workflow.agent_task_problem(workflow.pipeline_jobs, uuid) is
  'Én setning om hva som hindrer at oppgaven kan besvares nå, eller NULL — med det ene unntaket at kalleren som HOLDER den løpende leien, ikke avvises av sin egen leie eller av et forsøk som allerede er talt (ANTIDEP_CONSTITUTION.md regel 4). Uten skillet ville en autonom kjører blitt avvist av sitt eget uttak i det øyeblikket den leverte svaret, og siste tillatte forsøk aldri kunnet fullføres. Alle andre vilkår er nøyaktig de samme, og de står bare ett sted.';

revoke execute on function workflow.agent_task_problem(workflow.pipeline_jobs, uuid) from public;

create or replace function workflow.agent_task_problem(p_job workflow.pipeline_jobs)
  returns text
  language sql
  stable
  set search_path = ''
as $$
  select workflow.agent_task_problem(p_job, null::uuid)
$$;

comment on function workflow.agent_task_problem(workflow.pipeline_jobs) is
  'Én setning om hva som hindrer at oppgaven kan besvares nå, sett fra utsiden av ethvert uttak. Køen (api.agent_work_queue()), uttaket (api.agent_task_payload(uuid)) og den manuelle importen (api.import_agent_answer(uuid, jsonb)) leser denne, slik at de tre ikke kan bli uenige om hvilke jobber som faktisk er utførbare handoff-oppgaver. Fra migrasjon 011a er den et kall til workflow.agent_task_problem(workflow.pipeline_jobs, uuid) med NULL: én implementasjon, to kallere.';

revoke execute on function workflow.agent_task_problem(workflow.pipeline_jobs) from public;

-- ----------------------------------------------------------------------------
-- 7. Én skrivevei, to transporter
--
-- Importen fra migrasjon 010c flyttes ordrett ut i en intern funksjon. Den
-- manuelle veien og den autonome kjøreren kaller den samme koden, med de samme
-- constraintene, de samme gatene og det samme auditsporet. En kopi ville vært et
-- andre sted å endre en regel, og den ene som ble glemt, ville sluppet gjennom
-- noe den andre stoppet.
--
-- Det følger av dette at MCP-veien strukturelt ikke kan få større faglige
-- skrivefullmakter enn nedlast/opplast-veien.
--
-- To ting skiller kallerne, og bare to: hvem som er autentisert, og om kalleren
-- allerede holder et uttak. Alt annet er felles.
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- 6b. Uttaket vet hvilken kjører som holder det
--
-- Leieholderen på workflow.pipeline_jobs er agentidentiteten, og den er PER
-- ROLLE: to kjørere i det samme leddet deler den. Da kan ingen av dem skilles
-- fra den andre på raden, og det får to følger som begge er feil.
--
-- Den ene: trekkes en kjører tilbake mens den holder arbeid, blir uttaket
-- stående til leien løper ut — normalt et kvarter, og opptil et døgn om
-- kjøringen ba om det. Erstatteren, som nå kan registreres på den samme
-- nøkkelen, får ikke gjort noe i mellomtiden, og arbeidet ser ut til å pågå
-- hos noen som ikke lenger finnes.
--
-- Den andre: agentarbeidsflaten leste «en kjører holder denne» strukturelt, av
-- at uttakshendelsen manglet en aktør. Etter en tilbaketrekking pekte den
-- avlesningen på den NYE kjøreren i rollen, og flaten fortalte at et arbeid var
-- i gang hos noen som aldri hadde tatt det.
--
-- Kolonnen gjør holderen til en opplysning framfor en gjetning. Den gjelder
-- bare mens uttaket løper: en trigger glemmer den i det raden forlater
-- «leased», slik at ingen skrivevei kan etterlate en holder som ikke holder
-- noe (ANTIDEP_CONSTITUTION.md regel 4).
-- ----------------------------------------------------------------------------
alter table workflow.pipeline_jobs
  add column runner_connection_id uuid
    references workflow.agent_runner_connections (id) on update restrict on delete restrict,
  add constraint pipeline_jobs_runner_connection_lease_check
    check (runner_connection_id is null or (state = 'leased' and lease_token is not null));

comment on column workflow.pipeline_jobs.runner_connection_id is
  'Den autonome kjøreren som holder det løpende uttaket, eller NULL når uttaket er et menneskes eller ingen holder noe. Egen kolonne fordi leased_by_agent_identity_id er per rolle og deles av alle kjørere i den: uten denne kunne verken en tilbaketrekking finne arbeidet sin egen kjører holdt, eller flaten si hvem som faktisk holdt det. Gjelder bare i tilstanden leased, håndhevet av pipeline_jobs_runner_connection_lease_check og workflow.forget_runner_connection_outside_lease().';

create index pipeline_jobs_runner_connection_idx
  on workflow.pipeline_jobs (runner_connection_id)
  where runner_connection_id is not null;

create function workflow.forget_runner_connection_outside_lease()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.state <> 'leased' then
    new.runner_connection_id := null;
  end if;
  return new;
end;
$$;

comment on function workflow.forget_runner_connection_outside_lease() is
  'Glemmer hvilken autonom kjører som holdt uttaket, i det raden forlater tilstanden leased. Ligger i en trigger og ikke i hver skrivevei: en holder som blir stående etter at uttaket er over, ville fått agentarbeidsflaten til å melde et arbeid som pågår, og en tilbaketrekking til å frigi noe som allerede var frigitt. Regelen skal gjelde uansett hvem som skriver.';

revoke execute on function workflow.forget_runner_connection_outside_lease() from public;

create trigger pipeline_jobs_forget_runner_connection
  before update on workflow.pipeline_jobs
  for each row execute function workflow.forget_runner_connection_outside_lease();

alter table workflow.agent_handoff_imports
  add column runner_connection_id uuid
    references workflow.agent_runner_connections (id) on update restrict on delete restrict;

comment on column workflow.agent_handoff_imports.runner_connection_id is
  'Den autonome kjøreren som leverte svaret, eller NULL når et menneske lastet det opp fra agentarbeidsflaten. Egen kolonne og ikke en utledning: hvordan svaret kom inn, er en opplysning om kjeden, og imported_by_actor_id sier fortsatt hvem som står ansvarlig for at det kom inn i det hele tatt.';

create index agent_handoff_imports_runner_idx
  on workflow.agent_handoff_imports (runner_connection_id, created_at desc)
  where runner_connection_id is not null;
create function workflow.record_agent_handoff_answer(
  p_pipeline_job_id uuid,
  p_answer jsonb,
  p_actor_id uuid,
  p_runner_connection_id uuid,
  p_lease_token uuid
)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_attempt integer;
  v_job workflow.pipeline_jobs;
  v_problem text;
  v_task jsonb;
  v_binding jsonb;
  v_input jsonb;
  v_answer_digest text;
  v_existing workflow.agent_handoff_imports;
  v_identity jsonb;
  v_provider text;
  v_model text;
  v_model_version text;
  v_disclosure provenance.model_version_disclosure;
  v_answered_at timestamptz;
  v_result jsonb;
  v_unknown text;
  v_agent_identity provenance.agent_identities;
  v_agent_actor_id uuid;
  v_registration provenance.role_model_assignments;
  v_semantic provenance.role_model_assignments;
  v_lease uuid;
  v_run_id uuid;
  v_outcome jsonb;
  v_extraction jsonb;
  v_claim jsonb;
  v_assessment jsonb;
  v_evidence_item_id uuid;
  v_ids uuid[];
  v_id uuid;
begin
  -- Kalleren har allerede fastslått hvem dette er: en redaktør med mandat i den
  -- manuelle veien, eller den registrerte kjørertilkoblingens egen registrant i
  -- den autonome. Autentiseringen hører i api-funksjonen, arbeidet her.
  v_actor_id := p_actor_id;

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.id = p_pipeline_job_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Det finnes ingen agentoppgave med id %L.', p_pipeline_job_id);
  end if;

  -- ------------------------------------------------------------------
  -- Gjentakelsen først, før alt annet
  --
  -- Det samme svaret sendt inn igjen — et dobbeltklikk, en gjenopptatt
  -- økt — skal svare med det som allerede ble registrert, framfor å lage
  -- et nytt klinisk objekt. Et *annet* svar på en jobb som allerede er
  -- besvart, er ikke en gjentakelse, og avvises.
  -- ------------------------------------------------------------------
  v_answer_digest := 'sha256:' || encode(sha256(convert_to(p_answer::text, 'UTF8')), 'hex');

  select i.* into v_existing
  from workflow.agent_handoff_imports i
  where i.pipeline_job_id = p_pipeline_job_id;

  if found then
    if v_existing.answer_digest = v_answer_digest then
      return jsonb_build_object(
        'imported', false,
        'already_imported', true,
        'delivered_by', case when v_existing.runner_connection_id is null
                             then 'manual' else 'autonomous_runner' end,
        'pipeline_job_id', p_pipeline_job_id,
        'agent_role', v_existing.agent_role::text,
        'agent_run_id', v_existing.agent_run_id,
        'outcome', v_existing.outcome
      );
    end if;
    raise exception using
      errcode = 'unique_violation',
      message = 'Denne agentoppgaven har allerede tatt imot et annet svar.',
      hint = 'Ett svar per oppgave. To svar ville gitt to kliniske objekter for det samme arbeidet, og ingen ville kunnet si hvilket som gjaldt (ANTIDEP_CONSTITUTION.md regel 4). Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;

  if v_job.state = 'succeeded' then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Agentoppgaven er allerede fullført.',
      hint = 'Jobben har et registrert utfall fra før. Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;
  -- Uttaket, før alt annet som handler om jobbens tilstand.
  --
  -- Den manuelle veien tar selv et uttak, som før. Den autonome kommer med et
  -- uttak den allerede holder, og det uttaket er svarets eneste adgangstegn: et
  -- håndtak som ikke er jobbens gjeldende leie, er et foreldet svar fra en
  -- kjøring som er overtatt eller har løpt ut, og det skal avvises før noe
  -- skrives (ANTIDEP_CONSTITUTION.md regel 4, 7).
  if p_lease_token is not null then
    if v_job.state <> 'leased'
       or v_job.lease_token is distinct from p_lease_token
       or v_job.lease_expires_at is null
       or v_job.lease_expires_at <= statement_timestamp() then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Uttaket dette svaret ble gjort under, gjelder ikke lenger.',
        hint = 'Leien er løpt ut eller overtatt av en annen kjøring. Hent arbeid på nytt framfor å levere et svar på et uttak som ikke er ditt; et svar fra et foreldet uttak ville kunnet skrive over arbeidet en annen kjøring nettopp gjorde.';
    end if;
    v_attempt := v_job.attempts;
    v_lease := p_lease_token;
  else
    if v_job.attempts >= v_job.max_attempts then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Agentoppgaven har brukt opp forsøkene sine og blir stående.',
        hint = 'En oppbrukt jobb skal ikke se ut som en jobb som fortsatt er underveis (ANTIDEP_CONSTITUTION.md regel 4). Legg inn oppgaven på nytt dersom den skal forsøkes igjen.';
    end if;
    v_attempt := v_job.attempts + 1;
    v_lease := gen_random_uuid();
  end if;

  v_problem := workflow.agent_task_problem(v_job, p_lease_token);
  if v_problem is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = v_problem;
  end if;

  -- ------------------------------------------------------------------
  -- Formen på svaret, og bindingen
  -- ------------------------------------------------------------------
  if p_answer is null or jsonb_typeof(p_answer) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret er ikke et JSON-objekt.';
  end if;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(p_answer) as k(value)
  where k.value not in (
    'answer_version', 'task_version', 'role', 'job_key', 'request_digest',
    'output_schema_version', 'identity', 'answered_at', 'result'
  );
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret har felter denne kontrakten ikke kjenner: %s.', v_unknown),
      hint = 'Ukjente felter avvises framfor å ignoreres: et felt med skrivefeil ville ellers sett ut som en utelatt opplysning, og et felt ingen leser, ville vært en påstand uten virkning.';
  end if;

  v_task := workflow.agent_task(v_job);
  v_binding := v_task -> 'binding';
  v_input := v_binding -> 'input';

  if p_answer ->> 'answer_version' is distinct from workflow.agent_handoff_answer_version() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er skrevet mot %L, men Antidep leser %L.',
        p_answer ->> 'answer_version', workflow.agent_handoff_answer_version());
  end if;
  if p_answer ->> 'task_version' is distinct from workflow.agent_handoff_task_version() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret gjelder oppgaveformen %L, men denne oppgaven er %L.',
        p_answer ->> 'task_version', workflow.agent_handoff_task_version());
  end if;
  if p_answer ->> 'role' is distinct from v_job.agent_role::text then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er avgitt i rollen %L, mens oppgaven gjelder rollen %L.',
        p_answer ->> 'role', v_job.agent_role::text),
      hint = 'Rollen avgjør hva svaret får lov til å registrere. Et svar fra ett ledd skal ikke kunne lukkes inn i et annet.';
  end if;
  if p_answer ->> 'job_key' is distinct from v_job.job_key then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret gjelder en annen agentoppgave enn den det importeres på.';
  end if;
  if p_answer ->> 'output_schema_version' is distinct from (v_task ->> 'output_schema_version') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er skrevet mot svarformen %L, mens oppgaven krever %L.',
        p_answer ->> 'output_schema_version', v_task ->> 'output_schema_version');
  end if;
  if p_answer ->> 'request_digest' is distinct from (v_task ->> 'request_digest') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Svaret er avgitt på forespørselen %s, mens oppgaven nå er %s.',
        coalesce(p_answer ->> 'request_digest', '(mangler)'), v_task ->> 'request_digest'),
      hint = 'Avtrykket dekker rollen, oppgaven, promptmalen, svarformen og hele grunnlaget oppgaven ble bygget av. Er noe av det endret siden oppgaven ble hentet ut, gjelder ikke det gamle svaret lenger. Hent oppgaven på nytt og be om et nytt svar (ANTIDEP_CONSTITUTION.md regel 2, 4).';
  end if;

  v_result := p_answer -> 'result';
  if v_result is null or jsonb_typeof(v_result) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret har ingen result som er et JSON-objekt.';
  end if;

  -- ------------------------------------------------------------------
  -- Hvem som svarte
  -- ------------------------------------------------------------------
  v_identity := p_answer -> 'identity';
  if v_identity is null or jsonb_typeof(v_identity) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret sier ikke hvilken modell som utførte oppgaven.',
      hint = 'identity skal ha provider, model og model_version_disclosure — og model_version når tjenesten faktisk oppgir en versjon. Uten den kan ingen si om kontrollene i kjeden er uavhengige (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(v_identity) as k(value)
  where k.value not in ('provider', 'model', 'model_version', 'model_version_disclosure');
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('identity har felter denne kontrakten ikke kjenner: %s.', v_unknown);
  end if;

  -- Den samme lesningen tildelingen ble gjort med, slik at «samme modell» betyr
  -- det samme begge steder.
  v_identity := provenance.canonical_model_identity(
    v_identity ->> 'provider',
    v_identity ->> 'model',
    v_identity ->> 'model_version',
    v_identity ->> 'model_version_disclosure'
  );
  v_provider := v_identity ->> 'provider';
  v_model := v_identity ->> 'model';
  v_model_version := v_identity ->> 'model_version';
  v_disclosure := (v_identity ->> 'model_version_disclosure')::provenance.model_version_disclosure;

  -- Svaret bekrefter identiteten sin; det etablerer den ikke. Tildelingen er
  -- tatt på forhånd av en redaktør med mandat, den står i bindingen avtrykket er
  -- regnet av, og et svar fra en annen modell avvises her — før noe skrives. Et
  -- svar som fikk registrere sin egen identitet, ville etablert premisset som
  -- autoriserte det selv, og separasjonen mellom leddene ville hvilt på en
  -- erklæring modellen avga om seg selv (ANTIDEP_CONSTITUTION.md regel 3).
  v_semantic := provenance.require_semantic_model_assignment(v_job.agent_role, v_identity);

  if p_answer ->> 'answered_at' is not null then
    begin
      v_answered_at := (p_answer ->> 'answered_at')::timestamptz;
    exception
      when others then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('answered_at er %L, som ikke er et tidspunkt.', p_answer ->> 'answered_at');
    end;

    -- Et svar kan ikke være avgitt i framtiden. Slakken finnes fordi agenten
    -- kjører på en annen maskin med en annen klokke, og et tidspunkt avrundet
    -- til nærmeste minutt ikke er en usann påstand; uten den ville en riktig
    -- import blitt stoppet av tre sekunder, og kontrollen blitt skrudd av
    -- framfor fulgt. Samme regel og samme slakk som i den filbaserte kjøringen.
    if v_answered_at > statement_timestamp() + interval '5 minutes'
       or v_answered_at < v_job.enqueued_at - interval '5 minutes' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format(
          'answered_at er %L, som ligger utenfor oppgaven: den ble lagt inn %L og importeres nå.',
          v_answered_at, v_job.enqueued_at
        ),
        hint = 'Tidspunktet registreres som da agenten svarte. Et svar avgitt før oppgaven fantes, eller inn i framtiden, er ikke en unøyaktighet — det er en usann proveniens (ANTIDEP_CONSTITUTION.md regel 4). La feltet stå tomt om du er usikker.';
    end if;
  end if;

  -- ------------------------------------------------------------------
  -- Uttaket og kjøringen
  --
  -- Importen gjør det en kjører ville gjort: tar ut jobben med en leie i
  -- rollens egen agentidentitet, åpner kjøringen for nettopp det uttaket, og
  -- melder utfallet. Da gjelder de samme bindingene og de samme reglene som
  -- for et automatisert ledd — inkludert at kjøringen ikke kan gjenbrukes på
  -- en annen jobb.
  -- ------------------------------------------------------------------
  select ai.* into v_agent_identity
  from provenance.agent_identities ai
  where ai.agent_role = v_job.agent_role
    and ai.valid_from <= statement_timestamp()
    and (ai.valid_to is null or ai.valid_to > statement_timestamp())
  order by ai.valid_from
  limit 1;

  if v_agent_identity.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig agentidentitet å registrere kjøringen under.', v_job.agent_role);
  end if;
  v_agent_actor_id := v_agent_identity.actor_id;

  v_registration := provenance.current_role_model(v_job.agent_role);
  if v_registration.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig modelltildeling for registreringsleddet.', v_job.agent_role);
  end if;

  -- Den manuelle veien tar uttaket her; den autonome tok det da den hentet
  -- arbeidet, og skal ikke ta det en gang til — et nytt uttak ville talt et
  -- forsøk som aldri fant sted, og byttet ut nøkkelen midt i sitt eget svar.
  if p_lease_token is null then
    update workflow.pipeline_jobs
    set state = 'leased',
        attempts = v_attempt,
        leased_by_agent_identity_id = v_agent_identity.id,
        lease_expires_at = statement_timestamp() + interval '15 minutes',
        lease_token = v_lease,
        -- Uttaket er et menneskes. Sto det en kjører på raden fra et uttak som
        -- rakk å løpe ut, er den ikke lenger holderen, og skal ikke bli stående
        -- som om den var det.
        runner_connection_id = null,
        -- En jobb som sto som failed, bærer et fullføringstidspunkt. Uttaket er
        -- et nytt forsøk, og et forsøk som pågår, er ikke fullført.
        completed_at = null
    where id = v_job.id;

    perform workflow.record_pipeline_job_event(
      v_job.id, v_job.state, 'leased'::workflow.pipeline_job_state,
      v_attempt, v_actor_id, null,
      'Uttak for import av et eksternt agentsvar.'
    );
  end if;

  insert into provenance.agent_runs (
    agent_identity_id, actor_id, agent_role,
    provider, model, model_version, model_version_disclosure,
    semantic_provider, semantic_model, semantic_model_version,
    semantic_model_version_disclosure,
    prompt_template_version, pipeline_version,
    status, input_manifest, input_source_version_id
  )
  values (
    v_agent_identity.id, v_agent_actor_id, v_job.agent_role,
    v_registration.provider, v_registration.model, v_registration.model_version,
    v_registration.model_version_disclosure,
    v_provider, v_model, v_model_version, v_disclosure,
    v_task ->> 'prompt_template_version', 'antidep-evidence/1',
    'running',
    jsonb_build_object('handoff', jsonb_build_object(
      'task_version', v_task ->> 'task_version',
      'answer_version', v_task ->> 'answer_version',
      'request_digest', v_task ->> 'request_digest',
      'output_schema_version', v_task ->> 'output_schema_version',
      'answer_digest', v_answer_digest,
      'answered_at', v_answered_at,
      'imported_by_actor_id', v_actor_id,
      'binding', v_binding
    )),
    case when v_job.agent_role = 'evidence_extraction'
         then (v_input ->> 'source_version_id')::uuid end
  )
  returning id into v_run_id;

  insert into workflow.pipeline_job_runs (agent_run_id, pipeline_job_id, lease_token, attempt)
  values (v_run_id, v_job.id, v_lease, v_attempt);

  -- ------------------------------------------------------------------
  -- Arbeidet, gjennom de samme skriveveiene som agentkjørerne bruker
  -- ------------------------------------------------------------------
  if v_job.agent_role = 'evidence_extraction' then
    v_extraction := v_result -> 'extraction';
    if v_extraction is null or jsonb_typeof(v_extraction) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen extraction som er et JSON-objekt.';
    end if;

    -- Katalogen er redaktørens avgrensning, og modellen velger innenfor den.
    -- En id utenfor oppgaven ville flyttet funnet til et annet virkestoff eller
    -- et naboendepunkt, og den ordrette kontrollen kontrollerer utdrag — ikke
    -- avgrensning.
    v_ids := workflow.manifest_uuids(v_input, 'drug_ids');
    v_id := workflow.manifest_uuid(v_extraction, 'intervention_drug_id');
    if v_id is null or not (v_id = any (v_ids)) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et virkestoff som ikke står blant virkestoffene i oppgaven.';
    end if;
    v_id := workflow.manifest_uuid(v_extraction, 'comparator_drug_id');
    if v_extraction ->> 'comparator_drug_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et komparatorvirkestoff som ikke står blant virkestoffene i oppgaven.';
    end if;
    v_ids := workflow.manifest_uuids(v_input, 'outcome_concept_ids');
    v_id := workflow.manifest_uuid(v_extraction, 'outcome_concept_id');
    if v_id is null or not (v_id = any (v_ids)) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et endepunkt som ikke står blant endepunktene i oppgaven.';
    end if;
    v_ids := coalesce(workflow.manifest_uuids(v_input, 'population_ids'), array[]::uuid[]);
    v_id := workflow.manifest_uuid(v_extraction, 'population_id');
    if v_extraction ->> 'population_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir en populasjon som ikke står blant populasjonene i oppgaven.';
    end if;

    v_evidence_item_id := knowledge.record_evidence_item(
      (v_input ->> 'source_id')::uuid,
      v_extraction ->> 'design_code',
      v_extraction ->> 'population_availability',
      v_extraction ->> 'population_detail',
      v_extraction ->> 'sample_size_availability',
      (v_extraction ->> 'intervention_drug_id')::uuid,
      v_extraction ->> 'comparator_kind',
      (v_extraction ->> 'outcome_concept_id')::uuid,
      v_extraction ->> 'outcome_detail',
      v_extraction ->> 'timepoint_availability',
      v_extraction ->> 'reported_direction',
      v_extraction ->> 'estimate_availability',
      v_extraction ->> 'confidence_interval_availability',
      v_extraction ->> 'source_locator',
      (v_input ->> 'source_version_id')::uuid,
      workflow.manifest_uuid(v_extraction, 'population_id'),
      (v_extraction ->> 'sample_size')::integer,
      v_extraction ->> 'intervention_detail',
      workflow.manifest_uuid(v_extraction, 'comparator_drug_id'),
      v_extraction ->> 'comparator_detail',
      v_extraction ->> 'timepoint_min',
      v_extraction ->> 'timepoint_max',
      v_extraction ->> 'effect_measure',
      (v_extraction ->> 'estimate')::numeric,
      v_extraction ->> 'estimate_unit',
      (v_extraction ->> 'ci_lower')::numeric,
      (v_extraction ->> 'ci_upper')::numeric,
      (v_extraction ->> 'ci_level_percent')::numeric,
      v_extraction ->> 'limitations_text',
      v_extraction ->> 'source_quote',
      v_result -> 'field_groundings',
      'ai_assisted',
      v_agent_actor_id,
      v_run_id
    );

    perform workflow.assert_extraction_fully_grounded(v_evidence_item_id);
    v_outcome := jsonb_build_object('evidence_item_id', v_evidence_item_id);

  elsif v_job.agent_role = 'claim_synthesis' then
    v_claim := v_result -> 'claim';
    if v_claim is null or jsonb_typeof(v_claim) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen claim som er et JSON-objekt.';
    end if;

    -- Evidenssettet er oppgavens, ikke svarets. En lenke til et funn utenfor
    -- oppgaven ville gitt en påstand som hvilte på noe ingen hadde avgrenset.
    if exists (
      select 1
      from jsonb_array_elements(coalesce(v_result -> 'evidence_links', '[]'::jsonb)) as link(value)
      where workflow.manifest_uuid(link.value, 'evidence_item_id') is null
         or not (workflow.manifest_uuid(link.value, 'evidence_item_id') = any (
              select (e.value ->> 'evidence_item_id')::uuid
              from jsonb_array_elements(v_input -> 'evidence') as e(value)))
    ) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret lenker til et evidensfunn som ikke står i oppgaven.',
        hint = 'Hvilke funn en syntese kan bygge på, er en faglig avgrensning som ligger i oppgaven. En modell som fikk velge fritt, ville kunnet bygge påstanden på noe ingen hadde tatt stilling til.';
    end if;

    -- Og hele settet, ikke en delmengde av det. Et svar som utelot et funn som
    -- MOTSIER påstanden, ville gitt en syntese som hvilte på et annet grunnlag
    -- enn det redaktøren avgrenset — og uenigheten ville vært borte uten at noe
    -- i kjeden sa fra (ANTIDEP_CONSTITUTION.md regel 4).
    if exists (
      select 1
      from jsonb_array_elements(v_input -> 'evidence') as assigned(value)
      where not exists (
        select 1
        from jsonb_array_elements(coalesce(v_result -> 'evidence_links', '[]'::jsonb)) as link(value)
        where link.value ->> 'evidence_item_id' = assigned.value ->> 'evidence_item_id'
      )
    ) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret dekker ikke alle evidensfunnene oppgaven avgrenset.',
        hint = 'Hvert funn i oppgaven skal ha en relasjon til påstanden — også et funn som motsier den, som da føres som contradicts. Et utelatt funn ville gjort grunnlaget til et annet enn det som finnes.';
    end if;

    -- Populasjonen er redaktørens avgrensning, som katalogen i et
    -- ekstraksjonsoppdrag. En id kopiert ut av dossieret ville passert
    -- fremmednøkkelen og flyttet påstanden til en annen populasjon.
    v_ids := coalesce(workflow.manifest_uuids(v_input, 'population_ids'), array[]::uuid[]);
    v_id := workflow.manifest_uuid(v_claim, 'population_id');
    if v_claim ->> 'population_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir en populasjon som ikke står blant populasjonene i oppgaven.';
    end if;

    v_outcome := knowledge.record_agent_claim_synthesis(
      v_run_id,
      v_agent_actor_id,
      (v_input ->> 'topic_concept_id')::uuid,
      (v_input ->> 'subject_drug_id')::uuid,
      v_claim ->> 'statement',
      v_claim ->> 'scope',
      v_claim ->> 'comparator_kind',
      v_claim ->> 'uncertainty_summary',
      v_result -> 'evidence_links',
      workflow.manifest_uuid(v_input, 'claim_id'),
      workflow.manifest_uuid(v_claim, 'population_id'),
      v_claim ->> 'timeframe_min',
      v_claim ->> 'timeframe_max',
      workflow.manifest_uuid(v_claim, 'comparator_drug_id'),
      v_claim ->> 'direction',
      v_claim ->> 'magnitude_measure',
      (v_claim ->> 'magnitude_value')::numeric,
      v_claim ->> 'magnitude_unit',
      v_claim ->> 'qualifiers'
    );

  else
    v_assessment := v_result -> 'assessment';
    if v_assessment is null or jsonb_typeof(v_assessment) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen assessment som er et JSON-objekt.';
    end if;

    v_outcome := knowledge.record_evidence_assessment_row(
      v_run_id,
      v_agent_actor_id,
      (v_input ->> 'claim_revision_id')::uuid,
      -- Avtrykket av evidenssettet er oppgavens eget, ikke svarets: oppgaven
      -- viste nøyaktig det settet, og request_digest dekker det allerede. En
      -- verdi fra svaret ville vært en påstand om hva agenten så.
      v_input ->> 'evidence_set_digest',
      v_assessment ->> 'framework',
      v_assessment ->> 'certainty_level',
      v_assessment ->> 'rationale',
      v_assessment ->> 'risk_of_bias',
      v_assessment ->> 'inconsistency',
      v_assessment ->> 'indirectness',
      v_assessment ->> 'imprecision',
      v_assessment ->> 'publication_bias',
      v_assessment ->> 'other_considerations',
      v_assessment ->> 'evidence_gap'
    );
  end if;

  -- ------------------------------------------------------------------
  -- Utfallet
  -- ------------------------------------------------------------------
  update provenance.agent_runs
  set status = 'succeeded', completed_at = now(), output_manifest = v_outcome
  where id = v_run_id;

  update workflow.pipeline_jobs
  set state = 'succeeded',
      agent_run_id = v_run_id,
      output_manifest = v_outcome,
      completed_at = now(),
      failure_reason = null
  where id = v_job.id;

  perform workflow.record_pipeline_job_event(
    v_job.id, 'leased'::workflow.pipeline_job_state, 'succeeded'::workflow.pipeline_job_state,
    v_attempt, v_actor_id, null,
    case when p_runner_connection_id is null
      then 'Eksternt agentsvar importert og registrert.'
      else 'Eksternt agentsvar levert av en autonom kjører og registrert.' end
  );

  insert into workflow.agent_handoff_imports (
    pipeline_job_id, agent_role, request_digest, answer_digest,
    agent_run_id, imported_by_actor_id, answered_at, outcome,
    runner_connection_id
  )
  values (
    v_job.id, v_job.agent_role, v_task ->> 'request_digest', v_answer_digest,
    v_run_id, v_actor_id, v_answered_at, v_outcome,
    p_runner_connection_id
  );

  return jsonb_build_object(
    'imported', true,
    'already_imported', false,
    'delivered_by', case when p_runner_connection_id is null then 'manual' else 'autonomous_runner' end,
    'pipeline_job_id', v_job.id,
    'agent_role', v_job.agent_role::text,
    'agent_run_id', v_run_id,
    'request_digest', v_task ->> 'request_digest',
    'model', jsonb_build_object(
      'provider', v_provider, 'model', v_model,
      'model_version', v_model_version,
      'model_version_disclosure', v_disclosure::text),
    'outcome', v_outcome
  );
end;
$$;

comment on function workflow.record_agent_handoff_answer(uuid, jsonb, uuid, uuid, uuid) is
  'Tar imot ett eksternt agentsvar på én agentoppgave og registrerer resultatet gjennom de samme interne skriveveiene agentkjørerne bruker (ANTIDEP_CONSTITUTION.md regel 3, 4, 7). Kroppen er ordrett den samme som api.import_agent_answer(uuid, jsonb) hadde i migrasjon 010c, med to forskjeller: aktøren er fastslått av kalleren framfor her, og en kaller som allerede holder et uttak, leverer under nettopp det uttaket framfor å ta et nytt. Begge transportene — nedlast/opplast og den autonome MCP-kjøreren — kaller denne, slik at ingen av dem kan få større faglige skrivefullmakter enn den andre. Autentiserer ingenting selv og er derfor ikke SECURITY DEFINER: den kalles fra innsiden av en api-funksjon som allerede har fastslått hvem kalleren er.';

revoke execute on function workflow.record_agent_handoff_answer(uuid, jsonb, uuid, uuid, uuid) from public;

-- Den manuelle veien: uendret utenfra, og nå bare autentisering og delegering.
create or replace function api.import_agent_answer(p_pipeline_job_id uuid, p_answer jsonb)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := knowledge.assert_editor_authorized();
  -- Ingen tilkobling, og ingen leie: den manuelle veien tar selv uttaket, som
  -- den alltid har gjort. En jobb en autonom kjører holder, avvises da av
  -- workflow.agent_task_problem — det er den samme regelen som hindrer to
  -- mennesker i å importere det samme arbeidet.
  return workflow.record_agent_handoff_answer(p_pipeline_job_id, p_answer, v_actor_id, null, null);
end;
$$;

comment on function api.import_agent_answer(uuid, jsonb) is
  'Tar imot ett eksternt agentsvar lastet opp fra agentarbeidsflaten, og registrerer det gjennom workflow.record_agent_handoff_answer(uuid, jsonb, uuid, uuid, uuid) — den samme skriveveien den autonome MCP-kjøreren bruker (ANTIDEP_CONSTITUTION.md regel 3, 4, 7). Svaret er data: ukjente felter avvises, bindingen kontrolleres mot oppgaven slik databasen bygger den nå, og verdiene hentes ut av svaret selv. Et svar avgitt på en oppgave som siden har fått et annet grunnlag, har et annet request_digest og avvises. Importen er idempotent på jobben, og en jobb en autonom kjører holder leien på, kan ikke importeres herfra før leien er ute — det er den samme regelen som hindrer to mennesker i å registrere det samme arbeidet. Krever editor-mandat. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny; kalleren valideres på funksjonens eget kall.';

revoke execute on function api.import_agent_answer(uuid, jsonb) from public;
grant execute on function api.import_agent_answer(uuid, jsonb) to authenticated;

-- ============================================================================
-- 8. Redaktørens veier
--
-- Tre handlinger og én lesing, alle med editor-mandat: registrer en kjører,
-- hent én engangs tilkoblingskode, trekk kjøreren tilbake, og se hva som
-- finnes. Tilkoblingskoden er det eneste stedet en hemmelighet forlater
-- databasen i klartekst, og den lever i ti minutter.
-- ============================================================================
create function api.register_agent_runner(
  p_connection_key text,
  p_display_name text,
  p_agent_role text,
  p_platform_agent_reference text,
  p_platform_model_disclosure text,
  p_reason text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_role provenance.agent_role;
  v_disclosure workflow.runner_model_disclosure;
  v_connection workflow.agent_runner_connections;
  v_holder text;
  v_valid_from timestamptz;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role);
  end;

  -- En kjører kan bare få arbeid i et ledd som faktisk kan settes ut. De
  -- uavhengige kontrolleddene er Antideps egen deterministiske kode, og en
  -- ekstern modell som fikk utføre dem, ville gjort kontrollen til nok en
  -- modellvurdering (ANTIDEP_CONSTITUTION.md regel 3).
  if workflow.agent_task_contract(v_role) is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Rollen %L utføres av Antideps egen deterministiske kode, og kan ikke settes ut til en autonom kjører.',
        p_agent_role);
  end if;

  begin
    v_disclosure := p_platform_model_disclosure::workflow.runner_model_disclosure;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format(
          '%L sier ikke om plattformen pinner modellen. Gyldige verdier er platform_pinned og not_exposed.',
          p_platform_model_disclosure),
        hint = 'Pinner Workspace Agent-en en bestemt modell som plattformen viser, er verdien platform_pinned. Gjør den ikke det, er den not_exposed — og det er en sann opplysning framfor en mangel: separasjonen hviler da på modelltildelingen, ikke på plattformen (ANTIDEP_CONSTITUTION.md regel 3, 4).';
  end;

  -- Perioden begynner der den forrige sluttet, og aldri før.
  --
  -- Standardverdien for valid_from er now(), altså transaksjonens starttid. En
  -- tilbaketrekking og en ny registrering i den samme transaksjonen ville derfor
  -- fått overlappende perioder, og exclusion-reglene ville avvist en
  -- registrering som er helt legitim. Samme regning, og samme begrunnelse, som i
  -- api.assign_agent_role_model.
  select greatest(
           statement_timestamp(),
           coalesce(max(c.valid_to), statement_timestamp()))
    into v_valid_from
  from workflow.agent_runner_connections c
  where c.agent_role = v_role
     or c.connection_key = btrim(coalesce(p_connection_key, ''))
     or c.platform_agent_reference = btrim(coalesce(p_platform_agent_reference, ''));

  begin
    insert into workflow.agent_runner_connections (
      connection_key, display_name, agent_role,
      platform_agent_reference, platform_model_disclosure,
      valid_from, registered_by_actor_id, registration_reason
    )
    values (
      btrim(coalesce(p_connection_key, '')),
      btrim(coalesce(p_display_name, '')),
      v_role,
      btrim(coalesce(p_platform_agent_reference, '')),
      v_disclosure,
      coalesce(v_valid_from, statement_timestamp()),
      v_actor_id,
      coalesce(
        nullif(btrim(coalesce(p_reason, '')), ''),
        'Registrert av en redaktør med mandat som den planlagte eksterne kjøreren av dette agentleddet.')
    )
    returning * into v_connection;
  exception
    when exclusion_violation then
      -- Hvilken av de to reglene som svarte, avgjør hva som må gjøres. En
      -- melding som gjettet, ville sendt eieren etter feil årsak.
      select c.agent_role::text into v_holder
      from workflow.agent_runner_connections c
      where c.platform_agent_reference = btrim(coalesce(p_platform_agent_reference, ''))
        and c.agent_role <> v_role
        and c.valid_to is null;

      if v_holder is not null then
        raise exception using
          errcode = 'restrict_violation',
          message = format(
            'Workspace Agent-en %L kjører allerede agentleddet %s, og kan ikke også kjøre %s.',
            btrim(coalesce(p_platform_agent_reference, '')), v_holder, p_agent_role),
          hint = 'Én agentkonfigurasjon er én modellruntime. Lar vi den samme agenten både lage innholdet og vurdere det, er kontrollen den samme vurderingen gjort to ganger (ANTIDEP_CONSTITUTION.md regel 3). Opprett en egen Workspace Agent for dette leddet.';
      end if;

      if exists (
        select 1 from workflow.agent_runner_connections c
        where c.connection_key = btrim(coalesce(p_connection_key, ''))
          and c.valid_to is null
      ) then
        raise exception using
          errcode = 'restrict_violation',
          message = format('Nøkkelen %L tilhører allerede en gjeldende kjører.', p_connection_key),
          hint = 'Trekk den gjeldende tilbake med api.revoke_agent_runner(text, text) først. Den samme nøkkelen kan brukes på nytt etterpå: unikheten gjelder de gjeldende tilkoblingene, ikke historikken.';
      end if;

      raise exception using
        errcode = 'restrict_violation',
        message = format('Agentleddet %L har allerede en gjeldende autonom kjører.', p_agent_role),
        hint = 'Trekk den gjeldende tilbake med api.revoke_agent_runner(text, text) før en ny registreres. Ett ledd med to kjørere ville gjort «hvem henter arbeidet her» til et spørsmål med to svar.';
  end;

  return jsonb_build_object(
    'registered', true,
    'connection_key', v_connection.connection_key,
    'display_name', v_connection.display_name,
    'agent_role', v_connection.agent_role::text,
    'platform_agent_reference', v_connection.platform_agent_reference,
    'platform_model_disclosure', v_connection.platform_model_disclosure::text
  );
end;
$$;

comment on function api.register_agent_runner(text, text, text, text, text, text) is
  'Registrerer én autonom kjører av eksternt agentarbeid — i praksis én planlagt ChatGPT Workspace Agent (ANTIDEP_CONSTITUTION.md regel 3, 7). Tilkoblingen bindes til nøyaktig ett agentledd, og den samme Workspace Agent-en kan ikke kjøre to ledd: én konfigurasjon er én modellruntime, og en kjede der den samme agenten både laget innholdet og vurderte det, ville vært egenverifikasjon. Gir ingen tilgang i seg selv — den kommer først når en tilkoblingskode innløses. Krever editor-mandat. SECURITY DEFINER fordi workflow har RLS med default deny; kalleren valideres på funksjonens eget kall.';

revoke execute on function api.register_agent_runner(text, text, text, text, text, text) from public;
grant execute on function api.register_agent_runner(text, text, text, text, text, text) to authenticated;

create function api.revoke_agent_runner(p_connection_key text, p_reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_connection workflow.agent_runner_connections;
  v_secrets integer;
  v_job workflow.pipeline_jobs;
  v_released integer := 0;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En tilbaketrekking krever en begrunnelse.',
      hint = 'At en autonom kjører slutter å ha tilgang, er en endring av hvem som utfører kjedens arbeid. En endring uten grunn ville vært en endring uten ansvar.';
  end if;

  select c.* into v_connection
  from workflow.agent_runner_connections c
  where c.connection_key = btrim(coalesce(p_connection_key, ''))
    and c.valid_to is null
  for update;

  if not found then
    return jsonb_build_object('revoked', false, 'connection_key', p_connection_key);
  end if;

  update workflow.agent_runner_connections
  set valid_to = statement_timestamp(),
      revoked_by_actor_id = v_actor_id,
      revocation_reason = btrim(p_reason)
  where id = v_connection.id;

  -- Tilgangen forsvinner i det samme øyeblikket. En tilbaketrukket tilkobling
  -- med et levende token ville vært en tilbaketrekking som ikke virket før
  -- tokenet tilfeldigvis løp ut.
  update workflow.agent_runner_secrets
  set revoked_at = statement_timestamp()
  where connection_id = v_connection.id
    and revoked_at is null;
  get diagnostics v_secrets = row_count;

  -- Arbeidet kjøreren holdt, blir ledig med det samme.
  --
  -- En tilbaketrukket kjører kommer aldri tilbake for å levere eller gi fra
  -- seg: tokenet er dødt i det samme øyeblikket. Uten dette ville uttaket
  -- blitt stående til leien løp ut — normalt et kvarter, opptil et døgn om
  -- kjøringen ba om det — og erstatteren ville ikke fått gjort arbeidet i
  -- mellomtiden. Køen ville samtidig meldt det som pågående, og en oppgave
  -- som ingen utfører, skal ikke se ut som en oppgave noen utfører
  -- (ANTIDEP_CONSTITUTION.md regel 4).
  --
  -- Forsøket står, som når en kjører selv gir oppgaven fra seg: uttaket ER et
  -- forsøk, og et tall som telles ned igjen, ville vært en historikk skrevet
  -- om til å se penere ut enn den var.
  for v_job in
    select j.*
    from workflow.pipeline_jobs j
    where j.runner_connection_id = v_connection.id
      and j.state = 'leased'
    for update
  loop
    update workflow.pipeline_jobs
    set state = 'ready',
        leased_by_agent_identity_id = null,
        lease_token = null,
        lease_expires_at = null,
        runner_connection_id = null
    where id = v_job.id;

    -- Hendelsen føres på mennesket og ikke på agentidentiteten: det var
    -- redaktøren som frigjorde uttaket, ikke kjøreren som ga det fra seg.
    perform workflow.record_pipeline_job_event(
      v_job.id, 'leased'::workflow.pipeline_job_state, 'ready'::workflow.pipeline_job_state,
      v_job.attempts, v_actor_id, null,
      'Uttaket ble frigitt fordi kjøreren som holdt det, ble trukket tilbake.'
    );

    perform workflow.record_agent_runner_event(
      v_connection.id, 'revoke_agent_runner', 'lease_lost'::workflow.agent_runner_outcome,
      v_connection.agent_role, v_job.id,
      'Uttaket ble frigitt da tilkoblingen ble trukket tilbake.');

    v_released := v_released + 1;
  end loop;

  return jsonb_build_object(
    'revoked', true,
    'connection_key', v_connection.connection_key,
    'agent_role', v_connection.agent_role::text,
    'revoked_secrets', v_secrets,
    'released_tasks', v_released
  );
end;
$$;

comment on function api.revoke_agent_runner(text, text) is
  'Trekker tilbake en autonom kjører, alle tokenene dens og alt arbeidet den holdt, i samme transaksjon (ANTIDEP_CONSTITUTION.md regel 7). Tilgangen forsvinner i det samme øyeblikket: en tilbaketrukket tilkobling med et levende token ville vært en tilbaketrekking som ikke virket før tokenet tilfeldigvis løp ut. Uttakene den holdt, blir ledige med det samme framfor å stå til leien løper ut — kjøreren kommer aldri tilbake for å levere dem, og en oppgave ingen utfører, skal ikke se ut som en oppgave noen utfører. Forsøkene står, som når en kjører selv gir en oppgave fra seg. Sletter aldri: tilkoblingen blir stående med sin periode, med hvem og hvorfor. Krever editor-mandat og en begrunnelse.';

revoke execute on function api.revoke_agent_runner(text, text) from public;
grant execute on function api.revoke_agent_runner(text, text) to authenticated;

create function api.issue_agent_runner_pairing_code(p_connection_key text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_connection workflow.agent_runner_connections;
  v_code text;
  v_expires timestamptz;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  -- Låsen på tilkoblingsraden gjør hele utstedelsen til én avgjørelse.
  --
  -- Uten den kunne to faner lest den samme tilstanden, begge trukket tilbake
  -- den koden de så, og begge satt inn sin egen — og da ville det finnes to
  -- gyldige koder for den samme kjøreren, som er nøyaktig det avsnittet under
  -- finnes for å hindre. En tilbaketrekking som rakk å bli ferdig mellom
  -- lesningen og innsettingen, ville dessuten gitt redaktøren en kode til en
  -- tilkobling som ikke lenger finnes. `for update` venter på den, og i
  -- READ COMMITTED prøves vilkårene på nytt mot den oppdaterte raden: er den
  -- trukket tilbake i mellomtiden, treffer ingenting, og svaret blir det samme
  -- som om nøkkelen aldri fantes.
  select c.* into v_connection
  from workflow.agent_runner_connections c
  where c.connection_key = btrim(coalesce(p_connection_key, ''))
    and c.valid_from <= statement_timestamp()
    and c.valid_to is null
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Det finnes ingen gjeldende kjørertilkobling med nøkkelen %L.', p_connection_key);
  end if;

  -- En tidligere kode som ikke er brukt, trekkes tilbake. To gyldige koder for
  -- den samme tilkoblingen ville vært to veier inn, og bare den ene ville vært
  -- den redaktøren trodde hen hadde utstedt.
  update workflow.agent_runner_secrets
  set revoked_at = statement_timestamp()
  where connection_id = v_connection.id
    and kind = 'pairing_code'
    and consumed_at is null
    and revoked_at is null;

  v_code := workflow.new_agent_runner_secret();
  v_expires := statement_timestamp() + interval '10 minutes';

  insert into workflow.agent_runner_secrets
    (kind, secret_hash, connection_id, issued_by_actor_id, expires_at)
  values
    ('pairing_code', workflow.agent_runner_secret_hash('pairing_code', v_code),
     v_connection.id, v_actor_id, v_expires);

  -- Den ene gangen en hemmelighet forlater databasen i klartekst.
  return jsonb_build_object(
    'connection_key', v_connection.connection_key,
    'display_name', v_connection.display_name,
    'agent_role', v_connection.agent_role::text,
    'pairing_code', v_code,
    'expires_at', v_expires
  );
end;
$$;

comment on function api.issue_agent_runner_pairing_code(text) is
  'Utsteder én engangs tilkoblingskode for en registrert autonom kjører (ANTIDEP_CONSTITUTION.md regel 7). Koden er beviset på editor-mandat i det øyeblikket ChatGPT kobler seg til, og den er det eneste stedet en hemmelighet forlater databasen i klartekst. Den lever i ti minutter, kan brukes én gang, og en tidligere ubrukt kode for den samme tilkoblingen trekkes tilbake i samme kall — to gyldige koder ville vært to veier inn, og bare den ene ville vært den redaktøren trodde hen hadde utstedt. Tilkoblingsraden låses først, slik at to samtidige utstedelser ikke kan gi hver sin gyldige kode, og slik at en tilbaketrekking ikke kan bli ferdig mellom lesningen og innsettingen. Krever editor-mandat.';

revoke execute on function api.issue_agent_runner_pairing_code(text) from public;
grant execute on function api.issue_agent_runner_pairing_code(text) to authenticated;

create function api.agent_runner_connections()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_rows jsonb;
begin
  perform knowledge.assert_editor_authorized();

  select coalesce(jsonb_agg(row_to_json(q)::jsonb order by q.agent_role, q.connection_key), '[]'::jsonb)
    into v_rows
  from (
    select
      c.connection_key,
      c.display_name,
      c.agent_role::text as agent_role,
      c.platform_agent_reference,
      c.platform_model_disclosure::text as platform_model_disclosure,
      c.valid_from,
      -- Står tilkoblingen ved lag? Det er fornyelsesretten som svarer på det,
      -- ikke et levende access-token.
      --
      -- Et access-token lever i én time. En planlagt kjøring som går én gang i
      -- døgnet, har derfor ikke noe levende access-token mesteparten av tiden —
      -- og en flate som leste det, ville sagt «ikke tilkoblet» om en tilkobling
      -- som virker helt som den skal, og fått et menneske til å hente en ny
      -- engangskode uten grunn. Et ubrukt refresh-token er derimot nettopp
      -- retten til å skaffe seg et nytt access-token ved neste kjøring.
      exists (
        select 1 from workflow.agent_runner_secrets s
        where s.connection_id = c.id
          and s.kind = 'refresh_token'
          and s.revoked_at is null
          and s.consumed_at is null
          and s.expires_at > statement_timestamp()
      ) as connected,
      (
        select max(e.created_at) from workflow.agent_runner_events e
        where e.connection_id = c.id
      ) as last_seen_at,
      (
        select count(*) from workflow.agent_handoff_imports i
        where i.runner_connection_id = c.id
      ) as delivered_answers
    from workflow.agent_runner_connections c
    where c.valid_from <= statement_timestamp()
      and c.valid_to is null
  ) q;

  return v_rows;
end;
$$;

comment on function api.agent_runner_connections() is
  'De gjeldende autonome kjørerne, slik agentarbeidsflaten trenger dem: hvilket ledd de utfører, hvilken Workspace Agent de er, om plattformen pinner modellen, om tilkoblingen står ved lag, når de sist var innom og hvor mange svar de har levert. connected leser fornyelsesretten og ikke et levende access-token: et access-token lever i én time, så en planlagt kjøring som går én gang i døgnet, ville ellers stått som frakoblet mesteparten av tiden. Bærer ingen hemmelighet — et levende token svares på med ja eller nei, aldri med verdien. Krever editor-mandat.';

revoke execute on function api.agent_runner_connections() from public;
grant execute on function api.agent_runner_connections() to authenticated;

-- ============================================================================
-- 9. Tilkoblingsflyten
--
-- Fire funksjoner, alle gitt til `anon`, alle uten brukersesjon — samme form og
-- samme begrunnelse som api.claim_pipeline_job(text, text, text, integer):
-- en kjører har ingen brukerkonto, så legitimasjonen og ikke Data API-rollen er
-- kontrollen (migrasjon 005e).
--
-- MCP-serveren er ren transport. Den holder ingen hemmelighet av egen kraft, og
-- den kan derfor ikke gi seg selv mer enn kalleren allerede har.
-- ============================================================================

-- PKCE, regnet med de samme reglene på begge sider.
create function workflow.pkce_s256_challenge(p_code_verifier text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select rtrim(
    translate(encode(sha256(convert_to(p_code_verifier, 'UTF8')), 'base64'), '+/', '-_'),
    '=')
$$;

comment on function workflow.pkce_s256_challenge(text) is
  'PKCE-utfordringen (S256, base64url uten utfylling) som hører til en code_verifier (RFC 7636). Bare S256 finnes: en kode utstedt mot en ren tekst-utfordring ville vært en kode uten PKCE i praksis.';

revoke execute on function workflow.pkce_s256_challenge(text) from public;

create function api.register_agent_runner_client(
  p_client_name text,
  p_redirect_uris text[]
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_client_id text;
  v_count bigint;
begin
  -- Registreringen er åpen, som RFC 7591 forutsetter, og gir ingen tilgang i
  -- det hele tatt: uten en innløst tilkoblingskode kan klienten ikke få et
  -- eneste token. Taket finnes for at en åpen vei ikke skal kunne fylle en
  -- tabell, ikke fordi raden er farlig.
  --
  -- Taket er en TAKT og ikke et livstidstall. Raden er append-only, så et
  -- livstidstak ville gjort en liten mengde uautentisert trafikk til en varig
  -- driftsstans: den dagen taket var nådd, kunne ingen ekte ChatGPT-klient
  -- registrere seg igjen, og oppsettet ville vært umulig å fullføre. Med et
  -- vindu går en flom over av seg selv, og den ekte tilkoblingen kan gjøres like
  -- etterpå (ANTIDEP_CONSTITUTION.md regel 4: en teknisk grense skal ikke se ut
  -- som en permanent tilstand).
  -- Telling og innsetting er én avgjørelse, og må derfor gjøres av én om
  -- gangen. Uten låsen leser samtidige registreringer hver sin tilstand fra før
  -- de andre commitet, finner alle færre enn taket og slipper alle gjennom — og
  -- en takt ville vært en grense som ikke holdt nettopp i det tilfellet den
  -- finnes for. Låsen er transaksjonslokal og slippes av seg selv; nøkkelen er
  -- utledet av hva den beskytter, slik at ingen annen lås kan kollidere med den
  -- ved et uhell.
  perform pg_catalog.pg_advisory_xact_lock(
    ('x' || pg_catalog.substr(pg_catalog.md5('workflow.agent_runner_clients'), 1, 16))::bit(64)::bigint
  );

  select count(*) into v_count
  from workflow.agent_runner_clients c
  where c.created_at > statement_timestamp() - interval '1 hour';
  if v_count >= 20 then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Det er registrert for mange OAuth-klienter mot denne appen den siste timen.',
      hint = 'Registreringen er åpen fordi MCP-autorisasjonen krever det, men takten er begrenset. Prøv igjen om en stund; grensen gjelder et vindu og ikke for alltid.';
  end if;

  if nullif(btrim(coalesce(p_client_name, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'client_name mangler.';
  end if;
  if not workflow.agent_runner_redirect_uris_are_valid(p_redirect_uris) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'redirect_uris mangler eller har en adresse som ikke godtas.',
      hint = 'Mellom én og åtte adresser, alle https — med unntak for loopback. En autorisasjonskode leveres bare til en adresse klienten registrerte på forhånd.';
  end if;

  v_client_id := replace(gen_random_uuid()::text, '-', '')
              || replace(gen_random_uuid()::text, '-', '');

  insert into workflow.agent_runner_clients (client_id, client_name, redirect_uris)
  values (v_client_id, btrim(p_client_name), p_redirect_uris);

  return jsonb_build_object(
    'client_id', v_client_id,
    'client_name', btrim(p_client_name),
    'redirect_uris', to_jsonb(p_redirect_uris)
  );
end;
$$;

comment on function api.register_agent_runner_client(text, text[]) is
  'Registrerer en OAuth-klient mot Antideps private MCP-app (RFC 7591). Gir ingen tilgang: uten en innløst tilkoblingskode fra en redaktør med mandat kan klienten ikke få et eneste token. Redirect-URI-ene er det eneste som faktisk brukes — en autorisasjonskode leveres bare til en adresse klienten registrerte på forhånd, slik at koden ikke kan omdirigeres et annet sted. EXECUTE går til anon fordi en MCP-klient ikke har brukerkonto.';

revoke execute on function api.register_agent_runner_client(text, text[]) from public;
grant execute on function api.register_agent_runner_client(text, text[]) to anon, authenticated;

-- Innløsningen: tilkoblingskoden byttes i en autorisasjonskode.
-- ----------------------------------------------------------------------------
-- Publikumet, lest én gang
--
-- RFC 8707 krever at klienten navngir MCP-serveren tokenet skal gjelde for, og
-- MCP-spesifikasjonen krever at serveren avviser et token som ble utstedt for en
-- annen. Formen kontrolleres her, slik at alle tre stedene som tar imot en
-- `resource`, leser den likt.
-- ----------------------------------------------------------------------------
create function workflow.assert_agent_runner_resource(p_resource text)
  returns text
  language plpgsql
  immutable
  set search_path = ''
as $$
declare
  v_resource text := btrim(coalesce(p_resource, ''));
begin
  if v_resource = '' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'resource mangler.',
      hint = 'Et token skal utstedes for én navngitt MCP-server (RFC 8707). Et token uten publikum passer overalt.';
  end if;
  if v_resource !~ '^https?://[^\s#]+$' or length(v_resource) > 300 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%L er ikke en kanonisk ressursadresse.', v_resource),
      hint = 'Adressen skal være absolutt og uten fragment, slik RFC 8707 og RFC 9728 beskriver.';
  end if;
  return v_resource;
end;
$$;

comment on function workflow.assert_agent_runner_resource(text) is
  'Leser og kontrollerer den kanoniske adressen et token skal gjelde for (RFC 8707). Én implementasjon, slik at autorisasjonen, innvekslingen og fornyelsen ikke kan bli uenige om hva en gyldig ressursadresse er.';

revoke execute on function workflow.assert_agent_runner_resource(text) from public;

create function api.authorize_agent_runner(
  p_pairing_code text,
  p_client_id text,
  p_redirect_uri text,
  p_code_challenge text,
  p_code_challenge_method text default 'S256',
  p_resource text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_secret workflow.agent_runner_secrets;
  v_connection workflow.agent_runner_connections;
  v_client workflow.agent_runner_clients;
  v_code text;
  v_expires timestamptz;
  v_resource text;
begin
  v_resource := workflow.assert_agent_runner_resource(p_resource);

  if p_code_challenge_method is distinct from 'S256' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Bare PKCE med S256 godtas.',
      hint = 'En kode utstedt mot en ren tekst-utfordring ville vært en kode uten PKCE i praksis.';
  end if;
  if p_code_challenge is null or p_code_challenge !~ '^[A-Za-z0-9_-]{43}$' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'code_challenge har ikke formen en S256-utfordring skal ha.';
  end if;

  select c.* into v_client
  from workflow.agent_runner_clients c
  where c.client_id = p_client_id;
  if not found or not (p_redirect_uri = any (v_client.redirect_uris)) then
    -- Klienten og adressen svares på med det samme avslaget som koden: en
    -- kaller som kunne skille dem, kunne kartlagt registrerte klienter.
    perform workflow.reject_agent_runner_authentication();
  end if;

  select s.* into v_secret
  from workflow.agent_runner_secrets s
  where s.kind = 'pairing_code'
    and s.secret_hash = workflow.agent_runner_secret_hash('pairing_code', p_pairing_code)
    and s.consumed_at is null
    and s.revoked_at is null
    and s.expires_at > statement_timestamp()
  for update;

  if not found then
    perform workflow.reject_agent_runner_authentication();
  end if;

  select c.* into v_connection
  from workflow.agent_runner_connections c
  where c.id = v_secret.connection_id
    and c.valid_from <= statement_timestamp()
    and c.valid_to is null;
  if not found then
    perform workflow.reject_agent_runner_authentication();
  end if;

  update workflow.agent_runner_secrets
  set consumed_at = statement_timestamp()
  where id = v_secret.id;

  v_code := workflow.new_agent_runner_secret();
  v_expires := statement_timestamp() + interval '2 minutes';

  insert into workflow.agent_runner_secrets
    (kind, secret_hash, connection_id, client_id, redirect_uri, code_challenge,
     resource, parent_id, expires_at)
  values
    ('authorization_code', workflow.agent_runner_secret_hash('authorization_code', v_code),
     v_connection.id, v_client.client_id, p_redirect_uri, p_code_challenge,
     v_resource, v_secret.id, v_expires);

  return jsonb_build_object(
    'authorization_code', v_code,
    'expires_at', v_expires,
    'connection_key', v_connection.connection_key,
    'display_name', v_connection.display_name,
    'agent_role', v_connection.agent_role::text
  );
end;
$$;

comment on function api.authorize_agent_runner(text, text, text, text, text, text) is
  'Bytter én engangs tilkoblingskode i én OAuth-autorisasjonskode, bundet til klienten, redirect-adressen, PKCE-utfordringen og den MCP-serveren tokenet skal gjelde for (ANTIDEP_CONSTITUTION.md regel 7, RFC 8707). Tilkoblingskoden brukes opp i det samme kallet. p_resource er påkrevd og arves av tokenparet: uten den ville tokenet vært uten publikum, og et token uten publikum passer overalt. En ukjent klient, en uregistrert adresse og en ugyldig kode svares på med det samme avslaget: en kaller som kunne skille dem, kunne kartlagt registrerte klienter. EXECUTE går til anon fordi tilkoblingen skjer uten brukersesjon; koden og ikke Data API-rollen er kontrollen.';

revoke execute on function api.authorize_agent_runner(text, text, text, text, text, text) from public;
grant execute on function api.authorize_agent_runner(text, text, text, text, text, text) to anon, authenticated;

-- Tokenutstedelsen, felles for den første utvekslingen og for fornyelsen.
create function workflow.issue_agent_runner_tokens(
  p_connection_id uuid,
  p_client_id text,
  p_parent_id uuid,
  p_resource text
)
  returns jsonb
  language plpgsql
  volatile
  set search_path = ''
as $$
declare
  v_access text := workflow.new_agent_runner_secret();
  v_refresh text := workflow.new_agent_runner_secret();
  v_access_expires timestamptz := statement_timestamp() + interval '1 hour';
begin
  insert into workflow.agent_runner_secrets
    (kind, secret_hash, connection_id, client_id, parent_id, resource, expires_at)
  values
    ('access_token', workflow.agent_runner_secret_hash('access_token', v_access),
     p_connection_id, p_client_id, p_parent_id, p_resource, v_access_expires),
    ('refresh_token', workflow.agent_runner_secret_hash('refresh_token', v_refresh),
     p_connection_id, p_client_id, p_parent_id, p_resource,
     statement_timestamp() + interval '90 days');

  return jsonb_build_object(
    'access_token', v_access,
    'refresh_token', v_refresh,
    'token_type', 'Bearer',
    'expires_in', 3600,
    'expires_at', v_access_expires
  );
end;
$$;

comment on function workflow.issue_agent_runner_tokens(uuid, text, uuid, text) is
  'Utsteder ett access-token og ett refresh-token for en tilkobling og én navngitt MCP-server, og lagrer bare fingeravtrykkene. Access-tokenet lever i én time, refresh-tokenet i nitti dager: en planlagt kjøring skal overleve en ferie uten at noen kobler til på nytt, mens et lekket access-token blir ubrukelig av seg selv. p_resource arves fra autorisasjonskoden eller fra det refresh-tokenet som ble rotert, slik at publikumet aldri kan skifte underveis i en tilkobling.';

revoke execute on function workflow.issue_agent_runner_tokens(uuid, text, uuid, text) from public;

create function api.exchange_agent_runner_code(
  p_code text,
  p_code_verifier text,
  p_client_id text,
  p_redirect_uri text,
  p_resource text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_secret workflow.agent_runner_secrets;
  v_connection workflow.agent_runner_connections;
  v_resource text;
begin
  -- `resource` skal følge tokenforespørselen og ikke bare autorisasjonen
  -- (RFC 8707), og den må være den samme begge steder: en kode utstedt for
  -- denne appen skal ikke kunne veksles inn i et token for en annen.
  v_resource := workflow.assert_agent_runner_resource(p_resource);

  select s.* into v_secret
  from workflow.agent_runner_secrets s
  where s.kind = 'authorization_code'
    and s.secret_hash = workflow.agent_runner_secret_hash('authorization_code', p_code)
    and s.consumed_at is null
    and s.revoked_at is null
    and s.expires_at > statement_timestamp()
    and s.client_id = p_client_id
    and s.redirect_uri = p_redirect_uri
    and s.resource = v_resource
  for update;

  if not found then
    perform workflow.reject_agent_runner_authentication();
  end if;

  -- PKCE. Uten den kunne en avlyttet kode innløses av en annen enn den som ba
  -- om den, og hele tilkoblingen ville hvilt på at redirect-adressen aldri lakk.
  if v_secret.code_challenge is distinct from workflow.pkce_s256_challenge(coalesce(p_code_verifier, '')) then
    perform workflow.reject_agent_runner_authentication();
  end if;

  select c.* into v_connection
  from workflow.agent_runner_connections c
  where c.id = v_secret.connection_id
    and c.valid_from <= statement_timestamp()
    and c.valid_to is null;
  if not found then
    perform workflow.reject_agent_runner_authentication();
  end if;

  update workflow.agent_runner_secrets
  set consumed_at = statement_timestamp()
  where id = v_secret.id;

  return workflow.issue_agent_runner_tokens(
      v_connection.id, p_client_id, v_secret.id, v_secret.resource)
    || jsonb_build_object('scope', 'antidep.agent-runner');
end;
$$;

comment on function api.exchange_agent_runner_code(text, text, text, text, text) is
  'Bytter en autorisasjonskode i et token-par (OAuth 2.1 med PKCE). Koden brukes opp, er bundet til klienten, redirect-adressen, PKCE-utfordringen og ressursen, og lever i to minutter. p_resource er påkrevd og må være den samme som autorisasjonen ble gjort for (RFC 8707): en kode utstedt for denne appen skal ikke kunne veksles inn i et token for en annen. Ethvert avvik svares på med det samme avslaget. EXECUTE går til anon fordi utvekslingen skjer uten brukersesjon.';

revoke execute on function api.exchange_agent_runner_code(text, text, text, text, text) from public;
grant execute on function api.exchange_agent_runner_code(text, text, text, text, text) to anon, authenticated;

create function api.refresh_agent_runner_token(
  p_refresh_token text,
  p_client_id text,
  p_resource text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_secret workflow.agent_runner_secrets;
  v_connection workflow.agent_runner_connections;
  v_resource text;
begin
  v_resource := workflow.assert_agent_runner_resource(p_resource);

  select s.* into v_secret
  from workflow.agent_runner_secrets s
  where s.kind = 'refresh_token'
    and s.secret_hash = workflow.agent_runner_secret_hash('refresh_token', p_refresh_token)
    and s.consumed_at is null
    and s.revoked_at is null
    and s.expires_at > statement_timestamp()
    and s.client_id = p_client_id
    -- Publikumet kan ikke skifte i en fornyelse: et refresh-token for denne
    -- appen skal ikke kunne veksles inn i et access-token for en annen.
    and s.resource = v_resource
  for update;

  if not found then
    perform workflow.reject_agent_runner_authentication();
  end if;

  select c.* into v_connection
  from workflow.agent_runner_connections c
  where c.id = v_secret.connection_id
    and c.valid_from <= statement_timestamp()
    and c.valid_to is null;
  if not found then
    perform workflow.reject_agent_runner_authentication();
  end if;

  -- Rotasjon: det brukte refresh-tokenet er brukt opp, og det gamle
  -- access-tokenet trekkes tilbake. Uten rotasjonen ville et lekket
  -- refresh-token vært en varig tilgang ingen kunne se at fantes.
  update workflow.agent_runner_secrets
  set consumed_at = statement_timestamp()
  where id = v_secret.id;

  -- Rotasjonen gjelder ETT token-par, ikke hele tilkoblingen.
  --
  -- Access-tokenet og refresh-tokenet ble utstedt i det samme kallet og deler
  -- derfor opphav; søsknet finnes på `parent_id`. Den samme tilkoblingen kan ha
  -- flere levende par — en ny tilkoblingskode gir en ny autorisasjon — og en
  -- fornyelse som trakk tilbake alle, ville latt to lovlige kjøringer slå
  -- hverandre ut annenhver gang, uten at noe var galt. Én rotasjon skal koste
  -- nøyaktig det paret som ble rotert.
  update workflow.agent_runner_secrets
  set revoked_at = statement_timestamp()
  where connection_id = v_connection.id
    and kind = 'access_token'
    and parent_id = v_secret.parent_id
    and revoked_at is null
    and expires_at > statement_timestamp();

  return workflow.issue_agent_runner_tokens(
      v_connection.id, p_client_id, v_secret.id, v_secret.resource)
    || jsonb_build_object('scope', 'antidep.agent-runner');
end;
$$;

comment on function api.refresh_agent_runner_token(text, text, text) is
  'Fornyer et token-par mot et refresh-token, med rotasjon: det brukte refresh-tokenet er brukt opp, og access-tokenet som ble utstedt sammen med det, trekkes tilbake i samme kall (ANTIDEP_CONSTITUTION.md regel 7). Uten rotasjonen ville et lekket refresh-token vært en varig tilgang ingen kunne se at fantes. Rotasjonen gjelder nøyaktig det ene paret, funnet på felles parent_id: en tilkobling kan ha flere levende par, og en fornyelse som trakk tilbake alle, ville latt to lovlige kjøringer slå hverandre ut annenhver gang. En tilkobling som er trukket tilbake, kan ikke fornyes — tilbaketrekkingen virker da med det samme framfor når tokenet tilfeldigvis løper ut.';

revoke execute on function api.refresh_agent_runner_token(text, text, text) from public;
grant execute on function api.refresh_agent_runner_token(text, text, text) to anon, authenticated;

-- ============================================================================
-- 10. Arbeidsflaten den autonome kjøreren ser
--
-- Fem operasjoner, og ikke én til. Ingen SQL, ingen tabellesing, ingen generell
-- databaseadgang: kjøreren kan spørre om det finnes arbeid i sitt eget ledd, ta
-- én oppgave, lese den, levere ett svar, og gi oppgaven fra seg igjen.
--
-- Rollen er ikke en parameter. Den er tilkoblingens egen, og et token kan derfor
-- aldri hente arbeid i et annet agentledd enn det mennesket registrerte det for
-- (ANTIDEP_CONSTITUTION.md regel 3).
-- ============================================================================
-- Hvem tokenet tilhører.
--
-- Transportlaget kaller denne på hver forespørsel, slik at et token som er
-- utløpt eller trukket tilbake, gir 401 med det samme framfor å se ut som en
-- levende tilkobling helt til det første verktøykallet. Klienten trenger nettopp
-- den 401-en for å vite at den skal fornye.
create function api.agent_runner_identity(
  p_access_token text,
  p_resource text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_connection workflow.agent_runner_connections;
begin
  v_connection := workflow.authenticated_runner_connection(p_access_token, p_resource);
  return jsonb_build_object(
    'connection_key', v_connection.connection_key,
    'display_name', v_connection.display_name,
    'agent_role', v_connection.agent_role::text,
    'platform_model_disclosure', v_connection.platform_model_disclosure::text
  );
end;
$$;

comment on function api.agent_runner_identity(text, text) is
  'Hvilken tilkobling et access-token tilhører, og hvilket agentledd den utfører. Bærer ingen hemmelighet og skriver ingenting. Transportlaget kaller den på hver forespørsel med sin egen kanoniske adresse som p_resource, slik at publikumet kontrolleres i det samme predikatet som tokenet (RFC 8707): et token utstedt for en annen MCP-server avvises her, før noe utføres. Et utløpt eller tilbaketrukket token gir på samme vis et avslag med det samme framfor å se ut som en levende tilkobling helt til det første verktøykallet — klienten trenger nettopp det avslaget for å vite at den skal fornye. EXECUTE går til anon: tokenet og ikke Data API-rollen er kontrollen.';

revoke execute on function api.agent_runner_identity(text, text) from public;
grant execute on function api.agent_runner_identity(text, text) to anon, authenticated;

create function api.list_pending_agent_tasks(p_access_token text, p_resource text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
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
$$;

comment on function api.list_pending_agent_tasks(text, text) is
  'Hva som venter i nettopp dette agentleddet, slik en autonom kjører trenger det: hva oppgaven gjelder, og en ugjennomsiktig henvisning (ANTIDEP_CONSTITUTION.md regel 2, 4). Inneholder ingen forskningsartikkel og ingen databaseidentitet — hele oppgaven hentes først når den faktisk er tatt, slik at én planlagt kjøring ikke laster ned hele fulltekstbiblioteket bare for å se hva som finnes. blocked_count teller de oppgavene som venter på et menneske, fordi «ingen arbeid» og «faglig blokkert» er to forskjellige tilstander. Rollen er tilkoblingens egen og ikke en parameter. EXECUTE går til anon: tokenet og ikke Data API-rollen er kontrollen.';

revoke execute on function api.list_pending_agent_tasks(text, text) from public;
grant execute on function api.list_pending_agent_tasks(text, text) to anon, authenticated;

create function api.claim_agent_task(
  p_access_token text,
  p_resource text,
  p_task_ref text default null,
  p_lease_seconds integer default 900
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_connection workflow.agent_runner_connections;
  v_job workflow.pipeline_jobs;
  v_identity provenance.agent_identities;
  v_from workflow.pipeline_job_state;
  v_lease uuid;
  v_problem text;
begin
  v_connection := workflow.authenticated_runner_connection(p_access_token, p_resource);

  if p_lease_seconds is null or p_lease_seconds < 30 or p_lease_seconds > 86400 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Leietiden %s sekunder er utenfor 30–86400.', coalesce(p_lease_seconds::text, 'NULL')),
      hint = 'En leie som er for kort, utløper mens arbeidet pågår og lar to kjøringer ta det samme oppdraget. En som er for lang, holder et oppdrag utilgjengelig lenge etter at kjøringen er borte.';
  end if;

  select ai.* into v_identity
  from provenance.agent_identities ai
  where ai.agent_role = v_connection.agent_role
    and ai.valid_from <= statement_timestamp()
    and (ai.valid_to is null or ai.valid_to > statement_timestamp())
  order by ai.valid_from
  limit 1;

  if v_identity.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig agentidentitet å ta ut arbeid under.', v_connection.agent_role);
  end if;

  -- `skip locked` framfor å vente, som i api.claim_pipeline_job: to planlagte
  -- kjøringer som spør samtidig, skal få hver sin oppgave eller ingen — aldri
  -- den samme. Utførbarheten leses av den ene regelen køen og importen leser,
  -- slik at de tre ikke kan bli uenige.
  select j.* into v_job
  from workflow.pipeline_jobs j
  join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
  where j.agent_role = v_connection.agent_role
    and (p_task_ref is null
         or workflow.agent_runner_task_ref(v_connection.id, j.id) = p_task_ref)
    and workflow.agent_task_problem(j) is null
  order by j.enqueued_at, j.id
  for update of j skip locked
  limit 1;

  if not found then
    perform workflow.record_agent_runner_event(
      v_connection.id, 'claim_agent_task',
      case when p_task_ref is null then 'no_work'::workflow.agent_runner_outcome
           else 'stale_task'::workflow.agent_runner_outcome end,
      v_connection.agent_role, null,
      case when p_task_ref is not null
        then 'Oppgavehenvisningen gjaldt ingen oppgave som kunne tas nå.' end
    );
    return jsonb_build_object(
      'claimed', false,
      'agent_role', v_connection.agent_role::text,
      'reason', case when p_task_ref is null then 'no_work' else 'stale_task' end
    );
  end if;

  -- Låsen er tatt nå. Vilkårene leses en gang til på den låste raden, fordi
  -- utvalget leste dem før låsen: uten dette ville et uttak kunnet hvile på en
  -- tilstand som rakk å endre seg i mellomtiden.
  v_problem := workflow.agent_task_problem(v_job);
  if v_problem is not null then
    perform workflow.record_agent_runner_event(
      v_connection.id, 'claim_agent_task', 'blocked'::workflow.agent_runner_outcome,
      v_connection.agent_role, v_job.id, 'Oppgaven ble utilgjengelig mellom utvalget og låsen.');
    return jsonb_build_object(
      'claimed', false,
      'agent_role', v_connection.agent_role::text,
      'reason', 'blocked'
    );
  end if;

  v_from := v_job.state;
  v_lease := gen_random_uuid();

  update workflow.pipeline_jobs j
  set state = 'leased',
      attempts = j.attempts + 1,
      leased_by_agent_identity_id = v_identity.id,
      lease_token = v_lease,
      lease_expires_at = statement_timestamp() + make_interval(secs => p_lease_seconds),
      -- Hvem som holder uttaket, og ikke bare hvilken rolle det tilhører.
      -- Identiteten deles av alle kjørere i leddet; tilkoblingen er denne ene.
      runner_connection_id = v_connection.id,
      completed_at = null
  where j.id = v_job.id
  returning * into v_job;

  perform workflow.record_pipeline_job_event(
    v_job.id, v_from, 'leased'::workflow.pipeline_job_state, v_job.attempts,
    null, v_identity.id,
    'Uttak av en autonom kjører over MCP.'
  );

  perform workflow.record_agent_runner_event(
    v_connection.id, 'claim_agent_task', 'ok'::workflow.agent_runner_outcome,
    v_connection.agent_role, v_job.id);

  -- Håndtaket ER leienøkkelen. En kjøring uten den gjeldende nøkkelen kan verken
  -- lese oppgaven eller levere et svar, og nøkkelen byttes ut ved hvert uttak —
  -- så et håndtak fra en utløpt leie treffer ingenting (DATABASE_ARCHITECTURE.md §33).
  return jsonb_build_object(
    'claimed', true,
    'task_handle', v_lease,
    'agent_role', v_job.agent_role::text,
    'subject_kind', coalesce(workflow.agent_task_subject(v_job) ->> 'kind', 'oppgave'),
    'subject_label', coalesce(workflow.agent_task_subject(v_job) ->> 'label', v_job.job_key),
    'attempt', v_job.attempts,
    'max_attempts', v_job.max_attempts,
    'lease_expires_at', v_job.lease_expires_at
  );
end;
$$;

comment on function api.claim_agent_task(text, text, text, integer) is
  'Tar ut én ekstern agentoppgave for tilkoblingens eget agentledd, med en leie som løper ut (DATABASE_ARCHITECTURE.md §33, §43). Bruker FOR UPDATE SKIP LOCKED og leser utførbarheten på nytt etter at låsen er tatt, slik at to planlagte kjøringer som spør samtidig aldri kan få den samme oppgaven, og slik at et uttak ikke hviler på en tilstand som rakk å endre seg. En oppgave med en løpende leie er ikke ledig; en med utløpt leie er det, fordi nettopp den tilstanden skal overleve at en kjøring døde. Svarer {claimed: false, reason: "no_work"} når det ikke finnes arbeid; det er ikke en feil. Håndtaket som returneres, ER uttakets leienøkkel: den byttes ut ved hvert uttak, så et håndtak fra en utløpt leie treffer ingenting. EXECUTE går til anon: tokenet og ikke Data API-rollen er kontrollen.';

revoke execute on function api.claim_agent_task(text, text, text, integer) from public;
grant execute on function api.claim_agent_task(text, text, text, integer) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Hvorfor oppgaven kan leses to steder fra
--
-- MCP-serveren leser oppgaven én gang til inne i `submit_agent_answer`: de
-- deterministiske kontrollene trenger kildeteksten, og protokollen er
-- tilstandsløs, så det finnes ingen lesning å huske fra forrige kall.
--
-- Den lesningen er ikke et verktøykall, og sporet skal ikke påstå at den var
-- det. Den har derfor sitt eget navn — og navnet ER funksjonen kalleren traff,
-- ikke en verdi hen sendte med. En etikett kalleren valgte, ville latt en
-- tokeninnehaver få databasen til å skrive at en levering fant sted; en
-- forhåndslesning påstår ingenting annet enn at noen leste oppgaven, og det er
-- nøyaktig det som skjedde.
--
-- Ingen av de to kan lese uten å etterlate seg en rad. En stille lesning ville
-- vært et sted kildetekst kunne forlate databasen uten at sporet visste det.
--
-- Implementasjonen er én, slik at de to aldri kan bli uenige om hvem som får
-- se hva.
-- ----------------------------------------------------------------------------
create function workflow.agent_task_for_connection(
  p_connection workflow.agent_runner_connections,
  p_task_handle uuid,
  p_tool_name text
)
  returns jsonb
  language plpgsql
  volatile
  set search_path = ''
as $$
declare
  v_job workflow.pipeline_jobs;
begin
  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.lease_token = p_task_handle
    and j.state = 'leased'
    and j.lease_expires_at > statement_timestamp()
    and j.agent_role = p_connection.agent_role;

  if not found then
    perform workflow.record_agent_runner_event(
      p_connection.id, p_tool_name, 'stale_task'::workflow.agent_runner_outcome,
      p_connection.agent_role, null,
      'Håndtaket gjaldt ingen oppgave denne kjøreren holder nå.');
    return jsonb_build_object(
      'available', false,
      'reason', 'stale_task',
      'agent_role', p_connection.agent_role::text
    );
  end if;

  perform workflow.record_agent_runner_event(
    p_connection.id, p_tool_name, 'ok'::workflow.agent_runner_outcome,
    p_connection.agent_role, v_job.id);

  return jsonb_build_object(
    'available', true,
    'task_handle', p_task_handle,
    'lease_expires_at', v_job.lease_expires_at,
    -- Nøyaktig den oppgaven den manuelle veien bygger, av de samme radene og
    -- med det samme avtrykket. To bygginger ville kunnet bli uenige.
    'task', workflow.agent_task(v_job)
  );
end;
$$;

comment on function workflow.agent_task_for_connection(workflow.agent_runner_connections, uuid, text) is
  'Oppgaven bak ett uttak, ført i sporet under navnet kalleren av api-funksjonen ikke kan velge. Én implementasjon for både lesningen og forhåndslesningen, slik at de to aldri kan bli uenige om hvem som får se hva.';

revoke execute on function workflow.agent_task_for_connection(workflow.agent_runner_connections, uuid, text) from public;

create function api.agent_task_for_runner(
  p_access_token text,
  p_resource text,
  p_task_handle uuid
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  return workflow.agent_task_for_connection(
    workflow.authenticated_runner_connection(p_access_token, p_resource),
    p_task_handle,
    'get_agent_task');
end;
$$;

comment on function api.agent_task_for_runner(text, text, uuid) is
  'Hele agentoppgaven for det uttaket håndtaket navngir — nøyaktig den oppgaven api.agent_task_payload(uuid) bygger, av de samme radene og med det samme avtrykket (ANTIDEP_CONSTITUTION.md regel 2). Leveres bare til den kjøreren som faktisk holder den løpende leien, og bare i tilkoblingens eget agentledd: et håndtak fra en utløpt eller overtatt leie svarer stale_task framfor å gi fra seg en forskningsartikkel. Svarer med en tilstand framfor å kaste, fordi et foreldet håndtak er en normal ting som skjer for en planlagt kjøring og ikke en teknisk feil. Fører alltid get_agent_task i sporet: navnet er funksjonen, ikke en verdi kalleren sender med.';

revoke execute on function api.agent_task_for_runner(text, text, uuid) from public;
grant execute on function api.agent_task_for_runner(text, text, uuid) to anon, authenticated;

create function api.agent_task_precheck(
  p_access_token text,
  p_resource text,
  p_task_handle uuid
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  return workflow.agent_task_for_connection(
    workflow.authenticated_runner_connection(p_access_token, p_resource),
    p_task_handle,
    'submit_agent_answer:precheck');
end;
$$;

comment on function api.agent_task_precheck(text, text, uuid) is
  'Den samme oppgaven, lest for de deterministiske kontrollene MCP-serveren kjører før en levering. Svarer nøyaktig som api.agent_task_for_runner, men fører submit_agent_answer:precheck i sporet — et navn som sier at noen LESTE oppgaven i forkant av en levering, og aldri at en levering fant sted. Navnet er funksjonen og ikke en parameter, nettopp fordi en etikett kalleren valgte, ville latt en tokeninnehaver få databasen til å skrive at et verktøykall skjedde som ikke skjedde. Det autoritative utfallet for ett MCP-kall står i én rad, skrevet av api.submit_agent_answer.';

revoke execute on function api.agent_task_precheck(text, text, uuid) from public;
grant execute on function api.agent_task_precheck(text, text, uuid) to anon, authenticated;

create function api.submit_agent_answer(
  p_access_token text,
  p_resource text,
  p_task_handle uuid,
  p_answer jsonb
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_connection workflow.agent_runner_connections;
  v_job workflow.pipeline_jobs;
  v_outcome jsonb;
  v_rejection text;
begin
  v_connection := workflow.authenticated_runner_connection(p_access_token, p_resource);

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.lease_token = p_task_handle
    and j.agent_role = v_connection.agent_role;

  if not found then
    perform workflow.record_agent_runner_event(
      v_connection.id, 'submit_agent_answer', 'stale_task'::workflow.agent_runner_outcome,
      v_connection.agent_role, null,
      'Håndtaket gjaldt ingen oppgave i dette agentleddet.');
    return jsonb_build_object(
      'accepted', false,
      'reason', 'stale_task',
      'agent_role', v_connection.agent_role::text
    );
  end if;

  -- Selve registreringen: nøyaktig den samme skriveveien et opplastet
  -- `svar.json` går gjennom, kalt under det uttaket kjøreren faktisk holder.
  --
  -- Aktøren er mennesket som registrerte kjøreren. Arbeidet er en KI-agents og
  -- står på kjøringen (provenance.agent_runs.semantic_*); dette er hvem som
  -- svarer for at det kom inn i Antidep i det hele tatt. En kjører kan ikke
  -- være sin egen fullmakt.
  --
  -- Avvisningen fanges her, og det er en egenskap ved sporet og ikke en
  -- bekvemmelighet: en avvisning ruller hele leveringen tilbake, sporet
  -- inkludert, og uten dette måtte kjøreren SELV meldt fra om at den ble
  -- avvist. En slik rad sier bare hva kjøreren sa. Fanget her er den derimot
  -- skrevet av operasjonen som faktisk fant sted — unntaksblokken ruller bare
  -- tilbake til sitt eget punkt, så raden under står igjen og commiter.
  --
  -- Teksten fra avvisningen går til kalleren, som allerede har materialet den
  -- handler om, og aldri inn i sporet.
  begin
    v_outcome := workflow.record_agent_handoff_answer(
      v_job.id, p_answer, v_connection.registered_by_actor_id, v_connection.id, p_task_handle);
  exception
    when restrict_violation or invalid_parameter_value or unique_violation then
      v_rejection := sqlerrm;
      perform workflow.record_agent_runner_event(
        v_connection.id, 'submit_agent_answer', 'rejected'::workflow.agent_runner_outcome,
        v_connection.agent_role, v_job.id,
        'Den autoritative kontrollen avviste svaret.');
      return jsonb_build_object(
        'accepted', false,
        'reason', 'rejected',
        'agent_role', v_connection.agent_role::text,
        'message', v_rejection
      );
  end;

  perform workflow.record_agent_runner_event(
    v_connection.id, 'submit_agent_answer', 'ok'::workflow.agent_runner_outcome,
    v_connection.agent_role, v_job.id);

  return jsonb_build_object('accepted', true) || v_outcome;
end;
$$;

comment on function api.submit_agent_answer(text, text, uuid, jsonb) is
  'Leverer ett agentsvar fra en autonom kjører, og registrerer det gjennom workflow.record_agent_handoff_answer(uuid, jsonb, uuid, uuid, uuid) — nøyaktig den samme autoritative skriveveien et opplastet svar.json går gjennom (ANTIDEP_CONSTITUTION.md regel 3, 4, 7). MCP-veien kan derfor ikke få større faglige skrivefullmakter enn den manuelle. Svaret leveres under det uttaket kjøreren holder: et foreldet håndtak avvises før noe skrives, og en avvisning fra den autoritative kontrollen ruller hele leveringen tilbake framfor å etterlate et halvt registrert svar. Aktøren svaret føres på, er mennesket som registrerte kjøreren — arbeidet er en KI-agents og står på kjøringen; en kjører kan ikke være sin egen fullmakt.';

revoke execute on function api.submit_agent_answer(text, text, uuid, jsonb) from public;
grant execute on function api.submit_agent_answer(text, text, uuid, jsonb) to anon, authenticated;

-- Hvorfor en kjører ga en oppgave fra seg, som en lukket klasse.
--
-- Fri tekst fra modellen ville vært modellinnhold i det operative sporet, og
-- sporet skal ikke bli et sted privat innhold eller en promptavledet setning
-- samler seg (AGENTS.md: et agentsvar er data, aldri instrukser). Klassen sier
-- det som faktisk er nyttig å vite, og Antidep skriver setningen selv.
create function workflow.agent_release_note(p_reason_code text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case p_reason_code
    when 'blocked_by_task' then 'Kjøreren mente oppgaven ikke lot seg utføre slik den er stilt.'
    when 'could_not_complete' then 'Kjøreren fikk ikke fullført arbeidet.'
    when 'out_of_time' then 'Kjøringen rakk ikke å fullføre oppgaven.'
  end;
$$;

comment on function workflow.agent_release_note(text) is
  'Antideps egen setning om hvorfor en kjører ga en oppgave fra seg, valgt av en lukket klasse kjøreren oppgir. NULL for en ukjent klasse, som kalleren avviser. Fri tekst fra modellen ville vært modellinnhold i det operative sporet, og et spor som tok imot det, ville blitt et sted en promptavledet setning eller et kildeutdrag kunne samle seg (ANTIDEP_CONSTITUTION.md regel 2, 7).';

revoke execute on function workflow.agent_release_note(text) from public;

create function api.release_agent_task(
  p_access_token text,
  p_resource text,
  p_task_handle uuid,
  p_reason_code text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_connection workflow.agent_runner_connections;
  v_job workflow.pipeline_jobs;
  v_note text;
begin
  v_connection := workflow.authenticated_runner_connection(p_access_token, p_resource);

  if p_reason_code is not null then
    v_note := workflow.agent_release_note(p_reason_code);
    if v_note is null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent grunn til å gi en oppgave fra seg.', p_reason_code),
        hint = 'Gyldige verdier er blocked_by_task, could_not_complete og out_of_time. Sporet tar ikke imot fri tekst fra en modell.';
    end if;
  end if;

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.lease_token = p_task_handle
    and j.state = 'leased'
    and j.lease_expires_at > statement_timestamp()
    and j.agent_role = v_connection.agent_role
  for update;

  if not found then
    perform workflow.record_agent_runner_event(
      v_connection.id, 'release_agent_task', 'stale_task'::workflow.agent_runner_outcome,
      v_connection.agent_role, null,
      'Håndtaket gjaldt ingen løpende leie denne kjøreren holder.');
    return jsonb_build_object('released', false, 'reason', 'stale_task');
  end if;

  update workflow.pipeline_jobs
  set state = 'ready',
      leased_by_agent_identity_id = null,
      lease_token = null,
      lease_expires_at = null
  where id = v_job.id;

  -- Forsøket står. Et uttak ER et forsøk (DATABASE_ARCHITECTURE.md §33), og en
  -- kjører som kunne gi oppgaven fra seg uten å bruke et, kunne prøvd i det
  -- uendelige uten at noe i køen fortalte at det gikk galt.
  perform workflow.record_pipeline_job_event(
    v_job.id, 'leased'::workflow.pipeline_job_state, 'ready'::workflow.pipeline_job_state,
    v_job.attempts, null, v_job.leased_by_agent_identity_id,
    'En autonom kjører ga oppgaven fra seg uten å levere et svar.'
  );

  perform workflow.record_agent_runner_event(
    v_connection.id, 'release_agent_task', 'ok'::workflow.agent_runner_outcome,
    v_connection.agent_role, v_job.id, v_note);

  return jsonb_build_object('released', true, 'agent_role', v_job.agent_role::text);
end;
$$;

comment on function api.release_agent_task(text, text, uuid, text) is
  'Gir en tatt oppgave fra seg med det samme, slik at den blir ledig igjen framfor å stå låst til leien løper ut (DATABASE_ARCHITECTURE.md §33). Forsøket står: et uttak ER et forsøk, og en kjører som kunne gi oppgaven fra seg uten å bruke et, kunne prøvd i det uendelige uten at noe i køen fortalte at det gikk galt. Grunnen er en lukket klasse og ikke fri tekst: en setning fra modellen ville vært modellinnhold i det operative sporet, og Antidep skriver derfor selv setningen klassen står for (workflow.agent_release_note(text)).';

revoke execute on function api.release_agent_task(text, text, uuid, text) from public;
grant execute on function api.release_agent_task(text, text, uuid, text) to anon, authenticated;

-- Sporet MCP-serveren skriver når selve kallet rullet tilbake.
--
-- En avvisning fra den autoritative kontrollen ruller hele transaksjonen
-- tilbake, sporet inkludert. Uten denne veien ville nettopp de kjøringene som
-- gikk galt, vært de eneste som ikke etterlot seg noe.
create function api.record_agent_runner_outcome(
  p_access_token text,
  p_resource text,
  p_tool_name text,
  p_outcome text,
  p_task_handle uuid default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_connection workflow.agent_runner_connections;
  v_outcome workflow.agent_runner_outcome;
  v_job_id uuid;
  v_tool text := btrim(coalesce(p_tool_name, ''));
begin
  v_connection := workflow.authenticated_runner_connection(p_access_token, p_resource);

  -- Navnet er ett av verktøyene, og ingenting annet.
  --
  -- Fri tekst ville latt en tokeninnehaver skrive en rad under navnet på noe
  -- bare Antidep selv skriver — en tilbaketrekking, en forhåndslesning — og
  -- sporet ville da beskrevet hendelser som aldri fant sted.
  if v_tool not in (
    'list_pending_agent_tasks', 'claim_agent_task', 'get_agent_task',
    'submit_agent_answer', 'release_agent_task'
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%L er ikke et av kjørerens verktøy.', v_tool),
      hint = 'Sporet tar bare imot navnet på et verktøy kjøreren faktisk kan kalle.';
  end if;

  begin
    v_outcome := p_outcome::workflow.agent_runner_outcome;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent utfallsklasse.', p_outcome);
  end;

  -- Og et vellykket kall kan ikke meldes inn her.
  --
  -- Denne veien finnes bare for kallet som IKKE fikk skrevet sitt eget spor:
  -- en avvisning fra den autoritative kontrollen ruller transaksjonen tilbake,
  -- sporet inkludert. Et kall som lyktes, rullet ikke tilbake, og skrev derfor
  -- sin egen rad i den samme transaksjonen som arbeidet. Uten denne grensen
  -- kunne en tokeninnehaver skrevet «ok» for et verktøykall som aldri ble gjort,
  -- og sporet ville båret en påstand om utført arbeid som ingenting sto bak.
  if v_outcome = 'ok' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et vellykket kall skriver sitt eget spor, i den samme transaksjonen som arbeidet.',
      hint = 'Denne veien er for utfallet av et kall som ikke kunne skrive sitt eget.';
  end if;

  if p_task_handle is not null then
    select j.id into v_job_id
    from workflow.pipeline_jobs j
    where j.lease_token = p_task_handle
      and j.agent_role = v_connection.agent_role;
  end if;

  -- Raden bærer at den er en selvmelding. En tokeninnehaver kan kalle denne
  -- veien direkte, og da skal raden si hva kjøreren SA — ikke stå som en rad
  -- databasen selv så.
  perform workflow.record_agent_runner_event(
    v_connection.id, v_tool, v_outcome, v_connection.agent_role, v_job_id, null, true);

  return jsonb_build_object('recorded', true, 'self_reported', true);
end;
$$;

comment on function api.record_agent_runner_outcome(text, text, text, text, uuid) is
  'Skriver ett spor etter et MCP-kall som ikke kunne skrive sitt eget (ANTIDEP_CONSTITUTION.md regel 4). En avvisning fra den autoritative kontrollen ruller hele transaksjonen tilbake, sporet inkludert; uten denne veien ville nettopp de kjøringene som gikk galt, vært de eneste som ikke etterlot seg noe. Tar bare en utfallsklasse og navnet på et av kjørerens fem verktøy — aldri en feiltekst, fordi en avvisning kan navngi en påstand eller et kildeutdrag. Kan ikke melde inn ok: et kall som lyktes, skrev sin egen rad i den samme transaksjonen som arbeidet, så den ene raden en tokeninnehaver kan legge til om seg selv, er at noe gikk galt.';

revoke execute on function api.record_agent_runner_outcome(text, text, text, text, uuid) from public;
grant execute on function api.record_agent_runner_outcome(text, text, text, text, uuid) to anon, authenticated;

-- ============================================================================
-- 11. Køen sier hvem som holder oppgaven
--
-- Den manuelle handoffen består, og de to veiene deler kø, leie og jobb. Det er
-- nettopp derfor de ikke kan gjøre dobbeltarbeid: en oppgave en planlagt kjøring
-- holder, er allerede blokkert for flaten av `workflow.agent_task_problem`.
--
-- Men «blokkert» er ikke en god nok setning når grunnen er at arbeidet gjøres
-- automatisk akkurat nå. Køen sier derfor hvilken kjører som holder den, slik at
-- den som står ved flaten, ser forskjell på «noe er i veien» og «dette går av
-- seg selv» (ANTIDEP_CONSTITUTION.md regel 4).
-- ============================================================================
create or replace function api.agent_work_queue()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
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
  ) q;

  return v_rows;
end;
$$;

comment on function api.agent_work_queue() is
  'De eksterne agentoppgavene som fortsatt venter, slik en operativ flate trenger dem: rolle, hva oppgaven gjelder, tilstand, hvilken ekstern modell leddet er tildelt, én setning om hva som eventuelt hindrer at den kan kjøres — og fra migrasjon 011a hvilken autonom kjører som eventuelt holder den akkurat nå. Bare jobber som faktisk er lagt inn som eksterne agentoppgaver (workflow.agent_handoff_jobs), og bare de som ikke har et registrert utfall. Den autonome kjøreren og den manuelle flaten deler kø, leie og jobb, og kan derfor ikke gjøre dobbeltarbeid: en oppgave en planlagt kjøring holder, er allerede blokkert for flaten av workflow.agent_task_problem. Inneholder ikke kildeteksten. Krever editor-mandat.';

revoke execute on function api.agent_work_queue() from public;
grant execute on function api.agent_work_queue() to authenticated;
