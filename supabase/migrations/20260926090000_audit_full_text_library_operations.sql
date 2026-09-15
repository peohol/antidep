-- ============================================================================
-- Migrasjon 009 — audit.event_operation får verdiene fulltekstbiblioteket,
--                 modellrollene og kandidaten trenger
--
-- Fire skriveveier kommer i migrasjonene 009a, 009c og 009d, og alle fire lager
-- eller avgjør noe DATABASE_ARCHITECTURE.md §35 krever et spor av:
--
--   source_document_stored             en originalfil er lagt i det private
--                                      biblioteket, bundet til en publikasjon
--   role_model_assignment_registered   hvilken modell en agentrolle får handle
--                                      som — den mest sikkerhetskritiske
--                                      innstillingen i kjeden etter rolletildeling
--   candidate_built                    et agentferdig kandidatinnhold er forseglet
--   candidate_final_control_recorded   en navngitt fagperson har sluttkontrollert
--                                      nøyaktig den kandidaten
--
-- Uten verdiene ville de fire skriveveiene enten måttet skrive uten spor, eller
-- ført sporet under en operasjon som beskrev noe annet. Begge deler er verre enn
-- ingen auditrad: en logg som er stille akkurat der avgjørelsen ble tatt, ser ut
-- som en logg.
--
-- ----------------------------------------------------------------------------
-- Hvorfor denne filen ikke gjør noe annet
--
-- Samme grunn som i 008a, 008b, 008i, 008j og 008k: `ALTER TYPE ... ADD VALUE`
-- kan ikke brukes i samme transaksjon som verdien den legger til, og
-- migrasjonsløperen sender hver fil som én transaksjon
-- (scripts/deploy-migrations.sh). Migrasjon 009a bygger om CASE-uttrykkene i
-- audit.events sine genererte kolonner og events_snapshot_shape_check for å
-- dekke verdiene, og kan derfor ikke også innføre dem.
--
-- Fram til 009a har kjørt, kan audit.events ikke motta en rad med noen av disse
-- operasjonene: object_schema og object_table ville gitt NULL og feilet på sin
-- egen NOT NULL, og events_snapshot_shape_check ville truffet ELSE false.
-- ============================================================================

alter type audit.event_operation add value 'source_document_stored';
alter type audit.event_operation add value 'role_model_assignment_registered';
alter type audit.event_operation add value 'candidate_built';
alter type audit.event_operation add value 'candidate_final_control_recorded';
