-- Migrasjon 013n — overlapp uten å slå sammen uavhengige studier
--
-- 013m ga overlappet gjennom en systematisk oversikt en representasjon, og
-- bandt grupperingen til oppgaven. Gjennomgangen av 013m fant tre ting, og alle
-- tre var reelle:
--
--   1. **Den transitive lukkingen gjorde to primærstudier til ett
--      deltakerutvalg.** Grupperingen la review→inkludert-studie-relasjonene i
--      en graf og slo sammen hele den sammenhengende komponenten. Men
--      deltakeroverlapp er ikke transitivt: at en oversikt inneholder studie A
--      *og* studie B, betyr ikke at A og B deler deltakere. Med oversikten og
--      begge primærstudiene i grunnlaget ble svaret «én uavhengig enhet», mens
--      det riktige er to — oversikten er avledet av dem og legger ikke til et
--      tredje utvalg, men den gjør heller ikke A og B til det samme utvalget.
--      Tallet går videre til GRADE-leddet, som leser konsistens og presisjon av
--      nettopp det, så feilen var ikke kosmetisk.
--   2. **Overlapp mellom to oversikter ble ikke oppdaget.** Kanten krevde at
--      den delte primærstudien selv var en node i grunnlaget. Hviler
--      grunnlaget på oversikt R1 og oversikt R2, som begge inkluderer studie S
--      uten at noen rapport om S er valgt, fantes ingen kant — og de to sto som
--      to uavhengige enheter. SOURCE_POLICY.md §7 sier uttrykkelig at overlapp
--      må vurderes ved bruk av flere oversikter.
--   3. **En studie registrert fra en oversikt uten registernummer ble en
--      studie til når nummeret senere kom.** Oppslaget gikk bare på paret
--      (register, nummer). Oversiktskoblingen pekte da på den ene raden og
--      hovedrapporten på den andre, og overlappet var uten virkning — stikk i
--      strid med det kommentaren på api-funksjonen lovet.
--
-- ----------------------------------------------------------------------------
-- Modellen: en oversikt er avledet, den er ikke et utvalg
--
-- To forhold holdes nå fra hverandre, fordi de er forskjellige:
--
--   **Avledet oversikt.** Inkluderer en oversikt i grunnlaget en studie som
--   *selv* er i grunnlaget, er oversikten et sammendrag av noe som allerede er
--   der. Den beholder funnene sine, men legger ikke til et uavhengig
--   deltakerutvalg, og den sier hvilke enheter den er avledet av.
--   Primærstudiene står hver for seg — de er fortsatt like uavhengige av
--   hverandre som før oversikten kom.
--
--   **Overlappende oversikter.** To oversikter som deler en inkludert studie,
--   uten at noen rapport om den studien er i grunnlaget, er ikke uavhengige av
--   hverandre: begge bærer de samme deltakerne. De slås sammen til én enhet.
--   Det er en nedre grense for uavhengighet og ikke et presist tall — de kan
--   også inneholde hver sine øvrige studier — men det er retningen som aldri
--   lar «to oversikter er enige» se ut som to uavhengige bekreftelser.
--
-- Sammenslåing brukes altså bare der den er begrunnet i at de samme deltakerne
-- faktisk telles to ganger. To primærstudier slås aldri sammen.

-- ----------------------------------------------------------------------------
-- 1. Når en studie uten registernummer viser seg å ha ett
--
-- Append-only, som resten av sporet: oppgraderingen er en ny opplysning om en
-- identitet, og den skal kunne etterprøves i ettertid.
-- ----------------------------------------------------------------------------
create table knowledge.study_identity_upgrades (
  id uuid primary key default gen_random_uuid(),

  study_id uuid not null
    references knowledge.studies (id) on update restrict on delete restrict,

  -- Navnet raden ble funnet på. Står her fordi navnet kan endres senere, og da
  -- ville grunnlaget for oppgraderingen ikke lenger vært lesbart.
  matched_label text not null,
  registry_kind text not null,
  registry_id text not null,
  basis text not null,

  upgraded_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  upgraded_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint study_identity_upgrades_basis_shape_check
    check (basis = btrim(basis) and length(basis) between 1 and 2000),
  constraint study_identity_upgrades_label_shape_check
    check (matched_label = btrim(matched_label)
           and length(matched_label) between 1 and 500),
  constraint study_identity_upgrades_registry_shape_check
    check (registry_id = btrim(registry_id) and length(registry_id) between 1 and 100),
  constraint study_identity_upgrades_origin_check
    check (num_nonnulls(upgraded_by_actor_id, upgraded_by_agent_run_id) = 1)
);

