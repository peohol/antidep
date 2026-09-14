# Antidep 2 — operasjonell plan for Codex

**Dato:** 14. september 2026  
**Analysert repo:** `peohol/antidep`  
**Kodegrunnlag:** `ed5a0a60e0cc37f13b00d7974d3035d4cefcb8da` (etter PR 89)  
**Status:** Implementeringsoppdrag, ikke ferdig implementasjon. Planleggingen har ikke endret kode eller databaseinnhold.  
**Mandat:** Peder har uttrykkelig bedt om ny visjon, fjerning av foreldet dokumentasjon og kode, og nullstilling av eksperimentelt faglig innhold. Dette er en kontrollert preproduksjonsreset, ikke en generell adgang til å slette klinisk historikk.

## 1. Leveransen og grensene

Lag **én sammenhengende reset-PR**: kort og konsistent dokumentasjon, fjernet gammelt produktgrensesnitt, et ærlig minimalt appskall, bevart nyttig agent-/datainfrastruktur, fulltekstbarrierer og en testet reset av aktivt prototypeinnhold.

Arbeid i interne etapper, men ikke lag en PR per filgruppe. Denne leveransen skal gjøre den neste leveransen enkel: **fra en fulltekst i kildebiblioteket til et agentkontrollert, lesbart produktutkast i det faktiske klinikergrensesnittet**.

Ikke bygg den komplette nye klinikerflaten, et nytt designsystem, en generell arbeidsflytmotor eller alle nye modelladaptere i reset-PR-en. Ikke bytt React/Vite/Supabase eller oppgrader avhengigheter uten en konkret nødvendighet. Ikke omtal en tom app eller en innspilt modellrespons som en ferdig autonom kunnskapspipeline.

**Ingen operasjoner mot hostet database i Codex-oppgaven.** Lag og test migrasjoner og en driftsbeskrivelse; faktisk utrulling og datarydding skjer først etter teknisk review av implementasjons-PR-en, i rett miljø og med sikkerhetskopi. En kode-PR som ikke er deployet, har ikke ryddet produksjonsdata.

## 2. Hva repoanalysen faktisk viser

Dette er holdepunktene for planen, ikke antakelser om hva en plattform eller modell kan gjøre:

| Observert i kodegrunnlaget | Betydning for resetten |
| --- | --- |
| `src/agents/agent-api.ts` importerer `Database` fra `src/types/database.ts` og `Uuid` fra `src/types/api.ts`. | Frontend og agenter deler kontrakter. Ikke slett hele `src/types` eller `src/lib` sammen med UI-et. |
| `src/agents/model-adapters.ts` registrerer bare `recorded`. | En innebygd, løpende modellleverandør er ikke implementert. En separat runtimeleveranse gjenstår. |
| `src/agents/claim-checks.ts` lar bevisst deler stå `not_assessable`; kontrollen kan ikke alene gi en full bekreftelse. | Ikke gjør algoritmen til en falsk semantisk verifikator for å slippe menneskelige klikk. |
| `src/agents/source-binding.ts` støtter både netttekst og dokumentbundet tekst; dokumentoppslaget går via `DocumentLookup`. | Gjenbruk grensen. Nettbasert abstract-henting kan beholdes for discovery, men må stenges som klinisk evidensvei. Senere kobles privat fillager til dokumentoppslaget. |
| `20260916090000_source_document_fingerprint.sql` lagrer fingeravtrykk/oppskrift, ikke originalfilen. | Permanent dokumentlagring er et faktisk manglende produktledd, ikke noe et nytt navn på et felt løser. |
| `scripts/verify-counts.sh` leser den gamle MVP-planens tall og PR-historikk; CI krever skriptet. | Sletting av planen krever samtidig at denne utdaterte kontrollen erstattes. |
| Flere pgTAP-tester, blant annet `250_publication_gate_test.sql`, slår opp Fava-/Versiani-funn fra migrert seed. | Lag isolerte testfiksturer før resetten. En tom aktiv kunnskapsbase må være testbar. |
| `tests/api-vocabularies.test.ts` og `tests/api-columns.test.ts` kontrollerer kontraktene, ikke bare skjermbilder. | Behold vernet; tilpass kontraktene bevisst når frontend-RPC-er trekkes tilbake. |
| `scripts/db-lock-test.sh` og `scripts/agent-chain-test.ts` ligger utenfor pgTAP-suiten. | Fullført pgTAP er ikke nok. Begge integrasjonsløp må fortsatt kjøres. |
| Siste eksisterende migrasjon heter `20260924095000_assessment_author_mandate_is_a_gate.sql`. | En ny fil med dagens datoprefiks ville havnet før allerede anvendte filer. Velg ID etter den største eksisterende ID-en. |
| De gamle `discard_unpublished_*`-funksjonene nekter å fjerne menneskekontrollert innhold. | De kan ikke brukes som om denne engangsresetten var vanlig redaksjonell sletting. Ikke svekk dem globalt. |
| `workflow.assert_claim_verified_before_assessment(uuid)` og evidensvurdererens egen rolle finnes etter PR 89. | Behold skillet mellom syntese, kildestøttekontroll og evidensvurdering. Ikke gjeninnfør de rettede feilene. |
| `.github/workflows/vercel.yml` deployer ved push til `main`. De to gamle verifikasjonsarbeidsflytene bruker `workflow_dispatch`. | Ikke legg reset i frontendbygg eller npm-livssyklusskript. Ikke beskriv de gamle verifikasjonsjobbene som en eksisterende autonom orkestrering. |

Analysen gjelder repoet. Antall og publiseringsstatus for dagens hostede rader er **ikke** verifisert her. Ingen konkrete live-rader skal slettes ut fra UUID-er eller antall nevnt i en gammel samtale.

## 3. Autoritativ produktretning

