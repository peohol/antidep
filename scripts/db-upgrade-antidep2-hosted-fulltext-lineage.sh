#!/usr/bin/env bash
# Regression test for the lineage the hosted database actually has.
#
# The repo baseline still holds the originally seeded, abstract-rooted prototype.
# Production does not: on 2026-09-12 the owner discarded the abstract-derived
# findings and the claims made from them (audit.events, operations
# extraction_artifact_discarded and claim_artifact_discarded, issue #84) and the
# two studies were re-extracted from their registered full text, all before the
# reset was authorized on 2026-09-14. This test reproduces exactly that shape and
# asserts that the reset accepts it, and that every perturbation of it is refused
# before a single row is deleted.
set -euo pipefail
cd "$(dirname "$0")/.."

LAST_LEGACY=20260924095000
AUTHORIZED_AT='2026-09-14T08:46:42Z'
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

DB_URL=$(npx --no-install supabase status -o json 2>/dev/null | node -e '
  let data = ""
  process.stdin.on("data", (chunk) => (data += chunk)).on("end", () => {
    try { process.stdout.write(JSON.parse(data).DB_URL ?? "") } catch { process.stdout.write("") }
  })
')

# Never allow this upgrade fixture to point at a hosted database.
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

reset_legacy() {
  npx --no-install supabase db reset --version "$LAST_LEGACY" --no-seed >/dev/null
}

assert_preflight_left_no_partial_rollout() {
  assert_eq "$(scalar "select coalesce(to_regprocedure('knowledge.assert_clinical_full_text(uuid,uuid)')::text, '')")" '' \
    'stopptesten etterlot fulltekstvakten halvveis installert'
  assert_eq "$(scalar "select coalesce(to_regprocedure('knowledge.assert_antidep2_reset_preconditions()')::text, '')")" '' \
    'stopptesten etterlot vedlikeholdsfunksjonen fra en rullet tilbake preflight'
  assert_eq "$(scalar "select coalesce(to_regclass('audit.prototype_resets')::text, '')")" '' \
    'stopptesten etterlot et snapshot fra en rullet tilbake reset'
}

# Rewrites the seeded prototype graph into the hosted shape. The arguments are
# the single-axis perturbations the negative scenarios need, so the positive and
# negative cases are always the same fixture:
#
#   $1 audit_shift    interval added to every creation-audit timestamp
#   $2 digest_suffix  appended to the extraction runs' model-request digest
#   $3 version_shift  interval added to the full-text source versions' created_at
#   $4 orphan_audit   'true' adds a post-authorization creation audit for a row
#                     that does not exist
#
# The append-only guards, the content-hash writers and the audit clock are
# suspended only inside this transaction and only for the fixture's own rows. No
# production write path can reach any of this; reproducing a historical state is
# maintenance-only test setup, exactly as in the sibling stop tests.
apply_hosted_fixture() {
  local audit_shift=$1 digest_suffix=$2 version_shift=$3 orphan_audit=$4
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<SQL
begin;

alter table knowledge.source_versions disable trigger source_versions_set_row_timestamps;
alter table knowledge.source_versions disable trigger source_versions_record_registration_audit_event;
alter table provenance.agent_runs disable trigger agent_runs_set_row_timestamps;
alter table knowledge.evidence_items disable trigger evidence_items_reject_mutation;
alter table knowledge.evidence_assessments disable trigger evidence_assessments_reject_mutation;
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_reject_mutation;
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_set_created_at;
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_reject_after_assessment;
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_reject_after_publication;
alter table knowledge.claim_revisions disable trigger claim_revisions_reject_mutation;
alter table knowledge.claim_revisions disable trigger claim_revisions_set_created_at;
alter table knowledge.claim_revisions disable trigger claim_revisions_set_content_hash;
alter table knowledge.claim_revisions disable trigger claim_revisions_record_creation_audit_event;
alter table knowledge.claim_revisions disable trigger claim_revisions_enforce_supersedes_order;
alter table audit.events disable trigger events_set_created_at;

-- The immutable identities the hosted prototype roots actually carry. These are
-- read straight out of production: the content hash and grounding digest of each
-- re-extraction, and the model-request digest of the extraction run that made it.
create temporary table hosted on commit drop as
select * from (values
  (
    'sertralin',
    '5e100000-0000-4000-8000-000000000001'::uuid,
    '5e100000-0000-4000-8000-000000000011'::uuid,
    'sha256:43971be1e4a28cd1ce5d1d55456256762fa9cd56fa6fb4d8a7c69399e5850810',
    'sha256-v3:cc4fc45130204ea17ff3456d10a94f00125008ed2f93e24e0cc2b5a5f09d1e12',
    'sha256-v1:444d6bd33d1be8edd9626fedde14a4b40b8cac24ef6a8308ab07072fcc91924a',
    timestamptz '2026-09-12T19:23:11Z',
    timestamptz '2026-09-12T19:41:53Z'
  ),
  (
    'mirtazapin',
    '5e100000-0000-4000-8000-000000000002'::uuid,
    '5e100000-0000-4000-8000-000000000012'::uuid,
    'sha256:67296bc917398cd95de2bb8cb9e0167e3cb7bb0112a7d11e5690322f46650fc0',
    'sha256-v3:a271c1c7917ba9bf493e74b106d7d91c5826dab04a61a77a69f103f82307ae3b',
    'sha256-v1:2574bc207d68e1e844f76ef453d75e59c39725d177a8ffcb3fea1afe30eb25a6',
    timestamptz '2026-09-12T10:18:03Z',
    timestamptz '2026-09-12T20:39:56Z'
  )
) as t(drug, source_version_id, run_id, request_digest, content_hash,
       grounding_digest, version_created_at, extracted_at);

create temporary table hosted_revision on commit drop as
select * from (values
  (1, '5e100000-0000-4000-8000-000000000021'::uuid, timestamptz '2026-09-13T02:19:23Z'),
  (2, '5e100000-0000-4000-8000-000000000022'::uuid, timestamptz '2026-09-13T05:18:17Z')
) as t(revision_number, run_id, synthesised_at);

-- 1. A full-text representation of each anchored legacy source, registered
--    before the reset was authorized.
insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash, representation,
  retrieved_by_actor_id, document_sha256, document_byte_size, document_media_type,
  text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
  text_extraction_transform, created_at, updated_at
)
select
  h.source_version_id,
  e.source_id,
  h.version_created_at,
  'https://doi.org/10.0000/antidep2-' || h.drug,
  'sha256:' || encode(extensions.digest(h.drug || '-fulltekst', 'sha256'), 'hex'),
  'full_text',
  sv.retrieved_by_actor_id,
  'sha256:' || encode(extensions.digest(h.drug || '-dokument', 'sha256'), 'hex'),
  55291,
  'application/pdf',
  'pdftotext',
  'pdftotext 24.02.0',
  '-bbox-layout -enc UTF-8 -eol unix',
  'antidep-reading-order@2',
  h.version_created_at + ($version_shift),
  h.version_created_at + ($version_shift)
from hosted h
join catalog.drugs d on d.canonical_name = h.drug
join knowledge.evidence_items e on e.intervention_drug_id = d.id
join knowledge.source_versions sv on sv.id = e.source_version_id;

-- 2. The succeeded extraction run behind each re-extraction.
insert into provenance.agent_runs (
  id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
  prompt_template_version, pipeline_version, status, input_manifest,
  output_manifest, input_source_version_id, started_at, created_at, completed_at,
  updated_at
)
select
  h.run_id, ai.id, ai.actor_id, 'evidence_extraction', 'antidep',
  'proposal-grounded-extraction', '1.1.0', 'evidence-extraction/proposal/1',
  'antidep-evidence/1', 'succeeded',
  jsonb_build_object(
    'source_version_id', h.source_version_id,
    'extraction_method', 'ai_assisted',
    'generated_by', jsonb_build_object(
      'producer', 'model',
      'provider', 'anthropic',
      'request_digest', h.request_digest || '$digest_suffix'
    )
  ),
  jsonb_build_object('evidence_item_id', h.run_id, 'request_digest_checked', true),
  h.source_version_id,
  h.extracted_at, h.extracted_at,
  h.extracted_at + interval '1 second', h.extracted_at + interval '1 second'
from hosted h
join provenance.agent_identities ai
  on ai.identity_key = 'agent-identity:evidence-extraction-01';

-- 3. Re-point each prototype root at its full-text re-extraction, with the exact
--    immutable identity the hosted row carries.
update knowledge.evidence_items e
set source_version_id = h.source_version_id,
    content_hash = h.content_hash,
    grounding_digest = h.grounding_digest,
    agent_run_id = h.run_id,
    agent_run_role = 'evidence_extraction',
    created_at = h.extracted_at
from catalog.drugs d
join hosted h on h.drug = d.canonical_name
where d.id = e.intervention_drug_id;

-- 4. The hosted database has exactly one surviving synthesis root: the
--    sertraline claim and everything derived from it was discarded.
create temporary table discarded_claim on commit drop as
select cl.id
from knowledge.claims cl
join catalog.drugs d on d.id = cl.subject_drug_id
where d.canonical_name = 'sertralin';

delete from knowledge.evidence_assessments
where claim_revision_id in (
  select r.id from knowledge.claim_revisions r join discarded_claim x on x.id = r.claim_id
);
delete from knowledge.claim_evidence_links;
delete from knowledge.claim_revisions where claim_id in (select id from discarded_claim);
delete from knowledge.claims where id in (select id from discarded_claim);

-- 5. The two synthesis runs behind the surviving claim's two revisions.
insert into provenance.agent_runs (
  id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
  prompt_template_version, pipeline_version, status, input_manifest,
  output_manifest, started_at, created_at, completed_at, updated_at
)
select
  v.run_id, ai.id, ai.actor_id, 'claim_synthesis', 'antidep',
  'proposal-grounded-synthesis', '1.0.0', 'claim-synthesis/proposal/1',
  'antidep-claims/1', 'succeeded',
  jsonb_build_object('revision_number', v.revision_number),
  jsonb_build_object('registered', true),
  v.synthesised_at, v.synthesised_at,
  v.synthesised_at + interval '1 second', v.synthesised_at + interval '1 second'
from hosted_revision v
join provenance.agent_identities ai
  on ai.identity_key = 'agent-identity:claim-synthesis-01';

update knowledge.claim_revisions r
set content_hash = 'sha256-v1:f551ac1d26a15a1cd84dba7a44c40c4ede5621796e2bc307f51bd4e0ef4ed052',
    agent_run_id = v.run_id,
    agent_run_role = 'claim_synthesis',
    created_at = v.synthesised_at
from hosted_revision v
where v.revision_number = 1 and r.revision_number = 1;

-- Revision 2 reproduced the same statement, so it carries the same content
-- identity. Copying the row keeps every other column exactly as the seeded
-- revision had it.
create temporary table hosted_revision_two on commit drop as
select * from knowledge.claim_revisions where revision_number = 1;

update hosted_revision_two
set id = '5e100000-0000-4000-8000-000000000031',
    revision_number = 2,
    supersedes_revision_id = (
      select id from knowledge.claim_revisions where revision_number = 1
    ),
    agent_run_id = (select run_id from hosted_revision where revision_number = 2),
    created_at = (select synthesised_at from hosted_revision where revision_number = 2);

insert into knowledge.claim_revisions select * from hosted_revision_two;

insert into knowledge.claim_evidence_links (
  claim_revision_id, evidence_item_id, relationship_type, directness,
  relevance_note, created_by_actor_id, created_at
)
select
  r.id, e.id, 'supports', 'indirect',
  'Fiksturbinding: mirtazapinfunnet underbygger retningen i den registrerte paastanden.',
  a.id, r.created_at
from knowledge.claim_revisions r
join knowledge.claims cl on cl.id = r.claim_id
join knowledge.evidence_items e on e.intervention_drug_id = cl.subject_drug_id
join provenance.actors a on a.actor_key = 'agent:claim-synthesis';

-- 6. The append-only creation audit the trigger would have written at the time.
--    This is the clock every lineage check rests on.
insert into audit.events (
  operation, object_id, actor_id, object_schema, object_table,
  new_revision_or_snapshot, occurred_at, created_at
)
select
  'evidence_item_created', e.id, e.created_by_actor_id, 'knowledge',
  'evidence_items', to_jsonb(e), h.extracted_at + ($audit_shift),
  h.extracted_at + ($audit_shift)
from knowledge.evidence_items e
join catalog.drugs d on d.id = e.intervention_drug_id
join hosted h on h.drug = d.canonical_name;

insert into audit.events (
  operation, object_id, actor_id, object_schema, object_table,
  new_revision_or_snapshot, occurred_at, created_at
)
select
  'claim_revision_created', r.id, r.created_by_actor_id, 'knowledge',
  'claim_revisions', to_jsonb(r), r.created_at + ($audit_shift),
  r.created_at + ($audit_shift)
from knowledge.claim_revisions r;

-- An optional creation audit for a row that no longer exists. The hosted
-- database is full of these, because every discarded prototype artifact keeps
-- its creation audit forever. They must never be able to block their own reset.
insert into audit.events (
  operation, object_id, actor_id, object_schema, object_table,
  new_revision_or_snapshot, occurred_at, created_at
)
select
  'evidence_item_created', '5e100000-0000-4000-8000-0000000000ff'::uuid, a.id,
  'knowledge', 'evidence_items',
  jsonb_build_object('id', '5e100000-0000-4000-8000-0000000000ff'),
  timestamptz '$AUTHORIZED_AT' + interval '3 days',
  timestamptz '$AUTHORIZED_AT' + interval '3 days'
from provenance.actors a
where a.actor_key = 'agent:evidence-extraction' and $orphan_audit;

alter table audit.events enable trigger events_set_created_at;
alter table knowledge.claim_revisions enable trigger claim_revisions_enforce_supersedes_order;
alter table knowledge.claim_revisions enable trigger claim_revisions_record_creation_audit_event;
alter table knowledge.claim_revisions enable trigger claim_revisions_set_content_hash;
alter table knowledge.claim_revisions enable trigger claim_revisions_set_created_at;
alter table knowledge.claim_revisions enable trigger claim_revisions_reject_mutation;
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_after_publication;
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_after_assessment;
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_set_created_at;
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_mutation;
alter table knowledge.evidence_assessments enable trigger evidence_assessments_reject_mutation;
alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;
alter table provenance.agent_runs enable trigger agent_runs_set_row_timestamps;
alter table knowledge.source_versions enable trigger source_versions_record_registration_audit_event;
alter table knowledge.source_versions enable trigger source_versions_set_row_timestamps;

commit;
SQL
}

