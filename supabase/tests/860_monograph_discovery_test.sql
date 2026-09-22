-- Migrasjon 013e — søkeplanen, søkeloggen og den separate kontrollen av
-- søkedekningen.
--
-- Filen dekker den delen av fase C som gjør kildeoppdagelsen til en utført
-- operasjon framfor til et rollenavn i en prompt:
--
--   * planene bygges av behovene og grupperes på kildeprofil og avgrensning,
--     slik at ett søk kan dekke flere behov,
--   * hvert obligatorisk søkespor opprettes som «ikke forsøkt», og et spor som
--     ikke er forsøkt hindrer at dekningen kan erklæres ferdig,
--   * et maskinelt utført søk krever kildeleddets egen identitet, legitimasjon
--     og en åpen kjøring, og bare den veien kan sette utførelsesbeviset til
--     maskinelt bekreftet,
--   * en utilgjengelig søkevei kan ikke bære et treffantall, og et kontrollert
--     nullsøk kan ikke være avkortet,
--   * en avkortet treffliste som ikke er fulgt opp, hindrer avslutning,
--   * en betalingsmur er en tilgangsbegrensning og ikke en eksklusjonsgrunn,
--   * en uavklart kilde som kan endre hovedkonklusjonen, hindrer avslutning,
--   * en godtatt dekningskontroll krever at kontrollen søkte selv og vurderte
--     vesentligheten — den kan godt kjøre den samme modellen som søkte, men da
--     i sin egen runde som sitt eget agentledd (migrasjon 013t),
--   * et oppbrukt arbeidsbudsjett setter planen på pause og lukker den aldri, og
--   * når alle kravene er oppfylt, kan dekningen erklæres ferdig — og behovene
--     går videre til kildevurdering.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23505 = unique_violation,
-- 23514 = check_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(69);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('workflow', 'monograph_search_plans',
                 'workflow.monograph_search_plans finnes');
select has_table('workflow', 'monograph_searches', 'workflow.monograph_searches finnes');
select has_table('workflow', 'monograph_search_track_attempts',
                 'workflow.monograph_search_track_attempts finnes');
select has_table('workflow', 'monograph_candidate_sources',
                 'workflow.monograph_candidate_sources finnes');
select has_table('workflow', 'monograph_coverage_controls',
                 'workflow.monograph_coverage_controls finnes');
select has_function('workflow', 'monograph_search_closure_problem',
                    'workflow.monograph_search_closure_problem(uuid) finnes');

select is_empty(
  $$
    select t.table_name, r.role_name, p.privilege
    from (values ('workflow.monograph_search_plans'),
                 ('workflow.monograph_searches'),
                 ('workflow.monograph_search_track_attempts'),
                 ('workflow.monograph_candidate_sources'),
                 ('workflow.monograph_coverage_controls')) as t(table_name),
         (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, t.table_name, p.privilege)
  $$,
  'ingen klientrolle kan lese eller skrive i søkeloggen direkte'
);

-- De to kildeleddene har hver sin registreringstildeling, og de deler ikke
-- modellidentitet med noe annet ledd.
select is(
  (select count(*)::integer from provenance.role_model_assignments
   where valid_to is null
     and agent_role in ('source_discovery', 'source_quality_assessment')),
  2,
  'kildeoppdagelsen og dekningskontrollen har hver sin registreringstildeling'
);

