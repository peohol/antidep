-- Migrasjon 013j — den samlede monografikandidaten, sluttkontrollen og
--                  publiseringen.
--
-- Filen dekker at det som tas i bruk, er nøyaktig det et navngitt menneske
-- leste:
--
--   * kandidaten fryser hele visningen, dekningen, standardversjonen og de
--     eksakte svarrevisjonene, med et avtrykk av alt sammen,
--   * den samme utgaven bygget to ganger er én kandidat,
--   * en utgave uten ett eneste kontrollert svar er ikke en kandidat,
--   * sluttkontrollen er bundet til avtrykket, og et annet avtrykk avvises,
--   * ingen agent kan attestere at et menneske har vurdert innhold,
--   * publisering krever et annet mandat enn godkjenning,
--   * en kandidat monografien har forlatt, kan verken godkjennes eller
--     publiseres,
--   * tilbaketrekking sletter ingenting, og
--   * private kildeutdrag følger ikke med kandidaten.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23514 = check_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(34);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('knowledge', 'monograph_edition_candidates',
                 'knowledge.monograph_edition_candidates finnes');
select has_table('workflow', 'monograph_final_controls',
                 'workflow.monograph_final_controls finnes');
select has_table('knowledge', 'monograph_publication_events',
                 'knowledge.monograph_publication_events finnes');

select is_empty(
  $$
    select t.table_name, r.role_name, p.privilege
    from (values ('knowledge.monograph_edition_candidates'),
                 ('workflow.monograph_final_controls'),
                 ('knowledge.monograph_publication_events')) as t(table_name),
         (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, t.table_name, p.privilege)
  $$,
  'ingen klientrolle leser eller skriver kandidaten, kontrollen eller historikken direkte'
);

-- ===========================================================================
-- Del 2 — Kontoene: tre mandater, tre mennesker
-- ===========================================================================
insert into auth.users (id, email)
values
  ('91000000-0000-4000-8000-00000000000a', 'redaktor-910@test.invalid'),
  ('91000000-0000-4000-8000-00000000000b', 'kontrollor-910@test.invalid'),
  ('91000000-0000-4000-8000-00000000000c', 'utgiver-910@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac910000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-910',
   'Redaktør 910', 'Editor, for 910.', '91000000-0000-4000-8000-00000000000a'),
  ('ac910000-0000-4000-8000-00000000000b', 'human', 'human:kontrollor-910',
   'Kontrollør 910', 'Reviewer, for 910.', '91000000-0000-4000-8000-00000000000b'),
  ('ac910000-0000-4000-8000-00000000000c', 'human', 'human:utgiver-910',
   'Utgiver 910', 'Publisher, for 910.', '91000000-0000-4000-8000-00000000000c');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('91000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
   'ac910000-0000-4000-8000-00000000000a', 'Editor-tildeling for 910.'),
  ('91000000-0000-4000-8000-00000000000b', 'editor', null, now() - interval '1 year',
   'ac910000-0000-4000-8000-00000000000a', 'Editor-tildeling for kontrolløren i 910.'),
  ('91000000-0000-4000-8000-00000000000b', 'reviewer', null, now() - interval '1 year',
   'ac910000-0000-4000-8000-00000000000a', 'Reviewer-tildeling for 910.'),
  ('91000000-0000-4000-8000-00000000000c', 'editor', null, now() - interval '1 year',
   'ac910000-0000-4000-8000-00000000000a', 'Editor-tildeling for utgiveren i 910.'),
  ('91000000-0000-4000-8000-00000000000c', 'publisher', null, now() - interval '1 year',
   'ac910000-0000-4000-8000-00000000000a', 'Publisher-tildeling for 910.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
create temporary table ref (name text primary key, value text not null) on commit drop;
grant select, insert on svar to authenticated;
grant select on fixture to authenticated;
grant select on ref to authenticated;

insert into fixture (name, id) values ('redaktor', 'ac910000-0000-4000-8000-00000000000a');
insert into fixture (name, id)
select 'owner', id from provenance.actors where actor_key = 'human:peder-holman';

select set_config('request.jwt.claims',
                  '{"sub":"91000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 910.');
reset role;

insert into fixture (name, id)
select 'edition', e.id from knowledge.monograph_editions e
where e.reference = (select payload ->> 'reference' from svar where label = 'bestilling');
insert into ref (name, value)
select 'bestilling', payload ->> 'reference' from svar where label = 'bestilling';

-- Et dekningskart uten ett eneste svar er ikke en kandidat.
select set_config('request.jwt.claims',
                  '{"sub":"91000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.build_monograph_candidate(%L) $$,
         (select value from ref where name = 'bestilling')),
  '23001', null,
  'et dekningskart uten ett eneste kontrollert svar er ikke en monografikandidat'
);
reset role;

