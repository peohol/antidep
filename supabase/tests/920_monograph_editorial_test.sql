-- Migrasjon 013k — den redaksjonelle kontrollen.
--
-- Filen dekker at et menneske med mandat faktisk styrer innholdet, og at
-- styringen ikke kan omgås:
--
--   * en rettelse er en ny revisjon med en begrunnelse, og den forrige blir
--     stående,
--   * en lås stopper den automatiske skrivingen, men skjermer ikke innholdet
--     mot kritikk: det som ville blitt skrevet, blir et synlig avvik,
--   * et menneske med mandat kan fortsatt rette et låst svar,
--   * en kildebegrensning håndheves i databasen og ikke i flaten,
--   * en relevant kilde utenfor listen blir et synlig forslag — den brukes ikke
--     i det stille, og den erklæres ikke irrelevant,
--   * å godta en slik kilde utvider listen framfor å gi en usynlig dispensasjon,
--   * en forkastet kildebruk slettes ikke, men kan ikke lenger bære et svar, og
--   * ingen av veiene er åpne uten redaktørmandat.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(32);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('workflow', 'monograph_source_restrictions',
                 'workflow.monograph_source_restrictions finnes');
select has_table('workflow', 'monograph_revision_proposals',
                 'workflow.monograph_revision_proposals finnes');
select has_table('knowledge', 'monograph_source_use_revocations',
                 'knowledge.monograph_source_use_revocations finnes');
select has_column('knowledge', 'monograph_answers', 'locked_at',
                  'et svar kan låses mot automatisk overskriving');

select is_empty(
  $$
    select t.table_name, r.role_name, p.privilege
    from (values ('workflow.monograph_source_restrictions'),
                 ('workflow.monograph_restriction_sources'),
                 ('workflow.monograph_revision_proposals'),
                 ('knowledge.monograph_source_use_revocations')) as t(table_name),
         (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, t.table_name, p.privilege)
  $$,
  'ingen klientrolle skriver låsen, begrensningen eller avvikene direkte'
);

-- ===========================================================================
-- Del 2 — Fikstur
-- ===========================================================================
insert into auth.users (id, email)
values
  ('92000000-0000-4000-8000-00000000000a', 'redaktor-920@test.invalid'),
  ('92000000-0000-4000-8000-00000000000b', 'kliniker-920@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac920000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-920',
   'Redaktør 920', 'Editor, for 920.', '92000000-0000-4000-8000-00000000000a'),
  ('ac920000-0000-4000-8000-00000000000b', 'human', 'human:kliniker-920',
   'Kliniker 920', 'Uten mandat, for 920.', '92000000-0000-4000-8000-00000000000b');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('92000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
        'ac920000-0000-4000-8000-00000000000a', 'Editor-tildeling for 920.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
create temporary table ref (name text primary key, value text not null) on commit drop;
grant select, insert on svar to authenticated;
grant select on fixture to authenticated;
grant select on ref to authenticated;

insert into fixture (name, id) values ('redaktor', 'ac920000-0000-4000-8000-00000000000a');
insert into fixture (name, id)
select 'owner', id from provenance.actors where actor_key = 'human:peder-holman';

select set_config('request.jwt.claims',
                  '{"sub":"92000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 920.');
reset role;

insert into fixture (name, id)
select 'edition', e.id from knowledge.monograph_editions e
where e.reference = (select payload ->> 'reference' from svar where label = 'bestilling');
insert into ref (name, value)
select 'bestilling', payload ->> 'reference' from svar where label = 'bestilling';

insert into fixture (name, id)
select 'behov', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where n.edition_id = (select id from fixture where name = 'edition') and t.code = 'MN03'
limit 1;
insert into ref (name, value)
select 'behov', n.reference from knowledge.monograph_needs n
where n.id = (select id from fixture where name = 'behov');

-- To kilder: én som blir forhåndsgodkjent, og én som ikke blir det.
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('92000000-0000-4000-8000-000000000001', 'summary_of_product_characteristics',
   'Godkjent preparatomtale 920', 'Syntetisk myndighet',
   (select id from fixture where name = 'owner')),
  ('92000000-0000-4000-8000-000000000002', 'journal_article',
   'En annen kilde 920', 'Testforfatter 920',
   (select id from fixture where name = 'owner'));

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash,
  representation, retrieved_by_actor_id
)
values
  ('92000000-0000-4000-8000-000000000021', '92000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/920a',
   knowledge.source_version_content_hash('Sertralin Testmerke tabletter 50 mg.'),
   'regulatory_summary', (select id from fixture where name = 'owner')),
  ('92000000-0000-4000-8000-000000000022', '92000000-0000-4000-8000-000000000002',
   now(), 'https://example.test/920b',
   knowledge.source_version_content_hash('En annen tekst om sertralin, 100 mg tabletter.'),
   'regulatory_summary', (select id from fixture where name = 'owner'));