-- ===========================================================================
-- Del 2 — Kontoene og bestillingen
-- ===========================================================================
insert into auth.users (id, email)
values ('86000000-0000-4000-8000-00000000000a', 'redaktor-860@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac860000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-860',
   'Redaktør 860',
   'Editor uten avgrensning, for prøven av søkeplanen og søkeloggen i 860.',
   '86000000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('86000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
   'ac860000-0000-4000-8000-00000000000a', 'Editor-tildeling for 860.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table refs (label text primary key, value text not null) on commit drop;
create temporary table cred (label text primary key, secret text not null) on commit drop;
grant select, insert on svar to anon, authenticated;
grant select on refs, cred to anon, authenticated;

select set_config('request.jwt.claims',
                  '{"sub":"86000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 860.');
reset role;

insert into refs (label, value)
select 'utgave', payload ->> 'reference' from svar where label = 'bestilling';

-- ===========================================================================
-- Del 3 — Planene bygges av behovene, og grupperes på profil og avgrensning
-- ===========================================================================
select cmp_ok(
  (select count(*)::integer from workflow.monograph_search_plans),
  '>', 0,
  'bestillingen bygget søkeplaner av behovene'
);
select cmp_ok(
  (select count(*)::integer from workflow.monograph_search_plans),
  '<', (select count(*)::integer from knowledge.monograph_needs),
  'planene er færre enn behovene: 80 spørsmålsmaler er ikke 80 litteratursøk'
);
select isnt_empty(
  $$
    select p.id
    from workflow.monograph_search_plans p
    where (select count(*) from workflow.monograph_search_plan_needs pn
           where pn.plan_id = p.id) > 1
  $$,
  'minst én plan dekker flere behov: ett søk kan dekke flere spørsmål'
);
select is_empty(
  $$
    select p.id
    from workflow.monograph_search_plans p
    where not exists (
      select 1 from workflow.monograph_search_track_attempts a where a.plan_id = p.id
    )
  $$,
  'hver plan har sine obligatoriske søkespor'
);
-- Ingen spor er dekket eller begrenset før noe er gjort. Men et spor ingen
-- registrert søkevei dekker, står som det fra første stund framfor å si «ikke
-- forsøkt ennå» om noe som aldri blir forsøkt maskinelt (migrasjon 013x).
select is_empty(
  $$
    select a.id from workflow.monograph_search_track_attempts a
    where a.state not in ('pending', 'no_machine_path')
  $$,
  'ingen spor er dekket eller begrenset før noe er gjort'
);
select is_empty(
  $$
    select a.id
    from workflow.monograph_search_track_attempts a
    join knowledge.monograph_search_tracks k on k.id = a.track_id
    where a.state = 'pending'
      and not (k.code = any (knowledge.monograph_executable_track_codes()))
  $$,
  'og ingen spor venter på en maskinell søkevei som ikke finnes'
);

-- Behov med uavklart relevans får ingen plan. De forsvinner ikke: de står som
-- uavklarte i dekningen.
select is_empty(
  $$
    select n.id
    from knowledge.monograph_needs n
    join workflow.monograph_search_plan_needs pn on pn.need_id = n.id
    where n.relevance <> 'relevant'
  $$,
  'et behov med uavklart relevans setter ikke i gang et søk'
);
select cmp_ok(
  (select count(*)::integer from knowledge.monograph_needs where relevance = 'undetermined'),
  '>', 0,
  'og de uavklarte behovene finnes fortsatt'
);

-- ===========================================================================
-- Del 4 — En EFF-plan: den vi følger gjennom hele veien
-- ===========================================================================
create temporary table plans (label text primary key, id uuid not null) on commit drop;
insert into plans (label, id)
select 'eff', p.id
from workflow.monograph_search_plans p
join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
where sp.code = 'EFF'
order by p.created_at
limit 1;
insert into plans (label, id)
select 'reg', p.id
from workflow.monograph_search_plans p
join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
where sp.code = 'REG'
order by p.created_at
limit 1;

insert into refs (label, value)
select 'eff', p.reference from workflow.monograph_search_plans p
where p.id = (select id from plans where label = 'eff');

-- Migrasjon 013v: planen åpner sin egen maskinelle søkerunde, og et søk hører
-- til nøyaktig én runde. Uten koblingen ville runden aldri blitt lukket, og den
-- semantiske vurderingsoppgaven ville aldri blitt lagt i køen.
insert into refs (label, value)
select 'eff_runde', r.reference from workflow.monograph_search_requests r
where r.plan_id = (select id from plans where label = 'eff')
  and r.requested_for_role = 'source_discovery'
  and r.state = 'pending';

select matches(
  workflow.monograph_search_closure_problem((select id from plans where label = 'eff')),
  'ikke forsøkt ennå',
  'et spor som ikke er forsøkt, hindrer at søkedekningen kan erklæres ferdig'
);

-- ===========================================================================
-- Del 5 — Det maskinelt utførte søket
-- ===========================================================================
insert into cred (label, secret)
select 'discovery', provenance.issue_agent_identity_credential(
  'agent-identity:source-discovery-01', 'human:peder-holman');
insert into cred (label, secret)
select 'control', provenance.issue_agent_identity_credential(
  'agent-identity:source-quality-assessment-01', 'human:peder-holman');

-- Uten legitimasjon kommer ingen til arbeidet.
set local role anon;
select throws_ok(
  $$ select api.monograph_discovery_work('agent-identity:source-discovery-01', 'feil') $$,
  '42501',
  null,
  'søkearbeidet hentes ikke ut uten gyldig legitimasjon'
);
select throws_ok(
  $$ select api.monograph_discovery_work('agent-identity:evidence-extraction-01', 'hva som helst') $$,
  '42501',
  'Søkearbeidet hentes bare av kildeleddene.',
  'og ikke av en identitet i et annet agentledd'
);
reset role;

create temporary table runs (label text primary key, id uuid not null) on commit drop;
grant select, insert on runs to anon, authenticated;

set local role anon;
insert into svar (label, payload)
select 'arbeid', api.monograph_discovery_work(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'));
reset role;

select cmp_ok(
  (select jsonb_array_length(payload -> 'plans') from svar where label = 'arbeid'),
  '>', 0,
  'kildeoppdagelsen får de åpne søkeplanene'
);
select ok(
  (select bool_and(plan ? 'closure_problem' and plan ? 'tracks' and plan ? 'needs')
   from svar, jsonb_array_elements(payload -> 'plans') as plan
   where label = 'arbeid'),
  'oppgaven bærer stoppkravene, søkesporene og behovene'
);
-- Oppgaven bærer spørsmålene og ikke et forventet svar.
select ok(
  (select bool_and(need ? 'question' and not (need ? 'expected_answer'))
   from svar,
        jsonb_array_elements(payload -> 'plans') as plan,
        jsonb_array_elements(plan -> 'needs') as need
   where label = 'arbeid'),
  'behovene i oppgaven bærer spørsmålet, og ingen forventet klinisk konklusjon'
);

set local role anon;
insert into runs (label, id)
select 'discovery', api.begin_agent_run(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  'source_discovery', 'antidep', 'search-execution-and-registration', '1.0.0',
  'source-discovery/machine-search/1', 'antidep-evidence/1',
  jsonb_build_object('plan_reference', (select value from refs where label = 'eff')));
reset role;

select isnt(
  (select id from runs where label = 'discovery'),
  null,
  'kildeoppdagelsen kan åpne en kjøring med sine registrerte premisser'
);

-- Og premissene må være nøyaktig den registrerte tildelingen.
set local role anon;
select throws_ok(
  format($$
    select api.begin_agent_run(
      'agent-identity:source-discovery-01', %L,
      'source_discovery', 'openai', 'en-annen-modell', '9.9.9',
      'source-discovery/machine-search/1', 'antidep-evidence/1',
      jsonb_build_object('note', 'feil premisser'))
  $$, (select secret from cred where label = 'discovery')),
  '22023',
  null,
  'en kjøring med andre premisser enn den registrerte tildelingen avvises'
);

-- Selve søket. Utførelsesbeviset settes av funksjonen, ikke av kalleren.
insert into svar (label, payload)
select 'sok1', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'eff'),
  (select value from refs where label = 'eff_runde'),
  'Europe PMC', 'sertraline AND depressive disorder AND systematic review',
  'ingen språk- eller årsavgrensning',
  'https://www.ebi.ac.uk/europepmc/webservices/rest/search',
  'sha256:' || repeat('a', 64),
  'executed', 42, 42, false, null, null,
  array['bibliographic_database'],
  jsonb_build_array(jsonb_build_object(
    'identifier_kind', 'doi',
    'identifier_value', '10.1000/860-oversikt',
    'title', 'En oversikt over effekt ved depressiv lidelse (prøve 860)',
    'authors_or_issuer', 'Testforfatter',
    'publisher_or_journal', 'Tidsskrift 860',
    'publication_year', 2024,
    'discovery_path', 'Oversiktssøk i Europe PMC')));
