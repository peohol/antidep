# Supabase — lokalt utviklingsmiljø

Denne katalogen inneholder Antideps Supabase-utviklingsfundament, i tråd med
[`docs/DATABASE_ARCHITECTURE.md`](../docs/DATABASE_ARCHITECTURE.md) og repo-strukturen i
[`docs/MVP_IMPLEMENTATION_PLAN.md`](../docs/MVP_IMPLEMENTATION_PLAN.md) §6.

- `config.toml` — prosjektkonfigurasjon for Supabase CLI (generert av `supabase init`,
  CLI-versjonen er pinnet i `package.json`). `[api].schemas` styrer hvilke schemaer som
  eksponeres i Data API.
- `migrations/` — versjonerte migrasjoner:
  - 001 schema- og sikkerhetsfundamentet
  - 002 katalogfundamentet
  - 003 `knowledge.sources`, kildeversjoner og `knowledge.evidence_items`
  - 004 `knowledge.claims`, revisjoner, evidenslenker og evidensvurderinger
  - 005 `provenance.actors`, medlemskapsmodellen, verifikasjon og review
  - 006 `knowledge.publication_events` og den kontrollerte publiseringsoperasjonen
  - 006a korreksjon: entydig serialisering av `content_hash` på evidensfunn
  - 007 api-lesemodellen: `api.published_drugs`, `api.published_claims`,
    `api.published_claim_evidence`, med RLS-policyene og grantene under dem
  - 008 `audit.events` og de to auditskriverne over publisering og rolleforvaltning
  - 007a `published_at` og `last_reviewed_at` i `api.published_claims`, med
    godkjenningstidspunktet frosset på publiseringshendelsen
  - 005a den navngitte kvalifiserte redaktøren som menneskelig aktør, uten brukerkonto
    og uten rolletildeling
  - 005b redaktørens brukerkonto knyttet til aktørraden, og `reviewer`-rollen tildelt —
    men bare i miljøer der kontoen finnes i `auth.users`
  - 007b kallerens egen aktørrad og egne gjeldende rolletildelinger: `api.my_actor` og
    `api.my_roles`, med RLS-policyene og kolonnegrantene under dem
  - 003a `created_by_actor_id` på `knowledge.sources`, uforanderlig etter opprettelsen —
    kolonnen migrasjon 005 la til på de øvrige kunnskapsobjektene
  - 008a `source_created` lagt til `audit.event_operation`, alene i sin egen migrasjon fordi
    `ALTER TYPE ... ADD VALUE` ikke kan brukes i transaksjonen som legger verdien til
  - 007c adminflytens kontrollerte skrivevei: `api.create_source(...)` med
    `knowledge.assert_editor_authorized()` og auditskriveren over kildeopprettelse
  - 005c `editor`-rollen tildelt redaktørkontoen, altså retten til å registrere kilder og
    evidens som forslag — men bare i miljøer der kontoen finnes i `auth.users`
  - 008b `evidence_item_created` lagt til `audit.event_operation`, alene i sin egen migrasjon
    av samme grunn som 008a
  - 007d den redaksjonelle lesemodellen: `api.editor_sources`, `api.editor_source_versions`,
    `api.editor_drugs`, `api.editor_outcomes`, `api.editor_populations` og
    `api.editor_evidence_items`, med radgrensen `workflow.caller_is_active_editor()` og
    RLS-policyene under dem
  - 007e adminflytens andre kontrollerte skrivevei: `api.create_evidence_item(...)` med
    auditskriveren over evidensregistrering, og scope på
    `knowledge.assert_editor_authorized(uuid)`

  Nummereringen følger planlagt innhold i `docs/MVP_IMPLEMENTATION_PLAN.md` §18-§27, ikke
  filrekkefølge. Migrasjoner utenfor den planlagte rekken får en bokstav, slik at
  «migrasjon 007 — API-lesemodell» (§24) fortsatt betyr det samme i plan, migrasjoner og
  tester. Filrekkefølgen er derfor 001, 002, 003, 004, 005, 006, 006a, 007, 008, 007a, 005a,
  005b, 007b, 003a, 008a, 007c, 005c, 008b, 007d, 007e: 007a til 007e er skrevet etter 008,
  men utvider api-lesemodellen, 005a, 005b og 005c utvider aktørregisteret og
  medlemskapsmodellen fra 005, 003a utvider kildetabellen fra 003, og nummeret 009 er
  reservert for importfundamentet (§26).

- `tests/` — pgTAP-tester som kjøres med `npm run db:test`.
- `seed.sql` — kun lokal demodata. Kontrollert vokabular og pilotdata som produksjonen
  er avhengig av, ligger i migrasjonene (se «Hvor seed-data hører hjemme» under).

## Kjøre lokal Supabase

