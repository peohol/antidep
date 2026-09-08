-- Migrasjon 005 — immutabilitet i workflow og provenance.
--
-- ANTIDEP_CONSTITUTION.md §14 krever at endringer er attribuerte og
-- rapporterbare, og DATABASE_ARCHITECTURE.md §31 og §36 krever at
-- godkjenninger, avslag og senere omgjøringer bevares side om side framfor at
-- historikk overskrives.
--
-- Valgt strategi:
--   * workflow.evidence_verifications, claim_verifications og review_decisions
--     er append-only. En ny vurdering er en ny rad.
--   * provenance.actors har per-kolonne frys på identiteten, fordi visningsnavn
--     og tilbaketrekking må kunne endres.
--   * workflow.user_roles har per-kolonne frys på selve tildelingen, mens
--     avslutningen kan skrives nøyaktig én gang.
--   * knowledge.claims sitt opphav er frosset sammen med identiteten.
--
-- Testen kontrollerer både at vernet holder og at det ikke overblokkerer.
--
-- SQLSTATE 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(32);

-- ---------------------------------------------------------------------------
-- Testdata som bare finnes inne i denne transaksjonen
-- ---------------------------------------------------------------------------
create function pg_temp.actor(key text) returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = key
$$;

insert into auth.users (id, email)
values (gen_random_uuid(), 'immutabilitet@test.invalid'),
       (gen_random_uuid(), 'senkobling@test.invalid');

insert into provenance.actors
  (actor_type, actor_key, display_name, description, auth_user_id, agent_role)
values
  ('system', 'system:immutabilitet', 'Testsystemaktør',
   'Systemaktør for immutabilitetstestene.', null, null),
  ('agent', 'agent:immutabilitet', 'Testverifikator',
   'KI-aktør i kontrollrollen for immutabilitetstestene.', null, 'adversarial_review'),
  -- Claim-verifikasjonen krever mandatet fra migrasjon 005j, og for en agent er
  -- mandatet rollen citation_support_verification.
  ('agent', 'agent:citation-immutabilitet', 'Test claim-verifikator',
   'KI-aktør i sitat- og kildestøtterollen for immutabilitetstestene.', null,
   'citation_support_verification'),
  ('human', 'human:senkobling', 'Test Senkoblet',
   'Menneskelig aktør som får brukerkonto etter at aktøren ble opprettet.', null, null);

-- valid_from settes eksplisitt bakover i tid. Inne i én transaksjon gir now()
-- samme tidspunkt hele veien, og en tilbakekalling ville da fått
-- valid_to = valid_from, som DATABASE_ARCHITECTURE.md §58 avviser som et tomt
-- intervall.
insert into workflow.user_roles
  (user_id, role_code, granted_by_actor_id, grant_reason, valid_from)
select id, 'reviewer', pg_temp.actor('system:immutabilitet'),
       'Testtildeling for immutabilitetstestene.', timestamptz '2026-08-01T00:00:00Z'
from auth.users where email = 'immutabilitet@test.invalid';

insert into workflow.evidence_verifications (
  evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
  outcome, source_access, checked_fields, rationale, verified_at
)
select e.id, e.created_by_actor_id, pg_temp.actor('agent:immutabilitet'),
       'verified', 'original_source',
       array['source_locator', 'estimate']::workflow.evidence_check_field[],
       'Testkontroll av ekstraksjonen.', now()
from knowledge.evidence_items e
join catalog.drugs d on d.id = e.intervention_drug_id
where d.canonical_name = 'sertralin';

insert into workflow.claim_verifications (
  claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id,
  outcome, source_access,
  source_support, population_match, comparator_match, timeframe_match,
  direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
  rationale, verified_at
)
select r.id, r.created_by_actor_id, pg_temp.actor('agent:citation-immutabilitet'),
       'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Testkontroll av påstanden.', now()
from knowledge.claim_revisions r
join knowledge.claims cl on cl.id = r.claim_id
join catalog.drugs d on d.id = cl.subject_drug_id
where d.canonical_name = 'sertralin';

-- Kontrollradene under claim-verifikasjonen (migrasjon 005j): hva kontrollen
-- faktisk gikk gjennom, og like uforanderlig som kontrollen selv.
insert into workflow.claim_verification_citations (
  claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
  source_access, relationship_supported, finding
)
select cv.id, l.claim_revision_id, l.id, l.evidence_item_id,
       'original_source', 'not_assessable',
       'Testkontroll: relasjonstypen lot seg ikke bedømme.'
