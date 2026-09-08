-- ============================================================================
-- Migrasjon 005j — claim-verifikasjonen får et grunnlag den kan håndheves på
--
-- Neste ledd i §15 etter ekstraksjonsverifikasjonen (§74.32-§74.34):
-- workflow.claim_verifications med sine sju kontrollpunkter finnes fra migrasjon
-- 005, og publiseringsgatens G8/G9 leser den — men det finnes ingen skrivevei
-- inn i den, ingen binding mot en agentkjøring, ingen registrering av *hva*
-- kontrollen faktisk så på, og ingen kontroll av at den som skrev raden hadde
-- mandat til det.
--
-- Denne migrasjonen bygger det grunnlaget. Selve inngangspunktet
-- api.register_claim_verification(...) ligger i 005k, av samme grunn som 005g og
-- 005h er atskilt: schemaendringen og flaten er to ting å reviewe.
--
-- Utvider proveniens-/workflowlaget fra migrasjon 005 og agentkjøringsmodellen
-- fra 005e, og står utenfor den planlagte rekken i MVP_IMPLEMENTATION_PLAN.md
-- §18-§27, og får derfor en bokstav. Nummeret 009 er fortsatt reservert for
-- DrugProduct-/importfundamentet (§26).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md
--     §4  enhver klinisk relevant påstand skal være etterprøvbar
--     §9  motstridende evidens skal bevares
--     §10 KI-arbeidet skal deles i eksplisitte roller
--     §11 verifikasjon skal forsøke å falsifisere, mot kildematerialet
--     §12 KI kan foreslå; mennesker har det faglige ansvaret
--     §14 endringer skal være attribuerte og reversible
--   docs/DATABASE_ARCHITECTURE.md
--     §21 knowledge.claim_evidence_links
--     §30 claim-verifikasjon
--     §33 provenance.agent_runs
--     §35-§36 audit.events og append-only
--     §43-§44 skriveveier og Data API-kontrakten
--     §48-§50 RLS, least privilege og privilegerte databasefunksjoner
--     §57 deklarative constraints først
--     §59 cross-row-regler løses med sammensatt fremmednøkkel
--     §60 god triggerbruk
--   docs/EVIDENCE_PIPELINE.md §39-§41 Citation-verifier, §61 agentroller,
--     §63 minst mulig privilegier
--   docs/CONTENT_GOVERNANCE.md §14 Agent Worker
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §42, §49, §74.30-§74.34
--
-- ----------------------------------------------------------------------------
-- De fire hullene denne migrasjonen lukker
--
-- 1. **Ingen binding til en agentkjøring.** Samme hull som 005g lukket for
--    ekstraksjonsverifikasjonen, med samme løsning: to kolonner og to
--    sammensatte fremmednøkler mot provenance.agent_runs (id, actor_id) og
--    (id, agent_role), slik at en agentprodusert rad ikke kan attribueres til
--    en annen aktør enn kjøringens egen, og ikke kan peke på en kjøring i en
--    annen rolle (§59).
--
-- 2. **Ingen registrering av hva kontrollen faktisk så på.** De sju
--    kontrollpunktene sier hva verifikatoren *konkluderte*, ikke hvilke
--    evidenslenker den gikk gjennom eller hvilken kilderepresentasjon den
--    kontrollerte dem mot. ANTIDEP_CONSTITUTION.md §11 krever at kontrollen
--    skjer mot kildematerialet og ikke mot et annet ledds sammendrag, og §4 at
--    en kilde som bare omhandler samme tema ikke godtas som støtte. Uten en rad
--    per kontrollert lenke er begge deler noe verifikatoren *sier*, ikke noe
--    basen kan se. workflow.claim_verification_citations er den raden.
--
-- 3. **Ingen kontroll av mandatet.** workflow.claim_verifications krevde bare at
--    verifikatoren var en annen aktør enn forfatteren. Enhver aktør — en
--    ekstraksjonsagent, en syntesagent, et menneske uten reviewer-rolle — kunne
--    registrere raden publiseringsgatens G9 leser. Rollen er rettighetsgrensen
--    (migrasjon 005e), og den håndheves nå på raden selv.
--
-- 4. **Ingen binding til evidenssettet kontrollen gjaldt.** En verifikasjon av
--    en påstand er en vurdering av påstanden *mot et bestemt grunnlag*. Kommer
--    det en lenke til etterpå, gjelder den ikke lenger det settet som ville blitt
--    publisert. Løsningen er den samme som migrasjon 006 valgte for
--    godkjenningen (avsnitt 5 der): et avtrykk av settet, eid av databasen, og
--    ikke en tidssammenligning — som ikke er samtidighetssikker, fordi now() er
--    transaksjonens starttidspunkt og ikke committidspunktet.
--
-- ----------------------------------------------------------------------------
-- Hvorfor dekningskontrollen er en utsatt constraint-trigger
--
-- «Verifikasjonen dekker hver lenke i settet» kan ikke være en CHECK: den leser
-- flere rader i en annen tabell (§59). Den kan heller ikke være en vanlig AFTER
-- INSERT-trigger på moderraden: barnradene refererer moderen og settes inn
-- etterpå, så en umiddelbar kontroll ville alltid sett null barn.
--
-- En `constraint trigger ... deferrable initially deferred` kjører derimot ved
-- commit, når begge deler finnes. Det er en av tverradsinvariantene §60 navngir
-- som legitim triggerbruk.
--
-- Prisen skal skrives ut framfor oppdages: en utsatt kontroll kjører ikke i en
-- transaksjon som rulles tilbake. Testfilene i supabase/tests kjører i én
-- transaksjon som avsluttes med `rollback`, så den ville aldri felt noe der.
-- Derfor kaller api.register_claim_verification(...) (migrasjon 005k) den samme
-- funksjonen eksplisitt på slutten av sitt eget kall: skriveveien avviser
-- umiddelbart og prøvbart, mens constraint-triggeren er garantien for enhver
-- annen vei inn i tabellen. Regelen er skrevet én gang,
-- workflow.assert_claim_verification_complete(uuid), og kalles fra begge.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. audit.events utvides til å kunne peke på workflow.claim_verifications
--
-- Samme ombygging som 005e, 007c, 007e og 005g måtte gjøre, og av samme grunn:
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
    when 'claim_verification_registered' then 'workflow'
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
      -- En opprettelse, som de øvrige registreringene:
      -- workflow.claim_verifications er append-only, så raden kan aldri få et
      -- old-snapshot i ettertid.
      when 'claim_verification_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      else false
    end
  );

