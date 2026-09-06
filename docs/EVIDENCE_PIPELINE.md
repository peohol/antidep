# Antidep Evidence Pipeline

**Versjon:** 0.1  
**Dato:** 18. august 2026  
**Status:** Første prosesspesifikasjon  
**Styrende dokumenter:** [`ANTIDEP_CONSTITUTION.md`](./ANTIDEP_CONSTITUTION.md) og [`KNOWLEDGE_MODEL.md`](./KNOWLEDGE_MODEL.md)

## 1. Formål

Dette dokumentet definerer hvordan Antidep skal gå fra et informasjonsbehov til publisert, sporbar og faglig kontrollert kunnskap.

Det beskriver **arbeidsflyt, kontrollporter, agentroller og menneskelig godkjenning**. Det beskriver ikke et konkret databaseskjema, en bestemt KI-modell, en bestemt søkemotor eller en bestemt kjøreplattform.

Pipeline-arkitekturen skal gjøre det mulig å:

- oppdage relevante kilder systematisk
- vurdere om kilder er relevante og egnede
- hente ut konkrete evidensfunn med presis proveniens
- formulere atomiske påstander
- lete aktivt etter motstridende eller manglende evidens
- gradere usikkerhet eksplisitt
- kontrollere at sitater faktisk støtter påstandene
- kreve riktig nivå av menneskelig faglig godkjenning
- publisere uten å miste historikk
- oppdatere kunnskapen når nye data kommer
- rekonstruere i ettertid hvorfor Antidep sa det systemet sa på et bestemt tidspunkt

---

## 2. Normative begreper

I dette dokumentet betyr:

- **SKAL**: krav som ikke skal brytes uten eksplisitt endring av pipeline-spesifikasjonen eller et overordnet styringsdokument.
- **BØR**: sterk standard som kan fravikes når begrunnelsen dokumenteres.
- **KAN**: tillatt, men ikke påkrevd.

---

# Del I — Grunnprinsipper

## 3. Pipeline-invarianter

Følgende regler gjelder uavhengig av teknisk implementasjon.

### 3.1 Ingen direkte vei fra søk til publisering

Et agentfunn eller søkeresultat skal aldri gå direkte til publisert klinisk innhold.

Minimumsstrukturen for evidensbasert kunnskap er:

```text
informasjonsbehov
  ↓
søke-/kildeplan
  ↓
kildesøk
  ↓
kildeutvelgelse
  ↓
evidensekstraksjon
  ↓
uavhengig ekstraksjonskontroll
  ↓
påstandsforslag
  ↓
aktiv motbevis-/konfliktsøk
  ↓
evidensvurdering
  ↓
kildestøttekontroll
  ↓
menneskelig faglig vurdering
  ↓
publisering
  ↓
overvåking og revurdering
```

Enkelte deterministiske fakta kan følge et kortere spor, men skal fortsatt ha autoritativ kilde, validering, proveniens og versjonering.

### 3.2 Generering og verifikasjon skal være separate operasjoner

En agent eller prosess som oppretter et klinisk relevant objekt SKAL ikke alene kunne gi objektet endelig verifikasjonsstatus.

Dette innebærer ikke nødvendigvis at ulike modellleverandører må brukes. Det innebærer at verifikasjonen skal være en separat kjøring med separat oppgave, separat kontekst og eksplisitt mulighet til å avvise resultatet.

### 3.3 Verifikasjon skal bruke originalmaterialet

Verifikatorer SKAL kontrollere mot den opprinnelige tilgjengelige kilden eller en verifiserbar representasjon av den, ikke bare mot et sammendrag produsert av en tidligere agent.

### 3.4 Kildemengde er ikke evidenssikkerhet

Antall kilder skal aldri brukes alene som mål på hvor sikkert et utsagn er.

Pipeline skal holde minst følgende begreper adskilt:

- kildens troverdighet og metodiske kvalitet
- kildens relevans for det konkrete spørsmålet
- det enkelte evidensfunnets presisjon og begrensninger
- konsistens mellom evidensfunn
- samlet sikkerhet i evidensgrunnlaget
- klinisk betydning

### 3.5 Fravær av funn er ikke funn av fravær

Hvis pipeline ikke finner egnet evidens, skal sluttstatus kunne være **ingen vurderbar evidens** eller **utilstrekkelig evidens**.

Dette skal aldri automatisk oversettes til:

- ingen effekt
- ingen forskjell
- lav risiko
- ingen interaksjon
- trygg bruk

### 3.6 Negative og motstridende funn skal bevares

En kilde eller et evidensfunn skal ikke forkastes fordi resultatet strider mot eksisterende Antidep-innhold eller et foreløpig agentforslag.

### 3.7 Proveniens skal følge data gjennom hele kjeden

Hvert prosessledd SKAL kunne spores tilbake til:

- inputobjektene
- aktøren eller agenten
- modell og modellversjon når KI brukes
- prompt-/pipelineversjon når relevant
- tidspunkt
- programvare-/regelversjon når deterministisk behandling brukes
- outputobjektene
- avvik, varsler og menneskelige overstyringer

### 3.8 Eksternt innhold er data, ikke instruksjoner

Forskningsartikler, nettsider, PDF-er, metadata, vedlegg og andre kilder skal alltid behandles som **potensielt utrygt eksternt innhold**.

Instruksjoner som finnes inne i en kilde — for eksempel tekst som forsøker å få en agent til å endre oppgave, avsløre hemmeligheter, kjøre kode eller ignorere Antideps regler — SKAL ignoreres som instruksjoner.

Pipeline-agenter skal aldri få myndighet til å utføre kildeinnhold som kode eller kommandoer.

---

# Del II — Flere pipelinespor

## 4. Én kunnskapsbase, flere behandlingsspor

Antidep skal ikke tvinge alle kunnskapstyper gjennom identisk arbeidsflyt.

Minst fire spor skal kunne eksistere.

## 4.1 Spor A — Autoritative deterministiske fakta

Brukes når en opplysning kan hentes direkte fra en definert autoritativ strukturert kilde.

Eksempler:

- norske handelsnavn
- tilgjengelige styrker
- legemiddelform
- ATC-kode
- markedsstatus
- enkelte preparatspesifikke egenskaper

Typisk prosess:

```text
autoritativ kilde
  ↓
deterministisk import
  ↓
skjemavalidering
  ↓
endringsdeteksjon
  ↓
publisering eller review-kø ved relevante endringer
```

Dette sporet BØR bruke deterministisk behandling fremfor språkmodell når kildeformatet gjør det mulig.

KI KAN brukes til å oppdage avvik eller foreslå mapping, men skal ikke være nødvendig for å kopiere et entydig strukturert faktum.

## 4.2 Spor B — Evidensbaserte synteser

Brukes for spørsmål som krever fortolkning av forskning på tvers av én eller flere kilder.

