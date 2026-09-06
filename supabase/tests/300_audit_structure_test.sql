-- Migrasjon 008 — struktur i auditloggen.
--
-- Verifiserer at audit.events finnes med feltene DATABASE_ARCHITECTURE.md §35
-- krever, at de tre valgene migrasjonen tok er faktisk håndhevet — genererte
-- objektpekere, fravær av fremmednøkkel på object_id, og append-only — og at
-- produsenttriggerne er koblet på de skriveveiene de skal dekke.
--
-- Tilgang testes i 310, atferden til produsentene og constraintene i 320. Den
-- schemauttømmende vaktposten over audit ligger i 040_catalog_structure_test.sql
-- og fanger tabellen automatisk; konvensjonene i 030_conventions_test.sql
-- likeså.
begin;

create extension if not exists pgtap with schema extensions;

select plan(43);

-- ---------------------------------------------------------------------------
-- Tabellen og §35 sitt minimumsfeltsett
-- ---------------------------------------------------------------------------
select has_table('audit', 'events', 'audit.events finnes');
select col_is_pk('audit', 'events', 'id', 'audit.events har id som primærnøkkel');

-- Uttømmende feltliste framfor enkeltoppslag: en kolonne som legges til uten at
-- noen tar stilling til hva den betyr for loggen, skal synes her.
select columns_are(
  'audit', 'events',
  array[
    'id', 'operation', 'object_schema', 'object_table', 'object_id', 'actor_id',
    'old_revision_or_snapshot', 'new_revision_or_snapshot', 'request_or_run_id',
    'reason', 'occurred_at', 'created_at'
  ],
  'audit.events har nøyaktig feltene fra DATABASE_ARCHITECTURE.md §35'
);

select col_type_is(
  'audit', 'events', 'operation', 'audit.event_operation',
  'operasjonen er et kontrollert vokabular, ikke fritekst'
);
select col_type_is(
  'audit', 'events', 'object_id', 'uuid',
  'objektpekeren er en uuid, som alle identiteter i Antidep (DATABASE_ARCHITECTURE.md §8)'
);
select col_type_is(
  'audit', 'events', 'old_revision_or_snapshot', 'jsonb',
  'tilstanden før operasjonen lagres som jsonb'
);
select col_type_is(
  'audit', 'events', 'new_revision_or_snapshot', 'jsonb',
  'tilstanden etter operasjonen lagres som jsonb'
);

select col_not_null(
  'audit', 'events', 'operation',
  'raden sier alltid hvilken operasjon den registrerer'
);
select col_not_null(
  'audit', 'events', 'object_schema',
  'raden sier alltid hvilket schema objektet ligger i'
);
select col_not_null(
  'audit', 'events', 'object_table',
  'raden sier alltid hvilken tabell objektet ligger i'
);
select col_not_null(
  'audit', 'events', 'object_id',
  'raden peker alltid på et identifiserbart objekt'
);
select col_not_null(
  'audit', 'events', 'actor_id',
  'raden er alltid attribuert til en aktør (ANTIDEP_CONSTITUTION.md §14)'
);
select col_not_null(
  'audit', 'events', 'occurred_at',
  'operasjonen er alltid datert (DATABASE_ARCHITECTURE.md §7.3)'
);
select col_not_null(
  'audit', 'events', 'created_at',
  'registreringstidspunktet er alltid satt'
);

-- De fire feltene §35 markerer som valgfrie skal faktisk være valgfrie. Var
-- snapshotene NOT NULL, kunne verken en opprettelse eller en sletting uttrykkes.
select col_is_null(
  'audit', 'events', 'old_revision_or_snapshot',
  'old-snapshotet kan være tomt, slik at en opprettelse kan uttrykkes'
);
select col_is_null(
  'audit', 'events', 'new_revision_or_snapshot',
  'new-snapshotet kan være tomt, slik at en sletting kan uttrykkes'
);
select col_is_null(
  'audit', 'events', 'request_or_run_id',
  'korrelasjonsnøkkelen kan være tom; ingen produsent setter den ennå'
);
select col_is_null(
  'audit', 'events', 'reason',
  'begrunnelsen kan være tom, fordi ikke alle operasjoner krever en'
);

