-- Migrasjon 013p — en usikker inklusjon slutter ikke å være usikker
--
-- 013m ga oversiktskoblingen et sikkerhetsfelt, og 013o gjorde grupperingen
-- riktig. Men usikkerheten kom aldri fram dit den betyr noe, og den kunne ikke
-- avklares. Gjennomgangen fant begge, og begge var reelle:
--
--   1. **Usikkerheten forsvant ut av grupperingen.** `study_units_for_evidence`
--      leste bare `ri.study_id` fra oversiktskoblingen; `ri.certainty` fulgte
--      ikke med, og `uncertain_linkage` ble regnet bare av rapportkoblingen. En
--      oversikt som *kanskje* inkluderer S, kunne derfor stå som avledet med
--      `uncertain_linkage = false`. Syntesen og GRADE-leddet så da en
--      deduplisering uten å se at den hviler på en usikker relasjon — og
--      avtrykket bandt den ikke, så en senere avklaring ville ikke gjort et
--      utestående svar foreldet.
--   2. **Avklaringen var ikke mulig.** Skriveveien brukte
--      `on conflict do nothing`, så en dokumentert kobling registrert etter en
--      usikker endret ingenting. Verre: redaktørsvaret speilet det *innsendte*
--      `p_certain` og ikke det lagrede, så et kall kunne svare «certain: true»
--      mens databasen fortsatt sa `uncertain`.
--
-- ----------------------------------------------------------------------------
-- Hvorfor avklaringen er en ny rad og ikke en retting
--
-- Den første vurderingen ble gjort av noen, på et grunnlag, på et tidspunkt. En
-- senere vurdering er en *ny* opplysning, ikke en korreksjon av hvem den første
-- var. Skrev avklaringen over `certainty` på koblingsraden, ville raden ha båret
-- den nye vurderingen under den førstes navn. Derfor ligger hver senere
-- vurdering i sin egen append-only rad, med sitt eget grunnlag og sin egen
-- proveniens, og den gjeldende sikkerheten er den siste av dem.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en usikker inklusjon fortsatt dedupliserer
--
-- SOURCE_POLICY.md §7 er tydelig: en usikker kobling skal være synlig og aldri
-- løses ved en udokumentert sammenslåing, men den hindrer at rapportene regnes
-- som uavhengige. Den forsiktige lesningen er altså å behandle materialet som
-- overlappende *og* si at grunnlaget for det er usikkert. Oppførselen er derfor
-- uendret; det som er nytt, er at usikkerheten er synlig og bundet.

-- ----------------------------------------------------------------------------
-- 1. Senere vurderinger av en inklusjon
-- ----------------------------------------------------------------------------
create table knowledge.review_inclusion_assessments (
  id uuid primary key default gen_random_uuid(),

  review_included_study_id uuid not null
    references knowledge.review_included_studies (id)
    on update restrict on delete restrict,

  -- Den gjeldende sikkerheten da denne vurderingen ble gjort. Står her fordi
  -- en avklaring uten et før og et etter ikke er en avklaring.
  previous_certainty knowledge.study_link_certainty not null,
  certainty knowledge.study_link_certainty not null,
  basis text not null,

  assessed_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  assessed_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint review_inclusion_assessments_basis_shape_check
    check (basis = btrim(basis) and length(basis) between 1 and 2000),
  -- En vurdering som sier det samme som den forrige, er ingen ny opplysning.
  constraint review_inclusion_assessments_change_check
    check (certainty <> previous_certainty),
  constraint review_inclusion_assessments_origin_check
    check (num_nonnulls(assessed_by_actor_id, assessed_by_agent_run_id) = 1)
);

comment on table knowledge.review_inclusion_assessments is
  'Senere vurderinger av hvor sikker en oversikts inklusjon av en studie er (SOURCE_POLICY.md §7). Append-only ved siden av knowledge.review_included_studies, som bærer den første vurderingen: en avklaring er en ny opplysning og ikke en retting av hvem den første vurderingen kom fra. Den gjeldende sikkerheten er den siste raden her, ellers koblingsradens egen. Finnes fordi en usikker inklusjon både må kunne avklares og forbli synlig i mellomtiden — grupperingen dedupliserer uansett, men et grunnlag som hviler på en usikker relasjon, skal ikke se kontrollert ut.';

alter table knowledge.review_inclusion_assessments enable row level security;

create index review_inclusion_assessments_link_idx
  on knowledge.review_inclusion_assessments (review_included_study_id, created_at desc);

create trigger review_inclusion_assessments_set_created_at
  before insert or update on knowledge.review_inclusion_assessments
  for each row execute function catalog.set_created_at();

