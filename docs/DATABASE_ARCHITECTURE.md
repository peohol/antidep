# Antidep Database Architecture

**Versjon:** 0.1  
**Dato:** 18. august 2026  
**Status:** Første databasespesifikasjon  
**Styrende dokumenter:** [`ANTIDEP_CONSTITUTION.md`](./ANTIDEP_CONSTITUTION.md), [`KNOWLEDGE_MODEL.md`](./KNOWLEDGE_MODEL.md) og [`EVIDENCE_PIPELINE.md`](./EVIDENCE_PIPELINE.md)

## 1. Formål

Dette dokumentet oversetter Antideps kunnskapsmodell og evidenspipeline til en konkret, men fortsatt implementasjonsorientert databasearkitektur for PostgreSQL/Supabase.

Dokumentet skal være kontrakten som senere SQL-migrasjoner, API-er, agentarbeid og admin-UI avledes fra. Det etablerer derfor:

- skjema- og sikkerhetsgrenser
- tabellfamilier og sentrale relasjoner
- identitets- og revisjonsmønster
- regler for immutabilitet og historikk
- publiseringsmodell
- proveniens og audit
- tilgangsmodell og RLS-prinsipper
- regler for deterministiske importer
- API-projeksjoner
- integritetskrav som databasen selv skal håndheve

Dette dokumentet er **ikke** en ferdig SQL-migrasjon. Eksakte kolonnenavn, indekser, datatyper og funksjonssignaturer kan justeres under implementasjon så lenge invarianten og sikkerhetsmodellen i dette dokumentet bevares.

---

## 2. Arkitekturmål

Databasen skal gjøre følgende vanskelig eller umulig ved konstruksjon:

1. å publisere en klinisk påstand uten sporbar evidens og nødvendig godkjenning
2. å overskrive historiske revisjoner
3. å la en presentasjonstekst bli en separat sannhetskilde
4. å miste informasjon om hvem eller hva som gjorde en endring
5. å gi nettleserklienten direkte skriveadgang til kanoniske kunnskapstabeller
6. å bruke manglende data som om de betydde negativt funn
7. å slette historikk ved vanlig redaksjonelt arbeid
8. å gi en agent mer databaseadgang enn rollen trenger
9. å blande staging/importdata med publisert kunnskap
10. å gjøre publiseringsstatus avhengig av applikasjonslogikk alene

Databasen skal samtidig gjøre følgende enkelt:

- gjenbruke samme kunnskap i monografier, sammenligninger og verktøy
- finne den eksakte publiserte revisjonen av et objekt på et gitt tidspunkt
- vise hvorfor Antidep sier noe
- rulle tilbake til en tidligere faglig godkjent revisjon uten å slette nyere historikk
- oppdage hvilke publiserte påstander som påvirkes når en kilde korrigeres, trekkes tilbake eller erstattes
- regenerere avledede visninger og søkeindekser uten å endre kanoniske data

---

# Del I — PostgreSQL/Supabase-grunnmodell

## 3. Databasen er system of record

PostgreSQL skal være den kanoniske lagringsplassen for Antideps strukturerte kunnskap, evidensrelasjoner, arbeidsflytstatus, publiseringspekere og proveniens.

Følgende skal **ikke** være system of record:

- generert monografitekst
- søkeindeks
- embeddings
- cache
- klienttilstand
- LLM-samtaler
- statiske JSON-eksporter
- Markdown-dokumenter med legemiddelinnhold

Slike representasjoner kan avledes fra databasen og regenereres.

## 4. Supabase brukes som plattform, ikke som datamodell

Arkitekturen skal bruke standard PostgreSQL-primitiver der det er mulig:

- primær- og fremmednøkler
- `NOT NULL`
- `CHECK`
- `UNIQUE`
- transaksjoner
- views
- funksjoner
- triggere når deklarative constraints ikke er tilstrekkelige
- Row Level Security (RLS)
- eksplisitte `GRANT`/`REVOKE`

Supabase-spesifikke mekanismer skal hovedsakelig brukes for:

- Auth
- Data API
- eventuelt Storage
- server-/edge-integrasjon
- drift, migrasjoner og observabilitet

Kunnskapsmodellen skal ikke være avhengig av en Supabase-spesifikk datatype eller tjeneste dersom vanlig PostgreSQL løser problemet.

## 5. Eksponering skal være opt-in

Antidep skal aldri stole på plattformens standardprivilegier for nye tabeller.

Hver databaseobjekt-type skal eksplisitt få:

- schema-tilgang
- tabell-/view-/funksjonsprivilegier
- RLS der objektet kan nås via en eksponert rolle

Manglende eksplisitt grant skal behandles som ønsket standardtilstand.

---

# Del II — Skjemainndeling

## 6. Anbefalte PostgreSQL-skjemaer

Antidep bør starte med følgende logiske skjemaer:

| Schema | Formål | Data API |
|---|---|---|
| `catalog` | Virkestoffer, produkter, klassifikasjoner, kliniske begreper og andre relativt strukturelle domeneobjekter | Ikke direkte eksponert |
| `knowledge` | Claims, revisjoner, kilder, evidens, vurderinger, interaksjoner, anbefalinger og kliniske regler | Ikke direkte eksponert |
| `workflow` | EvidenceWorkUnits, agentkjøringer, verifikasjon, review-køer og arbeidsflytstatus | Ikke direkte eksponert |
| `provenance` | Aktører, pipeline-/modellversjoner og sporbarhetsrelasjoner | Ikke direkte eksponert |
| `audit` | Append-only hendelseslogg | Ikke direkte eksponert |
| `ingest` | Midlertidige snapshots og stagingdata fra eksterne kilder | Ikke direkte eksponert |
| `api` | Bevisst eksponerte views og RPC-er for bruker- og admin-klienter | Eksponert eksplisitt |

`public` skal ikke brukes som tilfeldig standardplass for nye Antidep-tabeller.

### 6.1 Hvorfor et eget `api`-schema

Nettleseren skal se et eksplisitt, smalt API-lag fremfor databasen som helhet.

Dette gir fire fordeler:

1. intern normalisering kan endres uten å endre klientkontrakten
2. sensitive workflow- og provenance-felter kan holdes private
3. publicerte data kan filtreres gjennom views
4. skriverettigheter kan kanaliseres gjennom kontrollerte operasjoner fremfor fri CRUD