Eksempler:

- relativ effekt
- risiko for seksuell dysfunksjon
- vektendring
- sedasjon
- seponeringsproblemer
- QT-effekter
- bruk ved bestemte komorbiditeter

Dette sporet skal normalt følge hele evidenspipelinen.

## 4.3 Spor C — Kliniske anbefalinger

Brukes for normative utsagn om hva klinikeren bør vurdere eller gjøre.

Anbefalingssporet SKAL bygge på allerede vurdert evidens og eventuelle eksplisitte retningslinjer eller regulatoriske kilder.

En klinisk anbefaling skal aldri opprettes bare fordi en språkmodell mener den «virker rimelig».

Dette sporet har strengest krav til menneskelig faglig godkjenning.

## 4.4 Spor D — Kuraterte kildeområder

Enkelte temaer eller felt KAN konfigureres slik at Antidep bare får bruke et forhåndsdefinert sett av manuelt godkjente kilder.

Eksempler kan være områder der redaksjonen vil styre kunnskapsgrunnlaget strengt, eller der en spesifikk norsk myndighetskilde skal være normerende for et bestemt faktum.

Pipeline skal derfor støtte en eksplisitt `SourcePolicy` eller tilsvarende prosessregel med minst følgende moduser:

- `open_discovery` — agenten kan lete etter nye kilder
- `approved_sources_only` — bare forhåndsgodkjente kilder kan brukes
- `authoritative_source_only` — ett definert kildesystem er normerende
- `manual_only` — ingen automatisk opprettelse eller endring av faglig innhold

Kildepolicy skal være versjonert og knyttet til tema eller kunnskapsområde.

---

# Del III — Arbeidsenheten

## 5. `EvidenceWorkUnit`

Pipeline bør ha et eksplisitt arbeidsobjekt som representerer ett avgrenset kunnskapsoppdrag. Det omtales her konseptuelt som `EvidenceWorkUnit`.

Eksempler:

- «Vurder korttidsrisiko for vektøkning med mirtazapin hos voksne med depressiv lidelse.»
- «Oppdater kunnskapen om sertralin og hyponatremi hos eldre.»
- «Finn ut om venlafaksin har høyere seponeringsrisiko enn sertralin.»

### 5.1 Minimumsinnhold

En arbeidsenhet BØR spesifisere:

- `work_unit_id`
- tema / `ClinicalConcept`
- berørte virkestoffer
- kunnskapstype
- populasjon
- intervensjon/eksponering
- komparator når relevant
- utfall
- tidsramme
- geografisk/regulatorisk kontekst når relevant
- kildepolicy
- ønsket evidenstype
- eksplisitte inklusjonskriterier
- eksplisitte eksklusjonskriterier
- risikonivå
- opprettet av
- tidspunkt
- pipelineversjon

### 5.2 Hvorfor arbeidsenheten er nødvendig

Uten et eksplisitt spørsmål kan et kildesøk bli retrospektivt tilpasset det agenten tilfeldigvis finner.

Arbeidsenheten skal derfor etableres **før** systematisk søk og syntese, slik at det er mulig å se om:

- søket dekket spørsmålet
- kildene faktisk er relevante
- utfallet ble endret underveis
- populasjonen ble utvidet uten begrunnelse
- agenten svarte på et annet spørsmål enn det som var bestilt

---

# Del IV — Fase 1: Planlegging

## 6. Avgrens spørsmålet før søk

For forskningsbaserte synteser skal arbeidsenheten så langt relevant struktureres etter komponenter som:

- populasjon
- intervensjon eller eksponering
- komparator
- utfall
- tidsramme
- studiedesign

Ikke alle spørsmål passer rent inn i PICO. Pipeline skal kunne bruke andre eksplisitte rammer når det passer bedre, men spørsmålet skal uansett være operasjonalisert før søket starter.

## 7. Klassifiser spørsmålet

Før kildeleting skal pipeline identifisere hvilken type spørsmål det gjelder, fordi dette påvirker hvilke kilder og studiedesign som er relevante.

Eksempler:

- effekt
- bivirkning/skade
- farmakokinetikk
- farmakodynamikk
- interaksjon
- dose–respons
- seponering
- graviditet/amming
- pediatri
- geriatri
- organfunksjon
- overdose/toksisitet
- markeds-/produktopplysning
- klinisk anbefaling

## 8. Lag en eksplisitt søkeplan

Søkeplanen SKAL kunne dokumentere:

- hvilke kildetyper som skal prioriteres
- hvilke databaser eller kildesystemer som skal brukes når relevant
- søkestrenger eller søkekonsepter
- dato for søket
- eventuelle tidsbegrensninger
- språkbegrensninger og begrunnelse
- studiedesignbegrensninger
- hvilke registre eller regulatoriske kilder som skal undersøkes
- hvem/hvilken agent som utførte søket

Søket BØR prioritere sensitivitet når formålet er å etablere eller oppdatere et samlet evidensgrunnlag. Søkeprosessen skal være reproducerbar så langt kildesystemene tillater det.

---

# Del V — Fase 2: Kildeoppdagelse og kildehåndtering

## 9. Discovery-agentens rolle

Discovery-agenten skal finne **kandidatkilder**. Den skal ikke avgjøre den endelige Antidep-påstanden.

### Discovery-agenten KAN

- søke databaser og nettressurser som kildepolicyen tillater
- følge referanser og siteringer
- finne systematiske oversikter, retningslinjer og primærstudier
- identifisere nyere forskning som kan endre en eldre syntese
- finne regulatoriske meldinger, preparatomtaler og relevante offentlige data
- foreslå at et spørsmål trenger en utvidet søkestrategi

### Discovery-agenten SKAL IKKE

- publisere
- gradere endelig evidenssikkerhet
- skjule kilder som strider mot forventet konklusjon
- bruke søkemotorens sammendrag som erstatning for kilden
- fremstille manglende fulltekst som om fulltekst var lest

## 10. Søk etter flere rapporter fra samme studie

Pipeline skal skille mellom **studie** og **rapport**.

Én klinisk studie kan være representert av:

- hovedpublikasjon
- sekundæranalyse
- konferanseabstract
- registeroppføring
- protokoll
- korreksjon
- regulatorisk rapport
- langtidsoppfølging

Rapporter fra samme studie BØR kobles til en felles studieidentitet når dette kan avgjøres pålitelig.

Dette reduserer risikoen for at samme deltakergrunnlag telles flere ganger som uavhengig evidens.

## 11. Deduplisering

Kandidatkilder skal dedupliseres ved hjelp av stabile identifikatorer der de finnes, for eksempel DOI, PMID, register-ID eller dokument-ID.

Tittel-/forfattermatching KAN brukes som sekundær metode, men automatisk fuzzy matching skal kunne markeres som usikker og sendes til kontroll.

## 12. Kildeversjoner, korreksjoner og tilbaketrekkinger

