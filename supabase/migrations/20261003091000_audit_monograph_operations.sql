-- ============================================================================
-- Migrasjon 013b — audit.event_operation får monografioperasjonene
--
-- Auditvokabularet dekker hver skrivevei som avgjør noe klinisk eller gir en
-- rettighet. Fase C legger til ti slike: bestillingen av en monografi, en
-- menneskelig relevansavgjørelse, et akseptert fagbegrep, en svarrevisjon, en
-- låsing av manuelt rettet innhold, en registrert kildebegrensning, den
-- forseglede monografikandidaten, den navngitte sluttkontrollen, publiseringen
-- og tilbaketrekkingen.
--
-- Pipelinejobbene og søkeloggen er bevisst ikke med. De avgjør ingenting
-- klinisk og gir ingen rettighet; de sier hvilket arbeid som gjenstår og hva
-- som faktisk ble søkt. Sporet deres er append-only tabeller i `workflow`, av
-- samme grunn som `workflow.pipeline_jobs` aldri ble et auditobjekt
-- (migrasjon 009b).
--
-- ----------------------------------------------------------------------------
-- Hvorfor denne ene filen bare legger til verdier
--
-- `ALTER TYPE ... ADD VALUE` kan ikke brukes i samme transaksjon som verdien
-- den legger til, og migrasjonsløperen sender hver fil som én transaksjon.
-- `20261003092000_monograph_order_and_coverage.sql` bygger om CASE-uttrykkene i
-- `audit.events` og `events_snapshot_shape_check` for å dekke verdiene, og kan
-- derfor ikke også innføre dem. Samme grep som 008a, 008b, 008i, 008j og 008k.
--
-- Fram til neste migrasjon har kjørt, kan `audit.events` ikke motta en rad med
-- en av disse operasjonene: `object_schema` og `object_table` ville gitt NULL og
-- feilet på sin egen NOT NULL, og `events_snapshot_shape_check` ville truffet
-- ELSE false.
-- ============================================================================

alter type audit.event_operation add value 'monograph_edition_ordered';
alter type audit.event_operation add value 'monograph_need_relevance_decided';
alter type audit.event_operation add value 'monograph_term_accepted';
alter type audit.event_operation add value 'monograph_answer_revision_created';
alter type audit.event_operation add value 'monograph_answer_lock_changed';
alter type audit.event_operation add value 'monograph_source_restriction_registered';
alter type audit.event_operation add value 'monograph_candidate_built';
alter type audit.event_operation add value 'monograph_final_control_recorded';
alter type audit.event_operation add value 'monograph_published';
alter type audit.event_operation add value 'monograph_publication_withdrawn';
