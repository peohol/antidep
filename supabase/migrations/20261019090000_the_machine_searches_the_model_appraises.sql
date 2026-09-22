-- ============================================================================
-- Migrasjon 013v — den maskinelle søkefasen kommer først, og modellen vurderer
--                  det maskinen faktisk hentet
--
-- Dette er ikke en promptrettelse. Det er en selvmotsigelse i arkitekturen, og
-- den ble synlig første gang en autonom Workspace Agent kom helt fram til en
-- `source_discovery`-oppgave:
--
--   «Den første oppgaven krever faktiske databasesøk, men oppgaveteksten og
--    kjørereglene tillater ingen verktøy utenfor Antidep. Jeg frigir derfor
--    oppgaven med korrekt årsak i stedet for å dikte opp søk eller kilder.»
--
-- Agenten gjorde det eneste riktige. Motsigelsen var Antideps:
--
--   * `docs/CHATGPT_WORKSPACE_AGENT.md` sier at agenten bare bruker Antideps
--     fem verktøy og ikke søker på nettet.
--   * Oppgaveteksten ba den likevel om å *utføre* søk og bare rapportere søk
--     den selv hadde gjennomført.
--   * `AGENTS.md` og `docs/MONOGRAPH_PHASE_D_HANDOVER.md` sier samtidig at
--     selve søkeutførelsen er Antideps deterministiske kode, og at modellens
--     oppgave er den semantiske: planlegging, utvalg og vurdering.
--
-- Den deterministiske søkeveien fantes allerede (`npm run ops:discovery`,
-- `api.record_monograph_machine_search`). Det som manglet, var at den kom
-- *først* — og at den semantiske oppgaven ba om det modellen faktisk kan gjøre
-- uten nettilgang.
--
-- ----------------------------------------------------------------------------
-- Arbeidsdelingen denne migrasjonen gjør til én ting
--
--   Antideps kode          utfører søkene, mot navngitte offentlige tjenester,
--                          og registrerer endepunkt, søkestreng, treffantall og
--                          responsavtrykk (`machine_executed`).
--   Den semantiske agenten leser de maskinelt registrerte søkene og kandidatene,
--                          vurderer hva som er relevant og til hva, og ber om
--                          flere eller mer målrettede søk som *strukturerte
--                          søkeforespørsler*.
--   Antideps kode          utfører forespørslene, registrerer dem, og først da
--                          får agenten neste vurderingsrunde.
--
-- Modellen rapporterer ikke lenger søk. Den *kan* ikke: `searches` er fjernet
-- fra begge svarformene, og et svar som fortsatt bærer feltet, avvises med en
-- setning som sier hvorfor. Skillet mellom `agent_reported` og
-- `machine_executed` står uendret i `workflow.monograph_searches` — det er bare
-- ikke lenger en vei inn for den første fra de to kildeleddene.
--
-- ----------------------------------------------------------------------------
-- Rekkefølgen, og hvorfor den er en port og ikke en tidsplan
--
-- En semantisk oppgave kan ikke hentes ut før den maskinelle søkefasen for
-- nettopp den planversjonen og nettopp den runden er gjort. Porten er
-- `workflow.monograph_search_phase_problem(uuid, provenance.agent_role)`, og
-- den leses av kjedeovergangen, av forhåndskontrollen og av uttaket — de samme
-- tre stedene som alle andre oppgavevilkår.
--
-- En utilgjengelig søketjeneste låser ingenting. Et søk som ikke kom fram, er
-- `unavailable` med sin begrensning; forespørselen står da som utilgjengelig og
-- *slipper* den semantiske oppgaven videre, med den ærlige begrensningen
-- synlig. Den prøves samtidig på nytt av neste planlagte kjøring, opp til tre
-- ganger. Deadlock ville vært å vente på et svar som aldri kommer; det gjør
-- ingen her (SOURCE_POLICY.md §8.2).
--
-- ----------------------------------------------------------------------------
-- Dekningskontrollen får sin egen maskinelle motsøkerunde
--
-- Kontrollen hadde den samme motsigelsen: den ble bedt om egne motsøk mens den
-- bare hadde Antideps fem verktøy. Nå åpner et registrert søkesvar en *egen*
-- maskinell motsøkerunde under kontrollens egen identitet og kjøring, med en
-- annen søkestrategi enn generatorens — målrettet per akse framfor bredt.
-- `searched_independently` settes ikke lenger av svaret: den utledes av at det
-- faktisk finnes maskinelt utførte søk registrert av kontrollrollens egen
-- kjøring. En erklæring kan ikke lenger bestås ved å skrive den.
--
-- Kontrollens motsøk kan ikke dekke generatorens obligatoriske søkespor. Det
-- ville gjort kontrollen til produsenten av den dekningen den kontrollerer.
--
-- ----------------------------------------------------------------------------
-- De oppgavene som allerede står ute
--
-- De hører til den gamle kontrakten, og de blir foreldet framfor å bli forsøkt
-- migrert: manifestet deres mangler runden, og forhåndskontrollen avviser det
-- med en setning som sier hvorfor. Jobbraden blir stående som historikk — den
-- er append-only, og skal være det — men den er ikke lenger utførbar, og den
-- vises ikke i køen. For hver åpne plan åpnes i stedet en maskinell søkefase,
-- og den nye oppgaven legges inn når fasen er gjort.
--
-- Styrende dokumenter: docs/SOURCE_POLICY.md §4.2, §4.3, §6, §8,
-- docs/ANTIDEP_CONSTITUTION.md regel 3, 4, 7, AGENTS.md.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Vokabularene søkeforespørselen trenger
-- ----------------------------------------------------------------------------

create type workflow.monograph_search_request_origin as enum (
  'plan_opened',
  'agent_requested',
  'control_opened'
);

revoke usage on type workflow.monograph_search_request_origin from public;

comment on type workflow.monograph_search_request_origin is
  'Hvem som ba om denne maskinelle søkerunden: plan_opened (den nye søkeplanens egen første runde), agent_requested (kildeoppdagelsen eller dekningskontrollen ba om flere eller mer målrettede søk i svaret sitt) eller control_opened (den separate dekningskontrollens egen motsøkerunde, åpnet av et registrert søkesvar). Opphavet er proveniens og ikke en rettighet: hvem som ba, avgjør ingenting om hva søket får lov til.';

create type workflow.monograph_search_request_state as enum (
  'pending',
  'fulfilled',
  'unavailable',
  'abandoned'
);

revoke usage on type workflow.monograph_search_request_state from public;

comment on type workflow.monograph_search_request_state is
  'Hvor langt én maskinell søkeforespørsel er kommet: pending (ikke utført ennå — den ene tilstanden som holder den semantiske oppgaven tilbake), fulfilled (minst ett søk gikk faktisk), unavailable (hvert forsøk møtte en søkevei som ikke svarte; forespørselen prøves på nytt, men den holder ingenting tilbake) og abandoned (forsøkene er brukt opp, og begrensningen står). Skillet mellom fulfilled og unavailable er det samme som mellom et resultat og en begrensning (SOURCE_POLICY.md §8.2).';

create type workflow.monograph_search_strategy as enum (
  'broad',
  'targeted'
);

revoke usage on type workflow.monograph_search_strategy from public;

comment on type workflow.monograph_search_strategy is
  'Hvilken form den maskinelle søkerunden har: broad er det brede orienterende søket der avgrensningsaksene står som ELLER-ledd, targeted er én passering per akse eller per bedt om term. Kildepolitikken krever begge deler (SOURCE_POLICY.md §4.1), og dekningskontrollens motsøk er alltid targeted — et motsøk som gjentok generatorens egen streng, ville ikke lett etter det generatoren overså (§6).';

-- ----------------------------------------------------------------------------
-- 2. Runden planen står i
--
-- To tellere og ikke én: kildeoppdagelsen og dekningskontrollen ber om sine
-- egne søkerunder, og de går ikke i takt. Runden inngår i oppgavens manifest og
-- i jobbnøkkelen, slik at runde to faktisk blir en ny oppgave — uten den ville
-- `workflow.chain_enqueue_job(...)` sett nøkkelen fra runde én og svart at
-- arbeidet fantes fra før.
-- ----------------------------------------------------------------------------

