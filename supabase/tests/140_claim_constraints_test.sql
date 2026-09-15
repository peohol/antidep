-- Migrasjon 004 — deklarative constraints og FK-integritet i påstandslaget.
--
-- DATABASE_ARCHITECTURE.md §57 krever at integritet håndheves deklarativt i
-- databasen, §58 lister invariantene som minst skal håndheves, §59 krever at
-- cross-row-regler bruker riktig mekanisme, og §67 krever at constraints, FK-er
-- og negative stier faktisk testes. Hver regel testes både positivt og negativt,
-- slik at en vaktpost som overblokkerer også blir synlig.
--
-- Særlig vekt på:
--   * unik revisjonsnummerering per påstand (MVP_IMPLEMENTATION_PLAN.md §21)
--   * relationship-type-constraints (DATABASE_ARCHITECTURE.md §21)
--   * certainty- og no-evidence-semantikken (ANTIDEP_CONSTITUTION.md §6)
--   * at en påstand ikke kan bli mer presis enn grunnlaget tillater
--
-- SQLSTATE: 23502 not_null_violation, 23503 foreign_key_violation,
-- 23505 unique_violation, 23514 check_violation, 22P02 invalid_text_representation.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(64);

-- ---------------------------------------------------------------------------
-- Testdata som bare finnes inne i denne transaksjonen
--
-- Testpåstandene får «depressiv lidelse» som tema, slik at de aldri kan
-- forveksles med slicepåstandene, som har «vektendring». At et begrep av typen
-- condition kan brukes som tema er samtidig poenget: temaet er bevisst ikke
-- låst til én begrepstype.
-- ---------------------------------------------------------------------------

-- Migrasjon 005 gjorde created_by_actor_id påkrevd på kunnskapsobjektene
-- (ANTIDEP_CONSTITUTION.md §14). Testdata attribueres til den samme aktøren som
-- produserte de seedede radene, slik at fikstursradene ikke er mindre
-- attribuerte enn kunnskapsbasen ellers.
create function pg_temp.synthesis_actor() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'agent:claim-synthesis'
$$;

