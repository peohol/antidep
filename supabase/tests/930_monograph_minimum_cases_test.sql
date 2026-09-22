-- Minimumskravene fase C ba om, som ikke var dekket andre steder.
--
-- De øvrige 930-filene dekker hvert sitt lag. Denne dekker fire krav som faller
-- mellom dem, og som hver for seg ville vært en reell mangel:
--
--   * **Attribuert råd og farmakologisk resonnement.** De fire andre
--     kunnskapstypene er prøvd i 900. Disse to var det ikke, og de er nettopp
--     de to som ikke bærer et forskningsestimat: et råd er attribuert til en
--     navngitt instans med en dato, og et resonnement hviler på andre
--     kontrollerte svar. Ingen av dem skal få en GRADE-vurdering.
--   * **Ett behov, flere kilder.** At én kilde dekker flere behov, er prøvd i
--     890. Det motsatte var ikke: at ett behov kan hvile på flere kilder, og at
--     dekningen likevel teller behovet én gang.
--   * **Rekonsiliering av monografileddene.** 890 prøver innhentingen. Søke-
--     oppdagelsen og monografisvaret var ikke prøvd: en avbrutt overgang der
--     ville etterlatt arbeid ingen tok opp igjen.
--
-- SQLSTATE 22023 = invalid_parameter_value, 23514 = check_violation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(23);

