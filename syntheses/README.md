# Synteseforslag

Denne katalogen er et internt arbeidsområde for agentmotoren og testene. Lokale forslag er mellomtilstander, ikke publisert klinisk kunnskap.

## Kontrakt

- Synteseagenten kan bare bygge på registrerte evidensfunn som tilfredsstiller de gjeldende databasereglene for kilde- og kontrollgrunnlag.
- Påstand, revisjon og evidenslenker registreres med proveniens og behandles som uforanderlige historiske objekter.
- En separat kildestøttekontroll skal forsøke å finne feil i syntesen.
- Evidensvurderingen er et eget senere agentledd med egen rolle og legitimasjon.
- Agentuenighet, forskningsusikkerhet og teknisk kontrollfeil skal forbli forskjellige tilstander.

`agent:synthesise-claims` er et beholdt utviklings- og prøvegrensesnitt. Produktflyten er den eksterne agent-handoffen: synteseoppgaven bygges av databasen med nøyaktig de evidensfunnene en redaktør har avgrenset, en ekstern KI-agent formulerer påstanden, og svaret importeres fra agentflaten. Synteseagenten og evidensvurdereren kan ikke være den samme modellen.

Den gamle menneskelige mikroreview-ruten er avviklet. Målbildet er at agentene produserer en ferdig klinisk kandidat som deretter kontrolleres av en navngitt fagperson i samme renderer som klinikeren skal se. Denne kandidatbindingen og klinikerflaten er neste produktleveranse.

Se [evidenskjeden](../docs/EVIDENCE_PIPELINE.md) og [roadmap](../docs/ROADMAP.md).
