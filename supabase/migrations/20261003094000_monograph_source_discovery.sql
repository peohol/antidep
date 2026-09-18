-- ============================================================================
-- Migrasjon 013e — søkeplanen, den dokumenterte søkeloggen og den separate
--                  kontrollen av søkedekningen
--
-- Dekningskartet sier hvilke spørsmål Antidep skal svare på. Denne migrasjonen
-- gir spørsmålene en søkeplan, søkene en varig logg, kandidatkildene en
-- begrunnet utvalgsbeslutning, og søkedekningen en port som ikke kan lukkes
-- fordi noen mener den er god nok.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en plan per kildeprofil og avgrensning, og ikke per behov
--
-- Fordi 80 spørsmålsmaler ikke er 80 litteratursøk (SOURCE_POLICY.md §1). Et
-- søk etter systematiske oversikter om effekt ved en indikasjon dekker MN12,
-- MN13, MN14, MN15 og MN16 på én gang — de har samme kildeprofil og samme
-- avgrensning. Planens nøkkel er derfor profilen og avgrensningsavtrykket, og
-- behovene henger på den mange-til-mange. Gjenbruk er regelen, ikke unntaket.
--
-- Gjenbruk arver likevel ikke status: en plan som dekker et nytt behov, er ikke
-- ferdig søkt for det behovet bare fordi den var det for de andre. Det er
-- derfor koblingstabellen finnes framfor et felt på planen.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en foreslått søkestreng ikke er et utført søk
--
-- Fordi det er forskjellen mellom dokumentasjon og påstand. En agent som
-- rapporterer et verktøykall, har gitt Antidep sin egen beretning; Antideps
-- egen kjører som faktisk kalte et endepunkt, har gitt et svar med et avtrykk.
-- De to er forskjellige opplysninger, og `execution_evidence` holder dem fra
-- hverandre: `agent_reported` er agentens ord, `machine_executed` er Antideps
-- eget kall med responsavtrykket som bevis.
--
-- Skillet er strukturelt og ikke en konvensjon: et agentrapportert søk *kan
-- ikke* bære et responsavtrykk, og et maskinelt utført *må*. En agent som
-- skrev `machine_executed` i svaret sitt, ville blitt avvist av raden.
--
-- ----------------------------------------------------------------------------
-- Hvorfor et utilgjengelig søkespor ikke er null treff
--
-- Fordi «vi søkte og fant ingenting» og «vi kom ikke til databasen» er to
-- forskjellige opplysninger, og bare den første er et resultat
-- (SOURCE_POLICY.md §4.2, §8.2). `zero_results` krever derfor at treffantallet
-- er kjent og null; `unavailable` krever en registrert begrensning og *forbyr*
-- et treffantall. Det er den samme regelen ANTIDEP_CONSTITUTION.md regel 4
-- allerede håndhever for teknisk svikt, anvendt på søket.
--
-- ----------------------------------------------------------------------------
-- Hvorfor søket ikke kan lukkes av at noen mener det er nok
--
-- Kildepolitikkens §8.1 har fem konkrete krav, og §8.2 sier uttrykkelig at en
-- oppbrukt ressursgrense ikke er en evidenskonklusjon. Ingen av disse er
-- gyldige grunner til å avslutte:
--
--   * tre artikler er funnet,
--   * to agenter er enige,
--   * de første ti treffene er gjennomgått,
--   * arbeidsbudsjettet er brukt opp.
--
-- `workflow.monograph_search_closure_problem(uuid)` er de fem kravene som en
-- port. Den leses av avslutningsveien, og den kan ikke overstyres: et oppbrukt
-- budsjett setter planen på pause — en åpen, ventende tilstand — og lukker den
-- aldri.
--
-- Styrende dokumenter: docs/SOURCE_POLICY.md §3, §4, §6, §8,
-- docs/MONOGRAPH_STANDARD.md §5, docs/ANTIDEP_CONSTITUTION.md regel 3, 4, 7.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Vokabularene
-- ----------------------------------------------------------------------------

create type workflow.monograph_search_outcome as enum (
  'executed',
  'zero_results',
  'unavailable',
  'failed'
);

revoke usage on type workflow.monograph_search_outcome from public;

comment on type workflow.monograph_search_outcome is
  'Hva som faktisk skjedde med ett søk (SOURCE_POLICY.md §4.2, §8.2): executed (søket gikk og ga treff), zero_results (søket gikk og ga null treff — et kontrollert nullsøk), unavailable (søkeveien var ikke tilgjengelig) og failed (verktøyet eller forbindelsen sviktet). De to siste er ikke null treff: «vi søkte og fant ingenting» og «vi kom ikke til databasen» er forskjellige opplysninger, og bare den første er et resultat (ANTIDEP_CONSTITUTION.md regel 4).';

create type workflow.monograph_execution_evidence as enum (
  'agent_reported',
  'machine_executed'
);

revoke usage on type workflow.monograph_execution_evidence from public;

comment on type workflow.monograph_execution_evidence is
  'Hvilket utførelsesbevis Antidep faktisk har for ett søk: agent_reported er den eksterne KI-agentens egen beretning om et verktøykall, machine_executed er Antideps eget kall til en navngitt søketjeneste, med responsavtrykket som bevis. Skillet er strukturelt og ikke en merkelapp: et agentrapportert søk kan ikke bære et responsavtrykk, og et maskinelt utført må. En agents erklæring om et verktøykall skal ikke kunne omtales som maskinelt bekreftet utførelse (SOURCE_POLICY.md §4.3).';

create type workflow.monograph_track_state as enum (
  'pending',
  'covered',
  'unavailable'
);

revoke usage on type workflow.monograph_track_state from public;

comment on type workflow.monograph_track_state is
  'Om et obligatorisk søkespor er forsøkt (SOURCE_POLICY.md §4.2): pending (ikke forsøkt ennå), covered (et dokumentert søk dekker det) eller unavailable (sporet var ikke tilgjengelig, med en registrert begrensning). Et pending spor hindrer at søkedekningen kan erklæres ferdig; et unavailable spor gjør det ikke, men står som en synlig begrensning i utkastet framfor å bli borte.';

create type workflow.monograph_candidate_decision as enum (
  'proposed',
  'selected_for_retrieval',
  'included',
  'excluded',
  'awaiting_access',
  'awaiting_clarification'
);

revoke usage on type workflow.monograph_candidate_decision from public;

comment on type workflow.monograph_candidate_decision is
  'Utvalgsbeslutningen om én kandidatkilde (SOURCE_POLICY.md §4.3): proposed (identifisert, ikke vurdert), selected_for_retrieval (valgt til innhenting), included (inkludert for en navngitt bruk), excluded (ekskludert med en faglig grunn), awaiting_access (kilden er relevant, men ikke tilgjengelig) og awaiting_clarification (noe må avklares før den kan vurderes). Betalingsmur hører til awaiting_access og aldri til excluded: en tilgangsbegrensning er ikke en faglig eksklusjonsgrunn, og raden håndhever det.';

create type workflow.monograph_coverage_outcome as enum (
  'accepted',
  'insufficient'
);

revoke usage on type workflow.monograph_coverage_outcome from public;

comment on type workflow.monograph_coverage_outcome is
  'Utfallet av den separate kontrollen av søkedekningen (SOURCE_POLICY.md §6, §8.1): accepted (kontrollen godtar begrunnelsen for å stoppe) eller insufficient (den gjør det ikke). En accepted krever at kontrollen faktisk søkte selv: et kontrollledd som bare leser generatorens valgte referanser, kan kontrollere sitatene, men ikke vurdere søkets dekningsgrad.';

-- ----------------------------------------------------------------------------
-- 2. Søkeplanen
-- ----------------------------------------------------------------------------

create table workflow.monograph_search_plans (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  edition_id uuid not null
    references knowledge.monograph_editions (id) on update restrict on delete restrict,
  profile_id uuid not null
    references knowledge.monograph_source_profiles (id)
    on update restrict on delete restrict,
  -- Deterministisk av profilen og avgrensningen: den samme planen bygget to
  -- ganger er én rad, og et nytt behov med samme profil og avgrensning finner
  -- planen framfor å lage en til.
  plan_key text not null,
  plan_version integer not null default 1,

  -- Avgrensningen planen gjelder, i den samme formen behovene har.
  indication_concept_id uuid
    references catalog.clinical_concepts (id) on update restrict on delete restrict,
  outcome_concept_id uuid
    references catalog.clinical_concepts (id) on update restrict on delete restrict,
  population_id uuid
    references catalog.populations (id) on update restrict on delete restrict,
  comparator_drug_id uuid
    references catalog.drugs (id) on update restrict on delete restrict,
  switch_target_drug_id uuid
    references catalog.drugs (id) on update restrict on delete restrict,
  scope_labels jsonb not null default '{}'::jsonb,
  scope_digest text not null,

  -- Når søkedekningen ble erklært ferdig, og på hvilket grunnlag.
  closed_at timestamptz,
  closed_note text,
  closed_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,

  -- Og når arbeidet står fordi budsjettet er brukt opp. En egen tilstand med
  -- vilje: et oppbrukt budsjett er åpent, ventende arbeid og aldri en
  -- konklusjon om evidensen (SOURCE_POLICY.md §8.2).
  paused_at timestamptz,
  paused_reason text,

  created_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint monograph_search_plans_reference_key unique (reference),
  constraint monograph_search_plans_key_key unique (edition_id, plan_key),
  constraint monograph_search_plans_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$'),
  constraint monograph_search_plans_plan_key_shape_check
    check (plan_key = btrim(plan_key) and length(plan_key) between 1 and 300),
  constraint monograph_search_plans_version_check check (plan_version >= 1),
  constraint monograph_search_plans_scope_digest_shape_check
    check (scope_digest ~ '^sha256:[0-9a-f]{64}$'),
  constraint monograph_search_plans_scope_labels_object_check
    check (jsonb_typeof(scope_labels) = 'object'),
  constraint monograph_search_plans_closure_shape_check
    check (num_nonnulls(closed_at, closed_note, closed_by_actor_id) in (0, 3)),
  constraint monograph_search_plans_closed_note_shape_check
    check (closed_note is null
           or (closed_note = btrim(closed_note) and length(closed_note) between 1 and 2000)),
  constraint monograph_search_plans_pause_pairing_check
    check ((paused_at is null) = (paused_reason is null)),
  constraint monograph_search_plans_pause_reason_shape_check
    check (paused_reason is null
           or (paused_reason = btrim(paused_reason)
               and length(paused_reason) between 1 and 2000)),
  -- En lukket plan er ikke på pause. De to sier motsatte ting om det samme
  -- arbeidet.
  constraint monograph_search_plans_not_closed_and_paused_check
    check (closed_at is null or paused_at is null)
);

