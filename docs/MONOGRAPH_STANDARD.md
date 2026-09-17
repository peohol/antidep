# Antidep Monograph Standard v1

Versjon: **1.0.0**. Utarbeidet: **2026-09-17** av ChatGPT etter repo-eiers startsignal til fase A og B i [monografiplanen](MONOGRAPH_PLAN.md).

Status: **faglig spesifikasjon, ikke implementert og ikke validert på en ferdig monografi**. Spørsmålsregisteret er leveransen i fase A; [Source Policy v1](SOURCE_POLICY.md) er fase B. Kildehenvisningene S01–S14 viser til kildepolitikkens lesegrunnlag. Ingen klinisk monografi, individuell behandlingsplan eller menneskelig faglig godkjenning opprettes av disse dokumentene.

## 1. Produktkontrakten

Bestillingen skal kunne være: **«Bygg monografi for sertralin.»** Systemet skal selv opprette kunnskapsbehov, lete etter kilder, vurdere dem og bygge et kontrollert utkast. Sertralin er pilot, ikke et spesialtilfelle i standarden.

Antidep er en gratis klinisk kunnskapstjeneste om **antidepressiver** for norske klinikere. Egne tekster skal bruke dette ordet; originaltitler og nødvendige ordrette kildeutdrag endres ikke for å normalisere terminologien. Bruk virkestoffnavn, norsk klinisk språk, tydelige enheter og eksplisitt usikkerhet.

Monografien er en versjonert visning over kildebelagte kunnskapsobjekter, ikke et stort frittstående tekstdokument. Samme kontrollerte opplysning skal kunne gjenbrukes i monografi, sammenligning og senere støtte for nedtrapping/bytte. Hvert meningsbærende svar skal ha eget grunnlag; en referanseliste nederst er ikke tilstrekkelig kildestøtte.

Standarden definerer **spørsmål, ikke forventede svar**. Den foreskriver ikke at et bestemt virkestoff har en fordel, risiko, effektstørrelse eller anbefalt dose. Negativ, usikker og motstridende evidens er gyldige forskningsutfall. Glemt arbeid, manglende tilgang og teknisk svikt er ikke slike utfall.

### Klinisk omfang

Monografien skal dekke virkestoffets relevante bruk i Norge, ikke bare én depresjonsstudie eller én ATC-etikett. Start med alle identifiserte norske godkjente indikasjoner og formuleringer, og undersøk klinisk relevant bruk utenfor godkjenning gjennom kildepolitikken. Skill godkjenning, dokumentert effekt og faglig anbefaling.

Hovedvisningen kan prioritere voksne, men godkjent bruk hos barn/unge og sikkerhetsopplysninger om særlige grupper må ikke forsvinne. Aldersgrenser, indikasjon og behandlingsfase følger hvert svar. Godkjenningsstatus er produkt-/formulerings- og indikasjonsspesifikk, ikke automatisk identisk for alle produkter med samme virkestoff.

«Major depressive disorder» skal ikke automatisk oversettes til «alvorlig depressiv lidelse». Bruk en klinisk riktig norsk diagnosebetegnelse, behold MDD som originalbegrep ved behov og angi depresjonens alvorlighetsgrad separat.

## 2. Felles svarstruktur

Dette er semantiske krav til den senere maskinlesbare kontrakten, ikke nye databasefelter eller et implementert JSON-skjema.

| Del | Påkrevd innhold |
| --- | --- |
| Identitet | Stabil spørsmålsmal-ID, standardversjon, konkret behov-ID og monografiutgave |
| Avgrensning | Virkestoff; relevante produkt/formulering/administrasjonsvei; indikasjon; populasjon og alvorlighetsgrad; behandlingsfase; dose; komparator; utfall og tidsrom. Ikke-relevante dimensjoner markeres eksplisitt. |
| Relevans | Relevant, ikke relevant med begrunnelse, eller ennå uavklart; betingelsen og grunnlaget for avgjørelsen |
| Svar | Strukturert verdi/estimat, attribuert råd eller kildebelagt sammenfatning; ingen betydningsfull kvalifikasjon bare i fritekst langt unna |
| Kunnskapstype | Regulatorisk opplysning, preparatdata, forskningsfunn/-syntese, attribuert retningslinjeråd eller eksplisitt farmakologisk/redaksjonelt resonnement |
| Dokumentasjon | Kilder og eksakte kildeversjoner, lokalisering, relevante funn, eventuell studiekobling og separat kildestøttekontroll |
| Usikkerhet | Faglig konklusjon og begrensninger; evidenssikkerhet når relevant; motstridende funn; søke-/tilgangsbegrensninger separat |
| Aktualitet | Relevant søkedato, kildeversjonsdato, siste kontroll og eventuell utdatert status |
| Endringer | Opphav, revisjon, manuelle endringer/låsinger og hvilke tidligere svar som videreføres |

Et spørsmål må være mer presist enn «sertralin + effekt». Effekten ved én indikasjon, én pasientgruppe og én behandlingsfase kan ikke stille erstatte et svar for en annen. Ingen teknisk unikhetsregel på bare virkestoff og tema skal tvinge disse svarene sammen.

### Svarformer

