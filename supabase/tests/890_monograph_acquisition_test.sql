-- Migrasjon 013h — fra valgt kilde til materiale i hus.
--
-- Filen dekker at en valgt kilde faktisk blir ført videre, uten et
-- godkjenningsklikk per artikkel:
--
--   * kilden opprettes fra kandidatens egen identifikator, og den samme
--     identifikatoren to ganger blir én kilde,
--   * det private kildebiblioteket spørres først: finnes dokumentet, blir den
--     godkjente kildebruken ført opp og ingen blir spurt,
--   * finnes det ikke, blir det én åpen forespørsel med artikkelidentitet og
--     faglig grunn — og avgrensningen er unionen av behovene,
--   * et nytt behov på en kilde som alt er valgt, utvider den åpne
--     forespørselen framfor å bli avvist,
--   * en betalingsmur er en tilgangsbegrensning: kandidaten blir stående valgt,
--     og begrensningen står i forespørselen,
--   * forskningsfulltekst og myndighetsdokument går hver sin vei, med hver sin
--     kontrakt, og en PDF avvises fra myndighetsveien,
--   * et myndighetsdokument får kilde- og aktualitetskontroll uten en
--     GRADE-vurdering og uten en evidensrad,
--   * et behov uten endepunkt og en kandidat uten identifikator blir synlige
--     avklaringer og ikke stille stopp,
--   * rekonsilieringen tar opp igjen en innhenting som ikke ble fullført, og
--     lager ingen duplikater, og
--   * ingen klientrolle kommer til radene eller originalfilen direkte.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 02000/P0002 = no_data_found.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(51);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('knowledge', 'authority_documents',
                 'knowledge.authority_documents finnes');
select has_table('workflow', 'monograph_document_requests',
                 'workflow.monograph_document_requests finnes');
select has_function('knowledge', 'monograph_need_material_kind',
                    'knowledge.monograph_need_material_kind(uuid) finnes');
select has_function('workflow', 'acquire_monograph_candidate',
                    'workflow.acquire_monograph_candidate(uuid) finnes');

-- Originalfilen har ingen leserett og ingen leseregel. Bytene forlater
-- databasen bare gjennom en kontrollert funksjon.
select is_empty(
  $$
    select r.role_name, p.privilege
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, 'knowledge.authority_documents', p.privilege)
  $$,
  'ingen klientrolle kommer til originalfilen til et myndighetsdokument'
);
select is_empty(
  $$
    select 1 from pg_policy p
    join pg_class c on c.oid = p.polrelid
    where c.relname = 'authority_documents'
  $$,
  'og det finnes ingen leseregel som ville sett ut som en tilgang'
);
select is_empty(
  $$
    select r.role_name, p.privilege
    from (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, 'workflow.monograph_document_requests', p.privilege)
  $$,
  'og ingen klientrolle leser eller skriver forespørselen direkte'
);

