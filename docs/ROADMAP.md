# Roadmap

Forrige leveranse — **ekstern agent-handoff som førstegangs støttet arbeidsform** — er implementert.

Eieren har besluttet at Antidep ikke skal ta i bruk et betalt modell-API. Det semantiske agentarbeidet gjøres av KI-tjenester eieren allerede har tilgang til — i praksis et vanlig chatvindu — og handoffen er derfor ikke en nødløsning i påvente av noe annet. Den er produktet.

Antidep eier oppgavekontrakten, integritetskontrollene og lagringen. Oppgaven bygges av databasen av rader som allerede finnes, med et avtrykk over nøyaktig det som binder svaret: rollen, oppgaven, promptmalen, svarformen, inndataens versjon og de tidligere agentkjøringene rollen hviler på. Den eksterne agenten får én selvforklarende fil og leverer én `svar.json`. Importen kontrollerer bindingen, henter verdiene ut av svaret selv, og skriver gjennom nøyaktig de samme interne skriveveiene agentkjørerne bruker. Modellidentiteten registreres på hver kjøring, og to agentledd kan strukturelt ikke dele modell: den modellen som laget innholdet, kan ikke også vurdere det.

Hele veien betjenes fra Antidep-flaten. Den som skal gjøre agentarbeidet, ser hva som venter, laster ned oppgaven, gir den til KI-tjenesten og laster opp svaret — uten å åpne repoet, redigere JSON, håndtere oppdragsfiler, kjøre terminalkommandoer, kjenne database-ID-er eller konfigurere en modell-API.

## Det som fortsatt krever en terminal

Agentarbeidet kan gjøres fra flaten. To ting rundt det kan ikke ennå, og de er begge ærlige mangler framfor noe som «kommer av seg selv»:

- **Kildeinngangen.** Fullteksten registreres av `npm run editor:assignment -- --pdf …`, fordi tekstuttrekket må gjøres med den registrerte oppskriften — `pdftotext` med en låst argumentliste og Antideps leserekkefølge — og en nettleser kan ikke kjøre den. Kommandoen legger riktignok agentoppgaven i køen med det samme, så selve agentarbeidet er flatens; men den som bare har en PDF, kommer ikke i gang alene.
- **De uavhengige kontrolleddene.** Ekstraksjonskontrollen og kildestøttekontrollen er Antideps egen deterministiske kode, og de kjøres i dag av kommandoer med hver sin agentlegitimasjon. Når et agentsvar er importert, går kjeden derfor ikke videre av seg selv. Flaten sier nettopp det framfor å love noe annet.

## Neste leveranse

Neste sammenhengende leveranse er **resten av kjeden fra flaten**: å komme fra en PDF til en kandidat uten et terminalvindu, uten å slippe et eneste krav underveis.

Den må løse fire ting samlet:

- en kontrollert vei for å laste opp en PDF og registrere en kilde fra flaten, med den samme publikasjonsbindingen og den samme lesbarhetskontrollen som i dag,
- et sted tekstuttrekket faktisk kjøres med den registrerte oppskriften, uten å innføre en ny ekstern tjeneste og uten en modellnøkkel,
- et enkelt sted å gjøre den redaksjonelle avgrensningen — hvilke virkestoff, hvilke endepunkt, hvilken populasjon et funn kan gjelde — som i dag er flagg på en kommandolinje, og
- en vei for at de deterministiske kontrolleddene kjøres når grunnlaget for dem finnes, med sin egen rolle og sin egen identitet som før, slik at et importert agentsvar faktisk fører kjeden videre.

Først da går hele veien fra en artikkel til publisert klinikerinnhold uten et terminalvindu.
