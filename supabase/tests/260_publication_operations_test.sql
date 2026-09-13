-- Migrasjon 006 — de kontrollerte publiseringsoperasjonene.
--
-- Verifiserer at publisering, erstatning, avpublisering og rollback er de fire
-- tilstandsovergangene DATABASE_ARCHITECTURE.md §39 beskriver, at pekeren og
-- historikken alltid stemmer overens, at rollback er ny historikk og ikke en
-- sletting (§40), at publiseringsretten kontrolleres som §50 krever, og at
-- operasjonen tar radlås slik §61 krever.
--
-- Gatene selv testes i 250, og tilgangen fra klientrollene i 270.
--
-- SQLSTATE 42501 = insufficient_privilege, 23001 = restrict_violation,
-- 22023 = invalid_parameter_value.
begin;

create extension if not exists pgtap with schema extensions;

select plan(41);

create temporary table fixture (name text primary key, id uuid not null) on commit drop;

-- ---------------------------------------------------------------------------
-- Aktører, brukerkontoer og roller
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('cccccccc-0000-0000-0000-000000000001', 'publisher-260@test.invalid'),
  ('cccccccc-0000-0000-0000-000000000002', 'reviewer-260@test.invalid'),
  ('cccccccc-0000-0000-0000-000000000003', 'retired-260@test.invalid'),
  ('cccccccc-0000-0000-0000-000000000004', 'publisher-tilbakekalt-260@test.invalid'),
  ('cccccccc-0000-0000-0000-000000000005', 'publisher-nettopp-gyldig-260@test.invalid');

insert into provenance.actors (actor_type, actor_key, display_name, description, auth_user_id)
values
  ('human', 'human:publisher-260', 'Publisher', 'Har publisher-rollen.',
   'cccccccc-0000-0000-0000-000000000001'),
  ('human', 'human:reviewer-260', 'Reviewer', 'Har reviewer-rollen, men ikke publisher.',
   'cccccccc-0000-0000-0000-000000000002'),
  ('human', 'human:publisher-tilbakekalt-260', 'Publisher med tilbakekalt rolle',
   'Publiseringsretten ble tilbakekalt mens transaksjonen pågikk.',
   'cccccccc-0000-0000-0000-000000000004'),
  ('human', 'human:publisher-nettopp-gyldig-260', 'Publisher med nylig gyldig rolle',
   'Publiseringsretten ble gyldig mens transaksjonen pågikk.',
   'cccccccc-0000-0000-0000-000000000005');

insert into provenance.actors
  (actor_type, actor_key, display_name, description, auth_user_id, retired_at, retirement_note)
values
  ('human', 'human:retired-260', 'Tidligere publisher',
   'Menneskelig aktør som er trukket tilbake.',
   'cccccccc-0000-0000-0000-000000000003', now(), 'Sluttet i rollen.');

insert into fixture (name, id)
select 'publisher', id from provenance.actors where actor_key = 'human:publisher-260';
insert into fixture (name, id)
select 'reviewer', id from provenance.actors where actor_key = 'human:reviewer-260';
insert into fixture (name, id)
select 'retired', id from provenance.actors where actor_key = 'human:retired-260';
insert into fixture (name, id)
select 'publisher_tilbakekalt', id from provenance.actors
where actor_key = 'human:publisher-tilbakekalt-260';
insert into fixture (name, id)
select 'publisher_nettopp_gyldig', id from provenance.actors
where actor_key = 'human:publisher-nettopp-gyldig-260';
insert into fixture (name, id)
select 'synthesis_actor', id from provenance.actors where actor_key = 'agent:claim-synthesis';
insert into fixture (name, id)
select 'topic', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'drug', id from catalog.drugs where canonical_name = 'sertralin';

insert into workflow.user_roles (user_id, role_code, granted_by_actor_id, grant_reason)
values
  ('cccccccc-0000-0000-0000-000000000001', 'publisher',
   (select id from fixture where name = 'reviewer'), 'Publiseringsrett for testene.'),
  ('cccccccc-0000-0000-0000-000000000002', 'reviewer',
   (select id from fixture where name = 'publisher'), 'Reviewrett for testene.'),
  ('cccccccc-0000-0000-0000-000000000003', 'publisher',
   (select id from fixture where name = 'reviewer'), 'Publiseringsrett for den tilbaketrukne aktøren.');