-- ===========================================================================
-- Del 3 — Et kontrollert svar, og kandidaten av det
-- ===========================================================================
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('91000000-0000-4000-8000-000000000001', 'summary_of_product_characteristics',
        'Syntetisk preparatomtale for 910', 'Syntetisk myndighet',
        (select id from fixture where name = 'owner'));

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash,
  representation, retrieved_by_actor_id
)
values ('91000000-0000-4000-8000-000000000021', '91000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/910',
        knowledge.source_version_content_hash(
          'Sertralin Testmerke tabletter 50 mg. Pakning med 28 tabletter.'),
        'regulatory_summary', (select id from fixture where name = 'owner'));

insert into knowledge.source_version_texts
  (source_version_id, representation, stored_by_actor_id)
values ('91000000-0000-4000-8000-000000000021',
        'Sertralin Testmerke tabletter 50 mg. Pakning med 28 tabletter.',
        (select id from fixture where name = 'owner'));

insert into fixture (name, id)
select 'preparatbehov', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where n.edition_id = (select id from fixture where name = 'edition') and t.code = 'MN03'
limit 1;

insert into knowledge.monograph_source_uses
  (need_id, source_version_id, approved_use, scope_digest, approved_by_actor_id)
select n.id, '91000000-0000-4000-8000-000000000021',
       'Oppgir handelsnavn, formulering, styrke og pakningsidentitet.',
       n.scope_digest, (select id from fixture where name = 'redaktor')
from knowledge.monograph_needs n
where n.id = (select id from fixture where name = 'preparatbehov');

insert into fixture (name, id)
select 'svar-1', knowledge.record_monograph_answer_revision(
  (select id from fixture where name = 'preparatbehov'),
  'product_data', 'human',
  'Sertralin Testmerke finnes som tabletter 50 mg i pakning med 28 tabletter.',
  jsonb_build_object('strength_mg', 50), null, null, null,
  '91000000-0000-4000-8000-000000000021', '2026-09-01',
  'Pakning med 28 tabletter.', 'Avsnitt 3', null, null, null, null,
  'Prøve i 910.', (select id from fixture where name = 'redaktor'), null);

select set_config('request.jwt.claims',
                  '{"sub":"91000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'kandidat', api.build_monograph_candidate(
  (select value from ref where name = 'bestilling'));
insert into svar (label, payload)
select 'kandidat-igjen', api.build_monograph_candidate(
  (select value from ref where name = 'bestilling'));
insert into svar (label, payload)
select 'utkast', api.monograph_draft((select value from ref where name = 'bestilling'));
reset role;

insert into ref (name, value)
select 'kandidat', payload ->> 'reference' from svar where label = 'kandidat';
insert into ref (name, value)
select 'avtrykk', payload ->> 'content_digest' from svar where label = 'kandidat';

select is(
  (select payload ->> 'reference' from svar where label = 'kandidat-igjen'),
  (select value from ref where name = 'kandidat'),
  'den samme utgaven bygget to ganger er én kandidat'
);
select is(
  (select (payload -> 'answer_revisions')::integer from svar where label = 'kandidat'),
  1,
  'kandidaten er bundet til de eksakte svarrevisjonene den er bygget av'
);
select ok(
  (select payload ->> 'content_digest' from svar where label = 'kandidat') ~ '^sha256:[0-9a-f]{64}$',
  'og den bærer et avtrykk av hele innholdet'
);

