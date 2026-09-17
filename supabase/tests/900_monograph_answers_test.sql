-- Migrasjon 013i — det strukturerte svaret.
--
-- Filen dekker at et svar bare kan stå når det kan kontrolleres:
--
--   * hver kunnskapstype har sin egen dokumentasjonskontrakt, og en type uten
--     en kontrakt stopper skrivingen,
--   * et ordrett utdrag som ikke står i den registrerte representasjonen,
--     avvises — det samme gjør en manglende lokalisering, et manglende eller
--     framtidig tidspunkt og en kilde som ikke er godkjent for behovet,
--   * en regulatorisk opplysning får ingen GRADE-vurdering, og et forskningsfunn
--     kan ikke skrives av svaragenten,
--   * et forskningssvar krever en påstand som har bestått kildestøttekontrollen,
--     har en evidensvurdering og svarer på nettopp dette behovet,
--   * et avledet svar hviler bare på gjeldende svar i den samme utgaven,
--   * en revisjon er uforanderlig, den forrige blir stående, og sporet bærer
--     begge,
--   * hver revisjon har nøyaktig én kontrollrad med hvilke felter som ble
--     kontrollert,
--   * den godkjente kildebruken legger svaroppgaven i køen, og
--   * den deterministiske svarkontrollen kan ikke settes ut til en modell.
--
-- SQLSTATE 22023 = invalid_parameter_value, 23001 = restrict_violation,
-- 23514 = check_violation, 02000/P0002 = no_data_found.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(34);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('knowledge', 'monograph_answers', 'knowledge.monograph_answers finnes');
select has_table('knowledge', 'monograph_answer_revisions',
                 'knowledge.monograph_answer_revisions finnes');
select has_table('workflow', 'monograph_answer_verifications',
                 'workflow.monograph_answer_verifications finnes');

select is_empty(
  $$
    select t.table_name, r.role_name, p.privilege
    from (values ('knowledge.monograph_answers'),
                 ('knowledge.monograph_answer_revisions'),
                 ('knowledge.monograph_answer_revision_sources'),
                 ('workflow.monograph_answer_verifications')) as t(table_name),
         (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, t.table_name, p.privilege)
  $$,
  'ingen klientrolle leser eller skriver svaret direkte'
);

-- Svarrollen kan settes ut. Den deterministiske kontrollen kan det ikke, og
-- det er hele poenget med at den er Antideps egen kode.
select isnt(
  workflow.agent_task_contract('monograph_answer'::provenance.agent_role), null,
  'monografisvarrollen har en ekstern agentkontrakt'
);
select is(
  workflow.agent_task_contract('monograph_answer_verification'::provenance.agent_role), null,
  'den deterministiske svarkontrollen kan ikke settes ut til en modell'
);
select is(
  (select count(*)::integer from provenance.role_model_assignments a
   where a.agent_role = 'monograph_answer_verification' and a.capacity = 'semantic'),
  0,
  'og den har ingen semantisk modelltildeling'
);

-- ===========================================================================
-- Del 2 — Bestillingen, materialet og den godkjente bruken
-- ===========================================================================
insert into auth.users (id, email)
values ('90000000-0000-4000-8000-00000000000a', 'redaktor-900@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values ('ac900000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-900',
        'Redaktør 900', 'Editor uten avgrensning, for 900.',
        '90000000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('90000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
        'ac900000-0000-4000-8000-00000000000a', 'Editor-tildeling for 900.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
grant select, insert on svar to authenticated;
grant select on fixture to authenticated;

insert into fixture (name, id) values ('redaktor', 'ac900000-0000-4000-8000-00000000000a');
insert into fixture (name, id)
select 'owner', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id)
select 'vektendring', id from catalog.clinical_concepts where canonical_label = 'vektendring';

select set_config('request.jwt.claims',
                  '{"sub":"90000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 900.');
reset role;

insert into fixture (name, id)
select 'edition', e.id from knowledge.monograph_editions e
where e.reference = (select payload ->> 'reference' from svar where label = 'bestilling');

insert into fixture (name, id)
select 'preparatbehov', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where n.edition_id = (select id from fixture where name = 'edition') and t.code = 'MN03'
limit 1;

insert into fixture (name, id)
select 'raadbehov', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where n.edition_id = (select id from fixture where name = 'edition')
  and n.answer_form = 'advice'
limit 1;

insert into fixture (name, id)
select 'avledet-behov', n.id
from knowledge.monograph_needs n
where n.edition_id = (select id from fixture where name = 'edition')
  and n.answer_form = 'derived'
limit 1;

