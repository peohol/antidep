-- ============================================================================
-- Migrasjon 004a — påstandsrevisjonen får si hvilken agentkjøring den kom av,
--                  og hver ny revisjon etterlater en auditrad
--
-- Migrasjon 004 ga revisjonen `created_by_actor_id` (gjennom 005): *hvem*
-- formulerte den. For et menneske er det nok. For en agent er det ikke det:
-- ANTIDEP_CONSTITUTION.md §8 krever at det skal være mulig å spore hvilke
-- vurderinger som førte til en bestemt påstand og versjon, og §20 krever at
-- modell, modellversjon, promptmal og pipelinekonfigurasjon er versjonert. Alt
-- det står på `provenance.agent_runs` — og evidensfunnet peker allerede dit
-- (migrasjon 005x). Påstanden gjorde det ikke.
--
-- Denne migrasjonen gir revisjonen den samme pekeren, med nøyaktig de samme to
-- sammensatte fremmednøklene `knowledge.evidence_items` bruker:
--
--   (agent_run_id, created_by_actor_id) → provenance.agent_runs (id, actor_id)
--   (agent_run_id, agent_run_role)      → provenance.agent_runs (id, agent_role)
--
-- Den første gjør at en revisjon ikke kan tilskrives én aktør og peke på en
-- kjøring som tilhører en annen. Den andre gjør at kjøringen må være i den ene
-- rollen som skal kunne formulere en påstand.
--
-- `agent_run_role` er en **generert** kolonne med én fast verdi, som på
-- `knowledge.evidence_items`, `workflow.evidence_verifications` og
-- `workflow.claim_verifications`. Rollen er dermed ikke noe en kaller oppgir,
-- og kan ikke oppgis feil: den finnes bare for at fremmednøkkelen skal ha en
-- venstreside å binde mot.
--
-- `agent_run_id` er NULL-bar. NULL betyr at revisjonen ikke kom av en
-- agentkjøring — tilstanden til enhver revisjon en kvalifisert redaktør skriver
-- selv, og til radene migrasjon 004 la inn. Den betyr aldri at kjøringen er
-- ukjent. Fremmednøkkelen er MATCH SIMPLE, så en NULL peker slår av kravet.
--
-- ----------------------------------------------------------------------------
-- Auditraden
--
-- `audit.events` har hittil ikke hatt en operasjon for en ny påstandsrevisjon,
-- fordi ingen skrivevei laget en. Migrasjon 005aj lager den. Triggeren under er
-- den samme snevre formen som `audit.record_evidence_item_event()`: én rad per
-- innsetting, med hele øyeblikksbildet, ført på den aktøren raden selv
-- attribueres til.
--
-- Den henger på tabellen og ikke på skriveveien, med vilje: en auditrad som bare
-- ble skrevet av den ene veien noen husket å kalle, ville vært en logg med hull
-- akkurat der en uventet skrivevei var (DATABASE_ARCHITECTURE.md §35).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §7, §8, §10, §14, §20
--   docs/DATABASE_ARCHITECTURE.md §14, §33, §35, §57, §59, §60
--   docs/KNOWLEDGE_MODEL.md §9, §19
--   docs/EVIDENCE_PIPELINE.md §27, §46, §65
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Pekeren til agentkjøringen
-- ----------------------------------------------------------------------------
alter table knowledge.claim_revisions
  add column agent_run_id uuid,
  add column agent_run_role provenance.agent_role
    generated always as ('claim_synthesis'::provenance.agent_role) stored;

comment on column knowledge.claim_revisions.agent_run_id is
  'Agentkjøringen revisjonen ble formulert i, eller NULL når den ikke kom av en agentkjøring. NULL er tilstanden til enhver revisjon en kvalifisert redaktør skriver selv, og betyr aldri at kjøringen er ukjent. Kjøringen bærer modell, modellversjon, promptmal og pipelineversjon (ANTIDEP_CONSTITUTION.md §20), og de sammensatte fremmednøklene håndhever at den tilhører nøyaktig den aktøren raden attribueres til, og er i rollen påstandsdannelse.';
comment on column knowledge.claim_revisions.agent_run_role is
  'Rollen en agentkjøring må ha for å kunne bære en påstandsrevisjon, som en generert konstant — samme form som på knowledge.evidence_items, workflow.evidence_verifications og workflow.claim_verifications. Ikke en opplysning kalleren gir: den finnes bare som venstreside for den sammensatte fremmednøkkelen mot provenance.agent_runs (id, agent_role), slik at kravet om at bare påstandsdannelse kan formulere en påstand, håndheves deklarativt. Verdien er satt også når agent_run_id er NULL; fremmednøkkelen er MATCH SIMPLE og slår da av kravet.';

-- Rollen er rettighetsgrensen (migrasjon 005e). En revisjon skal ikke kunne
-- bæres av en kjøring i rollen ekstraksjon eller kontroll, heller ikke om en
-- senere skrivevei skulle forsøke det: da ville generering og verifikasjon
-- kunnet falle sammen i én rolle (ANTIDEP_CONSTITUTION.md §10, §11). Den
-- genererte konstanten over gjør at fremmednøkkelen under er hele regelen.
alter table knowledge.claim_revisions
  add constraint claim_revisions_agent_run_actor_fkey
    foreign key (agent_run_id, created_by_actor_id)
    references provenance.agent_runs (id, actor_id)
    on update restrict on delete restrict,
  add constraint claim_revisions_agent_run_role_fkey
    foreign key (agent_run_id, agent_run_role)
    references provenance.agent_runs (id, agent_role)
    on update restrict on delete restrict;