-- De private utdragene følger ikke med kandidaten. Den redaksjonelle visningen
-- har dem, fordi det er der de trengs for å etterprøve svaret.
select is(
  (select c.content::text like '%Pakning med 28 tabletter.%'
   from knowledge.monograph_edition_candidates c
   where c.reference = (select value from ref where name = 'kandidat')),
  false,
  'det ordrette utdraget fra det private dokumentet følger ikke med kandidaten'
);
select ok(
  (select payload::text like '%Pakning med 28 tabletter.%' from svar where label = 'utkast'),
  'mens den redaksjonelle visningen har det, slik svaret kan etterprøves'
);
select ok(
  (select payload -> 'coverage' -> 'needs' ->> 'total' from svar where label = 'utkast')::integer > 100,
  'og nevneren er hele den lagrede behovslisten for utgaven'
);
select is(
  (select payload -> 'coverage' -> 'needs' ->> 'answered' from svar where label = 'utkast'),
  '1',
  'med ett besvart behov'
);

select is(
  (select count(*)::integer from audit.events e
   where e.operation = 'monograph_candidate_built'),
  1,
  'byggingen av kandidaten står i sporet'
);

-- ===========================================================================
-- Del 4 — Sluttkontrollen er bundet til avtrykket, og til et menneske
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"91000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.record_monograph_final_control(%L, %L, 'approved', 'Prøve i 910.') $$,
         (select value from ref where name = 'kandidat'),
         (select value from ref where name = 'avtrykk')),
  '42501', null,
  'en redaktør uten reviewer-mandat kan ikke gjøre sluttkontrollen'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"91000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.record_monograph_final_control(%L, 'sha256:%s', 'approved', 'Prøve i 910.') $$,
         (select value from ref where name = 'kandidat'),
         repeat('0', 64)),
  '23001', null,
  'et annet avtrykk enn kandidatens avvises: kontrollen gjelder det som ble lest'
);

insert into svar (label, payload)
select 'kontroll', api.record_monograph_final_control(
  (select value from ref where name = 'kandidat'),
  (select value from ref where name = 'avtrykk'),
  'approved',
  'Prøve i 910: utgaven er lest i sin helhet, og innholdet er faglig forsvarlig.');
reset role;

select is(
  (select (payload -> 'recorded')::boolean from svar where label = 'kontroll'),
  true,
  'sluttkontrollen registreres av et navngitt menneske med reviewer-mandat'
);

-- Ingen agent kan attestere at et menneske har vurdert innhold: kravet er
-- strukturelt.
select throws_ok(
  format($$
    insert into workflow.monograph_final_controls
      (candidate_id, candidate_digest, decision, rationale,
       reviewer_actor_id, reviewer_actor_type)
    select c.id, c.content_hash, 'approved', 'En agent som godkjenner.',
           (select id from provenance.actors where actor_key = 'agent:claim-synthesis'),
           'agent'
    from knowledge.monograph_edition_candidates c
    where c.reference = %L
  $$, (select value from ref where name = 'kandidat')),
  '23514', null,
  'en agent kan ikke attestere at innholdet er vurdert'
);

select is(
  (select count(*)::integer from audit.events e
   where e.operation = 'monograph_final_control_recorded'),
  1,
  'og sluttkontrollen står i sporet'
);

-- ===========================================================================
-- Del 5 — Publisering er en annen handling, med et annet mandat
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"91000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.publish_monograph(%L, 'Prøve i 910.') $$,
         (select value from ref where name = 'kandidat')),
  '42501', null,
  'den som godkjente, kan ikke publisere på sitt eget reviewer-mandat'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"91000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'publisering', api.publish_monograph(
  (select value from ref where name = 'kandidat'),
  'Prøve i 910: utgaven tas i bruk.');
insert into svar (label, payload)
select 'publisering-igjen', api.publish_monograph(
  (select value from ref where name = 'kandidat'),
  'Prøve i 910: den samme utgaven en gang til.');
reset role;

select is(
  (select (payload -> 'published')::boolean from svar where label = 'publisering'),
  true,
  'en kontrollert utgave publiseres av en aktør med publisher-mandat'
);
select is(
  (select (payload -> 'already_published')::boolean from svar where label = 'publisering-igjen'),
  true,
  'og den samme utgaven publisert to ganger er ikke to handlinger'
);
select is(
  (select count(*)::integer from knowledge.monograph_publication_events p
   where p.action = 'published'),
  1,
  'historikken har nøyaktig én publiseringshendelse'
);
select is(
  (select c.reference from knowledge.monograph_edition_candidates c
   join knowledge.monograph_editions e on e.current_published_candidate_id = c.id
   where e.id = (select id from fixture where name = 'edition')),
  (select value from ref where name = 'kandidat'),
  'og utgaven peker på nøyaktig den kandidaten som ble kontrollert'
);
select is(
  (select count(*)::integer from audit.events e where e.operation = 'monograph_published'),
  1,
  'publiseringen står i sporet'
);