-- Et registrert myndighetsdokument, med sin tekst.
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('90000000-0000-4000-8000-000000000001', 'summary_of_product_characteristics',
        'Syntetisk preparatomtale for 900', 'Syntetisk myndighet',
        (select id from fixture where name = 'owner'));

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash,
  representation, retrieved_by_actor_id
)
values ('90000000-0000-4000-8000-000000000021', '90000000-0000-4000-8000-000000000001',
        now(), 'https://example.test/900', 
        knowledge.source_version_content_hash(
          'Sertralin Testmerke tabletter 50 mg. Pakning med 28 tabletter. '
          || 'Anbefalt startdose hos voksne er 50 mg daglig.'),
        'regulatory_summary', (select id from fixture where name = 'owner'));

insert into knowledge.source_version_texts
  (source_version_id, representation, stored_by_actor_id)
values ('90000000-0000-4000-8000-000000000021',
        'Sertralin Testmerke tabletter 50 mg. Pakning med 28 tabletter. '
        || 'Anbefalt startdose hos voksne er 50 mg daglig.',
        (select id from fixture where name = 'owner'));

insert into knowledge.monograph_source_uses
  (need_id, source_version_id, approved_use, scope_digest, approved_by_actor_id)
select n.id, '90000000-0000-4000-8000-000000000021',
       'Oppgir handelsnavn, formulering, styrke og pakningsidentitet.',
       n.scope_digest, (select id from fixture where name = 'redaktor')
from knowledge.monograph_needs n
where n.id = (select id from fixture where name = 'preparatbehov');

-- Den godkjente kildebruken legger svaroppgaven i køen av seg selv.
select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'monograph_answer'
     and j.job_key like 'agent-handoff:'
       || (select id::text from fixture where name = 'preparatbehov') || ':%'),
  1,
  'den godkjente kildebruken legger svaroppgaven i køen'
);
select ok(
  (select exists (select 1 from workflow.agent_handoff_jobs h
                  join workflow.pipeline_jobs j on j.id = h.pipeline_job_id
                  where j.agent_role = 'monograph_answer')),
  'og oppgaven går gjennom den samme eksterne agentkontrakten som resten av kjeden'
);

-- ===========================================================================
-- Del 3 — Kontrollen kjører i skriveveien
-- ===========================================================================
select throws_ok(
  format($$
    select knowledge.record_monograph_answer_revision(
      %L, 'product_data', 'human',
      'Sertralin Testmerke finnes som tabletter 50 mg.', null, null, null,
      null, %L, '2026-09-01', 'Et utdrag som ikke står i dokumentet.', 'Avsnitt 3',
      null, null, null, null, 'Prøve i 900.', %L, null)
  $$,
    (select id from fixture where name = 'preparatbehov'),
    '90000000-0000-4000-8000-000000000021',
    (select id from fixture where name = 'redaktor')),
  '22023', null,
  'et ordrett utdrag som ikke står i den registrerte representasjonen, avvises'
);

select throws_ok(
  format($$
    select knowledge.record_monograph_answer_revision(
      %L, 'product_data', 'human',
      'Sertralin Testmerke finnes som tabletter 50 mg.', null, null, null,
      null, %L, '2099-01-01', 'Pakning med 28 tabletter.', 'Avsnitt 3',
      null, null, null, null, 'Prøve i 900.', %L, null)
  $$,
    (select id from fixture where name = 'preparatbehov'),
    '90000000-0000-4000-8000-000000000021',
    (select id from fixture where name = 'redaktor')),
  '22023', null,
  'et tidspunkt som ligger fram i tid, avvises'
);

select throws_ok(
  format($$
    select knowledge.record_monograph_answer_revision(
      %L, 'product_data', 'human',
      'Sertralin Testmerke finnes som tabletter 50 mg.', null, null, null,
      null, %L, '2026-09-01', 'Pakning med 28 tabletter.', 'Avsnitt 3',
      null, null, null, null, 'Prøve i 900.', %L, null)
  $$,
    (select id from fixture where name = 'raadbehov'),
    '90000000-0000-4000-8000-000000000021',
    (select id from fixture where name = 'redaktor')),
  '22023', null,
  'en kilde som ikke er godkjent for behovet, kan ikke bære svaret der'
);

select throws_ok(
  format($$
    select knowledge.record_monograph_answer_revision(
      %L, 'research_finding', 'human', 'Et forskningsfunn uten en påstand.',
      null, null, null, null, null, null, null, null, null, null, null, null,
      'Prøve i 900.', %L, null)
  $$,
    (select id from fixture where name = 'preparatbehov'),
    (select id from fixture where name = 'redaktor')),
  '22023', null,
  'et preparatbehov tar ikke imot et forskningsfunn, og kontrollen sier det før kontrakten gjør'
);