-- ----------------------------------------------------------------------------
-- 2. Refererbare nøkler for de sammensatte fremmednøklene i avsnitt 4
--
-- Ingen av dem endrer hva som er lovlig i tabellene de ligger på: kolonnen som
-- står først er allerede primærnøkkelen, så paret er unikt av seg selv. De
-- finnes utelukkende for at en annen tabell skal kunne kreve deklarativt at to
-- verdier hører sammen (DATABASE_ARCHITECTURE.md §59) — samme mønster som
-- claim_revisions_id_claim_key og actors_id_type_key i migrasjon 004 og 005.
-- ----------------------------------------------------------------------------
alter table knowledge.claim_evidence_links
  add constraint claim_evidence_links_id_revision_key unique (id, claim_revision_id),
  add constraint claim_evidence_links_id_item_key unique (id, evidence_item_id);

comment on constraint claim_evidence_links_id_revision_key on knowledge.claim_evidence_links is
  'Gjør (id, claim_revision_id) refererbar, slik at en claim-verifikasjons kontrollrad kan kreve deklarativt at lenken den viser til faktisk tilhører den revisjonen som ble kontrollert.';
comment on constraint claim_evidence_links_id_item_key on knowledge.claim_evidence_links is
  'Gjør (id, evidence_item_id) refererbar, slik at en kontrollrad ikke kan påstå å ha kontrollert lenke L mot et annet evidensfunn enn det L faktisk peker på.';

alter table knowledge.evidence_items
  add constraint evidence_items_id_source_version_key unique (id, source_version_id);

comment on constraint evidence_items_id_source_version_key on knowledge.evidence_items is
  'Gjør (id, source_version_id) refererbar, slik at en claim-verifikasjons kontrollrad kan kreve deklarativt at kildeversjonen den oppgir å ha kontrollert mot, er nettopp den evidensfunnet er lest ut av — ikke en annen versjon av samme kilde.';

alter table knowledge.source_versions
  add constraint source_versions_id_content_hash_key unique (id, content_hash);

comment on constraint source_versions_id_content_hash_key on knowledge.source_versions is
  'Gjør (id, content_hash) refererbar, slik at en kontrollrad ikke kan oppgi et annet fingeravtrykk enn det som faktisk er registrert på kildeversjonen. Uten det ville «jeg kontrollerte denne representasjonen» vært en påstand uten feste.';

alter table workflow.claim_verifications
  add constraint claim_verifications_id_revision_key unique (id, claim_revision_id);

comment on constraint claim_verifications_id_revision_key on workflow.claim_verifications is
  'Gjør (id, claim_revision_id) refererbar, slik at en kontrollrad ikke kan høre til én verifikasjon og samtidig vise til en lenke fra en annen revisjon.';

-- ----------------------------------------------------------------------------
-- 3. workflow.claim_verifications får agentkjøringsbinding og evidenssettavtrykk
-- ----------------------------------------------------------------------------
alter table workflow.claim_verifications
  add column agent_run_id uuid,
  add column agent_run_role provenance.agent_role
    generated always as ('citation_support_verification'::provenance.agent_role) stored,
  add column verified_evidence_set_digest text;

