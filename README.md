# Antidep

Antidep utvikles som et agentstyrt, etterprøvbart kunnskapssystem om antidepressiver. Forskningsbaserte kliniske funn krever kontrollert fulltekst. En navngitt fagperson skal vurdere det ferdige klinikerproduktet før eksplisitt publisering.

## Status

Repoet inneholder Supabase-skjemaet, en testbar agentmotor og klinikerflaten. Kjeden går nå hele veien fra en privat PDF til publisert klinikerinnhold, og den går av seg selv mellom leddene: originalfilen lagres varig og privat med serverberegnet filidentitet, publikasjonstilhørigheten og lesbarheten — tabellene inkludert — kontrolleres før fullteksten registreres, agentarbeidet har varig og idempotent jobbtilstand, hvert agentledd kjører som sin egen registrerte modellidentitet, og kandidatinnholdet forsegles med kildedekningen synlig.

Fra «Antidep mangler en artikkel» til «en kandidat ligger til sluttkontroll» er det to punkter der et menneske gjør noe — å be om artikkelen, og å velge riktig PDF — og ett til slutt: en navngitt fagperson som vurderer det ferdige produktet. Alt imellom er Antideps eget arbeid.

Alt et menneske gjør i brukergrensesnittet, er klinisk eller redaksjonelt arbeid. Teknisk konfigurering, transport, runner- og modelloppsett, feilsøking og vedlikehold er Antideps eget ansvar, eller de tekniske agentenes — aldri klinikerens.

Sluttkontrollen er bundet til nøyaktig den kandidaten som ble lest, og publiserer ingenting. Publiseringen er en egen handling med et annet mandat: et menneske med publisher-rolle tar i bruk nøyaktig det godkjente avtrykket, klinikerflaten viser den forseglede raden ordrett, og tilbaketrekking og rollback er nye, synlige hendelser som aldri sletter historikk.

Det semantiske agentarbeidet gjøres av KI-tjenester eieren allerede har tilgang til. Antidep bygger oppgaven, binder svaret til nøyaktig det grunnlaget oppgaven ble laget av, og registrerer resultatet gjennom de samme kontrollerte skriveveiene som før. En planlagt ChatGPT Workspace Agent henter arbeidet selv gjennom Antideps private MCP-app, utfører det og leverer svaret tilbake uten et menneske i transporten; nedlast/opplast-veien består som teknisk recovery-mekanisme utenfor produkt-UI. Ingen modellnøkkel og ingen betalt modell-API er nødvendig.

Denne kodeleveransen har ikke i seg selv endret noen hosted database.

## Utvikling

Krever Node-versjonen i `.nvmrc`. Databasetestene krever Docker; dokumenttestene krever Poppler.

```sh
npm ci
npm run lint
npm run format:check
npm run typecheck
npm run test
npm run build
npm run verify:repo
```

Lokal database: `npm run db:start`, `npm run db:test:upgrade`, `npm run db:reset`, `npm run db:test`, `npm run db:test:lock`, `npm run db:test:chain`, `npm run db:test:mcp`, `npm run db:test:intake`, `npm run db:stop`.

`npm run db:test` dekker de automatiske kjedeovergangene i `supabase/tests/810_chain_transitions_test.sql` — normalflyt, gjentakelse, kappløp, opprydning etter en teknisk svikt, og at en svikt i en overgang aldri ruller tilbake det kliniske arbeidet — og bestillingsflaten i `820_full_text_request_test.sql`.

`npm run db:test:intake` går hele veien fra «venter på fulltekst» til kølagt arbeid, med en ekte PDF og det ekte `pdftotext`, gjennom de ekte api-funksjonene.

`npm run db:test:mcp` går hele veien gjennom den private MCP-appen — tilkobling, uttak, oppgave, svar og registrering — mot den lokale databasen. Ingen modell kalles, og ingen nøkkel finnes: «agenten» er prøven selv.

## Flatene

