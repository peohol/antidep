# Originaldokumenter

Denne katalogen er den nåværende lokale dokumentkilden for agentmotoren og testene. PDF-er her er gitignorert, skal aldri commites og er ikke en permanent lagringsløsning.

## Kontrakt

- Forskningsbasert klinisk evidens krever en eksplisitt dokumentbundet `full_text`-kildeversjon.
- Databasen lagrer dokumentets SHA-256, byte-størrelse, medietype, tekstfingeravtrykk og den tillatte uttrekksoppskriften.
- Nye dokumentutledede versjoner bruker `pdftotext -bbox-layout -enc UTF-8 -eol unix` og Antideps versjonerte leserekkefølge-transformasjon.
- Agentleddene finner dokumentet etter fingeravtrykk. Mangler riktig dokument, skal kjeden stoppe; den skal aldri hente `retrieved_from` som erstatning for en dokumentbundet representasjon.
- Et korrekt fingeravtrykk og en PDF-signatur beviser dokumentidentitet, ikke at filen er riktig eller komplett publikasjon. Publikasjonstilhørighet og nødvendig tabell-/tilleggsdekning må valideres i den kommende fulltekstflyten.

Permanent privat PDF-lagring er ikke implementert. Neste produktleveranse skal gjøre dokumentene varig tilgjengelige for nye agentjobber uten lokal filtransport og samtidig kontrollere publikasjonstilhørighet.

Se [evidenskjeden](../docs/EVIDENCE_PIPELINE.md) og [roadmap](../docs/ROADMAP.md).
