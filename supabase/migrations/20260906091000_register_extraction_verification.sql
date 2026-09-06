-- ============================================================================
-- Migrasjon 005g — den kontrollerte skriveveien for ekstraksjonsverifikasjon
--
-- Neste ledd i §15 etter migrasjon 005e/005f (§74.30, §74.31): den tekniske
-- agentidentiteten og kjøringsmekanismen finnes, men det finnes ingen skrivevei
-- inn i workflow.evidence_verifications, bare maskineriet fra migrasjon 005.
-- Denne migrasjonen bygger nøyaktig det ene inngangspunktet en autentisert
-- ekstraksjonsverifikator kaller, og bare det.
--
-- Utvider provenience-/workflow-laget fra migrasjon 005 og agentkjøringsmodellen
-- fra 005e, og står utenfor den planlagte rekken i MVP_IMPLEMENTATION_PLAN.md
-- §18-§27, og får derfor en bokstav. Nummeret 009 er fortsatt reservert for
-- DrugProduct-/importfundamentet (§26).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md
--     §10 KI-arbeidet skal deles i eksplisitte roller
--     §11 verifikasjon skal forsøke å falsifisere, mot kildematerialet
--     §12 KI kan foreslå; mennesker har det faglige ansvaret
--     §14 endringer skal være attribuerte og reversible
--     §20 kunnskapsmodellen og agentpipen skal være leverandøruavhengige
--   docs/DATABASE_ARCHITECTURE.md
--     §29 workflow.evidence_verifications
--     §33 provenance.agent_runs
--     §35-§36 audit.events og append-only
--     §43-§44 skriveveier og Data API-kontrakten
--     §50 privilegerte databasefunksjoner
--     §59 cross-row-regler løses med sammensatt fremmednøkkel
--     §60 god triggerbruk
--   docs/EVIDENCE_PIPELINE.md §25 Extraction-verifier, §61 agentroller,
--     §63 minst mulig privilegier
--   docs/CONTENT_GOVERNANCE.md §14 Agent Worker
--   docs/MVP_IMPLEMENTATION_PLAN.md §15 pipelineleddene, §29 golden slice,
--     §49 least privilege for agenter, §74.30-§74.31
--
-- ----------------------------------------------------------------------------
-- Hva denne PR-en bygger, og hva den bevisst ikke gjør
--
-- Ett inngangspunkt, api.register_extraction_verification(...), som en
-- autentisert agentidentitet i rollen extraction_verification kaller inne i en
-- åpen agentkjøring i samme rolle, for å registrere resultatet av å ha
-- kontrollert ett EvidenceItem mot kildematerialet. Samme mønster som
-- api.create_source(...) og api.create_evidence_item(...): ett
-- SECURITY DEFINER-inngangspunkt, tomt search_path, autorisasjon på sitt eget
-- kall, attribusjon utledet av kalleren og ikke oppgitt av den, og en trigger
-- som skriver auditraden i samme transaksjon som INSERT.
--
-- Den bygger ingen kildeversjonsskrivevei (issue 44, §74.30 punkt 1), ingen
-- redaksjonell lesemodell over verifikasjonene, og ingen flate for at et
-- menneske skal registrere en verifikasjon gjennom et skjema — den siste er en
-- annen skrivevei mot samme tabell og hører til sin egen PR (§74.31 sier
-- eksplisitt at rollen som verifiserer nå er to ting: reviewer for et menneske,
-- og denne agentidentiteten for den automatiserte veien). Den bygger heller
-- ikke ClaimRevision, claim-evidenslenker, claim-verifikasjon, review eller
-- publisering — de er hver sin senere PR (§51).
--
-- §74.30 punkt 2 reiste spørsmålet om «adresse pluss hash» er et tilstrekkelig
-- verifikasjonsgrunnlag for `verifiable_representation`, og denne migrasjonen
-- avgjør det: ja. knowledge.source_versions sin egen hodekommentar (migrasjon
-- 20260819064500, avsnitt 5) sier hvorfor — retrieved_from er NOT NULL nettopp
-- fordi «en content_hash uten en adresse å hente på nytt fra kan ikke
-- etterprøves». Med begge til stede kan enhver tredjepart hente kilden på nytt
-- fra retrieved_from og kontrollere den mot content_hash, uavhengig av om
-- Antidep selv har lagret fulltekst i storage_reference. Det er selve
-- mekanismen `verifiable_representation` beskriver. storage_reference er noe
-- annet: en lagret kopi, «når lagring er tillatt og nødvendig», og ikke en
-- forutsetning for at adressen og hashen sammen kan etterprøves.
--
-- Funksjonen krever derfor at evidensfunnet peker på en knowledge.source_
-- versions-rad (source_version_id, migrasjon 20260819064500) som selv har
-- content_hash satt — ikke bare at raden finnes. En kildeversjon uten
-- content_hash (retrieved_from alene, uten hash) er et sporet besøk, ikke en
-- etterprøvbar representasjon, og kvalifiserer ikke. Se avsnitt 5 for hvor
-- dette håndheves, og den negative testen som prøver akkurat denne grensen.
--
-- Skriveveien for å registrere selve kildeversjonen (issue #44) bygges ikke
-- her — den hører til sin egen PR. knowledge.source_versions og
-- knowledge.evidence_items.source_version_id finnes derimot allerede, og
-- api.create_evidence_item(...) kan allerede ta imot en p_source_version_id.
-- Funksjonen bruker derfor det som allerede finnes av grunnlag i skjemaet.
--
-- ----------------------------------------------------------------------------
-- Hvorfor bindingen til agentkjøringen er deklarativ og ikke bare funksjonskode
--
-- Migrasjon 005e sin hodekommentar forutså nøyaktig dette: «Neste PR kan derfor
-- kreve deklarativt at en verifikasjon peker på en kjøring i riktig rolle, utført
-- av den aktøren raden attribueres til, framfor å kontrollere det i
-- funksjonskode som en senere skrivevei kunne glemme.»
--
-- workflow.evidence_verifications får to nye kolonner:
--
--   agent_run_id   Agentkjøringen som produserte raden. NULL for en
--                  verifikasjon en menneskelig reviewer registrerer gjennom et
--                  skjema — den skriv&veien finnes ikke ennå, men kolonnen skal
--                  ikke tvinge fram en agentkjøring for et pipelineledd som per
--                  definisjon kan gjøres av et menneske (§74.31).
--   agent_run_role Konstant `extraction_verification`. Finnes bare for å kunne
--                  uttrykke et krav med en sammensatt fremmednøkkel: denne
--                  tabellen registrerer ingen annen type verifikasjon enn
--                  ekstraksjonskontroll, så enhver kjøring den peker på skal ha
--                  nøyaktig den rollen.
--
-- To sammensatte fremmednøkler mot provenance.agent_runs sine to unike nøkler
-- fra 005e — (id, actor_id) og (id, agent_role) — låser dermed, uten en eneste
-- linje funksjonskode, at en verifikasjon som oppgir en agentkjøring, peker på
-- en kjøring som faktisk tilhører nøyaktig den aktøren raden attribueres til og
-- faktisk kjørte i rollen extraction_verification. Er agent_run_id NULL,
-- gjelder ingen av de to — SQL sin MATCH SIMPLE-semantikk for sammensatte
-- fremmednøkler slipper en rad gjennom når minst én av kolonnene i nøkkelen er
-- NULL.
--
-- Det denne bindingen ikke kan uttrykke deklarativt, er at kjøringen fortsatt
-- er *åpen* i det verifikasjonen registreres — «åpen» er en egenskap ved
-- tidspunktet handlingen skjer, ikke ved raden i ettertid, og kan derfor ikke
-- håndheves av en fremmednøkkel mot en tabell hvis rader endrer status over
-- tid. Den kontrollen gjør provenance.assert_agent_run_open(uuid, uuid), kalt
-- fra funksjonen (avsnitt 4), som den allerede gjør for api.complete_agent_run.
--
-- ----------------------------------------------------------------------------
-- Hvorfor aktør, rolle og kjøring ikke er parametre kalleren oppgir
--
-- p_agent_run_id er den eneste kjøringsrelaterte parameteren. Verifikator-
-- aktøren utledes av provenance.assert_agent_run_open(...) sitt returnerte
-- resultat, ikke av noe kalleren sender inn — samme resonnement som
-- api.create_evidence_item(...) utleder aktøren av auth.uid() og ikke av en
-- parameter. En agentkjører som kunne oppgi en annen aktør enn sin egen, ville
-- gjort attribusjonen til en påstand kalleren skriver om seg selv
-- (ANTIDEP_CONSTITUTION.md §14). Rollen er heller ikke en parameter: den er et
-- krav autentiseringen selv stiller (provenance.authenticate_agent_identity(...),
-- kalt med den faste verdien 'extraction_verification'), ikke en verdi kalleren
-- velger.
--
-- verified_item_creator_actor_id — hvem som laget evidensfunnet — er av samme
-- grunn ikke en parameter. Funksjonen leser den fra knowledge.evidence_items
-- selv, og evidence_verifications_item_fkey (migrasjon 005) håndhever likevel
-- at raden som skrives, faktisk peker på den virkelige skaperen: en verdi
-- kalleren kunne oppgitt fritt, ville vært nøyaktig den innsnikingen
-- separate-actor-kontrollen finnes for å hindre.
--
-- ----------------------------------------------------------------------------
-- Hvorfor verified_at ikke er en parameter
--
-- En agentkjøring som registrerer en verifikasjon, gjør det i det kontrollen
-- faktisk konkluderes; det finnes ingen etterslep å registrere som denne
-- skriveveien skal dekke, i motsetning til en menneskelig reviewer som kan
-- fylle ut et skjema for en kontroll utført tidligere samme dag. verified_at
-- settes derfor til now() i funksjonen, og evidence_verifications_verified_at_
-- not_future_check (migrasjon 005) er dermed alltid trivielt oppfylt for denne
-- veien. En senere skrivevei for menneskelig registrering kan ta imot
-- tidspunktet som egen parameter uten at dette endres.
--
-- ----------------------------------------------------------------------------
-- Enum- og array-parametre er text og castes i kroppen
--
-- Samme grunn som i alle tidligere skrivbare api-funksjoner (007c, 007e, 005e):
-- PostgREST bygger en schemakvalifisert cast til parameterens deklarerte type i
-- kallerens egen sesjon, før funksjonen i det hele tatt starter. Verken anon
-- eller authenticated har USAGE på workflow, så en enum- eller
-- enum-array-parameter ville feilet med «permission denied for schema
-- workflow» uansett at funksjonen selv er SECURITY DEFINER.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. audit.events utvides til å kunne peke på workflow.evidence_verifications
--
-- Samme ombygging som 007c, 007e og 005e måtte gjøre, og av samme grunn:
-- PostgreSQL har ingen ALTER COLUMN som endrer uttrykket til en generert
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
      -- En opprettelse, som source_created og evidence_item_created:
      -- workflow.evidence_verifications er append-only, så raden kan aldri få
      -- et old-snapshot i ettertid.
      when 'evidence_verification_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      else false
    end
  );

