# Roadmap

Forrige leveranse — **en klinikervennlig arbeidsflate, og teknikken som
Antideps eget ansvar** — er implementert. Den kom foran det som tidligere sto
som neste leveranse etter PR #97, og grunnen står under.

Eieren har besluttet at Antidep ikke skal ta i bruk et betalt modell-API. Det
står fast: ingen OpenAI-nøkkel, ingen Anthropic-nøkkel, ingen annen
leverandørnøkkel er en forutsetning for å kjøre kjeden.

## Den styrende produktregelen

**Alt et menneske gjør i Antideps brukergrensesnitt, skal være umiddelbart
forståelig og faglig eller redaksjonelt relevant for en kliniker. Teknisk
konfigurering, transport, runner- og modelloppsett, feilsøking og vedlikehold
håndteres automatisk eller av tekniske agenter som Claude Code og ChatGPT — og
skyves aldri tilbake på klinikeren.**

Regelen er varig og står i `AGENTS.md`. Den gjelder hver senere leveranse, og en
flate som bryter den, er ikke ferdig uansett hva den ellers gjør.

Dette er grunnen til at leveransen kom først. Flaten `/agentarbeid` ba mennesker
velge leverandør, modell og modellversjon for hvert agentledd, registrere en
«kjører», hente en tilkoblingskode, laste ned en oppgavefil og laste opp et
svar — og den viste rå feilmeldinger fra databasen når noe gikk galt. Ingen av
delene er klinisk eller redaksjonelt arbeid. Å bygge videre på den flaten ville
gjort gjelden større for hver leveranse.

## Flatene nå

- **`/arbeid` — den åpne arbeidsoversikten.** Read-only, uten innlogging, og med
  klinikervennlige beskrivelser på høyt abstraksjonsnivå: planlagt, pågår,
  stoppet, fullført. Hver tilstand har et tegn, en tekst og en farge, og ingen
  av dem uttrykkes med farge alene. Tilstanden kommer fra
  `api.public_work_board()` og dermed fra databasen, så historikken overlever en
  sideoppfriskning og en ny sesjon. Ingen agentrolle, ingen modell, ingen
  kjører, ingen jobbnøkkel, ingen artikkeltittel, ingen uuid og ingen feiltekst
  forlater databasen der.
- **`/fulltekst` — fulltekstinnboksen.** En editor eller admin ser hvilken
  artikkel som mangler, i klartekst, og gjør én ting: velger riktig PDF.
  Antidep binder filen til publikasjonen, kontrollerer at den faktisk *er* den
  artikkelen, prøver lesbarheten med tabellene i behold, kjører det registrerte
  tekstuttrekket, registrerer kildeversjonen og legger neste ledd i køen. Ingen
  uuid, ingen hash, ingen oppskrift og ingen terminalkommando er synlig.
- **`/tekniske-problemer` — driftens side.** Admin-mandat, et merke i
  navigasjonen når noe er uløst, og bare det en ikke-teknisk admin trenger:
  hvilket område, når det oppsto og sist ble sett, og om det fortsatt pågår.
  Den rå diagnosen finnes i `workflow.technical_incidents`, privat, og forlater
  aldri databasen gjennom noe `api`-objekt.

## Det som ikke lenger er en menneskeoppgave i produktet

Valg av KI-tjeneste for et agentledd, registrering av en autonom kjører,
tilkoblingskoder, nedlasting av oppgavefiler og opplasting av agentsvar er ute
av produkt-UI. Handlingene finnes fortsatt — de er de samme `api`-funksjonene —
men de kjøres som et driftssteg:

```sh
npm run ops:agents -- assign-model --role evidence_extraction --provider … --model …
npm run ops:agents -- register-runner --key … --name … --role … --platform-ref … --disclosure …
npm run ops:agents -- pair --key …
npm run ops:agents -- export-task --job … / import-answer --job … --answer …
npm run ops:full-text
```

Sikkerhetsgrensene er uendret. Tildelingen er fortsatt en attestert avgjørelse
tatt *før* oppgaven hentes ut, den inngår fortsatt i oppgavens avtrykk, og et
svar kan fortsatt bekrefte identiteten sin uten å bestemme den
(ANTIDEP_CONSTITUTION.md regel 3). Ingen modell attesterer seg selv, og ingen
kontroll er svekket for å få flaten enklere.

## Den primære arbeidsformen

En planlagt ChatGPT Workspace Agent kobler seg til Antideps private MCP-app,
spør om det finnes arbeid i sitt eget agentledd, tar én oppgave med en leie,
leser den, utfører den og leverer svaret tilbake. Mennesket er ute av
transporten.

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
og det er et **teknisk deploy-/driftssteg** — ikke en redaksjonell beslutning.

## Det plattformen avgjør, og ikke Antidep

Autonomien har én grense Antidep ikke kan flytte: om ChatGPT-workspacet tillater
at appens skrivehandlinger utføres uten en godkjenning per kjøring. Antideps
side er prøvd ende-til-ende i CI, gjennom det ekte protokollendepunktet, mot en
ekte database og uten et menneske i transporten. Om den siste innstillingen er
på plass, avgjøres i ChatGPT og verifiseres med én planlagt kjøring etter
oppsettet. Krever plattformen en engangs menneskelig autorisasjon, håndteres det
der — Antidep bygger ikke et teknisk skjema for å ta imot den.

Det samme gjelder modellseparasjonen. Pinner plattformen modellen bak en
Workspace Agent, registreres den og kan etterprøves der. Gjør den ikke det,
registreres det som `not_exposed`, og Antidep hevder ikke at separasjonen er
bevist av plattformen — den hviler da på den registrerte tildelingen, akkurat som
i den manuelle handoffen.

## Det som fortsatt krever en terminal

- **De uavhengige kontrolleddene.** Ekstraksjonskontrollen og
  kildestøttekontrollen er Antideps egen deterministiske kode, og de kjøres i
  dag av kommandoer med hver sin agentlegitimasjon. Når et agentsvar er
  registrert — av en planlagt kjøring eller av en recovery-import — går kjeden
  derfor ikke videre av seg selv.
- **Tekstuttrekket.** `npm run ops:full-text` kjører den registrerte oppskriften
  der `pdftotext` faktisk finnes. Det er et driftssteg og ikke en
  menneskeoppgave: for den som lastet opp PDF-en, er det usynlig, og oppgaven
  står som «pågår» til den er registrert.

Ingen av delene er noe en kliniker møter.

## Neste leveranse

Neste sammenhengende leveranse er **resten av veien fra registrert fulltekst til
kandidat uten et terminalvindu**. Etter denne leveransen gjenstår tre ting av
den, og de henger sammen:

- at de deterministiske kontrolleddene kjøres automatisk når grunnlaget for dem
  finnes, med sin egen rolle og sin egen identitet som før,
- at det neste semantiske leddet legges i køen av seg selv når kontrollen foran
  er ferdig, slik at den planlagte kjøreren finner arbeidet uten at noen legger
  det inn for hånd, og
- et enkelt, klinikervennlig sted å be om en artikkel Antidep mangler — altså
  `api.request_full_text(...)` med en flate foran, med den redaksjonelle
  avgrensningen som det den er: en faglig avgjørelse om hvilke virkestoff,
  hvilke endepunkt og hvilken populasjon et funn kan gjelde.

Kildeinngangen og selve opplastingen er ute av terminalen allerede. Det som
gjenstår, er automatikken mellom leddene — og den skal bygges under den samme
regelen: klinisk og redaksjonelt arbeid i UI, teknisk arbeid hos systemet og de
tekniske agentene.