from workflow.claim_verifications cv
join knowledge.claim_evidence_links l on l.claim_revision_id = cv.claim_revision_id;

insert into provenance.actors
  (actor_type, actor_key, display_name, description, auth_user_id)
select 'human', 'human:immutabilitet', 'Test Reviewer',
       'Menneskelig fagredaktør for immutabilitetstestene.', id
from auth.users where email = 'immutabilitet@test.invalid';

insert into workflow.review_decisions (
  claim_revision_id, claim_revision_creator_actor_id,
  review_type, decision, rationale,
  reviewer_actor_id, reviewer_actor_type, decided_at
)
select r.id, r.created_by_actor_id, 'publication_approval', 'changes_requested',
       'Testbeslutning som ber om endringer.',
       pg_temp.actor('human:immutabilitet'), 'human', now()
from knowledge.claim_revisions r
join knowledge.claims cl on cl.id = r.claim_id
join catalog.drugs d on d.id = cl.subject_drug_id
where d.canonical_name = 'sertralin';

-- ---------------------------------------------------------------------------
-- Verifikasjoner og beslutninger er append-only
-- ---------------------------------------------------------------------------
select throws_ok(
  $$update workflow.evidence_verifications set outcome = 'rejected'$$,
  '23001', null,
  'utfallet av en ekstraksjonsverifikasjon kan ikke endres etter innsetting'
);
select throws_ok(
  $$delete from workflow.evidence_verifications$$,
  '23001', null,
  'en ekstraksjonsverifikasjon kan ikke slettes'
);
select throws_ok(
  $$update workflow.claim_verifications set contradictory_evidence_represented = 'deviation'$$,
  '23001', null,
  'et kontrollpunkt i en claim-verifikasjon kan ikke endres etter innsetting'
);
select throws_ok(
  $$delete from workflow.claim_verifications$$,
  '23001', null,
  'en claim-verifikasjon kan ikke slettes'
);
select throws_ok(
  $$update workflow.claim_verification_citations set relationship_supported = 'ok'$$,
  '23001', null,
  'hva en kontroll fant for én evidenslenke kan ikke endres etter innsetting'
);
select throws_ok(
  $$delete from workflow.claim_verification_citations$$,
  '23001', null,
  'en kontrollrad kan ikke slettes; da ville en bekreftelse kunnet miste lenken som felte den'
);
select throws_ok(
  $$update workflow.review_decisions set decision = 'approved'$$,
  '23001', null,
  'et avslag kan ikke gjøres om til en godkjenning ved å skrive over beslutningen'
);
select throws_ok(
  $$update workflow.review_decisions set rationale = 'Omskrevet begrunnelse.'$$,
  '23001', null,
  'begrunnelsen i en beslutning kan ikke skrives om i ettertid'
);
select throws_ok(
  $$delete from workflow.review_decisions$$,
  '23001', null,
  'en reviewbeslutning kan ikke slettes (DATABASE_ARCHITECTURE.md §31, §36)'
);

-- Korreksjonsveien må være farbar: en omgjøring er en ny rad.
select lives_ok(
  $$
    insert into workflow.review_decisions (
      claim_revision_id, claim_revision_creator_actor_id,
      review_type, decision, rationale,
      reviewer_actor_id, reviewer_actor_type, decided_at
    )
    select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
           'Testomgjøring etter at endringene ble gjort.',
           pg_temp.actor('human:immutabilitet'), 'human', now()
    from knowledge.claim_revisions r
    join knowledge.claims cl on cl.id = r.claim_id
    join catalog.drugs d on d.id = cl.subject_drug_id
    where d.canonical_name = 'sertralin'
  $$,
  'en senere omgjøring registreres som en ny beslutning ved siden av den gamle'
);
select is(
  (select count(*) from workflow.review_decisions),
  2::bigint,
  'både den opprinnelige beslutningen og omgjøringen er bevart'
);

