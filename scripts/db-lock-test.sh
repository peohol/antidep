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
#
# ----------------------------------------------------------------------------
# Prøve 6 og 7 er den første formen igjen, på fjerningsveien for påstander
#
# `knowledge.discard_unpublished_claim_artifacts` (migrasjon 005ah) lover å
# feile lukket på en menneskelig evidenskontroll og på en reviewbeslutning på
# funnene påstanden er lenket til. Begge kontrollene LESER utenfor de seks
# tabellene veien sletter fra, og begge tabellene peker på
# `knowledge.evidence_items` — som veien ikke rører. En innsetting der trengte
# derfor ikke røre noen låst tabell, og kunne commite i vinduet mellom «vakten
# leste ingen» og slettingen. Funnet i teknisk review av PR #86 og rettet i
# migrasjon 005ai, som låser de to tabellene sammen med de øvrige.
#
# Økt A kaller fjerningen på en egen fikstur (scripts/discard-claim-race-fixture.sql)
# og holder låsene; økt B forsøker den samtidige registreringen. Økt A rulles
# tilbake, så fiksturen står igjen. Uten låsene venter ikke økt B i det hele
# tatt — den commiter, og fjerningen ville returnert suksess samtidig som
# vilkåret var sant.
#
# ----------------------------------------------------------------------------
# Prøve 5 er den samme formen, på en menneskelig beslutning
#
# Der prøve 4 handler om en maskinell kontroll, handler prøve 5 om et menneskes
# reviewbeslutning: økt A begynner først, økt B godkjenner og commiter, og A
# avviser etterpå. Prøven krever at avvisningen — raden som faktisk ble skrevet
# sist — er den gjeldende i reviewerflaten. Fiksturen er egen og bygget slik at
# G1 til G10 holder, slik at det eneste som avgjør utfallet, er beslutningen.
#
# Publiseringsgatens halvdel av dette flyttet med migrasjon 009e: fra da leser
# G11 og G12 den forseglede kandidaten og sluttkontrollen, ikke en
# publication_approval. Den samme regelen, på det objektet som nå bærer den,
# prøves i prøve 11.
#
# ----------------------------------------------------------------------------
# Prøve 8 til 11 — publiseringen, tilbaketrekkingen og rollbacken
#
# Publiseringslaget har to låser som må holde samtidig, og én rekkefølgeregel:
#
#   8   knowledge.publish_claim_revision(...) tar FOR UPDATE på påstanden før
#       den leser tilstanden. En samtidig tilbaketrekking må derfor vente; uten
#       låsen kunne de to lest den samme tilstanden og etterlatt to gjeldende
#       sannheter.
#
#   9   api.record_candidate_final_control(...) tar FOR UPDATE på kandidaten, og
#       publiseringen tar FOR SHARE på den samme raden. En publisering kan derfor
#       ikke skje mens en sluttkontroll pågår; uten låsen kunne en `rejected`
#       commite mellom gatens G12 og innsettingen av hendelsen.
#
#   10  Den motsatte formen, som prøve 4: økt A begynner først, økt B publiserer
#       og commiter, og A publiserer en nyere revisjon etterpå. A tar låsen når
#       den skriver, leser da den nye tilstanden, og registrerer en `replace` med
#       B sin hendelse som forgjenger. Kjeden har ett hode, og pekeren navngir
#       hodets eget innhold.
#
#   11  Samme form på sluttkontrollen: A begynner først, B godkjenner og
#       commiter, A avviser etterpå. Registreringsnummeret og ikke klokka avgjør
#       hvilken som gjelder, og publiseringsgaten stopper på avvisningen.
#
#   12  Publiseringen holder også låsene på det kandidatinnholdet faktisk
#       bygges av. En samtidig ekstraksjonskontroll på et lenket evidensfunn må
#       derfor vente; uten den låsen var kontrollen av at kandidaten fortsatt er
#       den gjeldende, et øyeblikksbilde.
#
#   13  Det samme for sluttkontrollen, på revisjonen: en samtidig
#       kildestøttekontroll må vente, fordi den er en del av det forseglede
#       innholdet.
#
#   14  Rollbacken holder de samme grunnlagslåsene, på *målrevisjonen*. Fra
#       migrasjon 009h krever den at kandidaten kalleren navnga fortsatt er det
#       gjeldende innholdet der, og den kontrollen er bare en garanti hvis
#       grunnlaget står stille fram til hendelsen.
#
#   15  Og den holder radlåsen på påstanden: en samtidig tilbaketrekking må
#       vente, som i prøve 8.
#
# Fiksturen er egen (scripts/publication-race-fixture.sql). Prøve 10 må commite
# en publisering for å kunne vise det den viser, og fiksturen trekker den tilbake
# før neste kjøring — gjennom den kontrollerte operasjonen, aldri ved å slette
# historikk.
#
# ----------------------------------------------------------------------------
# Prøve 16 til 18 — den autonome kjøreren (migrasjon 011a)
#
# Fra 011a kan en planlagt KI-agent hente arbeid selv. «Det kjøres bare én
# planlagt oppgave om gangen» er ikke en garanti noen kan gi: en plattform kan
# starte to kjøringer, en kjøring kan henge og bli startet på nytt, og et
# menneske kan stå ved agentarbeidsflaten samtidig. Uttaket må derfor holde av
# seg selv, og det er nettopp det som ikke lar seg prøve i pgTAP: filene der
# kjører i én transaksjon som rulles tilbake, og en andre forbindelse ville verken
# sett fiksturen deres eller kunnet kappes mot dem.
#
#   16  To planlagte kjøringer kan ikke ta den samme oppgaven. Økt A tar uttaket
#       og holder transaksjonen åpen; økt B ber om nøyaktig den samme oppgaven
#       og skal få vite at den ikke kan tas nå, framfor å få den. Uten FOR
#       UPDATE SKIP LOCKED og lesningen av utførbarheten på nytt etter låsen,
#       ville begge fått den.
#
#   17  Den manuelle veien og den autonome kan ikke registrere det samme
#       arbeidet. Økt A tar uttaket og commiter; økt B laster opp et svar fra
#       agentarbeidsflaten og skal avvises av at oppgaven er tatt ut.
#
#   18  En utløpt leie kan tas på nytt, uten tapt eller dobbelt arbeid. Uttaket
#       får sin egen nøkkel, så den forrige kjøringen kan ikke levere et svar
#       over den som nå arbeider — og oppgaven blir ikke stående låst fordi en
#       planlagt kjøring døde.
#
# Fiksturen er egen (scripts/agent-runner-race-fixture.sql) og bygges opp på
# nytt hver kjøring: uttak teller forsøk, og en jobb som ble stående med
# oppbrukte forsøk, ville gjort neste kjøring grønn av feil grunn.
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

