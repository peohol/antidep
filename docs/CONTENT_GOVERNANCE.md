# Antidep Content Governance

**Versjon:** 0.1  
**Dato:** 18. august 2026  
**Status:** Første styringsspesifikasjon  
**Styrende dokumenter:** [`ANTIDEP_CONSTITUTION.md`](./ANTIDEP_CONSTITUTION.md), [`KNOWLEDGE_MODEL.md`](./KNOWLEDGE_MODEL.md), [`EVIDENCE_PIPELINE.md`](./EVIDENCE_PIPELINE.md) og [`DATABASE_ARCHITECTURE.md`](./DATABASE_ARCHITECTURE.md)

## 1. Formål

Dette dokumentet definerer **hvem som kan gjøre hva med faglig innhold i Antidep, under hvilke vilkår og med hvilket ansvar**.

Det skal gjøre publisering, korreksjon og faglig uenighet håndterbar uten at kvaliteten blir avhengig av enkeltpersoners hukommelse eller skjønn alene.

Dokumentet regulerer blant annet:

- roller og beslutningsmyndighet
- hvilke innholdstyper som krever hvilket review-nivå
- hvordan KI-generert innhold behandles
- kilde- og evidensforvaltning
- publisering, avpublisering og rollback
- review-frister og oppdateringsutløsere
- håndtering av uenighet, usikkerhet og interessekonflikter
- feilrapportering og sikkerhetskritiske korreksjoner
- transparens overfor brukerne
- faglig ansvar for kliniske anbefalinger og verktøyregler

Dette er en **styringsmodell**, ikke et ansettelsesreglement eller en juridisk ansvarsfordeling mellom fremtidige organisasjoner.

---

## 2. Normative begreper

- **SKAL**: krav som bare kan fravikes ved eksplisitt endring av styringsdokumentene.
- **BØR**: sterk standard som kan fravikes når begrunnelsen dokumenteres.
- **KAN**: tillatt, men ikke påkrevd.

---

# Del I — Grunnprinsipper

## 3. Faglig autoritet ligger hos mennesker

KI-agenter, deterministiske prosesser og importer kan:

- finne kilder
- foreslå strukturering
- ekstrahere data
- foreslå claims
- oppdage inkonsistens
- utføre kontroller
- foreslå redaksjonelle forbedringer

De kan ikke alene ha endelig myndighet til å publisere klinisk betydningsfulle evidenssynteser, anbefalinger eller kliniske regler.

## 4. Godkjenning skal være proporsjonal med risiko

Antidep skal ikke behandle alle endringer likt.

En stavefeil i et handelsnavn og en ny anbefaling om nedtrapping skal ikke kreve samme prosess.

Review-nivå bestemmes av minst:

- kunnskapstype
- klinisk konsekvens dersom innholdet er feil
- usikkerhet i evidensen
- om endringen er ny eller bare redaksjonell
- om innholdet brukes i et klinisk verktøy
- om endringen kan påvirke behandling direkte

## 5. Ingen kan godkjenne sitt eget høyrisikoinnhold alene

For høyrisikoinnhold skal minst én kvalifisert person som ikke var hovedforfatter eller primær synteseaktør utføre faglig review.

Dette gjelder særlig:

- kliniske anbefalinger
- doseringsregler
- bytte- og nedtrappingslogikk
- alvorlige sikkerhetsadvarsler
- regler for graviditet/amming der feil kan ha vesentlig konsekvens
- interaksjoner med potensielt alvorlig utfall
- innhold som kan føre til at behandling startes, stoppes eller endres

## 6. Fravær av konsensus skal ikke skjules

Når kvalifiserte reviewere etter rimelig arbeid fortsatt er uenige, skal systemet kunne publisere:

- eksplisitt usikkerhet
- alternative fortolkninger
- avgrenset formulering
- eller ingen konklusjon

Målet er ikke å tvinge frem ett svar når kunnskapsgrunnlaget ikke forsvarer det.

---

# Del II — Roller

## 7. `Contributor`

Kan foreslå:

- nye kilder
- nye EvidenceItems
- nye claims
- rettelser
- metadataendringer

Contributor har ikke automatisk publiseringsmyndighet.

## 8. `Editor`

Kan:

- opprette og redigere utkast
- strukturere claims
- koble evidens
- håndtere kilde- og metadataarbeid
- sende innhold til review
- foreslå avpublisering eller revisjon