-- ===========================================================================
-- Del 2 — Kontoene og bestillingen
-- ===========================================================================
insert into auth.users (id, email)
values
  ('89000000-0000-4000-8000-00000000000a', 'redaktor-890@test.invalid'),
  ('89000000-0000-4000-8000-00000000000b', 'kliniker-890@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac890000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-890',
   'Redaktør 890', 'Editor uten avgrensning, for 890.',
   '89000000-0000-4000-8000-00000000000a'),
  ('ac890000-0000-4000-8000-00000000000b', 'human', 'human:kliniker-890',
   'Kliniker 890', 'Uten noen rolle, for 890.',
   '89000000-0000-4000-8000-00000000000b');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('89000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
        'ac890000-0000-4000-8000-00000000000a', 'Editor-tildeling for 890.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
create temporary table ref (name text primary key, value text not null) on commit drop;
grant select, insert on svar to authenticated;
grant select, insert on svar to anon;
grant select on fixture to authenticated;
grant select on ref to authenticated;

insert into fixture (name, id)
select 'sertralin', id from catalog.drugs where canonical_name = 'sertralin';
insert into fixture (name, id)
select 'vektendring', id from catalog.clinical_concepts where canonical_label = 'vektendring';
insert into fixture (name, id)
select 'owner', id from provenance.actors where actor_key = 'human:peder-holman';
insert into fixture (name, id)
select 'extractor', pg_temp.extraction_actor_id();
insert into fixture (name, id) values ('redaktor', 'ac890000-0000-4000-8000-00000000000a');

select set_config('request.jwt.claims',
                  '{"sub":"89000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 890.');
insert into svar (label, payload)
select 'utfall', api.propose_monograph_term(
  (select payload ->> 'reference' from svar where label = 'bestilling'),
  'outcome', 'vektendring', 'Prøve i 890: et dokumentert delutfall.');
insert into svar (label, payload)
select 'utfall-akseptert', api.decide_monograph_term(
  (select payload ->> 'reference' from svar where label = 'utfall'), true, null);
reset role;

insert into fixture (name, id)
select 'edition', e.id from knowledge.monograph_editions e
where e.reference = (select payload ->> 'reference' from svar where label = 'bestilling');

-- Et forskningsbehov med et navngitt endepunkt, og et myndighetsbehov.
insert into fixture (name, id)
select 'forskningsbehov', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where n.edition_id = (select id from fixture where name = 'edition')
  and t.code = 'MN29'
  and n.outcome_concept_id = (select id from fixture where name = 'vektendring')
limit 1;

insert into fixture (name, id)
select 'forskningsbehov-uten-utfall', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where n.edition_id = (select id from fixture where name = 'edition')
  and t.code = 'MN29'
  and n.outcome_concept_id is null
limit 1;

insert into fixture (name, id)
select 'preparatbehov', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where n.edition_id = (select id from fixture where name = 'edition')
  and t.code = 'MN03'
limit 1;

select is(
  knowledge.monograph_need_material_kind(
    (select id from fixture where name = 'forskningsbehov'))::text,
  'research_full_text',
  'et behov som ber om en profil, hviler på forskningsfulltekst'
);
select is(
  knowledge.monograph_need_material_kind(
    (select id from fixture where name = 'preparatbehov'))::text,
  'authority_document',
  'og et behov som ber om en tabell over norske produkter, på et preparatdokument'
);
select is(
  (select knowledge.monograph_need_material_kind(n.id)::text
   from knowledge.monograph_needs n
   where n.edition_id = (select id from fixture where name = 'edition')
     and n.answer_form = 'derived'
   limit 1),
  'derived',
  'et avledet svar trenger ingen ny kilde'
);

-- ===========================================================================
-- Del 3 — En valgt forskningskilde som ikke finnes i biblioteket
-- ===========================================================================
insert into fixture (name, id)
select 'forskningsplan', p.id
from workflow.monograph_search_plans p
join workflow.monograph_search_plan_needs pn on pn.plan_id = p.id
where pn.need_id = (select id from fixture where name = 'forskningsbehov')
limit 1;

insert into fixture (name, id)
select 'kandidat-1', workflow.record_monograph_candidate_source(
  (select id from fixture where name = 'forskningsplan'), null,
  'doi', '10.1000/PROVE.890.1', 'Vektendring under sertralin: en randomisert studie',
  'Testforfatter 890', 'Journal of Synthetic Trials', 2024,
  'Europe PMC, søk i prøve 890', false, null, true,
  'Rapporterer vektendring i kg og kan endre konklusjonen.',
  null, (select id from fixture where name = 'redaktor'));

insert into workflow.monograph_candidate_source_needs
  (candidate_source_id, need_id, proposed_use)
values ((select id from fixture where name = 'kandidat-1'),
        (select id from fixture where name = 'forskningsbehov'),
        'Rapporterer vektendring i kg og andel med klinisk definert vektøkning.');

insert into ref (name, value)
select 'kandidat-1', c.reference from workflow.monograph_candidate_sources c
where c.id = (select id from fixture where name = 'kandidat-1');
insert into ref (name, value)
select 'bestilling', payload ->> 'reference' from svar where label = 'bestilling';

select set_config('request.jwt.claims',
                  '{"sub":"89000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'valg-1', api.decide_monograph_candidate(
  (select value from ref where name = 'kandidat-1'), 'selected_for_retrieval',
  'Prøve i 890: kilden rapporterer utfallet behovet spør om.');
reset role;

select is(
  (select count(*)::integer from knowledge.source_identifiers i
   where i.identifier_system = 'doi' and i.identifier_value = '10.1000/prove.890.1'),
  1,
  'kilden opprettes fra kandidatens egen identifikator, normalisert'
);
select isnt(
  (select c.source_id from workflow.monograph_candidate_sources c
   where c.id = (select id from fixture where name = 'kandidat-1')),
  null,
  'og kandidaten peker på kilderaden etterpå'
);
select is(
  (select s.source_type::text from knowledge.sources s
   join workflow.monograph_candidate_sources c on c.source_id = s.id
   where c.id = (select id from fixture where name = 'kandidat-1')),
  'journal_article',
  'kildetypen følger kildeprofilen søket ble kjørt under'
);

select is(
  (select count(*)::integer from workflow.full_text_requests r
   join workflow.monograph_candidate_sources c on c.source_id = r.source_id
   where c.id = (select id from fixture where name = 'kandidat-1') and r.state = 'open'),
  1,
  'og fullteksten er etterspurt, uten et godkjenningsklikk per artikkel'
);
select is(
  (select r.outcome_concept_ids from workflow.full_text_requests r
   join workflow.monograph_candidate_sources c on c.source_id = r.source_id
   where c.id = (select id from fixture where name = 'kandidat-1') and r.state = 'open'),
  array[(select id from fixture where name = 'vektendring')],
  'avgrensningen er endepunktet behovet spør om'
);
select is(
  (select n.work_state::text from knowledge.monograph_needs n
   where n.id = (select id from fixture where name = 'forskningsbehov')),
  'awaiting_access',
  'behovet venter på tilgang, og ikke på en konklusjon om evidensen'
);
select is(
  (select n.outcome from knowledge.monograph_needs n
   where n.id = (select id from fixture where name = 'forskningsbehov')),
  null,
  'manglende tilgang er ikke et faglig utfall'
);

-- ===========================================================================
-- Del 4 — Et nytt behov utvider den åpne forespørselen
-- ===========================================================================
insert into fixture (name, id)
select 'annet-forskningsbehov', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where n.edition_id = (select id from fixture where name = 'edition')
  and t.code = 'MN35'
  and n.outcome_concept_id = (select id from fixture where name = 'vektendring')
limit 1;

insert into workflow.monograph_candidate_source_needs
  (candidate_source_id, need_id, proposed_use)
values ((select id from fixture where name = 'kandidat-1'),
        (select id from fixture where name = 'annet-forskningsbehov'),
        'Rapporterer også andre plagsomme bivirkninger.');

select is(
  (select count(*)::integer from workflow.full_text_requests r
   join workflow.monograph_candidate_sources c on c.source_id = r.source_id
   where c.id = (select id from fixture where name = 'kandidat-1') and r.state = 'open'),
  1,
  'et nytt behov gir ikke en andre forespørsel om den samme artikkelen'
);
select is(
  (select n.work_state::text from knowledge.monograph_needs n
   where n.id = (select id from fixture where name = 'annet-forskningsbehov')),
  'awaiting_access',
  'men det nye behovet venter på det samme dokumentet'
);

-- ===========================================================================
-- Del 5 — Det private kildebiblioteket først
-- ===========================================================================
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values ('89000000-0000-4000-8000-000000000001', 'journal_article',
        'En artikkel Antidep alt har', 'Testforfatter 890',
        (select id from fixture where name = 'owner'));

insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
values ('89000000-0000-4000-8000-000000000001', 'doi', '10.1000/prove.890.2');

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, external_version, content_hash,
  storage_reference, representation, retrieved_by_actor_id, document_sha256,
  document_byte_size, document_media_type, text_extraction_tool,
  text_extraction_tool_version, text_extraction_arguments, text_extraction_transform
)
values (
  '89000000-0000-4000-8000-000000000021', '89000000-0000-4000-8000-000000000001',
  now(), 'https://doi.org/10.1000/prove.890.2', 'synthetic-890',
  knowledge.source_version_content_hash('Syntetisk kildetekst for prøve 890.'),
  'private://890.pdf', 'full_text', (select id from fixture where name = 'extractor'),
  pg_temp.synthetic_pdf_digest('89000000-0000-4000-8000-000000000021'),
  octet_length(pg_temp.synthetic_pdf('89000000-0000-4000-8000-000000000021')),
  'application/pdf', 'pdftotext', '24.02.0',
  '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2');

