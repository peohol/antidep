-- Migrasjon 007c — den kontrollerte skriveveien for å opprette en Source.
--
-- Steg 2 av «manuell adminflyt» (MVP_IMPLEMENTATION_PLAN.md §29, §74.21,
-- §74.22): «Editor oppretter Source» (§15), det første leddet i
-- admin-workflowen. Testen dekker tre ting samlet, fordi de hører til samme
-- lille skrivevei: kontrakten (hva som faktisk er eksponert), autorisasjonen
-- (knowledge.assert_editor_authorized(), prøvd i hver av sine grener) og
-- konsekvensen (raden som settes inn, og auditraden som følger den).
--
-- SQLSTATE 42501 = insufficient_privilege, 22P02 = invalid_text_representation,
-- 23514 = check_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(31);

-- ===========================================================================
-- Del 1 — Kontrakten: hva migrasjon 003a, 008a og 007c faktisk åpnet
-- ===========================================================================

select col_not_null(
  'knowledge', 'sources', 'created_by_actor_id',
  'enhver kilde er attribuert til en aktør (ANTIDEP_CONSTITUTION.md §14)'
);
select fk_ok(
  'knowledge', 'sources', 'created_by_actor_id',
  'provenance', 'actors', 'id',
  'attribusjonen peker på en normalisert aktør'
);

select enum_has_labels(
  'audit', 'event_operation',
  array[
    'claim_published', 'claim_publication_replaced', 'claim_publication_withdrawn',
    'claim_publication_rolled_back', 'role_granted', 'role_ended', 'source_created',
    'evidence_item_created', 'agent_identity_registered',
    'agent_identity_credential_issued', 'agent_identity_revoked',
    'evidence_verification_registered', 'source_version_registered',
    'claim_verification_registered', 'review_decision_registered',
    'evidence_field_grounding_recorded',
    'extraction_artifact_discarded', 'claim_artifact_discarded',
    'claim_revision_created',
    -- Migrasjon 009: fulltekstbiblioteket (009a), modellregisteret (009c) og
    -- kandidaten med sin sluttkontroll (009d).
    'source_document_stored', 'role_model_assignment_registered', 'role_model_assignment_closed',
    'candidate_built', 'candidate_final_control_recorded',
    -- Migrasjon 013b: monografibestillingen, relevansavgjørelsen, det
    -- aksepterte fagbegrepet, svarrevisjonen, låsingen, kildebegrensningen,
    -- den forseglede monografikandidaten, sluttkontrollen, publiseringen og
    -- tilbaketrekkingen.
    'monograph_edition_ordered', 'monograph_need_relevance_decided',
    'monograph_term_accepted', 'monograph_answer_revision_created',
    'monograph_answer_lock_changed', 'monograph_source_restriction_registered',
    'monograph_candidate_built', 'monograph_final_control_recorded',
    'monograph_published', 'monograph_publication_withdrawn'
  ],
  'audit.event_operation dekker nå også kildeopprettelse, evidensregistrering, agentidentitetenes livssyklus, ekstraksjons- og claim-verifikasjon, kildeversjoner, den menneskelige reviewbeslutningen, kildeforankringen per kontrollfelt, de to fjerningene av testartefakter og opprettelsen av en påstandsrevisjon, samt fulltekstbiblioteket, modellregisteret og kandidaten med sin sluttkontroll, samt monografilaget i fase C (013b)'
);

select has_function('api', 'create_source', 'api.create_source() finnes');
select has_function(
  'knowledge', 'assert_editor_authorized', 'knowledge.assert_editor_authorized() finnes'
);
select has_function('audit', 'record_source_event', 'audit.record_source_event() finnes');
select has_trigger(
  'knowledge', 'sources', 'sources_record_creation_audit_event',
  'enhver innsatt kilde auditeres'
);