`api` er derfor et kontraktslag, ikke den kanoniske datamodellen.

---

# Del III — Identitet, revisjoner og tidssemantikk

## 7. Stabil identitet + immutable revisjoner

Objekter som kan endre faglig betydning over tid skal følge mønsteret:

```text
identity row
  ├── revision 1
  ├── revision 2
  └── revision 3
          ↑
   current published pointer
```

Eksempel:

```text
knowledge.claims
knowledge.claim_revisions
```

`claims` representerer stabil identitet. `claim_revisions` representerer den eksakte faglige formuleringen og strukturerte betydningen i én versjon.

### 7.1 Revisjonsrader skal ikke overskrives

Etter innsetting skal faglig innhold i en revisjon være uforanderlig. En rettelse oppretter en ny revisjon.

Workflow-status skal derfor ikke tvinge oss til å mutere selve revisjonsinnholdet. Endringer i review- eller publiseringsstatus skal lagres separat som hendelser eller tilstandsobjekter.

### 7.2 Peker fremfor kopiering

Identitetstabellen kan inneholde pekere som:

- `current_draft_revision_id`
- `current_published_revision_id`

Publisering flytter en peker atomisk etter validering; den kopierer ikke innhold til en ny «published claims»-tabell.

### 7.3 Tidsbegreper må skilles

Der de er relevante, skal minst følgende semantikk holdes adskilt:

- `created_at`: når Antidep opprettet raden
- `recorded_at`: når Antidep registrerte hendelsen eller faktaet
- `valid_from` / `valid_to`: når faktaet gjelder i den eksterne virkeligheten
- `published_at`: når Antidep publiserte en revisjon
- `review_due_at`: når ny vurdering er forventet

Et norsk produkt kan for eksempel være registrert i databasen i august, men ha markedsstatus som gjelder fra en tidligere eller senere dato.

## 8. Identifikatorer

Kanoniske objekter bør bruke databasegenererte UUID-er som interne primærnøkler.

Eksterne identifikatorer — DOI, PMID, ATC-kode, FEST-ID, varenummer og lignende — skal lagres som egne felter eller identifikatorrelasjoner og skal ikke brukes som eneste interne primærnøkkel.

Begrunnelse:

- eksterne ID-er kan mangle
- samme objekt kan ha flere ID-systemer
- identifikatorregler kan endres
- interne relasjoner skal være stabile selv om metadata korrigeres

---

# Del IV — Domene- og katalogtabeller

## 9. `catalog.drugs`

Stabil identitet for virkestoff.

Minimum:

```text
drug_id PK
canonical_name
status
created_at
```

Navneendringer og aliaser bør ligge i separat tabell, eksempelvis `drug_names`, slik at søk kan støtte historiske og alternative navn uten å endre kanonisk identitet.

## 10. `catalog.drug_products`

Representerer et identifiserbart norsk legemiddelprodukt eller en produktpresentasjon.

Kjernefelter bør inkludere:

```text
product_id PK
drug_id FK
external_source_system
external_record_id
trade_name
form_code
route_code
strength_value
strength_unit
release_type
market_context
valid_from
valid_to
source_id FK
```

### 10.1 Norske markedsdata behandles temporalt

En unikhet som «sertralin + 50 mg + tablett» er ikke tilstrekkelig identitet. Handelsnavn, pakning, formulering og markedsstatus kan endres.

Produktobjekter skal derfor beholde:

- ekstern kildereferanse
- tidsvaliditet
- import-/snapshot-proveniens

## 11. `catalog.clinical_concepts`

Kontrollert begrepsstruktur for temaer som vektøkning, seksuell dysfunksjon, sedasjon, hyponatremi og graviditet.

Minimum:

```text
concept_id PK
canonical_label
concept_type
parent_concept_id FK NULL
status
```

Synonymer skal ligge separat. Hierarkiet skal ikke kopiere klinisk innhold; det organiserer innholdet.

## 12. `catalog.populations`

Populasjon bør normaliseres nok til at viktige gyldighetsgrenser kan spørres på strukturert.

En første versjon kan kombinere:

- en stabil `population_id`
- en kort kanonisk etikett
- strukturerte dimensjoner for alder, indikasjon/diagnose, graviditet/amming og sentral komorbiditet

Modellen bør unngå å lage en unik rad for enhver tenkelig kombinasjon hvis det fører til kombinatorisk eksplosjon. Endelig normaliseringsgrad avgjøres under schema-design.

---

# Del V — Claims og publisert kunnskap

## 13. `knowledge.claims`

Stabil identitet for en påstand.

Minimum:

```text
claim_id PK
knowledge_type
topic_id FK
created_at
created_by_actor_id FK
current_published_revision_id FK NULL
retired_at NULL
```

Tillatte `knowledge_type` skal minst dekke:

- `deterministic_fact`
- `evidence_synthesis`
- `clinical_recommendation`

## 14. `knowledge.claim_revisions`

Immutable faglig versjon av et claim.

Minimum:

```text
claim_revision_id PK
claim_id FK
revision_number
statement
scope
population_id FK NULL
timeframe_value/timeframe_code NULL
comparator_type/comparator_id NULL
direction NULL
magnitude_value NULL
magnitude_unit_or_measure NULL
qualifiers NULL
uncertainty_summary NULL
supersedes_revision_id FK NULL
created_at
created_by_actor_id FK
content_hash
```

Krav:

- `UNIQUE (claim_id, revision_number)`
- en revisjon kan ikke `supersede` seg selv
- `supersedes_revision_id` må tilhøre samme `claim_id`
- publisert revisjon må være en revisjon av samme `claim_id`

Det siste og nest siste kravet er tverrradskrav og kan kreve en kombinasjon av sammensatte fremmednøkler, transaksjonsfunksjoner eller triggere.

### 14.1 `content_hash`

Revisjoner bør ha en deterministisk hash av de kanoniske faglige feltene.

Formål:

- oppdage identiske agentforslag
- unngå unødvendige duplikatrevisjoner
- gjøre audit og reproduksjon enklere

Hashen er et hjelpemiddel, ikke en erstatning for revisjons-ID eller faglig vurdering.

## 15. Livssyklus skal ikke skjules i ett muterbart statusfelt