insert into fixture (name, id)
select 'kandidat-2', workflow.record_monograph_candidate_source(
  (select id from fixture where name = 'forskningsplan'), null,
  'doi', 'https://doi.org/10.1000/PROVE.890.2', 'En artikkel Antidep alt har',
  'Testforfatter 890', 'Journal of Synthetic Trials', 2023,
  'Europe PMC, søk i prøve 890', false, null, false, null,
  null, (select id from fixture where name = 'redaktor'));

insert into workflow.monograph_candidate_source_needs
  (candidate_source_id, need_id, proposed_use)
values ((select id from fixture where name = 'kandidat-2'),
        (select id from fixture where name = 'forskningsbehov'),
        'Rapporterer vektendring over 24 uker.');

insert into ref (name, value)
select 'kandidat-2', c.reference from workflow.monograph_candidate_sources c
where c.id = (select id from fixture where name = 'kandidat-2');

select set_config('request.jwt.claims',
                  '{"sub":"89000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'valg-2', api.decide_monograph_candidate(
  (select value from ref where name = 'kandidat-2'), 'included',
  'Prøve i 890: kilden er inkludert.');
reset role;

select is(
  (select c.source_id from workflow.monograph_candidate_sources c
   where c.id = (select id from fixture where name = 'kandidat-2')),
  '89000000-0000-4000-8000-000000000001'::uuid,
  'den samme DOI-en skrevet som en lenke er den samme kilden, og ikke en ny'
);
select is(
  (select count(*)::integer from workflow.full_text_requests r
   where r.source_id = '89000000-0000-4000-8000-000000000001' and r.state = 'open'),
  0,
  'et dokument Antidep alt har, blir ikke etterspurt på nytt'
);
select is(
  (select count(*)::integer from knowledge.monograph_source_uses u
   where u.source_version_id = '89000000-0000-4000-8000-000000000021'
     and u.need_id = (select id from fixture where name = 'forskningsbehov')),
  1,
  'og den godkjente kildebruken føres opp i det samme kallet'
);
select is(
  (select u.approved_use from knowledge.monograph_source_uses u
   where u.source_version_id = '89000000-0000-4000-8000-000000000021'
     and u.need_id = (select id from fixture where name = 'forskningsbehov')),
  'Rapporterer vektendring over 24 uker.',
  'med nøyaktig det kilden er foreslått brukt til i dette behovet'
);

