# Antidep Source Policy v1

Versjon: **1.0.0**. Utarbeidet: **2026-09-17** av ChatGPT etter repo-eiers startsignal til fase A og B i [monografiplanen](MONOGRAPH_PLAN.md).

Status: **faglig spesifikasjon, implementert som versjonert kontrakt i fase C, men ikke validert i en reell monografikjøring**. De 13 kildeprofilene og deres obligatoriske søkespor ligger i `knowledge.monograph_source_profiles` og `knowledge.monograph_search_tracks`, og `src/monograph/standard.test.ts` leser dette dokumentet på nytt ved hver kjøring og krever at hver rad er den samme. Den faglige valideringen er fase D ([overleveringen](MONOGRAPH_PHASE_D_HANDOVER.md)). Dette dokumentet er ikke en registrert kildevurdering eller menneskelig publiseringsgodkjenning. [Konstitusjonen](ANTIDEP_CONSTITUTION.md) og eksisterende tilgangs- og publiseringskontroller gjelder uendret.

## 1. Formål og avgrensning

Antidep skal få et kunnskapsbehov fra [monografistandarden](MONOGRAPH_STANDARD.md), ikke vente på at en kliniker velger en artikkel. Agentene skal søke, velge, begrunne, innhente, kontrollere og sammenstille. Mennesker kan supplere eller overstyre redaksjonelt, men er ikke ordinær transport mellom leddene.

Dette er en spørsmålsspesifikk policy for en vedlikeholdt klinisk kunnskapstjeneste. Den lover ikke at hver monografi er en ny, uttømmende systematisk oversikt. Antideps praktiske stopp- og oppdateringsregler nedenfor er egne produktvalg, ikke validerte terskler fra Cochrane eller andre organisasjoner. Kliniske anbefalinger og effektstørrelser må undersøkes særskilt når en monografi bygges.

Et spørsmål kan kreve flere kilder; én kilde kan dekke mange spørsmål og flere virkestoffer. Gjenbruk søk, dokumenter og kontroller når avgrensning og versjon faktisk er de samme. Ikke gjør 80 spørsmålsmaler til 80 isolerte litteratursøk eller 80 obligatoriske artikler.

## 2. Skill mellom hva en kilde kan dokumentere

| Kunnskapstype | Hva den kan si | Hva som ikke følger automatisk |
| --- | --- | --- |
| Norsk regulatorisk opplysning | Hva gjeldende godkjent preparatomtale sier om et bestemt preparat i Norge | At anbefalingen er en sammenlignende effektkonklusjon eller at all bruk utenfor godkjenningen mangler dokumentasjon |
| Norsk preparat-/vareopplysning | Registrert formulering, styrke, pakning, markedsføringsstatus og oppdateringstid | At varen finnes på et bestemt apotek nå, eller at en tablett kan deles i like doser |
| Forskningsfunn | Hva én studie eller en kontrollert forskningssyntese viser innen sin avgrensning | En anbefaling for alle pasienter eller alle midler i samme klasse |
| Retningslinje eller faglig råd | Hva en identifisert faglig instans anbefaler, med dato og forutsetninger | At rådet er et målt forsøksresultat eller er norsk godkjent dosering |
| Farmakologisk resonnement | En eksplisitt slutning fra dokumenterte premisser | At den kliniske konsekvensen er observert eller at en beregnet bytteplan er validert |
| Antideps redaksjonelle syntese | En begrunnet sammenstilling av de foregående typene | Tillatelse til å legge til nye, ukontrollerte fakta |

Preparatomtalens struktur er et utgangspunkt for regulatoriske spørsmål (S01). Norske strukturerte legemiddeldata er et annet kildegrunnlag enn forskningsartikler (S02–S03). Hver opplysning skal beholde sin kunnskapstype helt til klinikervisningen.

**Godkjent kilde er ikke en universell godkjenning.** Lagre en vurdering av kildeversjonens egnethet for et navngitt spørsmål og en bestemt bruk. En kilde kan være egnet for farmakokinetikk og uegnet for sammenlignende klinisk effekt. Bibliografisk korrekt, lesbar, relevant, metodisk sterk og publiserbar er forskjellige egenskaper.

## 3. Kildeprofiler

Profilkodene brukes i monografiens spørsmålsregister. Flere koder i samme rad betyr at forskjellige deler av svaret trenger hvert sitt grunnlag; de er ikke alternative snarveier. En kilde som foretrekkes her, må fortsatt vurderes konkret.

