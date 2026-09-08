-- Migrasjon 006 — struktur i publiseringslaget.
--
-- Verifiserer at publiseringshistorikken fra MVP_IMPLEMENTATION_PLAN.md §23
-- finnes med de feltene, relasjonene og vokabularene DATABASE_ARCHITECTURE.md
-- §39 og §40 krever, og at de privilegerte funksjonene har den formen §50 krever.
-- Constraint-atferd og immutabilitet testes i 240, selve gatene i 250 og tilgang
-- i 260. De schemauttømmende vaktpostene over knowledge ligger fortsatt i
-- 040_catalog_structure_test.sql og 080_knowledge_structure_test.sql, og fanger
-- denne tabellen automatisk.
begin;

create extension if not exists pgtap with schema extensions;

select plan(47);

-- ---------------------------------------------------------------------------
-- Tabellen og §39 sitt minimumsfeltsett
-- ---------------------------------------------------------------------------
select has_table('knowledge', 'publication_events', 'knowledge.publication_events finnes');
select has_pk(
  'knowledge', 'publication_events',
  'knowledge.publication_events har en primærnøkkel'
);

select col_not_null(
  'knowledge', 'publication_events', 'claim_id',
  'hendelsen peker alltid på en identifiserbar påstand'
);
select col_not_null(
  'knowledge', 'publication_events', 'action',
  'hendelsen sier alltid hvilken tilstandsovergang den registrerer'
);
select col_not_null(
  'knowledge', 'publication_events', 'published_by_actor_id',
  'hendelsen er alltid attribuert til en aktør (ANTIDEP_CONSTITUTION.md §14)'
);
select col_not_null(
  'knowledge', 'publication_events', 'reason',
  'hendelsen har alltid en begrunnelse (ANTIDEP_CONSTITUTION.md §14)'
);
select col_not_null(
  'knowledge', 'publication_events', 'published_at',
  'hendelsen er alltid datert (DATABASE_ARCHITECTURE.md §7.3)'
);
select col_not_null(
  'knowledge', 'publication_events', 'created_at',
  'registreringstidspunktet er alltid satt'
);

-- Pekerne skal kunne være tomme: en avpublisering har ingen etterfølgende
-- revisjon, og en førstegangspublisering ingen forutgående. Var de NOT NULL,
-- kunne ikke §39 sine fire handlinger uttrykkes.
select col_is_null(
  'knowledge', 'publication_events', 'revision_id',
  'revision_id kan være tom, slik at en avpublisering kan uttrykkes'
);
select col_is_null(
  'knowledge', 'publication_events', 'previous_revision_id',
  'previous_revision_id kan være tom, slik at en førstegangspublisering kan uttrykkes'
);
select col_is_null(
  'knowledge', 'publication_events', 'previous_event_id',
  'previous_event_id kan være tom, men bare på den første hendelsen for en påstand'
);

-- Hendelsen er en observasjon og har bevisst ingen updated_at.
select hasnt_column(
  'knowledge', 'publication_events', 'updated_at',
  'en registrert publiseringshendelse har ingen updated_at'
);

-- ---------------------------------------------------------------------------
-- Kontrollerte vokabularer
-- ---------------------------------------------------------------------------
select enum_has_labels(
  'knowledge', 'publication_action',
  array['publish', 'replace', 'withdraw', 'rollback'],
  'knowledge.publication_action dekker de fire handlingene i DATABASE_ARCHITECTURE.md §39'
);
select enum_has_labels(
  'knowledge', 'publication_object_type', array['claim'],
  'knowledge.publication_object_type dekker den ene objekttypen som kan publiseres'
);

-- §39 sitt object_type finnes som lesbart felt, men er avledet og kan derfor
-- ikke si noe annet enn fremmednøkkelen gjør.
select is(
  (select a.attgenerated
   from pg_attribute a
   where a.attrelid = 'knowledge.publication_events'::regclass
     and a.attname = 'object_type'),
  's'::"char",
  'object_type er en generert kolonne og ikke en verdi kalleren oppgir'
);