insert into knowledge.claims
  (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
select 'evidence_synthesis', c.id, d.id, pg_temp.synthesis_actor()
from catalog.clinical_concepts c, catalog.drugs d
where c.canonical_label = 'depressiv lidelse' and d.canonical_name = 'sertralin';

insert into knowledge.claims
  (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
select 'deterministic_fact', c.id, d.id, pg_temp.synthesis_actor()
from catalog.clinical_concepts c, catalog.drugs d
where c.canonical_label = 'depressiv lidelse' and d.canonical_name = 'mirtazapin';

create function pg_temp.test_claim(kind text) returns uuid language sql as $$
  select cl.id
  from knowledge.claims cl
  join catalog.clinical_concepts c on c.id = cl.topic_concept_id
  where c.canonical_label = 'depressiv lidelse'
    and cl.knowledge_type::text = kind;
$$;

-- Kortform for en gyldig revisjon, slik at hver negativ test bare varierer den
-- ene kolonnen den handler om.
create function pg_temp.insert_revision(
  overrides jsonb default '{}'::jsonb
) returns uuid language plpgsql as $$
declare
  payload jsonb;
  new_id uuid;
begin
  payload := jsonb_build_object(
    'claim_kind', 'evidence_synthesis',
    'revision_number', 1,
    'statement', 'Testpåstand om vektendring i testdata.',
    'scope', 'Gjelder gjennomsnittlig vektendring fra behandlingsstart i testdata.',
    'timeframe_min', '8 weeks',
    'timeframe_max', '8 weeks',
    'comparator_kind', 'none',
    'direction', 'increase',
    'uncertainty_summary', 'Ett evidensfunn i testdata.'
  ) || overrides;

  insert into knowledge.claim_revisions (
    claim_id, revision_number, knowledge_type, subject_drug_id,
    supersedes_revision_id, statement, scope, population_id,
    timeframe_min, timeframe_max, comparator_kind, comparator_drug_id,
    direction, magnitude_measure, magnitude_value, magnitude_unit,
    qualifiers, uncertainty_summary, created_by_actor_id
  )
  select
    cl.id,
    (payload ->> 'revision_number')::integer,
    coalesce((payload ->> 'knowledge_type')::knowledge.knowledge_type, cl.knowledge_type),
    coalesce(
      (select d.id from catalog.drugs d where d.canonical_name = payload ->> 'subject_drug'),
      cl.subject_drug_id
    ),
    (payload ->> 'supersedes_revision_id')::uuid,
    payload ->> 'statement',
    payload ->> 'scope',
    case when payload ? 'population_null' then null
         else (select id from catalog.populations
               where canonical_label = 'voksne med depressiv lidelse') end,
    (payload ->> 'timeframe_min')::interval,
    (payload ->> 'timeframe_max')::interval,
    (payload ->> 'comparator_kind')::knowledge.comparator_kind,
    (select d.id from catalog.drugs d where d.canonical_name = payload ->> 'comparator_drug'),
    (payload ->> 'direction')::knowledge.claim_direction,
    (payload ->> 'magnitude_measure')::knowledge.effect_measure,
    (payload ->> 'magnitude_value')::numeric,
    (payload ->> 'magnitude_unit')::knowledge.estimate_unit,
    payload ->> 'qualifiers',
    payload ->> 'uncertainty_summary',
    pg_temp.synthesis_actor()
  from knowledge.claims cl
  where cl.id = pg_temp.test_claim(payload ->> 'claim_kind')
  returning id into new_id;

  return new_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- knowledge.claims — identitet og tilbaketrekking
-- ---------------------------------------------------------------------------
-- KNOWLEDGE_MODEL.md §9.1: en påstand skal være atomisk, og samme virkestoff og
-- tema skal derfor kunne ha flere selvstendige påstander.
select lives_ok(
  $$
    insert into knowledge.claims
      (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
    select 'evidence_synthesis', c.id, d.id, pg_temp.synthesis_actor()
    from catalog.clinical_concepts c, catalog.drugs d
    where c.canonical_label = 'vektendring' and d.canonical_name = 'sertralin'
  $$,
  'samme virkestoff og tema kan ha flere selvstendige påstander (KNOWLEDGE_MODEL.md §9.1)'
);
select throws_ok(
  $$
    insert into knowledge.claims
      (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
    select 'evidence_summary', c.id, d.id, pg_temp.synthesis_actor()
    from catalog.clinical_concepts c, catalog.drugs d
    where c.canonical_label = 'vektendring' and d.canonical_name = 'sertralin'
  $$,
  '22P02', null,
  'en kunnskapstype utenfor det kontrollerte vokabularet avvises'
);
select throws_ok(
  $$
    insert into knowledge.claims
      (knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
    select 'evidence_synthesis', c.id, gen_random_uuid(), pg_temp.synthesis_actor()
    from catalog.clinical_concepts c where c.canonical_label = 'vektendring'
  $$,
  '23503', null,
  'en påstand om et ukjent virkestoff avvises'
);

-- ANTIDEP_CONSTITUTION.md §14: en tilbaketrekking skal ikke kunne skje uten spor.
select throws_ok(
  $$update knowledge.claims set retired_at = now()
    where id = pg_temp.test_claim('deterministic_fact')$$,
  '23514', null,
  'en påstand kan ikke trekkes tilbake uten begrunnelse'
);
select throws_ok(
  $$update knowledge.claims set retirement_note = 'Begrunnelse uten tilbaketrekking'
    where id = pg_temp.test_claim('deterministic_fact')$$,
  '23514', null,
  'en tilbaketrekkingsbegrunnelse uten retired_at avvises'
);
select lives_ok(
  $$update knowledge.claims
    set retired_at = now(), retirement_note = 'Erstattet av en mer presis påstand i testdata'
    where id = pg_temp.test_claim('deterministic_fact')$$,
  'tilbaketrekking med begrunnelse er tillatt'
);
-- Vaktposten skal ikke overblokkere: en tilbaketrekking kan angres, og da
-- fjernes begge feltene sammen.
select lives_ok(
  $$update knowledge.claims set retired_at = null, retirement_note = null
    where id = pg_temp.test_claim('deterministic_fact')$$,
  'en tilbaketrekking kan angres når begge feltene fjernes sammen'
);

-- ---------------------------------------------------------------------------
-- knowledge.claim_revisions — nummerering og identitetsspeil
-- ---------------------------------------------------------------------------
select lives_ok(
  $$select pg_temp.insert_revision()$$,
  'en gyldig revisjon kan registreres'
);
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"statement": "Testpåstand, dublett av revisjonsnummer 1."}'::jsonb)$$,
  '23505', null,
  'to revisjoner av samme påstand kan ikke ha samme revisjonsnummer'
);
select lives_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 2, "statement": "Testpåstand, revisjon 2."}'::jsonb)$$,
  'neste revisjonsnummer er tillatt'
);
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 0, "statement": "Testpåstand, revisjon 0."}'::jsonb)$$,
  '23514', null,
  'revisjonsnummer null avvises (DATABASE_ARCHITECTURE.md §58)'
);
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": -1, "statement": "Testpåstand, negativt revisjonsnummer."}'::jsonb)$$,
  '23514', null,
  'et negativt revisjonsnummer avvises'
);