| Profil | Spørsmål | Første kildevalg | Suppler når nødvendig og særskilt kontroll |
| --- | --- | --- | --- |
| REG | Norsk godkjenning, dosegrenser, kontraindikasjoner, preparathåndtering | Gjeldende norsk myndighetsgodkjent preparatomtale, identifisert via DMP/Legemiddelsøk; relevant EMA-produktinformasjon når den gjelder produktet | Faglige råd merkes separat. Behold forskjeller mellom produkter, formuleringer, indikasjoner og aldersgrupper. Kontroller at versjonen ikke er avløst. |
| PROD | Preparater, styrker, pakninger, markedsføring og refusjon | Gjeldende DMP-legemiddeldata, FEST/FHIR der egnet og tilgjengelig, samt produktets preparatomtale | Mangelsituasjon og lokal lagerstatus er egne forhold. Leverandørens faktiske datadekning og vilkår må kontrolleres før integrasjon. En synlig delestrek er ikke dokumentasjon på like deldoser. |
| EFF | Effekt, dose–respons, behandlingsfaser og sammenligning | Relevante systematiske oversikter, eventuelt nettverksmetaanalyser, med lesbar metode og dekkende populasjon, komparator og utfall | Oppdateringssøk etter oversiktens siste søkedato; sentrale primærstudier ved hull, motstrid eller behov for kontroll. Observasjonsstudier vurderes separat, ikke som automatisk erstatning for randomisering. |
| AE | Vanlige bivirkninger og behandlingsavbrudd | Kontrollerte studier og systematiske oversikter med brukbare nevnere og registreringsmetoder; preparatomtalen som regulatorisk oversikt | Skill aktiv utspørring fra spontanrapportering i en studie, varighet, dose og baselineplager. Frekvenskategorier fra forskjellige preparatomtaler er ikke en komparativ studie. |
| SAFE | Alvorlige, sjeldne eller vedvarende skader | Preparatomtaler og myndighetenes sikkerhetsvurderinger, supplert med egnede oversikter, store observasjonsstudier og målrettede primærstudier | Kasuistikker og meldesystemer kan gi signaler; de gir ikke alene insidens eller bevist årsak. Kontroller eksponering, nevner, tidsforløp, alternative forklaringer og mulig rapporteringsskjevhet (S11). |
| POP | Graviditet, amming, alder, organsvikt og komorbiditet | REG for godkjenningsgrenser; relevante spesialistretningslinjer og systematiske oversikter/primærstudier i den aktuelle gruppen | Teratologiske/laktasjonsfaglige oppslagsverk og norske faglige råd kan brukes som attribuert veiledning når versjon, begrunnelse og tilgang kan kontrolleres. Skill risiko ved behandling fra risiko ved sykdom og behandlingsstopp. |
| INT | Interaksjoner og praktisk håndtering | REG og dokumenterte kliniske interaksjonsstudier; egnet nasjonal interaksjonsinformasjon og faglige retningslinjer | Skill eksponeringsendring fra dokumentert klinisk utfall, in vitro fra mennesker og mekanisme fra håndteringsråd. Registrer begge virkestoffene, retning, dose, varighet og vedvarende virkning etter stopp. |
| PK | Farmakokinetikk og farmakodynamikk | REG og humane PK-/PD-studier, supplert med faglige synteser | Arts-/in vitro-data merkes og kan ikke alene begrunne klinisk effekt. Behold dose, formulering, analytt/metabolitt, matriks, tidspunkt, studiepopulasjon og målemetode. |
| PGX | Genetikk og klinisk anvendelse | Relevante CPIC-/DPWG-anbefalinger med identifisert versjon, supplert med REG og studiene anbefalingen bygger på | Skill hvordan et eksisterende prøvesvar brukes fra hvem som bør testes. CPIC-dokumentet undersøkt her beskriver det første, ikke generell testindikasjon (S09). Behold uenighet mellom retningslinjer. |
| TDM | Konsentrasjonsmåling og fortolkning | Identifiserte faglige TDM-retningslinjer og norske laboratoriers dokumenterte analyse-/fortolkningsveiledning; relevante PK- og kliniske studier | Et laboratorieintervall, et konsensusbasert terapeutisk referanseområde og et dokumentert konsentrasjon–effekt-forhold er forskjellige. Registrer analytt, matriks, prøvetid, likevekt, enhet og metode. |
| STOP | Seponering, nedtrapping og bytte | Relevante retningslinjer og faglige råd, inkludert NICE og NHS SPS der anvendelige; kontrollerte studier og oversikter når de finnes | REG, PROD, PK og INT er tilleggskrav ved konkrete doser/bytteplaner. Skill veiledning og farmakologisk ekstrapolasjon fra empirisk sammenlignede strategier. Norske formuleringer må kontrolleres særskilt (S08, S10, S12). |
| TOX | Overdosering og forgiftningsrisiko | Norske oppdaterte toksikologiske anbefalinger når tilgjengelige, REG og relevante humane forgiftningsstudier | Skill terapeutisk bruk fra overdose, isolert inntak fra blandingsinntak, og klinisk risiko fra rapporteringsfrekvens. Akutt behandling er ikke en automatisk doseringsfunksjon i v1. |
| SYN | Kortoversikt og gjenbruk | Allerede kontrollerte svar på de underliggende spørsmålene | Ingen ny ekstern faktakilde og ingen ny klinisk slutning i sammendragsleddet. Alle meningsbærende forbehold og avvik skal følge med. |

Felles minstekrav: identifiserbar avsender og kildeversjon, relevant avgrensning, tilstrekkelig originalmateriale for påstanden, etterprøvbar lokalisering, registrerte begrensninger og faktisk utført kontroll. Kildens prestisje eller antall siteringer erstatter ingen av disse kravene.

## 4. Fra spørsmål til dokumentert søk

### 4.1 Planlegg før resultatene styrer utvalget