-- Regelen om hvilke pekere hver handling skal ha, er uttømmende over vokabularet.
-- Vaktposten fanger den migrasjonen som legger til en femte handling uten å ta
-- stilling til hva pekeren skal peke på etterpå.
select is_empty(
  $$
    select e.enumlabel::text
    from pg_enum e
    join pg_type t on t.oid = e.enumtypid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'knowledge' and t.typname = 'publication_action'
      and position(e.enumlabel in (
            select pg_get_constraintdef(con.oid)
            from pg_constraint con
            where con.conrelid = 'knowledge.publication_events'::regclass
              and con.conname = 'publication_events_action_pointer_check'
          )) = 0
  $$,
  'hver handling i vokabularet er dekket av regelen om hvilke pekere som skal være satt'
);

-- ---------------------------------------------------------------------------
-- Relasjoner. Cross-row-reglene er løst med sammensatte fremmednøkler, ikke med
-- CHECK som leser andre tabeller (DATABASE_ARCHITECTURE.md §59).
-- ---------------------------------------------------------------------------
select fk_ok(
  'knowledge', 'publication_events', array['claim_id'],
  'knowledge', 'claims', array['id'],
  'hendelsen henger på en ekte påstandsidentitet, ikke på en generisk object_id'
);
select fk_ok(
  'knowledge', 'publication_events', array['revision_id', 'claim_id', 'revision_number'],
  'knowledge', 'claim_revisions', array['id', 'claim_id', 'revision_number'],
  'den publiserte revisjonen må tilhøre den påstanden hendelsen gjelder, og speilet av revisjonsnummeret er låst til revisjonsraden'
);
select fk_ok(
  'knowledge', 'publication_events',
  array['previous_revision_id', 'claim_id', 'previous_revision_number'],
  'knowledge', 'claim_revisions', array['id', 'claim_id', 'revision_number'],
  'den forrige publiserte revisjonen er låst på samme måte'
);
select fk_ok(
  'knowledge', 'publication_events', array['previous_event_id', 'claim_id'],
  'knowledge', 'publication_events', array['id', 'claim_id'],
  'forrige hendelse i kjeden må gjelde den samme påstanden'
);
select fk_ok(
  'knowledge', 'publication_events',
  array['published_by_actor_id', 'published_by_actor_type'],
  'provenance', 'actors', array['id', 'actor_type'],
  'speilet av aktørtypen er låst til aktørraden, slik at kravet om et menneske er strukturelt'
);

-- Samtidighetsvernet er deklarativt: to hendelser for samme påstand kan ikke ha
-- samme forgjenger. NULLS NOT DISTINCT er nødvendig for at det også skal gjelde
-- førstegangspubliseringen, der forgjengeren er NULL.
select ok(
  exists (
    select 1
    from pg_constraint con
    where con.conrelid = 'knowledge.publication_events'::regclass
      and con.contype = 'u'
      and con.conname = 'publication_events_no_forked_history_key'
  ),
  'publiseringshistorikken har en unikhetsregel mot forgrening'
);
select ok(
  (select i.indnullsnotdistinct
   from pg_index i
   join pg_constraint con on con.conindid = i.indexrelid
   where con.conname = 'publication_events_no_forked_history_key'),
  'unikhetsregelen behandler NULL-forgjengere som like, slik at to samtidige førstegangspubliseringer kolliderer'
);

-- ---------------------------------------------------------------------------
-- Tidsstempler, triggere og oppslag
-- ---------------------------------------------------------------------------
select has_trigger(
  'knowledge', 'publication_events', 'publication_events_set_created_at',
  'registreringstidspunktet eies av databasen, ikke av kalleren'
);
select has_trigger(
  'knowledge', 'publication_events', 'publication_events_reject_mutation',
  'publiseringshistorikken er append-only (DATABASE_ARCHITECTURE.md §36, §40)'
);
select has_trigger(
  'knowledge', 'claim_evidence_links', 'claim_evidence_links_reject_after_publication',
  'evidensgrunnlaget forsegles av publisering, ikke bare av evidensvurderingen'
);

