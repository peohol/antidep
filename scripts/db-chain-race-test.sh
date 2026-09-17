#!/usr/bin/env bash
#
# Samtidighetsprøver: de to stedene kjeden «finner eller oppretter»
#
#   ./scripts/db-chain-race-test.sh                  # mot den lokale stacken
#   ./scripts/db-chain-race-test.sh --db-url <url>   # mot en annen database
#
# ----------------------------------------------------------------------------
# Hvorfor dette ikke er pgTAP-filer
#
# pgTAP-filene kjører i én transaksjon som rulles tilbake, og en annen
# forbindelse ville verken sett fiksturen deres eller kunnet kappes mot dem. Det
# som prøves her, skjer nettopp *mellom* to transaksjoner, og må derfor være to
# reelle forbindelser. Samme grunn som i scripts/db-lock-test.sh, og filen
# følger den samme formen.
#
# ----------------------------------------------------------------------------
# Hva den prøver
#
# Migrasjon 012b og 012c har hver sin «les, og skriv hvis det ikke finnes».
# Begge er kappløp uten en lås, og ingen av dem fanges av et unikhetskrav —
# fordi det som skrives, ikke er likt nok til å kollidere:
#
#   1. Synteseoppgaven. To kontroller av *forskjellige* funn på det samme
#      virkestoffet og endepunktet kan begge lese «ingen oppgave» og legge inn
#      hver sin. Nøklene blir forskjellige, fordi evidenssettet manifestet bygges
#      av, er forskjellig — så unikhetskravet på (agent_role, job_key) ser to
#      lovlige rader. Resultatet ville vært to semantisk like oppgaver, som er
#      nøyaktig det ledd 2 i issue #101 ikke skal kunne skje.
#      Låsen er workflow.lock_chain_subject(provenance.agent_role, text).
#
#   2. Kilden bak en fulltekstbestilling. To bestillinger av den samme DOI-en
#      kan begge lese «finnes ikke» og begge opprette en kilde. Unikhetskravet
#      på DOI-en fanger den andre identifikatoren, men uten en lås — og uten at
#      kilden og identifikatoren settes inn i den samme underblokken — blir
#      taperens kilderad stående uten identifikator: en artikkel ingenting peker
#      på, som neste bestilling av den samme artikkelen ikke finner igjen.
#
# Hver prøve kjører to økter mot hverandre:
#
#   Økt A   begynner en transaksjon og gjør sin halvdel. Låsen holdes.
#   Økt B   gjør den samme halvdelen samtidig, og skal blokkere.
#   Økt A   commiter. Økt B våkner, ser hva A gjorde, og gjør det ikke om igjen.
#
# Prøven slår fast begge deler: at økt B faktisk ventet (uten ventingen måler
# den bare rekkefølgen på to prosesser), og at tilstanden etterpå er én rad og
# ikke to.
#
# ----------------------------------------------------------------------------
# Radene den legger igjen
#
# Fiksturen er ny for hver kjøring, med id-er laget der og da. Det er med vilje:
# en gjenbrukt fikstur ville hatt oppgaven fra forrige kjøring liggende, og
# begge øktene ville hoppet over — prøven ville bestått uten å ha prøvd noe.
# Radene er syntetiske, upubliserte og lenket til ingenting.
#
# Bestillingen prøve 2 legger inn, trekkes tilbake igjen til slutt gjennom
# produktets egen vei: en åpen fulltekstbestilling ville ellers blitt stående i
# den åpne arbeidsoversikten etter kjøringen, og talt med av enhver senere prøve
# som leser hele oversikten.
#
# Kjøres av CI. Hører til teknisk drift, aldri til en brukerflate.
set -uo pipefail
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

if [ -z "$DB_URL" ]; then
  printf 'Fant ingen databaseadresse. Start den lokale stacken (npm run db:start), eller oppgi --db-url.\n' >&2
  exit 1
fi

arbeid=$(mktemp -d)
okt_a_pid=""
okt_b_pid=""
trap 'rm -rf "$arbeid"
      [ -n "$okt_a_pid" ] && kill "$okt_a_pid" 2>/dev/null
      [ -n "$okt_b_pid" ] && kill "$okt_b_pid" 2>/dev/null
      true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

