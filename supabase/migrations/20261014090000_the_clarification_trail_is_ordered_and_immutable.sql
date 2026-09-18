-- Migrasjon 013q — sporet er ordnet, uforanderlig, og usikkerheten smitter
--
-- 013p gjorde usikkerheten synlig og avklaringen mulig. Gjennomgangen fant tre
-- ting i den løsningen, og alle tre var reelle:
--
--   1. **Usikkerheten kunne forsvinne mellom to oversikter, avhengig av
--      rekkefølgen.** Dekningen husket *hvilke* studier som var dekket, men
--      ikke hvor sikkert de var det. Inkluderte R1 studie S usikkert og R2 den
--      samme S dokumentert, uten at noen rapport om S var lagt fram, og R1 ble
--      lest først, ble R1 uavhengig uten overlapp (og dermed uten
--      usikkerhetsmerke), mens R2 ble avledet mot en dekning R1 bare *antok*.
--      Hele grunnlaget endte med `uncertain_linkage = 0`, selv om
--      dedupliseringen av R2 hvilte på R1s usikre kobling. I motsatt rekkefølge
--      kom usikkerheten fram. Et svar som avhenger av lesningsrekkefølgen, er
--      ikke et svar.
--   2. **Sporet var dokumentert som append-only uten å være det.** Tabellene
--      fra 013m, 013n og 013p hadde RLS og default deny, men ingen
--      mutasjonsvakt. Resten av repoet bruker
--      `knowledge.reject_append_only_mutation(...)` nettopp for å gjøre
--      historikken uforanderlig også mot en privilegert eller feilaktig
--      skrivevei — og migrasjonene sa uttrykkelig at den første vurderingen
--      «står urørt», mens en UPDATE kunne skrive den om.
--   3. **«Siste vurdering» hadde ingen sikker rekkefølge.** `created_at` er
--      `now()`, altså transaksjonens starttid. To avklaringer i den samme
--      transaksjonen fikk identisk tidsstempel, og `id desc` er tilfeldig
--      UUID-rekkefølge: usikker → dokumentert → usikker kunne etterpå leses som
--      dokumentert. Skriveveien låste heller ikke koblingen før den leste
--      gjeldende tilstand, så to samtidige avklaringer kunne begge lese det
--      samme utgangspunktet.

-- ----------------------------------------------------------------------------
-- 1. Sporet er uforanderlig, ikke bare kalt uforanderlig
--
-- Samme vakt som resten av historikktabellene i repoet. Vakten fyrer før
-- tidsstempeltriggeren, fordi triggere kjøres i navnerekkefølge og «reject»
-- kommer før «set».
-- ----------------------------------------------------------------------------
create trigger review_included_studies_reject_mutation
  before update or delete on knowledge.review_included_studies
  for each row execute function knowledge.reject_append_only_mutation(
    'Registrer en ny vurdering i knowledge.review_inclusion_assessments hvis sikkerheten har endret seg. Den første inklusjonsvurderingen ble gjort av noen, på et grunnlag, og skal fortsatt kunne leses som deres.'
  );

create trigger study_identity_upgrades_reject_mutation
  before update or delete on knowledge.study_identity_upgrades
  for each row execute function knowledge.reject_append_only_mutation(
    'En oppgradering av en studieidentitet dokumenterer at to identiteter ble regnet som den samme. Var den feil, er det en ny opplysning som må registreres — raden forteller hva Antidep faktisk gjorde.'
  );

create trigger review_inclusion_assessments_reject_mutation
  before update or delete on knowledge.review_inclusion_assessments
  for each row execute function knowledge.reject_append_only_mutation(
    'Registrer en ny vurdering for den endrede sikkerheten. En avklaring som skrives om i ettertid, er ikke et spor — da kan ingen se hva som faktisk ble ment da svaret ble avgitt.'
  );

-- ----------------------------------------------------------------------------
-- 2. Rekkefølgen på vurderingene er databasens, ikke klokkens
--
-- Samme form som `knowledge.claim_revisions.revision_number`: et løpenummer per
-- kobling, med unikhet. `created_at` er transaksjonens starttid og kan ikke
-- skille to vurderinger i den samme transaksjonen; et løpenummer kan.
-- ----------------------------------------------------------------------------
alter table knowledge.review_inclusion_assessments
  add column assessment_number integer;

update knowledge.review_inclusion_assessments a
set assessment_number = n.nr
from (
  select id, row_number() over (
           partition by review_included_study_id
           order by created_at, id) as nr
  from knowledge.review_inclusion_assessments
) n
where n.id = a.id;

alter table knowledge.review_inclusion_assessments
  alter column assessment_number set not null;

alter table knowledge.review_inclusion_assessments
  add constraint review_inclusion_assessments_number_key
    unique (review_included_study_id, assessment_number);

alter table knowledge.review_inclusion_assessments
  add constraint review_inclusion_assessments_number_positive_check
    check (assessment_number >= 1);

comment on column knowledge.review_inclusion_assessments.assessment_number is
  'Løpenummer for vurderingen, per kobling, fra 1. Rekkefølgen kan ikke leses av created_at: det er transaksjonens starttid, og to vurderinger i den samme transaksjonen får identisk verdi. Uten nummeret ville «den siste vurderingen» blitt avgjort av tilfeldig UUID-rekkefølge, og usikker → dokumentert → usikker kunne etterpå blitt lest som dokumentert.';