-- ===========================================================================
-- Del 1 — Bestillingen
-- ===========================================================================
insert into auth.users (id, email)
values ('93000000-0000-4000-8000-00000000000a', 'redaktor-930@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values ('ac930000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-930',
        'Redaktør 930', 'Editor uten avgrensning, for 930.',
        '93000000-0000-4000-8000-00000000000a');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values ('93000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
        'ac930000-0000-4000-8000-00000000000a', 'Editor-tildeling for 930.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
create temporary table fixture (name text primary key, id uuid not null) on commit drop;
grant select, insert on svar to authenticated;
grant select on fixture to authenticated;

insert into fixture (name, id) values ('redaktor', 'ac930000-0000-4000-8000-00000000000a');
insert into fixture (name, id)
select 'owner', id from provenance.actors where actor_key = 'human:peder-holman';

select set_config('request.jwt.claims',
                  '{"sub":"93000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 930.');
reset role;

insert into fixture (name, id)
select 'edition', e.id from knowledge.monograph_editions e
where e.reference = (select payload ->> 'reference' from svar where label = 'bestilling');

-- Ett behov som ber om et råd, ett som ber om et resonnement, og ett som ber om
-- en tabell over norske produkter.
insert into fixture (name, id)
select 'raadbehov', n.id
from knowledge.monograph_needs n
where n.edition_id = (select id from fixture where name = 'edition')
  and n.answer_form = 'advice'
limit 1;

-- Resonnementet hører til et behov som er avledet presentasjon: kontrakten
-- tillater `reasoning` og `derived` der, og ingen andre steder. Et resonnement
-- er ikke en egen svarform — det er en kunnskapstype for et spørsmål som ikke
-- henter inn nytt materiale (MONOGRAPH_STANDARD.md §3, §5.3).
insert into fixture (name, id)
select 'resonnementbehov', n.id
from knowledge.monograph_needs n
where n.edition_id = (select id from fixture where name = 'edition')
  and n.answer_form = 'derived'
limit 1;

insert into fixture (name, id)
select 'preparatbehov', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where n.edition_id = (select id from fixture where name = 'edition') and t.code = 'MN03'
limit 1;

-- ===========================================================================
-- Del 2 — To registrerte kilder for det samme behovet
--
-- Én retningslinje og én preparatomtale. Begge er godkjent for bruk, og begge
-- har sin egen tekst: kontrollen av et ordrett utdrag leser den registrerte
-- representasjonen, og en kilde uten tekst ville ikke kunnet bære et utdrag.
-- ===========================================================================
insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
values
  ('93000000-0000-4000-8000-000000000001', 'clinical_guideline',
   'Syntetisk retningslinje for 930', 'Syntetisk fagmyndighet',
   (select id from fixture where name = 'owner')),
  ('93000000-0000-4000-8000-000000000002', 'summary_of_product_characteristics',
   'Syntetisk preparatomtale for 930', 'Syntetisk legemiddelmyndighet',
   (select id from fixture where name = 'owner'));

insert into knowledge.source_versions (
  id, source_id, retrieved_at, retrieved_from, content_hash,
  representation, retrieved_by_actor_id
)
values
  ('93000000-0000-4000-8000-000000000021', '93000000-0000-4000-8000-000000000001',
   now(), 'https://example.test/930-retningslinje',
   knowledge.source_version_content_hash(
     'Ved oppstart anbefales laveste effektive dose, med ny vurdering etter to uker. '
     || 'Anbefalingen gjelder voksne i allmennpraksis.'),
   'regulatory_summary', (select id from fixture where name = 'owner')),
  ('93000000-0000-4000-8000-000000000022', '93000000-0000-4000-8000-000000000002',
   now(), 'https://example.test/930-preparatomtale',
   knowledge.source_version_content_hash(
     'Anbefalt startdose hos voksne er 50 mg daglig. Tabletter 50 mg i pakning med 28.'),
   'regulatory_summary', (select id from fixture where name = 'owner'));

insert into knowledge.source_version_texts
  (source_version_id, representation, stored_by_actor_id)
values
  ('93000000-0000-4000-8000-000000000021',
   'Ved oppstart anbefales laveste effektive dose, med ny vurdering etter to uker. '
   || 'Anbefalingen gjelder voksne i allmennpraksis.',
   (select id from fixture where name = 'owner')),
  ('93000000-0000-4000-8000-000000000022',
   'Anbefalt startdose hos voksne er 50 mg daglig. Tabletter 50 mg i pakning med 28.',
   (select id from fixture where name = 'owner'));

-- Begge kildene godkjennes for rådbehovet. Det er den formen kravet handler om:
-- ett spørsmål som hviler på mer enn én kilde.
insert into knowledge.monograph_source_uses
  (need_id, source_version_id, approved_use, scope_digest, approved_by_actor_id)
select n.id, v.source_version_id, v.approved_use, n.scope_digest,
       (select id from fixture where name = 'redaktor')
from knowledge.monograph_needs n,
     (values
       ('93000000-0000-4000-8000-000000000021'::uuid,
        'Bærer den faglige anbefalingen om oppstart.'),
       ('93000000-0000-4000-8000-000000000022'::uuid,
        'Bærer startdosen slik den er godkjent for norske produkter.')
     ) as v(source_version_id, approved_use)
where n.id = (select id from fixture where name = 'raadbehov');

select is(
  (select count(*)::integer from knowledge.monograph_source_uses u
   where u.need_id = (select id from fixture where name = 'raadbehov')),
  2,
  'ett kunnskapsbehov kan hvile på flere godkjente kilder'
);

-- Og behovet er fortsatt ett behov. En godkjent kildebruk er ikke et nytt
-- spørsmål, og dekningen skal ikke telle spørsmålet to ganger fordi det har to
-- kilder.
select is(
  (select count(*)::integer from knowledge.monograph_needs n
   where n.id = (select id from fixture where name = 'raadbehov')),
  1,
  'og behovet er fortsatt ett behov: to kilder er ikke to spørsmål'
);

select is(
  (select (api.monograph_coverage(
             (select payload ->> 'reference' from svar where label = 'bestilling'))
           -> 'needs' -> 'total')::integer),
  (select count(*)::integer from knowledge.monograph_needs n
   where n.edition_id = (select id from fixture where name = 'edition')),
  'nevneren er behovslisten, og den vokser ikke av at et behov får flere kilder'
);

-- ===========================================================================
-- Del 3 — Det attribuerte rådet
--
-- Et råd er ikke et forskningsfunn. Det har en navngitt instans og en dato, og
-- uten dem er det ikke attribuert til noen (MONOGRAPH_STANDARD.md §3).
-- ===========================================================================
select throws_ok(
  format($$
    select knowledge.record_monograph_answer_revision(
      %L, 'attributed_advice', 'human',
      'Ved oppstart anbefales laveste effektive dose.', null, null, null,
      null, %L, '2026-09-01',
      'Ved oppstart anbefales laveste effektive dose, med ny vurdering etter to uker.',
      'Avsnitt 2', null, null, null, null, 'Prøve i 930.', %L, null)
  $$,
    (select id from fixture where name = 'raadbehov'),
    '93000000-0000-4000-8000-000000000021',
    (select id from fixture where name = 'redaktor')),
  '23514', null,
  'et råd uten en navngitt instans og en dato er ikke attribuert, og avvises'
);

insert into fixture (name, id)
select 'raad', knowledge.record_monograph_answer_revision(
  (select id from fixture where name = 'raadbehov'),
  'attributed_advice', 'human',
  'Ved oppstart anbefales laveste effektive dose, med ny vurdering etter to uker.',
  null,
  'Anbefalingen er en faglig vurdering og ikke et forskningsestimat.',
  null, null, '93000000-0000-4000-8000-000000000021', '2026-09-01',
  'Ved oppstart anbefales laveste effektive dose, med ny vurdering etter to uker.',
  'Avsnitt 2', 'Syntetisk fagmyndighet', '2026-01-15', null,
  jsonb_build_array(jsonb_build_object(
    'source_version_id', '93000000-0000-4000-8000-000000000022',
    'as_of', '2026-09-01',
    'source_quote', 'Anbefalt startdose hos voksne er 50 mg daglig.',
    'source_locator', 'Avsnitt 4.2')),
  'Prøve i 930: rådet, med begge kildene.',
  (select id from fixture where name = 'redaktor'), null);

select is(
  (select r.recommending_body || ' / ' || r.recommendation_date::text
   from knowledge.monograph_answer_revisions r
   where r.id = (select id from fixture where name = 'raad')),
  'Syntetisk fagmyndighet / 2026-01-15',
  'rådet bærer instansen som anbefaler og datoen anbefalingen gjelder fra'
);

-- Dette er den andre halvparten av «ett behov, flere kilder»: svaret bærer
-- begge kildene, og hver av dem har sitt eget ordrette utdrag.
select is(
  (select count(*)::integer from knowledge.monograph_answer_revision_sources s
   where s.answer_revision_id = (select id from fixture where name = 'raad')),
  1,
  'og tilleggskilden står som sin egen rad med sitt eget utdrag'
);
select ok(
  (select exists (
     select 1 from knowledge.monograph_answer_revision_sources s
     where s.answer_revision_id = (select id from fixture where name = 'raad')
       and s.source_version_id = '93000000-0000-4000-8000-000000000022'
       and s.source_quote = 'Anbefalt startdose hos voksne er 50 mg daglig.')),
  'slik at svaret kan etterprøves mot hver enkelt kilde, og ikke bare mot den første'
);

select is(
  (select count(*)::integer from knowledge.evidence_assessments a
   join knowledge.claim_revisions cr on cr.id = a.claim_revision_id
   join knowledge.claims c on c.id = cr.claim_id
   where c.monograph_need_id = (select id from fixture where name = 'raadbehov')),
  0,
  'et attribuert råd får ingen GRADE-vurdering: det er ingen forskningssyntese'
);
select is(
  (select r.claim_revision_id from knowledge.monograph_answer_revisions r
   where r.id = (select id from fixture where name = 'raad')),
  null,
  'og det hviler ikke på en påstandsrevisjon: kilden er anbefalingen selv'
);

-- Og en tilleggskilde som ikke er godkjent for behovet, kommer ikke inn den
-- veien heller. Ellers ville feltet vært en omvei rundt kildekontrollen.
select throws_ok(
  format($$
    select knowledge.record_monograph_answer_revision(
      %L, 'attributed_advice', 'human', 'Et råd med en ukontrollert tilleggskilde.',
      null, null, null, null, %L, '2026-09-01',
      'Ved oppstart anbefales laveste effektive dose, med ny vurdering etter to uker.',
      'Avsnitt 2', 'Syntetisk fagmyndighet', '2026-01-15', null,
      jsonb_build_array(jsonb_build_object(
        'source_version_id', %L,
        'as_of', '2026-09-01',
        'source_quote', 'Anbefalt startdose hos voksne er 50 mg daglig.',
        'source_locator', 'Avsnitt 4.2')),
      'Prøve i 930.', %L, null)
  $$,
    (select id from fixture where name = 'preparatbehov'),
    '93000000-0000-4000-8000-000000000021',
    '93000000-0000-4000-8000-000000000022',
    (select id from fixture where name = 'redaktor')),
  '22023', null,
  'en tilleggskilde som ikke er godkjent for behovet, er ingen omvei rundt kontrollen'
);

-- ===========================================================================
-- Del 4 — Det farmakologiske resonnementet
--
-- Et resonnement legger ikke til ny kunnskap. Det hviler på andre kontrollerte
-- svar i den samme utgaven, og uten dem er det ikke et resonnement — det er en
-- påstand uten grunnlag.
-- ===========================================================================
select throws_ok(
  format($$
    select knowledge.record_monograph_answer_revision(
      %L, 'reasoning', 'human', 'Et resonnement uten noe å resonnere fra.',
      null, null, null, null, null, null, null, null, null, null,
      null, null, 'Prøve i 930.', %L, null)
  $$,
    (select id from fixture where name = 'resonnementbehov'),
    (select id from fixture where name = 'redaktor')),
  '23514', null,
  'et resonnement uten et grunnlag i andre svar avvises'
);

insert into fixture (name, id)
select 'resonnement', knowledge.record_monograph_answer_revision(
  (select id from fixture where name = 'resonnementbehov'),
  'reasoning', 'human',
  'Startdosen følger av anbefalingen om laveste effektive dose.',
  null, 'Resonnementet legger ikke til ny kunnskap ut over svarene det hviler på.',
  null, null, null, null, null, null, null, null,
  array[(select id from fixture where name = 'raad')],
  null, 'Prøve i 930: resonnementet.',
  (select id from fixture where name = 'redaktor'), null);

select is(
  (select cardinality(r.derived_from_revision_ids)
   from knowledge.monograph_answer_revisions r
   where r.id = (select id from fixture where name = 'resonnement')),
  1,
  'resonnementet navngir svaret det hviler på'
);
select is(
  (select num_nonnulls(r.source_version_id, r.claim_revision_id, r.recommending_body)
   from knowledge.monograph_answer_revisions r
   where r.id = (select id from fixture where name = 'resonnement')),
  0,
  'og har ingen egen kilde: det er de underliggende svarene som bærer kunnskapen'
);
select is(
  (select count(*)::integer from knowledge.evidence_assessments a
   join knowledge.claim_revisions cr on cr.id = a.claim_revision_id
   join knowledge.claims c on c.id = cr.claim_id
   where c.monograph_need_id = (select id from fixture where name = 'resonnementbehov')),
  0,
  'et resonnement får ingen GRADE-vurdering, like lite som rådet'
);

-- ===========================================================================
-- Del 5 — Rekonsilieringen av monografileddene
--
-- Overgangene kjøres i den samme transaksjonen som skrivingen, og en overgang
-- som feiler, ruller aldri tilbake det kliniske arbeidet: den noteres, og
-- rekonsilieringen tar den opp igjen. 890 prøver innhentingsleddet. Her prøves
-- svarleddet, og at rekonsilieringen ikke lager duplikater av noe som alt står
-- i køen.
--
-- Avbruddet etterlignes ved å slå av nettopp den overgangen for én skriving.
-- Det er noe annet enn å slette arbeid: tilstanden «en godkjent kildebruk uten
-- svaroppgave» er den tilstanden et avbrudd *etterlater*, og det er den
-- rekonsilieringen finnes for.
-- ===========================================================================
create temporary table koen (label text primary key, antall integer) on commit drop;

insert into koen (label, antall)
select 'oppdagelse-for', count(*)::integer from workflow.pipeline_jobs j
where j.agent_role = 'source_discovery';
insert into koen (label, antall)
select 'sokerunder', count(*)::integer from workflow.monograph_search_requests r
where r.requested_for_role = 'source_discovery' and r.state = 'pending';
insert into koen (label, antall)
select 'svar-for', count(*)::integer from workflow.pipeline_jobs j
where j.agent_role = 'monograph_answer';

-- Migrasjon 013v: bestillingen åpner de maskinelle søkerundene, ikke den
-- semantiske vurderingsoppgaven. Rekkefølgen er en port: Antideps egen kode
-- søker først, og vurderingen legges i køen av runden som faktisk ble utført.
select cmp_ok(
  (select antall from koen where label = 'sokerunder'), '>', 0,
  'bestillingen åpnet de maskinelle søkerundene av seg selv'
);
select is(
  (select antall from koen where label = 'oppdagelse-for'), 0,
  'og ingen semantisk kildeoppgave finnes før søkene er utført: den ville krevd søke-I/O agenten ikke har verktøy til'
);

alter table knowledge.monograph_source_uses disable trigger monograph_source_uses_enqueue_answer;
insert into knowledge.monograph_source_uses
  (need_id, source_version_id, approved_use, scope_digest, approved_by_actor_id)
select n.id, '93000000-0000-4000-8000-000000000022',
       'Oppgir styrke og pakningsidentitet for norske produkter.',
       n.scope_digest, (select id from fixture where name = 'redaktor')
from knowledge.monograph_needs n
where n.id = (select id from fixture where name = 'preparatbehov');
alter table knowledge.monograph_source_uses enable trigger monograph_source_uses_enqueue_answer;

select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'monograph_answer'
     and j.job_key like 'agent-handoff:'
       || (select id::text from fixture where name = 'preparatbehov') || ':%'),
  0,
  'avbruddet etterlot en godkjent kildebruk uten svaroppgave'
);

