-- ============================================================================
-- Migrasjon 014h — søkeleddene tar igjen sine egne overganger
--
-- Kjedeovergangene er databasens egne: det kallet som gjør en overgang mulig,
-- legger arbeidet i køen i den samme transaksjonen (012b). Det som ikke har et
-- slikt kall, eller der overgangen sviktet, tar
-- `api.resume_chain_transitions(...)` igjen — og den kjøres av de
-- deterministiske kontrolleddene hvert kvarter.
--
-- I produksjon har den aldri kjørt. Arbeidsflyten «Deterministiske kontroller»
-- har ikke legitimasjonen sin, og avslutter grønt med en advarsel. Det er
-- ingen feil i seg selv, men det betyr at alt kildeleddene bare fikk av
-- rekonsilieringen, aldri kom. Etter 014g er det tre slike steder:
--
--   * En redaktør som registrerer et søkespor for hånd, fører et søk inn i
--     kildeoppdagelsens grunnlag. Grunnlaget vokser, og den ledige oppgaven
--     slutter å gjelde (014g) — men ingenting la inn den nye. Planen sto med
--     en oppgave agenten ikke kunne hente, og uten en den kunne.
--   * En plan som tas ut av pause, fikk ingen oppgave for en runde som ble
--     ferdig søkt mens den sto: overgangen gjør ingenting for en plan på pause,
--     og ingenting kjørte den igjen etterpå.
--   * En oppgave en kjøring holdt da runden vokste, får gjøre seg ferdig eller
--     løpe ut før den erstattes (014g). Løper den ut, er det ingen hendelse som
--     legger inn den nye — bare den neste rekonsilieringen.
--
-- Og dekningskontrollens motsøk åpnes av kildeoppdagelsens import, eller av
-- rekonsilieringen så snart planen har et utført søk. Uten rekonsilieringen
-- ventet dekningskontrollen på at kildeoppdagelsen var helt ferdig. Etter
-- 014g-reparasjonen har hver åpen plan sin runde, men en ny bestilling ville
-- ikke fått den før da.
--
-- Rettingen er at kildeleddene ikke er avhengige av en kjøring som ikke er
-- deres:
--
--   * Redaktørens to handlinger på en søkeplan — registrere et spor for hånd og
--     ta planen ut av pause — kjører begge kildeleddenes overgang selv, i den
--     samme transaksjonen, som lukkingen av en søkerunde alltid har gjort.
--   * Søkeleddenes egen maskinelle kjøring, som går hver halvtime i produksjon,
--     tar igjen sitt eget ledd først: `api.resume_search_round_tasks(...)`,
--     med leddets egen identitet. Det er den samme feiingen
--     `api.resume_chain_transitions(...)` gjør for søkeplanene — én funksjon,
--     `workflow.resume_search_round_tasks(...)`, med én markør per ledd —
--     slik at de to ikke kan komme til å gjøre hver sin ting.
--   * Invarianten fra 014g er en funksjon
--     (`workflow.monograph_search_task_invariant_problem()`), lest av
--     migrasjonen og av prøvene.
--
-- Ingen jobber, hendelser eller kliniske rader slettes eller skrives om.
-- Migrasjonen kjører hver åpen plan gjennom overgangene én gang og kontrollerer
-- invarianten før den committer.
--
-- Funksjonskroppene til `api.resume_chain_transitions(...)` og
-- `api.record_monograph_track_by_editor(...)` er hentet fra databasen med
-- `pg_get_functiondef` og splisset, som i 014f og 014g: den eneste endringen i
-- den første er søkeplanleddet, og i den andre overgangen før hvert svar.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Kildeleddene, og hvor et av dem svikter
-- ----------------------------------------------------------------------------

create function workflow.monograph_search_roles()
  returns setof provenance.agent_role
  language sql
  stable
  set search_path = ''
as $$
  select r.role
  from unnest(enum_range(null::provenance.agent_role)) as r(role)
  where workflow.monograph_round_manifest_key(r.role) is not null
  order by r.role;
$$;

comment on function workflow.monograph_search_roles() is
  'De to kildeleddene: rollene hvis oppgaver hører til en maskinell søkerunde (workflow.monograph_round_manifest_key). Det ene stedet listen står, slik at overgangene, feiingen, invarianten og identitetskontrollen ikke kan bli uenige om hvilke ledd de gjelder (migrasjon 014h).';

revoke execute on function workflow.monograph_search_roles() from public;

create function workflow.monograph_search_chain_step(p_role provenance.agent_role)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case p_role
    when 'source_discovery'::provenance.agent_role then 'kildeoppdagelse'
    when 'source_quality_assessment'::provenance.agent_role then 'dekningskontroll'
  end;
$$;

comment on function workflow.monograph_search_chain_step(provenance.agent_role) is
  'Kjedeleddet et kildeledds overgang føres under: markøren i workflow.chain_reconciliation_cursors og signaturen til et teknisk problem (workflow.chain_step_signature). kildeoppdagelse er det samme leddet api.resume_chain_transitions(text, text) har ført siden 013v; dekningskontroll er nytt i migrasjon 014h. NULL for alle andre roller.';

revoke execute on function workflow.monograph_search_chain_step(provenance.agent_role) from public;