-- To tildelinger med gyldighetsgrense mellom transaksjonens starttidspunkt og
-- den setningen som senere autoriserer. Se avsnittet om tilbakekalling under.
insert into workflow.user_roles
  (user_id, role_code, valid_from, valid_to, granted_by_actor_id, grant_reason,
   ended_by_actor_id, end_reason)
values
  ('cccccccc-0000-0000-0000-000000000004', 'publisher',
   now() - interval '1 hour', now() + interval '10 milliseconds',
   (select id from fixture where name = 'reviewer'), 'Publiseringsrett som tilbakekalles.',
   (select id from fixture where name = 'reviewer'), 'Tilbakekalt mens transaksjonen pågikk.');

insert into workflow.user_roles
  (user_id, role_code, valid_from, granted_by_actor_id, grant_reason)
values
  ('cccccccc-0000-0000-0000-000000000005', 'publisher',
   now() + interval '10 milliseconds',
   (select id from fixture where name = 'reviewer'), 'Publiseringsrett som blir gyldig underveis.');

-- ---------------------------------------------------------------------------
-- En påstand med tre revisjoner. Revisjon 1 og 3 er fullt publiserbare;
-- revisjon 2 er bevisst ikke bygget ut, fordi den bare brukes til å vise at en
-- revisjon som aldri har vært publisert ikke kan rulles tilbake til.
-- ---------------------------------------------------------------------------
with inserted as (
  insert into knowledge.claims
    (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
  select 'evidence_synthesis', t.id, d.id, a.id
  from fixture t, fixture d, fixture a
  where t.name = 'topic' and d.name = 'drug' and a.name = 'synthesis_actor'
  returning id
)
insert into fixture (name, id) select 'claim', id from inserted;

insert into knowledge.claim_revisions (
  claim_id, revision_number, knowledge_type, subject_drug_id,
  statement, scope, comparator_kind, uncertainty_summary, created_by_actor_id
)
select c.id, n.revision_number, c.knowledge_type, c.subject_drug_id,
       format('Testformulering nummer %s.', n.revision_number),
       'Gjelder bare testene i denne filen.', 'none', 'Testusikkerhet.',
       c.created_by_actor_id
from knowledge.claims c, (values (1), (2), (3)) as n(revision_number)
where c.id = (select id from fixture where name = 'claim');

insert into fixture (name, id)
select 'rev1', r.id from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'claim') and r.revision_number = 1;
insert into fixture (name, id)
select 'rev2', r.id from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'claim') and r.revision_number = 2;
insert into fixture (name, id)
select 'rev3', r.id from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'claim') and r.revision_number = 3;

-- Ekstraksjonsverifikasjon av evidensfunnene.
-- Den kildeomfattende halvdelen av et globalt fravær (`not_reported`,
-- `not_measured`) kan bare føres opp av en maskinell kontroll med sin egen
-- agentkjøring (migrasjon 005ae,
-- evidence_verifications_source_wide_absence_check): ingen menneskelig
-- kontrolløkt søker gjennom hele representasjonen, og blir aldri spurt om det.
-- En fikstur som skal ha full dekning, trenger derfor begge leddene.
create function pg_temp.cover_source_wide_absence(p_evidence_item_id uuid)
  returns void
  language plpgsql
as $fn$
declare
  v_run_id uuid;
  v_actor_id uuid;
