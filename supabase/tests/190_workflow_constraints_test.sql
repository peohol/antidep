-- Migrasjon 005 — constraints i workflow og provenance.
--
-- Verifiserer at reglene DATABASE_ARCHITECTURE.md §29-§32, §47, §57 og §58 og
-- ANTIDEP_CONSTITUTION.md §10, §11, §12 og §14 krever, faktisk håndheves av
-- databasen og ikke bare er dokumentert.
--
-- Kjernen er skillet mellom generering og kontroll: en verifikator kan ikke
-- kontrollere sitt eget arbeid, en bekreftelse kan ikke hvile på et avledet
-- sammendrag alene, og en faglig godkjenning kan bare komme fra et menneske med
-- gyldig reviewer-rolle.
--
-- SQLSTATE: 23514 = check_violation, 23503 = foreign_key_violation,
-- 23505 = unique_violation, 23P01 = exclusion_violation,
-- 42501 = insufficient_privilege.
begin;

create extension if not exists pgtap with schema extensions;

select plan(68);

-- ---------------------------------------------------------------------------
-- Testdata som bare finnes inne i denne transaksjonen
-- ---------------------------------------------------------------------------
create function pg_temp.actor(key text) returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = key
$$;

create function pg_temp.user_id(label text) returns uuid language sql stable as $$
  select id from auth.users where email = label
$$;

create function pg_temp.seeded_revision(drug text) returns uuid language sql stable as $$
  select r.id
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  join catalog.drugs d on d.id = cl.subject_drug_id
  where d.canonical_name = drug and r.revision_number = 1
$$;

create function pg_temp.seeded_evidence(drug text) returns uuid language sql stable as $$
  select e.id
  from knowledge.evidence_items e
  join catalog.drugs d on d.id = e.intervention_drug_id
  where d.canonical_name = drug
    -- Ikke funnet denne filen selv lager lenger nede for å prøve
    -- selvverifikasjonsregelen. `is distinct from` og ikke `<>`: aktøren finnes
    -- ikke ennå når funksjonen defineres, og NULL <> x er ukjent, ikke sant.
    and e.created_by_actor_id
        is distinct from pg_temp.actor('agent:extraction-verifier-test')
$$;

insert into auth.users (id, email)
values (gen_random_uuid(), 'reviewer@test.invalid'),
       (gen_random_uuid(), 'editor@test.invalid'),
       (gen_random_uuid(), 'scoped@test.invalid'),
       (gen_random_uuid(), 'scopepair@test.invalid'),
       (gen_random_uuid(), 'backdated@test.invalid'),
       (gen_random_uuid(), 'former@test.invalid');

insert into provenance.actors
  (actor_type, actor_key, display_name, description, auth_user_id, agent_role)
values
  ('system', 'system:rolleforvaltning', 'Testrolleforvaltning',
   'Systemaktør som tildeler roller i testdata.', null, null),
  ('agent', 'agent:verifier-test', 'Testverifikator',
   'KI-aktør i kontrollrollen i testdata.', null, 'adversarial_review'),
  -- Egen aktør for claim-verifikasjonene: migrasjon 005j krever at den som
  -- kontrollerer en påstand mot grunnlaget har mandatet til det, og for en agent
  -- er mandatet rollen citation_support_verification. agent:verifier-test har en
  -- annen rolle med vilje, slik at avvisningen kan prøves med den.
  ('agent', 'agent:citation-verifier-test', 'Test claim-verifikator',
   'KI-aktør i sitat- og kildestøtterollen i testdata.', null, 'citation_support_verification'),
  -- Egen aktør for ekstraksjonsverifikasjonene, av samme grunn: migrasjon 005q
  -- krever at den som kontrollerer en ekstraksjon mot kilden har mandatet til
  -- det, og for en agent er mandatet rollen extraction_verification.
  -- agent:verifier-test har en annen rolle med vilje, slik at avvisningen kan
  -- prøves med den.
  ('agent', 'agent:extraction-verifier-test', 'Test ekstraksjonsverifikator',
   'KI-aktør i ekstraksjonskontrollrollen i testdata.', null, 'extraction_verification'),
  ('human', 'human:reviewer-test', 'Test Reviewer',
   'Menneskelig fagredaktør med reviewer-rolle i testdata.',
   pg_temp.user_id('reviewer@test.invalid'), null),
  ('human', 'human:editor-test', 'Test Editor',
   'Menneskelig bidragsyter med kun editor-rolle i testdata.',
   pg_temp.user_id('editor@test.invalid'), null),
  ('human', 'human:scoped-test', 'Test Scoped Reviewer',
   'Menneskelig fagredaktør med reviewer-rolle avgrenset til ett innholdsområde i testdata.',
   pg_temp.user_id('scoped@test.invalid'), null),
  ('human', 'human:unlinked-test', 'Test Ukoblet Redaktør',
   'Menneskelig aktør uten brukerkonto i testdata.', null, null),
  ('human', 'human:backdated-test', 'Test Tilbakedatert Reviewer',
   'Menneskelig fagredaktør hvis rolletildeling er tilbakedatert i testdata.',
   pg_temp.user_id('backdated@test.invalid'), null);

insert into workflow.user_roles
  (user_id, role_code, scope_id, granted_by_actor_id, grant_reason)
values
  (pg_temp.user_id('reviewer@test.invalid'), 'reviewer', null,
   pg_temp.actor('system:rolleforvaltning'), 'Testtildeling av reviewer-rolle.'),
  (pg_temp.user_id('editor@test.invalid'), 'editor', null,
   pg_temp.actor('system:rolleforvaltning'), 'Testtildeling av editor-rolle.'),
  (pg_temp.user_id('editor@test.invalid'), 'admin', null,
   pg_temp.actor('system:rolleforvaltning'), 'Testtildeling av admin-rolle.');

