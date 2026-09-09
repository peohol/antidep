-- Migrasjon 005q og 005s — den menneskelige skriveveien inn i
-- workflow.evidence_verifications, og mandatet som nå ligger på raden.
--
-- Speilbildet av 500_human_claim_verification_test.sql for ekstraksjonsleddet.
-- Filen dekker kontrakten (hva som faktisk er eksponert), autorisasjonen i hver
-- av sine grener, konsekvensen (raden og auditraden), og de invariantene som
-- skal gjelde likt uansett om det er en maskin eller et menneske som
-- registrerer: forbudet mot selvverifikasjon, forbudet mot å bekrefte på et
-- avledet sammendrag alene, kravet om at kildepekeren er kontrollert i en
-- bekreftelse, kravet om funn ved et annet utfall enn verified, og append-only.
--
-- I tillegg dekker den de tre tingene som er nye i dette leddet:
--
--   * at kontrollen gjelder nøyaktig det grunnlaget revieweren faktisk så
--   * at skriveveiens egen autorisasjon ikke er den eneste sperren — raden har
--     sin egen mandatkontroll, og den holder når skriveveiens er mutert bort
--   * at kontrollen av «det du faktisk så» tar radlåsen, slik at en samtidig
--     registrering ikke kan snike seg inn i vinduet
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23514 = check_violation, P0002 = no_data_found.
begin;

create extension if not exists pgtap with schema extensions;

select plan(41);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_function(
  'api', 'register_human_extraction_verification',
  'api.register_human_extraction_verification() finnes'
);
select has_function(
  'workflow', 'record_evidence_verification', 'workflow.record_evidence_verification() finnes'
);
select has_function(
  'workflow', 'assert_extraction_unchanged', 'workflow.assert_extraction_unchanged() finnes'
);
select has_function(
  'workflow', 'evidence_extraction_digest', 'workflow.evidence_extraction_digest() finnes'
);
select has_function(
  'workflow', 'evidence_verifier_has_mandate', 'workflow.evidence_verifier_has_mandate() finnes'
);
select has_trigger(
  'workflow', 'evidence_verifications', 'evidence_verifications_enforce_verifier_mandate',
  'mandatet håndheves på raden, uansett hvordan den kom dit'
);

select ok(
  (select p.prosecdef from pg_proc p
   where p.oid = 'api.register_human_extraction_verification(uuid,text,text,text,text[],text,text)'::regprocedure),
  'api.register_human_extraction_verification() er SECURITY DEFINER (DATABASE_ARCHITECTURE.md §50)'
);

-- Kontrollen forutsetter en innlogget person. anon skal ikke kunne kalle den i
-- det hele tatt — til forskjell fra agentveien, der legitimasjonen og ikke Data
-- API-rollen er kontrollen.
select is_empty(
  $$
    select r.role_name
    from (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(
      r.role_name,
      'api.register_human_extraction_verification(uuid,text,text,text,text[],text,text)'::regprocedure,
      'execute'
    )
  $$,
  'api.register_human_extraction_verification() er kjørbar bare for authenticated'
);
select ok(
  has_function_privilege(
    'authenticated',
    'api.register_human_extraction_verification(uuid,text,text,text,text[],text,text)'::regprocedure,
    'execute'
  ),
  'authenticated kan kalle den'
);

-- Ingen klientrolle får kjøre registreringsleddet, låsekontrollen, avtrykket
-- eller mandatet direkte: de gjør ingen autorisasjon, og er ment å kalles fra
-- innsiden av en api-funksjon som har avgjort hvem kalleren er.
select is_empty(
  $$
    select r.role_name, f.signature
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values
            ('workflow.record_evidence_verification(uuid,uuid,uuid,text,text,text[],text,text)'),
            ('workflow.assert_extraction_unchanged(uuid,text)'),
            ('workflow.evidence_extraction_digest(uuid)'),
            ('workflow.evidence_extraction_dossier(uuid)'),
            ('workflow.evidence_verifier_has_mandate(uuid,uuid,timestamp with time zone)'),
            ('workflow.covered_check_fields(uuid)')
         ) as f(signature)
    where has_function_privilege(r.role_name, f.signature::regprocedure, 'execute')
  $$,
  'ingen klientrolle kan kalle registreringsleddet, avtrykket, låsekontrollen, dossieret, mandatet eller dekningen direkte'
);
select is_empty(
  $$
    select r.role_name, p.priv
    from (values ('anon'), ('authenticated'), ('public')) as r(role_name),
         (values ('select'), ('insert'), ('update'), ('delete')) as p(priv)
    where has_table_privilege(r.role_name, 'workflow.evidence_verifications', p.priv)
  $$,
  'klientrollene har ingen tabellrettighet på workflow.evidence_verifications'
);