-- ===========================================================================
-- Del 4 — Svaret som kan kontrolleres
-- ===========================================================================
insert into fixture (name, id)
select 'revisjon-1', knowledge.record_monograph_answer_revision(
  (select id from fixture where name = 'preparatbehov'),
  'product_data', 'human',
  'Sertralin Testmerke finnes som tabletter 50 mg i pakning med 28 tabletter.',
  jsonb_build_object('strength_mg', 50, 'pack_size', 28),
  'Preparatomtalen oppgir ikke andre pakningsstørrelser.',
  null, null, '90000000-0000-4000-8000-000000000021', '2026-09-01',
  'Pakning med 28 tabletter.', 'Avsnitt 3', null, null, null, null,
  'Prøve i 900: første svar.', (select id from fixture where name = 'redaktor'), null);

select is(
  (select r.knowledge_type::text from knowledge.monograph_answer_revisions r
   where r.id = (select id from fixture where name = 'revisjon-1')),
  'product_data',
  'svaret står med sin kunnskapstype'
);
select is(
  (select a.current_revision_id from knowledge.monograph_answers a
   where a.need_id = (select id from fixture where name = 'preparatbehov')),
  (select id from fixture where name = 'revisjon-1'),
  'og er behovets gjeldende svar'
);
select is(
  (select n.work_state::text || '/' || n.outcome::text from knowledge.monograph_needs n
   where n.id = (select id from fixture where name = 'preparatbehov')),
  'agent_complete/answered',
  'behovet er ferdig behandlet, og utfallet er svarets konklusjon'
);
select is(
  (select v.checked_fields::text[] from workflow.monograph_answer_verifications v
   where v.answer_revision_id = (select id from fixture where name = 'revisjon-1')),
  array['knowledge_type_match', 'source_support', 'source_locator',
        'currency', 'approved_use', 'no_invented_certainty'],
  'og kontrollraden sier hvilke felter som faktisk ble kontrollert'
);
select is(
  (select count(*)::integer from knowledge.evidence_assessments a
   join knowledge.claim_revisions cr on cr.id = a.claim_revision_id
   join knowledge.claims c on c.id = cr.claim_id
   where c.monograph_need_id = (select id from fixture where name = 'preparatbehov')),
  0,
  'en preparatdata får ingen GRADE-vurdering'
);
select is(
  (select count(*)::integer from audit.events e
   where e.operation = 'monograph_answer_revision_created'
     and e.object_id = (select id from fixture where name = 'revisjon-1')),
  1,
  'og revisjonen står i det uforanderlige sporet'
);

-- ===========================================================================
-- Del 5 — Revisjonen bevarer den forrige
-- ===========================================================================
insert into fixture (name, id)
select 'revisjon-2', knowledge.record_monograph_answer_revision(
  (select id from fixture where name = 'preparatbehov'),
  'product_data', 'human',
  'Sertralin Testmerke finnes som tabletter 50 mg; anbefalt startdose hos voksne er 50 mg daglig.',
  jsonb_build_object('strength_mg', 50, 'start_dose_mg', 50),
  null, null, null, '90000000-0000-4000-8000-000000000021', '2026-09-10',
  'Anbefalt startdose hos voksne er 50 mg daglig.', 'Avsnitt 4.2', null, null, null, null,
  'Prøve i 900: preparatomtalen er lest på nytt.',
  (select id from fixture where name = 'redaktor'), null);

select is(
  (select count(*)::integer from knowledge.monograph_answer_revisions r
   join knowledge.monograph_answers a on a.id = r.answer_id
   where a.need_id = (select id from fixture where name = 'preparatbehov')),
  2,
  'den forrige revisjonen blir stående'
);
select is(
  (select r.supersedes_revision_id from knowledge.monograph_answer_revisions r
   where r.id = (select id from fixture where name = 'revisjon-2')),
  (select id from fixture where name = 'revisjon-1'),
  'og den nye sier hvilken den avløste'
);
select is(
  (select a.current_revision_id from knowledge.monograph_answers a
   where a.need_id = (select id from fixture where name = 'preparatbehov')),
  (select id from fixture where name = 'revisjon-2'),
  'mens den nye er den gjeldende'
);
select throws_ok(
  format($$ update knowledge.monograph_answer_revisions
            set statement = 'noe annet' where id = %L $$,
         (select id from fixture where name = 'revisjon-1')),
  '23001', null,
  'en revisjon skrives ikke om i ettertid'
);

-- ===========================================================================
-- Del 6 — Det avledede svaret
-- ===========================================================================
select throws_ok(
  format($$
    select knowledge.record_monograph_answer_revision(
      %L, 'derived', 'human', 'En avledet oppsummering.', null, null, null,
      null, null, null, null, null, null, null,
      array[%L]::uuid[], null, 'Prøve i 900.', %L, null)
  $$,
    (select id from fixture where name = 'avledet-behov'),
    (select id from fixture where name = 'revisjon-1'),
    (select id from fixture where name = 'redaktor')),
  '22023', null,
  'et avledet svar kan ikke hvile på en avløst revisjon'
);

