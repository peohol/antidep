# Antidep

Antidep utvikles som et agentstyrt, etterprøvbart kunnskapssystem om antidepressiver. Forskningsbaserte kliniske funn krever kontrollert fulltekst. En navngitt fagperson skal vurdere det ferdige klinikerproduktet før eksplisitt publisering.

## Status

Repoet inneholder Supabase-skjemaet, en testbar agentmotor og klinikerflaten. Kjeden går nå hele veien fra en privat PDF til publisert klinikerinnhold: originalfilen lagres varig og privat med serverberegnet filidentitet, publikasjonstilhørigheten og lesbarheten — tabellene inkludert — kontrolleres før fullteksten registreres, agentarbeidet har varig og idempotent jobbtilstand, hvert agentledd kjører som sin egen registrerte modellidentitet, og kandidatinnholdet forsegles med kildedekningen synlig.

Sluttkontrollen er bundet til nøyaktig den kandidaten som ble lest, og publiserer ingenting. Publiseringen er en egen handling med et annet mandat: et menneske med publisher-rolle tar i bruk nøyaktig det godkjente avtrykket, klinikerflaten viser den forseglede raden ordrett, og tilbaketrekking og rollback er nye, synlige hendelser som aldri sletter historikk.

Det finnes ingen live semantisk modellruntime; utkastleddene kjøres av et opptak.

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

Se [roadmap](docs/ROADMAP.md), [evidenskjeden](docs/EVIDENCE_PIPELINE.md) og [styringsreglene](docs/ANTIDEP_CONSTITUTION.md).