-- ----------------------------------------------------------------------------
-- 2. Den gjeldende sikkerheten
-- ----------------------------------------------------------------------------
create function knowledge.review_inclusion_certainty(p_review_included_study_id uuid)
  returns knowledge.study_link_certainty
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(
    (select a.certainty
     from knowledge.review_inclusion_assessments a
     where a.review_included_study_id = p_review_included_study_id
     order by a.created_at desc, a.id desc
     limit 1),
    (select ri.certainty
     from knowledge.review_included_studies ri
     where ri.id = p_review_included_study_id));
$$;

comment on function knowledge.review_inclusion_certainty(uuid) is
  'Hvor sikker en oversikts inklusjon av en studie er nå: den siste registrerte vurderingen, ellers den første. Ett sted, slik at grupperingen, redaktørsvaret og avtrykket ikke kan lese tre forskjellige verdier.';

revoke execute on function knowledge.review_inclusion_certainty(uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. Skriveveien kan avklare, og overskriver ingenting
-- ----------------------------------------------------------------------------
create or replace function knowledge.link_review_included_study(
  p_review_source_id uuid,
  p_study_id uuid,
  p_inclusion_basis text,
  p_certainty knowledge.study_link_certainty,
  p_actor_id uuid,
  p_agent_run_id uuid)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_own_study uuid;
  v_link_id uuid;
  v_gjeldende knowledge.study_link_certainty;
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
      hint = 'Samme krav som for rapportkoblingen: si hvor i oversikten studien står oppført (SOURCE_POLICY.md §7, §11).';
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

  select ri.id into v_link_id
  from knowledge.review_included_studies ri
  where ri.review_source_id = p_review_source_id and ri.study_id = p_study_id;

  if v_link_id is null then
    insert into knowledge.review_included_studies
      (review_source_id, study_id, inclusion_basis, certainty,
       linked_by_actor_id, linked_by_agent_run_id)
    values (p_review_source_id, p_study_id, btrim(p_inclusion_basis), p_certainty,
            p_actor_id, p_agent_run_id)
    returning id into v_link_id;

    return v_link_id;
  end if;

  -- Koblingen finnes. Sier kalleren det samme som den gjeldende vurderingen, er
  -- dette den samme opplysningen på nytt, og ingenting skjer. Sier den noe
  -- annet, er det en ny vurdering — og den legges ved siden av den forrige, med
  -- sitt eget grunnlag og sin egen proveniens. Den første vurderingen står
  -- urørt: den ble gjort av noen, og den skal fortsatt kunne leses som deres.
  v_gjeldende := knowledge.review_inclusion_certainty(v_link_id);

  if v_gjeldende is distinct from p_certainty then
    insert into knowledge.review_inclusion_assessments
      (review_included_study_id, previous_certainty, certainty, basis,
       assessed_by_actor_id, assessed_by_agent_run_id)
    values (v_link_id, v_gjeldende, p_certainty, btrim(p_inclusion_basis),
            p_actor_id, p_agent_run_id);
  end if;

  return v_link_id;
end;
$$;

comment on function knowledge.link_review_included_study(uuid, uuid, text, knowledge.study_link_certainty, uuid, uuid) is
  'Registrerer at en systematisk oversikt inkluderer en studie (SOURCE_POLICY.md §7, §11), slik at oversikten og primærstudien ikke telles som to uavhengige deltakerutvalg. Grunnlaget er påkrevd og proveniensen er enten et menneske eller en agentkjøring. Et kall som sier noe annet om sikkerheten enn den gjeldende vurderingen, registrerer en ny vurdering ved siden av den forrige framfor å skrive over den — en avklaring er en ny opplysning, ikke en retting av hvem den første vurderingen kom fra. Sier kallet det samme, endres ingenting. Returnerer koblingens id.';

revoke execute on function knowledge.link_review_included_study(uuid, uuid, text, knowledge.study_link_certainty, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Redaktørsvaret speiler det lagrede, ikke det innsendte
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
  v_for knowledge.study_link_certainty;
  v_etter knowledge.study_link_certainty;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  v_review_source_id := knowledge.source_id_for_reference(p_review_reference);

  -- Den inkluderte studien identifiseres på nøyaktig samme måte som i
  -- rapportkoblingen, og opprettes hvis Antidep ikke kjenner den fra før: en
  -- oversikt kan godt liste en studie ingen har lagt fram artikkelen til ennå,
  -- og når artikkelen senere kommer inn, lander den på den samme studien.
  v_study_id := knowledge.find_or_create_study(
    p_registry_kind, p_registry_id, p_study_label, v_actor_id, null);

  select knowledge.review_inclusion_certainty(ri.id) into v_for
  from knowledge.review_included_studies ri
  where ri.review_source_id = v_review_source_id and ri.study_id = v_study_id;

  v_link_id := knowledge.link_review_included_study(
    v_review_source_id, v_study_id, p_inclusion_basis,
    case when p_certain then 'documented'::knowledge.study_link_certainty
         else 'uncertain'::knowledge.study_link_certainty end,
    v_actor_id, null);

  v_etter := knowledge.review_inclusion_certainty(v_link_id);

  return jsonb_build_object(
    'review', (select s.title from knowledge.sources s where s.id = v_review_source_id),
    'study', (select s.label from knowledge.studies s where s.id = v_study_id),
    'registry', (select case when s.registry_kind is null then null
                             else s.registry_kind || ':' || s.registry_id end
                 from knowledge.studies s where s.id = v_study_id),
    'included_studies', (select count(*)::integer
                         from knowledge.review_included_studies ri
                         where ri.review_source_id = v_review_source_id),
    -- Det *lagrede* svaret, ikke det innsendte. Et svar som gjentok det
    -- kalleren sendte inn, kunne si «sikker» om en kobling databasen fortsatt
    -- førte som usikker.
    'certain', v_etter = 'documented',
    'clarified', v_for is not null and v_for is distinct from v_etter);
end;
$$;

comment on function api.link_review_included_study(text, text, text, text, text, boolean) is
  'Redaktørens vei til å si at en systematisk oversikt inkluderer en bestemt studie (SOURCE_POLICY.md §7, §11). Uten den kunne en oversikt og primærstudiene den bygger på, telles som uavhengige kilder, og de samme deltakerne ville talt to ganger. Oversikten navngis med en identifikator eller en entydig tittel, studien med forsøksregisternummeret sitt eller navnet sitt — og studien opprettes hvis Antidep ikke kjenner den, slik at artikkelen om den lander på den samme studien når den senere kommer inn. Et kall som sier noe annet om sikkerheten enn den gjeldende vurderingen, registrerer en avklaring, og svaret oppgir den sikkerheten som faktisk er lagret. Krever redaktørmandat.';

revoke execute on function api.link_review_included_study(text, text, text, text, text, boolean) from public;
grant execute on function api.link_review_included_study(text, text, text, text, text, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Grupperingen bærer usikkerheten dit den betyr noe
--
-- Uendret i hva den grupperer. Det nye er at en enhet som er deduplisert på
-- grunnlag av en usikker inklusjon, sier det — og navngir hvilke av studiene
-- det gjelder.
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
  v_usikre uuid[];
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

    -- Usikkerheten som betyr noe, er den som ligger under *dedupliseringen*: de
    -- studiene enhetens rolle hviler på, og som bare usikkert er inkludert. En
    -- usikker inklusjon av noe ingen andre har lagt fram, endrer ingen telling.
    select coalesce(array_agg(x), array[]::uuid[]) into v_usikre
    from unnest(v_overlapp) as t(x)
    where t.x = any (v_rad.usikre);

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
  'Hvor mange uavhengige deltakerutvalg et evidenssett hviler på, og hvordan funnene henger sammen (SOURCE_POLICY.md §7, §11). Én regel avgjør: en enhet er ikke uavhengig når alt den dekker, allerede er dekket av andre enheter i grunnlaget. Funn fra flere rapporter om den samme studien er én enhet. En rapport om en studie er alltid sitt eget utvalg — at en oversikt nevner den, gjør den ikke overflødig. En systematisk oversikt teller ikke som et eget utvalg når alle studiene den er registrert som å inkludere, er lagt fram for seg; dekker den noe ingen andre har lagt fram, står den igjen som uavhengig for nettopp det. En usikker inklusjon dedupliserer som en dokumentert — den forsiktige lesningen er å behandle materialet som overlappende — men enheten sier da at sammenslåingen hviler på en usikker relasjon, og navngir hvilke studier det gjelder. Rekkefølgen er deterministisk og grådig: rapportene først, så oversiktene med den bredeste først. Sletter ingenting: hvert funn står fortsatt i enheten sin.';

revoke execute on function knowledge.study_units_for_evidence(uuid[]) from public;

-- ----------------------------------------------------------------------------
-- 6. Avtrykket binder også den semantiske sikkerheten
--
-- Uten den ville en avklaring fra usikker til dokumentert ikke gjort et
-- utestående svar foreldet, og et svar avgitt da grunnlaget var usikkert, kunne
-- blitt registrert som om det var gitt på et avklart grunnlag.
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
                  || ':' || knowledge.study_list_key(u.value -> 'uncertain_inclusions')
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
