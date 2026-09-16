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

  if exists (
    select 1
    from knowledge.evidence_items e
    join knowledge.source_versions sv on sv.id = e.source_version_id
    join knowledge.sources s on s.id = e.source_id
    join catalog.drugs d on d.id = e.intervention_drug_id
    join catalog.clinical_concepts c on c.id = e.outcome_concept_id
    where sv.representation is distinct from 'abstract'::knowledge.source_representation
       or c.canonical_label <> 'vektendring'
       or not (
         (d.canonical_name = 'sertralin'
          and s.title = 'Fluoxetine versus sertraline and paroxetine in major depressive disorder: changes in weight with long-term treatment'
          and exists (
            select 1
            from knowledge.source_identifiers si
            where si.source_id = e.source_id
              and si.identifier_system = 'pmid'
              and si.identifier_value = '11105740'
          ))
         or
         (d.canonical_name = 'mirtazapin'
          and s.title = 'Comparison of the effects of mirtazapine and fluoxetine in severely depressed patients'
          and exists (
            select 1
            from knowledge.source_identifiers si
            where si.source_id = e.source_id
              and si.identifier_system = 'pmid'
              and si.identifier_value = '15697327'
          ))
       )
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: evidensrøttene er ikke nøyaktig de to autoriserte abstract-baserte legacy-kildene.';
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

  -- No orphan/new claim identity is silently classified as legacy: every
  -- surviving claim must have at least one revision, every revision must be
  -- explicitly linked to an evidence root, and the claim and evidence item must
  -- concern the same drug. Because the evidence-root check above admits only
  -- the two legacy abstract rows, all linked revisions/assessments remain
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