insert into fixture (name, id)
select 'avledet', knowledge.record_monograph_answer_revision(
  (select id from fixture where name = 'avledet-behov'),
  'derived', 'derived',
  'Sertralin Testmerke: 50 mg tabletter, startdose 50 mg daglig.',
  null, null, null, null, null, null, null, null, null, null,
  array[(select id from fixture where name = 'revisjon-2')]::uuid[],
  null, 'Prøve i 900: avledet av det kontrollerte svaret.',
  (select id from fixture where name = 'redaktor'), null);

select is(
  (select r.derived_from_revision_ids from knowledge.monograph_answer_revisions r
   where r.id = (select id from fixture where name = 'avledet')),
  array[(select id from fixture where name = 'revisjon-2')],
  'et avledet svar hviler på gjeldende svar i den samme utgaven'
);
select is(
  (select r.source_version_id from knowledge.monograph_answer_revisions r
   where r.id = (select id from fixture where name = 'avledet')),
  null,
  'og har ingen egen kilde: det legger ikke til ny kunnskap'
);
select is(
  (select v.checked_fields::text[] from workflow.monograph_answer_verifications v
   where v.answer_revision_id = (select id from fixture where name = 'avledet')),
  array['knowledge_type_match', 'derivation_basis', 'no_invented_certainty'],
  'kontrollen av et avledet svar er en annen kontroll, og den sier det'
);

-- ===========================================================================
-- Del 7 — Materialet avgjør kunnskapstypen
-- ===========================================================================
insert into fixture (name, id)
select 'forskningsbehov', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where n.edition_id = (select id from fixture where name = 'edition')
  and t.code = 'MN29'
limit 1;

select is(
  workflow.monograph_answer_problem(
    (select id from fixture where name = 'forskningsbehov'),
    'product_data'::knowledge.monograph_knowledge_type,
    null, '90000000-0000-4000-8000-000000000021', '2026-09-01',
    'Pakning med 28 tabletter.', 'Avsnitt 3', null)
    like '%forskningsfunn%',
  true,
  'et forskningsbehov tar ikke imot en preparatdata'
);
select ok(
  workflow.monograph_answer_problem(
    (select id from fixture where name = 'preparatbehov'),
    'research_finding'::knowledge.monograph_knowledge_type,
    null, null, null, null, null, null) is not null,
  'og et preparatbehov tar ikke imot et forskningsfunn'
);

-- Et behov som er avgjort som ikke relevant, får ikke et svar som motsier
-- avgjørelsen.
update knowledge.monograph_needs n
set relevance = 'not_applicable',
    relevance_reason = 'Prøve i 900: ikke relevant for dette virkestoffet.',
    relevance_decided_by_actor_id = (select id from fixture where name = 'redaktor'),
    relevance_decided_at = now()
where n.id = (select id from fixture where name = 'raadbehov');

select ok(
  workflow.monograph_answer_problem(
    (select id from fixture where name = 'raadbehov'),
    'attributed_advice'::knowledge.monograph_knowledge_type,
    null, '90000000-0000-4000-8000-000000000021', '2026-09-01',
    'Pakning med 28 tabletter.', 'Avsnitt 3', null) is not null,
  'et behov som er avgjort som ikke relevant, får ikke et svar som motsier avgjørelsen'
);

-- ===========================================================================
-- Del 8 — Forskningssvaret krever hele kjeden
-- ===========================================================================
-- Fiksturets påstand er ikke monografiavgrenset, så overgangen gjør ingenting.
select is(
  workflow.chain_answer_for_assessment('f2000000-0000-4000-8000-000000000031'),
  null,
  'en artikkelbasert påstand blir ikke et monografisvar av seg selv'
);

select ok(
  workflow.monograph_answer_problem(
    (select id from fixture where name = 'forskningsbehov'),
    'research_finding'::knowledge.monograph_knowledge_type,
    'f2000000-0000-4000-8000-000000000031'::uuid,
    null, null, null, null, null) is not null,
  'og en påstand som ikke svarer på behovet, kan ikke bli svaret der'
);

-- ===========================================================================
-- Del 9 — Svaragenten skriver ikke et forskningsfunn
-- ===========================================================================
select is(
  (select count(*)::integer from provenance.actors a
   where a.actor_key in ('agent:monograph-answer', 'agent:monograph-answer-verification')),
  2,
  'begge svarleddene har sin egen aktør'
);
select is(
  (select count(*)::integer from provenance.agent_identities i
   where i.identity_key in ('agent-identity:monograph-answer-01',
                            'agent-identity:monograph-answer-verification-01')
     and i.secret_hash is null),
  2,
  'og begge identitetene er inerte til legitimasjonen utstedes'
);

select * from finish();
rollback;
