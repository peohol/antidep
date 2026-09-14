-- Migrasjon 005 — tilgang til review- og provenienslaget.
--
-- Kritisk negativ test fra MVP_IMPLEMENTATION_PLAN.md §42 og §47 og
-- DATABASE_ARCHITECTURE.md §5, §46, §48, §49 og §67: workflow og provenance er
-- default deny. Verken anonyme eller vanlige innloggede brukere skal kunne lese
-- eller skrive der, og RLS skal være den andre sperren, ikke bare fraværet av
-- grants.
--
-- Den viktigste testen her er privilege escalation: medlemskapstabellen er
-- autorisasjonskilden (§46), og en bruker som kan skrive i den kan gi seg selv
-- hvilken som helst rolle. Testen kontrollerer derfor både at granten mangler,
-- og at RLS ville stoppet forsøket selv om granten ble gitt ved et uhell.
--
-- SQLSTATE 42501 = insufficient_privilege.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(34);

-- ---------------------------------------------------------------------------
-- Testdata som bare finnes inne i denne transaksjonen, slik at et tomt resultat
-- under RLS ikke kan forveksles med en tom tabell.
-- ---------------------------------------------------------------------------
-- Fast uuid framfor gen_random_uuid(): den positive RLS-kontrollen nederst må
-- kunne oppgi nøyaktig denne brukeren som subjekt i tokenet.
insert into auth.users (id, email) values
  ('21000000-0000-4000-8000-000000000001', 'tilgang@test.invalid');

insert into provenance.actors (actor_type, actor_key, display_name, description)
values ('system', 'system:tilgang', 'Testsystemaktør',
        'Systemaktør for tilgangstestene.');

insert into workflow.user_roles
  (user_id, role_code, granted_by_actor_id, grant_reason)
select u.id, 'editor', a.id, 'Testtildeling for tilgangstestene.'
from auth.users u, provenance.actors a
where u.email = 'tilgang@test.invalid' and a.actor_key = 'system:tilgang';

-- ---------------------------------------------------------------------------
-- Lag 1: grants
-- ---------------------------------------------------------------------------
-- Migrasjon 007 åpnet nøyaktig én tabell her, og bare for lesing:
-- workflow.review_decisions, fordi en tilbaketrukket ekstraksjon kan registreres
-- etter at påstanden ble publisert, og lesemodellen ellers ville vist funnet som
-- ordinær evidens. Policyen under slipper bare gjennom
-- review_type = 'extraction_withdrawal'.
--
-- Migrasjon 007b åpnet i tillegg kallerens *egne* rader i workflow.user_roles og
-- provenance.actors — men på kolonnenivå, og has_table_privilege() ser ikke
-- kolonnegrant. Denne assertionen svarer derfor fortsatt «ingen tabellvid
-- tilgang», og det er sant; kolonnene føres uttømmende i assertionen etter.
-- Skillet er ikke pedantisk: en test som bare spør om tabellprivilegiet ville
-- vært stille sann uansett hvor mange kolonner en senere migrasjon åpnet.
select is_empty(
  $$
    select t.table_name, r.role_name, p.privilege
    from (values ('provenance.actors'), ('workflow.user_roles'),
                 ('workflow.evidence_verifications'), ('workflow.claim_verifications'),
                 ('workflow.review_decisions')) as t(table_name)
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'),
                       ('references'), ('trigger')) as p(privilege)
    where has_table_privilege(r.role_name, t.table_name, p.privilege)
      and not (
        p.privilege = 'select'
        and r.role_name in ('anon', 'authenticated')
        and t.table_name = 'workflow.review_decisions'
      )
  $$,
  'bare workflow.review_decisions er åpnet tabellvidt, bare for lesing, og bare for de to Data API-rollene'
);