nyid() { node -e 'process.stdout.write(crypto.randomUUID())'; }
les() { psql "$DB_URL" -tAXq -c "$1"; }

# Id-ene denne kjøringen eier. Ingen annen kjøring og ingen seedet rad deler dem.
kjoring=$(nyid)
kilde=$(nyid)
versjon=$(nyid)
endepunkt=$(nyid)
funn_a=$(nyid)
funn_b=$(nyid)
kjoring_a=$(nyid)
kjoring_b=$(nyid)
bruker=$(nyid)
aktor=$(nyid)
doi="10.9999/antidep.kapplop.${kjoring:0:8}"

# ----------------------------------------------------------------------------
# Venter til én forbindelse faktisk står og venter på en rådgivende lås.
#
# Uten denne kunne økt A commitet før økt B var kommet fram til låsen, og
# prøven ville målt rekkefølgen på to prosesser framfor låsen.
# ----------------------------------------------------------------------------
vent_paa_blokkering() {
  local navn=$1 i
  for i in $(seq 1 150); do
    if [ "$(les "select count(*) from pg_locks where locktype = 'advisory' and not granted")" != "0" ]; then
      return 0
    fi
    sleep 0.1
  done
  printf 'AVVIK    %s\n' "$navn" >&2
  printf '         Økt B ventet ikke på noen lås. Da er «finn eller opprett» ikke udelelig,\n' >&2
  printf '         og to samtidige kall kan begge skrive.\n' >&2
  exit 1
}

feil() {
  printf 'AVVIK    %s\n' "$1" >&2
  printf '         %s\n' "$2" >&2
  [ -n "${3:-}" ] && [ -s "${3:-}" ] && sed 's/^/         /' "$3" >&2
  exit 1
}

# ============================================================================
# Fiksturen: en artikkel med fulltekst, og to funn på det samme subjektet
# ============================================================================
if ! psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 > "$arbeid/fikstur.log" 2>&1 <<SQL
-- Dokumentet er ekte bytes: fra migrasjon 009a *er* avtrykket bytene, og
-- fullteksten må ligge i det private biblioteket, bundet til publikasjonen og
-- lesbarhetskontrollert. Fiksturen får ekte bytes framfor at porten mykes opp.
create temporary table kapplop_pdf as
select convert_to('%PDF-1.7' || E'\nkapplopsprove\n%%EOF\n', 'UTF8') as bytes;

insert into catalog.clinical_concepts (id, canonical_label, concept_type)
values ('$endepunkt', 'søvnkvalitet i kappløpsprøven ${kjoring:0:8}', 'outcome');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
select '$kilde', 'journal_article', 'Kappløpsprøve ${kjoring:0:8}',
       'scripts/db-chain-race-test.sh', a.id
from provenance.actors a where a.actor_key = 'human:peder-holman';

insert into knowledge.source_documents
  (sha256, byte_size, media_type, content, stored_by_actor_id)
select knowledge.source_document_fingerprint(g.bytes), octet_length(g.bytes),
       'application/pdf', g.bytes, a.id
from kapplop_pdf g
join provenance.actors a on a.actor_key = 'human:peder-holman'
on conflict (sha256) do nothing;

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference,
   representation, retrieved_by_actor_id, document_sha256, document_byte_size,
   document_media_type, text_extraction_tool, text_extraction_tool_version,
   text_extraction_arguments, text_extraction_transform)
select '$versjon', '$kilde', now(), 'file:///kapplopsprove-${kjoring:0:8}.pdf',
       knowledge.source_version_content_hash('Syntetisk kildetekst for kappløpsprøven.'),
       'private://kapplopsprove-${kjoring:0:8}.pdf', 'full_text', a.id,
       knowledge.source_document_fingerprint(g.bytes), octet_length(g.bytes),
       'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from provenance.actors a
cross join kapplop_pdf g
where a.actor_key = 'agent:evidence-extraction';

insert into knowledge.source_document_publications
  (source_document_id, source_id, binding_basis, binding_evidence, bound_by_actor_id)
select d.id, sv.source_id, 'title', 'syntetisk binding for kappløpsprøven',
       sv.retrieved_by_actor_id
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = '$versjon'
on conflict on constraint source_document_publications_pairing_key do nothing;