I stedet for å gjøre `claim_revisions.status` til eneste sannhet bør livssyklusen representeres som eksplisitte hendelser eller beslutninger.

Anbefalt:

```text
workflow.review_decisions
knowledge.publication_events
workflow.review_requirements
```

En avledet «nåværende status» kan bygges som view eller materialisert projeksjon.

Dette gjør det mulig å se at samme revisjon eksempelvis:

1. ble kildeverifisert
2. fikk faglig godkjenning
3. ble publisert
4. senere ble markert `review_due`
5. til slutt ble erstattet

uten å miste mellomtilstandene.

---

# Del VI — Kilder, studier og evidens

## 16. `knowledge.sources`

Representerer en konkret rapport, publikasjon, retningslinje, regulatorisk dokument eller datasett.

Minimum:

```text
source_id PK
source_type
title
publisher_or_journal
publication_date
source_status
created_at
```

Bibliografiske identifikatorer bør normaliseres i:

```text
knowledge.source_identifiers
```

med felter som:

```text
source_id FK
identifier_type
identifier_value
```

og hensiktsmessige unike constraints for DOI, PMID og andre globale ID-er.

## 17. Studie og rapport bør kunne skilles

Flere publikasjoner kan beskrive samme underliggende studie. Antidep bør derfor støtte:

```text
knowledge.studies
knowledge.study_sources
```

Dette er særlig viktig for å unngå dobbelttelling i synteser.

En `Source` er det dokumentet vi leser; en `Study` er den underliggende undersøkelsen når dette skillet er relevant.

## 18. `knowledge.source_versions`

Levende kilder — eksempelvis offentlige nettsider, preparatomtaler og datasett — kan endres uten å få ny URL.

For slike kilder bør Antidep kunne lagre versjon/snapshot-metadata:

```text
source_version_id PK
source_id FK
retrieved_at
external_version
content_hash
storage_reference NULL
```

Fulltekst skal bare lagres når det er tillatt og nødvendig. Ellers skal metadata, hash og presis kildepeker brukes.

## 19. `knowledge.evidence_items`

Ett konkret ekstrahert funn fra én kildeversjon.

Minimum bør dekke:

```text
evidence_item_id PK
source_id FK
source_version_id FK NULL
study_id FK NULL
population_id FK NULL
design_code
sample_size NULL
intervention_subject_id/comparator_subject_id NULL
outcome_concept_id FK
timepoint_value/timepoint_unit NULL
effect_measure_code NULL
estimate NULL
ci_lower NULL
ci_upper NULL
absolute_effect NULL
limitations_text NULL
source_locator
extraction_method
created_at
created_by_actor_id FK
content_hash
```

### 19.1 Manglende verdier skal ha semantikk

For klinisk viktige felt bør systemet skille mellom minst:

- `reported_value`
- `not_reported`
- `not_applicable`
- `not_extractable`
- `uncertain_extraction`

`NULL` alene er ofte for tvetydig.

Dette kan implementeres med separate statusfelt for de feltene hvor skillet er viktig, eller en strukturert `missingness`-modell.

## 20. Rå ekstraksjon og kanoniske felt

Kildespesifikke eller ustrukturerte detaljer kan lagres som `jsonb`, men sentrale spørre- og valideringsfelter skal være relasjonelle kolonner/FK-er.

Regel:

> JSONB kan bevare variasjon; JSONB skal ikke skjule kjernemodellen.

Eksempel: et komplett agentuttrekk kan lagres som rå payload for reproduksjon, mens effektmål, estimat, populasjon og tidsramme samtidig normaliseres til validerbare kolonner.

## 21. `knowledge.claim_evidence_links`

Typed many-to-many-relasjon mellom en bestemt claim-revisjon og et evidensfunn.

Minimum:

```text
claim_evidence_link_id PK
claim_revision_id FK
evidence_item_id FK
relationship_type
relevance_note
created_at
created_by_actor_id FK
```

`relationship_type` skal minst støtte:

- `supports`
- `partially_supports`
- `contradicts`
- `indirect`

Krav:

- samme claim-revisjon/evidence-item-relasjon skal ikke dupliseres uten eksplisitt grunn
- motstridende lenker skal være like bevaringsverdige som støttende lenker

## 22. `knowledge.evidence_assessments`

Versjonert vurdering av den samlede evidensen for en bestemt claim-revisjon eller et definert evidensspørsmål.

Bør kunne representere:

```text
assessment_id PK
claim_revision_id FK
framework
certainty_level
risk_of_bias
inconsistency
indirectness
imprecision
publication_bias
other_considerations
rationale
created_at
created_by_actor_id FK
```

`certainty_level` og domenene skal aldri utledes kun fra antall kilder.

En senere mer avansert modell kan skille vurderingen fra selve claim-revisjonen for å støtte flere samtidige faglige vurderinger, men MVP-en bør sikre én eksplisitt godkjent vurdering for hver publisert evidenssyntese der vurdering kreves.

---

# Del VII — Kliniske anbefalinger, interaksjoner og regler

## 23. Kliniske anbefalinger er claims med strengere krav

`clinical_recommendation` skal ikke få en parallell fritekstdatabase. Den skal bruke samme claim/revision/evidence-modell, men få ekstra strukturerte relasjoner når de trengs.

Eksempelvis:

```text
knowledge.recommendation_details
```

kan knytte en claim-revisjon til:

- målpopulasjon
- handling
- styrke/formulering av anbefaling
- unntak
- nødvendig monitorering
- begrunnelse

## 24. `knowledge.interactions`

Interaksjoner bør ha stabil identitet og versjonert innhold.

Modellen må kunne uttrykke minst:

- legemiddel A
- legemiddel/klasse/faktor B
- retning
- mekanisme
- forventet eksponerings- eller effektendring
- klinisk konsekvens
- håndteringsråd
- evidens og sikkerhet

Interaksjonsvisninger skal avledes fra disse objektene og underliggende claims/evidens, ikke skrives separat.

## 25. `knowledge.clinical_rules`

Deterministiske regler for eksempelvis dose-, bytte- eller nedtrappingslogikk skal være eksplisitte, versjonerte dataobjekter eller versjonert kode med databasekoblet metadata.

Databasen skal minst kunne lagre:

```text
clinical_rule_id
rule_type
rule_version
inputs_schema
outputs_schema
rule_artifact_reference
valid_from
valid_to
review_status
approved_by_actor_id
approved_at
```

Selve beregningsmotoren kan ligge i applikasjonskode dersom dette er bedre testbart enn SQL.

Viktig invariant:

> Det skal være mulig å identifisere nøyaktig hvilken regelversjon som produserte et klinisk resultat.

---

# Del VIII — Evidence pipeline og workflow

## 26. `workflow.evidence_work_units`

Databaseobjektet som avgrenser én evidensoppgave.

Bør inneholde:

```text
work_unit_id PK
question
scope
population_definition
intervention_definition
comparator_definition
outcome_definition
timeframe_definition
knowledge_type_target
priority
risk_level
created_at
created_by_actor_id
closed_at NULL
```

Alle agentkjøringer og reviewhandlinger bør kunne kobles til en work unit når de er del av evidenspipelinen.

## 27. Søkehistorikk

For reproduksjon bør databasen støtte minst:

```text
workflow.search_plans
workflow.search_runs
workflow.search_results
```

`search_run` bør fange:

- database/søketjeneste
- eksakt eller rekonstruerbar søkestreng
- dato/tid
- filtre
- agent/pipelineversjon
- antall treff

`search_result` bør koble kandidaten til `Source` når den senere normaliseres.

## 28. Kildeutvelgelse

Inklusjon og eksklusjon skal være egne beslutninger, ikke sletting av kandidater.

Eksempel:

```text
workflow.source_screening_decisions
```

med:

```text
work_unit_id
source_candidate_id/source_id
decision
reason_code
reason_text
actor_id
created_at
```

Dette gjør søket etterprøvbart og gjør det mulig å oppdage systematiske skjevheter i agentenes utvelgelse.

## 29. Ekstraksjonsverifikasjon

Ekstraksjon og verifikasjon må være separate hendelser.

Anbefalt:

```text
workflow.evidence_verifications
```

som peker til `evidence_item_id` og inneholder:

- verifikator
- resultat: `verified`, `needs_correction`, `rejected`, `uncertain`
- kontrollerte felter
- avvik
- tidspunkt

En korrigert ekstraksjon oppretter et nytt `EvidenceItem` eller en ny immutable evidensrevisjon; den gamle skal ikke silently overskrives.

Skriveveien inn i `workflow.evidence_verifications` er `api.register_extraction_verification(...)`: en autentisert agentidentitet i rollen `extraction_verification`, inne i en åpen `provenance.agent_run` i samme rolle. Aktør, rolle og kjøring er ikke parametre kalleren oppgir — de utledes av autentiseringen (§49) og av kjøringen selv (§33) — og bindingen mellom verifikasjonsraden og kjøringen er deklarativ, med to sammensatte fremmednøkler mot `provenance.agent_runs (id, actor_id)` og `(id, agent_role)`, som §33 og §59 beskriver. Kravet om at verifikator og ekstraktør er ulike aktører (§74.31 i implementasjonsplanen) er en egen `CHECK` på tabellen, uendret av skriveveien.

## 30. Claim-verifikasjon

Claim-verifikasjon skal være eksplisitt og minst dekke:

- støtter kilden faktisk ordlyden?
- er populasjonen korrekt?
- er komparatoren korrekt?
- er tidsrammen korrekt?
- er retning og numeriske størrelser korrekt?
- mangler vesentlige forbehold?
- finnes relevant motstridende evidens som ikke er representert?

Dette kan ligge i:

```text
workflow.claim_verifications
```

## 31. Human review

Menneskelig faglig review skal lagres som beslutningsobjekter, ikke bare `approved_by` på innholdsraden.

Eksempel:

```text
workflow.review_decisions
```

med:

```text
review_decision_id PK
object_type
object_id
review_type
decision
rationale
reviewer_actor_id
created_at
```

Dette gjør det mulig å bevare både godkjenninger, avslag og senere omgjøringer.

---

# Del IX — Proveniens og agentkjøringer

## 32. `provenance.actors`

Alle betydningsfulle handlinger skal peke til en normalisert aktør.

Aktørtyper kan minst være:

- `human`
- `agent`
- `deterministic_process`
- `external_import`
- `system`

En menneskelig aktør kan kobles til `auth.users`, men faglig historikk skal ikke forsvinne dersom brukerprofilen senere deaktiveres.

## 32.1 `provenance.agent_identities`

En agent kan ikke ha en brukerkonto (§32 sitt skille mellom aktørtyper er avgjørende, ikke
kosmetisk), og `service_role` er ikke applikasjonens universalnøkkel (§49). En KI-prosess som
skal skrive til kunnskapsbasen, trenger derfor en egen teknisk identitet:

```text
agent_identity_id PK
actor_id FK → provenance.actors     (unik: én identitet per agentaktør)
agent_role                          (speil av aktørens rolle, låst av sammensatt FK)
identity_key                        (stabil maskinnøkkel)
secret_hash NULL                    (hashet legitimasjon; NULL = ikke utstedt)
secret_version
secret_issued_at NULL
secret_issued_by_actor_id NULL      (må være en human-aktør)
valid_from
valid_to NULL                       (tilbakekalling; krever aktør og begrunnelse)
registered_by_actor_id              (må være en human-aktør)
registration_reason
```

Rollen er rettighetsgrensen. Autentiseringen krever den rollen operasjonen faktisk trenger, så
en identitet i ett pipelineledd kan ikke utføre et annet pipelineledds operasjon — heller ikke
med gyldig legitimasjon. Flere uavhengige kontrollag skaleres ved å registrere flere aktører
med samme rolle, ikke ved å gi én identitet flere roller.

Legitimasjonen skal aldri lagres i klartekst, og hashen bør bindes til identitetsnøkkelen slik
at en lekket hash ikke kan spilles av mot en annen identitet. Registrering, utstedelse og
tilbakekalling er rettighetsendringer og skal auditeres (§35).

At bare et menneske kan registrere en agentidentitet eller utstede legitimasjon til den, skal
være håndhevet deklarativt, ikke bare beskrevet: en agent som kunne registrere agenter, ville
vært en rettighetseskalering med ett ekstra ledd.

## 33. `provenance.agent_runs`

Hver KI-kjøring som produserer eller verifiserer kunnskapsobjekter bør registrere:

