# Antidep Product Information Architecture

**Versjon:** 0.1  
**Dato:** 18. august 2026  
**Status:** Første produkt-/IA-spesifikasjon  
**Styrende dokumenter:** [`ANTIDEP_CONSTITUTION.md`](./ANTIDEP_CONSTITUTION.md), [`KNOWLEDGE_MODEL.md`](./KNOWLEDGE_MODEL.md), [`EVIDENCE_PIPELINE.md`](./EVIDENCE_PIPELINE.md) og [`DATABASE_ARCHITECTURE.md`](./DATABASE_ARCHITECTURE.md)

## 1. Formål

Dette dokumentet definerer hvordan Antideps strukturerte kunnskap skal organiseres og presenteres for klinikeren.

Målet er ikke å tegne endelige skjermer. Målet er å fastsette:

- hvilke hovedoppgaver produktet skal støtte
- hvilke innganger og informasjonsnivåer brukeren møter
- hvordan samme kunnskapsbase gjenbrukes i ulike visninger
- hvordan evidens, usikkerhet og kilder vises uten å overbelaste standardvisningen
- hvordan sammenligning, kliniske problemstillinger og verktøy henger sammen
- hvilke UX-invarianter som skal gjelde på desktop og mobil

Datamodellen skal ikke diktere navigasjonen. Klinikerens oppgave skal være utgangspunktet.

---

## 2. Normative begreper

- **SKAL**: produktkrav som ikke skal brytes uten eksplisitt arkitekturendring.
- **BØR**: sterk standard som kan fravikes med dokumentert grunn.
- **KAN**: tillatt, men ikke påkrevd.

---

# Del I — Produktets mentale modell

## 3. Antidep skal kunne åpnes fra fire kliniske spørsmål

Den overordnede brukerarkitekturen skal støtte minst fire innganger:

1. **Jeg vil vite om ett antidepressiv.**
2. **Jeg vil sammenligne flere antidepressiver.**
3. **Jeg har en klinisk problemstilling og vil vite hvilke antidepressiver som skiller seg ut.**
4. **Jeg skal bytte, trappe ned eller utføre en annen konkret legemiddelhandling.**

Disse inngangene skal bygge på samme kunnskapsbase.

## 4. Femte inngang: globalt søk

Brukeren skal ikke måtte kjenne Antideps informasjonsarkitektur for å finne innhold.

Globalt søk skal kunne finne:

- virkestoff
- handelsnavn
- klasse
- klinisk tema
- interaksjonspartner
- relevant verktøy
- eventuelt vanlig synonym eller norsk/engelsk fagterm

Søk skal være en primær inngang, ikke en sekundær funksjon gjemt i en meny.

## 5. Hovednavigasjon

Første versjon bør konseptuelt ha følgende hovedområder:

```text
Søk / Oppslag
Sammenlign
Kliniske situasjoner
Bytte og nedtrapping
Om evidensen / Metode
```

`Interaksjoner` kan enten være eget hovedområde eller tilgjengelig som kontekstuelt verktøy fra legemiddel- og kliniske situasjonsvisninger.

Admin-/redaktørfunksjoner skal ikke blandes inn i klinikerens hovednavigasjon.

---

# Del II — Progressiv informasjonsdybde

## 6. Tre informasjonsnivåer

Antidep skal som hovedregel presentere klinisk kunnskap i tre lag.

### Nivå 1 — beslutningsrelevant oversikt

Skal kunne leses på sekunder.

Viser eksempelvis:

- kort konklusjon
- retning/størrelseskategori når forsvarlig
- viktig usikkerhet
- sentrale varsler
- sammenligningsrelevant indikator

### Nivå 2 — klinisk forklaring

Viser:

- presisering av populasjon
- komparator
- tidsramme
- klinisk betydning
- viktige forbehold
- relevante tall
- hvorfor funnet kan være viktig

### Nivå 3 — evidens og metode

Viser:

- konkrete kilder
- EvidenceItems
- effektmål og konfidensintervall
- evidenssikkerhet
- kilde–claim-relasjon
- motstridende evidens
- siste review
- eventuelt metodisk begrunnelse

Brukeren skal kunne gå fra nivå 1 til nivå 3 uten å miste kontekst.

