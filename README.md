# Antidep

Antidep er et klinisk arbeidsverktøy under utvikling: rask, presis og etterprøvbar informasjon
om antidepressiver for helsepersonell i Norge.

Prosjektet er i bootstrap-fasen. Ingen klinisk funksjonalitet er implementert ennå, og ingen
klinisk informasjon er publisert.

## Styringsdokumenter

All utvikling styres av dokumentene i [`docs/`](./docs):

- [`ANTIDEP_CONSTITUTION.md`](./docs/ANTIDEP_CONSTITUTION.md) — ikke-forhandlingsbare prinsipper
- [`MVP_IMPLEMENTATION_PLAN.md`](./docs/MVP_IMPLEMENTATION_PLAN.md) — implementeringsrekkefølge og status
- [`ROUTINE_EXTRACTION.md`](./docs/ROUTINE_EXTRACTION.md) — hvordan modell-leddet kjøres av en Claude Code Routine
- [`KNOWLEDGE_MODEL.md`](./docs/KNOWLEDGE_MODEL.md), [`EVIDENCE_PIPELINE.md`](./docs/EVIDENCE_PIPELINE.md),
  [`DATABASE_ARCHITECTURE.md`](./docs/DATABASE_ARCHITECTURE.md),
  [`CONTENT_GOVERNANCE.md`](./docs/CONTENT_GOVERNANCE.md),
  [`PRODUCT_INFORMATION_ARCHITECTURE.md`](./docs/PRODUCT_INFORMATION_ARCHITECTURE.md)

## Teknisk stack

React, TypeScript og Vite i klientlaget; Vitest og React Testing Library for tester;
ESLint og Prettier for kodekvalitet. Supabase/PostgreSQL er valgt som kanonisk dataplattform;
det lokale utviklingsmiljøet er satt opp med pinnet Supabase CLI (se `supabase/README.md`),
og schema/migrasjoner innføres fra og med de første databaseslicene. Hosting er planlagt
på Vercel.

## Kom i gang

Krav: Node.js 22 (se `.nvmrc`) og npm. Docker kreves i tillegg for den lokale
Supabase-stacken (valgfritt inntil databaseslicene tar den i bruk).

```bash
npm ci        # installer avhengigheter fra package-lock.json
npm run dev   # start utviklingsserver
```

## Kommandoer

```bash
npm run dev          # utviklingsserver med hot reload
npm run build        # typecheck + produksjonsbygg til dist/
npm run preview      # serverer produksjonsbygget lokalt
npm run lint         # ESLint
npm run format       # Prettier (skriver endringer)
npm run format:check # Prettier (kun kontroll, brukes i CI)
npm run typecheck    # TypeScript uten emit
npm run test         # Vitest, én kjøring (brukes i CI)
npm run test:watch   # Vitest i watch-modus
npm run db:start     # lokal Supabase-stack (krever Docker), se supabase/README.md
npm run db:status    # status og lokale nøkler
npm run db:reset     # gjenskap lokal database (kjører migrasjoner når de finnes)
npm run db:stop      # stopp lokal Supabase-stack
```

Modell-leddet (ingen legitimasjon, ingen databasetilgang):

```bash
npm run agent:draft-extraction -- --assignment <fil> --open      # hent kilden, skriv ut prompten
npm run agent:draft-extraction -- --assignment <fil> --close     # les svaret, lag ett forslag
npm run agent:draft-extraction -- --assignment <fil> --status    # hvor kjøringen står
```

Dette er veien en Claude Code Routine kjører leddet: to kommandoer med en fil
imellom, og modellsvaret skrevet direkte i kjøremappa. Se
[`docs/ROUTINE_EXTRACTION.md`](./docs/ROUTINE_EXTRACTION.md).

Den eldre veien er beholdt for feilsøking og for å spille av en kjøring om igjen
uten en modell:

```bash
npm run agent:propose-extraction -- --assignment <fil> --prepare <katalog>   # skriv ut prompten og et tomt opptak
npm run agent:propose-extraction -- --assignment <fil> --recording <fil> --out <fil>   # lag ett forslag
```

Agentkjørerne (krever legitimasjon, se `supabase/README.md`):

```bash
npm run agent:extract-evidence -- --schema                        # kontrakten for et forslag
npm run agent:extract-evidence -- --proposal <fil> --assignment <fil>     # maskinutkast, med oppdraget
npm run agent:extract-evidence -- --proposal <fil> --model-proposal       # maskinutkast uten oppdrag
npm run agent:extract-evidence -- --proposal <fil> --human-proposal       # en redaktørs eget arbeid
npm run agent:reextract-evidence -- --directory proposals --model-proposal   # flere forslag, med kontroll etter hvert
npm run agent:verify-extraction                                  # den deterministiske kontrollen
npm run agent:verify-claims                                      # claim-verifikatoren
```

Oppdragene modell-leddet leser, er beskrevet i `assignments/README.md`.
Forslagsfilene det skriver, og hvordan de registreres, i `proposals/README.md`.

CI (GitHub Actions, `.github/workflows/ci.yml`) kjører lint, formatkontroll, typecheck,
tester og produksjonsbygg på alle pull requests og på `main`, og verifiserer i en egen jobb
at den lokale Supabase-stacken booter fra clean checkout.

### Forhåndsvisninger og deploy

`.github/workflows/vercel.yml` kjører **bare** på `main`. Den kjørte tidligere også på alle
`pull_request`, med `VERCEL_TOKEN` i jobbens miljø, og bygde koden fra PR-branchen — og en pull
request fra en branch i _samme_ repo får repository-secrets. Kode på en PR-branch kunne derfor
kjøre med deploy-tokenet tilgjengelig. Veien er stengt fordi en autonom aktør som leser
eksternt kildemateriale, ikke skal kunne nå den (`docs/ROUTINE_EXTRACTION.md` §3.5).

Forhåndsvisninger for pull requests lages av **Vercels egen Git-integrasjon**, som allerede
gjorde det: det er den som gir `antidep-git-<branch>-…`-lenken i PR-kommentaren.
Arbeidsflyten laget en andre deploy av det samme, uten branch-alias.

## Miljøvariabler

Kopier `.env.example` til `.env.local` og fyll inn verdier ved behov; for lokal utvikling
skrives verdiene ut av `npm run db:start`/`npm run db:status`. Kun variabler med
`VITE_`-prefiks eksponeres til nettleseren, og klienten skal kun bruke publishable-nøkkelen.
Reelle nøkler skal aldri committes, og Supabase secret-/`service_role`-nøkler skal aldri
finnes i klientkode eller i repoet.

## Prosjektstruktur

```text
docs/        styringsdokumenter (arkitektur, governance, plan)
src/
  app/       app-skall og applikasjonsoppsett
supabase/    lokal Supabase-konfigurasjon; migrasjoner kommer fra og med PR B
tests/       testoppsett og tverrgående tester (e2e kommer i senere slices)
```

`src/` vokser mot strukturen i MVP-planen §6 (`components/`, `features/`, `lib/`, `routes/`,
`types/`); katalogene opprettes først når de tas i bruk.

## Deploy

Repoet er forberedt for Vercel med framework-preset **Vite** (auto-detektert; ingen egen
konfigurasjonsfil er nødvendig ennå). Preview deployments for PR-er aktiveres ved å koble
repoet til et Vercel-prosjekt, jf. MVP-planen §53.

## Arbeidsform

Små, énformåls-PR-er med eksplisitt validering (MVP-planen §51–52). Endringer vurderes mot
styringsdokumentene, ikke bare mot om koden «virker».
