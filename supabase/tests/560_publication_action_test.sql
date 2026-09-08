-- Migrasjon 006g og 006h — publiseringsrettigheten og den redaksjonelle
-- handlingen som bruker den.
--
-- §74.36 kjørte hele kjeden mot de reelle radene: alle tretten vilkårene i
-- publiseringsgaten passerte, og det som stoppet publiseringen var en rettighet
-- ingen migrasjon tildelte. Denne filen dekker begge halvdelene av det som ble
-- bygget for å lukke det:
--
--   006g  tildelingen av publisher-rollen, med begge grenene av den
--         miljøavhengige funksjonen og alle fire tilstandene en eksisterende
--         tildeling kan stå i (samme form som 380_source_registration_role_test.sql)
--   006h  api.publish_claim_revision(uuid, text), den eneste veien fra et
--         grensesnitt inn i den kontrollerte publiseringsoperasjonen
--
-- Den viktigste assertionen i filen er den siste: publisher-rollen åpner ingen
-- gate. En publisher uten kontrollert grunnlag får den samme avvisningen som
-- før, og godkjenning og publisering er fortsatt to rettigheter.
--
-- SQLSTATE 42501 = insufficient_privilege, 23001 = restrict_violation,
-- 22023 = invalid_parameter_value, P0002 = no_data_found.
begin;

create extension if not exists pgtap with schema extensions;

select plan(26);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'workflow', 'ensure_publisher_role_grant', 'workflow.ensure_publisher_role_grant() finnes'
);
select has_function(
  'api', 'publish_claim_revision', 'api.publish_claim_revision() finnes'
);
select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.publish_claim_revision(uuid,text)'::regprocedure),
  'api.publish_claim_revision() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name, 'api.publish_claim_revision(uuid,text)'::regprocedure, 'execute')
  $$,
  'api.publish_claim_revision() er kjørbar bare for authenticated'
);
-- Den underliggende operasjonen forblir utilgjengelig for enhver klientrolle:
-- api-funksjonen er inngangen, ikke en av to.
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name, 'knowledge.publish_claim_revision(uuid,uuid,text)'::regprocedure, 'execute')
  $$,
  'ingen klientrolle kan kalle knowledge.publish_claim_revision() direkte'
);

-- ===========================================================================
-- Del 2 — Tildelingen: den negative grenen
--
-- Tilstanden i CI og i enhver lokal stack. Kallet går ikke stille: statusen
-- kommer tilbake til kalleren, og funksjonen gir i tillegg en notice.
-- ===========================================================================
select is(
  workflow.ensure_publisher_role_grant(),
  'account_missing',
  'uten brukerkontoen i auth.users rapporterer funksjonen at kontoen mangler'
);
select is_empty(
  $$select role_code::text from workflow.user_roles
    where user_id = 'a703ede9-3f58-4de9-8c85-73936d58df1f'$$,
  'den negative grenen tildeler ingen rolle'
);

-- ===========================================================================
-- Del 3 — Tildelingen: forutsetningene, prøvd framfor antatt
-- ===========================================================================
insert into auth.users (id, email)
values ('a703ede9-3f58-4de9-8c85-73936d58df1f', 'redaktor-560@test.invalid');

select throws_ok(
  $$select workflow.ensure_publisher_role_grant()$$,
  '23001',
  'Aktøren ''human:peder-holman'' er ikke knyttet til brukerkontoen ''a703ede9-3f58-4de9-8c85-73936d58df1f'', og kan ikke tildeles publisher-rollen for den.',
  'uten koblingen fra 005b tildeles ingen publisher-rolle til en konto uten aktør'
);

-- Produksjonens egen rekkefølge: 005b knytter kontoen og tildeler reviewer.
select is(
  workflow.ensure_named_editor_authorization(),
  'authorized',
  'migrasjon 005b knytter kontoen og tildeler reviewer-rollen først, som i produksjon'
);
select is(
  workflow.ensure_publisher_role_grant(),
  'authorized',
  'med konto og kobling på plass skrives publisher-tildelingen'
);
select is(
  workflow.ensure_publisher_role_grant(),
  'already_authorized',
  'et nytt kall etter en fullført tildeling rapporterer at den allerede er gjort'
);
select results_eq(
  $$
    select ur.role_code::text, ur.scope_id is null, ur.valid_to is null, g.actor_key
    from workflow.user_roles ur
    join provenance.actors g on g.id = ur.granted_by_actor_id
    where ur.user_id = 'a703ede9-3f58-4de9-8c85-73936d58df1f'
    order by ur.role_code::text
  $$,
  $$values ('publisher', true, true, 'human:peder-holman'),
           ('reviewer', true, true, 'human:peder-holman')$$,
  'begge tildelingene står side om side: den nye publisher og den uendrede reviewer fra 005b'
);

