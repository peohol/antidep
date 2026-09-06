-- Migrasjon 005d, 005e og 005f — teknisk agentidentitet: struktur og
-- tilgangsflate.
--
-- Filen dekker det som er sant om formen: at tabellene finnes med de nøklene og
-- speilkolonnene som gjør separasjonen håndhevbar, at ingen klientrolle kommer
-- til dem, at de to api-funksjonene er de eneste inngangspunktene, og at
-- legitimasjonsmaterialet ikke er eksponert noe sted. Autentisering og
-- legitimasjonens livssyklus prøves i 420, kjøringene i 430.
--
-- SQLSTATE 42501 = insufficient_privilege, 23001 = restrict_violation,
-- 23503 = foreign_key_violation, 23505 = unique_violation,
-- 23514 = check_violation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(40);

-- ===========================================================================
-- Del 1 — Tabellene og nøklene som bærer separasjonen
-- ===========================================================================
select has_table(
  'provenance', 'agent_identities', 'provenance.agent_identities finnes'
);
select has_table('provenance', 'agent_runs', 'provenance.agent_runs finnes');

select col_is_pk(
  'provenance', 'agent_identities', 'id',
  'provenance.agent_identities har uuid-primærnøkkel'
);
select col_is_pk(
  'provenance', 'agent_runs', 'id', 'provenance.agent_runs har uuid-primærnøkkel'
);

-- Én identitet per aktør. Uten regelen kunne samme agentaktør hatt to
-- legitimasjoner, og en tilbakekalling ville ikke vært en tilbakekalling.
select col_is_unique(
  'provenance', 'agent_identities', array['actor_id'],
  'én teknisk identitet per agentaktør'
);
select col_is_unique(
  'provenance', 'agent_identities', array['identity_key'],
  'identitetsnøkkelen er unik og er navnet en kjører autentiserer seg med'
);

-- Speilkolonnene er det som gjør at en senere skrivevei kan kreve deklarativt at
-- en verifikasjon peker på en kjøring i riktig rolle, utført av riktig aktør
-- (DATABASE_ARCHITECTURE.md §59). Uten de unike nøklene finnes ikke den
-- muligheten, og kontrollen ville måttet skrives i funksjonskode hver gang.
select col_is_unique(
  'provenance', 'agent_identities', array['id', 'agent_role'],
  '(id, agent_role) på identiteten er refererbar'
);
select col_is_unique(
  'provenance', 'agent_identities', array['id', 'actor_id'],
  '(id, actor_id) på identiteten er refererbar'
);
select col_is_unique(
  'provenance', 'agent_runs', array['id', 'agent_role'],
  '(id, agent_role) på kjøringen er refererbar'
);
select col_is_unique(
  'provenance', 'agent_runs', array['id', 'actor_id'],
  '(id, actor_id) på kjøringen er refererbar'
);

-- ===========================================================================
-- Del 2 — Reglene som ikke kan omgås
-- ===========================================================================

-- En identitet kan ikke peke på et menneske, en deterministisk prosess eller en
-- systemaktør: agent_role er NOT NULL på identiteten, og aktørens agent_role er
-- satt hvis og bare hvis aktørtypen er agent. Den ene fremmednøkkelen bærer
-- begge deler.
select throws_ok(
  $$
    insert into provenance.agent_identities
      (actor_id, agent_role, identity_key,
       registered_by_actor_id, registered_by_actor_type, registration_reason)
    select a.id, 'evidence_extraction', 'agent-identity:menneske-som-agent',
           a.id, 'human', 'Prøver å gi et menneske en maskinidentitet.'
    from provenance.actors a where a.actor_key = 'human:peder-holman'
  $$,
  '23503', null,
  'en agentidentitet kan ikke peke på en aktør som ikke er en agent'
);

-- Bare et menneske kan gi en maskin rett til å handle (CONTENT_GOVERNANCE.md
-- §14). En agent som kunne registrere agenter, ville vært en
-- rettighetseskalering med ett ekstra ledd.
select throws_ok(
  $$
    insert into provenance.agent_identities
      (actor_id, agent_role, identity_key,
       registered_by_actor_id, registered_by_actor_type, registration_reason)
    select v.id, 'extraction_verification', 'agent-identity:selvregistrert',
           e.id, 'agent', 'En agent som registrerer en agent.'
    from provenance.actors v, provenance.actors e
    where v.actor_key = 'agent:claim-synthesis'
      and e.actor_key = 'agent:evidence-extraction'
  $$,
  '23514', null,
  'en agent kan ikke registrere en agentidentitet; registratoren må være et menneske'
);

