#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

sha256sum --check --strict scripts/legacy-migrations.sha256 >/dev/null

last_legacy=20260924095000
while IFS= read -r path; do
  id=${path##*/}
  id=${id%%_*}
  if [[ $id -le $last_legacy ]] && ! grep -Fq "  $path" scripts/legacy-migrations.sha256; then
    echo "Uregistrert migrasjon i historisk ID-område: $path" >&2
    exit 1
  fi
done < <(find supabase/migrations -type f -name '*.sql' | sort)

for obsolete in \
  docs/MVP_IMPLEMENTATION_PLAN.md \
  docs/ROUTINE_EXTRACTION.md \
  .github/workflows/claim-verification.yml \
  .github/workflows/extraction-verification.yml; do
  [[ ! -e $obsolete ]] || {
    echo "Foreldet fil finnes: $obsolete" >&2
    exit 1
  }
done

reject_grep_matches() {
  local message=$1
  shift
  if grep "$@"; then
    echo "$message" >&2
    exit 1
  else
    local status=$?
    if [[ $status -ne 1 ]]; then
      echo "Repokontrollen kunne ikke fullføre grep-søket (exit $status)." >&2
      exit "$status"
    fi
  fi
}

reject_grep_matches \
  'Gammel produktflate eller klinisk eksempeltekst finnes i appen.' \
  -R -n -E \
  --include='*.ts' --include='*.tsx' --exclude='*.test.ts' --exclude='*.test.tsx' \
  '(/review|/extraction-review|Fava|Versiani)' src/app

operational_docs=(
  .env.example
  assignments/README.md
  proposals/README.md
  assessments/README.md
  syntheses/README.md
  documents/README.md
  supabase/README.md
  supabase/seed.sql
)
for file in "${operational_docs[@]}"; do
  [[ -f $file ]] || {
    echo "Forventet operativ instruks mangler: $file" >&2
    exit 1
  }
done
reject_grep_matches \
  'Foreldet mikroreview- eller ekstraksjonsflyt finnes fortsatt i operative instrukser.' \
  -n -E \
  'MVP_IMPLEMENTATION_PLAN|ROUTINE_EXTRACTION|/extraction-review|/review' \
  "${operational_docs[@]}"

node scripts/verify-doc-links.mjs