-- ===========================================================================
-- Del 2 — Fikstur
--
-- Åtte brukerkontoer, én per autorisasjonsgren, og fire evidensfunn:
--
--   E1  laget av ekstraksjonsagenten, med etterprøvbar kildeversjon. Den
--       lykkede stien og feltreglene.
--   E2  laget av reviewer H sin egen aktør. Finnes bare for å prøve
--       selvverifikasjonsregelen med en aktør som faktisk har mandatet.
--   E3  laget av ekstraksjonsagenten. Brukes til avtrykkskontrollen.
--   E4  kildeversjon uten content_hash, for verifiable_representation-regelen.
--   E5  urørt, for låseprøven: ingenting i fiksturen skal ha låst raden.
-- ===========================================================================
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
insert into fixture (name, id) select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id) select 'weight', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id) select 'editor', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id) select 'extractor', id from provenance.actors where actor_key = 'agent:evidence-extraction';
insert into fixture (name, id) select 'extraction_verifier', id from provenance.actors where actor_key = 'agent:extraction-verification';

-- Et annet innholdsområde, slik at en avgrenset tildeling kan prøves mot et
-- endepunkt den ikke dekker.
insert into catalog.clinical_concepts (id, canonical_label, concept_type)
values ('54000000-0000-4000-8000-0000000000f0', 'søvnkvalitet for 540', 'outcome');

insert into auth.users (id, instance_id, aud, role, email)
select u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u.email
from (values
  ('54000000-0000-4000-8000-0000000000a0'::uuid, 'a540@example.test'),
  ('54000000-0000-4000-8000-0000000000b0'::uuid, 'b540@example.test'),
  ('54000000-0000-4000-8000-0000000000c0'::uuid, 'c540@example.test'),
  ('54000000-0000-4000-8000-0000000000d0'::uuid, 'd540@example.test'),
  ('54000000-0000-4000-8000-0000000000e0'::uuid, 'e540@example.test'),
  ('54000000-0000-4000-8000-0000000000f1'::uuid, 'f540@example.test'),
  ('54000000-0000-4000-8000-000000000090'::uuid, 'g540@example.test'),
  ('54000000-0000-4000-8000-000000000080'::uuid, 'h540@example.test')
) as u(id, email);

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id, retired_at, retirement_note)
values
  -- B: aktør uten noen rolletildeling.
  ('54000000-0000-4000-8000-0000000000b1', 'human:b-540', 'human', 'Kaller B 540',
   'Aktør uten rolle, for 540.', '54000000-0000-4000-8000-0000000000b0', null, null),
  -- C: tilbaketrukket aktør med en ellers gyldig reviewer-tildeling.
  ('54000000-0000-4000-8000-0000000000c1', 'human:c-540', 'human', 'Kaller C 540',
   'Tilbaketrukket aktør, for 540.', '54000000-0000-4000-8000-0000000000c0',
   now() - interval '1 day', 'Tilbaketrukket for testene i 540.'),
  -- D: editor, ikke reviewer.
  ('54000000-0000-4000-8000-0000000000d1', 'human:d-540', 'human', 'Kaller D 540',
   'Editor uten reviewer-rolle, for 540.', '54000000-0000-4000-8000-0000000000d0', null, null),
  -- E: reviewer avgrenset til et annet endepunkt.
  ('54000000-0000-4000-8000-0000000000e1', 'human:e-540', 'human', 'Kaller E 540',
   'Avgrenset reviewer for et annet endepunkt, for 540.', '54000000-0000-4000-8000-0000000000e0', null, null),
  -- F: reviewer avgrenset til nøyaktig dette endepunktet.
  ('54000000-0000-4000-8000-0000000000f2', 'human:f-540', 'human', 'Kaller F 540',
   'Avgrenset reviewer for riktig endepunkt, for 540.', '54000000-0000-4000-8000-0000000000f1', null, null),
  -- G: reviewer-tildeling som er avsluttet.
  ('54000000-0000-4000-8000-000000000091', 'human:g-540', 'human', 'Kaller G 540',
   'Avsluttet reviewer-tildeling, for 540.', '54000000-0000-4000-8000-000000000090', null, null),
  -- H: uavgrenset reviewer.
  ('54000000-0000-4000-8000-000000000081', 'human:h-540', 'human', 'Kaller H 540',
   'Uavgrenset reviewer, for 540.', '54000000-0000-4000-8000-000000000080', null, null);

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, valid_to,
   granted_by_actor_id, grant_reason, ended_by_actor_id, end_reason)
