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

# Separasjonen skal ikke hevdes sterkere enn den er (migrasjon 013t).
#
# Regel 3 er håndhevet på rolle og kjøring: et svar kan ikke attestere sitt eget
# resultat, og det samme registreringsleddet kan ikke både skrive innholdet og
# kontrollere det. Den samme modellen *kan* utføre alle leddene, og den samme
# Workspace Agent-en kan kjøre flere av dem.
#
# Formuleringene under er de påstandene systemet ikke lenger gjør, og de har
# drevet tilbake i dokumentene én gang allerede. Søket går på dem ordrett.
# Grunnen til at det er et repo-søk og ikke en prøve, er at det er tekst og ikke
# oppførsel: ingen database kan si fra om at et dokument lover for mye.
#
# Bare `docs/` og `README.md` søkes. En migrasjon forteller sin egen historie og
# siterer med vilje regelen den fjerner; et søk som traff den, ville tvunget fram
# en migrasjon som ikke kunne forklare seg.
reject_grep_matches \
  'Et dokument hevder en separasjon systemet ikke har (migrasjon 013t).' \
  -R -n -E --include='*.md' \
  '(modellruntime|ikke dele modell|kan ikke kjøre to|hå(ndhevet|ndheves) på (modellidentitet|agentidentitet)|to (roller|ledd|agentledd) kan ikke dele|ingen andre ledd kan bruke den samme|kan ikke være den samme modellen)' \
  docs README.md

# Modellnavnet skal ikke beskrives som en adgangskontroll (migrasjon 013u).
#
# Den kontrollen fantes, og den ble prøvd i drift: importen krevde at svarets
# `identity` var nøyaktig den modellen leddet var tildelt. En Workspace Agent får
# ikke vite hvilken modellvekt den kjører på, så den avviste nøyaktig det ærlige
# svaret — og den kunne uansett ikke bære noe, siden den ene siden av
# sammenligningen er noe modellen skriver selv.
#
# Setningene under er måtene den regelen ble beskrevet på. De er her fordi en
# tekst som lover kontrollen tilbake, er det som får noen til å bygge den igjen —
# eller, verre, til å hardkode et modellnavn i en agentinstruks for å få den til
# å passere. Samme søkeflate som over, og av samme grunn.
reject_grep_matches \
  'Et dokument beskriver modellnavnet som en adgangskontroll (migrasjon 013u).' \
  -R -n -E --include='*.md' \
  '(bekrefter? identiteten sin|komme fra den tildelte modellen|kontrollert mot svaret|må bevise hvilken modell)' \
  docs README.md

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

# En arbeidsflyt med hemmeligheter skal ikke kunne startes mot en valgt branch.
#
# `VERCEL_TOKEN` og redaktørens innlogging ligger i jobbens miljø, og jobben
# kjører kode fra den branchen kjøringen gjelder. Kode på en branch som ikke er
# reviewet, skal derfor ikke kunne starte den: den ene kan deploye til
# produksjon, den andre kan lese originaldokumenter ut av databasen.
#
# `pull_request` er den åpenbare — en pull request fra en branch i samme repo
# kan få repository-secrets. De tre andre er mindre åpenbare og like ille:
# `workflow_dispatch` har en branch-meny i GitHubs «Run workflow», og en
# manuell kjøring mot en valgt branch setter `GITHUB_REF`/`GITHUB_SHA` til
# nettopp den, slik at `actions/checkout` henter den branchens kode.
# `workflow_call` lar kalleren bestemme det samme. `schedule` og `push` mot en
# navngitt branch gjør det ikke, og er derfor det som er igjen.
#
# Grensen sto til nå bare som en kommentar i `vercel.yml`. Her er den en
# kontroll, slik at den neste arbeidsflyten med en hemmelighet ikke kan glemme
# den (AGENTS.md, ANTIDEP_CONSTITUTION.md regel 7).
while IFS= read -r workflow; do
  grep -q 'secrets\.' "$workflow" || continue
  if trigger=$(grep -oE '^[[:space:]]{2}(pull_request_target|pull_request|workflow_dispatch|workflow_call):' \
                 "$workflow" | head -1); then
    echo "Arbeidsflyt med hemmeligheter kan startes mot en valgt branch ($trigger): $workflow" >&2
    exit 1
  fi
