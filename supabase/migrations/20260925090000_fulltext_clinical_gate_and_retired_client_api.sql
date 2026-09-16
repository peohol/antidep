-- Antidep 2: read-only preflight for the owner-authorized reset.
begin;

-- This migration only installs and runs the private scope check. Do not change
-- clinical write rules or client grants here: a writer can commit between two
-- migration transactions. The next migration repeats this check under locks
-- and applies the full-text gate, RPC retirement and reset in ONE transaction.
-- If that second check fails, the legacy application remains operational;
-- only this inaccessible maintenance helper is left for the retry.
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

  -- Keep a complete count snapshot for diagnostics, but do not freeze the
  -- owner-authorized scope to one historical count of derived rows. The two
  -- legacy abstract roots were worked on further before this reset reached the
  -- hosted database: verifications, field groundings and later claim revisions
  -- are still descendants of the same pre-Antidep-2 prototype and belong in
  -- the private immutable reset snapshot. New clinical roots do not.
  v_root_counts := jsonb_build_object(
    'claim_verification_citations', (select count(*) from workflow.claim_verification_citations),
    'claim_verifications', (select count(*) from workflow.claim_verifications),
    'evidence_verifications', (select count(*) from workflow.evidence_verifications),
    'review_decisions', (select count(*) from workflow.review_decisions),
    'evidence_items', (select count(*) from knowledge.evidence_items),
    'evidence_field_groundings', (select count(*) from knowledge.evidence_field_groundings),
    'claims', (select count(*) from knowledge.claims),
    'claim_revisions', (select count(*) from knowledge.claim_revisions),
    'claim_evidence_links', (select count(*) from knowledge.claim_evidence_links),
    'evidence_assessments', (select count(*) from knowledge.evidence_assessments)
  );

  -- Human publication/review and claim-level verification are stronger
  -- boundaries than ordinary work on an unpublished prototype. If any of them
  -- happened, stop rather than interpreting that content as disposable legacy.
  if exists (select 1 from workflow.review_decisions)
     or exists (select 1 from workflow.claim_verifications)
     or exists (select 1 from workflow.claim_verification_citations) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: prototypeinnholdet har formell review eller påstandskontroll.',
      detail = 'Observerte rot- og avhengighetsantall: ' || v_root_counts::text;
  end if;

  -- The reset is authorized for exactly the two historical evidence roots.
  -- Their source versions are known MEDLINE/abstract snapshots. This is the
  -- decisive boundary: a new full-text Antidep-2 evidence item must never be
  -- swept into the one-time legacy reset, even if it concerns the same drug and
  -- outcome.
  if (select count(*) from knowledge.evidence_items) <> 2 then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: antallet evidensrøtter er ikke den autoriserte to-studiers legacy-prototypen.',
      detail = 'Observerte rot- og avhengighetsantall: ' || v_root_counts::text;
  end if;

  -- Deliberately exact, not merely an allow-list. With two rows total an
  -- allow-list alone would also accept two sertraline rows and no mirtazapine
  -- row.
  if (select array_agg(d.canonical_name order by d.canonical_name)
      from knowledge.evidence_items e
      join catalog.drugs d on d.id = e.intervention_drug_id)
     is distinct from array['mirtazapin', 'sertralin']::text[] then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: evidensrøttene har ikke nøyaktig de to autoriserte virkestoffidentitetene.';
  end if;

  -- Evidence roots are bound to the exact immutable source snapshots they were
  -- originally extracted from, not to mutable bibliographic metadata. The two
  -- source_versions were created in migration 003 with fixed SHA-256 hashes;
  -- knowledge.freeze_source_version() prevents those hashes from ever changing.
  -- This is a stronger identity boundary than current title/identifier rows:
  -- it proves which bytes the historical extraction actually read.
  if exists (
    select 1
    from knowledge.evidence_items e
    left join knowledge.source_versions sv on sv.id = e.source_version_id
    where sv.id is null
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: en historisk evidensrot mangler kildeversjon.';
  end if;

  if exists (
    select 1
    from knowledge.evidence_items e
    join knowledge.source_versions sv on sv.id = e.source_version_id
    where sv.representation is distinct from 'abstract'::knowledge.source_representation
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: en autorisert legacy-kilde er ikke lenger dokumentert som abstract-representasjon.';
  end if;

  if exists (
    select 1
    from knowledge.evidence_items e
    join catalog.clinical_concepts c on c.id = e.outcome_concept_id
    where c.canonical_label <> 'vektendring'
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: et evidensfunn har annet klinisk utfall enn den autoriserte legacy-prototypen.';
  end if;

  if exists (
    select 1
    from knowledge.evidence_items e
    join knowledge.source_versions sv on sv.id = e.source_version_id
    join catalog.drugs d on d.id = e.intervention_drug_id
    where case d.canonical_name
      when 'sertralin' then sv.content_hash is distinct from 'sha256:797e91b6c4a6c075bdde4113d263608d708fb07c3c0a7b656ff3c231d12895d3'
      when 'mirtazapin' then sv.content_hash is distinct from 'sha256:c62a66215fc51b8c164cda70072ea30ff055b7c8e565a173a0be17cdf4e75722'
      else true
    end
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: kildeversjonen er ikke ett av de to autoriserte, uforanderlige legacy-snapshotene.';
  end if;

  -- Snapshot identity is still not historical evidence-row lineage. After
  -- evidence extraction became a controlled write path, a new extraction can
  -- legitimately point to the same old source version, drug and outcome as a
  -- removed prototype row. The two authorized roots predate BOTH evidence-item
  -- agent provenance (007g) and the evidence_item_created audit trigger. Rows
  -- from before 007g were backfilled with agent_run_id = NULL, and the audit
  -- trigger was not retroactive. Any later editor or agent replacement therefore
  -- has agent_run_id and/or a creation audit. Require both historical markers so
  -- a semantically identical replacement is never classified as disposable
  -- legacy content.
  if exists (
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
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: en evidensrot kan ikke bevises å være et historisk prototypefunn.',
      detail = 'En autorisert legacy-evidensrot skal være fra før både agentkjørings-proveniens og evidence_item_created-audit ble innført.';
  end if;

  -- Claims are derived content, so one of the historical roots may already have
  -- been retired/removed and a remaining root may have gained later revisions.
  -- Accept that evolution only while every surviving claim is still a unique
  -- weight-change synthesis for one of the two legacy drugs.
  if (select count(*) from knowledge.claims) > 2
     or (select count(*) from knowledge.claims)
        <> (select count(distinct subject_drug_id) from knowledge.claims) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: påstandsrøttene er ikke et delsett av den autoriserte legacy-prototypen.';
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
      message = 'Antidep 2-resetten stoppet: en påstandsrot ligger utenfor den autoriserte legacy-prototypen.';
  end if;

  -- Drug/topic identity is not historical lineage. After claim-synthesis became
  -- an agent write path, a new claim can legitimately have the same drug, topic
  -- and legacy evidence as a removed prototype claim. The authorized roots are
  -- distinguishable without hard-coded random UUIDs: their revision 1 rows were
  -- inserted by migration 004, before claim-revision agent provenance and the
  -- claim_revision_created audit trigger existed. A later claim therefore has
  -- agent_run_id and/or a creation audit for revision 1. Require BOTH historical
  -- markers so a newly-created replacement root can never be swept into this
  -- destructive one-time reset merely because it looks semantically identical.
  if exists (
    select 1
    from knowledge.claims cl
    where not exists (
      select 1
      from knowledge.claim_revisions r
      where r.claim_id = cl.id
        and r.revision_number = 1
        and r.agent_run_id is null
        and not exists (
          select 1
          from audit.events ae
          where ae.operation = 'claim_revision_created'
            and ae.object_id = r.id
        )
    )
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: en påstandsrot kan ikke bevises å være en historisk prototypepåstand.',
      detail = 'En autorisert legacy-påstand skal ha revisjon 1 fra før agentkjørings-proveniens og revisjonsaudit ble innført.';
  end if;

  -- No orphan/new claim identity is silently classified as legacy: every
  -- surviving claim must have at least one revision, every revision must be
  -- explicitly linked to an evidence root, and the claim and evidence item must
  -- concern the same drug. Because the evidence-root check above admits only
  -- the two historical source snapshots, all linked revisions/assessments remain
  -- structurally inside that bounded graph.
  if exists (
    select 1
    from knowledge.claims cl
    where not exists (
      select 1 from knowledge.claim_revisions r where r.claim_id = cl.id
    )
  ) or exists (
    select 1
    from knowledge.claim_revisions r
    where not exists (
      select 1 from knowledge.claim_evidence_links l where l.claim_revision_id = r.id
    )
  ) or exists (
    select 1
    from knowledge.claim_evidence_links l
    join knowledge.claim_revisions r on r.id = l.claim_revision_id
    join knowledge.claims cl on cl.id = r.claim_id
    join knowledge.evidence_items e on e.id = l.evidence_item_id
    where cl.subject_drug_id <> e.intervention_drug_id
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: avledet påstandsinnhold kan ikke bindes entydig til de autoriserte legacy-røttene.',
      detail = 'Observerte rot- og avhengighetsantall: ' || v_root_counts::text;
  end if;
end;
$$;
revoke execute on function knowledge.assert_antidep2_reset_preconditions()
  from public, anon, authenticated, service_role;

select knowledge.assert_antidep2_reset_preconditions();

commit;
