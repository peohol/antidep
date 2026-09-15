-- Migrasjon 008 — auditloggens atferd.
--
-- Verifiserer at de to produsentene faktisk skriver, at de skriver riktig, at
-- constraintene på audit.events avviser en rad som ikke henger sammen, og at de
-- to egenskapene migrasjonen argumenterer for — at auditraden overlever objektet
-- sitt, og at en operasjon som ikke kan auditeres heller ikke kan utføres —
-- holder i praksis framfor bare i kommentaren.
--
-- Strukturen testes i 300 og tilgangen i 310. Den fullstendige veien gjennom
-- knowledge.publish_claim_revision() dekkes av 260_publication_operations_test.sql,
-- som kjører med auditskriveren påkoblet; her drives de fire
-- tilstandsovergangene ved å skrive publiseringshendelsene direkte, slik at alle
-- fire kan dekkes uten å bygge fire komplette publiseringsgater.
--
-- SQLSTATE 23001 = restrict_violation, 23503 = foreign_key_violation,
-- 23514 = check_violation, 42501 = insufficient_privilege,
-- 428C9 = generated_always.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(33);

create temporary table fixture (name text primary key, id uuid not null) on commit drop;

-- ---------------------------------------------------------------------------
-- Aktører og brukerkontoer
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'publisher-320@test.invalid'),
  ('eeeeeeee-0000-0000-0000-000000000002', 'admin-320@test.invalid'),
  ('eeeeeeee-0000-0000-0000-000000000003', 'mottaker-320@test.invalid');

-- Aktør-ID-ene er oppgitt eksplisitt framfor genererte, fordi den siste testen i
-- filen kjører som anon og da ikke kan slå opp aktøren: anon mangler usage på
-- provenance. Et oppslag der ville gjort at forsøket feilet på delspørringen
-- framfor på det testen måler — mutasjonstesten viste nettopp det.
insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('eeeeeeee-1111-0000-0000-000000000001', 'human', 'human:publisher-320', 'Publisher',
   'Menneskelig aktør som utfører publiseringene i denne filen.',
   'eeeeeeee-0000-0000-0000-000000000001'),
  ('eeeeeeee-1111-0000-0000-000000000002', 'human', 'human:admin-320', 'Administrator',
   'Menneskelig aktør som tildeler og tilbakekaller roller i denne filen.',
   'eeeeeeee-0000-0000-0000-000000000002');

insert into fixture (name, id)
select 'publisher', id from provenance.actors where actor_key = 'human:publisher-320';
insert into fixture (name, id)
select 'admin', id from provenance.actors where actor_key = 'human:admin-320';
insert into fixture (name, id)
select 'synthesis_actor', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id)
select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'drug', id from catalog.drugs where canonical_name = 'sertralin';

-- ---------------------------------------------------------------------------
-- En påstand med to revisjoner, nok til at alle fire tilstandsovergangene i
-- DATABASE_ARCHITECTURE.md §39 kan uttrykkes som én sammenhengende kjede.
-- ---------------------------------------------------------------------------
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'drug' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'claim', id from inserted;

insert into knowledge.claim_revisions (
  claim_id, revision_number, knowledge_type, subject_drug_id,
  statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id
)
select c.id, n.revision_number, c.knowledge_type, c.subject_drug_id,
       format('Testformulering nummer %s.', n.revision_number),
       'Gjelder bare testene i denne filen.', 'none', 'Testusikkerhet.',
       c.created_by_actor_id
from knowledge.claims c, (values (1), (2)) as n(revision_number)
where c.id = (select id from fixture where name = 'claim');

insert into fixture (name, id)
select 'rev1', r.id from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'claim') and r.revision_number = 1;
insert into fixture (name, id)
select 'rev2', r.id from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'claim') and r.revision_number = 2;

