#!/usr/bin/env bash
# Fail-closed regression: a newly created claim with the same drug/topic and the
# same old evidence root is NOT part of the owner-authorized legacy prototype.
set -euo pipefail
cd "$(dirname "$0")/.."

LAST_LEGACY=20260924095000
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

DB_URL=$(npx --no-install supabase status -o json 2>/dev/null | node -e '
  let data = ""
  process.stdin.on("data", (chunk) => (data += chunk)).on("end", () => {
    try { process.stdout.write(JSON.parse(data).DB_URL ?? "") } catch { process.stdout.write("") }
  })
')

node scripts/local-test-db.mjs "$DB_URL"

scalar() {
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -t -A -c "$1" | tr -d '\r\n'
}

fail() {
  printf 'FEIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual=$1 expected=$2 message=$3
  [ "$actual" = "$expected" ] || fail "$message (forventet $expected, fikk $actual)"
}

printf 'Antidep 2: stopptest for ny erstatningspåstand med legacy-lik identitet.\n'
npx --no-install supabase db reset --version "$LAST_LEGACY" --no-seed >/dev/null

assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'legacy-fiksturen skal starte med to evidensrøtter'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" '2' \
  'legacy-fiksturen skal starte med to historiske påstandsrøtter'

# Reproduce the dangerous shape from the review finding. A new synthesis run
# creates a fresh mirtazapine claim whose semantic identity and evidence root are
# indistinguishable from the removed legacy claim if the guard only compares
# drug/topic/linkage. The revision creation trigger gives the new root an audit
# event, and the run pointer proves it was created after agent provenance existed.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
begin;

create temporary table old_mirt_claim as
select cl.id as claim_id, r.id as revision_id
from knowledge.claims cl
join catalog.drugs d on d.id = cl.subject_drug_id
join knowledge.claim_revisions r on r.claim_id = cl.id and r.revision_number = 1
where d.canonical_name = 'mirtazapin';

insert into provenance.agent_runs (
  id, agent_identity_id, actor_id, agent_role,
  provider, model, model_version,
  prompt_template_version, pipeline_version, input_manifest,
  status, completed_at, output_manifest
)
select '10300000-0000-4000-8000-000000000001', ai.id, ai.actor_id,
       'claim_synthesis', 'antidep', 'replacement-claim-regression', '1.0.0',
       'claim-synthesis/regression/1', 'antidep-evidence/1',
       '{"mode":"replacement-claim-regression"}'::jsonb,
       'succeeded', now(), '{"mode":"replacement-claim-regression"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:claim-synthesis-01';

create temporary table new_claim(id uuid primary key) on commit drop;
insert into new_claim
select gen_random_uuid();

insert into knowledge.claims (
  id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id
)
select n.id, old.knowledge_type, old.topic_concept_id, old.subject_drug_id,
       run.actor_id
from new_claim n
cross join lateral (
  select cl.*
  from knowledge.claims cl
  join old_mirt_claim x on x.claim_id = cl.id
) old
cross join provenance.agent_runs run
where run.id = '10300000-0000-4000-8000-000000000001';

create temporary table new_revision(id uuid primary key) on commit drop;
insert into new_revision select gen_random_uuid();

insert into knowledge.claim_revisions (
  id, claim_id, revision_number, knowledge_type, subject_drug_id,
  supersedes_revision_id, statement, scope, population_id,
  timeframe_min, timeframe_max, comparator_kind, comparator_drug_id,
  direction, magnitude_measure, magnitude_value, magnitude_unit,
  qualifiers, uncertainty_summary, created_by_actor_id, agent_run_id
)
select nr.id, nc.id, 1, old.knowledge_type, old.subject_drug_id,
       null, old.statement, old.scope, old.population_id,
       old.timeframe_min, old.timeframe_max, old.comparator_kind,
       old.comparator_drug_id, old.direction, old.magnitude_measure,
       old.magnitude_value, old.magnitude_unit, old.qualifiers,
       old.uncertainty_summary, run.actor_id, run.id
from new_revision nr
cross join new_claim nc
cross join lateral (
  select r.*
  from knowledge.claim_revisions r
  join old_mirt_claim x on x.revision_id = r.id
) old
cross join provenance.agent_runs run
where run.id = '10300000-0000-4000-8000-000000000001';

insert into knowledge.claim_evidence_links (
  claim_revision_id, evidence_item_id, relationship_type,
  directness, relevance_note, created_by_actor_id
)
select nr.id, old_link.evidence_item_id, old_link.relationship_type,
       old_link.directness, old_link.relevance_note, run.actor_id
from new_revision nr
cross join lateral (
  select l.*
  from knowledge.claim_evidence_links l
  join old_mirt_claim x on x.revision_id = l.claim_revision_id
  order by l.created_at, l.id
  limit 1
) old_link
cross join provenance.agent_runs run
where run.id = '10300000-0000-4000-8000-000000000001';

-- Remove the old mirtazapine claim exactly as an evolved hosted state may have
-- done. Keep both historical evidence roots. The new root now occupies the same
-- drug/topic slot and points at the same old evidence item.
alter table knowledge.evidence_assessments disable trigger evidence_assessments_reject_mutation;
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_reject_mutation;
alter table knowledge.claim_revisions disable trigger claim_revisions_reject_mutation;

delete from knowledge.evidence_assessments
where claim_revision_id in (
  select r.id from knowledge.claim_revisions r
  join old_mirt_claim x on x.claim_id = r.claim_id
);
delete from knowledge.claim_evidence_links
where claim_revision_id in (
  select r.id from knowledge.claim_revisions r
  join old_mirt_claim x on x.claim_id = r.claim_id
);
delete from knowledge.claim_revisions
where claim_id in (select claim_id from old_mirt_claim);
delete from knowledge.claims
where id in (select claim_id from old_mirt_claim);

alter table knowledge.claim_revisions enable trigger claim_revisions_reject_mutation;
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_mutation;
alter table knowledge.evidence_assessments enable trigger evidence_assessments_reject_mutation;

commit;
SQL

assert_eq "$(scalar 'select count(*) from knowledge.claims')" '2' \
  'fiksturen skal ha én gammel og én ny, semantisk legacy-lik påstand'
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'fiksturen skal fortsatt bare ha de to autoriserte evidensrøttene'
assert_eq "$(scalar "select count(*) from knowledge.claim_revisions where revision_number=1 and agent_run_id='10300000-0000-4000-8000-000000000001'")" '1' \
  'den nye påstanden skal kunne kjennes igjen på agentkjørings-proveniens'
assert_eq "$(scalar "select count(*) from audit.events ae join knowledge.claim_revisions r on r.id=ae.object_id where ae.operation='claim_revision_created' and r.agent_run_id='10300000-0000-4000-8000-000000000001'")" '1' \
  'den nye påstanden skal ha revisjonsaudit som en historisk migrasjonsrad ikke har'
assert_eq "$(scalar 'select count(*) from knowledge.publication_events')" '0' \
  'fiksturen skal ikke stoppes av publiseringshistorikk i stedet for lineage-kontrollen'
assert_eq "$(scalar 'select count(*) from workflow.review_decisions')" '0' \
  'fiksturen skal ikke stoppes av formell review i stedet for lineage-kontrollen'
assert_eq "$(scalar 'select count(*) from workflow.claim_verifications')" '0' \
  'fiksturen skal ikke stoppes av claim-verifikasjon i stedet for lineage-kontrollen'
assert_eq "$(scalar "select count(*) from provenance.agent_runs where status='running'")" '0' \
  'fiksturen skal ikke stoppes av en åpen agentkjøring i stedet for lineage-kontrollen'

if npx --no-install supabase migration up --local >"$TMP_DIR/replacement-claim.log" 2>&1; then
  cat "$TMP_DIR/replacement-claim.log" >&2
  fail 'resetten godtok en ny påstandsrot bare fordi den lignet legacy-prototypen'
fi

assert_eq "$(scalar 'select count(*) from knowledge.claims')" '2' \
  'stopptesten etterlot delvis slettede påstander'
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'stopptesten etterlot delvis slettet evidens'
assert_eq "$(scalar "select coalesce(to_regprocedure('knowledge.assert_antidep2_reset_preconditions()')::text, '')")" '' \
  'stopptesten etterlot vedlikeholdsfunksjonen fra en rullet tilbake preflight'
assert_eq "$(scalar "select coalesce(to_regclass('audit.prototype_resets')::text, '')")" '' \
  'stopptesten etterlot et snapshot fra en rullet tilbake reset'

printf 'OK: ny agentopprettet erstatningspåstand stopper resetten før endringer.\n'