# Faste id-er for fiksturene prøve 4 og 5 bygger. De står her fordi prøve 1 til 3
# skal holde seg til radene migrasjonene seeder, og derfor må kunne se bort fra
# dem — også når prøvene kjøres om igjen mot den samme databasen.
prove_kilde='7a000000-0000-4000-8000-000000000001'
prove_versjon='7a000000-0000-4000-8000-000000000002'
prove_funn='7a000000-0000-4000-8000-000000000003'
prove_kilde5='7b000000-0000-4000-8000-000000000001'
prove_revisjon='7b000000-0000-4000-8000-000000000005'
prove_konto='7b000000-0000-4000-8000-0000000000a0'

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
# Build the explicit, idempotent, document-bound synthetic graph before any
# lock probe. The reset intentionally leaves the active clinical tables empty.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$(dirname "$0")/review-decision-race-fixture.sql"

# Prøve 1 — evidenssettet til en påstandsrevisjon (migrasjon 006f)
#
# Hver innsetting i knowledge.claim_evidence_links tar selv FOR UPDATE på
# revisjonen, i knowledge.reject_evidence_link_after_assessment(). Økt B må
# derfor vente. Uten låsen i kontrollen ville den ikke ventet i det hele tatt, og
# fått 23001 fra forseglingskontrollen som ligger *etter* låsen i den samme
# triggeren. 55P03 betyr «måtte vente», 23001 betyr «slapp forbi».
# ----------------------------------------------------------------------------
revisjon=$prove_revisjon
avtrykk=$(les "select knowledge.claim_evidence_set_digest('$revisjon')")
funn='7b000000-0000-4000-8000-000000000003'
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
  (id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference, representation,
   retrieved_by_actor_id, document_sha256, document_byte_size, document_media_type,
   text_extraction_tool, text_extraction_tool_version, text_extraction_arguments, text_extraction_transform)
select '$prove_versjon', '$prove_kilde', now(),
       'file:///syntetisk-samtidighetsprove.pdf', 'sha256:' || repeat('7', 64),
       'private://syntetisk-samtidighetsprove.pdf', 'full_text', a.id,
       'sha256:' || repeat('8', 64), 1024, 'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@1'
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

# ----------------------------------------------------------------------------
# Prøve 5 — den gjeldende *reviewbeslutningen* følger skrivingene, ikke klokka
#
# Samme form som prøve 4, på det stedet konsekvensen er alvorligst: en
# publiseringsgodkjenning. Økt A begynner først, økt B skriver `approved` og
# commiter, og A skriver `rejected` etterpå. A sin rad bærer da det eldste
# decided_at, fordi now() er transaksjonens starttidspunkt.
#
# Prøven krever at avvisningen — raden som faktisk ble skrevet sist — er den
# gjeldende i reviewerflaten.
#
# Publiseringsgatens halvdel av dette flyttet med migrasjon 009e: fra da leser
# G11 og G12 den forseglede kandidaten og sluttkontrollen, ikke en
# publication_approval. Den samme regelen, på det objektet som nå bærer den,
# prøves i prøve 11.
#
# Fiksturen er egen (scripts/review-decision-race-fixture.sql) og bygget slik at
# G1 til G10 holder. Uten det ville gaten stoppet på et tidligere vilkår, og
# prøven ville ikke sagt noe om hvilken beslutning som gjelder. Revisjonen er
# aldri publisert og leses ikke av noen flate.
#
# Begge skrivingene går gjennom den ekte skriveveien
# api.register_publication_approval(...), som `authenticated` med reviewerens
# egen brukerkonto — ikke ved direkte innsetting. Beslutningen skal komme dit den
# faktisk kommer fra.
# ----------------------------------------------------------------------------
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$(dirname "$0")/review-decision-race-fixture.sql"

prove_avtrykk=$(les "select knowledge.claim_evidence_set_digest('$prove_revisjon')")

if [ -z "$prove_avtrykk" ]; then
  printf 'Fikk ikke satt opp fiksturen for prøve 5. Kjør migrasjonene først (npm run db:reset).\n' >&2
  exit 1
fi

a5_log="$arbeid/a5.log"
styr5="$arbeid/styr5.$$"
rm -f "$styr5"
mkfifo "$styr5"

# Økt A begynner først, og fester bare transaksjonens klokke. Ingen lås tas:
# dette er ikke en låseprøve, men en prøve på hva «senere» betyr.
(
  printf "begin;\n"
  printf "select 1;\n"
  printf "\\\\echo A5_STARTET\n"
  cat "$styr5"
) | psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 > "$a5_log" 2>&1 &
okt_a_pid=$!
exec 9>"$styr5"