-- En påstandsrevisjon forfattet av den mandaterte testverifikatoren.
--
-- Selvverifikasjonsregelen (claim_verifications_separate_actor_check) og
-- mandatregelen (migrasjon 005j) er to grenser, og den ene skjuler den andre om
-- fiksturen ikke skiller dem: forfatteren av de seedede revisjonene er
-- agent:claim-synthesis, som avvises av mandatet før CHECK-en i det hele tatt
-- prøves. Denne revisjonen har en forfatter som *har* mandatet, og er derfor det
-- eneste grunnlaget der selvverifikasjonen er det som faktisk feller forsøket.
with c as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', con.id, d.id, pg_temp.actor('agent:citation-verifier-test')
  from catalog.clinical_concepts con, catalog.drugs d
  where con.canonical_label = 'vektendring' and d.canonical_name = 'mirtazapin'
  returning id, knowledge_type, subject_drug_id, created_by_actor_id
)
insert into knowledge.claim_revisions
  (claim_id, revision_number, knowledge_type, subject_drug_id,
   statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id)
select c.id, 1, c.knowledge_type, c.subject_drug_id,
       'Testpåstand formulert av den mandaterte testverifikatoren, for å prøve selvverifikasjonsregelen.',
       'Gjelder bare som testdata i 190.',
       'none', 'Testusikkerhet.', c.created_by_actor_id
from c;

create function pg_temp.self_authored_revision() returns uuid language sql stable as $$
  select r.id from knowledge.claim_revisions r
  where r.created_by_actor_id = pg_temp.actor('agent:citation-verifier-test')
$$;

-- Samme grep for ekstraksjonskontrollen: forfatteren av de seedede
-- evidensfunnene er agent:evidence-extraction, som avvises av mandatet (005q)
-- før evidence_verifications_separate_actor_check i det hele tatt prøves. Dette
-- funnet har en forfatter som *har* mandatet, og er derfor det eneste grunnlaget
-- der selvverifikasjonen er det som faktisk feller forsøket.
insert into knowledge.evidence_items (
  source_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind,
  outcome_concept_id, outcome_detail, timepoint_availability,
  reported_direction, estimate_availability, confidence_interval_availability,
  source_locator, extraction_method, created_by_actor_id
)
select
  e.source_id, 'randomized_controlled_trial', 'not_reported',
  'Testdata i 190; bare til for å prøve selvverifikasjonsregelen.',
  'not_reported', e.intervention_drug_id, 'none',
  e.outcome_concept_id, 'Testendepunkt i 190.', 'not_reported',
  'increase', 'not_reported', 'not_reported',
  'Avsnitt for 190', 'ai_assisted', pg_temp.actor('agent:extraction-verifier-test')
from knowledge.evidence_items e
where e.id = pg_temp.seeded_evidence('sertralin');

create function pg_temp.self_authored_evidence() returns uuid language sql stable as $$
  select e.id from knowledge.evidence_items e
  where e.created_by_actor_id = pg_temp.actor('agent:extraction-verifier-test')
$$;

-- Scoped reviewer: godkjent for «depressiv lidelse», ikke for «vektendring».
insert into workflow.user_roles
  (user_id, role_code, scope_id, granted_by_actor_id, grant_reason)
select pg_temp.user_id('scoped@test.invalid'), 'reviewer', c.id,
       pg_temp.actor('system:rolleforvaltning'),
       'Testtildeling av reviewer-rolle avgrenset til ett innholdsområde.'
from catalog.clinical_concepts c
where c.canonical_label = 'depressiv lidelse';

-- Egen konto for scopetestene på selve medlemskapsmodellen. Den har bevisst
-- ingen aktør, slik at tildelingene under aldri kan påvirke reviewtestene.
insert into workflow.user_roles
  (user_id, role_code, scope_id, granted_by_actor_id, grant_reason)
select pg_temp.user_id('scopepair@test.invalid'), 'reviewer', c.id,
       pg_temp.actor('system:rolleforvaltning'),
       'Testtildeling for det første innholdsområdet.'
from catalog.clinical_concepts c
where c.canonical_label = 'depressiv lidelse';

-- Tilbakedatert tildeling: raden opprettes nå, men valid_from peker til 2020.
-- Det er en legitim registrering av en eksisterende rettighet, og skal virke
-- framover. Den skal derimot ikke kunne legitimere en beslutning fra før raden
-- fantes.
insert into workflow.user_roles
  (user_id, role_code, granted_by_actor_id, grant_reason, valid_from)
values
  (pg_temp.user_id('backdated@test.invalid'), 'reviewer',
   pg_temp.actor('system:rolleforvaltning'),
   'Registrering av en rettighet som formelt gjaldt fra tidligere.',
   timestamptz '2020-01-01T00:00:00Z');

-- Tidligere reviewer: rollen var gyldig fram til 1. mars 2026.
insert into workflow.user_roles
  (user_id, role_code, granted_by_actor_id, grant_reason,
   valid_from, valid_to, ended_by_actor_id, end_reason)
values
  (pg_temp.user_id('former@test.invalid'), 'reviewer',
   pg_temp.actor('system:rolleforvaltning'), 'Testtildeling som senere ble tilbakekalt.',
   timestamptz '2026-01-01T00:00:00Z', timestamptz '2026-03-01T00:00:00Z',
   pg_temp.actor('system:rolleforvaltning'), 'Testtilbakekalling.');

