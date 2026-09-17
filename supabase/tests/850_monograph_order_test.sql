-- Migrasjon 013c — bestillingen, kunnskapsbehovene og den ærlige dekningen.
--
-- Filen dekker veien fra «bygg monografi for sertralin» til et dekningskart:
--
--   * én bestilling oppretter konkrete behov av alle 80 malene, og
--     screeningsmalene får ett behov per verdi standarden navngir,
--   * en duplikatbestilling er den samme utgaven og ikke et andre dekningskart,
--   * relevansen følger kravtypen, og uavklart relevans forsvinner ikke,
--   * «ikke relevant» krever en positiv begrunnelse og en navngitt avgjørelse,
--   * et utfall hører til et behov som faktisk er ferdig behandlet,
--   * avgrensningen er behovets identitet: to indikasjoner kolliderer ikke, og
--     den samme avgrensningen to ganger er ett behov,
--   * et åpent forslag om en ny verdi utvider ingenting, et akseptert gjør det,
--     og en agent kan ikke akseptere sitt eget forslag,
--   * dekningen holder relevans, arbeidstilstand, faglig utfall og blokkeringer
--     atskilt, og nevneren er alle behov i utgaven,
--   * malen og avgrensningen er uforanderlige, og
--   * bestillingen krever redaktørmandat.
--
-- SQLSTATE 42501 = insufficient_privilege, 22023 = invalid_parameter_value,
-- 23001 = restrict_violation, 23514 = check_violation,
-- P0002 = no_data_found slik plpgsql reiser den.
begin;

create extension if not exists pgtap with schema extensions;

select plan(72);

-- ===========================================================================
-- Del 1 — Kontrakten
-- ===========================================================================
select has_table('knowledge', 'monograph_editions', 'knowledge.monograph_editions finnes');
select has_table('knowledge', 'monograph_needs', 'knowledge.monograph_needs finnes');
select has_table('workflow', 'monograph_need_events',
                 'workflow.monograph_need_events finnes');
select has_table('workflow', 'monograph_term_proposals',
                 'workflow.monograph_term_proposals finnes');

select is_empty(
  $$
    select f.name, r.role_name
    from (values
      ('api.order_monograph(text,text)'),
      ('api.monograph_order_options()'),
      ('api.monograph_orders()'),
      ('api.monograph_coverage(text)'),
      ('api.propose_monograph_term(text,text,text,text)'),
      ('api.decide_monograph_term(text,boolean,text)'),
      ('api.monograph_term_proposals(text)')
    ) as f(name),
    (values ('anon'), ('service_role'), ('public')) as r(role_name)
    where has_function_privilege(r.role_name, f.name, 'EXECUTE')
  $$,
  'monografibestillingen er stengt for anon, service_role og PUBLIC'
);

select is_empty(
  $$
    select t.table_name, r.role_name, p.privilege
    from (values ('knowledge.monograph_editions'),
                 ('knowledge.monograph_needs'),
                 ('workflow.monograph_need_events'),
                 ('workflow.monograph_term_proposals')) as t(table_name),
         (values ('anon'), ('authenticated'), ('service_role'), ('public')) as r(role_name),
         (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as p(privilege)
    where has_table_privilege(r.role_name, t.table_name, p.privilege)
  $$,
  'ingen klientrolle kan lese eller skrive i bestillingen eller behovene direkte'
);

-- ===========================================================================
-- Del 2 — Kontoene
-- ===========================================================================
insert into auth.users (id, email)
values
  ('85000000-0000-4000-8000-00000000000a', 'redaktor-850@test.invalid'),
  ('85000000-0000-4000-8000-00000000000b', 'kliniker-850@test.invalid');

insert into provenance.actors
  (id, actor_type, actor_key, display_name, description, auth_user_id)
values
  ('ac850000-0000-4000-8000-00000000000a', 'human', 'human:redaktor-850',
   'Redaktør 850', 'Editor uten avgrensning, for 850.',
   '85000000-0000-4000-8000-00000000000a'),
  ('ac850000-0000-4000-8000-00000000000b', 'human', 'human:kliniker-850',
   'Kliniker 850', 'Uten noen rolle i det hele tatt, for 850.',
   '85000000-0000-4000-8000-00000000000b');

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
values
  ('85000000-0000-4000-8000-00000000000a', 'editor', null, now() - interval '1 year',
   'ac850000-0000-4000-8000-00000000000a', 'Editor-tildeling for 850.');

create temporary table svar (label text primary key, payload jsonb) on commit drop;
grant select, insert on svar to authenticated;

-- ===========================================================================
-- Del 3 — Bestillingen krever redaktørmandat
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"85000000-0000-4000-8000-00000000000b"}', true);
set local role authenticated;
select throws_ok(
  $$ select api.order_monograph('sertralin', null) $$,
  '42501',
  null,
  'en kliniker uten redaktørmandat kan ikke bestille en monografi'
);
reset role;