## 7. Standardvisningen skal være kort

Antidep skal ikke vise full monografitekst som standard.

Detaljer skal åpnes ved behov gjennom for eksempel:

- ekspanderbare seksjoner
- detaljer-panel
- dialog/drawer
- dedikert evidensside

Valg av komponent kan variere mellom desktop og mobil.

## 8. Kritisk informasjon får bryte progressiv disclosure

Informasjon som er nødvendig for sikker bruk skal ikke skjules bare fordi den er detaljert.

Eksempler:

- alvorlig kontraindikasjon
- viktig interaksjon
- sikkerhetskritisk dose-/bytteforbehold
- høy usikkerhet i en ellers tilsynelatende presis anbefaling

---

# Del III — Legemiddeloppslag

## 9. Legemiddelsiden er en projeksjon, ikke et dokument

En legemiddelside skal komponeres fra strukturerte objekter og claims.

Den skal ikke være en separat håndskrevet monografi som utvikler seg uavhengig av sammenlignings- og temavisninger.

## 10. Toppfelt

Ved åpning av et virkestoff bør brukeren umiddelbart se:

- kanonisk virkestoffnavn
- vanlige norske handelsnavn
- klasse
- tilgjengelige norske legemiddelformer/styrker i komprimert form
- eventuelle høyt prioriterte sikkerhetsvarsler
- handlinger som `Sammenlign`, `Bytt fra/til`, `Se interaksjoner`

## 11. Foreslåtte hovedseksjoner

Legemiddelsiden bør inneholde følgende konseptuelle seksjoner:

### Oversikt

- klasse og virkningsprofil
- sentrale bruksområder
- kort effektprofil
- kort tolerabilitetsprofil
- viktigste særtrekk

### Effekt

- depresjon
- andre relevante indikasjoner
- respons/remisjon når tilgjengelig
- effektstørrelse
- dose–respons
- vedlikeholdsbehandling/tilbakefallsforebygging

### Bivirkninger og tolerabilitet

- seksuell dysfunksjon
- vekt
- GI
- søvn/sedasjon
- aktivering
- svetting
- emosjonell avflatning når evidensgrunnlaget tillater vurdering
- samlet seponerings-/tolerabilitetsdata

### Sikkerhet

- QT
- kramper
- hyponatremi
- blødning
- serotonerg toksisitet
- overdose
- mani/hypomani
- andre alvorlige forhold

### Interaksjoner

- klinisk relevante PK-interaksjoner
- PD-interaksjoner
- enzymhemming/-induksjon
- konsekvens og håndtering

### Farmakologi og farmakokinetikk

- primær virkningsmekanisme
- reseptor-/transportørprofil når relevant
- biotilgjengelighet
- halveringstid
- aktive metabolitter
- CYP
- nonlinearitet
- steady state

### Spesielle situasjoner

- graviditet
- amming
- eldre
- barn/ungdom
- leverfunksjon
- nyrefunksjon
- epilepsi
- hjertesykdom
- bipolaritet
- polyfarmasi

### Preparater i Norge

- handelsnavn
- form
- styrke
- depot
- delbarhet der relevant og pålitelig strukturert
- markedsstatus

## 12. Seksjonsrekkefølge kan tilpasses klinisk betydning

Antidep skal ikke låse alle virkestoffer til identisk visuell prioritet dersom ett legemiddel har et særskilt viktig sikkerhetsforhold.

Strukturen skal være konsistent, men relevante varsler kan løftes opp.

---

# Del IV — Claim-komponenten

## 13. Claim er den grunnleggende presentasjonsenheten

En klinisk påstand skal kunne vises som en standardisert komponent på tvers av produktet.

Eksempelstruktur:

```text
[Konklusjon]
Mirtazapin er assosiert med større vektøkning enn placebo ved korttidsbehandling.

[Indikator]
Økt vekt ↑

[Sikkerhet i evidensen]
Moderat

[Detaljer]
Populasjon · tidsramme · størrelse · forbehold

[Hvorfor sier Antidep dette?]
```

## 14. Claim-komponenten skal ikke skjule scope

Hvis påstanden bare gjelder:

- voksne
- korttidsbehandling
- depresjon
- bestemt doseområde