Pipeline SKAL kunne registrere at en kilde er:

- korrigert
- oppdatert
- erstattet
- trukket tilbake
- uttrykt bekymring om
- utdatert i regulatorisk forstand

En slik statusendring skal kunne trigge revurdering av alle avhengige `EvidenceItem`, `ClaimRevision`, `EvidenceAssessment`, `Recommendation` og `ClinicalRule`.

## 13. Fulltekststatus skal være eksplisitt

For hver kilde skal pipeline vite om vurderingen bygger på:

- fulltekst
- abstrakt
- registerdata
- regulatorisk sammendrag
- sekundær omtale
- annen begrenset representasjon

Agenten skal aldri beskrive kildeinnhold som ikke faktisk var tilgjengelig i kjøringen.

Manglende fulltekst kan være grunn til å stoppe eller nedgradere en vurdering, avhengig av spørsmålet.

## 14. Opphavsrett og lagring

Bibliografiske metadata, evidensobjekter og egne strukturerte ekstraksjoner skal kunne lagres uavhengig av om Antidep har rett til å redistribuere selve fullteksten.

Pipeline skal ikke anta at tilgang til en artikkel gir rett til offentlig videredistribusjon av hele innholdet.

---

# Del VI — Fase 3: Kildeutvelgelse og kvalitetsvurdering

## 15. Relevans og kvalitet vurderes separat

En metodisk god studie kan være irrelevant for det konkrete spørsmålet. En svært relevant studie kan samtidig ha betydelig risiko for bias.

Pipeline skal derfor ikke ha ett enkelt felt kalt «source_quality» som forsøker å oppsummere alt.

Minst følgende dimensjoner skal kunne vurderes separat:

- relevans for arbeidsenheten
- studiedesign
- risiko for bias / metodiske begrensninger
- direktehet
- datakompletthet
- kilde-/rapportstatus
- eventuell interessekonflikt eller sponsing når relevant

## 16. Inklusjon og eksklusjon skal begrunnes

For kandidatkilder som når fulltekst- eller tilsvarende vurderingsnivå, BØR pipeline lagre en strukturert beslutning:

- `included`
- `excluded`
- `awaiting_classification`
- `ongoing`
- `incomplete`

Ekskluderte kilder skal ha en kort, eksplisitt begrunnelse.

Pipeline skal ikke slette spor etter en kilde bare fordi den ble ekskludert.

## 17. Hierarki skal ikke bli blind autoritet

Systematiske oversikter og gode retningslinjer kan være effektive startpunkter, men pipeline skal ikke anta at de alltid er nyere, mer direkte eller mer relevante enn primærdata.

Ved viktige spørsmål skal pipeline blant annet vurdere:

- når søket i oversikten ble avsluttet
- om nyere studier finnes
- om oversiktens populasjon og utfall matcher Antideps spørsmål
- om samme studiegrunnlag gjenbrukes i flere oversikter
- om konklusjonen er påvirket av manglende evidens

---

# Del VII — Fase 4: Evidensekstraksjon

## 18. Extraction-agentens rolle

Extraction-agenten skal transformere rapportert informasjon til strukturerte `EvidenceItem`.

Den skal **ikke** forsøke å skrive ferdig monografitekst.

## 19. Ekstraksjonen skal ligge tett på kilden

Et `EvidenceItem` skal gjengi hva kilden faktisk rapporterer med minst mulig syntetisk fortolkning.

Eksempel:

Hvis kilden rapporterer:

- RR 1,42
- 95 % KI 1,10–1,84
- 8 ukers oppfølging

skal dette lagres som strukturerte data dersom feltene er relevante og tilgjengelige, i stedet for at agenten bare skriver «risikoen var noe økt».

## 20. Råverdi og normalisert verdi

Når Antidep normaliserer:

- enheter
- prosenter
- doser
- tidsangivelser
- virkestoffnavn
- utfallskoder

skal den opprinnelig rapporterte verdien kunne bevares sammen med den normaliserte representasjonen og transformasjonsregelen.

Normalisering skal ikke gjøre originaldata urekonstruerbare.

## 21. Numeriske data krever særskilt kontroll

Tallfeil kan endre klinisk mening betydelig.

For klinisk viktige numeriske felter BØR pipeline bruke minst én separat kontrollmekanisme, for eksempel:

- ny ekstraksjon av en uavhengig agent
- deterministisk parser når tabellformatet tillater det
- eksplisitt sammenligning mot kildeområdet
- menneskelig kontroll for høyrisikoopplysninger

Avvik mellom to ekstraksjoner skal ikke løses ved å velge gjennomsnittet eller den mest plausible verdien; kilden skal undersøkes på nytt.

## 22. Tabeller og figurer

Når resultatet bare finnes i tabell eller figur, skal dette fremgå av proveniensen.

Grafisk avleste tall skal merkes som avledede/estimerte og skal ikke fremstilles med større presisjon enn figuren tillater.

## 23. Effektmål skal ikke blandes ukritisk

Pipeline skal bevare hvilket effektmål kilden brukte.

RR, OR, HR, RD, MD, SMD og andre mål skal ikke presenteres som direkte utskiftbare uten eksplisitt transformasjon eller syntesemetode.

## 24. Manglende data er et eksplisitt resultat

Hvis et ønsket felt ikke rapporteres, skal agenten kunne returnere `not_reported` eller tilsvarende fremfor å gjette.

`not_reported`, `not_applicable`, `not_accessible` og `unclear` BØR være forskjellige tilstander.

---

# Del VIII — Fase 5: Verifikasjon av ekstraksjon

## 25. Extraction-verifier

En separat verifikator skal kontrollere `EvidenceItem` mot kildegrunnlaget.

Kontrollen BØR minst dekke:

- riktig kilde
- riktig studie/populasjon
- riktig intervensjon og komparator
- riktig utfall
- riktig tidspunkt
- riktige numeriske verdier
- riktig fortegn/retning
- riktig konfidensintervall eller annen usikkerhet
- riktig tabell/figur/avsnitt
- at agenten ikke har fylt inn ikke-rapporterte data
- at begrensninger som endrer tolkningen er fanget opp

`ExtractionVerifier` (§61) registrerer resultatet gjennom `api.register_extraction_verification(...)`, som krever at kalleren er autentisert nøyaktig for agentrollen `extraction_verification` og handler inne i en åpen kjøring i samme rolle (DATABASE_ARCHITECTURE.md §29, §33). Skriveveien håndhever ikke selv om kontrollen faktisk dekket punktene over — det er verifikatorens ansvar — men den kan ikke registrere en kontroll av et evidensfunn den selv produserte, uansett agentkjøring.

## 26. Verifikasjonsstatus

Et evidensfunn skal minst kunne ha status:

- `unverified`
- `verified`
- `verified_with_caveat`
- `rejected`
- `needs_human_review`