-- ===========================================================================
-- Del 4 — «Bygg monografi for sertralin»
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"85000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling', api.order_monograph('sertralin', 'Prøve i 850: pilotbestillingen.');
insert into svar (label, payload)
select 'valg', api.monograph_order_options();
reset role;

select is(
  (select payload ->> 'drug' from svar where label = 'bestilling'),
  'sertralin',
  'bestillingen gjelder virkestoffet redaktøren navnga'
);
select is(
  (select (payload -> 'ordered')::boolean from svar where label = 'bestilling'),
  true,
  'bestillingen opprettet en ny utgave'
);
select is(
  (select payload ->> 'standard_version' from svar where label = 'bestilling'),
  '1.0.0',
  'utgaven bærer standardversjonen behovene ble opprettet av'
);
select is(
  (select (payload -> 'question_templates')::integer from svar where label = 'valg'),
  80,
  'bestillingsflaten sier hvor mange spørsmål standarden stiller'
);

-- Alle 80 malene er representert. Ikke «minst én rad per mal» som en telling,
-- men uttømmende: en mal uten et behov er et spørsmål ingen stilte.
select is_empty(
  $$
    select t.code
    from knowledge.monograph_question_templates t
    where t.standard_version = '1.0.0'
      and not exists (
        select 1 from knowledge.monograph_needs n where n.template_id = t.id
      )
  $$,
  'alle 80 spørsmålsmalene har minst ett konkret kunnskapsbehov'
);

-- Og antallet behov er nøyaktig det standarden gir: én per svarform per mal, og
-- for screeningsmalene én per verdi standarden navngir — uten et rotbehov ved
-- siden av.
select is(
  (select count(*)::integer from knowledge.monograph_needs),
  (select sum(
     case when exists (select 1 from knowledge.monograph_prescribed_scope_values v
                       where v.template_id = t.id)
          then cardinality(t.answer_forms)
               * (select count(*) from knowledge.monograph_prescribed_scope_values v
                  where v.template_id = t.id)
          else cardinality(t.answer_forms) end)::integer
   from knowledge.monograph_question_templates t
   where t.standard_version = '1.0.0'),
  'antallet behov er én per svarform per mal, og én per navngitt screeningsverdi'
);

select is(
  (select count(*)::integer
   from knowledge.monograph_needs n
   join knowledge.monograph_question_templates t on t.id = n.template_id
   where t.code = 'MN38'),
  11,
  'MN38 har ett behov per risikoområde standarden navngir'
);
select is_empty(
  $$
    select n.id
    from knowledge.monograph_needs n
    join knowledge.monograph_question_templates t on t.id = n.template_id
    where t.code = 'MN38' and n.scope_labels = '{}'::jsonb
  $$,
  'MN38 har ikke et rotbehov uten avgrensning ved siden av de elleve'
);
select is(
  (select array_agg(n.scope_labels ->> 'comorbidity' order by n.scope_labels ->> 'comorbidity')
   from knowledge.monograph_needs n
   join knowledge.monograph_question_templates t on t.id = n.template_id
   where t.code = 'MN50'),
  array['bipolaritet/mani', 'psykose', 'relevante angsttilstander', 'rusmiddelproblemer'],
  'MN50 har ett behov per psykiatrisk tilleggstilstand standarden navngir'
);