-- De kontrollerte skriveveiene er de eneste funksjonene i api eller knowledge
-- en klientrolle kan kjøre. Uttømmende over begge schemaene, framfor bare et
-- oppslag på funksjonen selv: en framtidig funksjon i knowledge skal ikke
-- kunne bli kjørbar for en klientrolle ved et uhell (samme mønster som
-- 270_publication_access_test.sql). Listen utvides av den migrasjonen som
-- åpner en ny skrivevei, og bare av den.
select is_empty(
  $$
    select p.oid::regprocedure::text, r.role_name
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join (values ('anon'), ('authenticated'), ('service_role'), ('public'))
           as r(role_name)
    where n.nspname in ('knowledge', 'api')
      and has_function_privilege(r.role_name, p.oid, 'execute')
      and p.oid::regprocedure::text not in (
        'api.create_source(text,text,text,text,text,text,text,date,text)',
        'api.create_evidence_item(uuid,text,text,text,text,uuid,text,uuid,text,text,text,text,text,text,uuid,uuid,integer,text,uuid,text,text,text,text,numeric,text,numeric,numeric,numeric,text,text)',
        -- Migrasjon 005e. De to eneste funksjonene i api som anon kan kjøre, og
        -- de rører ingen kunnskapsobjekter: de åpner og lukker en agentkjøring,
        -- og gjør ingenting før legitimasjonen er autentisert. Hvilke roller som
        -- faktisk har EXECUTE på hvilken funksjon, kontrolleres i
        -- 410_agent_identity_structure_test.sql; her er poenget at listen er
        -- uttømmende.
        'api.begin_agent_run(text,text,text,text,text,text,text,text,jsonb,uuid)',
        'api.complete_agent_run(text,text,uuid,text,jsonb,text)',
        -- Migrasjon 005g. Samme begrunnelse som de to over: en autentisert
        -- ekstraksjonsverifikator kaller den som anon, og den rører ingenting
        -- før autentiseringen og den åpne kjøringen er kontrollert. Hvilke
        -- roller som faktisk har EXECUTE, kontrolleres i
        -- 440_extraction_verification_registration_test.sql.
        'api.register_extraction_verification(text,text,uuid,uuid,text,text,text[],text,text)',
        -- Migrasjon 007f. En editorhandling, som de to første: bare
        -- authenticated, og autorisasjonen tas på funksjonens eget kall.
        'api.create_source_version(uuid,timestamp with time zone,text,text,text,text,text)',
        -- Migrasjon 005h. Lesegrunnlaget verifikatoren arbeider fra. Kalles av
        -- anon av samme grunn som de tre agentfunksjonene over, og gir
        -- ingenting før legitimasjonen og den åpne kjøringen er kontrollert;
        -- hvilke roller som har EXECUTE kontrolleres i
        -- 460_extraction_verification_input_test.sql.
        'api.extraction_verification_input(text,text,uuid,uuid)',
        -- Migrasjon 005k. Claim-verifikatorens to flater, med samme begrunnelse
        -- som ekstraksjonsverifikatorens: begge kalles av anon, begge gir og
        -- skriver ingenting før legitimasjonen, rollen og den åpne kjøringen er
        -- kontrollert. Hvilke roller som faktisk har EXECUTE, kontrolleres i
        -- 470_claim_verification_registration_test.sql og
        -- 480_claim_verification_input_test.sql.
        'api.claim_verification_input(text,text,uuid,uuid)',
        'api.register_claim_verification(text,text,uuid,uuid,text,text,text,text,text,text,text,text,jsonb,text,text)',
        -- Migrasjon 005n, 005o og 006d. Den menneskelige reviewflyten: to
        -- skriveveier og én lesevei, alle tre bare for authenticated, og alle
        -- tre autoriserer kalleren på sitt eget kall
        -- (workflow.assert_reviewer_authorized). Hvilke roller som faktisk har
        -- EXECUTE, kontrolleres i
        -- 500_human_claim_verification_test.sql,
        -- 510_publication_approval_test.sql og
        -- 520_claim_review_workspace_test.sql.
        'api.register_human_claim_verification(uuid,text,text,text,text,text,text,text,text,text,jsonb,text,text)',
        'api.register_publication_approval(uuid,text,text,text)',
        'api.claim_review_workspace(uuid)',
        -- Migrasjon 005s og 005t. Den menneskelige ekstraksjonskontrollen: én
        -- skrivevei og én lesevei, begge bare for authenticated, og begge
        -- autoriserer kalleren på sitt eget kall
        -- (workflow.assert_reviewer_authorized). Hvilke roller som faktisk har
        -- EXECUTE, kontrolleres i
        -- 540_human_extraction_verification_test.sql og
        -- 550_extraction_review_workspace_test.sql.
        'api.register_human_extraction_verification(uuid,text,text,text,text[],text,text)',
        'api.extraction_review_workspace(uuid)',
        -- Migrasjon 005v. Ekstraksjonsagentens skrivevei. Som de øvrige
        -- agentendepunktene er den kjørbar for anon og authenticated, fordi en
        -- agent ikke har en brukerkonto: kontrollen er legitimasjonen og den
        -- eksplisitte rollen, ikke Data API-rollen. Hvilke roller som faktisk
        -- har EXECUTE, kontrolleres i 600_agent_extraction_test.sql.
        'api.register_agent_extraction(text,text,uuid,uuid,uuid,text,text,text,text,uuid,text,uuid,text,text,text,text,text,text,jsonb,text,uuid,integer,text,uuid,text,text,text,text,numeric,text,numeric,numeric,numeric,text,text)',
        -- Migrasjon 003e. Den dokumentutledede kildeversjonen: samme
        -- autorisasjon som tekstveien (knowledge.assert_editor_authorized), og
        -- bare authenticated. Kalleren sender bytene, ikke fingeravtrykket:
        -- databasen beregner det selv, og dokumentet lagres ikke. Hvilke roller
        -- som faktisk har EXECUTE, kontrolleres i
        -- 640_source_document_registration_test.sql.
        'api.create_source_version_from_document(uuid,timestamp with time zone,text,text,text,text,text,text,text,text,text,text)',
        -- Migrasjon 007i. Ekstraksjonsoppdraget bygget av databasens egne
        -- rader. Ren lesevei, bare authenticated, og den autoriserer kalleren
        -- på sitt eget kall (knowledge.assert_editor_authorized). Hvilke roller
        -- som faktisk har EXECUTE, kontrolleres i
        -- 650_build_extraction_assignment_test.sql.
        'api.build_extraction_assignment(uuid,text[],text[],text[])',
        -- Migrasjon 005am. Synteseagentens skrivevei: én påstandsrevisjon med
        -- identiteten og evidenslenkene sine, i én transaksjon. Som de øvrige
        -- agentendepunktene er den kjørbar for anon og authenticated, fordi en
        -- agent ikke har en brukerkonto: kontrollen er legitimasjonen og den
        -- eksplisitte rollen `claim_synthesis`, ikke Data API-rollen. Signaturen
        -- er uten `p_assessment`: evidensvurderingen er et eget ledd, og en
        -- gjenoppstått overlast med den parameteren ville sluppet graderingen
        -- tilbake i synteserollen. Hvilke roller som faktisk har EXECUTE,
        -- kontrolleres i 690_claim_synthesis_write_path_test.sql.
        'api.register_claim_synthesis(text,text,uuid,uuid,uuid,text,text,text,text,jsonb,uuid,uuid,text,text,uuid,text,text,numeric,text,text)',
        -- Migrasjon 005am. Evidensvurderingsagentens skrivevei: én
        -- GRADE-vurdering for én påstandsrevisjon, etter at
        -- kildestøtteverifikasjonen har bekreftet påstanden. Egen rolle
        -- (`evidence_assessment`) og egen identitet, fordi ansvarsgrensen i
        -- EVIDENCE_PIPELINE.md §61 samtidig skal være en teknisk grense. Hvilke
        -- roller som faktisk har EXECUTE, kontrolleres i
        -- 700_evidence_assessment_write_path_test.sql.
        'api.register_evidence_assessment(text,text,uuid,uuid,text,text,text,text,text,text,text,text,text,text,text)',
        -- Migrasjon 009a. Veien inn i det private fulltekstbiblioteket: filen,
        -- publikasjonsbindingen, lesbarhetskontrollen og kildeversjonen i én
        -- transaksjon. Bare authenticated, samme autorisasjon som de øvrige
        -- redaktørveiene. Kontrolleres i 730_full_text_library_test.sql.
        'api.upload_full_text_document(uuid,timestamp with time zone,text,text,text,text,text,text,text,text)',
        -- Migrasjon 009b. Den varige jobbkøen. Innleggingen er en redaktørvei
        -- og bare authenticated; de tre andre er agentveier og kjørbare for
        -- anon, fordi en agent ikke har brukerkonto. Kontrolleres i
        -- 740_pipeline_jobs_test.sql.
        'api.enqueue_pipeline_job(text,text,jsonb)',
        'api.claim_pipeline_job(text,text,text,integer)',
        'api.begin_pipeline_job_run(text,text,uuid,uuid,text,text,text,text,text,jsonb,uuid)',
        'api.complete_pipeline_job(text,text,uuid,uuid,uuid)',
        'api.fail_pipeline_job(text,text,uuid,uuid,text)',
        -- Migrasjon 009d. Kandidaten og den kandidatbundne sluttkontrollen,
        -- med den leseflaten klinikeren og sluttkontrolløren deler. Alle fire
        -- er authenticated: utkast er tilgangsbegrenset, og sluttkontrollen er
        -- et menneskes beslutning. Kontrolleres i
        -- 760_candidate_final_control_test.sql.
        'api.build_candidate(uuid)',
        'api.record_candidate_final_control(uuid,text,text,text)',
        'api.candidate_for_control(uuid)',
        'api.candidate_control_queue()',
        -- Migrasjon 009e og 009f. Publiseringen, tilbaketrekkingen og
        -- rollbacken, og den publiserte klinikerflaten. Alle seks er
        -- authenticated og ingen av dem anon: de tre handlingene krever en
        -- navngitt menneskelig aktør med publisher-mandat, og det publiserte
        -- innholdet bærer ordrette kildeutdrag hvis offentlige
        -- gjengivelsesrett er vurdert separat. Kontrolleres i
        -- 770_candidate_publication_test.sql.
        'api.publish_candidate(uuid,text,text)',
        'api.withdraw_claim_publication(uuid,text)',
        'api.rollback_claim_publication(uuid,uuid,text,text)',
        'api.claim_publication_history(uuid)',
        'api.published_claim(uuid)',
        'api.published_claim_index()',
        -- Migrasjon 010c. Den eksterne agent-handoffen: køen, oppgaven og
        -- importen av ett agentsvar, pluss innleggingen og avslutningen av en
        -- rolles semantiske modell. Alle fem er authenticated og ingen av dem
        -- anon: oppgaven bærer hele den kontrollerte kildeteksten, og importen
        -- skriver kliniske objekter på vegne av et agentledd. Kontrolleres i
        -- 780_external_agent_handoff_test.sql.
        'api.agent_work_queue()',
        'api.agent_task_payload(uuid)',
        'api.import_agent_answer(uuid,jsonb)',
        'api.enqueue_agent_task(text,jsonb)',
        -- Tildelingen og avslutningen av leddets semantiske modell. Tildelingen
        -- er en attestert avgjørelse en redaktør tar FØR oppgaven hentes ut:
        -- modellidentiteten kan ikke etableres av agentsvaret selv, og derfor
        -- finnes den som en egen redaktørvei framfor som en registrering ved
        -- første svar (ANTIDEP_CONSTITUTION.md regel 3).
        'api.assign_agent_role_model(text,text,text,text,text,text,text)',
        'api.release_agent_role_model(text,text)',
        -- Migrasjon 011a. Den autonome kjøreren over den samme handoffen.
        --
        -- Redaktørveiene er authenticated, som resten av handoffen: å registrere
        -- en kjører, hente en engangs tilkoblingskode og trekke den tilbake er
        -- avgjørelser om hvem som utfører kjedens arbeid.
        'api.register_agent_runner(text,text,text,text,text,text)',
        'api.revoke_agent_runner(text,text)',
        'api.issue_agent_runner_pairing_code(text)',
        'api.agent_runner_connections()',
        -- Kjørerveiene er i tillegg anon, av samme grunn som
        -- api.claim_pipeline_job(text,text,text,integer): en kjører har ingen
        -- brukerkonto, så legitimasjonen — her et OAuth-token bundet til en
        -- registrert tilkobling — og ikke Data API-rollen er kontrollen. Ingen
        -- av dem gir tilgang uten et token, og ingen av dem kan gi større
        -- faglige skrivefullmakter enn den manuelle handoffen: de deler
        -- skrivevei (workflow.record_agent_handoff_answer). Kontrolleres i
        -- 790_autonomous_agent_runner_test.sql.
        'api.register_agent_runner_client(text,text[])',
        'api.authorize_agent_runner(text,text,text,text,text,text)',
        'api.exchange_agent_runner_code(text,text,text,text,text)',
        'api.refresh_agent_runner_token(text,text,text)',
        'api.list_pending_agent_tasks(text,text)',
        'api.claim_agent_task(text,text,text,integer)',
        'api.agent_task_for_runner(text,text,uuid)',
        'api.agent_task_precheck(text,text,uuid)',
        'api.submit_agent_answer(text,text,uuid,jsonb)',
        'api.release_agent_task(text,text,uuid,text)',
        'api.agent_runner_identity(text,text)',
        'api.record_agent_runner_outcome(text,text,text,text,uuid)',
        -- Migrasjon 012a. Den klinikervennlige arbeidsflaten.
        --
        -- api.public_work_board() er den ene som i tillegg er anon, og det er
        -- hele poenget med den: arbeidsoversikten skal kunne leses uten
        -- innlogging. Den svarer med et lukket produktvokabular og bærer ingen
        -- agentrolle, modell, kjører, jobbnøkkel, artikkeltittel, uuid eller
        -- feiltekst. Kontrolleres i 800_clinician_work_surface_test.sql.
        'api.public_work_board()',
        -- Fulltekstinnboksen og Antideps eget tekstuttrekk. Alle authenticated:
        -- innboksen krever editor- eller admin-mandat, og uttrekksveiene gir ut
        -- originaldokumentet, som bare skal forlate databasen til den som
        -- allerede kan laste det opp.
        'api.request_full_text(uuid,uuid[],uuid[],uuid[],text)',
        'api.withdraw_full_text_request(text,text)',
        'api.full_text_inbox()',
        'api.submit_full_text(text,text)',
        'api.claim_full_text_extraction(integer)',
        'api.complete_full_text_extraction(uuid,text,text)',
        'api.fail_full_text_extraction(uuid,text)',
        'api.resume_blocked_full_text_extractions()',
        -- Den tekniske problemoversikten. Tellingen svarer stille «ikke synlig»
        -- til alle som ikke er admin, og selvmeldingen tar bare
        -- maskinidentifikatorer og ingen tekst. Ingen av dem leser diagnosen.
        'api.technical_problem_board()',
        'api.technical_problem_summary()',
        'api.report_technical_problem(text,text,text,text,integer,text,uuid)',
        'api.record_client_diagnostic(uuid,text,text,text,text,integer,text,text)',
        -- Migrasjon 012b. De to veiene de deterministiske kontrolleddene har,
        -- og ingen andre. Begge er anon og authenticated av samme grunn som de
        -- øvrige agentveiene: et kontrolledd har ingen brukerkonto, og
        -- kontrollen er legitimasjonen og den eksplisitte rollen — her
        -- extraction_verification eller citation_support_verification — og ikke
        -- Data API-rollen.
        --
        -- api.control_source_representation(...) gir den lagrede,
        -- etterprøvbare representasjonen av én kildeversjon, altså nøyaktig den
        -- teksten kildeversjonens content_hash ble beregnet av. Originalfilen
        -- forlater aldri databasen der, og veien krever i tillegg en åpen
        -- kjøring som tilhører identiteten, slik at ingen lesning av kildetekst
        -- skjer uten en proveniensrad.
        --
        -- api.resume_chain_transitions(...) tar ikke imot ett eneste felt fra
        -- kalleren: den leser hva databasens egen tilstand tilsier og legger inn
        -- nøyaktig det triggerne ville lagt inn. Kontrolleres i
        -- 810_chain_transitions_test.sql.
        'api.control_source_representation(text,text,uuid,uuid)',
        'api.resume_chain_transitions(text,text)',
        -- Migrasjon 012c. Den klinikervennlige bestillingen av en artikkel
        -- Antidep mangler. Alle tre er authenticated og ingen av dem anon:
        -- bestillingen krever editor-mandat, listene den velger fra er de samme
        -- redaktørveiene, og hva den innloggede kan gjøre, er et svar på et
        -- spørsmål bare en innlogget kan stille. Kontrolleres i
        -- 820_full_text_request_test.sql.
        'api.request_missing_full_text(text,text,text,text[],text[],text[],text,integer)',
        'api.full_text_request_options()',
        'api.full_text_capabilities()',
        -- Migrasjon 012d. Den redaksjonelle avgjørelsen om ny evidens på en
        -- påstand som allerede finnes. Alle tre authenticated og ingen av dem
        -- anon: å avgjøre hva en påstand skal si i lys av ny kunnskap er en
        -- redaksjonell handling som krever editor-mandat, og selve beslutningen
        -- krever i tillegg mandat for endepunktet påstanden hører under.
        -- Kontrolleres i 830_claim_revision_review_test.sql.
        'api.claim_revision_queue()',
        'api.claim_revision_for_decision(text)',
        'api.record_claim_revision_decision(text,text,text,text)',
        -- Migrasjon 013c. Monografibestillingen og dekningskartet. Alle
        -- authenticated og ingen av dem anon: å avgjøre at Antidep skal si noe
        -- om et virkestoff er en redaksjonell handling, og et dekningskart er
        -- internt arbeidsmateriale som krever mandat å lese
        -- (ANTIDEP_CONSTITUTION.md regel 5). Kontrolleres i
        -- 850_monograph_order_test.sql.
        'api.monograph_order_options()',
        'api.order_monograph(text,text)',
        'api.monograph_orders()',
        'api.monograph_coverage(text)',
        'api.propose_monograph_term(text,text,text,text)',
        'api.decide_monograph_term(text,boolean,text)',
        'api.monograph_term_proposals(text)',
        -- Migrasjon 013e. Søkeplanen, den dokumenterte søkeloggen og de tre
        -- redaksjonelle handlingene krever editor-mandat. De to første er
        -- kildeleddenes egen vei — identitet og legitimasjon, som de andre
        -- deterministiske kjøringene — og er derfor åpne for både anon og
        -- authenticated på funksjonsnivå, med hele autorisasjonen i databasen.
        -- Kontrolleres i 860_monograph_discovery_test.sql.
        'api.monograph_discovery_work(text,text)',
        'api.record_monograph_machine_search(text,text,uuid,text,text,text,text,text,text,text,integer,integer,boolean,text,text,text[],jsonb)',
        'api.monograph_search_plans(text)',
        'api.close_monograph_search_plan(text,text)',
        'api.pause_monograph_search_plan(text,text)',
        'api.resume_monograph_search_plan(text)',
        'api.decide_monograph_candidate(text,text,text)'
      )
  $$,
  'ingen annen funksjon i knowledge eller api enn de kontrollerte inngangspunktene er kjørbar for noen klientrolle'
);
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.create_source(text,text,text,text,text,text,text,date,text)'::regprocedure,
      'execute'
    )
  $$,
  'api.create_source() er kjørbar bare for authenticated, ikke for anon, service_role eller PUBLIC'
);
select ok(
  has_function_privilege(
    'authenticated',
    'api.create_source(text,text,text,text,text,text,text,date,text)'::regprocedure,
    'execute'
  ),
  'authenticated har EXECUTE på api.create_source()'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.create_source(text,text,text,text,text,text,text,date,text)'::regprocedure),
  'api.create_source() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);
-- Auditskriveren skal aldri være mer privilegert enn operasjonen den
-- registrerer (samme regel som for de to auditskriverne migrasjon 008 innførte).
select ok(
  not (select p.prosecdef from pg_proc p
       where p.oid = 'audit.record_source_event()'::regprocedure),
  'audit.record_source_event() er ikke SECURITY DEFINER'
);

-- ===========================================================================
-- Del 2 — Uinnlogget og direkte tabellskriving er begge stengt (§43)
-- ===========================================================================
set local role anon;
select throws_ok(
  $$select api.create_source('journal_article', 'Anonymt forsøk', 'Anon')$$,
  '42501', null,
  'anon kan ikke opprette en kilde gjennom skriveveien'
);
select throws_ok(
  $$
    insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
    values ('journal_article', 'Anonymt forsøk', 'Anon', gen_random_uuid())
  $$,
  '42501', null,
  'anon kan ikke skrive direkte i knowledge.sources'
);
reset role;

set local role authenticated;
select throws_ok(
  $$
    insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
    values ('journal_article', 'Direkte forsøk', 'Autentisert', gen_random_uuid())
  $$,
  '42501', null,
  'en innlogget bruker kan ikke omgå funksjonen ved å skrive direkte i knowledge.sources'
);
reset role;

-- ===========================================================================
-- Del 3 — Fikstur: seks kontoer som spenner ut autorisasjonsgrenene
--
--   A  ingen aktørrad i det hele tatt
--   B  aktør, men ingen rolletildeling
--   C  aktør, tilbaketrukket, med en ellers gyldig editor-tildeling
--   D  aktør, reviewer-tildeling (ikke editor)
--   E  aktør, editor-tildeling avgrenset til «vektendring»
--   F  aktør, editor-tildeling uavgrenset, og en avsluttet tildeling ved siden av
-- ===========================================================================
insert into auth.users (id, email) values
  ('37000000-0000-4000-8000-00000000000a', 'kilde-370-a@test.invalid'),
  ('37000000-0000-4000-8000-00000000000b', 'kilde-370-b@test.invalid'),
  ('37000000-0000-4000-8000-00000000000c', 'kilde-370-c@test.invalid'),
  ('37000000-0000-4000-8000-00000000000d', 'kilde-370-d@test.invalid'),
  ('37000000-0000-4000-8000-00000000000e', 'kilde-370-e@test.invalid'),
  ('37000000-0000-4000-8000-00000000000f', 'kilde-370-f@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id, retired_at, retirement_note)
values
  ('ac370000-0000-4000-8000-00000000000b', 'human', 'human:kilde-370-b', 'Kaller B',
   'Aktør uten rolletildeling, for 370.', '37000000-0000-4000-8000-00000000000b', null, null),
  ('ac370000-0000-4000-8000-00000000000c', 'human', 'human:kilde-370-c', 'Kaller C',
   'Tilbaketrukket aktør med en ellers gyldig editor-tildeling, for 370.',
   '37000000-0000-4000-8000-00000000000c',
   now() - interval '1 day', 'Trukket tilbake for testene i 370.'),
  ('ac370000-0000-4000-8000-00000000000d', 'human', 'human:kilde-370-d', 'Kaller D',
   'Aktør med reviewer-rolle, ikke editor, for 370.', '37000000-0000-4000-8000-00000000000d',
   null, null),
  ('ac370000-0000-4000-8000-00000000000e', 'human', 'human:kilde-370-e', 'Kaller E',
   'Aktør med editor-rolle avgrenset til vektendring, for 370.',
   '37000000-0000-4000-8000-00000000000e', null, null),
  ('ac370000-0000-4000-8000-00000000000f', 'human', 'human:kilde-370-f', 'Kaller F',
   'Aktør med uavgrenset editor-rolle, for 370.', '37000000-0000-4000-8000-00000000000f',
   null, null);

create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id)
select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'actor_c', id from provenance.actors where actor_key = 'human:kilde-370-c';
insert into fixture (name, id) select 'actor_e', id from provenance.actors where actor_key = 'human:kilde-370-e';
insert into fixture (name, id) select 'actor_f', id from provenance.actors where actor_key = 'human:kilde-370-f';

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to, granted_by_actor_id, grant_reason,
   ended_by_actor_id, end_reason)
