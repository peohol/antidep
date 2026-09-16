-- Migrasjon 011a — en autonom kjører over den eksterne agent-handoffen.
--
-- Filen dekker at setningene i migrasjonen betyr noe:
--
--   * tilkoblingen registreres av et menneske med mandat, aldri av et svar,
--   * ett agentledd har høyst én kjører, og én Workspace Agent kjører ett ledd,
--   * tilkoblingskoden er én gang, kort levetid og PKCE med S256,
--   * tokenet gir arbeid i nøyaktig ett ledd, og ingenting annet,
--   * bare ekte handoff-jobber eksponeres — aldri en vanlig pipelinejobb,
--   * en løpende leie blokkerer, og en utløpt leie er ledig igjen,
--   * oppgavehåndtaket ER leienøkkelen, så et manipulert håndtak treffer ingen,
--   * leveringen går gjennom den samme skriveveien som et opplastet svar.json,
--   * det samme svaret registrerer ingenting nytt, og et annet svar avvises,
--   * en tilbaketrekking stopper tilgangen i det samme øyeblikket,
--   * og sporet bærer utfallsklassen, aldri kildeteksten.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23505 = unique_violation, 02000 = no_data_found.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(114);

-- ===========================================================================
-- Del 1 — Flaten
-- ===========================================================================
select has_table('workflow', 'agent_runner_connections',
                 'workflow.agent_runner_connections finnes');
select has_table('workflow', 'agent_runner_secrets',
                 'workflow.agent_runner_secrets finnes');
select has_table('workflow', 'agent_runner_events',
                 'workflow.agent_runner_events finnes');

-- Redaktørveiene er authenticated og ingenting annet: å registrere en kjører,
-- hente en engangskode og trekke den tilbake er avgjørelser om hvem som utfører
-- kjedens arbeid.
select is_empty(
  $$
    select f.name
    from (values
      ('api.register_agent_runner(text,text,text,text,text,text)'),
      ('api.revoke_agent_runner(text,text)'),
      ('api.issue_agent_runner_pairing_code(text)'),
      ('api.agent_runner_connections()')
    ) as f(name)
    where has_function_privilege('anon', f.name, 'EXECUTE')
       or has_function_privilege('public', f.name, 'EXECUTE')
       or has_function_privilege('service_role', f.name, 'EXECUTE')
  $$,
  'redaktørveiene for kjøreren er ikke åpne for anon, service_role eller PUBLIC'
);

-- Kjørerveiene er anon, av samme grunn som api.claim_pipeline_job: en kjører har
-- ingen brukerkonto, så tokenet og ikke Data API-rollen er kontrollen.
select is_empty(
  $$
    select f.name
    from (values
      ('api.list_pending_agent_tasks(text,text)'),
      ('api.claim_agent_task(text,text,text,integer)'),
      ('api.agent_task_for_runner(text,text,uuid)'),
      ('api.agent_task_precheck(text,text,uuid)'),
      ('api.submit_agent_answer(text,text,uuid,jsonb)'),
      ('api.release_agent_task(text,text,uuid,text)'),
      ('api.agent_runner_identity(text,text)')
    ) as f(name)
    where not has_function_privilege('anon', f.name, 'EXECUTE')
       or has_function_privilege('public', f.name, 'EXECUTE')
       or has_function_privilege('service_role', f.name, 'EXECUTE')
  $$,
  'kjørerveiene er gitt til anon, og aldri til service_role eller PUBLIC'
);

select is_empty(
  $$
    select r.rolname
    from (values ('anon'), ('authenticated'), ('service_role')) as r(rolname)
    where has_table_privilege(r.rolname, 'workflow.agent_runner_secrets', 'SELECT')
  $$,
  'ingen klientrolle kan lese fingeravtrykkene av tokenene'
);

-- ===========================================================================
-- Del 2 — Grunnlaget
-- ===========================================================================
create temporary table rep (text text) on commit drop;
insert into rep values (
  E'Syntetisk artikkel om sertralin og vektendring, for kjørerprøven.\n\n' ||
  E'Patients (N = 100) with major depressive disorder were randomly assigned to sertraline for 8 weeks.\n\n' ||
  E'Mean weight change from baseline was 0.8 kg in the sertraline arm at 8 weeks.\n\n' ||
  E'No confidence interval was reported for the mean weight change.\n\n' ||
  E'The study was limited by its short duration and its open-label design.\n');

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('79000000-0000-4000-8000-000000000001', 'journal_article',
        'Syntetisk kjørerkilde for 790', 'Testforfatter', pg_temp.extraction_actor_id());

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, external_version, content_hash,
  representation, retrieved_by_actor_id, document_sha256, document_byte_size,
  document_media_type, text_extraction_tool, text_extraction_tool_version,
  text_extraction_arguments, text_extraction_transform
)
select '79000000-0000-4000-8000-000000000002', '79000000-0000-4000-8000-000000000001',
       now(), 'file:///runner-790.pdf', 'runner-v1',
       knowledge.source_version_content_hash(r.text),
       'full_text', pg_temp.extraction_actor_id(),
       pg_temp.synthetic_pdf_digest('79000000-0000-4000-8000-000000000002'),
       octet_length(pg_temp.synthetic_pdf('79000000-0000-4000-8000-000000000002')),
       'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from rep r;

insert into knowledge.source_version_texts (source_version_id, representation, stored_by_actor_id)
select '79000000-0000-4000-8000-000000000002', r.text, pg_temp.extraction_actor_id() from rep r;

insert into auth.users (id, email) values
  ('79000000-0000-4000-8000-00000000000e', 'redaktor-790@test.invalid'),
  ('79000000-0000-4000-8000-00000000000f', 'utenmandat-790@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac790000-0000-4000-8000-00000000000e', 'human', 'human:redaktor-790', 'Redaktør 790',
   'Aktør med editor-tildeling, for 790.', '79000000-0000-4000-8000-00000000000e'),
  ('ac790000-0000-4000-8000-00000000000f', 'human', 'human:utenmandat-790', 'Uten mandat 790',
   'Aktør uten editor-tildeling, for 790.', '79000000-0000-4000-8000-00000000000f');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('79000000-0000-4000-8000-00000000000e', 'editor', null, now() - interval '1 year',
   (select id from provenance.actors where actor_key = 'human:peder-holman'),
   'Gyldig editor-tildeling for 790.');

create temporary table ids (name text primary key, id uuid) on commit drop;
insert into ids select 'drug', id from catalog.drugs where canonical_name = 'sertralin';
insert into ids select 'other_drug', id from catalog.drugs where canonical_name = 'mirtazapin';
insert into ids select 'outcome', id from catalog.clinical_concepts
  where canonical_label = 'vektendring' and concept_type = 'outcome';
insert into ids select 'population', id from catalog.populations
  where canonical_label = 'voksne med depressiv lidelse';

create temporary table res (label text primary key, payload jsonb) on commit drop;
grant select, insert on res to authenticated, anon;
grant select on ids to authenticated, anon;

