-- ============================================================================
-- Migrasjon 013k — den redaksjonelle kontrollen
--
-- En kliniker med mandat skal kunne rette en tekst, låse en rettelse mot
-- automatisk overskriving, begrense et område til forhåndsgodkjente kilder, og
-- legge til eller forkaste en kilde — uten kode, uten SQL og uten en
-- utviklingsagent.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en lås ikke skjermer innholdet mot kritikk
--
-- Fordi det ville vært den farligste varianten av en lås. Et låst svar skal
-- ikke overskrives av automatikken — men ny evidens som utfordrer det, skal
-- være synlig som et avvik. Låsen gjør derfor to ting samtidig: den stopper
-- den automatiske skrivingen, og den gjør det som ville blitt skrevet, om til
-- et forslag noen må ta stilling til.
--
-- ----------------------------------------------------------------------------
-- Hvorfor kildebegrensningen håndheves i databasen
--
-- Fordi en begrensning som bare fantes i flaten, ville vært en anbefaling. Den
-- står her, i den samme funksjonen som kontrollerer et ordrett utdrag, slik at
-- en agent ikke kan komme utenom den. Og en relevant kilde utenfor listen blir
-- et synlig forslag: den brukes ikke i det stille, og den erklæres ikke
-- irrelevant (SOURCE_POLICY.md §2, ANTIDEP_CONSTITUTION.md regel 4).
--
-- ----------------------------------------------------------------------------
-- Hvorfor en forkastet kilde ikke slettes
--
-- Fordi godkjenningen er dokumentasjon. En forkasting er en ny opplysning om
-- den godkjenningen — hvem som forkastet den og hvorfor — og den legges til
-- framfor å viske ut det som sto der.
--
-- Styrende dokumenter: docs/CONTENT_GOVERNANCE.md, docs/SOURCE_POLICY.md §2,
-- docs/MONOGRAPH_STANDARD.md §2, docs/ANTIDEP_CONSTITUTION.md regel 2, 4, 6.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Låsen
-- ----------------------------------------------------------------------------

alter table knowledge.monograph_answers
  add column locked_at timestamptz,
  add column locked_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  add column lock_reason text,
  add constraint monograph_answers_lock_shape_check
    check (num_nonnulls(locked_at, locked_by_actor_id, lock_reason) in (0, 3)),
  add constraint monograph_answers_lock_reason_shape_check
    check (lock_reason is null
           or (lock_reason = btrim(lock_reason) and length(lock_reason) between 1 and 2000));

comment on column knowledge.monograph_answers.locked_at is
  'Når svaret ble låst mot automatisk overskriving, eller NULL. En lås stopper den automatiske skrivingen og gjør det som ville blitt skrevet, om til et synlig forslag — den skjermer ikke innholdet mot kritikk. Et låst svar som ny evidens motsier, skal vises som et avvik, ikke som en enighet (ANTIDEP_CONSTITUTION.md regel 4).';

create function audit.record_monograph_answer_lock_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.locked_at is not distinct from old.locked_at
     and new.lock_reason is not distinct from old.lock_reason then
    return null;
  end if;

  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, reason, occurred_at
  )
  values (
    'monograph_answer_lock_changed'::audit.event_operation,
    new.id,
    coalesce(new.locked_by_actor_id, old.locked_by_actor_id, new.created_by_actor_id),
    to_jsonb(old), to_jsonb(new),
    coalesce(new.lock_reason, old.lock_reason, 'Låsen er opphevet.'),
    now()
  );
  return null;
end;
$$;

revoke execute on function audit.record_monograph_answer_lock_event() from public;

create trigger monograph_answers_record_lock_event
  after update on knowledge.monograph_answers
  for each row execute function audit.record_monograph_answer_lock_event();

-- ----------------------------------------------------------------------------
-- 2. Kildebegrensningen
--
-- Et område — én spørsmålsmal i én monografiutgave, eventuelt bare ett behov —
-- kan begrenses til kilder et menneske har forhåndsgodkjent.
-- ----------------------------------------------------------------------------

create table workflow.monograph_source_restrictions (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  edition_id uuid not null
    references knowledge.monograph_editions (id) on update restrict on delete restrict,
  -- Området. En mal dekker alle behovene den er gjentatt på; et behov dekker
  -- bare seg selv.
  template_id uuid
    references knowledge.monograph_question_templates (id)
    on update restrict on delete restrict,
  need_id uuid
    references knowledge.monograph_needs (id) on update restrict on delete restrict,

  reason text not null,
  registered_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  lifted_at timestamptz,
  lifted_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  lift_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint monograph_source_restrictions_reference_key unique (reference),
  constraint monograph_source_restrictions_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$'),
  constraint monograph_source_restrictions_area_check
    check (num_nonnulls(template_id, need_id) = 1),
  constraint monograph_source_restrictions_reason_shape_check
    check (reason = btrim(reason) and length(reason) between 1 and 2000),
  constraint monograph_source_restrictions_lift_shape_check
    check (num_nonnulls(lifted_at, lifted_by_actor_id, lift_reason) in (0, 3))
);

comment on table workflow.monograph_source_restrictions is
  'Et område i én monografiutgave som bare kan bruke kilder et menneske har forhåndsgodkjent. Området er enten én spørsmålsmal — som dekker alle behovene malen er gjentatt på — eller ett enkelt behov. Begrensningen håndheves i databasen og ikke i flaten: en begrensning som bare fantes i brukergrensesnittet, ville vært en anbefaling, og en agent kunne gått utenom den.';

alter table workflow.monograph_source_restrictions enable row level security;

create unique index monograph_source_restrictions_template_key
  on workflow.monograph_source_restrictions (edition_id, template_id)
  where template_id is not null and lifted_at is null;