-- Identitetens rolle er aktørens rolle, ikke en verdi den kan velge selv. En
-- identitet som kunne oppgi en annen rolle enn aktøren har, ville vært nettopp
-- den selvtildelte rettigheten hele modellen skal hindre.
select throws_ok(
  $$
    insert into provenance.agent_identities
      (actor_id, agent_role, identity_key,
       registered_by_actor_id, registered_by_actor_type, registration_reason)
    select e.id, 'claim_synthesis', 'agent-identity:feil-rolle',
           h.id, 'human', 'Prøver å gi ekstraksjonsagenten synteserollen.'
    from provenance.actors e, provenance.actors h
    where e.actor_key = 'agent:evidence-extraction'
      and h.actor_key = 'human:peder-holman'
  $$,
  '23503', null,
  'en identitet kan ikke ha en annen rolle enn aktøren sin'
);

-- En tilbakekalling skal ikke kunne skje i stillhet.
select throws_ok(
  $$
    update provenance.agent_identities
    set valid_to = now()
    where identity_key = 'agent-identity:extraction-verification-01'
  $$,
  '23514', null,
  'en tilbakekalling uten aktør og begrunnelse avvises'
);

-- Ingen identitet kan slettes; tilbakekalling er en statusendring
-- (ANTIDEP_CONSTITUTION.md §14).
select throws_ok(
  $$delete from provenance.agent_identities$$,
  '23001', null,
  'en agentidentitet kan ikke slettes, bare trekkes tilbake'
);

-- To rettighetsendringer i én operasjon ville gitt én auditrad for begge, og
-- auditskriveren kan bare registrere én per rad. Kombinasjonen er derfor umulig
-- framfor underauditert.
select throws_ok(
  $$
    update provenance.agent_identities ai
    set valid_to = now(),
        revoked_by_actor_id = (select id from provenance.actors where actor_key = 'human:peder-holman'),
        revoked_by_actor_type = 'human',
        revocation_reason = 'Prøve i 410.',
        secret_hash = 'sha256-v1:' || repeat('a', 64),
        secret_version = ai.secret_version + 1,
        secret_issued_at = now(),
        secret_issued_by_actor_id = (select id from provenance.actors where actor_key = 'human:peder-holman'),
        secret_issued_by_actor_type = 'human'
    where ai.identity_key = 'agent-identity:extraction-verification-01'
  $$,
  '23001', null,
  'en identitet kan ikke trekkes tilbake og få ny legitimasjon i samme operasjon'
);

-- Legitimasjonens fire felter flytter seg sammen eller ikke i det hele tatt.
-- Auditskriveren registrerer en utstedelse på at hashen endret seg, så en
-- skriving som beholdt hashen og likevel skrev om versjonstallet,
-- utstedelsestidspunktet eller utstederen, ville omskrevet legitimasjonens
-- historikk uten å legge igjen en eneste auditrad.
select throws_ok(
  $$
    update provenance.agent_identities
    set secret_version = secret_version + 1
    where identity_key = 'agent-identity:extraction-verification-01'
  $$,
  '23001', null,
  'versjonstallet kan ikke endres uten at legitimasjonen selv endres'
);
select throws_ok(
  $$
    update provenance.agent_identities
    set secret_issued_at = now(),
        secret_issued_by_actor_id = (select id from provenance.actors where actor_key = 'human:peder-holman'),
        secret_issued_by_actor_type = 'human'
    where identity_key = 'agent-identity:extraction-verification-01'
  $$,
  '23001', null,
  'utstedelsestidspunkt og utsteder kan ikke skrives om uten en faktisk utstedelse'
);

-- En identitet begynner alltid inert. Auditskriveren registrerer en INSERT som
-- nøyaktig én hendelse, så en registrering som samtidig utstedte legitimasjon
-- eller trakk identiteten tilbake, ville utført to rettighetsendringer til og
-- bare loggført den ene.
select throws_ok(
  $$
    insert into provenance.agent_identities
      (actor_id, agent_role, identity_key,
       registered_by_actor_id, registered_by_actor_type, registration_reason,
       secret_hash, secret_version, secret_issued_at,
       secret_issued_by_actor_id, secret_issued_by_actor_type)
    select e.id, 'evidence_extraction', 'agent-identity:ferdig-credentialed',
           h.id, 'human', 'Registrert med legitimasjon allerede utstedt.',
           'sha256-v1:' || repeat('a', 64), 1, now(), h.id, 'human'
    from provenance.actors e, provenance.actors h
    where e.actor_key = 'agent:evidence-extraction'
      and h.actor_key = 'human:peder-holman'
  $$,
  '23001', null,
  'en agentidentitet kan ikke registreres med legitimasjon allerede utstedt'
);
select throws_ok(
  $$
    insert into provenance.agent_identities
      (actor_id, agent_role, identity_key,
       registered_by_actor_id, registered_by_actor_type, registration_reason,
       valid_to, revoked_by_actor_id, revoked_by_actor_type, revocation_reason)
    select e.id, 'evidence_extraction', 'agent-identity:ferdig-tilbakekalt',
           h.id, 'human', 'Registrert som allerede tilbakekalt.',
           now() + interval '1 hour', h.id, 'human', 'Tilbakekalt ved registrering.'
    from provenance.actors e, provenance.actors h
    where e.actor_key = 'agent:evidence-extraction'
      and h.actor_key = 'human:peder-holman'
  $$,
  '23001', null,
  'en agentidentitet kan ikke registreres som allerede tilbakekalt'
);