for i in $(seq 1 100); do
  grep -q 'A5_STARTET' "$a5_log" 2>/dev/null && break
  sleep 0.1
done
if ! grep -q 'A5_STARTET' "$a5_log" 2>/dev/null; then
  printf 'Økt A kom ikke i gang i prøve 5:\n' >&2
  cat "$a5_log" >&2
  exec 9>&-
  exit 1
fi

sleep 0.3

# Økt B godkjenner og commiter mens økt A står åpen.
if ! psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 >"$arbeid/b5.log" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$prove_konto"}', true);
set local role authenticated;
select api.register_publication_approval(
  '$prove_revisjon'::uuid, '$prove_avtrykk', 'approved',
  'Samtidighetsprøve: godkjenning skrevet av økt B, som begynte sist.');
reset role;
commit;
SQL
then
  printf 'Økt B fikk ikke registrert godkjenningen sin i prøve 5:\n' >&2
  cat "$arbeid/b5.log" >&2
  exec 9>&-
  exit 1
fi

# …og økt A avviser etterpå, med det eldre tidsstempelet.
cat >&9 <<SQL
select set_config('request.jwt.claims', '{"sub":"$prove_konto"}', true);
set local role authenticated;
select api.register_publication_approval(
  '$prove_revisjon'::uuid, '$prove_avtrykk', 'rejected',
  'Samtidighetsprøve: avvisning skrevet av økt A, som begynte først og skrev sist.');
reset role;

do \$p\$
declare
  v_a workflow.review_decisions;
  v_b workflow.review_decisions;
  v_gjeldende text;
begin
  select * into v_a from workflow.review_decisions
  where claim_revision_id = '$prove_revisjon'
  order by registration_ordinal desc limit 1;

  select * into v_b from workflow.review_decisions
  where claim_revision_id = '$prove_revisjon' and decision = 'approved'
  order by registration_ordinal desc limit 1;

  if v_a.decision <> 'rejected' then
    raise exception 'Raden med høyest registreringsnummer er ikke den økt A skrev.';
  end if;
  if not (v_a.decided_at < v_b.decided_at) then
    raise exception 'Forutsetningen mangler: økt A sin rad bærer ikke et eldre tidsstempel enn økt B sin.';
  end if;
  if not (v_a.registration_ordinal > v_b.registration_ordinal) then
    raise exception 'Raden som ble skrevet sist fikk ikke det høyeste registreringsnummeret.';
  end if;

  v_gjeldende := workflow.claim_review_history('$prove_revisjon')
                 ->> 'current_review_decision_id';
  if v_gjeldende is distinct from v_a.id::text then
    raise exception 'Den gjeldende beslutningen i reviewerflaten er ikke den som ble skrevet sist.';
  end if;
end
\$p\$;
\echo BESLUTNINGSREKKEFØLGE_BEVIST
rollback;
SQL

exec 9>&-
wait "$okt_a_pid" 2>/dev/null || true
okt_a_pid=""
rm -f "$styr5"

if grep -q 'BESLUTNINGSREKKEFØLGE_BEVIST' "$a5_log"; then
  printf 'ok       en avvisning skrevet sist er den gjeldende reviewbeslutningen\n'
else
  printf 'AVVIK    en avvisning skrevet sist er den gjeldende reviewbeslutningen\n' >&2
  printf '         Uten en registreringsrekkefølge kan et menneskes nei bære det eldste tidsstempelet, og forsvinne bak en godkjenning som ble skrevet før det (migrasjon 006i).\n' >&2
  printf '         Svaret fra økt A:\n' >&2
  sed 's/^/         /' "$a5_log" >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# Prøve 6 og 7 — fjerningsveien for påstandsartefakter (migrasjon 005ai)
#
# Fiksturen er bygget slik at fjerningen slipper gjennom hver kontroll: uten det
# ville kallet i økt A feilet, transaksjonen blitt avbrutt og låsen sluppet, og
# prøven ville målt ingenting.
# ----------------------------------------------------------------------------
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$(dirname "$0")/discard-claim-race-fixture.sql"

fjerning_konto='7c000000-0000-4000-8000-0000000000a0'
fjerning_aktor='7c000000-0000-4000-8000-0000000000a1'
fjerning_funn='7c000000-0000-4000-8000-000000000003'
fjerning_paastand='7c000000-0000-4000-8000-000000000004'

fjerning_laas="select set_config('request.jwt.claims', '{\"sub\":\"$fjerning_konto\"}', true);
select knowledge.discard_unpublished_claim_artifacts(
  array['$fjerning_paastand']::uuid[],
  'Samtidighetsprøve i scripts/db-lock-test.sh. Rulles tilbake.');"

proev 'en samtidig menneskelig evidenskontroll må vente på fjerningen (55P03)' \
  "$fjerning_laas" \
  "insert into workflow.evidence_verifications
     (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
      source_access, checked_fields, findings, rationale, verified_at)
   select e.id, e.created_by_actor_id, '$fjerning_aktor', 'needs_correction',
          'original_source', array['estimate']::workflow.evidence_check_field[],
          'Samtidighetsprøve.', 'Samtidighetsprøve: menneskelig kontroll.', now()
   from knowledge.evidence_items e where e.id = '$fjerning_funn';" \
  'Vakten leser workflow.evidence_verifications, og ingen fremmednøkkel peker fra den mot noe fjerningen sletter. Uten låsen kan en menneskelig kontroll commite etter at vakten leste «ingen», og fjerningen lykkes likevel (migrasjon 005ai).'