-- ---------------------------------------------------------------------------
-- Publiseringskjeden: publish rev1 → replace rev2 → rollback rev1 → withdraw.
--
-- published_at settes med synkende avstand bakover i tid, slik at rekkefølgen i
-- assertionene under er den faktiske hendelsesrekkefølgen og ikke en tilfeldig
-- radrekkefølge. Det er også den eneste rekkefølgen auditloggen selv påstår noe
-- om: den daterer, den ordner ikke (se migrasjonens innledning).
-- ---------------------------------------------------------------------------
with e1 as (
  insert into knowledge.publication_events
    (claim_id, action, revision_id, revision_number,
     published_by_actor_id, published_by_actor_type, reason, published_at)
  select f.id, 'publish', r1.id, 1, p.id, 'human',
         'Første publisering.', now() - interval '4 minutes'
  from fixture f, fixture r1, fixture p
  where f.name = 'claim' and r1.name = 'rev1' and p.name = 'publisher'
  returning id
), e2 as (
  insert into knowledge.publication_events
    (claim_id, action, revision_id, revision_number,
     previous_revision_id, previous_revision_number, previous_event_id,
     published_by_actor_id, published_by_actor_type, reason, published_at)
  select f.id, 'replace', r2.id, 2, r1.id, 1, e1.id, p.id, 'human',
         'Erstattet med nyere revisjon.', now() - interval '3 minutes'
  from fixture f, fixture r1, fixture r2, fixture p, e1
  where f.name = 'claim' and r1.name = 'rev1' and r2.name = 'rev2' and p.name = 'publisher'
  returning id
), e3 as (
  insert into knowledge.publication_events
    (claim_id, action, revision_id, revision_number,
     previous_revision_id, previous_revision_number, previous_event_id,
     published_by_actor_id, published_by_actor_type, reason, published_at)
  select f.id, 'rollback', r1.id, 1, r2.id, 2, e2.id, p.id, 'human',
         'Rullet tilbake til forrige revisjon.', now() - interval '2 minutes'
  from fixture f, fixture r1, fixture r2, fixture p, e2
  where f.name = 'claim' and r1.name = 'rev1' and r2.name = 'rev2' and p.name = 'publisher'
  returning id
)
insert into knowledge.publication_events
  (claim_id, action, previous_revision_id, previous_revision_number, previous_event_id,
   published_by_actor_id, published_by_actor_type, reason, published_at)
select f.id, 'withdraw', r1.id, 1, e3.id, p.id, 'human',
       'Trukket tilbake i påvente av ny vurdering.', now() - interval '1 minute'
from fixture f, fixture r1, fixture p, e3
where f.name = 'claim' and r1.name = 'rev1' and p.name = 'publisher';

-- ---------------------------------------------------------------------------
-- Hver publiseringshendelse ga én auditrad, og de fire handlingene ble til de
-- fire tilsvarende operasjonene
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::integer from audit.events
   where object_id = (select id from fixture where name = 'claim')),
  4,
  'de fire publiseringshendelsene ga fire auditrader'
);

select results_eq(
  $$
    select operation::text
    from audit.events
    where object_id = (select id from fixture where name = 'claim')
    order by occurred_at
  $$,
  $$
    values ('claim_published'), ('claim_publication_replaced'),
           ('claim_publication_rolled_back'), ('claim_publication_withdrawn')
  $$,
  'hver publiseringshandling ble oversatt til sin egen auditoperasjon'
);

select is_empty(
  $$
    select e.id::text
    from audit.events e
    where e.object_id = (select id from fixture where name = 'claim')
      and (e.object_schema, e.object_table) is distinct from ('knowledge', 'claims')
  $$,
  'auditraden peker på påstanden, ikke på hendelsen som utløste den'
);

select is_empty(
  $$
    select e.id::text
    from audit.events e
    where e.object_id = (select id from fixture where name = 'claim')
      and e.actor_id <> (select id from fixture where name = 'publisher')
  $$,
  'publiseringen er attribuert til aktøren som utførte den (ANTIDEP_CONSTITUTION.md §14)'
);

