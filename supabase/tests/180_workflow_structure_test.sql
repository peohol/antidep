-- Migrasjon 005 — struktur i workflow og provenance.
--
-- Verifiserer at review- og proveniensfundamentet fra
-- MVP_IMPLEMENTATION_PLAN.md §22 finnes med de relasjonene og vokabularene
-- DATABASE_ARCHITECTURE.md §29-§34 og §47 krever, og at attribusjonen
-- ANTIDEP_CONSTITUTION.md §14 krever faktisk er påkrevd på kunnskapsobjektene.
-- Constraint-atferd testes i 190, immutabilitet i 200, tilgang i 210 og
-- seedomfanget i 220.
--
-- Filen holder i tillegg de schemauttømmende vaktpostene for workflow og
-- provenance, tilsvarende dem 080_knowledge_structure_test.sql holder for
-- knowledge. De må utvides, ikke omgås, av senere migrasjoner.
begin;

create extension if not exists pgtap with schema extensions;

select plan(62);

-- ---------------------------------------------------------------------------
-- Tabellene i migrasjon 005
-- ---------------------------------------------------------------------------
select has_table('provenance', 'actors', 'provenance.actors finnes');
select has_table('workflow', 'user_roles', 'workflow.user_roles finnes');
select has_table(
  'workflow', 'evidence_verifications', 'workflow.evidence_verifications finnes'
);
select has_table(
  'workflow', 'claim_verifications', 'workflow.claim_verifications finnes'
);
select has_table('workflow', 'review_decisions', 'workflow.review_decisions finnes');

-- Publiseringsgaten i migrasjon 006 leser beslutningene og verifikasjonene denne
-- migrasjonen lager. Vaktposten her sto opprinnelig som en hasnt_table på
-- knowledge.publication_events; nå som tabellen finnes, er den reelle
-- assertionen at gaten faktisk henter tilstanden sin fra workflow og ikke fra en
-- kopi et annet sted. Uten dette kunne gaten skrives om til å lese en
-- statuskolonne uten at noen test sa fra, og overleveringen fra migrasjon 005 om
-- tilbaketrukket ekstraksjon ville glidd ut.
select has_table(
  'knowledge', 'publication_events',
  'knowledge.publication_events finnes; publiseringsgaten leser beslutningene fra denne migrasjonen'
);
-- Gaten er to funksjoner fra migrasjon 006e: forutsetningene før den
-- menneskelige godkjenningen (G1-G10) er flyttet ut i
-- knowledge.assert_claim_revision_ready_for_approval(uuid), slik at skriveveien
-- for godkjenningen kan kreve nøyaktig de samme vilkårene uten å kopiere dem.
-- Kravet er derfor på de to til sammen: gaten skal fortsatt lese hver av dem.
select is_empty(
  $$
    select t.needle
    from (values ('workflow.evidence_verifications'),
                 ('workflow.claim_verifications'),
                 ('workflow.review_decisions'),
                 ('extraction_withdrawal'),
                 ('publication_approval'),
                 ('approved_evidence_set_digest')) as t(needle)
    where position(t.needle in
           (select string_agg(p.prosrc, ' ')
            from pg_proc p
            where p.oid in ('knowledge.assert_claim_revision_publishable(uuid)'::regprocedure,
                            'knowledge.assert_claim_revision_ready_for_approval(uuid)'::regprocedure))) = 0
  $$,
  'publiseringsgaten leser verifikasjonene, godkjenningen og tilbaketrekkingsbeslutningen fra workflow'
);
-- ... og forutsetningene skal faktisk kalles av gaten. Uten denne assertionen
-- kunne G1-G10 blitt liggende igjen som en frittstående funksjon ingen leser,
-- og gaten sluppet gjennom alt de stenger.
select ok(
  position('knowledge.assert_claim_revision_ready_for_approval' in
           (select p.prosrc from pg_proc p
            where p.oid = 'knowledge.assert_claim_revision_publishable(uuid)'::regprocedure)) > 0,
  'publiseringsgaten kaller forutsetningene før godkjenningen, framfor å ha en egen kopi av dem'
);
select is_empty(
  $$
    select t.needle
    from (values ('workflow.user_roles'), ('publisher')) as t(needle)
    where position(t.needle in
           (select p.prosrc
            from pg_proc p
            where p.oid = 'knowledge.assert_publisher_authorized(uuid, uuid)'::regprocedure)) = 0
  $$,
  'publiseringsretten leses fra medlemskapstabellen, ikke fra en JWT-claim (DATABASE_ARCHITECTURE.md §46)'
);