-- Den som utfører handlingen, må kunne utføre handlinger. Uten regelen ville en
-- tilbaketrukket redaktør kunne stå som den som ga en maskin evnen til å handle,
-- og auditraden ville påstått at vedkommende gjorde det.
select throws_ok(
  $$
    do $probe$
    begin
      update provenance.actors
      set retired_at = now(), retirement_note = 'Prøve i 410.'
      where actor_key = 'human:peder-holman';

      insert into provenance.agent_identities
        (actor_id, agent_role, identity_key,
         registered_by_actor_id, registered_by_actor_type, registration_reason)
      select e.id, 'evidence_extraction', 'agent-identity:registrert-av-tilbaketrukket',
             h.id, 'human', 'Registrert av en tilbaketrukket aktør.'
      from provenance.actors e, provenance.actors h
      where e.actor_key = 'agent:evidence-extraction'
        and h.actor_key = 'human:peder-holman';
    end
    $probe$
  $$,
  '23001', null,
  'en tilbaketrukket aktør kan ikke stå som registrator for en agentidentitet'
);

-- Den andre enden av samme regel: en identitet kan ikke opprettes for en
-- agentaktør som er tatt ut av bruk. Rettigheten ville ligget der og ventet på
-- at aktøren ble reaktivert.
select throws_ok(
  $$
    do $probe$
    begin
      update provenance.actors
      set retired_at = now(), retirement_note = 'Prøve i 410.'
      where actor_key = 'agent:evidence-extraction';

      insert into provenance.agent_identities
        (actor_id, agent_role, identity_key,
         registered_by_actor_id, registered_by_actor_type, registration_reason)
      select e.id, 'evidence_extraction', 'agent-identity:tilbaketrukket-aktor',
             h.id, 'human', 'Identitet for en tilbaketrukket agentaktør.'
      from provenance.actors e, provenance.actors h
      where e.actor_key = 'agent:evidence-extraction'
        and h.actor_key = 'human:peder-holman';
    end
    $probe$
  $$,
  '23001', null,
  'en agentidentitet kan ikke opprettes for en agentaktør som er trukket tilbake'
);

-- ===========================================================================
-- Del 3 — Tilgangsflaten
-- ===========================================================================
select ok(
  (select c.relrowsecurity from pg_class c
   where c.oid = 'provenance.agent_identities'::regclass),
  'RLS er aktivert på provenance.agent_identities'
);
select ok(
  (select c.relrowsecurity from pg_class c
   where c.oid = 'provenance.agent_runs'::regclass),
  'RLS er aktivert på provenance.agent_runs'
);

-- Uttømmende over begge tabellene og alle klientrollene, på kolonnenivå også: et
-- kolonnegrant ligger i pg_attribute.attacl og er ikke synlig i
-- has_table_privilege(), så en regel som bare leste relacl ville sluttet å måle
-- (samme blindsone som 030_conventions_test.sql beskriver).
select is_empty(
  $$
    select t.table_name || ':' || r.role_name || ':' || p.privilege
    from (values ('provenance.agent_identities'), ('provenance.agent_runs'))
           as t(table_name)
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'))
           as p(privilege)
    where has_table_privilege(r.role_name, t.table_name, p.privilege)
  $$,
  'ingen klientrolle har noen tabellrettighet på agentidentitetene eller agentkjøringene'
);
select is_empty(
  $$
    select n.nspname || '.' || c.relname || '.' || a.attname || ':' || r.role_name
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    where c.relname in ('agent_identities', 'agent_runs')
      and n.nspname = 'provenance'
      and has_column_privilege(r.role_name, c.oid, a.attnum, 'SELECT')
  $$,
  'ingen klientrolle kan lese noen kolonne på agentidentitetene eller agentkjøringene'
);