comment on column workflow.claim_verifications.agent_run_id is
  'Agentkjøringen som produserte denne verifikasjonen (provenance.agent_runs), når verifikatoren er en agent. NULL for en verifikasjon et menneske registrerer gjennom en reviewer-flyt — den skriveveien finnes ikke ennå, men kolonnen skal ikke tvinge fram en agentkjøring for et pipelineledd som per definisjon også kan gjøres av et menneske (MVP_IMPLEMENTATION_PLAN.md §74.31). Når satt, låser claim_verifications_agent_run_actor_fkey og claim_verifications_agent_run_role_fkey deklarativt at kjøringen faktisk tilhører verifikator-aktøren og faktisk kjørte i rollen citation_support_verification (DATABASE_ARCHITECTURE.md §59); at kjøringen fortsatt var åpen da raden ble skrevet, kontrolleres av provenance.assert_agent_run_open(uuid, uuid) i skriveveien, fordi «åpen» er en egenskap ved tidspunktet og ikke noe en fremmednøkkel kan uttrykke.';
comment on column workflow.claim_verifications.agent_run_role is
  'Konstant «citation_support_verification». Finnes bare for å kunne uttrykke, med en sammensatt fremmednøkkel mot provenance.agent_runs (id, agent_role), at en agentkjøring denne raden peker på faktisk hadde den rollen: tabellen registrerer ingen annen type verifikasjon enn kontroll av en påstand mot grunnlaget. Ikke en egenskap ved den enkelte raden — verdien er alltid den samme.';
comment on column workflow.claim_verifications.verified_evidence_set_digest is
  'Fingeravtrykk av evidenssettet til revisjonen slik det var registrert da kontrollen ble lagret (knowledge.claim_evidence_set_digest). Eid av databasen, ikke av kalleren: var det kallerstyrt, kunne den som registrerer kontrollen oppgi avtrykket av et annet sett enn det som fantes. Publiseringsgaten sammenligner det med settet ved publisering og nekter dersom grunnlaget er utvidet etter kontrollen — en kontroll av et smalere grunnlag er ikke en kontroll av det som ville blitt publisert (KNOWLEDGE_MODEL.md §19.2). Erstatter en tidssammenligning, som ikke er samtidighetssikker.';

alter table workflow.claim_verifications
  add constraint claim_verifications_agent_run_actor_fkey
    foreign key (agent_run_id, verifier_actor_id)
    references provenance.agent_runs (id, actor_id)
    on update restrict on delete restrict,
  add constraint claim_verifications_agent_run_role_fkey
    foreign key (agent_run_id, agent_run_role)
    references provenance.agent_runs (id, agent_role)
    on update restrict on delete restrict,
  add constraint claim_verifications_evidence_set_digest_format_check
    check (verified_evidence_set_digest ~ '^sha256-v[0-9]+:[0-9a-f]{64}$');

-- Egen setning framfor `add column ... not null`: kolonnen fylles av triggeren i
-- avsnitt 5, og NOT NULL kontrolleres etter BEFORE-triggerne. Skulle tabellen mot
-- formodning ha rader fra før, feiler denne setningen synlig framfor å la et
-- avtrykk stå tomt på en rad publiseringsgaten leser.
alter table workflow.claim_verifications
  alter column verified_evidence_set_digest set not null;

comment on constraint claim_verifications_agent_run_actor_fkey
  on workflow.claim_verifications is
  'Når agent_run_id er satt, må agentkjøringen faktisk tilhøre nøyaktig den aktøren raden attribueres til (verifier_actor_id). Sammen med agent_identity_id sine egne fremmednøkler på provenance.agent_runs (migrasjon 005e) gjør dette det umulig å attribuere en claim-verifikasjon til en aktør som ikke faktisk utførte kjøringen.';
comment on constraint claim_verifications_agent_run_role_fkey
  on workflow.claim_verifications is
  'Når agent_run_id er satt, må agentkjøringen faktisk ha kjørt i rollen citation_support_verification. Låser rettighetsgrensen på raden selv, framfor at kravet bare finnes i skriveveiens funksjonskode, som en senere skrivevei kunne glemme (DATABASE_ARCHITECTURE.md §59).';

create index claim_verifications_agent_run_id_idx
  on workflow.claim_verifications (agent_run_id);

