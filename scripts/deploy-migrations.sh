#!/usr/bin/env bash
#
# Kjører de migrasjonene som mangler i et hostet Supabase-prosjekt.
#
#   ./scripts/deploy-migrations.sh --dry-run   # vis hva som mangler, kjør ingenting
#   ./scripts/deploy-migrations.sh             # kjør dem, i tidsstempelrekkefølge
#
# ----------------------------------------------------------------------------
# Hvorfor dette skriptet finnes
#
# `supabase link` og `supabase db push` kan ikke kjøres fra en agentsesjon: den
# pinnede CLI-ens Bun-runtime klarer ikke TLS gjennom sesjonens HTTPS-proxy
# (MVP_IMPLEMENTATION_PLAN.md §74.23). Migrasjonene er derfor kjørt gjennom
# Management-API-et tre ganger — §74.26, §74.28 og §74.34 — hver gang for hånd,
# med den samme framgangsmåten skrevet ut på nytt i planen. En operasjon som
# gjentar seg, og som skriver til produksjon, hører hjemme i et skript som kan
# reviewes én gang framfor i en framgangsmåte som gjengis fra hukommelsen.
#
# Skriptet gjør nøyaktig det `supabase db push` gjør, og ikke noe mer: hver
# migrasjonsfil sendes som **én forespørsel**, og hver forespørsel er **én
# transaksjon som inneholder både migrasjonens egen SQL og raden i
# `supabase_migrations.schema_migrations`». Filene tas uendret fra repoet;
# ingenting skrives for hånd.
#
# ----------------------------------------------------------------------------
# Hvorfor én fil per forespørsel, og ikke alle i én
#
# `ALTER TYPE ... ADD VALUE` og bruken av den nye verdien kan ikke ligge i samme
# transaksjon (§74.24). Enum-utvidelsene ligger derfor alltid alene i sin egen
# migrasjonsfil, og én forespørsel per fil er nettopp det skillet som får dem til
# å committe før filen som bruker verdien.
#
# ----------------------------------------------------------------------------
# Driftskontrollen skriptet gjør før det skriver noe
#
# Kontrollen ligger i `src/ops/migration-plan.ts`, som har tester, og den er på
# versjon og navn, på at ingen av de to listene har rader den andre ikke har, og
# på at det som er kjørt utgjør et **sammenhengende prefiks** av filene i
# repoet. Det siste er ikke en formalitet: uten det ville registrert historikk
# `A, C` mot lokal `A, B, C` fått skriptet til å kjøre `B` etter `C`. Et hull
# betyr at prosjektet og repoet har kommet fra hverandre, og det er ikke noe et
# deployskript skal reparere selv — det melder fra og kjører ingenting.
#
# Kontrollen er *ikke* på innholdet i `statements`-kolonnen, og det
# er en avlesning og ikke en forglemmelse: kolonnen inneholder forskjellig tekst
# avhengig av hvilket verktøy som skrev raden. `supabase db push` deler filen i
# enkeltsetninger og fjerner kommentarene (de tretten første radene i dette
# prosjektet har mellom 4 og 158 elementer og er en brøkdel av filens lengde),
# mens Management-API-kjøringene i §74.26 la inn hele filen som ett element. En
# sammenligning på innhold ville derfor meldt avvik på tretten filer ingen har
# rørt, og en vaktpost som roper ulv er verre enn ingen vaktpost.
#
# En merget migrasjon skal likevel aldri redigeres — Supabase kjører aldri en
# registrert versjon på nytt (§74.32) — men den regelen kan ikke håndheves
# herfra, og hører hjemme i review.
#
# Miljø:
#   SUPABASE_PROJECT_REF    prosjektets referanse
#   SUPABASE_ACCESS_TOKEN   personlig access token til Management-API-et

set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Ukjent valg: $1" >&2; exit 2 ;;
  esac
done

: "${SUPABASE_PROJECT_REF:?mangler SUPABASE_PROJECT_REF}"
: "${SUPABASE_ACCESS_TOKEN:?mangler SUPABASE_ACCESS_TOKEN}"

API="https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF}/database/query"

# Sender én SQL-tekst som én forespørsel. Kroppen bygges av `node` framfor av
# `printf`, slik at JSON-escapingen av migrasjonens egen tekst er riktig uansett
# hva filen inneholder.
kjor_sql() {
  local sql_fil=$1 svar kode kropp
  svar=$(node -e '
    const fs = require("fs");
    process.stdout.write(JSON.stringify({ query: fs.readFileSync(process.argv[1], "utf8") }));
  ' "$sql_fil" | curl -sS -w $'\n%{http_code}' -X POST "$API" \
      -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d @-)
  kode=$(printf '%s' "$svar" | tail -n1)
  kropp=$(printf '%s' "$svar" | sed '$d')
  if [ "$kode" != "200" ] && [ "$kode" != "201" ]; then
    echo "$kropp" >&2
    return 1
  fi
  printf '%s' "$kropp"
}

arbeid=$(mktemp -d)
trap 'rm -rf "$arbeid"' EXIT

# 1. Les historikken, og sammenlign den med filene i repoet.
echo 'select version, name from supabase_migrations.schema_migrations order by version' \
  > "$arbeid/historikk.sql"
kjor_sql "$arbeid/historikk.sql" > "$arbeid/historikk.json"

# Selve sammenligningen ligger i `src/ops/migration-plan.ts`, som har tester.
# Den avgjør om det skrives til produksjon, og den avviser blant annet et hull i
# historikken framfor å kjøre en eldre migrasjon etter en nyere.
node src/ops/migration-plan-cli.ts "$arbeid/historikk.json" "$arbeid/mangler.json"

antall=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).length)' "$arbeid/mangler.json")
[ "$antall" = "0" ] && exit 0

if [ "$DRY_RUN" = "1" ]; then
  echo
  echo "--dry-run: ingenting er kjørt."
  exit 0
fi

# 2. Kjør dem, én fil om gangen, i tidsstempelrekkefølge.
echo
for i in $(seq 0 $((antall - 1))); do
  fil=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))[process.argv[2]].file)' "$arbeid/mangler.json" "$i")
  versjon="${fil:0:14}"
  navn=$(basename "$fil" .sql)
  navn="${navn:15}"

  # Migrasjonens egen SQL, og historikkraden, i én og samme transaksjon.
  # `statements` får filens tekst uendret, slik `db push` skriver den.
  node -e '
    const fs = require("fs");
    const [fil, versjon, navn, ut] = process.argv.slice(1);
    const sql = fs.readFileSync(`supabase/migrations/${fil}`, "utf8");
    const tag = "antidep_mig";
    if (sql.includes(tag)) throw new Error(`dollar-quote-taggen $${tag}$ finnes i ${fil}`);
    fs.writeFileSync(
      ut,
      sql +
        "\n\ninsert into supabase_migrations.schema_migrations (version, name, statements)\n" +
        `values ($${tag}_v$${versjon}$${tag}_v$, $${tag}_n$${navn}$${tag}_n$,\n` +
        `        array[$${tag}$` + sql + `$${tag}$]);\n`,
    );
  ' "$fil" "$versjon" "$navn" "$arbeid/kjor.sql"

  printf '  %s %-40s ' "$versjon" "$navn"
  if kjor_sql "$arbeid/kjor.sql" > /dev/null; then
    echo "ok"
  else
    echo "FEIL — ingenting er skrevet for denne migrasjonen, og resten er ikke forsøkt."
    exit 1
  fi
done

echo
echo "Ferdig. Kontroller resultatet med ./scripts/deploy-migrations.sh --dry-run"
