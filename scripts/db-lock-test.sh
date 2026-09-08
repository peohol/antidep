#!/usr/bin/env bash
#
# Samtidighetsprøver: kontrollene av «det du faktisk så» holder radlåsen.
#
#   ./scripts/db-lock-test.sh                       # mot den lokale stacken
#   ./scripts/db-lock-test.sh --db-url <url>        # mot en annen database
#
# ----------------------------------------------------------------------------
# Hvorfor dette ikke er pgTAP-filer
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
# To menneskelige skriveveier binder en vurdering til det grunnlaget revieweren
# faktisk så, og begge må ta radlåsen *før* de sammenligner — ellers er
# kontrollen bare et øyeblikksbilde, og en rad som commiter mellom kontrollen og
# innsettingen slipper gjennom.
#
#   1. workflow.assert_evidence_set_unchanged(uuid, text) (migrasjon 006f) låser
#      påstandsrevisjonen. Uten låsen kunne en evidenslenke commite i vinduet, og
#      avtrykket som lagres — beregnet av triggeren på raden — ville beskrevet et
#      sett revieweren aldri så.
#
#   2. workflow.assert_extraction_unchanged(uuid, text) (migrasjon 005s) låser
#      evidensfunnet og tar delt lås på kilden. Uten dem kunne en annen kontroll,
#      eller en endring av kildens status, commite i vinduet — og kontrollen ville
#      stått som en kontroll av noe annet enn den var.
#
# Hver prøve kjører to økter mot hverandre:
#
#   Økt A   begynner en transaksjon og kaller kontrollen. Låsen holdes.
#   Økt B   forsøker den samtidige skrivingen, med lock_timeout satt.
#
# Med låsen svarer økt B 55P03 (lock_not_available), altså «måtte vente». Uten
# den slipper den forbi og får et helt annet svar — eller lykkes. Det er nettopp
# den forskjellen prøvene leser. Ingen av dem skriver noe: begge øktene rulles
# tilbake, og prøvene bruker rader migrasjonene allerede seeder.
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

les() { psql "$DB_URL" -tAX -c "$1"; }

# ----------------------------------------------------------------------------
# Én prøve: økt A tar låsen og holder den, økt B kappes mot den.
#
#   $1  navn på prøven, som skrives ut
#   $2  setningen økt A kaller for å ta låsen
#   $3  setningen økt B forsøker mens låsen holdes
#   $4  setningen som skrives ut når prøven feiler
# ----------------------------------------------------------------------------
proev() {
  local navn=$1 laas_sql=$2 probe_sql=$3 forklaring=$4
  local styr="$arbeid/styr.$$" a_log="$arbeid/a.log" b_log="$arbeid/b.log"

  rm -f "$styr"
  mkfifo "$styr"

  # Signalfilen sier når låsen er tatt. Uten den ville økt B kunnet komme først,
  # og prøven ville målt rekkefølgen på to prosesser framfor låsen.
  (
    printf "begin;\n"
    printf "%s\n" "$laas_sql"
    printf "\\\\echo LÅST\n"
    printf "\\\\o /dev/null\n"
    cat "$styr"
    printf "rollback;\n"
  ) | psql "$DB_URL" -X -v ON_ERROR_STOP=1 > "$a_log" 2>&1 &
  okt_a_pid=$!
  exec 9>"$styr"

  local i
  for i in $(seq 1 100); do
    grep -q 'LÅST' "$a_log" 2>/dev/null && break
    sleep 0.1
  done
  if ! grep -q 'LÅST' "$a_log" 2>/dev/null; then
    printf 'Økt A fikk ikke tatt låsen i prøven «%s»:\n' "$navn" >&2
    cat "$a_log" >&2
    exec 9>&-
    exit 1
  fi

  set +e
  psql "$DB_URL" -X -tA > "$b_log" 2>&1 <<SQL
\\set VERBOSITY verbose
set lock_timeout = '2s';
begin;
$probe_sql
rollback;
SQL
  set -e

  printf 'exit\n' >&9 || true
  exec 9>&-
  wait "$okt_a_pid" 2>/dev/null || true
  okt_a_pid=""
  rm -f "$styr"

  if grep -q '55P03' "$b_log"; then
    printf 'ok       %s\n' "$navn"
    return 0
  fi

  printf 'AVVIK    %s\n' "$navn" >&2
  printf '         %s\n' "$forklaring" >&2
  printf '         Svaret fra økt B:\n' >&2
  sed 's/^/         /' "$b_log" >&2
  exit 1
}