-- ----------------------------------------------------------------------------
-- 4. workflow.claim_verification_citations — hva kontrollen faktisk så på
--
-- Én rad per evidenslenke verifikatoren gikk gjennom. Uten den er «kontrollert
-- mot grunnlaget» noe raden påstår; med den er det noe basen kan lese, og de tre
-- viktigste delene av påstanden er låst deklarativt:
--
--   * lenken hører til den kontrollerte revisjonen  (id, claim_revision_id)
--   * evidensfunnet er lenkens eget                 (id, evidence_item_id)
--   * kildeversjonen er funnets egen                (id, source_version_id)
--   * fingeravtrykket er kildeversjonens registrerte (id, content_hash)
--
-- Den siste er den som gjør ANTIDEP_CONSTITUTION.md §11 maskinelt kontrollerbar
-- for dette leddet: en rad som sier `verifiable_representation` må navngi
-- nøyaktig det fingeravtrykket kildeversjonen er registrert med, og et
-- fingeravtrykk verifikatoren fant på ville blitt avvist av fremmednøkkelen.
--
-- Relasjonstypen speiles bevisst *ikke* inn hit. knowledge.claim_evidence_links
-- er append-only og uforanderlig, så lenke-id-en peker alltid på den samme
-- stance-verdien; en speilkolonne ville låst noe som allerede er låst.
-- relationship_supported sier om den registrerte relasjonstypen holder
-- (EVIDENCE_PIPELINE.md §40), og not_assessable er ikke det samme som ok: et
-- punkt som ikke lot seg bedømme er nettopp den usikkerheten §11 skal fram i
-- lyset.
-- ----------------------------------------------------------------------------
create table workflow.claim_verification_citations (
  id uuid primary key default gen_random_uuid(),

  claim_verification_id uuid not null
    references workflow.claim_verifications (id) on update restrict on delete restrict,
  claim_revision_id uuid not null,
  claim_evidence_link_id uuid not null
    references knowledge.claim_evidence_links (id) on update restrict on delete restrict,
  evidence_item_id uuid not null,

  source_access workflow.verification_source_access not null,
  source_version_id uuid,
  checked_content_hash text,

  relationship_supported workflow.verification_check_result not null,
  finding text,
  created_at timestamptz not null default now(),

  -- Samme lenke kan ikke kontrolleres to ganger i samme verifikasjon: to rader
  -- ville kunnet si hver sin ting om det samme, og dekningskontrollen ville
  -- talt dem som to.
  constraint claim_verification_citations_verification_link_key
    unique (claim_verification_id, claim_evidence_link_id),

  constraint claim_verification_citations_verification_fkey
    foreign key (claim_verification_id, claim_revision_id)
    references workflow.claim_verifications (id, claim_revision_id)
    on update restrict on delete restrict,
  constraint claim_verification_citations_link_revision_fkey
    foreign key (claim_evidence_link_id, claim_revision_id)
    references knowledge.claim_evidence_links (id, claim_revision_id)
    on update restrict on delete restrict,
  constraint claim_verification_citations_link_item_fkey
    foreign key (claim_evidence_link_id, evidence_item_id)
    references knowledge.claim_evidence_links (id, evidence_item_id)
    on update restrict on delete restrict,
  constraint claim_verification_citations_source_version_fkey
    foreign key (evidence_item_id, source_version_id)
    references knowledge.evidence_items (id, source_version_id)
    on update restrict on delete restrict,
  constraint claim_verification_citations_content_hash_fkey
    foreign key (source_version_id, checked_content_hash)
    references knowledge.source_versions (id, content_hash)
    on update restrict on delete restrict,

  -- Adressen og fingeravtrykket hører sammen: et fingeravtrykk uten en
  -- kildeversjon å høre til er ikke etterprøvbart, og en kildeversjon uten
  -- fingeravtrykk er et sporet besøk (§74.32).
  constraint claim_verification_citations_representation_pairing_check
    check ((source_version_id is null) = (checked_content_hash is null)),
  constraint claim_verification_citations_verifiable_requires_hash_check
    check (source_access <> 'verifiable_representation' or source_version_id is not null),
  -- Et sammendrag laget av et annet ledd er per definisjon ikke kildeversjonens
  -- registrerte representasjon. Å oppgi begge deler ville vært å si to ting.
  constraint claim_verification_citations_derived_summary_check
    check (source_access <> 'derived_summary' or source_version_id is null),

  constraint claim_verification_citations_finding_required_check
    check (relationship_supported = 'ok'
           or (finding is not null and btrim(finding) <> '')),
  constraint claim_verification_citations_finding_format_check
    check (finding is null
           or (finding = btrim(finding) and length(finding) between 1 and 4000)),
  constraint claim_verification_citations_content_hash_format_check
    check (checked_content_hash is null or checked_content_hash ~ '^sha256:[0-9a-f]{64}$')
);

comment on table workflow.claim_verification_citations is
  'Hva en claim-verifikasjon faktisk gikk gjennom: én rad per evidenslenke, med kildegrunnlaget kontrollen hadde for nettopp den lenken og om den registrerte relasjonstypen holder (EVIDENCE_PIPELINE.md §39-§41, ANTIDEP_CONSTITUTION.md §4, §11). Sammen med workflow.assert_claim_verification_complete(uuid) er dette det som gjør at en bekreftelse ikke kan dekke mindre enn den gir inntrykk av. Raden er append-only.';
