-- Migrasjon 013x og 014c — fra kjørerens faktiske evner til porten.
--
-- 860 og 870 følger én plan gjennom forløpet. Denne filen stiller det spørsmålet
-- de to ikke stiller: *kan* kjeden i det hele tatt komme fram, for hver av
-- kildeprofilene Antidep har?
--
-- 013x stilte spørsmålet først, og svaret var at Antidep bare kunne utføre det
-- bibliografiske sporet. Alle andre obligatoriske spor ble ført som
-- `no_machine_path` og ventet på at en redaktør søkte for hånd: i en
-- sertralinbestilling sto hver eneste av de sytti planene fast på et menneske.
-- 014c gjorde registeret til (plattform, metode, spor, profiler), og ga hvert
-- søkespor i standarden en deterministisk søkemetode. Denne filen holder det
-- som et faktum om registeret og ikke som en påstand i dokumentasjonen:
--
--   * registeret er nøyaktig det kjøreren kaller, med sporene hver metode dekker,
--   * ingen av standardens (profil, spor)-par står uten en maskinell vei,
--   * ingen søkevei kan erklære et spor den ikke er registrert for — heller ikke
--     for en profil metoden ikke gjelder,
--   * `no_machine_path` oppstår bare når registeret faktisk mangler veien, og
--     porten navngir sporet og redaktørens vei ut,
--   * redaktørens vei ut finnes fortsatt som et kontrollert unntak,
--   * får registeret en ny vei etter at planene finnes, åpner planene selv en
--     maskinell runde for den, og
--   * REG, PROD og en forskningsprofil kommer helt fram på Antideps egne søk,
--     uten én redaktørregistrert passering.
--
-- SQLSTATE 22023 = invalid_parameter_value, 23001 = restrict_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(47);

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

-- ===========================================================================
-- Del 1 — Registeret er det kjøreren faktisk kan
-- ===========================================================================
-- Den andre halvdelen av denne kontrollen ligger i
-- src/ops/search-methods.test.ts, som leser seedingen i migrasjonen og
-- sammenligner den med SEARCH_METHOD_CATALOG. Her står den siden porten hviler på.
select bag_eq(
  $$select platform, method, track_code, profile_codes
    from knowledge.monograph_search_platforms$$,
  $$values
    ('ClinicalTrials.gov', 'registry_search', 'trial_registries', null::text[]),
    ('ClinPGx', 'guideline_annotations', 'regulatory_or_specialist_guidance', '{PGX}'::text[]),
    ('Crossref', 'keyword', 'bibliographic_database', null::text[]),
    ('Crossref', 'keyword', 'independent_second_database', null::text[]),
    ('Crossref', 'references', 'reference_lists', null::text[]),
    ('DMP FEST', 'product_register', 'all_identified_products', null::text[]),
    ('DMP FEST', 'product_register', 'change_and_shortage_check', null::text[]),
    ('DMP FEST', 'product_register', 'dependent_profile_controls', null::text[]),
    ('DMP FEST', 'product_register', 'norwegian_authority_source', null::text[]),
    ('DMP FEST', 'product_register', 'product_information', null::text[]),
    ('EMA', 'regulatory_data', 'regulatory_or_specialist_guidance', '{SAFE,POP,STOP,TOX}'::text[]),
    ('Europe PMC', 'citations', 'citing_works', null::text[]),
    ('Europe PMC', 'keyword', 'bibliographic_database', null::text[]),
    ('Europe PMC', 'references', 'reference_lists', null::text[]),
    ('Europe PMC', 'systematic_review_filter', 'systematic_review_search', null::text[]),
    ('PubMed', 'guideline_filter', 'regulatory_or_specialist_guidance', null::text[]),
    ('PubMed', 'human_primary_filter', 'human_primary_studies', null::text[]),
    ('PubMed', 'keyword', 'bibliographic_database', null::text[]),
    ('PubMed', 'observational_filter', 'observational_safety_search', null::text[]),
    ('PubMed', 'systematic_review_filter', 'systematic_review_search', null::text[]),
    ('PubMed', 'update_window', 'update_search', null::text[])$$,
  'registeret er nøyaktig søkemetodene Antidep kaller, med sporene og profilene hver av dem dekker'
);