Opprett en søkeplan per faglig sammenhengende spørsmålsgruppe. Den skal peke på monografiversjon og konkrete behov, angi virkestoffets navn/synonymer, indikasjon/populasjon, utfall, behandlingsfase og ønskede studiedesign. Ikke lås søket til et forventet svar eller en forventet skaderetning.

Kildene skal kunne oppdages bredere enn den senere analyseavgrensningen: et for smalt søk som krever at alle utfall står i tittel eller abstract, skal ikke være eneste søk. Søkeplanen skal ha et bredt orienterende søk og målrettede tillegg der det trengs. Metodegrunnlaget for dokumentasjon og studieidentifisering er S04 og S06; den konkrete arbeidsformen nedenfor er Antideps tilpasning.

### 4.2 Minimumsdekning per profil

| Profiler | Søkespor som må være forsøkt og dokumentert før ferdigvurdering |
| --- | --- |
| REG, PROD | Direkte kontroll i relevant norsk myndighetskilde og kildeversjon; alle identifiserte relevante produkter/formuleringer; kontroll av endrings-/mangelopplysninger når slike opplysninger skal vises. |
| EFF, AE | PubMed/MEDLINE, et særskilt oversiktssøk, et supplerende uavhengig søkespor som CENTRAL eller en egnet annen database, referanselister og nyere siterende arbeider for sentrale kilder. Forsøksregistre brukes til å lete etter oversette, uavsluttede eller upubliserte studier. |
| SAFE, POP | Relevant regulatorisk/spesialisert veiledning, oversiktssøk og målrettet søk etter egnede observasjons-/sikkerhetsdata; forsøksdata når de besvarer spørsmålet. Ikke bruk et RCT-filter som eneste inngang til sjeldne skader. |
| PK, INT | Preparatomtale, målrettet søk etter humane originalstudier og egnet faglig veiledning. Følg referanser når parameterens definisjon eller kliniske råd er uklare. |
| PGX, TDM | Retningslinjeeierens/laboratoriets gjeldende dokumentasjon og et oppdateringssøk etter nye eller motstridende studier. En gammel kjent veiledning kan ikke alene dokumentere at dagens anbefaling er uendret. |
| STOP, TOX | Gjeldende relevant veiledning, målrettede oversikts-/primærstudiesøk og nødvendige REG/PROD/PK/INT-kontroller for konkrete tiltak. |
| SYN | Kontroller at alle brukte svar fortsatt gjelder den samme avgrensningen og kandidatversjonen. Ingen selvstendig litteraturjakt i sammendragsleddet. |

Ikke alle kilder eller databaser er nødvendigvis tilgjengelige i en agentkjøring. En utilgjengelig obligatorisk søkevei registreres som begrensning, ikke som null treff. En erstattende søkevei må begrunnes og kontrolleres separat. Delvis søk kan gi et tydelig merket delutkast, men ikke status som ferdig søkedekning.

Ingen automatisk avgrensning til åpen tilgang, engelsk språk, siste fem år eller statistisk signifikante resultater. En avgrensning kan være begrunnet, men må stå i planen og i begrensningene. Søk gjerne først etter en dekkende nyere syntese; eldre originalstudier blir ikke ugyldige fordi de er gamle.

### 4.3 Søkelogg og utvalgslogg

Lagre faktisk utført søk: database og plattform, eksakt søkestreng, filtre, dato/tid, versjon på søkeplanen, returnert treffantall når kjent, hvor mye som ble gjennomgått, og om paginering/resultatgrenser avkortet trefflisten. En foreslått søkestreng er ikke et utført søk. En side med ti treff er ikke et søk uten flere treff.

For hvert kandidatdokument: identifikatorer, bibliografi, oppdagelsesvei, mulige behov det dekker, beslutning og begrunnelse. Bruk atskilte utfall: valgt til innhenting, inkludert for navngitt bruk, ekskludert med faglig grunn, avventer tilgang, eller avventer avklaring. Betalingsmur er ikke en faglig eksklusjonsgrunn. Registrer også kontrollerte nullsøk.

Søkestrategier og avgrensninger skal være lesbare for en fagperson, men tekniske identifikatorer og transport håndteres av systemet. PRISMA-S er et rapporteringsgrunnlag, ikke en erklæring om at Antidep har gjennomført en PRISMA-kompatibel systematisk oversikt (S06).

### 4.4 Hvem som utfører søket, og hvem som vurderer det

Søke-I/O er systemets egen deterministiske kode. En KI-agent i kildeleddene planlegger ikke et nettverkskall og utfører ikke et: den får de maskinelt utførte søkene med endepunkt, søkestreng, treffantall og et fingeravtrykk av svaret, og gjør den semantiske vurderingen av dem — hva som er relevant, til hvilket behov, hva som med rimelighet kan endre hovedkonklusjonen, og hva som mangler. Trenger den flere eller mer målrettede søk, ber den om dem som en strukturert søkeforespørsel; den deterministiske søkeveien utfører dem og gir leddet neste vurderingsrunde.

Rekkefølgen er en port og ikke en forventning: en semantisk kildeoppgave skal ikke kunne hentes ut før den maskinelle søkerunden for nettopp den planversjonen faktisk er utført. En oppgave som krever søke-I/O agenten ikke har verktøy til, er ikke en oppgave — den er en umulighet, og den skal ikke finnes.