Bare evidens som har nådd nødvendig kontrollnivå skal kunne brukes til publiserbar syntese.

---

# Del IX — Fase 6: Påstandsdannelse

## 27. Claim-agentens rolle

Claim-agenten skal bruke verifiserte `EvidenceItem` til å foreslå:

- nytt `Claim`
- ny `ClaimRevision`
- oppdatering av eksisterende påstand
- eksplisitt status «utilstrekkelig evidens»
- behov for ytterligere søk

Agenten skal ikke ha publiseringsmyndighet.

## 28. Atomisitet

Claim-agenten skal dele sammensatte utsagn når delene kan ha forskjellig evidensgrunnlag eller sikkerhet.

Påstander om eksempelvis effekt, vekt, seksuell funksjon og anbefalt valg skal ikke slås sammen bare fordi de omtaler samme legemiddel.

## 29. Scope skal være eksplisitt

Agenten skal ikke generalisere utover evidensen uten at dette markeres som en egen inferens.

Eksempler på ulovlig taus utvidelse:

- voksne → alle aldersgrupper
- depresjon → alle indikasjoner
- 6–8 uker → langtidsbehandling
- én dose → hele terapeutisk doseområde
- surrogatendepunkt → klinisk utfall
- klasseeffekt → alle enkeltstoffer

Hvis en generalisering vurderes rimelig, skal den være eksplisitt og få egen usikkerhetsvurdering.

## 30. Påstandsteksten skal uttrykke evidensens presisjon

Språket skal reflektere hvor sikkert og hvor stort funnet er.

Pipeline skal motvirke at agenten automatisk omskriver:

- statistisk signifikant → klinisk viktig
- ikke-signifikant → ingen forskjell
- assosiasjon → kausal effekt
- numerisk forskjell → dokumentert forskjell
- observasjonsdata → sikker årsakssammenheng

---

# Del X — Fase 7: Aktiv motprøving

## 31. Adversarial-agentens mandat

Før en ny eller vesentlig endret evidenssyntese kan godkjennes, skal en separat agent/prosess forsøke å vise at foreløpig konklusjon er feil, overdrevet eller for generell.

Oppgaven er ikke å være «balansert» for balansens skyld. Oppgaven er å lete etter reelle svakheter.

## 32. Minimumsspørsmål ved motprøving

Adversarial-agenten BØR spørre:

- Finnes det høykvalitetskilder med motsatt konklusjon?
- Finnes nyere evidens som endrer bildet?
- Er viktige nullfunn eller skadefunn utelatt?
- Finnes upubliserte eller registerførte data som tyder på selektiv publisering?
- Er samme studie telt flere ganger via ulike rapporter eller metaanalyser?
- Er populasjon, dose eller tidsramme indirekte?
- Er effekten drevet av én studie?
- Er konfidensintervallene for brede til den foreslåtte formuleringen?
- Er endepunktet klinisk relevant?
- Er det tegn til selektiv resultatrapportering?
- Har en kilde blitt korrigert eller trukket tilbake?
- Har agenten oversett plausible alternative forklaringer?

## 33. Motprøving kan sende arbeidet bakover

Adversarial-fasen skal ikke bare produsere en kommentar.

Den skal kunne utløse:

- nytt kildesøk
- ny kildevurdering
- ny ekstraksjon
- endret scope
- splitting av en påstand
- svakere formulering
- lavere evidenssikkerhet
- `insufficient_evidence`
- avvisning av påstanden

---

# Del XI — Fase 8: Samlet evidensvurdering

## 34. `EvidenceAssessment`

Samlet vurdering skal foregå på nivået til det konkrete kliniske spørsmålet/utfallet, ikke som en generell stjernekarakter for et legemiddel eller en artikkel.

## 35. GRADE når det er egnet

For spørsmål der GRADE-rammeverket passer, skal Antidep kunne representere minst:

- risiko for bias
- inkonsistens
- indirekthet
- upresisjon
- publikasjons-/manglende-evidensbias
- eventuell oppgradering der metodikken tillater det
- eksplisitt begrunnelse for hver vurdering
- samlet sikkerhet: høy, moderat, lav eller svært lav

`ingen vurderbar evidens` skal være en separat tilstand og ikke en femte GRADE-grad.

## 36. Ikke alle spørsmål skal tvinges inn i GRADE

Farmakokinetiske fakta, regulatoriske data, interaksjonsmekanismer og andre kunnskapstyper kan kreve andre vurderingsrammer.

Hvis Antidep bruker en annen metode, skal metoden være eksplisitt, dokumentert og versjonert.

Et universelt egenlaget «evidensscore»-tall BØR unngås dersom tallet skjuler ulike typer usikkerhet.

## 37. Absolutt og relativ effekt

Når det er metodisk forsvarlig og klinisk relevant, BØR syntesen bevare både relative og absolutte effektmål.

Et relativt mål skal ikke presenteres visuelt på en måte som får en liten absolutt forskjell til å se stor ut.

## 38. Klinisk relevans er ikke det samme som statistisk evidens

Pipeline skal holde adskilt:

- størrelse på estimert effekt
- statistisk usikkerhet
- evidenssikkerhet
- klinisk betydning

Det kan finnes relativt sikker evidens for en liten effekt og svært usikker evidens for en mulig stor effekt.

---

# Del XII — Fase 9: Kildestøtteverifikasjon

## 39. Citation-verifier

Før publisering skal en separat verifikator kontrollere relasjonen mellom den foreslåtte `ClaimRevision` og hvert tilknyttet `EvidenceItem`/`Source`.

Spørsmålet er:

> Støtter denne kilden faktisk denne konkrete påstanden slik den er formulert?

## 40. Relasjonstype skal kontrolleres

Verifikatoren skal kunne godkjenne eller endre relasjonen til for eksempel:

- `supports`
- `partially_supports`
- `contradicts`
- `indirect`
- `context_only`

En kilde skal ikke stå som `supports` bare fordi den nevner samme legemiddel eller tema.

## 41. Vanlige feil som skal fanges

Citation-verifier skal spesielt lete etter:

- feil populasjon
- feil komparator
- feil tidspunkt
- feil dose
- sekundært endepunkt fremstilt som primært
- subgruppe fremstilt som hovedresultat
- observasjon fremstilt som randomisert evidens
- abstraktkonklusjon som ikke samsvarer med resultattabellen
- kilde som bare støtter én del av et sammensatt utsagn
- tall som er korrekt kopiert, men feil fortolket
- konklusjon fra oversiktsforfattere fremstilt som direkte studiedata

---

# Del XIII — Fase 10: Kliniske anbefalinger

## 42. Anbefalinger skal være downstream av evidensen

En `clinical_recommendation` skal så langt mulig vise hvilke evidenssynteser, retningslinjer, regulatoriske krav og andre premisser den bygger på.