-- ---------------------------------------------------------------------------
-- provenance.actors (DATABASE_ARCHITECTURE.md §32, ANTIDEP_CONSTITUTION.md §10)
-- ---------------------------------------------------------------------------
select lives_ok(
  $$
    insert into provenance.actors (actor_type, actor_key, display_name, description)
    values ('deterministic_process', 'process:festimport', 'Testimportjobb',
            'Deterministisk importjobb i testdata.')
  $$,
  'en deterministisk prosess kan registreres som aktør uten agentrolle'
);
select throws_ok(
  $$
    insert into provenance.actors (actor_type, actor_key, display_name, description)
    values ('agent', 'agent:uten-rolle', 'Testagent uten rolle',
            'KI-aktør uten eksplisitt rolle i testdata.')
  $$,
  '23514', null,
  'en KI-aktør uten eksplisitt agentrolle avvises (ANTIDEP_CONSTITUTION.md §10)'
);
select throws_ok(
  $$
    insert into provenance.actors
      (actor_type, actor_key, display_name, description, agent_role)
    values ('human', 'human:med-agentrolle', 'Testmenneske',
            'Menneskelig aktør med agentrolle i testdata.', 'evidence_extraction')
  $$,
  '23514', null,
  'et menneske kan ikke ha en agentrolle'
);
select throws_ok(
  $$
    insert into provenance.actors
      (actor_type, actor_key, display_name, description, auth_user_id, agent_role)
    select 'agent', 'agent:med-konto', 'Testagent med konto',
           'KI-aktør med brukerkonto i testdata.',
           pg_temp.user_id('reviewer@test.invalid'), 'evidence_extraction'
  $$,
  '23514', null,
  'en agent kan ikke ha en brukerkonto (MVP_IMPLEMENTATION_PLAN.md §16)'
);
select throws_ok(
  $$
    insert into provenance.actors (actor_type, actor_key, display_name, description)
    values ('system', 'agent:verifier-test', 'Duplikat', 'Duplikatnøkkel i testdata.')
  $$,
  '23505', null,
  'to aktører kan ikke dele maskinnøkkel'
);
select throws_ok(
  $$
    insert into provenance.actors
      (actor_type, actor_key, display_name, description, auth_user_id)
    select 'human', 'human:dobbeltkonto', 'Testmenneske to',
           'Andre aktør på samme brukerkonto i testdata.',
           pg_temp.user_id('reviewer@test.invalid')
  $$,
  '23505', null,
  'én brukerkonto kan ikke ha to aktører, slik at kravet om atskilte aktører ikke kan omgås'
);
select throws_ok(
  $$
    insert into provenance.actors (actor_type, actor_key, display_name, description)
    values ('system', 'Ugyldig Nøkkel', 'Testaktør', 'Ugyldig nøkkelformat i testdata.')
  $$,
  '23514', null,
  'aktørnøkkelen må følge det stabile maskinformatet'
);
select throws_ok(
  $$
    insert into provenance.actors
      (actor_type, actor_key, display_name, description, retired_at)
    values ('system', 'system:stille-avvikling', 'Testaktør',
            'Aktør trukket tilbake uten begrunnelse i testdata.', now())
  $$,
  '23514', null,
  'en aktør kan ikke trekkes tilbake uten begrunnelse (ANTIDEP_CONSTITUTION.md §14)'
);
select throws_ok(
  $$delete from auth.users where email = 'reviewer@test.invalid'$$,
  '23503', null,
  'en brukerkonto en aktør peker på kan ikke slettes bort (DATABASE_ARCHITECTURE.md §32)'
);

