-- Antidep 2: read-only fail-closed diagnostics for hosted legacy source drift.
--
-- Production has already passed the reset's root-count, drug-identity and
-- historical-lineage checks, but one evidence root does not point at the exact
-- immutable source-version hash seeded by migration 003. We cannot inspect the
-- hosted database directly, so expose only the minimum non-sensitive metadata
-- needed to distinguish a different historical snapshot from a different root.
--
-- This migration never repairs, reclassifies or deletes anything. On the known
-- local legacy fixture it is a no-op. It emits diagnostics only when the graph
-- is still bounded to exactly the two pre-agent, pre-audit evidence roots and
-- one of their immutable source snapshots differs from the authorized seed.
begin;

do $diagnostic$
declare
  r record;
  v_expected_hash text;
  v_expected_pmid text;
  v_expected_external_version text;
  v_expected_retrieved_from text;
begin
  -- Do not disclose snapshot metadata for an arbitrary/new clinical graph.
  -- If the scope is not the exact historical-looking pair, the existing reset
  -- preflight remains authoritative and will stop with its normal generic error.
  if (select count(*) from knowledge.evidence_items) <> 2
     or (select array_agg(d.canonical_name order by d.canonical_name)
         from knowledge.evidence_items e
         join catalog.drugs d on d.id = e.intervention_drug_id)
        is distinct from array['mirtazapin', 'sertralin']::text[]
     or exists (
       select 1
       from knowledge.evidence_items e
       where e.agent_run_id is not null
          or exists (
            select 1
            from audit.events ae
            where ae.operation = 'evidence_item_created'
              and ae.object_id = e.id
          )
     ) then
    return;
  end if;

  for r in
    select
      d.canonical_name as drug,
      sv.content_hash,
      sv.representation::text as representation,
      sv.retrieved_at,
      sv.retrieved_from,
      sv.external_version
    from knowledge.evidence_items e
    join knowledge.source_versions sv on sv.id = e.source_version_id
    join catalog.drugs d on d.id = e.intervention_drug_id
    order by d.canonical_name
  loop
    case r.drug
      when 'sertralin' then
        v_expected_hash := 'sha256:797e91b6c4a6c075bdde4113d263608d708fb07c3c0a7b656ff3c231d12895d3';
        v_expected_pmid := '11105740';
        v_expected_external_version := 'MEDLINE DateRevised 2026-01-28';
      when 'mirtazapin' then
        v_expected_hash := 'sha256:c62a66215fc51b8c164cda70072ea30ff055b7c8e565a173a0be17cdf4e75722';
        v_expected_pmid := '15697327';
        v_expected_external_version := 'MEDLINE DateRevised 2018-12-01';
      else
        -- The exact drug-pair guard above makes this unreachable. Keep the
        -- diagnostic itself fail-closed if the query is changed later.
        raise exception using
          errcode = '23001',
          message = 'Antidep 2-resetten stoppet: snapshot-diagnostikken traff en uventet evidensrot.';
    end case;

    v_expected_retrieved_from :=
      'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id='
      || v_expected_pmid || '&retmode=xml';

    if r.content_hash is distinct from v_expected_hash then
      raise exception using
        errcode = '23001',
        message = format(
          'Antidep 2-resetten stoppet: kildeversjonen er ikke ett av de to autoriserte, uforanderlige legacy-snapshotene. Sikker snapshot-diagnostikk: virkestoff=%s; faktisk_hash=%s; forventet_pmid_match=%s; hentetid_match=%s; kildeadresse_match=%s; ekstern_versjon_match=%s; representasjon=%s.',
          r.drug,
          coalesce(r.content_hash, 'NULL'),
          exists (
            select 1
            from knowledge.evidence_items e2
            join knowledge.source_identifiers si on si.source_id = e2.source_id
            join catalog.drugs d2 on d2.id = e2.intervention_drug_id
            where d2.canonical_name = r.drug
              and si.identifier_system = 'pmid'
              and si.identifier_value = v_expected_pmid
          ),
          r.retrieved_at is not distinct from timestamptz '2026-08-19T06:17:31Z',
          r.retrieved_from is not distinct from v_expected_retrieved_from,
          r.external_version is not distinct from v_expected_external_version,
          coalesce(r.representation, 'NULL')
        );
    end if;
  end loop;
end;
$diagnostic$;

commit;
