-- Migrasjon 007d — den redaksjonelle lesemodellen registreringen av et
-- EvidenceItem trenger.
--
-- Seks views i `api` og seks nye RLS-policyer under dem. Filen prøver tre ting:
-- kontrakten (hvem som kan lese hva), radgrensen (at den faktisk skiller en
-- editor fra alle andre, i hver av sine grener), og at radgrensen er den samme
-- regelen som skriveveiene håndhever — ikke en andre, litt annerledes sannhet
-- om hvem som er editor.
--
-- Kolonner og typer i de seks viewene dekkes av
-- 340_api_column_contract_test.sql, som gjør det uttømmende for hele `api`.
--
-- SQLSTATE 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(20);

-- ===========================================================================
-- Del 1 — Kontrakten: hvem kan lese viewene, og hvem kan kjøre radgrensen
-- ===========================================================================
select has_function(
  'workflow', 'caller_is_active_editor', 'workflow.caller_is_active_editor() finnes'
);
select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'workflow.caller_is_active_editor()'::regprocedure),
  'radgrensen er SECURITY DEFINER: svaret skal ikke avhenge av hva kalleren tilfeldigvis kan lese om seg selv'
);

-- Bare SELECT, og bare til authenticated. anon har ingenting: den redaksjonelle
-- lesemodellen er ikke publisert innhold, og et tomt svar til en uinnlogget
-- kaller ville vært en tomhet som så ut som en liste.
select is_empty(
  $$
    select t.view_name, r.role_name, p.privilege
    from (values ('api.editor_sources'), ('api.editor_source_versions'),
                 ('api.editor_drugs'), ('api.editor_outcomes'),
                 ('api.editor_populations'), ('api.editor_evidence_items'))
           as t(view_name)
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'),
                       ('references'), ('trigger')) as p(privilege)
    where has_table_privilege(r.role_name, t.view_name, p.privilege)
      and not (p.privilege = 'select' and r.role_name = 'authenticated')
  $$,
  'de seks viewene gir bare SELECT, og bare til authenticated'
);
select is_empty(
  $$
    select t.view_name
    from (values ('api.editor_sources'), ('api.editor_source_versions'),
                 ('api.editor_drugs'), ('api.editor_outcomes'),
                 ('api.editor_populations'), ('api.editor_evidence_items'))
           as t(view_name)
    where not has_table_privilege('authenticated', t.view_name, 'select')
  $$,
  'authenticated kan lese alle seks viewene'
);

-- ===========================================================================
-- Del 2 — Fiksturen: seks kallere som spenner ut radgrensen
--
--   A  ingen aktørrad
--   B  aktør, ingen rolletildeling
--   C  aktør, tilbaketrukket, med en ellers gyldig editor-tildeling
--   D  aktør, reviewer-tildeling (ikke editor)
--   E  aktør, editor-tildeling avgrenset til «vektendring»
--   F  aktør, editor-tildeling uavgrenset
--
-- Én upublisert kilde med ett øyeblikksbilde og ett evidensfunn. Ingenting i
-- denne transaksjonen er publisert, så det publiserte predikatet gir null rader
-- til alle — og enhver rad en kaller ser her, ser hen i kraft av editor-rollen.
-- ===========================================================================
insert into auth.users (id, email) values
  ('40000000-0000-4000-8000-00000000000a', 'lesemodell-400-a@test.invalid'),
  ('40000000-0000-4000-8000-00000000000b', 'lesemodell-400-b@test.invalid'),
  ('40000000-0000-4000-8000-00000000000c', 'lesemodell-400-c@test.invalid'),
  ('40000000-0000-4000-8000-00000000000d', 'lesemodell-400-d@test.invalid'),
  ('40000000-0000-4000-8000-00000000000e', 'lesemodell-400-e@test.invalid'),
  ('40000000-0000-4000-8000-00000000000f', 'lesemodell-400-f@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id, retired_at, retirement_note)
values
  ('ac400000-0000-4000-8000-00000000000b', 'human', 'human:lesemodell-400-b', 'Kaller B',
   'Aktør uten rolletildeling, for 400.', '40000000-0000-4000-8000-00000000000b', null, null),
  ('ac400000-0000-4000-8000-00000000000c', 'human', 'human:lesemodell-400-c', 'Kaller C',
   'Tilbaketrukket aktør med en ellers gyldig editor-tildeling, for 400.',
   '40000000-0000-4000-8000-00000000000c',
   now() - interval '1 day', 'Trukket tilbake for testene i 400.'),
  ('ac400000-0000-4000-8000-00000000000d', 'human', 'human:lesemodell-400-d', 'Kaller D',
   'Aktør med reviewer-rolle, ikke editor, for 400.', '40000000-0000-4000-8000-00000000000d',
   null, null),
  ('ac400000-0000-4000-8000-00000000000e', 'human', 'human:lesemodell-400-e', 'Kaller E',
   'Aktør med editor-rolle avgrenset til vektendring, for 400.',
   '40000000-0000-4000-8000-00000000000e', null, null),
  ('ac400000-0000-4000-8000-00000000000f', 'human', 'human:lesemodell-400-f', 'Kaller F',
   'Aktør med uavgrenset editor-rolle, for 400.', '40000000-0000-4000-8000-00000000000f',
   null, null);

create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id)
select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id)
select 'actor_e', id from provenance.actors where actor_key = 'human:lesemodell-400-e';
insert into fixture (name, id)
select 'actor_c', id from provenance.actors where actor_key = 'human:lesemodell-400-c';
insert into fixture (name, id)
select 'actor_f', id from provenance.actors where actor_key = 'human:lesemodell-400-f';

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('40000000-0000-4000-8000-00000000000c', 'editor', null, now() - interval '1 year',
   (select id from fixture where name = 'actor_c'), 'Ellers gyldig tildeling for tilbaketrukket kaller C.'),
  ('40000000-0000-4000-8000-00000000000d', 'reviewer', null, now() - interval '1 year',
   (select id from fixture where name = 'actor_e'), 'Reviewer, ikke editor, for kaller D.'),
  ('40000000-0000-4000-8000-00000000000e', 'editor', (select id from fixture where name = 'weight'),
   now() - interval '1 year',
   (select id from fixture where name = 'actor_e'), 'Avgrenset editor-tildeling for kaller E.'),
  ('40000000-0000-4000-8000-00000000000f', 'editor', null, now() - interval '1 year',
   (select id from fixture where name = 'actor_f'), 'Uavgrenset editor-tildeling for kaller F.');