### 3.1 Menneskets normale oppgave

Mennesket skaffer fulltekster som systemet mangler, vurderer det ferdige klinikerproduktet før publisering og er navngitt faglig ansvarlig. Felt-for-felt-kontroll og transport av JSON-filer er ikke normal redaktørarbeidsflyt.

Sluttkontrollen skal bruke **samme visningskode og samme konkrete innhold** som klinikeren får, inkludert forklaringer, kildegrunnlag, usikkerhet og relevante kildeutdrag. En redaktør får tilleggshandlingene Godkjenn for publisering, Be om endringer og Avvis. En godkjenning av en side eller en faglig seksjon kan omfatte flere eksplisitt identifiserte påstandsrevisjoner; den skal ikke kreve ett menneskelig klikk per databaseobjekt.

Godkjenningen må senere bindes til nøyaktig kandidatversjon: publiseringstekst, påstandsrevisjoner, evidenssett, vurderinger og faglig betydningsfulle forklaringer. Endring i disse gir ny kandidat og ny sluttgodkjenning. At gamle claim-revisjoner er uforanderlige, er ikke alene nok når ny redaksjonell prosa legges utenpå dem.

### 3.2 Agentenes oppgave

Den logiske kjeden er:

```text
Klinisk spørsmål og kildeplan
  -> discovery og prioritering
  -> komplett fulltekst tilgjengelig og kontrollert
  -> kildevurdering og studie-/rapportkobling
  -> ekstraksjon
  -> separat ekstraksjonsverifikasjon
  -> syntese og atomiske påstandsrevisjoner
  -> separat motprøving, med supplerende søk ved behov
  -> kildestøtteverifikasjon av det reviderte forslaget
  -> separat evidens-/GRADE-vurdering
  -> redaksjonell formulering
  -> kontroll av at sluttteksten ikke har endret den faglige meningen
  -> agentferdig publiseringskandidat
  -> menneskelig sluttkontroll
  -> eksplisitt publisering av akkurat den kandidaten
```

Ved en faglig endring går berørte deler gjennom kontroll igjen. Samme bibliotek/modell kan gjenbrukes, men en ny rolleetikett på det samme ukontrollerte svaret er ikke uavhengig kontroll. Kontrollagenten får originalgrunnlaget og skal lete etter feil, ikke bare bekrefte generatorens forklaring.

**Tre ting må skilles:** usikkerhet i forskningen, uenighet mellom agenter og en teknisk mislykket kontroll. Svak evidens kan beskrives redelig og komme til sluttkontroll. Manglende kildetilgang, feil tall, feil kilde eller en kontroll som aldri kjørte kan ikke omdøpes til et faglig forbehold. Agentene forsøker avgrenset korreksjon selv; antall forsøk og ressursbruk skal begrenses. Teknisk feil er ikke et klinisk spørsmål Peder skal løse.

Bevar korte, kildeforankrede begrunnelser, funn og løsninger. Ikke krev private interne tankerekker fra modellene. Enighet mellom agenter er ikke i seg selv et sannhetsbevis; kvalitet skal undersøkes med positive tester og målrettet feilinjeksjon.

### 3.3 Fulltekstregelen

For forskningsbasert klinisk innhold er abstract, bibliografiske metadata, registeromtale og andre begrensede representasjoner **discovery-only**. De kan begrunne at en publikasjon bør skaffes, aldri en klinisk konklusjon, heller ikke indirekte ved å kopiere resultatet inn i synteseteksten.

En komplett systematisk oversikt er fortsatt en fulltekstkilde. «Sekundærstudie» er ikke det samme som «bare sekundæromtale av en kilde man ikke har lest». Når Antidep bruker en oversikt, skal ikke de underliggende primærstudiene utgis for selv å være lest eller telles som uavhengige kilder flere ganger.

Avgrens reset-implementasjonens dokumentvei til fulltekst-PDF, som dagens dokumentkode kan håndtere. Ikke lag nye unntaksveier for forskningsabstract. Andre komplette autoritative kildetyper kan senere få en eksplisitt dokumentpolicy; katalogidentiteter og tekniske begreper er ikke forskningssynteser som skal tømmes.

En PDF-signatur eller `representation = full_text` er ikke bevis for at riktig, komplett publikasjon er lest. Den kommende opplastingsflyten skal kontrollere publikasjonstilhørighet, lesbarhet og nødvendig innhold, inkludert tabeller/tillegg når de bærer konklusjonen.

### 3.4 Klinikerproduktet

Leseren møter en sammenhengende faglig framstilling, ikke en liste med tekniske felter. Nødvendige forbehold som endrer klinisk mening skal stå synlig i hovedteksten, ikke skjules i et lukket detaljeelement.

Progressiv fordypning skal følge denne rekkefølgen:

```text
Hva sier Antidep, og hvor sikkert er det?
  -> Hvorfor sier Antidep dette?
    -> Studier, relevante funn og motstridende resultater
      -> Ordrette utdrag med tilstrekkelig sammenheng og lokalisering
        -> Kildeversjon, korte kontrollrapporter og øvrig proveniens
```

Gjenta ikke en lang artikkeltittel foran hver setning. Bruk korte kildehenvisninger som kan åpnes. Fullteksttilgang og rett til offentlig gjengivelse er separate spørsmål: originalfiler er private, og offentlige utdrag må ha tillatt omfang. Manglende fulltekst må framgå som mulig dekningsmangel, ikke som at den utilgjengelige studien hadde et bestemt resultat.

Interne agentutkast skal være tilgangsbegrensede og merket «Eksperimentelt utkast – ikke faglig godkjent». Bruk samme framtidige renderer som ved publisering, men aldri samme ufiltrerte offentlige datatilgang. En advarselstekst alene er ikke tilgangskontroll.

## 4. Behold/slett/endre-matrise for kode

