-- Migrasjon 007 — API-lesemodellen, sett fra klientrollene.
--
-- MVP_IMPLEMENTATION_PLAN.md §24 krever at api-projeksjonene testes «eksplisitt
-- med faktisk klientrolle», og DATABASE_ARCHITECTURE.md §44 punkt 4 sier det
-- samme. Denne filen er den testen: hver påstand under er enten en kontrakt om
-- hva api eksponerer, eller et forsøk utført som anon eller authenticated.
--
-- Databasen inneholder ingen publiserte påstander, og skal ikke gjøre det:
-- publisering krever en menneskelig faglig godkjenning som ikke kan seedes
-- (ANTIDEP_CONSTITUTION.md §12, MVP_IMPLEMENTATION_PLAN.md §74.4). Testen
-- publiserer derfor sitt eget innhold inne i transaksjonen og ruller alt
-- tilbake, på samme måte som 260. Et tomt svar fra et view betyr da noe: det er
-- filteret som virker, ikke en tom database.
--
-- Tre lås står mellom en klientrolle og en upublisert påstand, og de testes hver
-- for seg, fordi et view som gjentar et predikat ellers kan få en ødelagt policy
-- til å se ut som om den virker:
--   lag 1  klientrollene mangler usage på de kanoniske schemaene
--   lag 2  RLS slipper bare gjennom rader nådd fra en publisert påstand
--   lag 3  bare SELECT er gitt, og bare til anon og authenticated
--
-- SQLSTATE 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(67);

create temporary table fixture (name text primary key, id uuid not null) on commit drop;

-- Assertionene under kjøres dels som anon og dels som authenticated, og noen av
-- dem sammenligner mot en id fra fikstureren. Temptabellen er lokal til
-- transaksjonen og rulles tilbake med den.
grant select on fixture to anon, authenticated;

-- ===========================================================================
-- Del 1 — Kontrakten: hva api faktisk eksponerer
-- ===========================================================================

-- Uttømmende inventar. Et nytt objekt i api er en utvidelse av den offentlige
-- kontrakten og skal ikke kunne gli inn uten at denne listen endres.
--
-- `my_actor` og `my_roles` kom med migrasjon 007b og er ikke del av den
-- publiserte lesemodellen denne filen ellers handler om: de projiserer
-- kallerens egen aktør og egne rolletildelinger, og prøves i
-- 360_caller_authorization_test.sql. De seks `editor_*` kom med migrasjon 007d
-- og er den redaksjonelle lesemodellen registreringen av et evidensfunn
-- trenger; de prøves i 400_editor_read_model_access_test.sql. Alle åtte står
-- her fordi inventaret er uttømmende — det er hele poenget med det.
select set_eq(
  $$
    select c.relname || ':' || c.relkind::text
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'api'
      and c.relkind in ('r', 'p', 'v', 'm', 'f')
  $$,
  $$
    values ('published_drugs:v'),
           ('published_claims:v'),
           ('published_claim_evidence:v'),
           ('my_actor:v'),
           ('my_roles:v'),
           ('editor_sources:v'),
           ('editor_source_versions:v'),
           ('editor_drugs:v'),
           ('editor_outcomes:v'),
           ('editor_populations:v'),
           ('editor_evidence_items:v')
  $$,
  'api inneholder nøyaktig de elleve viewene migrasjon 007, 007b og 007d oppretter, og ingen tabeller'
);

-- Lag 3: hvert view er lesbart for begge Data API-rollene, og bare lesbart.
-- service_role og PUBLIC har fortsatt ingenting (DATABASE_ARCHITECTURE.md §49).
select is_empty(
  $$
    select t.view_name, r.role_name, p.privilege
    from (values ('api.published_drugs'), ('api.published_claims'),
                 ('api.published_claim_evidence')) as t(view_name)
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'),
                       ('references'), ('trigger')) as p(privilege)
    where has_table_privilege(r.role_name, t.view_name, p.privilege)
      and not (p.privilege = 'select' and r.role_name in ('anon', 'authenticated'))
  $$,
  'viewene i api gir bare SELECT, og bare til anon og authenticated'
);

select is_empty(
  $$
    select t.view_name, r.role_name
    from (values ('api.published_drugs'), ('api.published_claims'),
                 ('api.published_claim_evidence')) as t(view_name)
    cross join (values ('anon'), ('authenticated')) as r(role_name)
    where not has_table_privilege(r.role_name, t.view_name, 'select')
  $$,
  'begge Data API-rollene kan lese alle tre viewene'
);

