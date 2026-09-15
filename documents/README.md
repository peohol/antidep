# Originaldokumenter

Denne katalogen er den lokale arbeidskopien agentkjørerne leser fra. PDF-er her er gitignorert og skal aldri commites.

Den varige lagringen er databasen. `api.upload_full_text_document(...)` legger originalfilen i `knowledge.source_documents`, som er privat: RLS med default deny, ingen grants og ingen view. Ingen klientrolle kan lese én byte, og filen finnes der etter at den lokale kopien er borte.

## Kontrakt

- Forskningsbasert klinisk evidens krever en eksplisitt dokumentbundet `full_text`-kildeversjon.
- Filidentiteten er innholdet: SHA-256 beregnes av bytene og gjentas som en regel på raden, så den kan ikke være en påstand kalleren skriver.
- Publikasjonstilhørigheten kontrolleres av teksten selv. Fullteksten må bære kildens registrerte DOI, dens PMID navngitt som en PMID, eller tittelen. Et korrekt fingeravtrykk beviser hvilken fil dette er, ikke hvilken artikkel den er.
- Lesbarheten kontrolleres, tabellene særskilt: nok tekst, nok linjer, nok bokstaver, og datarader fra tabellene. En artikkel der tabellene ble droppet som bilder, ser hel ut i brødteksten samtidig som de kliniske tallene mangler, og registreres ikke.
- Nye dokumentutledede versjoner bruker `pdftotext -bbox-layout -enc UTF-8 -eol unix` og Antideps versjonerte leserekkefølge-transformasjon.
- Agentleddene finner dokumentet etter fingeravtrykk. Mangler riktig dokument, skal kjeden stoppe; den skal aldri hente `retrieved_from` som erstatning for en dokumentbundet representasjon.

Opplastingen er idempotent: den samme filen finner sin egen rad på fingeravtrykket, og den samme teksten sin egen kildeversjon. En avbrutt kjøring kan derfor kjøres om igjen uten å rydde.

Se [evidenskjeden](../docs/EVIDENCE_PIPELINE.md) og [roadmap](../docs/ROADMAP.md).