-- Kolonnegrantene, uttømmende over de to schemaene. pg_attribute.attacl bærer
-- bare de *eksplisitte* kolonnegrantene, i motsetning til
-- information_schema.role_column_grants, som også utleder én rad per kolonne av
-- et tabellvidt grant og dermed ville drukket disse i review_decisions.
--
-- Listen er kontrakten migrasjon 007b åpnet: nøyaktig de kolonnene api.my_actor
-- og api.my_roles leser eller filtrerer på. Begrunnelsene for tildeling og
-- avslutning, aktørpekerne, aktørens beskrivelse og tilbaketrekkingsnotat står
-- utenfor, og en migrasjon som legger til en kolonne her må endre denne raden.
select set_eq(
  $$
    select n.nspname || '.' || c.relname || '.' || a.attname
        || ':' || case when acl.grantee = 0 then 'PUBLIC'
                       else acl.grantee::regrole::text end
        || ':' || acl.privilege_type
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a
      on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
    cross join lateral aclexplode(a.attacl) acl
    where n.nspname in ('workflow', 'provenance')
  $$,
  $$
    values ('provenance.actors.id:authenticated:SELECT'),
           ('provenance.actors.actor_key:authenticated:SELECT'),
           ('provenance.actors.display_name:authenticated:SELECT'),
           ('provenance.actors.auth_user_id:authenticated:SELECT'),
           ('provenance.actors.retired_at:authenticated:SELECT'),
           ('workflow.user_roles.user_id:authenticated:SELECT'),
           ('workflow.user_roles.role_code:authenticated:SELECT'),
           ('workflow.user_roles.scope_id:authenticated:SELECT'),
           ('workflow.user_roles.scope_type:authenticated:SELECT'),
           ('workflow.user_roles.valid_from:authenticated:SELECT'),
           ('workflow.user_roles.valid_to:authenticated:SELECT')
  $$,
  'kolonnegrantene i workflow og provenance er nøyaktig de elleve api.my_actor og api.my_roles trenger, og bare til authenticated'
);
select is_empty(
  $$
    select s.schema_name, r.role_name, p.privilege
    from (values ('workflow'), ('provenance')) as s(schema_name)
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('usage'), ('create')) as p(privilege)
    where has_schema_privilege(r.role_name, s.schema_name, p.privilege)
  $$,
  'ingen klientrolle har usage eller create på workflow eller provenance'
);
-- Uttømmende over schemaene framfor en håndholdt liste: en ny funksjon i
-- workflow eller provenance skal ikke kunne bli kjørbar for en klientrolle ved
-- at noen glemmer å føre den opp her.
--
-- Det ene unntaket er workflow.caller_is_active_editor(), som migrasjon 007d
-- innførte som radgrense for den redaksjonelle lesemodellen. Unntaket er
-- nødvendig og ikke en lettelse: EXECUTE kontrolleres i kjøretid også når
-- funksjonen bare står i et policyuttrykk, så uten granten ville hvert oppslag
-- i api.editor_* feilet med «permission denied for function» — prøvd mot denne
-- stacken, ikke antatt. Unntaket er dessuten smalere enn det ser ut: granten
-- gjelder bare authenticated, og en klientrolle kan uansett ikke *navngi*
-- schemaet workflow. Begge halvdelene er festet under, framfor å stå her som en
-- påstand.
select is_empty(
  $$
    select p.oid::regprocedure::text, r.role_name
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    where n.nspname in ('workflow', 'provenance')
      and has_function_privilege(r.role_name, p.oid, 'execute')
      and not (
        r.role_name = 'authenticated'
        and p.oid::regprocedure::text = 'workflow.caller_is_active_editor()'
      )
  $$,
  'ingen klientrolle kan kjøre noen funksjon i workflow eller provenance, bortsett fra radgrensen authenticated trenger'
);
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name, 'workflow.caller_is_active_editor()'::regprocedure, 'execute'
    )
  $$,
  'radgrensen er kjørbar bare for authenticated, ikke for anon, service_role eller PUBLIC'
);

-- ---------------------------------------------------------------------------
-- Lag 2: RLS er aktivert, uten policies i dette steget
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select n.nspname || '.' || c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('workflow', 'provenance')
      and c.relkind = 'r'
      and not c.relrowsecurity
  $$,
  'RLS er aktivert på alle tabellene i workflow og provenance'
);
-- Uttømmende inventar. Skriveveien er fortsatt en SECURITY DEFINER-funksjon som
-- verken trenger grant eller policy, så alle policyene her er rene lesepolicyer.
-- polcmd 'r' betyr SELECT, og at alle tre står med 'r' er halve påstanden.
--
-- De to fra migrasjon 007b er begge avgrenset til kallerens egne rader. At de
-- *er* så avgrenset, prøves i 360_caller_authorization_test.sql; her føres bare
-- at det ikke har kommet flere policyer enn de tre.
select set_eq(
  $$
    select n.nspname || '.' || c.relname || ':' || p.polname || ':' || p.polcmd::text
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('workflow', 'provenance')
  $$,
  $$
    values ('workflow.review_decisions:review_decisions_extraction_withdrawal_read:r'),
           ('workflow.user_roles:user_roles_own_grants_read:r'),
           ('provenance.actors:actors_own_actor_read:r')
  $$,
  'workflow og provenance har nøyaktig tre lesepolicyer, og ingen av dem åpner for skriving'
);

