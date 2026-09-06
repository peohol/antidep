-- ============================================================================
-- Migrasjon 005e — teknisk agentidentitet og agentkjøringer
--
-- Utvider proveniensmodellen fra migrasjon 005 (§22) med de to objektene den
-- selv utsatte: den tekniske identiteten en KI-prosess handler med, og
-- kjøringen den handler i. Står utenfor den planlagte rekken i
-- MVP_IMPLEMENTATION_PLAN.md §18-§27 og får derfor en bokstav. Nummeret 009 er
-- fortsatt reservert for DrugProduct-/importfundamentet (§26).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md
--     §10 KI-arbeidet skal deles i eksplisitte roller
--     §11 verifikasjon skal forsøke å falsifisere, mot kildematerialet
--     §12 KI kan foreslå; mennesker har det faglige ansvaret
--     §14 endringer skal være attribuerte og reversible
--     §20 kunnskapsmodellen og agentpipen skal være leverandøruavhengige
--   docs/DATABASE_ARCHITECTURE.md
--     §32 provenance.actors
--     §33 provenance.agent_runs
--     §34 proveniens er en graf
--     §35-§36 audit.events og append-only
--     §43-§44 skriveveier og Data API-kontrakten
--     §45, §48-§50 roller, default deny, least privilege, privilegerte funksjoner
--     §59 cross-row-regler løses med sammensatt fremmednøkkel
--   docs/EVIDENCE_PIPELINE.md §61 agentroller, §63 minst mulig privilegier,
--     §65 modell- og pipelineversjonering
--   docs/CONTENT_GOVERNANCE.md §14 Agent Worker
--   docs/MVP_IMPLEMENTATION_PLAN.md §16 roller, §49 least privilege for agenter
--
-- ----------------------------------------------------------------------------
-- Hvorfor migrasjonen finnes: hullet §74.30 punkt 4 fant
--
-- Neste ledd i §15 er «separat verifier verifiserer ekstraksjonen».
-- workflow.evidence_verifications krever at verifikatoren er en *annen* aktør
-- enn den som laget funnet, og det er en CHECK og ikke en konvensjon. §74.30
-- leste konsekvensen ut av produksjon: de to KI-aktørene har ingen brukerkonto,
-- og kan derfor ikke kalle en skrivevei som autoriserer på den innloggede
-- brukeren. Valget stod mellom å registrere en andre navngitt person og å bygge
-- den agentidentiteten §16 forutser.
--
-- Prosjektbeslutningen er tatt, og den er ført i planen: Antidep er agent-first.
-- Kontrollen skal ligge i flere uavhengige agentledd framfor i manuelt
-- menneskearbeid, og et evidensfunn registrert av en menneskelig editor skal
-- kunne verifiseres av en KI-verifikator med egen teknisk identitet. Denne
-- migrasjonen bygger den identiteten, og bare den.
--
-- ----------------------------------------------------------------------------
-- Hva migrasjonen bevisst IKKE gjør
--
-- Den registrerer ingen verifikasjon, ingen reviewbeslutning og ingen
-- publisering, og den åpner ikke publiseringsgaten. Den bygger heller ikke
-- skriveveien inn i workflow.evidence_verifications — den hører til neste PR,
-- og bruker mekanismen her. Den svekker ingen eksisterende kontroll: ingen
-- CHECK, ingen policy, ingen grant og ingen gate er endret eller fjernet.
--
-- Særlig ikke denne: workflow.review_decisions krever fortsatt en *menneskelig*
-- aktør, deklarativt håndhevet med sammensatt fremmednøkkel. En agentidentitet
-- kan derfor ikke registrere en faglig godkjenning uansett hvilken rolle den
-- har. ANTIDEP_CONSTITUTION.md §12 er ikke endret av denne migrasjonen, og skal
-- ikke kunne endres av kode (Konstitusjonens innledning).
--
-- ----------------------------------------------------------------------------
-- Tre lag som håndhever «en agent skal ikke verifisere sitt eget arbeid»
--
--   1. Rollen er rettighetsgrensen. En agentidentitet har nøyaktig én
--      provenance.agent_role, og provenance.authenticate_agent_identity()
--      krever den rollen operasjonen faktisk trenger. Ekstraksjonsidentiteten
--      kan derfor ikke autentisere seg for en verifikasjonsoperasjon i det hele
--      tatt — den avvises før den rører et kunnskapsobjekt.
--   2. Aktøren er den samme grensen på raden. workflow.evidence_verifications
--      sin evidence_verifications_separate_actor_check avviser en rad der
--      verifikator og ekstraktør er samme aktør, uansett hvordan raden kom dit.
--   3. Kjøringen kan låses til begge deler. provenance.agent_runs bærer
--      speilkolonner for aktør og rolle, låst til identiteten av sammensatte
--      fremmednøkler, og eksponerer selv (id, actor_id) og (id, agent_role) som
--      unike nøkler. Neste PR kan derfor kreve deklarativt at en verifikasjon
--      peker på en kjøring i riktig rolle, utført av den aktøren raden
--      attribuerer den til (DATABASE_ARCHITECTURE.md §59).
--
-- Lag 1 og 2 er uavhengige: den ene svikter ikke fordi den andre gjør det.
--
-- ----------------------------------------------------------------------------
-- Hvorfor identiteten er en legitimasjon i basen og ikke en brukerkonto
--
-- provenance.actors sin actors_auth_user_is_human_check forbyr at en agent har
-- en rad i auth.users, og MVP_IMPLEMENTATION_PLAN.md §16 sier hvorfor:
-- agentbrukere skal ikke representeres som vanlige menneskelige brukere. En
-- agent kan derfor ikke logge inn, og auth.uid() er NULL for enhver
-- agentoperasjon.
--
-- service_role var det opplagte alternativet og er avvist av
-- DATABASE_ARCHITECTURE.md §49: den omgår RLS, er én felles nøkkel med full
-- tilgang, og gir ingen rolleseparasjon mellom agentledd. En nøkkel som kan alt,
-- kan også verifisere sitt eget arbeid.
--
-- Identiteten er derfor en egen rad med sin egen legitimasjon, og rettighetene
-- følger av rollen på aktøren den peker på. Det gir nøyaktig det §49 ber om:
-- egne least-privilege-identiteter framfor en felles nøkkel med full tilgang.
--
-- ----------------------------------------------------------------------------
-- Hvorfor legitimasjonen aldri lagres i klartekst
--
-- secret_hash lagrer sha256 av «identitetsnøkkel:hemmelighet», ikke av
-- hemmeligheten alene. Bindingen til identitetsnøkkelen gjør at en lekket hash
-- ikke kan spilles av mot en annen identitet, selv om to identiteter mot all
-- formodning skulle fått samme hemmelighet. Prefikset sha256-v1 versjonerer
-- definisjonen, som content_hash gjør (migrasjon 003, 006a).
--
-- Sammenligningen er en vanlig likhet på hashen og ikke en konstanttidsrutine.
-- Det er et bevisst valg: hashen er ikke hemmeligheten, og en angriper som
-- skulle lese ut hele hashen gjennom tidsmåling, ville måtte finne et preimage
-- for å bruke den. Hemmeligheten selv er 256 bits fra databasens egen
-- kryptografiske tilfeldighetskilde.
--
-- pgcrypto er ikke innført. sha256() og gen_random_uuid() er begge i
-- PostgreSQL-kjernen, og migrasjon 001 sin regel er at en extension legges til
-- av den migrasjonen som faktisk trenger den — ikke «for sikkerhets skyld».
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. provenance.actors blir refererbar på (id, agent_role)
--
-- Samme mønster som actors_id_type_key, som migrasjon 005 innførte for at
-- workflow.review_decisions skulle kunne kreve deklarativt at en reviewer er et
-- menneske (DATABASE_ARCHITECTURE.md §59). Her er behovet det samme, én grad
-- finere: agentidentiteten skal kunne låse rollen sin til aktørens rolle, slik
-- at de to aldri kan komme i utakt.
--
-- Nøkkelen gjør samtidig én ting til, og det er den viktigste: fordi
-- agent_identities.agent_role er NOT NULL og actors_agent_role_check sier at
-- agent_role er satt hvis og bare hvis aktørtypen er `agent`, følger det av
-- fremmednøkkelen alene at en agentidentitet aldri kan peke på et menneske, en
-- deterministisk prosess eller en systemaktør. Ingen egen aktørtypekontroll
-- trengs på identiteten.
-- ----------------------------------------------------------------------------
alter table provenance.actors
  add constraint actors_id_agent_role_key unique (id, agent_role);

comment on constraint actors_id_agent_role_key on provenance.actors is
  'Gjør (id, agent_role) refererbar, slik at provenance.agent_identities kan låse identitetens rolle til aktørens rolle med en sammensatt fremmednøkkel framfor med en CHECK som ikke kan se den andre raden (DATABASE_ARCHITECTURE.md §59). Fordi agent_role er satt hvis og bare hvis aktørtypen er agent, følger det av samme fremmednøkkel at en agentidentitet ikke kan peke på en aktør som ikke er en agent.';

