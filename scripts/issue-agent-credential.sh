#!/usr/bin/env bash
#
# Utsteder legitimasjon til en agentidentitet, og skriver den ut én gang.
#
#   ./scripts/issue-agent-credential.sh                      # lokal stack
#   ./scripts/issue-agent-credential.sh --db-url "postgresql://..."
#   ./scripts/issue-agent-credential.sh --management-api     # hostet, uten db-passord
#   ./scripts/issue-agent-credential.sh --write-env          # til .env.agent.local
#   ./scripts/issue-agent-credential.sh --identity agent-identity:… --issuer human:…
#
# Hemmeligheten genereres av databasen (provenance.issue_agent_identity_credential),
# lagres aldri i klartekst, og kan ikke leses ut igjen. Mister du den, utsteder du
# en ny — som samtidig ugyldiggjør den gamle.
#
# ----------------------------------------------------------------------------
# Hvorfor dette er et skript og ikke en migrasjon
#
# En hemmelighet generert av en migrasjon måtte enten ligget i repoet eller blitt
# returnert til den som kjørte migrasjonen, altså gjennom en agentsesjons logg og
# videre inn i en transkripsjon (MVP_IMPLEMENTATION_PLAN.md §74.31). Utstedelsen
# hører derfor til en bevisst, manuell handling i det miljøet kjøreren skal lese
# hemmeligheten fra.
#
# Funksjonen har ingen EXECUTE til noen klientrolle: den er en
# forvaltningsoperasjon og krever en privilegert databaseforbindelse. Det er med
# hensikt — en flate som kunne utstedt legitimasjon over Data API-et, ville vært
# en rettighetseskalering med ett ledd (CONTENT_GOVERNANCE.md §14).
#
# ----------------------------------------------------------------------------
# Hvorfor skriptet nekter å kjøre i CI
#
# Verdien skrives til stdout. I en CI-jobb er stdout en logg som lagres, deles og
# ofte er offentlig. Hemmeligheten skal settes som en kryptert secret i det
# miljøet som trenger den, ikke produseres av en jobb som logger den.
#
# ----------------------------------------------------------------------------
# --write-env: samme grunn, for et miljø der stdout også blir en logg
#
# En agentsesjon skriver stdout til en transkripsjon som lagres. Der er
# utskriften like uegnet som i CI, men behovet for å utstede legitimasjon er
# reelt: kjøreren skal prøves mot det hostede prosjektet. `--write-env` skriver
# derfor de to variablene rett inn i en gitignorert miljøfil, uten å vise
# verdien noe sted. Filen er den samme `npm run agent:verify-extraction` leser.
#
# ----------------------------------------------------------------------------
# --management-api: en privilegert forbindelse uten databasepassord
#
# `provenance.issue_agent_identity_credential(...)` har ingen EXECUTE til noen
# klientrolle og krever en privilegert forbindelse. Supabases Management-API
# kjører SQL som `postgres`, og gir dermed den forbindelsen til den som allerede
# har et access token — uten at databasepassordet må hentes ut eller settes på
# nytt. Merk avveiningen: forespørselen går over HTTPS til api.supabase.com, mens
# `--db-url` gir en direkte TLS-forbindelse til databasen. Foretrekk `--db-url`
# når passordet er for hånden.

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY='agent-identity:extraction-verification-01'
ISSUER='human:peder-holman'
DB_URL="${ANTIDEP_DB_URL:-}"
MANAGEMENT_API=0
ENV_FIL=''

while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="${2:?--identity krever en identitetsnøkkel}"; shift 2 ;;
    --issuer)   ISSUER="${2:?--issuer krever en aktørnøkkel}"; shift 2 ;;
    --db-url)   DB_URL="${2:?--db-url krever en tilkoblingsstreng}"; shift 2 ;;
    --management-api) MANAGEMENT_API=1; shift ;;
    --write-env)
      # Valgfri filbane. Neste argument hører til flagget bare når det ikke
      # selv er et flagg.
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then ENV_FIL="$2"; shift 2
      else ENV_FIL='.env.agent.local'; shift; fi ;;
    -h|--help)
      sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Ukjent valg: $1" >&2
      exit 2 ;;
  esac
done

# Begge verdiene interpoleres inn i en SQL-setning som kjøres på en privilegert
# forbindelse. Nøkkelformatet er det samme som
# `agent_identities_identity_key_format_check` håndhever i basen, så kravet her
# avviser ingenting som ellers ville virket — det stenger bare muligheten for at
# et argument bærer med seg SQL.
for par in "identitetsnøkkel:$IDENTITY" "aktørnøkkel:$ISSUER"; do
  if ! printf '%s' "${par#*:}" | grep -qE '^[a-z0-9]+([-.][a-z0-9]+)*:[a-z0-9]+([-.][a-z0-9]+)*$'; then
    echo "Ugyldig ${par%%:*}: ${par#*:}" >&2
    echo "Forventet formen «type:navn», med små bokstaver, tall, bindestrek og punktum." >&2
    exit 2
  fi
done

# CI-nektelsen gjelder utskriften, ikke utstedelsen. Med --write-env vises
# verdien ingen steder, men en CI-jobb er likevel feil sted å utstede fra: filen
# forsvinner med jobben, og den gamle legitimasjonen ville vært ugyldiggjort.
if [ -n "${CI:-}" ]; then
  cat >&2 <<'STOPP'
Dette skriptet skriver hemmeligheten til stdout og skal ikke kjøres i CI.

Kjør det lokalt eller på maskinen som forvalter miljøet, og legg verdien inn som
en kryptert secret der kjøreren leser den (GitHub Actions: Settings → Secrets and
variables → Actions).
STOPP
  exit 1
