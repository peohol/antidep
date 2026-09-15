#!/usr/bin/env bash
# Test-only compatibility wrapper for the durable review-decision race probe.
# The retired publication RPC is opened only on an explicitly validated local
# database, and a failed restoration must fail the test rather than be hidden.
set -euo pipefail
cd "$(dirname "$0")/.."

DB_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --db-url)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ -n "$DB_URL" ]; then
        printf 'Expected exactly one nonempty --db-url value.\n' >&2
        exit 2
      fi
      DB_URL=$2
      shift 2
      ;;
    *) printf 'Unknown argument.\n' >&2; exit 2 ;;
  esac
done

if [ -z "$DB_URL" ]; then
  DB_URL=$(npx --no-install supabase status -o json 2>/dev/null | node -e '
    let d = ""
    process.stdin.on("data", (c) => (d += c)).on("end", () => {
      try { process.stdout.write(JSON.parse(d).DB_URL ?? "") } catch { process.stdout.write("") }
    })
  ')
fi

# Validate before installing cleanup or issuing any SQL, including REVOKE.
node scripts/local-test-db.mjs "$DB_URL"

restore_grant=false
cleanup() {
  local status=$?
  trap - EXIT
  if [ "$restore_grant" = true ]; then
    if ! psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -c \
      "revoke execute on function api.register_publication_approval(uuid,text,text,text) from authenticated"; then
      printf 'Failed to close the temporary publication RPC grant.\n' >&2
      [ "$status" -ne 0 ] || status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Probe 4 uses a fixed synthetic identity. Keep its current safe PDF recipe;
# never weaken the production full-text gate to make a legacy test pass.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
select '7a000000-0000-4000-8000-000000000001', 'journal_article',
       'Samtidighetsprøve for registreringsrekkefølgen',
       'scripts/db-lock-test.sh', a.id
from provenance.actors a where a.actor_key = 'human:peder-holman'
on conflict (id) do nothing;

-- From migration 009a the document digest IS the bytes, and the file must be in
-- the private library, bound to the publication and readability-checked. Never
-- weaken the production gate to make a fixture pass; give the fixture real
-- bytes instead.
create temporary table lock_probe_pdf as
select convert_to('%PDF-1.7' || E'\nsamtidighetsprove\n%%EOF\n', 'UTF8') as bytes;

insert into knowledge.source_documents
  (sha256, byte_size, media_type, content, stored_by_actor_id)
select knowledge.source_document_fingerprint(g.bytes), octet_length(g.bytes),
       'application/pdf', g.bytes, a.id
from lock_probe_pdf g
join provenance.actors a on a.actor_key = 'human:peder-holman'
on conflict (sha256) do nothing;

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference, representation,
   retrieved_by_actor_id, document_sha256, document_byte_size, document_media_type,
   text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
   text_extraction_transform)
select '7a000000-0000-4000-8000-000000000002',
       '7a000000-0000-4000-8000-000000000001', now(),
       'file:///syntetisk-samtidighetsprove.pdf', 'sha256:' || repeat('7', 64),
       'private://syntetisk-samtidighetsprove.pdf', 'full_text', a.id,
       knowledge.source_document_fingerprint(g.bytes), octet_length(g.bytes),
       'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from provenance.actors a
cross join lock_probe_pdf g
where a.actor_key = 'human:peder-holman'
on conflict (id) do nothing;

insert into knowledge.source_document_publications
  (source_document_id, source_id, binding_basis, binding_evidence, bound_by_actor_id)
select d.id, sv.source_id, 'title', 'syntetisk binding for samtidighetsprøven',
       sv.retrieved_by_actor_id
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = '7a000000-0000-4000-8000-000000000002'
on conflict on constraint source_document_publications_pairing_key do nothing;

insert into knowledge.full_text_readability_checks
  (source_version_id, source_document_id, character_count, letter_count,
   line_count, table_row_count, table_declaration_count)
select sv.id, d.id, 20000, 15000, 400, 12, 3
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = '7a000000-0000-4000-8000-000000000002'
on conflict on constraint full_text_readability_checks_source_version_key do nothing;
SQL

if [ "$(psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c \
  "select text_extraction_transform from knowledge.source_versions where id = '7a000000-0000-4000-8000-000000000002'")" != "antidep-reading-order@2" ]; then
  printf 'The concurrency fixture does not use the current safe PDF recipe.\n' >&2
  exit 1
fi

# Set this before GRANT so an interrupted/ambiguous grant is also cleaned up.
restore_grant=true
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -c \
  "grant execute on function api.register_publication_approval(uuid,text,text,text) to authenticated"

# Forward the one resolved URI, never the original argument list or a second
# auto-discovery result that could target a different database.
bash scripts/db-lock-test.sh --db-url "$DB_URL"