-- ---------------------------------------------------------------------------
-- workflow.user_roles (DATABASE_ARCHITECTURE.md §47, §58)
-- ---------------------------------------------------------------------------
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, granted_by_actor_id, grant_reason)
    select pg_temp.user_id('reviewer@test.invalid'), 'reviewer',
           pg_temp.actor('system:rolleforvaltning'), 'Dublett av en løpende tildeling.'
  $$,
  '23P01', null,
  'to overlappende tildelinger av samme rolle uten scope avvises, slik at tilbakekalling er entydig'
);
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, scope_id, granted_by_actor_id, grant_reason)
    select pg_temp.user_id('scoped@test.invalid'), 'reviewer', c.id,
           pg_temp.actor('system:rolleforvaltning'), 'Dublett av en scoped tildeling.'
    from catalog.clinical_concepts c where c.canonical_label = 'depressiv lidelse'
  $$,
  '23P01', null,
  'to overlappende tildelinger av samme rolle med samme scope avvises'
);
select lives_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, scope_id, granted_by_actor_id, grant_reason)
    select pg_temp.user_id('scopepair@test.invalid'), 'reviewer', c.id,
           pg_temp.actor('system:rolleforvaltning'), 'Tildeling for et annet innholdsområde.'
    from catalog.clinical_concepts c where c.canonical_label = 'vektendring'
  $$,
  'samme rolle kan tildeles for et annet innholdsområde uten å kollidere'
);
select lives_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, granted_by_actor_id, grant_reason, valid_from, valid_to,
       ended_by_actor_id, end_reason)
    select pg_temp.user_id('former@test.invalid'), 'reviewer',
           pg_temp.actor('system:rolleforvaltning'), 'Ny periode etter tilbakekalling.',
           timestamptz '2026-04-01T00:00:00Z', timestamptz '2026-05-01T00:00:00Z',
           pg_temp.actor('system:rolleforvaltning'), 'Planlagt utløp.'
  $$,
  'en ny tildeling i en periode som ikke overlapper den gamle er lovlig'
);
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, granted_by_actor_id, grant_reason, valid_from, valid_to,
       ended_by_actor_id, end_reason)
    select pg_temp.user_id('former@test.invalid'), 'publisher',
           pg_temp.actor('system:rolleforvaltning'), 'Invertert gyldighetsperiode.',
           timestamptz '2026-06-01T00:00:00Z', timestamptz '2026-05-01T00:00:00Z',
           pg_temp.actor('system:rolleforvaltning'), 'Testavslutning.'
  $$,
  '23514', null,
  'en invertert gyldighetsperiode avvises (DATABASE_ARCHITECTURE.md §58)'
);
-- De to pardannelsesreglene testes hver for seg. Utelates både ansvarlig og
-- begrunnelse, ville begge reglene slått inn, og hver av assertionene ville
-- passert selv om den andre regelen var borte.
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, granted_by_actor_id, grant_reason, valid_to, end_reason)
    select pg_temp.user_id('former@test.invalid'), 'publisher',
           pg_temp.actor('system:rolleforvaltning'), 'Avsluttet uten ansvarlig.',
           timestamptz '2027-01-01T00:00:00Z', 'Testavslutning uten ansvarlig.'
  $$,
  '23514', null,
  'en avgrenset tildeling må si hvem som avgrenset den (ANTIDEP_CONSTITUTION.md §14)'
);
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, granted_by_actor_id, grant_reason, valid_to, ended_by_actor_id)
    select pg_temp.user_id('former@test.invalid'), 'publisher',
           pg_temp.actor('system:rolleforvaltning'), 'Avsluttet uten begrunnelse.',
           timestamptz '2027-01-01T00:00:00Z', pg_temp.actor('system:rolleforvaltning')
  $$,
  '23514', null,
  'en avgrenset tildeling må si hvorfor den ble avgrenset (ANTIDEP_CONSTITUTION.md §14)'
);
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, granted_by_actor_id, grant_reason)
    select gen_random_uuid(), 'reviewer',
           pg_temp.actor('system:rolleforvaltning'), 'Tildeling til ukjent konto.'
  $$,
  '23503', null,
  'en rolletildeling til en ukjent brukerkonto avvises'
);
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, scope_id, granted_by_actor_id, grant_reason)
    select pg_temp.user_id('former@test.invalid'), 'publisher', gen_random_uuid(),
           pg_temp.actor('system:rolleforvaltning'), 'Tildeling med ukjent scope.'
  $$,
  '23503', null,
  'et scope som ikke finnes avvises'
);
select throws_ok(
  $$
    insert into workflow.user_roles
      (user_id, role_code, granted_by_actor_id, grant_reason)
    select pg_temp.user_id('former@test.invalid'), 'publisher',
           pg_temp.actor('system:rolleforvaltning'), '   '
  $$,
  '23514', null,
  'en rolletildeling uten reell begrunnelse avvises'
);
-- scope_type følger pekeren og kan ikke settes uavhengig av den.
select is(
  (select scope_type::text
   from workflow.user_roles
   where user_id = pg_temp.user_id('scoped@test.invalid')
   limit 1),
  'clinical_concept',
  'scope_type er avledet til clinical_concept når scope_id er satt'
);
select is(
  (select scope_type
   from workflow.user_roles
   where user_id = pg_temp.user_id('reviewer@test.invalid')),
  null,
  'scope_type er NULL når tildelingen ikke er avgrenset'
);

-- ---------------------------------------------------------------------------
-- workflow.evidence_verifications (DATABASE_ARCHITECTURE.md §29,
-- ANTIDEP_CONSTITUTION.md §11)
-- ---------------------------------------------------------------------------
create function pg_temp.insert_evidence_verification(
  overrides jsonb default '{}'::jsonb
) returns void language plpgsql as $$
declare
  payload jsonb;
begin
  payload := jsonb_build_object(
    'verifier', 'agent:extraction-verifier-test',
    'outcome', 'verified',
    'source_access', 'original_source',
    'checked_fields', '["source_locator", "estimate", "population"]'::jsonb,
    'rationale', 'Testkontroll av ekstraksjonen mot kildeversjonen.',
    'evidence', 'seeded'
  ) || overrides;

  insert into workflow.evidence_verifications (
    evidence_item_id, verified_item_creator_actor_id, verifier_actor_id,
    outcome, source_access, checked_fields, findings, rationale, verified_at
  )
  select
    e.id,
    coalesce(
      (payload ->> 'creator_override')::uuid,
      e.created_by_actor_id
    ),
    pg_temp.actor(payload ->> 'verifier'),
    (payload ->> 'outcome')::workflow.verification_outcome,
    (payload ->> 'source_access')::workflow.verification_source_access,
    (select coalesce(
       array_agg(value::text::workflow.evidence_check_field),
       array[]::workflow.evidence_check_field[])
     from jsonb_array_elements_text(payload -> 'checked_fields') as value),
    payload ->> 'findings',
    payload ->> 'rationale',
    coalesce((payload ->> 'verified_at')::timestamptz, now())
  from knowledge.evidence_items e
  where e.id = case payload ->> 'evidence'
                 when 'self_authored' then pg_temp.self_authored_evidence()
                 else pg_temp.seeded_evidence('sertralin')
               end;
end;
$$;

