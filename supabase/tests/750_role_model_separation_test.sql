-- Migrasjon 009c — modellrollene er reelt separate.
--
-- ANTIDEP_CONSTITUTION.md regel 3 sier at generator, kildestøttekontroll og
-- evidensvurdering er separate roller, og at egenverifikasjon er forbudt.
-- Fram til 009c var den regelen håndhevet på aktør, men ikke på modell: to
-- roller kunne oppgi nøyaktig den samme modellen, og kjeden godtok det.
--
-- Migrasjon 013t flyttet regelen: flere ledd *kan* dele modell, fordi den samme
-- modellen utfører dem i atskilte runder med hver sin instruks og sin egen
-- kontekst. Det som ikke kan deles, er leddet selv — én tildeling per rolle, én
-- rolle per agentidentitet.
--
-- Filen dekker de tre lagene som står i veien:
--
--   * registeret gir hvert ledd én gyldig tildeling om gangen, og lar flere
--     ledd bruke den samme modellen,
--   * api.begin_agent_run krever at premissene er den registrerte
--     tildelingen, og avviser en rolle uten tildeling, og
--   * kontrollradene avviser en kontroll gjort av den samme registrerings-
--     eller agentidentiteten som laget det som kontrolleres.
--
-- SQLSTATE 22023 = invalid_parameter_value, 23001 = restrict_violation,
-- 23P01 = exclusion_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(25);

-- ===========================================================================
-- Del 1 — Registeret
-- ===========================================================================
select has_table('provenance', 'role_model_assignments',
                 'provenance.role_model_assignments finnes');

-- Fem ledd fra evidenskjeden, fra migrasjon 013e de to kildeleddene, og fra
-- 013i den deterministiske svarkontrollen.
select is(
  (select count(*)::int from provenance.role_model_assignments where valid_to is null),
  8,
  'de åtte skrivende rollene i kjeden har hver sin gyldige tildeling'
);

-- Registreringsidentitetene er fortsatt én per ledd. Det er ingen
-- databaseregel etter 013t, men det er Antideps egen kode, og hvert ledd har
-- sin egen: et sammenfall der ville betydd at det samme kodeleddet både skrev
-- innholdet og kontrollerte det.
select is(
  (select count(distinct (provider, model, model_version))::int
   from provenance.role_model_assignments where valid_to is null),
  8,
  'de åtte registreringsidentitetene er forskjellige'
);

select is(
  (select a.model from provenance.current_role_model('evidence_extraction') a),
  'proposal-grounded-extraction',
  'oppslaget gir rollens gjeldende modell'
);

-- Og én rolle kan ikke ha to samtidige modeller: «hvilken modell handler denne
-- rollen som» skal ha ett svar.
select throws_ok(
  $$insert into provenance.role_model_assignments
      (agent_role, provider, model, model_version, registered_by_actor_id, reason)
    select 'evidence_extraction', 'antidep', 'en-helt-annen-modell', '9.9.9',
           (select id from provenance.actors where actor_key = 'human:peder-holman'),
           'Prøve i 750: to samtidige modeller for én rolle.'$$,
  '23P01', null,
  'én rolle kan ikke ha to samtidige modelltildelinger'
);

-- Tildelingen etterlater et spor. Hvilken modell en rolle får handle som, er
-- den mest sikkerhetskritiske innstillingen i kjeden etter rolletildeling.
select is(
  (select count(*)::int from audit.events e
   where e.operation = 'role_model_assignment_registered'),
  8,
  'hver tildeling etterlot en auditrad'
);
select is(
  (select distinct e.object_schema || '.' || e.object_table from audit.events e
   where e.operation = 'role_model_assignment_registered'),
  'provenance.role_model_assignments',
  'auditraden peker på registeret'
);