values
  ('37000000-0000-4000-8000-00000000000c', 'editor', null, now() - interval '1 year', null,
   (select id from fixture where name = 'actor_c'), 'Ellers gyldig tildeling for tilbaketrukket kaller C.',
   null, null),
  ('37000000-0000-4000-8000-00000000000d', 'reviewer', null, now() - interval '1 year', null,
   (select id from fixture where name = 'actor_e'), 'Reviewer, ikke editor, for kaller D.',
   null, null),
  ('37000000-0000-4000-8000-00000000000e', 'editor', (select id from fixture where name = 'topic'),
   now() - interval '1 year', null,
   (select id from fixture where name = 'actor_e'), 'Avgrenset editor-tildeling for kaller E.',
   null, null),
  ('37000000-0000-4000-8000-00000000000f', 'editor', null, now() - interval '1 year', null,
   (select id from fixture where name = 'actor_f'), 'Uavgrenset editor-tildeling for kaller F.',
   null, null),
  -- Ved siden av F sin gyldige tildeling: en avsluttet editor-tildeling som
  -- ikke skal telle. Uten den ville en mutasjon som leser «finnes det NOEN
  -- tildeling» framfor «finnes det en GYLDIG NÅ tildeling» ikke blitt fanget.
  ('37000000-0000-4000-8000-00000000000f', 'publisher', null,
   now() - interval '2 years', now() - interval '1 year',
   (select id from fixture where name = 'actor_f'), 'Avsluttet publisher-tildeling for kaller F.',
   (select id from fixture where name = 'actor_f'), 'Avsluttet for testene i 370.');

