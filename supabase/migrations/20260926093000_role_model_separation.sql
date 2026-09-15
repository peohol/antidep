-- ============================================================================
-- Migrasjon 009c — modellrollene blir reelt separate
--
-- ANTIDEP_CONSTITUTION.md regel 3 sier at generator, kildestøttekontroll og
-- evidensvurdering er separate roller, og at egenverifikasjon er forbudt.
-- Fram til nå har den regelen vært håndhevet på *aktør*: en agent kan ikke
-- kontrollere sitt eget arbeid, fordi verifikasjonsradene krever en annen
-- aktør enn den som laget raden.
--
-- Modellen har ikke vært håndhevet i det hele tatt. Leverandør, modell og
-- modellversjon har vært fri tekst på kjøringen, og to roller kunne oppgi
-- nøyaktig den samme modellen. Da er separasjonen et navn i en prompt, og
-- EVIDENCE_PIPELINE.md er uttrykkelig på at en rolle som bare er et navn i en
-- prompt, ingen grense er.
--
-- Det var ikke hypotetisk: supabase/tests/700 og 710 åpnet fem kjøringer i fem
-- forskjellige roller, alle med modellidentiteten «testleverandør/testmodell/
-- 2026-09-24». Kjeden godtok det.
--
-- ----------------------------------------------------------------------------
-- 1. Registeret er erklæringen
--
-- `provenance.role_model_assignments` sier hvilken modellidentitet hver
-- agentrolle handler som, med gyldighetsperiode, begrunnelse og hvem som
-- registrerte den. To exclusion constraints gjør erklæringen til en regel:
--
--   * én gyldig tildeling per rolle om gangen, og
--   * ingen to roller deler modellidentitet i overlappende tid.
--
-- Den andre er separasjonen. Den er strukturell og ikke en konvensjon: et
-- forsøk på å gi to ledd den samme modellen avvises av databasen, uansett
-- hvilken skrivevei som prøver.
--
-- ----------------------------------------------------------------------------
-- 2. Premissene kan ikke lenger være hva som helst
--
-- `api.begin_agent_run` krever nå at kjøringens leverandør, modell og
-- modellversjon er nøyaktig den registrerte tildelingen for rollen. En rolle
-- uten gyldig tildeling kan ikke åpne en kjøring i det hele tatt — fail-closed,
-- fordi alternativet er en kjøring med premisser ingen har tatt stilling til.
--
-- Promptmalversjon og pipelineversjon er fortsatt frie. De er *våre*, ikke
-- leverandørens: promptmalen hører til forespørselen, og pipelineversjonen sier
-- hvilken kjede kjøringen var en del av. Å pinne dem her ville gjort hver
-- malendring til en migrasjon uten å gjøre separasjonen sterkere.
--
-- ----------------------------------------------------------------------------
-- 3. Forbudet mot egenverifikasjon gjentas der det gjelder
--
-- Registeret gjør det umulig for to roller å dele modell, og en kontroll er
-- alltid en annen rolle enn det den kontrollerer. Forbudet følger dermed
-- allerede. Det håndheves likevel en gang til, på selve kontrollradene: en
-- kontroll skal ikke kunne vise til en kjøring med den samme modellidentiteten
-- som den kjøringen som laget det kontrollerte. En regel som bare gjaldt
-- indirekte, ville sluttet å gjelde den dagen registeret ble feilkonfigurert —
-- og det er nettopp da den betyr noe.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 3, 4, 7
--   docs/DATABASE_ARCHITECTURE.md §33, §35, §43, §50
--   docs/EVIDENCE_PIPELINE.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Registeret
-- ----------------------------------------------------------------------------
create table provenance.role_model_assignments (
  id uuid primary key default gen_random_uuid(),

  agent_role provenance.agent_role not null,
  provider text not null,
  model text not null,
  model_version text not null,

  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  validity tstzrange
    generated always as (tstzrange(valid_from, valid_to, '[)')) stored,

  registered_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  reason text not null,

  -- Avslutningen har sin egen attribusjon og sin egen begrunnelse. Den som
  -- registrerte tildelingen, er ikke nødvendigvis den som avsluttet den, og en
  -- auditrad som førte avslutningen på registranten ville sagt noe usant om
  -- hvem som endret kjedens mest sikkerhetskritiske innstilling.
  closed_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict,
  close_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint role_model_assignments_validity_check
    check (valid_to is null or valid_to > valid_from),
  -- De tre feltene som utgjør avslutningen, settes sammen eller ikke i det hele
  -- tatt. En valid_to uten hvem og hvorfor ville vært en endring uten ansvar.
  constraint role_model_assignments_closure_pairing_check
    check ((valid_to is null) = (closed_by_actor_id is null)
           and (valid_to is null) = (close_reason is null)),
  constraint role_model_assignments_close_reason_shape_check
    check (close_reason is null
           or (close_reason = btrim(close_reason) and length(close_reason) between 1 and 2000)),
  constraint role_model_assignments_provider_shape_check
    check (provider = btrim(provider) and length(provider) between 1 and 200),
  constraint role_model_assignments_model_shape_check
    check (model = btrim(model) and length(model) between 1 and 200),
  constraint role_model_assignments_model_version_shape_check
    check (model_version = btrim(model_version) and length(model_version) between 1 and 200),
  constraint role_model_assignments_reason_shape_check
    check (reason = btrim(reason) and length(reason) between 1 and 2000),

  -- Én gyldig tildeling per rolle om gangen. Uten den kunne en rolle hatt to
  -- samtidige modeller, og «hvilken modell handler denne rollen som» ville
  -- vært et spørsmål uten ett svar.
  constraint role_model_assignments_one_per_role_excl
    exclude using gist (agent_role with =, validity with &&),

  -- Separasjonen: ingen to roller deler modellidentitet i overlappende tid.
  -- Dette er regel 3 som en databaseregel framfor som en konvensjon.
  constraint role_model_assignments_no_shared_model_excl
    exclude using gist (provider with =, model with =, model_version with =, validity with &&)
);

