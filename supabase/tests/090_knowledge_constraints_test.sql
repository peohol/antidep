-- Migrasjon 003 — deklarative constraints og FK-integritet i knowledge.
--
-- DATABASE_ARCHITECTURE.md §57 krever at integritet håndheves deklarativt i
-- databasen, §58 lister invariantene som minst skal håndheves, §59 krever at
-- cross-row-regler bruker riktig mekanisme, og §67 krever at constraints, FK-er
-- og negative stier faktisk testes. Hver regel testes både positivt og negativt.
--
-- Særlig vekt på null/ukjent-semantikken i §19.1 og ANTIDEP_CONSTITUTION.md §6:
-- «ikke målt», «ikke rapportert» og «ingen klar forskjell» er tre forskjellige
-- tilstander, og ingen av dem skal kunne kollapse til en naken NULL.
--
-- SQLSTATE: 23502 not_null_violation, 23503 foreign_key_violation,
-- 23505 unique_violation, 23514 check_violation, 22P02 invalid_text_representation.
begin;

create extension if not exists pgtap with schema extensions;

select plan(60);

-- ---------------------------------------------------------------------------
-- Testdata som bare finnes inne i denne transaksjonen
-- ---------------------------------------------------------------------------

-- Migrasjon 005 gjorde created_by_actor_id påkrevd på kunnskapsobjektene
-- (ANTIDEP_CONSTITUTION.md §14). Testdata attribueres til den samme aktøren som
-- produserte de seedede radene, slik at fikstursradene ikke er mindre
-- attribuerte enn kunnskapsbasen ellers.
create function pg_temp.extraction_actor() returns uuid language sql stable as $$
  select id from provenance.actors where actor_key = 'agent:evidence-extraction'
$$;

insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
values ('journal_article', 'Testkilde om vektendring', 'Testforfatter T', pg_temp.extraction_actor());

insert into knowledge.source_versions
  (source_id, retrieved_at, retrieved_from, retrieved_by_actor_id)
select id, now(), 'https://example.invalid/testkilde', pg_temp.extraction_actor()
from knowledge.sources where title = 'Testkilde om vektendring';

insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
values ('journal_article', 'Annen testkilde', 'Testforfatter A', pg_temp.extraction_actor());

-- Kortform for et gyldig evidensfunn, slik at hver negativ test bare varierer
-- den ene kolonnen den handler om.
create function pg_temp.insert_evidence(
  overrides jsonb default '{}'::jsonb
) returns void language plpgsql as $$
declare
  payload jsonb;
begin
  payload := jsonb_build_object(
    'population_availability', 'reported_value',
    'population_detail', 'Voksne med depressiv lidelse i testdata',
    'sample_size', 100,
    'sample_size_availability', 'reported_value',
    'comparator_kind', 'none',
    'outcome_detail', 'Gjennomsnittlig vektendring i testdata',
    'timepoint_min', '8 weeks',
    'timepoint_max', '8 weeks',
    'timepoint_availability', 'reported_value',
    'reported_direction', 'increase',
    'effect_measure', 'mean_change',
    'estimate', 1.5,
    'estimate_unit', 'kg',
    'estimate_availability', 'reported_value',
    'confidence_interval_availability', 'not_reported',
    'source_locator', 'Sammendrag, avsnittet RESULTS',
    'extraction_method', 'ai_assisted'
  ) || overrides;

  insert into knowledge.evidence_items (
    source_id, design_code, population_id, population_availability, population_detail,
    sample_size, sample_size_availability, intervention_drug_id, comparator_kind,
    comparator_drug_id, outcome_concept_id, outcome_detail,
    timepoint_min, timepoint_max, timepoint_availability,
    reported_direction, effect_measure, estimate, estimate_unit, estimate_availability,
    ci_lower, ci_upper, ci_level_percent, confidence_interval_availability,
    source_locator, extraction_method, created_by_actor_id
  )
  select
    (select id from knowledge.sources where title = 'Testkilde om vektendring'),
    'randomized_controlled_trial',
    case when payload ? 'population_id_null' then null
         else (select id from catalog.populations
               where canonical_label = 'voksne med depressiv lidelse') end,
    (payload ->> 'population_availability')::knowledge.value_availability,
    payload ->> 'population_detail',
    (payload ->> 'sample_size')::integer,
    (payload ->> 'sample_size_availability')::knowledge.value_availability,
    (select id from catalog.drugs where canonical_name = 'sertralin'),
    (payload ->> 'comparator_kind')::knowledge.comparator_kind,
    case when payload ->> 'comparator_drug' is null then null
         else (select id from catalog.drugs
               where canonical_name = payload ->> 'comparator_drug') end,
    (select id from catalog.clinical_concepts where canonical_label = 'vektendring'),
    payload ->> 'outcome_detail',
    (payload ->> 'timepoint_min')::interval,
    (payload ->> 'timepoint_max')::interval,
    (payload ->> 'timepoint_availability')::knowledge.value_availability,
    (payload ->> 'reported_direction')::knowledge.effect_direction,
    (payload ->> 'effect_measure')::knowledge.effect_measure,
    (payload ->> 'estimate')::numeric,
    (payload ->> 'estimate_unit')::knowledge.estimate_unit,
    (payload ->> 'estimate_availability')::knowledge.value_availability,
    (payload ->> 'ci_lower')::numeric,
    (payload ->> 'ci_upper')::numeric,
    (payload ->> 'ci_level_percent')::numeric,
    (payload ->> 'confidence_interval_availability')::knowledge.value_availability,
    payload ->> 'source_locator',
    (payload ->> 'extraction_method')::knowledge.extraction_method,
    pg_temp.extraction_actor();