**Faktum:** strukturert tekst eller klassifikasjon med nødvendig omfang og kilde. **Tabell:** en samling slike poster, der hver rad har egen identitet og dokumentasjon. **Estimat:** tall med definisjon og kontekst nedenfor. **Råd:** handling, hvem den gjelder, betingelser, unntak, oppfølging og hvem som anbefaler den. **Profil:** flere navngitte delutfall med egne svar; ikke en udokumentert totalskår. **Avledet:** sammensatt av allerede kontrollerte svar uten ny klinisk kunnskap.

For tall lagres opprinnelig verdi, enhet og statistisk betydning. Et intervall må angi om det er variasjonsbredde, referanseområde, konfidensintervall eller troverdighetsintervall. Standardavvik er ikke standardfeil. Omregninger merkes som beregnet, med formel, inndata, analytt og kontroll; manglende tall fylles ikke inn ved gjetning.

Et klinisk estimat trenger utfallsdefinisjon, instrument/skala, arm og komparator, dose, populasjon, tidspunkt, analysepopulasjon, nevner der relevant, frafall, estimattype og rapportert presisjon. Behold eksakt tidsrom selv om brukerflaten grupperer det som akutt-, fortsettelses- eller vedlikeholdsbehandling. Antidep skal ikke gjøre forskjellige perioder like ved å omdøpe dem. Denne kontekstualiseringen bygger blant annet på S05; feltvalgene er Antideps produktkontrakt.

Fravær på et enkelt datafelt merkes særskilt: ikke rapportert, ikke målt når kilden uttrykkelig støtter dette, ikke entydig ekstraherbart eller ikke relevant. Taushet er ikke dokumentasjon på at noe ikke ble målt. Manglende presisjonsmål kan begrense et estimat uten å oppheve alt annet kilden faktisk dokumenterer.

## 3. Spørsmålsregister: 80 maler

**O** betyr obligatorisk å undersøke, ikke at et positivt eller presist svar må finnes. **B** betyr betinget fordypning etter den angitte utløseren. **A** betyr avledet visning. Alle maler skal inngå i relevansvurderingen; en ukjent betingelse er ikke det samme som en usann betingelse.

Malene gjentas når avgrensningen krever det: per produkt, indikasjon, populasjon, utfall, interaksjon eller rettet byttepar. Det faktiske antallet kunnskapsbehov vil derfor være større enn 80. Ulike delutfall i én profil blir egne kontrollerbare svar. Profilkoder viser til [kildepolitikken](SOURCE_POLICY.md).

### 3.1 Identitet og norske preparater

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN01 | Hvilket virkestoff gjelder dette? Kanonisk navn, relevante synonymer, virkestoff-/saltangivelse og identifikatorer; kombinasjonspreparater skilles ut. | O | Faktum / REG, PROD |
| MN02 | Hvilken klasse og hvilke dokumenterte virkningsmekanismer har det? Skill etablert farmakologi fra hypoteser om klinisk effekt. | O | Profil / REG, PK |
| MN03 | Hvilke norske produkter finnes? Handelsnavn, formulering, administrasjonsvei, styrke og relevant pakningsidentitet. | O | Tabell / PROD |
| MN04 | Er produktene markedsført, avregistrert eller omfattet av kjente leveringsbegrensninger? Datakilde og tidspunkt; ikke påstå lokal lagerstatus. | O | Tabell / PROD |
| MN05 | Hvordan kan hvert produkt håndteres? Like deldoser, svelging, knusing, åpning, oppløsning eller fortynning; «ikke dokumentert» må kunne vises. | O | Tabell / REG, PROD |
| MN06 | Hvilke hjelpestoffer, væskekonsentrasjoner, måleredskaper eller administrasjonsforhold har praktisk klinisk betydning? | O; detaljposter bare ved relevant forhold | Tabell / REG, PROD |
| MN07 | Hvilke små doser kan faktisk gis med dokumenterte norske produktmuligheter? Skill ordinært markedsførte, importerte og apotektilvirkede alternativer. | O | Tabell / PROD, REG |
| MN08 | Hvilke norske refusjonsvilkår er relevante for aktuelle produkter/indikasjoner? Skill refusjon fra godkjenning og oppgi kontrolltidspunkt. | O | Tabell / PROD |

### 3.2 Indikasjoner og behandlingsrolle

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN09 | Hvilke indikasjoner og aldersgrupper er godkjent i Norge for relevante produkter? Behold ordlyd og avgrensning. | O | Tabell / REG |
| MN10 | Hvilken annen klinisk relevant bruk bør vurderes? Indikasjon, begrunnelse for inkludering, evidens og eventuelle frarådinger; ikke likestill bruk med anbefaling. | O | Tabell / EFF, POP, REG |
| MN11 | Hvilken plass har virkestoffet i relevante behandlingsanbefalinger? Første/senere behandlingsvalg, monoterapi/tillegg og hvilke pasienter rådet gjelder. | B: identifisert godkjent eller relevant annen indikasjon | Råd / EFF, POP |

### 3.3 Dokumentert effekt

