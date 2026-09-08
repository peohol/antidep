-- Migrasjon 008 — tilgang til auditloggen.
--
-- Kritisk negativ test fra MVP_IMPLEMENTATION_PLAN.md §42, §47 og §48 og
-- DATABASE_ARCHITECTURE.md §5, §35, §48, §49 og §67. §47 lister `audit` blant
-- schemaene den offentlige klinikerflaten aldri skal ha SELECT mot, og
-- auditloggen har derfor ingen lesevei for klientroller i det hele tatt: ingen
-- grant, ingen policy, ingen usage på schemaet, og ingen view i api som leser
-- fra den.
--
-- Migrasjon 007 flyttet grensen for de tretten tabellene api-viewene leser.
-- Auditloggen står utenfor den flyttingen, og det er hele poenget med testen:
-- det som gjelder for én tabell i `knowledge` skal ikke smitte over på `audit`.
--
-- SQLSTATE 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(20);

-- ---------------------------------------------------------------------------
-- Lag 1: grants
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select r.role_name, p.privilege
    from (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'),
                       ('references'), ('trigger')) as p(privilege)
    where has_table_privilege(r.role_name, 'audit.events', p.privilege)
  $$,
  'ingen klientrolle har noe tabellprivilegium på auditloggen'
);

select is_empty(
  $$
    select r.role_name, p.privilege
    from (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('usage'), ('create')) as p(privilege)
    where has_schema_privilege(r.role_name, 'audit', p.privilege)
  $$,
  'ingen klientrolle har usage eller create på audit-schemaet'
);

-- Typen er også et privilegium. Uten dette ville en klientrolle kunnet navngi
-- vokabularet selv om den ikke kan lese tabellen (DATABASE_ARCHITECTURE.md §5).
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    where has_type_privilege(r.role_name, 'audit.event_operation', 'usage')
  $$,
  'ingen klientrolle har usage på auditvokabularet'
);

-- Auditskriverne er triggerfunksjoner og skal ikke kunne kalles direkte. Kunne
-- de det, ville en kaller kunnet skrive en auditrad uten at operasjonen den
-- beskriver har funnet sted.
select is_empty(
  $$
    select r.role_name, f.function_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('audit.record_publication_event()'),
                       ('audit.record_user_role_event()')) as f(function_name)
    where has_function_privilege(r.role_name, f.function_name, 'execute')
  $$,
  'ingen klientrolle kan kalle auditskriverne direkte'
);

-- ---------------------------------------------------------------------------
-- Lag 2: RLS er default deny, og ingen policy myker den opp
-- ---------------------------------------------------------------------------
select ok(
  (select c.relrowsecurity from pg_class c where c.oid = 'audit.events'::regclass),
  'RLS er aktivert på auditloggen'
);

select is_empty(
  $$
    select pol.polname::text
    from pg_policy pol
    where pol.polrelid = 'audit.events'::regclass
  $$,
  'auditloggen har ingen policy; default deny står alene'
);

-- ---------------------------------------------------------------------------
-- Lag 3: ingen vei inn gjennom kontraktslaget
--
-- Grantene fra migrasjon 007 virker gjennom viewene i api, som ble navneoppslått
-- da de ble opprettet. Et view som leste fra audit ville derfor vært en lesevei
-- forbi alt over, uten at noen grant på audit.events var nødvendig.
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select v.relname::text
    from pg_depend d
    join pg_rewrite rw on rw.oid = d.objid
    join pg_class v on v.oid = rw.ev_class
    join pg_namespace vn on vn.oid = v.relnamespace
    join pg_class t on t.oid = d.refobjid
    join pg_namespace tn on tn.oid = t.relnamespace
    where d.classid = 'pg_rewrite'::regclass
      and d.refclassid = 'pg_class'::regclass
      and tn.nspname = 'audit'
      and vn.nspname = 'api'
  $$,
  'ingen view i api leser fra audit'
);

-- ---------------------------------------------------------------------------
-- Faktiske forsøk med Data API-rollene
--
-- Manglende usage på schemaet slår inn før tabellprivilegiet, så feilen er
-- «permission denied for schema audit». Det er den ytterste av de tre låsene, og
-- den testes her sammen med at de to andre likevel ville stoppet forsøket.
-- ---------------------------------------------------------------------------
set local role anon;
select throws_ok(
  'select 1 from audit.events', '42501', null,
  'anon nektes lesing av auditloggen'
);
select throws_ok(
  $$
    insert into audit.events (operation, object_id, actor_id, new_revision_or_snapshot)
    values ('role_granted', gen_random_uuid(), gen_random_uuid(), '{}'::jsonb)
  $$,
  '42501', null,
  'anon kan ikke skrive en auditrad'
);
reset role;

