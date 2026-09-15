#!/usr/bin/env bash
# Regression test for the Antidep 2 one-time reset as an upgrade, not a fresh install.
set -euo pipefail
cd "$(dirname "$0")/.."

LAST_LEGACY=20260924095000
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

DB_URL=$(npx --no-install supabase status -o json 2>/dev/null | node -e '
  let data = ""
  process.stdin.on("data", (chunk) => (data += chunk)).on("end", () => {
    try { process.stdout.write(JSON.parse(data).DB_URL ?? "") } catch { process.stdout.write("") }
  })
')

# A localhost-looking URI can still redirect libpq through query parameters or
# service/hostaddr defaults. Reject it before any SQL or destructive db reset.
node scripts/local-test-db.mjs "$DB_URL"

scalar() {
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -t -A -c "$1" | tr -d '\r\n'
}

fail() {
  printf 'FEIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual=$1 expected=$2 message=$3
  [ "$actual" = "$expected" ] || fail "$message (forventet $expected, fikk $actual)"
}

assert_gt_zero() {
  local actual=$1 message=$2
  [ "$actual" -gt 0 ] || fail "$message (fikk $actual)"
}

reset_legacy() {
  npx --no-install supabase db reset --version "$LAST_LEGACY" --no-seed >/dev/null
}

expect_upgrade_failure() {
  local label=$1
  if npx --no-install supabase migration up --local >"$TMP_DIR/$label.log" 2>&1; then
    cat "$TMP_DIR/$label.log" >&2
    fail "oppgraderingen skulle ha stoppet i scenarioet $label"
  fi
}

assert_preflight_left_no_partial_rollout() {
  assert_eq "$(scalar "select coalesce(to_regprocedure('knowledge.assert_clinical_full_text(uuid,uuid)')::text, '')")" '' \
    'preflight-stopp etterlot fulltekstvakten halvveis installert'
  assert_eq "$(scalar "select coalesce(to_regprocedure('knowledge.assert_antidep2_reset_preconditions()')::text, '')")" '' \
    'preflight-stopp etterlot vedlikeholdsfunksjonen fra første migrasjon'
}

printf 'Antidep 2: oppgraderingsprøve fra legacy-baseline.\n'

# 1. The actual pre-reset legacy database already contains the prototype graph.
# Upgrade that real state, snapshot it, and empty only the derived clinical layer.
reset_legacy
before_evidence=$(scalar 'select count(*) from knowledge.evidence_items')
before_claims=$(scalar 'select count(*) from knowledge.claims')
before_sources=$(scalar 'select count(*) from knowledge.sources')
assert_gt_zero "$before_evidence" 'legacy-baselinen mangler evidensfunn'
assert_gt_zero "$before_claims" 'legacy-baselinen mangler påstander'

npx --no-install supabase migration up --local >"$TMP_DIR/success.log" 2>&1
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '0' 'resetten lot evidensfunn stå aktive'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" '0' 'resetten lot påstander stå aktive'
assert_eq "$(scalar 'select count(*) from audit.prototype_resets')" '1' 'resetten skrev ikke nøyaktig ett snapshot'
assert_eq "$(scalar "select jsonb_array_length(snapshot -> 'evidence_items') from audit.prototype_resets")" "$before_evidence" 'snapshotet dekker ikke alle evidensfunnene'
assert_eq "$(scalar "select jsonb_array_length(snapshot -> 'claims') from audit.prototype_resets")" "$before_claims" 'snapshotet dekker ikke alle påstandene'
assert_eq "$(scalar 'select count(*) from knowledge.sources')" "$before_sources" 'resetten endret kildebiblioteket'
assert_eq "$(scalar "select coalesce(to_regprocedure('knowledge.assert_antidep2_reset_preconditions()')::text, '')")" '' 'vellykket reset etterlot en vedlikeholdsfunksjon'

# Create genuinely new Antidep 2 content after the reset. A literal rerun of the
# one-time migration must fail before touching it.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
-- From migration 009a a clinical full text must have its original file in the
-- private library, be shown to belong to the publication, and have passed the
-- readability check. The library computes the digest from the bytes, so this
-- fixture needs real bytes rather than an invented digest.
create temporary table rerun_guard_pdf as
select convert_to('%PDF-1.7' || E'\nantidep2-rerun-guard\n%%EOF\n', 'UTF8') as bytes;

insert into knowledge.source_documents
  (sha256, byte_size, media_type, content, stored_by_actor_id)
select knowledge.source_document_fingerprint(g.bytes), octet_length(g.bytes),
       'application/pdf', g.bytes, a.id
from rerun_guard_pdf g
join provenance.actors a on a.actor_key = 'agent:evidence-extraction'
on conflict (sha256) do nothing;

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference,
  representation, retrieved_by_actor_id, document_sha256, document_byte_size,
  document_media_type, text_extraction_tool, text_extraction_tool_version,
  text_extraction_arguments, text_extraction_transform
)
select
  'fa200000-0000-4000-8000-000000000002'::uuid,
  s.id, now(), 'file:///antidep2-rerun-guard.pdf',
  'sha256:' || repeat('a', 64), 'private://antidep2-rerun-guard.pdf',
  'full_text', a.id, knowledge.source_document_fingerprint(g.bytes),
  octet_length(g.bytes), 'application/pdf',
  'pdftotext', '24.02.0', '-bbox-layout -enc UTF-8 -eol unix',
  'antidep-reading-order@2'
