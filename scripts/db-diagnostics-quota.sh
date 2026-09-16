#!/usr/bin/env bash
# ============================================================================
# Samtidighetsprøve for kvoten på rå diagnostikk
#
# `api.record_client_diagnostic(...)` teller hvor mange rader en bruker har
# skrevet den siste timen, og setter inn hvis tallet er lavt nok. «Tell, og sett
# inn hvis» er et kappløp: to samtidige kall ser den samme tellingen og setter
# inn begge. Med forskjellige signaturer låser de heller ikke den samme raden
# noe annet sted, så ingenting stopper dem.
#
# pgTAP kjører i én transaksjon som rulles tilbake, og kan derfor ikke prøve hva
# som skjer *mellom* to transaksjoner. Denne prøven kjører derfor mange reelle
# forbindelser mot hverandre, med hver sitt kall i hver sin transaksjon, og
# kontrollerer at kvoten holder.
#
# Uten radlåsen i funksjonen feiler den: forsøkene slipper gjennom i flokk.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

DB_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --db-url)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ -n "$DB_URL" ]; then
        printf 'Forventet nøyaktig én ikke-tom --db-url.\n' >&2
        exit 2
      fi
      DB_URL=$2
      shift 2
      ;;
    *) printf 'Ukjent argument.\n' >&2; exit 2 ;;
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

# Kontrolleres før noe som helst SQL sendes. Prøven skriver til en ekte tabell,
# og den skal bare kunne gjøre det mot en lokal, isolert database.
node scripts/local-test-db.mjs "$DB_URL"

# Tabellen er append-only, så prøven kan ikke rydde etter seg. Den bruker derfor
# en ny bruker-id hver gang, og teller bare sine egne rader.
USER_ID=$(psql "$DB_URL" -X -tAq -v ON_ERROR_STOP=1 -c 'select gen_random_uuid()')
CONNECTIONS=12
PER_CONNECTION=10
QUOTA=60

printf 'Kjører %s forbindelser med %s kall hver mot kvoten på %s.\n' \
  "$CONNECTIONS" "$PER_CONNECTION" "$QUOTA"

for connection in $(seq 1 "$CONNECTIONS"); do
  {
    # Sesjonsnivå, ikke transaksjonsnivå: hvert kall under skal være sin egen
    # transaksjon, ellers ville én forbindelse holdt låsen gjennom alle sine
    # kall og prøven ikke målt noe kappløp.
    printf "select set_config('request.jwt.claims', '{\"sub\":\"%s\"}', false);\n" "$USER_ID"
    printf 'set role authenticated;\n'
    for call in $(seq 1 "$PER_CONNECTION"); do
      # Forskjellige operasjoner med vilje: to kall med samme signatur ville
      # kunnet låse den samme incident-raden og skjule kappløpet.
      printf "select api.record_client_diagnostic('work_queue', 'unavailable', %s, null, null, 'network', 'forbindelse %s kall %s');\n" \
        "$([ $((call % 2)) -eq 0 ] && printf "'public_work_board'" || printf "'full_text_inbox'")" \
        "$connection" "$call"
    done
  } | psql "$DB_URL" -X -q -v ON_ERROR_STOP=0 >/dev/null 2>&1 &
done
wait

STORED=$(psql "$DB_URL" -X -tAq -v ON_ERROR_STOP=1 -c \
  "select count(*) from workflow.client_diagnostics where reported_by_user_id = '$USER_ID'")

printf '%s forsøk ga %s lagrede rader.\n' "$((CONNECTIONS * PER_CONNECTION))" "$STORED"

if [ "$STORED" -gt "$QUOTA" ]; then
  printf 'Kvoten holdt ikke: %s rader er over grensen på %s.\n' "$STORED" "$QUOTA" >&2
  exit 1
fi
if [ "$STORED" -lt 1 ]; then
  printf 'Ingenting ble lagret. Da prøver ikke denne testen det den skal.\n' >&2
  exit 1
fi

printf 'Kvoten holdt under samtidighet.\n'
