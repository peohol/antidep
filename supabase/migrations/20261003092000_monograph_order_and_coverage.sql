-- ============================================================================
-- Migrasjon 013c — bestillingen, kunnskapsbehovene og den ærlige dekningen
--
-- Normalinngangen i Antidep har vært «her er en artikkel». Denne migrasjonen
-- gjør den til «bygg monografi for sertralin»: én bestilling, og Antidep
-- oppretter selv de konkrete kunnskapsbehovene av standardregisteret.
--
-- ----------------------------------------------------------------------------
-- Hvorfor 80 maler ikke er 80 behov
--
-- Fordi avgrensningen følger svaret. Effekten ved én indikasjon, én
-- pasientgruppe og én behandlingsfase kan ikke stille erstatte et svar for en
-- annen (MONOGRAPH_STANDARD.md §2). En mal gjentas derfor per relevant produkt,
-- formulering, indikasjon, populasjon, utfall, risikoområde, interaksjon, gen
-- eller rettet byttepar, og hvert av de behovene har sin egen relevans, sin
-- egen arbeidstilstand og sitt eget faglige utfall.
--
-- Behovets identitet er derfor (utgave, mal, svarform, avgrensning) — der
-- avgrensningen er et avtrykk databasen regner av de fem katalogpekerne, de
-- frie etikettene og de aksene som er uttrykkelig markert som ikke relevante.
-- To behov kolliderer ikke fordi begge gjelder det samme virkestoffet og det
-- samme temaet.
--
-- ----------------------------------------------------------------------------
-- Hvorfor tre tilstander og ikke én
--
-- Standardens §5 krever at relevans, arbeidstilstand og faglig utfall holdes
-- fra hverandre, og det er ikke ryddighet: «ikke undersøkt», «teknisk stopp»,
-- «avventer tilgang» og «undersøkt, men utilstrekkelig evidens» er fire
-- forskjellige opplysninger, og en flate som viste dem likt, ville gjort et
-- hull om til en konklusjon (ANTIDEP_CONSTITUTION.md regel 4).
--
-- Derfor er de tre kolonner med tre vokabularer, og derfor har raden ingen
-- felles «status». Dekningen regnes av dem hver for seg.
--
-- ----------------------------------------------------------------------------
-- Hvorfor uavklart relevans ikke er «ikke relevant»
--
-- Et behov opprettes som `relevant` når malen er obligatorisk å undersøke, og
-- som `undetermined` når den er betinget: betingelsen er ikke avgjort ennå, og
-- en ukjent betingelse er ikke en usann betingelse (MONOGRAPH_STANDARD.md §3).
-- `not_applicable` krever en positiv, kontrollerbar begrunnelse og et
-- menneskelig eller separat kontrollert opphav — «ingen data», «ikke godkjent
-- hos barn» og «fant ingen kilde» er ikke gyldige grunner (§5.1).
--
-- ----------------------------------------------------------------------------
-- Hvorfor en agent kan foreslå et begrep, men ikke ta det i bruk selv
--
-- Katalogen er liten med vilje, og en monografi trenger flere indikasjoner,
-- utfall og populasjoner enn den har. Å kreve at en redaktør fyller katalogen
-- først, ville vært å flytte litteraturarbeidets arbeidsledelse tilbake til
-- klinikeren. Å la ekstraksjonsagenten skrive i katalogen ville vært verre: da
-- kunne den som skal finne et svar, endre sitt eget mandat for å få funnet
-- godkjent (MONOGRAPH_STANDARD.md §4).
--
-- `workflow.monograph_term_proposals` er veien imellom. Forslaget bærer
-- kildeversjonen og det ordrette utdraget det hviler på, og *aksepten* er en
-- egen handling med et annet opphav. Ingen agent kan akseptere sitt eget
-- forslag: skriveveien krever at aksepterende aktør er et menneske med
-- redaktørmandat, eller en kjøring i et annet agentledd enn den som foreslo.
--
-- Styrende dokumenter: docs/MONOGRAPH_STANDARD.md §2–§5, docs/SOURCE_POLICY.md,
-- docs/ANTIDEP_CONSTITUTION.md regel 4, 7, docs/DATABASE_ARCHITECTURE.md,
-- AGENTS.md.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Auditvokabularet fra 013b tas i bruk
--
-- CASE-uttrykkene er uttømmende over vokabularet, og ELSE-grenene er det som
-- gjør dem det: en ny enum-verdi uten en gren ville gitt NULL på en NOT NULL og
-- `false` i formkontrollen, framfor å gli gjennom.
-- ----------------------------------------------------------------------------
-- En generert kolonne kan ikke endres, så begge slippes og lages på nytt — samme
-- grep som i migrasjon 004a, 005af, 005ah og 009a.
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
      when 'source_document_stored' then 'knowledge'
      when 'role_model_assignment_registered' then 'provenance'
      when 'role_model_assignment_closed' then 'provenance'
      when 'candidate_built' then 'knowledge'
      when 'candidate_final_control_recorded' then 'workflow'
      when 'monograph_edition_ordered' then 'knowledge'
      when 'monograph_need_relevance_decided' then 'knowledge'
      when 'monograph_term_accepted' then 'workflow'
      when 'monograph_answer_revision_created' then 'knowledge'
      when 'monograph_answer_lock_changed' then 'knowledge'
      when 'monograph_source_restriction_registered' then 'workflow'
      when 'monograph_candidate_built' then 'knowledge'
      when 'monograph_final_control_recorded' then 'workflow'
      when 'monograph_published' then 'knowledge'
      when 'monograph_publication_withdrawn' then 'knowledge'
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
      when 'source_document_stored' then 'source_documents'
      when 'role_model_assignment_registered' then 'role_model_assignments'
      when 'role_model_assignment_closed' then 'role_model_assignments'
      when 'candidate_built' then 'candidates'
      when 'candidate_final_control_recorded' then 'candidate_final_controls'
      when 'monograph_edition_ordered' then 'monograph_editions'
      when 'monograph_need_relevance_decided' then 'monograph_needs'
      when 'monograph_term_accepted' then 'monograph_term_proposals'
      when 'monograph_answer_revision_created' then 'monograph_answer_revisions'
      when 'monograph_answer_lock_changed' then 'monograph_answers'
      when 'monograph_source_restriction_registered' then 'monograph_source_restrictions'
      when 'monograph_candidate_built' then 'monograph_edition_candidates'
      when 'monograph_final_control_recorded' then 'monograph_final_controls'
      when 'monograph_published' then 'monograph_editions'
      when 'monograph_publication_withdrawn' then 'monograph_editions'
    else null
  end
) stored;

comment on column audit.events.object_schema is
  'Schemaet objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen framfor oppgitt av kalleren: en kaller som kunne skrive det selv, kunne skrevet feil, og en auditrad som peker på et annet objekt enn den beskriver, er verre enn ingen auditrad. Uttrykket er uttømmende med ELSE NULL, og en ny operasjon uten sin gren feiler derfor på NOT NULL framfor å bli en rad uten sted.';
comment on column audit.events.object_table is
  'Tabellen objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen, med samme begrunnelse som object_schema.';

-- Indeksen over «hva har skjedd med dette objektet?» hang på de to kolonnene og
-- forsvant med dem. Den lages på nytt her, av samme grunn som i migrasjon 009a:
-- oppslaget er det auditloggen finnes for.
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
      when 'review_decision_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'evidence_field_grounding_recorded' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'extraction_artifact_discarded' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is null
      when 'claim_artifact_discarded' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is null
      when 'claim_revision_created' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'source_document_stored' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'role_model_assignment_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'role_model_assignment_closed' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'candidate_built' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'candidate_final_control_recorded' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'monograph_edition_ordered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'monograph_need_relevance_decided' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'monograph_term_accepted' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'monograph_answer_revision_created' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'monograph_answer_lock_changed' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'monograph_source_restriction_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'monograph_candidate_built' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'monograph_final_control_recorded' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'monograph_published' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'monograph_publication_withdrawn' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      else false
    end
  );

-- ----------------------------------------------------------------------------
-- 2. De tre tilstandsvokabularene
-- ----------------------------------------------------------------------------

create type knowledge.monograph_relevance as enum (
  'relevant',
  'not_applicable',
  'undetermined'
);

revoke usage on type knowledge.monograph_relevance from public;

comment on type knowledge.monograph_relevance is
  'Om kunnskapsbehovet gjelder for dette virkestoffet og denne avgrensningen (MONOGRAPH_STANDARD.md §5.1): relevant, not_applicable med en positiv og kontrollerbar begrunnelse, eller undetermined. undetermined er en reell tilstand og aldri et mildere «ikke relevant»: «ingen data», «ikke godkjent hos barn» og «fant ingen kilde» er ikke grunner til å utelate et spørsmål, og manglende godkjenning for en pasientgruppe er ikke i seg selv grunn til å utelate gruppens sikkerhetsspørsmål.';

create type knowledge.monograph_work_state as enum (
  'not_started',
  'searching',
  'appraising_sources',
  'awaiting_access',
  'extracting',
  'awaiting_clarification',
  'technical_stop',
  'agent_complete'
);

revoke usage on type knowledge.monograph_work_state from public;

comment on type knowledge.monograph_work_state is
  'Hvor arbeidet med behovet står (MONOGRAPH_STANDARD.md §5.2): not_started, searching (søk pågår), appraising_sources (kilder vurderes eller innhentes), awaiting_access (kilden finnes, men er ikke tilgjengelig), extracting (ekstraksjon og kontroll pågår), awaiting_clarification (noe må avklares redaksjonelt), technical_stop (en teknisk svikt står i veien) og agent_complete. De åtte flates aldri ut til ett nullfelt: en betalingsmur, en teknisk feil og et gjennomført søk uten kvalifiserende funn er tre forskjellige opplysninger, og bare den siste er et faglig utfall (ANTIDEP_CONSTITUTION.md regel 4).';

create type knowledge.monograph_outcome as enum (
  'answered',
  'no_qualifying_evidence',
  'insufficient_evidence',
  'conflicting_evidence',
  'not_applicable'
);

revoke usage on type knowledge.monograph_outcome from public;

comment on type knowledge.monograph_outcome is
  'Det faglige utfallet av et ferdig behandlet behov (MONOGRAPH_STANDARD.md §5.3): answered (det finnes et kontrollert svar innen en eksplisitt avgrensning — også et nøytralt eller negativt resultat med lav evidenssikkerhet), no_qualifying_evidence (dokumenterte søk er avsluttet etter kildepolitikken uten kvalifiserende grunnlag), insufficient_evidence (relevant grunnlag er vurdert, men bærer ikke et svar), conflicting_evidence (reelle uforenlige funn er gjennomgått og synliggjort) og not_applicable (relevansavgjørelsen er begrunnet og kontrollert). Utfallet settes bare på et behov som faktisk er ferdig behandlet: manglende fulltekst, uavklart agentuenighet og teknisk feil er arbeidstilstander og skal aldri bli «utilstrekkelig evidens» eller «ingen relevante studier».';

-- ----------------------------------------------------------------------------
-- 3. Bestillingen
--
-- Raden har bevisst ingen statuskolonne. Livssyklusen avledes av behovene, av
-- `superseded_at` og av publiseringspekeren — samme form som
-- `knowledge.claims` (DATABASE_ARCHITECTURE.md §15). Standardens fire
-- fullføringsnivåer er forskjellige spørsmål med forskjellige svar, og en
-- enkelt kolonne ville tvunget dem sammen (§5.4).
-- ----------------------------------------------------------------------------

