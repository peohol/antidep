#!/usr/bin/env bash
#
# Utsteder legitimasjon til en agentidentitet, og skriver den ut én gang.
#
#   ./scripts/issue-agent-credential.sh                      # lokal stack
#   ./scripts/issue-agent-credential.sh --db-url "postgresql://..."
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

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY='agent-identity:extraction-verification-01'
ISSUER='human:peder-holman'
DB_URL="${ANTIDEP_DB_URL:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="${2:?--identity krever en identitetsnøkkel}"; shift 2 ;;
    --issuer)   ISSUER="${2:?--issuer krever en aktørnøkkel}"; shift 2 ;;
    --db-url)   DB_URL="${2:?--db-url krever en tilkoblingsstreng}"; shift 2 ;;
    -h|--help)
      sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Ukjent valg: $1" >&2
      exit 2 ;;
  esac
done

if [ -n "${CI:-}" ]; then
  cat >&2 <<'STOPP'
Dette skriptet skriver hemmeligheten til stdout og skal ikke kjøres i CI.

Kjør det lokalt eller på maskinen som forvalter miljøet, og legg verdien inn som
en kryptert secret der kjøreren leser den (GitHub Actions: Settings → Secrets and
variables → Actions).
STOPP
  exit 1
fi

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
STOPP
  exit 1
fi

SECRET=$(psql "$DB_URL" --no-psqlrc --quiet --tuples-only --no-align \
  --set ON_ERROR_STOP=1 \
  --command "select provenance.issue_agent_identity_credential('$IDENTITY', '$ISSUER');")

if [ -z "$SECRET" ]; then
  echo "Utstedelsen ga ingen verdi. Ingenting er endret." >&2
  exit 1
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
