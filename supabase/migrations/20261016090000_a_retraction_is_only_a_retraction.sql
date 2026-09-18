-- Migrasjon 013s — en tilbaketrekking er bare en tilbaketrekking
--
-- 013r ga tilbaketrekkingen en append-only tilstand og et virksomt vern mot at
-- en feilregistrering ble permanent. Men veien inn leste sikkerheten på feil
-- tidspunkt, og gjennomgangen fant det:
--
--   **En samtidig avklaring kunne bli skrevet tilbake av en tilbaketrekking.**
--   `api.retract_review_included_study(...)` regnet ut gjeldende sikkerhet som
--   et *funksjonsargument*, altså før den indre skriveveien hadde tatt
--   radlåsen. Sto koblingen som `uncertain`, og økt A avklarte den til
--   `documented` og holdt låsen, leste økt B fortsatt `uncertain` og ventet.
--   Når A committet, skrev B en vurdering `documented -> uncertain` sammen med
--   `included -> retracted`. Tilbaketrekkingen hadde da i stillhet omgjort A
--   sin faglige avklaring, og sporet sa at den som bare trakk koblingen
--   tilbake, også endret sikkerhetsvurderingen. Det er nettopp den forvekslingen
--   sporet finnes for å hindre.
--
--   Samtidighetsprøven låste dessuten oppførselen inn: den kalte den indre
--   funksjonen direkte med en fast `uncertain`, og forventet kjeden den feilen
--   ga. Den viste at radlåsen virket, men ikke at en tilbaketrekking lar
--   sikkerheten stå.
--
-- ----------------------------------------------------------------------------
-- Rettingen: sikkerheten kan bæres av låsen i stedet for av kalleren
--
-- `p_certainty = null` betyr nå «behold den sikkerheten som gjelder når låsen
-- er vunnet». Det er den eneste måten en ren tilstandsendring kan uttrykkes
-- uten å ta stilling til noe den ikke handler om — og avgjørelsen tas da
-- *inne* i den låste delen, der den gjeldende verdien er den virkelige.
--
-- Alternativet var en egen indre tilbaketrekkingsvei. Den ville hatt sin egen
-- lås, sin egen nummerering og sin egen kappløpsflate å holde i orden, og 013q
-- sin lærepenge var at det bare finnes én rekkefølge fordi det bare finnes ett
-- sted som skriver.