assert_hosted_shape() {
  assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
    'fiksturen skal ha nøyaktig de to hostede evidensrøttene'
  assert_eq "$(scalar "select count(*) from knowledge.evidence_items e join knowledge.source_versions sv on sv.id = e.source_version_id where sv.representation = 'full_text'")" '2' \
    'de hostede evidensrøttene skal peke på fulltekstrepresentasjoner'
  assert_eq "$(scalar 'select count(*) from knowledge.evidence_items where agent_run_id is not null')" '2' \
    'de hostede evidensrøttene skal være agentopprettede'
  assert_eq "$(scalar "select count(*) from audit.events ae join knowledge.evidence_items e on e.id = ae.object_id where ae.operation = 'evidence_item_created'")" '2' \
    'de hostede evidensrøttene skal ha creation-audit'
  assert_eq "$(scalar 'select count(*) from knowledge.claims')" '1' \
    'fiksturen skal ha den ene gjenstående hostede påstandsroten'
  assert_eq "$(scalar 'select count(*) from knowledge.claim_revisions')" '2' \
    'den hostede påstandsroten skal ha to revisjoner'
  # Nothing may stop the upgrade for a reason other than the lineage rules.
  assert_eq "$(scalar 'select count(*) from knowledge.publication_events')" '0' \
    'fiksturen skal ikke ha publiseringshistorikk'
  assert_eq "$(scalar 'select count(*) from workflow.review_decisions')" '0' \
    'fiksturen skal ikke ha formell review'
  assert_eq "$(scalar 'select count(*) from workflow.claim_verifications')" '0' \
    'fiksturen skal ikke ha påstandskontroll'
  assert_eq "$(scalar "select count(*) from provenance.agent_runs where status = 'running'")" '0' \
    'fiksturen skal ikke ha åpen agentkjøring'
}

