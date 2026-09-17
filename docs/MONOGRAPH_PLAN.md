# Plan for legemiddelmonografier og autonom kildeoppdagelse

Status: **planlagt, ikke påbegynt**.

Dette dokumentet beskriver den avtalte retningen for neste større innholdsleveranse i Antidep. Det skal bevare produktmålet før mer kode bygges. Faglig arbeid med monografistandard og kildepolitikk skal **ikke starte før repo-eier uttrykkelig gir signal**.

## 1. Utgangspunktet

Antidep skal være en gratis, skalerbar nettapp for norske klinikere om antidepressiver. Appen skal gi rask, kildebelagt informasjon om hvert virkestoff, gjøre sammenligning mulig, gi konkret hjelp til nedtrapping og bytte og på sikt kunne tilby systematisk beslutningsstøtte.

Innholdet skal i stor grad produseres og kvalitetssikres av KI-agenter. Kliniske fagpersoner skal kunne inspisere, korrigere, overstyre og supplere innholdet, men de skal ikke være nødt til å drive litteratursøk eller foreslå artikler én for én for at en monografi skal kunne bygges.

## 2. Gapet i dagens system

Antidep har nå en sterk kjede for å behandle en kilde som allerede er valgt:

klinisk avgrensning → fulltekst → ekstraksjon → kontroll → syntese → kildestøttekontroll → evidensvurdering → kandidat → menneskelig sluttkontroll → eksplisitt publisering.

Det som mangler, ligger foran denne kjeden:

- Antidep har ingen formell definisjon av hva en komplett legemiddelmonografi skal inneholde.
- Systemet vet derfor ikke hvilke kliniske spørsmål som må besvares for et gitt virkestoff.
- Dagens kildeinngang forutsetter i stor grad at et menneske allerede vet hvilken artikkel som bør brukes og hva den kan brukes til.
- Det finnes ikke et autonomt discovery-ledd som selv finner og prioriterer kilder ut fra et definert kunnskapsbehov.

Målet er å flytte normalinngangen fra «her er en artikkel» til «bygg monografi for dette virkestoffet».

## 3. Målbildet

En kliniker eller redaktør skal i prinsippet kunne bestille:

> Bygg monografi for sertralin.

Antidep skal deretter selv:

1. bruke en versjonert monografistandard til å opprette alle relevante kunnskapsbehov;
2. avgjøre hvilke spørsmål som er obligatoriske og hvilke som bare gjelder når de er relevante;
3. søke etter egnede kilder for hvert spørsmål;
4. prioritere kilder etter en eksplisitt kildepolitikk som avhenger av spørsmålstype;
5. identifisere hvilke kilder som fortjener fulltekst og videre behandling;
6. føre de valgte kildene inn i den eksisterende evidenskjeden;
7. bygge strukturerte, kildebelagte påstander med eksplisitt usikkerhet;
8. sette disse sammen til en komplett monografi;
9. vise hvilke deler som er ferdige, utilstrekkelig belagt, ikke relevante eller fortsatt mangler arbeid;
10. la mennesker inspisere, supplere, korrigere eller overstyre uten at dette er nødvendig for normal fremdrift.

## 4. Viktig arkitekturprinsipp

En monografi skal **ikke** være ett stort fritekstdokument lagret som sannheten om et virkestoff.

Den skal være en visning over mange strukturerte kunnskapsobjekter og påstander, for eksempel:

- sertralin + halveringstid
- sertralin + seksuell dysfunksjon
- sertralin + effekt + alvorlig depressiv lidelse + akuttbehandling
- sertralin + graviditet
- sertralin + CYP2D6-hemming
- sertralin + seponeringsrisiko

Hvert slikt objekt skal kunne ha eget evidensgrunnlag, usikkerhet, revisjonshistorikk og proveniens. Dette gjør samme kunnskapsgrunnlag gjenbrukbart i monografier, sammenligninger, bytteregler, nedtrappingsstøtte og senere beslutningsstøtte.

## 5. Monografien må definere spørsmål, ikke svar

Monografistandarden skal si hva Antidep alltid eller betinget skal undersøke, ikke på forhånd hva svaret skal være.

Eksempel:

- riktig: «undersøk seksuelle bivirkninger»
- feil: «sertralin gir mye seksuell dysfunksjon»

Et gyldig utfall for et kunnskapsbehov skal kunne være:

- kildebelagt svar;
- utilstrekkelig eller motstridende evidens;
- ikke relevant for dette virkestoffet;
- fortsatt manglende kildegrunnlag.

Et tomt felt skal aldri være tvetydig mellom «ikke undersøkt» og «ingen kunnskap finnes».

