# Roadmap

Forrige leveranse — **revisjonen av en påstand som allerede finnes** — er
implementert. Den lukket det siste bevisste hullet i golden slice: ny evidens om
et virkestoff og et endepunkt som allerede har en påstand, blir nå en synlig,
varig redaksjonell oppgave framfor et stille stopp, og redaktørens avgjørelse
setter resten av kjeden i gang. Den er beskrevet under.

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

## De tre menneskehandlingene

Hele veien fra «Antidep mangler en artikkel» til «en kandidat ligger til
sluttkontroll» har nå **tre** punkter der et menneske gjør noe, og alle tre er
redaksjonelle:

1. **Å be om artikkelen** (`/be-om-artikkel`). En redaktør sier hvilken artikkel
   Antidep bør ha — tittel, forfattere, tidsskrift, år og DOI — og hva et funn
   fra den kan gjelde: hvilke virkestoff, hvilke endepunkt og hvilken
   populasjon. Katalogvalgene er navn, aldri id-er.
2. **Å velge riktig PDF** (`/fulltekst`). En editor eller admin kjenner igjen
   artikkelen og velger filen. Ingenting mer.
3. **Å avgjøre om ny forskning skal inn i en påstand som finnes**
   (`/ny-evidens`). En redaktør ser påstanden slik den står i dag og hva slags
   forskning som er kommet til, og avgjør enten at påstanden skal skrives om med
   det oppdaterte grunnlaget, eller at den nye forskningen ikke endrer den — det
   siste med en begrunnelse. Antidep bygger resten selv.

Og ett punkt til slutt, som skal være et menneskes:

4. **Sluttkontrollen** (`/kandidater`). En navngitt fagperson vurderer det
   ferdige produktet i den samme visningen klinikeren får, og publiseringen er
   en egen, eksplisitt handling etter den.

Alt mellom disse er Antideps eget arbeid.

## Flatene nå

- **`/arbeid` — den åpne arbeidsoversikten.** Read-only, uten innlogging, og med
  klinikervennlige beskrivelser på høyt abstraksjonsnivå: planlagt, pågår,
  stoppet, fullført. Hver tilstand har et tegn, en tekst og en farge, og ingen
  av dem uttrykkes med farge alene. Tilstanden kommer fra
  `api.public_work_board()` og dermed fra databasen, så historikken overlever en
  sideoppfriskning og en ny sesjon. Ingen agentrolle, ingen modell, ingen
  kjører, ingen jobbnøkkel, ingen artikkeltittel, ingen uuid og ingen feiltekst
  forlater databasen der.
- **`/be-om-artikkel` — bestillingen.** En redaktør ber om en artikkel Antidep
  mangler. Skjemaet spør om bibliografien og den faglige avgrensningen, og om
  ingenting annet. Antidep oppretter eller gjenfinner kilden på DOI-en, utleder
  adressen dokumentet hentes fra, og legger behovet i den åpne oversikten som
  «venter på fulltekst».
- **`/fulltekst` — fulltekstinnboksen.** En editor eller admin ser hvilken
  artikkel som mangler, i klartekst, og gjør én ting: velger riktig PDF.
  Antidep binder filen til publikasjonen, kontrollerer at den faktisk *er* den
  artikkelen, prøver lesbarheten med tabellene i behold, kjører det registrerte
  tekstuttrekket, registrerer kildeversjonen og legger neste ledd i køen. Ingen
  uuid, ingen hash, ingen oppskrift og ingen terminalkommando er synlig.
- **`/ny-evidens` — ny forskning på en påstand som finnes.** Krever
  redaktørmandat for fagområdet påstanden hører under. Flaten viser hva
  påstanden sier i dag, hvilket virkestoff og endepunkt den gjelder, om den er
  publisert, hvor sikker evidensen ble vurdert til å være — og hver ny artikkel
  som er kommet til, med bibliografi, studiedesign, populasjon, retning og
  størrelse. Ingen uuid, ingen jobbnøkkel, ingen agentrolle og ingen modell.
  Avgjørelsen er bundet til nøyaktig det evidensgrunnlaget redaktøren tok
  stilling til.
- **`/kandidater` og `/publisert`.** Sluttkontrollen av det ferdige produktet,
  og det Antidep faktisk sier.
- **`/tekniske-problemer` — driftens side.** Admin-mandat, et merke i
  navigasjonen når noe er uløst, og bare det en ikke-teknisk admin trenger:
  hvilket område, når det oppsto og sist ble sett, og om det fortsatt pågår.
  Den rå diagnosen finnes i `workflow.technical_incidents`, privat, og forlater
  aldri databasen gjennom noe `api`-objekt.

## Kjeden går av seg selv

Overgangene mellom leddene er **databasens egne**, ikke en kjøreplans. Hver av
dem er en trigger på den raden som utløser den, i den samme transaksjonen som
skrev raden (migrasjon 012b):

| Det som blir registrert | Det Antidep gjør i det samme kallet |
| --- | --- |
| Fulltekst registrert | Ekstraksjonsoppgaven legges i køen, med avgrensningen bestillingen bar |
| Evidensfunn registrert | Ekstraksjonskontrollen legges i køen |
| Ekstraksjonskontroll bekreftet | Synteseoppgaven legges i køen — eller, når paret alt har en påstand, en redaksjonell revisjonsoppgave åpnes |
| Revisjon besluttet av en redaktør | Synteseoppgaven legges i køen, med hele grunnlaget og med påstanden den gjelder |
| Påstandsrevisjon registrert | Kildestøttekontrollen legges i køen |
| Kildestøttekontroll bekreftet | Evidensvurderingen legges i køen |
| Evidensvurdering registrert | Kandidaten forsegles, og ligger til sluttkontroll |