comment on column workflow.claim_verification_citations.claim_revision_id is
  'Speil av revisjonen, låst av to sammensatte fremmednøkler: mot verifikasjonen og mot lenken. Finnes for at en kontrollrad ikke skal kunne høre til én revisjons verifikasjon og vise til en annen revisjons lenke. Ikke en selvstendig sannhet.';
comment on column workflow.claim_verification_citations.evidence_item_id is
  'Speil av evidensfunnet lenken peker på, låst av claim_verification_citations_link_item_fkey. Finnes for at kildeversjonen under skal kunne kreves å være nettopp dette funnets egen. Ikke en selvstendig sannhet.';
comment on column workflow.claim_verification_citations.source_access is
  'Hva verifikatoren faktisk hadde tilgang til for denne lenken (ANTIDEP_CONSTITUTION.md §11). Verdien gjelder én lenke; verifikasjonsradens egen source_access er den svakeste av dem, slik at en samlet påstand aldri er sterkere enn det svakeste leddet den hviler på.';
comment on column workflow.claim_verification_citations.source_version_id is
  'Kildeversjonen kontrollen faktisk ble gjort mot. Må være den evidensfunnet er lest ut av, håndhevet deklarativt. NULL når verifikatoren ikke hadde en registrert representasjon for denne lenken.';
comment on column workflow.claim_verification_citations.checked_content_hash is
  'Fingeravtrykket verifikatoren kontrollerte representasjonen mot. Må være det kildeversjonen faktisk er registrert med, håndhevet av claim_verification_citations_content_hash_fkey: en verdi verifikatoren fant på, ville blitt avvist. Det er dette som gjør «kontrollert mot en etterprøvbar representasjon» til noe basen kan se framfor noe raden påstår.';
comment on column workflow.claim_verification_citations.relationship_supported is
  'Om den registrerte relasjonstypen på lenken faktisk holder mot kilden (EVIDENCE_PIPELINE.md §40). not_assessable er ikke ok: en kilde som bare omhandler samme tema er ikke støtte, og et punkt som ikke lot seg bedømme er ikke et bestått punkt (ANTIDEP_CONSTITUTION.md §4, §6).';
comment on column workflow.claim_verification_citations.finding is
  'Hva kontrollen fant for denne lenken. Påkrevd når relationship_supported ikke er ok.';

create index claim_verification_citations_verification_id_idx
  on workflow.claim_verification_citations (claim_verification_id);
create index claim_verification_citations_link_id_idx
  on workflow.claim_verification_citations (claim_evidence_link_id);
create index claim_verification_citations_evidence_item_id_idx
  on workflow.claim_verification_citations (evidence_item_id);

alter table workflow.claim_verification_citations enable row level security;

create trigger claim_verification_citations_set_created_at
  before insert on workflow.claim_verification_citations
  for each row execute function catalog.set_created_at();

create trigger claim_verification_citations_reject_mutation
  before update or delete on workflow.claim_verification_citations
  for each row execute function knowledge.reject_append_only_mutation(
    'Registrer en ny claim-verifikasjon med sine egne kontrollrader. Hva en kontroll faktisk gikk gjennom, dokumenterer hva verifikatoren så på det tidspunktet, og skal verken overskrives eller slettes.'
  );

-- ----------------------------------------------------------------------------
-- 5. Avtrykket av evidenssettet eies av databasen
--
-- Samme mekanisme og samme begrunnelse som workflow.set_review_evidence_set_digest()
-- i migrasjon 006, avsnitt 5: radlås på revisjonen mens avtrykket beregnes, slik
-- at en lenke ikke kan committe i vinduet og avtrykket beskrive et sett som aldri
-- fantes samtidig.
-- ----------------------------------------------------------------------------
create function workflow.set_claim_verification_evidence_set_digest()
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

  new.verified_evidence_set_digest :=
    knowledge.claim_evidence_set_digest(new.claim_revision_id);

  return new;
end;
$$;

comment on function workflow.set_claim_verification_evidence_set_digest() is
  'Gir databasen eierskap til fingeravtrykket av evidenssettet en claim-verifikasjon gjelder, og låser revisjonsraden mens det beregnes slik at settet ikke kan endres i vinduet. SECURITY DEFINER fordi evidenslenkene ligger bak RLS med default deny; funksjonen leser bare og skriver bare til raden som settes inn.';

revoke execute on function workflow.set_claim_verification_evidence_set_digest() from public;