-- ----------------------------------------------------------------------------
-- 2. provenance.agent_run_status — livssyklusen til én agentoperasjon
--
-- DATABASE_ARCHITECTURE.md §33 lister `status` som minimumsfelt på en
-- agentkjøring. Vokabularet er et kontrollert vokabular og håndheves
-- deklarativt som enum (§57, §72), som resten av basen.
--
-- `aborted` er ikke det samme som `failed`, og skillet er verdt en egen verdi:
-- en kjøring som ble stoppet — av en tidsgrense, av en operatør, av et
-- pipelinesteg foran den — har ikke sagt noe om det den skulle vurdere. En
-- kjøring som feilet, har det heller ikke, men av en annen grunn. Å slå dem
-- sammen ville gjort feilraten (§40) umulig å lese.
-- ----------------------------------------------------------------------------
create type provenance.agent_run_status as enum (
  'running',
  'succeeded',
  'failed',
  'aborted'
);

comment on type provenance.agent_run_status is
  'Tilstanden til én agentkjøring (DATABASE_ARCHITECTURE.md §33): running (kjøringen er åpen og kan produsere objekter), succeeded (kjøringen fullførte og har et outputmanifest), failed (kjøringen feilet) og aborted (kjøringen ble stoppet før den konkluderte). failed og aborted holdes adskilt fordi de betyr forskjellige ting for kvalitetsmålingen i MVP_IMPLEMENTATION_PLAN.md §40. Bare running er en åpen tilstand; de tre andre er endelige.';

revoke usage on type provenance.agent_run_status from public;

-- ----------------------------------------------------------------------------
-- 3. provenance.agent_identities — den tekniske identiteten en agent handler med
--
-- Én identitet per agentaktør. Rollen er ikke en egenskap ved legitimasjonen,
-- men ved aktøren: en identitet som kunne bytte rolle, ville vært en identitet
-- som kunne gi seg selv nye rettigheter (CONTENT_GOVERNANCE.md §14).
--
-- Flere kontrollag skaleres ved å registrere flere aktører med samme rolle, ikke
-- ved å gi én identitet flere roller. To uavhengige ekstraksjonsverifikatorer er
-- to aktører, to identiteter og to kjøringer — og
-- workflow.evidence_verifications er append-only, så begge kontrollene består
-- ved siden av hverandre.
--
-- Legitimasjonen er skilt fra registreringen med hensikt. En nyregistrert
-- identitet har secret_hash NULL og kan ikke autentisere seg i det hele tatt:
-- den er inert til noen utsteder legitimasjon til den. Å opprette en identitet
-- og å gi den evnen til å handle er to forskjellige handlinger, og de har hver
-- sin auditoperasjon.
-- ----------------------------------------------------------------------------
create table provenance.agent_identities (
  id uuid primary key default gen_random_uuid(),

  actor_id uuid not null,
  -- Speil av aktørens rolle, låst av den sammensatte fremmednøkkelen under.
  -- Ikke en selvstendig sannhet, som speilkolonnene i migrasjon 004 og 005.
  agent_role provenance.agent_role not null,

  identity_key text not null,

  -- Legitimasjonen. NULL betyr «ikke utstedt ennå», ikke «ingen kontroll»:
  -- provenance.authenticate_agent_identity() avviser en identitet uten hash.
  secret_hash text,
  secret_version integer not null default 0,
  secret_issued_at timestamptz,
  secret_issued_by_actor_id uuid,
  secret_issued_by_actor_type provenance.actor_type,

  valid_from timestamptz not null default now(),
  valid_to timestamptz,

  registered_by_actor_id uuid not null,
  registered_by_actor_type provenance.actor_type not null,
  registration_reason text not null,

  revoked_by_actor_id uuid,
  revoked_by_actor_type provenance.actor_type,
  revocation_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Identiteten er aktørens, og aktøren er en agent. Se avsnitt 1 for hvorfor
  -- denne ene fremmednøkkelen også utelukker alle andre aktørtyper.
  constraint agent_identities_actor_fkey
    foreign key (actor_id, agent_role)
    references provenance.actors (id, agent_role)
    on update restrict on delete restrict,

  -- Én identitet per aktør. Uten regelen kunne samme agentaktør hatt to
  -- legitimasjoner, og en tilbakekalling ville ikke vært en tilbakekalling.
  constraint agent_identities_actor_key unique (actor_id),
  constraint agent_identities_identity_key_key unique (identity_key),

  -- Gjør identiteten refererbar sammen med sin aktør og sin rolle, slik at
  -- provenance.agent_runs kan låse begge speilkolonnene sine (avsnitt 4).
  constraint agent_identities_id_actor_key unique (id, actor_id),
  constraint agent_identities_id_role_key unique (id, agent_role),

  -- Bare et menneske kan gi en maskin rett til å handle i Antidep, og bare et
  -- menneske kan utstede legitimasjonen eller trekke den tilbake. Regelen er
  -- den samme som workflow.review_decisions bruker for reviewere, og den er
  -- CONTENT_GOVERNANCE.md §14 sitt «en agent skal ikke kunne gi seg selv ny
  -- rolle» håndhevet i basen framfor beskrevet i prosa. En agent som kunne
  -- registrere agenter, ville vært en rettighetseskalering med ett ekstra ledd.
  constraint agent_identities_registered_by_fkey
    foreign key (registered_by_actor_id, registered_by_actor_type)
    references provenance.actors (id, actor_type)
    on update restrict on delete restrict,
  constraint agent_identities_registered_by_human_check
    check (registered_by_actor_type = 'human'),

  constraint agent_identities_secret_issued_by_fkey
    foreign key (secret_issued_by_actor_id, secret_issued_by_actor_type)
    references provenance.actors (id, actor_type)
    on update restrict on delete restrict,
  constraint agent_identities_secret_issued_by_human_check
    check (secret_issued_by_actor_type is null
           or secret_issued_by_actor_type = 'human'),

  constraint agent_identities_revoked_by_fkey
    foreign key (revoked_by_actor_id, revoked_by_actor_type)
    references provenance.actors (id, actor_type)
    on update restrict on delete restrict,
  constraint agent_identities_revoked_by_human_check
    check (revoked_by_actor_type is null
           or revoked_by_actor_type = 'human'),

  -- Legitimasjonens fire felter hører sammen. Uten paringen kunne en identitet
  -- hatt en hash uten å vite hvem som utstedte den eller når — altså en
  -- rettighet uten den attribusjonen ANTIDEP_CONSTITUTION.md §14 krever.
  constraint agent_identities_secret_shape_check
    check ((secret_hash is null) = (secret_issued_at is null)
           and (secret_hash is null) = (secret_issued_by_actor_id is null)
           and (secret_hash is null) = (secret_version = 0)),
  constraint agent_identities_secret_issued_by_pair_check
    check ((secret_issued_by_actor_id is null) = (secret_issued_by_actor_type is null)),
  constraint agent_identities_secret_hash_format_check
    check (secret_hash is null or secret_hash ~ '^sha256-v[0-9]+:[0-9a-f]{64}$'),
  constraint agent_identities_secret_version_check
    check (secret_version >= 0),

  -- En tilbakekalling skal ikke kunne skje i stillhet, som ved en
  -- tilbaketrukket aktør eller en avsluttet rolletildeling.
  constraint agent_identities_revocation_shape_check
    check ((valid_to is null) = (revoked_by_actor_id is null)
           and (valid_to is null) = (revocation_reason is null)),
  constraint agent_identities_revoked_by_pair_check
    check ((revoked_by_actor_id is null) = (revoked_by_actor_type is null)),
  constraint agent_identities_validity_order_check
    check (valid_to is null or valid_to > valid_from),

  -- Samme nøkkelform som provenance.actors.actor_key: maskinlesbar,
  -- språkuavhengig og stabil.
  constraint agent_identities_identity_key_format_check
    check (identity_key ~ '^[a-z0-9]+(?:[-.][a-z0-9]+)*:[a-z0-9]+(?:[-.][a-z0-9]+)*$'),
  constraint agent_identities_registration_reason_check
    check (registration_reason = btrim(registration_reason)
           and length(registration_reason) between 1 and 2000),
  constraint agent_identities_revocation_reason_check
    check (revocation_reason is null
           or (revocation_reason = btrim(revocation_reason)
               and length(revocation_reason) between 1 and 2000))
);