-- ---------------------------------------------------------------------------
-- Kontrollerte vokabularer
-- ---------------------------------------------------------------------------
select enum_has_labels(
  'provenance', 'actor_type',
  array['human', 'agent', 'deterministic_process', 'external_import', 'system'],
  'provenance.actor_type dekker aktørtypene i DATABASE_ARCHITECTURE.md §32'
);
-- Rekkefølgen er pipelinerekkefølgen og ikke tilfeldig: migrasjon 005d la
-- extraction_verification inn rett etter leddet den kontrollerer, framfor
-- bakerst. enum_has_labels() sammenligner ordnet, så vakten fanger også at en
-- senere verdi settes inn på feil sted.
select enum_has_labels(
  'provenance', 'agent_role',
  array['source_discovery', 'source_quality_assessment', 'evidence_extraction',
        'extraction_verification', 'claim_synthesis', 'adversarial_review',
        'citation_support_verification', 'editorial_compression'],
  'provenance.agent_role dekker de sju agentrollene i ANTIDEP_CONSTITUTION.md §10 og ekstraksjonsverifikatoren i EVIDENCE_PIPELINE.md §61'
);
select enum_has_labels(
  'workflow', 'role_scope_type', array['clinical_concept'],
  'workflow.role_scope_type dekker scoped review på innholdsområde'
);
select enum_has_labels(
  'workflow', 'verification_outcome',
  array['verified', 'needs_correction', 'rejected', 'uncertain'],
  'workflow.verification_outcome dekker utfallene i DATABASE_ARCHITECTURE.md §29'
);
select enum_has_labels(
  'workflow', 'verification_source_access',
  array['original_source', 'verifiable_representation', 'derived_summary'],
  'workflow.verification_source_access skiller originalkilde, etterprøvbar representasjon og avledet sammendrag'
);
select enum_has_labels(
  'workflow', 'verification_check_result',
  array['ok', 'deviation', 'not_assessable'],
  'workflow.verification_check_result skiller bestått, avvik og ikke vurderbart'
);
select enum_has_labels(
  'workflow', 'review_object_type', array['claim_revision', 'evidence_item'],
  'workflow.review_object_type dekker objektene som kan reviewes nå'
);
select enum_has_labels(
  'workflow', 'review_type', array['publication_approval', 'extraction_withdrawal'],
  'workflow.review_type dekker publiseringsgodkjenning og tilbaketrekking av ekstraksjon'
);
select enum_has_labels(
  'workflow', 'review_outcome',
  array['approved', 'rejected', 'changes_requested',
        'extraction_withdrawn', 'extraction_upheld'],
  'workflow.review_outcome bevarer både godkjenning, avslag og tilbaketrekking'
);

-- workflow.app_role er fra migrasjon 001 og skal gjenbrukes, ikke gjenoppfinnes.
select enum_has_labels(
  'workflow', 'app_role', array['editor', 'reviewer', 'publisher', 'admin'],
  'workflow.app_role fra migrasjon 001 er uendret'
);