-- ---------------------------------------------------------------------------
-- provenance.actors: identiteten er frosset, presentasjonen er ikke
-- ---------------------------------------------------------------------------
select throws_ok(
  $$update provenance.actors set actor_type = 'human'
    where actor_key = 'agent:immutabilitet'$$,
  '23001', null,
  'en KI-aktør kan ikke gjøres om til et menneske i ettertid (ANTIDEP_CONSTITUTION.md §12)'
);
select throws_ok(
  $$update provenance.actors set actor_key = 'agent:noe-annet'
    where actor_key = 'agent:immutabilitet'$$,
  '23001', null,
  'maskinnøkkelen til en aktør kan ikke endres'
);
select throws_ok(
  $$update provenance.actors set agent_role = 'evidence_extraction'
    where actor_key = 'agent:immutabilitet'$$,
  '23001', null,
  'agentrollen kan ikke endres etter innsetting'
);
select throws_ok(
  $$update provenance.actors set auth_user_id = null
    where actor_key = 'human:immutabilitet'$$,
  '23001', null,
  'en brukerkobling som først er satt kan ikke fjernes'
);
select lives_ok(
  $$update provenance.actors set display_name = 'Testverifikator (nytt navn)'
    where actor_key = 'agent:immutabilitet'$$,
  'visningsnavnet kan endres uten at identiteten endres'
);
select lives_ok(
  $$update provenance.actors
    set retired_at = now(), retirement_note = 'Erstattet av en nyere kontrollrolle.'
    where actor_key = 'agent:immutabilitet'$$,
  'en aktør kan trekkes tilbake med begrunnelse'
);
-- En menneskelig aktør kan bli registrert før kontoen finnes, og kobles én gang.
select lives_ok(
  $$
    update provenance.actors
    set auth_user_id = (select id from auth.users where email = 'senkobling@test.invalid')
    where actor_key = 'human:senkobling'
  $$,
  'en aktør uten brukerkonto kan kobles til en konto senere'
);
select throws_ok(
  $$
    update provenance.actors
    set auth_user_id = (select id from auth.users where email = 'immutabilitet@test.invalid')
    where actor_key = 'human:senkobling'
  $$,
  '23001', null,
  'brukerkoblingen kan ikke flyttes til en annen konto etterpå'
);

-- Blokken ligger bevisst før rollen tilbakekalles lenger nede. Med en avsluttet
-- reviewer-rolle ville kvalifikasjonskontrollen avvist en framtidsdatert
-- beslutning først, og assertionen om tidsregelen ville passert av feil grunn.
-- ---------------------------------------------------------------------------
-- created_at eies av databasen på de append-only workflow-tabellene
--
-- På disse radene er created_at ikke bare teknisk metadata: det er
-- referansepunktet de kallerstyrte hendelsestidspunktene måles mot, og
-- rollekontrollen hviler på at det ikke kan flyttes. En oppgitt verdi skal derfor
-- ignoreres, ikke lagres.
-- ---------------------------------------------------------------------------
insert into workflow.evidence_verifications (
  evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
  outcome, source_access, checked_fields, rationale, verified_at, created_at
)
select e.id, e.created_by_actor_id, pg_temp.actor('agent:immutabilitet'),
       'verified', 'original_source',
       array['source_locator']::workflow.evidence_check_field[],
       'Testkontroll med oppgitt registreringstid.',
       timestamptz '2021-06-01T00:00:00Z', timestamptz '2021-06-01T00:00:00Z'
from knowledge.evidence_items e
join catalog.drugs d on d.id = e.intervention_drug_id
where d.canonical_name = 'mirtazapin';

select cmp_ok(
  (select created_at from workflow.evidence_verifications
   where rationale = 'Testkontroll med oppgitt registreringstid.'),
  '>',
  timestamptz '2026-01-01T00:00:00Z',
  'en oppgitt created_at på en ekstraksjonsverifikasjon ignoreres av databasen'
);
select is(
  (select verified_at from workflow.evidence_verifications
   where rationale = 'Testkontroll med oppgitt registreringstid.'),
  timestamptz '2021-06-01T00:00:00Z',
  'hendelsestidspunktet er kallerstyrt og bevares; det er bare referansepunktet databasen eier'
);
select throws_ok(
  $$
    insert into workflow.review_decisions (
      claim_revision_id, claim_revision_creator_actor_id,
      review_type, decision, rationale,
      reviewer_actor_id, reviewer_actor_type, decided_at, created_at
    )
    select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
           'Forsøk på å datere en beslutning fram i tid.',
           pg_temp.actor('human:immutabilitet'), 'human',
           now() + interval '1 day', now() + interval '2 days'
    from knowledge.claim_revisions r
    join knowledge.claims cl on cl.id = r.claim_id
    join catalog.drugs d on d.id = cl.subject_drug_id
    where d.canonical_name = 'sertralin'
  $$,
  '23514', null,
  'en framtidsdatert beslutning kan ikke reddes ved å oppgi en enda senere created_at'
);