create unique index monograph_source_restrictions_need_key
  on workflow.monograph_source_restrictions (edition_id, need_id)
  where need_id is not null and lifted_at is null;

create trigger monograph_source_restrictions_set_row_timestamps
  before insert or update on workflow.monograph_source_restrictions
  for each row execute function catalog.set_row_timestamps();

create table workflow.monograph_restriction_sources (
  id uuid primary key default gen_random_uuid(),

  restriction_id uuid not null
    references workflow.monograph_source_restrictions (id)
    on update restrict on delete restrict,
  source_id uuid not null
    references knowledge.sources (id) on update restrict on delete restrict,
  reason text not null,
  approved_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint monograph_restriction_sources_pair_key unique (restriction_id, source_id),
  constraint monograph_restriction_sources_reason_shape_check
    check (reason = btrim(reason) and length(reason) between 1 and 2000)
);

comment on table workflow.monograph_restriction_sources is
  'Kildene et menneske har forhåndsgodkjent for et begrenset område. Godkjenningen står på kilden og ikke på kildeversjonen, fordi en ny versjon av den samme preparatomtalen er den samme forhåndsgodkjente kilden.';

alter table workflow.monograph_restriction_sources enable row level security;

create index monograph_restriction_sources_source_idx
  on workflow.monograph_restriction_sources (source_id);

create trigger monograph_restriction_sources_set_created_at
  before insert or update on workflow.monograph_restriction_sources
  for each row execute function catalog.set_created_at();

create trigger monograph_restriction_sources_are_append_only
  before update or delete on workflow.monograph_restriction_sources
  for each row execute function knowledge.reject_append_only_mutation();

create function audit.record_monograph_source_restriction_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    return null;
  end if;

  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, reason, occurred_at
  )
  values (
    'monograph_source_restriction_registered'::audit.event_operation,
    new.id, new.registered_by_actor_id, null, to_jsonb(new), new.reason, new.created_at
  );
  return null;
end;
$$;

revoke execute on function audit.record_monograph_source_restriction_event() from public;

create trigger monograph_source_restrictions_record_audit_event
  after insert on workflow.monograph_source_restrictions
  for each row execute function audit.record_monograph_source_restriction_event();

-- Begrensningen som gjelder for ett behov, eller NULL.
create function workflow.monograph_restriction_for_need(p_need_id uuid)
  returns workflow.monograph_source_restrictions
  language sql
  stable
  set search_path = ''
as $$
  select r.*
  from workflow.monograph_source_restrictions r
  join knowledge.monograph_needs n on n.edition_id = r.edition_id
  where n.id = p_need_id
    and r.lifted_at is null
    and (r.need_id = n.id or r.template_id = n.template_id)
  -- Den mest presise først: en begrensning på behovet selv går foran malens.
  order by (r.need_id is not null) desc, r.created_at
  limit 1;
$$;

comment on function workflow.monograph_restriction_for_need(uuid) is
  'Den kildebegrensningen som gjelder for ett kunnskapsbehov, eller ingen rad. En begrensning på behovet selv går foran malens: den er den mest presise avgjørelsen, og den er tatt om nettopp dette spørsmålet.';

revoke execute on function workflow.monograph_restriction_for_need(uuid) from public;

create function workflow.monograph_source_is_permitted(
  p_need_id uuid,
  p_source_id uuid)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select case
    when (workflow.monograph_restriction_for_need(p_need_id)).id is null then true
    else exists (
      select 1
      from workflow.monograph_restriction_sources s
      where s.restriction_id = (workflow.monograph_restriction_for_need(p_need_id)).id
        and s.source_id = p_source_id)
  end;
$$;

comment on function workflow.monograph_source_is_permitted(uuid, uuid) is
  'Om én kilde kan brukes for ett kunnskapsbehov. Uten en begrensning på området er svaret alltid ja. Med en begrensning er svaret ja bare for de kildene et menneske har forhåndsgodkjent — og et nei betyr at kilden blir et synlig forslag, ikke at den er irrelevant.';