-- Ingen av de to nye slipper inn en uinnlogget kaller. Policyen som *også*
-- gjaldt anon ville gitt hver anonym forespørsel et oppslag mot
-- autorisasjonskilden, og ville dessuten gjort et tomt svar tvetydig.
select set_eq(
  $$
    select c.relname || ':' || coalesce(r.rolname, '(alle roller)')
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    left join lateral unnest(p.polroles) as pr(oid) on true
    left join pg_roles r on r.oid = pr.oid
    where n.nspname in ('workflow', 'provenance')
      and p.polname in ('user_roles_own_grants_read', 'actors_own_actor_read')
  $$,
  $$
    values ('user_roles:authenticated'),
           ('actors:authenticated')
  $$,
  'policyene fra migrasjon 007b gjelder bare authenticated, ikke anon og ikke alle roller'
);

-- Policyen er smal med hensikt: en publiseringsgodkjenning skal ikke være
-- lesbar for en klientrolle, bare tilbaketrekkingen av en ekstraksjon.
select is_empty(
  $$
    select p.polname
    from pg_policy p
    where p.polrelid = 'workflow.review_decisions'::regclass
      and pg_get_expr(p.polqual, p.polrelid) not like '%extraction_withdrawal%'
  $$,
  'lesepolicyen på reviewbeslutningene er avgrenset til extraction_withdrawal'
);

-- ---------------------------------------------------------------------------
-- Faktiske forsøk med Data API-rollene
-- ---------------------------------------------------------------------------
set local role anon;
select throws_ok(
  'select 1 from provenance.actors', '42501', null,
  'anon nektes lesing av aktørregisteret'
);
select throws_ok(
  'select 1 from workflow.user_roles', '42501', null,
  'anon nektes lesing av medlemskapstabellen'
);
select throws_ok(
  'select 1 from workflow.evidence_verifications', '42501', null,
  'anon nektes lesing av ekstraksjonsverifikasjonene'
);
select throws_ok(
  'select 1 from workflow.claim_verifications', '42501', null,
  'anon nektes lesing av claim-verifikasjonene'
);
select throws_ok(
  'select 1 from workflow.review_decisions', '42501', null,
  'anon nektes lesing av reviewbeslutningene'
);
reset role;

set local role authenticated;
select throws_ok(
  'select 1 from workflow.user_roles', '42501', null,
  'vanlig innlogget bruker nektes lesing av medlemskapstabellen'
);
select throws_ok(
  'select 1 from provenance.actors', '42501', null,
  'vanlig innlogget bruker nektes lesing av aktørregisteret'
);
select throws_ok(
  'select 1 from workflow.review_decisions', '42501', null,
  'vanlig innlogget bruker nektes lesing av reviewbeslutningene'
);
-- Privilege escalation: den farligste skriveveien i hele schemaet.
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, granted_by_actor_id, grant_reason)
    values (gen_random_uuid(), 'admin', gen_random_uuid(), 'Selvtildelt rolle.')
  $$,
  '42501', null,
  'vanlig innlogget bruker kan ikke gi seg selv en rolle'
);
select throws_ok(
  $$update workflow.user_roles set valid_to = null, ended_by_actor_id = null, end_reason = null$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke gjenåpne en tilbakekalt rolle'
);
select throws_ok(
  $$delete from workflow.user_roles$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke slette en rolletildeling for å skjule den'
);
select throws_ok(
  $$
    insert into provenance.actors (actor_type, actor_key, display_name, description)
    values ('human', 'human:selvopprettet', 'Selvopprettet', 'Aktør opprettet av bruker.')
  $$,
  '42501', null,
  'vanlig innlogget bruker kan ikke opprette en aktør å attribuere handlinger til'
);
select throws_ok(
  $$
    insert into workflow.review_decisions (
      claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
      rationale, reviewer_actor_id, reviewer_actor_type, decided_at
    )
    values (gen_random_uuid(), gen_random_uuid(), 'publication_approval', 'approved',
            'Selvgodkjenning.', gen_random_uuid(), 'human', now())
  $$,
  '42501', null,
  'vanlig innlogget bruker kan ikke godkjenne klinisk innhold'
);
select throws_ok(
  $$
    insert into workflow.claim_verifications (
      claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id,
      outcome, source_access, source_support, population_match, comparator_match,
      timeframe_match, direction_and_magnitude, qualifiers_complete,
      contradictory_evidence_represented, rationale, verified_at
    )
    values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
            'verified', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
            'Selvverifikasjon.', now())
  $$,
  '42501', null,
  'vanlig innlogget bruker kan ikke registrere en verifikasjon'
);
select throws_ok(
  $$select workflow.enforce_reviewer_qualification()$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke kjøre den privilegerte kvalifikasjonskontrollen'
);
-- Publiseringsfunksjonene i migrasjon 006 leser nettopp medlemskapstabellen og
-- reviewbeslutningene over. De er SECURITY DEFINER, så den eneste sperren mot at
-- en vanlig bruker kjører dem er EXECUTE-privilegiet — og det er ikke gitt til
-- noen. Testen hører hjemme her fordi det er workflow-tilgangen som ville vært
-- omgått hvis den falt bort.
select throws_ok(
  $$select knowledge.publish_claim_revision(gen_random_uuid(), gen_random_uuid(), 'Forsøk.')$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke kjøre publiseringsfunksjonen og dermed lese rollemodellen forbi RLS'
);
reset role;