Editor kan være kliniker eller annen kvalifisert fagperson avhengig av arbeidsområdet.

## 9. `Reviewer`

Kan utføre faglig review innen eksplisitt tildelt scope.

Scope kan eksempelvis avgrenses etter:

- klinisk fagområde
- innholdstype
- bestemte legemidler
- evidensmetodikk
- farmakokinetikk/interaksjoner
- graviditet/amming
- kliniske regler

Reviewer skal kunne:

- godkjenne
- be om endringer
- avvise
- markere usikkerhet
- eskalere

## 10. `Publisher`

Kan utføre selve publiseringshandlingen når alle nødvendige gates er oppfylt.

Publisher skal normalt ikke kunne overstyre manglende faglig godkjenning.

Publisering er en administrativ/teknisk rettighet; den skal ikke i seg selv gi faglig autoritet.

## 11. `Clinical Lead`

Antidep BØR ha én eller flere navngitte kliniske fagansvarlige med myndighet til å:

- fastsette review-standarder
- avgjøre eskalerte faglige konflikter
- godkjenne høyrisiko policyendringer
- iverksette midlertidig avpublisering av sikkerhetsgrunner
- definere hvilke kompetansekrav som gjelder for reviewer-scope

Clinical Lead skal ikke kunne slette uenighet eller historikk.

## 12. `Evidence Lead`

Antidep BØR ha metodisk ansvar for:

- evidensstandarder
- GRADE-bruk der relevant
- kildekvalitetsvurdering
- søke- og ekstraksjonsmetodikk
- håndtering av indirekte eller motstridende evidens
- evaluering av agentenes evidensarbeid

Clinical Lead og Evidence Lead kan være samme person i en tidlig fase, men rollene bør konseptuelt holdes adskilt.

## 13. `Administrator`

Kan forvalte:

- brukerroller
- scopes
- tekniske tilganger
- systemkonfigurasjon

Administratorrollen gir ikke automatisk faglig review- eller publiseringsmyndighet.

## 14. `Agent Worker`

Maskinrolle med least-privilege-tilgang til eksplisitte pipelineoperasjoner.

`Agent Worker` er ikke én rolle, men et register. Hvert pipelineledd som skriver til
kunnskapsbasen, har sin egen aktør, sin egen tekniske identitet og sin egen legitimasjon, og
identiteten arver aktørens agentrolle som rettighetsgrense. En agent autentiserer seg med sin
egen legitimasjon — aldri med en brukerkonto og aldri med en felles nøkkel som kan alt.

Konsekvensene skal være håndhevet, ikke beskrevet. Agenten skal ikke kunne:

- gi seg selv ny rolle
- registrere eller utstede legitimasjon til en agentidentitet; det er en menneskelig handling
- utføre et annet agentledds operasjon, heller ikke med gyldig legitimasjon
- verifisere sitt eget arbeid
- registrere en faglig godkjenning; en reviewbeslutning krever en menneskelig aktør
- endre publiseringspolicy
- godkjenne eget høyrisikoinnhold
- endre tidligere publisert revisjon in place
- slette audit/proveniens

Flere uavhengige kontrollag er ønsket og er den foretrukne måten å øke kvaliteten på. Et andre
kontrollag er en ny aktør med sin egen identitet og sin egen kjøring — ikke flere rettigheter
på en identitet som allerede finnes.

---

# Del III — Kunnskapstype og godkjenningskrav

## 15. `deterministic_fact`

Eksempler:

- handelsnavn
- legemiddelform
- styrke
- ATC-kode
- markedsstatus

### Standard

Når opplysningen kommer direkte fra definert autoritativ strukturert kilde og valideringen er deterministisk, KAN publisering automatiseres etter vellykket validering.

### Krever review dersom

- mapping er tvetydig
- kildekilder er uenige
- endringen påvirker et klinisk verktøy
- data må fortolkes
- produktopplysningen har klinisk sikkerhetsbetydning som ikke kan avgjøres rent maskinelt

## 16. `evidence_synthesis`

SKAL ha:

- verifiserte relevante EvidenceItems
- eksplisitte ClaimEvidenceLinks
- evidensvurdering
- vurdering av motstridende evidens
- menneskelig faglig review før første publisering

Vesentlig revisjon krever nytt review.

## 17. `clinical_recommendation`