end;
$$;

-- ---------------------------------------------------------------------------
-- knowledge.sources — bibliografisk identitet
-- ---------------------------------------------------------------------------
select lives_ok(
  $$insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
    values ('clinical_guideline', 'Gyldig testretningslinje', 'Testutgiver',
            pg_temp.extraction_actor())$$,
  'en gyldig kilde kan registreres'
);
select throws_ok(
  $$insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
    values ('journal_article', '', 'Testforfatter', pg_temp.extraction_actor())$$,
  '23514', null,
  'en kilde uten tittel avvises'
);
select throws_ok(
  $$insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
    values ('journal_article', '  ledende blanktegn  ', 'Testforfatter',
            pg_temp.extraction_actor())$$,
  '23514', null,
  'en tittel med omkringliggende blanktegn avvises'
);
select throws_ok(
  $$insert into knowledge.sources (source_type, title, authors_or_issuer, created_by_actor_id)
    values ('preprint', 'Ukjent kildetype', 'Testforfatter', pg_temp.extraction_actor())$$,
  '22P02', null,
  'en kildetype utenfor det kontrollerte vokabularet avvises'
);

-- Datoen og presisjonen hører sammen, og datoen skal ikke bære mer presisjon
-- enn den er belagt for (ANTIDEP_CONSTITUTION.md §6).
select lives_ok(
  $$insert into knowledge.sources
      (source_type, title, authors_or_issuer, publication_date, publication_date_precision,
       created_by_actor_id)
    values ('journal_article', 'Kilde med årpresisjon', 'Testforfatter',
            date '2005-01-01', 'year', pg_temp.extraction_actor())$$,
  'en kilde som bare er årfestet kan registreres med årpresisjon'
);
select throws_ok(
  $$insert into knowledge.sources
      (source_type, title, authors_or_issuer, publication_date, created_by_actor_id)
    values ('journal_article', 'Dato uten presisjon', 'Testforfatter', date '2005-04-07',
            pg_temp.extraction_actor())$$,
  '23514', null,
  'en publiseringsdato uten presisjonsnivå avvises'
);
select throws_ok(
  $$insert into knowledge.sources
      (source_type, title, authors_or_issuer, publication_date_precision, created_by_actor_id)
    values ('journal_article', 'Presisjon uten dato', 'Testforfatter', 'year',
            pg_temp.extraction_actor())$$,
  '23514', null,
  'et presisjonsnivå uten dato avvises'
);
select throws_ok(
  $$insert into knowledge.sources
      (source_type, title, authors_or_issuer, publication_date, publication_date_precision,
       created_by_actor_id)
    values ('journal_article', 'Falsk årpresisjon', 'Testforfatter',
            date '2005-04-07', 'year', pg_temp.extraction_actor())$$,
  '23514', null,
  'en dato som ikke er avkortet til årpresisjon avvises som falsk presisjon'
);
select throws_ok(
  $$insert into knowledge.sources
      (source_type, title, authors_or_issuer, publication_date, publication_date_precision,
       created_by_actor_id)
    values ('journal_article', 'Falsk månedspresisjon', 'Testforfatter',
            date '2005-04-07', 'month', pg_temp.extraction_actor())$$,
  '23514', null,
  'en dato som ikke er avkortet til månedspresisjon avvises'
);
select lives_ok(
  $$insert into knowledge.sources
      (source_type, title, authors_or_issuer, publication_date, publication_date_precision,
       created_by_actor_id)
    values ('journal_article', 'Ekte dagpresisjon', 'Testforfatter',
            date '2005-04-07', 'day', pg_temp.extraction_actor())$$,
  'en dato med reell dagpresisjon er tillatt'
);

