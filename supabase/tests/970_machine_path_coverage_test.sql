-- Migrasjon 013x — fra kjørerens faktiske evner til porten.
--
-- 860 og 870 følger én plan gjennom forløpet. Denne filen stiller det spørsmålet
-- de to ikke stiller: *kan* kjeden i det hele tatt komme fram, for hver av
-- kildeprofilene Antidep har?
--
-- Spørsmålet måtte stilles fordi svaret en stund var nei for alle tretten, uten
-- at én prøve merket det. 013v beholdt skjæringen i `runSearch` — et søk kan
-- bare erklære spor plattformen dekker — og fjernet samtidig den eneste veien
-- de øvrige sporene noen gang ble dekket på: at modellen rapporterte søkene
-- selv. Alle tre søkeveiene dekker bare `bibliographic_database`. EFF og AE
-- manglet da fem av seks obligatoriske spor; REG, PROD og SYN hadde ikke ett
-- eneste utførbart. Planene kunne aldri lukkes, og de sa ikke fra.
--
-- Prøvene merket det ikke fordi de registrerte søk som erklærte
-- `systematic_review_search` på Europe PMC og `trial_registries` på en
-- oppdiktet «ClinicalTrials.gov» — spor og søkeveier den virkelige kjøringen
-- aldri kan produsere. Derfor går denne filen den andre veien: den starter i
-- registeret over søkeveier, som `src/ops/monograph-search.test.ts` holder lik
-- SEARCH_PLATFORMS i TypeScript, og spør hva porten sier for hver profil.
--
--   * registeret er det samme som kjøreren faktisk kaller,
--   * ingen søkevei kan erklære et spor den ikke er registrert for,
--   * hver profils obligatoriske spor er enten utførbare eller ført som
--     `no_machine_path` — aldri stille ventende,
--   * porten navngir dem framfor å nekte uten å si hvorfor, og
--   * redaktørens vei ut finnes, og fører planen videre.
--
-- SQLSTATE 22023 = invalid_parameter_value, 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(19);