Malene MN12–MN20 vurderes for hver indikasjon aktivert av MN09–MN10. For en indikasjon som ikke studeres med respons/remisjon, registreres et begrunnet ikke-relevant utfall og et passende, navngitt indikasjonsspesifikt utfall; det opprinnelige spørsmålet slettes ikke.

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN12 | Hvor stor er endringen i relevante symptomer sammenlignet med komparator? Instrument, absolutt/standardisert forskjell, tidsrom og presisjon. | B: aktiv indikasjon | Estimat / EFF |
| MN13 | Hvor mange oppnår respons? Kildens responsdefinisjon, hendelser/nevnere og absolutt/relativ forskjell. | B: aktiv indikasjon | Estimat / EFF |
| MN14 | Hvor mange oppnår remisjon? Definisjon, varighet og sammenligning; ikke bytt ut med respons. | B: aktiv indikasjon | Estimat / EFF |
| MN15 | Hva er dokumentert om tid til bedring eller klinisk viktig effekt? Skill første statistiske utslag fra pasientrelevant bedring. | B: aktiv indikasjon | Estimat eller sammenfatning / EFF |
| MN16 | Hva er effekten på funksjon, livskvalitet og andre pasientviktige utfall? Ikke utled disse av symptomskår alene. | B: aktiv indikasjon | Profil / EFF |
| MN17 | Hva er dokumentert om fortsatt behandling og tilbakefalls-/residivforebygging? Utvalgsberikelse, tidligere respons, varighet og seponering i kontrollarmen. | B: aktiv indikasjon der videre behandling er aktuelt | Profil / EFF, STOP |
| MN18 | Hvordan varierer nytte og belastning med dose? Skill dose–respons-data fra godkjent doseområde og farmakologiske antakelser. | B: aktiv indikasjon | Profil / EFF, AE |
| MN19 | Hva vet vi ved tidligere utilstrekkelig effekt eller behandlingsresistens? Behold definisjon, antall tidligere forsøk og mono-/tilleggsbehandling. | B: relevant behandlingssituasjon identifisert | Profil / EFF |
| MN20 | Hva kan faktisk sammenlignes med andre antidepressiver? Navngitt par, direkte/indirekte grunnlag, utfall, tidsrom, forskjell og usikkerhet. | B: aktiv indikasjon | Estimat eller begrunnet ikke-sammenlignbarhet / EFF |

### 3.4 Dosering, oppstart og oppfølging

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN21 | Hva er godkjent startdose per indikasjon, alder og formulering, og finnes separate faglige råd? | O; gjentas per relevant bruk | Tabell / REG, POP |
| MN22 | Hvordan titreres behandlingen? Trinn, minste intervall, vurderingspunkter og dosebegrensende forhold; merk rådets opphav. | O | Råd / REG, POP |
| MN23 | Hva er vanlig behandlingsområde og godkjent maksimaldose? Avgrens til produkt, indikasjon og gruppe; høyere faglig foreslått dose er et separat utsagn. | O | Tabell / REG, EFF, POP |
| MN24 | Hvordan tas legemidlet? Doseringshyppighet, tidspunkt, mat og praktisk administrasjon; koble til MN05. | O | Råd / REG, PK |
| MN25 | Hvilke dokumenterte råd gjelder glemt dose, behandlingsavbrudd og eventuell gjenoppstart? Ikke gi én regel for alle avbruddslengder. | O | Råd / REG, STOP |
| MN26 | Hva bør avklares før oppstart? Relevante symptomer/risikofaktorer, legemidler, undersøkelser og prøver; rutinekrav skilles fra risikobasert kontroll. | O | Råd / REG, SAFE, POP |
| MN27 | Hva bør følges opp, når og med hvilke reaksjoner på funn? Effekt, tolerabilitet, sikkerhet og behandlingsvarighet; kildegrunnlag for eventuelle terskler. | O | Råd / REG, EFF, SAFE |

### 3.5 Klinisk bivirkningsprofil

For alle profilene etterspørres forekomst, komparator, dose, varighet, registreringsmetode, alvorlighet og eventuell reversibilitet når dette er undersøkt. Ingen obligatorisk prosent eller lav/middels/høy-skår fylles inn uten grunnlag.

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN28 | Hva vet vi om seksuell funksjon? Lyst, opphisselse, orgasme og andre relevante delutfall; baselineplager og målemetode. | O | Profil / AE |
| MN29 | Hva vet vi om vekt og appetitt? Endring i kg/prosent, klinisk definert vektøkning/-tap og tidsforløp holdes atskilt. | O | Profil / AE |
| MN30 | Hva vet vi om søvn og våkenhet? Søvnighet, tretthet, søvnløshet og søvnkvalitet er egne delutfall. | O | Profil / AE |
| MN31 | Hva vet vi om aktivering, uro, angstforverring og akatisi? Skill tidlig reaksjon, vedvarende plager og grunnsykdom. | O | Profil / AE, SAFE |
| MN32 | Hva vet vi om gastrointestinale plager? Kvalme, oppkast, diaré og obstipasjon vurderes hver for seg. | O | Profil / AE |
| MN33 | Hva vet vi om svette, munntørrhet og andre autonome/antikolinerge plager? Ikke utled hele profilen av reseptorbinding alene. | O | Profil / AE, PK |
| MN34 | Hva vet vi om kognisjon, emosjonell avflatning og daglig funksjon som mulige bivirkninger? Skill sykdomseffekt og legemiddeleffekt. | O | Profil / AE |
| MN35 | Hvilke andre vanlige eller særlig plagsomme bivirkninger er relevante? Eksempelvis hodepine, svimmelhet og tremor; opprett navngitte delutfall. | O | Profil / AE |
| MN36 | Hvor ofte avsluttes behandling på grunn av bivirkninger, og hvor ofte uansett årsak? Separate utfall med tidsrom og komparator. | O | Estimat / AE, EFF |

