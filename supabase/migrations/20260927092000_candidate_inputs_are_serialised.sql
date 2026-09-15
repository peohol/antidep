-- ============================================================================
-- Migrasjon 009g — grunnlaget under en kandidat låses gjennom hele kontrollen
--
-- Migrasjon 009e krever at kandidaten fortsatt er den *gjeldende* når en
-- sluttkontroll registreres og når en publisering skjer: innholdet må bygge til
-- nøyaktig det avtrykket kandidaten bærer. Kontrollen ble gjort under radlåsene
-- på påstanden, revisjonen og kandidaten.
--
-- De tre låsene dekker ikke alt innholdet er bygget av.
--
-- `knowledge.candidate_content(uuid)` leser evidensfunnene, kontrollene deres,
-- kildene og kildestatusene. Skriveveien for en ekstraksjonskontroll låser
-- *evidensfunnet* (workflow.record_evidence_verification), ikke kandidaten — og
-- skriveveiene for en kildestøttekontroll og en evidensvurdering låser ingenting
-- i det hele tatt. En slik rad kunne derfor commite etter at avtrykket var
-- regnet ut og før hendelsen ble skrevet. Kontrollen var da et øyeblikksbilde og
-- ikke en garanti: en godkjenning kunne bli registrert, og en publisering
-- utført, for et innhold som allerede var foreldet.
--
-- Det er den samme feilformen migrasjon 005s og 006f lukket for de to andre
-- «det du faktisk så»-kontrollene, og den lukkes på den samme måten: med låser
-- som holder fra kontrollen til skrivingen.
--
-- ----------------------------------------------------------------------------
-- Én låsrekkefølge, og revisjonen er alltid først
--
-- `knowledge.lock_candidate_inputs(uuid)` tar radlåsene på alt kandidaten bygges
-- av: revisjonen, hvert lenket evidensfunn og hver kilde under dem, i stigende
-- id-rekkefølge. Den kalles av sluttkontrollen, publiseringen og rollbacken.
--
-- Revisjonen låses *først* i alle tre. Det er det som gjør rekkefølgen trygg:
-- to veier som begge rører kandidatinnholdet, møtes på revisjonslåsen før de
-- rekker å ta noe annet, og kan derfor ikke holde hver sin halvdel av det den
-- andre venter på.
--
-- ----------------------------------------------------------------------------
-- Skriveveier som ikke låser noe, gjør det nå — på tabellen, ikke på veien
--
-- En radlås kan ikke stoppe en INSERT av en ny rad. For de to tabellene hvis
-- skriveveier ikke låser noe, må låsen derfor tas av dem: tre små triggere tar
-- radlåsen på det objektet raden gjelder, før den settes inn.
--
--   workflow.claim_verifications     -> revisjonen
--   knowledge.evidence_assessments   -> revisjonen
--   workflow.evidence_verifications  -> evidensfunnet
--   workflow.review_decisions        -> revisjonen eller evidensfunnet
--
-- Triggeren er stedet og ikke skriveveien, av samme grunn som
-- `claim_evidence_links_reject_after_assessment` ligger på tabellen: en garanti
-- som hviler på at hver framtidig skrivevei husker å ta låsen, er ingen garanti.
-- De to første og den siste er nye låser; den på ekstraksjonskontrollen gjentar
-- en lås `workflow.record_evidence_verification` allerede tar, slik at også en
-- direkte innsetting er dekket.
--
-- Rapportert i kodegjennomgangen av PR #94.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 4, 5, 6
--   docs/DATABASE_ARCHITECTURE.md, docs/EVIDENCE_PIPELINE.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Låsen på alt kandidatinnholdet bygges av
-- ----------------------------------------------------------------------------
create function knowledge.lock_candidate_inputs(p_claim_revision_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
begin
  -- Revisjonen først. Alle veier som rører kandidatinnholdet tar denne låsen
  -- før noen annen, så de møtes her og kan ikke holde hver sin halvdel.
  perform 1
  from knowledge.claim_revisions r
  where r.id = p_claim_revision_id
  for update;

  -- Evidensfunnene, i stigende id-rekkefølge. Delt lås: flere lesere kan holde
  -- den samtidig, mens en ekstraksjonskontroll — som tar FOR UPDATE på funnet —
  -- må vente. Uten den kunne en kontroll commite mellom regningen av avtrykket
  -- og skrivingen, og gjøre innholdet et annet enn det som ble kontrollert.
  perform 1
  from knowledge.evidence_items e
  join knowledge.claim_evidence_links l on l.evidence_item_id = e.id
  where l.claim_revision_id = p_claim_revision_id
  order by e.id
  for share of e;

  -- Kildene. Kildestatusen står i det forseglede innholdet, og en
  -- tilbaketrekking av kilden er en oppdatering av raden — som må vente på den
  -- delte låsen. Samme lås workflow.assert_extraction_unchanged(uuid, text) tar,
  -- og i den samme rekkefølgen: funnet først, kilden etterpå.
  perform 1
  from knowledge.sources s
  where s.id in (
    select e.source_id
    from knowledge.evidence_items e
    join knowledge.claim_evidence_links l on l.evidence_item_id = e.id
    where l.claim_revision_id = p_claim_revision_id
  )
  order by s.id
  for share of s;
end;
$$;

comment on function knowledge.lock_candidate_inputs(uuid) is
  'Tar radlåsene på alt knowledge.candidate_content(uuid) bygges av: påstandsrevisjonen, hvert lenket evidensfunn og hver kilde under dem. Kalles av sluttkontrollen, publiseringen og rollbacken før de regner ut avtrykket, og låsene holdes ut transaksjonen — slik at kontrollen av at kandidaten fortsatt er den gjeldende, er en garanti og ikke et øyeblikksbilde. Revisjonen låses først i alle tre veiene, og det er det som gjør rekkefølgen trygg: to veier som rører det samme innholdet møtes der før de rekker å ta noe annet. Evidensfunnene og kildene låses delt og i stigende id-rekkefølge, i den samme rekkefølgen workflow.assert_extraction_unchanged(uuid, text) bruker.';

revoke execute on function knowledge.lock_candidate_inputs(uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. Skriveveiene uten lås får den av tabellen
-- ----------------------------------------------------------------------------
create function knowledge.lock_claim_revision_for_candidate_input()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform 1
  from knowledge.claim_revisions r
  where r.id = new.claim_revision_id
  for update;

  return new;
end;
$$;

comment on function knowledge.lock_claim_revision_for_candidate_input() is
  'Tar radlåsen på påstandsrevisjonen før en rad som er en del av kandidatinnholdet, settes inn. Ligger på tabellen og ikke på skriveveien, av samme grunn som de øvrige tverradsvaktene: en garanti som hviler på at hver framtidig skrivevei husker låsen, er ingen garanti. SECURITY DEFINER fordi knowledge har RLS med default deny og låsen må kunne tas uansett hvem som skriver; funksjonen leser ingenting ut.';

revoke execute on function knowledge.lock_claim_revision_for_candidate_input() from public;

create function knowledge.lock_evidence_item_for_candidate_input()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform 1
  from knowledge.evidence_items e
  where e.id = new.evidence_item_id
  for update;

  return new;
end;
$$;

comment on function knowledge.lock_evidence_item_for_candidate_input() is
  'Tar radlåsen på evidensfunnet før en rad som er en del av kandidatinnholdet eller av publiseringsgaten, settes inn. Gjentar for ekstraksjonskontrollen den låsen workflow.record_evidence_verification(uuid, uuid, uuid, text, text, text[], text, text) allerede tar, slik at også en direkte innsetting er dekket. SECURITY DEFINER av samme grunn som over.';

revoke execute on function knowledge.lock_evidence_item_for_candidate_input() from public;

-- Navnene begynner med «a», slik at de fyrer før de øvrige BEFORE INSERT-
-- triggerne på de samme tabellene: låsen skal tas før noen annen regel leser
-- tilstanden den skal gjelde for. PostgreSQL fyrer triggere i alfabetisk
-- rekkefølge.
create trigger a_claim_verifications_lock_revision
  before insert on workflow.claim_verifications
  for each row execute function knowledge.lock_claim_revision_for_candidate_input();

create trigger a_evidence_assessments_lock_revision
  before insert on knowledge.evidence_assessments
  for each row execute function knowledge.lock_claim_revision_for_candidate_input();

create trigger a_evidence_verifications_lock_evidence_item
  before insert on workflow.evidence_verifications
  for each row execute function knowledge.lock_evidence_item_for_candidate_input();

-- Reviewbeslutningene bærer nøyaktig én objektpeker
-- (review_decisions_single_object_check), og gaten leser begge slagene: G6 leser
-- tilbaketrekkingen av en ekstraksjon, og historikken leser beslutningen om en
-- revisjon. Låsen tas på det objektet raden faktisk gjelder.
create function knowledge.lock_review_decision_object_for_candidate_input()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.claim_revision_id is not null then
    perform 1
    from knowledge.claim_revisions r
    where r.id = new.claim_revision_id
    for update;
  end if;

  if new.evidence_item_id is not null then
    perform 1
    from knowledge.evidence_items e
    where e.id = new.evidence_item_id
    for update;
  end if;

  return new;
end;
$$;

comment on function knowledge.lock_review_decision_object_for_candidate_input() is
  'Tar radlåsen på det objektet en reviewbeslutning gjelder, før den settes inn. Publiseringsgatens G6 leser tilbaketrekkingen av en ekstraksjon, og uten låsen kunne en slik beslutning commite mellom gaten og publiseringshendelsen. Låser begge pekerne når begge er satt, selv om review_decisions_single_object_check garanterer at bare én er det: en vakt som hviler på en annen regel, slutter å gjelde stille hvis den andre endres.';

revoke execute on function knowledge.lock_review_decision_object_for_candidate_input() from public;

create trigger a_review_decisions_lock_object
  before insert on workflow.review_decisions
  for each row execute function knowledge.lock_review_decision_object_for_candidate_input();

-- ----------------------------------------------------------------------------
-- 3. De tre veiene tar låsen
-- ----------------------------------------------------------------------------
create or replace function api.record_candidate_final_control(
  p_candidate_id uuid,
  p_seen_candidate_digest text,
  p_decision text,
  p_rationale text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_candidate knowledge.candidates;
  v_claim_revision_id uuid;
  v_topic_concept_id uuid;
  v_reviewer_actor_id uuid;
  v_decision workflow.final_control_decision;
  v_current_digest text;
  v_control_id uuid;
begin
  begin
    v_decision := p_decision::workflow.final_control_decision;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke et kjent utfall av en sluttkontroll.', p_decision),
        hint = 'Gyldige utfall er approved, rejected og changes_requested.';
  end;

  select c.claim_revision_id into v_claim_revision_id
  from knowledge.candidates c
  where c.id = p_candidate_id;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kandidaten %L finnes ikke.', p_candidate_id);
  end if;

  -- Grunnlaget låses først, og deretter kandidaten. Rekkefølgen er den samme
  -- som publiseringen bruker, og revisjonslåsen er den ene alle veier som rører
  -- kandidatinnholdet tar først — derfor kan de ikke gripe inn i hverandre.
  --
  -- Uten grunnlagslåsen ville kontrollen av at innholdet fortsatt bygger til
  -- avtrykket, vært et øyeblikksbilde: en ekstraksjonskontroll låser
  -- evidensfunnet og ikke kandidaten, og kunne commite mellom regningen og
  -- innsettingen. Da ville en godkjenning blitt registrert for en kandidat som
  -- allerede var foreldet.
  perform knowledge.lock_candidate_inputs(v_claim_revision_id);

  select c.* into v_candidate
  from knowledge.candidates c
  where c.id = p_candidate_id
  for update;

  select cl.topic_concept_id into v_topic_concept_id
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  where r.id = v_candidate.claim_revision_id;

  v_reviewer_actor_id := workflow.assert_reviewer_authorized(v_topic_concept_id);

  if p_seen_candidate_digest is distinct from v_candidate.candidate_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Sluttkontrollen viser til et annet kandidatavtrykk enn kandidatens eget.',
      hint = 'Avtrykket skal kopieres uendret fra den kandidaten som faktisk ble lest. En godkjenning avgitt mot ett innhold og registrert mot et annet, ville vært en attestasjon uten dekning (ANTIDEP_CONSTITUTION.md regel 5).';
  end if;

  v_current_digest := knowledge.source_version_content_hash(
    knowledge.candidate_content(v_candidate.claim_revision_id)::text
  );
  if v_current_digest is distinct from v_candidate.candidate_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Grunnlaget kandidaten ble forseglet av, er endret siden den ble bygget.',
      hint = format(
        'Kandidaten bærer %s, mens innholdet nå bygger til %s. Bygg kandidaten på nytt med api.build_candidate(uuid) og sluttkontroller den nye; en godkjenning av et innhold som ikke lenger er det som ligger der, er ikke en godkjenning av noe (ANTIDEP_CONSTITUTION.md regel 5).',
        v_candidate.candidate_digest, v_current_digest
      );
  end if;

  insert into workflow.candidate_final_controls (
    candidate_id, candidate_digest, decision, rationale,
    reviewer_actor_id, reviewer_actor_type
  )
  values (
    v_candidate.id, v_candidate.candidate_digest, v_decision, btrim(coalesce(p_rationale, '')),
    v_reviewer_actor_id, 'human'
  )
  returning id into v_control_id;

  return jsonb_build_object(
    'candidate_final_control_id', v_control_id,
    'candidate_id', v_candidate.id,
    'candidate_digest', v_candidate.candidate_digest,
    'decision', v_decision::text,
    -- Sagt eksplisitt, fordi det er den ene misforståelsen som ville vært
    -- alvorlig: en godkjenning er ikke en publisering. Publiseringen er en egen
    -- handling, med et annet mandat, i api.publish_candidate(uuid, text, text).
    'published', false
  );
end;
$$;

create or replace function knowledge.publish_claim_revision(
  p_claim_revision_id uuid,
  p_publisher_actor_id uuid,
  p_reason text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_claim_id uuid;
  v_topic_concept_id uuid;
  v_revision_number integer;
  v_current_revision_id uuid;
  v_current_revision_number integer;
  v_current_candidate_id uuid;
  v_current_candidate_digest text;
  v_previous_event_id uuid;
  v_candidate knowledge.candidates;
  v_control workflow.candidate_final_controls;
  v_action knowledge.publication_action;
  v_event_id uuid;
begin
  select r.claim_id, r.revision_number
    into v_claim_id, v_revision_number
  from knowledge.claim_revisions r
  where r.id = p_claim_revision_id;

  if not found then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Påstandsrevisjon %L finnes ikke.', p_claim_revision_id),
      hint = 'Publisering peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3).';
  end if;

  -- Låsene, i den faste rekkefølgen påstand -> revisjon -> kandidat.
  select c.topic_concept_id, c.current_published_revision_id, c.current_published_candidate_id
    into v_topic_concept_id, v_current_revision_id, v_current_candidate_id
  from knowledge.claims c
  where c.id = v_claim_id
  for update;

  -- Revisjonen *og* alt kandidatinnholdet bygges av: evidensfunnene og kildene
  -- deres. Uten dem ville gaten vært et øyeblikksbilde — en ekstraksjonskontroll
  -- låser funnet og ikke kandidaten, og kunne commite mellom G11 og hendelsen.
  perform knowledge.lock_candidate_inputs(p_claim_revision_id);

  perform knowledge.assert_publisher_authorized(p_publisher_actor_id, v_topic_concept_id);

  -- Kandidaten hentes og låses *før* gaten. Låsen er den samme som
  -- sluttkontrollens skrivevei tar, så en ny sluttkontroll kan ikke commite i
  -- vinduet mellom G12 og innsettingen av hendelsen.
  v_candidate := knowledge.current_candidate(p_claim_revision_id);
  if v_candidate.id is not null then
    perform 1 from knowledge.candidates c where c.id = v_candidate.id for share;
    -- Lest på nytt under låsen: den første lesningen var utenfor den.
    v_candidate := knowledge.current_candidate(p_claim_revision_id);
  end if;

  perform knowledge.assert_claim_revision_publishable(p_claim_revision_id);

  v_control := workflow.current_candidate_final_control(v_candidate.id);

  if v_current_revision_id is null then
    v_action := 'publish';
  elsif v_current_revision_id = p_claim_revision_id then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Revisjon %L er allerede den publiserte.', p_claim_revision_id),
      hint = 'Publiseringshistorikken skal registrere reelle tilstandsendringer. En publisering som ikke endrer noe er ikke en hendelse.';
  else
    select r.revision_number into v_current_revision_number
    from knowledge.claim_revisions r
    where r.id = v_current_revision_id;

    if v_revision_number < v_current_revision_number then
      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'Revisjon %L er eldre enn den publiserte revisjonen og kan ikke erstatte den.',
          p_claim_revision_id
        ),
        hint = 'Å gå tilbake til en tidligere revisjon er en rollback, ikke en erstatning, og skal registreres som det (DATABASE_ARCHITECTURE.md §40). Bruk knowledge.rollback_claim_publication().';
    end if;

    v_action := 'replace';
  end if;

  select c.candidate_digest into v_current_candidate_digest
  from knowledge.candidates c
  where c.id = v_current_candidate_id;

  v_previous_event_id := (knowledge.publication_head_event(v_claim_id)).id;

  update knowledge.claims
  set current_published_revision_id = p_claim_revision_id,
      current_published_candidate_id = v_candidate.id
  where id = v_claim_id;

  insert into knowledge.publication_events (
    claim_id, action, revision_id, revision_number,
    previous_revision_id, previous_revision_number, previous_event_id,
    candidate_id, candidate_digest, final_control_id, final_control_decision,
    previous_candidate_id, previous_candidate_digest,
    published_by_actor_id, published_by_actor_type, reason, published_at
  )
  select
    v_claim_id, v_action, p_claim_revision_id, v_revision_number,
    v_current_revision_id, v_current_revision_number, v_previous_event_id,
    v_candidate.id, v_candidate.candidate_digest, v_control.id, v_control.decision,
    v_current_candidate_id, v_current_candidate_digest,
    p_publisher_actor_id, a.actor_type, p_reason, now()
  from provenance.actors a
  where a.id = p_publisher_actor_id
  returning id into v_event_id;

  return v_event_id;
end;
$$;

create or replace function knowledge.rollback_claim_publication(
  p_claim_id uuid,
  p_target_revision_id uuid,
  p_publisher_actor_id uuid,
  p_reason text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_topic_concept_id uuid;
  v_current_revision_id uuid;
  v_current_revision_number integer;
  v_current_candidate_id uuid;
  v_current_candidate_digest text;
  v_target_claim_id uuid;
  v_target_revision_number integer;
  v_previous_event_id uuid;
  v_candidate knowledge.candidates;
  v_control workflow.candidate_final_controls;
  v_event_id uuid;
begin
  select c.topic_concept_id, c.current_published_revision_id, c.current_published_candidate_id
    into v_topic_concept_id, v_current_revision_id, v_current_candidate_id
  from knowledge.claims c
  where c.id = p_claim_id
  for update;

  if not found then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Påstand %L finnes ikke.', p_claim_id),
      hint = 'Kontroller påstands-ID-en.';
  end if;

  if v_current_revision_id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Påstand %L har ingen publisert revisjon å rulle tilbake fra.', p_claim_id),
      hint = 'En rollback flytter pekeren fra den gjeldende revisjonen tilbake til en tidligere publisert. Er ingenting publisert, er handlingen en publisering.';
  end if;

  select r.claim_id, r.revision_number
    into v_target_claim_id, v_target_revision_number
  from knowledge.claim_revisions r
  where r.id = p_target_revision_id;

  if not found or v_target_claim_id <> p_claim_id then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Revisjon %L finnes ikke eller tilhører en annen påstand enn %L.',
        p_target_revision_id, p_claim_id
      ),
      hint = 'Publiseringspekeren kan bare peke på en revisjon av den samme påstanden (DATABASE_ARCHITECTURE.md §58).';
  end if;

  perform knowledge.lock_candidate_inputs(p_target_revision_id);

  if p_target_revision_id = v_current_revision_id then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Revisjon %L er allerede den publiserte.', p_target_revision_id),
      hint = 'Publiseringshistorikken skal registrere reelle tilstandsendringer.';
  end if;

  select r.revision_number into v_current_revision_number
  from knowledge.claim_revisions r
  where r.id = v_current_revision_id;

  if v_target_revision_number > v_current_revision_number then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L er nyere enn den publiserte revisjonen og er derfor ikke en rollback.',
        p_target_revision_id
      ),
      hint = 'Å gå framover til en nyere revisjon er en erstatning. Bruk knowledge.publish_claim_revision().';
  end if;

  -- Målet må ha vært publisert før. Uten det kravet ville «rollback» vært en
  -- vilkårlig flytting bakover til noe Antidep aldri har sagt.
  if not exists (
    select 1
    from knowledge.publication_events e
    where e.revision_id = p_target_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har aldri vært publisert og kan derfor ikke rulles tilbake til.',
        p_target_revision_id
      ),
      hint = 'En rollback flytter pekeren tilbake til en tidligere publisert revisjon (DATABASE_ARCHITECTURE.md §40). Skal en revisjon som aldri har vært publisert tas i bruk, er det en publisering.';
  end if;

  perform knowledge.assert_publisher_authorized(p_publisher_actor_id, v_topic_concept_id);

  v_candidate := knowledge.current_candidate(p_target_revision_id);
  if v_candidate.id is not null then
    perform 1 from knowledge.candidates c where c.id = v_candidate.id for share;
    v_candidate := knowledge.current_candidate(p_target_revision_id);
  end if;

  -- Gaten kjøres på nytt på målrevisjonen. Det er ikke overflødig: en revisjon
  -- som var publiserbar i fjor kan ha fått et senere avvist verifikasjonsfunn,
  -- en tilbaketrukket kilde eller en omgjort sluttkontroll. Å rulle tilbake til
  -- den ville da vært å publisere noe som ikke lenger holder.
  perform knowledge.assert_claim_revision_publishable(p_target_revision_id);

  -- Målets gjeldende kandidat må være den som faktisk har vært publisert. Uten
  -- dette kravet kunne en rollback tatt i bruk et innhold som aldri har vært
  -- vist — gaten ville sluppet det gjennom, fordi det er godkjent, men
  -- «tilbake» ville da betydd «til noe nytt».
  if not exists (
    select 1
    from knowledge.publication_events e
    where e.candidate_id = v_candidate.id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Det gjeldende innholdet for revisjon %L har aldri vært publisert, og en rollback kan ikke ta det i bruk.',
        p_target_revision_id
      ),
      hint = 'Grunnlaget under revisjonen er endret siden den var publisert, så den gjeldende kandidaten er et annet innhold enn det som faktisk ble vist. Et innhold som aldri har vært publisert, tas i bruk ved en publisering — ikke ved en rollback (DATABASE_ARCHITECTURE.md §40).';
  end if;

  v_control := workflow.current_candidate_final_control(v_candidate.id);

  select c.candidate_digest into v_current_candidate_digest
  from knowledge.candidates c
  where c.id = v_current_candidate_id;

  v_previous_event_id := (knowledge.publication_head_event(p_claim_id)).id;

  update knowledge.claims
  set current_published_revision_id = p_target_revision_id,
      current_published_candidate_id = v_candidate.id
  where id = p_claim_id;

  insert into knowledge.publication_events (
    claim_id, action, revision_id, revision_number,
    previous_revision_id, previous_revision_number, previous_event_id,
    candidate_id, candidate_digest, final_control_id, final_control_decision,
    previous_candidate_id, previous_candidate_digest,
    published_by_actor_id, published_by_actor_type, reason, published_at
  )
  select
    p_claim_id, 'rollback', p_target_revision_id, v_target_revision_number,
    v_current_revision_id, v_current_revision_number, v_previous_event_id,
    v_candidate.id, v_candidate.candidate_digest, v_control.id, v_control.decision,
    v_current_candidate_id, v_current_candidate_digest,
    p_publisher_actor_id, a.actor_type, p_reason, now()
  from provenance.actors a
  where a.id = p_publisher_actor_id
  returning id into v_event_id;

  return v_event_id;
end;
$$;