create or replace function knowledge.link_review_included_study(
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
  v_ny_certainty knowledge.study_link_certainty;
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
  -- Alt som avhenger av gjeldende tilstand, leses *etter* den — ellers kunne en
  -- verdi lest på forhånd skrevet tilbake en avklaring som ble committet mens
  -- dette kallet ventet.
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

    -- «Behold gjeldende sikkerhet» har ingen mening for en kobling som ikke
    -- finnes: det finnes ingen gjeldende sikkerhet å beholde.
    if p_certainty is null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'En ny inklusjonskobling må si hvor sikker den er.',
        hint = 'NULL betyr «behold den sikkerheten som gjelder», og en kobling som registreres for første gang, har ingen.';
    end if;

    -- Taper vi kappløpet mot en annen skrivevei, er raden den andre laget, den
    -- samme koblingen — og da fortsetter vi på den framfor å feile på
    -- unikhetskravet.
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

  -- Koblingen finnes, og låsen er vunnet. Nå — og ikke før — er den gjeldende
  -- tilstanden den virkelige.
  v_certainty := knowledge.review_inclusion_certainty(v_link_id);
  v_state := case when knowledge.review_inclusion_active(v_link_id)
                  then 'included'::knowledge.review_inclusion_state
                  else 'retracted'::knowledge.review_inclusion_state end;

  -- En ren tilstandsendring tar ikke stilling til sikkerheten: den beholder
  -- den som gjelder. Uten dette ville en tilbaketrekking som ventet på låsen,
  -- skrevet tilbake en avklaring som ble committet i mellomtiden — og sporet
  -- ville tilskrevet sikkerhetsendringen den som bare trakk koblingen tilbake.
  v_ny_certainty := coalesce(p_certainty, v_certainty);

  -- Sier kalleren det samme som det som gjelder nå, er dette den samme
  -- opplysningen på nytt, og ingenting skjer. Sier den noe annet — om
  -- sikkerheten, om tilstanden, eller om begge — er det en ny vurdering, og
  -- den legges ved siden av den forrige med sitt eget grunnlag og sin egen
  -- proveniens. Ingen tidligere rad skrives over.
  if (v_certainty, v_state) is distinct from (v_ny_certainty, p_state) then
    select coalesce(max(a.assessment_number), 0) + 1 into v_nummer
    from knowledge.review_inclusion_assessments a
    where a.review_included_study_id = v_link_id;

    insert into knowledge.review_inclusion_assessments
      (review_included_study_id, assessment_number,
       previous_certainty, certainty, previous_state, state,
       basis, assessed_by_actor_id, assessed_by_agent_run_id)
    values (v_link_id, v_nummer, v_certainty, v_ny_certainty, v_state, p_state,
            btrim(p_inclusion_basis), p_actor_id, p_agent_run_id);
  end if;

  return v_link_id;
end;
$$;

comment on function knowledge.link_review_included_study(uuid, uuid, text, knowledge.study_link_certainty, uuid, uuid, knowledge.review_inclusion_state) is
  'Registrerer hva som gjelder for en oversikts inklusjon av en studie (SOURCE_POLICY.md §7, §11): hvor sikker koblingen er, og om den gjelder. Grunnlaget er påkrevd og proveniensen er enten et menneske eller en agentkjøring. `p_certainty = null` betyr «behold den sikkerheten som gjelder», og er måten en ren tilstandsendring uttrykkes: avgjørelsen tas inne i den låste delen, slik at en tilbaketrekking som ventet på låsen, ikke skriver tilbake en avklaring som ble committet i mellomtiden. NULL avvises for en kobling som registreres for første gang, fordi det ikke finnes noen gjeldende sikkerhet å beholde. Sier kallet noe annet enn det som gjelder, registreres en ny vurdering med neste løpenummer ved siden av den forrige framfor å skrive over den; sier det det samme, endres ingenting. En tilbaketrekking av en kobling som ikke finnes, avvises. Koblingsraden låses før gjeldende tilstand leses, slik at to samtidige endringer serialiseres.';

revoke execute on function knowledge.link_review_included_study(uuid, uuid, text, knowledge.study_link_certainty, uuid, uuid, knowledge.review_inclusion_state) from public;

-- ----------------------------------------------------------------------------
-- Tilbaketrekkingen sier ingenting om sikkerheten
-- ----------------------------------------------------------------------------
create or replace function api.retract_review_included_study(
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

  -- Sikkerheten leses ikke her. NULL sier «behold den som gjelder», og hvilken
  -- det er, avgjøres inne i skriveveien etter at radlåsen er vunnet. Leste vi
  -- den her, ville en avklaring som ble committet mens dette kallet ventet på
  -- låsen, blitt skrevet tilbake — og sporet ville tilskrevet den endringen
  -- den som bare trakk koblingen tilbake.
  v_link_id := knowledge.link_review_included_study(
    v_review_source_id, v_study_id, p_basis,
    null::knowledge.study_link_certainty,
    v_actor_id, null, 'retracted'::knowledge.review_inclusion_state);

  return jsonb_build_object(
    'review', (select s.title from knowledge.sources s where s.id = v_review_source_id),
    'study', (select s.label from knowledge.studies s where s.id = v_study_id),
    'registry', (select case when s.registry_kind is null then null
                             else s.registry_kind || ':' || s.registry_id end
                 from knowledge.studies s where s.id = v_study_id),
    'active', knowledge.review_inclusion_active(v_link_id),
    -- Sikkerheten står som den var. Tilbaketrekkingen sier at koblingen ikke
    -- gjelder, ikke at den var dårligere dokumentert enn noen mente.
    'certain', knowledge.review_inclusion_certainty(v_link_id) = 'documented',
    'included_studies', (select count(*)::integer
                         from knowledge.review_included_studies ri
                         where ri.review_source_id = v_review_source_id
                           and knowledge.review_inclusion_active(ri.id)));
end;
$$;

comment on function api.retract_review_included_study(text, text, text, text, text) is
  'Redaktørens vei til å trekke tilbake en inklusjonskobling som viste seg å være feil — oversikten inkluderte ved nærmere kontroll ikke studien likevel (SOURCE_POLICY.md §7, §11). Uten den ville en feilregistrering vært permanent virksom i grupperingen, og et reelt uavhengig bidrag ville blitt undertrykt i syntesen og i GRADE-leddet for alltid. Tilbaketrekkingen er en *ren* tilstandsendring: den lar sikkerhetsvurderingen stå som den er, også når en annen økt avklarer den samtidig. Den sletter ingenting — den er en ny vurdering i sporet, med grunnlaget og hvem som sto bak — og den kan selv trekkes tilbake ved å registrere inklusjonen på nytt. En tilbaketrekking av en kobling som ikke finnes, avvises. Krever redaktørmandat.';

revoke execute on function api.retract_review_included_study(text, text, text, text, text) from public;
grant execute on function api.retract_review_included_study(text, text, text, text, text) to authenticated;