-- Registreringstiden i knowledge ble databaseeid av denne migrasjonen fordi
-- gaten begynner å lese den. Vaktposten i 080 er uttømmende over schemaet; her
-- assereres de fire tabellene ved navn, slik at en fjernet trigger ikke kan
-- forsvinne i en generell formulering.
select has_trigger(
  'knowledge', 'evidence_items', 'evidence_items_set_created_at',
  'knowledge.evidence_items eier sin egen registreringstid'
);
select has_trigger(
  'knowledge', 'claim_revisions', 'claim_revisions_set_created_at',
  'knowledge.claim_revisions eier sin egen registreringstid'
);
select has_trigger(
  'knowledge', 'claim_evidence_links', 'claim_evidence_links_set_created_at',
  'knowledge.claim_evidence_links eier sin egen registreringstid; publiseringsgaten leser den'
);
select has_trigger(
  'knowledge', 'evidence_assessments', 'evidence_assessments_set_created_at',
  'knowledge.evidence_assessments eier sin egen registreringstid'
);

select has_index(
  'knowledge', 'publication_events', 'publication_events_claim_published_at_idx',
  'oppslaget «hva sa vi om denne påstanden, og når?» er indeksert'
);
select has_index(
  'knowledge', 'publication_events', 'publication_events_revision_id_idx',
  'oppslaget «har denne revisjonen vært publisert?» er indeksert; forseglingen og rollback bruker det'
);

-- ---------------------------------------------------------------------------
-- De privilegerte funksjonene (DATABASE_ARCHITECTURE.md §50)
-- ---------------------------------------------------------------------------
select has_function(
  'knowledge', 'assert_claim_revision_publishable', array['uuid'],
  'publiseringsgaten finnes som en egen funksjon'
);
select has_function(
  'knowledge', 'assert_claim_revision_ready_for_approval', array['uuid'],
  'forutsetningene før den menneskelige godkjenningen finnes som en egen funksjon (migrasjon 006e)'
);
select has_function(
  'knowledge', 'claim_evidence_set_digest', array['uuid'],
  'avtrykket av evidenssettet finnes som en egen funksjon'
);
-- Avtrykket må skille et tomt sett fra en manglende verdi, ellers ville en
-- revisjon uten lenker og en revisjon ingen har beregnet avtrykk for sett like ut.
select isnt(
  (select knowledge.claim_evidence_set_digest('00000000-0000-0000-0000-0000000000ff')),
  null,
  'et tomt evidenssett har sitt eget avtrykk og kollapser ikke til NULL'
);
-- ... og avtrykket må faktisk endre seg når settet gjør det. Uten denne
-- assertionen kunne funksjonen returnert en konstant uten at noen test sa fra.
select isnt(
  (select knowledge.claim_evidence_set_digest(r.id)
   from knowledge.claim_revisions r
   order by r.id limit 1),
  (select knowledge.claim_evidence_set_digest('00000000-0000-0000-0000-0000000000ff')),
  'en revisjon med evidenslenker får et annet avtrykk enn et tomt sett'
);
select has_function(
  'knowledge', 'assert_publisher_authorized', array['uuid', 'uuid'],
  'kontrollen av publiseringsretten finnes som en egen funksjon'
);
select has_function(
  'knowledge', 'publish_claim_revision', array['uuid', 'uuid', 'text'],
  'publiseringsoperasjonen finnes'
);
select has_function(
  'knowledge', 'withdraw_claim_publication', array['uuid', 'uuid', 'text'],
  'avpubliseringsoperasjonen finnes'
);
select has_function(
  'knowledge', 'rollback_claim_publication', array['uuid', 'uuid', 'uuid', 'text'],
  'rollback-operasjonen finnes (DATABASE_ARCHITECTURE.md §40)'
);

-- De tre inngangspunktene må være SECURITY DEFINER for å kunne lese rollemodellen
-- og reviewbeslutningene forbi RLS.
select is_empty(
  $$
    select f.function_name
    from (values ('knowledge.publish_claim_revision(uuid, uuid, text)'),
                 ('knowledge.withdraw_claim_publication(uuid, uuid, text)'),
                 ('knowledge.rollback_claim_publication(uuid, uuid, uuid, text)'))
           as f(function_name)
    where not (select p.prosecdef from pg_proc p where p.oid = f.function_name::regprocedure)
  $$,
  'de tre publiseringsoperasjonene er SECURITY DEFINER'
);