create table knowledge.monograph_editions (
  id uuid primary key default gen_random_uuid(),
  -- Det ugjennomsiktige håndtaket brukerflaten viser. Ingen intern id forlater
  -- databasen (migrasjon 012a).
  reference text not null default workflow.new_public_reference(),

  drug_id uuid not null
    references catalog.drugs (id) on update restrict on delete restrict,
  standard_version text not null
    references knowledge.monograph_standard_versions (version)
    on update restrict on delete restrict,
  edition_no integer not null,

  ordered_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  ordered_at timestamptz not null default now(),
  order_note text,

  -- Når en nyere utgave tok over. En avløst utgave beholder sine behov, sine
  -- svar og sin historikk: den er det en godkjent monografi ble bygget av.
  superseded_at timestamptz,
  superseded_note text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint monograph_editions_reference_key unique (reference),
  constraint monograph_editions_drug_edition_key unique (drug_id, edition_no),
  constraint monograph_editions_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$'),
  constraint monograph_editions_edition_no_check check (edition_no >= 1),
  constraint monograph_editions_order_note_shape_check
    check (order_note is null
           or (order_note = btrim(order_note) and length(order_note) between 1 and 2000)),
  constraint monograph_editions_superseded_pairing_check
    check ((superseded_at is null) = (superseded_note is null)),
  constraint monograph_editions_superseded_note_shape_check
    check (superseded_note is null
           or (superseded_note = btrim(superseded_note)
               and length(superseded_note) between 1 and 2000))
);

comment on table knowledge.monograph_editions is
  'Én versjonert monografibestilling: «bygg monografi for dette virkestoffet», med den standardversjonen behovene ble opprettet av. Raden har bevisst ingen statuskolonne — standardens fire fullføringsnivåer (dekningskart opprettet, agentferdig kandidat, publisert monografi, handlingsklar funksjon) er forskjellige spørsmål, og de avledes av behovene, kandidaten og publiseringshistorikken framfor å tvinges inn i ett felt (MONOGRAPH_STANDARD.md §5.4). En duplikatbestilling på et virkestoff som allerede har en gjeldende utgave, er den samme utgaven og ikke en ny.';
comment on column knowledge.monograph_editions.standard_version is
  'Standardversjonen utgaven ble opprettet under. Står på utgaven fordi en ny standardversjon aldri skal kunne endre spørsmålet under et svar som allerede finnes (MONOGRAPH_STANDARD.md §9): en migrering til en ny versjon er en ny utgave, med en eksplisitt overføring av dekningskartet.';
comment on column knowledge.monograph_editions.superseded_at is
  'Når en nyere utgave tok over. Utgaven beholder sine behov, svar og sin historikk: den er det en godkjent monografi ble bygget av, og den skrives ikke om.';

alter table knowledge.monograph_editions enable row level security;

create index monograph_editions_drug_idx on knowledge.monograph_editions (drug_id);
create unique index monograph_editions_one_current_per_drug
  on knowledge.monograph_editions (drug_id)
  where superseded_at is null;

comment on index knowledge.monograph_editions_one_current_per_drug is
  'Ett virkestoff har høyst én gjeldende monografiutgave. Regelen er det som gjør en duplikatbestilling til den samme utgaven framfor til et andre dekningskart som sier noe annet: to samtidige bestillinger på sertralin kan ikke begge opprette en utgave, og den som taper kappløpet, får den som finnes.';

create trigger monograph_editions_set_row_timestamps
  before insert or update on knowledge.monograph_editions
  for each row execute function catalog.set_row_timestamps();

-- Identiteten er uforanderlig. Virkestoffet, standardversjonen, nummeret og
-- opphavet er det utgaven *er*; en endring ville gjort alle behov og svar under
-- den uforklarlige.
create function knowledge.freeze_monograph_edition()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.reference is distinct from old.reference
     or new.drug_id is distinct from old.drug_id
     or new.standard_version is distinct from old.standard_version
     or new.edition_no is distinct from old.edition_no
     or new.ordered_by_actor_id is distinct from old.ordered_by_actor_id
     or new.ordered_at is distinct from old.ordered_at
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En monografiutgaves identitet er uforanderlig.',
      hint = 'Virkestoffet, standardversjonen, nummeret og opphavet er det utgaven er. En endring ville gjort behovene og svarene under den uforklarlige (ANTIDEP_CONSTITUTION.md regel 7). En ny standardversjon eller et nytt virkestoff er en ny utgave.';
  end if;

  if old.superseded_at is not null
     and (new.superseded_at is distinct from old.superseded_at
          or new.superseded_note is distinct from old.superseded_note) then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En avløst monografiutgave kan ikke avløses på nytt eller gjenåpnes.',
      hint = 'Avløsningen er selv et historisk faktum. En gjenåpning er en ny utgave.';
  end if;

  return new;
end;
$$;

comment on function knowledge.freeze_monograph_edition() is
  'Holder monografiutgavens identitet uforanderlig og lar den bare avløses, én gang. Samme form som fryseren på kildeversjoner og modelltildelinger.';

revoke execute on function knowledge.freeze_monograph_edition() from public;

create trigger monograph_editions_identity_is_frozen
  before update on knowledge.monograph_editions
  for each row execute function knowledge.freeze_monograph_edition();

create function audit.record_monograph_edition_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, reason, occurred_at
  )
  values (
    'monograph_edition_ordered'::audit.event_operation,
    new.id,
    new.ordered_by_actor_id,
    null,
    to_jsonb(new),
    new.order_note,
    new.ordered_at
  );
  return null;
end;
$$;

comment on function audit.record_monograph_edition_event() is
  'Auditskriver over bestilte monografiutgaver (DATABASE_ARCHITECTURE.md §35). Å bestille en monografi er en redaksjonell avgjørelse om hva Antidep skal undersøke, og den skal kunne leses tilbake til den som tok den.';

revoke execute on function audit.record_monograph_edition_event() from public;

create trigger monograph_editions_record_audit_event
  after insert on knowledge.monograph_editions
  for each row execute function audit.record_monograph_edition_event();

-- ----------------------------------------------------------------------------
-- 4. Kunnskapsbehovene
--
-- Avgrensningen er fem katalogpekere med ekte fremmednøkler, frie etiketter for
-- de aksene katalogen ikke har en identitet for, og listen over akser som er
-- uttrykkelig markert som ikke relevante. Avtrykket regnes av alle tre.
--
-- Katalogpekerne er ikke pynt: de er det den eksisterende evidenskjeden bygger
-- ekstraksjonsoppdraget og syntesen av. Uten dem måtte kjeden lest en etikett
-- ut av en jsonb og slått den opp på nytt — og en etikett som ikke traff, ville
-- gitt et funn på et naboendepunkt.
-- ----------------------------------------------------------------------------

create table knowledge.monograph_needs (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  edition_id uuid not null
    references knowledge.monograph_editions (id) on update restrict on delete restrict,
  template_id uuid not null
    references knowledge.monograph_question_templates (id)
    on update restrict on delete restrict,
  -- Hvilken av malens svarformer dette behovet dekker. En mal med to former er
  -- to kontrollerbare svar (MONOGRAPH_STANDARD.md §2).
  answer_form knowledge.monograph_answer_form not null,

  -- Avgrensningen: katalogpekerne først.
  indication_concept_id uuid
    references catalog.clinical_concepts (id) on update restrict on delete restrict,
  outcome_concept_id uuid
    references catalog.clinical_concepts (id) on update restrict on delete restrict,
  population_id uuid
    references catalog.populations (id) on update restrict on delete restrict,
  comparator_drug_id uuid
    references catalog.drugs (id) on update restrict on delete restrict,
  -- Rettet med vilje: A→B og B→A er forskjellige behov (§3.12).
  switch_target_drug_id uuid
    references catalog.drugs (id) on update restrict on delete restrict,

  -- Og etikettene for de aksene katalogen ikke har en identitet for:
  -- produkt, formulering, behandlingsfase, dose, tidsrom, interaksjonsmotpart,
  -- eksponering, komorbiditet, risikoområde, gen og funn.
  scope_labels jsonb not null default '{}'::jsonb,
  -- Aksene som er uttrykkelig markert som ikke relevante for dette behovet.
  -- Standarden krever at de markeres framfor å være stille tomme (§2).
  scope_not_applicable knowledge.monograph_scope_axis[] not null
    default array[]::knowledge.monograph_scope_axis[],

  scope_digest text not null,

  relevance knowledge.monograph_relevance not null default 'undetermined',
  relevance_reason text,
  relevance_decided_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  relevance_decided_at timestamptz,

  work_state knowledge.monograph_work_state not null default 'not_started',
  work_state_note text,

  outcome knowledge.monograph_outcome,

  -- Hvilket behov som aktiverte dette, og hvorfor. En betinget mal aktivert av
  -- et dokumentert funn skal kunne leses tilbake til funnet.
  activated_by_need_id uuid
    references knowledge.monograph_needs (id) on update restrict on delete restrict,
  activation_reason text not null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint monograph_needs_reference_key unique (reference),
  constraint monograph_needs_identity_key
    unique (edition_id, template_id, answer_form, scope_digest),
  constraint monograph_needs_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$'),
  constraint monograph_needs_scope_labels_object_check
    check (jsonb_typeof(scope_labels) = 'object'),
  constraint monograph_needs_scope_digest_shape_check
    check (scope_digest ~ '^sha256:[0-9a-f]{64}$'),
  constraint monograph_needs_activation_reason_shape_check
    check (activation_reason = btrim(activation_reason)
           and length(activation_reason) between 1 and 1000),
  constraint monograph_needs_relevance_reason_shape_check
    check (relevance_reason is null
           or (relevance_reason = btrim(relevance_reason)
               and length(relevance_reason) between 1 and 2000)),
  constraint monograph_needs_work_state_note_shape_check
    check (work_state_note is null
           or (work_state_note = btrim(work_state_note)
               and length(work_state_note) between 1 and 2000)),

  -- «Ikke relevant» krever en positiv, kontrollerbar begrunnelse og en
  -- navngitt avgjørelse. Uten dette kunne et vanskelig spørsmål forsvinne ut
  -- av nevneren uten at noen hadde tatt stilling til noe (§5.1).
  constraint monograph_needs_not_applicable_needs_reason_check
    check (relevance <> 'not_applicable'
           or (relevance_reason is not null
               and relevance_decided_by_actor_id is not null
               and relevance_decided_at is not null)),
  constraint monograph_needs_relevance_decision_pairing_check
    check ((relevance_decided_by_actor_id is null) = (relevance_decided_at is null)),

  -- Utfallet hører til et behov som faktisk er ferdig behandlet. Et utfall på
  -- et behov som fortsatt søker, ville vært en konklusjon om evidensen trukket
  -- av arbeidets tilstand (ANTIDEP_CONSTITUTION.md regel 4).
  constraint monograph_needs_outcome_needs_completion_check
    check (outcome is null or work_state = 'agent_complete'),
  constraint monograph_needs_complete_needs_outcome_check
    check (work_state <> 'agent_complete' or outcome is not null),
  -- Og de to vokabularene skal si det samme om relevansen.
  constraint monograph_needs_outcome_matches_relevance_check
    check ((outcome = 'not_applicable') is not true or relevance = 'not_applicable'),
  constraint monograph_needs_not_applicable_outcome_check
    check (relevance <> 'not_applicable'
           or outcome is null
           or outcome = 'not_applicable'),

  -- Et behov kan ikke ha aktivert seg selv.
  constraint monograph_needs_activation_not_self_check
    check (activated_by_need_id is distinct from id)
);

comment on table knowledge.monograph_needs is
  'Ett konkret kunnskapsbehov i én monografiutgave: én spørsmålsmal, én svarform og én avgrensning. Identiteten er (utgave, mal, svarform, avgrensningsavtrykk), fordi avgrensningen følger svaret: to svar skal ikke kollidere fordi begge gjelder det samme virkestoffet og det samme overordnede temaet når indikasjon, populasjon, dose, formulering, komparator eller tidsrom er forskjellig (MONOGRAPH_STANDARD.md §2). Relevans, arbeidstilstand og faglig utfall er tre kolonner med tre vokabularer og flates aldri ut til én status (§5).';
comment on column knowledge.monograph_needs.scope_labels is
  'Avgrensningsaksene katalogen ikke har en identitet for — produkt, formulering, behandlingsfase, dose, tidsrom, interaksjonsmotpart, eksponering, komorbiditet, risikoområde, gen og funn — som akse til etikett. Katalogaksene ligger som ekte fremmednøkler ved siden av, fordi det er dem den eksisterende evidenskjeden bygger ekstraksjonsoppdraget og syntesen av.';
