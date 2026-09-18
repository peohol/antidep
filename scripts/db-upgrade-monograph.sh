#!/usr/bin/env bash
# Monografien lagt oppå en base som alt har innhold.
#
# Den tomme basen prøves av `npm run db:test` og `npm run db:test:monograph`.
# Denne prøven svarer på det andre spørsmålet: tåler monografi-
# migrasjonene en base der kjeden alt har kjørt, og der det alt står en
# *publisert* påstand om det samme virkestoffet og det samme temaet monografien
# skal svare på?
#
# Rekkefølgen er hele poenget:
#
#   1. Basen settes til siste migrasjon før monografien (20261002090000).
#   2. `agent-chain-test.ts` bygger innholdet gjennom de autoriserte veiene —
#      kildeversjoner, evidens, kontroller, en påstand og en publisering. Den
#      påstanden er sertralin + vektendring.
#   3. Alt telles og avtrykkes.
#   4. Monografimigrasjonene kjøres.
#   5. Ingenting fra før skal ha flyttet seg: samme rader, samme innholds-
#      avtrykk, samme publiseringspeker, samme revisjonshistorikk. Den gamle
#      påstanden skal ha fått `monograph_need_id is null` og ikke en oppdiktet
#      avgrensning.
#   6. `monograph-e2e.ts` kjører hele den nye kjeden oppå dette — og den
#      bestiller nettopp sertralin og svarer nettopp på vektendring. Det er
#      blokkeringen fase C skulle løse: en eksisterende påstand for samme tema
#      og virkestoff skal ikke hindre videre automatisk syntese.
#   7. Den gamle påstanden skal fortsatt stå publisert og uendret etterpå, og
#      den nye skal være sin egen — bundet til kunnskapsbehovet, ikke til den
#      gamle.
set -euo pipefail
cd "$(dirname "$0")/.."

LAST_BEFORE_MONOGRAPH=20261002090000
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

# Innholdet som fantes før oppgraderingen, én linje per rad.
#
# Linjer og ikke ett avtrykk, med vilje: en avvikende hash sier bare at *noe*
# er annerledes, mens en diff sier hvilken rad det gjelder. Revisjonssporet
# telles for seg, fordi migrasjonene har lov til å *legge til* der — de skal
# bare ikke fjerne eller skrive om noe.
CONTENT_SQL="
select line from (
  select 'claim:' || c.id::text || '|' || c.subject_drug_id::text || '|'
         || c.topic_concept_id::text as line
  from knowledge.claims c
  union all
  select 'revision:' || r.id::text || '|' || r.claim_id::text || '|'
         || r.revision_number::text || '|' || r.content_hash as line
  from knowledge.claim_revisions r
  union all
  select 'evidence:' || e.id::text || '|' || e.content_hash as line
  from knowledge.evidence_items e
  union all
  select 'link:' || l.claim_revision_id::text || '|' || l.evidence_item_id::text || '|'
         || l.relationship_type::text as line
  from knowledge.claim_evidence_links l
  union all
  select 'publication:' || p.id::text || '|' || p.action::text || '|'
         || coalesce(p.revision_id::text, '') || '|'
         || coalesce(p.candidate_digest, '') as line
  from knowledge.publication_events p
  union all
  select 'version:' || v.id::text || '|' || v.content_hash as line
  from knowledge.source_versions v
) rows
order by line;
"

AUDIT_SQL="
select 'audit:' || a.id::text || '|' || a.operation::text || '|' || a.object_id::text
from audit.events a
order by 1;
"

dump() {
  psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -t -A -c "$1" | tr -d '\r' | sed '/^$/d'
}

printf 'Antidep 2: monografien lagt oppå en base som alt har innhold.\n'
printf '  1/7  setter basen til siste migrasjon før monografien …\n'
npx --no-install supabase db reset --version "$LAST_BEFORE_MONOGRAPH" >/dev/null

assert_eq "$(scalar "select coalesce(to_regclass('knowledge.monograph_editions')::text, '')")" '' \
  'basen hadde monografitabellene før migrasjonene ble kjørt'

printf '  2/7  bygger innhold gjennom de autoriserte veiene (agent-chain-test) …\n'
if ! node scripts/agent-chain-test.ts >"$TMP_DIR/chain.log" 2>&1; then
  tail -40 "$TMP_DIR/chain.log" >&2
  fail 'kjedeprøven fikk ikke bygget innholdet oppgraderingen skal prøves mot'
