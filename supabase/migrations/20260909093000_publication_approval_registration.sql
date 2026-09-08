-- ============================================================================
-- Migrasjon 006d — den menneskelige godkjenningen får en skrivevei
--
-- `workflow.review_decisions` har fantes siden migrasjon 005, og
-- publiseringsgatens G11, G12 og G13 har lest den siden migrasjon 006: det skal
-- finnes en `publication_approval` for revisjonen, den gjeldende beslutningen
-- skal være `approved`, og den skal gjelde nøyaktig det evidenssettet som er
-- registrert nå. Ingen har kunnet skrive raden. Godkjenningen —
-- ANTIDEP_CONSTITUTION.md §12 sitt krav om at et menneske har det faglige
-- ansvaret — har vært den siste låste døra på veien til første publiserte
-- påstand (MVP_IMPLEMENTATION_PLAN.md §74.4, §74.35).
--
-- Denne migrasjonen åpner den, og gjør tre ting:
--
--   1. audit.event_operation-verdien fra 008g tas i bruk: en beslutning som
--      avgjør om klinisk innhold kan publiseres, skal etterlate en auditrad
--      (DATABASE_ARCHITECTURE.md §35).
--   2. audit.record_review_decision_event() og triggeren som skriver den.
--   3. api.register_publication_approval(...), den eneste veien inn.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE endres
--
-- Ingen gate mykes opp. G11, G12 og G13 står ordrett som de var, og de er
-- fasiten for hva en godkjenning er verdt ved publisering. Ingen CHECK,
-- constraint, trigger, policy eller grant på workflow.review_decisions endres:
-- at reviewer må være et menneske, at reviewer ikke kan være den som formulerte
-- revisjonen, at rollen må ha vært gyldig på beslutningstidspunktet med en
-- tildelingsrad som fantes senest da, at beslutningen ikke kan være datert
-- fram i tid, at begrunnelsen er påkrevd og at raden er append-only — alt står
-- uendret, og skriveveien arver hver av dem.
--
-- ----------------------------------------------------------------------------
-- Godkjenningen er ikke den faglige kontrollen
--
-- To beslutninger, to objekter, to handlinger:
-- api.register_human_claim_verification(...) (005n) registrerer at revieweren
-- har kontrollert påstanden mot grunnlaget; denne registrerer at revieweren går
-- god for at den kan publiseres. Gaten krever begge, hver for seg (G9 og G11),
-- og de kan ikke slås sammen til én «godkjenn alt»-handling uten å slå sammen to
-- forskjellige faglige utsagn (ANTIDEP_CONSTITUTION.md §11, §12).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §6, §9, §12, §13, §14
--   docs/CONTENT_GOVERNANCE.md §11, §12 godkjenning og publisering
--   docs/DATABASE_ARCHITECTURE.md §31, §35, §36, §43, §46, §50
--   docs/KNOWLEDGE_MODEL.md §19.2, §19.3
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §16, §49, §74.4, §74.35
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. audit.events dekker review_decision_registered
--
-- Samme ombygging som 005e, 007c, 007e, 005g og 005j måtte gjøre, og av samme
-- grunn: PostgreSQL har ingen ALTER COLUMN som endrer uttrykket til en generert
-- kolonne, og en CHECK kan bare endres ved DROP/ADD. Indeksen som bruker begge
-- kolonnene tas ned og opp igjen rundt det. Operasjonen er trygg på levende
-- rader: CASE-uttrykkene dekker hver eksisterende verdi uendret.
-- ----------------------------------------------------------------------------
drop index audit.events_object_occurred_at_idx;

alter table audit.events drop column object_schema;
alter table audit.events drop column object_table;

alter table audit.events add column object_schema text not null generated always as (
  case operation
    when 'claim_published' then 'knowledge'
    when 'claim_publication_replaced' then 'knowledge'
    when 'claim_publication_withdrawn' then 'knowledge'
    when 'claim_publication_rolled_back' then 'knowledge'
    when 'role_granted' then 'workflow'
    when 'role_ended' then 'workflow'
    when 'source_created' then 'knowledge'
    when 'evidence_item_created' then 'knowledge'
    when 'agent_identity_registered' then 'provenance'
    when 'agent_identity_credential_issued' then 'provenance'
    when 'agent_identity_revoked' then 'provenance'
    when 'evidence_verification_registered' then 'workflow'
    when 'source_version_registered' then 'knowledge'
    when 'claim_verification_registered' then 'workflow'
    when 'review_decision_registered' then 'workflow'
  end
) stored;

