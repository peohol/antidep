#!/usr/bin/env bash
# Fail-closed regression: a newly extracted evidence item for the same legacy
# source/drug/outcome is NOT one of the two historical prototype roots.
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

printf 'Antidep 2: stopptest for ny ekstraksjon med legacy-lik kildeidentitet.\n'
npx --no-install supabase db reset --version "$LAST_LEGACY" --no-seed >/dev/null

assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'legacy-fiksturen skal starte med to historiske evidensrøtter'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" '2' \
  'legacy-fiksturen skal starte med to historiske påstandsrøtter'

# Reproduce the evidence-side version of the dangerous review scenario. Remove
# the historical sertraline claim and evidence artifact, then run the current
# extraction path against the SAME legacy abstract source version, drug and
# outcome. Without an explicit lineage check the new row would again leave the
# database with exactly two semantically legacy-looking evidence roots.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
begin;

create temporary table fixture (
  name text primary key,
  id uuid,
  text_value text
) on commit drop;

insert into fixture(name, id)
select 'drug', d.id from catalog.drugs d where d.canonical_name = 'sertralin';
insert into fixture(name, id)
select 'outcome', c.id from catalog.clinical_concepts c where c.canonical_label = 'vektendring';
insert into fixture(name, id)
select 'old_evidence', e.id
from knowledge.evidence_items e
join catalog.drugs d on d.id = e.intervention_drug_id
where d.canonical_name = 'sertralin';
insert into fixture(name, id)
select 'source', e.source_id
from knowledge.evidence_items e
join catalog.drugs d on d.id = e.intervention_drug_id
where d.canonical_name = 'sertralin';
insert into fixture(name, id)
select 'source_version', e.source_version_id
from knowledge.evidence_items e
join catalog.drugs d on d.id = e.intervention_drug_id
where d.canonical_name = 'sertralin';

create temporary table old_claim(id uuid primary key) on commit drop;
insert into old_claim(id)
select cl.id
from knowledge.claims cl
join catalog.drugs d on d.id = cl.subject_drug_id
where d.canonical_name = 'sertralin';

create temporary table cred(secret text not null) on commit drop;
insert into cred(secret)
select provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman'
);
grant select on fixture, cred to anon;

-- First remove the historical sertraline branch. This is test-only maintenance
-- setup that mirrors the state the guarded discard paths can eventually leave;
-- the production write paths remain untouched.
alter table knowledge.evidence_assessments disable trigger evidence_assessments_reject_mutation;
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_reject_mutation;
alter table knowledge.claim_revisions disable trigger claim_revisions_reject_mutation;
alter table workflow.evidence_verifications disable trigger evidence_verifications_reject_mutation;
alter table knowledge.evidence_field_groundings disable trigger evidence_field_groundings_reject_mutation;
alter table knowledge.evidence_items disable trigger evidence_items_reject_mutation;

delete from knowledge.evidence_assessments
where claim_revision_id in (
  select r.id from knowledge.claim_revisions r join old_claim x on x.id = r.claim_id
);
delete from knowledge.claim_evidence_links
where claim_revision_id in (
  select r.id from knowledge.claim_revisions r join old_claim x on x.id = r.claim_id
);
delete from knowledge.claim_revisions
where claim_id in (select id from old_claim);
delete from knowledge.claims
where id in (select id from old_claim);
delete from workflow.evidence_verifications
where evidence_item_id = (select id from fixture where name = 'old_evidence');
delete from knowledge.evidence_field_groundings
where evidence_item_id = (select id from fixture where name = 'old_evidence');
delete from knowledge.evidence_items
where id = (select id from fixture where name = 'old_evidence');

alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;
alter table knowledge.evidence_field_groundings enable trigger evidence_field_groundings_reject_mutation;
alter table workflow.evidence_verifications enable trigger evidence_verifications_reject_mutation;
alter table knowledge.claim_revisions enable trigger claim_revisions_reject_mutation;
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_mutation;
alter table knowledge.evidence_assessments enable trigger evidence_assessments_reject_mutation;

create temporary table run(id uuid not null) on commit drop;
grant select, insert on run to anon;

set local role anon;
insert into run(id)
select api.begin_agent_run(
  p_identity_key := 'agent-identity:evidence-extraction-01',
  p_secret := (select secret from cred),
  p_agent_role := 'evidence_extraction',
  p_provider := 'antidep',
  p_model := 'replacement-evidence-regression',
  p_model_version := '1.0.0',
  p_prompt_template_version := 'evidence-extraction/regression/1',
  p_pipeline_version := 'antidep-evidence/1',
  p_input_manifest := jsonb_build_object('mode', 'replacement-evidence-regression'),
  p_input_source_version_id := (select id from fixture where name = 'source_version')
);