insert into auth.users (id, email)
values ('97000000-0000-4000-8000-00000000000a', 'redaktor-970@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac970000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-970',
   'Redaktør 970', 'Editor for prøven av den maskinelle søkeveien i 970.',
   '97000000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('97000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
   'ac970000-0000-4000-8000-00000000000a', 'Editor-tildeling for 970.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table refs (label text primary key, value text not null) on commit drop;
grant select, insert on svar to authenticated, anon;
grant select on refs to authenticated, anon;

select set_config('request.jwt.claims',
                  '{"sub":"97000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 970.');
reset role;

-- ===========================================================================
-- Del 1 — Registeret er det kjøreren faktisk kan
-- ===========================================================================
-- Den andre halvdelen av denne kontrollen ligger i
-- src/ops/monograph-search.test.ts, som leser seedingen i migrasjonen og
-- sammenligner den med SEARCH_PLATFORMS. Her står den siden porten hviler på.
select bag_eq(
  $$select platform, track_code from knowledge.monograph_search_platforms$$,
  $$values ('Europe PMC', 'bibliographic_database'),
           ('PubMed', 'bibliographic_database'),
           ('Crossref', 'bibliographic_database')$$,
  'registeret over søkeveier er nøyaktig de tre Antidep kaller, med det ene sporet de dekker'
);

select is(
  knowledge.monograph_executable_track_codes(),
  array['bibliographic_database'],
  'og de utførbare sporene er utledet av registeret, ikke skrevet av ved siden av det'
);

-- ===========================================================================
-- Del 2 — Ingen søkevei kan erklære et spor den ikke er registrert for
-- ===========================================================================
insert into refs (label, value)
select 'eff', p.reference
from workflow.monograph_search_plans p
join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
where sp.code = 'EFF'
order by p.created_at
limit 1;

select throws_ok(
  format($$
    insert into workflow.monograph_searches
      (plan_id, plan_version, platform, query_string, executed_at, result_count,
       screened_count, outcome, execution_evidence, evidence_endpoint,
       response_digest, track_codes, recorded_by_actor_id)
    values ((select id from workflow.monograph_search_plans where reference = %L),
            1, 'Europe PMC', 'sertralin', now(), 3, 3,
            'executed', 'machine_executed', 'https://example.test',
            'sha256:' || repeat('a', 64),
            array['bibliographic_database', 'systematic_review_search'],
            'ac970000-0000-4000-8000-00000000000a')
  $$, (select value from refs where label = 'eff')),
  '22023',
  null,
  'et Europe PMC-søk kan ikke erklære et oversiktssøk dekket: nøyaktig det prøvene besto på før 013x'
);

select throws_ok(
  format($$
    insert into workflow.monograph_searches
      (plan_id, plan_version, platform, query_string, executed_at, result_count,
       screened_count, outcome, execution_evidence, evidence_endpoint,
       response_digest, track_codes, recorded_by_actor_id)
    values ((select id from workflow.monograph_search_plans where reference = %L),
            1, 'ClinicalTrials.gov', 'sertraline', now(), 3, 3,
            'executed', 'machine_executed', 'https://example.test',
            'sha256:' || repeat('b', 64),
            array['trial_registries'],
            'ac970000-0000-4000-8000-00000000000a')
  $$, (select value from refs where label = 'eff')),
  '22023',
  null,
  'og en søkevei som ikke er registrert, kan ikke dekke et krav ved å bli navngitt'
);

-- ===========================================================================
-- Del 3 — Hver profil: utførbart eller ført, aldri stille ventende
-- ===========================================================================
-- Det er dette spørsmålet ingen prøve stilte. Én plan som kommer fram, sier
-- ingenting om de tolv andre profilene.
select is_empty(
  $$
    select p.id
    from workflow.monograph_search_plans p
    join workflow.monograph_search_track_attempts a on a.plan_id = p.id
    join knowledge.monograph_search_tracks k on k.id = a.track_id
    where a.state = 'pending'
      and not (k.code = any (knowledge.monograph_executable_track_codes()))
  $$,
  'ingen plan har et spor som venter på en maskinell søkevei som ikke finnes'
);

select is_empty(
  $$
    select p.id
    from workflow.monograph_search_plans p
    join workflow.monograph_search_track_attempts a on a.plan_id = p.id
    join knowledge.monograph_search_tracks k on k.id = a.track_id
    where a.state = 'no_machine_path'
      and k.code = any (knowledge.monograph_executable_track_codes())
  $$,
  'og ingen utførbart spor er ført som om det manglet en vei: da ville maskinen sluppet unna arbeid den kan gjøre'
);

select isnt_empty(
  $$
    select distinct sp.code
    from workflow.monograph_search_plans p
    join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
    join workflow.monograph_search_track_attempts a on a.plan_id = p.id
    where a.state = 'no_machine_path'
  $$,
  'og flere profiler har spor som krever et menneske — det er et faktum om Antidep, ikke om prøven'
);

-- Hvert ført spor bærer en begrunnelse, og ingen bærer et menneske ennå.
select is_empty(
  $$
    select a.id from workflow.monograph_search_track_attempts a
    where a.state = 'no_machine_path'
      and (a.note is null or a.resolved_by_actor_id is not null or a.search_id is not null)
  $$,
  'hvert ført spor bærer begrunnelsen sin, og maskinen later ikke som om noen har løst det'
);

-- ===========================================================================
-- Del 4 — Porten navngir sporene framfor å nekte stille
-- ===========================================================================
-- Det ene utførbare sporet dekkes først. Uten det svarer porten på det forrige
-- kravet — «ikke forsøkt ennå» — og prøven ville sagt ingenting om det nye.
insert into workflow.monograph_searches
  (plan_id, plan_version, platform, query_string, executed_at, result_count,
   screened_count, outcome, execution_evidence, evidence_endpoint,
   response_digest, track_codes, recorded_by_actor_id)
values ((select id from workflow.monograph_search_plans
         where reference = (select value from refs where label = 'eff')),
        1, 'Europe PMC', '"sertralin" AND ("depressiv lidelse")', now(), 12, 12,
        'executed', 'machine_executed',
        'https://www.ebi.ac.uk/europepmc/webservices/rest/search',
        'sha256:' || repeat('c', 64),
        array['bibliographic_database'],
        'ac970000-0000-4000-8000-00000000000a');

-- Et direkte innlegg oppdaterer ikke sporet; det gjør bare skriveveien. Her
-- gjelder prøven porten, ikke skriveveien, så sporet føres for hånd.
update workflow.monograph_search_track_attempts a
set state = 'covered',
    search_id = (select s.id from workflow.monograph_searches s
                 where s.plan_id = a.plan_id
                 order by s.registration_ordinal desc limit 1)
where a.plan_id = (select id from workflow.monograph_search_plans
                   where reference = (select value from refs where label = 'eff'))
  and a.track_id = (select k.id from knowledge.monograph_search_tracks k
                    where k.code = 'bibliographic_database'
                    order by k.standard_version desc limit 1);

select alike(
  workflow.monograph_search_closure_problem(
    (select id from workflow.monograph_search_plans
     where reference = (select value from refs where label = 'eff'))),
  '%registrerte søkeveier dekker%',
  'porten sier hvilke obligatoriske spor som mangler en maskinell vei'
);

select alike(
  workflow.monograph_search_closure_problem(
    (select id from workflow.monograph_search_plans
     where reference = (select value from refs where label = 'eff'))),
  '%record_monograph_track_by_editor%',
  'og hva som løser dem: en blindvei uten utgang er ikke en ærlig begrensning'
);

-- ===========================================================================
-- Del 5 — Redaktørens vei ut, og grensene den har
-- ===========================================================================
insert into refs (label, value)
select 'reg', p.reference
from workflow.monograph_search_plans p
join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
where sp.code = 'REG'
order by p.created_at
limit 1;

select set_config('request.jwt.claims',
                  '{"sub":"97000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;

select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'pending',
            'Forsøk på å sette sporet tilbake i den maskinelle køen for hånd.')$$,
         (select value from refs where label = 'eff')),
  '22023',
  null,
  'et spor kan ikke settes tilbake til å vente: registeret avgjør selv om en maskinell vei finnes'
);