-- Speilkolonnene er låst til identitetsraden av den sammensatte fremmednøkkelen,
-- og kan derfor ikke settes til noe annet enn det identiteten sier.
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 3, "knowledge_type": "clinical_recommendation",
        "statement": "Testpåstand med feil kunnskapstype."}'::jsonb)$$,
  '23503', null,
  'en revisjon kan ikke oppgi en annen kunnskapstype enn identiteten'
);
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 3, "subject_drug": "mirtazapin",
        "statement": "Testpåstand med feil virkestoff."}'::jsonb)$$,
  '23503', null,
  'en revisjon kan ikke oppgi et annet virkestoff enn identiteten'
);

-- En revisjon kan ikke erstatte en revisjon av en annen påstand
-- (DATABASE_ARCHITECTURE.md §14).
select throws_ok(
  $$
    insert into knowledge.claim_revisions (
      claim_id, revision_number, knowledge_type, subject_drug_id,
      supersedes_revision_id, statement, scope, comparator_kind, uncertainty_summary,
      created_by_actor_id
    )
    select
      cl.id, 3, cl.knowledge_type, cl.subject_drug_id,
      (select r.id from knowledge.claim_revisions r
       join knowledge.claims c2 on c2.id = r.claim_id
       join catalog.clinical_concepts cc on cc.id = c2.topic_concept_id
       where cc.canonical_label = 'vektendring' limit 1),
      'Testpåstand som erstatter en annen påstands revisjon.',
      'Testomfang.', 'none', 'Testusikkerhet.', pg_temp.synthesis_actor()
    from knowledge.claims cl
    where cl.id = pg_temp.test_claim('evidence_synthesis')
  $$,
  '23503', null,
  'en revisjon kan ikke erstatte en revisjon av en annen påstand'
);
select lives_ok(
  $$
    select pg_temp.insert_revision(jsonb_build_object(
      'revision_number', 3,
      'statement', 'Testpåstand, revisjon 3 som viderefører revisjon 2.',
      'supersedes_revision_id',
        (select r.id from knowledge.claim_revisions r
         where r.claim_id = pg_temp.test_claim('evidence_synthesis')
           and r.revision_number = 2)
    ))
  $$,
  'en revisjon kan erstatte en tidligere revisjon av samme påstand'
);