-- Uttømmende kontrakt over hvilke kanoniske tabeller viewene i api har åpnet.
-- Den generelle regelen — aldri mer enn SELECT — står i 020 og 030; dette er
-- listen over hvilke tabeller det gjelder, og den skal endres bevisst.
--
-- Både tabellvide og kolonnevise grants telles. Et oppslag mot pg_class.relacl
-- alene ville ikke sett de tre tabellene som bare er åpnet på kolonnenivå —
-- knowledge.publication_events fra migrasjon 007a, og de to fra 007b — og
-- assertionen ville sagt «tretten» mens seksten var åpnet. Samme blindsone som
-- has_table_privilege() har, og av samme grunn.
select set_eq(
  $$
    select n.nspname || '.' || c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) a
    where n.nspname in ('catalog', 'knowledge', 'workflow', 'provenance', 'audit')
      and a.grantee::regrole::text in ('anon', 'authenticated')
    union
    select n.nspname || '.' || c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute att
      on att.attrelid = c.oid and att.attnum > 0 and not att.attisdropped
    cross join lateral aclexplode(att.attacl) a
    where n.nspname in ('catalog', 'knowledge', 'workflow', 'provenance', 'audit')
      and a.grantee::regrole::text in ('anon', 'authenticated')
  $$,
  $$
    values ('catalog.drugs'), ('catalog.drug_identifiers'),
           ('catalog.clinical_concepts'), ('catalog.populations'),
           ('knowledge.claims'), ('knowledge.claim_revisions'),
           ('knowledge.claim_evidence_links'), ('knowledge.evidence_assessments'),
           ('knowledge.evidence_items'), ('knowledge.sources'),
           ('knowledge.source_identifiers'), ('knowledge.source_versions'),
           ('knowledge.publication_events'),
           ('workflow.review_decisions'),
           ('workflow.user_roles'), ('provenance.actors')
  $$,
  'nøyaktig de seksten tabellene viewene i api leser er åpnet for klientrollene, tabellvidt eller på kolonnenivå'
);

-- Bare én tabell i workflow er åpnet, og bare fordi en tilbaketrukket ekstraksjon
-- kan registreres etter publisering. Rollemedlemskap, verifikasjoner,
-- aktøridentiteter og publiseringshistorikken er ikke publisert innhold.
select is_empty(
  $$
    select n.nspname || '.' || c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) a
    where n.nspname in ('workflow', 'provenance', 'audit')
      and a.grantee::regrole::text in ('anon', 'authenticated')
      and n.nspname || '.' || c.relname <> 'workflow.review_decisions'
  $$,
  'ingenting i workflow utenom review_decisions er åpnet, og verken provenance eller audit'
);

-- Autorisasjonskilden er den raden som betyr mest at forblir stengt
-- (DATABASE_ARCHITECTURE.md §46).
select is_empty(
  $$
    select r.role_name, p.privilege
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    cross join (values ('select'), ('insert'), ('update'), ('delete')) as p(privilege)
    where has_table_privilege(r.role_name, 'workflow.user_roles', p.privilege)
  $$,
  'rollemedlemskapstabellen er fortsatt helt stengt for alle klientroller'
);

-- ===========================================================================
-- Del 2 — Lag 1: granten alene åpner ikke tabellene
--
-- Dette er den nye og lett kontraintuitive tilstanden etter migrasjon 007.
-- anon *har* SELECT på knowledge.claims, men kan ikke navngi tabellen, fordi
-- usage på schemaet mangler. Viewene leser videre fordi navneoppslaget deres
-- skjedde da de ble opprettet.
-- ===========================================================================

select ok(
  has_table_privilege('anon', 'knowledge.claims', 'select'),
  'anon har faktisk SELECT på knowledge.claims'
);
select ok(
  not has_schema_privilege('anon', 'knowledge', 'usage'),
  'anon har fortsatt ikke usage på knowledge'
);
select ok(
  not has_schema_privilege('anon', 'catalog', 'usage'),
  'anon har fortsatt ikke usage på catalog'
);

set local role anon;
select throws_ok(
  'select 1 from knowledge.claims',
  '42501', null,
  'anon nektes å navngi knowledge.claims direkte, tross SELECT-granten'
);
select lives_ok(
  'select 1 from api.published_claims',
  'anon kan lese det samme innholdet gjennom api-viewet'
);
reset role;

-- ===========================================================================
-- Del 3 — Ingenting er publisert, så projeksjonen er tom
--
-- Kontrollen er meningsfull bare sammen med den neste: de to seedede påstandene
-- finnes, de er bare ikke publisert.
-- ===========================================================================