comment on table knowledge.study_identity_upgrades is
  'Når en studie som var registrert uten forsøksregisternummer, fikk ett (SOURCE_POLICY.md §7). En oversikt kan liste en studie lenge før noen legger fram artikkelen om den, og da finnes bare navnet. Kommer artikkelen senere med både navnet og nummeret, må det bli den samme studien — ellers peker oversiktskoblingen på én rad og rapporten på en annen, og vernet mot dobbelttelling er uten virkning. Raden bevarer navnet oppslaget traff, grunnlaget og hvem som sto bak, slik at en sammenslåing som viser seg å være feil, kan finnes igjen.';

alter table knowledge.study_identity_upgrades enable row level security;

create index study_identity_upgrades_study_idx
  on knowledge.study_identity_upgrades (study_id);

create trigger study_identity_upgrades_set_created_at
  before insert or update on knowledge.study_identity_upgrades
  for each row execute function catalog.set_created_at();

-- ----------------------------------------------------------------------------
-- 2. Studiens identitet, med oppgraderingen og uten gjetning
--
-- Uendret bortsett fra to ting: et navneoppslag som treffer flere studier,
-- avvises framfor å ta en av dem, og en entydig studie uten registernummer
-- oppgraderes når nummeret kommer.
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
  -- identiteten og ikke på en rad — nettopp fordi raden ennå ikke finnes. Uten
  -- den ville to samtidige koblinger til den samme studien begge sett
  -- «finnes ikke», og den ene ville tapt på unikhetskravet. Begge nøklene låses
  -- når begge kan brukes, fordi oppgraderingen under leser dem begge.
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
    select count(*)::integer into v_matches
    from knowledge.studies s
    where s.registry_kind is null and lower(s.label) = lower(v_label);

    if v_matches > 1 then
      raise exception using
        errcode = 'restrict_violation',
        message = format('%s studier uten registernummer heter «%s», og Antidep vet ikke hvilken som menes.', v_matches, v_label),
        hint = 'Et navn er en svakere identitet enn et forsøksregisternummer. Oppgi nummeret, eller gi studien et navn som skiller den fra de andre.';
    end if;

    if v_matches = 1 then
      select s.id into v_study_id
      from knowledge.studies s
      where s.registry_kind is null and lower(s.label) = lower(v_label);
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
  'Studien med den identiteten, opprettet hvis den ikke finnes (SOURCE_POLICY.md §7). Identiteten er forsøksregisternummeret når det finnes, ellers navnet. Registeret utledes av nummerets egen form når formen er kjent, og overstyrer da det kalleren oppgav — ellers ville kildeoppdagelsens «other» og redaktørens «clinicaltrials_gov» blitt to studier om det samme forsøket. En studie som var registrert uten registernummer under nøyaktig det samme navnet, oppgraderes til å bære nummeret framfor å bli liggende som en rad til: en oversikt kan liste en studie lenge før artikkelen om den kommer inn. Oppgraderingen er append-only ført i knowledge.study_identity_upgrades, og et navn som treffer flere studier uten registernummer, avvises framfor å gjettes på. Felles for rapportkoblingen og oversiktskoblingen, slik at begge veier inn gir den samme studien.';