-- Uttømmende over de to schemaene: PUBLIC skal ikke ha usage på noen type.
select is_empty(
  $$
    select n.nspname || '.' || t.typname
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname in ('workflow', 'provenance')
      and t.typtype = 'e'
      and has_type_privilege('public', t.oid, 'usage')
  $$,
  'PUBLIC har ikke usage på noen type i workflow eller provenance'
);

-- ---------------------------------------------------------------------------
-- provenance.actors (DATABASE_ARCHITECTURE.md §32, KNOWLEDGE_MODEL.md §17)
-- ---------------------------------------------------------------------------
select col_is_pk('provenance', 'actors', 'id', 'provenance.actors har uuid-primærnøkkel');
select col_is_unique(
  'provenance', 'actors', array['actor_key'],
  'aktørnøkkelen er en stabil, språkuavhengig maskinnøkkel og er unik'
);
select col_is_unique(
  'provenance', 'actors', array['auth_user_id'],
  'én aktør per brukerkonto, slik at kravet om atskilte aktører ikke kan omgås med en aktør til'
);
select col_is_unique(
  'provenance', 'actors', array['id', 'actor_type'],
  '(id, actor_type) er refererbar, slik at reviewbeslutninger kan kreve en menneskelig aktør deklarativt'
);
select fk_ok(
  'provenance', 'actors', 'auth_user_id', 'auth', 'users', 'id',
  'en menneskelig aktør kan knyttes til en brukerkonto (DATABASE_ARCHITECTURE.md §32)'
);

-- ---------------------------------------------------------------------------
-- Attribusjon på kunnskapsobjektene (ANTIDEP_CONSTITUTION.md §14)
--
-- Uttømmende: hver av de fem tabellene DATABASE_ARCHITECTURE.md §13, §14, §19,
-- §21 og §22 krever opphav på, skal ha kolonnen, den skal være NOT NULL, og den
-- skal peke på provenance.actors. En senere migrasjon som legger til en av dem
-- uten attribusjon skal slå ut her.
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select t.table_name
    from (values ('knowledge.evidence_items'), ('knowledge.claims'),
                 ('knowledge.claim_revisions'), ('knowledge.claim_evidence_links'),
                 ('knowledge.evidence_assessments')) as t(table_name)
    where not exists (
      select 1
      from pg_attribute a
      where a.attrelid = t.table_name::regclass
        and a.attname = 'created_by_actor_id'
        and a.attnum > 0
        and not a.attisdropped
        and a.atttypid = 'pg_catalog.uuid'::regtype
        and a.attnotnull
    )
  $$,
  'alle fem kunnskapstabellene har created_by_actor_id uuid not null'
);
select is_empty(
  $$
    select t.table_name
    from (values ('knowledge.evidence_items'), ('knowledge.claims'),
                 ('knowledge.claim_revisions'), ('knowledge.claim_evidence_links'),
                 ('knowledge.evidence_assessments')) as t(table_name)
    where not exists (
      select 1
      from pg_constraint con
      join pg_attribute a
        on a.attrelid = con.conrelid and a.attnum = any (con.conkey)
      where con.conrelid = t.table_name::regclass
        and con.contype = 'f'
        and con.confrelid = 'provenance.actors'::regclass
        and a.attname = 'created_by_actor_id'
    )
  $$,
  'created_by_actor_id peker på provenance.actors i alle fem tabellene'
);
select col_is_unique(
  'knowledge', 'evidence_items', array['id', 'created_by_actor_id'],
  '(id, created_by_actor_id) på evidensfunnet er refererbar for speilkolonnene i workflow'
);
select col_is_unique(
  'knowledge', 'claim_revisions', array['id', 'created_by_actor_id'],
  '(id, created_by_actor_id) på revisjonen er refererbar for speilkolonnene i workflow'
);