Bruk matrisen som utgangspunkt. Dokumenter avvik kort med faktisk avhengighet. Filnavn er ikke alene bevis for at noe er foreldet.

| Område | Beslutning i reset-PR-en |
| --- | --- |
| `src/app/pages/` | Fjern den gamle sidenes produktlogikk og tilhørende UI-tester. Bygg et minimalt nytt skall, ikke en modifisert review-wizard. Auth kan gjenbrukes som teknikk, men gammel AccessPage er ikke et bindende design. |
| `src/app/App.tsx`, `App.test.tsx`, `routes.ts`, `routes.test.ts` | Erstatt med nye, små innganger og tester. Gamle `/review`, `/extraction-review` og manuelle registreringsruter skal ikke fortsatt starte arbeidsflyten, heller ikke via direkte URL. |
| `src/app/ClaimGroups*`, `extraction-session-handlers.ts`, `test-support.tsx` | Fjern gammel presentasjon og mikroreview-fiksturer. Lag liten ny appfikstur ved behov. |
| `src/app/antidep-client*`, `use-auth-session*`, `use-page-title.ts` | Behold tekniske deler som det nye skallet faktisk bruker. Ikke flytt eller skriv om fungerende autentisering bare for kosmetisk opprydding. |
| `src/app/use-read-model*`, `slug-resolution.ts` | Fjern dersom bare gamle sider bruker dem. Behold bare med en konkret, testet forbruker. |
| `src/components/ControlWizard.tsx`, `CheckpointPanes.tsx`, `ExtractionControlIntro.tsx`, `ExtractionFieldStep.tsx`, `claim-control-steps.tsx`, `extraction-control-steps.tsx` | Fjern. Ingen erstatningsveiviser med de samme ja/nei-spørsmålene. |
| Øvrige gamle komponenter: `ClaimCard*`, `ClaimCertainty*`, `EvidenceFinding*`, `ExtractionDossier*`, `ReviewDossier.tsx`, `SourceDetails*`, `SourceAccessCaveat.tsx`, `SourceLink.tsx`, `KnowledgeNotice*`, `DetailList.tsx` | Fjern den gamle visningsarkitekturen. Flytt bare konkret gjenbrukt ren domenelogikk ut før sletting; ikke behold skjermbilder av den gamle datamodellen «for sikkerhets skyld». |
| `src/components/vocabulary-labels.ts` | Ikke slett før importene er undersøkt. Bevar fortsatt brukte faglige etiketter som ren modul, eventuelt i `src/lib`; fjern wizard-spørsmål og utdaterte sammenlimte setninger. |
| `src/lib/control-session*`, `control-steps*`, `claim-checkpoint-context*`, `register-human-claim-verification.ts`, `register-human-extraction-verification.ts` | Fjern gammel menneskelig delkontrollkode og dens UI-spesifikke tester. Behold ikke disse som obligatorisk fallback for manglende ny agentkode. |
| `src/lib/review-workspace*`, `extraction-review*`, `create-evidence-item*`, `evidence-registration*`, `create-source*`, `create-source-version*`, `editor-read-model*`, `publish-claim-revision.ts`, `register-publication-approval.ts`, `source-choice*`, `read-utf8-file*`, `local-datetime*` | Fjern når siste gamle frontendforbruker er borte. Dette gjelder klienthjelpere, ikke automatisk databasefunksjonene med samme navn. Behold eventuelle reelle agent-/driftsavhengigheter med begrunnelse. |
| `src/lib/supabase*`, `caller-authorization*`, `evidence-item*`, `claim-effect*`, `claim-certainty*`, `source-identifier*`, `source-links.ts`, `norwegian-format*`, `readable-excerpt*`, `publication-date*`, `slug*`, `published-read-model*`, `extraction-statements*` | Vurder som delte domene-/kontraktmoduler. Behold dem som trengs av beholdt kode eller fortsatt relevante kontrakttester. Fjern gammel UI-formatering som ikke har en slik rolle. Unngå en blind sletting av `src/lib`. |
| `src/types/api.ts`, `src/types/database.ts` | Behold og beskjær eksplisitt bare utgåtte frontendkontrakter. `AgentDatabase` bygger på dem. Gjennomfør type- og API-kontrakttester etter endring. |
| `src/agents/` | Behold motoren og regresjonstestene. Tilpass kliniske innganger til fulltekstregelen. Skil skillene i dokumentasjonen mellom ekte kontroller, opptaksadapter og manglende semantiske agentledd. Ikke skriv om hele agentmappen. |
| `src/ops/migration-plan*`, `scripts/deploy-migrations.sh`, `scripts/issue-agent-credential.sh` | Behold driftsmekanismer. Oppdater utdaterte dokumentlenker. Ikke kjør dem mot hostet prosjekt i oppgaven. |
| `src/ops/extraction-assignment*` og agent-CLI-er | Behold nødvendige interne kontrakter og testgrensesnitt. De skal ikke beskrives som oppgaver Peder må utføre. Erstatt filtransport som produktarbeidsflyt i neste leveranse, ikke fjern fungerende kode før en faktisk forbruker er undersøkt. |
| `src/main.tsx`, `src/index.css`, `index.html` | Behold React-inngangen, erstatt gamle stiler og visningskoblinger. Skallet skal ikke vise gamle kliniske tekster eller hente ukontrollerte utkast offentlig. |
| `.claude/routines/ekstraksjonsoppdrag.md`, `.claude/skills/ekstraksjon/SKILL.md` | Fjern de gamle oppdriftsoppskriftene som produktinstruksjoner. Ta med varige sikkerhetsregler i ny leverandøruavhengig dokumentasjon før de slettes. Ingen rutine skal fortsatt instruere Peder om manuell JSON-transport. |
| `.github/workflows/extraction-verification.yml`, `claim-verification.yml` | Ta de gamle nett-/abstract-orienterte driftsinngangene ut av aktiv bruk. Behold selve testbare verifikatorene. En ny varig jobbkjede bygges med privat fullteksttilgang, ikke en workflow som hopper over nettopp fulltekstene. |
| `.github/workflows/ci.yml`, `vercel.yml` | Behold bygg og tester. Oppdater CI for ny dokumentkontroll og testfiksturer. Reset skal aldri kjøres automatisk av Vercel eller `npm install`. PR-kode skal ikke få produksjonshemmeligheter. |

