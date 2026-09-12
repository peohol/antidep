# Antidep MVP Implementation Plan

**Versjon:** 0.1  
**Dato:** 18. august 2026  
**Status:** Første implementeringsplan  
**Styrende dokumenter:** [`ANTIDEP_CONSTITUTION.md`](./ANTIDEP_CONSTITUTION.md), [`KNOWLEDGE_MODEL.md`](./KNOWLEDGE_MODEL.md), [`EVIDENCE_PIPELINE.md`](./EVIDENCE_PIPELINE.md), [`DATABASE_ARCHITECTURE.md`](./DATABASE_ARCHITECTURE.md), [`CONTENT_GOVERNANCE.md`](./CONTENT_GOVERNANCE.md) og [`PRODUCT_INFORMATION_ARCHITECTURE.md`](./PRODUCT_INFORMATION_ARCHITECTURE.md)

## 1. Formål

Dette dokumentet markerer overgangen fra arkitektur til faktisk bygging av Antidep.

Målet er å få frem en liten, produksjonslignende MVP som demonstrerer at hele kjeden fungerer:

```text
kilde
→ strukturert evidens
→ verifisering
→ claim
→ evidensvurdering
→ human review
→ publisering
→ kliniker-UI
→ kildedrilldown
```

Planen skal styre rekkefølgen på implementasjonen og hindre to vanlige feil:

1. at prosjektet bygger stor teknisk infrastruktur før noen komplett klinisk arbeidsflyt fungerer
2. at prosjektet fyller databasen med store mengder innhold før evidens-, review- og publiseringsmekanismene er validert

Implementasjonen skal derfor skje i små, reviewbare **vertikale slices**.

---

## 2. Normative begreper

- **SKAL**: krav som må oppfylles før MVP kan anses arkitekturmessig korrekt.
- **BØR**: sterk standard som kan fravikes med dokumentert grunn.
- **KAN**: tillatt, men ikke påkrevd.

---

# Del I — Hva MVP-en skal bevise

## 3. MVP er en arkitekturvalidering, ikke et komplett antidepressivleksikon

MVP-en skal bevise at Antidep kan:

- representere antidepressiver og norske produkter strukturert
- lagre en kilde og konkrete evidensfunn separat
- formulere atomiske, versjonerte claims
- koble evidens til claims med eksplisitt relasjonstype
- representere usikkerhet og evidenssikkerhet
- verifisere ekstraksjon og claim-støtte uavhengig
- håndtere human review
- publisere og erstatte revisjoner uten å miste historikk
- vise den samme kunnskapen i legemiddel-, sammenlignings- og temavisning
- vise «Hvorfor sier Antidep dette?» ned til konkret evidens og kilde
- håndtere `ingen vurderbar evidens` uten at dette ser ut som null risiko eller null effekt
- gjennomføre en kontrollert, deterministisk klinisk regel for et begrenset bytte-/nedtrappingsscenario
- fungere på desktop og mobil
- kunne administreres uten direkte databasearbeid i normal redaksjonell drift

MVP-en skal **ikke** bevise at Antidep allerede dekker hele antidepressivfeltet.

## 4. Primært suksesskriterium

Den viktigste testen er ikke antall virkestoffer eller antall sider.

MVP-en er vellykket når en kliniker kan gå fra et konkret spørsmål til et korrekt, kort svar og derfra ned til den strukturerte evidensen, samtidig som en redaktør kan oppdatere samme kunnskapsobjekt gjennom en kontrollert review- og publiseringsflyt.

---

# Del II — Teknisk baseline

## 5. Anbefalt applikasjonsstack

Første implementasjon BØR bruke en enkel TypeScript-basert webstack:

```text
Frontend
  React
  TypeScript
  Vite

Backend / data
  Supabase
  PostgreSQL
  Supabase Auth
  kontrollerte server-/RPC-operasjoner

Hosting
  Vercel

Testing
  Vitest
  React Testing Library
  Playwright
  database-/RLS-tester
```

Begrunnelse:

- produktet er primært en interaktiv klinikerapp, ikke et innholdstungt SEO-nettsted
- Vite holder klientlaget enkelt
- React/TypeScript passer godt til strukturerte komponenter, admin-UI og sammenligningstabeller
- PostgreSQL/Supabase er allerede valgt som kanonisk dataplattform i arkitekturen
- Vercel gir enkel distribusjon og preview deployments

Hvis implementasjonen avdekker et konkret behov som klart favoriserer en annen frontendarkitektur, kan dette valget revurderes. Det skal ikke byttes rammeverk av smakshensyn.

## 6. Anbefalt repo-struktur

Start enkelt:

```text
/
├─ docs/
├─ src/
│  ├─ app/
│  ├─ components/
│  ├─ features/
│  ├─ lib/
│  ├─ routes/
│  └─ types/
├─ supabase/
│  ├─ migrations/
│  ├─ seed.sql
│  └─ tests/
├─ tests/
│  └─ e2e/
├─ package.json
└─ ...
```

Ikke innfør monorepo, mange packages eller egen mikroservicearkitektur før et konkret behov eksisterer.

## 7. Avhengigheter skal holdes nøkterne

MVP-en bør bruke få, velbegrunnede biblioteker.

Aktuelle kategorier:

- routing
- server-state/data fetching
- skjema-/inputvalidering
- tilgjengelige UI-primitiver
- testing

Ikke innfør en tung design system-stack, generisk workflow-motor eller egen abstraksjonsramme for KI før behovet er demonstrert.

## 8. Supabase-forutsetninger skal verifiseres før første migrasjon

Før schemaimplementasjon starter skal teamet kontrollere gjeldende:

- Supabase changelog
- Data API-eksponering og grants
- RLS-veiledning
- custom schemas
- view-sikkerhet
- databasefunksjoner
- CLI-versjon og migrasjonsworkflow

`DATABASE_ARCHITECTURE.md` er styrende, men plattformdetaljer kan ha endret seg siden dokumentet ble skrevet.

---

# Del III — MVP-scope

## 9. Pilotsett av antidepressiver

MVP-en skal ikke starte med alle antidepressiver.

Følgende seks virkestoffer anbefales som pilotsett:

| Virkestoff | Hvorfor det inngår i pilotsettet |
|---|---|
| **sertralin** | vanlig SSRI og egnet baseline for mange sammenligninger |
| **escitalopram** | vanlig SSRI med relevant dose-/QT- og interaksjonskontekst |
| **fluoksetin** | svært lang halveringstid; viktig test av bytte-/nedtrappingslogikk |
| **venlafaksin** | SNRI og nyttig test av seponeringsproblemer og formuleringer |
| **mirtazapin** | annen farmakologisk profil; tydelig relevant for vekt og sedasjon |
| **vortioksetin** | multimodal profil og nyttig kontrast for blant annet seksuell funksjon |

Dette er et **arkitekturpilotsett**, ikke en påstand om at disse seks alltid er de viktigste antidepressivene klinisk.

## 10. Første utvidelsessett

Følgende kan vurderes etter at pilotsettet fungerer:

- duloksetin
- paroksetin
- citalopram
- amitriptylin
- klomipramin
- bupropion der norsk indikasjon/off-label-kontekst er tydelig modellert

Utvidelse skal ikke skje før pipeline- og reviewkvalitet er demonstrert.

## 11. Pilottemaer / ClinicalConcepts

MVP-en skal prioritere følgende innholdsområder:

1. **effekt ved depressiv lidelse**
2. **vektendring**
3. **seksuell dysfunksjon**
4. **sedasjon / søvn**
5. **seponeringssymptomer / seponeringsproblemer**
6. **sentral farmakokinetikk**, inkludert halveringstid og aktive metabolitter når relevant
7. **viktige farmakokinetiske interaksjoner**
8. **utvalgte sikkerhetsområder**, først og fremst områder som er egnet til reell sammenligning mellom pilotlegemidlene
9. **norske preparater, formuleringer og styrker**

MVP-en trenger ikke komplett dekning av alle underområder for alle seks legemidler før første interne pilot.

## 12. Første «golden slice»

Den aller første komplette vertikale slicen skal være:

```text
sertralin + mirtazapin
×
vektendring
```

Denne slicen skal inneholde:

- to `Drug`-objekter
- relevante `ClinicalConcept`/Population-objekter
- minst én reell Source
- minst ett verifisert EvidenceItem per relevant kilde
- atomiske Claims
- ClaimEvidenceLinks
- EvidenceAssessment
- human ReviewDecision
- PublicationEvent
- offentlig API-projeksjon
- legemiddelvisning
- enkel sammenligning
- «Hvorfor sier Antidep dette?»

Før denne kjeden fungerer skal prosjektet ikke masseimplementere andre temaer.

---

# Del IV — Funksjonelt MVP-omfang

## 13. Klinikerflate

Før første offentlige MVP skal følgende hovedflyter fungere.

### 13.1 Søk og legemiddeloppslag

Brukeren skal kunne:

```text
åpne Antidep
→ søke på virkestoff eller norsk handelsnavn
→ åpne legemiddelside
→ se kort standardinformasjon
→ åpne et faglig tema
→ åpne claim/evidens
```

### 13.2 Sammenligning

Brukeren skal kunne:

```text
velge 2–4 pilotlegemidler
→ velge relevante dimensjoner
→ se sammenligning
→ velge «vis bare forskjeller»
→ åpne evidensgrunnlaget for et datapunkt
```

### 13.3 Klinisk situasjon

Minst følgende temainnganger bør fungere:

- vektøkning
- seksuell dysfunksjon
- sedasjon/søvn
- seponeringsproblemer

Temavisningen skal være en projeksjon av de samme Claims som brukes på legemiddelsiden.

### 13.4 Evidensdrilldown

For ethvert publisert klinisk relevant claim skal brukeren kunne åpne:

```text
Hva sier Antidep?
→ hvor sikker er kunnskapen?
→ hvilke studier/kilder ligger bak?
→ hvordan støtter eller motsier kilden claimet?
→ hvor i kilden finnes evidensfunnet?
```

### 13.5 Bytte/nedtrapping

MVP-en skal inneholde en **begrenset, eksplisitt støttet** bytte-/nedtrappingsmotor.

Den skal ikke late som alle legemiddelpar er støttet.

Første versjon bør:

- bare aktivere planer for eksplisitt faglig godkjente overganger
- bruke faktiske norske formuleringer/styrker
- vise hvilken regelversjon som ble brukt
- vise sentrale forutsetninger
- tillate at klinikeren velger blant definerte tempoalternativer der dette er faglig forsvarlig
- vise tydelig når en overgang ikke er støttet i Antidep ennå

Første implementerte regel bør velges fordi den tester arkitekturen godt, ikke fordi flest mulige scenarioer skal dekkes.

---

# Del V — Admin- og review-MVP

## 14. Admin er en del av MVP, ikke et senere internt verktøy

MVP-en er ikke ferdig hvis innhold bare kan opprettes ved SQL, seed-filer eller Claude Code.

Følgende redaksjonelle handlinger skal kunne utføres i UI før offentlig lansering:

- opprette Source
- opprette eller korrigere EvidenceItem
- opprette Claim / ny ClaimRevision
- koble EvidenceItem til ClaimRevision
- angi relasjonstype
- registrere EvidenceAssessment
- sende til review
- godkjenne eller avvise
- forhåndsvise publisert utseende
- publisere
- erstatte en publisert revisjon
- trekke tilbake publisert revisjon
- se historikk

## 15. Første admin-workflow

Første komplette admin-workflow skal være:

```text
Editor oppretter Source
→ Editor registrerer EvidenceItem
→ separat verifier verifiserer ekstraksjonen
→ Editor oppretter ClaimRevision
→ Claim–Evidence-relasjon registreres
→ claim-støtte verifiseres
→ EvidenceAssessment registreres
→ Clinical Reviewer godkjenner
→ Publisher publiserer
→ kliniker-UI oppdateres
```

Systemet skal vise hvorfor et steg er blokkert dersom en gate mangler.

## 16. Roller i første tekniske implementasjon

Følgende applikasjonsroller implementeres først:

- `editor`
- `reviewer`
- `publisher`
- `admin`

`clinical_lead` og `evidence_lead` kan initialt være governance-attributter/ansvarsroller uten egne tekniske tillatelser dersom ingen særskilt handling krever det ennå.

Agentbrukere skal ikke representeres som vanlige menneskelige editor-brukere.

`agent_worker` er derfor ikke en verdi i `workflow.app_role`, men et eget register:
`provenance.agent_identities`. Hver agentidentitet er knyttet til én agentaktør, arver
aktørens agentrolle som rettighetsgrense, og autentiserer seg med sin egen legitimasjon
framfor med en brukerkonto eller med `service_role`. Flere agentledd betyr flere aktører og
flere identiteter, ikke flere rettigheter på én identitet (§74.31).

---

# Del VI — Databaseimplementasjon i rekkefølge

## 17. Migrasjonsstrategi

Databasen skal bygges i små migrasjoner som følger de vertikale slicene.

Ikke opprett alle tabeller fra `DATABASE_ARCHITECTURE.md` i én gigantisk initial migration.

## 18. Migrasjon 001 — schema- og sikkerhetsfundament

Opprett:

```text
catalog
knowledge
workflow
provenance
audit
api
```

Etabler:

- nødvendige extensions
- eksplisitte grants/revokes
- grunnleggende rolle-/sikkerhetsmodell
- conventions for UUID/timestamps
- migrasjonstest som bekrefter at kanoniske schema ikke er offentlig lesbare

Ingen klinisk data ennå.

## 19. Migrasjon 002 — katalogfundament

Opprett minimum:

```text
catalog.drugs
catalog.drug_names
catalog.clinical_concepts
catalog.populations
```

Seed kun data som trengs for første golden slice.

## 20. Migrasjon 003 — Source og EvidenceItem

Opprett minimum:

```text
knowledge.sources
knowledge.source_identifiers
knowledge.source_versions
knowledge.evidence_items
```

Implementer:

- identitetsconstraints
- kildestatus
- source locator
- eksplisitte null/ukjent-tilstander der nødvendig
- immutabilitetsstrategi for EvidenceItem

## 21. Migrasjon 004 — Claims

Opprett:

```text
knowledge.claims
knowledge.claim_revisions
knowledge.claim_evidence_links
knowledge.evidence_assessments
```

Implementer:

- immutable revisjoner
- unik revisjonsnummerering per claim
- relationship-type constraints
- knowledge type
- certainty/no-evidence-semantikk

## 22. Migrasjon 005 — review og proveniens

Opprett minimum:

```text
provenance.actors
workflow.evidence_verifications
workflow.claim_verifications
workflow.review_decisions
workflow.user_roles
```

Agent-run-tabeller kan implementeres samtidig dersom første evidenspipeline bruker agentkjøringer allerede i denne slicen.

## 23. Migrasjon 006 — publisering

Opprett:

```text
knowledge.publication_events
```

Implementer kontrollert publiseringsoperasjon.

Publisering skal:

- være transaksjonell
- kontrollere nødvendige gates
- oppdatere current published revision atomisk
- opprette PublicationEvent
- avvise ugyldig publisering med forståelig feil

## 24. Migrasjon 007 — API-lesemodell

Opprett første views:

```text
api.published_drugs
api.published_claims
api.published_claim_evidence
```

Kun publiserte revisjoner skal vises.

Test eksplisitt med faktisk klientrolle.

## 25. Migrasjon 008 — audit

Opprett:

```text
audit.events
```

Audit bør komme tidlig nok til at resten av admin-MVP-en bygges med sporbarhet fra starten.

## 26. Migrasjon 009 — DrugProduct/importfundament

Når golden slice er stabil, opprett:

```text
catalog.drug_products
```

og nødvendig ingest/staging for første autoritative norske produktdatasett.

Ikke start automatisert produktimport før:

- ekstern identitet er bestemt
- idempotens er testet
- endringsdeteksjon er definert
- tidsvaliditet er modellert

## 27. Migrasjon 010+ — kun når neste slice trenger det

Eksempler:

- studies/study_sources
- evidence work units
- search history
- screening decisions
- clinical rules
- interactions

Ikke opprett dem kun fordi de finnes i fremtidsarkitekturen.

---

# Del VII — Vertikale implementasjonsslices

## 28. Slice 0 — prosjektbootstrap

### Leveranser

- React/TypeScript/Vite-app
- lint/format/typecheck
- testgrunnlag
- miljøvariabelstruktur
- Supabase lokal/dev-oppsett
- Vercel preview deployment
- enkel CI
- grunnleggende app shell

### Definition of done

- clean checkout kan installeres og kjøres etter dokumenterte kommandoer
- typecheck og tester kjører i CI
- preview deployment fungerer
- ingen secrets i klient/repo

## 29. Slice 1 — golden evidence slice

### Klinisk scope

```text
sertralin vs mirtazapin
vektendring
```

### Leveranser

- migrasjon 001–006
- Source
- EvidenceItem
- Claim/ClaimRevision
- EvidenceAssessment
- verifikasjon
- review
- publisering
- manuell adminflyt

### Definition of done

En kvalifisert reviewer kan gjennom admin-UI publisere ett reelt claim, og systemet kan rekonstruere hele provenienskjeden.

## 30. Slice 2 — første kliniker-UI

### Leveranser

- `/drugs/sertralin`
- `/drugs/mirtazapin`
- enkel temaside for vekt
- claim-komponent
- uncertainty/certainty-visning
- `Hvorfor sier Antidep dette?`
- kildedetalj

### Definition of done

En kliniker kan finne claimet og forstå:

- hva Antidep hevder
- hva det gjelder
- hvor sikker kunnskapen er
- hva evidensen er
- hvilken kilde som støtter eller motsier det

uten admin-tilgang.

## 31. Slice 3 — sammenligning

### Leveranser

- valg av legemidler
- valg av dimensjoner
- sammenligningsvisning
- responsiv mobilrepresentasjon
- `vis bare forskjeller`
- drilldown fra hvert datapunkt

### Definition of done

Sertralin og mirtazapin kan sammenlignes uten duplisert innhold eller separat sammenligningstekst i databasen.

## 32. Slice 4 — norsk produktdata

### Leveranser

- DrugProduct-modell
- staging/importmekanisme
- pilotimport for de seks virkestoffene
- handelsnavn
- formuleringer
- styrker
- tidsvaliditet
- idempotent rerun

### Definition of done

Brukeren kan svare korrekt på «hvilke styrker finnes i Norge?» og importen kan kjøres på nytt uten semantiske duplikater.

## 33. Slice 5 — utvid evidenspipelinen

### Leveranser

Utvid golden slice til:

```text
6 pilotlegemidler
×
vekt
seksuell dysfunksjon
sedasjon/søvn
seponering
```

Ikke nødvendigvis alle 24 kombinasjoner umiddelbart; arbeid i batches som kan reviewes.

### Pipelinekrav

- source discovery
- source assessment
- extraction
- separat verification
- claim drafting
- contradictory-evidence check
- evidence assessment
- claim support verification
- human review

### Definition of done

Det finnes målt feilrate for agentassistert ekstraksjon og claim-verifikasjon på pilotsettet.

## 34. Slice 6 — kliniske temasider og globalt søk

### Leveranser

- temavisninger
- søk på virkestoff
- handelsnavn
- klinisk konsept
- relevante claims
- dypelenker

### Definition of done

Den samme ClaimRevision vises konsistent på legemiddelside, temaside, søk og sammenligning.

## 35. Slice 7 — bytte/nedtrapping, første regel

### Scope

Velg én eller noen få klinisk veldefinerte overganger som tester:

- lang vs kort halveringstid
- tilgjengelige norske styrker
- doseendringer
- eksplisitte forutsetninger

### Leveranser

- `ClinicalRule`-objekt eller tilsvarende versjonert regelartefakt
- deterministisk beregningsmotor
- rule version
- klinisk rationale/evidenskobling
- enhetstester
- edge-case-tester
- human clinical approval
- UI med tydelig supported/unsupported-status

### Definition of done

Samme input + samme regelversjon gir deterministisk samme plan, og brukeren kan se hvilken regel og hvilke forutsetninger som ligger bak.

## 36. Slice 8 — full pilot og hardening

### Leveranser

- alle seks pilotlegemidler
- de avtalte MVP-temaene med akseptabel dekning
- mobilgjennomgang
- keyboard/accessibility-gjennomgang
- feilrapportering
- re-review-flagg
- source correction/retraction-propagation
- observability/logging
- sikkerhetstesting
- usability-test med klinikere

### Definition of done

MVP-en oppfyller lanseringskriteriene i dette dokumentet.

---

# Del VIII — Evidenspipeline i første implementasjon

## 37. Automatiser sent, men ikke for sent

Første golden slice kan opprettes delvis manuelt for å validere datamodellen.

Agentpipeline skal deretter implementeres på samme objekter.

Unngå to ekstremer:

- full agentautomatisering før objektmodellen er testet
- langvarig manuell innholdsproduksjon som om agentpipeline ikke er et kjernekrav

## 38. Første agentroller

Implementer i denne rekkefølgen:

1. **Extraction agent**
2. **Extraction verifier**
3. **Claim drafter**
4. **Claim support verifier**
5. **Contradiction/adversarial checker**
6. **Source discovery/assessment**

Grunnen til at discovery ikke nødvendigvis kommer først teknisk, er at ekstraksjon/verifikasjon kan testes på et lite manuelt kuratert kildesett før man bygger robust søkeorkestrering.

Hver av dem er en egen aktør med sin egen tekniske identitet og sin egen rolle, ikke en
konfigurasjon av den samme identiteten. Rollen er rettighetsgrensen: en identitet slipper bare
gjennom autentiseringen for den rollen operasjonen krever, så et agentledd kan ikke utføre et
annet agentledds operasjon selv med gyldig legitimasjon. Et andre uavhengig kontrollag i samme
rolle er en ny aktør med sin egen identitet og sin egen kjøring, og begge kontrollene består
ved siden av hverandre.

## 39. Agent-output skal være strukturert

Agentene skal produsere validerbare objekter, ikke fritekst som direkte lagres som publisert kunnskap.

Eksempel:

```text
Extraction agent
→ EvidenceItem candidate
→ schema validation
→ verification queue
```

## 40. Mål kvalitet før skalering

På pilotsettet skal minst følgende måles:

- numerisk ekstraksjonsfeil
- feil populasjon
- feil komparator
- feil tidsramme
- locator-feil
- claim som overdriver evidensen
- manglende sentrale forbehold
- feil support/contradict-relasjon
- oversett motstridende evidens

Ingen bestemt prosentgrense fastsettes i plan v0.1; terskler skal bestemmes etter at en representativ evalueringssample finnes.

---

# Del IX — Teststrategi

## 41. Testpyramide

MVP-en skal ha flere testnivåer.

### Database

Test:

- constraints
- foreign keys
- immutabilitet
- grants
- RLS
- publiseringsgates
- rollback
- audit
- idempotent import

### Domene-/regeltester

Test:

- mapping av knowledge types
- certainty/no-evidence states
- sammenligningslogikk
- ClinicalRule
- dose-/styrkeberegning

### Komponenttester

Test:

- claim card
- uncertainty-visning
- evidence drilldown
- sammenligningsceller
- forms/admin validation

### End-to-end

Test representative kliniske oppgaver.

## 42. Kritiske negative tester

MVP-en skal eksplisitt teste at systemet **nekter**:

- publisering uten evidens når evidens kreves
- publisering uten human review når dette kreves
- review av en revisjon som senere er endret uten nytt review
- redigering av publisert immutable revisjon
- vanlig brukerlesing av private knowledge/workflow-tabeller
- adminhandling uten riktig rolle
- klinisk plan for unsupported transition
- visning av `no evidence` som null

## 43. Accessibility-test

Automatisert testing er ikke tilstrekkelig.

Før lansering skal sentrale flyter testes manuelt med:

- keyboard
- synlig fokus
- zoom
- smal mobilviewport
- screen-reader-semantikk på sentrale komponenter
- informasjon uten farge

---

# Del X — UX- og klinisk validering

## 44. Første usability-runde

Bruk 3–5 klinikere tidlig, før full pilotdekning.

Oppgaver:

- finn tilgjengelige norske styrker
- finn et konkret claim
- identifiser evidenssikkerheten
- finn kilden
- sammenlign sertralin og mirtazapin på vekt
- identifiser at manglende evidens ikke betyr lav risiko

## 45. Andre usability-runde

Etter Slice 7:

- sammenlign 3–4 antidepressiver
- bruk temaside
- gjennomfør støttet bytte-/nedtrappingsscenario
- identifiser unsupported scenario
- finn rationale og regelversjon

## 46. Mål

Følg minst:

- tid til korrekt svar
- feilrate
- misforstått usikkerhet
- kildefunnrate
- navigasjonsfriksjon
- mobilgjennomførbarhet
- feilaktig inferert behandlingsrangering

---

# Del XI — Sikkerhet og tilgang

## 47. Offentlig lesing

Offentlig klinikerflate skal kun lese eksplisitt publiserte API-projeksjoner.

Den skal ikke få direkte `SELECT` mot:

- `knowledge`
- `workflow`
- `provenance`
- `audit`
- `ingest`

## 48. Admin-skriving

Admin-klienten skal ikke få generell tabellskriveadgang til kanoniske data.

Sentrale operasjoner skal gå gjennom kontrollerte server-/RPC-grenser som kan:

- validere rolle
- validere objektstatus
- håndheve preconditions
- opprette audit
- utføre transaksjoner

## 49. Least privilege for agenter

En ekstraksjonsagent skal ikke kunne publisere.

En source discovery-agent skal ikke kunne endre Claims.

En verifier skal kunne skrive verifikasjonsresultat, ikke overskrive inputobjektet som verifiseres.

Grensene skal være håndhevet i databasen og ikke være en promptkonvensjon. Tre uavhengige lag
bærer dem:

1. **Rollen.** En agentidentitet har nøyaktig én agentrolle, og autentiseringen krever den
   rollen operasjonen faktisk trenger. En identitet i ekstraksjonsrollen avvises for en
   verifikasjonsoperasjon før den rører et kunnskapsobjekt.
2. **Aktøren.** `workflow.evidence_verifications` og `workflow.claim_verifications` avviser en
   rad der kontrolløren er samme aktør som den som laget objektet, uansett hvordan raden kom
   dit.
3. **Kjøringen.** `provenance.agent_runs` bærer aktør og rolle som speilkolonner låst til
   identiteten, og eksponerer dem som unike nøkler, slik at en skrivevei kan kreve
   deklarativt at et objekt ble produsert av den kjøringen det attribueres til.

En agentidentitet kan bare registreres, få legitimasjon eller trekkes tilbake av en
menneskelig aktør. En agent som kunne registrere agenter, ville vært en rettighetseskalering
med ett ekstra ledd.

## 50. Ingen pasientdata i MVP

MVP-en skal ikke lagre:

- navn
- fødselsnummer
- journaltekst
- pasientprofiler
- fritekstkasus med identifiserbare opplysninger

Bytte-/nedtrappingsverktøy skal operere på de nødvendige legemiddel- og doseparameterne uten permanent pasientprofil.

---

# Del XII — CI/CD og arbeidsform

## 51. Små PR-er

Etter implementeringsplanen skal arbeidet deles i små PR-er.

Et typisk godt implementerings-PR skal gjøre én ting, for eksempel:

- bootstrap frontend
- opprett schema skeleton
- implementer Source/EvidenceItem
- implementer ClaimRevision
- implementer publication RPC
- bygg ClaimCard
- bygg evidence drawer

Unngå PR-er som samtidig endrer schema, evidenspipeline, admin-UI og kliniker-UI i stor skala.

## 52. Hver PR skal ha eksplisitt validation

Relevant kombinasjon av:

```text
lint
typecheck
unit tests
database tests
RLS tests
e2e tests
build
```

Dokumentasjons-PR-er trenger ikke kjøre unødvendige app-tester dersom ingen appkode påvirkes.

## 53. Preview deployments

UI-PR-er bør få Vercel preview deployment slik at klinisk og visuell review kan gjøres uten lokal utviklingsmiljø.

## 54. Databaseendringer

Schemaendringer skal alltid ligge som versjonerte migrasjoner i repoet.

Produksjonsschema skal ikke utvikles ved manuelle Dashboard-endringer som ikke finnes i Git-historikken.

---

# Del XIII — Hva som eksplisitt ikke skal bygges nå

## 55. Ikke-MVP

Følgende utsettes:

- komplett dekning av alle antidepressiver
- full individuell behandlingsanbefalingsmotor
- automatisk «beste antidepressiv for denne pasienten»
- pasientprofiler
- journalintegrasjon
- TDM-modul
- full farmakogenetikkmodul
- avansert interaksjonsontologi
- institusjonelle overlays
- embeddings/semantisk søk med mindre vanlig søk viser seg utilstrekkelig
- native mobilapp
- offline-first-synkronisering
- flerspråklig UI
- generisk workflow builder
- generisk regel-DSL
- automatisert masspublisering uten human review

## 56. Beslutningsstøtte avgrenses bevisst

Temasider og sammenligning skal ikke automatisk rangere legemidler som «best».

Individuell, algoritmisk behandlingsanbefaling er en senere produktfase med separat regulatorisk og klinisk validering.

---

# Del XIV — Milepæler

## 57. Milepæl A — teknisk fundament

Oppnådd når:

- app kjører
- CI kjører
- Supabase-devmiljø fungerer
- sikkerhetsgrensene er etablert
- første migrasjoner er i repoet

## 58. Milepæl B — første publiserte Claim

Oppnådd når:

- Source → EvidenceItem → Claim → review → publish fungerer
- publisering skjer gjennom kontrollert operasjon
- historikk/proveniens er intakt

Dette er den første store arkitekturmilepælen.

## 59. Milepæl C — første kliniske end-to-end-opplevelse

Oppnådd når klinikeren kan:

```text
søke
→ åpne legemiddel
→ lese claim
→ sammenligne
→ åpne evidens
```

for golden slice.

## 60. Milepæl D — redaksjonell selvbetjening

Oppnådd når vanlig innholdsarbeid for pilotobjektene ikke krever SQL eller vibekoding.

## 61. Milepæl E — pilotkunnskapsbase

Oppnådd når seks pilotlegemidler har reviewet dekning av de prioriterte temaene i den graden som er definert for intern pilot.

## 62. Milepæl F — begrenset klinisk verktøy

Oppnådd når minst én bytte-/nedtrappingsregel er versjonert, testet, faglig godkjent og brukt gjennom UI.

## 63. Milepæl G — offentlig MVP-kandidat

Oppnådd når lanseringskriteriene under er oppfylt.

---

# Del XV — Lanseringskriterier

## 64. Faglig

Før offentlig MVP:

- alle publiserte evidenssynteser har nødvendig human review
- alle publiserte claims har sporbar evidens eller eksplisitt relevant deterministisk kilde
- relevante motstridende funn er representert
- `no evidence` brukes korrekt
- alle aktive ClinicalRules er eksplisitt godkjent
- review-overdue høyrisikoinnhold er ikke publisert som om det var aktuelt

## 65. Teknisk

- ingen kjente kritiske RLS-/grant-feil
- ingen secrets i klienten
- publisering og rollback er testet
- migrasjoner kan kjøres reproduserbart
- backup/recovery-forutsetninger er dokumentert
- logging er tilstrekkelig for feilsporing uten pasientdata
- kritiske E2E-tester er grønne

## 66. UX

- sentrale kliniske oppgaver er gjennomført med klinikere
- brukerne kan finne evidensgrunnlag
- ukjent/usikkert misforstås ikke systematisk som trygt
- mobilflytene er brukbare
- keyboard-flyt fungerer
- farge er ikke eneste informasjonsbærer

## 67. Governance

- aktive roller er definert
- Publisher-funksjon finnes
- Clinical Reviewer finnes
- ansvar for evidensmetodikk er definert
- feilrapportering har eier
- sikkerhetskritisk avpublisering kan gjennomføres raskt

---

# Del XVI — Første konkrete PR-rekke etter denne planen

## 68. Anbefalt PR-sekvens

Etter at denne planen er merget, anbefales følgende implementeringsrekkefølge:

```text
PR A  chore: bootstrap Antidep web app
PR B  db: add schema and security foundation
PR C  db: add drug and clinical concept catalog
PR D  db: add sources and evidence items
PR E  db: add claims and evidence assessments
PR F  db: add review and publication workflow
PR G  feat: add admin golden-slice workflow
PR H  feat: add published claim API views
PR I  feat: add first drug and evidence UI
PR J  feat: add comparison golden slice
PR K  db: add Norwegian product model and ingest
PR L+ expand pilot evidence pipeline and content
```

Hver PR skal vurderes mot de styrende dokumentene, ikke bare mot om koden «virker».

Rekkefølgen over er den opprinnelig planlagte. Den faktiske rekkefølgen har avveket
fra og med PR F: databasearbeidet er gjennomført med **én migrasjon per PR**, slik at
hver migrasjon kan reviewes for seg. Etikettene PR F og PR G over svarer derfor ikke
til det som faktisk ble bygget. Se §74 for den faktiske rekkefølgen.

## 69. Første implementeringsoppgave

Den aller neste arbeidsoppgaven etter at denne planen er godkjent skal være:

> **Bootstrap en minimal React + TypeScript + Vite-applikasjon med test-, CI- og Supabase-utviklingsfundament, uten å implementere klinisk funksjonalitet ennå.**

Denne oppgaven skal samtidig etablere en kort `CLAUDE.md` eller tilsvarende agentinstruks som peker til de styrende dokumentene i `docs/`, uten å kopiere dem inn og dermed blåse opp konteksten.

---

# Del XVII — Hvordan planen skal vedlikeholdes

## 70. Planen er operativ

`MVP_IMPLEMENTATION_PLAN.md` skal brukes som prosjektets fremdriftskart frem til MVP.

Når en slice er ferdig, skal status oppdateres eksplisitt.

Anbefalt statusmarkering:

```text
[ ] not started
[~] in progress
[x] done
[!] blocked / needs decision
```

## 71. Ikke skriv historien om igjen

Hvis implementasjonen krever avvik fra planen:

- dokumenter beslutningen
- oppdater relevant del
- behold Git-historikken
- endre overordnet arkitektur bare dersom erfaring faktisk viser at den bør endres

Små tekniske avvik krever ikke at konstitusjonen eller kunnskapsmodellen omskrives.

## 72. Arkitekturgjeld skal være eksplisitt

Hvis en MVP-forenkling bryter en ønsket langsiktig egenskap uten å bryte en invariant, skal den registreres som eksplisitt arkitekturgjeld med:

- hva som er forenklet
- hvorfor
- risiko
- trigger for når det må ryddes opp

---

# Del XVIII — MVP-statusoversikt

## 73. Initial status ved versjon 0.1

Listen under er statusen slik den var da planen ble skrevet, og beholdes som
historikk (§71). **Gjeldende status står i §74.**

```text
[x] Product/evidence constitution
[x] Knowledge model
[x] Evidence pipeline specification
[x] Database architecture
[x] Content governance
[x] Product information architecture
[x] MVP implementation plan drafted

[~] Web application bootstrap
[x] Supabase schema/security foundation
[~] Golden evidence slice
[ ] First admin workflow
[ ] First published Claim
[ ] First clinician UI
[ ] Comparison golden slice
[ ] Norwegian product ingest
[ ] Pilot evidence pipeline
[ ] Clinical situation views
[ ] First ClinicalRule
[ ] Usability validation
[ ] Security/accessibility hardening
[ ] Public MVP candidate
```

---

## 74. Status etter kildevisningen

**Oppdatert:** 4. september 2026 (etter at det første reelle evidensfunnet ble registrert
gjennom produksjons-UI-et — se §74.29, og planen for neste ledd i §74.30; forrige oppdatering
etter at skriveveien for å registrere et EvidenceItem ble merget og kjørt mot det hostede
prosjektet, §74.28)

### 74.1 Gjeldende statusmarkering

```text
[x] Product/evidence constitution
[x] Knowledge model
[x] Evidence pipeline specification
[x] Database architecture
[x] Content governance
[x] Product information architecture
[x] MVP implementation plan drafted

[x] Web application bootstrap
[x] Supabase schema/security foundation
[~] Golden evidence slice
[~] First admin workflow
[!] First published Claim
[x] First clinician UI
[ ] Comparison golden slice
[ ] Norwegian product ingest
[ ] Pilot evidence pipeline
[ ] Clinical situation views
[ ] First ClinicalRule
[ ] Usability validation
[ ] Security/accessibility hardening
[ ] Public MVP candidate
```

**Milepæl A (§57) er nådd.** Appen kjører, CI kjører, Supabase-devmiljøet fungerer,
sikkerhetsgrensene er etablert og de første migrasjonene er i repoet.

**Slice 0 (§28) er ferdig.** Alle fire punktene i definition of done er innfridd, også
preview deployment: Vercel-prosjektet er koblet til repoet gjennom GitHub-integrasjonen
og bygger både preview per pull request og produksjon fra `main`. Koblingen er satt opp
på prosjektsiden hos Vercel, ikke som konfigurasjon i repoet, så fravær av `vercel.json`
sier ingenting om status.

`First admin workflow` og `First published Claim` stod begge som `[!]`, men grunnen har
endret seg. Fram til nå var de blokkert av en governance-beslutning som ikke var tatt: hvem er
den navngitte kvalifiserte redaktøren? Den beslutningen er tatt, og redaktøren er registrert
som aktør (§74.17). Det som gjenstår er ikke lenger et åpent spørsmål, men konkret arbeid som
ikke er gjort: en reell brukerkonto, en rolletildeling, to verifikasjonsfaser og en
godkjenning. Se §74.4.

**`First admin workflow` er flyttet fra `[!]` til `[~]`.** Tre av stegene §29 lister er nå
bygget og prøvd: «hvem er jeg, og hva har jeg lov til?» (§74.21-§74.22), «Editor oppretter
Source» — bekreftet i produksjon med en reell kilde (§74.24, §74.27) — og «Editor registrerer
EvidenceItem», nå også bekreftet i produksjon med et reelt evidensfunn (§74.27, §74.29).
Markeringen er ikke `[x]`: verifikasjon, review og publisering gjenstår. Den er heller ikke lenger `[!]`: ingenting blokkerer, det gjenstår arbeid.
`First published Claim` står urørt som `[!]`, av grunnene i §74.4.

**Slice 2 (§30) er ferdig.** Alle fem punktene i definition of done er dekket: klinikeren kan
finne påstanden og se hva Antidep hevder, hva det gjelder, hvor sikker kunnskapen er, hva
evidensen er og hvilken kilde som støtter eller motsier den — uten admin-tilgang. Det kom med
evidensvisningen (§74.15), som viser hele kilderaden på hvert funn: dokumenttype, tittel,
forfattere, tidsskrift, publiseringsdato med sin presisjon, kildestatus, DOI, PMID, sted i
kilden og kildeversjon.

Det siste leveransepunktet, «kildedetalj», kom med kildevisningen (§74.16):
`PRODUCT_INFORMATION_ARCHITECTURE.md` §42 er eksplisitt på at en `Source`-visning — én side
per kilde, med alt Antidep bruker den til — er en *annen* visning enn claim-evidensvisningen,
og de to lenker nå til hverandre uten å være blandet. Markeringen er derfor flyttet fra `[~]`
til `[x]`. Innholdet bak den er fortsatt minimalt av samme grunn som resten: ingenting er
publisert (§74.4).

**Produktinvariant 9 er innfridd.** «Hvorfor sier Antidep dette?» går nå fra hvert
påstandskort til en visning som faktisk svarer.

### 74.2 Faktisk PR-rekkefølge

```text
PR A  chore: bootstrap Antidep web app                                      (#9)   merget
PR B  db: add schema and security foundation                                (#10)  merget   migrasjon 001
PR C  db: add drug and clinical concept catalog                             (#11)  merget   migrasjon 002
PR D  db: add sources and evidence items                                    (#12)  merget   migrasjon 003
PR E  db: add claims and evidence assessments                               (#13)  merget   migrasjon 004
PR F  db: add review and provenance                                         (#14)  merget   migrasjon 005
PR G  db: add publication events and gate                                   (#15)  merget   migrasjon 006
      docs: record implementation status after migration 006                (#16)  merget   ingen migrasjon
      db: make evidence item content hash unambiguous                       (#17)  merget   migrasjon 006a
      db: add api published read model                                      (#18)  merget   migrasjon 007
      ci: verify the numeric claims in the plan                             (#19)  merget   ingen migrasjon
      db: add audit events                                                  (#20)  merget   migrasjon 008
      db: expose publication and review timestamps in api                   (#21)  merget   migrasjon 007a
      feat: add published read model client                                 (#22)  merget   ingen migrasjon
      feat: add claim card and certainty display                            (#23)  merget   ingen migrasjon
      feat: add routing and first clinician pages                           (#24)  merget   ingen migrasjon
      feat: add the claim evidence view                                     (#25)  merget   ingen migrasjon
      feat: add the source view                                             (#26)  merget   ingen migrasjon
      db: register the named qualified editor                               (#27)  merget   migrasjon 005a
      docs: correct the record of the hosted Supabase project               (#28)  merget   ingen migrasjon
      test: verify the api column contract                                  (#29)  merget   ingen migrasjon
      docs: clarify collaboration and reporting rules                       (#30)  merget   ingen migrasjon
      db: authorize the named qualified editor                              (#31)  merget   migrasjon 005b
      db: expose the caller's own actor and roles                           (#32)  merget   migrasjon 007b
      docs: mark #32 as merged in the PR log                                (#33)  merget   ingen migrasjon
      feat: add sign-in and my access                                       (#34)  merget   ingen migrasjon
      docs: record that the hosted project is migrated and api is exposed   (#37)  merget   ingen migrasjon
      feat: add the controlled write path for creating a Source             (#35)  merget   migrasjon 003a, 008a, 007c
      docs: mark #34, #35 and #37 as merged in the PR log                   (#38)  merget   ingen migrasjon
      db: grant the editor role for source registration                     (#39)  merget   migrasjon 005c
      docs: record the hosted project in sync and source creation deployed  (#41)  merget   ingen migrasjon
      feat: add the controlled write path for registering an EvidenceItem   (#43)  merget   migrasjon 008b, 007d, 007e
      docs: record the evidence registration deployed to the hosted project (#46)  merget   ingen migrasjon
      docs: record the first real evidence registration in production       (#47)  merget   ingen migrasjon
      db: add technical agent identity and agent runs                        (#48)  merget   migrasjon 005d, 008c, 005e, 005f
      db: add the extraction verification registration write path            (#50)  merget   migrasjon 008d, 005g
      feat: run the extraction verifier from source version to verification (#51)  merget   migrasjon 008e, 007f, 005h
      ops: activate the extraction verifier in the hosted project           (#56)  merget   ingen migrasjon
      feat: verify claims against their registered evidence                 (#57)  merget   migrasjon 008f, 005i, 005j, 005k, 006c, 005l
      feat: add the human claim review and publication approval flow        (#59)  merget   migrasjon 008g, 005m, 005n, 006d, 005o, 005p, 006e, 006f
      feat: add the human extraction check and make publication operational (#61)  merget   migrasjon 005q, 005r, 005s, 005t, 006g, 006h
      feat: rebuild the human control flow as a guided session              (#62)  merget   migrasjon 008h, 005u, 007g, 003b, 005v, 005w, 003c, 005x, 005y, 005z, 005æ, 005ø, 005å
      feat: make the current review decision race-safe                      (#65)  merget   migrasjon 006i, 007h
      db: make the source grounding part of an evidence item's identity    (#67)  merget   migrasjon 003d
      feat: add the model link that reads a source and drafts a proposal    (#68)  merget   migrasjon 005ab, 005ac
      feat: make the model link runnable by a Claude Code Routine          (#69)  merget   ingen migrasjon
      feat: extract from a local full-text PDF, end to end                 (#70)  merget   migrasjon 003e, 007i
      feat: gjør kildekontrollen mulig uten artikkelen ved siden av         (#73)  merget   ingen migrasjon
      fix: keep a two-column source excerpt readable in the control session (#75)  merget   ingen migrasjon
      feat: gi et kildeomfattende fravær et kontrollledd som kan bære det   (#78)  merget   migrasjon 005ad, 005ae
      fix: la kontrollraden si hvor representasjonen faktisk kom fra        (#80)  merget   ingen migrasjon
      fix: la fraværsgjennomlesningen etterlate et spor                    (#81)  merget   ingen migrasjon
      fix: gjør PDF-tekstuttrekkingen kolonnebevisst                       (#86)  åpen     migrasjon 003g
```

Avviket fra §68 er bevisst: én migrasjon per PR gir mindre og mer reviewbare enheter,
i tråd med §51. Den planlagte PR G — `feat: add admin golden-slice workflow` — er
dermed ikke bygget ennå, og glir til etter migrasjon 008. Rekkefølgen mellom migrasjon
008 og PR I (`feat: add first drug and evidence UI`) er avgjort til fordel for 008, fordi
§25 er eksplisitt på at audit skal komme tidlig nok til at resten av admin-MVP-en bygges
med sporbarhet fra starten. Se §74.10.

PR I bygges i deler, slik §51 forutsetter: «bygg ClaimCard» og «bygg evidence drawer» står
der som egne PR-er. Første del, `feat: add published read model client`, inneholdt ingen
visning og etablerte den typede leseveien fra `api` inn i appen (§74.12). Andre del,
`feat: add claim card and certainty display`, er den første klinikerflaten: presentasjons-
enheten for én publisert påstand, uten ruting og uten datahenting (§74.13). Tredje del,
`feat: add routing and first clinician pages`, er den første navigerbare flaten: adressene,
forsiden, legemiddelsidene og temasiden, med datahenting (§74.14). Fjerde del,
`feat: add the claim evidence view`, er evidensdrilldownen bak «Hvorfor sier Antidep dette?»
(§74.15). Femte og siste del, `feat: add the source view`, er kildedetaljen: én side per kilde,
med alt Antidep bruker den til (§74.16). **PR I er dermed ferdig, og med den Slice 2.**

Tabellen over er en logg over utført arbeid, og skal føres i den PR-en som gjør arbeidet
ferdig, ikke i en senere. Statuskolonnen beskriver tilstanden da raden ble skrevet, så den
nyeste raden står alltid som `åpen` til neste PR retter den. Hva 006a innfridde, står i §74.8;
hva 007 innfridde, i §74.9.

**Raden for #37 føres her og ikke av #37 selv, og det er femte gangen konvensjonen svikter.**
Den PR-en skrev §74.18, §74.23 og `supabase/README.md` uten å føre sin egen rad, og etterlot
samtidig #34 stående som `åpen` selv om den var merget. Vaktposten fanget det ikke, og kunne
ikke: den krever bare at hver rad *unntatt den nyeste* står som `merget`, og den nyeste raden
var nettopp #34. En rad som aldri blir skrevet, står ikke under noen — den er utenfor
kontrollen på samme måte som et tall som bare finnes i en hand-off (§74.18). Denne PR-en
etterfører raden, retter #34 og #35, og fører sin egen rad slik konvensjonen sier.

**Hoppet fra #34 til #37 er ikke et hull, og #35 står under #37 og ikke over.** #35 var åpen
da raden for #37 ble skrevet, og førte sin egen rad da den selv merget — etter konvensjonen
over. #37 merget først (`4903d2a`), #35 etter (`f86b24d`), og rekkefølgen i tabellen er
faktisk mergerekkefølge og ikke nummerrekke. #36 er en issue og ikke en PR.

Titlene er commit-emnene ordrett. Kolonnebredden er derfor utvidet framfor å forkorte en
tittel: en logg som gjengir noe annet enn historikken, kan ikke sammenlignes med den. Det har
skjedd to ganger — først for #37, så for den nyeste raden — og utvidelsen gjelder hele tabellen,
slik at kolonnen står på samme sted i alle rader.

Raden for denne PR-en selv føres i en egen commit på samme PR: PR-nummeret er ikke tildelt
før PR-en er åpnet, og en foreløpig rad uten nummer ville vært en påstand tabellen ikke kan
stå for. `(#N)` i parentes skal aldri stå andre steder i planen enn i denne tabellen, så
nummeret venter til det finnes.

Raden for #30 føres her og ikke av #30 selv. Den PR-en endret bare `CLAUDE.md` og rørte
verken planen eller vaktposten, så loggen fikk et hull mellom #29 og #31. Et hull i en tabell
som heter «faktisk PR-rekkefølge» leses som en feil, ikke som et fravær, og etterføring er
billigere enn å la nummerrekken være usann.

Konvensjonen har sviktet fire ganger på rad, og er derfor ikke lenger bare en konvensjon:
`scripts/verify-counts.sh` krever at hver rad unntatt den nyeste står som `merget`, og at
hver rad ført som `merget` har sin commit i git-historikken. Den nyeste raden er unntatt,
fordi en PR ikke kan kjenne sin egen mergestatus — og nettopp derfor slår kontrollen ut i
det øyeblikket noen legger til raden under en foreldet rad.

**Migrasjonsnumrene i §18-§27 navngir planlagt innhold, ikke filrekkefølge.** Den niende
migrasjonsfilen er migrasjon 008, fordi den sjuende — korreksjonsmigrasjonen 006a — står
utenfor den planlagte rekken og fikk en bokstav. Konvensjonen finnes nettopp for at
«migrasjon 007 — API-lesemodell» (§24) skal bety det samme i plan, migrasjoner og tester.
Den tiende filen er migrasjon 007a av samme grunn: den utvider api-lesemodellen fra §24 og
står utenfor den planlagte rekken, og nummeret 009 er reservert for DrugProduct- og
importfundamentet (§26). Den ellevte filen er migrasjon 005a, som utvider aktørregisteret fra
§20 og står utenfor rekken på nøyaktig samme måte. Det gjør også den tolvte, migrasjon
005b, som fullfører det 005a bevisst lot stå åpent, og den trettende, migrasjon 007b, som
utvider api-lesemodellen fra §24 slik 007a gjorde. Den fjortende filen er migrasjon 003a, som
utvider kildetabellen fra §20 og lukker et attribusjonshull migrasjon 005 etterlot (§74.24).
Den femtende, migrasjon 008a, utvider auditvokabularet fra §25 med én ny verdi. Den sekstende,
migrasjon 007c, utvider api-lesemodellen fra §24 en fjerde gang — med det første skrivbare
medlemmet, adminflytens kontrollerte skrivevei for å opprette en Source (§29, §74.24). Den
syttende, migrasjon 005c, utvider medlemskapsmodellen fra §20 slik 005b gjorde, og tildeler
den `editor`-rollen den skriveveien krever (§74.25). De tre siste hører til steg 3 av
adminflyten (§74.27): migrasjon 008b utvider auditvokabularet med enda én verdi, 007d utvider
api-lesemodellen en femte gang — med den redaksjonelle lesemodellen registreringen trenger —
og 007e gir den sitt andre skrivbare medlem, skriveveien for å registrere et EvidenceItem.
De fire neste hører til agentidentiteten (§74.31): 005d utvider agentrollevokabularet med
`extraction_verification`, 008c utvider auditvokabularet med agentidentitetenes tre
livssyklushendelser, 005e bygger identitets- og kjøringsmodellen med sine to
api-inngangspunkter, og 005f registrerer den første agentidentiteten.
De to neste hører til skriveveien for verifikasjonen (§74.30, §74.31, §74.32): 008d utvider
auditvokabularet en sjette gang, med `evidence_verification_registered`, og 005g bygger den
kontrollerte skriveveien som lar den registrerte ekstraksjonsverifikatoren registrere en
verifikasjon i `workflow.evidence_verifications` — bundet deklarativt til riktig aktør og
riktig agentrolle med to sammensatte fremmednøkler mot `provenance.agent_runs`.
De fire siste lukker kjeden fra kildeversjon til kjørt verifikasjon (§74.33): 008e utvider
auditvokabularet en sjuende gang med `source_version_registered`, 007f gir api-lesemodellen
sitt tredje skrivbare medlem — skriveveien for å registrere en kildeversjon, med
fingeravtrykket beregnet av databasen — 005h gir verifikatoren leseveien inn til
grunnlaget den kontrollerer mot, og 006b lar publiseringsgaten lese hva kontrollene faktisk
dekket, slik at en delkontroll ikke alene kan tilfredsstille den.
Filrekkefølgen er dermed 001, 002, 003, 004, 005, 006, 006a, 007, 008, 007a, 005a, 005b,
007b, 003a, 008a, 007c, 005c, 008b, 007d, 007e, 005d, 008c, 005e, 005f, 008d, 005g, 008e,
007f, 005h, 006b — sortert på tidsstempel, ikke på migrasjonsnummer, og de tjue siste filene
bærer alle et bokstavnummer, altså et nummer utenfor den planlagte rekken. (Setningen sa tidligere at «de
seks siste filene bærer de seks laveste bokstavnumrene». Det stemte ikke mot listen over —
006a og 007a har lavere bokstavnumre enn flere av dem — så den er erstattet med den påstanden
listen faktisk bærer.)

Databaselaget teller nå 2187 pgTAP-assertions over 67 testfiler.

Tallene i dette avsnittet og i §74.5 kontrolleres maskinelt av
`scripts/verify-counts.sh`, som kjører i CI. Bakgrunnen er §74.8: to ganger har et tall
vært feil fordi det ble arvet fra en gjeldspost eller en hand-off og ført videre i god tro,
ikke fordi noen regnet feil. Slår kontrollen ut, er dokumentet feil — kilden vinner. En
setning som omformuleres slik at vakten ikke finner påstanden lenger, teller også som brudd;
ellers ville vakten blitt stille uten at noen merket det.

### 74.3 Hva databasen faktisk inneholder

Kunnskapsmodellen er komplett til og med publisering: katalog, kilder og kildeversjoner,
evidensfunn, påstander med immutable revisjoner, evidenslenker, evidensvurderinger,
aktører, rollemodell, ekstraksjons- og claim-verifikasjon, reviewbeslutninger, og
publiseringshistorikk med en kontrollert publiseringsoperasjon.

Fra migrasjon 007 finnes også leseveien ut: tre views i `api`, de første RLS-policyene, og
`SELECT` til klientrollene på de tretten tabellene viewene leser. Kjeden er dermed lukket i
begge ender — det som mangler mellom dem, er en publisering.

Fra migrasjon 007a bærer `api.published_claims` i tillegg `published_at` og
`last_reviewed_at`, slik at hver publisert påstand har både en publiseringsdato og en dato
for den menneskelige godkjenningen den hviler på — også et deterministisk faktum, som ikke
har noen evidensvurdering. Se §74.11.

Fra migrasjon 008 finnes auditloggen: `audit.events`, med de to produsentene som dekker de
skriveveiene som faktisk finnes i dag — publisering og rolleforvaltning. Loggen er tom i
migrert tilstand, av samme grunn som api-projeksjonene er det: ingenting er publisert, og
ingen rolle er tildelt. Se §74.10.

Innholdet er derimot bevisst minimalt, og det er ikke det samme som at slicen er ferdig:

- to virkestoff, to kliniske begreper, én populasjon
- to kilder og to evidensfunn
- to påstander med én revisjon, én evidenslenke og én evidensvurdering hver
- tre aktører: to KI-roller og den navngitte kvalifiserte redaktøren (§74.17)

**Ingen verifikasjon, ingen reviewbeslutning og ingen publisering er registrert.** Redaktøren
er navngitt, men har verken brukerkonto eller rolletildeling, og kan derfor ikke registrere en
faglig beslutning — `workflow.enforce_reviewer_qualification()` avviser forsøket, og
`220_provenance_seed_test.sql` prøver det framfor å påstå det. De to påstandene er fortsatt
ubekreftede KI-forslag, og `current_published_revision_id` er tom på begge.

**Migrasjon 005b endrer ikke listen over, og det er ikke en forglemmelse.** Den kobler
redaktørens aktørrad til brukerkontoen og tildeler `reviewer`-rollen — men bare i miljøer der
kontoen finnes i `auth.users`. Den finnes bare i det hostede prosjektet, og der er ingen
migrasjon kjørt (§74.18). I en fersk lokal stack og i CI gjør migrasjonen derfor ingenting,
og sier fra om det. Se §74.20.

### 74.4 Milepæl B er ikke nådd, og hvorfor

§58 krever at kjeden Source → EvidenceItem → Claim → review → publish *fungerer*.
Maskineriet finnes og er testet, men kjeden er ikke kjørt gjennom med reelle data.

Det er ikke en teknisk mangel. Publisering av en evidenssyntese krever menneskelig
faglig godkjenning fra en navngitt kvalifisert redaktør (ANTIDEP_CONSTITUTION.md §12),
og migrasjon 005 gjorde det til en strukturell umulighet uten en reell person: en
reviewbeslutning krever en aktør av typen `human`, knyttet til en brukerkonto, med
gyldig `reviewer`-rolle for innholdsområdet på beslutningstidspunktet.

**Governance-beslutningen er tatt.** Spørsmålet var hvem den kvalifiserte redaktøren er, og
prosjekteieren — Peder Holman — har utpekt seg selv. Migrasjon 005a registrerer vedkommende
som menneskelig aktør, slik at beslutningen står som en kanonisk rad framfor som en setning i
dette dokumentet (§74.17).

Konsekvens for rekkefølgen: migrasjon 007 (§24) er bygget, og api-projeksjonene viser et
tomt publisert sett. Det er korrekt oppførsel. 007 er testet mot data opprettet inne i en
transaksjon som rulles tilbake — samme mønster som 006 — framfor mot seedet innhold, og
`220_provenance_seed_test.sql` bekrefter fortsatt at ingenting er publisert.

**Denne teksten sa tidligere at det gjenstod «nøyaktig én ting» for Milepæl B. Det var
feil.** Påstanden ble ført videre fra en tidligere oppdatering uten å bli kontrollert mot
publiseringsgaten i migrasjon 006, og gaten stiller sju krav som ikke er innfridd:

| Krav | Hva som mangler |
|---|---|
| G4, G5 | Hvert lenket evidensfunn skal ha en registrert ekstraksjonsverifikasjon, og den gjeldende skal bekrefte funnet. `workflow.evidence_verifications` er tom |
| G8, G9 | Revisjonen skal ha en registrert claim-verifikasjon, og den gjeldende skal si `verified`. `workflow.claim_verifications` er tom |
| G11, G12 | Menneskelig godkjenning skal finnes og være den gjeldende beslutningen. `workflow.review_decisions` er tom |
| G13 | Evidensgrunnlaget skal være det samme som godkjenningen ble gitt for. Forutsetter at en godkjenning finnes |

Registreringen av redaktøren berører ingen av dem. Den fjerner et hinder foran G11 — §12 sin
navngitte redaktør finnes nå — men åpner ikke kravet: en reviewbeslutning krever i tillegg en
reell brukerkonto og en gyldig `reviewer`-rolle, og verifikasjonsfasene bak G4/G5 og G8/G9 er
urørt. Verifikasjonene kan være agentproduserte, så lenge §10 sitt skille mellom den som
genererte og den som kontrollerer holdes, og §11 sitt krav om at kontrollen skjer mot
kildematerialet er innfridd. Godkjenningen kan ikke være agentprodusert.

**Det som gjenstod for Milepæl B var derfor fire ting**, ikke én: en reell brukerkonto med
`reviewer`-rolle for redaktøren, ekstraksjonsverifikasjonene, claim-verifikasjonene og selve
godkjenningen. Alt maskineri fra kilde til klientflate står ferdig og testet rundt det
tomrommet. Den første av de fire er siden utført; se avsnittet under.

**Den første av de fire er utført, og det som gjenstår er tre.** Migrasjon 005b knytter
redaktørens aktørrad til brukerkontoen og tildeler `reviewer`-rollen, og begge grenene av den
er kjørt i CI (§74.20). Migrasjonene er siden kjørt mot det hostede prosjektet, og der tok den
den positive grenen: `workflow.user_roles` har én rad, `role_code = 'reviewer'`, uten
scopebegrensning, uten sluttdato, gyldig nå og selvtildelt av `human:peder-holman` — lest fra
produksjonsdatabasen, ikke antatt (§74.23). G11 sin forutsetning om konto og gyldig rolle er
dermed innfridd. **Det som gjenstår for Milepæl B er ekstraksjonsverifikasjonene,
claim-verifikasjonene og selve godkjenningen.**

> **Avsnittet under er overhalt.** Det stod her mens rollen ennå ikke fantes noe sted, og er
> beholdt som historikk (§71): «Men *utført* er den ingen steder: kontoen finnes bare i det
> hostede prosjektet, og der er ingen migrasjon kjørt (§74.18). Redaktøren har derfor fortsatt
> ingen rolle i noen database.» Begge setningene er nå usanne; se §74.23.

**De tre som gjenstår er uendret, men den ene av dem har fått en vei fram.** §74.30 punkt 4
fant at ingen kunne registrere ekstraksjonsverifikasjonen av redaktørens eget evidensfunn:
regelen krever en annen aktør, og de to KI-aktørene hadde ingen måte å autentisere seg på.
Valget stod mellom å registrere en andre navngitt person og å bygge agentidentiteten §16
forutser. Beslutningen er tatt — Antidep er agent-first — og identiteten er bygget (§74.31).
Verifikasjonen selv er fortsatt ikke registrert, så G4/G5 er urørt; det som er borte, er
hindringen foran dem.

G8 er verdt å merke seg særskilt, fordi den er lett å utelate når kravene listes opp: G9 leser
utfallet på den gjeldende claim-verifikasjonen, mens G8 er kravet om at det finnes en i det
hele tatt. Med en tom tabell feiler begge, på hver sin måte. Dette er sjette gang et tall
eller en påstand i planen har vært arvet framfor kontrollert (§74.8), og den ble funnet ved å
lese gaten framfor hand-offen.

**Beslutningen som blokkerte rollegranten, er tatt og gjennomført.** Prosjekteieren opprettet
redaktørens brukerkonto i autentiseringslaget i det hostede Supabase-prosjektet.
`workflow.user_roles.user_id` er `NOT NULL` med fremmednøkkel til `auth.users`, og CI starter
en fersk lokal stack uten den kontoen, så migrasjonen kunne ikke skrives før det var avgjort
hva den skulle gjøre i miljøer der kontoen ikke finnes. Valget, med prisen på hver vei, står i
§74.18; hvordan prisen faktisk ble betalt, står i §74.20.

**Adminflyten er begynt, og den lukker ingen av de fire.** Migrasjon 007b åpner den
autentiserte leseveien for «hvem er jeg, og hva har jeg lov til?» — kallerens egen aktørrad
og egne gjeldende rolletildelinger, og ingenting mer (§74.21). Det er første steg i «manuell
adminflyt», den ene leveransen §29 lister for Slice 1 og som ikke er bygget. Ingen av de sju
gatekravene i tabellen over er berørt: migrasjonen skriver ingen verifikasjon, ingen
reviewbeslutning og ingen publisering, og den tildeler ingen rettighet. Den gjør bare en
rettighet som allerede finnes, lesbar for den som har den.

**Steg 2 og 3 er siden bygget og bekreftet i produksjon, og de lukker heller ingen av de tre
som gjenstår.** «Editor oppretter Source» (§74.24): den første reelle kilden er opprettet
gjennom skjemaet (§74.27). «Editor registrerer EvidenceItem» (§74.27): det første reelle
evidensfunnet er registrert gjennom skjemaet (§74.29). Begge produserer objekter *foran* gaten:
et evidensfunn er nettopp det G4 og G5 senere skal kreve en verifikasjon av, og verken
verifikasjon, reviewbeslutning eller publisering er rørt. Neste ledd, ekstraksjonsverifikasjonen
bak G4/G5, er planlagt i §74.30.

**Begge verifikasjonsleddene er siden bygget og kjørt i produksjon, og ingen av dem lukker en
gate — fordi ingen av dem konkluderte.** Ekstraksjonsverifikasjonen er kjørbar og kjørt
(§74.33, §74.34), og claim-verifikasjonen er bygget og kjørt (§74.35). Alle fem registrerte
kontrollene står som `uncertain`, og det er riktig: begge kontrollene er deterministiske, og en
deterministisk kontroll kan falsifisere, men ikke bekrefte at ordlyden er dekket eller at ingen
motstridende evidens mangler. **Det som gjenstår for Milepæl B er derfor fortsatt de samme tre
tingene** — en bekreftet ekstraksjonskontroll bak G4/G5, en bekreftet claim-kontroll bak
G8/G9, og den menneskelige godkjenningen bak G11/G12/G13 — men maskineriet foran alle tre er nå
bygget, prøvd og kjørt mot reelle rader. Den gjeldende avlesningen står i §74.35.

**Den menneskelige flyten er siden bygget, og den er den ene av de tre som har en vei fram uten
nytt maskineri.** §74.36 bygger skriveveiene og den redaksjonelle flaten for begge de
menneskelige beslutningene: kontrollen mot grunnlaget (G8/G9) og publiseringsgodkjenningen
(G11/G12/G13). Hele kjeden er prøvd mot de reelle radene og passerer gaten når begge
beslutningene er registrert. Ingen av dem *er* registrert i produksjon, og det er med hensikt:
begge er faglige vurderinger som hører til revieweren, ikke til en migrasjon eller en
agentsesjon. Det som gjenstår er dermed ikke lenger maskineri, men to reelle mangler — en
ekstraksjonskontroll som konkluderer, og en `publisher`-tildeling. Se §74.36.

### 74.5 Beslutninger tatt før migrasjon 007 eksponerte verdier utad

Alle tre er avgjort, og avgjørelsene er nå offentlig kontrakt:

1. **Enum kontra oppslagstabell — utsatt, og gjort billigere å utsette.** Det finnes
   40 enum-typer, fordelt på de syttiseks migrasjonsfilene 001, 002, 003, 004, 005, 006, 006a,
   007, 008, 007a, 005a, 005b, 007b, 003a, 008a, 007c, 005c, 008b, 007d, 007e, 005d, 008c,
   005e, 005f, 008d, 005g, 008e, 007f, 005h, 006b, 008f, 005i, 005j, 005k, 006c, 005l, 008g,
   005m, 005n, 006d, 005o, 005p, 006e, 006f, 005q, 005r, 005s, 005t, 006g, 006h, 008h, 005u,
   007g, 003b, 005v, 005w, 003c, 005x, 005y, 005z, 005æ, 005ø, 005å, 006i, 007h, 003d, 005ab,
   005ac, 003e, 007i, 003f, 005ad, 005ae, 003g, 008i og 005af — i
   filrekkefølge, ikke i nummerrekkefølge — med henholdsvis 1, 6,
   11, 7, 10, 2, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 og 0.
   Tallet er kontrollert mot kilden (`grep -cE '^create type ' supabase/migrations/*.sql`) og
   mot databasen. Alle syttiseks ledd er nå oppgitt eksplisitt framfor å la de siste hvile på
   restpåstanden i `scripts/verify-counts.sh`; det er den formen vakten kontrollerer
   strengest. Verken 005a, 005b, 007b eller 003a legger til enum-typer: den første
   registrerer én rad i et register som allerede finnes, den andre knytter og tildeler, den
   tredje projiserer to eksisterende vokabularer som `text` slik resten av `api` gjør, og den
   fjerde legger til en kolonne. 008a legger heller ikke til en enum-*type* — den utvider
   vokabularet til en type migrasjon 008 allerede opprettet, med `ALTER TYPE ... ADD VALUE`,
   som `^create type ` ikke fanger og ikke skal fange: det er en ny verdi, ikke en ny type.
   007c oppretter ingen egen enum-type av samme grunn som 007, 007a og 007b: den kaster
   eksisterende vokabularer til `text` i parameterlisten, av en grunn den selv forklarer
   (§74.23). 005c oppretter heller ingen: den skriver én rad i medlemskapsmodellen og bruker
   `workflow.app_role`, som migrasjon 001 opprettet. Av de tre neste er 008b en ren
   `ALTER TYPE ... ADD VALUE` som 008a, 007d projiserer eksisterende vokabularer som `text`
   som resten av `api`, og 007e tar dem imot som `text` som 007c. Av de fire neste er 005d og
   008c begge rene `ALTER TYPE ... ADD VALUE`, 005f skriver to rader uten å innføre noe
   vokabular, og bare 005e oppretter en ny type — `provenance.agent_run_status`. Den er den
   ene som løfter totalen fra 38 til 39. De to siste legger ingen til: 008d er en ren
   `ALTER TYPE ... ADD VALUE` som 008a, 008b og 008c, og 005g tar imot verifikasjonens tre
   vokabularer (utfall, kildetilgang og kontrollerte felter) som `text` og array av `text`, og
   caster dem i funksjonskroppen — samme mønster som 007c, 007d, 007e og 005e.
   De fem siste legger heller ingen til: 008f er en ren `ALTER TYPE ... ADD VALUE`,
   005i skriver to rader uten å innføre noe vokabular, 005j gjenbruker
   `workflow.verification_source_access` og `workflow.verification_check_result` fra
   migrasjon 005 på en ny tabell, 005k tar imot de samme vokabularene som `text` og `jsonb`
   og caster dem i funksjonskroppen, og 006c og 005l gjenskaper hver sine funksjoner.
   Av de sju siste oppretter bare 003b en ny type — `knowledge.source_representation`,
   som løfter totalen fra 39 til 40. 008h er en ren `ALTER TYPE ... ADD VALUE` som 008a,
   005u oppretter en tabell over et vokabular migrasjon 005 allerede eier, 007g flytter
   innsettingen ut i én delt funksjon uten å innføre noe vokabular, 005v tar imot de samme
   vokabularene som `text` og `jsonb` og caster dem i funksjonskroppen som 005k, 005w
   skriver én rad i et register som allerede finnes, og 003c skriver forankringsrader og
   setter en kolonne som 003b nettopp opprettet. 005x innfører heller ingen type: den
   legger til to kolonner, ett avtrykk og én forutsetning i en skrivevei som allerede
   fantes. Det gjør heller ikke de tre siste: 006i legger til et registreringsnummer,
   007h gjenskaper én funksjon, og 003d legger til en kolonne og tre funksjoner over
   vokabularer migrasjon 005 og 005u allerede eier.
   Viewene caster enum-kolonner til `text`, så den offentlige kontrakten er en streng
   fra et dokumentert vokabular, ikke PostgreSQL-typen. Et senere bytte til
   oppslagstabeller er dermed ikke en brytende API-endring. Castingen sparer også
   klientrollene for `usage` på typene.
2. **Katalogobjekter eksponeres med `uuid`, med ATC som ekstern nøkkel.** Radens
   databasegenererte `uuid` er identiteten (`DATABASE_ARCHITECTURE.md` §8), og for
   virkestoff følger ATC-kodene med som språkuavhengig ekstern nøkkel, som sortert
   array — se §74.9 om hvorfor de aggregeres framfor å joines. En egen
   slug-kolonne etter mønster av `provenance.actors.actor_key` ville krevd en
   katalogmigrasjon utenfor §24 og er ikke innført. Spørsmålet kan tas opp igjen når
   en klient faktisk trenger en menneskelesbar nøkkel i URL-er.
3. **`public` er fjernet fra `[api].schemas`.** Verdien er nå
   `["api", "graphql_public"]`. Schemaet inneholdt ingen Antidep-objekter — §5 er opt-in,
   og en tom eksponering er fortsatt en eksponering. Verdien kontrolleres nå mot
   `supabase/config.toml` av `scripts/verify-counts.sh`, av samme grunn som tallene over: en
   påstand om en konfigurasjonsverdi driver, hvis ingenting sammenligner den med verdien.

   **`api` står først i `config.toml` og er dermed standardprofilen i PostgREST — men appen
   hviler ikke på det.** `src/lib/supabase.ts` setter `db: { schema: 'api' }`, så supabase-js
   sender `Accept-Profile: api` på hver forespørsel og er uavhengig av standardprofilen.
   Rekkefølgen gjelder dessuten bare `config.toml`: i dashboardet er eksponerte schemaer en
   avhukingsmeny uten rekkefølge, så setningen beskriver den lokale stacken og ikke det
   hostede prosjektet.

   **«Endringen må synkes manuelt mot det hostede prosjektet» stod her uten forbehold, og
   var utilstrekkelig.** Det finnes ikke noe `api`-schema å eksponere der: migrasjonene er
   aldri kjørt mot det hostede prosjektet, og databasen der er tom. Se §74.18.
   **Dette er ikke lenger tilstanden.** Migrasjonene er siden kjørt, og synkingen er gjort:
   eksponerte schemaer i det hostede prosjektet er `api, graphql_public`. Se §74.23.

### 74.6 Invariant etablert i migrasjon 006

To reviewfunn i PR #15 hadde samme rot: PostgreSQL-tid har flere betydninger, og
`now()` er transaksjonens *starttidspunkt* — verken committidspunkt eller nåtid.
Regelen som ble etablert, gjelder framover:

> **Tid som *avgjør* noe måles på setningen (`statement_timestamp()`).
> Tid som *registrerer* noe måles på transaksjonen (`now()`).**

Spørsmålet «er evidensgrunnlaget endret siden godkjenningen?» besvares dessuten ikke
med tid i det hele tatt, men med et databaseeid avtrykk av settet, fordi
commitrekkefølgen ikke er lesbar fra radene. Den som skriver ny autorisasjons- eller
gyldighetslogikk bør lese dette før `now()` brukes i et predikat.

### 74.7 Registrert arkitekturgjeld (§72)

| Gjeld | Risiko | Trigger for opprydding |
|---|---|---|
| Tidsbasert utløp av review er ikke håndhevet i publiseringsgaten | En godkjenning eldes uten at noe fanger det | Migrasjonen som innfører `workflow.review_requirements` / `review_due_at`. Krever først en klinisk policy for hvor lenge en godkjenning er gyldig per kunnskapstype og risiko |
| Godkjenningens evidensavtrykk beregnes ved innsetting, ikke fra det reviewer faktisk så | En lenke som commiter mellom reviewers lesing og lagring av beslutningen havner i avtrykket | Admin-flyten oppgir avtrykket den viste reviewer. Kolonnen er utformet for det |
| `knowledge.publication_object_type` har én verdi, og hendelsen har én ekte fremmednøkkel | En andre publiserbar objekttype kan friste til å gjenbruke `claim_id` som generisk `object_id` | Migrasjonen som innfører objekttype nummer to må legge til egen fremmednøkkelkolonne og eget speil |
| En tilbaketrukket ekstraksjon utløser ingen automatisk avpublisering eller ny review | En publisert påstand kan bli stående mens deler av grunnlaget er underkjent. Lesemodellen merker det nå (§74.9), men livssyklusen er ikke lukket | Admin-flyten (§29). Der hører beslutningen om hva som skal skje med berørte publiseringer hjemme — automatisk avpublisering er en klinisk policy, ikke en implementasjonsdetalj |
| En fornyet godkjenning etter publisering oppdaterer ikke «sist faglig vurdert» | `last_reviewed_at` er frosset på publiseringshendelsen. Blir en publisert revisjon godkjent på nytt i en reviewsyklus, står den gamle datoen. I dag er det ikke en reell risiko, fordi det ikke finnes noen reviewsyklus | Migrasjonen som innfører `workflow.review_requirements` / `review_due_at`. Den må ta stilling til om en fornyet godkjenning skal flytte datoen, og er samme migrasjon som gjeldsposten om tidsbasert utløp over |
| En reviewbeslutning som ikke er `approved`, registrert etter publisering, er usynlig i lesemodellen | Ber reviewer om endringer på en revisjon som allerede står publisert, flyttes verken publiseringspekeren eller `last_reviewed_at`, og klienten får ingen signal. Parallellen er `withdrawn_evidence_count`, som ble innført for det tilsvarende tilfellet på evidenssiden | Admin-flyten (§29), sammen med beslutningen om hva som skal skje med berørte publiseringer. Å eksponere beslutningstypen er en governance-endring: §74.11 avgrenset kontrakten til tidsstempler |
| Ingen regel håndhever at en publisert påstand har en publiseringshendelse | `knowledge.claims.current_published_revision_id` kan i prinsippet flyttes uten at en hendelse skrives, og da blir `published_at` NULL i `api.published_claims`. Invarianten er dokumentert i migrasjon 006, men bare håndhevet ved at publiseringsoperasjonen er den eneste sanksjonerte skriveveien | Admin-RPC-laget, eller den første migrasjonen som trenger å stole på hendelsen som kilde framfor på pekeren. En deklarativ regel må håndtere at pekeren og hendelsen settes i samme transaksjon |
| `api.published_claims` eksponerer populasjonens etikett, ikke dens strukturerte grenser | Aldersgrenser, indikasjon, graviditetskontekst og komorbiditet ligger bare i etiketteksten | Det første viewet som faktisk trenger å filtrere på populasjon. `catalog.populations` er allerede lesbar for klientrollene, så det er en projeksjonsendring, ikke en tilgangsendring |
| Felles hjelpefunksjoner (`catalog.set_row_timestamps()`, `catalog.set_created_at()`, `knowledge.reject_append_only_mutation()`) brukes fra flere schemaer | Lav; plasseringen er misvisende. Migrasjon 008 gjorde den mer misvisende: `audit.events` bruker begge de to siste, så `catalog` og `knowledge` eier nå hjelpefunksjoner for et schema som ikke har noe med noen av dem å gjøre | Et `util`-schema endrer `DATABASE_ARCHITECTURE.md` §6 og hver schemauttømmende vaktpost i testpakken. Egen beslutning |
| Fysisk sletting av en rolletildeling er selv uauditert | En rolletildeling kan fjernes fysisk uten at det står hvem som fjernet den. Auditradene for tildelingen og avslutningen består — det er nettopp derfor `object_id` ikke har fremmednøkkel — men slettingen selv etterlater ingen rad. En trigger kan ikke navngi den som sletter, fordi `DELETE` ikke bærer en aktør, og `audit.events.actor_id` er med hensikt `NOT NULL` | Admin-flyten (§48). Der går slettingen gjennom en kontrollert funksjon som kjenner aktøren, og `DATABASE_ARCHITECTURE.md` §36 sitt krav om «særskilt audit» ved fysisk sletting kan innfris |
| Endringer på `provenance.actors` auditeres ikke | Aktørraden er festepunktet for all attribusjon, og visningsnavn, beskrivelse og tilbaketrekking kan endres uten spor. Identiteten er riktignok frosset av `provenance.freeze_actor_identity()`, så det som kan endres er presentasjon og livssyklus, ikke hvem aktøren er | Samme trigger som over, og av samme grunn: tabellen har ingen kolonne som sier hvem som endret raden, så en trigger har ingen aktør å registrere |
| `audit.events.request_or_run_id` har ingen produsent | Auditrader kan ikke grupperes etter forespørselen eller agentkjøringen de hørte til, så en operasjon som består av flere skrivinger framstår som uavhengige hendelser. `provenance.agent_runs` finnes nå (§74.31) og er den identiteten kolonnen ble laget for, men ingen skrivevei sender den ennå: en kjøring rører ingen kunnskapsobjekter, så det er først den første skrivende agentoperasjonen som har en kjøring å oppgi | Den første skrivende agentoperasjonen — ekstraksjonsverifikasjonen — eller det første admin-RPC-laget som har en forespørselsidentitet å sende med |
| Agentflaten har ingen rate limiting | `api.begin_agent_run(...)` og `api.complete_agent_run(...)` er kjørbare for `anon`, fordi en agent ikke har brukerkonto (§16). Legitimasjonen bærer sikkerheten: 256 bits fra databasens egen kryptografiske tilfeldighetskilde, ingen lesing eller skriving før autentiseringen har lyktes, og identiske avvisninger for alle feilmodi, slik at flaten ikke kan brukes til å telle opp identiteter. Det som mangler er en grense for hvor mange forsøk som kan gjøres. Å logge mislykkede forsøk i basen ville gitt en uautentisert skrivevei, altså byttet en teoretisk risiko mot en reell | Ført som GitHub-issue 49. Hører til et lag som kan telle uten å skrive i den kanoniske basen — plattformens egen rate limiting, en kant foran Data API-et, eller en agentkjører som ikke eksponerer flaten utad i det hele tatt |
| Den synlige `notice` fra migrasjon 005b er ikke maskinelt kontrollert | §74.18 krevde at raden ikke skal utebli i stillhet når brukerkontoen mangler, og migrasjonen gir derfor en `notice`. pgTAP kan ikke observere en `notice`, så den delen av kravet hviler på at et menneske leser utdataene fra `supabase db push`. Statusen `account_missing` som funksjonen returnerer, er den halvdelen som *er* kontrollert (`350_editor_authorization_test.sql` assertion 1), og en mutasjon som degraderer `raise notice` til `raise debug` overlever derfor hele suiten | Den første vaktposten som uansett må lese utdataene fra en migrasjonskjøring — eller en avvikling av behovet, ved at kontoen finnes i alle miljøer og grenen ikke lenger kan tas |
| En basiskolonne kan miste sin `NOT NULL` uten at kolonnekontrakten fanger det | Kolonnenavn og kolonnetyper i `api` er nå uttømmende kontrollert mot katalogen, og nullbarheten er målt på faktiske rader (§74.19). Målingen fanger en kolonne som blir nullbar fordi joinen, uttrykket eller projeksjonen endres — den minimale probe-raden går da NULL. Den fanger ikke at en basiskolonne under viewet stille mister sin `NOT NULL`: probe-fiksturen navngir kolonnen i sin `insert`, så den fortsetter å sette en verdi, og raden ser lik ut. Klienten ville lest en kolonne som `string` mens databasen kan svare `null` | Enten en avledning som knytter hver ikke-nullbare api-kolonne til den basiskolonnen den kommer fra og krever `attnotnull` der — det krever en kolonnekartlegging gjennom viewdefinisjonen, som PostgreSQL ikke eksponerer ferdig — eller den første migrasjonen som gjør en basiskolonne nullbar. Migrasjonen må da endre kontraktsraden i `supabase/tests/340_api_column_contract_test.sql` og radtypen sammen |
| Ingen regel binder et kontrastivt effektmål til en komparator | `knowledge.claim_revisions` tillater fortsatt `magnitude_measure = 'mean_difference'` sammen med `comparator_kind = 'none'`, og en redaktør kan skrive kombinasjonen. Migrasjon 003 tillater nøyaktig det samme paret på `knowledge.evidence_items`, så gjelden gjelder begge tabellene. Presentasjonslaget nekter nå å tolke den på begge (§74.13, §74.15) gjennom én felles avledning, men det er et forsvar i visningen, ikke en invariant: dataene er like ugyldige, og enhver annen leser av `api` ser dem rå | Migrasjonen som legger til betingelsen, eller admin-flyten (§29), som er første sted en redaktør kan skrive kombinasjonen. Regelen må ta stilling til `mean_change`, som er en endring fra behandlingsstart og korrekt har `none` |
| Ingen regel binder en tallfestet effekt til at evidensen er graderbar | En revisjon kan bære `magnitude_value` samtidig som vurderingen er `no_assessable_evidence` — som ifølge migrasjon 004 betyr at det ikke finnes tilstrekkelig grunnlag til å gjøre en vurdering i det hele tatt. Kolonnekommentaren på `magnitude_value` sier selv at en påstand som er mer presis enn evidensen under den, er et brudd på `ANTIDEP_CONSTITUTION.md` §4 og §6, men ingen `CHECK` håndhever det på tvers av de to tabellene. Presentasjonslaget skjuler tallet (§74.13); databasen tillater det | Samme migrasjon som over, eller admin-flyten. Regelen krysser `knowledge.claim_revisions` og `knowledge.evidence_assessments`, så den må enten være en trigger eller en betingelse i publiseringsgaten |
| Modellen kan ikke avgjøre om en effektstørrelses fortegn stemmer med påstandens retning | `direction = 'increase'` med `magnitude_value = -0,4` ser motstridende ut, men er det ikke nødvendigvis: fortegnet hører til skalaen `magnitude_unit` måler på, og modellen registrerer ikke om den skalaens positive retning peker samme vei som temaet påstanden handler om. «Økning i vekttap» med en negativ vektforskjell er konsistent. Kontrollen er derfor bevisst ikke innført — den ville gitt falske utslag på gyldige data | Det første objektet som registrerer polariteten til et utfall i forhold til sitt `ClinicalConcept`. Uten det kan verken UI eller en databaseregel bedømme fortegnet |
| Adressen til et katalogobjekt er avledet av visningsnavnet, ikke lagret | `/drugs/sertralin` og `/topics/vektendring` bygges ved å slå opp sluggen mot de kanoniske navnene i det publiserte settet (`src/lib/slug.ts`). En slug avledet av et visningsnavn er ikke en stabil identitet: endres navnet i katalogen, endres adressen, og en delt lenke slutter å virke (§55). Avledningen er dessuten tapsgivende, så to navn kan kollidere — oppslaget svarer da `ambiguous` framfor å velge, men adressen er ikke lenger entydig | En slug-kolonne i katalogen etter mønster av `provenance.actors.actor_key`, i den migrasjonen som først trenger en permanent lenke — eller det første katalogobjektet som faktisk kan skifte navn. Spørsmålet ble utsatt i §74.5 punkt 2 «til en klient faktisk trenger en menneskelesbar nøkkel i URL-er»; det behovet har nå meldt seg, og utsettelsen er derfor gjeld og ikke lenger et åpent valg. Gjelden er bevisst ikke utvidet: kildesiden adresseres med `source_id` framfor med en slug av tittelen (§74.16 punkt 3), så avledningen gjelder fortsatt to objekttyper og ikke tre |
| Temasiden og kildesiden laster hele det publiserte settet | `api` har verken en tema- eller en kildeprojeksjon. `/topics/:slug` henter alle publiserte påstander og filtrerer i klienten, fordi en slug ikke kan inverteres til en etikett. `/sources/:sourceId` henter kilden fra `published_claim_evidence`, men evidensradene bærer ikke `statement`, så hele det publiserte settet hentes i tillegg og **joines** i klienten for å kunne navngi hva kilden brukes til (§74.16 punkt 1). Det skalerer ikke: en kunnskapsbase med hundrevis av påstander lastes i sin helhet for å vise ett tema eller én kilde, og klienten gjør et arbeid databasen burde gjort. Kildesiden er den andre forekomsten og den første som joiner framfor bare å filtrere | Et `api.published_topics`-view og en projeksjon som gir påstandsformuleringen sammen med evidensraden — eller en slug-kolonne i katalogen (posten over) — slik at oppslaget skjer på serversiden, som på legemiddelsiden. Utløses i praksis av den første utvidelsen av pilotinnholdet (§33) |
| `knowledge.sources.superseded_by_source_id` er ikke i api-kontrakten | Kildestatusen `superseded` betyr per migrasjon 003 at en *bestemt* nyere kilde er registrert: kolonnen er NOT NULL hvis og bare hvis statusen er den, og de to forutsetter hverandre. Pekeren er verken i `api.published_claim_evidence` eller i `src/types/api.ts`, så klienten kan ikke følge den. Kildesiden sier derfor eksplisitt at etterfølgeren er registrert uten å kunne navngis (§74.16 punkt 5); uten den setningen ville etiketten «Erstattet av en nyere kilde» vært en halv sannhet, og fravær av et navn ville sett ut som fravær av en etterfølger. Prisen er at en kliniker ikke kan gå fra en utdatert kilde til den som erstattet den | Migrasjonen som utvider viewet. Den må projisere etterfølgerens *tittel* og ikke bare dens `uuid` — en identitet klienten ikke kan slå opp, er ikke et svar — og ta stilling til hva som vises når etterfølgeren ikke selv er lesbar for klientrollene, siden RLS bare gir tilgang til kilder som ligger under en publisert påstand |
| Katalogstatusen på et virkestoff vises ikke i klinikerflaten | `api.published_drugs.status` bærer `active`, `historical` eller `withdrawn`, men beskriver Antideps forvaltning av virkestoffet og ikke markedsstatus i Norge — det står eksplisitt i kommentaren på `catalog.drug_status`. «Aktiv» ved siden av et virkestoffnavn ville blitt lest som det siste, og §58 holder workflow-status utenfor klinikerflaten, så verdien er utelatt. Prisen er at en kliniker ikke kan se at Antidep ikke lenger vedlikeholder et virkestoff det står publiserte påstander om | Det første virkestoffet med publiserte påstander og status ulik `active`. Da må vokabularet lukkes og få kjøretidskontroll (§74.12 punkt 3), og ordlyden må navngi Antidep som subjekt framfor å se ut som en markedsstatus |
| `api.my_roles` kan ikke skille en utløpt rolletildeling fra ingen tildeling | Viewet viser bare tildelinger som gjelder nå, og det er riktig som autorisasjonssvar: begge tilfellene betyr «ingen rettighet nå». Som *forklaring* er de forskjellige. En reviewer hvis tildeling utløp i går, får se «du har ingen roller» uten at noe sier hvorfor, og kan ikke skille det fra aldri å ha hatt en. Radgrensen i RLS er allerede eierskap og ikke gyldighet, nettopp for at en historikkprojeksjon skal være mulig senere uten å røre policyen | Den første adminskjermen som skal forklare hvorfor en rettighet mangler. Da hører det til et eget `api`-view over kallerens egen rollehistorikk, ikke til en oppmyking av `api.my_roles`: å blande gjeldende og utløpte rettigheter i ett svar er nettopp den sammenblandingen viewet finnes for å hindre |
| `api.my_roles.scope_id` kan ikke slås opp til en etikett | En avgrenset rolletildeling viser hvilken *type* den er avgrenset til (`scope_type`), men ikke hvilket klinisk begrep. `catalog.clinical_concepts` er bare lesbar for klientrollene gjennom publiseringspredikatet i migrasjon 007, så et begrep uten publiserte påstander under seg ville gitt en tom etikett ved siden av en reell avgrensning — altså en avgrensning som så ut som ingen, og det er den farligste retningen å ta feil i. Derfor er etiketten utelatt framfor å være noen ganger tom. Prisen er at en klient foreløpig ikke kan navngi avgrensningen. Samme form som `superseded_by_source_id` over: en identitet klienten ikke kan slå opp, er ikke et svar | Den første avgrensede rolletildelingen i faktisk bruk — i dag er redaktørens tildeling uavgrenset (§74.20). Migrasjonen må ta stilling til hva som vises når begrepet ikke er lesbar for kalleren, og det er en tilgangsbeslutning og ikke en projeksjonsdetalj |
| Kompetansekravet for redaktørrollen er ikke definert, og redaktøren er utpekt av seg selv | `ANTIDEP_CONSTITUTION.md` §12 krever en «navngitt kvalifisert redaktør», men ingenting definerer hva som gjør noen kvalifisert. `CONTENT_GOVERNANCE.md` §11 legger nettopp det til Clinical Lead — «definere hvilke kompetansekrav som gjelder for reviewer-scope» — og Antidep har ingen Clinical Lead. Migrasjon 005a registrerer derfor en redaktør hvis utpeking hviler på prosjekteierrollen, ikke på et kontrollert kompetansekrav, og som er utpekt av seg selv. Samme person er dessuten prosjekteier og eneste faglige godkjenner; §45 og §46 ber om at en slik profesjonell binding registreres, og modellen har ingen kolonne for det noe sted. `workflow.user_roles.grant_reason` er i dag det eneste feltet en kvalifikasjon kan skrives i, og det er fritekst på tildelingen og ikke på personen. §72 sitt krav om at høyrisikoinnhold reviewes av noen som ikke var hovedforfatter, er innfridd bare fordi forfatteren er en KI-aktør. Migrasjon 005c gjør den delen konkret: med `editor` ved siden av `reviewer` kan redaktøren selv være forfatter av innholdet vedkommende er eneste godkjenner for, og da hviler `CONTENT_GOVERNANCE.md` §5 ikke lenger på at forfatteren tilfeldigvis er en maskin | Beslutningen om hvem som er Clinical Lead, og migrasjonene som tildeler rollene: begge må skrive kvalifikasjonen inn i `grant_reason` uansett, og er dermed første sted hullet blir konkret. `reviewer` ble tildelt i 005b, `editor` i 005c, og begge begrunnelsene viser til denne gjeldsposten framfor å påstå en kvalifikasjon Antidep har kontrollert. Skal lukkes før den første publiseringen av klinisk innhold — en godkjenning gitt under et udefinert kompetansekrav er ikke etterprøvbar (§14) |

### 74.8 Gjeld innfridd i korreksjonsmigrasjon 006a

Migrasjonen `20260820120000_evidence_item_content_hash_v2.sql` og oppryddingen rundt den
lukket:

- **Serialiseringen av `content_hash` på evidensfunn.** `concat_ws('|', …)` er byttet med
  den lengdeprefiksede kanoniseringen som allerede var husstandard i migrasjon 004 og 006,
  under nytt prefiks `sha256-v2`, og de eksisterende radene er rehashet.
  `280_content_hash_serialization_test.sql` gjenskaper den gamle kanoniseringen og påstår at
  de to fikstursradene faktisk kolliderte under den, slik at testen viser feilen den retter
  framfor bare å hevde at den er rettet.
- **`KNOWLEDGE_MODEL.md` §8 og §9.** Statuskolonnen er fjernet fra minimumsfeltene på både
  `Claim` og `ClaimRevision`, i favør av den avledede livssyklusen i
  `DATABASE_ARCHITECTURE.md` §15. Bare §8 var registrert som gjeld, men §9 stod i nøyaktig
  samme motstrid, og §15 navngir nettopp `claim_revisions.status`.
- **Tekstgjelden.** Kolonnekommentaren på `catalog.drugs.updated_at` navngir nå
  `catalog.set_row_timestamps()`, som faktisk finnes; testbeskrivelsene i `060` og `110`
  sier hvorfor det fortsatt ikke finnes RLS-policies, framfor å vise til migrasjon 005 som
  om den var ukommet; og enum-antallet i kommentarene til migrasjon 005 og 006 er rettet.
  Det riktige tallet er 35 etter 005 og 37 etter 006 — den registrerte gjelden oppga 37 for
  begge. Tallene er nå formulert som antallet *etter den migrasjonen*, som er en historisk
  kjensgjerning og ikke kan drive fra hverandre igjen.

Tre vaktposter kom til eller ble strammet, alle fordi fraværet av dem var grunnen til at
gjelden fikk ligge:

- **Hver kanonisk kolonne må påvirke fingeravtrykket.** Kanoniseringen tar hele raden som
  argument, men feltlisten er eksplisitt, så en kolonne som legges til senere blir ikke
  hashet av seg selv. Kontrollen er derfor kolonneuttømmende: den nuller ut én kolonne om
  gangen på en ferdig utfylt rad og krever at hashen endrer seg. Unntakslisten i testen er
  kontrakten for hva som bevisst står utenfor — blant annet `created_by_actor_id`, som kom
  til i migrasjon 005 uten å bli tatt inn i definisjonen.
- **En kommentar i de kanoniske schemaene kan ikke navngi en funksjon som ikke finnes.**
  Vakten er selv mutasjonstestet i `280`. En kommentar som skal peke framover på noe som
  ennå ikke finnes, skriver navnet uten parentes.
- **Vaktposten mot avslåtte triggere** i `200_workflow_immutability_test.sql` dekker nå både
  `D` og `R`, og også `api`. En trigger satt til replica fyrer ikke i vanlig drift, og et
  vern som ikke fyrer, er ikke et vern.

### 74.9 Hva migrasjon 007 innførte

`20260820140000_api_published_read_model.sql` åpner den første leseveien fra klientflaten
inn i kunnskapsbasen (§24): `api.published_drugs`, `api.published_claims` og
`api.published_claim_evidence`, de tretten `SELECT`-grantene viewene trenger, og de første
RLS-policyene i Antidep.

**Grensen flyttet seg, og måtte skrives om framfor å strykes.** Fram til nå hadde ingen
klientrolle noe privilegium i de kanoniske schemaene i det hele tatt, og fire testfiler
påstod nettopp det. Et `security_invoker`-view leser med kallerens rettigheter
(`DATABASE_ARCHITECTURE.md` §42), så granten er uunngåelig. Reglene er derfor gjort
snevrere, ikke fjernet: klientrollene kan ha `SELECT` og ingenting annet, hver `SELECT`
skal ha en policy under seg, og ingen policy i de kanoniske schemaene får åpne for annet
enn lesing. Alle tre håndheves uttømmende i `030_conventions_test.sql`.

**Tre lås, testet hver for seg.** Klientrollene mangler `usage` på de kanoniske schemaene
og kan derfor ikke navngi tabellene — granten virker bare gjennom viewene, som ble
navneoppslått da de ble opprettet. RLS slipper bare gjennom rader nådd fra en publisert,
ikke tilbaketrukket påstand. Og bare `SELECT` er gitt, bare til `anon` og `authenticated`.
`290_api_read_model_access_test.sql` publiserer sitt eget innhold inne i en transaksjon som
rulles tilbake, og leser deretter som faktisk klientrolle.

**Viewene bærer publiseringspredikatet i tillegg til RLS, og begge lagene testes alene.**
Det er bevisst dobbeltarbeid. Muteringstestingen viste hvorfor det ikke er nok å teste dem
sammen: da viewet ble endret til å følge høyeste revisjonsnummer framfor
publiseringspekeren, overlevde feilen alle assertions lest som `anon` — RLS skjulte
utkastrevisjonen, så også den feilaktige joinen landet på riktig rad. Bare en lesing som
eier, altså forbi RLS, fanget den. Den assertionen ble lagt til som følge av mutasjonen.
Tjuefire mutasjoner ble kjørt i alt; alle ble fanget etter dette.

**Policyene danner en asyklisk kjede.** `knowledge.claims` er selvstendig, og hver øvrige
policy spør bare om raden er nådd fra en rad som allerede er synlig — et `EXISTS` mot en
RLS-beskyttet tabell filtreres av den tabellens egen policy, så synligheten forplanter seg
gjennom `claims → claim_revisions → claim_evidence_links → evidence_items → sources` uten
at noen policy gjentar publiseringspredikatet. En syklus ville gitt «infinite recursion
detected in policy for relation» ved første spørring, ikke ved migrering.

**Lesbarhet og utgivelse er bevisst ulike predikater.** `catalog.drugs`-policyen slipper
gjennom virkestoff som er nevnt av en publisert revisjon eller et synlig evidensfunn, som
subjekt, komparator eller intervensjon — komparatorens navn må kunne leses for at påstanden
skal gi mening. `api.published_drugs` er snevrere og viser bare virkestoff Antidep faktisk
har publisert påstander *om*. En oppføring der ville ellers antydet en dekning som ikke
finnes.

**To NULL-tilstander holdes fra hverandre i `certainty_level`.** Verdien
`no_assessable_evidence` betyr at grunnlaget er vurdert og ikke lar seg gradere, med
`evidence_gap` utfylt. `NULL` betyr at ingen GRADE-vurdering gjelder for påstandstypen, og
forekommer hvis og bare hvis `knowledge_type` er `deterministic_fact` — publiseringsgaten
G10 krever vurdering for de to andre typene. Ingen av dem betyr lav risiko eller ingen
effekt (`ANTIDEP_CONSTITUTION.md` §6, §17), og skillet står i kolonnekommentaren.

**En tilbaketrukket ekstraksjon merkes framfor å skjules.** Publiseringsgaten G6 behandler en
tilbaketrukket ekstraksjon som en hard blokk ved publisering, men beslutningen er append-only og
kan registreres etterpå — og da flytter den verken publiseringspekeren eller evidenslenkene.
Lesemodellen avleder derfor den gjeldende tilstanden med nøyaktig samme regel som gaten bruker,
og eksponerer den som `extraction_withdrawn` på evidensraden og `withdrawn_evidence_count` på
påstanden. Funnet skjules ikke: da ville påstanden sett bedre underbygget ut enn den er.

Dette er den ene grunnen `workflow.review_decisions` er åpnet, og policyen slipper bare gjennom
`review_type = 'extraction_withdrawal'`. Begge utfallene må være lesbare, ikke bare
`extraction_withdrawn`: skjulte vi `extraction_upheld`, ville avledningen «siste beslutning
gjelder» svart forskjellig avhengig av hvem som spør. `workflow.user_roles` — autorisasjonskilden
— er fortsatt helt stengt.

**Identifikatorer aggregeres, de joines ikke.** `catalog.drug_identifiers` og
`knowledge.source_identifiers` er unike på `(identifier_system, identifier_value)`, ikke på
`(forelder, identifier_system)`. Ett virkestoff kan derfor ha flere ATC-koder, og ingenting
hindrer to DOI-er på samme kilde. Var identifikatorene joinet inn i viewene, ville ett
virkestoff blitt til to rader og ett evidensfunn til to — det siste ville fått ett funn til å
se ut som to uavhengige, altså nøyaktig den oppblåsingen av evidensmengden
`claim_evidence_links_revision_item_key` finnes for å hindre. ATC-kodene aggregeres derfor til
en array, og DOI og PMID hentes med skalare underspørringer som velger deterministisk.

Tre av punktene over kom fra reviewen på PR #18 og var reelle: at en tilbaketrukket ekstraksjon
forble synlig som ordinær evidens, at `source_doi`/`source_pmid` som skalarer var tapsbringende
— den ekte seedede DOI-en var faktisk den en «velg den laveste»-regel ville forkastet — og at
kildeversjonen manglet i drilldownen.

En vaktpost ble strammet underveis: kommentarvakten i `280` joinet `pg_description` mot tre
systemkataloger på `objoid` alene. OID-er er unike innenfor hver katalog, ikke på tvers, så
oppslaget kunne treffe en urelatert rad. Policykommentarene fra 007 er de første
kommentarene i Antidep-schemaene som verken beskriver en relasjon, en funksjon eller en
type, og gjorde svakheten nåbar. Hver gren binder nå sin egen `classoid`, og policyer er
tatt inn i vakten framfor å falle utenfor den.

### 74.10 Hva migrasjon 008 innførte

`20260821090000_audit_events.sql` oppretter `audit.events` (§25), vokabularet
`audit.event_operation`, og de to produsentene som gjør loggen til noe annet enn en tom
tabell.

**Sporvalget.** To spor var byggbare etter migrasjon 007: audit (§25) og det første
kliniker-UI-et (§30, PR I). Audit ble valgt fordi §25 selv begrunner rekkefølgen — audit
skal komme tidlig nok til at resten av admin-MVP-en bygges med sporbarhet fra starten — og
fordi kliniker-UI-et støter på en governance-beslutning med det samme: gjeldsposten om
publiserings- og reviewtidspunkt i `api` har nettopp det viewet som trigger, og krever
først en avgjørelse om hvor mye av reviewhistorikken som skal være offentlig. Audit har
ingen slik forutsetning.

Den avgjørelsen er nå tatt, og gjeldsposten innfridd i migrasjon 007a. Se §74.11.

**Auditloggen er et supplement, ikke et andre hjem for faglig historikk.**
`DATABASE_ARCHITECTURE.md` §35 er eksplisitt på det. Den kliniske historikken ligger
fortsatt i revisjonsmodellen og i `knowledge.publication_events`. Det loggen tilfører er
det tverrgående spørsmålet ingen av dem kan besvare: «hva gjorde denne aktøren, på tvers av
objekter og schemaer?» Derfor er raden ett smalt spor per operasjon, ikke en kopi av
innholdet.

**`object_id` har bevisst ingen fremmednøkkel, og det er migrasjonens ene avvik fra §37.**
Grunnen står i §36: fysisk sletting er reservert for feilopprettede objekter, personvernkrav
og administrativt vedlikehold, og «skal i så fall ha særskilt audit». En fremmednøkkel ville
gjort nettopp den auditen umulig — enten ville slettingen blitt blokkert av auditraden,
eller auditraden ville forsvunnet med objektet den dokumenterer. Auditraden bærer derfor et
snapshot framfor bare en peker, og `320_audit_operations_test.sql` demonstrerer egenskapen
ved faktisk å slette rolletildelingen og lese auditsporet etterpå. `actor_id` er derimot en
ekte fremmednøkkel med `RESTRICT`: der er ikke overlevelse spørsmålet, men at en aktør ikke
skal kunne slettes bort under sin egen historikk.

**Loggen daterer, den ordner ikke.** Et løpenummer ville vært den nærliggende måten å gi en
append-only logg en total orden. Den ville vært falsk, av samme grunn som §74.6 slo fast for
publisering: et løpenummer tildeles ved innsetting, ikke ved commit, så to transaksjoner kan
commite i motsatt rekkefølge av tildelingen, og en rullet tilbake transaksjon etterlater
hull. Rekkefølgespørsmål besvares der de har et svar — hendelseskjeden i
`knowledge.publication_events` og gyldighetsintervallene i `workflow.user_roles`.

**Objektpekeren er avledet, ikke oppgitt.** `object_schema` og `object_table` er genererte
kolonner over `operation`, etter samme mønster som `workflow.user_roles.scope_type` og
`knowledge.publication_events.object_type`. Kunne de oppgis uavhengig, kunne de komme i
utakt, og loggen ville kunnet påstå at en rolletildeling skjedde i `knowledge`. Begge er
`NOT NULL`, slik at en enum-verdi som legges til uten at `CASE`-uttrykket utvides feiler ved
innsetting framfor å gi en tom kolonne.

**Vokabularet er domenehandlinger, ikke DML-verb.** «update på `workflow.user_roles`»
forteller ikke den som gjennomgår loggen om en rettighet ble utvidet eller tilbakekalt, og
det er nettopp det spørsmålet loggen finnes for. Prisen er at hver ny auditert operasjon
krever en migrasjon. Det er en villet pris: en logg som stilltiende utvider seg til nye
operasjoner, utvider seg også til operasjoner ingen har tatt stilling til om skal auditeres.

**Produsentene er triggere, og de er bevisst ikke `SECURITY DEFINER`.** §60 navngir
«append-only audit» som en av de få legitime triggerbrukene, og grunnen er at en trigger
ikke kan glemmes av neste skrivevei — rolletildelinger har i dag ingen kontrollert funksjon
over seg i det hele tatt. At auditskriverne kjører med kallerens rettigheter er en
sikkerhetsbeslutning: en auditskriver som er mer privilegert enn operasjonen den
registrerer, er en vei til å skrive falske auditrader. Konsekvensen er at den som ikke kan
skrive auditraden heller ikke får registrert operasjonen. Det er riktig vei å feile, og det
testes med en rolle som får `INSERT` på `workflow.user_roles` og ingenting i `audit`.

**Loggen har ingen lesevei for klientroller.** §47 lister `audit` blant schemaene den
offentlige klinikerflaten aldri skal ha `SELECT` mot. Tabellen har derfor ingen grant, ingen
policy, ingen `usage` på schemaet, og `310_audit_access_test.sql` kontrollerer i tillegg at
ingen view i `api` leser fra den — grantene fra migrasjon 007 virker gjennom viewene, så et
slikt view ville vært en vei forbi alle tre lagene uten at noen grant på `audit.events` var
nødvendig.

**Vaktposten i `040_catalog_structure_test.sql` ble snevret, ikke fjernet.** Den påstod at
`audit` var tomt; den påstår nå at schemaet inneholder nøyaktig én relasjon. Et objekt som
sniker seg inn i `audit` uten en migrasjon som forklarer det, fanges fortsatt.

**Identiteten på en rolletildeling er tatt inn i frysevernet.** Auditloggen peker på
objektet sitt uten fremmednøkkel, og prisen for den friheten er at primærnøkkelen den peker
på må være stabil. For de andre auditerte objektene er den det allerede — `knowledge.claims`
er låst av `ON UPDATE RESTRICT` fra publiseringshendelsen i det øyeblikket det finnes en
auditrad å låse. `workflow.user_roles` har derimot ingen inngående fremmednøkler i det hele
tatt, og `workflow.freeze_role_grant()` fra migrasjon 005 frøs alt *om* tildelingen, men ikke
raden selv. En `UPDATE` som bare endret `id` passerte derfor både frysetriggeren og
auditrigeren, og etterlot rettigheten på en ny uuid uten en eneste auditrad mens
`role_granted` ble hengende på en uuid som ikke lenger fantes. Funnet kom fra en ekstern
review av PR #20, ble reprodusert mot databasen før det ble rettet, og er rettet i rota:
identiteten står nå først i vernet. Å auditere omnummereringen ville ikke løst noe — de gamle
auditradene ville fortsatt pekt på en rad som ikke finnes.

**Mutasjonstesting, og hva den avdekket.** Trettifire mutasjoner ble kjørt mot de nye
testene og mot tallvakten. Alle blir fanget nå, men tre gjorde det ikke i første omgang, og
alle tre av samme grunn: assertionen var *stille sann* framfor sann.

- En `is_empty` over en join mellom auditraden og publiseringshendelsen passerte også når
  joinen ikke traff i det hele tatt — altså nettopp når `occurred_at` var feil. Den er nå
  formulert som en telling.
- Kontrollen av at en uendret oppdatering ikke gir en auditrad kjørte ikke i det hele tatt
  under mutasjonen den skulle fange, fordi oppdateringen da feilet først. Den er nå pakket i
  `lives_ok`.
- Kontrollen av at en operasjon som ikke kan auditeres heller ikke kan utføres, bestod av to
  feil grunner etter hverandre: først fordi et aktøroppslag i testdataene traff
  `permission denied for schema provenance`, og deretter — etter at oppslaget var fjernet —
  fordi RLS på `workflow.user_roles` avviser skrivingen før triggeren i det hele tatt kjører.
  Testen åpner nå alle tre lagene inne i transaksjonen, slik at auditskrivingen er det
  eneste som gjenstår, og kontrollerer feilmeldingen og ikke bare SQLSTATE: `42501` alene
  skiller ikke «kunne ikke skrive auditraden» fra en hvilken som helst annen rettighetsfeil
  på veien.

Tallvakten ble mutert på ytterpunktene og ikke bare i midten (§74.9-lærdommen fra #19):
første ledd, siste ledd, forkortet påstand, ett ledd for langt, og en omformulering som
fjerner påstanden. Alle fem ble fanget.

---

# Del XIX — Ikke-forhandlingsbare implementeringsprinsipper

1. **Bygg vertikalt; ikke bygg hele databasen før første kliniske flyt.**
2. **Ingen masseinnholdsproduksjon før evidenspipelinen er kvalitetsmålt.**
3. **Admin-UI bygges tidlig nok til at innhold ikke blir kode.**
4. **Publiserte revisjoner er immutable.**
5. **Kliniker-UI leser publiserte projeksjoner, ikke redaksjonelle tabeller.**
6. **Samme Claim driver alle kliniske visninger.**
7. **Usikkerhet og fravær av evidens er eksplisitte datatilstander.**
8. **ClinicalRules er deterministiske, versjonerte og testede.**
9. **Unsupported kliniske scenarioer skal være tydelig unsupported, ikke improviseres av KI.**
10. **Agentroller følger least privilege og kan ikke selvpublisere høyrisikoinnhold.**
11. **Databaseintegritet håndheves i databasen der det er praktisk og korrekt.**
12. **Ingen pasientdatabase etableres som bivirkning av MVP-utviklingen.**
13. **Mobil, tilgjengelighet og evidensdrilldown testes før offentlig MVP.**
14. **Små, reviewbare PR-er er normal utviklingsenhet.**
15. **Styringsdokumentene er kontrakten; implementasjonen skal ikke gradvis definere et annet produkt.**

### 74.11 Hva migrasjon 007a innførte

`20260821143000_api_publication_timestamps.sql` innfrir gjeldsposten «Publiseringstidspunkt
og reviewtidspunkt er ikke eksponert i `api`» fra §74.7. Den oppretter ingen tabeller og
ingen data, og publiserer ingenting.

**Governance-beslutningen først, koden etterpå.** Gjeldsposten hadde «viewet som betjener
kliniker-UI-et» som trigger og en beslutning som forutsetning: hvor mye av reviewhistorikken
skal være offentlig? Avgjørelsen er den smaleste av de mulige — **kun tidsstempler**. Ingen
aktøridentitet, ingen beslutningstype, ingen begrunnelse. Den følger
`PRODUCT_INFORMATION_ARCHITECTURE.md` §58: klinikeren ser «sist faglig vurdert», ikke hvem
som vurderte eller hva som ble sagt underveis. At en påstand er publisert, er publisert
innhold; hvem som godkjente den, og hvorfor, er det ikke.

**Gjeldsposten den lukker.** Før 007a fikk en kliniker «sist faglig vurdert» bare gjennom
`last_assessed_at`, som kommer fra evidensvurderingen. Et `deterministic_fact` har per
konstruksjon ingen evidensvurdering (migrasjon 004 tillater den ikke) og sto derfor helt
uten dato. `last_reviewed_at` finnes for alle tre kunnskapstypene, fordi menneskelig
godkjenning kreves for alle tre (publiseringsgaten G11/G12).

**Utformingen er beslutningens viktigste konsekvens.** Den opplagte implementasjonen — en
RLS-policy som slipper gjennom publiseringsgodkjenningene, og et view som bare projiserer
`decided_at` — ville vært feil. Klientrollene har allerede et *tabellvidt* `SELECT`-grant på
`workflow.review_decisions` fra migrasjon 007, gitt for tilbaketrekkingssporet. En policy som
åpner raden, åpner den for hele granten, og reviewers identitet og begrunnelse ville ligget
ett view unna. **RLS er en radgrense, ikke en kolonnegrense.**

Godkjenningstidspunktet fryses derfor på publiseringshendelsen i stedet, av en
BEFORE INSERT-trigger som speiler gaten G11/G12: den gjeldende beslutningen er den siste, og
bare `approved` teller. Det er samme grep som `approved_evidence_set_digest` i migrasjon 006
— en avledet verdi databasen eier, låst til det den beskrev i øyeblikket. `review_decisions`
er ikke rørt, og godkjenningene er fortsatt utenfor klientflaten.

**Fire invarianter herfra:**

1. **Kolonnegrant er en reell fjerde lås.** Et `security_invoker`-view kan ikke projisere en
   kolonne kalleren mangler grant på, uansett hva viewet inneholder. Et policyuttrykk kan
   derimot fritt referere kolonner kalleren ikke har — privilegiene gjelder spørringen, ikke
   policyen — så radgrensen svekkes ikke av at granten er smal. `knowledge.publication_events`
   er åpnet på fire av fjorten kolonner; `reason` og `published_by_actor_id` er ikke blant dem.

2. **Et kolonnegrant er usynlig for `has_table_privilege()` og
   `information_schema.role_table_grants`.** En vaktpost som bare spør om tabellprivilegiet
   svarer «ingen tilgang» også når kolonner er åpnet. Assertionen i
   `270_publication_access_test.sql` som påsto at publiseringshistorikken var utilgjengelig,
   ble derfor *stille sann* i det 007a ga granten, uten å feile. Den kontrollerer nå
   `role_column_grants` i tillegg, uttømmende. Dette er samme feilmodus som §74.10 beskrev
   for `is_empty` over en join: en assertion kan bestå uten å nå det den påstår å måle.

3. **`published_at` og `last_reviewed_at` er to forskjellige ting, og begge er forskjellige
   fra `revision_created_at` og `last_assessed_at`.** Fire tidsbegreper, holdt adskilt som
   `DATABASE_ARCHITECTURE.md` §7.3 krever. NULL i noen av dem betyr ukjent, aldri «nylig
   vurdert» og aldri «ikke vurdert».

4. **Innenfor én transaksjon kan hendelser ikke skilles på tid, og en uuid er ingen
   rekkefølge.** `published_at` og `created_at` er begge `now()`, altså transaksjonens
   starttidspunkt (§74.6). Skjer publisering, avpublisering, ny godkjenning og
   republisering i samme transaksjon, er de to publiseringshendelsene identiske på tid,
   men bærer ulik `approval_decided_at`. En `order by ... id desc` faller da tilbake på en
   tilfeldig uuid og plukket den gamle godkjenningen i 94 av 200 forsøk. Feilen ble funnet
   av den eksterne reviewen på PR #21, etter at CI hadde vært grønn — den ville vært en
   flakete CI-feil, ikke en stabil. Lesemodellen aggregerer derfor med `max()`, som er
   korrekt fordi begge kolonnene er monotont ikke-avtagende: `published_at` kan ikke gå
   bakover, og `approval_decided_at` velges blant append-only beslutninger, så maksimum
   kan bare stige. **Forgjengerkjeden kunne besvart det eksakt, men ikke bak RLS:** et
   «finnes ingen etterfølger»-predikat evalueres over de radene kalleren *ser*, og en
   skjult etterfølger ville fått en tidligere hendelse til å framstå som kjedens hale.
   Den som senere trenger «siste hendelse» under RLS må regne med det.

5. **Verdien er frosset, og det er et valg med utløpsdato.** En senere reviewbeslutning på
   samme revisjon flytter den ikke. I dag er det riktig, fordi det ikke finnes noen
   reviewsyklus å flytte den med. Migrasjonen som innfører `review_due_at` må ta stilling til
   om en fornyet godkjenning skal oppdatere datoen; posten står i §74.7.

**Sporet som nå er åpent.** Med gjeldsposten innfridd har det første kliniker-UI-et (§30,
PR I) ingen gjenstående forutsetning i databasen. Viewene svarer fortsatt `[]` til noe er
publisert, så UI-et må bygges mot en tom projeksjon og behandle den som en førsteklasses
tilstand: «ingen data», «ingen vurderbar evidens» og «lav risiko» skal se forskjellige ut
(`ANTIDEP_CONSTITUTION.md` §6, §17).

### 74.12 Hva lesemodellklienten innførte

`feat: add published read model client` er den første appkoden siden bootstrap (PR A) og
første del av PR I (§30, §68). Den oppretter ingen migrasjon, ingen komponenter og ingen
ruting, og leser ingenting i seg selv: viewene svarer fortsatt `[]`.

Den består av radtypene for de tre api-viewene (`src/types/api.ts`), `Database`-typen
supabase-js parametriseres med (`src/types/database.ts`), klienten (`src/lib/supabase.ts`),
de tre lesefunksjonene (`src/lib/published-read-model.ts`) og avledningen av sikkerhetsgrad
(`src/lib/claim-certainty.ts`).

**Fem beslutninger, i den rekkefølgen de betyr noe klinisk:**

1. **Tomt er en egen tilstand, ikke en tom liste.** Lesefunksjonene returnerer en lukket
   union `ok | empty | error` der `ok` per konstruksjon aldri har null rader. En kaller kan
   ikke rendre et tomt sett som en liste uten først å ha tatt stilling til `empty`, og en
   feil kan ikke forsvinne i den samme tomme listen. Det er den strukturelle formen av
   kravet om at «ingen data» aldri skal se ut som «lav risiko» (`ANTIDEP_CONSTITUTION.md`
   §6, §17), og den gjelder fra første komponent i neste PR.

2. **De to NULL-lignende sikkerhetstilstandene er skilt i én avledning.**
   `describeClaimCertainty()` gir `graded`, `no_assessable_evidence`,
   `not_applicable_deterministic_fact` eller `unknown`. En klient som forgrener direkte på
   `certainty_level` gjør de to første usynlige for hverandre ved første `if (!level)`.
   `unknown` dekker fire kontraktsbrudd — en ukjent kunnskapstype, en evidenssyntese uten
   vurdering, en verdi utenfor vokabularet, og et deterministisk faktum som likevel bærer en
   gradering — og ingen av de fire tilstandene kan renderes som en lav gradering.
   Kunnskapstypen kontrolleres først og på alle veier: den avgjør hvilken sikkerhetstilstand
   som er gyldig, så en fjerde epistemisk kategori med en tilsynelatende gyldig gradering
   skal ikke passere som en ordinær GRADE-vurdert påstand. Den første utformingen kontrollerte
   den bare på NULL-veien; det ble funnet av den eksterne reviewen på PR #22 og er rettet der.

3. **Lukket vokabular bare der klienten forgrener, og med kjøretidskontroll.** Enum-verdiene
   er tekst i kontrakten (§74.5 punkt 1), så en TypeScript-union er en påstand om databasen
   som ingenting håndhever. Linjen er trukket etter klinisk konsekvens: kunnskapstype,
   sikkerhetsgrad, relasjonstype, `*_availability` og kildestatus er lukkede unioner; resten
   er dokumentert `string`, og promoteres av den PR-en som faktisk forgrener på dem. Gjelden
   som følger, står i §74.7.

4. **Evidensen sorteres bevisst nøytralt.** En rekkefølge etter `relationship_type` ville
   satt støttende funn først og gjort presentasjonsrekkefølgen til en vekting av evidensen.
   Motstridende funn skal stå side om side med støttende (§9), så api-laget sorterer bare
   på lenkens id — stabilt mellom kall, uten mening — og overlater rekkefølgen i
   klinikerflaten til visningen, der den er en designbeslutning.

5. **Nøkkelvakten er positiv, ikke en svarteliste.** `assertPublishableKey()` avviser alt
   annet enn `anon` og `authenticated`, ikke bare `service_role`, slik at en framtidig
   privilegert rolle ikke slipper gjennom fordi den ikke var navngitt. Vakten er et
   supplement til at hemmeligheter aldri legges i repoet (`DATABASE_ARCHITECTURE.md` §49),
   ikke en lås; den fanger den dagen noen kopierer feil verdi inn i `.env.local`. Klienten
   er dessuten bundet til `api`, slik at et forsøk på å navngi en kanonisk tabell blir en
   typefeil framfor et 404 i produksjon.

**En stille feilmodus ble truffet under arbeidet, og fanges nå.** supabase-js forkaster en
`Database`-type som ikke oppfyller formen sin — uten feilmelding — og gir da `never` som
radtype. `never` er tilordnbart til alt, så typecheck og tester fortsetter å passere mens
spørringene ikke lenger er typet. To skrivemåter utløser det: en Row deklarert som
`interface` (uten implisitt indekssignatur) og tomme oppslag skrevet som
`Record<string, never>` (som slår ut radtypen til hvert view gjennom snittet
`Tables & Views`). Begge er prøvd mot kompilatoren, ikke antatt, og
`src/lib/published-read-model.test.ts` bærer en kompileringsvakt som gir typefeil hvis
radtypen kollapser igjen. Vakten håndheves av `npm run typecheck`, ikke av vitest, som
fjerner typene — det står i filen, slik at ingen tror testkjøringen dekker den. Dette er
samme kategori som den stille sanne assertionen i §74.11 punkt 2: en kontroll kan slutte å
måle uten å feile.

**Hva som gjenstår av PR I.** Ruting, legemiddelside, claim-komponent, «Hvorfor sier Antidep
dette?» og kildedetalj (§30). Avhengighetsvalgene for ruting og server-state (§7) er ikke
tatt, fordi denne delen ikke trenger dem. Klinikerflaten må bygges mot den tomme
projeksjonen og behandle den som en førsteklasses tilstand — §74.11 sist.

### 74.13 Hva claim-kortet innførte

`feat: add claim card and certainty display` er andre del av PR I (§30, §68) og den første
klinikerflaten. Den oppretter ingen migrasjon, ingen ruting og ingen datahenting, og legger
ingen ny avhengighet til: avhengighetsvalgene i §7 for ruting og server-state er fortsatt
ikke tatt, fordi rene presentasjonskomponenter ikke trenger dem.

Den består av presentasjonsenheten for én publisert påstand
(`src/components/ClaimCard.tsx`), sikkerhetsvisningen (`src/components/ClaimCertainty.tsx`),
avledningen av påstandens strukturerte betydning (`src/lib/claim-effect.ts`) og norsk
gjengivelse av intervaller, tidsstempler og tall (`src/lib/norwegian-format.ts`). Fire
vokabularer er lukket i `src/types/api.ts`, og `tests/api-vocabularies.test.ts` kontrollerer
alle de lukkede vokabularene mot migrasjonene.

**Fem beslutninger, i den rekkefølgen de betyr noe klinisk:**

1. **«Ikke aktuelt» og «mangler» er forskjellige ting, og kunnskapstypen avgjør hvilken.** Et
   deterministisk faktum — et handelsnavn, en legemiddelform — har ingen retning og ingen
   effektstørrelse. Å skrive «størrelsen er ikke tallfestet, og det betyr ikke at effekten er
   null» på «finnes som tablett 50 mg» er en kategorifeil som låner faktumet en epistemisk
   ramme det ikke har (`ANTIDEP_CONSTITUTION.md` §5). De to aksene utelates derfor for et
   deterministisk faktum — men bare når de faktisk er tomme; bærer faktumet likevel en
   retning eller en størrelse, er det noe å vise. Det er samme skille som
   `not_applicable_deterministic_fact` gjør på sikkerhetsaksen. For de to andre
   kunnskapstypene gjelder det motsatte: der er en manglende tallfesting informasjon, og
   stillhet ville vært §17-feilen. Dette ble funnet ved å se på gjengivelsen i nettleseren,
   ikke av en test.

2. **Effektmål og komparator er én påstand, og et uforenlig par tolkes ikke.**
   `comparator_kind = 'none'` betyr ikke «komparator mangler»; migrasjon 004 sier at det betyr
   *en endring fra behandlingsstart*. Det er en påstand om hva tallet måler, og den må stemme
   med effektmålet: `mean_change` måler innenfor én arm, mens `mean_difference`, SMD, RR og OR
   måler mellom to. «Gjennomsnittsforskjell 1,7 kg» med `none` har ingen gruppe å være
   forskjellig fra, og å presentere den som «endring fra behandlingsstart» ville gitt et
   kontraktsbrudd en plausibel, men gal klinisk betydning. Størrelsen avledes derfor med
   komparatoren i hånden, og et uforenlig par kan ikke bli `quantified`: tallet er
   utilgjengelig for visningen framfor å måtte huskes skjult av den. Kontrastiv er
   komplementet til innenfor-arm, ikke en egen liste, så et sjette effektmål krever komparator
   til noen tar stilling til det. Tre tilstander holdes fra hverandre, fordi de krever hver sin
   retting: en gyldig `none` der målet faktisk beskriver endring fra baseline, en komparator
   som selv er brutt, og et par der hvert felt er gyldig men kombinasjonen ikke er det. Hvert
   kontraktsbrudd på størrelsen gir sin egen forklaring framfor et tall.

3. **Ingen skala, og ingen fargeramme over graderingene.** §17 navngir «en tom skala» som
   nettopp det mønsteret som får manglende data til å se ut som lav risiko: en firetrinns
   indikator ville tvunget «ingen vurderbar evidens» og «ukjent sikkerhet» inn på samme akse
   som «svært lav», som et trinn under framfor som noe annet. Teksten bærer betydningen (§20),
   og en visuell skala hører først hjemme når hvert trinn har en definert semantikk å vise
   (§18). «Traffic-light medicine» er dessuten et eksplisitt antimønster (§65), og høy
   sikkerhet i kunnskapsgrunnlaget er ikke et grønt lys — den sier ingenting om hvor gunstig
   funnet er. De ikke-graderte tilstandene skiller seg strukturelt: de bærer ingen
   `data-certainty-level`, og stilsettet henger den graderte drakten på nettopp det
   attributtet, så en ny ikke-gradert tilstand kan ikke arve utseendet til en gradering.

4. **Veien til evidensen er påkrevd, og den er en lenke.** `evidenceHref` er ikke valgfri:
   produktinvariant 9 sier at brukeren alltid skal finne «Hvorfor sier Antidep dette?», og et
   valgfritt felt ville gjort det til noe en kaller kan glemme. At det er en lenke og ikke en
   handling, gjør evidensvisningen delbar og bokmerkbar (§55). URL-en eies av rutingen, ikke
   av kortet, så evidensvisningen kan bygges uten å endre kortet.

5. **Fire vokabularer lukket, alle med kjøretidskontroll.** `claim_direction`,
   `comparator_kind`, `effect_measure` og `estimate_unit` forgrenes det nå på, og regelen fra
   §74.12 punkt 3 er at den PR-en som forgrener, legger til kontrollen samtidig. Påstandens
   `direction` er bevisst ikke evidensfunnets `reported_direction`: det vokabularet har den
   fjerde verdien `not_stated`, og å slå dem sammen ville latt «kilden oppgir ingen retning»
   og «Antidep konkluderer med ingen klar forskjell» bytte plass. `relationship_type`,
   `*_availability` og `source_status` står fortsatt uten kontroll, fordi ingenting forgrener
   på dem ennå.

**Gjeld: én halvpart innfridd, én post lagt til.** `tests/api-vocabularies.test.ts` leser de
versjonerte migrasjonene og krever at hver lukket union i `src/types/api.ts` er nøyaktig sin
enum, og i tillegg at skillet mellom dimensjonale og dimensjonsløse effektmål er det samme som
`claim_revisions_magnitude_unit_check`. Uthentingen leser ikke bare `create type`: en senere
`alter type … add value` eller `rename value` regnes med, og en endringsform testen ikke kan
tolke stopper den framfor å bli ignorert. Uten det ville vaktposten sluttet å måle første gang
et enum ble utvidet — den ville passert mens databasen kunne returnere en verdi unionen ikke
kjenner. Ingen migrasjon bruker `alter type` i dag; kodeveien er derfor prøvd mot syntetisk
SQL, slik at den virker den dagen den trengs. Ingen database trengs; framgangsmåten er den samme som
i `tests/data-api-exposure.test.ts`. Kolonnenavn, nullbarhet og kolonnetyper står fortsatt
ukontrollert, og gjeldsposten i §74.7 er strammet inn til det. Den nye posten er databasens
manglende binding mellom effektmål og komparator.

**Serialiseringen av `interval` er kontrollert, ikke antatt.** PostgREST gir PostgreSQLs egen
tekstform, og Supabase kjører med standardinnstillingen `IntervalStyle = postgres`. Formene er
lest ut av en PostgreSQL 16-instans: `interval '8 weeks'` blir `56 days`, `'3 months'` blir
`3 mons`, `'18 months'` blir `1 year 6 mons`, og `to_json()` gir samme streng som `::text`.
Uker overlever altså ikke, og de regnes ikke tilbake: enheten databasen faktisk bærer er den
som vises. Alt som ikke passer formen — ISO 8601 fra en annen `IntervalStyle`, eller et
negativt intervall — gjengis uendret framfor å tolkes på slump.

**Tre kombinasjonsfeil funnet i sluttgjennomgangen.** Alle tre er samme type: hvert felt er
gyldig for seg, mens paret betyr noe annet enn delene. De ble ikke funnet av mutasjonstesting,
fordi mutasjonene traff koden og ikke antakelsen om at feltene kunne vurderes hver for seg.

1. **`mean_difference` med `comparator_kind = 'none'`.** Kortet skrev
   «Gjennomsnittsforskjell 1,7 kg. Ingen komparator: endring fra behandlingsstart.»
   Den siste setningen er en gyldig lesning av `mean_change + none`, men en helt annen
   påstand for `mean_difference + none` — presentasjonslaget reparerte altså et
   kontraktsbrudd ved å gi det en plausibel, men gal klinisk betydning. Rettet ved at
   størrelsen avledes med komparatoren i hånden (punkt 2 over), og at baselinelesningen
   bare skrives ut når målet lisensierer den.

2. **Tallfestet effekt sammen med `no_assessable_evidence`.** Migrasjon 004 sier at den
   tilstanden betyr at det ikke finnes tilstrekkelig grunnlag til å gjøre en vurdering i det
   hele tatt, og kolonnekommentaren på `magnitude_value` sier selv at en påstand som er mer
   presis enn evidensen under den, er et brudd på `ANTIDEP_CONSTITUTION.md` §4 og §6. Kortet
   viste likevel punktestimatet ved siden av «Ingen vurderbar evidens». Tallet skjules nå, med
   begrunnelsen synlig. Avgrenset til den vurderte tilstanden: `unknown` dekker blant annet en
   kunnskapstype Antidep ikke kjenner, og da er det sikkerhetsvisningen som sier fra.

3. **Deterministisk faktum som likevel bærer retning eller størrelse.** §74.13 punkt 1 utelot
   de to aksene når de er tomme, men viste dem umerket når de ikke er det — og da så en verdi
   som ikke gjelder for kunnskapstypen nøyaktig ut som en som gjør det (§5). Verdien står
   fortsatt, siden det å skjule den ville skjult bruddet, men den er nå merket. Parallellen på
   sikkerhetsaksen er `assessment_on_deterministic_fact`.

**En kontroll ble vurdert og bevisst ikke innført.** Fortegnet på en effektstørrelse kan se ut
til å motsi påstandens retning — `increase` med −0,4 — men modellen registrerer ikke om den
positive retningen på skalaen `magnitude_unit` måler i, peker samme vei som temaet påstanden
handler om. «Økning i vekttap» med en negativ vektforskjell er konsistent, så en fortegnsregel
ville gitt falske utslag på gyldige data. Registrert som gjeld i §74.7 framfor implementert.

**Forsvaret i visningen lukker ikke databaseinvarianten.** Databasen tillater fortsatt begge
kombinasjonene, en redaktør kan skrive dem, og enhver annen leser av `api` ser dem rå. De to
lagene er registrert hver for seg i §74.7.

**Hva som ble verifisert.** 46 mutasjoner ble innført én om gangen og alle fanget: 23 mot
kortet, sikkerhetsvisningen, avledningen og formateringen, ti mot vaktposten på vokabularene,
og tretten mot kombinasjonsreglene over. Én mutasjon overlevde først, og var et funn i seg
selv: `baselineReadingIsLicensed()` kalte `isWithinArmMeasure()` i en gren som avledningen
allerede hadde gjort uoppnåelig. En uprøvbar vakt ser ut som et vern uten å være det, så
grenen ble fjernet framfor at mutasjonen ble notert som et unntak. Typene ble sondert framfor antatt — en tilordning av en verdi utenfor hvert nytt
vokabular gir fire typefeil, og kollapsvakten fra §74.12 slår fortsatt ut når en radtype
skrives om til `interface`. Kortet ble kjørt i Chromium på 1280 og på en ekte 390 px
mobilviewport gjennom devtools-protokollen, fordi `--window-size` klemmes til minst 500 px og
en skjermdump alene ville sett ut som avkuttet tekst uten å være det: ingen horisontal
overflyt, og ingen konsollmeldinger utover en manglende favicon på den midlertidige
forhåndsvisningssiden. En vitest-kontroll fanger dessuten `console.error` fra React på flere
varianter av kortet.

**Hva som gjenstår av PR I.** Ruting, legemiddelsidene `/drugs/sertralin` og
`/drugs/mirtazapin`, temasiden for vekt, evidensvisningen bak «Hvorfor sier Antidep dette?» og
kildedetaljen (§30). Evidensvisningen er en egen PR (§51). Avhengighetsvalgene for ruting og
server-state (§7) hører til den PR-en som først trenger dem. Viewene svarer fortsatt `[]`, så
den første siden må behandle den tomme projeksjonen som en førsteklasses tilstand — `ok` i
lesemodellen har per konstruksjon aldri null rader, nettopp for å tvinge det fram (§74.12
punkt 1).

### 74.14 Hva rutingen og de første sidene innførte

`feat: add routing and first clinician pages` er tredje del av PR I (§30, §68) og den første
navigerbare klinikerflaten. Den oppretter ingen migrasjon. Den består av adressene
(`src/app/routes.ts`), sluggavledningen (`src/lib/slug.ts`), klienttilstanden
(`src/app/antidep-client.ts`), hentingen (`src/app/use-read-model.ts`), fraværs- og
feiltilstandene (`src/components/KnowledgeNotice.tsx`), grupperingen
(`src/app/ClaimGroups.tsx`) og fem sider: forsiden, legemiddelsiden, temasiden, den ennå
ubygde evidensvisningen og en side for ukjent adresse.

**Avhengighetsvalgene i §7 er tatt, og det ene av dem er å la være.**

1. **Ruting: `react-router`, i deklarativ modus.** Én transitiv avhengighet (`cookie-es`), og
   den etablerte standarden. Alternativet — en håndskrevet ruter på History API-et — ville
   spart avhengigheten og kostet nettopp de detaljene en ruter finnes for: at ctrl-, cmd- og
   midtklikk fortsatt åpner i ny fane, at `popstate` og nettleserens fram/tilbake virker, og
   at eksterne lenker ikke fanges. Det er en klasse feil som ser ut som ingenting til den
   dagen den ikke gjør det. Data-modusen (`createBrowserRouter`, loaders) er bevisst ikke tatt
   i bruk: den ville innført et server-state-mønster gjennom bakdøren. Avhengigheten hevet
   dessuten Node-gulvet, og avdekket at `engines.node` allerede var usann: `jsdom` krever
   `^22.22.2`, mens roten erklærte `>=22`, og `npm ci` nøyde seg med en advarsel. Gulvet er
   rettet til det laveste treet faktisk tilfredsstiller, og `.npmrc` gjør avviket til en feil
   framfor en advarsel — en erklæring ingenting håndhever, er den formen for påstand §74.8
   handler om.
2. **Server-state: ingen avhengighet.** §7 ber om at kategorien utsettes til behovet er
   demonstrert. Flaten har tre lesespørringer, ingen mutasjoner, ingen invalidering og ingen
   bakgrunnsoppfriskning. `useReadModel()` er en effekt og en tilstand, og legger nøyaktig én
   ting til lesemodellens tre: at svaret ikke er kommet ennå.
3. **Dypelenker krever en omskrivingsregel på verten.** `vercel.json` sender alle stier til
   `index.html`. Uten den ville `/drugs/sertralin` gitt 404 ved direkte åpning og ved
   oppdatering — altså ville dypelenken virket overalt unntatt der §55 faktisk krever den.
   Regelen ligger i repoet framfor i prosjektinnstillingene hos Vercel, i tråd med §54.

**Fem beslutninger, i den rekkefølgen de betyr noe klinisk:**

1. **Fem tomme skjermer, fem forskjellige utsagn.** En side som leser publisert kunnskap kan
   ende uten innhold av fem grunner, og de betyr ikke det samme: spørringen laster; Antidep
   har ikke publisert noe i det hele tatt; adressen traff ikke noe publisert; adressen er
   tvetydig; spørringen feilet. Alle fem ville vært samme blanke flate, og en blank flate
   leses som «ingenting å bekymre seg for». Hver av dem har derfor sin egen ordlyd, og de
   tre fraværstilstandene bærer den samme setningen om at fravær i Antidep ikke er
   dokumentasjon på fravær av effekt, bivirkning eller risiko (`ANTIDEP_CONSTITUTION.md` §17,
   `PRODUCT_INFORMATION_ARCHITECTURE.md` §32, §65 «No-data-as-zero»). Setningen står ett sted,
   i `KnowledgeNotice.tsx`, fordi den skrevet på nytt per side ville drevet fra hverandre.
   «Laster» er skilt fra «tomt» strukturelt og ikke bare i tekst: `useReadModel()` starter i
   `loading`, og et svar kan ikke vises som en tom liste (§74.12 punkt 1).

2. **En tom projeksjon sier ingenting om virkestoffet i adressen.** `/drugs/sertralin` mot et
   tomt `api.published_drugs` betyr at Antidep ikke har publisert noe — ikke at virkestoffet
   er ukjent, og slett ikke at det er uten risiko. De to utsagnene er skilt: den tomme
   projeksjonen sier «om noe virkestoff», og et treff som mangler sier eksplisitt at det er et
   utsagn om Antideps innhold og ikke om virkestoffet. Overskriften er dessuten aldri sluggen
   fra URL-en; å sette den ville gjort en adresse leseren skrev, til noe Antidep ser ut til å
   hevde.

3. **Adressen er avledet av navnet, og tvetydighet er en tilstand.** `api` eksponerer ingen
   slug (§74.5 punkt 2), så `/drugs/sertralin` finnes ved å avlede sluggen av hvert kanonisk
   navn i det publiserte settet. Avledningen er tapsgivende — norske bokstaver skrives om, så
   to navn kan kollidere — og et oppslag som velger det første treffer riktig nesten alltid og
   viser feil virkestoff resten av tiden. Det siste er en feil som ser ut som et gyldig svar,
   så oppslaget svarer `ambiguous` og siden sier fra. Påstandens identitet er ikke berørt:
   evidensvisningen adresseres med `claim_id`, som overlever en ny publisering.

4. **Rekkefølge er ikke rangering, og to påstander ved siden av hverandre er ikke en
   sammenligning.** «UI-derived recommendations» er et eksplisitt antimønster (§65), og
   invariant 14 sier at visuell orden ikke skal bli en anbefaling ved en tilfeldighet. En
   temaside med to virkestoff under samme overskrift *er* en ordnet liste, og leseren fyller
   inn en mening hvis vi ikke oppgir den. Rekkefølgen er derfor alfabetisk, sorteringen gjøres
   i visningen framfor å arves fra spørringen — `order by` i PostgreSQL bruker databasens
   kollasjon, som ikke er norsk, så en visning som *sier* at rekkefølgen er alfabetisk må selv
   gjøre den alfabetisk — og begge deler skrives ut. En liste bærer dessuten to påstander på én
   gang: rekkefølgen, og at dette er settet. Den andre er den farligste her, fordi to virkestoff
   under et tema leses som at de øvrige ikke har temaet, så begge listene sier hva de er: det
   Antidep har publisert, ikke et fullstendig sett. Temasiden sier i tillegg at påstandene
   ikke er en sammenligning: de kan ha ulik populasjon, ulik komparator og ulik tidsramme, og
   sammenligning er en egen visning med egen semantikk (§21-§24, §29). Kollasjonen er norsk og
   ikke tegnverdi, av samme grunn: en liste en norsk leser leser som usortert, ser ut som en
   liste sortert etter noe annet — for eksempel etter viktighet.

5. **Dokumentstrukturen er en klinisk egenskap, ikke pynt.** Kortet rendret `h3` da det stod
   alene; en side har nå `h2` og gruppene `h3`, så kortet fikk `headingLevel` og ligger på
   `h4` under gruppen sin. Et hopp i nivå gir feil disposisjon for en skjermleser (§50, §53).
   Fokus flyttes til hovedområdet ved hver navigering, men ikke ved første render, fordi en
   klientside-navigering ellers etterlater en skjermleser i forrige side. Hopplenken er
   første fokuserbare element (§49, §52), og dokumenttittelen settes per adresse, slik at et
   bokmerke og en delt lenke har et navn (§55, §57).

**Det som ikke vises, og hvorfor.** Handelsnavn, klasse, norske legemiddelformer og styrker
(§10) finnes ikke i datamodellen ennå og kommer med DrugProduct-fundamentet (§26) og slice 4
(§32); de er utelatt framfor gjettet på. Katalogstatusen på virkestoffet er utelatt av en
annen grunn: kolonnen beskriver Antideps forvaltning og ikke markedsstatus i Norge, og
«aktiv» ved siden av et virkestoffnavn ville blitt lest som det siste. Begge er registrert i
§74.7, den siste som gjeld.

**Evidensadressen finnes, men visningen gjør det ikke.** `/claims/:claimId/evidence` er
registrert som rute og svarer med en side som sier at visningen ikke er bygget. Uten ruten
ville lenken fra hvert kort gitt «siden finnes ikke», som ikke er sant — adressen er riktig,
innholdet mangler. **Produktinvariant 9 er dermed ikke innfridd ennå.** Det er ikke gjeld,
men gjenstående arbeid: evidensvisningen er den neste PR-en (§51).

**Gjeld: tre poster lagt til.** Adressen til et katalogobjekt er avledet av visningsnavnet og
ikke lagret; temasiden laster hele det publiserte settet fordi `api` ikke har noen
temaprojeksjon; katalogstatusen vises ikke. Alle tre står i §74.7 med sin egen trigger. Den
første er den samme avveiningen §74.5 punkt 2 utsatte — utsettelsen er nå gjeld, fordi
behovet den ventet på har meldt seg.

**Vaktposten på PR-tabellen.** §74.2 sin statuskolonne har vært foreldet ved fire
sesjonsstarter på rad. `scripts/verify-counts.sh` kontrollerer nå at hver rad unntatt den
nyeste står som `merget`, og at hver `merget`-rad har sin commit i git-historikken. Den
nyeste raden er unntatt fordi en PR ikke kan kjenne sin egen mergestatus; kontrollen slår
derfor ut i det øyeblikket noen legger til raden under en foreldet rad — som er nøyaktig når
forsømmelsen skjer. CI-jobben henter hele historikken for at den andre halvdelen skal kunne
måle; en avkortet historikk gir feilmelding framfor stillhet.

**Hva som ble verifisert.** `npm run lint`, `npm run format:check`, `npm run typecheck`,
`npm run test` og `npm run build` er kjørt og passerer, sammen med
`./scripts/verify-counts.sh`. Vitest-suiten er utvidet med sider, ruting, sluggavledning,
hentetilstander og gruppering. Mutasjonstesting er kjørt etter mønsteret i §74.13: hver ny
regel er fjernet én om gangen, og testen som påstår å teste den, er kontrollert å feile.
Flaten er kjørt i Chromium på 1280 px og på en ekte 390 px mobilviewport gjennom
devtools-protokollen — ikke gjennom `--window-size`, som klemmes til minst 500 px — uten
horisontal overflyt og uten konsollmeldinger utover en manglende favicon.

**Hva som gjenstår av PR I.** Evidensvisningen bak «Hvorfor sier Antidep dette?» og
kildedetaljen (§30). Evidensvisningen er en egen PR (§51), og kildesiden er en annen visning
enn evidensvisningen (§42). Viewene svarer fortsatt `[]`, så begge må bygges mot den tomme
projeksjonen på samme måte som sidene her. Det som gjenstår for at slice 2 skal være ferdig,
er dermed nøyaktig de to punktene i definition of done som handler om evidens og kilde.

### 74.15 Hva evidensvisningen innførte

`feat: add the claim evidence view` er fjerde del av PR I (§30, §68) og svaret bak «Hvorfor
sier Antidep dette?» (`PRODUCT_INFORMATION_ARCHITECTURE.md` §15). Den oppretter ingen
migrasjon og legger ingen ny avhengighet til. Den består av avledningen av ett evidensfunn
(`src/lib/evidence-item.ts`), presentasjonen av det (`src/components/EvidenceFinding.tsx`),
selve siden (`src/app/pages/ClaimEvidencePage.tsx`, som til nå har vært en plassholder), en
ny lesefunksjon (`fetchPublishedClaimById()`) og de delte vokabularetikettene
(`src/components/vocabulary-labels.ts`).

**`fetchPublishedClaimEvidence()` ble skrevet og testet i #22 og har aldri vært kalt. Nå
kalles den.** Ruten `/claims/:claimId/evidence` og `claimEvidencePath()` kom i #24; adressen
er uendret.

**Sju beslutninger, i den rekkefølgen de betyr noe klinisk:**

1. **Påstanden står øverst, og det er det samme kortet.** §41 begynner med påstanden, og uten
   den er et evidensgrunnlag ikke etterprøvbart: leseren har ingenting å prøve funnene mot
   (`ANTIDEP_CONSTITUTION.md` §4). Evidensradene bærer verken `statement`, `certainty_level`,
   `uncertainty_summary` eller `topic_label`, så påstanden hentes med `fetchPublishedClaimById()`
   — filtrert på `claim_id`, som overlever en ny publisering (§7). `ClaimCard` gjenbrukes
   framfor å få en egen utgave her: kortet bærer regler om scope, størrelse, komparator og
   sikkerhet som en parallell presentasjon ville måttet gjenta og deretter drive fra
   (§65 «Duplicated truth»). Kortets `evidenceHref` er påkrevd og forblir det; på denne
   siden *er* veien videre seksjonen lenger nede, så verdien er et anker og ikke en rute. Å
   gjøre lenken valgfri ville latt et kort et annet sted miste den ved en forglemmelse.

2. **Rekkefølgen er ikke en vekting, og antallet er ikke sikkerhet.** Evidensen kommer sortert
   på `claim_evidence_link_id` — stabilt mellom kall, uten mening (§74.12 punkt 4) — og
   visningen sorterer ikke om. Den grupperer heller ikke støttende og motstridende i egne
   bolker slik §41 foreslår, av to grunner: en rekkefølge etter `relationship_type` ville satt
   støttende funn først og gjort presentasjonsrekkefølgen til en vekting av evidensen
   (`ANTIDEP_CONSTITUTION.md` §9, §20), og en egen bolk for motstridende evidens som står tom,
   leses som «det finnes ingen motstridende evidens» — en påstand om forskningen, ikke om
   Antideps innhold. Hvert funn bærer i stedet relasjonen sin som tekst, øverst og i sitt eget
   tilgjengelige navn, slik at leseren ser den uten å utlede den av plasseringen. Antallet funn
   skrives ikke ut som et tall å veie: «tre støtter, ett motsier» er stemmetelling, og GRADE
   avviser den eksplisitt — sikkerheten i kunnskapsgrunnlaget er en egen vurdering, og den står
   på påstanden (§6). Merknaden over listen sier alle tre delene: at dette er hele grunnlaget
   bak den publiserte revisjonen, at rekkefølgen ikke er en rangering, og at antallet ikke er
   sikkerhet. Skulle en senere PR likevel gruppere, er det en designbeslutning som må skrives
   ned og begrunnes — ikke en sortering som sniker seg inn.

3. **Et fravær sier alltid hvorfor, og et konfidensintervall står aldri uten sin status.** Seks
   kolonner bærer en `*_availability`, og de finnes nettopp for at en tom verdi aldri skal kunne
   leses som en nullverdi (§17, `DATABASE_ARCHITECTURE.md` §19.1). Avledningen deler vokabularet
   i de to halvdelene migrasjon 003 faktisk skiller på — `reported_value`/`uncertain_extraction`
   mot de fire fraværene — og alt annet blir et synlig kontraktsbrudd framfor å havne i «ikke
   rapportert». Listene er skrevet ut og ikke avledet av hverandre, slik at en ny enum-verdi
   tvinger fram en beslutning. De fire grunnene holdes fra hverandre i teksten, fordi de er
   egenskaper ved forskjellige ting: studien, publikasjonen, funnet og ekstraksjonen.
   Presisjonsfeltet er alltid til stede, også når intervallet mangler — samme regel som at
   tallet og komparatoren på kortet er ett felt: et manglende intervall betyr upresist grunnlag,
   ikke et presist estimat. Og et intervall uten nivå vises ikke som et intervall, fordi «0,9
   til 2,5» betyr forskjellige ting på 90 % og på 99 %.

4. **Fem vokabularer lukket, og alle åtte har nå kjøretidskontroll.** §74.12 punkt 3 sa at den
   PR-en som forgrener på et vokabular, legger til kontrollen samtidig. Evidensvisningen
   forgrener på åtte:

   | Vokabular | Hva en feil gren ville gjort |
   |---|---|
   | `relationship_type` | presentert et motstridende funn som støtte (§9) |
   | `directness` | skjult at et funn bare treffer påstanden indirekte |
   | `*_availability` | gjort et registrert fravær til en nullverdi (§17) |
   | `reported_direction` | latt kildens egen retning bli Antideps konklusjon (§5) |
   | `study_design` | gitt et ukjent design en randomisert studies vekt |
   | `source_type` | lest en preparatomtale som en primærstudie |
   | `source_status` | vist en tilbaketrukket kilde som normal (§14) |
   | `date_precision` | vist «2019» som «1. januar 2019», altså falsk presisjon (§6) |

   `reported_direction` er en felle, og den er navngitt i koden: den er **ikke** påstandens
   `direction`. Vokabularet har en fjerde verdi, `not_stated`, og å slå de to sammen ville latt
   «kilden oppgir ingen retning» og «Antidep konkluderer med ingen klar forskjell» bytte plass.
   `tests/api-vocabularies.test.ts` kontrollerer nå alle åtte mot migrasjonene, og har i tillegg
   en vaktpost som krever at de to retningsvokabularene *forblir forskjellige* — målt på
   migrasjonene, ikke på TypeScript-unionene, slik at den også fanger at databasen skulle slå
   dem sammen.

5. **Evidensen er festet til den revisjonen som faktisk står på skjermen.** Begge viewene
   følger `current_published_revision_id`, og de to spørringene er uavhengige. Publiseres en ny
   revisjon mellom dem, svarer `published_claims` med revisjon N og `published_claim_evidence`
   med funnene til revisjon N+1 — og siden ville vist et evidensgrunnlag under en formulering det
   aldri var lenket til. Det er nøyaktig det §4 forbyr: en kilde som omhandler samme tema uten å
   underbygge formuleringen, er ikke støtte. Vinduet er lite, og feilen ser ut som et gyldig svar
   — samme klasse som det foreldede svaret `useReadModel()` gjør strukturelt umulig (§74.14
   punkt 4). Hver evidensrad bærer sin `claim_revision_id`, og settet vises bare når alle hører
   til den viste revisjonen; ellers sier siden at påstanden ble publisert på nytt mens siden
   lastet. Ingen delvis visning: et blandet sett er verre enn ingen. Kontrollen er en
   sammenligning og ikke et filter i spørringen, med hensikt — et `eq('claim_revision_id', …)`
   ville gjort skiftet til et tomt svar, og et tomt svar betyr allerede noe helt annet her (se
   punktet under). De to årsakene må ikke dele ordlyd. Funnet kom fra den eksterne reviewen på
   denne PR-en; det er sjette PR på rad der en gjennomgang finner noe mutasjonstesting ikke
   kunne, og av samme grunn som før: mutasjonene traff implementasjonen, ikke forutsetningen om
   at de to spørringene ser samme revisjon.

6. **En publisert påstand uten evidens er et brudd, ikke et fravær.** Publiseringsgaten G3
   nekter å publisere en revisjon uten minst én evidenslenke (§4), så tilstanden skal ikke
   kunne finnes. Den vises derfor som en feil med `role="alert"` og med beskjed om å behandle
   påstanden som ubekreftet — ikke som en rolig opplysning om at evidens mangler. Det samme
   gjelder to publiserte påstander på samme identitet: `api.published_claims` har én rad per
   påstand, så to rader er ikke en rekkefølge å velge i, og ingen av dem vises.

7. **En tilbaketrukket ekstraksjon merkes, den skjules ikke — og reviewkontrakten utvides
   ikke.** Kortet sier hvor mange evidenslenker som er trukket tilbake; her står det hvilke,
   med tidspunkt og begrunnelse, og funnet blir stående fordi påstanden over det fortsatt er
   publisert (§14). Av reviewhistorikken vises fortsatt bare tidsstempler — ingen
   aktøridentitet, ingen beslutningstype, ingen begrunnelse (§58, §74.11). De fire
   tidsbegrepene holdes adskilt (`DATABASE_ARCHITECTURE.md` §7.3), og
   publiseringstidspunktet, som kortet med vilje utelater, står her.

**Én delt regel, ikke to utgaver.** `describeMeasureUnit()` er skilt ut av
`describeClaimMagnitude()` fordi migrasjon 003 håndhever nøyaktig samme enhetsregel på
evidensfunnene som migrasjon 004 gjør på påstandsrevisjonene. Estimatavledningen kaller
`describeClaimComparator()` og `describeClaimMagnitude()` direkte når statusen sier at et tall
står der, med intervensjonen som subjekt slik virkestoffet er påstandens. Da gjelder også
forsvaret mot et kontrastivt effektmål uten komparator på evidensradene, uten en andre utgave
av regelen. Effektmåletikettene ligger nå i `vocabulary-labels.ts`, av samme grunn: en
oddsratio er en oddsratio uansett hvilken rad den står i.

**Veien tilbake.** Siden lenker til virkestoffet og til det kliniske temaet påstanden hører
til. En delt lenke lander her uten historikk å gå tilbake i, og §55 og §56 krever at
dypelenken virker og at tilbakenavigasjonen bevarer konteksten. Adressene bygges av
`routes.ts`, som ellers på flaten.

**Det som ikke vises, og hvorfor.** §41 avslutter med «Full referanseliste». Den er utelatt som
egen seksjon: hvert funn bærer hele kilderaden allerede, og en liste i tillegg ville vært de
samme dataene to ganger på én side. Behovet §41 peker på — én visning per kilde, med alt
Antidep bruker den til — er `Source`-visningen i §42, og den er en egen PR. Identifikatorene
vises som tekst og ikke som lenke til originalen; en `href` bygget av en streng fra databasen
er en annen beslutning enn å vise strengen, og den hører hjemme sammen med `Source`-visningen.

**Gjeld: ingen nye poster, to eksisterende presisert.** Regelen om at et kontrastivt effektmål
krever en komparator, mangler også på `knowledge.evidence_items` — samme gjeld, én tabell til.
Og kontrollen av `api`-kontrakten mot databasens *kolonner* står fortsatt igjen; innsatsen er
høyere nå, fordi evidensvisningen leser over femti kolonner fra ett view. Vokabularhalvdelen er
til gjengjeld helt lukket: alle åtte lukkede unioner har både en kontroll mot migrasjonene og en
kjøretidskontroll.

**Ingen uprøvbare vakter.** To tidlige utforminger her hadde grener ingen test kunne nå: en
`complete`-tilbakekalling i den generiske feltavledningen ga kallerne en tidsromtype og en
intervalltype med ledd som i praksis aldri var tomme, og visningen måtte likevel forgrene på dem.
Avledningen bygger nå den sammensatte verdien først etter at leddene er kontrollert, så typen
selv sier at begge ledd finnes, og visningen har ingen gren igjen å skrive. Det er samme
opprydding som `baselineReadingIsLicensed()` i §74.13 og de to fjernede grenene i §74.14: en
uprøvbar vakt ser ut som et vern uten å være det. `implausible_value` kom til i samme runde, som
et eget bruddskille fra `incomplete_value` — en utvalgsstørrelse på null og et intervall med
grensene i feil rekkefølge er ikke halve verdier, de er verdier som ikke kan være det de er
registrert som, og rettingen er en annen.

**Hva som ble verifisert.** `npm run lint`, `npm run format:check`, `npm run typecheck`,
`npm run test` og `npm run build` er kjørt og passerer, sammen med `./scripts/verify-counts.sh`.
Vitest-suiten er utvidet fra 408 til 556 tester. Mutasjonstesting er kjørt etter mønsteret i
§74.13 og §74.14: rundt åtti mutasjoner er innført én om gangen over avledningen, komponenten,
siden, de delte reglene og vokabularvaktpostene, og alle fanges nå. Fem av dem overlevde først,
og alle fem var reelle hull i testene framfor i koden:

- Datomønsteret var ikke prøvd på ytterpunktene. En løsere form gjorde «20190301» og «2019-3-1»
  til gyldige datoer uten at noe feilet.
- Mønsteret var heller ikke prøvd uforankret i slutten, og et uforankret mønster ville tatt imot
  et `timestamptz` og stilltiende kuttet klokkeslettet — altså vist en dato som ikke er den
  kolonnen bærer.
- Påstanden om merknaden over evidenslisten var avkortet, slik at **halesetningen** — den som
  sier hvor sikkerheten faktisk står — stod uprøvd.
- En assertion på publiseringstidspunktet var **stille sann**, fordi en annen rad i samme
  tidspunktliste bar nøyaktig samme dato. Fiksturen har nå én dato per felt, og assertionen
  leser det feltet den handler om.
- Teksten for en verdi som ikke kan være det den er registrert som, ble aldri rendret av noen
  test. En utvalgsstørrelse på null kunne dermed vært vist som «0» — nettopp den lesningen §17
  forbyr — uten at noe feilet.

Flaten er kjørt i Chromium på 1280 px og på en ekte 390 px mobilviewport gjennom
devtools-protokollen, med tre funn — ett velformet, ett tilbaketrukket med tilbaketrukket kilde,
ett uten estimat — uten horisontal overflyt (`scrollWidth` lik `clientWidth` på begge bredder) og
uten konsollmeldinger utover en manglende favicon på forhåndsvisningssiden. Overskriftshierarkiet
er kontrollert i nettleseren: h1 produkt, h2 side, h3 seksjon, h4 påstand og funn, h5 kilde.

**En anbefaling til neste PR som rører verktøykjeden.** Skjermdumpskriptet og
mutasjonstestharnessen er nå skrevet fra bunnen av tre ganger — i #23, i #24 og her — fordi de
lever i scratchpad og ikke i repoet. Ingen av dem inneholder klinisk innhold. De hører hjemme i
`scripts/`, men ikke i en ren funksjonalitets-PR (§51), så de er bevisst ikke lagt til her.

**Hva som gjenstår av PR I.** `Source`-visningen (§42): én side per kilde, som beskriver
publikasjonen og lenker til de påstandene Antidep bruker den til. Viewene svarer fortsatt `[]`,
så den må bygges mot den tomme projeksjonen på samme måte som sidene her. Det er det siste
punktet i leveranselisten i §30. Den ble bygget i neste PR; se §74.16.

### 74.16 Hva kildevisningen innførte

`feat: add the source view` er femte del av PR I (§30, §68) og det siste leveransepunktet i
Slice 2: «kildedetalj». Den oppretter ingen migrasjon og legger ingen ny avhengighet til. Den
består av ruten og adressen (`/sources/:sourceId`), en ny lesefunksjon
(`fetchPublishedEvidenceForSource()`), selve siden (`src/app/pages/SourcePage.tsx`), de delte
kildefeltene (`src/components/SourceDetails.tsx`), feltlisten begge kildevisningene nå bruker
(`src/components/DetailList.tsx`) og avledningen fra en registrert identifikator til en adresse
(`src/lib/source-identifier.ts`).

**Slice 2 (§30) er dermed ferdig.** Både definition of done og leveranselisten er innfridd, og
markeringen i §74.1 er flyttet fra `[~]` til `[x]`. `PRODUCT_INFORMATION_ARCHITECTURE.md` §42
er innfridd i begge retninger: fra en påstand til grunnlaget bak den, og fra én publikasjon til
alt Antidep bruker den til. De to visningene lenker til hverandre og er ikke blandet.

**Seks beslutninger, i den rekkefølgen de betyr noe klinisk:**

1. **Kilden er emnet, ikke det kilden konkluderer med.** Kilderaden beskriver dokumentet, og hva
   Antidep mener dokumentet *viser*, ligger i evidensfunnene og påstandene
   (`KNOWLEDGE_MODEL.md` §10). En side om én publikasjon leses lett som en oppsummering av
   publikasjonen, så merknaden over listen sier det eksplisitt: listen er Antideps bruk av
   kilden, ikke kildens innhold. Siden gjentar heller ikke evidensvisningen — hvorfor et funn
   støtter eller motsier en påstand, med populasjon, komparator, resultat og presisjon, står
   der, og herfra går det en lenke dit. Det siden legger til, er kildens eget bidrag til hvert
   funn: relasjonen funnet har til påstanden, hvor i kilden det står, og hvilken hentet versjon
   det ble lest ut av.

2. **Evidensen er festet til den revisjonen som faktisk står på skjermen — og strengere enn på
   evidenssiden.** §74.15 punkt 5 sa at enhver ny side som leser to api-views arver kravet, og
   dette er den første som gjør det. Kildesiden leser `published_claim_evidence` filtrert på
   `source_id` og `published_claims` for formuleringene, og de to spørringene er uavhengige.
   Hver evidensrad sammenlignes derfor mot påstandsraden sin på `claim_revision_id`, og et
   avvik forkaster *hele* listen — ikke bare den påstanden som skiftet. En liste bærer to
   påstander, rekkefølgen og at dette er settet (§74.14 punkt 1), og en liste der én påstand er
   utelatt fordi den skiftet under lastingen, sier at kilden brukes til færre ting enn den gjør.
   Skjevheten har to årsaker med hver sin ordlyd: påstanden ble publisert på nytt, eller den
   stod ikke lenger i det publiserte settet. Ingen av dem deler ordlyd med et tomt svar.

3. **Adressen er kildens `uuid`.** Samme grunn som at evidensvisningen adresseres med
   `claim_id`: uuid-en er kildens stabile identitet (`DATABASE_ARCHITECTURE.md` §8). En slug
   avledet av tittelen ville i tillegg til å bli lang og fremmedspråklig — titler er inntil 600
   tegn og står på kildens eget språk — hatt nøyaktig den svakheten §74.7 allerede fører som
   gjeld for `/drugs/:drugSlug` og `/topics/:topicSlug`: en adresse avledet av et visningsnavn
   er ikke en stabil identitet, avledningen er tapsgivende, og to titler kan kollidere. Gjelden
   er dermed ikke utvidet til et tredje objekt.

4. **Identifikatorene er blitt lenker, og det er en egen beslutning med to forutsetninger.**
   §74.15 satte beslutningen om å bygge en `href` av en databaseverdi til denne PR-en. Svaret er
   å lenke, fordi etterprøvbarhet mot originalkilden er hele poenget med både kilde- og
   evidensvisningen (`ANTIDEP_CONSTITUTION.md` §4, §11; §43). To ting gjør den forsvarlig.
   Formen er håndhevet i databasen — migrasjon 003 legger `CHECK`-betingelser på både DOI og
   PMID, så verdien *er* en identifikator og ikke en URL, et `doi:`-prefiks eller en fritekst —
   og mønstrene kontrolleres likevel i klienten, av samme grunn som vokabularene har
   kjøretidskontroll: en verdi utenfor formen blir en eksplisitt ulenkbar tilstand som vises som
   tekst, aldri en URL ingen har tatt stilling til. Og suffikset prosentkodes framfor å settes
   rått inn: `\S+` tillater `#`, `?`, `<` og `>`, som alle ville gitt en lenke som ser riktig ut
   og peker et annet sted. Bokstavstørrelsen er bevisst *ikke* del av kontrollen — en DOI er
   ikke bokstavstørrelsesfølsom, så en verdi med store bokstaver bryter databasens unikhetsregel
   uten å gjøre lenken feil. Lenkene åpner i samme fane, med `rel="noreferrer"`, og hvert felt
   sier at adressen ligger utenfor Antidep.

5. **En erstattet kilde sier at etterfølgeren ikke kan navngis.** Statusen `superseded` betyr
   per migrasjon 003 at en *bestemt* nyere kilde er registrert:
   `knowledge.sources.superseded_by_source_id` er NOT NULL hvis og bare hvis statusen er den, og
   de to forutsetter hverandre. Pekeren er ikke i api-kontrakten — kontrollert: den finnes verken
   i viewet eller i `src/types/api.ts` — så klienten kan ikke følge den, og etiketten «Erstattet
   av en nyere kilde» alene er en halv sannhet: den sier at det finnes en etterfølger uten å
   kunne navngi den. Valget er å si nettopp det, framfor å la leseren tro at ingen etterfølger er
   registrert. Å utvide viewet ble vurdert og valgt bort: en `uuid` alene er ikke et svar
   klienten kan vise, så projeksjonen måtte båret etterfølgerens tittel også, og den må dessuten
   ta stilling til hva som skjer når etterfølgeren ikke selv er lesbar for klientrollene. Det er
   en migrasjon med sin egen beslutning, og §51 holder den utenfor en funksjonalitets-PR.
   Registrert som ny gjeld i §74.7.

6. **Kildeversjonen står på funnet, ikke på kilden.** `source_version_*` ligger på evidensraden,
   og samme kilde kan være lest i flere versjoner av flere funn. En «versjon»-rad i
   publikasjonsblokken ville derfor vært en sammenslåing datamodellen ikke har. Versjonen står i
   stedet under hvert funn, sammen med stedet i kilden — der den hører til, og der den svarer på
   spørsmålet «hvilken utgave leste Antidep?».

**Én delt presentasjon, ikke to.** Kildefeltene er skilt ut i `SourceDetails.tsx` og brukes av
begge visningene, av samme grunn som `ClaimCard` gjenbrukes på fire sider: samme rad, samme
regler, og en egen utgave hvert sted ville drevet fra hverandre — den ene ville fått en rettelse
den andre ikke fikk (§65 «Duplicated truth»). Det gjelder også merket på en tilbaketrukket
ekstraksjon og relasjonen funnet har til påstanden. `RELATIONSHIP_LABELS` er derfor ikke lenger
eksportert: oppslaget går gjennom `stanceText()`, som tar imot den *avledede* relasjonen og ikke
råverdien, så det finnes ingen vei der en relasjon Antidep ikke kjenner kan slå opp som noe annet
enn ukjent. Påstandskortet gjenbrukes også her: formuleringen alene ville stått uten
sikkerhetsgrad, anvendelsesområde og forbehold, altså som en påstand mer skråsikker enn den er
(§14, invariant 4). Og fordi kildesiden viser påstander om flere virkestoff under én overskrift,
arver den forbeholdet fra `ClaimGroups` om at påstander side om side ikke er en sammenligning —
det samme forbeholdet, ikke en andre utgave av det.

**Ingen nye vokabularer.** Siden forgrener på `source_type`, `source_status` og
`date_precision`, og alle tre ble lukket med kjøretidskontroll i evidensvisningen (§74.15). De
leses gjennom én ny delt avledning, `describeSource()`, slik at kildesiden og evidensfunnet ikke
kan gi hvert sitt svar om samme rad. `tests/api-vocabularies.test.ts` er derfor uendret: de åtte
lukkede unionene er de samme åtte.

**Gjeld: én ny post, tre presisert.** Den nye er `superseded_by_source_id`, over. Presisert:
kildesiden er den andre visningen som laster hele det publiserte settet for å vise ett utsnitt,
og den første som joiner det i klienten; slug-posten er presisert med at kildevisningen bevisst
ikke gjentok avledningen på et tredje objekt; og kolonnekontrollen av api-kontrakten står
fortsatt igjen, nå med to sider som leser det samme brede viewet.

**Interne rutelenker navigerer i klienten.** Lenken fra hvert evidensfunn til kildesiden var
først en vanlig `<a>`, etter mønster av `ClaimCard`. Det gir en full dokumentnavigering: siden
lastes på nytt, og `useFocusMainOnNavigation()` hopper med vilje over fokusflyttingen ved første
render, så leseren havner øverst i et nytt dokument framfor i hovedområdet. På evidenssiden stod
lenken dessuten rett ved lenkene til virkestoffet og temaet, som er `Link` — å navigere ulikt fra
samme avsnitt er en forskjell uten begrunnelse. Skillet som faktisk gjelder, er hva verdien *er*:
`ClaimCard` kan ikke bruke `Link`, fordi dens `evidenceHref` er et anker på samme side
(`#evidensgrunnlaget`) når kortet står på evidensvisningen, mens kildelenken alltid er en rute.
Adressene lages fortsatt bare i `routes.ts`, så §74.13 punkt 4 står uendret.

**Og det er sjuende PR på rad der en gjennomgang finner noe mutasjonstesting ikke kunne** — av
nøyaktig samme grunn som de seks før: mutasjonene traff implementasjonen, ikke forutsetningen. Det
fantes en mutasjon som fjernet lenken, og den ble fanget; men ingen test spurte *hvordan* lenken
navigerer, fordi `Link` og `<a>` gir nøyaktig samme DOM. Testen som nå holder regelen, klikker
lenken og krever at kildesiden faktisk rendres — med en vanlig `<a>` står ruteren stille, og
evidenssiden blir værende.


**Hva som ble verifisert.** `npm run lint`, `npm run format:check`, `npm run typecheck`,
`npm run test` og `npm run build` er kjørt og passerer, sammen med `./scripts/verify-counts.sh`.
Vitest-suiten er utvidet fra 556 til 627 tester over 26 filer. Mutasjonstesting er kjørt etter
mønsteret i §74.13 til §74.15: 60 mutasjoner er innført én om gangen over avledningen, de delte
komponentene, siden, lesefunksjonen, adressene og navigeringsmåten, og alle fanges.

To ting om harnessen er verdt å ta med videre, fordi begge gjør en mutasjonskjøring stille
verdiløs. En avbrutt kjøring kan etterlate filen mutert, og da måler neste kjøring mot en **rød
grunnlinje** der hver eneste mutasjon rapporterer seg som drept — det skjedde her, og hele
batchen måtte forkastes og kjøres om. Harnessen kjører nå grunnlinjen først og avbryter hvis den
er rød, og gjenoppretter filen på signal. Og en assertion kan være svak på nøyaktig samme måte
som testdataene er svake: kollasjonstesten prøvde «Bly» mot «Åpen», som en sortering på tegnverdi
ordner *likt*, så en sortering uten `compareNorwegian()` ville passert. Testdataene inneholder nå
«Aaland», som norsk kollasjon sorterer som «Åland» og altså etter «Bly», og mutasjonen som bytter
til tegnverdisortering fanges.

Flaten er kjørt i Chromium på 1280 px og på en ekte 390 px mobilviewport gjennom
devtools-protokollen, med en kilde brukt til to påstander om to virkestoff, tre funn, ett av dem
med tilbaketrukket ekstraksjon, og en erstattet kilde med to DOI-er og én PMID — uten horisontal
overflyt (`scrollWidth` lik `clientWidth` på begge bredder, ingen element med indre overflyt) og
uten konsollmeldinger utover en manglende favicon på forhåndsvisningssiden. Overskriftshierarkiet
er kontrollert i nettleseren: h1 produkt, h2 kilden, h3 seksjon, h4 påstand. Evidensvisningen er
kjørt på nytt på begge bredder etter uttrekket av de delte feltene, og er uendret bortsett fra de
to nye tingene: lenken til kildesiden og de lenkede identifikatorene.

**Skjermdumpskriptet og mutasjonstestharnessen er nå skrevet fra bunnen av en fjerde gang**, av
samme grunn som før: de lever i scratchpad og ikke i repoet. Anbefalingen fra §74.15 står
uendret og er ikke innfridd her, fordi denne PR-en ikke rører verktøykjeden og §51 krever
enkeltformål.

**Hva som gjenstår.** Slice 2 er ferdig, og PR I er ferdig. Neste vertikale slice er §31
(sammenligning), men det som blokkerer er fortsatt ikke kode: Milepæl B mangler én navngitt
kvalifisert redaktør (§74.4), og viewene svarer `[]` til den finnes. Den mest verdifulle
strukturelle oppryddingen er fortsatt kolonnekontrollen av api-kontrakten (§74.7).

Redaktøren ble navngitt og registrert i neste PR; se §74.17. Setningen over arvet samtidig
feilen §74.4 nå retter: én redaktør var aldri alt som gjenstod for Milepæl B, og viewene
svarer fortsatt `[]`.

### 74.17 Hva registreringen av redaktøren innførte

`db: register the named qualified editor` er migrasjon 005a. Den utvider aktørregisteret fra
migrasjon 005 (§20), står utenfor den planlagte rekken i §18-§27 og får derfor en bokstav,
etter samme konvensjon som 006a og 007a. Den legger ingen ny avhengighet til, oppretter ingen
tabell, ingen enum-type og ingen funksjon. Den setter inn én rad.

**Beslutningen den registrerer.** §74.4 slo fast at neste skritt mot Milepæl B ikke var en
kodeoppgave, men en governance-beslutning: hvem er den navngitte kvalifiserte redaktøren
`ANTIDEP_CONSTITUTION.md` §12 krever? Prosjekteieren, Peder Holman, har utpekt seg selv.
Migrasjonen gjør den beslutningen til en kanonisk rad. En navngitt redaktør som bare finnes i
prosa, er ikke navngitt på en måte databasen kan bruke: aktørraden er festepunktet for all
attribusjon (`DATABASE_ARCHITECTURE.md` §32).

**Fem beslutninger, i den rekkefølgen de betyr noe:**

1. **Aktøren registreres uten brukerkonto, og det er formen modellen er bygget for.**
   `provenance.actors.auth_user_id` har en ekte fremmednøkkel til `auth.users`, og den kontoen
   er en reell Supabase-konto som må opprettes i autentiseringslaget — ikke i en migrasjon. En
   rad med en oppdiktet `uuid` ville enten feilet på fremmednøkkelen eller pekt på en konto
   ingen eier. Kolonnen står derfor `NULL`, og betyr nøyaktig det migrasjon 005 sier: aktøren
   har ikke en konto i dette systemet, ikke at aktøren er ukjent. Dette er ingen omgåelse:
   `provenance.freeze_actor_identity()` fryser aktøridentiteten, men gjør ett eksplisitt
   unntak — `auth_user_id` kan settes én gang fra `NULL`, «fordi en menneskelig aktør kan bli
   registrert før kontoen finnes». Unntaket er håndhevet og testet i begge retninger i
   `200_workflow_immutability_test.sql`: koblingen kan settes én gang, og kan verken fjernes
   eller flyttes etterpå. Den senere koblingen er dermed ikke en antakelse denne migrasjonen
   hviler på uten dekning.

2. **Raden åpner ikke publiseringsgaten, og det er prøvd framfor påstått.** En navngitt
   redaktør i basen leses lett som at godkjenningsveien nå står åpen. Den gjør ikke det, og å
   telle at `workflow.review_decisions` fortsatt er tom ville vært et svakt uttrykk for det —
   tabellen er tom av mange grunner. `220_provenance_seed_test.sql` forsøker derfor faktisk å
   registrere en publiseringsgodkjenning i redaktørens navn, og krever at databasen avviser
   den med `insufficient_privilege` og med den meldingen
   `workflow.enforce_reviewer_qualification()` gir. Assertionen kan ikke bli stille sann:
   slår oppslaget på `actor_key` feil, gir spørringen null rader, `insert`-en lykkes med å
   sette inn ingenting, og `throws_ok` feiler fordi ingen exception ble kastet. Både feilkoden
   og meldingen kontrolleres, slik at en feil på et tidligere lag ikke kan telle som riktig
   avvisning.

3. **Selvtildeling er valgt, og skrevet ned før kolonnen krevde en verdi.**
   `workflow.user_roles.granted_by_actor_id` er `NOT NULL` og peker på en aktør. Når
   `reviewer`-rollen en gang tildeles, finnes bare to muligheter: enten tildeler en KI-aktør
   et menneske faglig godkjenningsrett, eller så tildeler redaktørens egen aktør rollen til
   seg selv. Ingen `CHECK` forbyr selvtildeling, så valget ville ellers blitt tatt i stillhet
   av den som fylte ut kolonnen. Beslutningen er selvtildeling: autoriteten kommer utenfra
   systemet, prosjekteieren *er* den kvalifiserte redaktøren, og det finnes ingen høyere
   menneskelig instans i basen. Alternativet ville gjort en KI-prosess til opphavet til et
   menneskes faglige godkjenningsrett, stikk i strid med §10 og §12. Prisen er at
   selvtildelingen står usikret av en `CHECK`, og den må derfor stå eksplisitt i
   `grant_reason` på tildelingsraden.

4. **Beskrivelsen sier hva aktøren er, ikke hva som er kontrollert.** `description` er
   `NOT NULL` og skal være konkret nok til å være etterprøvbar. Den sier at utpekingen hviler
   på prosjekteierrollen og ikke på et fastsatt kompetansekrav, og at raden ikke i seg selv
   gir godkjenningsrett — den leses fra brukerkonto og `workflow.user_roles`, ikke herfra.
   Uten den siste setningen ville `display_name` «Peder Holman» ved siden av ordet «redaktør»
   kunnet leses som en fullmakt raden ikke gir. Beskrivelsen er bevisst utenfor
   identitetsvernet og kan endres når kompetansekravene finnes; den skal ikke kunne leses som
   en kvalifikasjon Antidep har kontrollert.

5. **Redaktøren har ikke forfattet noe, og det er en forutsetning.**
   `review_decisions_separate_actor_check` nekter en godkjenning der godkjenner og forfatter er
   samme aktør (§10, §12). Stod redaktøren senere som opphav til en revisjon, kunne
   vedkommende ikke godkjent den. Testen påstår derfor at ingen kunnskapsobjekt er attribuert
   til en menneskelig aktør, skrevet over aktørtypen og ikke over `actor_key`, slik at
   assertionen ikke kan bli stille sann av en feilstavet nøkkel.

**Seedtesten er justert, ikke omgått.** `220_provenance_seed_test.sql` sa selv at assertionene
«skal justeres av migrasjonen som registrerer en reell godkjenning og en reell publisering,
ikke omgås». Migrasjon 005a er første gang det skjer. Assertionen om at aktørregisteret
inneholder nøyaktig de to KI-rollene er utvidet til tre rader og bærer nå `display_name` også —
§12 krever en *navngitt* redaktør, og navnet er feltet som bærer navngivingen; uten det ville
testen godtatt en anonym menneskelig aktør. Assertionen om at det finnes null menneskelige
aktører er byttet med en som krever nøyaktig én, og at det er den navngitte. Filen gikk fra 14
til 16 assertions, og databaselaget fra 1096 til 1098.

**Én assertion ble strammet underveis.** Kravet om at hver aktør «forklarer konkret hva den er»
var skrevet som «beskrivelsen er ikke tom eller `NULL`». Databasens `CHECK` krever bare 1-2000
tegn, så en beskrivelse på ett tegn passerte begge. Migrasjon 005 sier hvorfor kolonnen finnes
— «en aktørrad uten beskrivelse ville gjort attribusjonen til en etikett i stedet for en
forklaring» — og en etikett er nettopp det en svært kort beskrivelse er. Assertionen har nå et
lengdegulv, slik at den påstår det den sier den påstår.

**Gjeld: én ny post.** Kompetansekravet for redaktørrollen er ikke definert, og redaktøren er
utpekt av seg selv. §12 krever en «kvalifisert» redaktør uten å definere kvalifikasjonen;
`CONTENT_GOVERNANCE.md` §11 legger den definisjonen til Clinical Lead, og Antidep har ingen.
Samme person er prosjekteier og eneste faglige godkjenner, og modellen har ingen kolonne for
den profesjonelle bindingen §45 og §46 ber om å registrere. Migrasjonen navngir personen
beslutningen allerede har pekt ut; den lukker ikke hullet, og skjuler det ikke heller.

**Hva som ble verifisert.** Migrasjonene er kjørt fra bunnen av og hele pgTAP-suiten er kjørt
mot en lokal PostgreSQL 16 med pgTAP — Docker-registryene svarer 403 gjennom egress-proxyen, så
`npx supabase start` er ikke tilgjengelig; CI kjører den ekte stacken. Grunnlinjen før endringen
var 1096 passerende assertions, etter endringen 1098, uten `not ok` og uten `ERROR`.
`npm run lint`, `npm run format:check`, `npm run typecheck`, `npm run test`, `npm run build` og
`./scripts/verify-counts.sh` er kjørt og passerer. Ti mutasjoner er innført én om gangen; ni
fanges. Den som overlever er lengdegulvet i assertionen over: senkes tallet, blir assertionen
svakere, og ingen test beskytter en annen tests terskelverdi. Mutasjonen som faktisk betyr noe
— en beskrivelse redusert til en etikett i migrasjonen — fanges.

**Den viktigste mutasjonen traff forutsetningen, ikke implementasjonen.** §74.16 slo fast at
sju PR-er på rad hadde fått funn mutasjonstesting ikke kunne finne, hver gang fordi mutasjonene
traff koden og ikke antakelsen den hvilte på. Her ble antakelsen mutert direkte: kravet om
brukerkonto i `workflow.enforce_reviewer_qualification()` ble slått av i migrasjon 005, og den
nye negative testen feilet. Den påstanden er dermed ikke lånt fra gaten — den er kontrollert
mot den.

**Hva som gjenstår.** Milepæl B mangler fire ting, ikke én (§74.4): brukerkonto med
`reviewer`-rolle, ekstraksjonsverifikasjonene, claim-verifikasjonene og godkjenningen. Neste
vertikale slice er §31 (sammenligning). Den mest verdifulle strukturelle oppryddingen er
fortsatt kolonnekontrollen av api-kontrakten (§74.7).

### 74.18 Det hostede Supabase-prosjektet er tomt

> **Overhalt av §74.23.** Migrasjonene er siden kjørt mot det hostede prosjektet, og `api` er
> eksponert. Avsnittet er beholdt som historikk (§71). Det som fortsatt gjelder herfra, er
> forbudet mot `supabase config push` og begrunnelsen for vei a i migrasjon 005b — men
> begrunnelsen for *forbudet* er rettet: tabellen under sammenlignet `config.toml` med
> produksjonsverdier ingen hadde lest. Den kontrollerte sammenligningen står i §74.23.

**Funnet.** Prosjekteieren åpnet Supabase-dashboardet (Integrations → Data API → Settings →
«Exposed schemas») for å gjøre den manuelle synkingen §74.5 punkt 3 ber om. Nedtrekkslisten
der viser de schemaene som faktisk finnes i databasen, og den inneholdt nøyaktig to:
`graphql_public` og `public`. Ingen av Antideps schemaer var der — verken kontraktslaget `api`
eller de kanoniske `catalog`, `knowledge`, `workflow`, `provenance` og `audit`.
**Migrasjonene har aldri vært kjørt mot det hostede prosjektet.** Databasen der er tom.

**Hva som er kontrollert, og av hvem.** Observasjonen kommer fra prosjekteieren i dashboardet.
Ingen med databasetilgang har bekreftet den, og denne sesjonen kan ikke: Supabase-MCP-serveren
krever en autorisasjon som ikke finnes her, og Docker-registryene svarer 403 gjennom
egress-proxyen, så `npx supabase start` kan ikke hente imagene. Påstanden føres derfor med sin
kilde, framfor som et faktum repoet har målt. Det som *er* kontrollert mot kilden her, er de to
tingene funnet gjør noe med: `supabase/config.toml` beskriver en lokal stack og ikke et hostet
prosjekt, og `src/lib/supabase.ts` binder klienten til `api` med `db: { schema: 'api' }`.

**Hvorfor den motsatte påstanden overlevde.** «Det hostede prosjektet» har vært omtalt i denne
planen og i `supabase/README.md` siden migrasjon 007 som noe migrasjonene *lå i* og som
`[api].schemas` skulle synkes *mot*. Ingen kontrollerte det; formuleringen ble ført videre fra
oppdatering til oppdatering. Dette er sjuende gang en påstand i planen har vært arvet framfor
kontrollert (§74.4, §74.8), og den skiller seg fra de seks foregående på ett punkt: de var
tall, som `scripts/verify-counts.sh` etter hvert kunne fange. Denne er en påstand om et system
utenfor repoet, og ingen vaktpost i CI rapporterer schematilstanden der. Det er ikke et
argument for å la den stå ukontrollert — det er grunnen til at den må føres med sin kilde og
ikke som et faktum.

**Konsekvenser, i den rekkefølgen de betyr noe:**

1. **`public` er skrudd av i det hostede prosjektet, og det var trygt.** Schemaet inneholder
   ingen Antidep-objekter — `020_data_api_boundary_test.sql` håndhever det for migrasjonene —
   og i det hostede prosjektet er det tomt uansett. Eksponeringen var derfor tom i begge
   miljøer, og §5 er opt-in.
2. **`api` kan ikke eksponeres ennå.** Schemaet dukker opp i avhukingsmenyen først når
   migrasjonene er kjørt. Synkingen §74.5 punkt 3 ber om, er dermed ikke utsatt av
   forsømmelse: den er ikke mulig ennå.
3. **Rekkefølgen i den listen finnes ikke som begrep, og betyr uansett ingenting for appen.**
   Dashboardets eksponerte schemaer er en avhukingsmeny, ikke en sortert liste. `api` står
   først i `config.toml`, men klienten sender `Accept-Profile: api` uansett (§74.5 punkt 3),
   så standardprofilen er ikke noe appen hviler på.
4. **Ingenting av klinikerflaten peker på det hostede prosjektet ennå, og det er ikke et nytt
   tap.** Ingenting er publisert (§74.4), så en fullt migrert database der ville vist et tomt
   publisert sett — nøyaktig det appen viser i dag.

**Det finnes en Supabase-GitHub-integrasjon på repoet, og den har vært stille hele veien.**
Hver pull request får en `Supabase Preview`-kontroll. På PR-en som skrev dette avsnittet er
utfallet `skipped`, med begrunnelsen «This git branch is not associated with any Supabase
Branch». Kontrollen peker på prosjektet `gxorhbwndpopartjuwbj`, som dermed er det hostede
prosjektet integrasjonen er koblet til. Det er første gang den identiteten står noe sted i
repoet — den finnes ellers bare i CI-overflaten — og den trengs av den som skal kjøre
`supabase link`. To ting kontrollen *ikke* sier, og som ikke må leses inn i den: en preview
branch er en egen database, så et `skipped`-utfall sier ingenting om hva produksjonsdatabasen
inneholder; og at integrasjonen er installert, betyr ikke at noen migrasjon noen gang er kjørt
gjennom den. Supabase Branching er likevel en tredje mulig vei ut for migrasjonene, ved siden
av `supabase db push` og dashboardet, og må vurderes sammen med dem — men den kjører
migrasjonene mot *preview*-databaser og ikke mot produksjon, så den løser ikke oppgaven under
alene.

**Å kjøre migrasjonene mot det hostede prosjektet er en egen oppgave, og den er ikke gjort.**
`supabase link` etterfulgt av `supabase db push` er verktøyet. Oppgaven skal planlegges og
ikke bare utføres: den må ta stilling til §54 — migrasjonene er kilden, ikke dashboardet — og
til advarselen under, som gjelder nabokommandoen. Den hører hjemme hos prosjekteieren og ikke
i en agentsesjon uten tilgang til prosjektet.

**Aldri `supabase config push` mot dette prosjektet.** Kommandoen finnes i den pinnede CLI-en
og ser ut som riktig vei, siden den ville gjort `config.toml` til kilden slik §54 ber om. Den
pusher hele filen, og `config.toml` her er i praksis `supabase init`-standardene for en lokal
stack:

| Nøkkel | Verdi i `config.toml` | Hva et push ville gjort i produksjon |
|---|---|---|
| `auth.site_url` | `http://127.0.0.1:3000` | satt produksjonens site URL til localhost |
| `auth.additional_redirect_urls` | `["https://127.0.0.1:3000"]` | slettet de reelle redirect-URL-ene |
| `auth.minimum_password_length` | `6` | senket passordkravet |
| `db.network_restrictions.allowed_cidrs` | `["0.0.0.0/0"]` | åpnet databasen for alle adresser |

> **Høyrekolonnen er ikke kontrollert, og var det aldri.** Venstre og midtre kolonne er lest
> ut av `config.toml` og stemmer. Høyrekolonnen er en slutning om produksjonsverdier ingen
> hadde lest på det tidspunktet — den ble skrevet 26. august 2026, samme dag som §74.18 slo
> fast at ingen her hadde tilgang til å lese det hostede prosjektet. To av de fire radene viste
> seg senere å beskrive en forskjell som ikke fantes. Tabellen er beholdt som historikk (§71);
> **den kontrollerte sammenligningen mot produksjon står i §74.23**, og det er den som skal
> brukes.

Alle fire treffer autentiseringslaget og nettverksgrensen — altså nøyaktig der redaktørens
brukerkonto ligger. Enkeltinnstillinger settes i dashboardet. Å gjøre `config.toml` til reell
kilde for det hostede prosjektet er en egen, bevisst oppgave der hver seksjon først må settes
til produksjonsverdier. Selve hovedregelen står uendret av rettelsen over, og hviler ikke på
de fire radene: `config.toml` er ikke en produksjonskonfigurasjon, kommandoen pusher hele
filen, og ingen har sammenlignet alle nøklene i den mot produksjon.

**Redaktørens brukerkonto finnes, og tvinger fram et valg.** Prosjekteieren har opprettet
kontoen i det hostede prosjektet (Authentication → Users) og oppgitt dens `uuid`:
`a703ede9-3f58-4de9-8c85-73936d58df1f`. Formen er kontrollert her — gyldig uuid v4 etter
RFC 4122 — men at raden finnes i `auth.users`, er ikke kontrollert av noen med databasetilgang.
Migrasjonen som kobler kontoen til aktørraden fra §74.17 og tildeler `reviewer`-rollen, kan
derfor ikke skrives før dette er avgjort: kontoen finnes bare i det hostede prosjektet, mens
CI starter en fersk lokal stack uten den, og `workflow.user_roles.user_id` er `NOT NULL` med
fremmednøkkel til `auth.users`. Tre veier, og ingen av dem er åpenbart riktig:

| Vei | Hva den gjør | Prisen |
|---|---|---|
| a | Gjør koblingen betinget av at kontoen finnes, slik at migrasjonen ikke skriver raden i miljøer uten den | Migrasjonen gjør forskjellige ting i forskjellige miljøer, og CI kjører aldri den grenen som faktisk kjører i produksjon |
| b | Seeder en tilsvarende konto i `supabase/seed.sql` for lokalt og CI | **Virker ikke** — se under |
| c | Holder kobling og rolletildeling utenfor migrasjonene, som en operasjonell engangshandling mot produksjon | Bryter §54 sitt krav om at durable tilstandsendringer ligger i versjonerte migrasjoner, og gjør rolletildelingen usporbar i repoet |

**Vei b er ikke en vei, og det er kontrollert mot kilden.** `supabase/config.toml` sier det
selv om `[db.seed]`: «If enabled, seeds the database after migrations during a db reset.»
Seedfilen kjøres *etter* migrasjonene. En migrasjon 005b som skriver
`workflow.user_roles.user_id`, ville dermed kjørt før kontoen fantes, og feilet på
fremmednøkkelen til `auth.users` uansett hva `seed.sql` inneholder. Alternativet var ført opp
i hand-offen som ett av tre likeverdige valg; det er det ikke. Skulle kontoen finnes før
migrasjonene er ferdige, måtte den vært opprettet av en *migrasjon* som skriver til
`auth.users` — en kobling til Supabases eget schema som bryter på neste plattformoppgradering,
og som uansett gjør migrasjonen miljøavhengig, altså vei a med et ekstra ledd.

**Valget er delegert, og retningen er vei a.** Prosjekteieren har overlatt avgjørelsen til
denne sesjonen. Det er en teknisk avgjørelse om hvordan en migrasjon oppfører seg i CI, ikke
governance-avgjørelsen om hvem redaktøren er — den ble tatt og registrert i §74.17, og er ikke
rørt her. Begrunnelsen for a: en rad i `auth.users` er per definisjon miljøspesifikk tilstand,
ikke schema. Kontoen kan ikke finnes i en fersk lokal stack, og en oppdiktet konto lokalt ville
gjort at CI kontrollerte en fiksjon. Vei a er den eneste som holder rolletildelingen i en
versjonert migrasjon (§54) *og* lar raden være fraværende der den skal være fraværende.

Prisen i tabellen må da betales eksplisitt, ikke ties i hjel, og migrasjonens PR må gjøre to
ting for å betale den: raden skal ikke stille utebli, men gi en synlig `notice` når kontoen
mangler, og CI skal kontrollere *begge* grenene — den positive ved å opprette en konto inne i
en transaksjon som rulles tilbake, slik testene allerede gjør for alt annet, og den negative
ved å påstå at ingen rolle er tildelt når kontoen ikke finnes. Uten den positive testen ville
produksjonsveien vært ukjørt, og det er nøyaktig innvendingen mot vei a.

Selve innholdet i migrasjonen er ellers avklart: koblingen kan settes nøyaktig én gang fra
`NULL` (§74.17 punkt 1), granten er en selvtildeling som skal stå eksplisitt i `grant_reason`
(§74.17 punkt 3), og `220_provenance_seed_test.sql` må justeres — den negative testen som
krever at gaten avviser en godkjenning fordi aktøren mangler brukerkonto, skal erstattes av en
som påstår den *nye* avvisningsgrunnen, ikke slettes.

**Lærdom: et tall som bare finnes i en hand-off, er utenfor enhver vaktpost.** Hand-offen inn
til §74.17 oppga 56 kildefiler i `src/`. Det korrekte tallet var 57, og hadde vært det siden
`feat: add the source view` — migrasjon 005a rørte ingen fil i `src/`. Feilen er ikke ført inn
i planen her, og skal ikke føres inn: planen har aldri hevdet et slikt tall, og å legge til en
påstand utelukkende for å kunne kontrollere den er seremoni. Poenget er det motsatte, og det
gjelder framover: en påstand som bare lever i en hand-off, kontrolleres av ingen. Skal den
overleve, må den enten inn i et dokument en vaktpost leser, eller kontrolleres mot kilden på
nytt hver gang den brukes.

**Hva denne oppdateringen endret i vaktposten.** `scripts/verify-counts.sh` kontrollerer nå at
`[api].schemas` i `supabase/config.toml` er den verdien §74.5 punkt 3 hevder. Det er den
eneste påstanden i det punktet som *kan* kontrolleres maskinelt: verdien i `config.toml` er
kildekode, mens dashboardets tilstand ikke er det. Kontrollen leser den påståtte verdien ut av
planen framfor å ha den innbakt, slik at en omformulering gir «fant ingen påstand» og ikke en
stille godkjenning — samme form som de øvrige kontrollene i filen.

**Hva som gjenstår.** Milepæl B mangler fortsatt fire ting (§74.4). Sporet etter denne
oppdateringen er ikke rollegranten, men kolonnekontrollen av api-kontrakten (§74.7): den er
den mest verdifulle rent strukturelle oppryddingen, den er uavhengig av alt som krever et
hostet prosjekt eller en brukerkonto, og innsatsen vokser for hver side som legges til over de
samme uprøvde kolonnepåstandene. Ett funn sparer den neste for en blindvei:
`information_schema.columns` rapporterer `is_nullable = 'YES'` for alle kolonner i et view —
PostgreSQL gjør ingen nullbarhetsanalyse gjennom views. Navn og typer kan leses derfra;
nullbarhet kan ikke, og må håndheves på en annen måte som må navngis eksplisitt.

---

### 74.19 Hva kolonnekontrakten av api innførte

`test: verify the api column contract` innfrir den andre halvdelen av gjeldsposten som har
stått siden migrasjon 007: radtypene i `src/types/api.ts` og `Database`-typen i
`src/types/database.ts` er nå bundet til kolonnene `api` faktisk har. Ingen migrasjon, ingen
SQL-endring og ingen endring i `src/` — bare to nye kontroller og en innstrammet gjeldspost.

1. **Kontrakten er erklært ett sted og kontrolleres i to retninger.** `contract`-tabellen i
   `supabase/tests/340_api_column_contract_test.sql` har én rad per kolonne i `api`: view,
   kolonnenavn, SQL-type og nullbarhet. Derfra går kontrollen begge veier, i hver sin CI-jobb:

   | Retning | Hvor | Hva den krever |
   |---|---|---|
   | kontrakt → database | `340_api_column_contract_test.sql` (databasejobben) | at `api` har nøyaktig disse kolonnene, med nøyaktig disse typene |
   | kontrakt → TypeScript | `tests/api-columns.test.ts` (valideringsjobben) | at radtypene har nøyaktig disse egenskapene, med typer som svarer til SQL-typen |

   TypeScript-siden leser `values`-listen ut av pgTAP-filen. **Kryssleseren er ikke en
   bekvemmelighet, den er hele bindingen:** uten den ville de to halvdelene vært to
   uavhengige påstander, og typene ville fortsatt ikke vært knyttet til databasen. Parseren
   krever at hver ikke-tom linje i blokken lar seg lese og kaster ellers, slik at en
   omformatert liste stopper testen framfor å gjøre den stille sann på et avkortet utvalg.
   Det er samme regel som «fant ingen påstand» i `scripts/verify-counts.sh`.

2. **Nullbarhet kan ikke leses ut av katalogen; den må måles.** `information_schema.columns`
   svarer `is_nullable = 'YES'` for *hver* kolonne i et view — PostgreSQL gjør ingen
   nullbarhetsanalyse gjennom views. Den samme visningen kollapser dessuten hver array-kolonne
   til `data_type = 'ARRAY'` og taper elementtypen, som er nettopp det TypeScript-siden må vite
   for å skille `string[]` fra `number[]`. Begge begrensningene er festet som egne assertions
   framfor å stå som en kommentar ingen kontrollerer: skulle en framtidig PostgreSQL-versjon
   begynne å svare presist, feiler de, og da er probe-fiksturen ikke lenger den eneste veien.
   Typen leses derfor med `format_type()` fra `pg_attribute`.

3. **Nullbarheten måles på tre probe-former.** Filen publiserer sitt eget innhold inne i
   transaksjonen og ruller alt tilbake, som 260 og 290 — godkjenningen utføres av en aktør som
   opprettes der, slik at ingen fiktiv godkjenning blir stående (§12 i Constitution).
   Formene er valgt for å spenne ut kontrakten:

   | Form | Hva den demonstrerer |
   |---|---|
   | rik | hver valgfri kolonne bærer verdi; ekstraksjonen trekkes tilbake *etter* publisering, fordi gaten G6 nekter å publisere et underkjent grunnlag |
   | minimal | hver valgfri verdi utelatt, på påstand, evidensfunn og kilde; deterministisk faktum, så hele certainty-blokken er fraværende og ikke bare tom |
   | peker | publiseringspekeren flyttet utenom den kontrollerte operasjonen, som er den dokumenterte grunnen til at `published_at` og `last_reviewed_at` kan være NULL |

   Påstanden som kontrolleres er en `set_eq` i begge retninger: nøyaktig kontraktens nullbare
   kolonner er NULL i minst én probe-rad. En kolonne som blir nullbar dukker opp på venstre
   side; en nullbarhetspåstand uten dekning blir stående alene på høyre. En andre `set_eq`
   krever at hver kolonne bærer verdi et sted — uten den ville en kolonne som *alltid* er NULL,
   et uttrykk koblet til feil sted, passert så lenge kontrakten kalte den nullbar.

   Cellene hentes med `jsonb_each` over hele raden framfor kolonne for kolonne. Settet er da
   utledet av radens egen form, og en kolonne kan ikke glemmes.

4. **Hva målingen ikke beviser, og hva som derfor står igjen som gjeld.** En kolonne som blir
   nullbar fordi joinen, uttrykket eller projeksjonen endres, går NULL i den minimale raden og
   fanges. En basiskolonne som stille mister sin `NOT NULL`, fanges ikke: probe-fiksturen
   navngir kolonnen i sin `insert` og fortsetter å sette en verdi. Det er ført som gjeld i
   §74.7, og erstatter den gamle posten om at kontrakten ikke var kontrollert i det hele tatt.
   Kolonnenavn og kolonnetyper er derimot uttømmende dekket, i begge retninger.

5. **`number` er ett begrep i TypeScript og tre i SQL.** SQL-typen bestemmer hvilke skrevne
   TypeScript-typer som er tillatt, og `integer`, `bigint` og `numeric` tillater alle `number`.
   Det er ikke en slapphet: språket har ikke skillet, og kontrakten kan ikke påstå et skille
   den ikke kan holde. Presisjonen ligger i SQL-typen, som pgTAP-filen kontrollerer mot
   katalogen. En SQL-type kontrakten ikke kjenner kaster framfor å gli forbi.

6. **Typene leses fra AST-en, ikke fra typecheckeren.** `Uuid`, `Timestamptz`, `DateText` og
   `IntervalText` er alle alias for `string`. En typechecker ville løst dem opp og mistet
   nettopp skillet kontrakten handler om — en `uuid` er ikke en `date`. `ts.createSourceFile`
   parser filen uten å typesjekke den, og medlemmets annotasjon leses som skrevet. At de fire
   faktisk *er* alias for `string`, og at de lukkede vokabularene er `(typeof X)[number]` over
   en `as const`-liste, utledes fra samme fil framfor å listes opp — et nytt vokabular blir da
   gjenkjent uten en endring to steder.

7. **Kartet fra view til radtype leses ut av `Database`-typen.** Det er ikke skrevet ned i
   testen. Et nytt view i kontrakten må derfor også være erklært for supabase-js for at
   kontrollen skal gå opp, og et view som fjernes fra `Database` uten å fjernes fra kontrakten
   slår ut på samme måte.

8. **En arvet påstand rettet: «de åtte lukkede unionene» var fjorten.** Gjeldsposten som nå er
   erstattet sa at `tests/api-vocabularies.test.ts` kontrollerer «hver av de åtte lukkede
   unionene». Filen kontrollerer fjorten. Tallet åtte hører til §74.15 punkt 4, der det er
   riktig: åtte er antallet vokabularer *evidensvisningen forgrener på*, og som derfor fikk
   kjøretidskontroll. De to tallene hadde glidd sammen. Feilen er av samme klasse som de sju
   §74.8 og §74.18 beskriver, og ble funnet ved å telle `export const`-listene i `api.ts` —
   ikke ved å lese setningen på nytt.

9. **Mutasjonstesting, og to feller harnessen gikk i.** 44 mutasjoner er innført og 42 drept: mot
   kontraktslisten (navn, type, rad fjernet, rad lagt til, nullbarhet snudd begge veier,
   `date` forvekslet med `timestamptz`, array skrevet som skalar), mot probe-fiksturen
   (pekerraden fjernet, tilbaketrekkingen slått av, `evidence_gap` tømt, kildeversjonen
   fjernet, DOI-en fjernet, testvirkestoffet gitt en ATC-kode), mot viewene og granten i
   migrasjonene (kolonne omdøpt, kolonnetype endret, kolonne gjort alltid NULL, `left join`
   gjort til `join`, ny kolonne lagt til, kolonnegrant fjernet), mot radtypene i `src/types/`
   (egenskap omdøpt, slettet, lagt til, `| null` fjernet og lagt til, alias brutt, vokabular
   gjort til bar `string`, view fjernet fra `Database`) og mot selve assertionene. De to som
   overlever er begge forstått: en bevisst no-op (` and true` føyd til en `where`-betingelse),
   som skal overleve og bekrefter at harnessen ikke rapporterer drap den ikke har gjort; og en
   flytting av den minimale påstanden til et virkestoff med ATC-kode, som overlever fordi
   pekerpåstanden dekker `atc_codes` NULL uansett — den skarpere mutasjonen, som gir
   *testvirkestoffet* en ATC-kode, dreper testen. Harnessen avviste i tillegg en identisk
   erstatning som no-op og tre mønstre med null treff som tvetydige, framfor å telle dem som
   kjørte mutasjoner.

   **Og forutsetningen, ikke bare implementasjonen:** `tests/api-columns.test.ts` hviler på at
   assertion 3 i pgTAP-filen faktisk binder kontrakten til databasen. Slettes den, passerer
   TypeScript-siden mens kjeden er brutt. Mutasjonen ble innført, og pgTAP feiler høyt —
   `plan(11)` stemmer ikke lenger med antall kjørte assertions. Justeres planen med, endrer
   totalen seg, og `scripts/verify-counts.sh` slår ut mot §74.2. Kjeden er dermed lukket i
   begge ledd.

   To feller kostet tid, og begge er verdt å kjenne for neste mutasjonskjøring:

   - **`git checkout --` gjenoppretter ikke en usporet fil.** De to nye filene var ennå ikke
     lagt til i indeksen, så gjenopprettingen feilet stille og lot mutasjonen bli stående.
     Neste mutasjon målte da mot en rød grunnlinje — nøyaktig den tilstanden der *hver*
     mutasjon rapporterer seg som drept. Grunnlinjekontrollen fanget det og avbrøt.
     Harnessen kopierer nå filene til et sikkerhetskopi-katalog framfor å stole på git.
   - **Rå `psql` feiler ikke på en plan som ikke stemmer.** `pg_prove`, som
     `supabase test db` bruker, behandler «Looks like you planned 11 but ran 10» som en feil;
     `psql -f` skriver den som en kommentar og avslutter med 0. Et lokalt harness som bare
     teller `^not ok` er derfor blindt for en slettet assertion. Det var nettopp den
     mutasjonen som skulle måles, og den så ut til å overleve til harnessen ble rettet.

---

### 74.20 Hva autorisasjonen av redaktøren innførte

`db: authorize the named qualified editor` er migrasjon 005b. Den fullfører det 005a bevisst
lot stå åpent: aktørraden knyttes til redaktørens brukerkonto, og `reviewer`-rollen tildeles.
Den oppretter ingen tabell og ingen enum-type. Den legger til én funksjon og skriver to rader
— i miljøer der brukerkontoen finnes.

**Migrasjonen er miljøavhengig, og det er valget §74.18 tok.** `workflow.user_roles.user_id`
er `NOT NULL` med fremmednøkkel til `auth.users`. Kontoen finnes bare i det hostede
prosjektet; CI og lokal utvikling starter en fersk stack uten den. «Vei a» gjør koblingen
betinget av at kontoen finnes, framfor å dikte opp en konto lokalt eller å holde
rolletildelingen utenfor de versjonerte migrasjonene. Prisen i tabellen der — at CI ellers
aldri ville kjørt den grenen som faktisk kjører i produksjon — er betalt på tre måter, og de
henger sammen:

1. **Raden uteblir ikke i stillhet.** Mangler kontoen, returnerer funksjonen statusen
   `account_missing` og gir i tillegg en synlig `notice` i utdataene fra `supabase db push`
   og `supabase db reset`. Det samme gjelder de to andre tilstandene der funksjonen bevisst
   ikke skriver, `role_not_yet_valid` og `role_ended`.

2. **Logikken ligger i én navngitt funksjon, ikke som løse setninger i migrasjonsfilen.**
   `workflow.ensure_named_editor_authorization()` er det ene stedet koblingen og tildelingen
   er beskrevet, og både migrasjonen og testen kaller den. Alternativet — å skrive setningene
   rett i filen og la testen gjenta dem — ville gitt to påstander som kan drive fra
   hverandre, og testen ville da kontrollert en kopi framfor produksjonsveien. Det er samme
   form som kolonnekontrakten i §74.19 punkt 2, av samme grunn.

3. **Begge grenene kjøres i CI.** `350_editor_authorization_test.sql` kaller funksjonen i
   migrert tilstand og krever `account_missing` og at ingenting skrives, oppretter så kontoen
   inne i transaksjonen som rulles tilbake og kjører hele produksjonsveien: kobling,
   tildeling, auditrad, idempotens og virkningen på kvalifikasjonskontrollen.

**Funksjonen blir stående, og det er en del av vei a.** Koblingen kan bli stående ugjort i et
miljø der kontoen kommer senere. Da skal den kunne fullføres med ett kall til, ikke med en ny
migrasjon som bærer en andre kopi av logikken. Funksjonen tar ingen parametere: både kontoens
`uuid` og aktørens `actor_key` er konstanter i kroppen, så den kan bare gjøre denne ene
tildelingen. En parameterisert utgave ville vært en generell «gi hvem som helst
reviewer»-funksjon — en rettighetseskalering med et vennlig navn. `EXECUTE` er trukket fra
`PUBLIC`, og klientrollene har uansett ikke `usage` på `workflow`.

**Tre vakter, fordi en betinget migrasjon har flere måter å ta feil på enn en ubetinget:**

- Mangler aktørraden fra 005a, feiler funksjonen høyt med `no_data_found`. Uten den vakten
  ville en brutt migrasjonskjede sett ut som «kontoen manglet», altså som den normale,
  forventede grenen.
- Peker aktøren allerede på en *annen* brukerkonto, feiler funksjonen med
  `restrict_violation`. Uten den ville rollen blitt tildelt en konto som ikke er bundet til
  redaktøraktøren — en rettighet uten den attribusjonen den hviler på, og
  `provenance.freeze_actor_identity()` ville uansett nektet å flytte koblingen etterpå.
- Et andre kall tildeler ikke rollen på nytt. Uten den vakten ville
  `user_roles_no_overlapping_grant_excl` avvist kallet, og «kjør den én gang til i miljøet der
  kontoen finnes» ville ikke vært en vei.

**Selvtildelingen står i raden, ikke i en kommentar.** Beslutningen ble tatt i §74.17 punkt 3:
`granted_by_actor_id` peker på redaktørens egen aktør, fordi alternativet ville gjort en
KI-aktør til opphavet til et menneskes faglige godkjenningsrett (§10, §12). Ingen `CHECK`
forbyr selvtildeling, så `grant_reason` er hele sikringen. Testen krever at ordet
«Selvtildeling» står *først* i begrunnelsen og ikke bare et sted i den: et treff hvor som
helst i feltet ville også slått ut på en benektelse av det (§74.16-lærdommen om ordlyd).
`scope_id` er `NULL` — «uten avgrensning», ikke «ukjent avgrensning».

**Hva raden ikke gjør.** Den åpner ikke publiseringsgaten. G4/G5, G8/G9 og G13 er urørt, og
assertion 14 prøver det framfor å påstå det: gaten stopper fortsatt på den manglende
ekstraksjonsverifikasjonen. Den lukker heller ikke governance-hullet fra §74.17 —
kompetansekravet for reviewer-scope er fortsatt udefinert, og redaktøren er utpekt av seg
selv. Det står i `grant_reason` framfor å bli borte.

**220 er justert, ikke omgått — og hand-offen inn hit tok feil om hvordan.** Hand-offen sa at
tre assertioner i `220_provenance_seed_test.sql` ville bli røde, og at den negative
throws_ok-testen måtte erstattes fordi godkjenningen etter migrasjonen ville blitt avvist av
en annen grunn. Det stemmer ikke for vei a: i CI finnes ikke kontoen, migrasjonen skriver
ingenting, og alle tre assertionene er like sanne som før. Suiten ble kjørt med migrasjonen på
plass og uten en eneste endring i 220 — 1109 av 1109 passerte. **Dette er niende gang en
påstand som ble ført videre fra en hand-off eller en gjeldspost, har vært feil** (§74.4,
§74.8, §74.18). Den ble funnet ved å kjøre suiten framfor ved å lese setningen på nytt.

**Men den riktige justeringen var en annen, og den var viktigere.** At assertionene i 220
fortsatt er sanne, er nettopp problemet: de ville vært like sanne om migrasjon 005b aldri
hadde kjørt. En påstand om at noe ikke finnes, sier ingenting om koden som valgte å ikke
skrive det. Derfor binder assertion 1-3 i 350 den negative grenen til selve funksjonen ved å
*kalle* den og kreve at kallet ikke skriver noe. 220 beholder sine assertioner om tilstanden
og sier nå i klartekst hva de ikke dekker.

**Beslutningen om `changes_requested` framfor `approved`.** Assertion 13 er speilbildet av den
negative testen i 220: den samme handlingen som avvises uten brukerkonto, skal gå gjennom med
konto og rolle. Beslutningen som registreres er likevel `changes_requested`.
`workflow.enforce_reviewer_qualification()` leser verken beslutningstype eller utfall, så
assertionen blir ikke svakere av det — mens en `approved` ville vært en registrert faglig
godkjenning uten at noen har gjennomgått noe. At transaksjonen rulles tilbake, gjør den ikke
mindre fiktiv mens den står (`ANTIDEP_CONSTITUTION.md` §12).

**Hva som ble verifisert.** Migrasjonene er kjørt fra bunnen av og hele pgTAP-suiten er kjørt
mot en lokal PostgreSQL 16 med pgTAP; Docker-registryene svarer 403 gjennom egress-proxyen, så
`npx supabase start` er ikke tilgjengelig, og CI kjører den ekte stacken. Grunnlinjen før
endringen var 1109 passerende assertions, etter endringen 1136, uten `not ok`, uten planavvik
og uten `ERROR`. `npm run lint`, `npm run format:check`, `npm run typecheck`, `npm run test`,
`npm run build` og `./scripts/verify-counts.sh` er kjørt og passerer.

Trettifem mutasjoner er innført én om gangen — tjueni i SQL, seks i planens tallpåstander — og
trettifire fanges. Den som overlever er `raise notice` degradert til `raise debug`: pgTAP kan
ikke observere en `notice`, så den halvdelen av kravet i §74.18 er ikke maskinelt kontrollert.
Det er registrert som gjeld i §74.7 framfor å bli stående som en kommentar. Statusen
funksjonen returnerer, er den halvdelen som *er* kontrollert, og den er nettopp derfor et
returnert felt og ikke bare en `notice`.

**Vaktposten er lukket i begge ledd, som i §74.19.** Fjernes en assertion fra
`350_editor_authorization_test.sql` uten at planen justeres, feiler pgTAP på «Looks like you
planned 27 tests but ran 26». Justeres `plan()` med, blir pgTAP stille — og da slår
`scripts/verify-counts.sh` ut mot §74.2, fordi summen av `plan(N)` ikke lenger er 1136. Begge
utveier er stengt, og det er prøvd og ikke antatt.

**Den viktigste mutasjonen traff forutsetningen, ikke implementasjonen.** Assertion 13 hviler
på at rolletildelingen er det som gjør kvalifikasjonskontrollen tilfreds. Den påstanden er
lånt hvis ingenting håndhever at rollen er *nødvendig* — en `lives_ok` passerer like godt om
kravet ikke finnes. Rollekravet i `workflow.enforce_reviewer_qualification()` ble derfor slått
av i migrasjon 005, og `190_workflow_constraints_test.sql` feilet på fem assertioner, blant
dem «editor- og admin-rollene gir ikke faglig godkjenningsrett». En variant der `editor` også
kvalifiserte, ble fanget av de samme. Begge ledd er dermed lukket: at rollen åpner kontrollen,
er prøvd her; at den er nødvendig for å åpne den, er prøvd i 190.

**Reviewen fant en feil i «allerede tildelt», og den var reell.** Første utgave av
funksjonen leste en eksisterende tildeling som `valid_to is null`. `workflow.user_roles` er
ikke et flagg, men en gyldighetsmodell: intervallet er halvåpent, og `valid_to` kan være satt
allerede ved tildeling som en planlagt utløpsdato. Tre lovlige tilstander ble derfor håndtert
feil, og alle tre er reprodusert mot databasen før de ble rettet:

| Tilstand | Hva som skjedde | Hva som skjer nå |
|---|---|---|
| Tidsavgrenset, men gyldig nå | Raden ble lest som fraværende, en ny tildeling forsøkt skrevet, og `user_roles_no_overlapping_grant_excl` avviste den. Funksjonen feilet i stedet for å svare — en `supabase db push` ville stoppet | `already_authorized`, ingenting skrives |
| Begynner å gjelde senere | `already_authorized`, mens null tildelinger faktisk var gyldige. En autorisasjonskontroll som svarer «autorisert» om noe som ikke gjelder | `role_not_yet_valid`, ingenting skrives |
| Avsluttet | `authorized`: rettigheten ble stille gjeninnført, og tilbakekallingen omgjort av en migrasjonskjøring | `role_ended`, ingenting skrives |

**Den avsluttede tildelingen var den farligste, og valget der er bevisst.** `DATABASE_ARCHITECTURE.md`
§46 krever at en rettighet skal kunne tilbakekalles umiddelbart, og en tilbakekalling som en
rutinemessig `supabase db push` omgjør, er ingen tilbakekalling. `workflow.freeze_role_grant()`
sier det samme om modellen: en gjeninnføring er en ny tildeling med sin egen begrunnelse — og
en slik begrunnelse kan ikke dikte seg selv opp i en bootstrap. Funksjonen rapporterer derfor
og lar et menneske avgjøre. Det er også det mest reversible: å nekte kan et menneske overstyre,
å gjeninnføre i stillhet kan ingen oppdage.

Returverdiene er utvidet fra tre til fem, og bare `authorized` skriver noe. Presedensen mellom
dem er skrevet ut i funksjonen framfor å falle ut av rekkefølgen på tre uavhengige kontroller:
en løpende tildeling ved siden av en avsluttet betyr at rettigheten gjelder, og det motsatte
svaret ville vært feil på den farligste måten en autorisasjonskontroll kan ta feil.

Gyldighet måles med `statement_timestamp()` og ikke med `now()`. §74.6 ber uttrykkelig den som
skriver ny autorisasjons- eller gyldighetslogikk om å lese skillet først: `now()` er
transaksjonens starttidspunkt, så en tildeling som trådte i kraft mens transaksjonen løp, ville
blitt lest som «gjelder ikke ennå» så lenge transaksjonen varte. Assertion 23 gjør vinduet
deterministisk med `pg_sleep` framfor å hvile på at to setninger tilfeldigvis får ulike
tidsstempler.

To hull til ble funnet av mutasjonstestingen og ikke av reviewen: uten `scope_id is null` og
`role_code = 'reviewer'` i oppslaget ville en *avgrenset* reviewer-tildeling eller en
`editor`-tildeling blitt lest som «allerede autorisert», og redaktøren ville stille sittet igjen
med en smalere rettighet enn migrasjonen skal gi. Begge har nå hver sin assertion.

**En sjette felle for mutasjonsharnessen, funnet her.** `F2` — å slå av vernet mot at en
avsluttet tildeling gjenåpnes — rapporterte seg først som overlevende. Mutasjonen traff
definisjonen i migrasjon 005, men migrasjon 008 gjør `create or replace` på den samme
funksjonen, så den muterte definisjonen var død kode. **En mutasjon av en definisjon en senere
migrasjon erstatter, er en stille no-op som ser ut som et hull i testdekningen.** Kontrollen er
å lese `prosrc` fra `pg_proc` og bekrefte at mutasjonen faktisk står i den lastede kroppen.
Mot den gjeldende definisjonen ble mutasjonen drept.

**Og en syvende: harnessen gjenopprettet filene, men ikke databasen.** Etter siste mutasjon i en
batch lå den muterte funksjonen fortsatt i basen, og neste kjøring målte mot den. To assertioner
så ut til å feile mot kode som var korrekt på disk. Gjenopprettingen må kjøre `reset` til slutt,
ikke bare skrive filene tilbake.

**Hva som gjenstår.** Milepæl B mangler fortsatt fire ting (§74.4). Den første venter ikke
lenger på kode, men på at migrasjonene kjøres mot det hostede prosjektet — en egen oppgave som
hører hos prosjekteieren (§74.18). De neste to, ekstraksjons- og claim-verifikasjonene, kan
være agentproduserte så lenge §10 og §11 holdes; den fjerde, godkjenningen, kan ikke.

### 74.21 Hva den autentiserte leseveien innførte

`db: expose the caller's own actor and roles` er migrasjon 007b. Den utvider api-lesemodellen
fra §24 slik 007a gjorde, og står derfor utenfor den planlagte rekken. Den oppretter to views,
to RLS-policyer og to kolonnegrants. Den oppretter ingen tabell, ingen enum-type og ingen
funksjon, og den skriver ingen rad.

**Hvorfor akkurat denne, og hvorfor nå.** «Manuell adminflyt» er den ene leveransen §29 lister
for Slice 1 som ikke er bygget, og den kan ikke begynne noe sted: hver eneste skjerm i den må
først kunne svare på «hvem er jeg, og hva har jeg lov til?». Fram til nå kunne ingen klient
svare på noen av delene. `workflow.user_roles` og `provenance.actors` var begge helt stengt —
ingen grant, ingen policy, default deny — og det er fortsatt riktig for alt annet enn kallerens
egne rader. Migrasjonen er derfor det minste defensive førstesteget: en ren lesevei, ingen
skrivevei, ingen ny rettighet. Den gjør bare en rettighet som allerede finnes, lesbar for den
som har den.

**To spørsmål, to views, og det er en kardinalitetsbeslutning.** En kaller har null eller én
aktør, og null til mange rolletildelinger. Slått sammen til ett view måtte identiteten enten
forsvinne når det ikke finnes noen rolletildeling — og et tomt svar sier da ingenting om
aktøren, som er nøyaktig feilen §74.14 punkt 6 beskriver — eller bæres som en array. To views
gir i stedet hver sitt tomme tilfelle med entydig betydning:

```text
api.my_actor  tom   ingen aktørrad er knyttet til denne brukerkontoen
api.my_roles  tom   kalleren har ingen rolletildeling som gjelder nå
```

Ingen av dem svarer på det sammensatte spørsmålet «kan jeg utføre handling X». Det er
adminflytens jobb, og den bygges over disse to. En avledet «du har lov»-verdi her ville flyttet
en autorisasjonsbeslutning inn i en projeksjon, og den ville uansett ikke vært den som gjelder:
skriveoperasjonene kontrollerer rettigheten selv, på sin egen setnings tidspunkt.

**Fire lås, og den fjerde er den som avgjør hva av raden som kan leses.** De tre første er de
samme som i §74.9: manglende schema-`usage`, RLS som radgrense, og bare `SELECT`. Den fjerde er
kolonnegranten fra §74.11 punkt 3, og her bærer den mer enn i 007a. Radene policyene slipper
gjennom inneholder også `grant_reason`, `granted_by_actor_id`, `end_reason` og aktørens
`description` og `retirement_note`. Ingen av dem er kallerens svar på «hva har jeg lov til» —
de er governance-tekst om beslutningen, skrevet for en revisor og ikke for innehaveren — og de
er utenfor granten.

**`anon` får ingenting, og det er et valg og ikke en forglemmelse.** Begge policyene gjelder
bare `authenticated`, og ingen av viewene er lesbare for `anon`. En uinnlogget kaller får
avslag framfor et tomt svar, fordi et tomt svar allerede betyr noe helt annet her.

**Eierskapet ligger i policyen, gyldigheten i viewet.** De to predikatene beskytter forskjellige
ting, og det avgjorde hvor de hører hjemme:

| Predikat | Hva det er | Hvor det ligger |
|---|---|---|
| `user_id = auth.uid()` | En sikkerhetsgrense. En kaller skal aldri se en annens rolletildeling | RLS, og gjentatt i viewet slik §74.9 gjentar publiseringspredikatet: hvert lag skal være korrekt alene |
| gyldig nå | En projeksjonsbeslutning. En avsluttet tildeling er kallerens *egen* historikk, ikke en annens data | Viewet. I RLS ville den låst en senere projeksjon av kallerens rollehistorikk ute av sin egen tabell |

**Gyldighetsmodellen er den samme som felte 005b, og den er behandlet deretter.**
`workflow.user_roles` er ikke et flagg: intervallet er halvåpent `[valid_from, valid_to)`, og
`valid_to` kan være satt allerede ved tildeling som en planlagt utløpsdato. Viewet spør derfor
om begge grensene, ikke om `valid_to is null`. Uten den nedre grensen ville en tildeling som
først begynner å gjelde senere blitt lest som gjeldende — en rettighet før den er gitt. Tiden
måles med `statement_timestamp()` og ikke `now()`, etter regelen i §74.6, og det er prøvd og
ikke bare påstått: fiksturen i `360_caller_authorization_test.sql` legger én tildeling som trer
i kraft og én som utløper *mens transaksjonen løper*, og gjør vinduet deterministisk med
`pg_sleep` framfor å hvile på at to setninger tilfeldigvis får ulike tidsstempler. Med `now()`
feiler begge, hver sin vei.

**To kolonner er utelatt fordi en databaseregel gjør dem informasjonsløse, og begge reglene
prøves framfor å telles.** Det er den formen §74.20 etablerte, og den er brukt igjen her:

1. `api.my_actor` projiserer ikke aktørtypen. `actors_auth_user_is_human_check` håndhever at
   bare et menneske kan ha en brukerkonto, så kolonnen ville hatt nøyaktig én mulig verdi for
   hver rad viewet kan vise. Testen forsøker å opprette en KI-aktør med brukerkonto og krever
   at databasen avviser det. Faller regelen bort, feiler testen — og da er kolonnen ikke lenger
   informasjonsløs, for da kan viewet skjule at kalleren er en KI-aktør.
2. `api.my_roles` projiserer ikke tildelingens `id`. Innenfor settet viewet viser, er
   `(role_code, scope_id)` allerede entydig: to tildelinger som begge gjelder nå ville
   overlappet i tid, og `user_roles_no_overlapping_grant_excl` forbyr det. Testen forsøker den
   overlappende innsettingen og krever `23P01`, og forsøker deretter den *avgrensede*
   tildelingen av samme rolle og krever at den går gjennom — avgrensningen er en del av nøkkelen
   og ikke en detalj ved siden av den.

**Vaktposten som ikke så kolonnegrant, ser den nå.** `030_conventions_test.sql` regel 8a og 8b
leste `pg_class.relacl`, som ikke bærer kolonnegrant; `pg_attribute.attacl` gjør det. Regelen
sluttet dermed å måle i det migrasjon 007a tok formen i bruk, uten å feile — en migrasjon kunne
åpnet en enkeltkolonne uten policy under, eller gitt en skriverett på kolonnenivå, og gått
gjennom. Begge grenene leser nå `attacl` i tillegg, og begge er selvtestet med et bevisst brudd
og med den konforme formen ved siden av, slik at reglene ikke kan være trivielt oppfylt ved å
flagge hvert kolonnegrant. Samme blindsone er rettet i `290_api_read_model_access_test.sql`:
inventaret over hvilke kanoniske tabeller `api` har åpnet, sa «tretten» mens seksten var åpnet,
fordi tre av dem bare er åpnet på kolonnenivå.

**Kolonnekontrakten måler nå fem views, og probe-radene er blitt eksplisitte om hvem som leste
dem.** De to nye viewene er ikke lesbare for `anon` og krever hver sin innloggede kaller — én
med en aktør som ikke er trukket tilbake og to tildelinger som til sammen dekker begge formene
av scope og sluttdato, og én med en tilbaketrukket aktør, slik at `retired_at` bærer verdi i
minst én rad. Cellene kan derfor ikke leses i én spørring. De materialiseres i stedet i en
temptabell under den rollen og med det tokenet som faktisk skal kunne lese dem, og sammenlignes
etterpå. Det er en innstramming: før ble cellene lest av en `set_eq` som tilfeldigvis kjørte som
`anon`. En ny assertion krever i tillegg at hvert view i kontrakten faktisk har bidratt med
celler — uten den ville et view som ingen probe-rad traff falt helt ut av begge sammenligningene,
og de to feilene ville pekt hver sin vei og lest som «kontrakten er for lang».

**Hva migrasjonen bevisst ikke gjør.** Den tildeler ingenting, endrer ingenting og oppretter
ingen aktør. En kaller uten aktørrad får et tomt `api.my_actor`, ikke en rad opprettet på
forespørsel: aktørregisteret er festepunktet for all attribusjon (`ANTIDEP_CONSTITUTION.md`
§14), og en aktør som oppstår fordi noen logget inn ville vært en identitet systemet selv fant
på. Skriveveien er urørt og forblir en kontrollert `SECURITY DEFINER`-funksjon
(`DATABASE_ARCHITECTURE.md` §43).

**To poster ført som gjeld (§74.7).** Et tomt `api.my_roles` skiller ikke en utløpt tildeling
fra en som aldri fantes, og `scope_id` kan ikke slås opp til en etikett. Begge er bevisste valg
med en pris, og prisen er skrevet ned framfor å bli oppdaget av den som bygger adminskjermen.

**Mutasjonstestet: 21 mutasjoner innført, 21 drept.** Tretten på migrasjonen — begge
policyene åpnet, `anon` sluppet inn på policy og på view, `grant_reason` og aktørens
`description` lagt til i kolonnegranten, hver av de to gyldighetsgrensene fjernet,
`statement_timestamp()` byttet til `now()`, hvert av de to viewenes eget eierskapspredikat
fjernet, `scope_type` projisert som konstant `NULL`, og `security_invoker` fjernet. To på de
utvidede grenene i regel 8a og 8b, tre på TypeScript-siden, og tre på kolonnekontrakten. Hver
av dem er kontrollert mot hvilken assertion som faktisk felte den, ikke bare mot at *noe*
feilet — en mutasjon drept av en urelatert assertion er et svakere signal enn det ser ut som.
De to som er verdt å nevne særskilt: `valid_to is null` — feilen fra 005b — felles av at den
avgrensede tildelingen med planlagt utløp forsvinner fra `api.my_roles`, og `now()` felles av
begge de to `pg_sleep`-testene, hver sin vei.

**Hva som gjenstår.** Milepæl B mangler fortsatt de samme fire tingene (§74.4). Denne
migrasjonen lukker ingen av dem, og den er heller ikke ment å gjøre det: den åpner det første
leddet i adminflyten, som er der de tre siste faktisk kan utføres.

---

### 74.22 Hva innlogging og min tilgang innførte

`feat: add sign-in and my access` er Steg 1 av «manuell adminflyt» (§29): innlogging, og et
svar på «hvem er jeg, og hva har jeg lov til?», bygget over den autentiserte leseveien
migrasjon 007b åpnet (§74.21). Ingen migrasjon: viewene og grantene fra 007b er nok for Steg 1.
Steg 2 — skriveveien/RPC-laget (DATABASE_ARCHITECTURE.md §43, §48) — og Spor 2 —
verifikasjon/godkjenning — hører til senere PR-er, og er ikke rørt her.

**Én side, ikke to.** `/access` («Min tilgang») er den samme adressen for en uinnlogget og en
innlogget kaller. En uinnlogget kaller ser innloggingsskjemaet der en innlogget kaller ser
svaret, og siden selv — ikke en ruteforgrening — avgjør hvilket av de to som vises
(`src/app/pages/AccessPage.tsx`). To sider, én for hver tilstand, ville latt ordlyden på de to
drive fra hverandre på nøyaktig den måten §74.16 og §74.20 allerede har dokumentert at skjer
når samme sannhet skrives to steder.

**FELLE 1 — sesjonen er en inngang til spørringen, ikke en omgivelse rundt den.**
`useReadModel()` kjører bare på nytt når spørringens referanse endres, og innlogging endrer
ingen parameter på `fetchCallerActor`/`fetchCallerRoles` — samme funksjon, samme referanse.
Uten et eksplisitt grep ville siden fortsatt vist svaret fra før innlogging. Løsningen er
strukturell, ikke en sesjonsnøkkel i en `useCallback`-avhengighet: `AccessPage` forgrener på
innloggingsstatus (`useAuthSession()`, ny hook i `src/app/use-auth-session.ts`, som abonnerer på
`client.auth.onAuthStateChange()`), og komponenten som faktisk kaller de to lesefunksjonene
finnes ikke i treet før kalleren er innlogget. En innlogging bytter dermed hele undertreet, og
en førstegangsmontering er per konstruksjon en frisk spørring — ingen nøkkel å holde i sync.
Testet direkte: `use-auth-session.test.tsx` beviser at hooken oppdager en innlogging og en
utlogging via abonnementet alene, og `AccessPage.test.tsx` beviser at ingen spørring mot
`api.my_actor`/`api.my_roles` kjører før innlogging, og at begge kjører rett etter — mutert ved
å la komponenten montere uforgrenet, som felte fire av ti tester i den filen.

**FELLE 2 — fire tilstander, ikke tre.** `ReadModelResult` er `ok | empty | error`, og
`useReadModel()` legger til `loading`. En uinnlogget kaller mot `api.my_actor` ville fått 42501
fra RLS og blitt lest som `error` — feil beskjed, og nøyaktig den samme sammenblandingen av feil
og fravær §74.12 punkt 1 allerede forbyr på klinikerflaten. Den unngås strukturelt av samme
grep som løser FELLE 1: spørringene kjører aldri før kalleren er innlogget, så en uinnlogget
kaller ser aldri `error` — den ser innloggingsskjemaet. De fire tilstandene `AccessPage` skiller,
med hver sin ordlyd:

```text
ikke innlogget            innloggingsskjemaet
innlogget, ingen aktør    «Kontoen din er ikke knyttet til en person i Antidep»
innlogget, ingen roller   «Du har ingen rettighet nå»
feil                      «Antidep fikk ikke hentet informasjon om tilgangen din»
```

Aktør og roller er to uavhengige spørringer, og siden venter bevisst på at begge er ferdige før
den viser noe annet enn «laster»: et svar som konkluderte «ingen aktør» mens rollene fortsatt
lastet, ville vært en forhastet konklusjon presentert som endelig.

**FELLE 3 — egen modul, ikke `published-read-model.ts`.** Kallerens egne roller er ikke
publisert kunnskap og har en annen tomhetssemantikk: en tom `api.my_actor` betyr «ingen aktør
er knyttet til denne kontoen», en tom `api.my_roles` betyr «ingen rettighet nå» — to navngitte
tomhetsformer, ikke lesemodellens ene generiske `empty`. Fetch-funksjonene ligger derfor i en ny
modul, `src/lib/caller-authorization.ts`, med sin egen resultattype
(`CallerActorResult`/`CallerRolesResult`, med variantene `ok | no_actor | error` og
`ok | no_roles | error`). Sorteringsdoktrinen fra `published-read-model.ts` gjelder heller ikke:
rekkefølgen på en persons roller er ingen vekting, bare en stabil rekkefølge mellom kall
(sortert på `role_code`). `useReadModel()` selv er generalisert til å være generisk over
resultattypen — `Result` utledes nå direkte av spørringens returtype, og trenger ingen egen
`Row`-parameter — slik at hentelogikken (klientoppslag, stale-response-vakten fra §74.14 punkt
4, feilfanging) er felles uten at de to modulenes betydninger flates ut. Ingen eksisterende
kallsted i `published-read-model.ts`-familien trengte å endres: `Result` faller tilbake til
`ReadModelResult<Row>` når ingenting annet er oppgitt.

**FELLE 4 — ingen «du har lov»-boolean i klienten.** Viewene svarer på hva kalleren HAR, ikke
hva kalleren KAN — det sier migrasjon 007b eksplisitt (§74.21), og klienten skal ikke regne ut
en autorisasjonsbeslutning en projeksjon ikke bærer. En tilbaketrukket aktør
(`retired_at` satt) har fortsatt sine rolletildelinger i `api.my_roles`, men
`knowledge.assert_publisher_authorized(uuid, uuid)` avviser den likevel på sitt eget tidspunkt.
Siden viser derfor rollene *og* et eksplisitt varsel side om side når aktøren er tilbaketrukket
— aldri ved å skjule rollene, som ville vært en stille og feil «ingen rettighet», og aldri uten
varselet, som ville lovet en handling systemet avviser.

**To gjeldsposter fra §74.7 er bevisst ikke utvidet.** `api.my_roles.scope_id` kan ikke slås opp
til en etikett, og skiller ikke en utløpt tildeling fra en som aldri fantes. Siden viser
«avgrenset til et bestemt klinisk begrep» uten navnet, med samme ordlydsmønster som
`superseded_by_source_id`-merknaden på kildesiden (§74.16 punkt 5): en identitet klienten ikke
kan slå opp, er ikke et svar. Ingen ny historikk-projeksjon er bygget for Steg 1.

**Nettleserverifisering.** Chromium (`/opt/pw-browsers/chromium`) kjørt headless med
devtools-protokollen direkte over Node 22 sin innebygde `WebSocket` — Playwright er ikke
installert. En midlertidig `preview.html`/`src/preview-main.tsx` rendret `AppLayout` i en
`MemoryRouter` på `/access` med `fakeClient()`, styrt fra en query-parameter, og dekket alle
tilstandene fra FELLE 2 og tilbaketrekkingsvarselet fra FELLE 4 på både mobil- (390px) og
skrivebordsbredde (1280px) — 14 kombinasjoner, ingen `Runtime.exceptionThrown` og ingen
konsollfeil i noen av dem. Innloggingsskjemaet, et avvist forsøk og utlogging ble i tillegg
øvd direkte i nettleseren (skrevet inn med den samme native-verdisetter-teknikken React
kontrollerte felt krever, ikke bare i jsdom), og viste seg identisk med den automatiserte
testpakken. Begge filene er slettet før commit, som instruert.

**Mutasjonstestet.** FELLE 1, FELLE 2 og FELLE 4 er hver mutert og bekreftet fanget: montering
uforgrenet av innloggingsstatus felte fire av ti tester i `AccessPage.test.tsx`; å behandle
`no_actor` som `error` felte den testen som ber om nettopp det skillet; å slutte å rendre
tilbaketrekkingsvarselet felte både den testen og testen som krever at varselet *ikke* vises
for en aktør som ikke er tilbaketrukket. Hele testpakken teller nå 771 passerende tester, opp
fra 740 ved sesjonsstart.

**Rettelse etter teknisk review.** `SignOutButton` kalte først `client.auth.signOut()` uten
`scope`. supabase-js sin standard er `'global'` — logger kalleren ut av *alle* enheter og
nettlesere kontoen er innlogget på, ikke bare denne fanen — en overraskende sideeffekt for en
knapp merket «Logg ut», og ikke et krav noe sted i denne planen. Rettet til
`signOut({ scope: 'local' })`. Faken i `test-support.tsx` registrerer nå det faktiske
`signOut()`-kallet, og en egen test krever `{ scope: 'local' }` — mutert til det opprinnelige
kallet uten `scope` og bekreftet at nettopp den testen feiler.

**Hva som gjenstår.** Steg 2 av adminflyten — den kontrollerte skriveveien admin-RPC-laget
(DATABASE_ARCHITECTURE.md §43, §48) — er ikke bygget. Spor 2 (verifikasjon og godkjenning) er
heller ikke rørt. Milepæl B mangler fortsatt de samme fire tingene den har gjort siden §74.4:
denne PR-en lukker ingen av dem, og er ikke ment å gjøre det.

---

### 74.23 Det hostede prosjektet er migrert, og `api` er eksponert

**Funnet, og det motsier §74.18.** Det hostede prosjektet er ikke tomt. Alle tretten
migrasjonene fra `main` er kjørt der og registrert i `supabase_migrations.schema_migrations`,
med nøyaktig de samme tretten versjonsnumrene og navnene som filene i `supabase/migrations/`.
Schemaene `api`, `catalog`, `knowledge`, `workflow`, `provenance` og `audit` finnes, og `api`
inneholder de fem viewene migrasjon 007, 007a og 007b oppretter. `supabase db push` hadde
dermed ingenting å pushe.

**Hva som er kontrollert, og hvordan.** Denne sesjonen leste tilstanden direkte fra
produksjonsdatabasen med Supabases Management-API og prosjektets access token, som
`read_only`-spørringer: migrasjonshistorikken, objektene per schema, og radtellingene under.
Det er første gang en påstand om det hostede prosjektet er lest fra prosjektet selv framfor
gjengitt fra et dashboardblikk. **Hvem som kjørte migrasjonene, og når, er ikke kjent herfra**
— repoet registrerer det ikke, og historikktabellen bærer bare versjon og navn. Det føres som
et åpent spørsmål, ikke som en antakelse.

**Feilen appen faktisk viste, var eksponeringen — ikke migrasjonene.** `Invalid schema: api`
kommer fra PostgREST, og Data API-ets `db_schema` i det hostede prosjektet var
`public,graphql_public`. Det er nøyaktig den manuelle synkingen §74.5 punkt 3 ber om, og som
§74.18 slo fast ikke var mulig ennå fordi `api` ikke fantes i menyen. Den forutsetningen falt
bort da migrasjonene ble kjørt. Verdien er nå satt til `api,graphql_public` — den samme
verdien `[api].schemas` i `supabase/config.toml` har hatt siden migrasjon 007, og `public` er
ute av eksponeringen begge steder. Endringen er gjort på det ene feltet gjennom
Management-API-et, ikke med `supabase config push`: forbudet mot den kommandoen står uendret,
men begrunnelsen for det er rettet — se «Forbudet mot `config push`» under.

**Grensen er prøvd etter endringen, ikke påstått.** Med publishable-nøkkelen og
`Accept-Profile` mot det hostede prosjektet:

| Forespørsel | Svar |
| --- | --- |
| `api.published_drugs`, `api.published_claims` | `200`, null rader |
| `api.my_roles` som `anon` | `42501 permission denied for view my_roles` |
| `catalog`, `knowledge`, `workflow`, `provenance`, `audit` | `PGRST106 Invalid schema`, «Only the following schemas are exposed: api, graphql\_public» |

Null rader er riktig svar og ikke en mangel: ingenting er publisert (§74.4). Avvisningen av
`anon` på `api.my_roles` er kolonn- og policygrensen fra migrasjon 007b som svarer — bare
`authenticated` har granten. De fem kanoniske schemaene avvises av PostgREST før noen
rettighetskontroll i det hele tatt, som §47 krever.

**Redaktørens autorisasjon tok den positive grenen i produksjon, og det lukker den første av
Milepæl B sine fire.** Aktørregisteret har tre rader, og `workflow.user_roles` har én:
`role_code = 'reviewer'`, uten scopebegrensning, uten sluttdato, gyldig nå og selvtildelt av
`human:peder-holman` — den selvtildelingen §74.17 punkt 3 valgte. Migrasjon 005b skriver bare
når kontoen finnes i `auth.users` (§74.18, §74.20), så raden er selve beviset for at kontoen
finnes der. §74.4 er rettet tilsvarende: **Milepæl B mangler nå tre ting**, ikke fire —
ekstraksjonsverifikasjonene, claim-verifikasjonene og selve godkjenningen.
`knowledge.publication_events` er tom, som ventet.

**Den pinnede CLI-en kan ikke brukes fra en agentsesjon, og det er miljøet og ikke prosjektet.**
`supabase` 2.115.0 kjører en Bun-kompilert binærfil (Bun 1.3.13). Dens `fetch` klarer ikke
TLS-håndtrykket gjennom sesjonens HTTPS-proxy: tunnelen settes opp (`200 Connection
Established`), og forbindelsen brytes deretter. Kontrollert ved å reprodusere feilen med samme
Bun-versjon mot samme URL, og ved at både Node og en nyere Bun lykkes med nøyaktig samme
forespørsel gjennom samme proxy. `supabase link` og `supabase db push` er dermed utilgjengelige
herfra; Management-API-et er ikke det. Dette er en egenskap ved agentmiljøet, ikke ved
CLI-pinningen, og skal ikke leses som en grunn til å endre den.

**Lærdom: en påstand om et system utenfor repoet må kontrolleres på brukstidspunktet.**
§74.18 førte funnet sitt med sin kilde — prosjekteieren i dashboardet — og det var riktig gjort.
Men ingen vaktpost i CI ser på det hostede prosjektet, så påstanden ble usann i det øyeblikket
noen kjørte migrasjonene, uten at noe sted i repoet merket det. Det er ikke et argument for å
legge til enda en påstand: det er grunnen til at neste oppgave som hviler på det hostede
prosjektets tilstand, må lese tilstanden på nytt før den handler.

**Autentiseringsoppsettet er rettet, og verdiene er lest tilbake.** Da denne oppdateringen
begynte, stod `site_url` på `http://localhost:3000`, listen over tillatte redirect-URL-er var
tom, og registrering var åpen for hvem som helst. Prosjekteieren har rettet alle tre i
dashboardet, og verdiene er lest tilbake fra prosjektet etterpå: `site_url` er
`https://antidep.vercel.app`, `uri_allow_list` er `https://antidep.vercel.app/**`, og
`disable_signup` er `true`. Innlogging i appen bruker bare passord (`signInWithPassword`) og
var aldri avhengig av URL-oppsettet; bekreftelses- og tilbakestillingslenker på e-post er det.

**Forbudet mot `config push` står — begrunnelsen for det er rettet.** §74.18 begrunnet forbudet
med fire konkrete forskjeller mot produksjon. De var slutninger, ikke avlesninger: ingen hadde
lest produksjonsverdiene da tabellen ble skrevet. Nå er de lest, 3. september 2026, gjennom
Management-API-et:

| Nøkkel i `config.toml` | Verdi i `config.toml` | Lest i produksjon | Hva et push ville gjort i dag |
|---|---|---|---|
| `auth.site_url` | `http://127.0.0.1:3000` | `https://antidep.vercel.app` | satt site URL til localhost |
| `auth.additional_redirect_urls` | `["https://127.0.0.1:3000"]` | `https://antidep.vercel.app/**` | erstattet den reelle redirect-URL-en |
| `auth.enable_signup` | `true` | registrering avslått | åpnet registrering igjen |
| `auth.minimum_password_length` | `6` | `6` | ingen forskjell |
| `db.network_restrictions.allowed_cidrs` / `_v6` | `["0.0.0.0/0"]` / `["::/0"]` | `0.0.0.0/0`, `::/0` | ingen forskjell i selve listene |

To av §74.18 sine fire rader beskrev altså en forskjell som ikke fantes — passordkravet og
nettverksgrensen er de samme på begge sider. Én rad var usann da den ble skrevet og er sann nå:
redirect-listen var tom 26. august, og et push ville ikke slettet noe; i dag ville det erstattet
den reelle URL-en. Og én forskjell tabellen ikke hadde, er den mest alvorlige: `enable_signup`
er `true` i `config.toml`, så et push ville åpnet registreringen prosjekteieren nettopp lukket.

**Hva som *ikke* er kontrollert, og hvorfor forbudet ikke hviler på tabellen.**
`db.network_restrictions.enabled` er `false` i `config.toml`, og hva et push gjør med selve
håndhevingen av nettverksgrensen — i motsetning til listene — er ikke lest og skal ikke gjettes.
Det samme gjelder resten av filen: `config.toml` har snaut to hundre nøkler, og bare de fem over
er sammenlignet. Hovedregelen er derfor ikke «disse radene er farlige», men den samme som før:
**`supabase config push` skal ikke kjøres før `config.toml` bevisst er gjort til en komplett og
korrekt produksjonskonfigurasjon**, nøkkel for nøkkel. Kommandoen pusher hele filen, og en fil
som er `supabase init`-standardene for en lokal stack, er ikke det. Enkeltinnstillinger settes i
dashboardet eller på det ene feltet gjennom Management-API-et.

**Røyktesten er kjørt, og den leser det samme som databasen.** Prosjekteieren logget inn på
`https://antidep.vercel.app` med redaktørkontoen og åpnet «Min tilgang». Siden viser aktøren
«Peder Holman» med `human:peder-holman`, og én rolle: `reviewer`, «Uavgrenset», gyldig fra
27. august 2026, «Ingen sluttdato er satt». Det er nøyaktig raden som ble lest fra
produksjonsdatabasen over, og datoen er migrasjon 005b sin egen (`20260827090000`). Dermed er
hele kjeden fra `auth.users` gjennom `provenance.actors` og `workflow.user_roles` til
`api.my_actor` og `api.my_roles` prøvd i produksjon, av en innlogget bruker, og ikke bare i
CI: innlogging, den autentiserte leseveien fra migrasjon 007b (§74.21) og klientflaten fra
§74.22 svarer alle som ventet.

**Hva som gjenstår.** Milepæl B mangler tre ting (§74.4): ekstraksjonsverifikasjonene,
claim-verifikasjonene og selve godkjenningen.

---

### 74.24 Hva steg 2 av adminflyten innførte

Steg 2 av «manuell adminflyt» (§29): «Editor oppretter Source» (§15), den kontrollerte
skriveveien migrasjon 007c åpner, og et skjema over den i klienten. Ikke noe mer av kjeden —
EvidenceItem, ClaimRevision, review og publisering hører til senere PR-er, én om gangen
(§51). Spor 2 (verifikasjon og godkjenning) er fortsatt urørt.

**Ett attribusjonshull ble funnet og lukket først (migrasjon 003a).** `knowledge.sources`
var det eneste kunnskapsobjektet uten `created_by_actor_id`: migrasjon 005 la kolonnen til på
`evidence_items`, `claims`, `claim_revisions`, `claim_evidence_links` og
`evidence_assessments`, men aktørraden den selv registrerte for `agent:evidence-extraction`
sier «Produserte kildene, kildeversjonene og evidensfunnene i migrasjon 003» — kildene var
alltid omfattet av den setningen, bare ikke av kolonnetillegget. Uten kolonnen ville
skriveveien enten latt en ny kilde mangle attribusjon eller måttet late som om en KI-aktør
skrev en rad et menneske faktisk opprettet. Migrasjonen legger kolonnen til, backfyller de to
seedede radene til samme aktør som resten av migrasjon 003, og utvider
`220_provenance_seed_test.sql` sin attribusjonskontroll til å dekke `knowledge.sources` også.

**`ALTER TYPE ... ADD VALUE` kan ikke brukes i samme fil som bruker verdien (migrasjon 008a).**
Prøvd direkte mot denne stacken, ikke antatt: et forsøk på å legge `source_created` til
`audit.event_operation` og utvide CASE-uttrykkene i samme migrasjonsfil feilet med `unsafe
use of new value … (SQLSTATE 55P04)` under `supabase db reset`, fordi migrasjonsløperen
sender hele filen som én transaksjon — ikke bare når filen selv inneholder en eksplisitt
BEGIN/COMMIT-blokk. Verdien måtte derfor legges til i en egen, ellers tom migrasjon som
committer alene, før migrasjon 007c kunne utvide `object_schema`/`object_table` og
`events_snapshot_shape_check` til å bruke den. Ingen tidligere migrasjon i Antidep hadde
utvidet en eksisterende enum-type; det har nå én, og feilmodusen er skrevet ned i migrasjonens
hodekommentar for den neste som trenger det.

**Aktøren utledes av `auth.uid()`, ikke oppgis som parameter.**
`knowledge.assert_publisher_authorized(p_publisher_actor_id, p_topic_concept_id)` (migrasjon
006) tar aktøren som parameter og kontrollerer at den stemmer med `auth.uid()` — det gir
mening der, fordi tre forskjellige operasjoner (publish/replace, withdraw, rollback) deler
samme kontrollfunksjon med samme signatur. `knowledge.assert_editor_authorized()` har bare én
kaller og ingen klientoppgitt verdi å kontrollere mot: attribusjonen for en ny kilde kan aldri
være noe annet enn kallerens egen aktør, så funksjonen slår den opp selv og returnerer den.
Det fjerner en hel feilklasse — en klient som ved en feil sender en annen aktørs id — uten å
tape noe en parameter ville gitt. En senere skrivevei som deler mønster med publiseringens tre
operasjoner kan fortsatt velge parameterformen; det er en avgjørelse for den PR-en.

**Editor-sjekken er bevisst ikke avgrenset til et klinisk begrep.**
`workflow.user_roles.scope_id` kan avgrense en tildeling til ett innholdsområde (§47), men en
Source er ikke selv om ett tema — den blir referert av evidensfunn som senere kan gjelde ulike
kliniske begreper. Det finnes derfor ingen `p_topic_concept_id` å kontrollere en avgrenset
tildeling mot, og `knowledge.assert_editor_authorized()` godtar enhver gyldig editor-tildeling,
avgrenset eller ikke. Alternativet — å kreve en uavgrenset tildeling — ble vurdert og valgt
bort: det ville i praksis krevd at enhver editor-tildeling var uavgrenset for at noen i det
hele tatt kunne opprette en kilde, og det er en strengere begrensning enn det skriveveien selv
trenger. En senere skrivevei som oppretter et objekt som *er* avgrenset (EvidenceItem knyttet
til et endepunkt, ClaimRevision under et klinisk begrep) skal ta stilling til scope på nytt.

**`p_source_type` og `p_publication_date_precision` er `text`, ikke enum-typene, i
parameterlisten — også dette prøvd direkte, ikke antatt.** Et første forsøk med
`knowledge.source_type`/`knowledge.date_precision` som parametertyper feilet over ekte HTTP
mot den lokale stacken med `permission denied for schema knowledge`, kastet før EXECUTE på
selve funksjonen engang ble kontrollert: PostgREST bygger et uttrykk som caster JSON-verdien
til parameterens deklarerte type, skrevet schemakvalifisert, og den casten evalueres i
kallerens egen sesjon — `authenticated` har ingen `usage` på `knowledge` (§47), uansett at
funksjonen selv er SECURITY DEFINER. Parametrene er derfor `text`, og castingen skjer i stedet
inne i `INSERT`-setningen, som kjører i funksjonens SECURITY DEFINER-kontekst. En ugyldig verdi
avvises fortsatt av databasen (`22P02`), bare ett steg lenger inn.

**Mutasjonstestet: fem mutasjoner på `knowledge.assert_editor_authorized()`, alle fanget av
nøyaktig den assertionen som påstår å teste dem.** Hver regel ble fjernet enkeltvis mot den
kjørende stacken og `370_source_creation_test.sql` kjørt på nytt:
aktør-finnes-kontrollen fjernet felte bare «en kaller uten aktørrad avvises eksplisitt»;
tilbaketrekkingskontrollen fjernet felte bare «en tilbaketrukket aktør avvises»;
`role_code = 'editor'`-filteret fjernet felte bare «reviewer-rollen gir ikke rett til å
opprette kilder»; `statement_timestamp()` byttet til `now()` felte begge de to
`pg_sleep`-testene i del 7, og ingen andre; og audittriggeren fjernet felte
strukturtesten («enhver innsatt kilde auditeres») og begge assertionene om den faktiske
auditraden. Ingen mutasjon feltes av en urelatert assertion — hver av de fem er sporet til
nøyaktig den påstanden som skal fange den.

**Ingen rollegate i klienten, samme doktrine som `AccessPage.tsx` sin FELLE 4.**
`CreateSourcePage.tsx` viser skjemaet til enhver innlogget bruker, ikke bare til en med
editor-rolle: `api.my_roles` svarer på hva kalleren HAR, ikke hva kalleren FÅR LOV TIL, og
skriveoperasjonen kontrollerer retten på sitt eget tidspunkt uansett. En bruker uten
editor-rolle ser skjemaet og et avvist forsøk med databasens egen forklaring, ikke en knapp
som er deaktivert på et løfte klienten ikke kan stå for. Innloggingssjekken alene er
strukturell, samme mønster som `AccessPage.tsx` sin FELLE 1: skjemaet finnes ikke i treet før
kalleren er `signed_in`.

**`/sources/new` kolliderer på tegnnivå med `sourcePath('new')`, og det er meningsløst å teste
bort.** Hvilken side adressen treffer avgjøres av at react-router selv rangerer det statiske
segmentet foran det dynamiske `:sourceId`, uavhengig av deklarasjonsrekkefølge i `App.tsx`.
Prøvd direkte i `App.test.tsx` framfor bare i `routes.test.ts`: en regresjon i rangeringen
ville sendt strengen «new» inn i `SourcePage` som om den var en uuid, og bare en full rendring
av ruteren kan fange det.

**Nettleserverifisering.** Chromium (`/opt/pw-browsers/chromium`) kjørt headless med
devtools-protokollen direkte over Node sin innebygde `WebSocket`, samme oppsett som §74.22. En
midlertidig `preview.html`/`src/preview-main.tsx` rendret `AppLayout` i en `MemoryRouter` på
`/sources/new` med en falsk klient, styrt fra en query-parameter, og dekket «ikke innlogget»,
det tomme skjemaet, en vellykket opprettelse (skjemaet fylt ut og sendt av rigget selv, med
Reacts native-verdisetter-teknikk) og en avvist opprettelse — på både mobil- (390px) og
skrivebordsbredde (1280px), pluss forsiden for å bekrefte at den nye navigasjonslenken finnes
der. Ingen konsollfeil og ingen kastet unntak i noen av dem. Begge filene er slettet før
commit, som instruert.

**To P2-funn fra den tekniske reviewen, rettet i samme PR.**

*1. Opphavet på en kilde var ikke vernet.* Migrasjon 003a la
`created_by_actor_id` til en **muterbar** tabell uten å verne den, mens migrasjon 005 hadde
slått fast prinsippet i én setning — «opphavet er en del av identiteten og skal ikke kunne
omskrives i ettertid» — og håndhevet det på `knowledge.claims`, den andre muterbare
kunnskapstabellen. Attribusjonen hvilte dermed på at framtidige RPC-er lot feltet være i fred,
og en attribusjon som kan skrives om av den som blir attribuert, er ingen attribusjon
(ANTIDEP_CONSTITUTION.md §14). `knowledge.freeze_source_attribution()` retter det: vernet er
smalt, og begge sider av grensen er prøvd — tittel, forfattere, bibliografiske felter, status
og `superseded_by_source_id` er fortsatt redigerbare, fordi det er korreksjon og livssyklus,
ikke identitet.

Raden selv er tatt med i vernet av samme grunn som migrasjon 008 tok `workflow.user_roles.id`
inn i sitt: migrasjon 007c lar `audit.events` peke på en kilde uten fremmednøkkel (§36), og en
nyopprettet kilde har ennå ingen inngående fremmednøkler som holder primærnøkkelen på plass i
det vinduet auditraden allerede finnes. En omnummerering ville etterlatt auditsporet på en rad
som ikke finnes.

*2. Datohåndteringen ba brukeren kjenne databasens interne format.* `knowledge.sources` lagrer
en årfestet dato som `YYYY-01-01` og en månedsfestet som `YYYY-MM-01`. Konvensjonen er riktig i
databasen — den er nettopp det som hindrer falsk presisjon (§6) — men skjemaet brukte én
`<input type="date">` og sendte verdien uendret. En redaktør som bare visste «november 2000»
måtte dermed selv vite at det skrives som 1. november, ellers avviste databasen en ellers
gyldig kilde med et constraint-navn.

Skjemaet spør nå om presisjonen først og viser deretter det ene datofeltet den presisjonen
faktisk rommer: et årsfelt, en `<input type="month">` eller en `<input type="date">`.
`src/lib/publication-date.ts` **konstruerer** den avkortede datoen framfor å kontrollere at
brukeren traff den, så en uavkortet dato kan ikke oppstå i det hele tatt. De tre feltene lever
side om side i draften, slik at et bytte fram og tilbake ikke sletter det brukeren har skrevet.

Grensen mot databasen er holdt: dette er ikke en kopi av CHECK-constraintene. Modulen svarer
bare på «har skjemaet fått nok input til å danne en verdi?» — er svaret nei, finnes det ingen
dato å sende. At 31. februar er umulig, er fortsatt databasens dom, og en test krever eksplisitt
at den formen slipper gjennom kanoniseringen. Prøvd ende-til-ende over HTTP mot den lokale
stacken: alle fire formene (år, år+måned, eksakt dag, ingen dato) godtas, og kontrollen —
en uavkortet dato med `year`-presisjon — avvises fortsatt av
`sources_publication_date_year_precision_check`. Constraintene er altså uendret.

**Mutasjonstestet, seks mutasjoner til, alle drept av riktig assertion.** Tre på databasen:
opphavssjekken fjernet felte den negative testen *og* kontrollen av at opphavet stod urørt;
identitetssjekken fjernet felte bare identitetstesten; hele triggeren droppet felte i tillegg
strukturtesten i `080`. Tre på klienten: å sende råverdien framfor den avkortede datoen felte
både enhetstesten og sidetesten for år; å fjerne `incomplete`-vakten felte de to testene som
krever at skjemaet sier fra og ikke sender noe; og å la `month`-grenen lese årsfeltet felte
fire tester i begge lag. Ingen av dem ble felt av en urelatert assertion.

**Bekreftelsen etter en opprettelse lenker ingen steder, og det er en rettelse.**
Suksessmeldingen tilbød først «Se kilden» med lenke til `/sources/:sourceId`. Den siden er en
klinikerflate bygget på `api.published_claim_evidence` — den eneste kildeprojeksjonen `api`
har (§74.15) — så den kan bare vise en kilde som allerede inngår i publisert kunnskap. En
kilde som nettopp er opprettet i dette steget har per definisjon ingen: evidensfunnet,
påstanden, godkjenningen og publiseringen ligger alle etter det i §15 sin kjede. Lenken ville
altså i normaltilfellet ført til fraværsmeldingen på kildesiden, og lest som om opprettelsen
hadde gått galt. Den er fjernet. Bekreftelsen oppgir i stedet kildens id som tekst — det
eneste håndtaket på raden som ble skrevet, og det neste ledd i kjeden vil trenge — og sier at
kilden ennå ikke er synlig i klinikerflaten. En admin-visning av *upubliserte* kilder er ikke
bygget her: den trenger sin egen projeksjon i `api` med sine egne grants, og hører til den
PR-en som får bruk for den (§51). To tester i `CreateSourcePage.test.tsx` holder rettelsen på
plass — én på at bekreftelsen ikke har noen lenke, én bredere på at ingen lenke på siden peker
til kildevisningen for den nye kilden — og lenken satt tilbake felte nøyaktig de to og ingen
andre.

**Kildetypen vises med etikett, ikke med enum-verdien.** Nedtrekkslista skrev først ut
`SOURCE_TYPES` direkte, altså `journal_article` og `summary_of_product_characteristics` — den
kanoniske verdien databasen krever, men ikke tekst for et menneske. Etikettene fantes allerede:
`SOURCE_TYPE_LABELS` i `vocabulary-labels.ts` dekker nøyaktig det samme vokabularet og brukes av
`SourceDetails`, så rettelsen er å lese den framfor å lage en ny tabell ved siden av.
`<option value>` er uendret, og RPC-kallet får fortsatt den kanoniske verdien. Testen krever
begge deler i samme assertion, fordi en test på bare etiketten ville overlevd at også verdien
ble byttet til norsk tekst — og da hadde databasen svart `22P02` på et skjema som så riktig ut.
Begge mutasjonene, å vise verdien og å sende etiketten, felte nøyaktig den ene testen.

**Ingen konto har `editor` ennå, og skriveveien er derfor stengt for alle — også i
produksjon.** `api.create_source(...)` krever gjennom `knowledge.assert_editor_authorized()`
en gyldig tildeling med `role_code = 'editor'`. Migrasjon 005b tildeler `reviewer`, og bare
den; ingen migrasjon tildeler `editor` til noen. Et søk gjennom `supabase/migrations/` gir to
treff på `'editor'` — enum-definisjonen i migrasjon 001 og filteret i 007c — og ingen
`insert`. I det hostede prosjektet har `workflow.user_roles` nøyaktig én rad, og den er
`reviewer` (§74.23). Redaktøren vil derfor møte «Brukeren har ikke gyldig editor-rolle» på
`/sources/new`, og det er kontrollen som virker framfor en feil i den: `reviewer` er faglig
godkjenningsrett, og skal ikke implisitt gi rett til å registrere kilder. At CI ikke fanger
dette, er ventet og ikke et hull i testene: `370_source_creation_test.sql` tildeler rollen
selv i sin egen transaksjon, så testene beviser at kontrollen virker — ikke at noen består
den.

**Selve tildelingen hører til sin egen PR (§51).** Den er ikke lagt til her, av tre grunner.
For det første ville denne PR-en da både satt opp porten og delt ut nøkkelen i samme endring,
og de to bør kunne vurderes hver for seg. For det andre er en rolletildeling en
governance-handling med sin egen begrunnelse: `reviewer` hviler på ANTIDEP_CONSTITUTION.md §12
og ble skrevet ut i migrasjon 005b sin `grant_reason`; `editor` er en annen rett — å registrere
kilder og evidens som *forslag*, som passerer review før noe kan publiseres — og terskelen for
den skal skrives ut som sin egen tekst, ikke arves. For det tredje er tildelingen avhengig av
en konto i `auth.users`, altså miljøspesifikk tilstand, og må følge vei a fra §74.18: betinget
av at kontoen finnes, idempotent, og uten å gjeninnføre en avsluttet tildeling
(DATABASE_ARCHITECTURE.md §46). Neste PR er dermed én migrasjon som følger mønsteret fra 005b
— en `workflow.ensure_named_editor_authorization()`-liknende funksjon som returnerer status
framfor å skrive blindt — med pgTAP-dekning av begge grenene, og deretter `supabase db push`
mot det hostede prosjektet. Ført som GitHub-issue 36 slik at den ikke bare står i prosa her.

**Hva som gjenstår.** Milepæl B mangler tre ting (§74.4): ekstraksjonsverifikasjonene,
claim-verifikasjonene og selve godkjenningen. Denne PR-en lukker ingen av dem. Resten av §15
sin admin-workflow — EvidenceItem-registrering, ClaimRevision, evidensverifikasjon og
claim-verifikasjon, review-beslutning, publisering — er ikke bygget, og hver del hører til sin
egen PR (§51).

---

### 74.25 Hva tildelingen av editor-rollen innførte

Migrasjon 005c tildeler redaktørkontoen en uscopet `editor`-rolle — retten til å registrere
kilder og evidens som *forslag*. Det er den ene raden som manglet for at den kontrollerte
skriveveien fra migrasjon 007c skulle kunne brukes av noen (GitHub-issue 36, §74.24). Ikke noe
mer av kjeden: EvidenceItem, ClaimRevision, verifikasjon, review og publisering hører fortsatt
til hver sin senere PR (§51).

**Begrunnelsen for selvtildelingen er skrevet på nytt, ikke arvet fra 005b.** `reviewer` er
faglig godkjenningsrett, og selvtildelingen av den hviler på ANTIDEP_CONSTITUTION.md §12:
prosjekteieren *er* den navngitte kvalifiserte redaktøren, og det finnes ingen høyere
menneskelig instans i basen. `editor` er en annen rett med en annen terskel, og terskelen
følger av hva rollen kan utrette alene: ingenting. En editor kan registrere, men ikke godkjenne
og ikke publisere — `workflow.enforce_reviewer_qualification()` leser `reviewer`,
`knowledge.assert_publisher_authorized(uuid, uuid)` leser `publisher`, og publiseringsgaten i
migrasjon 006 stiller sju krav ingen rolletildeling kan innfri. En selvtildelt `editor` utvider
altså ikke den faglige autoriteten prosjekteieren allerede har. Begrunnelsen står i
`grant_reason` på raden, og `380_source_registration_role_test.sql` krever at den er en annen
tekst enn reviewer-tildelingens: en tildeling som arver en begrunnelse, er en tildeling ingen
har tatt stilling til.

**Det tildelingen gjør synlig, og ikke lukker.** Samme person har nå både `editor` og
`reviewer`, altså er forfatter og godkjenner samme menneske for alt denne redaktøren selv
registrerer. CONTENT_GOVERNANCE.md §5 krever at høyrisikoinnhold godkjennes av noen som ikke
var hovedforfatter, og det kravet har til nå vært innfridd nærmest ved et uhell: det eneste
innholdet i basen er skrevet av en KI-aktør. Gjeldsposten i §74.7 om det udefinerte
kompetansekravet er utvidet med dette framfor å få en ny rad ved siden av seg — det er samme
mangel, gjort konkret — og utløsende hendelse er fortsatt «før første publisering av klinisk
innhold».

**En ny funksjon, ikke en parameter på 005b sin.** `workflow.ensure_editor_role_grant()` gjør
nesten det samme som `workflow.ensure_named_editor_authorization()`, og fristelsen var å gi den
siste en `p_role`-parameter. Migrasjon 005b avviste nettopp den formen, og begrunnelsen holder
her: en parameterisert utgave ville vært en generell «gi denne kontoen hvilken som helst
rolle»-funksjon, altså en rettighetseskalering med et vennlig navn, der `publisher` og `admin`
var like tilgjengelige som `editor`. Prisen er at de fire tilstandene er skrevet ned to steder.
Den er lavere enn den ser ut: 005b eier i tillegg koblingen mellom aktørraden og brukerkontoen,
og den er ikke gjentatt — 005c *krever* at koblingen finnes og feiler høyt hvis den ikke gjør
det, framfor å skrive en andre kopi av logikken som kunne drevet fra originalen.

**Begge grenene kjøres i CI, som for 005b.** Tildelingen er miljøavhengig etter «vei a»
(§74.18): den skriver bare når kontoen finnes i `auth.users`, og gir ellers en `notice` og
statusen `account_missing`. `380_source_registration_role_test.sql` kjører den negative grenen
slik den faktisk står i en fersk stack, og den positive ved å opprette kontoen inne i
transaksjonen som rulles tilbake — i produksjonens egen rekkefølge, med 005b sin kobling først.

**Den viktigste assertionen er ikke om funksjonen, men om det den åpner.** Alt det andre kan
være sant samtidig som redaktøren fortsatt møter «Brukeren har ikke gyldig editor-rolle» på
`/sources/new`. Testen kaller derfor `api.create_source(...)` gjennom klientrollen
`authenticated`, med redaktørkontoens eget JWT-subjekt, og krever at kilden blir opprettet og
attribuert til redaktørens egen aktør. Rollegrensen prøves fra begge sider i samme del:
reviewer-tildelingen fjernes, og med `editor` alene avvises både en reviewbeslutning og
publiseringskontrollen, mens skriveveien fortsatt virker. Uten det siste ville de tre
avvisningene vært forenlige med at det var `reviewer` som åpnet skjemaet.

**Mutasjonstestet: fjorten mutasjoner, alle drept av den assertionen som påstår å teste dem.**
Rollefilteret fjernet felte den som krever at reviewer, publisher og admin ikke teller som
editor; `statement_timestamp()` byttet til `now()` felte bare `pg_sleep`-testen;
`scope_id is null` fjernet felte bare de to om den avgrensede tildelingen; `role_ended`-grenen
fjernet felte bare de to om at en tilbakekalling ikke gjeninnføres; koblingssjekken fjernet
felte de to om en konto uten aktør; `auth.users`-sjekken fjernet felte den negative grenen;
aktørsjekken fjernet felte den om en brutt migrasjonskjede; `role_not_yet_valid` fjernet felte
bare den framtidige tildelingen; en ombyttet presedens felte de fire som skiller «gyldig nå»
fra «har hatt»; `reviewer` skrevet i stedet for `editor` felte hele den positive stien; en
begrunnelse uten «Selvtildeling» felte ordlydstesten; **reviewer-tildelingens begrunnelse
kopiert inn felte nøyaktig de to assertionene som krever en egen begrunnelse**; en avgrenset
tildeling felte den om at raden er uavgrenset; og en KI-aktør som tildeler felte de to om
attribusjon og auditrad.

**Vaktposten i `280_content_hash_serialization_test.sql` fanget en reell feil i denne PR-en.**
Kommentaren på den nye funksjonen viste først til `api.create_source(...)` med bokstavelige
tre punktum. Vakten som krever at enhver funksjonsreferanse i en kommentar lar seg slå opp med
`to_regprocedure()`, leste det som en signatur og stoppet på syntaksfeil. Referansen er nå
skrevet med full signatur, slik `knowledge.assert_publisher_authorized(uuid, uuid)` allerede er
det andre steder. Feilen var vår, ikke vaktens: en kommentar som navngir en funksjon som ikke
finnes, er nettopp det vakten er til for.

**Det hostede prosjektet er tre migrasjoner bak `main`, og det er lest fra prosjektet selv.**
§74.23 sin lærdom er at en påstand om et system utenfor repoet må kontrolleres på
brukstidspunktet, og den kontrollen ga et annet svar enn ventet:
`supabase_migrations.schema_migrations` har tretten rader og stopper på
`20260828090000_api_caller_authorization` (007b). Migrasjonene fra `feat: add the controlled
write path for creating a Source` — 003a, 008a og 007c — er merget i `main`, men aldri kjørt
der. I produksjon finnes derfor verken `api.create_source(...)`,
`knowledge.assert_editor_authorized()`, `knowledge.sources.created_by_actor_id` eller
auditverdien `source_created`; kontrollert med `to_regprocedure()` og katalogoppslag, ikke
antatt. `provenance.actors` har fortsatt tre rader med redaktøren knyttet til kontoen, og
`workflow.user_roles` har fortsatt nøyaktig én rad — den uscopede `reviewer`-tildelingen fra
005b.

**Konsekvensen er at denne migrasjonen ikke alene gjør «Opprett kilde» brukbar i produksjon.**
Fire migrasjoner må kjøres der, i tidsstempelrekkefølge — 003a, 008a, 007c og 005c — og ett
`supabase db push` gjør alle fire i riktig rekkefølge. 005c tar da den positive grenen, fordi
kontoen og koblingen allerede finnes. Ingenting er kjørt mot produksjon fra denne PR-en:
migrasjonen skal være den kanoniske endringen, og en migrasjon som ennå ikke er reviewet, hører
ikke hjemme i produksjon. `supabase db push` kan fortsatt ikke kjøres fra en agentsesjon —
prøvd på nytt her, og den pinnede CLI-ens Bun-runtime feiler fortsatt TLS gjennom sesjonens
HTTPS-proxy (§74.23) — så pushet må gjøres av prosjekteieren eller av en jobb med nettverk til
`api.supabase.com`.

**Bokføringen.** Raden for #38 var ført som `åpen` og er rettet til `merget`, slik konvensjonen
i §74.2 sier at den PR-en som legger til raden under, skal gjøre. Denne PR-en fører sin egen rad
i en egen commit, etter at PR-nummeret finnes. Setningen om filrekkefølgen er samtidig rettet:
den påstod at «de seks siste filene bærer de seks laveste bokstavnumrene», og det stemte ikke
mot listen den selv står ved siden av.

**Hva som gjenstår.** Milepæl B mangler fortsatt tre ting (§74.4): ekstraksjonsverifikasjonene,
claim-verifikasjonene og selve godkjenningen. Denne PR-en lukker ingen av dem, og åpner ikke
publiseringsgaten.

---

### 74.26 Det hostede prosjektet er brakt i synk, og skriveveien for kilder er deployet

§74.25 fant at produksjonsdatabasen stoppet på migrasjon 007b: 003a, 008a og 007c var merget i
`main` og aldri kjørt der, og 005c kom i tillegg. Konsekvensen var at issue 36 sitt symptom
ikke engang var det issuen beskrev — `api.create_source(...)` fantes ikke i produksjon i det
hele tatt. De fire er nå kjørt, etter at PR-en som innførte 005c var reviewet og merget.

**Hvordan, og hvorfor ikke med `supabase db push`.** Den pinnede CLI-en kan fortsatt ikke nå
`api.supabase.com` fra en agentsesjon (§74.23, prøvd på nytt). Migrasjonene ble derfor kjørt
gjennom Management-API-et, én fil om gangen, hver som **én transaksjon som inneholder både
migrasjonens egen SQL og raden i `supabase_migrations.schema_migrations`** — samme operasjon
`db push` utfører, med samme atomisitet. Filene ble tatt uendret fra `main`; ingenting er
skrevet for hånd, og ingen endring er gjort utenom migrasjonene. Rekkefølgen var
tidsstempelrekkefølgen: 003a, 008a, 007c, 005c.

At 008a måtte committe alene før 007c, er ikke en detalj her heller: `ALTER TYPE ... ADD VALUE`
og bruken av den nye verdien kan ikke ligge i samme transaksjon (§74.24). Én forespørsel per
migrasjonsfil gir nettopp det skillet.

**005c tok den positive grenen, og det er første gang den er kjørt med en konto å peke på.**
Kallet returnerte `authorized`. Migrasjonen skrev altså raden, framfor `account_missing` som i
CI og enhver fersk lokal stack — begge grenene har dermed kjørt i et ekte miljø, ikke bare i
testene.

**Hva som er lest tilbake etterpå, som avlesning og ikke som antakelse:**

| Kontroll | Svar |
| --- | --- |
| `supabase_migrations.schema_migrations` | sytten rader, med nøyaktig de samme versjonsnumrene og navnene som filene i `supabase/migrations/` |
| `knowledge.sources.created_by_actor_id` | finnes, `NOT NULL`, og begge de seedede radene er attribuert |
| `audit.event_operation` | inneholder `source_created` |
| `api.create_source(...)`, `knowledge.assert_editor_authorized()`, `audit.record_source_event()`, audittriggeren | alle finnes |
| `EXECUTE` på `api.create_source(...)` | bare `authenticated`; ikke `anon`, ikke `service_role` |
| `workflow.user_roles` | to rader: den uavgrensede `reviewer` fra 27. august og den uavgrensede `editor` fra i dag, begge løpende og begge selvtildelt av `human:peder-holman`, med hver sin begrunnelse |
| `audit.events` | to rader, én `role_granted` per tildeling, begge attribuert til redaktørens aktør |
| Den eksisterende auditraden etter ombyggingen i 007c | står urørt, med `object_schema`/`object_table` korrekt utledet av de nye generert-kolonnene |
| `api.my_roles`, lest gjennom klientrollen `authenticated` med redaktørens JWT-subjekt | viser begge rollene, uavgrenset, uten sluttdato |
| `knowledge.assert_editor_authorized()` med samme subjekt | godkjenner, og returnerer redaktørens egen aktør |
| Et nytt kall på `workflow.ensure_editor_role_grant()` | `already_authorized`, og fortsatt to tildelinger |

**Hva avlesningene over beviser, og hva de ikke beviser.** De viser at skriveveien er
*deployet* og at redaktøren er *autorisert* til å bruke den. De viser ikke at en opprettelse
har lyktes: **ingen vellykket `api.create_source(...)` er kjørt i produksjon.**
`knowledge.assert_editor_authorized()` er porten foran skriveveien, ikke skriveveien selv —
etter den gjør funksjonen en `INSERT` i `knowledge.sources`, som utløser audittriggeren fra
migrasjon 007c, og klienten når den gjennom Data API-ets RPC-flate. Ingen av de tre leddene er
prøvd i produksjon. De er dekket av `370_source_creation_test.sql` og
`380_source_registration_role_test.sql` mot en lokal stack, og RPC-flaten er prøvd over ekte
HTTP lokalt (§74.24) — men et grønt CI-miljø er ikke en avlesning fra produksjon, og det er
nettopp den forskjellen §74.23 sin lærdom handler om.

**Ingen testkilde er opprettet i produksjon, og det er et valg.** Den siste kontrollen kunne
vært å kalle `api.create_source(...)` og se raden komme, men den ville lagt en oppdiktet kilde
i den kanoniske kunnskapsbasen — og en kilde er ikke en testrad som kan ryddes bort uten spor:
opphavet er frosset (`knowledge.freeze_source_attribution()`), og auditraden består. Kjeden er
derfor prøvd så langt den kan prøves uten å skrive. Den første ekte kilden hører til
redaktøren, gjennom skjemaet, og det er den opprettelsen som lukker dette hullet.

**Gjelden dette etterlater.** Ingen vaktpost ser på det hostede prosjektet, og dette er tredje
gang en påstand om det har vært usann i repoet uten at noe merket det (§74.18, §74.23, §74.25).
At den nå er sann, endrer ikke mekanismen. GitHub-issue 40 gjaldt den konkrete forekomsten —
produksjonen var fire migrasjoner bak — og er lukket av arbeidet over. **Mekanismen er ført som
GitHub-issue 42**, med retningen: et steg som leser migrasjonshistorikken fra det hostede
prosjektet og sammenligner den med `supabase/migrations/`, i den første jobben som har nettverk
til `api.supabase.com` og et prosjekt-token i CI. Om det steget også skal *kjøre*
`supabase db push`, er en større beslutning — automatisk skriving til produksjon fra CI — og
hører til den issuen, ikke hit.

**Hva som gjenstår.** Milepæl B mangler fortsatt tre ting (§74.4): ekstraksjonsverifikasjonene,
claim-verifikasjonene og selve godkjenningen. Ingenting her lukker noen av dem, og
publiseringsgaten er urørt.

### 74.27 Den første reelle kilden er opprettet, og evidensregistreringen er bygget

§74.26 endte med et hull den ikke kunne lukke selv: skriveveien for kilder var deployet og
redaktøren autorisert, men **ingen vellykket `api.create_source(...)` var kjørt i
produksjon**. Den kontrollen kunne ikke gjøres uten å skrive, og en kilde er ikke en testrad
som kan ryddes bort uten spor.

**Hullet er lukket, og det ble lukket slik det skulle: av redaktøren, gjennom skjemaet.**
Prosjekteieren har opprettet den første reelle kilden i produksjon gjennom `/sources/new`.
Det er første gang alle tre leddene bak skriveveien er prøvd i produksjon samtidig: RPC-flaten
i Data API-et, `knowledge.assert_editor_authorized(...)` sin positive gren, `INSERT`-en i
`knowledge.sources`, og audittriggeren fra migrasjon 007c. **Skriveveien for Source er dermed
bekreftet ende-til-ende**, ikke bare deployet.

Det som ble bekreftet er kjeden, ikke en enkelt funksjon. Bekreftelsen er en avlesning fra
produksjon og ikke fra CI, og det er nettopp forskjellen §74.23 sin lærdom handler om.

---

**Steg 3 av «manuell adminflyt» (§29) er bygget: «Editor registrerer EvidenceItem» (§15).**
Ingenting av kjeden etter det er rørt. Ekstraksjonsverifikasjon, ClaimRevision,
claim-evidenslenker, review og publisering hører fortsatt til senere PR-er, én om gangen
(§51).

Tre migrasjoner, av samme grunn som steg 2 trengte tre:

| Migrasjon | Hva den gjør |
| --- | --- |
| 008b | `audit.event_operation` får verdien `evidence_item_created`. Alene i sin egen fil, fordi `ALTER TYPE ... ADD VALUE` ikke kan brukes i samme transaksjon som verdien (§74.24) |
| 007d | Den redaksjonelle lesemodellen: seks views i `api` og seks RLS-policyer under dem, slik at en editor kan *se* hvilke kilder, virkestoff, endepunkter og populasjoner et funn kan knyttes til |
| 007e | Skriveveien selv: `api.create_evidence_item(...)`, audittriggeren på `knowledge.evidence_items`, og scope-utvidelsen av `knowledge.assert_editor_authorized(uuid)` |

**Den redaksjonelle lesemodellen er nye policyer, ikke nye grants.** Migrasjon 007 ga allerede
klientrollene SELECT på tabellene under lesemodellen og lot RLS avgjøre hvilke *rader* som er
synlige; predikatet der er publisering. En editor trenger det motsatte utvalget — kilden hen
nettopp opprettet er per definisjon ikke publisert — så 007d legger til en andre policy per
tabell. Policyer er permissive og OR-es sammen: en editor ser hele registeret, alle andre ser
fortsatt nøyaktig det publiserte utvalget, og ingen ny tabell er åpnet for noen.

Radgrensen står ett sted, `workflow.caller_is_active_editor()`, framfor som seks kopier av
samme predikat. Den koster ett dokumentert unntak fra en vaktpost: `210_workflow_access_test.sql`
krevde at *ingen* funksjon i `workflow` eller `provenance` er kjørbar for en klientrolle, og
`authenticated` må ha EXECUTE på denne for at policyuttrykkene skal kunne evalueres — prøvd
mot stacken, ikke antatt. Unntaket er smalere enn det ser ut, og begge halvdelene er festet
som assertions framfor som prosa: granten gjelder bare `authenticated`, og en klientrolle kan
uansett ikke navngi schemaet `workflow`, så funksjonen er ikke kallbar utenfor policyene.

**Her måtte scope-spørsmålet 007c utsatte, faktisk besvares.** 007c lot en avgrenset
editor-tildeling opprette en Source, fordi en kilde ikke selv er avgrenset til noe klinisk
begrep — og skrev eksplisitt at en senere skrivevei som oppretter et *avgrenset* objekt måtte
ta stilling til scope på nytt. Et evidensfunn er avgrenset: `outcome_concept_id` peker på
nøyaktig den typen begrep `workflow.user_roles.scope_id` avgrenser en tildeling til. Svaret er
derfor det samme som for publisering: en uavgrenset editor-tildeling gjelder alt, en avgrenset
gjelder sitt eget endepunkt. Sammenligningen er nøyaktig likhet og ikke et hierarki — en
avgrensning som utvidet seg hver gang noen la til et underbegrep, ville vært en utvidelse
ingen tildelte.

**Tre kolonner er ikke parametre, og det er en integritetsbeslutning.** `extraction_method`
er hardkodet til `manual`: en registrering gjennom skjemaet *er* en menneskelig ekstraksjon,
og en klientoppgitt verdi ville gjort det mulig å merke en håndskrevet rad som maskinelt
importert — en usann påstand om radens opphav som ingenting kunne motsi. `content_hash` eies
av databasen, som før. `raw_extraction` bygges av ett tekstfelt, `p_source_quote`, under én
nøkkel definert i migrasjonen: en jsonb-parameter ville latt skjemakoden bestemme formen på et
kanonisk felt.

**Null/ukjent-semantikken er skjemaets form, ikke et tillegg.** Fem felter bærer en
`*_availability`, og databasen håndhever at verdien finnes hvis og bare hvis statusen sier det
(DATABASE_ARCHITECTURE.md §19.1). Skjemaet spør derfor alltid om statusen først og viser
verdifeltet bare når statusen er en av de to som betyr at kilden faktisk oppgir noe. Det gjør
det umulig å fylle ut et par databasen ville avvist — og, viktigere, det tvinger fram et svar
på *hvorfor* et tall mangler framfor å la feltet stå tomt (ANTIDEP_CONSTITUTION.md §6, §17).

**Én avvisning er oversatt, og bare én.** `content_hash` er unik, så nøyaktig samme
registrering to ganger avvises med 23505. Databasens egen tekst navngir en mekanisme framfor å
si hva som skjedde, og dette er den eneste avvisningen som er en forventet utgang av en riktig
utfylt form. Regelen er uendret; bare ordlyden er ny. Alt annet — availability-paringen,
enheten som følger effektmålet, komparatoren som ikke kan være intervensjonen selv, at
kildeversjonen tilhører samme kilde, at endepunktet er et begrep av typen `outcome` —
propageres uendret fra databasen.

**Hva som er prøvd, og hvordan.** `390_evidence_item_registration_test.sql` (35 assertions)
dekker kontrakten, hver autorisasjonsgren inkludert den avgrensede editoren i begge retninger,
den lykkede stien i detalj, auditraden og sju avvisninger fra tabellens egne regler.
`400_editor_read_model_access_test.sql` (20) dekker den redaksjonelle lesemodellen, og
kontrollerer at radgrensen og skriveveiens kontroll svarer likt for hver av seks kallere.
Skriveveien er dessuten prøvd over ekte HTTP gjennom PostgREST med et signert token, og hele
flyten — innlogging, registrering, bekreftelse — er kjørt i en ekte nettleser mot en lokal
stack, på både desktop- og mobilbredde, uten konsollfeil.

**Gjeld dette etterlater.** Kilden en editor nettopp har opprettet, har ingen registrert
kildeversjon, og skjemaet kan derfor bare tilby «ingen registrert kildeversjon». Feltet er
riktig modellert — `source_version_id` er nullbar, og NULL betyr «ikke knyttet til et
registrert øyeblikksbilde» — men uten en versjon finnes det ingen adresse en verifikator kan
hente kilden på nytt fra. Skriveveien for kildeversjoner er ført som GitHub-issue 44, og hører
til den PR-en som bygger verifikasjonssteget.

Den andre gjelden er katalogens rekkevidde: `catalog` inneholder fortsatt nøyaktig det første
golden slice trengte, to virkestoff og ett endepunkt, og et evidensfunn må peke på begge
deler. En redaktør kan derfor opprette en kilde om et hvilket som helst tema, men bare
registrere funn om de to. Ført som GitHub-issue 45, med de tre spørsmålene den PR-en må
avgjøre: hvilken rolle som forvalter vokabularet, attribusjon på katalogradene, og hva en
avgrenset rolle som kan opprette begreper betyr for sin egen rekkevidde.

**Hva som gjenstår for Milepæl B.** Fortsatt de samme tre (§74.4): ekstraksjonsverifikasjonene,
claim-verifikasjonene og selve godkjenningen. Steg 3 lukker ingen av dem — det produserer
nettopp de objektene G4/G5 senere skal kontrollere.

---

### 74.28 Evidensregistreringen er kjørt mot det hostede prosjektet

§74.27 beskrev skriveveien som *bygget*. Den var da merget i `main` og deployet som kode, men
de tre migrasjonene var ikke kjørt mot produksjonsdatabasen — nøyaktig det avviket §74.25
fant sist, og som issue 42 fortsatt ikke oppdager av seg selv. Migrasjonene er nå kjørt, etter
at PR-en var reviewet og merget.

**Hvordan.** Samme framgangsmåte som §74.26, og av samme grunn: den pinnede CLI-en når ikke
`api.supabase.com` fra en agentsesjon (§74.23). Migrasjonene ble kjørt gjennom
Management-API-et, én fil om gangen, hver som **én transaksjon som inneholder både
migrasjonens egen SQL og raden i `supabase_migrations.schema_migrations`** — samme operasjon
`supabase db push` utfører, med samme atomisitet. Filene er tatt uendret fra `main`, i
tidsstempelrekkefølge: 008b, 007d, 007e. At 008b måtte committe alene før 007e, er igjen ikke
en detalj: `ALTER TYPE ... ADD VALUE` og bruken av den nye verdien kan ikke ligge i samme
transaksjon (§74.24), og én forespørsel per fil gir nettopp det skillet.

**Hva som er lest tilbake etterpå, som avlesning og ikke som antakelse:**

| Kontroll | Svar |
| --- | --- |
| `supabase_migrations.schema_migrations` mot `supabase/migrations/` | tjue rader, identisk liste, sammenlignet maskinelt framfor for øyet |
| `api.editor_*` | seks views |
| `*_editor_read` | seks RLS-policyer |
| `api.create_evidence_item(...)` | finnes, med den 30 parametere lange signaturen |
| `knowledge.assert_editor_authorized(uuid)` | finnes; den gamle parameterløse varianten er borte |
| `workflow.caller_is_active_editor()`, `audit.record_evidence_item_event()`, audittriggeren | alle finnes |
| `audit.event_operation` | inneholder `evidence_item_created` |
| Grants på de seks views-ene | `authenticated` har SELECT på alle seks, ingenting utover SELECT; `anon` har ingenting |
| EXECUTE på funksjonene | `authenticated` på `api.create_evidence_item`, `api.create_source` og `workflow.caller_is_active_editor`; ingen klientrolle på `knowledge.assert_editor_authorized` eller `audit.record_evidence_item_event` |

**Data API-flaten er prøvd utenfra, ikke bare lest i katalogen.** En uinnlogget forespørsel mot
`api.editor_sources` avvises med 42501, og et kall på `api.create_evidence_item` med alle
fjorten obligatoriske parametere avvises med *permission denied for function* — ikke med
PostgREST sin `PGRST202`, «fant ikke funksjonen». Forskjellen er verdt å skille: `PGRST202`
ville betydd at PostgREST ikke har sett den nye funksjonen ennå, mens *permission denied for
function* betyr at den er synlig og stengt. Det er den siste som kom.

**Redaktørens tildeling er uavgrenset**, lest fra `workflow.user_roles`: `editor` uten
scopebegrensning og uten sluttdato, ved siden av `reviewer` fra §74.23. Skopebegrensningen
007e innførte, er derfor bygget og testet, men ingen tildeling i produksjon bruker den ennå.

**Grensen for hva dette bekrefter, skrevet ut.** Avlesningene viser at skriveveien er deployet
og at redaktøren er autorisert til å bruke den. De viser ikke at en registrering har lyktes:
`INSERT`-en i `knowledge.evidence_items`, audittriggeren og `content_hash`-beregningen er
ingen av dem kjørt i produksjon. Ingen testrad er opprettet for å lukke det hullet — et
evidensfunn er append-only og kan ikke ryddes bort uten spor, samme resonnement som §74.26
gjorde for kilder. Hullet lukkes slik det forrige ble lukket: av redaktøren, gjennom skjemaet.

**Katalogen produksjonsdatabasen faktisk har**, som avgjør hva som kan registreres i praksis:
tre kilder, to registrerte kildeversjoner, to virkestoff, ett endepunkt og én populasjon. De
to gjeldspostene §74.27 førte — issue 44 for kildeversjoner og issue 45 for katalogens
rekkevidde — er dermed ikke teoretiske: en registrering i produksjon i dag må peke på det ene
endepunktet som finnes.

---

### 74.29 Det første reelle evidensfunnet er registrert i produksjon

§74.28 endte med et hull den ikke kunne lukke selv, og skrev det ut: avlesningene viste at
skriveveien var deployet og redaktøren autorisert, men **ingen vellykket
`api.create_evidence_item(...)` var kjørt i produksjon**. `INSERT`-en, audittriggeren og
`content_hash`-beregningen var ingen av dem prøvd der. Ingen testrad ble opprettet for å lukke
det: et evidensfunn er append-only og kan ikke ryddes bort uten spor.

**Hullet er lukket, og det ble lukket slik det skulle: av redaktøren, gjennom skjemaet.**
Prosjekteieren har registrert det første reelle evidensfunnet i produksjon gjennom
`/evidence/new`. **Skriveveien for EvidenceItem er dermed bekreftet ende-til-ende**, ikke bare
deployet — samme forskjell §74.27 slo fast for kilder, og samme lærdom som §74.23 handler om:
bekreftelsen er en avlesning fra produksjon, ikke fra CI.

**Hva funnet er.** Fava 2000 målte hvor mange som gikk opp minst 7 % i vekt under
langtidsbehandling, men den registrerte kildeversjonen — MEDLINE-posten — oppgir ikke andelen
for sertralin. Den oppgir bare at antallet var signifikant høyere for paroksetin. Funnet
registrerer altså at størrelsen *ble målt* og at tallet *ikke står* der raden peker. Det er
ikke et tomt funn: `ANTIDEP_CONSTITUTION.md` §6 og §17 krever nettopp at manglende evidens
registreres som manglende framfor å utelates, og §19.1 sin paring av verdi og status er det
som gjør forskjellen lagrbar. Et funn som var utelatt fordi tallet manglet, ville sett ut som
om ingen hadde sett etter.

**Hva som er lest tilbake fra produksjon etterpå, som avlesning og ikke som antakelse:**

| Kontroll | Svar |
| --- | --- |
| Raden i `knowledge.evidence_items` | finnes, `3422c284-31eb-428e-b1a0-bebf3f616ffc` |
| Kilde og kildeversjon | Fava 2000, knyttet til den registrerte MEDLINE-versjonen — ikke NULL |
| `extraction_method` | `manual` |
| `content_hash` | beregnet av databasen, med `sha256-v2:`-prefiks |
| `raw_extraction` | sitatet, under den ene nøkkelen migrasjon 007e definerer |
| `created_by_actor_id` | den navngitte kvalifiserte redaktøren, ikke en KI-aktør |
| Auditraden | `evidence_item_created`, på riktig objekt, med menneskelig aktør og øyeblikksbilde |
| Availability-parene | populasjon, utvalgsstørrelse og oppfølgingstid som `reported_value`; estimat og konfidensintervall som `not_reported` |

**To av avlesningene er mer enn en kvittering.** `extraction_method` er hardkodet til `manual`
i skriveveien og kan ikke oppgis av klienten (§74.27); at raden bærer den verdien, er derfor et
bevis på at den kom gjennom den kontrollerte veien og ikke gjennom et direkte `INSERT`. Og
`created_by_actor_id` er første gang et evidensfunn i basen er attribuert til et menneske: de to
seedede funnene bærer «Antidep ekstraksjonsagent». Attribusjonskjeden §74.24 bygget, er dermed
prøvd med en reell menneskelig aktør i den enden den ble bygget for.

**Katalogen produksjonsdatabasen har nå:** tre kilder, to registrerte kildeversjoner, tre
evidensfunn, to virkestoff, ett endepunkt og én populasjon.

**Ingen ekstraksjonsverifikasjon, ingen claim-verifikasjon og ingen reviewgodkjenning er
registrert** — de tre som gjenstår for Milepæl B (§74.4), uendret av dette steget. Ingen
publisering er registrert heller, men publisering er ikke en fjerde gjenstående ting ved siden
av de tre: den er det gaten slipper gjennom *når* de tre er innfridd, og kan ikke skje før.
De to verifikasjonsfasene er dessuten to og ikke én — ekstraksjonen kontrolleres mot kilden
(G4/G5), claim-støtten mot evidensen (G8/G9) — og å slå dem sammen ville skjult den ene.

**Steg 3 av «manuell adminflyt» (§29) er dermed bekreftet i produksjon, ikke bare bygget.**
Markeringen for `First admin workflow` står fortsatt som `[~]` av samme grunn som før, og de to
tellemåtene skal ikke blandes. «Steg 1, 2 og 3» er §29 sin leveranse `manuell adminflyt`, der
steg 1 er «hvem er jeg, og hva har jeg lov til?» (§74.21-§74.22). Kjeden i §15 er noe annet: ti
ledd, og den begynner med «Editor oppretter Source». Tilgangsflaten er ikke ett av dem. **Av
§15 sine ti ledd er dermed de to første prøvd i produksjon**, og det tredje — «separat
verifier verifiserer ekstraksjonen» — er neste.

---

### 74.30 Neste ledd: ekstraksjonsverifikasjon, og hva som må avgjøres først

Neste ledd i §15 er «separat verifier verifiserer ekstraksjonen». Maskineriet finnes fra
migrasjon 005 — `workflow.evidence_verifications` med sine invarianter — men det finnes ingen
skrivevei inn i det, ingen redaksjonell lesemodell over det, og ingen flate. Mønsteret er gitt
av de to foregående stegene (§74.24, §74.27) og skal ikke oppfinnes på nytt: en kontrollert
`SECURITY DEFINER`-funksjon i `api`, autorisasjon på sitt eget kall, attribusjon, audit, og
views med RLS-policyer under seg.

**Fire ting må avgjøres i den PR-en, og alle fire er lest ut av produksjon framfor antatt.**

**1. Kildeversjoner må bygges i samme PR (issue 44).** `ANTIDEP_CONSTITUTION.md` §11 forbyr å
godkjenne en ekstraksjon på grunnlag av et annet ledds sammendrag alene, og
`evidence_verifications_source_access_check` håndhever det: `verified` sammen med
`derived_summary` avvises. En kilde opprettet gjennom `/sources/new` har ingen kildeversjon i
det hele tatt — Efexor-kilden er nettopp det tilfellet — og et funn registrert mot den ville
hatt ingenting å kontrolleres mot. Uten `api.create_source_version(...)` er verifikasjonssteget
derfor bygget for et grunnlag som bare tilfeldigvis finnes for de tre funnene som er registrert
i dag. Issue 44 sier selv at den hører til denne PR-en; avlesningen bekrefter det.

**2. «Adresse pluss hash» er ikke uten videre et tilstrekkelig verifikasjonsgrunnlag.**
Dette er det som må avgjøres og ikke antas. `workflow.verification_source_access` beskriver
`verifiable_representation` som et *lagret* og etterprøvbart øyeblikksbilde, og
`storage_reference` er NULL på begge de seedede kildeversjonene: det finnes ingen lagret kopi,
bare en adresse og en hash å hente på nytt og sammenligne mot. `original_source` er heller ikke
opplagt: `Source` er en tidsskriftartikkel, mens `retrieved_from` peker på en MEDLINE-post, og
funnenes `source_locator` sier eksplisitt «Sammendrag (MEDLINE-post)». Posten er en
bibliografisk representasjon av artikkelen, ikke artikkelen.

**Databasen fanger ikke dette.** CHECK-en avviser bare `verified` + `derived_summary`; en
`verified`-rad med `verifiable_representation` passerer uansett om kildeversjonen har en lagret
kopi eller ikke. Integriteten hviler altså på hva verifikatoren oppgir, og det er nettopp derfor
den skal skrives ut framfor å overlates til skjønn i øyeblikket. Den PR-en må velge én av tre,
og valget hører til den og ikke hit:

1. verifikatoren skaffer artikkelen selv og registrerer `original_source`;
2. skriveveien for kildeversjoner lagrer et faktisk øyeblikksbilde, slik at
   `verifiable_representation` er sann etter sin egen definisjon;
3. semantikken presiseres eksplisitt — for eksempel at en adresse med reproduserbar hash *er*
   en etterprøvbar representasjon — og presiseringen føres i typekommentaren og håndheves der
   den kan håndheves.

Alternativ 2 er det som gjør issue 44 til mer enn en bekvemmelighet, og er den retningen som
krever minst nytolkning av et vokabular som allerede er skrevet. En `verified`-rad skal
uansett ikke registreres i produksjon før spørsmålet er avgjort.

**3. Rollen som verifiserer er `reviewer`, ikke en ny rolle.** `workflow.app_role` definerer
`reviewer` som «faglig verifikasjon» (migrasjon 001), og redaktøren har allerede den
tildelingen uavgrenset (§74.28). Scope-spørsmålet er avgjort på samme måte som for
evidensregistreringen (§74.27): en ekstraksjonsverifikasjon er avgrenset til funnets endepunkt,
så en avgrenset `reviewer`-tildeling gjelder sitt eget begrep og en uavgrenset gjelder alt.
Ingen ny rolle, ingen ny tildeling.

**4. Den ene tingen som ikke kan avgjøres i koden: hvem som verifiserer redaktørens egne
funn.** `workflow.evidence_verifications` krever at verifikatoren er en *annen* aktør enn den
som opprettet funnet — Konstitusjonen §11, at generering og verifikasjon er atskilte
operasjoner, håndhevet som en CHECK og ikke som en konvensjon. §74.4 er samtidig eksplisitt på
at verifikasjonene *kan* være agentproduserte, så lenge skillet holdes og kontrollen skjer mot
kildematerialet. Spørsmålet er derfor ikke om regelen skal gjelde, men hvem den andre aktøren
er i praksis. Avlesningen fra produksjon gjør konsekvensen konkret:

- de to seedede funnene er opprettet av «Antidep ekstraksjonsagent», og **kan** verifiseres av
  redaktøren gjennom skjemaet;
- funnet redaktøren nettopp registrerte, **kan ikke** verifiseres av redaktøren selv;
- de to KI-aktørene har ingen brukerkonto, og kan derfor ikke kalle en skrivevei som
  autoriserer på den innloggede brukeren. En agentprodusert verifikasjon forutsetter den
  least privilege-identiteten §16 forutser for `agent_worker`, og den finnes ikke.

Det blokkerer ikke PR-en: skriveveien kan bygges og prøves fullt ut i test, i begge retninger,
mot de to seedede funnene — samme mønster som `390_evidence_item_registration_test.sql` bruker
på hver autorisasjonsgren. At de to funnene er *prøvbare* i test, er ikke det samme som at en
`verified`-rad kan registreres mot dem i produksjon: det avgjøres av punkt 2.

Det denne begrensningen derimot blokkerer, er at kjeden kjøres helt gjennom i produksjon for et
funn redaktøren selv har registrert. Valget står mellom å registrere en andre navngitt person
og å bygge agentidentiteten §16 forutser; det første er klart minst, men det er et
governance-spørsmål og ikke et teknisk, og det føres her framfor å bli oppdaget når skriveveien
avviser det første kallet.

**Hva PR-en ikke skal gjøre.** ClaimRevision, claim-evidenslenker, claim-verifikasjon,
EvidenceAssessment, review og publisering er de seks neste skrivende leddene i §15, og hører til
hver sin senere PR (§51). Det tiende og siste leddet, «kliniker-UI oppdateres», er ingen egen
skriveoperasjon: det følger av publiseringen gjennom api-projeksjonene (§74.12).

**Hva verifikasjonssteget faktisk lukker, og hva det ikke lukker.** Gaten i migrasjon 006 har
to krav bak ekstraksjonsverifikasjonen, ikke ett: G4 krever at det *finnes* en verifikasjon for
hvert lenket evidensfunn, og G5 krever at den *gjeldende* — den siste, sortert på `verified_at`
— sier `verified`. En vellykket verifikasjon lukker derfor begge for det funnet. En verifikasjon
med utfallet `needs_correction`, `rejected` eller `uncertain` lukker bare G4 og lar G5 blokkere,
og det er hensikten: en kontroll som ikke konkluderte, er ikke en bekreftelse
(ANTIDEP_CONSTITUTION.md §6, §11). Av de tre som gjenstår for Milepæl B (§74.4) lukker steget
altså det første, for de funnene som faktisk blir bekreftet, og etterlater claim-verifikasjonen
(G8/G9) og den menneskelige godkjenningen (G11/G12/G13).

---

### 74.31 Prosjektbeslutning: Antidep er agent-first, og agentidentiteten er bygget

§74.30 punkt 4 endte med et spørsmål koden ikke kunne avgjøre: hvem som verifiserer
redaktørens egne evidensfunn. `workflow.evidence_verifications` krever en *annen* aktør enn
den som laget funnet — ANTIDEP_CONSTITUTION.md §11, håndhevet som en CHECK — og de to
KI-aktørene hadde ingen brukerkonto og dermed ingen måte å kalle en skrivevei på. Valget stod
mellom å registrere en andre navngitt person og å bygge den agentidentiteten §16 forutser.

**Beslutningen er tatt av prosjekteieren: Antidep skal være agent-first.** Målet er at
KI-agenter gjør mest mulig av det redaksjonelle arbeidet, og at kvaliteten sikres med flere
uavhengige agentledd framfor med manuelt menneskearbeid. Menneskelig kontroll skal brukes der
den trengs eller ønskes, men den automatiserte fler-agent-flyten er hovedveien i
prøveprosjektet. En andre navngitt person ble derfor ikke registrert.

**Det som er endret i normene, og det som ikke er det.** §16, §38 og §49 er skrevet om til å
beskrive flere agentroller med hver sin identitet og hver sin rettighetsgrense.
EVIDENCE_PIPELINE.md §80.1 og §81 sier ikke lenger at manuell kjøring er normalveien, og
CONTENT_GOVERNANCE.md §14 beskriver `Agent Worker` som en faktisk identitetsmodell framfor som
en liste over hva en agent ikke skal kunne.

**ANTIDEP_CONSTITUTION.md er uendret, og §12 gjelder fullt ut.** KI kan foreslå og
kontrollere; den endelige faglige godkjenningen før første publisering er forbeholdt en
navngitt kvalifisert redaktør. `workflow.review_decisions` krever fortsatt en aktør av typen
`human`, deklarativt håndhevet med sammensatt fremmednøkkel, og ingen agentrolle kan komme
utenom den. Det samme gjelder publisering. Skal en agent kunne godkjenne eller publisere, må
selve Konstitusjonen revideres gjennom faglig gjennomgang og versjonskontroll — det er en
governance-beslutning som hører til prosjekteieren, ikke en implementasjonsdetalj, og koden
skal ikke kunne ta den (Konstitusjonens innledning og styringsregel).

---

**Fire migrasjoner, og ingen av dem rører kunnskapsobjektene.**

| Migrasjon | Hva den gjør |
| --- | --- |
| 005d | `provenance.agent_role` får `extraction_verification`. Alene i sin egen fil, fordi `ALTER TYPE ... ADD VALUE` ikke kan brukes i samme transaksjon som verdien (§74.24) |
| 008c | `audit.event_operation` får de tre livssyklushendelsene til en agentidentitet. Alene, av samme grunn |
| 005e | Selve mekanismen: `provenance.agent_identities`, `provenance.agent_runs`, autentiseringen, utstedelsen av legitimasjon, auditskriveren og de to api-inngangspunktene |
| 005f | Den første agentidentiteten: ekstraksjonsverifikatoren, registrert av den navngitte redaktøren og uten utstedt legitimasjon |

**Hvorfor rollen måtte legges til framfor lånes.** Konstitusjonen §10 lister sju roller
KI-arbeidet «minst» skal deles i, og migrasjon 005 skrev nøyaktig de sju. EVIDENCE_PIPELINE.md
§61 deler ett av dem i to: `ExtractionVerifier` kontrollerer ekstraksjonen mot kilden, mens
`CitationVerifier` kontrollerer at evidensen støtter påstanden. De har forskjellig input,
forskjellig output og hver sin tabell. Å gjenbruke `citation_support_verification` for begge
ville gitt én rolle to mandater, og gjort rollen ubrukelig nettopp som rettighetsgrense.

**Hvorfor identiteten er en legitimasjon og ikke en brukerkonto.**
`actors_auth_user_is_human_check` forbyr at en agent har en rad i `auth.users`, og §16 sier
hvorfor. `service_role` var det opplagte alternativet og er avvist av
DATABASE_ARCHITECTURE.md §49: den omgår RLS, er én felles nøkkel med full tilgang, og gir
ingen rolleseparasjon mellom agentledd — en nøkkel som kan alt, kan også verifisere sitt eget
arbeid. Identiteten er derfor en egen rad med sin egen hemmelighet, hashet med sha256 av
«identitetsnøkkel:hemmelighet» og aldri lagret i klartekst. Ingen extension er innført:
`sha256()` og `gen_random_uuid()` er begge i PostgreSQL-kjernen.

**Tre uavhengige lag håndhever at en agent ikke kan verifisere sitt eget arbeid**, og de er
prøvd hver for seg:

1. **Rollen.** En identitet har nøyaktig én agentrolle, og autentiseringen krever den rollen
   operasjonen trenger. Verifikatoridentiteten avvises for et ekstraksjonssteg selv med
   korrekt legitimasjon — prøvd i `420_agent_identity_authentication_test.sql` og over ekte
   HTTP.
2. **Aktøren.** `evidence_verifications_separate_actor_check` avviser en rad der kontrolløren
   er den samme aktøren som laget funnet, uansett hvordan raden kom dit.
3. **Kjøringen.** `provenance.agent_runs` bærer aktør og rolle som speilkolonner låst til
   identiteten av sammensatte fremmednøkler, og eksponerer `(id, actor_id)` og
   `(id, agent_role)` som unike nøkler. Neste PR kan derfor kreve deklarativt at en
   verifikasjon peker på en kjøring i riktig rolle, utført av den aktøren raden attribueres
   til (DATABASE_ARCHITECTURE.md §59), framfor å kontrollere det i funksjonskode.

**Registrering er en menneskelig handling, og det er en regel.** En agentidentitet kan bare
registreres, få legitimasjon eller trekkes tilbake av en aktør av typen `human`, håndhevet med
sammensatt fremmednøkkel og CHECK. En agent som kunne registrere agenter, ville vært en
rettighetseskalering med ett ekstra ledd (CONTENT_GOVERNANCE.md §14).

**Kjøringen er det som gjør en KI-operasjon rekonstruerbar.** `provenance.agent_runs` er
DATABASE_ARCHITECTURE.md §33 og EVIDENCE_PIPELINE.md §65 bygget: rolle, identitet, leverandør,
modell, modellversjon, promptmalversjon, pipelineversjon, inputmanifest, outputmanifest,
status og tidspunkter. Alle fem versjonsfeltene er NOT NULL — en kjøring som kunne unnlate å
oppgi dem, ville vært den uversjonerte KI-operasjonen Konstitusjonen §20 forbyr, og feltet
ville stått tomt akkurat i de kjøringene det betyr mest å kunne lese i ettertid. Kjøringen
åpnes én gang og lukkes én gang; premissene er uforanderlige og ingen kjøring kan slettes.

**EXECUTE går til `anon`, og det er en avveining som er skrevet ut.** En agent har ingen
brukerkonto, så en kaller uten brukersesjon er `anon` i Data API-et. Alternativene var
`service_role` (avvist av §49) eller en menneskelig konto brukt av en maskin (avvist av §16).
Legitimasjonen og ikke Data API-rollen er derfor kontrollen: funksjonene leser og skriver
ingenting før autentiseringen har lyktes, alle avvisninger er identiske, rollen er en del av
autentiseringen, og en vellykket autentisering gir ingenting annet enn retten til å åpne og
lukke en kjøring — som ikke rører ett kunnskapsobjekt. Restrisikoen er at flaten ikke har rate
limiting i basen; den er ført som gjeld (§74.7) og som GitHub-issue 49, framfor løst med
en halv mekanisme.

**Legitimasjonen er ikke utstedt, og det er med hensikt.** Migrasjon 005f registrerer
identiteten med `secret_hash` NULL, og en identitet uten utstedt legitimasjon kan ikke
autentisere seg i det hele tatt. En hemmelighet generert av en migrasjon måtte enten ligget i
repoet eller blitt returnert til den som kjørte den — altså gjennom en agentsesjons logg og
videre inn i en transkripsjon. Utstedelsen hører derfor til den PR-en som bygger kjøreren, med
ett kall til `provenance.issue_agent_identity_credential(text, text)` i det miljøet kjøreren
leser hemmeligheten fra. Fram til da er identiteten registrert, reviewbar og ute av stand til
å gjøre noe.

**Hva som er prøvd, og hvordan.** Tre nye testfiler med til sammen 83 assertions:
`410_agent_identity_structure_test.sql` dekker nøklene, speilkolonnene, reglene som ikke kan
omgås og hele tilgangsflaten; `420_agent_identity_authentication_test.sql` dekker
legitimasjonens livssyklus, rollen som rettighetsgrense, rotasjon, tilbaketrukket aktør,
tilbakekalling og auditsporet; `430_agent_run_lifecycle_test.sql` dekker inngangspunktene som
`anon`, kjøringens livssyklus, speilene som ikke lar seg forfalske, og lag 2 mot
`workflow.evidence_verifications`. Ni vaktposter i den eksisterende suiten slo ut på
endringen, som de skal, og er oppdatert framfor omgått. Fem funn fra kodegjennomgangen er rettet
på plass, hvert med sin regresjonstest, og alle fem handler om det samme: at de tre
rettighetsendringene i en agentidentitets livssyklus faktisk er tre, og at hver av dem
etterlater sin egen auditrad.

- Legitimasjonens fire felter kan bare flytte seg sammen. Ellers kunne versjonstall,
  utstedelsestidspunkt eller utsteder skrives om uten den auditraden hashendringen utløser.
- Et menneske som er trukket tilbake, kan ikke stå som den som registrerte en identitet,
  utstedte legitimasjon eller trakk den tilbake. Regelen ligger på tabellen og ikke bare i
  utstedelsesfunksjonen, fordi registrering og tilbakekalling skrives med rene INSERT/UPDATE.
- En identitet begynner alltid inert. Auditskriveren registrerer en INSERT som nøyaktig én
  hendelse, så en registrering som samtidig utstedte legitimasjon eller trakk identiteten
  tilbake, ville utført to rettighetsendringer til uten å loggføre dem.
- Hva som teller som «utfører handlingen», avgjøres av tilstandsendringen og ikke av om
  aktørkolonnen flyttet seg: en rotasjon med samme utsteder som sist kontrolleres på nytt.
  Aktørradene låses med `for share`, slik at en samtidig tilbaketrekking ikke kan gli inn
  mellom kontrollen og skrivingen.
- Regelen har to ledd, ikke ett. En tilbaketrukket aktør kan heller ikke *få* nye
  rettigheter: agentaktøren selv kontrolleres ved registrering og ved rotasjon. En
  legitimasjon utstedt mens aktøren var ute av bruk, ville blitt gyldig i det aktøren tas i
  bruk igjen — uten at noen hadde utstedt noe etter reaktiveringen. Tilbakekalling er unntatt:
  å rydde opp i en identitet hvis aktør allerede er ute av bruk, skal alltid være mulig. Hele flyten er dessuten kjørt over
ekte HTTP gjennom PostgREST med publishable-nøkkelen som `anon`: feil hemmelighet og feil
rolle gir begge 401 med identisk melding, riktig legitimasjon gir en kjøring, avslutningen gir
200, og tabellene selv er ikke eksponert.

**To i den fjerde runden, begge i selve evidenskontrollen.** Den første er den andre feilen i
denne PR-en som kunne gitt en falsk `verified`:

1. **Kliniske tallverdier mistet presisjon på vei ut av databasen.**
   `api.extraction_verification_input(...)` la `estimate`, `ci_lower`, `ci_upper` og
   `ci_level_percent` rett inn i jsonb som `numeric`. De ble da JSON-tall, og et JSON-tall blir en
   IEEE-754 double i det `JSON.parse` leser svaret — før noen linje i verifikatoren kjører.
   Et lagret `9007199254740993` var allerede blitt `9007199254740992`, og
   `0.1234567890123456789` var blitt `0.12345678901234568`. Kommentaren i parseren sa at den leste
   tall som tekst for å bevare presisjonen; avrundingen hadde skjedd et lag tidligere.

   Konsekvensen er en falsk bekreftelse: står den avrundede verdien i kilden mens den lagrede ikke
   gjør det, ville `estimate` blitt ført som kontrollert for et tall som ikke står der. De fire
   feltene serialiseres nå med `::text`, slik `timepoint_min` og `timepoint_max` alt gjorde, og
   parseren *kaster* på et tall framfor å bruke det — så en senere endring i api-funksjonen ikke
   kan gjeninnføre avrundingen stille. Prøvd i begge ender: pgTAP kontrollerer at svaret gir tekst
   og at `1.0000000000000000001` beholder hvert siffer, og enhetstestene går gjennom `JSON.parse`
   framfor et håndbygd objekt, fordi det er nettopp der presisjonen gikk tapt.

2. **Konfidensintervallet ble ført som kontrollert uten at nivået var det.** Kontrollen så bare på
   `ci_lower` og `ci_upper`. Et registrert 90 %-intervall kunne dermed bli `verified` mot en kilde
   som skriver «95% CI 0.4 to 2.6», og auditsporet ville sagt at intervallet var etterprøvd.
   «0,4 til 2,6» er ikke samme påstand med 90 % som med 95 %, og databasen krever da også begge
   eller ingen (`evidence_items_confidence_level_pairing_check`). Nivået inngår nå i tallkontrollen
   under `confidence_interval`, og feltet føres først som kontrollert når nedre grense, øvre grense
   og nivå alle er gjenfunnet.

Begge er mutasjonstestet, og ingen av dem endrer utfallet for de to seedede funnene: de rapporterer
ikke konfidensintervall, og estimatet `0.8` har ingen presisjon å miste.

**Den femte runden fant at nivåkontrollen over var halv.** Rettelsen la nivået til som et *tredje
uavhengig tallsøk*, og tre tall søkt hver for seg i hele teksten kan komme fra tre forskjellige
steder:

```text
90 participants were enrolled. The effect was 1.5 kg (95% CI 0.4 to 2.6).
```

Et funn registrert med 0,4–2,6 og nivå **90 %** fant alle tre tallene her: `90` fra utvalget, og
grensene fra et intervall kilden oppgir med *et annet* nivå. Kilden sier 95 %, raden sier 90 %, og
kontrollen sa `verified`. Reprodusert før rettelsen.

Intervallet kontrolleres nå som **én påstand rundt et anker**: stedet der kilden selv navngir et
konfidensintervall. Nivået må stå inntil ankeret, slik kilder faktisk skriver det («95% CI»,
«CI 95%», «95 % konfidensintervall»), og de to grensene må stå som *ett intervalluttrykk* i vinduet
rundt det samme ankeret — ikke som to tall som tilfeldigvis begge finnes der. Den andre halvdelen er
like nødvendig som den første: «0,4 til 1,9 … 1,1 til 2,6» inneholder både 0,4 og 2,6, men ingen av
intervallene er 0,4–2,6.

Inne i et navngitt intervall leses en bindestrek som intervallets strek og ikke som et minustegn, så
«95% CI 0.4-2.6» — den vanligste skrivemåten i MEDLINE-sammendrag — kjennes igjen. Utenfor et slikt
anker gjelder fortsatt den strengere regelen fra fjerde runde, der en bindestrek ikke kan skilles
fra et fortegn. Navngir kilden ikke noe intervall, er utfallet `uncertain` og ikke et avvik:
grensene kan stå i en tabell som ikke er med i representasjonen.

Mutasjonstestet: settes kontrollen tilbake til tre uavhengige globale tallsøk, feller de tre nye
testene den. De to seedede funnene er kjørt på nytt mot sine reelle NCBI-poster og er fortsatt
`verified` — ingen av dem rapporterer konfidensintervall.

**Den sjette runden viste at «samme vindu» ikke er «samme uttrykk».** Ankerregelen over lukket
eksempelet den ble skrevet for, men to nye viste at et vindu fortsatt har et «i nærheten» et annet
tall kan smyge seg inn i:

```text
n=90; CI 0.4 to 2.6
95% CI was not reported; observed values ranged from 0.4 to 2.6.
```

I den første er `90` en utvalgsstørrelse — kilden sier aldri prosent, og sier dermed ikke hvilket
nivå intervallet har. I den andre sier kilden uttrykkelig at intervallet *ikke* er rapportert, og
grenseparet hører til noe annet. Begge lå innenfor vinduet, og begge ble bekreftet. Reprodusert
før rettelsen.

Intervallet kontrolleres nå som **ett sammenhengende uttrykk**, og de to kravene er hver for seg
det som stopper hvert av eksemplene:

| Krav | Hva det stopper |
| --- | --- |
| Nivået må være en eksplisitt prosentangivelse (`95%`, `95 %`, `95 percent`) | `n=90; CI …` — et nakent tall ved ankeret er ikke et nivå |
| Delene bindes sammen av høyst 16 tegn uten et eneste siffer | `95% CI was not reported; … 0.4 to 2.6` — det er ikke ett uttrykk, det er to setninger |

Fire rekkefølger godtas, og det er de kilder faktisk skriver: nivået foran eller bak ankeret, og
grensene foran eller bak begge. Begge kravene er mutasjonstestet hver for seg — fjernes
prosentkravet feller to tester, løsnes limet feller en.

**Den syvende runden fant at «kort og sifferfritt» ikke er det samme som «nøytralt».** Limet var
«hva som helst uten siffer, høyst 16 tegn», og en benektelse passer i den beskrivelsen:

```text
95% CI was not 0.4 to 2.6
95% CI, not 0.4 to 2.6
```

Kilden sier uttrykkelig at 0,4–2,6 *ikke* er intervallet, og begge ble bekreftet. Reprodusert før
rettelsen. En verifikator som skal lete etter numeriske avvik, må ikke kunne bekrefte et talluttrykk
gjennom en benektelse.

Limet er nå en **tillatelsesliste** og ikke en lengdegrense: skilletegn, mellomrom, en gjentakelse
av selve intervallnavnet («… interval (CI) …»), og en kort liste nøytrale koblingsord (`of`, `was`,
`is`, `med`, `fra` …). Et ord som ikke står på listen — `not`, `except`, `unlike`, `ikke` — bryter
uttrykket. Punktum er heller ikke lim: en setningsgrense er ingen forbindelse.

Listen er bevisst kort, og retningen på feilen er valgt: en skrivemåte kontrollen ikke kjenner igjen
gir `uncertain`, altså en uavklart kontroll — ikke en falsk bekreftelse. Mutasjonstestet: settes
limet tilbake til den sifferfrie lengdegrensen, feller fire tester det, mens den positive formen
«95% CI was 0.4 to 2.6» fortsatt må bekreftes.

**Den åttende runden tok den samme lærdommen til skalarene.** Konfidensintervallet var kontrollert
mot sin egen kontekst, men `sample_size` og `estimate` ble fortsatt søkt som nakne sifferrekker i
hele representasjonen:

```text
registrert sample_size = 90   kilden sier «90% improved»
registrert estimate = 15      kilden sier «15 mg once daily»
```

Tallet fantes; verdien var aldri oppgitt for det feltet. Feltet ble likevel ført opp i
`checked_fields`, og raden kunne bli `verified`. Reprodusert før rettelsen.

Tallet må nå stå inntil et uttrykk som navngir feltet — «N = 48», «284 adults», «mean weight gain
of 0.8» — med det samme nøytrale limet som konfidensintervallet bruker. Ordlistene er korte med
vilje, og **enheten alene er ikke et anker for estimatet**: «15 mg» navngir en dose, ikke et
effektestimat, og et felt kontrollert mot en dose ville vært nøyaktig feilen dette skal hindre.

Samme runde lukket en grense til: `1.5` ble funnet inne i `1.5e-3`, som er 0,0015 og altså et helt
annet tall. En eksponent hører til tallet og er ikke tekst etter det, så tallgrensen avviser den nå
— også på øvre konfidensgrense, der `2.6` ikke lenger finnes i `2.6e-3`.

**Prøven som betyr noe:** begge de reelle NCBI-funnene er fortsatt `verified` under den strengere
regelen. «sertraline, N = 48» og «a mean weight gain of 0.8 +/- 2.7 kg» er begge former listene
kjenner igjen — og i den første kilden står `48` dessuten i et titalls referanser, som den gamle
regelen ville akseptert som treff. Begge rettelsene er mutasjonstestet hver for seg.

**Den niende runden strammet ordlistene til å faktisk navngi feltet.** Første utkast hadde verb i
ankerlisten for utvalgsstørrelse, og et verb sier hva som ble gjort — ikke hva som telles:

```text
registrert sample_size = 12   kilden sier «Participants completed 12 weeks of treatment.»
registrert estimate = 12      kilden sier «The median was 12 months.»
```

Begge ble bekreftet. Reprodusert før rettelsen — den andre fant jeg da jeg lette etter samme
feilklasse på estimatsiden, som gjennomgangen ikke hadde pekt på.

| Fjernet | Hvorfor | Hva som dekker de virkelige formene i stedet |
| --- | --- | --- |
| `included`, `enrolled`, `recruited`, `completed`, `randomized`, `total of` foran tallet | Sier hva som ble gjort, ikke hva som telles | Deltakerordene *bak* tallet: «enrolled 48 **patients**», «a total of 284 **adults**» |
| `mean`, `median`, `average`, `gjennomsnitt*` som anker for estimatet | Statistikk over hva som helst, ikke navnet på et effektmål | Det effektspesifikke ordet, som står der uansett: «a mean weight **gain** of 0.8», «the mean **difference** was 0.8» |

`n` krever nå `=` eller `:` rett etter: «N = 48» navngir utvalget, en løs `n` i nærheten av et tall
gjør det ikke. Verbene ga altså ingen dekning listene ikke allerede hadde — bare en åpning. Begge
innstrammingene er mutasjonstestet, og begge de reelle NCBI-funnene er fortsatt `verified`.

**Den tiende runden lukket to ting: en SSRF-omvei og bindingen mellom tall og funn.**

*NAT64 er to prefikser, ikke ett.* Vakten leste de siste 32 bitene som destinasjonen for hele
`64:ff9b::/32`. Det er bare riktig for `/96`. RFC 6052 tillater også kortere prefikser, og den lokale
blokken `64:ff9b:1::/48` (RFC 8215) bruker en slik: der er de siste 32 bitene suffiks. I
`64:ff9b:1:a00:0:100:808:808` er destinasjonen **10.0.0.1** — privat — mens de siste 32 bitene er
8.8.8.8 og ser offentlige ut. Vakten slapp den gjennom; det er prøvd. Nå pakkes bare `/96` ut, og
resten av `64:ff9b::/32` avvises: en destinasjon vakten ikke kan lese, er ikke en den kan godkjenne.
Samme runde tok inn de IPv6-blokkene registeret har fått siden: `100:0:0:1::/64` (dummy),
`3fff::/20` og `5f00::/16` — og Teredo-regelen ble utvidet til hele `2001::/23`, som også dekker
benchmarking, ORCHIDv2 og drone remote id. Grensene er prøvd i begge retninger, slik at
publikumsadresser like utenfor blokkene fortsatt slipper gjennom.

*Et tall må tilhøre funnet, ikke bare artikkelen.* Tallene ble søkt i hele representasjonen, og en
artikkel beskriver ofte flere armer og flere utfall:

```text
raden gjelder sertralin med sample_size = 48
artikkelen sier «paroxetine, N = 48» et annet sted
```

Feltet ble ført opp i `checked_fields` fordi en *annen arm* hadde det tallet. Bindingen som manglet,
fantes allerede: `raw_extraction` er funnets egne ordrette utdrag, og de er nettopp verifisert ord
for ord mot representasjonen. Tallene søkes derfor i dem. Er ingen utdrag gjenfunnet, føres ingen
tallfelt opp — samme regel som gjelder kildepekeren, og av samme grunn.

Innstrammingen krevde at fiksturen fikk to utdrag, som de seedede radene alt hadde: et funn som
oppgir utvalgsstørrelse må ha et utdrag som sier den. **Begge de reelle NCBI-funnene er fortsatt
`verified`** — «sertraline, N = 48» og «a mean weight gain of 0.8 +/- 2.7 kg» står begge i funnenes
egne utdrag, mens `48` i den samme artikkelens referanseliste og i paroksetin-armen nå er utenfor.
Begge rettelsene er mutasjonstestet hver for seg.

**Den ellevte runden fant tre ting, og den første gjorde at hele kjøringen falt.**

*`uncertain` kunne ikke registreres.* `workflow.evidence_verifications` krever en ikke-tom
`findings` for alt som ikke er `verified` (migrasjon 005), mens kontrollen med vilje ga
`findings: null` for et uavklart utfall. En helt normal uavklart kontroll ble derfor avvist av
databasen, og `runExtractionVerification` felte hele kjøringen. Feilen var usynlig i alle tidligere
kjøringer, fordi begge de reelle funnene endte som `verified` — reprodusert ende-til-ende først da
innstrammingen under gjorde dem uavklarte:

```
api.register_extraction_verification ble avvist:
new row … violates check constraint "evidence_verifications_findings_required_check"
```

Databasens regel er den riktige: en rad som ikke er bekreftet, skal si hvorfor der en leser ser
etter det. Kontrollen skriver derfor en begrunnelse, og den begynner med «Kontrollen konkluderte
ikke, og dette er ikke et avvik», slik at den ikke kan leses som en anklage. Bare de merknadene som
faktisk sier hva som *ikke* ble avgjort går inn; `rationale` beholder alle.

*IPv6-vakten var en avvisningsliste der den måtte være en tillatelsesliste.* IANA deler ut global
unicast fra `2000::/3`; resten av rommet er reservert. `4000::1` og `6000::1` sto ikke i noe
special-purpose-register og slapp derfor gjennom — men et reservert prefiks kan godt ha en intern
rute. Vanlige IPv6-adresser må nå ligge innenfor `2000::/3`, med de innpakkede formene håndtert før
regelen og avvisningslisten beholdt foran den, fordi den gir presise grunner for loopback og
link-local framfor den generiske.

*Et tall må tilhøre armen, ikke bare utdraget.* Å søke i funnets egne utdrag var ikke nok: et helt
vanlig utdrag beskriver flere armer i én setning, og da står den registrerte verdien der — men det
gjør de andre armenes verdier også. Kontrollen teller nå opp **alle** verdiene utdraget oppgir for
feltet. Er det nøyaktig én, og den er den registrerte, er raden bekreftet; er det flere, står feltet
uavklart. Samme regel gjelder konfidensintervallet, der flere intervalluttrykk i ett utdrag gir
samme utfall.

Grensen er skrevet ut framfor pyntet på: opptellingen ser det samme mønsteret bekreftelsen ser, så
en andre arm skrevet på en form ankerlisten ikke dekker, blir ikke oppdaget. Å telle med en løsere
regel enn den som bekrefter ble prøvd og forkastet — den fant tall langt unna og gjorde nesten
enhver rad uavklart, altså en verifikator som ikke lenger sier noe. Alle tre rettelsene er
mutasjonstestet hver for seg.

**Den tolvte runden fant at en samling utdrag ikke er en binding, og at 4000-grensen bare var halvt
håndhevet.**

*Utdraget må selv si hvilken arm det gjelder.* Å lese tallene fra funnets utdrag var ikke nok, fordi
utdragene ble slått sammen til én tekst. Et funn med to utdrag:

```text
«Sertraline-treated patients were included in the trial.»
«Paroxetine patients (N = 48) had mean weight change 1.5 kg (95% CI 0.4 to 2.6).»
```

Begge står ordrett i kilden, sertralin finnes, endepunktet finnes, og det er nøyaktig én kandidat
per felt — men alle tallene tilhører paroksetin. Utfallet ble `verified`. Reprodusert før rettelsen.
Tallene leses nå bare fra de utdragene som *selv* navngir funnets intervensjon, og begrepene leses
fra funnets utdrag av samme grunn: at legemiddelnavnet står et sted i artikkelen, sier ingenting om
denne raden. Det er også blitt en regel for redaktøren, og en rimelig en: et utdrag som skal
etterprøve et tall, må ta med armen tallet gjelder.

*Begge tekstfeltene har en grense, ikke bare det ene.* `findings` og `rationale` er begrenset til
4000 tegn hver, mens `raw_extraction` er jsonb uten tilsvarende grense. Avkortingen gjaldt bare
fallback-teksten for `uncertain`: et funn med mange eller lange utdragsnøkler ga en `rationale` på
10 448 tegn, som basen ville avvist. Grensen håndheves nå på begge feltene og på hver vei ut av
kontrollen.

*Og registreringen er flyttet innenfor innkapslingen.* En avvist rad felte hele kjøringen, slik at
de øvrige funnene sto ukontrollert av en grunn som ikke var deres. En avvisning er nå den ene radens
problem: funnet føres som overhoppet med databasens egen begrunnelse, og køen går videre. Alle tre
rettelsene er mutasjonstestet hver for seg.

**Den trettende runden fant to forvekslinger til, og den første er den farligste i akkurat dette
registeret.**

*Legemiddelnavn ble matchet som delstreng.* «citalopram» står inne i «escitalopram», og
«venlafaxine» inne i «desvenlafaxine». Et ordrett utdrag om escitalopram bandt derfor en
citalopramrad, og tallene i det ble kontrollert som om de var citalopramradens. Begreper matches nå
med ordgrense.

Grensen foran begrepet er den som avgjør, fordi de klinisk farlige forvekslingene er nettopp de
prefikserte formene — `es-`, `des-`, `levo-`. Etter begrepet tillates inntil to bokstaver, fordi
katalogen er på norsk og kildene på engelsk og forskjellen som regel er en endelse: «sertralin» mot
«sertraline». Uten den åpningen ville ingen norsk legemiddeletikett matchet en engelsk kilde. To
bokstaver er nok til endelsen og for lite til å nå et annet virkestoffnavn.

*Et estimat hører til ett endepunkt hos én arm.* Bindingen filtrerte bare på intervensjonen, mens
endepunktet ble kontrollert mot alle utdragene under ett. To sanne utdrag kunne dermed settes sammen
til en gal rad:

```text
«Sertraline-treated patients had a mean change of 5.0 points on the HAM-D scale.»
«Body weight change was the prespecified primary outcome.»
```

Begge står ordrett i kilden, og sammen «bekreftet» de en sertralinrad om vektendring med estimat
5,0 — et tall som hører til HAM-D. Estimat og konfidensintervall krever nå ett utdrag som navngir
både armen og endepunktet. Utvalgsstørrelsen krever fortsatt bare armen, fordi den er en egenskap
ved armen og ikke ved endepunktet.

**Konsekvensen er skrevet ut framfor pyntet på:** katalogen er på norsk og kildene på engelsk, så et
endepunkt som «vektendring» står sjelden i en engelsk kilde. Estimat og konfidensintervall vil derfor
stå uavklart for de fleste reelle kilder inntil et ledd som forstår språk finnes. Det er den riktige
enden å ta feil i — alternativet er en bekreftelse som bygger på at to sanne setninger om
forskjellige ting stod i samme artikkel. Begge rettelsene er mutasjonstestet hver for seg.

**Den fjortende runden flyttet bindingen fra utdraget til setningen.** Å velge ut de utdragene som
navngir armen — og for effektmål endepunktet — var ikke nok, fordi ett utdrag kan navngi flere:

```text
«Weight change was assessed. Sertraline and paroxetine were compared;
 paroxetine patients (N = 48) completed the trial.»

«Sertraline-treated patients had a mean change of 5.0 points on HAM-D;
 body weight change was also recorded.»
```

Det første utdraget navngir sertralin, men den eneste utvalgsstørrelsen tilhører paroksetin. Det
andre navngir både riktig arm og riktig endepunkt, men det eneste estimatet tilhører HAM-D — og det
nådde `verified`. Begge er reprodusert.

Utdragene deles nå i setninger, og et tall teller bare fra en setning som selv navngir armen — og
for estimat og konfidensintervall også endepunktet. Delingen går på punktum, semikolon, utropstegn
og spørsmålstegn; ikke på kolon, fordi «CI 95%: 0,4 til 2,6» ville blitt delt i to, og ikke på komma,
fordi et komma sjelden skiller to påstander om forskjellige armer. Et punktum mellom to sifre er et
desimalskilletegn og deler ingenting. Mutasjonstestet: settes bindingen tilbake til utdragsnivå,
feller de tre nye testene den.

**Den femtende runden viste at setning heller ikke er det samme som påstand.** To endepunkt kan stå
i én grammatisk setning:

```text
«Sertraline-treated patients had a mean HAM-D change of 5.0 points
 (95% CI 4.0 to 6.0), while body weight change was also recorded.»
```

Setningen navngir både armen og radens endepunkt, mens estimatet og intervallet tilhører HAM-D — og
den nådde `verified`. Reprodusert.

Rettelsen er **nærhet**, ikke enda et skilletegn i delingen: et tall må stå *inntil* det som binder
det. Utvalgsstørrelsen bindes til armen («sertraline patients (N = 284)»), og effektmålene til
endepunktet («weight change of 1.5 kg»); armen er allerede bundet på setningen. Å kreve armen inntil
et effektmål ville krevd at den sto klistret til verdien, og det gjør den nesten aldri — armen er
setningens subjekt og endepunktet står imellom. Konfidensintervallet må stå inntil endepunktet, med
radens *eget* estimat som lim, fordi intervallet hører til nettopp det tallet: er estimatet ikke
bekreftet, er intervallet det heller ikke.

Samme runde lukket to mindre feil som ble synlige underveis:

| Feil | Hva den gjorde |
| --- | --- |
| Setningsdeleren delte ikke et punktum rett etter et tall | «… N = 48. Sertraline …» ble én setning. Regelen skulle verne desimaltall, men et punktum er bare et desimalskilletegn når det står *mellom* to sifre |
| Et registrert tall med etterfølgende nuller kunne aldri gjenfinnes | `4,0` ble trimmet til `4`, og grensen bak mønsteret avviste så «4.0» i kilden. Et registrert `4,0` kunne dermed ikke matche en kilde som skriver `4.0` |

Den siste er verdt å merke seg: den gjorde at et helt korrekt tall aldri kunne bekreftes, altså en
feil i den trygge retningen — men like fullt en feil, og den ble bare synlig fordi kontrollen ble
prøvd mot et intervall skrevet med nuller. Alle fire rettelsene er mutasjonstestet hver for seg.

**Den sekstende runden lukket tre huller i nærhetsbindingen.**

*Begrepsankeret hadde ikke grensene kommentaren lovet.* `termAnchor` var igjen en delstrengsjekk, så
i «`Citalopram was compared with escitalopram-treated patients (N = 48).`» slapp setningen gjennom
det ytre filteret på ekte «Citalopram», mens nærhetsmønsteret bandt tallet til delstrengen inne i
«escitalopram». Ankeret har nå de samme ordgrensene som filteret.

*Et snitt av tallverdier er ikke en binding.* To forskjellige forekomster kunne dekke hver sin
halvdel: «`Sertraline 48 mg daily was used`» ga 48 fra armnærheten, «`Sertraline was compared with
paroxetine patients (N = 48)`» ga 48 fra feltankeret, og snittet ble `{48}` uten at noen ett sted sa
at sertralinarmen hadde 48 deltakere. Mønsteret krever nå at det bindende begrepet, feltets anker og
tallet står i **samme treff**.

*Enheten bak tallet forteller hvilken rolle det har.* «`body weight change at 5.0 weeks`» oppgir et
tidspunkt, «`Sertraline 48 mg daily`» en dose — og et generelt nærhetsmønster ser ingen forskjell.
En utvalgsstørrelse er et antall personer og står aldri med en måleenhet etter seg; et effektestimat
er verken et tidspunkt eller et antall personer. Et tall som står rett etter «N =» er dessuten et
utvalg uansett hva som kommer etter det. Samme runde tok `and`/`og` ut av limet, av samme grunn som
`while` og `not`: de føyer til en ny påstand, og et intervall fra ett endepunkt skal ikke kunne
kobles til det neste gjennom dem.

Alle tre er mutasjonstestet hver for seg.

**Den syttende runden fant tre veier til en falsk `verified` i den samme bindingen — og alle tre
handlet om at tallet tilhørte noe annet enn raden.**

*Et legemiddelnavn navngir armen, ikke feltet.* Begrepet kunne stå som *alternativ* til feltets eget
anker, og for utvalgsstørrelsen er begrepet bare legemiddelnavnet. «`Sertraline: 48 tablets were
dispensed`» bekreftet dermed en registrert `sample_size = 48`. Å svarteliste `tablets`, `centres`,
`sites` … ville aldri blitt komplett; uttrykkene som *navngir* et utvalg, er derimot få og kjente.
Begrepene er nå krav ved siden av ankeret og ikke alternativer til det, og utvalgsstørrelsen
bekreftes bare når samme treff både sier at tallet er et antall personer og binder det til armen.

*Én setning kan navngi det raden trenger og likevel tilskrive tallet en annen arm.* Effektmålene var
bundet til armen på setningen og til endepunktet i uttrykket, så «`Sertraline and paroxetine were
compared, and body weight change was 5.0 kg (95% CI 4.0 to 6.0) in paroxetine patients`» bekreftet en
**sertralin**rad med både estimat og intervall. Armen, endepunktet og verdien må nå stå i samme
sammenhengende treff, i en hvilken som helst rekkefølge. Det som stopper en gal binding, er at limet
er en tillatelsesliste: et annet legemiddelnavn er alltid et ord limet ikke kjenner. Rekkevidden er
en sekundær grense, og radens *egne* øvrige tall — «`(N = 48)`» mellom armen og verdien — er lim,
fordi et fremmed tall der er nettopp signalet om at setningen har begynt å snakke om noe annet.

*Enheten er en del av påstanden.* `estimate_unit` ble ikke brukt i det hele tatt, så en rad med
`estimate = 1,5` og `estimate_unit = kg` ble bekreftet av «`a mean weight change of 1.5%`» — samme
tall, en helt annen klinisk størrelse. Et dimensjonalt estimat må nå gjenfinnes sammen med enheten
det er registrert med, og estimatet limer bare konfidensintervallet til endepunktet med den samme
enheten.

Alle tre er mutasjonstestet, og de to som ikke falt på første forsøk fikk skarpere tester framfor
mildere krav: intervallets armbinding er prøvd på en setning der radens eget estimat *er* bekreftet,
og enhetslimet på en setning der samme sifferrekke står både med og uten enhet.

**Den attende runden fant den siste veien til en falsk `verified`, og den ble tydeligere nettopp
fordi tallbindingen var blitt strengere.** Et registrert klinisk begrep som ikke lot seg gjenfinne,
ble notert i begrunnelsen og holdt utenfor `checked_fields` — men det påvirket ikke utfallet.
Databasen fanger det ikke: for `verified` krever den `source_locator` i `checked_fields`, ikke armen
eller endepunktet. En rad uten oppgitte tallfelt hadde da ingenting igjen som kunne gjøre den
uavklart, og et ordrett — men fullstendig irrelevant — utdrag bar hele raden:

> Raden gjelder `sertraline` og `weight change`. `raw_extraction` er utdraget
> «`The trial was randomized and double blind.`», som står ordrett i riktig kildeversjon.

Sitatet ble gjenfunnet, kildepekeren korroborert, ingen tallkontroll kunne slå ut — og utfallet ble
`verified`, uten at kontrollen noen gang hadde sett at utdraget handlet om dette legemiddelet eller
dette endepunktet. Et manglende begrep gjør nå utfallet `uncertain`, fortsatt ikke
`needs_correction`: en norsk etikett mot en engelsk kilde er den vanligste grunnen, og den er ikke en
feilekstraksjon.

Regelen er prøvd ett begrep om gangen — intervensjon, endepunkt, aktiv komparator og rapportert
populasjon — med et utdrag som navngir alt *unntatt* det ene testen handler om, pluss reviewerens
egen sak i sin helhet og en positiv kontroll der begrepene faktisk står der. Mutasjonstestet: uten
regelen feller fem tester.

Fiksturens `population_label` var samtidig den eneste norske etiketten i en ellers engelsk fikstur,
og det var en inkonsistens uten konsekvens fram til nå. Den positive kontrollen skal være positiv,
så etiketten følger resten av fiksturen; at en norsk etikett mot en engelsk kilde gir `uncertain`, er
prøvd der det hører hjemme.

**Den nittende runden tok den samme lærdommen til begrepene.** Rettelsen i runde 18 krevde at hvert
begrep var gjenfunnet, men hvert *for seg*, mot den flate samlingen av utdrag — nøyaktig den feilen
tallene ble rettet for i runde 12 og 14. To ordrette og sanne utdrag kunne dermed sys sammen til én
gal rad:

> «`Sertraline-treated patients discontinued treatment because of nausea.`»
> «`Paroxetine-treated patients had a mean body weight change over the trial.`»

Begge står i kilden, `intervention_arm` ble kontrollert fra det første og `outcome` fra det andre, og
ingen del av kilden sier at vektendringen gjelder sertralin. Å kreve dem i samme *utdrag* ville ikke
holdt: ett utdrag kan beskrive flere armer, og ren forekomst skiller ikke en positiv binding fra en
benektelse — «`No participants received sertraline; paroxetine-treated patients had …`».

For `verified` kreves nå et lokalt støttefragment som binder intervensjonen til endepunktet: begge
begrepene i **ett sammenhengende treff**, med bare kjent lim imellom, akkurat som for tallene. `not`,
`and` og et fremmed legemiddelnavn er alle ord limet ikke kjenner. Regresjon for begge reviewerens
saker, for en benektelse i samme setning, og for to påstander skilt med semikolon — den siste viser
at setningsdelingen er bærende, siden semikolon er lim inne i et uttrykk («`CI 95%: 0,4 til 2,6`»)
men skiller to påstander. Den positive kontrollen er beholdt.

Tre mutasjoner faller: at bindingen ikke påvirker utfallet, at den søkes i hele utdraget framfor i
påstanden, og at den bare er samforekomst.

**Den tjuende runden tok bindingen ut til resten av raden — og avviste ett av tre punkter.**

*Komparatoren og populasjonen var fortsatt bare ordtreff.* «`Paroxetine was not used as a comparator
in this analysis`» førte `comparator_arm` opp som kontrollert, og «`Patients with major depressive
disorder were excluded from this analysis`» gjorde det samme for populasjonen — begge mens
arm-til-endepunkt-bindingen kom fra et helt annet utdrag. Begge deler er nå bundet lokalt:
komparatoren må stå navngitt **som** komparator (`compared with`, `versus`, `kontrollgruppen`, …), og
populasjonen må stå knyttet til armen. Benektelser stoppes av det samme limet som ellers — `not` er
ikke lim. `placebo` er samtidig gjort til et kontrollerbart begrep på linje med et virkestoffnavn;
det var ikke kontrollert i det hele tatt før.

*Forskjellen på en presisering og en kontrast er skrevet inn.* Radens egen populasjonsetikett er lim
mellom armen og verdien — «`Sertraline-treated patients with major depressive disorder had a mean
weight change`» er én påstand — mens komparatornavnet ikke er det. Et kontrastord mellom armen og
verdien er nettopp signalet om at verdien kan tilhøre den andre armen, og forskjellen er
mutasjonstestet.

*Det tredje punktet er ikke en feil.* Reviewer leste `comparator_kind = none` som «det finnes ingen
komparator», og pekte på at fiksturen har `none` mens kilden sier «`Fluoxetine was the comparator.`».
Vokabularet sier noe annet: `none` betyr at **funnet** er armspesifikt, ikke at studien manglet en
komparator — «et enarmet gjennomsnitt hentet fra en sammenlignende studie har komparator none»
(migrasjon `20260819064500`). Fiksturen er nettopp det dokumenterte tilfellet: et `mean_change` for
sertralinarmen, hentet fra en sammenlignende studie. Å gjøre `none` til noe som blokkerer `verified`
ville gjort hvert eneste armspesifikke funn permanent uavklart, av en grunn som ikke er et avvik.
`none` er en påstand om hvordan ekstraksjonen er avgrenset, ikke om kildens tekst, og det finnes
ingenting i teksten å kontrollere den mot.

Fem mutasjoner faller: komparatoren uten relasjonsanker, populasjonen uten binding til armen, placebo
som ukontrollerbart, bindingene uten virkning på utfallet, og komparatornavnet som lim.

**Den tjueførste runden gjorde bindingene til én binding — og byttet ut hvordan de matches.**

*Flere bindinger som holder hver for seg, er ikke én binding.* Runde 20 kontrollerte arm↔endepunkt,
komparator og populasjon som hver sin binding. Hver av dem kunne da komme fra sin egen påstand:
«`Sertraline-treated patients had a mean weight change over the trial.`» sammen med «`Fluoxetine was
compared with paroxetine for remission.`» ga en bekreftet rad der ingen påstand sier at paroksetin er
komparator for *dette* funnet. Populasjonen hadde samme form, og radens tall var ikke bundet til
kontrasten i det hele tatt. Alle radens aktive deler må nå stå i **ett** sammenhengende treff, og for
estimatet og konfidensintervallet inngår kontrasten i det samme treffet.

*Fiksturen var selv et tilfelle av feilen.* Den bandt populasjonen til armen i metodeutdraget og
endepunktet til armen i resultatutdraget. Resultatutdraget navngir nå alle tre.

*Matchingen er skrevet om, og det var nødvendig.* Ett mønster per rekkefølge betyr 120 mønstre med
fem deler, hvert med nøstede kvantorer — og på en tekst som *ikke* passer, prøver motoren alle måter
å dele limet på. Målt: over 20 sekunder på ett funn. Kildeteksten er utrygg ekstern data (§3.8), så
kjøretiden kan ikke avhenge av at den er snill. Teksten skannes nå én gang venstre til høyre etter
deler og lim; et sammenhengende treff er en ubrutt rekke av slike. Samme regel, uten baksporing:
testfilen gikk fra 44 til 3,5 sekunder.

*Én ekte feil kom ut av omskrivingen.* Limlisten inneholder både `g` og `gjennomsnittlig`. Med
baksporing kom mønsteret seg rundt at `g` stumper av det lange ordet; én gjennomgang gjør ikke det.
Limbitene har derfor en ordgrense bak seg — delt av alle de ordlignende formene, som også er det som
gjør skanningen rask.

Sju mutasjoner faller: radbindingen uten komparatoren, uten populasjonen, estimatet og intervallet
uten kontrasten, limbitene uten ordgrense, rekkevidden uten håndheving, og sammenhengen uten
håndheving.

**Den tjueandre runden lukket det siste stedet der to påstander kunne bli én.** Runde 21 gjorde
radens deler til én binding, men *tallets* binding krevde bare arm, endepunkt og kontrast.
Populasjonen lå i limet — altså som noe som *fikk* stå mellom delene, ikke som noe som *måtte*
finnes. Radbindingen og tallbindingen kunne dermed komme fra hver sin populasjon:

> «`Sertraline-treated patients with major depressive disorder had weight change …`»
> «`Sertraline-treated patients had weight change of 5.0 kg … in adolescents.`»

Den første binder raden, den andre bekreftet tallet, og tallet gjelder uttrykkelig ungdom. En verdi
hører til én arm, ett endepunkt, én kontrast og **én populasjon**, så rapportert populasjon er nå en
påkrevd del av tallets egen binding — også for utvalgsstørrelsen, der et «N = 48» fra en undergruppe
ikke er radens utvalg. Kravet motsa dessuten dokumentasjonen fra forrige runde, som allerede sa at
alle aktive deler *og verdien* skulle stå i samme treff.

Tre mutasjoner faller: utvalgsstørrelsen, estimatet og intervallet uten populasjonen som påkrevd del.

Innstrammingen traff 27 eksisterende tester som bytter ut fiksturens utdrag med sitt eget: de
forteller en annen historie enn fiksturen, og populasjonen er støy i dem. De slår den derfor av
eksplisitt (`UTEN_POPULASJON`) framfor at kravet mykes opp. Fiksturen selv oppgir fortsatt en
populasjon, og utdraget navngir den.

**Den tjuetredje runden fant en kontraktsfeil mellom verifikatoren og publiseringsgaten — ikke i
verifikatoren selv.**

Den deterministiske kontrollen bedømmer **en delmengde** av feltene, og har aldri påstått noe annet:
`checked_fields` sier presist hva den gikk gjennom (DATABASE_ARCHITECTURE.md §29). Den ser verken
tidspunkt, retning, effektmål, availability-semantikk eller forbehold. Publiseringsgatens G5 leste
imidlertid bare `outcome`. En rad registrert med `timepoint = 12 uker` mot en kilde som sier 8, eller
med `sample_size_availability = not_reported` mot et utdrag som sier «N = 48», kunne dermed passere
en gate som er ment å bety at ekstraksjonen er kontrollert.

Feilen er *pre-eksisterende* i gaten, men denne PR-en er det som gjør en automatisk `verified` mulig
i skala, så den lukkes her. Migrasjon **006b** legger til `workflow.required_check_fields(...)` og et
nytt vilkår **G5b**: unionen av `checked_fields` over funnets bekreftede kontroller må dekke feltene
raden faktisk påstår noe om. Kravet utledes fra raden selv framfor fra en liste noen må vedlikeholde
— et felt som ikke er rapportert, påstår ingenting og kreves ikke, men *at* det står som ikke
rapportert, dekkes av `availability_semantics`, som alltid kreves. Unionen, ikke den siste raden:
flere verifikatorledd kan dele arbeidet, mens G5 fortsatt krever at den *siste* kontrollen er en
bekreftelse.

Konsekvensen, skrevet ut: **den deterministiske kontrollen kan aldri alene lukke publiseringsgaten.**
Det er den riktige lesningen av hva den er, og den er nå håndhevet av databasen framfor forutsatt.

Kontrakten er prøvd fra begge sider. I basen: en delkontroll med `outcome = 'verified'` avvises av
gaten, kravet nevner et rapportert tidspunkt og availability-semantikken, og to verifikatorledd som
til sammen dekker kravet, slipper gjennom. I kjøreren: `CHECKABLE_FIELDS` er den ene siden av
kontrakten, og en test feller enhver `checked_fields` som går utenfor den — også på den lykkede
stien, der raden er `verified` med felter som fortsatt står ukontrollert. To mutasjoner faller: G5b
fjernet, og `availability_semantics` tatt ut av kravet.

Sju eksisterende testrader måtte oppgi full dekning framfor `array['source_locator', 'estimate']`.
De bruker nå `workflow.required_check_fields(e.id)`, altså den samme utledningen gaten bruker, slik
at de holder seg selv oppdatert.

**Den tjuefjerde runden fant en feil i G5b selv, i måten den møter G5 på.** Dekningen ble regnet som
unionen over *alle* historiske bekreftelser. Da fikk et senere avvik en vei ut som G5 er ment å
stenge:

> t1 full bekreftelse, dekker alt · t2 ny kontroll, tidspunktet er uavklart (G5 blokkerer, riktig) ·
> t3 delkontroll bekrefter sitat og begreper → G5 slipper, fordi siste utfall er `verified`, og G5b
> slipper, fordi dekningen for tidspunkt hentes fra t1 — som t2 nettopp underkjente.

Det åpne funnet fra t2 ville dermed vært borte uten at noen så på tidspunktet igjen. Dekningen har nå
**samme gjeldende-semantikk som utfallet**: en bekreftelse teller bare når ingen ikke-bekreftende
kontroll er nyere enn den, med samme rekkefølge G5 bruker for «den siste», slik at de to vilkårene
ikke kan bli uenige om hva som er nyere.

Nullstillingen gjelder alle felter, ikke bare det omstridte, og det er ikke strengere enn nødvendig:
en uavklart kontroll fører opp i `checked_fields` det den *bekreftet*, så feltet den ikke fikk
avklart, er nettopp det som ikke står der. Hvilket felt som er omstridt, er altså ikke avlesbart, og
da er den trygge lesningen at hele ekstraksjonen står åpen til den er kontrollert på nytt.

Regresjonen er reviewerens egen sekvens, i publiseringsgaten: full bekreftelse → uavklart kontroll →
delkontroll som ikke dekker det omstridte feltet (blokkeres) → kontroll som faktisk re-kontrollerer
alt (slipper gjennom). To mutasjoner faller: gjeldende-semantikken fjernet, og bare
`needs_correction` — ikke `uncertain` — som nullstiller.

**Hva denne PR-en bevisst ikke gjør.** Den bygger ikke skriveveien inn i
`workflow.evidence_verifications` — den hører til neste PR og bruker mekanismen her. Den
utsteder ingen legitimasjon i produksjon, registrerer ingen verifikasjon, ingen
reviewbeslutning og ingen publisering, og den åpner ikke publiseringsgaten. Den svekker ingen
eksisterende kontroll: ingen CHECK, ingen policy, ingen grant og ingen gate er fjernet eller
myknet opp.

**Hva som gjenstår for Milepæl B.** Fortsatt de samme tre (§74.4): ekstraksjonsverifikasjonene,
claim-verifikasjonene og selve godkjenningen. Denne PR-en lukker ingen av dem — den fjerner
hindringen foran den første.

**Neste steg er uendret fra §74.30, med fire punkter avgjort framfor tre.** Skriveveien for
ekstraksjonsverifikasjonen skal fortsatt bygges sammen med kildeversjoner (issue 44), og
spørsmålet om hva som er et tilstrekkelig verifikasjonsgrunnlag (§74.30 punkt 2) er fortsatt
det som må avgjøres og ikke antas. Rollen som verifiserer er nå to ting og ikke én: `reviewer`
for et menneske som verifiserer gjennom skjemaet, og agentidentiteten
`agent-identity:extraction-verification-01` for den automatiserte veien. Begge skriver til
samme tabell, og separasjonskravet gjelder likt for begge.

---

### 74.32 Skriveveien for ekstraksjonsverifikasjon — bygget, med punkt 2 avgjort under review

§74.30 listet fire ting én PR skulle avgjøre før skriveveien inn i
`workflow.evidence_verifications` var bygget. Denne PR-en bygger nøyaktig den skriveveien —
`api.register_extraction_verification(...)` — og prøver den fullt ut i test. Punkt 3 og 4
(rollen og hvem som kan verifisere hvem) var avgjort da PR-en åpnet; punkt 2 («adresse pluss
hash» som verifikasjonsgrunnlag) ble avgjort i teknisk review før merge, i samme PR. Punkt 1
(kildeversjoner, issue 44) står fortsatt åpen — det er en eksplisitt avgrensning av denne PR-en,
ikke en forglemmelse.

**Hva som er bygget.** Ett inngangspunkt, i samme form som `api.create_source(...)` og
`api.create_evidence_item(...)`: en autentisert `extraction_verification`-agent, inne i en
åpen `provenance.agent_run` i samme rolle, registrerer én verifikasjonsrad. Aktør, rolle og
kjøring er ikke parametre kalleren oppgir — de utledes av autentiseringen og av kjøringen selv
— og bindingen er deklarativ: to nye sammensatte fremmednøkler
(`evidence_verifications_agent_run_actor_fkey`, `evidence_verifications_agent_run_role_fkey`)
mot `provenance.agent_runs (id, actor_id)` og `(id, agent_role)` fra migrasjon 005e, nøyaktig
slik den migrasjonens hodekommentar forutså. De tre lagene som hindrer selvverifikasjon —
rollen, aktøren og nå kjøringen — er alle prøvd, hver for seg og sammen.

**Punkt 2 er avgjort: adresse pluss hash er et tilstrekkelig verifikasjonsgrunnlag.**
`knowledge.source_versions` sin egen hodekommentar sier hvorfor `retrieved_from` er `NOT NULL`:
«en `content_hash` uten en adresse å hente på nytt fra kan ikke etterprøves». Med begge til
stede kan en tredjepart hente kilden på nytt og kontrollere den mot hashen, uavhengig av om
Antidep har lagret fulltekst i `storage_reference` — det er selve mekanismen
`verifiable_representation` beskriver. `api.register_extraction_verification(...)` håndhever nå
dette: `p_source_access = 'verifiable_representation'` avvises både når evidensfunnets
`source_version_id` er NULL og når kildeversjonen den peker på selv mangler `content_hash`. En
kildeversjon med bare `retrieved_from` (et sporet besøk, uten fingeravtrykk) kvalifiserer altså
ikke. Et reelt evidensfunn uten lagret kildeversjon (som Efexor-funnet, §74.30) har fortsatt
ingenting å kontrollere `verifiable_representation` mot i produksjon, men det er nå fordi
grunnlaget mangler, ikke fordi databasen ikke kan se forskjellen. Issue 44 (selve
kildeversjonsskriveveien) står fortsatt åpen — det er punkt 1, ikke punkt 2.

**Migrasjonsdisiplin: en race-fiks skrevet fremover, ikke inn i en merget fil.**
Migrasjon 20260905092000 (fra PR #48) er allerede merget. En teknisk gjennomgang fanget at en
tidlig versjon av denne PR-en rettet en race condition i `provenance.assert_agent_run_open(...)`
(manglende radlås mellom «kjøringen er åpen»-sjekken og innsettingen) ved å redigere den
migrasjonen direkte — en endring som aldri ville nådd et miljø som allerede har kjørt den, fordi
Supabase aldri kjører en registrert migrasjonsversjon på nytt. Rettelsen ligger nå der den
faktisk virker: en `CREATE OR REPLACE FUNCTION` i denne PR-ens egen migrasjon, som legger
`FOR UPDATE` på radlåsen uten å endre signatur eller rettigheter.

**Hva dette betyr i praksis akkurat nå.** Skriveveien er reviewbar og fullt prøvd, men ingen
legitimasjon er utstedt til `agent-identity:extraction-verification-01` i produksjon (§74.31
sier hvorfor: utstedelsen hører til den PR-en som bygger den faktiske kjøreren). Ingen reell
verifikasjon er derfor registrert i det hostede prosjektet av denne PR-en, og kunne heller ikke
vært det: identiteten er fortsatt inert. Milepæl B mangler fortsatt de samme tre tingene som
§74.4 lister; denne PR-en fjerner en teknisk hindring til, men lukker ingen av dem.

**Neste steg.** Kildeversjonssnapshot (issue 44), deretter utstedelse av legitimasjon til
verifikatoren i det miljøet en faktisk agentkjører leser hemmeligheten fra, og til slutt
claim-verifikasjon (`workflow.claim_verifications`, `citation_support_verification`) som egen,
senere PR.

---

### 74.33 Kjeden er kjørt: fra kildeversjon til registrert verifikasjon

§74.32 endte med en skrivevei som var reviewbar og fullt prøvd, men som ingen hadde kjørt:
`agent-identity:extraction-verification-01` var registrert uten legitimasjon, det fantes ingen
skrivevei for kildeversjoner (punkt 1, issue #44), ingen lesevei inn til grunnlaget, og ingen
kjører. **Denne PR-en lukker alle fire, og kjører kjeden hele veien gjennom mot en reell
kilde.**

**Tre migrasjoner, ingen av dem med en ny enum-type.**

| Migrasjon | Hva den gjør |
| --- | --- |
| 008e | `audit.event_operation` får `source_version_registered`. Alene i sin egen fil, fordi `ALTER TYPE ... ADD VALUE` ikke kan brukes i samme transaksjon som verdien |
| 007f | Skriveveien for kildeversjoner: attribusjon på `knowledge.source_versions`, hashen som databasens eiendom, auditskriveren og `api.create_source_version(...)` |
| 005h | `api.extraction_verification_input(...)` — grunnlaget verifikatoren arbeider fra |

**Punkt 1 er lukket, og tillitsmodellen for `content_hash` er avgjort.** Issue #44 spurte
etter en skrivevei; kommentaren på issuen la til det som var det egentlige spørsmålet: en hash
klienten oppgir, er en påstand ingen kan etterprøve. Svaret er at **hashen aldri er en
parameter**. `api.create_source_version(...)` tar imot representasjonen, og databasen beregner
`knowledge.source_version_content_hash(text)` i samme transaksjon som raden skrives — samme
resonnement som gjorde `content_hash` på et evidensfunn til databasens eiendom (§74.27). De
tre spørsmålene har dermed hvert sitt entydige svar: PostgreSQL beregner den, den beregnes av
nøyaktig den teksten som ble oppgitt uten normalisering, og den etterprøves med
`curl <retrieved_from> | sha256sum`.

**Grensen for hva basen kan garantere er skrevet ut framfor pyntet på.** PostgreSQL kan ikke
hente en URL, så basen kan ikke vite at teksten faktisk kom fra adressen — bare at hashen er
hashen *av den teksten*. Den siste koblingen er verifikatorens, og den er reell: kjøreren
henter adressen på nytt og sammenligner. En registrering der teksten ikke kom fra adressen,
overlever derfor ikke første verifikasjon.

**Attribusjonen som manglet.** `knowledge.source_versions` var den ene kunnskapstabellen uten
`created_by_actor_id` — migrasjon 005 la den på fem tabeller, men ikke på denne, fordi det
ikke fantes noen skrivevei å attribuere. Nå finnes det en. Kolonnen heter
`retrieved_by_actor_id`, fordi raden er en observasjon og ikke et kunnskapsobjekt, og de to
seedede radene er backfilt til ekstraksjonsagenten — samme aktør migrasjon 005 attribuerte
evidensfunnene fra samme seed til, og samme arbeid.

**Kjøreren er deterministisk, og det er et valg og ikke en mangel.** Kontrollen sammenligner
hver ordrett gjengivelse i `raw_extraction` mot representasjonen, og hvert oppgitt tall mot
den samme. ANTIDEP_CONSTITUTION.md §17 sier at kliniske kontroller skal være deterministiske
«der det er mulig», og for sitat- og tallkontroll er det mulig — og strengere enn et
språkmodellkall. §20 er samtidig oppfylt: kjøringen registrerer leverandør (`antidep`), modell
(`deterministic-extraction-check`) og modellversjon som ethvert annet agentledd, så et senere
ledd med språkmodell er et adapterbytte og ikke en datamodellendring.

**Asymmetrien mellom å bekrefte og å avkrefte er kontrollens viktigste regel.** Et sitat er en
påstand om ordrett gjengivelse fra nøyaktig den representasjonen raden peker på, og den
påstanden er falsifiserbar: mangler teksten, er utfallet `needs_correction`. Et *tall* er noe
annet — det kan stå skrevet med bokstaver («Thirty-one HV»), i en annen enhet eller i en
tabell som ikke er med i representasjonen — så et manglende talltreff gir `uncertain` og ikke
et avvik, og feltet føres ikke opp i `checked_fields`. En verifikator som roper ulv, er verre
enn ingen verifikator. Regelen ble ikke funnet på: den ble oppdaget da kjeden ble kjørt mot en
reell kilde som skriver utvalgsstørrelsen med bokstaver.

**Kjøringen registrerer ingen verifikasjon i tre tilfeller**, og det strengeste er det tredje:
funnet mangler kildeversjon eller fingeravtrykk; kilden lot seg ikke hente; eller
fingeravtrykket stemmer ikke med det registrerte. I det siste tilfellet har verifikatoren sett
*en* utgave, men ikke den ekstraksjonen ble gjort fra — og ingen av de tre verdiene i
`workflow.verification_source_access` beskriver det sant. Å oppgi en usann verdi for å få
registrert at kontrollen mislyktes, ville byttet en manglende opplysning mot en usann. Avviket
står i kjøringens `output_manifest`, som er proveniensen for KI-operasjoner.

---

**Kjeden er kjørt mot en reell kilde, i en lokal stack, og dette er avlesningen.** Kilden er
Carbone, Vanuytsel og Tack (2017), *The effect of mirtazapine on gastric accommodation,
gastric sensitivity to distention, and nutrient tolerance in healthy subjects*,
Neurogastroenterology and motility 29(12) — en reell randomisert studie om mirtazapin og
kroppsvekt, hentet fra NCBI eutils.

| Ledd | Avlesning |
| --- | --- |
| 1. Kilde | Opprettet av den navngitte redaktøren gjennom `api.create_source(...)` |
| 2. Kildeversjon | Representasjonen hentet over nett (8 000 byte). Lokal `sha256sum` og databasens egen `content_hash` er identiske: `sha256:73d7f5d6…` |
| 3. EvidenceItem | Registrert med `source_version_id` satt, `extraction_method = manual` |
| 4. Agentkjøring | Åpnet av `agent-identity:extraction-verification-01` som `anon`, med legitimasjon utstedt av redaktøren |
| 5. Kontroll | Adressen hentet på nytt; fingeravtrykket reprodusert; sitatet gjenfunnet ordrett i representasjonen |
| 6. Verifikasjon | `verified`, `verifiable_representation`, `checked_fields = {raw_extraction, source_locator, intervention_arm}` (kjørt før innstrammingene under; se avsnittet om de seedede funnene) |
| 7. Proveniens | Verifikasjonen peker på kjøringen, kjøringen på identiteten, identiteten på agentaktøren — og auditsporet viser `source_created → source_version_registered → evidence_item_created → evidence_verification_registered`, med menneskelig aktør på de tre første og agentaktøren på den siste |

**Den negative veien er kjørt like reelt.** En kildeversjon registrert med et innhold adressen
ikke lenger gir, ble avvist av kjøreren med «Kilden har endret seg», begge fingeravtrykk
oppgitt, og ingen rad ble registrert. Det er den kontrollen som gjør at en `verified`-rad
faktisk betyr noe.

**De to seedede evidensfunnene er også kontrollert, mot sine egne reelle MEDLINE-poster.**
Begge kildeversjonene fra migrasjon 003 reproduserer fortsatt sine registrerte
fingeravtrykk fra NCBI i dag — seks uker etter at de ble registrert. At «adresse pluss hash» er et
etterprøvbart grunnlag (§74.32), er dermed ikke lenger bare et resonnement: det er en avlesning.

Etter innstrammingene under får begge funnene **`uncertain`**, og det er riktig svar. Utdragene
deres er flerarms: «Patients (fluoxetine, N = 44; sertraline, N = 48; paroxetine, N = 47) …». En
deterministisk kontroll kan ikke avgjøre hvilken av dem som er sertralinradens, og sier det, med
kandidatene oppgitt i `findings`. Sitatene, kildepekeren og intervensjonsarmen står fortsatt som
kontrollert. Et `verified` her ville vært en gjetning som så ut som en kontroll.

---

**Rettet under teknisk review: hentingen var en SSRF-vei.** Den første versjonen av kjøreren
hentet `retrieved_from` med `fetch()` og fulgte redirect automatisk, uten noen grense på hvilke
adresser den kunne nå. Gjennomgangen fanget at det gjør en registrert kilde til en fjernstyring
av hva den betrodde maskinen kobler seg til: `localhost`, et privat nett, eller
169.254.169.254 — skymiljøenes metadatatjeneste. Responsen ble dessuten lest ubegrenset inn i
minnet.

Rettelsen er ikke en filtrering av URL-en, og det er hele poenget. Å slå opp navnet, godkjenne
adressen og *deretter* kalle `fetch` ville etterlatt et vindu der DNS kan svare noe annet enn
det som ble godkjent (rebinding). Hentingen bruker derfor `node:https` med en egen
`lookup`-funksjon — den samme funksjonen socketen bruker som sitt eget navneoppslag — slik at
adressen som godkjennes *er* adressen det kobles til. Det finnes ikke to oppslag å komme
imellom.

| Kontroll | Hva den stopper |
| --- | --- |
| Bare `http:` og `https:` | `file:`, `ftp:` og resten |
| Bokstavelige IP-verter kontrolleres direkte | `http://127.0.0.1:8080/`. Node slår ikke opp noe når verten allerede er en adresse, så `lookup` ville aldri sett den — en egen test fanget nettopp den blindsonen i første forsøk på rettelsen |
| Navn kontrolleres i socketens eget oppslag | et navn som peker på en privat adresse, og DNS-rebinding |
| Alle adressene et navn gir, ikke bare den første | et navn som peker på både en offentlig og en privat adresse |
| Hvert redirect-hopp kontrolleres på nytt | en offentlig kilde som sender kjøreren videre innover |
| Størrelsesgrense og samlet tidsavbrudd | en kilde som bruker opp minnet eller tiden til kjøreren |

Adresseparsingen er streng med vilje: `127.000.000.1`, `0x7f.0.0.1` og `2130706433` avvises som
uleselige framfor å bli tolket. En vakt som leser en adresse annerledes enn socketen som kobler
til, er ingen vakt. De innkapslede formene som *er* kanoniske — `::ffff:127.0.0.1` og NAT64 —
pakkes ut og kontrolleres som den IPv4-adressen de bærer.

**Tre ting til, fanget i den andre gjennomgangsrunden.** Alle tre var reelle, og den midterste
er den eneste av alle funnene i denne PR-en som kunne påvirket klinisk innhold:

1. **Tidsavbruddet sluttet å vente uten å rive forbindelsen.** Kilden fortsatte å strømme i
   bakgrunnen, og en kø med mange kilder ville samlet opp åpne socketer. Det samme gjaldt en
   redirect-kropp og et feilsvar, som ble tømt med `resume()` framfor revet. Forespørselen
   rives nå i et `finally` som gjelder hver vei ut av funksjonen, og både redirect og feilsvar
   destrueres framfor å leses ferdig. Prøvd ved å telle socketer på en ekte server — og
   mutasjonstestet: uten rettelsen feller de nye testene den.

2. **Tallkontrollen mistet fortegnet.** `-1,5` ble søkt som `1.5`, så et registrert `-1,5` ble
   bekreftet av en kilde som oppgir `1,5` — og omvendt. En vektendring på −1,5 kg og en på
   1,5 kg peker motsatt vei, så dette kunne gitt `verified` på et funn som snur
   effektretningen. Fortegnet er nå en del av mønsteret: et negativt tall krever et minustegn
   rett foran seg, og et positivt tall avvises når det står med minustegn foran. Skriver kilden
   retningen med ord framfor med fortegn, finner kontrollen ingenting — og da er utfallet
   `uncertain`, som er den riktige enden av asymmetrien. Samme runde tettet at «12» ble funnet
   inne i «12.5».

3. **CI kunne maskert en mislykket kjøring.** Siste linje i arbeidsflyten rørte kjøreren
   gjennom `tee`, og uten `pipefail` er det `tee` sin exit-kode som gjelder — alltid 0. En
   feilet verifikasjonskjøring ville sett grønn ut. `shell: bash` og `set -euo pipefail` er nå
   eksplisitte, og forskjellen er prøvd i et skall før den ble skrevet inn.

**To til, fanget i den tredje gjennomgangsrunden.** Begge var reelle, og den første brøt
nøyaktig den kjeden denne PR-en finnes for å bygge:

1. **Redaktørflaten kunne ikke bevare bytene `content_hash` hevder å beskrive.**
   `/source-versions/new` tok imot representasjonen i en `<textarea>`, og HTML-standarden
   normaliserer linjeskift i feltets API-verdi: en kilde levert med CRLF ble hashet som om den
   hadde LF. Verifikatoren hasher de faktiske bytene fra nettet, så den ville rapportert
   `needs_correction` — «kilden har endret seg» — for en kilde som var uendret, og for hver
   eneste kilde som leveres med CRLF. Feilen var stille: ingenting i basen kunne oppdage den,
   fordi hashen var korrekt beregnet av en tekst som bare ikke var kildens.

   Registreringen tar nå imot en fil. `arrayBuffer()` gir bytene uten normalisering, og
   `src/lib/read-utf8-file.ts` dekoder dem strengt som UTF-8 — samme regel kjøreren bruker på
   svaret sitt — og avviser filen framfor å lagre et fingeravtrykk ingen kan etterprøve.
   Rettelsen er prøvd tre steder: en enhetstest på lesefunksjonen, en sidetest som feller
   `textarea`-semantikken (mutasjonstestet ved å normalisere CRLF i siden — testen feller det),
   og i en faktisk nettleser, der `File` gir kodepunktene `97,13,10,98` mens en `textarea` gir
   `97,10,98`.

2. **En ugyldig numerisk entitet i kildeinnhold kunne felle hele kjøringen.** Søkeprojeksjonen
   avkoder HTML-entiteter for å finne et sitat som står med `&amp;` eller `&#8722;` i kilden.
   `String.fromCodePoint` kaster på et kodepunkt over `0x10FFFF`, så `&#x110000;` i én kilde
   avbrøt hele kjøringen — også kontrollen av alle de andre funnene i køen. Avkodingen er nå
   total: et kodepunkt utenfor området beholdes ordrett framfor å kastes på. I tillegg er hvert
   funn isolert, slik at en uventet feil på én kilde gir «ikke registrert, med begrunnelse» for
   det funnet og lar resten av køen gå videre.

**Og en tredje av samme slag, funnet i gjennomlesingen av rettelsen selv: BOM-en.**
`TextDecoder` fjerner et innledende U+FEFF med mindre man ber den la være, og flaggets navn
(`ignoreBOM`) betyr det motsatte av hva det ser ut til. En kilde som leveres med BOM ville
dermed fått de tre bytene EF BB BF fjernet på vei inn — samme stille brudd som CRLF — og på
vei ut ville verifikatorens gjenkoding manglet dem, slik at `bytesAreUtf8` ble usann og kilden
aldri kunne verifiseres. Begge sider leser nå med `ignoreBOM: true`, og at det henger sammen
er avlest og ikke resonnert: `sha256sum` på en fil med BOM og
`knowledge.source_version_content_hash(...)` på den samme teksten gir samme verdi. Begge de nye
testene er mutasjonstestet — uten flagget feller de rettelsen.

**Hva denne PR-en bevisst ikke gjør.** Den registrerer ingenting i det hostede prosjektet:
migrasjonene er ikke deployet dit, ingen legitimasjon er utstedt der, og ingen verifikasjon er
registrert der. Alt over er kjørt mot en lokal stack. Den bygger heller ikke
claim-verifikasjon, reviewbeslutning eller publisering, og den svekker ingen eksisterende
kontroll: ingen CHECK, ingen policy, ingen grant og ingen gate er fjernet eller myknet opp.

**Hva som gjenstår for Milepæl B.** Ekstraksjonsverifikasjonene er nå *kjørbare*, og G4/G5 kan
lukkes for et funn ved å kjøre kjøreren mot det. De to andre står urørt: claim-verifikasjonene
(G8/G9) og den menneskelige godkjenningen (G11/G12/G13).

**Neste steg.** Deploy av de tre migrasjonene til det hostede prosjektet og utstedelse av
legitimasjon der, slik at kjeden kan kjøres i produksjon — og deretter claim-verifikasjon
(`workflow.claim_verifications`, `citation_support_verification`) som egen, senere PR.

---

### 74.34 Verifikatoren er aktivert i produksjon, og kjeden er kjørt der

§74.33 kjørte kjeden hele veien, men mot en lokal stack, og skrev det eksplisitt: ingen
migrasjoner deployet, ingen legitimasjon utstedt, ingen verifikasjon registrert i det hostede
prosjektet. Denne leveransen lukker alle tre. Alt under er avlest fra produksjonsdatabasen
etterpå, ikke utledet av at en kommando gikk igjennom.

**Det var ti migrasjoner som manglet, ikke tre.** Avlesningen ved oppstart ga tjue rader i
`supabase_migrations.schema_migrations` mot tretti filer i `migrations/`: ikke bare PR #51 sine
fire, men også PR #48 sine fire og PR #50 sine to hadde aldri vært kjørt der. Det er nøyaktig
det avviket §74.25 fant, og som issue 42 fortsatt ikke oppdager av seg selv — tredje gang på
rad. Alle ti er nå kjørt, i tidsstempelrekkefølge, hver som én forespørsel og én transaksjon
som inneholder både migrasjonens SQL og historikkraden. Etterpå: tretti rader mot tretti filer,
samme versjonsnumre og navn.

| Rekkefølge | Migrasjon | Fra |
| --- | --- | --- |
| 1–4 | 005d, 008c, 005e, 005f | PR #48 |
| 5–6 | 008d, 005g | PR #50 |
| 7–10 | 008e, 007f, 005h, publiseringsgatens G5b | PR #51 |

**Framgangsmåten er nå et skript framfor en framgangsmåte som gjengis.** `supabase db push`
kan fortsatt ikke kjøres herfra — `supabase projects list` gir `LegacyProjectsListNetworkError`,
prøvd på nytt 6. september 2026, og §74.23 sin diagnose står. Management-API-veien var dermed
den samme som i §74.26 og §74.28, men det var tredje gang den ble skrevet ut for hånd i denne
planen, og en operasjon som gjentar seg og som skriver til produksjon hører hjemme i noe som
kan reviewes én gang. `./scripts/deploy-migrations.sh` gjør nøyaktig det `db push` gjør, og
`--dry-run` svarer på «er produksjon i synk med repoet?» uten å skrive noe.

**Rettet under teknisk review: skriptet ville kjørt en eldre migrasjon etter en nyere.**
Første utgave behandlet enhver lokal migrasjon uten en historikkrad som «manglende», uten å
kontrollere at det som *var* kjørt utgjorde et sammenhengende prefiks av filene i repoet. Med
registrert historikk `A, C` mot lokal `A, B, C` ga det `B` som manglende — og `B` ville blitt
kjørt etter `C`. En migrasjon er skrevet under den forutsetningen at alt før den har kjørt, så
den kunne da gjort noe annet enn den gjorde lokalt, eller gjeninnført en endring i feil
rekkefølge. I et verktøy som skriver til produksjon er det en alvorligere feil enn den ser ut
som, nettopp fordi den bare inntreffer når historikken allerede har drevet.

Regelen er nå: **når en lokal migrasjon mangler, skal ingen nyere versjon allerede være
registrert.** Er den brutt, skrives ingenting — et hull betyr at prosjektet og repoet har kommet
fra hverandre, og hvorfor er et spørsmål et menneske må svare på, ikke noe et deployskript skal
reparere selv. Supabase gjør det samme skillet med `--include-all`. Sammenligningen ligger i
`src/ops/migration-plan.ts` framfor i skallet, og er mutasjonstestet: uten hullkontrollen
feller to av testene rettelsen. Prøvd ende-til-ende mot den ekte historikken med én migrasjon
fjernet midt i: avvist før noen skriving, med hullet navngitt.

**Én ting skriptet bevisst ikke kontrollerer, fordi kontrollen ikke ville vært sann.** Første
utkast sammenlignet `statements`-kolonnen med filens tekst for å oppdage en merget migrasjon
som var redigert etterpå. Den meldte avvik på seksten filer. Ingen av dem var rørt:
`supabase db push` deler filen i enkeltsetninger og fjerner kommentarene — de tretten eldste
radene har mellom 4 og 158 elementer og er en brøkdel av filens lengde — mens
Management-API-kjøringene i §74.26 la inn hele filen som ett element. Kontrollen er derfor på
versjon og navn. Regelen om at en merget migrasjon aldri redigeres (§74.32) står, men kan ikke
håndheves herfra.

**Hva som er lest tilbake etter deploy, som avlesning og ikke som antakelse:**

| Kontroll | Svar |
| --- | --- |
| `supabase_migrations.schema_migrations` mot `migrations/` | tretti rader, identisk liste, sammenlignet maskinelt |
| De seksten nye funksjonene | alle finnes, med de signaturene filene definerer; alle med `search_path = ''`, og `api.*`-flatene som `SECURITY DEFINER` |
| `provenance.agent_identities`, `provenance.agent_runs` | finnes, med RLS aktivert |
| `provenance.agent_role` | inneholder `extraction_verification` |
| `audit.event_operation` | inneholder `evidence_verification_registered` og `source_version_registered` |
| `evidence_verifications_agent_run_actor_fkey` og `_role_fkey` | begge finnes — de tre lagene mot selvverifikasjon er på plass |
| `knowledge.source_versions.retrieved_by_actor_id` | finnes, og begge de seedede radene er backfilt til `agent:evidence-extraction` |
| Race-fiksen i `provenance.assert_agent_run_open(...)` | funksjonsdefinisjonen i produksjon inneholder `FOR UPDATE` |
| `knowledge.assert_claim_revision_publishable(...)` | kaller `workflow.required_check_fields(...)` — G5b er i produksjon |
| EXECUTE-grants | `anon` og `authenticated` på de fire agentflatene; bare `authenticated` på `api.create_source_version`; ingen klientrolle på `provenance.issue_agent_identity_credential`, `provenance.authenticate_agent_identity`, `knowledge.record_source_version`, `knowledge.source_version_content_hash` eller `workflow.required_check_fields` |
| De ni nye triggerne | alle finnes |

**Legitimasjonen er utstedt, og verdien finnes ikke i denne transkripsjonen.**
`agent-identity:extraction-verification-01` har nå `secret_version = 1`, med
`secret_issued_by_actor_id` på `human:peder-holman` og en `agent_identity_credential_issued`
i auditloggen. Identiteten var inert fram til dette (§74.32), og er det ikke lenger.

Utstedelsen krevde en tilføyelse til `scripts/issue-agent-credential.sh`, og grunnen er den
samme som skriptet selv ble skrevet for. Skriptet nekter å kjøre i CI fordi det skriver
hemmeligheten til stdout, og stdout i en CI-jobb er en logg som lagres. En agentsesjon har
nøyaktig samme egenskap. `--write-env` skriver derfor de to variablene rett i den gitignorerte
miljøfila, uten å vise verdien noe sted, og `--management-api` gir den privilegerte
forbindelsen funksjonen krever uten at databasepassordet må hentes ut. Avveiningen er ført:
`--db-url` gir en direkte TLS-forbindelse til databasen og er å foretrekke når passordet er for
hånden; `--management-api` sender kallet over HTTPS til `api.supabase.com`.

**Kjeden er kjørt i produksjon. Dette er avlesningen.**

| Ledd | Avlesning |
| --- | --- |
| 1. Tørrkjøring | Kjøring `978f0c38`, ett avgrenset funn, lukket som `aborted`, null registrert |
| 2. Fingeravtrykk | Begge de seedede kildeversjonene hentet på nytt fra NCBI og hashet uavhengig av kjøreren: `sha256:797e91b6…` (8 055 byte) og `sha256:c62a66215…` (14 515 byte) reproduserer de registrerte verdiene |
| 3. Ekte kjøring | Kjøring `83c37ab9`, lukket som `succeeded`, tre verifikasjoner registrert |
| 4. Utfall | Alle tre `uncertain`, alle med `source_access = verifiable_representation` og `checked_fields = {raw_extraction, source_locator, intervention_arm}` |
| 5. Proveniens | Hver verifikasjon peker på kjøringen, kjøringen på identiteten, identiteten på `agent:extraction-verification` — og hver av de tre har nøyaktig én `evidence_verification_registered` i auditloggen |

**`uncertain` er riktig svar, og det er verdt å si hvorfor det ikke ble «rettet».** Begrunnelsen
kjøringen skrev, er den §74.33 forutså: utvalgsstørrelsen ble ikke gjenfunnet som tall i
funnets eget utdrag, fordi utdragene er flerarmede («fluoxetine (N = 92), sertraline …»), og de
norske katalogbegrepene ble ikke gjenfunnet ordrett i en engelsk kilde. Sitatet, kildepekeren
og intervensjonsarmen står som kontrollert. Et `verified` her ville vært en gjetning som så ut
som en kontroll.

**Publiseringsgaten er prøvd mot de reelle radene, i en transaksjon som ble rullet tilbake.**
`workflow.required_check_fields(...)` krever mellom ti og elleve felter for disse tre funnene,
mens den deterministiske kontrollen dekker tre. To scenarier ble kjørt mot en påstandsrevisjon
som faktisk er lenket til et av funnene:

| Scenario | Svar fra gaten |
| --- | --- |
| Slik det står nå (`uncertain` registrert) | Blokkert av G5: «Evidensfunn med åpent verifikasjonsfunn» |
| Med en syntetisk `verified` som bare bærer de tre deterministiske feltene | Blokkert av G5b: «Evidensfunn uten fullstendig kontrollert ekstraksjon» |

Det andre svaret er hele poenget med migrasjonen fra §74.33: en partiell deterministisk
`verified` kan ikke alene gjøre et klinisk funn publiserbart. Transaksjonen ble rullet tilbake,
og etterkontrollen viser fortsatt tre verifikasjoner, null `verified`, tre auditrader.

**Én ting gjenstår, og den krever tilgang denne sesjonen ikke har.** De fire
GitHub Actions-secretene er ikke satt, og kan ikke settes herfra: sesjonens GitHub-proxy
svarer `403` på `actions/secrets`, `actions/variables` og `actions/permissions`, mens
`actions/workflows` og `actions/runs` er åpne. Det er avlest og ikke antatt — arbeidsflyten ble
kjørt (`workflow_dispatch`, tørrkjøring, ett avgrenset funn) og feilet nøyaktig der den skal:
på vaktposten som lister opp hva som mangler, med alle fire navn. Selve arbeidsflyten er
dermed prøvd så langt den lar seg prøve herfra — den lar seg utløse, den sjekker ut, den
installerer, og vaktposten virker — og ingen verdi lekket i loggen.

Kjøringene over ble derfor gjort med kjøreren lokalt i sesjonen, mot det hostede prosjektet.
Det er samme kode arbeidsflyten kjører (`npm run agent:verify-extraction`), samme database og
samme identitet; det som ikke er prøvd, er GitHub-runneren som utførende maskin.

**Legitimasjonen som er utstedt, hører til sesjonen den ble utstedt i.** Den ligger i en
gitignorert fil i et miljø som forsvinner. Når secretene skal settes, utstedes en ny
legitimasjon i det miljøet som skal lese den — og den utstedelsen ugyldiggjør denne, som er
tilsiktet og uten konsekvens for radene som allerede er registrert: de peker på identiteten,
ikke på hemmeligheten.

**Rettet under teknisk review: `--write-env` holdt ikke sitt eget løfte.** Gjennomgangen fant
to feil i den nye skriveveien, og begge var reelle. De handler ikke om hva som ble skrevet,
men om hvor hemmeligheten kunne bli liggende.

1. **Filen fikk ikke `0600` når den fantes fra før.** `fs.writeFileSync(fil, tekst,
   { mode: 0o600 })` setter modus **bare** når filen opprettes — og standardtilfellet her er
   nettopp at `.env.agent.local` finnes fra før, med URL og publishable key i seg. En fil som
   sto som `0644`, ville fått agenthemmeligheten skrevet inn i seg mens koden så ut til å
   love noe annet, og ingenting ville feilet. Avlest framfor resonnert: `writeFileSync` med
   `mode: 0o600` på en eksisterende `0644`-fil gir `0644`. (Filen i den kjøringen som faktisk
   ble gjort, var `0600` — den ble opprettet fersk under `umask 077` — så ingen hemmelighet
   lå noen gang for åpent. Men det var flaks i rekkefølgen, ikke noe koden garanterte.)

   Skrivingen går nå gjennom en fersk tempfil som `fchmod`-es til `0600` og deretter flyttes
   på plass med `rename`. Rettighetene som gjelder til slutt er tempfilens, `fchmod` lar seg
   ikke utvide av umask, og det finnes ikke noe øyeblikk der filen er halvskrevet eller for
   vidt åpen.

2. **`--write-env <fil>` tok imot en hvilken som helst bane**, mens både skriptet og
   dokumentasjonen lovet at målet var gitignorert. Ingenting hindret at hemmeligheten ble
   skrevet rett i en sporet fil — `.env.example` er det nærliggende eksempelet — og derfra er
   veien inn i historikken ett `git add`. `git check-ignore` er nå et vilkår, og det feiler
   lukket: svarer ikke git, skrives ingenting.

**Og et tredje funn, på rettelsen av det første: tempfilen var ikke ignorert.** Tempfilen
punkt 1 innførte, bærer den samme hemmeligheten fram til `rename`. Den het
`.${basename}.<tilfeldig>.tmp`, som for `.env.agent.local` gir
`..env.agent.local.<tilfeldig>.tmp` — med to innledende punktum, som verken `.env.*` eller
`*.local` matcher. Blir prosessen drept i vinduet mellom skriving og `rename` — SIGKILL,
krasj, strømbrudd — rydder ingen `catch` opp, og da lå hemmeligheten i en **sporbar** fil i
arbeidstreet. Rettelsen på punkt 1 hadde altså flyttet nøyaktig den risikoen punkt 2 stengte,
over i et vindu ingen så på. Avlest med `git check-ignore`: `.env.agent.local` er ignorert,
`..env.agent.local.123abc.tmp` er ikke, `.env.agent.local.123abc.tmp` er.

Tempfilen heter derfor det samme som målet med et suffiks, uten det ekstra punktumet — og,
viktigere, den *konkrete* tempbanen kontrolleres med samme fail-closed regel som målfilen,
før hemmeligheten skrives. Navnet alene er ikke argumentet; kontrollen er. Er tempbanen ikke
ignorert, skrives ingenting.

Logikken ligger i `src/agents/agent-env-file.ts` framfor i skallet, fordi den fortjener
tester. Alle tre er mutasjonstestet: uten tempfilveien feller testen rettelsen med
«expected '644' to be '600'», uten gitignore-vilkåret på målet feller to andre den, og med
det innledende punktumet tilbake feller tempfil-testen den — den siste mot repoets faktiske
ignore-regler, ikke mot en gjengivelse av dem. Den ekte veien er prøvd like reelt: et forsøk
på å skrive til `.env.example` ble avvist med filen urørt, og etter hver runde autentiserte
kjøreren mot produksjon med en ny legitimasjon skrevet på den rettede veien, uten at noen
tempfil ble liggende igjen.

**Hva denne leveransen bevisst ikke gjør.** Den bygger ikke claim-verifikasjon
(`workflow.claim_verifications`, `citation_support_verification`), utvider ikke til andre
agentroller, og endrer ikke noe klinisk innhold for å få en verifikasjon til å passere. Ingen
CHECK, policy, grant eller gate er fjernet eller myknet opp.

**Hva som gjenstår for Milepæl B.** G4/G5 kan nå lukkes for et funn ved å kjøre kjøreren mot
det — men er ikke lukket for noen av de tre, fordi alle tre står som `uncertain`, og G5b vil
uansett kreve dekning ingen deterministisk kontroll alene kan gi. De to andre står urørt:
claim-verifikasjonene (G8/G9) og den menneskelige godkjenningen (G11/G12/G13).

**Neste steg.** Claim-verifikasjon (`workflow.claim_verifications`,
`citation_support_verification`) som egen, senere PR.

---

### 74.35 Claim-verifikasjonen er bygget og kjørt, og G8/G9 er lukket der de kan lukkes

§74.34 endte med ett neste steg: claim-verifikasjon som egen PR. Denne leveransen bygger den
hele veien — skriveflate, egen agentrolle og identitet, lesegrunnlag, deterministisk kjører,
publiseringsgater og tester — og kjører den mot de reelle radene i det hostede prosjektet.

**Seks migrasjoner.**

| Migrasjon | Hva den gjør |
| --- | --- |
| 008f | `audit.event_operation` får `claim_verification_registered`. Alene i sin egen fil, fordi `ALTER TYPE ... ADD VALUE` ikke kan brukes i samme transaksjon som verdien |
| 005i | Aktøren `agent:citation-support-verification` og identiteten `agent-identity:citation-support-verification-01`, registrert inert |
| 005j | Grunnlaget: agentkjøringsbinding, evidenssettavtrykk, mandatkontroll, `workflow.claim_verification_citations` og dekningskontrollen |
| 005k | `api.claim_verification_input(...)` og `api.register_claim_verification(...)` |
| 006c | Publiseringsgaten leser hvem som kontrollerte, og hva kontrollen gjaldt (G9b og G9c) |
| 005l | Rettelse av en feil den første ekte kjøringen mot produksjon fant; se under |

**Rollen er ny, og det er den som gjør skillet til en grense.** `provenance.agent_role` hadde
`citation_support_verification` fra migrasjon 005 — den er en av de sju
`ANTIDEP_CONSTITUTION.md` §10 krever — men ingen aktør hadde den. EVIDENCE_PIPELINE.md §61
skiller `ExtractionVerifier` og `CitationVerifier` på input, output og mandat, og
ekstraksjonsverifikatoren kan derfor ikke kontrollere en påstand: `authenticate_agent_identity`
avviser den, og skriveveien leser aldri en rad før den avvisningen har skjedd. De to
påstandsrevisjonene i produksjon er formulert av `agent:claim-synthesis`, som er en tredje
aktør — så generering og verifikasjon er atskilte operasjoner i praksis og ikke bare i prosa.

**Fire hull som var åpne i `workflow.claim_verifications`, og som nå er lukket på raden
selv.** Tabellen fantes fra migrasjon 005 med sine sju kontrollpunkter, og publiseringsgatens
G8/G9 leste den — men det fantes ingen skrivevei inn, ingen binding til en agentkjøring, ingen
registrering av *hva* kontrollen så på, og ingen kontroll av at den som skrev raden hadde
mandat til det. Enhver aktør som ikke tilfeldigvis var forfatteren, kunne skrive raden gaten
leser.

1. **Mandat.** `workflow.claim_verifier_has_mandate(...)` avgjør spørsmålet ett sted og
   håndheves to: ved innsetting, og i gaten på den gjeldende kontrollen. En agent må ha rollen
   `citation_support_verification`; et menneske må ha hatt gyldig `reviewer`-rolle for
   innholdsområdet på `verified_at`, med en tildelingsrad som fantes senest da — samme regel
   `workflow.enforce_reviewer_qualification()` bruker, og av samme grunn: en tilbakedatert
   `valid_from` skal ikke kunne konstruere gyldighet i etterkant.
2. **Dekning.** `workflow.claim_verification_citations` har én rad per evidenslenke kontrollen
   gikk gjennom. Fire sammensatte fremmednøkler låser at lenken hører til den kontrollerte
   revisjonen, at evidensfunnet er lenkens eget, at kildeversjonen er funnets egen, og at
   fingeravtrykket er **det kildeversjonen faktisk er registrert med**. Den siste er den som
   gjør `ANTIDEP_CONSTITUTION.md` §11 maskinelt kontrollerbar for dette leddet: en verifikator
   kan ikke finne på et fingeravtrykk for å få skrevet `verifiable_representation`.
3. **Samlet kildetilgang er den svakeste, ikke den sterkeste.** Radens `source_access` er ikke
   en parameter — den utledes av kontrollradene. Var den kallerstyrt, kunne en kontroll der én
   lenke bare hadde et sammendrag, blitt registrert som `original_source`, og §11 sitt forbud
   mot å godkjenne på andre agenters sammendrag ville vært omgåelig ved å aggregere.
4. **Grunnlaget kontrollen gjaldt.** `verified_evidence_set_digest` er databasens avtrykk av
   evidenssettet ved registrering, etter samme mønster som godkjenningens avtrykk i migrasjon
   006. Uten det var sekvensen «kontroller → legg til en lenke → publiser» lovlig, og den nye
   lenken kan være nettopp den motstridende evidensen kontrollen skulle lete etter.

**Publiseringsgaten fikk to nye vilkår, ingen ble myket opp.** G9b krever at den gjeldende
kontrollens avtrykk er avtrykket av settet slik det er nå; G9c krever at aktøren bak den hadde
mandatet. Begge leser den samme raden som G9, hentet én gang, slik at de tre aldri kan bli
uenige om hvilken kontroll som er den gjeldende. Tidssemantikken er uendret og prøvd: den siste
kontrollen er den gjeldende, så en senere `uncertain` eller `needs_correction` kan ikke skjules
av en eldre bekreftelse.

**Kjøreren er deterministisk, og kan ikke bekrefte — med hensikt.** Den henter hver
evidenslenkes kildeversjon på nytt, reproduserer fingeravtrykket, kontrollerer at utdragene
ekstraksjonen bygger på fortsatt står ordrett i representasjonen, og sammenligner påstandens
strukturerte betydning felt for felt med grunnlaget.

**Hvert avvik den melder, er et faktisk avvik — og det er derfor bare lenker som lover samsvar,
som kan felles.** `partially_supports` betyr at funnet underbygger deler av påstanden, og
`directness = indirect` at det treffer populasjon, endepunkt, komparator og tidsrom bare
indirekte; ingen av dem registrerer *hvilken* akse som ikke er dekket. En forskjell på en slik
lenke kan derfor være nettopp det lenken erkjenner. Bare `supports` + `direct` lover samsvar på
hver akse, og bare der meldes en forskjell som `deviation` — en støttende lenke som peker
motsatt vei, en komparator som er en annen, et tidspunkt helt utenfor påstandens tidsrom. På de
andre lenkene blir den samme forskjellen `not_assessable`, med funnet skrevet ut. En tallfestet
størrelse ingen enkeltlenke oppgir, er alltid `not_assessable`: for en evidenssyntese kan
størrelsen legitimt være syntesens egen, og §74.33 slo allerede fast at et tall som ikke lar
seg gjenfinne, gir `uncertain` og ikke en anklage. Sperren er den samme uansett —
`not_assessable` blokkerer publiseringsgaten nøyaktig som `deviation`; det som faller bort, er
anklagen mot innholdet.

Men tre av de sju punktene kan aldri bli `ok` herfra. To krever språkforståelse — om ordlyden
er dekket, og om vesentlige forbehold mangler. Det tredje kan ikke besvares fra basen i det
hele tatt: **fravær av registrert motstridende evidens er ikke fravær av motstridende evidens**
(`ANTIDEP_CONSTITUTION.md` §17). Siden `verified` krever at alle sju holder, er `uncertain` det
beste utfallet denne kontrollen kan gi, og G9 blokkerer da. Det er riktig svar og ikke en
mangel; et senere ledd med språkmodell eller en menneskelig reviewer er det som kan konkludere,
og det er et adapterbytte og ikke en datamodellendring (§20).

Kjøreren registrerer heller ingenting for en revisjon der én av lenkenes kildeversjoner ikke
lot seg etterprøve. Kontrollen må dekke hele settet, så den kan ikke registreres delvis — og en
usann `source_access` for å få skrevet at kontrollen mislyktes, ville byttet en manglende
opplysning mot en usann. Avviket står i kjøringens `output_manifest`.

---

**Kjeden er kjørt i produksjon. Dette er avlesningen.**

| Ledd | Avlesning |
| --- | --- |
| 1. Deploy | Fem migrasjoner kjørt med `./scripts/deploy-migrations.sh`; etterpå trettiseks rader mot trettiseks filer, sammenlignet maskinelt |
| 2. Legitimasjon | Utstedt til `agent-identity:citation-support-verification-01` med `--write-env --env-prefix ANTIDEP_CLAIM_AGENT`. Verdien finnes ikke i denne transkripsjonen |
| 3. Tørrkjøring | Kjøring `210d9a65`, to revisjoner, lukket som `aborted`, null registrert |
| 4. Ekte kjøring | Kjøring `8b3941c1`, lukket som `succeeded`, to kontroller registrert |
| 5. Utfall | Begge `uncertain`, begge med `source_access = verifiable_representation`, begge med avtrykket lik settets nåværende |
| 6. Kontrollrader | Én per evidenslenke, hver mot sin egen kildeversjon og sitt registrerte fingeravtrykk: `sha256:797e91b6…` og `sha256:c62a66215…` — de samme verdiene §74.34 leste av |
| 7. Proveniens | Hver kontroll peker på kjøringen, kjøringen på identiteten, identiteten på `agent:citation-support-verification`, og hver har nøyaktig én `claim_verification_registered` i auditloggen |

**`uncertain` er riktig svar, og det er verdt å si hvorfor det ikke ble «rettet».** Kontrollen
fant ingen avvik: populasjon, komparator, tidsrom og retning stemmer for sertralinpåstanden, og
komparator, tidsrom og retning for mirtazapinpåstanden. Det som står uavklart, er nettopp det
en deterministisk kontroll ikke kan avgjøre — og for mirtazapin i tillegg populasjonen, fordi
evidensfunnets egen `population_availability` er `uncertain_extraction`. Kontrollen fant
dessuten ett registrert evidensfunn på samme virkestoff og endepunkt som ikke er lenket til
sertralinpåstanden, og førte det opp som kandidat for urepresentert evidens. Ingen klinisk
verdi er endret for å få kontrollen til å passere.

**Publiseringsgaten er prøvd mot de reelle radene, i en transaksjon som ble rullet tilbake.**

| Scenario | Svar fra gaten |
| --- | --- |
| Slik det står nå | Blokkert av G5: ekstraksjonen er `uncertain` |
| Med en syntetisk fullstendig ekstraksjonsbekreftelse | Blokkert av G9: claim-kontrollen konkluderer ikke med `verified` |
| Med en syntetisk `verified` claim-kontroll fra `agent:evidence-extraction` | Blokkert av G9c: registrert av en aktør uten mandat |
| Med en syntetisk `verified` claim-kontroll fra claim-verifikatoren | Blokkert av G11: ikke godkjent av en kvalifisert redaktør |

Den siste raden er den positive assertionen for alle fire claim-gatene: G8, G9, G9b og G9c er
passert, og det som gjenstår, er den menneskelige godkjenningen. Transaksjonen ble rullet
tilbake, og etterkontrollen viser fortsatt to claim-verifikasjoner, null `verified`, to
kontrollrader, to auditrader og null publiseringer.

G9b lot seg ikke prøve mot de reelle radene, og grunnen er en invariant og ikke en mangel:
begge revisjonene har en registrert evidensvurdering, og migrasjon 004 forsegler evidenssettet
i det den skrives. En ny lenke kan ikke legges til, så avtrykket kan ikke bli utdatert for dem.
Vilkåret er prøvd i `250_publication_gate_test.sql` og
`490_claim_verification_publication_gate_test.sql` i begge retninger.

---

**Rettet under kjøringen mot produksjon: den utsatte kontrollen kjørte som feil rolle.**
Dekningskontrollen er en `constraint trigger ... deferrable initially deferred`, og
utsettelsen er nødvendig: kontrollradene finnes ikke ennå når moderraden settes inn. Men en
utsatt trigger kjører **ved commit**, og da er SECURITY DEFINER-konteksten i skriveveien
forlatt — den effektive brukeren er igjen `anon`, som ikke har og ikke skal ha `usage` på
`workflow`. Den første ekte kjøringen mot det hostede prosjektet svarte
«permission denied for schema workflow» etter at alt annet var utført.

Feilen kunne ikke slått ut i databasetestene: de avsluttes med `rollback`, og en utsatt trigger
kjører aldri i en transaksjon som rulles tilbake. Rettelsen (005l) gjør begge funksjonene
SECURITY DEFINER — samme begrunnelse som `workflow.enforce_reviewer_qualification()` har: de
leser bare, validerer bare, og returnerer ingen data. Ingen ny rettighet følger av det, og
EXECUTE er fortsatt revokert fra PUBLIC på begge.

Testen som nå dekker den, tvinger kontrollen fram med `set constraints all immediate` **mens
rollen er `anon`**, som er nøyaktig den situasjonen commit gir. Den er mutasjonstestet: uten
SECURITY DEFINER feller den med den samme meldingen produksjon ga.

Rettelsen er skrevet fremover og ikke inn i 005j, fordi 005j allerede var kjørt i det hostede
prosjektet, og Supabase kjører aldri en registrert migrasjonsversjon på nytt (§74.32).

---

**Hva denne leveransen bevisst ikke gjør.** Den bygger ikke human review, ikke reviewbeslutning
og ikke publisering — de er de neste leddene i §15 og hører til hver sin PR. Den endrer ikke
klinisk innhold for å få en kontroll til å passere, og den svekker ingen eksisterende kontroll:
ingen CHECK, ingen policy, ingen grant og ingen gate er fjernet eller myknet opp.

**Én ting gjenstår, og den krever tilgang denne sesjonen ikke har.** GitHub Actions-secreten
`ANTIDEP_CLAIM_AGENT_SECRET` for `.github/workflows/claim-verification.yml` er ikke satt, av
samme grunn som §74.34 fant for ekstraksjonsarbeidsflyten: sesjonens GitHub-proxy svarer `403`
på `actions/secrets`. Det er den eneste nye verdien arbeidsflyten trenger, utover
Supabase-verdiene arbeidsflytene allerede deler. Identitetsnøkkelen er ikke en hemmelighet —
den står i klartekst i migrasjon 005i og i `.env.example` — og ligger derfor som en konstant i
arbeidsflytfila, med `vars` som overstyring for et miljø som kjører en annen identitet.
Arbeidsflyten er inert til noen legger hemmeligheten inn, og stopper da på vaktposten som
lister opp hva som mangler. Kjøringene over ble gjort med kjøreren lokalt i sesjonen, mot det
hostede prosjektet — samme kode arbeidsflyten kjører, samme database og samme identitet.

**Hva som gjenstår for Milepæl B.** G8 og G9 kan nå lukkes for en revisjon ved å kjøre
kjøreren mot den — men er ikke lukket for noen av de to, fordi begge står som `uncertain`, og
den deterministiske kontrollen kan per konstruksjon ikke gi `verified`. Den siste av de tre
tingene §74.4 lister, den menneskelige godkjenningen (G11/G12/G13), står urørt.

**Neste steg.** Reviewbeslutningen — `workflow.review_decisions` og den redaksjonelle flaten
for å registrere en `publication_approval` — som egen, senere PR.

---

### 74.36 Den menneskelige reviewen er bygget, og hele kjeden er prøvd mot de reelle radene

§74.35 endte med ett neste steg: reviewbeslutningen som egen PR. Denne leveransen bygger den
hele veien — begge skriveveiene, den redaksjonelle flaten, og testene — og prøver hele kjeden
mot de reelle radene i det hostede prosjektet.

**Åtte migrasjoner.**

| Migrasjon | Hva den gjør |
| --- | --- |
| 008g | `audit.event_operation` får `review_decision_registered`. Alene i sin egen fil, fordi `ALTER TYPE ... ADD VALUE` ikke kan brukes i samme transaksjon som verdien |
| 005m | `workflow.claim_evidence_dossier(uuid)` — grunnlaget for en påstandskontroll, ett sted. `api.claim_verification_input(...)` bygger svaret sitt av den |
| 005n | `workflow.assert_reviewer_authorized(uuid)`, `workflow.assert_evidence_set_unchanged(uuid, text)`, `workflow.record_claim_verification(...)` som begge skriveveier deler, og `api.register_human_claim_verification(...)` |
| 006d | Auditskriver og trigger på `workflow.review_decisions`, og `api.register_publication_approval(...)` |
| 005o | `api.claim_review_workspace(uuid)` — arbeidsflaten, med publiseringsgaten lest av gaten selv |
| 005p | Rettelse av et funn i teknisk review; se under |
| 006e | Rettelse av et andre funn i teknisk review; se under |
| 006f | Rettelse av et tredje funn i teknisk review; se under |

**To dører som har vært låst innenfra siden migrasjon 005, er åpnet — uten at noen regel er
myket opp.** Den menneskelige grenen av `workflow.claim_verifier_has_mandate(...)` har vært
håndhevet, prøvd og dokumentert siden 005j, men uadresserbar: den eneste veien inn i
`workflow.claim_verifications` krevde agentlegitimasjon og en åpen agentkjøring. Uten den kan
ingen påstand noensinne komme forbi G9, fordi den deterministiske kontrollen per konstruksjon
ikke kan gi `verified` (§74.35). Det samme gjaldt `workflow.review_decisions`, som G11, G12 og
G13 har lest siden migrasjon 006 uten at noen kunne skrive raden.

Ingen CHECK, constraint, trigger, policy eller grant er fjernet eller svekket, og ingen ny
direkte tabelltilgang er gitt til `anon` eller `authenticated`. Mandatet er det samme
uttrykket, dekningskontrollen den samme funksjonen, `verified`-kravet den samme CHECK-en,
append-only den samme triggeren, og selvverifikasjon og selvgodkjenning de samme
constraintene.

**Ett nytt vilkår, og bare på de menneskelige veiene.** Begge skriveveiene krever at kalleren
oppgir avtrykket av det evidenssettet flaten faktisk viste. En menneskelig vurdering tar tid;
kommer det en evidenslenke til i vinduet, gjelder vurderingen et annet grunnlag enn det som
ble vurdert — og den nye lenken kan være nettopp den motstridende evidensen kontrollen skulle
lete etter. Publiseringsgatens G9b og G13 er fortsatt fasiten ved publisering; dette kommer i
tillegg og sier fra med en gang. Agentveien har ikke vilkåret, fordi lesegrunnlag og
registrering skjer i samme kjøring.

**Grunnlaget finnes bare i én formulering, og det er den viktigste avgjørelsen i leveransen.**
Reviewflaten skal vise nøyaktig det claim-verifikatoren arbeider mot. Projeksjonen er derfor
flyttet ut i `workflow.claim_evidence_dossier(uuid)`, og `api.claim_verification_input(...)`
bygger svaret sitt av den. To formuleringer ville før eller siden latt mennesket og maskinen
kontrollere påstanden mot hvert sitt bilde av evidensen — nøyaktig den feilen
`ANTIDEP_CONSTITUTION.md` §4 og §9 finnes for å hindre. Det samme grepet er gjort for
registreringen: `workflow.record_claim_verification(...)` er den ene kroppen begge skriveveiene
går gjennom, slik at den ene ikke kan slippe gjennom det den andre stenger.

**Blokkeringer leses av gaten selv.** `api.claim_review_workspace(uuid)` kaller
`knowledge.assert_claim_revision_publishable(uuid)` på ekte og returnerer avvisningen ordrett,
framfor å regne ut «er den klar?» på nytt. Gaten stopper på det første vilkåret som svikter, så
flaten navngir én blokkering om gangen. Det er prisen for at flaten aldri kan si «klar» om noe
gaten stenger.

**Flaten har to handlinger, ikke én.** Kontrollen mot grunnlaget (§11) og beslutningen om å
publisere (§12) er to forskjellige faglige utsagn, lagret som to beslutningsobjekter, og gaten
krever dem hver for seg. En samlet «godkjenn alt»-knapp ville latt ett museklikk stå for to
vurderinger som skal kunne skilles i ettertid.

---

**Kjeden er prøvd i produksjon. Dette er avlesningen.**

| Ledd | Avlesning |
| --- | --- |
| 1. Deploy | Fem migrasjoner kjørt med `./scripts/deploy-migrations.sh`; etterpå førtién rader mot førtién filer |
| 2. Agentens lesegrunnlag | `md5` av `revisions` fra `api.claim_verification_input(...)` for begge produksjonsrevisjonene er **uendret** før og etter deploy: `68e07d76…` og `ea05a3a2…`. Legitimasjonen ble utstedt i en transaksjon som ble rullet tilbake, så ingen versjon er rotert |
| 3. Lesing som redaktør | `api.claim_review_workspace()` gir to revisjoner i køen; oppslaget på én gir ett evidensfunn, én registrert kontroll, GRADE-sikkerhet `very_low` og én kandidat for urepresentert evidens |
| 4. Hele kjeden | Kjørt mot revisjon `724bc69b…` i én transaksjon som ble rullet tilbake; se tabellen under |
| 5. Etterkontroll | To claim-verifikasjoner, null `verified`, null reviewbeslutninger, null publiseringer, uendret legitimasjonsversjon, ingen nye agentkjøringer |

| Steg | Svar fra gaten |
| --- | --- |
| Slik det står nå | Blokkert av G5: `Evidensfunn med åpent verifikasjonsfunn: 5b98b916…` |
| Med en syntetisk fullstendig ekstraksjonsbekreftelse | Blokkert av G9: claim-kontrollen konkluderer ikke med `verified` |
| Menneskelig claim-verifikasjon registrert gjennom skriveveien | Rad `0b58e0ed…`. Den utsatte dekningskontrollen ble tvunget fram **mens rollen var `authenticated`** — samme situasjon commit gir — og passerte |
| Etter kontrollen | Blokkert av G11: ikke godkjent av en kvalifisert redaktør |
| Publiseringsgodkjenning registrert gjennom skriveveien | Rad `ac24856a…` |
| Etter godkjenningen | **Hele publiseringsgaten passerer** |
| Publisering | `42501: Brukeren har ikke gyldig publisher-rolle for dette innholdsområdet.` |

Det siste leddet er den positive assertionen for G8, G9, G9b, G9c, G10, G11, G12 og G13
samtidig: alle passerte, og det som stoppet publiseringen var en rettighet, ikke en gate.

**Kontrollen i steg 3 er syntetisk, og det er ikke en formalitet.** Den ble registrert med alle
sju punktene satt til `ok` for å prøve at skriveveien og gaten virker mot de reelle radene, og
transaksjonen ble rullet tilbake. Den er ikke en faglig vurdering av innholdet, og ingen
`verified` claim-verifikasjon er registrert i produksjon. Den vurderingen hører til revieweren
— å registrere den fra en agentsesjon ville vært å gjøre nøyaktig det
`ANTIDEP_CONSTITUTION.md` §12 forbyr. Ingen klinisk verdi er endret for å få gaten grønn.

**Hva som fortsatt stopper publisering, og hvorfor sperren står.** To reelle ting, og ingen av
dem er teknisk:

1. **Ekstraksjonskontrollene konkluderer med `uncertain`** for begge revisjonene, så G5
   blokkerer. Det er en faglig mangel: den deterministiske kontrollen fant ikke utdragene den
   trengte for å bekrefte alle feltene funnet påstår noe om (§74.34). En menneskelig
   ekstraksjonskontroll ville løst den, og den skriveveien finnes ikke ennå — den er
   speilbildet av 005n for `workflow.evidence_verifications`, og hører til sin egen PR.
2. **Ingen `publisher`-tildeling finnes.** Kontoen har `editor` og `reviewer`. Å godkjenne og
   å publisere er forskjellige rettigheter (§16), og den tredje er ikke tildelt. Det er en
   avgjørelse for prosjekteieren, ikke for en migrasjon.

**Hva som gjenstår for Milepæl B.** G8, G9, G11, G12 og G13 kan nå lukkes for en revisjon ved
at en kvalifisert reviewer gjør vurderingen i flaten. G4 og G5 kan det ikke: de krever en
ekstraksjonskontroll som konkluderer, og den finnes verken som resultat eller som menneskelig
skrivevei. Publisering krever i tillegg en `publisher`-tildeling. Avstanden mellom golden slice
og Milepæl B er dermed tre ting, og bare den første er kode.

**Testene.** Fire nye pgTAP-filer: `500` (den menneskelige skriveveien inn i
`workflow.claim_verifications`, med hver autorisasjonsgren, selvverifikasjon, endret
evidenssett, append-only og direkte omgåelse), `510` (publiseringsgodkjenningen, med de samme
grenene og vokabularet), `520` (arbeidsflaten, køens avgrensning, og assertionen om at
agentens lesegrunnlag er *nøyaktig* det samme uttrykket flaten viser) og `530` (hele
beslutningskjeden fra deterministisk `uncertain` til publisert påstand, med hvert ledd
registrert gjennom sin egen faktiske skrivevei).

`500` og `510` har hver sin mutasjonstest av den sikkerhetskritiske kontrollen: de bytter ut
`workflow.assert_reviewer_authorized(uuid)` med en variant som slipper alle gjennom, og krever
at kallet fortsatt avvises — av radens egen mandatkontroll og av
`workflow.enforce_reviewer_qualification()`. Uten dem ville testene bare prøvd at skriveveien
sier nei, ikke at regelen er sann.

---

**Rettet i teknisk review: en teknisk feil kunne sett ut som en faglig mangel.** 005o fanget
`when others` rundt publiseringsgaten og gjorde **enhver** feil om til
`publication_gate.status = 'blocked'`. For gatens egen avvisning var det riktig; for alt annet
var det stikk motsatt av hensikten. En regresjon i gatefunksjonen, et manglende objekt eller en
rettighetsfeil ville blitt presentert for revieweren som «publiseringen er blokkert, gaten
stopper på det første kravet som ikke er oppfylt» — på nøyaktig den flaten som skal være fasit
for om innholdet er klart. Ingen ville lett etter en teknisk feil der.

005p smalner fangsten til `restrict_violation`, koden gaten avviser med på hvert eneste av sine
vilkår. Alt annet propagerer, hele kallet feiler, og flaten sier det den skal: at dette er en
teknisk feil og ikke et svar om innholdet. Prøven er en mutasjon i
`520_claim_review_workspace_test.sql`: gatefunksjonen byttes ut med varianter som kaster hver
sin kode, og flaten må skille dem. Feilen er reprodusert først — med `when others` gir begge de
tekniske mutasjonene «no exception» der testen krever en — og deretter borte.

---

**Rettet i teknisk review: en godkjenning kunne gis til et ukontrollert utkast.** 006d lot
`decision = 'approved'` registreres når som helst i livsløpet — også før ekstraksjonen og
påstanden var kontrollert. Det er ikke bare rekkefølge på skjermen. Godkjenningen er
append-only og bundet bare til `approved_evidence_set_digest`, altså til *hvilke* evidenslenker
som fantes — ikke til hvilke kontroller som var gjeldende. Sekvensen «godkjenn mens G5 eller G9
blokkerer → registrer kontrollene senere → publiser» var derfor lovlig: den gamle godkjenningen
ville fortsatt vært den gjeldende beslutningen, G13 ville passert fordi avtrykket var uendret,
og revisjonen kunne publiseres uten at noe menneske hadde gått god for den etter at innholdet
faktisk ble kildekontrollert. Godkjenningen ville gjeldt noe annet enn det som ble publisert.
Det bryter livsløpet `ANTIDEP_CONSTITUTION.md` §13 og `KNOWLEDGE_MODEL.md` §20 beskriver, og
rekkefølgen i §15.

006e retter det i databasen, ikke i flaten. Publiseringsgatens G1 til G10 — «alt som skal holde
før et menneske tar stilling» — er flyttet ordrett ut i
`knowledge.assert_claim_revision_ready_for_approval(uuid)`. Gaten kaller den framfor å eie
vilkårene, og `api.register_publication_approval(...)` krever den før den registrerer en
`approved`-beslutning. Ingen logikk er kopiert, så de to kan ikke komme i utakt — samme
begrunnelse som mandatet har for å ligge i én boolsk funksjon og dossieret i ett uttrykk.
`rejected` og `changes_requested` er ikke bundet av vilkåret: det er nettopp når noe blokkerer
at de trengs.

Flaten sier det på forhånd. `api.claim_review_workspace(uuid)` svarer nå med
`approval_readiness` ved siden av `publication_gate`, lest av den samme funksjonen skriveveien
bruker. De to er ikke det samme: gaten stopper på det første vilkåret som svikter, og rett før
en godkjenning er det alltid G11 — «ikke godkjent av en kvalifisert redaktør». En flate som
leste gaten alene, kunne ikke skilt «mangler bare godkjenningen» fra «grunnlaget er ikke
kontrollert ennå». Er forutsetningene ikke oppfylt, tilbys ikke godkjenning i det hele tatt, og
flaten sier hvorfor.

Regresjonsprøven står i `510_publication_approval_test.sql` Del 9: en revisjon bygges opp fra
ingenting, og godkjenningen avvises først på manglende kildekontroll, så på manglende
claim-kontroll, og lykkes først når begge er på plass — mens anmodningen om endringer kan
registreres hele veien. `530` prøver det samme i den fulle kjeden, og `520` at flaten skiller
`approval_readiness` fra `publication_gate` og at en teknisk feil i forutsetningene feller hele
kallet framfor å bli lest som et ukontrollert grunnlag. Filens egen «lykkede sti» er samtidig
rettet: den registrerte en `approved`-rad uten at noen claim-verifikasjon fantes, altså
nøyaktig det som nå er umulig.

**Prøvd mot de reelle radene etter 006e**, i én transaksjon som ble rullet tilbake, på revisjon
`724bc69b…`:

| Steg | Svar |
| --- | --- |
| Godkjenning slik det står nå | `avvist: 23001 Evidensfunn med åpent verifikasjonsfunn: 5b98b916…` |
| Anmodning om endringer slik det står nå | registrert — den er ikke bundet av forutsetningene |
| Godkjenning etter en syntetisk fullstendig ekstraksjonsbekreftelse | `avvist: 23001 … konkluderer ikke med verified` |
| Godkjenning etter den menneskelige claim-verifikasjonen | registrert |
| Publiseringsgaten | passerer |

Etterkontrollen er uendret: to claim-verifikasjoner, null `verified`, null reviewbeslutninger,
null publiseringer. Arbeidsflaten lest som den navngitte redaktøren gir
`approval_readiness = blocked / 23001` med den samme setningen gaten gir, altså den reelle
faglige mangelen og ikke en teknisk feil.

---

**Rettet i teknisk review: kontrollen av «det du faktisk så» tok ingen lås.** 005n innførte
`workflow.assert_evidence_set_unchanged(uuid, text)`, men den sammenlignet uten å låse noe. Avtrykket
som faktisk *lagres*, beregnes senere av triggeren på raden, og den låsen beskytter bare
beregningen — ikke gapet mellom kontrollen og den. En evidenslenke som commitet i det vinduet, ble
en del av det lagrede avtrykket, og både G9b og G13 ville passert på et evidenssett revieweren
aldri så. Det er nøyaktig luken `p_seen_evidence_set_digest` finnes for å lukke.

006f tar `FOR UPDATE` på revisjonsraden *før* sammenligningen og holder låsen ut transaksjonen.
Da er de to mulige rekkefølgene begge riktige: kommer kontrollen først, må lenken vente til
beslutningen er ferdig, og avtrykket som lagres er det revieweren så; kommer lenken først, avvises
registreringen som utdatert. Serialiseringen er ikke ny mekanisme: hver innsetting i
`knowledge.claim_evidence_links` tar allerede den samme låsen, i
`knowledge.reject_evidence_link_after_assessment()` (migrasjon 004) og
`knowledge.reject_evidence_link_after_publication()` (migrasjon 006). Funksjonen kan ikke lenger
være `STABLE` — PostgreSQL tillater ikke `SELECT ... FOR UPDATE` i en ikke-`VOLATILE` funksjon — og
det er en fordel: en tilbakeføring feiler ved kjøring framfor å fjerne låsen i stillhet.

**Prøven krever to forbindelser, og fikk sin egen fil.** pgTAP-filene kjører i én transaksjon som
rulles tilbake; en andre forbindelse ville verken sett fiksturen eller kunnet kappes mot den, og
`dblink` og `postgres_fdw` nekter en ikke-superbruker å koble seg til en server som autentiserer med
`trust` — som den lokale stacken gjør. `scripts/db-lock-test.sh` kjører derfor to reelle psql-økter
mot hverandre: økt A kaller kontrollen og holder transaksjonen åpen, økt B forsøker å legge til en
evidenslenke på den samme revisjonen med `lock_timeout` satt. Med låsen svarer økt B `55P03` («måtte
vente»); uten den slipper den forbi låsen og får `23001` fra forseglingskontrollen som ligger etter
den i den samme triggeren. Begge utfall skriver ingenting, og prøven oppretter ingenting: den bruker
en av revisjonene migrasjon 20260819124500 seeder. Feilen er reprodusert med den gamle kroppen før
rettelsen ble prøvd. Filen kjøres av CI som et eget steg etter `db:test`.

I `500_human_claim_verification_test.sql` ligger i tillegg den delen som *kan* prøves i én
transaksjon: at raden er ulåst før kontrollen og låst etter den, at begge triggerne på
`knowledge.claim_evidence_links` låser den samme raden, og — som mutasjon — at kroppen fra før 006f
lar raden stå ulåst.

**Neste steg.** Den menneskelige ekstraksjonskontrollen — speilbildet av 005n for
`workflow.evidence_verifications` — som egen, senere PR. Den er det siste leddet som mangler
før en påstand kan komme helt gjennom på faglig grunnlag alene.

---

### 74.37 Ekstraksjonskontrollen har fått et menneske, og publiseringen er operativ

§74.36 endte med tre ting mellom golden slice og Milepæl B, og bare den første var kode:
ekstraksjonskontrollene konkluderte med `uncertain` uten at det fantes en menneskelig
skrivevei å rette det med, og `publisher`-rollen var ikke tildelt. Denne leveransen bygger
det første, gjør det andre mulig, og legger til den redaksjonelle handlingen som faktisk
publiserer.

**Seks migrasjoner.**

| Migrasjon | Hva den gjør |
| --- | --- |
| 005q | `workflow.evidence_verifier_has_mandate(uuid, uuid, timestamptz)` og triggeren som håndhever den på raden. `workflow.covered_check_fields(uuid)` flytter G5b sin dekningsberegning ut av gaten. Gaten får G5c |
| 005r | `workflow.evidence_extraction_dossier(uuid)` — grunnlaget for en ekstraksjonskontroll, ett sted. `api.extraction_verification_input(...)` bygger svaret sitt av den |
| 005s | `workflow.evidence_extraction_digest(uuid)`, `workflow.assert_extraction_unchanged(uuid, text)`, `workflow.record_evidence_verification(...)` som begge skriveveier deler, og `api.register_human_extraction_verification(...)` |
| 005t | `api.extraction_review_workspace(uuid)` — køen og kontrollflaten |
| 006g | `workflow.ensure_publisher_role_grant()` |
| 006h | `api.publish_claim_revision(uuid, text)` |

**En dør til er åpnet innenfra, og et lag er lagt til.** `workflow.evidence_verifications`
hadde ingen mandatkontroll på raden. Så lenge den eneste veien inn autentiserte en
agentidentitet eksplisitt for rollen `extraction_verification`, var forskjellen uten
praktisk konsekvens. Med to skriveveier — den andre et menneske med sesjon og reviewer-rolle
— er skriveveiens egen kontroll ikke lenger det eneste som avgjør hvor raden kan komme fra.
Regelen ligger derfor nå i én boolsk funksjon som håndheves to steder: ved innsetting av
raden, og i publiseringsgatens G5c på den gjeldende kontrollen. Nøyaktig samme form som
migrasjon 005j og G9c gir claim-kontrollen.

Ingen CHECK, constraint, trigger, policy eller grant er fjernet eller svekket, og ingen ny
direkte tabelltilgang er gitt til `anon` eller `authenticated`.

**Prisen står i testene, og den er betalt framfor omgått.** Mandattriggeren er
`BEFORE INSERT` og fyrer før CHECK-ene. Fire tidligere testfiler (190, 200, 430 og 440)
prøvde radinvarianter med aktører som ikke har mandatet, og den nye grensen ville skjult den
gamle. Fiksturene skiller nå de to: hver fil har en aktør som *har* mandatet, slik at
selvverifikasjonsregelen og de sammensatte fremmednøklene fortsatt er det som faktisk feller
forsøket. 440 fikk i tillegg en mutasjonstest — med mandatkontrollen byttet ut mot en variant
som slipper alle gjennom, må de to fremmednøklene fra 005g fortsatt fange forsøket.

**Avtrykket dekker mer enn evidenssettet gjorde, og det er en avlesning.** For en
claim-kontroll er «det du faktisk så» evidenssettet (005n). For en ekstraksjonskontroll er det
fire ting, og alle fire kan endre seg mens revieweren leser kilden:

1. kildens status — en kilde som blir trukket tilbake, er nettopp det G7 stopper på
2. kildeversjonen funnet peker på, med adresse og fingeravtrykk
3. selve ekstraksjonen, gjennom radens eget innholdsavtrykk
4. settet av kontroller som allerede er registrert

Det siste er det viktigste. En ny kontroll i vinduet endrer hva som er «den gjeldende», og et
åpent funn kunne ellers blitt borte uten at noen så på det omstridte feltet igjen — nøyaktig
den luken G5b sin nullstilling finnes for å stenge.

**Låsen tas før sammenligningen.** Lærdommen fra teknisk review av PR #59 (migrasjon 006f) er
anvendt før feilen oppstod: `workflow.assert_extraction_unchanged(uuid, text)` tar
`for update` på evidensfunnet og `for share` på kilden *før* den sammenligner, og
`workflow.record_evidence_verification(...)` tar den samme radlåsen. Begge skriveveier går
gjennom den, så to registreringer serialiseres mot hverandre uansett hvilken vei de kommer
fra. Låserekkefølgen er evidensfunn → kilde, og ingen kodevei tar dem i motsatt rekkefølge.

`scripts/db-lock-test.sh` kjører nå tre samtidighetsprøver med to reelle forbindelser, ikke
én. De to nye er reprodusert med en mutert kontroll uten lås: da slipper økt B forbi og
registrerer kontrollen sin, framfor å svare 55P03.

**Publiseringen er to ting, og de er fortsatt to.** `publisher` er retten til å *utføre*
publiseringen; `reviewer` er retten til å avgjøre om innholdet er godt nok. Tildelingen åpner
ingen gate — alle vilkårene kjøres på nytt inne i publiseringstransaksjonen, etter at
rettigheten er kontrollert — og `api.publish_claim_revision(uuid, text)` regner ingenting ut
selv. At forfatter, godkjenner og publisher nå er samme menneske, står eksplisitt i
`grant_reason` som registrert gjeld (CONTENT_GOVERNANCE.md §5, §74.7), og skal revurderes så
snart Antidep har mer enn én kvalifisert person.

Bare publisering er eksponert. Avpublisering og rollback finnes i `knowledge` fra migrasjon
006 og trenger hver sin flate med sine egne spørsmål; de hører til sin egen leveranse.

---

**Kjeden er prøvd i produksjon. Dette er avlesningen.**

| Ledd | Avlesning |
| --- | --- |
| 1. Deploy | Seks migrasjoner kjørt med `./scripts/deploy-migrations.sh`; etterpå femti rader mot femti filer |
| 2. Rolletildelingen | `publisher` skrevet for den navngitte redaktørkontoen. Kontoen har nå `editor`, `reviewer` og `publisher` — tre rader, tre begrunnelser |
| 3. Lesing som redaktør | `api.extraction_review_workspace()` gir to evidensfunn i køen, begge med `uncertain` som gjeldende kontroll og null av henholdsvis elleve og ti påkrevde felter dekket |
| 4. Hele kjeden | Kjørt mot evidensfunn `5b98b916…` og revisjon `724bc69b…` i én transaksjon som ble rullet tilbake; se tabellen under |
| 5. Etterkontroll | Tre ekstraksjonskontroller, null `verified`, to claim-verifikasjoner, null `verified`, null reviewbeslutninger, null publiseringer, null publiserte påstander — uendret fra før deployen |

| Steg | Svar fra gaten |
| --- | --- |
| Slik det står nå | Blokkert av G5: `Evidensfunn med åpent verifikasjonsfunn: 5b98b916…` |
| Menneskelig ekstraksjonskontroll registrert gjennom skriveveien | Rad `cb0b510f…` |
| Etter kontrollen | Blokkert av G9: claim-kontrollen konkluderer ikke med `verified` — altså passerte G4, G5, G5b og G5c |
| Menneskelig claim-verifikasjon registrert | Rad `8c70bf24…` |
| Etter den | Blokkert av G11: ikke godkjent av en kvalifisert redaktør |
| Publiseringsgodkjenning registrert | Rad `da59a174…` |
| Etter godkjenningen | **Hele publiseringsgaten passerer** |
| Publisering gjennom `api.publish_claim_revision(...)` | Hendelse `957ec378…`, `publish av human:peder-holman`, og påstanden synlig i `api.published_claims` |

Det siste leddet er den positive assertionen for hele gaten på én gang, og det første ledd i
prosjektets historie der en publisering faktisk lykkes.

**De fire vurderingene i tabellen er syntetiske, og det er ikke en formalitet.** De ble
registrert for å prøve at skriveveiene og gaten virker mot de reelle radene, og transaksjonen
ble rullet tilbake. De er ikke faglige vurderinger av innholdet, og ingen `verified`
ekstraksjonskontroll, ingen `verified` claim-verifikasjon, ingen godkjenning og ingen
publisering finnes i produksjon. De vurderingene hører til prosjekteieren — å registrere dem
fra en agentsesjon ville vært å gjøre nøyaktig det `ANTIDEP_CONSTITUTION.md` §12 forbyr. Ingen
klinisk verdi er endret for å få gaten grønn.

**Flaten.** To nye sider, `/extraction-review` og `/extraction-review/:evidenceItemId`, og en
tredje handling på reviewflaten. Ingen felter er huket av på forhånd: en avhuking er en påstand
om at revieweren faktisk har sammenlignet feltet med kilden, og en forhåndsutfylt liste ville
gjort den påstanden på hens vegne. Feltdekningen leses av publiseringsgatens egne funksjoner,
og differansen mellom «kreves» og «dekket» er ren mengdelære over to lister databasen har
levert. Publiseringen tilbys bare når gaten selv sier at den passerer — en visning av
tilstanden, ikke en beslutning om den.

**Testene.** Fire nye pgTAP-filer: `540` (den menneskelige skriveveien, med hver
autorisasjonsgren, radinvariantene, avtrykket, append-only, mandatet som radens egen garanti
når skriveveiens autorisasjon er mutert bort, og at kontrollen tar radlåsen), `550` (flaten,
radgrensen, feltdekningen lest av gatens egne funksjoner, og assertionen om at verifikatorens
lesegrunnlag er *nøyaktig* det samme uttrykket flaten viser), `560` (publisher-tildelingens
fire tilstander og publiseringshandlingens avvisninger, med den viktigste assertionen sist:
rollen åpner ingen gate) og `570` (hele kjeden fra deterministisk `uncertain` til publisert
påstand, med hvert ledd registrert gjennom sin egen faktiske skrivevei, og med et senere avvik
som nullstiller dekningen til slutt).

**`scripts/verify-counts.sh` er utvidet.** Kontrollen «hver merget rad har sin commit» krevde
`(#N)` i et commit-emne. Squash-mergen av #59 tok ikke med nummeret i emnet — bare i kroppen —
så raden kunne verken føres som merget eller stå som åpen uten at vakten slo ut. Kontrollen
godtar nå også et eksakt treff på radens tittel, som tabellen uansett hevder er commit-emnet
ordrett. Det er en strengere påstand enn nummeret alene, ikke en løsere, og den er
mutasjonstestet: en fabrikkert rad ført som merget slår fortsatt ut.

**Hva som gjenstår for Milepæl B.** Ingenting som er kode. Maskineriet er komplett, deployet og
prøvd mot de reelle radene. Det som står igjen, er prosjekteierens faktiske faglige vurderinger
i flaten:

1. **Kontroller ekstraksjonen mot kilden** på `/extraction-review`, for det evidensfunnet
   påstanden hviler på. Kontrollen må dekke hvert felt funnet påstår noe om — flaten viser
   hvilke — og konkludere med `verified` for at G5 og G5b skal slippe.
2. **Kontroller påstanden mot grunnlaget** på `/review`, og konkluder med `verified` når alle
   sju kontrollpunktene holder.
3. **Registrer publiseringsgodkjenningen** som en egen beslutning på den samme flaten.
4. **Publiser revisjonen** med handlingen som da blir tilbudt.

Fire vurderinger, tre av dem faglige. Ingen av dem kan tas av en agent.

---


### 74.38 Kontrollflaten er bygget om til en guidet kontrolløkt

§74.37 endte med at maskineriet var komplett og at det som gjenstod, var prosjekteierens
faktiske faglige vurderinger i flaten. Ved første forsøk viste flaten seg ikke å være brukbar
til det. Den var teknisk riktig og faglig uframkommelig: et helt dossier først, så et skjema
der revieweren skulle huke av fjorten felter, velge et samlet utfall, skrive «hvordan
gjennomførte du kontrollen?» og oppsummere funnene sine i ett felt til slutt — etter at
grunnlaget var lest ferdig og detaljene var blitt kalde.

Denne leveransen erstatter arbeidsmodellen. Databaseobjektene er de samme fire, og
publiseringsgaten er uendret.

**Én beslutning om gangen.** Kontrollen er nå en sekvensiell økt sentrert om én
påstandsrevisjon: hvilken påstand som vurderes, hvilken tilgang kontrolløren faktisk har til
hver kilde, ett steg per felt funnet påstår noe om, de sju kontrollpunktene ett om gangen,
den eksplisitte publiseringsbeslutningen, og publiseringen. Bare det aktive steget står åpent;
et ferdig steg lukkes, markeres med svaret sitt og kan åpnes igjen. Hele dossieret ligger
bak «Tekniske detaljer» og er ute av den kliniske arbeidsflyten.

**Tretten migrasjoner, og den bærende beslutningen er hvem som lager kontrollgrunnlaget.**

| Migrasjon | Hva den gjør |
| --- | --- |
| 008h | `audit.event_operation` får `evidence_field_grounding_recorded` |
| 005u | `knowledge.evidence_field_groundings` — kildeforankringen per kontrollfelt, med leser, dossier og avtrykk |
| 007g | Innsettingen i `knowledge.evidence_items` flyttes ut i én delt funksjon begge skriveveiene kaller |
| 003b | `knowledge.source_representation` og `source_versions.representation` — hva slags representasjon som faktisk ble hentet |
| 005v | `api.register_agent_extraction(...)` — ekstraksjonsagentens skrivevei, med komplett forankring som vilkår |
| 005w | Ekstraksjonsagenten får sin identitet i `provenance.agent_identities` |
| 003c | Golden slicens kildeversjoner får representasjonstypen `abstract`, og kolonnen fryses |
| 005x | `workflow.evidence_grounding_digest`, `grounding_machine_proved`, og kravet om maskinbevis før en menneskelig bekreftelse |
| 005y | Dekningen er unionen av kontroller: radkravet om kildepekeren er flyttet til gaten, og en uavklart kontroll teller nå med sine egne felter |
| 005z | `provenance.agent_runs.input_source_version_id`, og den sammensatte fremmednøkkelen som binder ekstraksjonen til kildeversjonen kjøringen leste |
| 005æ | Grunnlaget bærer `grounding_machine_proved`, så kontrolløkten kan stoppe før feltskuffene |
| 005ø | Maskinbeviset er det *gjeldende*: et nyere avvik underkjenner et eldre bevis. Kjøringens kildeversjon er et uforanderlig premiss |
| 005å | Verifikasjonsradene får et registreringsnummer tildelt på innsiden av radlåsen, og «senere» leses av det framfor av klokka |

**Koblingen mellom felt og kilde fantes ikke som data, og det var den egentlige feilen.**
Kontrollflaten kunne bare stille ett spørsmål — «stemmer denne raden med kilden?» — fordi
grunnlaget den kunne vise, var hele `raw_extraction`: utypet jsonb uten kobling til hvilket
felt et utdrag gjelder, og selv en del av den maskinelle ekstraksjonen. Å be om et svar per
felt uten å kunne vise grunnlaget per felt ville vært å be kontrolløren finne grunnlaget selv,
fjorten ganger.

`knowledge.evidence_field_groundings` bærer fire ting per felt: hvilket felt forankringen
gjelder, det minste ordrette kildeutdraget, den presise kildepekeren for nettopp det utdraget,
og en kort eksplisitt begrunnelse for hvordan utdraget ble til den strukturerte verdien.

**Forankringen er ekstraksjonens produkt, ikke redaktørens.** Ved første forsøk lå
forankringen på den manuelle registreringssiden, og det var feil produsent: da ville
venstresiden i kontrolløkten vært noe et menneske skrev inn ved siden av verdien, og
kontrolløren ville kontrollert skjemautfyllingen framfor kilden.
`api.register_agent_extraction(...)` er derfor den eneste veien inn. Den autentiserer
identiteten for rollen `evidence_extraction`, krever en åpen agentkjøring, krever en
kildeversjon med registrert representasjonstype, og avviser enhver ekstraksjon som ikke
forankrer hvert semantiske felt raden påstår noe om
(`workflow.assert_extraction_fully_grounded(uuid)`). Editorveien
`api.create_evidence_item(...)` er uendret og skriver ingen forankring; et funn registrert
der er nøyaktig så kontrollerbart felt for felt som fraværet sier.

**Den femte tingen lagres bevisst ikke, og det er en sikkerhetsbeslutning.** «Agentens
strukturerte tolkning» finnes allerede: det er kolonnen på `knowledge.evidence_items`. En
kopi ved siden av kunne kommet i utakt med den kanoniske verdien, og da ville kontrolløren
bekreftet en setning som ikke er det databasen holder. Utsagnet «Antidep mener at studien
inkluderte 48 deltakere» bygges derfor deterministisk av raden selv, i
`src/lib/extraction-statements.ts`, og forankringen sier bare hva utsagnet hviler på. Skjult
chain-of-thought verken lagres eller etterspørres.

**Maskinen beviser venstresiden, mennesket vurderer høyresiden.** Den deterministiske
ekstraksjonskontrollen søker hvert forankret utdrag ordrett i den kildeversjonen raden peker
på. Et utdrag som ikke står der, er et avvik av samme slag som et sitat som ikke gjør det, og
feltet det gjelder føres aldri opp som kontrollert. Kontrolløren står dermed igjen med den
ene sammenligningen som ikke kan avgjøres maskinelt: følger den strukturerte verdien av
utdraget? De verifiserte utdragene inngår også i høystakken tallene og begrepene søkes i;
kravet om at armen og endepunktet står i samme sammenhengende treff, er urørt.

**To provenansfelter er ikke lenger egne kliniske steg.** `raw_extraction` og
`source_locator` er påstander om proveniens — «er noe bevart ordrett?» og «hvor i dokumentet
står funnet som helhet?» — og som egne spørsmål i en kontrolløkt var de spørsmål uten klinisk
innhold. `workflow.semantic_check_fields(uuid)` er `required_check_fields(uuid)` uten dem, og
det er dette settet økten spør om. Garantien de bar er ikke svekket, men flyttet dit den er
sterkere: hver forankring har sitt eget ordrette utdrag og sin egen presise peker, så en
bekreftet semantisk delkontroll *er* en kontroll av begge deler — for nøyaktig det feltet
framfor for raden under ett. Publiseringsgatens G5b leser fortsatt hele
`required_check_fields(uuid)`, og de to feltene føres opp når kontrollen ender i en
bekreftelse.

**Lenken til kilden bygges av identifikatorene, ikke av henteadressen.**
`source_versions.retrieved_from` er maskinens eksakte adresse — for et EUtils-kall er den XML
— og er riktig der fingeravtrykket beregnes, men den er ikke artikkelen et menneske skal
åpne. Den menneskelige lenken bygges av kildens DOI, med PubMed-siden som reserve, og står
én gang i økten: i kildetilgangssteget. Henteadressen er flyttet til «Tekniske detaljer».

**Gamle funn stopper økten framfor å be om håndarbeid.** Et evidensfunn uten komplett
forankring kan ikke kontrolleres felt for felt: det finnes ingen venstreside å bedømme
verdien mot. Økten stopper derfor med én kort beskjed om at funnet må ekstraheres på nytt
etter gjeldende protokoll, og navngir feltene som mangler. Den deterministiske kontrollen
konkluderer på samme måte: `uncertain`, aldri `verified`. Antidep gjetter aldri et utdrag ut
av `raw_extraction` — et utdrag gjettet på den måten ville vært å konstruere nettopp det
grunnlaget kontrollen skal prøve.

Golden slicens to funn er eldre enn 005u og står i akkurat denne tilstanden. De blir
*ikke* forankret i ettertid. Første forsøk gjorde nettopp det, og reviewen fanget hvorfor
det var galt: forankringen er låst til evidensfunnets egen skaper av en sammensatt
fremmednøkkel, så retroaktive rader ville sett ut som et produkt av den opprinnelige
ekstraksjonskjøringen — en kjøring som aldri lagde dem. Legacy blir stående som legacy, og
veien videre er re-ekstraksjon gjennom agentveien.

003c gjør bare det som ikke er en påstand om noen: den setter representasjonstypen
`abstract` på de to kildeversjonene. EUtils efetch gir MEDLINE-posten, ikke
fulltekstartikkelen, og opplysningen har ingen aktørattribusjon — den sier hva dokumentet
*er*. Radene identifiseres av kildens PubMed-ID fordi id-ene i migrasjon 003 er
databasegenererte. Rett etterpå legges kolonnen inn i
`knowledge.freeze_source_version()`: `representation` er historisk metadata om et
øyeblikksbilde, og en rad som stille kunne endres fra `abstract` til `full_text` ville latt
en ekstraksjon se ut som om den hvilte på noe annet enn den gjorde.

**Maskinbeviset er ikke lenger bare implementert — det er påkrevd.** Kontrollen fantes,
men ingenting krevde at den var kjørt. En reviewer kunne åpne et funn der ingen hadde prøvd
utdragene, svare «Ja» på alt og registrere en bekreftelse som hvilte på at utdraget så
troverdig ut. Fra 005x avviser `workflow.record_evidence_verification(...)` en menneskelig
bekreftelse med mindre to ting holder: hvert semantisk felt har forankring, og det finnes en
maskinell kontroll som gjelder *dette* grunnlaget og som førte opp både `raw_extraction` og
`source_locator`. Maskinelle kontroller er unntatt fra det andre — de *er* beviset, og et
krav om at beviset skal ha et bevis ville vært sirkulært. Kontrollene ligger etter
innsettingen, slik at tabellens egne CHECK-er får avvise først; unntaket ruller
transaksjonen tilbake.

Det krever at en verifikasjonsrad vet hvilket grunnlag den gjelder, og
`verified_grounding_digest` settes derfor av skriveveien selv, under radlåsen den allerede
tar. Avtrykket er `workflow.evidence_grounding_digest(uuid)` og ikke det brede
`evidence_extraction_digest(uuid)`: det siste dekker settet av verifikasjoner med vilje, så
en kontrollør ser at noen andre har registrert en kontroll — men da ville et maskinbevis
vært foreldet i samme øyeblikk det ble skrevet. Det snevre avtrykket dekker ekstraksjonen,
kildeversjonen og settet av forankringer, og ikke mer.

**Ingen rad påstår mer enn sin egen operasjon.** Menneskets `checked_fields` inneholder nå
bare de semantiske feltene kontrolløren faktisk svarte «ja» på — ikke feltene hen ikke kunne
avgjøre, og ikke de to provenansfeltene økten aldri stilte spørsmål om. Det krevde to
endringer, fordi de gamle reglene gjorde den ærlige raden umulig:

* `evidence_verifications_locator_checked_check` krevde `source_locator` i *enhver*
  bekreftelse. Kravet er flyttet til gaten: G5b krever fortsatt at feltet er dekket, men
  dekningen kan komme fra den kontrollen som faktisk gjorde jobben.
* `covered_check_fields(uuid)` telte bare `verified`-rader og nullstilte ved enhver senere
  rad som ikke var det. Den deterministiske kontrollen ender normalt på `uncertain`, så
  maskinen kunne aldri bidra med dekning uansett hva den hadde bevist. Regelen er nå delt i
  to, som den alltid mente: et **avvik** nullstiller dekningen fra alt som ligger foran, en
  **uavklart** kontroll gjør det ikke — den motsier ingenting, og feltene den førte opp,
  gikk den faktisk gjennom.

G5 er urørt, og er det som hindrer at en uavklart kontroll blir en bekreftelse: den *siste*
registrerte kontrollen må fortsatt være `verified`. Unionen sier hva som er dekket; G5 sier
at noen konkluderte.

**Maskinbeviset hviler ikke på `raw_extraction`.** Beviset er `source_locator` i maskinens
`checked_fields`, og den deterministiske kontrollen fører opp nettopp det feltet bare når
representasjonen lot seg reprodusere, forankringen er komplett, og hvert forankret utdrag ble
gjenfunnet ordrett. Fram til 005y krevdes også `raw_extraction`, som gjorde den valgfrie
legacy-kolonnen til en skjult forutsetning: en helt gyldig agentekstraksjon uten
`source_quote` kunne aldri bli bevist, og dermed aldri menneskebekreftes. Av samme grunn
fører `required_check_fields` nå opp `raw_extraction` bare for rader som faktisk har en.

**Rekkefølgen er maskinbevis → menneskelig semantikk.** 005x håndhevet kravet ved lagring,
men flaten visste ingenting: en kontrollør kunne gå gjennom alle feltene og først få
avvisningen til slutt. Grunnlaget bærer nå `grounding_machine_proved` (005æ), og
kontrolløkten stopper før feltskuffene med én kort beskjed når beviset mangler eller er
foreldet.

**Ekstraksjonen er bundet til sin kjøring, og kjøringen til det den leste.**
`knowledge.evidence_items` har fått `agent_run_id` og en generert `agent_run_role`, med to
sammensatte fremmednøkler mot `provenance.agent_runs` — den ene binder kjøringen til
aktøren, den andre til rollen. En tredje binder ekstraksjonen til kildeversjonen kjøringen
faktisk ble åpnet for (`input_source_version_id`, 005z): uten den kunne en kjøring åpnes for
én utgave og registrere en ekstraksjon mot en annen. Koblingen er en fremmednøkkel og ikke
en nøkkel i `input_manifest`, fordi manifestet er fri jsonb skrevet av klienten — en regel
som leste en nøkkel derfra, ville vært en regel som stolte på en klientkonvensjon.
Aktørattribusjon alene sa *hvilken agent*, ikke *hvilken kjøring*, og dermed ikke hvilken
modell, modellversjon, prompt-versjon eller pipeline-versjon verdiene kom fra. Mønsteret er
det `workflow.evidence_verifications` allerede brukte, kopiert ord for ord. `content_hash`
er urørt av kolonnene: fingeravtrykket identifiserer innholdet i ekstraksjonen, ikke hvilken
kjøring som produserte det, så to kjøringer som kommer fram til samme verdier skal fortsatt
kollidere som dublett.

**Ekstraksjonsagenten kjører.** Kontrakten fantes i databasen, men ingen agentflyt brukte
den. Nå finnes hele kjeden: `api.begin_agent_run`, henting av representasjonen over nett,
krav om at fingeravtrykket er den registrerte kildeversjonens, ordrett kontroll av hvert
utdrag mot den, `api.register_agent_extraction`, og `api.complete_agent_run`. Kjøringen
registrerer ingenting den ikke har hentet og kontrollert, og lukkes alltid.

Leddet som *leser* en artikkel og bestemmer at utvalget var 48, er ikke med: det krever en
språkmodell, og dermed en leverandør og en konto. Det er skilt ut som forslagsformen
kjøringen tar imot (`src/agents/extraction-proposal.ts`), kontrollert felt for felt. Et
modell-ledd som skriver den formen, kobles på uten at noe annet i kjeden endres — og går
gjennom nøyaktig de samme kontrollene. Kontrollen av utdragene i selve kjøringen erstatter
ikke verifikatoren: den er generatorens egen aktsomhet, så et forslag med et oppdiktet
utdrag aldri blir en rad noen må avvise senere. Generering og verifikasjon er fortsatt to
operasjoner, av to aktører.

**Utfallet velges ikke lenger.** Kontrollalgoritmen *er* metoden. Alle obligatoriske felter
bekreftet og kildetilgangen oppfylt gir `verified`; minst ett konkret avvik gir
`needs_correction`; noe som ikke lot seg avgjøre — eller bare et sammendrag å gå på — gir
`uncertain`. Reglene er databasens egne, uttrykt framover framfor som en avvisning:
`*_source_access_check` forbyr en bekreftelse på et avledet sammendrag,
`claim_verifications_verified_requires_all_ok_check` krever at alle sju punktene er `ok`, og
`*_findings_required_check` krever et funn når utfallet ikke er `verified`. Begrunnelsen som
lagres, skrives deterministisk av de samme svarene; kontrolløren skriver bare der teksten
bærer informasjon — ved et avvik, der det oppdages, og ved «Be om endringer» og «Avvis».

`rejected` kan ikke utledes. Det er en sterkere konklusjon enn «noe må rettes», og en terskel
for hvor mange avvik som tipper over i avvisning ville vært en terskel ingen har bestemt.
Avvisning uttrykkes der den hører hjemme: i publiseringsbeslutningen.

**Foreldet grunnlag rammer det som faktisk er endret.** Garantien er uendret og ligger i
databasen: `workflow.assert_extraction_unchanged(uuid, text)` og
`workflow.assert_evidence_set_unchanged(uuid, text)` avviser en registrering der noe i
grunnlaget er endret, under radlåsen. Avtrykket dekker nå også settet av forankringer og
kildeversjonens representasjonstype. Flaten legger til én bekvemmelighet over den: den
sammenligner avtrykket av hvert *steg* før og etter en ny henting, og nullstiller bare de
stegene som nå viser noe annet. En forankring som byttes ut, rammer sitt eget felt; en
kontroll som registreres av en annen i mellomtiden, rammer registreringssteget og ikke
svarene.

**«Senere» kunne bety «tidligere».** Hele kjeden hviler på at den *siste* kontrollen er den
gjeldende: publiseringsgatens G5 og G9 leser den, og et senere avvik nullstiller både
dekningen og maskinbeviset. «Senere» ble avgjort av `verified_at`, som settes med `now()` —
transaksjonens *starttidspunkt*, ikke tidspunktet raden ble skrevet. To samtidige
registreringer kan derfor starte i én rekkefølge og skrive i den motsatte, og et reelt avvik
som ble skrevet sist kunne bære det eldste tidsstempelet og forsvinne bak en bekreftelse som
ble skrevet før det. Radlåsen serialiserte skrivingene riktig; det var rekkefølgen de ble
*lest* i som ikke fulgte dem. 005å gir hver verifikasjonsrad et registreringsnummer fra en
sekvens, tildelt av en trigger på innsiden av den samme radlåsen skriveveien allerede tar, og
alle lesere — gaten, maskinbeviset, dekningen og de to reviewerflatene — bytter til det
nummeret samtidig. Tidsstemplene beholdes uendret og leses fortsatt der spørsmålet er *når*
noe ble gjort, som i mandatkontrollene. `workflow.review_decisions` har samme form på «den
gjeldende beslutningen» og dermed samme svakhet; den er skilt ut som eget arbeid, fordi en
retting der trekker den publiserte lesemodellen inn i endringen.

**Ingen regel er myket opp.** Ingen CHECK, constraint, trigger, policy eller grant er fjernet
eller svekket, og ingen ny direkte tabelltilgang er gitt til `anon` eller `authenticated`.
`knowledge.evidence_field_groundings` er append-only med RLS og uten klientgrant, og
forankringen er låst til ekstraksjonens egen skaper av en sammensatt fremmednøkkel.
Grunnlagsavtrykket er blitt strengere, ikke løsere, og agentveien krever to ting editorveien
ikke gjør: en kildeversjon med kjent representasjonstype, og komplett forankring.

**Det som gjenstår.** Modell-leddet som leser en representasjon og foreslår de strukturerte
verdiene, er en egen leveranse. Den trenger en modelleverandør, som er en kostnads- og
kontobeslutning for prosjekteieren. Inntil den er tatt, må et forslag skrives for hånd, og
golden slicen står uforankret — og dermed ukontrollerbar felt for felt, som er den sanne
tilstanden.

**Testene.** Tre pgTAP-filer bærer leveransen: `580` (tabellen, rettighetene,
radinvariantene, append-only, leseren, dossieret, avtrykket og auditsporet), `590`
(agentens skrivevei, at forankringen blir til i samme kall og attribueres til kjøringens egen
aktør, at et hull i forankringen ikke etterlater noe, at en kildeversjon uten
representasjonstype avvises, at editorveien ikke kan skrive forankring, og hele kjeden fra
agentekstraksjon gjennom maskinbeviset til publisert påstand) og `600` (bindingen til
kjøringen, frysingen av representasjonstypen, og maskinbeviset: at det mangler før
verifikatoren har kjørt, at en menneskelig bekreftelse da avvises av databasen og ikke
etterlater noe, at det finnes etterpå, at det slutter å gjelde når forankringen endres, og at
registreringsrekkefølgen — ikke klokka — avgjør hvilken kontroll som er den gjeldende).
Agentkjøringen har egne tester uten database og uten nett: at den registrerer og lukker
kjøringen, at forankringen sendes videre uendret, at kjøringen sier hva den bygde på, og de
fire tilfellene der den nekter å registrere noe.

**Kjeden er prøvd der leddene faktisk møtes.** `scripts/agent-chain-test.ts` kjører de ekte
kjørerne gjennom de ekte portene mot en ekte database: `api.begin_agent_run`,
`api.register_agent_extraction`, `api.extraction_verification_input`,
`api.register_extraction_verification`, `api.register_human_extraction_verification`,
`api.register_human_claim_verification`, `api.register_publication_approval` og
`api.publish_claim_revision`. Bare kildehentingen er fikstur. pgTAP prøver SQL, vitest prøver
TypeScript med doble for databasen; grensen mellom dem — at parameternavnene agentporten
sender, er nøyaktig de `api`-funksjonene tar imot — var ikke prøvd av noen av dem. Prøven
kjører i databasejobben, etter migrasjonene og pgTAP, mot den samme stacken.

`scripts/db-lock-test.sh` prøver det pgTAP ikke kan nå: hva som skjer mellom to forbindelser.
Tre av prøvene viser at en samtidig skriving må vente på radlåsen. Den fjerde er den
motsatte formen — to registreringer som ikke venter på hverandre i det hele tatt: økt A
begynner først, økt B skriver og commiter, og A skriver etterpå. Prøven krever at raden som
faktisk ble skrevet sist er den gjeldende, og at avviket den bærer underkjenner både
maskinbeviset og dekningen fra bekreftelsen som ble skrevet før det.

`src/agents/extraction-chain.test.ts` krysser den samme grensen uten database, og er
raskere: den er en del av `npm test` og fanger drift mellom leddene før stacken er startet.
den ekte ekstraksjonskjøringen skriver, det den skrev oversettes til det leseflaten ville
gitt, den ekte verifikatorkjøringen leser og prøver utdragene mot den samme kildeteksten, og
menneskets rad utledes av delsvarene. Til slutt regnes G5b ut som ren mengdelære over de to
radene. Bare de to ytterste punktene er fikstur — kildeteksten og forslaget. Selve
skriveveien er SQL og prøves i `590` og `600`, som går den samme kjeden gjennom
`api.register_agent_extraction`, `api.register_extraction_verification`,
`api.register_human_extraction_verification` og publiseringsgaten. Frontenden har fått nye testfiler for de rene
modulene — utledningen av utfallene, utsagnene per felt, avtrykkene per steg, den
menneskelige kildelenken og grunnlaget for hvert kontrollpunkt — og de to sidetestene er
skrevet om til å beskrive arbeidsmodellen: at bare det aktive steget vises, at lenken går til
DOI og aldri til henteadressen, at ingen feltskuffe gjentar lenken, at ingen steg spør om
`raw_extraction` eller den globale kildepekeren, at et ugrunnet funn stopper økten, at
avvikstekst festes til riktig delkontroll, at det ikke finnes noen utfallsmeny, og at hele
kjeden går gjennom uten at noen av de fire beslutningsobjektene slås sammen.

---

### 74.39 «Gjeldende beslutning» er databasens rekkefølge, og forslaget er en kontrakt

§74.38 lukket det samme hullet på de to verifikasjonstabellene og navnga det som stod igjen:
`workflow.review_decisions` har samme form på «den gjeldende beslutningen», og dermed samme
svakhet. Denne leveransen lukker den, og gjør samtidig ekstraksjonsforslaget til en form som
tåler å være den permanente grensen mot et framtidig modell-ledd.

**To migrasjoner.**

| Migrasjon | Hva den gjør |
| --- | --- |
| 006i | `workflow.review_decisions` får `registration_ordinal` tildelt på innsiden av radlåsen, og alle sju leserne av «den gjeldende beslutningen» bytter til det |
| 007h | Dublettavvisningen fra `knowledge.record_evidence_item` navngir raden som kolliderte, slått opp med den kanoniske identiteten `UNIQUE`-regelen bruker |

**Et menneskes nei kunne forsvinne.** «Den gjeldende beslutningen» ble avgjort av
`decided_at`, som settes med `now()` — transaksjonens *starttidspunkt*, ikke tidspunktet raden
ble skrevet. To samtidige registreringer kan starte i én rekkefølge og skrive i den motsatte,
og da bærer raden som faktisk ble skrevet sist det eldste tidsstempelet. En `rejected` skrevet
sist kunne sorteres bak en `approved` skrevet før den, og publiseringsgatens G12 ville lest
godkjenningen som gjeldende. Retningen er alvorligere enn på verifikasjonstabellene: der kunne
et maskinelt avvik forsvinne, her kan et menneskes faglige avvisning gjøre det. Den samme
formen finnes på tilbaketrekking av en ekstraksjon, der et underkjent evidensfunn kunne stått
som gyldig evidens i den publiserte lesemodellen.

Rettingen er den samme som 005å: et registreringsnummer fra en sekvens med `cache 1`, uten
`DEFAULT`, tildelt av en `BEFORE INSERT`-trigger *etter* at radlåsen på objektet er tatt.
Låsen tas for begge `review_type`-variantene — `knowledge.claim_revisions` for en
publiseringsgodkjenning, `knowledge.evidence_items` for en tilbaketrekking — og ikke bare for
den ene `workflow.set_review_evidence_set_digest()` allerede låser. Alle aktive lesere bytter i
den samme migrasjonen: publiseringsgatens G6, G11 og G12, frysingen av
godkjenningstidspunktet på publiseringshendelsen, `workflow.claim_review_history`,
`api.claim_review_workspace`, og de to viewene i den publiserte lesemodellen.
`decided_at` beholdes uendret og leses fortsatt der spørsmålet er *når* beslutningen ble
tatt — blant annet i rollekontrollen, som krever at tildelingen fantes på det tidspunktet.

**Forslaget er nå en kontrakt, ikke bare en form.** Leddet som leser en artikkel og foreslår
strukturerte verdier, er fortsatt ikke bygget, og ingen betalt modelleverandør er koblet inn.
Det som er gjort, er å gjøre grensen god nok til å være permanent: forslaget bærer sin egen
kontraktsversjon, ukjente felter avvises framfor å ignoreres, hvert lukket vokabular
kontrolleres mot `src/types/api.ts`, kildeversjonen må være en uuid og fingeravtrykket ha
kildeversjonenes egen form, og et kildeutdrag må bære nok kontekst til å være
kontrollgrunnlag. `raw_extraction` navngis særskilt som noe et forslag ikke skal levere.
Kontrakten finnes maskinlesbart i `proposals/extraction-proposal.schema.json`, bygget av de
samme konstantene parseren bruker og prøvd mot dem, med et commitet syntetisk eksempel som mal.

**Forslagene lages utenfor Antidep, og skriver ingenting.** `proposals/` er en lokal,
gitignorert inndatakatalog med en kort oppskrift: hvordan man finner riktig kildeversjon,
hvilken representasjon utdragene må stå i, hvordan filen ser ut, og de tre kommandoene —
tørrkjøring, registrering og den deterministiske kontrollen etterpå. Den som lager forslaget
har ingen databasetilgang; alt som skrives, skjer i kjøringen, med agentlegitimasjon og under
de deterministiske kontrollene.

**Re-ekstraksjonen lar de gamle radene stå.** `npm run agent:reextract-evidence` tar ett eller
flere forslag, kjører hvert gjennom den ordinære ekstraksjonskjøringen, og kjører den
deterministiske kontrollen på nøyaktig det funnet som ble registrert. Det nye, forankrede
funnet kommer *ved siden av* det gamle; ingen legacy-rad muteres, og ingen forankring legges
til retroaktivt — ingen vet hvilke utdrag den gamle ekstraksjonen faktisk ble laget av.
Kjøringen er idempotent uten lokal bokføring: `evidence_items_content_hash_key` dekker hele
radens faglige innhold, så det samme forslaget kjørt om igjen skriver ingenting og
rapporteres som `already_registered`. Kommandoen lenker ikke funnet til en påstand: om et funn
støtter, motsier eller er indirekte relevant for en formulering er en faglig vurdering, og
gjøres av en kvalifisert redaktør i adminflyten (§12, §15).

**Ekstraksjonsagenten har fått sitt eget variabelpar.** `ANTIDEP_EXTRACTION_AGENT_*` ved siden
av verifikatorens `ANTIDEP_AGENT_*`. Re-ekstraksjonen kjører begge leddene i den samme
prosessen, og to roller kan ikke dele ett variabelnavn — rollen er rettighetsgrensen.

**Re-ekstraksjonen kan fullføre en avbrutt kjøring, og lyver ikke om kontrollen.** Funnet i
teknisk review. Registreringen og kontrollen er to skrivinger i to transaksjoner; dør
prosessen mellom dem, finnes raden uten maskinbevis, og en ny kjøring med det samme forslaget
får bare «dublett» tilbake. Avvisningen navngir nå raden (se nedenfor), så kjøringen har en
id å kontrollere, og fullfører kontrollen på nøyaktig den raden framfor å skrive en ny.
Resten av køen står urørt. Kjøringen teller i tillegg
funn som står uten registrert maskinbevis, og kommandoen avslutter med feil framfor å si at
kjeden er komplett: en kontroll som ikke lot seg gjennomføre, er ikke en kontroll (§11).

**Avtrykket dekker verdiene, ikke forankringen, og kjøringen skiller nå de to tilfellene.**
Også et funn fra review. `content_hash` beregnes av kolonnene på `knowledge.evidence_items`;
forankringen ligger i sin egen tabell. Et forslag som bare retter et utdrag, en peker eller en
begrunnelse, er derfor den samme ekstraksjonen for databasen og avvises som en dublett.

**Identiteten kommer fra databasen, ikke fra en likhet kjøreren finner på.** Første forsøk lot
kjøreren gjenfinne raden i arbeidskøen på kildeversjon og forankring. Det er ikke nok, og
teknisk review fant hvorfor: to funn fra den samme kildeversjonen kan legitimt dele forankring —
det samme utvalgsutdraget, den samme populasjonssetningen — og likevel gjelde ulike utfall. En
slik match kunne pekt på feil rad, og en slutning fra hva som *ellers* lå i køen kunne meldt en
konflikt der det ikke var noen.

Migrasjon 007h lar derfor avvisningen navngi raden. Oppslaget bruker
`knowledge.evidence_item_content_hash` på en radvariabel satt av de samme uttrykkene som
innsettingen — den kanoniske identiteten `UNIQUE`-regelen bruker, ikke en ny definisjon.
Kjøringen leser så nøyaktig den raden og avgjør på den: bærer den forslagets forankring og har
et gjeldende maskinbevis, er kjeden komplett; bærer den forankringen uten beviset, er det en
avbrutt kjøring som fullføres; bærer den en annen forankring, er forslaget en rettelse som
avtrykket ikke skiller fra en dublett. Det siste meldes som en forankringskonflikt, og
kommandoen avslutter med feil framfor å si «allerede gjort». At rettelsen ikke kan registreres i
det hele tatt, er en begrensning i datamodellen og ikke i kjørerne; den er ført som issue #66
med tre alternativer.

**En feil i ekstraksjonskjøringen ble funnet av at kjeden nå prøves mot en ekte database.**
`agent_runs_status_shape_check` krever en begrunnelse på en kjøring som lukkes som `aborted`.
Ekstraksjonskjøringen fra §74.38 sendte `null` i alle tre avbruddstilfellene — tørrkjøring,
et forslag som ikke holdt mål, og nå dubletten — og ville derfor feilet med en
constraintbrudd mot en ekte base. Feilen var usynlig fordi bare doble for databasen prøvde de
stiene. Nettopp `npm run agent:extract-evidence -- --dry-run` er kommandoen som skal brukes
før hver ekte registrering, så feilen lå i den mest brukte stien. Rettelsen er den samme
formen verifikatorkjøringen allerede hadde: hvert avbrudd bærer sin egen begrunnelse.

**Ingen regel er myket opp.** Ingen CHECK, constraint, trigger, policy eller grant er fjernet
eller svekket, og ingen ny tabelltilgang er gitt til `anon` eller `authenticated`. Kolonnen
føyer seg inn under det tabellvide lesegrantet `workflow.review_decisions` allerede har, og
radpolicyen som avgrenser klientroller til `extraction_withdrawal` er uendret.

**Testene.** `610` bærer migrasjonen: kontrakten på kolonnen, sekvensen og triggeren, at låsen
dekker begge `review_type`-variantene, og begge retningene av rettingen — en godkjenning
skrevet sist med det eldste tidsstempelet slipper gjennom gaten og fryses på
publiseringshendelsen, en avvisning skrevet sist blokkerer på G12 og står som den gjeldende i
reviewerflaten og i køen, og en tilbaketrekking skrevet sist slår gjennom i begge viewene i
den publiserte lesemodellen. `scripts/db-lock-test.sh` har fått prøve 5, som gjør det samme
med to reelle forbindelser: økt A begynner først, økt B godkjenner og commiter, og A avviser
etterpå, gjennom den ekte skriveveien `api.register_publication_approval(...)`. Fiksturen
(`scripts/review-decision-race-fixture.sql`) er egen, idempotent og bygget slik at G1 til G10
holder, slik at det eneste som avgjør utfallet er beslutningen.

Forslagskontrakten har egne tester uten database: at et ukjent felt er en feil på alle tre
nivåene, at hvert lukket vokabular avvises utenfor seg selv, at kontraktsversjonen kreves, at
et for kort utdrag avvises, at skjemafilen er nøyaktig det koden bygger, og at det commitede
eksempelet går gjennom den samme kontrollen som et ekte forslag. Re-ekstraksjonen har egne
tester på at kontrollen kjøres på riktig funn, at en dublett verken skriver eller kontrollerer,
at en tørrkjøring ikke skriver, og at ett dårlig forslag ikke stopper de andre.

`scripts/agent-chain-test.ts` har fått re-ekstraksjonen som et femte og sjette ledd, og prøver
der de tingene bare en ekte database kan avgjøre: at tørrkjøringen ikke skriver en evidensrad
men likevel lukker kjøringen sin med en begrunnelse, at det samme forslaget kjørt om igjen ikke
skriver noe fordi `evidence_items_content_hash_key` avviser dubletten, at en ekstraksjon som
ble registrert uten kontroll — den avbrutte kjøringen — blir kontrollert av den neste kjøringen
uten at det skrives en ny rad og uten at det gamle funnet på den samme kildeversjonen røres, og
at et forslag med de samme strukturerte verdiene men en annen forankring meldes som en
forankringskonflikt framfor som en dublett. To av leddene er identitetsprøvene fra review: to
funn på den samme kildeversjonen med identisk forankring men ulike verdier, der gjenopptakelsen
må treffe riktig rad, og tilfellet der den eksakte dublettraden allerede er kontrollert mens et
annet forankret funn på den samme kildeversjonen står ukontrollert, som ikke skal bli en falsk
konflikt. `590` prøver migrasjonen selv: at avvisningen navngir raden, og at den er funnet på
den kanoniske identiteten.
Samtidig prøves regelen re-ekstraksjonen finnes for: det gamle, uforankrede funnet står urørt
ved siden av det nye, uten forankring lagt til i etterkant. Det var dette leddet som avdekket
avbruddsfeilen over.

---

### 74.40 Kildeforankringen er en del av evidensfunnets identitet

§74.39 lot dublettavvisningen navngi raden som kolliderte, og navnga samtidig det som stod
igjen: `content_hash` ble regnet ut av kolonnene på `knowledge.evidence_items` alene, mens
kildeforankringen ligger i sin egen tabell. Et forslag som bare rettet et `source_excerpt`, en
`source_locator` eller en `justification`, ga nøyaktig den samme hashen, ble avvist som en
dublett — og den gale forankringen ble stående. Ført som issue #66, med tre veier videre.

**Én migrasjon.**

| Migrasjon | Hva den gjør |
| --- | --- |
| 003d | Forankringen inngår i evidensfunnets identitet, gjennom en `content_hash`-versjon 3 og et eget avtrykk på raden som databasen krever stemmer med forankringen |

**Valget er vei 1, og det følger av datamodellen.** Issue #66 satte opp tre alternativer: la
forankringen inngå i avtrykket, la den rettes på plass som en egen append-only korreksjonsrad,
eller la det stå. Den første er valgt, og begrunnelsen står i migrasjonen selv:
`knowledge.evidence_field_groundings` er allerede append-only med den samme begrunnelsen som
funnet, tabellens egen avvisningstekst sier allerede at «er forankringen feil, er ekstraksjonen
feil», og `UNIQUE (evidence_item_id, check_field)` finnes nettopp for at ett felt ikke skal
kunne ha to konkurrerende forankringer. En korreksjonsrad ville innført akkurat det den regelen
hindrer, og krevd en «gjeldende forankring»-avledning ved siden av. Kontrollradene har den
formen fordi en *vurdering* er en hendelse over tid; en ekstraksjon er det ikke.

**Hvordan et avtrykk kan dekke en annen tabell.** `content_hash` settes av en BEFORE
INSERT-trigger, og på det tidspunktet finnes forankringsradene ikke — de skrives etter funnet,
fordi de peker på det. Raden bærer derfor forankringens eget avtrykk i kolonnen
`grounding_digest`, og en utsatt `constraint trigger` krever ved commit at kolonnen stemmer med
de radene som faktisk ble skrevet. Kontrollen står på begge tabellene og går dermed begge
veier: den fanger både et funn som oppgir feil avtrykk, og en forankring som legges til på et
allerede registrert funn. Det siste er ikke hypotetisk — det er nettopp «å legge forankring på
en gammel rad», som re-ekstraksjonen finnes for å unngå.

**Én kanonisering, brukt av alle.** `knowledge.canonical_field_groundings(jsonb)` normaliserer
forslagets forankringsliste én gang. Både innsettingen i
`knowledge.evidence_field_groundings` og avtrykket bygges av den, med den samme begrunnelsen
006a hadde for å flytte kanoniseringen ut av triggerfunksjonen: to kopier som kunne komme fra
hverandre, er nøyaktig den klassen feil. Rekkefølgen i et forslag er ikke informasjon — ett
felt har én forankring — så avtrykket sorterer delene deterministisk med `collate "C"`, slik at
det er byte-rekkefølge og ikke databasens lokaltilpassede kollasjon som avgjør. En flyttet
linje i en fil blir dermed ikke feilaktig et nytt funn.

**Eksisterende rader er migrert, ikke rørt.** `grounding_digest` fylles ut av den forankringen
hver rad faktisk har — den tomme listen for alle funn registrert før 005u — og `content_hash`
regnes ut på nytt etter den nye definisjonen, slik 006a gjorde det for v2. Ingen kanonisk
kolonne røres. Rehashingen kan ikke kollidere: to rader som var distinkte under v2, hadde
distinkte feltverdier, og v3 leser de samme feltene og ett til. Migrasjonen kontrollerer selv,
før den commiter, at ingen rad står igjen på en eldre definisjon og at hvert avtrykk stemmer
med forankringen.

**Ingenting arves.** Det korrigerte funnet er en ny rad, og verifikasjoner, claim-lenker og
publiseringsgodkjenninger peker på `evidence_item_id`. Maskinbeviset, den menneskelige
ekstraksjonskontrollen, koblingen til en påstand og godkjenningen følger derfor ikke med. Det
nye funnet må selv gjennom de samme portene før det kan brukes i publisering
(ANTIDEP_CONSTITUTION.md §11, §12), og lenkingen til en påstand er som før en faglig vurdering
en kvalifisert redaktør gjør.

**Kjøreren fikk mindre å gjøre, ikke mer.** Re-ekstraksjonen sammenlignet tidligere
forankringen på den navngitte raden selv, og meldte en «forankringskonflikt» når den var en
annen — en tilstand som fantes bare fordi rettelsen ikke lot seg registrere. Den er borte:
identiteten databasen slo opp på, dekker nå forankringen, så den navngitte raden *er*
forslagets. Kjøringen avgjør bare om raden allerede bærer et gjeldende maskinbevis, og
fullfører kontrollen hvis ikke. Et forslag der bare et utdrag er rettet, går den ordinære veien:
registrering, deterministisk kontroll, ferdig.

**Ingen regel er myket opp.** Ingen CHECK, constraint, trigger, policy eller grant er fjernet
eller svekket, og ingen ny tabelltilgang er gitt til `anon` eller `authenticated`. Kolonnen har
sin egen formatkontroll, den utsatte kontrollen er ny og strengere, og dublettregelen er
strengere enn før: en dublett er nå den samme ekstraksjonen *med den samme forankringen*.

**Testene.** `620` bærer migrasjonen: kontrakten på kolonnen, funksjonene og de to utsatte
triggerne; at avtrykket er deterministisk, uavhengig av rekkefølge og lik en fast referanseverdi;
at et rettet utdrag, en rettet peker og en rettet begrunnelse hver blir et nytt funn med
identiske strukturerte verdier; at eksakt dublett fortsatt avvises og fortsatt navngir riktig
rad; at avtrykket ikke kan lyve i noen av retningene; og at gammel og ny rad står med hver sin
kontrollstatus. `100` og `280` er ført videre til v3, og `280`-kontrollen som krever at hver
kanonisk kolonne påvirker fingeravtrykket, dekker den nye kolonnen uten endring.

`scripts/agent-chain-test.ts` har fått et sjuende ledd, og det er den sterkeste vakten:
rettelsen gjøres på det *publiserte* funnet fra ledd 1 til 4, altså den ene raden som faktisk
bærer noe å arve. Prøven krever at den rettede forankringen blir en ny rad, at den går hele
veien til et gyldig maskinbevis gjennom de ekte kjørerne og de ekte portene, at den verken
arver den menneskelige kontrollen eller claim-lenken, at den gamle raden står med samme
avtrykk, samme forankring og samme kontroller som før, og at den publiserte påstanden fortsatt
viser bare det gamle funnet. Re-ekstraksjonens egne tester uten database er skrevet om til den
nye regelen: en rettet forankring registreres og kontrolleres, framfor å meldes som en konflikt.

---

### 74.41 Modell-leddet finnes, og leverandøren ligger bak et adapter

Issue #63 førte ett ledd som gjenstående: det som *leser* en artikkel og foreslår de
strukturerte verdiene for ett evidensfunn. Punkt 1, 3, 4 og 5 var bygget; punkt 2 manglet.
Det er nå bygget — og bygget slik at det ikke krever en leverandørkonto for å kunne kjøres,
prøves eller regresjonstestes.

**To migrasjoner.**

| Migrasjon | Hva den gjør |
| --- | --- |
| 005ab | Skriveveien tar imot `p_extraction_method` framfor å hardkode `ai_assisted` |
| 005ac | Kontrollgrunnlaget skiller hvem som laget utkastet fra kjøringen som registrerte det |

**Rollen er delt i to operasjoner med hver sine rettigheter.** Modell-leddet
(`npm run agent:propose-extraction`) henter kildeversjonen, krever at fingeravtrykket er den
registrerte, bygger den versjonerte prompten, spør et modelladapter, og skriver ett
ekstraksjonsforslag som fil. Det har **ingen databasetilgang, ingen agentlegitimasjon og
ingen skrivevei**. Registreringen er som før ekstraksjonsagentens, med sin egen identitet og
sin egen rolle. Delingen er ikke kosmetikk: leddet er det eneste i kjeden som tar imot utrygt
eksternt innhold i en modellkontekst, og et ledd som gjør det, skal ikke samtidig kunne
skrive en rad (EVIDENCE_PIPELINE.md §63).

**Leverandøren er to metoder.** `ModelClient` er hvem som svarte, og én forespørsel inn, én
tekst ut. Ingen verktøy, ingen funksjonskall, ingen tilgang til Antidep. Svaret er ren tekst
med vilje: strukturerte utdata heter forskjellige ting hos hver leverandør, og et grensesnitt
som forutsatte én av formene, ville vært bundet til den ene i praksis. Kontrollen av formen
ligger derfor der den uansett måtte ligge — i `parseExtractionDraft`, som avviser alt som ikke
er kontrakten. Garantien er vår, ikke leverandørens (§62).

**Adapteret som finnes, spiller av et opptak.** Et opptak er et modellsvar lagret sammen med
fingeravtrykket av forespørselen det svarte på. Det er ikke en test-dobbel: det er
arbeidsformen i dag. `--prepare` skriver ut prompten og et tomt opptak med riktig avtrykk,
prompten kjøres der modellen faktisk kjører — utenfor Antidep — og svaret limes inn. Hele
kjeden fra kilde til publisert påstand kan dermed kjøres, om igjen og om igjen, uten kostnad.
Et leverandøradapter er **én oppføring** i `src/agents/model-adapters.ts`; kontrakten,
kjøringen, kontrollene og databasen er uendret (ANTIDEP_CONSTITUTION.md §20, §66).

**Oppslaget er på avtrykket, ikke på et navn.** Forespørselen inneholder hele
representasjonen, katalogen i oppdraget og promptmalversjonen. Et opptak nøklet på et filnavn
kunne blitt spilt av for en *annen* artikkel — altså et svar som ikke var lest ut av noe. Nå
finnes svaret ikke lenger når én av delene endrer seg, og det er riktig utfall.

**Modellen får ikke velge fritt i katalogen.** Hvilket virkestoff og hvilket endepunkt et funn
gjelder, er en faglig avgrensning, og den leveres som et *oppdrag* (`assignments/`): den
kildeversjonen som skal leses, og de identifikatorene funnet kan peke på. En modell som kunne
valgt fritt, kunne flyttet funnet til et naboendepunkt uten at noe merket det — utdragene
ville fortsatt stått ordrett i kilden, og den deterministiske kontrollen kontrollerer utdrag,
ikke avgrensning. Oppdraget lages av en kvalifisert redaktør, som har leseflaten inn i
katalogen; modell-leddet har den ikke.

**Kildeteksten er data, og gjerdet er utledet av teksten selv.** Representasjonen står mellom
to markører, og malen sier at alt mellom dem er data (§3.8). Markøren bærer de første tegnene
av representasjonens eget fingeravtrykk. Det gir to egenskaper samtidig: deterministisk, så
et opptak kan spilles av igjen, og likevel ikke skrivbar inn i artikkelen — det ville krevd
sha256 av en tekst som inneholder nettopp den markøren. Står markøren likevel der, bygges
ingen forespørsel.

**Generatoren skriver ikke noe den vet er galt.** Før forslaget blir en fil, kontrollerer
leddet sitt eget svar: at hver identifikator står i oppdraget, at hvert `source_excerpt` står
ordrett i representasjonen, og at et eventuelt `source_quote` gjør det. Dette er ikke *den*
kontrollen — den er fortsatt en separat operasjon, av en annen identitet, senere i kjeden, og
uten den kan ingen menneskelig bekreftelse registreres (migrasjon 005x). Forskjellen er hva
som skjer ved et avvik: uten kontrollen her ville et oppdiktet utdrag blitt en fil, så en rad,
så noe en kontrollør måtte avvise.

**Kontrakten er versjon 2, og den sier hvem som laget forslaget.** `generated_by` er påkrevd:
leverandør, modell, modellversjon, promptmalversjon, tidspunktet utkastet ble laget og
fingeravtrykket av forespørselen. `producer` sier om det var en modell eller et menneske som
leste artikkelen. Uten feltet måtte kjøringen oppgi en fast verdi for hvert forslag — altså
registrere et menneskes ekstraksjon som en modells, og omvendt. Pipelineversjonen står bevisst
*ikke* i filen: den er Antideps egen, og et forslag utenfra skal ikke kunne påstå noe om
hvilken pipeline som registrerte det.

**Utkastet og registreringen er to operasjoner, og proveniensen holder dem fra hverandre.**
Erklæringen føres i registreringskjøringens `input_manifest` — kolonnen for hva kjøringen fikk
inn — mens premissekolonnene på kjøringen beskriver kjøringen selv: Antideps deterministiske
registreringsvei, på det tidspunktet noen kjørte kommandoen. Lot premissene si hvilken modell
som laget utkastet, ville `started_at` vært registreringstidspunktet framfor modellkjøringens,
inn- og utdatamanifestet ville beskrevet registreringen, og forespørselen modellen faktisk
svarte på, ville ikke vært identifiserbar i det hele tatt. Det siste er nettopp det
`request_digest` finnes for: det dekker representasjonen, katalogen i oppdraget og promptmalen.
Når et leverandøradapter en dag kjører med sin egen legitimasjon, kan utkastet få sin egen rad
i `provenance.agent_runs`, ved siden av registreringen.

**Derfor tar skriveveien nå imot ekstraksjonsmetoden.** Innvendingen mot en parameter var
reell — raden skal si hvordan den ble til, og det er ikke noe en klient skal finne på — men
alternativet var ikke «ingen påstand», det var *en usann påstand*: `ai_assisted` for hvert
eneste forslag et menneske har skrevet. Vokabularet er lukket til de to verdiene denne veien
faktisk beskriver, `deterministic_import` avvises, og verdien inngår i `content_hash`. De
samme verdiene erklært av et menneske og av en modell er derfor to rader, ikke én rad som
skifter mening; append-only står.

**Kontrollflaten viser hvem som laget verdiene.** Opplysningene fantes, men bare i
`provenance.agent_runs` — ikke i det bildet mennesket og den maskinelle kontrollen arbeider
fra. En kontrollør som vet at verdiene er et maskinutkast fra en bestemt modell og en bestemt
promptmal, leser dem annerledes enn en som tror en kollega skrev dem, og motsatt
(EVIDENCE_PIPELINE.md §46). Grunnlaget bærer nå `drafted_by` — erklæringen, med sitt eget
tidspunkt og sitt eget forespørselsavtrykk — og `registered_by` — kjøringen som skrev raden.
Begge ligger på den ene projeksjonen begge flatene leser, så de aldri kan kontrollere hvert
sitt grunnlag, og hver av dem er `null` — ikke et objekt med tomme felter — i den tilstanden
fraværet faktisk betyr noe. `drafted_by` er merket som en erklæring også i UI-et: databasen
kan ikke observere hvilken modell som leste en artikkel.

**Ingen regel er myket opp.** Ingen CHECK, constraint, trigger, policy eller grant er fjernet
eller svekket, og ingen ny tabelltilgang er gitt til `anon` eller `authenticated`.
Skriveveien beholder hvert vilkår den hadde — autentisering for rollen, åpen kjøring, påkrevd
kildeversjon med registrert representasjon, komplett forankring — og har fått ett til.

**Testene.** `630` bærer de to migrasjonene: at den gamle signaturen ikke står igjen, at
parameteren er påkrevd uten standardverdi, at rettighetene er uendret, at begge metodene
registreres og gir hvert sitt fingeravtrykk, at `deterministic_import` og en ukjent verdi
avvises uten å etterlate noe, at både erklæringen og kjøringen står i grunnlaget med alle sine
felter, at utkastets tidspunkt er et annet enn registreringens, at en kjøring uten erklæring
gir `null` for utkastet men fortsatt bærer seg selv, at begge er `null` uten agentkjøring, og
at begge flatene bygges av den samme projeksjonen. Uten database prøves modellgrensesnittet,
promptmalen, opptaket, adapterregisteret, oppdraget og selve modell-leddet — inkludert at et
utkast med en katalogverdi utenfor oppdraget, et oppdiktet utdrag eller et omskrevet sitat
aldri blir et forslag, at en urørt plassholder i opptakets identitet avvises, og at klokka som
leses, er den fra da modellen svarte.

`scripts/agent-chain-test.ts` har fått et åttende ledd, og det er det sterkeste: modell-leddet
kjøres med opptaksadapteret mot den ekte databasen, forslaget går gjennom filformen og de ekte
portene til et gyldig maskinbevis, kjøringen bærer modellens egne premisser, kontrollgrunnlaget
viser dem som en erklæring med utkastets eget tidspunkt og forespørselens avtrykk, og de samme
verdiene erklært av et menneske blir en annen rad ført som `manual`. Et utkast med et oppdiktet
utdrag prøves også: det blir ikke et forslag, og ingenting i basen endrer seg av det.

**Tre rettelser etter teknisk review.** Den første er den bærende: premissene på
registreringskjøringen sa opprinnelig hvilken modell som laget utkastet, og da beskrev
`started_at`, inn- og utdatamanifestet noe annet enn det som faktisk skjedde. Erklæringen er
flyttet til manifestet og har fått sitt eget tidspunkt og forespørselens avtrykk; kjøringen
beskriver seg selv igjen. De to andre er mindre, men samme klasse: et opptak der identiteten
fortsatt står med plassholderen fra `--prepare`, avvises framfor å bli en usann proveniens, og
`--prepare` skriver ikke lenger over et opptak som bærer et modellsvar — det kan være eneste
kopi.

**Én rettelse til.** Kjedeprøven ryddet ikke `knowledge.publication_events` mellom
kjøringene, så den andre kjøringen mot den samme databasen møtte forseglingen av en revisjon
som hadde vært publisert. Den er nå med i opprydningen, og prøven kan kjøres om igjen slik
hodekommentaren alltid har sagt at den skal.

**Hva som fortsatt krever et menneske.** Alt som krevde det før. Forslaget er et forslag:
det registreres under de deterministiske kontrollene, kontrolleres maskinelt av en annen
identitet, bekreftes felt for felt av en kvalifisert redaktør, lenkes til en påstand som en
faglig vurdering, og godkjennes før publisering (ANTIDEP_CONSTITUTION.md §10, §11, §12).
Kjeden ble ikke kortere; den fikk et ledd til i forkant.

---


### 74.42 Modell-leddet er kjørbart av en Claude Code Routine

§74.41 bygget leddet som leser en artikkel og foreslår verdier. Det manglet én ting for å
kunne kjøres av noe annet enn et menneske med klippebord: en arbeidsform der aktøren som
utfører modellarbeidet, ikke må lime en prompt ut og et svar inn.

**Ingen ny leverandørkobling.** Antidep har fortsatt ingen kobling mot Anthropic, OpenAI
eller noen annen betalt modelleverandør. Modellarbeidet gjøres av en **Claude Code Routine**,
innenfor et oppsett som allerede finnes, uten en egen konto og uten en egen kostnadslinje.
Antidep definerer oppdraget, kontrakten og kontrollene; Routinen er aktøren
(EVIDENCE_PIPELINE.md §18.2, §66). Det er også grunnen til at det *ikke* er bygget et eget
agentrammeverk her: Claude Code Routines er allerede orkestreringslaget.

**Leddet er to kommandoer med en fil imellom.** Modellarbeidet gjøres av en aktør Antidep
ikke kaller, så en kommando som ventet på svaret, ville aldri returnert.
`npm run agent:draft-extraction -- --open` henter kildeversjonen, krever at fingeravtrykket
er den registrerte, bygger den versjonerte forespørselen og legger igjen en **kjøremappe**
med `prompt.txt`, en tom `svar.json` og tilstanden i `kjoring.json`. Aktøren leser prompten
og skriver svaret sitt. `--close` leser svaret og kjører det gjennom nøyaktig de samme tre
kontrollene som før — formen, katalogen, de ordrette utdragene — og skriver `forslag.json`,
eller ingenting. Kjøremappa utledes av oppdragsfilen, og filnavnene er faste: en Routine skal
ikke velge en katalog, et filnavn, et modelladapter eller en promptmalversjon.

**Svaret er én fil med en kontrakt.** `svar.json` bærer avtrykket av forespørselen den svarer
på, identiteten som faktisk svarte, tidspunktet, og utkastet — som JSON-objekt, eller som
ordrett tekst når svaret kom fra et vindu et sted. Nøyaktig én av de to. Formen på filen
bestemmer ingenting om hva som godtas: svaret går gjennom `parseExtractionDraft` og den
ordrette kontrollen uansett (§62).

**Avtrykket binder de to stegene.** Det dekker representasjonen, katalogen i oppdraget og
promptmalversjonen, og står både i kjøringen og i svaret. Et svar som svarer på en annen
forespørsel, lukkes ikke inn i denne kjøringen. Endres kilden, oppdraget eller malen mellom
stegene, gjelder ikke det gamle svaret — og kjøringen sier fra framfor å lukke et svar som
ble lest ut av en annen tekst.

**Avbrutte kjøringer er en normal tilstand, ikke et uhell.** Tilstanden ligger på disk, og
begge stegene er idempotente: `--open` på en mappe som venter, lar et svar som allerede er
lagt inn, stå; `--open` på en mappe som har et forslag, gjør ingenting; `--close` på en
lukket kjøring gjør ingenting; `--close` på en kjøring som ble avbrutt før filen ble skrevet,
lager den. En avvist kjøring kan åpnes på nytt, og sier da hva forrige svar strandet på.

**Proveniensen er aktørens egen, og kontrolleres.** Identiteten i svaret registreres som
premissene utkastet ble laget under, og en plassholder som blir stående, avvises framfor å
bli en usann proveniens. `answered_at` er da aktøren svarte — ikke da kjøringen ble lukket —
og et tidspunkt som ligger utenfor vinduet mellom åpningen og lukkingen, avvises. Vinduet har
fem minutters slakk, fordi to maskiner har to klokker og et avrundet minutt ikke er en usann
påstand.

**Rettighetsgrensen ligger i kjøremiljøet, og vakten i koden er et lag under.** En Claude Code
Routine er en full, autonom sesjon: den har skall, miljøvariablene til kjøremiljøet sitt, og
de connectorene den ble opprettet med — som er alle tilkoblede som standard — og den kan bruke
ethvert verktøy fra dem, skriveverktøy medregnet, uten godkjenning underveis. En sesjon som
både leser en artikkel Antidep ikke kontrollerer *og* har noe å skrive med, har begge deler
samtidig, nøyaktig det §63 sier at et ledd ikke skal ha. Oppsettet er derfor **to** Routines
med hvert sitt kjøremiljø: modell-leddet uten skrivekapable hemmeligheter og uten connectorer,
registrering og kontroll for seg (`ROUTINE_EXTRACTION.md` §3). Antidep bidrar med et lag
under: modell-leddet nekter å kjøre dersom en skrivekapabel legitimasjon står i miljøet til
prosessen — også `SUPABASE_ACCESS_TOKEN`, som `scripts/deploy-migrations.sh` kjører vilkårlig
SQL mot produksjon med. Vakten ser verken sesjonen som startet kjøringen eller connectorene
den har, og er derfor dokumentert som det den er.

**Ingen regel er myket opp.** Ingen migrasjon, ingen CHECK, ingen constraint, ingen policy og
ingen grant er rørt. Denne leveransen har ingen databaseendring i det hele tatt: kontrakten
mot basen er den fra §74.41, og forslaget `--close` skriver, leses av nøyaktig den samme
leseren registreringen alltid har brukt.

**`--prepare`/opptaksflyten er beholdt.** Den er den korteste veien til å se prompten uten å
kjøre en modell, og til å spille av en kjøring om igjen. Den er bare ikke nødvendig lenger:
`--close` skriver selv et opptak ved siden av forslaget, med det samme avtrykket.

**Testene.** Uten database prøves svarkonvolutten, kjøremappa, argumentlisten og vakten mot
legitimasjon i miljøet — til sammen de tilstandene en autonom kjøring kan komme i: to steg
som hver er idempotente, en kjøring avbrutt mellom dem og midt i det andre, et svar på feil
forespørsel, et oppdiktet utdrag, et omskrevet sitat, en katalogverdi utenfor oppdraget, en
form som ikke er kontrakten, en tekst som ikke er JSON, en kilde som har endret seg, et
oppdrag som er redigert, og en proveniens som ville vært usann. En egen prøve leser
**importgrafen** til hver inngang i modell-leddet og krever at ingen modul som kan skrive en
rad, og ingen tredjepartsavhengighet, er nåbar — og at den samme prøven *ser* skriveveien fra
registreringskjøreren, slik at en grønn graf ikke kan være en tom påstand.
`scripts/agent-chain-test.ts` har fått et niende ledd: Routine-grensesnittet kjørt som filer
mot den ekte databasen, der forslaget `--close` skrev, går uendret gjennom de ekte portene
til et gyldig maskinbevis, og kontrollgrunnlaget bærer identiteten aktøren erklærte i
svarfilen.

**Overleveringen kontrolleres på registreringssiden, mot redaktørens egen fil.** Et forslag som
har vært innom en økt som leste utrygt eksternt innhold, er ikke et kontrollert artefakt: økten
har skall, og filen kan endres etter at `--close` kjørte. Registreringen tar derfor imot
oppdraget som en egen, tiltrodd inndata og kontrollerer kildebindingen og hver katalogverdi mot
det før noe skrives. Avgrensningen mot katalogen er den ene kontrollen den ordrette ikke kan
gjøre — et utdrag kan stå ordrett i kilden og likevel være ført på feil virkestoff — og den
levde tidligere bare i modell-leddet, altså på feil side av overleveringen. Nøyaktig ett av
`--assignment`, `--model-proposal` og `--human-proposal` er påkrevd for hver registrering, og
valget er kallerens. En sperre som leste forslagets egen `generated_by.producer` for å avgjøre om
oppdraget trengtes, ville latt den utrygge filen bestemme om den skulle kontrolleres — en
endret `producer` fra `model` til `human`, og kontrollen var hoppet over. Valget føres i
kjøringens manifest, slik at fravær av kontroll er en handling noen gjorde.

**Modusen bærer også produsenten, og avtrykket rekonstrueres.** `producer` avgjør
`extraction_method`, som er det feltet som forteller kontrolløren om hen etterprøver et
maskinutkast eller en kollegas arbeid, og verdien inngår i evidensfunnets identitet
(migrasjon 005ab, ANTIDEP_CONSTITUTION.md §8, §12, §14). Feltet står i den utrygge filen, så
et maskinutkast kunne blitt ført som en menneskelig ekstraksjon ved at ett ord ble endret
etter `--close` — alt annet ville passert. Hver arbeidsform bærer derfor sin produsent, og
forslagets erklæring må stemme med den; et avvik avvises før kjøringen åpnes. Arbeidsformen er
**påkrevd**, og det er poenget: så lenge den var valgfri, var invarianten valgfri, og
re-ekstraksjonen av eldre forslag utelot den — altså en åpen vei rundt kontrollen gjennom den
andre registreringskommandoen. De tre arbeidsformene er den oppdragsbaserte modellflyten, et
maskinutkast uten oppdrag, og en redaktørs eget arbeid; to av tre er en modells, fordi den ene
tilstanden som ikke skal kunne oppstå av en endret fil, er at et maskinutkast føres som et
menneskes arbeid. Arbeidsformen gjelder **hele** køen i re-ekstraksjonen, så den prøves mot
hvert forslag før den første registreringen: en blandet katalog avvises samlet, framfor å
skrive de forslagene som stemte og stanse på det første som ikke gjorde det. Av resten av
`generated_by` er `request_digest` den ene verdien som er etterprøvbar: forespørselen er en ren
funksjon av oppdraget, representasjonen og promptmalen, og registreringen har alle tre. Den
rekonstrueres derfor framfor å kopieres, og et avvik gir ingen rad. Lar den seg ikke
rekonstruere — uten oppdrag, uten forespørsel, eller under en eldre promptmal — fører kjøringen
`request_digest_checked` som usann, framfor å kalle en påstand et bevis.

**Deployveien er stengt der den fantes.** `.github/workflows/vercel.yml` kjørte på alle
`pull_request` med `VERCEL_TOKEN` i jobbens miljø og bygde koden fra PR-branchen; en pull
request fra en branch i samme repo får repository-secrets. En Routine pusher `claude/`-brancher
som alltid aksepteres, og det finnes ingen tilgangsmodus som slår det av under en kjøring — så
et krav om «ikke push» ville vært en regel uten håndhevelse. Arbeidsflyten kjører nå bare på
`main`. Forhåndsvisninger lages av Vercels egen Git-integrasjon, som allerede gjorde det;
arbeidsflyten laget en andre deploy av det samme, uten branch-alias.

**Hva som ikke er etablert, og som ble tydeligere under review.** To Routine-kjøringer deler
ikke filsystem: hver kjøring er en ny økt med en fersk klone av repoet, og grensesnittet i
modell-leddet er lokale, gitignorerte filer. Oppdraget leveres derfor i Routinens egen prompt,
og forslaget hentes ut av den økten som laget det; registreringen er en bevisst operasjon et
menneske setter i gang. En transportkanal mellom to kjøringer finnes ikke, og skal velges
bevisst når den trengs — ikke ved å commite kliniske arbeidsfiler eller ved å kjøre begge
leddene i én skrivekapabel økt. Det står i `ROUTINE_EXTRACTION.md` §3.5, og krever en beslutning framfor mer kode.

**Hva som gjenstår, og som ikke skal automatiseres bort.** Den første *reelle* ekstraksjonen
fra en faktisk vitenskapelig artikkel er ikke gjort. Den skal gjøres av ChatGPT sammen med
Peder, som validering av prompten, kontrakten og hele arbeidsflyten, før tilsvarende arbeid
overlates til en Routine. Maskineriet er prøvd mot en ekte adresse over nett — henting,
fingeravtrykk, gjerdet rundt kildeteksten, den ordrette kontrollen og filskrivingen — men det
er en prøve av mekanikken, ikke av det faglige.

### 74.43 Fulltekst er bundet til originaldokumentet, og oppdraget bygges av databasen

§74.42 gjorde modell-leddet kjørbart av en Routine. Det som fortsatt manglet, var
**noe å lese**: hver kildeversjon Antidep hadde, var et sammendrag hentet fra en adresse, og
begge de seedede evidensfunnene står med verdier sammendraget ikke oppgir (migrasjon 003).
En fulltekstartikkel er en PDF en redaktør har lovlig tilgang til lokalt — den ligger ikke på
en åpen adresse, den er ikke tekst, og Antidep har ikke rett til å redistribuere den
(EVIDENCE_PIPELINE.md §14).

**Dokumentet får et fingeravtrykk, og databasen eier det.**
`api.create_source_version_from_document(...)` tar imot **bytene**, ikke hashen: databasen
beregner sha256 og størrelsen, og leser mediatypen av dokumentets egen signatur. Ingen av de
tre er noe kalleren oppgir, av nøyaktig samme grunn som `content_hash` ikke er det (§74.32).
Dokumentet **lagres ikke** — bytene forsvinner med transaksjonen, og det som blir stående, er
fingeravtrykket.

**Oppskriften er den andre halvdelen.** Tekstuttrekking er ikke én operasjon: to verktøy gir
to forskjellige tekster av den samme PDF-en. Raden bærer derfor verktøyet, versjonen og
argumentene ordrett. Kontrakten utad blir en kommando: *kjør denne på dokumentet med dette
fingeravtrykket, og sha256 av resultatet skal være `content_hash`.* Den krever ingen
kjennskap til Antidep, og den er den samme kontrollen kjeden selv gjør ved hvert eneste ledd.

**Og oppskriften er en lukket liste.** Den er den ene lagrede verdien i Antidep som senere
blir en **prosess**: hver ekstraksjon og hver maskinelle kontroll henter teksten ut på nytt
med verktøyet og argumentene som står i raden. Var feltet fritt, kunne en redaktør skrevet
`sh` i det, og en verdi lest ut av basen ville blitt en kommando kjørt med rettighetene og
miljøet til den som kontrollerer — kodekjøring ut av en skriverettighet, og et brudd på
regelen om at lagret innhold aldri blir instruksjoner (EVIDENCE_PIPELINE.md §3.8). Antidep
støtter i dag nøyaktig én oppskrift, og migrasjon 003f skriver den ned som nøyaktig én:
`pdftotext` med `-layout -enc UTF-8 -eol unix`, håndhevet av en CHECK på tabellen og av en
lesbar avvisning i inngangspunktet. Kjørerne kontrollerer den samme listen på nytt
umiddelbart før de starter en prosess. Det er ikke det samme stedet to ganger: den ene
grensen stenger for at verdien blir lagret, den andre for at en verdi som likevel er lagret,
blir kjørt. Versjonen av verktøyet er med vilje fri — den er en opplysning som forklarer et
avvik, ikke noe som kjøres, og fasiten er uansett fingeravtrykket av teksten.

**De to veiene kan ikke bytte plass.** En dokumentbundet kildeversjon hentes **aldri** over
nett, og en tekstversjon hentes aldri fra et dokument (`src/agents/source-binding.ts`). Det
er ikke ryddighet, men selve invarianten: kunne en fulltekstversjon tilfredsstilles av det
som lå på `retrieved_from`, ville sammendraget fra PubMed kunnet bli kontrollgrunnlaget for
en ekstraksjon registrert som fulltekst. Mangler dokumentet, **stopper** leddet; det henter
ikke adressen i stedet.

**En PDF kommer ikke gjennom tekstveien lenger.** `api.create_source_version(...)`,
registreringsskjemaet og hentingen over nett avviser alle tre innhold som begynner med
PDF-signaturen, med en setning som sier hvilken vei som gjelder. Det er den ene feilen
dokumentveien gjør *lettere* å gjøre — en PDF hashet som tekst gir et fingeravtrykk ingen kan
reprodusere med `sha256sum` på filen — og derfor den ene som er stengt eksplisitt.
Registreringsskjemaet krever samtidig at representasjonstypen velges: kolonnen har vært
nullbar siden 003b, og en versjon uten den kan ikke bære en agentekstraksjon.

**Oppdraget skrives ikke lenger for hånd.** `api.build_extraction_assignment(...)` bygger hele
ekstraksjonsoppdraget av databasens egne rader, av kanoniske navn — «sertralin»,
«vektendring», «voksne med depressiv lidelse» — og `npm run editor:assignment` er de to
stegene i ett: registrer fullteksten av PDF-en, og skriv oppdraget. Ingen uuid, ingen hash og
ingen kildebinding settes sammen for hånd.

Det er ikke bare bekvemmelighet. Oppdraget er en **tiltrodd** inndata: registreringen
kontrollerer forslaget mot det (§74.42), så oppdraget er halvparten av kontrollen. Et oppdrag
satt sammen av kopierte verdier er en kontroll mot en kopi — og en kildebinding med adressen
fra én rad og fingeravtrykket fra en annen ville sendt hele kjeden til feil tekst uten at noe
merket det. Modell-leddet får fortsatt bare filen: funksjonen krever `editor`-rollen, som
modell-leddet ikke har og ikke skal ha.

**Registreringen kontrollerer oppdraget før den henter noe.** Rekkefølgen var motsatt, og det
ga riktig utfall av feil grunn: et forslag som pekte på et annet dokument, ble avvist med
«fant ingen fil» framfor med avviket mot redaktørens egen oppdragsfil. Kildebindingen i et
forslag avgjør *hvor* teksten skaffes fra, og forslaget er utrygg inndata.

**Prøvene.** Uten database prøves bindingens form, fingeravtrykket av bytene, oppslaget på
fingeravtrykk framfor filnavn, en oppskrift som gir en annen tekst, en fil som ikke er en PDF,
og at et ledd uten dokumentet aldri henter adressen i stedet. En egen fil prøver den lukkede
oppskriften der den blir en prosess: et verktøy eller argumenter utenfor listen gir en
avvisning **uten at verktøyet i det hele tatt blir kalt**, også når verdien kommer fra en rad
kjeden allerede har fått — og den samme filen krever at koden og migrasjonen staver listen
likt. pgTAP prøver at databasen eier begge fingeravtrykkene, at dokumentbindingen er
alt-eller-ingenting og uforanderlig, at det samme innholdet ikke kan registreres på nytt under
en annen representasjonstype, at oppskriften avvises både av inngangspunktet og av CHECK-en
mens versjonen forblir fri, og at et ukjent katalognavn gir en avvisning framfor et oppdrag
med én avgrensning mindre.
`scripts/agent-chain-test.ts` har fått et tiende ledd: en syntetisk, men ekte PDF går gjennom
skriveveien, oppdragsbyggeren, modell-leddet, registreringen og den maskinelle kontrollen —
hvert ledd med teksten hentet ut av dokumentet på nytt med `pdftotext` — til et gyldig
maskinbevis, med feiltilfellene i den samme kjeden.

**Hva som gjenstår, og hvorfor det ikke kunne gjøres her.** De to reelle ekstraksjonene —
Fava 2000 × sertralin og Versiani 2005 × mirtazapin, begge × vektendring × voksne med
depressiv lidelse — er **ikke** registrert. Grunnen er ikke faglig og ikke teknisk: begge
artiklene er bak betalingsmur (kontrollert mot PMC og OpenAlex; ingen av dem har en åpen
fulltekst), og de lovlige PDF-ene finnes bare som lokale arbeidsfiler hos redaktøren. Ingen
sesjon som ikke har filene, kan produsere de ordrette utdragene kjeden krever — og et utdrag
som ikke står i teksten, er nettopp det hele kjeden er bygget for å avvise
(ANTIDEP_CONSTITUTION.md §4, §11).

Med PDF-ene på plass er hvert av de to funnene to kommandoer, og ingen av dem krever at noen
finner en uuid:

```bash
npm run editor:assignment -- \
  --source "Fava" --pdf <fava-2000.pdf> \
  --retrieved-from "https://doi.org/10.4088/jcp.v61n1109" \
  --drug sertralin --outcome vektendring --population "voksne med depressiv lidelse"

npm run editor:assignment -- \
  --source "Versiani" --pdf <versiani-2005.pdf> \
  --retrieved-from "https://doi.org/10.2165/00023210-200519020-00004" \
  --drug mirtazapin --outcome vektendring --population "voksne med depressiv lidelse"
```

Deretter den uendrede kjeden per oppdrag: `agent:draft-extraction --open`, aktørens svar,
`--close`, `agent:extract-evidence --assignment`, `agent:verify-extraction`, og den
menneskelige kontrollen felt for felt.

Fullteksten er en **ny** kildeversjon ved siden av sammendraget, ikke en erstatning: det
gamle funnet står urørt med sin egen representasjonstype, og et evidensfunn lest av
fullteksten er en egen rad. Verdiene fulltekstresearchen har etablert — sertralin +1,0 % over
26–32 uker med n = 48, mirtazapin +0,8 kg med SD 2,7 kg over 8 uker — er begge **innen-arm**
gjennomsnittsendringer, og skal derfor registreres med `effect_measure = mean_change` og
`comparator_kind = none`: studienes aktive komparatorer gjør dem ikke til
mellom-gruppeestimater, og 2,7 kg er et standardavvik og ikke et konfidensintervall.

### 74.44 Kildekontrollen skal kunne gjennomføres uten artikkelen ved siden av

§74.43 gjorde det mulig å ekstrahere fra en fulltekst-PDF. Den første **reelle
menneskelige kildekontrollen** — Fava 2000 × sertralin × vektendring — ble
gjennomført på den flaten, og den avdekket at hovedmålet ikke var nådd:
kontrolløren måtte lese artikkelen ved siden av for å avgjøre delpunktene.

**Den avgjørende observasjonen var at dokumentasjonen allerede sa det riktige.**
Både promptmalen og ekstraksjonsferdigheten krevde at hvert `source_excerpt`
skulle inneholde hele setningen verdien står i. Likevel ble dette registrert i
produksjon:

```text
tine (N = 92), sertraline, (N = 96), or paroxetine
```

Utdraget står ordrett i artikkelen, og hvert deterministisk ledd i kjeden sa ja.
Det begynner inne i «fluoxetine». Lærdommen er at en regel som bare står i en
modellprompt, er en regel uten håndhevelse — og at en omskrevet prompt derfor
ikke ville vært et svar.

**Det som kan håndheves robust, håndheves nå.** `src/agents/source-excerpt.ts`
er den ene definisjonen av hva et kontrollerbart utdrag er, og den håndhever to
regler som ikke kan ta feil på en PDF: utdraget må stå i representasjonen som
**hele ord** — kontrollen leser tegnet rett foran og rett bak treffet, og tolker
ikke språk i det hele tatt — og det må inneholde **minst én setningsgrense**, med
desimaltegn unntatt. Begge kjøres av modell-leddets egen aktsomhet og av
registreringen, som er den siste grensen inn i basen. Ingen setningsparser:
linjeskift, orddeling, kolonner, fotnotemerker og forkortelser er hverdagen i
`pdftotext`-utdata, og et ledd som avviser riktige ekstraksjoner, blir slått av.
Den kjente kostnaden er dokumentert: en verdi som bare står i en tabellrad uten
tegnsetting, må forankres av teksten som sier hva raden er.

**Resten står svært eksplisitt i den versjonerte malen**, med nøyaktig det
feilende utdraget som eksempel på hva som ikke godtas. Promptversjonen er
`evidence-extraction/proposal-drafting/2`: den samme kilden forventes nå å gi et
annet forslag, og da er malen en ny versjon (§20).

**`sample_size` betyr noe annet enn flaten sa.** Kolonnekommentaren har hele
tiden sagt «antallet analysen faktisk omfatter, ikke antallet randomisert», men
kontrollflaten skrev «Studien inkluderte 48 deltakere» — som er feil om Fava
2000, der 284 ble randomisert og 96 fikk sertralin. Flaten sier nå «Dette
estimatet bygger på 48 deltakere», og malen sier at et tall som ikke uttrykkelig
er knyttet til estimatet, ikke skal føres.

**Kontrollflaten er bygget om rundt ett krav**, skrevet ned som produktkrav i
PRODUCT_INFORMATION_ARCHITECTURE.md §63.1 og EVIDENCE_PIPELINE.md §19.1:
kontrolløren skal få nok lokal kildekontekst til å vurdere hvert utsagn uten å
lete i fullteksten selv. Konkret:

- En **innledning** før veiviseren sier hva som skal kontrolleres — virkestoff,
  endepunkt og populasjon — og hvilken kilde det gjelder, med hele tittelen som
  lenke. Den bygges av den kanoniske raden, aldri av generert tekst.
- **Kildetilgangssteget** er strippet for identifikatorverdi, representasjonstype
  og gjentatt tittel. Begge de to første er flyttet til «Tekniske detaljer», der
  de ikke var før.
- **Tolkning og mangel er skilt, og spørsmålet følger premisset.**
  `FieldInterpretation.kind` har tre verdier. `interpretation` heter «Antideps
  tolkning» og spør «stemmer dette med teksten?». `absence` — ingen verdi, men en
  registrert grunn — heter «Hvorfor verdien mangler» og spør «stemmer denne
  begrunnelsen?». `unrecorded` — ingen verdi og ingen fraværskolonne, altså
  effektmål, forbehold og den rå gjengivelsen — heter «Ingenting er ført» og spør
  om det er riktig at ingenting er ført.

  Skillet kom av den tekniske reviewen, og det er et integritetskrav og ikke en
  nyanse: `not_extractable` betyr «står i kilden, men lar seg ikke lese entydig
  ut», og et felles spørsmål av typen «stemmer det at kilden ikke oppgir dette?»
  ville bedt kontrolløren bekrefte det motsatte av det som er ført — og svaret
  ville blitt registrert som om det gjaldt riktig spørsmål.

  En fjerde art, `absence_in_source`, kom av de neste rundene i den samme
  reviewen, og den koster mer enn en etikett. `not_reported` og `not_measured`
  er påstander om kilden eller studien **som helhet**, og et forbehold ved siden
  av et globalt ja/nei-spørsmål endrer ikke sannhetsbetingelsen: kontrolløren
  måtte fortsatt svart «kan ikke avgjøres» eller gått til fullteksten.

  To ting er gjort. Ekstraksjonen skal forankre et slikt fravær i passasjen der
  verdien *ville stått* — der funnets øvrige verdier for samme arm, endepunkt og
  tidspunkt rapporteres (EVIDENCE_PIPELINE.md §19.1) — og flaten snevrer
  spørsmålet inn til den: «mangler opplysningen der utdraget viser at den ville
  stått?». Da er økten gjennomførbar uten at kontrolløren må lete i artikkelen.

  Men et bekreftet lokalt fravær **er ikke** den globale påstanden raden bærer,
  og registreringen fører det derfor ikke opp som det. Feltet utelates fra
  `checked_fields`, begrunnelsen sier hvorfor, og kontrolløren får vite det i
  det hen lagrer. Feltet står udekket i publiseringsgatens union til det finnes
  et kontrollledd som kan bære en global fraværspåstand. Alternativet ville vært
  at auditraden og gaten sa at et menneske hadde gått god for den globale
  semantikken på grunnlag av én valgt passasje — nøyaktig den overdrivelsen
  DATABASE_ARCHITECTURE.md §29 forbyr.

  Prisen er reell og står som registrert gjeld i §74.7: Fava 2000 fører
  konfidensintervallet som ikke rapportert, og det feltet blir dermed ikke
  dekket. Hva Antidep skal kreve før et fravær kan regnes som kontrollert, er en
  klinisk og redaksjonell beslutning, og den er ikke tatt her.

  Bokføringssetningen «Antidep har ført 1 felt uten verdi, med en begrunnelse for
  hvert» er borte. En mangel blir aldri en klinisk påstand utledet av fraværet:
  et manglende konfidensintervall betyr ikke at effekten var uten statistisk
  signifikans.
- **Endepunkt og effektmål er gjort forskjellige.** «Det målte endepunktet er
  vektendring» mot «Resultatet er uttrykt som gjennomsnittlig endring, oppgitt i
  %», under overskriften «Hvordan resultatet er uttrykt».
- **Varighet vises som kilden oppgir den.** Er databasens dager hele uker, står
  uker som hovedform og den lagrede verdien navngitt ved siden av: «26 til 32
  uker (registrert som 182 til 224 dager)». Den kanoniske varigheten er uendret, og begge tallene står.

**Prøvene.** Regresjonsprøvene er skrevet av de utdragene som faktisk slapp
gjennom, ikke av fantasi: fragmentet fra Fava 2000 avvises av formkontrollen,
det samme fragmentet avvises av ordgrensekontrollen mot en representasjon med
linjeskift og orddeling i, og både modell-leddet og registreringen avviser et
utdrag som står ordrett men begynner midt i et ord. På flatesiden prøves
innledningen, at støyen i kildetilgangssteget er borte mens proveniensen er
bevart under tekniske detaljer, at et langt utdrag vises i sin helhet, at
`sample_size` ikke beskrives som studiens inklusjon, at 26–32 uker vises sammen
med 182–224 dager, at en manglende verdi presenteres som mangel med sitt eget
spørsmål, og at endepunkt og effektmål sier hver sin ting. Den eksisterende
stale-step-/resume-logikken og publiseringsgaten er uendret og prøves som før;
påstandsøkten, som ikke har en innledning foran seg, navngir fortsatt kilden i
kildetilgangssteget.

**Hva som gjenstår.** De to reelle re-ekstraksjonene er **ikke** kjørt. Fava 2000
og Versiani 2005 er begge registrert som fulltekst-kildeversjoner fra før, og
skal re-ekstraheres med den nye promptversjonen etter at denne endringen er
reviewet og merget — nye evidensfunn ved siden av de gamle, ikke i stedet for
dem. For Versiani 2005 er n = 117 særskilt: forrige kjøring førte tallet fordi
117 mirtazapinpasienter hadde en vektmåling på dag 56, men artikkelen oppgir
etter det vi har sett ikke uttrykkelig at `+0,8 ± 2,7 kg` er beregnet over dem.
Uten en eksplisitt kildepassasje som knytter nevneren til estimatet, skal
`sample_size` være `null` med riktig availability-status og ordrett grounding som
viser hvorfor.

---

### 74.45 Et globalt fravær har fått et kontrollledd som kan bære det

§74.44 lot én ting stå åpen, og den var den dyreste: `not_reported` («ikke
rapportert i kilden») og `not_measured` («ikke målt i studien») er påstander om
kildeversjonen **som helhet**, og ingen av Antideps to kontrollgrunnlag kunne
bære dem. Kontrolløren ser ett lokalt utdrag, og et utdrag viser hva som står
ett sted — ikke hva som ikke står noe sted. Feltet ble derfor bevisst ikke ført
opp som kontrollert, og publiseringsgatens G5b ble stående åpen uten at noe
navnga hva som manglet (issue [#74](https://github.com/peohol/antidep/issues/74)).

**Påstanden er delt i de to halvdelene som faktisk har hvert sitt
kontrollgrunnlag**, og hver halvdel har fått sitt eget felt i
`workflow.evidence_check_field`:

| Halvdel | Spørsmål | Grunnlag | Hvem | Felt |
|---|---|---|---|---|
| Lokal | Mangler opplysningen der forankringsutdraget viser at den ville stått, og er grunnen av riktig art? | Utdraget flaten viser | Et menneske | `availability_semantics` |
| Kildeomfattende | Står opplysningen noe annet sted i kildeversjonen? | Hele den registrerte representasjonen | To maskinelle ledd | `source_wide_absence` |

`workflow.required_check_fields(uuid)` krever den andre når og bare når raden
fører minst ett slikt fravær (`workflow.source_wide_absence_fields(uuid)`, som
er den ene definisjonen gaten, kontrollleddet og kontrollflaten alle leser).
**Gaten er dermed strengere enn før, ikke løsere:** hullet var der hele tiden,
men det var navnløst og så ut som et udekket `availability_semantics`.

**Den kildeomfattende halvdelen har selv to ledd, og bare det ene kan
konkludere.** Første utgave av leveransen lot den deterministiske
ekstraksjonskontrollen dekke halvdelen alene: fant mønstersøket ingen verdi, var
fraværet kontrollert. Teknisk review felte den, og eksempelet tar tretti
sekunder å konstruere — mønstrene kjente `CI`, `C.I.` og `confidence
interval(s)`, men ikke `CIs` og ikke `confidence limits`, så «The 95% CIs were
0.4 to 2.6.» ga null treff og ville blitt bokført som «ingen konfidensintervall i
kildeversjonen».

Å legge til de to formene løser ikke feilklassen. Naturlig språk har ingen
uttømmende mønsterliste, og `not_measured` gjør det tydeligere: en kilde kan si
at vekt ble *målt* uten å oppgi et eneste tall, og et rent verdisøk ville da
godkjent «ikke målt» på en variabel studien målte. **Et fravær kan ikke bevises
av et søk** — det er premisset i issue #74, og det står nå i koden:

| Ledd | Hva det kan | Rolle |
|---|---|---|
| Det deterministiske søket | **Falsifisere.** Et treff blokkerer dekningen alene | Forutsetning |
| Gjennomlesningen (`src/agents/absence-review.ts`) | **Konkludere.** Leser hele den reproduserte representasjonen og svarer `absent`, `present` eller `uncertain` per felt | Det eneste som dekker |

Feltet føres opp bare når representasjonen lot seg reprodusere, søket fant
ingenting, **og** gjennomlesningen svarte `absent` på hvert felt. Et søketreff
kan ikke overstyres av en gjennomlesning som mener noe annet.

**De to fraværsgrunnene er heller ikke det samme spørsmålet.** `not_reported` er
en påstand om kildeversjonen; `not_measured` betyr «kilden opplyser at størrelsen
ikke ble målt», og er dermed en påstand om at noe **står** i kilden. Statusen
følger feltet helt fram til spørsmålet og inngår i forespørselens avtrykk, og et
`absent` på `not_measured` må vise til stedet som sier det — ordrett, prøvd mot
representasjonen. Tier teksten om målingen, er svaret `uncertain`. «Ingen evidens
for at det ble målt» er ikke «evidens for at det ikke ble målt», og et ledd som
blandet dem, ville gjort taushet til en påstand om studien.

**Gjennomlesningen har ingen legitimasjon, og det er hele formen på den.**
Verifikatoren legger igjen spørsmålet som filer
(`--absence-prompts <katalog>`), en aktør Antidep ikke kaller svarer i
`svar.json`, og neste kjøring leser svaret (`--absence-reviews <katalog>`).
Bindingen er avtrykket av forespørselen, som dekker promptmalversjonen, feltene
det spørres om og hele representasjonsteksten: et svar avgitt på en annen
artikkel, en annen utgave eller et annet spørsmål legges bort. Samme form og
samme grunn som ekstraksjonsutkastet (EVIDENCE_PIPELINE.md §63). Det var også
det avgjørende valget mot alternativ 2 i issue #74: en menneskelig global
bekreftelse ville gjort Peder til manuell fulltekstleser for hvert eneste felt
uten verdi.

**Søket er bevisst bredere enn kontrollens øvrige søk.** Resten av modulen
binder en verdi til raden med en limkjede, fordi den skal *tilskrive* verdien
denne raden. Her er retningen motsatt: søket skal finne noe, og et treff
blokkerer. Søket har derfor **ingen binding til raden**, fri avstand mellom
anker og verdi, teller tall skrevet med bokstaver, og har en videre ankerliste
for konfidensintervall enn bekreftelsessøket.

To smalere utforminger ble forkastet i teknisk review av denne leveransen, og
begge er nå regresjonsprøver. Et krav om at verdien sto i en passasje som selv
navngir behandlingsarmen, kastet andre setning i «Sertraline patients improved.
The 95% CI was 0.4 to 2.6.» Et sifferbasert mønster ga ingen treff på
«Forty-eight sertraline-treated patients completed the trial» — en setning som
står i denne kodebasens egen PDF-fikstur.

**Rekkevidden er kildeversjonen, ikke publikasjonen, og det er ikke en
innskrenkning.** Det er nøyaktig det statusen selv gjelder — kolonnekommentaren
på `*_availability` har hele tiden sagt «den kildeversjonen og den
kildepekeren raden viser til, ikke nødvendigvis hele publikasjonen». Styrken
følger likevel av hva versjonen er, så kontrollraden navngir representasjonen
den gjennomsøkte: et søk gjennom et abstrakt skal ikke leses som et søk gjennom
en fulltekst.

**Én hard grense: representasjonen må ha latt seg reprodusere.** Et **treff** er
ikke et avvik: ingen av leddene vet om verdien gjelder denne armen og dette
endepunktet, så utfallet er `uncertain`, feltet føres ikke opp, og begrunnelsen
siterer hva som ble funnet. Et udekket fravær avgjør utfallet og står ikke bare
som en merknad — også det et reviewfunn. Et felt uten maskinelt søkbar form —
populasjonen er en etikett og ikke et tall — stanser ingenting: søket er
falsifikasjonsleddet, og et ledd som ikke kan prøve, har heller ikke funnet noe.
Gjennomlesningen avgjør da alene, og begrunnelsen sier eksplisitt at
konklusjonen hviler på ett ledd (issue #79).

**Mennesket kan ikke ta halvdelen på seg, og det er håndhevet framfor frarådet.**
`workflow.semantic_check_fields(uuid)` utelater feltet, så kontrolløkten stiller
aldri spørsmålet, og `evidence_verifications_source_wide_absence_check` avviser
enhver rad uten agentkjøring som fører det opp. Et framtidig menneskelig
kontrollobjekt for globalt fravær er mulig, men er da et eget objekt med sin
egen dekning — ikke en oppmyking av denne regelen.

**Kontrollflaten sier hvem som tar hva.** Feltsteget for et slikt fravær sier at
det bare er stedet som skal avgjøres, og at resten søkes etter maskinelt — «det
er ikke din oppgave». Lagringssteget sier om søket allerede har gått god for
funnet, eller om gaten fortsatt står åpen på det. Kontrolløren skal aldri
oppdage et udekket felt som en blokkert publisering senere
(PRODUCT_INFORMATION_ARCHITECTURE.md §63.1).

**Prøvene.** `660_source_wide_absence_test.sql` prøver at settet er utledet av
raden og bare av de to globale grunnene, at gaten krever feltet når og bare når
raden gjør påstanden, at kontrolløkten aldri får et steg for det, at
forankringskravet ikke gjelder det, og at det avvises både uten agentkjøring og
med bare et avledet sammendrag som grunnlag. `570` viser det i hele kjeden, med
et menneske som forsøker å bære påstanden og blir avvist. Kjedeprøven
(`npm run db:test:chain`) prøver det samme mot den ekte databasen gjennom de
ekte skriveveiene, nå i begge trinn: kjøringen legger igjen spørsmålet, en aktør
uten legitimasjon svarer i filen, og neste kjøring registrerer dekningen med en
begrunnelse som navngir hvem som leste.

På JavaScript-siden er begge leddene prøvd felt for felt. Reviewfunnets egen
falske negativ er en regresjonsprøve i to former — «The 95% CIs were 0.4 to
2.6.» og «confidence limits 0.4 and 2.6» — og den prøver tre ting samtidig: at
en gyldig, ukjent formulering aldri blir `checked` av seg selv, at en
gjennomlesning som ser verdien blokkerer, og at søket nå kjenner nettopp disse
formene. Videre er prøvd: et søketreff som ikke blir et avvik og som ikke kan
overstyres, et udekket fravær som avgjør utfallet, en representasjon uten
reprodusert fingeravtrykk, en verdi som står i setningen etter den som navngir
armen, tall skrevet med bokstaver, et svar avgitt på en annen tekst, et svar som
gjelder et annet funn, og et svar som ikke har kontraktens form.

**To fiksturer sa noe annet enn raden, og kontrollen fant det.** Kjedeprøvens
sammendrag sa «randomised for 8 weeks» mens funnet førte tidspunktet som ikke
rapportert, og funnet førte populasjonen som ikke rapportert uten at noe kunne
kontrollere det. Begge er rettet i fiksturen framfor å bli dempet i kontrollen.

#### Hva som står i produksjon

Den kildeomfattende fraværskontrollen er **kjørt mot produksjon for begge
funnene**, i den totrinnsflyten §74.45 beskriver, fra en sesjon som hadde
originaldokumentene. Det som gjensto, var bare det: dokumentene.

##### 1. Dokumentene stemmer, og representasjonen lot seg lage om igjen

Begge PDF-ene ble lagt i `documents/` (gitignorert, aldri commitet) og prøvd mot
det basen har registrert — ikke mot en antakelse:

| Funn | `document_sha256` | Byte | `content_hash` reprodusert |
|---|---|---|---|
| `9ba56fb4` | `sha256:0f5ac781…eed56` | 55 291 | ja — `sha256:bc7e12d3…1fb19` |
| `9570760c` | `sha256:be804f4e…1bbf508` | 139 515 | ja — `sha256:0999b91c…92e7a` |

Kontrollen er den som står i `documents/README.md`: `sha256sum` på filen, og
`pdftotext -layout -enc UTF-8 -eol unix` etterfulgt av `sha256sum` på teksten.
Begge ga nøyaktig de registrerte verdiene. Verktøyet måtte installeres i miljøet
(poppler 24.02.0, som er den registrerte versjonen), og uten det kan en
dokumentbundet kildeversjon hverken registreres eller kontrolleres.

##### 2. Rollene var delt, og gjennomlesningen hadde ingen vei til basen

Første trinn la igjen spørsmålet i en kjøremappe **utenfor arbeidstreet**.
Gjennomlesningen ble gjort av et eget ledd uten Antidep-legitimasjon, som bare
fikk mappa å lese og skrive i. Verifikatorens legitimasjon ble flyttet ut av
repoet mens leddet leste, slik at en instruksjon i fullteksten ikke kunne bli en
skrivevei: et ledd som leser utrygt innhold, skal ikke samtidig ha en (§63 i
`EVIDENCE_PIPELINE.md`). Deretter registrerte verifikatoren svaret under sin egen
identitet.

##### 3. Det ene fraværet er dekket, det andre står åpent med en grunn

| Funn | Felt | Søket | Gjennomlesningen | `source_wide_absence` |
|---|---|---|---|---|
| `9ba56fb4` | `confidence_interval` | ingen treff | `absent` | **dekket** |
| `9570760c` | `sample_size` | treff | `present`, med ordrett utdrag | ikke dekket |
| `9570760c` | `confidence_interval` | ingen treff | `uncertain` | ikke dekket |

Begge utfallene er de riktige, og ingen av dem er justert for å gi en grønnere
rad. For `9570760c` blokkerer søketreffet dekningen alene, og gjennomlesningen
fant i tillegg et faktisk antall i kilden («12 of 117 … at day 56») som den
forklarer er nevneren i den dikotome analysen, ikke i gjennomsnittsendringen. Det
er nøyaktig den opplysningen et menneske skal se på, og den står nå i
kontrollradens begrunnelse.

Gjeldende maskinkontroll, lest av basen etter kjøringen:

| | `9ba56fb4` | `9570760c` |
|---|---|---|
| Gjeldende verifikasjon | `902c2dc1…` | `9c5161d6…` |
| Utfall | `uncertain` | `uncertain` |
| `source_access` | `verifiable_representation` | samme |
| Kildeversjon brukt | `1287e69b…` | `d3c27d3d…` |
| Begrunnelsen navngir dokumentet og oppskriften | ja | ja |
| `source_wide_absence` i `checked_fields` | ja | nei |
| Proveniens for gjennomlesningen i `output_manifest` | ja, `covered: true` | ja, `covered: false` |

Begrunnelsene i produksjon sier nå at representasjonen ble **trukket ut av
originaldokumentet** med den registrerte oppskriften, og ikke hentet fra DOI-en.
Det var rettelsen §74.45 gjorde i koden; de gamle radene står fortsatt ved siden
av, som append-only krever.

##### 4. Ingen gate er åpnet på et svakere grunnlag

Udekkede gatefelter, regnet av gatens egne funksjoner:

| Funn | Udekket |
|---|---|
| `9ba56fb4` | `availability_semantics`, `effect_measure`, `estimate`, `outcome`, `population`, `reported_direction`, `sample_size`, `timepoint` |
| `9570760c` | de samme minus `sample_size`, pluss `source_wide_absence` |

Alt som står igjen for `9ba56fb4`, er nøyaktig de feltene mennesket skal svare
på. For `9570760c` står i tillegg `source_wide_absence` åpent, med grunnen i
begrunnelsen. Ingen menneskelig kontroll er registrert på noen av dem, og ingen
påstandsrevisjon er lenket til dem: publisering forutsetter både den
menneskelige kontrollen og en redaksjonell beslutning som ikke er tatt.

##### 5. Den menneskelige kildekontrollen kan begynne i UI-et

Kontrollert mot **produksjonsnyttelasten** fra `api.extraction_review_workspace`,
lest som reviewer og kjørt gjennom repoets egen parser:

| Egenskap | `9ba56fb4` | `9570760c` |
|---|---|---|
| Står i reviewerens kø | ja | ja |
| Nyttelasten parses av repoets egen parser | ja | ja |
| Semantiske felter uten forankring | ingen | ingen |
| Maskinbevis på forankringen | ja | ja |
| `source_wide_absence` blant spørsmålene økten stiller | nei | nei |
| Lenkede påstandsrevisjoner | 0 | 0 |

Kontrolløren blir altså aldri spurt om den kildeomfattende halvdelen, og hvert
felt hen skal svare på, har et ordrett utdrag ved siden av seg. Ingen tekniske
mellomsteg gjenstår: `/extraction-review` viser begge funnene, og økten kan
gjennomføres derfra.

##### Legitimasjonen: en ny ble utstedt, og ingenting fungerende ble ødelagt

Verifikatoren trengte legitimasjon, og en hemmelighet kan ikke leses ut igjen.
Før utstedelsen ble det avlest at `secret_version` allerede sto på 8, utstedt av
en tidligere agentsesjon hvis miljøfil er borte, og at
`extraction-verification.yml` sist kjørte grønt rundt PR #56 — altså på en
langt eldre versjon. GitHub-secreten var derfor ugyldig fra før, og utstedelsen
av versjon 9 gjorde ingen fungerende legitimasjon ubrukelig. Skal arbeidsflyten
kjøres igjen, utstedes en ny i det miljøet som skal lese den.

#### To rettelser funnet ved å kjøre leddet mot produksjon

**Kjøremappa kunne commites, og den inneholder hele artikkelen.** Kommandoen som
sto dokumentert her, skrev spørsmålet til `fravaer` i repoets rot — en katalog
ingen ignore-regel dekket. `prompt.txt` er en ordrett kopi av fullteksten, og
derfra er veien inn i historikken, og videre til et offentlig repo, ett
`git add -A`. Antidep har ikke rett til å redistribuere fullteksten
(`EVIDENCE_PIPELINE.md` §14), og det er grunnen til at både `documents/` og
`assignments/` har sin egen `.gitignore`.

Kjøringen kontrollerer det nå selv, og avviser før mappa opprettes
(`git-paths.ts`): en bane i et git-arbeidstre må være ignorert. Kontrollen gjelder
**filen** og ikke katalogen over den, fordi `assignments/` er en sporet katalog
som ignorerer alt under seg — en kontroll på katalogen ville avvist nettopp den
plasseringen resten av pipelinen bruker. En bane utenfor et arbeidstre slipper
gjennom, fordi det ikke finnes noen historikk å havne i. Oppslaget er det samme
som miljøfilskriveren bruker, og ligger nå felles.

To reviewfunn på nettopp denne kontrollen, begge reelle og begge rettet:

1. **Omkjøringen slapp gjennom.** Arbeidstre-oppslaget stanset så snart banen
   fantes, og for en fil ble `git -C` kalt med filen selv som katalog — «Not a
   directory», som ble lest som «utenfor et arbeidstre». Omkjøring er det normale
   tilfellet, så en `prompt.txt` som alt lå der på en uignorert bane, ble skrevet
   over med fullteksten uten at kontrollen slo til. Oppslaget går nå opp til
   nærmeste forelder som er en **katalog som finnes**.
2. **«Utenfor» var antatt og ikke fastslått, og det gjorde kontrollen
   fail-open.** `git rev-parse --show-toplevel` avslutter med 128 for alt — både
   «not a git repository», som betyr utenfor, og «dubious ownership», «invalid
   gitfile format» og en rettighetsfeil, som ikke betyr noe om hvor banen ligger
   — og mangler git i PATH, kommer det ingen exit-kode. Alle ble til «utenfor».
   Utfallet er nå tredelt, og «utenfor» krever et filsystemfaktum: ingen forelder
   har en `.git`. Svarer ikke git, og finnes det en `.git` over banen, skrives
   ingenting.
3. **Søket fulgte den leksikalske banen, ikke den fysiske.** Samme feilklasse en
   gang til: er en forelder en symlenke inn i et repo — `/tmp/kjoring` →
   `/repo/fravaer` — havner filen fysisk under `/repo` og kan commites derfra,
   mens søket oppover fra `/tmp/...` aldri ser `/repo/.git`. Svarer git, fanger
   `git -C` det selv, fordi git løser katalogen fysisk; det er når git ikke svarer
   at søket er alt som står igjen. Søket går nå langs den fysiske plasseringen, og
   lar den seg ikke fastslå, skrives ingenting.

**Gjennomlesningen kunne forsvinne ut av proveniensen.** To ting, begge funnet på
den ekte kjøringen av `9570760c`:

1. **Et søketreff slettet svaret.** Søket traff tre fragmenter fra den tospaltede
   PDF-en — «-10 classification of men» — og `continue` kom før svaret i det hele
   tatt ble lest. Begrunnelsen kontrolløren fikk, gjenga bare støyen, mens
   gjennomlesningen hadde funnet en hel setning med et faktisk antall i. Treffet
   avgjør fortsatt dekningen alene; svaret står nå ved siden av det.
2. **Proveniensen ble bare ført ved dekning.** En gjennomlesning som svarte
   `present` eller `uncertain`, endte som et modellskrevet avsnitt i en klinisk
   kontrollrad **uten at noe navnga hvem som skrev det, eller når**. §3.7 krever
   at hvert prosessledd kan spores, og et ledd som ikke åpnet gaten, er like mye
   et ledd som kjørte. Blokka føres nå hver gang en gjennomlesning ble lest, med
   `covered` i seg — den leses alene av en tredjepart, og uten feltet kunne den
   bli lest som et bevis for at gaten åpnet.

Begge er regresjonsprøver, og ingen av dem endrer hva som dekkes: de endrer bare
hva som står om det.

#### Hva som gjenstår

Ett steg, og det er ikke teknisk: **Peder gjør den menneskelige kildekontrollen**
av de to funnene i `/extraction-review`. Etter den gjenstår fortsatt en
redaksjonell beslutning før publisering — de to påstandsrevisjonene som finnes,
er lenket til de gamle sammendragsutledede funnene, ikke til disse.

### 74.46 Leserekkefølgen i den kanoniske teksten, og en ryddet kø

§74.45 endte med at ett steg gjenstod, og at det ikke var teknisk: Peder skulle
gjøre den menneskelige kildekontrollen av de to fulltekstfunnene i
`/extraction-review`. Det steget kunne ikke tas, og grunnen sto i flaten selv.

**Kildeutdragene viste tekst fra to spalter side om side på den samme
tekstlinjen.** Oppskriften var `pdftotext -layout -enc UTF-8 -eol unix`, og
`-layout` gjenskaper den **fysiske** plasseringen på papiret. I en tospaltet
vitenskapelig artikkel står venstre og høyre spalte ved siden av hverandre — og
da står de ved siden av hverandre i teksten også.

Det er ikke et visningsproblem, og det var ikke det issue
[#84](https://github.com/peohol/antidep/issues/84) ble skrevet om. Antideps
ordrette kontroll normaliserer blanktegn før den søker
(`src/agents/extraction-checks.ts`), så to uavhengige spalter ble behandlet som
**én sammenhengende tegnstrøm**. Et «ordrett sitat» kunne dermed bestå av ord
som aldri sto etter hverandre i kilden, og en klinisk opplysning kunne bli
tilskrevet feil behandlingsarm, feil studie eller feil endepunkt. Det er en
evidensintegritetsfeil (ANTIDEP_CONSTITUTION.md §8, §11).

Regresjonsprøven viser feilen ordrett, på en syntetisk tospaltet PDF-fikstur:
med den gamle oppskriften treffer sitatet «left column ends here. The right
column ends here.» — en setning som ikke står i dokumentet i det hele tatt.

#### Oppskriften henter nå posisjonsdata, og Antidep bygger rekkefølgen selv

```text
text_extraction_tool       pdftotext
text_extraction_arguments  -bbox-layout -enc UTF-8 -eol unix
text_extraction_transform  antidep-reading-order@2
```

`-bbox-layout` gir ikke tekst, men **koordinater**: hvert ord med sin
avgrensning, gruppert i linjer og blokker. `antidep-reading-order@2`
(`src/agents/reading-order.ts`) er Antideps eget, rene ledd som gjør dem om til
logisk leserekkefølge. Det **flytter blokker** og skriver ikke ett eneste tegn:
ingen orddeling settes sammen, ingen tegnsetting legges til, ingen ord fjernes.

Rekkefølgen bygges med et rekursivt snitt på tomrom, per side og rekursivt på
hver del:

| Steg | Regel |
|---|---|
| 1 | Finnes en **loddrett tomromskorridor** ingen blokk krysser, bred nok til å være en spaltemarg? Del der, og les venstre del før høyre |
| 2 | Ellers: finnes **vannrette tomromsbånd** ingen blokk krysser? Del der, øverste bånd først |
| 3 | Ellers er delen et blad, og blokkene leses ovenfra og ned |

**Loddrett før vannrett er ikke en smakssak.** Motsatt rekkefølge har en kjent
feil: har venstre og høyre spalte et avsnittsopphold på samme høyde, finnes det
et vannrett bånd tvers over begge, og et snitt der gir venstre-topp, høyre-topp,
venstre-bunn, høyre-bunn — spaltene flettet, altså nøyaktig feilen som skulle
rettes. Et loddrett snitt kan ikke gjøre det: en tittel eller en tabell over
full sidebredde krysser korridoren, korridoren finnes da ikke, og det vannrette
snittet skiller først full bredde fra spaltene. **Tittel, ingress og
gjennomgående overskrifter håndteres derfor av den samme regelen som spaltene,
uten et eget tilfelle.**

#### Når rekkefølgen ikke er gitt av oppsettet, avvises dokumentet

Et blad med to blokker som er atskilt vannrett og løper ved siden av hverandre
**mer enn to tommer** nedover siden, er to spalter som ingen korridor skilte.
Rekkefølgen mellom dem er ikke bestemt, og dokumentet markeres som ikke trygt
ekstraherbart: `extractDocumentText` returnerer en avvisning, og ekstraksjonen
stopper. Det er viktigere å avvise én vanskelig PDF enn å registrere kliniske
data lest i feil rekkefølge.

Grensen på to tommer er den ene terskelen som skiller to spalter fra **cellene i
en tabellrad**, som også står side om side. Forskjellen er ikke hva de
inneholder — det kan ingen geometri avgjøre — men hvor langt de løper sammen: en
rad er høy som et par linjer, en spalte som en side. Den høyeste tabellraden i
denne kodebasens egne artikler er 55 punkter; grensen er 144.

**Skjev tekst holdes utenfor.** Et vannmerke på tvers av siden — «Copyright 2001
… One personal copy may be printed» — er ikke artikkelens tekst, og det ligger
midt i spaltemargen. Uten at det holdes utenfor, ville det gjort
spalteinndelingen ubestemmelig og tatt hele siden med seg. Signalet er
geometrisk og ett: **ordene på en linje står ikke på samme grunnlinje** — og det
må gjelde **flertallet** av ordparene i blokken, ikke ett av dem. Et hevet tegn
inne i brødtekst, et sitatmerke eller en fotnote, har en egen liten avgrensning
som kan dekke nabo-ordet sitt mindre enn halvparten, og med en ett-par-regel
ville hele avsnittet blitt utelatt for det ene tegnets skyld. Margin er målt:
i artiklene her svikter *hvert* par i en skjev blokk og *ingen* i en vannrett.
Avgrensningen til det ene signalet er tilsiktet — bredere geometriske regler
(«linjer som ligger oppå hverandre») traff også ekte tekst, fordi Poppler legger
cellene i en tabellrad som egne linjer i den samme blokken. Utelatelse er den
dyre siden å ta feil på: en setning som forsvinner, kan få den kildeomfattende
fraværskontrollen til å konkludere at en opplysning ikke står noe sted.
Utelatelsen er derfor avgrenset og rapportert, og dekker den skjeve teksten mer
enn en fjerdedel av ordene på en side, avvises dokumentet.

#### Formen på teksten, og den harde grensen i kontrollen

```text
ord i en linje     mellomrom
linjer i en blokk  linjeskift       (mykt skille)
blokker            blank linje      (HARDT skille)
sider              sideskift \f     (HARDT skille)
```

En blokk er Popplers egen avgjørelse om at teksten henger sammen — et avsnitt.
Innenfor den skal en setning over to linjer fortsatt kunne siteres. Mellom to
blokker er det motsatte tilfellet.

**Men Popplers blokk er ikke alltid ett avsnitt.** For noen tabellrader legger
den radetiketten og verdicellene som egne linjer på den *samme grunnlinjen*
inne i én blokk. Da skilte bare et linjeskift «17-Item HAM-D score,» fra tallet
i nabocellen — altså det myke skillet — og den ordrette kontrollen ville godtatt
et sitat som gikk fra etiketten og inn i en fremmed celle. Det er den samme
feilen som spaltene, ett nivå lenger ned, og den sto i den ekte artikkelens
tabell 1.

En blokk deles derfor i cellene sine før rekkefølgen avgjøres, på det samme
geometriske signalet som resten av modulen: **to linjer på den samme
grunnlinjen, atskilt av et tomrom, er to celler**, og hver av dem blir sin egen
blokk med det harde skillet rundt seg. Grunnlinjekravet er det som skiller en
rad fra en stabling — to linjer som ikke overlapper i høyden, står over
hverandre — og tomromskravet det som skiller to celler fra én synlig tekstlinje
Poppler delte. En blokk der ingen rad har mer enn én linje, altså all vanlig
brødtekst, røres ikke, og teksten blir tegn for tegn den samme. Prøvd på de to
ekte artiklene: Versiani-teksten er byte for byte uendret, og Fava-teksten
endres bare i tabell 1 — med det samme ordtallet, 3911, før og etter.

`normalize()` i `extraction-checks.ts` gjør derfor **ikke** et opphold med en
blank linje eller et sideskift om til et mellomrom, men til en grense et ordrett
søk ikke kan krysse. Uten den kunne den samme feilen oppstått på nytt mellom en
sidefot og en brødtekst, mellom to tabellceller, eller mellom den siste blokken
på én side og den første på den neste. Grensen gjelder begge sider av søket: et
utdrag som selv er kopiert med avsnittsskillet i behold, treffer fortsatt.

#### Proveniensen: hele veien fra dokument til tekst står i raden

Uten etterbehandlingen er representasjonen ikke reproduserbar. En tredjepart som
kjører `pdftotext -bbox-layout` på dokumentet, får en XHTML-fil med koordinater
— ikke teksten `content_hash` er beregnet av. Migrasjon 003g gir derfor
`knowledge.source_versions` kolonnen `text_extraction_transform`, tar den inn i
uforanderlighetsvernet (`knowledge.freeze_source_version()`), og eksponerer den
i den redaksjonelle lesemodellen, i ekstraksjonsoppdraget og i
kontrollgrunnlaget. Dokumentbindingen som jsonb har fått **én** definisjon
(`knowledge.source_version_document_binding(uuid)`), lest av både oppdraget og
kontrollgrunnlaget: to kopier av formen var to steder å legge til et felt.

**Den lukkede oppskriftslisten har nå tre rader, og de to nederste er ikke en
overgangsordning.** Hver dokumentutledet kildeversjon som allerede står i basen,
er registrert med `-layout` og uten etterbehandling, eller med den første
utgaven av etterbehandlingen. De radene **skrives ikke om**: en rad som ble
laget på én måte, skal ikke i ettertid påstå at den ble laget på en annen
(ANTIDEP_CONSTITUTION.md §14).

De to grensene er forskjellige grenser, og det er forskjellen som lar
historikken bestå:

| Oppskrift | Kan lagres | Kan registreres nå | Kan kjøres |
|---|---|---|---|
| `-bbox-layout` + `antidep-reading-order@2` | ja | **ja** | ja |
| `-bbox-layout` + `antidep-reading-order@1` | ja | nei | **nei** |
| `-layout`, uten etterbehandling | ja | nei | ja |

`@1` er den ene raden som kan lagres uten å kunne kjøres, og grunnen er at den
ikke delte en tabellrad Poppler hadde lagt i én blokk. De kildeversjonene som
bærer den, skal få stå og si hva de faktisk ble laget med — men den skal ikke
kunne kjøres igjen og gi en tekst noen bygger videre på. Kolonnen «kan kjøres»
håndheves i `src/agents/document-binding.ts`, de to andre i databasen.

#### Kontrollflaten viser teksten, ikke papiret

`source_excerpt` vises som lesbar tekst med normal linjebryting, ett avsnitt per
uavhengig tekstblokk (`src/lib/readable-excerpt.ts`). Linjeskiftene inne i et
avsnitt er der spaltens linje tok slutt på papiret, og å bevare dem ville tvunget
en kontrollør på mobil til å rulle vannrett gjennom en setning. Den vannrette
rullingen fra §74.44 var kompensasjon for en representasjon med feil
leserekkefølge, og er borte.

Orddelingen står: «selec- tive» settes ikke sammen til «selective». En regel for
det ville måttet skille orddeling fra ekte bindestrek, og «fluoxetine- treated»
viser at den ikke kan gjøres trygg. Prisen er et par synlige bindestreker;
alternativet er et ord som ikke står i dokumentet.

**Én tekst skal likevel ikke flyte.** Alt over hviler på at leserekkefølgen i
teksten *er* logisk. En kildeversjon som bærer verktøyets utdata ordrett —
`-layout`, uten etterbehandling — er ikke det: der ligger venstre og høyre
spalte på den samme tekstlinjen, atskilt av en vegg mellomrom. Slås veggen
sammen til ett mellomrom, leser to uavhengige spalter som én flytende setning,
og kontrolløren ser en setning som ikke står i artikkelen. Veggen er det eneste
synlige varselet, og blir stående: et slikt utdrag vises som det står, med en
setning over det som sier hvorfor. Grensen leses av oppskriften i raden
(`excerptKeepsLayout`), ikke av en gjetning om hva som står i teksten.

#### Produksjonsdataene er ryddet, og to funn ble ikke fjernet

Køen i `/extraction-review` hadde seks evidensfunn. Den maskinelle kontrollen før
noe ble slettet, ga to forskjellige svar:

| Funn | Representasjon | Menneskelig kontroll | Påstandslenke | Reviewbeslutning | Claim-sitat | Publisert | Utfall |
|---|---|---|---|---|---|---|---|
| `090bd2a9` | full_text | 0 | 0 | 0 | 0 | 0 | fjernet |
| `445bda32` | full_text | 0 | 0 | 0 | 0 | 0 | fjernet |
| `9ba56fb4` | full_text | 0 | 0 | 0 | 0 | 0 | fjernet |
| `9570760c` | full_text | 0 | 0 | 0 | 0 | 0 | fjernet |
| `5b98b916` | abstract | 0 | **1** | 0 | **1** | 0 | **ikke fjernet** |
| `fcbbb1f8` | abstract | 0 | **1** | 0 | **1** | 0 | **ikke fjernet** |

Ingenting er publisert i prosjektet, og ingen av de seks var menneskelig
kildekontrollert. **De fire fulltekstfunnene var artefaktene fra den forrige
oppskriften, og de er fjernet** — med 41 forankringer og 8 maskinelle kontroller,
i én transaksjon, med en auditrad per funn.

**De to sammendragsutledede funnene er ikke fjernet.** De bærer hver sin
påstandsrevisjon og er sitert i en registrert claim-verifikasjon. Å fjerne dem
ville gjort revisjonene til påstander uten det grunnlaget de ble laget av, og
skrevet om nedtegnelsen av en utført kontroll — publisert eller ikke
(ANTIDEP_CONSTITUTION.md §4, §8, §14). De er dessuten ikke berørt av feilen:
de er utledet av et sammendrag hentet som tekst, ikke av en tospaltet PDF.
**Hva som skal skje med dem, er en redaksjonell beslutning, ikke en teknisk
opprydding.**

#### Veien ut er smal, guardet og ikke en redaksjonell funksjon

Antidep sletter ikke klinisk historikk, og append-only-triggerne er fasiten.
Alternativet til en guardet vei er likevel ikke «ingen sletting»: den som eier
databasen, kan skru av en trigger og slette hva som helst uten et spor.
`knowledge.discard_unpublished_extraction_artifacts(uuid[], text)` (migrasjon
005af) **innskrenker** derfor den operasjonen framfor å utvide noen rettighet:

- EXECUTE er revokert fra PUBLIC og gitt til **ingen** klientrolle — verken
  anon, authenticated eller service_role.
- Den krever i tillegg en autorisert redaktøridentitet
  (`knowledge.assert_editor_authorized()`) og en begrunnelse.
- Den tar en **eksplisitt liste** med id-er. Ikke et predikat, og ingen feiing.
- Den **feiler lukket**, uten å slette noe, på hver rad som er menneskelig
  kildekontrollert, bærer en påstandslenke, har en registrert reviewbeslutning
  eller er sitert i en claim-verifikasjon. Det er prøvd mot de ekte radene: et
  kall med hele køen ble avvist på `5b98b916`.
- Den skriver en auditrad per fjernet funn med hele kontrollgrunnlaget som
  `old_revision_or_snapshot`. **Det er raden som er borte, ikke sporet av den** —
  hva de fire funnene inneholdt, kan fortsatt leses ut av `audit.events`.
- Kilder, originaldokumenter, kildeversjoner, agentkjøringer og auditrader røres
  ikke.

Append-only-triggerne skrus av og på inne i transaksjonen, også når noe går galt,
slik at vernet aldri står av utenfor dette kallet.

**Kontrollene kjører bak låsen, ikke foran den.** De tre tabellene låses i
`ACCESS EXCLUSIVE` før den første kontrollen leser noe. Uten den rekkefølgen
kunne en menneskelig kildekontroll som ble commitet etter at kontrollen leste
tabellen, men før slettingen låste den, blitt lest som fraværende og så slettet
av kallet — og øyeblikksbildet ville ikke hatt den. Det er det motsatte av å
feile lukket. De tre øvrige kontrollene trenger ingen egen lås: påstandslenker,
reviewbeslutninger og claim-sitater peker på funnet med `on delete restrict`, så
en rad som blir commitet underveis, stopper slettingen framfor å forsvinne med
den.

#### Fava 2000 og Versiani 2005 er kjørt på nytt, på `@1`

Begge originaldokumentene var tilgjengelige i økten, og hele kjeden er kjørt fra
dokument til registrert kontroll — med de gamle kildeversjonene stående som
historiske rader:

| Ledd | Fava 2000 | Versiani 2005 |
|---|---|---|
| Ny kildeversjon | `1d84891a` | `f0811561` |
| `content_hash` | `sha256:f6b3ca4d…` | `sha256:d6b692f3…` |
| Gammel kildeversjon | `1287e69b`, står | `d3c27d3d`, står |
| Nytt evidensfunn | `59f7c235` | `a861f89f` |
| Forankrede felter | 10, alle gjenfunnet ordrett | 9, alle gjenfunnet ordrett |
| Maskinell kontroll | `d768c785`, utfall `uncertain` | `7f20a01a`, utfall `uncertain` |
| Dekkede av påkrevde felter | 4 av 13 | 3 av 12 |

`uncertain` er ikke et avvik, og kontrollen sier selv hvorfor: de norske
katalogetikettene («vektendring», «voksne med depressiv lidelse») finnes ikke
ordrett i en engelsk artikkel, og et tall uten det begrepet ved siden av kan ikke
tilskrives raden. For Versiani svarte den kildeomfattende gjennomlesningen
`uncertain` på begge fraværene, og begrunnelsene står i kontrollraden: teksten
oppgir flere antall, men ingen av dem er oppgitt som nevneren gjennomsnittet er
regnet over, og presisjonen er oppgitt som standardavvik framfor som
konfidensintervall. **Et `uncertain` stanser ingenting galt; et uriktig `absent`
ville latt Antidep påstå at kilden ikke oppgir noe den faktisk oppgir.**

Køen viser nå fire funn: de to nye fulltekstfunnene, og de to
sammendragsutledede som ikke kunne fjernes.

#### Ett steg gjenstår, og de to fulltekstfunnene skal ikke kildekontrolleres før det

Kjøringen over ble gjort før celledelingen fantes, og de to kildeversjonene
`1d84891a` og `f0811561` bærer derfor `antidep-reading-order@1`. For Versiani er
det uten betydning for teksten: `@2` gir byte for byte den samme teksten, så
raden er fortsatt nøyaktig reproduserbar. For Fava er den ikke det — tabell 1
kom ut med radetiketten og verdicellene skilt av et linjeskift framfor av en
blank linje, og det er nettopp den formen den ordrette kontrollen ikke skal
kunne krysse.

Å rette det i produksjonsbasen krever to ting, i denne rekkefølgen:

1. **Skjemaendringen fra denne PR-en må deployes** — den tre-radede
   oppskriftslisten og skriveveien som godtar `@2`. Uten den kan ingen `@2`-rad
   registreres.
2. **Begge dokumentene kjøres på nytt** mot `@2`: ny kildeversjon per dokument
   med de gamle radene stående, de to `@1`-funnene fjernet gjennom den guardede
   veien, og ekstraksjon, maskinell kontroll og kildeomfattende fraværskontroll
   kjørt om.

Inntil steg 2 er gjort, **skal den menneskelige kildekontrollen av `59f7c235` og
`a861f89f` ikke gjøres**. Det er den samme regelen issue #84 satte, av den samme
grunnen: en faglig kontroll skal ikke gjøres på et grunnlag som ikke holder.
De to sammendragsutledede funnene er ikke berørt — de er utledet av tekst, ikke
av en PDF.

#### Hva som ble kjørt

| Kontroll | Utfall |
|---|---|
| `npm run lint` | grønn |
| `npm run format:check` | grønn |
| `./scripts/verify-counts.sh` | grønn |
| `npm run typecheck` | grønn |
| `npm run test` | grønn |
| `npm run build` | grønn |
| pgTAP, 67 filer | kjørt mot det hostede prosjektet i en transaksjon som rulles tilbake, uten avvik mot utgangspunktet |
| Migrasjonene | 003g og 005af deployet; endringene fra rettelsene av celledelingen og låsen er deployet for 005af og **gjenstår for 003g** |
| Kjeden mot produksjon | modell-ledd, registrering og maskinell kontroll kjørt med hver sin identitet, på `@1` |
| Regresjonsprøven for tabellraden | kontrollert begge veier: den feiler uten celledelingen og består med den |

`npm run db:reset`, `npm run db:test`, `npm run db:test:lock` og
`npm run db:test:chain` krever en lokal Supabase-stack, og den krever Docker,
som ikke finnes i agentmiljøet. De kjøres i CI-jobben «Migrasjoner og
databasetester på lokal Supabase-stack», som er den som avgjør. pgTAP-filene er
i tillegg kjørt herfra mot det hostede prosjektet, én fil per transaksjon med
`rollback` til slutt, med og uten de nye migrasjonene, og differansen er null.

#### Hva som gjenstår

**Peder gjør den menneskelige kildekontrollen** av de to nye fulltekstfunnene i
`/extraction-review`. Utdragene står nå i korrekt logisk leserekkefølge, og
flaten viser dem som lesbar tekst.

To ting er redaksjonelle beslutninger og ikke teknisk gjeld:

1. Hva som skal skje med `5b98b916` og `fcbbb1f8`, de to sammendragsutledede
   funnene de eksisterende påstandsrevisjonene hviler på.
2. Om `fluoksetin` og `paroksetin` skal registreres i katalogen. Begge artiklene
   sammenligner mot dem, men bare `sertralin` og `mirtazapin` finnes, og et funn
   kan derfor ikke føre dem som komparator.

---

## 75. Neste steg

> **Merk:** Avsnittet under er skrevet ved planens godkjenning og beskriver oppstarten.
> Det er beholdt som historikk (§71). Planleggingsfasen er avsluttet, og PR A til PR G
> er merget (§74.2). **Gjeldende neste steg står i §74.4, og registrert gjeld i §74.7.**

Når denne planen er godkjent, avsluttes planleggingsfasen som standard arbeidsmodus.

Neste steg er **faktisk implementasjon**, med PR A:

```text
chore: bootstrap Antidep web app
```

Deretter følges PR-rekken og milepælene i dette dokumentet, med planen oppdatert fortløpende etter hvert som prosjektet går fra arkitektur til fungerende klinisk produkt.