-- Revisjonsnummeret er monotont (KNOWLEDGE_MODEL.md §9), så en videreføring må
-- peke bakover. Ellers kunne kjeden gå framover eller i sirkel, og «hvilken
-- revisjon erstattet hvilken?» ville ikke lenger vært entydig. 23001 =
-- restrict_violation.
select lives_ok(
  $$select pg_temp.insert_revision(
      '{"claim_kind": "deterministic_fact", "revision_number": 2,
        "statement": "Testfaktum, revisjon 2."}'::jsonb)$$,
  'en revisjon kan opprettes selv om lavere revisjonsnumre ennå ikke finnes'
);
select throws_ok(
  $$
    select pg_temp.insert_revision(jsonb_build_object(
      'claim_kind', 'deterministic_fact',
      'revision_number', 1,
      'statement', 'Testfaktum som viderefører en senere revisjon.',
      'supersedes_revision_id',
        (select r.id from knowledge.claim_revisions r
         where r.claim_id = pg_temp.test_claim('deterministic_fact')
           and r.revision_number = 2)
    ))
  $$,
  '23001', null,
  'en revisjon kan ikke erstatte en revisjon med høyere eller likt revisjonsnummer'
);

-- ---------------------------------------------------------------------------
-- knowledge.claim_revisions — strukturert betydning
-- ---------------------------------------------------------------------------
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 20, "statement": "   "}'::jsonb)$$,
  '23514', null,
  'en revisjon uten formulering avvises'
);
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 20, "scope": "  ",
        "statement": "Testpåstand uten uttalt omfang."}'::jsonb)$$,
  '23514', null,
  'en revisjon uten uttalt anvendelsesområde avvises'
);

-- ANTIDEP_CONSTITUTION.md §6: en evidenssyntese må ha en eksplisitt
-- usikkerhetstekst.
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 20, "uncertainty_summary": null,
        "statement": "Testpåstand uten usikkerhetstekst."}'::jsonb)$$,
  '23514', null,
  'en evidenssyntese uten eksplisitt usikkerhetstekst avvises'
);
-- Vaktposten skal ikke overblokkere: et deterministisk faktum påtvinges ikke en
-- innholdsløs standardtekst.
select lives_ok(
  $$select pg_temp.insert_revision(
      '{"claim_kind": "deterministic_fact", "uncertainty_summary": null,
        "statement": "Testfaktum uten usikkerhetstekst."}'::jsonb)$$,
  'et deterministisk faktum kan stå uten usikkerhetstekst'
);

-- Komparator: samme akse og samme regler som på evidensfunnene.
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 20, "comparator_drug": "mirtazapin",
        "statement": "Testpåstand med komparator uten kategori."}'::jsonb)$$,
  '23514', null,
  'en komparator uten kategorien drug avvises'
);
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 20, "comparator_kind": "drug",
        "statement": "Testpåstand med kategori uten komparator."}'::jsonb)$$,
  '23514', null,
  'kategorien drug uten oppgitt komparatorvirkestoff avvises'
);
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 20, "comparator_kind": "drug", "comparator_drug": "sertralin",
        "statement": "Testpåstand som sammenligner med seg selv."}'::jsonb)$$,
  '23514', null,
  'en påstand kan ikke ha sitt eget virkestoff som komparator'
);
select lives_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 20, "comparator_kind": "drug", "comparator_drug": "mirtazapin",
        "statement": "Testpåstand med et registrert komparatorvirkestoff."}'::jsonb)$$,
  'en påstand med et annet virkestoff som komparator er tillatt'
);
select lives_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 21, "comparator_kind": "placebo",
        "statement": "Testpåstand med placebo som komparator."}'::jsonb)$$,
  'placebo er en gyldig komparatorkategori uten komparatorvirkestoff'
);