### 3.6 Alvorlig risiko og forholdsregler

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN37 | Hvilke kontraindikasjoner og vesentlige forholdsregler gjelder? Skill absolutt kontraindikasjon fra forsiktighet og manglende data. | O | Tabell / REG, SAFE |
| MN38 | Hva er dokumentert om hvert forhåndsdefinert alvorlig risikoområde nedenfor? Risiko, disponerende forhold, kunnskapstype og praktisk konsekvens. | O; ett behov per risikoområde | Profil / SAFE, REG |
| MN39 | Hva vet vi om suicidalitet og selvskading? Alder, behandlingsfase, grunnrisiko, hendelsesdefinisjon og datakilde; absolutt risiko når mulig. | O | Profil / SAFE, EFF |
| MN40 | Finnes dokumentasjon på vedvarende symptomer eller skader etter avslutning? Skill sikkerhetssignal, observasjon og etablert risiko. | O | Profil / SAFE, STOP |
| MN41 | Hvilken betydning har behandlingen for kjøring, maskiner og sikkerhetskritisk arbeid? Klinisk påvirkning skilles fra eventuelle norske rettslige helsekrav. | O | Råd / REG, SAFE |
| MN42 | Hvilke faresignaler eller funn krever rask vurdering, behandlingsendring eller spesialistkontakt? Koble rådet til den konkrete risikoen. | O | Råd / REG, SAFE |

MN38 skal minst vurdere rytme-/ledningsforstyrrelser og QT, blodtrykksendring/ortostase, hyponatremi, blødning, kramper, mani/hypomani, serotonerg toksisitet, lever-/annen organskade, alvorlige overfølsomhetsreaksjoner, fall og klinisk betydningsfull antikolinerg belastning. Dette er **screeningsspørsmål**, ikke en erklæring om at hvert virkestoff gir hver risiko. Andre identifiserte alvorlige risikoer opprettes som tillegg med samme kontrakt.

### 3.7 Særlige pasientgrupper

Hver rad skal skille dokumentert effekt, sikkerhet, godkjenningsstatus og konkrete dose-/oppfølgingsråd. Fravær av godkjenning er ikke en grunn til å hoppe over sikkerhetsvurderingen. Alders-/funksjonsgrenser fra kilden beholdes, ikke erstattes av en antatt universell grense.

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN43 | Hva gjelder for barn og ungdom? Indikasjon, aldersgrupper, nytte, risiko og godkjent/annen bruk. | O | Profil / POP, REG |
| MN44 | Hva gjelder for eldre og skrøpelige? Dose, effektgrunnlag, multimorbiditet, fall, natrium og annen relevant oppfølging. | O | Profil / POP |
| MN45 | Hva gjelder i svangerskap? Tidlig/sen eksponering, foster-/svangerskaps-/neonatale utfall og risiko ved grunnsykdom/stopp; vurder videreføring separat fra nyoppstart. | O | Profil / POP, SAFE |
| MN46 | Hva gjelder ved amming? Melkeovergang og barnets eksponering/utfall, alder/prematuritet og praktisk oppfølging; ett eksponeringsmål er ikke alene en trygghetsdom. | O | Profil / POP, PK |
| MN47 | Hva vet vi om fertilitet og bruk rundt konsepsjon hos relevante grupper? Human dokumentasjon skilles fra dyredata og fra seksuelle bivirkninger. | O | Profil / POP, PK |
| MN48 | Hva gjelder ved nedsatt leverfunksjon? Kildens alvorlighetsinndeling, dose, kontraindikasjoner og oppfølging. | O | Profil / POP, REG, PK |
| MN49 | Hva gjelder ved nedsatt nyrefunksjon eller dialyse? Kildens funksjonsmål, terskler/enheter, aktive metabolitter og dose-/oppfølgingsråd. | O | Profil / POP, REG, PK |
| MN50 | Hvilke psykiatriske tilleggstilstander endrer vurderingen? Minst bipolaritet/mani, psykose, rusmiddelproblemer og relevante angsttilstander undersøkes; utdyp ved betydning. | O screening; B fordypning | Profil / POP, SAFE, EFF |
| MN51 | Hvilke somatiske forhold endrer vurderingen? Minst hjerte-/karsykdom, epilepsi, blødningsrisiko, metabolsk sykdom, glaukom/urinretensjon og endret gastrointestinal anatomi/absorpsjon vurderes. | O screening; B fordypning | Profil / POP, REG, PK |

### 3.8 Interaksjoner

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN52 | Hvilke enzymer/transportører er relevante for substrat-, hemmer- eller induserrolle? Dokumentert klinisk betydning og styrke skilles fra in vitro-funn. | O | Profil / INT, PK |
| MN53 | Hvilke farmakokinetiske kombinasjoner har praktisk betydning? Motpart, påvirket stoff, eksponeringsendring, klinisk utfall/råd og tidsforløp. | B: identifisert relevant kombinasjon | Relasjon / INT |
| MN54 | Hvilke farmakodynamiske kombinasjoner krever handling? Kontraindikasjon, unngåelse, dose-/monitoreringsråd og begrunnelse. | O screening; B per kombinasjon | Relasjon / INT, SAFE |
| MN55 | Hvilke interaksjoner gjelder mat, alkohol, andre rusmidler, røykestatus og natur-/kosttilskudd? Ikke gi generelle frikjennelser når data mangler. | O screening; B per relevant eksponering | Relasjon / INT |