select isnt_empty(
  'select 1 from knowledge.claims',
  'det finnes seedede påstander i databasen'
);

set local role anon;
select is(
  (select count(*) from api.published_claims), 0::bigint,
  'api.published_claims er tom fordi ingen påstand er publisert, ikke fordi det ikke finnes påstander'
);
select is(
  (select count(*) from api.published_drugs), 0::bigint,
  'api.published_drugs er tom av samme grunn'
);
select is(
  (select count(*) from api.published_claim_evidence), 0::bigint,
  'api.published_claim_evidence er tom av samme grunn'
);
reset role;

-- ===========================================================================
-- Del 4 — Én publisert påstand, opprettet og publisert inne i transaksjonen
--
-- Innholdet er testinnhold og ruller tilbake. Godkjenningen er ikke seedet: den
-- utføres her, av en aktør som er opprettet her, slik at ingen fiktiv
-- godkjenning blir stående i databasen (ANTIDEP_CONSTITUTION.md §12).
-- ===========================================================================

insert into auth.users (id, email) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'reviewer-290@test.invalid'),
  ('eeeeeeee-0000-0000-0000-000000000002', 'publisher-290@test.invalid'),
  ('eeeeeeee-0000-0000-0000-000000000003', 'verifier-290@test.invalid');

insert into provenance.actors (actor_type, actor_key, display_name, description, auth_user_id)
values
  ('human', 'human:reviewer-290', 'Reviewer', 'Kvalifisert redaktør for testene i 290.',
   'eeeeeeee-0000-0000-0000-000000000001'),
  ('human', 'human:publisher-290', 'Publisher', 'Utfører publiseringen i testene i 290.',
   'eeeeeeee-0000-0000-0000-000000000002'),
  ('human', 'human:verifier-290', 'Verifikator', 'Utfører verifikasjonene i testene i 290.',
   'eeeeeeee-0000-0000-0000-000000000003');

insert into fixture (name, id)
select 'reviewer', id from provenance.actors where actor_key = 'human:reviewer-290';
insert into fixture (name, id)
select 'publisher', id from provenance.actors where actor_key = 'human:publisher-290';
insert into fixture (name, id)
select 'verifier', id from provenance.actors where actor_key = 'human:verifier-290';
insert into fixture (name, id)
select 'synthesis_actor', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id)
select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id)
select 'mirtazapin', id from catalog.drugs where canonical_name = 'mirtazapin';
insert into fixture (name, id)
select 'evidence_sertralin', e.id from knowledge.evidence_items e
join knowledge.sources s on s.id = e.source_id
where s.title like 'Fluoxetine versus sertraline%';
insert into fixture (name, id)
select 'evidence_mirtazapin', e.id from knowledge.evidence_items e
join knowledge.sources s on s.id = e.source_id
where s.title like 'Comparison of the effects of mirtazapine%';

-- Rolletildelingene må ha eksistert før beslutningene som viser til dem
-- (workflow.enforce_reviewer_qualification()).
alter table workflow.user_roles disable trigger user_roles_set_row_timestamps;
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason, created_at)
values
  ('eeeeeeee-0000-0000-0000-000000000001', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'verifier'), 'Reviewrett for testene i 290.',
   now() - interval '1 year'),
  ('eeeeeeee-0000-0000-0000-000000000002', 'publisher', null, now() - interval '1 year',
   (select id from fixture where name = 'verifier'), 'Publiseringsrett for testene i 290.',
   now() - interval '1 year'),
  -- Verifikatoren trenger selv reviewer-rollen fra og med migrasjon 005j: en
  -- claim-verifikasjon krever mandat, og for et menneske er mandatet
  -- reviewer-rollen for innholdsområdet (MVP_IMPLEMENTATION_PLAN.md §74.30 punkt 3).
  ('eeeeeeee-0000-0000-0000-000000000003', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'reviewer'), 'Reviewrett for verifikatoren i 290.',
   now() - interval '1 year');
alter table workflow.user_roles enable trigger user_roles_set_row_timestamps;

-- Påstanden: sertralin, med mirtazapin som komparator, slik at komparatornavnet
-- og skillet mot api.published_drugs kan kontrolleres.
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'sertralin' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'claim', id from inserted;

with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    statement, scope, comparator_kind, comparator_drug_id,
    uncertainty_summary, created_by_actor_id
  )
  select c.id, 1, c.knowledge_type, c.subject_drug_id,
         'Testpåstand som publiseres i 290.',
         'Gjelder bare testene i denne filen.',
         'drug', (select id from fixture where name = 'mirtazapin'),
         'Testusikkerhet.', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'claim')
  returning id
)
insert into fixture (name, id) select 'rev1', id from inserted;