Et modellrapportert søk og et maskinelt utført søk er fortsatt to forskjellige opplysninger (§4.3), og de blandes ikke. Kildeleddene har ingen vei til å rapportere et søk de skulle ha utført, og et svar som gjør det, avvises.

En søkeforespørsel kan bare be om det den deterministiske søkeveien faktisk gjør: en navngitt søketjeneste av dem systemet allerede kaller, en søkestrategi og noen termer. En adresse kan ikke oppgis. Antall runder per planversjon er begrenset; er budsjettet brukt opp, er arbeidet åpent og ventende (§8.2) og aldri en konklusjon om evidensen.

## 5. Innhenting og kildeintegritet

Før et menneske bes om en PDF, skal agenten undersøke originalutgiver, tilgjengelig åpen fulltekst, egnet institusjonelt arkiv og eventuelle allerede autoriserte tilganger. Bruk eksisterende privat kildebibliotek før ny innhenting. Ingen betalingsmur eller tilgangskontroll skal omgås, ingen betaling skal foretas uten mandat, og ingen personlige innlogginger skal etterlignes.

Når menneskelig hjelp faktisk er nødvendig, skal forespørselen være samlet og faglig: hvilken artikkel som mangler, hvorfor den kan endre svaret og hvilken fulltekst som trengs. Ikke be klinikeren gjenskape søk, velge databaseidentifikatorer eller avgrense ekstraksjonen på nytt. Ikke be om 50 PDF-er når fem dekkende kilder og målrettede tillegg er tilstrekkelige.

For forskningsfunn gjelder konstitusjonens fulltekstkrav: les og kontroller komplett nødvendig originalmateriale, inkludert tabeller, figurer og relevante vedlegg. Abstract, søkesnutter, registeromtale, registerresultater alene og KI-oppsummeringer er discovery, ikke godkjent klinisk ekstraksjonsgrunnlag i denne versjonen. Registre kan samtidig synliggjøre at publisert litteratur er ufullstendig (S04).

Kontroller dokumentidentitet, versjon, lesbarhet, tabell-/figurtilhørighet og lokalisering. En korrekt DOI i teksten beviser ikke alene at alle sider/vedlegg er med. Kritiske tabellverdier må kontrolleres i den faktiske tabellen med overskrifter, armer, fotnoter og nevner; rekkefølge i et tekstuttrekk er ikke tilstrekkelig. Kan grunnlaget ikke kontrolleres, hold det aktuelle svaret åpent.

**Et formatkrav må ikke bli en påstand om evidens.** Fremtidig innhenting må kunne håndtere myndighetsdata og fullstendig originaltekst i egnede formater. Et komplett HTML-/XML-dokument er ikke et abstract fordi det ikke er PDF. Men dagens tekniske PDF-port består uendret: støtte for andre representasjoner og regulatoriske dataposter krever en kontrollert implementering i fase C før de kan brukes. Ikke merk data som `full_text` for å passere en eksisterende port, og ikke lag en PDF av en søkesnutt som erstatning for originalen.

Lagringsrett, rett til agentbehandling og rett til offentlig gjengivelse skal avklares hver for seg ut fra kildens vilkår og prosjektets autoriserte bruk. Ingen blankettrett følger av at en fil kan lastes ned. Fulltekster og omfattende utdrag holdes utenfor offentlig repo. En offentlig klinikerside skal kunne vise egne kildebelagte sammenfatninger og referanser uten å gjøre det private fulltekstbiblioteket offentlig. Dette er krav til senere løsning, ikke en juridisk konklusjon om en bestemt lisens.

## 6. Kvalitetsvurdering og motprøving

### Tre forskjellige vurderinger

1. **Dokumentet:** Er dette riktig, tilgjengelig, komplett og uendret kildeversjon?
2. **Funnene:** Er avlesning, tolkning og sammenheng riktige, og hvilke metodiske svakheter har studien/oversikten?
3. **Det samlede svaret:** Hvor sikkert og overførbart er kunnskapsgrunnlaget for akkurat denne konklusjonen?

For systematiske effektoversikter brukes en dokumentert metodevurdering, med AMSTAR 2 der verktøyet passer. Ikke lag en sammenlagt kvalitetspoengsum som skjuler en kritisk svakhet; AMSTAR 2 er ikke ment som en slik sum (S07). For randomiserte resultater brukes passende RoB 2-versjon eller begrunnet tilsvarende metode (S13). For ikke-randomiserte intervensjonseffekter og andre studiedesign velges et egnet designspesifikt verktøy med navngitt versjon; vurderingen skal ikke kalles en full instrumentvurdering hvis bare enkelte domener er gjennomgått.

Kontroller særlig sammenlignbarhet ved baseline, indikasjonsskjevhet, eksponeringsklassifikasjon, frafall, analysepopulasjon, forhåndsregistrerte utfall, manglende resultater, selektiv rapportering, finansiering og interessekonflikter. Interessekonflikt er informasjon som skal vurderes, ikke en automatisk godkjenning eller forkasting.