select lives_ok(
  $$select pg_temp.insert_evidence_verification()$$,
  'en separat verifikator kan bekrefte en ekstraksjon mot originalkilden'
);
-- Mandatet (migrasjon 005q) er en annen grense enn selvverifikasjonsregelen, og
-- den prøves med en agent som har en annen rolle enn extraction_verification.
select throws_ok(
  $$select pg_temp.insert_evidence_verification(
      '{"verifier": "agent:verifier-test"}'::jsonb)$$,
  '42501', null,
  'en agent uten rollen extraction_verification kan ikke kontrollere en ekstraksjon (ANTIDEP_CONSTITUTION.md §10)'
);
select throws_ok(
  $$select pg_temp.insert_evidence_verification(
      '{"verifier": "human:editor-test"}'::jsonb)$$,
  '42501', null,
  'et menneske uten reviewer-rolle kan ikke kontrollere en ekstraksjon'
);
-- Selvverifikasjonen prøves på det funnet den mandaterte testverifikatoren selv
-- har laget; ellers ville mandatet felt forsøket først, og CHECK-en aldri blitt
-- prøvd.
select throws_ok(
  $$select pg_temp.insert_evidence_verification(
      '{"evidence": "self_authored"}'::jsonb)$$,
  '23514', null,
  'ekstraktøren kan ikke verifisere sin egen ekstraksjon (ANTIDEP_CONSTITUTION.md §10)'
);
select throws_ok(
  $$select pg_temp.insert_evidence_verification(
      ('{"creator_override": "' || pg_temp.actor('agent:claim-synthesis') || '"}')::jsonb)$$,
  '23503', null,
  'speilet av ekstraktøren kan ikke oppgis fritt; det er låst til evidensfunnet'
);
select throws_ok(
  $$select pg_temp.insert_evidence_verification(
      '{"source_access": "derived_summary"}'::jsonb)$$,
  '23514', null,
  'en bekreftelse kan ikke hvile på et avledet sammendrag alene (ANTIDEP_CONSTITUTION.md §11)'
);
select lives_ok(
  $$select pg_temp.insert_evidence_verification(
      '{"source_access": "derived_summary", "outcome": "uncertain",
        "findings": "Kontrollen hadde bare et sammendrag og kunne ikke konkludere."}'::jsonb)$$,
  'et sammendrag er nok til å registrere at kontrollen ikke kunne konkludere'
);
-- Kildepekerkravet lå fram til migrasjon 005y på raden, som
-- evidence_verifications_locator_checked_check. Det tvang enhver bekreftelse
-- til å føre opp et felt operasjonen kanskje ikke gjorde — mennesket blir
-- aldri spurt om kildepekeren. Kravet er flyttet til publiseringsgatens G5b,
-- som leser unionen over funnets kontroller, og er prøvd der (250).
select lives_ok(
  $$select pg_temp.insert_evidence_verification(
      '{"checked_fields": ["estimate", "population"]}'::jsonb)$$,
  'en bekreftelse kan dekke bare sin egen operasjon, uten kildepekeren'
);

select is_empty(
  $$
    select c.conname::text
    from pg_constraint c
    where c.conrelid = 'workflow.evidence_verifications'::regclass
      and c.conname = 'evidence_verifications_locator_checked_check'
  $$,
  'og radkravet finnes ikke lenger: garantien ligger i gaten, ikke i raden'
);
-- Utfallet er bevisst ikke verified her. Med verified ville regelen om at
-- kildepekeren må være kontrollert slått inn først, og assertionen ville
-- passert uten å si noe om kardinalitetsregelen.
select throws_ok(
  $$select pg_temp.insert_evidence_verification(
      '{"checked_fields": [], "outcome": "needs_correction",
        "findings": "Kontrollen rakk ikke å gå gjennom noe felt."}'::jsonb)$$,
  '23514', null,
  'en kontroll som ikke kontrollerte noe felt avvises'
);
select throws_ok(
  $$select pg_temp.insert_evidence_verification('{"outcome": "needs_correction"}'::jsonb)$$,
  '23514', null,
  'et annet utfall enn verified må si hva som er galt'
);
select lives_ok(
  $$select pg_temp.insert_evidence_verification(
      '{"outcome": "needs_correction", "findings": "Estimatet er avrundet feil i raden."}'::jsonb)$$,
  'en korreksjonsmelding med avviksbeskrivelse kan registreres'
);

-- ---------------------------------------------------------------------------
-- workflow.claim_verifications (DATABASE_ARCHITECTURE.md §30,
-- ANTIDEP_CONSTITUTION.md §11)
-- ---------------------------------------------------------------------------
create function pg_temp.insert_claim_verification(
  overrides jsonb default '{}'::jsonb
) returns void language plpgsql as $$
declare
  payload jsonb;
begin
  payload := jsonb_build_object(
    'verifier', 'agent:citation-verifier-test',
    'outcome', 'verified',
    'source_access', 'original_source',
    'source_support', 'ok',
    'population_match', 'ok',
    'comparator_match', 'ok',
    'timeframe_match', 'ok',
    'direction_and_magnitude', 'ok',
    'qualifiers_complete', 'ok',
    'contradictory_evidence_represented', 'ok',
    'rationale', 'Testkontroll av påstanden mot det registrerte grunnlaget.',
    'revision', 'seeded'
  ) || overrides;

  insert into workflow.claim_verifications (
    claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id,
    outcome, source_access,
    source_support, population_match, comparator_match, timeframe_match,
    direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
    findings, rationale, verified_at
  )
  select
    r.id,
    r.created_by_actor_id,
    pg_temp.actor(payload ->> 'verifier'),
    (payload ->> 'outcome')::workflow.verification_outcome,
    (payload ->> 'source_access')::workflow.verification_source_access,
    (payload ->> 'source_support')::workflow.verification_check_result,
    (payload ->> 'population_match')::workflow.verification_check_result,
    (payload ->> 'comparator_match')::workflow.verification_check_result,
    (payload ->> 'timeframe_match')::workflow.verification_check_result,
    (payload ->> 'direction_and_magnitude')::workflow.verification_check_result,
    (payload ->> 'qualifiers_complete')::workflow.verification_check_result,
    (payload ->> 'contradictory_evidence_represented')::workflow.verification_check_result,
    payload ->> 'findings',
    payload ->> 'rationale',
    coalesce((payload ->> 'verified_at')::timestamptz, now())
  from knowledge.claim_revisions r
  where r.id = case
    when payload ->> 'revision' = 'self_authored' then pg_temp.self_authored_revision()
    else pg_temp.seeded_revision('sertralin')
  end;
