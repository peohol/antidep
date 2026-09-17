-- Migrasjon 013a — monografistandarden som et versjonert register.
--
-- Registeret er det en monografibestilling opprettet behov av, og det en
-- søkeplan leser kravene til søkedekning fra. Prøven dekker tre ting:
--
--   1. at standarden faktisk er komplett i databasen — 80 maler, 13 profiler,
--      sammenhengende identiteter og en kildeprofil eller en erklært åpen
--      profil per mal;
--   2. at skillet mellom obligatorisk, betinget og avledet er bevart, og at en
--      betinget mal ikke kan finnes uten sin betingelse;
--   3. at registeret er uforanderlig, slik at en ny standardversjon ikke kan
--      endre spørsmålet under et svar som allerede finnes.
--
-- Parityen mot `docs/MONOGRAPH_STANDARD.md` og `src/monograph/standard.ts`
-- prøves på TypeScript-siden (`standard.test.ts`, `standard-seed.test.ts`):
-- den kan bare prøves der dokumentet finnes.
begin;

create extension if not exists pgtap with schema extensions;

select plan(24);

-- ---------------------------------------------------------------------------
-- 1. Registeret er komplett
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::integer from knowledge.monograph_standard_versions),
  1,
  'det finnes nøyaktig én registrert standardversjon'
);
select is(
  (select version from knowledge.monograph_standard_versions),
  '1.0.0',
  'standardversjonen er 1.0.0'
);
select is(
  (select count(*)::integer from knowledge.monograph_question_templates
   where standard_version = '1.0.0'),
  80,
  'standarden har 80 spørsmålsmaler'
);
select is(
  (select count(*)::integer from knowledge.monograph_source_profiles
   where standard_version = '1.0.0'),
  13,
  'standarden har 13 kildeprofiler'
);

select is_empty(
  $$
    select format('MN%s', lpad(n::text, 2, '0'))
    from generate_series(1, 80) as n
    where not exists (
      select 1 from knowledge.monograph_question_templates t
      where t.standard_version = '1.0.0'
        and t.code = format('MN%s', lpad(n::text, 2, '0'))
    )
  $$,
  'malidentitetene er sammenhengende MN01–MN80'
);

select is_empty(
  $$
    select t.code
    from knowledge.monograph_question_templates t
    where t.standard_version = '1.0.0'
      and not t.open_source_profiles
      and not exists (
        select 1 from knowledge.monograph_template_profiles l where l.template_id = t.id
      )
  $$,
  'hver mal har minst én kildeprofil, eller er erklært åpen'
);

select is(
  (select array_agg(t.code order by t.ordinal)
   from knowledge.monograph_question_templates t
   where t.standard_version = '1.0.0' and t.open_source_profiles),
  array['MN80'],
  'MN80 er den ene malen med åpen kildeprofil: profilen følger av funnet'
);

select is_empty(
  $$
    select p.code
    from knowledge.monograph_source_profiles p
    where p.standard_version = '1.0.0'
      and not exists (
        select 1 from knowledge.monograph_template_profiles l where l.profile_id = p.id
      )
  $$,
  'hver kildeprofil brukes av minst én mal'
);

select is_empty(
  $$
    select p.code
    from knowledge.monograph_source_profiles p
    where p.standard_version = '1.0.0'
      and not exists (
        select 1 from knowledge.monograph_search_track_profiles l where l.profile_id = p.id
      )
  $$,
  'hver kildeprofil har minst ett obligatorisk søkespor'
);