select is(
  knowledge.monograph_executable_track_codes(),
  array['all_identified_products', 'bibliographic_database', 'change_and_shortage_check',
        'citing_works', 'dependent_profile_controls', 'human_primary_studies',
        'independent_second_database', 'norwegian_authority_source',
        'observational_safety_search', 'product_information', 'reference_lists',
        'regulatory_or_specialist_guidance', 'systematic_review_search',
        'trial_registries', 'update_search'],
  'de utførbare sporene er utledet av registeret: hvert søkespor i standarden'
);

select is(
  knowledge.monograph_answer_control_track_codes(),
  array['reuse_validity_check'],
  'og det ene sporet som ikke er et søk, er ført som svarkontrollen det er'
);

-- Regresjonen oppgaven ble gitt: antallet (profil, spor)-par i standarden som
-- står uten en maskinell vei. Før 014c var det 38 av 48: bare det
-- bibliografiske sporet, i ti av profilene, hadde en vei.
select is(
  (select count(*)::integer
   from knowledge.monograph_search_track_profiles kp
   join knowledge.monograph_search_tracks k on k.id = kp.track_id
   where not (k.code = any (knowledge.monograph_machine_track_codes(kp.profile_id)))
     and not (k.code = any (knowledge.monograph_answer_control_track_codes()))),
  0,
  'ingen (profil, spor)-par i standarden står uten en maskinell søkevei'
);
select is(
  (select count(*)::integer
   from knowledge.monograph_search_track_profiles kp
   join knowledge.monograph_search_tracks k on k.id = kp.track_id
   where k.code = any (knowledge.monograph_machine_track_codes(kp.profile_id))),
  47,
  'og 47 av standardens 48 par har en søkemetode Antideps kode utfører'
);

select is_empty(
  $$select platform, method from knowledge.monograph_search_methods
    where endpoint_base !~ '^https://' or btrim(coalesce(terms_note, '')) = ''
       or btrim(coalesce(coverage_note, '')) = ''$$,
  'hver søkemetode har en fast https-adresse, bruksvilkårene den hviler på og hva den ikke dekker'
);

select is_empty(
  $$select platform, method from knowledge.monograph_search_methods
    where requires_seeds <> (cardinality(seed_identifier_kinds) > 0)
       or (requires_seeds and default_for_requests)$$,
  'bare metodene som følger kilder tar imot kilder, og ingen av dem er et standardsøk'
);

-- ===========================================================================
-- Del 2 — Registeret som får en ny vei etter at planene finnes
-- ===========================================================================
-- Slik 014c selv kom: bestillingen er lagt inn før registeret kjente
-- observasjonsfilteret. Her tas det bort før bestillingen og legges til etter.
delete from knowledge.monograph_search_platforms
where platform = 'PubMed' and method = 'observational_filter'
  and track_code = 'observational_safety_search';

select set_config('request.jwt.claims',
                  '{"sub":"97000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 970.');
reset role;

insert into refs (label, value)
select 'p_' || lower(sp.code), p.reference
from (select distinct on (profile_id) id, profile_id, reference
      from workflow.monograph_search_plans order by profile_id, created_at) p
join knowledge.monograph_source_profiles sp on sp.id = p.profile_id;

select is(
  (select a.state::text
   from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   join workflow.monograph_search_plans p on p.id = a.plan_id
   where p.reference = (select value from refs where label = 'p_pop')
     and k.code = 'observational_safety_search'),
  'no_machine_path',
  'et spor registeret ikke har en vei til, føres med én gang som det'
);
select is_empty(
  $$select r.id from workflow.monograph_search_requests r
    where 'observational_safety_search' = any (r.track_codes)$$,
  'og ingen runde later som om den kan utføre det'
);