begin
  -- Fører ikke raden en slik påstand, kreves feltet ikke, og en rad som førte
  -- det opp ville påstått en kontroll av ingenting.
  if 'source_wide_absence' <> all (workflow.required_check_fields(p_evidence_item_id)) then
    return;
  end if;

  insert into provenance.agent_runs
    (agent_identity_id, actor_id, agent_role, provider, model, model_version,
     prompt_template_version, pipeline_version, input_manifest)
  select ai.id, ai.actor_id, 'extraction_verification', 'prøve', 'prøve', '1',
         'extraction-verification/1', 'antidep-evidence/1', '{"mode": "fikstur"}'::jsonb
  from provenance.agent_identities ai
  where ai.identity_key = 'agent-identity:extraction-verification-01'
  returning id, actor_id into v_run_id, v_actor_id;

  insert into workflow.evidence_verifications
    (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
     source_access, checked_fields, rationale, verified_at, agent_run_id)
  select e.id, e.created_by_actor_id, v_actor_id, 'verified', 'verifiable_representation',
         array['source_wide_absence']::workflow.evidence_check_field[],
         'Fikstur: et søk gjennom hele den kontrollerte representasjonen fant ingen verdi '
         || 'for de feltene raden fører som fraværende i kilden.',
         now() - interval '30 days', v_run_id
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;
end;
$fn$;

-- Den maskinelle halvdelen først, slik at den menneskelige kontrollen blir
-- den gjeldende (registreringsrekkefølgen avgjør, migrasjon 005å).
select pg_temp.cover_source_wide_absence(e.id)
from knowledge.evidence_items e, fixture v
where v.name = 'reviewer';

insert into workflow.evidence_verifications
  (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
   source_access, checked_fields, rationale, verified_at)
select e.id, e.created_by_actor_id, v.id, 'verified', 'original_source',
       -- Full dekning, utledet av raden selv: publiseringsgatens G5b krever at
       -- kontrollene til sammen dekker det funnet påstår noe om.
       array_remove(workflow.required_check_fields(e.id),
                    'source_wide_absence'::workflow.evidence_check_field),
       'Kontrollert mot originalkilden.', now()
from knowledge.evidence_items e, fixture v
where v.name = 'reviewer';

-- Evidenslenke, claim-verifikasjon, evidensvurdering og godkjenning for
-- revisjon 1 og 3.
insert into knowledge.claim_evidence_links
  (claim_revision_id, evidence_item_id, relationship_type, directness,
   relevance_note, created_by_actor_id)
select r.id, e.id, 'supports', 'direct', 'Funnet støtter formuleringen.',
       r.created_by_actor_id
from knowledge.claim_revisions r, knowledge.evidence_items e
where r.claim_id = (select id from fixture where name = 'claim')
  and r.revision_number in (1, 3)
  and e.id = (select e2.id
              from knowledge.evidence_items e2
              join knowledge.sources s on s.id = e2.source_id
              where s.title like 'Fluoxetine versus sertraline%');

insert into workflow.claim_verifications
  (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
   source_access, source_support, population_match, comparator_match, timeframe_match,
   direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
   rationale, verified_at)
select r.id, r.created_by_actor_id, v.id, 'verified', 'original_source',
       'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'Forsøkt falsifisert.', now()
from knowledge.claim_revisions r, fixture v
where r.claim_id = (select id from fixture where name = 'claim')
  and r.revision_number in (1, 3) and v.name = 'reviewer';

-- Vurderingen attribueres til evidensvurderingsaktøren, ikke til den som
-- formulerte revisjonen: publiseringsgatens G10b krever at den som gjorde
-- vurderingen, hadde mandat til det (migrasjon 005ap). Ansvarsgrensen mellom
-- påstandsdannelse og evidensvurdering er en teknisk grense
-- (EVIDENCE_PIPELINE.md §61).
insert into knowledge.evidence_assessments
  (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
   risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
   rationale, assessed_at, created_by_actor_id)
select r.id, r.knowledge_type, 'grade', 'low',
       'serious', 'not_assessable', 'serious', 'serious', 'not_assessable',
       'Domenene vurdert enkeltvis.', now(), (select id from provenance.actors where actor_key = 'agent:evidence-assessment')
from knowledge.claim_revisions r
where r.claim_id = (select id from fixture where name = 'claim')
  and r.revision_number in (1, 3);

insert into workflow.review_decisions
  (claim_revision_id, claim_revision_creator_actor_id, review_type, decision,
   rationale, reviewer_actor_id, reviewer_actor_type, decided_at)
select r.id, r.created_by_actor_id, 'publication_approval', 'approved',
       'Gjennomgått mot kilden.', rv.id, 'human', now()
