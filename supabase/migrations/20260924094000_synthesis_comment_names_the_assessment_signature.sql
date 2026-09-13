-- ============================================================================
-- Migrasjon 005ao — kommentaren på synteseveien navngir vurderingsveien med
--                   signaturen sin
--
-- Migrasjon 005am viste til `api.register_evidence_assessment(...)` i
-- kolonnekommentaren sin. Ellipsen er lesbar for et menneske og ubrukelig for
-- vakten: prøve 280 leser hver kommentar i de kanoniske schemaene, plukker ut
-- alt som har kallform, og krever at `to_regprocedure()` finner funksjonen.
-- «`(...)`» er ikke en parameterliste, og oppslaget feiler med «invalid type
-- name».
--
-- Vakten finnes fordi en kommentar som navngir en funksjon som ikke finnes, er
-- en feil ingen oppdager: `catalog.drugs.updated_at` viste i fire migrasjoner
-- til `catalog.set_updated_at()`, som aldri har eksistert. En referanse som skal
-- peke framover på noe som ennå ikke finnes, skrives uten parentes; en som peker
-- på noe som finnes, skrives med signaturen sin.
--
-- Denne migrasjonen skriver bare kommentaren om. Ingen funksjonskropp, ingen
-- rettighet og ingen signatur er endret.
--
-- Fremover-skrivende: 005am er ikke redigert. Den er kjørt i produksjon, og en
-- fersk CI-stack skal få den samme historikken — også når rettelsen er
-- kosmetisk.
-- ============================================================================

comment on function api.register_claim_synthesis(
  text, text, uuid, uuid, uuid, text, text, text, text, jsonb, uuid, uuid,
  text, text, uuid, text, text, numeric, text, text
) is
  'Den kontrollerte skriveveien for at synteseagenten registrerer én påstandsrevisjon med evidensgrunnlaget sitt: påstandsidentiteten (eller en ny revisjon av en som finnes), revisjonen og evidenslenkene, i én transaksjon (ANTIDEP_CONSTITUTION.md §4, §7, §10, §12). Autentiserer identiteten eksplisitt for rollen claim_synthesis og krever en åpen agentkjøring som tilhører den; aktøren radene attribueres til er kjøringens egen og er ikke en parameter. Kunnskapstypen er hardkodet evidence_synthesis: et deterministisk faktum avgjøres mot en autoritativ kilde, og en klinisk anbefaling skal ikke ha en KI-kjøring som opphav. Hvert lenket evidensfunn må ha nådd kontrollnivået EVIDENCE_PIPELINE.md §26 og §27 krever, lest av workflow.assert_evidence_usable_for_synthesis(uuid[]) med publiseringsgatens egne funksjoner. Veien registrerer IKKE evidensvurderingen: den er et annet ansvar, med en egen rolle, en egen identitet og et eget senere ledd — api.register_evidence_assessment(text, text, uuid, uuid, text, text, text, text, text, text, text, text, text, text, text), migrasjon 005am, EVIDENCE_PIPELINE.md §61. Veien godkjenner ingenting: revisjonen er et forslag uten claim-verifikasjon, uten evidensvurdering, uten reviewbeslutning og uten publiseringspeker. SECURITY DEFINER fordi knowledge, catalog og provenance har RLS med default deny; tomt search_path. EXECUTE går til anon og authenticated av samme grunn som de øvrige agentendepunktene: en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';