-- Legitimasjonsmaterialet skal ikke kunne nås gjennom kontraktslaget heller. En
-- senere lesemodell over agentkjøringer er tenkelig; en over hashen er det ikke.
select is_empty(
  $$
    select v.viewname
    from pg_views v
    where v.schemaname = 'api'
      and position('secret_hash' in v.definition) > 0
  $$,
  'ingen api-view eksponerer legitimasjonshashen'
);

-- ===========================================================================
-- Del 4 — Inngangspunktene
-- ===========================================================================
select has_function('api', 'begin_agent_run', 'api.begin_agent_run() finnes');
select has_function('api', 'complete_agent_run', 'api.complete_agent_run() finnes');
select has_function(
  'provenance', 'authenticate_agent_identity',
  'provenance.authenticate_agent_identity() finnes'
);
select has_function(
  'provenance', 'issue_agent_identity_credential',
  'provenance.issue_agent_identity_credential() finnes'
);
select has_function(
  'provenance', 'assert_agent_run_open', 'provenance.assert_agent_run_open() finnes'
);

-- §74.32: sjekken av at kjøringen er åpen må ta radlås på agentkjøringsraden,
-- ellers kan en samtidig api.complete_agent_run(...) lukke kjøringen mellom
-- sjekk og den påfølgende INSERT-en i den kallende skriveveien. En pgTAP-test
-- kjører i én sesjon og kan ikke observere en annen transaksjon blokkere (se
-- samme forbehold i 260_publication_operations_test.sql); assersjonen her
-- viser i stedet, som der, at implementasjonen faktisk tar FOR UPDATE. Fjernes
-- den, feiler testen.
select ok(
  (select p.prosrc from pg_proc p
   where p.oid = 'provenance.assert_agent_run_open(uuid,uuid)'::regprocedure)
    ~ 'provenance\.agent_runs[^;]*for update',
  'provenance.assert_agent_run_open() låser agentkjøringsraden med FOR UPDATE før den leser status'
);
select has_trigger(
  'provenance', 'agent_identities', 'agent_identities_record_audit_event',
  'enhver endring i en agentidentitets rettigheter auditeres'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.begin_agent_run(text,text,text,text,text,text,text,text,jsonb)'::regprocedure),
  'api.begin_agent_run() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.complete_agent_run(text,text,uuid,text,jsonb,text)'::regprocedure),
  'api.complete_agent_run() er SECURITY DEFINER'
);
-- Auditskriveren skal aldri være mer privilegert enn operasjonen den
-- registrerer, som de fire auditskriverne før den.
select ok(
  not (select p.prosecdef from pg_proc p
       where p.oid = 'audit.record_agent_identity_event()'::regprocedure),
  'audit.record_agent_identity_event() er ikke SECURITY DEFINER'
);

-- anon *skal* ha EXECUTE, og det er en bevisst avveining: en agent har ingen
-- brukerkonto (MVP_IMPLEMENTATION_PLAN.md §16), så alternativet ville vært
-- service_role, som DATABASE_ARCHITECTURE.md §49 avviser. Legitimasjonen og ikke
-- Data API-rollen er kontrollen, og 420 prøver den.
select ok(
  has_function_privilege(
    'anon',
    'api.begin_agent_run(text,text,text,text,text,text,text,text,jsonb)'::regprocedure,
    'execute'
  ),
  'anon har EXECUTE på api.begin_agent_run(), fordi en agent ikke har brukerkonto'
);
select is_empty(
  $$
    select f.fn || ':' || r.role_name
    from (values
      ('api.begin_agent_run(text,text,text,text,text,text,text,text,jsonb)'),
      ('api.complete_agent_run(text,text,uuid,text,jsonb,text)')) as f(fn)
    cross join (values ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(r.role_name, f.fn::regprocedure, 'execute')
  $$,
  'verken service_role eller PUBLIC kan kjøre agentflatens inngangspunkter'
);

-- Forvaltningsoperasjonene er ikke Data API-operasjoner. 210_workflow_access_test.sql
-- er allerede uttømmende over workflow og provenance; denne assertionen er den
-- navngitte utgaven for den funksjonen som utsteder legitimasjon, fordi
-- konsekvensen av en grant der ville vært at en klient kunne be om en
-- hemmelighet.
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    where has_function_privilege(
      r.role_name,
      'provenance.issue_agent_identity_credential(text, text)'::regprocedure,
      'execute'
    )
  $$,
  'ingen klientrolle kan be om utstedelse av en agentlegitimasjon'
);

select finish();

rollback;