Pipeline skal ikke blande «hva forskning viser» og «hva klinikeren bør gjøre» i samme usporbare tekstobjekt.

## 43. Anbefalingen skal synliggjøre verdidommer

Når anbefalingen avhenger av avveininger, skal disse kunne identifiseres.

Eksempler:

- effekt versus bivirkninger
- symptomlindring versus seponeringsbelastning
- liten gjennomsnittlig gevinst versus alvorlig sjelden risiko
- enkel dosering versus interaksjonspotensial
- evidensstyrke versus praktisk gjennomførbarhet

## 44. Pasientspesifikke anbefalinger er et særskilt risikonivå

En funksjon som kombinerer individuelle pasientdata med regler eller modeller og foreslår legemiddelvalg, dose, bytte eller nedtrapping skal ikke oppstå som en utilsiktet utvidelse av denne pipelinen.

Slik funksjonalitet krever særskilt spesifikasjon, validering, regulatorisk vurdering og klinisk sikkerhetsarbeid før produksjonssetting.

---

# Del XIV — Fase 11: Menneskelig faglig kontroll

## 45. KI kan forberede; kvalifiserte mennesker godkjenner

Menneskelig gjennomgang skal være en reell kontrollport, ikke bare et klikk som forventes å bekrefte agentens forslag.

Review-UI skal derfor vise nok av det underliggende materialet til at redaktøren kan vurdere påstanden.

## 46. Minimumsinformasjon til reviewer

For en evidenssyntese BØR reviewflaten vise:

- foreslått formulering
- strukturert scope
- evidenssikkerhet og begrunnelse
- alle støttende evidensobjekter
- motstridende evidens
- relevante ekskluderte/avventende kilder når dette påvirker tolkningen
- adversarial-rapport
- citation-verification
- endring fra forrige publiserte revisjon
- hvem/hvilken agent som har produsert hvert ledd

## 47. Reviewer skal kunne gjøre mer enn å godkjenne

Revieweren skal kunne:

- godkjenne
- redigere
- avvise
- sende tilbake til et spesifikt pipelineledd
- kreve nytt søk
- endre evidensvurdering med begrunnelse
- endre relasjonen mellom påstand og kilde
- markere konflikt eller usikkerhet
- slå sammen duplikater
- splitte en for bred påstand

Menneskelige overstyringer skal logges med begrunnelse.

---

# Del XV — Risikobasert godkjenning

## 48. Kontrollnivået skal følge potensiell konsekvens

Ikke alle innholdsendringer krever samme kontrollbyrde.

Antidep BØR ha en eksplisitt risikoklassifisering for faglige objekter og endringer.

### 48.1 Eksempel på risikonivåer

#### Lavere risiko

- bibliografiske metadata
- kosmetisk språk uten meningsendring
- ikke-kliniske taksonomirettelser

#### Moderat risiko

- evidenssyntese om vanlige bivirkninger
- endring i effektstørrelse
- endring i vurdert evidenssikkerhet

#### Høy risiko

- dosering
- kontraindikasjon
- alvorlige bivirkninger
- graviditet/amming
- interaksjoner med mulig alvorlig konsekvens
- seponerings- og bytteregler
- kliniske anbefalinger
- beslutningsstøtte

## 49. Høyrisikoendringer

Høyrisikoendringer SKAL kreve eksplisitt godkjenning fra kvalifisert fagperson før publisering.

Pipeline KAN senere kreve to-uavhengige-reviewere for særskilte typer innhold, men dette skal i så fall defineres eksplisitt og ikke antas generelt.

---

# Del XVI — Fase 12: Publisering

## 50. Publisering er en egen transaksjon

Godkjent innhold skal ikke bli publisert som en tilfeldig bieffekt av at et felt får riktig verdi.

Publiseringshandlingen skal eksplisitt:

- velge eksakt revisjon
- kontrollere alle obligatoriske porter
- sette publiseringstidspunkt
- registrere ansvarlig aktør
- bevare forrige publiserte revisjon
- oppdatere avhengige visninger

## 51. Publiseringsporter

En evidenssyntese skal normalt ikke kunne publiseres hvis:

- sentrale evidensobjekter er uverifiserte
- kildestøtteverifikasjon mangler
- påkrevd evidensvurdering mangler
- obligatorisk adversarial-kontroll mangler
- nødvendig menneskelig godkjenning mangler
- en sentral kilde er markert trukket tilbake uten at konsekvensen er vurdert
- påstanden har uløste alvorlige konflikter som ikke beskrives i teksten/usikkerheten

## 52. Genererte visninger skal kunne reproduseres

Når en monografi eller sammenligning vises, skal systemet kunne identifisere hvilke publiserte objektversjoner som lå til grunn.

Endring i presentasjonslaget skal ikke endre det underliggende evidensgrunnlaget.

---

# Del XVII — Oppdatering og overvåking

## 53. Antidep skal behandle kunnskapen som levende

Publisering avslutter ikke evidensprosessen.

En publisert påstand skal ha regler eller metadata for når den skal vurderes på nytt.

## 54. Revurdering kan utløses av tid eller hendelse

Mulige triggere:

- planlagt review-dato
- ny systematisk oversikt
- ny større studie
- ny regulatorisk sikkerhetsmelding
- endret preparatomtale
- nytt norsk markedsdata
- retraction/correction av en brukt kilde
- bruker-/fagpersonrapportert mulig feil
- endret retningslinje
- ny kilde som motsier eksisterende påstand
- endring i relevant metode eller klassifikasjon

## 55. Nye kilder skal kobles til berørte påstander

Når en ny kilde oppdages, skal pipeline forsøke å identifisere hvilke eksisterende arbeidsenheter, evidensvurderinger og påstander den kan påvirke.

Det skal ikke være nødvendig å «skrive hele monografien på nytt» for å oppdatere ett evidensområde.

## 56. Oppdatering skal være differensiell når mulig

Hvis et nytt evidensfunn ikke påvirker konklusjonen, kan systemet registrere at kunnskapen ble vurdert uten å endre den publiserte formuleringen.

Hvis funnet påvirker:

- effektstørrelse
- sikkerhetsgrad
- scope
- klinisk relevans
- anbefaling

skal ny `ClaimRevision` opprettes.

## 57. Utdatert-status skal være synlig internt og kunne være synlig eksternt

Hvis en påstand overskrider definert review-frist eller påvirkes av en uavklart viktig kilde, skal den kunne få status som krever ny vurdering.

For klinisk viktig kunnskap skal Antidep ikke late som innholdet er nylig kontrollert dersom det ikke er det.

---

# Del XVIII — Feiltilstander og eskalering

## 58. Pipeline skal kunne stoppe uten å produsere svar

Et robust system må kunne konkludere med at oppgaven ikke kan fullføres automatisk.

Gyldige stoppårsaker inkluderer blant annet:

- fulltekst utilgjengelig
- motstridende kilder som ikke kan avklares
- uklart studiegrunnlag
- utilstrekkelig evidens
- manglende autoritativ norsk kilde
- numeriske ekstraksjoner som ikke lar seg verifisere
- usikker kobling mellom flere rapporter og én studie
- usikker produktidentitet
- kilde med uavklart retraction/correction-status
- agentuenighet om sentrale data
- kildeformat som ikke kan tolkes sikkert

## 59. Ingen «best effort»-gjetting i kanoniske data

Best-effort-resonnement kan være nyttig for å foreslå hva en fagperson bør undersøke videre, men skal ikke konverteres til publiserte kliniske fakta uten nødvendig evidens og kontroll.

## 60. Eskaleringsobjekt

Pipeline BØR kunne opprette en eksplisitt review-/avvikssak med:

- hva som er uklart
- hvilket pipelineledd som stoppet
- hvilke objekter som er berørt
- hvilke kilder som må undersøkes
- hvilke agenter som var uenige
- anbefalt neste manuelle handling

---

# Del XIX — Agentroller og kontrakter

## 61. Agentroller

Rollene under er logiske ansvarsgrenser. De kan implementeres med ulike modeller og teknologier over tid.

Ansvarsgrensen skal samtidig være en teknisk grense: hver rolle som faktisk skriver til
kunnskapsbasen, har en egen aktør med en egen identitet og en egen legitimasjon, og
autentiseringen krever den rollen operasjonen trenger. En rolle som bare er et navn i en
prompt, er ingen grense.

| Rolle | Primær input | Primær output | Skal ikke gjøre |
|---|---|---|---|
| `QueryPlanner` | klinisk informasjonsbehov | strukturert arbeidsenhet og søkeplan | konkludere klinisk |
| `DiscoveryAgent` | arbeidsenhet + kildepolicy | kandidatkilder | publisere/syntetisere endelig |
| `SourceAssessor` | kandidatkilde | relevans-/kvalitetsvurdering | endre kildens resultater |
| `ExtractionAgent` | inkludert kilde | `EvidenceItem` | skrive endelig anbefaling |
| `ExtractionVerifier` | kilde + `EvidenceItem` | verifikasjonsrapport | godkjenne eget uttrekk |
| `ClaimAgent` | verifiserte evidensfunn | `Claim`/`ClaimRevision`-forslag | publisere |
| `AdversarialAgent` | foreløpig syntese + søkegrunnlag | motbevis-/svakhetsrapport | beskytte eksisterende konklusjon |
| `EvidenceAssessor` | samlet evidens | `EvidenceAssessment` | skjule usikkerhet |
| `CitationVerifier` | påstand + evidens + kilder | validerte relasjonstyper | bruke emnelikhet som støtte |
| `EditorialAgent` | faglig godkjent innhold | konsis presentasjonstekst | endre faglig mening uten ny review |
| `UpdateAgent` | nye kilder/endringssignaler | påvirkningsanalyse | automatisk oppdatere høyrisikokunnskap |

## 62. Strukturerte outputs

Hver agent BØR returnere strukturert output etter eksplisitt skjema i tillegg til eventuell forklarende tekst.

Hvis output ikke validerer mot skjemaet, skal kjøringen feile eller gå til reparasjonssteg; ugyldig output skal ikke stille og rolig lagres som kanoniske data.

## 63. Tillatte verktøy skal være minst mulig privilegerte

En agent skal bare ha tilgang til verktøyene den trenger for rollen.

Eksempel:

- extraction-agent trenger lesetilgang til kilde, men ikke publiseringsrett
- citation-verifier trenger kildetilgang, men ikke rett til å endre originaldata
- discovery-agent trenger søk, men ikke databaseadministrasjon

Ingen agent som leser utrygt eksternt innhold skal samtidig ha unødvendig tilgang til hemmeligheter eller destruktive systemhandlinger.

## 64. Modelluenighet skal ikke skjules

Hvis separate agenter eller verifikatorer kommer til vesentlig forskjellige resultater, skal uenigheten registreres og enten løses mot kilden eller eskaleres.

Pipeline skal ikke bruke flertallsavstemning mellom språkmodeller som erstatning for evidenskontroll.

---

# Del XX — Prompt-, modell- og pipelineversjonering

## 65. KI-generert kunnskap skal være reproduserbart attribuert

For hver vesentlig KI-operasjon BØR proveniensen kunne registrere:

- agentrolle
- modellleverandør
- modell-ID/versjon
- relevant modellkonfigurasjon
- promptmalversjon
- tilgjengelige verktøy
- pipelineversjon
- inputobjekt-ID-er
- outputobjekt-ID-er
- kjøretidspunkt

Full deterministisk reproduserbarhet kan ikke alltid garanteres for språkmodeller, men Antidep skal kunne rekonstruere **hva som ble kjørt med hvilke premisser**.

Premissene registreres per kjøring og ikke per objekt: agentrolle, leverandør, modell,
modellversjon, promptmalversjon, pipelineversjon, input, output, utfall og tidspunkter. En
kjøring uten dem skal ikke kunne registreres — et felt som kan stå tomt, står tomt akkurat i
de kjøringene det betyr mest å kunne lese i ettertid.

## 66. Modellbytte skal ikke endre kunnskapsmodellen

En overgang fra én modell eller leverandør til en annen skal i utgangspunktet være en endring i pipelinekonfigurasjon, ikke en migrering av den faglige datamodellen.

---

# Del XXI — Redaksjonell presentasjon

## 67. Redaksjonell komprimering skjer etter faglig strukturering

Antidep skal først etablere korrekt strukturert kunnskap og deretter lage kort klinikervennlig tekst.

En editorial-agent skal kunne:

- forkorte
- standardisere terminologi
- forbedre lesbarhet
- lage progressive sammendrag

Den skal ikke uten ny faglig kontroll:

- øke sikkerheten i formuleringen
- fjerne avgjørende forbehold
- endre populasjon
- endre tidsramme
- endre kausalitet
- endre tall
- konvertere evidenssyntese til anbefaling

## 68. Visuelle skalaer skal komme fra eksplisitte underliggende regler

Hvis Antidep viser for eksempel lav/moderat/høy risiko eller en visuell analog skala, skal mappingen fra kunnskapsobjekt til visning være dokumentert.

UI-et skal ikke få en språkmodell til å improvisere en skår ved render-tid.

---

# Del XXII — Manuell redaksjon

## 69. Mennesker kan initiere alle sentrale pipelineledd

Kvalifiserte redaktører skal kunne:

- legge til en kilde manuelt
- starte en ny arbeidsenhet
- knytte en kilde til et eksisterende spørsmål
- opprette eller korrigere et evidensfunn
- be om ny agentekstraksjon
- be om adversarial søk
- opprette eller endre en påstand
- endre evidensvurdering med begrunnelse
- publisere eller avpublisere
- markere innhold som trenger review