-- ---------------------------------------------------------------------------
-- 2. Skillene standarden krever, er bevart
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::integer from knowledge.monograph_question_templates
   where standard_version = '1.0.0' and requirement = 'derived'),
  1,
  'nøyaktig én mal er avledet presentasjon (MN79)'
);
select is(
  (select code from knowledge.monograph_question_templates
   where standard_version = '1.0.0' and requirement = 'derived'),
  'MN79',
  'den avledede malen er MN79'
);
select isnt_empty(
  $$
    select code from knowledge.monograph_question_templates
    where standard_version = '1.0.0' and requirement = 'conditional'
  $$,
  'det finnes betingede maler — 80 maler er ikke 80 obligatoriske spørsmål'
);
select is_empty(
  $$
    select code from knowledge.monograph_question_templates
    where standard_version = '1.0.0'
      and requirement <> 'mandatory'
      and condition_text is null
  $$,
  'ingen betinget eller avledet mal finnes uten sin betingelse'
);
select is(
  (select array_agg(code order by ordinal)
   from knowledge.monograph_question_templates
   where standard_version = '1.0.0' and conditional_deepening is not null),
  array['MN50', 'MN51', 'MN54', 'MN55', 'MN62', 'MN65'],
  'de seks screeningsmalene bærer sin betingede fordypning som et eget krav'
);
select is_empty(
  $$
    select code from knowledge.monograph_question_templates
    where standard_version = '1.0.0'
      and conditional_deepening is not null
      and requirement <> 'mandatory'
  $$,
  'en screeningsmal er obligatorisk å undersøke; det er fordypningen som er betinget'
);
select isnt_empty(
  $$
    select code from knowledge.monograph_question_templates
    where standard_version = '1.0.0'
      and 'switch_target' = any (expansion_axes)
  $$,
  'bytteparmalene gjentas på en rettet akse: A→B og B→A er forskjellige behov'
);
select isnt_empty(
  $$
    select code from knowledge.monograph_question_templates
    where standard_version = '1.0.0'
      and cardinality(expansion_axes) > 0
  $$,
  'maler gjentas per avgrensning: 80 maler betyr ikke 80 behov'
);

-- ---------------------------------------------------------------------------
-- 3. Registeret er uforanderlig
-- ---------------------------------------------------------------------------
select throws_ok(
  $$
    update knowledge.monograph_question_templates
    set prompt = 'Et annet spørsmål'
    where code = 'MN01'
  $$,
  '23001',
  'Monografistandardens register er uforanderlig.',
  'et spørsmål kan ikke skrives om under et svar som allerede finnes'
);
select throws_ok(
  $$ delete from knowledge.monograph_question_templates where code = 'MN80' $$,
  '23001',
  'Monografistandardens register er uforanderlig.',
  'en mal kan ikke slettes ut av en standardversjon'
);
select throws_ok(
  $$
    update knowledge.monograph_source_profiles set first_choice = 'Noe annet'
    where code = 'REG'
  $$,
  '23001',
  'Monografistandardens register er uforanderlig.',
  'en kildeprofil kan ikke skrives om'
);
select throws_ok(
  $$ update knowledge.monograph_standard_versions set published_on = current_date $$,
  '23001',
  'Monografistandardens register er uforanderlig.',
  'standardversjonen kan ikke skrives om'
);

-- En ny versjon legges inn ved siden av, og de gamle radene blir stående.
insert into knowledge.monograph_standard_versions
  (version, title, document_path, published_on)
values ('1.0.1', 'Prøveversjon', 'docs/MONOGRAPH_STANDARD.md', current_date);

select is(
  (select count(*)::integer from knowledge.monograph_standard_versions),
  2,
  'en ny standardversjon legges inn ved siden av den gamle'
);
select is(
  (select count(*)::integer from knowledge.monograph_question_templates
   where standard_version = '1.0.0'),
  80,
  'malene i den gamle versjonen står urørt når en ny versjon legges inn'
);

-- ---------------------------------------------------------------------------
-- 4. Ingen klientrolle kommer til registeret
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select c.relname, a.grantee::regrole::text
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) a
    where n.nspname = 'knowledge'
      and c.relname like 'monograph_%'
      and (a.grantee = 0 or a.grantee::regrole::text in ('anon', 'authenticated', 'service_role'))
  $$,
  'ingen klientrolle har direkte tilgang til standardregisteret'
);

select * from finish();

rollback;