-- Og fra 013t: to ledd kan dele modell. Den samme modellen utfører dem i
-- atskilte runder, med hver sin instruks og sin egen kontekst, og registeret
-- står ikke lenger i veien for å si det sant.
--
-- Tildelingen er semantisk: det er den kapasiteten en ekstern modell tildeles i,
-- og leddet har allerede sin egen registreringsidentitet ved siden av. Paret er
-- de to kildeleddene, fordi det er der delingen er lettest å lese — søket og
-- kontrollen av søkedekningen er to runder, ikke to modellvekter. Radene legges
-- inn etter auditkontrollene over, slik at de teller de åtte seedede
-- tildelingene og ikke prøvens egne.
select lives_ok(
  $$insert into provenance.role_model_assignments
      (agent_role, capacity, provider, model, model_version, registered_by_actor_id, reason)
    select 'source_discovery', 'semantic', 'openai', 'prøve-750-delt-modell', '1',
           (select id from provenance.actors where actor_key = 'human:peder-holman'),
           'Prøve i 750: kildeoppdagelsen får den delte modellen.'$$,
  'et ledd kan tildeles en ekstern modell i tillegg til registreringsidentiteten'
);
select lives_ok(
  $$insert into provenance.role_model_assignments
      (agent_role, capacity, provider, model, model_version, registered_by_actor_id, reason)
    select 'source_quality_assessment', 'semantic', 'openai', 'prøve-750-delt-modell', '1',
           (select id from provenance.actors where actor_key = 'human:peder-holman'),
           'Prøve i 750: dekningskontrollen kjører den samme modellen i sin egen runde.'$$,
  'to ledd kan dele den samme modellen i overlappende tid'
);

-- Historikken er uforanderlig. Hvilken modell en rolle handlet som i en
-- periode, er et faktum kjøringene i perioden hviler på: en omskriving i
-- ettertid ville gjort dem uforklarlige (ANTIDEP_CONSTITUTION.md regel 3, 7).
select throws_ok(
  $$update provenance.role_model_assignments
      set model = 'en-omskrevet-modell'
    where agent_role = 'evidence_extraction' and valid_to is null$$,
  '23001', 'En modelltildeling er uforanderlig bortsett fra at den kan avsluttes.',
  'en modelltildeling kan ikke skrives om i ettertid'
);
select throws_ok(
  $$update provenance.role_model_assignments
      set reason = 'Prøve i 750: omskrevet begrunnelse.'
    where agent_role = 'evidence_extraction' and valid_to is null$$,
  '23001', 'En modelltildeling er uforanderlig bortsett fra at den kan avsluttes.',
  'heller ikke begrunnelsen bak tildelingen kan skrives om'
);

-- En avslutning uten hvem og hvorfor ville vært en endring uten ansvar.
select throws_ok(
  $$update provenance.role_model_assignments
      set valid_to = now()
    where agent_role = 'claim_synthesis' and valid_to is null$$,
  '23514', null,
  'en avslutning uten attribusjon og begrunnelse avvises'
);

-- Den ene endringen som er lov, er å avslutte den — én gang, med hvem og
-- hvorfor.
select lives_ok(
  $$update provenance.role_model_assignments
      set valid_to = now(),
          closed_by_actor_id =
            (select id from provenance.actors where actor_key = 'human:peder-holman'),
          close_reason = 'Prøve i 750: rollen skal handle som en annen modell.'
    where agent_role = 'claim_synthesis' and valid_to is null$$,
  'en tildeling kan avsluttes'
);
select throws_ok(
  $$update provenance.role_model_assignments
      set valid_to = now() + interval '1 day'
    where agent_role = 'claim_synthesis' and valid_to is not null$$,
  '23001', 'En avsluttet modelltildeling kan ikke avsluttes på nytt eller gjenåpnes.',
  'en avsluttet tildeling kan verken avsluttes på nytt eller gjenåpnes'
);