```text
agent_run_id PK
agent_identity_id FK → provenance.agent_identities
actor_id                            (speil, låst av sammensatt FK)
agent_role                          (speil, låst av sammensatt FK)
work_unit_id FK NULL
provider
model
model_version_or_identifier
prompt_template_version
pipeline_version
started_at
completed_at
status
input_manifest
output_manifest
```

Promptens fulle innhold trenger ikke nødvendigvis ligge direkte i raden dersom det finnes en versjonert, innholdsadressert promptartefakt.

Aktør og rolle bør ligge som speilkolonner låst til identiteten, og kjøringen bør selv være
refererbar på `(id, actor_id)` og `(id, agent_role)`. Da kan et objekt en kjøring produserte,
kreve deklarativt at det ble produsert av den kjøringen det attribueres til, og i riktig rolle
— framfor at hver skrivevei kontrollerer det i funksjonskode (§59).

En kjøring åpnes én gang og lukkes én gang. Premissene bør være uforanderlige, og ingen kjøring
bør kunne slettes: en kjøring som kunne omskrives i ettertid, dokumenterer ingenting.

## 34. Proveniens er en graf

Et sluttobjekt skal kunne spores bakover:

```text
published claim revision
  → evidence assessment
  → claim/evidence links
  → evidence items
  → source versions
  → source
  → extraction agent run
  → verification run
  → human review decision
```

Datamodellen trenger ikke en generell grafdatabase. Relasjonelle FK-er er tilstrekkelig så lenge kjeden er komplett.

---

# Del X — Audit og immutabilitet

## 35. `audit.events`

Antidep skal ha en append-only auditlogg for sikkerhets- og forvaltningskritiske operasjoner.

Bør minimum lagre:

```text
audit_event_id PK
occurred_at
actor_id
operation
object_schema
object_table
object_id
old_revision_or_snapshot NULL
new_revision_or_snapshot NULL
request_or_run_id NULL
reason NULL
```

Auditloggen er et supplement til revisjonsmodellen. Den skal ikke være eneste sted hvor historiske faglige versjoner finnes.

## 36. Ingen normal `DELETE` på kanoniske kunnskapstabeller

Vanlig redaksjonelt arbeid skal bruke:

- `retired_at`
- `superseded`
- publiseringspeker
- status-/beslutningshendelser

fremfor fysisk sletting.

Fysisk sletting skal reserveres for:

- feilopprettede objekter før de inngår i noen referert historikk
- personvern-/sikkerhetskrav som faktisk krever sletting
- eksplisitte administrative vedlikeholdsoperasjoner

og skal i så fall ha særskilt audit.

## 37. Fremmednøkler skal som hovedregel bruke `RESTRICT`

`ON DELETE CASCADE` skal ikke brukes bredt i evidens- eller publikasjonshistorikk.

Hvis en Source er referert av EvidenceItems, eller en ClaimRevision av publiseringshistorikk, skal tilfeldig sletting feile fremfor å fjerne kjeden.

Cascade kan brukes i rent tekniske, avledede eller midlertidige tabeller hvor forelderen faktisk eier hele levetiden til barnet.

---

# Del XI — Publisering

## 38. Publisering er en database-transaksjon

Publisering skal skje gjennom én kontrollert operasjon som enten lykkes fullstendig eller ikke gjør noen endring.

Operasjonen skal før commit validere kravene for objektets kunnskapstype og risikonivå.

For en `evidence_synthesis` skal den typisk kontrollere at:

- claim-revisjonen finnes
- revisjonen er immutable og komplett
- nødvendige EvidenceItems finnes
- relevante EvidenceItems er verifisert
- ClaimEvidenceLinks er kontrollert
- EvidenceAssessment finnes
- ingen blokkerende verifikasjonsfunn er åpne
- nødvendig menneskelig review er godkjent
- review ikke er utløpt

For en `clinical_recommendation` skal terskelen være minst like streng og normalt kreve eksplisitt navngitt klinisk godkjenning.

## 39. `knowledge.publication_events`

Alle publiseringer og avpubliseringer skal registreres append-only.

Minimum:

```text
publication_event_id PK
object_type
object_id
revision_id
action
published_at
published_by_actor_id
previous_revision_id NULL
reason
```

Tillatte handlinger kan være:

- `publish`
- `replace`
- `withdraw`
- `rollback`

## 40. Rollback er ny historikk

Rollback skal ikke slette den problematiske publiseringen. Den skal opprette en ny publiseringshendelse og flytte publiseringspekeren tilbake til en tidligere godkjent revisjon.

Dermed kan Antidep i ettertid svare på både:

- «Hva sier vi nå?»
- «Hva sa vi på dato X, og hvorfor?»

---

# Del XII — API- og lesemodell

## 41. Offentlig klient skal primært lese avledede views

Eksempler i `api`:

```text
api.drugs
api.drug_products_current
api.published_claims
api.claim_evidence_summary
api.drug_monograph_sections
api.comparison_dimensions
api.interactions_current
```

Disse skal bare vise data som er publiserte og egnet for den aktuelle klientrollen.

## 42. Views skal ikke utilsiktet omgå RLS

Views i eksponerte schema skal opprettes med sikkerhetssemantikk som gjør at underliggende tilgangskontroll ikke omgås. Der PostgreSQL-versjonen støtter det skal `security_invoker` være standard for views som bygger på RLS-beskyttede data.

Hvis et view krever privilegert tilgang, skal dette være et eksplisitt designvalg med egen trusselvurdering, ikke en bivirkning av hvem som opprettet viewet.

## 43. Klienten skal ikke skrive direkte til kanoniske tabeller

Admin-UI skal bruke kontrollerte RPC-er/API-operasjoner for handlinger som:

- opprette ny claim-revisjon
- koble evidens
- godkjenne/rejecte
- publisere
- rulle tilbake
- markere kilde som erstattet eller trukket tilbake

Fordelen er at operasjonen kan håndheve invariants atomisk og auditere begrunnelsen.

Dette betyr ikke at all logikk skal ligge i PostgreSQL. En serverfunksjon kan orkestrere operasjonen, men databasen skal fortsatt håndheve de integritetsreglene som kan uttrykkes der.

## 44. Data API-kontrakten skal være eksplisitt

Antidep skal aldri anta at en ny tabell automatisk er tilgjengelig via Supabase Data API.

