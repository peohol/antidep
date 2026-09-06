-- ============================================================================
-- Migrasjon 007f — den kontrollerte skriveveien for å registrere en kildeversjon
--
-- Issue #44 og MVP_IMPLEMENTATION_PLAN.md §74.30 punkt 1: `knowledge.source_
-- versions` har eksistert siden migrasjon 003, men det finnes ingen skrivevei
-- inn i den. En kilde opprettet gjennom `api.create_source(...)` har derfor per
-- definisjon null versjoner, og et evidensfunn registrert mot den har ingenting
-- å kontrolleres mot. §74.32 avgjorde at `retrieved_from` + `content_hash` er et
-- tilstrekkelig verifikasjonsgrunnlag; denne migrasjonen bygger leddet som
-- faktisk produserer det grunnlaget.
--
-- Utvider api-lesemodellen fra migrasjon 007 (§24) med dens tredje skrivbare
-- medlem, etter 007c (Source) og 007e (EvidenceItem), og følger derfor
-- bokstavkonvensjonen videre: 007 → 007a → … → 007e → 007f. Nummeret 009 er
-- fortsatt reservert for DrugProduct-/importfundamentet (§26).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md
--     §4  enhver klinisk relevant påstand skal være etterprøvbar
--     §8  evidens og proveniens er førsteklasses data
--     §11 verifikasjon skal skje mot kildematerialet eller en etterprøvbar
--         representasjon av det
--     §14 endringer skal være attribuerte
--   docs/DATABASE_ARCHITECTURE.md
--     §7, §7.1, §7.3  historiske observasjoner, uforanderlighet og tidsstempler
--     §18  knowledge.source_versions
--     §35-§36  audit.events og append-only
--     §38  en kontrollert operasjon er én transaksjon
--     §43  klienten skal ikke skrive direkte til kanoniske tabeller
--     §44  Data API-kontrakten skal være eksplisitt
--     §50  privilegerte databasefunksjoner
--     §57  vokabular og constraints er fasiten
--   docs/EVIDENCE_PIPELINE.md §19 ekstraksjonen skal ligge tett på kilden,
--     §25 Extraction-verifier
--   docs/KNOWLEDGE_MODEL.md §10
--
-- ----------------------------------------------------------------------------
-- Tillitsmodellen for content_hash: databasen beregner den, kalleren oppgir den
-- ikke
--
-- Dette er migrasjonens viktigste valg, og det er tatt av samme grunn som
-- migrasjon 007e lot `knowledge.evidence_item_content_hash(...)` eie hashen på
-- et evidensfunn: «en hash kalleren kunne oppgi ville sett ut som en garanti
-- uten å være det».
--
-- api.create_source_version(...) tar derfor imot *representasjonen* og ikke
-- hashen. Den beregner selv `content_hash` med
-- knowledge.source_version_content_hash(text), i samme transaksjon som raden
-- skrives. Konsekvensen er at de tre spørsmålene en verifikator må kunne
-- besvare, har hvert sitt entydige svar:
--
--   Hvem beregner hashen?   PostgreSQL, inne i skriveveien. Ingen klient, ingen
--                           agent og ingen migrasjon kan sette verdien gjennom
--                           denne veien.
--   Hva hashes?             Nøyaktig den teksten kalleren oppgir som den hentede
--                           representasjonen, UTF-8-kodet, uten normalisering,
--                           uten trimming og uten reserialisering.
--   Hvordan etterprøves     Hent `retrieved_from` på nytt og kjør sha256 over
--   den?                    svaret. Er hashene like, er representasjonen den
--                           samme som den ekstraksjonen ble gjort fra. Er de
--                           ulike, har kilden endret seg — eller det som ble
--                           registrert var ikke det adressen faktisk gir.
--
-- Det siste er grensen for hva databasen kan garantere, og den skrives ut
-- framfor å pyntes på: PostgreSQL kan ikke hente en URL, så basen kan ikke vite
-- at teksten faktisk kom fra adressen. Den kan bare garantere at hashen er
-- hashen *av den teksten*. Kontrollen av den siste koblingen er
-- ekstraksjonsverifikatorens, og den er reell: verifikatoren henter adressen på
-- nytt og sammenligner (ANTIDEP_CONSTITUTION.md §11). En registrering der
-- teksten ikke kom fra adressen, overlever derfor ikke første verifikasjon —
-- den gir «kildeversjonen kan ikke reproduseres», og ingen `verified`-rad.
--
-- `p_retrieved_content` er påkrevd og kan ikke være tom. En kildeversjon uten
-- fingeravtrykk er det §74.32 kaller «et sporet besøk», og kvalifiserer ikke som
-- `verifiable_representation`. Kolonnen er fortsatt nullbar — de to seedede
-- radene fra migrasjon 003 og en eventuell senere skrivevei for representasjoner
-- som ikke er tekst (PDF, binærformater) skal ikke tvinges gjennom denne
-- formen — men denne veien kan ikke lage en slik rad.
--
-- `storage_reference` er valgfritt og er den sterkere formen: en faktisk lagret
-- kopi. Den er ikke en forutsetning for `verifiable_representation` (§74.32),
-- og den beregnes ikke av noe her — den er en driftsadresse, og migrasjon 003
-- holder den bevisst utenfor uforanderlighetsvernet av samme grunn.
--
-- ----------------------------------------------------------------------------
-- Attribusjon: kolonnen manglet, og en skrivevei uten den ville vært et hull
--
-- Migrasjon 005 la `created_by_actor_id` på fem kunnskapstabeller, men ikke på
-- knowledge.source_versions — det fantes ingen skrivevei dit, så det var ingen
-- handling å attribuere. Nå finnes det en, og ANTIDEP_CONSTITUTION.md §14
-- krever at den kan spores. Kolonnen heter `retrieved_by_actor_id` og ikke
-- `created_by_actor_id`, fordi raden er en observasjon og ikke et
-- kunnskapsobjekt: den sier «denne aktøren hentet denne representasjonen på
-- dette tidspunktet».
--
-- Backfillen av de to seedede radene er sann og ikke en bekvemmelighet: migrasjon
-- 003 sin egen seedkommentar sier at kildeversjonene er «de MEDLINE-postene som
-- faktisk ble hentet og kontrollert» for de to seedede evidensfunnene, og
-- migrasjon 005 attribuerte nettopp de funnene til `agent:evidence-extraction`.
-- Samme arbeid, samme aktør. Alternativet — å la kolonnen være nullbar for gamle
-- rader — er avvist av samme grunn som i migrasjon 005: «bare framover» kan ikke
-- uttrykkes deklarativt, og de radene er nettopp de golden slice skal publisere.
--
-- ----------------------------------------------------------------------------
-- Hvem som kan kalle skriveveien, og hvem som ikke kan
--
-- EXECUTE går til `authenticated` og bare dit: dette er en editorhandling, og
-- den autoriseres med knowledge.assert_editor_authorized(uuid) kalt uten begrep,
-- som api.create_source(...) — en kildeversjon er, som kilden selv, ikke
-- avgrenset til noe klinisk begrep.
--
-- Ekstraksjonsverifikatoren får bevisst ingen skrivevei hit. En verifikator som
-- kunne registrere kildeversjonen den selv skal kontrollere mot, ville
-- kontrollert sitt eget grunnlag — nøyaktig den sirkelen
-- ANTIDEP_CONSTITUTION.md §11 og de tre lagene i migrasjon 005e finnes for å
-- hindre. Skal en agent i et *ekstraksjonsledd* kunne registrere
-- representasjonen den leser av, hører det til den PR-en som bygger den
-- identiteten, og den skriveveien vil kalle den samme
-- knowledge.record_source_version(uuid, timestamptz, text, text, text, text, uuid)
-- framfor å kopiere den.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. audit.events utvides til å kunne peke på knowledge.source_versions
--
-- Samme ombygging som 007c, 007e, 005e og 005g måtte gjøre, og av samme grunn:
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
    when 'source_version_registered' then 'knowledge'
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
      -- En opprettelse, som source_created: observasjonen fantes ikke før, og
      -- den kan aldri få et old-snapshot i ettertid — knowledge.freeze_source_
      -- version() fryser den.
      when 'source_version_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      else false
    end
  );

comment on constraint events_snapshot_shape_check on audit.events is
  'Hvilke av de to snapshotene som skal være satt, følger av operasjonen. Uttømmende over audit.event_operation: en ny verdi uten egen gren gir ELSE false, altså en avvist innsetting framfor en stille tom kolonne.';

-- ----------------------------------------------------------------------------
-- 2. knowledge.source_versions får attribusjon
--
-- Se hodekommentaren for hvorfor kolonnen finnes, hvorfor den heter det den
-- heter, og hvorfor backfillen er sann. Rekkefølgen er bindende: kolonnen legges
-- til nullbar, backfilles, settes NOT NULL, og først deretter utvides
-- uforanderlighetsvernet til å dekke den — et vern som gjaldt under backfillen
-- ville avvist backfillen.
-- ----------------------------------------------------------------------------
alter table knowledge.source_versions
  add column retrieved_by_actor_id uuid
    references provenance.actors (id) on update restrict on delete restrict;

update knowledge.source_versions
set retrieved_by_actor_id = (
  select a.id from provenance.actors a where a.actor_key = 'agent:evidence-extraction'
)
where retrieved_by_actor_id is null;

-- Feiler høyt hvis aktøroppslaget over ga NULL. Det er hele kontrollen: en
-- stille NULL ville betydd en observasjon uten opphav (ANTIDEP_CONSTITUTION.md
-- §14), og migrasjonen skal stoppe framfor å etterlate den.
alter table knowledge.source_versions
  alter column retrieved_by_actor_id set not null;

comment on column knowledge.source_versions.retrieved_by_actor_id is
  'Aktøren som hentet representasjonen (ANTIDEP_CONSTITUTION.md §14, DATABASE_ARCHITECTURE.md §18). Heter ikke created_by_actor_id fordi raden er en observasjon og ikke et kunnskapsobjekt: den sier hvem som hentet, ikke hvem som mener noe. De to seedede radene fra migrasjon 003 er attribuert til Antideps ekstraksjonsagent, som er den aktøren migrasjon 005 attribuerte evidensfunnene fra samme seed til.';

create index source_versions_retrieved_by_actor_id_idx
  on knowledge.source_versions (retrieved_by_actor_id);

-- En observasjon kan ikke ha skjedd i framtiden. created_at er databaseeid
-- (catalog.set_row_timestamps()), så dette er en sammenligning mot uavhengig
-- tid og ikke mot et annet tall kalleren selv oppga — samme form som
-- agent_runs_started_at_not_future_check og
-- evidence_verifications_verified_at_not_future_check. En representasjon hentet
-- tidligere kan fortsatt registreres i etterkant; det er bare den
-- framtidsdaterte som avvises.
alter table knowledge.source_versions
  add constraint source_versions_retrieved_at_not_future_check
    check (retrieved_at <= created_at);

comment on constraint source_versions_retrieved_at_not_future_check
  on knowledge.source_versions is
  'En kildeversjon kan ikke være hentet etter at raden ble registrert. Uten regelen kunne en registrering datert fram i tid sett ut som en ferskere observasjon enn den er, og «hvilken versjon var den siste» ville vært en påstand kalleren styrte.';

create or replace function knowledge.freeze_source_version()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.source_id is distinct from old.source_id
    or new.retrieved_at is distinct from old.retrieved_at
    or new.retrieved_from is distinct from old.retrieved_from
    or new.external_version is distinct from old.external_version
    or new.content_hash is distinct from old.content_hash
    or new.retrieved_by_actor_id is distinct from old.retrieved_by_actor_id
  then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Et hentet øyeblikksbilde av en kilde er uforanderlig og kan ikke endres.',
      hint = 'Registrer en ny kildeversjon for det nye innholdet. Evidensfunn som peker på den gamle versjonen skal beholde sin opprinnelige dokumentasjon.';
  end if;

  return new;
end;
$$;

comment on function knowledge.freeze_source_version() is
  'Immutable-row guard: hindrer at et hentet øyeblikksbilde endres etter innsetting, slik at provenienskjeden til evidensfunn som peker på versjonen forblir etterprøvbar. Dekker også attribusjonen (retrieved_by_actor_id, migrasjon 20260907091000): en observasjon som kunne omattribueres i ettertid, ville vært en attribusjon ingen kunne stole på. storage_reference kan endres — hvor en lagret kopi ligger er driftsinformasjon, ikke en del av observasjonen.';

-- ----------------------------------------------------------------------------
-- 3. knowledge.source_version_content_hash(text) — hashen, ett sted
--
-- Ren funksjon uten tabelltilgang, som provenance.agent_secret_hash(text, text)
-- (migrasjon 005e). Formatet er `sha256:` + 64 hex-tegn, nøyaktig det
-- source_versions_content_hash_format_check allerede krever, og nøyaktig det de
-- to seedede radene bærer — de ble hashet med `sha256sum` over svaret fra samme
-- adresse, og verdien reproduseres fortsatt fra den adressen i dag.
--
-- Ingen normalisering: ingen trimming, ingen linjeskiftkonvertering, ingen
-- omkoding. Hashen skal kunne reproduseres av `sha256sum` på svaret fra
-- `retrieved_from`, og hver normalisering ville gjort den avhengig av at
-- etterprøveren kjenner og gjentar nøyaktig samme normalisering.
--
-- Merk at prefikset er `sha256:` og ikke `sha256-v2:` som på et evidensfunn. De
-- to hasher forskjellige ting: et evidensfunn hashes fra en kanonisk
-- serialisering av radens felter (migrasjon 006a), der versjonsnummeret sier
-- hvilken serialisering som ble brukt. Her hashes de hentede bytene direkte, og
-- det finnes ingen serialisering å versjonere. Skulle algoritmen byttes, er
-- prefikset selvbeskrivende nok til at gamle verdier ikke blir tvetydige — det
-- var hele grunnen til at migrasjon 003 la algoritmen inn i verdien.
-- ----------------------------------------------------------------------------
create function knowledge.source_version_content_hash(p_content text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case
    when p_content is null then null
    else 'sha256:' || encode(sha256(convert_to(p_content, 'UTF8')), 'hex')
  end;
$$;

comment on function knowledge.source_version_content_hash(text) is
  'Fingeravtrykket av en hentet representasjon: sha256 av teksten slik den ble hentet, UTF-8-kodet, med algoritmen som prefiks (migrasjon 003 sitt format). Ingen normalisering — verdien skal kunne reproduseres med `sha256sum` på svaret fra source_versions.retrieved_from av hvem som helst, uten å kjenne til noen kanonisk form. Ren funksjon uten tabelltilgang. Eies av databasen og oppgis aldri av en klient: se hodekommentaren i migrasjon 20260907091000 for tillitsmodellen.';

revoke execute on function knowledge.source_version_content_hash(text) from public;

-- ----------------------------------------------------------------------------
-- 4. audit.record_source_version_event() — produsenten for INSERT
--
-- Samme mønster som audit.record_source_event() (007c),
-- audit.record_evidence_item_event() (007e) og
-- audit.record_evidence_verification_event() (005g): ikke SECURITY DEFINER, slik
-- at auditskriveren aldri er mer privilegert enn operasjonen den registrerer
-- (§35, §60). Hele raden er snapshotet.
--
-- Triggeren står på tabellen og ikke i funksjonen, av samme grunn som i 007c:
-- plikten skal ligge på INSERT, uansett hvilken skrivevei som senere fører dit.
-- Den er samtidig det som skiller en rad skrevet gjennom skriveveien fra de to
-- seedede: en kildeversjon med en auditrad er en kildeversjon databasen selv
-- hashet.
-- ----------------------------------------------------------------------------
create function audit.record_source_version_event()
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
    'source_version_registered'::audit.event_operation,
    new.id,
    new.retrieved_by_actor_id,
    null,
    to_jsonb(new),
    now()
  );

  return null;
end;
$$;

comment on function audit.record_source_version_event() is
  'Auditskriver for kildeversjonslaget: registrerer at et øyeblikksbilde av en kilde ble hentet og registrert, med hele raden som snapshot. Kjører med kallerens rettigheter, ikke som SECURITY DEFINER, slik at en auditrad aldri kan skrives av noen som ikke kunne utført operasjonen selv (samme begrunnelse som audit.record_source_event() og audit.record_evidence_item_event()).';

revoke execute on function audit.record_source_version_event() from public;

create trigger source_versions_record_registration_audit_event
  after insert on knowledge.source_versions
  for each row execute function audit.record_source_version_event();

-- ----------------------------------------------------------------------------
-- 5. knowledge.record_source_version(...) — innsettingen, ett sted
--
-- Skilt fra api-inngangspunktet med hensikt. Autorisasjonen er forskjellig for
-- en editor og for en senere agentidentitet, men *innsettingen* — hashingen,
-- kolonnene og oversettelsen av dubletten — er den samme, og to kopier av den
-- ville kunnet drive fra hverandre. Aktøren er en parameter her og ikke noe
-- funksjonen utleder: den er allerede avgjort av den autorisasjonen som slapp
-- kalleren inn, og en andre utledning ville vært en andre sannhet om hvem som
-- handler.
--
-- SECURITY INVOKER (standard), som knowledge.assert_editor_authorized(uuid): den
-- kalles alltid fra innsiden av en SECURITY DEFINER-funksjon og arver den
-- elevated konteksten derfra. Tomt search_path og schemakvalifiserte navn
-- likevel (§50), og ingen EXECUTE til PUBLIC.
-- ----------------------------------------------------------------------------
create function knowledge.record_source_version(
  p_source_id uuid,
  p_retrieved_at timestamptz,
  p_retrieved_from text,
  p_retrieved_content text,
  p_external_version text,
  p_storage_reference text,
  p_retrieved_by_actor_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_source_version_id uuid;
begin
  -- Innholdet er påkrevd fordi hashen er det. En tom representasjon ville gitt
  -- hashen av den tomme strengen, altså et fingeravtrykk som er likt for enhver
  -- kilde og derfor ikke identifiserer noe. Kontrollen er på fravær av innhold,
  -- ikke på formen: hva en representasjon *er*, avgjøres av kilden.
  if nullif(btrim(coalesce(p_retrieved_content, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Den hentede representasjonen mangler, og da kan ingen kildeversjon registreres.',
      hint = 'Oppgi innholdet nøyaktig slik det ble hentet fra adressen. Databasen beregner content_hash av det, og hashen er det som gjør versjonen etterprøvbar (ANTIDEP_CONSTITUTION.md §11).';
  end if;

  insert into knowledge.source_versions (
    source_id, retrieved_at, retrieved_from, external_version,
    content_hash, storage_reference, retrieved_by_actor_id
  )
  values (
    p_source_id,
    p_retrieved_at,
    p_retrieved_from,
    p_external_version,
    -- Ubeskåret innhold: btrim over er bare en tomhetskontroll, aldri en
    -- normalisering av det som hashes.
    knowledge.source_version_content_hash(p_retrieved_content),
    p_storage_reference,
    p_retrieved_by_actor_id
  )
  returning id into v_source_version_id;

  return v_source_version_id;
exception
  -- source_versions_source_content_key. Den eneste oversatte avvisningen, og
  -- samme resonnement som dubletten i api.create_evidence_item(...): dette er en
  -- forventet utgang av en riktig utfylt form — den samme representasjonen hentet
  -- en gang til — og databasens egen tekst navngir en mekanisme framfor å si hva
  -- som skjedde. At hashene er like, er dessuten et *resultat*: kilden er
  -- uendret siden sist, og det er nettopp det versjonsmodellen finnes for å
  -- kunne se.
  when unique_violation then
    raise exception using
      errcode = 'unique_violation',
      message = 'Nøyaktig samme innhold er allerede registrert som en kildeversjon for denne kilden.',
      hint = 'At hashen er lik betyr at kilden er uendret siden forrige henting. Bruk den registrerte versjonen framfor å lage en ny; en ny rad ville vært den samme observasjonen om igjen.';
end;
$$;

comment on function knowledge.record_source_version(uuid, timestamptz, text, text, text, text, uuid) is
  'Innsettingen av én kildeversjon, uten autorisasjon: hasher den hentede representasjonen med knowledge.source_version_content_hash(text), setter inn raden attribuert til aktøren kalleren oppgir, og returnerer versjonens id. Autorisasjonen ligger hos inngangspunktet som kaller den — api.create_source_version(uuid, timestamptz, text, text, text, text) for en editor — slik at en senere skrivevei med en annen autorisasjonsmodell kan gjenbruke innsettingen framfor å kopiere den. Kalles fra innsiden av en SECURITY DEFINER-funksjon og trenger derfor ikke være det selv. Avviser en tom representasjon, og oversetter dubletten til en setning på norsk uten å endre regelen.';

revoke execute on function knowledge.record_source_version(
  uuid, timestamptz, text, text, text, text, uuid
) from public;

-- ----------------------------------------------------------------------------
-- 6. api.create_source_version(...) — inngangspunktet for en editor
--
-- SECURITY DEFINER, tomt search_path, schemakvalifiserte navn, EXECUTE revokert
-- fra PUBLIC og gitt bare til authenticated — samme form som
-- api.create_source(...) og api.create_evidence_item(...).
--
-- content_hash og retrieved_by_actor_id er ikke parametre. Den første eies av
-- databasen (hodekommentaren), den andre utledes av auth.uid() gjennom
-- knowledge.assert_editor_authorized(uuid), av samme grunn som i 007c og 007e:
-- attribusjonen for en ny observasjon kan aldri være noe annet enn kallerens
-- egen aktør.
-- ----------------------------------------------------------------------------
create function api.create_source_version(
  p_source_id uuid,
  p_retrieved_at timestamptz,
  p_retrieved_from text,
  p_retrieved_content text,
  p_external_version text default null,
  p_storage_reference text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
begin
  -- Uten begrep: en kildeversjon er, som kilden selv, ikke avgrenset til noe
  -- klinisk begrep, og en avgrenset editor-tildeling er derfor tilstrekkelig
  -- (samme resonnement som api.create_source(...) i migrasjon 007c).
  v_actor_id := knowledge.assert_editor_authorized();

  return knowledge.record_source_version(
    p_source_id,
    p_retrieved_at,
    p_retrieved_from,
    p_retrieved_content,
    p_external_version,
    p_storage_reference,
    v_actor_id
  );
end;
$$;

comment on function api.create_source_version(uuid, timestamptz, text, text, text, text) is
  'Den kontrollerte skriveveien for å registrere en kildeversjon (DATABASE_ARCHITECTURE.md §18, §43, MVP_IMPLEMENTATION_PLAN.md §15, §74.30 punkt 1, issue #44). Kontrollerer at kalleren har en registrert, aktiv aktør og en gyldig editor-rolle (knowledge.assert_editor_authorized(uuid), kalt uten begrep), setter inn raden gjennom knowledge.record_source_version(uuid, timestamptz, text, text, text, text, uuid) attribuert til kallerens egen aktør, og returnerer versjonens id. content_hash er ikke en parameter: databasen beregner den av p_retrieved_content, slik at hashen aldri er en påstand kalleren skriver om seg selv — se hodekommentaren i migrasjonen for hele tillitsmodellen. p_retrieved_content er påkrevd; en versjon uten fingeravtrykk kvalifiserer ikke som verifiserbart grunnlag (§74.32). p_storage_reference er valgfritt og er den sterkere formen, en faktisk lagret kopi. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi knowledge.source_versions, workflow.user_roles og provenance.actors har RLS med default deny for authenticated; tomt search_path, og kalleren valideres på funksjonens eget kall (§50). Ingen feltvalidering er duplisert her: constraintene på knowledge.source_versions er fasiten, og deres avvisninger propageres uendret.';

revoke execute on function api.create_source_version(
  uuid, timestamptz, text, text, text, text
) from public;
grant execute on function api.create_source_version(
  uuid, timestamptz, text, text, text, text
) to authenticated;

-- ----------------------------------------------------------------------------
-- 7. Kolonne- og tabellkommentarene som nå beskriver noe annet
--
-- content_hash sin kommentar sa «sha256 av innholdet som ble hentet». Det er
-- fortsatt sant, men den sa ikke hvem som beregner den — og etter denne
-- migrasjonen er det et poeng, ikke en detalj (§57 om at kommentaren er
-- kontrakten).
-- ----------------------------------------------------------------------------
comment on column knowledge.source_versions.content_hash is
  'sha256 av innholdet som ble hentet, med algoritmen som prefiks. Beregnet av databasen selv når raden skrives gjennom api.create_source_version(uuid, timestamptz, text, text, text, text): hashen er aldri en verdi en klient oppgir, og kan derfor ikke være en garanti uten dekning. NULL betyr at det ikke ble hashet noe øyeblikksbilde — mulig for de seedede radene fra migrasjon 003, men ikke gjennom skriveveien. Uten hash er raden et sporet besøk og ikke en etterprøvbar representasjon (MVP_IMPLEMENTATION_PLAN.md §74.32).';

comment on table knowledge.source_versions is
  'Et hentet øyeblikksbilde av en kilde: hvilken representasjon som ble lest, når den ble hentet, av hvem, hvilken versjon kilden selv oppga, og hva innholdet hashet til. Gjør en ekstraksjon etterprøvbar og gjør det mulig å oppdage at en levende kilde har endret seg (DATABASE_ARCHITECTURE.md §18). retrieved_from og content_hash er sammen det verifikasjonsgrunnlaget workflow.verification_source_access kaller verifiable_representation: en tredjepart kan hente adressen på nytt og kontrollere svaret mot hashen. Raden er en observasjon og er uforanderlig; en ny henting med nytt innhold er en ny rad.';