SKAL ha strengere krav enn beskrivende syntese.

Før publisering skal minst følgende være eksplisitt:

- hvem anbefalingen gjelder for
- hva som anbefales
- alternativene
- forventet nytte
- relevante skadevirkninger/ulemper
- evidenssikkerhet
- viktige verdibaserte eller pragmatiske antakelser
- kildegrunnlag
- navngitt kvalifisert human approval

Anbefalinger skal ikke maskeres som nøytrale fakta.

## 18. `ClinicalRule`

Regler som faktisk produserer dose-, bytte- eller nedtrappingssteg behandles som sikkerhetskritisk innhold.

Ny eller endret regel skal minst kreve:

1. eksplisitt spesifikasjon
2. kildegrunnlag
3. klinisk reviewer
4. teknisk/verifikatorisk test
5. testcases for normal- og grenseverdier
6. eksplisitt regelversjon
7. publiseringsbeslutning

Ved endring av inputdata som styrker, delbarhet eller markedsstatus skal berørte regler kunne flagges til re-review.

---

# Del IV — Risikoklassifisering

## 19. Internt governance-risikonivå

Dette er **ikke** regulatorisk klassifisering av medisinsk utstyr.

Antidep skal bruke et internt risikonivå for å styre review.

### `R0 — redaksjonell`

Ingen endring i klinisk betydning.

Eksempler:

- språkføring
- typografi
- retting av stavefeil uten meningsendring

Kan godkjennes av editor dersom diffen dokumenteres.

### `R1 — lav klinisk konsekvens`

Faktuell endring med liten sannsynlighet for å påvirke behandlingsvalg direkte.

Normalt ett kontrollledd utover forfatter/import.

### `R2 — moderat`

Kan påvirke klinikerens vurdering, men representerer ikke alene en direkte behandlingsinstruks.

Eksempler:

- relativ bivirkningsprofil
- effektforskjeller
- tolkning av farmakokinetikk

Krever kvalifisert faglig reviewer.

### `R3 — høy`

Kan direkte påvirke behandling eller pasientsikkerhet.

Eksempler:

- konkrete behandlingsanbefalinger
- nedtrappingsplan
- bytteregler
- alvorlige interaksjoner
- dosejustering ved organsvikt

Krever uavhengig human review og streng publiseringsgate.

### `R4 — kritisk`

Feil kan med rimelig sannsynlighet bidra til alvorlig skade eller farlig behandlingsendring.

Skal ha eksplisitt definert reviewerkompetanse og normalt minst to-personers klinisk kontroll før ordinær publisering.

I en akutt sikkerhetskorreksjon kan innhold midlertidig trekkes tilbake før full ny syntese er ferdig.

---

# Del V — Kildegovernance

## 20. Kilder vurderes for formål, ikke bare prestisje

En kilde skal vurderes etter:

- relevans for spørsmålet
- studiedesign
- metodisk kvalitet
- populasjon
- komparator
- endepunkt
- tidsramme
- presisjon
- direktehet
- aktualitet
- regulatorisk/norsk relevans der aktuelt

En «høy» kildehierarkisk kategori erstatter ikke denne vurderingen.

## 21. Autoritative kilder

For enkelte deterministiske felt kan Antidep definere en autoritativ kilde eller prioritert kildekjede.

Eksempelvis kan norsk markedsstatus eller styrke normalt baseres på norske regulatoriske/strukturerte legemiddeldata fremfor sekundære nettsider.

Hvilke kilder som er autoritative for hvilke felter skal være eksplisitt konfigurert og versjonert.

## 22. Kilder som ikke kan verifiseres

En kilde uten tilstrekkelig tilgang til relevant innhold kan:

- registreres som kandidat
- brukes til discovery

men skal ikke automatisk få status som direkte støtte for et konkret claim dersom Antidep ikke har kunnet kontrollere det påståtte innholdet.

## 23. Retractions og korreksjoner

Når en kilde:

- trekkes tilbake
- får alvorlig korreksjon
- blir erstattet
- viser seg å være feilregistrert

skal alle avhengige EvidenceItems og publiserte claims kunne identifiseres automatisk.

Berørte høyrisikoclaims skal prioriteres for review.

## 24. Produsentfinansiert evidens

Finansiering eller forfatterinteresser er ikke automatisk grunn til eksklusjon.

