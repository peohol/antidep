# Roadmap

Forrige leveranse — **en autonom kjører over den eksterne agent-handoffen** — er
implementert.

Eieren har besluttet at Antidep ikke skal ta i bruk et betalt modell-API. Det
står fast: ingen OpenAI-nøkkel, ingen Anthropic-nøkkel, ingen annen
leverandørnøkkel er en forutsetning for å kjøre kjeden. Det som er endret, er
hvem som frakter arbeidet.

## Den primære arbeidsformen

En planlagt ChatGPT Workspace Agent kobler seg til Antideps private MCP-app,
spør om det finnes arbeid i sitt eget agentledd, tar én oppgave med en leie,
leser den, utfører den og leverer svaret tilbake. Mennesket er ute av
transporten; det som er igjen for et menneske, er avgjørelsene: hvilken
KI-tjeneste et ledd utføres av, hvilken kjører som er registrert, og
sluttkontrollen av det ferdige produktet.

Kjøreren er en ny transport og ikke en ny agentarkitektur. Oppgaven bygges av de
samme radene, avtrykket regnes av den samme funksjonen, og svaret registreres av
nøyaktig den samme skriveveien et opplastet `svar.json` går gjennom. Det følger
av at de deler funksjon: MCP-veien kan strukturelt ikke få større faglige
skrivefullmakter enn den manuelle.

Tilkoblingen er OAuth 2.1 med PKCE, og hele tilstanden ligger hashet i Antideps
egen database. MCP-serveren holder ingen databasehemmelighet av egen kraft: den
videresender tokenet kalleren la ved, og databasen avgjør hva det får gjøre. En
tilkobling er bundet til nøyaktig ett agentledd, og den samme Workspace Agent-en
kan ikke kjøre to ledd — én konfigurasjon er én modellruntime, og en kjede der
den samme agenten både laget innholdet og vurderte det, ville vært
egenverifikasjon med et ekstra ledd.

Engangsoppsettet står i [Antidep som privat app i ChatGPT Business](CHATGPT_WORKSPACE_AGENT.md),
sammen med den ferdige agentinstruksen.

## Den manuelle filtransporten er fallback

Nedlast/opplast-veien på `/agentarbeid` består uendret. Den er fallback når en
planlagt kjøring er nede, den er nyttig ved feilsøking, og den er veien inn for
en KI-tjeneste som ikke har en autonom integrasjon. De to veiene deler kø, leie
og jobb, og kan derfor ikke gjøre dobbeltarbeid: en oppgave en planlagt kjøring
holder, er allerede blokkert for flaten, og flaten sier da at arbeidet gjøres
automatisk akkurat nå framfor at noe er i veien.

## Det plattformen avgjør, og ikke Antidep

Autonomien har én grense Antidep ikke kan flytte: om ChatGPT-workspacet tillater
at appens skrivehandlinger utføres uten en godkjenning per kjøring. Antideps
side er prøvd ende-til-ende i CI, gjennom det ekte protokollendepunktet, mot en
ekte database og uten et menneske i transporten. Om den siste innstillingen er
på plass, avgjøres i ChatGPT og verifiseres med én planlagt kjøring etter
oppsettet. Blir svaret nei, gjør den manuelle veien det samme arbeidet.

Det samme gjelder modellseparasjonen. Pinner plattformen modellen bak en
Workspace Agent, registreres den og kan etterprøves der. Gjør den ikke det,
registreres det som `not_exposed`, og Antidep hevder ikke at separasjonen er
bevist av plattformen — den hviler da på redaktørens egen tildeling, akkurat som
i den manuelle handoffen.

## Det som fortsatt krever en terminal

- **Kildeinngangen.** Fullteksten registreres av `npm run editor:assignment -- --pdf …`,
  fordi tekstuttrekket må gjøres med den registrerte oppskriften — `pdftotext`
  med en låst argumentliste og Antideps leserekkefølge — og en nettleser kan
  ikke kjøre den. Kommandoen legger agentoppgaven i køen med det samme, så
  selve agentarbeidet er flatens; men den som bare har en PDF, kommer ikke i
  gang alene.
- **De uavhengige kontrolleddene.** Ekstraksjonskontrollen og
  kildestøttekontrollen er Antideps egen deterministiske kode, og de kjøres i
  dag av kommandoer med hver sin agentlegitimasjon. Når et agentsvar er
  registrert — av en planlagt kjøring eller av et menneske — går kjeden derfor
  ikke videre av seg selv. Flaten sier nettopp det framfor å love noe annet.

## Neste leveranse

Neste sammenhengende leveranse er **hele kjeden fra PDF til kandidat uten et
terminalvindu**. Den må løse fem ting samlet:

- en kontrollert vei for å laste opp en PDF og registrere en kilde fra flaten,
  med den samme publikasjonsbindingen og den samme lesbarhetskontrollen som i
  dag,
- et versjonert tekstuttrekk som faktisk kjøres med den registrerte oppskriften,
  uten å innføre en ny ekstern tjeneste og uten en modellnøkkel,
- et enkelt sted å gjøre den redaksjonelle avgrensningen — hvilke virkestoff,
  hvilke endepunkt, hvilken populasjon et funn kan gjelde — som i dag er flagg
  på en kommandolinje,
- at de deterministiske kontrolleddene kjøres automatisk når grunnlaget for dem
  finnes, med sin egen rolle og sin egen identitet som før, og
- at det neste semantiske leddet legges i køen av seg selv når kontrollen foran
  er ferdig, slik at den planlagte kjøreren finner arbeidet uten at noen legger
  det inn for hånd.

Først da går hele veien fra en artikkel til publisert klinikerinnhold uten et
terminalvindu. Rekkefølgen er ikke tilfeldig: den eksterne plattformgrensen
skulle bevises i faktisk bruk før resten av kjeden bygges rundt den.