-- At en rolle sluttet å handle som en modell, er øyeblikket separasjonen mellom
-- to ledd kan endre seg. Et auditspor som bare dekket innsettingen, ville vært
-- stille akkurat der.
select is(
  (select count(*)::int from audit.events e
   where e.operation = 'role_model_assignment_closed'),
  1,
  'avslutningen etterlot sin egen auditrad'
);
select is(
  (select e.actor_id from audit.events e
   where e.operation = 'role_model_assignment_closed'),
  (select id from provenance.actors where actor_key = 'human:peder-holman'),
  'auditraden navngir den som avsluttet tildelingen, ikke den som registrerte den'
);
-- Begge øyeblikksbildene, slik at overgangen kan leses: hva som ble avsluttet,
-- og hva raden ble.
select ok(
  (select e.old_revision_or_snapshot ->> 'valid_to' is null
          and e.new_revision_or_snapshot ->> 'valid_to' is not null
   from audit.events e where e.operation = 'role_model_assignment_closed'),
  'auditraden bærer både den åpne og den avsluttede tildelingen'
);
select is(
  (select e.object_schema || '.' || e.object_table from audit.events e
   where e.operation = 'role_model_assignment_closed'),
  'provenance.role_model_assignments',
  'auditraden over avslutningen peker på registeret'
);

-- Og når den er avsluttet, kan rollen få en ny modell.
select lives_ok(
  $$insert into provenance.role_model_assignments
      (agent_role, provider, model, model_version, registered_by_actor_id, reason)
    select 'claim_synthesis', 'antidep', 'proposal-registered-synthesis', '1.1.0',
           (select id from provenance.actors where actor_key = 'human:peder-holman'),
           'Prøve i 750: ny tildeling etter at den gamle ble avsluttet.'$$,
  'en avsluttet tildeling gir plass til en ny for den samme rollen'
);

-- ===========================================================================
-- Del 2 — Gaten i api.begin_agent_run
-- ===========================================================================
create temporary table cred (label text primary key, secret text) on commit drop;
grant select on cred to anon;
insert into cred select 'extractor', provenance.issue_agent_identity_credential(
  'agent-identity:evidence-extraction-01', 'human:peder-holman');

set local role anon;
select throws_ok(
  $$select api.begin_agent_run(
      'agent-identity:evidence-extraction-01', (select secret from cred where label = 'extractor'),
      'evidence_extraction', 'en-annen-leverandør', 'en-annen-modell', '1',
      'evidence-extraction/proposal/1', 'antidep-evidence/1',
      '{"mode": "test-750"}'::jsonb,
      'f2000000-0000-4000-8000-000000000002')$$,
  '22023', null,
  'en kjøring med andre premisser enn den registrerte tildelingen avvises'
);

-- Autentiseringen står før modellgaten: en kaller uten legitimasjon skal ikke
-- få vite noe om konfigurasjonen bak.
select throws_ok(
  $$select api.begin_agent_run(
      'agent-identity:evidence-extraction-01', 'feil-hemmelighet',
      'evidence_extraction', 'en-annen-leverandør', 'en-annen-modell', '1',
      'evidence-extraction/proposal/1', 'antidep-evidence/1',
      '{"mode": "test-750"}'::jsonb,
      'f2000000-0000-4000-8000-000000000002')$$,
  '42501', 'Agentidentiteten kunne ikke autentiseres for denne operasjonen.',
  'en mislykket autentisering svarer det den alltid har svart'
);

select lives_ok(
  $$select api.begin_agent_run(
      'agent-identity:evidence-extraction-01', (select secret from cred where label = 'extractor'),
      'evidence_extraction', 'antidep', 'proposal-grounded-extraction', '1.1.0',
      'evidence-extraction/proposal/1', 'antidep-evidence/1',
      '{"mode": "test-750"}'::jsonb,
      'f2000000-0000-4000-8000-000000000002')$$,
  'en kjøring med den registrerte tildelingen kommer i gang'
);
reset role;

-- En rolle uten registrert tildeling kan ikke kjøre i det hele tatt.
-- `adversarial_review` har verken skrivevei eller identitet; fraværet er
-- tilsiktet, og gaten er fail-closed på det.
select is(
  (select count(*)::int from provenance.role_model_assignments
   where agent_role = 'adversarial_review'),
  0,
  'en rolle uten skrivevei har ingen modelltildeling'
);