alter table workflow.monograph_search_plans
  add column discovery_round integer not null default 1,
  add column control_round integer not null default 1,
  add constraint monograph_search_plans_discovery_round_check
    check (discovery_round between 1 and 4),
  add constraint monograph_search_plans_control_round_check
    check (control_round between 1 and 4);

comment on column workflow.monograph_search_plans.discovery_round is
  'Hvilken maskinell søkerunde kildeoppdagelsen står i for denne planversjonen. Økes når det semantiske leddet ber om flere eller mer målrettede søk, og taket på fire er der fordi en runde til alltid ser billigere ut enn en avgjørelse: når det er brukt opp, skal leddet vurdere det grunnlaget som faktisk er hentet, og si hva som mangler (SOURCE_POLICY.md §8.2).';
comment on column workflow.monograph_search_plans.control_round is
  'Hvilken maskinell motsøkerunde den separate dekningskontrollen står i for denne planversjonen. Egen teller, fordi kontrollens søk er kontrollens egne og ikke en fortsettelse av generatorens.';

-- ----------------------------------------------------------------------------
-- 3. Selve søkeforespørselen
--
-- Den er *ikke* et søk. Den er bestillingen av et søk, og den kan bare bestille
-- de tingene Antideps egen kode faktisk gjør: en navngitt offentlig plattform
-- av de tre som finnes, en strategi, og noen termer. En adresse kan ikke
-- oppgis. Uten den grensen ville en agent kunnet styre Antideps kjører mot en
-- tjeneste ingen har vurdert — og det er ikke en søkeforespørsel, det er en
-- proxy.
-- ----------------------------------------------------------------------------

-- Formen en term må ha, som en funksjon fordi en CHECK ikke kan inneholde en
-- delspørring. Termene havner i en søkestreng Antideps egen kode bygger, og en
-- term uten grenser er ikke en term — den er et inndatafelt.
create function workflow.monograph_search_terms_shaped(p_terms text[])
  returns boolean
  language sql
  immutable
  set search_path = ''
as $$
  select p_terms is not null
     and cardinality(p_terms) <= 8
     and not exists (
       select 1
       from unnest(p_terms) as t(value)
       where t.value is null
          or t.value <> btrim(t.value)
          or length(t.value) not between 2 and 120
          or t.value ~ '[\n\r"]'
     );
$$;

comment on function workflow.monograph_search_terms_shaped(text[]) is
  'Om en liste med søketermer har formen en søkeforespørsel kan bære: høyst åtte, hver på 2 til 120 tegn, uten linjeskift og uten anførselstegn. Egen funksjon fordi en CHECK ikke kan inneholde en delspørring, og grensen hører til raden og ikke til kjøreren: det er raden som må kunne si nei.';

revoke execute on function workflow.monograph_search_terms_shaped(text[]) from public;

create table workflow.monograph_search_requests (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  plan_id uuid not null
    references workflow.monograph_search_plans (id) on update restrict on delete restrict,
  plan_version integer not null,
  requested_for_role provenance.agent_role not null,
  search_round integer not null,

  origin workflow.monograph_search_request_origin not null,
  strategy workflow.monograph_search_strategy not null,
  -- Hvorfor runden ble bedt om. Fra det semantiske leddet er dette dens egen
  -- begrunnelse; fra planen og fra kontrollåpningen er det Antideps egen.
  rationale text not null,
  -- Plattformen forespørselen gjelder, når den gjelder én bestemt. NULL er
  -- «alle tre», og en verdi må være en av de tre Antidep faktisk kaller.
  platform text,
  -- Termene som legges til avgrensningen. Fri tekst, men bundet i form og
  -- antall: de havner i en søkestreng, og en streng uten grenser er ikke en
  -- term, den er et inndatafelt.
  query_terms text[] not null default array[]::text[],
  filters_note text,
  -- Sporene runden kan erklære å dekke. Kontrollens motsøk har alltid ingen:
  -- et motsøk som dekket generatorens obligatoriske spor, ville produsert den
  -- dekningen det kontrollerer (SOURCE_POLICY.md §4.2, §6).
  track_codes text[] not null default array[]::text[],

  state workflow.monograph_search_request_state not null default 'pending',
  attempts integer not null default 0,
  last_attempt_at timestamptz,
  completed_at timestamptz,
  outcome_note text,

  requested_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  requested_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint monograph_search_requests_reference_key unique (reference),
  constraint monograph_search_requests_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$'),
  constraint monograph_search_requests_version_check check (plan_version >= 1),
  constraint monograph_search_requests_round_check check (search_round between 1 and 4),
  constraint monograph_search_requests_attempts_check check (attempts between 0 and 3),
  constraint monograph_search_requests_role_check
    check (requested_for_role in ('source_discovery'::provenance.agent_role,
                                  'source_quality_assessment'::provenance.agent_role)),
  constraint monograph_search_requests_rationale_shape_check
    check (rationale = btrim(rationale) and length(rationale) between 1 and 2000),
  -- Den ene listen over plattformer Antideps kode faktisk kaller. Den står her
  -- og ikke bare i kjøreren, fordi det er raden som må kunne si nei til en
  -- plattform ingen har vurdert.
  constraint monograph_search_requests_platform_check
    check (platform is null or platform in ('Europe PMC', 'PubMed', 'Crossref')),
  constraint monograph_search_requests_terms_shape_check
    check (workflow.monograph_search_terms_shaped(query_terms)),
  constraint monograph_search_requests_filters_note_shape_check
    check (filters_note is null
           or (filters_note = btrim(filters_note)
               and length(filters_note) between 1 and 500)),
  constraint monograph_search_requests_outcome_note_shape_check
    check (outcome_note is null
           or (outcome_note = btrim(outcome_note)
               and length(outcome_note) between 1 and 2000)),
  constraint monograph_search_requests_control_has_no_tracks_check
    check (requested_for_role <> 'source_quality_assessment'::provenance.agent_role
           or cardinality(track_codes) = 0),
  constraint monograph_search_requests_state_shape_check
    check (
      case state
        when 'pending' then completed_at is null
        when 'fulfilled' then completed_at is not null and attempts >= 1
        when 'unavailable' then completed_at is null and attempts >= 1
                                 and outcome_note is not null
        when 'abandoned' then completed_at is not null and attempts >= 1
                              and outcome_note is not null
        else false
      end
    ),
  -- Én åpen forespørsel per (plan, versjon, rolle, runde, strategi, plattform).
  -- Uten den ville to overganger om det samme kunnet åpne to runder, og
  -- kjøringen ville søkt det samme to ganger og kalt det to passeringer.
  constraint monograph_search_requests_round_key
    unique nulls not distinct
      (plan_id, plan_version, requested_for_role, search_round, strategy, platform)
);

comment on table workflow.monograph_search_requests is
  'Én bestilling av en maskinell søkerunde på én søkeplanversjon: hvem den er for, hvilken runde, hvilken strategi, hvilke termer og hvilke obligatoriske spor den kan erklære. Dette er leddet som gjør arbeidsdelingen til noe annet enn en formulering i en prompt — den semantiske agenten ber om søk her, Antideps deterministiske kode utfører dem, og først når runden er gjort, får agenten neste vurderingsrunde. En forespørsel kan ikke oppgi en adresse: plattformen må være en av de tre Antidep faktisk kaller, og uten den grensen ville en agent kunnet styre kjøringen mot en tjeneste ingen har vurdert (ANTIDEP_CONSTITUTION.md regel 7). En pending forespørsel er det eneste som holder den semantiske oppgaven tilbake; en utilgjengelig søketjeneste gir unavailable, som prøves på nytt og likevel slipper oppgaven videre med begrensningen synlig (SOURCE_POLICY.md §8.2).';
comment on column workflow.monograph_search_requests.track_codes is
  'De obligatoriske søkesporene runden kan erklære å dekke. Dekningskontrollens motsøk har alltid ingen: et motsøk som dekket generatorens spor, ville produsert nettopp den dekningen det skal kontrollere (SOURCE_POLICY.md §4.2, §6).';
