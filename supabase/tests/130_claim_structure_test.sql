-- Migrasjon 004 — struktur i påstandslaget.
--
-- Verifiserer at Claims, revisjoner, evidenslenker og evidensvurderinger fra
-- MVP_IMPLEMENTATION_PLAN.md §21 finnes med den identiteten, de vokabularene og
-- de relasjonene DATABASE_ARCHITECTURE.md §13-§15 og §21-§22 krever.
-- Constraint-atferd testes i 140_claim_constraints_test.sql, immutabilitet i
-- 150_claim_immutability_test.sql, tilgang i 160_claim_access_test.sql og selve
-- slicedataene i 170_claim_seed_test.sql.
begin;
\ir fixtures/active_clinical_fixture.inc

create extension if not exists pgtap with schema extensions;

select plan(58);

-- ---------------------------------------------------------------------------
-- Tabellene i migrasjon 004
-- ---------------------------------------------------------------------------
select has_table('knowledge', 'claims', 'knowledge.claims finnes');
select has_table('knowledge', 'claim_revisions', 'knowledge.claim_revisions finnes');
select has_table(
  'knowledge', 'claim_evidence_links', 'knowledge.claim_evidence_links finnes'
);
select has_table(
  'knowledge', 'evidence_assessments', 'knowledge.evidence_assessments finnes'
);

-- ---------------------------------------------------------------------------
-- Kontrollerte vokabularer
-- ---------------------------------------------------------------------------
-- ANTIDEP_CONSTITUTION.md §5: alle tre kunnskapstypene skal kunne uttrykkes, og
-- ingen av dem skal kunne forsvinne senere uten at denne testen sier fra.
select enum_has_labels(
  'knowledge', 'knowledge_type',
  array['deterministic_fact', 'evidence_synthesis', 'clinical_recommendation'],
  'knowledge.knowledge_type dekker de tre kunnskapstypene i konstitusjonen §5'
);

-- Retningen på en påstand er Antideps syntese og har et eget vokabular, uten
-- not_stated: NULL betyr allerede at påstanden ikke uttrykker en retning.
select enum_has_labels(
  'knowledge', 'claim_direction',
  array['increase', 'decrease', 'no_clear_difference'],
  'knowledge.claim_direction skiller retning fra fravær av retning'
);

-- DATABASE_ARCHITECTURE.md §21 og ANTIDEP_CONSTITUTION.md §9: motstridende
-- evidens skal kunne registreres like presist som støttende.
-- KNOWLEDGE_MODEL.md §12 lister neutral/contextual som en egen stance-verdi.
-- Uten den ville et funn som er direkte relevant, men verken støtter eller
-- motsier påstanden, ikke kunne registreres uten samtidig å bli feilmerket som
-- indirekte.
select enum_has_labels(
  'knowledge', 'claim_evidence_relationship',
  array['supports', 'partially_supports', 'contradicts', 'neutral_contextual',
        'indirect'],
  'knowledge.claim_evidence_relationship dekker stance-verdiene i §12 og indirect fra §21'
);
select enum_has_labels(
  'knowledge', 'evidence_directness', array['direct', 'indirect'],
  'knowledge.evidence_directness holder indirekthet som en egen akse'
);
select enum_has_labels(
  'knowledge', 'assessment_framework', array['grade'],
  'knowledge.assessment_framework navngir metoden vurderingen bruker'
);

-- ANTIDEP_CONSTITUTION.md §6 og KNOWLEDGE_MODEL.md §13.1: de fire
-- GRADE-kategoriene, pluss «ingen vurderbar evidens» som en separat
-- systemtilstand. Forsvinner den siste verdien, er konstitusjonskravet borte.
select enum_has_labels(
  'knowledge', 'certainty_level',
  array['high', 'moderate', 'low', 'very_low', 'no_assessable_evidence'],
  'knowledge.certainty_level har ingen vurderbar evidens som egen tilstand'
);
select enum_has_labels(
  'knowledge', 'grade_domain_rating',
  array['not_serious', 'serious', 'very_serious', 'not_assessable'],
  'knowledge.grade_domain_rating skiller et domene som ikke lar seg vurdere fra et som ikke er alvorlig'
);

select is_empty(
  $$
    select t.type_name
    from (values ('knowledge.knowledge_type'), ('knowledge.claim_direction'),
                 ('knowledge.claim_evidence_relationship'),
                 ('knowledge.evidence_directness'),
                 ('knowledge.assessment_framework'), ('knowledge.certainty_level'),
                 ('knowledge.grade_domain_rating')) as t(type_name)
    where has_type_privilege('public', t.type_name, 'usage')
  $$,
  'PUBLIC har ikke usage på noen av påstandstypene'
);