-- ----------------------------------------------------------------------------
-- 6. Mandatet: hvem som i det hele tatt kan kontrollere en påstand
--
-- workflow.app_role definerer `reviewer` som «faglig verifikasjon» (migrasjon
-- 001), og §74.30 punkt 3 avgjorde at det er den rollen et menneske verifiserer
-- med — ikke en ny. For en agent er mandatet rollen på aktøren, som er selve
-- rettighetsgrensen (migrasjon 005e): citation_support_verification og ingen
-- annen.
--
-- Regelen ligger i sin egen boolske funksjon framfor bare i triggeren, fordi
-- publiseringsgaten stiller nøyaktig det samme spørsmålet om den gjeldende
-- verifikasjonen (G9c i migrasjonen etter denne). To formuleringer av samme
-- regel ville kunnet komme i utakt, og da ville gaten sluppet gjennom nøyaktig
-- det triggeren stengte, eller omvendt.
--
-- Tidspunktet er radens eget verified_at, ikke now(): en rolletildeling som
-- senere avsluttes, opphever ikke en kontroll som var legitim da den ble gjort
-- (ANTIDEP_CONSTITUTION.md §14 — historikken består). Kravet om at
-- tildelingsraden fantes senest da, er det samme som
-- workflow.enforce_reviewer_qualification() bruker, og av samme grunn: en
-- tilbakedatert valid_from skal ikke kunne konstruere gyldighet i etterkant.
-- ----------------------------------------------------------------------------
create function workflow.claim_verifier_has_mandate(
  p_verifier_actor_id uuid,
  p_claim_revision_id uuid,
  p_at timestamptz
)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_actor_type provenance.actor_type;
  v_agent_role provenance.agent_role;
  v_auth_user_id uuid;
  v_topic_concept_id uuid;
begin
  select a.actor_type, a.agent_role, a.auth_user_id
    into v_actor_type, v_agent_role, v_auth_user_id
  from provenance.actors a
  where a.id = p_verifier_actor_id;

  if not found then
    return false;
  end if;

  -- En agent har mandatet gjennom rollen sin, og bare gjennom den.
  if v_actor_type = 'agent' then
    return v_agent_role = 'citation_support_verification';
  end if;

  -- Et menneske har det gjennom en gyldig reviewer-tildeling for
  -- innholdsområdet. Ingen annen aktørtype kan kontrollere en påstand: en
  -- deterministisk prosess, en import eller en systemaktør har ingen faglig
  -- vurdering å registrere (ANTIDEP_CONSTITUTION.md §12).
  if v_actor_type <> 'human' or v_auth_user_id is null then
    return false;
  end if;

  select cl.topic_concept_id into v_topic_concept_id
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  where r.id = p_claim_revision_id;

  return exists (
    select 1
    from workflow.user_roles ur
    where ur.user_id = v_auth_user_id
      and ur.role_code = 'reviewer'
      and ur.created_at <= p_at
      and ur.valid_from <= p_at
      and (ur.valid_to is null or ur.valid_to > p_at)
      and (ur.scope_id is null or ur.scope_id = v_topic_concept_id)
  );
end;
$$;

comment on function workflow.claim_verifier_has_mandate(uuid, uuid, timestamptz) is
  'Om aktøren hadde mandat til å kontrollere denne påstandsrevisjonen mot grunnlaget på det oppgitte tidspunktet: en agent i rollen citation_support_verification, eller et menneske med gyldig reviewer-rolle for revisjonens innholdsområde (EVIDENCE_PIPELINE.md §39, §61, ANTIDEP_CONSTITUTION.md §10, §12, MVP_IMPLEMENTATION_PLAN.md §74.30 punkt 3). Regelen står ett sted fordi den håndheves to steder: ved innsetting av raden, og i publiseringsgaten på den gjeldende verifikasjonen. Rollen leses fra workflow.user_roles og aldri fra en JWT-claim (DATABASE_ARCHITECTURE.md §46). SECURITY DEFINER fordi både aktørregisteret og medlemskapsmodellen har RLS med default deny; funksjonen leser bare og returnerer ingen data.';

revoke execute on function workflow.claim_verifier_has_mandate(uuid, uuid, timestamptz) from public;

create function workflow.enforce_claim_verifier_mandate()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if not workflow.claim_verifier_has_mandate(
       new.verifier_actor_id, new.claim_revision_id, new.verified_at
     ) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Verifikatoraktøren hadde ikke mandat til å kontrollere denne påstanden mot grunnlaget.',
      hint = 'Sitat- og kildestøtteverifikasjon er et eget agentmandat (ANTIDEP_CONSTITUTION.md §10): en agent må ha rollen citation_support_verification, og et menneske må ha gyldig reviewer-rolle for revisjonens innholdsområde på verified_at, med en tildelingsrad som fantes senest da. En ekstraksjonsagent, en synteseagent eller en bruker uten reviewer-rolle kan ikke registrere raden publiseringsgaten leser.';
  end if;

  return new;
end;
$$;

comment on function workflow.enforce_claim_verifier_mandate() is
  'Tverradsinvariant: krever at en claim-verifikasjon kommer fra en aktør med mandatet til det (workflow.claim_verifier_has_mandate(uuid, uuid, timestamptz)). Uten den kunne enhver aktør som ikke tilfeldigvis var forfatteren, skrive raden publiseringsgatens G9 leser. Ikke SECURITY DEFINER: den kaller en funksjon som er det, og skal ikke selv være mer privilegert enn operasjonen den kontrollerer.';

