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

if [ -z "$DB_URL" ]; then
  printf 'Fant ingen lokal databaseadresse for Antidep 2-oppgraderingsprøven.\n' >&2
  exit 1
fi
case "$DB_URL" in
  postgresql://postgres:postgres@127.0.0.1:*/*|postgresql://postgres:postgres@localhost:*/*) ;;
  *)
    printf 'Oppgraderingsprøven nekter å kjøre mot annet enn lokal Supabase: %s\n' "$DB_URL" >&2
    exit 1
    ;;
esac

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

seed_active_prototype() {
  {
    printf 'begin;\n'
    cat supabase/tests/fixtures/active_clinical_fixture.inc
    printf '\ncommit;\n'
  } | psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 >/dev/null
}

expect_upgrade_failure() {
  local label=$1
  if npx --no-install supabase migration up --local >"$TMP_DIR/$label.log" 2>&1; then
    cat "$TMP_DIR/$label.log" >&2
    fail "oppgraderingen skulle ha stoppet i scenarioet $label"
  fi
}

printf 'Antidep 2: oppgraderingsprøve fra legacy-baseline.\n'

# 1. A real pre-reset database with active derived content is snapshotted and emptied.
reset_legacy
seed_active_prototype
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

# A second migration-up is a no-op and must not delete new Antidep 2 content.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
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
where sv.representation = 'full_text'
  and sv.document_sha256 ~ '^sha256:[0-9a-f]{64}$'
order by sv.created_at, sv.id
limit 1;
SQL
assert_eq "$(scalar "select count(*) from knowledge.evidence_items where id = 'fa200000-0000-4000-8000-000000000001'")" '1' 'klarte ikke å opprette nytt Antidep 2-funn etter reset'
npx --no-install supabase migration up --local >"$TMP_DIR/rerun.log" 2>&1
assert_eq "$(scalar "select count(*) from knowledge.evidence_items where id = 'fa200000-0000-4000-8000-000000000001'")" '1' 'en omkjøring slettet nytt Antidep 2-innhold'

# 2. Any publication history aborts the reset transaction without partial deletion.
reset_legacy
seed_active_prototype
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

# 3. An open agent run likewise aborts without partial deletion.
reset_legacy
seed_active_prototype
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
       'running', '{}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';
SQL
assert_gt_zero "$(scalar "select count(*) from provenance.agent_runs where status = 'running'")" 'klarte ikke å etablere åpen agentkjøring for stopptesten'
expect_upgrade_failure open-agent-run
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" "$before_evidence" 'agentstopp etterlot delvis slettet evidens'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" "$before_claims" 'agentstopp etterlot delvis slettede påstander'
assert_eq "$(scalar "select coalesce(to_regclass('audit.prototype_resets')::text, '')")" '' 'agentstopp etterlot et snapshot fra en rullet tilbake reset'

printf 'Antidep 2-oppgraderingsprøven gikk gjennom.\n'