values
  ('54000000-0000-4000-8000-0000000000c0', 'reviewer', null,
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller C i 540.', null, null),
  ('54000000-0000-4000-8000-0000000000d0', 'editor', null,
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller D i 540.', null, null),
  ('54000000-0000-4000-8000-0000000000e0', 'reviewer', '54000000-0000-4000-8000-0000000000f0',
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller E i 540.', null, null),
  ('54000000-0000-4000-8000-0000000000f1', 'reviewer', (select id from fixture where name = 'weight'),
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller F i 540.', null, null),
  ('54000000-0000-4000-8000-000000000090', 'reviewer', null,
   now() - interval '2 years', now() - interval '1 year',
   (select id from fixture where name = 'editor'), 'Tildeling for kaller G i 540.',
   (select id from fixture where name = 'editor'), 'Avsluttet for testene i 540.'),
  ('54000000-0000-4000-8000-000000000080', 'reviewer', null,
   now() - interval '1 year', null,
   (select id from fixture where name = 'editor'), 'Tildeling for kaller H i 540.', null, null);

insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('54000000-0000-4000-8000-000000000001', 'journal_article', 'Testkilde for 540',
        'Testforfatter 540', (select id from fixture where name = 'editor'));

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
values
  ('54000000-0000-4000-8000-000000000021', '54000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/540-a', 'sha256:' || repeat('a', 64),
   (select id from fixture where name = 'extractor')),
  -- Uten content_hash: et sporet besøk, ikke en etterprøvbar representasjon.
  ('54000000-0000-4000-8000-000000000022', '54000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/540-b', null,
   (select id from fixture where name = 'extractor'));

create function pg_temp.make_evidence(p_id uuid, p_version uuid, p_author uuid, p_note text)
  returns void language sql as $$
  insert into knowledge.evidence_items (
    id, source_id, source_version_id, design_code, population_availability, population_detail,
    sample_size_availability, intervention_drug_id, comparator_kind,
    outcome_concept_id, outcome_detail, timepoint_availability,
    reported_direction, estimate_availability, confidence_interval_availability,
    source_locator, extraction_method, created_by_actor_id
  )
  values (
    p_id, '54000000-0000-4000-8000-000000000001', p_version,
    'randomized_controlled_trial', 'not_reported', 'Prøve i 540.',
    'not_reported', (select id from fixture where name = 'sertralin'), 'none',
    (select id from fixture where name = 'weight'), p_note,
    'not_reported', 'increase', 'not_reported', 'not_reported',
    'Avsnitt for 540', 'ai_assisted', p_author
  );
$$;

select pg_temp.make_evidence('54000000-0000-4000-8000-000000000011',
  '54000000-0000-4000-8000-000000000021',
  (select id from fixture where name = 'extractor'), 'Første funn, for 540.');
select pg_temp.make_evidence('54000000-0000-4000-8000-000000000012',
  '54000000-0000-4000-8000-000000000021',
  '54000000-0000-4000-8000-000000000081', 'Andre funn, laget av reviewer H selv, for 540.');
select pg_temp.make_evidence('54000000-0000-4000-8000-000000000013',
  '54000000-0000-4000-8000-000000000021',
  (select id from fixture where name = 'extractor'), 'Tredje funn, for avtrykkskontrollen i 540.');
select pg_temp.make_evidence('54000000-0000-4000-8000-000000000014',
  '54000000-0000-4000-8000-000000000022',
  (select id from fixture where name = 'extractor'), 'Fjerde funn, uten fingeravtrykk, for 540.');
-- E5 og E6 er urørte og brukes bare av låseprøven: en rad som allerede har vært
-- innom en avvist registrering, bærer et xmax fra det forsøket, og prøven ville
-- da målt fiksturen framfor kontrollen.
select pg_temp.make_evidence('54000000-0000-4000-8000-000000000015',
  '54000000-0000-4000-8000-000000000021',
  (select id from fixture where name = 'extractor'), 'Femte funn, urørt, for låseprøven i 540.');
select pg_temp.make_evidence('54000000-0000-4000-8000-000000000016',
  '54000000-0000-4000-8000-000000000021',
  (select id from fixture where name = 'extractor'), 'Sjette funn, urørt, for mutasjonen i 540.');

-- Avtrykkene må beregnes før rollen byttes: workflow.evidence_extraction_digest()
-- er ikke kjørbar for authenticated, og det er hele poenget — avtrykket er noe
-- flaten får utlevert, ikke noe klienten regner ut selv.
create temporary table digest (label text primary key, value text) on commit drop;
insert into digest
select 'e' || right(e.id::text, 2), workflow.evidence_extraction_digest(e.id)
from knowledge.evidence_items e
where e.id in (
  '54000000-0000-4000-8000-000000000011', '54000000-0000-4000-8000-000000000012',
  '54000000-0000-4000-8000-000000000013', '54000000-0000-4000-8000-000000000014',
  '54000000-0000-4000-8000-000000000015', '54000000-0000-4000-8000-000000000016'
);
grant select on digest to authenticated;

-- ===========================================================================
-- Del 3 — Hver autorisasjonsgren, prøvd med den faktiske funksjonen
-- ===========================================================================
-- Kallet er det samme i hver gren; bare hvem som gjør det er forskjellig.
create function pg_temp.registration_sql(
  p_evidence uuid, p_digest text, p_outcome text default 'uncertain',
  p_source_access text default 'original_source',
  p_fields text default $q$array['source_locator', 'estimate']$q$,
  p_findings text default $q$'Prøve i 540: kontrollen konkluderte ikke.'$q$
)
  returns text language sql as $$
  select 'select api.register_human_extraction_verification('
    || quote_literal(p_evidence) || '::uuid, '
    || quote_literal(p_digest) || ', '
    || quote_literal(p_outcome) || ', '
    || quote_literal(p_source_access) || ', '
    || p_fields || ', '
    || $q$'Prøve i 540: kontroll av ekstraksjonen mot kilden.', $q$
    || p_findings || ')';
$$;

-- A — ingen aktørrad
select set_config('request.jwt.claims',
                  '{"sub":"54000000-0000-4000-8000-0000000000a0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000011',
    (select value from digest where label = 'e11')),
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en kaller uten aktørrad kan ikke registrere en ekstraksjonskontroll i sitt eget navn'
);
reset role;

-- B — aktør, ingen rolletildeling
select set_config('request.jwt.claims',
                  '{"sub":"54000000-0000-4000-8000-0000000000b0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000011',
    (select value from digest where label = 'e11')),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'en aktør uten noen rolletildeling avvises med rollefeilen, ikke aktørfeilen'
);
reset role;

-- C — tilbaketrukket aktør med gyldig reviewer-tildeling
select set_config('request.jwt.claims',
                  '{"sub":"54000000-0000-4000-8000-0000000000c0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000011',
    (select value from digest where label = 'e11')),
  '42501', 'Aktøren er trukket tilbake og kan ikke registrere en faglig vurdering.',
  'en tilbaketrukket aktør kan ikke kontrollere en ekstraksjon, selv med gyldig rolle'
);
reset role;

-- D — editor, ikke reviewer
select set_config('request.jwt.claims',
                  '{"sub":"54000000-0000-4000-8000-0000000000d0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000011',
    (select value from digest where label = 'e11')),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'editor-rollen gir ikke rett til å kontrollere en ekstraksjon'
);
reset role;