revoke execute on function workflow.enforce_claim_verifier_mandate() from public;

-- Begge er BEFORE INSERT, og PostgreSQL fyrer dem i alfabetisk rekkefølge.
-- Rekkefølgen er likegyldig her: mandatkontrollen leser verified_at, som
-- kalleren oppgir, og avtrykket leser evidenslenkene. Ingen av dem avhenger av
-- den andres resultat.
create trigger claim_verifications_set_evidence_set_digest
  before insert on workflow.claim_verifications
  for each row execute function workflow.set_claim_verification_evidence_set_digest();

create trigger claim_verifications_enforce_verifier_mandate
  before insert on workflow.claim_verifications
  for each row execute function workflow.enforce_claim_verifier_mandate();

-- ----------------------------------------------------------------------------
-- 7. Fullstendighet: en kontroll som ikke dekker settet, er ingen kontroll av det
--
-- Tre krav, alle om forholdet mellom moderraden og kontrollradene:
--
--   a) Hver evidenslenke på revisjonen er kontrollert, og minst én finnes.
--      ANTIDEP_CONSTITUTION.md §4 og §9: en påstand hviler på hele grunnlaget
--      sitt, også den delen som motsier den. En kontroll som hoppet over en
--      lenke, ville bekreftet påstanden uten å ha sett det som kunne felt den.
--   b) En bekreftelse forutsetter at hver enkelt lenke holder. Samme regel som
--      claim_verifications_verified_requires_all_ok_check gjør for de sju
--      kontrollpunktene, på det andre nivået.
--   c) Verifikasjonsradens source_access er den svakeste av kontrollradenes.
--      Ellers kunne en samlet «original_source» hvile på en lenke der
--      verifikatoren bare hadde et sammendrag — og §11 sitt forbud mot å
--      godkjenne på andre agenters sammendrag ville vært omgåelig ved å
--      aggregere.
--
-- Se hodekommentaren for hvorfor dette er en utsatt constraint-trigger, og
-- hvorfor skriveveien i tillegg kaller funksjonen direkte.
-- ----------------------------------------------------------------------------
create function workflow.source_access_strength(p_access workflow.verification_source_access)
  returns integer
  language sql
  immutable
  set search_path = ''
as $$
  select case p_access
    when 'derived_summary' then 1
    when 'verifiable_representation' then 2
    when 'original_source' then 3
  end;
$$;

comment on function workflow.source_access_strength(workflow.verification_source_access) is
  'Rangerer kildetilgangene fra svakest til sterkest, slik at «den svakeste av flere» kan uttrykkes i SQL. Uttømmende over vokabularet: en ny verdi uten gren gir NULL og feiler synlig framfor å bli sortert vilkårlig.';

revoke execute on function workflow.source_access_strength(workflow.verification_source_access) from public;

create function workflow.assert_claim_verification_complete(p_claim_verification_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_revision_id uuid;
  v_outcome workflow.verification_outcome;
  v_source_access workflow.verification_source_access;
  v_citations integer;
  v_uncovered text;
  v_weakest workflow.verification_source_access;
  v_offending text;
begin
  select cv.claim_revision_id, cv.outcome, cv.source_access
    into v_revision_id, v_outcome, v_source_access
  from workflow.claim_verifications cv
  where cv.id = p_claim_verification_id;

  if not found then
    return;
  end if;

  select count(*) into v_citations
  from workflow.claim_verification_citations c
  where c.claim_verification_id = p_claim_verification_id;

  if v_citations = 0 then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Claim-verifikasjon %L oppgir ikke hvilke evidenslenker den kontrollerte.',
        p_claim_verification_id
      ),
      hint = 'En kontroll av en påstand er en kontroll mot et bestemt grunnlag. Registrer én rad i workflow.claim_verification_citations per evidenslenke på revisjonen (ANTIDEP_CONSTITUTION.md §4, §11).';
  end if;

  select string_agg(distinct l.id::text, ', ' order by l.id::text)
    into v_uncovered
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = v_revision_id
    and not exists (
      select 1
      from workflow.claim_verification_citations c
      where c.claim_verification_id = p_claim_verification_id
        and c.claim_evidence_link_id = l.id
    );

  if v_uncovered is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Evidenslenker som ikke er kontrollert: %s.', v_uncovered),
      hint = 'Kontrollen skal dekke hele evidenssettet til revisjonen, også lenkene som motsier påstanden (ANTIDEP_CONSTITUTION.md §9). En kontroll som hoppet over en lenke, har ikke sett det som kunne felt påstanden.';
  end if;

  if v_outcome = 'verified' then
    select string_agg(distinct c.claim_evidence_link_id::text, ', '
                      order by c.claim_evidence_link_id::text)
      into v_offending
    from workflow.claim_verification_citations c
    where c.claim_verification_id = p_claim_verification_id
      and c.relationship_supported <> 'ok';

    if v_offending is not null then
      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'En bekreftet claim-verifikasjon kan ikke ha uavklarte eller avvikende evidenslenker: %s.',
          v_offending
        ),
        hint = 'Samme regel som for de sju kontrollpunktene: et punkt som ikke lot seg bedømme er ikke et bestått punkt (ANTIDEP_CONSTITUTION.md §6, §11). Registrer utfallet som uncertain eller needs_correction.';
    end if;
  end if;

  select c.source_access into v_weakest
  from workflow.claim_verification_citations c
  where c.claim_verification_id = p_claim_verification_id
  order by workflow.source_access_strength(c.source_access), c.source_access
  limit 1;

  if v_weakest is distinct from v_source_access then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Claim-verifikasjonens kildetilgang er %L, men den svakeste kontrollerte lenken har %L.',
        v_source_access, v_weakest
      ),
      hint = 'Den samlede kildetilgangen er den svakeste av lenkenes, ikke den sterkeste. Ellers ville en bekreftelse kunnet hvile på en lenke der verifikatoren bare hadde et sammendrag (ANTIDEP_CONSTITUTION.md §11).';
  end if;
