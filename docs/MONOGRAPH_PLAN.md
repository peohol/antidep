# Plan for legemiddelmonografier og autonom kildeoppdagelse

Status per **2026-09-17**: **Fase A, B og C er levert. Fase D–E er ikke startet.**

De to faglige spesifikasjonene er [Monograph Standard v1](MONOGRAPH_STANDARD.md) og [Source Policy v1](SOURCE_POLICY.md), og de er nå implementert som versjonerte kontrakter: 80 spørsmålsmaler og 13 kildeprofiler ligger i ett maskinlesbart register som prøves mot dokumentene ved hver kjøring.

Fase C er teknisk prøvd ende til ende og **ikke** faglig: ingen komplett monografi er utarbeidet, ingen klinisk monografi er godkjent eller publisert, og ingen agent kan attestere at et menneske har vurdert innhold. Fase D — pilotmonografien for sertralin — er beskrevet i [overleveringen](MONOGRAPH_PHASE_D_HANDOVER.md).

Dette dokumentet bevarer produktmålet og leveranserekkefølgen. Detaljer om spørsmål, svarformer, kilder, stoppkriterier og vedlikehold har én gjeldende beskrivelse i standardene, ikke parallelle foreløpige lister her.

## 1. Produktmålet

Antidep skal være en gratis, skalerbar nettapp for norske klinikere om antidepressiver. Appen skal gi rask, kildebelagt informasjon om hvert virkestoff, gjøre sammenligning mulig, gi konkret hjelp til nedtrapping og bytte og på sikt kunne tilby systematisk beslutningsstøtte.

Innholdet skal i stor grad produseres og kvalitetssikres av KI-agenter. Kliniske fagpersoner skal kunne inspisere, korrigere, overstyre og supplere innholdet, men de skal ikke være nødt til å drive litteratursøk eller foreslå artikler én for én for at en monografi skal bygges.

Klinikerflaten skal bruke ordet «antidepressiver», ha rask visuell oversikt, lite unødvendig tekst og flere detaljnivåer på mobil og desktop. Forbehold som endrer klinisk mening skal ikke skjules i fordypningen.

## 2. Retningsendringen

Normalinngangen skal flyttes fra:

> Her er en artikkel. Dette er virkestoffet, endepunktet og populasjonen den kan brukes til.

til:

> Bygg monografi for sertralin.

Antidep skal selv vite hvilke kliniske spørsmål som må besvares, søke etter egnet grunnlag, velge og begrunne kilder, innhente tilgjengelig originalmateriale og føre funnene gjennom kontroller til et samlet monografiutkast. Manuell artikkelinnlegging skal bestå som et supplement, ikke være forutsetningen for normal fremdrift.

Det eksisterende fundamentet med kilder, kildeversjoner, evidensfunn, påstander, kontroller, revisjoner og proveniens skal bevares. Det mangler et lag som uttrykker hva en monografi skal dekke og driver arbeidet ut fra disse behovene. Nye svarformer må også håndteres korrekt; en preparatstyrke, et forskningsestimat og et faglig råd er ikke samme type kunnskap.

## 3. Avtalte prinsipper

En monografi er en versjonert visning over strukturerte, kildebelagte kunnskapsobjekter, ikke ett stort fritekstdokument. Standarden definerer spørsmål og avgrensninger, ikke forhåndsbestemte svar.

Hvert behov må ha eksplisitt relevans, arbeidsstatus, faglig utfall, kildegrunnlag og usikkerhet. Ikke undersøkt, teknisk stopp, manglende tilgang og undersøkt, men utilstrekkelig evidens skal holdes fra hverandre. Arbeidsdekning er ikke evidenssikkerhet.

Kildepolitikken avhenger av spørsmålet. Norsk godkjent dosering, sammenlignende effekt, sjeldne skader og praktiske bytteråd kan ikke hentes og vurderes med ett udifferensiert kildehierarki. Discovery-resultater er forslag, ikke kliniske sannheter.

Bytte gjelder en rettet relasjon mellom virkestoffer. Nedtrapping krever både faglig grunnlag og dokumenterte praktiske produktmuligheter. En fullstendig monografi gir ikke i seg selv en validert individuell planmotor.

Mennesker skal kunne redigere gjennom admin-UI, tilføre/forkaste kilder, begrense utvalgte områder til manuelt forhåndsgodkjente kilder og overstyre faglige vurderinger uten kodearbeid. Endringene skal ha historikk og må ikke overskrives stille av agentene. Ingen overstyring kan gjøre en ikke-utført kontroll til en utført kontroll.

Dagens krav om navngitt faglig sluttkontroll og separat menneskelig publisering beholdes til en eventuell ny, uttrykkelig produktbeslutning. Autonomt mellomarbeid og menneskelig publiseringskontroll er forskjellige spørsmål.

## 4. Leveranserekkefølge og status

| Fase | Leveranse | Status |
| --- | --- | --- |
| A | Monograph Standard v1 | Utarbeidet av ChatGPT; 80 spørsmålsmaler med betingelser, svarformer, sammenligningsregler og akseptansegrunnlag |
| B | Source Policy v1 | Utarbeidet av ChatGPT; spørsmålsspesifikke kildeprofiler, søk/utvalg, integritet, kvalitetsvurdering, stopp og vedlikehold |
| C | Implementer monografibestilling, dekningskart og autonom kildeoppdagelse | Ikke startet; neste tekniske leveranse etter egen bestilling |
| D | Valider hele arbeidsformen på en reell sertralinmonografi | Ikke startet; ingen kliniske sertralinsvar er produsert som del av fase A/B |
| E | Skaler til øvrige antidepressiver og bygg videre sammenlignings-/behandlingsstøtte | Ikke startet |