proev 'en samtidig reviewbeslutning må vente på fjerningen (55P03)' \
  "$fjerning_laas" \
  "insert into workflow.review_decisions
     (evidence_item_id, evidence_item_creator_actor_id, review_type, decision, rationale,
      reviewer_actor_id, reviewer_actor_type, decided_at)
   select e.id, e.created_by_actor_id, 'extraction_withdrawal', 'extraction_upheld',
          'Samtidighetsprøve: beslutning.', '$fjerning_aktor', 'human', now()
   from knowledge.evidence_items e where e.id = '$fjerning_funn';" \
  'Vakten leser workflow.review_decisions, og ingen fremmednøkkel peker fra den mot noe fjerningen sletter. Uten låsen kan en beslutning commite etter at vakten leste «ingen», og fjerningen lykkes likevel (migrasjon 005ai).'

# ----------------------------------------------------------------------------
# Prøve 8 til 11 — publiseringen, tilbaketrekkingen og rollbacken
#
# Fiksturen er egen (scripts/publication-race-fixture.sql) og har to fullt
# publiserbare revisjoner med hver sin forseglede kandidat og sin godkjente
# sluttkontroll, en fagperson med reviewer-mandat og en publisher med
# publisher-mandat. Se hodekommentaren i fiksturen for hvorfor den nullstiller
# publiseringshistorikken sin.
# ----------------------------------------------------------------------------
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$(dirname "$0")/publication-race-fixture.sql"

pub_paastand='7d000000-0000-4000-8000-000000000004'
pub_rev1='7d000000-0000-4000-8000-000000000005'
pub_rev2='7d000000-0000-4000-8000-000000000015'
pub_fagperson='7d000000-0000-4000-8000-0000000000a0'
pub_publisher_konto='7d000000-0000-4000-8000-0000000000b0'
pub_publisher_aktor='7d000000-0000-4000-8000-0000000000b1'

pub_kandidat1=$(les "select c.id from knowledge.candidates c where c.claim_revision_id = '$pub_rev1'")
pub_kandidat2=$(les "select c.id from knowledge.candidates c where c.claim_revision_id = '$pub_rev2'")
pub_avtrykk2=$(les "select c.candidate_digest from knowledge.candidates c where c.id = '$pub_kandidat2'")

if [ -z "$pub_kandidat1" ] || [ -z "$pub_kandidat2" ] || [ -z "$pub_avtrykk2" ]; then
  printf 'Fikk ikke satt opp fiksturen for publiseringsprøvene. Kjør migrasjonene først (npm run db:reset).\n' >&2
  exit 1
fi

pub_sesjon="select set_config('request.jwt.claims', '{\"sub\":\"$pub_publisher_konto\"}', true);"

# Utgangsverdien prøve 10 teller mot. Fiksturen trekker tilbake framfor å slette,
# så historikken vokser mellom kjøringer — og et fast tall ville vært riktig bare
# den første gangen.

# Prøve 8 — publiseringen holder radlåsen på påstanden
#
# knowledge.publish_claim_revision(...) tar FOR UPDATE på påstanden før den leser
# tilstanden og skriver hendelsen. En samtidig tilbaketrekking må derfor vente.
# Uten låsen ville de to lest den samme tilstanden, og historikken kunne fått to
# hendelser med samme forgjenger — eller pekeren og hendelsen kunne sagt hver sin
# ting om hva som er publisert nå.
proev 'en samtidig tilbaketrekking må vente på publiseringen (55P03)' \
  "$pub_sesjon
   select knowledge.publish_claim_revision('$pub_rev1', '$pub_publisher_aktor',
     'Samtidighetsprøve; rulles tilbake.');" \
  "$pub_sesjon
   select knowledge.withdraw_claim_publication('$pub_paastand', '$pub_publisher_aktor',
     'Samtidighetsprøve; rulles tilbake.');" \
  'Uten radlåsen på påstanden kan en publisering og en tilbaketrekking lese den samme tilstanden, og etterlate to gjeldende sannheter (migrasjon 009e).'

# Prøve 9 — sluttkontrollen holder radlåsen på kandidaten
#
# api.record_candidate_final_control(...) tar FOR UPDATE på kandidaten, og
# publiseringen tar FOR SHARE på den samme raden etter at påstanden er låst. En
# publisering kan derfor ikke skje mens en sluttkontroll pågår. Uten den låsen
# kunne en `rejected` commite i vinduet mellom gatens G12 og innsettingen av
# hendelsen, og publiseringen ville hvilt på en godkjenning som var gjort om.
proev 'en samtidig publisering må vente på sluttkontrollen (55P03)' \
  "select set_config('request.jwt.claims', '{\"sub\":\"$pub_fagperson\"}', true);
   set local role authenticated;
   select api.record_candidate_final_control('$pub_kandidat2', '$pub_avtrykk2', 'rejected',
     'Samtidighetsprøve; rulles tilbake.');
   reset role;" \
  "$pub_sesjon
   select knowledge.publish_claim_revision('$pub_rev2', '$pub_publisher_aktor',
     'Samtidighetsprøve; rulles tilbake.');" \
  'Uten kandidatlåsen kan en sluttkontroll commite mellom publiseringsgatens G12 og publiseringshendelsen, og publiseringen ville hvilt på en godkjenning som var gjort om (migrasjon 009e).'

# Prøve 10 — to publiseringer som ikke venter på hverandre gir én historikk
#
# Samme form som prøve 4 og 5: økt A begynner først, økt B publiserer og
# commiter, og A publiserer etterpå. A tar radlåsen på påstanden når den skriver,
# og leser da den nye tilstanden — så A sin hendelse blir en `replace` med B sin
# hendelse som forgjenger, ikke en andre `publish` fra den samme tilstanden.
#
# Prøven krever at kjeden har nøyaktig ett hode, at pekeren navngir hodets eget
# innhold, og at A faktisk skrev en `replace`. Uten radlåsen ville begge lest
# «ingenting er publisert», og den andre ville blitt avvist av
# publication_events_no_forked_history_key — historikken ville vært konsistent,
# men prøven her viser at den også blir *riktig*: den andre publiseringen venter,
# ser den nye tilstanden og registrerer den overgangen som faktisk skjedde.
pub_hendelser_for=$(les "select count(*) from knowledge.publication_events where claim_id = '$pub_paastand'")