GRADE brukes når egnet til sikkerhet i et samlet effekt-/risikogrunnlag for et konkret utfall og en konkret sammenligning, ikke som én karakter til en artikkel, et virkestoff eller en hel monografi. Vurder skjevhet, inkonsistens, indirekthet, upresisjon og publikasjonsskjevhet. Skill evidenssikkerhet fra anbefalingsstyrke (S05). Norske godkjenningsfakta får kilde-/aktualitetskontroll, ikke en oppdiktet GRADE-karakter.

### Uenighet er arbeid, ikke automatisk feil

Motstridende studier skal undersøkes for ulik dose, populasjon, komparator, oppfølging, målemetode, frafall og analyse. Ikke avgjør ved flertall av artikler eller agenter. Kan faglig motstrid ikke løses, bevar resultatene og konkluder med relevant usikkerhet. Et lavt p-nivå sier ikke alene at en forskjell er klinisk viktig; manglende statistisk signifikans skal ikke omskrives til likeverdighet.

Motprøvingen skal også søke etter kilder som den første agenten overså. Et kontrollledd som bare leser generatorens utvalgte referanser, kan kontrollere sitatene, men ikke alene vurdere søkets dekningsgrad. Kildeutvalg og sentrale eksklusjoner må derfor ha egen separat kontroll før et søk lukkes.

Kontrollens egne søk utføres av den deterministiske søkeveien, under kontrollrollens egen identitet og kjøring, og med en annen søkestrategi enn generatorens — målrettede passeringer der generatoren søkte bredt. At kontrollen faktisk har søkt selv, utledes av søkeloggen og erklæres ikke i svaret: en erklæring om egen uavhengighet som kan bestås ved å skrive den, kontrollerer ingenting. En godtatt dekning uten et eget søk som faktisk gikk, avvises.

Modellseparasjon og deterministiske kontroller beholdes som prosjektgrenser, men enighet mellom modeller er ikke i seg selv fasit. Den senere pilotens faglige kontroll skal prøve originalkilder, utelatelser og klinisk mening, ikke bare om agentene er enige.

## 7. Studie, rapport og oversikt må holdes fra hverandre

Én studie kan ha protokoll, registeroppføring, hovedartikkel, sekundæranalyse, langtidsoppfølging og rettelse. Knytt disse sammen med studieidentitet og dokumenter grunnlaget for koblingen; tittel-likhet er ikke nok. Flere rapporter blir ikke flere uavhengige deltakerutvalg.

En oversikt og de inkluderte primærstudiene er heller ikke uavhengige bekreftelser. Ved bruk av flere oversikter må overlapp i studier vurderes. Velg et begrunnet syntesegrunnlag, og ikke summer deltakere eller gjennomsnittsberegn estimater på tvers av overlappende materiale. Ved oppdatering med nye studier må det skilles mellom en narrativ oppdatering og en ny statistisk metaanalyse. Den siste krever en egen dokumentert analyse, ikke regning gjort i løpende generert tekst.

Kravet er implementert, og på to nivåer. `knowledge.study_reports` bærer rapportene om én studie, og `knowledge.review_included_studies` bærer overlappet gjennom en oversikt — en egen tabell, fordi relasjonen er mange-til-mange og rapportkoblingen med rette håndhever at én kilde hører til høyst én studie. `knowledge.study_units_for_evidence(uuid[])` leser begge, og avgjør med én regel: **en enhet er ikke uavhengig når alt den dekker, allerede er dekket av andre enheter i grunnlaget.**

- En rapport om en studie dekker den studien og er alltid sitt eget utvalg. At en oversikt nevner den, gjør den ikke overflødig, og to primærstudier slås aldri sammen — at en oversikt fører A og B, sier ingenting om at A og B deler deltakere.
- En oversikt dekker studiene den er registrert som å inkludere. Er alle lagt fram for seg, teller den ikke som et eget utvalg (`derived_review`), men beholder funnene sine og navngir enhetene den er et sammendrag av. Bærer den noe ingen andre har lagt fram, står den igjen som uavhengig for nettopp det (`partially_derived_review`), og oppgir både hva den deler og hvor mange av studiene den fører som bare finnes gjennom den.

Rekkefølgen er deterministisk og grådig: rapportene først, så oversiktene med den bredeste først. Det er en lesning av det som faktisk er registrert, og ikke et bevis om minste mulige dekning — der to oversikter dekker hverandre delvis, står begge, fordi de da bærer hver sitt.

En _usikker_ inklusjon dedupliserer som en dokumentert: den forsiktige lesningen er å behandle materialet som overlappende inntil det motsatte er vist. Men enheten sier da at sammenslåingen hviler på en usikker relasjon (`uncertain_linkage`) og navngir hvilke studier det gjelder (`uncertain_inclusions`), og avtrykket binder det — en avklaring fra usikker til dokumentert gjør derfor et utestående svar foreldet. Usikkerheten følger dekningen og ikke bare enhetens egen kobling: er studien bare _antatt_ lagt fram av den enheten som dekket den først, er overlappet usikkert uansett hvilken vei grunnlaget leses.

Avklaringen er en ny rad i `knowledge.review_inclusion_assessments` og ikke en retting: den første vurderingen ble gjort av noen, på et grunnlag, og står urørt. Sporet er append-only i databasen og ikke bare i dokumentasjonen, rekkefølgen står på et løpenummer og ikke på et tidsstempel, og koblingen låses før gjeldende tilstand leses, slik at to samtidige endringer serialiseres.