alter table audit.events add column object_table text not null generated always as (
  case operation
    when 'claim_published' then 'claims'
    when 'claim_publication_replaced' then 'claims'
    when 'claim_publication_withdrawn' then 'claims'
    when 'claim_publication_rolled_back' then 'claims'
    when 'role_granted' then 'user_roles'
    when 'role_ended' then 'user_roles'
    when 'source_created' then 'sources'
    when 'evidence_item_created' then 'evidence_items'
    when 'agent_identity_registered' then 'agent_identities'
    when 'agent_identity_credential_issued' then 'agent_identities'
    when 'agent_identity_revoked' then 'agent_identities'
    when 'evidence_verification_registered' then 'evidence_verifications'
    when 'source_version_registered' then 'source_versions'
    when 'claim_verification_registered' then 'claim_verifications'
    when 'review_decision_registered' then 'review_decisions'
  end
) stored;

comment on column audit.events.object_schema is
  'Schemaet objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen, ikke oppgitt ved siden av den, slik at de to ikke kan komme i utakt. NOT NULL på en generert kolonne gjør at en ny enum-verdi uten tilhørende gren feiler ved innsetting framfor å gi en tom kolonne.';
comment on column audit.events.object_table is
  'Tabellen objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen, med samme begrunnelse som object_schema.';

create index events_object_occurred_at_idx
  on audit.events (object_schema, object_table, object_id, occurred_at desc);

alter table audit.events drop constraint events_snapshot_shape_check;
alter table audit.events add constraint events_snapshot_shape_check
  check (
    case operation
      when 'claim_published' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_replaced' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_withdrawn' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_rolled_back' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'role_granted' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'role_ended' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'source_created' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'evidence_item_created' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'agent_identity_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'agent_identity_credential_issued' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'agent_identity_revoked' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'evidence_verification_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'source_version_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'claim_verification_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      -- En opprettelse, som de øvrige registreringene: workflow.review_decisions
      -- er append-only, og en omgjøring er en ny rad ved siden av den gamle —
      -- aldri en endring av den (DATABASE_ARCHITECTURE.md §31).
      when 'review_decision_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      else false
    end
  );

-- ----------------------------------------------------------------------------
-- 2. audit.record_review_decision_event() — produsenten for INSERT
--
-- Samme mønster som audit.record_claim_verification_event() (migrasjon 005j):
-- ikke SECURITY DEFINER, slik at auditskriveren aldri er mer privilegert enn
-- operasjonen den registrerer (§35, §60). Hele raden er snapshotet.
--
-- Triggeren ligger på tabellen og ikke i skriveveien, slik at en beslutning
-- ikke kan oppstå uten sin auditrad uansett hvordan den kom dit.
-- ----------------------------------------------------------------------------
create function audit.record_review_decision_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot,
    reason, occurred_at
  )
  values (
    'review_decision_registered'::audit.event_operation,
    new.id,
    new.reviewer_actor_id,
    null,
    to_jsonb(new),
    -- Begrunnelsen er påkrevd på raden, og den er nettopp det en auditlesning
    -- av en godkjenning trenger å se uten å slå opp objektet
    -- (ANTIDEP_CONSTITUTION.md §14).
    new.rationale,
    now()
  );

  return null;
end;
$$;

comment on function audit.record_review_decision_event() is
  'Auditskriver for den menneskelige faglige beslutningen: registrerer at en reviewbeslutning ble registrert, med hele raden som snapshot og beslutningens egen begrunnelse i reason (DATABASE_ARCHITECTURE.md §35, ANTIDEP_CONSTITUTION.md §12, §14). Kjører med kallerens rettigheter, ikke som SECURITY DEFINER, slik at en auditrad aldri kan skrives av noen som ikke kunne utført operasjonen selv (samme begrunnelse som audit.record_claim_verification_event()).';

revoke execute on function audit.record_review_decision_event() from public;

create trigger review_decisions_record_creation_audit_event
  after insert on workflow.review_decisions
  for each row execute function audit.record_review_decision_event();