Krav: [Docker](https://docs.docker.com/get-docker/) må være installert og kjøre.
Supabase CLI følger med som pinnet devDependency (`npm ci` er nok; ingen global installasjon).

```bash
npm run db:start   # starter lokal stack (Postgres, API m.m.) og skriver ut URL-er og nøkler
npm run db:status  # viser status og lokale nøkler for kjørende stack
npm run db:reset   # gjenskaper lokal database og kjører alle migrasjoner fra bunnen av
npm run db:test    # kjører pgTAP-testene i tests/ mot den lokale databasen
npm run db:stop    # stopper stacken
```

`db:start` skriver ut lokal `API URL` og publishable-nøkkel. Kopier dem inn i `.env.local`
(se `.env.example`) når app-koden begynner å lese fra Supabase.

Verdiene fra den lokale stacken er kun lokale utviklingsnøkler, men reelle prosjektnøkler
skal aldri committes, og secret-/`service_role`-nøkler skal aldri finnes i klientkode
(`docs/DATABASE_ARCHITECTURE.md` §49).

## Schema- og sikkerhetsgrensen

Migrasjon 001 oppretter de logiske schemaene fra `docs/DATABASE_ARCHITECTURE.md` §6:

| Schema       | Innhold                                            | Data API  |
| ------------ | -------------------------------------------------- | --------- |
| `catalog`    | virkestoffer, produkter, kliniske begreper         | privat    |
| `knowledge`  | claims, revisjoner, kilder, evidens, vurderinger   | privat    |
| `workflow`   | arbeidsflyt, verifikasjon, review, rollemedlemskap | privat    |
| `provenance` | aktører, pipeline-/modellversjoner, sporbarhet     | privat    |
| `audit`      | append-only hendelseslogg                          | privat    |
| `api`        | publiserte views og kontrollerte RPC-er            | eksponert |

Fra migrasjon 007 er `[api].schemas` i `config.toml` satt til `["api", "graphql_public"]`.
`public` ble tatt ut fordi det ikke inneholder Antidep-objekter, og en tom eksponering er
fortsatt en eksponering. `api` står først og er dermed standardprofilen i PostgREST.

`ingest` opprettes først når importfundamentet kommer (migrasjon 009).

Tilgang er default deny. `anon` og `authenticated` har `usage` bare på `api`, og hvert
objekt i `api` må få egen `GRANT` i migrasjonen som oppretter det. `service_role` har
ingen tilgang til Antidep-schemaene og er ikke applikasjonens universalnøkkel
(`docs/DATABASE_ARCHITECTURE.md` §49).

Fra migrasjon 007a har klientrollene i tillegg `SELECT` på fire av kolonnene i
`knowledge.publication_events` — nok til å lese publiserings- og godkjenningstidspunktet
for den gjeldende publiseringen, og ikke mer. Publiseringsbegrunnelsen og hvem som
publiserte er ikke blant dem. Et kolonnegrant er en reell begrensning: et
`security_invoker`-view kan ikke projisere en kolonne kalleren mangler grant på. Merk at
det ikke er synlig i `has_table_privilege()` eller `information_schema.role_table_grants` —
en vaktpost må se på `role_column_grants` for å oppdage det, eller på
`pg_attribute.attacl`, som `tests/030_conventions_test.sql` nå gjør.

Fra migrasjon 007b har `authenticated` — og bare `authenticated` — `SELECT` på fem kolonner i
`provenance.actors` og seks i `workflow.user_roles`, nok til å lese sin _egen_ aktørrad og
sine _egne_ gjeldende rolletildelinger gjennom `api.my_actor` og `api.my_roles`. RLS-policyene
under dem slipper bare gjennom rader der kalleren er `auth.uid()`. Begrunnelsen for en
tildeling, hvem som tildelte eller avsluttet den, og aktørens beskrivelse er ikke blant
kolonnene: det er governance-tekst og ikke kallerens svar på «hva har jeg lov til».

Fra migrasjon 007 har klientrollene i tillegg `SELECT` på de tretten kanoniske tabellene
api-viewene leser. Det følger av at views i `api` er `security_invoker` og altså leser med
kallerens rettigheter (§42). Granten åpner ikke tabellene: uten `usage` på schemaet kan
klientrollene ikke navngi dem — forsøket gir «permission denied for schema» — og RLS
slipper uansett bare gjennom rader som er nådd fra en publisert påstand. Se
«API-lesemodellen» under.

Konvensjoner som gjelder for alle senere migrasjoner, håndhevet av
`tests/030_conventions_test.sql`:

- primærnøkkelen er én databasegenerert `uuid`-kolonne med `default gen_random_uuid()`
- alle tidspunkter som `timestamptz`, med `created_at timestamptz not null default now()`
- RLS aktivert på alle tabeller i de kanoniske schemaene, uten grants til klientrollene
- `security_invoker` på views i `api`
- `SECURITY DEFINER`-funksjoner kun med `search_path = ''` og schemakvalifiserte navn, og
  uten `EXECUTE` til `PUBLIC`

Schemaendringer skal alltid ligge som versjonerte migrasjoner her i repoet; manuelle
endringer i Supabase Dashboard skal ikke være kilden til produksjonsschema
(`docs/MVP_IMPLEMENTATION_PLAN.md` §54). Eksponerte schemaer i det hostede prosjektet må
holdes i synk med `[api].schemas` her.

**Det hostede prosjektet er i synk med `main`, lest 4. september 2026.** Alle sytten
migrasjonene over er kjørt der og registrert i `supabase_migrations.schema_migrations`, med
nøyaktig de samme versjonsnumrene og navnene som filene i `migrations/`, og Data API-ets
eksponerte schemaer er `api, graphql_public` — samme verdi som `[api].schemas` her.
Tilstanden er lest fra produksjonsdatabasen gjennom Management-API-et, ikke gjengitt fra
dashboardet.

**Datoen står der med hensikt.** Ingen vaktpost i CI ser på det hostede prosjektet, så en
påstand om det er sann bare til noen endrer noe uten å oppdatere setningen — nøyaktig det som
skjedde mellom §74.18, §74.23 og §74.25, tre ganger på rad. Les tilstanden på nytt før du
handler på den; hvordan avlesningen ble gjort, står i `docs/MVP_IMPLEMENTATION_PLAN.md` §74.26.
At ingenting oppdager avviket maskinelt, er ført som GitHub-issue 42.

Merk at `supabase link` og `supabase db push` ikke kan kjøres fra en agentsesjon: den pinnede
CLI-ens Bun-runtime klarer ikke TLS gjennom sesjonens HTTPS-proxy (§74.23, prøvd på nytt 3. september 2026 og feilen står). Det er en egenskap ved agentmiljøet og ingen grunn til å
endre pinningen; migrasjonene ble derfor kjørt gjennom Management-API-et, én fil om gangen,
med historikkraden i samme transaksjon — samme operasjon `db push` gjør (§74.26).

**Kjør aldri `supabase config push` mot det hostede prosjektet.** Kommandoen pusher hele
`config.toml`, og filen her er i praksis `supabase init`-standardene for en lokal stack —
`auth.site_url` er `http://127.0.0.1:3000`, `auth.additional_redirect_urls` peker samme sted,
og `auth.enable_signup` er `true`, mens produksjon står på appens egen URL med registrering
avslått. Regelen hviler likevel ikke på enkeltnøkler: bare en håndfull av filens nøkler er
sammenlignet med produksjon, og et push skriver dem alle. Den kontrollerte sammenligningen,
med hva som faktisk er lest og hva som ikke er det, står i
`docs/MVP_IMPLEMENTATION_PLAN.md` §74.23.

Enkeltinnstillinger settes i dashboardet eller på det ene feltet gjennom Management-API-et. Å
gjøre `config.toml` til reell kilde for det hostede prosjektet er en egen, bevisst oppgave der
hver seksjon først må settes til produksjonsverdier, nøkkel for nøkkel.

Supabase-forutsetningene i `docs/MVP_IMPLEMENTATION_PLAN.md` §8 ble kontrollert mot
plattformdokumentasjonen 18. august 2026, før migrasjon 001 ble skrevet.

## Katalogfundamentet

Migrasjon 002 oppretter virkestoffidentiteten, det kontrollerte begrepsvokabularet og
populasjonsmodellen som Claims, evidens og publiserte projeksjoner senere peker på:

| Tabell                      | Innhold                                                                        |
| --------------------------- | ------------------------------------------------------------------------------ |
| `catalog.drugs`             | stabil identitet for virkestoff, med kanonisk navn og status                   |
| `catalog.drug_names`        | aliaser, handelsnavn og historiske navn med eksplisitt navnetype               |
| `catalog.drug_identifiers`  | eksterne identifikatorer, foreløpig WHO ATC                                    |
| `catalog.clinical_concepts` | kontrollert begrepsvokabular med begrepstype og valgfritt hierarki             |
| `catalog.populations`       | strukturerte gyldighetsgrenser for alder, indikasjon, graviditet, komorbiditet |

Kanoniske navn og eksterne identifikatorer er unike, men aldri primærnøkkel: primærnøkkelen
er alltid en databasegenerert `uuid` (`docs/DATABASE_ARCHITECTURE.md` §8). Alle fremmednøkler
i `catalog` bruker `RESTRICT` (§37), så klinisk relevant historikk kan ikke forsvinne som
bivirkning av en sletting.

I `catalog.populations` betyr `NULL` i en dimensjon at populasjonen **ikke er avgrenset** på
den dimensjonen. `NULL` betyr ikke «ukjent» og ikke «vurdert og funnet irrelevant»
(`docs/ANTIDEP_CONSTITUTION.md` §6).

`created_at` og `updated_at` eies av databasen på alle katalogtabellene. En trigger setter
dem ved både `INSERT` og `UPDATE`, så en kaller kan verken glemme eller forfalske dem; en
`default` alene ville bare gjelde når kolonnen utelates. Tidspunkter fra den eksterne
virkeligheten hører til `recorded_at` eller `valid_from`/`valid_to`, ikke hit
(`docs/DATABASE_ARCHITECTURE.md` §7.3).

**Populasjonsdefinisjonen er uforanderlig.** En populasjon er en gyldighetsgrense, ikke bare
en etikett, og `ClaimRevision`/`EvidenceItem` peker på `population_id`. Kunne de definerende
feltene endres etterpå, ville en redigering stille endret omfanget av all historikk som
allerede peker dit, uten ny revisjon (`docs/DATABASE_ARCHITECTURE.md` §7, §7.1). En trigger
avviser derfor endring av etikett, aldersgrenser, indikasjon, graviditetskontekst og
komorbiditet. **Et endret omfang er en ny populasjon:** opprett en ny rad og sett den gamle
til `status = 'deprecated'`. Status og tidsstempler er utenfor vernet, så utfasing er mulig
uten å røre betydningen. Vernet gjelder også eieren; en reell datakorreksjon i en senere
migrasjon må slå av triggeren eksplisitt, som en synlig og reviewbar handling.

Begrepshierarkiet er bevisst ikke vernet på samme måte: en `ClinicalConcept` organiserer og
gjenfinner innhold og er ikke en gyldighetsgrense for en påstand, så en etikettkorreksjon
der endrer ikke omfanget av historikk.

Tabellene har RLS aktivert og ingen policies. De er derfor default deny for alle andre enn
eieren, og det samme gjelder tabellene i `knowledge`, `workflow` og `provenance`. Se
«Review og proveniens» under for hvorfor policyene fortsatt ikke er skrevet.

## Review og proveniens

Migrasjon 005 innfører attribusjonen og kontrollene som `docs/ANTIDEP_CONSTITUTION.md` §10,
§11, §12 og §14 krever:

| Tabell                            | Innhold                                                                       |
| --------------------------------- | ----------------------------------------------------------------------------- |
| `provenance.actors`               | normalisert aktør: menneske, KI-agent, deterministisk prosess, import, system |
| `workflow.user_roles`             | medlemskapsmodellen med scope og gyldighetsperiode                            |
| `workflow.evidence_verifications` | kontroll av at et evidensfunn gjengir kilden riktig                           |
| `workflow.claim_verifications`    | kontroll av at en påstandsrevisjon holder mot grunnlaget                      |
| `workflow.review_decisions`       | menneskelig faglig beslutning som eget beslutningsobjekt                      |

Samtidig får `knowledge.evidence_items`, `claims`, `claim_revisions`,
`claim_evidence_links` og `evidence_assessments` en påkrevd `created_by_actor_id`.

**Generering og verifikasjon er atskilte operasjoner.** Verifikasjonsraden ligger ved siden
av objektet og endrer det aldri, og en speilkolonne låst til foreldreraden gjør at en
radlokal `CHECK` kan avvise at verifikatoren er den samme aktøren som laget objektet. En
bekreftelse kan heller ikke hvile på et avledet sammendrag alene, og en claim-verifikasjon
kan bare konkluderes som `verified` når alle sju kontrollpunktene i
`docs/DATABASE_ARCHITECTURE.md` §30 er bedømt og holder.

**Tidsmodellen kan ikke konstrueres i etterkant.** `verified_at` og `decided_at` er
kallerstyrte hendelsestidspunkter, og `decided_at` bestemmer hvilken rolletildeling som
teller som gyldig. `created_at` på de tre append-only workflow-tabellene eies derfor av
databasen, hendelsestidspunktet kan ikke ligge etter det, og kvalifikasjonskontrollen
krever at selve rolletildelingsraden fantes senest på beslutningstidspunktet. En rolle
opprettet i dag kan dermed ikke legitimere en «godkjenning» datert i fjor ved å
tilbakedatere `valid_from`. En kontroll eller beslutning som faktisk fant sted tidligere
kan fortsatt registreres i etterkant.

**Bare mennesker kan godkjenne.** `workflow.review_decisions` krever en aktør av typen
`human` — håndhevet av en sammensatt fremmednøkkel og en `CHECK` — og en trigger krever i
tillegg at aktøren hadde gyldig `reviewer`-rolle for objektets innholdsområde på
beslutningstidspunktet. Rollen leses fra `workflow.user_roles`, aldri fra en JWT-claim
(`docs/DATABASE_ARCHITECTURE.md` §46). `admin` er brukerforvaltning og gir ikke faglig
godkjenningsrett.

**En tilbaketrukket ekstraksjon er en beslutning, ikke en statuskolonne.** Spørsmålet stod
åpent fra migrasjon 003 og er avgjort her: `review_type = 'extraction_withdrawal'` i
`workflow.review_decisions`. Publiseringsgaten i migrasjon 006 må lese den avledede
tilstanden og nekte å publisere en revisjon som hviler på et tilbaketrukket evidensfunn.

**Ingen skrivepolicies.** Migrasjon 007 skrev de første RLS-policyene, men bare for `SELECT`
og bare på leseveien til publiserte påstander. Skriveveien er fortsatt en kontrollert
`SECURITY DEFINER`-funksjon, ikke tabelltilgang (`docs/DATABASE_ARCHITECTURE.md` §43), og
`030_conventions_test.sql` håndhever at ingen policy i de kanoniske schemaene åpner for annet
enn lesing. `workflow` og `provenance` har fortsatt verken grants eller policies.

**Seedomfang.** Migrasjon 005 seeder bare de to KI-aktørene som faktisk produserte radene i
migrasjon 003 og 004. Ingen verifikasjon og ingen reviewbeslutning er seedet: begge deler er
utførte handlinger, og en seedet godkjenning ville vært nøyaktig den fiktive godkjenningen
`docs/ANTIDEP_CONSTITUTION.md` §12 forbyr. `provenance.agent_runs` opprettes først når en
faktisk automatisk pipeline skriver kjøringer.

## Redaktørens autorisasjon

Migrasjon 005a registrerer den navngitte kvalifiserte redaktøren
(`docs/ANTIDEP_CONSTITUTION.md` §12) som menneskelig aktør. Migrasjon 005b knytter aktørraden
til brukerkontoen og tildeler `reviewer`-rollen.

**005b gjør forskjellige ting i forskjellige miljøer, og det er et valg.**
`workflow.user_roles.user_id` er `NOT NULL` med fremmednøkkel til `auth.users`. Kontoen er en
reell Supabase-konto som bare finnes i miljøet den ble opprettet i, mens en lokal stack og CI
starter uten den. Migrasjonen skriver derfor bare når kontoen faktisk finnes, og sier fra med
en `notice` når den ikke gjør det. Bakgrunnen og de forkastede alternativene står i
`docs/MVP_IMPLEMENTATION_PLAN.md` §74.18; hvordan prisen for valget er betalt, i §74.20.

Logikken ligger i `workflow.ensure_named_editor_authorization()`, ikke som løse setninger i
migrasjonsfilen. Da kan testene kjøre nøyaktig den koden som kjører i produksjon framfor en
kopi av den, og koblingen kan fullføres med ett kall til i et miljø der kontoen kommer senere:

```sql
select workflow.ensure_named_editor_authorization();
```

Kallet er idempotent, og bare det første av de fem svarene skriver noe:

| Svar                 | Betydning                                          |
| -------------------- | -------------------------------------------------- |
| `authorized`         | tildelingen ble skrevet                            |
| `already_authorized` | en reviewer-tildeling er gyldig nå                 |
| `role_not_yet_valid` | en reviewer-tildeling begynner å gjelde senere     |
| `role_ended`         | en reviewer-tildeling er avsluttet                 |
| `account_missing`    | kontoen finnes ikke i `auth.users` i dette miljøet |

`workflow.user_roles` er en gyldighetsmodell og ikke et flagg: intervallet er halvåpent, og
`valid_to` kan være satt allerede ved tildeling som en planlagt utløpsdato. «Løpende» og
«gyldig nå» er derfor to forskjellige spørsmål, og bare det andre avgjør om rettigheten
finnes. Gyldighet måles med `statement_timestamp()`, ikke med `now()`
(`docs/MVP_IMPLEMENTATION_PLAN.md` §74.6).

**En avsluttet tildeling gjeninnføres aldri.** En tilbakekalling som en rutinemessig
`supabase db push` omgjør, er ingen tilbakekalling (`docs/DATABASE_ARCHITECTURE.md` §46).
Funksjonen rapporterer `role_ended` og lar et menneske avgjøre; en gjeninnføring er en ny
tildeling med sin egen begrunnelse.

Funksjonen tar ingen parametere — konto og aktørnøkkel er konstanter i kroppen, så den kan
bare gjøre denne ene tildelingen, aldri en vilkårlig. `EXECUTE` er trukket fra `PUBLIC`.

**Rollen er selvtildelt, og begrunnelsen står i raden.** `granted_by_actor_id` peker på
redaktørens egen aktør. Alternativet ville gjort en KI-aktør til opphavet til et menneskes
faglige godkjenningsrett (`docs/ANTIDEP_CONSTITUTION.md` §10, §12). Ingen `CHECK` forbyr
selvtildeling, så `grant_reason` er hele sikringen.

**Tildelingen åpner ikke publiseringsgaten.** Ekstraksjonsverifikasjon, claim-verifikasjon og
selve godkjenningen mangler fortsatt (`docs/MVP_IMPLEMENTATION_PLAN.md` §74.4).
`350_editor_authorization_test.sql` kjører begge grenene av migrasjonen og prøver begge
påstandene framfor å telle dem.

### `editor`-rollen: retten til å registrere, og bare den

Migrasjon 005c tildeler samme konto en uscopet `editor`-rolle. Den er forutsetningen for
`api.create_source(...)` (migrasjon 007c), som krever en gyldig `editor`-tildeling gjennom
`knowledge.assert_editor_authorized()`. Uten den svarer skjemaet «Opprett kilde» med
«Brukeren har ikke gyldig editor-rolle» for enhver innlogget bruker.

Logikken ligger i `workflow.ensure_editor_role_grant()`, som er en egen funksjon og ikke en
parameter på 005b sin: en parameterisert utgave ville vært en generell «gi denne kontoen
hvilken som helst rolle»-funksjon, der `publisher` og `admin` var like tilgjengelige som
`editor`.

```sql
select workflow.ensure_editor_role_grant();
```

Kallet er idempotent og har samme fem svar, med samme betydning, som funksjonen over. To ting
skiller den:

- **Den setter ikke koblingen mellom aktørrad og brukerkonto.** Den er migrasjon 005b sin, og
  005c _krever_ at den finnes. Mangler den mens kontoen finnes, feiler kallet høyt framfor å
  skrive en rettighet skriveveien uansett ville avvist.
- **Begrunnelsen er `editor`-rollens egen.** `editor` gir rett til å registrere kilder og
  evidens som _forslag_ (`docs/CONTENT_GOVERNANCE.md` §8). Den gir verken faglig
  godkjenningsrett (`reviewer`) eller publiseringsrett (`publisher`), og alt som registreres
  må gjennom verifikasjon, menneskelig godkjenning og publiseringsgaten før det kan nå en
  kliniker. Terskelen for å selvtildele den er derfor en annen enn for `reviewer`, og
  `380_source_registration_role_test.sql` krever at ordlyden faktisk er en annen tekst.

**Rollegrensen er prøvd fra begge sider.** Med `editor` alene avvises både en reviewbeslutning
og publiseringskontrollen, mens `api.create_source(...)` fortsatt virker — kalt gjennom
klientrollen `authenticated`, med redaktørkontoens eget JWT-subjekt, framfor gjennom
kontrollfunksjonen alene.

## API-lesemodellen

Migrasjon 007 åpner den første leseveien fra klientflaten inn i kunnskapsbasen
(`docs/MVP_IMPLEMENTATION_PLAN.md` §24):

| View                           | Innhold                                                                   |
| ------------------------------ | ------------------------------------------------------------------------- |
| `api.published_drugs`          | virkestoff Antidep har minst én publisert påstand om, med ATC-kode        |
| `api.published_claims`         | én rad per publisert påstand, med strukturert betydning og sikkerhetsgrad |
| `api.published_claim_evidence` | evidensgrunnlaget bak hver påstand, med funn, kilde, DOI og PMID          |

**Tre lås står mellom en klientrolle og en upublisert påstand.** Klientrollene mangler `usage`
på de kanoniske schemaene og kan ikke navngi tabellene. RLS slipper bare gjennom rader nådd fra
en publisert, ikke tilbaketrukket påstand. Og bare `SELECT` er gitt, bare til `anon` og
`authenticated`. Hvert lag testes for seg i `tests/290_api_read_model_access_test.sql`, med
faktisk klientrolle, slik §24 og `docs/DATABASE_ARCHITECTURE.md` §44 punkt 4 krever.

**Viewene bærer publiseringspredikatet i tillegg til RLS.** Det er bevisst dobbeltarbeid: hvert
lag skal være korrekt alene, slik at verken en tapt policy eller en feilskrevet join er nok til
å vise upublisert eller tilbaketrukket innhold. Nettopp derfor testes de hver for seg — leses
et view som eier, er RLS av, og viewets eget filter er det eneste som svarer.

**En tilbaketrukket ekstraksjon merkes, den skjules ikke.** Publiseringsgaten nekter å
publisere en revisjon som hviler på en tilbaketrukket ekstraksjon, men beslutningen er
append-only og kan komme _etter_ publiseringen — da flytter den verken publiseringspekeren
eller evidenslenkene. `api.published_claim_evidence.extraction_withdrawn` avleder den
gjeldende tilstanden på nøyaktig samme måte som gaten gjør, og
`api.published_claims.withdrawn_evidence_count` gir samme signal på påstandsnivå. Funnet
skjules ikke: da ville påstanden sett bedre underbygget ut enn den er.

Dette er den ene grunnen `workflow.review_decisions` er åpnet for klientrollene, og
policyen slipper bare gjennom `review_type = 'extraction_withdrawal'`.
Publiseringsgodkjenninger — med reviewers identitet og begrunnelse — forblir utenfor
klientflaten, og `workflow.user_roles` er fortsatt helt stengt. Begge utfallene av en
tilbaketrekking er lesbare: skjulte vi `extraction_upheld`, ville en ekstraksjon som først
ble trukket tilbake og siden opprettholdt sett tilbaketrukket ut for en klientrolle mens
eieren så den som gyldig.

**Projeksjonen er tom inntil noe faktisk er publisert.** Det er korrekt oppførsel, ikke en
mangel: publisering krever en menneskelig faglig godkjenning som ikke kan seedes
(`docs/ANTIDEP_CONSTITUTION.md` §12, `docs/MVP_IMPLEMENTATION_PLAN.md` §74.4). Testene
publiserer derfor sitt eget innhold inne i en transaksjon som rulles tilbake.

**Kontrakten er tekst, ikke enum.** Viewene caster enum-kolonner til `text`. Verdiene er de
samme, men den offentlige kontrakten bindes ikke til PostgreSQL-typen, og klientrollene trenger
ikke `usage` på typene. Om enumene på sikt byttes mot oppslagstabeller
(`docs/MVP_IMPLEMENTATION_PLAN.md` §74.5 punkt 1), er det da ikke en brytende API-endring.

**Identiteten er uuid, med ATC som ekstern nøkkel.** Katalogobjekter eksponeres med sin
databasegenererte `uuid` (`docs/DATABASE_ARCHITECTURE.md` §8). For virkestoff følger ATC-kodene
med som språkuavhengig ekstern nøkkel, som sortert array. `NULL` der betyr at ingen ATC-kode er
registrert i Antidep, ikke at virkestoffet mangler en.

**Identifikatorer aggregeres, de joines ikke — og de reduseres ikke til én.**
`catalog.drug_identifiers` og `knowledge.source_identifiers` er unike på
`(identifier_system, identifier_value)`, ikke på `(forelder, identifier_system)`: ett virkestoff
kan ha flere ATC-koder, og en kilde kan ha flere DOI-er, blant annet ved parallellpublisering.
Joinet inn ville de multiplisert raden — ett evidensfunn ville blitt til to og sett ut som to
uavhengige funn. Å velge én ville i stedet gjort en vilkårlig kanonisering til offentlig
kontrakt, siden ingen av identifikatorene er definert som primær. `atc_codes`, `source_dois` og
`source_pmids` er derfor sorterte arrays.

**Kildeversjonen følger med.** `source_locator` peker inn i en bestemt hentet versjon, ikke i
kilden generelt. For en levende kilde — retningslinje, preparatomtale, nettside — kan samme URL
senere gi annet innhold, og da er lokatoren alene ikke nok til å reprodusere hva som faktisk ble
verifisert. `api.published_claim_evidence` eksponerer derfor `source_version_id`, hentetidspunkt,
hentested, kildens egen versjonsbetegnelse og innholdsavtrykket. Lagringsreferansen til selve
innholdet er bevisst ikke med.

## Auditloggen

Migrasjon 008 oppretter `audit.events` (`docs/MVP_IMPLEMENTATION_PLAN.md` §25,
`docs/DATABASE_ARCHITECTURE.md` §35): en append-only logg over sikkerhets- og
forvaltningskritiske operasjoner.

**Loggen er et supplement, ikke et andre hjem for faglig historikk.** Den kliniske
historikken ligger fortsatt i revisjonsmodellen og i `knowledge.publication_events`. Det
auditloggen tilfører er det tverrgående spørsmålet ingen av dem kan besvare: «hva gjorde
denne aktøren, på tvers av objekter og schemaer?»

| Produsent                               | Dekker                                                           |
| --------------------------------------- | ---------------------------------------------------------------- |
| `publication_events_record_audit_event` | publisering, erstatning, avpublisering og rollback av en påstand |
| `user_roles_record_grant_audit_event`   | tildeling av en applikasjonsrolle                                |
| `user_roles_record_end_audit_event`     | avslutning eller tilbakekalling av en rolletildeling             |

**`object_id` har bevisst ingen fremmednøkkel.** Det er det ene stedet Antidep avviker fra
`RESTRICT`-regelen i `docs/DATABASE_ARCHITECTURE.md` §37, og grunnen står i §36: fysisk
sletting «skal i så fall ha særskilt audit». En fremmednøkkel ville enten blokkert
slettingen eller fjernet auditraden sammen med objektet. Auditraden bærer derfor et snapshot
av raden framfor bare en peker, og overlever objektet sitt. `actor_id` er derimot en ekte
fremmednøkkel med `RESTRICT`.

**Auditskriverne er ikke `SECURITY DEFINER`, og det er med hensikt.** En auditskriver som er
mer privilegert enn operasjonen den registrerer, er en vei til å skrive falske auditrader.
Konsekvensen er at den som ikke kan skrive auditraden heller ikke får registrert
operasjonen — en rolletildeling som ikke kan auditeres, skal ikke kunne registreres.

**Ingen lesevei for klientroller.** `docs/MVP_IMPLEMENTATION_PLAN.md` §47 lister `audit`
blant schemaene den offentlige klinikerflaten aldri skal ha `SELECT` mot. Tabellen har
verken grant, policy eller `usage` på schemaet, og ingen view i `api` leser fra den.

**Loggen er tom i migrert tilstand**, av samme grunn som api-projeksjonene er det:
ingenting er publisert, og ingen rolle er tildelt (`docs/MVP_IMPLEMENTATION_PLAN.md` §74.4).
Testene skriver derfor sitt eget innhold inne i en transaksjon som rulles tilbake.

## Hvor seed-data hører hjemme

Kontrollert vokabular og pilotdata som produksjonen er avhengig av, ligger i den versjonerte
migrasjonen som oppretter tabellene. Kliniske objekter i senere migrasjoner får fremmednøkler
til disse radene, og `seed.sql` kjøres bare ved lokal `supabase db reset` — data som bare
finnes der, ville ikke finnes i det hostede prosjektet.

`seed.sql` er derfor reservert for rent lokal demodata og er foreløpig tom.

Katalogdataene for den første golden slicen — sertralin, mirtazapin, `vektendring`,
`depressiv lidelse` og populasjonen «voksne med depressiv lidelse» — seedes av migrasjon 002.
Norske produktdata seedes ikke for hånd; de kommer gjennom `catalog.drug_products` og
FEST-importen i migrasjon 009.

## Kildeversjoner: hvem beregner fingeravtrykket

`knowledge.source_versions` er øyeblikksbildet Antidep faktisk leste av en kilde. Den er
det som gjør en ekstraksjon etterprøvbar: `retrieved_from` sier hvor representasjonen ble
hentet, og `content_hash` sier hva den inneholdt.

**Hashen beregnes av databasen, aldri av kalleren.** `api.create_source_version(...)`
(migrasjon 007f) tar imot representasjonen — ikke hashen — og beregner
`knowledge.source_version_content_hash(text)` i samme transaksjon som raden skrives. Det er
den samme grunnen som gjør at `content_hash` på et evidensfunn eies av databasen: en hash
kalleren kunne oppgi, ville sett ut som en garanti uten å være det.

De tre spørsmålene en verifikator må kunne besvare, har dermed hvert sitt entydige svar:

| Spørsmål                 | Svar                                                                  |
| ------------------------ | --------------------------------------------------------------------- |
| Hvem beregner hashen?    | PostgreSQL, inne i skriveveien                                        |
| Hva hashes?              | Nøyaktig den teksten som ble oppgitt, UTF-8-kodet, uten normalisering |
| Hvordan etterprøves den? | `curl <retrieved_from> \| sha256sum`                                  |

Grensen er skrevet ut framfor pyntet på: PostgreSQL kan ikke hente en URL, så basen kan ikke
vite at teksten faktisk kom fra adressen. Den kan bare garantere at hashen er hashen _av den
teksten_. Den siste koblingen kontrolleres av ekstraksjonsverifikatoren, som henter adressen
på nytt og sammenligner — en registrering der teksten ikke kom fra adressen, overlever derfor
ikke første verifikasjon.

**Redaktørflaten laster opp en fil, den limer ikke inn tekst.** `/source-versions/new` tar
imot representasjonen som en fil, fordi et `<textarea>` normaliserer linjeskift i sin
API-verdi: en kilde levert med CRLF ville blitt hashet som om den hadde LF, og
verifikatoren — som hasher de faktiske bytene fra nettet — ville rapportert endring for en
uendret kilde. Filen dekodes strengt som UTF-8 etter samme regel som verifikatoren bruker
på svaret sitt, og avvises hvis den ikke er det, framfor å lagre et fingeravtrykk ingen kan
etterprøve, og et innledende byte-order-mark beholdes framfor å bli fjernet av dekoderen.
Lagre derfor svaret rett fra nettet (`curl -o`), ikke via utklippstavlen.

## Legitimasjon til agentidentiteten

`agent-identity:extraction-verification-01` (migrasjon 005f) er registrert uten utstedt
legitimasjon og kan ikke gjøre noe før den får en. Utstedelsen er en bevisst, manuell
handling i det miljøet kjøreren skal lese hemmeligheten fra — ikke noe en migrasjon gjør,
fordi en hemmelighet generert av en migrasjon enten måtte ligget i repoet eller blitt
returnert gjennom en logg (`docs/MVP_IMPLEMENTATION_PLAN.md` §74.31).

```bash
# Lokal stack
npm run db:start
./scripts/issue-agent-credential.sh

# Hostet prosjekt: hent tilkoblingsstrengen i Supabase
# (Project Settings → Database → Connection string, direkte forbindelse)
./scripts/issue-agent-credential.sh --db-url "postgresql://..."
```

Skriptet skriver hemmeligheten til stdout **én gang**. Databasen lagrer bare hashen, og det
finnes ingen vei til å lese verdien ut igjen; mister du den, utsteder du en ny, som samtidig
ugyldiggjør den gamle. Skriptet nekter å kjøre når `CI` er satt: i en CI-jobb er stdout en
logg som lagres og deles.

Kjøreren leser fire miljøvariabler, ingen av dem med `VITE_`-prefiks — Vite eksponerer
nøyaktig de variablene til nettleseren, så et prefiks her ville lagt hemmeligheten i
klientbunten:

```
ANTIDEP_SUPABASE_URL=
ANTIDEP_SUPABASE_PUBLISHABLE_KEY=
ANTIDEP_AGENT_IDENTITY_KEY=agent-identity:extraction-verification-01
ANTIDEP_AGENT_SECRET=
```

Lokalt legges de i `.env.agent.local`, som er gitignorert og leses av
`npm run agent:verify-extraction`. I CI legges de inn som krypterte secrets (GitHub:
Settings → Secrets and variables → Actions), der arbeidsflyten
`.github/workflows/extraction-verification.yml` leser dem. **Publishable key, aldri
`service_role`:** agenten autentiseres av sin egen legitimasjon inne i api-funksjonene, ikke
av Data API-rollen, og en `service_role`-nøkkel ville omgått RLS og gitt kjøreren alt
(`docs/DATABASE_ARCHITECTURE.md` §49).

## Kjøre ekstraksjonsverifikatoren

```bash
npm run agent:verify-extraction -- --dry-run          # kontroller, registrer ingenting
npm run agent:verify-extraction                        # hele arbeidskøen
npm run agent:verify-extraction -- --evidence-item <uuid>
npm run agent:verify-extraction -- --limit 5
```

Kjøreren åpner en `provenance.agent_runs`-kjøring, leser grunnlaget med
`api.extraction_verification_input(...)` (migrasjon 005h), henter hver kildeversjons adresse
på nytt over nett, sammenligner fingeravtrykket, kontrollerer ekstraksjonen deterministisk mot
representasjonen og registrerer resultatet med `api.register_extraction_verification(...)`
(migrasjon 005g). Også en tørrkjøring registreres som en kjøring, og lukkes som `aborted`.

**Kjøringen registrerer ingen verifikasjon** når funnet mangler kildeversjon eller
fingeravtrykk, når kilden ikke lot seg hente, eller når fingeravtrykket ikke stemmer med det
registrerte. Da har verifikatoren ikke sett den utgaven ekstraksjonen ble gjort fra, og ingen
av verdiene i `workflow.verification_source_access` ville beskrevet situasjonen sant. Avviket
står i kjøringens `output_manifest`.

### Hentingen er begrenset til det offentlige internettet

`retrieved_from` er redaktørstyrt data, og kjøreren henter den adressen fra en maskin som har
tilgang til nettet — lokalt, eller fra en GitHub Actions-runner. Uten en grense ville en
registrert kilde kunne fjernstyre hva den maskinen kobler seg til. Kjøreren henter derfor bare
fra offentlige adresser, og kontrollen ligger på fire steder:

| Kontroll                                       | Hva den hindrer                                                                                        |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Bare `http:` og `https:`                       | `file:`, `ftp:` og andre skjemaer                                                                      |
| Bokstavelige IP-verter kontrolleres direkte    | `http://127.0.0.1:8080/`, `http://169.254.169.254/`                                                    |
| Navn kontrolleres i socketens eget DNS-oppslag | et navn som peker på en privat adresse, og DNS-rebinding — det finnes bare ett oppslag å komme imellom |
| Hvert redirect-hopp kontrolleres på nytt       | en offentlig kilde som sender kjøreren videre innover                                                  |

Avvist er loopback, private nett, operatørnett, link-local (inkludert skyens metadatatjeneste
på 169.254.169.254), multicast, dokumentasjons- og testnett, og de tilsvarende IPv6-områdene —
også når en IPv4-adresse er pakket inn i en IPv6-form. Svaret leses med en øvre
størrelsesgrense og et samlet tidsavbrudd, slik at en kilde ikke kan bruke opp minnet eller
tiden til kjøreren.

Konsekvens for drift: kontrollen gjelder adressen socketen kobler til. Skal kjøreren en dag stå
bak en utgående proxy på et privat nett, må det gjøres som en bevisst endring — ikke ved at
kontrollen mykes opp.
