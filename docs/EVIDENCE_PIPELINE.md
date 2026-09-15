# Evidenskjeden

## Ønsket kjede

Klinisk spørsmål → discovery → komplett fulltekst → kildevurdering → ekstraksjon → separat ekstraksjonskontroll → syntese → motprøving → kildestøttekontroll → separat evidensvurdering → redaksjonell formulering → meningskontroll → agentferdig kandidat → menneskelig sluttkontroll → eksplisitt publisering → klinikervisning, med tilbaketrekking og rollback som synlige hendelser.

Abstract og metadata stopper ved discovery. Begrensede representasjoner kan aldri bli EvidenceItem eller indirekte syntesegrunnlag.

## Implementert nå

- Versjonerte kilder, dokumentfingeravtrykk og tillatt PDF-tekstuttrekksoppskrift.
- **Privat fulltekstbibliotek.** Originalfilen blir liggende i databasen, utilgjengelig for enhver klientrolle. Fingeravtrykket beregnes av bytene og gjentas av en regel på raden, så filidentiteten er databasens og aldri en påstand kalleren skriver.
- **Kontrollert publikasjonstilhørighet.** Opplastingen krever at fullteksten bærer kildens egen registrerte identitet — DOI, PMID navngitt som en PMID, eller tittelen — og avviser filen ellers. Et korrekt fingeravtrykk beviser hvilken fil dette er, ikke hvilken artikkel den er.
- **Lesbarhets- og tabellkontroll.** Fullteksten prøves mot krav til mengde tekst, linjer, bokstavandel og antall datarader, og mot at et dokument som erklærer tabeller, faktisk har innhold under dem. En artikkel der tabellene ble droppet som bilder, ser hel ut i brødteksten samtidig som de kliniske tallene mangler; den registreres ikke.
- **Autonom kjører over den samme handoffen.** Det semantiske arbeidet kan nå
  hentes av en planlagt KI-agent framfor av et menneske med en fil. Antidep har
  en privat MCP-app med fem smale operasjoner — se om det finnes arbeid, ta én
  oppgave med en leie, les den, lever ett svar, gi oppgaven fra deg — og
  ingenting annet: ingen SQL, ingen generell databaseadgang, ingen
  service-nøkkel, ingen HTTP-proxy. Kjøreren er en ny transport og ikke en ny
  agentarkitektur: oppgaven bygges av de samme radene, avtrykket regnes av den
  samme funksjonen, og svaret registreres av nøyaktig den samme skriveveien et
  opplastet `svar.json` går gjennom. Det følger av at de deler funksjon
  (`workflow.record_agent_handoff_answer`) at MCP-veien strukturelt ikke kan få
  større faglige skrivefullmakter enn den manuelle. Tilkoblingen er OAuth 2.1
  med PKCE, bundet til nøyaktig ett agentledd, registrert av en redaktør med
  mandat og mulig å trekke tilbake med det samme; hele tokenstilstanden ligger
  hashet i Antideps egen database, og MCP-serveren holder ingen
  databasehemmelighet av egen kraft. Den samme Workspace Agent-en kan ikke kjøre
  to agentledd: én konfigurasjon er én modellruntime, og en kjede der den samme
  agenten både laget innholdet og vurderte det, ville vært egenverifikasjon med
  et ekstra ledd. Pinner plattformen ikke modellen bak agenten, registreres det
  som `not_exposed`, og Antidep hevder ikke at separasjonen er bevist av
  plattformen. Den manuelle nedlast/opplast-veien består som fallback, og de to
  deler kø, leie og jobb — så de kan ikke gjøre det samme arbeidet to ganger.