-- E — reviewer avgrenset til et annet endepunkt
select set_config('request.jwt.claims',
                  '{"sub":"54000000-0000-4000-8000-0000000000e0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000011',
    (select value from digest where label = 'e11')),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'en avgrenset reviewer-tildeling dekker ikke et funn om et annet endepunkt'
);
reset role;

-- G — avsluttet reviewer-tildeling
select set_config('request.jwt.claims',
                  '{"sub":"54000000-0000-4000-8000-000000000090"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000011',
    (select value from digest where label = 'e11')),
  '42501', 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.',
  'en avsluttet tildeling gir ingen rett, uansett at raden fortsatt finnes'
);
reset role;

-- Uinnlogget: ingen sub i det hele tatt.
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000011',
    (select value from digest where label = 'e11')),
  '42501', 'Kontoen din er ikke knyttet til en aktør i Antidep.',
  'en kaller uten sesjon avvises før noe leses'
);
reset role;

-- F — avgrenset reviewer for riktig endepunkt: lykkes
select set_config('request.jwt.claims',
                  '{"sub":"54000000-0000-4000-8000-0000000000f1"}', true);
set local role authenticated;
select lives_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000011',
    (select value from digest where label = 'e11')),
  'en reviewer avgrenset til nøyaktig dette endepunktet kan registrere kontrollen'
);
reset role;