a10_log="$arbeid/a10.log"
styr10="$arbeid/styr10.$$"
rm -f "$styr10"
mkfifo "$styr10"

(
  printf "begin;\n"
  printf "select 1;\n"
  printf "\\\\echo A10_STARTET\n"
  cat "$styr10"
) | psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 > "$a10_log" 2>&1 &
okt_a_pid=$!
exec 9>"$styr10"

for i in $(seq 1 100); do
  grep -q 'A10_STARTET' "$a10_log" 2>/dev/null && break
  sleep 0.1
done
if ! grep -q 'A10_STARTET' "$a10_log" 2>/dev/null; then
  printf 'Økt A kom ikke i gang i prøve 10:\n' >&2
  cat "$a10_log" >&2
  exec 9>&-
  exit 1
fi

sleep 0.3

if ! psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 >"$arbeid/b10.log" 2>&1 <<SQL
begin;
$pub_sesjon
select knowledge.publish_claim_revision('$pub_rev1', '$pub_publisher_aktor',
  'Samtidighetsprøve: publisert av økt B, som begynte sist.');
commit;
SQL
then
  printf 'Økt B fikk ikke publisert i prøve 10:\n' >&2
  cat "$arbeid/b10.log" >&2
  exec 9>&-
  exit 1
fi

cat >&9 <<SQL
$pub_sesjon
select knowledge.publish_claim_revision('$pub_rev2', '$pub_publisher_aktor',
  'Samtidighetsprøve: publisert av økt A, som begynte først og skrev sist.');

do \$p\$
declare
  v_hendelser integer;
  v_hoder integer;
  v_hode knowledge.publication_events;
  v_peker uuid;
  v_kandidatpeker uuid;
begin
  select count(*) into v_hendelser
  from knowledge.publication_events where claim_id = '$pub_paastand';
  if v_hendelser <> $pub_hendelser_for + 2 then
    raise exception 'To publiseringer ga % nye hendelser, ikke to.',
      v_hendelser - $pub_hendelser_for;
  end if;

  select count(*) into v_hoder
  from knowledge.publication_events e
  where e.claim_id = '$pub_paastand'
    and not exists (select 1 from knowledge.publication_events s
                    where s.previous_event_id = e.id);
  if v_hoder <> 1 then
    raise exception 'Historikken har % hoder: to samtidige publiseringer ga to gjeldende sannheter.', v_hoder;
  end if;

  v_hode := knowledge.publication_head_event('$pub_paastand');
  if v_hode.action <> 'replace' then
    raise exception 'Økt A skrev % og ikke replace: den så ikke tilstanden økt B commitet.', v_hode.action;
  end if;
  if v_hode.revision_id is distinct from '$pub_rev2'::uuid then
    raise exception 'Hodet i kjeden navngir ikke revisjonen økt A publiserte.';
  end if;

  select current_published_revision_id, current_published_candidate_id
    into v_peker, v_kandidatpeker
  from knowledge.claims where id = '$pub_paastand';
  if v_peker is distinct from v_hode.revision_id
     or v_kandidatpeker is distinct from v_hode.candidate_id then
    raise exception 'Publiseringspekeren og hodet i kjeden sier forskjellige ting.';
  end if;
end
\$p\$;
\echo PUBLISERINGSREKKEFØLGE_BEVIST
rollback;
SQL

exec 9>&-
wait "$okt_a_pid" 2>/dev/null || true
okt_a_pid=""
rm -f "$styr10"

if grep -q 'PUBLISERINGSREKKEFØLGE_BEVIST' "$a10_log"; then
  printf 'ok       to samtidige publiseringer gir én konsistent historikk\n'
else
  printf 'AVVIK    to samtidige publiseringer gir én konsistent historikk\n' >&2
  printf '         Uten radlåsen på påstanden kan to publiseringer lese den samme tilstanden, og etterlate en forgrenet historikk eller to gjeldende sannheter (migrasjon 009e).\n' >&2
  printf '         Svaret fra økt A:\n' >&2
  sed 's/^/         /' "$a10_log" >&2
  exit 1
fi

# Prøve 11 — den gjeldende *sluttkontrollen* følger skrivingene, ikke klokka
#
# Samme form, på det objektet publiseringsgaten faktisk leser fra migrasjon 009e:
# økt A begynner først, økt B godkjenner kandidaten og commiter, og A avviser
# etterpå. A sin rad bærer da det eldste decided_at, fordi now() er
# transaksjonens starttidspunkt.
#
# Prøven krever at avvisningen — raden som faktisk ble skrevet sist — er den
# gjeldende, og at publiseringsgaten stopper på den og ikke slipper gjennom
# godkjenningen som ble skrevet før den.
a11_log="$arbeid/a11.log"
styr11="$arbeid/styr11.$$"
rm -f "$styr11"
mkfifo "$styr11"

(
  printf "begin;\n"
  printf "select 1;\n"
  printf "\\\\echo A11_STARTET\n"
  cat "$styr11"
) | psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 > "$a11_log" 2>&1 &
okt_a_pid=$!
exec 9>"$styr11"

for i in $(seq 1 100); do
  grep -q 'A11_STARTET' "$a11_log" 2>/dev/null && break
  sleep 0.1
done
if ! grep -q 'A11_STARTET' "$a11_log" 2>/dev/null; then
  printf 'Økt A kom ikke i gang i prøve 11:\n' >&2
  cat "$a11_log" >&2
  exec 9>&-
  exit 1