reset role;

select is(
  (select payload ->> 'execution_evidence' from svar where label = 'sok1'),
  'machine_executed',
  'Antideps eget kall registreres som maskinelt bekreftet utførelse'
);
select is(
  (select (payload -> 'candidates_recorded')::integer from svar where label = 'sok1'),
  1,
  'og kandidatkilden søket ga, er registrert'
);
select is(
  (select s.execution_evidence::text from workflow.monograph_searches s
   where s.plan_id = (select id from plans where label = 'eff')),
  'machine_executed',
  'raden bærer utførelsesbeviset'
);
-- Sporet søket faktisk kunne dekke, står som dekket. Oversiktssøket gjør det
-- ikke: Europe PMC er ikke registrert for det, og et bibliografisk søk som
-- erklærte det, ville gjort porten blind for et spor ingen hadde søkt i
-- (migrasjon 013x).
select is(
  (select a.state::text
   from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   where a.plan_id = (select id from plans where label = 'eff')
     and k.code = 'bibliographic_database'),
  'covered',
  'sporet søket faktisk dekket, står som dekket'
);
select isnt(
  (select a.state::text
   from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   where a.plan_id = (select id from plans where label = 'eff')
     and k.code = 'systematic_review_search'),
  'covered',
  'og et spor Europe PMC ikke er registrert for, ble ikke dekket av det samme søket'
);
select is(
  (select n.work_state::text
   from knowledge.monograph_needs n
   join workflow.monograph_search_plan_needs pn on pn.need_id = n.id
   where pn.plan_id = (select id from plans where label = 'eff')
   limit 1),
  'searching',
  'behovene planen dekker, står som «søk pågår»'
);

-- Et agentrapportert søk kan strukturelt ikke bære et responsavtrykk.
select throws_ok(
  format($$
    insert into workflow.monograph_searches
      (plan_id, plan_version, platform, query_string, executed_at, result_count,
       outcome, execution_evidence, evidence_endpoint, response_digest,
       recorded_by_actor_id)
    values (%L, 1, 'PubMed', 'sertraline', now(), 7,
            'executed', 'agent_reported', 'https://eutils.example.test',
            'sha256:' || repeat('b', 64), 'ac860000-0000-4000-8000-00000000000a')
  $$, (select id from plans where label = 'eff')),
  '23514',
  null,
  'et agentrapportert søk kan ikke gi seg ut for å være maskinelt bekreftet'
);

