#!/usr/bin/env bash
# Migrasjon 014g lagt oppå produksjonens eget forløp.
#
# pgTAP 990 prøver invarianten på en tom base. Denne prøven svarer på det
# andre spørsmålet: reparerer migrasjonen de dataene produksjonen faktisk hadde
# da agentoppgavene ikke åpnet seg — uten å slette eller skrive om noe?
#
# Forløpet er produksjonens, i samme rekkefølge:
#
#   1. Basen settes til siste migrasjon før 013v, og sertralin bestilles. Det
#      gir kildeoppdagelsen oppgaver under den forrige kildekontrakten.
#   2. 013v–013z kjøres. De gamle oppgavene foreldes, og hver plan får sin
#      første maskinelle runde.
#   3. Kjøreren lukker rundene (kjøring #7–#15 i produksjon), og hver plan får
#      sin runde 1-oppgave. Noen av dem får et utfall: én tas ut og gis fra seg,
#      én blir fullført og én bruker opp forsøkene sine.
#   4. 014c–014f kjøres. Registeret åpner nye søk i runde 1 for de åpne
#      planene, og lukker planene som aldri var søkeplaner.
#   5. Feilen, slik den var: kjøreren lukker de nye søkene for planen med den
#      fullførte og planen med den oppbrukte oppgaven, og ingen ny oppgave
#      legges inn. Køen har ingenting kjørbart, bare «blokkert».
#   6. 014g kjøres med `supabase migration up`, som ved en utrulling.
#   7. Hver plan med en ferdig søkt runde har nøyaktig én oppgave for hele
#      grunnlaget; ingen plan har to; den foreldede historikken er trukket
#      tilbake med problemene sine lukket; og ingen jobb, hendelse eller
#      klinisk rad fra før er slettet eller skrevet om.
#   8. Kjøreren lukker resten av søkene for noen planer, og oppgavene deres
#      legges inn — én gang, også når overgangen kjøres om igjen.
set -euo pipefail
cd "$(dirname "$0")/.."

LAST_BEFORE_013V=20261018090000
LAST_BEFORE_014C=20261019095000
LAST_BEFORE_014G=20261020094000
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