-- Begrunnelsen kopieres framfor å formuleres på nytt, slik at loggen og
-- publiseringshendelsen sier det samme.
select results_eq(
  $$
    select e.reason
    from audit.events e
    where e.object_id = (select id from fixture where name = 'claim')
    order by e.occurred_at
  $$,
  $$
    values ('Første publisering.'), ('Erstattet med nyere revisjon.'),
           ('Rullet tilbake til forrige revisjon.'),
           ('Trukket tilbake i påvente av ny vurdering.')
  $$,
  'begrunnelsen følger med fra publiseringshendelsen'
);

-- occurred_at er hendelsestidspunktet, ikke registreringstidspunktet. Kjeden ble
-- skrevet nå, men datert bakover; skiller loggen ikke mellom de to, ville alle
-- fire fått samme tid.
-- Formulert som en telling framfor som is_empty over den samme joinen: en
-- is_empty ville passert også når joinen ikke traff i det hele tatt, altså
-- nettopp når occurred_at var feil. Mutasjonen «bruk now() som hendelsestid»
-- overlevde den formuleringen.
select is(
  (select count(*)::integer
   from audit.events e
   join knowledge.publication_events pe
     on pe.claim_id = e.object_id and pe.published_at = e.occurred_at
   where e.object_id = (select id from fixture where name = 'claim')
     and e.occurred_at < e.created_at),
  4,
  'occurred_at er publiseringstidspunktet fra hendelsen, og ligger før created_at'
);

-- ---------------------------------------------------------------------------
-- Snapshotene beskriver publiseringspekeren før og etter
-- ---------------------------------------------------------------------------
select ok(
  (select e.old_revision_or_snapshot ? 'current_published_revision_id'
      and e.old_revision_or_snapshot ->> 'current_published_revision_id' is null
   from audit.events e
   where e.object_id = (select id from fixture where name = 'claim')
     and e.operation = 'claim_published'),
  'førstegangspubliseringen har et old-snapshot der pekeren er tom, ikke et tomt old-snapshot'
);

select is(
  (select e.new_revision_or_snapshot ->> 'current_published_revision_id'
   from audit.events e
   where e.object_id = (select id from fixture where name = 'claim')
     and e.operation = 'claim_published'),
  (select id::text from fixture where name = 'rev1'),
  'førstegangspubliseringen registrerer hvilken revisjon som ble publisert'
);

select results_eq(
  $$
    select e.old_revision_or_snapshot ->> 'current_published_revision_id',
           e.new_revision_or_snapshot ->> 'current_published_revision_id'
    from audit.events e
    where e.object_id = (select id from fixture where name = 'claim')
      and e.operation = 'claim_publication_replaced'
  $$,
  $$
    select (select id::text from fixture where name = 'rev1'),
           (select id::text from fixture where name = 'rev2')
  $$,
  'erstatningen registrerer både revisjonen som gikk ut og den som kom inn'
);

select ok(
  (select e.new_revision_or_snapshot ->> 'current_published_revision_id' is null
   from audit.events e
   where e.object_id = (select id from fixture where name = 'claim')
     and e.operation = 'claim_publication_withdrawn'),
  'avpubliseringen registrerer at ingenting er publisert etterpå'
);

-- ---------------------------------------------------------------------------
-- Rolleforvaltningen
-- ---------------------------------------------------------------------------
insert into workflow.user_roles
  (user_id, role_code, valid_from, granted_by_actor_id, grant_reason)
values ('eeeeeeee-0000-0000-0000-000000000003', 'reviewer',
        now() - interval '1 hour',
        (select id from fixture where name = 'admin'),
        'Faglig godkjenningsrett for testene.');

insert into fixture (name, id)
select 'grant', id from workflow.user_roles
where user_id = 'eeeeeeee-0000-0000-0000-000000000003';

select is(
  (select count(*)::integer from audit.events
   where object_id = (select id from fixture where name = 'grant')),
  1,
  'rolletildelingen ga én auditrad'
);

select is_empty(
  $$
    select e.id::text
    from audit.events e
    where e.object_id = (select id from fixture where name = 'grant')
      and (e.operation, e.object_schema, e.object_table)
          is distinct from ('role_granted'::audit.event_operation, 'workflow', 'user_roles')
  $$,
  'tildelingen er registrert som role_granted på workflow.user_roles'
);