comment on table provenance.role_model_assignments is
  'Hvilken modellidentitet hver agentrolle handler som (ANTIDEP_CONSTITUTION.md regel 3, EVIDENCE_PIPELINE.md). To exclusion constraints gjør erklæringen til en regel: én gyldig tildeling per rolle om gangen, og ingen to roller som deler leverandør, modell og modellversjon i overlappende tid. Den andre er separasjonen mellom generator, kildestøttekontroll og evidensvurdering, håndhevet strukturelt framfor som en konvensjon — et forsøk på å gi to ledd den samme modellen avvises av databasen uansett hvilken skrivevei som prøver. api.begin_agent_run krever at kjøringens premisser er nøyaktig den registrerte tildelingen, og en rolle uten gyldig tildeling kan ikke åpne en kjøring i det hele tatt.';
comment on column provenance.role_model_assignments.validity is
  'Gyldighetsperioden som et intervall, generert av valid_from og valid_to. Finnes fordi de to exclusion-reglene trenger en venstreside å overlappe på; den er aldri en verdi kalleren oppgir.';
comment on column provenance.role_model_assignments.reason is
  'Hvorfor rollen fikk denne modellen. En modellbytte er en pipelinekonfigurasjonsendring og skal kunne leses tilbake; en tildeling uten begrunnelse ville vært en endring uten grunn.';
comment on column provenance.role_model_assignments.closed_by_actor_id is
  'Hvem som avsluttet tildelingen. Egen kolonne og ikke registered_by_actor_id: den som registrerte tildelingen, er ikke nødvendigvis den som avsluttet den, og auditraden over avslutningen skal navngi den som faktisk gjorde det.';
comment on column provenance.role_model_assignments.close_reason is
  'Hvorfor tildelingen ble avsluttet. Settes sammen med valid_to og closed_by_actor_id, eller ikke i det hele tatt: at en rolle sluttet å handle som en modell, er en pipelinekonfigurasjonsendring på linje med at den begynte.';