-- DATABASE_ARCHITECTURE.md §58: en tilbaketrukket kilde skal ikke kunne bli det
-- stille.
select throws_ok(
  $$update knowledge.sources set source_status = 'retracted'
    where title = 'Annen testkilde'$$,
  '23514', null,
  'en kilde kan ikke settes til retracted uten begrunnelse'
);
select lives_ok(
  $$update knowledge.sources
    set source_status = 'retracted',
        status_note = 'Trukket tilbake av tidsskriftet i testdata'
    where title = 'Annen testkilde'$$,
  'en tilbaketrekking med begrunnelse er tillatt'
);
select throws_ok(
  $$update knowledge.sources set superseded_by_source_id = id
    where title = 'Gyldig testretningslinje'$$,
  '23514', null,
  'en kilde kan ikke erstatte seg selv'
);
select throws_ok(
  $$
    update knowledge.sources
    set superseded_by_source_id =
      (select id from knowledge.sources where title = 'Annen testkilde')
    where title = 'Gyldig testretningslinje'
  $$,
  '23514', null,
  'en erstatningspeker krever status superseded'
);

-- Motsatt retning: statusen skal ikke kunne love en erstatning som ikke finnes.
select throws_ok(
  $$
    update knowledge.sources
    set source_status = 'superseded', status_note = 'Erstattet i testdata'
    where title = 'Gyldig testretningslinje'
  $$,
  '23514', null,
  'statusen superseded uten erstatningspeker avvises'
);
select lives_ok(
  $$
    update knowledge.sources
    set source_status = 'superseded',
        status_note = 'Erstattet i testdata',
        superseded_by_source_id =
          (select id from knowledge.sources where title = 'Annen testkilde')
    where title = 'Gyldig testretningslinje'
  $$,
  'status og erstatningspeker kan settes sammen'
);

-- Vaktposten skal ikke overblokkere: en kilde som er utdatert uten at en
-- bestemt etterfølger er registrert, hører til outdated og trenger ingen peker.
select lives_ok(
  $$
    update knowledge.sources
    set source_status = 'outdated', status_note = 'Utdatert uten registrert etterfølger'
    where title = 'Ekte dagpresisjon'
  $$,
  'en utdatert kilde uten registrert etterfølger er tillatt'
);

-- ---------------------------------------------------------------------------
-- knowledge.source_identifiers — globale identifikatorer
-- ---------------------------------------------------------------------------
select lives_ok(
  $$
    insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
    select id, 'doi', '10.1000/testkilde.001'
    from knowledge.sources where title = 'Testkilde om vektendring'
  $$,
  'en gyldig DOI kan registreres'
);
select throws_ok(
  $$
    insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
    select id, 'doi', '10.1000/TESTKILDE.002'
    from knowledge.sources where title = 'Testkilde om vektendring'
  $$,
  '23514', null,
  'en DOI med store bokstaver avvises, slik at unikhetsregelen ikke kan omgås'
);
select throws_ok(
  $$
    insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
    select id, 'doi', 'ikke-en-doi'
    from knowledge.sources where title = 'Testkilde om vektendring'
  $$,
  '23514', null,
  'en DOI med feil format avvises deklarativt'
);
select throws_ok(
  $$
    insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
    select id, 'pmid', '0123'
    from knowledge.sources where title = 'Testkilde om vektendring'
  $$,
  '23514', null,
  'en PMID med ledende null avvises'
);
select throws_ok(
  $$
    insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
    select id, 'doi', '10.1000/testkilde.001'
    from knowledge.sources where title = 'Annen testkilde'
  $$,
  '23505', null,
  'samme DOI kan ikke peke på to kilder'
);
select throws_ok(
  $$
    insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
    values (gen_random_uuid(), 'pmid', '999999')
  $$,
  '23503', null,
  'en identifikator for en ukjent kilde avvises'
);