DB_URL=$(npx --no-install supabase status -o json 2>/dev/null | node -e '
  let data = ""
  process.stdin.on("data", (chunk) => (data += chunk)).on("end", () => {
    try { process.stdout.write(JSON.parse(data).DB_URL ?? "") } catch { process.stdout.write("") }
  })
')

# Aldri mot en hostet base.
node scripts/local-test-db.mjs "$DB_URL"

sql() {
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 "$@"
}

scalar() {
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -t -A -c "$1" | tr -d '\r\n'
}

fail() {
  printf 'FEIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual=$1 expected=$2 message=$3
  [ "$actual" = "$expected" ] || fail "$message (forventet «$expected», fikk «$actual»)"
}

assert_ne() {
  local actual=$1 forbidden=$2 message=$3
  [ "$actual" != "$forbidden" ] || fail "$message (fikk «$actual»)"
}

# Migrasjonene mellom to versjoner, hver i sin egen transaksjon og ført i
# migrasjonsloggen, slik `supabase db push` gjør det. Prøven må stanse ved en
# bestemt migrasjon, og det kan ikke `supabase migration up`.
apply_between() {
  local after=$1 until=$2 file version
  for file in supabase/migrations/*.sql; do
    version=$(basename "$file" | cut -d_ -f1)
    if [[ "$version" > "$after" && ! "$version" > "$until" ]]; then
      if ! sql -1 -f "$file" >"$TMP_DIR/$version.log" 2>&1; then
        tail -40 "$TMP_DIR/$version.log" >&2
        fail "migrasjonen $(basename "$file") lot seg ikke kjøre"
      fi
      sql -c "insert into supabase_migrations.schema_migrations (version, name)
              values ('$version', '$(basename "$file" .sql | cut -d_ -f2-)')" >/dev/null
    fi
  done
}

# Kjøreren lukker hver ventende generatorrunde for de planene utvalget gir,
# gjennom den samme api-funksjonen den bruker i produksjon. Ingen søk er
# registrert, så rundene blir registrerte begrensninger — som ikke holder
# porten. Svarer med hvor mange av lukkingene som la inn en oppgave.
close_rounds() {
  local plans_sql=$1
  scalar "
    with lukket as (
      select api.close_monograph_search_request(
               'agent-identity:source-discovery-01',
               (select secret from upgrade_probe.cred where label = 'discovery'),
               (select id from upgrade_probe.runs where label = 'discovery'),
               r.reference) as svar
      from workflow.monograph_search_requests r
      where r.plan_id in ($plans_sql)
        and r.requested_for_role = 'source_discovery'
        and r.state = 'pending'
    )
    select count(*) filter (where (svar ->> 'enqueued_job')::boolean) from lukket"
}

# Hvordan køen ser ut for kildeoppdagelsen: kjørbart og blokkert, lest av den
# samme funksjonen api.list_pending_agent_tasks(...) leser, og med det samme
# utvalget. Fra 014g er en tilbaketrukket oppgave ikke med.
queue() {
  local withdrawn=${1:-}
  scalar "
    select count(*) filter (where workflow.agent_task_problem(j) is null)
           || '/' || count(*) filter (where workflow.agent_task_problem(j) is not null)
    from workflow.pipeline_jobs j
    join workflow.agent_handoff_jobs h on h.pipeline_job_id = j.id
    where j.agent_role = 'source_discovery'
      and j.state <> 'succeeded'
      and not exists (select 1 from workflow.agent_handoff_imports i where i.pipeline_job_id = j.id)
      $withdrawn"
}

# De kliniske og faglige radene, som ett avtrykk per tabell. Migrasjonen skal
# ikke røre noen av dem.
CLINICAL_SQL="
select string_agg(format('%s.%s', table_schema, table_name), ' ' order by table_schema, table_name)
from information_schema.tables
where table_schema in ('knowledge', 'catalog') and table_type = 'BASE TABLE'"

clinical_fingerprint() {
  local tables table
  tables=$(scalar "$CLINICAL_SQL")
  for table in $tables; do
    printf '%s %s\n' "$table" \
      "$(scalar "select count(*) || ':' || coalesce(md5(string_agg(t::text, '|' order by t::text)), '-') from $table t")"
  done
}

printf 'Migrasjon 014g lagt oppå produksjonens forløp.\n'
printf '  1/8  setter basen til siste migrasjon før 013v, og bestiller sertralin …\n'
npx --no-install supabase db reset --version "$LAST_BEFORE_013V" >/dev/null

sql >/dev/null <<'SQL'
insert into auth.users (id, email)
values ('99100000-0000-4000-8000-00000000000a', 'redaktor-oppgradering@test.invalid');
insert into provenance.actors (id, actor_type, actor_key, display_name, description, auth_user_id)
values ('ac991000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-oppgradering',
        'Redaktør oppgradering', 'Redaktøren i oppgraderingsprøven av 014g.',
        '99100000-0000-4000-8000-00000000000a');
insert into workflow.user_roles (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('99100000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
        'ac991000-0000-4000-8000-00000000000a', 'Editor-tildeling for oppgraderingsprøven av 014g.');

begin;
select set_config('request.jwt.claims', '{"sub":"99100000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select api.order_monograph('sertralin', 'Oppgraderingsprøven av 014g.');
select api.assign_agent_role_model(
  'source_discovery', 'openai', 'chatgpt', null, 'not_exposed',
  'Oppgraderingsprøven av 014g.', 'Oppgraderingsprøven av 014g: generatorens modell.');
commit;
SQL

LEGACY=$(scalar "select count(*) from workflow.pipeline_jobs where agent_role = 'source_discovery' and state = 'ready'")
assert_ne "$LEGACY" '0' 'bestillingen før 013v la ingen kildeoppgaver inn'

printf '  2/8  kjører 013v–013z (%s oppgaver under den forrige kildekontrakten) …\n' "$LEGACY"
apply_between "$LAST_BEFORE_013V" "$LAST_BEFORE_014C"

assert_eq "$(scalar "select count(*) from workflow.pipeline_jobs
                     where agent_role = 'source_discovery' and state = 'failed'
                       and failure_reason like 'Foreldet av migrasjon 013v:%'")" "$LEGACY" \
  '013v foreldet ikke oppgavene fra den forrige kildekontrakten'

# Kjøreren trenger en identitet og en åpen kjøring, som i produksjon.
sql >/dev/null <<'SQL'
create schema upgrade_probe;
create table upgrade_probe.cred (label text primary key, secret text not null);
create table upgrade_probe.runs (label text primary key, id uuid not null);
insert into upgrade_probe.cred
select 'discovery', provenance.issue_agent_identity_credential(
  'agent-identity:source-discovery-01', 'human:redaktor-oppgradering');
insert into upgrade_probe.runs
select 'discovery', api.begin_agent_run(
  'agent-identity:source-discovery-01', (select secret from upgrade_probe.cred where label = 'discovery'),
  'source_discovery', 'antidep', 'search-execution-and-registration', '1.0.0',
  'source-discovery/machine-execution/2', 'antidep-evidence/1',
  jsonb_build_object('search_plan_reference',
    (select min(reference) from workflow.monograph_search_plans)));
SQL

printf '  3/8  kjøreren lukker runde 1 for hver plan (kjøring #7–#15) …\n'
ROUND1=$(close_rounds 'select p.id from workflow.monograph_search_plans p where p.closed_at is null')
assert_ne "$ROUND1" '0' 'kjøreren la ingen runde 1-oppgaver inn'

# Tre av oppgavene får et utfall. Tilstanden settes direkte, slik kjøreren og
# importen setter den: det er migrasjonens lesning av den som prøves her.
#   * R: tatt ut og gitt fra seg igjen (ChatGPT gjorde det samme i produksjon),
#   * S: fullført — vurderingen av runde 1 er gjort, og runden står,
#   * F: oppbrukt — kjøreren ga opp etter siste forsøk.
sql >/dev/null <<'SQL'
create table upgrade_probe.plans (label text primary key, plan_id uuid not null, job_id uuid not null);
insert into upgrade_probe.plans (label, plan_id, job_id)
select v.label, x.plan_id, x.job_id
from (
  select (j.input_manifest ->> 'search_plan_id')::uuid as plan_id, j.id as job_id,
         row_number() over (order by j.input_manifest ->> 'search_plan_id') as n
  from workflow.pipeline_jobs j
  where j.agent_role = 'source_discovery' and j.state = 'ready'
    and j.input_manifest ? 'discovery_round'
) x
join (values ('R', 1), ('S', 2), ('F', 3)) as v(label, n) on v.n = x.n;

update workflow.pipeline_jobs set attempts = 1
where id = (select job_id from upgrade_probe.plans where label = 'R');

update workflow.pipeline_jobs
set state = 'succeeded', attempts = 1, completed_at = now(),
    leased_by_agent_identity_id = (select id from provenance.agent_identities
                                   where identity_key = 'agent-identity:source-discovery-01'),
    lease_token = gen_random_uuid(), lease_expires_at = now() + interval '15 minutes',
    agent_run_id = (select id from upgrade_probe.runs where label = 'discovery'),
    output_manifest = '{}'::jsonb
where id = (select job_id from upgrade_probe.plans where label = 'S');

update workflow.pipeline_jobs
set state = 'failed', attempts = max_attempts, completed_at = now(),
    failure_reason = 'Kjøreren fikk ikke fullført arbeidet.'
where id = (select job_id from upgrade_probe.plans where label = 'F');
SQL
assert_eq "$(scalar 'select count(*) from upgrade_probe.plans')" '3' \
  'prøven fant ikke tre runde 1-oppgaver å gi et utfall'

printf '  4/8  kjører 014c–014f …\n'
apply_between "$LAST_BEFORE_014C" "$LAST_BEFORE_014G"

GROWN=$(scalar "select count(distinct r.plan_id) from workflow.monograph_search_requests r
                where r.origin = 'registry_opened' and r.search_round = 1 and r.state = 'pending'")
assert_ne "$GROWN" '0' '014c–014f åpnet ingen nye søk i runde 1, og prøven prøver ingenting'

printf '  5/8  feilen, slik den var: runden vokser for S og F, og ingen oppgave legges inn …\n'
assert_eq "$(scalar "select count(distinct r.plan_id) from workflow.monograph_search_requests r
                     join upgrade_probe.plans p on p.plan_id = r.plan_id
                     where p.label in ('S', 'F') and r.state = 'pending'")" '2' \
  'registeret åpnet ikke nye søk i runde 1 for planene med den fullførte og den oppbrukte oppgaven'
BEFORE_FIX=$(close_rounds "select plan_id from upgrade_probe.plans where label in ('S', 'F')")
assert_eq "$BEFORE_FIX" '0' \
  'før 014g la kjøreren inn en oppgave for en runde som allerede hadde en fullført eller oppbrukt oppgave — da prøver ikke prøven feilen'
QUEUE_BEFORE=$(queue)
printf '       køen før 014g: %s kjørbare / blokkerte\n' "$QUEUE_BEFORE"
assert_eq "${QUEUE_BEFORE%%/*}" '0' 'før 014g hadde køen kjørbare oppgaver, slik produksjonen ikke hadde'

# Alt som fantes før, én rad per jobb og per hendelse, og avtrykket av de
# kliniske og faglige tabellene.
sql >/dev/null <<'SQL'
create table upgrade_probe.jobs_before as select * from workflow.pipeline_jobs;
create table upgrade_probe.events_before as select * from workflow.pipeline_job_events;
create table upgrade_probe.requests_before as select * from workflow.monograph_search_requests;
SQL
clinical_fingerprint >"$TMP_DIR/clinical-before.txt"

printf '  6/8  kjører 014g med supabase migration up …\n'
if ! npx --no-install supabase migration up --local >"$TMP_DIR/up.log" 2>&1; then
  tail -60 "$TMP_DIR/up.log" >&2
  fail '014g lot seg ikke legge oppå produksjonens forløp'
fi

printf '  7/8  kontrollerer reparasjonen …\n'

# Ingenting fra før er slettet eller skrevet om.
clinical_fingerprint >"$TMP_DIR/clinical-after.txt"
if ! diff -u "$TMP_DIR/clinical-before.txt" "$TMP_DIR/clinical-after.txt" >"$TMP_DIR/clinical.diff"; then
  cat "$TMP_DIR/clinical.diff" >&2
  fail '014g endret kliniske eller faglige rader'
fi
assert_eq "$(scalar "select count(*) from upgrade_probe.events_before b
                     where not exists (select 1 from workflow.pipeline_job_events e
                                       where e.id = b.id and row(e.*) is not distinct from row(b.*))")" '0' \
  '014g slettet eller skrev om en jobbhendelse'
assert_eq "$(scalar "select count(*) from upgrade_probe.requests_before b
                     where not exists (select 1 from workflow.monograph_search_requests r where r.id = b.id)")" '0' \
  '014g slettet en søkeforespørsel'
assert_eq "$(scalar "select count(*) from upgrade_probe.jobs_before b
                     where not exists (select 1 from workflow.pipeline_jobs j where j.id = b.id)")" '0' \
  '014g slettet en jobb'
# En avsluttet jobb står nøyaktig som den sto. En ledig jobb står enten som den
# sto, eller er trukket tilbake med en overgang til failed.
assert_eq "$(scalar "select count(*) from upgrade_probe.jobs_before b
                     join workflow.pipeline_jobs j on j.id = b.id
                     where b.state in ('succeeded', 'failed')
                       and (j.state, j.attempts, j.job_key, j.input_manifest, j.failure_reason,
                            j.completed_at, j.output_manifest)
                           is distinct from
                           (b.state, b.attempts, b.job_key, b.input_manifest, b.failure_reason,
                            b.completed_at, b.output_manifest)")" '0' \
  '014g skrev om en avsluttet jobb'
assert_eq "$(scalar "select count(*) from upgrade_probe.jobs_before b
                     join workflow.pipeline_jobs j on j.id = b.id
                     where b.state in ('ready', 'leased')
                       and ((j.job_key, j.input_manifest, j.attempts)
                              is distinct from (b.job_key, b.input_manifest, b.attempts)
                            or (j.state <> b.state
                                and not (j.state = 'failed' and workflow.pipeline_job_withdrawn(j.id))))")" '0' \
  '014g endret en ledig jobb på annen måte enn å trekke den tilbake'

# Den foreldede historikken er trukket tilbake, og problemene om den er lukket.
assert_eq "$(scalar "select count(*) from workflow.pipeline_jobs j
                     where j.failure_reason like 'Foreldet av migrasjon 01%'
                       and not workflow.pipeline_job_withdrawn(j.id)")" '0' \
  'foreldet historikk står fortsatt som ventende arbeid'
assert_eq "$(scalar "select count(*) from workflow.technical_incidents ti
                     join workflow.pipeline_job_withdrawals w
                       on ti.signature = 'pipeline-job:' || w.pipeline_job_id::text
                     where ti.area = 'automatic_task' and ti.resolved_at is null")" '0' \
  'en tilbaketrukket oppgave står fortsatt som et åpent teknisk problem'

# S og F har fått oppgaven for det utvidede grunnlaget. Den fullførte står som
# den var; den oppbrukte er trukket tilbake.
assert_eq "$(scalar "select count(*) from upgrade_probe.plans p
                     join workflow.pipeline_jobs j
                       on j.agent_role = 'source_discovery'
                      and j.input_manifest ->> 'search_plan_id' = p.plan_id::text
                      and j.state = 'ready'
                      and j.input_manifest ? 'search_basis'
                      and workflow.agent_task_problem(j) is null
                     where p.label in ('S', 'F')")" '2' \
  'planen med den fullførte og planen med den oppbrukte oppgaven fikk ingen ny, kjørbar oppgave'
assert_eq "$(scalar "select state || '/' || workflow.pipeline_job_withdrawn(id) from workflow.pipeline_jobs
                     where id = (select job_id from upgrade_probe.plans where label = 'S')")" 'succeeded/false' \
  'den fullførte vurderingen ble rørt'
assert_eq "$(scalar "select state || '/' || workflow.pipeline_job_withdrawn(id) from workflow.pipeline_jobs
                     where id = (select job_id from upgrade_probe.plans where label = 'F')")" 'failed/true' \
  'den oppbrukte oppgaven om det gamle grunnlaget ble ikke trukket tilbake'

# Invarianten, for hver åpen plan: en ferdig søkt runde har nøyaktig én aktiv
# oppgave, og en runde som søkes, har ingen.
INVARIANT_SQL="
  select count(*)
  from workflow.monograph_search_plans p
  join knowledge.monograph_editions e on e.id = p.edition_id
  cross join lateral (
    select count(*) as active
    from workflow.pipeline_jobs j
    where j.agent_role = 'source_discovery'
      and j.input_manifest ->> 'search_plan_id' = p.id::text
      and j.state in ('ready', 'leased')
      and not workflow.pipeline_job_withdrawn(j.id)
  ) a
  where p.closed_at is null and p.paused_at is null and e.superseded_at is null
    and a.active <> case when workflow.monograph_search_phase_problem(p.id, 'source_discovery') is null
                         then 1 else 0 end"
assert_eq "$(scalar "$INVARIANT_SQL")" '0' \
  'en åpen plan har ikke nøyaktig én aktiv oppgave når runden er søkt, og ingen når den søkes'

QUEUE_AFTER=$(queue 'and not workflow.pipeline_job_withdrawn(j.id)')
printf '       køen etter 014g: %s kjørbare / blokkerte\n' "$QUEUE_AFTER"
assert_eq "${QUEUE_AFTER#*/}" '0' 'etter 014g sier køen fortsatt at noe venter på et menneske'
assert_eq "${QUEUE_AFTER%%/*}" \
  "$(scalar "select count(*) from workflow.monograph_search_plans p
             where p.closed_at is null and p.paused_at is null
               and workflow.monograph_search_phase_problem(p.id, 'source_discovery') is null")" \
  'køen har ikke én kjørbar oppgave per ferdig søkt plan'

printf '  8/8  kjøreren lukker resten for noen planer, og overgangen kjøres om igjen …\n'
ACTIVE_BEFORE=$(scalar "select count(*) from workflow.pipeline_jobs j
                        where j.agent_role = 'source_discovery' and j.state in ('ready', 'leased')
                          and not workflow.pipeline_job_withdrawn(j.id)")
AFTER_FIX=$(close_rounds "
  select p.id from workflow.monograph_search_plans p
  where p.closed_at is null and p.paused_at is null
    and workflow.monograph_search_phase_problem(p.id, 'source_discovery') is not null
  order by p.id limit 10")
assert_eq "$AFTER_FIX" '10' 'når runden er søkt, legges oppgaven inn for hver av planene'
assert_eq "$(scalar "select count(*) filter (where workflow.chain_task_for_search_plan(p.id) is not null)
                     from workflow.monograph_search_plans p
                     where p.closed_at is null and p.paused_at is null")" '0' \
  'overgangen kjørt om igjen la inn oppgaver som allerede fantes'
assert_eq "$(scalar "select count(*) from workflow.pipeline_jobs j
                     where j.agent_role = 'source_discovery' and j.state in ('ready', 'leased')
                       and not workflow.pipeline_job_withdrawn(j.id)")" "$((ACTIVE_BEFORE + 10))" \
  'antallet aktive oppgaver er ikke det forrige pluss de ti nye'
assert_eq "$(scalar "$INVARIANT_SQL")" '0' 'invarianten holder ikke etter at kjøreren har søkt videre'

sql -c 'drop schema upgrade_probe cascade' >/dev/null
printf '\n014g reparerer produksjonens forløp, og legger inn arbeidet runden krever.\n'