Lag først en importoversikt fra beholdte innganger: agent-CLI-er, `src/ops`, `scripts/agent-chain-test.ts`, det nye appskallet og kontrakttestene. Undersøk også filstier brukt som tekst i tester og skript. Typecheck alene finner ikke slike filoppslag.

Ikke behold ubrukte UI-tester for å øke antall tester. Ikke slett domene-/sikkerhetstester fordi UI-et fjernes. Den testede egenskapen, ikke testens navn, avgjør.

## 5. Dokumentasjonen skal bli liten og entydig

Skriv om disse filene, fremfor å legge nye unntak oppå gammel historie:

| Fil | Ansvar etter reset |
| --- | --- |
| `README.md` | Hva Antidep er, hva som faktisk finnes nå, hvordan utvikling/test startes, lenke til roadmap. Ingen påstander om en autonom runtime som ikke finnes. |
| `AGENTS.md` | Felles kort inngang for kodeagenter, verifikasjonskommandoer og sikkerhetsgrenser. |
| `CLAUDE.md` | Kort henvisning til felles instrukser og eventuelle genuint Claude-spesifikke forhold. Ikke en konkurrerende policy. |
| `docs/ANTIDEP_CONSTITUTION.md` | Ny eksplisitt versjon med agent-first, fulltekstkrav, sluttproduktkontroll og navngitt menneskelig publiseringsansvar. Dokumenter at retningsendringen er eierbestilt. |
| `docs/EVIDENCE_PIPELINE.md` | Den ene ønskede kjeden fra spørsmål til kandidat; separat tydelig oversikt over implementerte og manglende ledd. |
| `docs/CONTENT_GOVERNANCE.md` | Beslutninger, endringssløyfe, tilgang, utkast kontra publisering, foreldelse og tilbakerulling. Ingen obligatorisk menneskelig mikroreview. |
| `docs/KNOWLEDGE_MODEL.md` | Kilde, kildeversjon, studie/rapport, evidensfunn, påstand, vurdering og framtidig publiseringskandidat. Skill eksisterende tabeller fra begreper som ennå ikke har skjema. |
| `docs/DATABASE_ARCHITECTURE.md` | Faktisk beholdt skjema, sikkerhetsgrenser, invariants og migrasjonspraksis. Ikke skriv framtidige tabeller som om de finnes. |
| `docs/PRODUCT_INFORMATION_ARCHITECTURE.md` | Klinikerlesing, utbrettbar forklaring, kildemangler og sluttkontroll i samme produktvisning. |
| Ny `docs/ROADMAP.md` | Kort, produktorientert prioritert plan med første hele lesbare leveranse. Ikke en ny PR-krønike. |
| `supabase/README.md` | Kjørbare lokale test-/driftsinstrukser og klart skille mellom lokal reset og hostet utrulling. |

Slett `docs/MVP_IMPLEMENTATION_PLAN.md` og `docs/ROUTINE_EXTRACTION.md`. Omskriv README-ene under `assignments/`, `proposals/`, `assessments/`, `syntheses/` og `documents/` til korte interne kontraktbeskrivelser der kode fortsatt bruker mappene. Behold `.gitignore`-vern mot hemmeligheter, fulltekster og lokale forslag.

Historikk finnes i Git. Ikke flytt hundretusener av tegn til et nytt `docs/legacy/` som agenter fortsatt forventes å lese. Migrasjonskommentarer er historiske forklaringer og skal ikke omskrives for nye paragrafnumre. Den nye dokumentasjonen skal si at gamle paragrafhenvisninger gjelder dokumentversjonen ved den migrasjonens commit.

Erstatt `scripts/verify-counts.sh` og tilhørende CI-steg med en liten relevant repokontroll, for eksempel `npm run verify:repo`: fungerende aktive dokumentlenker, ingen utgåtte produktinnganger, konsistente felles instrukser og uendrede legacy-migrasjoner. Behold den eksisterende testen for Data API-eksponering; ikke reduser sikkerhet til tekstsøk. Unngå nye manuelt vedlikeholdte opptellinger av PR-er, tester eller enum-er i prosa.

## 6. Database: presis ombygging, ikke blanket-sletting

### 6.1 Bevar disse grensene

Behold alle eksisterende migrasjonsfiler uendret. Ta en sjekksumliste over dem **før** kodearbeidet og bruk den i en test som feiler ved endring/sletting. Nye filer skal sortere etter høyeste eksisterende ID; bruk ikke dagens dato ukritisk. Enum-utvidelse og første bruk av ny verdi må være i separate committebare migrasjoner.

Behold:

- `catalog` og katalogdata, inkludert legemiddel-/begrepsidentiteter.
- Autentisering, `provenance.actors`, agentidentiteter/legitimasjon og `workflow.user_roles`.
- Kildeforankring, kontrollroller/mandat, uforanderlige revisjoner, evidenssettets forsegling og historikkmekanismer.
- Separate skriveveier for `claim_synthesis` og `evidence_assessment`, og vern mot egenverifikasjon.
- `workflow.assert_evidence_usable_for_synthesis`, `workflow.assert_claim_verified_before_assessment`, `knowledge.assert_claim_revision_ready_for_approval` og publiseringskjernens øvrige kontroller, med målrettede utvidelser.
- Sikkerhetskritiske interne hjelpefunksjoner selv om navnet inneholder `review`, `human` eller `dossier`.