-- ===========================================================================
-- Del 5 — Relevansen følger kravtypen, og uavklart forsvinner ikke
-- ===========================================================================
select is_empty(
  $$
    select t.code, n.relevance::text
    from knowledge.monograph_needs n
    join knowledge.monograph_question_templates t on t.id = n.template_id
    where t.requirement = 'mandatory' and n.relevance <> 'relevant'
  $$,
  'en obligatorisk mal gir et relevant behov'
);
select is_empty(
  $$
    select t.code, n.relevance::text
    from knowledge.monograph_needs n
    join knowledge.monograph_question_templates t on t.id = n.template_id
    where t.requirement = 'conditional' and n.relevance <> 'undetermined'
  $$,
  'en betinget mal gir et behov med uavklart relevans, ikke et «ikke relevant»'
);
select isnt_empty(
  $$
    select n.id from knowledge.monograph_needs n where n.relevance = 'undetermined'
  $$,
  'uavklart relevans finnes som en egen tilstand og er ikke slått sammen med noe'
);
select is(
  (select count(*)::integer from knowledge.monograph_needs where relevance = 'not_applicable'),
  0,
  'ingenting er «ikke relevant» før noen har begrunnet det'
);
select is_empty(
  $$
    select n.id from knowledge.monograph_needs n where n.activation_reason is null
  $$,
  'hvert behov kan forklares: ingen rad finnes uten en aktiveringsgrunn'
);

-- Og hvert behov fikk en rad i sporet da det ble opprettet.
select is(
  (select count(*)::integer from workflow.monograph_need_events),
  (select count(*)::integer from knowledge.monograph_needs),
  'hvert opprettet behov har en rad i sitt append-only spor'
);

-- ===========================================================================
-- Del 6 — «Ikke relevant» krever en positiv begrunnelse
-- ===========================================================================
create temporary table needs (label text primary key, id uuid not null) on commit drop;
insert into needs (label, id)
select 'mn12', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where t.code = 'MN12';
insert into needs (label, id)
select 'mn09', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where t.code = 'MN09';

select throws_ok(
  format($$
    update knowledge.monograph_needs set relevance = 'not_applicable' where id = %L
  $$, (select id from needs where label = 'mn12')),
  '23514',
  null,
  'et behov kan ikke settes til «ikke relevant» uten begrunnelse og avgjører'
);

select lives_ok(
  format($$
    update knowledge.monograph_needs
    set relevance = 'not_applicable',
        relevance_reason = 'Prøve i 850: en begrunnet, kontrollerbar utelukkelse.',
        relevance_decided_by_actor_id = 'ac850000-0000-4000-8000-00000000000a',
        relevance_decided_at = now()
    where id = %L
  $$, (select id from needs where label = 'mn12')),
  'et behov kan settes til «ikke relevant» med begrunnelse og navngitt avgjører'
);

select is(
  (select count(*)::integer from audit.events
   where operation = 'monograph_need_relevance_decided'),
  1,
  'relevansavgjørelsen er et auditobjekt'
);

-- ===========================================================================
-- Del 7 — Et utfall hører til et behov som faktisk er ferdig behandlet
-- ===========================================================================
select throws_ok(
  format($$
    update knowledge.monograph_needs set outcome = 'insufficient_evidence' where id = %L
  $$, (select id from needs where label = 'mn09')),
  '23514',
  null,
  'et faglig utfall kan ikke settes på et behov som ikke er ferdig behandlet'
);
select throws_ok(
  format($$
    update knowledge.monograph_needs set work_state = 'agent_complete' where id = %L
  $$, (select id from needs where label = 'mn09')),
  '23514',
  null,
  'et ferdig behandlet behov kan ikke stå uten et faglig utfall'
);
select lives_ok(
  format($$
    update knowledge.monograph_needs
    set work_state = 'awaiting_access',
        work_state_note = 'Prøve i 850: fullteksten ligger bak en betalingsmur.'
    where id = %L
  $$, (select id from needs where label = 'mn09')),
  'manglende tilgang er en arbeidstilstand og krever ikke et faglig utfall'
);