comment on table workflow.monograph_search_plans is
  'Én søkeplan per kildeprofil og avgrensning i én monografiutgave. Nøkkelen er profilen og avgrensningsavtrykket og ikke behovet, fordi 80 spørsmålsmaler ikke er 80 litteratursøk (SOURCE_POLICY.md §1): et oversiktssøk om effekt ved én indikasjon dekker MN12–MN16 på én gang. Behovene henger på planen mange-til-mange, slik at gjenbruk ikke arver status — en plan som dekker et nytt behov, er ikke ferdig søkt for det behovet bare fordi den var det for de andre. closed_at er en erklært ferdig søkedekning etter §8.1; paused_at er et oppbrukt arbeidsbudsjett, som er åpent ventende arbeid og aldri en konklusjon om evidensen (§8.2).';
comment on column workflow.monograph_search_plans.plan_version is
  'Versjonen av planen. Økes når avgrensningen eller de nødvendige søkesporene endres, slik at en tidligere godkjent dekningskontroll ikke kan bære en plan som er blitt en annen. Den separate kontrollen er per planversjon.';
comment on column workflow.monograph_search_plans.paused_reason is
  'Hvorfor planen står: oppbrukt tid, oppbrukt modellkvote, en utilgjengelig database eller en verktøyfeil. En egen kolonne fordi en ressursgrense aldri er en evidenskonklusjon (SOURCE_POLICY.md §8.2) — den setter arbeidet på pause, og lukker det ikke.';

alter table workflow.monograph_search_plans enable row level security;

create index monograph_search_plans_edition_idx
  on workflow.monograph_search_plans (edition_id, closed_at);

create trigger monograph_search_plans_set_row_timestamps
  before insert or update on workflow.monograph_search_plans
  for each row execute function catalog.set_row_timestamps();

create function workflow.freeze_monograph_search_plan()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.reference is distinct from old.reference
     or new.edition_id is distinct from old.edition_id
     or new.profile_id is distinct from old.profile_id
     or new.plan_key is distinct from old.plan_key
     or new.scope_digest is distinct from old.scope_digest
     or new.created_by_actor_id is distinct from old.created_by_actor_id
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En søkeplans profil og avgrensning er uforanderlig.',
      hint = 'Profilen og avgrensningen er det planen er, og søkeloggen under den er dokumentasjonen på nettopp det søket. En endret avgrensning er en ny plan (SOURCE_POLICY.md §4.1).';
  end if;

  if old.closed_at is not null and new.closed_at is null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En erklært ferdig søkedekning kan ikke gjenåpnes.',
      hint = 'Erklæringen er et historisk faktum svarene hviler på. Kommer det nye kilder, er det en ny planversjon med sin egen dekningskontroll.';
  end if;

  return new;
end;
$$;

comment on function workflow.freeze_monograph_search_plan() is
  'Holder søkeplanens profil og avgrensning uforanderlig, og hindrer at en erklært ferdig søkedekning gjenåpnes. Nye kilder gir en ny planversjon med sin egen dekningskontroll framfor en omskrevet erklæring.';

revoke execute on function workflow.freeze_monograph_search_plan() from public;

create trigger monograph_search_plans_are_frozen
  before update on workflow.monograph_search_plans
  for each row execute function workflow.freeze_monograph_search_plan();