fi

CLAIMS_BEFORE=$(scalar 'select count(*) from knowledge.claims')
REVISIONS_BEFORE=$(scalar 'select count(*) from knowledge.claim_revisions')
EVIDENCE_BEFORE=$(scalar 'select count(*) from knowledge.evidence_items')
LINKS_BEFORE=$(scalar 'select count(*) from knowledge.claim_evidence_links')
PUBLICATIONS_BEFORE=$(scalar 'select count(*) from knowledge.publication_events')
AUDIT_BEFORE=$(scalar 'select count(*) from audit.events')
dump "$CONTENT_SQL" >"$TMP_DIR/content-before.txt"
dump "$AUDIT_SQL" >"$TMP_DIR/audit-before.txt"

assert_ne "$CLAIMS_BEFORE" '0' 'oppgraderingsprøven må ha en påstand å prøve mot'
assert_eq \
  "$(scalar "select count(*) from knowledge.claims c
             join catalog.drugs d on d.id = c.subject_drug_id
             join catalog.clinical_concepts k on k.id = c.topic_concept_id
             where d.canonical_name = 'sertralin' and k.canonical_label = 'vektendring'")" \
  '1' \
  'prøven forutsetter den eksisterende påstanden om sertralin og vektendring'

PUBLISHED_BEFORE=$(scalar "
  select count(*) from knowledge.publication_events p
  where p.action = 'publish'")
assert_ne "$PUBLISHED_BEFORE" '0' 'prøven forutsetter at noe alt er publisert'

PUBLISHED_CLAIMS_BEFORE=$(scalar \
  "select jsonb_array_length(api.published_claim_index() -> 'claims')")
assert_ne "$PUBLISHED_CLAIMS_BEFORE" '0' \
  'prøven forutsetter at den publiserte katalogen svarer med innhold'

printf '  3/7  avtrykk av %s påstand(er), %s revisjoner, %s evidensfunn, %s revisjonslenker.\n' \
  "$CLAIMS_BEFORE" "$REVISIONS_BEFORE" "$EVIDENCE_BEFORE" "$LINKS_BEFORE"

printf '  4/7  kjører monografi-migrasjonene …\n'
if ! npx --no-install supabase migration up --local >"$TMP_DIR/up.log" 2>&1; then
  tail -60 "$TMP_DIR/up.log" >&2
  fail 'monografi-migrasjonene lot seg ikke legge oppå en base med innhold'
fi

printf '  5/7  kontrollerer at ingenting fra før har flyttet seg …\n'
assert_eq "$(scalar 'select count(*) from knowledge.claims')" "$CLAIMS_BEFORE" \
  'oppgraderingen endret antallet påstander'
assert_eq "$(scalar 'select count(*) from knowledge.claim_revisions')" "$REVISIONS_BEFORE" \
  'oppgraderingen endret antallet revisjoner'
assert_eq "$(scalar 'select count(*) from knowledge.evidence_items')" "$EVIDENCE_BEFORE" \
  'oppgraderingen endret antallet evidensfunn'
assert_eq "$(scalar 'select count(*) from knowledge.claim_evidence_links')" "$LINKS_BEFORE" \
  'oppgraderingen endret antallet revisjonslenker'
assert_eq "$(scalar 'select count(*) from knowledge.publication_events')" "$PUBLICATIONS_BEFORE" \
  'oppgraderingen endret publiseringshistorikken'
dump "$CONTENT_SQL" >"$TMP_DIR/content-after.txt"
if ! diff -u "$TMP_DIR/content-before.txt" "$TMP_DIR/content-after.txt" >"$TMP_DIR/content.diff"; then
  cat "$TMP_DIR/content.diff" >&2
  fail 'oppgraderingen endret innholdet i noe som alt fantes'
fi

# En migrasjon skriver ikke om historikken. Den kan legge til revisjons-
# varsler for innhold som nå har fått en monografiavgrensning — det er nettopp
# meningen — men de gamle radene skal stå der uendret, og det er det avtrykket
# over sier.
AUDIT_AFTER=$(scalar 'select count(*) from audit.events')
[ "$AUDIT_AFTER" -ge "$AUDIT_BEFORE" ] || \
  fail "oppgraderingen fjernet revisjonsspor ($AUDIT_BEFORE -> $AUDIT_AFTER)"

dump "$AUDIT_SQL" >"$TMP_DIR/audit-after.txt"
if [ -n "$(comm -23 "$TMP_DIR/audit-before.txt" "$TMP_DIR/audit-after.txt")" ]; then
  comm -23 "$TMP_DIR/audit-before.txt" "$TMP_DIR/audit-after.txt" >&2
  fail 'oppgraderingen fjernet eller skrev om et revisjonsspor som alt fantes'
fi

# Den nye kolonnen finnes, og den gamle påstanden har ingen oppdiktet
# avgrensning: en migrasjon som hadde gjettet et kunnskapsbehov for den, ville
# sagt at påstanden svarer på et spørsmål ingen stilte.
assert_eq "$(scalar 'select count(*) from knowledge.claims where monograph_need_id is not null')" '0' \
  'oppgraderingen ga en eksisterende påstand en monografiavgrensning den ikke har'

# Registrene landet, og de er ett register og ikke to.
assert_eq "$(scalar 'select count(*) from knowledge.monograph_question_templates')" '80' \
  'malregisteret mangler maler etter oppgraderingen'
assert_eq "$(scalar 'select count(*) from knowledge.monograph_source_profiles')" '13' \
  'kildeprofilene mangler etter oppgraderingen'

# Den publiserte leseveien svarer fortsatt, og den svarer om det samme.
# Svaret er jsonb og ikke et sett: katalogen leses som ett dokument.
assert_eq "$(scalar "select jsonb_array_length(api.published_claim_index() -> 'claims')")" \
  "$PUBLISHED_CLAIMS_BEFORE" \
  'den publiserte katalogen mistet innhold i oppgraderingen'

printf '  6/7  kjører hele monografikjeden oppå det eksisterende innholdet …\n'
if ! node scripts/monograph-e2e.ts >"$TMP_DIR/monograph.log" 2>&1; then
  tail -60 "$TMP_DIR/monograph.log" >&2
  fail 'monografikjeden kom ikke gjennom på en base som alt hadde en påstand om samme tema'
fi

printf '  7/7  kontrollerer at den gamle påstanden står, og at den nye er sin egen …\n'

# Den gamle påstanden er uendret og fortsatt publisert.
assert_eq "$(scalar "
  select count(*) from knowledge.claims c
  where c.monograph_need_id is null
    and exists (select 1 from knowledge.publication_events p
                where p.claim_id = c.id and p.action = 'publish')")" '1' \
  'den eksisterende, publiserte påstanden er ikke lenger der den var'

# Og den nye er en *annen* rad, bundet til kunnskapsbehovet. Samme virkestoff,
# samme tema — og likevel to påstander, fordi avgrensningen er forskjellig.
# Dette er blokkeringen fase C skulle løse.
NEW_SCOPED=$(scalar "
  select count(*) from knowledge.claims c
  join catalog.drugs d on d.id = c.subject_drug_id
  join catalog.clinical_concepts k on k.id = c.topic_concept_id
  where d.canonical_name = 'sertralin'
    and k.canonical_label = 'vektendring'
    and c.monograph_need_id is not null")
assert_eq "$NEW_SCOPED" '1' \
  'syntesen laget ingen egen påstand for kunnskapsbehovet — den gamle blokkerte den fortsatt'

assert_eq "$(scalar "
  select count(*) from knowledge.claims c
  join catalog.drugs d on d.id = c.subject_drug_id
  join catalog.clinical_concepts k on k.id = c.topic_concept_id
  where d.canonical_name = 'sertralin' and k.canonical_label = 'vektendring'")" '2' \
  'det skal stå nøyaktig to påstander om sertralin og vektendring: den gamle og den avgrensede'

# Den gamle fikk et revisjonsvarsel og ikke en overskriving: ny evidens for det
# samme temaet skal vurderes mot den, ikke skrives inn i den i stillhet.
assert_ne "$(scalar "
  select count(*) from workflow.claim_revision_reviews v
  join knowledge.claims c on c.id = v.claim_id
  where c.monograph_need_id is null")" '0' \
  'den gamle påstanden fikk ikke noe revisjonsvarsel av den nye evidensen'

printf '\nMonografien tåler en base som alt har innhold.\n'