-- Rekonsilieringen kjøres av et deterministisk kontrolledd, slik en kjører gjør
-- det i drift. Kildeoppdagelsen har ingen vei hit, og det er med vilje: å ta
-- opp igjen en avbrutt overgang er Antideps egen kode, ikke en oppgave et
-- semantisk ledd kan gi seg selv.
insert into svar (label, payload)
select 'legitimasjon',
       to_jsonb(provenance.issue_agent_identity_credential(
         'agent-identity:extraction-verification-01', 'human:peder-holman'));

insert into svar (label, payload)
select 'rekonsiliering', api.resume_chain_transitions(
  'agent-identity:extraction-verification-01',
  (select payload #>> '{}' from svar where label = 'legitimasjon'));

select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'monograph_answer'
     and j.job_key like 'agent-handoff:'
       || (select id::text from fixture where name = 'preparatbehov') || ':%'),
  1,
  'rekonsilieringen tok opp igjen svaroppgaven avbruddet etterlot'
);

select ok(
  (select exists (
     select 1 from workflow.agent_handoff_jobs h
     join workflow.pipeline_jobs j on j.id = h.pipeline_job_id
     where j.agent_role = 'monograph_answer')),
  'og oppgaven går gjennom den samme eksterne agentkontrakten som resten av kjeden'
);

