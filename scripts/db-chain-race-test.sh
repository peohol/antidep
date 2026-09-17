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
#   3b. Fjerningen av et evidensfunn mot den redaksjonelle beslutningen. De to
#      tar de samme to låsene, og beslutningen tar subjektlåsen først. Tok
#      fjerningen tabellåsene først, ville de gått i hver sin retning gjennom
#      dem, og Postgres måtte brutt vranglåsen ved å avbryte den ene. Prøven
#      måler ikke bare at fjerningen venter, men at den som holder subjektlåsen,
#      fortsatt kan lese evidenstabellen mens den venter.
#
#   3. Den redaksjonelle revisjonsoppgaven (migrasjon 012d). To kontroller av
#      forskjellige funn på et par som allerede har en påstand, kan begge lese
#      «ingen oppgave» og begge forsøke å opprette den — og taperen ville feilet
#      på unikhetskravet midt i en registrering som ellers lyktes. Og
#      beslutningen selv er et kappløp av den andre typen: grunnlaget kan endre
#      seg mens den står på skjermen, og en beslutning gjennomført på et annet
#      grunnlag enn det som ble lest, ville vært en avgjørelse om noe ingen så
#      (ANTIDEP_CONSTITUTION.md regel 5).
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
endepunkt2=$(nyid)
funn_c=$(nyid)
kjoring_c=$(nyid)
endepunkt3=$(nyid)
paastand=$(nyid)
revisjon=$(nyid)
funn_base=$(nyid)
funn_d=$(nyid)
funn_e=$(nyid)
funn_f=$(nyid)
kjoring_d=$(nyid)
kjoring_e=$(nyid)
kjoring_f=$(nyid)
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

-- ----------------------------------------------------------------------------
-- Prøve 3 trenger et subjekt til: ett som er ferdig kontrollert, men som ennå
-- ikke har fått synteseoppgaven sin.
--
-- Triggeren legger den inn med det samme, så den eneste måten å framkalle
-- tilstanden på er å fjerne jobben etterpå — nøyaktig som
-- supabase/tests/810_chain_transitions_test.sql gjør når den etterligner en
-- tapt forbindelse.
-- ----------------------------------------------------------------------------
insert into catalog.clinical_concepts (id, canonical_label, concept_type)
values ('$endepunkt2', 'våkenhet i kappløpsprøven ${kjoring:0:8}', 'outcome');

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_id,
  population_availability, population_detail, sample_size_availability,
  intervention_drug_id, comparator_kind, outcome_concept_id, outcome_detail,
  timepoint_availability, reported_direction, estimate_availability,
  confidence_interval_availability, source_locator, extraction_method,
  created_by_actor_id
)
select '$funn_c', '$kilde', '$versjon', 'randomized_controlled_trial',
       p.id, 'reported_value', 'Kappløpsprøven, funn C.', 'not_reported',
       d.id, 'none', '$endepunkt2', 'Kappløpsprøven, funn C.',
       'not_reported', 'decrease', 'not_reported', 'not_reported',
       'Avsnitt 3', 'ai_assisted', a.id
from catalog.drugs d
cross join catalog.populations p
cross join provenance.actors a
where d.canonical_name = 'sertralin'
  and p.canonical_label = 'voksne med depressiv lidelse'
  and a.actor_key = 'agent:evidence-extraction';

insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '$kjoring_c', ai.id, ai.actor_id, 'extraction_verification', 'antidep',
       'deterministic-extraction-check', '1.0.0',
       'extraction-verification/deterministic/1', 'antidep-evidence/1',
       jsonb_build_object('mode', 'race-probe')
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at, agent_run_id)
select e.id, e.created_by_actor_id, a.id, 'verified', 'verifiable_representation',
       array['source_wide_absence']::workflow.evidence_check_field[],
       'Kappløpsprøven: et søk gjennom hele representasjonen fant ingen verdi.',
       now() - interval '1 hour', '$kjoring_c'
from knowledge.evidence_items e
cross join provenance.actors a
where e.id = '$funn_c' and a.actor_key = 'agent:extraction-verification'
  and 'source_wide_absence' = any (workflow.required_check_fields(e.id));

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, a.id, 'verified', 'verifiable_representation',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Kappløpsprøven: fullstendig kontrollert ekstraksjon, funn C.', now()
from knowledge.evidence_items e
cross join provenance.actors a
where e.id = '$funn_c' and a.actor_key = 'agent:extraction-verification';

