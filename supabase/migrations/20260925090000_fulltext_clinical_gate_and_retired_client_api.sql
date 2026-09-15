-- Antidep 2: one structural full-text gate used by every EvidenceItem write.
begin;

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
