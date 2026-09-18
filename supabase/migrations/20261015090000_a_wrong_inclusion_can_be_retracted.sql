-- Migrasjon 013r — en feilregistrert inklusjon kan trekkes tilbake
--
-- 013q gjorde inklusjonssporet uforanderlig, ordnet og serialisert. Men da satt
-- det igjen ett hull, og gjennomgangen fant det:
--
--   **En feilaktig kobling kunne ikke trekkes tilbake.** Den eneste
--   etterfølgende tilstanden sporet kunne bære, var `study_link_certainty`, som
--   har `documented` og `uncertain` — og *begge* betyr operativt at studien
--   fortsatt regnes som inkludert. `uncertain` dedupliserer forsiktig, den
--   opphever ingenting. Viste en kobling seg å være feil — oversikten
--   inkluderte ved nærmere kontroll ikke studien likevel — fantes det ingen
--   støttet vei til å gjøre relasjonen uvirksom. Feilregistreringen ble
--   permanent virksom i grupperingen, og et reelt uavhengig bidrag ble
--   undertrykt i syntesen og i GRADE-leddet for alltid.
--
-- ----------------------------------------------------------------------------
-- Hvorfor tilstanden ligger i det samme sporet
--
-- Alternativet var en egen tilbaketrekkingstabell. Da ville «hva gjelder nå»
-- måttet leses av to spor med hver sin rekkefølge, og 013q sin lærepenge var
-- nettopp at rekkefølgen må være entydig. Hver rad i sporet er derfor en
-- fullstendig uttalelse om relasjonens stilling: både hvor sikker koblingen er,
-- og om den gjelder. Den med høyeste løpenummer er den som gjelder.
--
-- Og fordi hver rad er fullstendig, kan en tilbaketrekking selv trekkes
-- tilbake: viser det seg at *tilbaketrekkingen* var feil, registreres
-- inklusjonen på nytt. Ingen rad skrives over, og ingen rad slettes.

-- ----------------------------------------------------------------------------
-- 1. Om relasjonen gjelder
-- ----------------------------------------------------------------------------
create type knowledge.review_inclusion_state as enum ('included', 'retracted');

revoke usage on type knowledge.review_inclusion_state from public;

comment on type knowledge.review_inclusion_state is
  'Om en registrert inklusjon av en studie i en systematisk oversikt gjelder: included (oversikten inkluderer studien, og de to er ikke uavhengige) eller retracted (koblingen viste seg å være feil og er trukket tilbake). Tilstanden er atskilt fra sikkerheten, fordi de svarer på forskjellige spørsmål: knowledge.study_link_certainty sier hvor godt dokumentert koblingen er, og begge verdiene der betyr at studien fortsatt regnes som inkludert. Uten en egen tilstand ville en feilregistrering vært permanent virksom, og et reelt uavhengig bidrag ville blitt undertrykt for alltid.';

alter table knowledge.review_inclusion_assessments
  add column previous_state knowledge.review_inclusion_state,
  add column state knowledge.review_inclusion_state;

-- Alt som står i sporet fra før, er vurderinger av sikkerheten på en kobling
-- som gjaldt. Ingen av dem var en tilbaketrekking.
update knowledge.review_inclusion_assessments
set previous_state = 'included', state = 'included'
where previous_state is null or state is null;

alter table knowledge.review_inclusion_assessments
  alter column previous_state set not null,
  alter column state set not null;

comment on column knowledge.review_inclusion_assessments.state is
  'Om relasjonen gjelder etter denne vurderingen. Hver rad er en fullstendig uttalelse om relasjonens stilling — både sikkerhet og tilstand — slik at «hva gjelder nå» leses av én rad i ett spor med én rekkefølge.';

comment on column knowledge.review_inclusion_assessments.previous_state is
  'Tilstanden vurderingen gikk ut fra. Står her av samme grunn som previous_certainty: en endring uten et før og et etter kan ikke etterprøves.';

-- En vurdering må endre noe. Kravet dekker nå begge aksene: en tilbaketrekking
-- endrer tilstanden uten å endre sikkerheten, og skal derfor godtas.
alter table knowledge.review_inclusion_assessments
  drop constraint review_inclusion_assessments_change_check;

alter table knowledge.review_inclusion_assessments
  add constraint review_inclusion_assessments_change_check
    check ((certainty, state) <> (previous_certainty, previous_state));

