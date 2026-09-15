-- ============================================================================
-- Fiksturen publiseringsprøvene i scripts/db-lock-test.sh kappes på
--
-- Prøvene trenger én påstand med *to* fullt publiserbare revisjoner, hver med
-- sin forseglede kandidat og sin godkjente sluttkontroll, og to mennesker med
-- hvert sitt mandat: en fagperson som sluttkontrollerer, og en publisher som
-- publiserer. Uten det ville publiseringsgaten stoppet på et tidligere vilkår,
-- og prøvene ville ikke sagt noe om samtidigheten.
--
-- Fiksturen er egen og har faste id-er: ingen annen påstand og ingen annen kilde
-- rører den, og gjentatte kjøringer gjenbruker den framfor å legge igjen nye
-- rader.
--
-- ----------------------------------------------------------------------------
-- Hvorfor publiseringshistorikken nullstilles her
--
-- Én av prøvene *må* commite en publisering: den prøver hva som skjer når to
-- transaksjoner ikke venter på hverandre, og økt A kan bare se økt B sin
-- hendelse hvis den er commitet. Historikken ville da vokst for hver kjøring, og
-- den andre kjøringen ville møtt en påstand som allerede er publisert.
--
-- Nullstillingen er derfor en del av fiksturen og ikke en skrivevei: den gjelder
-- nøyaktig denne ene syntetiske påstanden, append-only-vernet slås av i det
-- smalest mulige vinduet og på igjen umiddelbart, og ingen annen rad kan nås av
-- setningene. Dette er prøvedata, ikke kunnskap (supabase/README.md).
--
-- Kjøres av scripts/db-lock-test.sh. Ingenting her hører hjemme i en migrasjon.
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Fagpersonen og publisheren. To mennesker, to mandater: å sluttkontrollere og
-- å publisere er to handlinger med hver sin rad og hvert sitt kall.
-- ----------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email)
values ('7d000000-0000-4000-8000-0000000000a0',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'publiseringsprove-fagperson@antidep.test'),
       ('7d000000-0000-4000-8000-0000000000b0',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'publiseringsprove-publisher@antidep.test')
on conflict (id) do nothing;

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values ('7d000000-0000-4000-8000-0000000000a1', 'human:publiseringsprove-fagperson', 'human',
        'Fagperson for publiseringsprøven',
        'Bare til scripts/db-lock-test.sh. Vurderer ikke reelt innhold.',
        '7d000000-0000-4000-8000-0000000000a0'),
       ('7d000000-0000-4000-8000-0000000000b1', 'human:publiseringsprove-publisher', 'human',
        'Publisher for publiseringsprøven',
        'Bare til scripts/db-lock-test.sh. Publiserer ikke reelt innhold.',
        '7d000000-0000-4000-8000-0000000000b0')
on conflict (id) do nothing;

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select '7d000000-0000-4000-8000-0000000000a0', 'reviewer', null, now() - interval '1 year',
       a.id, 'Sluttkontrollmandat for publiseringsprøven.'
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (
    select 1 from workflow.user_roles ur
    where ur.user_id = '7d000000-0000-4000-8000-0000000000a0' and ur.role_code = 'reviewer'
  );

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select '7d000000-0000-4000-8000-0000000000b0', 'publisher', null, now() - interval '1 year',
       a.id, 'Publiseringsmandat for publiseringsprøven.'
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (
    select 1 from workflow.user_roles ur
    where ur.user_id = '7d000000-0000-4000-8000-0000000000b0' and ur.role_code = 'publisher'
  );

-- ----------------------------------------------------------------------------
-- Kilden, kildeversjonen, den private filen og evidensfunnet.
-- ----------------------------------------------------------------------------
insert into knowledge.sources
  (id, source_type, title, authors_or_issuer, created_by_actor_id)
select '7d000000-0000-4000-8000-000000000001', 'journal_article',
       'Samtidighetsprøve for publiseringen', 'scripts/db-lock-test.sh', a.id
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (select 1 from knowledge.sources s
                  where s.id = '7d000000-0000-4000-8000-000000000001');

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference, representation,
   retrieved_by_actor_id, document_sha256, document_byte_size, document_media_type,
   text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
   text_extraction_transform)
select '7d000000-0000-4000-8000-000000000002', '7d000000-0000-4000-8000-000000000001',
       now(), 'file:///syntetisk-samtidighetsprove-publisering.pdf',
       'sha256:' || repeat('d', 64), 'private://syntetisk-samtidighetsprove-publisering.pdf',
       'full_text', a.id,
       knowledge.source_document_fingerprint(
         convert_to('%PDF-1.7' || E'\nsamtidighetsprove-publisering\n%%EOF\n', 'UTF8')),
       octet_length(convert_to('%PDF-1.7' || E'\nsamtidighetsprove-publisering\n%%EOF\n', 'UTF8')),
       'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (select 1 from knowledge.source_versions v
                  where v.id = '7d000000-0000-4000-8000-000000000002');