revoke execute on function workflow.monograph_source_is_permitted(uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. Avviket og revisjonsforslaget
--
-- Det automatikken *ville* skrevet, når den ikke får lov. Låst innhold og et
-- begrenset område er de to grunnene, og begge gir det samme: en synlig rad
-- noen må ta stilling til.
-- ----------------------------------------------------------------------------

create type workflow.monograph_proposal_kind as enum (
  'locked_answer_challenged',
  'restricted_source_offered'
);

revoke usage on type workflow.monograph_proposal_kind from public;

comment on type workflow.monograph_proposal_kind is
  'Hvorfor et revisjonsforslag finnes: locked_answer_challenged (et låst svar har fått et nytt kontrollert grunnlag som automatikken ikke fikk skrive) eller restricted_source_offered (en relevant kilde faller utenfor de forhåndsgodkjente kildene for området). Begge er synlige avvik og ikke stille utelatelser: den første skjermer ikke det låste innholdet mot kritikk, og den andre erklærer ikke kilden irrelevant.';

create type workflow.monograph_proposal_state as enum ('open', 'accepted', 'declined');

revoke usage on type workflow.monograph_proposal_state from public;

comment on type workflow.monograph_proposal_state is
  'Tilstanden til et revisjonsforslag: open (ingen har tatt stilling til det), accepted (godtatt av en redaktør med mandat) eller declined (avvist med en begrunnelse). En avvisning krever en begrunnelse, fordi det er begrunnelsen som gjør den til en faglig konklusjon framfor til en utsettelse.';

create table workflow.monograph_revision_proposals (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  need_id uuid not null
    references knowledge.monograph_needs (id) on update restrict on delete restrict,
  kind workflow.monograph_proposal_kind not null,

  -- Grunnlaget forslaget hviler på. Ett av de to, aldri begge.
  claim_revision_id uuid
    references knowledge.claim_revisions (id) on update restrict on delete restrict,
  source_version_id uuid
    references knowledge.source_versions (id) on update restrict on delete restrict,

  rationale text not null,
  proposed_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  proposed_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,

  state workflow.monograph_proposal_state not null default 'open',
  decided_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  decided_at timestamptz,
  decision_note text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint monograph_revision_proposals_reference_key unique (reference),
  constraint monograph_revision_proposals_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$'),
  constraint monograph_revision_proposals_basis_check
    check (num_nonnulls(claim_revision_id, source_version_id) = 1),
  constraint monograph_revision_proposals_kind_basis_check
    check (case kind
             when 'locked_answer_challenged' then true
             when 'restricted_source_offered' then source_version_id is not null
             else false
           end),
  constraint monograph_revision_proposals_rationale_shape_check
    check (rationale = btrim(rationale) and length(rationale) between 1 and 4000),
  constraint monograph_revision_proposals_decision_shape_check
    check (case state
             when 'open' then
               decided_at is null and decided_by_actor_id is null
               and decision_note is null
             when 'accepted' then
               decided_at is not null and decided_by_actor_id is not null
             when 'declined' then
               decided_at is not null and decided_by_actor_id is not null
               and decision_note is not null
             else false
           end)
);

comment on table workflow.monograph_revision_proposals is
  'Det automatikken ville skrevet, men ikke fikk: et nytt kontrollert grunnlag for et låst svar, eller en relevant kilde utenfor de forhåndsgodkjente kildene for området. Raden finnes for at ingen av de to skal bli en stille utelatelse — et låst svar skal ikke skjermes mot synlig kritikk, og en kilde utenfor en begrenset liste skal ikke erklæres irrelevant (ANTIDEP_CONSTITUTION.md regel 4). Avgjørelsen er redaksjonell og krever mandat.';

alter table workflow.monograph_revision_proposals enable row level security;

create index monograph_revision_proposals_need_idx
  on workflow.monograph_revision_proposals (need_id, state);

create unique index monograph_revision_proposals_open_basis_key
  on workflow.monograph_revision_proposals (
    need_id, kind, coalesce(claim_revision_id, source_version_id))
  where state = 'open';

comment on index workflow.monograph_revision_proposals_open_basis_key is
  'Det samme grunnlaget foreslått to ganger er ett forslag. Uten dette ville hver gjennomkjøring av kjeden lagt til en rad til om det samme, og den åpne listen ville blitt menneskearbeid Antidep selv fant på.';

create trigger monograph_revision_proposals_set_row_timestamps
  before insert or update on workflow.monograph_revision_proposals
  for each row execute function catalog.set_row_timestamps();

create function workflow.record_monograph_revision_proposal(
  p_need_id uuid,
  p_kind workflow.monograph_proposal_kind,
  p_claim_revision_id uuid,
  p_source_version_id uuid,
  p_rationale text,
  p_actor_id uuid,
  p_agent_run_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into workflow.monograph_revision_proposals (
    need_id, kind, claim_revision_id, source_version_id, rationale,
    proposed_by_actor_id, proposed_by_agent_run_id
  )
  values (
    p_need_id, p_kind, p_claim_revision_id, p_source_version_id, btrim(p_rationale),
    p_actor_id, p_agent_run_id
  )
  on conflict do nothing
  returning id into v_id;

  return v_id;
end;
$$;

comment on function workflow.record_monograph_revision_proposal(uuid, workflow.monograph_proposal_kind, uuid, uuid, text, uuid, uuid) is
  'Fører opp ett synlig avvik: et nytt grunnlag for et låst svar, eller en kilde utenfor en begrenset liste. Idempotent på grunnlaget, slik at en gjentatt gjennomkjøring av kjeden ikke lager menneskearbeid Antidep selv fant på.';

revoke execute on function workflow.record_monograph_revision_proposal(uuid, workflow.monograph_proposal_kind, uuid, uuid, text, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Forkastingen av en godkjent kilde
--
-- Godkjenningen er dokumentasjon. En forkasting legges til som en ny
-- opplysning om den, framfor å viske ut det som sto der.
-- ----------------------------------------------------------------------------

create table knowledge.monograph_source_use_revocations (
  id uuid primary key default gen_random_uuid(),

  source_use_id uuid not null
    references knowledge.monograph_source_uses (id) on update restrict on delete restrict,
  reason text not null,
  revoked_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint monograph_source_use_revocations_use_key unique (source_use_id),
  constraint monograph_source_use_revocations_reason_shape_check
    check (reason = btrim(reason) and length(reason) between 1 and 2000)
);

comment on table knowledge.monograph_source_use_revocations is
  'En forkastet kildebruk: hvem som forkastet den og hvorfor. Egen rad fordi godkjenningen er dokumentasjon og ikke en innstilling — en sletting ville visket ut at kilden en gang ble godkjent for dette spørsmålet, og et svar som hvilte på den, ville mistet sitt opphav.';

alter table knowledge.monograph_source_use_revocations enable row level security;

create trigger monograph_source_use_revocations_set_created_at
  before insert or update on knowledge.monograph_source_use_revocations
  for each row execute function catalog.set_created_at();

create trigger monograph_source_use_revocations_are_append_only
  before update or delete on knowledge.monograph_source_use_revocations
  for each row execute function knowledge.reject_append_only_mutation();

create function knowledge.monograph_source_use_is_active(p_source_use_id uuid)
  returns boolean
  language sql
  stable
  set search_path = ''
as $$
  select not exists (
    select 1 from knowledge.monograph_source_use_revocations r
    where r.source_use_id = p_source_use_id);
$$;

revoke execute on function knowledge.monograph_source_use_is_active(uuid) from public;

-- ----------------------------------------------------------------------------
-- 5. Håndhevingen, i de samme funksjonene som resten av kontrollen
--
-- Kildebegrensningen og forkastingen står i den funksjonen som alt kontrollerer
-- et ordrett utdrag, og låsen står i den ene skriveveien for et svar. Da finnes
-- det ingen vei utenom dem — heller ikke for en agent.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION workflow.monograph_answer_citation_problem(p_need_id uuid, p_source_version_id uuid, p_as_of date, p_source_quote text, p_source_locator text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_text text;
begin
  -- approved_use: kildeversjonen må være godkjent for nettopp dette behovet,
  -- og godkjenningen må ikke være forkastet.
  if not exists (
    select 1 from knowledge.monograph_source_uses u
    where u.need_id = p_need_id and u.source_version_id = p_source_version_id
      and knowledge.monograph_source_use_is_active(u.id)
  ) then
    if exists (
      select 1 from knowledge.monograph_source_uses u
      where u.need_id = p_need_id and u.source_version_id = p_source_version_id
    ) then
      return 'Kildebruken er forkastet av en redaktør, og kan ikke bære et svar.';
    end if;
    return 'Kildeversjonen er ikke godkjent for dette kunnskapsbehovet.';
  end if;

  -- Og kildebegrensningen, håndhevet her og ikke i flaten: en begrensning som
  -- bare fantes i brukergrensesnittet, ville vært en anbefaling, og en agent
  -- kunne gått utenom den (SOURCE_POLICY.md §2).
  if not workflow.monograph_source_is_permitted(
       p_need_id,
       (select sv.source_id from knowledge.source_versions sv
        where sv.id = p_source_version_id)) then
    return 'Området er begrenset til forhåndsgodkjente kilder, og denne kilden står ikke i listen.';
  end if;

  -- source_support: utdraget må stå ordrett i den registrerte representasjonen.
  v_text := knowledge.source_version_text(p_source_version_id);
  if v_text is null then
    return 'Kildeversjonen har ingen registrert representasjon å kontrollere utdraget mot.';
  end if;
  if nullif(btrim(coalesce(p_source_quote, '')), '') is null then
    return 'Svaret bærer ikke noe ordrett utdrag fra kilden.';
  end if;
  if position(btrim(p_source_quote) in v_text) = 0 then
    return 'Det ordrette utdraget står ikke i den registrerte representasjonen av kildeversjonen.';
  end if;

  -- source_locator: svaret må si hvor i dokumentet opplysningen står.
  if nullif(btrim(coalesce(p_source_locator, '')), '') is null then
    return 'Svaret sier ikke hvor i dokumentet opplysningen står.';
  end if;

  -- currency: opplysningen må ha et tidspunkt, og det kan ikke ligge fram i tid.
  if p_as_of is null then
    return 'Svaret sier ikke når opplysningen gjaldt.';
  end if;
  if p_as_of > (now() at time zone 'utc')::date then
    return 'Tidspunktet for opplysningen ligger fram i tid.';
  end if;

  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION workflow.register_monograph_source_uses(p_source_version_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_version knowledge.source_versions;
  v_row record;
  v_written integer := 0;
begin
  select sv.* into v_version
  from knowledge.source_versions sv
  where sv.id = p_source_version_id;

  if not found or v_version.representation is null then
    return 0;
  end if;

  for v_row in
    select cn.need_id,
           cn.proposed_use,
           n.scope_digest,
           c.decided_by_actor_id,
           c.decided_by_agent_run_id,
           c.recorded_by_actor_id,
           knowledge.monograph_need_material_kind(cn.need_id) as kind
    from workflow.monograph_candidate_sources c
    join workflow.monograph_candidate_source_needs cn on cn.candidate_source_id = c.id
    join knowledge.monograph_needs n on n.id = cn.need_id
    where c.source_id = v_version.source_id
      and c.decision in ('selected_for_retrieval', 'included')
      and n.relevance <> 'not_applicable'
    order by cn.need_id
  loop
    -- Representasjonen må passe det behovet trenger. Et sammendrag er ikke
    -- forskningsfulltekst, og et forskningsbehov skal ikke få en godkjent bruk
    -- av noe som ikke kan bære funnet (SOURCE_POLICY.md §5).
    if v_row.kind = 'research_full_text'
       and v_version.representation <> 'full_text' then
      continue;
    end if;
    if v_row.kind = 'authority_document'
       and v_version.representation not in ('full_text', 'regulatory_summary',
                                            'registry_record', 'secondary_report') then
      continue;
    end if;
    if v_row.kind = 'derived' then
      continue;
    end if;

    -- Er området begrenset til forhåndsgodkjente kilder, blir en relevant kilde
    -- utenfor listen et synlig forslag. Den brukes ikke i det stille, og den
    -- erklæres ikke irrelevant (ANTIDEP_CONSTITUTION.md regel 4).
    if not workflow.monograph_source_is_permitted(v_row.need_id, v_version.source_id) then
      perform workflow.record_monograph_revision_proposal(
        v_row.need_id,
        'restricted_source_offered'::workflow.monograph_proposal_kind,
        null, p_source_version_id,
        format('Kilden er valgt for dette behovet (%s), men området er begrenset '
               || 'til forhåndsgodkjente kilder og denne står ikke i listen.',
               v_row.proposed_use),
        coalesce(v_row.decided_by_actor_id, v_row.recorded_by_actor_id),
        v_row.decided_by_agent_run_id);
      continue;
    end if;

    insert into knowledge.monograph_source_uses (
      need_id, source_version_id, approved_use, scope_digest,
      approved_by_actor_id, approved_by_agent_run_id
    )
    values (
      v_row.need_id, p_source_version_id, v_row.proposed_use, v_row.scope_digest,
      case when v_row.decided_by_agent_run_id is null
           then coalesce(v_row.decided_by_actor_id, v_row.recorded_by_actor_id) end,
      v_row.decided_by_agent_run_id
    )
    on conflict on constraint monograph_source_uses_pair_key do nothing;

    if found then
      v_written := v_written + 1;
    end if;
  end loop;

  return v_written;
end;
$function$;

CREATE OR REPLACE FUNCTION knowledge.record_monograph_answer_revision(p_need_id uuid, p_knowledge_type knowledge.monograph_knowledge_type, p_origin knowledge.monograph_answer_origin, p_statement text, p_structured_value jsonb, p_uncertainty_summary text, p_limitation_note text, p_claim_revision_id uuid, p_source_version_id uuid, p_as_of date, p_source_quote text, p_source_locator text, p_recommending_body text, p_recommendation_date date, p_derived_from uuid[], p_additional_sources jsonb, p_change_reason text, p_actor_id uuid, p_agent_run_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_answer knowledge.monograph_answers;
  v_problem text;
  v_previous knowledge.monograph_answer_revisions;
  v_number integer;
  v_revision_id uuid;
  v_fields workflow.monograph_answer_check_field[];
  v_verifier_actor_id uuid;
  v_source jsonb;
  v_extra integer := 0;
begin
  -- Låsen på behovet først, slik at to samtidige svar på det samme spørsmålet
  -- blir to revisjoner i rekkefølge og ikke to revisjoner med samme nummer.
  perform 1 from knowledge.monograph_needs n where n.id = p_need_id for update;
  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kunnskapsbehovet svaret gjelder, finnes ikke.';
  end if;

  -- Låsen leses før kontrollen. Et låst svar skal ikke overskrives av
  -- automatikken — men det som ville blitt skrevet, blir et synlig forslag, så
  -- låsen skjermer ikke innholdet mot kritikk (ANTIDEP_CONSTITUTION.md regel 4).
  select a.* into v_answer
  from knowledge.monograph_answers a
  where a.need_id = p_need_id
  for update;

  if found and v_answer.locked_at is not null
     and p_origin <> 'human'::knowledge.monograph_answer_origin then
    perform workflow.record_monograph_revision_proposal(
      p_need_id,
      'locked_answer_challenged'::workflow.monograph_proposal_kind,
      p_claim_revision_id, p_source_version_id,
      format('Svaret er låst, og automatikken fikk ikke skrive dette: %s',
             left(btrim(coalesce(p_statement, '')), 3000)),
      p_actor_id, p_agent_run_id);
    return null;
  end if;

  v_problem := workflow.monograph_answer_problem(
    p_need_id, p_knowledge_type, p_claim_revision_id, p_source_version_id,
    p_as_of, p_source_quote, p_source_locator, p_derived_from);

  if v_problem is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = v_problem,
      hint = 'Et svar som ikke kan kontrolleres, skal ikke bli stående som et svar. Kontrollen er Antideps egen kode og kjører i skriveveien (ANTIDEP_CONSTITUTION.md regel 2).';
  end if;

  -- Og hver tilleggskilde, med den samme kontrollen. En kilde som slapp
  -- gjennom fordi den sto i et annet felt, ville vært en kilde ingen leste.
  if p_additional_sources is not null then
    if jsonb_typeof(p_additional_sources) <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Tilleggskildene må være en liste.';
    end if;
    for v_source in select value from jsonb_array_elements(p_additional_sources) loop
      v_problem := workflow.monograph_answer_citation_problem(
        p_need_id,
        (v_source ->> 'source_version_id')::uuid,
        (v_source ->> 'as_of')::date,
        v_source ->> 'source_quote',
        v_source ->> 'source_locator');
      if v_problem is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('Tilleggskilden kan ikke stå: %s', v_problem);
      end if;
    end loop;
  end if;

  if v_answer.id is null then
    insert into knowledge.monograph_answers (need_id, created_by_actor_id)
    values (p_need_id, p_actor_id)
    returning * into v_answer;
  end if;

  select r.* into v_previous
  from knowledge.monograph_answer_revisions r
  where r.answer_id = v_answer.id
  order by r.revision_number desc
  limit 1;

  v_number := coalesce(v_previous.revision_number, 0) + 1;

  insert into knowledge.monograph_answer_revisions (
    answer_id, revision_number, supersedes_revision_id,
    knowledge_type, origin, statement, structured_value,
    uncertainty_summary, limitation_note,
    claim_revision_id, source_version_id, as_of, source_quote, source_locator,
    recommending_body, recommendation_date, derived_from_revision_ids,
    change_reason, created_by_actor_id, created_by_agent_run_id
  )
  values (
    v_answer.id, v_number, v_previous.id,
    p_knowledge_type, p_origin, btrim(p_statement), p_structured_value,
    nullif(btrim(coalesce(p_uncertainty_summary, '')), ''),
    nullif(btrim(coalesce(p_limitation_note, '')), ''),
    p_claim_revision_id, p_source_version_id, p_as_of,
    nullif(btrim(coalesce(p_source_quote, '')), ''),
    nullif(btrim(coalesce(p_source_locator, '')), ''),
    nullif(btrim(coalesce(p_recommending_body, '')), ''),
    p_recommendation_date,
    case when p_derived_from is null or cardinality(p_derived_from) = 0
         then null else workflow.sorted_unique(p_derived_from) end,
    nullif(btrim(coalesce(p_change_reason, '')), ''),
    p_actor_id, p_agent_run_id
  )
  returning id into v_revision_id;

  if p_additional_sources is not null then
    for v_source in select value from jsonb_array_elements(p_additional_sources) loop
      insert into knowledge.monograph_answer_revision_sources
        (answer_revision_id, source_version_id, source_quote, source_locator, as_of)
      values (
        v_revision_id,
        (v_source ->> 'source_version_id')::uuid,
        btrim(v_source ->> 'source_quote'),
        btrim(v_source ->> 'source_locator'),
        (v_source ->> 'as_of')::date)
      on conflict on constraint monograph_answer_revision_sources_pair_key do nothing;
      v_extra := v_extra + 1;
    end loop;
  end if;

  -- Kontrollraden: hvilke felter som faktisk ble kontrollert for nettopp denne
  -- kunnskapstypen. «Kontrollert» skal aldri være noe et menneske må ta på tro.
  v_fields := case p_knowledge_type
    when 'research_finding' then
      array['knowledge_type_match', 'source_support', 'approved_use']
    when 'derived' then
      array['knowledge_type_match', 'derivation_basis', 'no_invented_certainty']
    when 'reasoning' then
      array['knowledge_type_match', 'derivation_basis', 'no_invented_certainty']
    else
      array['knowledge_type_match', 'source_support', 'source_locator',
            'currency', 'approved_use', 'no_invented_certainty']
  end::workflow.monograph_answer_check_field[];

  select a.id into v_verifier_actor_id
  from provenance.actors a
  where a.actor_key = 'agent:monograph-answer-verification';

  insert into workflow.monograph_answer_verifications
    (answer_revision_id, checked_fields, rationale, verifier_actor_id)
  values (
    v_revision_id, v_fields,
    format('Deterministisk svarkontroll for kunnskapstypen %L bestått i skriveveien, '
           || 'med %s tilleggskilde(r) kontrollert på samme måte.',
           p_knowledge_type, v_extra),
    v_verifier_actor_id);

  update knowledge.monograph_answers a
  set current_revision_id = v_revision_id
  where a.id = v_answer.id;

  -- Behovet er behandlet. Utfallet er svarets, og ikke en arbeidstilstand.
  perform knowledge.set_monograph_need_work_state(
    p_need_id, 'agent_complete'::knowledge.monograph_work_state,
    format('Strukturert svar registrert (revisjon %s).', v_number),
    'answered'::knowledge.monograph_outcome, p_actor_id, p_agent_run_id);

  return v_revision_id;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 6. Flatene
--
-- Vanlig innholdsendring skal ikke kreve kode, SQL eller en utviklingsagent.
-- ----------------------------------------------------------------------------

create function api.edit_monograph_answer(
  p_need_reference text,
  p_statement text,
  p_uncertainty_summary text default null,
  p_limitation_note text default null,
  p_structured_value jsonb default null,
  p_change_reason text default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_need knowledge.monograph_needs;
  v_current knowledge.monograph_answer_revisions;
  v_id uuid;
  v_sources jsonb;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  select n.* into v_need
  from knowledge.monograph_needs n
  where n.reference = p_need_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen kunnskapsbehov med denne referansen.';
  end if;

  select r.* into v_current
  from knowledge.monograph_answers a
  join knowledge.monograph_answer_revisions r on r.id = a.current_revision_id
  where a.need_id = v_need.id;

  if not found then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Behovet har ikke noe svar å rette ennå.',
      hint = 'En redaksjonell rettelse endrer et kontrollert svar. Et svar uten kildestøtte ville vært en påstand uten grunnlag, og det er ikke noe denne veien kan opprette (ANTIDEP_CONSTITUTION.md regel 2).';
  end if;

  if nullif(btrim(coalesce(p_change_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En redaksjonell endring krever en begrunnelse.',
      hint = 'Begrunnelsen er det som gjør at endringen senere kan leses som en avgjørelse framfor som en forskjell ingen forstår.';
  end if;

  -- Kildestøtten videreføres uendret. En redaksjonell rettelse er en endring
  -- av *formuleringen*, ikke av grunnlaget: en tekst som fikk bytte kilde uten
  -- kontroll, ville vært en ny påstand uten kildestøtte.
  select coalesce(jsonb_agg(jsonb_build_object(
           'source_version_id', x.source_version_id,
           'source_quote', x.source_quote,
           'source_locator', x.source_locator,
           'as_of', x.as_of)), '[]'::jsonb)
    into v_sources
  from knowledge.monograph_answer_revision_sources x
  where x.answer_revision_id = v_current.id;

  v_id := knowledge.record_monograph_answer_revision(
    v_need.id, v_current.knowledge_type,
    'human'::knowledge.monograph_answer_origin,
    p_statement,
    coalesce(p_structured_value, v_current.structured_value),
    coalesce(p_uncertainty_summary, v_current.uncertainty_summary),
    coalesce(p_limitation_note, v_current.limitation_note),
    v_current.claim_revision_id, v_current.source_version_id, v_current.as_of,
    v_current.source_quote, v_current.source_locator,
    v_current.recommending_body, v_current.recommendation_date,
    v_current.derived_from_revision_ids,
    case when jsonb_array_length(v_sources) = 0 then null else v_sources end,
    btrim(p_change_reason), v_actor_id, null);

  return jsonb_build_object(
    'need', v_need.reference,
    'revision', (select r.reference from knowledge.monograph_answer_revisions r
                 where r.id = v_id),
    'edited', true);
end;
$$;

comment on function api.edit_monograph_answer(text, text, text, text, jsonb, text) is
  'En redaksjonell rettelse av et kontrollert svar: en ny revisjon med en begrunnelse, der den forrige blir stående. Kildestøtten videreføres uendret — en rettelse endrer formuleringen, ikke grunnlaget, og en tekst som fikk bytte kilde uten kontroll, ville vært en ny påstand uten kildestøtte (ANTIDEP_CONSTITUTION.md regel 2). Veien krever ingen kode, ingen SQL og ingen utviklingsagent.';

revoke execute on function api.edit_monograph_answer(text, text, text, text, jsonb, text) from public;
grant execute on function api.edit_monograph_answer(text, text, text, text, jsonb, text) to authenticated;

create function api.lock_monograph_answer(
  p_need_reference text,
  p_reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_need knowledge.monograph_needs;
  v_answer knowledge.monograph_answers;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En låsing krever en begrunnelse.';
  end if;

  select n.* into v_need
  from knowledge.monograph_needs n where n.reference = p_need_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen kunnskapsbehov med denne referansen.';
  end if;

  update knowledge.monograph_answers a
  set locked_at = now(), locked_by_actor_id = v_actor_id, lock_reason = btrim(p_reason)
  where a.need_id = v_need.id and a.locked_at is null
  returning * into v_answer;

  if v_answer.id is null then
    return jsonb_build_object('need', v_need.reference, 'locked', false,
                              'already_locked', true);
  end if;

  return jsonb_build_object('need', v_need.reference, 'locked', true,
                            'already_locked', false);
end;
$$;

comment on function api.lock_monograph_answer(text, text) is
  'Låser et svar mot automatisk overskriving. Låsen skjermer ikke innholdet mot kritikk: kommer det et nytt kontrollert grunnlag, blir det et synlig revisjonsforslag framfor en stille utelatelse.';

revoke execute on function api.lock_monograph_answer(text, text) from public;
grant execute on function api.lock_monograph_answer(text, text) to authenticated;

create function api.unlock_monograph_answer(
  p_need_reference text,
  p_reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_need knowledge.monograph_needs;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En opphevelse av en lås krever en begrunnelse.';
  end if;

  select n.* into v_need
  from knowledge.monograph_needs n where n.reference = p_need_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen kunnskapsbehov med denne referansen.';
  end if;

  update knowledge.monograph_answers a
  set lock_reason = btrim(p_reason)
  where a.need_id = v_need.id and a.locked_at is not null;

  update knowledge.monograph_answers a
  set locked_at = null, locked_by_actor_id = null, lock_reason = null
  where a.need_id = v_need.id and a.locked_at is not null;

  return jsonb_build_object('need', v_need.reference, 'unlocked', true);
end;
$$;

revoke execute on function api.unlock_monograph_answer(text, text) from public;
grant execute on function api.unlock_monograph_answer(text, text) to authenticated;

create function api.restrict_monograph_sources(
  p_edition_reference text,
  p_template_code text,
  p_source_titles text[],
  p_reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_edition knowledge.monograph_editions;
  v_template knowledge.monograph_question_templates;
  v_restriction_id uuid;
  v_title text;
  v_source_id uuid;
  v_count integer := 0;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En kildebegrensning krever en begrunnelse.';
  end if;

  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.reference = p_edition_reference and e.superseded_at is null;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen gjeldende monografiutgave med denne referansen.';
  end if;

  select t.* into v_template
  from knowledge.monograph_question_templates t
  where t.code = upper(btrim(p_template_code))
    and t.standard_version = v_edition.standard_version;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Det finnes ingen spørsmålsmal %L i standardversjon %s.',
                       p_template_code, v_edition.standard_version);
  end if;

  if p_source_titles is null or cardinality(p_source_titles) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En kildebegrensning uten en eneste godkjent kilde ville stengt området helt.',
      hint = 'Oppgi de kildene området skal kunne bruke. Et område uten noen kilde ville aldri kunnet få et kildebelagt svar.';
  end if;

  insert into workflow.monograph_source_restrictions
    (edition_id, template_id, reason, registered_by_actor_id)
  values (v_edition.id, v_template.id, btrim(p_reason), v_actor_id)
  returning id into v_restriction_id;

  foreach v_title in array p_source_titles loop
    select s.id into v_source_id
    from knowledge.sources s
    where lower(s.title) = lower(btrim(v_title));

    if v_source_id is null then
      raise exception using
        errcode = 'no_data_found',
        message = format('Det finnes ingen registrert kilde med tittelen %L.', v_title),
        hint = 'En forhåndsgodkjent kilde må være registrert først. Uten det ville begrensningen pekt på noe som ikke finnes.';
    end if;

    insert into workflow.monograph_restriction_sources
      (restriction_id, source_id, reason, approved_by_actor_id)
    values (v_restriction_id, v_source_id, btrim(p_reason), v_actor_id)
    on conflict on constraint monograph_restriction_sources_pair_key do nothing;
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object(
    'reference', (select r.reference from workflow.monograph_source_restrictions r
                  where r.id = v_restriction_id),
    'template', v_template.code,
    'approved_sources', v_count);
end;
$$;

comment on function api.restrict_monograph_sources(text, text, text[], text) is
  'Begrenser ett spørsmålsområde i én monografiutgave til kilder et menneske har forhåndsgodkjent. Håndheves i databasen, ikke i flaten. En relevant kilde utenfor listen blir et synlig revisjonsforslag — den brukes ikke i det stille, og den erklæres ikke irrelevant (SOURCE_POLICY.md §2).';

revoke execute on function api.restrict_monograph_sources(text, text, text[], text) from public;
grant execute on function api.restrict_monograph_sources(text, text, text[], text) to authenticated;

create function api.monograph_revision_proposals(p_edition_reference text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_edition knowledge.monograph_editions;
begin
  perform knowledge.assert_editor_authorized();

  select e.* into v_edition
  from knowledge.monograph_editions e where e.reference = p_edition_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografiutgave med denne referansen.';
  end if;

  return jsonb_build_object(
    'edition', v_edition.reference,
    'proposals', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'reference', p.reference,
               'kind', p.kind::text,
               'state', p.state::text,
               'need_reference', n.reference,
               'template_code', t.code,
               'question', t.prompt,
               'scope', knowledge.monograph_need_scope_label(n.id),
               'rationale', p.rationale,
               'source_title', (
                 select s.title from knowledge.source_versions sv
                 join knowledge.sources s on s.id = sv.source_id
                 where sv.id = p.source_version_id),
               'proposed_at', p.created_at,
               'decision_note', p.decision_note)
               order by p.created_at desc), '[]'::jsonb)
      from workflow.monograph_revision_proposals p
      join knowledge.monograph_needs n on n.id = p.need_id
      join knowledge.monograph_question_templates t on t.id = n.template_id
      where n.edition_id = v_edition.id and p.state = 'open'));
end;
$$;

comment on function api.monograph_revision_proposals(text) is
  'De åpne avvikene i én monografiutgave: et nytt kontrollert grunnlag automatikken ikke fikk skrive fordi svaret er låst, og en relevant kilde utenfor et begrenset områdes forhåndsgodkjente liste. Listen finnes for at ingen av de to skal bli en stille utelatelse.';

revoke execute on function api.monograph_revision_proposals(text) from public;
grant execute on function api.monograph_revision_proposals(text) to authenticated;

create function api.decide_monograph_revision_proposal(
  p_reference text,
  p_accept boolean,
  p_note text default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_proposal workflow.monograph_revision_proposals;
  v_restriction_id uuid;
  v_source_id uuid;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  select p.* into v_proposal
  from workflow.monograph_revision_proposals p
  where p.reference = p_reference
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen revisjonsforslag med denne referansen.';
  end if;

  if v_proposal.state <> 'open' then
    return jsonb_build_object('reference', v_proposal.reference, 'decided', false,
                              'already_decided', true,
                              'state', v_proposal.state::text);
  end if;

  if not p_accept and nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En avvisning krever en begrunnelse.',
      hint = 'Begrunnelsen er det som gjør avvisningen til en faglig konklusjon framfor til en utsettelse.';
  end if;

  if p_accept and v_proposal.kind = 'restricted_source_offered' then
    -- Å godta en kilde utenfor listen er å utvide listen. Uten det ville
    -- godkjenningen vært en engangsdispensasjon ingen kunne se senere.
    v_restriction_id := (workflow.monograph_restriction_for_need(v_proposal.need_id)).id;
    select sv.source_id into v_source_id
    from knowledge.source_versions sv where sv.id = v_proposal.source_version_id;

    if v_restriction_id is not null and v_source_id is not null then
      insert into workflow.monograph_restriction_sources
        (restriction_id, source_id, reason, approved_by_actor_id)
      values (v_restriction_id, v_source_id,
              coalesce(nullif(btrim(coalesce(p_note, '')), ''),
                       'Godtatt etter at kilden ble foreslått av kildeoppdagelsen.'),
              v_actor_id)
      on conflict on constraint monograph_restriction_sources_pair_key do nothing;
    end if;
  end if;

  update workflow.monograph_revision_proposals p
  set state = case when p_accept then 'accepted'::workflow.monograph_proposal_state
                   else 'declined'::workflow.monograph_proposal_state end,
      decided_at = now(),
      decided_by_actor_id = v_actor_id,
      decision_note = nullif(btrim(coalesce(p_note, '')), '')
  where p.id = v_proposal.id;

  return jsonb_build_object(
    'reference', v_proposal.reference,
    'decided', true,
    'already_decided', false,
    'state', case when p_accept then 'accepted' else 'declined' end);
end;
$$;

comment on function api.decide_monograph_revision_proposal(text, boolean, text) is
  'Avgjør ett åpent avvik. Å godta en kilde utenfor et begrenset område utvider listen over forhåndsgodkjente kilder: uten det ville godkjenningen vært en engangsdispensasjon ingen kunne se senere. Å godta et nytt grunnlag for et låst svar er en beslutning om at svaret skal revideres — selve revisjonen er fortsatt en redaksjonell handling, fordi det er den som avgjør hva svaret skal si.';

revoke execute on function api.decide_monograph_revision_proposal(text, boolean, text) from public;
grant execute on function api.decide_monograph_revision_proposal(text, boolean, text) to authenticated;

create function api.discard_monograph_source(
  p_need_reference text,
  p_source_title text,
  p_reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_need knowledge.monograph_needs;
  v_use knowledge.monograph_source_uses;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En forkasting av en kilde krever en begrunnelse.';
  end if;

  select n.* into v_need
  from knowledge.monograph_needs n where n.reference = p_need_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen kunnskapsbehov med denne referansen.';
  end if;

  select u.* into v_use
  from knowledge.monograph_source_uses u
  join knowledge.source_versions sv on sv.id = u.source_version_id
  join knowledge.sources s on s.id = sv.source_id
  where u.need_id = v_need.id
    and lower(s.title) = lower(btrim(p_source_title))
    and knowledge.monograph_source_use_is_active(u.id)
  order by u.created_at desc
  limit 1;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen aktiv kildebruk med den tittelen for dette behovet.';
  end if;

  insert into knowledge.monograph_source_use_revocations
    (source_use_id, reason, revoked_by_actor_id)
  values (v_use.id, btrim(p_reason), v_actor_id);

  return jsonb_build_object(
    'need', v_need.reference, 'discarded', true, 'source', btrim(p_source_title));
end;
$$;

comment on function api.discard_monograph_source(text, text, text) is
  'Forkaster en godkjent kildebruk for ett kunnskapsbehov, med en begrunnelse. Godkjenningen slettes ikke: forkastingen legges til som en ny opplysning om den, fordi en sletting ville visket ut at kilden en gang ble godkjent for dette spørsmålet, og et svar som hvilte på den, ville mistet sitt opphav.';

revoke execute on function api.discard_monograph_source(text, text, text) from public;
grant execute on function api.discard_monograph_source(text, text, text) to authenticated;