-- ---------------------------------------------------------------------------
-- Verifikasjonene peker på objektet de kontrollerer, og på en aktør
-- (DATABASE_ARCHITECTURE.md §29, §30)
-- ---------------------------------------------------------------------------
select fk_ok(
  'workflow', 'evidence_verifications', 'evidence_item_id',
  'knowledge', 'evidence_items', 'id',
  'en ekstraksjonsverifikasjon peker på evidensfunnet den kontrollerer'
);
select fk_ok(
  'workflow', 'evidence_verifications',
  array['evidence_item_id', 'verified_item_creator_actor_id'],
  'knowledge', 'evidence_items', array['id', 'created_by_actor_id'],
  'speilet av ekstraktøren er låst til evidensfunnet av en sammensatt fremmednøkkel'
);
select fk_ok(
  'workflow', 'claim_verifications',
  array['claim_revision_id', 'verified_revision_creator_actor_id'],
  'knowledge', 'claim_revisions', array['id', 'created_by_actor_id'],
  'speilet av forfatteren er låst til revisjonen av en sammensatt fremmednøkkel'
);
select fk_ok(
  'workflow', 'review_decisions',
  array['reviewer_actor_id', 'reviewer_actor_type'],
  'provenance', 'actors', array['id', 'actor_type'],
  'speilet av aktørtypen er låst til aktørraden av en sammensatt fremmednøkkel'
);
select fk_ok(
  'workflow', 'user_roles', 'user_id', 'auth', 'users', 'id',
  'en rolletildeling peker på en brukerkonto (DATABASE_ARCHITECTURE.md §47)'
);

-- De sju kontrollpunktene i DATABASE_ARCHITECTURE.md §30 finnes som egne
-- kolonner og er alle påkrevd. set_eq gjør at både en fjernet og en stille
-- omdøpt kolonne slår ut.
select set_eq(
  $$
    select a.attname::text
    from pg_attribute a
    where a.attrelid = 'workflow.claim_verifications'::regclass
      and a.attnum > 0 and not a.attisdropped
      and a.atttypid = 'workflow.verification_check_result'::regtype
      and a.attnotnull
  $$,
  $$values ('source_support'), ('population_match'), ('comparator_match'),
           ('timeframe_match'), ('direction_and_magnitude'), ('qualifiers_complete'),
           ('contradictory_evidence_represented')$$,
  'alle sju kontrollpunktene i DATABASE_ARCHITECTURE.md §30 er egne påkrevde kolonner'
);

-- ---------------------------------------------------------------------------
-- Avledede kolonner kan ikke motsi pekeren de er avledet av
-- ---------------------------------------------------------------------------
select is(
  (select a.attgenerated
   from pg_attribute a
   where a.attrelid = 'workflow.review_decisions'::regclass
     and a.attname = 'object_type'),
  's'::"char",
  'object_type er avledet av objektpekeren, ikke oppgitt ved siden av den'
);
select is(
  (select a.attgenerated
   from pg_attribute a
   where a.attrelid = 'workflow.user_roles'::regclass
     and a.attname = 'scope_type'),
  's'::"char",
  'scope_type er avledet av scope_id, ikke oppgitt ved siden av den'
);

-- Overlappende rolletildelinger er utelukket deklarativt, ikke av en trigger
-- (DATABASE_ARCHITECTURE.md §57).
select is(
  (select count(*)
   from pg_constraint con
   where con.conrelid = 'workflow.user_roles'::regclass
     and con.contype = 'x'),
  1::bigint,
  'workflow.user_roles har en exclusion constraint mot overlappende tildelinger'
);

-- ---------------------------------------------------------------------------
-- Relasjoner, med RESTRICT som hovedregel (DATABASE_ARCHITECTURE.md §37)
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select n.nspname, rel.relname, con.conname, con.confdeltype, con.confupdtype
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname in ('workflow', 'provenance')
      and con.contype = 'f'
      and (con.confdeltype <> 'r' or con.confupdtype <> 'r')
  $$,
  'alle fremmednøkler i workflow og provenance bruker RESTRICT ved delete og update'
);
select is_empty(
  $$
    select n.nspname, rel.relname, con.conname
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'knowledge'
      and con.contype = 'f'
      and con.confrelid = 'provenance.actors'::regclass
      and (con.confdeltype <> 'r' or con.confupdtype <> 'r')
  $$,
  'attribusjonsnøklene fra knowledge til provenance.actors bruker også RESTRICT'
);