revoke execute on function knowledge.find_or_create_study(text, text, text, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. Grupperingen: avledet er ikke det samme som sammenslått
-- ----------------------------------------------------------------------------
create or replace function knowledge.study_units_for_evidence(p_evidence_item_ids uuid[])
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  with recursive funn as (
    select e.id as evidence_item_id, v.source_id
    from unnest(coalesce(p_evidence_item_ids, array[]::uuid[])) as i(id)
    join knowledge.evidence_items e on e.id = i.id
    left join knowledge.source_versions v on v.id = e.source_version_id
  ),
  -- Studien kilden hører til, når koblingen er registrert. Er den ikke det, er
  -- kilden sin egen enhet: et fravær er ikke en opplysning om at to kilder
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
  -- Hvilke studier hver enhet inkluderer som oversikt.
  inkludert as (
    select distinct e.unit_key, ri.study_id
    from enheter e
    join knowledge.review_included_studies ri on ri.review_source_id = e.source_id
  ),
  -- Avledet: oversikten inkluderer en studie som selv er en enhet i grunnlaget.
  -- Da er den et sammendrag av noe som allerede er lagt fram, og legger ikke til
  -- et deltakerutvalg. Primærstudiene står fortsatt hver for seg — at en
  -- oversikt nevner dem begge, gjør dem ikke til det samme utvalget.
  avledet as (
    select distinct i.unit_key
    from inkludert i
    join enheter p on p.study_id = i.study_id
    where p.unit_key <> i.unit_key
  ),
  -- De øvrige oversiktene: ingen av studiene deres er lagt fram for seg.
  frie_oversikter as (
    select unit_key from inkludert
    except
    select unit_key from avledet
  ),
  -- To slike oversikter som deler en inkludert studie, bærer de samme
  -- deltakerne. De er ikke uavhengige av hverandre, og slås sammen.
  kanter as (
    select distinct a.unit_key as a, b.unit_key as b
    from inkludert a
    join inkludert b on b.study_id = a.study_id and b.unit_key <> a.unit_key
    join frie_oversikter fa on fa.unit_key = a.unit_key
    join frie_oversikter fb on fb.unit_key = b.unit_key
  ),
  noder as (select distinct unit_key from enheter),
  naadd as (
    select n.unit_key as node, n.unit_key as root from noder n
    union
    select k.b, c.root
    from naadd c
    join kanter k on k.a = c.node
  ),
  kanonisk as (
    select node, min(root) as root from naadd group by node
  ),
  gruppert as (
    select
      k.root as unit_key,
      count(distinct u.evidence_item_id)::integer as evidence_items,
      count(distinct u.source_id)::integer as reports,
      count(distinct u.unit_key)::integer as noder,
      bool_or(u.certainty = 'uncertain') as uncertain,
      bool_or(u.unit_key in (select a.unit_key from avledet a)) as er_avledet,
      array_agg(distinct u.evidence_item_id) as evidence_item_ids,
      array_remove(array_agg(distinct u.study_id), null) as study_ids
    from enheter u
    join kanonisk k on k.node = u.unit_key
    group by k.root
  ),
  beskrevet as (
    select
      g.*,
      case when g.er_avledet then 'derived_review'
           when g.noder > 1 then 'overlapping_reviews'
           else 'primary' end as rolle,
      not g.er_avledet as uavhengig
    from gruppert g
  )
  select jsonb_build_object(
    'evidence_items', (select count(*)::integer from enheter),
    -- Tallet GRADE-leddet leser: hvor mange uavhengige deltakerutvalg
    -- grunnlaget faktisk hviler på. En avledet oversikt teller ikke med.
    'independent_units', (select count(*)::integer from beskrevet b where b.uavhengig),
    'derived_reviews',
      (select count(*)::integer from beskrevet b where b.rolle = 'derived_review'),
    'review_overlaps',
      (select count(*)::integer from beskrevet b where b.rolle = 'overlapping_reviews'),
    'shared_studies', (select count(*)::integer from beskrevet b where b.reports > 1),
    'uncertain_linkage', (select count(*)::integer from beskrevet b where b.uncertain),
    'units', coalesce((
      select jsonb_agg(jsonb_build_object(
               'role', b.rolle,
               'independent', b.uavhengig,
               'studies', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'label', s.label,
                          'registry', case when s.registry_kind is null then null
                                           else s.registry_kind || ':' || s.registry_id end)
                        order by coalesce(s.registry_kind || ':' || s.registry_id, s.label))
                 from knowledge.studies s
                 where s.id = any (b.study_ids)), '[]'::jsonb),
               -- For en avledet oversikt: hvilke av enhetene i grunnlaget den
               -- er et sammendrag av. Uten dette ville leseren sett at den ikke
               -- teller, men ikke hvorfor.
               'derives_from', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'label', d.label,
                          'registry', case when d.registry_kind is null then null
                                           else d.registry_kind || ':' || d.registry_id end)
                        order by coalesce(d.registry_kind || ':' || d.registry_id, d.label))
                 from (
                   select distinct s.id, s.label, s.registry_kind, s.registry_id
                   from inkludert i
                   join enheter p on p.study_id = i.study_id
                   join knowledge.studies s on s.id = i.study_id
                   where i.unit_key = b.unit_key and p.unit_key <> i.unit_key
                 ) d), '[]'::jsonb),
               'evidence_items', b.evidence_items,
               'reports', b.reports,
               'uncertain_linkage', b.uncertain,
               'evidence_item_ids', to_jsonb(b.evidence_item_ids))
             order by b.unit_key)
      from beskrevet b), '[]'::jsonb));