-- ===========================================================================
-- Del 8 — Duplikatbestillingen er den samme utgaven
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"85000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bestilling2', api.order_monograph('sertralin', 'Prøve i 850: samme bestilling igjen.');
reset role;

select is(
  (select payload ->> 'reference' from svar where label = 'bestilling2'),
  (select payload ->> 'reference' from svar where label = 'bestilling'),
  'en duplikatbestilling svarer med den samme utgaven'
);
select is(
  (select (payload -> 'already_ordered')::boolean from svar where label = 'bestilling2'),
  true,
  'og sier at utgaven fantes fra før framfor å late som om den ble opprettet'
);
select is(
  (select (payload -> 'needs_created')::integer from svar where label = 'bestilling2'),
  0,
  'og oppretter ingen nye behov: utvidelsen er idempotent'
);
select is(
  (select count(*)::integer from knowledge.monograph_editions),
  1,
  'det finnes fortsatt bare én utgave for virkestoffet'
);

-- Og regelen er strukturell, ikke bare en if-setning i bestillingsveien.
select throws_ok(
  $$
    insert into knowledge.monograph_editions
      (drug_id, standard_version, edition_no, ordered_by_actor_id)
    select d.id, '1.0.0', 99, 'ac850000-0000-4000-8000-00000000000a'
    from catalog.drugs d where d.canonical_name = 'sertralin'
  $$,
  '23505',
  null,
  'to gjeldende utgaver for det samme virkestoffet avvises av databasen'
);

-- ===========================================================================
-- Del 9 — Avgrensningen er behovets identitet
-- ===========================================================================
create temporary table editions (label text primary key, id uuid not null) on commit drop;
insert into editions (label, id)
select 'sertralin', e.id from knowledge.monograph_editions e;

-- Den samme avgrensningen to ganger er ett behov.
select throws_ok(
  format($$
    insert into knowledge.monograph_needs
      (edition_id, template_id, answer_form, scope_labels, activation_reason, scope_digest)
    select %L, t.id, 'table', '{}'::jsonb, 'Prøve i 850: et duplikat.',
           'sha256:' || repeat('0', 64)
    from knowledge.monograph_question_templates t where t.code = 'MN09'
  $$, (select id from editions where label = 'sertralin')),
  '23505',
  null,
  'det samme behovet med den samme avgrensningen kan ikke opprettes to ganger'
);

-- To indikasjoner kolliderer ikke, selv om malen, virkestoffet og temaet er de
-- samme.
insert into catalog.clinical_concepts (id, canonical_label, concept_type)
values
  ('c8500000-0000-4000-8000-000000000001', 'tvangslidelse (850)', 'condition'),
  ('c8500000-0000-4000-8000-000000000002', 'panikklidelse (850)', 'condition');

select lives_ok(
  format($$
    insert into knowledge.monograph_needs
      (edition_id, template_id, answer_form, indication_concept_id,
       activation_reason, scope_digest)
    select %L, t.id, 'estimate', 'c8500000-0000-4000-8000-000000000001',
           'Prøve i 850: effekt ved tvangslidelse.', 'sha256:' || repeat('0', 64)
    from knowledge.monograph_question_templates t where t.code = 'MN12'
  $$, (select id from editions where label = 'sertralin')),
  'et behov kan avgrenses til én indikasjon'
);
select lives_ok(
  format($$
    insert into knowledge.monograph_needs
      (edition_id, template_id, answer_form, indication_concept_id,
       activation_reason, scope_digest)
    select %L, t.id, 'estimate', 'c8500000-0000-4000-8000-000000000002',
           'Prøve i 850: effekt ved panikklidelse.', 'sha256:' || repeat('0', 64)
    from knowledge.monograph_question_templates t where t.code = 'MN12'
  $$, (select id from editions where label = 'sertralin')),
  'og et annet behov til en annen indikasjon, uten å kollidere med det første'
);
select is(
  (select count(distinct n.scope_digest)::integer
   from knowledge.monograph_needs n
   join knowledge.monograph_question_templates t on t.id = n.template_id
   where t.code = 'MN12'),
  3,
  'de tre MN12-behovene har tre forskjellige avgrensningsavtrykk'
);