comment on table provenance.agent_identities is
  'Den tekniske identiteten en KI-prosess handler med (DATABASE_ARCHITECTURE.md §49, MVP_IMPLEMENTATION_PLAN.md §16, §49). Én identitet per agentaktør, med aktørens rolle som rettighetsgrense og en egen legitimasjon som aldri lagres i klartekst. Erstatter det service_role ville vært brukt til, og gjør det motsatte: rettighetene følger rollen, så en identitet i ett pipelineledd kan ikke utføre operasjonene i et annet. Registrering, utstedelse av legitimasjon og tilbakekalling kan bare gjøres av en menneskelig aktør, deklarativt håndhevet (CONTENT_GOVERNANCE.md §14).';
comment on column provenance.agent_identities.actor_id is
  'Agentaktøren identiteten tilhører. Attribusjonen på kunnskapsobjektene peker på denne aktøren, ikke på identiteten: legitimasjonen kan roteres uten at historikken skifter opphav.';
comment on column provenance.agent_identities.agent_role is
  'Speil av aktørens agentrolle, låst av den sammensatte fremmednøkkelen. Finnes for at rollen skal kunne brukes som rettighetsgrense og låses til en kjøring uten et oppslag som kunne komme i utakt. Ikke en selvstendig sannhet.';
comment on column provenance.agent_identities.identity_key is
  'Stabil, språkuavhengig maskinnøkkel på formen «type:navn», som provenance.actors.actor_key. Dette er navnet en agentkjører oppgir ved autentisering, og det inngår i hashen av hemmeligheten.';
comment on column provenance.agent_identities.secret_hash is
  'sha256 av «identity_key:hemmelighet», med versjonert prefiks. NULL betyr at ingen legitimasjon er utstedt, og identiteten kan da ikke autentisere seg i det hele tatt. Klartekstverdien lagres aldri og finnes bare i det ene returnerte svaret fra provenance.issue_agent_identity_credential(text, text).';
comment on column provenance.agent_identities.secret_version is
  'Hvor mange ganger legitimasjonen er utstedt. 0 betyr at den aldri har vært utstedt. Tallet kan bare øke, slik at en rotasjon ikke kan se ut som om den ikke skjedde.';
comment on column provenance.agent_identities.valid_to is
  'Når identiteten ble trukket tilbake. NULL betyr løpende. En tilbakekalling er en statusendring og ikke en sletting: alle kjøringer og alle kunnskapsobjekter identiteten står bak, består.';
comment on column provenance.agent_identities.registration_reason is
  'Hvorfor denne maskinidentiteten finnes, konkret nok til å være etterprøvbar. Alltid utfylt, av samme grunn som grant_reason på en rolletildeling: en rettighet uten begrunnelse er en rettighet ingen har tatt stilling til.';

create index agent_identities_actor_id_idx on provenance.agent_identities (actor_id);
create index agent_identities_agent_role_idx on provenance.agent_identities (agent_role);

alter table provenance.agent_identities enable row level security;

create trigger agent_identities_set_row_timestamps
  before insert or update on provenance.agent_identities
  for each row execute function catalog.set_row_timestamps();

-- ----------------------------------------------------------------------------
-- 4. provenance.agent_runs — én agentoperasjon, med sine premisser
--
-- DATABASE_ARCHITECTURE.md §33 og EVIDENCE_PIPELINE.md §65: for hver vesentlig
-- KI-operasjon skal proveniensen kunne si hva som ble kjørt med hvilke
-- premisser — rolle, leverandør, modell, modellversjon, promptmalversjon,
-- pipelineversjon, input, output og tidspunkt. Full deterministisk
-- reproduserbarhet kan ikke garanteres for en språkmodell; rekonstruerbarhet
-- kan.
--
-- Alle fem versjonsfeltene er NOT NULL. En kjøring som kunne unnlate å oppgi
-- modellversjon eller pipelineversjon, ville vært nettopp den uversjonerte
-- KI-operasjonen ANTIDEP_CONSTITUTION.md §20 forbyr — og feltet ville stått tomt
-- akkurat i de kjøringene det betyr mest å kunne lese i ettertid. Feltene er fri
-- tekst med hensikt: leverandør, modell og pipeline er utskiftbare, og et
-- kontrollert vokabular her ville bundet kunnskapsmodellen til én leverandørs
-- identifikatorer (§20).
--
-- Kjøringen er ikke append-only i streng forstand: den åpnes som `running` og
-- lukkes én gang. Alt annet er uforanderlig, og overgangen kan bare gå én vei.
-- ----------------------------------------------------------------------------
create table provenance.agent_runs (
  id uuid primary key default gen_random_uuid(),

  agent_identity_id uuid not null,
  -- To speil, begge låst til identiteten av hver sin sammensatte fremmednøkkel.
  actor_id uuid not null,
  agent_role provenance.agent_role not null,

  provider text not null,
  model text not null,
  model_version text not null,
  prompt_template_version text not null,
  pipeline_version text not null,

  status provenance.agent_run_status not null default 'running',
  input_manifest jsonb not null,
  output_manifest jsonb,
  failure_reason text,

  started_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint agent_runs_identity_actor_fkey
    foreign key (agent_identity_id, actor_id)
    references provenance.agent_identities (id, actor_id)
    on update restrict on delete restrict,
  constraint agent_runs_identity_role_fkey
    foreign key (agent_identity_id, agent_role)
    references provenance.agent_identities (id, agent_role)
    on update restrict on delete restrict,

  -- Gjør kjøringen refererbar sammen med aktøren og rollen sin. Neste PR sin
  -- skrivevei kan da kreve deklarativt at en ekstraksjonsverifikasjon peker på
  -- en kjøring i rollen extraction_verification, utført av nøyaktig den aktøren
  -- raden attribueres til — framfor å kontrollere det i funksjonskode som en
  -- senere skrivevei kunne glemme (DATABASE_ARCHITECTURE.md §59).
  constraint agent_runs_id_actor_key unique (id, actor_id),
  constraint agent_runs_id_role_key unique (id, agent_role),

  -- Hva som skal være satt følger av statusen, og regelen er uttømmende over
  -- vokabularet. Uten else-grenen ville en ny statusverdi gitt NULL, og en NULL
  -- passerer en CHECK — regelen ville stilltiende sluttet å gjelde for nettopp
  -- den statusen som er ny. Samme mønster som events_snapshot_shape_check.
  constraint agent_runs_status_shape_check
    check (
      case status
        when 'running' then
          completed_at is null and output_manifest is null and failure_reason is null
        when 'succeeded' then
          completed_at is not null and output_manifest is not null and failure_reason is null
        when 'failed' then
          completed_at is not null and failure_reason is not null
        when 'aborted' then
          completed_at is not null and failure_reason is not null
        else false
      end
    ),

  -- En kjøring kan ikke ha startet i framtiden, og kan ikke ha blitt ferdig før
  -- den startet. created_at er databaseeid, så den første er en sammenligning
  -- mot uavhengig tid (DATABASE_ARCHITECTURE.md §7.3).
  constraint agent_runs_started_at_not_future_check
    check (started_at <= created_at),
  constraint agent_runs_completed_after_started_check
    check (completed_at is null or completed_at >= started_at),

  -- En kjøring uten inputmanifest ville vært en operasjon uten premisser: den
  -- kunne ikke rekonstrueres, og proveniensgrafen i §34 ville hatt et hull
  -- nøyaktig der KI-leddet står.
  constraint agent_runs_input_manifest_shape_check
    check (jsonb_typeof(input_manifest) = 'object' and input_manifest <> '{}'::jsonb),
  constraint agent_runs_output_manifest_shape_check
    check (output_manifest is null or jsonb_typeof(output_manifest) = 'object'),

  constraint agent_runs_provider_check
    check (provider = btrim(provider) and length(provider) between 1 and 200),
  constraint agent_runs_model_check
    check (model = btrim(model) and length(model) between 1 and 200),
  constraint agent_runs_model_version_check
    check (model_version = btrim(model_version) and length(model_version) between 1 and 200),
  constraint agent_runs_prompt_template_version_check
    check (prompt_template_version = btrim(prompt_template_version)
           and length(prompt_template_version) between 1 and 200),
  constraint agent_runs_pipeline_version_check
    check (pipeline_version = btrim(pipeline_version)
           and length(pipeline_version) between 1 and 200),
  constraint agent_runs_failure_reason_check
    check (failure_reason is null
           or (failure_reason = btrim(failure_reason)
               and length(failure_reason) between 1 and 4000))
);

comment on table provenance.agent_runs is
  'Én agentoperasjon med sine premisser (DATABASE_ARCHITECTURE.md §33, EVIDENCE_PIPELINE.md §65): hvilken identitet og rolle som kjørte, hvilken leverandør, modell, modellversjon, promptmalversjon og pipelineversjon den kjørte med, hva den fikk inn, hva den produserte og når. Gjør en KI-operasjon rekonstruerbar uten å kreve at språkmodellen er deterministisk. Kjøringen åpnes som running og lukkes én gang; alt annet er uforanderlig, og ingen kjøring kan slettes.';