-- ===========================================================================
-- Del 4 — Hver avvisningsgren, prøvd med den faktiske funksjonen
-- ===========================================================================

-- A — ingen aktørrad
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  $$select api.create_source('journal_article', 'Uten aktør', 'Kaller A')$$,
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en kaller uten aktørrad avvises eksplisitt, og får ikke en kilde opprettet i sitt navn'
);
reset role;

-- B — aktør, ingen rolletildeling i det hele tatt
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  $$select api.create_source('journal_article', 'Uten rolle', 'Kaller B')$$,
  '42501', 'Brukeren har ikke gyldig editor-rolle.',
  'en aktør uten noen rolletildeling avvises med rollefeilen, ikke aktørfeilen'
);
reset role;

-- C — tilbaketrukket aktør med en ellers gyldig editor-tildeling
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
select throws_ok(
  $$select api.create_source('journal_article', 'Tilbaketrukket', 'Kaller C')$$,
  '42501', 'Aktøren er trukket tilbake og kan ikke registrere nytt innhold.',
  'en tilbaketrukket aktør avvises, selv med en ellers gyldig editor-tildeling'
);
reset role;

-- D — reviewer, ikke editor
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000d"}', true);
set local role authenticated;
select throws_ok(
  $$select api.create_source('journal_article', 'Feil rolle', 'Kaller D')$$,
  '42501', 'Brukeren har ikke gyldig editor-rolle.',
  'reviewer-rollen gir ikke rett til å opprette kilder; å godkjenne og å opprette er forskjellige handlinger'
);
reset role;

