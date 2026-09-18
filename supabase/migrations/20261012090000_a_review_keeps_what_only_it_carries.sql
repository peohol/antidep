-- Migrasjon 013o — en oversikt beholder det bare den bærer
--
-- 013n rettet den transitive sammenslåingen, men lot to hull stå igjen.
-- Gjennomgangen fant begge, og begge var reelle:
--
--   1. **Avledningen var alt-eller-ingenting.** Inkluderte oversikten R
--      studiene S1 og S2, og besto grunnlaget av R og S1, ble hele R merket som
--      avledet i det S1 fantes direkte. Da forsvant det bare R bærer — S2 —
--      ut av uavhengighetsmodellen, og grunnlaget så smalere ut enn det er.
--      Feilen var speilbildet av den forrige: den forrige overdrev
--      sammenslåingen, denne overdrev avledningen.
--   2. **Identiteten kunne fortsatt splittes, i motsatt rekkefølge.**
--      Registreres hovedartikkelen først med navn *og* registernummer, og en
--      oversikt senere kobler den samme studien bare med navnet, lette
--      navnegrenen bare blant rader uten registernummer. Den registerbærende
--      studien ble oversett, og det ble opprettet en parallell identitet — med
--      nøyaktig den samme følgen 013n skulle fjerne.
--
-- ----------------------------------------------------------------------------
-- Én regel i stedet for to
--
-- 013n hadde to regler: «avledet oversikt» og «overlappende oversikter». De var
-- to utgaver av det samme spørsmålet, og den ene kunne ikke se det den andre
-- så. Regelen er nå én:
--
--   **En enhet er ikke uavhengig når alt den dekker, allerede er dekket av
--   andre enheter i grunnlaget.**
--
-- En rapport om en studie dekker den studien og er alltid sitt eget utvalg —
-- at en oversikt nevner den, gjør den ikke overflødig. En oversikt dekker
-- studiene den er registrert som å inkludere. Rapportene leses derfor først, og
-- oversiktene etterpå, med den som dekker flest registrerte studier først: en
-- oversikt som dekker en annen fullt ut, skal komme før den, slik at det er den
-- smalere som blir stående som avledet.
--
-- Rekkefølgen er deterministisk, og den er en grådig lesning og ikke et bevis
-- om minste mulige dekning. Der to oversikter dekker hverandre delvis, står
-- begge — de bærer hver sitt, og da er de ikke overflødige.
--
-- ----------------------------------------------------------------------------
-- Hva tallene betyr etterpå
--
--   independent_units   enheter som bærer noe ingen annen enhet i grunnlaget
--                       alt bærer. Tallet GRADE-leddet leser.
--   derived_reviews     oversikter der alt de dekker, er lagt fram for seg.
--   review_overlaps     oversikter som *delvis* overlapper, og som derfor står
--                       igjen som uavhengige for det bare de bærer.