-- En utilgjengelig søkevei kan ikke bære et treffantall.
select throws_ok(
  format($$
    insert into workflow.monograph_searches
      (plan_id, plan_version, platform, query_string, executed_at, result_count,
       outcome, limitation_note, execution_evidence, evidence_endpoint,
       response_digest, recorded_by_actor_id)
    values (%L, 1, 'CENTRAL', 'sertraline', now(), 0,
            'unavailable', 'Ingen lesetilgang til databasen.',
            'machine_executed', 'https://example.test',
            'sha256:' || repeat('c', 64), 'ac860000-0000-4000-8000-00000000000a')
  $$, (select id from plans where label = 'eff')),
  '23514',
  null,
  'en utilgjengelig søkevei kan ikke lagres som null treff'
);

-- Et kontrollert nullsøk kan ikke være avkortet.
select throws_ok(
  format($$
    insert into workflow.monograph_searches
      (plan_id, plan_version, platform, query_string, executed_at, result_count,
       truncated, truncation_note, outcome, execution_evidence, evidence_endpoint,
       response_digest, recorded_by_actor_id)
    values (%L, 1, 'CENTRAL', 'sertraline', now(), 0,
            true, 'Bare de ti første ble vist.',
            'zero_results', 'machine_executed', 'https://example.test',
            'sha256:' || repeat('d', 64), 'ac860000-0000-4000-8000-00000000000a')
  $$, (select id from plans where label = 'eff')),
  '23514',
  null,
  'et nullsøk kan ikke samtidig være avkortet'
);

-- Et søk kan ikke erklære å dekke et spor profilen ikke krever.
set local role anon;
select throws_ok(
  format($$
    select api.record_monograph_machine_search(
      'agent-identity:source-discovery-01', %L, %L, %L, %L,
      'Europe PMC', 'sertraline', null, 'https://example.test',
      'sha256:' || repeat('e', 64), 'executed', 3, 3, false, null, null,
      array['norwegian_authority_source'], null)
  $$,
  (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'eff'),
  (select value from refs where label = 'eff_runde')),
  '22023',
  null,
  'et søk kan ikke erklære å dekke et spor runden ikke fikk'
);
reset role;

-- ===========================================================================
-- Del 6 — En søkevei som ikke svarte, er en begrensning og ikke null treff
-- ===========================================================================
-- Før migrasjon 013x «løste» denne prøven de gjenstående sporene ved å
-- registrere søk mot plattformer Antidep ikke har — «Referanselister og
-- siteringsindeks», «ClinicalTrials.gov» — og kalle dem utilgjengelige. Det var
-- den samme hvitvaskingen som på den andre siden lot et bibliografisk søk
-- erklære et oversiktssøk dekket: en prøve som besto på noe kjøreren aldri kan
-- gjøre. Sporene uten maskinell søkevei føres nå i del 9b, der de hører hjemme.
set local role anon;
insert into svar (label, payload)
select 'utilgjengelig1', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'eff'),
  (select value from refs where label = 'eff_runde'),
  'Crossref', 'sertraline AND depressive disorder', null,
  'https://api.crossref.org/works',
  'sha256:' || repeat('6', 64),
  'unavailable', null, 0, false, null,
  'Søkeveien svarte ikke innenfor tidsrammen i denne kjøringen.',
  null, null);
reset role;

select is(
  (select s.result_count from workflow.monograph_searches s
   where s.plan_id = (select id from plans where label = 'eff')
     and s.outcome = 'unavailable'
   limit 1),
  null,
  'en utilgjengelig søkevei har ingen treffantall: den er en begrensning og ikke null treff'
);
select is(
  (select count(*)::integer from workflow.monograph_search_track_attempts a
   where a.plan_id = (select id from plans where label = 'eff') and a.state = 'pending'),
  0,
  'og den rører ingen spor: et søk uten erklærte spor dekker og begrenser ingen av dem'
);

-- ===========================================================================
-- Del 6b — Sporene ingen registrert søkevei dekker
-- ===========================================================================
-- De obligatoriske sporene ingen av Antideps registrerte søkeveier kan dekke,
-- er ført som det fra planen ble opprettet. De er dokumentert, men ikke
-- forsøkt: aldri dekning, og aldri en stillhet (migrasjon 013x).