set session_replication_role = replica;
delete from workflow.pipeline_job_events ev
where ev.pipeline_job_id in (
  select j.id from workflow.pipeline_jobs j
  where j.agent_role = 'claim_synthesis'
    and j.input_manifest ->> 'topic_concept_id' = '$endepunkt2');
delete from workflow.pipeline_jobs j
where j.agent_role = 'claim_synthesis'
  and j.input_manifest ->> 'topic_concept_id' = '$endepunkt2';
set session_replication_role = origin;

-- ----------------------------------------------------------------------------
-- Prøve 4 og 5 trenger et par som allerede HAR en påstand, og tre funn som
-- ingen revisjon av den hviler på.
--
-- Påstanden lages med én lenket kilde, slik at den er en ekte etablert påstand
-- og ikke en tom identitet. De tre andre funnene er den nye forskningen de to
-- prøvene kappes om.
-- ----------------------------------------------------------------------------
insert into catalog.clinical_concepts (id, canonical_label, concept_type)
values ('$endepunkt3', 'appetitt i kappløpsprøven ${kjoring:0:8}', 'outcome');

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
       d.id, 'none', '$endepunkt3', f.detalj,
       'not_reported', 'increase', 'not_reported', 'not_reported',
       f.peker, 'ai_assisted', a.id
from (values ('$funn_base'::uuid, 'Kappløpsprøven, grunnlaget påstanden hviler på.', 'Avsnitt 4'),
             ('$funn_d'::uuid, 'Kappløpsprøven, ny forskning D.', 'Avsnitt 5'),
             ('$funn_e'::uuid, 'Kappløpsprøven, ny forskning E.', 'Avsnitt 6'),
             ('$funn_f'::uuid, 'Kappløpsprøven, ny forskning F.', 'Avsnitt 7'))
       as f(id, detalj, peker)
cross join catalog.drugs d
cross join catalog.populations p
cross join provenance.actors a
where d.canonical_name = 'sertralin'
  and p.canonical_label = 'voksne med depressiv lidelse'
  and a.actor_key = 'agent:evidence-extraction';

