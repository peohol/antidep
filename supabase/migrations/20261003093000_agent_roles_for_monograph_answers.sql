-- ============================================================================
-- Migrasjon 013d — provenance.agent_role får de to monografisvarleddene
--
-- Kildeoppdagelsen trenger ingen nye roller: `source_discovery` og
-- `source_quality_assessment` har stått i vokabularet siden migrasjon 005, som
-- to av de rollene ANTIDEP_CONSTITUTION.md regel 3 krever at KI-arbeidet deles
-- i. Fase C gir dem endelig en skrivevei.
--
-- To roller mangler. En preparatstyrke, en godkjent indikasjon og et attribuert
-- retningslinjeråd er ikke forskningsfunn, og de kan ikke presses inn i
-- ekstraksjonskontrakten: den er bygget for numeriske estimater med arm,
-- komparator, nevner og presisjon (MONOGRAPH_STANDARD.md §9,
-- SOURCE_POLICY.md §2). De trenger sin egen oppgaveform, og dermed sitt eget
-- ledd — og kontrollen av dem trenger sitt eget ledd igjen, fordi en kontroll
-- utført av leddet som lagde innholdet, ikke er en kontroll.
--
--   monograph_answer              — den eksterne KI-agenten som leser en
--                                   regulatorisk kilde eller en retningslinje
--                                   og foreslår det strukturerte svaret
--   monograph_answer_verification — Antideps egen deterministiske kontroll av
--                                   det svaret: at utdraget står ordrett i den
--                                   registrerte representasjonen, at
--                                   lokaliseringen finnes, og at kilden er
--                                   gjeldende
--
-- ----------------------------------------------------------------------------
-- Hvorfor denne ene filen bare legger til verdier
--
-- `ALTER TYPE ... ADD VALUE` kan ikke brukes i samme transaksjon som verdien
-- den legger til, og migrasjonsløperen sender hver fil som én transaksjon.
-- Migrasjonene etter denne bruker verdiene i CASE-uttrykk, funksjonssignaturer
-- og seedrader, og kan derfor ikke også innføre dem. Samme grep som 005a, 008k
-- og 013b.
-- ============================================================================

alter type provenance.agent_role add value 'monograph_answer' after 'evidence_assessment';
alter type provenance.agent_role add value 'monograph_answer_verification'
  after 'monograph_answer';