comment on column workflow.monograph_search_requests.attempts is
  'Hvor mange ganger den planlagte kjøringen har forsøkt runden. Taket på tre er der fordi en søkevei som ikke svarer, er en begrensning som skal registreres og ikke en kø som skal vokse — og fordi et forsøk til aldri må kunne bli en grunn til at arbeidet står i det uendelige.';

alter table workflow.monograph_search_requests enable row level security;

create index monograph_search_requests_open_idx
  on workflow.monograph_search_requests (plan_id, requested_for_role, state);

create trigger monograph_search_requests_set_row_timestamps
  before insert or update on workflow.monograph_search_requests
  for each row execute function catalog.set_row_timestamps();

-- Og forespørselen er uforanderlig i det den er: bestillingen kan ikke skrives
-- om etter at kjøringen har utført den. Bare tilstanden beveger seg.
create function workflow.freeze_monograph_search_request()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.reference is distinct from old.reference
     or new.plan_id is distinct from old.plan_id
     or new.plan_version is distinct from old.plan_version
     or new.requested_for_role is distinct from old.requested_for_role
     or new.search_round is distinct from old.search_round
     or new.origin is distinct from old.origin
     or new.strategy is distinct from old.strategy
     or new.rationale is distinct from old.rationale
     or new.platform is distinct from old.platform
     or new.query_terms is distinct from old.query_terms
     or new.track_codes is distinct from old.track_codes
     or new.requested_by_agent_run_id is distinct from old.requested_by_agent_run_id
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En maskinell søkeforespørsel er uforanderlig i det den bestiller.',
      hint = 'Bestillingen er det søkeloggen dokumenterer at ble utført. En endret bestilling er en ny runde, ikke en omskrevet gammel.';
  end if;

  if old.state in ('fulfilled', 'abandoned') and new.state <> old.state then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En avsluttet søkeforespørsel kan ikke gjenåpnes.',
      hint = 'En utført eller oppgitt runde er et historisk faktum søkeloggen hviler på. Trengs det flere søk, er det en ny runde.';
  end if;

  return new;
end;
$$;

comment on function workflow.freeze_monograph_search_request() is
  'Holder det en maskinell søkeforespørsel bestiller, uforanderlig, og hindrer at en avsluttet runde gjenåpnes. Bare tilstanden, forsøkene og utfallsmerknaden beveger seg.';

revoke execute on function workflow.freeze_monograph_search_request() from public;

create trigger monograph_search_requests_are_frozen
  before update on workflow.monograph_search_requests
  for each row execute function workflow.freeze_monograph_search_request();

create trigger monograph_search_requests_reject_delete
  before delete on workflow.monograph_search_requests
  for each row execute function knowledge.reject_append_only_mutation();

-- Og søket peker tilbake på runden det ble utført for. Uten koblingen kunne en
-- runde blitt lukket av et søk som hørte til en annen.
alter table workflow.monograph_searches
  add column search_request_id uuid
    references workflow.monograph_search_requests (id) on update restrict on delete restrict;

comment on column workflow.monograph_searches.search_request_id is
  'Den maskinelle søkeforespørselen søket ble utført for, når det ble det. NULL for et søk registrert utenom en runde — den historiske agentrapporterte veien, og en redaktørs egen registrering. Koblingen er det runden lukkes av: uten den kunne et søk fra en annen runde sett ut som utførelsen av denne.';

-- ----------------------------------------------------------------------------
-- Og en søkevei som aldri svarte, må kunne registreres
--
-- Dette er en reell feil, funnet mens rekkefølgen over ble prøvd. Raden krevde
-- at et maskinelt utført søk *alltid* bar et responsavtrykk. Et avtrykk finnes
-- når det kom et svar — også når svaret var en HTTP-feil — men det finnes ikke
-- når tjenesten ikke svarte i det hele tatt. Nettopp det tilfellet ble derfor
-- avvist av beskrankningen, og kjøringen kunne ikke registrere begrensningen:
-- planen ville stått åpen uten at noe sa hvorfor, og den ærlige opplysningen
-- «vi kom ikke til databasen» hadde ingen vei inn (SOURCE_POLICY.md §4.2, §8.2).
--
-- Regelen strammes derfor til der den betyr noe, og løsnes der den ikke kunne
-- oppfylles: et maskinelt søk som faktisk ga et resultat — `executed`,
-- `zero_results` — og et som fikk et svar det ikke kunne lese — `failed` — må
-- bære avtrykket. Et `unavailable` maskinelt søk bærer det når det finnes, og
-- ikke når det ikke gjør det. Endepunktet står uansett: Antidep vet alltid
-- hvilken adresse den forsøkte. Et agentrapportert søk kan fortsatt ikke bære
-- noen av delene.
-- ----------------------------------------------------------------------------

alter table workflow.monograph_searches
  drop constraint monograph_searches_evidence_shape_check;

alter table workflow.monograph_searches
  add constraint monograph_searches_evidence_shape_check
  check (
    case execution_evidence
      when 'agent_reported' then
        evidence_endpoint is null and response_digest is null
        and agent_run_id is not null
      when 'machine_executed' then
        evidence_endpoint is not null
        and (response_digest is not null or outcome = 'unavailable')
      else false
    end
  );

comment on column workflow.monograph_searches.execution_evidence is
  'Hvilket utførelsesbevis Antidep har: agent_reported er agentens egen beretning om et verktøykall, machine_executed er Antideps eget kall med endepunktet og responsavtrykket som bevis. Skillet er håndhevet av raden og ikke av en konvensjon, slik at en agents erklæring aldri kan omtales som maskinelt bekreftet utførelse. Fra migrasjon 013v har et maskinelt utført søk alltid et endepunkt, og et responsavtrykk når det kom et svar å ta avtrykk av: en søkevei som ikke svarte i det hele tatt, er `unavailable` uten avtrykk — den skal kunne registreres som den ærlige begrensningen den er, framfor å bli avvist og forsvinne.';

-- ----------------------------------------------------------------------------
-- 4. Å åpne en runde, og å vite om den er gjort
-- ----------------------------------------------------------------------------