## 6. Foreløpig innholdsomfang for en monografi

Den endelige standarden skal utarbeides faglig senere, men minst disse områdene skal vurderes:

- kortoversikt og klasse;
- virkningsmekanisme;
- norske preparater, formuleringer og styrker;
- godkjente indikasjoner og annen relevant bruk;
- effekt per indikasjon og behandlingsfase;
- dosering, titrering og administrasjon;
- vanlige og klinisk viktige bivirkninger;
- klinisk bivirkningsprofil, blant annet seksualfunksjon, vekt, søvn/sedasjon, aktivering/angst og gastrointestinale effekter når relevant;
- alvorlige risikoer, kontraindikasjoner og forholdsregler;
- farmakokinetiske og farmakodynamiske interaksjoner;
- graviditet og amming;
- eldre, barn/unge, nyresvikt, leversvikt og andre relevante pasientgrupper;
- farmakodynamikk og farmakokinetikk;
- farmakogenetikk og TDM når klinisk relevant;
- seponeringsrisiko og seponeringssymptomer;
- praktisk nedtrapping med norske preparater og styrker;
- overgang til og fra andre antidepressiver;
- overdosering og toksisitet når relevant;
- eksplisitt usikkerhet, motstridende funn og kunnskapshull.

Denne listen er **ikke** Monograph Standard v1. Den er bare startpunktet for det senere faglige arbeidet.

## 7. Bytte og nedtrapping skal ikke presses inn som vanlig monografitekst

Bytte er en relasjon mellom minst to virkestoffer. Regler for bytte bør derfor modelleres som egne strukturerte relasjoner mellom fra- og til-legemiddel, og bare vises fra monografien når relevant.

Nedtrapping bør også struktureres slik at kunnskap om farmakokinetikk, formuleringer og tilgjengelige norske styrker senere kan brukes til praktiske, beregnede forslag. Viktig informasjon skal ikke gjemmes i fritekstavsnitt dersom den kan representeres eksplisitt.

## 8. Kildepolitikken skal være spørsmålsspesifikk

Discovery-agenten skal ikke bare få beskjed om å «finne gode kilder». Antidep skal ha en eksplisitt, versjonert kildepolitikk som angir foretrukket kildehierarki for ulike kunnskapsbehov.

Eksempler som skal vurderes i det senere faglige arbeidet:

- norske regulatoriske fakta: norske myndighetskilder/preparatomtale;
- komparativ effekt: systematiske oversikter/metaanalyser og relevante primærstudier;
- sjeldne eller langsiktige bivirkninger: store observasjonsstudier og farmakovigilansdata når egnet;
- farmakokinetikk: regulatoriske kilder supplert med egnede PK-studier;
- farmakogenetikk: relevante faglige retningslinjer når de finnes;
- nedtrapping/bytte: retningslinjer, farmakologi og annen best tilgjengelig evidens, med tydelig markering når kunnskapsgrunnlaget er svakere.

Kildepolitikken må også definere når søket kan anses som tilstrekkelig, når eldre kilder bør erstattes, og hvordan motstridende kilder håndteres.

## 9. Discovery skal være en egen agentfunksjon

Det skal bygges et eksplisitt discovery-ledd før dagens kildebehandling.

Discovery skal minst kunne:

- motta ett eller flere strukturerte kunnskapsbehov;
- formulere egnede søk;
- finne kandidatkilder;
- identifisere kildetype og relevans;
- prioritere kilder etter kildepolitikken;
- begrunne hvorfor en kilde bør eller ikke bør tas videre;
- oppdage mulig duplisering eller nyere/bedre erstatningskilder;
- foreslå fulltekstinnhenting for de kildene som faktisk trengs;
- etterlate et etterprøvbart spor over hva som ble søkt og valgt bort.

Discovery-resultater er forslag, ikke kliniske sannheter. Kliniske påstander oppstår først gjennom den kontrollerte evidenskjeden.

## 10. Monografidekning må være målbar

For hvert obligatorisk eller betinget kunnskapsbehov må Antidep kunne vise en eksplisitt status.

En monografi kan først regnes som faglig komplett når hvert påkrevd behov har ett av følgende utfall:

1. kildebelagt og kontrollert svar;
2. eksplisitt utilstrekkelig/motstridende evidens;
3. dokumentert ikke relevant;
4. fortsatt åpent arbeid, som betyr at monografien ikke er komplett.

Dette skal gjøre fremdrift målbar og hindre at et glemt område ser ut som et kunnskapshull.

## 11. Progressiv fordypning beholdes

Klinikerflaten skal fortsatt prioritere lite tekst og rask oversikt.