-- En migrasjon som gir registeret en ny vei, kaller denne funksjonen for de
-- åpne planene (slik 014e gjør).
insert into knowledge.monograph_search_platforms (platform, method, track_code)
values ('PubMed', 'observational_filter', 'observational_safety_search');

select is(
  (select sum(workflow.mark_tracks_without_machine_path(p.id))::integer > 0
   from workflow.monograph_search_plans p
   where p.closed_at is null),
  true,
  'den nye søkeveien flytter sporet tilbake i den maskinelle køen'
);
select is(
  (select a.state::text
   from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   join workflow.monograph_search_plans p on p.id = a.plan_id
   where p.reference = (select value from refs where label = 'p_pop')
     and k.code = 'observational_safety_search'),
  'pending',
  'og sporet venter nå på maskinen framfor på et menneske — uten at noen måtte rydde'
);
select is(
  (select array_agg(r.platform || '|' || r.method || '|' || array_to_string(r.track_codes, ','))
   from workflow.monograph_search_requests r
   join workflow.monograph_search_plans p on p.id = r.plan_id
   where p.reference = (select value from refs where label = 'p_pop')
     and r.origin = 'registry_opened' and r.state = 'pending'),
  array['PubMed|observational_filter|observational_safety_search'],
  'og planen åpnet selv runden som utfører det: et utførbart spor venter aldri på at noen husker det'
);

