-- Antidep 2 owner-authorized, atomic, one-time removal of the known legacy prototype graph.
begin;

create table audit.prototype_resets (
  id uuid primary key default gen_random_uuid(),
  reset_id text unique not null,
  baseline_commit text not null,
  reason text not null,
  captured_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  row_counts jsonb not null,
  snapshot jsonb not null,
  snapshot_sha256 text not null check (snapshot_sha256 ~ '^[0-9a-f]{64}$')
);
comment on table audit.prototype_resets is 'Private immutable recovery snapshot for the bounded Antidep 2 prototype reset; never clinical evidence.';
comment on column audit.prototype_resets.id is 'Database-generated identity for one immutable reset snapshot.';
comment on column audit.prototype_resets.reset_id is 'Stable operational identifier that makes the one-time reset scope explicit.';
comment on column audit.prototype_resets.baseline_commit is 'Code baseline that authorized and defined the reset.';
comment on column audit.prototype_resets.reason is 'Owner-authorized reason for taking prototype results out of active use.';
comment on column audit.prototype_resets.captured_at is 'When the source rows were captured, before deletion in the same transaction.';
comment on column audit.prototype_resets.created_at is 'Database-owned time when the immutable snapshot row was recorded.';
comment on column audit.prototype_resets.row_counts is 'Exact before-count for every table in the bounded reset scope.';
comment on column audit.prototype_resets.snapshot is 'Private recovery payload; never an active clinical evidence source.';
comment on column audit.prototype_resets.snapshot_sha256 is 'SHA-256 fingerprint of the canonical JSON snapshot payload.';
alter table audit.prototype_resets enable row level security;
revoke all on audit.prototype_resets from public, anon, authenticated, service_role;

create trigger prototype_resets_reject_mutation
  before update or delete on audit.prototype_resets
  for each row execute function knowledge.reject_append_only_mutation(
    'Et reset-snapshot er et uforanderlig gjenopprettingsspor. En rettelse registreres som en ny hendelse; snapshotet endres eller slettes aldri.'
  );

-- Lock every root or dependent table before inspecting the scope. A writer that
-- committed immediately before the lock is therefore visible to the checks
-- below; a writer after the lock must wait until this transaction is finished.
lock table knowledge.publication_events, knowledge.claims, provenance.agent_runs,
  workflow.claim_verification_citations, workflow.claim_verifications,
  workflow.evidence_verifications, workflow.review_decisions,
  knowledge.evidence_assessments, knowledge.claim_evidence_links,
  knowledge.claim_revisions, knowledge.evidence_field_groundings,
  knowledge.evidence_items in access exclusive mode;

do $$
declare
  v_snapshot jsonb;
  v_counts jsonb;
  v_root_counts jsonb;
begin
  if exists (select 1 from knowledge.publication_events)
     or exists (select 1 from knowledge.claims where current_published_revision_id is not null) then
    raise exception using errcode = '23001', message = 'Antidep 2-resetten stoppet: publiseringshistorikk finnes.';
  end if;
  if exists (select 1 from provenance.agent_runs where status = 'running') then
    raise exception using errcode = '23001', message = 'Antidep 2-resetten stoppet: en agentkjøring er fortsatt åpen.';
  end if;

  -- The owner authorization covers exactly the two-item golden-slice graph
  -- present at the reviewed legacy baseline. Never turn this migration into a
  -- generic "delete all unpublished content" operation: any additional root
  -- object means the target has diverged and requires a new explicit decision.
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

  v_snapshot := jsonb_build_object(
    'claim_verification_citations', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from workflow.claim_verification_citations t),
    'claim_verifications', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from workflow.claim_verifications t),
    'evidence_verifications', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from workflow.evidence_verifications t),
    'review_decisions', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from workflow.review_decisions t),
    'evidence_assessments', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from knowledge.evidence_assessments t),
    'claim_evidence_links', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from knowledge.claim_evidence_links t),
    'claim_revisions', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from knowledge.claim_revisions t),
    'claims', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from knowledge.claims t),
    'evidence_field_groundings', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from knowledge.evidence_field_groundings t),
    'evidence_items', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from knowledge.evidence_items t)
  );
  v_counts := (select jsonb_object_agg(key, jsonb_array_length(value)) from jsonb_each(v_snapshot));
  insert into audit.prototype_resets(reset_id, baseline_commit, reason, row_counts, snapshot, snapshot_sha256)
  values ('antidep-2-reset-2026-09', 'e1a41469aca0f142da21dff8ba4b41f2cf204806',
          'Owner-approved removal of the bounded pre-Antidep-2 prototype graph', v_counts, v_snapshot,
          encode(extensions.digest(convert_to(v_snapshot::text, 'UTF8'), 'sha256'), 'hex'));

  if (select snapshot_sha256 from audit.prototype_resets where reset_id = 'antidep-2-reset-2026-09')
     <> encode(extensions.digest(convert_to(v_snapshot::text, 'UTF8'), 'sha256'), 'hex') then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: snapshotets fingeravtrykk kunne ikke verifiseres.';
  end if;
end $$;

-- Only the named append-only guards are suspended, inside this migration transaction.
alter table workflow.claim_verification_citations disable trigger claim_verification_citations_reject_mutation;
alter table workflow.claim_verifications disable trigger claim_verifications_reject_mutation;
alter table workflow.evidence_verifications disable trigger evidence_verifications_reject_mutation;
alter table workflow.review_decisions disable trigger review_decisions_reject_mutation;
alter table knowledge.evidence_assessments disable trigger evidence_assessments_reject_mutation;
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_reject_mutation;
alter table knowledge.claim_revisions disable trigger claim_revisions_reject_mutation;
alter table knowledge.evidence_field_groundings disable trigger evidence_field_groundings_reject_mutation;
alter table knowledge.evidence_items disable trigger evidence_items_reject_mutation;

delete from workflow.claim_verification_citations;
delete from workflow.claim_verifications;
delete from workflow.evidence_verifications;
delete from workflow.review_decisions;
delete from knowledge.evidence_assessments;
delete from knowledge.claim_evidence_links;
delete from knowledge.claim_revisions;
delete from knowledge.claims;
delete from knowledge.evidence_field_groundings;
delete from knowledge.evidence_items;

alter table workflow.claim_verification_citations enable trigger claim_verification_citations_reject_mutation;
alter table workflow.claim_verifications enable trigger claim_verifications_reject_mutation;
alter table workflow.evidence_verifications enable trigger evidence_verifications_reject_mutation;
alter table workflow.review_decisions enable trigger review_decisions_reject_mutation;
alter table knowledge.evidence_assessments enable trigger evidence_assessments_reject_mutation;
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_mutation;
alter table knowledge.claim_revisions enable trigger claim_revisions_reject_mutation;
alter table knowledge.evidence_field_groundings enable trigger evidence_field_groundings_reject_mutation;
alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;

commit;