from knowledge.claim_revisions r, fixture rv
where r.claim_id = (select id from fixture where name = 'claim')
  and r.revision_number in (1, 3) and rv.name = 'reviewer';

-- ---------------------------------------------------------------------------
-- Publiseringsretten (DATABASE_ARCHITECTURE.md §46, §50)
-- ---------------------------------------------------------------------------

-- Ukjente ID-er skal gi en forståelig feil om hva som ikke finnes, ikke en
-- følgefeil lenger nede i kontrollen. Kontrollene ligger før rettighetskontrollen
-- og trenger derfor ingen sesjon.
select throws_like(
  $$select knowledge.publish_claim_revision(
      '00000000-0000-0000-0000-0000000000fe',
      (select id from fixture where name = 'publisher'),
      'Publisering av en revisjon som ikke finnes.')$$,
  '%Påstandsrevisjon % finnes ikke%',
  'publisering av en ukjent revisjon avvises med en egen feilmelding'
);
select throws_like(
  $$select knowledge.withdraw_claim_publication(
      '00000000-0000-0000-0000-0000000000fe',
      (select id from fixture where name = 'publisher'),
      'Avpublisering av en påstand som ikke finnes.')$$,
  '%Påstand % finnes ikke%',
  'avpublisering av en ukjent påstand avvises med en egen feilmelding'
);
select throws_like(
  $$select knowledge.rollback_claim_publication(
      '00000000-0000-0000-0000-0000000000fe',
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Rollback på en påstand som ikke finnes.')$$,
  '%Påstand % finnes ikke%',
  'rollback på en ukjent påstand avvises med en egen feilmelding'
);

-- Uten sesjonsidentitet finnes det ingen som kan stå ansvarlig for handlingen.
select throws_ok(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Publisering uten innlogget bruker.')$$,
  '42501', null,
  'publisering uten innlogget bruker avvises'
);

-- Sesjonen kan ikke publisere som en annen aktør enn sin egen.
select set_config('request.jwt.claims',
                  '{"sub":"cccccccc-0000-0000-0000-000000000002"}', true);
select throws_like(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Publisering på vegne av en annen.')$$,
  '%ikke den aktøren publiseringen attribueres til%',
  'en bruker kan ikke publisere som en annen aktør'
);

-- reviewer gir ikke publiseringsrett: å godkjenne og å publisere er to
-- forskjellige handlinger (MVP_IMPLEMENTATION_PLAN.md §15).
select throws_like(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'reviewer'),
      'Reviewer publiserer sin egen godkjenning.')$$,
  '%ikke gyldig publisher-rolle%',
  'reviewer-rollen gir ikke publiseringsrett'
);

-- En aktør-ID som ikke finnes skal gi en forståelig feil, ikke en følgefeil
-- lenger nede i kontrollen.
select throws_like(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      '00000000-0000-0000-0000-0000000000ff',
      'Publisering med ukjent aktør.')$$,
  '%Aktør % finnes ikke%',
  'en ukjent aktør-ID avvises med en egen feilmelding'
);

-- En KI-aktør kan ikke publisere (MVP_IMPLEMENTATION_PLAN.md §49).
select throws_like(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'synthesis_actor'),
      'Agenten publiserer sitt eget forslag.')$$,
  '%krever en menneskelig aktør%',
  'en KI-aktør kan ikke publisere sitt eget forslag'
);

-- En tilbaketrukket aktør kan ikke utføre nye handlinger, selv med rollen i behold.
select set_config('request.jwt.claims',
                  '{"sub":"cccccccc-0000-0000-0000-000000000003"}', true);
select throws_like(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'retired'),
      'Tilbaketrukket aktør publiserer.')$$,
  '%trukket tilbake og kan ikke publisere%',
  'en tilbaketrukket aktør kan ikke publisere'
);

