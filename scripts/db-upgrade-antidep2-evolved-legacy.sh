#!/usr/bin/env bash
# Regression test for the hosted legacy state that evolved after the original
# two-study prototype was seeded, but before the Antidep 2 reset was deployed.
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

printf 'Antidep 2: oppgraderingsprøve for videreutviklet legacy-prototype.\n'

npx --no-install supabase db reset --version "$LAST_LEGACY" --no-seed >/dev/null

assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'legacy-fiksturen skal starte med to evidensrøtter'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" '2' \
  'legacy-fiksturen skal starte med to påstandsrøtter'
assert_eq "$(scalar "select count(*) from knowledge.evidence_items e join knowledge.source_versions sv on sv.id=e.source_version_id where sv.representation='abstract'")" '2' \
  'begge legacy-evidensrøttene skal fortsatt være abstract-baserte'

# Reproduce the important shape of the hosted database without copying hosted
# data into CI: one old claim has been removed, while the surviving abstract
# evidence graph has received later field grounding and source verification.
# The bibliographic title is also corrected/normalized, which is explicitly
# allowed for knowledge.sources and must not change the source's stable identity.
# These rows are still descendants of the two pre-Antidep-2 roots. There is no
# publication, formal review or claim-level verification.
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
begin;

create temporary table evolved_removed_claim(id uuid primary key) on commit drop;
insert into evolved_removed_claim(id)
select cl.id
from knowledge.claims cl
join catalog.drugs d on d.id = cl.subject_drug_id
where d.canonical_name = 'mirtazapin';

alter table knowledge.evidence_assessments disable trigger evidence_assessments_reject_mutation;
alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_reject_mutation;
alter table knowledge.claim_revisions disable trigger claim_revisions_reject_mutation;

delete from knowledge.evidence_assessments
where claim_revision_id in (
  select r.id
  from knowledge.claim_revisions r
  join evolved_removed_claim x on x.id = r.claim_id
);

delete from knowledge.claim_evidence_links
where claim_revision_id in (
  select r.id
  from knowledge.claim_revisions r
  join evolved_removed_claim x on x.id = r.claim_id
);

delete from knowledge.claim_revisions
where claim_id in (select id from evolved_removed_claim);

delete from knowledge.claims
where id in (select id from evolved_removed_claim);

alter table knowledge.claim_revisions enable trigger claim_revisions_reject_mutation;
alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_mutation;
alter table knowledge.evidence_assessments enable trigger evidence_assessments_reject_mutation;

-- A source title is correction metadata, not source identity. Simulate the
-- production drift that exposed the brittle byte-for-byte title comparison.
update knowledge.sources s
set title = s.title || ' [normalisert bibliografisk tittel]'
where s.id in (
  select e.source_id
  from knowledge.evidence_items e
  join catalog.drugs d on d.id = e.intervention_drug_id
  where d.canonical_name = 'sertralin'
);

insert into knowledge.evidence_field_groundings (
  evidence_item_id, created_by_actor_id, check_field,
  source_excerpt, source_locator, justification
)
select e.id, e.created_by_actor_id, 'source_locator',
       'Syntetisk utdrag fra den gamle abstract-prototypen.',
       'Legacy abstract, regresjonsfikstur',
       'Regresjonsfikstur som representerer videre arbeid på den gamle prototypen.'
from knowledge.evidence_items e
join catalog.drugs d on d.id = e.intervention_drug_id
where d.canonical_name = 'sertralin';

-- Grounding became part of the evidence identity in migration 003d. The hosted
-- rows received their matching technical digest/content hash when they were
-- created. Because this fixture deliberately evolves an older seeded row in
-- place, update only those database-owned technical fields under the same
-- explicit maintenance guard used by the historical rehash migration.
alter table knowledge.evidence_items disable trigger evidence_items_reject_mutation;
update knowledge.evidence_items e
set grounding_digest = knowledge.evidence_item_grounding_digest(e.id)
from catalog.drugs d
where d.id = e.intervention_drug_id
  and d.canonical_name = 'sertralin';
update knowledge.evidence_items e
set content_hash = knowledge.evidence_item_content_hash(e.*)
from catalog.drugs d
where d.id = e.intervention_drug_id
  and d.canonical_name = 'sertralin';
alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;