-- Tidsrom.
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 22, "timeframe_min": "12 weeks", "timeframe_max": "8 weeks",
        "statement": "Testpåstand med invertert tidsrom."}'::jsonb)$$,
  '23514', null,
  'et invertert tidsrom avvises'
);
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 22, "timeframe_max": null,
        "statement": "Testpåstand med bare den ene tidsgrensen."}'::jsonb)$$,
  '23514', null,
  'et tidsrom med bare den ene grensen avvises'
);
select lives_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 22, "timeframe_min": null, "timeframe_max": null,
        "statement": "Testpåstand uten tidsavgrensning."}'::jsonb)$$,
  'en påstand uten tidsavgrensning er tillatt'
);
-- NULL på populasjon betyr at påstanden ikke er avgrenset til en populasjon,
-- ikke at populasjonen er ukjent.
select lives_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 23, "population_null": true,
        "statement": "Testpåstand uten populasjonsavgrensning."}'::jsonb)$$,
  'en påstand uten populasjonsavgrensning er tillatt'
);

-- Størrelse: en påstand skal ikke kunne bære et tall som er mindre tolkbart enn
-- tallene under den.
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 24, "magnitude_value": 0.8, "magnitude_unit": "kg",
        "statement": "Testpåstand med tall uten effektmål."}'::jsonb)$$,
  '23514', null,
  'en tallfestet størrelse uten effektmål avvises'
);
-- Enheten er bevisst utfylt her, slik at den manglende tallverdien er det eneste
-- som er galt. Uten den ville regelen om at et dimensjonalt mål krever enhet ha
-- utløst samme feilkode, og testen ville passert av feil grunn.
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 24, "magnitude_measure": "mean_change", "magnitude_unit": "kg",
        "statement": "Testpåstand med effektmål uten tall."}'::jsonb)$$,
  '23514', null,
  'et effektmål uten tallverdi avvises; størrelsen er enten hel eller fraværende'
);
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 24, "magnitude_measure": "mean_change", "magnitude_value": 0.8,
        "statement": "Testpåstand med dimensjonalt mål uten enhet."}'::jsonb)$$,
  '23514', null,
  'et dimensjonalt effektmål uten enhet avvises'
);
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 24, "magnitude_measure": "risk_ratio", "magnitude_value": 1.4,
        "magnitude_unit": "kg",
        "statement": "Testpåstand med dimensjonsløst mål og enhet."}'::jsonb)$$,
  '23514', null,
  'et dimensjonsløst effektmål med enhet avvises'
);
select throws_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 24, "magnitude_measure": "risk_ratio", "magnitude_value": -1.4,
        "statement": "Testpåstand med negativt forholdstall."}'::jsonb)$$,
  '23514', null,
  'et negativt forholdstall avvises'
);
select lives_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 24, "magnitude_measure": "mean_change", "magnitude_value": 0.8,
        "magnitude_unit": "kg", "statement": "Testpåstand med tallfestet størrelse."}'::jsonb)$$,
  'en påstand med fullt strukturert størrelse er tillatt'
);
-- Den normale tilstanden når grunnlaget ikke bærer et tall: ingen tallfestet
-- størrelse, og eventuelt heller ingen strukturert retning
-- (ANTIDEP_CONSTITUTION.md §4).
select lives_ok(
  $$select pg_temp.insert_revision(
      '{"revision_number": 25, "direction": null,
        "statement": "Testpåstand uten retning og uten størrelse."}'::jsonb)$$,
  'en påstand uten strukturert retning eller størrelse er tillatt'
);

