-- Explicit synthetic Antidep 2 graph. Included after BEGIN and rolled back by each test.
-- Preserve the migrated audit baseline so this shared fixture does not pollute
-- tests that make exhaustive assertions about their own audit effects.
create temporary table fixture_audit_baseline on commit drop as
select id from audit.events;

-- Samme grunn, for køen. Fra migrasjon 012b legger et registrert evidensfunn og
-- en registrert påstandsrevisjon selv neste ledd i køen. Det er riktig
-- oppførsel, og den prøves i 810_chain_transitions_test.sql — men dette
-- fiksturet er et stillas og ikke et forløp, og en delt kø ville tvunget hver
-- test til å filtrere bort jobber den aldri ba om.
create temporary table fixture_pipeline_baseline on commit drop as
select id from workflow.pipeline_jobs;

create function pg_temp.extraction_actor_id() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'agent:evidence-extraction'
$$;
create function pg_temp.synthesis_actor_id() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'agent:claim-synthesis'
$$;
create function pg_temp.assessment_actor_id() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'agent:evidence-assessment'
$$;

-- From migration 009a a clinical full-text version must have its original file
-- in knowledge.source_documents, and that table computes the digest from the
-- bytes themselves. A synthetic fixture can therefore no longer invent a
-- document digest: it must derive the digest from bytes it actually has. These
-- helpers are the smallest possible stand-in for a real PDF — the production
-- rules that matter here are the PDF signature, the digest identity and the
-- publication binding, none of which need a real article.
create function pg_temp.synthetic_pdf(p_seed text) returns bytea language sql immutable as $$
  select convert_to('%PDF-1.7' || E'\n' || p_seed || E'\n%%EOF' || E'\n', 'UTF8')
$$;
create function pg_temp.synthetic_pdf_digest(p_seed text) returns text language sql stable as $$
  select knowledge.source_document_fingerprint(pg_temp.synthetic_pdf(p_seed))
$$;

-- Put the synthetic file in the library, bind it to its publication and record
-- the readability check — the three rows migration 009a requires under every
-- clinical full-text version. The trigger only ever fires for rows whose
-- document digest is exactly the digest of this fixture's own synthetic bytes,
-- so a version registered through a real document path is never touched.
create function pg_temp.store_synthetic_full_text_document() returns trigger language plpgsql as $$
declare
  v_bytes bytea;
  v_document_id uuid;
begin
  if new.representation is distinct from 'full_text'::knowledge.source_representation
     or new.document_sha256 is null then
    return null;
  end if;

  v_bytes := pg_temp.synthetic_pdf(new.id::text);
  if knowledge.source_document_fingerprint(v_bytes) is distinct from new.document_sha256 then
    return null;
  end if;

  select d.id into v_document_id
  from knowledge.source_documents d
  where d.sha256 = new.document_sha256;

  if v_document_id is null then
    insert into knowledge.source_documents
      (sha256, byte_size, media_type, content, stored_by_actor_id)
    values (new.document_sha256, octet_length(v_bytes), 'application/pdf', v_bytes,
            new.retrieved_by_actor_id)
    returning id into v_document_id;
  end if;

  insert into knowledge.source_document_publications
    (source_document_id, source_id, binding_basis, binding_evidence, bound_by_actor_id)
  values (v_document_id, new.source_id, 'title', 'syntetisk testbinding',
          new.retrieved_by_actor_id)
  on conflict on constraint source_document_publications_pairing_key do nothing;

  -- Tallene er over hver terskel i knowledge.full_text_readability_problem.
  -- Fiksturet påstår ikke at en syntetisk PDF er lesbar; det står for at
  -- kontrollen er gjort, som er nøyaktig det gaten leser.
  insert into knowledge.full_text_readability_checks (
    source_version_id, source_document_id, character_count, letter_count,
    line_count, table_row_count, table_declaration_count
  )
  values (new.id, v_document_id, 20000, 15000, 400, 12, 3)
  on conflict on constraint full_text_readability_checks_source_version_key do nothing;

  return null;