create index claim_revisions_agent_run_id_idx
  on knowledge.claim_revisions (agent_run_id);

-- ----------------------------------------------------------------------------
-- 2. Auditvokabularet får plass til den nye operasjonen
--
-- De to genererte kolonnene og formkontrollen er uttømmende CASE-uttrykk med
-- ELSE NULL og ELSE false, og må derfor bygges om for å slippe verdien gjennom.
-- En generert kolonne kan ikke endres, så begge slippes og lages på nytt — samme
-- grep som i migrasjon 005af og 005ah.
-- ----------------------------------------------------------------------------
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
    when 'evidence_field_grounding_recorded' then 'knowledge'
    when 'extraction_artifact_discarded' then 'knowledge'
    when 'claim_artifact_discarded' then 'knowledge'
    when 'claim_revision_created' then 'knowledge'
    else null
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
    when 'evidence_field_grounding_recorded' then 'evidence_field_groundings'
    when 'extraction_artifact_discarded' then 'evidence_items'
    when 'claim_artifact_discarded' then 'claims'
    when 'claim_revision_created' then 'claim_revisions'
    else null
  end
) stored;

comment on column audit.events.object_schema is
  'Schemaet objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen framfor oppgitt av kalleren: en kaller som kunne skrive det selv, kunne skrevet feil, og en auditrad som peker på et annet objekt enn den beskriver, er verre enn ingen auditrad. Uttrykket er uttømmende med ELSE NULL, og en ny operasjon uten sin gren feiler derfor på NOT NULL framfor å bli en rad uten sted.';
comment on column audit.events.object_table is
  'Tabellen objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen, med samme begrunnelse som object_schema.';

-- Indeksen henger på de to kolonnene og forsvant med dem. Navnet er det samme
-- som før, fordi supabase/tests/300_audit_structure_test.sql kontrollerer at
-- oppslagsveien loggen finnes for, er indeksert — under sitt navn.
create index events_object_occurred_at_idx
  on audit.events (object_schema, object_table, object_id, occurred_at desc);

alter table audit.events drop constraint events_snapshot_shape_check;
alter table audit.events add constraint events_snapshot_shape_check
  check (
    case operation
      when 'claim_published' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_replaced' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_withdrawn' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_rolled_back' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'role_granted' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'role_ended' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'source_created' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'evidence_item_created' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'agent_identity_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'agent_identity_credential_issued' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'agent_identity_revoked' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'evidence_verification_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'source_version_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'claim_verification_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'review_decision_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'evidence_field_grounding_recorded' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      -- Fjerningen: det finnes et før og ingen etter (migrasjon 005af).
      when 'extraction_artifact_discarded' then old_revision_or_snapshot is not null and new_revision_or_snapshot is null
      -- Påstandssidens fjerning, med den samme formen (migrasjon 005ah).
      when 'claim_artifact_discarded' then old_revision_or_snapshot is not null and new_revision_or_snapshot is null
      -- En ny påstandsrevisjon: det finnes ingen tidligere utgave av *denne*
      -- raden, fordi en revisjon er uforanderlig. Videreføringen den eventuelt
      -- erstatter, står i øyeblikksbildets supersedes_revision_id.
      when 'claim_revision_created' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      else false
    end
  );

comment on constraint events_snapshot_shape_check on audit.events is
  'Hvilke øyeblikksbilder hver operasjon skal bære (DATABASE_ARCHITECTURE.md §35). Uttømmende CASE med ELSE false: en ny operasjon uten sin egen gren kan ikke bli en auditrad, og det er tilsiktet — en auditrad uten det øyeblikksbildet operasjonen forutsetter, ville sett ut som et spor uten å være et. En opprettelse har bare et etter, en endring har begge, og en fjerning (extraction_artifact_discarded i migrasjon 005af, claim_artifact_discarded i 005ah) har bare et før.';

-- ----------------------------------------------------------------------------
-- 3. Auditskriveren over nye påstandsrevisjoner
-- ----------------------------------------------------------------------------
create function audit.record_claim_revision_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot,
    request_or_run_id, occurred_at
  )
  values (
    'claim_revision_created'::audit.event_operation,
    new.id,
    new.created_by_actor_id,
    null,
    to_jsonb(new),
    -- Kjøringen, når revisjonen kom av en. NULL for en revisjon en kvalifisert
    -- redaktør skriver selv; kolonnen er den samme sporingsnøkkelen de øvrige
    -- skriverne bruker (DATABASE_ARCHITECTURE.md §35).
    new.agent_run_id,
    now()
  );

  return null;
end;
$$;

comment on function audit.record_claim_revision_event() is
  'Auditskriver over nye påstandsrevisjoner (DATABASE_ARCHITECTURE.md §35, ANTIDEP_CONSTITUTION.md §14). Skriver én rad med hele øyeblikksbildet, ført på den aktøren revisjonen attribueres til og med agentkjøringen som sporingsnøkkel. Ligger på tabellen og ikke på skriveveien, slik at en senere skrivevei ikke kan lage en klinisk påstand uten spor.';

revoke execute on function audit.record_claim_revision_event() from public;

create trigger claim_revisions_record_creation_audit_event
  after insert on knowledge.claim_revisions
  for each row execute function audit.record_claim_revision_event();