-- ---------------------------------------------------------------------------
-- knowledge.claim_evidence_links (DATABASE_ARCHITECTURE.md §21)
-- ---------------------------------------------------------------------------
create function pg_temp.insert_link(
  revision integer default 1,
  relationship text default 'supports',
  direct text default 'direct',
  note text default 'Testbegrunnelse for hvordan funnet forholder seg til påstanden.',
  drug text default 'sertralin'
) returns uuid language sql as $$
  insert into knowledge.claim_evidence_links (
    claim_revision_id, evidence_item_id, relationship_type, directness, relevance_note,
    created_by_actor_id
  )
  select
    (select r.id from knowledge.claim_revisions r
     where r.claim_id = pg_temp.test_claim('evidence_synthesis')
       and r.revision_number = revision),
    e.id,
    relationship::knowledge.claim_evidence_relationship,
    direct::knowledge.evidence_directness,
    note,
    pg_temp.synthesis_actor()
  from knowledge.evidence_items e
  join catalog.drugs d on d.id = e.intervention_drug_id
  where d.canonical_name = drug
  returning id;
$$;

select lives_ok(
  $$select pg_temp.insert_link()$$,
  'en gyldig evidenslenke kan registreres'
);
select throws_ok(
  $$select pg_temp.insert_link()$$,
  '23505', null,
  'samme revisjon og samme evidensfunn kan ikke kobles to ganger'
);

-- ANTIDEP_CONSTITUTION.md §9 og KNOWLEDGE_MODEL.md §13.2: motstridende evidens
-- registreres like presist som støttende, og databasen krever ikke at lenkene
-- på en revisjon er samstemte.
select lives_ok(
  $$select pg_temp.insert_link(1, 'contradicts', 'direct',
      'Testbegrunnelse for et funn som taler mot påstanden.', 'mirtazapin')$$,
  'et motstridende funn kan kobles til samme revisjon som et støttende'
);
select is(
  (select count(distinct l.relationship_type) from knowledge.claim_evidence_links l
   join knowledge.claim_revisions r on r.id = l.claim_revision_id
   where r.claim_id = pg_temp.test_claim('evidence_synthesis')),
  2::bigint,
  'en revisjon kan samtidig ha støttende og motstridende evidenslenker'
);

select throws_ok(
  $$select pg_temp.insert_link(2, 'neutral')$$,
  '22P02', null,
  'en relasjonstype utenfor det kontrollerte vokabularet avvises'
);
select throws_ok(
  $$select pg_temp.insert_link(2, 'supports', 'direct', '   ')$$,
  '23514', null,
  'en evidenslenke uten begrunnelse avvises (ANTIDEP_CONSTITUTION.md §4)'
);
-- De to aksene kan ikke motsi hverandre.
select throws_ok(
  $$select pg_temp.insert_link(2, 'indirect', 'direct')$$,
  '23514', null,
  'en relasjon merket indirect kan ikke samtidig påstås å treffe påstanden direkte'
);
-- Men et funn som støtter eller motsier påstanden indirekte skal kunne
-- registreres; ellers ville indirekthet gått tapt.
select lives_ok(
  $$select pg_temp.insert_link(2, 'partially_supports', 'indirect',
      'Testbegrunnelse for et indirekte funn som delvis underbygger påstanden.')$$,
  'et indirekte funn som delvis underbygger påstanden kan registreres'
);
-- KNOWLEDGE_MODEL.md §12: et funn kan være direkte relevant og likevel verken
-- støtte eller motsi påstanden. Uten en egen nøytral stance-verdi måtte det
-- enten feilmerkes som støttende eller framstilles som indirekte.
select lives_ok(
  $$select pg_temp.insert_link(3, 'neutral_contextual', 'direct',
      'Testbegrunnelse for et direkte relevant funn som verken støtter eller motsier påstanden.')$$,
  'et direkte relevant, men nøytralt funn kan registreres uten å bli merket indirekte'
);
select throws_ok(
  $$
    insert into knowledge.claim_evidence_links (
      claim_revision_id, evidence_item_id, relationship_type, directness, relevance_note,
      created_by_actor_id
    )
    select
      (select r.id from knowledge.claim_revisions r
       where r.claim_id = pg_temp.test_claim('evidence_synthesis') and r.revision_number = 1),
      gen_random_uuid(), 'supports', 'direct', 'Testbegrunnelse for et ukjent evidensfunn.',
      pg_temp.synthesis_actor()
  $$,
  '23503', null,
  'en lenke til et ukjent evidensfunn avvises'
);

