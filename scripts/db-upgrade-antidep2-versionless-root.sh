#!/usr/bin/env bash
# Fail-closed regression: a legacy-looking evidence root without a source
# version is not proven to be one of the two authorized abstract snapshots.
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

printf 'Antidep 2: stopptest for legacy-rot uten kildeversjon.\n'
npx --no-install supabase db reset --version "$LAST_LEGACY" --no-seed >/dev/null

assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'legacy-fiksturen skal starte med to evidensrøtter'

# source_version_id is historically nullable. Simulate a legacy-looking root
# whose provenance is no longer sufficient to prove that it is one of the two
# authorized abstract snapshots. This is maintenance-only test setup; no
# production write path may mutate an evidence item this way.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
begin;
alter table knowledge.evidence_items disable trigger evidence_items_reject_mutation;
update knowledge.evidence_items e
set source_version_id = null
from catalog.drugs d
where d.id = e.intervention_drug_id
  and d.canonical_name = 'sertralin';
alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;
commit;
SQL

assert_eq "$(scalar 'select count(*) from knowledge.evidence_items where source_version_id is null')" '1' \
  'klarte ikke å etablere versjonsløs legacy-rot for stopptesten'

if npx --no-install supabase migration up --local >"$TMP_DIR/versionless-root.log" 2>&1; then
  cat "$TMP_DIR/versionless-root.log" >&2
  fail 'resetten godtok en evidensrot uten dokumentert kildeversjon'
fi

assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'stopptesten etterlot delvis slettet evidens'
assert_eq "$(scalar "select coalesce(to_regprocedure('knowledge.assert_antidep2_reset_preconditions()')::text, '')")" '' \
  'stopptesten etterlot vedlikeholdsfunksjonen fra en rullet tilbake preflight'
assert_eq "$(scalar "select coalesce(to_regclass('audit.prototype_resets')::text, '')")" '' \
  'stopptesten etterlot et snapshot fra en rullet tilbake reset'

printf 'OK: evidensrot uten kildeversjon stopper resetten før endringer.\n'