end;
$$;
create trigger source_versions_store_synthetic_test_document
  after insert on knowledge.source_versions
  for each row execute function pg_temp.store_synthetic_full_text_document();

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('f2000000-0000-4000-8000-000000000001', 'journal_article', 'Syntetisk fulltekstkilde A for databasetest', 'Testforfatter', pg_temp.extraction_actor_id()),
  ('f2000000-0000-4000-8000-000000000003', 'journal_article', 'Syntetisk fulltekstkilde B for databasetest', 'Testforfatter', pg_temp.extraction_actor_id());

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, external_version, content_hash,
  storage_reference, representation, retrieved_by_actor_id, document_sha256,
  document_byte_size, document_media_type, text_extraction_tool,
  text_extraction_tool_version, text_extraction_arguments, text_extraction_transform
) values
  ('f2000000-0000-4000-8000-000000000002', 'f2000000-0000-4000-8000-000000000001', now(), 'file:///syntetisk-a.pdf', 'synthetic-v1', 'sha256:' || repeat('1', 64), 'private://syntetisk-a.pdf', 'full_text', pg_temp.extraction_actor_id(), pg_temp.synthetic_pdf_digest('f2000000-0000-4000-8000-000000000002'), octet_length(pg_temp.synthetic_pdf('f2000000-0000-4000-8000-000000000002')), 'application/pdf', 'pdftotext', '24.02.0', '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'),
  ('f2000000-0000-4000-8000-000000000004', 'f2000000-0000-4000-8000-000000000003', now(), 'file:///syntetisk-b.pdf', 'synthetic-v1', 'sha256:' || repeat('3', 64), 'private://syntetisk-b.pdf', 'full_text', pg_temp.extraction_actor_id(), pg_temp.synthetic_pdf_digest('f2000000-0000-4000-8000-000000000004'), octet_length(pg_temp.synthetic_pdf('f2000000-0000-4000-8000-000000000004')), 'application/pdf', 'pdftotext', '24.02.0', '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2');

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_id,
  population_availability, population_detail, sample_size, sample_size_availability,
  intervention_drug_id, comparator_kind, outcome_concept_id, outcome_detail,
  timepoint_min, timepoint_max, timepoint_availability, reported_direction,
  effect_measure, estimate, estimate_unit, estimate_availability,
  confidence_interval_availability, limitations_text, source_locator,
  extraction_method, raw_extraction, created_by_actor_id
)
select
  case d.canonical_name when 'sertralin' then 'f2000000-0000-4000-8000-000000000011'::uuid else 'f2000000-0000-4000-8000-000000000012'::uuid end,
  case d.canonical_name when 'sertralin' then 'f2000000-0000-4000-8000-000000000001'::uuid else 'f2000000-0000-4000-8000-000000000003'::uuid end,
  case d.canonical_name when 'sertralin' then 'f2000000-0000-4000-8000-000000000002'::uuid else 'f2000000-0000-4000-8000-000000000004'::uuid end,
  'randomized_controlled_trial', p.id, 'reported_value', 'Syntetisk testpopulasjon',
  100, 'reported_value', d.id, 'none', c.id, 'Syntetisk testutfall',
  interval '8 weeks', interval '8 weeks', 'reported_value', 'increase',
  'mean_change', case d.canonical_name when 'sertralin' then null else 0.8 end,
  case d.canonical_name when 'sertralin' then 'percent'::knowledge.estimate_unit else 'kg'::knowledge.estimate_unit end,
  case d.canonical_name when 'sertralin' then 'not_reported'::knowledge.value_availability else 'reported_value'::knowledge.value_availability end,
  'not_reported', 'Kun syntetiske data.', 'Syntetisk tabell 1', 'ai_assisted',
  jsonb_build_object('synthetic', true), pg_temp.extraction_actor_id()
from catalog.drugs d
cross join catalog.populations p
cross join catalog.clinical_concepts c
where d.canonical_name in ('sertralin', 'mirtazapin')
  and p.canonical_label = 'voksne med depressiv lidelse'
  and c.canonical_label = 'vektendring';