create function workflow.open_monograph_search_request(
  p_plan_id uuid,
  p_role provenance.agent_role,
  p_round integer,
  p_origin workflow.monograph_search_request_origin,
  p_strategy workflow.monograph_search_strategy,
  p_rationale text,
  p_platform text,
  p_query_terms text[],
  p_filters_note text,
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

  -- Sporene runden kan erklære. Generatorens runde kan erklære de sporene
  -- kildeprofilen faktisk krever; kontrollens motsøk kan ikke erklære noen, og
  -- raden håndhever det.
  if p_role = 'source_discovery' then
    select e.* into v_edition
    from knowledge.monograph_editions e where e.id = v_plan.edition_id;

    select coalesce(array_agg(k.code order by k.ordinal), array[]::text[]) into v_tracks
    from knowledge.monograph_search_tracks k
    join knowledge.monograph_search_track_profiles kp on kp.track_id = k.id
    where k.standard_version = v_edition.standard_version
      and kp.profile_id = v_plan.profile_id;
  end if;

  insert into workflow.monograph_search_requests (
    plan_id, plan_version, requested_for_role, search_round,
    origin, strategy, rationale, platform, query_terms, filters_note,
    track_codes, requested_by_agent_run_id, requested_by_actor_id
  )
  values (
    p_plan_id, v_plan.plan_version, p_role, p_round,
    p_origin, p_strategy, btrim(p_rationale),
    nullif(btrim(coalesce(p_platform, '')), ''),
    coalesce(p_query_terms, array[]::text[]),
    nullif(btrim(coalesce(p_filters_note, '')), ''),
    v_tracks, p_agent_run_id,
    coalesce(p_actor_id, v_plan.created_by_actor_id)
  )
  on conflict on constraint monograph_search_requests_round_key do nothing
  returning id into v_id;

  return v_id;
end;
$$;

comment on function workflow.open_monograph_search_request(uuid, provenance.agent_role, integer, workflow.monograph_search_request_origin, workflow.monograph_search_strategy, text, text, text[], text, uuid, uuid) is
  'Åpner én maskinell søkerunde på en søkeplanversjon, idempotent på (plan, versjon, rolle, runde, strategi, plattform). Sporene runden kan erklære, utledes av kildeprofilen og settes her og ikke av kalleren: et søk som erklærte et spor profilen aldri ba om, ville fått porten til å se dekket ut (SOURCE_POLICY.md §4.2). Dekningskontrollens motsøk får ingen spor i det hele tatt — et motsøk som dekket generatorens spor, ville produsert den dekningen det kontrollerer (§6). Svarer med runden sin id, eller NULL når den fantes fra før eller planen er lukket eller står på pause.';

revoke execute on function workflow.open_monograph_search_request(uuid, provenance.agent_role, integer, workflow.monograph_search_request_origin, workflow.monograph_search_strategy, text, text, text[], text, uuid, uuid) from public;

create function workflow.monograph_search_round(
  p_plan_id uuid,
  p_role provenance.agent_role
)
  returns integer
  language sql
  stable
  set search_path = ''
as $$
  select case
    when p_role = 'source_discovery'::provenance.agent_role then p.discovery_round
    else p.control_round
  end
  from workflow.monograph_search_plans p
  where p.id = p_plan_id;
$$;

comment on function workflow.monograph_search_round(uuid, provenance.agent_role) is
  'Hvilken maskinell søkerunde søkeplanen står i for ett av de to kildeleddene. Runden inngår i oppgavens manifest og i jobbnøkkelen, slik at en ny runde faktisk blir en ny oppgave.';

revoke execute on function workflow.monograph_search_round(uuid, provenance.agent_role) from public;

create function workflow.monograph_search_phase_problem(
  p_plan_id uuid,
  p_role provenance.agent_role
)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_round integer;
  v_open integer;
  v_total integer;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;
  if not found then
    return 'Søkeplanen finnes ikke.';
  end if;

  v_round := workflow.monograph_search_round(p_plan_id, p_role);

  select count(*) filter (where r.state = 'pending'), count(*)
    into v_open, v_total
  from workflow.monograph_search_requests r
  where r.plan_id = p_plan_id
    and r.plan_version = v_plan.plan_version
    and r.requested_for_role = p_role
    and r.search_round = v_round;

  if v_total = 0 then
    return 'Den maskinelle søkefasen er ikke åpnet for denne runden ennå. Antideps egen kode utfører søkene; det semantiske leddet vurderer det som er hentet.';
  end if;

  if v_open > 0 then
    return format(
      'Den maskinelle søkefasen er ikke ferdig: %s søkerunde(r) står uutført. Oppgaven kan ikke hentes ut før Antideps egen kode har søkt og registrert resultatene — den semantiske agenten utfører ingen søk selv.',
      v_open);
  end if;

  return null;
end;
$$;

comment on function workflow.monograph_search_phase_problem(uuid, provenance.agent_role) is
  'Én setning om hvorfor den semantiske oppgaven ikke kan hentes ut ennå, eller NULL. Porten som holder rekkefølgen: Antideps deterministiske kode søker først, og den semantiske agenten vurderer resultatene etterpå. Bare en pending runde holder tilbake — en søkevei som ikke svarte, gir unavailable, og den slipper oppgaven videre med begrensningen synlig framfor å låse arbeidet (SOURCE_POLICY.md §8.2). Leses av kjedeovergangen, av forhåndskontrollen av oppgaven og av uttaket, slik at de tre ikke kan bli uenige om hva som er en utførbar oppgave.';

revoke execute on function workflow.monograph_search_phase_problem(uuid, provenance.agent_role) from public;

-- Om dekningskontrollen faktisk har søkt selv.
--
-- Utledet, og ikke erklært. Fram til nå sto `searched_independently` i svaret,
-- og en erklæring et svar kan bestå ved å skrive den, kontrollerer ingenting.
-- Nå er den et spørsmål til søkeloggen: finnes det et maskinelt utført søk på
-- denne planversjonen, registrert av kontrollrollens egen kjøring, som faktisk
-- gikk?
create function workflow.monograph_control_searched_independently(p_plan_id uuid)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select exists (
    select 1
    from workflow.monograph_searches s
    join provenance.agent_runs r on r.id = s.agent_run_id
    join workflow.monograph_search_plans p on p.id = s.plan_id
    where s.plan_id = p_plan_id
      and s.plan_version = p.plan_version
      and s.execution_evidence = 'machine_executed'
      and s.outcome in ('executed', 'zero_results')
      and r.agent_role = 'source_quality_assessment'::provenance.agent_role
  );
$$;

comment on function workflow.monograph_control_searched_independently(uuid) is
  'Om den separate dekningskontrollen faktisk har egne, maskinelt utførte søk på gjeldende planversjon. Utledet av søkeloggen og ikke erklært i svaret: en erklæring om egen uavhengighet som kan bestås ved å skrive den, kontrollerer ingenting — den lærer bare den som skriver svaret, hvilken streng som er nøkkelen inn (SOURCE_POLICY.md §6, ANTIDEP_CONSTITUTION.md regel 3).';

revoke execute on function workflow.monograph_control_searched_independently(uuid) from public;

-- ----------------------------------------------------------------------------
-- 5. Subjektet, kontrakten og kjedeovergangene
--
-- Subjektet bærer runden. Uten den ville runde to fått den samme jobbnøkkelen
-- som runde én, og `workflow.chain_enqueue_job(...)` ville svart at arbeidet
-- fantes fra før — det semantiske leddet ville bedt om flere søk og aldri fått
-- se dem.
-- ----------------------------------------------------------------------------

create or replace function workflow.agent_task_manifest_subject(
  p_agent_role provenance.agent_role,
  p_input_manifest jsonb
)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case p_agent_role
    when 'evidence_extraction' then coalesce(p_input_manifest ->> 'source_version_id', '?')
    when 'claim_synthesis' then workflow.claim_synthesis_subject(
      p_input_manifest ->> 'subject_drug_id',
      p_input_manifest ->> 'topic_concept_id',
      p_input_manifest ->> 'monograph_need_id')
    when 'source_discovery' then format('%s#d%s',
      coalesce(p_input_manifest ->> 'search_plan_id', '?'),
      coalesce(p_input_manifest ->> 'discovery_round', '?'))
    when 'source_quality_assessment' then format('%s#c%s',
      coalesce(p_input_manifest ->> 'search_plan_id', '?'),
      coalesce(p_input_manifest ->> 'control_round', '?'))
    when 'monograph_answer' then coalesce(p_input_manifest ->> 'monograph_need_id', '?')
    else coalesce(p_input_manifest ->> 'claim_revision_id', '?')
  end;
$$;

comment on function workflow.agent_task_manifest_subject(provenance.agent_role, jsonb) is
  'Hva en oppgave i rollen handler om, som en stabil tekst: kildeversjonen, virkestoffet og temaet, søkeplanen med runden sin, kunnskapsbehovet, eller påstandsrevisjonen. Oppgavenøkkelen bygges av den, og duplikatkontrollen i kjedeovergangene leser den samme. Fra migrasjon 013v bærer kildeleddenes subjekt den maskinelle søkerunden: en ny runde er en ny vurdering av et nytt grunnlag, og uten runden i subjektet ville den andre runden sett ut som den første og aldri blitt lagt inn.';

create or replace function workflow.agent_task_contract(p_agent_role provenance.agent_role)
  returns jsonb
  language sql
  immutable
  set search_path = ''
as $$
  select case p_agent_role
    -- Promptmalene står på /2 fra migrasjon 013u: den delte delen av
    -- oppgaveteksten ble skrevet om for alle seks rollene i den samme
    -- endringen. Svarformene er uendret — `result` er det samme som før.
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
    -- Migrasjon 013v: kildeleddene vurderer maskinelt utførte søk og ber om
    -- flere som strukturerte søkeforespørsler. De rapporterer ikke lenger søk,
    -- og `searches` finnes ikke i noen av de to svarformene.
    when 'source_discovery' then jsonb_build_object(
      'prompt_template_version', 'source-discovery/machine-search-appraisal/3',
      'output_schema_version', 'antidep/source-discovery-draft@3'
    )
    when 'source_quality_assessment' then jsonb_build_object(
      'prompt_template_version', 'source-coverage/machine-countersearch-control/3',
      'output_schema_version', 'antidep/source-coverage-control-draft@2'
    )
    -- Migrasjon 013i: svaret på et behov som hviler på et myndighets-,
    -- preparat- eller retningslinjedokument. Den deterministiske
    -- svarkontrollen står bevisst ikke her: den er Antideps egen kode.
    when 'monograph_answer' then jsonb_build_object(
      'prompt_template_version', 'monograph-answer/handoff-fact/2',
      'output_schema_version', 'antidep/monograph-answer-draft@1'
    )
    else null
  end;
$$;

comment on function workflow.agent_task_contract(provenance.agent_role) is
  'Promptmalversjonen og outputschemaversjonen rollen er bundet til i den eksterne agent-handoffen, eller NULL for en rolle som ikke kan ta imot et eksternt agentsvar. Begge verdiene inngår i request_digest, slik at et svar avgitt under en eldre mal eller et eldre skjema ikke kan importeres på en oppgave bygget under en nyere. Verdiene er de samme som i src/agents/agent-task.ts, og pinnes av en prøve på begge sider av databasegrensen. Migrasjon 013v hevet begge kildeleddene: oppgaven ber nå om en vurdering av maskinelt utførte søk og om strukturerte søkeforespørsler, og ikke om søk modellen selv skulle ha utført.';

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
  if v_plan.discovery_round = 1 then
    perform workflow.open_monograph_search_request(
      p_plan_id, 'source_discovery'::provenance.agent_role, 1,
      'plan_opened'::workflow.monograph_search_request_origin,
      'broad'::workflow.monograph_search_strategy,
      'Den nye søkeplanens første maskinelle søkerunde: et bredt orienterende søk over avgrensningen (SOURCE_POLICY.md §4.1).',
      null, array[]::text[], null, null, v_plan.created_by_actor_id);
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
  'Åpner den maskinelle søkefasen for en ny søkeplan, og legger kildeoppdagelsens semantiske vurderingsoppgave i køen når fasen for gjeldende runde er gjort. Fra migrasjon 013v er rekkefølgen en port og ikke en forventning: Antideps deterministiske kode søker først, og den semantiske agenten vurderer resultatene etterpå — den blir aldri bedt om å utføre søke-I/O den ikke har verktøy til. Idempotent på planen og runden: to oppgaver om den samme runden i den samme rollen er ett stykke arbeid, og låsen tas før spørsmålet om oppgaven finnes. Gjør ingenting for en plan som er erklært ferdig eller står på pause. Svarer med jobbens id, eller NULL.';

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
      null, array[]::text[], null, null, v_plan.created_by_actor_id);
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