-- Revisjon 2 er et utkast og blir aldri publisert. Den finnes for å vise at
-- viewet følger publiseringspekeren, ikke det høyeste revisjonsnummeret.
with inserted as (
  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id, supersedes_revision_id,
    statement, scope, comparator_kind, comparator_drug_id,
    uncertainty_summary, created_by_actor_id
  )
  select c.id, 2, c.knowledge_type, c.subject_drug_id,
         (select id from fixture where name = 'rev1'),
         'Upublisert utkast som ikke skal være synlig.',
         'Gjelder bare testene i denne filen.',
         'drug', (select id from fixture where name = 'mirtazapin'),
         'Testusikkerhet.', c.created_by_actor_id
  from knowledge.claims c
  where c.id = (select id from fixture where name = 'claim')
  returning id
)
insert into fixture (name, id) select 'rev2', id from inserted;

-- To lenker med motsatt fortegn. Den motstridende skal være like synlig som den
-- støttende (ANTIDEP_CONSTITUTION.md §9); et view som filtrerte den bort ville
-- vist en annen påstand enn den som ble godkjent.
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select (select id from fixture where name = 'rev1'),
       (select id from fixture where name = 'evidence_sertralin'),
       'supports', 'direct',
       'Funnet rapporterer utfallet påstanden gjelder.',
       (select id from fixture where name = 'synthesis_actor');

insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select (select id from fixture where name = 'rev1'),
       (select id from fixture where name = 'evidence_mirtazapin'),
       'contradicts', 'indirect',
       'Funnet peker i motsatt retning for komparatoren.',
       (select id from fixture where name = 'synthesis_actor');

-- Den kildeomfattende halvdelen av et globalt fravær (`not_reported`,
-- `not_measured`) kan bare føres opp av en maskinell kontroll med sin egen
-- agentkjøring (migrasjon 005ae,
-- evidence_verifications_source_wide_absence_check): ingen menneskelig
-- kontrolløkt søker gjennom hele representasjonen, og blir aldri spurt om det.
-- En fikstur som skal ha full dekning, trenger derfor begge leddene.
create function pg_temp.cover_source_wide_absence(p_evidence_item_id uuid)
  returns void
  language plpgsql
as $fn$
declare
  v_run_id uuid;
  v_actor_id uuid;
begin
  -- Fører ikke raden en slik påstand, kreves feltet ikke, og en rad som førte
  -- det opp ville påstått en kontroll av ingenting.
  if 'source_wide_absence' <> all (workflow.required_check_fields(p_evidence_item_id)) then
    return;
  end if;

  insert into provenance.agent_runs
    (agent_identity_id, actor_id, agent_role, provider, model, model_version,
     prompt_template_version, pipeline_version, input_manifest)
  select ai.id, ai.actor_id, 'extraction_verification', 'prøve', 'prøve', '1',
         'extraction-verification/1', 'antidep-evidence/1', '{"mode": "fikstur"}'::jsonb
  from provenance.agent_identities ai
  where ai.identity_key = 'agent-identity:extraction-verification-01'
  returning id, actor_id into v_run_id, v_actor_id;

  insert into workflow.evidence_verifications
    (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
     source_access, checked_fields, rationale, verified_at, agent_run_id)
  select e.id, e.created_by_actor_id, v_actor_id, 'verified', 'verifiable_representation',
         array['source_wide_absence']::workflow.evidence_check_field[],
         'Fikstur: et søk gjennom hele den kontrollerte representasjonen fant ingen verdi '
         || 'for de feltene raden fører som fraværende i kilden.',
         now() - interval '30 days', v_run_id
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;
end;
$fn$;

-- Den maskinelle halvdelen først, slik at den menneskelige kontrollen blir
-- den gjeldende (registreringsrekkefølgen avgjør, migrasjon 005å).
select pg_temp.cover_source_wide_absence(e.id)
from knowledge.evidence_items e, fixture v
where v.name = 'verifier'
  and e.id in (select id from fixture where name in ('evidence_sertralin',
                                                     'evidence_mirtazapin'));

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'verified', 'original_source',
       -- Full dekning, utledet av raden selv: publiseringsgatens G5b krever at
       -- kontrollene til sammen dekker det funnet påstår noe om.
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Kontrollert mot originalkilden.', now() - interval '5 days'
from knowledge.evidence_items e, fixture v
where v.name = 'verifier'
  and e.id in (select id from fixture where name in ('evidence_sertralin',
                                                     'evidence_mirtazapin'));

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
       'Forsøkt falsifisert mot kilden.', now() - interval '4 days'