create function knowledge.review_inclusion_active(p_review_included_study_id uuid)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(
    (select a.state = 'included'
     from knowledge.review_inclusion_assessments a
     where a.review_included_study_id = p_review_included_study_id
     order by a.assessment_number desc
     limit 1),
    -- Ingen senere vurdering: koblingen står som den ble registrert, og en
    -- registrert inklusjon gjelder.
    true);
$$;

comment on function knowledge.review_inclusion_active(uuid) is
  'Om en registrert inklusjon gjelder nå: tilstanden i vurderingen med høyeste løpenummer, ellers sann, fordi en registrert inklusjon gjelder inntil noen dokumenterer at den var feil. Grupperingen bruker bare de koblingene som gjelder — en feilregistrering skal ikke kunne undertrykke et reelt uavhengig bidrag for alltid.';

revoke execute on function knowledge.review_inclusion_active(uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. Studieoppslaget for seg, uten å opprette noe
--
-- Tilbaketrekkingen må finne studien uten å opprette den: en kobling som ikke
-- finnes, skal gi et tydelig avslag og ikke en ny studierad. Oppslaget er
-- derfor løftet ut av «finn eller opprett», slik at de to leser den samme
-- identiteten på nøyaktig samme måte.
-- ----------------------------------------------------------------------------
create function knowledge.study_id_for_identity(
  p_registry_kind text,
  p_registry_id text,
  p_label text)
  returns uuid
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_registry_id text;
  v_kind text;
  v_derived text;
  v_label text;
  v_study_id uuid;
  v_matches integer;
begin
  v_registry_id := knowledge.normalized_registry_id(p_registry_id);
  v_label := nullif(btrim(coalesce(p_label, '')), '');
  v_kind := nullif(btrim(lower(coalesce(p_registry_kind, ''))), '');

  if v_registry_id is null and v_label is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Studien må ha enten et registernummer eller et lesbart navn.';
  end if;

  -- Formen på nummeret avgjør registeret når den kan det, uansett hva kalleren
  -- oppgav: identiteten er paret (register, nummer), og to navnerom for det
  -- samme nummeret ville vært to studier om det samme forsøket.
  v_derived := knowledge.registry_kind_for_identifier(v_registry_id);
  if v_derived is not null then
    v_kind := v_derived;
  end if;

  if v_registry_id is not null and v_kind is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et forsøksregisternummer må si hvilket register det er fra.',
      hint = 'Gyldige registre er clinicaltrials_gov, euctr, isrctn, who_ictrp og other. Et NCT-, ISRCTN- eller EudraCT-nummer trenger ingen angivelse: formen sier selv hvilket register det er.';
  end if;

  if v_registry_id is not null then
    select s.id into v_study_id
    from knowledge.studies s
    where s.registry_kind = v_kind and s.registry_id = v_registry_id;

    return v_study_id;
  end if;

  -- Navnegrenen leser alle studier med det navnet, og ikke bare dem uten
  -- registernummer: er studien alt registrert med nummer, skal et senere
  -- oppslag på bare navnet treffe den samme raden.
  select count(*)::integer into v_matches
  from knowledge.studies s
  where lower(s.label) = lower(v_label);

  if v_matches > 1 then
    raise exception using
      errcode = 'restrict_violation',
      message = format('%s studier heter «%s», og Antidep vet ikke hvilken som menes.', v_matches, v_label),
      hint = 'Et navn er en svakere identitet enn et forsøksregisternummer. Oppgi nummeret, eller gi studien et navn som skiller den fra de andre. Et gjett her ville knyttet grunnlaget til feil studie.';
  end if;

  if v_matches = 1 then
    select s.id into v_study_id
    from knowledge.studies s
    where lower(s.label) = lower(v_label);
  end if;

  return v_study_id;
end;
$$;

comment on function knowledge.study_id_for_identity(text, text, text) is
  'Studien med den identiteten, eller NULL når Antidep ikke kjenner den. Oppretter ingenting. Registeret utledes av nummerets egen form når formen er kjent, og et navn som treffer mer enn én studie avvises framfor å gjettes på. Felles for «finn eller opprett» og for de veiene som må finne en studie uten å kunne opprette den — som tilbaketrekkingen av en inklusjon, der en ny studierad ville vært et svar på et spørsmål ingen stilte.';

revoke execute on function knowledge.study_id_for_identity(text, text, text) from public;

create or replace function knowledge.find_or_create_study(
  p_registry_kind text,
  p_registry_id text,
  p_label text,
  p_actor_id uuid,
  p_agent_run_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_registry_id text;
  v_kind text;
  v_derived text;
  v_label text;
  v_study_id uuid;
  v_matches integer;
begin
  v_registry_id := knowledge.normalized_registry_id(p_registry_id);
  v_label := nullif(btrim(coalesce(p_label, '')), '');
  v_kind := nullif(btrim(lower(coalesce(p_registry_kind, ''))), '');
  v_derived := knowledge.registry_kind_for_identifier(v_registry_id);
  if v_derived is not null then
    v_kind := v_derived;
  end if;

  -- Låsen gjør «finn eller opprett» til én udelelig handling, og den står på
  -- identiteten og ikke på en rad — nettopp fordi raden ennå ikke finnes. Begge
  -- nøklene låses når begge kan brukes, fordi oppslaget leser dem begge.
  if v_registry_id is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('antidep:studie:' || coalesce(v_kind, '?') || ':' || v_registry_id, 0));
  end if;
  if v_label is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('antidep:studie:navn:' || lower(v_label), 0));
  end if;

  -- Oppslaget, validering av identiteten og avvisningen av et tvetydig navn
  -- ligger ett sted, felles med de veiene som ikke kan opprette noe.
  v_study_id := knowledge.study_id_for_identity(p_registry_kind, p_registry_id, p_label);

  if v_study_id is not null then
    return v_study_id;
  end if;

  -- Studien kan være registrert fra en oversikt før noen la fram artikkelen om
  -- den, og da finnes bare navnet. Kommer nummeret nå, er det den samme
  -- studien — og blir det en rad til, peker oversiktskoblingen på den ene og
  -- rapporten på den andre, slik at overlappet er uten virkning.
  --
  -- Oppgraderingen krever et *entydig* treff. Heter to studier uten
  -- registernummer det samme, vet ingen hvilken av dem nummeret hører til, og
  -- da stopper den framfor å gjette.
  if v_registry_id is not null and v_label is not null then
    select count(*)::integer into v_matches
    from knowledge.studies s
    where s.registry_kind is null and lower(s.label) = lower(v_label);

    if v_matches > 1 then
      raise exception using
        errcode = 'restrict_violation',
        message = format('%s studier uten registernummer heter «%s», og Antidep vet ikke hvilken av dem %s hører til.', v_matches, v_label, v_registry_id),
        hint = 'En sammenslåing på et navn som ikke er entydig, kan knytte et forsøksregisternummer til feil studie. Gi studien et navn som skiller den, eller registrer nummeret på den kilden som oppgir det.';
    end if;

    if v_matches = 1 then
      select s.id into v_study_id
      from knowledge.studies s
      where s.registry_kind is null and lower(s.label) = lower(v_label);

      insert into knowledge.study_identity_upgrades
        (study_id, matched_label, registry_kind, registry_id, basis,
         upgraded_by_actor_id, upgraded_by_agent_run_id)
      values (
        v_study_id, (select s.label from knowledge.studies s where s.id = v_study_id),
        v_kind, v_registry_id,
        format('Studien var registrert uten registernummer under navnet «%s», og %s:%s ble oppgitt for nøyaktig det samme navnet. Navnet var entydig blant studiene uten registernummer.',
               v_label, v_kind, v_registry_id),
        p_actor_id, p_agent_run_id);

      update knowledge.studies s
      set registry_kind = v_kind, registry_id = v_registry_id
      where s.id = v_study_id;

      return v_study_id;
    end if;
  end if;

  insert into knowledge.studies
    (registry_kind, registry_id, label, created_by_actor_id)
  values (
    case when v_registry_id is null then null else v_kind end,
    v_registry_id,
    coalesce(v_label, v_kind || ':' || v_registry_id),
    coalesce(p_actor_id,
             (select r.actor_id from provenance.agent_runs r where r.id = p_agent_run_id)))
  returning id into v_study_id;

  return v_study_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. Skriveveien bærer tilstanden