comment on function workflow.chain_task_for_search_coverage(uuid) is
  'Åpner dekningskontrollens egen maskinelle motsøkerunde for én søkeplan, og legger kontrolloppgaven i køen når runden er gjort. Motsøkene utføres av Antideps deterministiske kode under kontrollens egen identitet og kjøring, med en annen søkestrategi enn generatorens: kontrollen skal lete etter det generatoren overså, og den har ikke — og skal ikke ha — verktøy til å søke selv (SOURCE_POLICY.md §6). Gjør ingenting når det ikke finnes et utført søk å kontrollere, eller når planversjonen allerede er kontrollert. Svarer med jobbens id, eller NULL.';

-- ----------------------------------------------------------------------------
-- 6. Søkeloggen bærer runden den ble utført for
--
-- Parameteren legges til framfor å lages som en overlast: to nesten like
-- kropper ville før eller siden fått hver sin regel, og den ene som ble glemt,
-- ville registrert et søk uten den runden porten leser.
-- ----------------------------------------------------------------------------

drop function workflow.record_monograph_search(
  uuid, text, text, text, timestamptz, integer, integer, boolean, text,
  workflow.monograph_search_outcome, text, workflow.monograph_execution_evidence,
  text, text, text[], uuid, uuid);

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
  p_search_request_id uuid
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
    track_codes, agent_run_id, recorded_by_actor_id, search_request_id
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
    p_search_request_id
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

comment on function workflow.record_monograph_search(uuid, text, text, text, timestamptz, integer, integer, boolean, text, workflow.monograph_search_outcome, text, workflow.monograph_execution_evidence, text, text, text[], uuid, uuid, uuid) is
  'Registrerer ett faktisk utført søk på én søkeplan, og oppdaterer sporene søket dekket. Et søk som gikk, dekker sporet; et søk som ikke kunne gå, registrerer sporet som utilgjengelig med sin begrensning framfor som dekket — skillet mellom en begrensning og et resultat (SOURCE_POLICY.md §8.2). Sporkodene må være obligatoriske for planens kildeprofil, ellers kunne et søk erklært å dekke et spor planen aldri hadde. Et søk avvises etter at søkedekningen er erklært ferdig: det hører til en ny planversjon med sin egen dekningskontroll. Fra migrasjon 013v bærer søket den maskinelle runden det ble utført for, slik at runden kan lukkes av nøyaktig de søkene som faktisk ble gjort i den. Autentiserer ingenting selv og kalles fra innsiden av en api-funksjon som allerede har fastslått hvem kalleren er.';

