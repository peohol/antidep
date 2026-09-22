-- ---------------------------------------------------------------------------
-- Migrasjon 013x — hva Antidep faktisk kan søke i, som et registrert faktum
--
-- Hva som var galt
--
-- 013v gjorde to riktige ting som til sammen ga én gal virkning.
--
-- Den beholdt skjæringen i `runSearch`: et søk kan bare erklære de sporene
-- plattformen faktisk dekker. Og den ga søkerunden hele kildeprofilens
-- obligatoriske spor som tillatelse. Men alle tre plattformene Antidep kaller —
-- Europe PMC, PubMed og Crossref — dekker bare `bibliographic_database`.
--
-- Samtidig fjernet 013v den eneste veien de øvrige sporene noen gang ble dekket
-- på: at modellen rapporterte søkene selv. Den fjerningen var riktig — modellen
-- har ingen nettilgang og skal ikke påstå at den har søkt — men den etterlot
-- ingenting i stedet.
--
-- Virkningen, målt over alle tretten kildeprofilene: *ingen* av dem kunne lenger
-- nå ferdig søkedekning. EFF og AE manglet fem av seks obligatoriske spor. REG,
-- PROD og SYN hadde ikke ett eneste utførbart spor, og kunne dermed heller ikke
-- passere kravet om at minst ett søk faktisk må ha gått.
--
-- `workflow.monograph_search_closure_problem` nektet — med rette — å lukke en
-- plan med et `pending` spor. Men den nektet stille, i en tekststreng ingen
-- hadde i oppgave å lese, og uten noen vei videre. Etter fire runder kunne
-- planen bare ende på pause. Det er ikke en ærlig begrensning; det er en
-- blindvei.
--
-- Og hullet som skjulte det
--
-- Skjæringen lå bare i TypeScript. Basen tok imot de sporene et søk sa at det
-- dekket, og prøvde bare dem mot *runden*. Derfor kunne prøve 870 registrere et
-- Europe PMC-søk som erklærte `systematic_review_search` — et spor kjøreren
-- aldri kan produsere — og hele kjeden så dekket ut i en prøve mens den sto
-- stille i produksjon. En regel som bare finnes i kallerens kode, er ikke en
-- regel; den er en vane.
--
-- Hva denne migrasjonen gjør
--
-- Den gjør plattformenes evne til en rad. `knowledge.monograph_search_platforms`
-- sier hvilke obligatoriske søkespor hver plattform Antidep kaller, faktisk kan
-- dekke. Derfra følger alt annet:
--
--   * `record_monograph_machine_search` avviser et søk som erklærer et spor
--     plattformen ikke dekker — skjæringen er nå håndhevet der den betyr noe,
--     og ikke bare der den var lett å skrive.
--   * De obligatoriske sporene ingen registrert plattform dekker, settes til
--     `no_machine_path` når runden lukkes: dokumentert, men ikke forsøkt.
--     Porten slipper dem aldri gjennom som dekning — det ville vært
--     hvitvasking av manglende søk — men den sier nå nøyaktig hvilke spor det
--     gjelder, og at de krever et menneske.
--   * En redaktør kan registrere utfallet av søket hun faktisk har gjort, og da
--     går planen videre.
--
-- Retningen er selvhelbredende: registreres en ny plattform med et nytt spor,
-- flyttes sporet tilbake til `pending` ved neste rundelukking, og den maskinelle
-- veien overtar uten at noen må rydde.
-- ---------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 1. Registeret: hva hver søkevei faktisk kan dekke
-- ----------------------------------------------------------------------------

create table knowledge.monograph_search_platforms (
  id uuid primary key default gen_random_uuid(),

  platform text not null,
  track_code text not null,

  created_at timestamptz not null default now(),

  constraint monograph_search_platforms_pair_key unique (platform, track_code),
  constraint monograph_search_platforms_platform_shape_check
    check (platform = btrim(platform) and length(platform) between 2 and 80),
  constraint monograph_search_platforms_track_shape_check
    check (track_code ~ '^[a-z][a-z0-9_]*$')
);

comment on table knowledge.monograph_search_platforms is
  'Hvilke obligatoriske søkespor hver søkevei Antidep faktisk kaller, kan dekke (SOURCE_POLICY.md §4.2). Speiler SEARCH_PLATFORMS i src/ops/monograph-search.ts, og er den siden av speilet porten hviler på: et søk kan ikke erklære et spor plattformen ikke står oppført med, og et obligatorisk spor ingen plattform dekker, kan ikke bli dekket av å vente. Uten raden lå skjæringen bare i kallerens kode, og en prøve kunne bestå ved å erklære spor kjøreren aldri kan produsere.';