-- En indikasjon som ikke er en tilstand, avvises: en peker på tvers ville gitt
-- et behov som så avgrenset ut, men ikke var det.
select throws_ok(
  format($$
    insert into knowledge.monograph_needs
      (edition_id, template_id, answer_form, indication_concept_id,
       activation_reason, scope_digest)
    select %L, t.id, 'estimate', c.id, 'Prøve i 850: feil slags begrep.',
           'sha256:' || repeat('0', 64)
    from knowledge.monograph_question_templates t, catalog.clinical_concepts c
    where t.code = 'MN13' and c.canonical_label = 'vektendring'
  $$, (select id from editions where label = 'sertralin')),
  '22023',
  'Indikasjonen i avgrensningen er ikke en tilstand i katalogen.',
  'et endepunkt kan ikke stå som indikasjon i avgrensningen'
);

-- En akse kan ikke være både satt og markert som ikke relevant.
select throws_ok(
  format($$
    insert into knowledge.monograph_needs
      (edition_id, template_id, answer_form, indication_concept_id,
       scope_not_applicable, activation_reason, scope_digest)
    select %L, t.id, 'estimate', 'c8500000-0000-4000-8000-000000000001',
           array['indication']::knowledge.monograph_scope_axis[],
           'Prøve i 850: motstridende avgrensning.', 'sha256:' || repeat('0', 64)
    from knowledge.monograph_question_templates t where t.code = 'MN14'
  $$, (select id from editions where label = 'sertralin')),
  '22023',
  'En avgrensningsakse er både satt og markert som ikke relevant.',
  'en akse kan ikke være både avgrenset og markert som ikke relevant'
);

-- En svarform malen ikke har, avvises.
select throws_ok(
  format($$
    insert into knowledge.monograph_needs
      (edition_id, template_id, answer_form, activation_reason, scope_digest)
    select %L, t.id, 'directed_relation', 'Prøve i 850: feil svarform.',
           'sha256:' || repeat('0', 64)
    from knowledge.monograph_question_templates t where t.code = 'MN09'
  $$, (select id from editions where label = 'sertralin')),
  '22023',
  null,
  'et behov kan ikke ha en svarform malen ikke ber om'
);

-- Malen og avgrensningen er uforanderlige.
select throws_ok(
  format($$
    update knowledge.monograph_needs
    set indication_concept_id = 'c8500000-0000-4000-8000-000000000002'
    where id = %L
  $$, (select id from needs where label = 'mn09')),
  '23001',
  'Et kunnskapsbehovs mal og avgrensning er uforanderlig.',
  'avgrensningen kan ikke skrives om under et behov som finnes'
);

-- ===========================================================================
-- Del 10 — Forslaget om en ny verdi utvider ingenting før det er akseptert
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"85000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'forslag', api.propose_monograph_term(
  (select payload ->> 'reference' from svar where label = 'bestilling'),
  'indication', 'sosial angstlidelse (850)',
  'Prøve i 850: en godkjent indikasjon standarden ber om å dekke.');
reset role;

select is(
  (select payload ->> 'state' from svar where label = 'forslag'),
  'open',
  'et nytt forslag står som åpent'
);
select is(
  (select count(*)::integer
   from knowledge.monograph_needs n
   join knowledge.monograph_question_templates t on t.id = n.template_id
   where t.code = 'MN11'),
  1,
  'et åpent forslag oppretter ingen behov: bare rotbehovet finnes'
);

