-- ============================================================================
-- Fiksturen prøve 6 og 7 i scripts/db-lock-test.sh kappes på
--
-- Prøvene trenger én påstand som `knowledge.discard_unpublished_claim_artifacts`
-- slipper gjennom **hver** kontroll for: ikke publisert, ingen
-- publiseringshendelse, ingen menneskelig kontroll av påstanden selv, og ingen
-- menneskelig evidenskontroll eller reviewbeslutning på funnet den er lenket
-- til. Uten det ville fjerningen stoppet på et vilkår, transaksjonen blitt
-- avbrutt, og låsen sluppet — og prøven ville ikke sagt noe om låsen.
--
-- Fiksturen er egen og har faste id-er: ingen annen påstand, ingen annen kilde
-- og ingen annen kontroll rører den, og gjentatte kjøringer gjenbruker den
-- framfor å legge igjen nye rader. Påstanden er aldri publisert og er ikke
-- lenket til noe som vises noe sted.
--
-- Kallet i prøvene sletter fiksturen inne i sin egen transaksjon, som rulles
-- tilbake. Radene står derfor igjen mellom kjøringer, og alt her er idempotent.
--
-- Kjøres av scripts/db-lock-test.sh. Ingenting her hører hjemme i en migrasjon:
-- dette er prøvedata, ikke kunnskap (supabase/README.md, «Hvor seed-data hører
-- hjemme»).
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Kalleren. Fjerningsveien krever en autorisert redaktøridentitet, og prøven
-- bruker sin egen framfor eierens: hvilken tilstand eierens konto står i, skal
-- ikke avgjøre om en samtidighetsprøve kjører.
--
-- Kontoen får også `reviewer`, fordi prøve 7 registrerer en reviewbeslutning
-- fra den. Begge tildelingene gjelder bare denne prøvekontoen.
-- ----------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email)
values ('7c000000-0000-4000-8000-0000000000a0',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'fjerningsprove@antidep.test')
on conflict (id) do nothing;

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values ('7c000000-0000-4000-8000-0000000000a1', 'human:fjerningsprove-redaktor', 'human',
        'Redaktør for fjerningsprøven',
        'Bare til scripts/db-lock-test.sh. Registrerer ingen faglig vurdering av reelt innhold.',
        '7c000000-0000-4000-8000-0000000000a0')
on conflict (id) do nothing;

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select '7c000000-0000-4000-8000-0000000000a0', rolle, null, now() - interval '1 year',
       a.id, 'Tildeling for fjerningsprøven i scripts/db-lock-test.sh.'
from provenance.actors a,
     (values ('editor'::workflow.app_role), ('reviewer'::workflow.app_role)) as r(rolle)
where a.actor_key = 'human:peder-holman'
  and not exists (
    select 1 from workflow.user_roles ur
    where ur.user_id = '7c000000-0000-4000-8000-0000000000a0'
      and ur.role_code = r.rolle
  );

-- ----------------------------------------------------------------------------
-- Kilden, kildeversjonen og evidensfunnet. Funnet er laget av
-- ekstraksjonsagenten, slik at prøvekontoen er en ANNEN aktør enn den som laget
-- det — evidence_verifications_separate_actor_check krever nettopp det av
-- kontrollen prøve 6 forsøker.
-- ----------------------------------------------------------------------------
insert into knowledge.sources
  (id, source_type, title, authors_or_issuer, created_by_actor_id)
select '7c000000-0000-4000-8000-000000000001', 'journal_article',
       'Samtidighetsprøve for fjerning av påstandsartefakter', 'scripts/db-lock-test.sh', a.id
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (select 1 from knowledge.sources s
                  where s.id = '7c000000-0000-4000-8000-000000000001');

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation,
   retrieved_by_actor_id)
select '7c000000-0000-4000-8000-000000000002', '7c000000-0000-4000-8000-000000000001',
       now(), 'https://example.test/fjerningsprove',
       'sha256:' || repeat('c', 64), 'abstract', a.id
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (select 1 from knowledge.source_versions v
                  where v.id = '7c000000-0000-4000-8000-000000000002');

insert into knowledge.evidence_items
  (id, source_id, source_version_id, design_code, population_availability,
   population_detail, sample_size_availability, intervention_drug_id,
   comparator_kind, outcome_concept_id, outcome_detail, timepoint_availability,
   reported_direction, estimate_availability, confidence_interval_availability,
   source_locator, extraction_method, created_by_actor_id)
select '7c000000-0000-4000-8000-000000000003', '7c000000-0000-4000-8000-000000000001',
       '7c000000-0000-4000-8000-000000000002',
       'randomized_controlled_trial', 'not_reported', 'Samtidighetsprøve.',
       'not_reported', d.id, 'none', c.id, 'Samtidighetsprøve.', 'not_reported',
       'increase', 'not_reported', 'not_reported', 'Samtidighetsprøve', 'ai_assisted', a.id
from catalog.drugs d, catalog.clinical_concepts c, provenance.actors a
where d.canonical_name = 'sertralin'
  and c.canonical_label = 'vektendring'
  and a.actor_key = 'agent:evidence-extraction'
  and not exists (select 1 from knowledge.evidence_items e
                  where e.id = '7c000000-0000-4000-8000-000000000003');

-- ----------------------------------------------------------------------------
-- Påstanden, revisjonen og lenken. Ingen publisering, ingen menneskelig
-- kontroll og ingen reviewbeslutning: nøyaktig tilstanden fjerningsveien
-- slipper gjennom.
-- ----------------------------------------------------------------------------
insert into knowledge.claims
  (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
select '7c000000-0000-4000-8000-000000000004', 'evidence_synthesis', c.id, d.id, a.id
from catalog.drugs d, catalog.clinical_concepts c, provenance.actors a
where d.canonical_name = 'sertralin'
  and c.canonical_label = 'vektendring'
  and a.actor_key = 'agent:claim-synthesis'
  and not exists (select 1 from knowledge.claims c2
                  where c2.id = '7c000000-0000-4000-8000-000000000004');

insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
select '7c000000-0000-4000-8000-000000000005', '7c000000-0000-4000-8000-000000000004', 1,
       'evidence_synthesis', d.id,
       'Samtidighetsprøve: påstand som bare finnes for scripts/db-lock-test.sh.',
       'Gjelder bare som prøvedata.', 'none', 'increase',
       'Samtidighetsprøve; ingen reell usikkerhetsvurdering.', a.id
from catalog.drugs d, provenance.actors a
where d.canonical_name = 'sertralin'
  and a.actor_key = 'agent:claim-synthesis'
  and not exists (select 1 from knowledge.claim_revisions r
                  where r.id = '7c000000-0000-4000-8000-000000000005');

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select '7c000000-0000-4000-8000-000000000006', '7c000000-0000-4000-8000-000000000005',
       '7c000000-0000-4000-8000-000000000003', 'supports', 'direct',
       'Samtidighetsprøve.', a.id
from provenance.actors a
where a.actor_key = 'agent:claim-synthesis'
  and not exists (select 1 from knowledge.claim_evidence_links l
                  where l.id = '7c000000-0000-4000-8000-000000000006');