alter table knowledge.monograph_search_platforms enable row level security;

create trigger monograph_search_platforms_set_created_at
  before insert or update on knowledge.monograph_search_platforms
  for each row execute function catalog.set_created_at();

-- Lesbar for de påloggede: oppgavefilen viser hvilke søkeveier en runde kan be
-- om, og hva hver av dem kan dekke.
create policy monograph_search_platforms_read on knowledge.monograph_search_platforms
  for select to authenticated using (true);

insert into knowledge.monograph_search_platforms (platform, track_code) values
  ('Europe PMC', 'bibliographic_database'),
  ('PubMed', 'bibliographic_database'),
  ('Crossref', 'bibliographic_database');

create function knowledge.monograph_executable_track_codes()
  returns text[]
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(array_agg(distinct p.track_code order by p.track_code),
                  array[]::text[])
  from knowledge.monograph_search_platforms p;
$$;

comment on function knowledge.monograph_executable_track_codes() is
  'Søkesporene Antideps deterministiske kode faktisk kan utføre, utledet av de registrerte søkeveiene. Aldri en skrevet liste: en liste ved siden av registeret ville kunne påstå at Antidep dekker et spor ingen søkevei søker i, og porten ville trodd på påstanden.';

-- Ingen klientrolle. Funksjonen leses fra innsiden av SECURITY DEFINER-veiene,
-- og en direkte inngang ville vært en flate til uten et spørsmål bak seg.
revoke execute on function knowledge.monograph_executable_track_codes() from public;

-- ----------------------------------------------------------------------------
-- 2. Raden: en fjerde tilstand, og hvem som eventuelt løste sporet
-- ----------------------------------------------------------------------------

comment on type workflow.monograph_track_state is
  'Om et obligatorisk søkespor er forsøkt (SOURCE_POLICY.md §4.2): pending (ikke forsøkt ennå), covered (et dokumentert søk dekker det), unavailable (sporet ble forsøkt, men søkeveien svarte ikke) eller no_machine_path (ingen registrert søkevei dekker sporet i det hele tatt). De to siste er ikke det samme: unavailable er forbigående og prøves på nytt, no_machine_path blir ikke bedre av et nytt forsøk og krever et menneske. Et pending eller no_machine_path spor hindrer at søkedekningen kan erklæres ferdig; et unavailable spor gjør det ikke, men står som en synlig begrensning i utkastet framfor å bli borte.';

-- Hvem som løste sporet, når det var et menneske. Uten kolonnen ville en
-- redaktørs registrerte utfall og en søkevei som ikke svarte, vært den samme
-- raden med to forskjellige notater — og forskjellen ville ligget i tekst
-- framfor i struktur.
alter table workflow.monograph_search_track_attempts
  add column resolved_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict;

comment on column workflow.monograph_search_track_attempts.resolved_by_actor_id is
  'Redaktøren som registrerte utfallet av sporet for hånd, når ingen registrert søkevei dekker det. NULL for alt maskinen selv registrerte. Skillet er strukturelt og ikke tekstlig: «en tjeneste svarte ikke» og «et menneske har gjort søket og registrert hva det ga» er to forskjellige fakta om dekningen.';

alter table workflow.monograph_search_track_attempts
  drop constraint monograph_search_track_attempts_state_shape_check;

alter table workflow.monograph_search_track_attempts
  add constraint monograph_search_track_attempts_state_shape_check
    check (
      case state
        when 'pending' then
          search_id is null and note is null and resolved_by_actor_id is null
        -- Et dekket spor peker på søket som dekket det. Uten kravet kunne
        -- sporet blitt erklært dekket uten at et søk fantes.
        when 'covered' then search_id is not null
        -- Et utilgjengelig spor har en registrert begrensning og ikke et søk.
        when 'unavailable' then search_id is null and note is not null
        -- Et spor uten maskinell søkevei har en registrert begrunnelse, ikke et
        -- søk, og ingen som har løst det: gjør en redaktør det, er utfallet
        -- enten covered eller unavailable.
        when 'no_machine_path' then
          search_id is null and note is not null and resolved_by_actor_id is null
        else false
      end
    );