-- ===========================================================================
-- Del 3 — Ingen søkevei kan erklære et spor den ikke er registrert for
-- ===========================================================================
select throws_ok(
  format($$
    insert into workflow.monograph_searches
      (plan_id, plan_version, platform, search_method, query_string, executed_at,
       result_count, screened_count, outcome, execution_evidence, evidence_endpoint,
       response_digest, track_codes, recorded_by_actor_id)
    values ((select id from workflow.monograph_search_plans where reference = %L),
            1, 'Europe PMC', 'keyword', 'sertralin', now(), 3, 3,
            'executed', 'machine_executed', 'https://example.test',
            'sha256:' || repeat('a', 64),
            array['bibliographic_database', 'systematic_review_search'],
            'ac970000-0000-4000-8000-00000000000a')
  $$, (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'et fritekstsøk kan ikke erklære et oversiktssøk dekket: det er en annen metode'
);

select throws_ok(
  format($$
    insert into workflow.monograph_searches
      (plan_id, plan_version, platform, search_method, query_string, executed_at,
       result_count, screened_count, outcome, execution_evidence, evidence_endpoint,
       response_digest, track_codes, recorded_by_actor_id)
    values ((select id from workflow.monograph_search_plans where reference = %L),
            1, 'ClinicalTrials.gov', 'registry_search', 'sertraline', now(), 3, 3,
            'executed', 'machine_executed', 'https://example.test',
            'sha256:' || repeat('b', 64),
            array['bibliographic_database'],
            'ac970000-0000-4000-8000-00000000000a')
  $$, (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'et forsøksregister kan ikke dekke det bibliografiske sporet ved å bli navngitt'
);

select throws_ok(
  format($$
    insert into workflow.monograph_searches
      (plan_id, plan_version, platform, search_method, query_string, executed_at,
       result_count, screened_count, outcome, execution_evidence, evidence_endpoint,
       response_digest, track_codes, recorded_by_actor_id)
    values ((select id from workflow.monograph_search_plans where reference = %L),
            1, 'EMA', 'regulatory_data', 'sertraline', now(), 2, 2,
            'executed', 'machine_executed', 'https://example.test',
            'sha256:' || repeat('b', 64),
            array['regulatory_or_specialist_guidance'],
            'ac970000-0000-4000-8000-00000000000a')
  $$, (select value from refs where label = 'p_tdm')),
  '22023',
  null,
  'og EMAs sikkerhetsdata dekker ikke veiledningssporet for en profil de ikke svarer på'
);

select throws_ok(
  format($$
    insert into workflow.monograph_searches
      (plan_id, plan_version, platform, query_string, executed_at, result_count,
       screened_count, outcome, execution_evidence, evidence_endpoint,
       response_digest, track_codes, recorded_by_actor_id)
    values ((select id from workflow.monograph_search_plans where reference = %L),
            1, 'PubMed', 'sertralin', now(), 3, 3,
            'executed', 'machine_executed', 'https://example.test',
            'sha256:' || repeat('c', 64),
            array['bibliographic_database'],
            'ac970000-0000-4000-8000-00000000000a')
  $$, (select value from refs where label = 'p_eff')),
  '22023',
  'Et maskinelt utført søk må si hvilken søkemetode det brukte.',
  'et nytt maskinelt søk må si hvilken metode det brukte: plattformen alene sier ikke hva som ble søkt'
);

select throws_ok(
  format($$
    insert into workflow.monograph_searches
      (plan_id, plan_version, platform, search_method, query_string, executed_at,
       result_count, screened_count, outcome, execution_evidence, evidence_endpoint,
       response_digest, track_codes, recorded_by_actor_id)
    values ((select id from workflow.monograph_search_plans where reference = %L),
            1, 'PubMed', 'everything_filter', 'sertralin', now(), 3, 3,
            'executed', 'machine_executed', 'https://example.test',
            'sha256:' || repeat('d', 64),
            array['bibliographic_database'],
            'ac970000-0000-4000-8000-00000000000a')
  $$, (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'og en metode registeret ikke kjenner, kan ikke dekke noe'
);

select throws_ok(
  format($$
    insert into workflow.monograph_search_requests
      (plan_id, plan_version, requested_for_role, search_round, origin, strategy,
       rationale, platform, method, requested_by_actor_id)
    values ((select id from workflow.monograph_search_plans where reference = %L),
            1, 'source_discovery', 2, 'agent_requested', 'targeted',
            'Prøve i 970.', 'PubMed', 'everything_filter',
            'ac970000-0000-4000-8000-00000000000a')
  $$, (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'en søkeforespørsel kan heller ikke be om en metode registeret ikke kjenner'
);

-- ===========================================================================
-- Del 4 — Hver profil: utførbart, og med en runde som utfører det
-- ===========================================================================
select is_empty(
  $$
    select p.id, k.code
    from workflow.monograph_search_plans p
    join workflow.monograph_search_track_attempts a on a.plan_id = p.id
    join knowledge.monograph_search_tracks k on k.id = a.track_id
    where a.state = 'no_machine_path'
  $$,
  'ingen spor i en ny sertralinbestilling står og venter på et menneske'
);

select is_empty(
  $$
    select p.id, k.code
    from workflow.monograph_search_plans p
    join workflow.monograph_search_track_attempts a on a.plan_id = p.id
    join knowledge.monograph_search_tracks k on k.id = a.track_id
    where a.state = 'pending'
      and not (k.code = any (knowledge.monograph_machine_track_codes(p.profile_id)))
  $$,
  'ingen plan har et spor som venter på en maskinell søkevei som ikke finnes for profilen'
);

-- Et ventende spor uten en runde som utfører det, venter for alltid. Sporene
-- som følger kilder, venter på at kildeoppdagelsen velger kildene: de åpnes
-- når valget er registrert (870).
select is_empty(
  $$
    select p.id, k.code
    from workflow.monograph_search_plans p
    join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
    join workflow.monograph_search_track_attempts a on a.plan_id = p.id
    join knowledge.monograph_search_tracks k on k.id = a.track_id
    where a.state = 'pending'
      and exists (
        select 1
        from knowledge.monograph_search_platforms c
        join knowledge.monograph_search_methods m
          on m.platform = c.platform and m.method = c.method
        where c.track_code = k.code and not m.requires_seeds
          and (c.profile_codes is null or sp.code = any (c.profile_codes)))
      and not exists (
        select 1 from workflow.monograph_search_requests r
        where r.plan_id = p.id and r.state = 'pending' and k.code = any (r.track_codes))
  $$,
  'hvert ventende søkespor som ikke følger kilder, har allerede en åpen maskinell runde'
);

select is_empty(
  $$
    select p.id
    from workflow.monograph_search_plans p
    join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
    where sp.code = 'SYN'
  $$,
  'sammendragsleddet får ingen søkeplan: det gjør ingen selvstendig litteraturjakt (§4.2)'
);

select matches(
  workflow.monograph_track_note(
    'reuse_validity_check',
    (select id from knowledge.monograph_source_profiles where code = 'SYN')),
  'derivation_basis',
  'og dets ene spor er svarkontrollen som utføres hver gang et avledet svar registreres'
);

-- ===========================================================================
-- Del 5 — no_machine_path oppstår bare når registeret mangler veien
-- ===========================================================================
-- Registeret mister forsøksregisteret (i denne transaksjonen). Da, og bare da,
-- står sporet uten en maskinell vei.
delete from knowledge.monograph_search_platforms
where platform = 'ClinicalTrials.gov' and method = 'registry_search'
  and track_code = 'trial_registries';

select is(
  (select workflow.mark_tracks_without_machine_path(
     (select id from workflow.monograph_search_plans
      where reference = (select value from refs where label = 'p_eff'))) > 0),
  true,
  'et spor registeret ikke lenger har en vei til, føres som det'
);

select is(
  (select array_agg(k.code order by k.code)
   from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   join workflow.monograph_search_plans p on p.id = a.plan_id
   where p.reference = (select value from refs where label = 'p_eff')
     and a.state = 'no_machine_path'),
  array['trial_registries'],
  'og nøyaktig det sporet: de andre har fortsatt sin vei'
);

select is_empty(
  $$
    select a.id from workflow.monograph_search_track_attempts a
    where a.state = 'no_machine_path'
      and (a.note not like 'Ingen av Antideps registrerte søkemetoder%'
           or a.resolved_by_actor_id is not null or a.search_id is not null)
  $$,
  'det førte sporet bærer begrunnelsen sin, og maskinen later ikke som om noen har løst det'
);

-- De utførbare sporene dekkes først. Uten det svarer porten på det forrige
-- kravet — «ikke forsøkt ennå» — og prøven ville sagt ingenting om det nye.
insert into workflow.monograph_searches
  (plan_id, plan_version, platform, search_method, query_string, executed_at,
   result_count, screened_count, outcome, execution_evidence, evidence_endpoint,
   response_digest, track_codes, recorded_by_actor_id)
values ((select id from workflow.monograph_search_plans
         where reference = (select value from refs where label = 'p_eff')),
        1, 'Europe PMC', 'keyword', '"sertralin" AND ("depressiv lidelse")', now(), 12, 12,
        'executed', 'machine_executed',
        'https://www.ebi.ac.uk/europepmc/webservices/rest/search',
        'sha256:' || repeat('c', 64),
        array['bibliographic_database'],
        'ac970000-0000-4000-8000-00000000000a');

-- Et direkte innlegg oppdaterer ikke sporene; det gjør bare skriveveien. Her
-- gjelder prøven porten, ikke skriveveien, så sporene føres for hånd.
update workflow.monograph_search_track_attempts a
set state = 'covered',
    search_id = (select s.id from workflow.monograph_searches s
                 where s.plan_id = a.plan_id
                 order by s.registration_ordinal desc limit 1)
where a.plan_id = (select id from workflow.monograph_search_plans
                   where reference = (select value from refs where label = 'p_eff'))
  and a.state = 'pending';

select alike(
  workflow.monograph_search_closure_problem(
    (select id from workflow.monograph_search_plans
     where reference = (select value from refs where label = 'p_eff'))),
  '%registrerte søkeveier dekker%Forsøksregistre%',
  'porten sier hvilket obligatorisk spor som mangler en maskinell vei'
);

select alike(
  workflow.monograph_search_closure_problem(
    (select id from workflow.monograph_search_plans
     where reference = (select value from refs where label = 'p_eff'))),
  '%record_monograph_track_by_editor%',
  'og hva som løser det: en blindvei uten utgang er ikke en ærlig begrensning'
);

-- ===========================================================================
-- Del 6 — Redaktørens vei ut er et kontrollert unntak, og dokumenterer søket
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"97000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;

select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'pending',
            'Forsøk på å sette sporet tilbake i den maskinelle køen for hånd.')$$,
         (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'et spor kan ikke settes tilbake til å vente: registeret avgjør selv om en maskinell vei finnes'
);

select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'unavailable', 'ok')$$,
         (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'og det krever en begrunnelse, ikke et ord: begrunnelsen er det eneste sporet av hva mennesket gjorde'
);

-- De fire opplysningene SOURCE_POLICY.md §4.3 krever om et utført søk.
select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'covered',
            'Søkt manuelt i forsøksregisteret; treffene er gjennomgått.',
            null, '"sertralin"', null, now() - interval '1 hour', 4, 4, false, null)$$,
         (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'et dekket spor kan ikke registreres uten søkeveien passeringen gikk mot'
);
select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'covered',
            'Søkt manuelt i forsøksregisteret; treffene er gjennomgått.',
            'ClinicalTrials.gov', null, null, now() - interval '1 hour', 4, 4, false, null)$$,
         (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'og ikke uten den eksakte søkestrengen: en beskrivelse av et søk er ikke et søk'
);
select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'covered',
            'Søkt manuelt i forsøksregisteret; treffene er gjennomgått.',
            'ClinicalTrials.gov', '"sertralin"', null, now() + interval '1 day', 4, 4, false, null)$$,
         (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'og ikke med et tidspunkt i framtiden: det er ikke et utført søk'
);
select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'covered',
            'Søkt manuelt i forsøksregisteret; treffene er gjennomgått.',
            'ClinicalTrials.gov', '"sertralin"', null, now() - interval '1 hour', null, 4, false, null)$$,
         (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'og ikke uten treffantall: null treff er 0, og ingen verdi er ikke null treff'
);

-- En passering med treff må enten gi kandidatene den fant, eller si hva
-- gjennomgangen ga. Ellers er treffene sett av én person og forsvunnet.
select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'covered',
            'Søkt manuelt i ClinicalTrials.gov 2026-09-22; de fire treffene er gjennomgått.',
            'ClinicalTrials.gov', 'sertraline AND depressive disorder', 'status=all',
            now() - interval '1 hour', 4, 4, false, null, null, null)$$,
         (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'fire treff og fire gjennomgått uten én kandidat og uten et ord om hvorfor, avvises'
);

select lives_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'trial_registries', 'covered',
            'Søkt manuelt i ClinicalTrials.gov 2026-09-22; de fire treffene er gjennomgått.',
            'ClinicalTrials.gov', 'sertraline AND depressive disorder', 'status=all',
            now() - interval '1 hour', 4, 4, false, null,
            jsonb_build_array(jsonb_build_object(
              'identifier_kind', 'registry_id',
              'identifier_value', 'NCT00970-01',
              'title', 'Uavsluttet forsøk med sertralin ved depressiv lidelse (prøve 970)',
              'could_change_conclusion', true,
              'materiality_reason', 'Et uavsluttet forsøk kan endre bildet av effektstørrelsen.')),
            null)$$,
         (select value from refs where label = 'p_eff')),
  'redaktøren kan registrere passeringen som faktisk ble gjort, med kildene den ga'
);

