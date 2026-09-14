# Lokal database

Kjør bare mot den lokale Supabase-stakken:

```sh
npm run db:start
npm run db:reset
npm run db:test
npm run db:test:lock
npm run db:test:chain
npm run db:stop
```

`seed.sql` inneholder ikke klinisk prototypeinnhold. Migrasjoner til og med `20260924095000` er historiske og kontrolleres av `npm run verify:repo`. Nye migrasjoner er fremoverrettede.

## Hosted utrulling

Utrulling er en separat, menneskelig autorisert driftsoperasjon etter teknisk review: bekreft prosjekt og miljø, stopp gamle jobber, ta privat databasebackup, sikkerhetskopier Storage separat, prøv restore isolert, kontroller stopphendelser og mål-antall, og deploy reviewede migrasjoner. Ikke legg eksport, snapshot eller hemmeligheter i repo eller Actions-artefakter. Resetten skal stoppe ved publiseringshistorikk, publiseringspeker, åpen agentkjøring eller uventet avhengighet.