insert into knowledge.sources
  (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('54000000-0000-4000-8000-000000000001', 'journal_article',
        'Upublisert testkilde for 400', 'Testforfatter 400',
        (select id from fixture where name = 'actor_f'));

insert into knowledge.source_versions
  (source_id, retrieved_at, retrieved_from, retrieved_by_actor_id)
values ('54000000-0000-4000-8000-000000000001', now() - interval '1 day',
        'https://eksempel.invalid/400',
        (select id from provenance.actors where actor_key = 'agent:evidence-extraction'));

insert into knowledge.evidence_items (
  source_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
select '54000000-0000-4000-8000-000000000001', 'randomized_controlled_trial',
       'not_reported', 'Populasjonen er ikke beskrevet i kilden.',
       'not_reported', (select id from fixture where name = 'sertralin'), 'none',
       (select id from fixture where name = 'weight'), 'Vektendring, ikke tallfestet.',
       'not_reported', 'not_stated', 'not_reported', 'not_reported',
       'Avsnitt 1', 'manual', (select id from fixture where name = 'actor_f');

-- ===========================================================================
-- Del 3 — Radgrensen og skriveveiens kontroll er samme regel
--
-- workflow.caller_is_active_editor() svarer med en boolean; skriveveiene bruker
-- knowledge.assert_editor_authorized(uuid), som avviser. To formuleringer av
-- samme tre krav kan drive fra hverandre, og et avvik ville vært en
-- tilgangsforskjell ingen leste som en forskjell. Her kontrolleres de mot
-- hverandre for hver av de seks kallerne.
--
-- Begge kjøres som eier: begge leser auth.uid(), ikke den aktive rollen, og
-- poenget er å sammenligne de to svarene — ikke å prøve klientrettighetene, som
-- prøves i del 4.
-- ===========================================================================
create function pg_temp.assert_passes()
  returns boolean
  language plpgsql
as $$
begin
  perform knowledge.assert_editor_authorized();
  return true;
exception when insufficient_privilege then
  return false;
end;
$$;

create temporary table agreement (
  caller text primary key,
  predicate boolean not null,
  assertion boolean not null
) on commit drop;

do $$
declare
  v_caller record;
begin
  for v_caller in
    select * from (values
      ('A ingen aktør',        '40000000-0000-4000-8000-00000000000a'),
      ('B ingen rolle',        '40000000-0000-4000-8000-00000000000b'),
      ('C tilbaketrukket',     '40000000-0000-4000-8000-00000000000c'),
      ('D reviewer',           '40000000-0000-4000-8000-00000000000d'),
      ('E avgrenset editor',   '40000000-0000-4000-8000-00000000000e'),
      ('F uavgrenset editor',  '40000000-0000-4000-8000-00000000000f')
    ) as t(caller, sub)
  loop
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_caller.sub)::text, true);
    insert into agreement (caller, predicate, assertion)
    values (v_caller.caller,
            workflow.caller_is_active_editor(),
            pg_temp.assert_passes());
  end loop;
  perform set_config('request.jwt.claims', '', true);
