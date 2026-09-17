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
  -- The owner authorized this reset in commit
  -- e1a41469aca0f142da21dff8ba4b41f2cf204806 ("docs: planlegg Antidep 2-reset
  -- for Codex"). Everything the owner authorized removing already existed at
  -- that instant, so the authorization time is the boundary between disposable
  -- prototype content and content nobody has authorized deleting.
  --
  -- audit.events is append-only and its occurred_at is written by the audit
  -- trigger's own now() (audit.record_evidence_item_event), never by the
  -- caller. It is therefore a clock no write path can backdate, and it is the
  -- primitive every lineage check below rests on.
  v_authorized_at constant timestamptz := timestamptz '2026-09-14T08:46:42Z';

  -- Both legacy source snapshots were seeded with this single retrieval time in
  -- migration 20260819064500, which has never been rewritten.
  v_legacy_retrieved_at constant timestamptz := timestamptz '2026-08-19T06:17:31Z';

  -- One authoritative table of the immutable identities this reset is
  -- authorized for, keyed by the drug identity of the evidence root so no check
  -- below repeats a literal. The snapshot_* values are the repo-seeded MEDLINE
  -- snapshots from migration 20260819064500, kept immutable by
  -- knowledge.freeze_source_version(). The evolved_* values are the content,
  -- grounding and model-request digests of the two full-text re-extractions the
  -- owner authorized; every one of them is append-only or frozen in place.
  v_authorized constant jsonb := jsonb_build_object(
    'sertralin', jsonb_build_object(
      'pmid', '11105740',
      'snapshot_content_hash', 'sha256:797e91b6c4a6c075bdde4113d263608d708fb07c3c0a7b656ff3c231d12895d3',
      'snapshot_retrieved_from', 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id=11105740&retmode=xml',
      'snapshot_external_version', 'MEDLINE DateRevised 2026-01-28',
      'evolved_content_hash', 'sha256-v3:cc4fc45130204ea17ff3456d10a94f00125008ed2f93e24e0cc2b5a5f09d1e12',
      'evolved_grounding_digest', 'sha256-v1:444d6bd33d1be8edd9626fedde14a4b40b8cac24ef6a8308ab07072fcc91924a',
      'evolved_request_digest', 'sha256:43971be1e4a28cd1ce5d1d55456256762fa9cd56fa6fb4d8a7c69399e5850810'
    ),
    'mirtazapin', jsonb_build_object(
      'pmid', '15697327',
      'snapshot_content_hash', 'sha256:c62a66215fc51b8c164cda70072ea30ff055b7c8e565a173a0be17cdf4e75722',
      'snapshot_retrieved_from', 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id=15697327&retmode=xml',
      'snapshot_external_version', 'MEDLINE DateRevised 2018-12-01',
      'evolved_content_hash', 'sha256-v3:a271c1c7917ba9bf493e74b106d7d91c5826dab04a61a77a69f103f82307ae3b',
      'evolved_grounding_digest', 'sha256-v1:2574bc207d68e1e844f76ef453d75e59c39725d177a8ffcb3fea1afe30eb25a6',
      'evolved_request_digest', 'sha256:67296bc917398cd95de2bb8cb9e0167e3cb7bb0112a7d11e5690322f46650fc0'
    )
  );

  -- knowledge.claim_revisions.content_hash for the one surviving authorized
  -- synthesis root. Both its revisions carry the same content identity, because
  -- the second synthesis reproduced the same statement.
  v_authorized_claim_hashes constant text[] := array[
    'sha256-v1:f551ac1d26a15a1cd84dba7a44c40c4ede5621796e2bc307f51bd4e0ef4ed052'
  ];
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

  -- The master boundary, checked before any identity detail. The authorization
  -- covers the prototype graph as it stood at v_authorized_at; a clinical root
  -- the audit trigger stamped after that instant is content nobody authorized
  -- deleting, whatever it looks like. Only audit events whose row still exists
  -- count, so the prototype artifacts the owner discarded on 2026-09-12 — which
  -- keep their creation audit forever — cannot block their own reset.
  if exists (
    select 1
    from audit.events ae
    where ae.operation in ('evidence_item_created', 'claim_revision_created')
      and ae.occurred_at >= v_authorized_at
      and (
        exists (select 1 from knowledge.evidence_items e where e.id = ae.object_id)
        or exists (select 1 from knowledge.claim_revisions r where r.id = ae.object_id)
      )
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: det finnes klinisk innhold opprettet etter at resetten ble autorisert.',
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

  -- Anchor every evidence root to an intact, immutable legacy source snapshot
  -- before any mutable or later-backfilled metadata is consulted. The anchor is
  -- the repo-seeded MEDLINE snapshot itself: its content hash, retrieval time,
  -- EUtils address and external version must all still be exactly what
  -- migration 20260819064500 wrote, and the source must still carry the
  -- authorized PMID. That proves which bytes the legacy prototype read, and it
  -- is a stronger identity than any current title or identifier row.
  --
  -- Two source-version lineages are authorized, and only two:
  --
  --   1. the seeded abstract snapshot itself, which is the state the repo
  --      baseline is in; and
  --   2. a full-text representation of the SAME anchored source, registered
  --      before the owner authorized the reset. This is the hosted state: the
  --      abstract-derived roots were discarded in production on 2026-09-12
  --      (audit.events, extraction_artifact_discarded, issue #84) and the two
  --      studies were re-extracted from their registered full text before the
  --      authorization instant.
  --
  -- A full-text version registered after the authorization can never anchor a
  -- root, so a later Antidep 2 extraction is outside the reset by construction.
  if exists (
    select 1
    from knowledge.evidence_items e
    join catalog.drugs d on d.id = e.intervention_drug_id
    join knowledge.source_versions sv on sv.id = e.source_version_id
    left join lateral (
      select a.id
      from knowledge.source_versions a
      where a.source_id = e.source_id
        and a.representation = 'abstract'::knowledge.source_representation
        and a.content_hash = v_authorized -> d.canonical_name ->> 'snapshot_content_hash'
        and a.retrieved_at = v_legacy_retrieved_at
        and a.retrieved_from = v_authorized -> d.canonical_name ->> 'snapshot_retrieved_from'
        and a.external_version = v_authorized -> d.canonical_name ->> 'snapshot_external_version'
      limit 1
    ) anchor on true
    where anchor.id is null
       or not exists (
         select 1
         from knowledge.source_identifiers si
         where si.source_id = e.source_id
           and si.identifier_system = 'pmid'
           and si.identifier_value = v_authorized -> d.canonical_name ->> 'pmid'
       )
       -- coalesce, because an unknown lineage must read as a violation. A null
       -- representation would otherwise make the whole comparison null, and
       -- WHERE reads null as "no violation" — fail-open, in the one check whose
       -- whole purpose is to fail closed.
       or not coalesce(
         sv.id = anchor.id
         or (
           sv.source_id = e.source_id
           and sv.representation = 'full_text'::knowledge.source_representation
           and sv.created_at < v_authorized_at
         ),
         false
       )
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: kildeversjonen er ikke ett av de to autoriserte, uforanderlige legacy-snapshotene.',
      detail = (
        -- Bounded, non-sensitive metadata only: which drug, which snapshot the
        -- root points at, and which of the anchor conditions failed. No source
        -- text and no extracted clinical content are ever logged.
        select format(
          'Virkestoff=%s; rotens_kildeversjon=%s; representasjon=%s; kildeversjon_registrert=%s; uforanderlig_anker_finnes=%s; pmid_match=%s.',
          d.canonical_name,
          coalesce(sv.content_hash, 'NULL'),
          coalesce(sv.representation::text, 'NULL'),
          sv.created_at,
          exists (
            select 1
            from knowledge.source_versions a
            where a.source_id = e.source_id
              and a.representation = 'abstract'::knowledge.source_representation
              and a.content_hash = v_authorized -> d.canonical_name ->> 'snapshot_content_hash'
              and a.retrieved_at = v_legacy_retrieved_at
              and a.retrieved_from = v_authorized -> d.canonical_name ->> 'snapshot_retrieved_from'
              and a.external_version = v_authorized -> d.canonical_name ->> 'snapshot_external_version'
          ),
          exists (
            select 1
            from knowledge.source_identifiers si
            where si.source_id = e.source_id
              and si.identifier_system = 'pmid'
              and si.identifier_value = v_authorized -> d.canonical_name ->> 'pmid'
          )
        )
        from knowledge.evidence_items e
        join catalog.drugs d on d.id = e.intervention_drug_id
        join knowledge.source_versions sv on sv.id = e.source_version_id
        order by d.canonical_name
        limit 1
      );
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

  -- Anchored source identity is still not evidence-row lineage. A new
  -- extraction can legitimately point at the same anchored source, drug and
  -- outcome as a removed prototype row, so each root must positively prove it
  -- is one of exactly two documented historical lineages.
  if exists (
    select 1
    from knowledge.evidence_items e
    join catalog.drugs d on d.id = e.intervention_drug_id
    join knowledge.source_versions sv on sv.id = e.source_version_id
    -- coalesce for the same reason as above: a null digest or representation
    -- makes the comparison null, and an unproven lineage must read as a
    -- violation rather than as silence.
    where not coalesce(
      -- Lineage 1 — seeded prototype root. Inserted by migration
      -- 20260819064500, before BOTH evidence-item agent provenance (007g) and
      -- the evidence_item_created audit trigger (008b). Rows from before 007g
      -- were backfilled with agent_run_id = NULL and the audit trigger was not
      -- retroactive, and neither marker can be produced again: every current
      -- write path registers an agent run, and the trigger fires on every
      -- insert. This is the repo baseline's lineage.
      (
        sv.representation = 'abstract'::knowledge.source_representation
        and e.agent_run_id is null
        and not exists (
          select 1
          from audit.events ae
          where ae.operation = 'evidence_item_created'
            and ae.object_id = e.id
        )
      )
      or
      -- Lineage 2 — the authorized full-text re-extraction. This is the hosted
      -- lineage, and it is agent-created, so provenance alone cannot separate
      -- it from a later replacement. Three immutable digests do: the exact
      -- content hash, the exact grounding digest, and the exact model-request
      -- digest recorded in the extraction run's input manifest. A semantically
      -- identical re-run would reproduce the content hash — that is what a
      -- content hash is for — but never the request digest of this one
      -- historical request, and the append-only audit trigger would stamp its
      -- creation after the authorization instant.
      (
        sv.representation = 'full_text'::knowledge.source_representation
        and e.content_hash = v_authorized -> d.canonical_name ->> 'evolved_content_hash'
        and e.grounding_digest = v_authorized -> d.canonical_name ->> 'evolved_grounding_digest'
        and exists (
          select 1
          from audit.events ae
          where ae.operation = 'evidence_item_created'
            and ae.object_id = e.id
            and ae.occurred_at < v_authorized_at
        )
        and exists (
          select 1
          from provenance.agent_runs ar
          where ar.id = e.agent_run_id
            and ar.agent_role = 'evidence_extraction'
            and ar.status = 'succeeded'
            and ar.completed_at < v_authorized_at
            and ar.input_source_version_id = e.source_version_id
            and ar.input_manifest -> 'generated_by' ->> 'request_digest'
                = v_authorized -> d.canonical_name ->> 'evolved_request_digest'
        )
      ),
      false
    )
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: en evidensrot kan ikke bevises å være et historisk prototypefunn.',
      detail = 'En autorisert legacy-evidensrot er enten seedet før agentproveniens og creation-audit, eller nøyaktig den uforanderlige fulltekst-reekstraksjonen eieren autoriserte før resetten.';
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

  -- Drug/topic identity is not historical lineage either. After claim synthesis
  -- became an agent write path, a new claim can carry the same drug, topic and
  -- legacy evidence as a removed prototype claim. As for the evidence roots,
  -- exactly two lineages are authorized, and neither uses a hard-coded random
  -- UUID.
  if exists (
    select 1
    from knowledge.claims cl
    where not coalesce(
      -- Lineage 1 — seeded prototype claim. Revision 1 was inserted by
      -- migration 20260819124500, before claim-revision agent provenance and
      -- the claim_revision_created audit trigger existed.
      exists (
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
      or
      -- Lineage 2 — the authorized hosted synthesis root. Every one of its
      -- revisions must carry an authorized content identity AND a creation
      -- audit the trigger stamped before the authorization instant. A
      -- replacement synthesis run — even one reproducing the same statement and
      -- therefore the same content hash — is stamped after the boundary.
      (
        exists (
          select 1
          from knowledge.claim_revisions r
          where r.claim_id = cl.id
            and r.revision_number = 1
        )
        and not exists (
          select 1
          from knowledge.claim_revisions r
          where r.claim_id = cl.id
            and (
              r.content_hash is null
              or not (r.content_hash = any (v_authorized_claim_hashes))
              or not exists (
                select 1
                from audit.events ae
                where ae.operation = 'claim_revision_created'
                  and ae.object_id = r.id
                  and ae.occurred_at < v_authorized_at
              )
            )
        )
      ),
      false
    )
  ) then
    raise exception using
      errcode = '23001',
      message = 'Antidep 2-resetten stoppet: en påstandsrot kan ikke bevises å være en historisk prototypepåstand.',
      detail = 'En autorisert legacy-påstand har enten revisjon 1 fra før agentkjørings-proveniens og revisjonsaudit, eller nøyaktig den autoriserte innholdsidentiteten med revisjonsaudit fra før resetten ble autorisert.';
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
