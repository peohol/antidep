# Ekstraksjonsoppdrag

Denne katalogen er et internt grensesnitt for agentmotoren og testene. Filene som opprettes under kjøring er lokale, gitignorerte arbeidsartefakter og er ikke klinisk innhold.

## Kontrakt

- Et oppdrag bindes til én registrert kildeversjon og til katalogverdiene ekstraksjonen kan bruke.
- Forskningsbasert klinisk evidens krever en dokumentbundet `full_text`-versjon. Abstract og metadata er bare discovery og kan ikke bli et `EvidenceItem`.
- Dokumentbindingen omfatter dokumentfingeravtrykk, størrelse, medietype, tekstfingeravtrykk og den registrerte uttrekksoppskriften.
- Oppdraget kommer fra den kontrollerte databaseflaten; agenten skal ikke konstruere kilde-, versjons- eller katalog-ID-er selv.
- Manglende eller feil dokumentbinding skal stoppe kjeden, ikke falle tilbake til netttekst.
- Fullteksten registreres gjennom det private biblioteket: originalfilen lagres varig, publikasjonstilhørigheten kontrolleres mot kildens egen identitet, og lesbarheten prøves med tabellene inkludert. `editor:assignment --pdf` går denne veien.

Produktflyten er den eksterne agent-handoffen: Antidep bygger oppgaven av databasen, en KI-agent eieren allerede har tilgang til utfører den, og svaret importeres fra agentflaten. Ingen oppdragsfil er involvert i den veien, og ingen modellnøkkel.

`editor:assignment` registrerer fullteksten og legger agentoppgaven i køen; oppdragsfilen den skriver ved siden av, hører til den filbaserte kjøringen. `agent:draft-extraction` er det filbaserte grensesnittet, beholdt som utviklings- og prøveinngang: det er den som gjør hele kjeden kjørbar om igjen uten en eneste modell.

Menneskelig felt-for-felt-kontroll er ikke målbildet. Agentene gjør mellomarbeidet; en navngitt fagperson kontrollerer den ferdige kandidaten i klinikerens egen visning, og beslutningen er bundet til nøyaktig det innholdet som ble lest. Publiseringen er fortsatt en egen, stengt handling.

Se [evidenskjeden](../docs/EVIDENCE_PIPELINE.md) og [roadmap](../docs/ROADMAP.md) for gjeldende produktretning.