fi

sleep 0.3

if ! psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 >"$arbeid/b11.log" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$pub_fagperson"}', true);
set local role authenticated;
select api.record_candidate_final_control('$pub_kandidat2', '$pub_avtrykk2', 'approved',
  'Samtidighetsprøve: godkjenning skrevet av økt B, som begynte sist.');
reset role;
commit;
SQL
then
  printf 'Økt B fikk ikke registrert sluttkontrollen sin i prøve 11:\n' >&2
  cat "$arbeid/b11.log" >&2
  exec 9>&-
  exit 1
fi

cat >&9 <<SQL
do \$p\$
begin
  perform knowledge.assert_claim_revision_publishable('$pub_rev2');
exception
  when others then
    raise exception 'Forutsetningen mangler: godkjenningen fra økt B gjør ikke revisjonen publiserbar (%). Prøven kan ikke vise at en avvisning blokkerer den.', sqlerrm;
end
\$p\$;

select set_config('request.jwt.claims', '{"sub":"$pub_fagperson"}', true);
set local role authenticated;
select api.record_candidate_final_control('$pub_kandidat2', '$pub_avtrykk2', 'rejected',
  'Samtidighetsprøve: avvisning skrevet av økt A, som begynte først og skrev sist.');
reset role;

do \$p\$
declare
  v_a workflow.candidate_final_controls;
  v_b workflow.candidate_final_controls;
  v_blokkert boolean := false;
begin
  v_a := workflow.current_candidate_final_control('$pub_kandidat2');

  select * into v_b from workflow.candidate_final_controls
  where candidate_id = '$pub_kandidat2' and decision = 'approved'
  order by registration_ordinal desc limit 1;

  if v_a.decision <> 'rejected' then
    raise exception 'Den gjeldende sluttkontrollen er ikke den økt A skrev.';
  end if;
  if not (v_a.decided_at < v_b.decided_at) then
    raise exception 'Forutsetningen mangler: økt A sin rad bærer ikke et eldre tidsstempel enn økt B sin.';
  end if;
  if not (v_a.registration_ordinal > v_b.registration_ordinal) then
    raise exception 'Raden som ble skrevet sist fikk ikke det høyeste registreringsnummeret.';
  end if;

  begin
    perform knowledge.assert_claim_revision_publishable('$pub_rev2');
  exception
    when restrict_violation then
      v_blokkert := true;
      if sqlerrm not like '%er rejected, ikke approved%' then
        raise exception 'Gaten blokkerte, men ikke på den gjeldende sluttkontrollen: %', sqlerrm;
      end if;
  end;
  if not v_blokkert then
    raise exception 'En avvisning skrevet sist blokkerte ikke publiseringen.';
  end if;
end
\$p\$;
\echo SLUTTKONTROLLREKKEFØLGE_BEVIST
rollback;
SQL

exec 9>&-
wait "$okt_a_pid" 2>/dev/null || true
okt_a_pid=""
rm -f "$styr11"

if grep -q 'SLUTTKONTROLLREKKEFØLGE_BEVIST' "$a11_log"; then
  printf 'ok       en avvisning skrevet sist er den gjeldende sluttkontrollen og blokkerer publisering\n'
else
  printf 'AVVIK    en avvisning skrevet sist er den gjeldende sluttkontrollen og blokkerer publisering\n' >&2
  printf '         Uten et registreringsnummer kan et menneskes nei bære det eldste tidsstempelet, og forsvinne bak en godkjenning som ble skrevet før det (migrasjon 009e).\n' >&2
  printf '         Svaret fra økt A:\n' >&2
  sed 's/^/         /' "$a11_log" >&2
  exit 1
fi

# Prøve 12 og 13 — grunnlaget under kandidaten står stille gjennom kontrollen
#
# Publiseringen og sluttkontrollen kontrollerer at innholdet fortsatt bygger til
# kandidatens avtrykk. Uten låser på det innholdet faktisk bygges av, ville den
# kontrollen vært et øyeblikksbilde: en ekstraksjonskontroll låser evidensfunnet
# og ikke kandidaten, og en kildestøttekontroll låste ingenting i det hele tatt,
# så begge kunne commite mellom regningen av avtrykket og skrivingen.
# knowledge.lock_candidate_inputs(uuid) og de tre triggerne fra migrasjon 009g
# lukker det, og prøvene her leser forskjellen.
pub_funn='7d000000-0000-4000-8000-000000000003'
pub_verifikator=$(les "select a.id from provenance.actors a where a.actor_key = 'agent:extraction-verification'")
pub_avtrykk1=$(les "select c.candidate_digest from knowledge.candidates c where c.id = '$pub_kandidat1'")

# Revisjon 2, fordi prøve 10 commitet publiseringen av revisjon 1: en publisering
# som ikke endrer noe er ikke en hendelse, og da ville økt A feilet før den rakk
# å ta noen lås.
proev 'en samtidig ekstraksjonskontroll må vente på publiseringen (55P03)' \
  "$pub_sesjon
   select knowledge.publish_claim_revision('$pub_rev2', '$pub_publisher_aktor',
     'Samtidighetsprøve; rulles tilbake.');" \
  "select workflow.record_evidence_verification(
     '$pub_funn', '$pub_verifikator', null,
     'uncertain', 'original_source', array['source_locator'],
     'Samtidighetsprøve; rulles tilbake.',
     'Samtidighetsprøve; kontrollen konkluderte ikke.');" \
  'Uten grunnlagslåsen kan en ekstraksjonskontroll commite mellom publiseringsgaten og hendelsen, og en kandidat som allerede er foreldet blir publisert som gjeldende (migrasjon 009g).'

