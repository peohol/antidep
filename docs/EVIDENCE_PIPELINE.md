# Evidenskjeden

## Ønsket kjede

Klinisk spørsmål → discovery → komplett fulltekst → kildevurdering → ekstraksjon → separat ekstraksjonskontroll → syntese → motprøving → kildestøttekontroll → separat evidensvurdering → redaksjonell formulering → meningskontroll → agentferdig kandidat → menneskelig sluttkontroll → eksplisitt publisering.

Abstract og metadata stopper ved discovery. Begrensede representasjoner kan aldri bli EvidenceItem eller indirekte syntesegrunnlag.

## Implementert nå

- Versjonerte kilder, dokumentfingeravtrykk og tillatt PDF-tekstuttrekksoppskrift.
- **Privat fulltekstbibliotek.** Originalfilen blir liggende i databasen, utilgjengelig for enhver klientrolle. Fingeravtrykket beregnes av bytene og gjentas av en regel på raden, så filidentiteten er databasens og aldri en påstand kalleren skriver.
- **Kontrollert publikasjonstilhørighet.** Opplastingen krever at fullteksten bærer kildens egen registrerte identitet — DOI, PMID navngitt som en PMID, eller tittelen — og avviser filen ellers. Et korrekt fingeravtrykk beviser hvilken fil dette er, ikke hvilken artikkel den er.
- **Lesbarhets- og tabellkontroll.** Fullteksten prøves mot krav til mengde tekst, linjer, bokstavandel og antall datarader, og mot at et dokument som erklærer tabeller, faktisk har innhold under dem. En artikkel der tabellene ble droppet som bilder, ser hel ut i brødteksten samtidig som de kliniske tallene mangler; den registreres ikke.
- Opptaksbasert modelladapter og rolleavgrensede agentinnganger for ekstraksjon, kontroll, syntese og evidensvurdering.
- **Reelt separate modellroller.** Hver rolle har en registrert modellidentitet, ingen to roller kan dele en, og en kjøring må ha nøyaktig den registrerte. I tillegg avvises en kontroll utført av den samme modellidentiteten som produserte det kontrollerte. Tildelingen kan ikke skrives om i ettertid; den kan bare avsluttes, én gang, med hvem og hvorfor — og både registreringen og avslutningen etterlater sin egen auditrad.
- **Varig og idempotent jobbtilstand.** Arbeid som gjenstår, ligger i databasen med idempotensnøkkel, leie og append-only spor. En avbrutt orkestrering kan gjenta listen sin uten å doble noe, en kjører som forsvinner blokkerer ikke køen, og oppbrukte forsøk gir en jobb som blir stående framfor å prøves i det uendelige. Utfallet meldes med uttakets egen leienøkkel og peker på en kjøring som ble åpnet for nettopp det uttaket og selv er avsluttet med et vellykket utfall. En kjører hvis leie er løpt ut, kan derfor ikke skrive over det forsøket som nå arbeider; en jobb kan ikke meldes fullført før arbeidet bak den faktisk er det; og kjøringen fra én jobb kan ikke bære en annen.
- **Forseglet kandidat med synlig kildedekning.** Alt en kliniker og en sluttkontrollør skal se, settes sammen deterministisk av rader som allerede finnes, og avtrykket er innholdet. Kildedekningen ligger inne i avtrykket.
- **Kandidatbundet sluttkontroll.** En navngitt fagperson med mandat avgir beslutningen i den samme visningen klinikeren får, og beslutningen kan strukturelt ikke vise til et annet innhold enn det som ble lest. Flaten viser hele det forseglede innholdet — hvert GRADE-domene, hvert av de sju kontrollpunktene og tallene bak funnene — fordi avtrykket dekker alt sammen, og en attestasjon av noe fagpersonen aldri ble vist, ikke er en attestasjon. Er grunnlaget endret siden forseglingen, må kandidaten bygges på nytt.
- Separate proveniens- og kontrollrader, fulltekststrukturvakt og publiseringsgater.
- Lokal pgTAP-, samtidighets- og kjedeprøve, der kjedeprøven går hele veien fra en privat PDF til en registrert sluttkontroll.

## Mangler

Publiseringen er fortsatt stengt: `api.publish_claim_revision` er ikke kjørbar for klientrollene, og en sluttkontroll publiserer ingenting. Live semantisk runtime mangler også — utkastleddene kjøres av et opptak, ikke av en leverandørmodell.

Et lagringsnavn, en PDF-signatur eller et registrert modellnavn beviser ikke at disse leddene finnes.