insert into knowledge.source_version_texts
  (source_version_id, representation, stored_by_actor_id)
values
  ('92000000-0000-4000-8000-000000000021', 'Sertralin Testmerke tabletter 50 mg.',
   (select id from fixture where name = 'owner')),
  ('92000000-0000-4000-8000-000000000022',
   'En annen tekst om sertralin, 100 mg tabletter.',
   (select id from fixture where name = 'owner'));

insert into knowledge.monograph_source_uses
  (need_id, source_version_id, approved_use, scope_digest, approved_by_actor_id)
select n.id, '92000000-0000-4000-8000-000000000021',
       'Oppgir handelsnavn, formulering og styrke.',
       n.scope_digest, (select id from fixture where name = 'redaktor')
from knowledge.monograph_needs n where n.id = (select id from fixture where name = 'behov');

-- En agentkjøring i svarrollen, slik et agentskrevet svar har et ekte opphav.
insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   model_version_disclosure, prompt_template_version, pipeline_version, input_manifest)
select '92000000-0000-4000-8000-000000000051', ai.id, ai.actor_id, 'monograph_answer',
       'openai', 'GPT-5 Thinking', 'ikke-eksponert', 'not_exposed',
       'monograph-answer/handoff-fact/2', 'antidep-evidence/1',
       '{"mode": "test-920"}'::jsonb
from provenance.agent_identities ai
where ai.identity_key = 'agent-identity:monograph-answer-01';

insert into fixture (name, id)
select 'svar-1', knowledge.record_monograph_answer_revision(
  (select id from fixture where name = 'behov'),
  'product_data', 'agent',
  'Sertralin Testmerke finnes som tabletter 50 mg.',
  null, null, null, null, '92000000-0000-4000-8000-000000000021', '2026-09-01',
  'Sertralin Testmerke tabletter 50 mg.', 'Avsnitt 3', null, null, null, null,
  'Prøve i 920: agentens svar.',
  (select ai.actor_id from provenance.agent_identities ai
   where ai.identity_key = 'agent-identity:monograph-answer-01'),
  '92000000-0000-4000-8000-000000000051');

-- ===========================================================================
-- Del 3 — Rettelsen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"92000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.edit_monograph_answer(%L, 'Noe annet.', null, null, null, 'Fordi.') $$,
         (select value from ref where name = 'behov')),
  '42501', null,
  'en kliniker uten redaktørmandat kan ikke rette et svar'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"92000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.edit_monograph_answer(%L, 'Noe annet.') $$,
         (select value from ref where name = 'behov')),
  '22023', null,
  'en redaksjonell endring uten begrunnelse avvises'
);

insert into svar (label, payload)
select 'rettelse', api.edit_monograph_answer(
  (select value from ref where name = 'behov'),
  'Sertralin Testmerke finnes som tabletter 50 mg. Andre styrker er ikke omtalt her.',
  'Preparatomtalen omtaler ikke andre styrker.',
  null, null,
  'Prøve i 920: presisert at andre styrker ikke er omtalt.');
reset role;

select is(
  (select r.origin::text from knowledge.monograph_answer_revisions r
   join knowledge.monograph_answers a on a.id = r.answer_id
   where a.need_id = (select id from fixture where name = 'behov')
     and a.current_revision_id = r.id),
  'human',
  'rettelsen står som menneskets, ikke som agentens'
);
select is(
  (select count(*)::integer from knowledge.monograph_answer_revisions r
   join knowledge.monograph_answers a on a.id = r.answer_id
   where a.need_id = (select id from fixture where name = 'behov')),
  2,
  'og agentens svar blir stående som den forrige revisjonen'
);
select is(
  (select r.source_quote from knowledge.monograph_answer_revisions r
   join knowledge.monograph_answers a on a.id = r.answer_id
   where a.need_id = (select id from fixture where name = 'behov')
     and a.current_revision_id = r.id),
  'Sertralin Testmerke tabletter 50 mg.',
  'kildestøtten videreføres uendret: en rettelse endrer formuleringen, ikke grunnlaget'
);

