# Antidep

Antidep utvikles som et agentstyrt, etterprøvbart kunnskapssystem om antidepressiver. Forskningsbaserte kliniske funn krever kontrollert fulltekst. En navngitt fagperson skal vurdere det ferdige klinikerproduktet før eksplisitt publisering.

## Status

Repoet inneholder et minimalt React-skall, Supabase-skjemaet og en testbar agentmotor. Det finnes foreløpig ingen live semantisk modelladapter, permanent PDF-opplasting eller ferdig klinikerflate. Prototypeinnholdet er tatt ut av aktiv drift av en fremoverrettet, reversibel migrasjon; ingen hostet database er endret av kodeleveransen.

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

Lokal database: `npm run db:start`, `npm run db:reset`, `npm run db:test`, `npm run db:test:lock`, `npm run db:test:chain`, `npm run db:stop`.

Se [roadmap](docs/ROADMAP.md), [evidenskjeden](docs/EVIDENCE_PIPELINE.md) og [styringsreglene](docs/ANTIDEP_CONSTITUTION.md).