-- ---------------------------------------------------------------------------
-- Tilbakekalling skal virke umiddelbart, ikke fra neste transaksjon
--
-- Rapportert på PR #15. Publiseringsretten ble målt med now(), som er
-- transaksjonens starttidspunkt. En transaksjon kunne derfor starte mens
-- tildelingen var gyldig, tildelingen kunne tilbakekalles og commites i en annen
-- transaksjon, og den gamle transaksjonen ville deretter sett den tilbakekalte
-- raden — READ COMMITTED gir hver setning et nytt snapshot — men målt valid_to
-- mot et tidspunkt fra før tilbakekallingen og godtatt rettigheten likevel. Det
-- bryter med DATABASE_ARCHITECTURE.md §46, som krever at en rettighet skal kunne
-- tilbakekalles umiddelbart.
--
-- Testen utnytter at en pgTAP-fil kjører i én transaksjon: now() står stille fra
-- transaksjonen startet, mens statement_timestamp() flytter seg for hver setning.
-- Gyldighetsgrensen på tildelingene er lagt nøyaktig i vinduet mellom de to, og
-- pg_sleep gir et robust slingringsmonn framfor å stole på at fixturen tok tid.
-- Assertionen rett under kontrollerer at vinduet faktisk er åpent, slik at
-- testene ikke kan passere fordi tidsskillet kollapset.
-- ---------------------------------------------------------------------------
select pg_sleep(0.05);

select is_empty(
  $$
    select ur.user_id::text
    from workflow.user_roles ur
    where ur.user_id in ('cccccccc-0000-0000-0000-000000000004',
                         'cccccccc-0000-0000-0000-000000000005')
      and not (coalesce(ur.valid_to, ur.valid_from) > now()
               and coalesce(ur.valid_to, ur.valid_from) < statement_timestamp())
  $$,
  'begge gyldighetsgrensene ligger mellom transaksjonens starttidspunkt og den autoriserende setningen'
);

-- En tildeling som ble tilbakekalt etter at transaksjonen startet, gir ikke
-- publiseringsrett. Med now() ville den blitt godtatt.
select set_config('request.jwt.claims',
                  '{"sub":"cccccccc-0000-0000-0000-000000000004"}', true);
select throws_like(
  $$select knowledge.assert_publisher_authorized(
      (select id from fixture where name = 'publisher_tilbakekalt'),
      (select id from fixture where name = 'topic'))$$,
  '%ikke gyldig publisher-rolle%',
  'en tilbakekalt publiseringsrett virker umiddelbart, ikke først fra neste transaksjon (DATABASE_ARCHITECTURE.md §46)'
);

-- ... og motsatt vei: en tildeling som ble gyldig etter at transaksjonen startet,
-- gir publiseringsrett. Med now() ville den blitt avvist. Uten denne assertionen
-- kunne rettelsen vært en regel som bare avviser mer.
select set_config('request.jwt.claims',
                  '{"sub":"cccccccc-0000-0000-0000-000000000005"}', true);
select lives_ok(
  $$select knowledge.assert_publisher_authorized(
      (select id from fixture where name = 'publisher_nettopp_gyldig'),
      (select id from fixture where name = 'topic'))$$,
  'en tildeling som ble gyldig mens transaksjonen pågikk gir publiseringsrett'
);
select set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------------------
-- Radlåsen (DATABASE_ARCHITECTURE.md §61)
--
-- Hva denne assertionen kan og ikke kan vise: en pgTAP-test kjører i én sesjon
-- og én transaksjon, og kan derfor ikke observere at en annen transaksjon
-- blokkerer. pg_locks duger heller ikke som indirekte bevis — fremmednøkkelen
-- fra knowledge.claim_revisions tar allerede FOR KEY SHARE på påstandsraden, og
-- den registreres som den samme RowShareLock på tabellnivå som FOR UPDATE.
--
-- Samtidighetsgarantien er derfor delt i to, og begge delene er testet:
--
--   * Selve regelen — to samtidige publiseringer av samme påstand kan ikke gi to
--     gjeldende revisjoner — er håndhevet deklarativt av
--     publication_events_no_forked_history_key og testet på oppførsel i
--     240_publication_constraints_test.sql. Den holder uansett låsing.
--   * At operasjonene i tillegg tar radlås, slik at den andre transaksjonen
--     venter og leser den nye tilstanden framfor å feile, er en egenskap ved
--     koden, og assereres her som det. Fjernes låsen, feiler testen.
-- ---------------------------------------------------------------------------
select is_empty(
  $$
    select f.function_name
    from (values ('knowledge.publish_claim_revision(uuid, uuid, text)'),
                 ('knowledge.withdraw_claim_publication(uuid, uuid, text)'),
                 ('knowledge.rollback_claim_publication(uuid, uuid, uuid, text)'))
           as f(function_name)
    where (select p.prosrc from pg_proc p where p.oid = f.function_name::regprocedure)
          !~ 'knowledge\.claims[^;]*for update'
  $$,
  'alle tre publiseringsoperasjonene låser påstandsraden med FOR UPDATE før de leser publiseringspekeren'
);
select is_empty(
  $$
    select f.function_name
    from (values ('knowledge.publish_claim_revision(uuid, uuid, text)'),
                 ('knowledge.withdraw_claim_publication(uuid, uuid, text)'),
                 ('knowledge.rollback_claim_publication(uuid, uuid, uuid, text)'),
                 ('knowledge.reject_evidence_link_after_publication()'))
           as f(function_name)
    where (select p.prosrc from pg_proc p where p.oid = f.function_name::regprocedure)
          !~ 'knowledge\.claim_revisions[^;]*for update'
  $$,
  'operasjonene og forseglingen låser revisjonsraden, i den faste rekkefølgen påstand deretter revisjon'
);

