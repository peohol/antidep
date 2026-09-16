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

# Teknisk arbeid skal ikke komme tilbake i produkt-UI (issue #99).
#
# Å velge KI-tjeneste for et agentledd, registrere en «kjører», hente en
# tilkoblingskode, laste ned en oppgavefil og laste opp et agentsvar er teknisk
# arbeid. Det er flyttet til `src/ops/` og til kommandoene der. Søket går på de
# api-funksjonene som *er* de handlingene: en flate som kalte en av dem, ville
# hatt handlingen tilbake uansett hva knappen het. Selve adressen `/agentarbeid`
# holdes borte av `src/app/routes.test.ts`, som prøver hver rute mot den — her
# ville et søk på den også truffet forklaringene på hvorfor flaten er borte.
reject_grep_matches \
  'En runner-, modell- eller filtransportkontroll finnes i produkt-UI.' \
  -R -n -E \
  --include='*.ts' --include='*.tsx' --exclude='*.test.ts' --exclude='*.test.tsx' \
  '(register_agent_runner|issue_agent_runner_pairing_code|revoke_agent_runner|agent_runner_connections|assign_agent_role_model|agent_task_payload|import_agent_answer|agent_work_queue)' \
  src/app

# Rå feiltekst skal aldri rendres til et menneske.
#
# Gatewayene formulerer setningen selv (`src/app/gateway.ts`), og sidene leser
# den gjennom `pageMessage`. En gateway som la databasens `error.message` inn i
# en feil den kastet, ville tatt regelen ut av kraft uten at noe annet endret
# seg — og det er nettopp den formen issue #99 punkt 8 gjelder.
reject_grep_matches \
  'En gateway sender databasens egen feiltekst videre til flaten.' \
  -R -n -E \
  --include='*-gateway.ts' --exclude='*.test.ts' \
  '(error|cause)\.message' \
  src/app

reject_grep_matches \
  'En side rendrer en rå feiltekst framfor flatens egen setning.' \
  -R -n -E \
  --include='*.tsx' --exclude='*.test.tsx' \
  'instanceof Error \? [a-zA-Z]+\.message' \
  src/app

# En arbeidsflyt med hemmeligheter skal aldri kjøre på en pull request.
#
# `VERCEL_TOKEN` og redaktørens innlogging ligger i jobbens miljø, og jobben
# kjører kode fra branchen. En pull request fra en branch i samme repo kan få
# repository-secrets, og kode på en PR-branch skal derfor ikke få en
# produksjonsdeploy-token eller legitimasjon som kan lese originaldokumenter ut
# av databasen. Grensen sto til nå bare som en kommentar i `vercel.yml`; her er
# den en kontroll, slik at den neste arbeidsflyten med en hemmelighet ikke kan
# glemme den (AGENTS.md, ANTIDEP_CONSTITUTION.md regel 7).
while IFS= read -r workflow; do
  grep -q 'secrets\.' "$workflow" || continue
  if grep -qE '^[[:space:]]*pull_request(_target)?:' "$workflow"; then
    echo "Arbeidsflyt med hemmeligheter kjører på pull request: $workflow" >&2
    exit 1
  fi
done < <(find .github/workflows -type f -name '*.yml' | sort)

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