end;
$$;

select results_eq(
  $$select caller, predicate from agreement order by caller$$,
  $$
    values ('A ingen aktør', false),
           ('B ingen rolle', false),
           ('C tilbaketrukket', false),
           ('D reviewer', false),
           ('E avgrenset editor', true),
           ('F uavgrenset editor', true)
  $$,
  'radgrensen er sann for de to editorene og usann for de fire andre, inkludert den tilbaketrukne'
);
select is_empty(
  $$select caller from agreement where predicate is distinct from assertion$$,
  'radgrensen og skriveveiens kontroll svarer likt for hver kaller'
);

-- ===========================================================================
-- Del 4 — Faktiske oppslag, med de faktiske klientrettighetene
-- ===========================================================================

-- anon er avvist på alle seks, og får ikke et tomt svar som kunne lest som «det
-- finnes ingenting å registrere mot».
set local role anon;
select throws_ok(
  'select 1 from api.editor_sources', '42501', null,
  'anon nektes lesing av kilderegisteret'
);
select throws_ok(
  'select 1 from api.editor_source_versions', '42501', null,
  'anon nektes lesing av kildeversjonene'
);
select throws_ok(
  'select 1 from api.editor_drugs', '42501', null,
  'anon nektes lesing av virkestoffkatalogen'
);
select throws_ok(
  'select 1 from api.editor_outcomes', '42501', null,
  'anon nektes lesing av endepunktene'
);
select throws_ok(
  'select 1 from api.editor_populations', '42501', null,
  'anon nektes lesing av populasjonene'
);
select throws_ok(
  'select 1 from api.editor_evidence_items', '42501', null,
  'anon nektes lesing av evidensfunnene'
);
-- Og radgrensen selv er utenfor rekkevidde for en klientrolle: schemaet
-- workflow kan ikke navngis. Granten på funksjonen finnes bare for at
-- policyuttrykkene skal kunne evalueres.
select throws_ok(
  'select workflow.caller_is_active_editor()', '42501', null,
  'anon kan ikke kalle radgrensen direkte'
);
reset role;

set local role authenticated;
select throws_ok(
  'select workflow.caller_is_active_editor()', '42501', null,
  'heller ikke en innlogget kaller kan kalle radgrensen direkte: schemaet workflow kan ikke navngis'
);
reset role;

-- ---------------------------------------------------------------------------
-- De fire kallerne uten editor-rett ser ingenting. Ikke en feil: ingenting er
-- publisert i denne transaksjonen, så det publiserte predikatet gir null rader.
-- ---------------------------------------------------------------------------
create temporary table seen (
  caller text not null,
  view_name text not null,
  rows_seen bigint not null,
  primary key (caller, view_name)
) on commit drop;
grant insert on seen to authenticated;

select set_config('request.jwt.claims',
                  '{"sub":"40000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
insert into seen (caller, view_name, rows_seen)
select 'B', 'editor_sources', count(*) from api.editor_sources
union all select 'B', 'editor_source_versions', count(*) from api.editor_source_versions
union all select 'B', 'editor_drugs', count(*) from api.editor_drugs
union all select 'B', 'editor_outcomes', count(*) from api.editor_outcomes
union all select 'B', 'editor_populations', count(*) from api.editor_populations
union all select 'B', 'editor_evidence_items', count(*) from api.editor_evidence_items;
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"40000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
insert into seen (caller, view_name, rows_seen)
select 'C', 'editor_sources', count(*) from api.editor_sources
union all select 'C', 'editor_evidence_items', count(*) from api.editor_evidence_items;
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"40000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
insert into seen (caller, view_name, rows_seen)
select 'D', 'editor_sources', count(*) from api.editor_sources
union all select 'D', 'editor_evidence_items', count(*) from api.editor_evidence_items;
reset role;

-- ---------------------------------------------------------------------------
-- De to editorene ser hele registeret — også den avgrensede. Avgrensningen
-- gjelder retten til å SKRIVE et bestemt objekt (migrasjon 007e), ikke
-- lesbarheten: en editor som ikke kunne se kilden, kunne ikke registrert noe
-- mot den heller.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
                  '{"sub":"40000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
insert into seen (caller, view_name, rows_seen)
select 'E', 'editor_sources', count(*) from api.editor_sources
union all select 'E', 'editor_source_versions', count(*) from api.editor_source_versions
union all select 'E', 'editor_drugs', count(*) from api.editor_drugs
union all select 'E', 'editor_outcomes', count(*) from api.editor_outcomes
union all select 'E', 'editor_populations', count(*) from api.editor_populations
union all select 'E', 'editor_evidence_items', count(*) from api.editor_evidence_items;
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"40000000-0000-4000-8000-00000000000f"}', true);
set local role authenticated;
insert into seen (caller, view_name, rows_seen)
select 'F', 'editor_sources', count(*) from api.editor_sources
union all select 'F', 'editor_source_versions', count(*) from api.editor_source_versions
union all select 'F', 'editor_drugs', count(*) from api.editor_drugs
union all select 'F', 'editor_outcomes', count(*) from api.editor_outcomes
union all select 'F', 'editor_populations', count(*) from api.editor_populations
union all select 'F', 'editor_evidence_items', count(*) from api.editor_evidence_items;