expect_refusal() {
  local label=$1 message=$2
  local before_evidence before_claims
  before_evidence=$(scalar 'select count(*) from knowledge.evidence_items')
  before_claims=$(scalar 'select count(*) from knowledge.claims')
  if npx --no-install supabase migration up --local >"$TMP_DIR/$label.log" 2>&1; then
    cat "$TMP_DIR/$label.log" >&2
    fail "$message"
  fi
  grep -q '23001' "$TMP_DIR/$label.log" || {
    cat "$TMP_DIR/$label.log" >&2
    fail "scenarioet $label stoppet av noe annet enn omfangsvakten"
  }
  assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" "$before_evidence" \
    "scenarioet $label etterlot delvis slettet evidens"
  assert_eq "$(scalar 'select count(*) from knowledge.claims')" "$before_claims" \
    "scenarioet $label etterlot delvis slettede påstander"
  assert_preflight_left_no_partial_rollout
}

printf 'Antidep 2: oppgraderingsprøve for hostet fulltekst-lineage.\n'

# 1. Positive: exactly the hosted shape. The reset is authorized for it, and the
#    private recovery snapshot must cover every row it removes.
reset_legacy
apply_hosted_fixture "interval '0'" '' "interval '0'" 'false'
assert_hosted_shape
before_evidence=$(scalar 'select count(*) from knowledge.evidence_items')
before_claims=$(scalar 'select count(*) from knowledge.claims')
before_revisions=$(scalar 'select count(*) from knowledge.claim_revisions')
before_sources=$(scalar 'select count(*) from knowledge.sources')
before_versions=$(scalar 'select count(*) from knowledge.source_versions')
before_runs=$(scalar 'select count(*) from provenance.agent_runs')
if ! npx --no-install supabase migration up --local >"$TMP_DIR/hosted-accepted.log" 2>&1; then
  cat "$TMP_DIR/hosted-accepted.log" >&2
  fail 'den faktiske hostede legacy-lineagen ble feilaktig avvist'