-- ---------------------------------------------------------------------------
-- De fire tilstandsovergangene
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
                  '{"sub":"cccccccc-0000-0000-0000-000000000001"}', true);

-- Publiseringsoperasjonen kjører selv gaten. Uten denne assertionen kunne kallet
-- til knowledge.assert_claim_revision_publishable() vært fjernet fra funksjonen
-- uten at noen test merket det: 250 tester gaten direkte, og resten av denne
-- filen publiserer bare revisjoner som passerer den. Revisjon 2 er bevisst ikke
-- bygget ut og har derfor ingen evidenslenker.
select throws_like(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev2'),
      (select id from fixture where name = 'publisher'),
      'Publisering av en revisjon uten evidensgrunnlag.')$$,
  '%ingen registrerte evidenslenker%',
  'publiseringsoperasjonen kjører selv publiseringsgaten'
);

select lives_ok(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Første publisering.')$$,
  'en kvalifisert publisher kan publisere en revisjon som passerer gaten'
);

select is(
  (select c.current_published_revision_id from knowledge.claims c
   where c.id = (select id from fixture where name = 'claim')),
  (select id from fixture where name = 'rev1'),
  'publiseringspekeren står på den publiserte revisjonen'
);
select is(
  (select e.action::text from knowledge.publication_events e
   where e.claim_id = (select id from fixture where name = 'claim')),
  'publish',
  'den første hendelsen er registrert som publish'
);

select throws_like(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Publiserer den samme igjen.')$$,
  '%er allerede den publiserte%',
  'en publisering som ikke endrer noe er ikke en hendelse'
);

-- Avpublisering krever den samme publiseringsretten som publisering. En
-- avpublisering er en synlig endring av hva Antidep sier, og skal ikke være en
-- lettere vei inn i den samme tilstanden.
select set_config('request.jwt.claims',
                  '{"sub":"cccccccc-0000-0000-0000-000000000002"}', true);
select throws_like(
  $$select knowledge.withdraw_claim_publication(
      (select id from fixture where name = 'claim'),
      (select id from fixture where name = 'reviewer'),
      'Reviewer avpubliserer.')$$,
  '%ikke gyldig publisher-rolle%',
  'avpublisering krever publisher-rollen, ikke bare reviewer-rollen'
);
select set_config('request.jwt.claims',
                  '{"sub":"cccccccc-0000-0000-0000-000000000001"}', true);

select lives_ok(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev3'),
      (select id from fixture where name = 'publisher'),
      'Ny formulering etter fornyet gjennomgang.')$$,
  'en nyere revisjon kan erstatte den publiserte'
);
select is(
  (select e.action::text from knowledge.publication_events e
   where e.revision_id = (select id from fixture where name = 'rev3')),
  'replace',
  'erstatningen er registrert som replace, ikke som en ny førstegangspublisering'
);

