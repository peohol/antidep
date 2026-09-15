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

# Private fulltekster og agentsvar skal aldri bli en del av repoet.
#
# En eksportert agentoppgave bærer hele den kontrollerte kildeteksten mellom to
# markører, og en svarfil bærer et modellsvar som hører hjemme i en registrert
# rad med proveniens. Nedlastingen skjer i nettleseren og rører aldri
# arbeidstreet; dette er laget som fanger en fil noen likevel har lagt inn.
#
# Søket går på *innholdet* og ikke på filnavnet, fordi filnavnet kan være hva som
# helst — den samme grunnen til at selve handoffen ikke stoler på det.
reject_grep_matches \
  'En eksportert agentoppgave eller et agentsvar ligger i repoet.' \
  -R -l -E \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist \
  '<kildetekst nonce="[0-9a-f]{16}">|"answer_version": ?"antidep/agent-answer@' \
  .

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

node --test scripts/local-test-db.node-test.mjs
node scripts/verify-doc-links.mjs