fi
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '0' \
  'resetten lot hostede evidensrøtter stå aktive'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" '0' \
  'resetten lot den hostede påstandsroten stå aktiv'
assert_eq "$(scalar 'select count(*) from audit.prototype_resets')" '1' \
  'resetten skrev ikke nøyaktig ett gjenopprettingssnapshot'
assert_eq "$(scalar "select (row_counts ->> 'evidence_items')::bigint from audit.prototype_resets")" "$before_evidence" \
  'snapshotet dekker ikke de hostede evidensrøttene'
assert_eq "$(scalar "select (row_counts ->> 'claims')::bigint from audit.prototype_resets")" "$before_claims" \
  'snapshotet dekker ikke den hostede påstandsroten'
assert_eq "$(scalar "select (row_counts ->> 'claim_revisions')::bigint from audit.prototype_resets")" "$before_revisions" \
  'snapshotet dekker ikke revisjonene av den hostede påstandsroten'
# Sources, immutable snapshots and provenance are never part of the reset.
assert_eq "$(scalar 'select count(*) from knowledge.sources')" "$before_sources" \
  'resetten endret kildebiblioteket'
assert_eq "$(scalar 'select count(*) from knowledge.source_versions')" "$before_versions" \
  'resetten slettet uforanderlige kildesnapshots'