-- Selvtildelingen er ikke forbudt av noen CHECK, så begrunnelsen i raden er hele
-- sikringen. Ordet skal stå FØRST og ikke bare et sted i teksten.
select ok(
  (select grant_reason from workflow.user_roles
   where role_code = 'publisher' and user_id = 'a703ede9-3f58-4de9-8c85-73936d58df1f')
    like 'Selvtildeling%',
  'publisher-tildelingen navngir selvtildelingen i sin egen begrunnelse'
);
select isnt(
  (select grant_reason from workflow.user_roles
   where role_code = 'publisher' and user_id = 'a703ede9-3f58-4de9-8c85-73936d58df1f'),
  (select grant_reason from workflow.user_roles
   where role_code = 'reviewer' and user_id = 'a703ede9-3f58-4de9-8c85-73936d58df1f'),
  'publisher-tildelingen har sin egen begrunnelse og arver ikke reviewer-tildelingens'
);
select ok(
  (select grant_reason from workflow.user_roles
   where role_code = 'publisher' and user_id = 'a703ede9-3f58-4de9-8c85-73936d58df1f')
    like '%åpner heller ingen gate%',
  'begrunnelsen sier eksplisitt at rollen ikke åpner noen gate'
);
select results_eq(
  $$
    select e.object_schema, e.object_table, a.actor_key,
           e.old_revision_or_snapshot, e.new_revision_or_snapshot->>'scope_id'
    from audit.events e
    join provenance.actors a on a.id = e.actor_id
    where e.operation = 'role_granted'
      and e.new_revision_or_snapshot->>'role_code' = 'publisher'
  $$,
  $$values ('workflow', 'user_roles', 'human:peder-holman', null::jsonb, null::text)$$,
  'publisher-tildelingen legger igjen én auditrad, attribuert til aktøren som tildelte rollen'
);

-- ===========================================================================
-- Del 4 — De fire lovlige tilstandene en eksisterende tildeling kan stå i
-- ===========================================================================
-- 1. Gyldig nå, men tidsavgrenset.
update workflow.user_roles
set valid_to = now() + interval '30 days',
    ended_by_actor_id = granted_by_actor_id,
    end_reason = 'Planlagt utløpsdato satt i testen; tildelingen gjelder fortsatt.'
where role_code = 'publisher' and user_id = 'a703ede9-3f58-4de9-8c85-73936d58df1f';

select is(
  workflow.ensure_publisher_role_grant(),
  'already_authorized',
  'en tidsavgrenset tildeling som gjelder nå leses som gyldig, ikke som fraværende'
);

-- 2. Avsluttet tildeling: skal aldri gjeninnføres av en migrasjonskjøring.
delete from workflow.user_roles
where role_code = 'publisher' and user_id = 'a703ede9-3f58-4de9-8c85-73936d58df1f';
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to,
   granted_by_actor_id, grant_reason, ended_by_actor_id, end_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'publisher', null,
       now() - interval '2 years', now() - interval '1 year',
       a.id, 'Opprinnelig tildeling i testen.', a.id, 'Tilbakekalt i testen.'
from provenance.actors a where a.actor_key = 'human:peder-holman';

select is(
  workflow.ensure_publisher_role_grant(),
  'role_ended',
  'en avsluttet publisher-tildeling rapporteres som avsluttet, ikke som fraværende'
);
select results_eq(
  $$
    select ur.valid_to < statement_timestamp(), ur.end_reason
    from workflow.user_roles ur
    where ur.role_code = 'publisher'
      and ur.user_id = 'a703ede9-3f58-4de9-8c85-73936d58df1f'
  $$,
  $$values (true, 'Tilbakekalt i testen.')$$,
  'tilbakekallingen står urørt, og ingen ny tildeling er skrevet ved siden av den'
);

-- 3. Tildeling som først begynner å gjelde senere.
delete from workflow.user_roles
where role_code = 'publisher' and user_id = 'a703ede9-3f58-4de9-8c85-73936d58df1f';
insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select 'a703ede9-3f58-4de9-8c85-73936d58df1f', 'publisher', null,
       now() + interval '30 days', a.id, 'Framtidig tildeling i testen.'