-- ---------------------------------------------------------------------------
-- knowledge.source_versions — øyeblikksbilder
-- ---------------------------------------------------------------------------
select throws_ok(
  $$
    insert into knowledge.source_versions
      (source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
    select id, now(), 'https://example.invalid/annen', 'ikke-en-hash',
           pg_temp.extraction_actor()
    from knowledge.sources where title = 'Annen testkilde'
  $$,
  '23514', null,
  'en content_hash uten algoritmeprefiks og riktig lengde avvises'
);
select throws_ok(
  $$
    insert into knowledge.source_versions
      (source_id, retrieved_at, retrieved_from, retrieved_by_actor_id)
    select id, now(), '   ', pg_temp.extraction_actor()
    from knowledge.sources where title = 'Annen testkilde'
  $$,
  '23514', null,
  'en kildeversjon uten hentaddresse avvises'
);
select lives_ok(
  $$
    insert into knowledge.source_versions
      (source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
    select id, now(), 'https://example.invalid/testkilde/2',
           'sha256:' || repeat('a', 64), pg_temp.extraction_actor()
    from knowledge.sources where title = 'Testkilde om vektendring'
  $$,
  'et nytt øyeblikksbilde med ny hash kan registreres'
);
select throws_ok(
  $$
    insert into knowledge.source_versions
      (source_id, retrieved_at, retrieved_from, content_hash, retrieved_by_actor_id)
    select id, now(), 'https://example.invalid/testkilde/3',
           'sha256:' || repeat('a', 64), pg_temp.extraction_actor()
    from knowledge.sources where title = 'Testkilde om vektendring'
  $$,
  '23505', null,
  'samme innhold av samme kilde kan ikke registreres to ganger'
);

-- Attribusjon og tidsretning på observasjonen (migrasjon 20260907091000).
select throws_ok(
  $$
    insert into knowledge.source_versions (source_id, retrieved_at, retrieved_from)
    select id, now(), 'https://example.invalid/uten-aktor'
    from knowledge.sources where title = 'Annen testkilde'
  $$,
  '23502', null,
  'en kildeversjon uten aktør som hentet den avvises'
);
select throws_ok(
  $$
    insert into knowledge.source_versions
      (source_id, retrieved_at, retrieved_from, retrieved_by_actor_id)
    select id, now() + interval '1 day', 'https://example.invalid/framtiden',
           pg_temp.extraction_actor()
    from knowledge.sources where title = 'Annen testkilde'
  $$,
  '23514', null,
  'en kildeversjon hentet fram i tid avvises'
);

-- RESTRICT: en referert kilde kan ikke slettes bort
-- (DATABASE_ARCHITECTURE.md §36, §37).
select throws_ok(
  $$delete from knowledge.sources where title = 'Testkilde om vektendring'$$,
  '23503', null,
  'en kilde med registrerte identifikatorer og versjoner kan ikke slettes'
);

-- ---------------------------------------------------------------------------
-- knowledge.evidence_items — null/ukjent-semantikk (§19.1)
-- ---------------------------------------------------------------------------
select lives_ok(
  $$select pg_temp.insert_evidence()$$,
  'et gyldig evidensfunn kan registreres'
);

-- Et rapportert nullfunn er en verdi, ikke et fravær.
select lives_ok(
  $$select pg_temp.insert_evidence(
      '{"reported_direction": "no_clear_difference", "estimate": 0,
        "source_locator": "Sammendrag, nullfunn"}'::jsonb)$$,
  'et nullfunn registreres som estimat 0 med retning no_clear_difference'
);

-- «Ikke målt» og «ikke rapportert» er egne tilstander, og begge krever at
-- verdikolonnen faktisk er tom.
select lives_ok(
  $$select pg_temp.insert_evidence(
      '{"estimate": null, "estimate_availability": "not_measured",
        "source_locator": "Sammendrag, ikke maalt"}'::jsonb)$$,
  'et utfall kilden ikke målte registreres som not_measured uten verdi'
);
select lives_ok(
  $$select pg_temp.insert_evidence(
      '{"estimate": null, "estimate_availability": "not_reported",
        "source_locator": "Sammendrag, ikke rapportert"}'::jsonb)$$,
  'et utfall kilden ikke oppgir registreres som not_reported uten verdi'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"estimate": null, "estimate_availability": "reported_value"}'::jsonb)$$,
  '23514', null,
  'en manglende verdi kan ikke merkes som rapportert'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"estimate": 1.5, "estimate_availability": "not_reported"}'::jsonb)$$,
  '23514', null,
  'en verdi kan ikke stå i kolonnen samtidig som den er merket ikke rapportert'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"sample_size": null, "sample_size_availability": "reported_value"}'::jsonb)$$,
  '23514', null,
  'et manglende utvalg kan ikke merkes som rapportert'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"population_id_null": true, "population_availability": "reported_value"}'::jsonb)$$,
  '23514', null,
  'en manglende populasjonskobling kan ikke merkes som rapportert'
);
select lives_ok(
  $$select pg_temp.insert_evidence(
      '{"population_id_null": true, "population_availability": "not_extractable",
        "source_locator": "Sammendrag, uten populasjonskobling"}'::jsonb)$$,
  'et funn uten populasjonskobling er tillatt når statusen forklarer hvorfor'
);