assert_eq "$(scalar "select count(*) from knowledge.source_versions sv join knowledge.source_identifiers si on si.source_id = sv.source_id where si.identifier_system = 'pmid' and si.identifier_value in ('11105740', '15697327') and sv.representation = 'abstract'")" '2' \
  'resetten fjernet de uforanderlige legacy-snapshotene resten av sporet hviler på'
assert_eq "$(scalar 'select count(*) from provenance.agent_runs')" "$before_runs" \
  'resetten slettet agentproveniens'
printf 'OK: den faktiske hostede fulltekst-lineagen autoriseres.\n'

# 2. Negative: the same rows, created after the owner authorized the reset. This
#    is the decisive boundary — a later agent extraction and a later synthesis
#    are content nobody authorized deleting, however legacy-like they look.
reset_legacy
apply_hosted_fixture "interval '30 days'" '' "interval '0'" 'false'
assert_hosted_shape
assert_eq "$(scalar "select count(*) from audit.events ae join knowledge.evidence_items e on e.id = ae.object_id where ae.operation = 'evidence_item_created' and ae.occurred_at >= timestamptz '$AUTHORIZED_AT'")" '2' \
  'fiksturen klarte ikke å plassere creation-audit etter autoriseringen'
expect_refusal post-authorization \
  'resetten godtok klinisk innhold opprettet etter at den ble autorisert'
