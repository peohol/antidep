# Evidensvurderingsforslag

Denne katalogen er et internt arbeidsområde for agentmotoren og testene. Forslagene er lokale mellomartefakter og er ikke publisert klinisk innhold.

## Kontrakt

- Evidensvurdereren er en separat rolle fra synteseagenten og kildestøttekontrolløren.
- Vurderingen gjelder én bestemt påstandsrevisjon og det evidenssettet som er registrert for den.
- Databasen skal avvise vurderingen dersom grunnlaget har endret seg, mangler nødvendig kontroll eller vurdereren mangler riktig mandat.
- Forskningsusikkerhet skal beskrives som forskningsusikkerhet. En teknisk mislykket kontroll eller manglende kildetilgang er ikke en lav evidensgrad.
- Proveniens og rollegrenser bevares selv om den framtidige agentorkestreringen blir automatisert.

`agent:assess-evidence` er et beholdt utviklings-/testgrensesnitt, ikke en oppgave som produktets faglige eier skal utføre manuelt.

Den gamle menneskelige mikroreviewflaten er avviklet. Menneskelig fagansvar skal senere utøves som sluttkontroll av den ferdige, kandidatbundne klinikervisningen før eksplisitt publisering.

Se [evidenskjeden](../docs/EVIDENCE_PIPELINE.md) og [roadmap](../docs/ROADMAP.md).