select throws_ok(
  format($$select api.record_monograph_track_by_editor(%L, 'systematic_review_search', 'covered',
            'Forsøk på å overta et spor maskinen har en vei til.',
            'Epistemonikos', '"sertralin"', null, now() - interval '1 hour', 2, 2, false, null)$$,
         (select value from refs where label = 'p_tox')),
  '23001',
  null,
  'og et spor maskinen har en vei til, kan ikke overtas for hånd: ellers var hele den maskinelle fasen valgfri'
);

reset role;

select is(
  (select count(*)::integer
   from workflow.monograph_candidate_sources c
   join workflow.monograph_searches s on s.id = c.search_id
   join workflow.monograph_search_plans p on p.id = c.plan_id
   where p.reference = (select value from refs where label = 'p_eff')
     and s.execution_evidence = 'editor_recorded'),
  1,
  'og treffet er bundet til nøyaktig den passeringen, ikke til et maskinelt søk'
);

select is(
  (select array[s.platform, s.execution_evidence::text, s.evidence_endpoint, s.response_digest,
                array_to_string(s.track_codes, ',')]
   from workflow.monograph_search_track_attempts a
   join workflow.monograph_searches s on s.id = a.search_id
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   join workflow.monograph_search_plans p on p.id = a.plan_id
   where p.reference = (select value from refs where label = 'p_eff')
     and k.code = 'trial_registries'),
  array['ClinicalTrials.gov', 'editor_recorded', null, null, 'trial_registries'],
  'sporet peker på passeringen som gjaldt det, og raden er et menneskes dokumenterte arbeid'
);

