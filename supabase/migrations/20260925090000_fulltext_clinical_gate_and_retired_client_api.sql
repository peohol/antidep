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

  -- Owner authorization covers the exact reviewed legacy graph, including the
  -- absence of later review/verification/grounding rows. Every table that the
  -- reset migration deletes is therefore part of this guard.
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
  if v_root_counts <> jsonb_build_object(
       'claim_verification_citations', 0,
       'claim_verifications', 0,
       'evidence_verifications', 0,
       'review_decisions', 0,
       'evidence_items', 2,
       'evidence_field_groundings', 0,
       'claims', 2,
       'claim_revisions', 2,
       'claim_evidence_links', 2,
       'evidence_assessments', 2
     ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: aktivt klinisk innhold avviker fra den autoriserte legacy-baselinen.',
      detail = 'Observerte rot- og avhengighetsantall: ' || v_root_counts::text;
  end if;

  -- The set check below is deliberately exact, not merely an allow-list. With
  -- two rows total, an allow-list alone would also accept two sertraline rows
  -- and no mirtazapine row.
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

  if (select array_agg(d.canonical_name order by d.canonical_name)
      from knowledge.claims cl
      join catalog.drugs d on d.id = cl.subject_drug_id)
     is distinct from array['mirtazapin', 'sertralin']::text[] then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: påstandsrøttene har ikke nøyaktig de to autoriserte virkestoffidentitetene.';
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

commit;