-- E — editor, men avgrenset til et klinisk begrep. Kilden er ikke selv
-- avgrenset til noe (se migrasjonens hodekommentar), så dette skal LYKKES.
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000e"}', true);
set local role authenticated;
select lives_ok(
  $$select api.create_source('journal_article', 'Avgrenset editor', 'Kaller E')$$,
  'en editor-tildeling avgrenset til et klinisk begrep er tilstrekkelig: en Source er ikke selv avgrenset'
);
reset role;

select is(
  (select s.created_by_actor_id from knowledge.sources s where s.title = 'Avgrenset editor'),
  (select id from fixture where name = 'actor_e'),
  'kilden fra kaller E er attribuert til kaller E sin egen aktør, ikke til en annen'
);

-- ===========================================================================
-- Del 5 — Den lykkede stien, kontrollert i detalj (kaller F, uavgrenset)
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-00000000000f"}', true);
set local role authenticated;

-- Kallet selv skjer som authenticated (det er nettopp autorisasjonen som
-- prøves); innholdet i raden verifiseres etterpå som eieren, av samme grunn
-- som lag 1 i 360_caller_authorization_test.sql: authenticated har ikke usage
-- på knowledge og kan ikke lese tilbake fra tabellen i samme setning som den
-- kaller funksjonen — det ville vært et forsøk på å omgå §43 fra innsiden av
-- en test, ikke en reell klientspørring.
select lives_ok(
  $$
    select api.create_source(
      p_source_type := 'journal_article',
      p_title := 'Fullstendig testkilde for 370',
      p_authors_or_issuer := 'Testforfatter F',
      p_publisher_or_journal := 'Testtidsskriftet',
      p_publication_date := date '2024-06-01',
      p_publication_date_precision := 'month'
    )
  $$,
  'en uavgrenset editor-tildeling oppretter kilden'
);
select lives_ok(
  $$select api.create_source('clinical_guideline', 'Minimal testkilde for 370', 'Testutgiver')$$,
  'en kilde med bare de påkrevde feltene kan opprettes'
);