alter table provenance.role_model_assignments enable row level security;

create index role_model_assignments_role_idx
  on provenance.role_model_assignments (agent_role, valid_from desc);

create trigger role_model_assignments_set_row_timestamps
  before insert or update on provenance.role_model_assignments
  for each row execute function catalog.set_row_timestamps();

create trigger role_model_assignments_are_append_only
  before delete on provenance.role_model_assignments
  for each row execute function knowledge.reject_append_only_mutation(
    'En tildeling sier hvilken modell rollen faktisk handlet som i den perioden. Avslutt den med valid_to og registrer en ny; en slettet tildeling ville gjort kjøringene i perioden uforklarlige.'
  );

-- Sletting er ikke den eneste måten å viske ut historikken på.
--
-- En UPDATE kunne skrevet om leverandør, modell, modellversjon, starttidspunkt,
-- begrunnelse eller attribusjon i etterkant — og da ville raden sagt noe annet
-- enn det kjøringene i perioden faktisk kjørte under, mens auditraden fra
-- innsettingen fortsatt bar det opprinnelige øyeblikksbildet. To kilder som
-- motsier hverandre er verre enn én, og den ene endringen som *skal* kunne
-- gjøres, er å avslutte tildelingen.
--
-- Regelen er derfor smal: `valid_to` kan settes én gang, fra NULL til et
-- tidspunkt. Alt annet er frosset.
create function provenance.freeze_role_model_assignment()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.agent_role is distinct from old.agent_role
     or new.provider is distinct from old.provider
     or new.model is distinct from old.model
     or new.model_version is distinct from old.model_version
     or new.valid_from is distinct from old.valid_from
     or new.registered_by_actor_id is distinct from old.registered_by_actor_id
     or new.reason is distinct from old.reason
     or new.created_at is distinct from old.created_at
     or new.id is distinct from old.id then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En modelltildeling er uforanderlig bortsett fra at den kan avsluttes.',
      hint = 'Hvilken modell en rolle handlet som i en periode, er et historisk faktum kjøringene i perioden hviler på. Sett valid_to og registrer en ny tildeling for den nye modellen; en omskriving ville gjort de gamle kjøringene uforklarlige (ANTIDEP_CONSTITUTION.md regel 3, 7).';
  end if;

  if old.valid_to is not null
     and (new.valid_to is distinct from old.valid_to
          or new.closed_by_actor_id is distinct from old.closed_by_actor_id
          or new.close_reason is distinct from old.close_reason) then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En avsluttet modelltildeling kan ikke avsluttes på nytt eller gjenåpnes.',
      hint = 'Avslutningen er selv et historisk faktum. En gjenåpning er en ny tildeling.';
  end if;

  return new;
end;
$$;

comment on function provenance.freeze_role_model_assignment() is
  'Fryser alt ved en modelltildeling bortsett fra at den kan avsluttes én gang, med valid_to, closed_by_actor_id og close_reason satt sammen (ANTIDEP_CONSTITUTION.md regel 3, 7). Uten den kunne en UPDATE skrevet om leverandør, modell, modellversjon, starttidspunkt, begrunnelse eller attribusjon i etterkant, slik at raden sa noe annet enn det kjøringene i perioden faktisk kjørte under — mens auditraden fra innsettingen fortsatt bar det opprinnelige øyeblikksbildet. Sletting er stengt av sin egen trigger; dette er den andre halvdelen av den samme regelen.';

revoke execute on function provenance.freeze_role_model_assignment() from public;

create trigger role_model_assignments_freeze_history
  before update on provenance.role_model_assignments
  for each row execute function provenance.freeze_role_model_assignment();

create function audit.record_role_model_assignment_event()
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
    'role_model_assignment_registered'::audit.event_operation,
    new.id,
    new.registered_by_actor_id,
    null,
    to_jsonb(new),
    new.reason,
    now()
  );

  return null;
end;
$$;