skal UI-et ikke få den til å fremstå universell.

Kritiske scope-begrensninger bør være synlige allerede på nivå 1 eller 2.

## 15. «Hvorfor sier Antidep dette?» er en standardhandling

Alle klinisk relevante claims bør kunne åpne en evidensvisning med:

- kanonisk claim
- evidenssikkerhet
- kort syntesebegrunnelse
- sentrale støttende kilder
- motstridende/indirekte kilder
- konkrete resultater når relevante
- siste faglige review

Dette skal være et gjennomgående produktmønster.

---

# Del V — Usikkerhet og visuelle indikatorer

## 16. Usikkerhet skal være synlig, men ikke støyende

Antidep skal vise evidenssikkerhet konsistent.

Foretrukket mønster:

```text
Høy sikkerhet
Moderat sikkerhet
Lav sikkerhet
Svært lav sikkerhet
Ingen vurderbar evidens
```

UI-et kan bruke ikon, form eller farge som støtte, men teksten skal være tilgjengelig.

## 17. «Ingen evidens» skal aldri se ut som «lav risiko»

En tom skala, grå indikator eller manglende datapunkt må ikke intuitivt kunne tolkes som:

- ingen effekt
- ingen bivirkning
- ingen interaksjon

Bruk eksplisitt status som `Ukjent` eller `Ingen vurderbar evidens`.

## 18. Visuelle skalaer må ha semantisk definisjon

Hvis Antidep viser en 5-punkts skala som:

```text
svært lav ← lav ← moderat ← høy ← svært høy
```

skal hvert nivå ha definert betydning og datagrunnlag.

Skalaen skal ikke brukes dersom forskningens presisjon ikke forsvarer kategoriseringen.

## 19. Kvantitative data prioriteres når de er tolkbare

Når det finnes egnet data, bør Antidep vise tall i tillegg til eller i stedet for kategorier:

- RR/OR
- absolutt risiko
- gjennomsnittsforskjell
- SMD med klinisk fortolkning
- konfidensintervall

Tall skal ikke presenteres uten nødvendig kontekst.

## 20. Farge er aldri eneste signal

Betydning som `høy risiko`, `lav sikkerhet` eller `forskjell` skal også formidles med tekst, symbol, posisjon eller annen redundant kode.

---

# Del VI — Sammenligning

## 21. Sammenligning skal støtte mer enn to antidepressiver

Brukeren skal kunne velge minst 2 og gjerne flere virkestoffer.

Standardvisningen bør være en matrise:

```text
                  Sertralin   Escitalopram   Mirtazapin
Effekt            ...         ...            ...
Vekt              ...         ...            ...
Seksuell funksjon ...         ...            ...
Sedasjon          ...         ...            ...
Interaksjoner     ...         ...            ...
Seponering        ...         ...            ...
```

## 22. Brukeren skal velge sammenligningsdimensjoner

Ikke alle kliniske spørsmål trenger 30 rader.

Brukeren bør kunne:

- legge til/fjerne dimensjoner
- velge forhåndsdefinert sett
- filtrere på klinisk situasjon

Eksempel:

`Sammenlign ved søvnvansker` kan fremheve sedasjon, søvn, vekt og relevante sikkerhetsforhold.

## 23. «Vis bare forskjeller»

Sammenligningsverktøyet bør ha en funksjon som skjuler dimensjoner hvor legemidlene ikke skiller seg klinisk meningsfullt eller hvor evidensen ikke tillater differensiering.

Funksjonen må skille mellom:

- ingen viktig forskjell påvist
- utilstrekkelig evidens til å si om det er forskjell

## 24. Sammenligning skal være symmetrisk

Hvis et claim brukes til å vise A versus B, skal systemet ikke presentere inkonsistent konklusjon når brukeren åpner B versus A.

Retning kan inverteres, men evidensobjektet skal være det samme.

## 25. Sammenligning skal kunne åpnes fra legemiddelsiden

`Sammenlign med ...` skal være en primær handling fra et virkestoff.

Valgte legemidler bør bevares ved navigasjon til relevante claims og tilbake.

---

# Del VII — Kliniske situasjoner

## 26. Klinisk problemstilling er en egen inngang

Klinikeren starter ofte med:

- «pasienten er plaget med seksuell dysfunksjon»
- «jeg vil unngå vektøkning»
- «pasienten har epilepsi»
- «pasienten er gravid»

og ikke med et bestemt virkestoff.

Antidep skal derfor ha topic-/situasjonsvisninger.

## 27. Foreslåtte situasjoner

Tidlig katalog kan inkludere:

- vektøkning
- seksuell dysfunksjon
- søvnløshet
- hypersomni/sedasjon
- fatigue
- angst
- smerter
- ADHD
- epilepsi
- bipolaritet
- suicid-/overdoserisiko
- graviditet
- amming
- eldre
- leverfunksjon
- nyrefunksjon
- hjertesykdom/QT
- polyfarmasi
- tidligere uttalte seponeringssymptomer

## 28. Situasjonssiden skal ikke være en skjult anbefalingsmotor

En topic-visning kan vise:

- relevante antidepressiver
- forskjeller
- evidenssikkerhet
- viktige trade-offs

men skal ikke automatisk kalle ett middel «best» uten eksplisitt modellert anbefaling og nødvendig governance.

## 29. Rangering krever definert semantikk

Hvis Antidep senere rangerer legemidler, skal det være klart:

- hva som rangeres
- hvilke dimensjoner som inngår
- vektingen
- hvilken evidens som ligger til grunn
- hvordan usikkerhet håndteres

En visuelt ordnet liste skal ikke implisitt bli en behandlingsrangering ved en tilfeldighet.

---

# Del VIII — Interaksjoner

## 30. Interaksjonsvisningen skal være mekanistisk og klinisk

Et interaksjonsobjekt bør presenteres som:

```text
Hva skjer?
→ mekanisme

Hvor stor er forventet effekt?
→ eksempelvis konsentrasjonsendring når kjent

Hvor sikker er kunnskapen?
→ evidensstatus

Hvor viktig er det klinisk?
→ konsekvens

Hva bør klinikeren gjøre?
→ bare dersom dette finnes som godkjent anbefaling
```

## 31. PK og PD skal skilles

UI-et bør eksplisitt skille:

- farmakokinetisk interaksjon
- farmakodynamisk interaksjon
- både PK og PD
- ukjent/indirekte mekanisme

## 32. Fravær av registrert interaksjon er ikke «ingen interaksjon»

Søk uten treff skal bruke språk som:

`Ingen relevant interaksjon funnet i Antideps nåværende kunnskapsgrunnlag.`

ikke:

`Ingen interaksjon.`

---

# Del IX — Bytte- og nedtrappingsverktøy

## 33. Dette er et eget hovedverktøy

Bytte/nedtrapping skal ikke gjemmes som en tekstseksjon i monografien.

Det skal være en oppgaveorientert flyt.

## 34. Minimumsinput

Ved bytte:

- nåværende virkestoff
- nåværende dose
- formulering
- mållegemiddel
- eventuelt ønsket tempo når klinisk forsvarlig

Ved nedtrapping:

- virkestoff
- dose
- formulering
- relevant behandlingskontekst
- ønsket/valgt tempo innen definerte rammer

## 35. Verktøyet skal bruke faktisk norsk produktinformasjon

Planen skal baseres på tilgjengelige:

- styrker
- formuleringer
- delbarhet når pålitelig kjent
- depotegenskaper

Planen skal ikke foreslå praktisk umulige doser uten å forklare hvordan de kan oppnås.

## 36. Output skal være eksplisitt og handlingsorientert

Eksempel:

```text
Uke 1–2: 100 mg daglig
Uke 3–4: 75 mg daglig
Uke 5–6: 50 mg daglig
...
```

Ved hvert steg skal systemet kunne vise:

- hvilke tabletter/styrker som brukes
- viktige forbehold
- regelversjon
- hvorfor planen er valgt

## 37. Klinikerstyrt tempo fremfor falsk fasit

Når evidensen ikke definerer ett korrekt skjema, bør verktøyet tilby eksplisitte valgmuligheter som:

- langsommere
- standard
- raskere

med tydelig beskrivelse av hva som skiller dem.

Det skal ikke maskere et skjønnsbasert valg som naturvitenskapelig presisjon.

## 38. Kliniker kan overstyre