-- ===========================================================================
-- Del 4 — Låsen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"92000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'laas', api.lock_monograph_answer(
  (select value from ref where name = 'behov'),
  'Prøve i 920: formuleringen er avklart med fagansvarlig og skal ikke overskrives.');
reset role;

select is(
  (select (payload -> 'locked')::boolean from svar where label = 'laas'),
  true,
  'svaret kan låses mot automatisk overskriving'
);
select is(
  (select count(*)::integer from audit.events e
   where e.operation = 'monograph_answer_lock_changed'),
  1,
  'og låsingen står i sporet'
);

-- Automatikken får ikke skrive, men det den ville skrevet, blir synlig.
select is(
  knowledge.record_monograph_answer_revision(
    (select id from fixture where name = 'behov'),
    'product_data', 'agent',
    'Et nytt automatisk svar som ville overskrevet det låste.',
    null, null, null, null, '92000000-0000-4000-8000-000000000021', '2026-09-20',
    'Sertralin Testmerke tabletter 50 mg.', 'Avsnitt 3', null, null, null, null,
    'Prøve i 920.',
    (select ai.actor_id from provenance.agent_identities ai
     where ai.identity_key = 'agent-identity:monograph-answer-01'),
    '92000000-0000-4000-8000-000000000051'),
  null,
  'automatikken skriver ikke over et låst svar'
);
select is(
  (select r.statement from knowledge.monograph_answer_revisions r
   join knowledge.monograph_answers a on a.id = r.answer_id
   where a.need_id = (select id from fixture where name = 'behov')
     and a.current_revision_id = r.id),
  'Sertralin Testmerke finnes som tabletter 50 mg. Andre styrker er ikke omtalt her.',
  'det låste innholdet står uendret'
);
select is(
  (select count(*)::integer from workflow.monograph_revision_proposals p
   where p.need_id = (select id from fixture where name = 'behov')
     and p.kind = 'locked_answer_challenged' and p.state = 'open'),
  1,
  'men det som ville blitt skrevet, er et synlig avvik'
);
select ok(
  (select p.rationale like '%Et nytt automatisk svar%'
   from workflow.monograph_revision_proposals p
   where p.kind = 'locked_answer_challenged' limit 1),
  'og avviket bærer hva automatikken ville sagt, slik det kan vurderes'
);

-- Et menneske med mandat kan fortsatt rette det låste svaret.
select set_config('request.jwt.claims',
                  '{"sub":"92000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'rettelse-2', api.edit_monograph_answer(
  (select value from ref where name = 'behov'),
  'Sertralin Testmerke finnes som tabletter 50 mg. Presisert etter avviket.',
  null, null, null, 'Prøve i 920: rettet av mennesket som eier låsen.');
reset role;

select is(
  (select (payload -> 'edited')::boolean from svar where label = 'rettelse-2'),
  true,
  'et menneske med mandat kan fortsatt rette et låst svar'
);

-- ===========================================================================
-- Del 5 — Kildebegrensningen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"92000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'begrensning', api.restrict_monograph_sources(
  (select value from ref where name = 'bestilling'),
  'MN03',
  array['Godkjent preparatomtale 920'],
  'Prøve i 920: norske produktopplysninger skal bare hentes fra den godkjente preparatomtalen.');
reset role;

select is(
  (select (payload -> 'approved_sources')::integer from svar where label = 'begrensning'),
  1,
  'området kan begrenses til forhåndsgodkjente kilder'
);
select is(
  (select count(*)::integer from audit.events e
   where e.operation = 'monograph_source_restriction_registered'),
  1,
  'og begrensningen står i sporet'
);
select ok(
  workflow.monograph_source_is_permitted(
    (select id from fixture where name = 'behov'),
    '92000000-0000-4000-8000-000000000001'),
  'den forhåndsgodkjente kilden kan brukes'
);
select ok(
  not workflow.monograph_source_is_permitted(
    (select id from fixture where name = 'behov'),
    '92000000-0000-4000-8000-000000000002'),
  'og en kilde utenfor listen kan ikke'
);