- **Ekstern agent-handoff som arbeidsform.** Det semantiske arbeidet utføres av KI-agenter eieren allerede har tilgang til, gjennom én felles, versjonert oppgavekontrakt. Antidep bygger oppgaven av rader som allerede finnes og beregner et avtrykk over nøyaktig det som binder svaret — rollen, oppgaven, promptmalen, svarformen, inndataens versjon og de tidligere agentkjøringene rollen hviler på. Den eksterne agenten får én selvforklarende fil med hele materialet, og leverer ett svar. Importen kontrollerer bindingen mot oppgaven slik databasen bygger den *da*, avviser ukjente felter, henter de registrerte verdiene ut av svaret selv, og skriver gjennom nøyaktig de samme interne skriveveiene agentkjørerne bruker. Et eksternt modellsvar har ingen databaselegitimasjon og ingen egen skrivevei. Importen er idempotent på oppgaven: det samme svaret sendt inn igjen svarer med det som allerede ble registrert, og et annet svar på en besvart oppgave avvises — gjentatte forsøk gir aldri doble kliniske artefakter.
- **Sann modellproveniens, også når leverandøren ikke forteller alt.** Kjøringen bærer både registreringsidentiteten — Antideps egen deterministiske kode — og den eksterne KI-agenten som faktisk gjorde arbeidet, som egne kolonner. En tjeneste som ikke eksponerer noen intern build, registreres som «ikke eksponert» med én kanonisk verdi framfor med en oppdiktet versjon: to ukjente versjoner av den samme modellen er dermed den samme identiteten, og separasjonsregelen svekkes ikke av at versjonen mangler.
- **Handoff-jobbene er en egen form.** Om en pipelinejobb utføres av en ekstern KI-agent eller av Antideps egne kjørere, er en egenskap ved raden (`workflow.agent_handoff_jobs`) og ikke noe som utledes av agentrollen. Agentkøen viser bare de eksterne oppgavene som fortsatt venter; `api.claim_pipeline_job` utelater dem, og en jobb med en løpende leie kan ikke overtas av importen.
- **Separasjonen gjelder den eksterne modellen.** Hvilken KI-agent en rolle handler som, tildeles på forhånd av en redaktør med mandat (`api.assign_agent_role_model`) og kan ikke skrives om etterpå — bare avsluttes eller byttes, med hvem og hvorfor. Tildelingen inngår i oppgavens binding og dermed i `request_digest`: svaret bekrefter identiteten sin, men etablerer den ikke, og et svar avgitt under en tidligere tildeling kan ikke importeres etter et bytte. Exclusion-regelen gjør at ingen to roller kan dele modellidentitet, og forbudet mot egenverifikasjon sammenligner nå også de semantiske identitetene: det samme modellsvaret kan ikke både lage innholdet og kontrollere det. Finnes ingen uavhengig modell, stopper kjeden framfor å registrere en kontroll som ikke er uavhengig.
- **Privat representasjon.** Teksten kildeversjonens fingeravtrykk ble beregnet av, ligger lagret ved siden av originalfilen, med RLS default deny, uten grants og uten view. Den forlater databasen bare som en del av en agentoppgave, til en kaller med editor-mandat.
- Opptaksbasert modelladapter og rolleavgrensede agentinnganger for ekstraksjon, kontroll, syntese og evidensvurdering. Opptaket er fortsatt det som gjør hele kjeden kjørbar om igjen uten en eneste modell.
- **Reelt separate modellroller.** Hver rolle har en registrert modellidentitet, ingen to roller kan dele en, og en kjøring må ha nøyaktig den registrerte. I tillegg avvises en kontroll utført av den samme modellidentiteten som produserte det kontrollerte. Tildelingen kan ikke skrives om i ettertid; den kan bare avsluttes, én gang, med hvem og hvorfor — og både registreringen og avslutningen etterlater sin egen auditrad.
- **Varig og idempotent jobbtilstand.** Arbeid som gjenstår, ligger i databasen med idempotensnøkkel, leie og append-only spor. En avbrutt orkestrering kan gjenta listen sin uten å doble noe, en kjører som forsvinner blokkerer ikke køen, og oppbrukte forsøk gir en jobb som blir stående framfor å prøves i det uendelige. Utfallet meldes med uttakets egen leienøkkel og peker på en kjøring som ble åpnet for nettopp det uttaket og selv er avsluttet med et vellykket utfall. En kjører hvis leie er løpt ut, kan derfor ikke skrive over det forsøket som nå arbeider; en jobb kan ikke meldes fullført før arbeidet bak den faktisk er det; kjøringen fra én jobb kan ikke bære en annen; og jobbens utfall er kjøringens eget, kopiert framfor oppgitt.
- **Forseglet kandidat med synlig kildedekning.** Alt en kliniker og en sluttkontrollør skal se, settes sammen deterministisk av rader som allerede finnes, og avtrykket er innholdet. Kildedekningen ligger inne i avtrykket.
- **Kandidatbundet sluttkontroll.** En navngitt fagperson med mandat avgir beslutningen i den samme visningen klinikeren får, og beslutningen kan strukturelt ikke vise til et annet innhold enn det som ble lest. Flaten viser hele det forseglede innholdet — hvert GRADE-domene, hvert av de sju kontrollpunktene og tallene bak funnene — fordi avtrykket dekker alt sammen, og en attestasjon av noe fagpersonen aldri ble vist, ikke er en attestasjon. Er grunnlaget endret siden forseglingen, må kandidaten bygges på nytt.
- **Publisering av nøyaktig det godkjente innholdet.** Publiseringen er en egen, eksplisitt handling etter sluttkontrollen, med et annet mandat. Hendelsen navngir kandidaten, avtrykket og den sluttkontrollen den hviler på, og sammensatte fremmednøkler gjør det strukturelt umulig at en avvist eller omgjort beslutning bærer en publisering. Kandidaten må fortsatt være den gjeldende: er grunnlaget endret siden forseglingen, finnes det ikke noe å publisere før innholdet er bygget og godkjent på nytt. Radlåsene holder hele veien fra gaten til hendelsen — på påstanden, revisjonen, kandidaten og alt innholdet bygges av — så verken en sluttkontroll, en ekstraksjonskontroll, en kildestøttekontroll eller en tilbaketrukket kilde kan commite i vinduet mellom dem.
- **Klinikerflaten viser det publiserte, ikke det interne.** Innholdet er kandidatens egen rad, ordrett — ikke en gjenoppbygging fra dagens tilstand, som ville kunnet vise noe annet enn det som ble godkjent. Avtrykket følger med og kan regnes ut av innholdet selv. Interne kandidater og originaldokumenter er fortsatt private.
- **Synlig tilbaketrekking og rollback.** Begge er nye append-only hendelser. En tilbaketrekking navngir hvilket forseglet innhold som ble tatt ut av visning, og kjører bevisst ingen gate. En rollback peker på en tidligere publisert *versjon* og ikke bare på en revisjon — den samme revisjonen kan ha vært publisert som flere forskjellige innhold — kjører hele gaten på nytt, og krever i tillegg at den versjonen kalleren valgte fortsatt er innholdet der og faktisk har vært vist; ellers ville «tilbake» betydd «til noe annet» eller «til noe nytt». Historikken slettes aldri, og den leses i kjedens egen rekkefølge framfor på klokka.
- Separate proveniens- og kontrollrader, fulltekststrukturvakt og publiseringsgater.
- Lokal pgTAP-, samtidighets- og kjedeprøve, der kjedeprøven går hele veien fra en privat PDF til publisert klinikerinnhold, og deretter prøver tilbaketrekking og rollback.