from knowledge.claim_revisions r, fixture v
where r.id = (select id from fixture where name = 'rev1') and v.name = 'verifier';

insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select r.id, r.knowledge_type, 'grade', 'low',
       'serious', 'not_assessable', 'serious', 'serious', 'not_assessable',
       'To funn, det ene indirekte; domenene vurdert enkeltvis.',
       now() - interval '3 days', r.created_by_actor_id
from knowledge.claim_revisions r
where r.id = (select id from fixture where name = 'rev1');

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Gjennomgått mot kildene; formuleringen holder.',
       rg.id, 'human', now() - interval '2 days'
from knowledge.claim_revisions r, fixture rg
where r.id = (select id from fixture where name = 'rev1') and rg.name = 'reviewer';

select set_config('request.jwt.claims',
                  '{"sub":"eeeeeeee-0000-0000-0000-000000000002"}', true);
select lives_ok(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Publisert for tilgangstestene i 290.')$$,
  'revisjon 1 lar seg publisere når alle gatene er oppfylt'
);
select set_config('request.jwt.claims', '', true);

-- ===========================================================================
-- Del 5 — Den publiserte påstanden, lest som faktisk klientrolle
-- ===========================================================================

set local role anon;

select is(
  (select count(*) from api.published_claims), 1::bigint,
  'anon ser nøyaktig én publisert påstand'
);
select is(
  (select claim_revision_id from api.published_claims),
  (select id from fixture where name = 'rev1'),
  'anon ser revisjonen publiseringspekeren peker på, ikke det høyeste revisjonsnummeret'
);
select is(
  (select revision_number from api.published_claims), 1,
  'revisjonsnummeret er 1, selv om revisjon 2 finnes som upublisert utkast'
);
select is(
  (select drug_name from api.published_claims), 'sertralin',
  'virkestoffnavnet slås opp gjennom katalogpolicyen'
);
select is(
  (select comparator_drug_name from api.published_claims), 'mirtazapin',
  'komparatorens navn er lesbart, selv om mirtazapin ikke har egne publiserte påstander'
);
select is(
  (select certainty_level from api.published_claims), 'low',
  'sikkerhetsgraden følger med den publiserte revisjonen'
);
select is(
  (select topic_label from api.published_claims), 'vektendring',
  'temabegrepet slås opp gjennom begrepspolicyen'
);

-- De to seedede påstandene er ikke publisert og skal ikke være synlige.
select is_empty(
  $$
    select claim_id from api.published_claims
    where statement not like 'Testpåstand som publiseres i 290%'
  $$,
  'ingen av de seedede, upubliserte påstandene lekker inn i projeksjonen'
);

-- Evidensgrunnlaget, med begge fortegn.
select is(
  (select count(*) from api.published_claim_evidence), 2::bigint,
  'anon ser begge evidenslenkene på den publiserte revisjonen'
);
select set_eq(
  'select relationship_type from api.published_claim_evidence',
  $$ values ('supports'), ('contradicts') $$,
  'både den støttende og den motstridende lenken er synlig (ANTIDEP_CONSTITUTION.md §9)'
);
select is_empty(
  'select 1 from api.published_claim_evidence where source_title is null',
  'hver evidensrad har en kildetittel, slik at påstanden kan spores til kilden (ANTIDEP_CONSTITUTION.md §4)'
);
select is_empty(
  'select 1 from api.published_claim_evidence where source_locator is null',
  'hver evidensrad oppgir hvor i kilden funnet står'
);
-- source_locator peker inn i en bestemt hentet versjon, ikke i kilden generelt.
-- For en levende kilde kan samme URL senere gi annet innhold, og da er
-- lokatoren alene ikke nok til å reprodusere hva som ble verifisert
-- (DATABASE_ARCHITECTURE.md §18, ANTIDEP_CONSTITUTION.md §16).
select is_empty(
  $$
    select 1 from api.published_claim_evidence
    where source_version_id is null
       or source_version_retrieved_at is null
       or source_version_retrieved_from is null
  $$,
  'hver evidensrad oppgir kildeversjonen funnet ble ekstrahert fra, med hentetidspunkt og hentested'
);
-- Lagringsreferansen til selve innholdet er bevisst ikke eksponert.
select is_empty(
  $$
    select a.attname
    from pg_attribute a
    where a.attrelid = 'api.published_claim_evidence'::regclass
      and a.attnum > 0 and not a.attisdropped
      and a.attname like '%storage%'
  $$,
  'kildeversjonens lagringsreferanse er ikke del av den offentlige kontrakten'
);