-- ===========================================================================
-- Del 6 — Myndighetsveien
-- ===========================================================================
insert into fixture (name, id)
select 'preparatplan', p.id
from workflow.monograph_search_plans p
join workflow.monograph_search_plan_needs pn on pn.plan_id = p.id
where pn.need_id = (select id from fixture where name = 'preparatbehov')
limit 1;

insert into fixture (name, id)
select 'kandidat-3', workflow.record_monograph_candidate_source(
  (select id from fixture where name = 'preparatplan'), null,
  'url', 'https://www.legemiddelsok.no/prove-890', 'Preparatomtale for sertralin',
  'Direktoratet for medisinske produkter', 'Legemiddelsøk', 2026,
  'Legemiddelsøk, oppslag i prøve 890', false, null, false, null,
  null, (select id from fixture where name = 'redaktor'));

insert into workflow.monograph_candidate_source_needs
  (candidate_source_id, need_id, proposed_use)
values ((select id from fixture where name = 'kandidat-3'),
        (select id from fixture where name = 'preparatbehov'),
        'Oppgir handelsnavn, formulering, styrke og pakningsidentitet for norske produkter.');

insert into ref (name, value)
select 'kandidat-3', c.reference from workflow.monograph_candidate_sources c
where c.id = (select id from fixture where name = 'kandidat-3');

select set_config('request.jwt.claims',
                  '{"sub":"89000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'valg-3', api.decide_monograph_candidate(
  (select value from ref where name = 'kandidat-3'), 'selected_for_retrieval',
  'Prøve i 890: preparatomtalen er kilden for norske produkter.');
reset role;