-- ===========================================================================
-- Del 4 — Konsekvensen: raden og auditraden
-- ===========================================================================
create temporary table result (label text primary key, id uuid not null) on commit drop;
insert into result
select 'f-uncertain', ev.id
from workflow.evidence_verifications ev
where ev.evidence_item_id = '54000000-0000-4000-8000-000000000011';

select results_eq(
  $$
    select ev.verifier_actor_id, ev.verified_item_creator_actor_id,
           ev.outcome::text, ev.source_access::text,
           ev.checked_fields = array['source_locator', 'estimate']::workflow.evidence_check_field[],
           ev.agent_run_id, ev.verified_at <= ev.created_at
    from workflow.evidence_verifications ev
    where ev.id = (select id from result where label = 'f-uncertain')
  $$,
  $$
    values ('54000000-0000-4000-8000-0000000000f2'::uuid,
            (select id from fixture where name = 'extractor'),
            'uncertain', 'original_source', true, null::uuid, true)
  $$,
  'raden bærer nøyaktig det oppgitte, attribuert til kallerens egen aktør, uten agentkjøring'
);

select results_eq(
  $$
    select e.operation::text, e.object_schema, e.object_table, e.actor_id,
           e.old_revision_or_snapshot, e.new_revision_or_snapshot ->> 'outcome'
    from audit.events e
    where e.object_id = (select id from result where label = 'f-uncertain')
  $$,
  $$
    values ('evidence_verification_registered', 'workflow', 'evidence_verifications',
            '54000000-0000-4000-8000-0000000000f2'::uuid, null::jsonb, 'uncertain')
  $$,
  'auditraden peker på kontrollen, attribueres til revieweren, og bærer utfallet'
);