select is(
  (select a.resolved_by_actor_id
   from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   join workflow.monograph_search_plans p on p.id = a.plan_id
   where p.reference = (select value from refs where label = 'p_eff')
     and k.code = 'trial_registries'),
  'ac970000-0000-4000-8000-00000000000a'::uuid,
  'og raden bærer hvem: «et menneske har håndtert dette» er ikke samme faktum som «en tjeneste svarte ikke»'
);

-- En agent kan ikke skrive et slikt søk. Uten grensen hadde editor_recorded
-- vært en vei til å erklære et søk uten hverken kjøring eller endepunkt.
select throws_ok(
  format($$
    insert into workflow.monograph_searches
      (plan_id, plan_version, platform, query_string, executed_at, result_count,
       screened_count, outcome, execution_evidence, track_codes, recorded_by_actor_id)
    values ((select id from workflow.monograph_search_plans where reference = %L),
            1, 'Epistemonikos', 'sertralin', now(), 2, 2, 'executed',
            'editor_recorded', array['citing_works'],
            (select id from provenance.actors where actor_type = 'agent' limit 1))
  $$, (select value from refs where label = 'p_eff')),
  '22023',
  null,
  'en agent kan ikke registrere en menneskelig søkepassering'
);

-- ===========================================================================
-- Del 7 — Og hele veien fram, uten et menneske
-- ===========================================================================
-- REG og PROD var profilene som ikke hadde ett eneste utførbart spor. Nå
-- dekkes alle tre sporene deres av ett oppslag i FEST, Direktoratet for
-- medisinske produkters eget register. SAFE dekkes av fritekstsøkene, PubMeds
-- oversikts- og observasjonsfiltre og EMAs sikkerhetsdata.
create temporary table maskinsok (profile text, platform text, method text,
                                  endpoint text, tracks text[]) on commit drop;