-- ===========================================================================
-- Del 3 — Registreringen av kjøreren
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000f"}', true);
set local role authenticated;
select throws_ok(
  $$ select api.register_agent_runner('agent-runner:x', 'X', 'evidence_extraction',
                                      'Agent X', 'not_exposed') $$,
  '42501',
  null,
  'en innlogget bruker uten editor-mandat kan ikke registrere en autonom kjører'
);
select throws_ok(
  $$ select api.agent_runner_connections() $$,
  '42501',
  null,
  'og kan ikke se hvilke kjørere som finnes'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;

-- De uavhengige kontrolleddene er Antideps egen deterministiske kode, og en
-- ekstern modell som fikk utføre dem, ville gjort kontrollen til nok en
-- modellvurdering (ANTIDEP_CONSTITUTION.md regel 3).
select throws_ok(
  $$ select api.register_agent_runner('agent-runner:ekstraksjonskontroll', 'Kontroll',
                                      'extraction_verification', 'Agent K', 'not_exposed') $$,
  '22023',
  null,
  'et kontrolledd kan ikke settes ut til en autonom kjører'
);

select throws_ok(
  $$ select api.register_agent_runner('agent-runner:ekstraksjon', 'Kjører',
                                      'evidence_extraction', 'Agent A', 'kanskje') $$,
  '22023',
  null,
  'eksponeringsgraden må være platform_pinned eller not_exposed, og ikke fri tekst'
);

insert into res
select 'runner', api.register_agent_runner(
  'agent-runner:evidence-extraction', 'Antidep ekstraksjonskjører',
  'evidence_extraction', 'Antidep Ekstraksjon (ChatGPT)', 'not_exposed',
  'Prøve 790: den planlagte kjøreren av ekstraksjonsleddet.');

select is(
  (select payload ->> 'agent_role' from res where label = 'runner'),
  'evidence_extraction',
  'kjøreren registreres bundet til nøyaktig ett agentledd'
);

-- Ett ledd har høyst én gjeldende kjører.
select throws_ok(
  $$ select api.register_agent_runner('agent-runner:ekstraksjon-to', 'En til',
                                      'evidence_extraction', 'Antidep Ekstraksjon B', 'not_exposed') $$,
  '23001',
  null,
  'et agentledd kan ikke ha to gjeldende autonome kjørere'
);

-- Og den samme Workspace Agent-en kan ikke kjøre to ledd. Én konfigurasjon er
-- én modellruntime, og en kjede der den samme agenten både laget innholdet og
-- vurderte det, ville vært egenverifikasjon med et ekstra ledd.
select throws_ok(
  $$ select api.register_agent_runner('agent-runner:claim-synthesis', 'Syntese',
                                      'claim_synthesis', 'Antidep Ekstraksjon (ChatGPT)', 'not_exposed') $$,
  '23001',
  null,
  'den samme Workspace Agent-en kan ikke kjøre to agentledd'
);

-- ===========================================================================
-- Del 4 — Tilkoblingskoden og OAuth-flyten
-- ===========================================================================
insert into res
select 'pairing', api.issue_agent_runner_pairing_code('agent-runner:evidence-extraction');

select matches(
  (select payload ->> 'pairing_code' from res where label = 'pairing'),
  '^[0-9a-f]{64}$',
  'tilkoblingskoden er 64 heksadesimale tegn fra databasens egen tilfeldighetskilde'
);
reset role;

-- Koden lagres aldri i klartekst.
select is_empty(
  format(
    $$ select s.id from workflow.agent_runner_secrets s
       where s.secret_hash = %L $$,
    (select payload ->> 'pairing_code' from res where label = 'pairing')
  ),
  'tilkoblingskoden finnes ikke i klartekst i databasen'
);
select is(
  (select count(*)::int from workflow.agent_runner_secrets s where s.kind = 'pairing_code'),
  1,
  'én tilkoblingskode er utstedt'
);

-- PKCE-utfordringen regnes ut før rollen byttes: `anon` har ingen usage på
-- workflow, og skal ikke ha det. Verifieren er RFC 7636 sitt eget eksempel.
insert into res
select 'pkce', jsonb_build_object(
  'verifier', 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
  'challenge', workflow.pkce_s256_challenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
  'other_challenge', workflow.pkce_s256_challenge('en-annen'));

set local role anon;
insert into res
select 'client', api.register_agent_runner_client(
  'Prøveklient', array['https://chatgpt.example/callback']);

select throws_ok(
  $$ select api.register_agent_runner_client('Ugyldig', array['http://ikke-lokal.example/cb']) $$,
  '22023',
  null,
  'en redirect-adresse som verken er https eller loopback, avvises'
);

-- Og en adresse som bare BEGYNNER som en adresse. Uten forankringen i begge
-- ender ville den blitt godtatt her, brukt opp en engangskode ved
-- autorisasjonen, og så kastet i serverens URL-lesning — 500 uten
-- videresending, og en ny engangskode å hente.
select throws_ok(
  $$ select api.register_agent_runner_client('Halvveis',
       array['https://chatgpt.example/callback noe helt annet']) $$,
  '22023',
  null,
  'en redirect-adresse som ikke kan leses som en adresse, avvises der den oppgis'
);

-- Og en port som ikke finnes. Et mønster som bare teller siffer, ville godtatt
-- begge de to under: portene stopper på 65535, og grensen her skal være den
-- samme som serverens URL-leser har.
select throws_ok(
  $$ select api.register_agent_runner_client('For høy port',
       array['https://chatgpt.example:65536/callback']) $$,
  '22023',
  null,
  'en portverdi over 65535 avvises'
);

select throws_ok(
  $$ select api.register_agent_runner_client('Mye for høy port',
       array['https://chatgpt.example:99999/callback']) $$,
  '22023',
  null,
  'og en som ikke engang er i nærheten'
);

-- Grenseverdien prøves på selve regelen framfor gjennom registreringen: en
-- vellykket registrering ville brukt av taket per time, som en annen prøve
-- lenger nede teller nøyaktig.
reset role;
select is(
  workflow.agent_runner_redirect_uri_is_valid('https://chatgpt.example:65535/callback'),
  true,
  'mens den høyeste porten som finnes, godtas'
);
set local role anon;

-- PKCE er påkrevd, og bare S256.
select throws_ok(
  format(
    $$ select api.authorize_agent_runner(%L, %L, 'https://chatgpt.example/callback',
                                         'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM', 'plain',
                                         'https://antidep.example/mcp') $$,
    (select payload ->> 'pairing_code' from res where label = 'pairing'),
    (select payload ->> 'client_id' from res where label = 'client')
  ),
  '22023',
  null,
  'PKCE med plain avvises; bare S256 godtas'
);

-- En adresse klienten ikke registrerte, svares på med det samme avslaget som en
-- ukjent kode: en kaller som kunne skille dem, kunne kartlagt klienter.
select throws_ok(
  format(
    $$ select api.authorize_agent_runner(%L, %L, 'https://angriper.example/cb',
                                         'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM', 'S256',
                                         'https://antidep.example/mcp') $$,
    (select payload ->> 'pairing_code' from res where label = 'pairing'),
    (select payload ->> 'client_id' from res where label = 'client')
  ),
  '42501',
  null,
  'en autorisasjonskode leveres aldri til en adresse klienten ikke registrerte'
);

insert into res
select 'grant', api.authorize_agent_runner(
  (select payload ->> 'pairing_code' from res where label = 'pairing'),
  (select payload ->> 'client_id' from res where label = 'client'),
  'https://chatgpt.example/callback',
  (select payload ->> 'challenge' from res where label = 'pkce'),
  'S256', 'https://antidep.example/mcp');

-- Engangskoden er brukt opp.
select throws_ok(
  format(
    $$ select api.authorize_agent_runner(%L, %L, 'https://chatgpt.example/callback', %L, 'S256',
                                         'https://antidep.example/mcp') $$,
    (select payload ->> 'pairing_code' from res where label = 'pairing'),
    (select payload ->> 'client_id' from res where label = 'client'),
    (select payload ->> 'other_challenge' from res where label = 'pkce')
  ),
  '42501',
  null,
  'tilkoblingskoden kan bare brukes én gang'
);

-- Feil code_verifier gir ingen tokens.
select throws_ok(
  format(
    $$ select api.exchange_agent_runner_code(%L, 'feil-verifier', %L,
                                             'https://chatgpt.example/callback',
                                             'https://antidep.example/mcp') $$,
    (select payload ->> 'authorization_code' from res where label = 'grant'),
    (select payload ->> 'client_id' from res where label = 'client')
  ),
  '42501',
  null,
  'en autorisasjonskode kan ikke innløses uten den riktige PKCE-verifieren'
);

insert into res
select 'tokens', api.exchange_agent_runner_code(
  (select payload ->> 'authorization_code' from res where label = 'grant'),
  (select payload ->> 'verifier' from res where label = 'pkce'),
  (select payload ->> 'client_id' from res where label = 'client'),
  'https://chatgpt.example/callback', 'https://antidep.example/mcp');

select is(
  (select payload ->> 'token_type' from res where label = 'tokens'),
  'Bearer',
  'utvekslingen gir et Bearer-token'
);

-- Autorisasjonskoden er også en engangskode.
select throws_ok(
  format(
    $$ select api.exchange_agent_runner_code(%L, %L, %L, 'https://chatgpt.example/callback',
                                             'https://antidep.example/mcp') $$,
    (select payload ->> 'authorization_code' from res where label = 'grant'),
    (select payload ->> 'verifier' from res where label = 'pkce'),
    (select payload ->> 'client_id' from res where label = 'client')
  ),
  '42501',
  null,
  'en autorisasjonskode kan bare innløses én gang'
);

select is(
  (select payload ->> 'agent_role' from api.agent_runner_identity(
     (select payload ->> 'access_token' from res where label = 'tokens'),
     'https://antidep.example/mcp') as t(payload)),
  'evidence_extraction',
  'tokenet identifiserer nøyaktig det agentleddet tilkoblingen er registrert for'
);

select throws_ok(
  $$ select api.agent_runner_identity(repeat('f', 64), 'https://antidep.example/mcp') $$,
  '42501',
  null,
  'et token databasen ikke kjenner, avvises med det samme avslaget'
);
reset role;

-- ===========================================================================
-- Del 5 — Arbeidet
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;

-- En helt vanlig pipelinejobb i den samme rollen. Den skal ALDRI komme til
-- syne for kjøreren: utførelsesmåten er en egenskap ved raden, ikke ved rollen.
insert into res
select 'internal', api.enqueue_pipeline_job(
  'evidence_extraction', 'intern-jobb-790', jsonb_build_object(
    'source_version_id', '79000000-0000-4000-8000-000000000002'));

insert into res
select 'task', api.enqueue_agent_task('evidence_extraction', jsonb_build_object(
  'source_version_id', '79000000-0000-4000-8000-000000000002',
  'drug_ids', jsonb_build_array((select id from ids where name = 'drug')),
  'outcome_concept_ids', jsonb_build_array((select id from ids where name = 'outcome')),
  'population_ids', jsonb_build_array((select id from ids where name = 'population'))
));
reset role;

set local role anon;

-- Ingen KI-tjeneste er valgt for leddet ennå. Oppgaven finnes, men den venter
-- på et menneske — og det er noe annet enn at det ikke finnes arbeid.
select is(
  (select (api.list_pending_agent_tasks(
     (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp') -> 'tasks')::text),
  '[]',
  'en oppgave uten valgt KI-tjeneste er ikke arbeid kjøreren kan ta'
);
select cmp_ok(
  (select (api.list_pending_agent_tasks(
     (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp') ->> 'blocked_count')::int),
  '>=', 1,
  'og den telles som noe som venter på et menneske, framfor å forsvinne'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select api.assign_agent_role_model(
  'evidence_extraction', 'antidep-test', 'kjorer-modell-790', null, 'not_exposed',
  'Prøve 790: tjenesten som utfører ekstraksjonsutkastet.');
reset role;

set local role anon;
insert into res
select 'pending', api.list_pending_agent_tasks(
  (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp');

select is(
  (select jsonb_array_length(payload -> 'tasks') from res where label = 'pending'),
  1,
  'bare den ekte handoff-oppgaven vises — den interne pipelinejobben aldri'
);
select matches(
  (select payload -> 'tasks' -> 0 ->> 'task_ref' from res where label = 'pending'),
  '^task_[0-9a-f]{24}$',
  'køen gir en ugjennomsiktig henvisning, og ingen databaseidentitet'
);

-- Køen skal si hva oppgaven gjelder, og ikke bære artikkelen: én planlagt
-- kjøring skal ikke laste ned hele fulltekstbiblioteket for å se hva som finnes.
select is_empty(
  $$
    select 1 from res
    where label = 'pending'
      and payload::text like '%major depressive disorder%'
  $$,
  'køen inneholder ikke kildeteksten'
);

-- Et manipulert håndtak treffer ingen oppgave.
select is(
  (select api.claim_agent_task(
     (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp',
     'task_000000000000000000000000') ->> 'reason'),
  'stale_task',
  'en oppgavehenvisning kjøreren fant på, gir ingen oppgave'
);

insert into res
select 'claim', api.claim_agent_task(
  (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp',
  (select payload -> 'tasks' -> 0 ->> 'task_ref' from res where label = 'pending'),
  900);

select is(
  (select (payload ->> 'claimed')::boolean from res where label = 'claim'),
  true,
  'kjøreren tar ut oppgaven med en leie'
);

-- En løpende leie blokkerer. Ingen annen kjøring og ingen import kan ta den.
select is(
  (select api.claim_agent_task(
     (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp') ->> 'reason'),
  'no_work',
  'en oppgave med løpende leie er ikke ledig for et nytt uttak'
);

select is(
  (select (api.agent_task_for_runner(
     (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp',
     (select (payload ->> 'task_handle')::uuid from res where label = 'claim')) ->> 'available')::boolean),
  true,
  'den som holder leien, får hele oppgaven'
);

-- Og bare den. Et håndtak som ikke er jobbens gjeldende leie, gir ingen
-- forskningsartikkel ut.
select is(
  (select api.agent_task_for_runner(
     (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp',
     '00000000-0000-4000-8000-000000000000'::uuid) ->> 'reason'),
  'stale_task',
  'et manipulert oppgavehåndtak gir ingen oppgave ut'
);

insert into res
select 'payload', api.agent_task_for_runner(
  (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp',
  (select (payload ->> 'task_handle')::uuid from res where label = 'claim'));

select ok(
  (select payload -> 'task' -> 'input' ->> 'representation_text' from res where label = 'payload')
    like '%major depressive disorder%',
  'oppgaven bærer hele den kontrollerte fullteksten når den først er tatt'
);
reset role;

select ok(
  (select payload -> 'task' ->> 'request_digest' from res where label = 'payload')
    = (select workflow.agent_task_digest(workflow.agent_task(j) -> 'binding')
       from workflow.pipeline_jobs j
       where j.id = (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'task')),
  'avtrykket er nøyaktig det den manuelle veien ville gitt, av de samme radene'
);

-- ---------------------------------------------------------------------------
-- Forhåndslesningen har sitt eget navn, og kalleren kan ikke velge det
--
-- MCP-serveren leser oppgaven én gang til inne i `submit_agent_answer`, fordi
-- de deterministiske kontrollene trenger kildeteksten og protokollen er
-- tilstandsløs. Den lesningen er ikke et verktøykall. Navnet i sporet er
-- funksjonen som ble kalt, ikke en verdi kalleren sendte med: en etikett
-- kalleren valgte, ville latt en tokeninnehaver få databasen til å skrive at en
-- levering fant sted.
-- ---------------------------------------------------------------------------
insert into res
select 'events_before', jsonb_build_object(
  'get_agent_task', (select count(*) from workflow.agent_runner_events
                     where tool_name = 'get_agent_task'),
  'submit_agent_answer', (select count(*) from workflow.agent_runner_events
                          where tool_name = 'submit_agent_answer'),
  'precheck', (select count(*) from workflow.agent_runner_events
               where tool_name = 'submit_agent_answer:precheck'));

set role anon;

select lives_ok(
  $$
    select api.agent_task_precheck(
      (select payload ->> 'access_token' from res where label = 'tokens'),
      'https://antidep.example/mcp',
      (select (payload ->> 'task_handle')::uuid from res where label = 'claim'))
  $$,
  'leveringen kan lese oppgaven gjennom sin egen forhåndslesning'
);

-- Og verktøyveien tar ikke imot et navn i det hele tatt: den har ingen
-- parameter å spoofe.
select throws_ok(
  $$
    select api.agent_task_for_runner(
      (select payload ->> 'access_token' from res where label = 'tokens'),
      'https://antidep.example/mcp',
      (select (payload ->> 'task_handle')::uuid from res where label = 'claim'),
      'submit_agent_answer')
  $$,
  '42883',
  null,
  'verktøyveien har ingen etikett en kaller kan sende med'
);

reset role;

select is(
  (select count(*)::int from workflow.agent_runner_events
   where tool_name = 'submit_agent_answer:precheck'),
  (select (payload ->> 'precheck')::int + 1 from res where label = 'events_before'),
  'forhåndslesningen fører sin egen rad, under sitt eget navn'
);

-- Den påstår ingenting om at en levering fant sted, og den skygger ikke for
-- det autoritative utfallet: det står i én rad, skrevet av leveringen selv.
select is(
  (select count(*)::int from workflow.agent_runner_events
   where tool_name = 'submit_agent_answer'),
  (select (payload ->> 'submit_agent_answer')::int from res where label = 'events_before'),
  'ingen levering blir påstått av en lesning'
);

select is(
  (select count(*)::int from workflow.agent_runner_events
   where tool_name = 'get_agent_task'),
  (select (payload ->> 'get_agent_task')::int from res where label = 'events_before'),
  'og ingen get_agent_task-rad ble skrevet for et kall ingen klient gjorde'
);

-- ===========================================================================
-- Del 6 — Leveringen
--
-- «Agenten» under er denne prøven. Den kopierer bindingsverdiene uendret ut av
-- oppgaven og fyller inn de to tingene bare den vet: hvem den er, og hva den kom
-- fram til.
-- ===========================================================================
create temporary table answers (label text primary key, payload jsonb) on commit drop;
grant select, insert on answers to anon, authenticated;

insert into answers
select 'runner', jsonb_build_object(
  'answer_version', 'antidep/agent-answer@1',
  'task_version', 'antidep/agent-task@1',
  'role', 'evidence_extraction',
  'job_key', t.payload -> 'task' ->> 'job_key',
  'request_digest', t.payload -> 'task' ->> 'request_digest',
  'output_schema_version', t.payload -> 'task' ->> 'output_schema_version',
  'identity', jsonb_build_object(
    'provider', 'antidep-test', 'model', 'kjorer-modell-790',
    'model_version_disclosure', 'not_exposed'),
  'answered_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'result', jsonb_build_object(
    'extraction', jsonb_build_object(
      'design_code', 'randomized_controlled_trial',
      'population_id', (select id from ids where name = 'population'),
      'population_availability', 'reported_value',
      'population_detail', 'Voksne med depressiv lidelse',
      'sample_size', 100,
      'sample_size_availability', 'reported_value',
      'intervention_drug_id', (select id from ids where name = 'drug'),
      'intervention_detail', 'sertralin',
      'comparator_kind', 'none',
      'comparator_drug_id', null,
      'comparator_detail', null,
      'outcome_concept_id', (select id from ids where name = 'outcome'),
      'outcome_detail', 'Vektendring fra baseline',
      'timepoint_min', '8 weeks',
      'timepoint_max', '8 weeks',
      'timepoint_availability', 'reported_value',
      'reported_direction', 'increase',
      'effect_measure', 'mean_change',
      'estimate', '0.8',
      'estimate_unit', 'kg',
      'estimate_availability', 'reported_value',
      'ci_lower', null, 'ci_upper', null, 'ci_level_percent', null,
      'confidence_interval_availability', 'not_reported',
      'limitations_text', 'Kort varighet og åpen design.',
      'source_locator', 'Avsnitt 3',
      'source_quote', 'Mean weight change from baseline was 0.8 kg in the sertraline arm at 8 weeks.'
    ),
    'field_groundings', (
      select jsonb_agg(jsonb_build_object(
        'check_field', f,
        'source_excerpt', 'Mean weight change from baseline was 0.8 kg in the sertraline arm at 8 weeks.',
        'source_locator', 'Avsnitt 3',
        'justification', 'Utdraget oppgir verdien for ' || f || '.'))
      from unnest(array['intervention_arm','outcome','reported_direction','availability_semantics',
                        'effect_measure','population','sample_size','timepoint','estimate',
                        'limitations']) as f
    )
  ))
from res t where t.label = 'payload';

set local role anon;

-- Et svar levert på et håndtak kjøreren ikke holder, skriver ingenting.
select is(
  (select api.submit_agent_answer(
     (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp',
     '00000000-0000-4000-8000-000000000000'::uuid,
     (select payload from answers where label = 'runner')) ->> 'reason'),
  'stale_task',
  'et svar på et foreldet håndtak registrerer ingenting'
);

-- En avvisning er en TILSTAND, ikke et unntak — og det er en egenskap ved
-- sporet. Et unntak ville rullet hele leveringen tilbake, sporet inkludert, og
-- da måtte kjøreren selv meldt fra om at den ble avvist. En slik rad sier bare
-- hva kjøreren sa. Fanget i leveringen er raden derimot skrevet av operasjonen
-- som faktisk fant sted.
--
-- Et svar fra en annen modell enn den leddet er tildelt, avvises før noe skrives.
select is(
  (select api.submit_agent_answer(
     (select payload ->> 'access_token' from res where label = 'tokens'),
     'https://antidep.example/mcp',
     (select (payload ->> 'task_handle')::uuid from res where label = 'claim'),
     (select jsonb_set(payload, '{identity,model}', '"en-helt-annen-modell"')
      from answers where label = 'runner')) ->> 'reason'),
  'rejected',
  'et svar fra en annen modell enn den tildelte, avvises'
);

-- Og avvisningen står i sporet, skrevet av leveringen selv.
reset role;
select is(
  (select e.self_reported
   from workflow.agent_runner_events e
   where e.tool_name = 'submit_agent_answer' and e.outcome = 'rejected'
   order by e.created_at desc
   limit 1),
  false,
  'og avvisningen står i sporet, skrevet av leveringen og ikke meldt inn'
);
set local role anon;

-- Og et svar avgitt på et annet grunnlag.
select is(
  (select api.submit_agent_answer(
     (select payload ->> 'access_token' from res where label = 'tokens'),
     'https://antidep.example/mcp',
     (select (payload ->> 'task_handle')::uuid from res where label = 'claim'),
     (select jsonb_set(payload, '{request_digest}',
                       to_jsonb('sha256:' || repeat('a', 64)))
      from answers where label = 'runner')) ->> 'reason'),
  'rejected',
  'et svar avgitt på et annet grunnlag, avvises'
);

-- Ukjente felter avvises, som i den manuelle veien.
select is(
  (select api.submit_agent_answer(
     (select payload ->> 'access_token' from res where label = 'tokens'),
     'https://antidep.example/mcp',
     (select (payload ->> 'task_handle')::uuid from res where label = 'claim'),
     (select payload || '{"notat":"noe modellen fant på"}'::jsonb
      from answers where label = 'runner')) ->> 'reason'),
  'rejected',
  'et svar med et felt kontrakten ikke kjenner, avvises'
);

-- Og teksten avvisningen kom med, står ikke i sporet: den kan navngi en påstand
-- eller et kildeutdrag, og går bare til kjøreren som allerede har materialet.
reset role;
select is(
  (select count(*)::int from workflow.agent_runner_events e
   where coalesce(e.note, '') like '%notat%'),
  0,
  'og feilteksten følger ikke med inn i sporet'
);
set local role anon;

insert into res
select 'submitted', api.submit_agent_answer(
  (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp',
  (select (payload ->> 'task_handle')::uuid from res where label = 'claim'),
  (select payload from answers where label = 'runner'));

select is(
  (select (payload ->> 'imported')::boolean from res where label = 'submitted'),
  true,
  'svaret registreres gjennom den samme skriveveien et opplastet svar.json går gjennom'
);
select is(
  (select payload ->> 'delivered_by' from res where label = 'submitted'),
  'autonomous_runner',
  'importsporet sier at svaret kom fra en autonom kjører'
);

-- Det samme svaret sendt inn igjen registrerer ingenting nytt.
insert into res
select 'submitted_again', api.submit_agent_answer(
  (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp',
  (select (payload ->> 'task_handle')::uuid from res where label = 'claim'),
  (select payload from answers where label = 'runner'));

select is(
  (select (payload ->> 'already_imported')::boolean from res where label = 'submitted_again'),
  true,
  'det samme svaret sendt inn igjen registrerer ingenting nytt'
);

-- Et ANNET svar på en besvart oppgave avvises — som en tilstand, og med sin
-- egen rad i sporet.
select is(
  (select api.submit_agent_answer(
     (select payload ->> 'access_token' from res where label = 'tokens'),
     'https://antidep.example/mcp',
     (select (payload ->> 'task_handle')::uuid from res where label = 'claim'),
     (select jsonb_set(payload, '{result,extraction,sample_size}', '99')
      from answers where label = 'runner')) ->> 'reason'),
  'rejected',
  'et annet svar på en besvart oppgave avvises'
);
reset role;

select is(
  (select count(*)::int from knowledge.evidence_items e
   where e.source_version_id = '79000000-0000-4000-8000-000000000002'),
  1,
  'gjentatte leveringer gir aldri doble kliniske artefakter'
);

-- Proveniensen bærer både registreringsidentiteten og den eksterne agenten som
-- faktisk gjorde arbeidet.
select is(
  (select format('%s/%s', r.semantic_provider, r.semantic_model)
   from workflow.agent_handoff_imports i
   join provenance.agent_runs r on r.id = i.agent_run_id
   where i.pipeline_job_id = (select (payload ->> 'pipeline_job_id')::uuid
                              from res where label = 'task')),
  'antidep-test/kjorer-modell-790',
  'kjøringen bærer den eksterne modellen som faktisk gjorde arbeidet'
);

-- Og importen navngir kjøreren som leverte det, uten å gjøre den til aktør:
-- ansvaret ligger hos mennesket som registrerte kjøreren.
select is(
  (select c.connection_key
   from workflow.agent_handoff_imports i
   join workflow.agent_runner_connections c on c.id = i.runner_connection_id
   where i.pipeline_job_id = (select (payload ->> 'pipeline_job_id')::uuid
                              from res where label = 'task')),
  'agent-runner:evidence-extraction',
  'importen navngir den autonome kjøreren som leverte svaret'
);
select is(
  (select i.imported_by_actor_id from workflow.agent_handoff_imports i
   where i.pipeline_job_id = (select (payload ->> 'pipeline_job_id')::uuid
                              from res where label = 'task')),
  'ac790000-0000-4000-8000-00000000000e'::uuid,
  'ansvaret føres på mennesket som registrerte kjøreren, ikke på kjøreren selv'
);

-- ===========================================================================
-- Del 7 — Sporet, leien og tilbaketrekkingen
-- ===========================================================================
select ok(
  exists (
    select 1 from workflow.agent_runner_events e
    where e.tool_name = 'submit_agent_answer' and e.outcome = 'ok'
  ),
  'sporet bærer verktøynavnet og utfallsklassen'
);
select is_empty(
  $$
    select e.id from workflow.agent_runner_events e
    where coalesce(e.note, '') like '%major depressive disorder%'
       or coalesce(e.note, '') like '%sertraline%'
  $$,
  'sporet bærer aldri kildetekst'
);

-- En utløpt leie er ledig igjen. Det er nettopp den tilstanden som skal
-- overleve at en planlagt kjøring døde midt i arbeidet.
select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
insert into res
select 'task2', api.enqueue_agent_task('evidence_extraction', jsonb_build_object(
  'source_version_id', '79000000-0000-4000-8000-000000000002',
  'drug_ids', jsonb_build_array((select id from ids where name = 'drug')),
  'outcome_concept_ids', jsonb_build_array((select id from ids where name = 'outcome'))
));
reset role;

set local role anon;
insert into res
select 'claim2', api.claim_agent_task(
  (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp', null, 900);
reset role;

-- Køen sier hvem som holder oppgaven. «Blokkert» er feil ord når arbeidet
-- pågår automatisk akkurat nå.
select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
insert into res select 'queue', jsonb_build_object('rows', api.agent_work_queue());
reset role;

select is(
  (select q ->> 'held_by_runner'
   from res, jsonb_array_elements(payload -> 'rows') as q
   where label = 'queue'
     and q ->> 'pipeline_job_id' = (select payload ->> 'pipeline_job_id' from res where label = 'task2')),
  'Antidep ekstraksjonskjører',
  'agentkøen sier hvilken autonom kjører som holder oppgaven akkurat nå'
);

-- Den manuelle veien kan ikke registrere det samme arbeidet mens kjøreren
-- holder uttaket. De to deler kø, leie og jobb, og kan derfor ikke doble noe.
select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$ select api.import_agent_answer(%L::uuid, %L::jsonb) $$,
    (select payload ->> 'pipeline_job_id' from res where label = 'task2'),
    (select payload from answers where label = 'runner')
  ),
  '23001',
  null,
  'den manuelle importen kan ikke overta en oppgave en autonom kjører holder'
);
reset role;

update workflow.pipeline_jobs
set lease_expires_at = statement_timestamp() - interval '1 minute'
where id = (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'task2');

set local role anon;
select is(
  (select api.agent_task_for_runner(
     (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp',
     (select (payload ->> 'task_handle')::uuid from res where label = 'claim2')) ->> 'reason'),
  'stale_task',
  'en kjøring med utløpt leie får ikke oppgaven ut igjen'
);

insert into res
select 'reclaim', api.claim_agent_task(
  (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp', null, 900);
select is(
  (select (payload ->> 'claimed')::boolean from res where label = 'reclaim'),
  true,
  'en oppgave med utløpt leie kan tas på nytt'
);
select isnt(
  (select payload ->> 'task_handle' from res where label = 'reclaim'),
  (select payload ->> 'task_handle' from res where label = 'claim2'),
  'det nye uttaket får sin egen nøkkel, så det gamle håndtaket treffer ingenting'
);

-- Og det foreldede håndtaket kan ikke levere et svar over det uttaket som nå
-- arbeider.
select is(
  (select api.submit_agent_answer(
     (select payload ->> 'access_token' from res where label = 'tokens'), 'https://antidep.example/mcp',
     (select (payload ->> 'task_handle')::uuid from res where label = 'claim2'),
     (select payload from answers where label = 'runner')) ->> 'reason'),
  'stale_task',
  'et svar fra en utløpt leie kan ikke skrive over uttaket som nå arbeider'
);
reset role;

-- Tilbaketrekkingen stopper tilgangen i det samme øyeblikket.
select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select throws_ok(
  $$ select api.revoke_agent_runner('agent-runner:evidence-extraction', '   ') $$,
  '22023',
  null,
  'en tilbaketrekking krever en begrunnelse'
);
insert into res
select 'revoke', api.revoke_agent_runner(
  'agent-runner:evidence-extraction', 'Prøve 790: kjøreren tas ut av bruk.');
reset role;

-- Arbeidet kjøreren holdt, blir ledig med det samme.
--
-- Uten dette ville uttaket stått til leien løp ut — normalt et kvarter, opptil
-- et døgn om kjøringen ba om det — mens kjøreren som holdt det, var død i det
-- samme øyeblikket. Erstatteren ville ikke fått gjort arbeidet i mellomtiden,
-- og køen ville meldt det som pågående hos noen som ikke lenger fantes.
select is(
  (select (payload ->> 'released_tasks')::int from res where label = 'revoke'),
  1,
  'tilbaketrekkingen frigir uttaket kjøreren holdt'
);
select ok(
  (select j.state = 'ready'
            and j.lease_token is null
            and j.lease_expires_at is null
            and j.leased_by_agent_identity_id is null
            and j.runner_connection_id is null
   from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'task2')),
  'oppgaven står som ledig igjen, uten en holder som ikke holder noe'
);
-- Forsøket står, som når en kjører selv gir oppgaven fra seg: uttaket ER et
-- forsøk, og et tall som telles ned igjen, ville vært en historikk skrevet om
-- til å se penere ut enn den var.
select is(
  (select j.attempts from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'task2')),
  2,
  'forsøket står: uttaket var et forsøk, og et tall telles ikke ned igjen'
);
select ok(
  exists (
    select 1 from workflow.pipeline_job_events pe
    where pe.pipeline_job_id = (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'task2')
      and pe.to_state = 'ready'
      and pe.actor_id is not null
      and pe.agent_identity_id is null
      and pe.note = 'Uttaket ble frigitt fordi kjøreren som holdt det, ble trukket tilbake.'
  ),
  'frigivelsen føres på mennesket som trakk kjøreren tilbake, med Antideps egen setning'
);
select ok(
  exists (
    select 1 from workflow.agent_runner_events e
    where e.tool_name = 'revoke_agent_runner'
      and e.outcome = 'lease_lost'
      and e.pipeline_job_id = (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'task2')
  ),
  'sporet skiller et tapt uttak fra de andre utfallene, så det kan telles for seg'
);
-- Og oppgaven er utførbar igjen for den som overtar leddet. Det var nettopp
-- dette den løpende leien hindret.
select is(
  (select workflow.agent_task_problem(j) from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'task2')),
  null,
  'oppgaven kan tas av erstatteren med det samme, framfor å vente ut leien'
);

select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
insert into res select 'queue2', jsonb_build_object('rows', api.agent_work_queue());
reset role;

-- Køen leser holderen av raden og ikke av en antakelse om hvem som pleier å
-- ta arbeid i rollen. Utledningen den erstattet, pekte etter en tilbaketrekking
-- på den NYE kjøreren — som aldri hadde tatt oppgaven.
select is(
  (select q ->> 'held_by_runner'
   from res, jsonb_array_elements(payload -> 'rows') as q
   where label = 'queue2'
     and q ->> 'pipeline_job_id' = (select payload ->> 'pipeline_job_id' from res where label = 'task2')),
  null,
  'og køen sier ikke lenger at noen holder den'
);

-- En holder uten et uttak er ikke en tilstand tabellen godtar, og regelen
-- ligger to steder med vilje: triggeren glemmer holderen i det raden forlater
-- «leased», slik at ingen skrivevei trenger å huske det, og CHECK-en står igjen
-- som fasit for den dagen noen skriver forbi triggeren.
update workflow.pipeline_jobs
set runner_connection_id = (select id from workflow.agent_runner_connections
                            where connection_key = 'agent-runner:evidence-extraction' limit 1)
where id = (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'task2');

select is(
  (select j.runner_connection_id from workflow.pipeline_jobs j
   where j.id = (select (payload ->> 'pipeline_job_id')::uuid from res where label = 'task2')),
  null,
  'en holder skrevet på en oppgave som ikke er tatt ut, blir glemt av triggeren'
);

-- Og uten triggeren: tabellen selv avviser den. Triggeren slås av for nøyaktig
-- denne ene setningen i prøvens egen transaksjon, slik at CHECK-en kan prøves
-- for seg — regelen skal holde også uten hjelperen.
set local session_replication_role = replica;
select throws_ok(
  format(
    $$ update workflow.pipeline_jobs
       set runner_connection_id = %L::uuid
       where id = %L::uuid $$,
    (select id from workflow.agent_runner_connections
     where connection_key = 'agent-runner:evidence-extraction' limit 1),
    (select payload ->> 'pipeline_job_id' from res where label = 'task2')
  ),
  '23514',
  null,
  'og tabellen selv avviser den, også om noen skriver forbi triggeren'
);
set local session_replication_role = origin;

set local role anon;
select throws_ok(
  format($$ select api.list_pending_agent_tasks(%L, 'https://antidep.example/mcp') $$,
         (select payload ->> 'access_token' from res where label = 'tokens')),
  '42501',
  null,
  'et token slutter å gjelde i det samme øyeblikket kjøreren trekkes tilbake'
);
select throws_ok(
  format($$ select api.refresh_agent_runner_token(%L, %L, 'https://antidep.example/mcp') $$,
         (select payload ->> 'refresh_token' from res where label = 'tokens'),
         (select payload ->> 'client_id' from res where label = 'client')),
  '42501',
  null,
  'og en tilbaketrukket tilkobling kan ikke fornyes'
);
reset role;

-- Historikken består. En kjører som har hentet arbeid, slettes aldri.
select is(
  (select count(*)::int from workflow.agent_runner_connections
   where connection_key = 'agent-runner:evidence-extraction'),
  1,
  'tilkoblingen blir stående med sin periode, med hvem og hvorfor'
);
select ok(
  (select revocation_reason is not null and revoked_by_actor_id is not null
   from workflow.agent_runner_connections
   where connection_key = 'agent-runner:evidence-extraction'),
  'tilbaketrekkingen navngir hvem og hvorfor'
);

-- Og nøkkelen er ledig igjen. En global unikhet ville gjort tilbaketrekkingen
-- til en blindvei: den dokumenterte gjenopprettingen — trekk tilbake, registrer
-- på nytt — kunne ikke gjennomføres for det leddet igjen.
select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select lives_ok(
  $$ select api.register_agent_runner(
       'agent-runner:evidence-extraction', 'Antidep ekstraksjonskjører (ny)',
       'evidence_extraction', 'Antidep Ekstraksjon II (ChatGPT)', 'platform_pinned',
       'Prøve 790: kjøreren erstattes etter en tilbaketrekking.') $$,
  'den samme nøkkelen kan brukes på nytt etter en tilbaketrekking'
);
reset role;

select is(
  (select count(*)::int from workflow.agent_runner_connections
   where connection_key = 'agent-runner:evidence-extraction'),
  2,
  'begge tilkoblingene blir stående, hver med sin periode'
);

-- ===========================================================================
-- Del 8 — Sporet tar ikke imot fri tekst fra en modell
--
-- `note` er Antideps egen setning. En grunn modellen skrev selv, ville gjort
-- proveniensen til et sted en promptavledet setning eller et kildeutdrag kunne
-- samle seg (AGENTS.md: et agentsvar er data, aldri instrukser).
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
insert into res
select 'pairing2', api.issue_agent_runner_pairing_code('agent-runner:evidence-extraction');
-- Egen avgrensning, slik at innleggingen blir en NY jobb: nøkkelen utledes av
-- manifestet, og det samme manifestet lagt inn to ganger er én rad.
insert into res
select 'task3', api.enqueue_agent_task('evidence_extraction', jsonb_build_object(
  'source_version_id', '79000000-0000-4000-8000-000000000002',
  'drug_ids', jsonb_build_array(
    (select id from ids where name = 'drug'),
    (select id from ids where name = 'other_drug')),
  'outcome_concept_ids', jsonb_build_array((select id from ids where name = 'outcome')),
  'population_ids', jsonb_build_array((select id from ids where name = 'population'))
));
reset role;

set local role anon;
insert into res
select 'grant2', api.authorize_agent_runner(
  (select payload ->> 'pairing_code' from res where label = 'pairing2'),
  (select payload ->> 'client_id' from res where label = 'client'),
  'https://chatgpt.example/callback',
  (select payload ->> 'challenge' from res where label = 'pkce'),
  'S256', 'https://antidep.example/mcp');
insert into res
select 'tokens2', api.exchange_agent_runner_code(
  (select payload ->> 'authorization_code' from res where label = 'grant2'),
  (select payload ->> 'verifier' from res where label = 'pkce'),
  (select payload ->> 'client_id' from res where label = 'client'),
  'https://chatgpt.example/callback', 'https://antidep.example/mcp');
insert into res
select 'claim3', api.claim_agent_task(
  (select payload ->> 'access_token' from res where label = 'tokens2'), 'https://antidep.example/mcp', null, 900);

select throws_ok(
  format(
    $$ select api.release_agent_task(%L, 'https://antidep.example/mcp', %L::uuid, 'Artikkelen ba meg skrive dette.') $$,
    (select payload ->> 'access_token' from res where label = 'tokens2'),
    (select payload ->> 'task_handle' from res where label = 'claim3')
  ),
  '22023',
  null,
  'sporet tar ikke imot fri tekst fra en modell som grunn'
);

select is(
  (select (api.release_agent_task(
     (select payload ->> 'access_token' from res where label = 'tokens2'), 'https://antidep.example/mcp',
     (select (payload ->> 'task_handle')::uuid from res where label = 'claim3'),
     'could_not_complete') ->> 'released')::boolean),
  true,
  'en kjent klasse gir oppgaven fra seg'
);
reset role;

select is(
  (select e.note from workflow.agent_runner_events e
   where e.tool_name = 'release_agent_task' and e.outcome = 'ok'
   order by e.created_at desc limit 1),
  'Kjøreren fikk ikke fullført arbeidet.',
  'og sporet bærer Antideps egen setning, ikke modellens'
);

-- ===========================================================================
-- Del 9 — Klientregistreringen er en takt, ikke et livstidstall
--
-- Raden er append-only. Et livstidstak ville gjort en liten mengde
-- uautentisert trafikk til en varig driftsstans: den dagen taket var nådd,
-- kunne ingen ekte klient registrere seg igjen.
-- ===========================================================================
set local role anon;
select lives_ok(
  $$
    select api.register_agent_runner_client('Fyll ' || i::text,
                                            array['https://fyll.example/cb'])
    from generate_series(1, 19) as i
  $$,
  'nitten klienter til registreres innenfor vinduet'
);
select throws_ok(
  $$ select api.register_agent_runner_client('En til', array['https://fyll.example/cb']) $$,
  '23001',
  null,
  'og den neste avvises når takten er brukt opp'
);
reset role;

-- Vinduet går over av seg selv. Flyttes de eldre registreringene ut av timen,
-- er veien åpen igjen — og oppsettet kan fullføres.
-- Tiden flyttes framfor å ventes ut, og append-only-regelen slås av for
-- nøyaktig denne ene setningen i prøvens egen transaksjon. Prøven skal si noe
-- om vinduet, ikke om klokka — og ikke svekke regelen for noen andre.
set local session_replication_role = replica;
update workflow.agent_runner_clients
set created_at = statement_timestamp() - interval '2 hours'
where client_name like 'Fyll %';
set local session_replication_role = origin;

set local role anon;
select lives_ok(
  $$ select api.register_agent_runner_client('Etter vinduet', array['https://fyll.example/cb']) $$,
  'en flom av registreringer går over av seg selv, framfor å stenge veien for alltid'
);
reset role;

-- ===========================================================================
-- Del 9b — Tokenet er bundet til én navngitt MCP-server (RFC 8707)
--
-- Et token uten publikum passer overalt. MCP-spesifikasjonen krever at
-- klienten navngir serveren i både autorisasjons- og tokenforespørselen, og at
-- serveren avviser et token som ble utstedt for en annen: uten den kontrollen
-- er Antidep den forvirrede stedfortrederen som tar imot andres legitimasjon.
-- ===========================================================================
set local role anon;
select throws_ok(
  format(
    $$ select api.authorize_agent_runner(%L, %L, 'https://chatgpt.example/callback', %L, 'S256', null) $$,
    (select payload ->> 'pairing_code' from res where label = 'pairing2'),
    (select payload ->> 'client_id' from res where label = 'client'),
    (select payload ->> 'challenge' from res where label = 'pkce')
  ),
  '22023',
  null,
  'en autorisasjon uten resource avvises: et token uten publikum passer overalt'
);
select throws_ok(
  format(
    $$ select api.authorize_agent_runner(%L, %L, 'https://chatgpt.example/callback', %L, 'S256',
                                         'antidep.example/mcp') $$,
    (select payload ->> 'pairing_code' from res where label = 'pairing2'),
    (select payload ->> 'client_id' from res where label = 'client'),
    (select payload ->> 'challenge' from res where label = 'pkce')
  ),
  '22023',
  null,
  'og en adresse uten skjema er ikke en kanonisk ressursadresse'
);
reset role;

-- Tokenet bærer publikumet sitt, og kontrollen leser det.
select is(
  (select s.resource from workflow.agent_runner_secrets s
   where s.kind = 'access_token'
     and s.secret_hash = workflow.agent_runner_secret_hash(
       'access_token', (select payload ->> 'access_token' from res where label = 'tokens2'))),
  'https://antidep.example/mcp',
  'access-tokenet bærer den MCP-serveren det ble utstedt for'
);

set local role anon;
select throws_ok(
  format(
    $$ select api.agent_runner_identity(%L, 'https://en-annen.example/mcp') $$,
    (select payload ->> 'access_token' from res where label = 'tokens2')
  ),
  '42501',
  null,
  'et gyldig token avvises for en MCP-server det ikke ble utstedt for'
);
-- Og publikumet er ikke valgfritt. Med en standardverdi ville kontrollen bare
-- vært kjørt av de kallerne som husket å oppgi den — og veiene er gitt til
-- `anon`, så en som holder et token, kunne gått utenom MCP-serveren og rett på
-- Data API-et uten den.
select throws_ok(
  format(
    $$ select api.agent_runner_identity(%L, null) $$,
    (select payload ->> 'access_token' from res where label = 'tokens2')
  ),
  '22023',
  null,
  'et kall uten publikum avvises: kontrollen skal gjelde uansett hvem som kaller'
);
reset role;

-- Publikumet kan ikke skifte underveis: verken i innvekslingen eller i
-- fornyelsen kan en kode eller et refresh-token for denne appen bli et token
-- for en annen.
set local role anon;
select throws_ok(
  format(
    $$ select api.refresh_agent_runner_token(%L, %L, 'https://en-annen.example/mcp') $$,
    (select payload ->> 'refresh_token' from res where label = 'tokens2'),
    (select payload ->> 'client_id' from res where label = 'client')
  ),
  '42501',
  null,
  'og et refresh-token kan ikke veksles inn i et token for en annen server'
);
reset role;

-- Og kontrollen gjelder ARBEIDSVEIENE, ikke bare identiteten.
--
-- Det er hele poenget: funksjonene er gitt til `anon`, og en som holder et
-- token, kan kalle Data API-et direkte uten å gå gjennom MCP-serveren. Var
-- publikumskontrollen bare i transportlaget, ville den vært en kontroll man
-- kunne gå utenom (ANTIDEP_CONSTITUTION.md regel 7).
set local role anon;
select throws_ok(
  format(
    $$ select api.list_pending_agent_tasks(%L, 'https://en-annen.example/mcp') $$,
    (select payload ->> 'access_token' from res where label = 'tokens2')
  ),
  '42501',
  null,
  'køen kan ikke leses med et token utstedt for en annen MCP-server'
);
select throws_ok(
  format(
    $$ select api.claim_agent_task(%L, 'https://en-annen.example/mcp', null, 900) $$,
    (select payload ->> 'access_token' from res where label = 'tokens2')
  ),
  '42501',
  null,
  'og ingen oppgave kan tas ut med det'
);
select throws_ok(
  format(
    $$ select api.submit_agent_answer(%L, 'https://en-annen.example/mcp',
                                      '11111111-2222-4333-8444-555555555555'::uuid, '{}'::jsonb) $$,
    (select payload ->> 'access_token' from res where label = 'tokens2')
  ),
  '42501',
  null,
  'og ingen svar kan leveres med det'
);
select throws_ok(
  format(
    $$ select api.list_pending_agent_tasks(%L, null) $$,
    (select payload ->> 'access_token' from res where label = 'tokens2')
  ),
  '22023',
  null,
  'og en arbeidsvei uten publikum avvises, framfor å hoppe over kontrollen'
);
reset role;

-- Og publikumet kan ikke skrives om etter utstedelsen. Det er en del av det som
-- ble gitt, ikke en etikett på det: en oppdatering som kunne peke et allerede
-- utstedt token mot en annen MCP-server, ville latt raden beskrive en annen
-- binding enn den som faktisk ble gitt.
select throws_ok(
  $$
    update workflow.agent_runner_secrets
    set resource = 'https://en-annen.example/mcp'
    where kind = 'access_token' and revoked_at is null
  $$,
  '23001',
  null,
  'publikumet på en utstedt hemmelighet kan ikke skrives om'
);

-- Tabellen selv krever publikumet: en rad uten det er ikke en lovlig tilstand.
select throws_ok(
  $$
    insert into workflow.agent_runner_secrets
      (kind, secret_hash, connection_id, client_id, expires_at)
    select 'access_token', 'sha256-v1:' || repeat('9', 64), c.id, k.client_id,
           statement_timestamp() + interval '1 hour'
    from workflow.agent_runner_connections c, workflow.agent_runner_clients k
    where c.connection_key = 'agent-runner:evidence-extraction' and c.valid_to is null
    limit 1
  $$,
  '23514',
  null,
  'et token uten publikum kan ikke lagres i det hele tatt'
);

-- ===========================================================================
-- Del 10 — Rotasjonen gjelder ett token-par, ikke tilkoblingen
--
-- En tilkobling kan ha flere levende par: en ny tilkoblingskode gir en ny
-- autorisasjon. En fornyelse som trakk tilbake alle access-tokenene på
-- tilkoblingen, ville latt to lovlige kjøringer slå hverandre ut annenhver
-- gang — uten at noe var galt, og uten at noe i sporet forklarte hvorfor.
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
insert into res
select 'pairing3', api.issue_agent_runner_pairing_code('agent-runner:evidence-extraction');
reset role;

set local role anon;
insert into res
select 'grant3', api.authorize_agent_runner(
  (select payload ->> 'pairing_code' from res where label = 'pairing3'),
  (select payload ->> 'client_id' from res where label = 'client'),
  'https://chatgpt.example/callback',
  (select payload ->> 'challenge' from res where label = 'pkce'),
  'S256', 'https://antidep.example/mcp');
insert into res
select 'tokens3', api.exchange_agent_runner_code(
  (select payload ->> 'authorization_code' from res where label = 'grant3'),
  (select payload ->> 'verifier' from res where label = 'pkce'),
  (select payload ->> 'client_id' from res where label = 'client'),
  'https://chatgpt.example/callback', 'https://antidep.example/mcp');

select is(
  (select api.agent_runner_identity(
     (select payload ->> 'access_token' from res where label = 'tokens3'),
     'https://antidep.example/mcp') ->> 'agent_role'),
  'evidence_extraction',
  'den samme tilkoblingen kan ha to levende autorisasjoner'
);

-- Det eldste paret fornyes. Det er det yngste som ikke skal merke det.
insert into res
select 'fornyet', api.refresh_agent_runner_token(
  (select payload ->> 'refresh_token' from res where label = 'tokens2'),
  (select payload ->> 'client_id' from res where label = 'client'),
  'https://antidep.example/mcp');

-- `lives_ok` og ikke `is`: slår regelen feil, er utfallet en avvisning, og en
-- avvisning midt i en `is` ville avbrutt hele filen framfor å melde nøyaktig
-- hvilken regel som sviktet.
select lives_ok(
  format($$ select api.agent_runner_identity(%L, 'https://antidep.example/mcp') $$,
         (select payload ->> 'access_token' from res where label = 'tokens3')),
  'en fornyelse av det ene paret rører ikke det andre'
);
select is(
  (select api.agent_runner_identity(
     (select payload ->> 'access_token' from res where label = 'fornyet'),
     'https://antidep.example/mcp') ->> 'agent_role'),
  'evidence_extraction',
  'og det fornyede paret har fått et nytt, gyldig access-token'
);
-- Men rotasjonen skal koste det paret som faktisk ble rotert: et lekket
-- access-token skal ikke overleve at refresh-tokenet sitt ble brukt opp.
select throws_ok(
  format($$ select api.agent_runner_identity(%L, 'https://antidep.example/mcp') $$,
         (select payload ->> 'access_token' from res where label = 'tokens2')),
  '42501',
  null,
  'mens det rotertes eget gamle access-token er trukket tilbake'
);
reset role;

select throws_ok(
  $$ delete from workflow.agent_runner_events $$,
  '23001',
  null,
  'sporet etter en kjøring skrives ikke om'
);

-- ===========================================================================
-- Del 11 — Sporet kan ikke fylles med hendelser som ikke fant sted
--
-- `api.record_agent_runner_outcome` finnes fordi en avvisning fra den
-- autoritative kontrollen ruller transaksjonen tilbake, sporet inkludert. Den
-- er gitt til anon som resten av kjørerveiene, og en tokeninnehaver kan derfor
-- kalle den direkte. Da må den ikke kunne brukes til å skrive at noe LYKTES:
-- et kall som lyktes, rullet ikke tilbake, og skrev sin egen rad.
-- ===========================================================================
set local role anon;

select throws_ok(
  format($$ select api.record_agent_runner_outcome(%L, 'https://antidep.example/mcp',
                                                   'submit_agent_answer', 'ok') $$,
         (select payload ->> 'access_token' from res where label = 'fornyet')),
  '22023',
  null,
  'en tokeninnehaver kan ikke melde inn at et verktøykall lyktes'
);

select throws_ok(
  format($$ select api.record_agent_runner_outcome(%L, 'https://antidep.example/mcp',
                                                   'revoke_agent_runner', 'server_error') $$,
         (select payload ->> 'access_token' from res where label = 'fornyet')),
  '22023',
  null,
  'og ikke skrive en rad under navnet på noe bare Antidep selv skriver'
);

-- Men utfallet av et kall som gikk galt, skal den fortsatt kunne melde inn:
-- det er hele grunnen til at veien finnes.
select lives_ok(
  format($$ select api.record_agent_runner_outcome(%L, 'https://antidep.example/mcp',
                                                   'submit_agent_answer', 'rejected') $$,
         (select payload ->> 'access_token' from res where label = 'fornyet')),
  'et kall som gikk galt, kan fortsatt melde inn utfallet sitt'
);

reset role;

-- Og raden bærer at den er en selvmelding. Skillet står i raden, ikke i et
-- dokument: en rad operasjonen selv skrev, kan ikke stå der uten at operasjonen
-- fant sted — en innmeldt rad sier bare hva kjøreren sa.
select is(
  (select e.self_reported
   from workflow.agent_runner_events e
   where e.self_reported
   order by e.created_at desc
   limit 1),
  true,
  'en innmeldt rad står som innmeldt'
);

select is(
  (select count(*)::int from workflow.agent_runner_events e
   where e.self_reported and e.outcome = 'ok'),
  0,
  'og ingen innmeldt rad påstår at noe lyktes'
);

-- ===========================================================================
-- Del 12 — Tilkoblingen står ved lag mellom kjøringene
--
-- Et access-token lever i én time. En planlagt kjøring som går én gang i
-- døgnet, har derfor ikke noe levende access-token mesteparten av tiden, og en
-- flate som leste nettopp det, ville sagt «ikke tilkoblet» om en tilkobling som
-- virker helt som den skal.
-- ===========================================================================
update workflow.agent_runner_secrets
set revoked_at = statement_timestamp()
where kind = 'access_token' and revoked_at is null;

select set_config('request.jwt.claims',
                  '{"sub":"79000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select is(
  (select (r ->> 'connected')::boolean
   from jsonb_array_elements(api.agent_runner_connections()) r
   where r ->> 'connection_key' = 'agent-runner:evidence-extraction'),
  true,
  'uten et eneste levende access-token står tilkoblingen fortsatt ved lag'
);
reset role;

-- Men fornyelsesretten er grensen: uten den er den faktisk borte.
update workflow.agent_runner_secrets
set revoked_at = statement_timestamp()
where kind = 'refresh_token' and revoked_at is null;

set local role authenticated;
select is(
  (select (r ->> 'connected')::boolean
   from jsonb_array_elements(api.agent_runner_connections()) r
   where r ->> 'connection_key' = 'agent-runner:evidence-extraction'),
  false,
  'og uten fornyelsesrett er den ikke tilkoblet lenger'
);
reset role;

select * from finish();
rollback;