insert into knowledge.full_text_readability_checks
  (source_version_id, source_document_id, character_count, letter_count,
   line_count, table_row_count, table_declaration_count)
select sv.id, d.id, 20000, 15000, 400, 12, 3
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = '$versjon';

-- To funn på det samme virkestoffet og det samme endepunktet. Endepunktet er
-- nytt, så ingen påstand finnes for paret ennå — og uten den forutsetningen
-- ville kjeden hoppet over synteseleddet, og prøven prøvd ingenting.
insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_id,
  population_availability, population_detail, sample_size_availability,
  intervention_drug_id, comparator_kind, outcome_concept_id, outcome_detail,
  timepoint_availability, reported_direction, estimate_availability,
  confidence_interval_availability, source_locator, extraction_method,
  created_by_actor_id
)
select f.id, '$kilde', '$versjon', 'randomized_controlled_trial',
       p.id, 'reported_value', f.detalj, 'not_reported',
       d.id, 'none', '$endepunkt', f.detalj,
       'not_reported', 'decrease', 'not_reported', 'not_reported',
       f.peker, 'ai_assisted', a.id
from (values ('$funn_a'::uuid, 'Kappløpsprøven, funn A.', 'Avsnitt 1'),
             ('$funn_b'::uuid, 'Kappløpsprøven, funn B.', 'Avsnitt 2'))
       as f(id, detalj, peker)
cross join catalog.drugs d
cross join catalog.populations p
cross join provenance.actors a
where d.canonical_name = 'sertralin'
  and p.canonical_label = 'voksne med depressiv lidelse'
  and a.actor_key = 'agent:evidence-extraction';

-- Den kildeomfattende halvdelen av et globalt fravær kan bare føres opp av en
-- maskinell kontroll med sin egen kjøring (migrasjon 005ae). Hver økt trenger
-- derfor sin egen.
insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select r.id, ai.id, ai.actor_id, 'extraction_verification', 'antidep',
       'deterministic-extraction-check', '1.0.0',
       'extraction-verification/deterministic/1', 'antidep-evidence/1',
       jsonb_build_object('mode', 'race-probe')
from (values ('$kjoring_a'::uuid), ('$kjoring_b'::uuid)) as r(id)
cross join provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';

-- Redaktøren prøve 2 bestiller som.
insert into auth.users (id, instance_id, aud, role, email)
values ('$bruker', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'kapplop-${kjoring:0:8}@antidep.test');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values ('$aktor', 'human', 'human:kapplop-${kjoring:0:8}',
        'Redaktør i kappløpsprøven',
        'Aktør med gyldig editor-tildeling, for scripts/db-chain-race-test.sh.',
        '$bruker');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('$bruker', 'editor', null, now() - interval '1 year', '$aktor',
        'Gyldig editor-tildeling for kappløpsprøven.');
SQL
then
  feil 'fiksturen' 'Fiksturen lot seg ikke bygge.' "$arbeid/fikstur.log"
fi

