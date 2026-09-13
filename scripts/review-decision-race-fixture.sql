-- ============================================================================
-- Fiksturen prøve 5 i scripts/db-lock-test.sh kappes på
--
-- Prøven trenger én påstandsrevisjon som publiseringsgatens G1 til G10 slipper
-- gjennom, slik at det *eneste* som avgjør om den kan publiseres, er hvilken
-- reviewbeslutning som er den gjeldende (G11, G12). Uten det ville gaten stoppet
-- på et tidligere vilkår, og prøven ville ikke sagt noe om beslutningen.
--
-- Fiksturen er egen og har faste id-er: ingen annen påstand, ingen annen kilde
-- og ingen annen kontroll rører den, og gjentatte kjøringer gjenbruker den
-- framfor å legge igjen nye rader. Revisjonen er aldri publisert og er ikke
-- lenket til noe som vises noe sted.
--
-- Alt er idempotent. Radene i workflow er append-only, så de skrives bare når
-- de ikke finnes fra før — aldri ved å myke opp regelen.
--
-- Kjøres av scripts/db-lock-test.sh. Ingenting her hører hjemme i en migrasjon:
-- dette er prøvedata, ikke kunnskap (supabase/README.md, «Hvor seed-data hører
-- hjemme»).
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Revieweren. Et menneske med gyldig reviewer-tildeling, og en annen aktør enn
-- den som formulerte revisjonen — begge deler er krav databasen håndhever.
-- ----------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email)
values ('7b000000-0000-4000-8000-0000000000a0',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'samtidighetsprove@antidep.test')
on conflict (id) do nothing;

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values ('7b000000-0000-4000-8000-0000000000a1', 'human:samtidighetsprove-reviewer', 'human',
        'Reviewer for samtidighetsprøven',
        'Bare til scripts/db-lock-test.sh. Registrerer ingen faglig vurdering av reelt innhold.',
        '7b000000-0000-4000-8000-0000000000a0')
on conflict (id) do nothing;

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select '7b000000-0000-4000-8000-0000000000a0', 'reviewer', null, now() - interval '1 year',
       a.id, 'Reviewer-tildeling for samtidighetsprøven.'
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (
    select 1 from workflow.user_roles ur
    where ur.user_id = '7b000000-0000-4000-8000-0000000000a0'
      and ur.role_code = 'reviewer'
  );

-- ----------------------------------------------------------------------------
-- Kilden, kildeversjonen og evidensfunnet.
-- ----------------------------------------------------------------------------
insert into knowledge.sources
  (id, source_type, title, authors_or_issuer, created_by_actor_id)
select '7b000000-0000-4000-8000-000000000001', 'journal_article',
       'Samtidighetsprøve for reviewbeslutningen', 'scripts/db-lock-test.sh', a.id
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (select 1 from knowledge.sources s
                  where s.id = '7b000000-0000-4000-8000-000000000001');

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation,
   retrieved_by_actor_id)
select '7b000000-0000-4000-8000-000000000002', '7b000000-0000-4000-8000-000000000001',
       now(), 'https://example.test/samtidighetsprove-review',
       'sha256:' || repeat('b', 64), 'abstract', a.id
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (select 1 from knowledge.source_versions v
                  where v.id = '7b000000-0000-4000-8000-000000000002');

insert into knowledge.evidence_items
  (id, source_id, source_version_id, design_code, population_availability,
   population_detail, sample_size_availability, intervention_drug_id,
   comparator_kind, outcome_concept_id, outcome_detail, timepoint_availability,
   reported_direction, estimate_availability, confidence_interval_availability,
   source_locator, extraction_method, created_by_actor_id)
select '7b000000-0000-4000-8000-000000000003', '7b000000-0000-4000-8000-000000000001',
       '7b000000-0000-4000-8000-000000000002',
       'randomized_controlled_trial', 'not_reported', 'Samtidighetsprøve.',
       'not_reported', d.id, 'none', c.id, 'Samtidighetsprøve.', 'not_reported',
       'increase', 'not_reported', 'not_reported', 'Samtidighetsprøve', 'ai_assisted', a.id
from catalog.drugs d, catalog.clinical_concepts c, provenance.actors a
where d.canonical_name = 'sertralin'
  and c.canonical_label = 'vektendring'
  and a.actor_key = 'agent:evidence-extraction'
  and not exists (select 1 from knowledge.evidence_items e
                  where e.id = '7b000000-0000-4000-8000-000000000003');