-- En avvisning uten begrunnelse er en utsettelse, ikke en konklusjon.
select set_config('request.jwt.claims',
                  '{"sub":"85000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
select throws_ok(
  format($$ select api.decide_monograph_term(%L, false, null) $$,
         (select payload ->> 'reference' from svar where label = 'forslag')),
  '22023',
  'En avvisning krever en begrunnelse.',
  'en avvisning uten begrunnelse avvises'
);

insert into svar (label, payload)
select 'akseptert', api.decide_monograph_term(
  (select payload ->> 'reference' from svar where label = 'forslag'),
  true, 'Prøve i 850: indikasjonen er dokumentert.');
reset role;

select is(
  (select payload ->> 'state' from svar where label = 'akseptert'),
  'accepted',
  'forslaget er akseptert'
);
select cmp_ok(
  (select (payload -> 'needs_created')::integer from svar where label = 'akseptert'),
  '>', 0,
  'aksepten utvidet dekningskartet i den samme transaksjonen'
);
select is(
  (select count(*)::integer
   from knowledge.monograph_needs n
   join knowledge.monograph_question_templates t on t.id = n.template_id
   where t.code = 'MN11' and n.indication_concept_id is not null),
  1,
  'MN11 fikk et behov avgrenset til den nye indikasjonen'
);
select is(
  (select n.relevance::text
   from knowledge.monograph_needs n
   join knowledge.monograph_question_templates t on t.id = n.template_id
   where t.code = 'MN11' and n.indication_concept_id is not null),
  'relevant',
  'og den betingede malen er nå relevant, fordi betingelsen er oppfylt'
);
select is(
  (select c.concept_type::text from catalog.clinical_concepts c
   where c.canonical_label = 'sosial angstlidelse (850)'),
  'condition',
  'aksepten opprettet katalograden verdien trengte'
);
select is(
  (select count(*)::integer from audit.events where operation = 'monograph_term_accepted'),
  1,
  'det aksepterte fagbegrepet er et auditobjekt'
);

-- Rotbehovet står fortsatt, med sin uavklarte relevans: at én indikasjon er
-- dokumentert, betyr ikke at malen som sådan er avgjort.
select is(
  (select n.relevance::text
   from knowledge.monograph_needs n
   join knowledge.monograph_question_templates t on t.id = n.template_id
   where t.code = 'MN11' and n.indication_concept_id is null),
  'undetermined',
  'rotbehovet beholder sin uavklarte relevans'
);

-- Et avgjort forslag kan ikke avgjøres på nytt.
select set_config('request.jwt.claims',
                  '{"sub":"85000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'akseptert2', api.decide_monograph_term(
  (select payload ->> 'reference' from svar where label = 'forslag'),
  true, 'Prøve i 850: den samme aksepten igjen.');
reset role;
select is(
  (select (payload -> 'already_decided')::boolean from svar where label = 'akseptert2'),
  true,
  'den samme avgjørelsen sendt inn igjen svarer med det som ble registrert'
);

-- Et virkestoff opprettes ikke av en monografiutvidelse.
select set_config('request.jwt.claims',
                  '{"sub":"85000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'bytteforslag', api.propose_monograph_term(
  (select payload ->> 'reference' from svar where label = 'bestilling'),
  'switch_target', 'et virkestoff som ikke finnes (850)',
  'Prøve i 850: et byttepar mot noe katalogen ikke kjenner.');
select throws_ok(
  format($$ select api.decide_monograph_term(%L, true, 'Prøve i 850.') $$,
         (select payload ->> 'reference' from svar where label = 'bytteforslag')),
  '22023',
  'Verdien peker på et virkestoff som ikke finnes i katalogen.',
  'et virkestoff opprettes ikke som en bieffekt av en monografiutvidelse'
);
reset role;

-- ===========================================================================
-- Del 11 — En agent kan ikke akseptere sitt eget forslag
-- ===========================================================================
create temporary table runs (label text primary key, id uuid not null) on commit drop;

insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, status, input_manifest,
   completed_at, output_manifest)
select
  '85000000-0000-4000-8000-0000000000f1',
  ai.id, ai.actor_id, 'evidence_extraction',
  'antidep', 'proposal-grounded-extraction', '1.1.0',
  'evidence-extraction/proposal/1', 'antidep-evidence/1', 'succeeded',
  jsonb_build_object('note', 'Prøve i 850.'), now(), jsonb_build_object('note', 'Prøve i 850.')