-- service_role omgår RLS, men ikke grants, og er ikke applikasjonens
-- universalnøkkel (DATABASE_ARCHITECTURE.md §49).
set local role service_role;
select throws_ok(
  'select 1 from workflow.user_roles', '42501', null,
  'service_role nektes lesing av medlemskapstabellen fordi grants mangler'
);
select throws_ok(
  'select 1 from provenance.actors', '42501', null,
  'service_role nektes lesing av aktørregisteret fordi grants mangler'
);
reset role;

-- ---------------------------------------------------------------------------
-- RLS er en reell sperre, ikke bare fraværet av grants
--
-- Selvtest av lag 2: hvis en framtidig migrasjon ved et uhell gir privilegier
-- til en klientrolle, skal RLS fortsatt gi null rader og avvise skriving.
-- Grantene finnes bare inne i denne transaksjonen og rulles tilbake.
-- ---------------------------------------------------------------------------
grant usage on schema workflow, provenance to authenticated;
grant select, insert, update, delete on workflow.user_roles to authenticated;
grant select on provenance.actors to authenticated;

-- Kontroll av selve selvtesten: radene finnes faktisk, sett fra eieren.
select isnt_empty(
  'select 1 from workflow.user_roles',
  'rolletildelingen finnes, sett fra eieren'
);
select isnt_empty(
  'select 1 from provenance.actors',
  'aktørene finnes, sett fra eieren'
);

-- Uten et subjekt i tokenet er auth.uid() NULL, og begge policyene fra migrasjon
-- 007b sammenligner mot den. NULL = NULL er ukjent og ikke sant, så ingen rad
-- slipper gjennom — heller ikke aktørene som selv har auth_user_id NULL.
set local role authenticated;
select is(
  (select count(*) from workflow.user_roles),
  0::bigint,
  'RLS gir null rolletildelinger selv med SELECT-grant, når tokenet ikke har et subjekt'
);
select is(
  (select count(*) from provenance.actors),
  0::bigint,
  'RLS gir null aktører selv med SELECT-grant, når tokenet ikke har et subjekt'
);
reset role;

-- Og den positive retningen. Uten den ville en policy mutert til «using (false)»
-- overlevd hele filen: begge tallene over ville vært null uansett, og
-- selvtesten ville målt fraværet av en policy framfor policyens grense.
select set_config('request.jwt.claims',
                  '{"sub":"21000000-0000-4000-8000-000000000001"}', true);
set local role authenticated;
select is(
  (select count(*) from workflow.user_roles),
  1::bigint,
  'med et subjekt i tokenet slipper policyen gjennom nøyaktig kallerens egen tildeling'
);
-- Testaktøren her er en systemaktør uten brukerkonto, så kalleren har en rolle
-- uten å ha en aktørrad. Det er en reell tilstand og ikke en feil i fiksturen:
-- de to policyene svarer på hvert sitt spørsmål.
select is(
  (select count(*) from provenance.actors),
  0::bigint,
  'en kaller uten egen aktørrad ser ingen aktør, heller ikke systemaktøren'
);
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, granted_by_actor_id, grant_reason)
    values (gen_random_uuid(), 'admin', gen_random_uuid(), 'Selvtildelt rolle med grant.')
  $$,
  '42501', null,
  'RLS stopper selvtildeling av rolle selv om INSERT-granten er gitt ved et uhell'
);
reset role;
select set_config('request.jwt.claims', '', true);

select * from finish();

rollback;