-- Databasens vokabularkontroll er fasiten, ikke en klientside-gjetning
-- (felle 4 i oppgaveteksten): en verdi utenfor knowledge.source_type avvises av
-- casten inne i funksjonen.
select throws_ok(
  $$select api.create_source('preprint', 'Ukjent kildetype', 'Testforfatter')$$,
  '22P02', null,
  'en kildetype utenfor det kontrollerte vokabularet avvises av databasen, ikke antatt gyldig'
);
-- Og CHECK-constraintene på selve tabellen: en tom tittel avvises akkurat som
-- ved en direkte innsetting (090_knowledge_constraints_test.sql), gjennom
-- funksjonen og uten at funksjonen selv reimplementerer regelen.
select throws_ok(
  $$select api.create_source('journal_article', '', 'Testforfatter')$$,
  '23514', null,
  'en tom tittel avvises av knowledge.sources sin egen CHECK, ikke duplisert i funksjonen'
);

reset role;

-- Innholdet, kontrollert som eieren.
select results_eq(
  $$
    select s.source_type::text, s.title, s.authors_or_issuer, s.publisher_or_journal,
           s.publication_date::text, s.publication_date_precision::text, s.source_status::text,
           s.status_note, s.superseded_by_source_id, s.created_by_actor_id
    from knowledge.sources s
    where s.title = 'Fullstendig testkilde for 370'
  $$,
  $$
    values ('journal_article', 'Fullstendig testkilde for 370', 'Testforfatter F',
            'Testtidsskriftet', '2024-06-01', 'month', 'active', null, null::uuid,
            (select id from fixture where name = 'actor_f'))
  $$,
  'raden bærer nøyaktig det oppgitte, starter active uten status_note eller erstatter, og er attribuert til kalleren'
);