-- ===========================================================================
-- Del 5 — Radinvariantene arves uendret fra tabellen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"54000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;

-- Avtrykket er utdatert etter kontrollen i Del 3: den nye raden er en del av
-- grunnlaget. Det prøves eksplisitt i Del 6; her brukes funn E3, som ingen har
-- rørt.
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000013',
    (select value from digest where label = 'e13'),
    'verified', 'derived_summary',
    $q$array['source_locator', 'estimate']$q$, 'null'),
  '23514', null,
  'en bekreftelse kan ikke hvile på et avledet sammendrag alene (ANTIDEP_CONSTITUTION.md §11)'
);
-- Kildepekerkravet lå fram til migrasjon 005y på raden. Det tvang enhver
-- bekreftelse til å føre opp et felt operasjonen kanskje ikke gjorde —
-- mennesket blir aldri spurt om kildepekeren. Kravet er flyttet til
-- publiseringsgatens G5b, som leser unionen over funnets kontroller, og er
-- prøvd der (250). Her prøves bare at raden ikke lenger må lyve.
--
-- Kontrollen avvises likevel, men av det nye kravet fra 005x: uten et
-- maskinbevis kan ingen menneskelig bekreftelse registreres.
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000013',
    (select value from digest where label = 'e13'),
    'verified', 'original_source', $q$array['estimate']$q$, 'null'),
  '22023',
  'Evidensfunnet mangler kildeforankring for intervention_arm, outcome, reported_direction, availability_semantics, og kan ikke bekreftes.',
  'en bekreftelse uten kildeforankring avvises, og ikke av et radkrav om kildepekeren'
);
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000013',
    (select value from digest where label = 'e13'),
    'needs_correction', 'original_source', $q$array[]::text[]$q$,
    $q$'Kontrollen rakk ikke å gå gjennom noe felt.'$q$),
  '23514', null,
  'en kontroll som ikke kontrollerte noe felt avvises'
);
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000013',
    (select value from digest where label = 'e13'),
    'needs_correction', 'original_source',
    $q$array['source_locator']$q$, 'null'),
  '23514', null,
  'et annet utfall enn verified må si hva som er galt'
);
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000014',
    (select value from digest where label = 'e14'),
    'uncertain', 'verifiable_representation'),
  '22023', 'Kildeversjonen evidensfunnet peker på har ingen lagret fingeravtrykk (content_hash).',
  'verifiable_representation krever at kildeversjonen faktisk er etterprøvbar'
);
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000013',
    (select value from digest where label = 'e13'), 'godkjent'),
  '22023', $q$'godkjent' er ikke et kjent verifikasjonsutfall.$q$,
  'et ukjent utfall avvises med en setning som sier hva som er galt'
);
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000013',
    (select value from digest where label = 'e13'), 'uncertain', 'original_source',
    $q$array['source_locator', 'stemning']$q$),
  '22023', 'Ett eller flere kontrollerte felter er ikke et kjent felt.',
  'et ukjent kontrollfelt avvises med sin egen setning'
);
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-0000000000ff',
    (select value from digest where label = 'e13')),
  'P0002', $q$Evidensfunnet '54000000-0000-4000-8000-0000000000ff' finnes ikke.$q$,
  'et evidensfunn som ikke finnes avvises etter autorisasjonen, ikke før'
);