select throws_like(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Tilbake til den gamle formuleringen.')$$,
  '%eldre enn den publiserte revisjonen%',
  'å gå tilbake til en tidligere revisjon er en rollback, ikke en erstatning'
);

-- Rollback (DATABASE_ARCHITECTURE.md §40)
select set_config('request.jwt.claims',
                  '{"sub":"cccccccc-0000-0000-0000-000000000002"}', true);
select throws_like(
  $$select knowledge.rollback_claim_publication(
      (select id from fixture where name = 'claim'),
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'reviewer'),
      'Reviewer ruller tilbake.')$$,
  '%ikke gyldig publisher-rolle%',
  'rollback krever publisher-rollen, ikke bare reviewer-rollen'
);
select set_config('request.jwt.claims',
                  '{"sub":"cccccccc-0000-0000-0000-000000000001"}', true);

select throws_like(
  $$select knowledge.rollback_claim_publication(
      (select id from fixture where name = 'claim'),
      (select id from fixture where name = 'rev2'),
      (select id from fixture where name = 'publisher'),
      'Ruller tilbake til noe vi aldri har sagt.')$$,
  '%aldri vært publisert%',
  'en rollback kan bare gå tilbake til en revisjon som faktisk har vært publisert'
);
select throws_like(
  $$select knowledge.rollback_claim_publication(
      (select id from fixture where name = 'claim'),
      (select id from fixture where name = 'rev3'),
      (select id from fixture where name = 'publisher'),
      'Rollback til den gjeldende.')$$,
  '%er allerede den publiserte%',
  'en rollback til den gjeldende revisjonen er ikke en tilstandsendring'
);

-- Rollback kjører gaten på nytt på målrevisjonen. En revisjon som var
-- publiserbar tidligere kan ha fått et senere avvik, og da er det ikke lenger en
-- gyldig tilstand å gå tilbake til. Kilden settes midlertidig til retracted for
-- å framkalle nettopp det, uten å røre tidsstemplene i fixturen.
update knowledge.sources
set source_status = 'retracted',
    status_note = 'Trukket tilbake av tidsskriftet i testscenarioet.'
where id = (select e.source_id from knowledge.evidence_items e
            join knowledge.claim_evidence_links l on l.evidence_item_id = e.id
            where l.claim_revision_id = (select id from fixture where name = 'rev1'));