# ----------------------------------------------------------------------------
# Prøve 1 — evidenssettet til en påstandsrevisjon (migrasjon 006f)
#
# Hver innsetting i knowledge.claim_evidence_links tar selv FOR UPDATE på
# revisjonen, i knowledge.reject_evidence_link_after_assessment(). Økt B må
# derfor vente. Uten låsen i kontrollen ville den ikke ventet i det hele tatt, og
# fått 23001 fra forseglingskontrollen som ligger *etter* låsen i den samme
# triggeren. 55P03 betyr «måtte vente», 23001 betyr «slapp forbi».
# ----------------------------------------------------------------------------
revisjon=$(les "select r.id from knowledge.claim_revisions r order by r.id limit 1")
if [ -z "$revisjon" ]; then
  printf 'Fant ingen påstandsrevisjon i databasen. Kjør migrasjonene først (npm run db:reset).\n' >&2
  exit 1
fi
avtrykk=$(les "select knowledge.claim_evidence_set_digest('$revisjon')")
funn=$(les "select e.id from knowledge.evidence_items e order by e.id limit 1")
forfatter=$(les "select r.created_by_actor_id from knowledge.claim_revisions r where r.id = '$revisjon'")

printf 'Revisjon: %s\n' "$revisjon"
printf 'Evidensfunn: %s\n' "$funn"

proev 'en samtidig evidenslenke må vente på beslutningen (55P03)' \
  "select workflow.assert_evidence_set_unchanged('$revisjon', '$avtrykk');" \
  "insert into knowledge.claim_evidence_links
     (claim_revision_id, evidence_item_id, relationship_type, directness,
      relevance_note, created_by_actor_id)
   values ('$revisjon', '$funn', 'supports', 'direct',
           'Samtidighetsprøve; rulles tilbake.', '$forfatter');" \
  'Uten den låsen kan en godkjenning bli lagret med avtrykket av et evidenssett revieweren aldri så (migrasjon 006f).'

# ----------------------------------------------------------------------------
# Prøve 2 — grunnlaget for en ekstraksjonskontroll (migrasjon 005s)
#
# workflow.record_evidence_verification(...) tar FOR UPDATE på evidensfunnet før
# den skriver, og begge skriveveiene går gjennom den. Økt B må derfor vente.
# Uten låsen i kontrollen ville den sluppet forbi og registrert kontrollen sin,
# og avtrykket revieweren fikk utlevert ville beskrevet en kontrollhistorikk som
# ikke lenger var den gjeldende.
# ----------------------------------------------------------------------------
ekstraksjonsavtrykk=$(les "select workflow.evidence_extraction_digest('$funn')")
verifikator=$(les "select a.id from provenance.actors a where a.actor_key = 'agent:extraction-verification'")

proev 'en samtidig ekstraksjonskontroll må vente på den pågående vurderingen (55P03)' \
  "select workflow.assert_extraction_unchanged('$funn', '$ekstraksjonsavtrykk');" \
  "select workflow.record_evidence_verification(
     '$funn', '$verifikator', null,
     'uncertain', 'original_source', array['source_locator'],
     'Samtidighetsprøve; rulles tilbake.',
     'Samtidighetsprøve; kontrollen konkluderte ikke.');" \
  'Uten den låsen kan en kontroll bli registrert på et grunnlag revieweren aldri så (migrasjon 005s).'

# ----------------------------------------------------------------------------
# Prøve 3 — kildens status er en del av det som ble sett (migrasjon 005s)
#
# Den delte låsen på kilderaden blokkerer en samtidig statusendring uten å
# blokkere andre lesere. En kilde som blir trukket tilbake mens vurderingen
# pågår, ville ellers endret hva kontrollen faktisk dekket — og
# publiseringsgatens G7 er ment å fange nettopp den statusen.
# ----------------------------------------------------------------------------
kilde=$(les "select e.source_id from knowledge.evidence_items e where e.id = '$funn'")

proev 'en samtidig endring av kildens status må vente på vurderingen (55P03)' \
  "select workflow.assert_extraction_unchanged('$funn', '$ekstraksjonsavtrykk');" \
  "update knowledge.sources
   set source_status = 'retracted',
       status_note = 'Samtidighetsprøve; rulles tilbake.'
   where id = '$kilde';" \
  'Uten den delte låsen kan en kilde bli trukket tilbake i vinduet, og kontrollen bli stående som en kontroll av noe annet (migrasjon 005s).'

printf '\nAlle samtidighetsprøvene passerte.\n'