select is(
  (select count(*)::integer from workflow.monograph_search_track_attempts a
   where a.plan_id = (select id from plans where label = 'eff')
     and a.state = 'no_machine_path'),
  5,
  'de fem obligatoriske sporene ingen registrert søkevei dekker, står som det'
);
select is(
  (select count(*)::integer from workflow.monograph_search_track_attempts a
   where a.plan_id = (select id from plans where label = 'eff') and a.state = 'pending'),
  0,
  'og ingen av dem blir stående som «ikke forsøkt ennå», der de ville ventet for alltid'
);
select alike(
  workflow.monograph_search_closure_problem((select id from plans where label = 'eff')),
  '%registrerte søkeveier dekker%',
  'porten sier hvilke spor som mangler en maskinell vei, framfor å nekte stille'
);
select is(
  (select bool_and(a.resolved_by_actor_id is null)
   from workflow.monograph_search_track_attempts a
   where a.plan_id = (select id from plans where label = 'eff')
     and a.state = 'no_machine_path'),
  true,
  'ingen av dem bærer et menneske ennå: maskinen kan ikke løse dem, og har ikke latet som'
);

-- Redaktørens vei ut. Hun har gjort søkene, og registrerer hva de ga.
select set_config('request.jwt.claims',
                  '{"sub":"86000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format($$select api.record_monograph_track_by_editor(
            %L, 'trial_registries', 'unavailable', 'ok')$$,
         (select value from refs where label = 'eff')),
  '22023',
  null,
  'et spor avklart for hånd krever en begrunnelse, ikke et ord'
);
select throws_ok(
  format($$select api.record_monograph_track_by_editor(
            %L, 'bibliographic_database', 'covered',
            'Forsøk på å overta et spor maskinen allerede dekker.')$$,
         (select value from refs where label = 'eff')),
  '23001',
  null,
  'og et spor maskinen dekker, kan ikke overtas for hånd: ellers var hele den maskinelle fasen valgfri'
);

insert into svar (label, payload)
select 'redaktorspor', api.record_monograph_track_by_editor(
  (select value from refs where label = 'eff'), 'trial_registries', 'unavailable',
  'Søkt manuelt i ClinicalTrials.gov 2026-09-22. Registeret svarte ikke innenfor tidsrammen.');
insert into svar (label, payload)
select 'redaktorspor2', api.record_monograph_track_by_editor(
  (select value from refs where label = 'eff'), 'systematic_review_search', 'covered',
  'Oversiktssøk gjort manuelt i Epistemonikos 2026-09-22; treffene er gjennomgått og de relevante er registrert.');
select 'redaktorspor3', api.record_monograph_track_by_editor(
  (select value from refs where label = 'eff'), 'independent_second_database', 'unavailable',
  'CENTRAL krever abonnement Antidep ikke har. Begrensningen står i utkastet.');
select 'redaktorspor4', api.record_monograph_track_by_editor(
  (select value from refs where label = 'eff'), 'reference_lists', 'unavailable',
  'Referanselistene er gjennomgått manuelt uten nye potensielt konklusjonsendrende kilder.');
select 'redaktorspor5', api.record_monograph_track_by_editor(
  (select value from refs where label = 'eff'), 'citing_works', 'unavailable',
  'Siteringsindeksen er ikke tilgjengelig for Antidep i denne kjøringen.');
reset role;

select isnt(
  (select a.resolved_by_actor_id from workflow.monograph_search_track_attempts a
   join knowledge.monograph_search_tracks k on k.id = a.track_id
   where a.plan_id = (select id from plans where label = 'eff')
     and k.code = 'trial_registries'),
  null,
  'raden bærer hvem som gjorde det: «et menneske har håndtert dette» er ikke det samme faktumet som «en tjeneste svarte ikke»'
);
select unalike(
  coalesce(workflow.monograph_search_closure_problem(
    (select id from plans where label = 'eff')), ''),
  '%registrerte søkeveier dekker%',
  'og når redaktøren har ført alle fem, er det ikke lenger sporene som hindrer at dekningen kan erklæres ferdig'
);

-- ===========================================================================
-- Del 7 — Avkortingen
-- ===========================================================================
set local role anon;
insert into svar (label, payload)
select 'sok2', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'eff'),
  (select value from refs where label = 'eff_runde'),
  'PubMed', 'sertraline[tiab] AND depression[tiab]', null,
  'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi',
  'sha256:' || repeat('8', 64),
  'executed', 1200, 200, true, 'Bare de 200 første treffene ble hentet.',
  null, array['bibliographic_database'], null);
reset role;

select alike(
  workflow.monograph_search_closure_problem((select id from plans where label = 'eff')),
  '%avkortet%',
  'en avkortet treffliste som ikke er fulgt opp, hindrer at søket kan avsluttes'
);

set local role anon;
insert into svar (label, payload)
select 'sok3', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'eff'),
  (select value from refs where label = 'eff_runde'),
  'PubMed', 'sertraline[tiab] AND depression[tiab] AND randomized[pt]', null,
  'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi',
  'sha256:' || repeat('9', 64),
  'executed', 96, 96, false, null, null,
  array['bibliographic_database'], null);