-- ===========================================================================
-- Del 6 — En kandidat monografien har forlatt
-- ===========================================================================
insert into fixture (name, id)
select 'svar-2', knowledge.record_monograph_answer_revision(
  (select id from fixture where name = 'preparatbehov'),
  'product_data', 'human',
  'Sertralin Testmerke finnes som tabletter 50 mg; pakningen har 28 tabletter.',
  jsonb_build_object('strength_mg', 50, 'pack_size', 28), null, null, null,
  '91000000-0000-4000-8000-000000000021', '2026-09-05',
  'Sertralin Testmerke tabletter 50 mg.', 'Avsnitt 3', null, null, null, null,
  'Prøve i 910: svaret er revidert.', (select id from fixture where name = 'redaktor'), null);

select isnt(
  knowledge.monograph_candidate_staleness(
    (select c.id from knowledge.monograph_edition_candidates c
     where c.reference = (select value from ref where name = 'kandidat'))),
  null,
  'kandidaten er ikke lenger monografien når et svar har fått en ny revisjon'
);

select set_config('request.jwt.claims',
                  '{"sub":"91000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.record_monograph_final_control(%L, %L, 'approved', 'Prøve i 910.') $$,
         (select value from ref where name = 'kandidat'),
         (select value from ref where name = 'avtrykk')),
  '23001', null,
  'en utgave monografien har forlatt, kan ikke godkjennes'
);
reset role;

select set_config('request.jwt.claims',
                  '{"sub":"91000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'ny-kandidat', api.build_monograph_candidate(
  (select value from ref where name = 'bestilling'));
select throws_ok(
  format($$ select api.publish_monograph(%L, 'Prøve i 910.') $$,
         (select payload ->> 'reference' from svar where label = 'ny-kandidat')),
  '23001', null,
  'og en ny kandidat uten sluttkontroll publiseres ikke'
);
reset role;

select isnt(
  (select payload ->> 'reference' from svar where label = 'ny-kandidat'),
  (select value from ref where name = 'kandidat'),
  'det endrede innholdet gir en ny kandidat med sitt eget avtrykk'
);

-- ===========================================================================
-- Del 7 — Tilbaketrekking sletter ingenting
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"91000000-0000-4000-8000-00000000000c"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'tilbaketrekking', api.withdraw_monograph_publication(
  (select value from ref where name = 'bestilling'),
  'Prøve i 910: utgaven er trukket ut av bruk mens grunnlaget revideres.');
reset role;

select is(
  (select e.current_published_candidate_id from knowledge.monograph_editions e
   where e.id = (select id from fixture where name = 'edition')),
  null,
  'en tilbaketrukket utgave er ikke lenger i bruk'
);
select is(
  (select count(*)::integer from knowledge.monograph_publication_events p
   where p.edition_id = (select id from fixture where name = 'edition')),
  2,
  'men begge hendelsene står: publiseringen og tilbaketrekkingen'
);
select throws_ok(
  $$ delete from knowledge.monograph_publication_events $$,
  '23001', null,
  'og historikken kan ikke slettes'
);
select is(
  (select count(*)::integer from audit.events e
   where e.operation = 'monograph_publication_withdrawn'),
  1,
  'tilbaketrekkingen står i sporet'
);

-- ===========================================================================
-- Del 8 — Kandidaten er uforanderlig
-- ===========================================================================
select throws_ok(
  format($$ update knowledge.monograph_edition_candidates
            set content = '{}'::jsonb where reference = %L $$,
         (select value from ref where name = 'kandidat')),
  '23001', null,
  'en monografikandidat skrives ikke om: den er det et menneske faktisk leste'
);
select throws_ok(
  $$ update workflow.monograph_final_controls set decision = 'rejected' $$,
  '23001', null,
  'og en sluttkontroll skrives ikke om i ettertid'
);

select * from finish();
rollback;