from provenance.agent_identities ai
where ai.agent_role = 'evidence_extraction'
limit 1;

insert into provenance.agent_runs
  (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
   prompt_template_version, pipeline_version, status, input_manifest,
   completed_at, output_manifest)
select
  '85000000-0000-4000-8000-0000000000f2',
  ai.id, ai.actor_id, 'evidence_extraction',
  'antidep', 'proposal-grounded-extraction', '1.1.0',
  'evidence-extraction/proposal/1', 'antidep-evidence/1', 'succeeded',
  jsonb_build_object('note', 'Prøve i 850.'), now(), jsonb_build_object('note', 'Prøve i 850.')
from provenance.agent_identities ai
where ai.agent_role = 'evidence_extraction'
limit 1;

select is(
  (select p.state::text
   from workflow.monograph_term_proposals p
   where p.label = 'et virkestoff som ikke finnes (850)'),
  'open',
  'et forslag som ikke kunne aksepteres, står fortsatt åpent'
);

-- Forslaget føres på en agentkjøring …
insert into workflow.monograph_term_proposals
  (edition_id, axis, label, rationale, proposed_by_actor_id, proposed_by_agent_run_id)
select
  (select id from editions where label = 'sertralin'),
  'risk_area', 'et nytt risikoområde (850)',
  'Prøve i 850: et funn i en artikkel peker på et risikoområde standarden ikke navnga.',
  (select actor_id from provenance.agent_runs
   where id = '85000000-0000-4000-8000-0000000000f1'),
  '85000000-0000-4000-8000-0000000000f1';

-- … og en kjøring i det samme agentleddet kan ikke akseptere det.
select throws_ok(
  format($$
    select knowledge.decide_monograph_term_proposal(%L, true, null, null, %L)
  $$,
  (select id from workflow.monograph_term_proposals
   where label = 'et nytt risikoområde (850)'),
  '85000000-0000-4000-8000-0000000000f2'),
  '23001',
  'Et agentledd kan ikke akseptere sitt eget forslag om en utvidelse.',
  'et agentledd kan ikke akseptere sitt eget forslag om en utvidelse'
);

-- Men et menneske med redaktørmandat kan. Referansen leses før rolleskiftet:
-- ingen klientrolle kommer til forslagstabellen, og det er hele poenget.
create temporary table refs (label text primary key, value text not null) on commit drop;
grant select on refs to authenticated;
insert into refs (label, value)
select 'risiko', p.reference from workflow.monograph_term_proposals p
where p.label = 'et nytt risikoområde (850)';

select set_config('request.jwt.claims',
                  '{"sub":"85000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'risikoakseptert', api.decide_monograph_term(
  (select value from refs where label = 'risiko'),
  true, 'Prøve i 850: redaktøren tar risikoområdet i bruk.');
reset role;
select is(
  (select payload ->> 'state' from svar where label = 'risikoakseptert'),
  'accepted',
  'et menneske med redaktørmandat kan akseptere agentens forslag'
);

-- ===========================================================================
-- Del 12 — Forgreningen krever en akse malen faktisk gjentas på
-- ===========================================================================
select throws_ok(
  format($$
    select knowledge.refine_monograph_need(
      %L, 'gene', 'CYP2C19 (850)', null, null, null, 'Prøve i 850.')
  $$, (select id from needs where label = 'mn09')),
  '22023',
  null,
  'et behov kan ikke forgrenes på en akse malen ikke gjentas på'
);

-- Rotbehovet under MN21: det uten en avgrensning og uten et behov som aktiverte
-- det. De indikasjonsavgrensede søsknene er andre behov.
insert into needs (label, id)
select 'mn21rot', n.id
from knowledge.monograph_needs n
join knowledge.monograph_question_templates t on t.id = n.template_id
where t.code = 'MN21'
  and n.scope_labels = '{}'::jsonb
  and n.indication_concept_id is null
  and n.activated_by_need_id is null;