insert into knowledge.claims
  (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
select '$paastand', 'evidence_synthesis', '$endepunkt3', d.id, a.id
from catalog.drugs d cross join provenance.actors a
where d.canonical_name = 'sertralin' and a.actor_key = 'agent:claim-synthesis';

insert into knowledge.claim_revisions
  (id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
   comparator_kind, direction, uncertainty_summary, created_by_actor_id)
select '$revisjon', '$paastand', 1, 'evidence_synthesis', c.subject_drug_id,
       'Kappløpsprøven: sertralin og appetitt.', 'Kun syntetiske data.',
       'none', 'increase', 'Testusikkerhet.', c.created_by_actor_id
from knowledge.claims c where c.id = '$paastand';

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select '$revisjon', '$funn_base', 'supports', 'direct',
       'Den opprinnelige lenken i kappløpsprøven.', c.created_by_actor_id
from knowledge.claims c where c.id = '$paastand';

insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select r.id, ai.id, ai.actor_id, 'extraction_verification', 'antidep',
       'deterministic-extraction-check', '1.0.0',
       'extraction-verification/deterministic/1', 'antidep-evidence/1',
       jsonb_build_object('mode', 'race-probe')
from (values ('$kjoring_d'::uuid), ('$kjoring_e'::uuid), ('$kjoring_f'::uuid)) as r(id)
cross join provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';
SQL
then
  feil 'fiksturen' 'Fiksturen lot seg ikke bygge.' "$arbeid/fikstur.log"
fi

# ----------------------------------------------------------------------------
# Én bestått ekstraksjonskontroll av ett funn, i de to radene dekningen krever.
#
# Den kildeomfattende halvdelen av et globalt fravær kan bare føres opp av en
# maskinell kontroll med sin egen kjøring (migrasjon 005ae), så kontrollen er to
# rader og ikke én. Ett sted framfor tre: prøve 1, 4 og 5 registrerer nøyaktig
# den samme halvdelen, og tre kopier ville kunnet drive fra hverandre.
# ----------------------------------------------------------------------------
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

# ============================================================================
# Prøve 1 — to beståtte kontroller på det samme subjektet gir én synteseoppgave
# ============================================================================
proeve1() {
  local navn='synteseoppgaven kan ikke legges inn to ganger'
  local styr="$arbeid/styr1" sql_b="$arbeid/b1.sql"
  local a_log="$arbeid/a1.log" b_log="$arbeid/b1.log"

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

# ============================================================================
# Prøve 3 — den manuelle innleggingen og den automatiske overgangen deler lås
# ============================================================================
# Overgangen spør om subjektet allerede har en oppgave, uansett hvem som la den
# inn. `api.enqueue_agent_task(...)` er redaktørens og recovery-veiens, og den
# har med vilje en jobbnøkkel som skiller på manifestet: to forskjellige
# avgrensninger av det samme subjektet skal kunne bli to oppgaver.
#
# Nettopp derfor fanger ikke unikhetskravet dette kappløpet. Uten en felles lås
# kunne redaktøren commite en oppgave i vinduet mellom overgangens spørsmål og
# dens skriving, og subjektet ville endt med to.
proeve3() {
  local navn='en manuell innlegging og en overgang gir til sammen én oppgave'
  local styr="$arbeid/styr3" sql_b="$arbeid/b3.sql"
  local a_log="$arbeid/a3.log" b_log="$arbeid/b3.log"

  # Katalogverdien slås opp her og ikke i økt A: der er kalleren `authenticated`,
  # og en innlogget bruker kommer ikke til katalogskjemaet — som hen ikke skal.
  local virkestoff
  virkestoff=$(les "select id from catalog.drugs where canonical_name = 'sertralin'")

  rm -f "$styr"
  mkfifo "$styr"

  # Økt B er den automatiske overgangen: en kontroll til på det samme funnet
  # utløser triggeren på nytt, og den bygger manifestet sitt av hele det
  # brukbare grunnlaget — med populasjonen, som redaktørens ikke har.
  cat > "$sql_b" <<SQL
begin;
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, a.id, 'verified', 'verifiable_representation',
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Kappløpsprøven: kontrollen kjørt om igjen, funn C.', now()
from knowledge.evidence_items e
cross join provenance.actors a
where e.id = '$funn_c' and a.actor_key = 'agent:extraction-verification';
commit;
SQL

  # Økt A er redaktøren, med en annen avgrensning av det samme subjektet.
  (
    printf 'begin;\n'
    printf "select set_config('request.jwt.claims', '{\"sub\":\"%s\"}', true);\n" "$bruker"
    printf 'set local role authenticated;\n'
    printf "select api.enqueue_agent_task('claim_synthesis', jsonb_build_object(
              'topic_concept_id', '%s'::uuid,
              'subject_drug_id', '%s'::uuid,
              'evidence_item_ids', jsonb_build_array('%s'::uuid)));\n" \
      "$endepunkt2" "$virkestoff" "$funn_c"
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
                  and input_manifest ->> 'topic_concept_id' = '$endepunkt2'")
  [ "$antall" = "1" ] || feil "$navn" \
    "Subjektet har $antall synteseoppgaver. Redaktørens innlegging og overgangen skal til sammen gi én."

  # Og det er redaktørens som står: hen kom først, og overgangen skal se den og
  # la være — ikke skrive over den.
  local manuell
  manuell=$(les "select count(*) from workflow.agent_handoff_jobs h
                 join workflow.pipeline_jobs j on j.id = h.pipeline_job_id
                 where j.agent_role = 'claim_synthesis'
                   and j.input_manifest ->> 'topic_concept_id' = '$endepunkt2'")
  [ "$manuell" = "1" ] || feil "$navn" \
    'Oppgaven som ble stående, er ikke den redaktøren la inn.'

  printf 'ok       %s\n' "$navn"
}

# ============================================================================
# Prøve 4 — to nye funn om den samme påstanden gir én menneskeoppgave
# ============================================================================
# Overgangen leser «finnes det en rad for denne påstanden?» og skriver den hvis
# ikke. Uten en felles lås kunne to kontroller av forskjellige funn på det samme
# paret begge lest «nei» — og taperen ville feilet på unikhetskravet midt i en
# registrering som ellers lyktes, altså fått en teknisk svikt ut av et helt
# normalt forløp.
proeve4() {
  local navn='to nye funn om den samme påstanden gir én menneskeoppgave'
  local styr="$arbeid/styr4" sql_b="$arbeid/b4.sql"
  local a_log="$arbeid/a4.log" b_log="$arbeid/b4.log"

  rm -f "$styr"
  mkfifo "$styr"

  {
    printf 'begin;\n'
    kontroll_sql "$funn_e" "$kjoring_e"
    printf 'commit;\n'
  } > "$sql_b"

  (
    printf 'begin;\n'
    kontroll_sql "$funn_d" "$kjoring_d"
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

  local oppgaver
  oppgaver=$(les "select count(*) from workflow.claim_revision_reviews
                  where claim_id = '$paastand'")
  [ "$oppgaver" = "1" ] || feil "$navn" \
    "Påstanden har $oppgaver redaksjonelle oppgaver. Den skal ha nøyaktig én."

  # Og den ble åpnet én gang. Den andre økten så raden vinneren commitet, og
  # utvidet den framfor å åpne en til.
  local aapnet
  aapnet=$(les "select count(*) from workflow.claim_revision_review_events e
                join workflow.claim_revision_reviews r on r.id = e.claim_revision_review_id
                where r.claim_id = '$paastand' and e.transition = 'opened'")
  [ "$aapnet" = "1" ] || feil "$navn" \
    "Oppgaven ble åpnet $aapnet ganger. Den skal åpnes én gang."

  # Kjeden skal fortsatt ikke ha synteseret noe om igjen på egen hånd.
  local jobber
  jobber=$(les "select count(*) from workflow.pipeline_jobs
                where agent_role = 'claim_synthesis'
                  and input_manifest ->> 'topic_concept_id' = '$endepunkt3'")
  [ "$jobber" = "0" ] || feil "$navn" \
    "Kjeden la inn $jobber synteseoppgaver om en påstand som allerede finnes."

  # Og begge kontrollene står: det som ble hindret, er den doble oppgaven.
  local kontroller
  kontroller=$(les "select count(distinct evidence_item_id) from workflow.evidence_verifications
                    where evidence_item_id in ('$funn_d', '$funn_e') and outcome = 'verified'")
  [ "$kontroller" = "2" ] || feil "$navn" \
    "Bare $kontroller av de to kontrollene ble registrert. Låsen skal utsette, aldri forkaste."

  printf 'ok       %s\n' "$navn"
}

# ============================================================================
# Prøve 5 — en beslutning tatt på et foreldet evidensgrunnlag avvises
# ============================================================================
# Redaktøren leser grunnlaget, og i vinduet før beslutningen kommer det enda et
# kontrollert funn. Beslutningen er bundet til nøyaktig det grunnlaget som ble
# lest (ANTIDEP_CONSTITUTION.md regel 5), så den skal avvises — og flaten skal
# be om fersk tilstand framfor at revisjonen bygges av noe redaktøren aldri så.
#
# Kappløpet er ekte: økt B holder subjektlåsen mens økt A står og venter på den,
# og økt A leser grunnlaget på nytt først etter at B har commitet.
proeve5() {
  local navn='en beslutning tatt på et foreldet evidensgrunnlag avvises'
  local styr="$arbeid/styr5" sql_b="$arbeid/b5.sql"
  local a_log="$arbeid/a5.log" b_log="$arbeid/b5.log"

  local referanse grunnlag
  referanse=$(les "select reference from workflow.claim_revision_reviews
                   where claim_id = '$paastand'")
  [ -n "$referanse" ] || feil "$navn" 'Prøve 4 etterlot ingen redaksjonell oppgave.'

  # Grunnlaget slik redaktøren leste det, før det tredje funnet kom til.
  grunnlag=$(les "select workflow.evidence_set_digest(
                    workflow.claim_subject_evidence(c.subject_drug_id, c.topic_concept_id))
                  from knowledge.claims c where c.id = '$paastand'")

  rm -f "$styr"
  mkfifo "$styr"

  # Økt A er redaktørens beslutning, med det grunnlaget hen faktisk så.
  cat > "$sql_b" <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$bruker"}', true);
set local role authenticated;
select api.record_claim_revision_decision('$referanse', 'revise', '$grunnlag');
commit;
SQL

  # Økt B er det tredje funnet, som blir kontrollert i mellomtiden. Den tar
  # subjektlåsen gjennom overgangen, og holder den til den commiter.
  (
    printf 'begin;\n'
    kontroll_sql "$funn_f" "$kjoring_f"
    printf '\\echo KLAR\n'
    printf '\\o /dev/null\n'
    cat "$styr"
  ) | psql "$DB_URL" -X -v ON_ERROR_STOP=1 > "$b_log" 2>&1 &
  okt_b_pid=$!
  exec 9>"$styr"

  local i
  for i in $(seq 1 150); do
    grep -q 'KLAR' "$b_log" 2>/dev/null && break
    sleep 0.1
  done
  grep -q 'KLAR' "$b_log" 2>/dev/null || feil "$navn" 'Økt B kom ikke i gang.' "$b_log"

  psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$sql_b" > "$a_log" 2>&1 &
  okt_a_pid=$!

  vent_paa_blokkering "$navn"

  printf 'commit;\n' >&9
  exec 9>&-
  wait "$okt_b_pid" 2>/dev/null; local b_status=$?
  okt_b_pid=""
  wait "$okt_a_pid" 2>/dev/null; local a_status=$?
  okt_a_pid=""
  rm -f "$styr"

  [ "$b_status" -eq 0 ] || feil "$navn" 'Økt B kom ikke gjennom.' "$b_log"
  [ "$a_status" -ne 0 ] || feil "$navn" \
    'Beslutningen gikk gjennom på et grunnlag som var endret under beina på redaktøren.' "$a_log"
  grep -q 'Evidensgrunnlaget er endret' "$a_log" || feil "$navn" \
    'Beslutningen ble avvist, men ikke fordi grunnlaget var endret.' "$a_log"

  local jobber tilstand
  jobber=$(les "select count(*) from workflow.pipeline_jobs
                where agent_role = 'claim_synthesis'
                  and input_manifest ->> 'topic_concept_id' = '$endepunkt3'")
  [ "$jobber" = "0" ] || feil "$navn" \
    "Den avviste beslutningen etterlot $jobber synteseoppgaver."

  tilstand=$(les "select state from workflow.claim_revision_reviews
                  where claim_id = '$paastand'")
  [ "$tilstand" = "open" ] || feil "$navn" \
    "Oppgaven står som «$tilstand» etter en avvist beslutning. Den skal fortsatt være åpen."

  # Og med fersk tilstand går den gjennom: avvisningen var samtidighet, ikke en
  # sperre mot å bestemme seg.
  local ferskt
  ferskt=$(les "select workflow.evidence_set_digest(
                  workflow.claim_subject_evidence(c.subject_drug_id, c.topic_concept_id))
                from knowledge.claims c where c.id = '$paastand'")
  if ! psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 > "$arbeid/a5b.log" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$bruker"}', true);
set local role authenticated;
select api.record_claim_revision_decision('$referanse', 'revise', '$ferskt');
commit;
SQL
  then
    feil "$navn" 'Beslutningen gikk ikke gjennom med fersk tilstand heller.' "$arbeid/a5b.log"
  fi

  jobber=$(les "select count(*) from workflow.pipeline_jobs
                where agent_role = 'claim_synthesis'
                  and input_manifest ->> 'topic_concept_id' = '$endepunkt3'")
  [ "$jobber" = "1" ] || feil "$navn" \
    "Den besluttede revisjonen ga $jobber synteseoppgaver. Den skal gi nøyaktig én."

  local grunnlagsstoerrelse
  grunnlagsstoerrelse=$(les "select jsonb_array_length(input_manifest -> 'evidence_item_ids')
                             from workflow.pipeline_jobs
                             where agent_role = 'claim_synthesis'
                               and input_manifest ->> 'topic_concept_id' = '$endepunkt3'")
  [ "$grunnlagsstoerrelse" = "3" ] || feil "$navn" \
    "Synteseoppgaven bærer $grunnlagsstoerrelse funn. Den skal bære hele det gjeldende grunnlaget."

  printf 'ok       %s\n' "$navn"
}

# ----------------------------------------------------------------------------
# Prøve 6: fjerningen av et evidensfunn og den redaksjonelle beslutningen
#
# De to tar de samme to låsene — subjektlåsen og evidenstabellene. Beslutningen
# tar subjektlåsen først og leser evidens etterpå. Tok fjerningen tabellåsene
# først og subjektlåsen etterpå, ville de gått i hver sin retning gjennom de
# samme låsene, og Postgres måtte brutt vranglåsen ved å avbryte den ene.
#
# Prøven holder subjektlåsen i økt B, slik beslutningsveien gjør før den leser
# evidens, og lar økt A fjerne et funn samtidig. Det avgjørende er ikke bare at
# A venter, men at B fortsatt kan lese evidenstabellen mens A venter: det er
# nettopp den lesningen som ville stått fast om fjerningen holdt tabellåsene.
# ----------------------------------------------------------------------------
proeve6() {
  local navn='fjerning og beslutning tar låsene i samme rekkefølge'
  local styr="$arbeid/styr6" sql_a="$arbeid/a6.sql"
  local a_log="$arbeid/a6.log" b_log="$arbeid/b6.log"

  # Først porten foran hele saken: så lenge revisjonen er besluttet og oppgaven
  # ligger i køen, bærer manifestet funnet uten at noe peker på det. Fjernes det
  # da, ville jobben pekt på evidens som ikke finnes.
  if psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 > "$arbeid/a6a.log" 2>&1 <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$bruker"}', true);
select knowledge.discard_unpublished_extraction_artifacts(
  array['$funn_f']::uuid[], 'Kappløpsprøve: forsøk under en besluttet revisjon.');
commit;
SQL
  then
    feil "$navn" 'Et funn under en besluttet, ubygget revisjon lot seg fjerne.' "$arbeid/a6a.log"
  fi
  grep -q 'inngår i en besluttet revisjon' "$arbeid/a6a.log" || feil "$navn" \
    'Fjerningen ble avvist, men ikke fordi funnet inngår i en besluttet revisjon.' "$arbeid/a6a.log"

  # Jobben svikter teknisk, slik en jobb kan gjøre. Da er funnet fjernbart, og
  # selve låserekkefølgen kan prøves.
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 > /dev/null 2>&1 <<SQL
update workflow.pipeline_jobs
set state = 'failed', completed_at = now(),
    failure_reason = 'Kappløpsprøve: jobben svikter med vilje.'
where agent_role = 'claim_synthesis'
  and input_manifest ->> 'topic_concept_id' = '$endepunkt3';
SQL

  rm -f "$styr"
  mkfifo "$styr"

  # Økt B holder subjektlåsen, slik beslutningsveien gjør før den leser evidens.
  (
    cat <<SQL
begin;
select workflow.lock_chain_subject('claim_synthesis'::provenance.agent_role,
  (select format('%s+%s', c.subject_drug_id, c.topic_concept_id)
   from knowledge.claims c where c.id = '$paastand'));
\echo KLAR
\o /dev/null
SQL
    cat "$styr"
  ) | psql "$DB_URL" -X -v ON_ERROR_STOP=1 > "$b_log" 2>&1 &
  okt_b_pid=$!
  exec 9>"$styr"

  local i
  for i in $(seq 1 150); do
    grep -q 'KLAR' "$b_log" 2>/dev/null && break
    sleep 0.1
  done
  grep -q 'KLAR' "$b_log" 2>/dev/null || feil "$navn" 'Økt B kom ikke i gang.' "$b_log"

  cat > "$sql_a" <<SQL
begin;
select set_config('request.jwt.claims', '{"sub":"$bruker"}', true);
select knowledge.discard_unpublished_extraction_artifacts(
  array['$funn_f']::uuid[], 'Kappløpsprøve: fjerning mens beslutningen holder låsen.');
commit;
SQL
  psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$sql_a" > "$a_log" 2>&1 &
  okt_a_pid=$!

  vent_paa_blokkering "$navn"

  # Hele poenget: økt B leser evidenstabellen mens økt A venter på låsen B
  # holder. Holdt A tabellåsene, ville denne lesningen stått fast bak dem, og de
  # to ville ventet på hverandre.
  printf 'select count(*) from knowledge.evidence_items;\ncommit;\n' >&9
  exec 9>&-
  wait "$okt_b_pid" 2>/dev/null; local b_status=$?
  okt_b_pid=""
  wait "$okt_a_pid" 2>/dev/null; local a_status=$?
  okt_a_pid=""
  rm -f "$styr"

  [ "$b_status" -eq 0 ] || feil "$navn" \
    'Økt B kom ikke gjennom. Låsene tas i hver sin rekkefølge, og de to venter på hverandre.' "$b_log"
  [ "$a_status" -eq 0 ] || feil "$navn" \
    'Fjerningen kom ikke gjennom etter at subjektlåsen ble sluppet.' "$a_log"

  local igjen
  igjen=$(les "select count(*) from knowledge.evidence_items where id = '$funn_f'")
  [ "$igjen" = "0" ] || feil "$navn" 'Fjerningen sa den gikk gjennom, men funnet står.'

  printf 'ok       %s\n' "$navn"
}

printf 'Samtidighetsprøver for de automatiske kjedeovergangene\n'
proeve1
proeve2
proeve3
proeve4
proeve5
proeve6
printf 'Alle prøvene bestod.\n'