select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'unavailable', 'ok')$$,
         (select value from refs where label = 'eff')),
  '22023',
  null,
  'og det krever en begrunnelse, ikke et ord: begrunnelsen er det eneste sporet av hva mennesket gjorde'
);

-- Den regulatoriske planen har ingen søkepassering: ingen av dens tre
-- obligatoriske spor kan dekkes maskinelt, og ingen søkevei har gått for den.
select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'norwegian_authority_source', 'covered',
            'Kontrollert direkte i myndighetskilden, og versjonen er ikke avløst.')$$,
         (select value from refs where label = 'reg')),
  '23001',
  null,
  'et spor kan ikke erklæres dekket på en plan uten en registrert søkepassering å knytte det til'
);

select lives_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'unavailable',
            'Søkt manuelt i ClinicalTrials.gov 2026-09-22. Registeret svarte ikke innenfor tidsrammen.')$$,
         (select value from refs where label = 'eff')),
  'redaktøren kan registrere utfallet av et spor maskinen ikke har en vei til'
);

select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'unavailable',
            'Forsøk på å føre det samme sporet en gang til, etter at det er avklart.')$$,
         (select value from refs where label = 'eff')),
  '23001',
  null,
  'et avklart spor kan ikke føres på nytt: utfallet er ført, og veien er ikke en redigeringsflate'
);

select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'bibliographic_database', 'covered',
            'Forsøk på å overta et spor maskinen allerede dekker.')$$,
         (select value from refs where label = 'eff')),
  '23001',
  null,
  'og et spor maskinen dekker, kan ikke overtas for hånd: ellers var hele den maskinelle fasen valgfri'
);

reset role;

select is(
  (select a.resolved_by_actor_id
   from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   join workflow.monograph_search_plans p on p.id = a.plan_id
   where p.reference = (select value from refs where label = 'eff')
     and k.code = 'trial_registries'),
  'ac970000-0000-4000-8000-00000000000a'::uuid,
  'og raden bærer hvem: «et menneske har håndtert dette» er ikke samme faktum som «en tjeneste svarte ikke»'
);

-- ===========================================================================
-- Del 6 — Og selvhelbredingen: får Antidep en søkevei, overtar maskinen
-- ===========================================================================
insert into knowledge.monograph_search_platforms (platform, track_code)
values ('Europe PMC', 'systematic_review_search');

select is(
  (select workflow.mark_tracks_without_machine_path(
     (select id from workflow.monograph_search_plans
      where reference = (select value from refs where label = 'eff'))) > 0),
  true,
  'en ny registrert søkevei flytter sporet tilbake i den maskinelle køen'
);

select is(
  (select a.state::text
   from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   join workflow.monograph_search_plans p on p.id = a.plan_id
   where p.reference = (select value from refs where label = 'eff')
     and k.code = 'systematic_review_search'),
  'pending',
  'og sporet venter nå på maskinen framfor på et menneske — uten at noen måtte rydde'
);

select * from finish();
rollback;