Hver rad i sporet sier både hvor sikker koblingen er og **om den gjelder**. Viser en kobling seg å være feil — oversikten inkluderte ved nærmere kontroll ikke studien likevel — trekkes den tilbake med `api.retract_review_included_study(...)`, og grupperingen leser den ikke lenger. Uten det skillet ville en feilregistrering vært permanent virksom: både `documented` og `uncertain` betyr at studien fortsatt regnes som inkludert, så et reelt uavhengig bidrag ville blitt undertrykt for alltid. Tilbaketrekkingen sletter ingenting og kan selv trekkes tilbake ved å registrere inklusjonen på nytt. Den er en _ren_ tilstandsendring: den lar sikkerhetsvurderingen stå, også når en annen økt avklarer den samtidig, slik at den som bare trakk koblingen tilbake, ikke får tilskrevet en endring av sikkerheten.

Identiteten til en studie er paret (register, nummer), og registeret utledes av nummerets egen form. Uten den utledningen ville kildeoppdagelsens «other» og redaktørens «clinicaltrials_gov» om det samme NCT-nummeret blitt to studier, og vernet uten virkning. Både synteseoppgaven og evidensvurderingen er *bundet* til uavhengighetsstrukturen: registreres et overlapp etter at oppgaven ble hentet ut, blir et svar avgitt på den gamle strukturen avvist som foreldet.

For effektoversikter vurderes søkets sluttdato, ikke bare publikasjonens år. Nyere dato er ikke alene et argument for å erstatte en bedre, mer relevant oversikt. Rettelser og tilbaketrekninger kontrolleres ved utgiver og pålitelige bibliografiske opplysninger. En tilbaketrukket kilde skal ikke bære et gjeldende klinisk svar; den og tidligere bruk av den beholdes som historikk.

## 8. Når søket kan stoppe

### 8.1 Faglig avslutning

Et spørsmål kan få ferdig søkedekning først når alle følgende er oppfylt:

- Avgrensningen og nødvendige søkespor er dokumentert; ingen skjult treffavkorting står igjen.
- Sentrale kilder og referansespor er vurdert, et oppdateringssøk er gjort når en oversikt brukes, og vesentlige motkilder er undersøkt.
- Ingen ulest eller utilgjengelig kilde som med rimelighet kan endre hovedkonklusjonen står uavklart. Vurderingen av vesentlighet må begrunnes og kontrolleres separat.
- Alle aktiverte behov har et begrunnet utfall; manglende rapportering er skilt fra manglende undersøkelse.
- En separat kontroll av søkedekningen godtar begrunnelsen for å stoppe.

For en autoritativ regulatorisk opplysning kan én riktig, gjeldende kilde være tilstrekkelig. Ikke krev en ekstra artikkel for å bekrefte en norsk godkjent styrke. For forskningsspørsmål er verken «tre kilder», «to enige modeller» eller «ingen nye topp-ti-treff» et tilstrekkelig kriterium.

Etter at minimumssporene er dekket, brukes **to ulike supplerende søkepasseringer** uten nye potensielt konklusjonsendrende kilder som praktisk metningssignal: for eksempel et utvidet term-/synonymsøk og et nyere siteringssøk. Dette er Antideps v1-heuristikk, ikke bevis på uttømmende dekning. Kjente hull eller en svak grunnsøking overstyres aldri av dette signalet.

### 8.2 Ressursgrense er ikke evidenskonklusjon

Kjøringer må ha et eksplisitt arbeidsbudsjett og kunne fortsette senere uten å begynne på nytt. Oppbrukt tid, modellkvote, utilgjengelig database, betalingsmur eller verktøyfeil gir åpent/avventende arbeid. Det gir ikke «utilstrekkelig evidens», «ingen studier» eller «ikke relevant».

Et svar med begrenset evidens er en faglig konklusjon etter undersøkelser, og skal navngi begrensningen. Et søk uten kvalifiserende studier beskrives som «ingen relevante studier identifisert i de dokumenterte søkene til [dato]», ikke som en tidløs påstand om at slike studier ikke finnes.

Hvis en betydningsfull manglende kilde gjenstår, kan et avgrenset delutkast vise hva det tilgjengelige grunnlaget sier, sammen med den konkrete mangelen. Det skal ikke telles som komplett svar for den opprinnelige, bredere bestillingen.

## 9. Vedlikehold og oppdateringer

Følgende er **foreslåtte driftsmål for v1**, ikke allerede opprettede jobber eller garanterte responstider:

| Område | Normal kontroll | Utløser utenom normal kontroll |
| --- | --- | --- |
| Norske preparat-/varedata | Følg leverandørens faktiske oppdateringer; kontroller dataversjon før en konkret plan bygges | Endret styrke/formulering, markedsføring, mangel eller håndteringsopplysning |
| Myndighetenes sikkerhetsinformasjon | Daglig sjekk av tilgjengelige relevante kanaler når overvåkingen er etablert | Ny alvorlig advarsel, kontraindikasjon eller tilbaketrekking |
| Kliniske søkegrupper | Månedlig avgrenset oppdateringssøk | Ny sentral studie/oversikt, vesentlig motstrid eller faglig feilrapport |
| Hel monografi og retningslinjegrunnlag | Minst årlig planlagt gjennomgang | Endret standard, avløst retningslinje, vedvarende uløste kunnskapshull |