-- Virkestoffkatalogen: bare det Antidep har publisert påstander om. Mirtazapin
-- er lesbart som komparator og som intervensjon i et evidensfunn, men har ingen
-- publisert påstand og skal derfor ikke stå her.
select set_eq(
  'select canonical_name from api.published_drugs',
  $$ values ('sertralin') $$,
  'api.published_drugs viser bare virkestoff med publiserte påstander, ikke komparatorer'
);
select is(
  (select atc_codes from api.published_drugs where canonical_name = 'sertralin'),
  array['N06AB06'],
  'ATC-koden er med som språkuavhengig ekstern nøkkel'
);
select is(
  (select published_claim_count from api.published_drugs where canonical_name = 'sertralin'),
  1::bigint,
  'antallet publiserte påstander telles over det RLS-filtrerte settet'
);

-- ANTIDEP_CONSTITUTION.md §6 og §17: NULL sikkerhetsgrad betyr «ingen
-- GRADE-vurdering gjelder for denne påstandstypen», og forekommer bare for
-- deterministiske fakta. Publiseringsgaten G10 krever vurdering for de to andre
-- typene, så en evidenssyntese uten sikkerhetsgrad ville vært et brudd.
select is_empty(
  $$
    select claim_id from api.published_claims
    where knowledge_type <> 'deterministic_fact' and certainty_level is null
  $$,
  'ingen publisert evidenssyntese eller klinisk anbefaling mangler sikkerhetsgrad'
);

reset role;

-- ---------------------------------------------------------------------------
-- Flerverdiige identifikatorer skal ikke multiplisere rader
--
-- catalog.drug_identifiers og knowledge.source_identifiers er unike på
-- (identifier_system, identifier_value), ikke på (forelder, identifier_system).
-- Et virkestoff kan derfor ha flere ATC-koder, og ingenting hindrer to DOI-er på
-- samme kilde. Var identifikatorene joinet inn, ville ett virkestoff blitt til to
-- rader og ett evidensfunn til to — det siste ville fått ett funn til å se ut som
-- to uavhengige, og dermed blåst opp evidensmengden bak en publisert påstand.
-- ---------------------------------------------------------------------------
insert into catalog.drug_identifiers (drug_id, identifier_system, identifier_value)
select id, 'atc', 'N06AB99' from fixture where name = 'sertralin';

insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
select e.source_id, 'doi', v.value
from knowledge.evidence_items e,
     (values ('10.1000/andre-doi-290'), ('10.1000/tredje-doi-290')) as v(value)
where e.id = (select id from fixture where name = 'evidence_sertralin');

set local role anon;
select is(
  (select count(*) from api.published_drugs), 1::bigint,
  'et virkestoff med to ATC-koder står fortsatt som én rad i katalogen'
);
select is(
  (select atc_codes from api.published_drugs where canonical_name = 'sertralin'),
  array['N06AB06', 'N06AB99'],
  'begge ATC-kodene er med, sortert, framfor at den ene velges vilkårlig'
);
select is(
  (select count(*) from api.published_claim_evidence), 2::bigint,
  'to DOI-er på samme kilde dupliserer ikke evidensfunnet'
);
-- Kilden har allerede en ekte DOI fra migrasjon 003, så settet er tre. Nettopp
-- den ekte er den en «velg den leksikografisk laveste»-regel ville forkastet:
-- 10.1000-verdiene sorterer foran 10.4088. En vilkårlig kanonisering er ikke
-- bare tapsbringende i teorien.
select is(
  (select source_dois from api.published_claim_evidence where relationship_type = 'supports'),
  array['10.1000/andre-doi-290', '10.1000/tredje-doi-290', '10.4088/jcp.v61n1109'],
  'alle DOI-ene følger med, sortert, framfor at én velges vilkårlig som kanonisk'
);
reset role;

-- Viewets eget publiseringsfilter, uavhengig av RLS. Som eier er radfilteret av,
-- så et tomt eller for stort svar her er viewets egen join mot
-- publiseringspekeren. Uten denne kontrollen ville RLS kunne dekket over et
-- ødelagt view, og de to lagene ikke vært uavhengig testet.
select is(
  (select count(*) from api.published_claims), 1::bigint,
  'viewet viser bare den publiserte påstanden også lest som eier, altså forbi RLS'
);