-- ----------------------------------------------------------------------------
drop function knowledge.link_review_included_study(
  uuid, uuid, text, knowledge.study_link_certainty, uuid, uuid);

create function knowledge.link_review_included_study(
  p_review_source_id uuid,
  p_study_id uuid,
  p_inclusion_basis text,
  p_certainty knowledge.study_link_certainty,
  p_actor_id uuid,
  p_agent_run_id uuid,
  p_state knowledge.review_inclusion_state default 'included')
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_own_study uuid;
  v_link_id uuid;
  v_certainty knowledge.study_link_certainty;
  v_state knowledge.review_inclusion_state;
  v_nummer integer;
begin
  if p_review_source_id is null or not exists (
    select 1 from knowledge.sources s where s.id = p_review_source_id) then
    raise exception using
      errcode = 'no_data_found',
      message = 'Oversikten finnes ikke som kilde.';
  end if;

  if p_study_id is null or not exists (
    select 1 from knowledge.studies s where s.id = p_study_id) then
    raise exception using
      errcode = 'no_data_found',
      message = 'Studien finnes ikke.';
  end if;

  if btrim(coalesce(p_inclusion_basis, '')) = '' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En inklusjonskobling må si hva den hviler på.',
      hint = 'Samme krav som for rapportkoblingen: si hvor i oversikten studien står oppført, eller — for en tilbaketrekking — hva kontrollen viste (SOURCE_POLICY.md §7, §11).';
  end if;

  -- Oversikten kan ikke inkludere den studien den selv er en rapport om. Det
  -- ville vært en påstand om at kilden overlapper med seg selv, og den sier
  -- ingenting om uavhengighet.
  select r.study_id into v_own_study
  from knowledge.study_reports r
  where r.source_id = p_review_source_id;

  if v_own_study is not null and v_own_study = p_study_id then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Oversikten er selv registrert som en rapport om den studien.',
      hint = 'En kilde overlapper alltid med seg selv, og opplysningen sier derfor ingenting om uavhengighet. Er den ene av de to koblingene feil, er det den som må rettes.';
  end if;

  -- Låsen står på koblingsraden og holder helt til transaksjonen er ferdig.
  -- Uten den kunne to samtidige endringer begge lest den samme gjeldende
  -- tilstanden, og begge skrevet en vurdering med det samme «forrige».
  select ri.id into v_link_id
  from knowledge.review_included_studies ri
  where ri.review_source_id = p_review_source_id and ri.study_id = p_study_id
  for update;

  if v_link_id is null then
    -- En tilbaketrekking av noe som ikke er registrert, er ingen opplysning.
    if p_state <> 'included' then
      raise exception using
        errcode = 'no_data_found',
        message = 'Antidep har ingen registrert inklusjon av den studien i den oversikten.',
        hint = 'En tilbaketrekking gjelder en kobling som finnes. Finnes den ikke, er det ingenting å trekke tilbake.';
    end if;

    -- Finnes ikke ennå. Taper vi kappløpet mot en annen skrivevei, er raden
    -- den andre laget, den samme koblingen — og da fortsetter vi på den
    -- framfor å feile på unikhetskravet.
    begin
      insert into knowledge.review_included_studies
        (review_source_id, study_id, inclusion_basis, certainty,
         linked_by_actor_id, linked_by_agent_run_id)
      values (p_review_source_id, p_study_id, btrim(p_inclusion_basis), p_certainty,
              p_actor_id, p_agent_run_id)
      returning id into v_link_id;

      return v_link_id;
    exception
      when unique_violation then
        select ri.id into v_link_id
        from knowledge.review_included_studies ri
        where ri.review_source_id = p_review_source_id and ri.study_id = p_study_id
        for update;

        if v_link_id is null then
          raise exception using
            errcode = 'restrict_violation',
            message = 'Inklusjonskoblingen kunne ikke registreres nå.',
            hint = 'Unikhetskravet slo til, men raden som vant, fantes ikke da den ble slått opp igjen. Det er en tilstand skriveveien ikke kan tolke, og den stopper framfor å registrere en kobling til.';
        end if;
    end;
  end if;

  -- Koblingen finnes. Sier kalleren det samme som det som gjelder nå, er dette
  -- den samme opplysningen på nytt, og ingenting skjer. Sier den noe annet —
  -- om sikkerheten, om tilstanden, eller om begge — er det en ny vurdering, og
  -- den legges ved siden av den forrige med sitt eget grunnlag og sin egen
  -- proveniens. Ingen tidligere rad skrives over.
  v_certainty := knowledge.review_inclusion_certainty(v_link_id);
  v_state := case when knowledge.review_inclusion_active(v_link_id)
                  then 'included'::knowledge.review_inclusion_state
                  else 'retracted'::knowledge.review_inclusion_state end;

  if (v_certainty, v_state) is distinct from (p_certainty, p_state) then
    select coalesce(max(a.assessment_number), 0) + 1 into v_nummer
    from knowledge.review_inclusion_assessments a
    where a.review_included_study_id = v_link_id;

    insert into knowledge.review_inclusion_assessments
      (review_included_study_id, assessment_number,
       previous_certainty, certainty, previous_state, state,
       basis, assessed_by_actor_id, assessed_by_agent_run_id)
    values (v_link_id, v_nummer, v_certainty, p_certainty, v_state, p_state,
            btrim(p_inclusion_basis), p_actor_id, p_agent_run_id);
  end if;

  return v_link_id;