select is(
  (select s.source_type::text from knowledge.sources s
   join workflow.monograph_candidate_sources c on c.source_id = s.id
   where c.id = (select id from fixture where name = 'kandidat-3')),
  'summary_of_product_characteristics',
  'et treff funnet under preparatprofilen registreres som en preparatomtale'
);
select is(
  (select count(*)::integer from workflow.monograph_document_requests r
   join workflow.monograph_candidate_sources c on c.source_id = r.source_id
   where c.id = (select id from fixture where name = 'kandidat-3') and r.state = 'open'),
  1,
  'og dokumentet etterspørres gjennom myndighetsveien'
);
select is(
  (select r.required_representation::text from workflow.monograph_document_requests r
   join workflow.monograph_candidate_sources c on c.source_id = r.source_id
   where c.id = (select id from fixture where name = 'kandidat-3') and r.state = 'open'),
  'regulatory_summary',
  'representasjonen er myndighetens eget sammendrag, og ikke en oppdiktet fulltekst'
);
select is(
  (select count(*)::integer from workflow.full_text_requests r
   join workflow.monograph_candidate_sources c on c.source_id = r.source_id
   where c.id = (select id from fixture where name = 'kandidat-3')),
  0,
  'en preparatomtale presses ikke inn i den forskningsfaglige kontrakten'
);
select ok(
  (select r.professional_reason like '%MN03%'
   from workflow.monograph_document_requests r
   join workflow.monograph_candidate_sources c on c.source_id = r.source_id
   where c.id = (select id from fixture where name = 'kandidat-3') and r.state = 'open'),
  'forespørselen bærer den faglige grunnen, med malen den gjelder'
);

insert into ref (name, value)
select 'dokumentforespørsel', r.reference
from workflow.monograph_document_requests r
join workflow.monograph_candidate_sources c on c.source_id = r.source_id
where c.id = (select id from fixture where name = 'kandidat-3') and r.state = 'open';

-- En PDF hører til den andre veien.
select set_config('request.jwt.claims',
                  '{"sub":"89000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format(
    $$ select api.submit_monograph_document(%L, %L, 'text/html', %L, 'antidep-html-text@1') $$,
    (select value from ref where name = 'dokumentforespørsel'),
    encode(convert_to('%PDF-1.7' || chr(10) || 'ikke her' || chr(10) || '%%EOF', 'UTF8'), 'base64'),
    repeat('Sertralin Orifarm tabletter 50 mg. ', 20)),
  '22023',
  null,
  'en PDF avvises fra myndighetsveien: PDF-veien har sin egen kontroll'
);

select throws_ok(
  format(
    $$ select api.submit_monograph_document(%L, %L, 'text/html', 'for kort', 'antidep-html-text@1') $$,
    (select value from ref where name = 'dokumentforespørsel'),
    encode(convert_to('<html><body>Sertralin</body></html>', 'UTF8'), 'base64')),
  '22023',
  null,
  'og en tekst som er for kort til å være dokumentet, avvises'
);

insert into svar (label, payload)
select 'dokument', api.submit_monograph_document(
  (select value from ref where name = 'dokumentforespørsel'),
  encode(convert_to(
    '<html><body>' || repeat('<p>Sertralin Orifarm tabletter 50 mg.</p>', 20)
    || '</body></html>', 'UTF8'), 'base64'),
  'text/html',
  repeat('Sertralin Orifarm tabletter 50 mg. ', 20),
  'antidep-html-text@1',
  'https://www.legemiddelsok.no/prove-890');
reset role;

select is(
  (select (payload -> 'registered')::boolean from svar where label = 'dokument'),
  true,
  'dokumentet registreres med sitt eget fingeravtrykk'
);
select is(
  (select count(*)::integer from workflow.monograph_document_requests r
   where r.reference = (select value from ref where name = 'dokumentforespørsel')
     and r.state = 'fulfilled'),
  1,
  'og forespørselen lukkes av registreringen'
);
select is(
  (select count(*)::integer from knowledge.monograph_source_uses u
   where u.need_id = (select id from fixture where name = 'preparatbehov')),
  1,
  'behovet får sin godkjente kildebruk'
);
select is(
  (select n.work_state::text from knowledge.monograph_needs n
   where n.id = (select id from fixture where name = 'preparatbehov')),
  'extracting',
  'og går videre av seg selv'
);
select is(
  (select count(*)::integer from knowledge.evidence_assessments a
   join knowledge.claim_revisions cr on cr.id = a.claim_revision_id
   join knowledge.claims c on c.id = cr.claim_id
   where c.monograph_need_id = (select id from fixture where name = 'preparatbehov')),
  0,
  'et myndighetsdokument gir ingen GRADE-vurdering og ingen forskningssyntese'
);
select is(
  (select ad.media_type from knowledge.authority_documents ad
   join knowledge.source_versions sv on sv.id = ad.source_version_id
   where sv.source_id = (select c.source_id from workflow.monograph_candidate_sources c
                         where c.id = (select id from fixture where name = 'kandidat-3'))),
  'text/html',
  'originalfilen er lagret som det den er, og ikke omgjort til en PDF for å passere en kontroll'
);
select ok(
  (select length(knowledge.source_version_text(sv.id)) > 200
   from knowledge.source_versions sv
   join knowledge.authority_documents ad on ad.source_version_id = sv.id
   where sv.representation = 'regulatory_summary'),
  'og teksten et ordrett utdrag senere kontrolleres mot, er registrert'
);