### 6.2 Gamle frontend-RPC-er

Kartlegg eksakte signaturer med `pg_proc`, kildehenvisninger og tester. Trekk tilbake klienttilgang til de utdaterte inngangene for menneskelig delkontroll og manuell mellomobjektregistrering:

- `api.claim_review_workspace`
- `api.extraction_review_workspace`
- `api.register_human_claim_verification`
- `api.register_human_extraction_verification`
- den gamle frontendinngangen `api.create_evidence_item` når den bare tjener den fjernede skjermflyten.

Ingen «review_queue»-funksjon skal antas å finnes bare fordi det finnes en QueuePage; de gamle køene bruker workspace-funksjonene med tomt objektvalg.

Skill gamle klientinnganger fra intern publiseringskjerne. Den gamle frontendveien gjennom `api.register_publication_approval` / `api.publish_claim_revision` skal ikke presenteres som den nye sluttproduktgodkjenningen. Trekk tilbake dens klienttilgang under resetten, og bevar/test den interne godkjennings- og publiseringslogikken for gjenbruk. Ny kandidatbundet produktpublisering aktiveres først i den sammenhengende produktleveransen. Dette er en lukking av en utgått inngang, ikke fjerning av kravet om menneskelig sluttgodkjenning.

Bruk `REVOKE` fra relevante klientroller som første trygge utfasing. Fjern en funksjon fysisk bare når ingen beholdt SQL-, trigger-, test- eller agentavhengighet trenger den. Ikke bruk `DROP ... CASCADE` for å slippe avhengighetsanalysen. Oppdater tilgangstestene til å bevise både at utgåtte innganger er lukket og at beholdte agentinnganger fortsatt virker.

Behold kilde-/kildeversjonsregistrering som intern byggestein for den kommende opplastingen. At en skjerm slettes, betyr ikke at kildeidentitet eller dokumentregistrering er foreldet.

## 7. Reset av faglig prototypeinnhold

### 7.1 Hva «tom» betyr

Den **aktive kliniske kunnskapen** skal være tom: ingen gamle evidensfunn, synteser, vurderinger, godkjenninger eller publiseringskandidater skal framstå som Antidep 2-innhold eller brukes som grunnlag i en ny kjøring.

Bevar reelle kildemetadata og eventuelle originalfiler som kildebibliotek, ikke som godkjent klinisk kunnskap. Bevar sikkerhets-/auditspor og historiske avsluttede agentkjøringer. Det er forskjell på å kassere en gammel tolkning og å slette dokumentet man senere vil lese på nytt. Ikke slett private originalfiler som del av en SQL-reset.

Dette presiserer den tidligere, for vide oppryddingsprompten: vi skal nullstille resultatene, ikke ødelegge kildebibliotek, tilgang eller muligheten til å forstå tidligere feil.

### 7.2 Konkret avgrenset reset

Forbered en egen fremoverrettet **engangsmigrasjon**, etter omleggingen av tester. Operasjonen skal ikke bli et varig klienttilgjengelig slette-API.

Målgruppen er de eksisterende avledede prototyperadene i:

```text
workflow.claim_verification_citations
workflow.claim_verifications
workflow.evidence_verifications
workflow.review_decisions
knowledge.evidence_assessments
knowledge.claim_evidence_links
knowledge.claim_revisions
knowledge.claims
knowledge.evidence_field_groundings
knowledge.evidence_items
```

`knowledge.publication_events` er en **stoppbetingelse**, ikke historikk som skal slettes for å få resetten gjennom. Dersom den ikke er tom, eller en claim har publiseringspeker, skal hele operasjonen stoppe uten sletting. En tidligere tilbaketrukket publisering teller også. Denne planen autoriserer ikke tap av faktisk publisert historikk.

Kontroller tabell- og FK-listen mot den faktiske databasen. Ikke finn på manglende tabeller, og ikke bruk mønstre som `TRUNCATE knowledge.*` eller en kaskade som også treffer beholdte data.

### 7.3 Reversibel fjerning fra aktiv drift

Før sletting lagres et privat, uforanderlig reset-snapshot i et snevert auditobjekt, for eksempel `audit.prototype_resets`, med unik reset-ID, kodegrunnlag, tidspunkt, begrunnelse, nøyaktige mål-ID-er, før-antall, innhold og fingeravtrykk. Det er en teknisk engangshendelse autorisert av eierens resetbeslutning, **ikke** en oppdiktet innlogget faglig godkjenning fra Peder.

Snapshot skal ikke kunne leses eller skrives av `anon`, vanlig `authenticated` eller agentidentiteter. Ingen av de nye kliniske spørringene skal behandle det som evidens. Behold original auditlogg; ikke slett historiske auditrader fordi de peker på objekter som inngår i det private snapshotet.

Ta alle nødvendige låser før snapshot og validering. Nekter en vakt, skal både sletting og snapshottransaksjon rulles tilbake. Resetten skal stoppe hvis det finnes åpne agentkjøringer. Før hostet utrulling må gamle kjørere være stoppet; en avsluttet gammel kjøring skal ikke senere kunne skrive via `assert_agent_run_open`.

Fjern målrader i eksplisitt FK-rekkefølge. Ved sykliske henvisninger brukes eksisterende utsettbare constraints der de finnes, eller en eksplisitt, avgrenset tabelloperasjon som lar alle FK-er bestå. Ikke slå av `session_replication_role`, RLS eller alle triggere. Dersom append-only-mutasjonsvakter må omgås for denne ene eieroperasjonen, avgrens det til navngitte vakter i samme transaksjon, og test at alle vakter og grants er tilbake etterpå. Ikke svekk de ordinære `discard_unpublished_*`-funksjonene.