comment on column knowledge.monograph_needs.scope_not_applicable is
  'Aksene som er uttrykkelig markert som ikke relevante for dette behovet. Standarden krever at en ikke-relevant dimensjon markeres framfor å være stille tom (MONOGRAPH_STANDARD.md §2): en tom komparator kan ellers like godt bety «ingen komparator» som «ikke undersøkt».';
comment on column knowledge.monograph_needs.scope_digest is
  'Avtrykket av hele avgrensningen, regnet av databasen av katalogpekerne, etikettene og de ikke-relevante aksene. Er identiteten sammen med utgaven, malen og svarformen; en verdi en kaller kunne oppgi, ville latt to forskjellige avgrensninger kollidere eller det samme behovet bli opprettet to ganger.';
comment on column knowledge.monograph_needs.activation_reason is
  'Hvorfor behovet finnes: at malen er obligatorisk, eller det dokumenterte funnet som aktiverte den betingede malen. Påkrevd, fordi et dekningskart der noen behov ikke kan forklares, ikke er et dekningskart.';

alter table knowledge.monograph_needs enable row level security;

create index monograph_needs_edition_idx on knowledge.monograph_needs (edition_id);
create index monograph_needs_template_idx on knowledge.monograph_needs (template_id);
create index monograph_needs_open_idx
  on knowledge.monograph_needs (edition_id, work_state)
  where work_state <> 'agent_complete';

create trigger monograph_needs_set_row_timestamps
  before insert or update on knowledge.monograph_needs
  for each row execute function catalog.set_row_timestamps();

-- ----------------------------------------------------------------------------
-- 4b. Avtrykket er databasens
-- ----------------------------------------------------------------------------

create function knowledge.monograph_scope_canonical(p_need knowledge.monograph_needs)
  returns jsonb
  language sql
  immutable
  set search_path = ''
as $$
  -- Kanonisk: samme avgrensning gir samme tekst uansett rekkefølgen den ble
  -- skrevet i. jsonb sorterer nøklene selv, og de tomme verdiene utelates slik
  -- at «ikke satt» og «satt til null» er den samme avgrensningen.
  select jsonb_strip_nulls(jsonb_build_object(
    'indication_concept_id', p_need.indication_concept_id,
    'outcome_concept_id', p_need.outcome_concept_id,
    'population_id', p_need.population_id,
    'comparator_drug_id', p_need.comparator_drug_id,
    'switch_target_drug_id', p_need.switch_target_drug_id,
    'labels', case when p_need.scope_labels = '{}'::jsonb then null
                   else p_need.scope_labels end,
    'not_applicable', case when cardinality(p_need.scope_not_applicable) = 0 then null
                           else to_jsonb((
                             select array_agg(a::text order by a::text)
                             from unnest(p_need.scope_not_applicable) as a
                           )) end
  ));
$$;

comment on function knowledge.monograph_scope_canonical(knowledge.monograph_needs) is
  'Avgrensningen i kanonisk form: de samme opplysningene gir den samme teksten uansett hvilken rekkefølge de ble skrevet i. jsonb sorterer nøklene selv, de tomme verdiene fjernes slik at «ikke satt» og «satt til null» er den samme avgrensningen, og de ikke-relevante aksene sorteres. Grunnlaget for scope_digest.';

revoke execute on function knowledge.monograph_scope_canonical(knowledge.monograph_needs) from public;

create function knowledge.set_monograph_scope_digest()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_template knowledge.monograph_question_templates;
  v_axis text;
  v_label jsonb;