from knowledge.sources s
join provenance.actors a on a.actor_key = 'agent:evidence-extraction'
cross join rerun_guard_pdf g
order by s.id
limit 1;

insert into knowledge.source_document_publications
  (source_document_id, source_id, binding_basis, binding_evidence, bound_by_actor_id)
select d.id, sv.source_id, 'title', 'syntetisk binding for omkjøringsvakten',
       sv.retrieved_by_actor_id
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = 'fa200000-0000-4000-8000-000000000002'
on conflict on constraint source_document_publications_pairing_key do nothing;

insert into knowledge.full_text_readability_checks
  (source_version_id, source_document_id, character_count, letter_count,
   line_count, table_row_count, table_declaration_count)
select sv.id, d.id, 20000, 15000, 400, 12, 3
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = 'fa200000-0000-4000-8000-000000000002';

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability,
  population_detail, sample_size_availability, intervention_drug_id,
  comparator_kind, outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
select
  'fa200000-0000-4000-8000-000000000001'::uuid,
  sv.source_id, sv.id, 'randomized_controlled_trial', 'not_reported',
  'Syntetisk Antidep 2-testpopulasjon', 'not_reported', d.id, 'none', c.id,
  'Syntetisk Antidep 2-testutfall', 'not_reported', 'increase', 'not_reported',
  'not_reported', 'Syntetisk fulltekst, side 1', 'ai_assisted', a.id
from knowledge.source_versions sv
join catalog.drugs d on d.canonical_name = 'sertralin'
join catalog.clinical_concepts c on c.canonical_label = 'vektendring'
join provenance.actors a on a.actor_key = 'agent:evidence-extraction'
where sv.id = 'fa200000-0000-4000-8000-000000000002';
SQL
assert_eq "$(scalar "select count(*) from knowledge.evidence_items where id = 'fa200000-0000-4000-8000-000000000001'")" '1' 'klarte ikke å opprette nytt Antidep 2-funn etter reset'
if psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20260925091000_reset_active_prototype_content.sql \
  >"$TMP_DIR/rerun.log" 2>&1; then
  cat "$TMP_DIR/rerun.log" >&2
  fail 'engangsresetten lot seg kjøre bokstavelig en gang til'
fi
assert_eq "$(scalar "select count(*) from knowledge.evidence_items where id = 'fa200000-0000-4000-8000-000000000001'")" '1' 'en omkjøring slettet nytt Antidep 2-innhold'

# 2. Any publication history aborts before the first structural change.
reset_legacy
before_evidence=$(scalar 'select count(*) from knowledge.evidence_items')
before_claims=$(scalar 'select count(*) from knowledge.claims')
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
insert into knowledge.publication_events (
  claim_id, action, revision_id, revision_number,
  previous_revision_id, previous_revision_number, previous_event_id,
  published_by_actor_id, published_by_actor_type, reason, published_at
)
select r.claim_id, 'publish', r.id, r.revision_number,
       null, null, null, a.id, 'human',
       'Syntetisk publiseringshistorikk som skal blokkere Antidep 2-resetten.', now()
from knowledge.claim_revisions r
cross join lateral (
  select id from provenance.actors where actor_key = 'human:peder-holman'
) a
order by r.id
limit 1;
SQL
assert_gt_zero "$(scalar 'select count(*) from knowledge.publication_events')" 'klarte ikke å etablere publiseringshistorikk for stopptesten'
expect_upgrade_failure publication-history
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" "$before_evidence" 'publiseringsstopp etterlot delvis slettet evidens'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" "$before_claims" 'publiseringsstopp etterlot delvis slettede påstander'
assert_eq "$(scalar "select coalesce(to_regclass('audit.prototype_resets')::text, '')")" '' 'publiseringsstopp etterlot et snapshot fra en rullet tilbake reset'
assert_preflight_left_no_partial_rollout

# 3. An open, structurally valid agent run likewise aborts before structural changes.
reset_legacy
before_evidence=$(scalar 'select count(*) from knowledge.evidence_items')
before_claims=$(scalar 'select count(*) from knowledge.claims')
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
insert into provenance.agent_runs (
  agent_identity_id, actor_id, agent_role,
  provider, model, model_version, prompt_template_version, pipeline_version,
  status, input_manifest
)
select ai.id, ai.actor_id, ai.agent_role,
       'antidep-test', 'upgrade-blocker', '1', 'test', 'test',
       'running', '{"evidence_item_ids":["upgrade-blocker"]}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';