-- authenticated ser det samme settet: publisert kunnskap er offentlig lesbar,
-- og innlogging gir ikke utvidet innsyn i dette steget.
set local role authenticated;
select is(
  (select count(*) from api.published_claims), 1::bigint,
  'authenticated ser det samme publiserte settet som anon'
);
reset role;

-- ===========================================================================
-- Del 6 — Lag 2: RLS er en reell radgrense, ikke bare fraværet av usage
--
-- Selvtest av samme type som i 270. Skulle en senere migrasjon gi usage på
-- schemaet ved et uhell, skal RLS fortsatt skjule alt som ikke er publisert.
-- Granten finnes bare inne i denne transaksjonen.
-- ===========================================================================

grant usage on schema knowledge, catalog to anon;

select is(
  (select count(*) from knowledge.claims), 3::bigint,
  'eieren ser alle tre påstandene: de to seedede og den testen publiserte'
);

set local role anon;
select is(
  (select count(*) from knowledge.claims), 1::bigint,
  'anon ser bare den publiserte påstanden, også når tabellen leses direkte'
);
select is(
  (select count(*) from knowledge.claim_revisions), 1::bigint,
  'anon ser bare den publiserte revisjonen; utkastet i revisjon 2 er skjult'
);
select is(
  (select count(*) from knowledge.evidence_assessments), 1::bigint,
  'anon ser bare evidensvurderingen på den publiserte revisjonen'
);
select throws_ok(
  $$update knowledge.claims set retired_at = now(), retirement_note = 'Anonym.'$$,
  '42501', null,
  'anon kan ikke skrive i påstandstabellen selv med usage på schemaet'
);
select throws_ok(
  $$select 1 from workflow.review_decisions$$,
  '42501', null,
  'reviewbeslutningene er fortsatt utenfor rekkevidde'
);
reset role;

revoke usage on schema knowledge, catalog from anon;

-- ===========================================================================
-- Del 7 — En ekstraksjon som trekkes tilbake etter publisering
--
-- Publiseringsgaten (G6) nekter å publisere en revisjon som hviler på en
-- tilbaketrukket ekstraksjon. Men beslutningen er append-only og kan komme
-- etterpå, og da flytter den verken publiseringspekeren eller evidenslenkene.
-- Uten at lesemodellen avleder den gjeldende tilstanden, ville klienten fortsatt
-- vist et funn Antidep eksplisitt har underkjent, som ordinær evidens.
--
-- Funnet skal ikke skjules: da ville påstanden sett bedre underbygget ut enn den
-- er. Det skal merkes.
-- ===========================================================================

set local role anon;
select is(
  (select count(*) from api.published_claim_evidence where extraction_withdrawn), 0::bigint,
  'ingen ekstraksjon er trukket tilbake før beslutningen registreres'
);
select is(
  (select withdrawn_evidence_count from api.published_claims), 0::bigint,
  'påstanden viser null underkjente evidensfunn før beslutningen'
);
reset role;