comment on column provenance.agent_runs.actor_id is
  'Speil av identitetens aktør, låst av den sammensatte fremmednøkkelen. Finnes for at en senere skrivevei skal kunne kreve at objektet en kjøring produserte, er attribuert til nøyaktig den aktøren som kjørte. Ikke en selvstendig sannhet.';
comment on column provenance.agent_runs.agent_role is
  'Speil av identitetens rolle, låst av den sammensatte fremmednøkkelen. En kjøring kan ikke handle i en annen rolle enn identiteten har.';
comment on column provenance.agent_runs.model_version is
  'Modellversjonen eller den leverandørspesifikke modellidentifikatoren kjøringen faktisk brukte. Fri tekst med hensikt: leverandører skal ligge bak utskiftbare adaptere, og et kontrollert vokabular her ville bundet kunnskapsmodellen til én leverandør (ANTIDEP_CONSTITUTION.md §20).';
comment on column provenance.agent_runs.input_manifest is
  'Hva kjøringen fikk inn, som identifikatorer og premisser framfor som fritekst. Alltid et ikke-tomt objekt: en operasjon uten premisser kan ikke rekonstrueres.';
comment on column provenance.agent_runs.output_manifest is
  'Hva kjøringen produserte, som identifikatorer. Påkrevd for en kjøring som lyktes, forbudt for en som fortsatt er åpen. En kjøring som feilet eller ble stoppet kan ha delvis output, og da står den her ved siden av failure_reason.';
comment on column provenance.agent_runs.status is
  'Kjøringens tilstand. Bare running er åpen, og overgangen til en av de tre endelige tilstandene kan bare skje én gang og bare én vei.';

create index agent_runs_agent_identity_id_idx on provenance.agent_runs (agent_identity_id);
create index agent_runs_actor_id_started_at_idx on provenance.agent_runs (actor_id, started_at desc);
create index agent_runs_status_idx on provenance.agent_runs (status);

alter table provenance.agent_runs enable row level security;

create trigger agent_runs_set_row_timestamps
  before insert or update on provenance.agent_runs
  for each row execute function catalog.set_row_timestamps();

-- ----------------------------------------------------------------------------
-- 5. Immutable-row guards
--
-- Snevre vern, som DATABASE_ARCHITECTURE.md §60 navngir som god triggerbruk:
-- ingen klinisk logikk, ingen arbeidsflyt, bare hva som kan endres etterpå.
-- Vernene gjelder også eieren av tabellen; en reell vedlikeholdsoperasjon må slå
-- av triggeren eksplisitt, som en synlig og reviewbar handling.
-- ----------------------------------------------------------------------------
create function provenance.freeze_agent_identity()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Agentidentitet %L kan ikke slettes; den kan bare trekkes tilbake.', old.id
      ),
      hint = 'Sett valid_to, revoked_by_actor_id og revocation_reason. Kjøringene og kunnskapsobjektene identiteten står bak, skal beholde sitt opphav (ANTIDEP_CONSTITUTION.md §14).';
  end if;

  -- Identiteten selv er uforanderlig, av samme grunn som aktøridentiteten er
  -- det (provenance.freeze_actor_identity()): kunne aktør, rolle eller nøkkel
  -- endres i ettertid, ville hele attribusjonshistorikken stille fått et annet
  -- innhold, og en identitet kunne fått en rolle den aldri ble tildelt.
  if new.actor_id is distinct from old.actor_id
    or new.agent_role is distinct from old.agent_role
    or new.identity_key is distinct from old.identity_key
    or new.valid_from is distinct from old.valid_from
    or new.registered_by_actor_id is distinct from old.registered_by_actor_id
    or new.registered_by_actor_type is distinct from old.registered_by_actor_type
    or new.registration_reason is distinct from old.registration_reason
    or new.created_at is distinct from old.created_at
  then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Identiteten til agentidentitet %L er uforanderlig og kan ikke endres.', old.id
      ),
      hint = 'Trekk identiteten tilbake og registrer en ny for den nye rollen eller aktøren. Bare legitimasjonen og tilbakekallingen kan endres etter registrering.';
  end if;

  -- En tilbakekalling som kunne omgjøres, ville ikke vært en tilbakekalling
  -- (DATABASE_ARCHITECTURE.md §46). Samme regel som workflow.freeze_role_grant()
  -- har for en avsluttet rolletildeling.
  if old.valid_to is not null
    and (new.valid_to is distinct from old.valid_to
         or new.revoked_by_actor_id is distinct from old.revoked_by_actor_id
         or new.revoked_by_actor_type is distinct from old.revoked_by_actor_type
         or new.revocation_reason is distinct from old.revocation_reason
         or new.secret_hash is distinct from old.secret_hash
         or new.secret_version is distinct from old.secret_version)
  then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Agentidentitet %L er trukket tilbake og kan verken gjenåpnes eller få ny legitimasjon.', old.id
      ),
      hint = 'Registrer en ny agentidentitet dersom rollen skal kunne handle igjen. At identiteten var gyldig i sin opprinnelige periode, skal bevares.';
  end if;

  -- Én rettighetsendring om gangen. En UPDATE som både trakk tilbake identiteten
  -- og roterte legitimasjonen, ville vært to endringer med hver sin
  -- auditoperasjon, og auditskriveren kan bare registrere én per rad. Framfor å
  -- la den ene bli usynlig, er kombinasjonen umulig.
  if new.valid_to is distinct from old.valid_to
    and new.secret_hash is distinct from old.secret_hash
  then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Agentidentitet %L kan ikke trekkes tilbake og få ny legitimasjon i samme operasjon.', old.id
      ),
      hint = 'Gjør én endring om gangen, slik at hver rettighetsendring får sin egen auditrad.';
  end if;

  -- Legitimasjonens fire felter flytter seg sammen eller ikke i det hele tatt.
  --
  -- Å bare kontrollere versjonstallet når hashen endret seg, var ikke nok:
  -- auditskriveren registrerer en utstedelse på nettopp den endringen, så en
  -- UPDATE som beholdt hashen og likevel skrev om versjonstallet,
  -- utstedelsestidspunktet eller utstederen, ville omskrevet legitimasjonens
  -- historikk uten å legge igjen en eneste auditrad. At bare en privilegert
  -- vedlikeholdsoperasjon kan gjøre det, er ikke et forsvar: vernet gjelder også
  -- eieren av tabellen, og det er hele grunnen til at det finnes.
  if new.secret_hash is distinct from old.secret_hash then
    -- En rotasjon: versjonen må øke. Et versjonstall som kunne stå stille eller
    -- gå ned, ville gjort rotasjonen usynlig i raden.
    if new.secret_version <= old.secret_version then
      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'Ny legitimasjon for agentidentitet %L må øke secret_version.', old.id
        ),
        hint = 'Bruk provenance.issue_agent_identity_credential(text, text), som øker versjonstallet selv.';
    end if;
  elsif new.secret_version is distinct from old.secret_version
    or new.secret_issued_at is distinct from old.secret_issued_at
    or new.secret_issued_by_actor_id is distinct from old.secret_issued_by_actor_id
    or new.secret_issued_by_actor_type is distinct from old.secret_issued_by_actor_type
  then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Legitimasjonsmetadata for agentidentitet %L kan bare endres sammen med selve legitimasjonen.', old.id
      ),
      hint = 'Versjonstall, utstedelsestidspunkt og utsteder beskriver den legitimasjonen som faktisk ligger i raden. Utsted en ny med provenance.issue_agent_identity_credential(text, text); den skriver alle fire feltene i samme operasjon, og auditraden følger med.';
  end if;

  return new;
end;
$$;

comment on function provenance.freeze_agent_identity() is
  'Immutable-row guard for provenance.agent_identities: identiteten selv (aktør, rolle, nøkkel, registrering) kan ikke endres etter innsetting, en tilbakekalt identitet kan verken gjenåpnes eller få ny legitimasjon, legitimasjonen kan bare roteres framover, legitimasjonens fire felter flytter seg bare sammen — slik at ingen endring i dem kan skje uten den auditraden hashendringen utløser — tilbakekalling og rotasjon kan ikke skje i samme operasjon, og ingen identitet kan slettes. Legitimasjon og tilbakekalling er de eneste tilstandene som kan endres.';

revoke execute on function provenance.freeze_agent_identity() from public;

create trigger agent_identities_freeze
  before update or delete on provenance.agent_identities
  for each row execute function provenance.freeze_agent_identity();

