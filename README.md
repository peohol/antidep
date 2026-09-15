# Antidep

Antidep utvikles som et agentstyrt, etterprøvbart kunnskapssystem om antidepressiver. Forskningsbaserte kliniske funn krever kontrollert fulltekst. En navngitt fagperson skal vurdere det ferdige klinikerproduktet før eksplisitt publisering.

## Status

Repoet inneholder Supabase-skjemaet, en testbar agentmotor og klinikerflaten. Kjeden går nå hele veien fra en privat PDF til publisert klinikerinnhold: originalfilen lagres varig og privat med serverberegnet filidentitet, publikasjonstilhørigheten og lesbarheten — tabellene inkludert — kontrolleres før fullteksten registreres, agentarbeidet har varig og idempotent jobbtilstand, hvert agentledd kjører som sin egen registrerte modellidentitet, og kandidatinnholdet forsegles med kildedekningen synlig.

Sluttkontrollen er bundet til nøyaktig den kandidaten som ble lest, og publiserer ingenting. Publiseringen er en egen handling med et annet mandat: et menneske med publisher-rolle tar i bruk nøyaktig det godkjente avtrykket, klinikerflaten viser den forseglede raden ordrett, og tilbaketrekking og rollback er nye, synlige hendelser som aldri sletter historikk.

Det semantiske agentarbeidet gjøres av KI-tjenester eieren allerede har tilgang til. Antidep bygger oppgaven, binder svaret til nøyaktig det grunnlaget oppgaven ble laget av, og registrerer resultatet gjennom de samme kontrollerte skriveveiene som før. Hele veien betjenes fra flaten `/agentarbeid`: last ned oppgaven, gi den til KI-tjenesten, last opp svaret. Ingen modellnøkkel og ingen betalt modell-API er nødvendig.

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

Lokal database: `npm run db:start`, `npm run db:test:upgrade`, `npm run db:reset`, `npm run db:test`, `npm run db:test:lock`, `npm run db:test:chain`, `npm run db:stop`.

## Agentarbeid

Flaten `/agentarbeid` viser hvilke agentoppgaver som venter, hvilket ledd de gjelder, og hvilken KI-modell leddet er registrert med. Oppgaven lastes ned som én fil som inneholder alt agenten trenger — rollen, reglene, grensene, den forventede svarstrukturen og hele den kontrollerte kildeteksten — og svaret lastes opp igjen som én JSON-fil.

Oppgavefilen kan inneholde hele forskningsartikkelen. Den går rett fra flaten og inn i KI-tjenesten, og skal aldri commites, legges i en issue eller havne i en logg.

Generator, kildestøttekontroll og evidensvurdering skal fortsatt være reelt separate. Den modellen som svarer først i et agentledd, blir registrert som leddets modell, og ingen andre ledd kan bruke den samme. Finnes ingen uavhengig modell, stopper kjeden framfor å registrere en kontroll som ikke er uavhengig.

Se [roadmap](docs/ROADMAP.md), [evidenskjeden](docs/EVIDENCE_PIPELINE.md) og [styringsreglene](docs/ANTIDEP_CONSTITUTION.md).