end;
$$;

comment on function knowledge.link_review_included_study(uuid, uuid, text, knowledge.study_link_certainty, uuid, uuid, knowledge.review_inclusion_state) is
  'Registrerer hva som gjelder for en oversikts inklusjon av en studie (SOURCE_POLICY.md §7, §11): hvor sikker koblingen er, og om den gjelder. Grunnlaget er påkrevd og proveniensen er enten et menneske eller en agentkjøring. Sier kallet noe annet enn det som gjelder nå — om sikkerheten, om tilstanden eller om begge — registreres en ny vurdering med neste løpenummer ved siden av den forrige framfor å skrive over den. Sier det det samme, endres ingenting. En tilbaketrekking av en kobling som ikke finnes, avvises: da er det ingenting å trekke tilbake. Koblingsraden låses før gjeldende tilstand leses, slik at to samtidige endringer serialiseres.';

revoke execute on function knowledge.link_review_included_study(uuid, uuid, text, knowledge.study_link_certainty, uuid, uuid, knowledge.review_inclusion_state) from public;

-- ----------------------------------------------------------------------------
-- 4. Grupperingen bruker bare de koblingene som gjelder
-- ----------------------------------------------------------------------------
create or replace function knowledge.study_units_for_evidence(p_evidence_item_ids uuid[])
  returns jsonb
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_dekket uuid[] := array[]::uuid[];
  -- De studiene minst én enhet hevder med sikkerhet at ligger i materialet. En
  -- studie i v_dekket som ikke er her, er bare antatt dekket.
  v_dekket_sikkert uuid[] := array[]::uuid[];
  v_enheter jsonb := '[]'::jsonb;
  v_funn integer := 0;
  v_rad record;
  v_overlapp uuid[];
  v_usikre uuid[];
  v_sikre_nye uuid[];
  v_rolle text;
  v_uavhengig boolean;