set local role authenticated;
select throws_ok(
  'select 1 from audit.events', '42501', null,
  'vanlig innlogget bruker nektes lesing av auditloggen'
);
select throws_ok(
  $$
    insert into audit.events (operation, object_id, actor_id, new_revision_or_snapshot)
    values ('role_granted', gen_random_uuid(), gen_random_uuid(), '{}'::jsonb)
  $$,
  '42501', null,
  'vanlig innlogget bruker kan ikke skrive en auditrad'
);
select throws_ok(
  $$update audit.events set reason = 'Omskrevet.'$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke skrive om en auditrad'
);
select throws_ok(
  $$delete from audit.events$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke slette en auditrad for å skjule den'
);
select throws_ok(
  $$truncate audit.events$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke tømme auditloggen'
);
reset role;

-- service_role omgår RLS og er derfor det tilfellet der grantene er den eneste
-- gjenværende sperren. Den er ikke applikasjonens universalnøkkel
-- (DATABASE_ARCHITECTURE.md §49), og skal ikke ha noe her heller.
set local role service_role;
select throws_ok(
  'select 1 from audit.events', '42501', null,
  'service_role nektes lesing av auditloggen, selv om den omgår RLS'
);
select throws_ok(
  $$
    insert into audit.events (operation, object_id, actor_id, new_revision_or_snapshot)
    values ('role_granted', gen_random_uuid(), gen_random_uuid(), '{}'::jsonb)
  $$,
  '42501', null,
  'service_role kan ikke skrive en auditrad'
);
reset role;

-- ---------------------------------------------------------------------------
-- Den andre veien inn: skrivesiden på det som auditeres
--
-- En kaller som kunne skrevet i workflow.user_roles eller
-- knowledge.publication_events, ville utløst auditskriveren med sine egne
-- rettigheter. Auditloggen hviler derfor også på at de to skriveveiene er
-- stengt, og det kontrolleres her framfor å forutsettes.
-- ---------------------------------------------------------------------------
set local role authenticated;
select throws_ok(
  $$
    insert into workflow.user_roles (user_id, role_code, granted_by_actor_id, grant_reason)
    values (gen_random_uuid(), 'reviewer', gen_random_uuid(), 'Selvtildelt rolle.')
  $$,
  '42501', null,
  'vanlig innlogget bruker kan ikke tildele seg selv en rolle, og dermed heller ikke framprovosere en auditrad'
);
select throws_ok(
  $$update workflow.user_roles set valid_to = now()$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke avslutte en rolletildeling'
);
reset role;

-- ---------------------------------------------------------------------------
-- Eieren kommer til, og det er det som gjør de negative testene meningsfulle:
-- et tomt resultat under RLS skal ikke kunne forveksles med en stengt tabell.
-- ---------------------------------------------------------------------------
select lives_ok(
  'select count(*) from audit.events',
  'eieren kan lese auditloggen'
);

-- Vaktposten sto som «tom» fram til migrasjon 005f. Registreringen av en
-- agentidentitet er nettopp en forvaltningskritisk operasjon — en maskin fikk en
-- identitet i Antidep — og skal derfor legge igjen en rad. Migrasjon 005i
-- registrerte den andre, claim-verifikatoren, og loggen inneholder derfor to
-- like rader. Påstanden er strammet framfor svekket: nøyaktig de to, og fortsatt
-- ingen publisering, ingen rolletildeling og ingen utstedt legitimasjon
-- (MVP_IMPLEMENTATION_PLAN.md §74.4).
--
-- Rekkefølgen sorteres på identitetsnøkkelen framfor på occurred_at: begge
-- radene er skrevet av migrasjoner som kjørte i hver sin transaksjon, men
-- tidsstemplene kan i prinsippet være like nok til at rekkefølgen ikke er
-- entydig, og en flakende assertion om auditloggen er verre enn en presis.
select results_eq(
  $$
    select e.operation::text, e.object_schema, e.object_table, a.actor_key,
           ai.identity_key
    from audit.events e
    join provenance.actors a on a.id = e.actor_id
    join provenance.agent_identities ai on ai.id = e.object_id
    order by ai.identity_key
  $$,
  $$values ('agent_identity_registered', 'provenance', 'agent_identities',
            'human:peder-holman', 'agent-identity:citation-support-verification-01'),
           ('agent_identity_registered', 'provenance', 'agent_identities',
            'human:peder-holman', 'agent-identity:extraction-verification-01')$$,
  'auditloggen inneholder nøyaktig registreringen av de to agentidentitetene, begge attribuert til et menneske'
);

select * from finish();

rollback;