Men relevante interessekonflikter skal registreres når de er kjent og inngå i kvalitets-/biasvurderingen.

Antidep skal ikke la produsentkilder dominere syntesen bare fordi de er lettest tilgjengelige.

---

# Del VI — KI-governance

## 25. KI-innhold er alltid forslag før verifikasjon

Språkmodelloutput skal som utgangspunkt ha status som arbeidsprodukt, ikke kunnskap.

Verifikasjonen som løfter det fra forslag til kontrollert, kan selv være KI-produsert — det er
hovedveien — så lenge den er en separat operasjon, utført av en annen aktør, mot
kildematerialet. Det er kontrollens uavhengighet som gjør den til en kontroll, ikke at den
utføres av et menneske.

Status skal eksplisitt skille mellom eksempelvis:

- generated
- extracted
- independently_verified
- human_reviewed
- published

## 26. Menneskelig reviewer skal kunne se grunnlaget

Review-UI skal ikke bare vise ferdig KI-tekst.

Revieweren skal kunne gå til:

- kilden
- source locator
- EvidenceItems
- motstridende evidens
- tidligere revisjon
- agentens usikkerhets-/avviksflagg

Kravet er implementert som `api.claim_review_workspace(uuid)` og reviewflaten over den: hele
evidenssettet med hvert funn ordrett, kildens status, kildeversjonens adresse og
fingeravtrykk, den gjeldende ekstraksjonskontrollen per funn, registrert evidens på samme
virkestoff og endepunkt som *ikke* er lenket til revisjonen, evidensvurderingen, og hver
tidligere kontroll med sine sju kontrollpunkter og sine funn. Blokkeringer som stopper
publisering leses av publiseringsgaten selv, slik at flaten ikke kan si «klar» om noe gaten
stenger.

## 27. KI skal ikke skjule uenighet

Agenten skal ikke optimaliseres for å produsere en «ren» konklusjon på bekostning av relevante motfunn.

Pipeline skal eksplisitt belønne oppdagelse av:

- manglende evidens
- heterogenitet
- inkonsistens
- feil generalisering
- alternative forklaringer

## 28. Modeller og prompts er versjonerte produksjonskomponenter

For klinisk relevant agentarbeid skal det kunne rekonstrueres:

- leverandør
- modellidentifikator
- relevant modellversjon når tilgjengelig
- agentrolle
- promptmalversjon
- pipelineversjon
- inputmanifest
- outputmanifest

## 29. Modellbytte krever evaluering

Ny modell skal ikke få produksjonsrolle bare fordi den oppleves bedre i enkeltcaser.

Før betydningsfull modellendring bør Antidep kjøre et fast evalueringssett som måler minst:

- ekstraksjonsnøyaktighet
- numeriske feil
- kilde–claim-støtte
- falske positive konklusjoner
- manglende motstridende evidens
- evne til å avstå når evidens mangler

---

# Del VII — Review og publisering

## 30. Review er en beslutning, ikke en kommentar

Hvert formelt review skal ende i én eksplisitt status:

- `approved`
- `approved_with_minor_edits`
- `changes_requested`
- `rejected`
- `uncertain`
- `escalated`

Kommentarer kan supplere, men ikke erstatte beslutningen.

## 31. Review skal være knyttet til eksakt revisjon

En godkjenning av ClaimRevision 3 gjelder ikke automatisk ClaimRevision 4.

Redaksjonelle endringer som ikke påvirker mening kan følge en forenklet prosess dersom systemet kan dokumentere at den kliniske betydningen er uendret.

## 32. Publisering skal være eksplisitt

`approved` er ikke det samme som `published`.

Publisering er en separat hendelse som:

- kontrollerer gates
- peker til eksakt revisjon
- registrerer aktør og tidspunkt
- kan rulles tilbake uten historiesletting

## 33. Ingen «silent fixes» av publisert klinisk innhold

Hvis meningen i publisert innhold endres, skal det opprettes ny revisjon og ny publiseringshendelse.

Små presentasjonsendringer i avledet UI kan gjøres uten ny claim-revisjon når selve kunnskapsobjektet er uendret.

---

# Del VIII — Aktualitet og re-review

## 34. To typer oppdatering

Antidep skal kombinere:

1. **event-driven review** — trigges av ny relevant informasjon
2. **periodisk review** — sikkerhetsnett når ingen trigger er fanget opp