insert into knowledge.source_documents
  (sha256, byte_size, media_type, content, stored_by_actor_id)
select knowledge.source_document_fingerprint(g.bytes), octet_length(g.bytes),
       'application/pdf', g.bytes, a.id
from (select convert_to('%PDF-1.7' || E'\nsamtidighetsprove-publisering\n%%EOF\n', 'UTF8')
        as bytes) g
join provenance.actors a on a.actor_key = 'human:peder-holman'
on conflict (sha256) do nothing;

insert into knowledge.source_document_publications
  (source_document_id, source_id, binding_basis, binding_evidence, bound_by_actor_id)
select d.id, sv.source_id, 'title', 'syntetisk binding for publiseringsprøven',
       sv.retrieved_by_actor_id
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = '7d000000-0000-4000-8000-000000000002'
on conflict on constraint source_document_publications_pairing_key do nothing;

insert into knowledge.full_text_readability_checks
  (source_version_id, source_document_id, character_count, letter_count,
   line_count, table_row_count, table_declaration_count)
select sv.id, d.id, 20000, 15000, 400, 12, 3
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = '7d000000-0000-4000-8000-000000000002'
on conflict on constraint full_text_readability_checks_source_version_key do nothing;

insert into knowledge.evidence_items
  (id, source_id, source_version_id, design_code, population_availability,
   population_detail, sample_size_availability, intervention_drug_id,
   comparator_kind, outcome_concept_id, outcome_detail, timepoint_availability,
   reported_direction, estimate_availability, confidence_interval_availability,
   source_locator, extraction_method, created_by_actor_id)
select '7d000000-0000-4000-8000-000000000003', '7d000000-0000-4000-8000-000000000001',
       '7d000000-0000-4000-8000-000000000002',
       'randomized_controlled_trial', 'not_reported', 'Samtidighetsprøve.',
       'not_reported', d.id, 'none', c.id, 'Samtidighetsprøve.', 'not_reported',
       'increase', 'not_reported', 'not_reported', 'Samtidighetsprøve', 'ai_assisted', a.id
from catalog.drugs d, catalog.clinical_concepts c, provenance.actors a
where d.canonical_name = 'sertralin'
  and c.canonical_label = 'vektendring'
  and a.actor_key = 'agent:evidence-extraction'
  and not exists (select 1 from knowledge.evidence_items e
                  where e.id = '7d000000-0000-4000-8000-000000000003');

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
      where ev.evidence_item_id = '7d000000-0000-4000-8000-000000000003'
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
where e.id = '7d000000-0000-4000-8000-000000000003';