-- ----------------------------------------------------------------------------
-- 3. Skjæringen, håndhevet der den betyr noe
-- ----------------------------------------------------------------------------

create function workflow.assert_search_tracks_within_platform(
  p_platform text,
  p_track_codes text[]
)
  returns void
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_known boolean;
  v_outside text;
begin
  if cardinality(coalesce(p_track_codes, array[]::text[])) = 0 then
    return;
  end if;

  select exists (
    select 1 from knowledge.monograph_search_platforms p
    where p.platform = btrim(p_platform)
  ) into v_known;

  if not v_known then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%L er ikke en registrert søkevei.', p_platform),
      hint = 'Et søk kan bare erklære et obligatorisk søkespor når søkeveien står i knowledge.monograph_search_platforms. En søkevei ingen har vurdert, kan ikke dekke et krav (ANTIDEP_CONSTITUTION.md regel 7).';
  end if;

  select string_agg(w.code, ', ' order by w.code) into v_outside
  from unnest(p_track_codes) as w(code)
  where not exists (
    select 1 from knowledge.monograph_search_platforms p
    where p.platform = btrim(p_platform) and p.track_code = w.code
  );

  if v_outside is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Søket erklærer søkespor %s dekker ikke: %s.', btrim(p_platform), v_outside),
      hint = 'Hva en søkevei kan dekke, er registrert i knowledge.monograph_search_platforms. Et bibliografisk søk som erklærte forsøksregistre dekket, ville gjort porten blind for spor ingen hadde søkt i (SOURCE_POLICY.md §4.2).';
  end if;
end;
$$;

comment on function workflow.assert_search_tracks_within_platform(text, text[]) is
  'Avviser et søk som erklærer et obligatorisk søkespor søkeveien ikke er registrert for. Skjæringen fantes i src/ops/monograph-search.ts fra før; her er den håndhevet. En regel som bare finnes i kallerens kode, er en vane og ikke en regel: uten denne kunne en prøve bestå ved å erklære spor den virkelige kjøringen aldri kan produsere.';

revoke execute on function workflow.assert_search_tracks_within_platform(text, text[]) from public;

-- ----------------------------------------------------------------------------
-- 4. Sporene ingen søkevei dekker
-- ----------------------------------------------------------------------------

create function workflow.mark_tracks_without_machine_path(p_plan_id uuid)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_edition knowledge.monograph_editions;
  v_executable text[] := knowledge.monograph_executable_track_codes();
  v_marked integer := 0;
  v_freed integer := 0;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;
  if not found then
    return 0;
  end if;

  select e.* into v_edition
  from knowledge.monograph_editions e where e.id = v_plan.edition_id;

  -- Et obligatorisk spor ingen registrert søkevei dekker, blir ikke dekket av å
  -- vente. Det merkes med én gang, med en begrunnelse som sier hva Antidep
  -- faktisk kan søke i — ikke bare at noe manglet.
  update workflow.monograph_search_track_attempts a
  set state = 'no_machine_path',
      search_id = null,
      resolved_by_actor_id = null,
      note = format(
        'Ingen av Antideps registrerte søkeveier dekker dette sporet. Maskinelt utførbare spor er nå: %s. Sporet krever at en redaktør gjør og registrerer søket.',
        case when cardinality(v_executable) = 0
             then 'ingen'
             else array_to_string(v_executable, ', ') end)
  where a.plan_id = p_plan_id
    and a.state = 'pending'
    and a.track_id in (
      select k.id from knowledge.monograph_search_tracks k
      where k.standard_version = v_edition.standard_version
        and not (k.code = any (v_executable)));

  get diagnostics v_marked = row_count;

  -- Og motsatt vei. Registreres en søkevei for sporet senere, skal sporet
  -- tilbake i den maskinelle køen av seg selv. Uten dette ville en ny plattform
  -- krevd en opprydding ingen hadde i oppgave å gjøre, og sporene ville blitt
  -- liggende som en begrensning som ikke lenger var sann.
  update workflow.monograph_search_track_attempts a
  set state = 'pending', search_id = null, note = null, resolved_by_actor_id = null
  where a.plan_id = p_plan_id
    and a.state = 'no_machine_path'
    and a.track_id in (
      select k.id from knowledge.monograph_search_tracks k
      where k.standard_version = v_edition.standard_version
        and k.code = any (v_executable));

  get diagnostics v_freed = row_count;

  return v_marked + v_freed;