revoke execute on function workflow.record_monograph_search(uuid, text, text, text, timestamptz, integer, integer, boolean, text, workflow.monograph_search_outcome, text, workflow.monograph_execution_evidence, text, text, text[], uuid, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 7. Arbeidet den maskinelle kjøringen henter
--
-- Nå med runden og selve søkeforespørslene: kjøringen skal ikke gjette hva den
-- skal søke etter, og den skal ikke søke det samme om igjen hver time.
-- ----------------------------------------------------------------------------

create or replace function api.monograph_discovery_work(p_identity_key text, p_secret text)
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
      and exists (
        select 1 from workflow.monograph_search_requests r
        where r.plan_id = p.id
          and r.plan_version = p.plan_version
          and r.requested_for_role = v_identity.agent_role
          and r.state in ('pending', 'unavailable'))
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
  'De åpne maskinelle søkerundene kallerens eget kildeledd skal utføre nå: avgrensningen, kildeprofilen, de kunnskapsbehovene planen dekker med spørsmålene ordrett, de obligatoriske søkesporene med tilstanden sin, søkene som er gjort, og — fra migrasjon 013v — selve søkeforespørslene med strategi, termer og hvilke spor runden kan erklære. En plan uten en åpen runde står ikke i listen: kjøringen søker det noen faktisk har bedt om, og ikke det samme om igjen hver time. Krever kildeoppdagelsens eller dekningskontrollens egen identitet og legitimasjon, og gir hver av dem bare sine egne runder. SECURITY DEFINER fordi knowledge, workflow og catalog har RLS med default deny.';

revoke execute on function api.monograph_discovery_work(text, text) from public;
grant execute on function api.monograph_discovery_work(text, text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 8. Den maskinelt utførte søkeveien, bundet til runden den utfører
--
-- Signaturen endres, så den gamle slippes framfor å bli stående ved siden av:
-- en vei inn som ikke bærer runden, ville registrert et søk porten ikke kunne
-- lese — og runden ville stått åpen for alltid.
-- ----------------------------------------------------------------------------

drop function api.record_monograph_machine_search(
  text, text, uuid, text, text, text, text, text, text, text,
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
  v_request workflow.monograph_search_requests;
  v_outcome workflow.monograph_search_outcome;
  v_tracks text[];
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
    v_request.id);

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
    'candidates_recorded', v_recorded,
    'closure_problem', workflow.monograph_search_closure_problem(v_plan.id));
end;
$$;

comment on function api.record_monograph_machine_search(text, text, uuid, text, text, text, text, text, text, text, text, integer, integer, boolean, text, text, text[], jsonb) is
  'Registrerer ett søk Antidep faktisk utførte selv for én åpen søkerunde, med endepunktet og responsavtrykket som utførelsesbevis, og kandidatkildene det ga. Dette er veien som gjør kildeoppdagelsen til en utført operasjon framfor til en rapportert: utførelsesbeviset settes av funksjonen og kan ikke oppgis av en kaller, så et agentsvar kan ikke gi seg ut for å være maskinelt bekreftet (SOURCE_POLICY.md §4.3). Fra migrasjon 013v må søket høre til en åpen runde bestilt for kallerens eget ledd, og det kan bare erklære de søkesporene runden fikk — dekningskontrollens motsøk kan ikke dekke generatorens obligatoriske spor. Krever kildeleddets egen identitet, legitimasjon og en åpen kjøring som tilhører den. Ingen ekstern modell er en forutsetning, og ingen modellnøkkel finnes.';

revoke execute on function api.record_monograph_machine_search(text, text, uuid, text, text, text, text, text, text, text, text, integer, integer, boolean, text, text, text[], jsonb) from public;
grant execute on function api.record_monograph_machine_search(text, text, uuid, text, text, text, text, text, text, text, text, integer, integer, boolean, text, text, text[], jsonb) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 9. Å lukke runden — og først da finnes den semantiske oppgaven
--
-- Tilstanden utledes av søkeloggen og ikke av det kjøringen sier om seg selv.
-- En kjører som meldte «ferdig» uten å ha registrert et søk, ville ellers
-- kunnet slippe den semantiske oppgaven fram på et tomt grunnlag.
-- ----------------------------------------------------------------------------

create function api.close_monograph_search_request(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_request_reference text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity provenance.agent_identities;
  v_identity_id uuid;
  v_request workflow.monograph_search_requests;
  v_ran integer;
  v_recorded integer;
  v_attempts integer;
  v_state workflow.monograph_search_request_state;
  v_note text;
  v_job uuid;
begin
  select i.* into v_identity
  from provenance.agent_identities i
  where i.identity_key = p_identity_key;

  if not found or v_identity.agent_role not in
       ('source_discovery'::provenance.agent_role,
        'source_quality_assessment'::provenance.agent_role) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'En søkerunde lukkes bare av kildeleddene.';
  end if;

  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, v_identity.agent_role);
  perform provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  select r.* into v_request
  from workflow.monograph_search_requests r
  where r.reference = p_request_reference
  for update;

  if not found or v_request.requested_for_role <> v_identity.agent_role then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkerunden finnes ikke for dette kildeleddet.';
  end if;

  if v_request.state not in ('pending', 'unavailable') then
    return jsonb_build_object(
      'request_reference', v_request.reference,
      'state', v_request.state::text,
      'closed', false,
      'enqueued_job', null);
  end if;

  -- Hva runden faktisk gjorde. Ett søk som gikk, er nok til at runden er utført:
  -- en plattform som var nede, er en registrert begrensning og ikke en grunn
  -- til å holde hele runden åpen (SOURCE_POLICY.md §8.2).
  select count(*) filter (where s.outcome in ('executed', 'zero_results')), count(*)
    into v_ran, v_recorded
  from workflow.monograph_searches s
  where s.search_request_id = v_request.id;

  v_attempts := v_request.attempts + 1;

  if v_ran > 0 then
    v_state := 'fulfilled';
    v_note := null;
  elsif v_attempts >= 3 then
    v_state := 'abandoned';
    v_note := format(
      'Tre forsøk nådde ikke fram til en søkevei som svarte (%s registrerte forsøk). Begrensningen står, og den er ikke en konklusjon om evidensen.',
      v_recorded);
  else
    v_state := 'unavailable';
    v_note := format(
      'Ingen søkevei svarte i dette forsøket (%s registrerte forsøk). Runden prøves på nytt ved neste planlagte kjøring.',
      v_recorded);
  end if;

  update workflow.monograph_search_requests
  set state = v_state,
      attempts = v_attempts,
      last_attempt_at = now(),
      completed_at = case when v_state in ('fulfilled', 'abandoned') then now() end,
      outcome_note = v_note
  where id = v_request.id;

  -- Og overgangen: den semantiske oppgaven finnes fra nå, om runden var den
  -- siste som sto åpen.
  if v_identity.agent_role = 'source_discovery' then
    v_job := workflow.chain_task_for_search_plan(v_request.plan_id);
  else
    v_job := workflow.chain_task_for_search_coverage(v_request.plan_id);
  end if;

  return jsonb_build_object(
    'request_reference', v_request.reference,
    'state', v_state::text,
    'closed', true,
    'searches_recorded', v_recorded,
    'searches_that_ran', v_ran,
    'enqueued_job', v_job is not null,
    'phase_problem', workflow.monograph_search_phase_problem(
      v_request.plan_id, v_identity.agent_role));
end;
$$;

comment on function api.close_monograph_search_request(text, text, uuid, text) is
  'Lukker én maskinell søkerunde etter at kjøringen har registrert søkene sine, og legger den semantiske vurderingsoppgaven i køen når runden var den siste som sto åpen. Tilstanden utledes av søkeloggen og ikke av det kjøringen sier om seg selv: gikk minst ett søk, er runden utført; nådde ingen fram, er den utilgjengelig — som prøves på nytt, men som ikke holder den semantiske oppgaven tilbake, fordi en tjeneste som er nede, ikke skal kunne stanse arbeidet for alltid (SOURCE_POLICY.md §8.2). Etter tre forsøk står begrensningen, og runden er gitt opp framfor å vokse. Krever kildeleddets egen identitet, legitimasjon og en åpen kjøring som tilhører den. SECURITY DEFINER fordi workflow har RLS med default deny.';

revoke execute on function api.close_monograph_search_request(text, text, uuid, text) from public;
grant execute on function api.close_monograph_search_request(text, text, uuid, text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 10. Selve oppgaven, skrevet om til det agenten faktisk kan gjøre
--
-- Den gamle oppgaven ba modellen søke. Den nye gir den søkene Antidep har
-- utført, kandidatene de ga, og de begrensningene som står — og ber om det
-- semantiske: hva er relevant, til hva, og hva mangler som bør søkes etter.
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
    'required_tracks', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', k.code, 'label', k.label,
               'state', a.state::text, 'note', a.note) order by k.ordinal), '[]'::jsonb)
      from workflow.monograph_search_track_attempts a
      join knowledge.monograph_search_tracks k on k.id = a.track_id
      where a.plan_id = v_plan.id),
    -- Søkene Antidep faktisk utførte, med endepunkt og responsavtrykk. Dette
    -- er grunnlaget vurderingen gjelder, og det er maskinelt bekreftet
    -- utførelse og ikke noens beretning (SOURCE_POLICY.md §4.3).
    'machine_searches', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'platform', s.platform,
               'query', s.query_string,
               'filters', s.filters,
               'outcome', s.outcome::text,
               'result_count', s.result_count,
               'screened_count', s.screened_count,
               'truncated', s.truncated,
               'truncation_note', s.truncation_note,
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
      where s.plan_id = v_plan.id and s.plan_version = v_plan.plan_version),
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
               'found_by_platform', (select s.platform from workflow.monograph_searches s
                                     where s.id = c.search_id),
               'decision', c.decision::text,
               'decision_reason', c.decision_reason,
               'access_limited', c.access_limited,
               'access_limitation_note', c.access_limitation_note,
               'could_change_conclusion', c.could_change_conclusion,
               'materiality_reason', c.materiality_reason,
               'uses', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'need_reference', n.reference,
                          'proposed_use', cn.proposed_use) order by n.reference), '[]'::jsonb)
                 from workflow.monograph_candidate_source_needs cn
                 join knowledge.monograph_needs n on n.id = cn.need_id
                 where cn.candidate_source_id = c.id))
               order by c.created_at), '[]'::jsonb)
      from workflow.monograph_candidate_sources c where c.plan_id = v_plan.id),
    -- Hva en søkeforespørsel kan be om. Listen er uttømmende med vilje: en
    -- forespørsel kan ikke oppgi en adresse, og en plattform ingen har
    -- vurdert, finnes ikke å be om (ANTIDEP_CONSTITUTION.md regel 7).
    'search_request_options', jsonb_build_object(
      'platforms', jsonb_build_array('Europe PMC', 'PubMed', 'Crossref'),
      'strategies', jsonb_build_array('broad', 'targeted'),
      'max_terms', 8,
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
      'En søkevei som ikke svarte, står som en begrensning i oppgaven. Den er ikke null treff, og den er aldri en konklusjon om evidensen.'));

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
                   'decision_reason', c.decision_reason) order by c.created_at), '[]'::jsonb)
          from workflow.monograph_candidate_sources c
          where c.plan_id = v_plan.id and c.decision = 'excluded'),
        'unresolved_candidates', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'identifier_kind', c.identifier_kind,
                   'identifier_value', c.identifier_value,
                   'title', c.title,
                   'decision', c.decision::text,
                   'access_limited', c.access_limited,
                   'could_change_conclusion', c.could_change_conclusion,
                   'materiality_reason', c.materiality_reason) order by c.created_at), '[]'::jsonb)
          from workflow.monograph_candidate_sources c
          where c.plan_id = v_plan.id and c.decision not in ('included', 'excluded'))));
  end if;

  return v_payload;