-- ---------------------------------------------------------------------------
-- Stabil identitet og uforanderlige revisjoner (DATABASE_ARCHITECTURE.md §7)
-- ---------------------------------------------------------------------------
select col_is_pk('knowledge', 'claims', 'id', 'knowledge.claims har uuid-primærnøkkel');
select col_is_pk(
  'knowledge', 'claim_revisions', 'id', 'knowledge.claim_revisions har uuid-primærnøkkel'
);
select col_is_pk(
  'knowledge', 'claim_evidence_links', 'id',
  'knowledge.claim_evidence_links har uuid-primærnøkkel'
);
select col_is_pk(
  'knowledge', 'evidence_assessments', 'id',
  'knowledge.evidence_assessments har uuid-primærnøkkel'
);

-- Unik revisjonsnummerering per påstand (MVP_IMPLEMENTATION_PLAN.md §21,
-- DATABASE_ARCHITECTURE.md §14, §58).
select col_is_unique(
  'knowledge', 'claim_revisions', array['claim_id', 'revision_number'],
  'to revisjoner av samme påstand kan ikke ha samme revisjonsnummer'
);

-- DATABASE_ARCHITECTURE.md §15: livssyklusen skal ikke skjules i ett muterbart
-- statusfelt. En status-kolonne her ville vært nettopp det.
select hasnt_column(
  'knowledge', 'claims', 'status',
  'påstandsidentiteten har ingen muterbar statuskolonne (DATABASE_ARCHITECTURE.md §15)'
);
select hasnt_column(
  'knowledge', 'claim_revisions', 'status',
  'revisjonen har ingen muterbar statuskolonne; review og publisering er egne hendelser'
);
select has_column(
  'knowledge', 'claims', 'current_published_revision_id',
  'identiteten har en publiseringspeker (DATABASE_ARCHITECTURE.md §7.2, §13)'
);
select has_column(
  'knowledge', 'claims', 'retired_at',
  'identiteten kan trekkes tilbake uten at historikken slettes'
);

-- ---------------------------------------------------------------------------
-- Relasjoner, med RESTRICT som hovedregel (DATABASE_ARCHITECTURE.md §37).
-- At alle fremmednøkler i knowledge bruker RESTRICT kontrolleres uttømmende i
-- 080_knowledge_structure_test.sql.
-- ---------------------------------------------------------------------------
select fk_ok(
  'knowledge', 'claims', 'topic_concept_id', 'catalog', 'clinical_concepts', 'id',
  'påstanden peker på et klinisk begrep'
);
select fk_ok(
  'knowledge', 'claims', 'subject_drug_id', 'catalog', 'drugs', 'id',
  'påstanden peker på virkestoffet den handler om'
);
select fk_ok(
  'knowledge', 'claim_revisions', 'claim_id', 'knowledge', 'claims', 'id',
  'revisjonen peker på påstandsidentiteten'
);
select fk_ok(
  'knowledge', 'claim_revisions', 'population_id', 'catalog', 'populations', 'id',
  'revisjonen peker på en katalogpopulasjon'
);
select fk_ok(
  'knowledge', 'claim_revisions', 'comparator_drug_id', 'catalog', 'drugs', 'id',
  'komparatorvirkestoffet peker på katalogen'
);
select fk_ok(
  'knowledge', 'claim_evidence_links', 'claim_revision_id',
  'knowledge', 'claim_revisions', 'id',
  'evidenslenken peker på en eksakt påstandsrevisjon (KNOWLEDGE_MODEL.md §19.3)'
);
select fk_ok(
  'knowledge', 'claim_evidence_links', 'evidence_item_id',
  'knowledge', 'evidence_items', 'id',
  'evidenslenken peker på et konkret evidensfunn'
);

-- Cross-row-reglene er løst med sammensatte fremmednøkler, ikke med CHECK som
-- leser andre tabeller (DATABASE_ARCHITECTURE.md §59).
select fk_ok(
  'knowledge', 'claims', array['current_published_revision_id', 'id'],
  'knowledge', 'claim_revisions', array['id', 'claim_id'],
  'publiseringspekeren må peke på en revisjon av samme påstand (§58)'
);
select fk_ok(
  'knowledge', 'claim_revisions', array['claim_id', 'knowledge_type', 'subject_drug_id'],
  'knowledge', 'claims', array['id', 'knowledge_type', 'subject_drug_id'],
  'kunnskapstype og virkestoff på revisjonen er låst til identitetsraden'
);
select fk_ok(
  'knowledge', 'claim_revisions', array['supersedes_revision_id', 'claim_id'],
  'knowledge', 'claim_revisions', array['id', 'claim_id'],
  'en erstattet revisjon må tilhøre den samme påstanden'
);
select fk_ok(
  'knowledge', 'evidence_assessments',
  array['claim_revision_id', 'assessed_knowledge_type'],
  'knowledge', 'claim_revisions', array['id', 'knowledge_type'],
  'evidensvurderingen er låst til kunnskapstypen på revisjonen den vurderer'
);