Verktøyet skal ikke låse klinikeren til algoritmens forslag.

Ved manuell endring bør UI-et:

- bevare originalt forslag
- vise avvik
- validere åpenbart umulige doser
- ikke late som brukerens modifiserte plan er Antideps godkjente standardplan

## 39. Høyrisikoadvarsler må være kontekstuelle

Hvis overgang innebærer særskilt risiko, skal dette vises der beslutningen tas, ikke bare i et generelt sikkerhetsavsnitt på en annen side.

---

# Del X — Evidensvisning

## 40. Evidenssiden skal følge claimet

Brukeren skal kunne åpne et detaljpanel for ett claim uten å måtte søke på nytt.

## 41. Foreslått struktur

```text
Påstand

Sikkerhet i evidensen

Kort begrunnelse

Støttende evidens
  Studie/oversikt A
  → populasjon
  → komparator
  → resultat
  → presisjon

Motstridende/indirekte evidens
  Studie B
  → hvorfor den trekker i annen retning

Begrensninger

Sist faglig vurdert

Full referanseliste
```

## 42. Kildesiden og evidenssiden er forskjellige

En `Source`-visning beskriver én publikasjon/kilde.

En claim-evidensvisning beskriver hvorfor flere EvidenceItems samlet støtter en påstand.

De skal kunne lenke til hverandre, men ikke blandes.

## 43. Source locator bør brukes der mulig

Når lisens og teknisk tilgang tillater det, bør Antidep kunne vise:

- side
- tabell
- figur
- avsnitt

som gjør det enkelt for faglig bruker å kontrollere funnet i originalkilden.

---

# Del XI — Søk

## 44. Søket skal tåle klinisk språk

Søk bør støtte:

- generisk navn
- handelsnavn
- forkortelser
- norske og engelske synonymer
- vanlige stavemåter
- kliniske begreper

Eksempel:

`seksuelle bivirkninger`, `sexual dysfunction` og eventuelt relevante underbegreper skal kunne lede til samme ClinicalConcept.

## 45. Resultattyper skal skilles visuelt

Søk kan returnere:

- Virkestoff
- Handelsnavn
- Klinisk situasjon
- Interaksjon
- Verktøy

Brukeren skal forstå hva slags objekt som åpnes.

## 46. Søkeresultat skal prioritere klinisk relevans

Eksakt virkestoff-/handelsnavn bør rangeres over tilfeldige teksttreff.

Søk i publisert kunnskap skal ikke eksponere draft/retired content til vanlige kliniske brukere.

---

# Del XII — Mobil og responsivitet

## 47. Mobil er førsteklasses klient

Antidep skal ikke være en desktop-tabell som presses inn på mobil.

Alle sentrale arbeidsflyter skal være praktisk gjennomførbare på smal viewport.

## 48. Sammenligning på mobil

Store matriser bør kunne transformeres til for eksempel:

- én dimensjon av gangen
- sticky legemiddelhoder
- horisontal kontrollert scrolling
- «forskjeller»-kort

men underliggende sammenligningssemantikk skal være identisk.

## 49. Handlinger skal være nåbare uten presisjonspress

Interaktive mål og spacing skal være egnet for touch.

Kritiske handlinger som publisering gjelder admin-UI og er ikke del av klinikerens mobilflate.

---

# Del XIII — Tilgjengelighet

## 50. WCAG 2.2 skal være minimumsreferanse

Antidep skal designes slik at kjernefunksjoner kan brukes med:

- tastatur
- skjermleser
- zoom/reflow
- redusert fargesyn
- redusert finmotorikk

## 51. Semantikk før visuell pynt

Interaktive elementer skal bruke semantiske kontroller og tilgjengelige navn.

Et ikon uten tilgjengelig tekstalternativ skal ikke være eneste måte å forstå en klinisk handling på.

## 52. Fokus skal være synlig

Keyboard focus skal ikke fjernes eller gjøres subtilt.

Komponenter som drawer, modal og dropdown skal ha korrekt fokusrekkefølge og tilbakeføring.

## 53. Skjult innhold skal være programmatisk korrekt

Accordion/progressive disclosure skal eksponere:

- expanded/collapsed state
- relasjon mellom kontroll og innhold

for hjelpemidler.