## 70. Manuell overstyring skal ikke ødelegge proveniens

Når en fagperson overstyrer KI-resultatet, skal både det opprinnelige forslaget og den endelige beslutningen kunne rekonstrueres.

Systemet skal ikke fremstille et menneskelig redigert objekt som om det fortsatt var et urørt agentresultat.

---

# Del XXIII — Kvalitetsmålinger

## 71. Pipeline-kvalitet skal måles mot konkrete feilmodi

Antidep BØR etablere et testsett av representativt kildemateriale og kliniske oppgaver for å måle pipelinekvalitet over tid.

Relevante mål inkluderer:

- recall i kildesøk for validerte testspørsmål
- feilinkludering/-ekskludering av kilder
- ekstraksjonsnøyaktighet
- numerisk ekstraksjonsnøyaktighet
- feil rate for kilde–påstand-støtte
- frekvens av manglende viktige motstridende kilder
- korrekt atomisering av påstander
- over-/underestimering av evidenssikkerhet
- andel saker som korrekt eskaleres i stedet for å gjettes
- reviewer-overstyringsrate
- feil som når publisert innhold

## 72. Testsettet skal inneholde vanskelige tilfeller

Ikke bare enkle artikler.

Det BØR inkludere:

- flere publikasjoner fra samme studie
- subgruppeanalyser
- korrigerte artikler
- trukne artikler
- brede konfidensintervaller
- ikke-signifikante resultater
- abstrakt som overdriver resultater
- tabeller med flere doser
- motstridende metaanalyser
- observasjonsstudier med tydelig konfundering
- kilder med prompt-injection-lignende tekst
- manglende fulltekst

## 73. Pipelineendringer skal regresjonstestes

Bytte av modell, prompt, ekstraksjonsskjema eller agentrekkefølge skal kunne testes mot et fast evalueringssett før endringen tas i produksjon for klinisk innhold.

---

# Del XXIV — Logging og revisjon

## 74. Audit trail

For hvert publisert klinisk objekt skal Antidep kunne rekonstruere en kjede tilsvarende:

```text
publisert ClaimRevision
  ← menneskelig godkjenning
  ← citation verification
  ← EvidenceAssessment
  ← adversarial review
  ← Claim-forslag
  ← verifiserte EvidenceItem
  ← Source
  ← discovery/search run
  ← EvidenceWorkUnit
```

## 75. Audit-logg skal være append-orientert

Historisk sporbarhet skal ikke avhenge av mutable tekstfelt som overskrives.

Korrigeringer skal opprette nye hendelser/versjoner og bevare relevante tidligere tilstander.

## 76. Loggdata skal være tilgjengelige for intern gransking

En redaktør skal kunne svare på spørsmål som:

- Hvorfor sier Antidep dette?
- Hvilke studier ligger bak?
- Hvilke studier motsier det?
- Hvem godkjente det?
- Når ble det sist kontrollert?
- Hvilken agent og modell gjorde ekstraksjonen?
- Ble påstanden endret etter menneskelig review?
- Hvilken kildeendring utløste siste revisjon?

---

# Del XXV — Sikkerhet og personvern

## 77. Ingen pasientdata er nødvendig for evidenspipelinen

Kilde- og evidenspipelinen skal ikke kreve identifiserbare pasientdata.

Testdata for fremtidige kliniske verktøy skal holdes adskilt fra evidensproduksjonen.

## 78. Hemmeligheter skal ikke eksponeres for kildemateriale

API-nøkler, tokens, databasehemmeligheter eller andre credentials skal aldri legges inn i agentkontekst der eksterne dokumenter kan påvirke modellens instruksjonsforståelse.

## 79. Eksterne filer skal behandles konservativt

Pipeline skal ikke automatisk kjøre makroer, skript, binærkode eller annen aktiv funksjonalitet fra innhentede kilder.

---

# Del XXVI — Minimum viable pipeline

## 80. MVP skal være smalere enn sluttarkitekturen

Antidep trenger ikke implementere alle automatiseringsmuligheter samtidig.

En første produksjonsdyktig evidenspipeline BØR prioritere robusthet fremfor maksimal autonomi.

### 80.1 Anbefalt første operative flyt

```text
1. Menneske eller QueryPlanner definerer EvidenceWorkUnit
2. Agent foreslår kandidatkilder
3. SourceAssessor godkjenner kilder
4. Agent ekstraherer strukturerte EvidenceItem
5. Separat agent verifiserer ekstraksjonen mot kildene
6. Claim-agent foreslår atomiske påstander
7. Adversarial-agent søker etter svakheter/motbevis
8. EvidenceAssessor foreslår sikkerhetsvurdering
9. CitationVerifier kontrollerer hver kilderelasjon
10. Klinisk fagperson reviewer og godkjenner
11. Systemet publiserer eksakt godkjent revisjon
12. Endringer og review-frister overvåkes
```

**Leddene 1-9 skal kunne kjøres av agenter, og det er hovedveien.** Antidep er agent-first:
målet er at KI-agenter gjør mest mulig av det redaksjonelle arbeidet, og at kvaliteten sikres
med flere uavhengige kontrollag framfor med manuelt menneskearbeid. Et menneske skal kunne
tre inn i hvilket som helst av disse leddene når det er ønskelig eller nødvendig (§69), men
det er unntaket, ikke normalveien.

Ledd 10 er unntaket som ikke kan automatiseres bort. `ANTIDEP_CONSTITUTION.md` §12 krever
menneskelig faglig godkjenning før første publisering, og kravet er håndhevet i databasen: en
reviewbeslutning krever en aktør av typen `human`. En endring av det er en revisjon av
Konstitusjonen, ikke en pipelinekonfigurasjon.

Hvert agentledd har sin egen aktør, sin egen tekniske identitet og sin egen rolle. Rollen er
rettighetsgrensen: en identitet slipper bare gjennom autentiseringen for den rollen
operasjonen krever, så et ledd kan ikke utføre et annet ledds operasjon. Et andre uavhengig
kontrollag i samme rolle er en ny aktør med sin egen identitet — ikke en utvidelse av
rettighetene til den første.

Dette gir høy grad av KI-automatisering uten å gjøre KI til endelig faglig autoritet.

## 81. Automatisering kan økes gradvis

Når Antidep har reelle evalueringsdata for egen pipeline, kan lavrisikoledd automatiseres mer.

Økt autonomi skal begrunnes i observerte kvalitetsdata, ikke bare i at en nyere modell virker mer kapabel.

Mer autonomi betyr i første rekke **flere uavhengige kontrollag**, ikke færre kontroller: to
verifikatorer med hver sin identitet som er uenige, er et bedre utfall enn én som ikke ble
motsagt (§64). Å fjerne et kontrolledd er en governance-endring og skal begrunnes særskilt; å
legge til et er en konfigurasjonsendring.