end;
$$;

comment on function workflow.mark_tracks_without_machine_path(uuid) is
  'Fører hvilke av planens obligatoriske søkespor ingen registrert søkevei kan dekke. Et spor utenfor registeret settes fra pending til no_machine_path med en begrunnelse; et spor som er kommet innenfor igjen, settes tilbake til pending slik at den maskinelle veien overtar uten opprydding. Rører aldri covered eller unavailable: et utført søk og en registrert begrensning er historiske fakta.';

revoke execute on function workflow.mark_tracks_without_machine_path(uuid) from public;

-- Håndhevet på raden og ikke i én kaller. Et søk registreres av
-- `api.record_monograph_machine_search(...)`, av `workflow.record_monograph_search(...)`
-- og av redaksjonelle veier; en regel som bare lå i den første, ville vært
-- omgåelig fra de to andre — og fra en prøve.
create function workflow.enforce_search_track_platform() returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  perform workflow.assert_search_tracks_within_platform(new.platform, new.track_codes);
  return new;
end;
$$;

comment on function workflow.enforce_search_track_platform() is
  'Avviser et registrert søk som erklærer et obligatorisk søkespor søkeveien ikke er registrert for. Ligger på tabellen framfor i én kaller, slik at regelen gjelder alle veier inn.';

revoke execute on function workflow.enforce_search_track_platform() from public;

create trigger monograph_searches_enforce_track_platform
  before insert or update of track_codes, platform on workflow.monograph_searches
  for each row execute function workflow.enforce_search_track_platform();

-- Sporet er ærlig fra planen opprettes, ikke først når en runde er lukket. Et
-- obligatorisk spor ingen registrert søkevei dekker, kommer aldri til å bli
-- forsøkt maskinelt, og å la det stå som `pending` i mellomtiden ville vært å
-- si «ikke forsøkt ennå» om noe som aldri blir forsøkt.
create function workflow.set_track_machine_path() returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_code text;
  v_executable text[] := knowledge.monograph_executable_track_codes();
begin
  if new.state <> 'pending' then
    return new;
  end if;

  select k.code into v_code
  from knowledge.monograph_search_tracks k where k.id = new.track_id;

  if v_code is not null and not (v_code = any (v_executable)) then
    new.state := 'no_machine_path';
    new.search_id := null;
    new.resolved_by_actor_id := null;
    new.note := format(
      'Ingen av Antideps registrerte søkeveier dekker dette sporet. Maskinelt utførbare spor er nå: %s. Sporet krever at en redaktør gjør og registrerer søket.',
      case when cardinality(v_executable) = 0
           then 'ingen'
           else array_to_string(v_executable, ', ') end);
  end if;

  return new;
end;
$$;

comment on function workflow.set_track_machine_path() is
  'Setter et nytt obligatorisk søkespor til no_machine_path med én gang, når ingen registrert søkevei dekker det. Uten dette ville sporet stått som «ikke forsøkt ennå» fram til en runde ble lukket — en formulering som var usann fra første stund, fordi sporet aldri kom til å bli forsøkt maskinelt.';

revoke execute on function workflow.set_track_machine_path() from public;

create trigger monograph_search_track_attempts_set_machine_path
  before insert on workflow.monograph_search_track_attempts
  for each row execute function workflow.set_track_machine_path();

-- ----------------------------------------------------------------------------
-- 5. Porten: et spor uten maskinell vei er ikke dekning, og ikke en stillhet
-- ----------------------------------------------------------------------------