-- Håndhevet i databasen, ikke i flaten.
select ok(
  workflow.monograph_answer_citation_problem(
    (select id from fixture where name = 'behov'),
    '92000000-0000-4000-8000-000000000022', '2026-09-01',
    'En annen tekst om sertralin, 100 mg tabletter.', 'Avsnitt 1') is not null,
  'en kilde utenfor listen kan ikke bære et svar, uansett hvem som skriver det'
);

-- En relevant kilde utenfor listen blir et synlig forslag.
insert into knowledge.monograph_source_uses
  (need_id, source_version_id, approved_use, scope_digest, approved_by_actor_id)
select n.id, '92000000-0000-4000-8000-000000000022',
       'Kan også oppgi en styrke.', n.scope_digest,
       (select id from fixture where name = 'redaktor')
from knowledge.monograph_needs n where n.id = (select id from fixture where name = 'behov');

select is(
  workflow.record_monograph_revision_proposal(
    (select id from fixture where name = 'behov'),
    'restricted_source_offered'::workflow.monograph_proposal_kind,
    null, '92000000-0000-4000-8000-000000000022',
    'Prøve i 920: kilden er relevant, men står ikke i den forhåndsgodkjente listen.',
    (select id from fixture where name = 'redaktor'), null) is not null,
  true,
  'en kilde utenfor listen blir et synlig forslag'
);

insert into ref (name, value)
select 'forslag', p.reference from workflow.monograph_revision_proposals p
where p.kind = 'restricted_source_offered' and p.state = 'open' limit 1;

select set_config('request.jwt.claims',
                  '{"sub":"92000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'avvik', api.monograph_revision_proposals(
  (select value from ref where name = 'bestilling'));
insert into svar (label, payload)
select 'godta', api.decide_monograph_revision_proposal(
  (select value from ref where name = 'forslag'), true,
  'Prøve i 920: kilden godtas, og listen utvides.');
reset role;

select ok(
  (select jsonb_array_length(payload -> 'proposals') >= 2 from svar where label = 'avvik'),
  'avvikslisten viser både det låste svaret og kilden utenfor listen'
);
select ok(
  workflow.monograph_source_is_permitted(
    (select id from fixture where name = 'behov'),
    '92000000-0000-4000-8000-000000000002'),
  'å godta kilden utvider listen framfor å gi en usynlig dispensasjon'
);
select is(
  (select p.state::text from workflow.monograph_revision_proposals p
   where p.reference = (select value from ref where name = 'forslag')),
  'accepted',
  'og forslaget er avgjort'
);

-- ===========================================================================
-- Del 6 — Forkastingen
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"92000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'forkast', api.discard_monograph_source(
  (select value from ref where name = 'behov'),
  'En annen kilde 920',
  'Prøve i 920: kilden er ikke egnet for norske produktopplysninger likevel.');
reset role;

select is(
  (select (payload -> 'discarded')::boolean from svar where label = 'forkast'),
  true,
  'en godkjent kildebruk kan forkastes'
);
select is(
  (select count(*)::integer from knowledge.monograph_source_uses u
   where u.need_id = (select id from fixture where name = 'behov')),
  2,
  'og godkjenningen slettes ikke: den blir stående som det den var'
);
select ok(
  workflow.monograph_answer_citation_problem(
    (select id from fixture where name = 'behov'),
    '92000000-0000-4000-8000-000000000022', '2026-09-01',
    'En annen tekst om sertralin, 100 mg tabletter.', 'Avsnitt 1')
    like '%forkastet%',
  'men den kan ikke lenger bære et svar'
);
select throws_ok(
  $$ delete from knowledge.monograph_source_use_revocations $$,
  '23001', null,
  'og forkastingen kan ikke slettes'
);

-- ===========================================================================
-- Del 7 — Mandatet
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"92000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.lock_monograph_answer(%L, 'Fordi.') $$,
         (select value from ref where name = 'behov')),
  '42501', null,
  'en kliniker uten mandat kan ikke låse et svar'
);
select throws_ok(
  format($$ select api.restrict_monograph_sources(%L, 'MN03', array['x'], 'Fordi.') $$,
         (select value from ref where name = 'bestilling')),
  '42501', null,
  'og kan ikke begrense hvilke kilder et område bruker'
);
reset role;

select * from finish();
rollback;