insert into knowledge.claims (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
select case d.canonical_name when 'sertralin' then 'f2000000-0000-4000-8000-000000000021'::uuid else 'f2000000-0000-4000-8000-000000000022'::uuid end,
       'evidence_synthesis', c.id, d.id, pg_temp.synthesis_actor_id()
from catalog.drugs d cross join catalog.clinical_concepts c
where d.canonical_name in ('sertralin', 'mirtazapin') and c.canonical_label = 'vektendring';

insert into knowledge.claim_revisions (
  id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
  population_id, timeframe_min, timeframe_max, comparator_kind, direction,
  qualifiers, uncertainty_summary, created_by_actor_id
)
select case d.canonical_name when 'sertralin' then 'f2000000-0000-4000-8000-000000000031'::uuid else 'f2000000-0000-4000-8000-000000000032'::uuid end,
       cl.id, 1, cl.knowledge_type, cl.subject_drug_id, 'Syntetisk testpåstand',
       'Kun syntetisk databasetest', p.id, interval '8 weeks', interval '8 weeks',
       'none', 'increase', 'Ingen klinisk betydning.', 'Syntetisk usikkerhet.',
       pg_temp.synthesis_actor_id()
from knowledge.claims cl
join catalog.drugs d on d.id = cl.subject_drug_id
cross join catalog.populations p
where p.canonical_label = 'voksne med depressiv lidelse';

insert into knowledge.claim_evidence_links (
  claim_revision_id, evidence_item_id, relationship_type, directness,
  relevance_note, created_by_actor_id
)
select r.id, e.id, 'supports', 'direct', 'Syntetisk relevans.', pg_temp.synthesis_actor_id()
from knowledge.claim_revisions r
join knowledge.evidence_items e on e.intervention_drug_id = r.subject_drug_id;

insert into knowledge.evidence_assessments (
  claim_revision_id, assessed_knowledge_type, framework, certainty_level,
  risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
  rationale, evidence_gap, assessed_at, created_by_actor_id
)
select r.id, r.knowledge_type, 'grade', 'very_low', 'serious', 'not_assessable',
       'not_serious', 'not_assessable', 'not_assessable',
       'Syntetisk vurdering med alle nødvendige domener.',
       'Syntetisk testgrunnlag har med vilje begrenset dekning.', now(),
       pg_temp.assessment_actor_id()
from knowledge.claim_revisions r;

-- Remove only audit rows produced by the shared synthetic graph. Tests that
-- create rows after this point still see and can assert their own audit events.
set local session_replication_role = replica;
delete from audit.events e
where not exists (select 1 from fixture_audit_baseline b where b.id = e.id);

-- Og de kjedeoverganger stillaset selv utløste, av samme grunn og på samme
-- måte. Jobber en test legger inn etter dette punktet, står urørt.
delete from workflow.pipeline_job_events e
where not exists (select 1 from fixture_pipeline_baseline b where b.id = e.pipeline_job_id);
delete from workflow.agent_handoff_jobs h
where not exists (select 1 from fixture_pipeline_baseline b where b.id = h.pipeline_job_id);
delete from workflow.pipeline_jobs j
where not exists (select 1 from fixture_pipeline_baseline b where b.id = j.id);
set local session_replication_role = origin;

-- Older invariant tests create their own source versions using the pre-Antidep-2
-- column set. For known test fixtures, complete the row at INSERT time while
-- preserving its id. Agent runs and EvidenceItems must reference exactly the
-- same source-version id.
create function pg_temp.complete_legacy_test_source_version() returns trigger language plpgsql as $$
declare
  v_prefix text := left(new.id::text, 3);
  v_title text;
begin
  select s.title into v_title from knowledge.sources s where s.id = new.source_id;

  -- 280 tests content-hash serialization, not document extraction. Its fixture
  -- predates reading-order@2 and still spells the retired @1 value explicitly.
  -- Normalize only that synthetic test source to the current safe recipe before
  -- the production full-text trigger ever sees an EvidenceItem from it.
  if v_title = 'Serialiseringstestkilde'
     and new.text_extraction_transform = 'antidep-reading-order@1' then
    new.text_extraction_transform := 'antidep-reading-order@2';
  end if;

  if v_prefix in ('340','400','440','460','470','480','490','580','590','600','610','620','630','660','670','680','690','700','710','760')
     or v_title in ('Immutabilitetstestkilde', 'Upublisert testkilde for 400',
                    'Serialiseringstestkilde') then
    new.representation := 'full_text';
    new.content_hash := coalesce(new.content_hash,
      'sha256:' || encode(extensions.digest(convert_to(new.id::text || ':text', 'UTF8'), 'sha256'), 'hex'));
    new.storage_reference := coalesce(new.storage_reference,
      'private://syntetisk-testoppsett/' || new.id::text || '/original.pdf');
    -- Digesten er avledet av bytene fiksturet faktisk legger i biblioteket
    -- etterpå, og overstyrer en oppdiktet verdi: fra migrasjon 009a *er*
    -- fingeravtrykket innholdet, og en syntetisk rad som påsto noe annet,
    -- kunne ikke lenger bære et evidensfunn.
    new.document_sha256 := pg_temp.synthetic_pdf_digest(new.id::text);
    new.document_byte_size := octet_length(pg_temp.synthetic_pdf(new.id::text));
    new.document_media_type := coalesce(new.document_media_type, 'application/pdf');
    new.text_extraction_tool := coalesce(new.text_extraction_tool, 'pdftotext');
    new.text_extraction_tool_version := coalesce(new.text_extraction_tool_version, '24.02.0');
    new.text_extraction_arguments := coalesce(new.text_extraction_arguments, '-bbox-layout -enc UTF-8 -eol unix');
    new.text_extraction_transform := coalesce(new.text_extraction_transform, 'antidep-reading-order@2');
  end if;
  return new;
end;
$$;
create trigger source_versions_complete_legacy_test_fulltext
  before insert on knowledge.source_versions
  for each row execute function pg_temp.complete_legacy_test_source_version();

-- Tests that omit source_version_id entirely predate Antidep 2. Give only those
-- rows a synthetic full-text binding. Explicit references are never remapped:
-- invalid/cross-source references must still be rejected by production rules.
create function pg_temp.bind_test_evidence_to_full_text() returns trigger language plpgsql as $$
declare
  v_version uuid;
  v_new_id uuid;
begin
  if new.source_version_id is not null then
    return new;
  end if;

  select sv.id into v_version
  from knowledge.source_versions sv
  where sv.source_id = new.source_id
    and sv.representation = 'full_text'::knowledge.source_representation
    and sv.document_sha256 ~ '^sha256:[0-9a-f]{64}$'
    and sv.document_byte_size > 0
    and sv.document_media_type = 'application/pdf'
    and sv.content_hash ~ '^sha256:[0-9a-f]{64}$'
    and sv.text_extraction_tool = 'pdftotext'
    and nullif(btrim(sv.text_extraction_tool_version), '') is not null
    and sv.text_extraction_arguments = '-bbox-layout -enc UTF-8 -eol unix'
    and sv.text_extraction_transform = 'antidep-reading-order@2'
    -- Fra migrasjon 009a holder det ikke at bindingen er komplett: filen skal
    -- ligge i biblioteket, være bundet til publikasjonen og ha bestått
    -- lesbarhetskontrollen. Gjenbruk derfor bare en versjon som har alt tre.
    and exists (
      select 1
      from knowledge.source_documents d
      join knowledge.source_document_publications dp
        on dp.source_document_id = d.id and dp.source_id = sv.source_id
      join knowledge.full_text_readability_checks rc on rc.source_version_id = sv.id
      where d.sha256 = sv.document_sha256
    )
  order by sv.created_at, sv.id
  limit 1;

  if v_version is null then
    -- Id-en genereres her og ikke av kolonnens default, fordi dokumentets
    -- fingeravtrykk må avledes av bytene fiksturet legger i biblioteket for
    -- nettopp denne versjonen.
    v_new_id := gen_random_uuid();
    insert into knowledge.source_versions (
      id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference,
      representation, retrieved_by_actor_id, document_sha256, document_byte_size,
      document_media_type, text_extraction_tool, text_extraction_tool_version,
      text_extraction_arguments, text_extraction_transform
    ) values (
      v_new_id, new.source_id, now(),
      'file:///syntetisk-testoppsett-' || new.source_id::text || '.pdf',
      'sha256:' || encode(extensions.digest(convert_to(new.source_id::text || ':test-fulltext', 'UTF8'), 'sha256'), 'hex'),
      'private://syntetisk-testoppsett/' || new.source_id::text || '/original.pdf',
      'full_text', coalesce(new.created_by_actor_id, pg_temp.extraction_actor_id()),
      pg_temp.synthetic_pdf_digest(v_new_id::text),
      octet_length(pg_temp.synthetic_pdf(v_new_id::text)),
      'application/pdf', 'pdftotext', '24.02.0',
      '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
    ) returning id into v_version;
  end if;

  new.source_version_id := v_version;
  return new;
end;
$$;
create trigger evidence_items_bind_synthetic_test_full_text
  before insert on knowledge.evidence_items
  for each row execute function pg_temp.bind_test_evidence_to_full_text();

-- Registration-order tests still exercise the durable database ordering rule
-- through a retired helper RPC. Re-open it only inside the pgTAP transaction;
-- production keeps the Antidep 2 REVOKE from migration 20260925090000.
grant execute on function api.register_publication_approval(uuid, text, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- Kandidaten publiseringsgaten krever fra migrasjon 009e
--
-- Publiseringsgatens G11 og G12 spør ikke lenger etter en publication_approval i
-- workflow.review_decisions, men etter et forseglet kandidatinnhold og en
-- navngitt fagpersons sluttkontroll av nøyaktig det avtrykket. De eldre
-- publiseringstestene er skrevet før kandidaten fantes, og gaten skal ikke mykes
-- opp for dem: hjelperen gir dem den raden regelen faktisk krever.
--
-- Hjelperen finner ikke på noe. Innholdet er knowledge.candidate_content(uuid),
-- avtrykket beregnes av innholdet av den samme funksjonen produksjonskoden
-- bruker, og sluttkontrollen er en ekte rad fra en ekte menneskelig aktør. Den
-- er idempotent, slik at en test kan kalle den etter hver endring i grunnlaget
-- uten å legge igjen en kandidat til for det samme innholdet.
-- ----------------------------------------------------------------------------
create function pg_temp.owner_actor_id() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'human:peder-holman'
$$;

/** Bare forseglingen. Ingen sluttkontroll: den er et menneskes egen handling. */
create function pg_temp.seal_candidate(p_claim_revision_id uuid)
  returns uuid language plpgsql as $$
declare
  v_content jsonb;
  v_digest text;
  v_candidate_id uuid;
begin
  v_content := knowledge.candidate_content(p_claim_revision_id);
  v_digest := knowledge.source_version_content_hash(v_content::text);

  select c.id into v_candidate_id
  from knowledge.candidates c
  where c.claim_revision_id = p_claim_revision_id and c.candidate_digest = v_digest;

  if v_candidate_id is null then
    insert into knowledge.candidates
      (claim_revision_id, candidate_digest, evidence_set_digest, content, built_by_actor_id)
    values (p_claim_revision_id, v_digest,
            knowledge.claim_evidence_set_digest(p_claim_revision_id), v_content,
            pg_temp.owner_actor_id())
    returning id into v_candidate_id;
  end if;

  return v_candidate_id;
end;
$$;

create function pg_temp.seal_and_approve_candidate(p_claim_revision_id uuid)
  returns uuid language plpgsql as $$
declare
  v_candidate_id uuid;
begin
  v_candidate_id := pg_temp.seal_candidate(p_claim_revision_id);

  -- Den *gjeldende* sluttkontrollen, ikke «finnes det en godkjenning»: en
  -- senere omgjøring gjelder foran en tidligere godkjenning, og et fikstur som
  -- overså det ville latt en test stå som grønn på en kandidat gaten stenger.
  if (workflow.current_candidate_final_control(v_candidate_id)).decision
     is distinct from 'approved'::workflow.final_control_decision then
    insert into workflow.candidate_final_controls
      (candidate_id, candidate_digest, decision, rationale,
       reviewer_actor_id, reviewer_actor_type)
    select v_candidate_id, c.candidate_digest, 'approved',
           'Syntetisk sluttkontroll i databasetest.', pg_temp.owner_actor_id(), 'human'
    from knowledge.candidates c where c.id = v_candidate_id;
  end if;

  return v_candidate_id;
end;
$$;

/** Kandidaten for én revisjon, uten å bygge en ny. NULL når ingen er forseglet. */
create function pg_temp.candidate_id_for(p_claim_revision_id uuid)
  returns uuid language sql stable as $$
  select c.id from knowledge.candidates c
  where c.claim_revision_id = p_claim_revision_id
  order by c.built_at desc, c.id desc
  limit 1
$$;

/**
 * Bindingen en publiseringshendelse må bære, for én revisjon.
 *
 * Tre oppslag framfor ett, fordi en INSERT setter kolonner hver for seg. Alle
 * tre forsegler kandidaten og sluttkontrollen om de ikke finnes, slik at en
 * eldre test som skriver en hendelse direkte, ikke må sette opp kandidaten selv
 * — og slik at den fortsatt skriver en hendelse med en ekte kandidat og en ekte
 * godkjenning bak seg, ikke med oppdiktede verdier.
 */
create function pg_temp.sealed_candidate_id(p_claim_revision_id uuid)
  returns uuid language sql as $$
  select pg_temp.seal_and_approve_candidate(p_claim_revision_id)
$$;

create function pg_temp.sealed_candidate_digest(p_claim_revision_id uuid)
  returns text language sql as $$
  select c.candidate_digest from knowledge.candidates c
  where c.id = pg_temp.seal_and_approve_candidate(p_claim_revision_id)
$$;

create function pg_temp.sealed_final_control_id(p_claim_revision_id uuid)
  returns uuid language sql as $$
  select fc.id
  from workflow.candidate_final_controls fc
  where fc.candidate_id = pg_temp.seal_and_approve_candidate(p_claim_revision_id)
    and fc.decision = 'approved'
  order by fc.registration_ordinal desc
  limit 1
$$;

/**
 * En ny sluttkontroll med utfallet `approved` på revisjonens gjeldende kandidat.
 *
 * Til forskjell fra pg_temp.seal_and_approve_candidate(uuid) skriver denne
 * alltid en ny rad. Den finnes for de testene som trenger *to* godkjenninger av
 * det samme innholdet med hvert sitt tidspunkt — for eksempel en republisering
 * på en ny gjennomgang, der hele poenget er at de to hendelsene bærer ulik
 * godkjenningsdato.
 */
create function pg_temp.approve_candidate(
  p_claim_revision_id uuid,
  p_decided_at timestamptz default now(),
  p_rationale text default 'Syntetisk sluttkontroll i databasetest.'
)
  returns uuid language plpgsql as $$
declare
  v_candidate_id uuid;
begin
  v_candidate_id := pg_temp.seal_candidate(p_claim_revision_id);

  insert into workflow.candidate_final_controls
    (candidate_id, candidate_digest, decision, rationale, decided_at,
     reviewer_actor_id, reviewer_actor_type)
  select v_candidate_id, c.candidate_digest, 'approved', p_rationale, p_decided_at,
         pg_temp.owner_actor_id(), 'human'
  from knowledge.candidates c
  where c.id = v_candidate_id;

  return v_candidate_id;
end;
$$;