Ingen poller, ingen cron og ingen orkestrator som kan gå ned mellom to ledd.
Overgangen gjelder like mye for den autonome MCP-kjøreren, for
recovery-importen og for et menneske med mandat — tre veier inn som ellers
måtte huske det samme skrittet hver for seg.

Ingen kontrollport er fjernet eller gjort mildere. Innleggingen kjører den
samme forhåndskontrollen av grunnlaget som før, med de samme funksjonene
skriveveiene leser når svaret kommer tilbake. Kan neste ledd ikke bygges, legges
det ikke i køen — kjeden stopper, og det er hva fail-closed betyr her.

Ingen overgang kan lage to semantisk like oppgaver. `workflow.pipeline_jobs` er
unik på `(agent_role, job_key)`, og for de semantiske leddene spør overgangen i
tillegg om *subjektet* — virkestoffet og temaet, eller påstandsrevisjonen —
allerede har en oppgave i rollen, uansett hvem som la den inn. Det spørsmålet
stilles etter at overgangen har tatt en lås på subjektet, fordi to kontroller som
kommer samtidig, ellers begge kunne svart «nei» og lagt inn hver sin oppgave
under hvert sitt navn. To reelle forbindelser kappes om nettopp det i
`npm run db:test:race`.

Den samme låsen tas av den manuelle innleggingen, slik at en redaktør som
legger inn i samme øyeblikk, ikke kan gjøre overgangens svar foreldet mens det
skrives. Redaktørens rett til å legge inn en annen avgrensning med vilje er
urørt — det er en redaksjonell avgjørelse, ikke et kappløp.

Et ledd som har stoppet, meldes ikke friskt av at noe annet gikk bra.
Opprydningen avgjør hvert av de seks leddene for seg — de fem som legger arbeid
i køen, og det sjette som gjør synlig at ny evidens venter på en redaksjonell
avgjørelse — går gjennom leddet fra sin egen markør slik at en kostnadsgrense
ikke blir til sult for raden bak den, og slukker lampen bare når en hel runde kom
gjennom uten en eneste svikt.

## Det som fortsatt er teknisk drift

To planlagte kjøringer, begge uten noen i transporten:

- **Tekstuttrekket** (`.github/workflows/full-text-extraction.yml`, hvert
  kvarter). Den registrerte oppskriften er `pdftotext` med en låst argumentliste,
  og en nettleser kan ikke kjøre den.
- **De deterministiske kontrollene**
  (`.github/workflows/deterministic-controls.yml`, hvert kvarter). Kontrollene
  er flere tusen linjer deterministisk TypeScript, og en SQL-kopi av dem ville
  vært en andre implementasjon av den ene tingen som skal være uomtvistelig.
  Kjøringen tar uttak fra køen med hvert kontrolledds egen legitimasjon og
  registrerer resultatet gjennom de samme skriveveiene som før.

Begge finnes også som kommandoer for feilsøking — `npm run ops:full-text` og
`npm run ops:controls` — men ingen trenger å starte dem. Får kontrollen ikke
kjørt, står arbeidet i kø; det blir aldri borte, og det blir aldri en
menneskeoppgave.

`npm run ops:agents` dekker modelltildeling, kjøreroppsett og manuell handoff
som recovery. Ingen av kommandoene finnes i produkt-UI.

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

## Grensen automatikken ikke går over

Kjeden synteserer fortsatt ikke om igjen en påstand som allerede finnes for det
samme temaet og virkestoffet. Kommer det et nytt evidensfunn på et par som alt
har en påstand, blir funnet kontrollert og står klart — men *hva* påstanden skal
si i lys av det, er en redaksjonell avgjørelse og ikke en transport.

Det som er nytt, er at grensen ikke lenger er et stille stopp.
`workflow.claim_revision_reviews` gjør tilstanden eksplisitt og varig: én rad per
påstand, uansett hvor mange nye funn som kommer, med et append-only spor over når
Antidep la merke til den, hvor mye den har vokst, og hva som ble besluttet på
hvilket grunnlag. Raden står i den åpne arbeidsoversikten som planlagt arbeid —
aldri som en teknisk feil — og redaktøren avgjør den på `/ny-evidens`.

Avgjørelsen er bundet til nøyaktig det evidensgrunnlaget redaktøren leste. Er
grunnlaget blitt et annet mens siden sto åpen, avvises den, og flaten ber om
fersk tilstand (ANTIDEP_CONSTITUTION.md regel 5). Besluttes revisjon, bygger
Antidep den samme `claim_synthesis`-oppgaven kjeden selv ville lagt inn, med hele
det gjeldende brukbare grunnlaget og med påstanden revisjonen skal gjelde; derfra
går kildestøttekontroll, evidensvurdering og kandidatbygging som før. Historiske
revisjoner, kandidater og publiseringer står uendret.

«Den nye forskningen endrer ikke påstanden» er den andre avgjørelsen, og den er
en faglig konklusjon med en begrunnelse — ikke en utsettelse. Kommer det senere
enda mer ny forskning, åpner oppgaven seg igjen av seg selv. En synteseoppgave
som stopper teknisk, gjør den derimot ikke: det er et teknisk problem og stoppet
arbeid, og aldri en ny menneskeoppgave.

## Neste leveranse

Golden slice er nå hel: fra «Antidep mangler en artikkel» til publisert
klinikerinnhold finnes det ingen ledd som stopper uten at noen ser det, og de
tre menneskehandlingene foran sluttkontrollen er alle redaksjonelle flater.

Neste leveranse er derfor et nytt produktområde og ikke en lukking av et hull.
Den er ikke valgt ennå.