printf 'OK: innhold opprettet etter autoriseringen stopper resetten.\n'

# 3. Negative: the same content, re-extracted. A replacement run reproduces the
#    content hash by design, so only the model-request digest separates the
#    authorized historical extraction from a new one.
reset_legacy
apply_hosted_fixture "interval '0'" 'ny-kjoring' "interval '0'" 'false'
assert_hosted_shape
assert_eq "$(scalar "select count(*) from provenance.agent_runs where agent_role = 'evidence_extraction' and input_manifest -> 'generated_by' ->> 'request_digest' like '%ny-kjoring'")" '2' \
  'fiksturen klarte ikke å endre modellforespørselens avtrykk'
expect_refusal replacement-request-digest \
  'resetten godtok en ny ekstraksjon med samme innholdsavtrykk som den autoriserte'
printf 'OK: en reekstraksjon med nytt forespørselsavtrykk stopper resetten.\n'

# 4. Negative: the full text was registered after the authorization, so no
#    authorized root can rest on it.
reset_legacy
apply_hosted_fixture "interval '0'" '' "interval '30 days'" 'false'
assert_hosted_shape
assert_eq "$(scalar "select count(*) from knowledge.source_versions where representation = 'full_text' and created_at >= timestamptz '$AUTHORIZED_AT'")" '2' \
  'fiksturen klarte ikke å registrere fulltekstversjonen etter autoriseringen'
expect_refusal late-source-version \
  'resetten godtok en evidensrot forankret i en fulltekst registrert etter autoriseringen'
printf 'OK: fulltekst registrert etter autoriseringen stopper resetten.\n'

# 5. Positive: a creation audit whose row no longer exists is history, not
#    content. The hosted database keeps one for every discarded prototype
#    artifact, and they must not be able to block their own reset.
reset_legacy
apply_hosted_fixture "interval '0'" '' "interval '0'" 'true'
assert_hosted_shape
assert_eq "$(scalar "select count(*) from audit.events ae where ae.operation = 'evidence_item_created' and ae.occurred_at >= timestamptz '$AUTHORIZED_AT' and not exists (select 1 from knowledge.evidence_items e where e.id = ae.object_id)")" '1' \
  'fiksturen klarte ikke å etterlate en creation-audit uten rad'
if ! npx --no-install supabase migration up --local >"$TMP_DIR/orphan-audit.log" 2>&1; then
  cat "$TMP_DIR/orphan-audit.log" >&2
  fail 'en creation-audit for en slettet rad blokkerte resetten'
fi
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '0' \
  'resetten lot hostede evidensrøtter stå aktive'
printf 'OK: creation-audit for en slettet rad blokkerer ikke resetten.\n'

printf 'Oppgraderingsprøven for hostet fulltekst-lineage gikk gjennom.\n'