-- ----------------------------------------------------------------------------
-- 2. workflow.evidence_verifications får agentkjøringsbinding
--
-- Se hodekommentaren for hvorfor de to kolonnene og de to fremmednøklene finnes.
-- Kolonnene er lagt til før fremmednøklene, slik at ADD CONSTRAINT kan referere
-- dem.
-- ----------------------------------------------------------------------------
alter table workflow.evidence_verifications
  add column agent_run_id uuid,
  add column agent_run_role provenance.agent_role
    generated always as ('extraction_verification'::provenance.agent_role) stored;

comment on column workflow.evidence_verifications.agent_run_id is
  'Agentkjøringen som produserte denne verifikasjonen (provenance.agent_runs), når verifikatoren er en agent. NULL for en verifikasjon et menneske registrerer gjennom en reviewer-flyt — den skriveveien finnes ikke ennå, men kolonnen skal ikke tvinge fram en agentkjøring for et pipelineledd som per definisjon også kan gjøres av et menneske (MVP_IMPLEMENTATION_PLAN.md §74.31). Når satt, låser evidence_verifications_agent_run_actor_fkey og evidence_verifications_agent_run_role_fkey deklarativt at kjøringen faktisk tilhører verifikator-aktøren og faktisk kjørte i rollen extraction_verification (DATABASE_ARCHITECTURE.md §59) — at kjøringen fortsatt var åpen da raden ble skrevet, kontrolleres av provenance.assert_agent_run_open(uuid, uuid) i api.register_extraction_verification(text, text, uuid, uuid, text, text, text[], text, text), fordi «åpen» er en egenskap ved tidspunktet og ikke noe en fremmednøkkel kan uttrykke.';
