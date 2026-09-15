# Ekstraksjonsoppdrag

Denne katalogen er et internt grensesnitt for agentmotoren og testene. Filene som opprettes under kjøring er lokale, gitignorerte arbeidsartefakter og er ikke klinisk innhold.

## Kontrakt

- Et oppdrag bindes til én registrert kildeversjon og til katalogverdiene ekstraksjonen kan bruke.
- Forskningsbasert klinisk evidens krever en dokumentbundet `full_text`-versjon. Abstract og metadata er bare discovery og kan ikke bli et `EvidenceItem`.
- Dokumentbindingen omfatter dokumentfingeravtrykk, størrelse, medietype, tekstfingeravtrykk og den registrerte uttrekksoppskriften.
- Oppdraget kommer fra den kontrollerte databaseflaten; agenten skal ikke konstruere kilde-, versjons- eller katalog-ID-er selv.
- Manglende eller feil dokumentbinding skal stoppe kjeden, ikke falle tilbake til netttekst.

De eksisterende CLI-ene (`editor:assignment` og `agent:draft-extraction`) er beholdte utviklings- og testgrensesnitt. Den filbaserte modelladapteren er ikke en live semantisk runtime og skal ikke beskrives som den ferdige produktflyten.

Menneskelig felt-for-felt-kontroll er ikke målbildet. Agentene gjør mellomarbeidet; en navngitt fagperson skal senere kontrollere den ferdige publiseringskandidaten i klinikerens visning. Kandidatbundet sluttkontroll er ikke implementert ennå.

Se [evidenskjeden](../docs/EVIDENCE_PIPELINE.md) og [roadmap](../docs/ROADMAP.md) for gjeldende produktretning.