begin
  for v_rad in
    with funn as (
      select e.id as evidence_item_id, v.source_id
      from unnest(coalesce(p_evidence_item_ids, array[]::uuid[])) as i(id)
      join knowledge.evidence_items e on e.id = i.id
      left join knowledge.source_versions v on v.id = e.source_version_id
    ),
    -- Studien kilden hører til, når koblingen er registrert. Er den ikke det,
    -- er kilden sin egen enhet: et fravær er ikke en opplysning om at to kilder
    -- deler deltakerutvalg.
    enheter as (
      select
        f.evidence_item_id,
        f.source_id,
        r.study_id,
        r.certainty,
        coalesce(r.study_id::text,
                 'kilde:' || coalesce(f.source_id::text, f.evidence_item_id::text)) as unit_key
      from funn f
      left join knowledge.study_reports r on r.source_id = f.source_id
    ),
    inkludert as (
      select
        e.unit_key,
        array_agg(distinct ri.study_id) as studier,
        -- Studiene der den *gjeldende* vurderingen av inklusjonen er usikker.
        array_remove(array_agg(distinct case
          when knowledge.review_inclusion_certainty(ri.id) = 'uncertain'
          then ri.study_id end), null) as usikre
      from enheter e
      join knowledge.review_included_studies ri on ri.review_source_id = e.source_id
      -- Bare de koblingene som gjelder. En kobling som er dokumentert feil og
      -- trukket tilbake, skal ikke undertrykke et reelt uavhengig bidrag.
      where knowledge.review_inclusion_active(ri.id)
      group by e.unit_key
    ),
    samlet as (
      select
        u.unit_key,
        count(distinct u.evidence_item_id)::integer as evidence_items,
        count(distinct u.source_id)::integer as reports,
        bool_or(u.certainty = 'uncertain') as usikker_rapport,
        array_agg(distinct u.evidence_item_id) as evidence_item_ids,
        array_remove(array_agg(distinct u.study_id), null) as study_ids,
        coalesce((select i.studier from inkludert i where i.unit_key = u.unit_key),
                 array[]::uuid[]) as inkluderte,
        coalesce((select i.usikre from inkludert i where i.unit_key = u.unit_key),
                 array[]::uuid[]) as usikre
      from enheter u
      group by u.unit_key
    )
    select * from samlet
    -- Rapportene først: en rapport om en studie er alltid sitt eget utvalg, og
    -- at en oversikt nevner den, gjør den ikke overflødig. Så oversiktene, den
    -- med flest registrerte inkluderte studier først, slik at en oversikt som
    -- dekker en annen fullt ut, kommer før den.
    order by (cardinality(inkluderte) > 0), cardinality(inkluderte) desc, unit_key
  loop
    v_funn := v_funn + v_rad.evidence_items;

    if cardinality(v_rad.inkluderte) = 0 then
      v_overlapp := array[]::uuid[];
      v_rolle := 'primary';
      v_uavhengig := true;
    else
      select coalesce(array_agg(x), array[]::uuid[]) into v_overlapp
      from unnest(v_rad.inkluderte) as t(x)
      where t.x = any (v_dekket);

      if v_rad.inkluderte <@ v_dekket then
        -- Alt oversikten dekker, er lagt fram for seg. Den beholder funnene
        -- sine, men den legger ikke til et deltakerutvalg.
        v_rolle := 'derived_review';
        v_uavhengig := false;
      else
        -- Noe av det bare denne oversikten bærer, står ingen andre steder i
        -- grunnlaget. Da er den ikke overflødig — heller ikke når en del av det
        -- den dekker, alt er lagt fram.
        v_rolle := case when cardinality(v_overlapp) > 0
                        then 'partially_derived_review'
                        else 'independent_review' end;
        v_uavhengig := true;
      end if;
    end if;

    -- Usikkerheten som betyr noe, er den som ligger under *dedupliseringen*: de
    -- studiene enhetens rolle hviler på, der enten denne enhetens egen kobling
    -- eller den som dekket studien først, bare er antatt. Regnes før dekningen
    -- oppdateres, slik at en enhet ikke kan bekrefte sin egen overlapp.
    select coalesce(array_agg(x), array[]::uuid[]) into v_usikre
    from unnest(v_overlapp) as t(x)
    where t.x = any (v_rad.usikre) or not (t.x = any (v_dekket_sikkert));

    if v_uavhengig then
      v_dekket := v_dekket || v_rad.study_ids || v_rad.inkluderte;

      -- Rapportkoblingen gjør studien sikkert dekket bare når den selv er
      -- dokumentert; det samme gjelder de inklusjonene som er dokumenterte.
      if not coalesce(v_rad.usikker_rapport, false) then
        v_dekket_sikkert := v_dekket_sikkert || v_rad.study_ids;
      end if;

      select coalesce(array_agg(x), array[]::uuid[]) into v_sikre_nye
      from unnest(v_rad.inkluderte) as t(x)
      where not (t.x = any (v_rad.usikre));

      v_dekket_sikkert := v_dekket_sikkert || v_sikre_nye;
    end if;

    v_enheter := v_enheter || jsonb_build_array(jsonb_build_object(
      'role', v_rolle,
      'independent', v_uavhengig,
      'studies', knowledge.study_briefs(v_rad.study_ids),
      -- Studiene enheten dekker, og som allerede er dekket av andre enheter i
      -- grunnlaget. For en avledet oversikt er det alt den dekker; for en
      -- delvis avledet er det den delen som ikke er ny.
      'derives_from', knowledge.study_briefs(v_overlapp),
      -- Og hvilke av dem sammenslåingen bare *antar*. Uten dette så en
      -- deduplisering som hvilte på en usikker relasjon, like kontrollert ut
      -- som en som hvilte på en dokumentert (SOURCE_POLICY.md §7).
      'uncertain_inclusions', knowledge.study_briefs(v_usikre),
      -- Og hvor mye bare denne enheten bærer. Uten tallet ville leseren ikke
      -- se forskjell på en oversikt som er helt overflødig, og en som bærer noe
      -- ingen andre har lagt fram.
      'unique_studies', cardinality(v_rad.inkluderte) - cardinality(v_overlapp),
      'evidence_items', v_rad.evidence_items,
      'reports', v_rad.reports,
      'uncertain_linkage',
        coalesce(v_rad.usikker_rapport, false) or cardinality(v_usikre) > 0,
      'evidence_item_ids', to_jsonb(v_rad.evidence_item_ids)));
  end loop;

  return jsonb_build_object(
    'evidence_items', v_funn,
    'independent_units', (
      select count(*)::integer from jsonb_array_elements(v_enheter) as u(value)
      where (u.value ->> 'independent')::boolean),
    'derived_reviews', (
      select count(*)::integer from jsonb_array_elements(v_enheter) as u(value)
      where u.value ->> 'role' = 'derived_review'),
    'review_overlaps', (
      select count(*)::integer from jsonb_array_elements(v_enheter) as u(value)
      where u.value ->> 'role' = 'partially_derived_review'),
    'shared_studies', (
      select count(*)::integer from jsonb_array_elements(v_enheter) as u(value)
      where (u.value ->> 'reports')::integer > 1),
    'uncertain_linkage', (
      select count(*)::integer from jsonb_array_elements(v_enheter) as u(value)
      where (u.value ->> 'uncertain_linkage')::boolean),
    'units', v_enheter);