---

# Del XXVII — Globale valideringsregler

## 82. Følgende tilstander skal være teknisk umulige eller eksplisitt blokkerte

1. Publisert evidenssyntese uten kildekobling.
2. Publisert klinisk anbefaling uten menneskelig faglig godkjenning.
3. `EvidenceItem` uten identifiserbar `Source`.
4. `supports`-relasjon uten utført kildestøttekontroll når objektet krever dette.
5. Påstand som bruker `ingen evidens` som synonym for `ingen risiko`.
6. Skjult overskriving av historisk publisert `ClaimRevision`.
7. Agent som godkjenner sin egen høyrisikoekstraksjon som eneste kontroll.
8. Høyrisiko klinisk regel som blir aktivert direkte fra uverifisert språkmodelloutput.
9. Kilde markert som trukket tilbake uten påvirkningsanalyse av avhengig publisert kunnskap.
10. Publisert syntese med uløst alvorlig konflikt uten at konflikten er synlig i vurderingen.
11. Eksternt kildemateriale som får endre systeminstruksjoner eller pipelinepolicy.
12. Presentasjonslaget som oppretter nye faglige fakta ved render-tid.

---

# Del XXVIII — Metodisk forhold til systematiske oversikter

## 83. Antidep er ikke automatisk en serie fullstendige systematiske oversikter

Målet er en klinisk kunnskapsbase, ikke at hver enkelt påstand nødvendigvis skal være resultatet av en ny full Cochrane-lignende reviewprosess.

Likevel skal Antidep adoptere relevante metodiske prinsipper fra systematiske oversikter når det er nødvendig for å redusere bias, blant annet:

- eksplisitt spørsmål før søk
- reproducerbar søkeprosess
- registrering av inklusjon/eksklusjon
- studier fremfor publikasjoner som konseptuell analyseenhet
- strukturert dataekstraksjon
- vurdering av risiko for bias og manglende evidens
- eksplisitt sikkerhetsvurdering
- dokumenterte oppdateringer

Pipeline skal kunne bruke en eksisterende systematisk oversikt som evidenskilde uten å late som Antidep selv har gjentatt hele oversikten.

## 84. Søkeintensitet skal følge spørsmålet

For en høyrisiko klinisk anbefaling kan det være nødvendig med bredt og systematisk søk.

For et deterministisk norsk produktfaktum kan én autoritativ kilde være tilstrekkelig.

Pipeline skal derfor dokumentere søkets omfang fremfor å bruke samme kildekrav på alle spørsmål.

---

# Del XXIX — Metodisk grunnlag

Denne spesifikasjonen bygger særlig på følgende eksterne prinsipper:

- **Cochrane Handbook, Chapter 4**: systematisk og dokumentert søk, høy sensitivitet, kobling av flere rapporter fra samme studie, eksplisitt studieutvelgelse og søk som kan reproduseres.
- **Cochrane Handbook, Chapter 5**: nøyaktig, komplett, transparent og oppdaterbar dataekstraksjon.
- **Cochrane Handbook, Chapter 13**: eksplisitt vurdering av risiko for bias som følge av manglende evidens.
- **Cochrane Handbook, Chapter 14 / GRADE**: separat vurdering av evidenssikkerhet etter utfall, med eksplisitte begrunnelser for risiko for bias, inkonsistens, indirekthet, upresisjon og publikasjonsbias.
- **Cochrane Handbook, Chapter IV**: systematisk håndtering av oppdateringer når ny evidens eller nye metoder kan påvirke konklusjonen.
- **NIST AI RMF / Generative AI Profile**: eksplisitt risikostyring, evaluering, testing, sporbarhet og kontroll av generative KI-systemer.

### Utvalgte kilder

- Cochrane Handbook, Chapter 4: https://www.cochrane.org/authors/handbooks-and-manuals/handbook/current/chapter-04
- Cochrane Handbook, Chapter 5: https://www.cochrane.org/authors/handbooks-and-manuals/handbook/current/chapter-05
- Cochrane Handbook, Chapter 13: https://www.cochrane.org/authors/handbooks-and-manuals/handbook/current/chapter-13
- Cochrane Handbook, Chapter 14: https://www.cochrane.org/authors/handbooks-and-manuals/handbook/current/chapter-14
- Cochrane Handbook, Chapter IV: https://www.cochrane.org/authors/handbooks-and-manuals/handbook/current/chapter-iv
- NIST AI RMF Generative AI Profile: https://www.nist.gov/publications/artificial-intelligence-risk-management-framework-generative-artificial-intelligence

---

# Del XXX — Avgrensninger og åpne beslutninger

## 85. Dette dokumentet avgjør ikke ennå

Følgende skal bestemmes i senere spesifikasjoner eller implementasjonsbeslutninger:

- konkret databaseskjema
- hvilke bibliografiske API-er som brukes
- tilgang til eventuelle lisensierte databaser
- eksakt søkestrategi per klinisk tema
- hvilke risk-of-bias-verktøy som brukes for hvert studiedesign
- eksakt GRADE-representasjon i databasen
- om to menneskelige reviewere kreves for bestemte risikoklasser
- eksakte tidsintervaller for planlagt re-review
- hvilke modeller som brukes for hvilke agentroller
- terskler for automatisk versus manuell eskalering
- hvordan fulltekst håndteres juridisk og teknisk
- detaljert admin-UI

Disse valgene skal avledes fra konstitusjonen, kunnskapsmodellen og denne pipelinen.

---

# Del XXXI — Neste spesifikasjoner

Når dette dokumentet er vedtatt, bør følgende designarbeid følge:

1. **`DATABASE_ARCHITECTURE.md`** — oversett kunnskapsmodellen og pipeline-objektene til konkret PostgreSQL/Supabase-arkitektur, versjonering, constraints og RLS-grenser.
2. **`CONTENT_GOVERNANCE.md`** — roller, rettigheter, reviewerkrav, risikoklasser, publisering, feilrapportering og redaksjonell styring.
3. **`INFORMATION_ARCHITECTURE.md`** — hvordan klinikeren navigerer samme kunnskapsbase via legemidler, sammenligninger, kliniske problemstillinger og søk.
4. **`CLINICAL_TOOLS_SPEC.md`** — særskilt arkitektur for nedtrapping, bytte, interaksjoner og andre beregnings-/regelbaserte funksjoner.
5. **Agent schemas og evalueringssett** — maskinlesbare kontrakter for hver agentrolle og et representativt gold-standard-testsett før produksjonsbruk.

---

## 86. Styringsregel

Hvis en automatisering gjør pipelinen raskere, men svekker sporbarhet, uavhengig verifikasjon, usikkerhetshåndtering eller nødvendig menneskelig kontroll, skal automatiseringen endres — ikke kvalitetskravet.