Lag søk per gjenbrukbar spørsmålsgruppe der det er forsvarlig, ikke per visning av en side. Gjenbruk er ikke lov til å arve status «oppdatert» uten at søket faktisk dekker spørsmålet. Intervallene skal evalueres mot arbeidsmengde og oppdagede endringer i piloten.

Ny evidens utløser vurdering av berørte svar og et nytt utkast; den skal ikke kreve at klinikeren oppdager artikkelen eller bestiller revisjon. Menneskelig låst innhold beholdes til redaksjonell avklaring, men ny motstrid skal varsles synlig, ikke skjules. Ikke overskriv en publisert formulering eller manuell korreksjon.

Klinisk relevant endring krever ny kontroll og menneskelig publisering etter gjeldende konstitusjon. Et sikkerhetssignal skal få høy prioritet og et ærlig synlig varsel; ingen agent skal merke en tilbaketrekking, sluttkontroll eller klinisk godkjenning som menneskelig utført. Den eksisterende publiserings-/tilbaketrekkingsveien gjelder inntil en separat endring er godkjent.

Vis kildeversjon, siste relevante søkedato, siste faglige kontroll og eventuell utdatert status separat. «Siden ble åpnet i dag» er ikke «innholdet ble kontrollert i dag».

## 10. Redaksjonell kontroll uten manuelt ordinærarbeid

Standardmodusen er agentstyrt kildeutvalg innen den fastsatte policyen. I avgrensede temaer skal en redaktør kunne velge at bare navngitte, manuelt forhåndsgodkjente kilder kan brukes. Denne begrensningen skal være synlig for agentene og leseren der den påvirker svaret.

En ny relevant kilde utenfor en slik liste skal legges fram som et redaksjonelt forslag, ikke brukes i skjul og ikke bortforklares som irrelevant. En begrenset kildeliste kan gi et avgrenset svar, men kan ikke uten videre bære en påstand om at hele forskningsgrunnlaget er vurdert.

Manuelle tillegg, eksklusjoner, låsinger og overstyringer får forfatter, tidspunkt, begrunnelse, omfang og versjon. Klinikerens tekstredigering skal opprette et nytt utkast og beholde sporbarheten; den skal ikke kreve kodeendring. En menneskelig beslutning kan overstyre en faglig vurdering, men kan ikke gjøre et oppdiktet sitat, manglende kilde eller ikke-utført kontroll til dokumentert kunnskap.

Vanlige faglige uenigheter søkes løst og fremstilt av agentkjeden. Det som eskaleres til mennesker, er avgrensede redaksjonelle valg, nødvendig kildetilgang eller sluttkontroll av et samlet produkt, ikke en strøm av spørsmål om hver artikkel.

## 11. Krav til fase C og den senere piloten

Dette dokumentet implementerer ingen agent, database eller brukerflate. Den neste tekniske leveransen må likevel kunne bevise følgende med kontrollerte testtilfeller og deretter en reell pilot:

1. Én virkestoffbestilling lager relevante kunnskapsbehov og søkeoppgaver uten en menneskevalgt artikkel.
2. En kilde kan brukes til flere behov, mens samme studie ikke dobbelttelles via flere rapporter/oversikter. Prøvd i `supabase/tests/940_study_identity_test.sql` (flere rapporter om én studie) og `supabase/tests/950_review_overlap_test.sql` (avledet oversikt, to overlappende oversikter, og en studie som først bare hadde et navn).
3. Feil original, manglende tabell, utilgjengelig avgjørende fulltekst og avkortet søk gir riktig stopp, ikke «ingen evidens».
4. Norsk regulatorisk faktagrunnlag, forskningssyntese og attribuert faglig råd holdes atskilt; nye representasjonsformer har faktisk kontrollert støtte før bruk.
5. En motkilde kan endre et foreløpig svar. Ny evidens gir et nytt utkast til eksisterende svar uten skjult publisering.
6. En kildebegrensning eller manuell korreksjon overlever agentkjøringen og blir ikke stilletiende omgått.
7. Enighet mellom agenter er ikke eneste faglige test. Et separat kontrollutvalg vurderes mot originalmaterialet, inkludert bevisst vanskelige null-, konflikt- og feiltilfeller.
8. Manglende lisens, tilgang eller leverandørfunksjon beskrives som faktisk begrensning, ikke som en implementert evne.

Ingen ny betalt modell-API er et krav i denne spesifikasjonen. Hva de tilkoblede agentmiljøene faktisk kan gjøre, må verifiseres som drift i fase C; ikke anta at en planlagt funksjon finnes fordi den er beskrevet her.

## 12. Kilder og lesegrunnlag

Kildene nedenfor er brukt til å utforme spørsmål og metodekrav. De er **ikke** registrert eller godkjent som klinisk evidens i Antidep. Intervaller, profilkoder, stoppheuristikk og avgrensning er Antideps egne valg. Nettkontroll: 2026-09-17. Nye monografikjøringer skal kontrollere gjeldende kildeversjoner på nytt.

