-- Migrasjon 003 — tilgang til knowledge.
--
-- Kritisk negativ test fra MVP_IMPLEMENTATION_PLAN.md §42 og §47 og
-- DATABASE_ARCHITECTURE.md §5, §48 og §49: kunnskapstabellene er default deny.
-- Verken anonyme eller vanlige innloggede brukere skal kunne lese eller skrive
-- i knowledge, og RLS skal være den andre sperren, ikke bare fraværet av grants.
-- Klientflaten leser publiserte projeksjoner i api (migrasjon 007).
--
-- Kildene og evidensfunnene som ligger her er dessuten ikke ferdig vurdert
-- klinisk innhold, men ekstraksjonsforslag fram til verifikasjons- og
-- reviewgatene i migrasjon 005 og 006 (ANTIDEP_CONSTITUTION.md §12). At ingen
-- klientrolle kan nå dem er derfor et innholdskrav, ikke bare et sikkerhetskrav.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(15);

-- ---------------------------------------------------------------------------
-- Lag 1: grants
-- ---------------------------------------------------------------------------
-- Migrasjon 007 ga SELECT på alle fire, som api.published_claim_evidence leser.
-- knowledge.source_versions kom med fordi source_locator peker inn i en bestemt
-- hentet versjon, ikke i kilden generelt: uten versjonen er drilldownen ikke
-- reproduserbar for en levende kilde (DATABASE_ARCHITECTURE.md §18).
select is_empty(
  $$
    select t.table_name, r.role_name, p.privilege
    from (values ('knowledge.sources'), ('knowledge.source_identifiers'),
                 ('knowledge.source_versions'), ('knowledge.evidence_items'))
           as t(table_name)
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'),
                       ('references'), ('trigger')) as p(privilege)
    where has_table_privilege(r.role_name, t.table_name, p.privilege)
      and not (p.privilege = 'select' and r.role_name in ('anon', 'authenticated'))
  $$,
  'klientrollene har bare SELECT på kilde- og evidenstabellene, aldri noen skriverett'
);

-- Klientrollene har heller ikke usage på selve schemaet, så et framtidig uhell
-- med en enkelt GRANT på en tabell er ikke nok til å åpne knowledge.
select ok(
  not has_schema_privilege('anon', 'knowledge', 'usage'),
  'anon har ikke usage på knowledge'
);
select ok(
  not has_schema_privilege('authenticated', 'knowledge', 'usage'),
  'authenticated har ikke usage på knowledge'
);

-- ---------------------------------------------------------------------------
-- Lag 2: RLS er aktivert på alle kunnskapstabeller, og policyene er lesepolicyer
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'knowledge'
      and c.relkind = 'r'
      and not c.relrowsecurity
  $$,
  'RLS er aktivert på alle kunnskapstabeller'
);
-- Scoped til kilde- og evidenslaget; påstandslagets policyer kontrolleres i 160
-- og hele inventaret i 290. polcmd 'r' betyr SELECT.
--
-- De tre `*_editor_read`-policyene kom med migrasjon 007d: en editor må se hele
-- kilderegisteret, alle kildeversjoner og alle evidensfunn for å kunne
-- registrere et nytt funn — det publiserte predikatet ville skjult nettopp den
-- kilden som nettopp ble opprettet. source_identifiers har ingen slik policy:
-- DOI og PMID er ikke noe registreringen velger mellom, og skriveveien for dem
-- finnes ikke ennå.
select set_eq(
  $$
    select c.relname || ':' || p.polname || ':' || p.polcmd::text
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'knowledge'
      and c.relname in ('sources', 'source_identifiers', 'source_versions',
                        'evidence_items')
  $$,
  $$
    values ('sources:sources_published_read:r'),
           ('sources:sources_editor_read:r'),
           ('source_identifiers:source_identifiers_published_read:r'),
           ('source_versions:source_versions_published_read:r'),
           ('source_versions:source_versions_editor_read:r'),
           ('evidence_items:evidence_items_published_read:r'),
           ('evidence_items:evidence_items_editor_read:r')
  $$,
  'kilde- og evidenslaget har nøyaktig sine sju lesepolicyer, og ingen skrivepolicy'
);

-- ---------------------------------------------------------------------------
-- Faktiske forsøk med Data API-rollene (42501 = insufficient_privilege)
--
-- Merk hva som nå stopper dem. Etter migrasjon 007 *har* anon og authenticated
-- SELECT på flere av tabellene under, men de mangler fortsatt usage på schemaet
-- og kan derfor ikke navngi dem: feilen er «permission denied for schema», ikke
-- «for table». Grantene virker bare gjennom viewene i api, som ble navneoppslått
-- da de ble opprettet. Skulle usage bli gitt ved et uhell, er RLS neste sperre,
-- og den kontrolleres i 290_api_read_model_access_test.sql.
-- ---------------------------------------------------------------------------
set local role anon;
select throws_ok(
  'select 1 from knowledge.sources',
  '42501', null,
  'anon nektes lesing av kildene'
);
select throws_ok(
  'select 1 from knowledge.evidence_items',
  '42501', null,
  'anon nektes lesing av evidensfunnene'
);
select throws_ok(
  'select 1 from knowledge.source_identifiers',
  '42501', null,
  'anon nektes lesing av kildeidentifikatorene'
);
select throws_ok(
  $$insert into knowledge.sources (source_type, title, authors_or_issuer)
    values ('journal_article', 'anon-innsatt', 'anon')$$,
  '42501', null,
  'anon kan ikke opprette kilder'
);
reset role;

set local role authenticated;
select throws_ok(
  'select 1 from knowledge.evidence_items',
  '42501', null,
  'vanlig innlogget bruker nektes lesing av evidensfunnene'
);
select throws_ok(
  'select 1 from knowledge.source_versions',
  '42501', null,
  'vanlig innlogget bruker nektes lesing av kildeversjonene'
);
select throws_ok(
  $$update knowledge.sources set source_status = 'retracted'$$,
  '42501', null,
  'vanlig innlogget bruker kan ikke endre kildestatus'
);
select throws_ok(
  'delete from knowledge.evidence_items',
  '42501', null,
  'vanlig innlogget bruker kan ikke slette evidensfunn'
);
reset role;

-- service_role omgår RLS, men ikke grants, og er ikke applikasjonens
-- universalnøkkel (DATABASE_ARCHITECTURE.md §49). Evidenspipelinen skal ha en
-- egen least privilege-identitet når den trenger en skrivevei.
set local role service_role;
select throws_ok(
  'select 1 from knowledge.evidence_items',
  '42501', null,
  'service_role nektes lesing av knowledge fordi grants mangler'
);
reset role;

-- ---------------------------------------------------------------------------
-- RLS er en reell sperre, ikke bare fraværet av grants
--
-- Selvtest av lag 2: hvis en framtidig migrasjon ved et uhell gir SELECT til en
-- klientrolle, skal RLS fortsatt gi null rader. Granten finnes bare inne i
-- denne transaksjonen og rulles tilbake.
-- ---------------------------------------------------------------------------
grant usage on schema knowledge to authenticated;
grant select on knowledge.evidence_items to authenticated;

set local role authenticated;
select is(
  (select count(*) from knowledge.evidence_items),
  0::bigint,
  'RLS gir null rader selv med SELECT-grant, fordi ingen policy slipper noen inn'
);
reset role;

select * from finish();

rollback;