select ok(
  (select e.old_revision_or_snapshot is null
   from audit.events e
   where e.object_id = (select id from fixture where name = 'grant')),
  'tildelingen har intet old-snapshot: raden fantes ikke før'
);

-- Hele raden snapshotes, ikke bare det som endret seg. Til forskjell fra
-- publisering finnes det ingen hendelsestabell under workflow.user_roles, så
-- snapshotet er det eneste som bevarer hva rettigheten faktisk gjaldt.
select results_eq(
  $$
    select e.new_revision_or_snapshot ->> 'role_code',
           e.new_revision_or_snapshot ->> 'user_id',
           e.new_revision_or_snapshot ->> 'valid_to',
           e.reason,
           e.actor_id::text
    from audit.events e
    where e.object_id = (select id from fixture where name = 'grant')
  $$,
  $$
    select 'reviewer', 'eeeeeeee-0000-0000-0000-000000000003', null,
           'Faglig godkjenningsrett for testene.',
           (select id::text from fixture where name = 'admin')
  $$,
  'snapshotet bevarer hele rettigheten, og tildeleren står som aktør'
);

-- En oppdatering som ikke endrer gyldigheten er ikke en hendelse. Uten
-- WHEN-betingelsen på triggeren ville updated_at-oppdateringen alene lagt igjen
-- en auditrad om noe som ikke skjedde.
select lives_ok(
  $$
    update workflow.user_roles
    set grant_reason = grant_reason
    where id = (select id from fixture where name = 'grant')
  $$,
  'en oppdatering som ikke endrer gyldigheten er fortsatt lovlig'
);

select is(
  (select count(*)::integer from audit.events
   where object_id = (select id from fixture where name = 'grant')),
  1,
  'en oppdatering som ikke endrer gyldigheten gir ingen auditrad'
);

update workflow.user_roles
set valid_to = now(),
    ended_by_actor_id = (select id from fixture where name = 'publisher'),
    end_reason = 'Rettigheten er ikke lenger nødvendig.'
where id = (select id from fixture where name = 'grant');

select is(
  (select count(*)::integer from audit.events
   where object_id = (select id from fixture where name = 'grant')),
  2,
  'avslutningen av tildelingen ga en auditrad til'
);

select results_eq(
  $$
    select e.operation::text,
           (e.old_revision_or_snapshot ->> 'valid_to') is null,
           (e.new_revision_or_snapshot ->> 'valid_to') is not null,
           e.reason,
           e.actor_id::text
    from audit.events e
    where e.object_id = (select id from fixture where name = 'grant')
      and e.operation = 'role_ended'
  $$,
  $$
    select 'role_ended', true, true, 'Rettigheten er ikke lenger nødvendig.',
           (select id::text from fixture where name = 'publisher')
  $$,
  'avslutningen viser tilstanden før og etter, og attribueres til den som avsluttet'
);

-- ---------------------------------------------------------------------------
-- Append-only
-- ---------------------------------------------------------------------------
select throws_ok(
  $$update audit.events set reason = 'Omskrevet i ettertid.'$$,
  '23001', null,
  'en auditrad kan ikke skrives om, heller ikke av eieren'
);
select throws_ok(
  $$delete from audit.events$$,
  '23001', null,
  'en auditrad kan ikke slettes, heller ikke av eieren'
);

-- ---------------------------------------------------------------------------
-- Constraintene på raden
-- ---------------------------------------------------------------------------
select throws_ok(
  $$
    insert into audit.events (operation, object_schema, object_id, actor_id, new_revision_or_snapshot)
    values ('role_granted', 'knowledge', gen_random_uuid(),
            (select id from fixture where name = 'admin'), '{}'::jsonb)
  $$,
  '428C9', null,
  'object_schema kan ikke oppgis av kalleren; den er avledet av operasjonen'
);