$$;

comment on function knowledge.study_units_for_evidence(uuid[]) is
  'Hvor mange uavhengige deltakerutvalg et evidenssett hviler på, og hvordan funnene henger sammen (SOURCE_POLICY.md §7, §11). Funn fra flere rapporter om den samme studien er én enhet. En systematisk oversikt som inkluderer en studie som selv er i grunnlaget, er avledet: den beholder funnene sine og sier hvilke enheter den er et sammendrag av, men den teller ikke som et eget utvalg — og den slår heller ikke primærstudiene sammen, for at en oversikt nevner A og B, gjør ikke A og B til det samme utvalget. To oversikter som deler en inkludert studie uten at noen rapport om den studien er lagt fram, bærer derimot de samme deltakerne og slås sammen til én enhet; det er en nedre grense for uavhengighet, og den retningen lar aldri «to oversikter er enige» se ut som to uavhengige bekreftelser. En kilde uten registrert kobling er sin egen enhet. Sletter ingenting: hvert funn står fortsatt i enheten sin.';

-- ----------------------------------------------------------------------------
-- 4. Avtrykket dekker også rollen
--
-- Nøkkelen for en studieliste er trukket ut fordi avtrykket bruker den to
-- ganger: for studiene enheten selv er rapport om, og for dem den er avledet
-- av. To formuleringer av den samme kanoniseringen ville vært to kanoniseringer.
-- ----------------------------------------------------------------------------
create function knowledge.study_list_key(p_studies jsonb)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select coalesce(
    (select string_agg(nokkel, ',' order by nokkel)
     from (
       select coalesce(s.value ->> 'registry', 'navn:' || (s.value ->> 'label')) as nokkel
       from jsonb_array_elements(coalesce(p_studies, '[]'::jsonb)) as s(value)
     ) rader),
    '~');
$$;

comment on function knowledge.study_list_key(jsonb) is
  'Kanonisk nøkkel for en liste med studier, uavhengig av rekkefølge. Brukes av avtrykket over uavhengighetsstrukturen, som leser to slike lister per enhet.';

revoke execute on function knowledge.study_list_key(jsonb) from public;

-- ----------------------------------------------------------------------------
-- 4b. Avtrykket
--
-- Uten rollen ville en oversikt som gikk fra å være uavhengig til å være
-- avledet, gitt det samme avtrykket så lenge funntallene sto stille — og
-- nettopp den endringen er den som skal gjøre et utestående svar foreldet.
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
