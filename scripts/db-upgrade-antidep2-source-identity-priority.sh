#!/usr/bin/env bash
# Fail-closed regression: immutable source-snapshot identity is evaluated before
# the later representation label. A misleading representation must never hide
# that a root points at an unauthorized snapshot.
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

printf 'Antidep 2: kildeidentitet skal avgjøres før representasjonsmetadata.\n'
npx --no-install supabase db reset --version "$LAST_LEGACY" --no-seed >/dev/null

assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'legacy-fiksturen skal starte med to evidensrøtter'

# Maintenance-only corruption for the negative test. Make one historical root
# simultaneously look like full text and point at a different immutable content
# hash. Production write paths cannot mutate either field after registration.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
begin;
alter table knowledge.source_versions disable trigger source_versions_freeze_snapshot;
update knowledge.source_versions sv
set representation = 'full_text',
    content_hash = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
from knowledge.evidence_items e
join catalog.drugs d on d.id = e.intervention_drug_id
where e.source_version_id = sv.id
  and d.canonical_name = 'sertralin';
alter table knowledge.source_versions enable trigger source_versions_freeze_snapshot;
commit;
SQL

if npx --no-install supabase migration up --local >"$TMP_DIR/source-identity-priority.log" 2>&1; then
  cat "$TMP_DIR/source-identity-priority.log" >&2
  fail 'resetten godtok en evidensrot med feil uforanderlig kilde-snapshot'
fi

if ! grep -Fq 'kildeversjonen er ikke ett av de to autoriserte, uforanderlige legacy-snapshotene' \
  "$TMP_DIR/source-identity-priority.log"; then
  cat "$TMP_DIR/source-identity-priority.log" >&2
  fail 'preflighten diagnostiserte representasjon før den avviste feil kildeidentitet'
fi

assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'stopptesten etterlot delvis slettet evidens'
assert_eq "$(scalar "select coalesce(to_regprocedure('knowledge.assert_antidep2_reset_preconditions()')::text, '')")" '' \
  'stopptesten etterlot vedlikeholdsfunksjonen fra en rullet tilbake preflight'
assert_eq "$(scalar "select coalesce(to_regclass('audit.prototype_resets')::text, '')")" '' \
  'stopptesten etterlot et snapshot fra en rullet tilbake reset'

printf 'OK: uforanderlig kildeidentitet avvises før representasjonsmetadata vurderes.\n'