## 54. Tabeller skal forbli tabeller når semantikken er tabulær

Sammenligningsmatriser skal ha korrekt rad-/kolonneinformasjon, også når mobilpresentasjonen transformeres visuelt.

---

# Del XIV — Navigasjon og tilstand

## 55. Dypelenker er et krav

Brukeren skal kunne dele en URL direkte til:

- virkestoff
- bestemt seksjon
- claim/evidensvisning
- sammenligning med valgte legemidler/dimensjoner
- klinisk situasjon

Sensitive pasientdata skal ikke legges i delbare URL-er.

## 56. Tilbakenavigasjon skal bevare kontekst

Hvis brukeren går fra sammenligning → evidens → tilbake, skal valgte legemidler og dimensjoner normalt være bevart.

## 57. URL skal representere meningsfull klienttilstand

Tilstand som er nyttig å bokmerke eller dele bør så langt mulig være URL-adresserbar.

Kortvarig UI-tilstand som hover trenger ikke være det.

---

# Del XV — Status, aktualitet og historikk

## 58. Vanlig bruker ser publisert status, ikke workflow-støy

Intern status som `source_verified` og `changes_requested` hører i admin-UI.

Klinikeren bør se informasjon som faktisk er relevant:

- sist faglig vurdert
- evidenssikkerhet
- eventuell aktualitetsadvarsel
- tilbaketrukket/erstattet informasjon der nødvendig

## 59. Vesentlige korreksjoner skal kunne ses

Fra relevant claim bør brukeren kunne se at en vesentlig korreksjon har skjedd og åpne korreksjonsinformasjon.

Dette skal ikke gjøre hver claim til en Git-diff som standard.

---

# Del XVI — Personalisering uten kunnskapsfragmentering

## 60. Brukerpreferanser kan endre visning, ikke sannhet

Eksempler på tillatt personalisering:

- favorittvirkestoffer
- sist brukte
- valgte sammenligningsdimensjoner
- kompakt/utvidet standardvisning
- lagrede sammenligninger

Personalisering skal ikke skape separate user-specific versjoner av kliniske claims.

## 61. Lokale prosedyrer skal være tydelig separat lag

Hvis Antidep senere støtter institusjonelle anbefalinger, skal UI-et skille tydelig mellom:

- Antideps generelle kunnskapsgrunnlag
- lokal prosedyre/anbefaling

Lokal overlay skal ikke usynlig overskrive evidensgrunnlaget.

---

# Del XVII — Admin-UI som parallell produktflate

## 62. Kliniker-UI og admin-UI deler objekter, ikke arbeidsflyt

Admin-UI skal kunne åpne samme Claim, Source og EvidenceItem som klinikeren ser, men med andre handlinger.

## 63. Redaktøren skal arbeide på objektet, ikke på websiden

Admin-UI bør tilby handlinger som:

- rediger claim
- legg til evidens
- marker kildeproblem
- sammenlign revisjoner
- be om review
- godkjenn/avvis
- publiser
- trekk tilbake

ikke en stor «rediger monografi»-textarea.

## 63.1 Kildekontroll skal være mulig uten fullteksten ved siden av

Kildekontrollen er flaten der et menneske avgjør om Antideps strukturerte verdier
følger av kilden. Den bærende regelen er:

> **Kildekontrolløren skal få nok lokal kildekontekst til å kunne vurdere hvert
> utsagn uten å måtte lete i fullteksten selv.**

Dette er et produktkrav, ikke en promptpreferanse. Det binder både hva
ekstraksjonen må levere (EVIDENCE_PIPELINE.md §19.1) og hvordan kontrollflaten
presenterer det:

- Økten skal innlede med **hva som skal kontrolleres** — virkestoff, endepunkt og
  eventuell populasjon — og med **hvilken kilde** det gjelder, som en lenke til
  artikkelen. Innledningen bygges av den kanoniske raden, aldri av generert tekst.
- Hvert kildeutdrag skal vises i sin helhet, uten avkorting.
- Flaten skal skille mellom **Antideps tolkning** — hva Antidep mener kilden sier
  — og en **mangel**, altså en opplysning som ikke er ført. Bokføring om hvor
  mange felter som står uten verdi, er ingen av delene og skal ikke presenteres
  som en tolkning. En mangel skal aldri bli til en klinisk påstand utledet av
  fraværet.