-- Ett kildeledds overgang for én plan: den første runden og kildeoppdagelsens
-- oppgave, eller dekningskontrollens motsøk og kontrolloppgave.
create function workflow.chain_task_for_search_role(
  p_plan_id uuid,
  p_role provenance.agent_role
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
begin
  case p_role
    when 'source_discovery'::provenance.agent_role then
      return workflow.chain_task_for_search_plan(p_plan_id);
    when 'source_quality_assessment'::provenance.agent_role then
      return workflow.chain_task_for_search_coverage(p_plan_id);
    else
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Rollen %s er ikke et kildeledd.', p_role);
  end case;
end;
$$;

comment on function workflow.chain_task_for_search_role(uuid, provenance.agent_role) is
  'Kjører ett kildeledds kjedeovergang for én søkeplan: workflow.chain_task_for_search_plan(uuid) for kildeoppdagelsen, workflow.chain_task_for_search_coverage(uuid) for dekningskontrollen. Svarer med jobbens id, eller NULL (migrasjon 014h).';

revoke execute on function workflow.chain_task_for_search_role(uuid, provenance.agent_role) from public;

-- ----------------------------------------------------------------------------
-- 2. Begge ledd for én plan, der en redaktør har endret den
--
-- Registreringen foran overgangen er det redaktøren gjorde, og den skal stå
-- selv om overgangen svikter. Svikten føres som et teknisk problem på leddet,
-- og feiingen tar planen igjen — nøyaktig som triggerne i 012b.
-- ----------------------------------------------------------------------------

create function workflow.chain_search_plan_tasks(p_plan_id uuid)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_role provenance.agent_role;
  v_state text;
  v_enqueued integer := 0;
begin
  for v_role in select workflow.monograph_search_roles() loop
    begin
      if workflow.chain_task_for_search_role(p_plan_id, v_role) is not null then
        v_enqueued := v_enqueued + 1;
      end if;
    exception
      -- Grunnlaget er ikke klart. Kjeden står, og det er porten som gjør jobben
      -- sin — ikke en teknisk svikt (de samme tre klassene som i 012b).
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure(
          workflow.monograph_search_chain_step(v_role), p_plan_id, v_state);
    end;
  end loop;

  return v_enqueued;
end;
$$;

comment on function workflow.chain_search_plan_tasks(uuid) is
  'Kjører begge kildeleddenes kjedeovergang for én søkeplan, hver for seg: det en endring av planen gjør mulig — en ny oppgave for et grunnlag som har vokst, den første runden, eller dekningskontrollens motsøk — legges inn i den samme transaksjonen. En overgang som svikter, føres som et teknisk problem på leddet og tas igjen av feiingen, uten at endringen foran rulles tilbake. Svarer med hvor mange vurderingsoppgaver som ble lagt inn (migrasjon 014h).';

revoke execute on function workflow.chain_search_plan_tasks(uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. Feiingen, for ett ledd
--
-- Søkeplanleddet fra api.resume_chain_transitions(...), delt i ett per
-- kildeledd, slik at hvert ledd kan ta igjen sitt eget med sin egen identitet.
-- Den samme markøren og den samme kostnadsgrensen som de andre leddene.
-- ----------------------------------------------------------------------------

create function workflow.resume_search_round_tasks(p_role provenance.agent_role)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_limit constant integer := workflow.chain_reconciliation_limit();
  v_step constant text := workflow.monograph_search_chain_step(p_role);
  v_position text;
  v_row record;
  v_state text;
  v_seen integer := 0;
  v_failed boolean := false;
  v_enqueued integer := 0;
begin
  if v_step is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Rollen %s er ikke et kildeledd.', p_role);
  end if;

  v_position := workflow.chain_cursor_position(v_step);

  for v_row in
    select p.id, p.id::text as sort_key
    from workflow.monograph_search_plans p
    join knowledge.monograph_editions e on e.id = p.edition_id
    where p.closed_at is null
      and p.paused_at is null
      and e.superseded_at is null
      and p.id::text > v_position
    order by p.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_task_for_search_role(v_row.id, p_role) is not null then
        v_enqueued := v_enqueued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure(v_step, v_row.id, v_state);
        v_failed := true;
    end;
  end loop;

  if workflow.chain_cursor_step(v_step, v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step(v_step);
  end if;

  return v_enqueued;
end;
$$;

comment on function workflow.resume_search_round_tasks(provenance.agent_role) is
  'Tar igjen ett kildeledds kjedeovergang for de åpne søkeplanene: den første runden, dekningskontrollens motsøk og én vurderingsoppgave for hver ferdig søkt runde som ikke har sin — også når en eldre oppgave er trukket tilbake eller leien på den har løpt ut. De samme funksjonene og portene som overgangen selv, og idempotent: en plan som har det den skal, koster et oppslag. Fra sin egen markør og med den samme kostnadsgrensen som leddene i api.resume_chain_transitions(text, text), som kaller den for begge kildeleddene. Svarer med hvor mange vurderingsoppgaver som ble lagt inn (migrasjon 014h).';

revoke execute on function workflow.resume_search_round_tasks(provenance.agent_role) from public;

-- Og svikten, i ord som gjelder den kjøringen som faktisk tar den igjen.
create or replace function workflow.chain_note_failure(p_step text, p_subject uuid, p_sqlstate text)
  returns void
  language plpgsql
  set search_path = ''
as $$
begin
  perform workflow.record_technical_incident(
    'automatic_task'::workflow.technical_area,
    workflow.chain_step_signature(p_step),
    format(
      'Den automatiske overgangen %s stoppet for %s med SQLSTATE %s. Arbeidet står, og '
      'rekonsilieringen tar det opp igjen ved neste passering: api.resume_chain_transitions(text, text) '
      'for kontrolleddene, og for søkeplanene også kildeleddenes egen maskinelle kjøring '
      '(api.resume_search_round_tasks(text, text)). Selve registreringen foran overgangen er uberørt.',
      p_step, p_subject, p_sqlstate));
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. Søkekjøringens egen vei inn
--
-- Den samme identiteten og den samme kontrollen som api.monograph_discovery_work:
-- bare kildeleddene, og hvert bare for sitt eget ledd. Tar ikke imot ett felt
-- fra kalleren; den legger inn nøyaktig det databasens egen tilstand tilsier.
-- ----------------------------------------------------------------------------

create function api.resume_search_round_tasks(p_identity_key text, p_secret text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity provenance.agent_identities;
begin
  select i.* into v_identity
  from provenance.agent_identities i
  where i.identity_key = p_identity_key;

  if not found or v_identity.agent_role not in (select workflow.monograph_search_roles()) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Søkeplanenes overganger tas igjen av kildeleddene selv.',
      hint = 'Kildeoppdagelsen og den separate dekningskontrollen har hver sin identitet, og hver tar igjen sitt eget ledd. Veien legger aldri inn noe annet enn det databasens egen tilstand allerede tilsier.';
  end if;

  perform provenance.authenticate_agent_identity(
    p_identity_key, p_secret, v_identity.agent_role);

  return jsonb_build_object(
    'agent_role', v_identity.agent_role,
    'tasks_enqueued', workflow.resume_search_round_tasks(v_identity.agent_role));
end;
$$;

comment on function api.resume_search_round_tasks(text, text) is
  'Kildeleddets egen rekonsiliering, kalt av den maskinelle søkekjøringen før den henter arbeidet sitt: åpner det leddets runder og vurderingsoppgaver som databasens tilstand tilsier, men som ingen hendelse la inn — en oppgave som ble erstattet mens en kjøring holdt den, en overgang som sviktet, en plan som kom ut av pause. Gjør det samme som søkeplanleddet i api.resume_chain_transitions(text, text), og avhenger ikke av at kontrolleddene kjører. Krever en identitet i et av de to kildeleddene, og gjelder bare det leddet. Svarer med rollen og hvor mange vurderingsoppgaver som ble lagt inn. SECURITY DEFINER og EXECUTE til anon og authenticated av samme grunn som de øvrige agentveiene (migrasjon 014h).';

revoke execute on function api.resume_search_round_tasks(text, text) from public;
grant execute on function api.resume_search_round_tasks(text, text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 5. Kontrolleddenes rekonsiliering bruker den samme feiingen
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.resume_chain_transitions(p_identity_key text, p_secret text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  -- Grensen er en kostnadsgrense, og den avgjør i tillegg om passeringen nådde
  -- *enden* av leddet: færre rader enn grensen betyr at feiingen er rundt.
  -- Markøren (workflow.chain_reconciliation_cursors) gjør at neste passering
  -- fortsetter der denne slapp, slik at en grense ikke blir til sult.
  v_limit constant integer := workflow.chain_reconciliation_limit();
  v_identity provenance.agent_identities;
  v_row record;
  v_state text;
  v_queued integer := 0;
  v_candidates integer := 0;
  v_reviews integer := 0;
  v_acquisitions integer := 0;
  v_plans integer := 0;
  v_answers integer := 0;
  v_seen integer;
  v_failed boolean;
  v_position text;
begin
  select i.* into v_identity
  from provenance.agent_identities i
  where i.identity_key = p_identity_key;

  if not found or v_identity.agent_role not in
       ('extraction_verification'::provenance.agent_role,
        'citation_support_verification'::provenance.agent_role) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kjedeoverganger tas opp igjen av de deterministiske kontrolleddene.',
      hint = 'Veien legger aldri inn noe annet enn det databasens egen tilstand allerede tilsier, og tar ikke imot ett eneste felt fra kalleren.';
  end if;

  perform provenance.authenticate_agent_identity(
    p_identity_key, p_secret, v_identity.agent_role);

  -- --------------------------------------------------------------------
  -- Ekstraksjonskontroller som mangler.
  --
  -- Hvert ledd telles og rekonsilieres for seg. `v_failed` er det som avgjør
  -- om leddets tekniske problem kan lukkes, og `v_seen < v_limit` er det som
  -- avgjør om denne passeringen i det hele tatt så hele leddet: en passering
  -- som stoppet på grensen, kan ikke vite om raden bak den fortsatt svikter.
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('ekstraksjonskontroll');
  for v_row in
    select e.id, e.id::text as sort_key
    from knowledge.evidence_items e
    where not exists (
      select 1 from workflow.pipeline_jobs j
      where j.agent_role = 'extraction_verification'::provenance.agent_role
        and j.job_key = workflow.control_job_key('ekstraksjon', e.id))
      and e.id::text > v_position
    order by e.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_control_for_evidence_item(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('ekstraksjonskontroll', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'ekstraksjonskontroll', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('ekstraksjonskontroll');
  end if;

  -- Synteseoppgaver som mangler.
  --
  -- Utvalget er de *subjektene* som mangler en oppgave, og ikke enhver
  -- kontrollert rad: ett subjekt er én oppgave, og uten avgrensningen ville
  -- passeringen brukt grensen sin på rader den allerede hadde gjort ferdig.
  -- Portene speiler overgangens egne — den gjeldende kontrollen er den siste, og
  -- et par som alt har en påstand, er ikke automatikkens å skrive om — slik at
  -- en rad som med rette står, ikke blir liggende i utvalget for alltid.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('syntese');
  for v_row in
    with gjeldende as (
      select distinct on (ev.evidence_item_id)
             ev.evidence_item_id, ev.outcome
      from workflow.evidence_verifications ev
      order by ev.evidence_item_id, ev.registration_ordinal desc
    ),
    utestaaende as (
      select e.intervention_drug_id as drug_id,
             e.outcome_concept_id as topic_id,
             min(e.id::text) as sort_key
      from knowledge.evidence_items e
      join gjeldende g on g.evidence_item_id = e.id and g.outcome = 'verified'
      where not exists (
        select 1 from knowledge.claims c
        where c.topic_concept_id = e.outcome_concept_id
          and c.subject_drug_id = e.intervention_drug_id)
      group by e.intervention_drug_id, e.outcome_concept_id
    )
    select u.sort_key::uuid as id, u.sort_key
    from utestaaende u
    where not workflow.agent_task_subject_queued(
            'claim_synthesis'::provenance.agent_role,
            format('%s+%s', u.drug_id, u.topic_id))
      and u.sort_key > v_position
    order by u.sort_key
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_task_for_verified_extraction(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('syntese', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step('syntese', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('syntese');
  end if;

  -- Kildestøttekontroller som mangler.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('kildestottekontroll');
  for v_row in
    select r.id, r.id::text as sort_key
    from knowledge.claim_revisions r
    where not exists (
      select 1 from workflow.pipeline_jobs j
      where j.agent_role = 'citation_support_verification'::provenance.agent_role
        and j.job_key = workflow.control_job_key('kildestotte', r.id))
      and r.id::text > v_position
    order by r.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_control_for_claim_revision(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('kildestottekontroll', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'kildestottekontroll', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('kildestottekontroll');
  end if;

  -- Evidensvurderinger som mangler. Som over: de revisjonene som faktisk mangler
  -- oppgaven, lest med den gjeldende kontrollen og ikke med en hvilken som helst.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('evidensvurdering');
  for v_row in
    with gjeldende as (
      select distinct on (cv.claim_revision_id)
             cv.claim_revision_id, cv.outcome
      from workflow.claim_verifications cv
      order by cv.claim_revision_id, cv.registration_ordinal desc
    )
    select g.claim_revision_id as id, g.claim_revision_id::text as sort_key
    from gjeldende g
    where g.outcome = 'verified'
      and not workflow.agent_task_subject_queued(
            'evidence_assessment'::provenance.agent_role, g.claim_revision_id::text)
      and g.claim_revision_id::text > v_position
    order by g.claim_revision_id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_task_for_verified_claim(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('evidensvurdering', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'evidensvurdering', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('evidensvurdering');
  end if;

  -- Kandidater som mangler. Gaten avgjør, som i overgangen: en revisjon som
  -- ikke er ferdig, forseglet ikke, og det er ikke en feil — det er kjeden som
  -- ikke er kommet dit ennå. De tre klassene som betyr nettopp det, går derfor
  -- stille; alt annet er en teknisk svikt og skal telles som en, akkurat som i
  -- de fire leddene over. Et `when others` som svelget uten å registrere, ville
  -- gjort den ene svikten som *ikke* har en trigger bak seg, usynlig.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('kandidat');
  for v_row in
    select distinct a.claim_revision_id as id, a.claim_revision_id::text as sort_key
    from knowledge.evidence_assessments a
    where not exists (
      select 1 from knowledge.candidates c where c.claim_revision_id = a.claim_revision_id)
      and a.claim_revision_id::text > v_position
    order by a.claim_revision_id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_candidate_for_assessment(v_row.id) is not null then
        v_candidates := v_candidates + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('kandidat', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step('kandidat', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('kandidat');
  end if;

  -- ------------------------------------------------------------------
  -- Redaksjonelle revisjonsvurderinger som mangler.
  --
  -- Det sjette leddet, og det eneste som ikke ender i en jobb: her stopper
  -- kjeden med vilje, og det som skal stå igjen, er en synlig oppgave til et
  -- menneske (migrasjon 012d). Svikter den overgangen teknisk, ville den nye
  -- kunnskapen vært usynlig for alltid — derfor feies den igjen her, som de
  -- fem andre.
  --
  -- Utvalget er *parene* som har brukbar evidens ingen revisjon av påstanden
  -- hviler på, og ikke enhver kontrollert rad: ett par er én oppgave.
  -- Brukbarheten avgjøres inne i overgangen, med skriveveiens egen funksjon;
  -- her er utvalget den billigere formen — en gjeldende, bekreftet kontroll —
  -- slik at passeringen ikke bruker grensen sin på rader som uansett faller.
  -- ------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('paastandsrevisjon');
  for v_row in
    with gjeldende as (
      select distinct on (ev.evidence_item_id)
             ev.evidence_item_id, ev.outcome
      from workflow.evidence_verifications ev
      order by ev.evidence_item_id, ev.registration_ordinal desc
    ),
    par as (
      -- Par som har ny, kontrollert evidens ingen revisjon hviler på.
      select c.id as claim_id,
             c.subject_drug_id as drug_id,
             c.topic_concept_id as topic_id,
             c.monograph_need_id as need_id
      from knowledge.claims c
      join knowledge.evidence_items e
        on e.intervention_drug_id = c.subject_drug_id
       and e.outcome_concept_id = c.topic_concept_id
       -- Og innenfor påstandens egen avgrensning. En monografiavgrenset
       -- påstand utfordres ikke av et funn om et annet spørsmål.
       and (c.monograph_need_id is null
            or knowledge.monograph_need_for_evidence_item(e.id) = c.monograph_need_id)
      join gjeldende g on g.evidence_item_id = e.id and g.outcome = 'verified'
      where c.id = workflow.claim_awaiting_revision(
                     c.subject_drug_id, c.topic_concept_id, c.monograph_need_id)
        and not exists (
          select 1
          from knowledge.claim_evidence_links l
          join knowledge.claim_revisions r on r.id = l.claim_revision_id
          where r.claim_id = c.id and l.evidence_item_id = e.id)
      group by c.id, c.subject_drug_id, c.topic_concept_id, c.monograph_need_id
      union
      -- Og oppgavene som alt står åpne. Utvalget over finner dem gjennom en
      -- evidensrad, og en hard sletting tar den raden bort: da ville en oppgave
      -- ingen kan fullføre, ikke vært mulig å nå herfra i det hele tatt. Selve
      -- skrivingen holder tilstanden i takt (avsnitt 14); dette er nettet under.
      select c.id, c.subject_drug_id, c.topic_concept_id, c.monograph_need_id
      from workflow.claim_revision_reviews r
      join knowledge.claims c on c.id = r.claim_id
      where r.state = 'open'
    ),
    utestaaende as (
      -- Ett par og én avgrensning er én oppgave, også når begge kildene over
      -- peker på den.
      select distinct on (
               workflow.claim_synthesis_subject(
                 p.drug_id::text, p.topic_id::text, p.need_id::text))
             p.claim_id, p.drug_id, p.topic_id, p.need_id,
             workflow.claim_synthesis_subject(
               p.drug_id::text, p.topic_id::text, p.need_id::text) as sort_key
      from par p
      order by workflow.claim_synthesis_subject(
                 p.drug_id::text, p.topic_id::text, p.need_id::text),
               p.claim_id
    )
    select u.claim_id as id, u.drug_id, u.topic_id, u.need_id, u.sort_key
    from utestaaende u
    where u.sort_key > v_position
    order by u.sort_key
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.notice_claim_revision_need(
           v_row.drug_id, v_row.topic_id, v_row.need_id) is not null then
        v_reviews := v_reviews + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('paastandsrevisjon', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'paastandsrevisjon', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('paastandsrevisjon');
  end if;

  -- --------------------------------------------------------------------
  -- Søkeplaner uten sin vurderingsoppgave, og utførte søk uten et motsøk.
  --
  -- Per kildeledd, gjennom den samme feiingen kildeleddenes egen maskinelle
  -- kjøring gjør (migrasjon 014h). Markøren og det tekniske problemet er
  -- leddets egne, så de to kjøringene fører ett og det samme.
  -- --------------------------------------------------------------------
  v_plans := v_plans
    + workflow.resume_search_round_tasks('source_discovery'::provenance.agent_role)
    + workflow.resume_search_round_tasks('source_quality_assessment'::provenance.agent_role);

  -- --------------------------------------------------------------------
  -- Valgte kilder som ikke er hentet inn.
  --
  -- Utestående betyr: kilderaden er ikke løst, eller et behov kilden er valgt
  -- for, har verken en godkjent kildebruk eller en åpen forespørsel. Et behov
  -- som står på en avklaring, er ikke utestående her — det venter på et
  -- menneske, og det står synlig på behovet (ANTIDEP_CONSTITUTION.md regel 4).
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('innhenting');
  for v_row in
    select c.id, c.id::text as sort_key
    from workflow.monograph_candidate_sources c
    where c.decision in ('selected_for_retrieval'::workflow.monograph_candidate_decision,
                         'included'::workflow.monograph_candidate_decision)
      and workflow.monograph_candidate_identifier_system(c.identifier_kind) is not null
      and (
        c.source_id is null
        or exists (
          select 1
          from workflow.monograph_wanted_candidate_needs cn
          join knowledge.monograph_needs n on n.id = cn.need_id
          where cn.candidate_source_id = c.id
            and n.relevance <> 'not_applicable'::knowledge.monograph_relevance
            and n.work_state <> 'awaiting_clarification'::knowledge.monograph_work_state
            and knowledge.monograph_need_material_kind(cn.need_id)
                  <> 'derived'::knowledge.monograph_material_kind
            and not exists (
              select 1
              from knowledge.monograph_source_uses u
              join knowledge.source_versions sv on sv.id = u.source_version_id
              where u.need_id = cn.need_id and sv.source_id = c.source_id)
            and not exists (
              select 1 from workflow.full_text_requests r
              where r.source_id = c.source_id and r.state = 'open')
            and not exists (
              select 1 from workflow.monograph_document_requests r
              where r.source_id = c.source_id and r.state = 'open')))
      and c.id::text > v_position
    order by c.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.acquire_monograph_candidate(v_row.id) is not null then
        v_acquisitions := v_acquisitions + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('innhenting', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'innhenting', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('innhenting');
  end if;

  -- --------------------------------------------------------------------
  -- Monografisvar som mangler.
  --
  -- To slag: et forskningsbehov der påstanden er vurdert uten at svaret er
  -- bundet til den vurderte revisjonen, og et myndighetsbehov der materialet
  -- er godkjent uten at svaroppgaven står i køen.
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('monografisvar');
  for v_row in
    with utestaaende as (
      select c.monograph_need_id as need_id,
             r.id as claim_revision_id
      from knowledge.evidence_assessments a
      join knowledge.claim_revisions r on r.id = a.claim_revision_id
      join knowledge.claims c on c.id = r.claim_id
      where c.monograph_need_id is not null
        and not exists (
          select 1
          from knowledge.monograph_answers ma
          join knowledge.monograph_answer_revisions mr on mr.id = ma.current_revision_id
          where ma.need_id = c.monograph_need_id
            and mr.claim_revision_id = r.id)
      union all
      select u.need_id, null::uuid
      from knowledge.monograph_source_uses u
      join knowledge.monograph_needs n on n.id = u.need_id
      where n.relevance <> 'not_applicable'::knowledge.monograph_relevance
        and knowledge.monograph_need_material_kind(u.need_id)
              = 'authority_document'::knowledge.monograph_material_kind
        and not exists (
          select 1
          from knowledge.monograph_answers ma
          join knowledge.monograph_answer_revisions mr on mr.id = ma.current_revision_id
          where ma.need_id = u.need_id
            and mr.source_version_id = u.source_version_id)
        and not exists (
          select 1 from workflow.pipeline_jobs j
          where j.agent_role = 'monograph_answer'::provenance.agent_role
            and j.job_key like 'agent-handoff:' || u.need_id::text || ':%')
    )
    select distinct on (u.need_id::text || coalesce(u.claim_revision_id::text, ''))
           u.need_id as id, u.claim_revision_id,
           u.need_id::text || coalesce(u.claim_revision_id::text, '') as sort_key
    from utestaaende u
    where u.need_id::text || coalesce(u.claim_revision_id::text, '') > v_position
    order by u.need_id::text || coalesce(u.claim_revision_id::text, '')
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if v_row.claim_revision_id is not null then
        if workflow.chain_answer_for_assessment(v_row.claim_revision_id) is not null then
          v_answers := v_answers + 1;
        end if;
      else
        if workflow.chain_task_for_monograph_answer(v_row.id) is not null then
          v_answers := v_answers + 1;
        end if;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('monografisvar', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'monografisvar', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('monografisvar');
  end if;

  return jsonb_build_object('queued', v_queued, 'candidates_built', v_candidates,
                            'revision_reviews', v_reviews,
                            'search_tasks', v_plans,
                            'acquisitions', v_acquisitions,
                            'monograph_answers', v_answers);
end;
$function$;

comment on function api.resume_chain_transitions(text, text) is
  'Tar igjen de automatiske kjedeovergangene en teknisk svikt etterlot, og rekonsilierer samtidig det tekniske bildet. Leser hva databasens egen tilstand tilsier og legger inn nøyaktig det triggerne ville lagt inn — de samme funksjonene, de samme portene, den samme idempotensen — og tar ikke imot ett eneste felt fra kalleren. Den erstatter ingen tilstandsovergang: overgangen har allerede skjedd, og dette er lesningen av hva som mangler i forhold til den. Hvert ledd rekonsilieres for seg og fra sin egen markør, slik at en kostnadsgrense per passering ikke blir til sult; ett av dem gjør synlig at ny evidens venter på en redaksjonell avgjørelse om en påstand som allerede finnes — der er det ikke en jobb som kan gå tapt, men vissheten om at kunnskapen finnes. Søkeplanene tas igjen per kildeledd av workflow.resume_search_round_tasks(provenance.agent_role), den samme feiingen kildeleddenes egen kjøring gjør (migrasjon 014h). Leddets tekniske problem lukkes bare når en hel feiing — ikke en enkelt passering — kom gjennom leddet uten en eneste teknisk svikt. Krever en identitet i et av de to deterministiske kontrolleddene. Svarer med hvor mange jobber som ble lagt inn, hvor mange kandidater som ble forseglet, og hvor mange redaksjonelle oppgaver som ble åpnet. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny; EXECUTE går til anon og authenticated av samme grunn som for de øvrige agentveiene.';

-- ----------------------------------------------------------------------------
-- 6. Redaktørens to handlinger på en søkeplan kjører overgangen selv
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.record_monograph_track_by_editor(p_plan_reference text, p_track_code text, p_outcome text, p_note text, p_platform text DEFAULT NULL::text, p_query_string text DEFAULT NULL::text, p_filters text DEFAULT NULL::text, p_executed_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_result_count integer DEFAULT NULL::integer, p_screened_count integer DEFAULT NULL::integer, p_truncated boolean DEFAULT false, p_truncation_note text DEFAULT NULL::text, p_candidates jsonb DEFAULT NULL::jsonb, p_screening_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_actor_id uuid;
  v_plan workflow.monograph_search_plans;
  v_edition knowledge.monograph_editions;
  v_track_id uuid;
  v_attempt workflow.monograph_search_track_attempts;
  v_search_id uuid;
  v_outcome workflow.monograph_search_outcome;
  v_candidate jsonb;
  v_unknown text;
  v_recorded integer := 0;
  v_candidate_count integer := 0;
  v_enqueued integer;
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

    v_enqueued := workflow.chain_search_plan_tasks(v_plan.id);

    return jsonb_build_object(
      'plan_reference', v_plan.reference,
      'track_code', p_track_code,
      'state', 'unavailable',
      'search_recorded', false,
      'tasks_enqueued', v_enqueued,
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

  if p_candidates is not null then
    if jsonb_typeof(p_candidates) <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Kandidatlisten er ikke en JSON-liste.';
    end if;
    v_candidate_count := jsonb_array_length(p_candidates);
  end if;

  -- En passering som ga treff, må enten gi kandidatkildene den fant, eller si
  -- hva gjennomgangen ga. For et maskinelt søk leser den semantiske agenten de
  -- registrerte treffene selv; her er redaktøren den eneste som har sett dem,
  -- og «fire treff, fire gjennomgått, null kandidater» uten en setning om
  -- hvorfor, er treff som forsvinner stille (SOURCE_POLICY.md §4.3).
  if p_result_count > 0 and v_candidate_count = 0
     and (p_screening_note is null or length(btrim(p_screening_note)) < 20) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En passering med treff må enten gi kandidatkildene den fant, eller si hva gjennomgangen ga.',
      hint = 'Oppgi p_candidates med kildene som er verdt å vurdere, eller p_screening_note med minst 20 tegn om hvorfor ingen av treffene ble kandidater. Et tomt felt er ikke det samme som «ingen relevante treff».';
  end if;

  -- Et kontrollert nullsøk er `zero_results`, og det kan ikke være avkortet.
  v_outcome := case when p_result_count = 0
                    then 'zero_results'::workflow.monograph_search_outcome
                    else 'executed'::workflow.monograph_search_outcome end;

  insert into workflow.monograph_searches (
    plan_id, plan_version, platform, query_string, filters, executed_at,
    result_count, screened_count, truncated, truncation_note,
    outcome, execution_evidence, track_codes, recorded_by_actor_id,
    screening_note
  )
  values (
    v_plan.id, v_plan.plan_version, btrim(p_platform), btrim(p_query_string),
    nullif(btrim(coalesce(p_filters, '')), ''), p_executed_at,
    p_result_count, coalesce(p_screened_count, p_result_count),
    coalesce(p_truncated, false),
    nullif(btrim(coalesce(p_truncation_note, '')), ''),
    v_outcome, 'editor_recorded'::workflow.monograph_execution_evidence,
    array[p_track_code], v_actor_id,
    nullif(btrim(coalesce(p_screening_note, '')), '')
  )
  returning id into v_search_id;

  -- Kandidatene passeringen ga, bundet til nøyaktig denne raden. Samme
  -- kontrakt som det maskinelle søket bruker: ukjente felter avvises framfor å
  -- ignoreres.
  if v_candidate_count > 0 then
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

      if workflow.record_monograph_candidate_source(
           v_plan.id, v_search_id,
           v_candidate ->> 'identifier_kind',
           v_candidate ->> 'identifier_value',
           v_candidate ->> 'title',
           v_candidate ->> 'authors_or_issuer',
           v_candidate ->> 'publisher_or_journal',
           (v_candidate ->> 'publication_year')::integer,
           coalesce(v_candidate ->> 'discovery_path',
                    format('Manuelt søk i %s, utført og registrert av en redaktør', btrim(p_platform))),
           coalesce((v_candidate ->> 'access_limited')::boolean, false),
           v_candidate ->> 'access_limitation_note',
           coalesce((v_candidate ->> 'could_change_conclusion')::boolean, false),
           v_candidate ->> 'materiality_reason',
           null, v_actor_id) is not null then
        v_recorded := v_recorded + 1;
      end if;
    end loop;
  end if;

  update workflow.monograph_search_track_attempts
  set state = 'covered', search_id = v_search_id, note = btrim(p_note),
      resolved_by_actor_id = v_actor_id
  where id = v_attempt.id;

  -- Overgangen, i den samme transaksjonen som lukkingen av en søkerunde
  -- (migrasjon 014h). Et registrert søk gjør kildeoppdagelsens grunnlag
  -- større, og oppgaven for det gamle grunnlaget slutter å gjelde: den nye
  -- legges inn nå, og ikke når noe annet tilfeldigvis kjører overgangen.
  v_enqueued := workflow.chain_search_plan_tasks(v_plan.id);

  return jsonb_build_object(
    'plan_reference', v_plan.reference,
    'track_code', p_track_code,
    'state', 'covered',
    'search_recorded', true,
    'candidates_recorded', v_recorded,
    'tasks_enqueued', v_enqueued,
    'closure_problem', workflow.monograph_search_closure_problem(v_plan.id));
end;
$function$;

comment on function api.record_monograph_track_by_editor(text, text, text, text, text, text, text, timestamptz, integer, integer, boolean, text, jsonb, text) is
  'Lar en redaktør registrere utfallet av et obligatorisk søkespor ingen av Antideps registrerte søkeveier dekker. Gjelder bare spor som står som no_machine_path: et spor maskinen kan søke i, skal maskinen søke i. Utfallet unavailable krever en begrunnelse. Utfallet covered fører selve passeringen inn i søkeloggen som en egen rad med editor_recorded som utførelsesbevis — plattform, eksakt søkestreng, filtre, tidspunkt, treffantall og eventuell avkorting (SOURCE_POLICY.md §4.3) — og knytter sporet til nøyaktig den raden. Ga passeringen treff, må den enten gi kandidatkildene den fant, eller si hva gjennomgangen ga: for et maskinelt søk leser den semantiske agenten de registrerte treffene selv, mens en manuell passering er det bare redaktøren som har sett, og treffene ville ellers forsvunnet stille (014a). Fra migrasjon 014h kjører den begge kildeleddenes overgang før den svarer: et registrert søk gjør kildeoppdagelsens grunnlag større, og den nye vurderingsoppgaven legges inn med det samme (tasks_enqueued). Krever editor-mandat, og aktøren føres på søket, sporet og hver kandidat.';

create or replace function api.resume_monograph_search_plan(p_plan_reference text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
begin
  perform knowledge.assert_editor_authorized();

  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.reference = p_plan_reference
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen finnes ikke.';
  end if;

  update workflow.monograph_search_plans
  set paused_at = null, paused_reason = null
  where id = v_plan.id;

  -- Overgangen gjør ingenting for en plan på pause. Det som ble mulig mens den
  -- sto — en runde som ble ferdig søkt, eller et motsøk som kan åpnes — legges
  -- inn nå, og ikke først når noe annet tilfeldigvis kjører den (014h).
  return jsonb_build_object(
    'reference', v_plan.reference,
    'resumed', true,
    'tasks_enqueued', workflow.chain_search_plan_tasks(v_plan.id));
end;
$$;

comment on function api.resume_monograph_search_plan(text) is
  'Tar én søkeplan ut av pause. Arbeidet fortsetter der det sto: søkeloggen, sporene og kandidatkildene er uendret, og ingenting må gjøres om igjen (SOURCE_POLICY.md §8.2). Fra migrasjon 014h kjøres begge kildeleddenes overgang med det samme, slik at en runde som ble ferdig søkt under pausen, får sin vurderingsoppgave nå (tasks_enqueued).';

-- ----------------------------------------------------------------------------
-- 7. Invarianten, som en funksjon
--
-- Den samme kontrollen 014g gjorde etter reparasjonen, slik at migrasjonen og
-- prøvene leser nøyaktig den samme.
-- ----------------------------------------------------------------------------

create function workflow.monograph_search_task_invariant_problem()
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_missing integer;
  v_duplicates integer;
begin
  -- En åpen plan med en utført runde og et spørsmål å vurdere skal ha en
  -- oppgave for nøyaktig det grunnlaget — i hvilken som helst tilstand — eller
  -- en kjøring som holder den forrige akkurat nå.
  select count(*) into v_missing
  from workflow.monograph_search_plans p
  join knowledge.monograph_editions e on e.id = p.edition_id
  cross join workflow.monograph_search_roles() as r(role)
  where p.closed_at is null
    and p.paused_at is null
    and e.superseded_at is null
    and exists (select 1 from workflow.monograph_search_plan_needs pn where pn.plan_id = p.id)
    and workflow.monograph_search_phase_problem(p.id, r.role) is null
    and (r.role = 'source_discovery'::provenance.agent_role or not exists (
      select 1 from workflow.monograph_coverage_controls cc
      where cc.plan_id = p.id and cc.plan_version = p.plan_version))
    and not exists (
      select 1
      from workflow.pipeline_jobs j
      join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
      where j.agent_role = r.role
        and j.input_manifest ->> 'search_plan_id' = p.id::text
        and not workflow.pipeline_job_withdrawn(j.id)
        and (workflow.monograph_search_task_supersession(j) is null
             or (j.state = 'leased' and j.lease_expires_at > statement_timestamp())));

  if v_missing > 0 then
    return format('%s ferdig søkt(e) runde(r) på en åpen søkeplan står uten en vurderingsoppgave.', v_missing);
  end if;

  -- Aldri to aktive oppgaver om den samme runden.
  select count(*) into v_duplicates
  from (
    select j.agent_role, j.input_manifest ->> 'search_plan_id',
           j.input_manifest ->> workflow.monograph_round_manifest_key(j.agent_role)
    from workflow.pipeline_jobs j
    join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
    where j.agent_role in (select workflow.monograph_search_roles())
      and j.state in ('ready', 'leased')
      and not workflow.pipeline_job_withdrawn(j.id)
    group by 1, 2, 3
    having count(*) > 1
  ) d;

  if v_duplicates > 0 then
    return format('%s søkerunde(r) har mer enn én aktiv vurderingsoppgave.', v_duplicates);
  end if;

  return null;
end;
$$;

comment on function workflow.monograph_search_task_invariant_problem() is
  'Én setning om hva som bryter kildeleddenes invariant, eller NULL: hver åpen søkeplan med en ferdig søkt runde og et spørsmål å vurdere har én vurderingsoppgave for rundens grunnlag — i hvilken som helst tilstand — eller en kjøring som holder den forrige akkurat nå, og ingen runde har to aktive oppgaver. Den samme kontrollen migrasjon 014g gjorde etter reparasjonen, som en funksjon slik at migrasjonene og prøvene leser den samme (migrasjon 014h).';

revoke execute on function workflow.monograph_search_task_invariant_problem() from public;

-- ----------------------------------------------------------------------------
-- 8. Hver åpen plan gjennom overgangene én gang, og invarianten
--
-- Det feiingen ellers ville tatt igjen ved søkekjøringens neste passering, gjøres
-- her, slik at utrullingen ikke venter på den. Svikter invarianten, ruller hele
-- migrasjonen tilbake.
-- ----------------------------------------------------------------------------

do $$
declare
  v_plan record;
  v_enqueued integer := 0;
  v_problem text;
begin
  for v_plan in
    select p.id
    from workflow.monograph_search_plans p
    join knowledge.monograph_editions e on e.id = p.edition_id
    where p.closed_at is null
      and p.paused_at is null
      and e.superseded_at is null
    order by p.created_at, p.id
  loop
    v_enqueued := v_enqueued + workflow.chain_search_plan_tasks(v_plan.id);
  end loop;

  raise notice 'Migrasjon 014h: % vurderingsoppgaver lagt inn.', v_enqueued;

  v_problem := workflow.monograph_search_task_invariant_problem();
  if v_problem is not null then
    raise exception using
      errcode = 'check_violation',
      message = 'Migrasjon 014h: ' || v_problem,
      hint = 'Hver åpen plan med en utført maskinell runde skal ha én oppgave for rundens grunnlag. En runde uten den ville vært søk ingen noen gang vurderte.';
  end if;
end;
$$;