## 35. Oppdateringstriggere

Eksempler:

- ny eller oppdatert retningslinje
- ny viktig metaanalyse
- regulatorisk sikkerhetsmelding
- source retraction/correction
- nytt norsk produkt eller ny styrke
- markedsavregistrering
- ny alvorlig interaksjonsinformasjon
- bruker rapporterer mulig feil
- klinisk regel får nye inputforutsetninger
- agentmonitorering finner relevant ny evidens

## 36. Review-frister skal være risikobaserte

Systemet skal støtte en `review_due_at` og policy per innholdstype/risikonivå.

Versjon 0.1 fastsetter ikke permanente universelle intervaller.

Som driftsstart kan Antidep bruke konservative standardintervaller, men de skal kunne justeres uten å endre selve kunnskapsmodellen.

Høyrisikoinnhold skal ha kortere maksimal review-syklus enn stabile katalogfakta.

## 37. Utløpt review er en synlig systemtilstand

Når reviewfristen passeres skal innholdet ikke late som det er ferskt.

Avhengig av risiko kan det:

- fortsette publisert med «review overdue»-flagg internt
- få synlig aktualitetsadvarsel
- blokkeres fra bestemte kliniske verktøy
- avpubliseres dersom policyen krever det

---

# Del IX — Faglig uenighet

## 38. Uenighet mellom reviewer og editor

Første steg er å identifisere hva uenigheten gjelder:

- faktum
- kildeutvalg
- metodikk
- evidenssikkerhet
- klinisk betydning
- formulering
- verdibasert anbefaling

Disse skal ikke blandes sammen.

## 39. Eskalering

Ved vedvarende uenighet:

1. begge syn dokumenteres
2. relevant Evidence Lead/Clinical Lead involveres
3. ekstra reviewer kan innhentes
4. endelig beslutning dokumenteres med begrunnelse

Mindretalls-/alternativ vurdering skal kunne bevares i historikken.

## 40. Ved reell evidensusikkerhet er «ukjent» tillatt

Antidep skal heller publisere «usikkert» eller avstå fra rangering enn å produsere et kunstig entydig svar.

---

# Del X — Feil, korreksjoner og sikkerhet

## 41. Alle brukere skal kunne rapportere mulig feil

Fra relevant innhold skal det være mulig å rapportere:

- faktuell feil
- misvisende formulering
- manglende kilde
- kilde som ikke støtter påstanden
- foreldet informasjon
- mulig sikkerhetsproblem
- UI som skjuler viktig usikkerhet

Rapporten skal kobles til eksakt objekt/revisjon.

## 42. Triage av feilrapport

Minimumskategorier:

- `not_an_error`
- `editorial`
- `factual_low_risk`
- `clinical_significance`
- `potential_safety_issue`
- `security/privacy`

Høyrisikosaker skal prioriteres fremfor ordinær content backlog.

## 43. Midlertidig avpublisering

Clinical Lead eller definert beredskapsrolle skal kunne trekke et høyrisikoobjekt midlertidig dersom det finnes rimelig mistanke om vesentlig feil.

Dette skal:

- være auditert
- ha begrunnelse
- ikke slette objektet
- opprette reviewarbeid

Full ny evidenssyntese trenger ikke være ferdig før en potensielt farlig anbefaling tas ned.

## 44. Korreksjoner skal være synlige når de er vesentlige

Antidep bør ha offentlig korreksjonslogg for vesentlige publiserte feil.

Den skal beskrive:

- hva som var feil
- hva som ble endret
- når
- om feilen kunne ha påvirket klinisk bruk

uten å eksponere unødvendige personopplysninger om bidragsytere.

---

# Del XI — Interessekonflikter og redaksjonell uavhengighet

## 45. Faglige reviewere skal oppgi relevante interessekonflikter

Det bør registreres relevante økonomiske eller profesjonelle bindinger når disse med rimelighet kan påvirke vurderingen.

## 46. Interessekonflikt betyr ikke automatisk inhabilitet

Governance skal kunne skille mellom:

- ingen relevant konflikt
- mindre konflikt som kan håndteres transparent
- betydelig konflikt som krever annen hovedreviewer

Høyrisikoanbefalinger bør ikke ha eneste kliniske godkjenner med betydelig relevant økonomisk interessekonflikt.

## 47. Finansiering skal ikke kjøpe innhold