create table workflow.monograph_search_plan_needs (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null
    references workflow.monograph_search_plans (id) on update restrict on delete restrict,
  need_id uuid not null
    references knowledge.monograph_needs (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint monograph_search_plan_needs_pair_key unique (plan_id, need_id)
);

comment on table workflow.monograph_search_plan_needs is
  'Hvilke kunnskapsbehov én søkeplan dekker. Mange-til-mange med vilje: ett søk kan dekke flere behov, og ett behov kan kreve flere planer med hver sin kildeprofil (SOURCE_POLICY.md §1, §3).';

alter table workflow.monograph_search_plan_needs enable row level security;

create index monograph_search_plan_needs_need_idx
  on workflow.monograph_search_plan_needs (need_id);

create trigger monograph_search_plan_needs_set_created_at
  before insert or update on workflow.monograph_search_plan_needs
  for each row execute function catalog.set_created_at();

create trigger monograph_search_plan_needs_are_append_only
  before update or delete on workflow.monograph_search_plan_needs
  for each row execute function knowledge.reject_append_only_mutation();

-- ----------------------------------------------------------------------------
-- 3. Søkeloggen
--
-- Det faktisk utførte søket, med alt kildepolitikkens §4.3 krever lagret: hvor
-- det ble søkt, med hvilken streng, med hvilke filtre, når, hvor mange treff
-- som kom, hvor mye som ble gjennomgått, og om trefflisten ble avkortet.
-- ----------------------------------------------------------------------------

-- Rekkefølgen søkene ble registrert i, som et databaseeid nummer.
--
-- `executed_at` kan ikke bære den: to søk registrert i den samme transaksjonen
-- kan ha samme tidsstempel, og «ble avkortingen fulgt opp av et senere søk?» er
-- et spørsmål om rekkefølge og ikke om klokka. cache 1 er en del av garantien —
-- en bufret sekvens deler ut blokker per økt, og to økter kunne da fått numre i
-- motsatt rekkefølge av skrivingene. Samme grep og samme begrunnelse som
-- registreringsnummeret på verifikasjonene (migrasjon 005å).
create sequence workflow.monograph_search_registration_seq as bigint cache 1;

revoke all on sequence workflow.monograph_search_registration_seq from public;

comment on sequence workflow.monograph_search_registration_seq is
  'Kilden til registreringsnummeret på workflow.monograph_searches. Rekkefølgen er det porten leser når den spør om en avkortet treffliste ble fulgt opp av et senere søk, og et tidsstempel kan ikke svare på det: to søk i den samme transaksjonen har samme now(). Hull i rekken er uten betydning.';

create table workflow.monograph_searches (
  id uuid primary key default gen_random_uuid(),

  -- Rekkefølgen søket ble registrert i. Databaseeid, og det porten leser når
  -- den spør om en avkorting ble fulgt opp.
  registration_ordinal bigint not null
    default nextval('workflow.monograph_search_registration_seq'),

  plan_id uuid not null
    references workflow.monograph_search_plans (id) on update restrict on delete restrict,
  plan_version integer not null,

  -- Den faktisk brukte databasen eller plattformen, og den faktisk brukte
  -- søkestrengen. Ikke en foreslått streng: en foreslått søkestreng er ikke et
  -- utført søk (SOURCE_POLICY.md §4.3).
  platform text not null,
  query_string text not null,
  filters text,
  executed_at timestamptz not null,

  -- Treffantallet når det er kjent, hvor mye som ble gjennomgått, og om
  -- trefflisten ble avkortet. En side med ti treff er ikke et søk uten flere
  -- treff.
  result_count integer,
  screened_count integer not null default 0,
  truncated boolean not null default false,
  truncation_note text,

  outcome workflow.monograph_search_outcome not null,
  limitation_note text,

  execution_evidence workflow.monograph_execution_evidence not null,
  -- For et maskinelt utført søk: endepunktet som ble kalt, og avtrykket av
  -- svaret som kom tilbake. Det er dette som gjør utførelsen bekreftet framfor
  -- rapportert.
  evidence_endpoint text,
  response_digest text,

  -- Hvilke obligatoriske søkespor søket dekker.
  track_codes text[] not null default array[]::text[],

  agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  recorded_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint monograph_searches_platform_shape_check
    check (platform = btrim(platform) and length(platform) between 1 and 200),
  constraint monograph_searches_query_shape_check
    check (query_string = btrim(query_string) and length(query_string) between 1 and 4000),
  constraint monograph_searches_filters_shape_check
    check (filters is null
           or (filters = btrim(filters) and length(filters) between 1 and 2000)),
  constraint monograph_searches_counts_check
    check (screened_count >= 0 and (result_count is null or result_count >= 0)),
  constraint monograph_searches_version_check check (plan_version >= 1),
  constraint monograph_searches_truncation_pairing_check
    check (truncated = (truncation_note is not null)),
  constraint monograph_searches_truncation_note_shape_check
    check (truncation_note is null
           or (truncation_note = btrim(truncation_note)
               and length(truncation_note) between 1 and 2000)),
  constraint monograph_searches_limitation_note_shape_check
    check (limitation_note is null
           or (limitation_note = btrim(limitation_note)
               and length(limitation_note) between 1 and 2000)),

  -- Utfallet bestemmer hva som skal være satt, og regelen er uttømmende over
  -- vokabularet. ELSE false, slik at en ny utfallsverdi uten sin gren avvises
  -- framfor å gli gjennom.
  constraint monograph_searches_outcome_shape_check
    check (
      case outcome
        -- Et utført søk har et kjent treffantall og ingen begrensning.
        when 'executed' then result_count is not null and limitation_note is null
        -- Et kontrollert nullsøk: søket gikk, og treffantallet var null.
        when 'zero_results' then result_count = 0 and limitation_note is null
                                 and not truncated
        -- En utilgjengelig søkevei har ingen treffantall. Uten dette kunne
        -- «vi kom ikke til databasen» blitt lagret som null treff
        -- (SOURCE_POLICY.md §4.2, §8.2).
        when 'unavailable' then result_count is null and limitation_note is not null
                                 and screened_count = 0
        when 'failed' then result_count is null and limitation_note is not null
                            and screened_count = 0
        else false
      end
    ),

  -- Utførelsesbeviset er strukturelt. Et agentrapportert søk kan ikke bære et
  -- responsavtrykk, og et maskinelt utført må: en agent som skrev
  -- «machine_executed» i svaret sitt, avvises av raden (SOURCE_POLICY.md §4.3).
  constraint monograph_searches_evidence_shape_check
    check (
      case execution_evidence
        when 'agent_reported' then
          evidence_endpoint is null and response_digest is null
          and agent_run_id is not null
        when 'machine_executed' then
          evidence_endpoint is not null and response_digest is not null
        else false
      end
    ),
  constraint monograph_searches_response_digest_shape_check
    check (response_digest is null or response_digest ~ '^sha256:[0-9a-f]{64}$'),
  constraint monograph_searches_evidence_endpoint_shape_check
    check (evidence_endpoint is null
           or (evidence_endpoint = btrim(evidence_endpoint)
               and length(evidence_endpoint) between 1 and 500))
);

comment on table workflow.monograph_searches is
  'Ett faktisk utført søk, med alt SOURCE_POLICY.md §4.3 krever lagret: database og plattform, den eksakte søkestrengen, filtrene, tidspunktet, returnert treffantall når det er kjent, hvor mye som ble gjennomgått, og om paginering eller en resultatgrense avkortet trefflisten. En foreslått søkestreng er ikke et utført søk, og en side med ti treff er ikke et søk uten flere treff. Utfallet skiller et kontrollert nullsøk fra en utilgjengelig søkevei og fra en verktøyfeil: de to siste har ingen treffantall i det hele tatt, fordi «vi kom ikke til databasen» ikke er null treff.';
comment on column workflow.monograph_searches.execution_evidence is
  'Hvilket utførelsesbevis Antidep har: agent_reported er agentens egen beretning om et verktøykall, machine_executed er Antideps eget kall med endepunktet og responsavtrykket som bevis. Skillet er håndhevet av raden og ikke av en konvensjon, slik at en agents erklæring aldri kan omtales som maskinelt bekreftet utførelse.';
comment on column workflow.monograph_searches.track_codes is
  'Hvilke obligatoriske søkespor i SOURCE_POLICY.md §4.2 dette søket dekker. Står som koder og ikke som fremmednøkler fordi sporet hører til standardversjonen, og et søk utført under en tidligere versjon skal beholde sin egen dekning.';

alter sequence workflow.monograph_search_registration_seq
  owned by workflow.monograph_searches.registration_ordinal;

alter table workflow.monograph_searches
  add constraint monograph_searches_registration_ordinal_key unique (registration_ordinal);

comment on column workflow.monograph_searches.registration_ordinal is
  'Rekkefølgen søket ble registrert i, fra en databaseeid sekvens. Porten leser den når den spør om en avkortet treffliste ble fulgt opp av et senere søk; et tidsstempel kan ikke svare på det, fordi to søk registrert i den samme transaksjonen har samme now().';

alter table workflow.monograph_searches enable row level security;

create index monograph_searches_plan_idx
  on workflow.monograph_searches (plan_id, registration_ordinal);

create trigger monograph_searches_set_created_at
  before insert or update on workflow.monograph_searches
  for each row execute function catalog.set_created_at();

create trigger monograph_searches_are_append_only
  before update or delete on workflow.monograph_searches
  for each row execute function knowledge.reject_append_only_mutation();

-- ----------------------------------------------------------------------------
-- 4. Sporene som må være forsøkt
--
-- Én rad per obligatorisk søkespor for planens profil, opprettet som `pending`
-- når planen lages. Et spor som ikke er forsøkt, hindrer at søkedekningen kan
-- erklæres ferdig; et spor som var utilgjengelig, står som en synlig
-- begrensning.
-- ----------------------------------------------------------------------------

create table workflow.monograph_search_track_attempts (
  id uuid primary key default gen_random_uuid(),

  plan_id uuid not null
    references workflow.monograph_search_plans (id) on update restrict on delete restrict,
  track_id uuid not null
    references knowledge.monograph_search_tracks (id) on update restrict on delete restrict,

  state workflow.monograph_track_state not null default 'pending',
  search_id uuid
    references workflow.monograph_searches (id) on update restrict on delete restrict,
  note text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint monograph_search_track_attempts_pair_key unique (plan_id, track_id),
  constraint monograph_search_track_attempts_note_shape_check
    check (note is null or (note = btrim(note) and length(note) between 1 and 2000)),
  constraint monograph_search_track_attempts_state_shape_check
    check (
      case state
        when 'pending' then search_id is null and note is null
        -- Et dekket spor peker på søket som dekket det. Uten kravet kunne
        -- sporet blitt erklært dekket uten at et søk fantes.
        when 'covered' then search_id is not null
        -- Et utilgjengelig spor har en registrert begrensning og ikke et søk.
        when 'unavailable' then search_id is null and note is not null
        else false
      end
    )
);

comment on table workflow.monograph_search_track_attempts is
  'Om hvert obligatorisk søkespor for planens kildeprofil er forsøkt (SOURCE_POLICY.md §4.2). Radene opprettes som pending når planen lages, slik at et spor ingen har forsøkt, er synlig framfor å mangle. Et dekket spor peker på søket som dekket det; et utilgjengelig spor har en registrert begrensning og ikke et søk.';

alter table workflow.monograph_search_track_attempts enable row level security;

create index monograph_search_track_attempts_plan_idx
  on workflow.monograph_search_track_attempts (plan_id, state);

create trigger monograph_search_track_attempts_set_row_timestamps
  before insert or update on workflow.monograph_search_track_attempts
  for each row execute function catalog.set_row_timestamps();

-- ----------------------------------------------------------------------------
-- 5. Kandidatkildene og utvalgsbeslutningen
-- ----------------------------------------------------------------------------

create table workflow.monograph_candidate_sources (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  edition_id uuid not null
    references knowledge.monograph_editions (id) on update restrict on delete restrict,
  plan_id uuid
    references workflow.monograph_search_plans (id) on update restrict on delete restrict,
  search_id uuid
    references workflow.monograph_searches (id) on update restrict on delete restrict,

  -- Identiteten. En DOI er artikkelens bibliografiske identitet; en PMID peker
  -- på en omtale av den. Begge lagres, og begge er identiteter man kan slå opp.
  identifier_kind text not null,
  identifier_value text not null,
  title text not null,
  authors_or_issuer text,
  publisher_or_journal text,
  publication_year integer,

  -- Hvordan kilden ble funnet. «Søk i PubMed», «referanselisten i en oversikt»,
  -- «et siteringssøk» — dokumentert oppdagelsesvei etter §4.3.
  discovery_path text not null,

  -- Kilden når den er registrert i Antidep. NULL betyr en kandidat som ikke er
  -- innhentet ennå.
  source_id uuid
    references knowledge.sources (id) on update restrict on delete restrict,

  decision workflow.monograph_candidate_decision not null default 'proposed',
  decision_reason text,
  decided_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  decided_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  decided_at timestamptz,

  -- En tilgangsbegrensning, ikke en faglig dom. Er den satt, kan kilden ikke
  -- ekskluderes: en betalingsmur er ikke en faglig eksklusjonsgrunn
  -- (SOURCE_POLICY.md §4.3, §5).
  access_limited boolean not null default false,
  access_limitation_note text,

  -- Om kilden med rimelighet kan endre hovedkonklusjonen. Vesentligheten må
  -- begrunnes og kontrolleres separat (SOURCE_POLICY.md §8.1), og en uavklart
  -- vesentlig kilde hindrer at søket kan avsluttes.
  could_change_conclusion boolean not null default false,
  materiality_reason text,

  proposed_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  recorded_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint monograph_candidate_sources_reference_key unique (reference),
  constraint monograph_candidate_sources_identity_key
    unique (edition_id, identifier_kind, identifier_value),
  constraint monograph_candidate_sources_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$'),
  constraint monograph_candidate_sources_identifier_kind_check
    check (identifier_kind in ('doi', 'pmid', 'pmcid', 'url', 'title', 'registry_id')),
  constraint monograph_candidate_sources_identifier_value_shape_check
    check (identifier_value = btrim(identifier_value)
           and length(identifier_value) between 1 and 500),
  constraint monograph_candidate_sources_title_shape_check
    check (title = btrim(title) and length(title) between 1 and 1000),
  constraint monograph_candidate_sources_discovery_path_shape_check
    check (discovery_path = btrim(discovery_path)
           and length(discovery_path) between 1 and 500),
  constraint monograph_candidate_sources_year_check
    check (publication_year is null or publication_year between 1800 and 2200),
  constraint monograph_candidate_sources_decision_reason_shape_check
    check (decision_reason is null
           or (decision_reason = btrim(decision_reason)
               and length(decision_reason) between 1 and 2000)),
  constraint monograph_candidate_sources_decision_origin_check
    check (num_nonnulls(decided_by_actor_id, decided_by_agent_run_id) <= 1),
  constraint monograph_candidate_sources_access_note_pairing_check
    check (access_limited = (access_limitation_note is not null)),
  constraint monograph_candidate_sources_access_note_shape_check
    check (access_limitation_note is null
           or (access_limitation_note = btrim(access_limitation_note)
               and length(access_limitation_note) between 1 and 2000)),
  constraint monograph_candidate_sources_materiality_pairing_check
    check (could_change_conclusion = (materiality_reason is not null)),
  constraint monograph_candidate_sources_materiality_reason_shape_check
    check (materiality_reason is null
           or (materiality_reason = btrim(materiality_reason)
               and length(materiality_reason) between 1 and 2000)),

  -- Beslutningen bestemmer hva som skal være satt.
  constraint monograph_candidate_sources_decision_shape_check
    check (
      case decision
        when 'proposed' then decided_at is null
        -- En eksklusjon krever en faglig grunn og et navngitt opphav. Uten det
        -- kunne en kilde forsvinne uten at noen tok stilling til noe.
        when 'excluded' then decision_reason is not null and decided_at is not null
                             and num_nonnulls(decided_by_actor_id, decided_by_agent_run_id) = 1
        when 'awaiting_access' then decided_at is not null
        when 'awaiting_clarification' then decision_reason is not null
                                           and decided_at is not null
        when 'selected_for_retrieval' then decision_reason is not null
                                           and decided_at is not null
        when 'included' then decision_reason is not null and decided_at is not null
        else false
      end
    ),

  -- Og betalingsmuren er strukturelt utelukket som eksklusjonsgrunn.
  constraint monograph_candidate_sources_paywall_is_not_exclusion_check
    check (not (access_limited and decision = 'excluded'))
);

comment on table workflow.monograph_candidate_sources is
  'Én identifisert kandidatkilde i én monografiutgave, med identifikatorer, bibliografi, oppdagelsesvei og utvalgsbeslutning (SOURCE_POLICY.md §4.3). Beslutningsvokabularet skiller «valgt til innhenting» fra «inkludert for en navngitt bruk», «ekskludert med faglig grunn», «avventer tilgang» og «avventer avklaring». En eksklusjon krever en faglig grunn og et navngitt opphav, og en kilde med en registrert tilgangsbegrensning kan strukturelt ikke ekskluderes: en betalingsmur er en tilgangsbegrensning og ikke en faglig eksklusjonsgrunn.';
comment on column workflow.monograph_candidate_sources.could_change_conclusion is
  'Om kilden med rimelighet kan endre hovedkonklusjonen. Vesentligheten skal begrunnes og kontrolleres separat (SOURCE_POLICY.md §8.1), og en uavklart vesentlig kilde hindrer at søkedekningen kan erklæres ferdig — det er nettopp den kilden «ingen ulest eller utilgjengelig kilde som med rimelighet kan endre hovedkonklusjonen» handler om.';

alter table workflow.monograph_candidate_sources enable row level security;

create index monograph_candidate_sources_edition_idx
  on workflow.monograph_candidate_sources (edition_id, decision);
create index monograph_candidate_sources_plan_idx
  on workflow.monograph_candidate_sources (plan_id);

create trigger monograph_candidate_sources_set_row_timestamps
  before insert or update on workflow.monograph_candidate_sources
  for each row execute function catalog.set_row_timestamps();

create function workflow.freeze_monograph_candidate_source()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.reference is distinct from old.reference
     or new.edition_id is distinct from old.edition_id
     or new.identifier_kind is distinct from old.identifier_kind
     or new.identifier_value is distinct from old.identifier_value
     or new.discovery_path is distinct from old.discovery_path
     or new.search_id is distinct from old.search_id
     or new.proposed_by_agent_run_id is distinct from old.proposed_by_agent_run_id
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En kandidatkildes identitet og oppdagelsesvei er uforanderlig.',
      hint = 'Identifikatoren og hvordan kilden ble funnet, er dokumentasjonen på søket. En omskriving ville gjort søkeloggen til noe annet enn det som skjedde (SOURCE_POLICY.md §4.3).';
  end if;
  return new;
end;
$$;

comment on function workflow.freeze_monograph_candidate_source() is
  'Holder kandidatkildens identifikator, oppdagelsesvei og opphav uforanderlig. Utvalgsbeslutningen og tilgangstilstanden endres; dokumentasjonen på hvordan kilden ble funnet, gjør det ikke.';

revoke execute on function workflow.freeze_monograph_candidate_source() from public;

create trigger monograph_candidate_sources_are_frozen
  before update on workflow.monograph_candidate_sources
  for each row execute function workflow.freeze_monograph_candidate_source();

create table workflow.monograph_candidate_source_needs (
  id uuid primary key default gen_random_uuid(),
  candidate_source_id uuid not null
    references workflow.monograph_candidate_sources (id)
    on update restrict on delete restrict,
  need_id uuid not null
    references knowledge.monograph_needs (id) on update restrict on delete restrict,
  -- Hva kilden kan brukes til for nettopp dette behovet. En kilde godkjennes
  -- for en bestemt bruk og avgrensning, ikke universelt (SOURCE_POLICY.md §2).
  proposed_use text not null,
  created_at timestamptz not null default now(),

  constraint monograph_candidate_source_needs_pair_key
    unique (candidate_source_id, need_id),
  constraint monograph_candidate_source_needs_use_shape_check
    check (proposed_use = btrim(proposed_use) and length(proposed_use) between 1 and 1000)
);

comment on table workflow.monograph_candidate_source_needs is
  'Hvilke kunnskapsbehov én kandidatkilde kan brukes til, og til hva. Mange-til-mange, fordi én kilde kan bidra til flere behov og ett behov kan kreve flere kilder (SOURCE_POLICY.md §1). Bruken står per behov og ikke på kilden, fordi en kilde godkjennes for en bestemt bruk og avgrensning og aldri universelt: den samme artikkelen kan være egnet for farmakokinetikk og uegnet for sammenlignende klinisk effekt (§2).';

alter table workflow.monograph_candidate_source_needs enable row level security;

create index monograph_candidate_source_needs_need_idx
  on workflow.monograph_candidate_source_needs (need_id);

create trigger monograph_candidate_source_needs_set_created_at
  before insert or update on workflow.monograph_candidate_source_needs
  for each row execute function catalog.set_created_at();

create trigger monograph_candidate_source_needs_are_append_only
  before update or delete on workflow.monograph_candidate_source_needs
  for each row execute function knowledge.reject_append_only_mutation();

-- ----------------------------------------------------------------------------
-- 6. Den separate kontrollen av søkedekningen
--
-- Motprøvingen skal lete etter kilder den første agenten overså, kontrollere
-- sentrale eksklusjoner, og godta eller avvise begrunnelsen for å stoppe. Et
-- kontrollledd som bare leser generatorens valgte referanser, kan kontrollere
-- sitatene, men ikke vurdere søkets dekningsgrad (SOURCE_POLICY.md §6).
--
-- Derfor krever en godtatt kontroll at den faktisk søkte selv.
-- ----------------------------------------------------------------------------

create table workflow.monograph_coverage_controls (
  id uuid primary key default gen_random_uuid(),

  plan_id uuid not null
    references workflow.monograph_search_plans (id) on update restrict on delete restrict,
  plan_version integer not null,

  outcome workflow.monograph_coverage_outcome not null,
  note text not null,

  -- Om kontrollen gjorde sine egne søk. En godtatt dekning krever det.
  searched_independently boolean not null,
  -- Hvor mange oversette kilder kontrollen fant, og hvor mange sentrale
  -- eksklusjoner den gikk gjennom.
  missed_candidates integer not null default 0,
  exclusions_checked integer not null default 0,
  -- Om kontrollen faktisk vurderte vesentligheten av de uavklarte kildene.
  materiality_assessed boolean not null default false,

  agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  recorded_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint monograph_coverage_controls_version_key unique (plan_id, plan_version),
  constraint monograph_coverage_controls_version_check check (plan_version >= 1),
  constraint monograph_coverage_controls_note_shape_check
    check (note = btrim(note) and length(note) between 1 and 4000),
  constraint monograph_coverage_controls_counts_check
    check (missed_candidates >= 0 and exclusions_checked >= 0),
  -- En godtatt dekning krever at kontrollen søkte selv og vurderte
  -- vesentligheten. Uten det ville «to agenter er enige» vært nok, og det er
  -- uttrykkelig ikke et tilstrekkelig kriterium (SOURCE_POLICY.md §8.1).
  constraint monograph_coverage_controls_accepted_needs_own_search_check
    check (outcome <> 'accepted' or (searched_independently and materiality_assessed))
);

comment on table workflow.monograph_coverage_controls is
  'Den separate kontrollen av søkedekningen for én planversjon (SOURCE_POLICY.md §6, §8.1). Én rad per planversjon: en kontroll godtar en bestemt plan, og en plan som er blitt en annen, trenger en ny kontroll. En godtatt dekning krever strukturelt at kontrollen søkte selv og vurderte vesentligheten av de uavklarte kildene — et kontrollledd som bare leser generatorens valgte referanser, kan kontrollere sitatene, men ikke vurdere dekningsgraden, og «to agenter er enige» er uttrykkelig ikke et tilstrekkelig kriterium.';

alter table workflow.monograph_coverage_controls enable row level security;

create trigger monograph_coverage_controls_set_created_at
  before insert or update on workflow.monograph_coverage_controls
  for each row execute function catalog.set_created_at();

create trigger monograph_coverage_controls_are_append_only
  before update or delete on workflow.monograph_coverage_controls
  for each row execute function knowledge.reject_append_only_mutation();

-- ----------------------------------------------------------------------------
-- 7. Porten: når søket kan stoppe
--
-- Kildepolitikkens §8.1 har fem krav, og §8.2 sier uttrykkelig at en oppbrukt
-- ressursgrense ikke er en evidenskonklusjon. Denne funksjonen er de kravene
-- som en port, og den svarer med én setning om hva som mangler — eller NULL.
--
-- Den kan ikke overstyres. «Tre artikler er funnet», «to agenter er enige»,
-- «de første ti treffene er gjennomgått» og «arbeidsbudsjettet er brukt opp»
-- er ingen av dem en av de fem.
-- ----------------------------------------------------------------------------

create function workflow.monograph_search_closure_problem(p_plan_id uuid)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_profile text;
  v_pending text;
  v_count integer;
  v_last_candidate_ordinal bigint;
  v_control workflow.monograph_coverage_controls;
  v_unresolved text;
  v_open_truncation text;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.id = p_plan_id;

  if not found then
    return 'Søkeplanen finnes ikke.';
  end if;

  select sp.code into v_profile
  from knowledge.monograph_source_profiles sp
  where sp.id = v_plan.profile_id;

  -- 0. Et oppbrukt budsjett er åpent arbeid, ikke en ferdig søkedekning.
  if v_plan.paused_at is not null then
    return format(
      'Søket står på pause og er ikke ferdig: %s. En oppbrukt ressursgrense gir åpent, ventende arbeid og aldri en konklusjon om evidensen.',
      v_plan.paused_reason);
  end if;

  -- 1. Planen skal dekke minst ett behov. En plan uten behov er et søk uten et
  --    spørsmål.
  select count(*) into v_count
  from workflow.monograph_search_plan_needs n where n.plan_id = p_plan_id;
  if v_count = 0 then
    return 'Søkeplanen dekker ikke noe kunnskapsbehov.';
  end if;

  -- 2. Hvert obligatorisk søkespor skal være forsøkt og dokumentert.
  select string_agg(t.label, '; ' order by t.ordinal) into v_pending
  from workflow.monograph_search_track_attempts a
  join knowledge.monograph_search_tracks t on t.id = a.track_id
  where a.plan_id = p_plan_id and a.state = 'pending';
  if v_pending is not null then
    return format(
      'Disse obligatoriske søkesporene er ikke forsøkt ennå: %s. Et spor som ikke er forsøkt, hindrer at søkedekningen kan erklæres ferdig (SOURCE_POLICY.md §4.2).',
      v_pending);
  end if;

  -- 3. Minst ett søk må faktisk ha gått. En plan der alle søkeveier var
  --    utilgjengelige, har ingen dekning å erklære — den har en begrensning.
  select count(*) into v_count
  from workflow.monograph_searches s
  where s.plan_id = p_plan_id
    and s.plan_version = v_plan.plan_version
    and s.outcome in ('executed', 'zero_results');
  if v_count = 0 then
    return 'Ingen søk i denne planversjonen har faktisk gått. En utilgjengelig søkevei er en registrert begrensning og ikke en gjennomført søkedekning (SOURCE_POLICY.md §8.2).';
  end if;

  -- 4. Ingen skjult treffavkorting. En avkortet treffliste må være fulgt opp av
  --    et søk på den samme plattformen som ikke ble avkortet; ellers står det
  --    igjen treff ingen har sett.
  select string_agg(distinct s.platform, ', ' order by s.platform) into v_open_truncation
  from workflow.monograph_searches s
  where s.plan_id = p_plan_id
    and s.plan_version = v_plan.plan_version
    and s.truncated
    and not exists (
      select 1 from workflow.monograph_searches later
      where later.plan_id = s.plan_id
        and later.plan_version = s.plan_version
        and later.platform = s.platform
        and not later.truncated
        and later.outcome in ('executed', 'zero_results')
        and later.registration_ordinal > s.registration_ordinal
    );
  if v_open_truncation is not null then
    return format(
      'Trefflisten ble avkortet på %s uten at et senere søk dekket resten. En side med ti treff er ikke et søk uten flere treff (SOURCE_POLICY.md §4.3).',
      v_open_truncation);
  end if;

  -- 5. Ingen uavklart kilde som med rimelighet kan endre hovedkonklusjonen.
  select string_agg(c.title, '; ' order by c.title) into v_unresolved
  from workflow.monograph_candidate_sources c
  where c.plan_id = p_plan_id
    and c.could_change_conclusion
    and c.decision not in ('included', 'excluded');
  if v_unresolved is not null then
    return format(
      'Disse kildene kan endre hovedkonklusjonen og er fortsatt uavklarte: %s. En ulest eller utilgjengelig kilde som med rimelighet kan endre svaret, hindrer at søket kan avsluttes (SOURCE_POLICY.md §8.1).',
      v_unresolved);
  end if;

  -- 6. Metningssignalet: to supplerende søkepasseringer uten nye kilder.
  --    Hoppes over for de autoritative regulatoriske profilene, der én riktig,
  --    gjeldende kilde kan være tilstrekkelig — Antidep skal ikke kreve en
  --    ekstra artikkel for å bekrefte en norsk godkjent styrke (§8.1).
  if v_profile not in ('REG', 'PROD') then
    -- Søket som fant den nyeste kandidatkilden. Passeringene som teller, er de
    -- som er registrert *etter* det: en passering som selv fant kilden, er ikke
    -- en passering uten nye funn.
    select max(s.registration_ordinal) into v_last_candidate_ordinal
    from workflow.monograph_searches s
    join workflow.monograph_candidate_sources c on c.search_id = s.id
    where c.plan_id = p_plan_id;

    -- En kandidat registrert uten et søk — et redaksjonelt tillegg — nullstiller
    -- ikke metningssignalet av seg selv, men den nyeste av dem teller: en kilde
    -- lagt til etter siste passering er en kilde passeringene ikke så.
    if exists (
      select 1 from workflow.monograph_candidate_sources c
      where c.plan_id = p_plan_id and c.search_id is null
        and c.created_at > coalesce(
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

comment on function workflow.monograph_search_closure_problem(uuid) is
  'Én setning om hva som hindrer at søkedekningen kan erklæres ferdig, eller NULL. Er de konkrete stoppkravene i SOURCE_POLICY.md §8.1 som en port: planen må dekke et behov, hvert obligatorisk søkespor må være forsøkt og dokumentert, minst ett søk må faktisk ha gått, ingen avkortet treffliste kan stå igjen udekket, ingen uavklart kilde som kan endre hovedkonklusjonen kan stå åpen, metningssignalet må være gitt — unntatt for de autoritative regulatoriske profilene, der én gjeldende kilde kan være nok — og den separate dekningskontrollen må godta begrunnelsen. Et oppbrukt arbeidsbudsjett gir åpent arbeid og aldri en ferdig dekning (§8.2). Porten kan ikke overstyres: verken tre funne artikler, to enige agenter, ti gjennomgåtte treff eller et brukt budsjett er en av kravene.';

revoke execute on function workflow.monograph_search_closure_problem(uuid) from public;

-- ----------------------------------------------------------------------------
-- 8. Å bygge søkeplanene av behovene
--
-- Deterministisk og idempotent, som utvidelsen av dekningskartet: gitt de
-- samme behovene og de samme kildeprofilene er plansettet alltid det samme.
-- ----------------------------------------------------------------------------

create function workflow.build_monograph_search_plans(p_edition_id uuid)
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
begin
  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.id = p_edition_id
  for update;

  if not found or v_edition.superseded_at is not null then
    return 0;
  end if;

  -- Ett par per (behov, kildeprofil). Bare relevante behov: et behov med
  -- uavklart relevans skal ikke sette i gang et søk — betingelsen avgjøres av
  -- svaret på en obligatorisk mal, og et søk før den er avgjort, ville vært
  -- arbeid på et spørsmål ingen ennå vet gjelder. Behovet forsvinner ikke: det
  -- står som uavklart i dekningen, og får sin plan når betingelsen er oppfylt
  -- (MONOGRAPH_STANDARD.md §5.1).
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

        -- Og sporene som må være forsøkt for nettopp denne profilen, som
        -- pending. Et spor ingen har forsøkt, skal være synlig framfor å
        -- mangle (SOURCE_POLICY.md §4.2).
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

  return v_created;
end;
$$;

comment on function workflow.build_monograph_search_plans(uuid) is
  'Bygger søkeplanene for én monografiutgave av de relevante behovene og kildeprofilene deres, og svarer med hvor mange nye planer som ble opprettet. Deterministisk og idempotent: gitt de samme behovene og profilene er plansettet alltid det samme, så funksjonen kan kjøres om igjen etter et avbrudd og etter at nye behov er opprettet, uten å doble noe. Behov med uavklart relevans får ingen plan — betingelsen avgjøres av svaret på en obligatorisk mal, og et søk før den er avgjort ville vært arbeid på et spørsmål ingen ennå vet gjelder — men de forsvinner ikke: de står som uavklarte i dekningen og får sin plan når betingelsen er oppfylt (MONOGRAPH_STANDARD.md §5.1). Oppretter samtidig de obligatoriske søkesporene som pending.';

revoke execute on function workflow.build_monograph_search_plans(uuid) from public;

-- Utvidelsen av dekningskartet bygger planene i den samme transaksjonen. Et
-- behov uten en søkeplan ville vært et spørsmål ingen kunne begynne å svare på.
create or replace function knowledge.expand_monograph_edition(p_edition_id uuid)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_edition knowledge.monograph_editions;
  v_before integer;
  v_after integer;
  v_template knowledge.monograph_question_templates;
  v_form knowledge.monograph_answer_form;
  v_prescribed knowledge.monograph_prescribed_scope_values;
  v_proposal workflow.monograph_term_proposals;
  v_primary knowledge.monograph_scope_axis;
  v_root_id uuid;
  v_relevance knowledge.monograph_relevance;
begin
  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.id = p_edition_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Monografiutgaven finnes ikke.';
  end if;

  if v_edition.superseded_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En avløst monografiutgave utvides ikke.',
      hint = 'Utgaven er historikk, og den er det en godkjent monografi ble bygget av. Nye behov hører til den gjeldende utgaven.';
  end if;

  select count(*) into v_before
  from knowledge.monograph_needs n where n.edition_id = p_edition_id;

  for v_template in
    select t.* from knowledge.monograph_question_templates t
    where t.standard_version = v_edition.standard_version
    order by t.ordinal
  loop
    v_relevance := knowledge.monograph_relevance_for_requirement(v_template.requirement);

    if exists (
      select 1 from knowledge.monograph_prescribed_scope_values v
      where v.template_id = v_template.id
    ) then
      foreach v_form in array v_template.answer_forms loop
        for v_prescribed in
          select v.* from knowledge.monograph_prescribed_scope_values v
          where v.template_id = v_template.id
          order by v.ordinal
        loop
          perform knowledge.ensure_monograph_need(
            p_edition_id, v_template.id, v_form,
            v_prescribed.axis, v_prescribed.label,
            null, null, null,
            v_relevance, null,
            format('Standarden navngir %L som et obligatorisk screeningsspørsmål under %s.',
                   v_prescribed.label, v_template.code));
        end loop;
      end loop;
      continue;
    end if;

    foreach v_form in array v_template.answer_forms loop
      v_root_id := knowledge.ensure_monograph_need(
        p_edition_id, v_template.id, v_form,
        null, null, null, null, null,
        v_relevance, null,
        format('%s er %L i monografistandard %s.',
               v_template.code, v_template.requirement_text, v_edition.standard_version));

      if cardinality(v_template.expansion_axes) > 0 then
        v_primary := v_template.expansion_axes[1];
        for v_proposal in
          select p.* from workflow.monograph_term_proposals p
          where p.edition_id = p_edition_id
            and p.axis = v_primary
            and p.state = 'accepted'
          order by p.created_at, p.label
        loop
          perform knowledge.ensure_monograph_need(
            p_edition_id, v_template.id, v_form,
            v_primary, v_proposal.label,
            v_proposal.concept_id, v_proposal.population_id, v_proposal.drug_id,
            'relevant'::knowledge.monograph_relevance,
            v_root_id,
            format('Aktivert av den aksepterte verdien %L på aksen %s: %s',
                   v_proposal.label, v_primary, v_proposal.rationale));
        end loop;
      end if;
    end loop;
  end loop;

  select count(*) into v_after
  from knowledge.monograph_needs n where n.edition_id = p_edition_id;

  -- Og søkeplanene, i den samme transaksjonen. Et behov uten en søkeplan ville
  -- vært et spørsmål ingen kunne begynne å svare på.
  perform workflow.build_monograph_search_plans(p_edition_id);

  return v_after - v_before;
end;
$$;

-- ----------------------------------------------------------------------------
-- 9. Aktørene og identitetene de to kildeleddene handler med
--
-- `source_discovery` og `source_quality_assessment` har stått i rollevokabularet
-- siden migrasjon 005 uten å ha en skrivevei. Her får de en aktør, en identitet
-- og en registreringstildeling — og identitetene er inerte til legitimasjonen
-- utstedes i det miljøet kjøreren skal lese hemmeligheten fra, samme grep og
-- samme begrunnelse som migrasjon 005f, 005w, 005ak og 005an.
--
-- Registreringstildelingen er Antideps egen deterministiske kode: den som
-- utfører maskinelle søk og skriver radene. Den semantiske tildelingen — den
-- eksterne KI-agenten som planlegger søk og velger kilder — registreres av en
-- redaktør med mandat når den tas i bruk, og er *ikke* en forutsetning for at
-- den maskinelle søkeveien virker.
-- ----------------------------------------------------------------------------

insert into provenance.actors (actor_type, actor_key, display_name, description, agent_role)
values
  ('agent', 'agent:source-discovery',
   'Antidep kildeoppdagelsesagent',
   'KI-assistert prosess i kildeoppdagelsesrollen (SOURCE_POLICY.md §4). Planlegger søk, utfører dem eller rapporterer utførte søk, identifiserer kandidatkilder og foreslår utvalgsbeslutninger — alt gjennom de kontrollerte skriveveiene i migrasjon 013e. Aktøren utfører ingen faglig vurdering av søkedekningen: den hører til kildekvalitetsrollen, og en dekning kontrollert av leddet som gjorde søket, ville ikke vært en kontroll (ANTIDEP_CONSTITUTION.md regel 3).',
   'source_discovery'),
  ('agent', 'agent:source-quality-assessment',
   'Antidep kildedekningskontroll',
   'KI-assistert prosess i kildekvalitetsrollen (SOURCE_POLICY.md §6). Gjør sine egne søk etter oversette og motstridende kilder, kontrollerer sentrale eksklusjoner, vurderer vesentligheten av uavklarte kilder, og godtar eller avviser begrunnelsen for å avslutte søket. Aktøren kan ikke selv registrere et søk som dekker et obligatorisk spor for generatoren: den kontrollerer dekningen, den produserer den ikke.',
   'source_quality_assessment');

insert into provenance.agent_identities (
  actor_id, agent_role, identity_key,
  registered_by_actor_id, registered_by_actor_type, registration_reason
)
select
  a.id, a.agent_role, v.identity_key,
  editor.id, 'human'::provenance.actor_type, v.reason
from (values
  ('agent:source-discovery', 'agent-identity:source-discovery-01',
   'Den tekniske identiteten kildeoppdagelsen handler med. Rollen er rettighetsgrensen: identiteten kan registrere søk, kandidatkilder og utvalgsbeslutninger for en søkeplan, og ingenting annet. Den kan ikke ekstrahere evidens, ikke formulere en påstand, ikke registrere en evidensvurdering, og ikke godta sin egen søkedekning — den siste kontrollen krever rollen source_quality_assessment. Legitimasjon er ikke utstedt: identiteten er inert til provenance.issue_agent_identity_credential(text, text) kalles i det miljøet kjøreren skal lese hemmeligheten fra (DATABASE_ARCHITECTURE.md §49).'),
  ('agent:source-quality-assessment', 'agent-identity:source-quality-assessment-01',
   'Den tekniske identiteten den separate kontrollen av søkedekningen handler med. Rollen er rettighetsgrensen: identiteten kan registrere sine egne motsøk og én dekningskontroll per planversjon, og ingenting annet. Legitimasjon er ikke utstedt; identiteten er inert til den utstedes.')
) as v(actor_key, identity_key, reason)
join provenance.actors a on a.actor_key = v.actor_key
cross join lateral (
  select id from provenance.actors where actor_key = 'human:peder-holman'
) editor;

do $$
begin
  if (select count(*) from provenance.agent_identities
      where identity_key in ('agent-identity:source-discovery-01',
                             'agent-identity:source-quality-assessment-01')) <> 2 then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kildeleddenes agentidentiteter ble ikke registrert.',
      hint = 'Registreringen forutsetter at aktørene over og human:peder-holman finnes. En tom krysskobling ville satt inn null rader uten å feile, og identitetene ville manglet uten at noe sa fra.';
  end if;
end;
$$;

insert into provenance.role_model_assignments
  (agent_role, capacity, provider, model, model_version, registered_by_actor_id, reason)
select v.agent_role::provenance.agent_role, 'registration'::provenance.model_capacity,
       'antidep', v.model, v.model_version, a.id, v.reason
from (values
  ('source_discovery', 'search-execution-and-registration', '1.0.0',
   'Registreringsleddet for kildeoppdagelsen. Antideps egen deterministiske kode: den utfører maskinelle søk mot navngitte offentlige søketjenester, og den registrerer både dem og de søkene en ekstern KI-agent rapporterer — med utførelsesbeviset holdt fra hverandre. Hvilken ekstern KI-agent som planlegger og velger, er en egen semantisk tildeling, og den maskinelle søkeveien virker uten den.'),
  ('source_quality_assessment', 'coverage-control-registration', '1.0.0',
   'Registreringsleddet for den separate kontrollen av søkedekningen. Egen modellidentitet, fordi kontrollen ikke skal kunne være det samme leddet som gjorde søket (ANTIDEP_CONSTITUTION.md regel 3).')
) as v(agent_role, model, model_version, reason)
cross join lateral (
  select id from provenance.actors where actor_key = 'human:peder-holman'
) a;

-- ----------------------------------------------------------------------------
-- 10. Skriveveiene
--
-- De er interne og kalles fra api-funksjonene og fra handoff-importen. Ingen
-- av dem autentiserer noe selv: kalleren har alltid fastslått hvem dette er.
-- ----------------------------------------------------------------------------

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
  p_actor_id uuid
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
    track_codes, agent_run_id, recorded_by_actor_id
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
    coalesce(p_track_codes, array[]::text[]), p_agent_run_id, p_actor_id
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

comment on function workflow.record_monograph_search(uuid, text, text, text, timestamptz, integer, integer, boolean, text, workflow.monograph_search_outcome, text, workflow.monograph_execution_evidence, text, text, text[], uuid, uuid) is
  'Registrerer ett faktisk utført søk på én søkeplan, og oppdaterer sporene søket dekket. Et søk som gikk, dekker sporet; et søk som ikke kunne gå, registrerer sporet som utilgjengelig med sin begrensning framfor som dekket — skillet mellom en begrensning og et resultat (SOURCE_POLICY.md §8.2). Sporkodene må være obligatoriske for planens kildeprofil, ellers kunne et søk erklært å dekke et spor planen aldri hadde. Et søk avvises etter at søkedekningen er erklært ferdig: det hører til en ny planversjon med sin egen dekningskontroll. Autentiserer ingenting selv og kalles fra innsiden av en api-funksjon eller handoff-importen som allerede har fastslått hvem kalleren er.';

revoke execute on function workflow.record_monograph_search(uuid, text, text, text, timestamptz, integer, integer, boolean, text, workflow.monograph_search_outcome, text, workflow.monograph_execution_evidence, text, text, text[], uuid, uuid) from public;

create function workflow.record_monograph_candidate_source(
  p_plan_id uuid,
  p_search_id uuid,
  p_identifier_kind text,
  p_identifier_value text,
  p_title text,
  p_authors_or_issuer text,
  p_publisher_or_journal text,
  p_publication_year integer,
  p_discovery_path text,
  p_access_limited boolean,
  p_access_limitation_note text,
  p_could_change_conclusion boolean,
  p_materiality_reason text,
  p_agent_run_id uuid,
  p_actor_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_id uuid;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen finnes ikke.';
  end if;

  insert into workflow.monograph_candidate_sources (
    edition_id, plan_id, search_id,
    identifier_kind, identifier_value, title,
    authors_or_issuer, publisher_or_journal, publication_year,
    discovery_path, access_limited, access_limitation_note,
    could_change_conclusion, materiality_reason,
    proposed_by_agent_run_id, recorded_by_actor_id
  )
  values (
    v_plan.edition_id, p_plan_id, p_search_id,
    p_identifier_kind, btrim(p_identifier_value), btrim(p_title),
    nullif(btrim(coalesce(p_authors_or_issuer, '')), ''),
    nullif(btrim(coalesce(p_publisher_or_journal, '')), ''),
    p_publication_year,
    btrim(p_discovery_path),
    coalesce(p_access_limited, false),
    nullif(btrim(coalesce(p_access_limitation_note, '')), ''),
    coalesce(p_could_change_conclusion, false),
    nullif(btrim(coalesce(p_materiality_reason, '')), ''),
    p_agent_run_id, p_actor_id
  )
  on conflict (edition_id, identifier_kind, identifier_value) do nothing
  returning id into v_id;

  if v_id is null then
    -- Den samme kilden funnet av to søk er én kandidat. Oppdagelsesveien til
    -- den første beholdes: det var den som faktisk fant den.
    select c.id into v_id
    from workflow.monograph_candidate_sources c
    where c.edition_id = v_plan.edition_id
      and c.identifier_kind = p_identifier_kind
      and c.identifier_value = btrim(p_identifier_value);
  end if;

  return v_id;
end;
$$;

comment on function workflow.record_monograph_candidate_source(uuid, uuid, text, text, text, text, text, integer, text, boolean, text, boolean, text, uuid, uuid) is
  'Registrerer én identifisert kandidatkilde med bibliografi, oppdagelsesvei, eventuell tilgangsbegrensning og eventuell vesentlighet. Idempotent på (utgave, identifikatorform, identifikator): den samme kilden funnet av to søk er én kandidat, og oppdagelsesveien til det første søket beholdes fordi det var det som faktisk fant den.';

revoke execute on function workflow.record_monograph_candidate_source(uuid, uuid, text, text, text, text, text, integer, text, boolean, text, boolean, text, uuid, uuid) from public;

create function workflow.decide_monograph_candidate_source(
  p_candidate_id uuid,
  p_decision workflow.monograph_candidate_decision,
  p_reason text,
  p_actor_id uuid,
  p_agent_run_id uuid
)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_candidate workflow.monograph_candidate_sources;
begin
  select c.* into v_candidate
  from workflow.monograph_candidate_sources c
  where c.id = p_candidate_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kandidatkilden finnes ikke.';
  end if;

  -- En tilgangsbegrenset kilde kan ikke ekskluderes. Regelen står også på
  -- raden; her sies den med en setning et menneske kan lese, framfor med en
  -- beskrankningsnavn.
  if p_decision = 'excluded' and v_candidate.access_limited then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En kilde med registrert tilgangsbegrensning kan ikke ekskluderes.',
      hint = 'En betalingsmur er en tilgangsbegrensning og ikke en faglig eksklusjonsgrunn (SOURCE_POLICY.md §5). Kilden hører under «avventer tilgang» til grunnlaget er hentet eller en faglig grunn faktisk finnes.';
  end if;

  update workflow.monograph_candidate_sources
  set decision = p_decision,
      decision_reason = nullif(btrim(coalesce(p_reason, '')), ''),
      decided_by_actor_id = p_actor_id,
      decided_by_agent_run_id = p_agent_run_id,
      decided_at = now()
  where id = p_candidate_id;
end;
$$;

comment on function workflow.decide_monograph_candidate_source(uuid, workflow.monograph_candidate_decision, text, uuid, uuid) is
  'Registrerer utvalgsbeslutningen om én kandidatkilde med sin begrunnelse og sitt opphav. Avviser en eksklusjon av en kilde med registrert tilgangsbegrensning: en betalingsmur er en tilgangsbegrensning og ikke en faglig eksklusjonsgrunn (SOURCE_POLICY.md §5).';

revoke execute on function workflow.decide_monograph_candidate_source(uuid, workflow.monograph_candidate_decision, text, uuid, uuid) from public;

create function workflow.record_monograph_coverage_control(
  p_plan_id uuid,
  p_outcome workflow.monograph_coverage_outcome,
  p_note text,
  p_searched_independently boolean,
  p_missed_candidates integer,
  p_exclusions_checked integer,
  p_materiality_assessed boolean,
  p_agent_run_id uuid,
  p_actor_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_discovery provenance.role_model_assignments;
  v_control provenance.role_model_assignments;
  v_id uuid;
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

  -- Kontrollen skal ikke kunne utføres av den samme modellen som gjorde søket.
  -- To navn på den samme modellen er ikke to uavhengige modeller
  -- (ANTIDEP_CONSTITUTION.md regel 3). Kontrollen står her og ikke bare på
  -- raden, fordi den gjelder to *tildelinger* og ikke to kolonner.
  v_discovery := provenance.current_semantic_model('source_discovery');
  v_control := provenance.current_semantic_model('source_quality_assessment');
  if v_discovery.id is not null and v_control.id is not null
     and v_discovery.provider = v_control.provider
     and v_discovery.model = v_control.model
     and v_discovery.model_version = v_control.model_version then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Kontrollen av søkedekningen er tildelt den samme modellen som kildeoppdagelsen.',
      hint = 'En dekning kontrollert av leddet som gjorde søket, er ikke en kontroll. Finnes ingen uavhengig modell, stopper kjeden framfor å registrere en kontroll som ikke er uavhengig (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  insert into workflow.monograph_coverage_controls (
    plan_id, plan_version, outcome, note,
    searched_independently, missed_candidates, exclusions_checked,
    materiality_assessed, agent_run_id, recorded_by_actor_id
  )
  values (
    p_plan_id, v_plan.plan_version, p_outcome, btrim(p_note),
    coalesce(p_searched_independently, false),
    coalesce(p_missed_candidates, 0), coalesce(p_exclusions_checked, 0),
    coalesce(p_materiality_assessed, false), p_agent_run_id, p_actor_id
  )
  on conflict (plan_id, plan_version) do nothing
  returning id into v_id;

  if v_id is null then
    raise exception using
      errcode = 'unique_violation',
      message = 'Denne planversjonen har allerede en dekningskontroll.',
      hint = 'Én kontroll per planversjon. Skal dekningen kontrolleres på nytt, er planen blitt en annen, og det er en ny planversjon.';
  end if;

  return v_id;
end;
$$;

comment on function workflow.record_monograph_coverage_control(uuid, workflow.monograph_coverage_outcome, text, boolean, integer, integer, boolean, uuid, uuid) is
  'Registrerer den separate kontrollen av søkedekningen for én planversjon. Avviser en kontroll tildelt den samme eksterne modellen som kildeoppdagelsen: en dekning kontrollert av leddet som gjorde søket, er ikke en kontroll, og to navn på den samme modellen er ikke to uavhengige modeller (ANTIDEP_CONSTITUTION.md regel 3). Én kontroll per planversjon; skal dekningen kontrolleres på nytt, er planen blitt en annen.';

revoke execute on function workflow.record_monograph_coverage_control(uuid, workflow.monograph_coverage_outcome, text, boolean, integer, integer, boolean, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 11. Den maskinelt utførte søkeveien
--
-- Dette er den veien som gjør kildeoppdagelsen til noe annet enn et rollenavn i
-- en prompt: Antideps egen kjører henter de åpne søkeplanene, kaller navngitte
-- offentlige søketjenester, og registrerer treffene med endepunktet og
-- responsavtrykket som bevis. Ingen ekstern modell er en forutsetning, og ingen
-- modellnøkkel finnes.
--
-- Veien er smal med vilje: identiteten må være kildeoppdagelsens egen, og den
-- må ha en åpen kjøring som tilhører den. En lesning eller en registrering skal
-- etterlate seg en proveniensrad og ikke bare et vellykket kall.
-- ----------------------------------------------------------------------------

create function api.monograph_discovery_work(p_identity_key text, p_secret text)
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

  select coalesce(jsonb_agg(x.payload order by x.created_at), '[]'::jsonb) into v_rows
  from (
    select p.created_at, jsonb_build_object(
      'plan_reference', p.reference,
      'plan_version', p.plan_version,
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
        select count(*) from workflow.monograph_candidate_sources c
        where c.plan_id = p.id),
      -- Kriteriene for å avslutte, som én setning om hva som mangler. Oppgaven
      -- bærer stoppkravene og ikke et forventet svar (SOURCE_POLICY.md §8.1).
      'closure_problem', workflow.monograph_search_closure_problem(p.id)
    ) as payload
    from workflow.monograph_search_plans p
    join knowledge.monograph_editions e on e.id = p.edition_id
    join catalog.drugs d on d.id = e.drug_id
    join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
    where p.closed_at is null
      and p.paused_at is null
      and e.superseded_at is null
    order by p.created_at
    limit 25
  ) x;

  return jsonb_build_object(
    'identity_key', v_identity.identity_key,
    'agent_role', v_identity.agent_role::text,
    'plans', v_rows);
end;
$$;

comment on function api.monograph_discovery_work(text, text) is
  'De åpne søkeplanene kildeleddene skal arbeide med: avgrensningen, kildeprofilen med sitt første kildevalg og sine særskilte kontroller, de kunnskapsbehovene planen dekker med spørsmålene ordrett, de obligatoriske søkesporene med tilstanden sin, søkene som er gjort, og én setning om hva som hindrer at søkedekningen kan erklæres ferdig. Oppgaven bærer stoppkravene og ikke et forventet klinisk svar: standarden definerer spørsmål, ikke svar (MONOGRAPH_STANDARD.md §1, SOURCE_POLICY.md §4.1, §8.1). Krever kildeoppdagelsens eller dekningskontrollens egen identitet og legitimasjon. SECURITY DEFINER fordi knowledge, workflow og catalog har RLS med default deny.';

revoke execute on function api.monograph_discovery_work(text, text) from public;
grant execute on function api.monograph_discovery_work(text, text) to anon, authenticated;

create function api.record_monograph_machine_search(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_plan_reference text,
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
  p_candidates jsonb
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
  v_outcome workflow.monograph_search_outcome;
  v_search_id uuid;
  v_candidate jsonb;
  v_unknown text;
  v_recorded integer := 0;
  v_candidate_id uuid;
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
    p_track_codes, p_agent_run_id,
    (select r.actor_id from provenance.agent_runs r where r.id = p_agent_run_id));

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
    'recorded', true,
    'outcome', v_outcome::text,
    'execution_evidence', 'machine_executed',
    'candidates_recorded', v_recorded,
    'closure_problem', workflow.monograph_search_closure_problem(v_plan.id));
end;
$$;

comment on function api.record_monograph_machine_search(text, text, uuid, text, text, text, text, text, text, text, integer, integer, boolean, text, text, text[], jsonb) is
  'Registrerer ett søk Antidep faktisk utførte selv, med endepunktet og responsavtrykket som utførelsesbevis, og kandidatkildene det ga. Dette er veien som gjør kildeoppdagelsen til en utført operasjon framfor til en rapportert: utførelsesbeviset settes av funksjonen og kan ikke oppgis av en kaller, så et agentsvar kan ikke gi seg ut for å være maskinelt bekreftet (SOURCE_POLICY.md §4.3). Krever kildeleddets egen identitet, legitimasjon og en åpen kjøring som tilhører den — en registrering skal etterlate seg en proveniensrad og ikke bare et vellykket kall. Ingen ekstern modell er en forutsetning, og ingen modellnøkkel finnes.';

revoke execute on function api.record_monograph_machine_search(text, text, uuid, text, text, text, text, text, text, text, integer, integer, boolean, text, text, text[], jsonb) from public;
grant execute on function api.record_monograph_machine_search(text, text, uuid, text, text, text, text, text, text, text, integer, integer, boolean, text, text, text[], jsonb) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 12. Redaktørens lesevei og de tre handlingene
--
-- Lesing av søkeloggen er redaksjonelt arbeid: å se hvor det ble søkt, med hva,
-- hvor mye som ble gjennomgått, og hva som ble valgt bort og hvorfor, er
-- nettopp den kontrollen kildepolitikken ber om at et menneske skal kunne
-- gjøre. Ingen intern id forlater databasen.
-- ----------------------------------------------------------------------------

create function workflow.monograph_search_plan_payload(p_plan workflow.monograph_search_plans)
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
               'decision', c.decision::text,
               'decision_reason', c.decision_reason,
               'access_limited', c.access_limited,
               'access_limitation_note', c.access_limitation_note,
               'could_change_conclusion', c.could_change_conclusion,
               'materiality_reason', c.materiality_reason,
               'registered', c.source_id is not null,
               'uses', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'template', t.code, 'proposed_use', cn.proposed_use)
                          order by t.ordinal), '[]'::jsonb)
                 from workflow.monograph_candidate_source_needs cn
                 join knowledge.monograph_needs n on n.id = cn.need_id
                 join knowledge.monograph_question_templates t on t.id = n.template_id
                 where cn.candidate_source_id = c.id))
             order by c.created_at), '[]'::jsonb)
      from workflow.monograph_candidate_sources c where c.plan_id = p_plan.id),
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