begin
  select t.* into v_template
  from knowledge.monograph_question_templates t
  where t.id = new.template_id;

  -- Svarformen må være en malen faktisk har. Et behov i en form standarden ikke
  -- ber om, ville vært et svar ingen kontrakt dekker.
  if not (new.answer_form = any (v_template.answer_forms)) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Malen %s har ikke svarformen %L.', v_template.code, new.answer_form),
      hint = format('Malens svarformer er %s (MONOGRAPH_STANDARD.md §2).',
                    array_to_string(v_template.answer_forms::text[], ', '));
  end if;

  -- Etikettene skal ha en gyldig akse som nøkkel og en lesbar etikett som
  -- verdi. En fri nøkkel ville gjort avgrensningen til et fritekstfelt, og to
  -- skrivemåter av den samme aksen til to forskjellige behov.
  for v_axis, v_label in select key, value from jsonb_each(new.scope_labels) loop
    begin
      perform v_axis::knowledge.monograph_scope_axis;
    exception
      when invalid_text_representation then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('%L er ikke en avgrensningsakse.', v_axis),
          hint = 'Aksene er knowledge.monograph_scope_axis. En fri nøkkel ville gjort avgrensningen til et fritekstfelt, og to skrivemåter av den samme aksen til to forskjellige behov.';
    end;

    if jsonb_typeof(v_label) <> 'string'
       or btrim(v_label #>> '{}') = ''
       or length(v_label #>> '{}') > 300 then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Etiketten for aksen %L er ikke en lesbar tekst.', v_axis);
    end if;
  end loop;

  -- Katalogaksene skal peke på riktig slags begrep. En indikasjon er en
  -- tilstand og et endepunkt et utfall; en peker på tvers ville gitt et behov
  -- som så avgrenset ut, men ikke var det.
  if new.indication_concept_id is not null and not exists (
    select 1 from catalog.clinical_concepts c
    where c.id = new.indication_concept_id and c.concept_type = 'condition'
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Indikasjonen i avgrensningen er ikke en tilstand i katalogen.';
  end if;
  if new.outcome_concept_id is not null and not exists (
    select 1 from catalog.clinical_concepts c
    where c.id = new.outcome_concept_id and c.concept_type = 'outcome'
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Endepunktet i avgrensningen er ikke et utfall i katalogen.';
  end if;

  -- En akse kan ikke være både avgrenset og markert som ikke relevant.
  if exists (
    select 1
    from unnest(new.scope_not_applicable) as a
    where new.scope_labels ? a::text
       or (a = 'indication' and new.indication_concept_id is not null)
       or (a = 'outcome' and new.outcome_concept_id is not null)
       or (a = 'population' and new.population_id is not null)
       or (a = 'comparator' and new.comparator_drug_id is not null)
       or (a = 'switch_target' and new.switch_target_drug_id is not null)
  ) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En avgrensningsakse er både satt og markert som ikke relevant.',
      hint = 'De to sier motsatte ting om det samme behovet. En akse er avgrenset, markert som ikke relevant, eller ikke undersøkt ennå.';
  end if;

  new.scope_digest :=
    'sha256:' || encode(
      pg_catalog.sha256(
        pg_catalog.convert_to(knowledge.monograph_scope_canonical(new)::text, 'UTF8')),
      'hex');

  return new;
end;
$$;

comment on function knowledge.set_monograph_scope_digest() is
  'Regner avgrensningsavtrykket av behovets egne kolonner, og kontrollerer samtidig at svarformen er en malen har, at etikettnøklene er gyldige akser, at katalogpekerne peker på riktig slags begrep, og at ingen akse er både avgrenset og markert som ikke relevant. Avtrykket er databasens: en verdi en kaller kunne oppgi, ville latt to forskjellige avgrensninger kollidere, eller det samme behovet bli opprettet to ganger under to avtrykk.';

revoke execute on function knowledge.set_monograph_scope_digest() from public;

create trigger monograph_needs_set_scope_digest
  before insert or update on knowledge.monograph_needs
  for each row execute function knowledge.set_monograph_scope_digest();

-- Avgrensningen og malen er behovets identitet, og de er uforanderlige. Det er
-- tilstandene som endrer seg.
create function knowledge.freeze_monograph_need_identity()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.reference is distinct from old.reference
     or new.edition_id is distinct from old.edition_id
     or new.template_id is distinct from old.template_id
     or new.answer_form is distinct from old.answer_form
     or new.indication_concept_id is distinct from old.indication_concept_id
     or new.outcome_concept_id is distinct from old.outcome_concept_id
     or new.population_id is distinct from old.population_id
     or new.comparator_drug_id is distinct from old.comparator_drug_id
     or new.switch_target_drug_id is distinct from old.switch_target_drug_id
     or new.scope_labels is distinct from old.scope_labels
     or new.scope_not_applicable is distinct from old.scope_not_applicable
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Et kunnskapsbehovs mal og avgrensning er uforanderlig.',
      hint = 'Malen og avgrensningen er det behovet er. En endret avgrensning er et annet behov, og en omskriving ville flyttet et kontrollert svar til et spørsmål det aldri ble kontrollert for (MONOGRAPH_STANDARD.md §9).';
  end if;
  return new;
end;
$$;

comment on function knowledge.freeze_monograph_need_identity() is
  'Holder behovets mal, svarform og avgrensning uforanderlig. Tilstandene — relevans, arbeidstilstand og utfall — endres; identiteten gjør det ikke.';

revoke execute on function knowledge.freeze_monograph_need_identity() from public;

create trigger monograph_needs_identity_is_frozen
  before update on knowledge.monograph_needs
  for each row execute function knowledge.freeze_monograph_need_identity();

-- ----------------------------------------------------------------------------
-- 5. Sporet over behovets tilstander
--
-- Tilstanden endres; overgangene gjør det ikke. «Hva skjedde med dette
-- behovet» skal kunne besvares også etter at behovet har fått en ny tilstand —
-- samme form som `workflow.pipeline_job_events` (migrasjon 009b).
-- ----------------------------------------------------------------------------

create table workflow.monograph_need_events (
  id uuid primary key default gen_random_uuid(),

  need_id uuid not null
    references knowledge.monograph_needs (id) on update restrict on delete restrict,

  from_relevance knowledge.monograph_relevance,
  to_relevance knowledge.monograph_relevance not null,
  from_work_state knowledge.monograph_work_state,
  to_work_state knowledge.monograph_work_state not null,
  from_outcome knowledge.monograph_outcome,
  to_outcome knowledge.monograph_outcome,

  note text not null,

  -- Hvem som utløste overgangen. Enten et menneske eller en agentkjøring; aldri
  -- begge, og aldri ingen — samme regel som pipeline_job_events.
  actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,

  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint monograph_need_events_single_origin_check
    check (num_nonnulls(actor_id, agent_run_id) = 1),
  constraint monograph_need_events_note_shape_check
    check (note = btrim(note) and length(note) between 1 and 2000)
);

comment on table workflow.monograph_need_events is
  'Append-only sporet over hver tilstandsovergang for ett kunnskapsbehov: relevans, arbeidstilstand og faglig utfall, med hvem eller hvilken agentkjøring som utløste den. Finnes fordi tilstanden endres og historikken ikke skal gjøre det: «hvorfor står dette behovet som avventer tilgang» er et spørsmål som må kunne besvares etter at behovet har fått en ny tilstand.';

alter table workflow.monograph_need_events enable row level security;

create index monograph_need_events_need_idx
  on workflow.monograph_need_events (need_id, occurred_at);

create trigger monograph_need_events_set_created_at
  before insert or update on workflow.monograph_need_events
  for each row execute function catalog.set_created_at();

-- Append-only-vernet er den generiske funksjonen fra migrasjon 004, og ikke en
-- ny kopi av den samme regelen. Konvensjonsvakten i
-- supabase/tests/180_workflow_structure_test.sql krever nettopp den: en egen
-- kopi ville vært en regel som kunne drive fra de andre.
create trigger monograph_need_events_are_append_only
  before update or delete on workflow.monograph_need_events
  for each row execute function knowledge.reject_append_only_mutation();

create function workflow.record_monograph_need_event(
  p_need_id uuid,
  p_from knowledge.monograph_needs,
  p_note text,
  p_actor_id uuid,
  p_agent_run_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_to knowledge.monograph_needs;
  v_id uuid;
begin
  select n.* into v_to from knowledge.monograph_needs n where n.id = p_need_id;
  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kunnskapsbehovet finnes ikke.';
  end if;

  insert into workflow.monograph_need_events (
    need_id,
    from_relevance, to_relevance,
    from_work_state, to_work_state,
    from_outcome, to_outcome,
    note, actor_id, agent_run_id
  )
  values (
    p_need_id,
    p_from.relevance, v_to.relevance,
    p_from.work_state, v_to.work_state,
    p_from.outcome, v_to.outcome,
    p_note, p_actor_id, p_agent_run_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

comment on function workflow.record_monograph_need_event(uuid, knowledge.monograph_needs, text, uuid, uuid) is
  'Skriver én rad i sporet over et kunnskapsbehov, med tilstanden før og etter. Leser tilstanden etter fra raden selv framfor å få den oppgitt: et spor som hvilte på hva kalleren mente det hadde skrevet, kunne sagt noe annet enn det som står i tabellen. Kalles fra innsiden av en skrivevei som allerede har fastslått opphavet, og er derfor ikke SECURITY DEFINER.';

revoke execute on function workflow.record_monograph_need_event(uuid, knowledge.monograph_needs, text, uuid, uuid) from public;

create function audit.record_monograph_need_relevance_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  -- Bare relevansavgjørelsen er et auditobjekt. Arbeidstilstanden og utfallet
  -- er arbeidets egen tilstand og har sitt append-only spor; relevansen er en
  -- faglig avgjørelse om hva Antidep skal undersøke, og den kan ta et spørsmål
  -- ut av nevneren (MONOGRAPH_STANDARD.md §5.1).
  if new.relevance is not distinct from old.relevance then
    return null;
  end if;

  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, reason, occurred_at
  )
  values (
    'monograph_need_relevance_decided'::audit.event_operation,
    new.id,
    coalesce(new.relevance_decided_by_actor_id, old.relevance_decided_by_actor_id,
             (select e.ordered_by_actor_id from knowledge.monograph_editions e
              where e.id = new.edition_id)),
    to_jsonb(old),
    to_jsonb(new),
    new.relevance_reason,
    now()
  );
  return null;
end;
$$;

comment on function audit.record_monograph_need_relevance_event() is
  'Auditskriver over relevansavgjørelser på kunnskapsbehov. Bare relevansen føres: arbeidstilstanden og utfallet er arbeidets egen tilstand med sitt eget append-only spor, mens relevansen er den ene avgjørelsen som kan ta et spørsmål ut av nevneren, og den skal kunne leses tilbake til den som tok den (MONOGRAPH_STANDARD.md §5.1).';

revoke execute on function audit.record_monograph_need_relevance_event() from public;

create trigger monograph_needs_record_relevance_audit_event
  after update on knowledge.monograph_needs
  for each row execute function audit.record_monograph_need_relevance_event();

-- ----------------------------------------------------------------------------
-- 6. Veien inn for et nytt fagbegrep
--
-- Katalogen er liten med vilje, og en monografi trenger flere indikasjoner,
-- utfall og populasjoner enn den har. To løsninger er utelukket: å kreve at en
-- redaktør fyller katalogen først, ville flyttet litteraturarbeidets
-- arbeidsledelse tilbake til klinikeren (MONOGRAPH_PLAN.md §2), og å la
-- ekstraksjonsagenten skrive i katalogen ville latt den som skal finne et svar,
-- endre sitt eget mandat for å få funnet godkjent (MONOGRAPH_STANDARD.md §4).
--
-- Forslaget er veien imellom, og aksepten er en egen handling med et annet
-- opphav: et menneske med redaktørmandat, eller en kjøring i et *annet*
-- agentledd enn det som foreslo. Ingen agent kan akseptere sitt eget forslag.
-- ----------------------------------------------------------------------------

create type workflow.monograph_term_state as enum ('open', 'accepted', 'declined');

revoke usage on type workflow.monograph_term_state from public;

comment on type workflow.monograph_term_state is
  'Hvor et forslag om et nytt fagbegrep eller en ny avgrensningsverdi står: open (foreslått, ikke tatt i bruk), accepted (tatt i bruk, og dermed noe dekningskartet utvides av) eller declined (avvist, med en begrunnelse). Et åpent forslag utvider ingenting: et begrep ingen har tatt stilling til, skal ikke kunne opprette behov eller flytte en avgrensning.';

create table workflow.monograph_term_proposals (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  edition_id uuid not null
    references knowledge.monograph_editions (id) on update restrict on delete restrict,
  axis knowledge.monograph_scope_axis not null,
  label text not null,

  -- Katalograden verdien peker på, når aksen er en katalogen har identitet for.
  concept_id uuid
    references catalog.clinical_concepts (id) on update restrict on delete restrict,
  population_id uuid
    references catalog.populations (id) on update restrict on delete restrict,
  drug_id uuid
    references catalog.drugs (id) on update restrict on delete restrict,

  -- Grunnlaget. En verdi uten et dokumentert grunnlag er en påstand, og en
  -- påstand skal ikke kunne utvide dekningskartet.
  rationale text not null,
  source_version_id uuid
    references knowledge.source_versions (id) on update restrict on delete restrict,
  source_quote text,

  proposed_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  proposed_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  proposed_from_need_id uuid
    references knowledge.monograph_needs (id) on update restrict on delete restrict,

  state workflow.monograph_term_state not null default 'open',
  decided_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  decided_by_agent_run_id uuid
    references provenance.agent_runs (id) on update restrict on delete restrict,
  decided_at timestamptz,
  decision_note text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint monograph_term_proposals_reference_key unique (reference),
  constraint monograph_term_proposals_identity_key unique (edition_id, axis, label),
  constraint monograph_term_proposals_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$'),
  constraint monograph_term_proposals_label_shape_check
    check (label = btrim(label) and length(label) between 1 and 300),
  constraint monograph_term_proposals_rationale_shape_check
    check (rationale = btrim(rationale) and length(rationale) between 1 and 2000),
  constraint monograph_term_proposals_quote_shape_check
    check (source_quote is null
           or (source_quote = btrim(source_quote) and length(source_quote) between 1 and 2000)),
  constraint monograph_term_proposals_decision_note_shape_check
    check (decision_note is null
           or (decision_note = btrim(decision_note)
               and length(decision_note) between 1 and 2000)),
  -- Høyst én katalogpeker: en verdi som pekte på både et begrep og en
  -- populasjon, ville vært to verdier.
  constraint monograph_term_proposals_single_catalog_ref_check
    check (num_nonnulls(concept_id, population_id, drug_id) <= 1),
  -- Et ordrett utdrag hører til en kildeversjon. Et utdrag uten kilde ville
  -- vært en tekst ingen kan kontrollere mot noe.
  constraint monograph_term_proposals_quote_needs_source_check
    check (source_quote is null or source_version_id is not null),
  -- En avgjørelse har ett opphav, en tid og — for en avvisning — en grunn.
  constraint monograph_term_proposals_decision_shape_check
    check (
      case state
        when 'open' then
          decided_at is null and decided_by_actor_id is null
          and decided_by_agent_run_id is null and decision_note is null
        when 'accepted' then
          decided_at is not null
          and num_nonnulls(decided_by_actor_id, decided_by_agent_run_id) = 1
        when 'declined' then
          decided_at is not null and decision_note is not null
          and num_nonnulls(decided_by_actor_id, decided_by_agent_run_id) = 1
        else false
      end
    )
);

comment on table workflow.monograph_term_proposals is
  'Ett forslag om en ny avgrensningsverdi eller et nytt fagbegrep i én monografiutgave, med grunnlaget det hviler på. Finnes fordi utvidelsen må ha en kontrollert vei inn: en ekstraksjonsagent kan foreslå, men kan ikke endre sitt eget mandat for å få et funn godkjent (MONOGRAPH_STANDARD.md §4). Aksepten er en egen handling med et annet opphav — et menneske med redaktørmandat, eller en kjøring i et annet agentledd enn det som foreslo — og bare et akseptert forslag utvider dekningskartet.';
comment on column workflow.monograph_term_proposals.rationale is
  'Hvorfor verdien er relevant for denne monografien, med kildeversjonen og det ordrette utdraget ved siden av når forslaget hviler på et dokument. En verdi uten et dokumentert grunnlag er en påstand, og en påstand skal ikke kunne utvide dekningskartet.';

alter table workflow.monograph_term_proposals enable row level security;

create index monograph_term_proposals_edition_idx
  on workflow.monograph_term_proposals (edition_id, axis, state);

create trigger monograph_term_proposals_set_row_timestamps
  before insert or update on workflow.monograph_term_proposals
  for each row execute function catalog.set_row_timestamps();

create function workflow.freeze_monograph_term_proposal()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.reference is distinct from old.reference
     or new.edition_id is distinct from old.edition_id
     or new.axis is distinct from old.axis
     or new.label is distinct from old.label
     or new.rationale is distinct from old.rationale
     or new.source_version_id is distinct from old.source_version_id
     or new.source_quote is distinct from old.source_quote
     or new.proposed_by_actor_id is distinct from old.proposed_by_actor_id
     or new.proposed_by_agent_run_id is distinct from old.proposed_by_agent_run_id
     or new.proposed_from_need_id is distinct from old.proposed_from_need_id
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Et forslag om et fagbegrep er uforanderlig bortsett fra at det kan avgjøres.',
      hint = 'Forslaget og grunnlaget det hviler på, er det som ble lagt fram. En omskriving ville latt et avgjort forslag bety noe annet enn det den som avgjorde det, tok stilling til.';
  end if;

  if old.state <> 'open' and new.state is distinct from old.state then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Et avgjort forslag kan ikke avgjøres på nytt.',
      hint = 'Avgjørelsen er selv et historisk faktum. Skal verdien vurderes igjen, er det et nytt forslag.';
  end if;

  return new;
end;
$$;

comment on function workflow.freeze_monograph_term_proposal() is
  'Holder forslaget og grunnlaget det hviler på uforanderlig, og lar det bare avgjøres én gang.';

revoke execute on function workflow.freeze_monograph_term_proposal() from public;

create trigger monograph_term_proposals_are_frozen
  before update on workflow.monograph_term_proposals
  for each row execute function workflow.freeze_monograph_term_proposal();

create function audit.record_monograph_term_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.state <> 'accepted' or old.state = 'accepted' then
    return null;
  end if;

  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, reason,
    request_or_run_id, occurred_at
  )
  values (
    'monograph_term_accepted'::audit.event_operation,
    new.id,
    coalesce(new.decided_by_actor_id,
             (select r.actor_id from provenance.agent_runs r
              where r.id = new.decided_by_agent_run_id)),
    to_jsonb(old),
    to_jsonb(new),
    coalesce(new.decision_note, new.rationale),
    new.decided_by_agent_run_id,
    new.decided_at
  );
  return null;
end;
$$;

comment on function audit.record_monograph_term_event() is
  'Auditskriver over aksepterte fagbegreper. Å ta en ny indikasjon, et nytt utfall eller en ny populasjon i bruk utvider hva Antidep sier noe om, og det skal kunne leses tilbake til den som gjorde det. Et avvist forslag er ikke et auditobjekt: det endret ingenting.';

revoke execute on function audit.record_monograph_term_event() from public;

create trigger monograph_term_proposals_record_audit_event
  after update on workflow.monograph_term_proposals
  for each row execute function audit.record_monograph_term_event();

-- ----------------------------------------------------------------------------
-- 7. Utvidelsen av dekningskartet
--
-- Én funksjon, deterministisk og idempotent: gitt standardregisteret, utgaven
-- og de aksepterte verdiene, er behovslisten alltid den samme. Den kan derfor
-- kjøres om igjen etter et avbrudd, etter at en ny verdi er akseptert, og etter
-- at et funn har aktivert en betinget mal — uten å doble noe.
--
-- Utvidelsen tar ingen faglig avgjørelse. Den oppretter spørsmålene; hva svaret
-- blir, og om behovet i det hele tatt er relevant, avgjøres et annet sted.
-- ----------------------------------------------------------------------------

create function knowledge.monograph_relevance_for_requirement(
  p_requirement knowledge.monograph_requirement_type
)
  returns knowledge.monograph_relevance
  language sql
  immutable
  set search_path = ''
as $$
  select case p_requirement
    -- Obligatorisk å undersøke: relevansen er standardens egen avgjørelse.
    when 'mandatory' then 'relevant'::knowledge.monograph_relevance
    -- Betinget: betingelsen er ikke avgjort ennå. En ukjent betingelse er ikke
    -- en usann betingelse, og skal derfor ikke bli «ikke relevant»
    -- (MONOGRAPH_STANDARD.md §3, §5.1).
    when 'conditional' then 'undetermined'::knowledge.monograph_relevance
    -- Avledet presentasjon: den skal bygges når grunnlaget finnes, så den er
    -- relevant. At den ikke kan bygges ennå, er en arbeidstilstand.
    when 'derived' then 'relevant'::knowledge.monograph_relevance
  end;
$$;

comment on function knowledge.monograph_relevance_for_requirement(knowledge.monograph_requirement_type) is
  'Relevansen et nyopprettet behov får av malens kravtype: obligatorisk blir relevant, betinget blir undetermined fordi betingelsen ikke er avgjort, og avledet blir relevant fordi den skal bygges når grunnlaget finnes. En betinget mal blir aldri not_applicable av seg selv: en ukjent betingelse er ikke en usann betingelse (MONOGRAPH_STANDARD.md §3, §5.1).';

revoke execute on function knowledge.monograph_relevance_for_requirement(knowledge.monograph_requirement_type) from public;

create function knowledge.ensure_monograph_need(
  p_edition_id uuid,
  p_template_id uuid,
  p_answer_form knowledge.monograph_answer_form,
  p_axis knowledge.monograph_scope_axis,
  p_label text,
  p_concept_id uuid,
  p_population_id uuid,
  p_drug_id uuid,
  p_relevance knowledge.monograph_relevance,
  p_activated_by_need_id uuid,
  p_activation_reason text
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_labels jsonb := '{}'::jsonb;
  v_indication uuid;
  v_outcome uuid;
  v_population uuid;
  v_comparator uuid;
  v_switch_target uuid;
  v_id uuid;
begin
  -- Aksen avgjør hvilken kolonne verdien havner i. Katalogaksene får en ekte
  -- fremmednøkkel, fordi det er dem den eksisterende evidenskjeden bygger
  -- ekstraksjonsoppdraget og syntesen av; resten får en etikett.
  if p_axis is not null then
    if p_axis = 'indication' then
      v_indication := p_concept_id;
    elsif p_axis = 'outcome' then
      v_outcome := p_concept_id;
    elsif p_axis = 'population' then
      v_population := p_population_id;
    elsif p_axis = 'comparator' then
      v_comparator := p_drug_id;
    elsif p_axis = 'switch_target' then
      v_switch_target := p_drug_id;
    end if;

    -- Etiketten står med også for en katalogakse: oppgaven og flaten skal
    -- kunne lese avgrensningen uten et oppslag, og avtrykket dekker begge.
    if p_label is not null then
      v_labels := jsonb_build_object(p_axis::text, p_label);
    end if;

    -- En katalogakse uten en katalograd er ikke en avgrensning Antidep kan
    -- bygge et oppdrag av. Den skal bli et forslag, ikke et behov med et hull.
    if p_axis in ('indication', 'outcome', 'population', 'comparator', 'switch_target')
       and num_nonnulls(v_indication, v_outcome, v_population, v_comparator, v_switch_target) = 0 then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Avgrensningsaksen %L krever en katalograd, og forslaget har ingen.', p_axis),
        hint = 'Indikasjon, endepunkt, populasjon, komparator og bytteretning er de aksene den eksisterende evidenskjeden bygger oppdraget av. En etikett uten en katalograd ville gitt et behov ingen ekstraksjon kunne avgrenses til.';
    end if;

    -- Etiketten fjernes for en katalogakse: katalogpekeren *er* verdien, og en
    -- etikett ved siden av ville kunnet drive fra katalogens eget navn og gjort
    -- det samme behovet til to avtrykk.
    if p_axis in ('indication', 'outcome', 'population', 'comparator', 'switch_target') then
      v_labels := '{}'::jsonb;
    end if;
  end if;

  insert into knowledge.monograph_needs (
    edition_id, template_id, answer_form,
    indication_concept_id, outcome_concept_id, population_id,
    comparator_drug_id, switch_target_drug_id,
    scope_labels, relevance, activated_by_need_id, activation_reason,
    -- scope_digest settes av triggeren; verdien her er bare en plassholder som
    -- tilfredsstiller NOT NULL før BEFORE-triggeren regner den ekte.
    scope_digest
  )
  values (
    p_edition_id, p_template_id, p_answer_form,
    v_indication, v_outcome, v_population, v_comparator, v_switch_target,
    v_labels, p_relevance, p_activated_by_need_id, p_activation_reason,
    'sha256:' || repeat('0', 64)
  )
  on conflict (edition_id, template_id, answer_form, scope_digest) do nothing
  returning id into v_id;

  if v_id is null then
    -- Behovet fantes fra før. Det er det normale utfallet av en gjentatt
    -- utvidelse, og ingen feil: utvidelsen er idempotent med vilje.
    select n.id into v_id
    from knowledge.monograph_needs n
    where n.edition_id = p_edition_id
      and n.template_id = p_template_id
      and n.answer_form = p_answer_form
      and n.indication_concept_id is not distinct from v_indication
      and n.outcome_concept_id is not distinct from v_outcome
      and n.population_id is not distinct from v_population
      and n.comparator_drug_id is not distinct from v_comparator
      and n.switch_target_drug_id is not distinct from v_switch_target
      and n.scope_labels = v_labels;
    return v_id;
  end if;

  perform workflow.record_monograph_need_event(
    v_id, null::knowledge.monograph_needs,
    p_activation_reason,
    (select e.ordered_by_actor_id from knowledge.monograph_editions e where e.id = p_edition_id),
    null);

  return v_id;
end;
$$;

comment on function knowledge.ensure_monograph_need(uuid, uuid, knowledge.monograph_answer_form, knowledge.monograph_scope_axis, text, uuid, uuid, uuid, knowledge.monograph_relevance, uuid, text) is
  'Oppretter ett kunnskapsbehov, eller svarer med det som allerede finnes. Idempotent på behovets identitet — utgave, mal, svarform og avgrensningsavtrykk — slik at en utvidelse kan gjentas etter et avbrudd uten å doble noe. En katalogakse uten en katalograd avvises: indikasjon, endepunkt, populasjon, komparator og bytteretning er de aksene evidenskjeden bygger oppdraget av, og en etikett uten en rad ville gitt et behov ingen ekstraksjon kunne avgrenses til. Kalles fra innsiden av en skrivevei som allerede har fastslått opphavet, og er derfor ikke SECURITY DEFINER.';

revoke execute on function knowledge.ensure_monograph_need(uuid, uuid, knowledge.monograph_answer_form, knowledge.monograph_scope_axis, text, uuid, uuid, uuid, knowledge.monograph_relevance, uuid, text) from public;

create function knowledge.expand_monograph_edition(p_edition_id uuid)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_edition knowledge.monograph_editions;
  v_before integer;
  v_after integer;
  v_template knowledge.monograph_question_templates;
  v_form knowledge.monograph_answer_form;
  v_prescribed knowledge.monograph_prescribed_scope_values;
  v_proposal workflow.monograph_term_proposals;
  v_primary knowledge.monograph_scope_axis;
  v_root_id uuid;
  v_relevance knowledge.monograph_relevance;
begin
  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.id = p_edition_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Monografiutgaven finnes ikke.';
  end if;

  if v_edition.superseded_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En avløst monografiutgave utvides ikke.',
      hint = 'Utgaven er historikk, og den er det en godkjent monografi ble bygget av. Nye behov hører til den gjeldende utgaven.';
  end if;

  select count(*) into v_before
  from knowledge.monograph_needs n where n.edition_id = p_edition_id;

  for v_template in
    select t.* from knowledge.monograph_question_templates t
    where t.standard_version = v_edition.standard_version
    order by t.ordinal
  loop
    v_relevance := knowledge.monograph_relevance_for_requirement(v_template.requirement);

    if exists (
      select 1 from knowledge.monograph_prescribed_scope_values v
      where v.template_id = v_template.id
    ) then
      -- Standarden skriver ut listen selv. Da er det ett behov per verdi, og
      -- ingen rot: «ett behov per risikoområde» er malens eget krav, og et
      -- rotbehov ved siden av ville vært et spørsmål uten en avgrensning
      -- (MONOGRAPH_STANDARD.md §3.6).
      foreach v_form in array v_template.answer_forms loop
        for v_prescribed in
          select v.* from knowledge.monograph_prescribed_scope_values v
          where v.template_id = v_template.id
          order by v.ordinal
        loop
          perform knowledge.ensure_monograph_need(
            p_edition_id, v_template.id, v_form,
            v_prescribed.axis, v_prescribed.label,
            null, null, null,
            v_relevance, null,
            format('Standarden navngir %L som et obligatorisk screeningsspørsmål under %s.',
                   v_prescribed.label, v_template.code));
        end loop;
      end loop;
      continue;
    end if;

    foreach v_form in array v_template.answer_forms loop
      -- Rotbehovet: malen som sådan, uten en avgrensning på gjentakelsesaksen.
      v_root_id := knowledge.ensure_monograph_need(
        p_edition_id, v_template.id, v_form,
        null, null, null, null, null,
        v_relevance, null,
        format('%s er %L i monografistandard %s.',
               v_template.code, v_template.requirement_text, v_edition.standard_version));

      -- Og ett behov per akseptert verdi på malens primære gjentakelsesakse.
      -- Primæraksen og ikke kryssproduktet av alle aksene: et kryssprodukt av
      -- indikasjoner, populasjoner og formuleringer ville vokst uten grense, og
      -- standardens krav er at malen gjentas «per relevant bruk» — altså per
      -- dokumentert bruk. Videre forgreninger opprettes av dokumenterte funn
      -- gjennom knowledge.refine_monograph_need(...).
      if cardinality(v_template.expansion_axes) > 0 then
        v_primary := v_template.expansion_axes[1];
        for v_proposal in
          select p.* from workflow.monograph_term_proposals p
          where p.edition_id = p_edition_id
            and p.axis = v_primary
            and p.state = 'accepted'
          order by p.created_at, p.label
        loop
          perform knowledge.ensure_monograph_need(
            p_edition_id, v_template.id, v_form,
            v_primary, v_proposal.label,
            v_proposal.concept_id, v_proposal.population_id, v_proposal.drug_id,
            -- Betingelsen er nå oppfylt: verdien er dokumentert og akseptert.
            'relevant'::knowledge.monograph_relevance,
            v_root_id,
            format('Aktivert av den aksepterte verdien %L på aksen %s: %s',
                   v_proposal.label, v_primary, v_proposal.rationale));
        end loop;
      end if;
    end loop;
  end loop;

  select count(*) into v_after
  from knowledge.monograph_needs n where n.edition_id = p_edition_id;

  return v_after - v_before;
end;
$$;

comment on function knowledge.expand_monograph_edition(uuid) is
  'Utvider dekningskartet for én monografiutgave av standardregisteret og de aksepterte avgrensningsverdiene, og svarer med hvor mange behov som ble opprettet. Deterministisk og idempotent: gitt den samme standarden, utgaven og de samme aksepterte verdiene er behovslisten alltid den samme, så funksjonen kan kjøres om igjen etter et avbrudd, etter at en ny verdi er akseptert, og etter at et funn har aktivert en betinget mal — uten å doble noe. Maler standarden skriver ut en liste for, får ett behov per verdi og ingen rot; de øvrige får et rotbehov og ett behov per akseptert verdi på sin primære gjentakelsesakse. Tar ingen faglig avgjørelse: den oppretter spørsmålene, og hva svaret blir avgjøres et annet sted. Låser utgaven, slik at to samtidige utvidelser ikke kan opprette det samme behovet to ganger.';

revoke execute on function knowledge.expand_monograph_edition(uuid) from public;

-- ----------------------------------------------------------------------------
-- 8. Forgreningen et dokumentert funn utløser
--
-- Primæraksen dekker den vanlige utvidelsen: per indikasjon, per risikoområde,
-- per byttepar. Et dokumentert funn kan i tillegg kreve en finere avgrensning
-- under et behov som allerede finnes — en formulering, en behandlingsfase, en
-- dose. Den forgreningen opprettes her, av det behovet den forgrener, og med
-- funnets egen begrunnelse.
-- ----------------------------------------------------------------------------

create function knowledge.refine_monograph_need(
  p_parent_need_id uuid,
  p_axis knowledge.monograph_scope_axis,
  p_label text,
  p_concept_id uuid,
  p_population_id uuid,
  p_drug_id uuid,
  p_reason text
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_parent knowledge.monograph_needs;
  v_template knowledge.monograph_question_templates;
  v_labels jsonb;
  v_id uuid;
begin
  select n.* into v_parent
  from knowledge.monograph_needs n
  where n.id = p_parent_need_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Behovet som skal forgrenes, finnes ikke.';
  end if;

  select t.* into v_template
  from knowledge.monograph_question_templates t
  where t.id = v_parent.template_id;

  -- Aksen må være en malen faktisk gjentas på. Uten kravet kunne en forgrening
  -- gitt en avgrensning standarden ikke ber om, og et svar ingen kontrakt
  -- dekker.
  if not (p_axis = any (v_template.expansion_axes)) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Malen %s gjentas ikke på aksen %L.', v_template.code, p_axis),
      hint = format('Malens gjentakelsesakser er %s (MONOGRAPH_STANDARD.md §3).',
                    coalesce(nullif(array_to_string(v_template.expansion_axes::text[], ', '), ''),
                             'ingen'));
  end if;

  -- Og aksen kan ikke være den forelderen allerede er avgrenset på: det ville
  -- vært to verdier på den samme aksen i det samme behovet.
  if v_parent.scope_labels ? p_axis::text
     or (p_axis = 'indication' and v_parent.indication_concept_id is not null)
     or (p_axis = 'outcome' and v_parent.outcome_concept_id is not null)
     or (p_axis = 'population' and v_parent.population_id is not null)
     or (p_axis = 'comparator' and v_parent.comparator_drug_id is not null)
     or (p_axis = 'switch_target' and v_parent.switch_target_drug_id is not null) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Behovet er allerede avgrenset på aksen %L.', p_axis);
  end if;

  v_labels := v_parent.scope_labels;
  if p_axis not in ('indication', 'outcome', 'population', 'comparator', 'switch_target') then
    v_labels := v_labels || jsonb_build_object(p_axis::text, p_label);
  end if;

  insert into knowledge.monograph_needs (
    edition_id, template_id, answer_form,
    indication_concept_id, outcome_concept_id, population_id,
    comparator_drug_id, switch_target_drug_id,
    scope_labels, scope_not_applicable,
    relevance, activated_by_need_id, activation_reason, scope_digest
  )
  values (
    v_parent.edition_id, v_parent.template_id, v_parent.answer_form,
    case when p_axis = 'indication' then p_concept_id else v_parent.indication_concept_id end,
    case when p_axis = 'outcome' then p_concept_id else v_parent.outcome_concept_id end,
    case when p_axis = 'population' then p_population_id else v_parent.population_id end,
    case when p_axis = 'comparator' then p_drug_id else v_parent.comparator_drug_id end,
    case when p_axis = 'switch_target' then p_drug_id else v_parent.switch_target_drug_id end,
    v_labels,
    -- En akse som forgrenes, er per definisjon relevant, og skal ikke arves som
    -- «ikke relevant» fra forelderen.
    array_remove(v_parent.scope_not_applicable, p_axis),
    'relevant'::knowledge.monograph_relevance,
    v_parent.id,
    p_reason,
    'sha256:' || repeat('0', 64)
  )
  on conflict (edition_id, template_id, answer_form, scope_digest) do nothing
  returning id into v_id;

  if v_id is null then
    return null;
  end if;

  perform workflow.record_monograph_need_event(
    v_id, null::knowledge.monograph_needs, p_reason,
    (select e.ordered_by_actor_id from knowledge.monograph_editions e
     where e.id = v_parent.edition_id),
    null);

  return v_id;
end;
$$;

comment on function knowledge.refine_monograph_need(uuid, knowledge.monograph_scope_axis, text, uuid, uuid, uuid, text) is
  'Oppretter en finere avgrenset utgave av ett kunnskapsbehov, på en akse malen faktisk gjentas på, med det dokumenterte funnets egen begrunnelse. Finnes fordi utvidelsen per primærakse dekker den vanlige gjentakelsen, mens et funn kan kreve en formulering, en behandlingsfase eller en dose under et behov som allerede finnes (MONOGRAPH_STANDARD.md §4). Svarer NULL når den forgreningen allerede finnes. Arver ikke forelderens «ikke relevant» på aksen som forgrenes: en akse som forgrenes, er relevant.';

revoke execute on function knowledge.refine_monograph_need(uuid, knowledge.monograph_scope_axis, text, uuid, uuid, uuid, text) from public;

-- ----------------------------------------------------------------------------
-- 9. Den gjeldende standardversjonen
--
-- «Nyeste versjon som faktisk har maler» og ikke bare «nyeste versjon»: en
-- versjonsrad uten maler ville gitt en utgave med et tomt dekningskart, og det
-- ville sett ut som en monografi uten spørsmål.
-- ----------------------------------------------------------------------------

create function knowledge.current_monograph_standard_version()
  returns text
  language sql
  stable
  set search_path = ''
as $$
  select v.version
  from knowledge.monograph_standard_versions v
  where exists (
    select 1 from knowledge.monograph_question_templates t
    where t.standard_version = v.version
  )
  order by v.published_on desc,
           string_to_array(v.version, '.')::integer[] desc
  limit 1;
$$;

comment on function knowledge.current_monograph_standard_version() is
  'Den nyeste monografistandardversjonen som faktisk har spørsmålsmaler. Kravet om maler er ikke pynt: en versjonsrad uten dem ville gitt en utgave med et tomt dekningskart, og det ville sett ut som en monografi uten spørsmål framfor som en halvferdig migrering.';

revoke execute on function knowledge.current_monograph_standard_version() from public;

-- ----------------------------------------------------------------------------
-- 10. Bestillingen, slik en kliniker gjør den
--
-- Ett navn, og ingenting annet. Ingen standardversjon, ingen utgavenummer,
-- ingen mal-id-er og ingen liste over behov: alt utledes av rader som allerede
-- finnes (AGENTS.md).
--
-- Bestillingen er idempotent på virkestoffet. En redaktør som trykker to
-- ganger, og to redaktører som bestiller samtidig, får den samme utgaven — og
-- svaret sier hvilket av de to som skjedde, framfor å late som om den andre
-- opprettet noe.
-- ----------------------------------------------------------------------------

create function api.monograph_order_options()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform knowledge.assert_editor_authorized();

  return jsonb_build_object(
    'drugs', coalesce(
      (select jsonb_agg(d.canonical_name order by d.canonical_name)
       from catalog.drugs d
       where d.status = 'active'), '[]'::jsonb),
    'standard_version', knowledge.current_monograph_standard_version(),
    'question_templates', (
      select count(*)
      from knowledge.monograph_question_templates t
      where t.standard_version = knowledge.current_monograph_standard_version()));
end;
$$;

comment on function api.monograph_order_options() is
  'Virkestoffene en monografi kan bestilles for, som navn og ikke som id-er, sammen med den gjeldende standardversjonen og hvor mange spørsmål den stiller. Finnes for at bestillingsflaten skal kunne be om en faglig avgjørelse uten å vise én eneste teknisk verdi. Krever editor-mandat, som bestillingen selv. SECURITY DEFINER fordi catalog og knowledge har RLS med default deny.';

revoke execute on function api.monograph_order_options() from public;
grant execute on function api.monograph_order_options() to authenticated;

create function api.order_monograph(p_drug_name text, p_note text default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_drug_ids uuid[];
  v_drug_id uuid;
  v_version text;
  v_edition knowledge.monograph_editions;
  v_created boolean := false;
  v_needs integer := 0;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  v_drug_ids := workflow.catalog_ids_for_names('drug', array[p_drug_name]);
  v_drug_id := v_drug_ids[1];

  v_version := knowledge.current_monograph_standard_version();
  if v_version is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografistandard med spørsmålsmaler.',
      hint = 'Standardregisteret legges inn av en migrasjon. Uten det finnes ingen spørsmål å opprette behov av.';
  end if;

  -- Låsen først, og deretter spørsmålet. Uten den rekkefølgen kan to samtidige
  -- bestillinger på det samme virkestoffet begge lese «ingen utgave» og begge
  -- prøve å opprette en; den ene ville tapt på det unike indekset, med en
  -- SQLSTATE framfor med den utgaven som faktisk finnes. Låsen er på
  -- virkestoffet fordi det er der unikheten ligger.
  perform pg_advisory_xact_lock(
    hashtext('antidep.monograph_order'), hashtext(v_drug_id::text));

  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.drug_id = v_drug_id and e.superseded_at is null;

  if not found then
    insert into knowledge.monograph_editions
      (drug_id, standard_version, edition_no, ordered_by_actor_id, order_note)
    values (
      v_drug_id,
      v_version,
      coalesce(
        (select max(e.edition_no) + 1 from knowledge.monograph_editions e
         where e.drug_id = v_drug_id),
        1),
      v_actor_id,
      p_note)
    returning * into v_edition;
    v_created := true;
  end if;

  -- Utvidelsen kjøres uansett. En bestilling som fantes fra før, kan ha fått
  -- nye aksepterte verdier siden sist, og en utgave som ble avbrutt midt i
  -- utvidelsen, skal kunne bli komplett uten at noen bestiller på nytt.
  v_needs := knowledge.expand_monograph_edition(v_edition.id);

  return jsonb_build_object(
    'reference', v_edition.reference,
    'drug', p_drug_name,
    'standard_version', v_edition.standard_version,
    'edition_no', v_edition.edition_no,
    'ordered', v_created,
    'already_ordered', not v_created,
    'ordered_at', v_edition.ordered_at,
    'needs_created', v_needs,
    'needs_total', (select count(*) from knowledge.monograph_needs n
                    where n.edition_id = v_edition.id));
end;
$$;

comment on function api.order_monograph(text, text) is
  'Bestillingen: «bygg monografi for dette virkestoffet». Tar ett virkestoffnavn og en valgfri merknad, og oppretter en versjonert monografiutgave med de konkrete kunnskapsbehovene av standardregisteret — ingen standardversjon, ingen utgavenummer, ingen mal-id-er og ingen behovsliste oppgis (AGENTS.md). Idempotent på virkestoffet: en redaktør som trykker to ganger, og to redaktører som bestiller samtidig, får den samme utgaven, og svaret sier hvilket av de to som skjedde. Utvidelsen kjøres uansett, slik at en utgave som har fått nye aksepterte verdier — eller som ble avbrutt midt i utvidelsen — blir komplett uten en ny bestilling. Krever editor-mandat: å avgjøre at Antidep skal si noe om et virkestoff, er en redaksjonell avgjørelse. SECURITY DEFINER fordi catalog, knowledge og workflow har RLS med default deny.';

revoke execute on function api.order_monograph(text, text) from public;
grant execute on function api.order_monograph(text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 11. Dekningen, og hvorfor den ikke er ett tall
--
-- Standardens §5.4 krever at relevans, arbeidstilstand, faglig utfall,
-- evidenssikkerhet, aktualitet og kontrollstatus holdes atskilt, og at en
-- eventuell prosent bygger på den lagrede behovslisten for utgaven. Den
-- viktigste regelen står i samme avsnitt: **arbeidsdekning og evidenssikkerhet
-- skal aldri være samme indikator.**
--
-- Derfor svarer denne funksjonen med tellinger og ikke med en poengsum, og
-- derfor er nevneren *alle* behov i utgaven. Å fjerne de vanskelige spørsmålene
-- fra nevneren ville gitt en pen ferdigprosent og en usann monografi.
--
-- Evidenssikkerheten står ikke her i det hele tatt: den hører til det enkelte
-- svaret og til det kontrollerte grunnlaget bak det, og en samlet
-- «sikkerhetsprosent» for en monografi ville vært nettopp den sammenblandingen
-- standarden forbyr.
-- ----------------------------------------------------------------------------

create function knowledge.monograph_coverage_payload(p_edition knowledge.monograph_editions)
  returns jsonb
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_counts record;
  v_sections jsonb;
  v_drug text;
begin
  select d.canonical_name into v_drug
  from catalog.drugs d where d.id = p_edition.drug_id;

  select
    count(*)::integer as total,
    count(*) filter (where n.relevance = 'relevant')::integer as relevant,
    count(*) filter (where n.relevance = 'not_applicable')::integer as not_applicable,
    count(*) filter (where n.relevance = 'undetermined')::integer as undetermined,
    -- Besvart: det finnes et kontrollert svar innen en eksplisitt avgrensning.
    count(*) filter (where n.outcome = 'answered')::integer as answered,
    -- Gjennomgåtte kunnskapshull og motstrider. Dette er faglige utfall etter
    -- utført arbeid, og de er noe annet enn åpne behov: et dokumentert søk uten
    -- kvalifiserende funn er et resultat, ikke et hull i arbeidet.
    count(*) filter (where n.outcome = 'no_qualifying_evidence')::integer
      as no_qualifying_evidence,
    count(*) filter (where n.outcome = 'insufficient_evidence')::integer
      as insufficient_evidence,
    count(*) filter (where n.outcome = 'conflicting_evidence')::integer
      as conflicting_evidence,
    count(*) filter (where n.outcome = 'not_applicable')::integer
      as concluded_not_applicable,
    -- Fortsatt åpne: relevante behov som ikke er ferdig behandlet.
    count(*) filter (where n.relevance = 'relevant' and n.work_state <> 'agent_complete')::integer
      as open_relevant,
    -- Og de tilstandene som aldri skal bli et faglig utfall.
    count(*) filter (where n.work_state = 'awaiting_access')::integer as awaiting_access,
    count(*) filter (where n.work_state = 'technical_stop')::integer as technical_stop,
    count(*) filter (where n.work_state = 'awaiting_clarification')::integer
      as awaiting_clarification,
    count(*) filter (where n.work_state = 'not_started')::integer as not_started,
    count(*) filter (where n.work_state = 'searching')::integer as searching,
    count(*) filter (where n.work_state = 'appraising_sources')::integer as appraising_sources,
    count(*) filter (where n.work_state = 'extracting')::integer as extracting,
    count(*) filter (where n.work_state = 'agent_complete')::integer as agent_complete
  into v_counts
  from knowledge.monograph_needs n
  where n.edition_id = p_edition.id;

  select coalesce(jsonb_agg(s order by s.ordinal), '[]'::jsonb) into v_sections
  from (
    select
      min(t.ordinal) as ordinal,
      t.section,
      count(*)::integer as total,
      count(*) filter (where n.outcome = 'answered')::integer as answered,
      count(*) filter (where n.outcome in ('no_qualifying_evidence', 'insufficient_evidence',
                                           'conflicting_evidence'))::integer as reviewed_gaps,
      count(*) filter (where n.relevance = 'not_applicable')::integer as not_applicable,
      count(*) filter (where n.relevance = 'undetermined')::integer as undetermined,
      count(*) filter (where n.relevance = 'relevant'
                         and n.work_state <> 'agent_complete')::integer as open_relevant
    from knowledge.monograph_needs n
    join knowledge.monograph_question_templates t on t.id = n.template_id
    where n.edition_id = p_edition.id
    group by t.section
  ) s;

  return jsonb_build_object(
    'edition', jsonb_build_object(
      'reference', p_edition.reference,
      'drug', v_drug,
      'standard_version', p_edition.standard_version,
      'edition_no', p_edition.edition_no,
      'ordered_at', p_edition.ordered_at,
      'superseded', p_edition.superseded_at is not null),
    'needs', jsonb_build_object(
      'total', v_counts.total,
      -- Relevans er sin egen dimensjon.
      'relevant', v_counts.relevant,
      'justified_not_applicable', v_counts.not_applicable,
      'undetermined_relevance', v_counts.undetermined,
      -- Faglig utfall er sin egen.
      'answered', v_counts.answered,
      'reviewed_gaps', v_counts.no_qualifying_evidence
                       + v_counts.insufficient_evidence
                       + v_counts.conflicting_evidence,
      'no_qualifying_evidence', v_counts.no_qualifying_evidence,
      'insufficient_evidence', v_counts.insufficient_evidence,
      'conflicting_evidence', v_counts.conflicting_evidence,
      'open', v_counts.open_relevant),
    -- Og arbeidstilstanden er sin egen, med de tre blokkeringene som aldri
    -- skal bli «utilstrekkelig evidens» eller «ingen relevante studier»
    -- (ANTIDEP_CONSTITUTION.md regel 4).
    'work_states', jsonb_build_object(
      'not_started', v_counts.not_started,
      'searching', v_counts.searching,
      'appraising_sources', v_counts.appraising_sources,
      'awaiting_access', v_counts.awaiting_access,
      'extracting', v_counts.extracting,
      'awaiting_clarification', v_counts.awaiting_clarification,
      'technical_stop', v_counts.technical_stop,
      'agent_complete', v_counts.agent_complete),
    'blocked', jsonb_build_object(
      'awaiting_access', v_counts.awaiting_access,
      'awaiting_clarification', v_counts.awaiting_clarification,
      'technical_stop', v_counts.technical_stop),
    -- Arbeidsdekningen, og bare den: hvor stor del av den lagrede behovslisten
    -- som er ferdig behandlet. Ikke en evidenssikkerhet, og ikke en faglig
    -- ferdigprosent (MONOGRAPH_STANDARD.md §5.4).
    'work_coverage', jsonb_build_object(
      'handled', v_counts.agent_complete,
      'denominator', v_counts.total,
      'percent', case when v_counts.total = 0 then null
                      else round(100.0 * v_counts.agent_complete / v_counts.total) end),
    -- Fullføringsnivået etter standardens §5.4. `published` settes av
    -- publiseringslaget; her skilles dekningskartet fra den agentferdige
    -- utgaven, og «delvis» er sant så snart noe gjenstår.
    'completion', jsonb_build_object(
      'level', case
        when v_counts.total = 0 then 'no_coverage_map'
        when v_counts.open_relevant = 0 and v_counts.undetermined = 0 then 'agent_complete'
        else 'coverage_map' end,
      'partial', v_counts.open_relevant > 0 or v_counts.undetermined > 0),
    'sections', v_sections);
end;
$$;

comment on function knowledge.monograph_coverage_payload(knowledge.monograph_editions) is
  'Dekningsoversikten for én monografiutgave, regnet av den lagrede behovslisten. Relevans, faglig utfall, arbeidstilstand og blokkeringer er fire atskilte dimensjoner, og arbeidsdekningen er merket som nettopp det: evidenssikkerhet står ikke her i det hele tatt, fordi en samlet sikkerhetsprosent for en monografi ville vært den sammenblandingen MONOGRAPH_STANDARD.md §5.4 forbyr. Nevneren er alle behov i utgaven — å fjerne de vanskelige spørsmålene fra den ville gitt en pen ferdigprosent og en usann monografi.';

revoke execute on function knowledge.monograph_coverage_payload(knowledge.monograph_editions) from public;

create function api.monograph_coverage(p_reference text)
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
  from knowledge.monograph_editions e
  where e.reference = p_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografiutgave med denne referansen.';
  end if;

  return knowledge.monograph_coverage_payload(v_edition);
end;
$$;

comment on function api.monograph_coverage(text) is
  'Dekningsoversikten for én monografiutgave, slått opp på det ugjennomsiktige håndtaket flaten viser. Krever editor-mandat: et dekningskart er internt arbeidsmateriale, og et internt utkast er tilgangsbegrenset (ANTIDEP_CONSTITUTION.md regel 5). SECURITY DEFINER fordi knowledge har RLS med default deny.';

revoke execute on function api.monograph_coverage(text) from public;
grant execute on function api.monograph_coverage(text) to authenticated;

create function api.monograph_orders()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_rows jsonb;
begin
  perform knowledge.assert_editor_authorized();

  select coalesce(jsonb_agg(x.payload order by x.ordered_at desc), '[]'::jsonb) into v_rows
  from (
    select e.ordered_at, knowledge.monograph_coverage_payload(e) as payload
    from knowledge.monograph_editions e
  ) x;

  return v_rows;
end;
$$;

comment on function api.monograph_orders() is
  'Alle monografiutgaver med sin dekningsoversikt, nyeste bestilling først. Krever editor-mandat. Avløste utgaver står med: en utgave som er avløst, er det en godkjent monografi ble bygget av, og den skal kunne leses.';

revoke execute on function api.monograph_orders() from public;
grant execute on function api.monograph_orders() to authenticated;

-- ----------------------------------------------------------------------------
-- 12. Å foreslå en verdi, og å ta den i bruk
--
-- To handlinger med to opphav. Forslaget kan komme fra en agentkjøring som
-- leste en kilde; aksepten kan ikke komme fra den samme. Det er den samme
-- regelen som forbyr egenverifikasjon i evidenskjeden
-- (ANTIDEP_CONSTITUTION.md regel 3), anvendt på utvidelsen av mandatet: en
-- agent som kunne akseptere sitt eget forslag, ville kunnet utvide sitt eget
-- mandat for å få et funn godkjent.
-- ----------------------------------------------------------------------------

create function knowledge.record_monograph_term_proposal(
  p_edition_id uuid,
  p_axis knowledge.monograph_scope_axis,
  p_label text,
  p_rationale text,
  p_actor_id uuid,
  p_agent_run_id uuid,
  p_need_id uuid,
  p_source_version_id uuid,
  p_source_quote text,
  p_concept_id uuid,
  p_population_id uuid,
  p_drug_id uuid
)
  returns workflow.monograph_term_proposals
  language plpgsql
  set search_path = ''
as $$
declare
  v_proposal workflow.monograph_term_proposals;
begin
  -- Et ordrett utdrag skal faktisk stå i den registrerte representasjonen.
  -- Kontrollen er den samme evidenskjeden bruker; uten den ville et
  -- «dokumentert grunnlag» vært en tekst agenten fant på, og utvidelsen av
  -- mandatet ville hvilt på den (ANTIDEP_CONSTITUTION.md regel 2).
  if p_source_quote is not null then
    if knowledge.source_version_text(p_source_version_id) is null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Kildeversjonen forslaget viser til, har ingen registrert representasjon å kontrollere utdraget mot.';
    end if;
    if position(p_source_quote in knowledge.source_version_text(p_source_version_id)) = 0 then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Det ordrette utdraget står ikke i den registrerte representasjonen av kildeversjonen.',
        hint = 'Et grunnlag som ikke kan kontrolleres mot kilden, er en påstand. En påstand skal ikke kunne utvide dekningskartet (ANTIDEP_CONSTITUTION.md regel 2).';
    end if;
  end if;

  insert into workflow.monograph_term_proposals (
    edition_id, axis, label, rationale,
    proposed_by_actor_id, proposed_by_agent_run_id, proposed_from_need_id,
    source_version_id, source_quote,
    concept_id, population_id, drug_id
  )
  values (
    p_edition_id, p_axis, p_label, p_rationale,
    p_actor_id, p_agent_run_id, p_need_id,
    p_source_version_id, p_source_quote,
    p_concept_id, p_population_id, p_drug_id
  )
  on conflict (edition_id, axis, label) do nothing
  returning * into v_proposal;

  if v_proposal.id is null then
    -- Den samme verdien foreslått to ganger er ett forslag. Et andre forslag
    -- ville gitt to avgjørelser om den samme utvidelsen.
    select p.* into v_proposal
    from workflow.monograph_term_proposals p
    where p.edition_id = p_edition_id and p.axis = p_axis and p.label = p_label;
  end if;

  return v_proposal;
end;
$$;

comment on function knowledge.record_monograph_term_proposal(uuid, knowledge.monograph_scope_axis, text, text, uuid, uuid, uuid, uuid, text, uuid, uuid, uuid) is
  'Registrerer ett forslag om en ny avgrensningsverdi, og kontrollerer at et eventuelt ordrett utdrag faktisk står i den registrerte representasjonen av kildeversjonen — den samme kontrollen evidenskjeden bruker. Idempotent på (utgave, akse, etikett): den samme verdien foreslått to ganger er ett forslag, fordi to forslag ville gitt to avgjørelser om den samme utvidelsen. Utvider ingenting av seg selv: et åpent forslag oppretter ingen behov.';

revoke execute on function knowledge.record_monograph_term_proposal(uuid, knowledge.monograph_scope_axis, text, text, uuid, uuid, uuid, uuid, text, uuid, uuid, uuid) from public;

create function knowledge.decide_monograph_term_proposal(
  p_proposal_id uuid,
  p_accept boolean,
  p_note text,
  p_actor_id uuid,
  p_agent_run_id uuid
)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_proposal workflow.monograph_term_proposals;
  v_proposing_role provenance.agent_role;
  v_deciding_role provenance.agent_role;
  v_proposing_model provenance.role_model_assignments;
  v_deciding_model provenance.role_model_assignments;
  v_concept_id uuid;
  v_population_id uuid;
  v_needs integer := 0;
begin
  select p.* into v_proposal
  from workflow.monograph_term_proposals p
  where p.id = p_proposal_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Forslaget finnes ikke.';
  end if;

  if v_proposal.state <> 'open' then
    -- Den samme avgjørelsen sendt inn igjen svarer med det som ble registrert.
    -- En annen avgjørelse på et avgjort forslag avvises av fryseren.
    return jsonb_build_object(
      'reference', v_proposal.reference,
      'decided', false,
      'already_decided', true,
      'state', v_proposal.state::text,
      'needs_created', 0);
  end if;

  if p_agent_run_id is not null and v_proposal.proposed_by_agent_run_id is not null then
    select r.agent_role into v_proposing_role
    from provenance.agent_runs r where r.id = v_proposal.proposed_by_agent_run_id;
    select r.agent_role into v_deciding_role
    from provenance.agent_runs r where r.id = p_agent_run_id;

    if v_proposing_role = v_deciding_role then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Et agentledd kan ikke akseptere sitt eget forslag om en utvidelse.',
        hint = 'Den som skal finne et svar, skal ikke kunne endre sitt eget mandat for å få funnet godkjent (MONOGRAPH_STANDARD.md §4). Aksepten hører til et annet agentledd eller til et menneske med redaktørmandat.';
    end if;

    -- To navn på den samme modellen er ikke to uavhengige modeller
    -- (ANTIDEP_CONSTITUTION.md regel 3).
    v_proposing_model := provenance.current_semantic_model(v_proposing_role);
    v_deciding_model := provenance.current_semantic_model(v_deciding_role);
    if v_proposing_model.id is not null and v_deciding_model.id is not null
       and v_proposing_model.provider = v_deciding_model.provider
       and v_proposing_model.model = v_deciding_model.model
       and v_proposing_model.model_version = v_deciding_model.model_version then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Den aksepterende modellen er den samme som den foreslående.',
        hint = 'To navn på den samme modellen er ikke to uavhengige modeller (ANTIDEP_CONSTITUTION.md regel 3).';
    end if;
  end if;

  if not p_accept then
    update workflow.monograph_term_proposals
    set state = 'declined',
        decided_at = now(),
        decided_by_actor_id = p_actor_id,
        decided_by_agent_run_id = p_agent_run_id,
        decision_note = p_note
    where id = p_proposal_id;

    return jsonb_build_object(
      'reference', v_proposal.reference,
      'decided', true,
      'already_decided', false,
      'state', 'declined',
      'needs_created', 0);
  end if;

  -- Katalogaksene trenger en katalograd for å kunne bære et behov. Finnes den
  -- ikke, opprettes den her — av databasen, i den samme transaksjonen som
  -- aksepten, og bare når aksepten faktisk skjer. Et åpent forslag skal ikke
  -- etterlate en katalograd ingen har tatt stilling til.
  if v_proposal.axis = 'indication' then
    v_concept_id := v_proposal.concept_id;
    if v_concept_id is null then
      select c.id into v_concept_id
      from catalog.clinical_concepts c
      where lower(c.canonical_label) = lower(v_proposal.label)
        and c.concept_type = 'condition';
      if v_concept_id is null then
        insert into catalog.clinical_concepts (canonical_label, concept_type)
        values (v_proposal.label, 'condition')
        returning id into v_concept_id;
      end if;
    end if;
  elsif v_proposal.axis = 'outcome' then
    v_concept_id := v_proposal.concept_id;
    if v_concept_id is null then
      select c.id into v_concept_id
      from catalog.clinical_concepts c
      where lower(c.canonical_label) = lower(v_proposal.label)
        and c.concept_type = 'outcome';
      if v_concept_id is null then
        insert into catalog.clinical_concepts (canonical_label, concept_type)
        values (v_proposal.label, 'outcome')
        returning id into v_concept_id;
      end if;
    end if;
  elsif v_proposal.axis = 'population' then
    v_population_id := v_proposal.population_id;
    if v_population_id is null then
      select p.id into v_population_id
      from catalog.populations p
      where lower(p.canonical_label) = lower(v_proposal.label);
      if v_population_id is null then
        insert into catalog.populations (canonical_label)
        values (v_proposal.label)
        returning id into v_population_id;
      end if;
    end if;
  elsif v_proposal.axis in ('comparator', 'switch_target') and v_proposal.drug_id is null then
    -- Et virkestoff opprettes ikke av en monografiutvidelse. Legemiddelidentitet
    -- er katalogens eget ansvar med sine egne identifikatorer, og en rad
    -- opprettet av et byttepar ville manglet dem alle.
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Verdien peker på et virkestoff som ikke finnes i katalogen.',
      hint = 'Legemiddelidentitet med navn, salt og identifikatorer er katalogens eget ansvar. Et virkestoff opprettes ikke som en bieffekt av en monografiutvidelse.';
  end if;

  update workflow.monograph_term_proposals
  set state = 'accepted',
      decided_at = now(),
      decided_by_actor_id = p_actor_id,
      decided_by_agent_run_id = p_agent_run_id,
      decision_note = p_note,
      concept_id = coalesce(v_concept_id, concept_id),
      population_id = coalesce(v_population_id, population_id)
  where id = p_proposal_id;

  -- Og dekningskartet utvides med den nye verdien, i den samme transaksjonen.
  -- Et akseptert begrep som ikke førte til et behov, ville vært en utvidelse
  -- ingen kunne se.
  v_needs := knowledge.expand_monograph_edition(v_proposal.edition_id);

  return jsonb_build_object(
    'reference', v_proposal.reference,
    'decided', true,
    'already_decided', false,
    'state', 'accepted',
    'needs_created', v_needs);
end;
$$;

comment on function knowledge.decide_monograph_term_proposal(uuid, boolean, text, uuid, uuid) is
  'Avgjør ett forslag om en ny avgrensningsverdi. En agentkjøring kan ikke akseptere et forslag fra sitt eget agentledd, og ikke et forslag fra en kjøring med den samme semantiske modellidentiteten: den som skal finne et svar, skal ikke kunne endre sitt eget mandat for å få funnet godkjent (MONOGRAPH_STANDARD.md §4, ANTIDEP_CONSTITUTION.md regel 3). En akseptert verdi oppretter katalograden den trenger — men aldri et virkestoff, som er katalogens eget ansvar med sine egne identifikatorer — og utvider dekningskartet i den samme transaksjonen. Idempotent: den samme avgjørelsen sendt inn igjen svarer med det som ble registrert.';

revoke execute on function knowledge.decide_monograph_term_proposal(uuid, boolean, text, uuid, uuid) from public;

create function api.propose_monograph_term(
  p_edition_reference text,
  p_axis text,
  p_label text,
  p_rationale text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_edition knowledge.monograph_editions;
  v_axis knowledge.monograph_scope_axis;
  v_proposal workflow.monograph_term_proposals;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.reference = p_edition_reference and e.superseded_at is null;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen gjeldende monografiutgave med denne referansen.';
  end if;

  begin
    v_axis := p_axis::knowledge.monograph_scope_axis;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en avgrensningsakse.', p_axis);
  end;

  v_proposal := knowledge.record_monograph_term_proposal(
    v_edition.id, v_axis, btrim(p_label), btrim(p_rationale),
    v_actor_id, null, null, null, null, null, null, null);

  return jsonb_build_object(
    'reference', v_proposal.reference,
    'axis', v_proposal.axis::text,
    'label', v_proposal.label,
    'state', v_proposal.state::text);
end;
$$;

comment on function api.propose_monograph_term(text, text, text, text) is
  'En redaktørs forslag om en ny avgrensningsverdi i én monografiutgave: en indikasjon, et utfall, en populasjon, et risikoområde eller en annen akse standarden gjentar en mal på. Forslaget utvider ingenting av seg selv — aksepten er en egen handling. Krever editor-mandat. SECURITY DEFINER fordi knowledge og workflow har RLS med default deny.';

revoke execute on function api.propose_monograph_term(text, text, text, text) from public;
grant execute on function api.propose_monograph_term(text, text, text, text) to authenticated;

create function api.decide_monograph_term(
  p_reference text,
  p_accept boolean,
  p_note text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_proposal_id uuid;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  select p.id into v_proposal_id
  from workflow.monograph_term_proposals p
  where p.reference = p_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen forslag med denne referansen.';
  end if;

  if not p_accept and (p_note is null or btrim(p_note) = '') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En avvisning krever en begrunnelse.',
      hint = 'Det er begrunnelsen som gjør avvisningen til en faglig konklusjon framfor til en utsettelse.';
  end if;

  return knowledge.decide_monograph_term_proposal(
    v_proposal_id, p_accept, nullif(btrim(coalesce(p_note, '')), ''), v_actor_id, null);
end;
$$;

comment on function api.decide_monograph_term(text, boolean, text) is
  'En redaktørs avgjørelse om et foreslått fagbegrep: ta det i bruk, eller avvis det med en begrunnelse. En akseptert verdi oppretter katalograden den trenger og utvider dekningskartet i den samme transaksjonen. Krever editor-mandat. SECURITY DEFINER fordi catalog, knowledge og workflow har RLS med default deny.';

revoke execute on function api.decide_monograph_term(text, boolean, text) from public;
grant execute on function api.decide_monograph_term(text, boolean, text) to authenticated;

create function api.monograph_term_proposals(p_edition_reference text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_edition_id uuid;
  v_rows jsonb;
begin
  perform knowledge.assert_editor_authorized();

  select e.id into v_edition_id
  from knowledge.monograph_editions e
  where e.reference = p_edition_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografiutgave med denne referansen.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'reference', p.reference,
           'axis', p.axis::text,
           'label', p.label,
           'rationale', p.rationale,
           'state', p.state::text,
           'proposed_at', p.created_at,
           -- Om forslaget hviler på et dokument, og ikke hvilket: kildeversjonens
           -- id er en intern verdi, og utdraget er beskyttet materiale.
           'has_documented_basis', p.source_version_id is not null,
           'decided_at', p.decided_at,
           'decision_note', p.decision_note
         ) order by p.created_at), '[]'::jsonb)
    into v_rows
  from workflow.monograph_term_proposals p
  where p.edition_id = v_edition_id;

  return v_rows;
end;
$$;

comment on function api.monograph_term_proposals(text) is
  'Forslagene om nye avgrensningsverdier i én monografiutgave, med grunnlag, tilstand og avgjørelse. Sier om et forslag hviler på et dokument, men ikke hvilket: kildeversjonens id er en intern verdi, og det ordrette utdraget er beskyttet materiale (ANTIDEP_CONSTITUTION.md regel 2). Krever editor-mandat.';

revoke execute on function api.monograph_term_proposals(text) from public;
grant execute on function api.monograph_term_proposals(text) to authenticated;
