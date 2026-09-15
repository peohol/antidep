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

if grep -R -n -E \
  --include='*.ts' --include='*.tsx' --exclude='*.test.ts' --exclude='*.test.tsx' \
  '(/review|/extraction-review|Fava|Versiani)' src/app; then
  echo 'Gammel produktflate eller klinisk eksempeltekst finnes i appen.' >&2
  exit 1
fi

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
if grep -n -E \
  'MVP_IMPLEMENTATION_PLAN|ROUTINE_EXTRACTION|/extraction-review|/review' \
  "${operational_docs[@]}"; then
  echo 'Foreldet mikroreview- eller ekstraksjonsflyt finnes fortsatt i operative instrukser.' >&2
  exit 1
fi

node scripts/verify-doc-links.mjs