-- ---------------------------------------------------------------------------
-- Objektpekeren: avledet der den kan være det, uten fremmednøkkel der den ikke
-- kan være det
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select a.attname::text
    from pg_attribute a
    where a.attrelid = 'audit.events'::regclass
      and a.attname in ('object_schema', 'object_table')
      and a.attgenerated <> 's'
  $$,
  'object_schema og object_table er genererte kolonner og kan ikke oppgis ved siden av operasjonen'
);

-- Dette er migrasjonens ene bevisste avvik fra DATABASE_ARCHITECTURE.md §37, og
-- det er begrunnet i §36: en auditrad skal overleve at objektet den beskriver
-- blir fysisk slettet. Skulle noen «rette opp» ved å legge på en fremmednøkkel,
-- er det nettopp den egenskapen som forsvinner, og 320 demonstrerer den.
select is_empty(
  $$
    select con.conname::text
    from pg_constraint con
    where con.conrelid = 'audit.events'::regclass
      and con.contype = 'f'
      and (select a.attnum
           from pg_attribute a
           where a.attrelid = con.conrelid and a.attname = 'object_id') = any (con.conkey)
  $$,
  'object_id har bevisst ingen fremmednøkkel, slik at auditraden overlever objektet (DATABASE_ARCHITECTURE.md §36)'
);

-- Aktøren er derimot en ekte fremmednøkkel: der er ikke overlevelse spørsmålet,
-- men at aktøren ikke skal kunne slettes bort under sin egen historikk.
select fk_ok(
  'audit', 'events', 'actor_id',
  'provenance', 'actors', 'id',
  'auditraden peker på en normalisert aktør'
);
select is(
  (select con.confdeltype
   from pg_constraint con
   join pg_attribute a
     on a.attrelid = con.conrelid and a.attname = 'actor_id'
   where con.conrelid = 'audit.events'::regclass
     and con.contype = 'f'
     and a.attnum = any (con.conkey)),
  'r'::"char",
  'aktørreferansen er RESTRICT, ikke CASCADE (DATABASE_ARCHITECTURE.md §37)'
);

-- ---------------------------------------------------------------------------
-- Vokabularet
-- ---------------------------------------------------------------------------
select enum_has_labels(
  'audit', 'event_operation',
  array[
    'claim_published', 'claim_publication_replaced', 'claim_publication_withdrawn',
    'claim_publication_rolled_back', 'role_granted', 'role_ended', 'source_created',
    'evidence_item_created', 'agent_identity_registered',
    'agent_identity_credential_issued', 'agent_identity_revoked',
    'evidence_verification_registered'
  ],
  'audit.event_operation dekker publiseringshandlingene, rolleforvaltningen, kildeopprettelse (migrasjon 008a), evidensregistrering (008b), agentidentitetenes livssyklus (008c) og ekstraksjonsverifikasjon (008d)'
);

-- De fire publiseringsverdiene skal svare én-til-én til
-- knowledge.publication_action. Blir de to vokabularene ulike lange, finnes det
-- en publiseringshandling som ikke kan auditeres, og
-- audit.record_publication_event() vil avvise den ved kjøring framfor ved
-- migrering. Da er det bedre at testpakken sier fra først.
select is(
  (select count(*)::integer
   from unnest(enum_range(null::knowledge.publication_action))),
  (select count(*)::integer
   from unnest(enum_range(null::audit.event_operation)) as e
   where e::text like 'claim_publication%' or e::text = 'claim_published'),
  'hver publiseringshandling har nøyaktig én auditoperasjon'
);

-- ---------------------------------------------------------------------------
-- Oppslagsveiene loggen finnes for
-- ---------------------------------------------------------------------------
select has_index(
  'audit', 'events', 'events_actor_id_occurred_at_idx',
  'oppslaget «hva gjorde denne aktøren?» er indeksert'
);
select has_index(
  'audit', 'events', 'events_object_occurred_at_idx',
  'oppslaget «hva har skjedd med dette objektet?» er indeksert'
);
select has_index(
  'audit', 'events', 'events_occurred_at_idx',
  'oppslaget «hva skjedde nylig?» er indeksert'
);