- **`/arbeid` — arbeidsoversikten.** Åpen for alle, read-only, og på klinikerens språk: hva Antidep arbeider med nå, hva som er planlagt, hva som har stoppet, og hva som er gjort ferdig. Hver tilstand har et tegn, en tekst og en farge, og ingen av dem uttrykkes med farge alene. Mangler Antidep en artikkel, står det som planlagt arbeid med «Venter på fulltekst».
- **`/be-om-artikkel` — bestillingen.** Krever redaktørmandat. En redaktør sier hvilken artikkel Antidep bør ha — tittel, forfattere, tidsskrift, år og DOI — og hva et funn fra den kan gjelde: hvilke virkestoff, hvilke endepunkt og hvilken populasjon. Katalogvalgene er navn, aldri id-er. Antidep oppretter eller gjenfinner kilden, utleder hvor fullteksten hentes fra, og setter artikkelen på ventelisten.
- **`/fulltekst` — fulltekstinnboksen.** Krever editor- eller admin-mandat. Den viser hvilken artikkel som mangler, med tittel, forfattere og år, og ber om én ting: riktig PDF. Antidep binder filen til publikasjonen, kontrollerer at den faktisk _er_ den artikkelen, prøver lesbarheten med tabellene i behold, kjører det registrerte tekstuttrekket, registrerer kildeversjonen og legger neste ledd i køen — uten at noen oppgir en uuid, en hash, en oppskrift eller en terminalkommando.
- **`/kandidater` og `/publisert`.** Sluttkontrollen av det ferdige produktet, og det Antidep faktisk sier.
- **`/tekniske-problemer` — driftens side.** Krever admin-mandat, og et merke i navigasjonen dukker opp når noe er uløst. Den sier hvilket område som har problemer, når det oppsto og sist ble sett, og om det fortsatt pågår. Den rå årsaken lagres sikkert for Claude Code og ChatGPT, og vises aldri.

Ingen brukerflate viser en rå feil. `Error.message`, PostgREST- og Supabase-feil, JWT-feil, SQLSTATE og RPC-navn går til observability; flaten skriver sin egen stabile setning.

## Agentarbeid

Arbeidet gjøres på to måter, og begge går gjennom de samme kontrollene.

**Automatisk.** En planlagt KI-agent kobler seg til Antideps private MCP-app, spør om det finnes arbeid i sitt eget agentledd, tar én oppgave med en leie, leser den, utfører den og leverer svaret tilbake. Appen gir agenten fem smale operasjoner og ingenting annet: ingen SQL, ingen generell databaseadgang, ingen nøkler. Engangsoppsettet står i [Antidep som privat app i ChatGPT Business](docs/CHATGPT_WORKSPACE_AGENT.md), med den ferdige agentinstruksen, og er et teknisk deploy-/driftssteg.

**Teknisk recovery.** Nedlast/opplast-veien består som kommandoer og ikke som en flate:

```sh
npm run ops:agents -- work
npm run ops:agents -- export-task --job <id> --out oppgave.md
npm run ops:agents -- import-answer --job <id> --answer svar.json
```

Oppgavefilen kan inneholde hele forskningsartikkelen. Den går rett fra terminalen og inn i KI-tjenesten, og skal aldri commites, legges i en issue eller havne i en logg.

Generator, kildestøttekontroll og evidensvurdering er reelt separate. Hvilken KI-tjeneste et agentledd utføres av, tildeles på forhånd som et driftssteg (`npm run ops:agents -- assign-model …`), og ingen andre ledd kan bruke den samme. Valget inngår i oppgavens avtrykk, så et svar kan bekrefte identiteten sin men ikke bestemme den. Finnes ingen uavhengig modell, stopper kjeden framfor å registrere en kontroll som ikke er uavhengig.

## Drift

```sh
npm run ops:full-text   # Antideps eget tekstuttrekk av opplastede fulltekster
npm run ops:controls    # ekstraksjonskontrollen og kildestøttekontrollen
npm run ops:agents      # modelltildeling, kjøreroppsett og recovery-handoff
```

De to første kjøres planlagt av GitHub Actions hvert kvarter — `.github/workflows/full-text-extraction.yml` på en maskin der `pdftotext` er installert, og `.github/workflows/deterministic-controls.yml` med hvert kontrolledds egen legitimasjon. Ingen starter dem for hånd; kommandoene over er de samme kjøringene, tilgjengelige for feilsøking. `npm run ops:agents` kjøres av Claude Code eller ChatGPT ved behov. Ingen av dem er en klinikeroppgave, og ingen av dem finnes i produkt-UI.

Selve _overgangene_ mellom leddene er databasens egne og ikke kjøreplanens: et registrert evidensfunn legger ekstraksjonskontrollen i køen, en bekreftet kontroll legger neste semantiske ledd i køen, og en registrert evidensvurdering forsegler kandidaten — alt i den samme transaksjonen som skrev raden foran. Står en kjøring, blir arbeidet stående i kø; det blir aldri borte, og det blir aldri en menneskeoppgave.

Se [roadmap](docs/ROADMAP.md), [evidenskjeden](docs/EVIDENCE_PIPELINE.md), [den private MCP-appen](docs/CHATGPT_WORKSPACE_AGENT.md) og [styringsreglene](docs/ANTIDEP_CONSTITUTION.md).