-- ---------------------------------------------------------------------------
-- Evidenslenker og evidensvurderinger
-- ---------------------------------------------------------------------------
-- DATABASE_ARCHITECTURE.md §21: samme relasjon skal ikke kunne dupliseres.
select col_is_unique(
  'knowledge', 'claim_evidence_links', array['claim_revision_id', 'evidence_item_id'],
  'samme revisjon og samme evidensfunn kan bare kobles én gang'
);
-- DATABASE_ARCHITECTURE.md §22: nøyaktig én eksplisitt vurdering per revisjon.
select col_is_unique(
  'knowledge', 'evidence_assessments', array['claim_revision_id'],
  'en påstandsrevisjon har nøyaktig én evidensvurdering'
);

-- ANTIDEP_CONSTITUTION.md §4: koblingen skal dokumentere hvordan kilden
-- forholder seg til formuleringen. Uten begrunnelse er lenken den kilden §4
-- forbyr å telle som støtte.
select col_not_null(
  'knowledge', 'claim_evidence_links', 'relevance_note',
  'en evidenslenke må begrunne hvorfor funnet har denne relasjonen'
);
select col_not_null(
  'knowledge', 'claim_evidence_links', 'relationship_type',
  'en evidenslenke må ha en eksplisitt relasjonstype'
);
select col_not_null(
  'knowledge', 'claim_evidence_links', 'directness',
  'en evidenslenke må si hvor direkte funnet treffer påstanden'
);

-- ANTIDEP_CONSTITUTION.md §6: sikkerhetsgraden kan aldri stå tom, ellers ville
-- «ingen vurderbar evidens» kunne kollapse til NULL sammen med alt annet.
select col_not_null(
  'knowledge', 'evidence_assessments', 'certainty_level',
  'sikkerhetsgraden er alltid registrert'
);
select col_not_null(
  'knowledge', 'evidence_assessments', 'rationale',
  'en sikkerhetsgrad uten begrunnelse er ikke etterprøvbar'
);
select col_not_null(
  'knowledge', 'evidence_assessments', 'framework',
  'vurderingen navngir alltid metoden den bruker'
);

-- DATABASE_ARCHITECTURE.md §22: sikkerhetsgraden og domenene skal aldri kunne
-- utledes av antall kilder alene. Databasen kan ikke håndheve at en vurdering er
-- faglig riktig, men den kan håndheve at ingen av verdiene har en maskinell
-- opprinnelse: hver av dem må oppgis eksplisitt, uten default og uten å være en
-- generated column. Assertionen fanger en senere migrasjon som legger inn en
-- avledning.
select is_empty(
  $$
    select a.attname::text
    from pg_attribute a
    where a.attrelid = 'knowledge.evidence_assessments'::regclass
      and a.attnum > 0 and not a.attisdropped
      and a.attname::text in ('certainty_level', 'risk_of_bias', 'inconsistency',
                              'indirectness', 'imprecision', 'publication_bias')
      and (a.atthasdef or a.attgenerated <> '' or a.attidentity <> '')
  $$,
  'sikkerhetsgraden og GRADE-domenene har ingen default og er ikke avledet av databasen (DATABASE_ARCHITECTURE.md §22)'
);

-- ---------------------------------------------------------------------------
-- Struktur før fritekst (KNOWLEDGE_MODEL.md §9.2)
-- ---------------------------------------------------------------------------
select col_not_null(
  'knowledge', 'claim_revisions', 'statement',
  'revisjonen har alltid en kanonisk formulering'
);
select col_not_null(
  'knowledge', 'claim_revisions', 'scope',
  'revisjonen sier alltid hva den gjelder for'
);
select col_type_is(
  'knowledge', 'claim_revisions', 'timeframe_min', 'interval',
  'tidsrommet lagres som interval, slik at verdi og enhet ikke kan komme fra hverandre'
);
-- Den strukturerte betydningen skal ikke kunne forsvinne inn i statement.
-- set_eq gjør at både en fjernet og en stille omdøpt kolonne slår ut.
select set_eq(
  $$
    select a.attname::text
    from pg_attribute a
    where a.attrelid = 'knowledge.claim_revisions'::regclass
      and a.attnum > 0 and not a.attisdropped
      and a.attname::text in (
        'population_id', 'timeframe_min', 'timeframe_max', 'comparator_kind',
        'comparator_drug_id', 'direction', 'magnitude_measure', 'magnitude_value',
        'magnitude_unit', 'qualifiers', 'uncertainty_summary'
      )
  $$,
  $$values ('population_id'), ('timeframe_min'), ('timeframe_max'), ('comparator_kind'),
           ('comparator_drug_id'), ('direction'), ('magnitude_measure'),
           ('magnitude_value'), ('magnitude_unit'), ('qualifiers'),
           ('uncertainty_summary')$$,
  'populasjon, tidsrom, komparator, retning, størrelse, forbehold og usikkerhet finnes som egne kolonner (KNOWLEDGE_MODEL.md §9.2)'
);