end;
$$;

comment on function workflow.monograph_discovery_task_input(uuid, provenance.agent_role) is
  'Innholdet vurderingsoppgaven og kontrolloppgaven består av: avgrensningen, kildeprofilen, de relevante kunnskapsbehovene med spørsmålene ordrett fra standarden, de obligatoriske søkesporene, og — fra migrasjon 013v — de maskinelt utførte søkene med endepunkt og responsavtrykk, de søkeveiene som ikke svarte, og kandidatkildene de ga. Oppgaven ber ikke lenger modellen utføre søk: søke-I/O er Antideps deterministiske kode, og det semantiske leddet vurderer resultatene og ber om flere søk som strukturerte søkeforespørsler. Kontrolloppgaven får i tillegg sine egne, separat initierte og maskinelt utførte motsøk, generatorens søk, eksklusjonene og de uavklarte kildene — og uavhengigheten dens er utledet av søkeloggen framfor erklært i svaret (SOURCE_POLICY.md §4.1, §4.3, §6).';

revoke execute on function workflow.monograph_discovery_task_input(uuid, provenance.agent_role) from public;

-- ----------------------------------------------------------------------------
-- 11. Forhåndskontrollen av oppgaven
--
-- Kroppen er hentet fra databasen og har de eksisterende grenene ordrett
-- uendret. Det som er lagt til, er runden og søkefaseporten på kildeleddenes
-- gren. Køen, uttaket og importen leser alle denne ene funksjonen, så de kan
-- ikke bli uenige om hva som er en utførbar oppgave.
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
  v_round text;
  v_phase text;
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

    if (v_manifest ->> 'plan_version')::integer is distinct from v_plan.plan_version then
      return 'Søkeplanen har fått en ny versjon siden oppgaven ble lagt inn. Arbeidet hører til den nye versjonen.';
    end if;

    if v_plan.closed_at is not null then
      return 'Søkedekningen for denne planen er allerede erklært ferdig.';
    end if;

    if v_plan.paused_at is not null then
      return format('Søket står på pause: %s', v_plan.paused_reason);
    end if;

    if not exists (
      select 1 from workflow.monograph_search_plan_needs pn where pn.plan_id = v_plan_id
    ) then
      return 'Søkeplanen dekker ikke noe kunnskapsbehov, og det finnes ikke noe spørsmål å søke etter.';
    end if;

    -- Runden oppgaven hører til. En oppgave bygget før migrasjon 013v bærer den
    -- ikke, og den er foreldet med vilje: den ba agenten utføre søk den ikke
    -- har — og skal ikke ha — verktøy til.
    v_round := case when p_job.agent_role = 'source_discovery'
                    then v_manifest ->> 'discovery_round'
                    else v_manifest ->> 'control_round' end;

    if v_round is null then
      return 'Oppgaven er bygget under en tidligere kildekontrakt som ba agenten utføre søkene selv. Den kontrakten gjelder ikke lenger: Antideps egen kode utfører søkene, og oppgaven bygges på nytt når den maskinelle søkerunden er gjort.';
    end if;

    if v_round::integer is distinct from
       workflow.monograph_search_round(v_plan_id, p_job.agent_role) then
      return 'Søkeplanen har fått en ny maskinell søkerunde siden oppgaven ble lagt inn. Arbeidet hører til den nye runden.';
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
  'Én setning om hva som hindrer at oppgaven kan bygges av grunnlaget som faktisk ligger der, eller NULL. Fra migrasjon 013v krever kildeleddenes gren i tillegg at oppgaven hører til gjeldende maskinelle søkerunde, og at runden er utført: en semantisk oppgave som krevde søke-I/O agenten ikke har verktøy til, er ikke en oppgave — den er en umulighet, og den ble frigitt i produksjon med nettopp den begrunnelsen. En oppgave bygget under den forrige kildekontrakten bærer ingen runde, og er foreldet.';

-- ----------------------------------------------------------------------------
-- 12. Vesentligheten er en semantisk vurdering, og trenger sin egen skrivevei
--
-- Det maskinelle søket kan ikke vite om en kilde med rimelighet kan endre
-- hovedkonklusjonen — det leser en treffliste. Vurderingen er kildeoppdagelsens
-- og dekningskontrollens, og den er nettopp det som hindrer at et søk avsluttes
-- for tidlig (SOURCE_POLICY.md §8.1).
-- ----------------------------------------------------------------------------

create function workflow.appraise_monograph_candidate_source(
  p_candidate_id uuid,
  p_could_change_conclusion boolean,
  p_materiality_reason text,
  p_agent_run_id uuid
)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_reason text := nullif(btrim(coalesce(p_materiality_reason, '')), '');
begin
  if coalesce(p_could_change_conclusion, false) and v_reason is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En kilde som kan endre hovedkonklusjonen, må ha en begrunnelse.',
      hint = 'Vesentligheten skal begrunnes og kontrolleres separat (SOURCE_POLICY.md §8.1). Uten begrunnelsen ville porten stått på et utsagn ingen kunne etterprøve.';
  end if;

  update workflow.monograph_candidate_sources
  set could_change_conclusion = coalesce(p_could_change_conclusion, false),
      materiality_reason = case when coalesce(p_could_change_conclusion, false)
                                then v_reason end,
      decided_by_agent_run_id = coalesce(decided_by_agent_run_id, p_agent_run_id)
  where id = p_candidate_id;
end;
$$;

comment on function workflow.appraise_monograph_candidate_source(uuid, boolean, text, uuid) is
  'Registrerer den semantiske vurderingen av om én kandidatkilde med rimelighet kan endre hovedkonklusjonen, med begrunnelsen. Det maskinelle søket kan ikke avgjøre dette — det leser en treffliste — og vurderingen er nettopp det som hindrer at søket avsluttes for tidlig (SOURCE_POLICY.md §8.1). Identiteten og oppdagelsesveien røres ikke: de er dokumentasjonen på søket.';

revoke execute on function workflow.appraise_monograph_candidate_source(uuid, boolean, text, uuid) from public;