Eksponering krever bevisst:

1. schema-eksponering
2. `GRANT`
3. RLS/policy der relevant
4. test med faktisk `anon`/`authenticated`-rolle

---

# Del XIII — Autorisasjon og RLS

## 45. Roller på applikasjonsnivå

En første modell bør støtte minst:

| Rolle | Hovedrettigheter |
|---|---|
| `public_reader` | Lese publisert offentlig kunnskap |
| `editor` | Lage og redigere utkast/foreslå revisjoner |
| `reviewer` | Faglig verifisere og godkjenne innen tildelt område |
| `publisher` | Utføre kontrollert publisering etter oppfylte gates |
| `admin` | Bruker-/rolleforvaltning og systemadministrasjon |
| `agent_worker` | Avgrenset maskintilgang til eksplisitte pipeline-operasjoner |

En person kan ha flere roller.

`agent_worker` er ikke en rad i medlemskapsmodellen i §47: en agent har ingen brukerkonto å
knytte en tildeling til. Den hører til `provenance.agent_identities` (§32.1), der
rettighetsgrensen er agentrollen på aktøren framfor et `role_code` på en konto.

## 46. Autorisasjonsdata skal ikke komme fra brukerredigerbar metadata

Hvis JWT-claims brukes for roller, skal de komme fra serverstyrt/app-metadata, ikke brukerredigerbar metadata.

For rettigheter som må kunne tilbakekalles umiddelbart, bør RLS eller serveroperasjonen kontrollere en databasebasert medlemskapstabell fremfor å stole utelukkende på en mulig utdatert JWT.

## 47. Anbefalt medlemskapsmodell

Eksempel:

```text
workflow.user_roles
  user_id FK → auth.users
  role_code
  scope_type NULL
  scope_id NULL
  valid_from
  valid_to NULL
```

Dette tillater senere scoped review, for eksempel at en reviewer er godkjent for bestemte innholdsområder.

## 48. RLS: default deny

Alle tabeller som på noen måte kan nås av `anon` eller `authenticated` skal ha RLS og eksplisitte policies.

Ingen policy skal bare si «alle authenticated kan skrive» dersom handlingen krever faglig rolle.

En typisk write-policy eller RPC skal kontrollere:

- autentisert bruker
- relevant rolle
- eventuelt scope
- objektets workflow-status

## 49. `service_role` er ikke applikasjonens universalnøkkel

`service_role` omgår RLS og skal aldri finnes i nettleserklienten.

Bakgrunnsprosesser og agenter bør, så langt praktisk mulig, bruke egne least-privilege databaseidentiteter eller smale serveroperasjoner fremfor en felles nøkkel med full tilgang.

## 50. Privilegerte databasefunksjoner

`SECURITY INVOKER` skal være standard.

Hvis `SECURITY DEFINER` er nødvendig, skal funksjonen:

- ha eksplisitt og sikkert `search_path`
- ligge i et bevisst valgt schema
- ha `EXECUTE` revokert fra `PUBLIC`
- kun grants til nødvendige roller
- validere caller og input selv
- være liten og gjennomgått som sikkerhetskritisk kode

`SECURITY DEFINER` skal aldri brukes som rask løsning på en RLS-feil.

---

# Del XIV — Import og eksterne kilder

## 51. `ingest` er en karantene, ikke kunnskapsbasen

Data fra FEST/FHIR, preparatomtaler, bibliografiske API-er eller andre eksterne systemer skal først kunne landes som snapshot/staging.

Typisk flyt:

```text
external source
  ↓
ingest snapshot
  ↓
validation + normalization
  ↓
canonical catalog/knowledge objects
  ↓
publication
```

En importjobb skal ikke skrive direkte over manuelt godkjente kanoniske objekter uten endringsdeteksjon og definerte regler.

## 52. Importer skal være idempotente

Samme eksterne snapshot skal kunne behandles flere ganger uten å opprette semantisk dupliserte kanoniske rader.

Nyttige mekanismer:

- ekstern record-ID
- kildeversjon
- content hash
- unik constraint på relevant ekstern nøkkel + snapshot

## 53. Endringsdeteksjon skal klassifisere betydning

En ekstern endring skal ikke bare gi «row changed».

Systemet bør kunne skille:

- ren metadataendring
- ny produktstyrke/form
- markedsstatusendring
- endring som påvirker klinisk regel
- endring som potensielt gjør publisert tekst utdatert

De siste kategoriene skal kunne opprette review work units automatisk.

---

# Del XV — Søk, cache og avledede data

## 54. Fulltekstsøk er en projeksjon

PostgreSQL full-text search, ekstern søketjeneste eller annen indeks kan brukes, men indeksen skal bygges fra kanoniske publiserte objekter.

Sletting og gjenbygging av søkeindeks skal ikke påvirke faglig historikk.

## 55. Embeddings er ikke evidens

Hvis embeddings senere brukes til semantisk søk eller retrieval:

- de er avledede data
- embedding-modell og versjon skal registreres
- de skal kunne regenereres
- nærhet i embedding-rom skal aldri registreres som evidensrelasjon

## 56. Cache kan være aggressiv fordi publisering er versjonert

Publiserte views kan caches dersom cache-nøkkelen inkluderer relevant innholds-/publiseringsversjon.

En ny publisering skal invalidere eller versjonere berørt cache deterministisk.

---

# Del XVI — Integritetsregler databasen skal håndheve

## 57. Deklarative constraints først

Bruk prioriteringsrekkefølgen:

1. datatype
2. `NOT NULL`
3. `CHECK`
4. `UNIQUE`
5. `FOREIGN KEY`
6. partial unique index / exclusion constraint
7. trigger eller kontrollert transaksjonsfunksjon
8. kun applikasjonsvalidering som siste lag

Forretningskritisk integritet skal ikke bare leve i TypeScript/Zod.

## 58. Representative invariants

Databaseimplementasjonen skal kunne håndheve eller eksplisitt validere minst:

- `revision_number > 0`
- bare én revisjon med samme `(claim_id, revision_number)`
- publiseringspeker peker på revisjon av riktig identity
- evidence link peker på eksisterende immutable objekter
- `valid_to > valid_from` når begge finnes
- CI-grenser kan ikke være invertert når de representerer et vanlig intervall
- `sample_size > 0` når rapportert
- kun definerte relationship types
- kliniske anbefalinger kan ikke publiseres uten påkrevd human approval
- evidence synthesis kan ikke publiseres uten evidensvurdering når policyen krever det
- withdrawn/retired source kan ikke ubemerket tilfredsstille en gate som om statusen var normal

## 59. Cross-row-regler må ikke presses inn i `CHECK`

Constraints som avhenger av andre rader/tabeller skal bruke riktig mekanisme — FK, unique/exclusion, trigger eller kontrollert publiseringsfunksjon — fremfor `CHECK` som leser andre tabeller.

## 60. Ingen generelle «magic triggers»

Triggere skal brukes sparsomt og dokumenteres.

Gode triggerkandidater:

- immutable-row guard
- append-only audit
- enkelte tverrrad-invariants som ikke kan uttrykkes deklarativt

Dårlige triggerkandidater:

- store skjulte workflower
- omfattende klinisk forretningslogikk
- agentorkestrering

---

# Del XVII — Transaksjoner og samtidighet

## 61. Kritiske operasjoner skal være atomiske

Minst følgende skal utføres transaksjonelt:

- opprett claim + første revisjon
- publisering/erstatning av revisjon
- rollback
- endring av kilde til `retracted` med opprettelse av berørte review-flagg
- godkjenning når beslutningen oppdaterer en current-state-projeksjon

## 62. Optimistic concurrency i admin-UI

Når to redaktører arbeider samtidig, skal den andre ikke kunne overskrive den førstes arbeid ved et gammelt skjermbilde.

Write-operasjoner bør derfor kreve forventet versjon/revisjon eller tilsvarende precondition.

Konflikt skal gi eksplisitt feilmelding og diff/ny vurdering, ikke «last write wins».

---

# Del XVIII — Personvern og dataminimering

## 63. Kunnskapsbasen skal ikke inneholde pasientjournaldata

MVP-ens sentrale database er en kunnskapsdatabase, ikke en pasientdatabase.

Det skal ikke opprettes generiske fritekstfelt «for sikkerhets skyld» som inviterer til lagring av:

- navn
- fødselsnummer
- journaltekst
- kliniske kasus med identifiserbare opplysninger

## 64. Fremtidige pasientspesifikke funksjoner skal separeres

Hvis Antidep senere trenger å lagre pasientspesifikke opplysninger, skal dette vurderes som et eget dataområde med separat trusselmodell, rettslig grunnlag, tilgangsmodell, retention-policy og regulatorisk vurdering.

Det skal ikke bare legges noen pasientkolonner inn i `knowledge`.

---

# Del XIX — Drift, migrasjoner og testing

## 65. Schema endres bare via versjonerte migrasjoner

Når implementasjonen starter skal alle varige DDL-endringer ligge i repoets migrasjonshistorikk.

Direkte manuelle produksjonsendringer i Supabase Dashboard skal ikke være normal arbeidsflyt.

Hvis en hasteendring gjøres manuelt, skal den umiddelbart rekonstrueres i migrasjonshistorikken og dokumenteres.

## 66. Migrasjoner skal være små og reviewbare

Hver migrasjon bør ha ett forståelig formål.

Store «initial_schema.sql» som samtidig etablerer hundre tabeller, RLS, funksjoner og seed-data bør unngås hvis det gjør review og rollback-analyse vanskelig.

## 67. Database-testing er en del av funksjonen

Testpakken skal minst dekke:

- constraints
- FK-integritet
- immutabilitet
- publiseringsgates
- rollback
- RLS for `anon`
- RLS for ordinær authenticated bruker
- editor/reviewer/publisher-rettigheter
- agent worker med minst mulige privilegier
- forsøk på privilege escalation
- source retraction propagation
- idempotent import
- concurrent edit-konflikt

## 68. Sikkerhetskontroll etter schemaendringer

Før produksjonssetting skal relevante Supabase/PostgreSQL-advisors og sikkerhetstester kjøres.

Særlig skal nye:

- views
- functions
- RLS policies
- grants
- triggers

behandles som sikkerhetsrelevante endringer, ikke bare databasekomfort.

---

# Del XX — Anbefalt første fysiske schema

## 69. MVP-tabellsett

Første implementasjon bør ikke bygge hele fremtidsmodellen. Følgende er et anbefalt minimum som likevel bevarer arkitekturen:

### `catalog`

```text
drugs
drug_names
drug_products
clinical_concepts
populations
```

### `knowledge`

```text
claims
claim_revisions
sources
source_identifiers
source_versions
studies
study_sources
evidence_items
claim_evidence_links
evidence_assessments
publication_events
```

### `workflow`

```text
evidence_work_units
search_runs
source_screening_decisions
evidence_verifications
claim_verifications
review_decisions
user_roles
```

### `provenance`

```text
actors
agent_identities
agent_runs
```

### `audit`

```text
events
```

### `ingest`

Start med kildespesifikke stagingtabeller først når første faktiske import implementeres.

### `api`

```text
published_drugs
published_claims
published_claim_evidence
```

og et lite sett med kontrollerte admin-RPC-er.

## 70. Bevisst utsatt fra MVP-schema

Følgende bør **ikke** modelleres ferdig før en konkret funksjon krever det:

- full beslutningsstøttemotor
- omfattende farmakogenetikkmodell
- TDM-modell
- komplette interaksjonsontologier
- pasientprofiler
- embeddingtabeller
- avansert lokal/institusjonell overlay
- generisk regel-DSL

Arkitekturen skal gjøre disse mulige senere uten at de må oppfinnes nå.

---

# Del XXI — Eksempel: fra studie til publisert claim

## 71. Eksempel

Anta at Antidep skal representere en påstand om vektendring ved mirtazapin.

### Katalog

```text
catalog.drugs
  drug_id = D1
  canonical_name = "mirtazapin"

catalog.clinical_concepts
  concept_id = C1
  canonical_label = "vektøkning"
```

### Kilde

```text
knowledge.sources
  source_id = S1
  type = "systematic_review"

knowledge.source_versions
  source_version_id = SV1
  source_id = S1
  content_hash = ...
```

### Evidens

```text
knowledge.evidence_items
  evidence_item_id = E1
  source_version_id = SV1
  outcome_concept_id = C1
  comparator = placebo
  effect_measure = ...
  estimate = ...
  source_locator = ...
```