-- Den registrerte myndighetsfullteksten kan ikke bære et klinisk evidensfunn.
-- Forskningsporten står der den sto.
select throws_ok(
  format(
    $$ select knowledge.assert_clinical_full_text(%L, %L) $$,
    (select sv.source_id from knowledge.source_versions sv
     join knowledge.authority_documents ad on ad.source_version_id = sv.id limit 1),
    (select sv.id from knowledge.source_versions sv
     join knowledge.authority_documents ad on ad.source_version_id = sv.id limit 1)),
  '23001',
  null,
  'et myndighetsdokument kan ikke bære et klinisk evidensfunn: PDF-kravet står urørt'
);

-- ===========================================================================
-- Del 7 — Betalingsmuren, avklaringene og de synlige tilstandene
-- ===========================================================================
insert into fixture (name, id)
select 'kandidat-4', workflow.record_monograph_candidate_source(
  (select id from fixture where name = 'forskningsplan'), null,
  'doi', '10.1000/prove.890.4', 'En artikkel bak en betalingsmur',
  'Testforfatter 890', 'Journal of Synthetic Trials', 2025,
  'Europe PMC, søk i prøve 890', true,
  'Utgiveren krever abonnement, og ingen autorisert tilgang er registrert.',
  true, 'Rapporterer det samme utfallet, og kan endre konklusjonen.',
  null, (select id from fixture where name = 'redaktor'));

insert into workflow.monograph_candidate_source_needs
  (candidate_source_id, need_id, proposed_use)
values ((select id from fixture where name = 'kandidat-4'),
        (select id from fixture where name = 'forskningsbehov'),
        'Rapporterer vektendring i en annen populasjon.');

insert into ref (name, value)
select 'kandidat-4', c.reference from workflow.monograph_candidate_sources c
where c.id = (select id from fixture where name = 'kandidat-4');

select set_config('request.jwt.claims',
                  '{"sub":"89000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.decide_monograph_candidate(%L, 'excluded', 'Bak betalingsmur.') $$,
         (select value from ref where name = 'kandidat-4')),
  '22023',
  null,
  'en betalingsmur er ikke en faglig eksklusjonsgrunn'
);
insert into svar (label, payload)
select 'valg-4', api.decide_monograph_candidate(
  (select value from ref where name = 'kandidat-4'), 'selected_for_retrieval',
  'Prøve i 890: kilden er valgt, tilgangen er begrenset.');
insert into svar (label, payload)
select 'forespørsler', api.monograph_source_requests(
  (select value from ref where name = 'bestilling'));
reset role;

select ok(
  (select payload -> 'research_full_text' @> jsonb_build_array(jsonb_build_object(
            'kind', 'research_full_text'))
   from svar where label = 'forespørsler') is not false,
  'den samlede listen viser forskningsforespørslene'
);
select ok(
  (select exists (
     select 1 from jsonb_array_elements(payload -> 'research_full_text') as e(v)
     where e.v ->> 'access_limitation' is not null)
   from svar where label = 'forespørsler'),
  'og tilgangsbegrensningen står i den, som en begrensning og ikke en konklusjon'
);
select ok(
  (select jsonb_array_length(payload -> 'authority_documents') = 0
   from svar where label = 'forespørsler'),
  'myndighetsforespørselen er borte fra listen når dokumentet er registrert'
);
select is_empty(
  $$
    select e.v
    from svar s, jsonb_array_elements(s.payload -> 'research_full_text') as e(v)
    where s.label = 'forespørsler'
      and (e.v ? 'source_id' or e.v ? 'need_id' or e.v ? 'source_version_id')
  $$,
  'listen bærer ingen interne identifikatorer: teknisk registrering er ikke klinikerens arbeid'
);