reset role;

select unalike(
  workflow.monograph_search_closure_problem((select id from plans where label = 'eff')),
  '%avkortet%',
  'et oppfølgende søk på den samme plattformen lukker avkortingen'
);

-- ===========================================================================
-- Del 8 — Betalingsmuren og vesentligheten
-- ===========================================================================
insert into workflow.monograph_candidate_sources
  (edition_id, plan_id, identifier_kind, identifier_value, title, discovery_path,
   access_limited, access_limitation_note, could_change_conclusion, materiality_reason,
   recorded_by_actor_id)
select e.id, (select id from plans where label = 'eff'),
       'doi', '10.1000/860-bak-betalingsmur',
       'En avgjørende studie bak en betalingsmur (prøve 860)',
       'Referanselisten i oversikten',
       true, 'Fulltekst krever abonnement hos utgiveren.',
       true, 'Studien er den eneste med komparator og kan endre hovedkonklusjonen.',
       'ac860000-0000-4000-8000-00000000000a'
from knowledge.monograph_editions e;

insert into refs (label, value)
select 'betalingsmur', c.reference from workflow.monograph_candidate_sources c
where c.identifier_value = '10.1000/860-bak-betalingsmur';

select alike(
  workflow.monograph_search_closure_problem((select id from plans where label = 'eff')),
  '%endre hovedkonklusjonen%',
  'en uavklart kilde som kan endre hovedkonklusjonen, hindrer avslutning'
);

select set_config('request.jwt.claims',
                  '{"sub":"86000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.decide_monograph_candidate(%L, 'excluded', 'Kommer ikke til fullteksten.') $$,
         (select value from refs where label = 'betalingsmur')),
  '22023',
  'En kilde med registrert tilgangsbegrensning kan ikke ekskluderes.',
  'en betalingsmur er ikke en faglig eksklusjonsgrunn'
);
insert into svar (label, payload)
select 'avventer', api.decide_monograph_candidate(
  (select value from refs where label = 'betalingsmur'), 'awaiting_access', null);
reset role;

select is(
  (select payload ->> 'decision' from svar where label = 'avventer'),
  'awaiting_access',
  'men den kan settes som «avventer tilgang»'
);
select alike(
  workflow.monograph_search_closure_problem((select id from plans where label = 'eff')),
  '%endre hovedkonklusjonen%',
  'og «avventer tilgang» avklarer den ikke: den kan fortsatt endre svaret'
);

-- ===========================================================================
-- Del 9 — Dekningskontrollen
-- ===========================================================================
set local role anon;
insert into runs (label, id)
select 'control', api.begin_agent_run(
  'agent-identity:source-quality-assessment-01',
  (select secret from cred where label = 'control'),
  'source_quality_assessment', 'antidep', 'coverage-control-registration', '1.0.0',
  'source-coverage/control/1', 'antidep-evidence/1',
  jsonb_build_object('plan_reference', (select value from refs where label = 'eff')));
reset role;

-- En godtatt dekning krever at kontrollen faktisk søkte selv. «To agenter er
-- enige» er uttrykkelig ikke et tilstrekkelig kriterium.
select throws_ok(
  format($$
    select workflow.record_monograph_coverage_control(
      %L, 'accepted', 'Prøve i 860: kontrollen leste bare generatorens referanser.',
      false, 0, 0, false, %L, 'ac860000-0000-4000-8000-00000000000a')
  $$,
  (select id from plans where label = 'eff'),
  (select id from runs where label = 'control')),
  '23514',
  null,
  'en dekningskontroll som ikke søkte selv, kan ikke godta dekningen'
);

-- De to kildeleddene *kan* dele modellidentitet fra migrasjon 013t: den samme
-- modellen utfører dem i atskilte runder, med hver sin instruks og sin egen
-- kontekst. Det som bærer uavhengigheten her, er kravet over — en
-- dekningskontroll som ikke søkte selv, kan ikke godta dekningen — og at de to
-- leddene er hver sin agentidentitet.
insert into provenance.role_model_assignments
  (agent_role, capacity, provider, model, model_version, registered_by_actor_id, reason)
values
  ('source_discovery', 'semantic', 'prøve-860', 'samme-modell', '1',
   'ac860000-0000-4000-8000-00000000000a', 'Prøve i 860: generatorens modell.');

select lives_ok(
  $$
    insert into provenance.role_model_assignments
      (agent_role, capacity, provider, model, model_version, registered_by_actor_id, reason)
    values
      ('source_quality_assessment', 'semantic', 'prøve-860', 'samme-modell', '1',
       'ac860000-0000-4000-8000-00000000000a',
       'Prøve i 860: kontrollen kjører den samme modellen i en egen runde.')
  $$,
  'kontrollen av søkedekningen kan kjøre den samme modellen som kildeoppdagelsen'
);