-- uncertain_extraction er den ene andre tilstanden der en verdi faktisk står i
-- kolonnen: verdien er lest ut, men ekstraksjonen er usikker.
select lives_ok(
  $$select pg_temp.insert_evidence(
      '{"sample_size_availability": "uncertain_extraction",
        "source_locator": "Sammendrag, usikkert utvalg"}'::jsonb)$$,
  'en usikker ekstraksjon kan beholde verdien og merkes som usikker'
);

-- ---------------------------------------------------------------------------
-- knowledge.evidence_items — representative invariants (§58)
-- ---------------------------------------------------------------------------
select throws_ok(
  $$select pg_temp.insert_evidence('{"sample_size": 0}'::jsonb)$$,
  '23514', null,
  'et utvalg på null deltakere avvises'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"timepoint_min": "12 weeks", "timepoint_max": "8 weeks"}'::jsonb)$$,
  '23514', null,
  'et invertert oppfølgingsintervall avvises'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"estimate": null, "estimate_availability": "not_reported",
        "ci_lower": 2.0, "ci_upper": 0.5, "ci_level_percent": 95,
        "confidence_interval_availability": "reported_value"}'::jsonb)$$,
  '23514', null,
  'et invertert konfidensintervall avvises'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"estimate": 9.0, "ci_lower": 0.5, "ci_upper": 2.0, "ci_level_percent": 95,
        "confidence_interval_availability": "reported_value"}'::jsonb)$$,
  '23514', null,
  'et estimat utenfor sitt eget konfidensintervall avvises'
);
select lives_ok(
  $$select pg_temp.insert_evidence(
      '{"estimate": 1.5, "ci_lower": 0.5, "ci_upper": 2.0, "ci_level_percent": 95,
        "confidence_interval_availability": "reported_value",
        "source_locator": "Sammendrag, med konfidensintervall"}'::jsonb)$$,
  'et estimat innenfor konfidensintervallet er tillatt'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"ci_lower": 0.5, "ci_upper": 2.0, "ci_level_percent": null,
        "confidence_interval_availability": "reported_value"}'::jsonb)$$,
  '23514', null,
  'et konfidensintervall uten oppgitt nivå avvises'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"effect_measure": "risk_ratio", "estimate": -1.2, "estimate_unit": null}'::jsonb)$$,
  '23514', null,
  'et negativt forholdstall avvises'
);
select throws_ok(
  $$select pg_temp.insert_evidence('{"estimate_unit": null}'::jsonb)$$,
  '23514', null,
  'et dimensjonalt effektmål uten enhet avvises'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"effect_measure": "risk_ratio", "estimate": 1.2, "estimate_unit": "kg"}'::jsonb)$$,
  '23514', null,
  'et dimensjonsløst effektmål med enhet avvises'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"effect_measure": null, "estimate_unit": null}'::jsonb)$$,
  '23514', null,
  'et estimat uten effektmål avvises'
);
select throws_ok(
  $$select pg_temp.insert_evidence('{"comparator_drug": "mirtazapin"}'::jsonb)$$,
  '23514', null,
  'en komparator uten kategorien drug avvises'
);
select throws_ok(
  $$select pg_temp.insert_evidence('{"comparator_kind": "drug"}'::jsonb)$$,
  '23514', null,
  'kategorien drug uten oppgitt komparatorvirkestoff avvises'
);
select throws_ok(
  $$select pg_temp.insert_evidence(
      '{"comparator_kind": "drug", "comparator_drug": "sertralin"}'::jsonb)$$,
  '23514', null,
  'et virkestoff kan ikke være sin egen komparator'
);
select lives_ok(
  $$select pg_temp.insert_evidence(
      '{"comparator_kind": "drug", "comparator_drug": "mirtazapin",
        "source_locator": "Sammendrag, med komparator"}'::jsonb)$$,
  'et funn med et registrert komparatorvirkestoff er tillatt'
);
select throws_ok(
  $$select pg_temp.insert_evidence('{"source_locator": "   "}'::jsonb)$$,
  '23514', null,
  'et evidensfunn uten presis kildepeker avvises (KNOWLEDGE_MODEL.md §11.2)'
);