-- Hjelpefunksjonene er bevisst ikke DEFINER. De kalles fra DEFINER-konteksten og
-- arver rettighetene der; kalles de av noen andre, kan de ikke lese mer enn den
-- kalleren allerede kunne. Det holder DEFINER-flaten så liten som mulig.
select is_empty(
  $$
    select f.function_name
    from (values ('knowledge.assert_claim_revision_publishable(uuid)'),
                 ('knowledge.assert_claim_revision_ready_for_approval(uuid)'),
                 ('knowledge.assert_publisher_authorized(uuid, uuid)'))
           as f(function_name)
    where (select p.prosecdef from pg_proc p where p.oid = f.function_name::regprocedure)
  $$,
  'gaten og retighetskontrollen er SECURITY INVOKER, slik at DEFINER-flaten holdes minst mulig'
);

-- Tomt search_path på alle fem, ikke bare på DEFINER-funksjonene: en funksjon
-- som slår opp objekter via search_path kan omdirigeres av kalleren.
select is_empty(
  $$
    select f.function_name
    from (values ('knowledge.assert_claim_revision_publishable(uuid)'),
                 ('knowledge.assert_claim_revision_ready_for_approval(uuid)'),
                 ('knowledge.assert_publisher_authorized(uuid, uuid)'),
                 ('knowledge.publish_claim_revision(uuid, uuid, text)'),
                 ('knowledge.withdraw_claim_publication(uuid, uuid, text)'),
                 ('knowledge.rollback_claim_publication(uuid, uuid, uuid, text)'),
                 ('knowledge.reject_evidence_link_after_publication()'),
                 ('knowledge.claim_evidence_set_digest(uuid)'))
           as f(function_name)
    where not exists (
      select 1
      from pg_proc p, unnest(coalesce(p.proconfig, array[]::text[])) as cfg
      where p.oid = f.function_name::regprocedure
        and cfg in ('search_path=""', 'search_path=')
    )
  $$,
  'alle de nye funksjonene har tomt search_path (DATABASE_ARCHITECTURE.md §50)'
);

-- ---------------------------------------------------------------------------
-- Dokumentasjon i databasen
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select f.function_name
    from (values ('knowledge.assert_claim_revision_publishable(uuid)'),
                 ('knowledge.assert_claim_revision_ready_for_approval(uuid)'),
                 ('knowledge.assert_publisher_authorized(uuid, uuid)'),
                 ('knowledge.publish_claim_revision(uuid, uuid, text)'),
                 ('knowledge.withdraw_claim_publication(uuid, uuid, text)'),
                 ('knowledge.rollback_claim_publication(uuid, uuid, uuid, text)'),
                 ('knowledge.reject_evidence_link_after_publication()'),
                 ('knowledge.claim_evidence_set_digest(uuid)'))
           as f(function_name)
    where coalesce(obj_description(f.function_name::regprocedure, 'pg_proc'), '') = ''
  $$,
  'alle de nye funksjonene er dokumentert som sikkerhetskritisk kode'
);
-- Primærnøkkelen er unntatt, som overalt ellers i schemaet: den er en
-- databasegenerert uuid uten egen betydning, og en kommentar på den ville vært
-- støy. Alle kolonner som bærer betydning skal derimot forklare seg.
select is_empty(
  $$
    select a.attname::text
    from pg_attribute a
    where a.attrelid = 'knowledge.publication_events'::regclass
      and a.attnum > 0
      and not a.attisdropped
      and a.attname <> 'id'
      and coalesce(col_description(a.attrelid, a.attnum), '') = ''
  $$,
  'hver betydningsbærende kolonne på publiseringshendelsen er dokumentert'
);

-- ---------------------------------------------------------------------------
-- RLS er aktivert (detaljert tilgangstest i 260)
-- ---------------------------------------------------------------------------
select ok(
  (select c.relrowsecurity
   from pg_class c
   where c.oid = 'knowledge.publication_events'::regclass),
  'RLS er aktivert på publiseringshistorikken'
);

select * from finish();

rollback;