from provenance.actors a where a.actor_key = 'human:peder-holman';

select is(
  workflow.ensure_publisher_role_grant(),
  'role_not_yet_valid',
  'en tildeling som begynner å gjelde senere rapporteres som det, og overlappes ikke'
);

-- ===========================================================================
-- Del 5 — Fikstur for selve publiseringshandlingen
--
-- Egne kontoer, slik at hver gren står for seg og ikke avhenger av tilstanden i
-- Del 4. P har publisher-rollen; R har bare reviewer.
-- ===========================================================================
delete from workflow.user_roles
where role_code = 'publisher' and user_id = 'a703ede9-3f58-4de9-8c85-73936d58df1f';

insert into auth.users (id, instance_id, aud, role, email)
select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u.email
from (values
  ('56000000-0000-4000-8000-0000000000a0'::uuid, 'a560@example.test'),
  ('56000000-0000-4000-8000-000000000010'::uuid, 'p560@example.test'),
  ('56000000-0000-4000-8000-000000000020'::uuid, 'r560@example.test')
) as u(id, email);

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values
  ('56000000-0000-4000-8000-000000000011', 'human:p-560', 'human', 'Publisher 560',
   'Konto med publisher-rolle, for 560.', '56000000-0000-4000-8000-000000000010'),
  ('56000000-0000-4000-8000-000000000021', 'human:r-560', 'human', 'Reviewer 560',
   'Konto med bare reviewer-rolle, for 560.', '56000000-0000-4000-8000-000000000020');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('56000000-0000-4000-8000-000000000010', 'publisher', null, now() - interval '1 year',
   '56000000-0000-4000-8000-000000000011', 'Publisher-tildeling for 560.'),
  ('56000000-0000-4000-8000-000000000020', 'reviewer', null, now() - interval '1 year',
   '56000000-0000-4000-8000-000000000011', 'Reviewer-tildeling for 560.');

create temporary table target (id uuid) on commit drop;
insert into target select id from knowledge.claim_revisions order by id limit 1;
grant select on target to authenticated;

-- ===========================================================================
-- Del 6 — Skriveveien: hver avvisning
-- ===========================================================================
-- A: konto uten aktørrad
select set_config('request.jwt.claims',
                  '{"sub":"56000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select throws_ok(
  $$select api.publish_claim_revision((select id from target), 'Prøve i 560.')$$,
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en kaller uten aktørrad kan ikke publisere i sitt eget navn'
);
reset role;

-- R: reviewer uten publisher-rolle. Å godkjenne og å publisere er to
-- rettigheter, og den ene gir ikke den andre.
select set_config('request.jwt.claims',
                  '{"sub":"56000000-0000-4000-8000-000000000020"}', true);
set local role authenticated;
select throws_ok(
  $$select api.publish_claim_revision((select id from target), 'Prøve i 560.')$$,
  '42501', 'Brukeren har ikke gyldig publisher-rolle for dette innholdsområdet.',
  'reviewer-rollen gir ingen publiseringsrett'
);
reset role;

-- P: publisher, men grunnlaget er ikke kontrollert. Dette er filens viktigste
-- assertion: rollen åpner ingen gate.
select set_config('request.jwt.claims',
                  '{"sub":"56000000-0000-4000-8000-000000000010"}', true);
set local role authenticated;
select throws_like(
  $$select api.publish_claim_revision((select id from target), 'Prøve i 560.')$$,
  '%uten registrert ekstraksjonsverifikasjon%',
  'publisher-rollen åpner ingen gate: publiseringen stopper fortsatt på det første kravet som ikke er oppfylt'
);
select throws_ok(
  $$select api.publish_claim_revision('56000000-0000-4000-8000-0000000000ff', 'Prøve i 560.')$$,
  '22023', 'Påstandsrevisjon ''56000000-0000-4000-8000-0000000000ff'' finnes ikke.',
  'en revisjon som ikke finnes avvises av publiseringsoperasjonen selv'
);
reset role;

-- Ingenting er publisert, og ingen hendelse er registrert.
select is(
  (select count(*) from knowledge.publication_events),
  0::bigint,
  'ingen av de avviste forsøkene la igjen en publiseringshendelse'
);
select is_empty(
  $$select id from knowledge.claims where current_published_revision_id is not null$$,
  'og ingen påstand har fått flyttet publiseringspekeren sin'
);

select finish();
rollback;