-- ---------------------------------------------------------------------------
-- Append-only-tabellene har bevisst ingen updated_at
-- ---------------------------------------------------------------------------
select hasnt_column(
  'knowledge', 'claim_revisions', 'updated_at',
  'en uforanderlig revisjon har ingen updated_at'
);
select hasnt_column(
  'knowledge', 'claim_evidence_links', 'updated_at',
  'en uforanderlig evidenslenke har ingen updated_at'
);
select hasnt_column(
  'knowledge', 'evidence_assessments', 'updated_at',
  'en uforanderlig evidensvurdering har ingen updated_at'
);
-- Identiteten er derimot muterbar: publiseringspeker og tilbaketrekking endres
-- over tid, og da skal databasen eie tidsstemplene.
select has_column(
  'knowledge', 'claims', 'updated_at',
  'påstandsidentiteten har updated_at, fordi livssyklusfeltene kan endres'
);

-- ---------------------------------------------------------------------------
-- Triggerne som bærer immutabiliteten og det databaseeide fingeravtrykket
-- ---------------------------------------------------------------------------
select has_trigger(
  'knowledge', 'claims', 'claims_set_row_timestamps',
  'knowledge.claims får created_at og updated_at satt av databasen'
);
select has_trigger(
  'knowledge', 'claims', 'claims_freeze_identity',
  'knowledge.claims har en immutable-row guard på identitetsfeltene'
);
select has_trigger(
  'knowledge', 'claim_revisions', 'claim_revisions_set_content_hash',
  'knowledge.claim_revisions får content_hash satt av databasen'
);
select has_trigger(
  'knowledge', 'claim_revisions', 'claim_revisions_reject_mutation',
  'knowledge.claim_revisions er append-only'
);
select has_trigger(
  'knowledge', 'claim_evidence_links', 'claim_evidence_links_reject_mutation',
  'knowledge.claim_evidence_links er append-only'
);
select has_trigger(
  'knowledge', 'evidence_assessments', 'evidence_assessments_reject_mutation',
  'knowledge.evidence_assessments er append-only'
);
-- Tverradsinvariantene som append-only alene ikke dekker: evidenssettet
-- forsegles av vurderingen, og videreføringskjeden er monoton.
select has_trigger(
  'knowledge', 'claim_evidence_links', 'claim_evidence_links_reject_after_assessment',
  'evidenssettet til en revisjon forsegles når revisjonen får sin evidensvurdering'
);
select has_trigger(
  'knowledge', 'claim_revisions', 'claim_revisions_enforce_supersedes_order',
  'en revisjon kan bare erstatte en revisjon med lavere revisjonsnummer'
);

-- content_hash på en revisjon er bevisst ikke unik (DATABASE_ARCHITECTURE.md
-- §14.1). Med UNIQUE ville en ny revisjon som bare retter et feil sett av
-- evidenslenker eller en feil GRADE-vurdering blitt avvist som dublett, fordi
-- selve formuleringen er uendret — og feilen hadde vært umulig å rette, siden
-- lenkene og vurderingen er append-only. Assertionen holder valget fast, slik
-- at en senere migrasjon ikke kan innføre sperren uten å ta stilling til den.
select is_empty(
  $$
    select ix.indexrelid::regclass::text as unique_object
    from pg_index ix
    where ix.indrelid = 'knowledge.claim_revisions'::regclass
      and ix.indisunique
      and exists (
        select 1 from pg_attribute a
        where a.attrelid = ix.indrelid
          and a.attnum = any (ix.indkey)
          and a.attname = 'content_hash'
      )
  $$,
  'content_hash på en revisjon er ikke unik, slik at korreksjonsveien via ny revisjon forblir åpen'
);

select * from finish();

rollback;