Ekstern finansiering skal aldri gi rett til:

- å kreve bestemte konklusjoner
- å blokkere negativt innhold
- å velge bort relevante studier
- å endre evidenssikkerhet

Eventuelle fremtidige sponsorrelationer må holdes tydelig adskilt fra faglig styring.

---

# Del XII — Transparens overfor brukeren

## 48. Brukeren skal kunne forstå statusen til informasjonen

For klinisk relevante claims skal Antidep kunne vise:

- hva Antidep konkluderer
- evidenssikkerhet/usikkerhet
- når innholdet sist ble faglig vurdert
- sentrale kilder
- hvorfor kildene støtter eller motsier påstanden

## 49. Revieweridentitet

Internt skal navngitt reviewer lagres for alle formelle human reviews.

Offentlig visning kan bruke:

- navn
- rolle/fagområde
- eller en redaksjonell gruppe

avhengig av valgt personvern- og organisasjonsmodell.

Det må likevel internt være mulig å fastslå hvem som faktisk godkjente hva.

## 50. KI-bruk skal ikke fremstilles som menneskelig forfatterskap

Antidep skal være transparent om at KI brukes i innholdsproduksjon og kvalitetskontroll.

Det viktigste for brukeren er ikke modellnavnet ved hver setning, men at systemet tydelig beskriver:

- hvilke oppgaver KI utfører
- hvilke kontroller som finnes
- hvor menneskelig ansvar ligger

---

# Del XIII — Intended purpose og regulatorisk governance

## 51. Tiltenkt formål skal være et eksplisitt styrt dokument

Antidep skal ha en versjonert formulering av produktets tiltenkte formål.

Betydelige funksjonsendringer skal vurderes opp mot dette formålet før lansering.

## 52. Pasientspesifikke behandlingsanbefalinger er en governance-gate

Før Antidep går fra generell kunnskapsstøtte til funksjoner som kombinerer konkrete pasientdata med algoritmisk anbefaling om valg, dose, bytte eller stopp, skal prosjektet gjøre en eksplisitt regulatorisk og klinisk risikovurdering.

Denne vurderingen skal ikke erstattes av teksten «kun til informasjon» dersom funksjonen reelt gir individuell klinisk beslutningsstøtte.

## 53. Regulatorisk vurdering skal revideres ved funksjonsendringer

Eksempler på triggere:

- ny pasientspesifikk input
- ny algoritmisk anbefaling
- automatisk behandlingsrangering
- endret målgruppe
- direkte integrasjon i klinisk arbeidsflyt
- ny bruk av helseopplysninger

---

# Del XIV — Kvalitetsmåling

## 54. Governance skal måles, ikke bare beskrives

Antidep bør følge indikatorer som:

- andel publiserte claims med komplett evidensproveniens
- andel EvidenceItems med uavhengig verifikasjon
- feilrate i KI-ekstraksjon
- andel publisert innhold som er review-overdue
- tid fra sikkerhetsflagg til triage
- antall vesentlige korreksjoner
- andel claims der kilde–claim-støtte avvises av verifier
- inter-reviewer agreement på utvalgte oppgaver
- falsk sikkerhet: tilfeller der «ukjent» feilaktig ble presentert som lav risiko/ingen effekt

## 55. Kvalitetsmål skal ikke skape feil insentiver

Eksempler:

- færre korreksjoner er ikke nødvendigvis bedre dersom det betyr at feil ikke rapporteres
- høy publiseringstakt er ikke et kvalitetsmål i seg selv
- mange kilder betyr ikke høy evidenssikkerhet

---

# Del XV — Praktisk MVP-governance

## 56. Minimumsroller ved første publiserte versjon

Antidep bør minst ha:

- én eller flere Editors
- minst én kvalifisert Clinical Reviewer
- definert Publisher-funksjon
- definert Clinical Lead
- definert ansvar for evidensmetodikk

I en liten oppstartsgruppe kan samme person inneha flere roller, men systemet skal fortsatt logisk skille handlingene.

Det redaksjonelle arbeidet foran den kliniske godkjenningen — kildesøk, ekstraksjon,
kontroll av ekstraksjonen, påstandsformulering, motprøving og kildestøttekontroll — utføres
normalt av agenter med hver sin identitet, ikke av mennesker. Kravet om at handlingene skal
skilles logisk, er derfor ikke svakere når aktørene er maskiner: det er strengere, fordi
skillet er håndhevet i databasen framfor å hvile på at to personer holder oppgavene fra
hverandre.

