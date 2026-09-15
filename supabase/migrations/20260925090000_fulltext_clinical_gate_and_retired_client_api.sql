-- Antidep 2: preflight, structural full-text gate and retirement of the old browser workflow.
begin;

-- This PR contains two migrations because the structural gate and the one-time
-- data reset are separate concerns. The reset can intentionally fail closed.
-- Run the same reviewed preconditions here *before* changing grants or write
-- rules, so a database that is already outside the owner-authorized legacy
-- state does not get stranded with only the first half of the rollout applied.
-- The reset migration calls the function again after taking ACCESS EXCLUSIVE
-- locks, which closes the race between these two migration transactions.
create function knowledge.assert_antidep2_reset_preconditions() returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_root_counts jsonb;
begin
  if exists (select 1 from knowledge.publication_events)
     or exists (select 1 from knowledge.claims where current_published_revision_id is not null) then
    raise exception using errcode = '23001', message = 'Antidep 2-resetten stoppet: publiseringshistorikk finnes.';
  end if;

  if exists (select 1 from provenance.agent_runs where status = 'running') then
    raise exception using errcode = '23001', message = 'Antidep 2-resetten stoppet: en agentkjøring er fortsatt åpen.';
  end if;

  v_root_counts := jsonb_build_object(
    'evidence_items', (select count(*) from knowledge.evidence_items),
    'claims', (select count(*) from knowledge.claims),
    'claim_revisions', (select count(*) from knowledge.claim_revisions),
    'claim_evidence_links', (select count(*) from knowledge.claim_evidence_links),
    'evidence_assessments', (select count(*) from knowledge.evidence_assessments)
  );
  if v_root_counts <> jsonb_build_object(
       'evidence_items', 2,
       'claims', 2,
       'claim_revisions', 2,
       'claim_evidence_links', 2,
       'evidence_assessments', 2
     ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: aktivt klinisk innhold avviker fra den autoriserte legacy-baselinen.',
      detail = 'Observerte rotantall: ' || v_root_counts::text;
  end if;

  if exists (
    select 1
    from knowledge.evidence_items e
    join knowledge.sources s on s.id = e.source_id
    join catalog.drugs d on d.id = e.intervention_drug_id
    join catalog.clinical_concepts c on c.id = e.outcome_concept_id
    where c.canonical_label <> 'vektendring'
       or (d.canonical_name = 'sertralin'
           and s.title <> 'Fluoxetine versus sertraline and paroxetine in major depressive disorder: changes in weight with long-term treatment')
       or (d.canonical_name = 'mirtazapin'
           and s.title <> 'Comparison of the effects of mirtazapine and fluoxetine in severely depressed patients')
       or d.canonical_name not in ('sertralin', 'mirtazapin')
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: evidensrøttene er ikke den autoriserte legacy-prototypen.';
  end if;

  if exists (
    select 1
    from knowledge.claims cl
    join catalog.drugs d on d.id = cl.subject_drug_id
    join catalog.clinical_concepts c on c.id = cl.topic_concept_id
    where cl.knowledge_type <> 'evidence_synthesis'
       or c.canonical_label <> 'vektendring'
       or d.canonical_name not in ('sertralin', 'mirtazapin')
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: påstandsrøttene er ikke den autoriserte legacy-prototypen.';
  end if;
end;
$$;
revoke execute on function knowledge.assert_antidep2_reset_preconditions()
  from public, anon, authenticated, service_role;

select knowledge.assert_antidep2_reset_preconditions();

create function knowledge.assert_clinical_full_text(
  p_source_id uuid,
  p_source_version_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v knowledge.source_versions;
  v_status knowledge.source_status;
begin
  if p_source_version_id is null then
    raise exception using errcode = '22023', message = 'Kliniske evidensfunn krever en eksplisitt fulltekstversjon.';
  end if;

  select sv.* into v
  from knowledge.source_versions sv
  where sv.id = p_source_version_id;

  select s.source_status into v_status
  from knowledge.sources s
  where s.id = v.source_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'Kildeversjonen finnes ikke.';
  end if;
  if v.source_id <> p_source_id then
    -- Samme klasse som den sammensatte FK-en denne vakten dupliserer, slik at
    -- eldre integritetskontroller fortsatt ser dette som en referansefeil.
    raise exception using errcode = '23503', message = 'Kildeversjonen tilhører ikke evidensfunnets kilde.';
  end if;
  if v_status in ('retracted', 'withdrawn') then
    raise exception using errcode = '23001', message = 'En tilbaketrukket kilde kan ikke bære klinisk evidens.';
  end if;
  if v.representation is distinct from 'full_text'::knowledge.source_representation then
    raise exception using errcode = '23001', message = 'Abstract og begrensede representasjoner er bare til kildeoppdagelse; klinisk evidens krever fulltekst.';
  end if;
  if v.document_sha256 is null or v.document_sha256 !~ '^sha256:[0-9a-f]{64}$'
     or v.document_byte_size is null or v.document_byte_size <= 0
     or v.document_media_type is distinct from 'application/pdf'
     or v.content_hash is null or v.content_hash !~ '^sha256:[0-9a-f]{64}$'
     or v.text_extraction_tool is distinct from 'pdftotext'
     or nullif(btrim(v.text_extraction_tool_version), '') is null
     or v.text_extraction_arguments is distinct from '-bbox-layout -enc UTF-8 -eol unix'
     or v.text_extraction_transform is distinct from 'antidep-reading-order@2' then
    raise exception using
      errcode = '23001',
      message = 'Fulltekstversjonen mangler komplett dokumentbinding eller gjeldende tillatt tekstuttrekksoppskrift.';
  end if;
end;
$$;
revoke execute on function knowledge.assert_clinical_full_text(uuid, uuid) from public, anon, authenticated;

create function knowledge.enforce_evidence_full_text() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform knowledge.assert_clinical_full_text(new.source_id, new.source_version_id);
  return new;
end;
$$;
revoke execute on function knowledge.enforce_evidence_full_text() from public;
create trigger evidence_items_require_clinical_full_text
before insert on knowledge.evidence_items
for each row execute function knowledge.enforce_evidence_full_text();

-- Retire the obsolete browser workflow while preserving internal publication code.
revoke execute on function api.claim_review_workspace(uuid) from anon, authenticated;
revoke execute on function api.extraction_review_workspace(uuid) from anon, authenticated;
revoke execute on function api.register_human_claim_verification(uuid, text, text, text, text, text, text, text, text, text, jsonb, text, text) from anon, authenticated;
revoke execute on function api.register_human_extraction_verification(uuid, text, text, text, text[], text, text) from anon, authenticated;
revoke execute on function api.register_publication_approval(uuid, text, text, text) from anon, authenticated;
revoke execute on function api.publish_claim_revision(uuid, text) from anon, authenticated;
revoke execute on function api.create_evidence_item(uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text, uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric, numeric, numeric, text, text) from anon, authenticated;

commit;