### 3.9 Farmakokinetikk og utdypende farmakologi

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN56 | Hva vet vi om absorpsjon? Biotilgjengelighet, Tmax, mat-/formuleringseffekt, undersøkt dose og populasjon. | O | Profil / PK |
| MN57 | Hva vet vi om distribusjon? Distribusjonsvolum og proteinbinding, samt dokumentert klinisk betydning. | O | Profil / PK |
| MN58 | Hvordan metaboliseres og elimineres stoffet? Relevante enzymer, uendret renal utskillelse, metabolittdannelse og datagrunnlag. | O | Profil / PK |
| MN59 | Hvilke metabolitter bidrar farmakologisk? Aktivitet, eksponering, halveringstid og klinisk betydning; ingen automatisk likestilling med moderstoffet. | O | Profil / PK |
| MN60 | Hvilke halveringstider er relevante? Moderstoff/metabolitt, enkelt-/gjentatt dose, terminal/annen fase og populasjon. | O | Estimat eller profil / PK |
| MN61 | Hva vet vi om likevekt, akkumulering og doseproporsjonalitet? Målte funn skilles fra modellberegninger. | O | Profil / PK |
| MN62 | Hvilke eksponerings-/PD-forhold har praktisk betydning utover dette? Doseavhengig hemming, vedvarende farmakologisk effekt eller klinisk relevante reseptor-/transportørdata når dokumentert. | O screening; B fordypning | Profil / PK, INT |

### 3.10 TDM og farmakogenetikk

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN63 | Når kan konsentrasjonsmåling være nyttig, og hva kan den ikke avklare? Klinisk indikasjon og evidens/veiledning. | O | Råd / TDM |
| MN64 | Hvordan tas og tolkes prøven? Analytt eller sum, matriks, prøvetid, likevekt, enheter, referanseområde og begrensninger. | B: relevant TDM-anvendelse | Tabell og råd / TDM, PK |
| MN65 | Hvordan kan et eksisterende genetisk resultat påvirke valg/dose? Gen, fenotype, eksakt retningslinjeversjon, interaksjoner/fenokonversjon og usikkerhet. | O screening; B per relevant gen–legemiddel-par | Relasjon og råd / PGX |
| MN66 | Når bør testing vurderes, og er klinisk nytte av teststrategien undersøkt? Ikke utled testindikasjon fra MN65 alene. | O | Råd / PGX, EFF |

Avgrensningen mellom anvendelse av et genotypefunn og testindikasjon er uttrykkelig relevant i CPIC-dokumentet gjennomgått for standarden (S09). Konsentrasjoner skal ha faglig riktig analytt og enhet; der nmol/L brukes i norsk visning, skal en eventuell omregning fra originalen kunne kontrolleres.

### 3.11 Seponering og nedtrapping

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN67 | Hvilke seponeringssymptomer, forekomster og tidsforløp er dokumentert? Tidligere behandlingslengde, dose, seponeringsmåte og registreringsmetode. | O | Profil / STOP, SAFE |
| MN68 | Hva påvirker risiko eller behov for langsommere nedtrapping? Dokumentasjon for dose, varighet, tidligere erfaring og øvrige forhold. | O | Profil / STOP |
| MN69 | Hvordan vurderes mulig seponering, tilbakefall og annen årsak? Typiske kjennetegn, begrensninger og oppfølging; ingen sikker automatisk klassifikasjon. | O | Råd / STOP |
| MN70 | Hvilke nedtrappingsprinsipper er anbefalt og/eller undersøkt? Reduksjonsgrunnlag, trinn, intervaller, pauser og tilpasning etter symptomer. | O | Råd / STOP |
| MN71 | Hvordan kan et dokumentert prinsipp realiseres med norske produkter? Kobling til MN05–MN07, faktiske doser og begrensninger, ikke bare ideelle prosenttrinn. | O | Relasjon og mulighetsbeskrivelse / STOP, REG, PROD |
| MN72 | Hvilken oppfølging og håndtering anbefales ved plager under/etter nedtrapping? Pause, ny vurdering, eventuell endring og når spesialist bør involveres. | O | Råd / STOP, SAFE |

### 3.12 Bytte mellom antidepressiver

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN73 | Hvilken strategi er dokumentert/anbefalt fra A til B? Retning, dose-/formuleringsforutsetninger, direkte bytte, nedtrapping, overlapp eller legemiddelfritt intervall. | B: bestilt eller klinisk relevant identifisert byttepar | Rettet relasjon / STOP, REG, INT, PK |
| MN74 | Hvilke overlapp eller intervaller er kontraindisert, nødvendige eller usikre? Begrunnelse, aktive metabolitter og vedvarende farmakologisk virkning. | B: samme byttepar som MN73 | Rettet relasjon / STOP, REG, INT, PK |
| MN75 | Hva skal følges opp under og etter dette byttet, og når skal planen ikke brukes? Seponering, tilbakefall, interaksjoner og særgrupper. | B: samme byttepar som MN73 | Råd / STOP, POP, SAFE |

En enkelt monografi skal angi relevante byttebegrensninger og tilgang til byttefunksjonen, men fullstendighet krever ikke at alle mulige A→B-par er ferdigbehandlet. Et konkret par må være kontrollert før et handlingsforslag vises. A→B og B→A er forskjellige behov; kildedata kan gjenbrukes uten at rådet speilvendes.