comment on function audit.record_role_model_assignment_event() is
  'Auditskriver over nye modelltildelinger (DATABASE_ARCHITECTURE.md §35). Hvilken modell en agentrolle får handle som, er den mest sikkerhetskritiske innstillingen i kjeden etter rolletildeling: den avgjør om to ledd faktisk er uavhengige. Ligger på tabellen og ikke på en skrivevei, slik at ingen tildeling kan skje uten spor.';

revoke execute on function audit.record_role_model_assignment_event() from public;

create trigger role_model_assignments_record_audit_event
  after insert on provenance.role_model_assignments
  for each row execute function audit.record_role_model_assignment_event();

-- At en rolle *sluttet* å handle som en modell, er like sikkerhetskritisk som
-- at den begynte: det er øyeblikket separasjonen mellom to ledd kan endre seg.
-- Uten denne raden ville registeret båret avslutningen mens auditsporet var
-- stille akkurat der endringen ble gjort, og en logg som er stille der
-- avgjørelsen ble tatt, ser ut som en logg uten å være det.
--
-- Begge øyeblikksbildene føres, slik at avslutningen kan leses som det den er:
-- en overgang fra en åpen tildeling til en avsluttet.
create function audit.record_role_model_assignment_closure_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.valid_to is null or old.valid_to is not null then
    return null;
  end if;

  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, reason, occurred_at
  )
  values (
    'role_model_assignment_closed'::audit.event_operation,
    new.id,
    new.closed_by_actor_id,
    to_jsonb(old),
    to_jsonb(new),
    new.close_reason,
    now()
  );

  return null;
end;
$$;

comment on function audit.record_role_model_assignment_closure_event() is
  'Auditskriver over avsluttede modelltildelinger (DATABASE_ARCHITECTURE.md §35). Fryseren tillater nøyaktig én endring på en tildeling — at den avsluttes — og dette er sporet over den. At en rolle sluttet å handle som en modell, er øyeblikket separasjonen mellom to ledd kan endre seg, og et auditspor som bare dekket innsettingen ville vært stille akkurat der. Ligger på tabellen og ikke på en skrivevei, slik at ingen avslutning kan skje uten spor, og fører begge øyeblikksbildene, slik at overgangen kan leses.';

revoke execute on function audit.record_role_model_assignment_closure_event() from public;

create trigger role_model_assignments_record_closure_audit_event
  after update on provenance.role_model_assignments
  for each row execute function audit.record_role_model_assignment_closure_event();

-- ----------------------------------------------------------------------------
-- 2. Oppslaget, brukt av både gaten og kontrollene
-- ----------------------------------------------------------------------------
create function provenance.current_role_model(p_agent_role provenance.agent_role)
  returns provenance.role_model_assignments
  language sql
  stable
  set search_path = ''
as $$
  select a.*
  from provenance.role_model_assignments a
  where a.agent_role = p_agent_role
    and a.valid_from <= statement_timestamp()
    and (a.valid_to is null or a.valid_to > statement_timestamp())
  limit 1;
$$;

comment on function provenance.current_role_model(provenance.agent_role) is
  'Modelltildelingen som gjelder for rollen akkurat nå, eller ingen rad. Gyldighet måles med statement_timestamp() og ikke med transaksjonens starttidspunkt, slik at en avsluttet tildeling virker umiddelbart — samme regel som rolletildelingene bruker. Exclusion-regelen garanterer at det finnes høyst én.';

revoke execute on function provenance.current_role_model(provenance.agent_role) from public;

-- ----------------------------------------------------------------------------
-- 3. De registrerte tildelingene
--
-- Verdiene er ordrett de samme som premissene kjørerne registrerer
-- (src/agents/model-roles.ts). De to sidene er den samme kontrakten sett fra
-- hver sin side av databasegrensen, og pinnes derfor av en prøve på begge.
--
-- De fire rollene som ikke står her — source_discovery,
-- source_quality_assessment, adversarial_review og editorial_compression — har
-- ingen skrivevei og ingen registrert identitet. Fraværet er tilsiktet: en
-- kjøring i en av dem avvises, framfor å komme i gang med premisser ingen har
-- tatt stilling til.
-- ----------------------------------------------------------------------------
insert into provenance.role_model_assignments
  (agent_role, provider, model, model_version, registered_by_actor_id, reason)
