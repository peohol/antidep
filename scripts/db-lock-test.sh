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
# den forskjellen prøvene leser. Prøve 1 til 3 skriver ingenting: begge øktene
# rulles tilbake, og de bruker rader migrasjonene allerede seeder.
#
# ----------------------------------------------------------------------------
# Prøve 4 er den motsatte formen
#
# Der prøve 1 til 3 viser at en samtidig skriving må *vente*, viser prøve 4 hva
# som skjer når to registreringer ikke venter på hverandre i det hele tatt:
# transaksjon A begynner først, transaksjon B skriver og commiter, og A skriver
# etterpå. Raden som ble skrevet sist bærer da det eldste tidsstempelet, fordi
# now() er transaksjonens starttidspunkt. Prøven beviser at
# registration_ordinal (migrasjon 005å) — og ikke klokka — avgjør hvilken rad
# som er den gjeldende, og at et avvik skrevet sist underkjenner både
# maskinbeviset og dekningen fra bekreftelsen som ble skrevet før det.
#
# Prøve 4 må skrive for å kunne vise det: økt A kan bare se økt B sin rad hvis
# den er commitet. Økt B commiter derfor én kontroll, mens økt A — den som
# faktisk prøves — rulles tilbake. Fiksturen er egen og gjenbrukes mellom
# kjøringer: en egen kilde, en egen kildeversjon og et eget evidensfunn som
# ingen påstand er lenket til, slik at ingen gate og ingen flate påvirkes.
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

# Faste id-er for fiksturen prøve 4 bygger. De står her fordi prøve 1 til 3 skal
# holde seg til radene migrasjonene seeder, og derfor må kunne se bort fra dem.
prove_kilde='7a000000-0000-4000-8000-000000000001'
prove_versjon='7a000000-0000-4000-8000-000000000002'
prove_funn='7a000000-0000-4000-8000-000000000003'

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
funn=$(les "select e.id from knowledge.evidence_items e
             where e.source_id <> '$prove_kilde' order by e.id limit 1")
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

# ----------------------------------------------------------------------------
# Prøve 4 — registreringsrekkefølgen følger skrivingene, ikke klokka
#
# Fiksturen er egen og har faste id-er, slik at gjentatte kjøringer gjenbruker
# den framfor å legge igjen nye rader. Evidensfunnet er ikke lenket til noen
# påstand, så ingen publiseringsgate leser det.
# ----------------------------------------------------------------------------
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<SQL
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
select '$prove_kilde', 'journal_article',
       'Samtidighetsprøve for registreringsrekkefølgen',
       'scripts/db-lock-test.sh', a.id
from provenance.actors a where a.actor_key = 'human:peder-holman'
on conflict (id) do nothing;

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, representation,
   retrieved_by_actor_id)
select '$prove_versjon', '$prove_kilde', now(),
       'https://example.test/samtidighetsprove', 'sha256:' || repeat('7', 64),
       'abstract', a.id
from provenance.actors a where a.actor_key = 'human:peder-holman'
on conflict (id) do nothing;

insert into knowledge.evidence_items
  (id, source_id, source_version_id, design_code, population_availability,
   population_detail, sample_size_availability, intervention_drug_id,
   comparator_kind, outcome_concept_id, outcome_detail, timepoint_availability,
   reported_direction, estimate_availability, confidence_interval_availability,
   source_locator, extraction_method, created_by_actor_id)
select '$prove_funn', '$prove_kilde', '$prove_versjon',
       'randomized_controlled_trial', 'not_reported', 'Samtidighetsprøve.',
       'not_reported', d.id, 'none', c.id, 'Samtidighetsprøve.', 'not_reported',
       'increase', 'not_reported', 'not_reported', 'Samtidighetsprøve', 'manual',
       a.id
from catalog.drugs d, catalog.clinical_concepts c, provenance.actors a
where d.canonical_name = 'sertralin'
  and c.canonical_label = 'vektendring'
  and a.actor_key = 'human:peder-holman'
on conflict (id) do nothing;
SQL

# psql skriver kommandomerket ved siden av raden uten -q, og «INSERT 0 1» ville
# blitt en del av id-en.
lag_kjoering() {
  psql "$DB_URL" -tAXq -c "insert into provenance.agent_runs
         (agent_identity_id, actor_id, agent_role, provider, model, model_version,
          prompt_template_version, pipeline_version, input_manifest)
       select i.id, i.actor_id, 'extraction_verification', 'db-lock-test',
              'db-lock-test', '1', 'extraction-verification/1', 'antidep-evidence/1',
              '{\"mode\": \"db-lock-test\"}'::jsonb
       from provenance.agent_identities i
       where i.identity_key = 'agent-identity:extraction-verification-01'
       returning id" | head -1
}

verifikator_agent=$(les "select a.id from provenance.actors a where a.actor_key = 'agent:extraction-verification'")
kjoering_b=$(lag_kjoering)
kjoering_a=$(lag_kjoering)

if [ -z "$verifikator_agent" ] || [ -z "$kjoering_a" ] || [ -z "$kjoering_b" ]; then
  printf 'Fikk ikke satt opp fiksturen for prøve 4. Kjør migrasjonene først (npm run db:reset).\n' >&2
  exit 1
fi

a4_log="$arbeid/a4.log"
styr4="$arbeid/styr4.$$"
rm -f "$styr4"
mkfifo "$styr4"