-- ----------------------------------------------------------------------------
-- 3. api.register_publication_approval(...) — den eneste skriveveien
--
-- Tre ting er bevisst ikke parametre kalleren kan velge fritt:
--
--   reviewer_actor_id            kallerens egen aktør, hentet fra sesjonen
--   claim_revision_creator_...   leses fra revisjonen selv
--   approved_evidence_set_digest beregnes av databasen (migrasjon 006)
--
-- Den første er den viktigste: uten den ville en godkjenning kunnet registreres
-- i en annen persons navn, og attribusjonen ANTIDEP_CONSTITUTION.md §12 hviler
-- på ville vært en påstand fra den som skriver framfor en observasjon.
--
-- decided_at settes til now(): denne veien registrerer alltid beslutningen i det
-- den tas. En kallerstyrt dato ville latt en beslutning dateres dit
-- rolletildelingen tilfeldigvis passet, og det er nettopp det
-- review_decisions_decided_at_not_future_check og kvalifikasjonskontrollen er
-- til for å hindre.
--
-- review_type er ikke en parameter: denne veien registrerer
-- publiseringsgodkjenninger. `extraction_withdrawal` er en beslutning om et
-- evidensfunn, med sitt eget objekt og sine egne utfall, og hører til sin egen
-- skrivevei den dagen den bygges.
-- ----------------------------------------------------------------------------
create function api.register_publication_approval(
  p_claim_revision_id uuid,
  p_seen_evidence_set_digest text,
  p_decision text,
  p_rationale text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_decision workflow.review_outcome;
  v_topic_concept_id uuid;
  v_creator_actor_id uuid;
  v_reviewer_actor_id uuid;
  v_decision_id uuid;
begin
  -- Vokabularet castes først og for seg, slik at en ukjent verdi gir en setning
  -- som sier hva som er galt. Vokabularet er offentlig dokumentert
  -- (DATABASE_ARCHITECTURE.md §31).
  begin
    v_decision := p_decision::workflow.review_outcome;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent reviewbeslutning.', p_decision),
        hint = 'Gyldige beslutninger for en publiseringsgodkjenning er approved, rejected og changes_requested (DATABASE_ARCHITECTURE.md §31).';
  end;

  -- Temaet påstanden hører under er det en avgrenset reviewer-tildeling
  -- kontrolleres mot, og forfatteren er speilet den sammensatte fremmednøkkelen
  -- krever. Begge leses fra revisjonen, aldri fra kalleren.
  select cl.topic_concept_id, r.created_by_actor_id
    into v_topic_concept_id, v_creator_actor_id
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  where r.id = p_claim_revision_id;

  v_reviewer_actor_id := workflow.assert_reviewer_authorized(v_topic_concept_id);

  if v_creator_actor_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstandsrevisjonen %L finnes ikke.', p_claim_revision_id),
      hint = 'En godkjenning peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  -- Godkjenningen gjelder det grunnlaget revieweren faktisk så. Publiseringsgaten
  -- kontrollerer det samme på nytt ved publisering (G13); denne kontrollen sier
  -- fra med en gang, framfor å la en godkjenning av noe annet bli stående.
  perform workflow.assert_evidence_set_unchanged(
    p_claim_revision_id, p_seen_evidence_set_digest
  );

  insert into workflow.review_decisions (
    claim_revision_id, claim_revision_creator_actor_id,
    review_type, decision, rationale,
    reviewer_actor_id, reviewer_actor_type, decided_at
  )
  select
    p_claim_revision_id, v_creator_actor_id,
    'publication_approval'::workflow.review_type, v_decision, p_rationale,
    v_reviewer_actor_id, a.actor_type, now()
  from provenance.actors a
  where a.id = v_reviewer_actor_id
  returning id into v_decision_id;

  return v_decision_id;
end;
$$;

comment on function api.register_publication_approval(uuid, text, text, text) is
  'Den kontrollerte skriveveien for at en kvalifisert menneskelig reviewer registrerer en publiseringsgodkjenning for én påstandsrevisjon (ANTIDEP_CONSTITUTION.md §12, §14, DATABASE_ARCHITECTURE.md §31, §43, MVP_IMPLEMENTATION_PLAN.md §15). Kalleren må ha en registrert, ikke-tilbaketrukket aktør og gyldig reviewer-rolle for påstandens kliniske tema (workflow.assert_reviewer_authorized(uuid)); aktøren beslutningen attribueres til er kallerens egen og er ikke en parameter. p_seen_evidence_set_digest må være avtrykket av evidenssettet slik det er nå — en lenke som er kommet til mens vurderingen pågikk, avviser godkjenningen framfor å bli stilltiende dekket av den; publiseringsgatens G13 kontrollerer det samme igjen ved publisering. review_type er alltid publication_approval, decided_at er alltid now(), claim_revision_creator_actor_id leses fra revisjonen og approved_evidence_set_digest beregnes av databasen. Gyldige beslutninger er approved, rejected og changes_requested; alle tre bevares, og en omgjøring er en ny rad ved siden av den gamle. Godkjenningen er ikke den faglige kontrollen mot grunnlaget — den er api.register_human_claim_verification(uuid, text, text, text, text, text, text, text, text, text, jsonb, text, text), og publiseringsgaten krever begge, hver for seg (G9 og G11). Ingen feltvalidering er duplisert her: constraintene og triggerne på workflow.review_decisions er fasiten, inkludert at reviewer må være et menneske, ikke kan være den som formulerte revisjonen, og må ha hatt gyldig reviewer-rolle med en tildelingsrad som fantes senest på beslutningstidspunktet. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi workflow, knowledge og provenance har RLS med default deny; tomt search_path, og kalleren autoriseres på funksjonens eget kall (§50). EXECUTE gis bare til authenticated: en uinnlogget kaller har ingen aktør og kan ikke ha en reviewer-rolle.';

revoke execute on function api.register_publication_approval(uuid, text, text, text) from public;
grant execute on function api.register_publication_approval(uuid, text, text, text) to authenticated;