comment on column workflow.evidence_verifications.agent_run_role is
  'Konstant «extraction_verification». Finnes bare for å kunne uttrykke, med en sammensatt fremmednøkkel mot provenance.agent_runs (id, agent_role), at en agentkjøring denne raden peker på faktisk hadde den rollen: tabellen registrerer ingen annen type verifikasjon enn kontroll av en ekstraksjon mot kilden. Ikke en egenskap ved den enkelte raden — verdien er alltid den samme.';

alter table workflow.evidence_verifications
  add constraint evidence_verifications_agent_run_actor_fkey
    foreign key (agent_run_id, verifier_actor_id)
    references provenance.agent_runs (id, actor_id)
    on update restrict on delete restrict,
  add constraint evidence_verifications_agent_run_role_fkey
    foreign key (agent_run_id, agent_run_role)
    references provenance.agent_runs (id, agent_role)
    on update restrict on delete restrict;

comment on constraint evidence_verifications_agent_run_actor_fkey
  on workflow.evidence_verifications is
  'Når agent_run_id er satt, må agentkjøringen faktisk tilhøre nøyaktig den aktøren raden attribueres til (verifier_actor_id). Sammen med agent_identity_id sine egne fremmednøkler på provenance.agent_runs (migrasjon 005e) gjør dette det umulig å attribuere en verifikasjon til en aktør som ikke faktisk utførte kjøringen.';
