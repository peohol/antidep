# Lokal database

Kjør bare mot den lokale Supabase-stakken:

```sh
npm run db:start
npm run db:test:upgrade
npm run db:reset
npm run db:test
npm run db:test:lock
npm run db:test:race
npm run db:test:chain
npm run db:stop
```

`db:test:race` kjører to reelle forbindelser mot hverandre på de to stedene kjeden «finner eller oppretter»: synteseoppgaven for et virkestoff og et endepunkt, og kilden bak en fulltekstbestilling. Ingen av dem fanges av et unikhetskrav, fordi radene de to øktene skriver, ikke er like nok til å kollidere — og pgTAP-filene kjører i én transaksjon og kan derfor ikke se dem.

`db:test:upgrade` går tilbake til siste legacy-migrasjon og prøver Antidep 2-resetten som en faktisk oppgradering med syntetisk eksisterende innhold. `seed.sql` inneholder ikke klinisk prototypeinnhold. Migrasjoner til og med `20260924095000` er historiske og kontrolleres av `npm run verify:repo`. Nye migrasjoner er fremoverrettede.

## Legitimasjon til agentidentiteten

Agent-CLI-ene bruker prosjektets Data API med publishable key, aldri `service_role`. Hver agentrolle autentiseres i tillegg med sin egen databaseutstedte identitet og hemmelighet. De aktuelle miljøvariablene står i `.env.example`:

- `ANTIDEP_SUPABASE_URL` og `ANTIDEP_SUPABASE_PUBLISHABLE_KEY` er felles.
- `ANTIDEP_EXTRACTION_AGENT_*` brukes av ekstraksjonsagenten.
- `ANTIDEP_AGENT_*` brukes av den separate ekstraksjonsverifikatoren.
- `ANTIDEP_SYNTHESIS_AGENT_*` brukes av synteseagenten.
- `ANTIDEP_CLAIM_AGENT_*` brukes av den separate kildestøttekontrolløren.
- `ANTIDEP_ASSESSMENT_AGENT_*` brukes av evidensvurdereren.

`ANTIDEP_AGENT_*` og `ANTIDEP_CLAIM_AGENT_*` er i tillegg de to legitimasjonene den planlagte kontrollkjøringen leser (`npm run ops:controls`, `.github/workflows/deterministic-controls.yml`). De legges inn som repository secrets sammen med `ANTIDEP_SUPABASE_URL` og `ANTIDEP_SUPABASE_PUBLISHABLE_KEY`; mangler en av dem, avslutter kjøringen grønt med en advarsel framfor å stå rød. Kjøringen trenger ingen dokumentkatalog: kildeteksten slås opp som den registrerte representasjonen, og originalfilen forlater aldri databasen.

Hemmeligheter skal bare ligge i gitignorerte lokale miljøfiler eller et autorisert runtime-miljø. De skal aldri få `VITE_`-prefiks, commites eller legges i klientbunten.

Den eksterne agent-handoffen trenger ingen av dem, og ingen modelleverandørnøkkel. Oppgaven hentes og svaret importeres av et menneske med editor-mandat, gjennom sin egen innlogging; databasen åpner kjøringen og skriver gjennom de samme kontrollerte veiene som agentkjørerne bruker.

## Hosted utrulling

Reviewede databaseendringer deployes automatisk når en migrasjon er merget til `main`. `.github/workflows/database-production.yml` kjører bare på `push` til `main`, kobler Supabase CLI til produksjonsprosjektet, gjør først `db push --dry-run` og bruker deretter bare migrasjoner som ikke allerede står i den eksterne migrasjonshistorikken. Seed-data sendes aldri til produksjon. Project ref er ikke en hemmelighet; `SUPABASE_ACCESS_TOKEN` ligger som GitHub-secret og eksponeres bare for Supabase-stegene.

En PR-branch skal aldri kunne starte produksjonsjobben eller få tilgang til produksjonstokenet. Derfor skal workflowen ikke få `pull_request`, `pull_request_target`, `workflow_dispatch` eller `workflow_call`; `npm run verify:repo` håndhever denne grensen.

Destruktive driftsoperasjoner er fortsatt en separat handling. Kjør aldri `supabase db reset --linked` mot produksjon. Ved reset, rollback, restore eller annen operasjon som kan slette eller overskrive data skal prosjekt og miljø bekreftes, private database- og Storage-backuper håndteres utenfor repo og Actions-artefakter, og stopphendelser/publiseringshistorikk kontrolleres før inngrepet. Ikke legg eksport, snapshot eller hemmeligheter i repo eller Actions-artefakter.