-- ---------------------------------------------------------------------------
-- Cross-row-regler løst deklarativt (§59)
-- ---------------------------------------------------------------------------
-- En kildeversjon som tilhører en annen kilde skal avvises av den sammensatte
-- fremmednøkkelen, ikke av applikasjonskode.
select throws_ok(
  $$
    insert into knowledge.evidence_items (
      source_id, source_version_id, design_code, population_availability, population_detail,
      sample_size_availability, intervention_drug_id, comparator_kind,
      outcome_concept_id, outcome_detail, timepoint_availability,
      reported_direction, estimate_availability, confidence_interval_availability,
      source_locator, extraction_method, created_by_actor_id
    )
    select
      (select id from knowledge.sources where title = 'Annen testkilde'),
      (select v.id from knowledge.source_versions v
       join knowledge.sources s on s.id = v.source_id
       where s.title = 'Testkilde om vektendring' limit 1),
      'randomized_controlled_trial', 'not_extractable', 'Testpopulasjon',
      'not_reported',
      (select id from catalog.drugs where canonical_name = 'sertralin'),
      'none',
      (select id from catalog.clinical_concepts where canonical_label = 'vektendring'),
      'Testutfall', 'not_reported', 'not_stated', 'not_reported', 'not_reported',
      'Sammendrag', 'ai_assisted', pg_temp.extraction_actor()
  $$,
  '23503', null,
  'en kildeversjon som tilhører en annen kilde avvises av den sammensatte fremmednøkkelen'
);

-- Endepunktet må være et begrep av typen outcome; en diagnose er ikke et utfall.
select throws_ok(
  $$
    insert into knowledge.evidence_items (
      source_id, design_code, population_availability, population_detail,
      sample_size_availability, intervention_drug_id, comparator_kind,
      outcome_concept_id, outcome_detail, timepoint_availability,
      reported_direction, estimate_availability, confidence_interval_availability,
      source_locator, extraction_method, created_by_actor_id
    )
    select
      (select id from knowledge.sources where title = 'Testkilde om vektendring'),
      'randomized_controlled_trial', 'not_extractable', 'Testpopulasjon',
      'not_reported',
      (select id from catalog.drugs where canonical_name = 'sertralin'),
      'none',
      (select id from catalog.clinical_concepts where canonical_label = 'depressiv lidelse'),
      'Testutfall', 'not_reported', 'not_stated', 'not_reported', 'not_reported',
      'Sammendrag', 'ai_assisted', pg_temp.extraction_actor()
  $$,
  '23503', null,
  'et begrep av typen condition kan ikke brukes som endepunkt'
);

-- Rå ekstraksjon skal være et objekt, ikke en løs skalar (§20).
select throws_ok(
  $$
    insert into knowledge.evidence_items (
      source_id, design_code, population_availability, population_detail,
      sample_size_availability, intervention_drug_id, comparator_kind,
      outcome_concept_id, outcome_detail, timepoint_availability,
      reported_direction, estimate_availability, confidence_interval_availability,
      source_locator, extraction_method, raw_extraction, created_by_actor_id
    )
    select
      (select id from knowledge.sources where title = 'Testkilde om vektendring'),
      'randomized_controlled_trial', 'not_extractable', 'Testpopulasjon',
      'not_reported',
      (select id from catalog.drugs where canonical_name = 'sertralin'),
      'none',
      (select id from catalog.clinical_concepts where canonical_label = 'vektendring'),
      'Testutfall', 'not_reported', 'not_stated', 'not_reported', 'not_reported',
      'Sammendrag', 'ai_assisted', '"en løs streng"'::jsonb, pg_temp.extraction_actor()
  $$,
  '23514', null,
  'rå ekstraksjon må være et objekt, ikke en løs skalar'
);

-- Katalograder som evidens peker på kan ikke slettes bort.
select throws_ok(
  $$delete from catalog.drugs where canonical_name = 'sertralin'$$,
  '23503', null,
  'et virkestoff evidens peker på kan ikke slettes'
);
select throws_ok(
  $$delete from catalog.populations where canonical_label = 'voksne med depressiv lidelse'$$,
  '23503', null,
  'en populasjon evidens peker på kan ikke slettes'
);

select * from finish();

rollback;