create or replace function workflow.monograph_search_closure_problem(p_plan_id uuid)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_profile text;
  v_pending text;
  v_no_path text;
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

  -- 1. Planen skal dekke minst ett behov.
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
      'Ingen av Antideps registrerte søkeveier dekker disse obligatoriske søkesporene: %s. Sporet er dokumentert, men ikke forsøkt, og et forsøk som ikke er gjort, kan ikke telle som dekning. En redaktør registrerer utfallet med api.record_monograph_track_by_editor(...) — enten søket hun har gjort, eller hvorfor sporet ikke var tilgjengelig (SOURCE_POLICY.md §4.2).',
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

  -- 4. Ingen skjult treffavkorting.
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
  if v_profile not in ('REG', 'PROD') then
    select max(s.registration_ordinal) into v_last_candidate_ordinal
    from workflow.monograph_searches s
    join workflow.monograph_candidate_sources c on c.search_id = s.id
    where c.plan_id = p_plan_id;

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
  'Én setning om hva som hindrer at søkedekningen kan erklæres ferdig, eller NULL. Er de konkrete stoppkravene i SOURCE_POLICY.md §8.1 som en port: planen må dekke et behov, hvert obligatorisk søkespor må være forsøkt og dokumentert, spor ingen registrert søkevei dekker må være avklart av en redaktør, minst ett søk må faktisk ha gått, ingen avkortet treffliste kan stå igjen udekket, ingen uavklart kilde som kan endre hovedkonklusjonen kan stå åpen, metningssignalet må være gitt — unntatt for de autoritative regulatoriske profilene, der én gjeldende kilde kan være nok — og den separate dekningskontrollen må godta begrunnelsen. Et oppbrukt arbeidsbudsjett gir åpent arbeid og aldri en ferdig dekning (§8.2). Porten kan ikke overstyres: verken tre funne artikler, to enige agenter, ti gjennomgåtte treff eller et brukt budsjett er en av kravene.';

-- ----------------------------------------------------------------------------
-- 6. Rundelukkingen fører sporene ingen søkevei dekker
-- ----------------------------------------------------------------------------

create or replace function api.close_monograph_search_request(
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

  -- Sporene ingen registrert søkevei dekker. Bare generatorens runder fører
  -- spor: dekningskontrollens motsøk kan strukturelt ikke dekke noen (§6).
  if v_identity.agent_role = 'source_discovery' then
    perform workflow.mark_tracks_without_machine_path(v_request.plan_id);
  end if;

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
    'closure_problem', workflow.monograph_search_closure_problem(v_request.plan_id),
    'phase_problem', workflow.monograph_search_phase_problem(
      v_request.plan_id, v_identity.agent_role));
end;
$$;

comment on function api.close_monograph_search_request(text, text, uuid, text) is
  'Lukker én maskinell søkerunde etter at kjøringen har registrert søkene sine, og legger den semantiske vurderingsoppgaven i køen når runden var den siste som sto åpen. Tilstanden utledes av søkeloggen og ikke av det kjøringen sier om seg selv: gikk minst ett søk, er runden utført; nådde ingen fram, er den utilgjengelig — som prøves på nytt, men som ikke holder den semantiske oppgaven tilbake, fordi en tjeneste som er nede, ikke skal kunne stanse arbeidet for alltid (SOURCE_POLICY.md §8.2). Etter tre forsøk står begrensningen, og runden er gitt opp framfor å vokse. Generatorens runde fører samtidig de obligatoriske søkesporene ingen registrert søkevei dekker, som no_machine_path: de er aldri dekning, og de blir ikke stående som en stille blokkering. Krever kildeleddets egen identitet, legitimasjon og en åpen kjøring som tilhører den. SECURITY DEFINER fordi workflow har RLS med default deny.';

-- ----------------------------------------------------------------------------
-- 7. Redaktørens vei ut: sporet et menneske faktisk har håndtert
-- ----------------------------------------------------------------------------