-- Den ene spørringen skjemaet faktisk gjør etter en registrering: funnene under
-- én bestemt kilde.
insert into seen (caller, view_name, rows_seen)
select 'F', 'editor_evidence_items_for_source', count(*)
from api.editor_evidence_items
where source_id = '54000000-0000-4000-8000-000000000001';
reset role;
select set_config('request.jwt.claims', '', true);

select is_empty(
  $$select caller, view_name, rows_seen from seen where caller in ('B','C','D') and rows_seen <> 0$$,
  'en innlogget kaller uten gyldig editor-rolle ser null rader i den redaksjonelle lesemodellen, uansett hvilken av dem'
);

select results_eq(
  $$select view_name, rows_seen from seen where caller = 'E' order by view_name$$,
  $$
    values ('editor_drugs', 2::bigint),
           ('editor_evidence_items', 3::bigint),
           ('editor_outcomes', 1::bigint),
           ('editor_populations', 1::bigint),
           ('editor_source_versions', 3::bigint),
           ('editor_sources', 3::bigint)
  $$,
  'en editor avgrenset til ett endepunkt ser likevel hele registeret: de to seedede kildene og den upubliserte'
);

select results_eq(
  $$select view_name, rows_seen from seen where caller = 'F' order by view_name$$,
  $$
    values ('editor_drugs', 2::bigint),
           ('editor_evidence_items', 3::bigint),
           ('editor_evidence_items_for_source', 1::bigint),
           ('editor_outcomes', 1::bigint),
           ('editor_populations', 1::bigint),
           ('editor_source_versions', 3::bigint),
           ('editor_sources', 3::bigint)
  $$,
  'en uavgrenset editor ser det samme, og oppslaget på én kilde gir nøyaktig det ene funnet som er registrert på den'
);

-- ===========================================================================
-- Del 5 — Hva viewene projiserer, og hva de ikke gjør
-- ===========================================================================

-- editor_outcomes skal være nøyaktig endepunktene. Et diagnosebegrep er ikke et
-- endepunkt, og en registrering som kunne velge det ville brutt
-- fremmednøkkelen mot (id, concept_type).
select set_config('request.jwt.claims',
                  '{"sub":"40000000-0000-4000-8000-00000000000f"}', true);
set local role authenticated;
select set_eq(
  $$select canonical_label from api.editor_outcomes$$,
  $$values ('vektendring')$$,
  'editor_outcomes inneholder bare begreper av typen outcome, ikke diagnosebegrepet'
);
select results_eq(
  $$
    select source_title, intervention_drug_name, outcome_label, comparator_kind,
           comparator_drug_name, source_version_id, extraction_method
    from api.editor_evidence_items
    where source_id = '54000000-0000-4000-8000-000000000001'
  $$,
  $$
    values ('Upublisert testkilde for 400', 'sertralin', 'vektendring', 'none',
            null::text, null::uuid, 'manual')
  $$,
  'raden bærer kilden funnet hører til, og en komparator som ikke er et virkestoff gir NULL framfor en tom etikett'
);
reset role;
select set_config('request.jwt.claims', '', true);

-- ===========================================================================
-- Del 6 — De nye policyene åpner bare for lesing
-- ===========================================================================
select set_eq(
  $$
    select c.relname || ':' || p.polname
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('catalog', 'knowledge')
      and p.polname like '%_editor_read'
      and p.polcmd = 'r'
  $$,
  $$
    values ('sources:sources_editor_read'),
           ('source_versions:source_versions_editor_read'),
           ('evidence_items:evidence_items_editor_read'),
           ('drugs:drugs_editor_read'),
           ('clinical_concepts:clinical_concepts_editor_read'),
           ('populations:populations_editor_read')
  $$,
  'de seks redaksjonelle policyene finnes, og alle seks er SELECT-policyer'
);

select * from finish();

rollback;