end;
$$;

comment on function workflow.assert_claim_verification_complete(uuid) is
  'Kontrollerer at en claim-verifikasjon dekker hele evidenssettet til revisjonen, at en bekreftelse ikke har uavklarte eller avvikende lenker under seg, og at radens kildetilgang er den svakeste av lenkenes (ANTIDEP_CONSTITUTION.md §4, §9, §11). Kalles to steder: av constraint-triggeren claim_verifications_assert_complete ved commit, som er garantien uansett hvordan raden kom dit, og direkte av api.register_claim_verification(text, text, uuid, uuid, text, text, text, text, text, text, text, text, jsonb, text, text), slik at skriveveien avviser umiddelbart og kan prøves i en transaksjon som rulles tilbake. Ikke SECURITY DEFINER: den kalles fra en trigger på tabellen og fra en SECURITY DEFINER-funksjon, og skal ikke selv gi lesetilgang til noen som ikke allerede har den.';

revoke execute on function workflow.assert_claim_verification_complete(uuid) from public;

create function workflow.assert_claim_verification_complete_trigger()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  perform workflow.assert_claim_verification_complete(new.id);
  return null;
end;
$$;

comment on function workflow.assert_claim_verification_complete_trigger() is
  'Triggerinnpakningen rundt workflow.assert_claim_verification_complete(uuid). Egen funksjon fordi regelen også kalles direkte fra skriveveien, og en regel skrevet to ganger er en regel som kan komme i utakt.';

revoke execute on function workflow.assert_claim_verification_complete_trigger() from public;

create constraint trigger claim_verifications_assert_complete
  after insert on workflow.claim_verifications
  deferrable initially deferred
  for each row execute function workflow.assert_claim_verification_complete_trigger();

-- ----------------------------------------------------------------------------
-- 8. audit.record_claim_verification_event() — produsenten for INSERT
--
-- Samme mønster som audit.record_evidence_verification_event() (migrasjon 005g):
-- ikke SECURITY DEFINER, slik at auditskriveren aldri er mer privilegert enn
-- operasjonen den registrerer (§35, §60). Hele moderraden er snapshotet;
-- workflow.claim_verifications er append-only og har ingen egen hendelsestabell
-- under seg.
--
-- Kontrollradene er bevisst ikke med i snapshotet: triggeren fyrer før de er
-- satt inn, og de er selv append-only rader som peker på object_id. Å utsette
-- auditskrivingen til commit for å få dem med, ville gjort loggen avhengig av
-- transaksjonsrekkefølgen for å bli skrevet i det hele tatt.
-- ----------------------------------------------------------------------------
create function audit.record_claim_verification_event()
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
    'claim_verification_registered'::audit.event_operation,
    new.id,
    new.verifier_actor_id,
    null,
    to_jsonb(new),
    now()
  );

  return null;
end;
$$;

comment on function audit.record_claim_verification_event() is
  'Auditskriver for claim-verifikasjonslaget: registrerer at en kontroll av en påstand mot grunnlaget ble registrert, med hele raden som snapshot. Kjører med kallerens rettigheter, ikke som SECURITY DEFINER, slik at en auditrad aldri kan skrives av noen som ikke kunne utført operasjonen selv (samme begrunnelse som audit.record_evidence_verification_event()).';

revoke execute on function audit.record_claim_verification_event() from public;

create trigger claim_verifications_record_creation_audit_event
  after insert on workflow.claim_verifications
  for each row execute function audit.record_claim_verification_event();