end;
$$;

select lives_ok(
  $$select pg_temp.insert_claim_verification()$$,
  'en separat verifikator kan bekrefte en revisjon når alle sju kontrollpunktene holder'
);
select throws_ok(
  $$select pg_temp.insert_claim_verification(
      '{"contradictory_evidence_represented": "deviation",
        "findings": "Motstridende studie er ikke representert."}'::jsonb)$$,
  '23514', null,
  'en revisjon kan ikke bekreftes når motstridende evidens mangler (ANTIDEP_CONSTITUTION.md §9, §11)'
);
select throws_ok(
  $$select pg_temp.insert_claim_verification(
      '{"qualifiers_complete": "not_assessable",
        "findings": "Forbeholdene lot seg ikke bedømme."}'::jsonb)$$,
  '23514', null,
  'et kontrollpunkt som ikke lot seg bedømme teller ikke som bestått'
);
select lives_ok(
  $$select pg_temp.insert_claim_verification(
      '{"outcome": "uncertain", "qualifiers_complete": "not_assessable",
        "findings": "Forbeholdene lot seg ikke bedømme på det tilgjengelige grunnlaget."}'::jsonb)$$,
  'et ubedømt kontrollpunkt kan registreres når utfallet selv er uncertain'
);
select throws_ok(
  $$select pg_temp.insert_claim_verification(
      '{"revision": "self_authored", "verifier": "agent:citation-verifier-test"}'::jsonb)$$,
  '23514', null,
  'forfatteren av revisjonen kan ikke verifisere den selv, heller ikke med mandatet i orden (MVP_IMPLEMENTATION_PLAN.md §49)'
);
select lives_ok(
  $$select pg_temp.insert_claim_verification(
      '{"revision": "self_authored", "verifier": "human:reviewer-test"}'::jsonb)$$,
  'den samme revisjonen kan kontrolleres av en annen mandatert aktør — det er forfatterskapet som feller, ikke revisjonen'
);
select throws_ok(
  $$select pg_temp.insert_claim_verification(
      '{"source_access": "derived_summary"}'::jsonb)$$,
  '23514', null,
  'en bekreftet claim-verifikasjon kan ikke hvile på et avledet sammendrag alene'
);
-- Migrasjon 005j: mandatet er en egen grense, uavhengig av at verifikator og
-- forfatter er forskjellige aktører. agent:verifier-test er en annen aktør enn
-- forfatteren, og har likevel ikke lov: rollen er adversarial_review.
select throws_ok(
  $$select pg_temp.insert_claim_verification(
      '{"verifier": "agent:verifier-test"}'::jsonb)$$,
  '42501', 'Verifikatoraktøren hadde ikke mandat til å kontrollere denne påstanden mot grunnlaget.',
  'en agent i en annen kontrollrolle kan ikke registrere en claim-verifikasjon'
);
select throws_ok(
  $$select pg_temp.insert_claim_verification(
      '{"verifier": "human:unlinked-test"}'::jsonb)$$,
  '42501', 'Verifikatoraktøren hadde ikke mandat til å kontrollere denne påstanden mot grunnlaget.',
  'et menneske uten brukerkonto og uten reviewer-rolle kan heller ikke registrere en'
);
select lives_ok(
  $$select pg_temp.insert_claim_verification(
      '{"verifier": "human:reviewer-test"}'::jsonb)$$,
  'et menneske med gyldig reviewer-rolle for innholdsområdet kan registrere en claim-verifikasjon (MVP_IMPLEMENTATION_PLAN.md §74.30 punkt 3)'
);

-- ---------------------------------------------------------------------------
-- workflow.review_decisions (DATABASE_ARCHITECTURE.md §31,
-- ANTIDEP_CONSTITUTION.md §12)
-- ---------------------------------------------------------------------------
create function pg_temp.insert_review(
  overrides jsonb default '{}'::jsonb
) returns void language plpgsql as $$
declare
  payload jsonb;
  v_revision uuid;
  v_evidence uuid;
begin
  payload := jsonb_build_object(
    'reviewer', 'human:reviewer-test',
    'reviewer_actor_type', 'human',
    'object', 'claim_revision',
    'review_type', 'publication_approval',
    'decision', 'approved',
    'rationale', 'Testgodkjenning av påstandsrevisjonen.'
  ) || overrides;

  if payload ->> 'object' in ('claim_revision', 'both') then
    v_revision := coalesce(
      (payload ->> 'revision_override')::uuid, pg_temp.seeded_revision('sertralin')
    );
  end if;
  if payload ->> 'object' in ('evidence_item', 'both') then
    v_evidence := pg_temp.seeded_evidence('sertralin');
  end if;

  insert into workflow.review_decisions (
    claim_revision_id, claim_revision_creator_actor_id,
    evidence_item_id, evidence_item_creator_actor_id,
    review_type, decision, rationale,
    reviewer_actor_id, reviewer_actor_type, decided_at
  )
  select
    v_revision,
    (select r.created_by_actor_id from knowledge.claim_revisions r where r.id = v_revision),
    v_evidence,
    (select e.created_by_actor_id from knowledge.evidence_items e where e.id = v_evidence),
    (payload ->> 'review_type')::workflow.review_type,
    (payload ->> 'decision')::workflow.review_outcome,
    payload ->> 'rationale',
    pg_temp.actor(payload ->> 'reviewer'),
    (payload ->> 'reviewer_actor_type')::provenance.actor_type,
    -- Standard er now(). decided_at kan ikke ligge etter radens databaseeide
    -- created_at, så et fast framtidig litteral ville gjort hver eneste
    -- assertion i denne blokken avhengig av klokkeslettet testen kjøres på.
    coalesce((payload ->> 'decided_at')::timestamptz, now());