-- ----------------------------------------------------------------------------
-- 5a. En tilbaketrukket aktør kan verken utføre handlinger eller få nye
--     rettigheter
--
-- Regelen har to ledd, og de gjelder hver sin ende av raden.
--
-- De tre menneskelige aktørreferansene — registratoren, utstederen av
-- legitimasjonen og den som trekker den tilbake — er alle påstander om at et
-- bestemt menneske gjorde noe. Den sammensatte fremmednøkkelen og CHECK-en
-- håndhever at det er et menneske; ingen av dem kan se om mennesket fortsatt er
-- i bruk.
--
-- Agentaktøren står i den andre enden: den *mottar* evnen til å handle. En
-- identitet opprettet for en tilbaketrukket agentaktør, eller en legitimasjon
-- rotert til en, ville gitt en rettighet til noe som er tatt ut av bruk — og
-- fordi en tilbaketrekking kan omgjøres, ville den nye legitimasjonen blitt
-- gyldig i det `retired_at` nulles, uten at noen hadde utstedt noe etter
-- reaktiveringen. Agentaktøren kontrolleres derfor ved registrering og ved
-- rotasjon.
--
-- Ikke ved tilbakekalling: å trekke tilbake en identitet hvis aktør allerede er
-- tatt ut av bruk, er nettopp den ryddingen modellen skal tillate. En regel som
-- blokkerte det, ville gjort rekkefølgen mellom to opprydninger til en felle.
--
-- Resten av modellen avviser en tilbaketrukket aktør konsekvent:
-- knowledge.assert_editor_authorized(uuid) nekter en tilbaketrukket editor å
-- opprette noe, og provenance.authenticate_agent_identity(...) nekter en
-- identitet hvis agentaktør er trukket tilbake. Uten denne regelen ville et
-- tilbaketrukket menneske likevel kunne stå oppført som den som ga en maskin
-- evnen til å handle — og auditraden ville påstått at vedkommende gjorde det.
--
-- Regelen ligger på tabellen og ikke bare i utstedelsesfunksjonen, av samme
-- grunn som resten av basen legger fasiten i constraintene: registreringen og
-- tilbakekallingen skrives i dag med rene INSERT/UPDATE, og en regel som bare
-- fantes i én funksjon, ville ikke gjeldt dem.
--
-- Bare referanser denne skrivingen faktisk *attribuerer en handling til*,
-- kontrolleres. En aktør som trekkes tilbake i ettertid skal ikke gjøre det
-- umulig å trekke tilbake en identitet vedkommende registrerte i sin tid:
-- tilbaketrekking er en statusendring framover, ikke en underkjenning av det som
-- allerede er gjort (ANTIDEP_CONSTITUTION.md §14).
--
-- Hva som teller som «attribuerer en handling», avgjøres av tilstandsendringen
-- og ikke av om aktørkolonnen flyttet seg. En rotasjon utført av samme menneske
-- som sist, endrer hash, versjon og tidspunkt, men lar utsteder-ID-en stå: den
-- skrivingen påstår likevel at vedkommende utstedte en ny legitimasjon nå, og
-- auditraden sier det. En regel som bare så på om ID-en endret seg, ville derfor
-- sluppet gjennom en rotasjon i navnet til en aktør som var trukket tilbake i
-- mellomtiden. Samme resonnement gjelder tilbakekallingen og `valid_to`.
--
-- Aktørradene låses med `for share` før de leses. Uten låsen finnes et vindu
-- mellom kontrollen og skrivingen: utstedelsesfunksjonen kunne lese aktøren som
-- aktiv, en parallell transaksjon kunne trekke den tilbake, og triggeren ville
-- ikke sett det. Med låsen må de to transaksjonene stille seg i kø — kommer
-- tilbaketrekkingen først, ser triggeren den og avviser; kommer den etterpå,
-- var aktøren faktisk aktiv da handlingen ble utført.
-- ----------------------------------------------------------------------------
create function provenance.assert_agent_identity_actors_active()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_written uuid[];
  v_retired_actor_key text;
begin
  if tg_op = 'INSERT' then
    v_written := array[
      -- Registreringen gir agentaktøren en identitet.
      new.actor_id,
      new.registered_by_actor_id,
      new.secret_issued_by_actor_id,
      new.revoked_by_actor_id
    ];
  else
    v_written := array[
      -- En rotasjon gir agentaktøren en ny gyldig legitimasjon. En
      -- tilbakekalling gir den ingenting, og skal alltid være mulig.
      case when new.secret_hash is distinct from old.secret_hash
           then new.actor_id end,
      case when new.registered_by_actor_id is distinct from old.registered_by_actor_id
           then new.registered_by_actor_id end,
      -- Utstedelsen er handlingen, ikke bytte av utsteder: en rotasjon med samme
      -- menneske som sist attribuerer likevel en ny legitimasjon til det
      -- mennesket.
      case when new.secret_hash is distinct from old.secret_hash
             or new.secret_issued_by_actor_id is distinct from old.secret_issued_by_actor_id
           then new.secret_issued_by_actor_id end,
      case when new.valid_to is distinct from old.valid_to
             or new.revoked_by_actor_id is distinct from old.revoked_by_actor_id
           then new.revoked_by_actor_id end
    ];
  end if;

  -- Låsen først, lesningen etterpå: predikatet under returnerer bare de
  -- tilbaketrukne radene, så en lås festet der ville ikke holdt igjen en
  -- samtidig tilbaketrekking av en aktør som ennå er aktiv.
  perform 1
  from provenance.actors a
  where a.id = any (v_written)
  for share;

  select a.actor_key into v_retired_actor_key
  from provenance.actors a
  where a.id = any (v_written)
    and a.retired_at is not null
  limit 1;

  if v_retired_actor_key is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Aktøren %L er trukket tilbake og kan verken utføre handlinger eller få nye rettigheter.',
        v_retired_actor_key
      ),
      hint = 'En tilbaketrukket aktør beholder sin historikk, men er ute av bruk. Registrering, utstedelse av legitimasjon og tilbakekalling skal attribueres til et menneske som er i bruk, og en agentidentitet kan verken opprettes for eller roteres til en agentaktør som er trukket tilbake. Å trekke tilbake en identitet er alltid mulig.';
  end if;

  return new;
end;
$$;

comment on function provenance.assert_agent_identity_actors_active() is
  'Krever at ingen tilbaketrukket aktør verken utfører en handling eller får en ny rettighet gjennom en skriving mot provenance.agent_identities. Det gjelder de tre menneskene som registrerer, utsteder legitimasjon og trekker tilbake, og det gjelder agentaktøren selv ved registrering og ved rotasjon — en legitimasjon utstedt til en tilbaketrukket agentaktør ville blitt gyldig i det aktøren tas i bruk igjen, uten en ny utstedelse. Tilbakekalling er unntatt: å rydde opp i en identitet hvis aktør allerede er ute av bruk, skal alltid være mulig. Hva som teller som en handling, avgjøres av tilstandsendringen og ikke av om aktørkolonnen flyttet seg: en rotasjon med samme utsteder som sist kontrolleres på nytt. Referanser skrivingen ikke rører, kontrolleres ikke, slik at en aktør som trekkes tilbake i ettertid ikke låser raden. Aktørradene låses med for share, slik at en samtidig tilbaketrekking ikke kan gli inn mellom kontrollen og skrivingen. Ligger på tabellen og ikke bare i utstedelsesfunksjonen, fordi registrering og tilbakekalling skrives med rene INSERT/UPDATE.';

revoke execute on function provenance.assert_agent_identity_actors_active() from public;

create trigger agent_identities_assert_actors_active
  before insert or update on provenance.agent_identities
  for each row execute function provenance.assert_agent_identity_actors_active();

-- ----------------------------------------------------------------------------
-- 5b. En identitet begynner alltid inert
--
-- De tre auditoperasjonene (008c) hviler på at registrering, utstedelse av
-- legitimasjon og tilbakekalling er tre *separate* skrivinger. Auditskriveren
-- registrerer en INSERT som nøyaktig én hendelse — `agent_identity_registered` —
-- og kan ikke registrere to.
--
-- Uten dette vernet kunne én privilegert INSERT satt `secret_hash` og `valid_to`
-- med det samme: identiteten ville vært i stand til å autentisere seg fra første
-- øyeblikk, eventuelt allerede tilbakekalt, og auditloggen ville bare vist at
-- den ble registrert. De to andre rettighetsendringene ville skjedd uten spor.
-- CHECK-ene i tabellen fanger det ikke: de kontrollerer at feltene er innbyrdes
-- konsistente, ikke at de er tomme ved registrering. Og freeze_agent_identity()
-- gjelder bare UPDATE og DELETE.
--
-- Starttilstanden er derfor den migrasjon 005f faktisk skriver, og den er nå en
-- regel framfor en beskrivelse: ingen legitimasjon, ingen tilbakekalling. Begge
-- deler kommer etterpå, hver med sin egen skriving og sin egen auditrad.
-- ----------------------------------------------------------------------------
create function provenance.assert_agent_identity_starts_inert()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.secret_hash is not null
    or new.secret_version <> 0
    or new.secret_issued_at is not null
    or new.secret_issued_by_actor_id is not null
  then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Agentidentiteten %L kan ikke registreres med legitimasjon allerede utstedt.',
        new.identity_key
      ),
      hint = 'Registrer identiteten uten legitimasjon, og utsted den etterpå med provenance.issue_agent_identity_credential(text, text). Å opprette og å gi evnen til å handle er to rettighetsendringer, og de skal ha hver sin auditrad.';
  end if;

  if new.valid_to is not null
    or new.revoked_by_actor_id is not null
    or new.revocation_reason is not null
  then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Agentidentiteten %L kan ikke registreres som allerede tilbakekalt.',
        new.identity_key
      ),
      hint = 'En tilbakekalling er en egen handling med sin egen auditrad. Registrer identiteten, og trekk den eventuelt tilbake etterpå — eller la være å registrere den.';
  end if;

  return new;