Monografien skal kunne rendres med flere nivåer:

1. kort klinisk konklusjon og sikkerhet;
2. praktisk forklaring og viktige forbehold;
3. studier, motstridende funn og evidensgrunnlag;
4. kildeutdrag/proveniens og kontrollhistorikk for den som vil inspisere.

Detaljrikdommen i kunnskapsmodellen skal ikke tvinge klinikeren til å lese et teknisk dossier.

## 12. Menneskelig kontroll

Mennesker skal alltid kunne:

- legge til en oversett kilde;
- forkaste en kilde;
- korrigere eller overstyre en påstand;
- redigere innhold gjennom admin-/redaktørflate;
- inspisere kildegrunnlag og begrunnelse.

Normalarbeidsflyten skal likevel ikke kreve at et menneske foreslår artikler én for én eller forteller agentene hvilke fakta de bør lete etter.

Dagens krav om navngitt faglig sluttkontroll før publisering beholdes inntil det eventuelt tas en separat, eksplisitt produktbeslutning om noe annet. Autonom discovery og obligatorisk menneskelig publiseringskontroll er to uavhengige spørsmål.

## 13. Planlagt leveranserekkefølge

### Fase A — Monograph Standard v1

Faglig arbeid, utføres først etter eksplisitt signal fra repo-eier.

Leveransen skal definere:

- hvert standardisert kunnskapsbehov;
- obligatorisk vs. betinget innhold;
- forventet datatype/struktur;
- akseptable fraværs-/usikkerhetstilstander;
- hvilke behov som kan gjenbrukes direkte i sammenligningsvisning;
- hvilke behov som er relasjonelle og derfor skal ligge utenfor selve monografien.

### Fase B — Source Policy v1

Faglig arbeid, utføres først etter eksplisitt signal fra repo-eier.

Leveransen skal definere:

- foretrukket kildetype per kunnskapsbehov;
- minimumskrav til kvalitet og aktualitet;
- regler for regulatoriske kilder, systematiske oversikter, primærstudier, observasjonsdata og retningslinjer;
- hvordan motstridende kilder håndteres;
- når discovery kan stoppe;
- når Antidep skal konkludere med utilstrekkelig evidens fremfor å lete videre.

### Fase C — Implementer monografikontrakten og discovery

Én størst praktisk sammenhengende teknisk leveranse, normalt utført av Claude Code etter at fase A og B er ferdige.

Målet er å:

- gjøre monografistandarden versjonert og maskinlesbar;
- kunne opprette en «monografi som skal bygges» for ett virkestoff;
- generere alle kunnskapsbehov automatisk;
- spore status/dekning for hvert behov;
- innføre discovery-agent og etterprøvbar discovery-proveniens;
- knytte valgte kilder inn i eksisterende fulltekst- og evidenskjede;
- bevare menneskelig mulighet til å legge til/forkaste/overstyre;
- vise fremdrift uten tekniske detaljer i klinikerflaten.

### Fase D — Golden monograph: sertralin

Valider hele systemet end-to-end på ett reelt virkestoff.

Starttilstanden skal i prinsippet være én bestilling:

> Bygg monografi for sertralin.

Testen skal vise hvor langt Antidep kommer autonomt og avdekke hull i monografistandard, kildepolitikk, discovery, fullteksttilgang, evidensmodell og klinikerpresentasjon.

Sertralin brukes som valideringsobjekt, ikke som spesialtilfelle. Løsningen må være generell før den regnes som ferdig.

### Fase E — Skaler og bygg sammenligning

Når golden monograph fungerer:

- bygg monografier for øvrige antidepressiver;
- bruk de strukturerte kunnskapsobjektene direkte i sammenligningsvisningen;
- bygg videre støtte for nedtrapping, bytte og senere beslutningsstøtte på de samme dataene.

## 14. Definisjon av vellykket retning

Planen har lykkes når Antideps normale arbeidsform ikke lenger er:

> En kliniker finner en artikkel, legger den inn og forteller hva den kan brukes til.

men:

> Antidep får ansvar for et virkestoff, vet hvilke spørsmål som må besvares, finner og prioriterer kilder selv, fører dem gjennom en etterprøvbar evidenskjede og bygger en strukturert monografi som et menneske kan inspisere og overstyre.

Klinikeren skal være faglig kontrollør og mulig redaktør — ikke litteratursøkets manuelle orkestrator.

## 15. Neste handling

**Stopp her.**

Neste arbeid er fase A og B — `Monograph Standard v1` og `Source Policy v1` — men dette arbeidet skal ikke startes før repo-eier uttrykkelig gir signal.
