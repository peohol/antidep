#!/usr/bin/env bash
# Test-only compatibility wrapper for the durable review-decision race probe.
# Production keeps api.register_publication_approval revoked from authenticated;
# the old helper is opened only while the race suite runs and is always revoked
# again on exit. The race itself still exercises the database ordering/gating
# rule, not the retired UI.
set -euo pipefail

DB_URL=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--db-url" ] && [ $((i + 1)) -lt ${#args[@]} ]; then
    DB_URL="${args[$((i + 1))]}"
    break
  fi
done

if [ -z "$DB_URL" ]; then
  DB_URL=$(npx --no-install supabase status -o json 2>/dev/null | node -e '
    let d = ""
    process.stdin.on("data", (c) => (d += c)).on("end", () => {
      try { process.stdout.write(JSON.parse(d).DB_URL ?? "") } catch { process.stdout.write("") }
    })
  ')
fi

if [ -z "$DB_URL" ]; then
  printf 'Fant ingen databaseadresse for samtidighetsprøven.\n' >&2
  exit 1
fi

cleanup() {
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -c \
    "revoke execute on function api.register_publication_approval(uuid,text,text,text) from authenticated" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -c \
  "grant execute on function api.register_publication_approval(uuid,text,text,text) to authenticated"

"$(dirname "$0")/db-lock-test.sh" "$@"
