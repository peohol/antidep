# Lokal database

Kjør bare mot den lokale Supabase-stakken:

```sh
npm run db:start
npm run db:test:upgrade
npm run db:reset
npm run db:test
npm run db:test:lock
npm run db:test:chain
npm run db:stop
```

`db:test:upgrade` går tilbake til siste legacy-migrasjon og prøver Antidep 2-resetten som en faktisk oppgradering med syntetisk eksisterende innhold. `seed.sql` inneholder ikke klinisk prototypeinnhold. Migrasjoner til og med `20260924095000` er historiske og kontrolleres av `npm run verify:repo`. Nye migrasjoner er fremoverrettede.

## Legitimasjon til agentidentiteten

Agent-CLI-ene bruker prosjektets Data API med publishable key, aldri `service_role`. Hver agentrolle autentiseres i tillegg med sin egen databaseutstedte identitet og hemmelighet. De aktuelle miljøvariablene står i `.env.example`:

- `ANTIDEP_SUPABASE_URL` og `ANTIDEP_SUPABASE_PUBLISHABLE_KEY` er felles.
- `ANTIDEP_EXTRACTION_AGENT_*` brukes av ekstraksjonsagenten.
- `ANTIDEP_AGENT_*` brukes av den separate ekstraksjonsverifikatoren.
- `ANTIDEP_SYNTHESIS_AGENT_*` brukes av synteseagenten.
- `ANTIDEP_CLAIM_AGENT_*` brukes av den separate kildestøttekontrolløren.
- `ANTIDEP_ASSESSMENT_AGENT_*` brukes av evidensvurdereren.

Hemmeligheter skal bare ligge i gitignorerte lokale miljøfiler eller et autorisert runtime-miljø. De skal aldri få `VITE_`-prefiks, commites eller legges i klientbunten.

## Hosted utrulling

Utrulling er en separat, menneskelig autorisert driftsoperasjon etter teknisk review: bekreft prosjekt og miljø, stopp gamle jobber, ta privat databasebackup, sikkerhetskopier Storage separat, prøv restore isolert, kontroller stopphendelser og mål-antall, og deploy reviewede migrasjoner. Ikke legg eksport, snapshot eller hemmeligheter i repo eller Actions-artefakter. Resetten skal stoppe ved publiseringshistorikk, publiseringspeker, åpen agentkjøring eller uventet avhengighet.