-- ----------------------------------------------------------------------------
-- Påstanden og revisjonen. Formulert av synteseagenten, slik at revieweren er
-- en annen aktør enn forfatteren.
-- ----------------------------------------------------------------------------
insert into knowledge.claims
  (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
select '7b000000-0000-4000-8000-000000000004', 'evidence_synthesis', c.id, d.id, a.id
from catalog.drugs d, catalog.clinical_concepts c, provenance.actors a
where d.canonical_name = 'sertralin'
  and c.canonical_label = 'vektendring'
  and a.actor_key = 'agent:claim-synthesis'
  and not exists (select 1 from knowledge.claims c2
                  where c2.id = '7b000000-0000-4000-8000-000000000004');

insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
select '7b000000-0000-4000-8000-000000000005', '7b000000-0000-4000-8000-000000000004', 1,
       'evidence_synthesis', d.id,
       'Samtidighetsprøve: påstand som bare finnes for scripts/db-lock-test.sh.',
       'Gjelder bare som prøvedata.', 'none', 'increase',
       'Samtidighetsprøve; ingen reell usikkerhetsvurdering.', a.id
from catalog.drugs d, provenance.actors a
where d.canonical_name = 'sertralin'
  and a.actor_key = 'agent:claim-synthesis'
  and not exists (select 1 from knowledge.claim_revisions r
                  where r.id = '7b000000-0000-4000-8000-000000000005');

insert into knowledge.claim_evidence_links
  (id, claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select '7b000000-0000-4000-8000-000000000006', '7b000000-0000-4000-8000-000000000005',
       '7b000000-0000-4000-8000-000000000003', 'supports', 'direct',
       'Samtidighetsprøve.', a.id
from provenance.actors a
where a.actor_key = 'agent:claim-synthesis'
  and not exists (select 1 from knowledge.claim_evidence_links l
                  where l.id = '7b000000-0000-4000-8000-000000000006');

-- ----------------------------------------------------------------------------
-- G4, G5, G5b, G5c: ekstraksjonen er kontrollert av verifikatoren, som har
-- mandatet gjennom rollen sin.
--
-- Den kildeomfattende halvdelen av et globalt fravær (`source_wide_absence`,
-- migrasjon 005ae) er et søk gjennom hele kildeversjonen, og kan bare føres opp
-- av en rad med en agentkjøring. Fiksturen åpner derfor en kjøring for
-- verifikatoren og attribuerer hele kontrollen til den — det er også den ekte
-- formen: maskinen gjør søket.
-- ----------------------------------------------------------------------------
with run as (
  insert into provenance.agent_runs
    (agent_identity_id, actor_id, agent_role, provider, model, model_version,
     prompt_template_version, pipeline_version, input_manifest)
  select ai.id, ai.actor_id, 'extraction_verification', 'prøve', 'prøve', '1',
         'extraction-verification/1', 'antidep-evidence/1', '{"mode": "fikstur"}'::jsonb
  from provenance.agent_identities ai
  where ai.identity_key = 'agent-identity:extraction-verification-01'
    and not exists (
      select 1 from workflow.evidence_verifications ev
      where ev.evidence_item_id = '7b000000-0000-4000-8000-000000000003'
    )
  returning id, actor_id
)
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at, agent_run_id)
select e.id, e.created_by_actor_id, run.actor_id, 'verified', 'original_source',
       workflow.required_check_fields(e.id),
       'Samtidighetsprøve: ekstraksjonen er kontrollert i sin helhet.', now(), run.id
from knowledge.evidence_items e, run
where e.id = '7b000000-0000-4000-8000-000000000003';

-- ----------------------------------------------------------------------------
-- G8, G9, G9b, G9c: påstanden er kontrollert mot grunnlaget av revieweren, som
-- har mandatet gjennom sin gyldige reviewer-tildeling.
-- ----------------------------------------------------------------------------
with parent as (
  insert into workflow.claim_verifications
    (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
     source_access, source_support, population_match, comparator_match, timeframe_match,
     direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
     rationale, verified_at)
  select r.id, r.created_by_actor_id, '7b000000-0000-4000-8000-0000000000a1',
         'verified', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
         'Samtidighetsprøve: påstanden er kontrollert mot grunnlaget.', now()
  from knowledge.claim_revisions r
  where r.id = '7b000000-0000-4000-8000-000000000005'
    and not exists (
      select 1 from workflow.claim_verifications cv
      where cv.claim_revision_id = '7b000000-0000-4000-8000-000000000005'
    )
  returning id, claim_revision_id
)
insert into workflow.claim_verification_citations
  (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
   source_access, relationship_supported)
select parent.id, l.claim_revision_id, l.id, l.evidence_item_id, 'original_source', 'ok'
from parent
join knowledge.claim_evidence_links l on l.claim_revision_id = parent.claim_revision_id;

-- ----------------------------------------------------------------------------
-- G10: evidensvurderingen finnes.
-- ----------------------------------------------------------------------------
-- Vurderingen attribueres til evidensvurderingsaktøren, ikke til den som
-- formulerte revisjonen: publiseringsgatens G10b krever at den som gjorde
-- vurderingen, hadde mandat til det (migrasjon 005ap).
insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select '7b000000-0000-4000-8000-000000000005', 'evidence_synthesis', 'grade', 'low',
       'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
       'Samtidighetsprøve: lav sikkerhet, registrert bare for at gaten skal ha en vurdering å lese.',
       now(), a.id
from provenance.actors a
where a.actor_key = 'agent:evidence-assessment'
  and not exists (
    select 1 from knowledge.evidence_assessments ea
    where ea.claim_revision_id = '7b000000-0000-4000-8000-000000000005'
  );