insert into maskinsok values
  ('REG', 'DMP FEST', 'product_register',
   'https://www.dmp.no/globalassets/documents/om-oss/distribusjon-av-legemiddeldata/fest/festfiler/fest251.zip',
   array['norwegian_authority_source', 'all_identified_products', 'change_and_shortage_check']),
  ('PROD', 'DMP FEST', 'product_register',
   'https://www.dmp.no/globalassets/documents/om-oss/distribusjon-av-legemiddeldata/fest/festfiler/fest251.zip',
   array['norwegian_authority_source', 'all_identified_products', 'change_and_shortage_check']),
  ('SAFE', 'Europe PMC', 'keyword',
   'https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=sertraline',
   array['bibliographic_database']),
  ('SAFE', 'PubMed', 'keyword',
   'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=sertraline',
   array['bibliographic_database']),
  ('SAFE', 'PubMed', 'systematic_review_filter',
   'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=sertraline+AND+systematic%5Bsb%5D',
   array['systematic_review_search']),
  ('SAFE', 'PubMed', 'observational_filter',
   'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=sertraline+AND+cohort',
   array['observational_safety_search']),
  ('SAFE', 'EMA', 'regulatory_data',
   'https://www.ema.europa.eu/en/documents/report/medicines-output-periodic-safety-update-report-single-assessments-output_en.json',
   array['regulatory_or_specialist_guidance']);