insert into workflow.review_decisions
  (evidence_item_id, evidence_item_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select e.id, e.created_by_actor_id, 'extraction_withdrawal', 'extraction_withdrawn',
       'Ekstraksjonen gjengir ikke kilden riktig.',
       rg.id, 'human', now() - interval '1 hour'
from knowledge.evidence_items e, fixture rg
where e.id = (select id from fixture where name = 'evidence_sertralin')
  and rg.name = 'reviewer';

set local role anon;
select is(
  (select count(*) from api.published_claim_evidence), 2::bigint,
  'det tilbaketrukne funnet skjules ikke: påstanden skal ikke se bedre underbygget ut enn den er'
);
select is(
  (select count(*) from api.published_claim_evidence where extraction_withdrawn), 1::bigint,
  'nøyaktig ett funn er merket som tilbaketrukket'
);
select is(
  (select relationship_type from api.published_claim_evidence where extraction_withdrawn),
  'supports',
  'merket sitter på funnet beslutningen faktisk gjaldt'
);
select is(
  (select extraction_withdrawal_rationale from api.published_claim_evidence
   where extraction_withdrawn),
  'Ekstraksjonen gjengir ikke kilden riktig.',
  'begrunnelsen for tilbaketrekkingen er lesbar, slik source_status_note er det for en kilde'
);
select isnt(
  (select extraction_withdrawn_at from api.published_claim_evidence where extraction_withdrawn),
  null,
  'tidspunktet for tilbaketrekkingen følger med'
);
select is(
  (select withdrawn_evidence_count from api.published_claims), 1::bigint,
  'påstandssammendraget viser at grunnlaget er underkjent, uten at klienten må hente drilldownen'
);
reset role;

-- Ingen divergens mellom rollene. Policyen slipper gjennom begge utfallene av en
-- extraction_withdrawal nettopp for at avledningen «siste beslutning gjelder»
-- skal gi samme svar for en klientrolle som for eieren.
select is(
  (select count(*) from api.published_claim_evidence where extraction_withdrawn), 1::bigint,
  'eieren ser samme tilbaketrekking som klientrollen, forbi RLS'
);

-- En senere beslutning som opprettholder ekstraksjonen gjelder foran den
-- tidligere tilbaketrekkingen, på samme måte som i publiseringsgaten.
insert into workflow.review_decisions
  (evidence_item_id, evidence_item_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select e.id, e.created_by_actor_id, 'extraction_withdrawal', 'extraction_upheld',
       'Ny gjennomgang mot kilden: ekstraksjonen var likevel korrekt.',
       rg.id, 'human', now()
from knowledge.evidence_items e, fixture rg
where e.id = (select id from fixture where name = 'evidence_sertralin')
  and rg.name = 'reviewer';

set local role anon;
select is(
  (select count(*) from api.published_claim_evidence where extraction_withdrawn), 0::bigint,
  'en senere beslutning som opprettholder ekstraksjonen opphever merket'
);
select is(
  (select withdrawn_evidence_count from api.published_claims), 0::bigint,
  'og påstandssammendraget følger med tilbake'
);
select is_empty(
  'select 1 from api.published_claim_evidence where extraction_withdrawal_rationale is not null',
  'begrunnelsen for en beslutning som opprettholdt ekstraksjonen er ikke publisert innhold'
);
reset role;

-- ===========================================================================
-- Del 8 — Tilstandsoverganger: projeksjonen følger publiseringstilstanden
-- ===========================================================================

-- Tilbaketrekking av påstanden. retired_at nullstiller ikke
-- publiseringspekeren, så uten leddet «retired_at is null» i policyen ville en
-- tilbaketrukket påstand blitt stående som gjeldende kunnskap.
update knowledge.claims
set retired_at = now(), retirement_note = 'Trukket tilbake i testen.'
where id = (select id from fixture where name = 'claim');

-- Begge lagene kontrolleres hver for seg. Viewet bærer sitt eget
-- «retired_at is null», og policyen bærer sitt: hadde bare det ene vært testet,
-- ville et ødelagt lag kunnet gjemme seg bak det andre.
grant usage on schema knowledge to anon;

set local role anon;
select is(
  (select count(*) from knowledge.claims), 0::bigint,
  'RLS skjuler den tilbaketrukne påstanden også ved direkte lesing av tabellen'
);
select is(
  (select count(*) from api.published_claims), 0::bigint,
  'en tilbaketrukket påstand forsvinner fra projeksjonen, selv om pekeren fortsatt står'
);
select is(
  (select count(*) from api.published_claim_evidence), 0::bigint,
  'evidensgrunnlaget under en tilbaketrukket påstand forsvinner med den'
);
select is(
  (select count(*) from api.published_drugs), 0::bigint,
  'virkestoffet forsvinner fra katalogen når det ikke lenger har publiserte påstander'
);
reset role;

select is(
  (select count(*) from api.published_claims), 0::bigint,
  'viewets eget «retired_at is null» skjuler den tilbaketrukne påstanden også forbi RLS'
);

revoke usage on schema knowledge from anon;

update knowledge.claims
set retired_at = null, retirement_note = null
where id = (select id from fixture where name = 'claim');

set local role anon;
select is(
  (select count(*) from api.published_claims), 1::bigint,
  'påstanden er synlig igjen når tilbaketrekkingen oppheves'
);
reset role;

-- Avpublisering gjennom den kontrollerte operasjonen.
select set_config('request.jwt.claims',
                  '{"sub":"eeeeeeee-0000-0000-0000-000000000002"}', true);
select lives_ok(
  $$select knowledge.withdraw_claim_publication(
      (select id from fixture where name = 'claim'),
      (select id from fixture where name = 'publisher'),
      'Avpublisert for tilgangstestene i 290.')$$,
  'avpublisering lar seg utføre'
);
select set_config('request.jwt.claims', '', true);

set local role anon;
select is(
  (select count(*) from api.published_claims), 0::bigint,
  'en avpublisert påstand forsvinner fra projeksjonen'
);
select is(
  (select count(*) from api.published_claim_evidence), 0::bigint,
  'og evidensgrunnlaget under den forsvinner med den'
);
reset role;

select * from finish();

rollback;