-- Et forskningsbehov uten et navngitt endepunkt kan ikke bære et funn.
insert into workflow.monograph_candidate_source_needs
  (candidate_source_id, need_id, proposed_use)
values ((select id from fixture where name = 'kandidat-1'),
        (select id from fixture where name = 'forskningsbehov-uten-utfall'),
        'Kan være relevant for spørsmålet som helhet.');

select is(
  (select n.work_state::text from knowledge.monograph_needs n
   where n.id = (select id from fixture where name = 'forskningsbehov-uten-utfall')),
  'awaiting_clarification',
  'et forskningsbehov uten endepunkt blir en synlig avklaring, ikke et stille stopp'
);
select ok(
  (select n.work_state_note like '%endepunkt%' from knowledge.monograph_needs n
   where n.id = (select id from fixture where name = 'forskningsbehov-uten-utfall')),
  'og notatet sier hva som mangler'
);

-- En kandidat som bare er identifisert med en tittel, kan ikke bli en kilde.
insert into fixture (name, id)
select 'kandidat-5', workflow.record_monograph_candidate_source(
  (select id from fixture where name = 'forskningsplan'), null,
  'title', 'En artikkel uten identifikator', 'En artikkel uten identifikator',
  null, null, null, 'Nevnt i referanselisten til en annen artikkel',
  false, null, false, null,
  null, (select id from fixture where name = 'redaktor'));

insert into workflow.monograph_candidate_source_needs
  (candidate_source_id, need_id, proposed_use)
values ((select id from fixture where name = 'kandidat-5'),
        (select id from fixture where name = 'annet-forskningsbehov'),
        'Kan rapportere et av delutfallene.');

insert into ref (name, value)
select 'kandidat-5', c.reference from workflow.monograph_candidate_sources c
where c.id = (select id from fixture where name = 'kandidat-5');

select set_config('request.jwt.claims',
                  '{"sub":"89000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'valg-5', api.decide_monograph_candidate(
  (select value from ref where name = 'kandidat-5'), 'selected_for_retrieval',
  'Prøve i 890: kilden er valgt, identiteten mangler.');
reset role;

select is(
  (select c.source_id from workflow.monograph_candidate_sources c
   where c.id = (select id from fixture where name = 'kandidat-5')),
  null,
  'en tittel er ikke en identitet, og det opprettes ingen kilde av den'
);
select is(
  (select n.work_state::text from knowledge.monograph_needs n
   where n.id = (select id from fixture where name = 'annet-forskningsbehov')),
  'awaiting_clarification',
  'behovet sier at identiteten mangler, framfor å stoppe stille'
);

-- ===========================================================================
-- Del 8 — Rekonsilieringen lager ingen duplikater
-- ===========================================================================
create temporary table cred_890 (name text primary key, secret text not null)
  on commit drop;
grant select on cred_890 to anon;
insert into cred_890
select 'verifier', provenance.issue_agent_identity_credential(
  'agent-identity:extraction-verification-01', 'human:peder-holman');

select set_config('request.jwt.claims', null, true);
set local role anon;
insert into svar (label, payload)
select 'feiing', api.resume_chain_transitions(
  'agent-identity:extraction-verification-01',
  (select secret from cred_890 where name = 'verifier'));
reset role;

select ok(
  (select payload ? 'acquisitions' from svar where label = 'feiing'),
  'rekonsilieringen fører innhentingen som sitt eget ledd'
);
select is(
  (select count(*)::integer from workflow.full_text_requests r
   join workflow.monograph_candidate_sources c on c.source_id = r.source_id
   where c.edition_id = (select id from fixture where name = 'edition')
     and r.state = 'open'),
  2,
  'og den lager ingen andre forespørsel om en artikkel som alt er etterspurt'
);

-- ===========================================================================
-- Del 9 — Mandatet
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"89000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.monograph_source_requests(%L) $$,
         (select value from ref where name = 'bestilling')),
  '42501',
  null,
  'en kliniker uten redaktørmandat ser ikke forespørselslisten'
);
select throws_ok(
  $$ select api.submit_monograph_document('00000000000000000000000000000000',
       'AAAA', 'text/html', 'x', 'antidep-html-text@1') $$,
  '42501',
  null,
  'og kan ikke registrere et myndighetsdokument'
);
reset role;

select * from finish();
rollback;