comment on function workflow.monograph_search_plan_payload(workflow.monograph_search_plans) is
  'Hele søkeplanen slik en fagperson skal kunne lese den: avgrensningen, behovene, de obligatoriske sporene med tilstanden sin, den dokumenterte søkeloggen med plattform, streng, filtre, tidspunkt, treffantall, gjennomgått omfang, avkorting og utførelsesbevis, kandidatkildene med sine mulige bruksområder og utvalgsbeslutninger, den separate dekningskontrollen, og én setning om hva som hindrer at dekningen kan erklæres ferdig. Ingen intern id er med.';

revoke execute on function workflow.monograph_search_plan_payload(workflow.monograph_search_plans) from public;

create function api.monograph_search_plans(p_edition_reference text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_edition_id uuid;
  v_rows jsonb;
begin
  perform knowledge.assert_editor_authorized();

  select e.id into v_edition_id
  from knowledge.monograph_editions e where e.reference = p_edition_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografiutgave med denne referansen.';
  end if;

  select coalesce(jsonb_agg(workflow.monograph_search_plan_payload(p)
                            order by p.created_at), '[]'::jsonb)
    into v_rows
  from workflow.monograph_search_plans p
  where p.edition_id = v_edition_id;

  return v_rows;
end;
$$;

comment on function api.monograph_search_plans(text) is
  'Søkeplanene for én monografiutgave med hele den dokumenterte søkeloggen, kandidatkildene, utvalgsbeslutningene og dekningskontrollen. Krever editor-mandat: å lese hvor det ble søkt, hvor mye som ble gjennomgått, og hva som ble valgt bort og hvorfor, er den redaksjonelle kontrollen kildepolitikken ber om (SOURCE_POLICY.md §4.3, §10).';

revoke execute on function api.monograph_search_plans(text) from public;
grant execute on function api.monograph_search_plans(text) to authenticated;

create function api.close_monograph_search_plan(p_plan_reference text, p_note text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_plan workflow.monograph_search_plans;
  v_problem text;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.reference = p_plan_reference
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen finnes ikke.';
  end if;

  if v_plan.closed_at is not null then
    return jsonb_build_object(
      'reference', v_plan.reference, 'closed', false, 'already_closed', true,
      'closed_at', v_plan.closed_at);
  end if;

  if p_note is null or btrim(p_note) = '' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En erklært ferdig søkedekning krever en begrunnelse.';
  end if;

  -- Porten. Den kan ikke overstyres, og den er den samme enten en redaktør
  -- eller kjeden erklærer dekningen ferdig.
  v_problem := workflow.monograph_search_closure_problem(v_plan.id);
  if v_problem is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = v_problem,
      hint = 'Søkedekningen kan ikke erklæres ferdig før stoppkravene i SOURCE_POLICY.md §8.1 er oppfylt. Verken tre funne artikler, to enige agenter, ti gjennomgåtte treff eller et oppbrukt arbeidsbudsjett er et av dem.';
  end if;

  update workflow.monograph_search_plans
  set closed_at = now(), closed_note = btrim(p_note), closed_by_actor_id = v_actor_id
  where id = v_plan.id;

  -- Behovene planen dekker, er nå ferdig søkt. Arbeidstilstanden går videre til
  -- kildevurdering; det faglige utfallet avgjøres et annet sted.
  update knowledge.monograph_needs n
  set work_state = 'appraising_sources', work_state_note = null
  where n.id in (
    select pn.need_id from workflow.monograph_search_plan_needs pn
    where pn.plan_id = v_plan.id)
    and n.relevance = 'relevant'
    and n.work_state in ('not_started', 'searching');

  return jsonb_build_object(
    'reference', v_plan.reference, 'closed', true, 'already_closed', false,
    'closed_at', now());
end;
$$;

comment on function api.close_monograph_search_plan(text, text) is
  'Erklærer søkedekningen for én plan ferdig, etter at stoppkravene i SOURCE_POLICY.md §8.1 er oppfylt. Porten er workflow.monograph_search_closure_problem(uuid) og kan ikke overstyres: hvert obligatorisk søkespor må være forsøkt og dokumentert, minst ett søk må faktisk ha gått, ingen avkortet treffliste kan stå igjen udekket, ingen uavklart kilde som kan endre hovedkonklusjonen kan stå åpen, metningssignalet må være gitt, og den separate dekningskontrollen må godta begrunnelsen. Krever editor-mandat og en begrunnelse. Idempotent: en plan som allerede er erklært ferdig, svarer med det som ble registrert.';

revoke execute on function api.close_monograph_search_plan(text, text) from public;
grant execute on function api.close_monograph_search_plan(text, text) to authenticated;

create function api.pause_monograph_search_plan(p_plan_reference text, p_reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
begin
  perform knowledge.assert_editor_authorized();

  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.reference = p_plan_reference
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen finnes ikke.';
  end if;

  if v_plan.closed_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En erklært ferdig søkedekning kan ikke settes på pause.';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En pause krever en grunn.',
      hint = 'Grunnen er det som gjør pausen til en åpen, ventende tilstand framfor til en konklusjon om evidensen (SOURCE_POLICY.md §8.2).';
  end if;

  update workflow.monograph_search_plans
  set paused_at = now(), paused_reason = btrim(p_reason)
  where id = v_plan.id;

  return jsonb_build_object(
    'reference', v_plan.reference, 'paused', true, 'paused_reason', btrim(p_reason));
end;
$$;

comment on function api.pause_monograph_search_plan(text, text) is
  'Setter én søkeplan på pause med en grunn: oppbrukt tid, oppbrukt modellkvote, en utilgjengelig database eller en verktøyfeil. En pause er åpent, ventende arbeid og aldri en konklusjon om evidensen — den kan ikke settes på en plan som allerede er erklært ferdig, og den gjør ikke dekningen ferdig (SOURCE_POLICY.md §8.2). Krever editor-mandat.';

revoke execute on function api.pause_monograph_search_plan(text, text) from public;
grant execute on function api.pause_monograph_search_plan(text, text) to authenticated;

create function api.resume_monograph_search_plan(p_plan_reference text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
begin
  perform knowledge.assert_editor_authorized();

  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.reference = p_plan_reference
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen finnes ikke.';
  end if;

  update workflow.monograph_search_plans
  set paused_at = null, paused_reason = null
  where id = v_plan.id;

  return jsonb_build_object('reference', v_plan.reference, 'resumed', true);
end;
$$;

comment on function api.resume_monograph_search_plan(text) is
  'Tar én søkeplan ut av pause. Arbeidet fortsetter der det sto: søkeloggen, sporene og kandidatkildene er uendret, og ingenting må gjøres om igjen (SOURCE_POLICY.md §8.2).';

revoke execute on function api.resume_monograph_search_plan(text) from public;
grant execute on function api.resume_monograph_search_plan(text) to authenticated;

create function api.decide_monograph_candidate(
  p_candidate_reference text,
  p_decision text,
  p_reason text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_candidate workflow.monograph_candidate_sources;
  v_decision workflow.monograph_candidate_decision;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  select c.* into v_candidate
  from workflow.monograph_candidate_sources c
  where c.reference = p_candidate_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kandidatkilden finnes ikke.';
  end if;

  begin
    v_decision := p_decision::workflow.monograph_candidate_decision;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en utvalgsbeslutning.', p_decision);
  end;

  perform workflow.decide_monograph_candidate_source(
    v_candidate.id, v_decision, p_reason, v_actor_id, null);

  return jsonb_build_object(
    'reference', v_candidate.reference,
    'decision', v_decision::text,
    'title', v_candidate.title);
end;
$$;

comment on function api.decide_monograph_candidate(text, text, text) is
  'En redaktørs utvalgsbeslutning om én kandidatkilde: velg den til innhenting, inkluder den for en navngitt bruk, ekskluder den med en faglig grunn, eller sett den som avventer tilgang eller avklaring. En kilde med registrert tilgangsbegrensning kan ikke ekskluderes. Krever editor-mandat.';

revoke execute on function api.decide_monograph_candidate(text, text, text) from public;
grant execute on function api.decide_monograph_candidate(text, text, text) to authenticated;