-- ----------------------------------------------------------------------------
-- 13. Svarveien for de to kildeleddene, skrevet om til den nye kontrakten
--
-- Den store endringen står i én setning: `searches` finnes ikke lenger. Et
-- ledd som ikke utfører søk, skal ikke ha en vei til å rapportere at det gjorde
-- det — og et svar som fortsatt bærer feltet, avvises med en setning som sier
-- hvorfor framfor med «ukjent felt».
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION workflow.record_monograph_discovery_answer(p_job workflow.pipeline_jobs, p_input jsonb, p_result jsonb, p_run_id uuid, p_actor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_plan_id uuid := workflow.manifest_uuid(p_input, 'search_plan_id');
  v_plan workflow.monograph_search_plans;
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

      select c.* into v_candidate
      from workflow.monograph_candidate_sources c
      where c.plan_id = v_plan_id
        and c.identifier_kind = (v_item ->> 'identifier_kind')
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
          v_candidate.id, v_decision, v_item ->> 'decision_reason', null, p_run_id);
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

    v_next_round := case when p_job.agent_role = 'source_discovery'
                         then v_plan.discovery_round else v_plan.control_round end + 1;

    for v_item in select value from jsonb_array_elements(p_result -> 'search_requests') loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_item) as k(value)
      where k.value not in ('rationale', 'platform', 'strategy', 'query_terms', 'filters_note');
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('En søkeforespørsel har felter denne kontrakten ikke kjenner: %s.', v_unknown);
      end if;

      v_platform := nullif(btrim(coalesce(v_item ->> 'platform', '')), '');
      if v_platform is not null and v_platform not in ('Europe PMC', 'PubMed', 'Crossref') then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('%L er ikke en søkeplattform Antidep kaller.', v_platform),
          hint = 'Plattformene er Europe PMC, PubMed og Crossref. En forespørsel kan ikke oppgi en adresse: en tjeneste ingen har vurdert, finnes ikke å be om (ANTIDEP_CONSTITUTION.md regel 7).';
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

      if not workflow.monograph_search_terms_shaped(v_terms) then
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
             v_platform, v_terms, v_item ->> 'filters_note',
             p_run_id, p_actor_id) is not null then
          v_requests := v_requests + 1;
        end if;
      end if;
    end loop;

    if v_paused then
      update workflow.monograph_search_plans
      set paused_at = now(),
          paused_reason = 'Søkebudsjettet for denne planversjonen er brukt opp: kildeleddet ba om flere maskinelle søkerunder enn de fire som er tillatt. Arbeidet står åpent og ventende, og det er ingen konklusjon om evidensen (SOURCE_POLICY.md §8.2).'
      where id = v_plan_id and paused_at is null and closed_at is null;
    elsif v_requests > 0 then
      update workflow.monograph_search_plans
      set discovery_round = case when p_job.agent_role = 'source_discovery'
                                 then v_next_round else discovery_round end,
          control_round = case when p_job.agent_role = 'source_quality_assessment'
                               then v_next_round else control_round end
      where id = v_plan_id;
    end if;
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
  if not v_paused and v_requests = 0 then
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
    'search_budget_exhausted', v_paused,
    'coverage_control_id', v_control_id,
    'search_coverage_closed', v_closed,
    'closure_problem', workflow.monograph_search_closure_problem(v_plan_id),
    'next_job_id', v_next_job);
end;
$function$;

comment on function workflow.record_monograph_discovery_answer(workflow.pipeline_jobs, jsonb, jsonb, uuid, uuid) is
  'Registrerer ett eksternt agentsvar fra kildeoppdagelsen eller den separate kontrollen av søkedekningen, under kontrakten migrasjon 013v innførte: leddet vurderer de maskinelt utførte søkene og kandidatene de ga, og ber om flere søk som strukturerte søkeforespørsler. Et svar som rapporterer utførte søk eller legger til en kandidatkilde, avvises med en setning som sier hvorfor — et ledd som ikke utfører søk, skal ikke ha en vei til å hevde at det gjorde det (SOURCE_POLICY.md §4.3). Kontrollens uavhengighet erklæres ikke lenger i svaret: den utledes av at Antidep faktisk har kjørt motsøkene under kontrollens egen rolle og kjøring (§6). En søkeforespørsel åpner en ny maskinell runde, og oppgaven kommer tilbake når runden er utført; er budsjettet på fire runder brukt opp, settes planen på pause som åpent, ventende arbeid og aldri som en konklusjon om evidensen (§8.2).';

revoke execute on function workflow.record_monograph_discovery_answer(workflow.pipeline_jobs, jsonb, jsonb, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 14. De oppgavene som allerede står ute
--
-- De ble bygget under den forrige kontrakten, og den ba agenten utføre søkene
-- selv. Den oppgaven er umulig for en kjører som bare har Antideps fem verktøy
-- — og den ble frigitt i produksjon med nøyaktig den begrunnelsen. Å la dem stå
-- som ventende arbeid ville vært å la produksjonen holde på en umulighet.
--
-- De foreldes derfor eksplisitt: jobben settes til `failed` med begrunnelsen
-- skrevet ut, overgangen føres i sporet, og en ny maskinell søkerunde åpnes for
-- hver åpne plan. Radene slettes ikke — sporet er append-only, og det skal være
-- det — men ingen kjører kan hente dem, og ingen flate viser dem som noe som
-- venter på en agent.
-- ----------------------------------------------------------------------------

do $$
declare
  v_actor uuid;
  v_job workflow.pipeline_jobs;
  v_stale integer := 0;
  v_opened integer := 0;
  v_plan uuid;
begin
  select a.id into v_actor
  from provenance.actors a where a.actor_key = 'human:peder-holman';

  if v_actor is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Grunnaktøren finnes ikke, og en foreldelse uten opphav ville vært arbeid ingen kan spore tilbake.';
  end if;

  for v_job in
    select j.*
    from workflow.pipeline_jobs j
    where j.agent_role in ('source_discovery'::provenance.agent_role,
                           'source_quality_assessment'::provenance.agent_role)
      and j.state in ('ready', 'leased')
    order by j.enqueued_at
  loop
    update workflow.pipeline_jobs
    set state = 'failed',
        leased_by_agent_identity_id = null,
        lease_expires_at = null,
        lease_token = null,
        completed_at = now(),
        failure_reason = 'Foreldet av migrasjon 013v: oppgaven ble bygget under den forrige kildekontrakten, som ba agenten utføre søkene selv. Søkene utføres nå av Antideps egen kode, og den semantiske oppgaven bygges på nytt når den maskinelle søkerunden er gjort.'
    where id = v_job.id;

    perform workflow.record_pipeline_job_event(
      v_job.id, v_job.state, 'failed'::workflow.pipeline_job_state, v_job.attempts,
      v_actor, null,
      'Foreldet av den nye kildekontrakten: søke-I/O er Antideps deterministiske kode.');

    v_stale := v_stale + 1;
  end loop;

  -- Og den maskinelle søkefasen åpnes for hver åpen plan. Den semantiske
  -- oppgaven legges inn av `api.close_monograph_search_request(...)` når
  -- kjøringen har søkt — ikke her.
  for v_plan in
    select p.id
    from workflow.monograph_search_plans p
    join knowledge.monograph_editions e on e.id = p.edition_id
    where p.closed_at is null
      and p.paused_at is null
      and e.superseded_at is null
    order by p.created_at
  loop
    if workflow.chain_task_for_search_plan(v_plan) is null then
      v_opened := v_opened + 1;
    end if;
  end loop;

  raise notice 'Migrasjon 013v: % foreldede kildeoppgaver lukket, % søkeplaner har fått en maskinell søkerunde.',
    v_stale, v_opened;
end;
$$;

-- ----------------------------------------------------------------------------
-- 15. Og en siste kontroll: ingen åpen plan står uten en maskinell søkefase
--
-- En plan uten en runde ville vært et spørsmål ingen hadde begynt å svare på,
-- og den ville stått stille uten at noe sa fra.
-- ----------------------------------------------------------------------------

do $$
declare
  v_missing integer;
begin
  select count(*) into v_missing
  from workflow.monograph_search_plans p
  join knowledge.monograph_editions e on e.id = p.edition_id
  where p.closed_at is null
    and p.paused_at is null
    and e.superseded_at is null
    and not exists (
      select 1 from workflow.monograph_search_requests r
      where r.plan_id = p.id
        and r.plan_version = p.plan_version
        and r.requested_for_role = 'source_discovery'::provenance.agent_role);

  if v_missing > 0 then
    raise exception using
      errcode = 'no_data_found',
      message = format('%s åpne søkeplaner står uten en maskinell søkerunde.', v_missing),
      hint = 'Uten en runde ville planen stått stille: den semantiske oppgaven finnes ikke før søkene er utført, og søkene utføres ikke før noen har bedt om dem.';
  end if;
end;
$$;