select throws_ok(
  $$
    insert into audit.events (operation, object_id, actor_id,
                              old_revision_or_snapshot, new_revision_or_snapshot)
    select 'role_granted', f.id, a.id,
           jsonb_build_object('id', f.id), jsonb_build_object('id', f.id)
    from fixture f, fixture a
    where f.name = 'grant' and a.name = 'admin'
  $$,
  '23514', null,
  'en tildeling kan ikke ha et old-snapshot: raden fantes ikke før'
);

select throws_ok(
  $$
    insert into audit.events (operation, object_id, actor_id, new_revision_or_snapshot)
    select 'claim_published', f.id, a.id, jsonb_build_object('id', f.id)
    from fixture f, fixture a
    where f.name = 'claim' and a.name = 'publisher'
  $$,
  '23514', null,
  'en publisering kan ikke mangle old-snapshotet som viser hva som var publisert før'
);

select throws_ok(
  $$
    insert into audit.events (operation, object_id, actor_id, new_revision_or_snapshot)
    select 'role_granted', f.id, a.id, jsonb_build_object('id', gen_random_uuid())
    from fixture f, fixture a
    where f.name = 'grant' and a.name = 'admin'
  $$,
  '23514', null,
  'et snapshot som identifiserer en annen rad enn object_id avvises'
);

-- Uten jsonb_typeof-kontrollen ville denne sluppet gjennom: `->> 'id'` på en
-- array gir NULL framfor en feil, og en NULL-sammenligning passerer en CHECK.
select throws_ok(
  $$
    insert into audit.events (operation, object_id, actor_id, new_revision_or_snapshot)
    select 'role_granted', f.id, a.id, '[1, 2]'::jsonb
    from fixture f, fixture a
    where f.name = 'grant' and a.name = 'admin'
  $$,
  '23514', null,
  'et snapshot som ikke er et json-objekt avvises'
);

select throws_ok(
  $$
    insert into audit.events (operation, object_id, actor_id, new_revision_or_snapshot, occurred_at)
    select 'role_granted', f.id, a.id, jsonb_build_object('id', f.id), now() + interval '1 day'
    from fixture f, fixture a
    where f.name = 'grant' and a.name = 'admin'
  $$,
  '23514', null,
  'en operasjon kan ikke dateres til framtiden (DATABASE_ARCHITECTURE.md §7.3)'
);

select throws_ok(
  $$
    insert into audit.events (operation, object_id, actor_id, new_revision_or_snapshot, reason)
    select 'role_granted', f.id, a.id, jsonb_build_object('id', f.id), '   '
    from fixture f, fixture a
    where f.name = 'grant' and a.name = 'admin'
  $$,
  '23514', null,
  'en begrunnelse som bare er blanktegn avvises; da er NULL det ærlige svaret'
);

select throws_ok(
  $$
    insert into audit.events (operation, object_id, actor_id, new_revision_or_snapshot)
    select 'role_granted', f.id, '00000000-0000-0000-0000-0000000000fe',
           jsonb_build_object('id', f.id)
    from fixture f
    where f.name = 'grant'
  $$,
  '23503', null,
  'en auditrad kan ikke attribueres til en aktør som ikke finnes'
);

-- created_at eies av databasen. En kaller som oppgir den, skal ikke kunne
-- datere registreringen selv og dermed gjøre occurred_at-kontrollen virkningsløs.
insert into audit.events
  (operation, object_id, actor_id, new_revision_or_snapshot, occurred_at, created_at)
select 'role_granted', 'eeeeeeee-0000-0000-0000-0000000000aa', a.id,
       jsonb_build_object('id', 'eeeeeeee-0000-0000-0000-0000000000aa'::uuid),
       now() - interval '10 years', now() - interval '10 years'
from fixture a
where a.name = 'admin';

select ok(
  (select created_at > now() - interval '1 minute'
   from audit.events
   where object_id = 'eeeeeeee-0000-0000-0000-0000000000aa'),
  'created_at settes av databasen, uansett hva kalleren oppgir'
);