end;
$$;

comment on function provenance.assert_agent_identity_starts_inert() is
  'Krever at en agentidentitet registreres i den inerte tilstanden migrasjon 005f faktisk skriver: ingen utstedt legitimasjon og ingen tilbakekalling. Finnes fordi auditskriveren registrerer en INSERT som nøyaktig én hendelse: uten vernet kunne én skriving både registrere, utstede legitimasjon og tilbakekalle, mens loggen bare viste registreringen. Utstedelse og tilbakekalling er egne skrivinger med hver sin auditrad.';

revoke execute on function provenance.assert_agent_identity_starts_inert() from public;

create trigger agent_identities_assert_starts_inert
  before insert on provenance.agent_identities
  for each row execute function provenance.assert_agent_identity_starts_inert();

create function provenance.freeze_agent_run()
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

comment on function provenance.freeze_agent_run() is
  'Immutable-row guard for provenance.agent_runs: premissene (identitet, aktør, rolle, leverandør, modell, versjoner, inputmanifest, starttidspunkt) er uforanderlige, en kjøring kan bare endres ved å avsluttes, en avsluttet kjøring er endelig, og ingen kjøring kan slettes.';

revoke execute on function provenance.freeze_agent_run() from public;

create trigger agent_runs_freeze
  before update or delete on provenance.agent_runs
  for each row execute function provenance.freeze_agent_run();

-- ----------------------------------------------------------------------------
-- 6. audit.events utvides til å kunne peke på provenance.agent_identities
--
-- Samme ombygging som migrasjon 007c og 007e måtte gjøre, og av samme grunn:
-- object_schema og object_table er GENERATED ALWAYS ... STORED over et
-- CASE-uttrykk på operation, og PostgreSQL har ingen ALTER COLUMN som endrer
-- uttrykket til en generert kolonne. Den eneste veien er å fjerne og opprette
-- den på nytt, med indeksen som bruker begge kolonnene tatt ned og opp igjen
-- rundt det. events_snapshot_shape_check bygges om av samme grunn: en CHECK kan
-- bare endres ved DROP/ADD CONSTRAINT.
--
-- Begge operasjonene er trygge på levende rader: CASE-uttrykkene dekker alle
-- eksisterende verdier uendret, så de eksisterende radene regnes ut til det
-- samme de hadde.
-- ----------------------------------------------------------------------------
drop index audit.events_object_occurred_at_idx;

alter table audit.events drop column object_schema;
alter table audit.events drop column object_table;

alter table audit.events add column object_schema text not null generated always as (
  case operation
    when 'claim_published' then 'knowledge'
    when 'claim_publication_replaced' then 'knowledge'
    when 'claim_publication_withdrawn' then 'knowledge'
    when 'claim_publication_rolled_back' then 'knowledge'
    when 'role_granted' then 'workflow'
    when 'role_ended' then 'workflow'
    when 'source_created' then 'knowledge'
    when 'evidence_item_created' then 'knowledge'
    when 'agent_identity_registered' then 'provenance'
    when 'agent_identity_credential_issued' then 'provenance'
    when 'agent_identity_revoked' then 'provenance'
  end
) stored;

alter table audit.events add column object_table text not null generated always as (
  case operation
    when 'claim_published' then 'claims'
    when 'claim_publication_replaced' then 'claims'
    when 'claim_publication_withdrawn' then 'claims'
    when 'claim_publication_rolled_back' then 'claims'
    when 'role_granted' then 'user_roles'
    when 'role_ended' then 'user_roles'
    when 'source_created' then 'sources'
    when 'evidence_item_created' then 'evidence_items'
    when 'agent_identity_registered' then 'agent_identities'
    when 'agent_identity_credential_issued' then 'agent_identities'
    when 'agent_identity_revoked' then 'agent_identities'
  end
) stored;

comment on column audit.events.object_schema is
  'Schemaet objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen, ikke oppgitt ved siden av den, slik at de to ikke kan komme i utakt. NOT NULL på en generert kolonne gjør at en ny enum-verdi uten tilhørende gren feiler ved innsetting framfor å gi en tom kolonne.';
comment on column audit.events.object_table is
  'Tabellen objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen, med samme begrunnelse som object_schema.';

create index events_object_occurred_at_idx
  on audit.events (object_schema, object_table, object_id, occurred_at desc);

alter table audit.events drop constraint events_snapshot_shape_check;
alter table audit.events add constraint events_snapshot_shape_check
  check (
    case operation
      when 'claim_published' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_replaced' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_withdrawn' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_rolled_back' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'role_granted' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'role_ended' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'source_created' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'evidence_item_created' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      -- En opprettelse, som source_created og role_granted.
      when 'agent_identity_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      -- De to andre er endringer på en rad som fantes, som role_ended: begge
      -- sidene skal kunne leses, slik at det er synlig hva som faktisk endret
      -- seg da maskinen fikk eller mistet evnen til å handle.
      when 'agent_identity_credential_issued' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'agent_identity_revoked' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      else false
    end
  );

-- ----------------------------------------------------------------------------
-- 7. audit.record_agent_identity_event() — produsenten for de tre operasjonene
--
-- Samme mønster som audit.record_user_role_event() og
-- audit.record_evidence_item_event(): ikke SECURITY DEFINER, slik at
-- auditskriveren aldri er mer privilegert enn operasjonen den registrerer
-- (§35, §60).
--
-- Snapshotene fjerner secret_hash. En auditlogg skal kunne leses av en revisor,
-- og en hash av en levende legitimasjon hører ikke hjemme i et bredere lesbart
-- objekt enn raden den ligger på. Ingenting går tapt: secret_version står i
-- snapshotet og sier at legitimasjonen ble byttet, uten å bære materialet.
--
-- Bare tilstandsendringer registreres. En UPDATE som verken utsteder
-- legitimasjon eller trekker tilbake, gir ingen auditrad — den kan uansett bare
-- treffe felter freeze-triggeren allerede har godtatt.
-- ----------------------------------------------------------------------------
create function audit.record_agent_identity_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_operation audit.event_operation;
  v_actor_id uuid;
begin
  if tg_op = 'INSERT' then
    v_operation := 'agent_identity_registered';
    v_actor_id := new.registered_by_actor_id;
  elsif new.valid_to is not null and old.valid_to is null then
    v_operation := 'agent_identity_revoked';
    v_actor_id := new.revoked_by_actor_id;
  elsif new.secret_hash is distinct from old.secret_hash then
    v_operation := 'agent_identity_credential_issued';
    v_actor_id := new.secret_issued_by_actor_id;
  else
    return null;
  end if;

  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot,
    occurred_at
  )
  values (
    v_operation,
    new.id,
    v_actor_id,
    case when tg_op = 'INSERT' then null else to_jsonb(old) - 'secret_hash' end,
    to_jsonb(new) - 'secret_hash',
    now()
  );

  return null;
end;
$$;

comment on function audit.record_agent_identity_event() is
  'Auditskriver for agentidentiteter: registrerer at en maskinidentitet ble opprettet, fikk utstedt legitimasjon eller ble trukket tilbake — de tre punktene der en maskins rett til å handle i Antidep endrer seg. Aktøren på auditraden er mennesket som utførte handlingen. Snapshotene utelater secret_hash: versjonstallet viser at legitimasjonen ble byttet uten at materialet spres. Kjører med kallerens rettigheter, ikke som SECURITY DEFINER, slik at en auditrad aldri kan skrives av noen som ikke kunne utført operasjonen selv.';

revoke execute on function audit.record_agent_identity_event() from public;

create trigger agent_identities_record_audit_event
  after insert or update on provenance.agent_identities
  for each row execute function audit.record_agent_identity_event();