-- Valgfrie felter utelates til NULL, ikke til tomstreng eller en annen
-- standardverdi — funksjonen finner ikke på noe parameterlisten ikke oppga.
select results_eq(
  $$
    select s.publisher_or_journal, s.volume, s.issue, s.pages,
           s.publication_date, s.publication_date_precision
    from knowledge.sources s
    where s.title = 'Minimal testkilde for 370'
  $$,
  $$ values (null, null, null, null, null::date, null::knowledge.date_precision) $$,
  'valgfrie felter som ikke oppgis, forblir NULL'
);

-- ===========================================================================
-- Del 6 — Auditraden som fulgte den lykkede opprettelsen
-- ===========================================================================
select is(
  (select count(*)::integer from audit.events
   where object_id = (select s.id from knowledge.sources s
                       where s.title = 'Fullstendig testkilde for 370')),
  1,
  'opprettelsen ga nøyaktig én auditrad'
);

select results_eq(
  $$
    select e.operation::text, e.object_schema, e.object_table, e.actor_id,
           e.old_revision_or_snapshot,
           e.new_revision_or_snapshot ->> 'title',
           e.new_revision_or_snapshot ->> 'authors_or_issuer'
    from audit.events e
    where e.object_id = (select s.id from knowledge.sources s
                          where s.title = 'Fullstendig testkilde for 370')
  $$,
  $$
    values ('source_created', 'knowledge', 'sources',
            (select id from fixture where name = 'actor_f'),
            null::jsonb, 'Fullstendig testkilde for 370', 'Testforfatter F')
  $$,
  'auditraden peker på kilden, attribueres til oppretteren, har intet old-snapshot, og new-snapshotet er den faktiske raden'
);