-- ---------------------------------------------------------------------------
-- knowledge.evidence_assessments — certainty og «ingen vurderbar evidens»
-- (ANTIDEP_CONSTITUTION.md §6, DATABASE_ARCHITECTURE.md §22)
-- ---------------------------------------------------------------------------
create function pg_temp.insert_assessment(
  overrides jsonb default '{}'::jsonb
) returns uuid language plpgsql as $$
declare
  payload jsonb;
  new_id uuid;
begin
  payload := jsonb_build_object(
    'claim_kind', 'evidence_synthesis',
    'revision_number', 1,
    'certainty_level', 'very_low',
    'risk_of_bias', 'serious',
    'inconsistency', 'not_assessable',
    'indirectness', 'not_serious',
    'imprecision', 'very_serious',
    'publication_bias', 'not_assessable',
    'rationale', 'Testbegrunnelse for sikkerhetsgraden.'
  ) || overrides;

  insert into knowledge.evidence_assessments (
    claim_revision_id, assessed_knowledge_type, framework, certainty_level,
    risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
    rationale, evidence_gap, assessed_at, created_by_actor_id
  )
  select
    r.id,
    r.knowledge_type,
    'grade',
    (payload ->> 'certainty_level')::knowledge.certainty_level,
    (payload ->> 'risk_of_bias')::knowledge.grade_domain_rating,
    (payload ->> 'inconsistency')::knowledge.grade_domain_rating,
    (payload ->> 'indirectness')::knowledge.grade_domain_rating,
    (payload ->> 'imprecision')::knowledge.grade_domain_rating,
    (payload ->> 'publication_bias')::knowledge.grade_domain_rating,
    payload ->> 'rationale',
    payload ->> 'evidence_gap',
    now(),
    pg_temp.synthesis_actor()
  from knowledge.claim_revisions r
  where r.claim_id = pg_temp.test_claim(payload ->> 'claim_kind')
    and r.revision_number = (payload ->> 'revision_number')::integer
  returning id into new_id;

  return new_id;
end;
$$;

select lives_ok(
  $$select pg_temp.insert_assessment()$$,
  'en gyldig GRADE-vurdering kan registreres'
);
select throws_ok(
  $$select pg_temp.insert_assessment()$$,
  '23505', null,
  'en påstandsrevisjon kan bare ha én evidensvurdering'
);

-- Vurderingen forsegler evidenssettet. Uten denne regelen ville sekvensen
-- «revisjon → lenke → vurder → ny lenke» vært lovlig, og vurderingen ville ikke
-- lenger beskrevet det grunnlaget som faktisk står registrert på revisjonen.
select throws_ok(
  $$select pg_temp.insert_link(1, 'contradicts', 'direct',
      'Testbegrunnelse for et motstridende funn oppdaget etter vurderingen.', 'mirtazapin')$$,
  '23001', null,
  'en revisjon kan ikke få nye evidenslenker etter at den har fått sin evidensvurdering'
);
-- Vaktposten skal ikke overblokkere: en revisjon som ennå ikke er vurdert, skal
-- fortsatt kunne bygge opp evidenssettet sitt.
select lives_ok(
  $$select pg_temp.insert_link(3, 'supports', 'direct',
      'Testbegrunnelse for en lenke på en revisjon som ennå ikke er vurdert.', 'mirtazapin')$$,
  'en revisjon uten evidensvurdering kan fortsatt få nye evidenslenker'
);