Resettens omfang må fryses ved første vellykkede kjøring. En omkjøring skal ikke slette nytt Antidep 2-innhold som kom senere; bruk unik reset-ID og verifiser denne egenskapen i en regresjonstest.

### 7.4 Hostet utrulling er en egen kontrollert handling

Legg en kort kjørbar runbook i PR-en: identifiser rett Antidep-prosjekt, stopp gamle jobber, ta privat databaseeksport, kontroller eventuelle Storage-filer separat, prøv gjenoppretting i et isolert miljø, vis målrader/antall og stoppbetingelser, kjør de reviewede migrasjonene, og kontroller beholdt tilgang og tom aktiv kunnskap etterpå.

Ingen hemmeligheter, private snapshots eller reelle databaseeksporter i repo, PR-kommentarer eller offentlige Actions-artefakter. Supabase databasebackup omfatter ikke selve Storage-filene; lagring og metadata må ikke forveksles. Denne leveransen skal ikke få Codex til å be Peder gjøre SQL-arbeidet manuelt.

## 8. Fulltekstbarrierer i denne resetten

Implementer én gjenbrukbar intern fulltekstkontroll og bruk den i kliniske registrerings-/synteseinnganger samt sluttgaten. Den skal minst kreve:

- eksisterende, eksplisitt `source_version_id` som tilhører riktig kilde;
- `representation = full_text`;
- komplett dokumentbinding med fingeravtrykk, positiv filstørrelse og tillatt medietype;
- komplett og tillatt tekstekstraksjonsoppskrift samt tekstfingeravtrykk;
- ikke tilbaketrukket kilde, sammen med eksisterende kontroller.

Ingen særunntak for de gamle Fava-/Versiani-radene. For andre lenkerelasjoner skal abstract heller ikke kunne smugles inn som klinisk dokumentasjon. Discoveryopplysninger om en kilde som mangler fulltekst skal bo i kandidat-/kildesporet, ikke som et klinisk EvidenceItem.

Vakten skal brukes av eksisterende faktiske skriveveier, ikke bare av en ny funksjon som ingen kaller. Behold grensene mellom generator, registrar og verifikator. I TypeScript skal kliniske runner-innganger stoppe tidlig med en forståelig grunn før de prøver å behandle et abstract. La generisk nett-/metadatahenting være tilgjengelig for discovery.

**Ikke påstå at dette etablerer permanent fulltekstlagring.** Dagens `storage_reference` er ikke bevis for at en fil finnes eller er validert. Resetten innfører fulltekst-/dokumentbarrieren og tar den gamle publiseringsinngangen ut av bruk. Før den nye publiseringsflyten aktiveres må neste leveranse bevise privat varig lagring, publikasjonstilhørighet, serverkontrollert filidentitet og dokumenttilgang for alle kontrollledd. Et tilfeldig ikke-tomt lagringsfelt skal aldri åpne denne senere gaten.

## 9. Testomlegging uten å miste læringen

### 9.1 Isolerte fiksturer

Testsuiten skal kjøre når aktive kliniske tabeller er tomme. Opprett syntetiske kilder, dokumentbundne kildeversjoner, funn og påstander i den enkelte testtransaksjonen. Gjenbruk en liten testhjelper der den faktisk reduserer duplisering; den skal bare lastes i testløp og ikke fra `supabase/seed.sql` eller en produksjonsmigrasjon.

Hvis en delt SQL-include brukes, bekreft at den fungerer gjennom den pinnede `supabase test db`-kjøreren. Legg den slik at den ikke oppdages som en egen pgTAP-test. Ikke anta at et nytt testverktøy er nødvendig; egne testtransaksjoner er en gyldig enkel løsning.

Behold realistiske syntetiske dokumenter i Poppler-/leserekkefølgetester. Ikke legg opphavsrettslige fulltekster i repoet. En eksplisitt syntetisk testkilde kan ha farmakologiske feltnavn, men må ikke bli seede som klinisk innhold.

### 9.2 Prioriterte eksisterende testsamlinger

- `120_knowledge_seed_test.sql` og `170_claim_seed_test.sql`: erstatt forventningen om eksisterende klinisk seed med tester for tom aktiv kunnskap og beholdt katalog/kildebibliotek etter reset.
- `130`–`160`, `190`, `200`, `240`–`290`, `320`, `330`, `390` og senere tester som slår opp gamle funn: bygg eget nødvendig grunnlag; ikke gjeninnfør global faglig seed.
- `500`, `520`, `540`, `550`: gammel menneskelig delkontroll/workspace-tilgang skal ikke fortsatt testes som aktiv produktflate. Flytt varige integritets-/mandattester til beholdt kjerne og test at de gamle klientinngangene nå er stengt.
- `510`, `530`, `560`, `570`: skill mellom bevart intern sluttgodkjennings-/publiseringslogikk og de gamle frontend-RPC-ene som er tatt ut av bruk. Ikke slett kravet om navngitt menneskelig sluttgodkjenning.
- `600`, `610`, `620`, `630`, `640`, `650`, `660`: bevar kilde-/grunnlagsbinding, kontrollrekkefølge og presis fraværssemantikk. Tilpass fiksturene, ikke resultatene for å få grønt.
- `670`, `680`: bevar vern mot ordinær vilkårlig sletting. Engangsresetten skal ha egne tester og ikke bruke en permanent svekket discard-vei.
- `690`, `700`, `710`: bevar regresjonene fra PR 89, særlig separat evidensvurderer og blokkering av feil vurderingsopphav.
- `scripts/review-decision-race-fixture.sql`, `scripts/discard-claim-race-fixture.sql`, `scripts/db-lock-test.sh`, `scripts/agent-chain-test.ts`: undersøk i tillegg til pgTAP. De var kilde til tidligere CI-regresjoner.
- `tests/api-vocabularies.test.ts`, `api-columns.test.ts`, `data-api-exposure.test.ts` og relevante agenttester: behold reell kontrakt-/sikkerhetsdekning.