### 3.13 Overdosering og toksisitet

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN76 | Hvilke forgiftningsbilder og tidsforløp er relevante? Formulering, dose når kjent, isolert/blandet inntak og usikkerhet. | O | Profil / TOX |
| MN77 | Hva vet vi om alvorlighetsgrad ved overdose og eventuelle forskjeller fra andre antidepressiver? Sammenlignbare data, eksponeringsgrunnlag og begrensninger. | O | Profil / TOX |
| MN78 | Hvilke faresignaler og norske faglige ressurser skal klinikeren henvises til? Ikke erstatt akutt vurdering med en beregnet «trygg dose». | O | Råd / TOX, REG |

### 3.14 Samlet klinisk oversikt og blindsoner

| ID | Spørsmål og minste svarinnhold | Krav | Svarform / kildeprofil |
| --- | --- | --- | --- |
| MN79 | Hva er de viktigste kliniske egenskapene, begrensningene og kunnskapshullene i denne utgaven? Kortversjon fra kontrollerte svar, uten udokumentert rangering. | A: bygges når underliggende svar finnes | Avledet / SYN |
| MN80 | Finnes andre klinisk viktige forhold standardfeltene ikke fanger? Åpent sikkerhets-/særtrekksøk; opprett navngitte behov ved funn. | O | Profil / relevante kildeprofiler etter funn |

MN80 er ikke et fritekstfelt som kan omgå kontroll. Hvert tillegg får avgrensning, kildeprofil, svarform, relevans og dokumentasjon som øvrige behov. Gjentatte tillegg på tvers av virkestoffer skal vurderes for neste standardversjon, ikke bli stadig flere engangsunntak.

## 4. Hvordan bestillingen utvides uten hjelp fra klinikeren

Start med identitet og produkter, godkjente indikasjoner, relevante annenbruksspor og obligatoriske screeningsspørsmål. Deretter aktiveres underbehov fra dokumenterte funn: eksempelvis effekt per indikasjon, genotypepar og relevante interaksjoner. Agenten skal ikke måtte vente på at redaktøren fyller en katalog med hvert endepunkt eller komparator.

Utvidelse skjer innen den versjonerte standarden og kildepolitikken. Den som ekstraherer et funn får en avgrenset oppgave og kan foreslå nye behov, men kan ikke endre sitt eget mandat eller omklassifisere resultatet for å få det godkjent. Nye faglige termer og relevansavgjørelser må ha en kontrollert vei inn. Dette er et krav til fase C, ikke en åpning for frie skrivefullmakter.

Per monografiutgave lagres hvilke konkrete behov som er opprettet, hvorfor betingede behov er aktivert eller ikke relevante, og hvilke kilder/svar de avhenger av. En ny indikasjon eller alvorlig risiko kan øke arbeidsomfanget; systemet skal vise det framfor å bevare en misvisende ferdigprosent.

## 5. Tilstander: kunnskap, arbeid og publisering

### 5.1 Relevans

`relevant`, `not_applicable` eller `undetermined`. Ikke relevant krever en positiv, kontrollerbar begrunnelse. «Ingen data», «ikke godkjent hos barn» og «ikke funnet en kilde» er ikke automatisk ikke relevant.

### 5.2 Arbeidstilstand

Ikke startet; søk pågår; kilder vurderes/innhentes; avventer tilgang; ekstraksjon/kontroll pågår; avventer avklaring; teknisk stopp; agentferdig. Årsaken til venting beholdes. Forskjellige tilstander må ikke flates ut til ett nullfelt.

### 5.3 Faglig utfall

- **Besvart:** Det finnes et kontrollert svar innen en eksplisitt avgrensning. Det kan være et nøytralt eller negativt forskningsresultat og ha lav evidenssikkerhet.
- **Ingen kvalifiserende evidens identifisert:** Dokumenterte søk er avsluttet etter kildepolitikken, men fant ikke kvalifiserende grunnlag. Beskriv søkets rekkevidde og dato.
- **Utilstrekkelig evidens:** Relevant grunnlag er vurdert, men bærer ikke et tilstrekkelig svar. Angi hvorfor, og hva som likevel kan sies.
- **Motstridende evidens:** Reelle uforenlige funn er gjennomgått og synliggjort; ikke det samme som en teknisk kontrollfeil eller uavklart agentuenighet.
- **Ikke relevant:** Relevansavgjørelsen er begrunnet og kontrollert.

Agentferdig med et av disse utfallene krever at nødvendige søk og kontroller faktisk er utført. Ingen verdi betyr ikke null effekt. En kilde som er kjent, men ikke innhentet, kan ikke uten videre erstattes av utfallet «utilstrekkelig evidens».

### 5.4 Fire forskjellige fullføringsnivåer

| Nivå | Hva det betyr |
| --- | --- |
| Dekningskart opprettet | Standardmalene er instansiert og betingelser kan fortsatt være uavklart. Ingen påstand om faglig ferdig innhold. |
| Agentferdig monografikandidat | Alle nødvendige behov i den avgrensede utgaven er håndtert, søkedekning og svar er kontrollert, og ingen betydningsfull teknisk/tilgangsblokkering er skjult. Usikker kunnskap kan fortsatt være et riktig utfall. |
| Publisert monografi | En navngitt fagperson har kontrollert det eksakte samlede klinikerinnholdet og en separat autorisert publisering er utført. Ingen automatisk publisering følger av 100 prosent arbeidsdekning. |
| Handlingsklar funksjon | Den konkrete nedtrappings-/bytteregelen har i tillegg godkjent grunnlag, gyldige forutsetninger, aktuelle produktdata og egne versjonerte tester. En publisert oversikt er ikke automatisk handlingsklar. |