-- ---------------------------------------------------------------------------
-- Tidsstempler eies av databasen, ikke av klienten
--
-- Samme regel som 080 holder for knowledge: hver tabell med updated_at eier
-- tidsstemplene sine. En append-only tabell uten updated_at utvider vaktposten
-- i stedet for å bli listet opp som et unntak.
-- tgtype-bitene: 2 = BEFORE, 4 = INSERT, 16 = UPDATE.
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select n.nspname || '.' || c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('workflow', 'provenance')
      and c.relkind = 'r'
      and exists (
        select 1
        from pg_attribute a
        where a.attrelid = c.oid
          and a.attname = 'updated_at'
          and a.attnum > 0
          and not a.attisdropped
      )
      and not exists (
        select 1
        from pg_trigger t
        where t.tgrelid = c.oid
          and not t.tgisinternal
          and t.tgfoid = 'catalog.set_row_timestamps()'::regprocedure
          and (t.tgtype & 2) <> 0
          and (t.tgtype & 4) <> 0
          and (t.tgtype & 16) <> 0
      )
  $$,
  'hver tabell i workflow og provenance med updated_at setter created_at og updated_at ved både INSERT og UPDATE'
);

-- ... og hver append-only tabell uten updated_at eier likevel created_at.
-- Regelen er ikke kosmetisk: created_at er referansepunktet de kallerstyrte
-- hendelsestidspunktene verified_at og decided_at måles mot, og en default alene
-- gjelder bare når kolonnen utelates. Uten triggeren kunne kalleren oppgi begge
-- og datere en hendelse hvor som helst i tid.
select is_empty(
  $$
    select n.nspname || '.' || c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('workflow', 'provenance')
      and c.relkind = 'r'
      and not exists (
        select 1
        from pg_attribute a
        where a.attrelid = c.oid
          and a.attname = 'updated_at'
          and a.attnum > 0
          and not a.attisdropped
      )
      and not exists (
        select 1
        from pg_trigger t
        where t.tgrelid = c.oid
          and not t.tgisinternal
          and t.tgfoid = 'catalog.set_created_at()'::regprocedure
          and (t.tgtype & 2) <> 0
          and (t.tgtype & 4) <> 0
      )
  $$,
  'hver append-only tabell i workflow og provenance setter created_at selv ved INSERT'
);

-- Hendelsestidspunktene er bundet mot det databaseeide referansepunktet, slik at
-- en hendelse ikke kan dateres til framtiden.
select is_empty(
  $$
    select t.table_name
    from (values ('workflow.evidence_verifications', 'verified_at'),
                 ('workflow.claim_verifications', 'verified_at'),
                 ('workflow.review_decisions', 'decided_at')) as t(table_name, event_column)
    where not exists (
      select 1
      from pg_constraint con
      where con.conrelid = t.table_name::regclass
        and con.contype = 'c'
        and pg_get_constraintdef(con.oid) like '%' || t.event_column || ' <= created_at%'
    )
  $$,
  'hendelsestidspunktet på hver append-only workflow-tabell er bundet mot created_at'
);

-- De append-only tabellene har bevisst ingen updated_at: et sist endret-felt
-- ville vært en garanti uten innhold.
select hasnt_column(
  'workflow', 'evidence_verifications', 'updated_at',
  'en utført ekstraksjonsverifikasjon har ingen updated_at'
);
select hasnt_column(
  'workflow', 'claim_verifications', 'updated_at',
  'en utført claim-verifikasjon har ingen updated_at'
);
select hasnt_column(
  'workflow', 'review_decisions', 'updated_at',
  'en registrert reviewbeslutning har ingen updated_at'
);