-- Den faktiske kontrollen: den søkte selv og vurderte vesentligheten.
select isnt(
  (select workflow.record_monograph_coverage_control(
     (select id from plans where label = 'eff'),
     'accepted',
     'Prøve i 860: egne motsøk i to spor, sentrale eksklusjoner gjennomgått, og vesentligheten av den utilgjengelige studien vurdert.',
     true, 1, 2, true,
     (select id from runs where label = 'control'),
     'ac860000-0000-4000-8000-00000000000a')),
  null,
  'en dekningskontroll som søkte selv og vurderte vesentligheten, kan godta dekningen'
);

select throws_ok(
  format($$
    select workflow.record_monograph_coverage_control(
      %L, 'accepted', 'Prøve i 860: en andre kontroll av den samme planversjonen.',
      true, 0, 0, true, null, 'ac860000-0000-4000-8000-00000000000a')
  $$, (select id from plans where label = 'eff')),
  '23505',
  'Denne planversjonen har allerede en dekningskontroll.',
  'én dekningskontroll per planversjon'
);

-- ===========================================================================
-- Del 10 — Porten
-- ===========================================================================
-- Den vesentlige kilden avklares: fullteksten ble innhentet.
select set_config('request.jwt.claims',
                  '{"sub":"86000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'inkludert', api.decide_monograph_candidate(
  (select value from refs where label = 'betalingsmur'), 'included',
  'Prøve i 860: fullteksten ble innhentet, og studien er inkludert for effektspørsmålet.');
reset role;

-- Metningssignalet krever to *ulike* supplerende søkepasseringer uten nye
-- potensielt konklusjonsendrende kilder, etter det søket som sist fant en
-- kilde. Etter de to PubMed-passeringene er bare én plattform dekket, og
-- signalet er ikke gitt.
select alike(
  workflow.monograph_search_closure_problem((select id from plans where label = 'eff')),
  '%Metningssignalet mangler%',
  'én plattform er ikke to ulike supplerende søkepasseringer'
);

set local role anon;
insert into svar (label, payload)
select 'metning', api.record_monograph_machine_search(
  'agent-identity:source-discovery-01', (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'eff'),
  (select value from refs where label = 'eff_runde'),
  'Europe PMC',
  'CITES:"10.1000/860-oversikt" OR (sertraline OR "Zoloft")', null,
  'https://www.ebi.ac.uk/europepmc/webservices/rest/search',
  'sha256:' || repeat('a', 63) || '1',
  'zero_results', 0, 0, false, null, null,
  array['bibliographic_database'], null);
reset role;

select is(
  workflow.monograph_search_closure_problem((select id from plans where label = 'eff')),
  null,
  'med to ulike passeringer og alle de andre kravene oppfylt hindrer ingenting at søkedekningen erklæres ferdig'
);

-- Et oppbrukt arbeidsbudsjett lukker ingenting: det setter planen på pause.
select set_config('request.jwt.claims',
                  '{"sub":"86000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'pause', api.pause_monograph_search_plan(
  (select value from refs where label = 'eff'),
  'Prøve i 860: arbeidsbudsjettet for kjøringen er brukt opp.');
reset role;

select alike(
  workflow.monograph_search_closure_problem((select id from plans where label = 'eff')),
  '%på pause%',
  'et oppbrukt arbeidsbudsjett gir åpent arbeid og aldri en ferdig søkedekning'
);

select set_config('request.jwt.claims',
                  '{"sub":"86000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.close_monograph_search_plan(%L, 'Prøve i 860.') $$,
         (select value from refs where label = 'eff')),
  '23001',
  null,
  'og en plan på pause kan ikke erklæres ferdig'
);
insert into svar (label, payload)
select 'gjenopptatt', api.resume_monograph_search_plan(
  (select value from refs where label = 'eff'));
insert into svar (label, payload)
select 'lukket', api.close_monograph_search_plan(
  (select value from refs where label = 'eff'),
  'Prøve i 860: alle obligatoriske spor forsøkt, metningssignalet gitt, dekningskontrollen godtatt.');
reset role;

select is(
  (select (payload -> 'closed')::boolean from svar where label = 'lukket'),
  true,
  'søkedekningen kan erklæres ferdig når kravene er oppfylt'
);
select is(
  (select n.work_state::text
   from knowledge.monograph_needs n
   join workflow.monograph_search_plan_needs pn on pn.need_id = n.id
   where pn.plan_id = (select id from plans where label = 'eff')
   limit 1),
  'appraising_sources',
  'og behovene går videre til kildevurdering'
);