### Verifikasjon

```text
workflow.evidence_verifications
  evidence_item_id = E1
  decision = verified
```

### Claim

```text
knowledge.claims
  claim_id = CL1
  knowledge_type = evidence_synthesis
  topic_id = C1

knowledge.claim_revisions
  claim_revision_id = CLR1
  claim_id = CL1
  revision_number = 1
  statement = ...
```

### Relasjon og vurdering

```text
knowledge.claim_evidence_links
  claim_revision_id = CLR1
  evidence_item_id = E1
  relationship_type = supports

knowledge.evidence_assessments
  claim_revision_id = CLR1
  certainty_level = ...
```

### Human review og publisering

```text
workflow.review_decisions
  object_id = CLR1
  decision = approved

knowledge.publication_events
  object_id = CL1
  revision_id = CLR1
  action = publish
```

Deretter peker `knowledge.claims.current_published_revision_id` til `CLR1`, og `api.published_claims` viser revisjonen.

Ingen monografitekst må kopieres inn i en separat sannhetstabell.

---

# Del XXII — Avgjørelser som skal tas under implementasjon

## 72. Åpne tekniske valg

Følgende er bevisst ikke fastlåst i versjon 0.1:

- eksakt UUID-genereringsstrategi
- om enkelte kontrollerte vokabularer skal være lookup-tabeller, domains eller PostgreSQL-enums
- hvor langt `Population` normaliseres i MVP
- om EvidenceItem selv skal ha revisjonstabell fra dag én eller være immutable med erstatningsrelasjon
- om enkelte API-lesemodeller bør være views, materialized views eller vanlige projeksjonstabeller
- om admin-skriving bør gå gjennom Postgres RPC, serverfunksjoner eller en kombinasjon
- detaljene i scope-baserte reviewerrettigheter
- hvilke rå kildeartefakter som skal ligge i Supabase Storage
- hvilken søke-/embeddingløsning som eventuelt velges

Disse valgene skal avgjøres ut fra konkret implementasjonsbehov og benchmark/test, ikke smak.

---

# Del XXIII — Ikke-forhandlingsbare databaseinvarianter

## 73. Invariants

Følgende skal behandles som arkitekturkrav:

1. **Kanoniske kunnskapstabeller eksponeres ikke direkte til nettleseren.**
2. **Publiserte revisjoner overskrives aldri.**
3. **Klinisk viktig historikk slettes ikke ved normalt redaksjonelt arbeid.**
4. **Publisering er eksplisitt, validert og transaksjonell.**
5. **Alle publiserte claims kan spores til evidens og faglige beslutninger.**
6. **Motstridende evidens bevares.**
7. **Deterministiske fakta har kilde og tidsvaliditet.**
8. **Eksterne importer går gjennom staging/normalisering.**
9. **Agent- og brukerrettigheter følger least privilege.**
10. **RLS og grants er eksplisitte; tilgang er default deny.**
11. **Avledede views, cache, søkeindeks og embeddings er regenererbare.**
12. **Ingen pasientdatabase bygges inn i kunnskapsmodellen ved et uhell.**
13. **Databaseconstraints håndhever integritet som ikke trygt bør overlates til klientkode.**
14. **Alle sikkerhetskritiske databasefunksjoner og views behandles som kode som må reviewes og testes.**

---

# Del XXIV — Neste steg

## 74. Hva dette dokumentet muliggjør

Når denne arkitekturen er akseptert, bør neste arbeid deles i to parallelle spesifikasjoner før full appimplementasjon:

1. **`CONTENT_GOVERNANCE.md`**  
   Definer hvem som kan opprette, verifisere, godkjenne, publisere, overstyre og trekke tilbake innhold; review-frister; konflikthåndtering; feilrapportering og faglig ansvar.

2. **`PRODUCT_INFORMATION_ARCHITECTURE.md`**  
   Definer hvordan den samme strukturerte kunnskapen skal presenteres for klinikeren: navigasjon, monografi, sammenligning, klinisk problemstilling, progressive disclosure og «hvorfor sier Antidep dette?»-visningen.

Etter disse dokumentene kan Antidep gå over fra hovedsakelig arkitekturarbeid til konkret schema-migrasjon og MVP-implementasjon uten at databasen eller UI-et må finne opp kunnskapsreglene underveis.

---

## 75. Plattformforutsetninger kontrollert ved denne versjonen

Denne spesifikasjonen er skrevet med Supabase/PostgreSQL-forutsetninger kontrollert 18. august 2026.

Særlig relevante plattformforhold:

- Supabase krever RLS på tabeller i eksponerte schema for sikker direkte klienttilgang.
- Data API-tilgang og RLS er separate lag; eksplisitte grants skal brukes og Antidep skal ikke stole på automatisk tabell-eksponering.
- Custom schemas kan holdes utenfor Data API og brukes som private databaseområder.
- Views kan ellers få privilegiesemantikk som omgår forventet RLS; `security_invoker` skal brukes der RLS skal gjelde gjennom viewet.
- Databasefunksjoner er `SECURITY INVOKER` som normalvalg; `SECURITY DEFINER` krever særskilt sikring, begrensede grants og kontrollert `search_path`.
- PostgreSQL støtter deklarative `CHECK`, `UNIQUE`, `FOREIGN KEY` og exclusion constraints; tverrradskrav som ikke kan uttrykkes korrekt med disse skal ikke simuleres med ugyldige cross-row `CHECK`-uttrykk.

Før faktisk implementasjon skal Supabase changelog og relevante dokumentasjonssider kontrolleres på nytt fordi plattformadferd kan endres.

### Primærkilder

- [Supabase: Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase: Securing your API](https://supabase.com/docs/guides/api/securing-your-api)
- [Supabase: Using Custom Schemas](https://supabase.com/docs/guides/api/using-custom-schemas)
- [Supabase: Database Functions](https://supabase.com/docs/guides/database/functions)
- [Supabase: Tables and Data](https://supabase.com/docs/guides/database/tables)
- [Supabase changelog: Tables not exposed to Data and GraphQL API automatically](https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically)
- [PostgreSQL: Constraints](https://www.postgresql.org/docs/current/ddl-constraints.html)
- [PostgreSQL: Row Security Policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