-- ---------------------------------------------------------------------------
-- Godkjenningen bærer avtrykket av evidenssettet den gjaldt
--
-- Lagt til av migrasjon 006 etter et reviewfunn på PR #15: publiseringsgaten kan
-- ikke avgjøre om evidensgrunnlaget er endret ved å sammenligne tidsstempler,
-- fordi now() er transaksjonens starttidspunkt og ikke committidspunktet. En
-- lenke kan derfor bære en created_at foran godkjenningen selv om den ble synlig
-- etter den. Avtrykket er rekkefølgeuavhengig og er derfor invarianten gaten
-- hviler på; assertionene her sørger for at den ikke kan forsvinne stille.
-- ---------------------------------------------------------------------------
select has_column(
  'workflow', 'review_decisions', 'approved_evidence_set_digest',
  'reviewbeslutningen bærer avtrykket av evidenssettet den gjaldt'
);
select has_trigger(
  'workflow', 'review_decisions', 'review_decisions_set_evidence_set_digest',
  'avtrykket eies av databasen, ikke av den som registrerer godkjenningen'
);
-- Avtrykket hører til publiseringsgodkjenninger og ingen andre beslutninger: en
-- tilbaketrekking av en ekstraksjon gjelder ikke et lenkesett.
select is_empty(
  $$
    select t.constraint_name
    from (values ('review_decisions_evidence_digest_pairing_check'),
                 ('review_decisions_evidence_digest_format_check')) as t(constraint_name)
    where not exists (
      select 1 from pg_constraint con
      where con.conrelid = 'workflow.review_decisions'::regclass
        and con.contype = 'c'
        and con.conname = t.constraint_name
    )
  $$,
  'avtrykket er bundet til publiseringsgodkjenninger og til det versjonerte hashformatet'
);
select ok(
  (select p.prosecdef
   from pg_proc p
   where p.oid = 'workflow.set_review_evidence_set_digest()'::regprocedure),
  'avtrykksfunksjonen er SECURITY DEFINER, fordi evidenslenkene ligger bak RLS'
);
select ok(
  exists (
    select 1
    from pg_proc p, unnest(coalesce(p.proconfig, array[]::text[])) as cfg
    where p.oid = 'workflow.set_review_evidence_set_digest()'::regprocedure
      and cfg in ('search_path=""', 'search_path=')
  ),
  'avtrykksfunksjonen har tomt search_path (DATABASE_ARCHITECTURE.md §50)'
);
-- Radlåsen på revisjonen er det som gjør avtrykket til et bilde av ett bestemt
-- øyeblikk: uten den kunne en lenke commite mellom beregningen og commit, og
-- avtrykket ville beskrevet et sett som aldri fantes samtidig. En pgTAP-test kan
-- ikke observere at en annen transaksjon blokkerer, så låsen assereres som den
-- egenskapen ved koden den er — samme framgangsmåte som for
-- publiseringsoperasjonene i 260.
select ok(
  (select p.prosrc from pg_proc p
   where p.oid = 'workflow.set_review_evidence_set_digest()'::regprocedure)
  ~ 'knowledge\.claim_revisions[^;]*for update',
  'avtrykket beregnes med radlås på revisjonen (DATABASE_ARCHITECTURE.md §61)'
);

-- ---------------------------------------------------------------------------
-- Triggerne som bærer immutabiliteten og kvalifikasjonskravet
-- ---------------------------------------------------------------------------
select has_trigger(
  'provenance', 'actors', 'actors_freeze_identity',
  'provenance.actors har en immutable-row guard på identiteten'
);
select has_trigger(
  'workflow', 'user_roles', 'user_roles_freeze_grant',
  'workflow.user_roles har en immutable-row guard på selve tildelingen'
);
select has_trigger(
  'workflow', 'review_decisions', 'review_decisions_enforce_reviewer_qualification',
  'workflow.review_decisions kontrollerer at reviewer var kvalifisert (ANTIDEP_CONSTITUTION.md §12)'
);