# Økt A begynner *først*, og gjør ikke annet enn å feste transaksjonens klokke.
# Den tar ingen lås, så økt B blir ikke ventet på noe sted: dette er ikke en
# låseprøve, men en prøve på hva «senere» betyr.
(
  printf "begin;\n"
  printf "select 1;\n"
  printf "\\\\echo A_STARTET\n"
  cat "$styr4"
) | psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 > "$a4_log" 2>&1 &
okt_a_pid=$!
exec 9>"$styr4"

for i in $(seq 1 100); do
  grep -q 'A_STARTET' "$a4_log" 2>/dev/null && break
  sleep 0.1
done
if ! grep -q 'A_STARTET' "$a4_log" 2>/dev/null; then
  printf 'Økt A kom ikke i gang i prøve 4:\n' >&2
  cat "$a4_log" >&2
  exec 9>&-
  exit 1
fi

# Klokkeskillet skal være målbart: uten det kunne begge radene fått samme
# tidsstempel, og prøven ville ikke vist noe.
sleep 0.3

# Økt B skriver og commiter mens økt A står åpen.
if ! psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 >"$arbeid/b4.log" 2>&1 <<SQL
begin;
select workflow.record_evidence_verification(
  '$prove_funn', '$verifikator_agent', '$kjoering_b',
  'uncertain', 'verifiable_representation', array['source_locator'],
  'Samtidighetsprøve: kontrollen konkluderte ikke om innholdet.',
  'Samtidighetsprøve; skrevet av økt B, som begynte sist.');
commit;
SQL
then
  printf 'Økt B fikk ikke registrert kontrollen sin i prøve 4:\n' >&2
  cat "$arbeid/b4.log" >&2
  exec 9>&-
  exit 1
fi

# …og økt A skriver etterpå, med det eldre tidsstempelet.
cat >&9 <<SQL
do \$p\$
begin
  if not workflow.grounding_machine_proved('$prove_funn') then
    raise exception 'Maskinbeviset fra økt B gjelder ikke før økt A skriver; prøven kan ikke vise at det blir underkjent.';
  end if;
end
\$p\$;

select workflow.record_evidence_verification(
  '$prove_funn', '$verifikator_agent', '$kjoering_a',
  'needs_correction', 'verifiable_representation', array['source_locator'],
  'Samtidighetsprøve: utdraget ble ikke gjenfunnet.',
  'Samtidighetsprøve; skrevet av økt A, som begynte først og skrev sist.');

do \$p\$
declare
  v_a workflow.evidence_verifications;
  v_b workflow.evidence_verifications;
  v_gjeldende text;
begin
  select * into v_a from workflow.evidence_verifications
  where evidence_item_id = '$prove_funn'
  order by registration_ordinal desc limit 1;

  select * into v_b from workflow.evidence_verifications
  where evidence_item_id = '$prove_funn' and outcome = 'uncertain'
  order by registration_ordinal desc limit 1;

  if v_a.outcome <> 'needs_correction' then
    raise exception 'Raden med høyest registreringsnummer er ikke den økt A skrev.';
  end if;
  if not (v_a.verified_at < v_b.verified_at) then
    raise exception 'Forutsetningen mangler: økt A sin rad bærer ikke et eldre tidsstempel enn økt B sin.';
  end if;
  if not (v_a.registration_ordinal > v_b.registration_ordinal) then
    raise exception 'Raden som ble skrevet sist fikk ikke det høyeste registreringsnummeret.';
  end if;

  v_gjeldende := workflow.evidence_verification_history('$prove_funn')
                 ->> 'current_extraction_verification_id';
  if v_gjeldende is distinct from v_a.id::text then
    raise exception 'Den gjeldende kontrollen er ikke den som ble skrevet sist.';
  end if;

  if workflow.grounding_machine_proved('$prove_funn') then
    raise exception 'Et avvik skrevet sist underkjente ikke maskinbeviset.';
  end if;
  if array_length(workflow.covered_check_fields('$prove_funn'), 1) is not null then
    raise exception 'Et avvik skrevet sist nullstilte ikke dekningen.';
  end if;
end
\$p\$;
\echo REKKEFØLGE_BEVIST
rollback;
SQL

exec 9>&-
wait "$okt_a_pid" 2>/dev/null || true
okt_a_pid=""
rm -f "$styr4"

# Kjøringene lukkes med det de faktisk gjorde: økt B sin produserte en kontroll,
# økt A sin ble rullet tilbake.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 >/dev/null <<SQL
update provenance.agent_runs
set status = 'succeeded', completed_at = now(),
    output_manifest = '{"mode": "db-lock-test", "verifications": 1}'::jsonb
where id = '$kjoering_b';
update provenance.agent_runs
set status = 'aborted', completed_at = now(),
    failure_reason = 'Samtidighetsprøve; transaksjonen ble rullet tilbake.'
where id = '$kjoering_a';
SQL

if grep -q 'REKKEFØLGE_BEVIST' "$a4_log"; then
  printf 'ok       raden som ble skrevet sist er den gjeldende, uansett klokke\n'
else
  printf 'AVVIK    raden som ble skrevet sist er den gjeldende, uansett klokke\n' >&2
  printf '         Uten en registreringsrekkefølge kan et avvik som ble skrevet sist bære det eldste tidsstempelet, og forsvinne bak en bekreftelse (migrasjon 005å).\n' >&2
  printf '         Svaret fra økt A:\n' >&2
  sed 's/^/         /' "$a4_log" >&2
  exit 1
fi

printf '\nAlle samtidighetsprøvene passerte.\n'
