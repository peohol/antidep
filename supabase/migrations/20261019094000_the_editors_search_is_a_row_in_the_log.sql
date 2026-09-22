-- ---------------------------------------------------------------------------
-- Migrasjon 013z — redaktørens passering er en rad i søkeloggen
--
-- Hva som var galt i 013x
--
-- 013x ga redaktøren en vei til å avklare de obligatoriske søkesporene ingen
-- registrert søkevei dekker. Veien hadde to feil, og de hang sammen.
--
-- 1. Den dokumenterte ikke søket. `covered` knyttet sporet til den *siste*
--    `executed`/`zero_results`-raden på planen, uansett hvilket spor den raden
--    gjaldt. Et manuelt oversiktssøk i Epistemonikos ble dermed ført som dekket
--    ved å peke på et tidligere Europe PMC-søk. Søkeloggen sa at sporet var
--    dekket av en passering som aldri gjaldt det, og SOURCE_POLICY.md §4.3
--    krever nettopp plattform, eksakt søkestreng, filtre, tidspunkt og
--    treffantall for det *utførte* søket. Proveniensen var misvisende.
--
-- 2. Den nådde ikke fram for profilene som trengte den mest. REG, PROD og SYN
--    har ikke ett eneste maskinelt utførbart søkespor. `covered` krevde en
--    eksisterende søkepassering, og stoppkravet krever uansett at minst ett søk
--    faktisk har gått — men ingen maskinell passering kommer noen gang til å gå
--    for dem. Veien ut var derfor stengt for nøyaktig de profilene som ikke har
--    noen annen.
--
-- Begge løses av det samme: redaktørens passering registreres som en egen, sann
-- rad i søkeloggen, med `editor_recorded` som utførelsesbevis (013y), og sporet
-- knyttes til nøyaktig den raden. Da er det dokumentert hva som faktisk ble
-- gjort, og et søk som faktisk gikk, finnes for de tre profilene også.
--
-- Skillet er skjerpet og ikke myket opp: en menneskelig passering har verken
-- endepunkt eller responsavtrykk, og den kan ikke lenger låne et navn som lyver
-- om hvem som utførte den. Registeret over søkeveier begrenser fortsatt
-- maskinen — og bare maskinen. Et menneske kan søke der Antidep ikke kan, og
-- står oppført på raden for det.
--
-- Og metningssignalet, som var uriktig for SYN
--
-- §8.1 bruker to supplerende søkepasseringer som metningssignal. Unntaket var
-- skrevet som profilkodene `REG` og `PROD`. Men signalet handler om
-- litteratursøk, og §4.2 sier uttrykkelig at sammendragsleddet SYN ikke gjør
-- noen selvstendig litteraturjakt. SYN kunne derfor aldri nå ferdig dekning —
-- ikke fordi noe manglet, men fordi et krav om søkepasseringer ble stilt til et
-- ledd som ikke søker. Unntaket utledes nå av profilens egne obligatoriske
-- spor: krever den et bibliografisk søk, gjelder metningssignalet. Det gir
-- nøyaktig REG, PROD og SYN som unntak i dag, og det holder seg selv oppdatert.
-- ---------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 1. Formen på et søk redaktøren selv utførte
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
      -- Et menneske har ingen kjøring, og det Antidep ikke utførte, har verken
      -- endepunkt eller responsavtrykk å vise til. Å tillate dem ville vært å
      -- la en menneskelig passering se ut som et maskinelt bekreftet kall.
      when 'editor_recorded' then
        evidence_endpoint is null and response_digest is null
        and agent_run_id is null
      else false
    end
  );

comment on column workflow.monograph_searches.execution_evidence is
  'Hvilket utførelsesbevis Antidep har: agent_reported er agentens egen beretning om et verktøykall, machine_executed er Antideps eget kall med endepunktet og responsavtrykket som bevis, og editor_recorded er en søkepassering en redaktør selv utførte og registrerte. Skillet er håndhevet av raden og ikke av en konvensjon, slik at verken en agents erklæring eller et menneskes arbeid kan omtales som maskinelt bekreftet utførelse. Et maskinelt utført søk har alltid et endepunkt, og et responsavtrykk når det kom et svar å ta avtrykk av (013v). Et redaktørregistrert søk har ingen av delene, og ingen kjøring: det er et menneskes dokumenterte arbeid, ikke et kall Antidep kan gjenta (013z).';

-- ----------------------------------------------------------------------------
-- 2. Registeret begrenser maskinen, og bare maskinen
-- ----------------------------------------------------------------------------