En delvis monografi kan ha et kontrollert, avgrenset innhold, men må merkes **delvis** med synlige hull. Ikke kall den komplett ved å fjerne vanskelige spørsmål fra nevneren. Manglende sentral preparatidentitet, godkjennings-/doseringsgrunnlag eller sikkerhetskontroll blokkerer konkrete råd som avhenger av disse, også om resten er ferdig.

Vis minst antall relevante behov med kontrollert svar, antall gjennomgåtte kunnskapshull/motstrider, antall begrunnet ikke relevante, antall fortsatt åpne og eventuelle uavklarte betingelser. Prosent, hvis brukt, må bygge på den lagrede behovslisten for utgaven. **Arbeidsdekning og evidenssikkerhet skal aldri være samme indikator.**

## 6. Sammenligning uten falsk presisjon

Felles felter er nødvendig, men ikke tilstrekkelig for sammenligning. Monografiene kan vise samme type opplysning side om side med tydelig kontekst; påstander om forskjeller krever et eget komparativt grunnlag.

For kliniske tall kontrolleres indikasjon, populasjon/alvorlighetsgrad, dose/formulering, komparator, utfallsdefinisjon, registreringsmetode og tidsrom. En frekvenskategori i preparatomtalen, et spontant meldt symptom og et systematisk etterspurt symptom skal ikke tegnes som tre sammenlignbare prosenttall.

Direkte sammenligninger merkes som direkte. Nettverksestimater må ha dokumentert nettverk, overførbarhet og vurdering av relevante antakelser/inkonsistens. Ikke trekk fra to separate placeboeffekter og kall resultatet en bevist forskjell. Når grunnlaget ikke bærer en sammenligning, vis «ikke direkte sammenlignbart» og hvorfor.

Absolutte og relative estimater vises med usikkerhet der tilgjengelig. Beregnet absolutt effekt skal oppgi grunnrisikoens kilde. NNT/NNH er betinget av utfall, sammenligning, tidsrom og grunnrisiko og skal ikke presenteres som en fast legemiddelegenskap. Beregninger, særlig intervaller som krysser null forskjell, må håndteres av testede regler, ikke løpende språkmodellregning. S05 er et metodegrunnlag for denne delen.

Ingen generisk totalrangering, stjerner, radarskår eller lav/middels/høy-skala uten definert og kontrollert mål. En kunnskapssikkerhetsmarkør beskriver hvor godt en konklusjon er belagt, ikke hvor godt et legemiddel er. Manglende data må aldri få samme visuelle tegn som fravær av risiko.

## 7. Nedtrapping og bytte er egne produkter over kunnskapen

Monografien skal allerede dekke kunnskapen i MN67–MN75. En individuell planmotor er derimot en egen senere funksjon og må ikke aktiveres bare fordi disse feltene finnes.

Et framtidig nedtrappingsforslag trenger minst utgangspunkt i virkestoff, nøyaktig produkt/formulering, faktisk dose og hyppighet, behandlingslengde, tidligere seponeringsreaksjoner, relevante risikoforhold og ønsket oppfølging. Forslaget må angi om en prosent gjelder startdosen eller forrige dose, ønsket dose, realiserbar dose, faktisk reduksjon og hvilke produkter som gjør den mulig. Ikke lag mer presise trinn enn formuleringen kan gi.

Deling, knusing, åpning av kapsler, pelletstelling og fortynning kan ikke antas tillatt eller dosenøyaktig. Dokumentert bruk utenfor preparatomtalen, når relevant, må skilles fra godkjent håndtering og ha eget kontrollerbart grunnlag. Tilgjengelig flytende formulering i en utenlandsk veiledning dokumenterer ikke tilgjengelighet i Norge.

Halveringstid alene bestemmer verken seponeringsplager, nedtrappingstempo eller sikkert bytteintervall. Aktive metabolitter, vedvarende farmakologisk virkning, interaksjoner og kliniske forhold må kunne representeres. Ingen generell «fem halveringstider»-regel skal generere kliniske bytteråd. S08, S10 og S12 gir bakgrunn for spørsmål om individuelle strategier; standarden fastsetter ingen universell nedtrappingsprosent eller varighet.

Et bytteobjekt gjelder rettet A→B og har forutsetninger, utelukkelseskriterier, strategi, dose-/tidsregler, monitorering, stoppkriterier, kilder og versjon. Uegnet eller utilstrekkelig grunnlag skal gi «ingen plan tilgjengelig», ikke et improvisert standardskjema. Klinisk kontraindikasjon og manglende data er forskjellige forklaringer.

Sikkerhetskritiske regler krever egne versjonerte tester og eksplisitt faglig godkjenning etter konstitusjonen. Gjennomgått kunnskap uten en validert regel kan vises som informasjon, men ikke som en ferdig individuell instruksjon.

## 8. Klinikerflate og redaksjonell kontroll

Første nivå viser virkestoffet, relevant indikasjon/populasjon, få viktige kliniske hovedpunkter, nødvendige advarsler og om innholdet er komplett/delvis og oppdatert. Nivå to viser praktiske detaljer og egnede tabeller/grafer. Nivå tre viser studier, motstrid og metode. Dypeste nivå viser kildeversjon, lokalisering og kontrollhistorikk innen tillatte rettigheter.