-- ----------------------------------------------------------------------------
-- 1. Studien slås opp på navn uten å lage en parallell identitet
--
-- Uendret bortsett fra navnegrenen: den leser nå alle studier med det navnet,
-- og ikke bare dem uten registernummer.
-- ----------------------------------------------------------------------------
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

  if v_registry_id is null and v_label is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Studien må ha enten et registernummer eller et lesbart navn.';
  end if;

  -- Formen på nummeret avgjør registeret når den kan det, uansett hva kalleren
  -- oppgav. Uten overstyringen ble det samme forsøket to studier: kildeoppdagelsen
  -- sa «other» om NCT00000001, redaktøren sa «clinicaltrials_gov» om det samme
  -- nummeret, og unikheten står på paret (register, nummer).
  v_derived := knowledge.registry_kind_for_identifier(v_registry_id);
  if v_derived is not null then
    v_kind := v_derived;
  end if;

  -- Et registernummer uten et register er ingen identitet: NCT00000000 og
  -- ISRCTN00000000 er ikke det samme nummeret, og uten registeret vet ingen
  -- hvilket av dem raden mener.
  if v_registry_id is not null and v_kind is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et forsøksregisternummer må si hvilket register det er fra.',
      hint = 'Gyldige registre er clinicaltrials_gov, euctr, isrctn, who_ictrp og other. Et NCT-, ISRCTN- eller EudraCT-nummer trenger ingen angivelse: formen sier selv hvilket register det er.';
  end if;

  -- Låsen gjør «finn eller opprett» til én udelelig handling, og den står på
  -- identiteten og ikke på en rad — nettopp fordi raden ennå ikke finnes. Begge
  -- nøklene låses når begge kan brukes, fordi oppslaget leser dem begge.
  if v_registry_id is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('antidep:studie:' || v_kind || ':' || v_registry_id, 0));
  end if;
  if v_label is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('antidep:studie:navn:' || lower(v_label), 0));
  end if;

  if v_registry_id is not null then
    select s.id into v_study_id
    from knowledge.studies s
    where s.registry_kind = v_kind and s.registry_id = v_registry_id;

    -- Studien kan være registrert fra en oversikt før noen la fram artikkelen
    -- om den, og da finnes bare navnet. Kommer nummeret nå, er det den samme
    -- studien — og blir det en rad til, peker oversiktskoblingen på den ene og
    -- rapporten på den andre, slik at overlappet er uten virkning.
    --
    -- Oppgraderingen krever et *entydig* treff. Heter to studier uten
    -- registernummer det samme, vet ingen hvilken av dem nummeret hører til, og
    -- da stopper den framfor å gjette.
    if v_study_id is null and v_label is not null then
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
      else
        v_study_id := null;
      end if;
    end if;
  else
    -- Navnegrenen leser *alle* studier med det navnet, og ikke bare dem uten
    -- registernummer.
    --
    -- Motsatt rekkefølge av oppgraderingen over: er hovedartikkelen registrert
    -- først med navn og nummer, og kobler en oversikt senere den samme studien
    -- bare med navnet, skal den treffe den registerbærende raden. Leste grenen
    -- bare rader uten registernummer, ble det opprettet en parallell identitet
    -- ved siden av — med nøyaktig den samme følgen: oversiktskoblingen peker på
    -- én rad og rapporten på en annen, og overlappet er uten virkning.
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
    else
      v_study_id := null;
    end if;
  end if;

  if v_study_id is null then
    insert into knowledge.studies
      (registry_kind, registry_id, label, created_by_actor_id)
    values (
      case when v_registry_id is null then null else v_kind end,
      v_registry_id,
      coalesce(v_label, v_kind || ':' || v_registry_id),
      coalesce(p_actor_id,
               (select r.actor_id from provenance.agent_runs r where r.id = p_agent_run_id)))
    returning id into v_study_id;
  end if;

  return v_study_id;
end;
$$;

comment on function knowledge.find_or_create_study(text, text, text, uuid, uuid) is
  'Studien med den identiteten, opprettet hvis den ikke finnes (SOURCE_POLICY.md §7). Identiteten er forsøksregisternummeret når det finnes, ellers navnet. Registeret utledes av nummerets egen form når formen er kjent, og overstyrer da det kalleren oppgav. De to rekkefølgene er symmetriske: kommer nummeret etter at studien ble registrert med bare et navn, oppgraderes den raden (ført append-only i knowledge.study_identity_upgrades) framfor å bli en rad til; kommer navnet etter at studien ble registrert med nummer, treffer navnet den samme raden. Et navn som treffer mer enn én studie, avvises framfor å gjettes på. Felles for rapportkoblingen og oversiktskoblingen, slik at begge veier inn gir den samme studien.';

