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

# Probe 4 in the durable legacy race script creates its own source version with
# a now-retired reading-order recipe. Antidep 2 correctly refuses to create new
# clinical evidence from that recipe. Pre-create the same fixed test identity
# with the current safe recipe; the legacy script uses ON CONFLICT DO NOTHING
# for these rows and therefore exercises the same race without weakening the
# production full-text gate.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
select '7a000000-0000-4000-8000-000000000001', 'journal_article',
       'Samtidighetsprøve for registreringsrekkefølgen',
       'scripts/db-lock-test.sh', a.id
from provenance.actors a where a.actor_key = 'human:peder-holman'
on conflict (id) do nothing;

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference, representation,
   retrieved_by_actor_id, document_sha256, document_byte_size, document_media_type,
   text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
   text_extraction_transform)
select '7a000000-0000-4000-8000-000000000002',
       '7a000000-0000-4000-8000-000000000001', now(),
       'file:///syntetisk-samtidighetsprove.pdf', 'sha256:' || repeat('7', 64),
       'private://syntetisk-samtidighetsprove.pdf', 'full_text', a.id,
       'sha256:' || repeat('8', 64), 1024, 'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from provenance.actors a where a.actor_key = 'human:peder-holman'
on conflict (id) do nothing;
SQL

if [ "$(psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c \
  "select text_extraction_transform from knowledge.source_versions where id = '7a000000-0000-4000-8000-000000000002'")" != "antidep-reading-order@2" ]; then
  printf 'Samtidighetsfiksturen har ikke gjeldende sikker PDF-oppskrift.\n' >&2
  exit 1
fi

psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -c \
  "grant execute on function api.register_publication_approval(uuid,text,text,text) to authenticated"

"$(dirname "$0")/db-lock-test.sh" "$@"
