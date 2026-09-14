# Databasearkitektur

Supabase/PostgreSQL deler data i `catalog`, `knowledge`, `workflow`, `provenance`, `audit` og den smale Data API-flaten `api`. RLS er default-deny på interne skjema. Klienter bruker kontrollerte `security definer`-innganger som autentiserer aktør/agent og rolle; interne funksjoner er ikke generelle klient-API-er.

Katalog, kilder og kildeversjoner bevares. Avledet klinisk innhold er uforanderlig i normal drift. Publisering krever kildestøtte, separate kontroller, evidensvurdering med rett mandat, navngitt menneskelig godkjenning og publisher-rolle. Reset-migrasjonen er en eierautorisert engangshendelse med privat snapshot og stopp ved publiseringshistorikk eller åpne agentkjøringer; den er ikke et slette-API.

En klinisk kildeversjon må være `full_text`, tilhøre riktig kilde, ha komplett PDF-binding, positiv størrelse, SHA-256 for dokument og tekst og en tillatt uttrekksoppskrift. Dette beviser strukturell binding, ikke permanent lagring eller riktig publikasjon.

Alle skjemaendringer er fremoverrettede migrasjoner. Historiske migrasjoner i `scripts/legacy-migrations.sha256` skal aldri endres. Nye ID-er må sortere etter `20260924095000`. Test lokalt fra tom database og som oppgradering; hosted deploy krever review, rett prosjekt, backup og restore-prøve.
