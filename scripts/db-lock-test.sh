#!/usr/bin/env bash
#
# Samtidighetsprøve: kontrollen av «det du faktisk så» holder revisjonslåsen.
#
#   ./scripts/db-lock-test.sh                       # mot den lokale stacken
#   ./scripts/db-lock-test.sh --db-url <url>        # mot en annen database
#
# ----------------------------------------------------------------------------
# Hvorfor dette ikke er en pgTAP-fil
#
# pgTAP-filene kjører i én transaksjon som rulles tilbake. En andre forbindelse
# ville verken sett fiksturen deres eller kunnet kappes mot dem, og dblink og
# postgres_fdw nekter en ikke-superbruker å koble seg til en server som
# autentiserer med trust — som den lokale stacken gjør. En prøve på hva som skjer
# *mellom* to transaksjoner må derfor være to reelle forbindelser, og det er hva
# denne filen er.
#
# ----------------------------------------------------------------------------
# Hva den prøver
#
# workflow.assert_evidence_set_unchanged(uuid, text) tar FOR UPDATE på
# revisjonsraden før den sammenligner avtrykket, og holder låsen ut
# transaksjonen (migrasjon 006f). Uten den låsen kunne en evidenslenke commite
# mellom kontrollen og innsettingen, og avtrykket som lagres — beregnet av
# triggeren på raden — ville beskrevet et sett revieweren aldri så.
#
# Prøven kjører de to transaksjonene mot hverandre:
#
#   Økt A   begynner en transaksjon og kaller kontrollen. Låsen holdes.
#   Økt B   forsøker å legge til en evidenslenke på den samme revisjonen, med
#           lock_timeout satt.
#
# Hver innsetting i knowledge.claim_evidence_links tar selv FOR UPDATE på
# revisjonen, i knowledge.reject_evidence_link_after_assessment(). Økt B må
# derfor vente, og med lock_timeout satt gir det 55P03 (lock_not_available).
#
# Det er nettopp den forskjellen prøven leser: uten låsen i kontrollen ville økt
# B ikke ventet i det hele tatt, og fått 23001 fra forseglingskontrollen som
# ligger *etter* låsen i den samme triggeren. 55P03 betyr «måtte vente», 23001
# betyr «slapp forbi». Ingen av dem skriver noe: begge feiler.
#
# Revisjonen er en av de to som seedes av migrasjon 20260819124500, altså
# committet data enhver forbindelse ser. Prøven oppretter ingenting og har
# ingenting å rydde: begge øktene rulles tilbake.
set -euo pipefail

DB_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --db-url) DB_URL="$2"; shift 2 ;;
    *) printf 'Ukjent argument: %s\n' "$1" >&2; exit 2 ;;
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

if [ -z "$DB_URL" ]; then
  printf 'Fant ingen databaseadresse. Start den lokale stacken (npm run db:start), eller oppgi --db-url.\n' >&2
  exit 1
fi

arbeid=$(mktemp -d)
trap 'rm -rf "$arbeid"; [ -n "${okt_a_pid:-}" ] && kill "$okt_a_pid" 2>/dev/null || true' EXIT

# Revisjonen og dens avtrykk. Den første i uuid-rekkefølge, slik at valget ikke
# avhenger av hvilke uuid-er seeden tilfeldigvis genererte.
les() { psql "$DB_URL" -tAX -c "$1"; }

revisjon=$(les "select r.id from knowledge.claim_revisions r order by r.id limit 1")
if [ -z "$revisjon" ]; then
  printf 'Fant ingen påstandsrevisjon i databasen. Kjør migrasjonene først (npm run db:reset).\n' >&2
  exit 1
fi
avtrykk=$(les "select knowledge.claim_evidence_set_digest('$revisjon')")
funn=$(les "select e.id from knowledge.evidence_items e order by e.id limit 1")
forfatter=$(les "select r.created_by_actor_id from knowledge.claim_revisions r where r.id = '$revisjon'")

printf 'Revisjon: %s\n' "$revisjon"

# ----------------------------------------------------------------------------
# Økt A — kontrollen kalles, og transaksjonen holdes åpen
#
# Signalfilen sier når låsen er tatt. Uten den ville økt B kunnet komme først, og
# prøven ville målt rekkefølgen på to prosesser framfor låsen.
# ----------------------------------------------------------------------------
mkfifo "$arbeid/styr"
(
  printf "begin;\n"
  printf "select workflow.assert_evidence_set_unchanged('%s', '%s');\n" "$revisjon" "$avtrykk"
  printf "\\\\echo LÅST\n"
  printf "\\\\o /dev/null\n"
  cat "$arbeid/styr"
  printf "rollback;\n"
) | psql "$DB_URL" -X -v ON_ERROR_STOP=1 > "$arbeid/a.log" 2>&1 &
okt_a_pid=$!
exec 9>"$arbeid/styr"

for _ in $(seq 1 100); do
  grep -q 'LÅST' "$arbeid/a.log" 2>/dev/null && break
  sleep 0.1
done
if ! grep -q 'LÅST' "$arbeid/a.log" 2>/dev/null; then
  printf 'Økt A fikk ikke tatt låsen:\n' >&2
  cat "$arbeid/a.log" >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# Økt B — forsøker å utvide evidenssettet mens låsen holdes
# ----------------------------------------------------------------------------
set +e
psql "$DB_URL" -X -tA > "$arbeid/b.log" 2>&1 <<SQL
\\set VERBOSITY verbose
set lock_timeout = '2s';
begin;
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
values ('$revisjon', '$funn', 'supports', 'direct',
        'Samtidighetsprøve; rulles tilbake.', '$forfatter');
rollback;
SQL
set -e

printf 'exit\n' >&9 || true
exec 9>&-
wait "$okt_a_pid" 2>/dev/null || true
okt_a_pid=""

if grep -q '55P03' "$arbeid/b.log"; then
  printf 'ok       en samtidig evidenslenke må vente på beslutningen (55P03)\n'
  exit 0
fi

printf 'AVVIK    en samtidig evidenslenke slapp forbi låsen kontrollen skal holde.\n' >&2
printf '         Uten den låsen kan en godkjenning bli lagret med avtrykket av et\n' >&2
printf '         evidenssett revieweren aldri så (migrasjon 006f).\n' >&2
printf '         Svaret fra økt B:\n' >&2
sed 's/^/         /' "$arbeid/b.log" >&2
exit 1