fi

if [ "$MANAGEMENT_API" = "1" ]; then
  : "${SUPABASE_PROJECT_REF:?--management-api krever SUPABASE_PROJECT_REF}"
  : "${SUPABASE_ACCESS_TOKEN:?--management-api krever SUPABASE_ACCESS_TOKEN}"

  # Kroppen bygges av `node` slik at identiteten og aktørnøkkelen blir riktig
  # JSON-escapet, og svaret plukkes fra samme sted. Verdien går rett i en
  # variabel; den skrives ikke ut underveis.
  SECRET=$(node -e '
    const [identity, issuer] = process.argv.slice(1);
    process.stdout.write(JSON.stringify({
      query: "select provenance.issue_agent_identity_credential($i$" + identity +
             "$i$, $u$" + issuer + "$u$) as secret",
    }));
  ' "$IDENTITY" "$ISSUER" | curl -sS -X POST \
      "https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF}/database/query" \
      -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
      -H "Content-Type: application/json" -d @- | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let svar;
      try { svar = JSON.parse(s); } catch { process.exit(1); }
      // Feilsvar er et objekt med `message`, ikke en rad-liste. Meldingen kan
      // gjengis: den inneholder ikke hemmeligheten.
      if (!Array.isArray(svar)) {
        console.error(svar.message || s);
        process.exit(1);
      }
      if (!svar[0] || !svar[0].secret) process.exit(1);
      process.stdout.write(svar[0].secret);
    });
  ')
else
  if ! command -v psql >/dev/null 2>&1; then
    echo "psql finnes ikke i PATH. Installer PostgreSQL-klienten, eller kjør SQL-setningen under manuelt." >&2
    echo "  select provenance.issue_agent_identity_credential('$IDENTITY', '$ISSUER');" >&2
    exit 1
  fi

  if [ -z "$DB_URL" ]; then
    echo "Ingen --db-url oppgitt; leser tilkoblingsstrengen til den lokale stacken."
    DB_URL=$(npx --yes supabase status -o env 2>/dev/null | sed -n 's/^DB_URL="\(.*\)"$/\1/p')
  fi

  if [ -z "$DB_URL" ]; then
    cat >&2 <<'STOPP'
Fant ingen databasetilkobling.

Lokalt: start stacken med `npm run db:start` og kjør skriptet på nytt.
Hosted: hent tilkoblingsstrengen i Supabase (Project Settings → Database →
Connection string) og oppgi den med --db-url. Bruk en direkte forbindelse, ikke
Data API-et: funksjonen er en forvaltningsoperasjon uten grants til klientroller.
Har du ikke passordet for hånden, bruk --management-api.
STOPP
    exit 1
  fi

  SECRET=$(psql "$DB_URL" --no-psqlrc --quiet --tuples-only --no-align \
    --set ON_ERROR_STOP=1 \
    --command "select provenance.issue_agent_identity_credential('$IDENTITY', '$ISSUER');")
fi

if [ -z "$SECRET" ]; then
  echo "Utstedelsen ga ingen verdi. Ingenting er endret." >&2
  exit 1
fi

if [ -n "$ENV_FIL" ]; then
  # Selve skrivingen ligger i `src/agents/agent-env-file.ts`, som har tester:
  # den nekter å skrive til en fil git ikke ignorerer, og gir filen `0600` også
  # når den fantes fra før. Begge deler var funn i teknisk review — se
  # hodekommentaren der.
  #
  # Verdien går gjennom miljøet og ikke gjennom argumentlisten, som er lesbar
  # for alle på maskinen gjennom `ps`.
  if ! ANTIDEP_AGENT_IDENTITY_KEY="$IDENTITY" ANTIDEP_AGENT_SECRET="$SECRET" \
       node src/agents/write-agent-env-cli.ts "$ENV_FIL"; then
    cat >&2 <<'STOPP'

Legitimasjonen ble utstedt, men kunne ikke skrives til miljøfilen.

Den forrige legitimasjonen er dermed ugyldig, og denne er ingen steder. Rett
det som står over, og kjør skriptet på nytt for å utstede en ny.
STOPP
    exit 1
  fi

  cat <<SLUTT

Legitimasjon utstedt til $IDENTITY.

  ANTIDEP_AGENT_IDENTITY_KEY og ANTIDEP_AGENT_SECRET er skrevet til $ENV_FIL.

Verdien er ikke vist noe sted, og kan ikke leses ut av databasen igjen. Filen er
gitignorert. Trenger et annet miljø den samme kjøreren, utsteder du en ny
legitimasjon der — den gamle blir da ugyldig.

SLUTT
  exit 0
fi

cat <<SLUTT

Legitimasjon utstedt til $IDENTITY.

  ANTIDEP_AGENT_IDENTITY_KEY=$IDENTITY
  ANTIDEP_AGENT_SECRET=$SECRET

Verdien vises bare denne ene gangen — databasen lagrer bare hashen, og det finnes
ingen vei til å lese den ut igjen.

Slik gjør du den tilgjengelig for kjøreren:

  Lokalt   Legg de to linjene over i .env.agent.local sammen med
           ANTIDEP_SUPABASE_URL og ANTIDEP_SUPABASE_PUBLISHABLE_KEY. Filen er
           gitignorert, og npm run agent:verify-extraction leser den.

  CI       Legg dem inn som krypterte secrets i GitHub (Settings → Secrets and
           variables → Actions). Arbeidsflyten
           .github/workflows/extraction-verification.yml leser dem derfra.

Legg dem aldri i repoet, i en commit-melding eller i en logg.

SLUTT