## Hvem som gjør hva

Antidep eier oppgavekontrakten, integritetskontrollene og lagringen. Eksterne KI-agenter utfører de semantiske oppgavene — ekstraksjonsutkast, synteseutkast og evidensvurdering — og en planlagt ChatGPT Workspace Agent over den private MCP-appen er den primære utføreren. Et vanlig chatvindu med nedlasting og opplasting er fortsatt en eksplisitt støttet utfører, og er fallback når en planlagt kjøring er nede. De uavhengige kontrolleddene er Antideps egen deterministiske kode; en ekstern modell som fikk utføre dem, ville gjort kontrollen til nok en modellvurdering. En teknisk agent kan brukes til orkestrering og utvikling der det passer. Ingen bestemt betalt modell-API er en forutsetning, og ingen modellnøkkel er nødvendig for å kjøre kjeden.

## Mangler

Kildeinngangen fra flaten: en ny fulltekst registreres fortsatt av en kommando, fordi tekstuttrekket må kjøres med den registrerte oppskriften og en nettleser ikke kan kjøre den. Alt som følger etter registreringen, kan betjenes fra flaten — eller av den planlagte kjøreren.

De uavhengige kontrolleddene kjøres fortsatt av kommandoer. Et registrert agentsvar fører derfor ikke kjeden videre av seg selv, uansett om det kom fra en planlagt kjøring eller fra et menneske.

Autonomien har i tillegg én grense som ikke ligger i Antidep: om ChatGPT-workspacet tillater at appens skrivehandlinger utføres uten en godkjenning per kjøring. Antideps side er prøvd ende-til-ende i CI; den siste innstillingen avgjøres i ChatGPT og verifiseres med én planlagt kjøring etter oppsettet (`docs/CHATGPT_WORKSPACE_AGENT.md`).

Et lagringsnavn, en PDF-signatur eller et registrert modellnavn beviser ikke at disse leddene finnes.