For hver beholdt gate: et gyldig grunnlag må passere, og når akkurat den prøvde egenskapen svekkes, må akkurat den riktige feilen oppstå. «Kallet kaster et eller annet unntak» er ikke tilstrekkelig. En ny fulltekstfeil skal ikke skjule at for eksempel en samtidighetsprøve aldri nådde reviewrekkefølgen den skulle teste.

### 9.3 Nye obligatoriske regresjoner

1. Fersk database gjennom alle migrasjoner ender uten gamle aktive funn/påstander; katalog, brukertilgang og agentidentiteter er intakte.
2. Eksisterende prototypeinnhold med menneskelige kontroller kan tas ut av aktiv drift av den avgrensede resetten, og finnes i privat snapshot etterpå.
3. Publisert eller tidligere publisert innhold stopper hele resetten. Uventede FK-er eller åpne agentkjøringer stopper uten halvryddet tilstand.
4. Etter en vellykket reset kan en omkjøring ikke slette et nytt syntetisk Antidep 2-funn.
5. Abstract, ukjent representasjon, manglende dokumentbinding og kilde-/versjonsmismatch kan ikke bære klinisk registrering/syntese. En gyldig fulltekstkilde kan passere de nye strukturelle vaktene.
6. Et pent filnavn, en PDF-signatur eller et fritt valgt `storage_reference` gir ikke i seg selv en bekreftelse av korrekt kilde eller framtidig publiserbar kandidat.
7. Utgåtte klient-RPC-er er stengt; beholdte agent-RPC-er har fortsatt minstetilgang og avviser feil rolle/egenverifikasjon.
8. Usikkerhet, manglende data og feil fra database/nett kan ikke gjøres om til «verified» eller «succeeded» uten dekning. Behold SQLSTATE-regresjonene fra PR 89.
9. Skallet viser ingen gamle kliniske tekster, ingen manuelle kontrollveivisere og ingen fungerende gamle direkte-URL-er. Internt utkast er ikke offentlig data.
10. Alle legacy-migrasjoner er byte-for-byte uendret, aktive dokumentlenker virker, og ingen produksjonsseed fyller den kliniske basen på nytt.

## 10. Rekkefølge inni samme PR

### A. Etabler utgangspunktet

Les denne planen, sjekklisten, gjeldende `package.json`, CI og relevante SQL-definisjoner. Registrer utgangs-SHA og sjekksummer for gamle migrasjoner. Les import-/SQL-avhengigheter og kjør tilgjengelige baselinetester. Noter faktiske miljømangler; ikke bruk hostet database som erstatning for lokal test.

### B. Bytt de aktive instruksjonene

Revider konstitusjonen og skriv korte gjeldende dokumenter. Fjern den gamle MVP-planen sammen med koblingen i `verify-counts`. Ikke la historisk «minste mulige PR» eller obligatorisk mikroreview overstyre det nye eierbestilte oppdraget.

### C. Frigjør tester fra faglig seed

Lag testfiksturene først. Kjør pgTAP og begge eksterne integrasjonsløp med kontrollerte testdata. Etter dette skal det ikke finnes en usynlig avhengighet av at produksjonen har en bestemt artikkel eller claim.

### D. Gjennomfør databaseendringen lokalt

Nye migrasjoner for klientutfasing, fulltekstbarrierer og avgrenset, reversibel aktiv-innholdsreset. Kontroller rettigheter, FK-er, mutasjonsvern, reset-snapshot og feil/rollback. Test både oppgradering fra det gamle grunnlaget med testdata og fersk installasjon.

### E. Fjern gammel frontend og lag rent skall

Slett de utgåtte visningene, klienthjelperne og stilene etter avhengighetsmatrisen. Behold en enkel app som forklarer eksperimentstatus og ikke viser oppdiktet innhold. Ingen falske opplastings-/godkjenningsknapper som ser ferdige ut.

### F. Kontroller hele leveransen

Kjør kommandoene under, inspiser relevante endringer og skriv en kort teknisk leveranserapport. Opprett én PR. Ikke merge. Hvis miljøet mangler Docker, må CI bevise databasebiten før PR-en kan vurderes som ferdig; det skal ikke «løses» ved å fjerne den CI-jobben.

Bruk et kort arbeidsnotat underveis for fullførte etapper, endrede kontrakter og gjenværende testfeil. Ved avbrudd: fortsett fra siste etappe i samme oppdrag/branch. Ikke start arkitekturdebatten på nytt og ikke lever bare mer planlegging når implementering er bestilt.

## 11. Codex-miljø og verifikasjonskommandoer

Repoet krever Node `>=22.22.2`; bruk `.nvmrc` og den pinnede lockfilen. Supabase CLI ligger allerede som utviklingsavhengighet, versjon `2.115.0` i analysert `package.json`. Poppler er nødvendig for reelle dokument-/leserekkefølgetester. Docker/Supabase-stakk trengs for database- og kjedeprøver.

Codex skal selv undersøke `node --version`, `npm --version`, `pdftotext -v`, `docker info` og avhengighetene. Ikke anta at det å finne Docker-binæren betyr at en daemon kan brukes. Ikke oppgrader verktøy vilkårlig for å skjule et oppsettsproblem.

```sh
npm ci
npm run lint
npm run format:check
npm run typecheck
npm run test
npm run build
# Etter at gammel verify-counts er erstattet:
npm run verify:repo
# Bare mot lokal/isolert stakk:
npm run db:start
npm run db:reset
npm run db:test
npm run db:test:lock
npm run db:test:chain
npm run db:stop
```

