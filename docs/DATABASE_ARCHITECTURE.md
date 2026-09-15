# Databasearkitektur

Supabase/PostgreSQL deler data i `catalog`, `knowledge`, `workflow`, `provenance`, `audit` og den smale Data API-flaten `api`. RLS er default-deny på interne skjema. Klienter bruker kontrollerte `security definer`-innganger som autentiserer aktør/agent og rolle; interne funksjoner er ikke generelle klient-API-er.

Katalog, kilder og kildeversjoner bevares. Avledet klinisk innhold er uforanderlig i normal drift. Publisering krever kildestøtte, separate kontroller, evidensvurdering med rett mandat, navngitt menneskelig godkjenning og publisher-rolle.

Antidep 2-resetten er en eierautorisert engangshendelse, ikke et generelt slette-API. Den gjelder bare den eksplisitt reviewede legacy-prototypen. En preflight kjøres før første strukturelle endring og på nytt under lås rett før snapshot/sletting. Publiseringshistorikk, åpen agentkjøring eller ekstra/avvikende kliniske rotobjekter stopper utrullingen før innhold fjernes. De slettede prototype-radene lagres først i et privat, append-only snapshot med fingeravtrykk; katalog, kilder, kildeversjoner, kontoer, aktører, provenance og audit bevares.

En klinisk kildeversjon må være `full_text`, tilhøre riktig kilde, ha komplett PDF-binding, positiv størrelse, SHA-256 for dokument og tekst og den gjeldende sikre, tillatte uttrekksoppskriften. Dette beviser strukturell binding, ikke permanent lagring eller riktig publikasjon.

Alle skjemaendringer er fremoverrettede migrasjoner. Historiske migrasjoner i `scripts/legacy-migrations.sha256` skal aldri endres. Nye ID-er må sortere etter `20260924095000`. Test lokalt fra tom database og som oppgradering; hosted deploy krever review, rett prosjekt, backup og restore-prøve.
