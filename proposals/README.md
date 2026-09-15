# Ekstraksjonsforslag

Denne katalogen inneholder bare lokale mellomartefakter for agentmotoren og testene. Forslag er ikke godkjent kunnskap og skal ikke deployes eller publiseres.

## Kontrakt

- Ett forslag gjelder ett konkret evidensfunn fra én eksplisitt kildeversjon.
- Kliniske forskningsfunn kan bare registreres mot dokumentbundet fulltekst. Abstract, metadata og andre begrensede representasjoner er discovery-only.
- Kildeutdrag og kildepeker skal være forankret i den samme representasjonen som kildeversjonen beskriver.
- Registreringsagenten kontrollerer formen, kildebindingen og katalogverdiene før skriving.
- En separat ekstraksjonsverifikator kontrollerer kildestøtten. Generator og kontrollør skal ikke være samme rolle.
- Teknisk feil, manglende dokumenttilgang eller manglende kontroll kan aldri omdøpes til et verifisert funn.

`agent:extract-evidence` og `agent:reextract-evidence` er interne utviklings- og prøveinnganger. Produktflyten er den eksterne agent-handoffen: oppgaven bygges av databasen, en ekstern KI-agent utfører den, og svaret importeres fra agentflaten gjennom den samme kontrollerte skriveveien.

Det finnes ikke lenger en menneskelig mikroreview-rute for hvert evidensfelt. Den framtidige menneskelige oppgaven er sluttkontroll av en ferdig, kandidatbundet klinikervisning før eksplisitt publisering.

Se [evidenskjeden](../docs/EVIDENCE_PIPELINE.md) og [roadmap](../docs/ROADMAP.md).