SQL
assert_gt_zero "$(scalar "select count(*) from provenance.agent_runs where status = 'running'")" 'klarte ikke å etablere åpen agentkjøring for stopptesten'
expect_upgrade_failure open-agent-run
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" "$before_evidence" 'agentstopp etterlot delvis slettet evidens'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" "$before_claims" 'agentstopp etterlot delvis slettede påstander'
assert_eq "$(scalar "select coalesce(to_regclass('audit.prototype_resets')::text, '')")" '' 'agentstopp etterlot et snapshot fra en rullet tilbake reset'
assert_preflight_left_no_partial_rollout

# 4. Any additional clinical root is outside the owner-authorized reset scope.
# The migration must fail closed rather than silently treating it as prototype data.
reset_legacy
before_evidence=$(scalar 'select count(*) from knowledge.evidence_items')
before_claims=$(scalar 'select count(*) from knowledge.claims')
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
insert into knowledge.claims (
  knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id
)
select 'evidence_synthesis', c.id, d.id, a.id
from catalog.drugs d
cross join catalog.clinical_concepts c
cross join provenance.actors a
where d.canonical_name = 'sertralin'
  and c.canonical_label <> 'vektendring'
  and a.actor_key = 'agent:claim-synthesis'
order by c.id
limit 1;
SQL
unexpected_claims=$(scalar 'select count(*) from knowledge.claims')
assert_eq "$unexpected_claims" "$((before_claims + 1))" 'klarte ikke å etablere uventet klinisk rot for scope-testen'
expect_upgrade_failure unexpected-scope
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" "$before_evidence" 'scope-stopp etterlot delvis slettet evidens'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" "$unexpected_claims" 'scope-stopp slettet uventet klinisk innhold'
assert_eq "$(scalar "select coalesce(to_regclass('audit.prototype_resets')::text, '')")" '' 'scope-stopp etterlot et snapshot fra en rullet tilbake reset'
assert_preflight_left_no_partial_rollout

# 5. Reproduce the transaction-boundary race without timing assumptions: commit
# the preflight migration, start a new agent run, then execute the reset. A
# second-preflight failure must preserve BOTH the old data and old RPC grants.
reset_legacy
before_evidence=$(scalar 'select count(*) from knowledge.evidence_items')
before_claims=$(scalar 'select count(*) from knowledge.claims')
rpc_grants_sql="select jsonb_agg(jsonb_build_object(
  'function', p.oid::regprocedure::text,
  'anon', has_function_privilege('anon', p.oid, 'EXECUTE'),
  'authenticated', has_function_privilege('authenticated', p.oid, 'EXECUTE')
) order by p.oid)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'api' and p.proname = any (array[
  'claim_review_workspace', 'extraction_review_workspace',
  'register_human_claim_verification', 'register_human_extraction_verification',
  'register_publication_approval', 'publish_claim_revision', 'create_evidence_item'
])"
before_grants=$(scalar "$rpc_grants_sql")
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 \
  -f supabase/migrations/20260925090000_fulltext_clinical_gate_and_retired_client_api.sql \
  >"$TMP_DIR/preflight-only.log" 2>&1
assert_eq "$(scalar "$rpc_grants_sql")" "$before_grants" 'first migration changed operational RPC grants'
assert_eq "$(scalar "select coalesce(to_regprocedure('knowledge.assert_clinical_full_text(uuid,uuid)')::text, '')")" '' 'first migration installed a gate outside the reset transaction'

psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
insert into provenance.agent_runs (
  agent_identity_id, actor_id, agent_role,
  provider, model, model_version, prompt_template_version, pipeline_version,
  status, input_manifest
)
select ai.id, ai.actor_id, ai.agent_role,
       'antidep-test', 'inter-migration-blocker', '1', 'test', 'test',
       'running', '{"evidence_item_ids":["inter-migration-blocker"]}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';
SQL
assert_gt_zero "$(scalar "select count(*) from provenance.agent_runs where status = 'running'")" 'inter-migration fixture did not create a running agent'
if psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose \
  -f supabase/migrations/20260925091000_reset_active_prototype_content.sql \
  >"$TMP_DIR/inter-migration.log" 2>&1; then
  fail 'reset ignored an agent run committed between migrations'
fi
grep -q '23001' "$TMP_DIR/inter-migration.log" || {
  cat "$TMP_DIR/inter-migration.log" >&2
  fail 'inter-migration test failed for a reason other than the scope guard'
}
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" "$before_evidence" 'inter-migration stop removed evidence'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" "$before_claims" 'inter-migration stop removed claims'
assert_eq "$(scalar "$rpc_grants_sql")" "$before_grants" 'inter-migration stop stranded retired RPC grants'
assert_eq "$(scalar "select coalesce(to_regprocedure('knowledge.assert_clinical_full_text(uuid,uuid)')::text, '')")" '' 'inter-migration stop stranded the full-text gate'
assert_eq "$(scalar "select coalesce(to_regclass('audit.prototype_resets')::text, '')")" '' 'inter-migration stop left a reset snapshot'

printf 'Antidep 2-oppgraderingsprøven gikk gjennom.\n'