insert into workflow.evidence_verifications (
  evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
  outcome, source_access, checked_fields, findings, rationale, verified_at,
  verified_grounding_digest
)
select e.id, e.created_by_actor_id, verifier.id,
       'uncertain', 'verifiable_representation',
       array['source_locator']::workflow.evidence_check_field[],
       'Regresjonsfikstur: kontrollen er bevisst ikke en bekreftelse.',
       'Regresjonsfikstur: senere kontroll av den gamle abstract-prototypen.', now(),
       workflow.evidence_grounding_digest(e.id)
from knowledge.evidence_items e
join catalog.drugs d on d.id = e.intervention_drug_id
join provenance.actors verifier on verifier.actor_key = 'agent:extraction-verification'
where d.canonical_name = 'sertralin';

commit;
SQL

before_claims=$(scalar 'select count(*) from knowledge.claims')
before_revisions=$(scalar 'select count(*) from knowledge.claim_revisions')
before_links=$(scalar 'select count(*) from knowledge.claim_evidence_links')
before_assessments=$(scalar 'select count(*) from knowledge.evidence_assessments')
before_verifications=$(scalar 'select count(*) from workflow.evidence_verifications')
before_groundings=$(scalar 'select count(*) from knowledge.evidence_field_groundings')
before_sources=$(scalar 'select count(*) from knowledge.sources')

assert_eq "$before_claims" '1' 'fiksturen skal ha én gjenstående legacy-påstand'
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '2' \
  'fjerning av én påstand skal ikke fjerne de to legacy-evidensrøttene'
assert_eq "$(scalar "select count(*) from knowledge.sources where title like '%[normalisert bibliografisk tittel]' ")" '1' \
  'fiksturen skal inneholde en korrigert bibliografisk tittel uten ny kildeidentitet'
assert_eq "$before_verifications" '1' \
  'fiksturen skal inneholde senere kildekontroll på legacy-evidensen'
assert_eq "$before_groundings" '1' \
  'fiksturen skal inneholde senere feltforankring på legacy-evidensen'
assert_eq "$(scalar 'select count(*) from workflow.review_decisions')" '0' \
  'fiksturen skal ikke ha formell menneskelig review'
assert_eq "$(scalar 'select count(*) from workflow.claim_verifications')" '0' \
  'fiksturen skal ikke ha påstandskontroll'
assert_eq "$(scalar 'select count(*) from knowledge.publication_events')" '0' \
  'fiksturen skal ikke ha publiseringshistorikk'

npx --no-install supabase migration up --local >"$TMP_DIR/evolved-upgrade.log" 2>&1 || {
  cat "$TMP_DIR/evolved-upgrade.log" >&2
  fail 'videreutviklet, men fortsatt rent legacy-avledet prototype ble feilaktig avvist'
}

assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" '0' \
  'resetten lot legacy-evidens stå aktiv'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" '0' \
  'resetten lot legacy-påstander stå aktive'
assert_eq "$(scalar 'select count(*) from audit.prototype_resets')" '1' \
  'resetten skrev ikke nøyaktig ett privat snapshot'
assert_eq "$(scalar "select (row_counts ->> 'claims')::bigint from audit.prototype_resets")" "$before_claims" \
  'snapshotet mistet gjenstående påstandsrøtter'
assert_eq "$(scalar "select (row_counts ->> 'claim_revisions')::bigint from audit.prototype_resets")" "$before_revisions" \
  'snapshotet mistet legacy-revisjoner'
assert_eq "$(scalar "select (row_counts ->> 'claim_evidence_links')::bigint from audit.prototype_resets")" "$before_links" \
  'snapshotet mistet legacy-evidenslenker'
assert_eq "$(scalar "select (row_counts ->> 'evidence_assessments')::bigint from audit.prototype_resets")" "$before_assessments" \
  'snapshotet mistet legacy-evidensvurderinger'
assert_eq "$(scalar "select (row_counts ->> 'evidence_verifications')::bigint from audit.prototype_resets")" "$before_verifications" \
  'snapshotet mistet senere legacy-kildekontroller'
assert_eq "$(scalar "select (row_counts ->> 'evidence_field_groundings')::bigint from audit.prototype_resets")" "$before_groundings" \
  'snapshotet mistet senere legacy-feltforankringer'
assert_eq "$(scalar 'select count(*) from knowledge.sources')" "$before_sources" \
  'resetten endret kildebiblioteket'

printf 'OK: videreutviklet legacy-graf snapshots og resettes uten å utvide roten.\n'
