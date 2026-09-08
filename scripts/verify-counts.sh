#!/usr/bin/env bash
#
# Kontrollerer at tallene i styringsdokumentene stemmer med kilden.
#
# Bakgrunn: to ganger har et tall vært feil i planen, ikke fordi noen regnet
# feil, men fordi tallet ble arvet fra en gjeldspost eller en hand-off og ført
# videre i god tro (MVP_IMPLEMENTATION_PLAN.md §74.8). Et tall ingenting
# kontrollerer, driver. Denne vaktposten er derfor maskinell, som resten av
# konvensjonene i supabase/tests/030_conventions_test.sql.
#
# Kilden vinner alltid. Slår kontrollen ut, er dokumentet feil — ikke koden.
#
# Kun kildekode og git: ingen database, ingen Docker, ingen npm-avhengigheter.
# Kjøres i CI-jobben «Lint, format, typecheck, test og build», som henter hele
# historikken fordi statuskontrollen under leser den.
#
#   ./scripts/verify-counts.sh
#
# Exit 0 = alle påstander stemmer. Exit 1 = avvik, eller en påstand som ikke
# lenger lar seg finne i dokumentet.

set -uo pipefail
cd "$(dirname "$0")/.."

PLAN=docs/MVP_IMPLEMENTATION_PLAN.md
feil=0

# Rapporter én påstand. En påstand som ikke finnes er et brudd, ikke et
# frikort: uten dette ville en omformulering i planen gjort vakten stille.
sjekk() {
  local navn=$1 paastatt=$2 faktisk=$3 kilde=$4
  if [ -z "$paastatt" ]; then
    printf '  FEIL     %-26s fant ingen påstand i %s\n' "$navn" "$PLAN"
    feil=1
  elif [ "$paastatt" != "$faktisk" ]; then
    printf '  AVVIK    %-26s dokumentet sier %s, %s sier %s\n' \
      "$navn" "$paastatt" "$kilde" "$faktisk"
    feil=1
  else
    printf '  ok       %-26s %s\n' "$navn" "$faktisk"
  fi
}

echo "Kontrollerer tallpåstander i $PLAN mot kilden."
echo

# 1. pgTAP-assertions.
#
# Summen av plan(N) er sann bare når suiten faktisk passerer: en feil plan(N)
# gir «Looks like you planned X but ran Y» i npm run db:test, som kjører i sin
# egen CI-jobb. Her er summen den raske stedfortrederen, slik at et tall i
# planen kan kontrolleres uten å starte en database.
sjekk "pgTAP-assertions" \
  "$(grep -oE 'teller nå [0-9]+' "$PLAN" | grep -oE '[0-9]+' | head -1)" \
  "$(grep -hoE 'select plan\([0-9]+\)' supabase/tests/*.sql | grep -oE '[0-9]+' | paste -sd+ | bc)" \
  "summen av plan(N)"

# 2. Testfiler.
sjekk "testfiler" \
  "$(grep -oE '[0-9]+ testfiler' "$PLAN" | grep -oE '[0-9]+' | head -1)" \
  "$(ls supabase/tests/*.sql | wc -l | tr -d ' ')" \
  "supabase/tests/"

# 3. Enum-typer totalt. Dette er tallet som var feil i §74.7 fram til 006a.
sjekk "enum-typer totalt" \
  "$(grep -oE '[0-9]+ enum-typer' "$PLAN" | grep -oE '[0-9]+' | head -1)" \
  "$(grep -hcE '^create type ' supabase/migrations/*.sql | paste -sd+ | bc)" \
  "create type i migrasjonene"