proev 'en samtidig kildestøttekontroll må vente på sluttkontrollen (55P03)' \
  "select set_config('request.jwt.claims', '{\"sub\":\"$pub_fagperson\"}', true);
   set local role authenticated;
   select api.record_candidate_final_control('$pub_kandidat1', '$pub_avtrykk1', 'approved',
     'Samtidighetsprøve; rulles tilbake.');
   reset role;" \
  "insert into workflow.claim_verifications
     (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
      source_access, source_support, population_match, comparator_match, timeframe_match,
      direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
      rationale, verified_at)
   select r.id, r.created_by_actor_id, '7d000000-0000-4000-8000-0000000000a1',
          'uncertain', 'original_source', 'ok', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'ok',
          'Samtidighetsprøve; rulles tilbake.', now()
   from knowledge.claim_revisions r where r.id = '$pub_rev1';" \
  'Uten låsen på revisjonen kan en kildestøttekontroll commite mellom regningen av avtrykket og sluttkontrollen, og godkjenningen ville gjaldt et innhold som allerede var et annet (migrasjon 009g).'

# Prøve 14 og 15 — rollbacken holder de samme låsene som publiseringen
#
# Fra migrasjon 009h navngir en rollback et innhold og ikke en revisjon, og
# krever at nettopp den kandidaten fortsatt er det gjeldende innholdet. Den
# kontrollen er bare en garanti dersom grunnlaget under målrevisjonen står
# stille fra kontrollen til hendelsen: ellers kunne en kildestøttekontroll
# commite i vinduet, og rollbacken ville tatt i bruk et innhold som ikke lenger
# var det som lå der. Økt A publiserer først revisjon 2, slik at revisjon 1 blir
# et gyldig og eldre rollback-mål, og ruller deretter tilbake til kandidaten sin.
proev 'en samtidig kildestøttekontroll må vente på rollbacken (55P03)' \
  "$pub_sesjon
   select knowledge.publish_claim_revision('$pub_rev2', '$pub_publisher_aktor',
     'Samtidighetsprøve; rulles tilbake.');
   select knowledge.rollback_claim_publication('$pub_paastand', '$pub_kandidat1',
     '$pub_publisher_aktor', 'Samtidighetsprøve; rulles tilbake.');" \
  "insert into workflow.claim_verifications
     (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
      source_access, source_support, population_match, comparator_match, timeframe_match,
      direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
      rationale, verified_at)
   select r.id, r.created_by_actor_id, '7d000000-0000-4000-8000-0000000000a1',
          'uncertain', 'original_source', 'ok', 'not_assessable', 'ok', 'ok', 'ok', 'ok', 'ok',
          'Samtidighetsprøve; rulles tilbake.', now()
   from knowledge.claim_revisions r where r.id = '$pub_rev1';" \
  'Uten grunnlagslåsen på målrevisjonen kan en kildestøttekontroll commite mellom kontrollen av at kandidaten er den gjeldende og rollbackhendelsen, og rollbacken ville gjenopprettet et innhold som allerede var foreldet (migrasjon 009g, 009h).'

proev 'en samtidig tilbaketrekking må vente på rollbacken (55P03)' \
  "$pub_sesjon
   select knowledge.publish_claim_revision('$pub_rev2', '$pub_publisher_aktor',
     'Samtidighetsprøve; rulles tilbake.');
   select knowledge.rollback_claim_publication('$pub_paastand', '$pub_kandidat1',
     '$pub_publisher_aktor', 'Samtidighetsprøve; rulles tilbake.');" \
  "$pub_sesjon
   select knowledge.withdraw_claim_publication('$pub_paastand', '$pub_publisher_aktor',
     'Samtidighetsprøve; rulles tilbake.');" \
  'Uten radlåsen på påstanden kan en rollback og en tilbaketrekking lese den samme tilstanden, og etterlate to gjeldende sannheter (migrasjon 009e).'

# ----------------------------------------------------------------------------
# Prøve 16 til 18 — den autonome kjøreren
# ----------------------------------------------------------------------------
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$(dirname "$0")/agent-runner-race-fixture.sql"

kjorer_token='7e00000000000000000000000000000000000000000000000000000000000001'
kjorer_jobb='7e000000-0000-4000-8000-00000000000a'
kjorer_redaktor='7e000000-0000-4000-8000-0000000000e0'
# Begge øktene ber om NØYAKTIG denne oppgaven. «Gi meg arbeid» ville latt økt B
# få en annen jobb dersom databasen inneholder mer enn fiksturens egen, og
# prøven ville vært grønn uten å ha prøvd det den finnes for. Henvisningen er
# den modellen selv får: utledet av jobben og tilkoblingen, aldri en
# databaseidentitet.
kjorer_ref=$(les "select workflow.agent_runner_task_ref(
  '7e000000-0000-4000-8000-0000000000c1'::uuid, '$kjorer_jobb'::uuid)")