create or replace function workflow.enforce_search_track_platform() returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_actor_type provenance.actor_type;
begin
  -- Registeret sier hva Antideps *deterministiske kode* kan dekke. Et menneske
  -- kan søke der Antidep ikke kan — det er hele grunnen til at veien finnes —
  -- og å måle en menneskelig passering mot maskinens register ville stengt den
  -- igjen. Ansvarligheten ligger i stedet på raden: aktøren står der, og
  -- api.record_monograph_track_by_editor krever editor-mandat.
  if new.execution_evidence = 'machine_executed' then
    perform workflow.assert_search_tracks_within_platform(new.platform, new.track_codes);
  end if;

  if new.execution_evidence = 'editor_recorded' then
    select a.actor_type into v_actor_type
    from provenance.actors a where a.id = new.recorded_by_actor_id;

    if v_actor_type is distinct from 'human'::provenance.actor_type then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Et redaktørregistrert søk må være registrert av et menneske.',
        hint = 'editor_recorded er et menneskes dokumenterte arbeid. En agent som kunne skrive det, ville hatt en vei til å erklære et søk uten hverken kjøring eller endepunkt.';
    end if;
  end if;

  return new;
end;
$$;

comment on function workflow.enforce_search_track_platform() is
  'Avviser et maskinelt utført søk som erklærer et obligatorisk søkespor søkeveien ikke er registrert for, og et redaktørregistrert søk som ikke er registrert av et menneske. Ligger på tabellen framfor i én kaller, slik at regelen gjelder alle veier inn. Registeret måler maskinen og ikke mennesket: et menneske kan søke der Antidep ikke kan, og står oppført på raden for det.';

drop trigger monograph_searches_enforce_track_platform on workflow.monograph_searches;

create trigger monograph_searches_enforce_track_platform
  before insert or update of track_codes, platform, execution_evidence,
                             recorded_by_actor_id
  on workflow.monograph_searches
  for each row execute function workflow.enforce_search_track_platform();

-- ----------------------------------------------------------------------------
-- 3. Metningssignalet gjelder de profilene som faktisk søker i litteraturen
-- ----------------------------------------------------------------------------

create function workflow.monograph_profile_searches_literature(p_profile_id uuid)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select exists (
    select 1
    from knowledge.monograph_search_track_profiles kp
    join knowledge.monograph_search_tracks k on k.id = kp.track_id
    where kp.profile_id = p_profile_id
      and k.code = 'bibliographic_database'
  );
$$;

comment on function workflow.monograph_profile_searches_literature(uuid) is
  'Om kildeprofilen i det hele tatt gjør litteratursøk, utledet av om et bibliografisk søk er et av dens obligatoriske søkespor (SOURCE_POLICY.md §4.2). Metningssignalet i §8.1 er to supplerende søkepasseringer, og det gir bare mening for et ledd som søker: de autoritative regulatoriske profilene kan klare seg med én riktig, gjeldende kilde, og sammendragsleddet gjør ingen selvstendig litteraturjakt. Utledet framfor skrevet som en liste profilkoder, slik at unntaket ikke kan bli stående igjen når profilene endres.';