-- ----------------------------------------------------------------------------
-- 8. Legitimasjonen: hashing, utstedelse og autentisering
--
-- Hashen bindes til identitetsnøkkelen, ikke bare til hemmeligheten. Se
-- hodekommentaren for hvorfor, og for hvorfor sammenligningen ikke er en
-- konstanttidsrutine.
-- ----------------------------------------------------------------------------
create function provenance.agent_secret_hash(p_identity_key text, p_secret text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case
    when p_identity_key is null or p_secret is null then null
    else 'sha256-v1:' || encode(
      sha256(convert_to(p_identity_key || ':' || p_secret, 'UTF8')),
      'hex'
    )
  end;
$$;

comment on function provenance.agent_secret_hash(text, text) is
  'Hashen av en agentlegitimasjon: sha256 av «identity_key:hemmelighet», med versjonert prefiks som content_hash (migrasjon 003, 006a). Bindingen til identitetsnøkkelen gjør at en lekket hash ikke kan spilles av mot en annen identitet. Ren funksjon uten tabelltilgang; klarteksthemmeligheten lagres aldri.';

revoke execute on function provenance.agent_secret_hash(text, text) from public;

-- Ett sted for avvisningen, slik at ingen av grenene kan skille seg fra de
-- andre. En feilmelding som sa «ukjent identitet» framfor «feil hemmelighet»,
-- ville gjort funksjonen til et oppslagsverk over hvilke identiteter som finnes.
create function provenance.reject_agent_authentication()
  returns void
  language plpgsql
  set search_path = ''
as $$
begin
  raise exception using
    errcode = 'insufficient_privilege',
    message = 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
    hint = 'Kontroller identitetsnøkkelen, legitimasjonen og at identiteten har den rollen operasjonen krever. En identitet som er trukket tilbake, ikke har fått utstedt legitimasjon, eller hvis aktør er trukket tilbake, kan ikke utføre noen operasjon.';
end;
$$;

comment on function provenance.reject_agent_authentication() is
  'Den ene avvisningen alle mislykkede agentautentiseringer går gjennom. Finnes for at ingen gren skal kunne skille seg fra de andre: ukjent identitet, feil legitimasjon, feil rolle, tilbakekalt identitet og tilbaketrukket aktør gir nøyaktig samme svar, slik at flaten ikke kan brukes til å telle opp hvilke identiteter som finnes.';

revoke execute on function provenance.reject_agent_authentication() from public;

-- Utstedelse. Hemmeligheten genereres i basen og returneres én gang; det finnes
-- ingen vei til å lese den ut igjen etterpå. Funksjonen får ingen grants til
-- klientrollene: den er en forvaltningsoperasjon, og den kalles av en migrasjon
-- eller av en operatør fram til en admin-flate finnes.
create function provenance.issue_agent_identity_credential(
  p_identity_key text,
  p_issued_by_actor_key text
)
  returns text
  language plpgsql
  set search_path = ''
as $$
declare
  v_identity_id uuid;
  v_valid_to timestamptz;
  v_actor_retired_at timestamptz;
  v_issuer_id uuid;
  v_issuer_type provenance.actor_type;
  v_issuer_retired_at timestamptz;
  v_secret text;
begin
  select ai.id, ai.valid_to, a.retired_at
  into v_identity_id, v_valid_to, v_actor_retired_at
  from provenance.agent_identities ai
  join provenance.actors a on a.id = ai.actor_id
  where ai.identity_key = p_identity_key;

  if v_identity_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Agentidentiteten %L finnes ikke.', p_identity_key),
      hint = 'Registrer identiteten før legitimasjonen utstedes.';
  end if;

  if v_valid_to is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Agentidentiteten %L er trukket tilbake.', p_identity_key),
      hint = 'En tilbakekalt identitet kan ikke få ny legitimasjon. Registrer en ny identitet for rollen.';
  end if;

  if v_actor_retired_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Aktøren bak agentidentiteten %L er trukket tilbake.', p_identity_key),
      hint = 'En tilbaketrukket aktør beholder sin historikk, men kan ikke utføre nye handlinger.';
  end if;

  select a.id, a.actor_type, a.retired_at
  into v_issuer_id, v_issuer_type, v_issuer_retired_at
  from provenance.actors a
  where a.actor_key = p_issued_by_actor_key;

  -- Kontrollene er her i tillegg til den sammensatte fremmednøkkelen, CHECK-en
  -- og triggeren i avsnitt 5a, slik at en feil aktørnøkkel gir en setning som
  -- sier hva som er galt framfor en fremmednøkkelfeil. Reglene selv er
  -- tabellens, ikke funksjonens.
  if v_issuer_id is null or v_issuer_type <> 'human' then
    raise exception using
      errcode = 'restrict_violation',
      message = format('%L er ikke en registrert menneskelig aktør.', p_issued_by_actor_key),
      hint = 'Bare et menneske kan gi en maskin evnen til å handle i Antidep (CONTENT_GOVERNANCE.md §14).';
  end if;

  if v_issuer_retired_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Aktøren %L er trukket tilbake og kan ikke utstede legitimasjon.', p_issued_by_actor_key),
      hint = 'En tilbaketrukket aktør beholder sin historikk, men kan ikke utføre nye handlinger. Auditraden ville ellers påstått at vedkommende ga en maskin evnen til å handle.';
  end if;

  -- 244 bits fra pg_strong_random gjennom gen_random_uuid(), foldet til 256
  -- bits hex. Ingen extension innføres for dette; se hodekommentaren.
  v_secret := encode(
    sha256(convert_to(
      gen_random_uuid()::text || ':' || gen_random_uuid()::text,
      'UTF8'
    )),
    'hex'
  );

  update provenance.agent_identities
  set secret_hash = provenance.agent_secret_hash(p_identity_key, v_secret),
      secret_version = secret_version + 1,
      secret_issued_at = now(),
      secret_issued_by_actor_id = v_issuer_id,
      secret_issued_by_actor_type = v_issuer_type
  where id = v_identity_id;

  return v_secret;
end;
$$;

comment on function provenance.issue_agent_identity_credential(text, text) is
  'Utsteder eller roterer legitimasjonen til en agentidentitet og returnerer klartekstverdien én gang. Verdien lagres aldri: bare hashen ligger i raden, og det finnes ingen vei til å lese hemmeligheten ut igjen — en tapt hemmelighet erstattes ved å utstede en ny, som samtidig ugyldiggjør den gamle. Utstederen må være en registrert menneskelig aktør som ikke er trukket tilbake (CONTENT_GOVERNANCE.md §14). En tilbakekalt identitet eller en tilbaketrukket aktør får ingen legitimasjon. Auditraden skrives av triggeren på tabellen, i samme transaksjon. Ingen klientrolle har EXECUTE: dette er en forvaltningsoperasjon, ikke en Data API-operasjon.';

revoke execute on function provenance.issue_agent_identity_credential(text, text) from public;

-- Autentisering. SECURITY INVOKER, som knowledge.assert_editor_authorized(uuid):
-- den kalles alltid fra innsiden av en SECURITY DEFINER-funksjon og arver den
-- konteksten derfra. Tomt search_path og schemakvalifiserte navn likevel (§50).
create function provenance.authenticate_agent_identity(
  p_identity_key text,
  p_secret text,
  p_required_role provenance.agent_role
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_identity_id uuid;
begin
  if p_identity_key is null or p_secret is null or p_required_role is null then
    perform provenance.reject_agent_authentication();
  end if;

  -- Alle betingelsene i ett predikat, med ett svar. Å stille dem hver for seg
  -- ville gjort rekkefølgen til et implisitt valg og gitt hver gren sin egen
  -- observerbare oppførsel.
  --
  -- Gyldighet måles med statement_timestamp() og ikke med now(): dette er et
  -- predikat som avgjør noe (MVP_IMPLEMENTATION_PLAN.md §74.6).
  select ai.id into v_identity_id
  from provenance.agent_identities ai
  join provenance.actors a on a.id = ai.actor_id
  where ai.identity_key = p_identity_key
    and ai.secret_hash is not null
    and ai.secret_hash = provenance.agent_secret_hash(p_identity_key, p_secret)
    and ai.agent_role = p_required_role
    and ai.valid_from <= statement_timestamp()
    and (ai.valid_to is null or ai.valid_to > statement_timestamp())
    and a.retired_at is null;

  if v_identity_id is null then
    perform provenance.reject_agent_authentication();
  end if;

  return v_identity_id;
end;
$$;

comment on function provenance.authenticate_agent_identity(text, text, provenance.agent_role) is
  'Autentiserer en agentidentitet for én bestemt rolle og returnerer identitetens id. Rollen er ikke en opplysning kalleren får vite, men et krav operasjonen stiller: en identitet i ekstraksjonsrollen kan ikke autentisere seg for en verifikasjonsoperasjon, og omvendt. Det er det første av de tre lagene som gjør at en agent ikke kan verifisere sitt eget arbeid (se migrasjonens hodekommentar). Kontrollerer i ett predikat at identiteten finnes, har utstedt legitimasjon som stemmer, har den påkrevde rollen, er gyldig nå og har en aktør som ikke er trukket tilbake. Alle avvisninger er identiske (provenance.reject_agent_authentication()).';

revoke execute on function provenance.authenticate_agent_identity(text, text, provenance.agent_role) from public;

-- ----------------------------------------------------------------------------
-- 9. provenance.assert_agent_run_open() — bindingen mellom en operasjon og en
--    kjøring
--
-- Skriveveiene som kommer, skal skrive *inne i* en åpen kjøring, slik at
-- objektet de produserer kan spores til premissene det ble produsert under
-- (DATABASE_ARCHITECTURE.md §34). Kontrollen ligger her framfor i hver skrivevei,
-- slik at neste ledd i pipelinen arver den framfor å skrive den om igjen.
-- ----------------------------------------------------------------------------
create function provenance.assert_agent_run_open(
  p_agent_run_id uuid,
  p_agent_identity_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_actor_id uuid;
begin
  select ar.actor_id into v_actor_id
  from provenance.agent_runs ar
  where ar.id = p_agent_run_id
    and ar.agent_identity_id = p_agent_identity_id
    and ar.status = 'running';

  if v_actor_id is null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Det finnes ingen åpen agentkjøring med denne identiteten.',
      hint = 'En agentoperasjon skal skje inne i en kjøring som er åpnet med api.begin_agent_run(...) av samme identitet, og som ikke er avsluttet. En avsluttet kjøring kan ikke gjenåpnes.';
  end if;

  return v_actor_id;
end;
$$;

comment on function provenance.assert_agent_run_open(uuid, uuid) is
  'Kontrollerer at kjøringen finnes, tilhører den autentiserte identiteten og fortsatt er åpen, og returnerer aktøren kjøringen skal attribueres til. Den gjenbrukbare bindingen mellom en agentoperasjon og premissene den kjøres under; skriveveiene i senere pipelineledd kaller den framfor å skrive kontrollen om igjen.';

revoke execute on function provenance.assert_agent_run_open(uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 10. api.begin_agent_run(...) og api.complete_agent_run(...)
--
-- De to inngangspunktene en agentkjører faktisk kaller. SECURITY DEFINER, tomt
-- search_path, schemakvalifiserte navn, EXECUTE revokert fra PUBLIC — samme
-- form som api.create_source(...) og api.create_evidence_item(...).
--
-- Parametrene som bærer et vokabular er `text` og castes inne i kroppen, av
-- nøyaktig samme grunn som i migrasjon 007c: PostgREST bygger selv en
-- schemakvalifisert cast til parameterens deklarerte type, og den casten
-- evalueres i kallerens egen sesjon — før funksjonen starter. En klientrolle har
-- ingen USAGE på provenance, så en enum-typet parameter ville feilet med
-- «permission denied for schema provenance» uansett at funksjonen er SECURITY
-- DEFINER.
--
-- ----------------------------------------------------------------------------
-- Hvorfor EXECUTE går til anon, og hva som faktisk bærer sikkerheten
--
-- En agent har ingen brukerkonto (MVP_IMPLEMENTATION_PLAN.md §16), og en kaller
-- uten brukersesjon er `anon` i Data API-et. Skal en agentkjører nå flaten i det
-- hele tatt, må EXECUTE gå til anon; alternativet ville vært service_role, som
-- DATABASE_ARCHITECTURE.md §49 avviser, eller en menneskelig konto brukt av en
-- maskin, som §16 avviser.
--
-- Det er derfor legitimasjonen og ikke Data API-rollen som er kontrollen:
--
--   * Funksjonene leser og skriver ingenting før autentiseringen har lyktes.
--   * Alle avvisninger er identiske, så flaten kan ikke brukes til å telle opp
--     hvilke identiteter som finnes.
--   * Rollen er en del av autentiseringen, ikke en parameter kalleren kan velge
--     fritt: en identitet slipper bare gjennom for sin egen rolle.
--   * En vellykket autentisering gir ingenting annet enn retten til å åpne og
--     lukke en kjøring. Kjøringen alene rører ikke ett kunnskapsobjekt.
--
-- Restrisikoen som står igjen, er at flaten ikke har rate limiting i basen. Den
-- er ført som teknisk gjeld framfor å bli løst med en halv mekanisme her: å
-- logge mislykkede forsøk ville gitt en uautentisert skrivevei, altså byttet en
-- teoretisk risiko mot en reell.
-- ----------------------------------------------------------------------------
create function api.begin_agent_run(
  p_identity_key text,
  p_secret text,
  p_agent_role text,
  p_provider text,
  p_model text,
  p_model_version text,
  p_prompt_template_version text,
  p_pipeline_version text,
  p_input_manifest jsonb
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
begin
  -- Casten skjer først og for seg selv, slik at en ukjent rolle gir en setning
  -- som sier hva som er galt. Vokabularet er offentlig dokumentert
  -- (ANTIDEP_CONSTITUTION.md §10, EVIDENCE_PIPELINE.md §61), så meldingen røper
  -- ingenting autentiseringen skjuler.
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

  select ai.actor_id into v_actor_id
  from provenance.agent_identities ai
  where ai.id = v_identity_id;

  insert into provenance.agent_runs (
    agent_identity_id, actor_id, agent_role,
    provider, model, model_version, prompt_template_version, pipeline_version,
    status, input_manifest
  )
  values (
    v_identity_id, v_actor_id, v_role,
    p_provider, p_model, p_model_version, p_prompt_template_version, p_pipeline_version,
    'running', p_input_manifest
  )
  returning id into v_run_id;

  return v_run_id;
end;
$$;

comment on function api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb) is
  'Åpner en agentkjøring: autentiserer identiteten for den rollen kjøringen skal handle i, og registrerer premissene operasjonen kjøres under — leverandør, modell, modellversjon, promptmalversjon, pipelineversjon og inputmanifest (DATABASE_ARCHITECTURE.md §33, EVIDENCE_PIPELINE.md §65). Returnerer kjøringens id, som senere skrivende agentoperasjoner skriver inne i. Kjøringen alene rører ingen kunnskapsobjekter. SECURITY DEFINER med tomt search_path fordi provenance har RLS med default deny; kalleren autentiseres på funksjonens eget kall (§50). p_agent_role er text og castes i kroppen, av samme grunn som i migrasjon 007c. EXECUTE går til anon fordi en agent ikke har brukerkonto (§16) — legitimasjonen og ikke Data API-rollen er kontrollen; se migrasjonens hodekommentar.';

revoke execute on function api.begin_agent_run(
  text, text, text, text, text, text, text, text, jsonb
) from public;
grant execute on function api.begin_agent_run(
  text, text, text, text, text, text, text, text, jsonb
) to anon, authenticated;

create function api.complete_agent_run(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_status text,
  p_output_manifest jsonb default null,
  p_failure_reason text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_status provenance.agent_run_status;
  v_role provenance.agent_role;
  v_identity_id uuid;
begin
  begin
    v_status := p_status::provenance.agent_run_status;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent status for en agentkjøring.', p_status),
        hint = 'En kjøring avsluttes med succeeded, failed eller aborted.';
  end;

  if v_status = 'running' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En agentkjøring kan ikke avsluttes med statusen running.',
      hint = 'En kjøring avsluttes med succeeded, failed eller aborted.';
  end if;

  -- Rollen hentes fra kjøringen framfor å oppgis av kalleren: kravet
  -- autentiseringen stiller, skal komme fra objektet og ikke fra den som vil
  -- endre det. En ukjent kjøring gir samme avvisning som en mislykket
  -- autentisering, slik at flaten ikke kan brukes til å lete etter kjøringer.
  select ar.agent_role into v_role
  from provenance.agent_runs ar
  where ar.id = p_agent_run_id;

  if v_role is null then
    perform provenance.reject_agent_authentication();
  end if;

  v_identity_id := provenance.authenticate_agent_identity(p_identity_key, p_secret, v_role);
  perform provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  update provenance.agent_runs
  set status = v_status,
      completed_at = now(),
      output_manifest = p_output_manifest,
      failure_reason = p_failure_reason
  where id = p_agent_run_id;

  return p_agent_run_id;
end;
$$;

comment on function api.complete_agent_run(text, text, uuid, text, jsonb, text) is
  'Avslutter en agentkjøring med et endelig utfall og et outputmanifest, eller med en begrunnelse for at den feilet eller ble stoppet. Rollen autentiseringen krever, hentes fra kjøringen selv og oppgis ikke av kalleren. Overgangen kan bare skje én gang og bare fra running; provenance.freeze_agent_run() håndhever det, og en avsluttet kjøring kan verken gjenåpnes eller omskrives. Hvilke felter som må være satt for hvilken status, håndheves av agent_runs_status_shape_check, og avvisningen derfra propageres uendret. Samme SECURITY DEFINER-form og samme grants som api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb).';

revoke execute on function api.complete_agent_run(
  text, text, uuid, text, jsonb, text
) from public;
grant execute on function api.complete_agent_run(
  text, text, uuid, text, jsonb, text
) to anon, authenticated;