# 4. Enum-typer per migrasjon.
#
# Totalen alene ville ikke fanget at fordelingen er feil, og det var nettopp
# fordelingen som drev fra hverandre: gjeldsposten oppga 37 for både 005 og 006.
# Tallene er formulert som antallet lagt til i hver migrasjon, i filrekkefølge.
#
# Påstanden brytes over to linjer i planen. En linjebasert grep fanget derfor
# bare prefikset fram til bruddet, og siste ledd stod ukontrollert — en
# mutasjon av det overlevde. Linjeskift normaliseres nå bort før mønsteret
# brukes.
plan_flat=$(tr '\n' ' ' < "$PLAN" | tr -s ' ')
paastatt_fordeling=$(
  printf '%s' "$plan_flat" \
    | grep -oE 'henholdsvis [0-9]+(, [0-9]+)*(,? og [0-9]+)?' \
    | head -1 | grep -oE '[0-9]+' | paste -sd, -
)
faktisk_fordeling=$(
  grep -hcE '^create type ' supabase/migrations/*.sql | paste -sd, -
)

antall_paastatt=$(printf '%s' "$paastatt_fordeling" | tr ',' '\n' | grep -c .)
antall_faktisk=$(printf '%s' "$faktisk_fordeling" | tr ',' '\n' | grep -c .)

# Fordelingen skal oppgi ett ledd per migrasjonsfil, verken flere eller færre.
#
# Å bare sammenligne så mange ledd som planen oppgir — uten å kontrollere at
# avkortingen er berettiget — gjorde en kort påstand til en stille godkjenning:
# en påstand som var kortere enn den skulle, matchet alltid sitt eget prefiks.
#
# Restpåstanden under fanget det så lenge det siste oppgitte leddet var det
# siste som ikke var null. Migrasjon 007a la ikke til enum-typer, og da ble
# halen null: en påstand forkortet til ni ledd passerte restpåstanden, samtidig
# som prosaen rundt den fortsatt sa «de ti migrasjonsfilene». Derfor kreves nå
# fullstendighet direkte. Restpåstanden beholdes som en andre linje, ikke som
# den eneste.
if [ "$antall_paastatt" -ne "$antall_faktisk" ]; then
  printf '  AVVIK    %-26s dokumentet oppgir %s ledd, men det finnes %s migrasjonsfiler\n' \
    "enum-typer per migrasjon" "$antall_paastatt" "$antall_faktisk"
  feil=1
else
  sjekk "enum-typer per migrasjon" \
    "$paastatt_fordeling" \
    "$(printf '%s' "$faktisk_fordeling" | cut -d, -f1-"${antall_paastatt:-0}")" \
    "create type per fil"

  # Restpåstanden: migrasjonene planen ikke lister opp, la ikke til enum-typer.
  rest=$(printf '%s' "$faktisk_fordeling" | tr ',' '\n' | tail -n +"$((antall_paastatt + 1))")
  rest_ikke_null=$(printf '%s' "$rest" | grep -vc '^0$' || true)
  sjekk "enum-typer etter de oppgitte" "0" "${rest_ikke_null:-0}" \
    "antall migrasjoner med enum-typer utover de $antall_paastatt planen lister"
fi

# 5. Den eksponerte schemalisten i §74.5 punkt 3.
#
# Punktet hevder en konkret konfigurasjonsverdi, og verdien ligger i repoet.
# Uten denne kontrollen kunne `[api].schemas` endres i supabase/config.toml
# uten at påstanden fulgte med — samme driftsmodus som tallene over, og med en
# sikkerhetskonsekvens: et kanonisk schema lagt til der ville gjort planens
# «bare kontraktslaget er eksponert» usann i stillhet.
#
# Bare `config.toml` kontrolleres. Hva det hostede prosjektet faktisk eksponerer,
# er ikke kildekode og kan ikke nås herfra (§74.18) — den påstanden føres med sin
# kilde i planen framfor å bli hevdet som et faktum.
#
# Mellomrom fjernes på begge sider, slik at kontrollen gjelder verdien og ikke
# formateringen: `["api","graphql_public"]` og `["api", "graphql_public"]` er
# samme liste.
uten_mellomrom() { tr -d ' '; }

paastatt_schemas=$(
  printf '%s' "$plan_flat" \
    | grep -oE 'Verdien er nå `\[[^]]*\]`' \
    | head -1 | sed -E 's/^Verdien er nå `//; s/`$//' | uten_mellomrom
)
antall_schemalinjer=$(grep -cE '^schemas *= *\[' supabase/config.toml)

if [ "$antall_schemalinjer" -ne 1 ]; then
  # Null linjer ville gjort «faktisk» til den tomme strengen, og to ville gjort
  # det uklart hvilken som gjelder. Begge deler skal si fra, ikke sammenlignes.
  printf '  FEIL     %-26s fant %s linjer «schemas = [...]» i supabase/config.toml, forventet 1\n' \
    "eksponerte schemaer" "$antall_schemalinjer"
  feil=1
else
  sjekk "eksponerte schemaer" \
    "$paastatt_schemas" \
    "$(grep -E '^schemas *= *\[' supabase/config.toml | sed -E 's/^schemas *= *//' | uten_mellomrom)" \
    "[api].schemas i supabase/config.toml"
fi

# 6. Statusen på PR-radene i §74.2.
#
# Konvensjonen er at statuskolonnen beskriver tilstanden da raden ble skrevet:
# den nyeste raden står som «åpen» til neste PR retter den. Konvensjonen virker
# bare hvis neste PR faktisk gjør det, og fire ganger på rad har den nyeste raden
# vært foreldet ved sesjonsstart.
#
# Regelen som kontrolleres er derfor: alle rader unntatt den siste skal stå som
# «merget». Den siste er unntatt, fordi en PR ikke kan vite sin egen
# mergestatus — og nettopp derfor fanges forsømmelsen i det øyeblikket noen
# legger til raden under den.
#
# I tillegg kontrolleres den andre veien mot git: en rad ført som «merget» skal
# ha en commit `(#N)` i historikken. Det fanger en rad som er merket ferdig for
# tidlig.
pr_rader=$(grep -oE '\(#[0-9]+\) +(merget|åpen)' "$PLAN")
pr_linjer=$(grep -cE '\(#[0-9]+\)' "$PLAN" || true)
antall_rader=$(printf '%s' "$pr_rader" | grep -c . || true)

if [ "${antall_rader:-0}" -eq 0 ]; then
  printf '  FEIL     %-26s fant ingen PR-rader i %s\n' "PR-rader" "$PLAN"
  feil=1
else
  # En linje med (#N) uten status ville falt ut av kontrollen under uten å
  # feile, og da ville «den siste raden» pekt på feil rad.
  sjekk "PR-rader med status" "$antall_rader" "$pr_linjer" "linjer med (#N) i planen"

  foreldet=$(
    printf '%s\n' "$pr_rader" | sed '$d' | grep 'åpen' | grep -oE '#[0-9]+' | paste -sd' ' -
  )
  if [ -n "$foreldet" ]; then
    printf '  AVVIK    %-26s står som åpen, men er ikke den nyeste raden: %s\n' \
      "foreldet PR-status" "$foreldet"
    feil=1
  else
    printf '  ok       %-26s alle rader unntatt den nyeste står som merget\n' "foreldet PR-status"
  fi

  # Den andre veien: git er kilden, dokumentet er påstanden.
  #
  # En rad er funnet i historikken når ETT av to holder:
  #
  #   1. et commit-emne bærer `(#N)`, som en squash-merge normalt legger på, eller
  #   2. et commit-emne er nøyaktig radens tittel
  #
  # Den andre formen finnes fordi squash-mergen av #59 ikke tok med nummeret i
  # emnet — bare i kroppen, som «Funnet i teknisk review av PR #59». Uten den
  # ville en rad som faktisk *er* merget, blitt ført som et avvik, og den eneste
  # veien videre hadde vært å svekke kontrollen eller å lyve i tabellen.
  #
  # Tittelformen er ikke en løsere kontroll enn nummerformen: tabellen sier selv
  # at «titlene er commit-emnene ordrett», så et eksakt treff på emnet er en
  # sterkere påstand enn et treff på nummeret alene. De eldste radene (PR A til
  # PR G, #19 og #30) bærer et prefiks i tabellen og treffer derfor bare på
  # nummeret; de nyeste treffer på begge.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf '  FEIL     %-26s kontrollen krever et git-arbeidstre\n' "merget mot historikk"
    feil=1
  elif [ "$(git rev-parse --is-shallow-repository)" != "false" ]; then
    # En grunn klone ville gjort hver «merget»-rad til et avvik. Kontrollen sier
    # fra framfor å slå seg av; CI henter hele historikken (fetch-depth: 0).
    printf '  FEIL     %-26s historikken er avkortet (shallow clone)\n' "merget mot historikk"
    feil=1
  else
    emner=$(git log --format='%s')
    historikk=$(printf '%s\n' "$emner" | grep -oE '\(#[0-9]+\)' | tr -d '(#)' | sort -u)
    while IFS= read -r rad; do
      printf '%s' "$rad" | grep -q 'merget' || continue
      tidlig=$(printf '%s' "$rad" | grep -oE '\(#[0-9]+\)' | tr -d '(#)')
      tittel=$(printf '%s' "$rad" | sed -E 's/ *\(#[0-9]+\).*$//; s/^ *//')
      printf '%s\n' "$historikk" | grep -qx "$tidlig" && continue
      printf '%s\n' "$emner" | grep -qxF "$tittel" && continue
      ufunnet="${ufunnet:-} #$tidlig"
    done <<< "$(grep -E '\(#[0-9]+\) +(merget|åpen)' "$PLAN")"
    if [ -n "${ufunnet:-}" ]; then
      printf '  AVVIK    %-26s ført som merget, men uten commit i historikken:%s\n' \
        "merget mot historikk" "$ufunnet"
      feil=1
    else
      printf '  ok       %-26s hver merget rad har sin commit\n' "merget mot historikk"
    fi
  fi
fi

echo
if [ "$feil" -ne 0 ]; then
  cat <<'HJELP'
Minst én påstand stemmer ikke med kilden.

Kilden vinner: rett tallet i dokumentet, ikke i koden. Står det «fant ingen
påstand», er setningen omformulert slik at vakten ikke finner den lenger —
rett da enten setningen eller mønsteret her, framfor å fjerne kontrollen.

Står det «eksponerte schemaer», er §74.5 punkt 3 og supabase/config.toml ute av
synk. Kilden er config.toml: rett punktet i planen, med mindre schemalisten
selv er feil — da er det en sikkerhetsendring og ikke en tekstrettelse.

Står det «foreldet PR-status», er §74.2 ikke ført videre: statuskolonnen på
raden over den nyeste beskriver fortsatt tilstanden da raden ble skrevet. Rett
den til «merget» i den PR-en som legger til raden under.

Tilstandstall som ikke dekkes her — publiserte påstander, RLS-policyer,
tabeller med klientgrant — krever en kjørende database. Se supabase/README.md.
HJELP
  exit 1
fi

echo "Alle kontrollerte tallpåstander stemmer med kilden."