end;
$$;

select lives_ok(
  $$select pg_temp.insert_review()$$,
  'en kvalifisert menneskelig reviewer kan godkjenne en påstandsrevisjon'
);
select throws_ok(
  $$select pg_temp.insert_review('{"reviewer": "human:unlinked-test"}'::jsonb)$$,
  '42501',
  'Reviewaktøren er ikke knyttet til en brukerkonto og kan ikke registrere en faglig beslutning.',
  'en menneskelig aktør uten brukerkonto kan ikke godkjenne'
);
select throws_ok(
  $$select pg_temp.insert_review('{"reviewer": "human:editor-test"}'::jsonb)$$,
  '42501',
  'Reviewaktøren hadde ikke gyldig reviewer-rolle for dette innholdsområdet på beslutningstidspunktet.',
  'editor- og admin-rollene gir ikke faglig godkjenningsrett (DATABASE_ARCHITECTURE.md §45)'
);
select throws_ok(
  $$select pg_temp.insert_review('{"decided_at": "2026-06-01T00:00:00Z",
                                   "reviewer": "human:reviewer-test"}'::jsonb)$$,
  '42501',
  'Reviewaktøren hadde ikke gyldig reviewer-rolle for dette innholdsområdet på beslutningstidspunktet.',
  'en beslutning kan ikke dateres til før rollen ble tildelt'
);
-- Scoped reviewer er godkjent for «depressiv lidelse», mens slicepåstandene har
-- temaet «vektendring». Rollen skal ikke virke utenfor sitt eget område.
select throws_ok(
  $$select pg_temp.insert_review('{"reviewer": "human:scoped-test"}'::jsonb)$$,
  '42501',
  'Reviewaktøren hadde ikke gyldig reviewer-rolle for dette innholdsområdet på beslutningstidspunktet.',
  'en scoped reviewer kan ikke godkjenne utenfor sitt innholdsområde'
);

-- Kontroll av at forrige assertion ikke passerte av feil grunn: den samme
-- reviewer-aktøren skal kunne godkjenne innenfor sitt eget innholdsområde.
insert into workflow.user_roles
  (user_id, role_code, scope_id, granted_by_actor_id, grant_reason)
select pg_temp.user_id('scoped@test.invalid'), 'reviewer', c.id,
       pg_temp.actor('system:rolleforvaltning'),
       'Testtildeling for slicens innholdsområde.'
from catalog.clinical_concepts c
where c.canonical_label = 'vektendring'
  and not exists (
    select 1 from workflow.user_roles ur
    where ur.user_id = pg_temp.user_id('scoped@test.invalid') and ur.scope_id = c.id
  );

select lives_ok(
  $$select pg_temp.insert_review('{"reviewer": "human:scoped-test",
                                   "decision": "changes_requested",
                                   "rationale": "Testavslag med endringsønske."}'::jsonb)$$,
  'den samme scoped revieweren kan avgjøre innenfor sitt eget innholdsområde'
);

-- ---------------------------------------------------------------------------
-- Tidsmodellen kan ikke konstrueres i etterkant
--
-- decided_at er kallerstyrt og bestemmer hvilken rolletildeling som teller som
-- gyldig. Uten et databaseeid referansepunkt kunne en rolle opprettes i dag,
-- tilbakedateres med valid_from, og deretter legitimere en «godkjenning» som
-- aldri fant sted. De tre assertionene under dekker begge retninger og den
-- lovlige mellomtingen.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$select pg_temp.insert_review('{"reviewer": "human:backdated-test",
                                   "decided_at": "2021-06-01T00:00:00Z"}'::jsonb)$$,
  '42501',
  'Reviewaktøren hadde ikke gyldig reviewer-rolle for dette innholdsområdet på beslutningstidspunktet.',
  'en tilbakedatert rolletildeling kan ikke legitimere en beslutning fra før tildelingen fantes'
);
select throws_ok(
  $$
    select pg_temp.insert_review(
      ('{"decided_at": "' || (now() + interval '1 day') || '"}')::jsonb)
  $$,
  '23514', null,
  'en beslutning kan ikke dateres til framtiden'
);
-- Kontroll av at forrige assertion ikke overblokkerer: den samme tilbakedaterte
-- tildelingen skal virke for en beslutning tatt nå.
select lives_ok(
  $$select pg_temp.insert_review('{"reviewer": "human:backdated-test",
                                   "decision": "rejected",
                                   "rationale": "Testavslag fra tilbakedatert tildeling."}'::jsonb)$$,
  'en tilbakedatert tildeling gjelder framover og kan avgjøre en beslutning tatt nå'
);
-- created_at eies av databasen, så referansepunktet kan ikke oppgis av kalleren.
select throws_ok(
  $$
    insert into workflow.review_decisions (
      claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
      rationale, reviewer_actor_id, reviewer_actor_type, decided_at, created_at
    )
    select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
           'Forsøk på å flytte referansepunktet.',
           pg_temp.actor('human:backdated-test'), 'human',
           timestamptz '2021-06-01T00:00:00Z', timestamptz '2021-06-01T00:00:00Z'
    from knowledge.claim_revisions r
    where r.id = pg_temp.seeded_revision('mirtazapin')
  $$,
  '42501',
  'Reviewaktøren hadde ikke gyldig reviewer-rolle for dette innholdsområdet på beslutningstidspunktet.',
  'en oppgitt created_at flytter ikke referansepunktet; databasen overskriver den'
);