-- ===========================================================================
-- Del 3 — Forbudet mot egenverifikasjon, på modellnivå
-- ===========================================================================

-- To kjøringer med nøyaktig den samme modellidentiteten, satt inn direkte
-- forbi api-gaten: nettopp den tilstanden lag 3 finnes for.
insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest, input_source_version_id)
select '75000000-0000-4000-8000-000000000001', ai.id, ai.actor_id, 'evidence_extraction',
       'samme', 'samme-modell', '1', 't/1', 'p/1', '{"mode": "test-750"}'::jsonb,
       'f2000000-0000-4000-8000-000000000002'
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:evidence-extraction-01';

insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '75000000-0000-4000-8000-000000000002', ai.id, ai.actor_id, 'extraction_verification',
       'samme', 'samme-modell', '1', 't/1', 'p/1', '{"mode": "test-750"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';

insert into knowledge.evidence_items (
  id, source_id, source_version_id, design_code, population_availability, population_detail,
  sample_size_availability, intervention_drug_id, comparator_kind, outcome_concept_id,
  outcome_detail, timepoint_availability, reported_direction, estimate_availability,
  confidence_interval_availability, source_locator, extraction_method,
  created_by_actor_id, agent_run_id
)
select '75000000-0000-4000-8000-000000000011', 'f2000000-0000-4000-8000-000000000001',
       'f2000000-0000-4000-8000-000000000002', 'randomized_controlled_trial',
       'not_reported', 'Prøve i 750.', 'not_reported', d.id, 'none', c.id,
       'Prøve i 750.', 'not_reported', 'increase', 'not_reported', 'not_reported',
       'Avsnitt 1', 'ai_assisted',
       (select id from provenance.actors where actor_key = 'agent:evidence-extraction'),
       '75000000-0000-4000-8000-000000000001'
from catalog.drugs d, catalog.clinical_concepts c
where d.canonical_name = 'sertralin' and c.canonical_label = 'vektendring';

select throws_ok(
  $$insert into workflow.evidence_verifications
      (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
       source_access, checked_fields, rationale, verified_at, agent_run_id)
    select '75000000-0000-4000-8000-000000000011', e.created_by_actor_id,
           (select id from provenance.actors where actor_key = 'agent:extraction-verification'),
           'verified', 'original_source',
           array['outcome']::workflow.evidence_check_field[],
           'Prøve i 750: kontroll av samme modell som laget funnet.', now(),
           '75000000-0000-4000-8000-000000000002'
    from knowledge.evidence_items e
    where e.id = '75000000-0000-4000-8000-000000000011'$$,
  '23001', 'Ekstraksjonskontrollen ble gjort av den samme modellidentiteten som laget det som kontrolleres.',
  'en kontroll av den samme modellen som laget funnet, avvises'
);

-- Og motsatt: en kontroll fra en annen modellidentitet går gjennom. Uten
-- denne kunne regelen vært trivielt oppfylt ved å avvise alt.
insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, input_manifest)
select '75000000-0000-4000-8000-000000000003', ai.id, ai.actor_id, 'extraction_verification',
       'antidep', 'deterministic-extraction-check', '1.0.0', 't/1', 'p/1',
       '{"mode": "test-750"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:extraction-verification-01';

select lives_ok(
  $$insert into workflow.evidence_verifications
      (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
       source_access, checked_fields, rationale, verified_at, agent_run_id)
    select '75000000-0000-4000-8000-000000000011', e.created_by_actor_id,
           (select id from provenance.actors where actor_key = 'agent:extraction-verification'),
           'verified', 'original_source',
           array['outcome']::workflow.evidence_check_field[],
           'Prøve i 750: kontroll fra en annen modellidentitet.', now(),
           '75000000-0000-4000-8000-000000000003'
    from knowledge.evidence_items e
    where e.id = '75000000-0000-4000-8000-000000000011'$$,
  'en kontroll fra en annen modellidentitet går gjennom'
);

select * from finish();
rollback;