select v.agent_role::provenance.agent_role, v.provider, v.model, v.model_version,
       a.id, v.reason
from (values
  ('evidence_extraction', 'antidep', 'proposal-grounded-extraction', '1.1.0',
   'Registreringsleddet for ett kildeforankret ekstraksjonsforslag. Deterministisk kontroll av Antideps egen kode; modellen som leste artikkelen, er erklært i kjøringens inndatamanifest.'),
  ('extraction_verification', 'antidep', 'deterministic-extraction-check', '1.0.0',
   'Den uavhengige kontrollen av ett ekstrahert evidensfunn mot originaldokumentet. Egen modellidentitet, fordi kontrollen ikke skal kunne være det samme leddet som laget funnet.'),
  ('claim_synthesis', 'antidep', 'proposal-registered-synthesis', '1.0.0',
   'Registreringsleddet for én påstandsrevisjon med sitt evidensgrunnlag.'),
  ('citation_support_verification', 'antidep', 'deterministic-claim-check', '1.0.0',
   'Kildestøttekontrollen av én påstandsrevisjon mot det registrerte evidensgrunnlaget. Egen modellidentitet, fordi den ikke skal kunne være det samme leddet som formulerte påstanden.'),
  ('evidence_assessment', 'antidep', 'proposal-registered-assessment', '1.0.0',
   'Evidensvurderingen av grunnlaget bak én påstandsrevisjon. Egen modellidentitet, fordi vurderingen er et annet ansvar enn både påstandsdannelsen og kildestøttekontrollen.')
) as v(agent_role, provider, model, model_version, reason)
cross join lateral (
  select id from provenance.actors where actor_key = 'human:peder-holman'
) a;

-- ----------------------------------------------------------------------------
-- 4. Gaten i api.begin_agent_run
--
-- Signaturen er uendret, så `create or replace` framfor DROP + CREATE: da står
-- grantene, og PostgREST får ingen overload å velge mellom.
-- ----------------------------------------------------------------------------
create or replace function api.begin_agent_run(
  p_identity_key text,
  p_secret text,
  p_agent_role text,
  p_provider text,
  p_model text,
  p_model_version text,
  p_prompt_template_version text,
  p_pipeline_version text,
  p_input_manifest jsonb,
  p_input_source_version_id uuid default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_role provenance.agent_role;
  v_identity_id uuid;
  v_actor_id uuid;
  v_run_id uuid;
  v_assignment provenance.role_model_assignments;
begin
  -- Casten skjer først og for seg selv, slik at en ukjent rolle gir en setning
  -- som sier hva som er galt. Vokabularet er offentlig dokumentert
  -- (ANTIDEP_CONSTITUTION.md §10, EVIDENCE_PIPELINE.md §61), så meldingen røper
  -- ingenting autentiseringen skjuler.
  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role),
        hint = 'Gyldige roller er de eksplisitte agentrollene i ANTIDEP_CONSTITUTION.md §10 og EVIDENCE_PIPELINE.md §61.';
  end;

  -- Autentiseringen står før modellgaten, slik at en mislykket autentisering
  -- fortsatt svarer det den alltid har svart: en kaller uten legitimasjon skal
  -- ikke få vite noe om konfigurasjonen bak.
  v_identity_id := provenance.authenticate_agent_identity(p_identity_key, p_secret, v_role);

  -- Modellgaten (migrasjon 009c). Fail-closed på fravær: en rolle uten
  -- registrert tildeling kan ikke kjøre, framfor å kjøre med premisser ingen
  -- har tatt stilling til.
  v_assignment := provenance.current_role_model(v_role);
  if v_assignment.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig modelltildeling.', p_agent_role),
      hint = 'Hvilken modell en rolle handler som, er en registrert avgjørelse i provenance.role_model_assignments, ikke en verdi kalleren oppgir. En kjøring uten den ville hatt premisser ingen har tatt stilling til.';
  end if;

  if p_provider is distinct from v_assignment.provider
     or p_model is distinct from v_assignment.model
     or p_model_version is distinct from v_assignment.model_version then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Rollen %L er registrert med modellidentiteten %L/%L/%L, men kjøringen oppgir %L/%L/%L.',
        p_agent_role, v_assignment.provider, v_assignment.model, v_assignment.model_version,
        p_provider, p_model, p_model_version
      ),
      hint = 'Modellidentiteten er registeret sitt svar, ikke kallerens. Uten den regelen kunne to ledd i kjeden oppgitt den samme modellen, og separasjonen mellom generator, kildestøttekontroll og evidensvurdering ville vært et navn framfor en grense (ANTIDEP_CONSTITUTION.md regel 3). Promptmalversjon og pipelineversjon er fortsatt frie.';
  end if;

  select ai.actor_id into v_actor_id
  from provenance.agent_identities ai
  where ai.id = v_identity_id;

  insert into provenance.agent_runs (
    agent_identity_id, actor_id, agent_role,
    provider, model, model_version, prompt_template_version, pipeline_version,
    status, input_manifest, input_source_version_id
  )
  values (
    v_identity_id, v_actor_id, v_role,
    p_provider, p_model, p_model_version, p_prompt_template_version, p_pipeline_version,
    'running', p_input_manifest, p_input_source_version_id
  )
  returning id into v_run_id;

  return v_run_id;