-- Append-only-vernet gjenbruker den generiske funksjonen fra migrasjon 004
-- framfor tre nye kopier av samme regel. Uttømmende: hver tabell i workflow uten
-- updated_at skal ha vernet.
select is_empty(
  $$
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'workflow'
      and c.relkind = 'r'
      and not exists (
        select 1
        from pg_attribute a
        where a.attrelid = c.oid and a.attname = 'updated_at'
          and a.attnum > 0 and not a.attisdropped
      )
      and not exists (
        select 1
        from pg_trigger t
        where t.tgrelid = c.oid
          and not t.tgisinternal
          and t.tgfoid = 'knowledge.reject_append_only_mutation()'::regprocedure
          and (t.tgtype & 2) <> 0
          and (t.tgtype & 16) <> 0
          and (t.tgtype & 8) <> 0
      )
  $$,
  'hver append-only tabell i workflow avviser både UPDATE og DELETE'
);

-- ---------------------------------------------------------------------------
-- Privilegerte funksjoner (DATABASE_ARCHITECTURE.md §50)
--
-- Uttømmende over schemaene, ikke en håndholdt liste: en ny funksjon kan ikke
-- slippe forbi vaktposten ved at noen glemmer å føre den opp.
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select p.oid::regprocedure::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('workflow', 'provenance')
      and has_function_privilege('public', p.oid, 'execute')
  $$,
  'PUBLIC kan ikke kjøre noen funksjon i workflow eller provenance'
);

-- Kvalifikasjonskontrollen må være SECURITY DEFINER for å kunne lese
-- medlemskapstabellen forbi RLS, og skal derfor ha et kontrollert search_path.
select is(
  (select p.prosecdef
   from pg_proc p
   where p.oid = 'workflow.enforce_reviewer_qualification()'::regprocedure),
  true,
  'kvalifikasjonskontrollen er SECURITY DEFINER, fordi medlemskapstabellen har RLS'
);
select ok(
  exists (
    select 1
    from pg_proc p, unnest(coalesce(p.proconfig, array[]::text[])) as cfg
    where p.oid = 'workflow.enforce_reviewer_qualification()'::regprocedure
      and cfg in ('search_path=""', 'search_path=')
  ),
  'kvalifikasjonskontrollen har tomt search_path (DATABASE_ARCHITECTURE.md §50)'
);

-- ---------------------------------------------------------------------------
-- Dokumentasjon i databasen
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select n.nspname || '.' || c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('workflow', 'provenance')
      and c.relkind = 'r'
      and coalesce(obj_description(c.oid, 'pg_class'), '') = ''
  $$,
  'alle tabeller i workflow og provenance har en kommentar som dokumenterer formålet'
);
select is_empty(
  $$
    select n.nspname || '.' || t.typname
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname in ('workflow', 'provenance')
      and t.typtype = 'e'
      and coalesce(obj_description(t.oid, 'pg_type'), '') = ''
  $$,
  'alle kontrollerte vokabularer i workflow og provenance er dokumentert'
);
select is_empty(
  $$
    select t.table_name
    from (values ('knowledge.evidence_items'), ('knowledge.claims'),
                 ('knowledge.claim_revisions'), ('knowledge.claim_evidence_links'),
                 ('knowledge.evidence_assessments')) as t(table_name)
    where coalesce(
            col_description(
              t.table_name::regclass,
              (select a.attnum from pg_attribute a
               where a.attrelid = t.table_name::regclass
                 and a.attname = 'created_by_actor_id')
            ), '') = ''
  $$,
  'created_by_actor_id er dokumentert i alle fem kunnskapstabellene'
);

select * from finish();

rollback;