revoke execute on function workflow.monograph_profile_searches_literature(uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Porten, med metningssignalet stilt til det leddet faktisk gjør
-- ----------------------------------------------------------------------------

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
  --    Gjelder de profilene som faktisk søker i litteraturen. De autoritative
  --    regulatoriske profilene kan klare seg med én riktig, gjeldende kilde, og
  --    sammendragsleddet gjør ingen selvstendig litteraturjakt (§4.2, §8.1) —
  --    å kreve to søkepasseringer av et ledd som ikke søker, er et krav som
  --    aldri kan oppfylles.
  if workflow.monograph_profile_searches_literature(v_plan.profile_id) then
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
  'Én setning om hva som hindrer at søkedekningen kan erklæres ferdig, eller NULL. Er de konkrete stoppkravene i SOURCE_POLICY.md §8.1 som en port: planen må dekke et behov, hvert obligatorisk søkespor må være forsøkt og dokumentert, spor ingen registrert søkevei dekker må være avklart av en redaktør, minst ett søk må faktisk ha gått, ingen avkortet treffliste kan stå igjen udekket, ingen uavklart kilde som kan endre hovedkonklusjonen kan stå åpen, metningssignalet må være gitt — for de profilene som faktisk søker i litteraturen — og den separate dekningskontrollen må godta begrunnelsen. Et oppbrukt arbeidsbudsjett gir åpent arbeid og aldri en ferdig dekning (§8.2). Porten kan ikke overstyres: verken tre funne artikler, to enige agenter, ti gjennomgåtte treff eller et brukt budsjett er en av kravene.';

-- ----------------------------------------------------------------------------
-- 5. Redaktørens vei ut, som dokumenterer søket den bygger på
-- ----------------------------------------------------------------------------

drop function api.record_monograph_track_by_editor(text, text, text, text);

create function api.record_monograph_track_by_editor(
  p_plan_reference text,
  p_track_code text,
  p_outcome text,
  p_note text,
  p_platform text default null,
  p_query_string text default null,
  p_filters text default null,
  p_executed_at timestamptz default null,
  p_result_count integer default null,
  p_screened_count integer default null,
  p_truncated boolean default false,
  p_truncation_note text default null
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
  v_outcome workflow.monograph_search_outcome;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if p_outcome not in ('covered', 'unavailable') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%L er ikke et utfall for et søkespor.', p_outcome),
      hint = 'En redaktør registrerer enten covered — søket er gjort, og passeringen føres i søkeloggen sammen med sporet — eller unavailable, med begrunnelsen for hvorfor sporet ikke kunne dekkes. Et spor kan ikke settes tilbake til pending for hånd: registeret over søkeveier avgjør selv om en maskinell vei finnes.';
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

  if v_plan.closed_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Søkeplanen er erklært ferdig, og søkeloggen står.';
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

  if p_outcome = 'unavailable' then
    update workflow.monograph_search_track_attempts
    set state = 'unavailable', search_id = null, note = btrim(p_note),
        resolved_by_actor_id = v_actor_id
    where id = v_attempt.id;

    return jsonb_build_object(
      'plan_reference', v_plan.reference,
      'track_code', p_track_code,
      'state', 'unavailable',
      'search_recorded', false,
      'closure_problem', workflow.monograph_search_closure_problem(v_plan.id));
  end if;

  -- «Dekket» er nå en dokumentert passering og ikke en peker til en tilfeldig
  -- eksisterende rad. SOURCE_POLICY.md §4.3 krever plattform, eksakt
  -- søkestreng, filtre, tidspunkt og treffantall for det *utførte* søket — og
  -- før 013z pekte veien på den siste raden på planen uansett hvilket spor den
  -- gjaldt.
  if p_platform is null or length(btrim(p_platform)) < 2 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et dekket spor krever søkeveien passeringen faktisk gikk mot.',
      hint = 'Søkeloggen skal kunne leses av en fagperson: hvor det ble søkt, med hvilken streng, når, og hvor mange treff det ga (SOURCE_POLICY.md §4.3).';
  end if;

  if p_query_string is null or length(btrim(p_query_string)) < 2 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et dekket spor krever den eksakte søkestrengen passeringen brukte.',
      hint = 'En beskrivelse av et søk er ikke et søk. Strengen er det som gjør passeringen etterprøvbar.';
  end if;

  if p_executed_at is null or p_executed_at > now() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et dekket spor krever tidspunktet passeringen faktisk ble utført.',
      hint = 'Et søk uten tidspunkt kan ikke vurderes for aktualitet, og et tidspunkt i framtiden er ikke et utført søk.';
  end if;

  if p_result_count is null or p_result_count < 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et dekket spor krever treffantallet passeringen ga.',
      hint = 'Null treff er et resultat og registreres som 0. Ingen verdi er ikke null treff (SOURCE_POLICY.md §8.2).';
  end if;

  -- Et kontrollert nullsøk er `zero_results`, og det kan ikke være avkortet.
  v_outcome := case when p_result_count = 0
                    then 'zero_results'::workflow.monograph_search_outcome
                    else 'executed'::workflow.monograph_search_outcome end;

  insert into workflow.monograph_searches (
    plan_id, plan_version, platform, query_string, filters, executed_at,
    result_count, screened_count, truncated, truncation_note,
    outcome, execution_evidence, track_codes, recorded_by_actor_id
  )
  values (
    v_plan.id, v_plan.plan_version, btrim(p_platform), btrim(p_query_string),
    nullif(btrim(coalesce(p_filters, '')), ''), p_executed_at,
    p_result_count, coalesce(p_screened_count, p_result_count),
    coalesce(p_truncated, false),
    nullif(btrim(coalesce(p_truncation_note, '')), ''),
    v_outcome, 'editor_recorded'::workflow.monograph_execution_evidence,
    array[p_track_code], v_actor_id
  )
  returning id into v_search_id;

  update workflow.monograph_search_track_attempts
  set state = 'covered', search_id = v_search_id, note = btrim(p_note),
      resolved_by_actor_id = v_actor_id
  where id = v_attempt.id;

  return jsonb_build_object(
    'plan_reference', v_plan.reference,
    'track_code', p_track_code,
    'state', 'covered',
    'search_recorded', true,
    'closure_problem', workflow.monograph_search_closure_problem(v_plan.id));
end;
$$;

comment on function api.record_monograph_track_by_editor(text, text, text, text, text, text, text, timestamptz, integer, integer, boolean, text) is
  'Lar en redaktør registrere utfallet av et obligatorisk søkespor ingen av Antideps registrerte søkeveier dekker. Gjelder bare spor som står som no_machine_path: et spor maskinen kan søke i, skal maskinen søke i, og en vei rundt den maskinelle søkefasen ville gjort hele fasen valgfri. Utfallet unavailable krever en begrunnelse. Utfallet covered fører selve passeringen inn i søkeloggen som en egen rad med editor_recorded som utførelsesbevis — plattform, eksakt søkestreng, filtre, tidspunkt, treffantall og eventuell avkorting (SOURCE_POLICY.md §4.3) — og knytter sporet til nøyaktig den raden. Uten det ville sporet pekt på en tilfeldig tidligere passering som aldri gjaldt det, og profilene uten et eneste maskinelt utførbart spor ville aldri hatt et søk som faktisk gikk. Krever editor-mandat, og aktøren føres på både søket og sporet.';

revoke execute on function api.record_monograph_track_by_editor(text, text, text, text, text, text, text, timestamptz, integer, integer, boolean, text) from public;
grant execute on function api.record_monograph_track_by_editor(text, text, text, text, text, text, text, timestamptz, integer, integer, boolean, text) to authenticated;