-- Og ingenting som alt sto i køen, er blitt dobbelt. Det er den andre
-- halvparten av kravet: arbeidet skal kunne tas opp igjen *uten* duplikater.
select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role = 'source_discovery'),
  (select antall from koen where label = 'oppdagelse-for'),
  'og søkeoppgavene som alt sto i køen, er ikke blitt doble'
);

insert into svar (label, payload)
select 'rekonsiliering-2', api.resume_chain_transitions(
  'agent-identity:extraction-verification-01',
  (select payload #>> '{}' from svar where label = 'legitimasjon'));

select is(
  (select count(*)::integer from workflow.pipeline_jobs j
   where j.agent_role in ('source_discovery', 'monograph_answer')),
  (select antall from koen where label = 'oppdagelse-for')
  + (select antall from koen where label = 'svar-for') + 1,
  'en ny rekonsiliering rett etterpå lager ingen nye oppgaver'
);

-- Rekonsilieringen er en skrivevei, og den er forbeholdt de deterministiske
-- kontrolleddene. Kildeoppdagelsen kan gjøre søk, men den kan ikke gi seg selv
-- arbeid ved å ta opp igjen en overgang.
select throws_ok(
  $$select api.resume_chain_transitions('agent-identity:source-discovery-01', 'en-hemmelighet')$$,
  '42501', null,
  'et semantisk ledd kan ikke ta opp igjen en kjedeovergang'
);
select throws_ok(
  $$select api.resume_chain_transitions('agent-identity:extraction-verification-01', 'feil-hemmelighet')$$,
  '42501', null,
  'og en feil hemmelighet gir ingen rekonsiliering'
);

select * from finish();
rollback;