select throws_like(
  $$select knowledge.rollback_claim_publication(
      (select id from fixture where name = 'claim'),
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Rollback til en revisjon som ikke lenger holder.')$$,
  '%retracted eller withdrawn%',
  'rollback kjører publiseringsgaten på nytt på målrevisjonen (DATABASE_ARCHITECTURE.md §40)'
);

update knowledge.sources
set source_status = 'active', status_note = null
where source_status = 'retracted';

select lives_ok(
  $$select knowledge.rollback_claim_publication(
      (select id from fixture where name = 'claim'),
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Den nye formuleringen overtolket grunnlaget.')$$,
  'pekeren kan rulles tilbake til en tidligere publisert revisjon'
);
select is(
  (select c.current_published_revision_id from knowledge.claims c
   where c.id = (select id from fixture where name = 'claim')),
  (select id from fixture where name = 'rev1'),
  'pekeren står på den tilbakerullede revisjonen'
);
-- §40: rollback sletter ikke den problematiske publiseringen.
select is(
  (select count(*) from knowledge.publication_events e
   where e.revision_id = (select id from fixture where name = 'rev3')),
  1::bigint,
  'den problematiske publiseringen står fortsatt i historikken (DATABASE_ARCHITECTURE.md §40)'
);

-- Målrevisjonen må tilhøre påstanden, og må ligge bakover i historikken.
select throws_like(
  $$select knowledge.rollback_claim_publication(
      (select id from fixture where name = 'claim'),
      (select r.id from knowledge.claim_revisions r
       join knowledge.claims c on c.id = r.claim_id
       join catalog.drugs d on d.id = c.subject_drug_id
       where d.canonical_name = 'mirtazapin'),
      (select id from fixture where name = 'publisher'),
      'Rollback til en annen påstands revisjon.')$$,
  '%tilhører en annen påstand%',
  'en rollback kan ikke flytte pekeren til en revisjon av en annen påstand'
);
select throws_like(
  $$select knowledge.rollback_claim_publication(
      (select id from fixture where name = 'claim'),
      (select id from fixture where name = 'rev3'),
      (select id from fixture where name = 'publisher'),
      'Rollback framover.')$$,
  '%nyere enn den publiserte revisjonen%',
  'å gå framover til en nyere revisjon er en erstatning, ikke en rollback'
);

-- Avpublisering
select lives_ok(
  $$select knowledge.withdraw_claim_publication(
      (select id from fixture where name = 'claim'),
      (select id from fixture where name = 'publisher'),
      'Ny kilde gjør formuleringen usikker; tas ut inntil videre.')$$,
  'en publisert påstand kan avpubliseres'
);
select is(
  (select c.current_published_revision_id from knowledge.claims c
   where c.id = (select id from fixture where name = 'claim')),
  null::uuid,
  'ingenting er publisert etter avpubliseringen'
);
select throws_like(
  $$select knowledge.withdraw_claim_publication(
      (select id from fixture where name = 'claim'),
      (select id from fixture where name = 'publisher'),
      'Avpublisering nummer to.')$$,
  '%ingen publisert revisjon å trekke tilbake%',
  'en avpublisering av noe som ikke er publisert er ikke en hendelse'
);
select throws_like(
  $$select knowledge.rollback_claim_publication(
      (select id from fixture where name = 'claim'),
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Rollback uten noe publisert.')$$,
  '%ingen publisert revisjon å rulle tilbake fra%',
  'en rollback forutsetter at noe er publisert'
);

-- Ny publisering etter avpublisering er igjen en publish, og kjeden fortsetter.
select lives_ok(
  $$select knowledge.publish_claim_revision(
      (select id from fixture where name = 'rev1'),
      (select id from fixture where name = 'publisher'),
      'Den nye kilden endret ikke konklusjonen; publiseres på nytt.')$$,
  'en avpublisert påstand kan publiseres på nytt'
);

-- ---------------------------------------------------------------------------
-- Historikken som helhet
-- ---------------------------------------------------------------------------
select results_eq(
  $$
    with recursive chain as (
      select e.id, e.action, e.revision_id, 1 as step
      from knowledge.publication_events e
      where e.claim_id = (select id from fixture where name = 'claim')
        and e.previous_event_id is null
      union all
      select e.id, e.action, e.revision_id, chain.step + 1
      from knowledge.publication_events e
      join chain on e.previous_event_id = chain.id
    )
    select step, action::text from chain order by step
  $$,
  $$values (1, 'publish'), (2, 'replace'), (3, 'rollback'), (4, 'withdraw'), (5, 'publish')$$,
  'hendelseskjeden gjengir hele forløpet i rekkefølge, uten at noe er slettet'
);
select is(
  (select count(*) from knowledge.publication_events e
   where e.claim_id = (select id from fixture where name = 'claim')),
  5::bigint,
  'alle fem hendelsene ligger i kjeden; ingen står utenfor'
);
-- Pekeren og historikken sier det samme: den siste hendelsen i kjeden bærer den
-- revisjonen som faktisk er publisert.
select is(
  (select e.revision_id
   from knowledge.publication_events e
   where e.claim_id = (select id from fixture where name = 'claim')
     and not exists (
       select 1 from knowledge.publication_events successor
       where successor.previous_event_id = e.id
     )),
  (select c.current_published_revision_id from knowledge.claims c
   where c.id = (select id from fixture where name = 'claim')),
  'den siste hendelsen i kjeden stemmer med publiseringspekeren'
);

-- Attribusjonen er reell: hver hendelse peker på mennesket som utførte den.
select is_empty(
  $$
    select e.id::text
    from knowledge.publication_events e
    join provenance.actors a on a.id = e.published_by_actor_id
    where a.actor_key <> 'human:publisher-260'
  $$,
  'alle hendelsene er attribuert til publisheren som faktisk utførte dem'
);

select * from finish();

rollback;