revoke execute on function knowledge.find_or_create_study(text, text, text, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. Studiene i lesbar form, ett sted
-- ----------------------------------------------------------------------------
create function knowledge.study_briefs(p_study_ids uuid[])
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(
    (select jsonb_agg(jsonb_build_object(
              'label', s.label,
              'registry', case when s.registry_kind is null then null
                               else s.registry_kind || ':' || s.registry_id end)
            order by coalesce(s.registry_kind || ':' || s.registry_id, s.label))
     from knowledge.studies s
     where s.id = any (coalesce(p_study_ids, array[]::uuid[]))),
    '[]'::jsonb);
$$;

comment on function knowledge.study_briefs(uuid[]) is
  'Studiene i den formen en leser kan bruke: navnet og registeridentiteten, i fast rekkefølge. Ett sted, fordi grupperingen oppgir studier tre steder per enhet.';

revoke execute on function knowledge.study_briefs(uuid[]) from public;

-- ----------------------------------------------------------------------------
-- 3. Grupperingen: én regel om hva som allerede er dekket
-- ----------------------------------------------------------------------------
create or replace function knowledge.study_units_for_evidence(p_evidence_item_ids uuid[])
  returns jsonb
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_dekket uuid[] := array[]::uuid[];
  v_enheter jsonb := '[]'::jsonb;
  v_funn integer := 0;
  v_rad record;
  v_overlapp uuid[];
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
      select e.unit_key, array_agg(distinct ri.study_id) as studier
      from enheter e
      join knowledge.review_included_studies ri on ri.review_source_id = e.source_id
      group by e.unit_key
    ),
    samlet as (
      select
        u.unit_key,
        count(distinct u.evidence_item_id)::integer as evidence_items,
        count(distinct u.source_id)::integer as reports,
        bool_or(u.certainty = 'uncertain') as uncertain,
        array_agg(distinct u.evidence_item_id) as evidence_item_ids,
        array_remove(array_agg(distinct u.study_id), null) as study_ids,
        coalesce((select i.studier from inkludert i where i.unit_key = u.unit_key),
                 array[]::uuid[]) as inkluderte
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
      v_dekket := v_dekket || v_rad.study_ids;
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
        v_dekket := v_dekket || v_rad.inkluderte || v_rad.study_ids;
      end if;
    end if;

    v_enheter := v_enheter || jsonb_build_array(jsonb_build_object(
      'role', v_rolle,
      'independent', v_uavhengig,
      'studies', knowledge.study_briefs(v_rad.study_ids),
      -- Studiene enheten dekker, og som allerede er dekket av andre enheter i
      -- grunnlaget. For en avledet oversikt er det alt den dekker; for en
      -- delvis avledet er det den delen som ikke er ny.
      'derives_from', knowledge.study_briefs(v_overlapp),
      -- Og hvor mye bare denne enheten bærer. Uten tallet ville leseren ikke
      -- se forskjell på en oversikt som er helt overflødig, og en som bærer noe
      -- ingen andre har lagt fram.
      'unique_studies', cardinality(v_rad.inkluderte) - cardinality(v_overlapp),
      'evidence_items', v_rad.evidence_items,
      'reports', v_rad.reports,
      'uncertain_linkage', v_rad.uncertain,
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
  'Hvor mange uavhengige deltakerutvalg et evidenssett hviler på, og hvordan funnene henger sammen (SOURCE_POLICY.md §7, §11). Én regel avgjør: en enhet er ikke uavhengig når alt den dekker, allerede er dekket av andre enheter i grunnlaget. Funn fra flere rapporter om den samme studien er én enhet. En rapport om en studie er alltid sitt eget utvalg — at en oversikt nevner den, gjør den ikke overflødig. En systematisk oversikt teller ikke som et eget utvalg når alle studiene den er registrert som å inkludere, er lagt fram for seg; dekker den noe ingen andre har lagt fram, står den igjen som uavhengig for nettopp det, og oppgir både hva den deler og hvor mye bare den bærer. Rekkefølgen er deterministisk og grådig: rapportene først, så oversiktene med den bredeste først. Sletter ingenting: hvert funn står fortsatt i enheten sin.';

revoke execute on function knowledge.study_units_for_evidence(uuid[]) from public;

-- ----------------------------------------------------------------------------
-- 4. Avtrykket dekker også hvor mye bare enheten bærer
-- ----------------------------------------------------------------------------
create or replace function knowledge.study_unit_digest(p_evidence_item_ids uuid[])
  returns text
  language sql
  stable
  set search_path = ''
as $$
  select 'sha256-v1:' || encode(
    sha256(convert_to(
      coalesce(
        (select string_agg(linje, '|' order by linje)
         from (
           select (u.value ->> 'role') || ':' || (u.value ->> 'independent')
                  || ':' || (u.value ->> 'unique_studies')
                  || ':' || (u.value ->> 'evidence_items')
                  || ':' || (u.value ->> 'reports')
                  || ':' || coalesce(u.value ->> 'uncertain_linkage', '~')
                  || ':' || knowledge.study_list_key(u.value -> 'studies')
                  || ':' || knowledge.study_list_key(u.value -> 'derives_from')
                  || ':' || coalesce((
                       select string_agg(x, ',' order by x)
                       from jsonb_array_elements_text(
                              u.value -> 'evidence_item_ids') as e(x)), '~')
             as linje
           from jsonb_array_elements(
                  knowledge.study_units_for_evidence(p_evidence_item_ids) -> 'units') as u(value)
         ) rader),
        'tom'),
      'UTF8')), 'hex');
$$;