select lives_ok(
  $$
    select workflow.record_monograph_search(
      p.id, m.platform, 'sertraline (' || m.method || ')', null, now(), 4, 4, false, null,
      'executed', null, 'machine_executed', m.endpoint,
      'sha256:' || repeat('e', 64), m.tracks, null,
      'ac970000-0000-4000-8000-00000000000a', null, m.method)
    from maskinsok m
    join refs r on r.label = 'p_' || lower(m.profile)
    join workflow.monograph_search_plans p on p.reference = r.value
  $$,
  'hvert av søkene registreres gjennom skriveveien, med metoden det brukte'
);

-- Den separate dekningskontrollen er det normale siste steget.
do $$
declare v_plan record;
begin
  for v_plan in
    select p.id from refs ref
    join workflow.monograph_search_plans p on p.reference = ref.value
    where ref.label in ('p_reg', 'p_prod', 'p_safe')
  loop
    perform workflow.record_monograph_coverage_control(
      v_plan.id, 'accepted',
      'Prøve i 970: dekningen er kontrollert separat og begrunnelsen for å stoppe godtas.',
      true, 0, 0, true, null, 'ac970000-0000-4000-8000-00000000000a');
  end loop;
end $$;

select is(
  workflow.monograph_search_closure_problem(
    (select p.id from workflow.monograph_search_plans p
     where p.reference = (select value from refs where label = 'p_reg'))),
  null,
  'REG kommer helt fram på Antideps eget oppslag i FEST'
);
select is(
  workflow.monograph_search_closure_problem(
    (select p.id from workflow.monograph_search_plans p
     where p.reference = (select value from refs where label = 'p_prod'))),
  null,
  'PROD kommer helt fram'
);
select is(
  workflow.monograph_search_closure_problem(
    (select p.id from workflow.monograph_search_plans p
     where p.reference = (select value from refs where label = 'p_safe'))),
  null,
  'og en forskningsprofil kommer fram på maskinens søk alene'
);

-- Og ingen av dem kom fram på noe oppdiktet eller på et menneske: hvert dekket
-- spor peker på Antideps eget kall med en metode registeret har for sporet og
-- profilen.
select is_empty(
  $$
    select a.id
    from refs r
    join workflow.monograph_search_plans p on p.reference = r.value
    join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
    join workflow.monograph_search_track_attempts a on a.plan_id = p.id
    join knowledge.monograph_search_tracks k on k.id = a.track_id
    left join workflow.monograph_searches s on s.id = a.search_id
    where r.label in ('p_reg', 'p_prod', 'p_safe')
      and (a.state <> 'covered'
           or s.execution_evidence is distinct from 'machine_executed'
           or not exists (
             select 1 from knowledge.monograph_search_platforms c
             where c.platform = s.platform and c.method = s.search_method
               and c.track_code = k.code
               and (c.profile_codes is null or sp.code = any (c.profile_codes))))
  $$,
  'hvert spor er dekket av et maskinelt søk med en metode registeret har for sporet og profilen'
);
select is_empty(
  $$
    select s.id
    from refs r
    join workflow.monograph_search_plans p on p.reference = r.value
    join workflow.monograph_searches s on s.plan_id = p.id
    where r.label in ('p_reg', 'p_prod', 'p_safe')
      and s.execution_evidence = 'editor_recorded'
  $$,
  'og ingen av de tre planene har én redaktørregistrert passering'
);

select * from finish();
rollback;