-- ---------------------------------------------------------------------------
-- Append-only og databaseeid tid
-- ---------------------------------------------------------------------------
select has_trigger(
  'audit', 'events', 'events_set_created_at',
  'databasen eier registreringstidspunktet på auditraden'
);
select has_trigger(
  'audit', 'events', 'events_reject_mutation',
  'auditloggen er append-only'
);

-- En trigger satt til replica fyrer ikke i vanlig drift, og et vern som ikke
-- fyrer, er ikke et vern. Samme vaktpost som i 200_workflow_immutability_test.sql,
-- her rettet mot audit alene.
select is_empty(
  $$
    select t.tgname::text
    from pg_trigger t
    where t.tgrelid = 'audit.events'::regclass
      and not t.tgisinternal
      and t.tgenabled <> 'O'
  $$,
  'ingen trigger på auditloggen er avslått eller satt til replica'
);

-- ---------------------------------------------------------------------------
-- Produsentene er koblet på de skriveveiene som finnes
-- ---------------------------------------------------------------------------
select has_trigger(
  'knowledge', 'publication_events', 'publication_events_record_audit_event',
  'publiseringshendelser auditeres'
);
select has_trigger(
  'workflow', 'user_roles', 'user_roles_record_grant_audit_event',
  'rolletildelinger auditeres'
);
select has_trigger(
  'workflow', 'user_roles', 'user_roles_record_end_audit_event',
  'avslutning av en rolletildeling auditeres'
);
select has_trigger(
  'knowledge', 'sources', 'sources_record_creation_audit_event',
  'kildeopprettelse auditeres (migrasjon 007c)'
);

select has_function(
  'audit', 'record_publication_event', 'audit.record_publication_event() finnes'
);
select has_function(
  'audit', 'record_user_role_event', 'audit.record_user_role_event() finnes'
);
select has_function(
  'audit', 'record_source_event', 'audit.record_source_event() finnes'
);

-- En auditskriver som er mer privilegert enn operasjonen den registrerer, er en
-- vei til å skrive falske auditrader. Fraværet av SECURITY DEFINER er derfor en
-- sikkerhetsegenskap og ikke en forglemmelse, og skal testes som en.
select is_empty(
  $$
    select p.proname::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'audit'
      and p.prosecdef
  $$,
  'ingen funksjon i audit er SECURITY DEFINER'
);
select is_empty(
  $$
    select p.proname::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'audit'
      and not exists (
        select 1
        from unnest(coalesce(p.proconfig, array[]::text[])) as cfg
        where cfg in ('search_path=""', 'search_path=')
      )
  $$,
  'alle funksjoner i audit har tomt search_path (DATABASE_ARCHITECTURE.md §50)'
);

-- ---------------------------------------------------------------------------
-- Dokumentasjon i databasen
-- ---------------------------------------------------------------------------
select isnt(
  obj_description('audit.events'::regclass, 'pg_class'),
  null,
  'auditloggen forklarer hva den er, og hva den ikke er'
);
select is_empty(
  $$
    select f.function_name
    from (values ('audit.record_publication_event()'),
                 ('audit.record_user_role_event()'),
                 ('audit.record_source_event()'))
           as f(function_name)
    where coalesce(obj_description(f.function_name::regprocedure, 'pg_proc'), '') = ''
  $$,
  'alle tre auditskriverne er dokumentert'
);
-- Primærnøkkelen er unntatt, som overalt ellers i schemaene: den er en
-- databasegenerert uuid uten egen betydning.
select is_empty(
  $$
    select a.attname::text
    from pg_attribute a
    where a.attrelid = 'audit.events'::regclass
      and a.attnum > 0
      and not a.attisdropped
      and a.attname <> 'id'
      and coalesce(col_description(a.attrelid, a.attnum), '') = ''
  $$,
  'hver betydningsbærende kolonne på auditloggen er dokumentert'
);
select isnt(
  obj_description('audit.event_operation'::regtype, 'pg_type'),
  null,
  'vokabularet forklarer hvorfor verdiene er domenehandlinger og ikke DML-verb'
);

select * from finish();

rollback;