### Fase A — faglig spesifikasjon

[MONOGRAPH_STANDARD.md](MONOGRAPH_STANDARD.md) beskriver hva Antidep skal undersøke, hva som er obligatorisk eller betinget, forventet svarstruktur, tilstander og krav til klinikerpresentasjon. De 80 malene gir flere konkrete behov når de gjentas per produkt, indikasjon, populasjon, utfall eller relasjon.

Spørsmåls-ID-er og klinisk betydning skal versjoneres. Ingen implementert datakontrakt, tabell, agent eller brukerflate er laget i denne fasen.

### Fase B — kildepolitikk

[SOURCE_POLICY.md](SOURCE_POLICY.md) beskriver hvilke kilder og søkespor som passer hvert behov, hvordan valget begrunnes, hvordan originalgrunnlaget kontrolleres og når arbeidet kan avsluttes. Den skiller faglig usikkerhet fra manglende tilgang, søkedekning og teknisk svikt.

Dokumentet oppgir undersøkte metode-/veiledningskilder og begrensninger i lesetilgangen. Disse referansene er ikke registrerte eller klinisk godkjente kilder i Antideps database. Praktiske stopp- og oppdateringsregler er v1-produktvalg som må evalueres i piloten.

### Fase C — én sammenhengende teknisk leveranse

Normalt utført av Claude Code etter en egen bestilling basert på de ferdige spesifikasjonene og da gjeldende repo. Leveransen skal ende med en fungerende vei fra én virkestoffbestilling til standardiserte kunnskapsbehov, dokumentert kildeoppdagelse og kontrollert videre behandling, ikke bare dokumenter eller en isolert søkeboks.

Omfanget skal dekke:

- versjonert, maskinlesbar monografistandard og monografibestilling;
- automatisk opprettede/relevansvurderte behov og et ærlig dekningskart;
- agentstyrt søk, kildeutvalg, motprøving og dokumentert utvalgs-/søkehistorikk;
- gjenbruk av kilder på tvers av behov og studie-/rapportkobling som hindrer dobbelttelling;
- kontrollert innhenting og tilknytning til eksisterende evidenskjede, også en korrekt løsning for regulatoriske fakta og preparatdata;
- forslag til revisjon av eksisterende svar ved ny evidens, uten automatisk publisering;
- monografipresentasjon/kandidat med konsistente avhengigheter og bevart menneskelig redaksjonell kontroll;
- relevante tester, feil-/avbruddstilstander og klinikervennlig fremdriftsvisning.

Dagens kontroller skal ikke svekkes for å få nye kildetyper eller svarformer gjennom. Fulltekst-, rolle- og publiseringsgrenser må håndteres eksplisitt i implementeringen. Ingen bestemt betalt modell-API blir en forutsetning.

Oppgaver kan utføres i flere commits innen samme sammenhengende leveranse. Del bare i separate PR-er når reell uavhengighet, reviewbarhet, utrullingsbehov eller vesentlig risiko begrunner det, ikke bare fordi flere lag berøres. Reparasjon av nødvendig eksisterende drift kan håndteres uavhengig av denne produktutvidelsen.

### Fase D — reell sertralinmonografi

Start med «Bygg monografi for sertralin», ikke en håndplukket artikkelliste. Prøv hva som faktisk skjer autonomt helt fram til en samlet, lesbar monografi og ordinær menneskelig sluttkontroll.

Test spørsmål, kildedekning, fullteksttilgang, ekstraksjon, motstrid, sammenlignbarhet, norsk produktgrunnlag og mobil-/desktopvisning. Vurder faglige feil og utelatelser samt faktisk menneskelig arbeidsmengde, ikke bare antall gjennomførte jobber og grønne tekniske tester.

Sertralin er valideringsobjekt, ikke et hardkodet spesialtilfelle. Manglende data skal beskrives ærlig; ingen forsøksverdier eller kildekontroller skal simuleres som virkelig klinisk kunnskap.

### Fase E — skalering og videre funksjoner

Når pilotens generelle arbeidsform fungerer, bygg monografier for øvrige antidepressiver og gjenbruk kunnskapen i sammenligningsvisningen. Utvid praktisk støtte for nedtrapping, bytte og senere beslutningsstøtte med egne kontrollerte regler og faglig godkjenning.

## 5. Neste handling

Fase A og B er levert som dokumenter, og fase C som fungerende, prøvd kode: fra én virkestoffbestilling til et kontrollert, delvis monografiutkast med ærlig dekning, gjennom de autoriserte inngangene. **Neste steg er fase D** — å prøve arbeidsformen faglig på én reell sertralinmonografi. [Overleveringen](MONOGRAPH_PHASE_D_HANDOVER.md) sier hvordan piloten startes, hvor den inspiseres, og hvilke reelle tilgangsbegrensninger som står igjen.

Planen har lykkes når klinikeren kan være faglig kontrollør og mulig redaktør, uten å måtte være litteratursøkets manuelle arbeidsleder.