- **Spørsmålet skal følge det registrerte premisset, ikke bare det at verdien er
  tom.** Fraværsgrunnene er påstander om forskjellige ting: kilden rapporterer
  det ikke, studien målte det ikke, det er ikke aktuelt for funnet, eller det
  *står i kilden men lar seg ikke lese entydig ut*. Et felles spørsmål av typen
  «stemmer det at kilden ikke oppgir dette?» ville for den siste bedt
  kontrolløren bekrefte det motsatte av det som er ført, og svaret ville blitt
  registrert som om det gjaldt riktig spørsmål. Der en grunn er registrert, er
  det grunnen som skal bedømmes. Der ingen fraværskolonne finnes — effektmål,
  forbehold, den rå gjengivelsen — er «ingenting er ført» hele påstanden, og den
  handler om registreringen og ikke om hva kilden oppgir.
- **Et fravær i kilden som helhet kan ikke avgjøres av ett lokalt utdrag.** Sier
  Antidep at noe ikke er rapportert eller ikke er målt, skal flaten si at
  utdraget er den lokale konteksten og ikke et bevis for at opplysningen ikke
  står et annet sted. Kontrollflaten skal ikke stille et sterkere spørsmål enn
  grunnlaget den viser, kan bære.
- To utsagn som ser like ut, skal gjøres eksplisitt forskjellige. Endepunktet er
  hva som ble målt; effektmålet er hvordan resultatet er uttrykt.
- Tall skal presenteres i den formen kilden bruker, med databasens egen form som
  eksplisitt omregning ved siden av. En varighet lagret som 182 til 224 dager
  vises som «26 til 32 uker (registrert som 182 til 224 dager)», slik at kontrolløren slipper
  å kontrollregne. Den kanoniske verdien skal ikke gå tapt.
- Steget skal inneholde det som trengs for å svare, og ikke mer. Identifikatorer,
  henteadresser og representasjonstype er proveniens og hører til under tekniske
  detaljer.

## 64. Preview skal være tilgjengelig

Før publisering skal editor/reviewer kunne forhåndsvise hvordan den aktuelle revisjonen vil se ut i:

- legemiddelside
- sammenligning
- klinisk situasjon

uten å lagre separate kopier av teksten.

---

# Del XVIII — Antimønstre

## 65. Antidep skal unngå

### Giant monograph

En lang side hvor all informasjon må leses lineært.

### Traffic-light medicine

Rød/gul/grønn rangering uten eksplisitt semantikk og evidens.

### Evidence dumping

50 referanser uten forklaring på hvilke som faktisk støtter claimet.

### False precision

Numeriske skårer som `7.3/10 for weight gain` uten validert meningsinnhold.

### Hidden uncertainty

En tydelig konklusjon hvor svært lav evidens først vises flere klikk unna.

### No-data-as-zero

Manglende datapunkt som vises som null risiko/effekt.

### UI-derived recommendations

At sortering, grønnfarge eller defaultvalg utilsiktet blir en behandlingsanbefaling.

### Duplicated truth

Egen tekst for monografi, egen tekst for sammenligning og egen tekst for klinisk situasjon som senere divergerer.

---

# Del XIX — Foreslått MVP-informasjonsarkitektur

## 66. Første kliniske produktflate

MVP bør fokusere på fire sider/flyter:

### A. Søk/oppslag

```text
Forside
→ søk
→ legemiddelside
→ claim-detalj/evidens
```

### B. Sammenligning

```text
Velg 2–4 antidepressiver
→ velg dimensjoner
→ sammenligningsmatrise
→ åpne claim/evidens
```

### C. Klinisk situasjon

```text
Velg tema
→ relevante legemidler/claims
→ sammenlign
```

### D. Bytte/nedtrapping

```text
Velg nåværende legemiddel + dose
→ eventuelt mållegemiddel
→ parameterisert plan
→ praktisk doseringsskjema
→ evidens/rationale
```

## 67. MVP skal ikke kreve komplett kunnskapsunivers

Det er bedre at et begrenset antall virkestoffer og dimensjoner har høy evidens- og UX-kvalitet enn at hele antidepressivfeltet fylles med lavt verifisert innhold.