end;
$$;

comment on function knowledge.study_units_for_evidence(uuid[]) is
  'Hvor mange uavhengige deltakerutvalg et evidenssett hviler på, og hvordan funnene henger sammen (SOURCE_POLICY.md §7, §11). Én regel avgjør: en enhet er ikke uavhengig når alt den dekker, allerede er dekket av andre enheter i grunnlaget. Funn fra flere rapporter om den samme studien er én enhet. En rapport om en studie er alltid sitt eget utvalg — at en oversikt nevner den, gjør den ikke overflødig. En systematisk oversikt teller ikke som et eget utvalg når alle studiene den er registrert som å inkludere, er lagt fram for seg; dekker den noe ingen andre har lagt fram, står den igjen som uavhengig for nettopp det. Bare de inklusjonene som gjelder, leses: en kobling som er dokumentert feil og trukket tilbake, undertrykker ingenting. En usikker inklusjon dedupliserer som en dokumentert — den forsiktige lesningen er å behandle materialet som overlappende — men enheten sier da at sammenslåingen hviler på en usikker relasjon, og navngir hvilke studier det gjelder. Usikkerheten følger dekningen og ikke bare enhetens egen kobling. Rekkefølgen er deterministisk og grådig: rapportene først, så oversiktene med den bredeste først. Sletter ingenting: hvert funn står fortsatt i enheten sin.';