comment on constraint evidence_verifications_agent_run_role_fkey
  on workflow.evidence_verifications is
  'Når agent_run_id er satt, må agentkjøringen faktisk ha kjørt i rollen extraction_verification. Låser rettighetsgrensen på raden selv, framfor at kravet bare finnes i api.register_extraction_verification(text, text, uuid, uuid, text, text, text[], text, text) sin funksjonskode, som en senere skrivevei kunne glemme (DATABASE_ARCHITECTURE.md §59).';

create index evidence_verifications_agent_run_id_idx
  on workflow.evidence_verifications (agent_run_id);

-- ----------------------------------------------------------------------------
-- 3. audit.record_evidence_verification_event() — produsenten for INSERT
--
-- Samme mønster som audit.record_evidence_item_event() (migrasjon 007e) og
-- audit.record_source_event() (migrasjon 007c): ikke SECURITY DEFINER, slik at
-- auditskriveren aldri er mer privilegert enn operasjonen den registrerer
-- (§35, §60). Hele raden er snapshotet: workflow.evidence_verifications er
-- append-only og har ingen egen hendelsestabell under seg.
-- ----------------------------------------------------------------------------
create function audit.record_evidence_verification_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot,
    occurred_at
  )
  values (
    'evidence_verification_registered'::audit.event_operation,
    new.id,
    new.verifier_actor_id,
    null,
    to_jsonb(new),
    now()
  );

  return null;
end;
$$;

comment on function audit.record_evidence_verification_event() is
  'Auditskriver for verifikasjonslaget: registrerer at en ekstraksjonsverifikasjon ble registrert, med hele raden som snapshot. Kjører med kallerens rettigheter, ikke som SECURITY DEFINER, slik at en auditrad aldri kan skrives av noen som ikke kunne utført operasjonen selv (samme begrunnelse som audit.record_evidence_item_event() og audit.record_source_event()).';

revoke execute on function audit.record_evidence_verification_event() from public;

create trigger evidence_verifications_record_creation_audit_event
  after insert on workflow.evidence_verifications
  for each row execute function audit.record_evidence_verification_event();