-- ----------------------------------------------------------------------------
-- Påstanden og de to revisjonene.
-- ----------------------------------------------------------------------------
insert into knowledge.claims
  (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
select '7d000000-0000-4000-8000-000000000004', 'evidence_synthesis', c.id, d.id, a.id
from catalog.drugs d, catalog.clinical_concepts c, provenance.actors a
where d.canonical_name = 'sertralin'
  and c.canonical_label = 'vektendring'
  and a.actor_key = 'agent:claim-synthesis'
  and not exists (select 1 from knowledge.claims c2
                  where c2.id = '7d000000-0000-4000-8000-000000000004');

insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
select n.id, '7d000000-0000-4000-8000-000000000004', n.revision_number,
       'evidence_synthesis', d.id, n.statement,
       'Gjelder bare som prøvedata.', 'none', 'increase',
       'Samtidighetsprøve; ingen reell usikkerhetsvurdering.', a.id
from catalog.drugs d, provenance.actors a,
     (values ('7d000000-0000-4000-8000-000000000005'::uuid, 1,
              'Samtidighetsprøve: første formulering, bare for scripts/db-lock-test.sh.'),
             ('7d000000-0000-4000-8000-000000000015'::uuid, 2,
              'Samtidighetsprøve: andre formulering, bare for scripts/db-lock-test.sh.'))
       as n(id, revision_number, statement)
where d.canonical_name = 'sertralin'
  and a.actor_key = 'agent:claim-synthesis'
  and not exists (select 1 from knowledge.claim_revisions r where r.id = n.id);

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select r.id, '7d000000-0000-4000-8000-000000000003', 'supports', 'direct',
       'Samtidighetsprøve.', a.id
from knowledge.claim_revisions r, provenance.actors a
where r.claim_id = '7d000000-0000-4000-8000-000000000004'
  and a.actor_key = 'agent:claim-synthesis'
  and not exists (select 1 from knowledge.claim_evidence_links l
                  where l.claim_revision_id = r.id);

with parent as (
  insert into workflow.claim_verifications
    (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
     source_access, source_support, population_match, comparator_match, timeframe_match,
     direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
     rationale, verified_at)
  select r.id, r.created_by_actor_id, '7d000000-0000-4000-8000-0000000000a1',
         'verified', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
         'Samtidighetsprøve: påstanden er kontrollert mot grunnlaget.', now()
  from knowledge.claim_revisions r
  where r.claim_id = '7d000000-0000-4000-8000-000000000004'
    and not exists (
      select 1 from workflow.claim_verifications cv where cv.claim_revision_id = r.id
    )
  returning id, claim_revision_id
)
insert into workflow.claim_verification_citations
  (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
   source_access, relationship_supported)
select parent.id, l.claim_revision_id, l.id, l.evidence_item_id, 'original_source', 'ok'
from parent
join knowledge.claim_evidence_links l on l.claim_revision_id = parent.claim_revision_id;

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select r.id, 'evidence_synthesis', 'grade', 'low',
       'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
       'Samtidighetsprøve: registrert bare for at gaten skal ha en vurdering å lese.',
       now(), a.id
from knowledge.claim_revisions r, provenance.actors a
where r.claim_id = '7d000000-0000-4000-8000-000000000004'
  and a.actor_key = 'agent:evidence-assessment'
  and not exists (
    select 1 from knowledge.evidence_assessments ea where ea.claim_revision_id = r.id
  );

-- ----------------------------------------------------------------------------
-- Kandidatene og sluttkontrollene.
--
-- Innholdet og avtrykket kommer fra de samme funksjonene produksjonskoden
-- bruker; fiksturen finner ikke på noe. Sluttkontrollen er en ekte rad fra et
-- ekte menneske med reviewer-mandat.
-- ----------------------------------------------------------------------------
insert into knowledge.candidates
  (claim_revision_id, candidate_digest, evidence_set_digest, content, built_by_actor_id)
select r.id,
       knowledge.source_version_content_hash(knowledge.candidate_content(r.id)::text),
       knowledge.claim_evidence_set_digest(r.id),
       knowledge.candidate_content(r.id),
       '7d000000-0000-4000-8000-0000000000a1'
from knowledge.claim_revisions r
where r.claim_id = '7d000000-0000-4000-8000-000000000004'
  and not exists (
    select 1 from knowledge.candidates c
    where c.claim_revision_id = r.id
      and c.candidate_digest =
          knowledge.source_version_content_hash(knowledge.candidate_content(r.id)::text)
  );

insert into workflow.candidate_final_controls
  (candidate_id, candidate_digest, decision, rationale, reviewer_actor_id, reviewer_actor_type)
select c.id, c.candidate_digest, 'approved',
       'Samtidighetsprøve: innholdet er lest i klinikerens egen visning.',
       '7d000000-0000-4000-8000-0000000000a1', 'human'
from knowledge.candidates c
join knowledge.claim_revisions r on r.id = c.claim_revision_id
where r.claim_id = '7d000000-0000-4000-8000-000000000004'
  and (workflow.current_candidate_final_control(c.id)).decision
      is distinct from 'approved'::workflow.final_control_decision;

-- ----------------------------------------------------------------------------
-- Tilbakestillingen. Se hodekommentaren: én av prøvene må commite en publisering,
-- og uten dette ville den andre kjøringen møtt en påstand som allerede er
-- publisert.
--
-- Den er en ekte tilbaketrekking gjennom den kontrollerte operasjonen, ikke en
-- sletting: historikken vokser med én hendelse per kjøring, og det er riktig.
-- Publiseringshistorikk slettes aldri — heller ikke i en prøve
-- (ANTIDEP_CONSTITUTION.md regel 6, DATABASE_ARCHITECTURE.md §36). Prøvene teller
-- derfor hendelser mot en målt utgangsverdi framfor mot et fast tall.
-- ----------------------------------------------------------------------------
do $reset$
begin
  if exists (
    select 1 from knowledge.claims c
    where c.id = '7d000000-0000-4000-8000-000000000004'
      and c.current_published_revision_id is not null
  ) then
    perform set_config('request.jwt.claims',
                       '{"sub":"7d000000-0000-4000-8000-0000000000b0"}', true);
    perform knowledge.withdraw_claim_publication(
      '7d000000-0000-4000-8000-000000000004',
      '7d000000-0000-4000-8000-0000000000b1',
      'Samtidighetsprøve: tilbakestilling før en ny kjøring av scripts/db-lock-test.sh.');
  end if;
end
$reset$;