revoke execute on function knowledge.study_units_for_evidence(uuid[]) from public;

-- ----------------------------------------------------------------------------
-- 5. Redaktørens veier inn
-- ----------------------------------------------------------------------------
create or replace function api.link_review_included_study(
  p_review_reference text,
  p_registry_kind text,
  p_registry_id text,
  p_study_label text,
  p_inclusion_basis text,
  p_certain boolean default true)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_review_source_id uuid;
  v_study_id uuid;
  v_link_id uuid;
  v_for_certainty knowledge.study_link_certainty;
  v_for_aktiv boolean;
  v_etter_certainty knowledge.study_link_certainty;
  v_etter_aktiv boolean;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  v_review_source_id := knowledge.source_id_for_reference(p_review_reference);

  -- Den inkluderte studien identifiseres på nøyaktig samme måte som i
  -- rapportkoblingen, og opprettes hvis Antidep ikke kjenner den fra før: en
  -- oversikt kan godt liste en studie ingen har lagt fram artikkelen til ennå,
  -- og når artikkelen senere kommer inn, lander den på den samme studien.
  v_study_id := knowledge.find_or_create_study(
    p_registry_kind, p_registry_id, p_study_label, v_actor_id, null);

  select knowledge.review_inclusion_certainty(ri.id),
         knowledge.review_inclusion_active(ri.id)
    into v_for_certainty, v_for_aktiv
  from knowledge.review_included_studies ri
  where ri.review_source_id = v_review_source_id and ri.study_id = v_study_id;

  v_link_id := knowledge.link_review_included_study(
    v_review_source_id, v_study_id, p_inclusion_basis,
    case when p_certain then 'documented'::knowledge.study_link_certainty
         else 'uncertain'::knowledge.study_link_certainty end,
    v_actor_id, null, 'included'::knowledge.review_inclusion_state);

  v_etter_certainty := knowledge.review_inclusion_certainty(v_link_id);
  v_etter_aktiv := knowledge.review_inclusion_active(v_link_id);

  return jsonb_build_object(
    'review', (select s.title from knowledge.sources s where s.id = v_review_source_id),
    'study', (select s.label from knowledge.studies s where s.id = v_study_id),
    'registry', (select case when s.registry_kind is null then null
                             else s.registry_kind || ':' || s.registry_id end
                 from knowledge.studies s where s.id = v_study_id),
    'included_studies', (select count(*)::integer
                         from knowledge.review_included_studies ri
                         where ri.review_source_id = v_review_source_id
                           and knowledge.review_inclusion_active(ri.id)),
    -- Det *lagrede* svaret, ikke det innsendte. Et svar som gjentok det
    -- kalleren sendte inn, kunne si «sikker» om en kobling databasen fortsatt
    -- førte som usikker.
    'certain', v_etter_certainty = 'documented',
    'active', v_etter_aktiv,
    'clarified', v_for_certainty is not null
                 and (v_for_certainty, v_for_aktiv)
                     is distinct from (v_etter_certainty, v_etter_aktiv));