## 68. MVP-seksjoner per legemiddel

Første versjon kan begrense seg til:

- preparater/styrker
- effekt
- vekt
- seksuell dysfunksjon
- sedasjon/søvn
- seponeringsproblemer
- viktige interaksjoner
- sentral PK
- utvalgte sikkerhetsområder

Flere temaer kan legges til uten å endre IA-modellen.

---

# Del XX — UX-evaluering

## 69. Produktet skal testes på kliniske oppgaver

Ikke bare spør «liker du designet?».

Representative usability-oppgaver bør være:

- Finn hvilke styrker av venlafaksin som finnes i Norge.
- Sammenlign sertralin og mirtazapin med hensyn til vekt og seksuell dysfunksjon.
- Finn hvor sikker evidensen er for en konkret påstand.
- Finn en kilde og se hvorfor den støtter påstanden.
- Lag et foreslått bytte mellom to virkestoffer.
- Identifiser at evidensen er utilstrekkelig for en bestemt forskjell.

## 70. Mål

MVP-evaluering bør følge:

- tid til korrekt svar
- feilrate
- om usikkerhet blir forstått
- om brukeren finner kildene
- om visuelle skalaer feiltolkes
- navigasjonsfriksjon
- mobil gjennomførbarhet
- keyboard/accessibility-feil

## 71. Sikker UX er viktigere enn rask UX

Hvis en designendring gjør svaret raskere å finne, men øker risikoen for at `ukjent` tolkes som `trygt`, skal designet endres.

---

# Del XXI — Ikke-forhandlingsbare produktinvarianter

1. **Klinikerens oppgave styrer navigasjonen; databasetabellene gjør det ikke.**
2. **Standardvisningen er kort, med progressiv tilgang til detaljer og primærkilder.**
3. **Samme claim brukes i legemiddel-, sammenlignings- og temavisninger.**
4. **Usikkerhet vises eksplisitt.**
5. **Ingen evidens er aldri visuelt lik lav risiko eller null effekt.**
6. **Farge er aldri eneste bærer av klinisk mening.**
7. **Sammenligningsskalaer har eksplisitt semantikk og brukes bare når evidensen forsvarer dem.**
8. **Kliniske anbefalinger markeres som anbefalinger.**
9. **Brukeren kan alltid finne «Hvorfor sier Antidep dette?» for klinisk relevante claims.**
10. **Bytte/nedtrapping bruker faktiske norske produktstyrker og versjonerte regler.**
11. **Mobil er førsteklasses, ikke en komprimert ettertanke.**
12. **Dypelenker og bevart kontekst er standard.**
13. **Admin-UI redigerer kunnskapsobjekter, ikke dupliserte monografidokumenter.**
14. **Visuell orden eller defaultvalg skal ikke utilsiktet skape en anbefaling.**
15. **Tilgjengelighet behandles som funksjonell kvalitet.**

---

## 72. Neste steg

Når `CONTENT_GOVERNANCE.md` og dette dokumentet er godkjent, bør Antidep avslutte hoveddelen av den abstrakte arkitekturfasen.

Neste leveranse bør være en **konkret MVP-implementeringsplan** som velger:

- hvilke antidepressiver som inngår i pilotsettet
- hvilke ClinicalConcepts som inngår
- hvilke databaseobjekter som implementeres først
- første admin-workflow
- første evidenspipeline
- første kliniker-UI
- teststrategi
- rekkefølge på migrasjoner og vertikale slices

Planen bør deretter følges av faktisk implementasjon i små, reviewbare PR-er.

---

## 73. Tilgjengelighetsgrunnlag

Denne versjonen bruker WCAG 2.2 som normativ referanse for webtilgjengelighet.

Særlig relevante prinsipper inkluderer:

- informasjon skal ikke formidles med farge alene
- keyboard focus skal være synlig
- interaktive elementer skal kunne brukes uten mus
- struktur og relasjoner skal være programmatisk tilgjengelige

Primærkilder:

- https://www.w3.org/TR/WCAG22/
- https://www.w3.org/WAI/WCAG22/Understanding/use-of-color
- https://www.w3.org/WAI/WCAG22/Understanding/focus-visible