- **S01 — EMA.** [How to prepare and review a summary of product characteristics](https://www.ema.europa.eu/en/human-regulatory-overview/marketing-authorisation/product-information-requirements/how-prepare-review-summary-product-characteristics). Gjennomgått oversikten over SmPC-delene, blant annet 4.1–4.9 og 5.1–5.2. Grunnlag for regulatorisk dekning, ikke en kilde til virkestoffspesifikke svar.
- **S02 — DMP.** [What is FEST?](https://www.dmp.no/en/about-us/distribution-of-data-on-medicinal-products/electronic-prescription-support-system-fest/what-is-fest). Grunnlag for å skille strukturerte norske legemiddeldata fra forskningslitteratur.
- **S03 — DMP.** [Hvordan bruke FEST](https://www.dmp.no/om-oss/distribusjon-av-legemiddeldata/FHIR-tjenesten/fest/hvordan-bruke-fest). Gjennomgått beskrivelse av datagrunnlag og dokumentasjonsinnganger. Ingen integrasjon, tilgangsrett eller feltdekning er testet i dette arbeidet.
- **S04 — Cochrane Handbook.** [Chapter 4: Searching for and selecting studies](https://www.cochrane.org/authors/handbooks-and-manuals/handbook/current/chapter-04). Særlig supplerende søkespor, forsøksregistre, utvalg og studie-/rapportidentitet. Brukt som metodegrunnlag; ikke alle krav til en Cochrane-oversikt påstås oppfylt.
- **S05 — Cochrane Handbook.** [Chapter 14: Completing Summary of findings tables and grading the certainty of the evidence](https://www.cochrane.org/authors/handbooks-and-manuals/handbook/current/chapter-14). Særlig utfall, populasjon, komparator, tidsrom, absolutte/relative effekter og sikkerhet i et samlet evidensgrunnlag.
- **S06 — Rethlefsen et al., 2021.** [PRISMA-S](https://link.springer.com/article/10.1186/s13643-020-01542-z). DOI: `10.1186/s13643-020-01542-z`. Fulltekstside gjennomgått for dokumentasjon av søk. Rapportering er ikke i seg selv dokumentasjon på god søkekvalitet.
- **S07 — Shea et al., 2017.** [AMSTAR 2](https://www.bmj.com/content/358/bmj.j4008). DOI: `10.1136/bmj.j4008`. Fulltekst gjennomgått, særlig kritiske domener og advarselen mot summerte kvalitetspoeng.
- **S08 — NICE, NG222.** [Recommendations: stopping antidepressant medication](https://www.nice.org.uk/guidance/ng222/chapter/recommendations). Relevante deler av 1.4.12–1.4.16 kontrollert via indeksert originalsidetekst; direkte side-/PDF-henting ble avvist. Ingen full gjennomgang av NG222 eller dens evidensvedlegg er påstått. Brukt til standardens spørsmål om individuelt tilpasset seponering, ikke til en doseringsplan.
- **S09 — Bousman et al./CPIC, 2023.** [Guideline for serotonin reuptake inhibitor antidepressants](https://files.cpicpgx.org/data/guideline/publication/serotonin_reuptake_inhibitor_antidepressants/2023/37032427.pdf). DOI: `10.1002/cpt.2903`. Original-PDF lest i relevante deler, og side 52 og 55 kontrollert visuelt. Særlig avgrensningen til anvendelse av genotypefunn. Dette er den undersøkte 2023-versjonen, ikke en attestasjon på at ingen senere oppdatering finnes.
- **S10 — NHS Specialist Pharmacy Service.** [Switching strategies for antidepressants](https://sps.nhs.uk/articles/switching-strategies-for-antidepressants/). Originalside gjennomgått. Grunnlag for å skille byttestrategier og individuell planlegging; britiske preparatmuligheter overføres ikke automatisk til Norge.
- **S11 — FDA.** [Adverse Event Monitoring System](https://www.fda.gov/safety/fda-adverse-event-monitoring-system-aems). Begrensningene ved meldedata kontrollert: rapport er ikke bevist årsak og rapporttall gir ikke insidens.
- **S12 — Royal College of Psychiatrists.** [Stopping antidepressants](https://www.rcpsych.ac.uk/mental-health/treatments-and-wellbeing/stopping-antidepressants). Pasient-/pårørenderettet faglig veiledning, kontrollert i relevante indekserte avsnitt. Brukt som supplerende perspektiv på tolerabilitet og tilpasning, ikke som en empirisk sammenligning av optimale nedtrappingsregimer.
- **S13 — Risk of Bias tools.** [RoB 2](https://www.riskofbias.info/welcome/rob-2-0-tool). Verktøyeierens inngang og versjons-/designvalg kontrollert. Full instrumentanvendelse gjøres først ved vurdering av en konkret studie.
- **S14 — Norsk legemiddelhåndbok.** [Doksepin](https://www.legemiddelhandboka.no/extended/doksepin) og [tranylcypromin](https://www.legemiddelhandboka.no/extended/virkestoff/tranylcypromin). Brukt som norske eksempler på monografistruktur i indeksert originaltekst. Ingen doser, effektpåstander eller toksisitetsgrenser er adoptert fra disse sidene i denne leveransen.