end;
$$;

comment on function api.link_review_included_study(text, text, text, text, text, boolean) is
  'Redaktørens vei til å si at en systematisk oversikt inkluderer en bestemt studie (SOURCE_POLICY.md §7, §11). Uten den kunne en oversikt og primærstudiene den bygger på, telles som uavhengige kilder, og de samme deltakerne ville talt to ganger. Oversikten navngis med en identifikator eller en entydig tittel, studien med forsøksregisternummeret sitt eller navnet sitt — og studien opprettes hvis Antidep ikke kjenner den, slik at artikkelen om den lander på den samme studien når den senere kommer inn. Kallet setter koblingen til å gjelde, og gjenoppretter den dermed også hvis den var trukket tilbake ved en feil. Svaret oppgir den sikkerheten og tilstanden som faktisk er lagret. Krever redaktørmandat.';

revoke execute on function api.link_review_included_study(text, text, text, text, text, boolean) from public;
grant execute on function api.link_review_included_study(text, text, text, text, text, boolean) to authenticated;

create function api.retract_review_included_study(
  p_review_reference text,
  p_registry_kind text,
  p_registry_id text,
  p_study_label text,
  p_basis text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_review_source_id uuid;
  v_study_id uuid;
  v_link_id uuid;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  v_review_source_id := knowledge.source_id_for_reference(p_review_reference);

  -- Oppslaget som ikke oppretter noe: en tilbaketrekking gjelder en kobling som
  -- finnes, og en ny studierad ville vært et svar på et spørsmål ingen stilte.
  v_study_id := knowledge.study_id_for_identity(
    p_registry_kind, p_registry_id, p_study_label);

  if v_study_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Antidep kjenner ingen studie med den identiteten.';
  end if;

  v_link_id := knowledge.link_review_included_study(
    v_review_source_id, v_study_id, p_basis,
    knowledge.review_inclusion_certainty((
      select ri.id from knowledge.review_included_studies ri
      where ri.review_source_id = v_review_source_id and ri.study_id = v_study_id)),
    v_actor_id, null, 'retracted'::knowledge.review_inclusion_state);

  return jsonb_build_object(
    'review', (select s.title from knowledge.sources s where s.id = v_review_source_id),
    'study', (select s.label from knowledge.studies s where s.id = v_study_id),
    'registry', (select case when s.registry_kind is null then null
                             else s.registry_kind || ':' || s.registry_id end
                 from knowledge.studies s where s.id = v_study_id),
    'active', knowledge.review_inclusion_active(v_link_id),
    'included_studies', (select count(*)::integer
                         from knowledge.review_included_studies ri
                         where ri.review_source_id = v_review_source_id
                           and knowledge.review_inclusion_active(ri.id)));
end;
$$;

comment on function api.retract_review_included_study(text, text, text, text, text) is
  'Redaktørens vei til å trekke tilbake en inklusjonskobling som viste seg å være feil — oversikten inkluderte ved nærmere kontroll ikke studien likevel (SOURCE_POLICY.md §7, §11). Uten den ville en feilregistrering vært permanent virksom i grupperingen, og et reelt uavhengig bidrag ville blitt undertrykt i syntesen og i GRADE-leddet for alltid. Tilbaketrekkingen sletter ingenting: den er en ny vurdering i sporet, med grunnlaget og hvem som sto bak, og den kan selv trekkes tilbake ved å registrere inklusjonen på nytt. En tilbaketrekking av en kobling som ikke finnes, avvises. Krever redaktørmandat.';

revoke execute on function api.retract_review_included_study(text, text, text, text, text) from public;
grant execute on function api.retract_review_included_study(text, text, text, text, text) to authenticated;