-- Samme regel for verifikasjonene: en kontroll kan ikke ha funnet sted i framtiden.
select throws_ok(
  $$
    select pg_temp.insert_evidence_verification(
      ('{"verified_at": "' || (now() + interval '1 day') || '"}')::jsonb)
  $$,
  '23514', null,
  'en ekstraksjonsverifikasjon kan ikke dateres til framtiden'
);
select throws_ok(
  $$
    select pg_temp.insert_claim_verification(
      ('{"verified_at": "' || (now() + interval '1 day') || '"}')::jsonb)
  $$,
  '23514', null,
  'en claim-verifikasjon kan ikke dateres til framtiden'
);
select lives_ok(
  $$
    select pg_temp.insert_evidence_verification(
      '{"verified_at": "2026-08-01T00:00:00Z",
        "rationale": "Kontroll utført tidligere, registrert i etterkant."}'::jsonb)
  $$,
  'en kontroll utført tidligere kan registreres i etterkant'
);

-- En reviewer kan ikke godkjenne sitt eget arbeid.
insert into knowledge.claim_revisions (
  claim_id, revision_number, knowledge_type, subject_drug_id,
  statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id
)
select cl.id, 2, cl.knowledge_type, cl.subject_drug_id,
       'Testrevisjon skrevet av den menneskelige revieweren selv.',
       'Testomfang for egenkontroll.', 'none', 'Testusikkerhet.',
       pg_temp.actor('human:reviewer-test')
from knowledge.claims cl
join knowledge.claim_revisions r on r.claim_id = cl.id
where r.id = pg_temp.seeded_revision('sertralin');

select throws_ok(
  $$
    select pg_temp.insert_review(
      ('{"revision_override": "'
       || (select r.id from knowledge.claim_revisions r
           where r.revision_number = 2
             and r.created_by_actor_id = pg_temp.actor('human:reviewer-test'))
       || '"}')::jsonb)
  $$,
  '23514', null,
  'en reviewer kan ikke godkjenne en revisjon hun selv har skrevet (ANTIDEP_CONSTITUTION.md §12)'
);

select throws_ok(
  $$select pg_temp.insert_review('{"object": "evidence_item"}'::jsonb)$$,
  '23514', null,
  'en publiseringsgodkjenning kan ikke gjelde et evidensfunn'
);
select throws_ok(
  $$select pg_temp.insert_review('{"object": "both"}'::jsonb)$$,
  '23514', null,
  'en beslutning kan ikke gjelde to objekter samtidig'
);
select throws_ok(
  $$select pg_temp.insert_review('{"object": "none"}'::jsonb)$$,
  '23514', null,
  'en beslutning må gjelde et objekt'
);
select throws_ok(
  $$select pg_temp.insert_review(
      '{"object": "evidence_item", "review_type": "extraction_withdrawal",
        "decision": "approved"}'::jsonb)$$,
  '23514', null,
  'en tilbaketrekkingsvurdering kan ikke få utfallet approved'
);
select lives_ok(
  $$select pg_temp.insert_review(
      '{"object": "evidence_item", "review_type": "extraction_withdrawal",
        "decision": "extraction_withdrawn",
        "rationale": "Ekstraksjonen gjengir feil tabell i kilden og trekkes tilbake."}'::jsonb)$$,
  'en ekstraksjon kan trekkes tilbake som en faglig beslutning i workflow (DATABASE_ARCHITECTURE.md §29)'
);
select is(
  (select object_type::text
   from workflow.review_decisions
   where review_type = 'extraction_withdrawal'),
  'evidence_item',
  'object_type avledes av objektpekeren og kan ikke settes uavhengig av den'
);
select throws_ok(
  $$select pg_temp.insert_review('{"rationale": "   "}'::jsonb)$$,
  '23514', null,
  'en beslutning uten reell begrunnelse avvises (ANTIDEP_CONSTITUTION.md §14)'
);

-- Kravet om at revieweren er et menneske er et eget lag, uavhengig av
-- kvalifikasjonstriggeren. Triggeren slås av her for å isolere det: uten
-- avslåingen ville triggeren avvist en KI-aktør først, og assertionene under
-- ville passert av feil grunn.
alter table workflow.review_decisions
  disable trigger review_decisions_enforce_reviewer_qualification;

select throws_ok(
  $$select pg_temp.insert_review('{"reviewer": "agent:verifier-test",
                                   "reviewer_actor_type": "agent"}'::jsonb)$$,
  '23514', null,
  'en KI-aktør kan ikke registrere en faglig beslutning (ANTIDEP_CONSTITUTION.md §12)'
);
select throws_ok(
  $$select pg_temp.insert_review('{"reviewer": "agent:verifier-test",
                                   "reviewer_actor_type": "human"}'::jsonb)$$,
  '23503', null,
  'aktørtypen kan ikke oppgis fritt; speilet er låst til aktørraden'
);

alter table workflow.review_decisions
  enable trigger review_decisions_enforce_reviewer_qualification;

-- Kontroll av at avslåingen faktisk ble reversert: kvalifikasjonskravet skal
-- gjelde igjen etter blokken over.
select throws_ok(
  $$select pg_temp.insert_review('{"reviewer": "human:unlinked-test"}'::jsonb)$$,
  '42501',
  'Reviewaktøren er ikke knyttet til en brukerkonto og kan ikke registrere en faglig beslutning.',
  'kvalifikasjonskravet er aktivt igjen etter at triggeren ble slått på'
);

-- Kunnskapsobjektene kan ikke slettes bort under beslutningene som peker på dem
-- (DATABASE_ARCHITECTURE.md §36, §37).
select throws_ok(
  $$delete from provenance.actors where actor_key = 'agent:extraction-verifier-test'$$,
  '23503', null,
  'en aktør som står oppført på en verifikasjon kan ikke slettes'
);

select * from finish();

rollback;