create function api.record_monograph_track_by_editor(
  p_plan_reference text,
  p_track_code text,
  p_outcome text,
  p_note text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_plan workflow.monograph_search_plans;
  v_edition knowledge.monograph_editions;
  v_track_id uuid;
  v_attempt workflow.monograph_search_track_attempts;
  v_search_id uuid;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if p_outcome not in ('covered', 'unavailable') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%L er ikke et utfall for et søkespor.', p_outcome),
      hint = 'En redaktør registrerer enten covered — søket er gjort, og det finnes en registrert søkepassering på planen å knytte sporet til — eller unavailable, med begrunnelsen for hvorfor sporet ikke kunne dekkes. Et spor kan ikke settes tilbake til pending for hånd: registeret over søkeveier avgjør selv om en maskinell vei finnes.';
  end if;

  if p_note is null or length(btrim(p_note)) < 20 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et søkespor avklart for hånd krever en begrunnelse på minst 20 tegn.',
      hint = 'Begrunnelsen er det eneste sporet av hva mennesket faktisk gjorde. «ok» dokumenterer ingenting.';
  end if;

  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.reference = p_plan_reference
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen finnes ikke.';
  end if;

  select e.* into v_edition
  from knowledge.monograph_editions e where e.id = v_plan.edition_id;

  select k.id into v_track_id
  from knowledge.monograph_search_tracks k
  where k.standard_version = v_edition.standard_version and k.code = p_track_code;

  if v_track_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('%L er ikke et søkespor i denne standardversjonen.', p_track_code);
  end if;

  select a.* into v_attempt
  from workflow.monograph_search_track_attempts a
  where a.plan_id = v_plan.id and a.track_id = v_track_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Sporet er ikke obligatorisk for denne planens kildeprofil.';
  end if;

  -- Bare spor uten maskinell vei. Et spor maskinen kan søke i, skal maskinen
  -- søke i: en redaktør som kunne erklære hvilket som helst spor dekket, ville
  -- vært en vei rundt hele den maskinelle søkefasen.
  if v_attempt.state <> 'no_machine_path' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Sporet står som %s og trenger ingen avklaring for hånd.', v_attempt.state),
      hint = 'Redaktørens vei gjelder bare spor ingen registrert søkevei dekker. Et pending spor venter på den maskinelle søkefasen, og et covered eller unavailable spor er allerede ført.';
  end if;

  if p_outcome = 'covered' then
    -- «Dekket» krever en registrert søkepassering på planen, som for alt annet
    -- dekket. Uten kravet ville en setning vært nok til å erklære et spor
    -- dekket, og porten ville hvilt på en påstand framfor på en søkelogg.
    select s.id into v_search_id
    from workflow.monograph_searches s
    where s.plan_id = v_plan.id
      and s.plan_version = v_plan.plan_version
      and s.outcome in ('executed', 'zero_results')
    order by s.registration_ordinal desc
    limit 1;

    if v_search_id is null then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Planen har ingen registrert søkepassering å knytte sporet til.',
        hint = 'Et dekket spor peker alltid på et søk. Er søket gjort utenfor Antidep, registreres funnene først, og sporet avklares deretter — eller sporet føres som unavailable med begrunnelsen.';
    end if;

    update workflow.monograph_search_track_attempts
    set state = 'covered', search_id = v_search_id, note = btrim(p_note),
        resolved_by_actor_id = v_actor_id
    where id = v_attempt.id;
  else
    update workflow.monograph_search_track_attempts
    set state = 'unavailable', search_id = null, note = btrim(p_note),
        resolved_by_actor_id = v_actor_id
    where id = v_attempt.id;
  end if;

  return jsonb_build_object(
    'plan_reference', v_plan.reference,
    'track_code', p_track_code,
    'state', p_outcome,
    'closure_problem', workflow.monograph_search_closure_problem(v_plan.id));
end;
$$;

comment on function api.record_monograph_track_by_editor(text, text, text, text) is
  'Lar en redaktør registrere utfallet av et obligatorisk søkespor ingen av Antideps registrerte søkeveier dekker. Gjelder bare spor som står som no_machine_path: et spor maskinen kan søke i, skal maskinen søke i, og en vei rundt den maskinelle søkefasen ville gjort hele fasen valgfri. Utfallet er covered — som krever en registrert søkepassering på planen, akkurat som alt annet dekket — eller unavailable med en begrunnelse. Begrunnelsen er obligatorisk og er det eneste sporet av hva mennesket faktisk gjorde. Krever editor-mandat, og aktøren føres på raden, slik at «en redaktør har håndtert dette» og «en tjeneste svarte ikke» forblir to forskjellige fakta.';

revoke execute on function api.record_monograph_track_by_editor(text, text, text, text) from public;
grant execute on function api.record_monograph_track_by_editor(text, text, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 8. De åpne planene, ført med én gang
-- ----------------------------------------------------------------------------

-- Uten dette ville sporene først blitt ført ved neste rundelukking, og en plan
-- med en runde som allerede er lukket, ville stått med `pending` spor ingen
-- kommer tilbake til. Porten leser den samme funksjonen uansett, så raden skal
-- være sann fra nå.
do $$
declare
  v_plan_id uuid;
  v_total integer := 0;
begin
  for v_plan_id in
    select p.id
    from workflow.monograph_search_plans p
    join knowledge.monograph_editions e on e.id = p.edition_id
    where p.closed_at is null and e.superseded_at is null
  loop
    v_total := v_total + workflow.mark_tracks_without_machine_path(v_plan_id);
  end loop;

  raise notice 'Migrasjon 013x: % søkespor ført mot registeret over søkeveier.', v_total;
end;
$$;