-- Selvverifikasjon: H har mandatet, og har laget E2 selv. Da er det
-- evidence_verifications_separate_actor_check som feller forsøket, ikke mandatet.
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000012',
    (select value from digest where label = 'e12')),
  '23514', null,
  'en reviewer kan ikke kontrollere en ekstraksjon hen selv har laget'
);
reset role;

-- ===========================================================================
-- Del 6 — Kontrollen gjelder det grunnlaget revieweren faktisk så
-- ===========================================================================
-- En annen kontroll registreres på E3 mens «revieweren» arbeider.
insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
   outcome, source_access, checked_fields, findings, rationale, verified_at)
select '54000000-0000-4000-8000-000000000013', e.created_by_actor_id,
       (select id from fixture where name = 'extraction_verifier'),
       'uncertain', 'verifiable_representation',
       array['source_locator']::workflow.evidence_check_field[],
       'Kom til mens vurderingen pågikk, i 540.',
       'Prøve i 540: en annen kontroll registreres i vinduet.', now()
from knowledge.evidence_items e
where e.id = '54000000-0000-4000-8000-000000000013';

select isnt(
  workflow.evidence_extraction_digest('54000000-0000-4000-8000-000000000013'),
  (select value from digest where label = 'e13'),
  'avtrykket endrer seg når en kontroll kommer til'
);

select set_config('request.jwt.claims',
                  '{"sub":"54000000-0000-4000-8000-000000000080"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000013',
    (select value from digest where label = 'e13')),
  '23001', 'Grunnlaget for ekstraksjonskontrollen er endret etter at du hentet det fram.',
  'en kontroll registrert på et utdatert avtrykk avvises framfor å dekke noe revieweren ikke så'
);
reset role;

-- Kildens status er en del av avtrykket: en kilde som blir trukket tilbake mens
-- vurderingen pågår, endrer hva kontrollen ville dekket (publiseringsgatens G7).
create temporary table digest_before (value text) on commit drop;
insert into digest_before
select workflow.evidence_extraction_digest('54000000-0000-4000-8000-000000000011');
update knowledge.sources
set source_status = 'retracted',
    status_note = 'Trukket tilbake i prøven i 540.'
where id = '54000000-0000-4000-8000-000000000001';
select isnt(
  workflow.evidence_extraction_digest('54000000-0000-4000-8000-000000000011'),
  (select value from digest_before),
  'avtrykket endrer seg når kilden får en annen status'
);
update knowledge.sources
set source_status = 'active', status_note = null
where id = '54000000-0000-4000-8000-000000000001';

-- ===========================================================================
-- Del 7 — Raden er append-only
-- ===========================================================================
select throws_ok(
  $$update workflow.evidence_verifications set outcome = 'verified'
    where id = (select id from result where label = 'f-uncertain')$$,
  '23001', null,
  'en registrert ekstraksjonskontroll kan ikke endres'
);
select throws_ok(
  $$delete from workflow.evidence_verifications
    where id = (select id from result where label = 'f-uncertain')$$,
  '23001', null,
  'en registrert ekstraksjonskontroll kan ikke slettes'
);

-- ===========================================================================
-- Del 8 — Mutasjonstest: mandatet er radens egen garanti
--
-- workflow.assert_reviewer_authorized(uuid) byttes ut med en variant som slipper
-- alle gjennom og returnerer en aktør uten reviewer-rolle. Uten mandatet på
-- raden ville kallet da lyktes. Det gjør det ikke: triggeren fra migrasjon 005q
-- avviser, og den avvisningen er det som gjør publiseringsgatens G4 og G5 verdt
-- noe.
-- ===========================================================================
create or replace function workflow.assert_reviewer_authorized(p_scope_concept_id uuid default null)
  returns uuid language sql security definer set search_path = '' as $mutant$
  select '54000000-0000-4000-8000-0000000000d1'::uuid
$mutant$;

select set_config('request.jwt.claims',
                  '{"sub":"54000000-0000-4000-8000-0000000000d0"}', true);