Kjør gammel `./scripts/verify-counts.sh` bare for relevant baseline før den erstattes. `npm run verify:repo` er et nytt avtalt leveransekrav, ikke en kommando som finnes i utgangspunktet.

I tillegg skal oppgraderingsprøven kunne etableres fra det gamle migrasjonssettet, legge inn syntetisk prototypeinnhold og så bruke de nye migrasjonene. Test at utskifting av UI-et ikke fører til at reset må kjøres ved hver deploy.

En grønn build uten databaseprøver er ikke «alle tester grønne». Skill i PR-en mellom kjørt lokalt, kjørt i CI og ikke kjørt. Å endre denne dokumentasjonen krever ikke at en ekstra betalt modellkonto konfigureres.

Offisiell Codex-dokumentasjon beskriver egne setup-/agentfaser og `AGENTS.md`. Setup bør installere avhengigheter før en eventuelt nettbegrenset agentfase. Ikke kopier produksjonshemmeligheter til `.env` for å omgå at hemmeligheter kan ha begrenset tilgjengelighet mellom fasene. Denne oppgaven skal kunne implementeres uten slike hemmeligheter.

## 12. Neste sammenhengende produktleveranse

Etter resetten skal roadmap prioritere én ende-til-ende-leveranse, ikke en ny lang serie med usynlige tekniske milepæler:

**Fulltekstbibliotek + reell agentkjede + én lesbar klinikerflate med sluttkontroll.**

Kildemangellisten viser hvorfor en publikasjon trengs. Klikk åpner modal med bibliografiske opplysninger, direktelenker til PubMed/DOI når identifikatorene finnes, «Velg PDF fra datamaskinen» og dra-og-slipp-sone. Antidep gir systematisk visningsnavn, bevarer originalt navn, bruker stabil maskinidentitet, validerer fil og publikasjon, lagrer privat og sender jobben videre. En opplasting som er avbrutt eller feil publikasjon skal aldri markeres som fulltekstklar.

Filen og den tekst-/sidebundne representasjonen må kunne leses av nye agentøkter uten at Peder laster opp på nytt. Avgrens tilstrekkelig kildegrunnlag for et faktisk klinisk spørsmål, søk også etter motstridende funn, og synliggjør manglende dekning. Ikke markedsfør en enkeltstudiebeskrivelse som en dekkende legemiddelmonografi.

Pipelinekjøring skal ha varig jobbtilstand, avgrensede retries og idempotente registreringer. Samme jobb kjørt igjen må ikke lage en ny påstand ved et uklart nettverkssvar. Dette er neste leveranses driftskrav, ikke en grunn til å bruke resetten på en generell agentplattform.

Før kandidatbundet publisering åpnes: bevis riktig slutttekst, kildetilgang, separate kontroller, håndtert usikkerhet, oppdatert grunnlag og menneskelig godkjenning av akkurat den kandidaten. Sikkerhetskritiske dose-/bytteverktøy krever egne versjonerte, testede regler og eksplisitt faglig godkjenning; eksperimentstatus skal ikke brukes som begrunnelse for skjult klinisk risiko.

Åpne issues om gamle skjermfeil skal triageres, ikke mekanisk videreføres. #90 handler om den fjernede kontrollveiviseren. #88s lærdom om reviderbar kontroll/historikk bevares uten å bygge tilbake den gamle skjermen. #91s skille mellom utgått kandidat og bevisst tilbakerulling må håndteres i den nye kandidatmodellen; ikke kall det løst bare fordi køen er slettet.

## 13. Ferdigkriterier og leveranserapport

PR-en skal vise:

- én gjeldende visjon og kort roadmap;
- ingen gammel produkt-/mikroreviewflyt;
- en fungerende minimal app og bevart teknisk innlogging der relevant;
- uendrede historiske migrasjoner og testede nye migrasjoner;
- tom aktiv prototypekunnskap etter fersk installasjon og etter kontrollert oppgraderingsprøve;
- privat reversibelt reset-spor, bevart kildebibliotek, katalog, kontoer og sikkerhetsmodell;
- fulltekstbarrierer brukt av faktiske kliniske innganger;
- ingen påstand om implementert permanent lagring eller autonom runtime før de faktisk finnes;
- reelle positive/negative tester og grønn full CI, inklusive låse- og kjedeprøver;
- tydelig at ingen hostet datarydding er utført som del av Codex-oppgaven.

Rapporter filgrupper som er beholdt/fjernet, nye migrasjoner og deaktiverte API-innganger, verifikasjonsresultater og eventuelle reelle blokkere. Til Peder holder en kort forklaring på hva som nå er mulig å teste og hva neste produktleveranse er.

Når resetten er gjennomført, skal `AGENTS.md` peke på den nye korte, gjeldende dokumentasjonen. Ikke la denne engangsplanen eller sjekklisten bli en evig konkurrerende styringskilde: erstatt med en kort ferdigrapport eller fjern dem når de er avløst. Bevar migration-baseline og varige regresjonstester i testsystemet.

## Kilder til plattformdetaljene

Kontrollert under planleggingen; bruk oppdatert offisiell dokumentasjon ved faktisk implementering:

- OpenAI: https://developers.openai.com/codex/cloud/environments
- OpenAI: https://developers.openai.com/codex/guides/agents-md
- Supabase: https://supabase.com/docs/guides/local-development/database-migrations
- Supabase: https://supabase.com/docs/guides/platform/backups
- Supabase: https://supabase.com/docs/guides/storage/schema/design
- Supabase: https://supabase.com/docs/guides/storage/buckets/fundamentals

Repoobservasjonene er knyttet til kodegrunnlaget øverst, særlig filene i §2 og §4. De er ikke en påstand om at den hostede databasen er inspisert eller at tester er kjørt i denne planleggingsøkten.