select api.register_agent_extraction(
  p_identity_key => 'agent-identity:evidence-extraction-01',
  p_secret => (select secret from cred),
  p_agent_run_id => (select id from run),
  p_source_id => (select id from fixture where name = 'source'),
  p_source_version_id => (select id from fixture where name = 'source_version'),
  p_design_code => 'randomized_controlled_trial',
  p_population_availability => 'not_reported',
  p_population_detail => 'Ny ekstraksjon fra samme historiske abstract-kilde.',
  p_sample_size_availability => 'not_reported',
  p_intervention_drug_id => (select id from fixture where name = 'drug'),
  p_comparator_kind => 'none',
  p_outcome_concept_id => (select id from fixture where name = 'outcome'),
  p_outcome_detail => 'Vektendring, ny ekstraksjon fra samme abstract.',
  p_timepoint_availability => 'not_reported',
  p_reported_direction => 'increase',
  p_estimate_availability => 'not_reported',
  p_confidence_interval_availability => 'not_reported',
  p_source_locator => 'Abstract, regresjonsfikstur for evidens-lineage',
  p_extraction_method => 'ai_assisted',
  p_field_groundings => jsonb_build_array(
    jsonb_build_object(
      'check_field', 'intervention_arm',
      'source_excerpt', 'Patients received sertraline.',
      'source_locator', 'Abstract',
      'justification', 'Virkestoffet er eksplisitt angitt.'
    ),
    jsonb_build_object(
      'check_field', 'outcome',
      'source_excerpt', 'Weight change was assessed.',
      'source_locator', 'Abstract',
      'justification', 'Utfallet er eksplisitt angitt.'
    ),
    jsonb_build_object(
      'check_field', 'reported_direction',
      'source_excerpt', 'Weight increased during treatment.',
      'source_locator', 'Abstract',
      'justification', 'Retningen er eksplisitt angitt.'
    ),
    jsonb_build_object(
      'check_field', 'availability_semantics',
      'source_excerpt', 'The abstract does not report the analysis sample size.',
      'source_locator', 'Abstract',
      'justification', 'Manglende tall er registrert som ikke rapportert.'
    )
  ),
  p_source_quote => 'Weight increased during treatment with sertraline.'
);

select api.complete_agent_run(
  'agent-identity:evidence-extraction-01',
  (select secret from cred),
  (select id from run),
  'succeeded',
  '{"registered":true,"mode":"replacement-evidence-regression"}'::jsonb,
  null
);
reset role;

commit;
SQL

assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'fiksturen skal igjen ha nøyaktig to semantisk legacy-liknende evidensrøtter'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" '1' \
  'fiksturen skal bare ha den andre historiske påstandsroten igjen'
assert_eq "$(scalar "select count(*) from knowledge.evidence_items where agent_run_id is not null")" '1' \
  'den nye evidensroten skal kunne kjennes igjen på agentkjørings-proveniens'
assert_eq "$(scalar "select count(*) from audit.events ae join knowledge.evidence_items e on e.id=ae.object_id where ae.operation='evidence_item_created' and e.agent_run_id is not null")" '1' \
  'den nye evidensroten skal ha creation-audit som de historiske migrasjonsradene mangler'
assert_eq "$(scalar "select count(*) from provenance.agent_runs where status='running'")" '0' \
  'fiksturen skal ikke stoppes av en åpen agentkjøring i stedet for lineage-kontrollen'
assert_eq "$(scalar 'select count(*) from knowledge.publication_events')" '0' \
  'fiksturen skal ikke stoppes av publiseringshistorikk i stedet for lineage-kontrollen'
assert_eq "$(scalar 'select count(*) from workflow.review_decisions')" '0' \
  'fiksturen skal ikke stoppes av formell review i stedet for lineage-kontrollen'

if npx --no-install supabase migration up --local >"$TMP_DIR/replacement-evidence.log" 2>&1; then
  cat "$TMP_DIR/replacement-evidence.log" >&2
  fail 'resetten godtok en ny evidensrot bare fordi kilde og klinisk identitet lignet legacy-prototypen'
fi

assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'stopptesten etterlot delvis slettet evidens'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" '1' \
  'stopptesten etterlot delvis slettede påstander'
assert_eq "$(scalar "select coalesce(to_regprocedure('knowledge.assert_antidep2_reset_preconditions()')::text, '')")" '' \
  'stopptesten etterlot vedlikeholdsfunksjonen fra en rullet tilbake preflight'
assert_eq "$(scalar "select coalesce(to_regclass('audit.prototype_resets')::text, '')")" '' \
  'stopptesten etterlot et snapshot fra en rullet tilbake reset'

printf 'OK: ny agentopprettet erstatningsevidens stopper resetten før endringer.\n'