-- ===========================================================================
-- Del 7 — Gyldighet måles på setningen, ikke på transaksjonen (§74.6)
--
-- Samme deterministiske vindu som 360_caller_authorization_test.sql: en
-- editor-tildeling trer i kraft midt i transaksjonen, og en annen utløper midt
-- i den. now() ville svart feil på begge.
-- ===========================================================================
insert into auth.users (id, email) values
  ('37000000-0000-4000-8000-000000000010', 'kilde-370-g@test.invalid'),
  ('37000000-0000-4000-8000-000000000011', 'kilde-370-h@test.invalid');

insert into provenance.actors (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac370000-0000-4000-8000-000000000010', 'human', 'human:kilde-370-g', 'Kaller G',
   'Tildeling som trer i kraft underveis, for 370.', '37000000-0000-4000-8000-000000000010'),
  ('ac370000-0000-4000-8000-000000000011', 'human', 'human:kilde-370-h', 'Kaller H',
   'Tildeling som utløper underveis, for 370.', '37000000-0000-4000-8000-000000000011');

insert into workflow.user_roles
  (user_id, role_code, valid_from, valid_to, granted_by_actor_id, grant_reason,
   ended_by_actor_id, end_reason)
values
  ('37000000-0000-4000-8000-000000000010', 'editor',
   now() + interval '250 milliseconds', null,
   'ac370000-0000-4000-8000-000000000010', 'Trer i kraft underveis, for 370.', null, null),
  ('37000000-0000-4000-8000-000000000011', 'editor',
   now() - interval '1 day', now() + interval '250 milliseconds',
   'ac370000-0000-4000-8000-000000000011', 'Utløper underveis, for 370.',
   'ac370000-0000-4000-8000-000000000011', 'Planlagt utløp under transaksjonen.');

select pg_sleep(1);

select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-000000000010"}', true);
set local role authenticated;
select lives_ok(
  $$select api.create_source('journal_article', 'Tildeling trådte i kraft underveis', 'Kaller G')$$,
  'en editor-tildeling som trådte i kraft mens transaksjonen løp, gjelder nå'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"37000000-0000-4000-8000-000000000011"}', true);
set local role authenticated;
select throws_ok(
  $$select api.create_source('journal_article', 'Tildeling utløp underveis', 'Kaller H')$$,
  '42501', 'Brukeren har ikke gyldig editor-rolle.',
  'en editor-tildeling som utløp mens transaksjonen løp, gjelder ikke lenger'
);
reset role;

select set_config('request.jwt.claims', '', true);

select * from finish();

rollback;