-- Et søk etter at dekningen er erklært, hører til en ny planversjon.
set local role anon;
select throws_ok(
  format($$
    select api.record_monograph_machine_search(
      'agent-identity:source-discovery-01', %L, %L, %L, %L,
      'Europe PMC', 'sertraline', null, 'https://example.test',
      'sha256:' || repeat('c', 63) || '3', 'executed', 1, 1, false, null, null,
      array['bibliographic_database'], null)
  $$,
  (select secret from cred where label = 'discovery'),
  (select id from runs where label = 'discovery'),
  (select value from refs where label = 'eff'),
  (select value from refs where label = 'eff_runde')),
  '23001',
  'Søkedekningen for denne planen er erklært ferdig.',
  'et søk etter at dekningen er erklært, avvises'
);
reset role;

select throws_ok(
  format($$
    update workflow.monograph_search_plans set closed_at = null where id = %L
  $$, (select id from plans where label = 'eff')),
  '23001',
  'En erklært ferdig søkedekning kan ikke gjenåpnes.',
  'en erklært ferdig søkedekning kan ikke gjenåpnes'
);

-- ===========================================================================
-- Del 11 — En regulatorisk plan trenger ikke metningssignalet
-- ===========================================================================
-- Den regulatoriske profilen har ingen obligatoriske spor noen registrert
-- søkevei dekker: myndighetskilden, produktlisten og endringskontrollen er alle
-- menneskets. Før migrasjon 013x «løste» prøven dem ved å finne opp plattformen
-- «DMP Legemiddelsøk» og la den erklære myndighetskilden dekket. Nå går de den
-- veien de faktisk må gå.
select is(
  (select count(*)::integer from workflow.monograph_search_track_attempts a
   where a.plan_id = (select id from plans where label = 'reg')
     and a.state = 'no_machine_path'),
  3,
  'den regulatoriske planens tre obligatoriske spor har ingen maskinell søkevei, og står som det'
);

update workflow.monograph_search_track_attempts a
set state = 'unavailable',
    note = 'Prøve i 860: den norske myndighetskilden er kontrollert manuelt i kjøringen.',
    resolved_by_actor_id = 'ac860000-0000-4000-8000-00000000000a'
where a.plan_id = (select id from plans where label = 'reg')
  and a.state in ('pending', 'no_machine_path');

insert into workflow.monograph_searches
  (plan_id, plan_version, platform, query_string, executed_at, result_count,
   screened_count, outcome, execution_evidence, evidence_endpoint, response_digest,
   track_codes, recorded_by_actor_id)
values (
  (select id from plans where label = 'reg'), 1,
  'Europe PMC', 'sertralin preparatomtale', now(), 4, 4,
  'executed', 'machine_executed', 'https://www.ebi.ac.uk/europepmc/webservices/rest/search',
  'sha256:' || repeat('d', 63) || '4',
  array[]::text[], 'ac860000-0000-4000-8000-00000000000a');

select isnt(
  (select workflow.record_monograph_coverage_control(
     (select id from plans where label = 'reg'),
     'accepted',
     'Prøve i 860: gjeldende preparatomtale kontrollert direkte i myndighetskilden, og versjonen er ikke avløst.',
     true, 0, 0, true, null, 'ac860000-0000-4000-8000-00000000000a')),
  null,
  'den regulatoriske planen kan få sin dekningskontroll'
);
select is(
  workflow.monograph_search_closure_problem((select id from plans where label = 'reg')),
  null,
  'for en autoritativ regulatorisk opplysning kreves ikke metningssignalet: én riktig, gjeldende kilde kan være nok'
);

-- ===========================================================================
-- Del 12 — Søkeloggen slik en fagperson leser den
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"86000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'logg', api.monograph_search_plans((select value from refs where label = 'utgave'));
reset role;

select cmp_ok(
  (select jsonb_array_length(payload) from svar where label = 'logg'),
  '>', 0,
  'redaktøren får søkeplanene med hele søkeloggen'
);
select ok(
  (select bool_and(
     s ? 'platform' and s ? 'query' and s ? 'result_count'
     and s ? 'screened_count' and s ? 'truncated' and s ? 'execution_evidence')
   from svar,
        jsonb_array_elements(payload) as plan,
        jsonb_array_elements(plan -> 'searches') as s
   where label = 'logg'),
  'hvert søk i loggen bærer plattform, streng, treffantall, gjennomgått omfang, avkorting og utførelsesbevis'
);
select ok(
  (select bool_and(not (plan ? 'id') and not (plan -> 'scope' ? 'indication_concept_id'))
   from svar, jsonb_array_elements(payload) as plan
   where label = 'logg'),
  'og ingen intern id forlater databasen'
);
-- Kandidatkildens mulige bruksområder og begrunnelser er med, uten en intern id.
select ok(
  (select bool_and(c ? 'decision' and c ? 'access_limited' and c ? 'could_change_conclusion')
   from svar,
        jsonb_array_elements(payload) as plan,
        jsonb_array_elements(plan -> 'candidates') as c
   where label = 'logg'),
  'og hver kandidatkilde bærer utvalgsbeslutningen, tilgangstilstanden og vesentligheten'
);

select * from finish();

rollback;