# Økt A tar uttaket og HOLDER transaksjonen åpen. Økt B spør om arbeid mens
# raden er låst, og skal få «ingen arbeid» — ikke den samme jobben.
kapp_om_uttaket() {
  local styr="$arbeid/styr-runner.$$" a_log="$arbeid/a-runner.log" b_log="$arbeid/b-runner.log"

  rm -f "$styr"
  mkfifo "$styr"

  (
    printf "begin;\n"
    printf "select api.claim_agent_task('%s', '%s', 900);\n" "$kjorer_token" "$kjorer_ref"
    printf "\\\\echo TATT\n"
    printf "\\\\o /dev/null\n"
    cat "$styr"
    printf "rollback;\n"
  ) | psql "$DB_URL" -X -v ON_ERROR_STOP=1 > "$a_log" 2>&1 &
  okt_a_pid=$!
  exec 9>"$styr"

  local i
  for i in $(seq 1 100); do
    grep -q 'TATT' "$a_log" 2>/dev/null && break
    sleep 0.1
  done
  if ! grep -q 'TATT' "$a_log" 2>/dev/null; then
    printf 'Økt A fikk ikke tatt uttaket:\n' >&2
    cat "$a_log" >&2
    exec 9>&-
    exit 1
  fi

  set +e
  psql "$DB_URL" -X -tA > "$b_log" 2>&1 <<SQL
set lock_timeout = '2s';
select api.claim_agent_task('$kjorer_token', '$kjorer_ref', 900);
SQL
  set -e

  printf 'exit\n' >&9 || true
  exec 9>&-
  wait "$okt_a_pid" 2>/dev/null || true
  okt_a_pid=""
  rm -f "$styr"

  if grep -q '"claimed": false' "$b_log" && grep -q '"reason": "stale_task"' "$b_log"; then
    printf 'ok       to planlagte kjøringer kan ikke ta den samme oppgaven\n'
    return 0
  fi

  printf 'AVVIK    to planlagte kjøringer kan ikke ta den samme oppgaven\n' >&2
  printf '         Uten FOR UPDATE SKIP LOCKED og lesningen av utførbarheten etter låsen ville begge fått den samme jobben (migrasjon 011a).\n' >&2
  printf '         Svaret fra økt B:\n' >&2
  sed 's/^/         /' "$b_log" >&2
  exit 1
}

kapp_om_uttaket

# Prøve 17 — økt A commiter uttaket, og den manuelle importveien avvises.
handle=$(les "select api.claim_agent_task('$kjorer_token', '$kjorer_ref', 900) ->> 'task_handle'")
if [ -z "$handle" ]; then
  printf 'AVVIK    kjøreren fikk ikke tatt oppgaven etter at prøve 16 rullet tilbake\n' >&2
  exit 1
fi

manuell_log="$arbeid/manuell.log"
set +e
psql "$DB_URL" -X -tA > "$manuell_log" 2>&1 <<SQL
\set VERBOSITY verbose
begin;
select set_config('request.jwt.claims', '{"sub":"$kjorer_redaktor"}', true);
set local role authenticated;
select api.import_agent_answer('$kjorer_jobb', '{}'::jsonb);
rollback;
SQL
set -e

if grep -q '23001' "$manuell_log"; then
  printf 'ok       den manuelle importen kan ikke registrere en oppgave en kjører holder\n'
else
  printf 'AVVIK    den manuelle importen kan ikke registrere en oppgave en kjører holder\n' >&2
  printf '         Uten den delte leien kunne det samme arbeidet blitt registrert to ganger, i to modellidentiteter (migrasjon 011a).\n' >&2
  sed 's/^/         /' "$manuell_log" >&2
  exit 1
fi

# Prøve 18 — en utløpt leie er ledig igjen, og den forrige nøkkelen treffer
# ingenting. Tiden flyttes framfor å ventes ut: prøven skal si noe om regelen,
# ikke om klokka.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -c \
  "update workflow.pipeline_jobs
   set lease_expires_at = now() - interval '1 minute'
   where id = '$kjorer_jobb'" > /dev/null

nytt_handle=$(les "select api.claim_agent_task('$kjorer_token', '$kjorer_ref', 900) ->> 'task_handle'")
if [ -z "$nytt_handle" ] || [ "$nytt_handle" = "$handle" ]; then
  printf 'AVVIK    en utløpt leie kan tas på nytt med en ny nøkkel\n' >&2
  printf '         Uttaket fikk ikke sin egen nøkkel, og en kjøring som mistet leien kunne skrevet over den som nå arbeider (DATABASE_ARCHITECTURE.md §33).\n' >&2
  exit 1
fi
printf 'ok       en utløpt leie kan tas på nytt, og uttaket får sin egen nøkkel\n'

foreldet=$(les "select api.submit_agent_answer('$kjorer_token', '$handle'::uuid, '{}'::jsonb) ->> 'reason'")
if [ "$foreldet" = "stale_task" ]; then
  printf 'ok       en kjøring med utløpt leie kan ikke levere over uttaket som nå arbeider\n'
else
  printf 'AVVIK    en kjøring med utløpt leie kan ikke levere over uttaket som nå arbeider\n' >&2
  printf '         Svaret var: %s\n' "$foreldet" >&2
  exit 1
fi

# Oppgaven gis fra seg igjen, slik at databasen ikke blir stående med en leie
# fra en prøve som er ferdig.
les "select api.release_agent_task('$kjorer_token', '$nytt_handle'::uuid, 'could_not_complete')" > /dev/null

# Prøve 19 — taket på klientregistreringen er én avgjørelse om gangen
#
# /oauth/register må være åpen: RFC 7591 dynamisk klientregistrering er det
# ChatGPT bruker for å koble seg til i det hele tatt. Taket per time er da den
# eneste grensen, og en grense som leses og skrives i to trinn uten en lås, er
# ingen grense: samtidige registreringer leser hver sin tilstand fra før de
# andre commitet, finner alle færre enn taket og slipper alle gjennom.
#
# Låsen er transaksjonslokal. Økt A holder den mens den er inne i funksjonen;
# økt B må vente, og med lock_timeout blir ventingen synlig som 55P03.
proev 'en samtidig klientregistrering må vente på den som teller først (55P03)' \
  "select api.register_agent_runner_client('Samtidig A', array['https://samtidig.example/cb']);" \
  "select api.register_agent_runner_client('Samtidig B', array['https://samtidig.example/cb']);" \
  'Uten låsen er taket per time en grense som ikke holder nettopp i det tilfellet den finnes for: en flom av samtidige registreringer (migrasjon 011a).'

printf '\nAlle samtidighetsprøvene passerte.\n'