-- ---------------------------------------------------------------------------
-- Merk: at auditraden peker på objektet uten fremmednøkkel forutsetter at
-- primærnøkkelen den peker på er stabil. For workflow.user_roles er det ikke
-- gitt av inngående fremmednøkler — tabellen har ingen — men av at migrasjon 008
-- tok identiteten inn i workflow.freeze_role_grant(). Den kontrollen ligger i
-- 200_workflow_immutability_test.sql, sammen med resten av frysegarantiene.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Auditraden overlever objektet sitt
--
-- Dette er hele begrunnelsen for at object_id ikke har fremmednøkkel
-- (DATABASE_ARCHITECTURE.md §36). Testen demonstrerer egenskapen framfor å påstå
-- den: uten den ville slettingen enten blitt blokkert, eller tatt auditsporet
-- med seg.
-- ---------------------------------------------------------------------------
delete from workflow.user_roles
where id = (select id from fixture where name = 'grant');

select is(
  (select count(*)::integer from audit.events
   where object_id = (select id from fixture where name = 'grant')),
  2,
  'auditradene består etter at rolletildelingen er fysisk slettet'
);

select is(
  (select e.new_revision_or_snapshot ->> 'role_code'
   from audit.events e
   where e.object_id = (select id from fixture where name = 'grant')
     and e.operation = 'role_granted'),
  'reviewer',
  'snapshotet sier fortsatt hvilken rettighet som ble gitt, selv om raden er borte'
);

-- ---------------------------------------------------------------------------
-- En operasjon som ikke kan auditeres, kan ikke utføres
--
-- Auditskriverne er bevisst ikke SECURITY DEFINER. Konsekvensen skal være at
-- den som ikke kan skrive auditraden, heller ikke får skrevet operasjonen — ikke
-- at operasjonen går gjennom uauditert. Det er en egenskap for framtiden: første
-- gang admin-RPC-laget åpner en skrivevei for en annen rolle enn eieren, er det
-- denne egenskapen som avgjør om en uauditert rolletildeling er mulig.
--
-- Oppsettet er derfor kunstig med vilje. En klientrolle stoppes i dag av tre
-- lag — manglende usage på schemaet, manglende grant, og RLS med default deny —
-- og RLS slår inn før triggeren i det hele tatt kjører. Alle tre åpnes her,
-- inne i transaksjonen, slik at auditskrivingen blir det eneste som gjenstår.
-- Uten den åpningen ville testen bestått uansett hva auditskriveren gjorde:
-- mutasjonstesten viste at den først feilet på et aktøroppslag og deretter på
-- RLS, aldri på det den påstod å måle.
--
-- Feilmeldingen kontrolleres derfor også, ikke bare SQLSTATE: 42501 alene ville
-- ikke skilt «kunne ikke skrive auditraden» fra en hvilken som helst annen
-- rettighetsfeil på veien.
-- ---------------------------------------------------------------------------
grant usage on schema workflow to anon;
grant usage on type workflow.app_role to anon;
grant insert on workflow.user_roles to anon;
create policy user_roles_probe_insert on workflow.user_roles
  for insert to anon with check (true);

set local role anon;
select throws_like(
  $$
    insert into workflow.user_roles (user_id, role_code, granted_by_actor_id, grant_reason)
    values ('eeeeeeee-0000-0000-0000-000000000003', 'editor',
            'eeeeeeee-1111-0000-0000-000000000002',
            'Tildeling fra en rolle som ikke kan skrive audit.')
  $$,
  '%audit%',
  'en skriver som ikke kan skrive auditraden får heller ikke registrert rolletildelingen'
);
reset role;

select is(
  (select count(*)::integer from workflow.user_roles
   where user_id = 'eeeeeeee-0000-0000-0000-000000000003'),
  0,
  'det avviste forsøket etterlot ingen rolletildeling'
);

drop policy user_roles_probe_insert on workflow.user_roles;
revoke insert on workflow.user_roles from anon;
revoke usage on type workflow.app_role from anon;
revoke usage on schema workflow from anon;

select * from finish();

rollback;