Forbehold som endrer klinisk mening må stå ved konklusjonen, ikke bare i fordypningen. Visuelle framstillinger skal ha forståelige akser, enheter, nevnere og usikkerhet; farge skal ikke være eneste bærer av status. Mobilvisningen skal ha samme faglige innhold uten å tvinge brede datatabeller inn i hovednivået.

Klinikere med mandat skal kunne redigere tekst og strukturerte svar, tilføre/forkaste kilder og begrense utvalgte områder til manuelt forhåndsgodkjente kilder i admin-UI. Vanlige endringer skal ikke kreve kode. Redigering oppretter en ny revisjon, viser endringen og påvirkede avhengigheter, og kjører relevante kontroller igjen. En låst manuell rettelse skal ikke overskrives av agentene; ny motstrid blir et synlig forslag.

Den obligatoriske navngitte sluttkontrollen før publisering beholdes. At mennesket ikke skal utføre mellomarbeidet, betyr ikke at publiseringsporten er valgfri. Sluttkontrollen skal gjelde den samlede kandidatversjonen og den klinikerpresentasjonen som faktisk tas i bruk, ikke et klikk per lite databasefelt. Eksisterende påstandskandidater må ikke feilaktig omtales som om de allerede er en slik monografikandidat.

## 9. Endringsregler og grenser mot dagens system

De eksisterende kildene, evidensfunnene, påstandene, kontrollene og historikken er fundamentet. Ikke riv dette ned, men ikke anta at alle nye svarformer passer i samme tabell. Norsk preparatstyrke, et forskningsestimat og et attribuert råd trenger forskjellige innholdskontrakter med felles sporbarhet.

Fase C skal implementere det som mangler: versjonert spørsmålsregister og behovsinstanser, autorisert agentstyrt relevans-/kildeutvalg, kontrollerte kildeformer også for preparatdata, studie-/rapportkobling, monografikandidat med samlede avhengigheter, og automatisk forslag til revisjon ved ny evidens. Dagens begrensning på ny syntese av allerede eksisterende påstander må håndteres, ikke skjules med en ny påstand hver gang.

Gjeldende [databasearkitektur](DATABASE_ARCHITECTURE.md), [evidenskjede](EVIDENCE_PIPELINE.md) og [innholdsstyring](CONTENT_GOVERNANCE.md) beskriver implementasjonen. Denne standarden beskriver målkrav og endrer ingen eksisterende port, rolle eller tillatelse. PDF-/fulltekstkrav må ikke omgås for å få nye kildetyper til å passe; se Source Policy om kontrollert utvidelse.

Spørsmåls-ID-er er stabile. Nye obligatoriske spørsmål eller endret klinisk betydning krever ny standardversjon og eksplisitt migrering av dekningskartet. En formulering uten meningsendring kan være en mindre revisjon. Ikke endre spørsmålet under et eksisterende godkjent svar. Avledede korttekster må oppdateres og kontrolleres når grunnlaget endres.

## 10. Akseptansegrunnlag for sertralinpiloten

Ingen kliniske sertralinsvar er fylt inn i denne leveransen. Den senere piloten skal starte med virkestoffbestillingen, ikke en håndplukket artikkelliste, og prøve hele veien til en faktisk lesbar monografi.

Følgende tilfeller må kunne demonstreres:

1. Automatisk opprettede behov dekker hele standarden, aktiverte indikasjoner og produktvarianter, med begrunnede betingelser.
2. Ett dokument kan fylle flere behov, og ett behov kan bygge på flere dokumenter uten dobbelttelling av studier.
3. Et tall med feil arm, utfall, nevner, enhet eller tidsrom avvises selv om tallet står i originalen.
4. Et søk uten relevante funn skilles fra manglende fulltekst, ukjørt søk og teknisk svikt; ingen av dem gir automatisk «ingen risiko».
5. Uforenlige målemetoder eller populasjoner hindrer en misvisende tall-/graf­sammenligning.
6. Et usikkert svar kan presenteres ærlig, men ikke gi en ubegrunnet doserings-/bytteregel.
7. En norsk produktbegrensning hindrer et urealiserbart dosetrinn, selv om det matematiske trinnet er korrekt.
8. A→B arver ikke B→A-regelen; vedvarende virkninger må kunne overstyre en enkel eliminasjonsberegning.
9. Ny evidens gir et kontrollert revisjonsforslag, mens manuell overstyring og tidligere publisert versjon bevares.
10. Kortversjon og fordypning formidler samme kliniske mening, også på mobil, og kritiske forbehold er synlige før brukeren handler.
11. Sluttkontroll/publisering gjelder nøyaktig den samlede utgaven som ble sett; en endring i grunnlaget krever ny kandidat.
12. Faglig feilrate, vesentlige utelatelser, ubegrunnede konklusjoner, andel autonomt gjennomførte behov og faktisk menneskelig arbeidsmengde vurderes i piloten. Antall grønne tekniske tester alene dokumenterer ikke faglig kvalitet.

Ved funn revideres standarden eller kildepolitikken med begrunnelse. Ikke gjør sertralinspesifikke unntak i infrastrukturen for å få demonstrasjonen grønn. Skaler først når den generelle arbeidsformen og den kliniske presentasjonen er etterprøvd.