## 57. Minimumsgates for MVP

Før første publisering av en evidenssyntese:

```text
source registered
→ EvidenceItems extracted
→ extraction verified
→ claim drafted
→ contradictory evidence considered
→ evidence assessment completed
→ claim/source support verified
→ human clinical review approved
→ publish transaction
```

Før første publisering av en klinisk regel:

```text
rule specification
→ evidence/rationale linked
→ clinical review
→ deterministic tests
→ edge-case tests
→ explicit rule version
→ publish transaction
```

## 58. Ingen masseskalering før kvalitet er demonstrert

Agentpipen skal først valideres på et representativt mindre sett antidepressiver og kliniske temaer.

Før automatiseringen skaleres til hele kunnskapsbasen bør Antidep dokumentere at den faktisk finner, ekstraherer og verifiserer evidens med akseptabel feilrate.

---

# Del XVI — Endring av governance

## 59. Governance-dokumentet er versjonert

Endringer i:

- godkjenningskrav
- roller
- høyrisikodefinisjoner
- review-policy
- KI-publiseringsgrenser
- konflikthåndtering

skal gjennomgås som styringsendringer, ikke tilfeldige admin-innstillinger.

## 60. Governance kan bli strengere uten datamigrering

Datamodellen bør bevare nok provenance og reviewhistorikk til at Antidep senere kan skjerpe kravene uten å miste kunnskap om tidligere beslutninger.

---

# Del XVII — Ikke-forhandlingsbare governance-invarianter

1. **KI alene publiserer ikke klinisk høyrisikoinnhold.**
2. **Ingen godkjenning gjelder automatisk for en senere revisjon.**
3. **Kliniske anbefalinger skilles eksplisitt fra beskrivende fakta og evidenssynteser.**
4. **Motstridende evidens og faglig uenighet slettes ikke for å gjøre UI-et penere.**
5. **Publisering og faglig godkjenning er separate hendelser.**
6. **Vesentlige feil rettes med ny historikk, ikke silent overwrite.**
7. **Høyrisikoinnhold kan avpubliseres raskt ved rimelig sikkerhetsmistanke.**
8. **Review-krav øker med klinisk risiko.**
9. **Autoritative kilder er eksplisitt definert per datadomene.**
10. **Fravær av evidens er en gyldig konklusjonstilstand.**
11. **Administrative rettigheter gir ikke automatisk faglig autoritet.**
12. **Interessekonflikter skal håndteres transparent.**
13. **Regulatorisk vurdering skjer før funksjonen blir mer pasientspesifikk, ikke etterpå.**
14. **Governance-kvalitet skal kunne evalueres med data.**

---

## 61. Neste steg

Dette dokumentet og `PRODUCT_INFORMATION_ARCHITECTURE.md` fullfører den viktigste pre-implementation-arkitekturen.

Deretter bør prosjektet gå over til:

1. konkret MVP-scope
2. første PostgreSQL/Supabase-migrasjoner
3. første admin- og review-workflow
4. en liten end-to-end evidenspipeline
5. først deretter bred innholdsproduksjon

---

## 62. Eksternt faglig og regulatorisk grunnlag

Denne versjonen er blant annet informert av:

- WHO: *Ethics and governance of artificial intelligence for health* og senere veiledning om generativ/multimodal KI i helse
- Helsedirektoratet: *Regelverket for utvikling av kunstig intelligens*, inkludert klinisk beslutningsstøtte
- Direktoratet for medisinske produkter: veiledning om programvare som medisinsk utstyr
- GRADE-prinsipper for eksplisitt vurdering av evidenssikkerhet

Relevante primærkilder:

- https://www.who.int/publications/i/item/9789240029200
- https://www.who.int/publications/i/item/9789240084759
- https://www.helsedirektoratet.no/rundskriv/regelverket-for-utvikling-av-kunstig-intelligens
- https://www.dmp.no/medisinsk-utstyr/utvikling-og-produksjon/programvare-som-medisinsk-utstyr
- https://www.gradeworkinggroup.org/

Regelverk og myndighetsveiledning skal kontrolleres på nytt før Antidep lanserer funksjoner som kan kvalifisere som medisinsk utstyr eller behandler pasientspesifikke helseopplysninger.