-- ----------------------------------------------------------------------------
-- 4. provenance.assert_agent_run_open(...) tar radlås (§74.32)
--
-- Migrasjon 20260905092000 er allerede merget (PR #48): en database som har
-- registrert den migrasjonsversjonen kjører den aldri på nytt, så en endring i
-- selve den filen ville aldri nådd et allerede migrert miljø — bare et miljø
-- som starter helt fra bunnen, som `db reset` i CI gjør. Fremover-skrivende
-- migrasjoner er regelen (CLAUDE.md, DATABASE_ARCHITECTURE.md), og fiksen hører
-- derfor hjemme her, i den første migrasjonen etter 005e som faktisk bruker
-- funksjonen til noe nytt — ikke som en retusjert linje i filen fra §48.
--
-- Feilen den retter: en vanlig SELECT uten radlås lar sjekken i denne
-- migrasjonens egen api.register_extraction_verification(...) (avsnitt 5) løpe
-- mot en kjøring som en samtidig api.complete_agent_run(...) rekker å lukke
-- mellom sjekk og den påfølgende INSERT-en — verifikasjonen registreres da mot
-- en kjøring som i praksis allerede er lukket, selv om begge kontrollene for
-- seg så riktige ut i det øyeblikket de kjørte.
--
-- FOR UPDATE tar radlåsen på provenance.agent_runs-raden i den kallende
-- funksjonens transaksjon, før status leses. UPDATE-en i
-- api.complete_agent_run(...) er en vanlig UPDATE og konkurrerer derfor
-- automatisk om nøyaktig den samme radlåsen (ingen egen FOR UPDATE trengs
-- der), slik at de to blir atomiske mot hverandre uten at noen av dem endrer
-- oppførsel. Trygt for begge kallerne: funksjonen returnerer fortsatt bare
-- aktøren eller avviser, og holder aldri selv en lås etter at den returnerer —
-- det gjør bare den omsluttende transaksjonen, som allerede eier andre rader
-- den skriver i samme kall. CREATE OR REPLACE FUNCTION bytter bare kroppen;
-- signatur, eiere og grants fra 005e er uendret og gjentas ikke her.
-- ----------------------------------------------------------------------------
create or replace function provenance.assert_agent_run_open(
  p_agent_run_id uuid,
  p_agent_identity_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_actor_id uuid;
begin
  select ar.actor_id into v_actor_id
  from provenance.agent_runs ar
  where ar.id = p_agent_run_id
    and ar.agent_identity_id = p_agent_identity_id
    and ar.status = 'running'
  for update;

  if v_actor_id is null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Det finnes ingen åpen agentkjøring med denne identiteten.',
      hint = 'En agentoperasjon skal skje inne i en kjøring som er åpnet med api.begin_agent_run(...) av samme identitet, og som ikke er avsluttet. En avsluttet kjøring kan ikke gjenåpnes.';
  end if;

  return v_actor_id;
end;
$$;

comment on function provenance.assert_agent_run_open(uuid, uuid) is
  'Kontrollerer at kjøringen finnes, tilhører den autentiserte identiteten og fortsatt er åpen, og returnerer aktøren kjøringen skal attribueres til. Den gjenbrukbare bindingen mellom en agentoperasjon og premissene den kjøres under; skriveveiene i senere pipelineledd kaller den framfor å skrive kontrollen om igjen. SELECT-en tar FOR UPDATE på provenance.agent_runs-raden (§74.32, migrasjon 20260906091000): en agentoperasjon som skriver et objekt i samme transaksjon som dette kallet, gjør dermed sjekken og skrivingen atomisk mot en samtidig api.complete_agent_run(text, text, uuid, text, jsonb, text) som ellers kunne lukket kjøringen mellom sjekk og skriving.';

revoke execute on function provenance.assert_agent_run_open(uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 5. api.register_extraction_verification(...) — den eneste skriveveien
--
-- SECURITY DEFINER, tomt search_path, schemakvalifiserte navn, EXECUTE
-- revokert fra PUBLIC og gitt til anon og authenticated — samme form og samme
-- begrunnelse som api.begin_agent_run(...) og api.complete_agent_run(...)
-- (migrasjon 005e): en agent har ingen brukerkonto, så en kaller uten
-- brukersesjon er anon i Data API-et, og det er legitimasjonen og ikke
-- Data API-rollen som er kontrollen. Funksjonen leser og skriver ingenting før
-- autentiseringen har lyktes, og enhver mislykket autentisering gir nøyaktig
-- samme svar (provenance.reject_agent_authentication()).
-- ----------------------------------------------------------------------------
create function api.register_extraction_verification(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_evidence_item_id uuid,
  p_outcome text,
  p_source_access text,
  p_checked_fields text[],
  p_rationale text,
  p_findings text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_outcome workflow.verification_outcome;
  v_source_access workflow.verification_source_access;
  v_checked_fields workflow.evidence_check_field[];
  v_identity_id uuid;
  v_verifier_actor_id uuid;
  v_creator_actor_id uuid;
  v_source_version_id uuid;
  v_source_version_content_hash text;
  v_verification_id uuid;
begin
  -- Vokabularparametrene castes først og for seg, slik at en ukjent verdi gir
  -- en setning som sier hva som er galt, framfor en fremmednøkkelfeil lenger
  -- ned. Vokabularene er offentlig dokumentert (DATABASE_ARCHITECTURE.md §29),
  -- så meldingene røper ingenting autentiseringen skjuler.
  begin
    v_outcome := p_outcome::workflow.verification_outcome;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke et kjent verifikasjonsutfall.', p_outcome),
        hint = 'Gyldige utfall er verified, needs_correction, rejected og uncertain (DATABASE_ARCHITECTURE.md §29).';
  end;

  begin
    v_source_access := p_source_access::workflow.verification_source_access;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent kildetilgang.', p_source_access),
        hint = 'Gyldige verdier er original_source, verifiable_representation og derived_summary (ANTIDEP_CONSTITUTION.md §11).';
  end;

  -- Kastet direkte som array-til-array, ikke via unnest()/array_agg(): det
  -- siste ville gjort en tom liste om til NULL (aggregater over null rader
  -- returnerer NULL), og en tom liste skal avvises av tabellens egen
  -- evidence_verifications_checked_fields_check — ikke av en NOT NULL lenger
  -- oppe, som ville skjult hvilken regel som faktisk avviste den.
  begin
    v_checked_fields := p_checked_fields::workflow.evidence_check_field[];
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Ett eller flere kontrollerte felter er ikke et kjent felt.',
        hint = 'Gyldige felter er kolonnene på knowledge.evidence_items som workflow.evidence_check_field lister (DATABASE_ARCHITECTURE.md §29).';
  end;

  -- Autentiser identiteten eksplisitt for rollen extraction_verification. En
  -- identitet i en annen rolle avvises her, før noe leses eller skrives — det
  -- første av de tre lagene migrasjon 005e sin hodekommentar beskriver.
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'extraction_verification'::provenance.agent_role
  );

  -- Krev en åpen kjøring som tilhører nøyaktig denne identiteten, og la
  -- returverdien — ikke en klientoppgitt parameter — være aktøren raden
  -- attribueres til. Det er umulig å be om en annen aktør enn sin egen: det
  -- finnes ingen parameter å be gjennom.
  v_verifier_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  -- Hvem som laget evidensfunnet leses her, ikke oppgis av kalleren, av samme
  -- grunn: evidence_verifications_item_fkey (migrasjon 005) håndhever at raden
  -- som skrives, peker på den virkelige skaperen, og en verdi kalleren kunne
  -- valgt fritt ville vært nøyaktig den innsnikingen kontrollen finnes for å
  -- hindre.
  select created_by_actor_id, source_version_id
    into v_creator_actor_id, v_source_version_id
  from knowledge.evidence_items
  where id = p_evidence_item_id;

  if v_creator_actor_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Evidensfunnet %L finnes ikke.', p_evidence_item_id),
      hint = 'Kontroller id-en. Et evidensfunn registreres av api.create_evidence_item(...) og er append-only, så det forsvinner aldri i ettertid.';
  end if;

  -- §74.30 punkt 1/2: `verifiable_representation` er en påstand om at det
  -- finnes et grunnlag en tredjepart faktisk kan etterprøve mot — ikke bare et
  -- løfte om at kilden ble besøkt. Bare det at evidensfunnet peker på en
  -- knowledge.source_versions-rad er ikke nok: retrieved_from alene er et
  -- sporet besøk, ikke en etterprøvbar representasjon. content_hash er
  -- mekanismen som gjør representasjonen etterprøvbar (se hodekommentaren), så
  -- den må også være satt på den kildeversjonen.
  if v_source_access = 'verifiable_representation' then
    if v_source_version_id is null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Evidensfunnet har ingen lagret kildeversjon å vise til.',
        hint = 'verifiable_representation forutsetter at evidensfunnet peker på en knowledge.source_versions-rad (source_version_id). Uten det er original_source eller derived_summary det eneste kildegrunnlaget som faktisk kan dokumenteres for dette funnet (issue #44 dekker skriveveien for å registrere kildeversjonen selv).';
    end if;

    select content_hash into v_source_version_content_hash
    from knowledge.source_versions
    where id = v_source_version_id;

    if v_source_version_content_hash is null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Kildeversjonen evidensfunnet peker på har ingen lagret fingeravtrykk (content_hash).',
        hint = 'verifiable_representation krever at kildeversjonen har content_hash satt, slik at retrieved_from og content_hash sammen lar en tredjepart hente kilden på nytt og etterprøve den, uavhengig av om fulltekst er lagret i storage_reference. Uten content_hash er raden bare et sporet besøk (original_source eller derived_summary er da det som faktisk kan dokumenteres).';
    end if;
  end if;

  insert into workflow.evidence_verifications (
    evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
    outcome, source_access, checked_fields, findings, rationale, verified_at,
    agent_run_id
  )
  values (
    p_evidence_item_id, v_creator_actor_id, v_verifier_actor_id,
    v_outcome, v_source_access, v_checked_fields, p_findings, p_rationale, now(),
    p_agent_run_id
  )
  returning id into v_verification_id;

  return v_verification_id;
end;
$$;

comment on function api.register_extraction_verification(
  text, text, uuid, uuid, text, text, text[], text, text
) is
  'Den kontrollerte skriveveien for at en autentisert ekstraksjonsverifikator registrerer en kontroll av ett EvidenceItem mot kildematerialet (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29, §43). Autentiserer identiteten eksplisitt for rollen extraction_verification (avviser enhver annen rolle), krever en åpen agentkjøring i samme rolle som tilhører samme identitet (provenance.assert_agent_run_open(uuid, uuid), som tar radlås på kjøringen — se den funksjonens kommentar), og attribuerer raden til den aktøren kjøringen faktisk tilhører — verken aktør, rolle eller kjøring er parametre kalleren kan oppgi fritt. verified_item_creator_actor_id leses fra evidensfunnet selv, ikke fra kalleren. verified_at settes til now(): denne veien registrerer alltid kontrollen i det den konkluderes. p_source_access = ''verifiable_representation'' avvises eksplisitt når evidensfunnets source_version_id er NULL, eller når kildeversjonen den peker på ikke selv har content_hash satt (§74.30 punkt 1/2): retrieved_from og content_hash sammen er det som gjør en kildeversjon etterprøvbar for en tredjepart, og uten begge ville raden vært en påstand uten grunnlag. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi workflow.evidence_verifications, provenance.agent_runs og provenance.agent_identities har RLS med default deny; tomt search_path, og kalleren autentiseres på funksjonens eget kall (§50). EXECUTE går til anon og authenticated av samme grunn som api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb) og api.complete_agent_run(text, text, uuid, text, jsonb, text) (migrasjon 005e): en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen. Utover vokabularcastene og source_version-sjekken er ingen feltvalidering duplisert her: evidence_verifications_separate_actor_check, evidence_verifications_source_access_check og de øvrige constraintene på tabellen (migrasjon 005) er fasiten, og deres avvisninger propageres uendret — inkludert at en agent aldri kan verifisere sitt eget arbeid.';

revoke execute on function api.register_extraction_verification(
  text, text, uuid, uuid, text, text, text[], text, text
) from public;
grant execute on function api.register_extraction_verification(
  text, text, uuid, uuid, text, text, text[], text, text
) to anon, authenticated;