select isnt(
  (select knowledge.refine_monograph_need(
     (select id from needs where label = 'mn21rot'),
     'formulation', 'mikstur (850)', null, null, null,
     'Prøve i 850: et dokumentert funn gjelder bare miksturen.')),
  null,
  'et behov kan forgrenes på en formulering, fordi MN21 gjentas per formulering'
);
select is(
  (select knowledge.refine_monograph_need(
     (select id from needs where label = 'mn21rot'),
     'formulation', 'mikstur (850)', null, null, null,
     'Prøve i 850: den samme forgreningen igjen.')),
  null,
  'den samme forgreningen to ganger gir ett behov'
);

-- ===========================================================================
-- Del 13 — Dekningen holder dimensjonene atskilt
-- ===========================================================================
select set_config('request.jwt.claims',
                  '{"sub":"85000000-0000-4000-8000-00000000000a"}', true);
set local role authenticated;
insert into svar (label, payload)
select 'dekning', api.monograph_coverage(
  (select payload ->> 'reference' from svar where label = 'bestilling'));
reset role;

select is(
  (select (payload -> 'needs' -> 'total')::integer from svar where label = 'dekning'),
  (select count(*)::integer from knowledge.monograph_needs),
  'nevneren er alle behov i utgaven: ingen vanskelige spørsmål er fjernet'
);
select is(
  (select (payload -> 'needs' -> 'justified_not_applicable')::integer
   from svar where label = 'dekning'),
  1,
  'de begrunnet ikke relevante behovene telles for seg'
);
select cmp_ok(
  (select (payload -> 'needs' -> 'undetermined_relevance')::integer
   from svar where label = 'dekning'),
  '>', 0,
  'og de uavklarte betingelsene telles for seg, framfor å forsvinne'
);
select is(
  (select (payload -> 'blocked' -> 'awaiting_access')::integer
   from svar where label = 'dekning'),
  1,
  'manglende tilgang telles som en blokkering og ikke som et faglig utfall'
);
select is(
  (select (payload -> 'needs' -> 'no_qualifying_evidence')::integer
   from svar where label = 'dekning'),
  0,
  'og den blokkeringen er ikke blitt «ingen kvalifiserende evidens»'
);
select is(
  (select (payload -> 'needs' -> 'answered')::integer from svar where label = 'dekning'),
  0,
  'ingenting er besvart ennå'
);
select is(
  (select payload -> 'completion' ->> 'level' from svar where label = 'dekning'),
  'coverage_map',
  'utgaven er et opprettet dekningskart og ikke en agentferdig monografi'
);
select is(
  (select (payload -> 'completion' -> 'partial')::boolean from svar where label = 'dekning'),
  true,
  'og den er merket som delvis'
);
select is(
  (select payload -> 'work_coverage' ->> 'percent' from svar where label = 'dekning'),
  '0',
  'arbeidsdekningen er null, og den er merket som arbeidsdekning'
);
select ok(
  (select not (payload -> 'work_coverage' ? 'certainty') from svar where label = 'dekning')
  and (select not (payload ? 'certainty') from svar where label = 'dekning'),
  'dekningsoversikten bærer ingen samlet evidenssikkerhet: de to er aldri samme indikator'
);
select cmp_ok(
  (select jsonb_array_length(payload -> 'sections') from svar where label = 'dekning'),
  '>=', 14,
  'dekningen er brutt ned på standardens egne avsnitt'
);

-- ===========================================================================
-- Del 14 — Standardregisteret og utgaven er uforanderlige
-- ===========================================================================
select throws_ok(
  $$ update knowledge.monograph_editions set drug_id = gen_random_uuid() $$,
  '23001',
  'En monografiutgaves identitet er uforanderlig.',
  'utgavens virkestoff kan ikke skrives om'
);
select throws_ok(
  $$ delete from workflow.monograph_need_events $$,
  '23001',
  null,
  'sporet over kunnskapsbehovene er append-only'
);

select * from finish();

rollback;
