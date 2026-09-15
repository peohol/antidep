# Innholdsstyring

Agenter lager og kontrollerer et produktutkast med avgrensede retries. Faglig svak evidens kan presenteres med tydelig usikkerhet; manglende fulltekst, feil kilde, feil tall eller en kontroll som ikke kjørte, blokkerer kjeden.

Interne utkast er private og eksperimentelle. Sluttkontroll utføres av en navngitt fagperson på samme konkrete innhold og renderer som klinikeren skal se. Godkjenn, be om endringer og avvis er produktnivåbeslutninger, ikke ett klikk per databasefelt. Enhver faglig relevant endring lager senere en ny kandidat og krever ny sluttkontroll.

Publisering er eksplisitt og separat, og den finnes nå. Sluttkontrollen registrerer en beslutning om et forseglet innhold og publiserer ingenting; publiseringen er en egen handling, med et annet mandat, på nøyaktig det innholdet og det avtrykket. Bare et menneske med gyldig publisher-rolle kan utføre den, og en agentidentitet kan det ikke: veien er ikke kjørbar uten brukerkonto, og attribusjonen utledes av databasen framfor å oppgis.

Historikk slettes ikke. Tilbaketrekking og rollback er nye append-only hendelser som navngir hvilket innhold som ble tatt ut av visning eller tatt i bruk igjen, av hvem og hvorfor. En tilbaketrekking kjører bevisst ingen gate — å ta innhold ut av visning skal aldri kunne blokkeres av at grunnlaget er blitt utilstrekkelig — mens en rollback kjører hele gaten på nytt og i tillegg krever at målet faktisk har vært publisert.

En rollback gjelder nøyaktig det innholdet den som utfører den valgte. Den samme revisjonen kan ha vært publisert som flere forskjellige versjoner, og da holder det ikke å navngi revisjonen: valget ville vært tvetydig, og handlingen kunne tatt i bruk noe annet enn det flaten viste. Er den valgte versjonen ikke lenger den som ligger der, avvises rollbacken framfor å gjenopprette en annen — svaret er da å bygge på nytt, sluttkontrollere og publisere.

Mandatet gjelder også når handlingen allerede er utført. De tre handlingene svarer at ingenting ble endret når det ikke er noe å endre, og det svaret krever publisher-mandat som alt annet i publiseringslaget.