set local role authenticated;
select throws_ok(
  pg_temp.registration_sql('54000000-0000-4000-8000-000000000014',
    (select value from digest where label = 'e14')),
  '42501', 'Verifikatoraktøren hadde ikke mandat til å kontrollere denne ekstraksjonen mot kilden.',
  'raden avvises av sin egen mandatkontroll selv når skriveveiens autorisasjon er mutert bort'
);
reset role;

-- Tilbake til den ekte kontrollen for resten av filen.
drop function workflow.assert_reviewer_authorized(uuid);
create function workflow.assert_reviewer_authorized(p_scope_concept_id uuid default null)
  returns uuid language plpgsql set search_path = '' as $real$
declare
  v_actor_id uuid;
  v_retired_at timestamptz;
begin
  select a.id, a.retired_at into v_actor_id, v_retired_at
  from provenance.actors a
  where a.auth_user_id = auth.uid();

  if v_actor_id is null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kontoen din er ikke knyttet til en aktør i Antidep.';
  end if;

  if v_retired_at is not null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Aktøren er trukket tilbake og kan ikke registrere en faglig vurdering.';
  end if;

  if not exists (
    select 1
    from workflow.user_roles ur
    where ur.user_id = auth.uid()
      and ur.role_code = 'reviewer'
      and ur.valid_from <= statement_timestamp()
      and (ur.valid_to is null or ur.valid_to > statement_timestamp())
      and (p_scope_concept_id is null or ur.scope_id is null
           or ur.scope_id = p_scope_concept_id)
  ) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Brukeren har ikke gyldig reviewer-rolle for dette innholdsområdet.';
  end if;

  return v_actor_id;
end;
$real$;

-- ===========================================================================
-- Del 9 — Kontrollen av «det du faktisk så» tar radlåsen
--
-- Prøven på selve kappløpet krever to forbindelser og ligger i
-- scripts/db-lock-test.sh. Denne delen fanger at låsen er der: raden er ulåst
-- før kallet og låst etter det, og en mutert kontroll uten lås lar den stå ulåst.
-- ===========================================================================
select is(
  (select e.xmax::text from knowledge.evidence_items e
   where e.id = '54000000-0000-4000-8000-000000000015'),
  '0',
  'evidensfunnet er ulåst før kontrollen kalles'
);
select lives_ok(
  $$
    select workflow.assert_extraction_unchanged(
      '54000000-0000-4000-8000-000000000015',
      workflow.evidence_extraction_digest('54000000-0000-4000-8000-000000000015'))
  $$,
  'kontrollen passerer når grunnlaget er uendret'
);
select isnt(
  (select e.xmax::text from knowledge.evidence_items e
   where e.id = '54000000-0000-4000-8000-000000000015'),
  '0',
  'og raden er låst etterpå: låsen holdes ut transaksjonen (migrasjon 005s)'
);

create or replace function workflow.assert_extraction_unchanged(
  p_evidence_item_id uuid,
  p_seen_extraction_digest text
)
  returns void language plpgsql security definer set search_path = '' as $mutant$
begin
  if workflow.evidence_extraction_digest(p_evidence_item_id)
     is distinct from p_seen_extraction_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Mutert kontroll uten lås.';
  end if;
end;
$mutant$;

select lives_ok(
  $$
    select workflow.assert_extraction_unchanged(
      '54000000-0000-4000-8000-000000000016',
      workflow.evidence_extraction_digest('54000000-0000-4000-8000-000000000016'))
  $$,
  'den muterte kontrollen sammenligner fortsatt, og passerer'
);
select is(
  (select e.xmax::text from knowledge.evidence_items e
   where e.id = '54000000-0000-4000-8000-000000000016'),
  '0',
  'men den holder ingen lås: uten FOR UPDATE er kontrollen bare et øyeblikksbilde, og det er kappløpet migrasjon 005s lukker'
);

select finish();
rollback;