done < <(find .github/workflows -type f -name '*.yml' | sort)

# Den planlagte kjøringen skal ikke be om den rå årsaken.
#
# `--diagnostics` tar med feilteksten fra verktøyet og fra databasen. Den er
# nyttig for den som feilsøker lokalt, og feil i en GitHub Actions-logg i et
# offentlig repo: en videreformidlet feiltekst kan bære et beskrankningsnavn,
# en adresse eller en del av dokumentet (AGENTS.md).
reject_grep_matches \
  'Den planlagte kjøringen ber om den rå årsaken, og loggen er offentlig.' \
  -n -E -- '--diagnostics' .github/workflows/full-text-extraction.yml

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

# Reserveveiens legitimasjon skal aldri nå en nettleser.
#
# `ANTIDEP_DIAGNOSTICS_DATABASE_URL` er den ene hemmeligheten i Antidep som gir
# en forbindelse rett til databasen. Den er smal — rollen kan bare legge til
# rader gjennom to funksjoner og kan ikke lese én tilbake — men den hører
# utelukkende hjemme på serversiden.
#
# Et `VITE_`-prefiks ville lagt den i klartekst i nettleserbygget. Kontrollen
# står her slik at den ikke kan glemmes ved neste variabel.
reject_grep_matches \
  'Reserveveiens databaseadresse er gitt et VITE_-prefiks og ville havnet i nettleserbygget.' \
  -R -n -E \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist \
  'VITE_[A-Z_]*DIAGNOSTICS_DATABASE' \
  .

# Og modulen som holder forbindelsen, skal ikke kunne importeres av en flate.
#
# `src/diagnostics/store.ts` åpner en Postgres-forbindelse. Havnet den i
# nettleserbygget — gjennom en import fra `src/app/` eller `src/lib/` — ville
# bunteren tatt med den, og adressen måtte vært en `VITE_`-verdi for at den
# skulle virke. Kontrollen fanger importen framfor å vente på variabelen.
reject_grep_matches \
  'En nettleserflate importerer den server-side databaseforbindelsen.' \
  -R -n -E \
  --include='*.ts' --include='*.tsx' \
  "from '.*diagnostics/store'" \
  src/app src/lib src/components

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

# Ingen Node-side modul importerer flatens Supabase-modul.
#
# `src/lib/supabase.ts` er flatens: den leser `import.meta.env`, og den
# importerer uten filending slik Vite gjør. Node kan ikke løse en slik import,
# så en kjører som gikk den veien, døde med ERR_MODULE_NOT_FOUND før den hadde
# lest en enkelt miljøvariabel — og det er nøyaktig det som hadde skjedd med
# hver eneste `npm run agent:*` og `npm run ops:*`. Regelen om publishable key
# ligger i `src/lib/publishable-key.ts` for å kunne leses fra begge sider.
reject_grep_matches \
  'En Node-side modul importerer flatens Supabase-modul. Bruk lib/publishable-key.ts.' \
  -R -n -E \
  --include='*.ts' \
  "from '\.\./lib/supabase" \
  src/agents src/ops src/mcp src/diagnostics

# Og hver kommando kan faktisk lastes.
#
# Kontrollen over fanger den ene formen feilen hadde. Denne fanger alle andre:
# hver kommando kjøres med `--help`, som verken rører databasen eller nettet,
# men som krever at hele importtreet lastes. En kommando som ikke kan startes,
# er ikke levert.
#
# Utfallskoden brukes ikke: flere kommandoer skriver bruksteksten ved å kaste,
# og det er en gyldig `--help`. Det som aldri er gyldig, er at Node ikke finner
# en modul — da er det importtreet som er galt, og ingen miljøvariabel eller
# argumentliste kan rette det.
while IFS= read -r cli; do
  output=$(node "$cli" --help 2>&1 || true)
  if grep -qE 'ERR_MODULE_NOT_FOUND|ERR_UNSUPPORTED_DIR_IMPORT|Cannot find (module|package)' \
      <<<"$output"; then
    printf 'Kommandoen kan ikke lastes: %s\n%s\n' "$cli" "$output" >&2
    exit 1
  fi
done < <(find src/agents src/ops -type f -name '*-cli.ts' | sort)

node --test scripts/local-test-db.node-test.mjs
node scripts/verify-doc-links.mjs