end;
$$;

comment on function api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb, uuid) is
  'Åpner en agentkjøring: autentiserer identiteten for den rollen kjøringen skal handle i, kontrollerer at premissene er den registrerte modelltildelingen for rollen (provenance.role_model_assignments, migrasjon 009c), og registrerer premissene operasjonen kjøres under — leverandør, modell, modellversjon, promptmalversjon, pipelineversjon, inputmanifest og kildeversjonen kjøringen skal lese (DATABASE_ARCHITECTURE.md §33, §57, EVIDENCE_PIPELINE.md §65). Leverandør, modell og modellversjon er ikke lenger fri tekst: de må være nøyaktig den registrerte tildelingen, og en rolle uten gyldig tildeling kan ikke åpne en kjøring i det hele tatt — uten den regelen kunne to ledd i kjeden oppgitt den samme modellen, og separasjonen mellom generator, kildestøttekontroll og evidensvurdering ville vært et navn framfor en grense. Promptmalversjon og pipelineversjon er fortsatt frie, fordi de er Antideps egne og ikke leverandørens. Autentiseringen står før modellgaten, slik at en kaller uten legitimasjon ikke får vite noe om konfigurasjonen bak. p_input_source_version_id er påkrevd for rollen evidence_extraction og avvises for de øvrige. Kjøringen alene rører ingen kunnskapsobjekter. SECURITY DEFINER med tomt search_path fordi provenance har RLS med default deny; kalleren autentiseres på funksjonens eget kall (§50). EXECUTE går til anon fordi en agent ikke har brukerkonto (§16) — legitimasjonen og ikke Data API-rollen er kontrollen.';

-- ----------------------------------------------------------------------------
-- 5. Forbudet mot egenverifikasjon, gjentatt på kontrollradene
--
-- Registeret gjør allerede to roller ute av stand til å dele modell. Regelen
-- under er den samme regelen sagt der den gjelder: en kontroll skal ikke kunne
-- vise til en kjøring med den samme modellidentiteten som den kjøringen som
-- laget det kontrollerte. Den fanger den dagen registeret er feilkonfigurert,
-- og det er nettopp da den betyr noe.
-- ----------------------------------------------------------------------------
create function provenance.assert_distinct_model_identity(
  p_checking_run_id uuid,
  p_checked_run_id uuid,
  p_what text
)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_same boolean;
begin
  if p_checking_run_id is null or p_checked_run_id is null then
    -- Et menneskes registrering har ingen kjøring, og et objekt laget av et
    -- menneske har det heller ikke. Fraværet er ikke et sammenfall.
    return;
  end if;

  select a.provider = b.provider
     and a.model = b.model
     and a.model_version = b.model_version
    into v_same
  from provenance.agent_runs a, provenance.agent_runs b
  where a.id = p_checking_run_id and b.id = p_checked_run_id;

  if coalesce(v_same, false) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        '%s ble gjort av den samme modellidentiteten som laget det som kontrolleres.',
        p_what
      ),
      hint = 'Generator, kildestøttekontroll og evidensvurdering er separate roller, og egenverifikasjon er forbudt (ANTIDEP_CONSTITUTION.md regel 3). En kontroll utført av den samme modellen som produserte innholdet, er ikke en uavhengig kontroll — den er den samme vurderingen gjort to ganger.';
  end if;