# ============================================================================
# Prøve 1 — to beståtte kontroller på det samme subjektet gir én synteseoppgave
# ============================================================================
proeve1() {
  local navn='synteseoppgaven kan ikke legges inn to ganger'
  local styr="$arbeid/styr1" sql_b="$arbeid/b1.sql"
  local a_log="$arbeid/a1.log" b_log="$arbeid/b1.log"

  # Den samme halvdelen, én gang per funn. Kontrollen føres i to rader, fordi
  # den kildeomfattende halvdelen har sitt eget krav (migrasjon 005ae).
  kontroll_sql() {
    cat <<SQL
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at, agent_run_id)
select e.id, e.created_by_actor_id, a.id, 'verified', 'verifiable_representation',
       array['source_wide_absence']::workflow.evidence_check_field[],
       'Kappløpsprøven: et søk gjennom hele representasjonen fant ingen verdi.',
       now() - interval '1 hour', '$2'
from knowledge.evidence_items e
cross join provenance.actors a
where e.id = '$1' and a.actor_key = 'agent:extraction-verification'
  and 'source_wide_absence' = any (workflow.required_check_fields(e.id));

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, a.id, 'verified', 'verifiable_representation',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Kappløpsprøven: fullstendig kontrollert ekstraksjon.', now()
from knowledge.evidence_items e
cross join provenance.actors a
where e.id = '$1' and a.actor_key = 'agent:extraction-verification';
SQL
  }

  rm -f "$styr"
  mkfifo "$styr"

  {
    printf 'begin;\n'
    kontroll_sql "$funn_b" "$kjoring_b"
    printf 'commit;\n'
  } > "$sql_b"

  # Økt A mates fra et rør og ikke fra en fil: den siste setningen — commit —
  # skal først bli til når prøven vet at økt B står og venter.
  (
    printf 'begin;\n'
    kontroll_sql "$funn_a" "$kjoring_a"
    printf '\\echo KLAR\n'
    printf '\\o /dev/null\n'
    cat "$styr"
  ) | psql "$DB_URL" -X -v ON_ERROR_STOP=1 > "$a_log" 2>&1 &
  okt_a_pid=$!
  exec 9>"$styr"

  local i
  for i in $(seq 1 150); do
    grep -q 'KLAR' "$a_log" 2>/dev/null && break
    sleep 0.1
  done
  grep -q 'KLAR' "$a_log" 2>/dev/null || feil "$navn" 'Økt A kom ikke i gang.' "$a_log"

  psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$sql_b" > "$b_log" 2>&1 &
  okt_b_pid=$!

  vent_paa_blokkering "$navn"

  printf 'commit;\n' >&9
  exec 9>&-
  wait "$okt_a_pid" 2>/dev/null; local a_status=$?
  okt_a_pid=""
  wait "$okt_b_pid" 2>/dev/null; local b_status=$?
  okt_b_pid=""
  rm -f "$styr"

  [ "$a_status" -eq 0 ] || feil "$navn" 'Økt A kom ikke gjennom.' "$a_log"
  [ "$b_status" -eq 0 ] || feil "$navn" 'Økt B kom ikke gjennom.' "$b_log"

  local antall
  antall=$(les "select count(*) from workflow.pipeline_jobs
                where agent_role = 'claim_synthesis'
                  and input_manifest ->> 'topic_concept_id' = '$endepunkt'")
  [ "$antall" = "1" ] || feil "$navn" \
    "Køen har $antall synteseoppgaver om det samme subjektet. Den skal ha nøyaktig én."

  # Og begge kontrollene står der de skal: det som ble hindret, er den doble
  # oppgaven — ikke det kliniske arbeidet.
  local kontroller
  kontroller=$(les "select count(distinct evidence_item_id) from workflow.evidence_verifications
                    where evidence_item_id in ('$funn_a', '$funn_b') and outcome = 'verified'")
  [ "$kontroller" = "2" ] || feil "$navn" \
    "Bare $kontroller av de to kontrollene ble registrert. Låsen skal utsette, aldri forkaste."

  printf 'ok       %s\n' "$navn"
}

# ============================================================================
# Prøve 2 — to bestillinger av den samme DOI-en gir én kilde, uten en taperrad
# ============================================================================
proeve2() {
  local navn='den samme artikkelen bestilt to ganger blir én kilde'
  local styr="$arbeid/styr2" sql_b="$arbeid/b2.sql"
  local a_log="$arbeid/a2.log" b_log="$arbeid/b2.log"

  bestilling_sql() {
    cat <<SQL
select set_config('request.jwt.claims', '{"sub":"$bruker"}', true);
set local role authenticated;
select api.request_missing_full_text(
  '$doi', 'Kappløpsartikkelen ${kjoring:0:8}', 'Testforfatter m.fl.',
  array['sertralin'], array['vektendring'],
  array['voksne med depressiv lidelse'], 'Journal of Synthetic Trials', 2019);
SQL
  }

  rm -f "$styr"
  mkfifo "$styr"

  {
    printf 'begin;\n'
    bestilling_sql
    printf 'commit;\n'
  } > "$sql_b"

  (
    printf 'begin;\n'
    bestilling_sql
    printf '\\echo KLAR\n'
    printf '\\o /dev/null\n'
    cat "$styr"
  ) | psql "$DB_URL" -X -v ON_ERROR_STOP=1 > "$a_log" 2>&1 &
  okt_a_pid=$!
  exec 9>"$styr"

  local i
  for i in $(seq 1 150); do
    grep -q 'KLAR' "$a_log" 2>/dev/null && break
    sleep 0.1
  done
  grep -q 'KLAR' "$a_log" 2>/dev/null || feil "$navn" 'Økt A kom ikke i gang.' "$a_log"

  psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$sql_b" > "$b_log" 2>&1 &
  okt_b_pid=$!

  vent_paa_blokkering "$navn"

  printf 'commit;\n' >&9
  exec 9>&-
  wait "$okt_a_pid" 2>/dev/null; local a_status=$?
  okt_a_pid=""
  wait "$okt_b_pid" 2>/dev/null; local b_status=$?
  okt_b_pid=""
  rm -f "$styr"

  [ "$a_status" -eq 0 ] || feil "$navn" 'Økt A kom ikke gjennom.' "$a_log"
  [ "$b_status" -eq 0 ] || feil "$navn" 'Økt B kom ikke gjennom.' "$b_log"

  local kilder identifikatorer forespoersler
  kilder=$(les "select count(*) from knowledge.sources
                where title = 'Kappløpsartikkelen ${kjoring:0:8}'")
  [ "$kilder" = "1" ] || feil "$navn" \
    "Artikkelen ble registrert $kilder ganger. Den skal være én kilde."

  identifikatorer=$(les "select count(*) from knowledge.source_identifiers
                         where identifier_system = 'doi' and identifier_value = '$doi'")
  [ "$identifikatorer" = "1" ] || feil "$navn" \
    "DOI-en står på $identifikatorer rader."

  # Det er dette en lås alene ikke ville dekket: en kilde uten identifikator er
  # en artikkel ingenting peker på, og neste bestilling av den samme artikkelen
  # ville ikke funnet den igjen.
  local foreldreloese
  foreldreloese=$(les "select count(*) from knowledge.sources s
                       where s.title = 'Kappløpsartikkelen ${kjoring:0:8}'
                         and not exists (select 1 from knowledge.source_identifiers i
                                         where i.source_id = s.id)")
  [ "$foreldreloese" = "0" ] || feil "$navn" \
    "$foreldreloese kilderad(er) står igjen uten identifikator."

  forespoersler=$(les "select count(*) from workflow.full_text_requests r
                       join knowledge.sources s on s.id = r.source_id
                       where s.title = 'Kappløpsartikkelen ${kjoring:0:8}'")
  [ "$forespoersler" = "1" ] || feil "$navn" \
    "Ventelisten har $forespoersler rader for artikkelen. Den skal ha én."

  # Og til slutt: bestillingen trekkes tilbake igjen.
  #
  # Prøven har lagt en ekte, åpen fulltekstbestilling i den åpne oversikten, og
  # den ville blitt stående der etter kjøringen — synlig for alle, og talt med av
  # enhver senere prøve som leser hele oversikten. Tilbaketrekkingen går gjennom
  # produktets egen vei, med det samme redaktørmandatet bestillingen ble gjort
  # med, framfor å slette rader utenom skriveveiene.
  local referanse
  referanse=$(les "select r.reference from workflow.full_text_requests r
                   join knowledge.sources s on s.id = r.source_id
                   where s.title = 'Kappløpsartikkelen ${kjoring:0:8}'")
  if ! psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 > "$arbeid/rydd.log" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$bruker"}', true);
set local role authenticated;
select api.withdraw_full_text_request(
  '$referanse', 'Opprydning etter samtidighetsprøven i scripts/db-chain-race-test.sh.');
commit;
SQL
  then
    feil "$navn" 'Bestillingen lot seg ikke trekke tilbake etterpå.' "$arbeid/rydd.log"
  fi

  local aapne
  aapne=$(les "select count(*) from workflow.full_text_requests r
               join knowledge.sources s on s.id = r.source_id
               where s.title = 'Kappløpsartikkelen ${kjoring:0:8}' and r.state = 'open'")
  [ "$aapne" = "0" ] || feil "$navn" \
    'Prøven etterlot en åpen bestilling i den åpne arbeidsoversikten.'

  printf 'ok       %s\n' "$navn"
}

printf 'Samtidighetsprøver for de automatiske kjedeovergangene\n'
proeve1
proeve2
printf 'Begge prøvene bestod.\n'