-- «Ingen vurderbar evidens» er en egen tilstand, ikke svært lav sikkerhet, og
-- ikke en manglende verdi (ANTIDEP_CONSTITUTION.md §6).
select lives_ok(
  $$select pg_temp.insert_assessment(
      '{"revision_number": 2, "certainty_level": "no_assessable_evidence",
        "risk_of_bias": null, "inconsistency": null, "indirectness": null,
        "imprecision": null, "publication_bias": null,
        "evidence_gap": "Ingen studier dekker dette spørsmålet i testdata."}'::jsonb)$$,
  'ingen vurderbar evidens registreres som egen tilstand uten domenevurderinger'
);
select throws_ok(
  $$select pg_temp.insert_assessment(
      '{"revision_number": 3, "certainty_level": "no_assessable_evidence",
        "risk_of_bias": null, "inconsistency": null, "indirectness": null,
        "imprecision": null, "publication_bias": null}'::jsonb)$$,
  '23514', null,
  'ingen vurderbar evidens uten å si hva som mangler avvises'
);
select throws_ok(
  $$select pg_temp.insert_assessment(
      '{"revision_number": 3, "certainty_level": "no_assessable_evidence",
        "evidence_gap": "Ingen studier dekker dette spørsmålet i testdata."}'::jsonb)$$,
  '23514', null,
  'ingen vurderbar evidens med utfylte domener avvises; det finnes ikke noe å gradere ned fra'
);
select throws_ok(
  $$select pg_temp.insert_assessment('{"revision_number": 3, "risk_of_bias": null}'::jsonb)$$,
  '23514', null,
  'en GRADE-kategori uten eksplisitt domenevurdering avvises (ANTIDEP_CONSTITUTION.md §6)'
);
select throws_ok(
  $$select pg_temp.insert_assessment('{"revision_number": 3, "rationale": "   "}'::jsonb)$$,
  '23514', null,
  'en sikkerhetsgrad uten begrunnelse avvises'
);
select throws_ok(
  $$select pg_temp.insert_assessment(
      '{"revision_number": 3, "certainty_level": "insufficient"}'::jsonb)$$,
  '22P02', null,
  'en sikkerhetsgrad utenfor det kontrollerte vokabularet avvises'
);
-- Vaktposten skal ikke overblokkere: alle fire GRADE-kategoriene skal kunne
-- registreres, også høy sikkerhet.
select lives_ok(
  $$select pg_temp.insert_assessment(
      '{"revision_number": 3, "certainty_level": "high", "risk_of_bias": "not_serious",
        "inconsistency": "not_serious", "indirectness": "not_serious",
        "imprecision": "not_serious", "publication_bias": "not_serious"}'::jsonb)$$,
  'høy sikkerhet med utfylte domener er tillatt'
);

-- KNOWLEDGE_MODEL.md §13: bare evidenssynteser og kliniske anbefalinger har en
-- evidensvurdering. Et deterministisk faktum kontrolleres mot kilden sin, ikke
-- med GRADE.
select throws_ok(
  $$select pg_temp.insert_assessment(
      '{"claim_kind": "deterministic_fact", "revision_number": 1}'::jsonb)$$,
  '23514', null,
  'et deterministisk faktum kan ikke få en GRADE-vurdering'
);

-- ---------------------------------------------------------------------------
-- RESTRICT: referert historikk kan ikke slettes bort
-- (DATABASE_ARCHITECTURE.md §36, §37)
-- ---------------------------------------------------------------------------
select throws_ok(
  $$delete from catalog.drugs where canonical_name = 'sertralin'$$,
  '23503', null,
  'et virkestoff en påstand peker på kan ikke slettes'
);
select throws_ok(
  $$delete from catalog.clinical_concepts where canonical_label = 'vektendring'$$,
  '23503', null,
  'et begrep en påstand peker på kan ikke slettes'
);
select throws_ok(
  $$delete from catalog.populations where canonical_label = 'voksne med depressiv lidelse'$$,
  '23503', null,
  'en populasjon en påstandsrevisjon peker på kan ikke slettes'
);
select throws_ok(
  $$delete from knowledge.claims where id = pg_temp.test_claim('evidence_synthesis')$$,
  '23503', null,
  'en påstand med revisjoner kan ikke slettes'
);

select * from finish();

rollback;