-- ---------------------------------------------------------------------------
-- workflow.user_roles: tildelingen er frosset, avslutningen skrives én gang
-- ---------------------------------------------------------------------------
-- Raden selv står først i vernet fra og med migrasjon 008. Tabellen har ingen
-- inngående fremmednøkler, så ingenting utenfra holder primærnøkkelen på plass,
-- og audit.events peker på tildelingen med object_id og uten fremmednøkkel
-- (DATABASE_ARCHITECTURE.md §35, §36). En omnummerering passerte tidligere både
-- denne triggeren og auditrigeren — valid_to var uendret — og etterlot
-- rettigheten på en ny uuid uten en eneste auditrad, mens role_granted ble
-- hengende på en uuid som ikke lenger fantes.
select throws_ok(
  $$update workflow.user_roles set id = '00000000-0000-0000-0000-0000000000fe'
    where grant_reason = 'Testtildeling for immutabilitetstestene.'$$,
  '23001', null,
  'en rolletildeling kan ikke skifte identitet og dermed forlate auditsporet sitt'
);
select throws_ok(
  $$update workflow.user_roles set role_code = 'publisher'
    where grant_reason = 'Testtildeling for immutabilitetstestene.'$$,
  '23001', null,
  'en rolletildeling kan ikke gjøres om til en annen rolle'
);
select throws_ok(
  $$
    update workflow.user_roles
    set user_id = (select id from auth.users where email = 'senkobling@test.invalid')
    where grant_reason = 'Testtildeling for immutabilitetstestene.'
  $$,
  '23001', null,
  'en rolletildeling kan ikke flyttes til en annen bruker'
);
select throws_ok(
  $$update workflow.user_roles set valid_from = timestamptz '2020-01-01T00:00:00Z'
    where grant_reason = 'Testtildeling for immutabilitetstestene.'$$,
  '23001', null,
  'starttidspunktet for en tildeling kan ikke tilbakedateres'
);
select lives_ok(
  $$
    update workflow.user_roles
    set valid_to = now(),
        ended_by_actor_id = (select id from provenance.actors
                             where actor_key = 'system:immutabilitet'),
        end_reason = 'Testtilbakekalling.'
    where grant_reason = 'Testtildeling for immutabilitetstestene.'
  $$,
  'en tildeling kan tilbakekalles ved å sette valid_to med ansvarlig og begrunnelse'
);
select throws_ok(
  $$update workflow.user_roles set valid_to = null, ended_by_actor_id = null, end_reason = null
    where grant_reason = 'Testtildeling for immutabilitetstestene.'$$,
  '23001', null,
  'en tilbakekalt rolle kan ikke gjenåpnes; gjeninnføring er en ny tildeling'
);

-- ---------------------------------------------------------------------------
-- Opphavet på kunnskapsobjektene kan ikke skrives om
-- ---------------------------------------------------------------------------
select throws_ok(
  $$
    update knowledge.claims
    set created_by_actor_id = (select id from provenance.actors
                               where actor_key = 'human:immutabilitet')
  $$,
  '23001', null,
  'opphavet til en påstand kan ikke skrives om i ettertid (ANTIDEP_CONSTITUTION.md §14)'
);
select lives_ok(
  $$update knowledge.claims set retired_at = now(), retirement_note = 'Testtilbaketrekking.'$$,
  'livssyklusfeltene på en påstand er fortsatt endrbare etter at opphavet ble frosset'
);
select throws_ok(
  $$
    update knowledge.claim_revisions
    set created_by_actor_id = (select id from provenance.actors
                               where actor_key = 'human:immutabilitet')
  $$,
  '23001', null,
  'opphavet til en revisjon kan ikke skrives om; raden er append-only'
);

-- ---------------------------------------------------------------------------
-- Migrasjon 005 slo av append-only-triggerne rundt backfillen av
-- created_by_actor_id, og korreksjonsmigrasjon 006a gjorde det samme rundt
-- rehashingen av knowledge.evidence_items. Denne vaktposten fanger at en av dem
-- ble stående av.
--
-- «Avslått» dekker både D og R: en trigger satt til replica fyrer ikke i vanlig
-- drift, og et vern som ikke fyrer, er ikke et vern. A er derimot strengere enn
-- O og er ikke et brudd. api er med i listen fordi et view der kan få en
-- INSTEAD OF-trigger.
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select n.nspname || '.' || c.relname || ': ' || t.tgname
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('catalog', 'knowledge', 'workflow', 'provenance', 'audit', 'api')
      and not t.tgisinternal
      and t.tgenabled in ('D', 'R')
  $$,
  'ingen trigger i de kanoniske schemaene står avslått etter migrasjonene'
);

select * from finish();

rollback;
