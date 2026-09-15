# Evidensvurderingsforslag

Denne katalogen er et internt arbeidsområde for agentmotoren og testene. Forslagene er lokale mellomartefakter og er ikke publisert klinisk innhold.

## Kontrakt

- Evidensvurdereren er en separat rolle fra synteseagenten og kildestøttekontrolløren.
- Vurderingen gjelder én bestemt påstandsrevisjon og det evidenssettet som er registrert for den.
- Databasen skal avvise vurderingen dersom grunnlaget har endret seg, mangler nødvendig kontroll eller vurdereren mangler riktig mandat.
- Forskningsusikkerhet skal beskrives som forskningsusikkerhet. En teknisk mislykket kontroll eller manglende kildetilgang er ikke en lav evidensgrad.
- Proveniens og rollegrenser bevares selv om den framtidige agentorkestreringen blir automatisert.

`agent:assess-evidence` er et beholdt utviklings- og prøvegrensesnitt. Produktflyten er den eksterne agent-handoffen: vurderingsoppgaven bygges av databasen med nøyaktig det evidenssettet revisjonen hviler på, en ekstern KI-agent gjør vurderingen, og svaret importeres fra agentflaten. Den modellen som laget innholdet, kan ikke også vurdere det — databasen avviser kombinasjonen.

Den gamle menneskelige mikroreviewflaten er avviklet. Menneskelig fagansvar skal senere utøves som sluttkontroll av den ferdige, kandidatbundne klinikervisningen før eksplisitt publisering.

Se [evidenskjeden](../docs/EVIDENCE_PIPELINE.md) og [roadmap](../docs/ROADMAP.md).