create or replace function knowledge.review_inclusion_certainty(p_review_included_study_id uuid)
  returns knowledge.study_link_certainty
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(
    (select a.certainty
     from knowledge.review_inclusion_assessments a
     where a.review_included_study_id = p_review_included_study_id
     order by a.assessment_number desc
     limit 1),
    (select ri.certainty
     from knowledge.review_included_studies ri
     where ri.id = p_review_included_study_id));
$$;

comment on function knowledge.review_inclusion_certainty(uuid) is
  'Hvor sikker en oversikts inklusjon av en studie er nå: vurderingen med det høyeste løpenummeret, ellers den første vurderingen på koblingsraden. Ett sted, slik at grupperingen, redaktørsvaret og avtrykket ikke kan lese tre forskjellige verdier — og på løpenummer og ikke på tidsstempel, fordi to vurderinger i den samme transaksjonen deler tidsstempel.';

revoke execute on function knowledge.review_inclusion_certainty(uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. Skriveveien låser koblingen før den leser den
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

  -- Låsen står på koblingsraden og holder helt til transaksjonen er ferdig.
  -- Uten den kunne to samtidige avklaringer begge lest den samme gjeldende
  -- tilstanden, og begge skrevet en vurdering med det samme «forrige».
  select ri.id into v_link_id
  from knowledge.review_included_studies ri
  where ri.review_source_id = p_review_source_id and ri.study_id = p_study_id
  for update;

  if v_link_id is null then
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

  -- Koblingen finnes. Sier kalleren det samme som den gjeldende vurderingen, er
  -- dette den samme opplysningen på nytt, og ingenting skjer. Sier den noe
  -- annet, er det en ny vurdering — og den legges ved siden av den forrige, med
  -- sitt eget grunnlag og sin egen proveniens. Den første vurderingen står
  -- urørt: den ble gjort av noen, og den skal fortsatt kunne leses som deres.
  v_gjeldende := knowledge.review_inclusion_certainty(v_link_id);

  if v_gjeldende is distinct from p_certainty then
    select coalesce(max(a.assessment_number), 0) + 1 into v_nummer
    from knowledge.review_inclusion_assessments a
    where a.review_included_study_id = v_link_id;

    insert into knowledge.review_inclusion_assessments
      (review_included_study_id, assessment_number, previous_certainty, certainty,
       basis, assessed_by_actor_id, assessed_by_agent_run_id)
    values (v_link_id, v_nummer, v_gjeldende, p_certainty, btrim(p_inclusion_basis),
            p_actor_id, p_agent_run_id);
  end if;

  return v_link_id;
end;
$$;

comment on function knowledge.link_review_included_study(uuid, uuid, text, knowledge.study_link_certainty, uuid, uuid) is
  'Registrerer at en systematisk oversikt inkluderer en studie (SOURCE_POLICY.md §7, §11), slik at oversikten og primærstudien ikke telles som to uavhengige deltakerutvalg. Grunnlaget er påkrevd og proveniensen er enten et menneske eller en agentkjøring. Et kall som sier noe annet om sikkerheten enn den gjeldende vurderingen, registrerer en ny vurdering med neste løpenummer ved siden av den forrige framfor å skrive over den — en avklaring er en ny opplysning, ikke en retting av hvem den første vurderingen kom fra. Sier kallet det samme, endres ingenting. Koblingsraden låses før gjeldende tilstand leses, slik at to samtidige avklaringer serialiseres framfor å lese det samme utgangspunktet. Returnerer koblingens id.';

revoke execute on function knowledge.link_review_included_study(uuid, uuid, text, knowledge.study_link_certainty, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Dekningen bærer hvor sikkert en studie er dekket
--
-- Uendret i hva den grupperer. Det nye er at dekningen skiller mellom en studie
-- som er lagt fram, og en studie noen bare *antar* ligger i materialet — slik at
-- et overlapp er usikkert når enten denne enhetens kobling eller den koblingen
-- som dekket studien først, er usikker.
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
  'Hvor mange uavhengige deltakerutvalg et evidenssett hviler på, og hvordan funnene henger sammen (SOURCE_POLICY.md §7, §11). Én regel avgjør: en enhet er ikke uavhengig når alt den dekker, allerede er dekket av andre enheter i grunnlaget. Funn fra flere rapporter om den samme studien er én enhet. En rapport om en studie er alltid sitt eget utvalg — at en oversikt nevner den, gjør den ikke overflødig. En systematisk oversikt teller ikke som et eget utvalg når alle studiene den er registrert som å inkludere, er lagt fram for seg; dekker den noe ingen andre har lagt fram, står den igjen som uavhengig for nettopp det. En usikker inklusjon dedupliserer som en dokumentert — den forsiktige lesningen er å behandle materialet som overlappende — men enheten sier da at sammenslåingen hviler på en usikker relasjon, og navngir hvilke studier det gjelder. Usikkerheten følger dekningen og ikke bare enhetens egen kobling: er studien bare antatt lagt fram av den enheten som dekket den først, er overlappet usikkert uansett hvilken vei det leses. Rekkefølgen er deterministisk og grådig: rapportene først, så oversiktene med den bredeste først. Sletter ingenting: hvert funn står fortsatt i enheten sin.';

revoke execute on function knowledge.study_units_for_evidence(uuid[]) from public;