end;
$$;

comment on function provenance.assert_distinct_model_identity(uuid, uuid, text) is
  'Avviser en kontroll utført av den samme modellidentiteten som produserte det kontrollerte (ANTIDEP_CONSTITUTION.md regel 3). NULL på en av sidene er ikke et sammenfall: et menneskes registrering har ingen agentkjøring. Regelen følger allerede av at provenance.role_model_assignments ikke lar to roller dele modell; den håndheves likevel her, fordi en regel som bare gjaldt indirekte, ville sluttet å gjelde den dagen registeret ble feilkonfigurert.';

revoke execute on function provenance.assert_distinct_model_identity(uuid, uuid, text) from public;

create function workflow.enforce_evidence_verification_model_separation()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_checked_run_id uuid;
begin
  select e.agent_run_id into v_checked_run_id
  from knowledge.evidence_items e
  where e.id = new.evidence_item_id;

  perform provenance.assert_distinct_model_identity(
    new.agent_run_id, v_checked_run_id, 'Ekstraksjonskontrollen'
  );
  return new;
end;
$$;

revoke execute on function workflow.enforce_evidence_verification_model_separation() from public;

create trigger evidence_verifications_require_model_separation
  before insert on workflow.evidence_verifications
  for each row execute function workflow.enforce_evidence_verification_model_separation();

create function workflow.enforce_claim_verification_model_separation()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_checked_run_id uuid;
begin
  select r.agent_run_id into v_checked_run_id
  from knowledge.claim_revisions r
  where r.id = new.claim_revision_id;

  perform provenance.assert_distinct_model_identity(
    new.agent_run_id, v_checked_run_id, 'Kildestøttekontrollen'
  );
  return new;
end;
$$;

revoke execute on function workflow.enforce_claim_verification_model_separation() from public;

create trigger claim_verifications_require_model_separation
  before insert on workflow.claim_verifications
  for each row execute function workflow.enforce_claim_verification_model_separation();

create function knowledge.enforce_assessment_model_separation()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_revision_run_id uuid;
  v_verification_run_id uuid;
begin
  select r.agent_run_id into v_revision_run_id
  from knowledge.claim_revisions r
  where r.id = new.claim_revision_id;

  perform provenance.assert_distinct_model_identity(
    new.agent_run_id, v_revision_run_id, 'Evidensvurderingen'
  );

  -- Vurderingen skal heller ikke være den samme modellen som kildestøtte-
  -- kontrollen: de to er hvert sitt ansvar, og en sammenslåing ville gjort
  -- «kontrollert og vurdert» til én operasjon utført av ett ledd.
  select v.agent_run_id into v_verification_run_id
  from workflow.claim_verifications v
  where v.claim_revision_id = new.claim_revision_id
  order by v.verified_at desc, v.id desc
  limit 1;

  perform provenance.assert_distinct_model_identity(
    new.agent_run_id, v_verification_run_id, 'Evidensvurderingen'
  );
  return new;
end;
$$;

revoke execute on function knowledge.enforce_assessment_model_separation() from public;

create trigger evidence_assessments_require_model_separation
  before insert on knowledge.evidence_assessments
  for each row execute function knowledge.enforce_assessment_model_separation();
